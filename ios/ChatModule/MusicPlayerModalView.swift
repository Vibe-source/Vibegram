import SwiftUI
import UIKit

// MARK: - Audio level bars

/// Bottom-anchored equalizer bars — the "this row is playing" mark on the active
/// list row. Levels chase randomized targets with frame-rate-independent smoothing,
/// which reads like a real level meter rather than a mechanical sine.
final class NativeAudioBarsView: UIView {
  private let bars: [UIView]
  private var levels: [CGFloat]
  private var targets: [CGFloat]
  private var displayLink: CADisplayLink?
  private var retargetClock: CFTimeInterval = 0.0
  private var playing = false

  /// Level the bars settle on when paused (a low, calm resting state).
  private let restingLevel: CGFloat = 0.24

  var barColor: UIColor = .label {
    didSet { bars.forEach { $0.backgroundColor = barColor } }
  }

  init(barCount: Int = 4, color: UIColor = .label) {
    let count = max(3, barCount)
    bars = (0..<count).map { _ in
      let view = UIView()
      view.backgroundColor = color
      view.layer.cornerCurve = .continuous
      return view
    }
    levels = (0..<count).map { _ in CGFloat.random(in: 0.25...0.7) }
    targets = levels
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    bars.forEach { addSubview($0) }
    barColor = color
  }

  required init?(coder: NSCoder) { nil }

  deinit { displayLink?.invalidate() }

  func setPlaying(_ isPlaying: Bool) {
    guard playing != isPlaying else { return }
    playing = isPlaying
    if isPlaying {
      startLink()
    } else {
      stopLink()
      settleToResting()
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    // Never keep a display link alive off-screen.
    if window == nil {
      stopLink()
    } else if playing {
      startLink()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    applyLevels()
  }

  private func startLink() {
    guard displayLink == nil, window != nil else { return }
    let link = CADisplayLink(target: self, selector: #selector(step(_:)))
    link.preferredFrameRateRange = CAFrameRateRange(minimum: 30.0, maximum: 60.0, preferred: 60.0)
    link.add(to: .main, forMode: .common)
    displayLink = link
    retargetClock = 0.0
  }

  private func stopLink() {
    displayLink?.invalidate()
    displayLink = nil
  }

  private func settleToResting() {
    levels = levels.map { _ in restingLevel }
    targets = levels
    UIView.animate(
      withDuration: 0.28, delay: 0.0, options: [.beginFromCurrentState, .curveEaseOut]
    ) {
      self.applyLevels()
    }
  }

  @objc private func step(_ link: CADisplayLink) {
    let dt = max(1.0 / 120.0, min(1.0 / 20.0, link.targetTimestamp - link.timestamp))
    retargetClock += dt
    if retargetClock >= 0.085 {
      retargetClock = 0.0
      for index in targets.indices {
        // Outer bars peak lower than the middle — reads as a spectrum, not noise.
        let ceiling: CGFloat = (index == 0 || index == targets.count - 1) ? 0.74 : 1.0
        targets[index] = CGFloat.random(in: 0.22...ceiling)
      }
    }

    let smoothing = min(1.0, CGFloat(dt) * 15.0)
    var changed = false
    for index in levels.indices {
      let delta = targets[index] - levels[index]
      if abs(delta) > 0.002 {
        levels[index] += delta * smoothing
        changed = true
      }
    }
    if changed { applyLevels() }
  }

  private func applyLevels() {
    let count = CGFloat(bars.count)
    guard bounds.width > 1.0, bounds.height > 1.0, count > 0.0 else { return }
    let spacing = max(1.5, bounds.width * 0.10)
    let barWidth = max(1.5, (bounds.width - spacing * (count - 1.0)) / count)
    let radius = min(barWidth * 0.5, 2.0)
    for (index, bar) in bars.enumerated() {
      let level = max(0.12, min(1.0, levels[index]))
      let height = max(2.0, bounds.height * level)
      bar.frame = CGRect(
        x: CGFloat(index) * (barWidth + spacing),
        y: bounds.height - height,
        width: barWidth,
        height: height
      )
      bar.layer.cornerRadius = radius
    }
  }
}

/// SwiftUI face of `NativeAudioBarsView` so the list row and the header share one
/// visualizer implementation.
private struct NativeAudioBars: UIViewRepresentable {
  let isPlaying: Bool
  let color: UIColor

  func makeUIView(context: Context) -> NativeAudioBarsView {
    let view = NativeAudioBarsView(barCount: 4, color: color)
    view.setPlaying(isPlaying)
    return view
  }

  func updateUIView(_ uiView: NativeAudioBarsView, context: Context) {
    uiView.barColor = color
    uiView.setPlaying(isPlaying)
  }
}

// MARK: - Download snapshot

struct VoiceSnapshotDownloadInfo {
  let fraction: CGFloat?
  let downloadedBytes: Int64?
  let totalBytes: Int64?

  static func extract(from snapshot: VoiceBubblePlaybackSnapshot?) -> VoiceSnapshotDownloadInfo {
    guard let snapshot else {
      return VoiceSnapshotDownloadInfo(fraction: nil, downloadedBytes: nil, totalBytes: nil)
    }
    // Prefer the byte-derived fraction; fall back to the coarse downloadProgress
    // while a download is in flight.
    var frac = snapshot.downloadFraction
    if frac == nil && snapshot.isDownloading {
      frac = snapshot.downloadProgress
    }

    return VoiceSnapshotDownloadInfo(
      fraction: frac,
      downloadedBytes: snapshot.downloadedBytes,
      totalBytes: snapshot.totalBytes
    )
  }

  var isDownloading: Bool {
    fraction != nil || downloadedBytes != nil || totalBytes != nil
  }
}

// MARK: - Progress bar

/// Straight, thumbless scrub bar: track + buffered fill + played fill, all plain
/// views. No shape layers, no mask, no redraw — a progress tick resizes one view,
/// which is the whole point after the waveform version cost a masked offscreen
/// composite on every frame of every tick.
final class NativePlayerProgressBar: UIControl {
  private let trackView = UIView()
  private let bufferView = UIView()
  private let fillView = UIView()

  /// Resting visual thickness; the bar lifts under the finger while scrubbing.
  var barThickness: CGFloat = 5.0 {
    didSet {
      guard abs(barThickness - oldValue) > 0.05 else { return }
      layoutBars()
    }
  }

  private(set) var progress: CGFloat = 0.0
  private(set) var bufferProgress: CGFloat = 0.0
  private(set) var isScrubbing = false

  /// Live scrub position (continuous, while the finger is down).
  var onScrub: ((CGFloat) -> Void)?
  /// Final position on lift / cancel.
  var onCommit: ((CGFloat) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear

    trackView.clipsToBounds = true
    trackView.layer.cornerCurve = .continuous
    trackView.isUserInteractionEnabled = false
    addSubview(trackView)

    [bufferView, fillView].forEach {
      $0.isUserInteractionEnabled = false
      trackView.addSubview($0)
    }

    setColors(
      track: UIColor.label.withAlphaComponent(0.16),
      buffer: UIColor.label.withAlphaComponent(0.30),
      fill: UIColor.tintColor
    )
  }

  required init?(coder: NSCoder) { nil }

  func setColors(track: UIColor, buffer: UIColor, fill: UIColor) {
    trackView.backgroundColor = track
    bufferView.backgroundColor = buffer
    fillView.backgroundColor = fill
  }

  func setProgress(_ value: CGFloat, animated: Bool) {
    guard !isScrubbing else { return }
    let clamped = max(0.0, min(1.0, value.isFinite ? value : 0.0))
    let delta = clamped - progress
    guard abs(delta) > 0.0005 else { return }
    progress = clamped
    // Glide small forward ticks so the fill flows; snap on seek / track change.
    if animated, delta > 0.0, delta < 0.08 {
      UIView.animate(
        withDuration: 0.3, delay: 0.0,
        options: [.curveLinear, .beginFromCurrentState, .allowUserInteraction]
      ) {
        self.layoutBars()
      }
    } else {
      layoutBars()
    }
  }

  func setBuffer(_ value: CGFloat?) {
    let raw = value ?? 0.0
    let clamped = max(0.0, min(1.0, raw.isFinite ? raw : 0.0))
    guard abs(clamped - bufferProgress) > 0.002 else { return }
    bufferProgress = clamped
    layoutBars()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layoutBars()
  }

  private func layoutBars() {
    let height = isScrubbing ? barThickness * 1.9 : barThickness
    let y = floor((bounds.height - height) * 0.5)
    trackView.frame = CGRect(x: 0.0, y: y, width: bounds.width, height: height)
    trackView.layer.cornerRadius = height * 0.5
    bufferView.frame = CGRect(
      x: 0.0, y: 0.0, width: bounds.width * max(bufferProgress, progress), height: height)
    fillView.frame = CGRect(x: 0.0, y: 0.0, width: bounds.width * progress, height: height)
  }

  private func animateLift() {
    UIView.animate(
      withDuration: 0.2, delay: 0.0, usingSpringWithDamping: 0.74, initialSpringVelocity: 0.5,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.layoutBars()
    }
  }

  private func updateProgress(from touch: UITouch) {
    guard bounds.width > 1.0 else { return }
    let x = touch.location(in: self).x
    progress = max(0.0, min(1.0, x / bounds.width))
    layoutBars()
    onScrub?(progress)
  }

  override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
    isScrubbing = true
    UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
    animateLift()
    updateProgress(from: touch)
    return true
  }

  override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
    updateProgress(from: touch)
    return true
  }

  override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
    if let touch { updateProgress(from: touch) }
    isScrubbing = false
    animateLift()
    onCommit?(progress)
  }

  override func cancelTracking(with event: UIEvent?) {
    isScrubbing = false
    animateLift()
    onCommit?(progress)
  }

  /// Generous vertical hit slop — the drawn line is thin, the target is not.
  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    bounds.insetBy(dx: 0.0, dy: -12.0).contains(point)
  }
}

// MARK: - Player sheet

/// Two-mode player sheet.
///
/// **Compact (medium detent) — Now Playing:** hero artwork, title/artist, waveform
/// scrubber, transport. **Expanded (large detent) — Queue:** the hero collapses into
/// a now-playing row and the chat's audio list takes the whole sheet.
///
/// The two layouts are discrete states with one spring transition on detent change —
/// deliberately *not* a per-frame morph, which is what made the previous version
/// re-layout the hosted list on every display-link tick. The transport dock has
/// identical frames in both states, so the controls never move or flicker; only the
/// artwork, the labels and the list animate.
final class NativeMusicPlayerModalView: UIViewController, UISheetPresentationControllerDelegate {
  var onTogglePlayback: (() -> Void)?
  var onDismiss: (() -> Void)?
  var onPlayNext: (() -> Void)?
  var onPlayPrev: (() -> Void)?
  var onToggleQueueOrder: (() -> Void)?
  var onToggleRepeat: (() -> Void)?
  var onSeek: ((Double) -> Void)?
  var onSelectTrack: ((String) -> Void)?
  /// Persist a new list order (all displayed trackIds in drop order).
  var onReorderQueue: (([String]) -> Void)?
  /// Remove a track from the list.
  var onRemoveTrack: ((String) -> Void)?

  private let sheetContent = UIView()
  /// Flat surface, not a material. A blur is what gave the hero something to end
  /// *against*; fading the artwork into a solid colour leaves nothing to see a seam
  /// in — and it drops a full-screen live blur from every drag frame.
  private let backdropView = UIView()

  // Now playing — a contained artwork card at compact, a 52pt row thumb when expanded.
  private let artworkTapControl = UIControl()
  /// Casts the card's shadow. `artworkView` clips its image, and a clipping layer
  /// cannot draw a shadow, so the depth lives on a sibling underneath.
  private let artworkShadowView = UIView()
  private let artworkView = UIImageView()
  private let artworkFallbackView = UIImageView()
  private let titleLabel = UILabel()
  private let artistLabel = UILabel()
  private let headerBarsView = NativeAudioBarsView(barCount: 4)
  private let moreButton = UIButton(type: .system)

  // Scrubber + times.
  private let progressBar = NativePlayerProgressBar()
  private let elapsedLabel = UILabel()
  private let remainingLabel = UILabel()

  // List.
  private let sectionLabel = UILabel()
  private let queueHintButton = UIButton(type: .system)

  // Transport dock (identical frames in both states, no bar chrome behind it).
  private let orderButton = UIButton(type: .system)
  private let prevButton = UIButton(type: .system)
  private let playButton = UIControl()
  private let playGlyphView = UIImageView()
  private let nextButton = UIButton(type: .system)
  private let repeatButton = UIButton(type: .system)

  /// Native SwiftUI list (swipe: leading = Play Next, trailing = Delete; drag to
  /// reorder). Hosted inside the UIKit sheet so the chrome stays UIKit.
  private let queueModel = NativeMusicPlayerQueueModel()
  private lazy var queueHostingController = UIHostingController(
    rootView: NativeMusicPlayerQueueListView(model: queueModel))

  /// Compact detent: taller than `.medium()` so the now-playing hero has real room
  /// while still leaving the chat visible and interactive behind the sheet.
  static let compactDetentIdentifier = UISheetPresentationController.Detent.Identifier(
    "vibePlayerCompact")
  static func compactDetent() -> UISheetPresentationController.Detent {
    .custom(identifier: compactDetentIdentifier) { context in
      context.maximumDetentValue * 0.62
    }
  }

  private var theme = NativeMusicPlayerTheme()
  private var isShowing = false
  /// The one piece of layout state: which of the two compositions is on screen.
  private var isExpanded = false
  private var coverImageTask: URLSessionDataTask?

  private var currentTrack: NativeMusicPlayerTrack?
  private var currentState: (progressMs: Double, durationMs: Double, isPlaying: Bool) =
    (0.0, 0.0, false)
  private var currentQueue: [NativeMusicPlayerTrack] = []
  private var currentLibrary: [NativeMusicPlayerTrack] = []
  private var currentArtwork: UIImage?
  private var currentDownloadInfo = VoiceSnapshotDownloadInfo(
    fraction: nil, downloadedBytes: nil, totalBytes: nil)
  private var queueOrderMode: NativeMusicPlayerQueueOrderMode = .forward
  private var isRepeatEnabled = false

  // Render guards — `updateState` runs on every playback tick, so anything that
  // rebuilds a UIButton configuration, a menu or the list model has to be gated on a
  // real change. (Unguarded rebuilds were the source of the control-row flicker.)
  private var renderedPlayButtonIsPlaying: Bool?
  private var renderedQueueOrderMode: NativeMusicPlayerQueueOrderMode?
  private var renderedRepeatEnabled: Bool?
  private var renderedMenuTrackId: String?
  private var renderedSectionCount: Int = -1
  private var renderedCoverTrackId: String?
  private var renderedCoverURL: String?
  private var renderedCoverImageIdentifier: ObjectIdentifier?
  private var renderedQueueSignature: String?
  /// Fingerprint of the raw inputs the display list is derived from — the gate that
  /// keeps the per-tick list rebuild from happening at all.
  private var renderedQueueInputFingerprint: String?
  private var queueThumbRefreshScheduled = false
  private var renderedQueueTracks: [NativeMusicPlayerTrack] = []
  /// Session-local hides from a swipe-Delete (until rebuild forces a full refresh).
  private var suppressedTrackIds = Set<String>()
  /// When true, `renderedQueueTracks` is the authoritative display order (post-drag / remove).
  private var hasLocalQueueOrderOverride = false

  private enum Metrics {
    static let padCompact: CGFloat = 22.0
    static let padExpanded: CGFloat = 18.0
    /// Dock: taller than a toolbar so the controls sit in air, not in a strip.
    static let dockHeight: CGFloat = 82.0
    /// Hit targets — all five controls are bare glyphs, no plate behind any of them.
    static let playSide: CGFloat = 56.0
    static let navSide: CGFloat = 50.0
    static let utilitySide: CGFloat = 44.0
    /// Centre-to-centre offsets — even optical rhythm out from the play glyph.
    static let navOffset: CGFloat = 70.0
    static let utilityOffset: CGFloat = 138.0
    static let rowArtSide: CGFloat = 52.0
    static let scrubHeight: CGFloat = 22.0
    /// Hero card: floor keeps it readable on short sheets, corner is the card's shape.
    static let heroMinSide: CGFloat = 132.0
    static let heroCornerRadius: CGFloat = 22.0
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear

    sheetContent.clipsToBounds = false
    view.addSubview(sheetContent)

    backdropView.isUserInteractionEnabled = false
    sheetContent.addSubview(backdropView)

    // No mask, no fade, no blur under the artwork. Every attempt to dissolve a
    // full-bleed hero into the sheet produced the seam — a gradient's start *is* a
    // slope discontinuity and the eye finds it on any cover with detail there. A
    // contained card has no accidental edge at all: the boundary is a deliberate
    // rounded shape, which is what the eye expects to see.
    artworkShadowView.isUserInteractionEnabled = false
    artworkShadowView.layer.cornerCurve = .continuous
    artworkShadowView.layer.shadowColor = UIColor.black.cgColor
    artworkShadowView.layer.shadowOffset = CGSize(width: 0.0, height: 12.0)
    artworkShadowView.layer.shadowRadius = 26.0
    sheetContent.addSubview(artworkShadowView)

    artworkView.contentMode = .scaleAspectFill
    artworkView.clipsToBounds = true
    artworkView.layer.cornerCurve = .continuous
    artworkView.isUserInteractionEnabled = false
    sheetContent.addSubview(artworkView)

    artworkFallbackView.contentMode = .scaleAspectFit
    artworkFallbackView.image = UIImage(systemName: "music.note")
    artworkView.addSubview(artworkFallbackView)

    // Separate transparent target over the solid part of the hero only, so taps near
    // the scrubber or the times don't fire the detent toggle.
    artworkTapControl.addTarget(self, action: #selector(handleArtworkTap), for: .touchUpInside)
    sheetContent.addSubview(artworkTapControl)

    titleLabel.numberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail
    sheetContent.addSubview(titleLabel)

    artistLabel.numberOfLines = 1
    artistLabel.lineBreakMode = .byTruncatingTail
    sheetContent.addSubview(artistLabel)

    headerBarsView.isHidden = true
    sheetContent.addSubview(headerBarsView)

    moreButton.showsMenuAsPrimaryAction = true
    sheetContent.addSubview(moreButton)

    progressBar.onScrub = { [weak self] fraction in self?.handleScrub(fraction) }
    progressBar.onCommit = { [weak self] fraction in self?.handleScrubCommit(fraction) }
    sheetContent.addSubview(progressBar)

    elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    remainingLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    remainingLabel.textAlignment = .right
    sheetContent.addSubview(elapsedLabel)
    sheetContent.addSubview(remainingLabel)

    sectionLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    sectionLabel.isHidden = true
    sheetContent.addSubview(sectionLabel)

    // Compact-state advertisement for the second mode: says what is up there and
    // takes you there. Without it, the queue is invisible until you happen to drag.
    queueHintButton.addTarget(self, action: #selector(handleQueueHintTap), for: .touchUpInside)
    sheetContent.addSubview(queueHintButton)

    queueModel.onSelect = { [weak self] trackId in self?.onSelectTrack?(trackId) }
    queueModel.onPlayNext = { [weak self] trackId in self?.handlePlayNextTrack(trackId) }
    queueModel.onRemove = { [weak self] trackId in self?.handleRemoveTrack(trackId) }
    queueModel.onMove = { [weak self] orderedIds in self?.handleReorderTracks(orderedIds) }
    queueHostingController.view.backgroundColor = .clear
    queueHostingController.view.clipsToBounds = true
    queueHostingController.view.isHidden = true
    queueHostingController.view.alpha = 0.0
    if #available(iOS 16.4, *) {
      queueHostingController.safeAreaRegions = []
    }
    addChild(queueHostingController)
    sheetContent.addSubview(queueHostingController.view)
    queueHostingController.didMove(toParent: self)

    // Dock last so the controls sit above the list. There is no bar behind them —
    // no material, no hairline; the list simply ends where the dock begins.
    orderButton.addTarget(self, action: #selector(handleQueueOrderToggle), for: .touchUpInside)
    prevButton.addTarget(self, action: #selector(handlePrev), for: .touchUpInside)
    nextButton.addTarget(self, action: #selector(handleNext), for: .touchUpInside)
    repeatButton.addTarget(self, action: #selector(handleRepeatToggle), for: .touchUpInside)

    // Play/pause is a hand-built control, not a configured UIButton: no configuration
    // update pass on every layout, no bounce, no insets shifting under the glyph.
    playGlyphView.contentMode = .center
    playGlyphView.isUserInteractionEnabled = false
    playButton.addSubview(playGlyphView)
    playButton.addTarget(self, action: #selector(handlePlay), for: .touchUpInside)
    playButton.addTarget(self, action: #selector(handlePlayTouchDown), for: .touchDown)
    playButton.addTarget(
      self, action: #selector(handlePlayTouchRelease),
      for: [.touchUpInside, .touchUpOutside, .touchCancel])

    [orderButton, prevButton, playButton, nextButton, repeatButton].forEach {
      sheetContent.addSubview($0)
    }

    applyTheme(theme)
    applyModeTextStyling()
    applyModeAnimatableStyling()
  }

  required init?(coder: NSCoder) { nil }

  init() {
    super.init(nibName: nil, bundle: nil)
  }

  deinit { coverImageTask?.cancel() }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    isExpanded = (sheetPresentationController?.selectedDetentIdentifier == .large)
    applyModeTextStyling()
    applyModeAnimatableStyling()
    queueHostingController.view.isHidden = !isExpanded
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    isShowing = true
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed {
      isShowing = false
      // The only genuine teardown — a nil track mid-run is a transition, not a stop.
      _ = clearQueueRowsIfNeeded()
      onDismiss?()
    }
  }

  // MARK: - Mode

  func sheetPresentationControllerDidChangeSelectedDetentIdentifier(
    _ sheetPresentationController: UISheetPresentationController
  ) {
    setExpanded(
      sheetPresentationController.selectedDetentIdentifier == .large, animated: true)
  }

  private func setExpanded(_ expanded: Bool, animated: Bool) {
    guard isExpanded != expanded else { return }
    isExpanded = expanded

    guard animated, isViewLoaded, view.window != nil else {
      applyModeTextStyling()
      applyModeAnimatableStyling()
      queueHostingController.view.isHidden = !expanded
      view.setNeedsLayout()
      view.layoutIfNeeded()
      return
    }

    // Type can't tween, so the two labels swap font/colour behind a short dissolve of
    // *themselves only* — never a container-wide crossfade, which would double-expose
    // the transport dock and read as the exact flicker this replaced.
    UIView.transition(
      with: titleLabel, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]
    ) {
      self.applyModeTextStyling()
    }
    UIView.transition(
      with: artistLabel, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]
    ) {}

    if expanded { queueHostingController.view.isHidden = false }
    UIView.animate(
      withDuration: 0.42, delay: 0.0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.2,
      options: [.allowUserInteraction, .beginFromCurrentState]
    ) {
      self.applyModeAnimatableStyling()
      self.view.setNeedsLayout()
      self.view.layoutIfNeeded()
    } completion: { _ in
      if !expanded { self.queueHostingController.view.isHidden = true }
    }
  }

  private func requestDetent(_ expanded: Bool) {
    guard let sheet = sheetPresentationController else { return }
    let target: UISheetPresentationController.Detent.Identifier =
      expanded ? .large : Self.compactDetentIdentifier
    guard sheet.selectedDetentIdentifier != target else { return }
    sheet.animateChanges { sheet.selectedDetentIdentifier = target }
    // `animateChanges` doesn't call the delegate for programmatic changes.
    setExpanded(expanded, animated: true)
  }

  /// Fonts and text colours — swapped inside a dissolve, never interpolated.
  private func applyModeTextStyling() {
    titleLabel.font = .systemFont(ofSize: isExpanded ? 17 : 20, weight: .semibold)
    artistLabel.font = .systemFont(ofSize: isExpanded ? 13 : 14, weight: .regular)
    titleLabel.textColor = isExpanded ? UIColor.tintColor : UIColor.label
  }

  /// Properties that animate cleanly alongside the frame spring.
  private func applyModeAnimatableStyling() {
    let radius = isExpanded ? 10.0 : Metrics.heroCornerRadius
    artworkView.layer.cornerRadius = radius
    artworkShadowView.layer.cornerRadius = radius
    artworkShadowView.layer.shadowOpacity = theme.isDark ? 0.55 : 0.20
    artworkShadowView.alpha = isExpanded ? 0.0 : 1.0
    sectionLabel.alpha = isExpanded ? 1.0 : 0.0
    queueHostingController.view.alpha = isExpanded ? 1.0 : 0.0
    queueHintButton.alpha = isExpanded ? 0.0 : 1.0
    queueHintButton.isUserInteractionEnabled = !isExpanded
  }

  // MARK: - Theme

  func applyTheme(_ theme: NativeMusicPlayerTheme) {
    self.theme = theme
    view.backgroundColor = .clear

    backdropView.backgroundColor = UIColor.secondarySystemBackground
    artworkShadowView.layer.shadowOpacity = theme.isDark ? 0.55 : 0.20

    // All dynamic system colors: light/dark tracks the appearance with no re-theme
    // pass and no baked images anywhere in the sheet.
    artworkView.backgroundColor = UIColor.tertiarySystemFill
    artworkFallbackView.tintColor = UIColor.secondaryLabel
    artistLabel.textColor = UIColor.secondaryLabel
    elapsedLabel.textColor = UIColor.tertiaryLabel
    remainingLabel.textColor = UIColor.tertiaryLabel
    sectionLabel.textColor = UIColor.secondaryLabel
    headerBarsView.barColor = UIColor.tintColor

    progressBar.setColors(
      track: UIColor.label.withAlphaComponent(theme.isDark ? 0.20 : 0.14),
      buffer: UIColor.label.withAlphaComponent(theme.isDark ? 0.38 : 0.28),
      fill: UIColor.tintColor
    )

    moreButton.tintColor = UIColor.secondaryLabel
    moreButton.setImage(
      UIImage(systemName: "ellipsis")?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 18.0, weight: .semibold)),
      for: .normal
    )

    var hint = UIButton.Configuration.gray()
    hint.cornerStyle = .capsule
    hint.baseForegroundColor = UIColor.label
    hint.image = UIImage(systemName: "chevron.up")?.withConfiguration(
      UIImage.SymbolConfiguration(pointSize: 10.0, weight: .bold))
    hint.imagePadding = 6.0
    hint.contentInsets = NSDirectionalEdgeInsets(
      top: 7.0, leading: 14.0, bottom: 7.0, trailing: 14.0)
    queueHintButton.configuration = hint
    updateQueueHintTitle(count: renderedQueueTracks.count)

    applyGlyphButtonStyle(prevButton, systemName: "backward.fill", pointSize: 24.0, tint: .label)
    applyGlyphButtonStyle(nextButton, systemName: "forward.fill", pointSize: 24.0, tint: .label)
    applyPlayButtonStyle()
    renderedQueueOrderMode = nil
    renderedRepeatEnabled = nil
    updateQueueControlButtons()

    queueModel.applyAccent(UIColor.tintColor)
    view.setNeedsLayout()
  }

  // MARK: - State

  func updateState(
    track: NativeMusicPlayerTrack?,
    queue: [NativeMusicPlayerTrack],
    library: [NativeMusicPlayerTrack],
    isPlaying: Bool,
    progressMs: Double,
    durationMs: Double,
    queueOrderMode: NativeMusicPlayerQueueOrderMode,
    isRepeatEnabled: Bool,
    artworkImage: UIImage?,
    voiceSnapshot: VoiceBubblePlaybackSnapshot? = nil
  ) {
    currentTrack = track
    currentQueue = queue
    currentLibrary = library
    currentArtwork = artworkImage
    self.queueOrderMode = queueOrderMode
    self.isRepeatEnabled = isRepeatEnabled

    let downloadInfo = VoiceSnapshotDownloadInfo.extract(from: voiceSnapshot)
    currentDownloadInfo = downloadInfo

    guard let track else {
      // A nil track is almost always a *transition*, not a stop: the coordinator
      // publishes an empty snapshot between stopping one item and starting the next
      // (and while the next one downloads), which is what emptied the whole sheet
      // mid-tap. Keep the rows and just drop the now-playing marker — the next
      // update repaints them. Only a genuine teardown clears the list.
      headerBarsView.isHidden = true
      headerBarsView.setPlaying(false)
      updatePlayButton(isPlaying: false)
      queueModel.update(
        items: queueModel.items, activeTrackId: nil, isPlaying: false)
      renderedQueueSignature = nil
      renderedQueueInputFingerprint = nil
      refreshMoreMenu()
      return
    }

    titleLabel.text = track.title
    artistLabel.text = track.artist

    let effectiveDuration = max(durationMs, (track.durationSeconds ?? 0.0) * 1000.0)
    currentState = (progressMs, effectiveDuration, isPlaying)

    progressBar.setBuffer(downloadInfo.fraction)
    if !progressBar.isScrubbing {
      let duration = max(effectiveDuration, 1.0)
      progressBar.setProgress(
        CGFloat(max(0.0, min(1.0, progressMs / duration))), animated: true)
      elapsedLabel.text = Self.format(ms: progressMs)
      remainingLabel.text =
        downloadInfo.isDownloading
        ? Self.formatBytes(
          downloaded: downloadInfo.downloadedBytes, total: downloadInfo.totalBytes)
        : "-" + Self.format(ms: max(0.0, effectiveDuration - progressMs))
    }

    updatePlayButton(isPlaying: isPlaying)
    headerBarsView.isHidden = false
    headerBarsView.setPlaying(isPlaying)
    updateCoverIfNeeded(for: track, directImage: artworkImage)
    let listDidChange = updateQueueRowsIfNeeded(
      track: track, queue: queue, library: library)
    updateQueueControlButtons()
    refreshMoreMenu()

    if listDidChange { view.setNeedsLayout() }
  }

  var isModalVisible: Bool { isShowing }

  func show(animated: Bool = true) {
    guard !isShowing else { return }
    isShowing = true
    guard let controller = topMostViewController() else { return }
    controller.present(self, animated: animated)
  }

  @objc func dismissModal(animated: Bool = true) {
    dismiss(animated: animated)
  }

  // MARK: - Layout

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()

    let width = view.bounds.width
    let height = view.bounds.height
    let pad = isExpanded ? Metrics.padExpanded : Metrics.padCompact
    let usableWidth = max(0.0, width - pad * 2.0)

    sheetContent.frame = view.bounds
    backdropView.frame = sheetContent.bounds

    // — Transport dock: pinned to the bottom edge, byte-identical in both modes.
    //   It is laid out first and never participates in the mode transition.
    let safeBottom = view.safeAreaInsets.bottom
    let dockTop = height - (Metrics.dockHeight + safeBottom)
    layoutTransportControls(dockTop: dockTop, width: width)

    let moreSide: CGFloat = 34.0

    if isExpanded {
      // ── Queue mode ───────────────────────────────────────────────────────────
      let topY: CGFloat = 14.0
      let art = CGRect(
        x: pad, y: topY, width: Metrics.rowArtSide, height: Metrics.rowArtSide)
      layoutArtwork(art, fallbackInset: 15.0)
      artworkTapControl.frame = art

      let moreX = width - pad - moreSide
      let barsW: CGFloat = 18.0
      let textX = art.maxX + 12.0
      let textW = max(0.0, moreX - 10.0 - barsW - 8.0 - textX)
      let titleH: CGFloat = 21.0
      let artistH: CGFloat = 17.0
      let textY = art.midY - (titleH + 2.0 + artistH) * 0.5
      titleLabel.frame = CGRect(x: textX, y: textY, width: textW, height: titleH)
      artistLabel.frame = CGRect(
        x: textX, y: titleLabel.frame.maxY + 2.0, width: textW, height: artistH)
      headerBarsView.frame = CGRect(
        x: moreX - 10.0 - barsW, y: art.midY - 6.0, width: barsW, height: 13.0)
      moreButton.frame = CGRect(
        x: moreX, y: art.midY - moreSide * 0.5, width: moreSide, height: moreSide)

      // Inset, never full-bleed.
      progressBar.frame = CGRect(
        x: pad, y: art.maxY + 12.0, width: usableWidth, height: Metrics.scrubHeight)
      progressBar.barThickness = 4.0
      let timesY = progressBar.frame.maxY + 3.0
      elapsedLabel.frame = CGRect(x: pad, y: timesY, width: 90.0, height: 14.0)
      remainingLabel.frame = CGRect(
        x: width - pad - 140.0, y: timesY, width: 140.0, height: 14.0)

      sectionLabel.frame = CGRect(
        x: pad, y: elapsedLabel.frame.maxY + 16.0, width: usableWidth, height: 18.0)
      queueHintButton.center = CGPoint(x: width * 0.5, y: sectionLabel.frame.midY)

      let listY = sectionLabel.frame.maxY + 6.0
      layoutQueueHost(
        CGRect(
          x: pad - 8.0, y: listY,
          width: max(0.0, width - (pad - 8.0) * 2.0),
          height: max(0.0, dockTop - listY - 4.0)))
    } else {
      // ── Now-playing mode ─────────────────────────────────────────────────────
      // Everything under the artwork is measured *up from the dock*, so the stack is
      // fixed and only the card takes up the slack. The card is contained and
      // centred — it does not fill the sheet and it has no edge to hide.
      let hintHeight: CGFloat = 32.0
      let barsW: CGFloat = 20.0
      let moreX = width - pad - moreSide
      let textW = max(0.0, moreX - 12.0 - pad)

      let hintCenterY = dockTop - 10.0 - hintHeight * 0.5
      let timesY = hintCenterY - hintHeight * 0.5 - 12.0 - 14.0
      let scrubY = timesY - 3.0 - Metrics.scrubHeight
      let artistY = scrubY - 20.0 - 18.0
      let titleY = artistY - 1.0 - 25.0

      titleLabel.frame = CGRect(x: pad, y: titleY, width: textW, height: 25.0)
      artistLabel.frame = CGRect(
        x: pad, y: artistY, width: max(0.0, textW - barsW - 8.0), height: 18.0)
      headerBarsView.frame = CGRect(
        x: artistLabel.frame.maxX + 8.0, y: artistLabel.frame.maxY - 13.0,
        width: barsW, height: 13.0)
      moreButton.frame = CGRect(
        x: moreX, y: titleLabel.frame.midY - moreSide * 0.5,
        width: moreSide, height: moreSide)

      progressBar.frame = CGRect(
        x: pad, y: scrubY, width: usableWidth, height: Metrics.scrubHeight)
      progressBar.barThickness = 5.0
      elapsedLabel.frame = CGRect(x: pad, y: timesY, width: 90.0, height: 14.0)
      remainingLabel.frame = CGRect(
        x: width - pad - 140.0, y: timesY, width: 140.0, height: 14.0)

      // Square card, centred in whatever room the stack leaves it.
      let heroTopInset: CGFloat = 26.0
      let heroRoom = max(0.0, titleY - 24.0 - heroTopInset)
      let artSide = max(Metrics.heroMinSide, min(usableWidth, heroRoom))
      let art = CGRect(
        x: (width - artSide).rounded() * 0.5,
        y: (heroTopInset + max(0.0, (heroRoom - artSide) * 0.5)).rounded(),
        width: artSide, height: artSide)
      layoutArtwork(art, fallbackInset: artSide * 0.34)
      artworkTapControl.frame = art

      sectionLabel.frame = CGRect(
        x: pad, y: timesY + 24.0, width: usableWidth, height: 18.0)
      queueHintButton.sizeToFit()
      queueHintButton.center = CGPoint(x: width * 0.5, y: hintCenterY)

      // Parked (hidden) — zero-height so SwiftUI does no work at compact.
      layoutQueueHost(CGRect(x: pad, y: dockTop, width: usableWidth, height: 0.0))
    }
  }

  private func layoutArtwork(_ rect: CGRect, fallbackInset: CGFloat) {
    artworkView.frame = rect
    artworkShadowView.frame = rect
    artworkShadowView.layer.shadowPath = UIBezierPath(
      roundedRect: CGRect(origin: .zero, size: rect.size),
      cornerRadius: artworkShadowView.layer.cornerRadius
    ).cgPath
    artworkFallbackView.frame = artworkView.bounds.insetBy(
      dx: fallbackInset, dy: fallbackInset)
  }

  /// The hosted list's frame is set with animations **off**, always. Tweening it
  /// re-runs SwiftUI's whole `List` layout on every frame of the mode spring — that
  /// was the cost on expand, not the artwork. It snaps to its final size instead and
  /// fades in with the rest, so SwiftUI lays out exactly once per mode change.
  private func layoutQueueHost(_ rect: CGRect) {
    guard queueHostingController.view.frame != rect else { return }
    UIView.performWithoutAnimation {
      queueHostingController.view.frame = rect
      queueHostingController.view.layoutIfNeeded()
    }
  }

  /// Five controls on one optical centre line, spaced by centre-to-centre offsets so
  /// the rhythm holds regardless of glyph bounding boxes. Identical in both modes and
  /// recomputed from the same constants every pass — nothing here can drift.
  private func layoutTransportControls(dockTop: CGFloat, width: CGFloat) {
    let centerY = dockTop + Metrics.dockHeight * 0.5
    let centerX = width * 0.5
    // Squeeze the outer pair inward on narrow screens rather than clipping them.
    let maxUtilityOffset = max(0.0, width * 0.5 - Metrics.utilitySide * 0.5 - 14.0)
    let utilityOffset = min(Metrics.utilityOffset, maxUtilityOffset)
    let navOffset = min(Metrics.navOffset, utilityOffset - 44.0)

    func center(_ view: UIView, x: CGFloat, side: CGFloat) {
      view.bounds = CGRect(x: 0.0, y: 0.0, width: side, height: side)
      view.center = CGPoint(x: x, y: centerY)
    }

    center(playButton, x: centerX, side: Metrics.playSide)
    // `play.fill`'s visual mass sits left of its box; nudge it back to optical centre.
    let glyphOffset: CGFloat = (renderedPlayButtonIsPlaying == true) ? 0.0 : 2.0
    playGlyphView.frame = playButton.bounds.offsetBy(dx: glyphOffset, dy: 0.0)

    center(prevButton, x: centerX - navOffset, side: Metrics.navSide)
    center(nextButton, x: centerX + navOffset, side: Metrics.navSide)
    center(orderButton, x: centerX - utilityOffset, side: Metrics.utilitySide)
    center(repeatButton, x: centerX + utilityOffset, side: Metrics.utilitySide)
  }

  // MARK: - Actions

  @objc private func handlePlay() { onTogglePlayback?() }

  /// Next/Prev step through **the list this sheet is showing**, not the playback
  /// engine's in-memory queue. Those are different sets: the sheet also lists
  /// persisted chat tracks whose cells were never registered, and the engine's
  /// adjacency lookup returns nothing at all when the playing track is missing from
  /// its registry — which is why Next often did nothing. Selecting by id goes through
  /// the store-backed path, so every visible row is reachable. Falls back to the
  /// engine's own stepping when the sheet has no list of its own.
  @objc private func handlePrev() { step(by: -1) { self.onPlayPrev?() } }
  @objc private func handleNext() { step(by: 1) { self.onPlayNext?() } }

  private func step(by offset: Int, fallback: () -> Void) {
    let ids = renderedQueueTracks.map(\.trackId)
    guard ids.count > 1, let currentId = currentTrack?.trackId,
      let index = ids.firstIndex(of: currentId)
    else {
      fallback()
      return
    }
    let target = index + offset
    if ids.indices.contains(target) {
      onSelectTrack?(ids[target])
    } else if isRepeatEnabled {
      onSelectTrack?(offset > 0 ? ids[0] : ids[ids.count - 1])
    }
  }

  @objc private func handleQueueOrderToggle() { onToggleQueueOrder?() }
  @objc private func handleRepeatToggle() { onToggleRepeat?() }
  @objc private func handleQueueHintTap() { requestDetent(true) }

  @objc private func handleArtworkTap() { requestDetent(!isExpanded) }

  private func handleScrub(_ fraction: CGFloat) {
    let duration = max(currentState.durationMs, 1.0)
    let position = Double(fraction) * duration
    elapsedLabel.text = Self.format(ms: position)
    remainingLabel.text = "-" + Self.format(ms: max(0.0, duration - position))
  }

  private func handleScrubCommit(_ fraction: CGFloat) {
    onSeek?(Double(fraction) * max(currentState.durationMs, 1.0))
  }

  private func refreshMoreMenu() {
    guard let track = currentTrack else {
      if renderedMenuTrackId != nil {
        renderedMenuTrackId = nil
        moreButton.isEnabled = false
        moreButton.menu = nil
      }
      return
    }
    guard renderedMenuTrackId != track.trackId else { return }
    renderedMenuTrackId = track.trackId
    moreButton.isEnabled = true
    var actions: [UIAction] = [
      UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) {
        [weak self] _ in self?.handleShare()
      }
    ]
    if let url = shareURL(for: track), !url.isFileURL {
      actions.append(
        UIAction(title: "Copy Link", image: UIImage(systemName: "link")) { _ in
          UIPasteboard.general.url = url
        })
    }
    moreButton.menu = UIMenu(children: actions)
  }

  private func handleShare() {
    guard let currentTrack else { return }
    var items: [Any] = []
    let shareText = [currentTrack.title, currentTrack.artist]
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .joined(separator: " • ")
    if !shareText.isEmpty { items.append(shareText) }
    if let url = shareURL(for: currentTrack) { items.append(url) }
    guard !items.isEmpty, let controller = topMostViewController() else { return }
    let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
    if let popover = activity.popoverPresentationController {
      popover.sourceView = moreButton
      popover.sourceRect = moreButton.bounds
    }
    controller.present(activity, animated: true)
  }

  // MARK: - Button styling

  /// Plain `setImage` styling — deliberately no `UIButton.Configuration`, which would
  /// run a configuration update on every layout pass of every control in the dock.
  private func applyGlyphButtonStyle(
    _ button: UIButton, systemName: String, pointSize: CGFloat, tint: UIColor
  ) {
    button.tintColor = tint
    button.setImage(
      UIImage(systemName: systemName)?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)),
      for: .normal
    )
    button.adjustsImageWhenHighlighted = true
  }

  /// Bare glyph, no plate: the dock is five icons on one line, and play/pause earns
  /// its focus from size and weight rather than a filled circle.
  private func applyPlayButtonStyle() {
    playButton.backgroundColor = .clear
    playGlyphView.tintColor = UIColor.label
    renderedPlayButtonIsPlaying = nil
    updatePlayButtonImage()
  }

  private func updatePlayButton(isPlaying: Bool) {
    currentState.isPlaying = isPlaying
    updatePlayButtonImage()
  }

  /// Straight image swap. The glyph is centred by `layoutTransportControls`, so the
  /// button never resizes, never re-inserts insets and never springs — it is a static
  /// control that happens to change its picture.
  private func updatePlayButtonImage() {
    let targetIsPlaying = currentState.isPlaying
    guard renderedPlayButtonIsPlaying != targetIsPlaying else { return }
    renderedPlayButtonIsPlaying = targetIsPlaying
    playGlyphView.image = UIImage(systemName: targetIsPlaying ? "pause.fill" : "play.fill")?
      .withConfiguration(UIImage.SymbolConfiguration(pointSize: 36.0, weight: .medium))
    // Re-centre in place; no layout pass, so the dock cannot move.
    playGlyphView.frame = playButton.bounds.offsetBy(dx: targetIsPlaying ? 0.0 : 2.0, dy: 0.0)
  }

  @objc private func handlePlayTouchDown() { playButton.alpha = 0.72 }
  @objc private func handlePlayTouchRelease() { playButton.alpha = 1.0 }

  private func queueOrderIconName() -> String {
    switch queueOrderMode {
    case .forward: return "arrow.down"
    case .reverse: return "arrow.up"
    case .random: return "shuffle"
    }
  }

  /// Gated on real changes — rebuilding button configurations on every playback tick
  /// is what made the control row shimmer.
  private func updateQueueControlButtons() {
    if renderedQueueOrderMode != queueOrderMode {
      renderedQueueOrderMode = queueOrderMode
      applyGlyphButtonStyle(
        orderButton,
        systemName: queueOrderIconName(),
        pointSize: 16.0,
        tint: queueOrderMode == .forward ? UIColor.secondaryLabel : UIColor.tintColor
      )
    }
    if renderedRepeatEnabled != isRepeatEnabled {
      renderedRepeatEnabled = isRepeatEnabled
      applyGlyphButtonStyle(
        repeatButton,
        systemName: isRepeatEnabled ? "repeat.1" : "repeat",
        pointSize: 16.0,
        tint: isRepeatEnabled ? UIColor.tintColor : UIColor.secondaryLabel
      )
    }
  }

  private func updateQueueHintTitle(count: Int) {
    var config = queueHintButton.configuration
    let title = count > 0 ? "\(count) in this chat" : "Up next"
    config?.attributedTitle = AttributedString(
      title,
      attributes: AttributeContainer([
        .font: UIFont.systemFont(ofSize: 13, weight: .semibold)
      ]))
    queueHintButton.configuration = config
    queueHintButton.isHidden = count <= 0
    view.setNeedsLayout()
  }

  // MARK: - Artwork

  private func updateCoverIfNeeded(for track: NativeMusicPlayerTrack, directImage: UIImage?) {
    let normalizedCoverURL = track.cover?.trimmingCharacters(in: .whitespacesAndNewlines)
    let imageIdentifier = directImage.map(ObjectIdentifier.init)
    guard
      renderedCoverTrackId != track.trackId
        || renderedCoverURL != normalizedCoverURL
        || renderedCoverImageIdentifier != imageIdentifier
    else { return }

    renderedCoverTrackId = track.trackId
    renderedCoverURL = normalizedCoverURL
    renderedCoverImageIdentifier = imageIdentifier
    updateCover(urlString: normalizedCoverURL, directImage: directImage)
  }

  private func updateCover(urlString: String?, directImage: UIImage?) {
    coverImageTask?.cancel()
    coverImageTask = nil

    let applyImage: (UIImage) -> Void = { [weak self] image in
      guard let self else { return }
      self.artworkView.image = image
      self.artworkFallbackView.isHidden = true
    }

    if let directImage {
      applyImage(directImage)
      return
    }

    guard
      let trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else {
      artworkView.image = nil
      artworkFallbackView.isHidden = false
      return
    }

    // Keep the previous cover visible until the cached/network image arrives.
    if artworkView.image == nil { artworkFallbackView.isHidden = false }

    let expectedURL = trimmed
    let expectedTrackId = renderedCoverTrackId
    coverImageTask = chatLoadMusicCover(urlString: trimmed) { [weak self] image in
      guard let self else { return }
      guard self.renderedCoverURL == expectedURL,
        self.renderedCoverTrackId == expectedTrackId
      else { return }
      applyImage(image)
    }
  }

  // MARK: - List data

  private func updateQueueRowsIfNeeded(
    track: NativeMusicPlayerTrack,
    queue: [NativeMusicPlayerTrack],
    library: [NativeMusicPlayerTrack]
  ) -> Bool {
    // Cheapest possible gate, first. `updateState` runs on every playback tick, and
    // everything below walks / dedups / lowercases the whole chat list — several
    // times a second that is main-thread time taken straight out of the list's
    // scrolling. An id-join is O(n) string work; the rest is not.
    let fingerprint =
      track.trackId + "\u{1}" + queue.map(\.trackId).joined(separator: ",") + "\u{1}"
      + library.map(\.trackId).joined(separator: ",") + "\u{1}"
      + "\(suppressedTrackIds.count)\(hasLocalQueueOrderOverride ? "o" : "-")"
      + (currentState.isPlaying ? "1" : "0")
    guard renderedQueueInputFingerprint != fingerprint else { return false }
    renderedQueueInputFingerprint = fingerprint

    let tracks: [NativeMusicPlayerTrack]
    if hasLocalQueueOrderOverride, !renderedQueueTracks.isEmpty {
      // Keep drag/remove order; drop suppressed; append any newly-arrived tracks.
      var seen = Set(renderedQueueTracks.map(\.trackId))
      var merged = renderedQueueTracks.filter { !suppressedTrackIds.contains($0.trackId) }
      let fresh = resolvedDisplayTracks(currentTrack: track, queue: queue, library: library)
      for candidate in fresh where !seen.contains(candidate.trackId) {
        seen.insert(candidate.trackId)
        merged.append(candidate)
      }
      // Prefer fresher metadata (cover/title) for matching ids while keeping order.
      let byId = Dictionary(uniqueKeysWithValues: fresh.map { ($0.trackId, $0) })
      merged = merged.map { byId[$0.trackId] ?? $0 }
      tracks = merged
    } else {
      tracks = resolvedDisplayTracks(currentTrack: track, queue: queue, library: library)
    }

    renderedQueueTracks = tracks
    sectionLabel.isHidden = tracks.isEmpty

    let signature =
      tracks.map(\.trackId).joined(separator: ",") + "|" + track.trackId + "|"
      + (currentState.isPlaying ? "1" : "0")
    let structureChanged = renderedQueueSignature?.split(separator: "|").first
      != signature.split(separator: "|").first
    renderedQueueSignature = signature

    if renderedSectionCount != tracks.count {
      renderedSectionCount = tracks.count
      sectionLabel.text = tracks.count > 0 ? "Up next · \(tracks.count)" : "Up next"
      updateQueueHintTitle(count: tracks.count)
    }

    queueModel.update(
      items: queueRowVMs(for: tracks, activeTrackId: track.trackId),
      activeTrackId: track.trackId,
      isPlaying: currentState.isPlaying)

    return structureChanged
  }

  private func queueRowVMs(
    for tracks: [NativeMusicPlayerTrack], activeTrackId: String?
  ) -> [NativeMusicPlayerQueueRowVM] {
    tracks.map { candidate in
      let cover = candidate.cover?.trimmingCharacters(in: .whitespacesAndNewlines)
      let coverURL = (cover?.isEmpty == false) ? cover : nil
      let direct =
        ChatAudioQueueRegistry.shared.artwork(
          for: candidate.trackId, in: candidate.links["chat_id"])
        ?? (candidate.trackId == activeTrackId ? currentArtwork : nil)
      let thumb = NativeMusicPlayerThumbCache.shared.thumb(
        key: coverURL ?? candidate.trackId,
        source: direct,
        coverURL: coverURL
      ) { [weak self] in self?.scheduleQueueThumbRefresh() }
      return NativeMusicPlayerQueueRowVM(
        id: candidate.trackId,
        title: candidate.title,
        subtitle: queueSubtitle(for: candidate),
        thumb: thumb
      )
    }
  }

  /// A thumbnail landing is not a list change — coalesce every arrival in one run
  /// loop turn into a single model update instead of one per row.
  private func scheduleQueueThumbRefresh() {
    guard !queueThumbRefreshScheduled else { return }
    queueThumbRefreshScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.queueThumbRefreshScheduled = false
      guard !self.renderedQueueTracks.isEmpty else { return }
      self.queueModel.update(
        items: self.queueRowVMs(
          for: self.renderedQueueTracks, activeTrackId: self.currentTrack?.trackId),
        activeTrackId: self.queueModel.activeTrackId,
        isPlaying: self.queueModel.isPlaying)
    }
  }

  private func queueSubtitle(for track: NativeMusicPlayerTrack) -> String {
    let parts = [track.duration, track.artist].compactMap { value -> String? in
      guard let value, !value.isEmpty else { return nil }
      return value
    }
    return parts.isEmpty ? "Audio" : parts.joined(separator: " • ")
  }

  private func clearQueueRowsIfNeeded() -> Bool {
    guard !renderedQueueTracks.isEmpty else { return false }
    renderedQueueTracks = []
    renderedQueueSignature = nil
    renderedQueueInputFingerprint = nil
    renderedSectionCount = -1
    suppressedTrackIds.removeAll()
    hasLocalQueueOrderOverride = false
    queueModel.update(items: [], activeTrackId: nil, isPlaying: false)
    updateQueueHintTitle(count: 0)
    return true
  }

  /// Chat music list, deduped by trackId and by exact title+artist so the same song
  /// never appears twice, and always containing the currently-playing track.
  ///
  /// `queue` already carries the store's chat tracks and the registry's — the
  /// presenter merges them before it calls in. Re-querying them here ran the store's
  /// filter-plus-locale-sort a second time on every playback tick for no new rows.
  private func resolvedDisplayTracks(
    currentTrack: NativeMusicPlayerTrack,
    queue: [NativeMusicPlayerTrack],
    library: [NativeMusicPlayerTrack]
  ) -> [NativeMusicPlayerTrack] {
    var seenIds = Set<String>()
    var seenTitleArtist = Set<String>()
    var tracks: [NativeMusicPlayerTrack] = []

    func identityKey(_ track: NativeMusicPlayerTrack) -> String {
      let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return "\(title)|\(artist)"
    }

    func append(_ candidates: [NativeMusicPlayerTrack]) {
      for candidate in candidates {
        if suppressedTrackIds.contains(candidate.trackId) { continue }
        guard seenIds.insert(candidate.trackId).inserted else { continue }
        let key = identityKey(candidate)
        // Drop exact title+artist duplicates (different ids for the same song).
        if !key.hasPrefix("|"), !seenTitleArtist.insert(key).inserted { continue }
        tracks.append(candidate)
      }
    }

    append(queue)
    append(library)
    // Currently-playing track must always appear (even if missing from store/queue).
    if !suppressedTrackIds.contains(currentTrack.trackId),
      seenIds.insert(currentTrack.trackId).inserted
    {
      let key = identityKey(currentTrack)
      if key.hasPrefix("|") || seenTitleArtist.insert(key).inserted {
        tracks.insert(currentTrack, at: 0)
      }
    } else if !suppressedTrackIds.contains(currentTrack.trackId) {
      // Already present by id — prefer richer cover metadata on the playing row.
      if let idx = tracks.firstIndex(where: { $0.trackId == currentTrack.trackId }),
        tracks[idx].cover == nil, currentTrack.cover != nil
      {
        tracks[idx] = currentTrack
      }
    }
    return tracks
  }

  // MARK: - List swipe / reorder callbacks

  /// Trailing swipe → Delete: hide the track locally and persist the remaining order.
  private func handleRemoveTrack(_ trackId: String) {
    suppressedTrackIds.insert(trackId)
    hasLocalQueueOrderOverride = true
    renderedQueueTracks.removeAll { $0.trackId == trackId }
    renderedQueueSignature = nil
    renderedQueueInputFingerprint = nil
    onRemoveTrack?(trackId)
    onReorderQueue?(renderedQueueTracks.map(\.trackId))
    queueModel.update(
      items: queueModel.items.filter { $0.id != trackId },
      activeTrackId: queueModel.activeTrackId,
      isPlaying: queueModel.isPlaying)
    renderedSectionCount = renderedQueueTracks.count
    sectionLabel.text =
      renderedQueueTracks.isEmpty ? "Up next" : "Up next · \(renderedQueueTracks.count)"
    updateQueueHintTitle(count: renderedQueueTracks.count)
  }

  /// Leading swipe → Play Next: move the track to immediately after the current one.
  private func handlePlayNextTrack(_ trackId: String) {
    let currentId = queueModel.activeTrackId ?? currentTrack?.trackId
    guard let currentId, currentId != trackId else { return }
    var order = renderedQueueTracks.map(\.trackId)
    guard let from = order.firstIndex(of: trackId),
      let currentIndex = order.firstIndex(of: currentId)
    else { return }
    order.remove(at: from)
    let insertAt = min(currentIndex + 1, order.count)
    order.insert(trackId, at: insertAt)
    applyLocalOrder(order)
  }

  /// Drag-to-reorder (SwiftUI `.onMove`): adopt the new order and persist it.
  private func handleReorderTracks(_ orderedIds: [String]) {
    applyLocalOrder(orderedIds)
  }

  private func applyLocalOrder(_ orderedIds: [String]) {
    let byId = Dictionary(
      renderedQueueTracks.map { ($0.trackId, $0) }, uniquingKeysWith: { a, _ in a })
    renderedQueueTracks = orderedIds.compactMap { byId[$0] }
    hasLocalQueueOrderOverride = true
    renderedQueueSignature = nil
    renderedQueueInputFingerprint = nil
    onReorderQueue?(orderedIds)
    let orderRank = Dictionary(uniqueKeysWithValues: orderedIds.enumerated().map { ($1, $0) })
    let reordered = queueModel.items.sorted {
      (orderRank[$0.id] ?? Int.max) < (orderRank[$1.id] ?? Int.max)
    }
    queueModel.update(
      items: reordered, activeTrackId: queueModel.activeTrackId, isPlaying: queueModel.isPlaying)
  }

  // MARK: - Helpers

  private func shareURL(for track: NativeMusicPlayerTrack) -> URL? {
    let candidates = [track.localURI, track.streamURL, track.previewURL, track.cover]
    for candidate in candidates {
      guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
        !trimmed.isEmpty
      else { continue }
      if let url = URL(string: trimmed) { return url }
      if trimmed.hasPrefix("/") { return URL(fileURLWithPath: trimmed) }
    }
    return nil
  }

  private func topMostViewController() -> UIViewController? {
    guard
      let root =
        view.window?.rootViewController
        ?? UIApplication.shared.connectedScenes
        .compactMap({ scene -> UIViewController? in
          guard let windowScene = scene as? UIWindowScene else { return nil }
          return windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        })
        .first
    else { return nil }
    var top = root
    while let presented = top.presentedViewController {
      top = presented
    }
    return top
  }

  static func format(ms: Double) -> String {
    guard ms.isFinite, ms > 0.0 else { return "0:00" }
    let seconds = Int((ms / 1000.0).rounded())
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }

  static func formatBytes(downloaded: Int64?, total: Int64?) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useMB, .useKB, .useBytes]
    if let downloaded = downloaded, let total = total, total > 0 {
      return
        "\(formatter.string(fromByteCount: downloaded)) / \(formatter.string(fromByteCount: total))"
    } else if let downloaded = downloaded {
      return formatter.string(fromByteCount: downloaded)
    } else if let total = total, total > 0 {
      return formatter.string(fromByteCount: total)
    }
    return "Downloading…"
  }
}

// MARK: - SwiftUI list (native swipe + drag-reorder)

/// Row artwork, prepared once per cover: downsampled to the row size and rounded
/// *into the bitmap*. The list then draws a plain `Image` — no `clipShape` mask
/// (which is an offscreen composite per row, per frame, while scrolling), no decode
/// of a 1000px cover into a 48pt box, and no I/O started from a SwiftUI view body.
final class NativeMusicPlayerThumbCache {
  static let shared = NativeMusicPlayerThumbCache()
  static let side: CGFloat = 48.0
  static let cornerRadius: CGFloat = 12.0

  private let cache = NSCache<NSString, UIImage>()
  /// Main-thread only — every entry point and every completion lands there.
  private var inFlight = Set<String>()
  private let renderQueue = DispatchQueue(
    label: "vibe.player.queueThumbs", qos: .userInitiated)

  private init() { cache.countLimit = 300 }

  /// The ready thumbnail, or nil having started preparing one. `onReady` fires on the
  /// main thread when a new thumb lands; callers coalesce.
  func thumb(
    key: String, source: UIImage?, coverURL: String?, onReady: @escaping () -> Void
  ) -> UIImage? {
    if let hit = cache.object(forKey: key as NSString) { return hit }
    guard !inFlight.contains(key) else { return nil }
    if let source {
      inFlight.insert(key)
      render(key: key, image: source, onReady: onReady)
      return nil
    }
    guard let coverURL, !coverURL.isEmpty else { return nil }
    inFlight.insert(key)
    chatLoadMusicCover(urlString: coverURL) { [weak self] image in
      self?.render(key: key, image: image, onReady: onReady)
    }
    return nil
  }

  private func render(key: String, image: UIImage, onReady: @escaping () -> Void) {
    renderQueue.async { [weak self] in
      let side = Self.side
      let format = UIGraphicsImageRendererFormat.preferred()
      format.opaque = false
      let thumb = UIGraphicsImageRenderer(
        size: CGSize(width: side, height: side), format: format
      ).image { _ in
        UIBezierPath(
          roundedRect: CGRect(x: 0.0, y: 0.0, width: side, height: side),
          cornerRadius: Self.cornerRadius
        ).addClip()
        let source = image.size
        guard source.width > 0.0, source.height > 0.0 else { return }
        // Aspect fill, centred.
        let scale = max(side / source.width, side / source.height)
        let drawn = CGSize(width: source.width * scale, height: source.height * scale)
        image.draw(
          in: CGRect(
            x: (side - drawn.width) * 0.5, y: (side - drawn.height) * 0.5,
            width: drawn.width, height: drawn.height))
      }
      DispatchQueue.main.async {
        guard let self else { return }
        self.cache.setObject(thumb, forKey: key as NSString)
        self.inFlight.remove(key)
        onReady()
      }
    }
  }
}

struct NativeMusicPlayerQueueRowVM: Identifiable, Equatable {
  let id: String
  let title: String
  let subtitle: String
  let thumb: UIImage?

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.id == rhs.id && lhs.title == rhs.title && lhs.subtitle == rhs.subtitle
      && lhs.thumb === rhs.thumb
  }
}

/// Drives the hosted SwiftUI list. The sheet pushes state in; the list calls back for
/// select / play-next / delete / reorder.
final class NativeMusicPlayerQueueModel: ObservableObject {
  @Published fileprivate var items: [NativeMusicPlayerQueueRowVM] = []
  @Published fileprivate var activeTrackId: String?
  @Published fileprivate var isPlaying: Bool = false
  @Published fileprivate var accentUIColor: UIColor = .tintColor

  var onSelect: ((String) -> Void)?
  var onPlayNext: ((String) -> Void)?
  var onRemove: ((String) -> Void)?
  var onMove: (([String]) -> Void)?

  /// Text uses SwiftUI's semantic `.primary` / `.secondary`, so only the accent has
  /// to be pushed in — light/dark then tracks the system appearance on its own.
  func applyAccent(_ accent: UIColor) {
    if accentUIColor != accent { accentUIColor = accent }
  }

  func update(items: [NativeMusicPlayerQueueRowVM], activeTrackId: String?, isPlaying: Bool) {
    if self.items != items { self.items = items }
    if self.activeTrackId != activeTrackId { self.activeTrackId = activeTrackId }
    if self.isPlaying != isPlaying { self.isPlaying = isPlaying }
  }
}

struct NativeMusicPlayerQueueListView: View {
  @ObservedObject var model: NativeMusicPlayerQueueModel

  var body: some View {
    List {
      ForEach(model.items) { item in
        // Button (not onTapGesture): List + swipeActions + onMove often swallows
        // plain taps; a plain-styled button is the reliable select target.
        Button {
          model.onSelect?(item.id)
        } label: {
          NativeMusicPlayerQueueRow(
            item: item,
            isActive: item.id == model.activeTrackId,
            isPlaying: model.isPlaying,
            accentUIColor: model.accentUIColor
          )
          .contentShape(Rectangle())
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        .listRowSeparator(.hidden)
        .listRowBackground(
          Group {
            if item.id == model.activeTrackId {
              RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: model.accentUIColor).opacity(0.12))
                .padding(.vertical, 1)
            } else {
              Color.clear
            }
          }
        )
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
          Button {
            model.onPlayNext?(item.id)
          } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
          }
          .tint(Color(uiColor: model.accentUIColor))
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
          Button(role: .destructive) {
            model.onRemove?(item.id)
          } label: {
            Label("Delete", systemImage: "trash")
          }
        }
      }
      .onMove { indices, newOffset in
        var arr = model.items
        arr.move(fromOffsets: indices, toOffset: newOffset)
        model.items = arr
        model.onMove?(arr.map(\.id))
      }
    }
    .listStyle(.plain)
    .clearListBackground()
    .background(Color.clear)
    .environment(\.defaultMinListRowHeight, 62)
  }
}

private struct NativeMusicPlayerQueueRow: View {
  let item: NativeMusicPlayerQueueRowVM
  let isActive: Bool
  let isPlaying: Bool
  let accentUIColor: UIColor

  var body: some View {
    HStack(spacing: 12) {
      NativeMusicPlayerQueueArtwork(thumb: item.thumb)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.system(size: 16, weight: isActive ? .semibold : .regular))
          .foregroundStyle(isActive ? Color(uiColor: accentUIColor) : Color.primary)
          .lineLimit(1)
        Text(item.subtitle)
          .font(.system(size: 13, weight: .regular))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      // The playing row says "playing", not "selected" — live bars, no checkmark.
      // Every other row shows the reorder grip instead.
      if isActive {
        NativeAudioBars(isPlaying: isPlaying, color: accentUIColor)
          .frame(width: 16, height: 13)
          .padding(.trailing, 4)
      } else {
        Image(systemName: "line.3.horizontal")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.tertiary)
          .padding(.trailing, 2)
      }
    }
    .padding(.vertical, 7)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Purely passive: the bitmap arrives already sized and already rounded, so this does
/// no clipping, no scaling and no loading while the list scrolls.
private struct NativeMusicPlayerQueueArtwork: View {
  let thumb: UIImage?

  var body: some View {
    Group {
      if let thumb {
        Image(uiImage: thumb)
      } else {
        ZStack {
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(uiColor: .tertiarySystemFill))
          Image(systemName: "music.note")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.secondary)
        }
      }
    }
    .frame(width: 48, height: 48)
  }
}

extension View {
  /// Clears the List's default opaque background where supported (iOS 16+).
  @ViewBuilder fileprivate func clearListBackground() -> some View {
    if #available(iOS 16.0, *) {
      self.scrollContentBackground(.hidden)
    } else {
      self
    }
  }
}
