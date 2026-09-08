import Foundation
import Security

/// Custody of the per-install store key used to seal `core_messages_v1`.
///
/// # Why this is not `SecureKeyStore`
///
/// `SecureKeyStore` stores `String` values. Putting 32 bytes of key material
/// through a Swift `String` means base64-encoding it, holding it in a
/// non-zeroizable buffer, and leaving copies wherever the string was passed.
/// This type keeps the key as `Data` end to end and hands it straight to the
/// Rust sealer. Same Keychain service conventions, same accessibility class —
/// only the value type differs, and it differs for a reason.
///
/// # Accessibility class
///
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, matching the RSA private
/// key (`SecureKeyStore.swift:24`). This is deliberate and must not be
/// "hardened" to `WhenUnlocked`: push wake-ups and background refresh write to
/// the store while the device is locked, and a stricter class makes those writes
/// fail rather than making them safer. `ThisDeviceOnly` keeps the key out of
/// backups and device migrations — a restored backup gets a fresh key and
/// re-backfills, which is correct, because a sealed store is worthless without
/// the key that sealed it.
enum VibeCoreStoreKey {

  /// AES-256.
  static let lengthBytes = 32

  private static let service = "vibe.core.store"
  private static let account = "core_store_key_v1"
  private static let queue = DispatchQueue(label: "vibe.core.storekey")

  /// Returns the existing key, or generates and persists one.
  ///
  /// Returns `nil` rather than trapping when the Keychain refuses. A device that
  /// cannot hold a key must fall back to the legacy path, not crash and not
  /// silently seal under something predictable.
  static func loadOrCreate() -> Data? {
    queue.sync {
      let existing = loadLocked()
      if let key = existing.key {
        // A key of the wrong width means a corrupt or partially-written item.
        // Replacing it is safe: the sealed store is derived data and is rebuilt
        // by the backfill.
        if key.count == lengthBytes { return key }
        VibeLog.error("[VibeCore] store key wrong width — regenerating")
        deleteLocked()
        return createLocked()
      }
      // "Absent" and "temporarily unreadable" are NOT the same thing, and only
      // the first may mint a new key. The item is
      // `kSecAttrAccessibleAfterFirstUnlock`, so a background launch before the
      // first unlock after a reboot returns `errSecInteractionNotAllowed` — and
      // minting there would delete the key that every already-sealed row on disk
      // depends on, turning the user's whole local history into unreadable
      // bytes. Fail closed: the caller falls back to plaintext for this launch,
      // which is recoverable; losing the key is not.
      guard existing.status == errSecItemNotFound else {
        VibeLog.error(
          "[VibeCore] store key unavailable (status=\(existing.status)) — NOT regenerating")
        return nil
      }
      return createLocked()
    }
  }

  /// Removes the key. The sealed store becomes unreadable and must be rebuilt.
  ///
  /// This is the logout path: dropping the key is what makes the sealed rows
  /// unrecoverable, which is the point of sealing them.
  static func destroy() {
    queue.sync { deleteLocked() }
  }

  static var exists: Bool {
    queue.sync { loadLocked().key != nil }
  }

  // MARK: - Keychain

  /// Returns the key *and* the raw status, because the caller's decision depends
  /// on which kind of "no key" this is — see ``loadOrCreate``.
  private static func loadLocked() -> (key: Data?, status: OSStatus) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { return (nil, status) }
    return (data, status)
  }

  private static func createLocked() -> Data? {
    var bytes = [UInt8](repeating: 0, count: lengthBytes)
    let rc = SecRandomCopyBytes(kSecRandomDefault, lengthBytes, &bytes)
    guard rc == errSecSuccess else {
      // Never fall back to any other source of randomness here. A weak store key
      // is worse than no sealing at all, because the column would be named
      // `sealed_body` and everyone downstream would believe it.
      VibeLog.error("[VibeCore] SecRandomCopyBytes failed rc=\(rc)")
      return nil
    }
    var data = Data(bytes)
    // Scrub our stack copy. The `Data` still holds the key, and Swift gives no
    // guarantee about buffers it has already copied — see the honest limit in
    // vibe_core_ffi/src/seal.rs. This removes one avoidable copy, not all of them.
    for i in bytes.indices { bytes[i] = 0 }

    deleteLocked()
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else {
      VibeLog.error("[VibeCore] store key SecItemAdd failed status=\(status)")
      data.resetBytes(in: 0..<data.count)
      return nil
    }
    VibeLog.info("[VibeCore] generated a new store key")
    return data
  }

  private static func deleteLocked() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(query as CFDictionary)
  }
}
