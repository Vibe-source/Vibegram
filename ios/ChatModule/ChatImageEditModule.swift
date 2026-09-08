import UIKit

enum ChatImageEditEventType: String {
  case reply = "mediaReplyRequested"
  case edit = "mediaEditRequested"
  case resend = "mediaResendRequested"
  case sendNew = "mediaSendNewRequested"
  case showInChat = "mediaShowInChatRequested"
  case delete = "mediaDeleteRequested"
  /// Forward inside the app — the chat's own share sheet, not the system one.
  case share = "mediaShareRequested"
}

struct ChatImageEditActionPayload {
  let eventType: ChatImageEditEventType
  let messageId: String?
  let mediaURL: String
  let caption: String?
  let editedImageURL: URL?
  var extraImageURLs: [URL] = []
  var viewOnce: Bool = false
  var mediaTtlSeconds: Int? = nil
  var isHighQuality: Bool = false
}

/// One page in the native image open sheet (single image or multi-image set).
struct ChatImageEditGalleryPage {
  let mediaURL: String
  let image: UIImage?
  /// Message id this page came from — swiping across a chat moves between
  /// messages, so the action menu has to follow the photo, not the opener.
  let messageId: String?
  /// Second header line (the message date, as in the reference).
  let subtitle: String?
  let viewOnce: Bool
  let mediaTtlSeconds: Int?
  let mediaKey: String?

  init(
    mediaURL: String,
    image: UIImage?,
    messageId: String? = nil,
    subtitle: String? = nil,
    viewOnce: Bool = false,
    mediaTtlSeconds: Int? = nil,
    mediaKey: String? = nil
  ) {
    self.mediaURL = mediaURL
    self.image = image
    self.messageId = messageId
    self.subtitle = subtitle
    self.viewOnce = viewOnce
    self.mediaTtlSeconds = mediaTtlSeconds
    self.mediaKey = mediaKey
  }
}

private final class ChatMediaZoomViewSourceProvider: ChatMediaZoomSourceProviding {
  private weak var sourceView: UIView?
  private weak var fallback: ChatMediaZoomSourceProviding?
  private let initialMessageId: String?
  private let initialPageIndex: Int
  private var directSourceActive = false

  init(
    sourceView: UIView,
    fallback: ChatMediaZoomSourceProviding?,
    initialMessageId: String?,
    initialPageIndex: Int
  ) {
    self.sourceView = sourceView
    self.fallback = fallback
    self.initialMessageId = initialMessageId
    self.initialPageIndex = initialPageIndex
  }

  private func usesDirectSource(messageId: String?, pageIndex: Int) -> Bool {
    guard pageIndex == initialPageIndex else { return false }
    guard let initialMessageId else { return true }
    return messageId == initialMessageId
  }

  func chatMediaZoomSource(forMessageId messageId: String?, pageIndex: Int) -> ChatMediaZoomSource? {
    directSourceActive = usesDirectSource(messageId: messageId, pageIndex: pageIndex)
    guard directSourceActive else {
      return fallback?.chatMediaZoomSource(forMessageId: messageId, pageIndex: pageIndex)
    }
    guard let sourceView, sourceView.window != nil else { return nil }
    if let imageView = sourceView as? UIImageView {
      return makeChatMediaZoomSource(for: imageView)
    }
    let renderer = UIGraphicsImageRenderer(bounds: sourceView.bounds)
    let image = renderer.image { _ in
      sourceView.drawHierarchy(in: sourceView.bounds, afterScreenUpdates: false)
    }
    return ChatMediaZoomSource(
      frame: sourceView.convert(sourceView.bounds, to: nil),
      cornerRadius: sourceView.layer.cornerRadius,
      cornerCurve: sourceView.layer.cornerCurve,
      image: image
    )
  }

  func chatMediaZoomSetSourceHidden(
    _ hidden: Bool,
    forMessageId messageId: String?,
    pageIndex: Int
  ) {
    if usesDirectSource(messageId: messageId, pageIndex: pageIndex) {
      sourceView?.isHidden = hidden
    } else {
      fallback?.chatMediaZoomSetSourceHidden(hidden, forMessageId: messageId, pageIndex: pageIndex)
    }
  }

  func chatMediaZoomInstallFlightView(_ flightView: UIView, frameInWindow: CGRect) -> UIView? {
    guard !directSourceActive else { return nil }
    return fallback?.chatMediaZoomInstallFlightView(flightView, frameInWindow: frameInWindow)
  }
}

enum ChatImageEditModule {
  static func presentEditor(
    from presenter: UIViewController,
    sourceView: UIView? = nil,
    messageId: String?,
    mediaURL: String,
    initialImage: UIImage?,
    initialCaption: String?,
    headerTitle: String? = nil,
    headerSubtitle: String? = nil,
    dismissPresenterOnSend: Bool = false,
    galleryPages: [ChatImageEditGalleryPage] = [],
    startIndex: Int = 0,
    /// When true, open directly in markup mode (draw/text). Default is view-only until Edit.
    startInEditMode: Bool = false,
    /// Only a multi-image *message* gets the thumbnail strip; swiping across a
    /// whole chat would turn it into a scroll bar for hundreds of photos.
    allowsFilmstrip: Bool = true,
    /// Supplies the cell the photo should grow out of and shrink back into.
    zoomSourceProvider: ChatMediaZoomSourceProviding? = nil,
    onProtectedMediaDisplayed: ((String?, Int?) -> Void)? = nil,
    onProtectedMediaExpired: ((String?) -> Void)? = nil,
    onAction: @escaping (ChatImageEditActionPayload) -> Void
  ) {
    let pages: [ChatImageEditGalleryPage] = {
      if galleryPages.count > 1 { return galleryPages }
      if !galleryPages.isEmpty { return galleryPages }
      return [ChatImageEditGalleryPage(mediaURL: mediaURL, image: initialImage)]
    }()
    let controller = ChatImageEditViewController(
      messageId: messageId,
      mediaURL: mediaURL,
      initialImage: initialImage,
      initialCaption: initialCaption,
      headerTitle: headerTitle,
      headerSubtitle: headerSubtitle,
      dismissPresenterOnSend: dismissPresenterOnSend,
      galleryPages: pages,
      startIndex: startIndex,
      startInEditMode: startInEditMode,
      allowsFilmstrip: allowsFilmstrip
    )
    controller.modalPresentationStyle = .overFullScreen
    let transition = ChatMediaZoomTransition()
    if let sourceView {
      transition.sourceProvider = ChatMediaZoomViewSourceProvider(
        sourceView: sourceView,
        fallback: zoomSourceProvider,
        initialMessageId: messageId,
        initialPageIndex: startIndex
      )
    } else {
      transition.sourceProvider = zoomSourceProvider
    }
    controller.zoomTransition = transition
    controller.transitioningDelegate = transition
    controller.onProtectedMediaDisplayed = onProtectedMediaDisplayed
    controller.onProtectedMediaExpired = onProtectedMediaExpired
    controller.onAction = onAction
    presenter.present(controller, animated: true)
  }
}
