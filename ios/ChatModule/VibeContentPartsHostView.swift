import SwiftUI
import UIKit

// MARK: - Host model (stable identity across cell reuse)

/// Holds the latest render inputs so the hosting controller can keep a single root
/// view identity while `configure` mutates parts / accent / callbacks. Closures are
/// stored here (not captured by SwiftUI forever) so cell reuse can nil them out.
private final class VibeContentPartsHostModel: ObservableObject {
  @Published var parts: [VibeContentPart] = []
  @Published var accent: Color = Color(
    red: 0.1843, green: 0.6196, blue: 0.5765
  )

  var onAction: (String) -> Void = { _ in }
  var onCallRequested: () -> Void = {}
  var onOpenLink: (URL) -> Void = { _ in }
}

/// Thin root that always reads the latest model — avoids rebuilding
/// `UIHostingController` on every `configure` (critical for cell reuse).
private struct VibeContentPartsHostRoot: View {
  @ObservedObject var model: VibeContentPartsHostModel

  var body: some View {
    VibeContentPartsView(
      parts: model.parts,
      accent: model.accent,
      onAction: { model.onAction($0) },
      onCallRequested: { model.onCallRequested() },
      onOpenLink: { model.onOpenLink($0) }
    )
    // Zero-height empty state so empty configure collapses cleanly.
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - UIKit host

/// UIKit host wrapping `VibeContentPartsView` for chat-bubble cells.
///
/// Embeds the SwiftUI parts renderer via `UIHostingController`, self-sizes from
/// the hosted view's `sizeThatFits`, and is safe for table/collection cell reuse
/// (parent VC attach/detach on window changes; callbacks cleared on `reset`).
///
/// Text / media parts are skipped — the existing bubble owns those lanes.
final class VibeContentPartsHostView: UIView {
  var onHeightChange: ((CGFloat) -> Void)?

  private let model = VibeContentPartsHostModel()
  private let hostingController: UIHostingController<VibeContentPartsHostRoot>
  private var isHostingControllerAttached = false
  private var lastReportedHeight: CGFloat = -1
  private var lastAvailableWidth: CGFloat = 0
  private var cachedIntrinsicHeight: CGFloat = 0

  // MARK: Init

  override init(frame: CGRect) {
    hostingController = UIHostingController(
      rootView: VibeContentPartsHostRoot(model: model)
    )
    super.init(frame: frame)
    commonInit()
  }

  required init?(coder: NSCoder) {
    hostingController = UIHostingController(
      rootView: VibeContentPartsHostRoot(model: model)
    )
    super.init(coder: coder)
    commonInit()
  }

  private func commonInit() {
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = false

    if #available(iOS 16.4, *) {
      hostingController.safeAreaRegions = []
    }
    hostingController.view.backgroundColor = .clear
    hostingController.view.isOpaque = false
    // Disable safe-area padding so bubble-width measurement matches the cell.
    hostingController.view.insetsLayoutMarginsFromSafeArea = false

    let hostedView = hostingController.view!
    hostedView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(hostedView)

    // Same priority-999 bottom-pin trick as `VibeAgentTurnContentView`: chat-bubble
    // cells often position hosts with manual frames (including height == 0 while
    // parked). A required bottom pin fights the frame height and UIKit breaks a
    // random internal constraint. Priority 999 yields silently but still outranks
    // `.fittingSizeLevel`, so measurement remains correct.
    let bottomPin = hostedView.bottomAnchor.constraint(equalTo: bottomAnchor)
    bottomPin.priority = UILayoutPriority(999)
    NSLayoutConstraint.activate([
      hostedView.topAnchor.constraint(equalTo: topAnchor),
      hostedView.leadingAnchor.constraint(equalTo: leadingAnchor),
      hostedView.trailingAnchor.constraint(equalTo: trailingAnchor),
      bottomPin,
    ])
  }

  // MARK: Configure

  /// Decode raw part dicts, drop text/media (bubble owns those), and re-render.
  func configure(
    partsRaw: [[String: Any]],
    accent: UIColor,
    onAction: @escaping (String) -> Void,
    onCallRequested: @escaping () -> Void,
    onOpenLink: @escaping (URL) -> Void
  ) {
    let decoded: [VibeContentPart] = partsRaw.compactMap { VibeContentPart(raw: $0) }
    // Bubble already renders text + media attachments; host only owns rich kinds.
    let rich = decoded.filter { part in
      let kind = part.kind
      return kind != "text" && kind != "media"
    }

    model.parts = rich
    model.accent = Color(uiColor: accent)
    model.onAction = onAction
    model.onCallRequested = onCallRequested
    model.onOpenLink = onOpenLink

    // Force the hosting view to re-measure after model mutation.
    setNeedsLayout()
    invalidateIntrinsicContentSize()
    reportHeightIfNeeded(force: true)
  }

  /// Cell-reuse hygiene: clear parts + callbacks so a recycled cell never fires
  /// the previous row's action handlers or shows stale content for a frame.
  func reset() {
    model.parts = []
    model.onAction = { _ in }
    model.onCallRequested = {}
    model.onOpenLink = { _ in }
    lastReportedHeight = -1
    cachedIntrinsicHeight = 0
    invalidateIntrinsicContentSize()
  }

  // MARK: Hosting lifecycle (cell reuse)

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      attachHostingControllerIfNeeded()
    } else {
      detachHostingControllerIfNeeded()
    }
  }

  private func attachHostingControllerIfNeeded() {
    guard !isHostingControllerAttached else { return }
    guard let parentVC = nearestViewController() else { return }
    // Hosting view is already a subview of self; only adopt the VC parent link.
    parentVC.addChild(hostingController)
    hostingController.didMove(toParent: parentVC)
    isHostingControllerAttached = true
  }

  private func detachHostingControllerIfNeeded() {
    guard isHostingControllerAttached else { return }
    hostingController.willMove(toParent: nil)
    hostingController.removeFromParent()
    isHostingControllerAttached = false
  }

  private func nearestViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let next = responder?.next {
      if let vc = next as? UIViewController {
        return vc
      }
      responder = next
    }
    return nil
  }

  // MARK: Self-sizing

  override var intrinsicContentSize: CGSize {
    let width = resolvedMeasureWidth()
    let height = measuredContentHeight(forWidth: width)
    return CGSize(width: UIView.noIntrinsicMetric, height: height)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let width = bounds.width
    if width > 1, abs(width - lastAvailableWidth) > 0.5 {
      lastAvailableWidth = width
      invalidateIntrinsicContentSize()
    }
    reportHeightIfNeeded(force: false)
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    let width = size.width > 1 ? size.width : resolvedMeasureWidth()
    let height = measuredContentHeight(forWidth: width)
    return CGSize(width: width, height: height)
  }

  private func resolvedMeasureWidth() -> CGFloat {
    if bounds.width > 1 { return bounds.width }
    if lastAvailableWidth > 1 { return lastAvailableWidth }
    // Fallback for offscreen / pre-layout measure (mirrors chat bubble defaults).
    return max(1, UIScreen.main.bounds.width - 96)
  }

  private func measuredContentHeight(forWidth width: CGFloat) -> CGFloat {
    guard width > 1 else { return 0 }
    if model.parts.isEmpty { return 0 }

    let hosted = hostingController.view!
    // Prefer the modern UIHostingController API when available; fall back to the
    // hosted UIView's sizeThatFits for older OS / edge cases.
    let fitted: CGSize
    if #available(iOS 16.0, *) {
      fitted = hostingController.sizeThatFits(
        in: CGSize(width: width, height: UIView.layoutFittingExpandedSize.height)
      )
    } else {
      fitted = hosted.sizeThatFits(
        CGSize(width: width, height: UIView.layoutFittingExpandedSize.height)
      )
    }

    let height = fitted.height
    guard height.isFinite, height >= 0 else { return 0 }
    let ceiled = ceil(height)
    cachedIntrinsicHeight = ceiled
    return ceiled
  }

  private func reportHeightIfNeeded(force: Bool) {
    let width = resolvedMeasureWidth()
    let height = measuredContentHeight(forWidth: width)
    if force || abs(height - lastReportedHeight) > 0.5 {
      lastReportedHeight = height
      onHeightChange?(height)
    }
  }

  // MARK: Off-window sizing template (mirrors VibeAgentTurnContentView)

  /// One shared offscreen instance reused for pure measurement — never added to a
  /// window. Avoids allocating a fresh hosting-controller graph per row on every
  /// chat-list height pass during live streams / reloads.
  private static let sizingTemplate: VibeContentPartsHostView = {
    let view = VibeContentPartsHostView(frame: .zero)
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }()

  private static var sizingWidthConstraint: NSLayoutConstraint?

  /// Height that `configure(partsRaw:…)` would produce at `availableWidth`, without
  /// needing a live instance in the view hierarchy. Callers must pass the same
  /// raw parts they'll use for the subsequent on-screen `configure`.
  static func measuredHeight(
    partsRaw: [[String: Any]],
    accent: UIColor,
    availableWidth: CGFloat
  ) -> CGFloat {
    let width = max(1, availableWidth)
    let template = sizingTemplate
    // Clear leftover parts / callbacks from a previous measurement so stale
    // (often taller) content cannot inflate this row's fitting height.
    template.reset()
    template.onHeightChange = nil

    if let constraint = sizingWidthConstraint {
      constraint.constant = width
    } else {
      let constraint = template.widthAnchor.constraint(equalToConstant: width)
      constraint.isActive = true
      sizingWidthConstraint = constraint
    }

    template.configure(
      partsRaw: partsRaw,
      accent: accent,
      onAction: { _ in },
      onCallRequested: {},
      onOpenLink: { _ in }
    )
    template.bounds = CGRect(x: 0, y: 0, width: width, height: 0)
    template.lastAvailableWidth = width
    template.setNeedsLayout()
    template.layoutIfNeeded()

    // CRITICAL: target height MUST be finite. An unconstrained dimension with
    // `.greatestFiniteMagnitude` as the fitting target can yield an infinite
    // row height → collection-view assertion. Finite 0 collapses to the
    // caller's floor instead.
    let size = template.systemLayoutSizeFitting(
      CGSize(width: width, height: 0.0),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )
    // Prefer the hosting sizeThatFits path — more reliable for SwiftUI hosts
    // than pure Auto Layout fitting when the graph is off-window.
    let hostingHeight = template.measuredContentHeight(forWidth: width)
    let height = max(size.height, hostingHeight)
    guard height.isFinite, height > 0 else { return 0 }
    return ceil(height)
  }
}
