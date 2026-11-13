import Foundation
import Security

public enum KeychainError: LocalizedError, Sendable {
    case unhandledStatus(OSStatus)
    case invalidData
    case keyNotFound
    
    public var errorDescription: String? {
        switch self {
        case .unhandledStatus(let status):
            if let msg = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error (\(status)): \(msg)"
            }
            return "Keychain error (\(status))"
        case .invalidData:
            return "Failed to encode/decode keychain data."
        case .keyNotFound:
            return "Requested key not found in keychain."
        }
    }
}

public final class KeychainService: @unchecked Sendable {
    public static let shared = KeychainService()
    public static let defaultService = "com.rossonerian.pearl.keys"
    
    // In-memory override for test environments
    private var inMemoryStore: [String: String]?
    private let lock = NSLock()
    
    public init() {}
    
    public func setInMemoryStoreEnabled(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if enabled {
            inMemoryStore = [:]
        } else {
            inMemoryStore = nil
        }
    }
    
    public func saveKey(_ key: String, account: String, service: String = defaultService) throws {
        lock.lock()
        defer { lock.unlock() }
        
        if inMemoryStore != nil {
            inMemoryStore?["\(service):\(account)"] = key
            return
        }
        
        guard let data = key.data(using: .utf8) else {
            throw KeychainError.invalidData
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributesToUpdate as CFDictionary)
            if updateStatus != errSecSuccess {
                throw KeychainError.unhandledStatus(updateStatus)
            }
        } else if status != errSecSuccess {
            throw KeychainError.unhandledStatus(status)
        }
    }
    
    public func loadKey(account: String, service: String = defaultService) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        
        if let store = inMemoryStore {
            return store["\(service):\(account)"]
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unhandledStatus(status)
        }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return key
    }
    
    public func deleteKey(account: String, service: String = defaultService) throws {
        lock.lock()
        defer { lock.unlock() }
        
        if inMemoryStore != nil {
            inMemoryStore?.removeValue(forKey: "\(service):\(account)")
            return
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unhandledStatus(status)
        }
    }
    
    public func maskedKey(account: String, service: String = defaultService) throws -> String? {
        guard let key = try loadKey(account: account, service: service), !key.isEmpty else {
            return nil
        }
        if key.count <= 4 {
            return String(repeating: "•", count: key.count)
        }
        let suffix = key.suffix(4)
        return "••••••••••••\(suffix)"
    }
    
    // MARK: - Redaction Utility
    
    private static let antKeyRegex = try! NSRegularExpression(
        pattern: #"\b(sk-ant-[a-zA-Z0-9_\-]{8,})\b"#,
        options: []
    )
    private static let generalKeyRegex = try! NSRegularExpression(
        pattern: #"\b(sk-[a-zA-Z0-9_\-]{16,})\b"#,
        options: []
    )
    private static let bearerRegex = try! NSRegularExpression(
        pattern: #"\bBearer\s+([a-zA-Z0-9_\-\.]{12,})\b"#,
        options: [.caseInsensitive]
    )
    private static let hexSecretRegex = try! NSRegularExpression(
        pattern: #"\b[0-9a-fA-F]{32,64}\b"#,
        options: []
    )
    
    public static func redact(text: String, additionalSecrets: [String] = []) -> String {
        var result = text
        
        // 1. Redact custom known secrets first
        for secret in additionalSecrets where !secret.isEmpty && secret.count >= 4 {
            result = result.replacingOccurrences(of: secret, with: "[REDACTED_SECRET]")
        }
        
        // 2. Redact Anthropic keys
        let antRange = NSRange(location: 0, length: result.utf16.count)
        result = antKeyRegex.stringByReplacingMatches(
            in: result,
            options: [],
            range: antRange,
            withTemplate: "[REDACTED_API_KEY]"
        )
        
        // 3. Redact general sk- keys
        let genRange = NSRange(location: 0, length: result.utf16.count)
        result = generalKeyRegex.stringByReplacingMatches(
            in: result,
            options: [],
            range: genRange,
            withTemplate: "[REDACTED_API_KEY]"
        )
        
        // 4. Redact Bearer tokens
        let bearerRange = NSRange(location: 0, length: result.utf16.count)
        result = bearerRegex.stringByReplacingMatches(
            in: result,
            options: [],
            range: bearerRange,
            withTemplate: "Bearer [REDACTED_TOKEN]"
        )
        
        // 5. Redact Hex secrets
        let hexRange = NSRange(location: 0, length: result.utf16.count)
        result = hexSecretRegex.stringByReplacingMatches(
            in: result,
            options: [],
            range: hexRange,
            withTemplate: "[REDACTED_HEX_SECRET]"
        )
        
        return result
    }
    
    public func redact(text: String) -> String {
        var knownKeys: [String] = []
        if let key = try? loadKey(account: "anthropic") {
            knownKeys.append(key)
        }
        if let key = try? loadKey(account: "anthropic_api_key") {
            knownKeys.append(key)
        }
        return KeychainService.redact(text: text, additionalSecrets: knownKeys)
    }
}
