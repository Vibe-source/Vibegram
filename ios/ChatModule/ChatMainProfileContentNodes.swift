import UIKit
import AVFoundation
import CoreImage

final class ChatMainProfileTabNode: UIControl {
  private let titleLabel = UILabel()
  private let pressedOverlay = UIView()

  private var normalTextColor: UIColor = .secondaryLabel
  private var activeTextColor: UIColor = .label
  private var activeBackgroundColor: UIColor = UIColor(white: 1.0, alpha: 0.12)

  var isActive: Bool = false {
    didSet { applyState() }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    clipsToBounds = true
    layer.cornerCurve = .continuous
    layer.cornerRadius = 18.0

    titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .medium)
    titleLabel.textAlignment = .center
    addSubview(titleLabel)

    pressedOverlay.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
    pressedOverlay.alpha = 0.0
    pressedOverlay.isUserInteractionEnabled = false
    addSubview(pressedOverlay)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    titleLabel.frame = bounds.insetBy(dx: 14.0, dy: 6.0)
    pressedOverlay.frame = bounds
  }

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(
        withDuration: isHighlighted ? 0.08 : 0.18, delay: 0.0,
        options: [.curveEaseOut, .allowUserInteraction]
      ) {
        self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
        self.pressedOverlay.alpha = self.isHighlighted ? 1.0 : 0.0
      }
    }
  }

  func setTitle(_ title: String) {
    titleLabel.text = title
  }

  func applyTheme(
    activeTextColor: UIColor,
    normalTextColor: UIColor,
    activeBackgroundColor: UIColor
  ) {
    self.activeTextColor = activeTextColor
    self.normalTextColor = normalTextColor
    self.activeBackgroundColor = activeBackgroundColor
    applyState()
  }

  private func applyState() {
    backgroundColor = isActive ? activeBackgroundColor : .clear
    titleLabel.textColor = isActive ? activeTextColor : normalTextColor
  }
}

final class ChatMainProfileListRowNode: UIControl {
  private let iconContainer = UIView()
  private let iconImageView = UIImageView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let valueLabel = UILabel()
  private let chevronImageView = UIImageView()
  private let separatorView = UIView()
  private let pressedOverlay = UIView()

  private var defaultTitleColor: UIColor = .label
  private var subtitleColor: UIColor = .secondaryLabel
  private var valueColor: UIColor = .secondaryLabel
  private var separatorColor: UIColor = UIColor(white: 1.0, alpha: 0.08)
  private var highlightedColor: UIColor = UIColor(white: 1.0, alpha: 0.04)
  private var titleColorOverride: UIColor?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    clipsToBounds = true

    iconContainer.layer.cornerRadius = 10.0
    iconContainer.layer.cornerCurve = .continuous
    iconContainer.backgroundColor = UIColor(white: 1.0, alpha: 0.06)
    iconContainer.isHidden = true
    addSubview(iconContainer)

    iconImageView.contentMode = .scaleAspectFit
    iconImageView.tintColor = .white
    iconContainer.addSubview(iconImageView)

    titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    titleLabel.numberOfLines = 1
    addSubview(titleLabel)

    subtitleLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
    subtitleLabel.numberOfLines = 2
    addSubview(subtitleLabel)

    valueLabel.font = UIFont.systemFont(ofSize: 15, weight: .regular)
    valueLabel.textAlignment = .right
    valueLabel.numberOfLines = 1
    addSubview(valueLabel)

    let chevronConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    chevronImageView.image = UIImage(systemName: "chevron.right", withConfiguration: chevronConfig)
    chevronImageView.tintColor = UIColor(white: 1.0, alpha: 0.2)
    chevronImageView.contentMode = .center
    addSubview(chevronImageView)

    separatorView.backgroundColor = separatorColor
    addSubview(separatorView)

    pressedOverlay.backgroundColor = highlightedColor
    pressedOverlay.alpha = 0.0
    pressedOverlay.isUserInteractionEnabled = false
    addSubview(pressedOverlay)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let hasIcon = !iconContainer.isHidden
    let insetX: CGFloat = hasIcon ? 64.0 : 20.0

    if hasIcon {
      iconContainer.frame = CGRect(
        x: 16.0, y: (bounds.height - 36.0) / 2.0, width: 36.0, height: 36.0)
      iconImageView.frame = iconContainer.bounds.insetBy(dx: 8.0, dy: 8.0)
    }

    let chevronWidth: CGFloat = 20.0
    let hasChevron = !chevronImageView.isHidden
    let valueWidth: CGFloat = valueLabel.isHidden ? 0.0 : 56.0
    chevronImageView.frame = CGRect(
      x: bounds.width - 16.0 - chevronWidth,
      y: (bounds.height - chevronWidth) / 2.0,
      width: chevronWidth,
      height: chevronWidth
    )
    valueLabel.frame = CGRect(
      x: bounds.width - 16.0 - (hasChevron ? chevronWidth + 8.0 : 0.0) - valueWidth,
      y: 0.0,
      width: valueWidth,
      height: bounds.height
    )

    let textWidth =
      bounds.width
      - insetX
      - (hasChevron ? chevronWidth + 12.0 : 0.0)
      - (valueLabel.isHidden ? 0.0 : valueWidth + 10.0)
    let hasSubtitle = !(subtitleLabel.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

    if hasSubtitle {
      titleLabel.frame = CGRect(
        x: insetX, y: 12.0, width: textWidth, height: 22.0)
      let subtitleHeight = max(0.0, bounds.height - titleLabel.frame.maxY - 12.0)
      subtitleLabel.frame = CGRect(
        x: insetX,
        y: titleLabel.frame.maxY,
        width: textWidth,
        height: subtitleHeight
      )
    } else {
      titleLabel.frame = CGRect(
        x: insetX,
        y: (bounds.height - 22.0) * 0.5,
        width: textWidth,
        height: 22.0
      )
      subtitleLabel.frame = .zero
    }
    separatorView.frame = CGRect(
      x: insetX,
      y: bounds.height - (1.0 / UIScreen.main.scale),
      width: max(0.0, bounds.width - insetX),
      height: 1.0 / UIScreen.main.scale
    )
    pressedOverlay.frame = bounds
  }

  override var isHighlighted: Bool {
    didSet {
      guard isEnabled else { return }
      UIView.animate(
        withDuration: isHighlighted ? 0.08 : 0.16, delay: 0.0,
        options: [.curveEaseOut, .allowUserInteraction]
      ) {
        self.pressedOverlay.alpha = self.isHighlighted ? 1.0 : 0.0
      }
    }
  }

  func configure(
    title: String,
    subtitle: String,
    value: String = "",
    titleColor: UIColor? = nil,
    showsSeparator: Bool,
    iconName: String? = nil,
    iconTintColor: UIColor? = nil,
    iconBackgroundColor: UIColor? = nil,
    showsChevron: Bool = true
  ) {
    titleLabel.text = title
    subtitleLabel.text = subtitle
    subtitleLabel.isHidden = subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    valueLabel.text = value
    valueLabel.isHidden = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    chevronImageView.isHidden = !showsChevron
    titleColorOverride = titleColor
    separatorView.isHidden = !showsSeparator
    titleLabel.textColor = titleColor ?? defaultTitleColor
    subtitleLabel.textColor = subtitleColor
    valueLabel.textColor = valueColor

    if let iconName {
      iconContainer.isHidden = false
      iconImageView.image = UIImage(systemName: iconName)
      if let tintColor = iconTintColor {
        iconImageView.tintColor = tintColor
      }
      if let bgColor = iconBackgroundColor {
        iconContainer.backgroundColor = bgColor
      }
    } else {
      iconContainer.isHidden = true
    }
  }

  func applyTheme(
    titleColor: UIColor,
    subtitleColor: UIColor,
    separatorColor: UIColor,
    highlightedColor: UIColor,
    valueColor: UIColor? = nil
  ) {
    defaultTitleColor = titleColor
    self.subtitleColor = subtitleColor
    self.valueColor = valueColor ?? subtitleColor
    self.separatorColor = separatorColor
    self.highlightedColor = highlightedColor
    titleLabel.textColor = titleColorOverride ?? titleColor
    subtitleLabel.textColor = subtitleColor
    valueLabel.textColor = self.valueColor
    separatorView.backgroundColor = separatorColor
    pressedOverlay.backgroundColor = highlightedColor
  }
}

final class ChatMainProfileMediaCellNode: UIControl {
  private static let imageCache = NSCache<NSString, UIImage>()
  private static let previewContext = CIContext(options: [.cacheIntermediates: false])

  private let imageView = UIImageView()
  private let placeholderIcon = UIImageView()
  private let videoBadge = UIView()
  private let videoBadgeLabel = UILabel()

  var mediaTransitionSourceView: UIView {
    imageView.isHidden ? self : imageView
  }

  private var imageLoadTask: URLSessionDataTask?
  private var imageURLString: String?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  deinit {
    imageLoadTask?.cancel()
  }

  private func setup() {
    clipsToBounds = true
    layer.cornerCurve = .continuous
    layer.cornerRadius = 3.0

    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    imageView.isHidden = true
    addSubview(imageView)

    placeholderIcon.contentMode = .scaleAspectFit
    placeholderIcon.image = UIImage(systemName: "photo")
    addSubview(placeholderIcon)

    videoBadge.backgroundColor = UIColor(white: 0.0, alpha: 0.58)
    videoBadge.layer.cornerRadius = 7.0
    videoBadge.layer.cornerCurve = .continuous
    videoBadge.isHidden = true
    addSubview(videoBadge)

    videoBadgeLabel.font = UIFont.systemFont(ofSize: 10, weight: .semibold)
    videoBadgeLabel.text = "VIDEO"
    videoBadgeLabel.textColor = .white
    videoBadgeLabel.textAlignment = .center
    videoBadge.addSubview(videoBadgeLabel)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    imageView.frame = bounds
    placeholderIcon.frame = bounds.insetBy(dx: bounds.width * 0.3, dy: bounds.height * 0.3)

    let badgeHeight: CGFloat = 16.0
    let badgeWidth: CGFloat = 48.0
    videoBadge.frame = CGRect(
      x: max(0.0, bounds.width - badgeWidth - 6.0),
      y: max(0.0, bounds.height - badgeHeight - 6.0),
      width: badgeWidth,
      height: badgeHeight
    )
    videoBadgeLabel.frame = videoBadge.bounds.insetBy(dx: 4.0, dy: 1.0)
  }

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(
        withDuration: isHighlighted ? 0.08 : 0.16, delay: 0.0,
        options: [.curveEaseOut, .allowUserInteraction]
      ) {
        self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.98, y: 0.98) : .identity
        self.alpha = self.isHighlighted ? 0.86 : 1.0
      }
    }
  }

  func configure(
    urlString: String?,
    isVideo: Bool,
    thumbnailBase64: String? = nil,
    mediaKey: String? = nil
  ) {
    videoBadge.isHidden = !isVideo
    // SwiftUI re-runs updateUIView on every diff; without this the preview re-renders each pass.
    if let urlString, !urlString.isEmpty, imageURLString == urlString, imageView.image != nil {
      return
    }
    imageLoadTask?.cancel()
    imageLoadTask = nil
    imageView.image = nil
    imageView.isHidden = true
    placeholderIcon.isHidden = false
    imageURLString = nil

    // Base64 is the blur preview only — it seeds the cell, the full image still loads over it.
    if let thumbnailBase64,
       let data = Data(base64Encoded: thumbnailBase64),
       let image = UIImage(data: data) {
      imageView.image = Self.softenedPreview(image) ?? image
      imageView.isHidden = false
      placeholderIcon.isHidden = true
    }

    guard let urlString, !urlString.isEmpty else { return }
    imageURLString = urlString

    if let cached = Self.imageCache.object(forKey: urlString as NSString) {
      imageView.image = cached
      imageView.isHidden = false
      placeholderIcon.isHidden = true
      return
    }

    guard let url = URL(string: urlString) else { return }

    if isVideo {
      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        do {
          let cgImage = try generator.copyCGImage(at: .zero, actualTime: nil)
          let image = UIImage(cgImage: cgImage)
          Self.imageCache.setObject(image, forKey: urlString as NSString)
          DispatchQueue.main.async {
            guard let self, self.imageURLString == urlString else { return }
            self.imageView.image = image
            self.imageView.isHidden = false
            self.placeholderIcon.isHidden = true
          }
        } catch {
          // ignore
        }
      }
      return
    }

    if url.isFileURL, let image = UIImage(contentsOfFile: url.path) {
      Self.imageCache.setObject(image, forKey: urlString as NSString)
      imageView.image = image
      imageView.isHidden = false
      placeholderIcon.isHidden = true
      return
    }

    let task = VibeHTTP.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let self, let data else { return }
      guard
        let plaintext = ChatEngine.shared.decryptMediaDataIfNeeded(data, mediaKey: mediaKey),
        let image = UIImage(data: plaintext)
      else { return }
      let identity = VibeMediaVault.identity(rawURL: urlString, mediaKey: mediaKey)
      _ = VibeMediaVault.shared.store(plaintext, for: identity, kind: .image)
      Self.imageCache.setObject(image, forKey: urlString as NSString)
      DispatchQueue.main.async {
        guard self.imageURLString == urlString else { return }
        self.imageView.image = image
        self.imageView.isHidden = false
        self.placeholderIcon.isHidden = true
      }
    }
    imageLoadTask = task
    task.resume()
  }

  /// Upscales the tiny preview before applying a real blur so source pixels do not read as blocks.
  private static func softenedPreview(_ image: UIImage) -> UIImage? {
    guard image.size.width > 0, image.size.height > 0 else { return nil }
    let scale = 320 / max(image.size.width, image.size.height)
    let size = CGSize(
      width: max(1, (image.size.width * scale).rounded()),
      height: max(1, (image.size.height * scale).rounded()))
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.opaque = true
    let upscaled = UIGraphicsImageRenderer(size: size, format: format).image { context in
      context.cgContext.interpolationQuality = .high
      image.draw(in: CGRect(origin: .zero, size: size))
    }
    guard let input = CIImage(image: upscaled) else { return upscaled }
    let extent = input.extent
    let blurred = input
      .clampedToExtent()
      .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 10.0])
      .cropped(to: extent)
    guard let output = previewContext.createCGImage(blurred, from: extent) else { return upscaled }
    return UIImage(cgImage: output)
  }

  func applyTheme(placeholderTintColor: UIColor, placeholderBackgroundColor: UIColor) {
    backgroundColor = placeholderBackgroundColor
    placeholderIcon.tintColor = placeholderTintColor
  }
}

struct ChatMainProfileMembersItem: Equatable {
  let userId: String
  let name: String
  let roleLabel: String
  let isAdmin: Bool
}

final class ChatMainProfileMembersNode: UIView, UITableViewDataSource, UITableViewDelegate {
  var onBackTap: (() -> Void)?

  private let headerContainer = UIView()
  private let headerMaskView = UIView()
  private let headerBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
  private let headerOverlayView = UIView()
  private let headerMaskGradientLayer = CAGradientLayer()
  private let headerContentView = UIView()
  private let backButton = UIButton(type: .system)
  private let backGlassView = UIVisualEffectView(effect: nil)
  private let backPressedOverlayView = UIView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()

  private let tableView = UITableView(frame: .zero, style: .insetGrouped)
  private let emptyLabel = UILabel()
  private var members: [ChatMainProfileMembersItem] = []
  private var presented = false
  private var topInset: CGFloat = 0.0
  private var bgColor: UIColor = .systemBackground
  private var textColor: UIColor = .label
  private var secondaryTextColor: UIColor = .secondaryLabel
  private var isDarkTheme = false
  private static let cellId = "profile_member_cell"

  var isPresented: Bool { presented }
  var memberCount: Int { members.count }

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    isHidden = true
    alpha = 0.0
    clipsToBounds = true
    layer.zPosition = 90
    isUserInteractionEnabled = false

    headerContainer.clipsToBounds = false
    headerMaskView.isUserInteractionEnabled = false
    headerContainer.addSubview(headerMaskView)
    headerMaskView.addSubview(headerBlurView)
    headerBlurView.contentView.addSubview(headerOverlayView)
    headerMaskGradientLayer.colors = [
      UIColor.black.withAlphaComponent(0.95).cgColor,
      UIColor.black.withAlphaComponent(0.82).cgColor,
      UIColor.black.withAlphaComponent(0.36).cgColor,
      UIColor.clear.cgColor,
    ]
    headerMaskGradientLayer.locations = [0.0, 0.54, 0.84, 1.0]
    headerMaskView.layer.mask = headerMaskGradientLayer
    headerContainer.addSubview(headerContentView)
    addSubview(headerContainer)

    let symbolConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
    backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
    backButton.setPreferredSymbolConfiguration(symbolConfig, forImageIn: .normal)
    backButton.backgroundColor = .clear
    backButton.contentHorizontalAlignment = .center
    backButton.contentVerticalAlignment = .center
    backButton.clipsToBounds = true
    backButton.addTarget(self, action: #selector(handleBackPressed), for: .touchUpInside)
    backButton.addTarget(
      self, action: #selector(handleBackPressDown), for: [.touchDown, .touchDragEnter])
    backButton.addTarget(
      self,
      action: #selector(handleBackPressUp),
      for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit, .touchDragOutside]
    )
    headerContentView.addSubview(backButton)

    backGlassView.isUserInteractionEnabled = false
    backGlassView.clipsToBounds = true
    backButton.addSubview(backGlassView)
    backButton.sendSubviewToBack(backGlassView)

    backPressedOverlayView.isUserInteractionEnabled = false
    backPressedOverlayView.backgroundColor = UIColor(white: 1.0, alpha: 0.08)
    backPressedOverlayView.alpha = 0.0
    backButton.addSubview(backPressedOverlayView)

    titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    titleLabel.textAlignment = .center
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.text = "Members"
    headerContentView.addSubview(titleLabel)

    subtitleLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
    subtitleLabel.textAlignment = .center
    subtitleLabel.lineBreakMode = .byTruncatingTail
    headerContentView.addSubview(subtitleLabel)

    tableView.dataSource = self
    tableView.delegate = self
    tableView.backgroundColor = .clear
    tableView.separatorStyle = .none
    if #available(iOS 11.0, *) {
      tableView.contentInsetAdjustmentBehavior = .never
    }
    if #available(iOS 15.0, *) {
      tableView.sectionHeaderTopPadding = 0.0
    }
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellId)
    addSubview(tableView)

    emptyLabel.textAlignment = .center
    emptyLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
    emptyLabel.textColor = .secondaryLabel
    emptyLabel.text = "No members available"
    addSubview(emptyLabel)

    // Keep header controls above the list so the back button receives touches.
    bringSubviewToFront(headerContainer)
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    let headerHeight = topInset + 60.0
    headerContainer.frame = CGRect(x: 0.0, y: 0.0, width: bounds.width, height: headerHeight)
    headerMaskView.frame = headerContainer.bounds
    headerBlurView.frame = headerMaskView.bounds
    headerOverlayView.frame = headerBlurView.bounds
    headerMaskGradientLayer.frame = headerMaskView.bounds
    headerContainer.bringSubviewToFront(headerContentView)
    bringSubviewToFront(headerContainer)

    headerContentView.frame = CGRect(
      x: 12.0, y: topInset + 8.0, width: max(0.0, bounds.width - 24.0), height: 44.0)
    backButton.frame = CGRect(x: 0.0, y: 0.0, width: 44.0, height: 44.0)
    backButton.layer.cornerRadius = 22.0
    backGlassView.frame = backButton.bounds
    backGlassView.layer.cornerRadius = 22.0
    backPressedOverlayView.frame = backButton.bounds
    backPressedOverlayView.layer.cornerRadius = 22.0
    if let imageView = backButton.imageView {
      backButton.bringSubviewToFront(imageView)
    }
    backButton.bringSubviewToFront(backPressedOverlayView)

    let centerWidth = max(0.0, headerContentView.bounds.width - 88.0)
    let centerX = (headerContentView.bounds.width - centerWidth) * 0.5
    titleLabel.frame = CGRect(x: centerX + 12.0, y: 2.0, width: centerWidth - 24.0, height: 22.0)
    subtitleLabel.frame = CGRect(
      x: centerX + 12.0, y: titleLabel.frame.maxY - 1.0, width: centerWidth - 24.0, height: 18.0)

    tableView.frame = bounds
    let topPadding = headerHeight + 12.0
    if abs(tableView.contentInset.top - topPadding) > 0.5 {
      tableView.contentInset = UIEdgeInsets(top: topPadding, left: 0.0, bottom: 24.0, right: 0.0)
      tableView.scrollIndicatorInsets = UIEdgeInsets(top: headerHeight, left: 0.0, bottom: 0.0, right: 0.0)
    }
    emptyLabel.frame = CGRect(
      x: 24.0, y: headerHeight + 56.0, width: max(0.0, bounds.width - 48.0), height: 28.0)
  }

  func setMembers(_ nextMembers: [ChatMainProfileMembersItem]) {
    members = nextMembers
    tableView.reloadData()
    emptyLabel.isHidden = !members.isEmpty
    subtitleLabel.text = members.count == 1 ? "1 member" : "\(members.count) members"
  }

  func setTopInset(_ value: CGFloat) {
    let next = max(0.0, value)
    if abs(next - topInset) < 0.5 { return }
    topInset = next
    setNeedsLayout()
  }

  func applyTheme(backgroundColor: UIColor) {
    bgColor = backgroundColor
    var white: CGFloat = 0
    if backgroundColor.getWhite(&white, alpha: nil) {
      isDarkTheme = white < 0.5
    } else {
      isDarkTheme = traitCollection.userInterfaceStyle == .dark
    }
    textColor = isDarkTheme ? .white : .black
    secondaryTextColor = textColor.withAlphaComponent(0.7)

    self.backgroundColor = backgroundColor.withAlphaComponent(0.96)
    tableView.backgroundColor = .clear
    titleLabel.textColor = textColor
    subtitleLabel.textColor = secondaryTextColor
    backButton.tintColor = textColor
    headerBlurView.effect =
      UIBlurEffect(style: isDarkTheme ? .systemThinMaterialDark : .systemThinMaterialLight)
    headerOverlayView.backgroundColor = backgroundColor.withAlphaComponent(isDarkTheme ? 0.42 : 0.72)

    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect()
      effect.isInteractive = true
      backGlassView.effect = effect
    } else {
      backGlassView.effect = UIBlurEffect(style: .systemMaterial)
    }
  }

  private func parentShiftX() -> CGFloat {
    let width = max(1.0, bounds.width)
    return min(max(52.0, width * 0.24), 120.0)
  }

  func syncPresentation(hostScrollView: UIScrollView) {
    let width = max(1.0, bounds.width)
    let hiddenTransform = CGAffineTransform(translationX: width, y: 0.0)
    if presented {
      isHidden = false
      alpha = 1.0
      transform = .identity
      isUserInteractionEnabled = true
      headerContentView.alpha = 1.0
      headerContentView.transform = .identity
      hostScrollView.transform = CGAffineTransform(translationX: -parentShiftX(), y: 0.0)
      hostScrollView.alpha = 0.72
    } else {
      transform = hiddenTransform
      alpha = 0.0
      isHidden = true
      isUserInteractionEnabled = false
      headerContentView.alpha = 0.0
      headerContentView.transform = CGAffineTransform(translationX: 18.0, y: 0.0)
      hostScrollView.transform = .identity
      hostScrollView.alpha = 1.0
    }
  }

  func setPresented(_ nextPresented: Bool, animated: Bool, hostScrollView: UIScrollView) {
    if presented == nextPresented {
      syncPresentation(hostScrollView: hostScrollView)
      return
    }
    presented = nextPresented

    let width = max(1.0, bounds.width)
    let hiddenTransform = CGAffineTransform(translationX: width, y: 0.0)
    let shift = parentShiftX()

    if nextPresented {
      isHidden = false
      alpha = 1.0
      transform = hiddenTransform
      isUserInteractionEnabled = true
      headerContentView.alpha = 0.0
      headerContentView.transform = CGAffineTransform(translationX: 18.0, y: 0.0)
    }

    let apply = {
      hostScrollView.transform =
        nextPresented ? CGAffineTransform(translationX: -shift, y: 0.0) : .identity
      hostScrollView.alpha = nextPresented ? 0.72 : 1.0
      self.transform = nextPresented ? .identity : hiddenTransform
      self.alpha = nextPresented ? 1.0 : 0.0
      self.headerContentView.transform =
        nextPresented ? .identity : CGAffineTransform(translationX: 18.0, y: 0.0)
      self.headerContentView.alpha = nextPresented ? 1.0 : 0.0
    }

    let finalize = {
      if !nextPresented {
        self.isHidden = true
        self.isUserInteractionEnabled = false
      }
    }

    if animated {
      UIView.animate(
        withDuration: 0.28,
        delay: 0.0,
        options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
        animations: apply
      ) { _ in
        finalize()
      }
    } else {
      apply()
      finalize()
    }
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    members.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellId, for: indexPath)
    let item = members[indexPath.row]
    var content = UIListContentConfiguration.subtitleCell()
    content.text = item.name
    content.secondaryText =
      item.isAdmin ? "\(item.roleLabel) • \(item.userId.prefix(8))" : item.roleLabel
    content.textProperties.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    content.secondaryTextProperties.font = UIFont.systemFont(ofSize: 13, weight: .medium)
    content.secondaryTextProperties.color = .secondaryLabel
    content.image = UIImage(systemName: item.isAdmin ? "star.circle.fill" : "person.circle")
    content.imageProperties.tintColor = item.isAdmin ? .systemYellow : .secondaryLabel
    content.imageToTextPadding = 12
    cell.contentConfiguration = content
    cell.backgroundColor = .clear
    var bg = UIBackgroundConfiguration.listGroupedCell()
    bg.backgroundColor = UIColor.secondarySystemGroupedBackground.withAlphaComponent(0.55)
    bg.cornerRadius = 14
    cell.backgroundConfiguration = bg
    cell.selectionStyle = .none
    return cell
  }

  func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    62.0
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
  }

  @objc private func handleBackPressed() {
    onBackTap?()
  }

  @objc private func handleBackPressDown() {
    UIView.animate(
      withDuration: 0.1, delay: 0.0, options: [.curveEaseOut, .allowUserInteraction]
    ) {
      self.backButton.imageView?.transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
      self.backPressedOverlayView.alpha = 1.0
      self.backGlassView.alpha = 0.92
    }
  }

  @objc private func handleBackPressUp() {
    UIView.animate(
      withDuration: 0.22,
      delay: 0.0,
      usingSpringWithDamping: 0.72,
      initialSpringVelocity: 0.25,
      options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      self.backButton.imageView?.transform = .identity
      self.backPressedOverlayView.alpha = 0.0
      self.backGlassView.alpha = 1.0
    }
  }
}

// MARK: - Agent Prompt Control Node

protocol ChatMainProfileAgentPromptNodeDelegate: AnyObject {
  func agentPromptNode(
    _ node: ChatMainProfileAgentPromptNode, didUpdateConfig config: [String: Any])
  func agentPromptNodeDidRequestDelete(_ node: ChatMainProfileAgentPromptNode)
  func agentPromptNodeDidRequestFullEditor(_ node: ChatMainProfileAgentPromptNode)
}

final class ChatMainProfileAgentPromptNode: UIView {

  weak var delegate: ChatMainProfileAgentPromptNodeDelegate?

  private let headerBar = UIView()
  private let headerIcon = UIImageView()
  private let headerTitleLabel = UILabel()
  private let headerSubtitleLabel = UILabel()
  private let headerToggle = UISwitch()

  private let promptPreviewCard = UIView()
  private let promptPreviewTitleLabel = UILabel()
  private let promptPreviewLabel = UILabel()
  
  private let documentsTitleLabel = UILabel()
  private let documentsContainer = UIStackView()

  private let editButton = UIButton(type: .system)
  private let deleteButton = UIButton(type: .system)

  private var chatId: String = ""
  private var currentConfig: [String: Any] = [:]
  private var hasPersistedConfig = false
  private var currentDocuments: [(id: String, name: String)] = []

  private let defaultAccent = UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0)
  private var textColor: UIColor = .white
  private var secondaryTextColor: UIColor = UIColor(white: 1.0, alpha: 0.58)
  private var surfaceColor: UIColor = UIColor(white: 1.0, alpha: 0.06)
  private var fieldBgColor: UIColor = UIColor(white: 1.0, alpha: 0.04)
  private var accentColor: UIColor = UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0)

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    clipsToBounds = true
    layer.cornerCurve = .continuous
    layer.cornerRadius = 22.0

    headerBar.clipsToBounds = true
    addSubview(headerBar)

    let iconConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
    headerIcon.image = UIImage(systemName: "sparkles", withConfiguration: iconConfig)
    headerIcon.contentMode = .scaleAspectFit
    headerIcon.tintColor = defaultAccent
    headerBar.addSubview(headerIcon)

    headerTitleLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    headerTitleLabel.text = "✦ AI Agent"
    headerBar.addSubview(headerTitleLabel)

    headerSubtitleLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
    headerSubtitleLabel.text = "Single model backend"
    headerBar.addSubview(headerSubtitleLabel)

    headerToggle.transform = CGAffineTransform(scaleX: 0.82, y: 0.82)
    headerToggle.onTintColor = defaultAccent
    headerToggle.addTarget(self, action: #selector(handleToggleChanged), for: .valueChanged)
    headerBar.addSubview(headerToggle)

    promptPreviewCard.layer.cornerRadius = 14.0
    promptPreviewCard.layer.cornerCurve = .continuous
    promptPreviewCard.clipsToBounds = true
    addSubview(promptPreviewCard)

    promptPreviewTitleLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
    promptPreviewTitleLabel.text = "PROMPT PREVIEW"
    promptPreviewCard.addSubview(promptPreviewTitleLabel)

    promptPreviewLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
    promptPreviewLabel.numberOfLines = 4
    promptPreviewCard.addSubview(promptPreviewLabel)
    
    documentsTitleLabel.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
    documentsTitleLabel.text = "AGENT DOCUMENTS"
    addSubview(documentsTitleLabel)
    
    documentsContainer.axis = .vertical
    documentsContainer.spacing = 8.0
    documentsContainer.distribution = .equalSpacing
    addSubview(documentsContainer)

    let editIconConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    editButton.setImage(UIImage(systemName: "pencil", withConfiguration: editIconConfig), for: .normal)
    editButton.layer.cornerRadius = 16.0
    editButton.layer.cornerCurve = .continuous
    editButton.clipsToBounds = true
    editButton.addTarget(self, action: #selector(handleEditTapped), for: .touchUpInside)
    addSubview(editButton)

    let deleteIconConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    deleteButton.setImage(UIImage(systemName: "trash", withConfiguration: deleteIconConfig), for: .normal)
    deleteButton.layer.cornerRadius = 16.0
    deleteButton.layer.cornerCurve = .continuous
    deleteButton.layer.borderWidth = 1.0 / UIScreen.main.scale
    deleteButton.clipsToBounds = true
    deleteButton.addTarget(self, action: #selector(handleDeleteTapped), for: .touchUpInside)
    addSubview(deleteButton)

    applyTheme(
      textColor: textColor,
      secondaryTextColor: secondaryTextColor,
      surfaceColor: surfaceColor,
      accentColor: accentColor
    )
    refreshViewState()
  }

  func configure(chatId: String, config: [String: Any]?, documents: [(id: String, name: String)]) {
    self.chatId = chatId
    hasPersistedConfig = config != nil
    
    var uniqueDocs = [(id: String, name: String)]()
    var seenNames = Set<String>()
    for doc in documents {
      if !seenNames.contains(doc.name) {
        seenNames.insert(doc.name)
        uniqueDocs.append(doc)
      }
    }
    self.currentDocuments = uniqueDocs

    if let config {
      var nextConfig: [String: Any] = [:]
      nextConfig["chat_id"] = chatId
      nextConfig["name"] = normalizedName(from: config)
      nextConfig["system_prompt"] = normalizedPrompt(from: config)
      nextConfig["enabled"] = normalizedEnabled(from: config, defaultValue: true)
      if let existingId = config["id"] {
        nextConfig["id"] = existingId
      }
      currentConfig = nextConfig
    } else {
      currentConfig = [
        "chat_id": chatId,
        "name": "Vibe AI",
        "system_prompt": "",
        "enabled": false,
      ]
    }

    rebuildDocumentsUI()
    refreshViewState()
    setNeedsLayout()
  }
  
  private func rebuildDocumentsUI() {
    documentsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
    for doc in currentDocuments {
      let row = UIView()
      row.layer.cornerRadius = 10.0
      row.layer.cornerCurve = .continuous
      row.backgroundColor = fieldBgColor
      row.translatesAutoresizingMaskIntoConstraints = false
      row.heightAnchor.constraint(equalToConstant: 40).isActive = true
      
      let icon = UIImageView(image: UIImage(systemName: "doc.text.fill"))
      icon.tintColor = secondaryTextColor
      icon.contentMode = .scaleAspectFit
      icon.translatesAutoresizingMaskIntoConstraints = false
      row.addSubview(icon)
      
      let label = UILabel()
      label.text = doc.name
      label.font = UIFont.systemFont(ofSize: 13, weight: .medium)
      label.textColor = textColor
      label.translatesAutoresizingMaskIntoConstraints = false
      row.addSubview(label)
      
      NSLayoutConstraint.activate([
        icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
        icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        icon.widthAnchor.constraint(equalToConstant: 16),
        icon.heightAnchor.constraint(equalToConstant: 16),
        
        label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
        label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
        label.centerYAnchor.constraint(equalTo: row.centerYAnchor)
      ])
      
      documentsContainer.addArrangedSubview(row)
    }
  }

  func applyTheme(
    textColor: UIColor,
    secondaryTextColor: UIColor,
    surfaceColor: UIColor,
    accentColor: UIColor
  ) {
    self.textColor = textColor
    self.secondaryTextColor = secondaryTextColor
    self.surfaceColor = surfaceColor
    self.accentColor = accentColor
    self.fieldBgColor = surfaceColor.withAlphaComponent(0.58)

    backgroundColor = surfaceColor
    headerTitleLabel.textColor = textColor
    headerSubtitleLabel.textColor = secondaryTextColor
    headerIcon.tintColor = accentColor
    headerToggle.onTintColor = accentColor

    promptPreviewCard.backgroundColor = fieldBgColor
    promptPreviewTitleLabel.textColor = secondaryTextColor
    promptPreviewLabel.textColor = textColor
    
    documentsTitleLabel.textColor = secondaryTextColor
    
    for subview in documentsContainer.arrangedSubviews {
      subview.backgroundColor = fieldBgColor
      if let label = subview.subviews.compactMap({ $0 as? UILabel }).first {
        label.textColor = textColor
      }
      if let icon = subview.subviews.compactMap({ $0 as? UIImageView }).first {
        icon.tintColor = secondaryTextColor
      }
    }

    editButton.backgroundColor = accentColor
    editButton.tintColor = .white

    deleteButton.backgroundColor = fieldBgColor
    deleteButton.tintColor = .systemRed
    deleteButton.layer.borderColor = secondaryTextColor.withAlphaComponent(0.35).cgColor
  }

  func preferredHeight(for width: CGFloat) -> CGFloat {
    let headerHeight: CGFloat = 58.0
    let pad: CGFloat = 16.0
    var total = headerHeight + 5.0

    if shouldShowPromptPreview {
      total += promptCardHeight(for: width) + 12.0
    }
    
    if !currentDocuments.isEmpty {
      total += 14.0 + 8.0 // Title
      total += CGFloat(currentDocuments.count) * 40.0 + CGFloat(max(0, currentDocuments.count - 1)) * 8.0
      total += 12.0
    }

    return total + pad
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let width = bounds.width
    let pad: CGFloat = 16.0
    let headerHeight: CGFloat = 58.0

    headerBar.frame = CGRect(x: 0.0, y: 0.0, width: width, height: headerHeight)
    headerIcon.frame = CGRect(x: pad, y: 12.0, width: 20.0, height: 20.0)
    
    let actionsWidth: CGFloat = 80.0
    headerTitleLabel.frame = CGRect(x: pad + 28.0, y: 8.0, width: width - 120.0 - actionsWidth, height: 22.0)
    headerSubtitleLabel.frame = CGRect(
      x: pad + 28.0, y: headerTitleLabel.frame.maxY - 1.0, width: width - 120.0 - actionsWidth, height: 18.0)

    let toggleSize = headerToggle.intrinsicContentSize
    let scaledToggleWidth = toggleSize.width * 0.82
    let scaledToggleHeight = toggleSize.height * 0.82
    headerToggle.frame = CGRect(
      x: width - pad - scaledToggleWidth,
      y: (headerHeight - scaledToggleHeight) * 0.5,
      width: toggleSize.width,
      height: toggleSize.height
    )
    
    let btnSize: CGFloat = 32.0
    editButton.frame = CGRect(
      x: headerToggle.frame.minX - btnSize - 12.0,
      y: (headerHeight - btnSize) * 0.5,
      width: btnSize,
      height: btnSize
    )
    deleteButton.frame = CGRect(
      x: editButton.frame.minX - btnSize - 8.0,
      y: (headerHeight - btnSize) * 0.5,
      width: btnSize,
      height: btnSize
    )

    var y = headerBar.frame.maxY + 5.0
    if shouldShowPromptPreview {
      let promptCardHeight = promptCardHeight(for: width)
      promptPreviewCard.frame = CGRect(
        x: pad,
        y: y,
        width: width - (pad * 2.0),
        height: promptCardHeight
      )
      promptPreviewTitleLabel.frame = CGRect(
        x: 12.0, y: 10.0, width: promptPreviewCard.bounds.width - 24.0, height: 14.0)
      promptPreviewLabel.frame = CGRect(
        x: 12.0, y: 28.0, width: promptPreviewCard.bounds.width - 24.0,
        height: promptCardHeight - 40.0)
      y = promptPreviewCard.frame.maxY + 12.0
    } else {
      promptPreviewCard.frame = .zero
      promptPreviewTitleLabel.frame = .zero
      promptPreviewLabel.frame = .zero
    }

    if !currentDocuments.isEmpty {
      documentsTitleLabel.isHidden = false
      documentsContainer.isHidden = false
      documentsTitleLabel.frame = CGRect(x: pad + 2.0, y: y, width: width - (pad * 2.0), height: 14.0)
      y += 14.0 + 8.0
      
      let docsHeight = CGFloat(currentDocuments.count) * 40.0 + CGFloat(max(0, currentDocuments.count - 1)) * 8.0
      documentsContainer.frame = CGRect(x: pad, y: y, width: width - (pad * 2.0), height: docsHeight)
      y += docsHeight + 12.0
    } else {
      documentsTitleLabel.isHidden = true
      documentsContainer.isHidden = true
    }
  }

  @objc private func handleToggleChanged() {
    let prompt = normalizedPrompt(from: currentConfig)
    if headerToggle.isOn && prompt.isEmpty {
      headerToggle.setOn(false, animated: true)
      delegate?.agentPromptNodeDidRequestFullEditor(self)
      return
    }
    emitConfigUpdate(enabled: headerToggle.isOn)
  }

  @objc private func handleEditTapped() {
    delegate?.agentPromptNodeDidRequestFullEditor(self)
  }

  @objc private func handleDeleteTapped() {
    delegate?.agentPromptNodeDidRequestDelete(self)
  }

  private var shouldShowPromptPreview: Bool {
    guard normalizedEnabled(from: currentConfig, defaultValue: false) else { return false }
    return !normalizedPrompt(from: currentConfig).isEmpty
  }

  private func refreshViewState() {
    let name = normalizedName(from: currentConfig)
    let prompt = normalizedPrompt(from: currentConfig)
    let isEnabled = normalizedEnabled(from: currentConfig, defaultValue: false)

    headerToggle.isOn = isEnabled
    headerTitleLabel.text = "✦ \(name)"
    headerSubtitleLabel.text = isEnabled ? "Single model backend" : "Agent is paused"

    promptPreviewLabel.text = prompt
    promptPreviewCard.isHidden = !shouldShowPromptPreview
    deleteButton.isHidden = !hasPersistedConfig
    setNeedsLayout()
  }

  private func normalizedName(from config: [String: Any]) -> String {
    let raw = (config["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return raw.isEmpty ? "Vibe AI" : raw
  }

  private func normalizedPrompt(from config: [String: Any]) -> String {
    let snake =
      (config["system_prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !snake.isEmpty { return snake }
    return
      (config["systemPrompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private func normalizedEnabled(from config: [String: Any], defaultValue: Bool) -> Bool {
    guard let raw = config["enabled"] else { return defaultValue }
    if let bool = raw as? Bool { return bool }
    if let number = raw as? NSNumber { return number.boolValue }
    if let string = raw as? String {
      switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "true", "1", "yes", "on":
        return true
      case "false", "0", "no", "off":
        return false
      default:
        break
      }
    }
    return defaultValue
  }

  private func promptCardHeight(for width: CGFloat) -> CGFloat {
    let availableWidth = max(10.0, width - 56.0)
    let promptText = normalizedPrompt(from: currentConfig)
    let bounding = (promptText as NSString).boundingRect(
      with: CGSize(width: availableWidth, height: 140.0),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: UIFont.systemFont(ofSize: 14.0, weight: .regular)],
      context: nil
    )
    let textHeight = min(96.0, ceil(bounding.height))
    return max(68.0, 28.0 + textHeight + 12.0)
  }

  private func emitConfigUpdate(enabled: Bool) {
    var config = currentConfig
    config["chat_id"] = chatId
    config["name"] = normalizedName(from: config)
    config["system_prompt"] = normalizedPrompt(from: config)
    config["enabled"] = enabled
    currentConfig = config
    refreshViewState()
    delegate?.agentPromptNode(self, didUpdateConfig: config)
  }
}
