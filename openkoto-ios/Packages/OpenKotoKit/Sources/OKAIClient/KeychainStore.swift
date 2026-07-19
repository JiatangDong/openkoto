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

    /// 写入/更新某个模型配置的 API Key。空串等价于删除。
    @discardableResult
    public func setKey(_ key: String, for id: UUID) -> Bool {
        guard !key.isEmpty else {
            return deleteKey(for: id)
        }
        let account = id.uuidString
        let data = Data(key.utf8)

        // 已存在则更新，否则新增。
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8)
        else { return nil }
        return key
    }

    /// 是否已配置 Key（设置页 SecureField 只显示“已配置”，不回显）。
    public func hasKey(for id: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// 删除某个模型配置的 Key。
    @discardableResult
    public func deleteKey(for id: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
