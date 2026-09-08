import Foundation
import Security

/// Pins peer identities in the Keychain and derives comparison codes.
enum VibeSecureTrust {

  /// What a peer's freshly-claimed KeyPackage means for trust.
  enum Verdict: Equatable {
    /// First contact; the key is now pinned.
    case pinnedOnFirstContact
    /// Same key as last time. Nothing has changed.
    case matchesPin
    /// Key changed; callers fail closed until the user verifies it.
    case changed(pinned: Data, offered: Data)
  }

  private static let service = "vibe.secure.trust"
  private static let pendingService = "vibe.secure.trust.pending"
  private static let queue = DispatchQueue(label: "vibe.secure.trust")


  /// Pins on first contact and stages changed keys for user verification.
  static func evaluate(signatureKey: Data, userId: String) -> Verdict {
    queue.sync {
      guard let pinned = loadKey(userId: userId) else {
        _ = storeKey(signatureKey, userId: userId)
        deleteKey(userId: userId, service: pendingService)
        return .pinnedOnFirstContact
      }
      if pinned == signatureKey {
        deleteKey(userId: userId, service: pendingService)
        return .matchesPin
      }
      _ = storeKey(signatureKey, userId: userId, service: pendingService)
      return .changed(pinned: pinned, offered: signatureKey)
    }
  }

  /// The key currently pinned for `userId`, if any.
  static func pinnedKey(userId: String) -> Data? {
    queue.sync { loadKey(userId: userId) }
  }

  /// Replaces the MLS pin only after explicit user verification.
  @discardableResult
  static func acceptChange(signatureKey: Data, userId: String) -> Bool {
    queue.sync { storeKey(signatureKey, userId: userId) }
  }

  static func pendingChange(userId: String) -> Data? {
    queue.sync { loadKey(userId: userId, service: pendingService) }
  }

  /// Promotes only the exact identity keys the user verified.
  @discardableResult
  static func acceptPendingChange(userId: String, expectedSignatureKey: Data?) -> Bool {
    queue.sync {
      guard let expectedSignatureKey,
        loadKey(userId: userId, service: pendingService) == expectedSignatureKey
      else { return false }
      let stored = storeKey(expectedSignatureKey, userId: userId)
      if stored { deleteKey(userId: userId, service: pendingService) }
      return stored
    }
  }

  /// Clears all pins only when this device retires its own identity.
  static func clearAllPins() {
    queue.sync {
      for pinService in [service, pendingService] {
        let query: [String: Any] = [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: pinService,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
          VibeLog.error("[VibeSecure] could not clear peer pins: OSStatus \(status)")
          return
        }
      }
      VibeLog.notice("[VibeSecure] cleared every peer identity pin — they re-pin on next contact")
    }
  }

  /// Returns the 60-digit comparison code in groups of five.
  static func safetyNumber(myKey: Data, peerKey: Data) -> String {
    let digits = vibeSafetyNumber(keyA: myKey, keyB: peerKey)
    return stride(from: 0, to: digits.count, by: 5)
      .map { offset -> String in
        let start = digits.index(digits.startIndex, offsetBy: offset)
        let end = digits.index(start, offsetBy: min(5, digits.count - offset))
        return String(digits[start..<end])
      }
      .joined(separator: " ")
  }

  /// The same fingerprint as a hex key block, ungrouped — the view chunks it.
  static func safetyCodeHex(myKey: Data, peerKey: Data) -> String {
    vibeSafetyCodeHex(keyA: myKey, keyB: peerKey)
  }


  private static func loadKey(userId: String, service: String = service) -> Data? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: userId,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data, !data.isEmpty
    else { return nil }
    return data
  }

  private static func deleteKey(userId: String, service: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: userId,
    ]
    SecItemDelete(query as CFDictionary)
  }

  private static func storeKey(_ key: Data, userId: String, service: String = service) -> Bool {
    let attributes: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: userId,
      kSecValueData as String: key,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    SecItemDelete(attributes as CFDictionary)
    return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
  }
}
