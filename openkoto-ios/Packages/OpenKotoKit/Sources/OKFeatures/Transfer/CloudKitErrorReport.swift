#if os(iOS)
import CloudKit
import Foundation

/// 把 `CKError` 展开成人能看懂的一段话。
///
/// `localizedDescription` 对 CloudKit 基本没用 —— 全是
/// "The operation couldn't be completed. (CKErrorDomain error 15.)" 这种，
/// 既不告诉你 15 是什么，也不告诉你服务端到底拒绝了什么。
/// 真正有用的信息藏在 `userInfo` 里：服务端原话、局部失败的逐条错误、底层错误链。
enum CloudKitErrorReport {
    static func describe(_ error: Error) -> String {
        guard let ckError = error as? CKError else {
            return error.localizedDescription
        }
        var lines: [String] = ["\(codeName(ckError.code)) (\(ckError.errorCode))"]

        // 服务端的原话。CloudKit 常把真正的原因放在这里，
        // 比如"record type not found"、"invalid record name"。
        if let serverMessage = ckError.userInfo["ServerErrorDescription"] as? String {
            lines.append(serverMessage)
        } else if let description = ckError.userInfo[NSLocalizedDescriptionKey] as? String,
            !description.hasPrefix("The operation couldn")
        {
            lines.append(description)
        }

        // 批量操作里哪几条挂了、各自为什么。整批失败时这是唯一能定位到具体记录的线索。
        if let partial = ckError.partialErrorsByItemID, !partial.isEmpty {
            let details = partial.prefix(3).map { key, value in
                let inner = (value as? CKError).map { "\(codeName($0.code))" } ?? "\(value)"
                return "\(key): \(inner)"
            }
            lines.append(details.joined(separator: "; "))
            if partial.count > 3 { lines.append("…共 \(partial.count) 条") }
        }

        if let underlying = ckError.userInfo[NSUnderlyingErrorKey] as? NSError {
            lines.append("← \(underlying.domain) \(underlying.code)")
        }
        if let retryAfter = ckError.retryAfterSeconds {
            lines.append("可在 \(Int(retryAfter))s 后重试")
        }
        return lines.joined(separator: "\n")
    }

    /// CloudKit 的错误码名。数字本身对排查毫无帮助，名字才有。
    static func codeName(_ code: CKError.Code) -> String {
        switch code {
        case .internalError: return "internalError"
        case .partialFailure: return "partialFailure"
        case .networkUnavailable: return "networkUnavailable"
        case .networkFailure: return "networkFailure"
        case .badContainer: return "badContainer"
        case .serviceUnavailable: return "serviceUnavailable"
        case .requestRateLimited: return "requestRateLimited"
        case .missingEntitlement: return "missingEntitlement"
        case .notAuthenticated: return "notAuthenticated"
        case .permissionFailure: return "permissionFailure"
        case .unknownItem: return "unknownItem"
        case .invalidArguments: return "invalidArguments"
        case .serverRecordChanged: return "serverRecordChanged"
        case .serverRejectedRequest: return "serverRejectedRequest"
        case .assetFileNotFound: return "assetFileNotFound"
        case .incompatibleVersion: return "incompatibleVersion"
        case .constraintViolation: return "constraintViolation"
        case .changeTokenExpired: return "changeTokenExpired"
        case .batchRequestFailed: return "batchRequestFailed"
        case .zoneBusy: return "zoneBusy"
        case .badDatabase: return "badDatabase"
        case .quotaExceeded: return "quotaExceeded"
        case .zoneNotFound: return "zoneNotFound"
        case .limitExceeded: return "limitExceeded"
        case .userDeletedZone: return "userDeletedZone"
        case .accountTemporarilyUnavailable: return "accountTemporarilyUnavailable"
        default: return "CKError(\(code.rawValue))"
        }
    }
}
#endif
