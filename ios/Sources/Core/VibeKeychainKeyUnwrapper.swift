import Foundation
import Security

/// Thread-safe handoff of the RSA private key from the engine to the core.
///
/// # Why a box instead of asking the engine
///
/// The obvious wiring — have the unwrapper call back into `ChatEngine` for the
/// key — would put a `queue.sync` from the **core's worker thread** into the
/// engine's serial queue. That is precisely the `[ChatEngine][MAIN-THREAD-HANG]`
/// shape this migration exists to delete, just pointed at a different thread: the
/// core would stall behind whatever the engine happened to be doing, and a core
/// that blocks on the engine is not an independent pipeline.
///
/// So the key is *pushed*, not pulled. The engine publishes the `SecKey` it has
/// already resolved on its own queue; the core reads it behind an uncontended
/// lock and never waits on anything.
///
/// A `SecKey` is a handle, not key bytes — it is the Keychain's reference to a
/// key it holds. Storing one here does not put private key material in this
/// process's heap.
final class VibeCorePrivateKeyBox: @unchecked Sendable {
  static let shared = VibeCorePrivateKeyBox()

  private let lock = NSLock()
  private var key: SecKey?

  private init() {}

  /// Publishes the current key. `nil` on logout or when the Keychain is locked —
  /// which correctly makes every subsequent unwrap fail closed.
  func publish(_ key: SecKey?) {
    lock.lock()
    self.key = key
    lock.unlock()
  }

  func current() -> SecKey? {
    lock.lock()
    defer { lock.unlock() }
    return key
  }
}

/// Platform-side private-key custody for the Rust core.
///
/// # This is the only cryptography Swift keeps
///
/// Everything else in the message pipeline — envelope parsing, AES-GCM open,
/// canonicalization, ordering, dedup — moves into `vibe_core`. This one operation
/// cannot: the RSA private key lives in the Keychain as a `SecKey`, and a `SecKey`
/// is a handle to a key the Secure Enclave or the keychain daemon holds. It has no
/// byte representation that could cross an FFI boundary, and giving one to Rust
/// would mean exporting the private key, which is precisely the thing that must
/// never happen.
///
/// So the split is: **Rust decides which wrapped keys to try and in what order;
/// Swift performs the private-key operation; Rust opens the payload.** The private
/// key never leaves this process boundary, and the core never sees it.
///
/// # One call per ingest batch
///
/// A 100-message history page is 100 RSA operations at roughly 0.3–1 ms each on an
/// A18 — 30–100 ms. That happens **once**, on the core's worker thread, and never
/// again for those rows, because the durable store keeps the opened form sealed
/// under the store key. This type must therefore never be called from the main
/// thread, and nothing here dispatches to it.
///
/// # The contract this must not break
///
/// The core pairs answers to requests **positionally**. Returning a different
/// number of slots than it asked for makes every key ambiguous, so the core
/// discards the whole batch. This implementation always appends exactly one slot
/// per request, on every path including failure.
final class VibeKeychainKeyUnwrapper: VibeFfiKeyUnwrapper {
  /// Resolves the current private key.
  ///
  /// A closure rather than a stored `SecKey` because the key is not a constant:
  /// it is cached behind a TTL, dropped on logout, and absent until the user has
  /// a session. Capturing one at construction would pin a stale handle and keep
  /// key material alive past the lifetime its owner chose for it.
  private let privateKey: () -> SecKey?

  /// Counters for diagnostics. Counts only — never which candidate opened, never
  /// a message id, never bytes.
  private let lock = NSLock()
  private(set) var opened = 0
  private(set) var refused = 0

  init(privateKey: @escaping () -> SecKey?) {
    self.privateKey = privateKey
  }

  /// Unwraps one batch of content keys.
  ///
  /// Returns, per request and in order, the first candidate that unwrapped to a
  /// plausible AES-256 key, or `nil`. A `nil` is not an error path — it is the
  /// shipped behaviour when the Keychain is locked or the message was sealed to a
  /// key this device does not hold, and it renders the decryption-failure state.
  func unwrapAesKeys(requests: [VibeFfiKeyRequest]) -> [Data?] {
    guard !requests.isEmpty else { return [] }

    // Resolved once for the whole batch. Re-resolving per message would re-enter
    // the key's TTL bookkeeping a hundred times for one page.
    guard let key = privateKey() else {
      // Locked Keychain or signed-out session. Exactly one slot per request, so
      // the core sees "none of these opened" rather than a length mismatch.
      recordLocked(opened: 0, refused: requests.count)
      // Named, because this is the one failure mode that looks identical to "sealed to
      // another device" from the render side and has a completely different fix. Both
      // arrive as `decryptFailed=N` in `[VibeCore] window` with nothing to tell them
      // apart — that number has been unactionable for exactly this reason.
      VibeLog.error(
        "core unwrap refused every key — no private key (locked Keychain or signed out)",
        category: "crypto", metadata: ["batch": String(requests.count)])
      return Array(repeating: nil, count: requests.count)
    }

    var results: [Data?] = []
    results.reserveCapacity(requests.count)
    var openedCount = 0

    for request in requests {
      var unwrapped: Data?
      // Order is the core's, and it is direction-dependent: group slot first,
      // then sender-before-recipient for own messages and the reverse for peer
      // messages. Reordering here would change which historical messages open.
      for candidate in request.candidates {
        guard let plain = Self.rsaDecryptOAEP(privateKey: key, encrypted: candidate) else {
          continue
        }
        // A wrong-length result is refused rather than padded. An AES-256 content
        // key is 32 bytes; anything else means this candidate was not the key,
        // and using it would decrypt under something the sender never used.
        guard plain.count == Self.aesKeyLength else { continue }
        unwrapped = plain
        break
      }
      if unwrapped != nil { openedCount += 1 }
      results.append(unwrapped)
    }

    let refusedCount = requests.count - openedCount
    recordLocked(opened: openedCount, refused: refusedCount)
    // The counters above have existed since this file was written and have never been
    // printed anywhere, which is why `decryptFailed=12` was a dead end: it says twelve
    // rows render as failures, not whether the private key refused them here or the
    // AES-GCM open refused them in the core afterwards. Those have different causes
    // (a key this device does not hold vs. a corrupt/ill-formed envelope) and different
    // fixes. `refused > 0` is the discriminator, and it belongs at the seam.
    //
    // Counts only. Never a message id, never which candidate opened — the doc on this
    // type is explicit that revealing which slot succeeded leaks send-vs-receive to
    // anything watching the boundary.
    if refusedCount > 0 {
      VibeLog.warning(
        "core unwrap refused a key — sealed to a key this device does not hold",
        category: "crypto",
        metadata: [
          "batch": String(requests.count),
          "opened": String(openedCount),
          "refused": String(refusedCount),
        ])
    }
    // Invariant the core depends on. Cheap to assert, catastrophic to violate.
    assert(results.count == requests.count, "unwrapper must answer positionally")
    return results
  }

  private static let aesKeyLength = 32

  /// RSA-2048-OAEP-SHA256 unwrap.
  ///
  /// The `CFError` is drained and dropped: it distinguishes "wrong key" from
  /// "malformed ciphertext", and surfacing that difference to a caller — or to a
  /// log — is a decryption oracle. A failure is a failure.
  private static func rsaDecryptOAEP(privateKey: SecKey, encrypted: Data) -> Data? {
    var error: Unmanaged<CFError>?
    let decrypted =
      SecKeyCreateDecryptedData(
        privateKey,
        .rsaEncryptionOAEPSHA256,
        encrypted as CFData,
        &error
      ) as Data?
    _ = error?.takeRetainedValue()
    return decrypted
  }

  private func recordLocked(opened openedDelta: Int, refused refusedDelta: Int) {
    lock.lock()
    opened += openedDelta
    refused += refusedDelta
    lock.unlock()
  }

  var counts: (opened: Int, refused: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (opened, refused)
  }
}
