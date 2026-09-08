import UIKit

/// Where the current thumbnail lives in window coordinates.
struct ChatMediaZoomSource {
  let frame: CGRect
  let cornerRadius: CGFloat
  let cornerCurve: CALayerCornerCurve
  let image: UIImage?
}

/// Resolve the same clipping geometry the thumbnail actually displays. Some
/// cells put their corner radius on the image view, others on an identically
/// sized wrapper; preserving the owner, its curve and its window-space scale
/// prevents the flight from becoming a slightly different rounded rectangle on
/// its final frame.
func makeChatMediaZoomSource(for anchor: UIImageView) -> ChatMediaZoomSource {
  let anchorFrame = anchor.convert(anchor.bounds, to: nil)
  let clipOwner: UIView = {
    if anchor.layer.cornerRadius > 0 { return anchor }
    guard let parent = anchor.superview,
      parent.layer.cornerRadius > 0 || parent.layer.mask is CAShapeLayer
    else { return anchor }
    let parentFrame = parent.convert(parent.bounds, to: nil)
    let sameGeometry =
      abs(parentFrame.width - anchorFrame.width) < 1.5
      && abs(parentFrame.height - anchorFrame.height) < 1.5
      && abs(parentFrame.midX - anchorFrame.midX) < 1.5
      && abs(parentFrame.midY - anchorFrame.midY) < 1.5
    return sameGeometry ? parent : anchor
  }()
  let frame = clipOwner === anchor ? anchorFrame : clipOwner.convert(clipOwner.bounds, to: nil)
  let shapeMask = clipOwner.layer.mask as? CAShapeLayer
  let localRadius: CGFloat = {
    if clipOwner.layer.cornerRadius > 0 { return clipOwner.layer.cornerRadius }
    if let path = shapeMask?.path {
      // Chat bubble masks start at (topLeftRadius, 0). Using that radius keeps
      // the spring visually aligned; the source view itself supplies the exact
      // asymmetric mask on handoff.
      var firstPoint: CGPoint?
      path.applyWithBlock { element in
        guard firstPoint == nil, element.pointee.type == .moveToPoint else { return }
        firstPoint = element.pointee.points[0]
      }
      if let firstPoint { return max(0, firstPoint.x) }
    }
    return anchor.superview?.layer.cornerRadius ?? 0
  }()
  let scaleX = frame.width / max(clipOwner.bounds.width, 1)
  let scaleY = frame.height / max(clipOwner.bounds.height, 1)
  return ChatMediaZoomSource(
    frame: frame,
    cornerRadius: localRadius * min(scaleX, scaleY),
    cornerCurve: shapeMask == nil ? clipOwner.layer.cornerCurve : .circular,
    image: anchor.image)
}

/// The source side of the photo-only transition.
protocol ChatMediaZoomSourceProviding: AnyObject {
  func chatMediaZoomSource(forMessageId messageId: String?, pageIndex: Int) -> ChatMediaZoomSource?
  func chatMediaZoomSetSourceHidden(
    _ hidden: Bool,
    forMessageId messageId: String?,
    pageIndex: Int)
  /// Mounts the flight view inside the source content hierarchy. In the chat
  /// this host sits below its header, so the photo can never paint over chrome.
  func chatMediaZoomInstallFlightView(_ flightView: UIView, frameInWindow: CGRect) -> UIView?
}

/// The viewer side of the shared photo transition.
protocol ChatMediaZoomTransitionTarget: UIViewController {
  var zoomTransitionImage: UIImage? { get }
  var zoomTransitionMessageId: String? { get }
  var zoomTransitionPageIndex: Int { get }
  func zoomTransitionTargetFrame(for image: UIImage?) -> CGRect
  var zoomTransitionCurrentFrame: CGRect { get }
  func setZoomTransitionContentHidden(_ hidden: Bool)
  /// Mounts the flight view below the viewer's native navigation header.
  func installZoomTransitionFlightView(_ flightView: UIView, frameInWindow: CGRect) -> UIView
}

/// Photo-only zoom. Unlike UIKit's whole-controller zoom, this keeps the
/// presenting chat at scale 1.0 for the full transition.
final class ChatMediaZoomTransition: NSObject, UIViewControllerTransitioningDelegate {
  var sourceProvider: ChatMediaZoomSourceProviding?

  func animationController(
    forPresented presented: UIViewController,
    presenting: UIViewController,
    source: UIViewController
  ) -> UIViewControllerAnimatedTransitioning? {
    guard let target = presented as? ChatMediaZoomTransitionTarget else { return nil }
    return ChatMediaZoomPresentAnimator(target: target, sourceProvider: sourceProvider)
  }

  func animationController(forDismissed dismissed: UIViewController)
    -> UIViewControllerAnimatedTransitioning?
  {
    guard let target = dismissed as? ChatMediaZoomTransitionTarget else { return nil }
    return ChatMediaZoomDismissAnimator(target: target, sourceProvider: sourceProvider)
  }
}

private func makeZoomFlyingView(
  image: UIImage?, cornerRadius: CGFloat, cornerCurve: CALayerCornerCurve
) -> UIView {
  let container = UIView()
  container.clipsToBounds = true
  container.backgroundColor = .clear
  container.layer.cornerRadius = cornerRadius
  container.layer.cornerCurve = cornerCurve

  let imageView = UIImageView(image: image)
  imageView.contentMode = .scaleAspectFill
  imageView.frame = container.bounds
  imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
  container.addSubview(imageView)
  return container
}

private final class ChatMediaZoomPresentAnimator: NSObject, UIViewControllerAnimatedTransitioning {
  private weak var target: ChatMediaZoomTransitionTarget?
  private weak var sourceProvider: ChatMediaZoomSourceProviding?

  init(target: ChatMediaZoomTransitionTarget, sourceProvider: ChatMediaZoomSourceProviding?) {
    self.target = target
    self.sourceProvider = sourceProvider
  }

  func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?)
    -> TimeInterval
  {
    0.42
  }

  func animateTransition(using context: UIViewControllerContextTransitioning) {
    let container = context.containerView
    guard let target, let toView = target.view else {
      context.completeTransition(!context.transitionWasCancelled)
      return
    }

    toView.frame = context.finalFrame(for: target)
    container.addSubview(toView)
    toView.layoutIfNeeded()

    let messageId = target.zoomTransitionMessageId
    let pageIndex = target.zoomTransitionPageIndex
    let source = sourceProvider?.chatMediaZoomSource(forMessageId: messageId, pageIndex: pageIndex)
    let image = target.zoomTransitionImage ?? source?.image
    let endFrameInWindow = target.zoomTransitionTargetFrame(for: image)
    let duration = transitionDuration(using: context)

    guard let source, let image,
      endFrameInWindow.width > 1, endFrameInWindow.height > 1,
      source.frame.width > 1, source.frame.height > 1
    else {
      context.completeTransition(!context.transitionWasCancelled)
      return
    }

    let flyer = makeZoomFlyingView(
      image: image,
      cornerRadius: source.cornerRadius,
      cornerCurve: source.cornerCurve)
    let host = target.installZoomTransitionFlightView(flyer, frameInWindow: source.frame)
    target.setZoomTransitionContentHidden(true)
    sourceProvider?.chatMediaZoomSetSourceHidden(
      true, forMessageId: messageId, pageIndex: pageIndex)

    let endFrame = host.convert(endFrameInWindow, from: nil)
    let animator = UIViewPropertyAnimator(duration: duration, dampingRatio: 0.88) {
      flyer.frame = endFrame
      flyer.layer.cornerRadius = 0
    }
    animator.addCompletion { _ in
      target.setZoomTransitionContentHidden(false)
      self.sourceProvider?.chatMediaZoomSetSourceHidden(
        false, forMessageId: messageId, pageIndex: pageIndex)
      flyer.removeFromSuperview()
      context.completeTransition(!context.transitionWasCancelled)
    }
    animator.startAnimation()
  }
}

private final class ChatMediaZoomDismissAnimator: NSObject, UIViewControllerAnimatedTransitioning {
  private weak var target: ChatMediaZoomTransitionTarget?
  private weak var sourceProvider: ChatMediaZoomSourceProviding?

  init(target: ChatMediaZoomTransitionTarget, sourceProvider: ChatMediaZoomSourceProviding?) {
    self.target = target
    self.sourceProvider = sourceProvider
  }

  func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?)
    -> TimeInterval
  {
    0.36
  }

  func animateTransition(using context: UIViewControllerContextTransitioning) {
    let container = context.containerView
    guard let target, let fromView = target.view else {
      context.completeTransition(!context.transitionWasCancelled)
      return
    }

    let messageId = target.zoomTransitionMessageId
    let pageIndex = target.zoomTransitionPageIndex
    let startFrameInWindow = target.zoomTransitionCurrentFrame
    let image = target.zoomTransitionImage
    let source = sourceProvider?.chatMediaZoomSource(forMessageId: messageId, pageIndex: pageIndex)
    let duration = transitionDuration(using: context)

    guard let source, let image,
      startFrameInWindow.width > 1, startFrameInWindow.height > 1,
      source.frame.width > 1, source.frame.height > 1
    else {
      fromView.removeFromSuperview()
      context.completeTransition(!context.transitionWasCancelled)
      return
    }

    let flyer = makeZoomFlyingView(
      image: image,
      cornerRadius: 0,
      cornerCurve: source.cornerCurve)
    let host: UIView
    if let sourceHost = sourceProvider?.chatMediaZoomInstallFlightView(
      flyer, frameInWindow: startFrameInWindow)
    {
      host = sourceHost
    } else {
      host = container
      container.addSubview(flyer)
      flyer.frame = container.convert(startFrameInWindow, from: nil)
    }

    target.setZoomTransitionContentHidden(true)
    sourceProvider?.chatMediaZoomSetSourceHidden(
      true, forMessageId: messageId, pageIndex: pageIndex)
    fromView.isHidden = true

    let endFrame = host.convert(source.frame, from: nil)
    let animator = UIViewPropertyAnimator(duration: duration, dampingRatio: 0.92) {
      flyer.frame = endFrame
      flyer.layer.cornerRadius = source.cornerRadius
    }
    animator.addCompletion { _ in
      self.sourceProvider?.chatMediaZoomSetSourceHidden(
        false, forMessageId: messageId, pageIndex: pageIndex)
      flyer.removeFromSuperview()
      fromView.removeFromSuperview()
      context.completeTransition(!context.transitionWasCancelled)
    }
    animator.startAnimation()
  }
}
