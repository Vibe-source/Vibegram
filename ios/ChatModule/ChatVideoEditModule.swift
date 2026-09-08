import AVFoundation
import UIKit

struct ChatVideoEditActionPayload {
  let videoURL: URL
  let caption: String?
  let isMuted: Bool
  let qualityLabel: String
  let transitionCapture: ChatAttachmentTransitionCapture?
}

enum ChatVideoEditModule {
  static func presentEditor(
    from presenter: UIViewController,
    asset: AVAsset,
    initialCaption: String?,
    onSend: @escaping (ChatVideoEditActionPayload) -> Void
  ) {
    let controller = ChatVideoEditViewController(
      asset: asset,
      initialCaption: initialCaption,
      headerTitle: nil,
      previewOnly: false
    )
    controller.modalPresentationStyle = .overFullScreen
    controller.onSend = onSend
    presenter.present(controller, animated: true)
  }

  static func presentPreview(
    from presenter: UIViewController,
    asset: AVAsset,
    initialCaption: String?,
    headerTitle: String? = nil,
    messageId: String? = nil,
    viewOnce: Bool = false,
    mediaTtlSeconds: Int? = nil,
    zoomSourceProvider: ChatMediaZoomSourceProviding? = nil,
    onProtectedMediaDisplayed: ((String?, Int?) -> Void)? = nil,
    onProtectedMediaExpired: ((String?) -> Void)? = nil,
    onReply: (() -> Void)? = nil
  ) {
    let controller = ChatVideoEditViewController(
      asset: asset,
      initialCaption: initialCaption,
      headerTitle: headerTitle,
      previewOnly: true,
      messageId: messageId,
      viewOnce: viewOnce,
      mediaTtlSeconds: mediaTtlSeconds
    )
    controller.modalPresentationStyle = .overFullScreen
    controller.onProtectedMediaDisplayed = onProtectedMediaDisplayed
    controller.onProtectedMediaExpired = onProtectedMediaExpired
    controller.onReply = onReply
    if let zoomSourceProvider {
      let transition = ChatMediaZoomTransition()
      transition.sourceProvider = zoomSourceProvider
      controller.zoomTransition = transition
      controller.transitioningDelegate = transition
    }
    presenter.present(controller, animated: true)
  }
}
