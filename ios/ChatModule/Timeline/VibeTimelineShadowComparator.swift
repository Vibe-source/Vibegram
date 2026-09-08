import CoreGraphics
import Foundation

// MARK: - Shadow diff (ids / metrics only)

/// One shadow mismatch. **Never** carries message bodies or paint text.
struct VibeTimelineShadowDiff: Sendable, Equatable {
  enum Kind: String, Sendable, Equatable {
    case generationMismatch
    case orderMismatch
    case missingIdentity
    case extraIdentity
    case geometryMismatch
    case anchorMismatch
    case contentHeightMismatch
    case windowCountMismatch
  }

  let kind: Kind
  /// Message / anchor id when applicable.
  let identityId: String?
  let metricA: Double?
  let metricB: Double?
  let detailCode: String?

  init(
    kind: Kind,
    identityId: String? = nil,
    metricA: Double? = nil,
    metricB: Double? = nil,
    detailCode: String? = nil
  ) {
    self.kind = kind
    self.identityId = identityId
    self.metricA = metricA
    self.metricB = metricB
    self.detailCode = detailCode
  }
}

/// Aggregate shadow comparison result (counts + diffs). No content payloads.
struct VibeTimelineShadowReport: Sendable, Equatable {
  let leftGeneration: UInt64
  let rightGeneration: UInt64
  let leftItemCount: Int
  let rightItemCount: Int
  let diffs: [VibeTimelineShadowDiff]

  var isMatch: Bool { diffs.isEmpty }
  var mismatchCount: Int { diffs.count }
}

// MARK: - Comparator

/// Dual-host geometry / order / generation / anchor comparison.
///
/// Tolerance for sizes and offsets: **0.5 pt** (board qualification).
/// Emits identifiers and metrics only.
enum VibeTimelineShadowComparator {
  /// Geometry equality tolerance in points.
  static let geometryTolerance: CGFloat = 0.5

  /// Compare two snapshots (e.g. production host vs experimental host).
  static func compare(
    left: VibeRenderSnapshot,
    right: VibeRenderSnapshot
  ) -> VibeTimelineShadowReport {
    var diffs: [VibeTimelineShadowDiff] = []

    if left.generation != right.generation {
      diffs.append(
        VibeTimelineShadowDiff(
          kind: .generationMismatch,
          metricA: Double(left.generation),
          metricB: Double(right.generation),
          detailCode: "snapshot.generation"
        )
      )
    }

    if left.items.count != right.items.count {
      diffs.append(
        VibeTimelineShadowDiff(
          kind: .windowCountMismatch,
          metricA: Double(left.items.count),
          metricB: Double(right.items.count),
          detailCode: "items.count"
        )
      )
    }

    if abs(left.contentHeight - right.contentHeight) > geometryTolerance {
      diffs.append(
        VibeTimelineShadowDiff(
          kind: .contentHeightMismatch,
          metricA: Double(left.contentHeight),
          metricB: Double(right.contentHeight),
          detailCode: "contentHeight"
        )
      )
    }

    appendAnchorDiffs(left: left.anchor, right: right.anchor, into: &diffs)
    appendOrderAndGeometryDiffs(left: left.items, right: right.items, into: &diffs)

    return VibeTimelineShadowReport(
      leftGeneration: left.generation,
      rightGeneration: right.generation,
      leftItemCount: left.items.count,
      rightItemCount: right.items.count,
      diffs: diffs
    )
  }

  /// Compare debug geometry maps from two hosts (messageId → height).
  static func compareGeometryMaps(
    left: [String: CGFloat],
    right: [String: CGFloat],
    leftGeneration: UInt64 = 0,
    rightGeneration: UInt64 = 0
  ) -> VibeTimelineShadowReport {
    var diffs: [VibeTimelineShadowDiff] = []
    let leftKeys = Set(left.keys)
    let rightKeys = Set(right.keys)

    for id in leftKeys.subtracting(rightKeys).sorted() {
      diffs.append(
        VibeTimelineShadowDiff(
          kind: .missingIdentity,
          identityId: id,
          metricA: left[id].map(Double.init),
          detailCode: "geometryMap.rightMissing"
        )
      )
    }
    for id in rightKeys.subtracting(leftKeys).sorted() {
      diffs.append(
        VibeTimelineShadowDiff(
          kind: .extraIdentity,
          identityId: id,
          metricB: right[id].map(Double.init),
          detailCode: "geometryMap.leftMissing"
        )
      )
    }
    for id in leftKeys.intersection(rightKeys).sorted() {
      guard let a = left[id], let b = right[id] else { continue }
      if abs(a - b) > geometryTolerance {
        diffs.append(
          VibeTimelineShadowDiff(
            kind: .geometryMismatch,
            identityId: id,
            metricA: Double(a),
            metricB: Double(b),
            detailCode: "height"
          )
        )
      }
    }

    return VibeTimelineShadowReport(
      leftGeneration: leftGeneration,
      rightGeneration: rightGeneration,
      leftItemCount: left.count,
      rightItemCount: right.count,
      diffs: diffs
    )
  }

  /// Compare two ordered identity sequences (stable scroll order).
  static func compareOrder(
    leftIds: [String],
    rightIds: [String]
  ) -> [VibeTimelineShadowDiff] {
    var diffs: [VibeTimelineShadowDiff] = []
    let count = min(leftIds.count, rightIds.count)
    for index in 0..<count where leftIds[index] != rightIds[index] {
      diffs.append(
        VibeTimelineShadowDiff(
          kind: .orderMismatch,
          identityId: leftIds[index],
          metricA: Double(index),
          metricB: Double(index),
          detailCode: "order[\(index)] rightId=\(rightIds[index])"
        )
      )
    }
    if leftIds.count != rightIds.count {
      diffs.append(
        VibeTimelineShadowDiff(
          kind: .windowCountMismatch,
          metricA: Double(leftIds.count),
          metricB: Double(rightIds.count),
          detailCode: "order.count"
        )
      )
    }
    return diffs
  }

  // MARK: Private

  private static func appendAnchorDiffs(
    left: VibeViewportAnchor,
    right: VibeViewportAnchor,
    into diffs: inout [VibeTimelineShadowDiff]
  ) {
    if left.pin != right.pin {
      diffs.append(
        VibeTimelineShadowDiff(
          kind: .anchorMismatch,
          detailCode: "pin.\(left.pin.rawValue)!=\(right.pin.rawValue)"
        )
      )
    }
    if left.itemId != right.itemId {
      diffs.append(
        VibeTimelineShadowDiff(
          kind: .anchorMismatch,
          identityId: left.itemId.isEmpty ? right.itemId : left.itemId,
          detailCode: "itemId"
        )
      )
    }
    if abs(left.offsetFromTop - right.offsetFromTop) > geometryTolerance {
      diffs.append(
        VibeTimelineShadowDiff(
          kind: .anchorMismatch,
          identityId: left.itemId.isEmpty ? nil : left.itemId,
          metricA: Double(left.offsetFromTop),
          metricB: Double(right.offsetFromTop),
          detailCode: "offsetFromTop"
        )
      )
    }
  }

  private static func appendOrderAndGeometryDiffs(
    left: [VibeRenderItem],
    right: [VibeRenderItem],
    into diffs: inout [VibeTimelineShadowDiff]
  ) {
    let leftIds = left.map(\.identity.messageId)
    let rightIds = right.map(\.identity.messageId)
    diffs.append(contentsOf: compareOrder(leftIds: leftIds, rightIds: rightIds))

    var rightById: [String: VibeRenderItem] = [:]
    rightById.reserveCapacity(right.count)
    for item in right {
      rightById[item.identity.messageId] = item
    }

    var seenRight = Set<String>()
    for item in left {
      let id = item.identity.messageId
      guard let other = rightById[id] else {
        diffs.append(
          VibeTimelineShadowDiff(
            kind: .missingIdentity,
            identityId: id,
            metricA: Double(item.size.height),
            detailCode: "item.rightMissing"
          )
        )
        continue
      }
      seenRight.insert(id)
      appendItemGeometryDiff(left: item, right: other, into: &diffs)
    }

    for item in right where !seenRight.contains(item.identity.messageId) {
      diffs.append(
        VibeTimelineShadowDiff(
          kind: .extraIdentity,
          identityId: item.identity.messageId,
          metricB: Double(item.size.height),
          detailCode: "item.leftMissing"
        )
      )
    }
  }

  private static func appendItemGeometryDiff(
    left: VibeRenderItem,
    right: VibeRenderItem,
    into diffs: inout [VibeTimelineShadowDiff]
  ) {
    let id = left.identity.messageId
    if abs(left.size.height - right.size.height) > geometryTolerance {
      diffs.append(
        VibeTimelineShadowDiff(
          kind: .geometryMismatch,
          identityId: id,
          metricA: Double(left.size.height),
          metricB: Double(right.size.height),
          detailCode: "height"
        )
      )
    }
    if abs(left.size.width - right.size.width) > geometryTolerance {
      diffs.append(
        VibeTimelineShadowDiff(
          kind: .geometryMismatch,
          identityId: id,
          metricA: Double(left.size.width),
          metricB: Double(right.size.width),
          detailCode: "width"
        )
      )
    }
    if left.geometryRevision != right.geometryRevision {
      diffs.append(
        VibeTimelineShadowDiff(
          kind: .geometryMismatch,
          identityId: id,
          metricA: Double(left.geometryRevision),
          metricB: Double(right.geometryRevision),
          detailCode: "geometryRevision"
        )
      )
    }
  }
}
