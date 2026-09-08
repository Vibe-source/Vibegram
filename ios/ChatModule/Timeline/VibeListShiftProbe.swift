import UIKit

/// Watches the transcript for content moving under the reader, and for frames the
/// list failed to deliver — the two things a person means by "it shifted" and
/// "it's janky", neither of which the existing instrumentation can see.
///
/// # Why the logs kept saying everything was fine
///
/// Every diagnostic this list already has measures *itself*. `[HeightShift]`
/// fires when a corrector changes a settled row's height, `[ScrollHitch]` times
/// the body of `scrollViewDidScroll`, `[ScrollProfile]` sums those ticks over a
/// gesture. Each is a stopwatch inside a function that already suspected it was
/// the problem, and each is therefore blind in the same direction:
///
/// - A row can keep its height exactly and still move, because something was
///   inserted above it, or `contentSize` changed, or an inset moved. No height
///   changed, so `[HeightShift]` says nothing.
/// - A gesture can report `ticks=270 overBudget=0 worst=2ms` while visibly
///   stuttering, because the expensive work is in `cellForItemAt`, in
///   `layoutSubviews`, or in an image decode — none of which run inside
///   `scrollViewDidScroll` and none of which its stopwatch spans.
///
/// So the device log could read clean through a session the reader experienced
/// as the list jumping and stalling. That gap is what this closes. It measures
/// two things that are true regardless of which mechanism produced them:
///
/// 1. **Did a row the reader was looking at change position when they were not
///    scrolling?** That is the shift, by definition — whatever caused it.
/// 2. **Did the display actually get its frames?** Measured from the display
///    link, so it counts frames the user did not receive rather than time this
///    list happened to spend in one function.
///
/// # How the shift check avoids false positives
///
/// It anchors on the topmost visible cell and follows *that specific row* by
/// identity. A report requires all of: the same row still on screen, the scroll
/// view not tracking / dragging / decelerating, and its on-screen y moved by
/// more than half a point. Position is measured as `cell.frame.minY -
/// contentOffset.y`, deliberately not window coordinates — during a navigation
/// push the whole view is under a transform, and window coordinates would call
/// every push a shift.
///
/// An *anchored* prepend passes this test silently, which is the point: it moves
/// `contentOffset` and the row's frame by the same amount, so the row does not
/// move on screen and there is nothing to report. The log fires exactly when the
/// anchoring failed to hold.
///
/// # Cost
///
/// The steady-state path is one `indexPath(for:)` on a cell it already holds and
/// a handful of float compares. It only walks `visibleCells` when the anchor was
/// recycled. Reports are rate-limited per cause and capped per chat, because a
/// diagnostic that floods the ring buffer buries the line that mattered — this
/// project has shipped that failure once already.
final class VibeListShiftProbe {

  /// What the list was doing when a movement happened, if it declared it.
  ///
  /// A declared intent does not suppress the report. Some intentional moves are
  /// still felt as jumps, and a probe that hides them would be arguing with the
  /// reader. It is recorded so the log distinguishes "the keyboard opened" from
  /// "nobody knows why this moved".
  private struct Intent {
    let reason: String
    let at: CFTimeInterval
  }

  private weak var collectionView: UICollectionView?
  /// Identity for a row index, as the layout keys its height memo. Supplied by
  /// the list so this file needs no access to its private storage.
  private let identityAt: (Int) -> String?
  private let chatLabel: () -> String

  private var observer: CFRunLoopObserver?

  // MARK: Anchor state

  private weak var anchorCell: UICollectionViewCell?
  private var anchorIdentity = ""
  private var anchorIndex = -1
  private var anchorScreenY: CGFloat = 0
  private var anchorHeight: CGFloat = 0
  private var anchorWidth: CGFloat = 0
  private var lastOffsetY: CGFloat = 0
  private var lastContentHeight: CGFloat = 0
  private var lastInsetTop: CGFloat = 0
  private var lastRowCount = 0

  private var intent: Intent?
  private var lastSampleAt: CFTimeInterval = 0

  // MARK: Reporting budget

  /// One frame at 120Hz. Sampling faster than the display refreshes cannot
  /// observe anything new and only costs the main thread.
  private static let minSampleInterval: CFTimeInterval = 0.008
  /// Sub-pixel movement is rounding, not a shift.
  private static let shiftThreshold: CGFloat = 0.5
  private static let detailCap = 60
  private var detailsLogged = 0
  private var totalShifts = 0
  private var totalTravel: CGFloat = 0
  private var worstShift: CGFloat = 0
  private var byIntent: [String: Int] = [:]

  init(
    collectionView: UICollectionView,
    chatLabel: @escaping () -> String,
    identityAt: @escaping (Int) -> String?
  ) {
    self.collectionView = collectionView
    self.chatLabel = chatLabel
    self.identityAt = identityAt
  }

  deinit { disarm() }

  // MARK: Lifecycle

  /// Starts watching. The observer runs on `.beforeWaiting`: the run loop has
  /// finished laying out and is about to let the frame be presented, so this is
  /// the last moment the geometry the reader is about to see is still readable.
  func arm() {
    guard observer == nil else { return }
    let observer = CFRunLoopObserverCreateWithHandler(
      kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 0
    ) { [weak self] _, _ in
      self?.sample()
    }
    guard let observer else { return }
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    self.observer = observer
  }

  func disarm() {
    guard let observer else { return }
    CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
    CFRunLoopObserverInvalidate(observer)
    self.observer = nil
  }

  /// Names what the list is about to do, for the next moment or two.
  ///
  /// Call it immediately before an intentional offset change — a keyboard
  /// inset, a jump to bottom, an anchored prepend. The window is short on
  /// purpose: a stale label attached to an unrelated movement is worse than no
  /// label, because it sends the reader of the log looking in the wrong place.
  func declare(_ reason: String) {
    intent = Intent(reason: reason, at: CACurrentMediaTime())
  }

  /// Forgets the anchor. Call when the transcript is replaced wholesale — the
  /// previous chat's row is not a meaningful reference for this one.
  func resetAnchor() {
    anchorCell = nil
    anchorIdentity = ""
    anchorIndex = -1
  }

  // MARK: Sampling

  private func sample() {
    guard let collectionView, collectionView.window != nil else { return }
    let now = CACurrentMediaTime()
    guard now - lastSampleAt >= Self.minSampleInterval else { return }
    lastSampleAt = now

    let offsetY = collectionView.contentOffset.y
    let insetTop = collectionView.adjustedContentInset.top
    let rowCount = collectionView.numberOfItems(inSection: 0)
    // `contentSize` is read from the cached bounds rather than the layout, on
    // purpose: asking the layout for its content size can trigger a rebuild, and
    // a probe that provokes the work it is measuring is not a probe.
    let contentHeight = collectionView.contentSize.height

    let scrolling =
      collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating

    defer {
      lastOffsetY = offsetY
      lastContentHeight = contentHeight
      lastInsetTop = insetTop
      lastRowCount = rowCount
    }

    // Follow the anchor we already have; only go looking when it was recycled.
    guard let cell = anchorCell, let path = collectionView.indexPath(for: cell) else {
      captureAnchor(in: collectionView, offsetY: offsetY)
      return
    }

    let screenY = cell.frame.minY - offsetY
    let dy = screenY - anchorScreenY
    let identityNow = identityAt(path.item)

    // The row under the anchor changed out from under us — the cell was reused
    // for a different message. Nothing to compare; re-anchor.
    guard let identityNow, identityNow == anchorIdentity else {
      captureAnchor(in: collectionView, offsetY: offsetY)
      return
    }

    let widthDelta = cell.frame.width - anchorWidth
    let heightDelta = cell.frame.height - anchorHeight

    if !scrolling, abs(dy) > Self.shiftThreshold {
      report(
        dy: dy, offsetY: offsetY, contentHeight: contentHeight, insetTop: insetTop,
        rowCount: rowCount, index: path.item, heightDelta: heightDelta, widthDelta: widthDelta,
        collectionView: collectionView)
    }

    // A width change is worth its own line whether or not the row moved: it means
    // this row was framed at a width its height was not measured against, and the
    // height error lands on the next pass rather than this one.
    if abs(widthDelta) > Self.shiftThreshold, detailsLogged < Self.detailCap {
      detailsLogged += 1
      NSLog(
        "[ListShift] WIDTH chat=%@ row=%@ %.1f→%.1f cv=%.1f — row framed at a width its height was not measured against",
        chatLabel(), String(anchorIdentity.suffix(14)), anchorWidth, cell.frame.width,
        collectionView.bounds.width)
    }

    anchorScreenY = screenY
    anchorIndex = path.item
    anchorHeight = cell.frame.height
    anchorWidth = cell.frame.width
  }

  private func captureAnchor(in collectionView: UICollectionView, offsetY: CGFloat) {
    var best: UICollectionViewCell?
    var bestY = CGFloat.greatestFiniteMagnitude
    for cell in collectionView.visibleCells {
      let y = cell.frame.minY
      // The topmost row whose bottom edge is still on screen. A row scrolled
      // entirely past the top is about to be recycled and makes a poor anchor.
      guard cell.frame.maxY > offsetY, y < bestY else { continue }
      bestY = y
      best = cell
    }
    guard let best, let path = collectionView.indexPath(for: best),
      let identity = identityAt(path.item)
    else {
      anchorCell = nil
      return
    }
    anchorCell = best
    anchorIdentity = identity
    anchorIndex = path.item
    anchorScreenY = best.frame.minY - offsetY
    anchorHeight = best.frame.height
    anchorWidth = best.frame.width
  }

  // MARK: Reporting

  private func report(
    dy: CGFloat, offsetY: CGFloat, contentHeight: CGFloat, insetTop: CGFloat,
    rowCount: Int, index: Int, heightDelta: CGFloat, widthDelta: CGFloat,
    collectionView: UICollectionView
  ) {
    totalShifts += 1
    totalTravel += abs(dy)
    if abs(dy) > abs(worstShift) { worstShift = dy }

    let label: String
    if let intent, CACurrentMediaTime() - intent.at < 0.2 {
      label = intent.reason
    } else {
      label = "none"
    }
    byIntent[label, default: 0] += 1

    guard detailsLogged < Self.detailCap else { return }
    detailsLogged += 1

    // Every field here is one of the ways an anchored row can move. A shift with
    // all of them at zero means the movement came from somewhere this list does
    // not yet model, which is worth knowing on its own.
    NSLog(
      "[ListShift] MOVED chat=%@ row=%@ dy=%+.1fpt intent=%@ | off=%+.1f csize=%+.1f "
        + "inset=%+.1f idx=%+d rows=%+d h=%+.1f w=%+.1f | at=%.0f rows=%d",
      chatLabel(), String(anchorIdentity.suffix(14)), dy, label,
      offsetY - lastOffsetY, contentHeight - lastContentHeight, insetTop - lastInsetTop,
      index - anchorIndex, rowCount - lastRowCount, heightDelta, widthDelta,
      offsetY, rowCount)
    // Also to the persistent log. `NSLog` only reaches a console someone has
    // attached, and the automated repro cannot keep one attached — a UI test
    // takes over the app and kills any console-attached process. This file is
    // pullable off the device afterwards, so it is the only record that survives
    // the run that produces the evidence.
    VibeLog.warning(
      "list moved under the reader", category: "listshift",
      metadata: [
        "chat": chatLabel(), "row": String(anchorIdentity.suffix(14)),
        "dy": String(format: "%+.1f", dy), "intent": label,
        "off": String(format: "%+.1f", offsetY - lastOffsetY),
        "csize": String(format: "%+.1f", contentHeight - lastContentHeight),
        "inset": String(format: "%+.1f", insetTop - lastInsetTop),
        "idx": String(index - anchorIndex), "rows": String(rowCount - lastRowCount),
        "h": String(format: "%+.1f", heightDelta), "w": String(format: "%+.1f", widthDelta),
        "at": String(format: "%.0f", offsetY),
      ])
  }

  /// Verdict for the chat that is closing. The only moment these numbers are final.
  func logSummary(reason: String) {
    guard totalShifts > 0 else {
      NSLog("[ListShift] summary chat=%@ (%@) — nothing moved under the reader", chatLabel(), reason)
      VibeLog.info(
        "list shifts: none", category: "listshift",
        metadata: ["chat": chatLabel(), "reason": reason])
      return
    }
    let causes = byIntent.sorted { $0.value > $1.value }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: " ")
    NSLog(
      "[ListShift] summary chat=%@ (%@) shifts=%d travel=%.0fpt worst=%+.1fpt [%@]",
      chatLabel(), reason, totalShifts, totalTravel, worstShift, causes)
    VibeLog.error(
      "list shifted under the reader", category: "listshift",
      metadata: [
        "chat": chatLabel(), "reason": reason, "shifts": String(totalShifts),
        "travel": String(format: "%.0f", totalTravel),
        "worst": String(format: "%+.1f", worstShift), "causes": causes,
      ])
  }

  var totals: (shifts: Int, worst: CGFloat) { (totalShifts, worstShift) }
}

/// Counts the frames the display did not get during a scroll.
///
/// `[ScrollProfile]` can only report how long this list spent inside
/// `scrollViewDidScroll`. That number was `worst=2ms` through a session the
/// reader described as janky, because the work that drops frames — building a
/// cell, laying out a bubble, decoding an image — happens in other callbacks
/// entirely. A display link is downstream of all of them: if a frame did not
/// ship, the gap shows up here no matter who ate it.
final class VibeListFramePacer {

  private var link: CADisplayLink?
  private var lastTimestamp: CFTimeInterval = 0
  private(set) var frames = 0
  private(set) var dropped = 0
  private(set) var worstGapMs: Double = 0
  /// Frames whose gap was long enough to be seen as a stutter rather than
  /// measured — roughly three refreshes.
  private(set) var stutters = 0

  func begin() {
    guard link == nil else { return }
    frames = 0
    dropped = 0
    worstGapMs = 0
    stutters = 0
    lastTimestamp = 0
    let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
    // `.common` so it keeps ticking while the user's finger is down — tracking
    // mode is exactly when we need the measurement.
    link.add(to: .main, forMode: .common)
    self.link = link
  }

  func end() {
    link?.invalidate()
    link = nil
  }

  @objc private func tick(_ link: CADisplayLink) {
    defer { lastTimestamp = link.timestamp }
    guard lastTimestamp > 0 else { return }
    let gap = link.timestamp - lastTimestamp
    // What the display was ready to give us this frame. Read from the link
    // rather than assumed, because ProMotion changes it under us.
    let expected = max(0.001, link.targetTimestamp - link.timestamp)
    frames += 1
    let gapMs = gap * 1000.0
    if gapMs > worstGapMs { worstGapMs = gapMs }
    guard gap > expected * 1.5 else { return }
    let missed = Int((gap / expected).rounded()) - 1
    dropped += max(1, missed)
    if missed >= 3 { stutters += 1 }
  }
}
