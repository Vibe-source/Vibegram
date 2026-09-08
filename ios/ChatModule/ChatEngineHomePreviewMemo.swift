import Foundation

/// Decrypted Home previews, readable from any thread without touching the engine queue.
///
/// # Why this exists
///
/// Home renders its list on the main thread and asks for one decrypted preview per
/// visible row. That ask used to be `syncOnQueue { … decrypt … }`, so every row waited
/// on whatever the engine happened to be doing. Measured on device, 2026-08-03:
///
/// ```
/// syncOnQueue blocked main thread for 772ms at makeHomePreviewText(_:)
/// main-thread-stall blockedMs=31504 context=ChatHomeNativeListController apply nextRows=15
/// ```
///
/// Two of the four measured scroll costs in
/// `docs/production-timeline-core-refactor.md` §0 meet there: per-row E2E decrypt during
/// parse, and `queue.sync` from main. Neither is fixed by making the decrypt faster —
/// the wait is the cost, and any main-thread reader is exposed to the full duration of
/// whatever the queue is running.
///
/// # Bounded on purpose
///
/// Previews are plaintext. Holding one per message the user has ever scrolled past
/// would be both a memory leak and a widening of how long plaintext lives in this
/// process (`docs/production-timeline-core-refactor.md` §4.6). Home shows a bounded
/// number of chats, so the memo is bounded to a small multiple of that and evicts the
/// least recently read.
final class ChatEngineHomePreviewMemo: @unchecked Sendable {
  /// Home lists tens of chats; a few hundred previews covers scrolling it plus recent
  /// churn, and is small enough that eviction is never the interesting behaviour.
  private static let capacity = 400

  private let lock = NSLock()
  /// `String?` rather than `String`: a miss and a *known-undecryptable* row are
  /// different answers. Collapsing them re-schedules the same failing decrypt on every
  /// render pass, forever.
  private var entries: [String: String?] = [:]
  /// Read order, least recent first.
  private var order: [String] = []
  /// Keys currently being decrypted, so a re-render mid-flight does not schedule the
  /// same work again — fifteen rows re-asking would otherwise queue fifteen copies.
  private var inFlight: Set<String> = []

  private(set) var hits = 0
  private(set) var misses = 0

  /// The memoized preview, or `nil` when nothing has been computed for this key.
  ///
  /// Double-optional: the outer `nil` is "not computed", the inner is "computed, and
  /// this row has no usable preview".
  func value(for key: String) -> String?? {
    lock.lock()
    defer { lock.unlock() }
    guard let entry = entries[key] else {
      misses += 1
      return nil
    }
    hits += 1
    touchLocked(key)
    return entry
  }

  /// Claims a key for decryption. `false` means someone else already has it.
  func beginIfNotInFlight(_ key: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard entries[key] == nil, !inFlight.contains(key) else { return false }
    inFlight.insert(key)
    return true
  }

  /// Publishes a computed preview and releases the claim.
  func finish(_ key: String, value: String?) {
    lock.lock()
    defer { lock.unlock() }
    inFlight.remove(key)
    if entries.updateValue(value, forKey: key) == nil {
      order.append(key)
    } else {
      touchLocked(key)
    }
    evictLocked()
  }

  /// Drops everything. Called on logout — plaintext must not outlive the session.
  func clear() {
    lock.lock()
    defer { lock.unlock() }
    entries.removeAll()
    order.removeAll()
    inFlight.removeAll()
  }

  var counts: (hits: Int, misses: Int, entries: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (hits, misses, entries.count)
  }

  private func touchLocked(_ key: String) {
    guard let index = order.firstIndex(of: key) else { return }
    order.remove(at: index)
    order.append(key)
  }

  private func evictLocked() {
    while order.count > Self.capacity, let oldest = order.first {
      order.removeFirst()
      entries.removeValue(forKey: oldest)
    }
  }
}
