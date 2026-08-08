#if os(iOS)
import Foundation
import Network
import os
import UIKit
import OKAIClient

/// 「复制诊断信息」的报告拼装。
///
/// 背景：用户反馈"网络不可用"时，这句话盖住了一整族错误（试用额度到期、
/// 模型 alias 失效、Keychain 读出失败、连接被重置……），没有现场信息根本
/// 无法区分。这份报告是开发者唯一能看到的现场——宁可多带，不可漏项。
/// 脱敏红线与 `AIFailureDiagnostics` 一致：任何字段都不含 API Key。
enum AIDiagnosticsReport {
    static func make(error: AIClientError, diagnostics: AIFailureDiagnostics?) async -> String {
        var lines: [String] = []
        lines.append("== OpenKoto AI 诊断报告 ==")
        lines.append("报告生成: \(iso(Date()))")
        lines.append("App: \(appVersion) (\(buildNumber))")
        // UIDevice 整体是 MainActor 隔离的，一次性跳到主 actor 取完。
        let (systemName, systemVersion) = await MainActor.run {
            (UIDevice.current.systemName, UIDevice.current.systemVersion)
        }
        lines.append("设备: \(machineIdentifier), \(systemName) \(systemVersion)")
        lines.append("语言: \(Locale.current.identifier), 时区: \(TimeZone.current.identifier)")
        // "网络不可用"类报告的第一嫌疑是设备真的断网——复制瞬间再探一次。
        lines.append("当前网络: \(await networkSnapshot())")
        lines.append("")
        lines.append("错误: \(userMessage(for: error)) [\(String(describing: error))]")

        if let d = diagnostics {
            lines.append("发生时间: \(iso(d.timestamp)), 耗时: \(String(format: "%.1f", d.duration))s")
            lines.append("用途: \(d.purpose), 请求ID: \(d.requestID.uuidString)")
            lines.append("Provider: \(d.providerName) (\(d.providerID)), 模型: \(d.model)")
            lines.append("端点: \(d.endpoint)")
            // false + 401 = Key 没读出来（Keychain 问题），不是 Key 填错了。
            lines.append("请求带 Key: \(d.apiKeyAttached ? "是" : "否")")
            if let status = d.httpStatus {
                lines.append("HTTP: \(status)")
            }
            if let code = d.urlErrorCode {
                lines.append("URLError: \(d.urlErrorName ?? "?") (\(code))")
            }
            if let message = d.urlErrorMessage {
                lines.append("URLError 描述: \(message)")
            }
            if let body = d.responseBodyExcerpt, !body.isEmpty {
                lines.append("响应体摘录:")
                lines.append(body)
            }
        } else {
            lines.append("（无 transport 现场：错误来自应用层，如未配置模型或响应解析失败）")
        }
        return lines.joined(separator: "\n")
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String ?? "?"
    }

    /// `iPhone16,2` 这种机型标识——`UIDevice.model` 只有 "iPhone"，对排查没帮助。
    private static var machineIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { bytes in
            String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    /// 复制瞬间的网络状态快照：是否在线、走的什么接口、是否低数据模式。
    private static func networkSnapshot() async -> String {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            // cancel() 之前已入队的更新仍会送达（如恰逢 Wi-Fi↔蜂窝切换），
            // 不挡住第二次回调就是 continuation 双重 resume——必崩。
            let resumed = OSAllocatedUnfairLock(initialState: false)
            monitor.pathUpdateHandler = { path in
                let isFirst = resumed.withLock { done in
                    if done { return false }
                    done = true
                    return true
                }
                guard isFirst else { return }
                monitor.cancel()
                continuation.resume(returning: describe(path))
            }
            monitor.start(queue: DispatchQueue(label: "openkoto.diagnostics.netpath"))
        }
    }

    private static func describe(_ path: NWPath) -> String {
        var parts: [String] = []
        switch path.status {
        case .satisfied: parts.append("在线")
        case .unsatisfied: parts.append("离线")
        case .requiresConnection: parts.append("待连接")
        @unknown default: parts.append("未知")
        }
        var interfaces: [String] = []
        if path.usesInterfaceType(.wifi) { interfaces.append("Wi-Fi") }
        if path.usesInterfaceType(.cellular) { interfaces.append("蜂窝") }
        if path.usesInterfaceType(.wiredEthernet) { interfaces.append("有线") }
        if path.usesInterfaceType(.loopback) { interfaces.append("回环") }
        if path.usesInterfaceType(.other) { interfaces.append("其他") }
        parts.append(interfaces.isEmpty ? "无接口" : interfaces.joined(separator: "+"))
        if path.isExpensive { parts.append("计费网络") }
        if path.isConstrained { parts.append("低数据模式") }
        return parts.joined(separator: ", ")
    }
}
#endif
