import AVFoundation
import CoreLocation
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

// MARK: - ChatAttachmentMenuController

final class ChatAttachmentMenuController: UIViewController, UITextFieldDelegate {
  var onSelectImage: ((String, String?, ChatAttachmentTransitionCapture?) -> Void)?
  /// Multi-select send: all picked image uris (selection order) + the shared caption.
  var onSelectImages: (([String], String?, ChatAttachmentTransitionCapture?) -> Void)?
  var onSelectFile: ((String, String) -> Void)?
  var onSelectLocation: ((Double, Double) -> Void)?
  var onSelectText: ((String) -> Void)?
  var recipientName: String = ""

  var sourceButtonFrameInWindow: CGRect?
  weak var sourceButtonView: UIView?

  private let appearance: ChatListAppearance

  // ── UI ──
  private let headerTitleButton = UIButton(type: .system)
  private let contentView = UIView()
  private let galleryCollectionView: UICollectionView
  private let galleryLayout = GalleryGridLayout()
  private let galleryEmptyLabel = UILabel()
  /// "Open Settings" when access was denied, "Select More Photos" under limited
  /// access — the grid cannot fix either state on its own.
  private let galleryPermissionButton = UIButton(type: .system)
  /// Thumbnail the editor was opened from, so it can grow out of it and shrink
  /// back into it. Weak because the grid may recycle the cell meanwhile.
  private weak var zoomAnchorCellImageView: UIImageView?
  private let fileView = UIView()
  private let fileActionButton = UIButton(type: .system)
  private let fileScrollView = UIScrollView()
  private let fileStack = UIStackView()
  private let recentsTable = UITableView(frame: .zero, style: .plain)
  private var recentEntries: [ChatRecentSentFilesStore.Entry] = []
  private var recentsHeightConstraint: NSLayoutConstraint?
  private let locationView = UIView()
  private let locationActionButton = UIButton(type: .system)
  private let articleView = UIView()
  private let articleField = UITextField()
  private let articleSendButton = UIButton(type: .system)
  private let checklistView = UIView()
  private let checklistField = UITextField()
  private var checklistItems: [String] = []
  private let checklistList = UIStackView()
  private let audioView = UIView()
  private let audioActionButton = UIButton(type: .system)

  // ── Soft edge masks (gradient fade at header and bottom) ──
  private let topMaskView = UIView()
  private let bottomMaskView = UIView()
  private let topMaskGradient = CAGradientLayer()
  private let bottomMaskGradient = CAGradientLayer()

  // ── Tab Bar: exact copy of ChatNativeTabBarModule subview pattern ──
  private class FloatingTabBar: UITabBar {
    override var safeAreaInsets: UIEdgeInsets { .zero }
  }
  // Tab bar is a direct subview — Apple draws its own floating glass pill.
  private let tabBar = FloatingTabBar()
  // Caption chrome — separate glass view, like vibeChromeView in ChatNativeTabBarModule.
  // Starts hidden. When an item is selected via the select toggle, this expands over the tab bar.
  private let captionChromeView = UIVisualEffectView(effect: nil)
  private let captionField = UITextField()
  private let captionSendButton = UIButton(type: .system)
  private let captionIconView = UIImageView()
  private var captionWidthConstraint: NSLayoutConstraint?
  private var captionHeightConstraint: NSLayoutConstraint?
  private var isCaptionMode = false
  // Multi-select: gallery indices in selection order. Images can be combined (up to
  // `maxMultiSelect`); a video always sends alone, so picking one clears the rest.
  private var selectedAssetIndices: [Int] = []
  private static let maxMultiSelect = 6
  private var tabBarContainerBottomConstraint: NSLayoutConstraint?

  // ── Tab bar container ──
  // A transparent container that holds the tab bar + caption chrome side-by-side,
  // matching the ChatNativeTabBarModule layout exactly.
  private let tabBarContainer = UIView()

  // ── State ──
  private let photoManager = PHCachingImageManager()
  private var allGalleryAssets: [PHAsset] = []
  private var galleryAssets: [PHAsset] = []
  private var galleryThumbSize: CGSize = .zero
  private var galleryBaseItem: CGFloat = 0
  private var isSelectingAsset = false
  private var activeSection: MenuSection = .gallery
  private var activeGalleryFilter: GalleryFilter = .recent

  // ── Camera ──
  private var cameraPreviewAvailable = false
  private weak var cameraPreviewHostView: UIView?
  private var isCameraLoading = true

  private let selectionFeedback = UISelectionFeedbackGenerator()

  private enum MenuSection: Int, CaseIterable {
    case gallery, article, file, location, checklist, audio
    var title: String {
      switch self {
      case .gallery: return "Gallery"
      case .article: return "Article"
      case .file: return "File"
      case .location: return "Location"
      case .checklist: return "Checklist"
      case .audio: return "Audio"
      }
    }
    var symbolName: String {
      switch self {
      case .gallery: return "photo.on.rectangle"
      case .article: return "doc.richtext"
      case .file: return "doc.fill"
      case .location: return "location"
      case .checklist: return "checkmark.square"
      case .audio: return "play.circle"
      }
    }
  }

  private enum GalleryFilter: String, CaseIterable {
    case recent = "Recent"
    case videos = "Videos"
    case photos = "Photos"
  }

  // MARK: - Colors (matched to theme.ts)

  private var modalBgColor: UIColor {
    appearance.isDark
      ? UIColor(red: 0.071, green: 0.071, blue: 0.071, alpha: 1.0)  // #121212
      : UIColor(red: 0.961, green: 0.957, blue: 0.945, alpha: 1.0)  // #F5F4F1
  }

  private var primaryTextColor: UIColor {
    appearance.isDark
      ? UIColor(red: 0.91, green: 0.90, blue: 0.94, alpha: 1.0)  // #E8E6F0
      : UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)  // #1A1A1F
  }

  private var secondaryTextColor: UIColor {
    primaryTextColor.withAlphaComponent(0.55)
  }

  private var accentColor: UIColor {
    appearance.bubbleMeGradient.first ?? appearance.bubbleThemColor
  }

  // MARK: - Init

  init(appearance: ChatListAppearance) {
    self.appearance = appearance
    galleryLayout.spacing = 2
    self.galleryCollectionView = UICollectionView(frame: .zero, collectionViewLayout: galleryLayout)
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .pageSheet
  }

  required init?(coder: NSCoder) { nil }

  // MARK: - Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = modalBgColor
    view.clipsToBounds = true

    configureSheet()
    setupContent()  // content first (behind everything)
    setupMasks()  // gradient masks on top of content
    setupHeader()  // header on top of mask
    setupTabBarAndCaption()  // tab bar on top of mask
    setActiveSection(.gallery, animated: false)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleKeyboardWillChangeFrame(_:)),
      name: UIResponder.keyboardWillChangeFrameNotification,
      object: nil
    )
  }

  /// Lift the caption bar above the keyboard while a caption is being typed —
  /// without this the field stays pinned to the sheet bottom, hidden behind the
  /// keyboard. Frame math is done in this view's coordinates so it stays correct
  /// even when the sheet itself shifts for the keyboard.
  @objc private func handleKeyboardWillChangeFrame(_ note: Notification) {
    guard isViewLoaded,
      let endFrame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
    else { return }
    let endFrameInView = view.convert(endFrame, from: nil)
    let overlap = max(0.0, view.bounds.maxY - endFrameInView.minY)
    let duration =
      (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
    let curveRaw =
      (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 7
    tabBarContainerBottomConstraint?.constant = -(10.0 + overlap)
    UIView.animate(
      withDuration: duration,
      delay: 0,
      options: [UIView.AnimationOptions(rawValue: curveRaw << 16), .beginFromCurrentState]
    ) {
      self.view.layoutIfNeeded()
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    layoutAll()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    startCameraPreview()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    stopCameraPreview()
  }

  deinit { stopCameraPreview() }

  // MARK: - Sheet

  private func configureSheet() {
    guard let sheet = sheetPresentationController else { return }
    sheet.detents = [.medium(), .large()]
    sheet.selectedDetentIdentifier = .medium
    sheet.prefersGrabberVisible = false
    sheet.prefersScrollingExpandsWhenScrolledToEdge = true
    sheet.prefersEdgeAttachedInCompactHeight = true
    sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
    sheet.preferredCornerRadius = 28
  }

  // MARK: - Header

  private func setupHeader() {
    headerTitleButton.tintColor = primaryTextColor
    headerTitleButton.showsMenuAsPrimaryAction = true
    view.addSubview(headerTitleButton)  // on top of mask
    updateHeaderButton()
  }

  // MARK: - Soft Edge Masks

  private func setupMasks() {
    // Top mask: fades from modalBgColor → transparent
    topMaskView.isUserInteractionEnabled = false
    topMaskGradient.colors = [modalBgColor.cgColor, modalBgColor.withAlphaComponent(0).cgColor]
    topMaskGradient.startPoint = CGPoint(x: 0.5, y: 0)
    topMaskGradient.endPoint = CGPoint(x: 0.5, y: 1)
    topMaskView.layer.addSublayer(topMaskGradient)
    view.addSubview(topMaskView)  // above content, below header

    // Bottom mask: fades from transparent → modalBgColor
    bottomMaskView.isUserInteractionEnabled = false
    bottomMaskGradient.colors = [modalBgColor.withAlphaComponent(0).cgColor, modalBgColor.cgColor]
    bottomMaskGradient.startPoint = CGPoint(x: 0.5, y: 0)
    bottomMaskGradient.endPoint = CGPoint(x: 0.5, y: 1)
    bottomMaskView.layer.addSublayer(bottomMaskGradient)
    view.addSubview(bottomMaskView)  // above content, below tab bar
  }

  // MARK: - Content

  private func setupContent() {
    contentView.backgroundColor = .clear
    view.addSubview(contentView)

    galleryCollectionView.backgroundColor = .clear
    galleryCollectionView.alwaysBounceVertical = true
    galleryCollectionView.showsVerticalScrollIndicator = true
    galleryCollectionView.contentInsetAdjustmentBehavior = .never
    galleryCollectionView.allowsMultipleSelection = false
    galleryCollectionView.dataSource = self
    galleryCollectionView.delegate = self
    galleryCollectionView.register(
      ChatAttachmentAssetCell.self,
      forCellWithReuseIdentifier: ChatAttachmentAssetCell.reuseIdentifier
    )
    galleryCollectionView.register(
      ChatAttachmentCameraCell.self,
      forCellWithReuseIdentifier: ChatAttachmentCameraCell.reuseIdentifier
    )

    galleryEmptyLabel.text = "No photos found"
    galleryEmptyLabel.font = .systemFont(ofSize: 14, weight: .medium)
    galleryEmptyLabel.textColor = secondaryTextColor
    galleryEmptyLabel.textAlignment = .center
    galleryEmptyLabel.numberOfLines = 0

    // Denied access and limited access both need a way forward from inside the
    // sheet; a label alone leaves the user with nothing to do about it.
    galleryPermissionButton.isHidden = true
    galleryPermissionButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    galleryPermissionButton.setTitleColor(accentColor, for: .normal)
    galleryPermissionButton.addTarget(
      self, action: #selector(handleGalleryPermissionTap), for: .touchUpInside)

    contentView.addSubview(galleryCollectionView)
    contentView.addSubview(galleryEmptyLabel)
    contentView.addSubview(galleryPermissionButton)

    installFileSheet()
    contentView.addSubview(fileView)

    setupCenterAction(
      locationView, title: "Share Location", subtitle: "Send your current location",
      button: locationActionButton, buttonTitle: "Use Current Location", symbol: "location.circle"
    )
    locationActionButton.addTarget(self, action: #selector(openLocation), for: .touchUpInside)
    contentView.addSubview(locationView)

    setupArticleHost()
    setupChecklistHost()
    setupCenterAction(
      audioView, title: "Audio", subtitle: "Send a music or audio file",
      button: audioActionButton, buttonTitle: "Choose Audio", symbol: "play.circle")
    audioActionButton.addTarget(self, action: #selector(openAudioPicker), for: .touchUpInside)
    contentView.addSubview(articleView)
    contentView.addSubview(checklistView)
    contentView.addSubview(audioView)
    articleView.isHidden = true
    checklistView.isHidden = true
    audioView.isHidden = true
  }

  private func installFileSheet() {
    let isDark = appearance.isDark

    fileScrollView.translatesAutoresizingMaskIntoConstraints = false
    fileScrollView.alwaysBounceVertical = true
    fileScrollView.showsVerticalScrollIndicator = false
    fileView.addSubview(fileScrollView)

    fileStack.translatesAutoresizingMaskIntoConstraints = false
    fileStack.axis = .vertical
    fileStack.spacing = 18
    fileScrollView.addSubview(fileStack)

    let card = UIView()
    card.backgroundColor = primaryTextColor.withAlphaComponent(isDark ? 0.08 : 0.06)
    card.layer.cornerRadius = 26
    card.layer.cornerCurve = .continuous
    card.clipsToBounds = true
    let cardStack = UIStackView()
    cardStack.translatesAutoresizingMaskIntoConstraints = false
    cardStack.axis = .vertical
    cardStack.spacing = 0
    card.addSubview(cardStack)

    let galleryRow = AttachmentRowView(
      title: "Select from Gallery",
      symbol: "photo",
      color: .systemBlue,
      isDark: isDark,
      showDivider: true,
      showChevron: true
    ) { [weak self] in
      self?.openFullGalleryPicker()
    }
    let docRow = AttachmentRowView(
      title: "Select from Files",
      symbol: "folder",
      color: .systemOrange,
      isDark: isDark,
      showDivider: true,
      showChevron: true
    ) { [weak self] in
      self?.openFilePicker()
    }
    let scanRow = AttachmentRowView(
      title: "Scan Document",
      symbol: "doc.viewfinder",
      color: .systemIndigo,
      isDark: isDark,
      showDivider: false,
      showChevron: true
    ) { [weak self] in
      self?.openDocumentScanner()
    }
    cardStack.addArrangedSubview(galleryRow)
    cardStack.addArrangedSubview(docRow)
    cardStack.addArrangedSubview(scanRow)

    let recentsLabel = UILabel()
    recentsLabel.text = "RECENTLY SENT FILES"
    recentsLabel.font = .systemFont(ofSize: 12, weight: .semibold)
    recentsLabel.textColor = secondaryTextColor

    recentsTable.translatesAutoresizingMaskIntoConstraints = false
    recentsTable.backgroundColor = .clear
    recentsTable.separatorStyle = .none
    recentsTable.isScrollEnabled = false
    recentsTable.dataSource = self
    recentsTable.delegate = self
    recentsTable.register(UITableViewCell.self, forCellReuseIdentifier: "recent-file")
    recentsTable.rowHeight = 58

    fileStack.addArrangedSubview(card)
    fileStack.addArrangedSubview(recentsLabel)
    fileStack.addArrangedSubview(recentsTable)

    NSLayoutConstraint.activate([
      fileScrollView.leadingAnchor.constraint(equalTo: fileView.leadingAnchor),
      fileScrollView.trailingAnchor.constraint(equalTo: fileView.trailingAnchor),
      fileScrollView.topAnchor.constraint(equalTo: fileView.topAnchor),
      fileScrollView.bottomAnchor.constraint(equalTo: fileView.bottomAnchor),
      fileStack.leadingAnchor.constraint(equalTo: fileScrollView.contentLayoutGuide.leadingAnchor, constant: 16),
      fileStack.trailingAnchor.constraint(equalTo: fileScrollView.contentLayoutGuide.trailingAnchor, constant: -16),
      fileStack.topAnchor.constraint(equalTo: fileScrollView.contentLayoutGuide.topAnchor, constant: 8),
      fileStack.bottomAnchor.constraint(equalTo: fileScrollView.contentLayoutGuide.bottomAnchor, constant: -20),
      fileStack.widthAnchor.constraint(equalTo: fileScrollView.frameLayoutGuide.widthAnchor, constant: -32),
      cardStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
      cardStack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
      cardStack.topAnchor.constraint(equalTo: card.topAnchor),
      cardStack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
    ])
    let recentsH = recentsTable.heightAnchor.constraint(equalToConstant: 8)
    recentsH.isActive = true
    recentsHeightConstraint = recentsH
    reloadRecentFiles()
    NotificationCenter.default.addObserver(
      self, selector: #selector(reloadRecentFiles),
      name: ChatRecentSentFilesStore.didChange, object: nil)
  }

  @objc private func reloadRecentFiles() {
    recentEntries = ChatRecentSentFilesStore.shared.entries
    recentsTable.reloadData()
    recentsTable.layoutIfNeeded()
    recentsHeightConstraint?.constant = max(8, recentsTable.contentSize.height)
  }

  private func setupArticleHost() {
    articleView.backgroundColor = .clear
    let card = UIView()
    card.tag = 10
    card.backgroundColor = primaryTextColor.withAlphaComponent(appearance.isDark ? 0.08 : 0.06)
    card.layer.cornerRadius = 26
    card.layer.cornerCurve = .continuous
    articleView.addSubview(card)

    let title = UILabel()
    title.text = "Article"
    title.font = .systemFont(ofSize: 17, weight: .semibold)
    title.textColor = primaryTextColor
    card.addSubview(title)
    title.tag = 11

    articleField.placeholder = "Paste a link or title"
    articleField.font = .systemFont(ofSize: 16)
    articleField.textColor = primaryTextColor
    articleField.borderStyle = .none
    articleField.backgroundColor = primaryTextColor.withAlphaComponent(appearance.isDark ? 0.08 : 0.06)
    articleField.layer.cornerRadius = 14
    articleField.layer.cornerCurve = .continuous
    articleField.clipsToBounds = true
    articleField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 8))
    articleField.leftViewMode = .always
    articleField.returnKeyType = .send
    articleField.delegate = self
    card.addSubview(articleField)
    articleField.tag = 12

    articleSendButton.setTitle("Send Article", for: .normal)
    articleSendButton.setTitleColor(.white, for: .normal)
    articleSendButton.backgroundColor = accentColor
    articleSendButton.layer.cornerRadius = 14
    articleSendButton.layer.cornerCurve = .continuous
    articleSendButton.addTarget(self, action: #selector(sendArticle), for: .touchUpInside)
    card.addSubview(articleSendButton)
    articleSendButton.tag = 13
  }

  private func setupChecklistHost() {
    checklistView.backgroundColor = .clear
    let title = UILabel()
    title.text = "Checklist"
    title.font = .systemFont(ofSize: 22, weight: .semibold)
    title.textColor = primaryTextColor
    title.textAlignment = .center
    checklistView.addSubview(title)
    title.tag = 21
    checklistField.placeholder = "Add an item"
    checklistField.font = .systemFont(ofSize: 16)
    checklistField.textColor = primaryTextColor
    checklistField.borderStyle = .roundedRect
    checklistField.returnKeyType = .done
    checklistField.delegate = self
    checklistView.addSubview(checklistField)
    checklistField.tag = 22
    checklistList.axis = .vertical
    checklistList.spacing = 8
    checklistView.addSubview(checklistList)
    checklistList.tag = 23
    let send = UIButton(type: .system)
    send.setTitle("Send Checklist", for: .normal)
    send.setTitleColor(accentColor, for: .normal)
    send.addTarget(self, action: #selector(sendChecklist), for: .touchUpInside)
    checklistView.addSubview(send)
    send.tag = 24
  }

  // MARK: - Tab Bar + Caption (exact ChatNativeTabBarModule subview copy)

  private func setupTabBarAndCaption() {
    // ── Container (transparent, no background, no edges) ──
    tabBarContainer.translatesAutoresizingMaskIntoConstraints = false
    tabBarContainer.backgroundColor = .clear
    tabBarContainer.isOpaque = false
    tabBarContainer.clipsToBounds = false
    view.addSubview(tabBarContainer)

    // ── Tab Bar (Apple draws its own glass pill internally) ──
    tabBar.translatesAutoresizingMaskIntoConstraints = false
    tabBar.delegate = self
    tabBar.itemPositioning = .automatic
    // We strictly do NOT clip or round tabBar. Apple handles the inner floating pill.
    tabBarContainer.addSubview(tabBar)

    // ── Caption Chrome (like vibeChromeView in ChatNativeTabBarModule) ──
    captionChromeView.translatesAutoresizingMaskIntoConstraints = false
    captionChromeView.layer.cornerRadius = 30
    captionChromeView.layer.cornerCurve = .continuous
    captionChromeView.clipsToBounds = true
    captionChromeView.isHidden = true
    tabBarContainer.addSubview(captionChromeView)

    // Caption icon
    captionIconView.translatesAutoresizingMaskIntoConstraints = false
    captionIconView.contentMode = .scaleAspectFit
    captionIconView.isUserInteractionEnabled = false
    captionIconView.image = UIImage(
      systemName: "paperplane.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
    )
    captionIconView.tintColor = .white
    captionIconView.alpha = 1.0
    captionChromeView.contentView.addSubview(captionIconView)

    // Caption text field
    captionField.translatesAutoresizingMaskIntoConstraints = false
    captionField.placeholder = "Add a caption…"
    captionField.font = .systemFont(ofSize: 16)
    captionField.textColor = primaryTextColor
    captionField.tintColor = accentColor
    captionField.alpha = 0
    captionField.returnKeyType = .send
    captionField.delegate = self
    captionField.addTarget(self, action: #selector(captionTextDidChange), for: .editingChanged)
    captionChromeView.contentView.addSubview(captionField)

    // Caption send button (below icon, like vibeSubmitButton)
    captionSendButton.translatesAutoresizingMaskIntoConstraints = false
    captionSendButton.backgroundColor = .clear
    captionSendButton.alpha = 0
    captionSendButton.addTarget(self, action: #selector(sendSelectedItem), for: .touchUpInside)
    captionChromeView.contentView.insertSubview(captionSendButton, belowSubview: captionIconView)

    let wC = captionChromeView.widthAnchor.constraint(equalToConstant: 0)
    let hC = captionChromeView.heightAnchor.constraint(equalToConstant: 0)
    captionWidthConstraint = wC
    captionHeightConstraint = hC
    // Kept as a var so the caption bar can ride above the keyboard while typing.
    let tabBarContainerBottom = tabBarContainer.bottomAnchor.constraint(
      equalTo: view.bottomAnchor, constant: -10)
    tabBarContainerBottomConstraint = tabBarContainerBottom

    // ── Constraints (exact ChatNativeTabBarModule pattern) ──
    NSLayoutConstraint.activate([
      // Container at bottom, full width, 64pt tall.
      // Pinned to view.bottomAnchor (NOT safeAreaLayoutGuide) — avoids the 70px gap.
      // The floating UITabBar draws its own glass pill; no safe area padding needed.
      tabBarContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
      tabBarContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
      tabBarContainerBottom,
      tabBarContainer.heightAnchor.constraint(equalToConstant: 64),

      // Tab bar: shift bounding box outward by -16 lead / +8 trail (Apple internal padding fix)
      tabBar.leadingAnchor.constraint(equalTo: tabBarContainer.leadingAnchor, constant: -16),
      tabBar.trailingAnchor.constraint(equalTo: tabBarContainer.trailingAnchor, constant: 16),
      tabBar.centerYAnchor.constraint(equalTo: tabBarContainer.centerYAnchor),

      // Caption chrome: same position as container (initially 0 width)
      captionChromeView.leadingAnchor.constraint(equalTo: tabBarContainer.leadingAnchor),
      captionChromeView.topAnchor.constraint(equalTo: tabBar.topAnchor),
      wC, hC,

      captionIconView.centerXAnchor.constraint(equalTo: captionSendButton.centerXAnchor),
      captionIconView.centerYAnchor.constraint(equalTo: captionSendButton.centerYAnchor),
      captionIconView.widthAnchor.constraint(equalToConstant: 20),
      captionIconView.heightAnchor.constraint(equalToConstant: 20),

      // Text field
      captionField.leadingAnchor.constraint(
        equalTo: captionChromeView.contentView.leadingAnchor, constant: 14),
      captionField.centerYAnchor.constraint(equalTo: captionChromeView.contentView.centerYAnchor),
      captionField.trailingAnchor.constraint(
        equalTo: captionSendButton.leadingAnchor, constant: -8),

      // Send button
      captionSendButton.trailingAnchor.constraint(
        equalTo: captionChromeView.contentView.trailingAnchor, constant: -6),
      captionSendButton.centerYAnchor.constraint(
        equalTo: captionChromeView.contentView.centerYAnchor),
      captionSendButton.widthAnchor.constraint(equalToConstant: 38),
      captionSendButton.heightAnchor.constraint(equalToConstant: 38),
    ])

    // Build tab items
    var items: [UITabBarItem] = []
    for section in MenuSection.allCases {
      let cfg = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
      let selCfg = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
      let sym = section.symbolName
      let tabItem = UITabBarItem(
        title: section.title,
        image: UIImage(systemName: sym, withConfiguration: cfg),
        tag: section.rawValue
      )
      tabItem.selectedImage =
        UIImage(systemName: sym + ".fill", withConfiguration: selCfg)
        ?? UIImage(systemName: sym, withConfiguration: selCfg)
      items.append(tabItem)
    }
    tabBar.items = items
    tabBar.selectedItem = items.first

    selectionFeedback.prepare()
    applyChrome()
  }

  // MARK: - Chrome (exact copy of ChatNativeTabBarModule.applyChrome)

  private func applyChrome() {
    let blurStyle: UIBlurEffect.Style =
      appearance.isDark ? .systemChromeMaterialDark : .systemChromeMaterialLight

    // ── 1. UITabBar natively draws its own glass ──
    let tabAppearance = UITabBarAppearance()
    tabAppearance.configureWithDefaultBackground()
    tabAppearance.shadowColor = .clear
    // We STRICTLY do not set appearance.backgroundColor here.
    tabAppearance.backgroundEffect = UIBlurEffect(style: blurStyle)

    let itemApp = tabAppearance.stackedLayoutAppearance
    let inactiveColor = primaryTextColor.withAlphaComponent(0.50)
    itemApp.normal.iconColor = inactiveColor
    itemApp.normal.titleTextAttributes = [.foregroundColor: inactiveColor]
    itemApp.normal.titlePositionAdjustment = .zero
    itemApp.selected.iconColor = primaryTextColor
    itemApp.selected.titleTextAttributes = [.foregroundColor: primaryTextColor]
    itemApp.selected.titlePositionAdjustment = .zero
    tabAppearance.stackedLayoutAppearance = itemApp
    tabAppearance.inlineLayoutAppearance = itemApp
    tabAppearance.compactInlineLayoutAppearance = itemApp

    tabBar.standardAppearance = tabAppearance
    if #available(iOS 15.0, *) {
      tabBar.scrollEdgeAppearance = tabAppearance
    }

    // ── 2. Caption chrome matches exact material ──
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect()
      glass.isInteractive = true
      captionChromeView.effect = glass
    } else {
      captionChromeView.effect = UIBlurEffect(style: blurStyle)
    }
  }

  @objc private func captionTextDidChange() {
    guard isCaptionMode else { return }
    updateCaptionSendAppearance(animated: true)
  }

  /// Selected media is already sendable; caption text is optional.
  private func updateCaptionSendAppearance(animated: Bool) {
    let apply = {
      self.captionSendButton.backgroundColor = self.accentColor
      self.captionIconView.tintColor = .white
    }
    if animated {
      UIView.animate(withDuration: 0.2, animations: apply)
    } else {
      apply()
    }
  }

  // MARK: - Layout

  private func layoutAll() {
    let safe = view.safeAreaInsets
    let w = view.bounds.width
    let h = view.bounds.height

    // Header title
    let headerTop = safe.top + 8
    let titleWidth = min(240, w - 40)
    headerTitleButton.frame = CGRect(
      x: (w - titleWidth) * 0.5, y: headerTop, width: titleWidth, height: 34
    )

    // Content extends full-bleed: from top to view bottom.
    // Both header and tab bar float on top, with gradient masks for soft edges.
    contentView.frame = CGRect(x: 0, y: 0, width: w, height: h)

    galleryCollectionView.frame = contentView.bounds
    // Top inset pushes content below header; bottom inset keeps it above tab bar
    let topInset = headerTop + 42
    let tabBarOverlap: CGFloat = 80
    galleryCollectionView.contentInset = UIEdgeInsets(
      top: topInset, left: 0, bottom: tabBarOverlap, right: 0)
    galleryCollectionView.scrollIndicatorInsets = UIEdgeInsets(
      top: topInset, left: 0, bottom: tabBarOverlap, right: 0)
    // Under limited access the grid still shows, so the button sits just under the
    // header rather than in the middle of the (non-empty) list.
    let permissionIsInline = !galleryAssets.isEmpty
    galleryPermissionButton.frame = CGRect(
      x: 20,
      y: permissionIsInline ? topInset + 6 : topInset + 64,
      width: w - 40,
      height: 34)
    galleryEmptyLabel.frame = CGRect(
      x: 20, y: topInset + 20, width: w - 40, height: h - topInset - tabBarOverlap - 40)
    if permissionIsInline {
      contentView.bringSubviewToFront(galleryPermissionButton)
    }

    // ── Soft gradient masks ──
    let topMaskH: CGFloat = topInset + 16  // covers header + fade zone
    topMaskView.frame = CGRect(x: 0, y: 0, width: w, height: topMaskH)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    topMaskGradient.frame = topMaskView.bounds
    CATransaction.commit()

    let bottomMaskH: CGFloat = 90  // fade zone above tab bar
    let bottomMaskY = h - bottomMaskH
    bottomMaskView.frame = CGRect(x: 0, y: bottomMaskY, width: w, height: bottomMaskH)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    bottomMaskGradient.frame = bottomMaskView.bounds
    CATransaction.commit()

    // Gallery grid
    let spacing: CGFloat = 2
    let columns: CGFloat = w > 540 ? 5 : 3
    let itemSize = floor((w - ((columns - 1) * spacing)) / columns)
    galleryBaseItem = itemSize
    galleryLayout.columns = Int(columns)
    galleryLayout.spacing = spacing
    galleryLayout.invalidateLayout()

    let scale = view.window?.screen.scale ?? UIScreen.main.scale
    galleryThumbSize = CGSize(width: itemSize * scale, height: itemSize * scale)

    // File/Location use the visible area between header and tab bar
    let fileLocFrame = CGRect(
      x: 0, y: topInset, width: w, height: max(1, h - topInset - tabBarOverlap))
    fileView.frame = fileLocFrame
    locationView.frame = fileLocFrame
    articleView.frame = fileLocFrame
    checklistView.frame = fileLocFrame
    audioView.frame = fileLocFrame
    layoutCenterViews()
    layoutComposerHosts()
    updateCameraPreviewFrame()
  }

  private func layoutComposerHosts() {
    let bounds = articleView.bounds
    let card = articleView.viewWithTag(10)
    card?.frame = CGRect(x: 16, y: 12, width: bounds.width - 32, height: 168)
    articleView.viewWithTag(11)?.frame = CGRect(x: 16, y: 16, width: (card?.bounds.width ?? 0) - 32, height: 22)
    articleField.frame = CGRect(x: 16, y: 48, width: (card?.bounds.width ?? bounds.width) - 32, height: 44)
    articleSendButton.frame = CGRect(x: 16, y: 104, width: (card?.bounds.width ?? bounds.width) - 32, height: 44)
    checklistView.viewWithTag(21)?.frame = CGRect(x: 16, y: 24, width: bounds.width - 32, height: 28)
    checklistField.frame = CGRect(x: 16, y: 68, width: bounds.width - 32, height: 44)
    let send = checklistView.viewWithTag(24)
    send?.frame = CGRect(x: 16, y: bounds.height - 56, width: bounds.width - 32, height: 44)
    checklistList.frame = CGRect(x: 16, y: 124, width: bounds.width - 32, height: max(40, bounds.height - 190))
  }

  private func layoutCenterViews() {
    let insetBounds = contentView.bounds.insetBy(dx: 12, dy: 12)
    // Only location uses the classic center layout now
    for host in [locationView, audioView] {
      guard host.subviews.count >= 3 else { continue }
      let title = host.subviews[0]
      let subtitle = host.subviews[1]
      let button = host.subviews[2]
      title.frame = CGRect(
        x: 0, y: max(20, insetBounds.height * 0.22), width: insetBounds.width, height: 28)
      subtitle.frame = CGRect(
        x: 16, y: title.frame.maxY + 8, width: insetBounds.width - 32, height: 40)
      button.frame = CGRect(
        x: max(16, (insetBounds.width - 220) * 0.5),
        y: subtitle.frame.maxY + 18,
        width: min(220, insetBounds.width - 32), height: 44
      )
      title.center.x = host.bounds.midX
      subtitle.center.x = host.bounds.midX
      button.center.x = host.bounds.midX
    }
  }

  // MARK: - Section Switching

  private func setActiveSection(_ section: MenuSection, animated: Bool) {
    let previous = activeSection
    activeSection = section
    if section == .gallery { refreshGalleryAssets() }
    updateHeaderButton()

    guard animated && previous != section else {
      showHostView(for: section)
      return
    }

    let target = hostView(for: section)
    let from = hostView(for: previous)

    // Hide all first, then just show target and from
    [galleryCollectionView, galleryEmptyLabel, galleryPermissionButton, fileView, locationView,
      articleView, checklistView, audioView]
      .forEach {
        $0.isHidden = true
      }
    from.isHidden = false
    target.isHidden = false
    let targetEmptyLabelVisible = (section == .gallery && galleryAssets.isEmpty)
    let fromEmptyLabelVisible = (previous == .gallery && galleryAssets.isEmpty)
    if targetEmptyLabelVisible || fromEmptyLabelVisible {
      galleryEmptyLabel.isHidden = false
    }

    let width = contentView.bounds.width
    let dir: CGFloat = section.rawValue > previous.rawValue ? 1.0 : -1.0
    target.alpha = 1
    target.transform = CGAffineTransform(translationX: dir * width, y: 0)
    from.transform = .identity
    from.alpha = 1
    if targetEmptyLabelVisible {
      galleryEmptyLabel.alpha = 1
      galleryEmptyLabel.transform = CGAffineTransform(translationX: dir * width, y: 0)
    }

    UIView.animate(withDuration: 0.32, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
      from.transform = CGAffineTransform(translationX: -dir * width, y: 0)
      target.transform = .identity
      if targetEmptyLabelVisible {
        self.galleryEmptyLabel.transform = .identity
      } else if fromEmptyLabelVisible {
        self.galleryEmptyLabel.transform = CGAffineTransform(translationX: -dir * width, y: 0)
      }
    } completion: { _ in
      self.showHostView(for: section)
      from.transform = .identity
      self.galleryEmptyLabel.transform = .identity
      self.galleryEmptyLabel.alpha = 1
    }
  }

  private func showHostView(for section: MenuSection) {
    galleryCollectionView.isHidden = section != .gallery
    galleryEmptyLabel.isHidden = section != .gallery || !galleryAssets.isEmpty
    galleryPermissionButton.isHidden = section != .gallery || !galleryNeedsPermissionAction
    fileView.isHidden = section != .file
    locationView.isHidden = section != .location
    articleView.isHidden = section != .article
    checklistView.isHidden = section != .checklist
    audioView.isHidden = section != .audio
  }

  /// Limited access can add more, denied access can be changed in Settings; full
  /// access has nothing to offer.
  private var galleryNeedsPermissionAction: Bool {
    switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
    case .authorized, .notDetermined: return false
    default: return true
    }
  }

  private func hostView(for section: MenuSection) -> UIView {
    switch section {
    case .gallery: return galleryCollectionView
    case .file: return fileView
    case .location: return locationView
    case .article: return articleView
    case .checklist: return checklistView
    case .audio: return audioView
    }
  }

  // MARK: - Header Button

  private func updateHeaderButton() {
    let title = activeSection == .gallery ? activeGalleryFilter.rawValue : activeSection.title
    let showsArrow = activeSection == .gallery

    headerTitleButton.menu = activeSection == .gallery ? buildFilterMenu() : nil
    headerTitleButton.showsMenuAsPrimaryAction = activeSection == .gallery

    var attributes = AttributeContainer()
    attributes.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    var config = UIButton.Configuration.plain()
    config.attributedTitle = AttributedString(title, attributes: attributes)
    config.baseForegroundColor = primaryTextColor
    config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10)
    config.titleAlignment = .center
    if showsArrow {
      config.image = UIImage(
        systemName: "chevron.down",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
      )
      config.imagePlacement = .trailing
      config.imagePadding = 4
    }
    headerTitleButton.configuration = config
  }

  private func buildFilterMenu() -> UIMenu {
    UIMenu(
      children: GalleryFilter.allCases.map { filter in
        UIAction(
          title: filter.rawValue,
          image: UIImage(
            systemName: filter == .recent ? "clock" : filter == .videos ? "video" : "photo"),
          state: activeGalleryFilter == filter ? .on : .off
        ) { [weak self] _ in
          self?.setGalleryFilter(filter)
        }
      })
  }

  private func setGalleryFilter(_ filter: GalleryFilter) {
    guard activeGalleryFilter != filter else { return }
    activeGalleryFilter = filter
    updateHeaderButton()
    applyGalleryFilter()
  }

  // MARK: - Selection / Caption Mode (exact setVibeExpanded pattern)

  /// Called when the selection toggle on a cell is tapped.
  func handleSelectToggle(assetIndex: Int) {
    guard assetIndex < galleryAssets.count else { return }
    if let position = selectedAssetIndices.firstIndex(of: assetIndex) {
      // Deselect this one; caption mode collapses when nothing is left.
      selectedAssetIndices.remove(at: position)
      setCellChecked(assetIndex: assetIndex, checked: false)
      selectionFeedback.selectionChanged()
      selectionFeedback.prepare()
      if selectedAssetIndices.isEmpty { exitCaptionMode() }
      return
    }
    // A video sends alone: picking one clears any prior picks, and picking an image
    // while a video is selected drops the video.
    let tappedIsVideo = galleryAssets[assetIndex].mediaType == .video
    let hasVideoSelected = selectedAssetIndices.contains {
      $0 < galleryAssets.count && galleryAssets[$0].mediaType == .video
    }
    if tappedIsVideo || hasVideoSelected {
      let previous = selectedAssetIndices
      selectedAssetIndices = []
      previous.forEach { setCellChecked(assetIndex: $0, checked: false) }
    }
    guard selectedAssetIndices.count < Self.maxMultiSelect else { return }
    selectedAssetIndices.append(assetIndex)
    setCellChecked(assetIndex: assetIndex, checked: true)
    selectionFeedback.selectionChanged()
    selectionFeedback.prepare()
    enterCaptionMode()
  }

  private func setCellChecked(assetIndex: Int, checked: Bool) {
    let ip = IndexPath(item: assetIndex + 1, section: 0)
    if let cell = galleryCollectionView.cellForItem(at: ip) as? ChatAttachmentAssetCell {
      cell.setChecked(checked, animated: true)
    }
  }

  private func enterCaptionMode() {
    guard !isCaptionMode else { return }
    isCaptionMode = true
    captionChromeView.isHidden = false
    let tabFrame = tabBar.bounds
    if captionWidthConstraint?.constant == 0 {
      captionWidthConstraint?.constant = max(64, tabFrame.width)
      captionHeightConstraint?.constant = max(44, tabFrame.height)
      captionChromeView.layer.cornerRadius = 22
      tabBarContainer.layoutIfNeeded()
    }

    captionChromeView.contentView.bringSubviewToFront(captionSendButton)
    captionChromeView.contentView.bringSubviewToFront(captionIconView)

    UIView.animate(
      withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.92, initialSpringVelocity: 0.12,
      options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]
    ) {
      let fullWidth = self.tabBarContainer.bounds.width
      self.captionWidthConstraint?.constant = fullWidth
      self.captionHeightConstraint?.constant = 50
      self.captionChromeView.layer.cornerRadius = 25
      self.tabBar.alpha = 0
      self.tabBar.transform = .identity
      self.captionIconView.transform = .identity
      self.captionSendButton.layer.cornerRadius = 19
      self.captionSendButton.backgroundColor = self.accentColor
      self.captionIconView.alpha = 1
      self.captionIconView.tintColor = .white
      self.captionField.alpha = 1
      self.captionSendButton.alpha = 1
      self.tabBarContainer.layoutIfNeeded()
    }
  }

  private func exitCaptionMode() {
    guard isCaptionMode else { return }
    isCaptionMode = false
    captionField.resignFirstResponder()
    captionField.text = ""

    let previous = selectedAssetIndices
    selectedAssetIndices = []
    previous.forEach { setCellChecked(assetIndex: $0, checked: false) }

    UIView.animate(
      withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.2,
      options: .curveEaseInOut
    ) {
      self.captionWidthConstraint?.constant = 0
      self.captionHeightConstraint?.constant = 0
      self.captionChromeView.layer.cornerRadius = 30

      self.tabBar.alpha = 1
      self.tabBar.transform = .identity

      self.captionIconView.transform = .identity
      self.captionIconView.alpha = 1.0
      self.captionIconView.tintColor = self.primaryTextColor.withAlphaComponent(0.7)

      self.captionField.alpha = 0
      self.captionSendButton.alpha = 0
      self.captionSendButton.backgroundColor = .clear

      self.tabBarContainer.layoutIfNeeded()
    } completion: { _ in
      self.captionChromeView.isHidden = true
    }
  }

  @objc private func sendSelectedItem() {
    let indices = selectedAssetIndices.filter { $0 < galleryAssets.count }
    guard !indices.isEmpty else { return }
    presentComposer(for: indices.map { galleryAssets[$0] }, startIndex: 0)
  }

  /// Export every selected image to a temp file, then hand ALL uris (selection order)
  /// + the shared caption to the host in one callback, so an agent DM can dispatch a
  /// single task carrying the whole set.
  private func sendSelectedImages(_ assets: [PHAsset]) {
    guard !assets.isEmpty, !isSelectingAsset else { return }
    isSelectingAsset = true
    let caption = currentCaption()
    let group = DispatchGroup()
    let lock = NSLock()
    var urisByIndex: [Int: String] = [:]
    for (index, asset) in assets.enumerated() {
      group.enter()
      let options = PHImageRequestOptions()
      options.isNetworkAccessAllowed = true
      options.deliveryMode = .highQualityFormat
      options.version = .current
      PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) {
        data, uti, _, _ in
        defer { group.leave() }
        guard let data else { return }
        let ext: String = {
          if let uti, let type = UTType(uti) { return type.preferredFilenameExtension ?? "jpg" }
          return "jpg"
        }()
        guard let url = VibeMediaVault.shared.persistOutgoingPick(data: data, fileExtension: ext)
        else { return }
        lock.lock()
        urisByIndex[index] = url.absoluteString
        lock.unlock()
      }
    }
    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      self.isSelectingAsset = false
      let uris = urisByIndex.keys.sorted().compactMap { urisByIndex[$0] }
      guard !uris.isEmpty else { return }
      self.finishAndDismiss {
        if uris.count == 1 {
          self.onSelectImage?(uris[0], caption, nil)
        } else {
          self.onSelectImages?(uris, caption, nil)
        }
      }
    }
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    if textField === articleField {
      sendArticle()
      return true
    }
    if textField === checklistField {
      let item = checklistField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !item.isEmpty {
        checklistItems.append(item)
        checklistField.text = ""
        let row = UILabel()
        row.text = "☐ \(item)"
        row.font = .systemFont(ofSize: 16)
        row.textColor = primaryTextColor
        checklistList.addArrangedSubview(row)
      }
      return true
    }
    if isCaptionMode { sendSelectedItem() }
    return true
  }

  // MARK: - Gallery

  private func refreshGalleryAssets() {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    switch status {
    case .authorized:
      galleryPermissionButton.isHidden = true
      loadGalleryAssets()
    case .limited:
      // Only some of the library is visible, and the grid cannot say so on its
      // own — a short library reads as an empty one.
      galleryPermissionButton.isHidden = false
      galleryPermissionButton.setTitle("Select More Photos", for: .normal)
      loadGalleryAssets()
    case .notDetermined:
      // `.readWrite` covers photos *and* videos; asking for `.addOnly` or a
      // narrower scope is what leaves the Videos tab permanently empty.
      PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] _ in
        DispatchQueue.main.async { self?.refreshGalleryAssets() }
      }
    default:
      allGalleryAssets = []
      galleryAssets = []
      galleryCollectionView.reloadData()
      galleryEmptyLabel.text = "Vibe needs access to your photos and videos"
      galleryEmptyLabel.isHidden = false
      galleryPermissionButton.isHidden = false
      galleryPermissionButton.setTitle("Open Settings", for: .normal)
    }
  }

  /// Fetches the *active filter* from the library rather than slicing a
  /// pre-truncated list. The old version pulled the 300 newest assets of any type
  /// and filtered in memory, so "Videos" was empty for anyone whose 300 most
  /// recent items happened to be photos.
  private func loadGalleryAssets() {
    let opts = PHFetchOptions()
    opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    opts.fetchLimit = 300
    let image = PHAssetMediaType.image.rawValue
    let video = PHAssetMediaType.video.rawValue
    switch activeGalleryFilter {
    case .recent:
      // Explicit, so audio and whatever else the library holds stay out of a grid
      // that can only send pictures and video.
      opts.predicate = NSPredicate(
        format: "mediaType == %d || mediaType == %d", image, video)
    case .photos:
      opts.predicate = NSPredicate(format: "mediaType == %d", image)
    case .videos:
      opts.predicate = NSPredicate(format: "mediaType == %d", video)
    }

    let fetch = PHAsset.fetchAssets(with: opts)
    var next: [PHAsset] = []
    next.reserveCapacity(fetch.count)
    fetch.enumerateObjects { asset, _, _ in next.append(asset) }
    allGalleryAssets = next
    galleryAssets = next
    galleryCollectionView.reloadData()
    galleryEmptyLabel.text =
      activeGalleryFilter == .videos ? "No videos found" : "No photos found"
    galleryEmptyLabel.isHidden = !galleryAssets.isEmpty
  }

  private func applyGalleryFilter() {
    loadGalleryAssets()
  }

  @objc private func handleGalleryPermissionTap() {
    if PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited {
      PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: self)
      return
    }
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }

  private func currentCaption() -> String? {
    let v = captionField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return v.isEmpty ? nil : v
  }

  // MARK: - Send

  private func sendSelectedAsset(_ asset: PHAsset, skipEditor: Bool = false) {
    guard !isSelectingAsset else { return }
    isSelectingAsset = true
    if asset.mediaType == .video {
      sendVideo(asset, skipEditor: skipEditor)
      return
    }
    let options = PHImageRequestOptions()
    options.isNetworkAccessAllowed = true
    options.deliveryMode = .highQualityFormat
    options.version = .current
    PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) {
      [weak self] data, uti, _, _ in
      guard let self, let data else {
        DispatchQueue.main.async { self?.isSelectingAsset = false }
        return
      }
      let ext: String = {
        if let uti, let type = UTType(uti) { return type.preferredFilenameExtension ?? "jpg" }
        return "jpg"
      }()
      guard let url = VibeMediaVault.shared.persistOutgoingPick(data: data, fileExtension: ext)
      else {
        DispatchQueue.main.async { self.isSelectingAsset = false }
        return
      }
      DispatchQueue.main.async {
        self.isSelectingAsset = false
        if skipEditor {
          self.finishAndDismiss {
            self.onSelectImage?(url.absoluteString, self.currentCaption(), nil)
          }
        } else {
          self.presentEditor(for: url, initialImage: UIImage(data: data))
        }
      }
    }
  }

  private func presentEditor(for url: URL, initialImage: UIImage?) {
    presentComposerPages(
      [ChatImageEditGalleryPage(mediaURL: url.absoluteString, image: initialImage)],
      startIndex: 0,
      fallbackURL: url)
  }

  private func presentComposer(for assets: [PHAsset], startIndex: Int) {
    guard !assets.isEmpty, !isSelectingAsset else { return }
    if assets.count == 1, assets[0].mediaType == .video {
      isSelectingAsset = true
      sendVideo(assets[0], skipEditor: false)
      return
    }
    let images = assets.filter { $0.mediaType == .image }
    guard !images.isEmpty else { return }
    isSelectingAsset = true
    let group = DispatchGroup()
    let lock = NSLock()
    var pagesByIndex: [Int: ChatImageEditGalleryPage] = [:]
    for (index, asset) in images.enumerated() {
      group.enter()
      let options = PHImageRequestOptions()
      options.isNetworkAccessAllowed = true
      options.deliveryMode = .highQualityFormat
      options.version = .current
      PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) {
        data, uti, _, _ in
        defer { group.leave() }
        guard let data else { return }
        let ext: String = {
          if let uti, let type = UTType(uti) { return type.preferredFilenameExtension ?? "jpg" }
          return "jpg"
        }()
        guard let url = VibeMediaVault.shared.persistOutgoingPick(data: data, fileExtension: ext)
        else { return }
        lock.lock()
        pagesByIndex[index] = ChatImageEditGalleryPage(
          mediaURL: url.absoluteString, image: UIImage(data: data))
        lock.unlock()
      }
    }
    group.notify(queue: .main) { [weak self] in
      guard let self else { return }
      self.isSelectingAsset = false
      let pages = pagesByIndex.keys.sorted().compactMap { pagesByIndex[$0] }
      guard let first = pages.first, let url = URL(string: first.mediaURL) else { return }
      self.presentComposerPages(pages, startIndex: min(startIndex, pages.count - 1), fallbackURL: url)
    }
  }

  private func presentComposerPages(
    _ pages: [ChatImageEditGalleryPage], startIndex: Int, fallbackURL: URL
  ) {
    let onSelectImage = self.onSelectImage
    let onSelectImages = self.onSelectImages
    ChatImageEditModule.presentEditor(
      from: self,
      messageId: nil,
      mediaURL: (startIndex >= 0 && startIndex < pages.count)
        ? pages[startIndex].mediaURL : fallbackURL.absoluteString,
      initialImage: (startIndex >= 0 && startIndex < pages.count)
        ? pages[startIndex].image : pages.first?.image,
      initialCaption: currentCaption(),
      headerTitle: recipientName,
      dismissPresenterOnSend: true,
      galleryPages: pages,
      startIndex: startIndex,
      allowsFilmstrip: false,
      zoomSourceProvider: self
    ) { [weak self] payload in
      guard payload.eventType == .sendNew else { return }
      let primary = payload.editedImageURL ?? fallbackURL
      var uris = [primary.absoluteString]
      uris.append(contentsOf: payload.extraImageURLs.map(\.absoluteString))
      let caption = payload.caption ?? self?.currentCaption()
      ChatAttachSendContext.pending = ChatAttachmentSendOptions(
        viewOnce: payload.viewOnce,
        mediaTtlSeconds: payload.mediaTtlSeconds,
        isHighQuality: payload.isHighQuality)
      let send: () -> Void = {
        if uris.count == 1 {
          onSelectImage?(uris[0], caption, nil)
        } else {
          onSelectImages?(uris, caption, nil)
        }
      }
      if let self {
        self.finishAndDismiss(send)
      } else {
        send()
      }
    }
  }

  private func sendVideo(_ asset: PHAsset, skipEditor: Bool = false) {
    let opts = PHVideoRequestOptions()
    opts.isNetworkAccessAllowed = true
    opts.deliveryMode = .highQualityFormat
    PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) {
      [weak self] avAsset, _, _ in
      guard let self, let avAsset else {
        DispatchQueue.main.async { self?.isSelectingAsset = false }
        return
      }
      DispatchQueue.main.async {
        if skipEditor {
          self.persistSelectedVideoAsset(avAsset)
        } else {
          self.isSelectingAsset = false
          self.presentVideoEditor(for: avAsset)
        }
      }
    }
  }

  private func presentVideoEditor(for asset: AVAsset) {
    let onSelectImage = self.onSelectImage
    ChatVideoEditModule.presentEditor(
      from: self,
      asset: asset,
      initialCaption: currentCaption()
    ) { [weak self] payload in
      if let self = self {
        self.finishAndDismiss {
          onSelectImage?(
            payload.videoURL.absoluteString,
            payload.caption,
            payload.transitionCapture
          )
        }
      } else {
        onSelectImage?(
          payload.videoURL.absoluteString,
          payload.caption,
          payload.transitionCapture
        )
      }
    }
  }

  private func persistSelectedVideoAsset(_ asset: AVAsset) {
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      
      let exportPresets = AVAssetExportSession.exportPresets(compatibleWith: asset)
      let preferredPresets = [
        AVAssetExportPreset1280x720,
        AVAssetExportPreset960x540,
        AVAssetExportPresetMediumQuality,
      ]

      if let presetName = preferredPresets.first(where: { exportPresets.contains($0) }),
        let exportSession = AVAssetExportSession(asset: asset, presetName: presetName),
        let outputFileType =
          ([AVFileType.mov, .mp4].first { exportSession.supportedFileTypes.contains($0) })
          ?? exportSession.supportedFileTypes.first
      {
        let outputExtension = outputFileType == .mov ? "mov" : "mp4"
        let outputURL = FileManager.default.temporaryDirectory
          .appendingPathComponent("gallery-video-\(UUID().uuidString)")
          .appendingPathExtension(outputExtension)

        if FileManager.default.fileExists(atPath: outputURL.path) {
          try? FileManager.default.removeItem(at: outputURL)
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = outputFileType
        exportSession.shouldOptimizeForNetworkUse = true
        NSLog(
          "[ChatAttachmentVideoExport] start preset=%@ fileType=%@ output=%@",
          presetName,
          outputFileType.rawValue,
          outputURL.lastPathComponent
        )
        exportSession.exportAsynchronously { [weak self] in
          DispatchQueue.main.async {
            guard let self else { return }
            if exportSession.status == .completed,
              self.isUsableExportedVideo(outputURL, logContext: "gallery_export")
            {
              let durable =
                VibeMediaVault.shared.persistOutgoingPick(fileAt: outputURL, move: true)
                ?? outputURL
              self.isSelectingAsset = false
              self.finishAndDismiss {
                self.onSelectImage?(durable.absoluteString, self.currentCaption(), nil)
              }
              return
            }

            if let urlAsset = asset as? AVURLAsset,
              let fallbackURL = try? self.copyVideoToTemporaryURL(from: urlAsset.url)
            {
              self.isSelectingAsset = false
              self.finishAndDismiss {
                self.onSelectImage?(fallbackURL.absoluteString, self.currentCaption(), nil)
              }
              return
            }

            self.isSelectingAsset = false
          }
        }
        return
      }

      if let urlAsset = asset as? AVURLAsset {
        do {
          let url = try self.copyVideoToTemporaryURL(from: urlAsset.url)
          DispatchQueue.main.async {
            self.isSelectingAsset = false
            self.finishAndDismiss { self.onSelectImage?(url.absoluteString, self.currentCaption(), nil) }
          }
        } catch {
          DispatchQueue.main.async { self.isSelectingAsset = false }
        }
        return
      }

      DispatchQueue.main.async {
        self.isSelectingAsset = false
      }
    }
  }

  private func isUsableExportedVideo(_ url: URL, logContext: String) -> Bool {
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    let byteSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    guard byteSize > 0 else {
      NSLog("[ChatAttachmentVideoExport] %@ invalid empty path=%@", logContext, url.path)
      return false
    }
    let asset = AVURLAsset(url: url)
    let videoTracks = asset.tracks(withMediaType: .video)
    if asset.isPlayable && !videoTracks.isEmpty {
      NSLog(
        "[ChatAttachmentVideoExport] %@ validated path=%@ bytes=%lld tracks=%d",
        logContext,
        url.path,
        byteSize,
        videoTracks.count
      )
      return true
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 640.0, height: 640.0)
    let probeTimes: [Double] = [0.0, 0.05, 0.12, 0.25, 0.5]
    var lastErrorDescription = "unknown"
    for seconds in probeTimes {
      do {
        _ = try generator.copyCGImage(
          at: CMTime(seconds: seconds, preferredTimescale: 600),
          actualTime: nil
        )
        NSLog(
          "[ChatAttachmentVideoExport] %@ validated by frame path=%@ bytes=%lld frame=%.2f",
          logContext,
          url.path,
          byteSize,
          seconds
        )
        return true
      } catch {
        lastErrorDescription = error.localizedDescription
      }
    }
    NSLog(
      "[ChatAttachmentVideoExport] %@ invalid path=%@ bytes=%lld tracks=%d playable=%@ error=%@",
      logContext,
      url.path,
      byteSize,
      videoTracks.count,
      asset.isPlayable ? "Y" : "N",
      lastErrorDescription
    )
    return false
  }

  private func copyVideoToTemporaryURL(from sourceURL: URL) throws -> URL {
    if let durable = VibeMediaVault.shared.persistOutgoingPick(fileAt: sourceURL, move: false) {
      return durable
    }
    let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
    let destinationURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("gallery-video-\(UUID().uuidString)")
      .appendingPathExtension(ext)
    if FileManager.default.fileExists(atPath: destinationURL.path) {
      try FileManager.default.removeItem(at: destinationURL)
    }
    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    return destinationURL
  }

  private func finishAndDismiss(_ action: @escaping () -> Void) {
    if let presenter = presentingViewController {
      presenter.dismiss(animated: true) {
        action()
      }
    } else {
      dismiss(animated: true) {
        action()
      }
    }
  }

  // MARK: - Actions

  @objc private func openFullGalleryPicker() {
    view.endEditing(true)
    var config = PHPickerConfiguration(photoLibrary: .shared())
    config.selectionLimit = 1
    config.filter = .any(of: [.images, .videos])
    config.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    present(picker, animated: true)
  }

  @objc private func openFilePicker() {
    view.endEditing(true)
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
    picker.delegate = self
    picker.allowsMultipleSelection = false
    present(picker, animated: true)
  }

  @objc private func openLocation() {
    view.endEditing(true)
    ChatAttachmentMenuLocationManager.shared.requestOnce { [weak self] coord in
      DispatchQueue.main.async {
        guard let self else { return }
        self.finishAndDismiss { self.onSelectLocation?(coord.latitude, coord.longitude) }
      }
    }
  }

  // MARK: - Camera
  
  private func bindCameraPreview(to hostView: UIView) {
    cameraPreviewHostView = hostView
    let layer = ChatAttachmentMenuCameraManager.shared.previewLayer
    if layer.superlayer !== hostView.layer {
      layer.removeFromSuperlayer()
      hostView.layer.insertSublayer(layer, at: 0)
    }
    updateCameraPreviewFrame()
  }

  private func updateCameraPreviewFrame() {
    guard let host = cameraPreviewHostView else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    ChatAttachmentMenuCameraManager.shared.previewLayer.frame = host.bounds
    CATransaction.commit()
  }

  private func updateCameraTileLoadingState() {
    let indexPath = IndexPath(item: 0, section: 0)
    if let cell = galleryCollectionView.cellForItem(at: indexPath) as? ChatAttachmentCameraCell {
      cell.setLoading(isCameraLoading)
      cell.setCameraAvailable(cameraPreviewAvailable)
    }
  }

  private func startCameraPreview() {
    isCameraLoading = true
    updateCameraTileLoadingState()
    ChatAttachmentMenuCameraManager.shared.requestStart { [weak self] success in
      self?.cameraPreviewAvailable = success
      // Small delay to ensure the first frame is actually visible before removing blur
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        self?.isCameraLoading = false
        self?.updateCameraTileLoadingState()
      }
    }
  }

  private func stopCameraPreview() {
    ChatAttachmentMenuCameraManager.shared.previewLayer.removeFromSuperlayer()
    cameraPreviewHostView = nil
    ChatAttachmentMenuCameraManager.shared.requestStop()
  }

  // MARK: - Helpers

  private func setupCenterAction(
    _ host: UIView, title: String, subtitle: String,
    button: UIButton, buttonTitle: String, symbol: String
  ) {
    let titleLabel = UILabel()
    titleLabel.text = title
    titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
    titleLabel.textColor = primaryTextColor
    titleLabel.textAlignment = .center
    host.addSubview(titleLabel)

    let subtitleLabel = UILabel()
    subtitleLabel.text = subtitle
    subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
    subtitleLabel.textColor = secondaryTextColor
    subtitleLabel.textAlignment = .center
    subtitleLabel.numberOfLines = 2
    host.addSubview(subtitleLabel)

    button.layer.cornerRadius = 15
    button.layer.cornerCurve = .continuous
    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: symbol)
    config.imagePlacement = .leading
    config.imagePadding = 6
    config.baseForegroundColor = primaryTextColor
    config.title = buttonTitle
    config.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12)
    button.configuration = config
    button.backgroundColor = primaryTextColor.withAlphaComponent(appearance.isDark ? 0.06 : 0.05)
    host.addSubview(button)
  }
}

// MARK: - UITabBarDelegate

extension ChatAttachmentMenuController: UITabBarDelegate {
  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    guard let section = MenuSection(rawValue: item.tag) else { return }
    if section != activeSection {
      selectionFeedback.selectionChanged()
      selectionFeedback.prepare()
    }
    if isCaptionMode { exitCaptionMode() }
    setActiveSection(section, animated: true)
  }
}

// MARK: - UIDocumentPickerDelegate

extension ChatAttachmentMenuController: UIDocumentPickerDelegate {
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL])
  {
    guard let url = urls.first else { return }
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
    ChatRecentSentFilesStore.shared.record(
      sourceURL: url, displayName: url.lastPathComponent, byteSize: size)
    finishAndDismiss { self.onSelectFile?(url.absoluteString, url.lastPathComponent) }
  }
}

extension ChatAttachmentMenuController: UITableViewDataSource, UITableViewDelegate {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    recentEntries.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "recent-file", for: indexPath)
    let entry = recentEntries[indexPath.row]
    var content = cell.defaultContentConfiguration()
    content.text = entry.fileName
    content.secondaryText = Self.recentFileSubtitle(entry)
    content.image = UIImage(systemName: "doc.fill")
    content.imageProperties.tintColor = .systemBlue
    content.textProperties.color = primaryTextColor
    content.secondaryTextProperties.color = secondaryTextColor
    cell.contentConfiguration = content
    cell.backgroundColor = .clear
    cell.selectionStyle = .default
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let entry = recentEntries[indexPath.row]
    let url = ChatRecentSentFilesStore.shared.fileURL(for: entry)
    finishAndDismiss { self.onSelectFile?(url.absoluteString, entry.fileName) }
  }

  private static func recentFileSubtitle(_ entry: ChatRecentSentFilesStore.Entry) -> String {
    let size = ByteCountFormatter.string(fromByteCount: entry.byteSize, countStyle: .file)
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return "\(size) · \(formatter.string(from: entry.sentAt))"
  }
}

extension ChatAttachmentMenuController: VNDocumentCameraViewControllerDelegate {
  @objc private func openDocumentScanner() {
    guard VNDocumentCameraViewController.isSupported else {
      openFilePicker()
      return
    }
    let scanner = VNDocumentCameraViewController()
    scanner.delegate = self
    present(scanner, animated: true)
  }

  func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
    controller.dismiss(animated: true)
  }

  func documentCameraViewController(
    _ controller: VNDocumentCameraViewController, didFailWithError error: Error
  ) {
    controller.dismiss(animated: true)
  }

  func documentCameraViewController(
    _ controller: VNDocumentCameraViewController,
    didFinishWith scan: VNDocumentCameraScan
  ) {
    controller.dismiss(animated: true)
    guard scan.pageCount > 0 else { return }
    let image = scan.imageOfPage(at: 0)
    guard let data = image.jpegData(compressionQuality: 0.88),
      let url = VibeMediaVault.shared.persistOutgoingPick(data: data, fileExtension: "jpg")
    else { return }
    presentEditor(for: url, initialImage: image)
  }

  @objc private func openAudioPicker() {
    view.endEditing(true)
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio, .mp3, .mpeg4Audio])
    picker.delegate = self
    picker.allowsMultipleSelection = false
    present(picker, animated: true)
  }

  @objc private func sendArticle() {
    let text = articleField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !text.isEmpty else { return }
    finishAndDismiss { self.onSelectText?(text) }
  }

  @objc private func sendChecklist() {
    let pending = checklistField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var items = checklistItems
    if !pending.isEmpty { items.append(pending) }
    guard !items.isEmpty else { return }
    let body = items.map { "☐ \($0)" }.joined(separator: "\n")
    finishAndDismiss { self.onSelectText?(body) }
  }
}

// MARK: - Shared-element anchor for the editor

extension ChatAttachmentMenuController: ChatMediaZoomSourceProviding {
  /// The picker has no message ids — there is exactly one photo in flight, the
  /// one whose thumbnail was tapped, so both arguments are ignored here.
  func chatMediaZoomSource(forMessageId messageId: String?, pageIndex: Int)
    -> ChatMediaZoomSource?
  {
    guard let anchor = zoomAnchorCellImageView, anchor.window != nil else { return nil }
    return makeChatMediaZoomSource(for: anchor)
  }

  func chatMediaZoomSetSourceHidden(
    _ hidden: Bool,
    forMessageId messageId: String?,
    pageIndex: Int
  ) {
    zoomAnchorCellImageView?.alpha = hidden ? 0 : 1
  }

  func chatMediaZoomInstallFlightView(_ flightView: UIView, frameInWindow: CGRect) -> UIView? {
    // The picker header is a sibling above `contentView`; mounting the flight in
    // content keeps the same invariant as the chat list.
    contentView.addSubview(flightView)
    flightView.frame = contentView.convert(frameInWindow, from: nil)
    return contentView
  }
}

// MARK: - Collection View

extension ChatAttachmentMenuController:
  UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout
{
  func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    galleryAssets.count + 1
  }

  func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath)
    -> UICollectionViewCell
  {
    if indexPath.item == 0 {
      guard
        let cell = cv.dequeueReusableCell(
          withReuseIdentifier: ChatAttachmentCameraCell.reuseIdentifier, for: indexPath
        ) as? ChatAttachmentCameraCell
      else { return UICollectionViewCell() }
      cell.setCameraAvailable(cameraPreviewAvailable)
      cell.setLoading(isCameraLoading)
      bindCameraPreview(to: cell.previewView)
      return cell
    }
    guard
      let cell = cv.dequeueReusableCell(
        withReuseIdentifier: ChatAttachmentAssetCell.reuseIdentifier, for: indexPath
      ) as? ChatAttachmentAssetCell
    else { return UICollectionViewCell() }

    let assetIdx = indexPath.item - 1
    guard assetIdx < galleryAssets.count else { return cell }
    let asset = galleryAssets[assetIdx]
    cell.representedAssetId = asset.localIdentifier
    cell.imageView.image = nil
    cell.configureVideoBadge(isVideo: asset.mediaType == .video, duration: asset.duration)
    cell.onSelectToggle = { [weak self] in
      self?.handleSelectToggle(assetIndex: assetIdx)
    }
    // Show checked state if this cell matches current selection
    cell.setChecked(selectedAssetIndices.contains(assetIdx), animated: false)

    let targetSize = galleryThumbSize == .zero ? CGSize(width: 300, height: 300) : galleryThumbSize
    let opts = PHImageRequestOptions()
    opts.deliveryMode = .opportunistic
    opts.resizeMode = .fast
    opts.isNetworkAccessAllowed = true
    photoManager.requestImage(
      for: asset, targetSize: targetSize, contentMode: .aspectFill, options: opts
    ) { image, _ in
      guard cell.representedAssetId == asset.localIdentifier else { return }
      cell.imageView.image = image
    }
    return cell
  }

  // Tap on cell body = open editor directly (not selection)
  func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    cv.deselectItem(at: indexPath, animated: false)
    if indexPath.item == 0 {
      openSystemCamera()
      return
    }
    let assetIdx = indexPath.item - 1
    guard assetIdx < galleryAssets.count else { return }
    // Remember the thumbnail so the editor can grow out of it. Held weakly: the
    // grid can recycle the cell while the asset's full-size data is still loading.
    zoomAnchorCellImageView = (cv.cellForItem(at: indexPath) as? ChatAttachmentAssetCell)?.imageView
    var indices = selectedAssetIndices.filter { $0 < galleryAssets.count }
    if !indices.contains(assetIdx) { indices.insert(assetIdx, at: 0) }
    if indices.isEmpty { indices = [assetIdx] }
    let start = indices.firstIndex(of: assetIdx) ?? 0
    presentComposer(for: indices.map { galleryAssets[$0] }, startIndex: start)
  }

  // This goes through the generic FlowLayout delegate method, but
  // GalleryGridLayout doesn't actually use this. It's safe to keep or remove.
  func collectionView(
    _ cv: UICollectionView,
    layout: UICollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> CGSize {
    let base = max(1, galleryBaseItem)
    return CGSize(width: base, height: base)
  }
}

// MARK: - Camera Picker

extension ChatAttachmentMenuController: UIImagePickerControllerDelegate,
  UINavigationControllerDelegate
{
  private func openSystemCamera() {
    guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.mediaTypes = ["public.image", "public.movie"]
    picker.delegate = self
    present(picker, animated: true)
  }

  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    picker.dismiss(animated: true) { [weak self] in
      if let image = info[.originalImage] as? UIImage {
        if let data = image.jpegData(compressionQuality: 0.9),
          let url = VibeMediaVault.shared.persistOutgoingPick(data: data, fileExtension: "jpg")
        {
          self?.finishAndDismiss { self?.onSelectImage?(url.absoluteString, nil, nil) }
        }
      } else if let videoURL = info[.mediaURL] as? URL, let self {
        let stableURL = (try? self.copyVideoToTemporaryURL(from: videoURL)) ?? videoURL
        self.presentVideoEditor(for: AVURLAsset(url: stableURL))
      }
    }
  }
}

// MARK: - Location Manager

private final class ChatAttachmentMenuLocationManager: NSObject, CLLocationManagerDelegate {
  static let shared = ChatAttachmentMenuLocationManager()
  private let manager = CLLocationManager()
  private var callback: ((CLLocationCoordinate2D) -> Void)?

  override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
  }

  func requestOnce(_ cb: @escaping (CLLocationCoordinate2D) -> Void) {
    callback = cb
    manager.requestWhenInUseAuthorization()
    manager.requestLocation()
  }

  func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
    guard let loc = locs.first else { return }
    callback?(loc.coordinate)
    callback = nil
  }

  func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
    callback = nil
  }
}

// MARK: - Asset Cell (2-state selection toggle at top-right)

private final class ChatAttachmentAssetCell: UICollectionViewCell {
  static let reuseIdentifier = "ChatAttachmentAssetCell"
  let imageView = UIImageView()
  var representedAssetId = ""
  var onSelectToggle: (() -> Void)?

  // Selection toggle: `.normal` = inactive circle, `.selected` = active check.
  private let toggleButton = UIButton(type: .custom)
  private let selectedScrim = UIView()
  private let videoBadgeView = UIView()
  private let videoBadgeIconView = UIImageView()
  private let videoBadgeLabel = UILabel()
  private var isChecked = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    layer.cornerCurve = .continuous
    layer.cornerRadius = 8
    isAccessibilityElement = true
    accessibilityLabel = "Select photo"

    imageView.frame = bounds
    imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    imageView.contentMode = .scaleAspectFill
    imageView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
    contentView.addSubview(imageView)

    selectedScrim.frame = bounds
    selectedScrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    selectedScrim.backgroundColor = UIColor.black.withAlphaComponent(0.28)
    selectedScrim.isUserInteractionEnabled = false
    selectedScrim.alpha = 0
    contentView.addSubview(selectedScrim)

    let symbol = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
    let inactive = UIImage(systemName: "circle", withConfiguration: symbol)
    let active = UIImage(systemName: "checkmark.circle.fill", withConfiguration: symbol)
    toggleButton.setImage(inactive, for: .normal)
    toggleButton.setImage(inactive, for: .highlighted)
    toggleButton.setImage(active, for: .selected)
    toggleButton.setImage(active, for: [.selected, .highlighted])
    toggleButton.adjustsImageWhenHighlighted = false
    toggleButton.tintColor = UIColor.white.withAlphaComponent(0.85)
    toggleButton.addTarget(self, action: #selector(toggleTapped), for: .touchUpInside)
    toggleButton.contentEdgeInsets = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
    contentView.addSubview(toggleButton)

    videoBadgeView.backgroundColor = UIColor(white: 0.0, alpha: 0.64)
    videoBadgeView.layer.cornerRadius = 8
    videoBadgeView.layer.cornerCurve = .continuous
    videoBadgeView.isHidden = true
    contentView.addSubview(videoBadgeView)

    videoBadgeIconView.image = UIImage(
      systemName: "video.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
    videoBadgeIconView.tintColor = .white
    videoBadgeIconView.contentMode = .scaleAspectFit
    videoBadgeIconView.isHidden = true
    videoBadgeView.addSubview(videoBadgeIconView)

    videoBadgeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
    videoBadgeLabel.textColor = .white
    videoBadgeLabel.textAlignment = .center
    videoBadgeView.addSubview(videoBadgeLabel)
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    let size: CGFloat = 32
    toggleButton.frame = CGRect(
      x: bounds.width - size - 4, y: 4, width: size, height: size
    )

    let badgeText = videoBadgeLabel.text ?? ""
    let labelWidth = ceil((badgeText as NSString).size(withAttributes: [.font: videoBadgeLabel.font as Any]).width)
    let badgeWidth = max(34.0, labelWidth + 16.0)
    let badgeHeight: CGFloat = 20.0
    videoBadgeView.frame = CGRect(
      x: bounds.width - badgeWidth - 6.0,
      y: bounds.height - badgeHeight - 6.0,
      width: badgeWidth,
      height: badgeHeight
    )
    videoBadgeLabel.frame = CGRect(
      x: 8.0,
      y: 2.0,
      width: max(1.0, badgeWidth - 16.0),
      height: badgeHeight - 4.0
    )
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    representedAssetId = ""
    imageView.image = nil
    onSelectToggle = nil
    videoBadgeView.isHidden = true
    videoBadgeLabel.text = nil
    setChecked(false, animated: false)
  }

  @objc private func toggleTapped() {
    onSelectToggle?()
  }

  func setChecked(_ checked: Bool, animated: Bool) {
    isChecked = checked
    let apply = {
      self.toggleButton.isSelected = checked
      self.toggleButton.tintColor =
        checked ? UIColor.systemBlue : UIColor.white.withAlphaComponent(0.85)
      self.selectedScrim.alpha = checked ? 1 : 0
      if checked {
        self.accessibilityTraits.insert(.selected)
      } else {
        self.accessibilityTraits.remove(.selected)
      }
    }
    if animated {
      UIView.animate(withDuration: 0.18, delay: 0, options: .curveEaseInOut, animations: apply)
    } else {
      apply()
    }
  }

  func configureVideoBadge(isVideo: Bool, duration: TimeInterval) {
    guard isVideo else {
      videoBadgeView.isHidden = true
      videoBadgeLabel.text = nil
      return
    }
    videoBadgeLabel.text = Self.formattedDuration(duration)
    videoBadgeView.isHidden = false
    setNeedsLayout()
  }

  private static func formattedDuration(_ duration: TimeInterval) -> String {
    let totalSeconds = max(0, Int(duration.rounded()))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
  }
}

// MARK: - Camera Cell

private final class ChatAttachmentCameraCell: UICollectionViewCell {
  static let reuseIdentifier = "ChatAttachmentCameraCell"
  let previewView = UIView()
  private let gridLayer = CAShapeLayer()
  private let unavailableOverlay = UIView()
  private let unavailableIcon = UIImageView()
  private let unavailableLabel = UILabel()
  private let loadingBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    layer.cornerCurve = .continuous
    layer.cornerRadius = 10
    layer.borderWidth = 0.4
    layer.borderColor = UIColor.white.withAlphaComponent(0.24).cgColor

    previewView.backgroundColor = UIColor(white: 0.08, alpha: 1.0)
    previewView.frame = bounds
    previewView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    previewView.clipsToBounds = true
    contentView.addSubview(previewView)

    gridLayer.strokeColor = UIColor.white.withAlphaComponent(0.24).cgColor
    gridLayer.fillColor = UIColor.clear.cgColor
    gridLayer.lineWidth = 0.9
    previewView.layer.addSublayer(gridLayer)

    unavailableOverlay.backgroundColor = UIColor.black.withAlphaComponent(0.34)
    unavailableOverlay.frame = bounds
    unavailableOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    contentView.addSubview(unavailableOverlay)

    unavailableIcon.image = UIImage(
      systemName: "camera.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
    )
    unavailableIcon.tintColor = UIColor.white.withAlphaComponent(0.92)
    unavailableIcon.contentMode = .scaleAspectFit
    unavailableOverlay.addSubview(unavailableIcon)

    unavailableLabel.text = "Camera"
    unavailableLabel.font = .systemFont(ofSize: 11, weight: .semibold)
    unavailableLabel.textColor = UIColor.white.withAlphaComponent(0.92)
    unavailableLabel.textAlignment = .center
    unavailableOverlay.addSubview(unavailableLabel)
    
    loadingBlurView.frame = bounds
    loadingBlurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    contentView.addSubview(loadingBlurView)
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    let cy = bounds.midY
    unavailableIcon.frame = CGRect(x: (bounds.width - 20) * 0.5, y: cy - 16, width: 20, height: 20)
    unavailableLabel.frame = CGRect(
      x: 6, y: unavailableIcon.frame.maxY + 2, width: bounds.width - 12, height: 14)

    let b = previewView.bounds
    let path = UIBezierPath()
    let tx = b.width / 3
    let ttx = tx * 2
    let ty = b.height / 3
    let tty = ty * 2
    for x in [tx, ttx] {
      path.move(to: CGPoint(x: x, y: b.minY))
      path.addLine(to: CGPoint(x: x, y: b.maxY))
    }
    for y in [ty, tty] {
      path.move(to: CGPoint(x: b.minX, y: y))
      path.addLine(to: CGPoint(x: b.maxX, y: y))
    }
    gridLayer.path = path.cgPath
    gridLayer.frame = b
  }

  func setCameraAvailable(_ available: Bool) {
    unavailableOverlay.isHidden = available
  }
  
  func setLoading(_ isLoading: Bool) {
    if isLoading {
      loadingBlurView.alpha = 1
    } else {
      UIView.animate(withDuration: 0.25) {
        self.loadingBlurView.alpha = 0
      }
    }
  }
}

// MARK: - PHPickerViewControllerDelegate

extension ChatAttachmentMenuController: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let result = results.first else { return }

    // Attempt to load item safely
    let itemProvider = result.itemProvider
    if itemProvider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
      itemProvider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) {
        [weak self] url, _ in
        guard let url = url else { return }
        guard let self else { return }
        let stableURL = (try? self.copyVideoToTemporaryURL(from: url)) ?? url
        DispatchQueue.main.async {
          self.isSelectingAsset = false
          self.presentVideoEditor(for: AVURLAsset(url: stableURL))
        }
      }
    } else if itemProvider.canLoadObject(ofClass: UIImage.self) {
      itemProvider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
        guard let image = object as? UIImage, let data = image.jpegData(compressionQuality: 0.9)
        else { return }
        guard let url = VibeMediaVault.shared.persistOutgoingPick(data: data, fileExtension: "jpg")
        else { return }
        DispatchQueue.main.async {
          self?.finishAndDismiss { self?.onSelectImage?(url.absoluteString, nil, nil) }
        }
      }
    }
  }
}

// MARK: - Attachment Row View

private final class AttachmentRowView: UIControl {
  private let iconContainer = UIView()
  private let iconView = UIImageView()
  private let titleLabel = UILabel()
  private let chevronView = UIImageView()
  private let divider = UIView()
  private var onPress: (() -> Void)?

  init(
    title: String, symbol: String, color: UIColor, isDark: Bool, showDivider: Bool,
    showChevron: Bool = true,
    onPress: @escaping () -> Void
  ) {
    self.onPress = onPress
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    addTarget(self, action: #selector(handleTap), for: .touchUpInside)

    iconContainer.translatesAutoresizingMaskIntoConstraints = false
    iconContainer.layer.cornerRadius = 8
    iconContainer.layer.cornerCurve = .continuous
    iconContainer.clipsToBounds = true
    iconContainer.backgroundColor = color.withAlphaComponent(isDark ? 0.78 : 0.88)
    addSubview(iconContainer)

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.contentMode = .scaleAspectFit
    iconView.image = UIImage(
      systemName: symbol,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
    iconView.tintColor = .white
    iconContainer.addSubview(iconView)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 17, weight: .regular)
    titleLabel.textColor = isDark ? .white : .black
    titleLabel.text = title
    addSubview(titleLabel)

    chevronView.translatesAutoresizingMaskIntoConstraints = false
    chevronView.contentMode = .scaleAspectFit
    chevronView.image = UIImage(
      systemName: "chevron.right",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
    chevronView.tintColor = (isDark ? UIColor.white : UIColor.black).withAlphaComponent(
      isDark ? 0.5 : 0.32)
    chevronView.isHidden = !showChevron
    addSubview(chevronView)

    divider.translatesAutoresizingMaskIntoConstraints = false
    divider.backgroundColor = (isDark ? UIColor.white : UIColor.black).withAlphaComponent(
      isDark ? 0.05 : 0.06)
    divider.isHidden = !showDivider
    addSubview(divider)

    NSLayoutConstraint.activate([
      heightAnchor.constraint(equalToConstant: 62),

      iconContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
      iconContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconContainer.widthAnchor.constraint(equalToConstant: 34),
      iconContainer.heightAnchor.constraint(equalToConstant: 34),

      iconView.centerXAnchor.constraint(equalTo: iconContainer.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: iconContainer.centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 18),
      iconView.heightAnchor.constraint(equalToConstant: 18),

      titleLabel.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 14),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
      chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),

      divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 64),
      divider.trailingAnchor.constraint(equalTo: trailingAnchor),
      divider.bottomAnchor.constraint(equalTo: bottomAnchor),
      divider.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
    ])
  }

  required init?(coder: NSCoder) { nil }

  @objc private func handleTap() { onPress?() }

  override var isHighlighted: Bool {
    didSet {
      backgroundColor = isHighlighted ? UIColor(white: 0.5, alpha: 0.1) : .clear
    }
  }
}

// MARK: - Shared Camera Manager

private final class ChatAttachmentMenuCameraManager {
  static let shared = ChatAttachmentMenuCameraManager()
  
  let session = AVCaptureSession()
  let previewLayer = AVCaptureVideoPreviewLayer()
  private let queue = DispatchQueue(label: "chat.attachment.menu.camera.session", qos: .userInitiated)
  private var isConfigured = false
  private(set) var isAvailable = false
  
  private init() {
    previewLayer.session = session
    previewLayer.videoGravity = .resizeAspectFill
  }
  
  func requestStart(completion: @escaping (Bool) -> Void) {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    switch status {
    case .authorized:
      configureAndStart(completion)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        if granted {
          self?.configureAndStart(completion)
        } else {
          DispatchQueue.main.async { completion(false) }
        }
      }
    default:
      DispatchQueue.main.async { completion(false) }
    }
  }
  
  private func configureAndStart(_ completion: @escaping (Bool) -> Void) {
    queue.async { [weak self] in
      guard let self else { return }
      
      let notify: (Bool) -> Void = { success in
        DispatchQueue.main.async {
          self.isAvailable = success
          completion(success)
        }
      }
      
      if !self.isConfigured {
        self.session.beginConfiguration()
        self.session.sessionPreset = .photo
        self.session.inputs.forEach { self.session.removeInput($0) }
        let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        guard let cam, let input = try? AVCaptureDeviceInput(device: cam), self.session.canAddInput(input) else {
          self.session.commitConfiguration()
          notify(false)
          return
        }
        self.session.addInput(input)
        self.session.commitConfiguration()
        self.isConfigured = true
      }
      if !self.session.isRunning {
        self.session.startRunning()
      }
      notify(true)
    }
  }
  
  func requestStop() {
    queue.async { [weak self] in
      if self?.session.isRunning == true {
        self?.session.stopRunning()
      }
    }
  }
}

// MARK: - GalleryGridLayout

private final class GalleryGridLayout: UICollectionViewLayout {
  var spacing: CGFloat = 2
  var columns: Int = 3

  private var cache: [UICollectionViewLayoutAttributes] = []
  private var contentHeight: CGFloat = 0

  override func prepare() {
    super.prepare()
    guard let cv = collectionView, cv.numberOfSections > 0 else { return }
    cache.removeAll()

    let itemsCount = cv.numberOfItems(inSection: 0)
    guard itemsCount > 0 else {
      contentHeight = 0
      return
    }

    let width = cv.bounds.width
    let itemW = floor((width - CGFloat(columns - 1) * spacing) / CGFloat(columns))

    // Make first item (camera) height equal to exactly two rows + spacing
    // This perfectly aligns it with two grid squares next to it.
    let cameraH = itemW * 2 + spacing

    // We keep track of the current Y offset for each column
    var yOffsets = Array(repeating: CGFloat(0), count: max(1, columns))

    for item in 0..<itemsCount {
      let indexPath = IndexPath(item: item, section: 0)
      let attr = UICollectionViewLayoutAttributes(forCellWith: indexPath)

      if item == 0 {
        // Camera span column 0, two rows
        attr.frame = CGRect(x: 0, y: 0, width: itemW, height: cameraH)
        yOffsets[0] = cameraH + spacing
      } else {
        // Find shortest column to place the next item
        var minCol = 0
        var minH = yOffsets[0]
        for col in 1..<columns {
          if yOffsets[col] < minH {
            minH = yOffsets[col]
            minCol = col
          }
        }

        let xOffset = CGFloat(minCol) * (itemW + spacing)
        attr.frame = CGRect(x: xOffset, y: minH, width: itemW, height: itemW)
        yOffsets[minCol] = minH + itemW + spacing
      }
      cache.append(attr)
    }

    contentHeight = (yOffsets.max() ?? 0) - spacing
  }

  override var collectionViewContentSize: CGSize {
    return CGSize(width: collectionView?.bounds.width ?? 0, height: contentHeight)
  }

  override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]?
  {
    var visible: [UICollectionViewLayoutAttributes] = []
    for attr in cache {
      if attr.frame.intersects(rect) { visible.append(attr) }
    }
    return visible
  }

  override func layoutAttributesForItem(at indexPath: IndexPath)
    -> UICollectionViewLayoutAttributes?
  {
    guard indexPath.item < cache.count else { return nil }
    return cache[indexPath.item]
  }

  override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
    guard let cv = collectionView else { return false }
    return cv.bounds.width != newBounds.width
  }
}
