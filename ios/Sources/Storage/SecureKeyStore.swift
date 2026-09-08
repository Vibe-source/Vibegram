import Foundation
import Security

/// Thread-safe Keychain wrapper for storing sensitive values (private keys, auth tokens).
/// Uses kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly so secrets survive reboots
/// but are NOT included in device backups or migrations.
final class SecureKeyStore {
  static let shared = SecureKeyStore()

  private let service = "vibe.chat.engine.securekeys"
  private let queue = DispatchQueue(label: "vibe.securekeystore")

  private init() {}

  func storeSecret(key: String, value: String) -> Bool {
    queue.sync {
      guard let data = value.data(using: .utf8) else { return false }
      deleteSecretLocked(key: key)
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: key,
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      ]
      let status = SecItemAdd(query as CFDictionary, nil)
      return status == errSecSuccess
    }
  }

  func retrieveSecret(key: String) -> String? {
    queue.sync {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: key,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var result: AnyObject?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      guard status == errSecSuccess, let data = result as? Data else { return nil }
      return String(data: data, encoding: .utf8)
    }
  }

  /// Whether the item exists at all. Attributes stay readable when the data does not
  /// (locked device), so this separates "nothing stored" from "cannot read it now".
  func hasSecret(key: String) -> Bool {
    queue.sync {
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: key,
        kSecReturnAttributes as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne,
      ]
      var result: AnyObject?
      return SecItemCopyMatching(query as CFDictionary, &result) != errSecItemNotFound
    }
  }

  func deleteSecret(key: String) {
    queue.sync {
      deleteSecretLocked(key: key)
    }
  }

  private func deleteSecretLocked(key: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
    SecItemDelete(query as CFDictionary)
  }

  /// Migrate secrets from a plaintext config dictionary into the Keychain.
  /// Returns a sanitized copy of the config with secrets replaced by sentinels.
  func migrateAndSanitize(_ config: [String: Any]) -> [String: Any] {
    var sanitized = config
    for key in Self.sensitiveKeys {
      if let value = config[key] as? String, !value.isEmpty, value != Self.sentinel {
        _ = storeSecret(key: key, value: value)
        sanitized[key] = Self.sentinel
      }
    }
    return sanitized
  }

  /// Reassemble a config by replacing sentinels with values from secure storage.
  func reassemble(_ config: [String: Any]) -> [String: Any] {
    var assembled = config
    for key in Self.sensitiveKeys {
      if let stored = config[key] as? String, stored == Self.sentinel {
        if let secret = retrieveSecret(key: key) {
          assembled[key] = secret
        }
      }
    }
    return assembled
  }

  static let sentinel = "__SECURE__"
  static let sensitiveKeys = [
    "privateKeyPem",
    "privateKey",
    "authToken",
    "token",
    "packetTicket",
    "loginSecret",
  ]
}
