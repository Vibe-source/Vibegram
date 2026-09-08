import UIKit

/// Drag-to-select region overlay for AI image editing.
///
/// Sits directly on top of the image at exactly the image's fitted rect, so its
/// bounds map 1:1 onto the picture — `normalizedSelection` is therefore a
/// straight ratio conversion with no letterbox maths.
final class ChatImageAISelectionView: UIView {

  /// Fires whenever the selection appears, changes or is cleared.
  var onSelectionChanged: ((CGRect?) -> Void)?

  private(set) var selectionRect: CGRect? {
    didSet {
      setNeedsLayout()
      updateMask()
    }
  }

  private let dimLayer = CAShapeLayer()
  private let borderLayer = CAShapeLayer()
  private let hintLabel = UILabel()

  private var dragStart: CGPoint?

  /// Below this a drag reads as a stray tap rather than a deliberate region.
  private let minimumSide: CGFloat = 28

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear

    dimLayer.fillRule = .evenOdd
    dimLayer.fillColor = UIColor.black.withAlphaComponent(0.45).cgColor
    layer.addSublayer(dimLayer)

    borderLayer.fillColor = UIColor.clear.cgColor
    borderLayer.strokeColor = UIColor.white.cgColor
    borderLayer.lineWidth = 2
    borderLayer.lineJoin = .round
    layer.addSublayer(borderLayer)

    hintLabel.text = "Drag to select an area"
    hintLabel.font = .systemFont(ofSize: 13, weight: .semibold)
    hintLabel.textColor = UIColor(white: 1, alpha: 0.9)
    hintLabel.textAlignment = .center
    hintLabel.backgroundColor = UIColor.black.withAlphaComponent(0.45)
    hintLabel.layer.cornerRadius = 13
    hintLabel.layer.cornerCurve = .continuous
    hintLabel.clipsToBounds = true
    addSubview(hintLabel)

    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    addGestureRecognizer(pan)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// Selection as ratios of the image (0…1), or nil for whole-image.
  var normalizedSelection: CGRect? {
    guard let rect = selectionRect, bounds.width > 1, bounds.height > 1 else { return nil }
    return CGRect(
      x: rect.minX / bounds.width,
      y: rect.minY / bounds.height,
      width: rect.width / bounds.width,
      height: rect.height / bounds.height
    ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
  }

  func clearSelection() {
    guard selectionRect != nil else { return }
    selectionRect = nil
    onSelectionChanged?(nil)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    hintLabel.isHidden = selectionRect != nil
    let size = CGSize(width: 190, height: 26)
    hintLabel.frame = CGRect(
      x: (bounds.width - size.width) * 0.5,
      y: max(12, bounds.height - size.height - 16),
      width: size.width,
      height: size.height)
    updateMask()
  }

  private func updateMask() {
    let full = UIBezierPath(rect: bounds)
    if let rect = selectionRect {
      full.append(UIBezierPath(roundedRect: rect, cornerRadius: 6).reversing())
      borderLayer.path = UIBezierPath(roundedRect: rect, cornerRadius: 6).cgPath
    } else {
      borderLayer.path = nil
    }
    dimLayer.path = full.cgPath
  }

  @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
    let point = gesture.location(in: self)

    switch gesture.state {
    case .began:
      dragStart = point
      selectionRect = nil

    case .changed:
      guard let start = dragStart else { return }
      selectionRect = rect(from: start, to: point)

    case .ended:
      guard let start = dragStart else { return }
      let candidate = rect(from: start, to: point)
      dragStart = nil
      if candidate.width < minimumSide || candidate.height < minimumSide {
        // Too small to be intentional — fall back to whole-image.
        selectionRect = nil
        onSelectionChanged?(nil)
      } else {
        selectionRect = candidate
        onSelectionChanged?(candidate)
      }

    case .cancelled, .failed:
      dragStart = nil
      selectionRect = nil
      onSelectionChanged?(nil)

    default:
      break
    }
  }

  private func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
    CGRect(
      x: min(a.x, b.x),
      y: min(a.y, b.y),
      width: abs(a.x - b.x),
      height: abs(a.y - b.y)
    ).intersection(bounds)
  }
}
