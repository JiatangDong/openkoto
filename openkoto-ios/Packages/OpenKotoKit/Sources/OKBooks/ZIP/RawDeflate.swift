import Compression
import Foundation

/// 原始 DEFLATE（RFC 1951）解压。
///
/// Apple `Compression` 框架里的 `COMPRESSION_ZLIB` 就是**不带 zlib 头**的 raw deflate，
/// 正是 ZIP method 8 所需——不要再去剥 zlib 头。
enum RawDeflate {
    enum Failure: Error, Equatable {
        case initializationFailed
        case corruptStream
        case outputTooLarge
    }

    /// 分块流式解压，边解边比对上限，绝不先解完再检查（zip bomb 会在检查前就吃光内存）。
    /// - Parameters:
    ///   - expectedSize: 中央目录声明的解压后大小，仅用于预分配。
    ///   - limit: 硬上限，产出超过即中止。
    static func inflate(_ source: Data, expectedSize: Int, limit: Int) throws -> Data {
        guard !source.isEmpty else { return Data() }

        // compression_stream 无空初始化器，先用占位指针建流，随后立刻被真实缓冲覆盖。
        let placeholder = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { placeholder.deallocate() }

        var stream = compression_stream(
            dst_ptr: placeholder,
            dst_size: 0,
            src_ptr: UnsafePointer(placeholder),
            src_size: 0,
            state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            == COMPRESSION_STATUS_OK
        else { throw Failure.initializationFailed }
        defer { compression_stream_destroy(&stream) }

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var output = Data(capacity: min(max(expectedSize, 1), 1 << 20))
        var thrown: Failure?

        source.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            stream.src_ptr = base
            stream.src_size = source.count

            while true {
                stream.dst_ptr = buffer
                stream.dst_size = bufferSize
                let remainingBefore = stream.src_size
                let status = compression_stream_process(
                    &stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - stream.dst_size

                if produced > 0 { output.append(buffer, count: produced) }
                if output.count > limit {
                    thrown = .outputTooLarge
                    return
                }

                switch status {
                case COMPRESSION_STATUS_END:
                    return
                case COMPRESSION_STATUS_OK:
                    // 既没消费输入也没产出 = 流不完整/已损坏，否则会空转。
                    if produced == 0 && stream.src_size == remainingBefore {
                        thrown = .corruptStream
                        return
                    }
                default:
                    thrown = .corruptStream
                    return
                }
            }
        }

        if let thrown { throw thrown }
        return output
    }
}
