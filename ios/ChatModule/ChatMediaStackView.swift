import UIKit

/// How a multi-image message presents itself inside the bubble.
enum ChatMediaStackMode {
  /// A deck of cards: one picture face-up, the next couple showing as edges
  /// behind it. Used when the message has no caption, where the bubble is the
  /// picture and there is room to let the stack read as a stack.
  case deck
  /// Inline paging with dots. Used when there is a caption — the caption already
  /// wants the bubble's full width, so the images page in place instead of
  /// stacking into extra height.
  case carousel
}

/// Geometry for a multi-image bubble. Pure, because the sizing pass and the
/// layout pass must agree exactly — a row whose measured height disagrees with
/// what it draws is the list-shift bug this codebase keeps re-learning.
enum ChatMediaStackGeometry {
  /// Vertical drop per card behind the front one.
  static let peekStep: CGFloat = 9.0
  /// How much smaller each card behind the front one is.
  static let scaleStep: CGFloat = 0.055
  /// Cards actually rendered behind the front one. Beyond this the deck reads as
  /// the same thickness, so a 40-image message costs no more than a 4-image one.
  static let maxDepth: Int = 2

  /// Card aspect (height ÷ width), clamped so one extreme picture cannot make a
  /// whole bubble absurd.
  static func cardAspect(natural: CGSize?) -> CGFloat {
    guard let natural, natural.width > 1, natural.height > 1 else { return 1.0 }
    return max(0.62, min(1.32, natural.height / natural.width))
  }

  static func height(count: Int, width: CGFloat, mode: ChatMediaStackMode, aspect: CGFloat)
    -> CGFloat
  {
    guard count > 1, width > 1 else { return 0 }
    let cardHeight = (width * aspect).rounded()
    switch mode {
    case .carousel:
      return cardHeight
    case .deck:
      let depth = min(maxDepth, count - 1)
      return cardHeight + peekStep * CGFloat(depth)
    }
  }

  /// The front card's rect inside a stack of the given total height.
  static func frontCardRect(
    count: Int, width: CGFloat, mode: ChatMediaStackMode, aspect: CGFloat
  ) -> CGRect {
    let cardHeight = (width * aspect).rounded()
    return CGRect(x: 0, y: 0, width: width, height: cardHeight)
  }
}

/// Multi-image message body: a swipeable deck (or inline carousel) instead of a
/// tile grid. One picture is shown whole rather than four cropped into squares.
final class ChatMediaStackView: UIView, UIGestureRecognizerDelegate {
  /// Opening the viewer: which image, and the view it should grow out of.
  var onTap: ((Int, UIImageView) -> Void)?
  /// Fires when the visible picture changes, so the cell can re-report its anchor.
  var onIndexChanged: ((Int) -> Void)?

  private(set) var mode: ChatMediaStackMode = .deck
  private(set) var currentIndex: Int = 0
  private(set) var imageCount: Int = 0
  private var aspect: CGFloat = 1.0

  private var cardViews: [UIImageView] = []
  private let counterLabel = PaddedCounterLabel()
  private let dotsView = ChatMediaStackDots()
  private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
  private var dragOffset: CGFloat = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = false
    isUserInteractionEnabled = true

    counterLabel.isHidden = true
    counterLabel.textColor = .white
    counterLabel.font = .systemFont(ofSize: 11, weight: .semibold)
    counterLabel.backgroundColor = UIColor.black.withAlphaComponent(0.42)
    counterLabel.layer.cornerRadius = 9
    counterLabel.layer.cornerCurve = .continuous
    counterLabel.clipsToBounds = true
    addSubview(counterLabel)

    dotsView.isHidden = true
    addSubview(dotsView)

    pan.delegate = self
    addGestureRecognizer(pan)
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    addGestureRecognizer(tap)
  }

  required init?(coder: NSCoder) { nil }

  // MARK: - Content

  func configure(count: Int, mode: ChatMediaStackMode, aspect: CGFloat, resetIndex: Bool) {
    let clamped = max(0, count)
    let modeChanged = self.mode != mode
    self.mode = mode
    self.aspect = aspect

    if clamped != imageCount || resetIndex {
      currentIndex = 0
      dragOffset = 0
    }
    imageCount = clamped

    while cardViews.count < clamped {
      let card = UIImageView()
      card.contentMode = .scaleAspectFill
      card.clipsToBounds = true
      card.layer.cornerRadius = 14
      card.layer.cornerCurve = .continuous
      card.backgroundColor = UIColor(white: 0, alpha: 0.22)
      // Each card behind the front one gets a hairline edge, or a stack of
      // similar photos reads as one thick blurry card.
      card.layer.borderWidth = 0.5
      card.layer.borderColor = UIColor(white: 1, alpha: 0.10).cgColor
      insertSubview(card, belowSubview: counterLabel)
      cardViews.append(card)
    }
    for (index, card) in cardViews.enumerated() {
      card.isHidden = index >= clamped
      if index >= clamped { card.image = nil }
    }

    counterLabel.isHidden = mode != .deck || clamped < 2
    dotsView.isHidden = mode != .carousel || clamped < 2
    dotsView.count = clamped
    if modeChanged { setNeedsLayout() }
    refreshIndicators()
    setNeedsLayout()
  }

  func setImage(_ image: UIImage?, at index: Int) {
    guard index >= 0, index < cardViews.count else { return }
    cardViews[index].image = image
  }

  func image(at index: Int) -> UIImage? {
    guard index >= 0, index < cardViews.count else { return nil }
    return cardViews[index].image
  }

  func imageView(at index: Int) -> UIImageView? {
    guard index >= 0, index < cardViews.count else { return nil }
    return cardViews[index]
  }

  /// The card the user is actually looking at — what the zoom transition has to
  /// fly out of, and what a tap opens.
  var frontImageView: UIImageView? { imageView(at: currentIndex) }

  // MARK: - Layout

  override func layoutSubviews() {
    super.layoutSubviews()
    let card = ChatMediaStackGeometry.frontCardRect(
      count: imageCount, width: bounds.width, mode: mode, aspect: aspect)
    for (index, view) in cardViews.enumerated() where !view.isHidden {
      view.transform = .identity
      view.frame = card
      apply(depth: CGFloat(index - currentIndex) - dragOffset, to: view)
    }

    let inset: CGFloat = 8
    counterLabel.sizeToFit()
    let counterSize = CGSize(
      width: max(30, counterLabel.bounds.width + 16), height: 18)
    counterLabel.frame = CGRect(
      x: card.maxX - inset - counterSize.width,
      y: card.minY + inset,
      width: counterSize.width,
      height: counterSize.height)

    let dotsHeight: CGFloat = 14
    dotsView.frame = CGRect(
      x: 0, y: card.maxY - dotsHeight - 8, width: bounds.width, height: dotsHeight)
  }

  /// Where a card sits given its distance from the front one. Fractional while a
  /// drag is in flight, which is what makes the deck follow the finger instead of
  /// snapping between states.
  private func apply(depth: CGFloat, to view: UIImageView) {
    switch mode {
    case .carousel:
      let width = bounds.width
      view.layer.zPosition = 100 - abs(depth)
      view.transform = CGAffineTransform(translationX: depth * (width + 6), y: 0)
      view.alpha = abs(depth) > 1.4 ? 0 : 1

    case .deck:
      if depth < 0 {
        // Thrown off to the left, and drawn above the rest on its way out.
        let width = bounds.width
        view.layer.zPosition = 200 - depth
        view.transform = CGAffineTransform(
          translationX: depth * width * 1.12, y: 0
        ).rotated(by: depth * 0.14)
        view.alpha = max(0, 1 + depth)
      } else {
        let clamped = min(depth, CGFloat(ChatMediaStackGeometry.maxDepth))
        let scale = 1 - ChatMediaStackGeometry.scaleStep * clamped
        view.layer.zPosition = 100 - clamped
        view.transform = CGAffineTransform(
          translationX: 0, y: ChatMediaStackGeometry.peekStep * clamped
        ).scaledBy(x: scale, y: scale)
        view.alpha = depth > CGFloat(ChatMediaStackGeometry.maxDepth) + 0.9 ? 0 : 1
      }
    }
  }

  private func refreshIndicators() {
    counterLabel.text = "\(min(currentIndex + 1, max(imageCount, 1)))/\(imageCount)"
    dotsView.selected = currentIndex
    setNeedsLayout()
  }

  // MARK: - Gestures

  @objc private func handleTap() {
    guard let front = frontImageView else { return }
    onTap?(currentIndex, front)
  }

  @objc private func handlePan(_ gr: UIPanGestureRecognizer) {
    guard imageCount > 1, bounds.width > 1 else { return }
    let translation = gr.translation(in: self).x

    switch gr.state {
    case .changed:
      // Resist at the ends rather than refusing to move: a dead edge reads as a
      // broken gesture, a heavy one reads as the end of the deck.
      var raw = -translation / bounds.width
      if currentIndex == 0, raw < 0 { raw *= 0.35 }
      if currentIndex == imageCount - 1, raw > 0 { raw *= 0.35 }
      dragOffset = raw
      setNeedsLayout()
      layoutIfNeeded()

    case .ended, .cancelled, .failed:
      let velocity = gr.velocity(in: self).x
      var target = currentIndex
      if gr.state == .ended, dragOffset > 0.28 || velocity < -700 {
        target = min(imageCount - 1, currentIndex + 1)
      } else if gr.state == .ended, dragOffset < -0.28 || velocity > 700 {
        target = max(0, currentIndex - 1)
      }
      setCurrentIndex(target, animated: true)

    default:
      break
    }
  }

  func setCurrentIndex(_ index: Int, animated: Bool) {
    let clamped = max(0, min(max(imageCount - 1, 0), index))
    let changed = clamped != currentIndex
    currentIndex = clamped
    dragOffset = 0
    refreshIndicators()

    let settle = { self.layoutIfNeeded() }
    if animated {
      UIView.animate(
        withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0,
        options: [.beginFromCurrentState, .allowUserInteraction],
        animations: {
          self.setNeedsLayout()
          settle()
        })
    } else {
      setNeedsLayout()
      settle()
    }
    if changed { onIndexChanged?(clamped) }
  }

  // `UIView` already declares this, so the delegate conformance overrides it.
  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer === pan else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
    guard imageCount > 1 else { return false }
    // Horizontal intent only, so a scroll that starts on a photo still scrolls
    // the chat rather than flicking through the message's images.
    let translation = pan.translation(in: self)
    let velocity = pan.velocity(in: self)
    if abs(translation.x) > 2 || abs(translation.y) > 2 {
      return abs(translation.x) > abs(translation.y)
    }
    return abs(velocity.x) > abs(velocity.y)
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool {
    // The list's own vertical scroll keeps working underneath; only the chat's
    // leftward reply swipe is asked to stand down, and that happens in
    // `ChatListView`'s own `gestureRecognizerShouldBegin`.
    other is UIPanGestureRecognizer && other.view is UIScrollView
  }
}

// MARK: - Indicators

private final class PaddedCounterLabel: UILabel {
  override func drawText(in rect: CGRect) {
    super.drawText(in: rect.insetBy(dx: 8, dy: 0))
  }
}

/// Page dots for the caption variant, drawn rather than hosted so the cell keeps
/// one view per indicator instead of a `UIPageControl`'s internals.
private final class ChatMediaStackDots: UIView {
  var count: Int = 0 { didSet { setNeedsDisplay() } }
  var selected: Int = 0 { didSet { setNeedsDisplay() } }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isUserInteractionEnabled = false
    isOpaque = false
  }

  required init?(coder: NSCoder) { nil }

  override func draw(_ rect: CGRect) {
    guard count > 1, let ctx = UIGraphicsGetCurrentContext() else { return }
    // Past a point the dots stop being countable and only add noise; the counter
    // pill covers those cases instead.
    let shown = min(count, 10)
    let dot: CGFloat = 6
    let gap: CGFloat = 5
    let totalWidth = CGFloat(shown) * dot + CGFloat(shown - 1) * gap
    var x = (bounds.width - totalWidth) * 0.5
    let y = (bounds.height - dot) * 0.5

    for index in 0..<shown {
      let isOn = index == min(selected, shown - 1)
      ctx.setFillColor(UIColor.white.withAlphaComponent(isOn ? 0.95 : 0.42).cgColor)
      ctx.fillEllipse(in: CGRect(x: x, y: y, width: dot, height: dot))
      x += dot + gap
    }
  }
}
