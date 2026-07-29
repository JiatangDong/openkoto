import Foundation
import Security

/// API Key 的 Keychain 存取（设计文档 §4.5）。
///
/// - `kSecClassGenericPassword`，service = `app.openkoto.ios.apikey`，account = `ModelConfig.id`。
/// - 默认 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`：不进 iCloud Keychain 同步，
///   也不需要锁屏后台访问。
/// - 删除模型配置时必须同步删除对应 Key；更新 ID 不得遗留孤儿 Key（由上层 AppConfigStore 协调）。
public struct KeychainStore: Sendable {
    public static let defaultService = "app.openkoto.ios.apikey"

    private let service: String

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    /// 四个查询共用的基底。
    ///
    /// `kSecUseDataProtectionKeychain` 必须**四个查询全带**：Mac（Catalyst / 原生）上
    /// 不带这个标志会落到老的 file-based keychain，`kSecAttrAccessible` 被忽略，
    /// 而且跨进程访问会弹授权框。只给一部分查询带的话，会出现
    /// "写进了 data-protection keychain、读却去 file-based 找" —— 表现为
    /// 用户明明配好了 API Key，重启后 App 说没配。
    ///
    /// iOS 上该标志默认就是 true，显式写等于无操作，不影响存量用户的 Key。
    private func baseQuery(account: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.uuidString,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// 写入/更新某个模型配置的 API Key。空串等价于删除。
    @discardableResult
    public func setKey(_ key: String, for id: UUID) -> Bool {
        guard !key.isEmpty else {
            return deleteKey(for: id)
        }
        let data = Data(key.utf8)

        // 已存在则更新，否则新增。
        let query = baseQuery(account: id)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    /// 读取某个模型配置的 API Key（不存在返回 nil）。
    public func key(for id: UUID) -> String? {
        var query = baseQuery(account: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8)
        else { return nil }
        return key
    }

    /// 是否已配置 Key（设置页 SecureField 只显示“已配置”，不回显）。
    public func hasKey(for id: UUID) -> Bool {
        var query = baseQuery(account: id)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// 删除某个模型配置的 Key。
    @discardableResult
    public func deleteKey(for id: UUID) -> Bool {
        let status = SecItemDelete(baseQuery(account: id) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
