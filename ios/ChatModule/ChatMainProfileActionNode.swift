import UIKit

final class ChatMainProfileActionNode: UIControl {
  private let glassView = UIVisualEffectView(effect: nil)
  private let iconView = UIImageView()
  private let titleView = UILabel()
  private let pressedOverlay = UIView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    clipsToBounds = false
    backgroundColor = .clear

    glassView.clipsToBounds = true
    glassView.isUserInteractionEnabled = false
    addSubview(glassView)

    pressedOverlay.backgroundColor = UIColor(white: 1.0, alpha: 0.12)
    pressedOverlay.alpha = 0
    pressedOverlay.isUserInteractionEnabled = false
    glassView.contentView.addSubview(pressedOverlay)

    iconView.contentMode = .center
    glassView.contentView.addSubview(iconView)

    titleView.font = UIFont.systemFont(ofSize: 11, weight: .regular)
    titleView.textAlignment = .center
    titleView.numberOfLines = 1
    addSubview(titleView)
  }

  override var isHighlighted: Bool {
    didSet {
      let scale: CGFloat = isHighlighted ? 0.92 : 1.0
      let duration: TimeInterval = isHighlighted ? 0.08 : 0.18
      UIView.animate(
        withDuration: duration, delay: 0, options: [.curveEaseOut, .allowUserInteraction]
      ) {
        self.glassView.transform = CGAffineTransform(scaleX: scale, y: scale)
        self.pressedOverlay.alpha = self.isHighlighted ? 1.0 : 0.0
      }
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let circleSize: CGFloat = 44
    let spacing: CGFloat = 4
    let titleHeight: CGFloat = 14
    
    let totalHeight = circleSize + spacing + titleHeight
    let startY = max(0, (bounds.height - totalHeight) * 0.5)
    
    glassView.frame = CGRect(
      x: (bounds.width - circleSize) * 0.5,
      y: startY,
      width: circleSize,
      height: circleSize
    )
    glassView.layer.cornerRadius = circleSize * 0.5

    iconView.frame = glassView.bounds
    pressedOverlay.frame = glassView.bounds

    titleView.frame = CGRect(
      x: -10,
      y: glassView.frame.maxY + spacing,
      width: bounds.width + 20,
      height: titleHeight
    )
  }

  func configure(title: String, symbol: String) {
    titleView.text = title
    let cfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)
    iconView.image = UIImage(systemName: symbol, withConfiguration: cfg)
  }

  func setTitle(_ title: String) {
    titleView.text = title
  }

  func applyTheme(foreground: UIColor, background: UIColor, isDark: Bool = true) {
    titleView.textColor = foreground
    iconView.tintColor = foreground

    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .regular)
      glass.isInteractive = true
      glassView.effect = glass
      glassView.contentView.backgroundColor = .clear
    } else {
      glassView.effect = UIBlurEffect(style: isDark ? .systemThinMaterialDark : .systemThinMaterialLight)
      glassView.contentView.backgroundColor = background.withAlphaComponent(0.25)
    }
  }
}
