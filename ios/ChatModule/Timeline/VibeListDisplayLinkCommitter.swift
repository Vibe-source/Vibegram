import Foundation
import QuartzCore
import UIKit

// MARK: - Timing observation (no content)

/// Frame-commit timing. Identifiers and durations only — never message bodies.
struct VibeListCommitTimingObservation: Sendable, Equatable {
  let baseGeneration: UInt64
  let nextGeneration: UInt64
  let opCount: Int
  /// How many enqueued transactions were merged into this commit.
  let coalescedCount: Int
  let enqueueUptime: CFTimeInterval
  let commitUptime: CFTimeInterval
  /// Main-thread commit handler duration in milliseconds.
  let mainThreadDurationMs: Double
  let wasCancelled: Bool
}

// MARK: - Pending entry

private struct VibeListPendingCommit: Sendable {
  let transaction: VibeListTransaction
  let enqueueUptime: CFTimeInterval
}

// MARK: - Display-link proxy (breaks CADisplayLink ↔ owner retain cycle)

/// NSObject target for `CADisplayLink`. Holds a weak back-reference only.
/// The link runs on the main run loop; `assumeIsolated` matches that contract.
private final class VibeListDisplayLinkProxy: NSObject {
  nonisolated(unsafe) weak var owner: VibeListDisplayLinkCommitter?

  @objc func handleDisplayLink(_ link: CADisplayLink) {
    MainActor.assumeIsolated {
      owner?.handleDisplayLinkTick(link)
    }
  }
}

// MARK: - Display-link committer

/// Main-actor list transaction scheduler.
///
/// - Coalesces bursts to **at most one atomic commit per display frame**.
/// - Preserves enqueue order and continuous generation chains.
/// - Supports cancel (drop pending) and invalidate (tear down link).
/// - Exposes timing observations without logging content.
///
/// UIKit is intentionally used here (CADisplayLink / main run loop).
/// Call `invalidate()` before release; the proxy keeps the link from retaining `self`.
@MainActor
final class VibeListDisplayLinkCommitter {
  typealias CommitHandler = (VibeListTransaction) -> Void
  typealias TimingHandler = (VibeListCommitTimingObservation) -> Void

  private var displayLink: CADisplayLink?
  private let proxy = VibeListDisplayLinkProxy()
  private var pending: [VibeListPendingCommit] = []
  private var isInvalidated = false

  /// Invoked on the main actor with the coalesced transaction for this frame.
  var onCommit: CommitHandler?
  /// Optional timing sink (metrics / harness). Must not log message bodies.
  var onTiming: TimingHandler?

  /// Number of transactions waiting for the next frame.
  var pendingCount: Int { pending.count }

  /// Whether `invalidate()` has been called.
  var isValid: Bool { !isInvalidated }

  init() {
    proxy.owner = self
  }

  // MARK: Enqueue

  /// Enqueues a transaction. Immediate-deadline commits apply now (still atomic);
  /// display-link deadlines wait for the next frame and may coalesce.
  func enqueue(_ transaction: VibeListTransaction) {
    precondition(Thread.isMainThread, "VibeListDisplayLinkCommitter requires main thread")
    guard !isInvalidated else { return }

    let entry = VibeListPendingCommit(
      transaction: transaction,
      enqueueUptime: CACurrentMediaTime()
    )

    if transaction.commitDeadline == .immediate {
      // Flush every already-queued chain first to preserve enqueue order. A single
      // flush may leave a discontinuous chain queued; committing the immediate item
      // ahead of it would invert engine truth.
      while !pending.isEmpty {
        flushCoalescedCommit()
      }
      commitNow(entry, coalescedCount: 1)
      return
    }

    pending.append(entry)
    ensureDisplayLinkRunning()
  }

  // MARK: Cancel / invalidate

  /// Drops all pending transactions without committing. Display link stays available.
  func cancelPending() {
    precondition(Thread.isMainThread, "VibeListDisplayLinkCommitter requires main thread")
    guard !pending.isEmpty else { return }
    let dropped = pending
    pending.removeAll(keepingCapacity: true)
    pauseDisplayLinkIfIdle()
    for entry in dropped {
      emitCancelledTiming(for: entry)
    }
  }

  /// Permanently stops the committer. Further enqueues are ignored.
  func invalidate() {
    precondition(Thread.isMainThread, "VibeListDisplayLinkCommitter requires main thread")
    isInvalidated = true
    cancelPending()
    tearDownDisplayLink()
    onCommit = nil
    onTiming = nil
    proxy.owner = nil
  }

  // MARK: Display link

  fileprivate func handleDisplayLinkTick(_ link: CADisplayLink) {
    _ = link
    guard !isInvalidated else { return }
    guard !pending.isEmpty else {
      pauseDisplayLinkIfIdle()
      return
    }
    flushCoalescedCommit()
  }

  private func ensureDisplayLinkRunning() {
    if displayLink == nil {
      let link = CADisplayLink(
        target: proxy,
        selector: #selector(VibeListDisplayLinkProxy.handleDisplayLink(_:))
      )
      // Prefer the display's cadence; 120 Hz devices get one slot per preferred frame.
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
      link.add(to: .main, forMode: .common)
      displayLink = link
    }
    displayLink?.isPaused = false
  }

  private func pauseDisplayLinkIfIdle() {
    guard pending.isEmpty else { return }
    displayLink?.isPaused = true
  }

  private func tearDownDisplayLink() {
    displayLink?.invalidate()
    displayLink = nil
  }

  // MARK: Coalesce + commit

  /// Takes the longest continuous generation chain from the front of the queue and
  /// commits it as one transaction. Remainder waits for the next frame.
  private func flushCoalescedCommit() {
    guard !pending.isEmpty else { return }
    let (merged, coalescedCount, remaining) = Self.coalesceChain(pending)
    pending = remaining
    commitNow(merged, coalescedCount: coalescedCount)
    pauseDisplayLinkIfIdle()
  }

  private func commitNow(_ entry: VibeListPendingCommit, coalescedCount: Int) {
    let start = CACurrentMediaTime()
    onCommit?(entry.transaction)
    let end = CACurrentMediaTime()
    let observation = VibeListCommitTimingObservation(
      baseGeneration: entry.transaction.baseGeneration,
      nextGeneration: entry.transaction.nextGeneration,
      opCount: entry.transaction.ops.count,
      coalescedCount: coalescedCount,
      enqueueUptime: entry.enqueueUptime,
      commitUptime: end,
      mainThreadDurationMs: (end - start) * 1000.0,
      wasCancelled: false
    )
    onTiming?(observation)
  }

  private func emitCancelledTiming(for entry: VibeListPendingCommit) {
    let now = CACurrentMediaTime()
    onTiming?(
      VibeListCommitTimingObservation(
        baseGeneration: entry.transaction.baseGeneration,
        nextGeneration: entry.transaction.nextGeneration,
        opCount: entry.transaction.ops.count,
        coalescedCount: 0,
        enqueueUptime: entry.enqueueUptime,
        commitUptime: now,
        mainThreadDurationMs: 0,
        wasCancelled: true
      )
    )
  }

  /// Merges a continuous base→next generation chain into one transaction.
  private static func coalesceChain(
    _ entries: [VibeListPendingCommit]
  ) -> (merged: VibeListPendingCommit, count: Int, remaining: [VibeListPendingCommit]) {
    precondition(!entries.isEmpty)
    let first = entries[0]
    var ops = first.transaction.ops
    var nextGeneration = first.transaction.nextGeneration
    var preserve = first.transaction.preserve
    var animation = first.transaction.animation
    var deadline = first.transaction.commitDeadline
    var count = 1
    var index = 1

    while index < entries.count {
      let candidate = entries[index].transaction
      guard candidate.baseGeneration == nextGeneration else { break }
      ops.append(contentsOf: candidate.ops)
      nextGeneration = candidate.nextGeneration
      // Latest preserve wins for the visual anchor of the merged commit.
      preserve = candidate.preserve
      if animation == .none {
        animation = candidate.animation
      }
      if candidate.commitDeadline == .immediate {
        deadline = .immediate
      }
      count += 1
      index += 1
    }

    let mergedTransaction = VibeListTransaction(
      baseGeneration: first.transaction.baseGeneration,
      nextGeneration: nextGeneration,
      ops: ops,
      preserve: preserve,
      animation: animation,
      commitDeadline: deadline
    )
    let merged = VibeListPendingCommit(
      transaction: mergedTransaction,
      enqueueUptime: first.enqueueUptime
    )
    let remaining = Array(entries.dropFirst(index))
    return (merged, count, remaining)
  }
}
