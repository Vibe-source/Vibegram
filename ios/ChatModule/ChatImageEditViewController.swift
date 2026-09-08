import Combine
import PencilKit
import PhotosUI
import SwiftUI
import UIKit

/// Full-screen image open + markup (PencilKit draw, text, stickers).
/// Opaque black canvas — never shows chat cells underneath.
final class ChatImageEditViewController: UIViewController, UITextFieldDelegate,
  UIGestureRecognizerDelegate, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout,
  PKCanvasViewDelegate, UIEditMenuInteractionDelegate
{
  private let messageId: String?
  private var mediaURL: String
  private let initialImage: UIImage?
  private let initialCaption: String
  private let headerTitleText: String
  private let headerSubtitleText: String
  private let dismissPresenterOnSend: Bool
  private let startInEditMode: Bool
  private let allowsFilmstrip: Bool
  private var captionText: String
  private var galleryPages: [ChatImageEditGalleryPage]
  private var galleryIndex: Int

  var onAction: ((ChatImageEditActionPayload) -> Void)?
  var onProtectedMediaDisplayed: ((String?, Int?) -> Void)?
  var onProtectedMediaExpired: ((String?) -> Void)?

  // MARK: Canvas

  private let stageView = UIView()
  /// The black behind the photo, as its own view rather than the controller's
  /// background colour, so a swipe-to-dismiss can switch it off outright and let
  /// the chat show through. It is never faded — only shown or hidden.
  private let backdropView = UIView()

  // MARK: Photo-only media transition

  /// Held strongly because `transitioningDelegate` is weak.
  var zoomTransition: ChatMediaZoomTransition?
  private lazy var dismissPan = UIPanGestureRecognizer(
    target: self, action: #selector(handleDismissPan(_:)))
  private var isDismissDragging = false
  private var chromeWasHiddenBeforeDrag = false
  private var hasCommittedDragEffects = false

  // MARK: Paging
  //
  // Viewing pages horizontally through the chat's photos; the markup surface
  // rides on top of the current page and is translated with the scroll so the
  // picture being edited is the one that moves under the finger.
  private let pagingScrollView = UIScrollView()
  private var pageImageViews: [UIImageView] = []
  private var isChromeHidden = false
  private let renderSurfaceView = UIView()
  private let imageView = UIImageView()
  private let canvasView = PKCanvasView()
  /// Inking is PencilKit's (`PKCanvasView` + `PKInkingTool`) — that is where
  /// stroke quality actually comes from. The *picker*, though, is ours.
  ///
  /// `PKToolPicker` docks itself to the bottom of the screen on iPhone and there
  /// is no API to place it anywhere else, so it can only ever sit **below** the
  /// mode row — which put the pens on the far side of the actions and shoved the
  /// whole row upward every time drawing turned on. The reference stacks pens,
  /// colours and actions as one block with the actions on the floor, and that is
  /// only reachable with a row we lay out ourselves.
  private let overlayContainer = UIView()

  // MARK: AI edit

  private let aiSelectionView = ChatImageAISelectionView()
  /// Images replaced by an AI edit, newest last — powers the Undo chip.
  private var aiUndoStack: [UIImage] = []
  private var aiTask: Task<Void, Never>?

  // MARK: Top chrome

  private let topContainer = UIView()
  /// SwiftUI owns the native Liquid Glass container because it can associate
  /// stable IDs with multiple surfaces and morph them in place. A standalone
  /// `UINavigationBar` only transitions whole item stacks, which made the
  /// ellipsis/Clear All change read as an unanimated replacement.
  private lazy var headerHost = ChatImageEditorHeaderHost(
    title: headerTitleText,
    subtitle: headerSubtitleText,
    hasMessage: currentMessageId != nil,
    allowsActions: !isProtectedMediaPage)
  private lazy var composerModel = ChatAttachComposerModel(
    recipientName: headerTitleText == "Photo" ? "" : headerTitleText,
    pickCount: 1,
    pageIndex: 0,
    caption: "")
  private lazy var composerHost = ChatAttachComposerChromeHost(
    model: composerModel,
    sendColor: UIColor(red: 0.20, green: 0.55, blue: 0.98, alpha: 1))
  private var isAttachComposer: Bool { dismissPresenterOnSend && messageId == nil }
  private var cropOverlay: ChatAttachCropOverlay?
  private var composerOriginalImage: UIImage?

  // MARK: Bottom

  private let bottomContainer = UIView()
  /// Keeps white chrome readable when it floats over a bright photo.
  private let topScrim = CAGradientLayer()
  private let bottomScrimHost = UIView()
  private let bottomScrim = CAGradientLayer()
  private let captionField = UITextField()
  private let markupModel = ChatImageMarkupModel()
  private lazy var markupHost = ChatImageMarkupToolbarHost(model: markupModel)
  private let viewerBarHost = ChatImageViewerBottomBarHost()
  private let strokeSizeControl = ChatImageStrokeSizeControl()
  private var markupCancellable: AnyCancellable?
  private var composerCancellable: AnyCancellable?

  /// Sticker/GIF library (reuse chat GIF panel — not a custom emoji tray).
  private var gifPanel: ChatGifPanelView?
  private let gifPanelContainer = UIView()
  private let gifGrabber = UIView()
  private var isGifPanelVisible = false
  /// 0…1 expand factor; 0 = default height, 1 = nearly full.
  private var gifPanelExpand: CGFloat = 0
  private var gifPanStartExpand: CGFloat = 0

  /// Asking the AI for an edit. Deliberately *not* a markup mode: it puts a
  /// field above the keyboard and changes nothing else, so the picture never
  /// resizes to make room for tools a prompt has no use for.
  private var isAIPromptActive = false
  private let aiPromptBar = ChatImageAIPromptBar()

  /// The content below the native header still changes height when tools enter.
  /// Keeping this animator separate makes it impossible for it to reorder or
  /// cover the navigation bar.
  private var markupLayoutAnimator: UIViewPropertyAnimator?

  /// Inline text entry overlay (Cancel / Done flow).
  private var isTextEntryActive = false
  private let textDimView = UIView()
  private let textEntryField = UITextField()
  private let textKeyboardAccessoryBlur = UIVisualEffectView(
    effect: UIBlurEffect(style: .dark))
  private var textKeyboardAccessoryHost: UIHostingController<ChatImageTextKeyboardBar>?

  /// Covers the picture — and only the picture — while the model works, with the
  /// elapsed clock on it. Shared with the video editor.
  private let aiProcessingOverlay = ChatAIProcessingOverlayView()
  private weak var editingTextShell: MarkupTextShellView?
  private weak var activeTextMenuShell: MarkupTextShellView?
  private var overlayPanStartCenters: [ObjectIdentifier: CGPoint] = [:]

  // MARK: Filmstrip

  private let filmstripLayout = UICollectionViewFlowLayout()
  private lazy var filmstrip: UICollectionView = {
    filmstripLayout.scrollDirection = .horizontal
    filmstripLayout.minimumLineSpacing = 8
    filmstripLayout.itemSize = CGSize(width: 52, height: 52)
    let cv = UICollectionView(frame: .zero, collectionViewLayout: filmstripLayout)
    cv.backgroundColor = .clear
    cv.showsHorizontalScrollIndicator = false
    cv.dataSource = self
    cv.delegate = self
    cv.register(
      ChatImageEditFilmstripCell.self,
      forCellWithReuseIdentifier: ChatImageEditFilmstripCell.reuseId)
    cv.isHidden = true
    return cv
  }()

  private var remoteImageTask: URLSessionDataTask?
  private var originalImage: UIImage?
  private var isHighQuality = false
  private var keyboardHeight: CGFloat = 0
  private var isMarkupActive = false
  /// Last mode the layout was animated for, so only a real tab change springs.
  private var lastAppliedMarkupMode: ChatImageMarkupMode?
  private var undoManagerProxy = UndoManager()
  private let protectedTimerHost = UIView()
  private let protectedTimerTrack = UIView()
  private let protectedTimerFill = UIView()
  private let protectedTimerIcon = UIImageView(image: UIImage(systemName: "flame.fill"))
  private let protectedTimerLabel = UILabel()
  private var protectedTimer: Timer?
  private var protectedTimerDeadline: CFTimeInterval?
  private var protectedTimerDuration: TimeInterval = 0
  private var displayedProtectedMediaIds = Set<String>()
  private var isProtectedExpiryCommitted = false

  private var currentPage: ChatImageEditGalleryPage? { galleryPages[safeIndex: galleryIndex] }
  private var isProtectedMediaPage: Bool {
    currentPage?.viewOnce == true || (currentPage?.mediaTtlSeconds ?? 0) > 0
  }
  private var showsFilmstrip: Bool { allowsFilmstrip && galleryPages.count > 1 }
  private var showsPaging: Bool { galleryPages.count > 1 }

  // MARK: Init

  init(
    messageId: String?,
    mediaURL: String,
    initialImage: UIImage?,
    initialCaption: String?,
    headerTitle: String?,
    headerSubtitle: String? = nil,
    dismissPresenterOnSend: Bool,
    galleryPages: [ChatImageEditGalleryPage] = [],
    startIndex: Int = 0,
    startInEditMode: Bool = false,
    allowsFilmstrip: Bool = true
  ) {
    self.messageId = messageId
    let pages: [ChatImageEditGalleryPage] = {
      if galleryPages.count > 1 { return galleryPages }
      if !galleryPages.isEmpty { return galleryPages }
      return [ChatImageEditGalleryPage(mediaURL: mediaURL, image: initialImage)]
    }()
    self.galleryPages = pages
    let idx = max(0, min(startIndex, max(0, pages.count - 1)))
    self.galleryIndex = idx
    let page = pages[idx]
    self.mediaURL = page.mediaURL.isEmpty ? mediaURL : page.mediaURL
    self.initialImage = page.image ?? initialImage
    // Do NOT prefill bubble message text as caption — user adds caption only if they want.
    let _ = initialCaption
    self.initialCaption = ""
    self.captionText = ""
    let normalizedHeaderTitle = headerTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.headerTitleText = normalizedHeaderTitle.isEmpty ? "Photo" : normalizedHeaderTitle
    self.headerSubtitleText =
      headerSubtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.dismissPresenterOnSend = dismissPresenterOnSend
    self.startInEditMode = startInEditMode
    self.allowsFilmstrip = allowsFilmstrip
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }

  required init?(coder: NSCoder) { nil }

  deinit {
    remoteImageTask?.cancel()
    protectedTimer?.invalidate()
    NotificationCenter.default.removeObserver(self)
  }

  // MARK: Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    // Black comes from `backdropView`, not from the controller's view, so a
    // dismissal can drop it in one step and let the picture scale down over the
    // chat it is returning to.
    view.backgroundColor = .clear
    view.isOpaque = false
    backdropView.backgroundColor = .black
    view.addSubview(backdropView)

    // Sits under the markup stage and carries the neighbouring photos. Only the
    // current page's image view is hidden — the markup surface stands in for it
    // so drawings and AI edits stay attached to the picture they belong to.
    pagingScrollView.isPagingEnabled = true
    pagingScrollView.showsHorizontalScrollIndicator = false
    pagingScrollView.showsVerticalScrollIndicator = false
    pagingScrollView.alwaysBounceHorizontal = true
    pagingScrollView.backgroundColor = .clear
    pagingScrollView.delegate = self
    pagingScrollView.contentInsetAdjustmentBehavior = .never
    // While text is focused the scroll view ends at the keyboard, so this is the
    // same native soft bottom edge used by the chat transcript rather than a
    // full-photo blur overlay.
    pagingScrollView.topEdgeEffect.isHidden = true
    pagingScrollView.bottomEdgeEffect.style = .soft
    pagingScrollView.bottomEdgeEffect.isHidden = true
    view.addSubview(pagingScrollView)

    let chromeTap = UITapGestureRecognizer(target: self, action: #selector(handleChromeTap))
    pagingScrollView.addGestureRecognizer(chromeTap)

    dismissPan.delegate = self
    pagingScrollView.addGestureRecognizer(dismissPan)

    // The stage lives *inside* the scroll view so a drag that starts on the
    // photo is delivered to the paging pan recogniser. Hanging it off `view`
    // instead would swallow every swipe before the scroll view saw it.
    stageView.backgroundColor = .clear
    stageView.clipsToBounds = true
    pagingScrollView.addSubview(stageView)

    renderSurfaceView.backgroundColor = .black
    renderSurfaceView.clipsToBounds = true
    stageView.addSubview(renderSurfaceView)

    imageView.contentMode = .scaleAspectFit
    imageView.clipsToBounds = true
    imageView.backgroundColor = .clear
    // Full-bleed: no letterbox “wrapper” tint on the canvas. The stage stays clear
    // so a swipe-to-dismiss drags the picture alone — a black page background
    // would travel with it as a visible card.
    stageView.backgroundColor = .clear
    renderSurfaceView.backgroundColor = .clear
    renderSurfaceView.addSubview(imageView)

    canvasView.backgroundColor = .clear
    canvasView.isOpaque = false
    canvasView.drawingPolicy = .anyInput
    canvasView.delegate = self
    canvasView.isUserInteractionEnabled = false
    // Hide default PencilKit tool picker — we use SwiftUI chrome.
    canvasView.overrideUserInterfaceStyle = .dark
    renderSurfaceView.addSubview(canvasView)

    overlayContainer.backgroundColor = .clear
    overlayContainer.isUserInteractionEnabled = true
    renderSurfaceView.addSubview(overlayContainer)

    // Sits on the image at exactly the fitted rect, so its bounds map 1:1 onto
    // the picture. Hidden until the AI tab is selected.
    aiSelectionView.isHidden = true
    aiSelectionView.isUserInteractionEnabled = false
    aiSelectionView.onSelectionChanged = { [weak self] rect in
      guard let self else { return }
      self.markupModel.aiHasSelection = rect != nil
      self.markupHost.refresh()
    }
    renderSurfaceView.addSubview(aiSelectionView)

    setupTopBar()
    setupBottomBar()
    setupProtectedMediaUI()
    rebuildPages()
    loadImage()
    refreshHeaderForCurrentPage()
    applyToolFromModel()

    composerCancellable = composerModel.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async { self?.applyComposerAdjustmentsPreview() }
    }
    markupCancellable = markupModel.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async {
        guard let self else { return }
        self.applyToolFromModel()
        self.view.setNeedsLayout()
        // The AI tab and the tool tray are different heights, so the bar's frame
        // moves too. Left un-animated it snaps while the content inside is still
        // sliding — the two halves of one movement running on different clocks.
        let previousMode = self.lastAppliedMarkupMode
        self.lastAppliedMarkupMode = self.markupModel.mode
        guard previousMode != self.markupModel.mode else { return }
        UIView.animate(
          withDuration: 0.34, delay: 0, usingSpringWithDamping: 0.88,
          initialSpringVelocity: 0, options: [.beginFromCurrentState],
          animations: { self.view.layoutIfNeeded() })
      }
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(keyboardWillChangeFrame(_:)),
      name: UIResponder.keyboardWillChangeFrameNotification,
      object: nil
    )

    // PencilKit registers its own stroke undos on this manager without telling
    // us, so the arrows learn about a new stroke from the manager rather than
    // from the drawing.
    for name: NSNotification.Name in [
      .NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
      .NSUndoManagerDidRedoChange,
    ] {
      NotificationCenter.default.addObserver(
        self, selector: #selector(handleUndoStackChanged), name: name,
        object: undoManagerProxy)
    }

    // Long-press image to enter markup (tap Edit also works).
    let hold = UILongPressGestureRecognizer(target: self, action: #selector(handleImageHold(_:)))
    hold.minimumPressDuration = 0.35
    renderSurfaceView.addGestureRecognizer(hold)
    renderSurfaceView.isUserInteractionEnabled = true

    if startInEditMode, !isProtectedMediaPage {
      setMarkupActive(true, animated: false)
    } else {
      setMarkupActive(false, animated: false)
    }

    if isAttachComposer {
      headerHost.isHidden = true
      viewerBarHost.isHidden = true
      filmstrip.isHidden = true
      composerHost.isHidden = false
      composerModel.pickCount = max(1, galleryPages.count)
      composerModel.pageIndex = galleryIndex
      composerModel.recipientName = headerTitleText == "Photo" ? "" : headerTitleText
      composerHost.reloadChrome()
    }
  }

  private func setupProtectedMediaUI() {
    guard isProtectedMediaPage else {
      protectedTimerHost.isHidden = true
      return
    }
    protectedTimerHost.backgroundColor = UIColor.black.withAlphaComponent(0.48)
    protectedTimerHost.layer.cornerRadius = 15
    protectedTimerHost.isUserInteractionEnabled = false
    protectedTimerHost.isHidden = true
    protectedTimerTrack.backgroundColor = UIColor.white.withAlphaComponent(0.20)
    protectedTimerTrack.layer.cornerRadius = 1.5
    protectedTimerFill.backgroundColor = .systemOrange
    protectedTimerFill.layer.cornerRadius = 1.5
    protectedTimerIcon.tintColor = .systemOrange
    protectedTimerIcon.contentMode = .scaleAspectFit
    protectedTimerLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    protectedTimerLabel.textColor = .white
    protectedTimerLabel.textAlignment = .right
    protectedTimerHost.addSubview(protectedTimerIcon)
    protectedTimerHost.addSubview(protectedTimerLabel)
    protectedTimerHost.addSubview(protectedTimerTrack)
    protectedTimerTrack.addSubview(protectedTimerFill)
    view.addSubview(protectedTimerHost)
    bottomContainer.isHidden = true
    viewerBarHost.isHidden = true
    filmstrip.isHidden = true
    markupHost.isHidden = true
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    beginProtectedMediaIfReady()
  }

  private func beginProtectedMediaIfReady() {
    guard isProtectedMediaPage, imageView.image != nil, let page = currentPage else { return }
    let identity = page.messageId ?? "url:\(page.mediaURL)"
    if displayedProtectedMediaIds.insert(identity).inserted {
      onProtectedMediaDisplayed?(page.messageId, page.mediaTtlSeconds)
    }
    guard protectedTimer == nil, let seconds = page.mediaTtlSeconds, seconds > 0 else { return }
    protectedTimerDuration = TimeInterval(seconds)
    protectedTimerDeadline = CACurrentMediaTime() + protectedTimerDuration
    protectedTimerHost.isHidden = false
    let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      self?.tickProtectedMediaTimer()
    }
    protectedTimer = timer
    RunLoop.main.add(timer, forMode: .common)
    tickProtectedMediaTimer()
  }

  private func tickProtectedMediaTimer() {
    guard let deadline = protectedTimerDeadline, protectedTimerDuration > 0 else { return }
    let remaining = max(0, deadline - CACurrentMediaTime())
    let fraction = CGFloat(min(1, remaining / protectedTimerDuration))
    protectedTimerLabel.text = "\(max(0, Int(ceil(remaining))))s"
    protectedTimerFill.frame = CGRect(
      x: 0, y: 0, width: protectedTimerTrack.bounds.width * fraction,
      height: protectedTimerTrack.bounds.height)
    if remaining <= 0 { expireProtectedMedia() }
  }

  private func expireProtectedMedia() {
    guard !isProtectedExpiryCommitted else { return }
    isProtectedExpiryCommitted = true
    protectedTimer?.invalidate()
    protectedTimer = nil
    protectedTimerDeadline = nil
    remoteImageTask?.cancel()
    remoteImageTask = nil
    imageView.image = nil
    originalImage = nil
    composerOriginalImage = nil
    let expiredMessageId = currentPage?.messageId ?? messageId
    if galleryIndex >= 0, galleryIndex < galleryPages.count {
      let page = galleryPages[galleryIndex]
      galleryPages[galleryIndex] = ChatImageEditGalleryPage(
        mediaURL: page.mediaURL,
        image: nil,
        messageId: page.messageId,
        subtitle: page.subtitle,
        viewOnce: page.viewOnce,
        mediaTtlSeconds: page.mediaTtlSeconds,
        mediaKey: page.mediaKey)
      pageImageViews[safeIndex: galleryIndex]?.image = nil
    }
    protectedTimerHost.isHidden = true
    onProtectedMediaExpired?(expiredMessageId)
    UIView.animate(withDuration: 0.16, animations: {
      self.renderSurfaceView.alpha = 0
    }) { _ in
      self.dismiss(animated: false)
    }
  }

  @objc private func handleImageHold(_ gr: UILongPressGestureRecognizer) {
    guard gr.state == .began, !isMarkupActive, !isProtectedMediaPage else { return }
    setMarkupActive(true, animated: true)
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    applyThemeToChrome()
  }

  private func setupTopBar() {
    // The scrim remains content underneath the native glass surfaces.
    topContainer.backgroundColor = .clear
    view.addSubview(topContainer)

    headerHost.onClose = { [weak self] in self?.handleClose() }
    headerHost.onUndo = { [weak self] in self?.handleUndoTapped() }
    headerHost.onRedo = { [weak self] in self?.handleRedoTapped() }
    headerHost.onClearAll = { [weak self] in self?.handleClearAll() }
    headerHost.onAI = { [weak self] in self?.handleAITapped() }
    headerHost.onCancelText = { [weak self] in self?.handleTextCancel() }
    headerHost.onDoneText = { [weak self] in self?.handleTextDone() }
    headerHost.onShowInChat = { [weak self] in self?.emitAfterDismiss(.showInChat) }
    headerHost.onSave = { [weak self] in self?.handleSaveImage() }
    headerHost.onReply = { [weak self] in self?.emitAfterDismiss(.reply) }
    headerHost.onDelete = { [weak self] in self?.handleDeleteRequested() }
    view.addSubview(headerHost)

    composerHost.onClose = { [weak self] in self?.handleClose() }
    composerHost.onPick = { [weak self] in self?.handleComposerPickMore() }
    composerHost.onCrop = { [weak self] in self?.handleComposerCrop() }
    composerHost.onDraw = { [weak self] in
      self?.markupModel.mode = .draw
      self?.setMarkupActive(true, animated: true)
    }
    composerHost.onToggleAdjust = { [weak self] in
      guard let self else { return }
      self.composerModel.showAdjustments.toggle()
      if !self.composerModel.showAdjustments {
        self.applyComposerAdjustmentsPreview()
      }
      self.view.setNeedsLayout()
    }
    composerHost.onToggleHD = { [weak self] in
      guard let self else { return }
      self.isHighQuality.toggle()
      self.composerModel.isHighQuality = self.isHighQuality
    }
    composerHost.onSend = { [weak self] in self?.handleSend() }
    composerHost.isHidden = true
    view.addSubview(composerHost)

    applyThemeToChrome()
  }

  private func updateHeaderStack(animated: Bool) {
    let mode: ChatImageEditorHeaderMode =
      isTextEntryActive ? .text : (isMarkupActive ? .markup : .viewer)
    headerHost.setMode(mode, animated: animated)
  }

  private func setupBottomBar() {
    // Clear + scrim rather than a black plate: the photo now runs the full
    // height of the screen and the bar floats on top of it.
    bottomContainer.backgroundColor = .clear
    bottomScrim.colors = [
      UIColor.clear.cgColor,
      UIColor.black.withAlphaComponent(0.55).cgColor,
    ]
    bottomScrim.locations = [0, 1]
    view.addSubview(bottomContainer)
    // The viewer scrim is part of the viewer section, so it travels out with
    // that section instead of disappearing while the controls slide.
    bottomScrimHost.backgroundColor = .clear
    bottomScrimHost.isUserInteractionEnabled = false
    bottomScrimHost.layer.addSublayer(bottomScrim)
    bottomContainer.addSubview(bottomScrimHost)

    topScrim.colors = [
      UIColor.black.withAlphaComponent(0.45).cgColor,
      UIColor.clear.cgColor,
    ]
    topScrim.locations = [0, 1]
    topContainer.layer.insertSublayer(topScrim, at: 0)

    // The width paddle remains physically attached to the left bezel. Dragging
    // changes only its vertical value; its frame never follows the finger into
    // the picture.
    strokeSizeControl.strokeScale = markupModel.strokeScale
    strokeSizeControl.onStrokeScaleChanged = { [weak self] scale in
      guard let self else { return }
      self.markupModel.strokeScale = scale
      self.applyToolFromModel()
    }
    view.insertSubview(strokeSizeControl, belowSubview: topContainer)

    // View-mode bar: share · markup · AI · delete (ref #1)
    viewerBarHost.onShare = { [weak self] in self?.handleShare() }
    viewerBarHost.onMarkup = { [weak self] in
      guard let self else { return }
      self.markupModel.mode = .draw
      self.setMarkupActive(true, animated: true)
    }
    // AI from the viewer opens a field, not the editor. It used to switch markup
    // on, which meant asking a question about the photo dropped you into pens and
    // stickers you never asked for.
    viewerBarHost.onAI = { [weak self] in self?.setAIPromptActive(true) }
    viewerBarHost.onDelete = { [weak self] in self?.handleDeleteRequested() }
    bottomContainer.addSubview(viewerBarHost)

    captionField.isHidden = true
    captionField.delegate = self
    bottomContainer.addSubview(captionField)
    bottomContainer.addSubview(filmstrip)

    markupHost.onCancel = { [weak self] in
      self?.hideGifPanel()
      self?.endTextEntry(commit: false)
      self?.handleClearAll()
      self?.setMarkupActive(false, animated: true)
    }
    markupHost.onConfirm = { [weak self] in
      guard let self else { return }
      self.hideGifPanel()
      self.endTextEntry(commit: true)
      if self.hasVisualEdits() {
        self.handleSend()
      } else {
        self.setMarkupActive(false, animated: true)
      }
    }
    markupHost.onColorWheel = { [weak self] in self?.presentSystemColorPicker() }
    markupHost.onAddText = { [weak self] in self?.beginTextEntry() }
    markupHost.onOpenStickers = { [weak self] in self?.showGifPanel() }
    markupHost.onPickShape = { [weak self] kind in self?.addShape(kind) }
    bottomContainer.addSubview(markupHost)
    markupHost.isHidden = true

    // Sits on the view, not in `bottomContainer`: the bar tracks the keyboard,
    // and the bottom container tracks the chrome. Putting it in the container
    // would drag the chrome up with the keyboard.
    aiPromptBar.isHidden = true
    aiPromptBar.onSubmit = { [weak self] prompt in self?.handleAIGenerate(prompt: prompt) }
    aiPromptBar.onUndo = { [weak self] in self?.handleAIUndo() }
    aiPromptBar.onEndEditing = { [weak self] in
      guard let self else { return }
      // Not while an edit is running: `runAIEdit` puts the keyboard away itself,
      // and the bar has to stay to show that it is working.
      guard !self.markupModel.aiIsWorking else { return }
      self.setAIPromptActive(false)
    }
    view.addSubview(aiPromptBar)

    // GIF / sticker panel — starts off-screen bottom, slides up.
    gifPanelContainer.backgroundColor = UIColor(white: 0.12, alpha: 1)
    gifPanelContainer.isHidden = true
    gifPanelContainer.layer.cornerRadius = 18
    gifPanelContainer.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    gifPanelContainer.clipsToBounds = true
    view.addSubview(gifPanelContainer)

    gifGrabber.backgroundColor = UIColor.white.withAlphaComponent(0.35)
    gifGrabber.layer.cornerRadius = 2.5
    gifGrabber.isUserInteractionEnabled = true
    gifPanelContainer.addSubview(gifGrabber)
    // Grabber-only pan so scrolling inside the GIF panel still works.
    let grabPan = UIPanGestureRecognizer(target: self, action: #selector(handleGifGrabPan(_:)))
    gifGrabber.addGestureRecognizer(grabPan)

    // Focus treatment is a low-alpha wash only. Blurring the whole photo picked
    // up saturated colours from the image and turned the editor blue.
    textDimView.backgroundColor = UIColor.black.withAlphaComponent(0.11)
    textDimView.isHidden = true
    textDimView.alpha = 0
    view.addSubview(textDimView)

    textEntryField.isHidden = true
    textEntryField.textAlignment = .center
    textEntryField.textColor = .white
    textEntryField.font = .systemFont(ofSize: 28, weight: .bold)
    textEntryField.backgroundColor = .clear
    textEntryField.returnKeyType = .done
    textEntryField.delegate = self
    textEntryField.keyboardAppearance = .dark
    textEntryField.tintColor = .white
    textEntryField.autocorrectionType = .yes
    installTextKeyboardAccessory()
    view.addSubview(textEntryField)
  }

  private func installTextKeyboardAccessory() {
    let host = UIHostingController(
      rootView: ChatImageTextKeyboardBar(
        model: markupModel,
        onColor: { [weak self] in self?.presentSystemColorPicker() },
        onEmoji: { [weak self] in
          self?.textEntryField.resignFirstResponder()
          // Re-focus with emoji keyboard is OS-controlled; open sticker panel as fallback.
          self?.showGifPanel()
        }
      ))
    textKeyboardAccessoryBlur.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 44)
    // `.dark` is deliberately neutral. Semantic chrome material can borrow a
    // blue cast from a saturated photo, which made this row look selected.
    textKeyboardAccessoryBlur.contentView.backgroundColor = UIColor.black.withAlphaComponent(0.18)
    textKeyboardAccessoryBlur.overrideUserInterfaceStyle = .dark
    textKeyboardAccessoryBlur.tintColor = .white
    host.view.frame = textKeyboardAccessoryBlur.bounds
    host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    host.view.backgroundColor = .clear
    textKeyboardAccessoryBlur.contentView.addSubview(host.view)
    textKeyboardAccessoryHost = host
    textEntryField.inputAccessoryView = textKeyboardAccessoryBlur
  }

  private func applyThemeToChrome() {
    topContainer.backgroundColor = .clear
    headerHost.overrideUserInterfaceStyle = .dark
  }

  private func presentSystemColorPicker() {
    if #available(iOS 14.0, *) {
      let picker = UIColorPickerViewController()
      picker.selectedColor = markupModel.uiColor
      picker.supportsAlpha = true
      picker.delegate = self
      picker.modalPresentationStyle = .pageSheet
      if let sheet = picker.sheetPresentationController {
        sheet.detents = [.medium(), .large()]
        sheet.prefersGrabberVisible = true
      }
      present(picker, animated: true)
    }
  }

  // MARK: Layout

  /// The safe area, with the window's insets standing in until the view has its own.
  ///
  /// A full-screen presentation driven by a custom transition lays out at least
  /// once before its safe-area insets propagate, so the first pass put the bar
  /// 34pt lower than the second — the shift you see the moment the viewer opens.
  /// Taking the larger of the two never moves anything that was already right.
  private var resolvedSafeAreaInsets: UIEdgeInsets {
    var insets = view.safeAreaInsets
    guard let window = view.window else { return insets }
    insets.top = max(insets.top, window.safeAreaInsets.top)
    insets.bottom = max(insets.bottom, window.safeAreaInsets.bottom)
    return insets
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let safe = resolvedSafeAreaInsets
    let w = view.bounds.width
    let h = view.bounds.height

    backdropView.frame = view.bounds

    let topH = safe.top + 52
    setChromeFrame(topContainer, CGRect(x: 0, y: 0, width: w, height: topH))
    setChromeFrame(
      headerHost,
      CGRect(x: 0, y: safe.top, width: w, height: max(44, topH - safe.top)))
    if isProtectedMediaPage {
      let timerWidth = min(168, max(120, w - 40))
      protectedTimerHost.frame = CGRect(
        x: floor((w - timerWidth) * 0.5), y: topH + 5, width: timerWidth, height: 30)
      protectedTimerIcon.frame = CGRect(x: 10, y: 5, width: 18, height: 16)
      protectedTimerLabel.frame = CGRect(x: timerWidth - 50, y: 3, width: 40, height: 18)
      protectedTimerTrack.frame = CGRect(x: 10, y: 24, width: timerWidth - 20, height: 3)
      if let deadline = protectedTimerDeadline, protectedTimerDuration > 0 {
        let remaining = max(0, deadline - CACurrentMediaTime())
        let fraction = CGFloat(min(1, remaining / protectedTimerDuration))
        protectedTimerFill.frame = CGRect(
          x: 0, y: 0, width: protectedTimerTrack.bounds.width * fraction,
          height: protectedTimerTrack.bounds.height)
      }
    }
    if isAttachComposer {
      let composerBottomLift = keyboardHeight > 0 ? keyboardHeight : 0
      setChromeFrame(composerHost, view.bounds.inset(by: UIEdgeInsets(
        top: safe.top, left: 0, bottom: composerBottomLift, right: 0)))
      composerHost.isHidden = isMarkupActive
      headerHost.isHidden = !isMarkupActive
      viewerBarHost.isHidden = true
      view.bringSubviewToFront(composerHost)
    }
    refreshUndoRedoState()

    let markupH: CGFloat =
      isMarkupActive ? markupHost.preferredHeight(for: w) : 0
    let viewerH: CGFloat = isMarkupActive ? 0 : viewerBarHost.preferredHeight
    let viewerFilmH: CGFloat = showsFilmstrip ? 56 : 0
    let filmH: CGFloat = !isMarkupActive ? viewerFilmH : 0
    let baseGifH: CGFloat = min(320, h * 0.42)
    let maxGifH: CGFloat = min(h * 0.78, h - safe.top - 80)
    let gifH: CGFloat =
      isGifPanelVisible
      ? (baseGifH + (maxGifH - baseGifH) * gifPanelExpand)
      : 0
    let bottomContent = isMarkupActive ? markupH : (viewerH + filmH)
    // When GIF is open it replaces the markup strip height visually.
    let bottomTotal: CGFloat = {
      if isGifPanelVisible { return gifH + safe.bottom }
      return bottomContent + safe.bottom
    }()

    // Clear in both states. Editing used to swap in a black plate, which is what
    // made the bar read as a different app arriving rather than the same chrome
    // changing what it offers.
    bottomContainer.backgroundColor = .clear
    let naturalBottomMinY = h - bottomTotal
    if isGifPanelVisible {
      // Hide mode bar under panel; panel owns the bottom.
      setChromeFrame(
        bottomContainer, CGRect(x: 0, y: h, width: w, height: bottomContent + safe.bottom))
    } else {
      setChromeFrame(
        bottomContainer, CGRect(x: 0, y: naturalBottomMinY, width: w, height: bottomTotal))
    }

    // The top scrim belongs to the stationary header. The bottom scrim is hosted
    // with the viewer controls below, so it can share their slide.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    topScrim.frame = CGRect(x: 0, y: 0, width: w, height: topH + 28)
    topScrim.isHidden = isMarkupActive
    CATransaction.commit()

    // Both bars stay bottom-anchored while the container changes height.
    let containerH = bottomContainer.bounds.height
    let markupNaturalH = markupHost.preferredHeight(for: w)
    let markupFrame = CGRect(
      x: 0, y: containerH - safe.bottom - markupNaturalH, width: w, height: markupNaturalH)
    let viewerBarFrame = CGRect(
      x: 0, y: containerH - safe.bottom - viewerBarHost.preferredHeight, width: w,
      height: viewerBarHost.preferredHeight)
    setChromeFrame(markupHost, markupFrame)
    setChromeFrame(viewerBarHost, viewerBarFrame)

    let filmstripFrame = CGRect(
      x: 0,
      y: viewerBarFrame.minY - viewerFilmH,
      width: w,
      height: viewerFilmH)
    setChromeFrame(filmstrip, filmstripFrame)
    if showsFilmstrip { centerFilmstripContentIfNeeded() }

    let scrimFrame = CGRect(
      x: 0,
      y: viewerBarFrame.minY - viewerFilmH - 44,
      width: w,
      height: viewerBarHost.preferredHeight + viewerFilmH + safe.bottom + 44)
    setChromeFrame(bottomScrimHost, scrimFrame)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    bottomScrim.frame = bottomScrimHost.bounds
    bottomScrim.isHidden = false
    CATransaction.commit()

    // No alpha changes: the complete viewer section (including its scrim and
    // filmstrip) slides down as one unit while markup rises from below.
    let mainSlideOffset =
      viewerBarHost.preferredHeight + viewerFilmH + safe.bottom + 44
    let markupSlideOffset = markupNaturalH + safe.bottom + 12
    let showsViewer = !isMarkupActive && !isGifPanelVisible && !isAttachComposer && !isProtectedMediaPage
    setBottomControlVisible(
      bottomScrimHost, showsViewer, hiddenOffset: mainSlideOffset)
    setBottomControlVisible(
      viewerBarHost, showsViewer, hiddenOffset: mainSlideOffset)
    setBottomControlVisible(
      filmstrip, showsViewer && showsFilmstrip, hiddenOffset: mainSlideOffset)
    setBottomControlVisible(
      markupHost, isMarkupActive && !isGifPanelVisible, hiddenOffset: markupSlideOffset)

    // GIF panel: full width, bottom-aligned (slide animation sets transform separately)
    if isGifPanelVisible {
      gifPanelContainer.isHidden = false
      let panelH = gifH + safe.bottom
      gifPanelContainer.frame = CGRect(x: 0, y: h - panelH, width: w, height: panelH)
      gifGrabber.frame = CGRect(x: (w - 40) * 0.5, y: 8, width: 40, height: 5)
      gifPanel?.frame = CGRect(x: 0, y: 16, width: w, height: gifH - 8)
    }

    // The stage is the whole screen in every mode, so the picture never resizes.
    //
    // It used to inset itself between the bars while editing, which meant the
    // photo re-scaled every time a bar appeared, left, or changed height — the
    // whole surface heaving for a tab change. The reference never does that: the
    // image is aspect-fit to the screen once and the chrome floats on the
    // letterbox it leaves. Only the GIF panel, which genuinely owns the bottom
    // half, still pushes it.
    let stageTop: CGFloat = 0
    let stageBottom: CGFloat = isGifPanelVisible ? gifPanelContainer.frame.minY : h

    let pagingEnabled = layoutPages(width: w, height: h)
    // Stage coordinates are the scroll view's content space, so the stage sits
    // on its own page and travels with the swipe for free.
    let stageX: CGFloat = pagingEnabled ? CGFloat(galleryIndex) * w : 0
    setChromeFrame(
      stageView,
      CGRect(x: stageX, y: stageTop, width: w, height: max(1, stageBottom - stageTop)))

    let paddleHeight = min(210, max(168, h * 0.20))
    strokeSizeControl.frame = CGRect(
      x: -18,
      y: max(topH + 36, (h - paddleHeight) * 0.5),
      width: 52,
      height: paddleHeight)
    let showsStrokeSize =
      isMarkupActive && markupModel.mode == .draw && !isTextEntryActive && !isGifPanelVisible
    strokeSizeControl.isHidden = !showsStrokeSize
    strokeSizeControl.isUserInteractionEnabled = showsStrokeSize

    view.bringSubviewToFront(topContainer)
    view.bringSubviewToFront(bottomContainer)
    if isGifPanelVisible { view.bringSubviewToFront(gifPanelContainer) }
    view.bringSubviewToFront(headerHost)
    if !protectedTimerHost.isHidden { view.bringSubviewToFront(protectedTimerHost) }
    if isAttachComposer && !isMarkupActive {
      view.bringSubviewToFront(composerHost)
    }

    if let image = imageView.image, image.size.width > 1, image.size.height > 1 {
      let rect = fittingRect(container: stageView.bounds, mediaSize: image.size)
      renderSurfaceView.frame = rect
    } else {
      renderSurfaceView.frame = stageView.bounds
    }
    imageView.frame = renderSurfaceView.bounds
    canvasView.frame = renderSurfaceView.bounds
    overlayContainer.frame = renderSurfaceView.bounds
    aiSelectionView.frame = renderSurfaceView.bounds

    // The prompt bar is the one thing on screen that follows the keyboard. The
    // stage is deliberately not in this calculation: the picture keeps whatever
    // size it already had, and the field simply covers the bottom of it.
    aiPromptBar.isHidden = !isAIPromptActive
    if isAIPromptActive {
      let barH = ChatImageAIPromptBar.barHeight
      let lift = keyboardHeight > 0 ? keyboardHeight : safe.bottom
      aiPromptBar.frame = CGRect(x: 0, y: h - lift - barH - 2, width: w, height: barH)
      view.bringSubviewToFront(aiPromptBar)
    }

    textDimView.frame = view.bounds
    if isTextEntryActive {
      textDimView.isHidden = false
      textEntryField.isHidden = false
      // Sit directly above the accessory/keyboard join. The old 24pt air gap
      // made the input look detached from the keyboard.
      let keyboardTop = keyboardHeight > 0 ? h - keyboardHeight : h - 280
      let fieldY = max(stageTop + 40, keyboardTop - 56 - 6)
      textEntryField.frame = CGRect(x: 24, y: fieldY, width: w - 48, height: 56)
      view.bringSubviewToFront(textDimView)
      view.bringSubviewToFront(topContainer)
      view.bringSubviewToFront(headerHost)
      view.bringSubviewToFront(textEntryField)
    } else {
      textDimView.isHidden = true
      textEntryField.isHidden = true
    }
  }

  private func setBottomControlVisible(
    _ control: UIView,
    _ visible: Bool,
    hiddenOffset: CGFloat
  ) {
    control.isHidden = false
    control.alpha = 1
    control.transform =
      visible ? .identity : CGAffineTransform(translationX: 0, y: hiddenOffset)
    control.isUserInteractionEnabled = visible
  }

  // MARK: - Undo / redo

  /// Supplying the undo manager here is what puts PencilKit's stroke history,
  /// the overlay objects and the AI edits on one stack: `PKCanvasView` registers
  /// its undo actions with whatever the responder chain hands back, and without
  /// this that is nobody.
  override var undoManager: UndoManager? { undoManagerProxy }

  private func refreshUndoRedoState() {
    let canUndo = undoManagerProxy.canUndo
    let canRedo = undoManagerProxy.canRedo
    headerHost.updateUndo(canUndo: canUndo, canRedo: canRedo)
  }

  @objc private func handleUndoStackChanged() {
    refreshUndoRedoState()
  }

  @objc private func handleUndoTapped() {
    guard undoManagerProxy.canUndo else { return }
    undoManagerProxy.undo()
    refreshUndoRedoState()
  }

  @objc private func handleRedoTapped() {
    guard undoManagerProxy.canRedo else { return }
    undoManagerProxy.redo()
    refreshUndoRedoState()
  }

  /// Records an overlay object (text, sticker, shape) so undo takes it away and
  /// redo brings it back. Registering *during* an undo is how `UndoManager`
  /// learns the redo, so the two helpers call each other on purpose.
  private func registerOverlayInsert(_ subview: UIView) {
    undoManagerProxy.registerUndo(withTarget: self) { target in
      target.undoOverlayInsert(subview)
    }
    refreshUndoRedoState()
  }

  private func undoOverlayInsert(_ subview: UIView) {
    subview.removeFromSuperview()
    undoManagerProxy.registerUndo(withTarget: self) { target in
      target.overlayContainer.addSubview(subview)
      target.registerOverlayInsert(subview)
    }
    refreshUndoRedoState()
  }

  /// Records an image replacement (an AI edit) on the same stack, so the header
  /// arrow reverses it just like it reverses a stroke.
  private func registerImageChange(from previous: UIImage) {
    undoManagerProxy.registerUndo(withTarget: self) { target in
      let current = target.imageView.image
      target.applyImage(previous)
      UIView.transition(
        with: target.imageView, duration: 0.24, options: [.transitionCrossDissolve],
        animations: nil)
      if let current { target.registerImageChange(from: current) }
      target.refreshUndoRedoState()
    }
    refreshUndoRedoState()
  }

  /// Frame assignment that survives an active transform. The chrome carries a
  /// translation while it is hidden and the stage carries one while a swipe is
  /// in flight, and setting `.frame` under a transform is undefined.
  private func setChromeFrame(_ target: UIView, _ frame: CGRect) {
    let transform = target.transform
    guard !transform.isIdentity else {
      target.frame = frame
      return
    }
    target.transform = .identity
    target.frame = frame
    target.transform = transform
  }

  // MARK: - Paging

  private func rebuildPages() {
    pageImageViews.forEach { $0.removeFromSuperview() }
    pageImageViews = galleryPages.map { page in
      let imageView = UIImageView()
      imageView.contentMode = .scaleAspectFit
      imageView.clipsToBounds = true
      imageView.backgroundColor = .clear
      imageView.image = page.image
      pagingScrollView.addSubview(imageView)
      return imageView
    }
  }

  /// Returns whether horizontal paging is live for this pass.
  @discardableResult
  private func layoutPages(width: CGFloat, height: CGFloat) -> Bool {
    let focusBottomInset = isTextEntryActive ? keyboardHeight : 0
    pagingScrollView.frame = CGRect(
      x: 0,
      y: 0,
      width: width,
      height: max(1, height - focusBottomInset))
    pagingScrollView.bottomEdgeEffect.isHidden = !isTextEntryActive
    let pagingEnabled = showsPaging && !isMarkupActive && !isTextEntryActive
    if !isDismissDragging { pagingScrollView.isScrollEnabled = pagingEnabled }

    guard pagingEnabled else {
      // Collapse to a single page while editing so a stray drag cannot carry the
      // markup surface off the photo it belongs to.
      pagingScrollView.contentSize = CGSize(width: width, height: height)
      pagingScrollView.contentOffset = .zero
      pageImageViews.forEach { $0.isHidden = true }
      return false
    }

    let count = max(1, pageImageViews.count)
    pagingScrollView.contentSize = CGSize(width: width * CGFloat(count), height: height)

    for (index, pageView) in pageImageViews.enumerated() {
      pageView.frame = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: height)
      // The current page is drawn by the markup stage on top, so showing it here
      // as well would double the image during a swipe.
      pageView.isHidden = index == galleryIndex
    }

    if !pagingScrollView.isDragging, !pagingScrollView.isDecelerating {
      let target = CGPoint(x: CGFloat(galleryIndex) * width, y: 0)
      if abs(pagingScrollView.contentOffset.x - target.x) > 0.5 {
        pagingScrollView.contentOffset = target
      }
    }
    return true
  }

  private func commitPageChange() {
    let width = view.bounds.width
    guard width > 0, !galleryPages.isEmpty else { return }
    let index = max(
      0, min(galleryPages.count - 1, Int((pagingScrollView.contentOffset.x / width).rounded())))
    guard index != galleryIndex else {
      view.setNeedsLayout()
      return
    }
    selectPage(at: index)
  }

  /// Moves the editing surface onto another photo. Any markup on the page being
  /// left is dropped rather than silently carried across — strokes belong to the
  /// picture they were drawn on.
  private func selectPage(at index: Int, animated: Bool = false) {
    guard index >= 0, index < galleryPages.count else { return }
    galleryIndex = index
    let page = galleryPages[index]
    mediaURL = page.mediaURL
    composerOriginalImage = nil
    composerModel.pageIndex = index
    composerModel.pickCount = galleryPages.count
    canvasView.drawing = PKDrawing()
    overlayContainer.subviews.forEach { $0.removeFromSuperview() }
    aiUndoStack.removeAll()
    markupModel.aiCanUndo = false
    aiSelectionView.clearSelection()
    _ = animated

    if let image = page.image {
      applyImage(image)
    } else {
      imageView.image = nil
      loadImage()
    }

    refreshHeaderForCurrentPage()
    filmstrip.reloadData()
    centerFilmstripContentIfNeeded()
    view.setNeedsLayout()
  }

  // MARK: - Paging scroll delegate
  //
  // The filmstrip is a `UICollectionView` on the same delegate, so every one of
  // these has to check which scroll view is talking.

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    guard scrollView === pagingScrollView else { return }
    commitPageChange()
  }

  func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
    guard scrollView === pagingScrollView else { return }
    commitPageChange()
  }

  func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    guard scrollView === pagingScrollView, !decelerate else { return }
    commitPageChange()
  }

  // MARK: - Chrome visibility

  @objc private func handleChromeTap() {
    // Tapping the picture while the prompt is up puts it away, the way tapping
    // outside any field does. Toggling the chrome instead would leave the
    // keyboard stranded over a bar that just left.
    if isAIPromptActive {
      setAIPromptActive(false)
      return
    }
    guard !isMarkupActive, !isTextEntryActive, !isGifPanelVisible else { return }
    setChromeHidden(!isChromeHidden, animated: true)
  }

  /// The chrome fades out where it stands; it does not slide off the edges.
  ///
  /// A translation moves the bars *through* the photo on the way out, which is
  /// the movement the picture is not supposed to have any part in. Full-screen
  /// media viewers — the system's included — take their chrome away in place.
  /// The glass goes with `effect`, per Apple's guidance to prefer that over
  /// `alpha`, so the pills dematerialize instead of ghosting.
  private func setChromeHidden(_ hidden: Bool, animated: Bool) {
    guard isChromeHidden != hidden else { return }
    isChromeHidden = hidden

    let changes = {
      self.topContainer.alpha = hidden ? 0 : 1
      self.headerHost.alpha = hidden ? 0 : 1
      self.headerHost.isUserInteractionEnabled = !hidden
      self.bottomContainer.alpha = hidden ? 0 : 1
      self.view.setNeedsLayout()
      self.view.layoutIfNeeded()
    }

    if animated {
      UIView.animate(
        withDuration: 0.26, delay: 0,
        options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
        animations: changes)
    } else {
      changes()
    }
  }

  // MARK: - Swipe to dismiss

  @objc private func handleDismissPan(_ gr: UIPanGestureRecognizer) {
    guard !isMarkupActive, !isTextEntryActive, !isGifPanelVisible, !isAIPromptActive else {
      return
    }
    let translation = gr.translation(in: view)

    switch gr.state {
    case .began:
      isDismissDragging = true
      pagingScrollView.isScrollEnabled = false

    case .changed:
      if !hasCommittedDragEffects, abs(translation.x) + abs(translation.y) > 8 {
        beginDragEffects()
      }
      let reach = max(1, view.bounds.height * 0.5)
      let progress = min(1, max(0, abs(translation.y) / reach))
      let scale = 1 - progress * 0.35
      stageView.transform = CGAffineTransform(translationX: translation.x, y: translation.y)
        .scaledBy(x: scale, y: scale)

    case .ended, .cancelled, .failed:
      isDismissDragging = false
      let velocity = gr.velocity(in: view)
      let committed =
        gr.state == .ended && hasCommittedDragEffects
        && (abs(translation.y) > 110 || abs(velocity.y) > 900)
      if committed {
        dismiss(animated: true)
        return
      }
      pagingScrollView.isScrollEnabled = showsPaging && !isMarkupActive && !isTextEntryActive
      guard hasCommittedDragEffects else { return }
      endDragEffects()
      UIView.animate(
        withDuration: 0.34, delay: 0, usingSpringWithDamping: 0.82,
        initialSpringVelocity: 0,
        options: [.beginFromCurrentState, .allowUserInteraction],
        animations: { self.stageView.transform = .identity })

    default:
      break
    }
  }

  private func beginDragEffects() {
    hasCommittedDragEffects = true
    chromeWasHiddenBeforeDrag = isChromeHidden
    setChromeHidden(true, animated: true)
    backdropView.isHidden = true
    zoomTransition?.sourceProvider?.chatMediaZoomSetSourceHidden(
      true, forMessageId: currentMessageId, pageIndex: galleryIndex)
  }

  private func endDragEffects() {
    hasCommittedDragEffects = false
    backdropView.isHidden = false
    zoomTransition?.sourceProvider?.chatMediaZoomSetSourceHidden(
      false, forMessageId: currentMessageId, pageIndex: galleryIndex)
    if !chromeWasHiddenBeforeDrag { setChromeHidden(false, animated: true) }
  }

  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer === dismissPan else { return true }
    guard !isMarkupActive, !isTextEntryActive, !isGifPanelVisible else { return false }
    let velocity = dismissPan.velocity(in: view)
    return abs(velocity.y) > abs(velocity.x)
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool {
    gestureRecognizer === dismissPan || other === dismissPan
  }

  // MARK: - Overflow menu

  private func makeOverflowMenu() -> UIMenu {
    var actions: [UIMenuElement] = []

    if currentMessageId != nil {
      actions.append(
        UIAction(
          title: "Show in Chat",
          image: UIImage(systemName: "bubble.left.and.text.bubble.right")
        ) { [weak self] _ in
          self?.emitAfterDismiss(.showInChat)
        })
    }

    actions.append(
      UIAction(title: "Save Image", image: UIImage(systemName: "square.and.arrow.down")) {
        [weak self] _ in
        self?.handleSaveImage()
      })

    if currentMessageId != nil {
      actions.append(
        UIAction(title: "Reply", image: UIImage(systemName: "arrowshape.turn.up.left")) {
          [weak self] _ in
          self?.emitAfterDismiss(.reply)
        })
      actions.append(
        UIAction(
          title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive
        ) { [weak self] _ in
          self?.handleDeleteRequested()
        })
    }

    return UIMenu(children: actions)
  }

  private func handleDeleteRequested() {
    guard currentMessageId != nil else {
      handleClose()
      return
    }
    emitAfterDismiss(.delete)
  }

  /// Menu actions that hand the chat back control — reply, delete, jump to the
  /// message — fire *after* the viewer is off screen. `emit` reports first and
  /// dismisses second, which would tear down any sheet the chat then presents.
  private func emitAfterDismiss(_ eventType: ChatImageEditEventType) {
    let payload = ChatImageEditActionPayload(
      eventType: eventType,
      messageId: currentMessageId,
      mediaURL: mediaURL,
      caption: nil,
      editedImageURL: nil
    )
    let action = onAction
    hideGifPanel()
    endTextEntry(commit: false)
    dismiss(animated: true) { action?(payload) }
  }

  private func handleSaveImage() {
    if galleryPages[safeIndex: galleryIndex]?.viewOnce == true {
      presentToast("This photo can't be saved")
      return
    }
    guard let image = snapshotEditedImage() ?? imageView.image else { return }
    UIImageWriteToSavedPhotosAlbum(
      image, self,
      #selector(handleSaveFinished(_:didFinishSavingWithError:contextInfo:)), nil)
  }

  @objc private func handleSaveFinished(
    _ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer?
  ) {
    presentToast(error == nil ? "Saved to Photos" : "Couldn't save this photo")
  }

  private func presentToast(_ text: String) {
    let label = PaddedLabel()
    label.text = text
    label.font = .systemFont(ofSize: 14, weight: .semibold)
    label.textColor = .white
    label.textAlignment = .center
    label.backgroundColor = UIColor(white: 0.1, alpha: 0.92)
    label.layer.cornerRadius = 18
    label.layer.cornerCurve = .continuous
    label.clipsToBounds = true
    label.alpha = 0
    view.addSubview(label)

    let size = label.intrinsicContentSize
    label.frame = CGRect(
      x: (view.bounds.width - size.width) * 0.5,
      y: view.bounds.height - view.safeAreaInsets.bottom - 140,
      width: size.width,
      height: 36)

    UIView.animate(withDuration: 0.22) { label.alpha = 1 }
    UIView.animate(
      withDuration: 0.28, delay: 1.6, options: [.curveEaseIn],
      animations: { label.alpha = 0 },
      completion: { _ in label.removeFromSuperview() })
  }

  private func fittingRect(container: CGRect, mediaSize: CGSize) -> CGRect {
    let scale = min(
      container.width / max(mediaSize.width, 1),
      container.height / max(mediaSize.height, 1))
    let fitted = CGSize(width: mediaSize.width * scale, height: mediaSize.height * scale)
    return CGRect(
      x: container.minX + (container.width - fitted.width) * 0.5,
      y: container.minY + (container.height - fitted.height) * 0.5,
      width: fitted.width,
      height: fitted.height
    )
  }

  // MARK: Markup mode

  /// Enter/leave markup. The standalone navigation bar owns the header push/pop;
  /// only the tool content below it uses a layout animator.
  private func setMarkupActive(_ active: Bool, animated: Bool) {
    // Tools are useless behind hidden chrome, so entering or leaving markup
    // always brings the bars back.
    setChromeHidden(false, animated: animated)

    markupLayoutAnimator?.stopAnimation(true)
    markupLayoutAnimator = nil

    isMarkupActive = active
    markupModel.isEditing = active
    if active {
      markupModel.mode = .draw
    } else {
      hideGifPanel()
      endTextEntry(commit: false)
    }
    canvasView.isUserInteractionEnabled = active && markupModel.mode == .draw
    overlayContainer.isUserInteractionEnabled = active
    applyToolFromModel()
    markupHost.refresh()
    updateHeaderStack(animated: animated)

    let changes = {
      self.view.setNeedsLayout()
      self.view.layoutIfNeeded()
    }

    guard animated else {
      changes()
      return
    }

    let duration = max(TimeInterval(UINavigationController.hideShowBarDuration), 0.32)
    let animator = UIViewPropertyAnimator(duration: duration, curve: .easeInOut, animations: changes)
    animator.addCompletion { [weak self] _ in self?.markupLayoutAnimator = nil }
    markupLayoutAnimator = animator
    animator.startAnimation()
  }

  private func applyToolFromModel() {
    guard isMarkupActive else {
      canvasView.isUserInteractionEnabled = false
      setAISelectionActive(false)
      return
    }
    switch markupModel.mode {
    case .draw:
      setAISelectionActive(false)
      canvasView.isUserInteractionEnabled = true
      overlayContainer.isUserInteractionEnabled = false
      // Native inks, our picker: the strokes are `PKInkingTool`, only the row
      // that chooses between them is ours.
      canvasView.tool =
        markupModel.drawTool == .eraser
        ? PKEraserTool(.vector) as PKTool
        : markupModel.makeInk() as PKTool
    case .text, .sticker:
      setAISelectionActive(false)
      canvasView.isUserInteractionEnabled = false
      overlayContainer.isUserInteractionEnabled = true
    case .ai:
      // Drawing and overlay editing are muted so a drag reads as a region
      // selection rather than a stroke.
      canvasView.isUserInteractionEnabled = false
      overlayContainer.isUserInteractionEnabled = false
      setAISelectionActive(true)
    }
  }

  private func setAISelectionActive(_ active: Bool) {
    guard aiSelectionView.isHidden == active || aiSelectionView.isUserInteractionEnabled != active
    else { return }
    aiSelectionView.isUserInteractionEnabled = active
    if !active { aiSelectionView.clearSelection() }

    if active {
      aiSelectionView.isHidden = false
      aiSelectionView.alpha = 0
      renderSurfaceView.bringSubviewToFront(aiSelectionView)
      UIView.animate(withDuration: 0.22) { self.aiSelectionView.alpha = 1 }
    } else {
      UIView.animate(
        withDuration: 0.18,
        animations: { self.aiSelectionView.alpha = 0 },
        completion: { _ in self.aiSelectionView.isHidden = true })
    }
  }

  // MARK: AI edit

  private func handleAIGenerate(prompt rawPrompt: String) {
    let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty, !markupModel.aiIsWorking else { return }
    guard let source = imageView.image else { return }
    markupModel.aiPrompt = prompt

    // Disclosure before a single byte leaves the device.
    ChatAIMediaConsent.ensureConsent(for: .openAI, from: self) { [weak self] accepted in
      guard let self, accepted else { return }
      self.runAIEdit(prompt: prompt, source: source)
    }
  }

  private func runAIEdit(prompt: String, source: UIImage) {
    // Upload the picture at a size the editor actually works at. A full-res
    // camera frame re-encoded as PNG is tens of megabytes: the upload alone ate
    // most of the request window, which is why edits appeared to run forever and
    // then quietly time out.
    let upload = Self.normalizedForUpload(source)
    guard let imageData = upload.pngData() else { return }
    let maskData = aiSelectionView.normalizedSelection.flatMap {
      Self.makeMaskPNG(imageSize: upload.size, scale: upload.scale, normalizedHole: $0)
    }

    markupModel.aiIsWorking = true
    aiPromptBar.isWorking = true
    markupHost.refresh()
    view.endEditing(true)

    // The picture carries its own wait: blurred in place, with a shine running
    // its edge and the clock counting. A spinner in the bar said the app was
    // busy but never which picture, nor for how long.
    presentAIProcessingOverlay(over: source)

    aiTask?.cancel()
    aiTask = Task { [weak self] in
      do {
        let edited = try await ChatAIMediaEditService.editImage(
          image: imageData,
          mimeType: "image/png",
          mask: maskData,
          prompt: prompt
        )
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard let self else { return }
          self.finishAIEdit(with: UIImage(data: edited.data), error: nil, previous: source)
        }
      } catch {
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard let self else { return }
          self.finishAIEdit(with: nil, error: error, previous: source)
        }
      }
    }
  }

  /// Largest edge the editor is given. `gpt-image-2` renders at its own sizes
  /// anyway, so anything beyond this is upload cost with nothing to show for it.
  private static let aiUploadMaxEdge: CGFloat = 2048.0

  private static func normalizedForUpload(_ image: UIImage) -> UIImage {
    let pixelSize = CGSize(
      width: image.size.width * image.scale, height: image.size.height * image.scale)
    let longest = max(pixelSize.width, pixelSize.height)
    guard longest > aiUploadMaxEdge else {
      // Still redrawn: a rotated image carries its orientation in metadata, and
      // the mask is built in flat pixel space, so the two would not line up.
      return redraw(image, pixelSize: pixelSize)
    }
    let ratio = aiUploadMaxEdge / longest
    return redraw(
      image,
      pixelSize: CGSize(
        width: (pixelSize.width * ratio).rounded(), height: (pixelSize.height * ratio).rounded()))
  }

  private static func redraw(_ image: UIImage, pixelSize: CGSize) -> UIImage {
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1.0
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
    return renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: pixelSize))
    }
  }

  private func presentAIProcessingOverlay(over source: UIImage) {
    aiProcessingOverlay.onCancel = { [weak self] in self?.cancelAIEdit() }
    aiProcessingOverlay.setCaption("Editing with AI")
    // Exactly the fitted picture, in the controller's coordinates — the letterbox
    // around it is not part of what is being edited and should not be blurred.
    let rect = renderSurfaceView.convert(renderSurfaceView.bounds, to: view)
    aiProcessingOverlay.present(
      in: view,
      over: rect,
      shape: .rect(cornerRadius: 0),
      frame: source,
      detail: "Sent to OpenAI · this step is not end-to-end encrypted")
  }

  private func cancelAIEdit() {
    guard markupModel.aiIsWorking else { return }
    aiTask?.cancel()
    aiTask = nil
    markupModel.aiIsWorking = false
    aiPromptBar.isWorking = false
    aiProcessingOverlay.dismiss()
    markupHost.refresh()
  }

  private func finishAIEdit(with image: UIImage?, error: Error?, previous: UIImage) {
    markupModel.aiIsWorking = false
    aiPromptBar.isWorking = false
    aiProcessingOverlay.dismiss()

    if let image {
      aiUndoStack.append(previous)
      markupModel.aiCanUndo = true
      markupModel.aiPrompt = ""
      aiPromptBar.text = ""
      aiPromptBar.canUndo = true
      aiSelectionView.clearSelection()
      // On the same stack as strokes and stickers, so the header arrow reverses
      // an AI edit too.
      registerImageChange(from: previous)
      applyImage(image)
      UIView.transition(
        with: imageView, duration: 0.28, options: [.transitionCrossDissolve], animations: nil)
    } else {
      let message =
        (error as? LocalizedError)?.errorDescription ?? "That edit didn't go through."
      presentAIError(message)
    }

    markupHost.refresh()
  }

  private func handleAIUndo() {
    guard let previous = aiUndoStack.popLast() else { return }
    markupModel.aiCanUndo = !aiUndoStack.isEmpty
    aiPromptBar.canUndo = markupModel.aiCanUndo
    applyImage(previous)
    UIView.transition(
      with: imageView, duration: 0.24, options: [.transitionCrossDissolve], animations: nil)
    markupHost.refresh()
  }

  private func presentAIError(_ message: String) {
    let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }

  /// Builds the OpenAI edit mask: opaque everywhere, **transparent over the
  /// region to replace**, at the source image's pixel dimensions.
  private static func makeMaskPNG(
    imageSize: CGSize, scale: CGFloat, normalizedHole: CGRect
  ) -> Data? {
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = scale
    format.opaque = false

    let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)
    let image = renderer.image { ctx in
      UIColor.black.setFill()
      ctx.fill(CGRect(origin: .zero, size: imageSize))

      let hole = CGRect(
        x: normalizedHole.minX * imageSize.width,
        y: normalizedHole.minY * imageSize.height,
        width: normalizedHole.width * imageSize.width,
        height: normalizedHole.height * imageSize.height)

      ctx.cgContext.setBlendMode(.clear)
      ctx.cgContext.fill(hole)
    }
    return image.pngData()
  }

  // MARK: Image load

  private func loadImage() {
    let page = galleryPages[safeIndex: galleryIndex]
    let isProtectedMedia = page?.viewOnce == true
    let mediaKey = page?.mediaKey
    if let pageImage = page?.image {
      applyImage(pageImage)
      return
    }
    if let initialImage, galleryPages.count <= 1 {
      applyImage(initialImage)
      return
    }
    let trimmed = mediaURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    if let parsed = URL(string: trimmed), parsed.isFileURL {
      if let image = UIImage(contentsOfFile: parsed.path) { applyImage(image) }
      return
    }
    if trimmed.hasPrefix("/"), let image = UIImage(contentsOfFile: trimmed) {
      applyImage(image)
      return
    }
    if !isProtectedMedia, let diskData = chatMediaDiskCacheLoad(trimmed),
      let diskImage = UIImage(data: diskData)
    {
      applyImage(diskImage)
      return
    }
    guard let remoteURL = URL(string: trimmed) else { return }
    remoteImageTask?.cancel()
    let requestedMessageId = page?.messageId
    remoteImageTask = VibeHTTP.shared.dataTask(with: remoteURL) { [weak self] data, _, _ in
      guard let self, let data,
        let clearData = ChatEngine.shared.decryptMediaDataIfNeeded(data, mediaKey: mediaKey),
        let image = UIImage(data: clearData)
      else { return }
      if !isProtectedMedia { chatMediaDiskCacheSave(clearData, forKey: trimmed) }
      DispatchQueue.main.async {
        let currentPage = self.galleryPages[safeIndex: self.galleryIndex]
        guard currentPage?.messageId == requestedMessageId, self.mediaURL == trimmed else { return }
        self.applyImage(image)
      }
    }
    remoteImageTask?.resume()
  }

  private func applyImage(_ image: UIImage) {
    if composerOriginalImage == nil || !composerModel.hasAdjustments {
      composerOriginalImage = image
    }
    originalImage = image
    imageView.image = image
    // Keep the page cache in step so swiping away and back shows what the user
    // is actually looking at, edits included.
    if galleryIndex >= 0, galleryIndex < galleryPages.count {
      let page = galleryPages[galleryIndex]
      galleryPages[galleryIndex] = ChatImageEditGalleryPage(
        mediaURL: page.mediaURL,
        image: image,
        messageId: page.messageId,
        subtitle: page.subtitle,
        viewOnce: page.viewOnce,
        mediaTtlSeconds: page.mediaTtlSeconds,
        mediaKey: page.mediaKey)
      if galleryIndex < pageImageViews.count {
        pageImageViews[galleryIndex].image = image
      }
    }
    view.setNeedsLayout()
    if view.window != nil { beginProtectedMediaIfReady() }
  }

  /// Message the *current page* came from. Swiping moves between messages, so
  /// Reply / Delete / Show in Chat must target the photo on screen.
  private var currentMessageId: String? {
    galleryPages[safeIndex: galleryIndex]?.messageId ?? messageId
  }

  private func refreshHeaderForCurrentPage() {
    let subtitle =
      galleryPages[safeIndex: galleryIndex]?.subtitle?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? headerSubtitleText
    headerHost.updatePage(
      title: headerTitleText,
      subtitle: subtitle,
      hasMessage: currentMessageId != nil)
    headerHost.model.allowsActions = !isProtectedMediaPage
  }

  // MARK: Snapshot + send

  private func hasVisualEdits() -> Bool {
    // An AI edit replaces the image itself and leaves no stroke or overlay
    // behind, so it has to count here or confirm would silently discard it.
    !canvasView.drawing.strokes.isEmpty || !overlayContainer.subviews.isEmpty
      || !aiUndoStack.isEmpty
      || (isAttachComposer && composerModel.hasAdjustments)
  }

  private func snapshotEditedImage() -> UIImage? {
    guard let displayed = imageView.image else { return nil }
    let base: UIImage = {
      guard isAttachComposer, composerModel.hasAdjustments else { return displayed }
      let source = composerOriginalImage ?? displayed
      return ChatAttachImageAdjust.apply(
        source,
        brightness: composerModel.brightness,
        contrast: composerModel.contrast,
        saturation: composerModel.saturation)
    }()
    // Flatten image + PencilKit drawing + overlays into one image at base pixel size.
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = base.scale
    let size = base.size
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    return renderer.image { ctx in
      base.draw(in: CGRect(origin: .zero, size: size))
      let drawing = canvasView.drawing
      if !drawing.strokes.isEmpty {
        let bounds = canvasView.bounds
        if bounds.width > 1, bounds.height > 1 {
          let pkImage = drawing.image(from: bounds, scale: format.scale)
          pkImage.draw(in: CGRect(origin: .zero, size: size))
        }
      }
      // Render overlays (text/stickers) scaled from view coords → image coords.
      if !overlayContainer.subviews.isEmpty,
        overlayContainer.bounds.width > 1,
        overlayContainer.bounds.height > 1
      {
        let sx = size.width / overlayContainer.bounds.width
        let sy = size.height / overlayContainer.bounds.height
        ctx.cgContext.saveGState()
        ctx.cgContext.scaleBy(x: sx, y: sy)
        overlayContainer.layer.render(in: ctx.cgContext)
        ctx.cgContext.restoreGState()
      }
    }
  }

  private func writeJPEGToTemp(_ image: UIImage) -> URL? {
    let maxDimension: CGFloat = isHighQuality ? 2048 : 1440
    let scale = min(1.0, maxDimension / max(image.size.width, image.size.height, 1))
    let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: target))
    }
    guard let data = resized.jpegData(compressionQuality: isHighQuality ? 0.88 : 0.78) else {
      return nil
    }
    return VibeMediaVault.shared.persistOutgoingPick(data: data, fileExtension: "jpg")
  }

  private func emit(_ eventType: ChatImageEditEventType) {
    captionText = captionField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let editedImageURL: URL? = {
      if hasVisualEdits(), let snapshot = snapshotEditedImage() {
        return writeJPEGToTemp(snapshot)
      }
      // Resend without edits: still provide a local file if we only have a UIImage seed.
      if let originalImage, mediaURL.isEmpty || mediaURL.hasPrefix("file") == false {
        // Prefer original remote mediaURL for resend when no visual edits.
        if eventType == .resend { return nil }
      }
      if hasVisualEdits() == false, eventType == .sendNew, let originalImage {
        return writeJPEGToTemp(originalImage)
      }
      if hasVisualEdits(), let originalImage {
        return writeJPEGToTemp(originalImage)
      }
      return nil
    }()

    // Always attach snapshot when user was in markup and has strokes/overlays.
    let finalEdited: URL? = {
      if let editedImageURL { return editedImageURL }
      if hasVisualEdits(), let snap = snapshotEditedImage() {
        return writeJPEGToTemp(snap)
      }
      return nil
    }()

    let extraURLs: [URL] = {
      guard isAttachComposer, galleryPages.count > 1 else { return [] }
      return galleryPages.enumerated().compactMap { index, page in
        if index == galleryIndex { return nil }
        if let image = page.image { return writeJPEGToTemp(image) }
        if page.mediaURL.hasPrefix("file"), let url = URL(string: page.mediaURL) { return url }
        return nil
      }
    }()
    if isAttachComposer {
      ChatAttachSendContext.pending = ChatAttachmentSendOptions.from(
        composerModel.keepPolicy, highQuality: isHighQuality)
      captionText = composerModel.caption.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    onAction?(
      ChatImageEditActionPayload(
        eventType: eventType,
        messageId: currentMessageId,
        mediaURL: mediaURL,
        caption: captionText.isEmpty ? nil : captionText,
        editedImageURL: finalEdited,
        extraImageURLs: extraURLs,
        viewOnce: isAttachComposer ? composerModel.keepPolicy.viewOnce : false,
        mediaTtlSeconds: isAttachComposer ? composerModel.keepPolicy.mediaTtlSeconds : nil,
        isHighQuality: isHighQuality
      ))

    let shouldDismissPresenter = dismissPresenterOnSend && eventType == .sendNew
    let dismissTarget = shouldDismissPresenter ? (presentingViewController ?? self) : self
    dismissTarget.dismiss(animated: true)
  }

  // MARK: Actions

  @objc private func handleClose() {
    hideGifPanel()
    endTextEntry(commit: false)
    dismiss(animated: true)
  }

  /// AI puts the cursor in a field. That is all it does — it does not switch the
  /// editor on, does not swap the bottom bar for tool tabs, and does not resize
  /// the picture. Routing it through markup meant asking a question lit the whole
  /// editing surface up and shrank the photo behind it.
  @objc private func handleAITapped() {
    setAIPromptActive(true)
  }

  private func setAIPromptActive(_ active: Bool) {
    guard isAIPromptActive != active else { return }
    isAIPromptActive = active

    if active {
      aiPromptBar.text = markupModel.aiPrompt
      aiPromptBar.isWorking = markupModel.aiIsWorking
      aiPromptBar.canUndo = markupModel.aiCanUndo
      aiPromptBar.isHidden = false
      // Laid out before it takes the keyboard, so it rises from the right place
      // instead of snapping into position once the frame notification lands.
      view.setNeedsLayout()
      view.layoutIfNeeded()
      applyToolFromModel()
      aiPromptBar.becomeFirstResponder()
    } else {
      markupModel.aiPrompt = aiPromptBar.text
      aiPromptBar.resignFirstResponder()
      aiPromptBar.isHidden = true
      applyToolFromModel()
      view.setNeedsLayout()
    }
  }

  @objc private func handleEditToggle() {
    setMarkupActive(!isMarkupActive, animated: true)
  }

  @objc private func handleClearAll() {
    canvasView.drawing = PKDrawing()
    overlayContainer.subviews.forEach { $0.removeFromSuperview() }
    // Clear All is not one step back — it throws the whole session away, so the
    // step-by-step history it was built from goes with it rather than being left
    // pointing at objects that are no longer on the picture.
    undoManagerProxy.removeAllActions()
    refreshUndoRedoState()
  }

  /// Forwards through the app's own share sheet — the chat picker the selection
  /// bar opens — rather than the system activity sheet. Falls back to the system
  /// sheet only when there is no message to forward (the pre-send editor), where
  /// there is nothing in the chat to point the picker at.
  private func handleShare() {
    guard currentMessageId != nil else {
      var items: [Any] = []
      let trimmed = mediaURL.trimmingCharacters(in: .whitespacesAndNewlines)
      if !hasVisualEdits(), !trimmed.isEmpty, let url = URL(string: trimmed) {
        items.append(url)
      } else if let image = snapshotEditedImage() ?? imageView.image {
        items.append(image)
      }
      guard !items.isEmpty else { return }

      let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
      if let popover = activity.popoverPresentationController {
        popover.sourceView = viewerBarHost
        popover.sourceRect = CGRect(
          x: 44, y: viewerBarHost.bounds.midY, width: 1, height: 1)
      }
      present(activity, animated: true)
      return
    }
    emitAfterDismiss(.share)
  }

  // MARK: - GIF / sticker panel (slide up from bottom, expandable)

  private func showGifPanel() {
    if gifPanel == nil {
      let panel = ChatGifPanelView()
      panel.delegate = self
      // Required for GiphyGridController embed (same as ChatInputBar).
      panel.hostViewController = self
      gifPanelContainer.insertSubview(panel, belowSubview: gifGrabber)
      gifPanel = panel
    } else {
      gifPanel?.hostViewController = self
    }
    markupModel.mode = .sticker
    markupHost.refresh()
    endTextEntry(commit: false)

    // Size at bottom first (real non-zero frame), activate Giphy, then short slide-up.
    isGifPanelVisible = true
    gifPanelExpand = 0
    gifPanelContainer.isHidden = false
    gifPanelContainer.transform = .identity
    gifPanelContainer.alpha = 1
    view.setNeedsLayout()
    view.layoutIfNeeded()

    gifPanel?.setPanelVisible(true)
    gifPanel?.prepareIfNeeded()
    gifPanel?.setNeedsLayout()
    gifPanel?.layoutIfNeeded()

    let offset = max(24, min(56, max(gifPanelContainer.bounds.height, 280) * 0.12))
    gifPanelContainer.transform = CGAffineTransform(translationX: 0, y: offset)
    gifPanelContainer.alpha = 0
    UIView.animate(
      withDuration: 0.28,
      delay: 0,
      options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      self.gifPanelContainer.transform = .identity
      self.gifPanelContainer.alpha = 1
    }
  }

  private func hideGifPanel() {
    guard isGifPanelVisible else { return }
    let h = view.bounds.height
    UIView.animate(
      withDuration: 0.28,
      delay: 0,
      options: [.curveEaseIn, .allowUserInteraction]
    ) {
      self.gifPanelContainer.transform = CGAffineTransform(translationX: 0, y: h * 0.55)
    } completion: { _ in
      self.isGifPanelVisible = false
      self.gifPanelExpand = 0
      self.gifPanelContainer.transform = .identity
      self.gifPanelContainer.isHidden = true
      self.gifPanel?.setPanelVisible(false)
      self.view.setNeedsLayout()
      self.view.layoutIfNeeded()
    }
  }

  @objc private func handleGifGrabPan(_ gr: UIPanGestureRecognizer) {
    guard isGifPanelVisible else { return }
    let dy = gr.translation(in: view).y
    switch gr.state {
    case .began:
      gifPanStartExpand = gifPanelExpand
    case .changed:
      // Drag up expands, drag down collapses.
      let delta = -dy / 280
      gifPanelExpand = min(1, max(0, gifPanStartExpand + delta))
      view.setNeedsLayout()
      view.layoutIfNeeded()
    case .ended, .cancelled:
      let v = gr.velocity(in: view).y
      if v < -400 {
        gifPanelExpand = 1
      } else if v > 400 {
        if gifPanelExpand < 0.25 {
          hideGifPanel()
          return
        }
        gifPanelExpand = 0
      } else {
        gifPanelExpand = gifPanelExpand > 0.45 ? 1 : 0
      }
      UIView.animate(withDuration: 0.28, delay: 0, options: [.curveEaseOut]) {
        self.view.setNeedsLayout()
        self.view.layoutIfNeeded()
      }
    default:
      break
    }
  }

  // MARK: - Text entry (Cancel / Done + dim + keyboard bar)

  private func beginTextEntry(editing shell: MarkupTextShellView? = nil) {
    hideGifPanel()
    activeTextMenuShell = nil
    editingTextShell = shell
    isTextEntryActive = true
    updateHeaderStack(animated: true)
    if let shell {
      textEntryField.text = shell.currentText
      shell.isHidden = true
    } else {
      textEntryField.text = ""
    }
    applyTextFieldStyleFromModel()
    view.setNeedsLayout()
    textDimView.alpha = 0
    textDimView.isHidden = false
    UIView.animate(withDuration: 0.22) {
      self.textDimView.alpha = 1
      self.view.layoutIfNeeded()
    }
    textEntryField.becomeFirstResponder()
  }

  private func applyTextFieldStyleFromModel() {
    let size = markupModel.textFontSize
    let weight: UIFont.Weight = markupModel.textBold ? .bold : .regular
    if markupModel.textFontName == "San Francisco" {
      textEntryField.font = .systemFont(ofSize: size, weight: weight)
    } else if let face = UIFont(name: markupModel.textFontName, size: size) {
      textEntryField.font = face
    } else {
      textEntryField.font = .systemFont(ofSize: size, weight: weight)
    }
    textEntryField.textColor = .white
  }

  private func endTextEntry(commit: Bool) {
    guard isTextEntryActive else { return }
    isTextEntryActive = false
    updateHeaderStack(animated: true)
    textEntryField.resignFirstResponder()
    let t = textEntryField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if commit, !t.isEmpty {
      if let shell = editingTextShell {
        // Resizing a transformed shell can perturb its rendered frame. Preserve
        // the user's release point explicitly while the label measures its new
        // text, then restore the accumulated pinch transform.
        let restingCenter = shell.center
        let restingTransform = shell.transform
        shell.transform = .identity
        shell.isHidden = false
        shell.updateText(
          t,
          fontSize: markupModel.textFontSize,
          bold: markupModel.textBold,
          fontName: markupModel.textFontName,
          textColor: markupModel.uiColor
        )
        shell.center = restingCenter
        shell.transform = restingTransform
      } else {
        addTextLabel(t)
      }
    } else {
      editingTextShell?.isHidden = false
    }
    editingTextShell = nil
    textEntryField.text = nil
    UIView.animate(withDuration: 0.2) {
      self.textDimView.alpha = 0
      self.stageView.transform = .identity
    } completion: { _ in
      self.textDimView.isHidden = true
    }
    view.setNeedsLayout()
  }

  @objc private func handleTextCancel() {
    endTextEntry(commit: false)
  }

  @objc private func handleTextDone() {
    endTextEntry(commit: true)
  }

  // MARK: - Shapes (+ menu)

  private func addShape(_ kind: ChatImageShapeKind) {
    hideGifPanel()
    let shape = MarkupShapeView(kind: kind, strokeColor: markupModel.uiColor)
    let side = min(overlayContainer.bounds.width, overlayContainer.bounds.height) * 0.42
    shape.bounds = CGRect(x: 0, y: 0, width: max(120, side), height: max(120, side))
    shape.center = CGPoint(
      x: overlayContainer.bounds.midX, y: overlayContainer.bounds.midY)
    shape.isUserInteractionEnabled = true
    let pan = UIPanGestureRecognizer(target: self, action: #selector(handleOverlayPan(_:)))
    shape.addGestureRecognizer(pan)
    let pin = UIPinchGestureRecognizer(target: self, action: #selector(handleOverlayPinch(_:)))
    shape.addGestureRecognizer(pin)
    overlayContainer.addSubview(shape)
    registerOverlayInsert(shape)
    shape.setNeedsDisplay()
  }

  @objc private func handleSend() {
    if isAttachComposer { commitComposerCropIfNeeded() }
    let edited = hasVisualEdits() || (isAttachComposer && composerModel.hasAdjustments)
    let captionChanged =
      !(captionField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || (isAttachComposer
        && !composerModel.caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    let eventType: ChatImageEditEventType = {
      if currentMessageId == nil { return .sendNew }
      if edited || captionChanged { return .edit }
      return .resend
    }()
    emit(eventType)
  }

  private func handleComposerPickMore() {
    var config = PHPickerConfiguration(photoLibrary: .shared())
    config.selectionLimit = max(1, 6 - galleryPages.count)
    config.filter = .images
    config.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    present(picker, animated: true)
  }

  private func handleComposerCrop() {
    if composerModel.isCropping {
      commitComposerCropIfNeeded()
      return
    }
    composerModel.isCropping = true
    let overlay = ChatAttachCropOverlay(frame: stageView.bounds)
    overlay.install(over: renderSurfaceView.frame)
    stageView.addSubview(overlay)
    cropOverlay = overlay
  }

  private func commitComposerCropIfNeeded() {
    guard composerModel.isCropping, let overlay = cropOverlay, let image = imageView.image else {
      composerModel.isCropping = false
      cropOverlay?.removeFromSuperview()
      cropOverlay = nil
      return
    }
    if let cropped = overlay.croppedImage(from: image, drawnIn: renderSurfaceView.frame) {
      applyImage(cropped)
    }
    overlay.removeFromSuperview()
    cropOverlay = nil
    composerModel.isCropping = false
  }

  private func applyComposerAdjustmentsPreview() {
    guard isAttachComposer, composerModel.showAdjustments || composerModel.hasAdjustments else {
      return
    }
    let source = composerOriginalImage ?? imageView.image
    guard let source else { return }
    imageView.image = ChatAttachImageAdjust.apply(
      source,
      brightness: composerModel.brightness,
      contrast: composerModel.contrast,
      saturation: composerModel.saturation)
  }

  private func appendComposerPages(_ pages: [ChatImageEditGalleryPage]) {
    guard !pages.isEmpty else { return }
    galleryPages.append(contentsOf: pages)
    composerModel.pickCount = galleryPages.count
    rebuildPages()
    composerModel.pageIndex = galleryIndex
    composerHost.reloadChrome()
    view.setNeedsLayout()
  }


  private func addTextLabel(_ text: String) {
    // Selection chrome (dashed box + blue handles) wrapping a white text pill — like system Markup.
    let shell = MarkupTextShellView()
    shell.configure(
      text: text,
      fontSize: markupModel.textFontSize,
      bold: markupModel.textBold,
      fontName: markupModel.textFontName,
      textColor: markupModel.uiColor
    )
    shell.sizeToFitContent()
    shell.center = CGPoint(
      x: overlayContainer.bounds.midX,
      y: overlayContainer.bounds.midY)
    shell.isUserInteractionEnabled = true
    installTextShellInteractions(shell)
    overlayContainer.addSubview(shell)
    registerOverlayInsert(shell)
    markupModel.mode = .text
    markupHost.refresh()
  }

  @objc private func handleTextShellTap(_ gr: UITapGestureRecognizer) {
    guard let shell = gr.view as? MarkupTextShellView else { return }
    activeTextMenuShell = shell
    guard
      let interaction = shell.interactions.first(where: { $0 is UIEditMenuInteraction })
        as? UIEditMenuInteraction
    else { return }
    let configuration = UIEditMenuConfiguration(
      identifier: nil,
      sourcePoint: gr.location(in: shell))
    interaction.presentEditMenu(with: configuration)
  }

  private func installTextShellInteractions(_ shell: MarkupTextShellView) {
    let pan = UIPanGestureRecognizer(target: self, action: #selector(handleOverlayPan(_:)))
    shell.addGestureRecognizer(pan)
    let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handleOverlayPinch(_:)))
    shell.addGestureRecognizer(pinch)
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTextShellTap(_:)))
    tap.require(toFail: pan)
    shell.addGestureRecognizer(tap)
    shell.addInteraction(UIEditMenuInteraction(delegate: self))
  }

  func editMenuInteraction(
    _ interaction: UIEditMenuInteraction,
    menuFor configuration: UIEditMenuConfiguration,
    suggestedActions: [UIMenuElement]
  ) -> UIMenu? {
    guard let shell = activeTextMenuShell, shell.superview === overlayContainer else { return nil }
    let edit = UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { [weak self, weak shell] _ in
      guard let self, let shell else { return }
      self.beginTextEntry(editing: shell)
    }
    let delete = UIAction(
      title: "Delete",
      image: UIImage(systemName: "trash"),
      attributes: .destructive
    ) { [weak self, weak shell] _ in
      guard let self, let shell else { return }
      self.deleteOverlay(shell)
    }
    return UIMenu(children: [edit, delete])
  }

  func editMenuInteraction(
    _ interaction: UIEditMenuInteraction,
    targetRectFor configuration: UIEditMenuConfiguration
  ) -> CGRect {
    activeTextMenuShell?.bounds ?? .zero
  }

  private func deleteOverlay(_ subview: UIView) {
    guard subview.superview === overlayContainer else { return }
    let index = overlayContainer.subviews.firstIndex(of: subview) ?? overlayContainer.subviews.count
    subview.removeFromSuperview()
    undoManagerProxy.registerUndo(withTarget: self) { target in
      target.restoreDeletedOverlay(subview, at: index)
    }
    refreshUndoRedoState()
  }

  private func restoreDeletedOverlay(_ subview: UIView, at index: Int) {
    overlayContainer.insertSubview(subview, at: min(index, overlayContainer.subviews.count))
    undoManagerProxy.registerUndo(withTarget: self) { target in
      target.deleteOverlay(subview)
    }
    refreshUndoRedoState()
  }

  private func addStickerEmoji(_ emoji: String) {
    let label = UILabel()
    label.text = emoji
    label.font = .systemFont(ofSize: 64)
    label.sizeToFit()
    label.center = CGPoint(
      x: overlayContainer.bounds.midX, y: overlayContainer.bounds.midY)
    label.isUserInteractionEnabled = true
    let pan = UIPanGestureRecognizer(target: self, action: #selector(handleOverlayPan(_:)))
    label.addGestureRecognizer(pan)
    let pin = UIPinchGestureRecognizer(target: self, action: #selector(handleOverlayPinch(_:)))
    label.addGestureRecognizer(pin)
    overlayContainer.addSubview(label)
    registerOverlayInsert(label)
    hideGifPanel()
  }

  private func addStickerImage(from urlString: String) {
    guard let url = URL(string: urlString) else { return }
    VibeHTTP.shared.dataTask(with: url) { [weak self] data, _, _ in
      guard let self, let data, let image = UIImage(data: data) else { return }
      DispatchQueue.main.async {
        let iv = UIImageView(image: image)
        iv.contentMode = .scaleAspectFit
        let side: CGFloat = 120
        iv.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        iv.center = CGPoint(
          x: self.overlayContainer.bounds.midX, y: self.overlayContainer.bounds.midY)
        iv.isUserInteractionEnabled = true
        let pan = UIPanGestureRecognizer(target: self, action: #selector(self.handleOverlayPan(_:)))
        iv.addGestureRecognizer(pan)
        let pin = UIPinchGestureRecognizer(
          target: self, action: #selector(self.handleOverlayPinch(_:)))
        iv.addGestureRecognizer(pin)
        self.overlayContainer.addSubview(iv)
        self.registerOverlayInsert(iv)
        self.hideGifPanel()
      }
    }.resume()
  }

  @objc private func handleOverlayPan(_ gr: UIPanGestureRecognizer) {
    guard let v = gr.view else { return }
    let key = ObjectIdentifier(gr)
    if gr.state == .began {
      overlayPanStartCenters[key] = v.center
    }
    let start = overlayPanStartCenters[key] ?? v.center
    let t = gr.translation(in: overlayContainer)
    v.center = CGPoint(x: start.x + t.x, y: start.y + t.y)
    if gr.state == .ended || gr.state == .cancelled || gr.state == .failed {
      overlayPanStartCenters.removeValue(forKey: key)
    }
  }

  @objc private func handleOverlayPinch(_ gr: UIPinchGestureRecognizer) {
    guard let v = gr.view else { return }
    if gr.state == .began || gr.state == .changed {
      v.transform = v.transform.scaledBy(x: gr.scale, y: gr.scale)
      gr.scale = 1
    }
  }

  @objc private func keyboardWillChangeFrame(_ notification: Notification) {
    guard
      let info = notification.userInfo,
      let endFrame = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
    else { return }
    let local = view.convert(endFrame, from: nil)
    keyboardHeight = max(0, view.bounds.maxY - local.minY)
    let duration =
      (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
    let curveRaw =
      (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
    let options = UIView.AnimationOptions(rawValue: curveRaw << 16).union([
      .beginFromCurrentState, .allowUserInteraction,
    ])
    UIView.animate(withDuration: duration, delay: 0, options: options) {
      self.view.setNeedsLayout()
      self.view.layoutIfNeeded()
      self.stageView.transform =
        self.isTextEntryActive && self.keyboardHeight > 0
        ? CGAffineTransform(translationX: 0, y: -14)
        : .identity
    }
  }

  // MARK: UITextField

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    if textField === textEntryField {
      endTextEntry(commit: true)
    } else {
      textField.resignFirstResponder()
    }
    return true
  }

  // MARK: PKCanvasViewDelegate

  func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {}

  // MARK: Filmstrip

  private func centerFilmstripContentIfNeeded() {
    guard showsFilmstrip else { return }
    filmstrip.layoutIfNeeded()
    let contentW = filmstrip.collectionViewLayout.collectionViewContentSize.width
    let boundsW = filmstrip.bounds.width
    let inset = max(0, (boundsW - contentW) * 0.5)
    filmstrip.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
    if contentW < boundsW {
      filmstrip.contentOffset = CGPoint(x: -inset, y: 0)
    }
  }

  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int)
    -> Int
  {
    galleryPages.count
  }

  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath)
    -> UICollectionViewCell
  {
    let cell =
      collectionView.dequeueReusableCell(
        withReuseIdentifier: ChatImageEditFilmstripCell.reuseId, for: indexPath)
      as! ChatImageEditFilmstripCell
    let page = galleryPages[indexPath.item]
    cell.configure(image: page.image, selected: indexPath.item == galleryIndex)
    return cell
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    guard indexPath.item != galleryIndex else { return }
    selectPage(at: indexPath.item)
  }
}

// MARK: - Photo-only zoom target

extension ChatImageEditViewController: ChatMediaZoomTransitionTarget {
  var zoomTransitionImage: UIImage? {
    imageView.image ?? galleryPages[safeIndex: galleryIndex]?.image
  }

  var zoomTransitionMessageId: String? { currentMessageId }

  var zoomTransitionPageIndex: Int { galleryIndex }

  func zoomTransitionTargetFrame(for image: UIImage?) -> CGRect {
    if imageView.image == nil, let image, image.size.width > 1, image.size.height > 1 {
      let rect = fittingRect(container: stageView.bounds, mediaSize: image.size)
      return stageView.convert(rect, to: nil)
    }
    return zoomTransitionCurrentFrame
  }

  var zoomTransitionCurrentFrame: CGRect {
    renderSurfaceView.convert(renderSurfaceView.bounds, to: nil)
  }

  func setZoomTransitionContentHidden(_ hidden: Bool) {
    stageView.isHidden = hidden
  }

  func installZoomTransitionFlightView(_ flightView: UIView, frameInWindow: CGRect) -> UIView {
    // `topContainer`, the bottom controls and `headerHost` all sit above
    // this insertion point. The moving photo therefore starts behind the header
    // and stays behind it for every frame instead of jumping layers on completion.
    view.insertSubview(flightView, belowSubview: topContainer)
    flightView.frame = view.convert(frameInWindow, from: nil)
    return view
  }
}

extension ChatImageEditViewController: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard !results.isEmpty else { return }
    let group = DispatchGroup()
    let lock = NSLock()
    var pagesByIndex: [Int: ChatImageEditGalleryPage] = [:]
    for (index, result) in results.enumerated() {
      guard result.itemProvider.canLoadObject(ofClass: UIImage.self) else { continue }
      group.enter()
      result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
        defer { group.leave() }
        guard let image = object as? UIImage,
          let data = image.jpegData(compressionQuality: 0.9),
          let url = VibeMediaVault.shared.persistOutgoingPick(data: data, fileExtension: "jpg")
        else { return }
        lock.lock()
        pagesByIndex[index] = ChatImageEditGalleryPage(mediaURL: url.absoluteString, image: image)
        lock.unlock()
      }
    }
    group.notify(queue: .main) { [weak self] in
      let pages = pagesByIndex.keys.sorted().compactMap { pagesByIndex[$0] }
      self?.appendComposerPages(pages)
    }
  }
}

// MARK: - Edge-anchored stroke width paddle

private final class ChatImageStrokeSizeControl: UIControl {
  private let track = UIView()
  private let knob = UIView()
  private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))

  var onStrokeScaleChanged: ((CGFloat) -> Void)?

  var strokeScale: CGFloat = 1.0 {
    didSet {
      strokeScale = min(max(strokeScale, 0.35), 2.4)
      setNeedsLayout()
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isAccessibilityElement = true
    accessibilityLabel = "Stroke width"
    accessibilityTraits = [.adjustable]

    track.isUserInteractionEnabled = false
    // Telegram's control is a slender warm translucent rail entering from the
    // bezel, not a wide frosted panel.
    track.backgroundColor = UIColor(red: 0.68, green: 0.61, blue: 0.46, alpha: 0.48)
    track.clipsToBounds = true
    addSubview(track)

    knob.backgroundColor = .white
    knob.isUserInteractionEnabled = false
    knob.layer.borderColor = UIColor.black.withAlphaComponent(0.16).cgColor
    knob.layer.borderWidth = 0.5
    knob.layer.shadowColor = UIColor.black.cgColor
    knob.layer.shadowOpacity = 0.28
    knob.layer.shadowRadius = 4
    knob.layer.shadowOffset = CGSize(width: 0, height: 2)
    addSubview(knob)

    addGestureRecognizer(pan)
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    track.frame = CGRect(x: 0, y: 0, width: 30, height: bounds.height)
    track.layer.cornerRadius = 15

    let normalized = (strokeScale - 0.35) / (2.4 - 0.35)
    let diameter = 31 + normalized * 4
    let travelInset = diameter * 0.5 + 4
    let y = travelInset + (1 - normalized) * max(1, bounds.height - travelInset * 2)
    knob.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
    knob.center = CGPoint(x: 30, y: y)
    knob.layer.cornerRadius = diameter * 0.5
    accessibilityValue = "\(Int((normalized * 100).rounded())) percent"
  }

  @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
    guard gesture.state == .began || gesture.state == .changed else { return }
    let location = gesture.location(in: self)
    let inset: CGFloat = 24
    let normalized = 1 - min(max((location.y - inset) / max(1, bounds.height - inset * 2), 0), 1)
    strokeScale = 0.35 + normalized * (2.4 - 0.35)
    onStrokeScaleChanged?(strokeScale)
  }

  override func accessibilityIncrement() {
    strokeScale += 0.15
    onStrokeScaleChanged?(strokeScale)
  }

  override func accessibilityDecrement() {
    strokeScale -= 0.15
    onStrokeScaleChanged?(strokeScale)
  }
}

// MARK: - Toast label

private final class PaddedLabel: UILabel {
  private let inset = UIEdgeInsets(top: 8, left: 18, bottom: 8, right: 18)

  override func drawText(in rect: CGRect) {
    super.drawText(in: rect.inset(by: inset))
  }

  override var intrinsicContentSize: CGSize {
    let size = super.intrinsicContentSize
    return CGSize(
      width: size.width + inset.left + inset.right,
      height: size.height + inset.top + inset.bottom)
  }
}

// MARK: - GIF panel delegate

extension ChatImageEditViewController: ChatGifPanelViewDelegate {
  func chatGifPanel(_ panel: ChatGifPanelView, didSelectGif gif: ChatGifSelection) {
    addStickerImage(from: gif.url.isEmpty ? gif.previewUrl : gif.url)
  }

  func chatGifPanel(_ panel: ChatGifPanelView, didSelectSticker sticker: ChatStickerSelection) {
    if let remote = sticker.remoteUrl, !remote.isEmpty {
      addStickerImage(from: remote)
    } else if let emoji = sticker.emoji, !emoji.isEmpty {
      addStickerEmoji(emoji)
    } else if let bundle = sticker.bundleFileName {
      // Best-effort: treat as emoji-less image path via remote only
      _ = bundle
    }
  }

  func chatGifPanel(_ panel: ChatGifPanelView, didSelectEmoji emoji: String) {
    addStickerEmoji(emoji)
  }

  func chatGifPanelDidRequestClose(_ panel: ChatGifPanelView) {
    hideGifPanel()
  }
}

// MARK: - System color picker

extension ChatImageEditViewController: UIColorPickerViewControllerDelegate {
  func colorPickerViewControllerDidFinish(_ viewController: UIColorPickerViewController) {
    applyPickedColor(viewController.selectedColor)
  }

  func colorPickerViewControllerDidSelectColor(_ viewController: UIColorPickerViewController) {
    applyPickedColor(viewController.selectedColor)
  }

  private func applyPickedColor(_ color: UIColor) {
    markupModel.inkColor = Color(color)
    var alpha: CGFloat = 1
    color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
    markupModel.inkOpacity = Double(alpha)
    applyToolFromModel()
    markupHost.refresh()
  }
}

// MARK: - Shape overlay

private final class MarkupShapeView: UIView {
  private let kind: ChatImageShapeKind
  private let strokeColor: UIColor
  private let border = CAShapeLayer()
  private var handleViews: [UIView] = []

  init(kind: ChatImageShapeKind, strokeColor: UIColor) {
    self.kind = kind
    self.strokeColor = strokeColor
    super.init(frame: .zero)
    backgroundColor = .clear
    isOpaque = false
    border.fillColor = UIColor.clear.cgColor
    border.strokeColor = strokeColor.cgColor
    border.lineWidth = 5
    border.lineJoin = .round
    border.lineCap = .round
    layer.addSublayer(border)

    for _ in 0..<8 {
      let h = UIView()
      h.backgroundColor = .systemBlue
      h.layer.cornerRadius = 5
      h.layer.borderWidth = 1.5
      h.layer.borderColor = UIColor.white.cgColor
      addSubview(h)
      handleViews.append(h)
    }
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    border.frame = bounds
    border.path = shapePath(in: bounds.insetBy(dx: 10, dy: 10)).cgPath
    let pts = handlePoints(in: bounds.insetBy(dx: 6, dy: 6))
    for (i, hv) in handleViews.enumerated() {
      guard i < pts.count else {
        hv.isHidden = true
        continue
      }
      hv.isHidden = false
      hv.frame = CGRect(x: pts[i].x - 5, y: pts[i].y - 5, width: 10, height: 10)
    }
  }

  private func shapePath(in rect: CGRect) -> UIBezierPath {
    switch kind {
    case .rectangle:
      return UIBezierPath(roundedRect: rect, cornerRadius: 4)
    case .ellipse:
      return UIBezierPath(ovalIn: rect)
    case .bubble:
      let path = UIBezierPath(
        roundedRect: CGRect(
          x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.72),
        cornerRadius: 12)
      path.move(to: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.72))
      path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.72))
      path.close()
      return path
    case .star:
      return starPath(in: rect)
    case .arrow:
      let path = UIBezierPath()
      let midY = rect.midY
      path.move(to: CGPoint(x: rect.minX, y: midY))
      path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.28, y: midY))
      path.move(to: CGPoint(x: rect.maxX - rect.width * 0.35, y: rect.minY + rect.height * 0.22))
      path.addLine(to: CGPoint(x: rect.maxX, y: midY))
      path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.35, y: rect.maxY - rect.height * 0.22))
      return path
    }
  }

  private func starPath(in rect: CGRect) -> UIBezierPath {
    let path = UIBezierPath()
    let cx = rect.midX
    let cy = rect.midY
    let r = min(rect.width, rect.height) * 0.5
    let inner = r * 0.42
    for i in 0..<10 {
      let angle = CGFloat(i) * .pi / 5 - .pi / 2
      let rad = i % 2 == 0 ? r : inner
      let p = CGPoint(x: cx + cos(angle) * rad, y: cy + sin(angle) * rad)
      if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.close()
    return path
  }

  private func handlePoints(in rect: CGRect) -> [CGPoint] {
    [
      CGPoint(x: rect.minX, y: rect.minY),
      CGPoint(x: rect.midX, y: rect.minY),
      CGPoint(x: rect.maxX, y: rect.minY),
      CGPoint(x: rect.maxX, y: rect.midY),
      CGPoint(x: rect.maxX, y: rect.maxY),
      CGPoint(x: rect.midX, y: rect.maxY),
      CGPoint(x: rect.minX, y: rect.maxY),
      CGPoint(x: rect.minX, y: rect.midY),
    ]
  }
}

// MARK: - Markup text shell (dashed selection + white pill)

private final class MarkupTextShellView: UIView {
  private let label = UILabel()
  private let border = CAShapeLayer()
  private let leftHandle = UIView()
  private let rightHandle = UIView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear

    label.backgroundColor = .white
    label.textColor = .black
    label.textAlignment = .center
    label.layer.cornerRadius = 8
    label.clipsToBounds = true
    addSubview(label)

    border.strokeColor = UIColor.white.withAlphaComponent(0.85).cgColor
    border.fillColor = UIColor.clear.cgColor
    border.lineWidth = 1.5
    border.lineDashPattern = [5, 4]
    layer.addSublayer(border)

    for handle in [leftHandle, rightHandle] {
      handle.backgroundColor = .white
      handle.layer.borderColor = UIColor.systemBlue.cgColor
      handle.layer.borderWidth = 2
      handle.layer.cornerRadius = 7
      addSubview(handle)
    }
  }

  required init?(coder: NSCoder) { nil }

  var currentText: String { label.text ?? "" }

  func configure(
    text: String, fontSize: CGFloat, bold: Bool, fontName: String, textColor: UIColor
  ) {
    apply(text: text, fontSize: fontSize, bold: bold, fontName: fontName, textColor: textColor)
  }

  func updateText(
    _ text: String, fontSize: CGFloat, bold: Bool, fontName: String, textColor: UIColor
  ) {
    apply(text: text, fontSize: fontSize, bold: bold, fontName: fontName, textColor: textColor)
    sizeToFitContent()
  }

  private func apply(
    text: String, fontSize: CGFloat, bold: Bool, fontName: String, textColor: UIColor
  ) {
    label.text = text
    let weight: UIFont.Weight = bold ? .bold : .regular
    if fontName == "San Francisco" {
      label.font = .systemFont(ofSize: fontSize, weight: weight)
    } else if let face = UIFont(name: fontName, size: fontSize) {
      label.font = face
    } else {
      label.font = .systemFont(ofSize: fontSize, weight: weight)
    }
    // System Markup: black type on white pill.
    label.textColor = .black
    _ = textColor
  }

  func sizeToFitContent() {
    label.sizeToFit()
    let padX: CGFloat = 16
    let padY: CGFloat = 10
    let labelSize = CGSize(
      width: label.bounds.width + padX * 2,
      height: label.bounds.height + padY * 2)
    let inset: CGFloat = 10
    bounds = CGRect(
      x: 0, y: 0,
      width: labelSize.width + inset * 2,
      height: labelSize.height + inset * 2)
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let inset: CGFloat = 10
    label.frame = bounds.insetBy(dx: inset, dy: inset)
    let path = UIBezierPath(
      roundedRect: label.frame.insetBy(dx: -4, dy: -4), cornerRadius: 10)
    border.path = path.cgPath
    border.frame = bounds

    let handle: CGFloat = 14
    leftHandle.frame = CGRect(
      x: label.frame.minX - handle * 0.5 - 4,
      y: bounds.midY - handle * 0.5,
      width: handle, height: handle)
    rightHandle.frame = CGRect(
      x: label.frame.maxX - handle * 0.5 + 4,
      y: bounds.midY - handle * 0.5,
      width: handle, height: handle)
  }
}

// MARK: - Filmstrip cell

private final class ChatImageEditFilmstripCell: UICollectionViewCell {
  static let reuseId = "ChatImageEditFilmstripCell"
  private let imageView = UIImageView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    contentView.clipsToBounds = true
    contentView.layer.cornerRadius = 10
    contentView.layer.cornerCurve = .continuous
    contentView.backgroundColor = UIColor(white: 0.18, alpha: 1)
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    contentView.addSubview(imageView)
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    imageView.frame = contentView.bounds
  }

  func configure(image: UIImage?, selected: Bool) {
    imageView.image = image
    contentView.layer.borderWidth = selected ? 2 : 0
    contentView.layer.borderColor = UIColor.white.cgColor
    contentView.alpha = selected ? 1 : 0.72
  }
}

private extension Array {
  subscript(safeIndex index: Int) -> Element? {
    guard index >= 0, index < count else { return nil }
    return self[index]
  }
}

// MARK: - SwiftUI bridge (optional host)

struct ChatImageEditSwiftUIView: UIViewControllerRepresentable {
  let messageId: String?
  let mediaURL: String
  let initialImage: UIImage?
  let initialCaption: String?
  let headerTitle: String?
  let dismissPresenterOnSend: Bool
  var onAction: ((ChatImageEditActionPayload) -> Void)?

  func makeUIViewController(context: Context) -> ChatImageEditViewController {
    let vc = ChatImageEditViewController(
      messageId: messageId,
      mediaURL: mediaURL,
      initialImage: initialImage,
      initialCaption: initialCaption,
      headerTitle: headerTitle,
      dismissPresenterOnSend: dismissPresenterOnSend
    )
    vc.onAction = onAction
    return vc
  }

  func updateUIViewController(_ uiViewController: ChatImageEditViewController, context: Context) {}
}
