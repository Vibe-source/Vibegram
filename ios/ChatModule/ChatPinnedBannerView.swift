import UIKit

/// Floating glass chip used for pin / usage banners.
///
/// Important for Liquid Glass (iOS 26+): a **single** `UIGlassEffect` owns the shell.
/// Content (icon, labels, dots, close) lives inside `blurView.contentView` — never as
/// sibling overlays outside the glass, and never as a second nested glass layer.
/// Nesting or sibling chrome breaks the interactive "tab" refraction.
final class ChatPinnedBannerView: UIControl {
  static let preferredHeight: CGFloat = 44.0

  private let blurView = UIVisualEffectView(effect: nil)
  /// Content that can translate on carousel swaps without fading the glass shell.
  private let contentContainer = UIView()
  private let iconContainer = UIView()
  private let iconGlowView = UIView()
  private let iconImageView = UIImageView()
  private let titleLabel = UILabel()
  private let bodyLabel = UILabel()
  private let textStack = UIStackView()
  private let closeButton = UIButton(type: .system)
  /// Vertical page dots (leading edge) for multi-agent usage carousel.
  private let pageDotsStack = UIStackView()
  private var pageDotViews: [UIView] = []
  private var isFilePinned = false
  private var iconAccentColor: UIColor?
  private var textColor: UIColor = .label
  private var pageCount: Int = 0
  private var pageIndex: Int = 0

  /// When set, a trailing ✕ appears and taps on it call this instead of the banner's
  /// own touch-up action (the button swallows its touches as a UIControl subview).
  var onClose: (() -> Void)? {
    didSet { closeButton.isHidden = onClose == nil }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(title: String, body: String, isFile: Bool, animateIcon: Bool = false) {
    let shouldAnimate =
      animateIcon
      || titleLabel.text != title
      || bodyLabel.text != body
      || isFilePinned != isFile

    titleLabel.text = title
    bodyLabel.text = body
    isFilePinned = isFile
    iconImageView.image = UIImage(systemName: isFile ? "pin.circle.fill" : "pin.fill")
    if animateIcon || shouldAnimate {
      animatePinIcon()
    }
    setNeedsLayout()
  }

  /// Configures the banner with an explicit SF Symbol — used by the agent Inbox
  /// banner (tray icon) rather than the default pin glyph.
  func configure(title: String, body: String, systemImage: String, animateIcon: Bool = false) {
    let titleChanged = titleLabel.text != title
    let bodyChanged = bodyLabel.text != body
    titleLabel.text = title
    bodyLabel.text = body
    iconImageView.image = UIImage(systemName: systemImage)
    if animateIcon || titleChanged || bodyChanged {
      animatePinIcon()
    }
    setNeedsLayout()
  }

  /// Multi-agent usage carousel: leading vertical dots for page count/index.
  /// Active dot expands in height (thin pill). `count <= 1` hides the dots.
  func setPageIndicator(count: Int, index: Int, animated: Bool = true) {
    let nextCount = max(0, count)
    let nextIndex = nextCount == 0 ? 0 : min(max(0, index), nextCount - 1)
    let changed = pageCount != nextCount || pageIndex != nextIndex
    pageCount = nextCount
    pageIndex = nextIndex
    rebuildPageDotsIfNeeded()
    pageDotsStack.isHidden = nextCount <= 1
    let apply = { [weak self] in
      self?.applyPageDotStyles()
      self?.setNeedsLayout()
      self?.layoutIfNeeded()
    }
    if animated, changed, !pageDotsStack.isHidden {
      UIView.animate(
        withDuration: 0.28,
        delay: 0,
        usingSpringWithDamping: 0.78,
        initialSpringVelocity: 0.5,
        options: [.beginFromCurrentState, .allowUserInteraction],
        animations: apply
      )
    } else {
      apply()
    }
  }

  /// Slide only the inner content (icon + text + dots) along Y — glass shell stays put, no fade.
  func animateContentTranslateY(from dy: CGFloat) {
    contentContainer.layer.removeAllAnimations()
    contentContainer.transform = CGAffineTransform(translationX: 0, y: dy)
    UIView.animate(
      withDuration: 0.28,
      delay: 0,
      usingSpringWithDamping: 0.86,
      initialSpringVelocity: 0.4,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.contentContainer.transform = .identity
      self.contentContainer.alpha = 1.0
    }
  }

  /// Finger-follow for the usage carousel: the inner content tracks the drag along X
  /// while the glass shell stays put. Fades slightly toward the edges so a full
  /// commit reads as the content leaving, not the banner tearing.
  func setContentTranslationX(_ dx: CGFloat) {
    contentContainer.layer.removeAllAnimations()
    contentContainer.transform = CGAffineTransform(translationX: dx, y: 0)
    let width = max(1.0, bounds.width)
    contentContainer.alpha = max(0.35, 1.0 - abs(dx) / width * 0.9)
  }

  /// Settle the inner content back to rest from an X offset (page landed / drag
  /// cancelled) — spring home, restoring full opacity.
  func animateContentTranslateX(from dx: CGFloat) {
    contentContainer.layer.removeAllAnimations()
    contentContainer.transform = CGAffineTransform(translationX: dx, y: 0)
    UIView.animate(
      withDuration: 0.32,
      delay: 0,
      usingSpringWithDamping: 0.85,
      initialSpringVelocity: 0.5,
      options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      self.contentContainer.transform = .identity
      self.contentContainer.alpha = 1.0
    }
  }

  func applyTheme(textColor: UIColor, surfaceColor: UIColor, isDark: Bool) {
    self.textColor = textColor
    // One glass shell only — never nest another effect or opaque fill under it.
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .regular)
      glass.isInteractive = true
      blurView.effect = glass
      blurView.contentView.backgroundColor = .clear
    } else {
      blurView.effect = UIBlurEffect(style: .systemThinMaterial)
      blurView.contentView.backgroundColor = surfaceColor.withAlphaComponent(isDark ? 0.16 : 0.10)
    }
    backgroundColor = .clear
    blurView.alpha = 1.0
    alpha = 1.0
    let iconColor = iconAccentColor ?? textColor
    let iconFillColor = iconAccentColor ?? surfaceColor
    // Soft tint disc, not a second glass material.
    iconContainer.backgroundColor = iconFillColor.withAlphaComponent(isDark ? 0.22 : 0.14)
    iconGlowView.backgroundColor = iconColor.withAlphaComponent(isDark ? 0.28 : 0.18)
    iconImageView.tintColor = iconColor.withAlphaComponent(0.95)
    titleLabel.textColor = textColor.withAlphaComponent(0.96)
    bodyLabel.textColor = textColor.withAlphaComponent(0.82)
    closeButton.tintColor = textColor.withAlphaComponent(0.55)
    applyPageDotStyles()
  }

  func applyIconAccent(_ color: UIColor?) {
    iconAccentColor = color
  }

  private func setup() {
    backgroundColor = .clear
    isUserInteractionEnabled = true
    // Blur must not steal UIControl hit-tracking; close is handled via hitTest.
    blurView.isUserInteractionEnabled = false
    contentContainer.isUserInteractionEnabled = false
    pageDotsStack.isUserInteractionEnabled = false

    // Single glass shell as the only material layer.
    addSubview(blurView)
    blurView.layer.cornerCurve = .continuous
    blurView.layer.cornerRadius = ChatPinnedBannerView.preferredHeight / 2.0
    // Clip only the material to the capsule — content is inside contentView so
    // the interactive glass "tab" refraction still applies to the whole chip.
    blurView.clipsToBounds = true
    blurView.contentView.clipsToBounds = true
    blurView.contentView.backgroundColor = .clear

    // All chrome lives INSIDE the glass contentView (not as external siblings).
    blurView.contentView.addSubview(contentContainer)
    contentContainer.addSubview(pageDotsStack)
    contentContainer.addSubview(iconContainer)
    iconContainer.addSubview(iconGlowView)
    iconContainer.addSubview(iconImageView)
    contentContainer.addSubview(textStack)
    contentContainer.addSubview(closeButton)

    pageDotsStack.axis = .vertical
    pageDotsStack.alignment = .center
    pageDotsStack.distribution = .equalSpacing
    pageDotsStack.spacing = 3.0
    pageDotsStack.isHidden = true

    iconImageView.image = UIImage(systemName: "pin.fill")
    iconImageView.contentMode = .scaleAspectFit
    iconImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
      pointSize: 13, weight: .semibold)

    iconContainer.layer.cornerCurve = .continuous
    iconContainer.layer.cornerRadius = 14.0
    iconGlowView.layer.cornerCurve = .continuous
    iconGlowView.layer.cornerRadius = 14.0
    iconGlowView.alpha = 0.0

    titleLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
    titleLabel.numberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail

    bodyLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
    bodyLabel.numberOfLines = 1
    bodyLabel.lineBreakMode = .byTruncatingTail

    textStack.axis = .vertical
    textStack.alignment = .fill
    textStack.distribution = .fill
    textStack.spacing = 0.0
    textStack.addArrangedSubview(titleLabel)
    textStack.addArrangedSubview(bodyLabel)

    closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
    closeButton.setPreferredSymbolConfiguration(
      UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold), forImageIn: .normal)
    closeButton.isHidden = true
    closeButton.isUserInteractionEnabled = true
    closeButton.addAction(
      UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    blurView.frame = bounds
    // contentView always fills blurView.
    let host = blurView.contentView.bounds
    contentContainer.frame = host

    let closeSize: CGFloat = 32.0
    closeButton.frame = CGRect(
      x: host.width - closeSize - 6.0,
      y: (host.height - closeSize) * 0.5,
      width: closeSize,
      height: closeSize
    )

    // Dots on the LEADING edge (thinner column).
    let showsDots = pageCount > 1
    let dotsColumnWidth: CGFloat = showsDots ? 5.0 : 0.0
    let dotsLeading: CGFloat = showsDots ? 8.0 : 0.0
    let dotsTrailingGap: CGFloat = showsDots ? 6.0 : 0.0
    let leadingContentX: CGFloat = showsDots ? (dotsLeading + dotsColumnWidth + dotsTrailingGap) : 0.0
    let trailingReserve: CGFloat = closeButton.isHidden ? 12.0 : closeSize + 8.0

    if showsDots {
      var totalH: CGFloat = 0
      for i in 0..<pageCount {
        totalH += (i == pageIndex ? 9.0 : 3.0)
        if i < pageCount - 1 { totalH += 3.0 }
      }
      pageDotsStack.frame = CGRect(
        x: dotsLeading,
        y: (host.height - totalH) * 0.5,
        width: dotsColumnWidth,
        height: totalH
      )
    } else {
      pageDotsStack.frame = .zero
    }

    let iconSize: CGFloat = 28.0
    let iconX = leadingContentX + 10.0
    iconContainer.frame = CGRect(
      x: iconX,
      y: (host.height - iconSize) * 0.5,
      width: iconSize,
      height: iconSize
    )
    iconGlowView.frame = iconContainer.bounds
    iconImageView.frame = iconContainer.bounds.insetBy(dx: 7.0, dy: 7.0)

    let hasTextLayoutSpace = host.width > 40.0 && host.height > 12.0
    textStack.isHidden = !hasTextLayoutSpace
    titleLabel.isHidden = !hasTextLayoutSpace
    bodyLabel.isHidden = !hasTextLayoutSpace
    guard hasTextLayoutSpace else {
      textStack.frame = .zero
      return
    }

    let textX = iconContainer.frame.maxX + 10.0
    textStack.frame = CGRect(
      x: textX,
      y: 6.0,
      width: max(0.0, host.width - textX - trailingReserve),
      height: max(0.0, host.height - 12.0)
    )
  }

  /// Prefer banner tap over child views except the close button.
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    guard !isHidden, alpha > 0.01, isUserInteractionEnabled, bounds.contains(point) else {
      return nil
    }
    if !closeButton.isHidden {
      let closePoint = closeButton.convert(point, from: self)
      if closeButton.bounds.contains(closePoint) {
        return closeButton
      }
    }
    return self
  }

  private var pageDotWidthConstraints: [NSLayoutConstraint] = []
  private var pageDotHeightConstraints: [NSLayoutConstraint] = []

  private func rebuildPageDotsIfNeeded() {
    while pageDotViews.count < pageCount {
      let dot = UIView()
      dot.layer.cornerCurve = .continuous
      dot.translatesAutoresizingMaskIntoConstraints = false
      let w = dot.widthAnchor.constraint(equalToConstant: 3)
      let h = dot.heightAnchor.constraint(equalToConstant: 3)
      NSLayoutConstraint.activate([w, h])
      pageDotWidthConstraints.append(w)
      pageDotHeightConstraints.append(h)
      pageDotsStack.addArrangedSubview(dot)
      pageDotViews.append(dot)
    }
    while pageDotViews.count > pageCount {
      let last = pageDotViews.removeLast()
      pageDotsStack.removeArrangedSubview(last)
      last.removeFromSuperview()
      if !pageDotWidthConstraints.isEmpty { pageDotWidthConstraints.removeLast() }
      if !pageDotHeightConstraints.isEmpty { pageDotHeightConstraints.removeLast() }
    }
  }

  private func applyPageDotStyles() {
    for (i, dot) in pageDotViews.enumerated() {
      let active = i == pageIndex
      // Thin vertical pill when active; small circle when idle.
      let w: CGFloat = 3.0
      let h: CGFloat = active ? 9.0 : 3.0
      if i < pageDotWidthConstraints.count { pageDotWidthConstraints[i].constant = w }
      if i < pageDotHeightConstraints.count { pageDotHeightConstraints[i].constant = h }
      dot.layer.cornerRadius = w * 0.5
      dot.backgroundColor = textColor.withAlphaComponent(active ? 0.90 : 0.28)
    }
  }

  private func animatePinIcon() {
    iconContainer.layer.removeAnimation(forKey: "pinScale")
    iconImageView.layer.removeAnimation(forKey: "pinWiggle")
    iconGlowView.layer.removeAnimation(forKey: "pinGlow")

    let wiggle = CAKeyframeAnimation(keyPath: "transform.rotation.z")
    wiggle.values = [0.0, -0.18, 0.14, -0.08, 0.04, 0.0]
    wiggle.keyTimes = [0.0, 0.2, 0.42, 0.62, 0.82, 1.0]
    wiggle.duration = 0.46
    wiggle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    iconImageView.layer.add(wiggle, forKey: "pinWiggle")

    let scale = CASpringAnimation(keyPath: "transform.scale")
    scale.fromValue = 0.88
    scale.toValue = 1.0
    scale.initialVelocity = 0.7
    scale.damping = 10.0
    scale.stiffness = 140.0
    scale.mass = 0.9
    scale.duration = scale.settlingDuration
    iconContainer.layer.add(scale, forKey: "pinScale")

    iconGlowView.alpha = 0.0
    UIView.animate(
      withDuration: 0.18,
      delay: 0.0,
      options: [.beginFromCurrentState, .curveEaseOut]
    ) {
      self.iconGlowView.alpha = 1.0
    } completion: { _ in
      UIView.animate(
        withDuration: 0.32,
        delay: 0.0,
        options: [.beginFromCurrentState, .curveEaseIn]
      ) {
        self.iconGlowView.alpha = 0.0
      }
    }
  }
}
