import Combine
import PhotosUI
import UIKit

// MARK: - Keep policy / send options

enum ChatMediaKeepPolicy: Equatable {
  case persist
  case viewOnce
  case seconds(Int)

  var title: String {
    switch self {
    case .persist: return "Do Not Delete"
    case .viewOnce: return "View Once"
    case .seconds(let s): return "\(s) Seconds"
    }
  }

  var viewOnce: Bool {
    switch self {
    case .persist: return false
    default: return true
    }
  }

  var mediaTtlSeconds: Int? {
    switch self {
    case .persist: return nil
    case .viewOnce: return 0
    case .seconds(let s): return s
    }
  }

  static let secondChoices = [5, 10, 15, 20, 25, 30]
}

struct ChatAttachmentSendOptions {
  var viewOnce: Bool = false
  var mediaTtlSeconds: Int? = nil
  var isHighQuality: Bool = false

  static func from(_ policy: ChatMediaKeepPolicy, highQuality: Bool) -> ChatAttachmentSendOptions {
    ChatAttachmentSendOptions(
      viewOnce: policy.viewOnce,
      mediaTtlSeconds: policy.mediaTtlSeconds,
      isHighQuality: highQuality)
  }
}

enum ChatAttachSendContext {
  static var pending: ChatAttachmentSendOptions?

  static func take() -> ChatAttachmentSendOptions? {
    let value = pending
    pending = nil
    return value
  }
}

// MARK: - Composer model

@MainActor
final class ChatAttachComposerModel: ObservableObject {
  @Published var recipientName: String
  @Published var pickCount: Int
  @Published var pageIndex: Int
  @Published var caption: String
  @Published var keepPolicy: ChatMediaKeepPolicy = .persist
  @Published var isHighQuality: Bool = false
  @Published var showAdjustments: Bool = false
  @Published var brightness: Double = 0
  @Published var contrast: Double = 0
  @Published var saturation: Double = 0
  @Published var isCropping: Bool = false

  var hasAdjustments: Bool {
    abs(brightness) > 0.004 || abs(contrast) > 0.004 || abs(saturation) > 0.004
  }

  init(recipientName: String, pickCount: Int, pageIndex: Int, caption: String) {
    self.recipientName = recipientName
    self.pickCount = pickCount
    self.pageIndex = pageIndex
    self.caption = caption
  }

  func resetAdjustments() {
    brightness = 0
    contrast = 0
    saturation = 0
  }
}

// MARK: - Chrome

@MainActor
final class ChatAttachComposerChromeHost: UIView, UITextFieldDelegate {
  let model: ChatAttachComposerModel
  private let sendColor: UIColor

  private let nameButton = UIButton(type: .system)
  private let pickButton = UIButton(type: .custom)
  private let pickCountLabel = UILabel()
  private let captionGlass = makeChatContextLiquidGlassView(
    style: .systemThinMaterialDark, cornerRadius: 22, capsuleCorners: true, interactive: true)
  private let captionField = UITextField()
  private let timerButton = UIButton(type: .system)
  private let backButton = UIButton(type: .system)
  private let sendButton = UIButton(type: .system)
  private let toolsGlass = makeChatContextLiquidGlassView(
    style: .systemThinMaterialDark, cornerRadius: 22, capsuleCorners: true, interactive: true)
  private let cropButton = UIButton(type: .system)
  private let drawButton = UIButton(type: .system)
  private let adjustButton = UIButton(type: .system)
  private let hdButton = UIButton(type: .system)
  private let adjustPanel = UIView()
  private let brightSlider = UISlider()
  private let contrastSlider = UISlider()
  private let satSlider = UISlider()
  private let keepDimmer = UIControl()
  private var keepMenu: ChatAttachKeepMenuView?

  var onClose: (() -> Void)?
  var onPick: (() -> Void)?
  var onCrop: (() -> Void)?
  var onDraw: (() -> Void)?
  var onToggleAdjust: (() -> Void)?
  var onToggleHD: (() -> Void)?
  var onSend: (() -> Void)?

  init(model: ChatAttachComposerModel, sendColor: UIColor) {
    self.model = model
    self.sendColor = sendColor
    super.init(frame: .zero)
    backgroundColor = .clear
    isOpaque = false
    isUserInteractionEnabled = true

    configureHeader()
    configureCaption()
    configureToolbar()
    configureAdjustPanel()

    keepDimmer.backgroundColor = UIColor.black.withAlphaComponent(0.22)
    keepDimmer.addTarget(self, action: #selector(dismissKeepMenu), for: .touchUpInside)
    keepDimmer.isHidden = true
    addSubview(keepDimmer)
    reloadChrome()
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    let safeTop: CGFloat = 4
    let safeBottom = safeAreaInsets.bottom
    nameButton.frame = CGRect(x: 12, y: safeTop, width: min(220, bounds.width * 0.62), height: 44)
    pickButton.frame = CGRect(x: bounds.width - 12 - 32, y: safeTop + 6, width: 32, height: 32)
    pickCountLabel.frame = pickButton.bounds

    let toolbarH: CGFloat = 40
    let capH: CGFloat = 44
    let gap: CGFloat = 10
    let bottomY = bounds.height - safeBottom - 8
    let toolsW: CGFloat = 176
    let sendS: CGFloat = 36
    let backS: CGFloat = 40
    sendButton.frame = CGRect(x: bounds.width - 12 - sendS, y: bottomY - sendS, width: sendS, height: sendS)
    sendButton.layer.cornerRadius = sendS * 0.5
    backButton.frame = CGRect(x: 12, y: bottomY - backS, width: backS, height: backS)
    toolsGlass.frame = CGRect(
      x: (bounds.width - toolsW) * 0.5, y: bottomY - 40, width: toolsW, height: 40)
    let toolW: CGFloat = 44
    cropButton.frame = CGRect(x: 0, y: 0, width: toolW, height: 40)
    drawButton.frame = CGRect(x: toolW, y: 0, width: toolW, height: 40)
    adjustButton.frame = CGRect(x: toolW * 2, y: 0, width: toolW, height: 40)
    hdButton.frame = CGRect(x: toolW * 3, y: 0, width: toolW, height: 40)

    let capY = toolsGlass.frame.minY - gap - capH
    captionGlass.frame = CGRect(x: 16, y: capY, width: max(1, bounds.width - 32), height: capH)
    timerButton.frame = CGRect(x: captionGlass.bounds.width - 40, y: 4, width: 36, height: 36)
    captionField.frame = CGRect(x: 16, y: 0, width: max(1, timerButton.frame.minX - 20), height: capH)

    let adjH: CGFloat = 118
    adjustPanel.frame = CGRect(
      x: 16, y: captionGlass.frame.minY - 10 - adjH, width: max(1, bounds.width - 32), height: adjH)
    let sw = adjustPanel.bounds.width - 24
    brightSlider.frame = CGRect(x: 12, y: 16, width: sw, height: 28)
    contrastSlider.frame = CGRect(x: 12, y: 48, width: sw, height: 28)
    satSlider.frame = CGRect(x: 12, y: 80, width: sw, height: 28)

    keepDimmer.frame = bounds
    if let keepMenu {
      keepMenu.frame = keepMenuFrame()
      bringSubviewToFront(keepDimmer)
      bringSubviewToFront(keepMenu)
    }
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let hit = super.hitTest(point, with: event)
    return hit === self ? nil : hit
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    textField.resignFirstResponder()
    return true
  }

  private func configureHeader() {
    nameButton.contentHorizontalAlignment = .leading
    nameButton.addTarget(self, action: #selector(tapClose), for: .touchUpInside)
    addSubview(nameButton)

    pickButton.addTarget(self, action: #selector(tapPick), for: .touchUpInside)
    pickCountLabel.font = .systemFont(ofSize: 15, weight: .bold)
    pickCountLabel.textColor = .white
    pickCountLabel.textAlignment = .center
    pickCountLabel.isUserInteractionEnabled = false
    pickButton.addSubview(pickCountLabel)
    addSubview(pickButton)
  }

  private func configureCaption() {
    captionField.font = .systemFont(ofSize: 16)
    captionField.textColor = .white
    captionField.tintColor = .white
    captionField.attributedPlaceholder = NSAttributedString(
      string: "Add a caption…",
      attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.45)])
    captionField.returnKeyType = .done
    captionField.delegate = self
    captionField.addTarget(self, action: #selector(captionChanged), for: .editingChanged)
    captionGlass.contentView.addSubview(captionField)
    timerButton.addTarget(self, action: #selector(toggleKeepMenu), for: .touchUpInside)
    captionGlass.contentView.addSubview(timerButton)
    addSubview(captionGlass)
  }

  private func configureToolbar() {
    styleGlassCircle(backButton, symbol: "chevron.backward", size: 17)
    backButton.addTarget(self, action: #selector(tapClose), for: .touchUpInside)
    addSubview(backButton)

    cropButton.addTarget(self, action: #selector(tapCrop), for: .touchUpInside)
    drawButton.addTarget(self, action: #selector(tapDraw), for: .touchUpInside)
    adjustButton.addTarget(self, action: #selector(tapAdjust), for: .touchUpInside)
    hdButton.addTarget(self, action: #selector(tapHD), for: .touchUpInside)
    toolsGlass.contentView.addSubview(cropButton)
    toolsGlass.contentView.addSubview(drawButton)
    toolsGlass.contentView.addSubview(adjustButton)
    toolsGlass.contentView.addSubview(hdButton)
    addSubview(toolsGlass)

    sendButton.backgroundColor = sendColor
    sendButton.clipsToBounds = true
    sendButton.addTarget(self, action: #selector(tapSend), for: .touchUpInside)
    addSubview(sendButton)
  }

  private func configureAdjustPanel() {
    adjustPanel.backgroundColor = UIColor.black.withAlphaComponent(0.42)
    adjustPanel.layer.cornerRadius = 16
    adjustPanel.layer.cornerCurve = .continuous
    adjustPanel.isHidden = true
    for slider in [brightSlider, contrastSlider, satSlider] {
      slider.minimumValue = -0.7
      slider.maximumValue = 0.7
      slider.value = 0
      slider.minimumTrackTintColor = .white
      slider.addTarget(self, action: #selector(adjustChanged), for: .valueChanged)
      adjustPanel.addSubview(slider)
    }
    addSubview(adjustPanel)
  }

  private func styleGlassCircle(_ button: UIButton, symbol: String, size: CGFloat) {
    var config = UIButton.Configuration.plain()
    config.image = UIImage(
      systemName: symbol,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold))
    config.baseForegroundColor = .white
    button.configuration = config
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect()
      glass.isInteractive = true
      let wrap = UIVisualEffectView(effect: glass)
      wrap.cornerConfiguration = .capsule()
      wrap.isUserInteractionEnabled = false
      button.backgroundColor = .clear
      button.insertSubview(wrap, at: 0)
      wrap.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
      wrap.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    } else {
      button.backgroundColor = UIColor.white.withAlphaComponent(0.16)
      button.layer.cornerRadius = 20
    }
  }

  private func toolGlyph(_ button: UIButton, symbol: String?, title: String?, selected: Bool) {
    var config = UIButton.Configuration.plain()
    if let symbol {
      config.image = UIImage(
        systemName: symbol,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
    }
    if let title {
      var attrs = AttributeContainer()
      attrs.font = .systemFont(ofSize: 13, weight: .bold)
      attrs.foregroundColor = UIColor.white
      config.attributedTitle = AttributedString(title, attributes: attrs)
    }
    config.baseForegroundColor = .white
    button.configuration = config
    button.backgroundColor = selected ? UIColor.white.withAlphaComponent(0.18) : .clear
    button.layer.cornerRadius = 12
  }

  func reloadChrome() {
    let name = model.recipientName.isEmpty ? "Send" : model.recipientName
    var nameConfig = UIButton.Configuration.plain()
    nameConfig.image = UIImage(
      systemName: "arrow.up",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
    nameConfig.title = name
    nameConfig.imagePadding = 5
    nameConfig.baseForegroundColor = .white
    nameConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var out = incoming
      out.font = .systemFont(ofSize: 16, weight: .semibold)
      return out
    }
    nameButton.configuration = nameConfig

    let counted = model.pickCount > 0
    pickButton.backgroundColor = counted
      ? UIColor(red: 0.32, green: 0.82, blue: 0.47, alpha: 1)
      : .clear
    pickButton.layer.cornerRadius = 16
    pickButton.layer.borderWidth = counted ? 0 : 1.6
    pickButton.layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor
    pickCountLabel.text = counted ? "\(model.pickCount)" : nil

    toolGlyph(cropButton, symbol: "crop", title: nil, selected: model.isCropping)
    toolGlyph(drawButton, symbol: "pencil.tip", title: nil, selected: false)
    toolGlyph(adjustButton, symbol: "slider.horizontal.3", title: nil, selected: model.showAdjustments)
    toolGlyph(hdButton, symbol: nil, title: model.isHighQuality ? "HD" : "SD", selected: model.isHighQuality)

    var sendConfig = UIButton.Configuration.plain()
    sendConfig.image = UIImage(
      systemName: "paperplane.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
    sendConfig.baseForegroundColor = .white
    sendButton.configuration = sendConfig

    refreshTimerButton()
    adjustPanel.isHidden = !model.showAdjustments
    if !captionField.isFirstResponder {
      captionField.text = model.caption
    }
  }

  @objc private func tapClose() { onClose?() }
  @objc private func tapPick() { onPick?() }
  @objc private func tapCrop() { onCrop?(); reloadChrome() }
  @objc private func tapDraw() { onDraw?() }
  @objc private func tapAdjust() { onToggleAdjust?(); reloadChrome() }
  @objc private func tapHD() { onToggleHD?(); reloadChrome() }
  @objc private func tapSend() { onSend?() }

  @objc private func captionChanged() {
    model.caption = captionField.text ?? ""
  }

  @objc private func adjustChanged() {
    model.brightness = Double(brightSlider.value)
    model.contrast = Double(contrastSlider.value)
    model.saturation = Double(satSlider.value)
  }

  @objc private func toggleKeepMenu() {
    if keepMenu == nil { presentKeepMenu() } else { dismissKeepMenu() }
  }

  private func presentKeepMenu() {
    keepDimmer.isHidden = false
    let menu = ChatAttachKeepMenuView(policy: model.keepPolicy)
    menu.onSelect = { [weak self] policy in
      guard let self else { return }
      self.model.keepPolicy = policy
      self.refreshTimerButton()
    }
    menu.onCommit = { [weak self] in self?.dismissKeepMenu() }
    addSubview(menu)
    keepMenu = menu
    menu.frame = keepMenuFrame()
    menu.layer.anchorPoint = CGPoint(x: 1, y: 1)
    menu.frame = keepMenuFrame()
    menu.transform = CGAffineTransform(scaleX: 0.001, y: 0.001)
    menu.alpha = 0
    UIView.animate(
      withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.4
    ) {
      menu.transform = .identity
      menu.alpha = 1
    }
    bringSubviewToFront(keepDimmer)
    bringSubviewToFront(menu)
  }

  @objc private func dismissKeepMenu() {
    guard let menu = keepMenu else {
      keepDimmer.isHidden = true
      return
    }
    UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseIn]) {
      menu.transform = CGAffineTransform(scaleX: 0.001, y: 0.001)
      menu.alpha = 0
    } completion: { _ in
      menu.removeFromSuperview()
    }
    keepMenu = nil
    keepDimmer.isHidden = true
  }

  private func keepMenuFrame() -> CGRect {
    let size = ChatAttachKeepMenuView.preferredSize
    let timer = timerButton.convert(timerButton.bounds, to: self)
    var origin = CGPoint(x: timer.maxX - size.width, y: timer.minY - 10 - size.height)
    origin.x = min(max(12, origin.x), bounds.width - size.width - 12)
    origin.y = min(max(12, origin.y), max(12, timer.minY - size.height - 8))
    return CGRect(origin: origin, size: size)
  }

  private func refreshTimerButton() {
    let title: String
    let symbol: String
    switch model.keepPolicy {
    case .persist:
      title = ""
      symbol = "timer"
    case .viewOnce:
      title = "1"
      symbol = ""
    case .seconds(let s):
      title = "\(s)"
      symbol = ""
    }
    var config = UIButton.Configuration.plain()
    if title.isEmpty {
      config.image = UIImage(
        systemName: symbol,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
    } else {
      var attrs = AttributeContainer()
      attrs.font = .systemFont(ofSize: 13, weight: .bold)
      attrs.foregroundColor = UIColor.white
      config.attributedTitle = AttributedString(title, attributes: attrs)
    }
    config.baseForegroundColor = .white
    config.contentInsets = .zero
    timerButton.configuration = config
    timerButton.backgroundColor = model.keepPolicy == .persist
      ? .clear : UIColor.white.withAlphaComponent(0.16)
    timerButton.layer.cornerRadius = 18
  }
}


final class ChatAttachKeepMenuView: UIView {
  static let preferredSize = CGSize(width: 268, height: 372)

  var onSelect: ((ChatMediaKeepPolicy) -> Void)?
  var onCommit: (() -> Void)?

  private let glass = makeChatContextLiquidGlassView(
    style: .systemMaterialDark, cornerRadius: 22, interactive: true)
  private let titleLabel = UILabel()
  private var rowButtons: [UIButton] = []
  private var policy: ChatMediaKeepPolicy
  private let options: [ChatMediaKeepPolicy] =
    [.viewOnce] + ChatMediaKeepPolicy.secondChoices.map { .seconds($0) } + [.persist]

  init(policy: ChatMediaKeepPolicy) {
    self.policy = policy
    super.init(frame: .zero)
    glass.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glass)
    NSLayoutConstraint.activate([
      glass.topAnchor.constraint(equalTo: topAnchor),
      glass.bottomAnchor.constraint(equalTo: bottomAnchor),
      glass.leadingAnchor.constraint(equalTo: leadingAnchor),
      glass.trailingAnchor.constraint(equalTo: trailingAnchor),
    ])

    titleLabel.text = "Choose how long the media will be kept after opening."
    titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    titleLabel.textColor = .white
    titleLabel.numberOfLines = 2
    titleLabel.textAlignment = .center

    var rows: [UIView] = [titleLabel]
    for (index, option) in options.enumerated() {
      let button = UIButton(type: .system)
      button.tag = index
      button.addTarget(self, action: #selector(tapOption(_:)), for: .touchUpInside)
      rowButtons.append(button)
      rows.append(button)
    }

    let stack = UIStackView(arrangedSubviews: rows)
    stack.axis = .vertical
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    glass.contentView.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 12),
      stack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 6),
      stack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -6),
      stack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -8),
      titleLabel.heightAnchor.constraint(equalToConstant: 40),
    ])
    for button in rowButtons {
      button.heightAnchor.constraint(equalToConstant: 40).isActive = true
    }
    refreshChecks()
  }

  required init?(coder: NSCoder) { nil }

  @objc private func tapOption(_ sender: UIButton) {
    let index = sender.tag
    guard options.indices.contains(index) else { return }
    policy = options[index]
    refreshChecks()
    onSelect?(policy)
    onCommit?()
  }

  private func refreshChecks() {
    for (index, button) in rowButtons.enumerated() {
      applyCheck(button, title: options[index].title, selected: options[index] == policy)
    }
  }

  private func applyCheck(_ button: UIButton, title: String, selected: Bool) {
    var config = UIButton.Configuration.plain()
    config.title = title
    config.baseForegroundColor = .white
    config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
      var out = incoming
      out.font = .systemFont(ofSize: 17, weight: selected ? .semibold : .regular)
      return out
    }
    config.image = selected
      ? UIImage(
        systemName: "checkmark",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
      : nil
    config.imagePlacement = .leading
    config.imagePadding = 8
    config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)
    button.configuration = config
    button.contentHorizontalAlignment = .leading
  }
}

final class ChatAttachCropOverlay: UIView {
  var cropRectInView: CGRect = .zero
  private let shade = CAShapeLayer()
  private let border = CAShapeLayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    shade.fillRule = .evenOdd
    shade.fillColor = UIColor.black.withAlphaComponent(0.45).cgColor
    border.strokeColor = UIColor.white.cgColor
    border.fillColor = UIColor.clear.cgColor
    border.lineWidth = 1.2
    layer.addSublayer(shade)
    layer.addSublayer(border)
    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    addGestureRecognizer(pan)
  }

  required init?(coder: NSCoder) { nil }

  func install(over imageFrame: CGRect) {
    let inset = min(imageFrame.width, imageFrame.height) * 0.08
    cropRectInView = imageFrame.insetBy(dx: inset, dy: inset)
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    shade.frame = bounds
    border.frame = bounds
    let path = UIBezierPath(rect: bounds)
    path.append(UIBezierPath(rect: cropRectInView))
    shade.path = path.cgPath
    border.path = UIBezierPath(rect: cropRectInView).cgPath
  }

  @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
    let delta = gr.translation(in: self)
    gr.setTranslation(.zero, in: self)
    var next = cropRectInView.offsetBy(dx: delta.x, dy: delta.y)
    next.origin.x = min(max(0, next.origin.x), bounds.width - next.width)
    next.origin.y = min(max(0, next.origin.y), bounds.height - next.height)
    cropRectInView = next
    setNeedsLayout()
  }

  func croppedImage(from image: UIImage, drawnIn imageFrame: CGRect) -> UIImage? {
    guard imageFrame.width > 1, imageFrame.height > 1 else { return image }
    let sx = image.size.width / imageFrame.width
    let sy = image.size.height / imageFrame.height
    let crop = CGRect(
      x: (cropRectInView.minX - imageFrame.minX) * sx,
      y: (cropRectInView.minY - imageFrame.minY) * sy,
      width: cropRectInView.width * sx,
      height: cropRectInView.height * sy
    ).integral
    guard let cg = image.cgImage?.cropping(to: crop) else { return image }
    return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
  }
}

enum ChatAttachImageAdjust {
  static func apply(_ image: UIImage, brightness: Double, contrast: Double, saturation: Double)
    -> UIImage
  {
    guard abs(brightness) > 0.004 || abs(contrast) > 0.004 || abs(saturation) > 0.004 else {
      return image
    }
    guard let ciImage = CIImage(image: image) else { return image }
    let filter = CIFilter(name: "CIColorControls")
    filter?.setValue(ciImage, forKey: kCIInputImageKey)
    filter?.setValue(brightness, forKey: kCIInputBrightnessKey)
    filter?.setValue(1.0 + contrast, forKey: kCIInputContrastKey)
    filter?.setValue(1.0 + saturation, forKey: kCIInputSaturationKey)
    guard let output = filter?.outputImage else { return image }
    let context = CIContext(options: nil)
    guard let cg = context.createCGImage(output, from: output.extent) else { return image }
    return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
  }
}
