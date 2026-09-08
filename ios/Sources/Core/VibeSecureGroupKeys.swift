import Foundation
import Security

/// Custody of group epoch keys — the layer that covers what MLS cannot.
///
/// # Which chats land here, and why there are two layers
///
/// DMs and ordinary groups are MLS (`VibeSecureSessions`). Two kinds cannot be:
///
/// * **Channels.** MLS gives a joiner no way to read anything sent before they
///   joined. That is a feature everywhere except a broadcast channel, where
///   reading the backlog is the entire point.
/// * **Groups past the MLS member cap.** Adding N members is an O(N) tree
///   operation with an O(N) Welcome fan-out; past the cap that stops being
///   something a phone should do on a join.
///
/// An epoch key handles both: history is readable by anyone *given* the older
/// epoch key, and adding a member costs one key delivery.
///
/// The two layers never overlap. A chat is one or the other, and the envelope
/// prefix (`vmls1.` vs `vgrp2.`) says which, so a reader never guesses.
///
/// # Why the Keychain, and why `ThisDeviceOnly`
///
/// An epoch key is read access to a group's history. `UserDefaults` is a plist
/// readable by anything with file access, so storing keys there would mean the
/// encryption protects the message in transit and then leaves the key beside it
/// at rest.
///
/// `ThisDeviceOnly` because a key restored onto a *different* device from an
/// iCloud backup is exactly the thing the group never agreed to: membership was
/// granted to a device, and a backup restore is not a membership change that
/// anyone approved. The same reasoning governs the MLS store and the identity
/// pins in `VibeSecureTrust`.
///
/// # What this type will not do
///
/// It will not hand a key back out after installing it. `mintEpoch` returns key
/// material — once, to the device that is about to distribute it — and after
/// that the keyring is write-only. There is deliberately no `key(for:)`.
final class VibeSecureGroupKeys {

  static let shared = VibeSecureGroupKeys()

  private static let service = "vibe.secure.groupkeys"

  /// Serializes keyring access. The Rust side is already `Mutex`-guarded per
  /// keyring, but the cache and the Keychain round-trip around it are not, and
  /// two threads first-touching the same chat would otherwise build two keyrings
  /// and race to fill them.
  private let queue = DispatchQueue(label: "vibe.secure.groupkeys")

  /// One keyring per chat, built on first use from the Keychain.
  private var keyrings: [String: VibeGroupKeyringHandle] = [:]

  private init() {}

  // ── minting and installing ──────────────────────────────────────────────

  /// Mints a fresh epoch key for `chatId`, installs it, and returns it **once**
  /// so the caller can seal it to each member.
  ///
  /// The returned bytes are the only copy that ever leaves this type. The caller
  /// must deliver them over a channel that is already end-to-end encrypted and
  /// must not persist them anywhere else — this type is already persisting the
  /// authoritative copy.
  ///
  /// `epoch` must be strictly newer than anything held, which is what makes a
  /// rotation a rotation rather than a rollback onto a key a removed member
  /// still has.
  func mintEpoch(chatId: String, epoch: UInt32) -> Data? {
    queue.sync {
      guard let keyring = keyringLocked(chatId: chatId) else { return nil }
      guard let key = try? vibeGroupMintEpochKey() else { return nil }
      do {
        try keyring.installEpoch(epoch: epoch, key: key)
      } catch {
        return nil
      }
      persistLocked(chatId: chatId, epoch: epoch, key: key)
      return key
    }
  }

  /// Installs a key for a **strictly newer** epoch, received from the group's
  /// key authority.
  @discardableResult
  func installEpoch(chatId: String, epoch: UInt32, key: Data) -> Bool {
    queue.sync {
      guard let keyring = keyringLocked(chatId: chatId) else { return false }
      do {
        try keyring.installEpoch(epoch: epoch, key: key)
      } catch {
        return false
      }
      persistLocked(chatId: chatId, epoch: epoch, key: key)
      return true
    }
  }

  /// Installs a key for an epoch **older** than the newest held, so history
  /// granted to a new member becomes readable.
  ///
  /// Separate from `installEpoch` on purpose: this is the one operation that
  /// legitimately moves backwards, so it is named rather than inferred, and a
  /// frame that merely looks like a rotation can never reach it.
  @discardableResult
  func backfillEpoch(chatId: String, epoch: UInt32, key: Data) -> Bool {
    queue.sync {
      guard let keyring = keyringLocked(chatId: chatId) else { return false }
      do {
        try keyring.backfillEpoch(epoch: epoch, key: key)
      } catch {
        return false
      }
      persistLocked(chatId: chatId, epoch: epoch, key: key)
      return true
    }
  }

  /// The newest epoch this device can seal under, or `nil` when it holds no key
  /// for the chat at all — which is the signal to request one before sending.
  func newestEpoch(chatId: String) -> UInt32? {
    queue.sync {
      guard let keyring = keyringLocked(chatId: chatId) else { return nil }
      return try? keyring.newestEpoch() ?? nil
    }
  }

  func hasEpoch(chatId: String, epoch: UInt32) -> Bool {
    queue.sync {
      guard let keyring = keyringLocked(chatId: chatId) else { return false }
      return (try? keyring.hasEpoch(epoch: epoch)) ?? false
    }
  }

  // ── sealing and opening ─────────────────────────────────────────────────

  /// Seals under the newest held epoch, but only when *every* member can read
  /// the format.
  ///
  /// `totalMembers` and `capableMembers` are passed down to a Rust type that has
  /// no constructor skipping the check. Turning group encryption on for a chat
  /// where one member's client does not understand `vgrp2.` does not weaken that
  /// member — it silently removes them from the conversation, and that is not
  /// recoverable after the fact.
  ///
  /// Returns `nil` rather than throwing so the caller's send path can fall back
  /// to its existing behaviour on any failure, exactly as the MLS seal does.
  func seal(chatId: String, plaintext: String, totalMembers: UInt32, capableMembers: UInt32)
    -> String?
  {
    guard let data = plaintext.data(using: .utf8) else { return nil }
    return queue.sync {
      guard let keyring = keyringLocked(chatId: chatId) else { return nil }
      return try? keyring.seal(
        totalMembers: totalMembers, capableMembers: capableMembers, plaintext: data)
    }
  }

  /// Opens a `vgrp2.` envelope, or `nil` when this device lacks the epoch key it
  /// names.
  ///
  /// A `nil` here means "ask for epoch N", not "this message is empty" — the
  /// caller must render the row as undecryptable rather than blank. Use
  /// `missingEpoch(for:)` to learn which key to request.
  func open(chatId: String, envelope: String) -> String? {
    queue.sync {
      guard let keyring = keyringLocked(chatId: chatId),
        let opened = try? keyring.open(envelope: envelope)
      else { return nil }
      return String(data: opened, encoding: .utf8)
    }
  }

  /// True when `raw` is a group envelope this layer owns.
  static func isGroupEnvelope(_ raw: String) -> Bool {
    vibeGroupIsEnvelope(raw: raw)
  }

  /// The epoch an unopenable envelope names, so the client can request exactly
  /// the key it is missing instead of re-requesting everything.
  func missingEpoch(for envelope: String, chatId: String) -> UInt32? {
    guard let epoch = vibeGroupEnvelopeEpoch(raw: envelope) else { return nil }
    return hasEpoch(chatId: chatId, epoch: epoch) ? nil : epoch
  }

  // ── persistence ─────────────────────────────────────────────────────────

  /// Builds (or returns) the keyring for `chatId`, seeding it from the Keychain.
  ///
  /// Seeding uses `backfillEpoch` for every key rather than `installEpoch`
  /// because the stored set is not necessarily ascending in dictionary order and
  /// `installEpoch` would reject anything out of order. Restoring what this
  /// device already legitimately holds is not a rotation, so the monotonicity
  /// rule has nothing to protect against here.
  private func keyringLocked(chatId: String) -> VibeGroupKeyringHandle? {
    if let existing = keyrings[chatId] { return existing }
    let keyring = VibeGroupKeyringHandle(groupId: chatId)
    for (epoch, key) in storedKeysLocked(chatId: chatId).sorted(by: { $0.key < $1.key }) {
      // First install must be `installEpoch` (the ring is empty); the rest are
      // ascending so either call would do. Using backfill throughout keeps this
      // one path rather than two.
      _ = try? keyring.backfillEpoch(epoch: epoch, key: key)
    }
    keyrings[chatId] = keyring
    return keyring
  }

  private func persistLocked(chatId: String, epoch: UInt32, key: Data) {
    var stored = storedKeysLocked(chatId: chatId)
    stored[epoch] = key
    // Bounded to match the Rust keyring's own retention, so the Keychain cannot
    // grow without limit for a long-lived channel. Oldest goes first: scroll-back
    // reaches for recent history far more often than for a group's beginning.
    let retention = Int(vibeGroupEpochRetention())
    if stored.count > retention {
      for epoch in stored.keys.sorted().prefix(stored.count - retention) {
        stored.removeValue(forKey: epoch)
      }
    }
    writeStoredKeysLocked(chatId: chatId, keys: stored)
  }

  private func storedKeysLocked(chatId: String) -> [UInt32: Data] {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: chatId,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data,
      let raw = try? PropertyListSerialization.propertyList(
        from: data, options: [], format: nil) as? [String: Data]
    else { return [:] }

    var keys: [UInt32: Data] = [:]
    for (epochString, key) in raw {
      guard let epoch = UInt32(epochString) else { continue }
      keys[epoch] = key
    }
    return keys
  }

  private func writeStoredKeysLocked(chatId: String, keys: [UInt32: Data]) {
    var raw: [String: Data] = [:]
    for (epoch, key) in keys { raw[String(epoch)] = key }
    guard
      let data = try? PropertyListSerialization.data(
        fromPropertyList: raw, format: .binary, options: 0)
    else { return }

    let attributes: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: Self.service,
      kSecAttrAccount as String: chatId,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    SecItemDelete(attributes as CFDictionary)
    SecItemAdd(attributes as CFDictionary, nil)
  }

  /// Drops every epoch key for one chat — leaving the group, or being removed.
  ///
  /// Keeping them would not let us read anything new (we never receive another
  /// epoch), but it would leave read access to history on a device that is no
  /// longer a member, which is the state the epoch design exists to end.
  func discard(chatId: String) {
    queue.sync {
      keyrings.removeValue(forKey: chatId)
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: Self.service,
        kSecAttrAccount as String: chatId,
      ]
      SecItemDelete(query as CFDictionary)
    }
  }
}
