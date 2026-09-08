import UIKit

#if canImport(GiphyUISDK)
    import GiphyUISDK
#endif

final class ChatGifPanelConfig {
    static let shared = ChatGifPanelConfig()

    private init() {}

    /// Giphy API key. Loaded from (first match wins):
    /// 1) process env `GIPHY_API_KEY`
    /// 2) Info.plist `GIPHY_API_KEY`
    /// 3) same public demo key the web client uses (fetch still works offline-dev)
    var apiKey: String = ChatGifPanelConfig.resolveApiKey()

    /// Re-read env/plist (call at launch so scheme env overrides apply).
    func reloadFromEnvironment() {
        apiKey = Self.resolveApiKey()
        let n = apiKey.trimmingCharacters(in: .whitespacesAndNewlines).count
        NSLog("[NativeGif][iOS] apiKey reloaded length=%d", n)
    }

    private static func resolveApiKey() -> String {
        if let env = ProcessInfo.processInfo.environment["GIPHY_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !env.isEmpty
        {
            return env
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "GIPHY_API_KEY") as? String {
            let trimmed = plist.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        // Public demo key used by client/src/components/GifPicker.tsx
        return "sXpGFDGZs0Dv1mmNFvYaGUvYwKX0PWIh"
    }
}

struct ChatGifSelection {
    let id: String
    let url: String
    let previewUrl: String
    let width: Int
    let height: Int
    /// Already-decoded/cached GIF bytes when available (cell image, cache, or local file).
    let localData: Data?
}

protocol ChatGifPanelViewDelegate: AnyObject {
    func chatGifPanel(_ panel: ChatGifPanelView, didSelectGif gif: ChatGifSelection)
    func chatGifPanel(_ panel: ChatGifPanelView, didSelectSticker sticker: ChatStickerSelection)
    func chatGifPanel(_ panel: ChatGifPanelView, didSelectEmoji emoji: String)
    func chatGifPanelDidRequestClose(_ panel: ChatGifPanelView)
}

private enum ChatGifPanelTab: Int, CaseIterable, Hashable {
    case gifs = 0
    case stickers = 1
    case emoji = 2

    var title: String {
        switch self {
        case .gifs: return "GIFs"
        case .stickers: return "Stickers"
        case .emoji: return "Emoji"
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .gifs: return "Search GIFs"
        case .stickers: return "Search stickers"
        case .emoji: return "Search emoji"
        }
    }
}

/// One mounted grid per slot, so returning to a category shows what it already loaded.
private enum ChatGifGridSlot: Hashable {
    case trending
    case search
    case filter(String)
}

private struct ChatGifGridKey: Hashable {
    let tab: ChatGifPanelTab
    let slot: ChatGifGridSlot
}

private struct ChatGifQuickFilter {
    let id: String
    /// SF Symbol name (outline); rendered as a muted template image.
    let symbolName: String
    let query: String
}

/// Standard Unicode emoji groups. Replaced an emotion taxonomy that could only ever hold a
/// hand-picked sample.
enum ChatEmojiCategory: String, CaseIterable {
    case recent
    case smileys
    case people
    case nature
    case food
    case activity
    case travel
    case objects
    case symbols
    case flags

    static let browseCases: [ChatEmojiCategory] = [
        .smileys, .people, .nature, .food, .activity, .travel, .objects, .symbols, .flags,
    ]

    var title: String {
        switch self {
        case .recent: return "Recently Used"
        case .smileys: return "Smileys & Emotion"
        case .people: return "People & Body"
        case .nature: return "Animals & Nature"
        case .food: return "Food & Drink"
        case .activity: return "Activity"
        case .travel: return "Travel & Places"
        case .objects: return "Objects"
        case .symbols: return "Symbols"
        case .flags: return "Flags"
        }
    }

    var icon: String {
        switch self {
        case .recent: return "🕘"
        case .smileys: return "🙂"
        case .people: return "👍"
        case .nature: return "🐻"
        case .food: return "🍔"
        case .activity: return "⚽️"
        case .travel: return "✈️"
        case .objects: return "💡"
        case .symbols: return "❤️"
        case .flags: return "🏳️"
        }
    }

    /// Scalar ranges per group, approximated by Unicode block.
    var scalarRanges: [ClosedRange<UInt32>] {
        switch self {
        case .recent, .flags: return []
        case .smileys: return [0x1F600...0x1F64F, 0x1F910...0x1F93A, 0x1F970...0x1F97A,
                               0x1FAE0...0x1FAE8, 0x2639...0x263A]
        case .people: return [0x1F440...0x1F450, 0x1F464...0x1F487, 0x1F574...0x1F575,
                              0x1F645...0x1F64F, 0x1F9B0...0x1F9DF, 0x1FAF0...0x1FAF8,
                              0x261D...0x261D, 0x270A...0x270D]
        case .nature: return [0x1F400...0x1F43F, 0x1F980...0x1F9AE, 0x1F330...0x1F344,
                              0x1F998...0x1F9AE, 0x1F41A...0x1F43F, 0x2600...0x2604]
        case .food: return [0x1F345...0x1F37F, 0x1F950...0x1F96F, 0x1F32D...0x1F32F]
        case .activity: return [0x1F380...0x1F3AF, 0x1F930...0x1F93E, 0x26BD...0x26BE,
                                0x1F3C0...0x1F3CF]
        case .travel: return [0x1F680...0x1F6C5, 0x1F3E0...0x1F3F0, 0x1F5FA...0x1F5FF,
                              0x2708...0x2708]
        case .objects: return [0x1F4A0...0x1F4FF, 0x1F510...0x1F5D4, 0x1F9F0...0x1F9FF,
                               0x231A...0x231B]
        case .symbols: return [0x2190...0x21FF, 0x2700...0x27BF, 0x1F300...0x1F32C,
                               0x1F500...0x1F50F, 0x2764...0x2764, 0x1F493...0x1F49F,
                               0x0023...0x0023, 0x2049...0x2049]
        }
    }
}

/// Every emoji this device can draw, from Unicode. Search text comes from
/// `properties.name`; unrenderable scalars are dropped rather than shown as tofu.
enum ChatEmojiCatalogBuilder {
    static func build() -> [ChatEmojiEntry] {
        var seen = Set<String>()
        var entries: [ChatEmojiEntry] = []

        for category in ChatEmojiCategory.browseCases where category != .flags {
            for range in category.scalarRanges {
                for raw in range {
                    guard let scalar = Unicode.Scalar(raw) else { continue }
                    let properties = scalar.properties
                    guard properties.isEmoji else { continue }
                    // Without the selector these draw as monochrome text glyphs.
                    let value =
                        properties.isEmojiPresentation
                        ? String(scalar) : String(scalar) + "\u{FE0F}"
                    guard !seen.contains(value), isRenderable(value) else { continue }
                    seen.insert(value)
                    entries.append(
                        ChatEmojiEntry(
                            value: value,
                            searchText: (properties.name ?? "").lowercased(),
                            category: category
                        ))
                }
            }
        }

        entries.append(contentsOf: flagEntries(excluding: &seen))
        return entries
    }

    /// Flags are regional-indicator pairs, so they come from region codes, not a range.
    private static func flagEntries(excluding seen: inout Set<String>) -> [ChatEmojiEntry] {
        let base: UInt32 = 0x1F1E6
        let scalarA = Unicode.Scalar("A").value
        var entries: [ChatEmojiEntry] = []
        for region in Locale.Region.isoRegions {
            let code = region.identifier
            guard code.count == 2 else { continue }
            var value = ""
            var valid = true
            for character in code.uppercased().unicodeScalars {
                guard character.value >= scalarA, character.value <= scalarA + 25,
                    let indicator = Unicode.Scalar(base + (character.value - scalarA))
                else {
                    valid = false
                    break
                }
                value.unicodeScalars.append(indicator)
            }
            guard valid, !seen.contains(value), isRenderable(value) else { continue }
            seen.insert(value)
            let name = Locale.current.localizedString(forRegionCode: code) ?? code
            entries.append(
                ChatEmojiEntry(
                    value: value,
                    searchText: "\(name.lowercased()) flag \(code.lowercased())",
                    category: .flags
                ))
        }
        return entries
    }

    /// Tofu filter: does the emoji font have a glyph for every scalar?
    private static func isRenderable(_ value: String) -> Bool {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 16, nil)
        var characters = Array(value.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        return CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count)
    }
}

struct ChatEmojiEntry: Hashable {
    let value: String
    let searchText: String
    let category: ChatEmojiCategory
}

private struct ChatEmojiSection {
    let title: String
    let items: [ChatEmojiEntry]
}

private final class ChatGifRecentCell: UICollectionViewCell {
    static let reuseIdentifier = "ChatGifRecentCell"
    static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 60
        return cache
    }()
    let imageView = UIImageView()
    var representedKey: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 10
        imageView.layer.cornerCurve = .continuous
        contentView.addSubview(imageView)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = contentView.bounds
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
        representedKey = nil
    }
}

private final class ChatGifPanelEmojiCell: UICollectionViewCell {
    static let reuseIdentifier = "ChatGifPanelEmojiCell"

    private let emojiLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(emojiLabel)
        contentView.layer.cornerRadius = 14
        contentView.layer.cornerCurve = .continuous

        emojiLabel.translatesAutoresizingMaskIntoConstraints = false
        emojiLabel.font = .systemFont(ofSize: 31)
        emojiLabel.textAlignment = .center

        NSLayoutConstraint.activate([
            emojiLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            emojiLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            emojiLabel.topAnchor.constraint(equalTo: contentView.topAnchor),
            emojiLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(emoji: String, highlighted: Bool) {
        emojiLabel.text = emoji
        contentView.backgroundColor =
            highlighted
            ? UIColor.white.withAlphaComponent(0.12)
            : UIColor.clear
    }
}

private final class ChatGifPanelEmojiHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "ChatGifPanelEmojiHeaderView"

    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(titleLabel)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.75

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(title: String, color: UIColor) {
        titleLabel.text = title.uppercased()
        titleLabel.textColor = color
    }
}

final class ChatGifPanelView: UIView {
    weak var delegate: ChatGifPanelViewDelegate?
    var onPreferredHeightChange: (() -> Void)?

    /// True while the panel's own search field holds focus. Host lifts the bar above the
    /// search keyboard; panel height stays fixed so the composer is not pushed offscreen.
    private(set) var isSearchExpanded = false

    /// Space above floating tab bar for scroll content (tighter — closer to content).
    private let bottomFloatingControlHeight: CGFloat = 38
    /// Not from the safe area — that reserves the home-indicator strip inside the chrome
    /// and pushes it out of view.
    private let bottomFloatingEdgeInset: CGFloat = 14
    private let topControlsSpacing: CGFloat = 4
    private let searchHeight: CGFloat = 30
    /// Chips ride inside the search capsule, so they clear its rounded ends.
    private let stripChipHeight: CGFloat = 26
    /// One row plus breathing room above and below. Was two stacked rows.
    private var headerZoneHeight: CGFloat {
        6 + searchHeight + 8
    }

    private var panelVisible = false
    private var activeTab: ChatGifPanelTab = .gifs
    private var searchTextByTab: [ChatGifPanelTab: String] = [:]
    private var selectedGifFilterID: String?
    private var selectedStickerFilterID: String?
    private var selectedEmojiCategory: ChatEmojiCategory?

    /// Stickers page. A second Giphy grid on `.sticker` media — the three bundled Lottie
    /// packs it replaced could only ever show eleven stickers, which read as a mock.
    private let stickerContainerView = UIView()
    private var emojiSections: [ChatEmojiSection] = []
    private var recentEmojiValues = ChatGifPanelView.loadRecentEmojiValues()

    weak var hostViewController: UIViewController? {
        didSet {
            guard hostViewController !== oldValue else { return }
            removeEmbeddedPickers()
            if panelVisible, activeTab != .emoji {
                installEmbeddedPickerIfNeeded(for: activeTab)
            }
        }
    }

    private let glassBackground = UIVisualEffectView(effect: nil)
    // Category strip + search — translateY + fade on content scroll
    private let headerView = UIView()
    /// Flat translucent capsule, never a material. A blur plate here read as a raised
    /// slab over the grid instead of the recessed field the search actually is.
    private let headerChromeView = UIView()
    private let topStripScrollView = UIScrollView()
    private let topStripStack = UIStackView()
    private let searchChromeView = UIView()
    private let searchIconView = UIImageView()
    private let searchField = UITextField()
    private let clearSearchButton = UIButton(type: .system)
    // Full-bleed content: 3 pages (GIF | Stickers | Emoji) via translateX / paging
    private let contentContainerView = UIView()
    private let pagesScrollView = UIScrollView()
    private let mediaContainerView = UIView()
    /// GIFs the user has sent, above the browse grid. Local files, no network.
    private lazy var recentsCollectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 6
        layout.minimumInteritemSpacing = 6
        layout.itemSize = CGSize(width: 96, height: 96)
        layout.sectionInset = UIEdgeInsets(top: 6, left: 10, bottom: 0, right: 10)
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.showsHorizontalScrollIndicator = false
        view.register(
            ChatGifRecentCell.self, forCellWithReuseIdentifier: ChatGifRecentCell.reuseIdentifier)
        view.register(
            UICollectionReusableView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: "ChatGifPanelEmptyHeaderView"
        )
        view.dataSource = self
        view.delegate = self
        return view
    }()
    private var recentGifEntries: [ChatGifRecentsStore.Entry] = []
    private let stateLabel = UILabel()
    private let loadingView = UIView()
    private let loadingSpinner = UIActivityIndicatorView(style: .medium)
    private var isProgrammaticPageScroll = false
    // Bottom gradient mask (fades into tab bar)
    private let bottomMaskView = UIView()
    private let bottomMaskGradient = CAGradientLayer()
    // Bottom floating controls
    /// Capsule hugging three labels. A UITabBar's 49pt intrinsic height could only ever be
    /// clipped into a row this short, which is what cut its background off.
    private let bottomTabBarContainer = UIVisualEffectView(effect: nil)
    private let bottomTabStack = UIStackView()
    private var bottomTabButtons: [UIButton] = []
    private let bottomTabIndicator = UIView()
    private let closeChromeView = UIVisualEffectView(effect: nil)
    private let closeButton = UIButton(type: .system)
    private let selectionFeedback = UISelectionFeedbackGenerator()

    private let emojiCollectionView: UICollectionView

    #if canImport(GiphyUISDK)
        private var embeddedPickers: [ChatGifGridKey: GiphyGridController] = [:]
        /// Least recently shown first — the eviction order.
        private var gridRecency: [ChatGifGridKey] = []
        private var didPrefetchGrids: Set<ChatGifPanelTab> = []
        private static let maxCachedGrids = 6
        private static let prefetchedCategories = 3
    #endif

    override init(frame: CGRect) {
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 8
        layout.minimumInteritemSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 6, left: 12, bottom: 16, right: 12)
        layout.headerReferenceSize = CGSize(width: 120, height: 34)
        emojiCollectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        // Registered here, not in `setupUI`: the layout declares a header size, so the
        // view must never exist in a state where one can be asked for and not dequeued.
        emojiCollectionView.register(
            ChatGifPanelEmojiHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: ChatGifPanelEmojiHeaderView.reuseIdentifier
        )
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        removeEmbeddedPickers()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let panelCornerRadius: CGFloat = 28
        let topCorners: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        layer.cornerRadius = panelCornerRadius
        layer.cornerCurve = .continuous
        layer.maskedCorners = topCorners
        glassBackground.layer.cornerRadius = panelCornerRadius
        glassBackground.layer.cornerCurve = .continuous
        glassBackground.layer.maskedCorners = topCorners
        bottomTabBarContainer.layer.cornerRadius = bottomFloatingControlHeight * 0.5
        closeChromeView.layer.cornerRadius = bottomFloatingControlHeight * 0.5
        closeChromeView.layer.cornerCurve = .continuous
        applyFrameLayout()
        // The Giphy grid builds its scroll view lazily, so the inset pass at install time
        // finds nothing. Re-applying on layout catches it; it is idempotent and leaves a
        // scrolling user alone.
        updateContentInsets()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshChrome()
        rebuildTopStripButtons()
        rebuildSearchChrome()
        emojiCollectionView.reloadData()

        #if canImport(GiphyUISDK)
            for picker in embeddedPickers.values { picker.theme = currentGiphyTheme() }
        #endif
    }

    func prepareIfNeeded() {
        guard panelVisible else { return }
        if activeTab == .emoji {
            rebuildEmojiSections()
        } else {
            installEmbeddedPickerIfNeeded(for: activeTab)
        }
    }

    func setPanelVisible(_ visible: Bool) {
        guard panelVisible != visible else { return }
        panelVisible = visible

        if visible {
            reloadRecentGifs()
            // Recents open first when there are any — one category among the others now,
            // just with no network behind it.
            headerView.transform = .identity
            headerView.alpha = 1
            if selectedGifFilterID == nil, !recentGifEntries.isEmpty {
                selectedGifFilterID = Self.recentFilterID
            }
            applyActiveTabState(animated: false)
            if activeTab != .emoji {
                installEmbeddedPickerIfNeeded(for: activeTab)
            }
            return
        }

        // Grids stay mounted. Tearing them down here is what made every reopen start empty
        // and refetch; they are released when the host goes away.
        searchField.resignFirstResponder()
        setSearchExpanded(false)
        loadingSpinner.stopAnimating()
        loadingView.isHidden = true
        stateLabel.isHidden = true
    }

    private func setupUI() {
        clipsToBounds = true
        backgroundColor = .clear

        // Glass background fills everything
        glassBackground.frame = bounds
        glassBackground.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glassBackground)

        // Full-bleed content container (top to bottom — header floats above)
        contentContainerView.backgroundColor = .clear
        contentContainerView.frame = bounds
        contentContainerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(contentContainerView)

        // Horizontal paging: page 0 = GIFs, 1 = Stickers, 2 = Emoji (translateX)
        pagesScrollView.isPagingEnabled = true
        pagesScrollView.showsHorizontalScrollIndicator = false
        pagesScrollView.showsVerticalScrollIndicator = false
        pagesScrollView.bounces = true
        pagesScrollView.delegate = self
        pagesScrollView.backgroundColor = .clear
        pagesScrollView.clipsToBounds = true
        contentContainerView.addSubview(pagesScrollView)

        // Media container for Giphy grid — page 0
        mediaContainerView.backgroundColor = .clear
        pagesScrollView.addSubview(mediaContainerView)

        // Stickers — page 1 (second Giphy grid, installed on first visit)
        stickerContainerView.backgroundColor = .clear
        pagesScrollView.addSubview(stickerContainerView)

        // Emoji collection — page 2
        emojiCollectionView.translatesAutoresizingMaskIntoConstraints = true
        emojiCollectionView.backgroundColor = .clear
        emojiCollectionView.alwaysBounceVertical = true
        emojiCollectionView.keyboardDismissMode = .onDrag
        emojiCollectionView.dataSource = self
        emojiCollectionView.delegate = self
        emojiCollectionView.register(
            ChatGifPanelEmojiCell.self,
            forCellWithReuseIdentifier: ChatGifPanelEmojiCell.reuseIdentifier
        )
        emojiCollectionView.register(
            ChatGifPanelEmojiHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: ChatGifPanelEmojiHeaderView.reuseIdentifier
        )
        pagesScrollView.addSubview(emojiCollectionView)

        // State / loading overlays
        stateLabel.translatesAutoresizingMaskIntoConstraints = true
        stateLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        stateLabel.font = .systemFont(ofSize: 14)
        stateLabel.textAlignment = .center
        stateLabel.numberOfLines = 0
        stateLabel.isHidden = true
        contentContainerView.addSubview(stateLabel)

        loadingView.backgroundColor = .clear
        loadingView.isUserInteractionEnabled = false
        loadingView.isHidden = true
        contentContainerView.addSubview(loadingView)

        loadingSpinner.hidesWhenStopped = true
        loadingView.addSubview(loadingSpinner)

        // Bottom gradient mask: transparent → bg colour (feathers into tab bar)
        bottomMaskView.isUserInteractionEnabled = false
        bottomMaskGradient.startPoint = CGPoint(x: 0.5, y: 0)
        bottomMaskGradient.endPoint = CGPoint(x: 0.5, y: 1)
        bottomMaskView.layer.addSublayer(bottomMaskGradient)
        addSubview(bottomMaskView)

        // ── Scrollable header: strip + search (scrolls with content) ──
        headerView.backgroundColor = .clear
        headerView.isUserInteractionEnabled = true
        addSubview(headerView)

        headerChromeView.clipsToBounds = true
        headerChromeView.layer.cornerRadius = searchHeight * 0.5
        headerChromeView.layer.cornerCurve = .continuous
        headerView.addSubview(headerChromeView)

        topStripScrollView.showsHorizontalScrollIndicator = false
        topStripScrollView.alwaysBounceHorizontal = true
        topStripScrollView.backgroundColor = .clear
        headerChromeView.addSubview(topStripScrollView)

        topStripStack.axis = .horizontal
        topStripStack.alignment = .center
        topStripStack.spacing = 2
        topStripStack.translatesAutoresizingMaskIntoConstraints = false
        topStripScrollView.addSubview(topStripStack)

        let topStripMinHeight = topStripStack.heightAnchor.constraint(
            greaterThanOrEqualTo: topStripScrollView.frameLayoutGuide.heightAnchor)

        NSLayoutConstraint.activate([
            topStripStack.leadingAnchor.constraint(
                equalTo: topStripScrollView.contentLayoutGuide.leadingAnchor),
            topStripStack.trailingAnchor.constraint(
                equalTo: topStripScrollView.contentLayoutGuide.trailingAnchor),
            topStripStack.topAnchor.constraint(
                equalTo: topStripScrollView.contentLayoutGuide.topAnchor),
            topStripStack.bottomAnchor.constraint(
                equalTo: topStripScrollView.contentLayoutGuide.bottomAnchor),
            topStripMinHeight,
        ])

        searchChromeView.clipsToBounds = true
        searchChromeView.layer.cornerRadius = searchHeight * 0.5
        searchChromeView.layer.cornerCurve = .continuous
        headerChromeView.addSubview(searchChromeView)

        searchIconView.contentMode = .scaleAspectFit
        searchChromeView.addSubview(searchIconView)

        searchField.delegate = self
        searchField.returnKeyType = .search
        searchField.clearButtonMode = .never
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.spellCheckingType = .no
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.addTarget(self, action: #selector(searchTextDidChange), for: .editingChanged)
        searchChromeView.addSubview(searchField)

        clearSearchButton.translatesAutoresizingMaskIntoConstraints = false
        clearSearchButton.addTarget(self, action: #selector(clearSearchTapped), for: .touchUpInside)
        searchChromeView.addSubview(clearSearchButton)

        // Internal search chrome constraints
        let searchIcon = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        searchIconView.translatesAutoresizingMaskIntoConstraints = false
        let searchIconLeading = searchIconView.leadingAnchor.constraint(
            equalTo: searchChromeView.leadingAnchor, constant: 10)
        let searchIconWidth = searchIconView.widthAnchor.constraint(equalToConstant: 18)
        let clearButtonTrailing = clearSearchButton.trailingAnchor.constraint(
            equalTo: searchChromeView.trailingAnchor, constant: -10)
        let clearButtonWidth = clearSearchButton.widthAnchor.constraint(equalToConstant: 24)
        let searchFieldLeading = searchField.leadingAnchor.constraint(
            equalTo: searchIconView.trailingAnchor, constant: 8)
        let searchFieldTrailing = searchField.trailingAnchor.constraint(
            equalTo: clearSearchButton.leadingAnchor, constant: -6)
        [searchIconLeading, searchIconWidth, clearButtonTrailing, clearButtonWidth, searchFieldLeading,
         searchFieldTrailing].forEach { $0.priority = .defaultHigh }

        NSLayoutConstraint.activate([
            searchIconLeading,
            searchIconView.centerYAnchor.constraint(
                equalTo: searchChromeView.centerYAnchor),
            searchIconWidth,
            searchIconView.heightAnchor.constraint(equalToConstant: 20),

            clearButtonTrailing,
            clearSearchButton.centerYAnchor.constraint(
                equalTo: searchChromeView.centerYAnchor),
            clearButtonWidth,
            clearSearchButton.heightAnchor.constraint(equalToConstant: 24),

            searchFieldLeading,
            searchFieldTrailing,
            searchField.centerYAnchor.constraint(
                equalTo: searchChromeView.centerYAnchor),
        ])
        _ = searchIcon  // suppress unused warning

        // ── Bottom floating tab capsule + close ──
        bottomTabBarContainer.clipsToBounds = true
        bottomTabBarContainer.layer.cornerRadius = bottomFloatingControlHeight * 0.5
        bottomTabBarContainer.layer.cornerCurve = .continuous
        bottomTabBarContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomTabBarContainer)

        bottomTabIndicator.layer.cornerCurve = .continuous
        bottomTabIndicator.isUserInteractionEnabled = false
        bottomTabBarContainer.contentView.addSubview(bottomTabIndicator)

        bottomTabStack.axis = .horizontal
        bottomTabStack.alignment = .fill
        bottomTabStack.distribution = .fillProportionally
        bottomTabStack.translatesAutoresizingMaskIntoConstraints = false
        bottomTabBarContainer.contentView.addSubview(bottomTabStack)

        for tab in ChatGifPanelTab.allCases {
            let button = UIButton(type: .system)
            var buttonConfig = UIButton.Configuration.plain()
            buttonConfig.contentInsets = NSDirectionalEdgeInsets(
                top: 0, leading: 14, bottom: 0, trailing: 14)
            button.configuration = buttonConfig
            button.setTitle(tab.title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
            button.tag = tab.rawValue
            button.addTarget(self, action: #selector(tabButtonTapped(_:)), for: .touchUpInside)
            bottomTabStack.addArrangedSubview(button)
            bottomTabButtons.append(button)
        }

        closeChromeView.clipsToBounds = true
        closeChromeView.layer.cornerRadius = bottomFloatingControlHeight * 0.5
        closeChromeView.layer.cornerCurve = .continuous
        closeChromeView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeChromeView)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeChromeView.contentView.addSubview(closeButton)

        // Compact floating chrome flush to panel bottom (small edge inset only).
        NSLayoutConstraint.activate([
            bottomTabBarContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            // Safe area, not the raw edge: pinned to the bottom the capsule and the close
            // button sat in the home-indicator strip, which is what made them hard to hit.
            bottomTabBarContainer.bottomAnchor.constraint(
                equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -bottomFloatingEdgeInset),
            bottomTabBarContainer.heightAnchor.constraint(
                equalToConstant: bottomFloatingControlHeight),

            // No fixed width — the capsule takes its width from the labels, so nothing
            // inside it can overflow and nothing has to be clipped back.
            bottomTabStack.leadingAnchor.constraint(
                equalTo: bottomTabBarContainer.contentView.leadingAnchor, constant: 4),
            bottomTabStack.trailingAnchor.constraint(
                equalTo: bottomTabBarContainer.contentView.trailingAnchor, constant: -4),
            bottomTabStack.topAnchor.constraint(
                equalTo: bottomTabBarContainer.contentView.topAnchor, constant: 3),
            bottomTabStack.bottomAnchor.constraint(
                equalTo: bottomTabBarContainer.contentView.bottomAnchor, constant: -3),

            closeChromeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            // Centred on the capsule rather than pinned to the panel bottom, so the two
            // read as one row however tall the capsule ends up.
            closeChromeView.centerYAnchor.constraint(
                equalTo: bottomTabBarContainer.centerYAnchor),
            closeChromeView.widthAnchor.constraint(equalToConstant: bottomFloatingControlHeight),
            closeChromeView.heightAnchor.constraint(equalToConstant: bottomFloatingControlHeight),

            closeButton.leadingAnchor.constraint(
                equalTo: closeChromeView.contentView.leadingAnchor),
            closeButton.trailingAnchor.constraint(
                equalTo: closeChromeView.contentView.trailingAnchor),
            closeButton.topAnchor.constraint(equalTo: closeChromeView.contentView.topAnchor),
            closeButton.bottomAnchor.constraint(equalTo: closeChromeView.contentView.bottomAnchor),
        ])

        // Plain glyph, not `xmark.circle.fill` — that symbol carries its own filled disc,
        // which read as a second plate on top of the toolbar's material.
        let closeConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        closeButton.setImage(
            UIImage(systemName: "xmark", withConfiguration: closeConfig),
            for: .normal
        )
        closeButton.tintColor = secondaryTextColor

        selectionFeedback.prepare()
        refreshChrome()
        rebuildSearchChrome()
        rebuildTopStripButtons()
        rebuildEmojiSections()
        updateContentInsets()
        applyActiveTabState(animated: false)
    }

    private func updateContentInsets() {
        // Clearance for the floating chrome. It rides the safe area now, so the reserve
        // has to follow it instead of being one constant.
        let floatingClearance =
            safeAreaInsets.bottom + bottomFloatingControlHeight + bottomFloatingEdgeInset + 8
        applyContentInsets(
            UIEdgeInsets(
                top: headerZoneHeight, left: 0, bottom: floatingClearance, right: 0),
            to: emojiCollectionView)
        applyContentInsets(
            UIEdgeInsets(top: 0, left: 0, bottom: floatingClearance, right: 0),
            to: recentsCollectionView)
        // Giphy pages carry their top padding in the container frame; only the floating
        // toolbar still needs reserving, and that has to be re-asserted after every load.
        #if canImport(GiphyUISDK)
            let gridInsets = UIEdgeInsets(top: 0, left: 0, bottom: floatingClearance, right: 0)
            for picker in embeddedPickers.values {
                guard let sv = findScrollView(in: picker.view) else { continue }
                applyContentInsets(gridInsets, to: sv)
            }
        #endif
    }

    /// Setting `contentInset.top` does not move content that is already at rest — the
    /// offset has to be pinned to `-top` too, or the first rows sit under the header.
    private func applyContentInsets(_ insets: UIEdgeInsets, to scrollView: UIScrollView) {
        // Ours is the only top inset; without this the safe area is added on top of it.
        scrollView.contentInsetAdjustmentBehavior = .never
        let wasAtTop = scrollView.contentOffset.y <= -scrollView.contentInset.top + 0.5
        scrollView.contentInset = insets
        scrollView.verticalScrollIndicatorInsets = insets
        if wasAtTop, !scrollView.isDragging, !scrollView.isDecelerating {
            scrollView.contentOffset.y = -insets.top
        }
    }

    /// Frame-based layout — called from layoutSubviews.
    private func applyFrameLayout() {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        let hInset: CGFloat = 10
        let stripTop: CGFloat = 6

        // Header is pinned. It used to translate up and fade on content scroll, which is the
        // search row that appeared to shift away every time a page reloaded.
        headerView.frame = CGRect(x: 0, y: 0, width: w, height: headerZoneHeight)
        // One row: search on the left, category chips scrolling beside it. Two stacked
        // rows made the header a block that pushed content under the composer.
        let rowHeight = searchHeight
        headerChromeView.frame = CGRect(
            x: hInset, y: stripTop, width: max(0, w - hInset * 2), height: rowHeight)
        let chromeWidth = headerChromeView.bounds.width
        let searchWidth = isSearchExpanded ? chromeWidth : min(126, chromeWidth * 0.34)
        searchChromeView.frame = CGRect(
            x: 0, y: 0, width: searchWidth, height: rowHeight)
        let stripX = searchChromeView.frame.maxX + topControlsSpacing
        topStripScrollView.frame = CGRect(
            x: stripX,
            y: 0,
            width: max(0, chromeWidth - stripX),
            height: rowHeight
        )
        topStripScrollView.alpha = isSearchExpanded ? 0 : 1

        // Content: full-bleed horizontal pages
        contentContainerView.frame = bounds
        pagesScrollView.frame = bounds
        pagesScrollView.contentSize = CGSize(width: w * 3, height: h)

        // Page 0 GIFs · 1 Stickers · 2 Emoji. The two Giphy pages START below the chrome
        // rather than reserving it with `contentInset` — the SDK rewrites its grid's insets
        // on every content load, which is what let rows slide under the search row.
        let gifTop = headerZoneHeight
        mediaContainerView.frame = CGRect(x: 0, y: gifTop, width: w, height: max(0, h - gifTop))

        // Recents fill the GIF page like any browse grid. As a page subview they travel with
        // the pager instead of floating over the sticker page mid-swipe.
        if recentsCollectionView.superview !== mediaContainerView {
            recentsCollectionView.removeFromSuperview()
            mediaContainerView.addSubview(recentsCollectionView)
        }
        recentsCollectionView.isHidden = !isRecentGifCategorySelected
        recentsCollectionView.frame = mediaContainerView.bounds
        if let recentsLayout = recentsCollectionView.collectionViewLayout
            as? UICollectionViewFlowLayout
        {
            let columns = max(3, floor((w - 20) / 118))
            let side = floor((w - 20 - 6 * (columns - 1)) / columns)
            if side > 0, abs(recentsLayout.itemSize.width - side) > 0.5 {
                recentsLayout.itemSize = CGSize(width: side, height: side)
                recentsLayout.invalidateLayout()
            }
        }
        stickerContainerView.frame = CGRect(
            x: w, y: headerZoneHeight, width: w, height: max(0, h - headerZoneHeight))
        emojiCollectionView.frame = CGRect(x: w * 2, y: 0, width: w, height: h)

        // Keep page offset in sync with active tab (no jump when resizing)
        let pageX = CGFloat(activeTab.rawValue) * w
        if abs(pagesScrollView.contentOffset.x - pageX) > 1, !pagesScrollView.isDragging,
            !pagesScrollView.isDecelerating
        {
            isProgrammaticPageScroll = true
            pagesScrollView.contentOffset = CGPoint(x: pageX, y: 0)
            isProgrammaticPageScroll = false
        }

        // On the panel, not on page 0 — a sticker fetch used to spin over the GIF page.
        stateLabel.frame = bounds
        loadingView.frame = bounds
        loadingSpinner.center = CGPoint(x: w * 0.5, y: h * 0.5 - 18)
        if stateLabel.superview !== self {
            addSubview(stateLabel)
            addSubview(loadingView)
        }

        // Bottom gradient mask (shorter — tighter chrome)
        let bottomMaskH: CGFloat = 56
        bottomMaskView.frame = CGRect(x: 0, y: h - bottomMaskH, width: w, height: bottomMaskH)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bottomMaskGradient.frame = bottomMaskView.bounds
        CATransaction.commit()

        // Z-order: content → recents → bottom mask → floating controls → header
        mediaContainerView.bringSubviewToFront(recentsCollectionView)
        bringSubviewToFront(bottomMaskView)
        bringSubviewToFront(bottomTabBarContainer)
        bringSubviewToFront(closeChromeView)
        bringSubviewToFront(headerView)

        // Buttons must have real frames before the fill can be sized to one.
        bottomTabBarContainer.layoutIfNeeded()
        layoutTabIndicator(animated: false)
    }

    private func refreshChrome() {
        let blurStyle: UIBlurEffect.Style =
            isDarkMode ? .systemChromeMaterialDark : .systemChromeMaterialLight
        if #available(iOS 26.0, *) {
            let backgroundGlass = UIGlassEffect()
            backgroundGlass.isInteractive = true
            glassBackground.effect = backgroundGlass
            let closeGlass = UIGlassEffect()
            closeGlass.isInteractive = true
            closeChromeView.effect = closeGlass
        } else {
            glassBackground.effect = UIBlurEffect(style: .systemMaterial)
            closeChromeView.effect = UIBlurEffect(style: blurStyle)
        }

        // Recessed fill, not a material — one capsule holding search and the chip strip.
        headerChromeView.backgroundColor =
            isDarkMode
            ? UIColor(white: 1, alpha: 0.10)
            : UIColor(white: 0, alpha: 0.06)
        searchChromeView.backgroundColor = .clear

        // Update gradient mask colours to match current background
        let bgColor =
            isDarkMode
            ? UIColor(red: 0.071, green: 0.071, blue: 0.071, alpha: 1)
            : UIColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        bottomMaskGradient.colors = [bgColor.withAlphaComponent(0).cgColor, bgColor.cgColor]

        if #available(iOS 26.0, *) {
            let tabGlass = UIGlassEffect()
            tabGlass.isInteractive = true
            bottomTabBarContainer.effect = tabGlass
        } else {
            bottomTabBarContainer.effect = UIBlurEffect(style: blurStyle)
        }
        bottomTabIndicator.backgroundColor =
            isDarkMode
            ? UIColor(white: 1, alpha: 0.16)
            : UIColor(white: 0, alpha: 0.09)
        updateTabButtonSelection()
        closeButton.tintColor = secondaryTextColor
    }

    private func rebuildSearchChrome() {
        let searchConfig = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        searchIconView.image = UIImage(
            systemName: "magnifyingglass", withConfiguration: searchConfig)
        searchIconView.tintColor = secondaryTextColor.withAlphaComponent(0.5)

        let clearConfig = UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)
        clearSearchButton.setImage(
            UIImage(systemName: "xmark", withConfiguration: clearConfig),
            for: .normal
        )
        clearSearchButton.tintColor = secondaryTextColor
        clearSearchButton.isHidden = currentSearchText().isEmpty
        searchField.textColor = primaryTextColor
        searchField.tintColor = primaryTextColor
        searchField.font = .systemFont(ofSize: 15, weight: .regular)
        searchField.attributedPlaceholder = NSAttributedString(
            string: activeTab.searchPlaceholder,
            attributes: [.foregroundColor: secondaryTextColor.withAlphaComponent(0.5)]
        )
    }

    private func rebuildTopStripButtons() {
        topStripStack.arrangedSubviews.forEach { view in
            topStripStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        switch activeTab {
        case .gifs, .stickers:
            // Both pages are Giphy searches, so they take the same chips.
            let activeFilterID =
                activeTab == .stickers ? selectedStickerFilterID : selectedGifFilterID
            for (index, filter) in stripFilters.enumerated() {
                let button = makeStripButton(
                    symbolName: filter.symbolName,
                    selected: activeFilterID == filter.id,
                    showsAddBadge: false
                )
                button.tag = index
                button.accessibilityLabel = filter.query
                button.addTarget(
                    self, action: #selector(gifQuickFilterTapped(_:)), for: .touchUpInside)
                topStripStack.addArrangedSubview(button)
            }
        case .emoji:
            let categories = [ChatEmojiCategory.recent] + ChatEmojiCategory.browseCases
            for (index, category) in categories.enumerated() {
                let selected = selectedEmojiCategory == category
                let button = makeStripButton(
                    title: category.icon,
                    selected: selected,
                    showsAddBadge: false
                )
                button.tag = index
                button.accessibilityLabel = category.title
                button.addTarget(
                    self, action: #selector(emojiCategoryTapped(_:)), for: .touchUpInside)
                topStripStack.addArrangedSubview(button)
            }
        }
    }

    private func makeStripButton(
        title: String? = nil,
        symbolName: String? = nil,
        selected: Bool,
        showsAddBadge: Bool
    ) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        var config = UIButton.Configuration.plain()

        if let symbolName {
            // Muted outline SF Symbol; selected uses primary tint + chip background.
            let symbolConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            config.image = UIImage(systemName: symbolName, withConfiguration: symbolConfig)
            config.contentInsets = NSDirectionalEdgeInsets(top: 3, leading: 7, bottom: 3, trailing: 7)
            button.configuration = config
            button.tintColor = selected ? primaryTextColor : secondaryTextColor
        } else if let title {
            let isEmoji = title.count <= 2
            config.contentInsets = NSDirectionalEdgeInsets(
                top: 0, leading: isEmoji ? 5 : 9, bottom: 0, trailing: isEmoji ? 5 : 9)
            button.configuration = config
            button.setTitle(title, for: .normal)
            button.setTitleColor(primaryTextColor, for: .normal)
            button.titleLabel?.font = .systemFont(
                ofSize: isEmoji ? 19 : 14,
                weight: isEmoji ? .regular : .semibold
            )
        }

        button.backgroundColor = selected ? selectedChipColor : .clear
        if activeTab == .emoji {
            button.alpha = 1.0
            button.transform = selected ? CGAffineTransform(scaleX: 1.2, y: 1.2) : .identity
        }

        button.layer.cornerRadius = stripChipHeight * 0.5
        button.layer.cornerCurve = .continuous
        let heightConstraint = button.heightAnchor.constraint(equalToConstant: stripChipHeight)
        heightConstraint.priority = .defaultHigh
        heightConstraint.isActive = true

        if showsAddBadge {
            let badge = UILabel()
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.text = "+"
            badge.textAlignment = .center
            badge.font = .systemFont(ofSize: 13, weight: .bold)
            badge.textColor = .white
            badge.backgroundColor = accentBadgeColor
            badge.layer.cornerRadius = 10
            badge.layer.cornerCurve = .continuous
            badge.clipsToBounds = true
            button.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.widthAnchor.constraint(equalToConstant: 20),
                badge.heightAnchor.constraint(equalToConstant: 20),
                badge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: 3),
                badge.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: 3),
            ])
        }

        return button
    }

    private func applyActiveTabState(animated: Bool) {
        rebuildSearchChrome()
        rebuildTopStripButtons()

        // All three pages stay mounted; we only translateX the pager.
        mediaContainerView.isHidden = false
        stickerContainerView.isHidden = false
        emojiCollectionView.isHidden = false

        switch activeTab {
        case .emoji:
            loadingSpinner.stopAnimating()
            loadingView.isHidden = true
            rebuildEmojiSections()
        case .gifs, .stickers:
            stateLabel.isHidden = true
            if isRecentGifCategorySelected {
                hideGifGrids()
                loadingSpinner.stopAnimating()
                loadingView.isHidden = true
                break
            }
            if panelVisible {
                installEmbeddedPickerIfNeeded(for: activeTab)
            }
            #if canImport(GiphyUISDK)
                let shouldShowLoading = animated && embeddedPickers[gridKey(for: activeTab)] == nil
            #else
                let shouldShowLoading = false
            #endif
            updateEmbeddedPickerContent(for: activeTab, showLoading: shouldShowLoading)
        }

        let w = max(bounds.width, 1)
        let targetX = CGFloat(activeTab.rawValue) * w
        isProgrammaticPageScroll = true
        if animated, bounds.width > 1 {
            UIView.animate(
                withDuration: 0.28,
                delay: 0,
                options: [.curveEaseInOut, .allowUserInteraction]
            ) {
                self.pagesScrollView.contentOffset = CGPoint(x: targetX, y: 0)
            } completion: { _ in
                self.isProgrammaticPageScroll = false
            }
        } else {
            pagesScrollView.contentOffset = CGPoint(x: targetX, y: 0)
            isProgrammaticPageScroll = false
        }

        // Keep search-expand height rule for the active tab.
        if searchField.isFirstResponder {
            setSearchExpanded(true)
        }
        setNeedsLayout()
    }

    private func reloadRecentGifs() {
        recentGifEntries = ChatGifRecentsStore.shared.entries
        recentsCollectionView.reloadData()
        setNeedsLayout()
    }

    // MARK: - Scroll-hosted header


    private func findScrollView(in view: UIView) -> UIScrollView? {
        for sub in view.subviews {
            if let sv = sub as? UIScrollView { return sv }
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }

    @objc private func gifQuickFilterTapped(_ sender: UIButton) {
        let filters = stripFilters
        guard sender.tag >= 0, sender.tag < filters.count else { return }
        let filter = filters[sender.tag]
        selectionFeedback.selectionChanged()
        if activeTab == .stickers {
            selectedStickerFilterID = filter.id
        } else {
            selectedGifFilterID = filter.id
        }
        updateCurrentSearchText(filter.query, synchronizeField: true, clearPresetSelection: false)
        searchField.resignFirstResponder()
        applyActiveTabState(animated: false)
    }

    @objc private func emojiCategoryTapped(_ sender: UIButton) {
        let categories = [ChatEmojiCategory.recent] + ChatEmojiCategory.browseCases
        guard sender.tag >= 0, sender.tag < categories.count else { return }
        let category = categories[sender.tag]
        selectionFeedback.selectionChanged()
        selectedEmojiCategory = (selectedEmojiCategory == category) ? nil : category
        updateCurrentSearchText("", synchronizeField: true, clearPresetSelection: false)
        searchField.resignFirstResponder()
        rebuildTopStripButtons()
        rebuildEmojiSections()
    }

    @objc private func searchTextDidChange() {
        updateCurrentSearchText(
            searchField.text ?? "", synchronizeField: false, clearPresetSelection: true)
    }

    @objc private func clearSearchTapped() {
        updateCurrentSearchText("", synchronizeField: true, clearPresetSelection: true)
        searchField.becomeFirstResponder()
    }

    @objc private func closeTapped() {
        delegate?.chatGifPanelDidRequestClose(self)
    }

    private func updateCurrentSearchText(
        _ rawValue: String,
        synchronizeField: Bool,
        clearPresetSelection: Bool
    ) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTextByTab[activeTab] = value

        if synchronizeField, searchField.text != value {
            searchField.text = value
        }

        if clearPresetSelection {
            switch activeTab {
            case .gifs:
                selectedGifFilterID = nil
            case .stickers:
                selectedStickerFilterID = nil
            case .emoji:
                if !value.isEmpty {
                    selectedEmojiCategory = nil
                }
            }
            rebuildTopStripButtons()
        }

        clearSearchButton.isHidden = value.isEmpty

        switch activeTab {
        case .emoji:
            rebuildEmojiSections()
        case .gifs, .stickers:
            updateEmbeddedPickerContent(for: activeTab, showLoading: false)
        }
    }

    private func currentSearchText() -> String {
        searchTextByTab[activeTab] ?? ""
    }

    private func setSearchExpanded(_ expanded: Bool) {
        if expanded, headerView.transform != .identity {
            UIView.animate(withDuration: 0.2) {
                self.headerView.transform = .identity
                self.headerView.alpha = 1
            }
        }
        guard expanded != isSearchExpanded else { return }
        isSearchExpanded = expanded
        // Chips yield to the field while typing; height stays fixed (host lifts the bar).
        UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState]) {
            self.applyFrameLayout()
        }
        onPreferredHeightChange?()
    }

    private func rebuildEmojiSections() {
        let query = currentSearchText().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if !query.isEmpty {
            let matches = emojiCatalog.filter {
                $0.value.contains(query) || $0.searchText.localizedCaseInsensitiveContains(query)
            }
            emojiSections =
                matches.isEmpty
                ? []
                : [ChatEmojiSection(title: "Search Results", items: matches)]
        } else if let selectedEmojiCategory {
            if selectedEmojiCategory == .recent {
                let recents = resolvedRecentEmojiEntries()
                emojiSections =
                    recents.isEmpty
                    ? []
                    : [ChatEmojiSection(title: ChatEmojiCategory.recent.title, items: recents)]
            } else {
                emojiSections = [
                    ChatEmojiSection(
                        title: selectedEmojiCategory.title,
                        items: emojiCatalog.filter { $0.category == selectedEmojiCategory }
                    )
                ]
            }
        } else {
            var sections: [ChatEmojiSection] = []
            let recents = resolvedRecentEmojiEntries()
            if !recents.isEmpty {
                sections.append(
                    ChatEmojiSection(title: ChatEmojiCategory.recent.title, items: recents))
            }
            for category in ChatEmojiCategory.browseCases {
                let items = emojiCatalog.filter { $0.category == category }
                if !items.isEmpty {
                    sections.append(ChatEmojiSection(title: category.title, items: items))
                }
            }
            emojiSections = sections
        }

        emojiCollectionView.reloadData()
        let shouldShowEmpty = activeTab == .emoji && emojiSections.allSatisfy(\.items.isEmpty)
        if shouldShowEmpty {
            stateLabel.text =
                query.isEmpty
                ? "No emoji available yet."
                : "No emoji found for \"\(query)\"."
            stateLabel.textColor = secondaryTextColor
            stateLabel.isHidden = false
        } else if activeTab == .emoji {
            stateLabel.isHidden = true
        }
    }

    private func resolvedRecentEmojiEntries() -> [ChatEmojiEntry] {
        recentEmojiValues.compactMap { value in
            emojiCatalog.first(where: { $0.value == value })
        }
    }

    private func registerRecentEmoji(_ emoji: String) {
        recentEmojiValues.removeAll(where: { $0 == emoji })
        recentEmojiValues.insert(emoji, at: 0)
        if recentEmojiValues.count > 32 {
            recentEmojiValues = Array(recentEmojiValues.prefix(32))
        }
        UserDefaults.standard.set(recentEmojiValues, forKey: Self.recentEmojiDefaultsKey)
    }

    private static func loadRecentEmojiValues() -> [String] {
        let stored = UserDefaults.standard.array(forKey: recentEmojiDefaultsKey) as? [String]
        return stored ?? []
    }

    @discardableResult
    private func configureGiphySDKIfNeeded() -> Bool {
        #if canImport(GiphyUISDK)
            let key = ChatGifPanelConfig.shared.apiKey.trimmingCharacters(
                in: .whitespacesAndNewlines)
            print("[NativeGif][iOS] configureGiphySDKIfNeeded keyLength=\(key.count)")
            guard !key.isEmpty else { return false }
            Giphy.configure(apiKey: key)
            print("[NativeGif][iOS] Giphy.configure succeeded")
            return true
        #else
            print("[NativeGif][iOS] GiphyUISDK unavailable")
            return false
        #endif
    }

    #if canImport(GiphyUISDK)
        private func currentGiphyTheme() -> GPHTheme {
            GPHTheme(type: isDarkMode ? .darkBlur : .lightBlur)
        }

        /// Content is derived from the slot, not from live state, so a cached grid re-read
        /// later still describes what it actually holds.
        private func resolvedGiphyContent(for key: ChatGifGridKey) -> GPHContent {
            let stickers = key.tab == .stickers
            let mediaType: GPHMediaType = stickers ? .sticker : .gif

            let query: String
            switch key.slot {
            case .trending:
                return stickers ? .trendingStickers : .trendingGifs
            case .search:
                query = searchTextByTab[key.tab]?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            case .filter(let id):
                query = gifQuickFilters.first(where: { $0.id == id })?.query ?? ""
            }

            guard !query.isEmpty else {
                return stickers ? .trendingStickers : .trendingGifs
            }
            return .search(
                withQuery: query,
                mediaType: mediaType,
                language: .english,
                includeDynamicResults: true
            )
        }
    #endif

    /// The page each grid lives on.
    private func gridContainerView(for tab: ChatGifPanelTab) -> UIView {
        tab == .stickers ? stickerContainerView : mediaContainerView
    }

    /// Which grid the current state wants. A chip writes its query into the field, so the
    /// chip owns the slot even though the content is a search.
    private func gridKey(for tab: ChatGifPanelTab) -> ChatGifGridKey {
        let query = searchTextByTab[tab]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let filterID = tab == .stickers ? selectedStickerFilterID : selectedGifFilterID
        if let filterID, gifQuickFilters.first(where: { $0.id == filterID })?.query == query {
            return ChatGifGridKey(tab: tab, slot: .filter(filterID))
        }
        return ChatGifGridKey(tab: tab, slot: query.isEmpty ? .trending : .search)
    }

    /// Mounts the grid the current slot wants, reusing a cached one when it exists. A
    /// revisited category is already loaded and still at its scroll position.
    private func installEmbeddedPickerIfNeeded(for tab: ChatGifPanelTab) {
        #if canImport(GiphyUISDK)
            guard tab == .gifs || tab == .stickers else { return }
            guard hostViewController != nil else {
                print("[NativeGif][iOS] installEmbeddedPickerIfNeeded missing hostViewController")
                showStateLabel("GIF host is unavailable right now.")
                return
            }

            let key = gridKey(for: tab)
            let alreadyLoaded = embeddedPickers[key] != nil
            guard makeGridIfNeeded(key) != nil else { return }

            stateLabel.isHidden = true
            if panelVisible, !alreadyLoaded {
                loadingSpinner.startAnimating()
                loadingView.isHidden = false
            }
            presentGrid(key)
            evictColdGridsIfNeeded()
            updateContentInsets()
            prefetchBrowseGrids(for: tab)
        #else
            showStateLabel("Install the Giphy native SDK to enable GIF search.")
        #endif
    }

    #if canImport(GiphyUISDK)
        /// Builds and starts a grid, hidden. Presentation is a separate step so categories can
        /// load in the background without stealing the page.
        @discardableResult
        private func makeGridIfNeeded(_ key: ChatGifGridKey) -> GiphyGridController? {
            guard let host = hostViewController else { return nil }
            if let existing = embeddedPickers[key] {
                // A host swap invalidates the child relationship; rebuild rather than reuse.
                if existing.parent === host { return existing }
                print("[NativeGif][iOS] reparent GiphyGridController — host changed")
                discardGrid(key)
            }

            guard configureGiphySDKIfNeeded() else {
                print("[NativeGif][iOS] makeGrid missing API key")
                showStateLabel("Configure a Giphy API key to enable GIF search.")
                return nil
            }

            print("[NativeGif][iOS] creating GiphyGridController slot=\(key.slot)")

            let container = gridContainerView(for: key.tab)
            let picker = GiphyGridController()
            picker.delegate = self
            picker.theme = currentGiphyTheme()
            picker.direction = .vertical
            picker.fixedSizeCells = false
            // Same rendition as send path so cell image / GPHCache hits are reusable.
            picker.renditionType = Self.gridGifRendition
            picker.additionalSafeAreaInsets = .zero
            // Stickers are transparent, so they need air and a column more than GIFs do.
            if key.tab == .stickers {
                picker.cellPadding = 8
                picker.numberOfTracks = 4
            }
            picker.content = resolvedGiphyContent(for: key)

            // Add child before attaching view so hierarchy stays consistent.
            host.addChild(picker)
            picker.view.isHidden = true
            container.addSubview(picker.view)
            picker.view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                picker.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                picker.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                picker.view.topAnchor.constraint(equalTo: container.topAnchor),
                picker.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            picker.view.backgroundColor = .clear
            picker.view.isOpaque = false
            picker.didMove(toParent: host)

            embeddedPickers[key] = picker
            gridRecency.insert(key, at: 0)
            picker.update()
            return picker
        }

        /// Warms the first few category grids so tapping a chip shows a loaded grid instead of
        /// a fetch. Bounded by `maxCachedGrids`; the visible grid is built first.
        private func prefetchBrowseGrids(for tab: ChatGifPanelTab) {
            guard panelVisible, !didPrefetchGrids.contains(tab) else { return }
            didPrefetchGrids.insert(tab)
            let warm = gifQuickFilters.prefix(Self.prefetchedCategories).map {
                ChatGifGridKey(tab: tab, slot: .filter($0.id))
            }
            for (index, key) in warm.enumerated() where embeddedPickers[key] == nil {
                // Staggered so the visible grid keeps the network to itself first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35 + Double(index) * 0.25) {
                    [weak self] in
                    guard let self, self.panelVisible else { return }
                    self.makeGridIfNeeded(key)
                    self.updateContentInsets()
                }
            }
        }
    #endif

    /// Only a free-text search refetches. Category and trending grids keep what they loaded —
    /// that is the whole point of keying a grid per slot.
    private func updateEmbeddedPickerContent(for tab: ChatGifPanelTab, showLoading: Bool) {
        #if canImport(GiphyUISDK)
            guard tab == .gifs || tab == .stickers else { return }
            let key = gridKey(for: tab)
            guard let picker = embeddedPickers[key], picker.parent === hostViewController else {
                if panelVisible {
                    installEmbeddedPickerIfNeeded(for: tab)
                }
                return
            }

            presentGrid(key)
            guard key.slot == .search else {
                loadingSpinner.stopAnimating()
                loadingView.isHidden = true
                stateLabel.isHidden = true
                return
            }

            picker.content = resolvedGiphyContent(for: key)
            if showLoading {
                loadingSpinner.startAnimating()
                loadingView.isHidden = false
            } else {
                loadingSpinner.stopAnimating()
                loadingView.isHidden = true
            }
            stateLabel.isHidden = true
            picker.update()
        #endif
    }

    #if canImport(GiphyUISDK)
        /// Shows one grid on its page and hides its siblings — hidden grids must not scroll
        /// or take touches.
        private func presentGrid(_ key: ChatGifGridKey) {
            for (otherKey, picker) in embeddedPickers where otherKey.tab == key.tab {
                picker.view.isHidden = otherKey != key
            }
            // Recents own the GIF page while their chip is picked; a grid load must not
            // paint through the gaps behind them.
            if isRecentGifCategorySelected { hideGifGrids() }
            gridRecency.removeAll { $0 == key }
            gridRecency.append(key)
        }

        /// Cached grids are bounded; the least recently shown ones go first. Never the
        /// current one, and never a page's only grid.
        private func evictColdGridsIfNeeded() {
            let liveKeys = Set([ChatGifPanelTab.gifs, .stickers].map { gridKey(for: $0) })
            while embeddedPickers.count > Self.maxCachedGrids {
                guard let victim = gridRecency.first(where: { !liveKeys.contains($0) }) else {
                    return
                }
                discardGrid(victim)
            }
        }

        private func discardGrid(_ key: ChatGifGridKey) {
            guard let picker = embeddedPickers.removeValue(forKey: key) else { return }
            gridRecency.removeAll { $0 == key }
            picker.willMove(toParent: nil)
            picker.view.removeFromSuperview()
            // removeFromParent is safe even if parent is already nil.
            if picker.parent != nil {
                picker.removeFromParent()
            }
        }
    #endif

    /// Every grid, dropped. Only for a host change or teardown — NOT for a panel close, or
    /// the next open starts empty and refetches everything.
    private func removeEmbeddedPickers() {
        #if canImport(GiphyUISDK)
            for key in Array(embeddedPickers.keys) { discardGrid(key) }
            didPrefetchGrids.removeAll()
        #endif
    }

    private func showStateLabel(_ text: String) {
        loadingSpinner.stopAnimating()
        loadingView.isHidden = true
        stateLabel.text = text
        stateLabel.textColor = secondaryTextColor
        stateLabel.isHidden = false
    }

    private func normalizedNonEmptyString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    #if canImport(GiphyUISDK)
        /// Grid + send share this so visible cell / GPHCache bytes match the URL we emit.
        private static let gridGifRendition: GPHRenditionType = .downsized

        private func resolvedPrimaryImage(from images: GPHImages?) -> GPHImage? {
            guard let images else { return nil }
            if let preferred = images.rendition(Self.gridGifRendition) { return preferred }
            if let downsized = images.downsized { return downsized }
            if let fixedWidth = images.fixedWidth { return fixedWidth }
            if let fixedHeight = images.fixedHeight { return fixedHeight }
            if let original = images.original { return original }
            if let preview = images.preview { return preview }
            if let fixedWidthSmall = images.fixedWidthSmall { return fixedWidthSmall }
            return nil
        }

        private func findGPHMediaView(in view: UIView) -> GPHMediaView? {
            if let mediaView = view as? GPHMediaView { return mediaView }
            for subview in view.subviews {
                if let found = findGPHMediaView(in: subview) { return found }
            }
            return nil
        }

        /// Prefer the cell's already-decoded GIF, then exact-URL cache; nil falls back to fetch.
        private func localGifData(from cell: UICollectionViewCell?, renditionURL: String?) -> Data? {
            if let cell,
                let mediaView = findGPHMediaView(in: cell),
                let yyImage = mediaView.image as? GiphyYYImage,
                let data = yyImage.animatedImageData,
                !data.isEmpty
            {
                return data
            }
            if let renditionURL,
                let url = URL(string: renditionURL),
                let cached = GPHCache.shared.cache.cachedResponse(for: URLRequest(url: url)),
                !cached.data.isEmpty
            {
                return cached.data
            }
            return nil
        }

        private func resolvedPreviewURL(
            from images: GPHImages?,
            primaryImage: GPHImage?,
            fallbackURL: String
        ) -> String {
            if let preview = normalizedNonEmptyString(images?.preview?.gifUrl) {
                return preview
            }
            if let fixedWidthSmallStill = normalizedNonEmptyString(
                images?.fixedWidthSmallStill?.stillGifUrl)
            {
                return fixedWidthSmallStill
            }
            if let fixedWidthStill = normalizedNonEmptyString(images?.fixedWidthStill?.stillGifUrl)
            {
                return fixedWidthStill
            }
            if let originalStill = normalizedNonEmptyString(images?.originalStill?.stillGifUrl) {
                return originalStill
            }
            if let primaryStill = normalizedNonEmptyString(primaryImage?.stillGifUrl) {
                return primaryStill
            }
            return fallbackURL
        }
    #endif

    private var isDarkMode: Bool {
        traitCollection.userInterfaceStyle == .dark
    }

    private var primaryTextColor: UIColor {
        isDarkMode
            ? UIColor(white: 0.95, alpha: 0.96)
            : UIColor(white: 0.12, alpha: 0.96)
    }

    private var secondaryTextColor: UIColor {
        isDarkMode
            ? UIColor(white: 0.84, alpha: 0.62)
            : UIColor(white: 0.12, alpha: 0.42)
    }

    private var selectedChipColor: UIColor {
        isDarkMode
            ? UIColor.white.withAlphaComponent(0.18)
            : UIColor.black.withAlphaComponent(0.1)
    }

    private var accentBadgeColor: UIColor {
        UIColor(red: 0.90, green: 0.75, blue: 0.48, alpha: 0.92)
    }

    private static let recentEmojiDefaultsKey = "chat.gif.panel.recent.emoji"

    private let gifQuickFilters: [ChatGifQuickFilter] = [
        .init(id: "love", symbolName: "heart", query: "love"),
        .init(id: "like", symbolName: "hand.thumbsup", query: "like"),
        .init(id: "dislike", symbolName: "hand.thumbsdown", query: "dislike"),
        .init(id: "party", symbolName: "party.popper", query: "party"),
        .init(id: "happy", symbolName: "face.smiling", query: "happy"),
        .init(id: "sad", symbolName: "cloud.rain", query: "sad"),
        .init(id: "angry", symbolName: "flame", query: "angry"),
        .init(id: "neutral", symbolName: "minus.circle", query: "neutral"),
    ]

    static let recentFilterID = "recent"

    /// Recents are one chip in the same strip as the browse categories — they used to be a
    /// separate 96pt row pinned under the header with the grid squeezed below it.
    private var stripFilters: [ChatGifQuickFilter] {
        guard activeTab == .gifs, !recentGifEntries.isEmpty else { return gifQuickFilters }
        return [
            .init(id: Self.recentFilterID, symbolName: "clock.arrow.circlepath", query: "")
        ] + gifQuickFilters
    }

    /// True while the recents category owns the GIF page. No Giphy grid backs it.
    var isRecentGifCategorySelected: Bool {
        activeTab == .gifs && selectedGifFilterID == Self.recentFilterID
            && !recentGifEntries.isEmpty
    }

    func hideGifGrids() {
        #if canImport(GiphyUISDK)
            for (key, picker) in embeddedPickers where key.tab == .gifs {
                picker.view.isHidden = true
            }
        #endif
    }

    /// Was a hand-typed list of ~90; now the full set.
    private lazy var emojiCatalog: [ChatEmojiEntry] = ChatEmojiCatalogBuilder.build()
}

extension ChatGifPanelView: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        setSearchExpanded(true)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        setSearchExpanded(false)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

extension ChatGifPanelView {
    @objc fileprivate func tabButtonTapped(_ sender: UIButton) {
        guard let nextTab = ChatGifPanelTab(rawValue: sender.tag), nextTab != activeTab else {
            return
        }
        activeTab = nextTab
        searchField.resignFirstResponder()
        if searchField.text != currentSearchText() {
            searchField.text = currentSearchText()
        }
        selectionFeedback.selectionChanged()
        updateTabButtonSelection()
        applyActiveTabState(animated: true)
    }

    fileprivate func updateTabButtonSelection() {
        for button in bottomTabButtons {
            let selected = button.tag == activeTab.rawValue
            button.setTitleColor(selected ? primaryTextColor : secondaryTextColor, for: .normal)
            button.tintColor = selected ? primaryTextColor : secondaryTextColor
        }
        layoutTabIndicator(animated: window != nil)
    }

    /// Fill rides behind the selected label; the capsule itself never moves.
    fileprivate func layoutTabIndicator(animated: Bool) {
        guard bottomTabButtons.indices.contains(activeTab.rawValue) else { return }
        let button = bottomTabButtons[activeTab.rawValue]
        guard button.bounds.width > 1 else { return }
        let target = button.convert(button.bounds, to: bottomTabBarContainer.contentView)
        let apply = {
            self.bottomTabIndicator.frame = target
            self.bottomTabIndicator.layer.cornerRadius = target.height * 0.5
        }
        guard animated else {
            apply()
            return
        }
        UIView.animate(
            withDuration: 0.26, delay: 0, usingSpringWithDamping: 0.86,
            initialSpringVelocity: 0.4, options: [.allowUserInteraction, .beginFromCurrentState]
        ) { apply() }
    }
}

extension ChatGifPanelView: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        collectionView === recentsCollectionView ? 1 : emojiSections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int)
        -> Int
    {
        if collectionView === recentsCollectionView { return recentGifEntries.count }
        return emojiSections[section].items.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        if collectionView === recentsCollectionView {
            guard
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: ChatGifRecentCell.reuseIdentifier, for: indexPath
                ) as? ChatGifRecentCell
            else { return UICollectionViewCell() }
            let entry = recentGifEntries[indexPath.item]
            let url = ChatGifRecentsStore.shared.fileURL(for: entry)
            let key = url.path as NSString
            if let cached = ChatGifRecentCell.imageCache.object(forKey: key) {
                cell.imageView.image = cached
                return cell
            }
            // A grid of recents is a dozen visible GIFs; reading and decoding them on main
            // is the hang this cache and hop exist to avoid.
            cell.representedKey = key as String
            DispatchQueue.global(qos: .userInitiated).async {
                guard let data = try? Data(contentsOf: url),
                    let image = chatMediaDecodedImagePublic(from: data, shouldAnimate: true)
                else { return }
                DispatchQueue.main.async {
                    ChatGifRecentCell.imageCache.setObject(image, forKey: key)
                    guard cell.representedKey == key as String else { return }
                    cell.imageView.image = image
                }
            }
            return cell
        }
        guard
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatGifPanelEmojiCell.reuseIdentifier,
                for: indexPath
            ) as? ChatGifPanelEmojiCell
        else {
            return UICollectionViewCell()
        }

        let item = emojiSections[indexPath.section].items[indexPath.item]
        cell.configure(emoji: item.value, highlighted: false)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if collectionView === recentsCollectionView {
            let entry = recentGifEntries[indexPath.item]
            let url = ChatGifRecentsStore.shared.fileURL(for: entry)
            let localData = try? Data(contentsOf: url)
            selectionFeedback.selectionChanged()
            delegate?.chatGifPanel(
                self,
                didSelectGif: ChatGifSelection(
                    id: entry.id,
                    url: url.absoluteString,
                    previewUrl: url.absoluteString,
                    width: entry.width,
                    height: entry.height,
                    localData: localData
                ))
            return
        }
        let item = emojiSections[indexPath.section].items[indexPath.item]
        registerRecentEmoji(item.value)
        delegate?.chatGifPanel(self, didSelectEmoji: item.value)
        if activeTab == .emoji && currentSearchText().isEmpty {
            rebuildEmojiSections()
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        // Identify the emoji grid positively. Matching by exclusion dequeued its header
        // identifier on whatever else asked, and only the emoji grid registers it.
        guard collectionView === emojiCollectionView else {
            if collectionView === recentsCollectionView {
                return collectionView.dequeueReusableSupplementaryView(
                    ofKind: kind,
                    withReuseIdentifier: "ChatGifPanelEmptyHeaderView",
                    for: indexPath
                )
            }
            return UICollectionReusableView()
        }

        guard
            kind == UICollectionView.elementKindSectionHeader,
            emojiSections.indices.contains(indexPath.section),
            let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: ChatGifPanelEmojiHeaderView.reuseIdentifier,
                for: indexPath
            ) as? ChatGifPanelEmojiHeaderView
        else {
            return UICollectionReusableView()
        }

        header.configure(title: emojiSections[indexPath.section].title, color: secondaryTextColor)
        return header
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        if collectionView === recentsCollectionView {
            return (collectionViewLayout as? UICollectionViewFlowLayout)?.itemSize
                ?? CGSize(width: 96, height: 96)
        }

        // Derived from the layout's own insets, not a constant that has to agree with them,
        // and square — a taller-than-wide cell put every glyph off its highlight.
        let flow = collectionViewLayout as? UICollectionViewFlowLayout
        let sectionInset = flow?.sectionInset ?? .zero
        let interitem = flow?.minimumInteritemSpacing ?? 8
        let columns: CGFloat = collectionView.bounds.width < 360 ? 7 : 8
        let available =
            collectionView.bounds.width - sectionInset.left - sectionInset.right
            - interitem * (columns - 1)
        let side = max(34, floor(available / columns))
        return CGSize(width: side, height: side)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        referenceSizeForHeaderInSection section: Int
    ) -> CGSize {
        guard collectionView === emojiCollectionView,
              emojiSections.indices.contains(section) else {
            return .zero
        }
        let title = emojiSections[section].title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? .zero : CGSize(width: collectionView.bounds.width, height: 36)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === emojiCollectionView {
            // Only while the finger owns the scroll: a reload resets contentOffset, and that
            // reset is what used to snap the search row back mid-gesture.
            guard scrollView.isDragging || scrollView.isDecelerating else { return }
            let travel = min(
                headerZoneHeight,
                max(0, scrollView.contentOffset.y + scrollView.contentInset.top))
            headerView.transform = CGAffineTransform(translationX: 0, y: -travel)
            headerView.alpha = 1 - (travel / max(1, headerZoneHeight)) * 0.9
            return
        }
        if scrollView === pagesScrollView {
            headerView.transform = .identity
            headerView.alpha = 1
            guard !isProgrammaticPageScroll, pagesScrollView.bounds.width > 1 else { return }
            let page = Int(round(pagesScrollView.contentOffset.x / pagesScrollView.bounds.width))
            guard let tab = ChatGifPanelTab(rawValue: page), tab != activeTab else { return }
            activeTab = tab
            updateTabButtonSelection()
            // Refresh strip/search for the page without re-animating pager.
            rebuildSearchChrome()
            rebuildTopStripButtons()
            switch tab {
            case .gifs, .stickers:
                if panelVisible { installEmbeddedPickerIfNeeded(for: tab) }
                updateEmbeddedPickerContent(for: tab, showLoading: false)
            case .emoji:
                rebuildEmojiSections()
            }
            if searchField.isFirstResponder { setSearchExpanded(true) }
            // Recents belong to the GIF page only, and page frames follow it.
            setNeedsLayout()
        }
    }
}

#if canImport(GiphyUISDK)
    extension ChatGifPanelView: GPHGridDelegate {
        func contentDidUpdate(resultCount: Int, error: (any Error)?) {
            print(
                "[NativeGif][iOS] contentDidUpdate resultCount=\(resultCount) error=\(error != nil)"
            )
            loadingSpinner.stopAnimating()
            loadingView.isHidden = true
            if activeTab != .emoji {
                stateLabel.isHidden = true
            }
            // The grid rewrites its own insets as it loads; ours go back on top.
            updateContentInsets()
        }

        func didSelectMedia(media: GPHMedia, cell: UICollectionViewCell) {
            emitSelection(media: media, cell: cell)
        }

        func didSelectMoreByYou(query: String) {}

        func didScroll(offset: CGFloat) {
            // Header is hosted inside the scroll view itself, so no manual sync is needed.
        }

        func errorDidOccur(_ error: any Error) {
            print("[NativeGif][iOS] grid error: \(error.localizedDescription)")
            showStateLabel("Unable to load \(activeTab.title.lowercased()) right now.")
        }

        func syntheticErrorDidOccur() {
            print("[NativeGif][iOS] grid synthetic error")
            showStateLabel("Unable to load \(activeTab.title.lowercased()) right now.")
        }

        private func emitSelection(media: GPHMedia, cell: UICollectionViewCell) {
            let images = media.images
            let primaryImage = resolvedPrimaryImage(from: images)
            let normalizedMediaID = media.id.isEmpty ? UUID().uuidString.lowercased() : media.id
            let primaryURL = normalizedNonEmptyString(primaryImage?.gifUrl)

            guard
                let url = primaryURL
            else {
                guard let fallbackUrl = normalizedNonEmptyString(media.url) else { return }
                let localData = localGifData(from: cell, renditionURL: fallbackUrl)
                delegate?.chatGifPanel(
                    self,
                    didSelectGif: ChatGifSelection(
                        id: normalizedMediaID,
                        url: fallbackUrl,
                        previewUrl: fallbackUrl,
                        width: 0,
                        height: 0,
                        localData: localData
                    )
                )
                return
            }

            let previewUrl = resolvedPreviewURL(
                from: images,
                primaryImage: primaryImage,
                fallbackURL: url
            )
            let localData = localGifData(from: cell, renditionURL: url)

            delegate?.chatGifPanel(
                self,
                didSelectGif: ChatGifSelection(
                    id: normalizedMediaID,
                    url: url,
                    previewUrl: previewUrl,
                    width: primaryImage?.width ?? 0,
                    height: primaryImage?.height ?? 0,
                    localData: localData
                )
            )
        }
    }
#endif

