import CoreGraphics
import UIKit

// MARK: - VibeMessageListHost

/// Replaceable message-list renderer boundary.
///
/// Chat navigation and `ChatMainView` will eventually talk only to this protocol.
/// Implementations may wrap the existing `UICollectionView` path or a future async
/// host. UIKit types are permitted **only** at this root (`view`, insets).
///
/// Invariants:
/// - `apply(snapshot:)` mounts an atomic first paint; no engine callback is invoked
///   synchronously from inside the host.
/// - `apply(transaction:)` is generation-fenced; partial reloads without anchor
///   preserve are forbidden.
/// - Settled geometry is never mutated by content-only ops (enforced by contracts).
/// - No `[String: Any]`, decrypted media buffers, or UIKit objects inside render items.
@MainActor
protocol VibeMessageListHost: AnyObject {
  /// Root view attached to the chat chrome hierarchy. Sole UIKit escape hatch.
  var view: UIView { get }

  /// Mount or replace the full bounded window for first paint / trait changes.
  func apply(snapshot: VibeRenderSnapshot, reason: VibeMountReason)

  /// Apply an ordered, atomic list mutation (possibly coalesced by the display-link committer).
  func apply(transaction: VibeListTransaction)

  /// Keyboard, composer, and safe-area insets affecting the scrollable viewport.
  func setViewportInsets(_ insets: UIEdgeInsets)

  /// Currently visible row identities (ids only).
  func visibleAnchors() -> [VibeTimelineAnchor]

  /// Window-attached prestage before `pushViewController` (populated push contract).
  func prepareForNavigationPush(bounds: CGRect, safeBottom: CGFloat)

  /// Called after the navigation transition settles (`viewDidAppear` path).
  func completePresentation()

  /// Cancel media/layout prefetch for identities outside the extended range.
  func cancelPrefetch(outside range: Range<Int>)

  /// Debug/shadow: message id → row height. Never includes message bodies.
  func debugGeometryMap() -> [String: CGFloat]
}

// MARK: - Optional host capabilities

/// Optional metrics surface for harness / shadow mode (identifiers and timings only).
@MainActor
protocol VibeMessageListHostMetrics: AnyObject {
  /// Last applied timeline generation, if any.
  var lastAppliedGeneration: UInt64? { get }
  /// Number of item nodes/cells currently instantiated (visible + preload).
  var instantiatedItemCount: Int { get }
}

// MARK: - No-op host (compile-time / test double)

/// Inert host used by unit tests and as a safe placeholder before wiring production.
/// Does not touch the real chat path.
@MainActor
final class VibeNoOpMessageListHost: VibeMessageListHost {
  let view: UIView
  private(set) var lastSnapshot: VibeRenderSnapshot?
  private(set) var lastTransaction: VibeListTransaction?
  private(set) var viewportInsets: UIEdgeInsets = .zero
  private(set) var lastAppliedGeneration: UInt64?
  private var geometry: [String: CGFloat] = [:]

  init() {
    self.view = UIView(frame: .zero)
  }

  init(view: UIView) {
    self.view = view
  }

  func apply(snapshot: VibeRenderSnapshot, reason: VibeMountReason) {
    _ = reason
    lastSnapshot = snapshot
    lastAppliedGeneration = snapshot.generation
    geometry = Dictionary(
      uniqueKeysWithValues: snapshot.items.map {
        ($0.identity.messageId, $0.size.height)
      }
    )
  }

  func apply(transaction: VibeListTransaction) {
    lastTransaction = transaction
    lastAppliedGeneration = transaction.nextGeneration
    for op in transaction.ops {
      switch op {
      case .insert(let items, _):
        for item in items {
          geometry[item.identity.messageId] = item.size.height
        }
      case .remove(let ids):
        for id in ids { geometry.removeValue(forKey: id) }
      case .updateContent(_, let item):
        // Content-only: height unchanged by contract; keep existing if present.
        if geometry[item.identity.messageId] == nil {
          geometry[item.identity.messageId] = item.size.height
        }
      case .updateGeometry(_, let item, _):
        geometry[item.identity.messageId] = item.size.height
      case .move:
        break
      }
    }
  }

  func setViewportInsets(_ insets: UIEdgeInsets) {
    viewportInsets = insets
  }

  func visibleAnchors() -> [VibeTimelineAnchor] {
    lastSnapshot?.items.map(\.identity) ?? []
  }

  func prepareForNavigationPush(bounds: CGRect, safeBottom: CGFloat) {
    view.frame = bounds
    _ = safeBottom
  }

  func completePresentation() {}

  func cancelPrefetch(outside range: Range<Int>) {
    _ = range
  }

  func debugGeometryMap() -> [String: CGFloat] {
    geometry
  }
}

extension VibeNoOpMessageListHost: VibeMessageListHostMetrics {
  var instantiatedItemCount: Int { geometry.count }
}
