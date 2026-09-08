import ImageIO
import OSLog
import SwiftUI
import UIKit

private let settingsNativeUITraceLogger = Logger(
  subsystem: "com.mohammadshayani.vibe.native",
  category: "UITrace"
)

private func settingsNativeUITrace(_ message: String) {
  settingsNativeUITraceLogger.notice("\(message, privacy: .public)")
  NSLog("[VibeUITrace] %@", message)
}

enum SettingsNativeRowKind {
  case link
  case toggle
}

struct SettingsNativeRow: Identifiable, Equatable {
  let id: String
  let icon: String
  let label: String
  let detailText: String?
  let toggleValue: Bool
  let kind: SettingsNativeRowKind
  let iconColor: UIColor
  let divider: Bool
  let destructive: Bool
}

struct SettingsNativeSection: Identifiable, Equatable {
  var id: String { title ?? "section_\(rows.first?.id ?? UUID().uuidString)" }
  let title: String?
  let rows: [SettingsNativeRow]
}

struct SettingsNativeTheme {
  let background: UIColor
  let card: UIColor
  let text: UIColor
  let secondaryText: UIColor
  let primary: UIColor
  let isDark: Bool

  init(palette: AppThemePalette, isDark: Bool) {
    self.background = palette.backgroundUIColor
    self.card = palette.cardUIColor
    self.text = palette.textUIColor
    self.secondaryText = palette.secondaryTextUIColor
    self.primary = palette.accentUIColor
    self.isDark = isDark
  }
}

/// Plain UIView row (not UIControl) so pan-on-row always belongs to UIScrollView.
final class SettingsNativeRowView: UIView, UIGestureRecognizerDelegate {
  private let highlightOverlayView = UIView()
  private let iconBackgroundView = UIView()
  private let iconView = UIImageView()
  private let titleLabel = UILabel()
  private let valueLabel = UILabel()
  private let chevronImageView = UIImageView()
  private let switchControl = UISwitch()
  private let dividerView = UIView()

  private var currentRow: SettingsNativeRow?
  private var currentTheme: SettingsNativeTheme?
  private var onPress: (() -> Void)?
  private var onToggle: ((Bool) -> Void)?
  private var isPressed = false
  private let tapRecognizer = UITapGestureRecognizer()

  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: 62)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)

    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear
    isAccessibilityElement = true
    accessibilityTraits = .button

    // Tap does not steal the scroll pan (fails once drag exceeds system slop).
    tapRecognizer.addTarget(self, action: #selector(handleTap))
    tapRecognizer.cancelsTouchesInView = false
    tapRecognizer.delegate = self
    addGestureRecognizer(tapRecognizer)

    highlightOverlayView.translatesAutoresizingMaskIntoConstraints = false
    highlightOverlayView.isUserInteractionEnabled = false
    highlightOverlayView.alpha = 0
    addSubview(highlightOverlayView)

    // Slightly roomier tiles: 34×34, corner 8, larger glyph, softer tint.
    iconBackgroundView.translatesAutoresizingMaskIntoConstraints = false
    iconBackgroundView.layer.cornerRadius = 8
    iconBackgroundView.clipsToBounds = true
    if #available(iOS 13.0, *) {
      iconBackgroundView.layer.cornerCurve = .continuous
    }
    iconBackgroundView.backgroundColor = UIColor.white.withAlphaComponent(0.10)
    iconBackgroundView.isUserInteractionEnabled = false
    addSubview(iconBackgroundView)

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.contentMode = .scaleAspectFit
    iconView.isUserInteractionEnabled = false
    addSubview(iconView)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 17, weight: .regular)
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    titleLabel.isUserInteractionEnabled = false
    addSubview(titleLabel)

    valueLabel.translatesAutoresizingMaskIntoConstraints = false
    valueLabel.font = .systemFont(ofSize: 16, weight: .regular)
    valueLabel.textAlignment = .right
    valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    valueLabel.setContentHuggingPriority(.required, for: .horizontal)
    valueLabel.isUserInteractionEnabled = false
    addSubview(valueLabel)

    chevronImageView.translatesAutoresizingMaskIntoConstraints = false
    chevronImageView.contentMode = .scaleAspectFit
    chevronImageView.setContentCompressionResistancePriority(.required, for: .horizontal)
    chevronImageView.setContentHuggingPriority(.required, for: .horizontal)
    chevronImageView.isUserInteractionEnabled = false
    chevronImageView.image = UIImage(
      systemName: "chevron.right",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
    )
    addSubview(chevronImageView)

    switchControl.translatesAutoresizingMaskIntoConstraints = false
    switchControl.setContentCompressionResistancePriority(.required, for: .horizontal)
    switchControl.setContentHuggingPriority(.required, for: .horizontal)
    switchControl.addTarget(self, action: #selector(handleSwitchChanged), for: .valueChanged)
    addSubview(switchControl)

    dividerView.translatesAutoresizingMaskIntoConstraints = false
    dividerView.isUserInteractionEnabled = false
    addSubview(dividerView)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 62),

      highlightOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
      highlightOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
      highlightOverlayView.topAnchor.constraint(equalTo: topAnchor),
      highlightOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor),

      // More edge air (16) + larger icon tile (34) + roomier vertical pad (16).
      iconBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      iconBackgroundView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconBackgroundView.widthAnchor.constraint(equalToConstant: 34),
      iconBackgroundView.heightAnchor.constraint(equalToConstant: 34),

      iconView.centerXAnchor.constraint(equalTo: iconBackgroundView.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: iconBackgroundView.centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 18),
      iconView.heightAnchor.constraint(equalToConstant: 18),

      titleLabel.leadingAnchor.constraint(equalTo: iconBackgroundView.trailingAnchor, constant: 14),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      chevronImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      chevronImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
      chevronImageView.widthAnchor.constraint(equalToConstant: 12),
      chevronImageView.heightAnchor.constraint(equalToConstant: 14),

      valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
      valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      valueLabel.trailingAnchor.constraint(equalTo: chevronImageView.leadingAnchor, constant: -8),

      switchControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      switchControl.centerYAnchor.constraint(equalTo: centerYAnchor),
      switchControl.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),

      dividerView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      dividerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      dividerView.bottomAnchor.constraint(equalTo: bottomAnchor),
      dividerView.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),

      topAnchor.constraint(lessThanOrEqualTo: titleLabel.topAnchor, constant: 16),
      bottomAnchor.constraint(greaterThanOrEqualTo: titleLabel.bottomAnchor, constant: 16),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(
    row: SettingsNativeRow,
    theme: SettingsNativeTheme,
    onPress: (() -> Void)?,
    onToggle: ((Bool) -> Void)?
  ) {
    currentRow = row
    currentTheme = theme
    self.onPress = onPress
    self.onToggle = onToggle

    accessibilityLabel = row.label

    let hasAccent = row.iconColor.cgColor.alpha > 0.01
    // Soften tile tint (was full system color — read as too loud).
    iconBackgroundView.backgroundColor =
      hasAccent
      ? row.iconColor.withAlphaComponent(theme.isDark ? 0.78 : 0.88)
      : (theme.isDark ? UIColor.white : UIColor.black).withAlphaComponent(theme.isDark ? 0.10 : 0.08)
    // Falls back to the asset catalog so a row can ship its own vector glyph.
    iconView.image =
      UIImage(
        systemName: row.icon,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
      ) ?? UIImage(named: row.icon)?.withRenderingMode(.alwaysTemplate)
    iconView.tintColor = hasAccent ? .white : theme.secondaryText.withAlphaComponent(theme.isDark ? 0.92 : 0.78)
    titleLabel.text = row.label
    titleLabel.textColor =
      row.destructive
      ? UIColor(red: 239 / 255, green: 68 / 255, blue: 68 / 255, alpha: 1.0)
      : theme.text
    valueLabel.text = row.detailText
    valueLabel.textColor = theme.secondaryText
    dividerView.isHidden = !row.divider
    dividerView.backgroundColor =
      (theme.isDark ? UIColor.white : UIColor.black).withAlphaComponent(theme.isDark ? 0.10 : 0.08)

    switch row.kind {
    case .link:
      chevronImageView.isHidden = false
      valueLabel.isHidden = row.detailText == nil
      switchControl.isHidden = true
      accessibilityTraits = .button
    case .toggle:
      chevronImageView.isHidden = true
      valueLabel.isHidden = true
      switchControl.isHidden = false
      switchControl.onTintColor = .systemGreen
      switchControl.setOn(row.toggleValue, animated: false)
      accessibilityTraits = .none
      isAccessibilityElement = false
    }

    chevronImageView.tintColor =
      (theme.isDark ? UIColor.white : UIColor.black).withAlphaComponent(theme.isDark ? 0.5 : 0.32)
    setPressed(false, animated: false)
  }

  @objc private func handleTap() {
    guard let row = currentRow else { return }
    switch row.kind {
    case .toggle:
      let nextValue = !switchControl.isOn
      switchControl.setOn(nextValue, animated: true)
      onToggle?(nextValue)
    case .link:
      onPress?()
    }
  }

  @objc private func handleSwitchChanged() {
    onToggle?(switchControl.isOn)
  }

  // MARK: - Press highlight (UIView — scroll pan cancels via touchesCancelled)

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesBegan(touches, with: event)
    guard currentRow?.kind == .link else { return }
    setPressed(true, animated: true)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesEnded(touches, with: event)
    setPressed(false, animated: true)
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesCancelled(touches, with: event)
    setPressed(false, animated: true)
  }

  private func setPressed(_ pressed: Bool, animated: Bool) {
    isPressed = pressed
    guard let row = currentRow, let theme = currentTheme else { return }
    let isLink = row.kind == .link
    let targetAlpha: CGFloat = isLink && pressed ? 1 : 0
    let targetOverlayColor =
      theme.isDark
      ? UIColor.white.withAlphaComponent(0.12)
      : UIColor.black.withAlphaComponent(0.06)

    let updates = {
      self.highlightOverlayView.backgroundColor = targetOverlayColor
      self.highlightOverlayView.alpha = targetAlpha
    }
    if animated {
      UIView.animate(
        withDuration: 0.12,
        delay: 0,
        options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState],
        animations: updates
      )
    } else {
      updates()
    }
  }

  // MARK: UIGestureRecognizerDelegate

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
    -> Bool
  {
    // Let UISwitch own its touches.
    if let view = touch.view, view is UISwitch || view.isDescendant(of: switchControl) {
      return false
    }
    return true
  }
}

final class SettingsNativeRowContainerView: UIView {
  private let rowView = SettingsNativeRowView()

  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: 62)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)

    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear

    rowView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(rowView)

    NSLayoutConstraint.activate([
      rowView.leadingAnchor.constraint(equalTo: leadingAnchor),
      rowView.trailingAnchor.constraint(equalTo: trailingAnchor),
      rowView.topAnchor.constraint(equalTo: topAnchor),
      rowView.bottomAnchor.constraint(equalTo: bottomAnchor),
      heightAnchor.constraint(greaterThanOrEqualToConstant: 62),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(
    row: SettingsNativeRow,
    theme: SettingsNativeTheme,
    onPress: (() -> Void)?,
    onToggle: ((Bool) -> Void)?
  ) {
    rowView.configure(row: row, theme: theme, onPress: onPress, onToggle: onToggle)
  }
}

struct SettingsNativeRowControl: UIViewRepresentable {
  let row: SettingsNativeRow
  let palette: AppThemePalette
  let isDark: Bool
  let onPress: (() -> Void)?
  let onToggle: ((Bool) -> Void)?

  func makeUIView(context: Context) -> SettingsNativeRowContainerView {
    SettingsNativeRowContainerView()
  }

  func updateUIView(_ uiView: SettingsNativeRowContainerView, context: Context) {
    uiView.configure(
      row: row,
      theme: SettingsNativeTheme(palette: palette, isDark: isDark),
      onPress: onPress,
      onToggle: onToggle
    )
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    uiView: SettingsNativeRowContainerView,
    context: Context
  ) -> CGSize? {
    CGSize(width: proposal.width ?? UIView.noIntrinsicMetric, height: 58)
  }
}

struct SettingsNativeSectionCard: View {
  let section: SettingsNativeSection
  let palette: AppThemePalette
  let isDark: Bool
  let onPress: (String) -> Void
  let onToggle: (String, Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let title = section.title, !title.isEmpty {
        Text(title)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(palette.secondaryText.opacity(0.72))
          .padding(.horizontal, 16)
      }

      VStack(spacing: 0) {
        ForEach(section.rows) { row in
          SettingsNativeRowControl(
            row: row,
            palette: palette,
            isDark: isDark,
            onPress: {
              onPress(row.id)
            },
            onToggle: { value in
              onToggle(row.id, value)
            }
          )
          .frame(maxWidth: .infinity, minHeight: 58)
        }
      }
      .background(
        RoundedRectangle(cornerRadius: 26, style: .continuous)
          .fill(palette.card)
      )
      .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
  }
}

@MainActor
private final class SettingsAvatarModel: ObservableObject {
  @Published var fallbackText: String = "U"
  @Published var displayName: String = ""
  @Published var subtitle: String = ""
  /// Collapsed (outside) name colors — morph toward white on hero.
  @Published var nameColor: Color = .primary
  @Published var subtitleColor: Color = .secondary
  @Published var loadedImage: UIImage?
  @Published var expandedSize: CGFloat = 120.0
  @Published var collapsedSize: CGFloat = 36.0
  @Published var expandedTopInset: CGFloat = 90.0
  @Published var collapsedTopInset: CGFloat = 0.0
  /// Signed scroll offset (negative = pull-down overscroll for hero expand).
  @Published var scrollOffset: CGFloat = 0.0
  /// 0 = circle, 1 = full hero banner (profile-style).
  @Published var heroExpandProgress: CGFloat = 0.0
  /// Extra band height while pulling past fully-expanded hero.
  @Published var overscrollStretch: CGFloat = 0.0
  /// 0…1 — how far the COLLAPSED circle avatar has scrolled toward exiting the top
  /// of the screen. Drives a blur+fade+scale-down on the avatar as it scrolls away,
  /// instead of just clipping off abruptly with no transition.
  @Published var scrollCollapseFade: CGFloat = 0.0
  /// Rubber-band overscroll consumed at expand commit — pushes the media down by the
  /// same amount the offset snapped up, then decays to 0 through the morph (seamless commit).
  @Published var extraTopAir: CGFloat = 0.0
  @Published var bandWidth: CGFloat = UIScreen.main.bounds.width
  @Published var heroBaseHeight: CGFloat = UIScreen.main.bounds.height * 0.45
  @Published var islandCoverColor: UIColor = UIColor(red: 0.071, green: 0.071, blue: 0.075, alpha: 1.0)
  @Published var fallbackBackgroundColor: UIColor = UIColor(
    red: 222 / 255,
    green: 230 / 255,
    blue: 243 / 255,
    alpha: 1.0
  )
  @Published var fallbackGradientEndColor: UIColor = UIColor(
    red: 139 / 255,
    green: 65 / 255,
    blue: 27 / 255,
    alpha: 1.0
  )
  @Published var fallbackIconTintColor: UIColor = UIColor.darkText

  private var imageURI: String?
  private var imageTask: Task<Void, Never>?

  deinit {
    imageTask?.cancel()
  }

  func applyLocalImage(_ image: UIImage) {
    imageTask?.cancel()
    loadedImage = image
  }

  func setImageURI(_ value: String?, force: Bool = false) {
    let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    if !force, normalized == imageURI, loadedImage != nil { return }

    imageURI = normalized
    imageTask?.cancel()

    guard let normalized, !normalized.isEmpty else {
      return
    }

    // Prefer shared store (seeded on upload) so Settings paints immediately.
    if let cached = ChatAvatarImageStore.cached(for: normalized) {
      loadedImage = cached
      return
    }

    imageTask = Task { [weak self] in
      // Hero-quality load (list path stays at 384; settings needs full-width sharpness).
      var image = await ChatAvatarImageStore.loadHero(from: normalized)
      if image == nil {
        image = await SettingsAvatarImageLoader.load(from: normalized)
      }
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self, self.imageURI == normalized else { return }
        if let image {
          ChatAvatarImageStore.cacheHero(image, for: normalized)
        }
        self.loadedImage = image
      }
    }
  }
}

private enum SettingsAvatarHeroMetrics {
  /// Rest pin: topAir 90 + circle 120 + 8 = 218.
  /// Pull-down → hero expand; scroll-up → scale/fade collapse.
  static let topAir: CGFloat = 90
  static let expandedSize: CGFloat = 120
  static let collapsedSize: CGFloat = 36
  static let bottomSpacing: CGFloat = 8
  /// Pull-down distance (rubber-banded pts) over which the live expand scrub reaches
  /// p=1. Kept short — iOS rubber-band resistance rarely yields 80pt of raw offset.
  static let expandPullTravel: CGFloat = 52
  /// Releasing a pull past this fraction finishes expand. ~0.3 ≈ one natural tug.
  static let expandCommitFraction: CGFloat = 0.30

  static func expandedTop(for safeTop: CGFloat) -> CGFloat {
    _ = safeTop
    return topAir
  }

  /// Name sticky stop + collapse fade travel end.
  static func stickyTop(for safeTop: CGFloat) -> CGFloat {
    max(36, safeTop - 10)
  }

  static func hostHeight(for safeTop: CGFloat) -> CGFloat {
    expandedTop(for: safeTop) + expandedSize + bottomSpacing
  }

  static func heroBaseHeight() -> CGFloat {
    UIScreen.main.bounds.height * 0.45
  }

  /// Scroll distance for avatar scale/fade + name pin travel.
  static func blendTravel(for safeTop: CGFloat) -> CGFloat {
    let naturalY = hostHeight(for: safeTop) + 4
    return max(80, naturalY - stickyTop(for: safeTop))
  }

  struct BandLayout {
    let mediaTop: CGFloat
    let mediaH: CGFloat
    let nameReserve: CGFloat
    var bandHeight: CGFloat { mediaTop + mediaH + nameReserve }
  }

  /// SINGLE source for band geometry — SwiftUI morph view and the UIKit height
  /// constraint both read this; any drift between the two = mid-flight clip or row jump.
  /// Top edge morphs topAir → 0 while height grows to FULL hero, so p=1 is a
  /// full-bleed image from the screen top (no gap under the header). Settled band
  /// heights (p=0, p=1) are unchanged by the top morph, so rows never shift.
  static func bandLayout(
    progress: CGFloat,
    topAir: CGFloat,
    circle: CGFloat,
    hero: CGFloat,
    nameBlock: CGFloat
  ) -> BandLayout {
    let p = max(0, min(1, progress))
    return BandLayout(
      mediaTop: topAir * (1 - p),
      mediaH: circle + (max(circle, hero) - circle) * p,
      nameReserve: nameBlock * (1 - p)
    )
  }
}

enum SettingsAvatarImageLoader {
  static func load(from rawValue: String?) async -> UIImage? {
    guard let rawValue else { return nil }
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    let startedAt = CFAbsoluteTimeGetCurrent()

    if value.hasPrefix("data:"), let commaIndex = value.firstIndex(of: ",") {
      let base64 = String(value[value.index(after: commaIndex)...])
      return await decodeBase64Image(base64, source: "data-uri", startedAt: startedAt)
    }

    if value.hasPrefix("/") {
      return await decodeImageFile(URL(fileURLWithPath: value), source: "file-path", startedAt: startedAt)
    }

    if let url = URL(string: value), let scheme = url.scheme?.lowercased() {
      if url.isFileURL {
        return await decodeImageFile(url, source: "file-url", startedAt: startedAt)
      }

      guard scheme == "http" || scheme == "https" else {
        return nil
      }

      do {
        let (data, _) = try await VibeHTTP.shared.data(from: url)
        settingsNativeUITrace("SettingsAvatarImageLoader fetched source=remote bytes=\(data.count)")
        return await decodeImageData(data, source: "remote", startedAt: startedAt)
      } catch {
        settingsNativeUITrace("SettingsAvatarImageLoader fetch error source=remote error=\(error.localizedDescription)")
        return nil
      }
    }

    return await decodeBase64Image(value, source: "base64", startedAt: startedAt)
  }

  private static func decodeImageData(
    _ data: Data,
    source: String,
    startedAt: CFAbsoluteTime,
    maxPixelSize: CGFloat = 1280
  ) async -> UIImage? {
    await Task.detached(priority: .utility) {
      let image = downsampleImage(data: data, maxPixelSize: maxPixelSize)
      let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
      settingsNativeUITrace(
        "SettingsAvatarImageLoader decode source=\(source) bytes=\(data.count) success=\(image != nil) durationMs=\(durationMs)"
      )
      return image
    }.value
  }

  private static func decodeBase64Image(
    _ value: String,
    source: String,
    startedAt: CFAbsoluteTime,
    maxPixelSize: CGFloat = 1280
  ) async -> UIImage? {
    await Task.detached(priority: .utility) {
      guard let data = Data(base64Encoded: value, options: [.ignoreUnknownCharacters]) else {
        settingsNativeUITrace("SettingsAvatarImageLoader decode source=\(source) invalidBase64=Y")
        return nil
      }
      let image = downsampleImage(data: data, maxPixelSize: maxPixelSize)
      let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
      settingsNativeUITrace(
        "SettingsAvatarImageLoader decode source=\(source) bytes=\(data.count) success=\(image != nil) durationMs=\(durationMs)"
      )
      return image
    }.value
  }

  private static func decodeImageFile(
    _ url: URL,
    source: String,
    startedAt: CFAbsoluteTime,
    maxPixelSize: CGFloat = 1280
  ) async -> UIImage? {
    await Task.detached(priority: .utility) {
      let image = downsampleImage(url: url, maxPixelSize: maxPixelSize)
      let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
      settingsNativeUITrace(
        "SettingsAvatarImageLoader decode source=\(source) success=\(image != nil) durationMs=\(durationMs)"
      )
      return image
    }.value
  }

  private static func downsampleImage(data: Data, maxPixelSize: CGFloat) -> UIImage? {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
      return UIImage(data: data)
    }
    return downsampleImage(source: source, maxPixelSize: maxPixelSize) ?? UIImage(data: data)
  }

  private static func downsampleImage(url: URL, maxPixelSize: CGFloat) -> UIImage? {
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, options) else {
      return UIImage(contentsOfFile: url.path)
    }
    return downsampleImage(source: source, maxPixelSize: maxPixelSize)
      ?? UIImage(contentsOfFile: url.path)
  }

  private static func downsampleImage(source: CGImageSource, maxPixelSize: CGFloat) -> UIImage? {
    let options = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: Int(maxPixelSize),
    ] as CFDictionary
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
      return nil
    }
    // Use device scale so decoded pts match screen density (scale:1 looked soft).
    let scale = UIScreen.main.scale
    return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
  }
}

struct SettingsAvatarHeroView: View {
  let imageURI: String?
  let fallbackText: String
  let scrollOffset: CGFloat
  let palette: AppThemePalette

  static var hostHeight: CGFloat {
    SettingsAvatarHeroMetrics.hostHeight(for: 0)
  }

  @StateObject private var model = SettingsAvatarModel()

  var body: some View {
    GeometryReader { proxy in
      let safeTop = proxy.safeAreaInsets.top
      // Moves + scales + fades with scroll (not a fixed pin).
      SettingsAvatarScrollMorphView(model: model)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
          applyModelMetrics(safeTop: safeTop)
        }
        .onChange(of: safeTop) { _, newValue in
          applyModelMetrics(safeTop: newValue)
        }
    }
    .frame(height: Self.hostHeight)
    .frame(maxWidth: .infinity, alignment: .top)
    .onAppear {
      model.setImageURI(imageURI, force: true)
      model.fallbackText = fallbackText
      model.scrollOffset = scrollOffset
      applyPalette()
    }
    .onChange(of: imageURI) { _, newValue in
      model.setImageURI(newValue, force: true)
    }
    .onChange(of: fallbackText) { _, newValue in
      model.fallbackText = newValue
    }
    .onChange(of: scrollOffset) { _, newValue in
      model.scrollOffset = max(0, newValue)
    }
    .onChange(of: palette.backgroundUIColor.description) { _, _ in
      applyPalette()
    }
  }

  private func applyModelMetrics(safeTop: CGFloat) {
    model.expandedSize = SettingsAvatarHeroMetrics.expandedSize
    model.collapsedSize = SettingsAvatarHeroMetrics.collapsedSize
    model.expandedTopInset = SettingsAvatarHeroMetrics.expandedTop(for: safeTop)
    model.collapsedTopInset = SettingsAvatarHeroMetrics.stickyTop(for: safeTop)
  }

  private func applyPalette() {
    model.islandCoverColor = palette.backgroundUIColor
    model.fallbackBackgroundColor = palette.cardUIColor
    model.fallbackIconTintColor = palette.textUIColor
  }
}

private struct SettingsAvatarInnerContent: View {
  let image: UIImage?
  let fallbackText: String
  let fallbackIconTintColor: UIColor
  let fallbackBackgroundColor: UIColor
  var fallbackGradientEndColor: UIColor = UIColor(
    red: 139 / 255, green: 65 / 255, blue: 27 / 255, alpha: 1.0)
  let size: CGFloat

  private var fallbackGlyph: String {
    let seed = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
    return seed.isEmpty ? "?" : String(seed.prefix(1)).uppercased()
  }

  var body: some View {
    ZStack {
      Circle()
        .fill(
          LinearGradient(
            colors: [
              Color(uiColor: fallbackBackgroundColor),
              Color(uiColor: fallbackGradientEndColor),
            ],
            startPoint: .top,
            endPoint: .bottom
          )
        )

      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: size, height: size)
          .clipShape(Circle())
      } else {
        Text(fallbackGlyph)
          .font(.system(size: max(12, size * 0.36), weight: .bold))
          .foregroundStyle(.white)
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
  }
}

private struct SettingsHeroClipModifier: ViewModifier {
  let clip: Bool
  func body(content: Content) -> some View {
    if clip {
      content.clipped()
    } else {
      content
    }
  }
}

/// ONE continuous media morph (circle → hero). Driven by `model.heroExpandProgress`
/// under a single spring — not a separate overlay layer.
private struct SettingsAvatarScrollMorphView: View {
  @ObservedObject var model: SettingsAvatarModel

  private static func pixelRound(_ value: CGFloat) -> CGFloat {
    let scale = UIScreen.main.scale
    return (value * scale).rounded() / scale
  }

  /// Shared expand 0…1 — same value UIKit height constraint uses.
  private var expandP: CGFloat {
    max(0, min(1, model.heroExpandProgress))
  }

  private var circleSize: CGFloat { model.expandedSize }
  private var bottomPad: CGFloat { 8 }
  private var nameOutsideHeight: CGFloat { 48 }
  private var blurBandHeight: CGFloat { 50 }

  private var stretch: CGFloat {
    max(0, model.overscrollStretch)
  }

  private var resolvedBandWidth: CGFloat {
    max(model.bandWidth, UIScreen.main.bounds.width)
  }

  private var resolvedHeroHeight: CGFloat {
    max(model.heroBaseHeight, UIScreen.main.bounds.height * 0.4)
  }

  /// Shared geometry with the UIKit band constraint (same formula, same inputs).
  private var bandLayout: SettingsAvatarHeroMetrics.BandLayout {
    SettingsAvatarHeroMetrics.bandLayout(
      progress: expandP,
      topAir: model.expandedTopInset,
      circle: circleSize,
      hero: resolvedHeroHeight,
      nameBlock: bottomPad + nameOutsideHeight
    )
  }

  private var extraTopAir: CGFloat {
    max(0, model.extraTopAir)
  }

  /// Morphs topAir → 0 with p: hero fills to the very top of the screen at p=1.
  /// extraTopAir = consumed rubber-band offset (decays to 0 during the morph).
  private var mediaTop: CGFloat {
    bandLayout.mediaTop + extraTopAir
  }

  /// Full width at p=1 (edge-to-edge horizontally).
  private var mediaW: CGFloat {
    circleSize + (resolvedBandWidth - circleSize) * expandP
  }

  /// At p=1 = full hero height (screen top → hero bottom).
  private var mediaH: CGFloat {
    bandLayout.mediaH + stretch
  }

  private var mediaCorner: CGFloat {
    (circleSize * 0.5) * (1 - expandP) + 4 * expandP
  }

  /// Name under circle collapses onto media bottom as p→1.
  private var nameReserve: CGFloat {
    bandLayout.nameReserve
  }

  /// Matches UIKit band constraint by construction (shared bandLayout + same extras).
  private var hostBandHeight: CGFloat {
    bandLayout.bandHeight + extraTopAir + stretch
  }

  /// Name: under circle → on hero bottom (no vertical fly of the photo).
  private var nameTop: CGFloat {
    let y0 = mediaTop + mediaH + bottomPad
    let y1 = max(0, mediaTop + mediaH - nameOutsideHeight - 10)
    return y0 + (y1 - y0) * expandP
  }

  var body: some View {
    let ep = expandP
    let shape = RoundedRectangle(cornerRadius: mediaCorner, style: .continuous)
    let heroImageScale = stretch > 0 ? 1 + min(0.18, stretch / max(1, resolvedHeroHeight)) : 1
    let band = resolvedBandWidth
    let _ = heroMorphSUITrace(ep: ep)
    // Only relevant to the collapsed circle (gated by 1-ep) — fade+scale-down as the
    // avatar scrolls toward exiting the top, instead of clipping off raw. No blur:
    // the only blur anywhere is the bottom-edge material band behind the name.
    let scrollFade = model.scrollCollapseFade * (1 - ep)

    return ZStack(alignment: .topLeading) {
      mediaBody(imageScale: heroImageScale)
        .frame(width: mediaW, height: mediaH)
        .clipShape(shape)
        .scaleEffect(1 - 0.08 * scrollFade, anchor: .top)
        .opacity(Double(1 - 0.5 * scrollFade))
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, mediaTop)

      // Centered under the circle when collapsed; slides LEFT as the hero forms —
      // each line's x is a continuous lerp of the SAME p (centered → 20pt inset).
      nameChrome(expand: ep, clusterWidth: max(1, band - 32))
        .frame(
          width: max(1, band - 32),
          height: nameOutsideHeight,
          alignment: .leading
        )
        .padding(.top, nameTop)
        .padding(.leading, 16)
    }
    .frame(width: band, height: hostBandHeight, alignment: .top)
    // Mid-expand scrub keeps the UIKit band height collapsed (avoids rubber-band
    // fight); allow overflow so the morph can still draw. Clip only at rest.
    .modifier(SettingsHeroClipModifier(clip: ep < 0.001 || ep > 0.999))
  }

  /// Mid-flight only — pairs with UIKit [HeroMorph] ticks to expose render lag/drift.
  private func heroMorphSUITrace(ep: CGFloat) {
    guard ep > 0.0005, ep < 0.9995 else { return }
    NSLog(
      "[HeroMorphSUI] p=%.3f mediaTop=%.1f mediaH=%.1f host=%.1f stretch=%.1f extraTop=%.1f",
      Double(ep), Double(mediaTop), Double(mediaH), Double(hostBandHeight), Double(stretch),
      Double(extraTopAir)
    )
  }

  /// Single-line width for the center→leading slide (system font, no attributes drift).
  private static func lineWidth(_ text: String, size: CGFloat, weight: UIFont.Weight) -> CGFloat {
    (text as NSString).size(
      withAttributes: [.font: UIFont.systemFont(ofSize: size, weight: weight)]
    ).width
  }

  @ViewBuilder
  private func nameChrome(expand ep: CGFloat, clusterWidth: CGFloat) -> some View {
    let title = model.displayName.isEmpty ? model.fallbackText : model.displayName
    let titleColor = Color.lerp(model.nameColor, Color.white.opacity(0.92), t: ep)
    let subColor = Color.lerp(model.subtitleColor, Color.white.opacity(0.78), t: ep)

    // Each line slides from its CENTERED x to a 20pt screen inset as p rises —
    // one shared value, no alignment flip, no jump. Cluster origin sits at 16,
    // so the in-cluster hero target is 4.
    let heroInset: CGFloat = 4
    let titleW = min(clusterWidth, Self.lineWidth(title, size: 24, weight: .semibold))
    let titleCenteredX = max(0, (clusterWidth - titleW) * 0.5)
    let subW = min(clusterWidth, Self.lineWidth(model.subtitle, size: 13, weight: .regular))
    let subCenteredX = max(0, (clusterWidth - subW) * 0.5)

    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        // Slightly smaller + semibold (was 28 bold).
        .font(.system(size: 24, weight: .semibold))
        .foregroundStyle(titleColor)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .shadow(color: .black.opacity(0.35 * ep), radius: 6 * ep, y: 1)
        // Leading anchor: the scale must not drift the left edge off its lerped x.
        .scaleEffect(1 - 0.06 * ep, anchor: .leading)
        .offset(x: titleCenteredX + (heroInset - titleCenteredX) * ep)
      if !model.subtitle.isEmpty {
        Text(model.subtitle)
          .font(.system(size: 13, weight: .regular))
          .foregroundStyle(subColor)
          .lineLimit(1)
          .shadow(color: .black.opacity(0.30 * ep), radius: 4 * ep, y: 1)
          .offset(x: subCenteredX + (heroInset - subCenteredX) * ep)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func mediaBody(imageScale: CGFloat) -> some View {
    let ep = expandP
    // Single image layer only — dual blur was re-rasterizing every tick (frame flicker).
    let blurStart = max(0, 1 - blurBandHeight / max(1, mediaH))

    ZStack {
      if model.loadedImage == nil {
        LinearGradient(
          colors: [
            Color(uiColor: model.fallbackBackgroundColor),
            Color(uiColor: model.fallbackGradientEndColor),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
      }
      if let image = model.loadedImage {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .scaleEffect(imageScale, anchor: .top)
      } else {
        let glyph = {
          let seed = model.fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
          return seed.isEmpty ? "?" : String(seed.prefix(1)).uppercased()
        }()
        Text(glyph)
          .font(.system(size: 26 + 20 * ep, weight: .semibold))
          .foregroundStyle(.white.opacity(0.92))
          .minimumScaleFactor(0.4)
      }

      // Frosted-glass falloff at the bottom edge for name legibility — adapts to
      // the image via native Material translucency instead of a flat black
      // scrim imposing a fixed shadow/theme color.
      Rectangle()
        .fill(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
        .mask(
          LinearGradient(
            stops: [
              .init(color: .clear, location: 0.0),
              .init(color: .clear, location: blurStart),
              .init(color: .black.opacity(0.85), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
          )
        )
        .opacity(Double(0.3 + 0.5 * ep))
        .allowsHitTesting(false)
    }
    .frame(width: mediaW, height: mediaH)
    // No image blur anywhere: the soft bottom-edge material band under the
    // username is the ONLY blur, and it lives inside the image for text legibility.
    .clipped()
  }
}

private extension Color {
  /// Linear RGB lerp for smooth theme→white name morph.
  static func lerp(_ a: Color, _ b: Color, t: CGFloat) -> Color {
    let u = max(0, min(1, t))
    let ua = UIColor(a)
    let ub = UIColor(b)
    var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
    var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
    ua.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    ub.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
    return Color(
      red: r1 + (r2 - r1) * u,
      green: g1 + (g2 - g1) * u,
      blue: b1 + (b2 - b1) * u,
      opacity: a1 + (a2 - a1) * u
    )
  }
}

private struct SettingsNativeAvatarContentView: View {
  @ObservedObject var model: SettingsAvatarModel

  var body: some View {
    SettingsAvatarScrollMorphView(model: model)
  }
}

final class SettingsNativeAvatarView: UIView {
  private let model = SettingsAvatarModel()
  /// SwiftUI host only — discrete expand 0↔1 via spring (no live UIKit track morph).
  private let hostingController: UIHostingController<SettingsNativeAvatarContentView>
  private var isHostingControllerAttached = false
  private var currentImageURI: String?
  private var currentFallbackText: String = "U"
  private var currentExpandedSize: CGFloat = 120.0
  private var currentCollapsedSize: CGFloat = 36.0
  private var currentExpandedTopInset: CGFloat = 90.0
  private var currentCollapsedTopInset: CGFloat = 0.0
  private var currentScrollOffset: CGFloat = 0.0
  private var currentHeroExpandProgress: CGFloat = 0.0
  private var currentOverscrollStretch: CGFloat = 0.0
  private var currentExtraTopAir: CGFloat = 0.0
  private var currentScrollCollapseFade: CGFloat = 0.0
  var currentExpandProgress: CGFloat { currentHeroExpandProgress }
  private var currentIslandCoverColor: UIColor = UIColor(red: 0.071, green: 0.071, blue: 0.075, alpha: 1.0)
  private var currentFallbackBackgroundColor: UIColor = UIColor(
    red: 222 / 255,
    green: 230 / 255,
    blue: 243 / 255,
    alpha: 1.0
  )
  private var currentFallbackIconTintColor: UIColor = UIColor.darkText

  override init(frame: CGRect) {
    model.bandWidth = UIScreen.main.bounds.width
    model.heroBaseHeight = UIScreen.main.bounds.height * 0.45
    hostingController = UIHostingController(
      rootView: SettingsNativeAvatarContentView(model: model)
    )
    super.init(frame: frame)

    backgroundColor = .clear
    clipsToBounds = true

    if #available(iOS 16.4, *) {
      hostingController.safeAreaRegions = []
    }

    let hostedView = hostingController.view!
    hostedView.translatesAutoresizingMaskIntoConstraints = false
    hostedView.backgroundColor = .clear
    hostedView.clipsToBounds = false
    addSubview(hostedView)

    NSLayoutConstraint.activate([
      hostedView.leadingAnchor.constraint(equalTo: leadingAnchor),
      hostedView.trailingAnchor.constraint(equalTo: trailingAnchor),
      hostedView.topAnchor.constraint(equalTo: topAnchor),
      hostedView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil, !isHostingControllerAttached {
      if let parentVC = findNearestViewController() {
        parentVC.addChild(hostingController)
        hostingController.didMove(toParent: parentVC)
        isHostingControllerAttached = true
      }
    } else if window == nil, isHostingControllerAttached {
      hostingController.willMove(toParent: nil)
      hostingController.removeFromParent()
      isHostingControllerAttached = false
    }
  }

  private func findNearestViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let next = responder?.next {
      if let vc = next as? UIViewController {
        return vc
      }
      responder = next
    }
    return nil
  }

  func setImageURI(_ value: String?, force: Bool = false) {
    let nextValue = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    if !force, currentImageURI == nextValue { return }
    currentImageURI = nextValue
    publishModelChange { $0.setImageURI(nextValue, force: force) }
  }

  func setFallbackText(_ value: String?) {
    let nextValue =
      (value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        ? value
        : "U") ?? "U"
    guard currentFallbackText != nextValue else { return }
    currentFallbackText = nextValue
    publishModelChange { $0.fallbackText = nextValue }
  }

  func setDisplayName(_ value: String?) {
    let next = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    publishModelChange { $0.displayName = next }
  }

  func setSubtitle(_ value: String?) {
    let next = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    publishModelChange { $0.subtitle = next }
  }

  func setNameColors(primary: Color, secondary: Color) {
    publishModelChange {
      $0.nameColor = primary
      $0.subtitleColor = secondary
    }
  }

  func setExpandedSize(_ value: CGFloat) {
    let resolved = max(1.0, value)
    guard currentExpandedSize != resolved else { return }
    currentExpandedSize = resolved
    publishModelChange { $0.expandedSize = resolved }
  }

  func setCollapsedSize(_ value: CGFloat) {
    let resolved = max(1.0, value)
    guard currentCollapsedSize != resolved else { return }
    currentCollapsedSize = resolved
    publishModelChange { $0.collapsedSize = resolved }
  }

  func setExpandedTopInset(_ value: CGFloat) {
    let resolved = max(0.0, value)
    guard currentExpandedTopInset != resolved else { return }
    currentExpandedTopInset = resolved
    publishModelChange { $0.expandedTopInset = resolved }
  }

  func setCollapsedTopInset(_ value: CGFloat) {
    let resolved = max(0.0, value)
    guard currentCollapsedTopInset != resolved else { return }
    currentCollapsedTopInset = resolved
    publishModelChange { $0.collapsedTopInset = resolved }
  }

  /// Signed offset — negative pull-down drives hero expand.
  /// Applied **synchronously** on main (async was dropping scroll frames).
  func setScrollOffset(_ value: CGFloat) {
    guard abs(currentScrollOffset - value) >= 0.25 else { return }
    currentScrollOffset = value
    model.scrollOffset = value
  }

  func setHeroExpandProgress(_ value: CGFloat, animated: Bool) {
    let resolved = max(0, min(1, value))
    if abs(currentHeroExpandProgress - resolved) < 0.0005 { return }
    currentHeroExpandProgress = resolved
    if animated {
      withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
        model.heroExpandProgress = resolved
      }
    } else {
      var t = Transaction()
      t.disablesAnimations = true
      withTransaction(t) {
        model.heroExpandProgress = resolved
      }
    }
  }

  func setOverscrollStretch(_ value: CGFloat) {
    let resolved = max(0, value)
    // Tight threshold: the UIKit band constraint gets this value exactly, so a loose
    // guard here left the SwiftUI media edge sub-pixel off the band edge (shimmer).
    guard abs(currentOverscrollStretch - resolved) >= 0.05 else { return }
    currentOverscrollStretch = resolved
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      model.overscrollStretch = resolved
    }
  }

  func setExtraTopAir(_ value: CGFloat) {
    let resolved = max(0, value)
    guard abs(currentExtraTopAir - resolved) >= 0.05 else { return }
    currentExtraTopAir = resolved
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      model.extraTopAir = resolved
    }
  }

  func setScrollCollapseFade(_ value: CGFloat) {
    let resolved = max(0, min(1, value))
    guard abs(currentScrollCollapseFade - resolved) >= 0.01 else { return }
    currentScrollCollapseFade = resolved
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      model.scrollCollapseFade = resolved
    }
  }

  func setBandMetrics(width: CGFloat, heroBaseHeight: CGFloat) {
    let w = max(width, UIScreen.main.bounds.width)
    let h = max(heroBaseHeight, UIScreen.main.bounds.height * 0.4)
    if abs(model.bandWidth - w) < 0.5, abs(model.heroBaseHeight - h) < 0.5 { return }
    model.objectWillChange.send()
    model.bandWidth = w
    model.heroBaseHeight = h
  }

  func setIslandCoverColor(_ value: UIColor) {
    guard currentIslandCoverColor != value else { return }
    currentIslandCoverColor = value
    publishModelChange { $0.islandCoverColor = value }
  }

  func setFallbackBackgroundColor(_ value: UIColor) {
    guard currentFallbackBackgroundColor != value else { return }
    currentFallbackBackgroundColor = value
    publishModelChange { $0.fallbackBackgroundColor = value }
  }

  func setFallbackGradientEndColor(_ value: UIColor) {
    publishModelChange { $0.fallbackGradientEndColor = value }
  }

  func setFallbackIconTintColor(_ value: UIColor) {
    guard currentFallbackIconTintColor != value else { return }
    currentFallbackIconTintColor = value
    publishModelChange { $0.fallbackIconTintColor = value }
  }

  func applyLocalImage(_ image: UIImage) {
    publishModelChange { $0.applyLocalImage(image) }
  }

  /// High-frequency scroll path — must not hop through async.
  private func applyModelSync(_ update: @escaping (SettingsAvatarModel) -> Void) {
    if Thread.isMainThread {
      update(model)
    } else {
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        update(self.model)
      }
    }
  }

  private func publishModelChange(_ update: @escaping (SettingsAvatarModel) -> Void) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      update(self.model)
    }
  }
}

private final class SettingsNativeGlassButton: UIControl {
  private let effectView = UIVisualEffectView(effect: nil)
  private let titleLabelView = UILabel()
  private let iconView = UIImageView()
  private let overlayView = UIView()
  private var iconSizeConstraint: NSLayoutConstraint?
  private var heightConstraint: NSLayoutConstraint?
  private var widthConstraint: NSLayoutConstraint?

  var iconTintColor: UIColor = .white {
    didSet {
      iconView.tintColor = iconTintColor
      titleLabelView.textColor = iconTintColor
    }
  }

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: 0.16) {
        self.overlayView.alpha = self.isHighlighted ? 1.0 : 0.0
        self.transform =
          self.isHighlighted
          ? CGAffineTransform(scaleX: 0.96, y: 0.96)
          : .identity
      }
    }
  }

  override var intrinsicContentSize: CGSize {
    let height = heightConstraint?.constant ?? 44
    if let widthConstraint, widthConstraint.isActive {
      return CGSize(width: widthConstraint.constant, height: height)
    }

    if let text = titleLabelView.text, !text.isEmpty {
      let textWidth = ceil(
        (text as NSString).size(withAttributes: [.font: titleLabelView.font as Any]).width)
      return CGSize(width: max(56, textWidth + 28), height: height)
    }

    if iconView.image != nil {
      return CGSize(width: height, height: height)
    }

    return CGSize(width: height, height: height)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)

    translatesAutoresizingMaskIntoConstraints = false
    clipsToBounds = false

    effectView.translatesAutoresizingMaskIntoConstraints = false
    effectView.clipsToBounds = true
    if #available(iOS 13.0, *) {
      effectView.layer.cornerCurve = .continuous
    }
    addSubview(effectView)

    overlayView.translatesAutoresizingMaskIntoConstraints = false
    overlayView.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
    overlayView.alpha = 0
    effectView.contentView.addSubview(overlayView)

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.contentMode = .scaleAspectFit
    iconView.tintColor = iconTintColor
    effectView.contentView.addSubview(iconView)

    titleLabelView.translatesAutoresizingMaskIntoConstraints = false
    titleLabelView.font = .systemFont(ofSize: 13, weight: .semibold)
    titleLabelView.textAlignment = .center
    titleLabelView.textColor = iconTintColor
    effectView.contentView.addSubview(titleLabelView)

    NSLayoutConstraint.activate([
      effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
      effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
      effectView.topAnchor.constraint(equalTo: topAnchor),
      effectView.bottomAnchor.constraint(equalTo: bottomAnchor),

      overlayView.leadingAnchor.constraint(equalTo: effectView.contentView.leadingAnchor),
      overlayView.trailingAnchor.constraint(equalTo: effectView.contentView.trailingAnchor),
      overlayView.topAnchor.constraint(equalTo: effectView.contentView.topAnchor),
      overlayView.bottomAnchor.constraint(equalTo: effectView.contentView.bottomAnchor),

      iconView.centerXAnchor.constraint(equalTo: effectView.contentView.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: effectView.contentView.centerYAnchor),

      titleLabelView.leadingAnchor.constraint(
        equalTo: effectView.contentView.leadingAnchor,
        constant: 14
      ),
      titleLabelView.trailingAnchor.constraint(
        equalTo: effectView.contentView.trailingAnchor,
        constant: -14
      ),
      titleLabelView.centerYAnchor.constraint(equalTo: effectView.contentView.centerYAnchor),
    ])

    iconSizeConstraint = iconView.widthAnchor.constraint(equalToConstant: 20)
    iconSizeConstraint?.isActive = true
    iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor).isActive = true

    heightConstraint = heightAnchor.constraint(equalToConstant: 44)
    heightConstraint?.isActive = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setGlassTheme(isDark: Bool) {
    if #available(iOS 26.0, *) {
      effectView.effect = UIGlassEffect()
      effectView.contentView.backgroundColor = .clear
    } else {
      effectView.effect = UIBlurEffect(
        style: isDark ? .systemThinMaterialDark : .systemThinMaterialLight
      )
      effectView.contentView.backgroundColor =
        (isDark ? UIColor.black : UIColor.white).withAlphaComponent(isDark ? 0.12 : 0.06)
    }
    effectView.layer.cornerRadius = (heightConstraint?.constant ?? 44) * 0.5
  }

  func setIcon(systemName: String?, pointSize: CGFloat = 20) {
    guard let systemName, !systemName.isEmpty else {
      iconView.image = nil
      iconView.isHidden = true
      invalidateIntrinsicContentSize()
      return
    }
    let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    iconView.image = UIImage(systemName: systemName, withConfiguration: configuration)
    iconView.isHidden = false
    iconSizeConstraint?.constant = pointSize
    invalidateIntrinsicContentSize()
  }

  func setTitle(_ title: String?) {
    titleLabelView.text = title
    titleLabelView.isHidden = title?.isEmpty ?? true
    invalidateIntrinsicContentSize()
  }

  func setButtonSize(width: CGFloat?, height: CGFloat = 44) {
    heightConstraint?.constant = height
    if let width {
      if widthConstraint == nil {
        widthConstraint = widthAnchor.constraint(equalToConstant: width)
        widthConstraint?.isActive = true
      } else {
        widthConstraint?.constant = width
      }
    } else {
      widthConstraint?.isActive = false
      widthConstraint = nil
    }
    effectView.layer.cornerRadius = height * 0.5
    invalidateIntrinsicContentSize()
  }
}

// MARK: - Settings identity (sticky name — no fade; avatar dissolves instead)

@MainActor
private final class SettingsIdentityBlendModel: ObservableObject {
  @Published var name: String = ""
  @Published var subtitle: String = ""
  /// 0 free under avatar → 1 fully pinned under status bar.
  @Published var pinProgress: CGFloat = 0
  @Published var textColor: Color = .primary
  @Published var secondaryColor: Color = .secondary
}

/// Sticky name cluster: tracks scroll then pins. No blur/fade (avatar owns dissolve).
private struct SettingsIdentityBlendView: View {
  @ObservedObject var model: SettingsIdentityBlendModel

  var body: some View {
    let p = max(0, min(1, model.pinProgress))
    VStack(spacing: 3) {
      Text(model.name)
        .font(.system(size: 28, weight: .bold))
        .foregroundStyle(model.textColor)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
      if !model.subtitle.isEmpty {
        Text(model.subtitle)
          .font(.system(size: 14, weight: .regular))
          .foregroundStyle(model.secondaryColor)
          .lineLimit(1)
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    // Profile-style name scale only (28 → ~19). Stays fully opaque.
    .scaleEffect(1 - 0.32 * p, anchor: .top)
    .animation(nil, value: p)
  }
}

final class SettingsNativeMainView: UIView, UIScrollViewDelegate, UIImagePickerControllerDelegate,
  UINavigationControllerDelegate
{
  var onRowPress: ((String) -> Void)?
  var onRowToggle: ((String, Bool) -> Void)?
  var onAvatarTap: (() -> Void)?
  var onSignOut: (() -> Void)?
  var avatarUserId: String = ""

  private let backgroundView = UIView()
  private let scrollView = UIScrollView()
  private let scrollContentView = UIView()
  private let rootStack = UIStackView()
  private let bodyStack = UIStackView()
  private let headerMaskContainer = UIView()
  private let headerMaskLayer = CAGradientLayer()
  /// IN-SCROLL first stack child — avatar+name+rows are one scroll unit (no overlay gap).
  private let avatarView = SettingsNativeAvatarView()
  private let footerLabel = UILabel()
  private let signOutButton = UIButton(type: .system)
  private let nameOutsideHeight: CGFloat = 48

  private var headerMaskHeightConstraint: NSLayoutConstraint?
  private var avatarBandHeightConstraint: NSLayoutConstraint?

  private var theme = SettingsNativeTheme(
    palette: AppThemePalette.resolve(for: .dark),
    isDark: true
  )
  private var sections: [SettingsNativeSection] = []
  private var currentPinHeight: CGFloat = 218
  private var currentSafeTop: CGFloat = 59
  private var heroExpanded = false
  private var heroExpandProgress: CGFloat = 0
  /// True while the EXPAND commit display link runs — didScroll must not fight it.
  /// (Collapse has no committed morph anymore: it's a live, offset-driven scrub.)
  private var isCommittingHero = false
  private var expandGestureArmed = true
  /// Single expand-commit driver: feeds the SAME progress to the UIKit band constraint
  /// and the SwiftUI media each frame (two parallel animators desync → clip pop).
  private var heroMorphDisplayLink: CADisplayLink?
  private var heroMorphStart: CFTimeInterval = 0
  private var heroMorphFrom: CGFloat = 0
  private var heroMorphTarget: CGFloat = 1
  /// Rubber-band offset consumed at expand commit; decays to 0 across the morph.
  private var heroMorphOverscroll: CGFloat = 0
  /// Coarse gate so expanded-stretch sampling logs don't spam at 120Hz.
  private var lastHeroSampleLogY: CGFloat = .greatestFiniteMagnitude
  /// KVO backup — guarantees we see every contentOffset change (Fable).
  private var contentOffsetObservation: NSKeyValueObservation?
  override init(frame: CGRect) {
    super.init(frame: frame)
    configureView()
    rebuildSections()
    updateMetrics()
  }

  deinit {
    contentOffsetObservation?.invalidate()
    heroMorphDisplayLink?.invalidate()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    updateMetrics()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    headerMaskLayer.frame = headerMaskContainer.bounds
    // Keep avatar band width metrics current for full-bleed hero.
    let w = bounds.width > 1 ? bounds.width : UIScreen.main.bounds.width
    avatarView.setBandMetrics(
      width: w,
      heroBaseHeight: SettingsAvatarHeroMetrics.heroBaseHeight()
    )
  }

  func configure(
    displayName: String,
    subtitle: String,
    avatarImageURI: String?,
    avatarFallbackText: String,
    avatarUserId: String,
    footerText: String,
    sections: [SettingsNativeSection],
    palette: AppThemePalette,
    isDark: Bool,
    onRowPress: ((String) -> Void)?,
    onRowToggle: ((String, Bool) -> Void)?,
    onAvatarTap: (() -> Void)?,
    onSignOut: (() -> Void)?
  ) {
    theme = SettingsNativeTheme(palette: palette, isDark: isDark)
    self.onRowPress = onRowPress
    self.onRowToggle = onRowToggle
    self.onAvatarTap = onAvatarTap
    self.onSignOut = onSignOut
    self.avatarUserId = avatarUserId

    let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedSubtitle = subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
    footerLabel.text = footerText.trimmingCharacters(in: .whitespacesAndNewlines)

    avatarView.setImageURI(avatarImageURI, force: true)
    avatarView.setFallbackText(avatarFallbackText)
    avatarView.setDisplayName(trimmedName)
    avatarView.setSubtitle(trimmedSubtitle)
    avatarView.setNameColors(primary: palette.text, secondary: palette.secondaryText)
    avatarView.setIslandCoverColor(palette.backgroundUIColor)
    let colors = ChatProfileAppearanceStore.avatarColors(
      title: displayName,
      peerUserId: avatarUserId.isEmpty ? nil : avatarUserId,
      chatId: nil
    )
    avatarView.setFallbackBackgroundColor(colors.0)
    avatarView.setFallbackGradientEndColor(colors.1)
    avatarView.setFallbackIconTintColor(.white)

    applyTheme()

    // rootStack: [headerContainer] + body children
    let needsRebuild = self.sections != sections || bodyStack.arrangedSubviews.isEmpty
    if needsRebuild {
      self.sections = sections
      rebuildSections()
    }
    // updateMetrics re-derives header from live contentOffset (no discrete wipe).
    updateMetrics()
  }

  private func configureView() {
    backgroundColor = .clear
    clipsToBounds = false

    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    backgroundView.isUserInteractionEnabled = false
    addSubview(backgroundView)

    // Scroll first (under overlay avatar).
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.backgroundColor = .clear
    scrollView.showsVerticalScrollIndicator = false
    scrollView.contentInsetAdjustmentBehavior = .never
    scrollView.alwaysBounceVertical = true
    scrollView.bounces = true
    scrollView.delegate = self
    scrollView.delaysContentTouches = false
    scrollView.canCancelContentTouches = true
    addSubview(scrollView)

    // KVO so pull scale never depends on delegate-only delivery (Fable).
    contentOffsetObservation = scrollView.observe(
      \.contentOffset,
      options: [.new]
    ) { [weak self] scroll, _ in
      self?.updateScrollAnimations(offsetY: scroll.contentOffset.y)
    }

    scrollContentView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(scrollContentView)

    rootStack.translatesAutoresizingMaskIntoConstraints = false
    rootStack.axis = .vertical
    rootStack.spacing = 12
    rootStack.alignment = .fill
    scrollContentView.addSubview(rootStack)

    // Avatar IN scroll stack — one unit with name + rows (no overlay disconnect).
    avatarView.translatesAutoresizingMaskIntoConstraints = false
    avatarView.clipsToBounds = true
    // false: pans pass through so pull/scroll always hit the scroll view.
    avatarView.isUserInteractionEnabled = false
    rootStack.addArrangedSubview(avatarView)

    let bodyWrap = UIView()
    bodyWrap.translatesAutoresizingMaskIntoConstraints = false
    bodyWrap.backgroundColor = .clear
    rootStack.addArrangedSubview(bodyWrap)
    // Z-safety: layout comes from arrangedSubviews order (unchanged); if any
    // transient frame overlap ever happens mid-morph, rows tuck UNDER the hero
    // edge instead of slicing across the image.
    rootStack.bringSubviewToFront(avatarView)

    bodyStack.translatesAutoresizingMaskIntoConstraints = false
    bodyStack.axis = .vertical
    bodyStack.spacing = 22
    bodyStack.alignment = .fill
    bodyWrap.addSubview(bodyStack)

    // Photo picker via host tap (circle/hero only) so scroll keeps the pan.
    let avatarTap = UITapGestureRecognizer(target: self, action: #selector(handleAvatarTap))
    avatarTap.cancelsTouchesInView = false
    addGestureRecognizer(avatarTap)

    headerMaskContainer.translatesAutoresizingMaskIntoConstraints = false
    headerMaskContainer.isUserInteractionEnabled = false
    addSubview(headerMaskContainer)

    headerMaskLayer.locations = [0.0, 0.7, 1.0]
    headerMaskLayer.startPoint = CGPoint(x: 0.5, y: 0)
    headerMaskLayer.endPoint = CGPoint(x: 0.5, y: 1)
    headerMaskContainer.layer.addSublayer(headerMaskLayer)

    footerLabel.translatesAutoresizingMaskIntoConstraints = false
    footerLabel.font = .systemFont(ofSize: 12, weight: .regular)
    footerLabel.textAlignment = .center

    signOutButton.translatesAutoresizingMaskIntoConstraints = false
    signOutButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
    signOutButton.layer.cornerRadius = 24
    if #available(iOS 13.0, *) {
      signOutButton.layer.cornerCurve = .continuous
    }
    signOutButton.addTarget(self, action: #selector(handleSignOutPress), for: .touchUpInside)

    NSLayoutConstraint.activate([
      backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
      backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
      backgroundView.topAnchor.constraint(equalTo: topAnchor),
      backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),

      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

      scrollContentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      scrollContentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      scrollContentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      scrollContentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      scrollContentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

      rootStack.leadingAnchor.constraint(equalTo: scrollContentView.leadingAnchor),
      rootStack.trailingAnchor.constraint(equalTo: scrollContentView.trailingAnchor),
      rootStack.topAnchor.constraint(equalTo: scrollContentView.topAnchor),
      rootStack.bottomAnchor.constraint(equalTo: scrollContentView.bottomAnchor, constant: -28),

      bodyStack.leadingAnchor.constraint(equalTo: bodyWrap.leadingAnchor, constant: 16),
      bodyStack.trailingAnchor.constraint(equalTo: bodyWrap.trailingAnchor, constant: -16),
      bodyStack.topAnchor.constraint(equalTo: bodyWrap.topAnchor),
      bodyStack.bottomAnchor.constraint(equalTo: bodyWrap.bottomAnchor),

      headerMaskContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
      headerMaskContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
      headerMaskContainer.topAnchor.constraint(equalTo: topAnchor),
    ])

    headerMaskHeightConstraint = headerMaskContainer.heightAnchor.constraint(equalToConstant: 104)
    headerMaskHeightConstraint?.isActive = true

    let initialH = avatarBandHeight(for: 0)
    avatarBandHeightConstraint = avatarView.heightAnchor.constraint(equalToConstant: initialH)
    avatarBandHeightConstraint?.isActive = true

    bringSubviewToFront(headerMaskContainer)

    applyTheme()
  }

  /// Settled layout (stretch while expanded). Morph drives this per-frame via display link.
  /// stretch/extraTop are pixel-quantized so the UIKit constraint and the SwiftUI media
  /// receive IDENTICAL values — sub-pixel disagreement reads as edge shimmer.
  private func applyHeaderLayout(p: CGFloat, stretch: CGFloat, extraTop: CGFloat = 0) {
    let clampedP = max(0, min(1, p))
    let scale = max(1, UIScreen.main.scale)
    let quantStretch = (max(0, stretch) * scale).rounded() / scale
    let quantExtraTop = (max(0, extraTop) * scale).rounded() / scale
    heroExpandProgress = clampedP
    let h = avatarBandHeight(for: clampedP) + quantStretch + quantExtraTop
    avatarBandHeightConstraint?.constant = (h * scale).rounded() / scale
    avatarView.setOverscrollStretch(quantStretch)
    avatarView.setExtraTopAir(quantExtraTop)
    avatarView.setHeroExpandProgress(clampedP, animated: false)
  }

  private func rebuildSections() {
    bodyStack.arrangedSubviews.forEach {
      bodyStack.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }

    for section in sections {
      bodyStack.addArrangedSubview(makeSectionView(section))
    }
    bodyStack.addArrangedSubview(makeSignOutView())
    bodyStack.addArrangedSubview(makeFooterView())
  }

  private func makeSectionView(_ section: SettingsNativeSection) -> UIView {
    let wrapper = UIStackView()
    wrapper.translatesAutoresizingMaskIntoConstraints = false
    wrapper.axis = .vertical
    wrapper.spacing = 8

    if let title = section.title, !title.isEmpty {
      let label = UILabel()
      label.translatesAutoresizingMaskIntoConstraints = false
      label.font = .systemFont(ofSize: 13, weight: .medium)
      label.textColor = theme.secondaryText
      label.text = title.uppercased()
      label.alpha = 0.78
      // Profile-style section header inset
      label.layoutMargins = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
      wrapper.addArrangedSubview(label)
    }

    // Material card like profile sections (not solid flat fill).
    let card = UIVisualEffectView(
      effect: UIBlurEffect(style: theme.isDark ? .systemUltraThinMaterialDark : .systemUltraThinMaterialLight)
    )
    card.translatesAutoresizingMaskIntoConstraints = false
    card.backgroundColor = theme.card.withAlphaComponent(theme.isDark ? 0.32 : 0.62)
    card.layer.cornerRadius = 28
    if #available(iOS 13.0, *) {
      card.layer.cornerCurve = .continuous
    }
    card.clipsToBounds = true
    card.layer.borderWidth = 1.0 / UIScreen.main.scale
    card.layer.borderColor =
      (theme.isDark ? UIColor.white : UIColor.black).withAlphaComponent(theme.isDark ? 0.08 : 0.05).cgColor
    wrapper.addArrangedSubview(card)

    let stack = UIStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 0
    card.contentView.addSubview(stack)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
      stack.topAnchor.constraint(equalTo: card.contentView.topAnchor),
      stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
    ])

    for row in section.rows {
      let rowView = SettingsNativeRowView()
      rowView.configure(
        row: row,
        theme: theme,
        onPress: { [weak self] in
          self?.onRowPress?(row.id)
        },
        onToggle: { [weak self] value in
          self?.onRowToggle?(row.id, value)
        }
      )
      stack.addArrangedSubview(rowView)
    }

    return wrapper
  }

  private func makeSignOutView() -> UIView {
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    signOutButton.removeFromSuperview()
    container.addSubview(signOutButton)

    NSLayoutConstraint.activate([
      signOutButton.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      signOutButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      signOutButton.topAnchor.constraint(equalTo: container.topAnchor),
      signOutButton.heightAnchor.constraint(equalToConstant: 54),
      signOutButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])

    return container
  }

  private func makeFooterView() -> UIView {
    let footerContainer = UIView()
    footerContainer.translatesAutoresizingMaskIntoConstraints = false
    footerLabel.removeFromSuperview()
    footerContainer.addSubview(footerLabel)

    NSLayoutConstraint.activate([
      footerLabel.leadingAnchor.constraint(equalTo: footerContainer.leadingAnchor),
      footerLabel.trailingAnchor.constraint(equalTo: footerContainer.trailingAnchor),
      footerLabel.topAnchor.constraint(equalTo: footerContainer.topAnchor, constant: 8),
      footerLabel.bottomAnchor.constraint(equalTo: footerContainer.bottomAnchor, constant: -12),
    ])

    return footerContainer
  }

  private func applyTheme() {
    backgroundView.backgroundColor = theme.background
    headerMaskLayer.colors = [
      theme.background.withAlphaComponent(theme.isDark ? 0.16 : 0.10).cgColor,
      theme.background.withAlphaComponent(theme.isDark ? 0.05 : 0.03).cgColor,
      UIColor.clear.cgColor,
    ]

    footerLabel.textColor = theme.secondaryText
    footerLabel.alpha = 0.5
    signOutButton.backgroundColor = theme.card.withAlphaComponent(theme.isDark ? 0.46 : 0.86)
    signOutButton.layer.borderWidth = 1.0 / UIScreen.main.scale
    signOutButton.layer.borderColor =
      (theme.isDark ? UIColor.white : UIColor.black).withAlphaComponent(theme.isDark ? 0.08 : 0.05).cgColor
    signOutButton.setTitleColor(
      UIColor(red: 239 / 255, green: 68 / 255, blue: 68 / 255, alpha: 1.0),
      for: .normal
    )
    signOutButton.setTitle("Sign Out", for: .normal)
    avatarView.setNameColors(
      primary: Color(uiColor: theme.text),
      secondary: Color(uiColor: theme.secondaryText)
    )
  }

  /// Matches SwiftUI hostBandHeight by construction (shared bandLayout formula).
  private func avatarBandHeight(for progress: CGFloat) -> CGFloat {
    SettingsAvatarHeroMetrics.bandLayout(
      progress: progress,
      topAir: SettingsAvatarHeroMetrics.topAir,
      circle: SettingsAvatarHeroMetrics.expandedSize,
      hero: SettingsAvatarHeroMetrics.heroBaseHeight(),
      nameBlock: 8 + nameOutsideHeight
    ).bandHeight
  }

  private func updateMetrics() {
    let topInset = window?.safeAreaInsets.top ?? safeAreaInsets.top
    currentSafeTop = topInset
    currentPinHeight = avatarBandHeight(for: 0)

    headerMaskHeightConstraint?.constant = topInset + 60

    let heroTop = SettingsAvatarHeroMetrics.expandedTop(for: topInset)
    avatarView.setExpandedSize(SettingsAvatarHeroMetrics.expandedSize)
    avatarView.setCollapsedSize(SettingsAvatarHeroMetrics.collapsedSize)
    avatarView.setExpandedTopInset(heroTop)
    avatarView.setCollapsedTopInset(SettingsAvatarHeroMetrics.stickyTop(for: topInset))
    avatarView.setBandMetrics(
      width: bounds.width > 1 ? bounds.width : UIScreen.main.bounds.width,
      heroBaseHeight: SettingsAvatarHeroMetrics.heroBaseHeight()
    )
    // Fable: never force discrete p here — re-derive from live offset so
    // updateUIView→configure cannot wipe mid-pull scale.
    updateScrollAnimations(offsetY: scrollView.contentOffset.y)
  }

  /// Full expanded→collapsed scrub distance. MUST be the exact band-height delta:
  /// that's what makes `bandHeight(p) + extraTop` constant during the live collapse
  /// (no contentSize churn → no offset re-clamp → the scroll never locks).
  private var collapseTravel: CGFloat {
    max(1, avatarBandHeight(for: 1) - avatarBandHeight(for: 0))
  }

  /// LIVE scroll-driven morphs (Telegram-style). Collapsed + pull-down: p scrubs up
  /// with the pull (image grows under the finger; full pull = it becomes the view).
  /// Expanded + scroll-up: p scrubs down with the scroll — the hero shrinks into the
  /// circle immediately, in real time, with no blur stage and no gesture hijack.
  private func updateScrollAnimations(offsetY: CGFloat) {
    // Freeze ALL samples during the expand-commit morph — no fighting the spring.
    if isCommittingHero { return }

    let adjusted = offsetY + scrollView.adjustedContentInset.top
    let y = min(offsetY, adjusted)

    if !heroExpanded {
      if y < 0 {
        // Finger-tracked expand scrub. Do NOT grow the UIKit band height while
        // rubber-banding — that contentSize change eats the overscroll and caps
        // p around ~0.15 (see logs). Visual p updates only; commit expands the band.
        let pLive = min(1, -y / SettingsAvatarHeroMetrics.expandPullTravel)
        avatarView.setScrollCollapseFade(0)
        avatarView.clipsToBounds = false
        heroExpandProgress = pLive
        avatarView.setHeroExpandProgress(pLive, animated: false)
        // Keep settled collapsed band height so bounce distance stays usable.
        let collapsedH = avatarBandHeight(for: 0)
        if abs((avatarBandHeightConstraint?.constant ?? 0) - collapsedH) > 0.5 {
          avatarBandHeightConstraint?.constant = collapsedH
        }
        if pLive >= 0.98, expandGestureArmed {
          expandGestureArmed = false
          NSLog("[HeroMorph] full-pull commit y=%.1f p=%.3f", Double(y), Double(pLive))
          commitHeroExpand()
        }
        return
      }
      expandGestureArmed = true
      avatarView.clipsToBounds = true
      if heroExpandProgress > 0 {
        applyHeaderLayout(p: 0, stretch: 0, extraTop: 0)
      }
      // Collapsed: no scale-on-scroll, but fade+shrink the avatar as it scrolls
      // toward exiting the top of the screen instead of just clipping off raw.
      let fadeRange = max(1, avatarBandHeight(for: 0))
      avatarView.setScrollCollapseFade(max(0, min(1, y / fadeRange)))
    } else {
      // Expanded: live collapse scrub. p falls with the scroll while extraTop rises
      // by the exact consumed distance — band height stays constant, so the
      // shrinking hero pins toward its rest spot while the rows ride the scroll
      // natively (no offset writes, no pan disable). State swaps only at rest.
      let travel = collapseTravel
      let yc = max(0, min(y, travel))
      let pLive = 1 - yc / travel
      applyHeaderLayout(p: pLive, stretch: liveOverscrollStretch(), extraTop: yc)
      // Past the full travel the settled circle rides off — same fade as collapsed.
      let fadeRange = max(1, avatarBandHeight(for: 0))
      avatarView.setScrollCollapseFade(
        y > travel ? max(0, min(1, (y - travel) / fadeRange)) : 0)
      if abs(y - lastHeroSampleLogY) > 24 {
        lastHeroSampleLogY = y
        NSLog(
          "[HeroMorph] scrub y=%.1f p=%.3f band=%.1f",
          Double(y), Double(pLive), Double(avatarBandHeightConstraint?.constant ?? -1)
        )
      }
    }
  }

  // `response`/damping of the analytic spring in stepHeroMorph. Slightly softer than
  // critical so the finish has a visible spring settle — never a jump. The live scrub
  // has usually carried p most of the way already, so the felt commit is quick.
  private static let heroExpandDuration: TimeInterval = 0.24
  private static let heroExpandDamping: Double = 0.82

  /// Commit the EXPAND from the live scrub: the spring finishes the remaining p and
  /// decays the consumed overscroll. (Collapse never commits an animation — the live
  /// scrub IS the collapse, and `rebaseCollapsedIfSettled` swaps state at rest.)
  private func commitHeroExpand() {
    guard !heroExpanded, !isCommittingHero else { return }

    isCommittingHero = true
    heroExpanded = true
    avatarView.clipsToBounds = true

    UIImpactFeedbackGenerator(style: .medium).impactOccurred()

    avatarView.transform = .identity
    avatarView.setScrollCollapseFade(0)

    // Consume the rubber-band overscroll COMPENSATED: offset snaps to 0 (UIKit clamps
    // it anyway one frame later — the old 35pt list jump) while extraTop pushes the
    // media + band down by the exact same amount, so the commit frame is pixel-
    // identical. extraTop then decays to 0 inside the morph curve — one smooth motion.
    let offsetY = scrollView.contentOffset.y
    let y = min(offsetY, offsetY + scrollView.adjustedContentInset.top)
    let consumedOverscroll = max(0, -y)
    let wasTracking = scrollView.isTracking
    if consumedOverscroll > 0 {
      scrollView.setContentOffset(.zero, animated: false)
    }
    // Only a full-pull commit still has the finger down — cancel that pan
    // (Telegram-style takeover) so it can't rewrite the just-consumed offset.
    // Release-commits never touch the gesture.
    if wasTracking {
      scrollView.panGestureRecognizer.isEnabled = false
    }
    heroMorphOverscroll = consumedOverscroll

    NSLog(
      "[HeroMorph] commit expand fromP=%.3f consumed=%.1f tracking=%d band=%.1f",
      Double(heroExpandProgress),
      Double(consumedOverscroll),
      wasTracking ? 1 : 0,
      Double(avatarBandHeightConstraint?.constant ?? -1)
    )

    // Apply the compensated state NOW (same runloop turn) — waiting for the first
    // display-link tick would render one uncompensated (jumped) frame.
    applyHeaderLayout(p: heroExpandProgress, stretch: 0, extraTop: consumedOverscroll)
    layoutIfNeeded()

    let w = bounds.width > 1 ? bounds.width : UIScreen.main.bounds.width
    avatarView.setBandMetrics(
      width: w,
      heroBaseHeight: SettingsAvatarHeroMetrics.heroBaseHeight()
    )

    // ONE display-link driver for the shared progress: the UIKit band constraint
    // and the SwiftUI media read the SAME p every frame, so the band can never clip
    // the image mid-flight (the old UIKit-vs-SwiftUI dual-spring desync = clip-then-pop).
    startHeroMorph(from: heroExpandProgress, to: 1)
  }

  private func startHeroMorph(from: CGFloat, to target: CGFloat) {
    heroMorphDisplayLink?.invalidate()
    heroMorphFrom = from
    heroMorphTarget = target
    heroMorphStart = CACurrentMediaTime()
    let link = CADisplayLink(target: self, selector: #selector(stepHeroMorph(_:)))
    if #available(iOS 15.0, *) {
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
    }
    link.add(to: .main, forMode: .common)
    heroMorphDisplayLink = link
  }

  /// Analytic underdamped-spring ease: a slight soft overshoot-settle instead of
  /// easeOutCubic's hard mechanical stop — matches SwiftUI's own
  /// `.spring(response:dampingFraction:)` model so the Settings and Profile hero
  /// views share the same motion feel.
  private static func springEase(
    elapsed: TimeInterval, response: TimeInterval, damping: Double, initialVelocity: Double = 0
  ) -> CGFloat {
    guard response > 0 else { return 1 }
    let omegaN = 2 * Double.pi / response
    let zeta = min(0.999, max(0.001, damping))
    if zeta >= 1 {
      let x = 1 - (1 + (omegaN - initialVelocity) * elapsed) * exp(-omegaN * elapsed)
      return CGFloat(x)
    }
    let omegaD = omegaN * sqrt(1 - zeta * zeta)
    let envelope = exp(-zeta * omegaN * elapsed)
    let b = (zeta * omegaN - initialVelocity) / omegaD
    let x = 1 - envelope * (cos(omegaD * elapsed) + b * sin(omegaD * elapsed))
    return CGFloat(x)
  }

  @objc private func stepHeroMorph(_ link: CADisplayLink) {
    let elapsed = CACurrentMediaTime() - heroMorphStart
    let t = min(1, max(0, elapsed / Self.heroExpandDuration))
    let eased = Self.springEase(
      elapsed: elapsed,
      response: Self.heroExpandDuration,
      damping: Self.heroExpandDamping
    )
    let p = heroMorphFrom + (heroMorphTarget - heroMorphFrom) * eased
    // NO live offset sampling mid-flight: growing the band makes UIScrollView re-clamp
    // the offset every frame, and feeding that back as stretch oscillated the band
    // (the "noisy soft jump" flicker). Only the consumed-at-commit overscroll decays.
    let extraTop = heroMorphOverscroll * max(0, 1 - eased)
    // Constraint first, THEN offset: the band resize changes contentSize, and a
    // stale contentSize can clamp the offset write.
    applyHeaderLayout(p: p, stretch: 0, extraTop: extraTop)
    layoutIfNeeded()
    // Pin the offset so every committed frame renders identical 0 — any residual
    // writer (bounce-back physics, clamp) would jitter the whole list.
    if scrollView.contentOffset.y != 0 {
      scrollView.contentOffset = .zero
    }
    heroMorphLog(stage: "tick", t: t, p: p, stretch: 0, extraTop: extraTop)
    // Settle-aware finish (hard cap 3× duration).
    if elapsed >= Self.heroExpandDuration, abs(1 - eased) < 0.01 {
      finishHeroMorph()
    } else if elapsed >= Self.heroExpandDuration * 3 {
      finishHeroMorph()
    }
  }

  private func finishHeroMorph() {
    heroMorphDisplayLink?.invalidate()
    heroMorphDisplayLink = nil
    heroMorphOverscroll = 0
    let stretch = liveOverscrollStretch()
    applyHeaderLayout(p: heroMorphTarget, stretch: stretch)
    layoutIfNeeded()
    avatarView.transform = .identity
    if !scrollView.panGestureRecognizer.isEnabled {
      scrollView.panGestureRecognizer.isEnabled = true
    }
    isCommittingHero = false
    heroMorphLog(stage: "finish", t: 1, p: heroMorphTarget, stretch: stretch, extraTop: 0)
  }

  /// Same y-derivation as updateScrollAnimations. 1pt continuous deadband so tiny
  /// offset oscillations around zero don't jiggle the band height.
  private func liveOverscrollStretch() -> CGFloat {
    let offsetY = scrollView.contentOffset.y
    let y = min(offsetY, offsetY + scrollView.adjustedContentInset.top)
    guard y < -1 else { return 0 }
    return min(-y - 1, bounds.height * 0.12)
  }

  private func heroMorphLog(stage: String, t: CGFloat, p: CGFloat, stretch: CGFloat, extraTop: CGFloat) {
    let rowsY = bodyStack.convert(CGPoint.zero, to: nil).y
    NSLog(
      "[HeroMorph] %@ t=%.2f p=%.3f stretch=%.1f extraTop=%.1f offY=%.1f band=%.1f avatarH=%.1f rowsY=%.1f dragging=%d",
      stage,
      Double(t),
      Double(p),
      Double(stretch),
      Double(extraTop),
      Double(scrollView.contentOffset.y),
      Double(avatarBandHeightConstraint?.constant ?? -1),
      Double(avatarView.frame.height),
      Double(rowsY),
      scrollView.isDragging ? 1 : 0
    )
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    updateScrollAnimations(offsetY: scrollView.contentOffset.y)
  }

  func scrollViewWillEndDragging(
    _ scrollView: UIScrollView,
    withVelocity velocity: CGPoint,
    targetContentOffset: UnsafeMutablePointer<CGPoint>
  ) {
    guard heroExpanded, !isCommittingHero else { return }
    let travel = collapseTravel
    let target = targetContentOffset.pointee.y
    guard target > 0.5, target < travel - 0.5 else { return }
    // Mid-scrub release: land on a settled state (full hero or full circle) —
    // native deceleration animates it and the live scrub renders the morph, so
    // the gesture/momentum is never interrupted.
    let toCollapsed = velocity.y > 0.3 || (velocity.y >= -0.3 && target > travel * 0.5)
    targetContentOffset.pointee.y = toCollapsed ? travel : 0
    NSLog(
      "[HeroMorph] snap target=%.1f -> %.1f v=%.2f",
      Double(target), Double(targetContentOffset.pointee.y), Double(velocity.y)
    )
  }

  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    maybeCommitExpandOnRelease()
    if !decelerate { rebaseCollapsedIfSettled() }
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    rebaseCollapsedIfSettled()
  }

  /// Release-commit: letting go past half the pull travel finishes the expand with
  /// the spring; below it the native bounce shrinks the hero back on its own.
  private func maybeCommitExpandOnRelease() {
    guard !heroExpanded, !isCommittingHero else { return }
    let offsetY = scrollView.contentOffset.y
    let y = min(offsetY, offsetY + scrollView.adjustedContentInset.top)
    let pull = max(0, -y)
    let commitPull =
      SettingsAvatarHeroMetrics.expandPullTravel
      * SettingsAvatarHeroMetrics.expandCommitFraction
    guard pull >= commitPull else { return }
    expandGestureArmed = false
    NSLog("[HeroMorph] release-commit pull=%.1f fromP=%.3f", Double(pull), Double(heroExpandProgress))
    commitHeroExpand()
  }

  /// The live scrub leaves `heroExpanded` on while rendering the circle. Once the
  /// scroll SETTLES past the full travel, swap to the committed collapsed state
  /// pixel-identically: the band drops by exactly the travel and the offset rebases
  /// by the same amount — nothing on screen moves and nothing animates.
  private func rebaseCollapsedIfSettled() {
    guard heroExpanded, !isCommittingHero else { return }
    let travel = collapseTravel
    let y = scrollView.contentOffset.y
    guard y >= travel - 0.5 else { return }
    heroExpanded = false
    UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
    applyHeaderLayout(p: 0, stretch: 0, extraTop: 0)
    layoutIfNeeded()
    scrollView.contentOffset = CGPoint(x: 0, y: max(0, y - travel))
    expandGestureArmed = true
    NSLog("[HeroMorph] rebase-collapsed y=%.1f travel=%.1f", Double(y), Double(travel))
  }

  @objc private func handleAvatarTap(_ gesture: UITapGestureRecognizer) {
    guard gesture.state == .ended else { return }
    // Only fire photo picker if tap lands on the circle/hero media, not empty chrome.
    let point = gesture.location(in: avatarView)
    guard avatarView.bounds.contains(point) else { return }
    // Prefer center band of current avatar host.
    let inset = avatarView.bounds.insetBy(dx: 24, dy: 24)
    guard inset.contains(point) || heroExpandProgress > 0.2 else { return }
    presentAvatarImagePicker()
  }

  // Note: avatarView is non-interactive so pans always hit scrollView (required for scale).



  @objc private func handleSignOutPress() {
    onSignOut?()
  }

  private func presentAvatarImagePicker() {
    guard let presenter = findPresenter() else { return }
    let picker = UIImagePickerController()
    picker.sourceType = .photoLibrary
    picker.allowsEditing = true
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  private func findPresenter() -> UIViewController? {
    var responder: UIResponder? = self
    while let next = responder?.next {
      if let vc = next as? UIViewController { return vc }
      responder = next
    }
    return nil
  }

  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    picker.dismiss(animated: true)
    let image =
      (info[.editedImage] as? UIImage)
      ?? (info[.originalImage] as? UIImage)
    guard let image, let data = image.jpegData(compressionQuality: 0.82) else { return }
    // Optimistic local paint while upload runs.
    avatarView.applyLocalImage(image)
    Task { @MainActor in
      guard let config = AppSessionConfig.current else { return }
      do {
        let url = try await ChatRoomCreateService.uploadAvatar(imageData: data, config: config)
        ChatAvatarImageStore.replaceHero(image, for: url)
        _ = try await AppProfileController.shared.updateFields(["profileImage": url])
        avatarView.setImageURI(url, force: true)
        AppToastController.shared.show("Photo updated")
      } catch {
        AppToastController.shared.show(error.localizedDescription)
      }
    }
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
  }
}

struct SettingsNativeMainViewRepresentable: UIViewRepresentable {
  let displayName: String
  let subtitle: String
  let avatarImageURI: String?
  let avatarFallbackText: String
  var avatarUserId: String = ""
  let footerText: String
  let sections: [SettingsNativeSection]
  let palette: AppThemePalette
  let isDark: Bool
  let onRowPress: (String) -> Void
  let onRowToggle: (String, Bool) -> Void
  var onAvatarTap: (() -> Void)? = nil

  let onSignOut: () -> Void

  func makeUIView(context: Context) -> SettingsNativeMainView {
    SettingsNativeMainView()
  }

  func updateUIView(_ uiView: SettingsNativeMainView, context: Context) {
    uiView.configure(
      displayName: displayName,
      subtitle: subtitle,
      avatarImageURI: avatarImageURI,
      avatarFallbackText: avatarFallbackText,
      avatarUserId: avatarUserId,
      footerText: footerText,
      sections: sections,
      palette: palette,
      isDark: isDark,
      onRowPress: onRowPress,
      onRowToggle: onRowToggle,
      onAvatarTap: onAvatarTap,
      onSignOut: onSignOut
    )
  }
}
