import UIKit

/// Uptime anchor for "user tapped a chat row" — set at route creation, read by every
/// `[ChatOpen] host-stage` log so the tap→settled timeline is attributable end to end.
enum VibeChatOpenTap {
  static var uptime: TimeInterval = 0
  static func msSinceTap() -> Int {
    guard uptime > 0 else { return -1 }
    return Int((ProcessInfo.processInfo.systemUptime - uptime) * 1000)
  }
}

final class ChatNativeMainRegistry {
  static let shared = ChatNativeMainRegistry()

  private final class WeakRef {
    weak var value: ChatMainView?

    init(_ value: ChatMainView) {
      self.value = value
    }
  }

  private var map: [String: WeakRef] = [:]

  func register(surfaceId: String, view: ChatMainView) {
    map[surfaceId] = WeakRef(view)
  }

  func view(for surfaceId: String) -> ChatMainView? {
    if let value = map[surfaceId]?.value {
      return value
    }
    map.removeValue(forKey: surfaceId)
    return nil
  }

  func unregister(surfaceId: String) {
    map.removeValue(forKey: surfaceId)
  }
}

private enum ChatMainPage: String {
  case chat
  case profile
  case agent
}

private enum ChatMainHeaderMode: String {
  case `default` = "default"
  case savedMessages = "savedmessages"
}

private enum ChatMainProfileTab: String, CaseIterable {
  case media
  case music
  case files
  case links
  case pinned
}

private struct ChatMainProfileMediaItem: Equatable {
  let messageId: String
  let type: String
  let mediaUrl: String
}

private struct ChatMainProfileFileItem: Equatable {
  let messageId: String
  let type: String
  let fileName: String
  let mediaUrl: String?
  let fileSize: Int64?
  let timestampMs: Int64
}

private struct ChatMainProfileLinkItem: Equatable {
  let messageId: String
  let url: String
  let subtitle: String
}

private struct ChatMainProfilePinnedItem: Equatable {
  let messageId: String
  let text: String
  let subtitle: String
}

private struct ChatMainPinnedBannerContent: Equatable {
  let title: String
  let body: String
  let messageId: String?
  let isFile: Bool
  let mediaUrl: String?
  let fileName: String?
}

public final class ChatMainView: UIView,
  UIGestureRecognizerDelegate,
  ChatMainProfileAgentPromptNodeDelegate,
  UITextFieldDelegate
{
  public var onViewportChanged = NativeEventDispatcher() {
    didSet { syncListDispatchers() }
  }
  public var onNativeEvent = NativeEventDispatcher() {
    didSet { syncListDispatchers() }
  }

  @objc public var surfaceId: String = "" {
    didSet {
      let trimmed = surfaceId.trimmingCharacters(in: .whitespacesAndNewlines)
      if !registeredSurfaceId.isEmpty, registeredSurfaceId != trimmed {
        ChatNativeMainRegistry.shared.unregister(surfaceId: registeredSurfaceId)
      }
      registeredSurfaceId = trimmed
      guard !trimmed.isEmpty else { return }
      ChatNativeMainRegistry.shared.register(surfaceId: trimmed, view: self)
      chatListView.surfaceId = "\(trimmed)#list"
    }
  }

  private let chatListView: ChatListView

  private let headerContainer = UIView()
  private let headerMaskView = UIView()
  private let headerMaskBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
  /// Second blur pass — single material maxes out soft; stack for stronger frost.
  private let headerMaskBlurBoostView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
  private let headerMaskOverlayView = UIView()
  private let headerMaskGradientLayer = CAGradientLayer()
  private let headerContentView = UIView()

  private let backGlassView = UIVisualEffectView(effect: nil)
  private let backButton = UIButton(type: .system)

  private let titleGlassView = UIVisualEffectView(effect: nil)
  private let titleButton = UIButton(type: .custom)

  private let avatarGlassView = UIVisualEffectView(effect: nil)
  private let avatarButton = UIButton(type: .system)
  private let avatarNode = ChatAvatarNodeView()
  /// Lives inside avatar glass — same chip morphs avatar → "Selected" + count.
  private let selectionHeaderStack = UIStackView()
  private let selectionTitleLabel = UILabel()
  private let selectionCountLabel = UILabel()

  private let rightActionsStack = UIStackView()
  private let callButton = UIButton(type: .system)
  private let videoCallButton = UIButton(type: .system)
  private let historyButton = UIButton(type: .system)
  private let newChatButton = UIButton(type: .system)
  /// Selection-mode confirm (replaces call/video glass on the trailing side).
  private let selectionDoneButton = UIButton(type: .system)

  private let menuGlassView = UIVisualEffectView(effect: nil)
  private let savedSearchCancelGlassView = UIVisualEffectView(effect: nil)
  private let rightActionsGlassView = UIVisualEffectView(effect: nil)
  private let menuButton = UIButton(type: .system)
  private let savedSearchField = UITextField()
  private let savedSearchCancelButton = UIButton(type: .system)
  private var savedSearchExpanded = false

  private let profileHeaderContainer = UIView()
  private let profileHeaderMaskView = UIView()
  private let profileHeaderBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
  private let profileHeaderOverlayView = UIView()
  private let profileHeaderMaskGradientLayer = CAGradientLayer()
  private let profileHeaderContentView = UIView()
  private let profileBackGlassView = UIVisualEffectView(effect: nil)
  private let profileBackButton = UIButton(type: .system)
  private let profileMenuGlassView = UIVisualEffectView(effect: nil)
  private let profileMenuButton = UIButton(type: .system)

  private let chatHeaderStack = UIStackView()
  private let chatTitleLabel = UILabel()
  private let chatSubtitleRow = UIStackView()
  private let chatSubtitleDotView = UIView()
  private let chatSubtitleLabel = UILabel()
  /// Leading line spinner for Connecting / Updating — matches Home principal header.
  private let chatConnectingSpinner = VibeHeaderLineSpinnerView(size: 11, lineWidth: 1.55)
  private let profileHeaderStack = UIStackView()
  private let profileTitleLabel = UILabel()
  private let profileSubtitleLabel = UILabel()

  /// The one and only chat wallpaper. Owns gradient, pattern, mask, theme and raster —
  /// see `ChatWallpaperView`. The list used to carry a second copy of all of this.
  private let wallpaperView = ChatWallpaperView()
  private let pagesHost = UIView()
  private let chatPage = UIView()
  // The DM-level agent runtime view (Claude/Codex) is hosted FULL-SCREEN by the owning
  // ChatConversationController (its own header + full bounds), NOT nested inside this view —
  // nesting it below the shared header clipped its height and overlapped its content. These
  // passthroughs let ChatListView's presence logic drive that isolated surface.
  var onPresentBridgeAgentSurface: ((VibeAgentConversationViewController) -> Void)?
  var onDismissBridgeAgentSurface: (() -> Void)?
  var hostedBridgeAgentProviderProvider: (() -> String?)?
  var hostedBridgeAgentSurfaceModeProvider: (() -> VibeAgentConversationSurfaceMode?)?
  private let pinnedBannerView = ChatPinnedBannerView()
  private let inboxBannerView = ChatPinnedBannerView()
  private let profilePage = UIView()
  private let agentPage = UIView()
  private let agentScrollView = UIScrollView()
  private let agentContentView = UIView()
  private let agentPromptNode = ChatMainProfileAgentPromptNode()
  private let profileMembersNode = ChatMainProfileMembersNode()
  private let profileWallpaperLayer = CAGradientLayer()
  private let profileWallpaperPatternLayer = CAGradientLayer()
  private let profileWallpaperPatternMaskLayer = CALayer()
  private let profileScrollView = UIScrollView()
  private let profileContentView = UIView()

  private let profileAvatarView = UIView()
  private let profileAvatarNode = ChatAvatarNodeView()
  private let profileOnlineDotView = UIView()
  private let profileNameLabel = UILabel()
  private let profileHandleLabel = UILabel()
  private let profileBioLabel = UILabel()
  private let profileActionsStack = UIStackView()
  private let profileMuteButton = ChatMainProfileActionNode()
  private let profileSearchButton = ChatMainProfileActionNode()
  private let profileAudioCallButton = ChatMainProfileActionNode()
  private let profileVideoCallButton = ChatMainProfileActionNode()
  private let profileIdentityCard = UIView()
  private let profileUsernameRow = ChatMainProfileListRowNode()
  private let profileBioRow = ChatMainProfileListRowNode()
  private let profileTabsCard = UIView()
  private let profileTabsScrollView = UIScrollView()
  private let profileTabsStack = UIView()
  private let profileTabContentContainer = UIView()
  private let profileTabPlaceholderLabel = UILabel()

  private let profileAgentRow = ChatMainProfileListRowNode()
  private var agentConfig: [String: Any]?
  private var isGroupOrChannel = false
  /// Broadcast channel (not a multi-member group). Drives header/profile copy.
  private var isChannel = false

  private var appearance = ChatListAppearance.current
  private var lastAppliedSystemStyleIsDark: Bool?
  private var lastRawAppearance: [String: Any]?
  private var headerMode: ChatMainHeaderMode = .default
  private var builtInAgentChatMode = false
  private var bridgeProvider: String = ""
  private var ownedStandaloneAgentMode = false
  private var isOnline = false
  private var surfacePresenceOnline: Bool?
  private var chatTitleText: String = "Chat"
  private var chatSubtitleText: String = ""
  private var headerUnreadCount = 0
  private var profileNameText: String = "User"
  private var profileHandleText: String = ""
  private var profileBioText: String = ""
  private var groupMemberDisplayNameByUserId: [String: String] = [:]
  private var groupMemberRoleByUserId: [String: String] = [:]
  private var groupMemberOrder: [String] = []
  private var groupAvatarMembers: [[String: Any]] = []
  private var groupMemberCount: Int?
  private var groupTypingUserIds: [String] = []
  /// Sticky group-typing display: last uptime each member was seen typing. During a
  /// multi-agent run the per-agent typing events renew on independent TTLs, so the raw
  /// engine set flaps (Agy → Grok → Codex → …) several times a second. Members stay in
  /// the displayed set for a short hold window so the header reads steady.
  private var groupTypingLastSeenAt: [String: TimeInterval] = [:]
  private var groupTypingHoldTimer: Timer?
  private static let groupTypingHoldSeconds: TimeInterval = 3.5
  private var directPeerTypingActive = false
  private var hasPeerResponseInCurrentRows = false
  private var agentProgressSubtitle: String?
  private var agentAwaitingApproval = false
  // The current bridge session's History-panel title, prefetched with the engine-state
  // snapshot. Shown as the idle header subtitle so the user knows WHICH session this
  // thread is on; nil (no session yet / New Chat) falls back to "Start session".
  private var bridgeSessionTopic: String?
  private var bridgeSessionModel: String?
  /// Last concrete model reported for the mounted bridge session. History/list/runtime
  /// snapshots arrive independently; a later sparse snapshot must not replace a real
  /// model (for example `claude-opus-4-8`) with the provider fallback (`Claude`).
  private var bridgeLastKnownRealModel: String?
  private var bridgeSessionReasoningEffort: String?
  private var bridgeSessionProjectName: String?
  private var bridgeSessionProjectPath: String?
  private var defersEngineStateRefreshes = false
  private var engineStateUpdatesSuspended = false
  private var pinnedBannerMessageId: String?
  private var pinnedBannerTitle: String?
  private var pinnedBannerBody: String?
  private var pinnedBannerMediaUrl: String?
  private var pinnedBannerFileName: String?
  private var pinnedBannerIsFile = false
  private var agentInboxModeEnabled = false
  private var inboxBannerCount = 0
  private var inboxBannerPreview: String?
  private var persistentInboxCount: Int?
  private var persistentInboxPreview: String?
  private var builderSetupPanelPayload: ChatBuilderPanelPayload?
  private var builderSetupNavigationController: UINavigationController?
  private var lastPresentedBuilderRequestId: String?
  private var lastPresentedBuilderReviewSignature: String?
  private var avatarGradientStartLight: String?
  private var avatarGradientEndLight: String?
  private var avatarGradientStartDark: String?
  private var avatarGradientEndDark: String?
  private var avatarUri: String = ""
  private var isChatMuted = false
  private var engineChatId: String = ""
  private var enginePeerUserIdRaw: String = ""
  private var enginePeerUserId: String = ""
  private var engineLastSeenTimestampMs: Int64?
  private var profileSummaryMessageCount = 0
  private var profileSummaryMediaCount = 0
  private var profileSummaryFileCount = 0
  private var profileSummaryLinkCount = 0
  private var profileSummaryRecentFiles: [String] = []
  private var profileSummaryHistoryLoaded = false
  private var profileMediaItems: [ChatMainProfileMediaItem] = []
  private var profileMusicItems: [ChatMainProfileFileItem] = []
  private var profileFileItems: [ChatMainProfileFileItem] = []
  private var profileLinkItems: [ChatMainProfileLinkItem] = []
  private var profilePinnedItems: [ChatMainProfilePinnedItem] = []
  private var profileVisibleTabs: [ChatMainProfileTab] = []
  private var profileTabButtons: [ChatMainProfileTab: ChatMainProfileTabNode] = [:]
  private var profileActiveTab: ChatMainProfileTab = .media
  private var profileTabContentNeedsReload = true
  private var profileLastTabContentWidth: CGFloat = 0.0
  private var currentPage: ChatMainPage = .chat
  private var registeredSurfaceId: String = ""
  private var pendingNativePageTarget: ChatMainPage?
  private var pendingNativePageLockUntil: CFTimeInterval = 0.0
  private var profileSwipeStartProgress: CGFloat = 0.0
  private var chatHeaderCenterMinWidth: CGFloat = 0.0
  private var standaloneProfileMode = false
  private var profileHierarchyAttached = false
  private var externalNavigationHeaderEnabled = false
  private var previewHeaderCenterOnly = false
  private var previewHeaderCompactLeading = false
  private let engineStateRefreshQueue = DispatchQueue(
    label: "vibe.chat.main.engine-state",
    qos: .utility
  )
  private var engineStateRefreshGeneration = 0
  private var engineStateRefreshWorkItem: DispatchWorkItem?

  private lazy var profileSwipeBackGesture: UIScreenEdgePanGestureRecognizer = {
    let gesture = UIScreenEdgePanGestureRecognizer(
      target: self, action: #selector(handleProfileSwipeBack(_:)))
    gesture.edges = .left
    gesture.delegate = self
    return gesture
  }()


  private static let profileListDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()

  private static let themeDarkBg = UIColor(
    red: 18.0 / 255.0, green: 18.0 / 255.0, blue: 18.0 / 255.0, alpha: 1.0)
  private static let themeLightBg = UIColor(
    red: 245.0 / 255.0, green: 244.0 / 255.0, blue: 241.0 / 255.0, alpha: 1.0)
  private static let themeDarkCard = UIColor(
    red: 36.0 / 255.0, green: 36.0 / 255.0, blue: 36.0 / 255.0, alpha: 1.0)
  private static let themeLightCard = UIColor.white
  override init(frame: CGRect) {
    let initStartedAt = ProcessInfo.processInfo.systemUptime
    chatListView = ChatListView()
    let listDoneAt = ProcessInfo.processInfo.systemUptime
    super.init(frame: frame)
    clipsToBounds = true
    configureView()
    let configureDoneAt = ProcessInfo.processInfo.systemUptime
    startObservingChatEngine()
    syncListDispatchers()
    applyTheme()
    updateHeaderTexts()
    updateProfileTexts()
    let now = ProcessInfo.processInfo.systemUptime
    NSLog(
      "[ChatOpen] host-stage ChatMainView.init totalMs=%d listMs=%d configureMs=%d sinceTapMs=%d",
      Int((now - initStartedAt) * 1000),
      Int((listDoneAt - initStartedAt) * 1000),
      Int((configureDoneAt - listDoneAt) * 1000),
      VibeChatOpenTap.msSinceTap())
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    reapplyNativeThemeIfSystemStyleChanged()
  }

  override public func didMoveToWindow() {
    super.didMoveToWindow()
    reapplyNativeThemeIfSystemStyleChanged()
  }

  /// This page owns light/dark for everything inside it. The list used to derive it too,
  /// from its own detached traitCollection, and whichever ran last won.
  private func reapplyNativeThemeIfSystemStyleChanged() {
    guard window != nil else { return }
    let isDarkNow = ChatListAppearance.resolvedSystemStyle() == .dark
    guard lastAppliedSystemStyleIsDark != isDarkNow else { return }
    lastAppliedSystemStyleIsDark = isDarkNow
    ChatListAppearance.invalidateBootstrap()
    reapplyNativeThemeForCurrentInterfaceStyle()
  }

  deinit {
    engineStateRefreshWorkItem?.cancel()
    groupTypingHoldTimer?.invalidate()
    NotificationCenter.default.removeObserver(
      self, name: ChatEngine.didChangeNotification, object: nil)
    if !registeredSurfaceId.isEmpty {
      ChatNativeMainRegistry.shared.unregister(surfaceId: registeredSurfaceId)
    }
  }

  override public func layoutSubviews() {
    super.layoutSubviews()
    let layoutStartedAt = ProcessInfo.processInfo.systemUptime
    var layoutMarkAt = layoutStartedAt
    func layoutPhaseMs() -> Int {
      let now = ProcessInfo.processInfo.systemUptime
      defer { layoutMarkAt = now }
      return Int((now - layoutMarkAt) * 1000)
    }
    wallpaperView.frame = bounds
    layoutChrome()
    let chromeMs = layoutPhaseMs()
    layoutPages()
    let pagesMs = layoutPhaseMs()
    layoutProfileContent()
    layoutProfileMembersContent()
    let profileMs = layoutPhaseMs()
    layoutAgentContent()
    let agentMs = layoutPhaseMs()
    applyPageState(animated: false, emitEvent: false, fromLayout: true)
    let pageStateMs = layoutPhaseMs()
    let layoutTotalMs = Int((ProcessInfo.processInfo.systemUptime - layoutStartedAt) * 1000)
    if layoutTotalMs >= 8 {
      NSLog(
        "[ChatOpen] host-stage ChatMainView.layout totalMs=%d chromeMs=%d pagesMs=%d profileMs=%d agentMs=%d pageStateMs=%d sinceTapMs=%d",
        layoutTotalMs, chromeMs, pagesMs, profileMs, agentMs, pageStateMs,
        VibeChatOpenTap.msSinceTap())
    }

  }

  // MARK: - Forwarded chat-list APIs

  func setOpeningUnreadCount(_ value: Int) {
    chatListView.setOpeningUnreadCount(value)
  }

  func persistViewportState() {
    chatListView.persistViewportState()
  }

  func captureReopenSnapshot() {
    chatListView.captureReopenSnapshot()
  }

  func setRows(_ rows: [[String: Any]]) {
    // [EmptyTrace] The chat view gets its rows here. Log an empty apply together with the
    // current header progress subtitle — if this prints "EMPTY … progress=<label>" mid-run,
    // the engine handed the view an empty list while a run was live (the reported bug). Pair
    // with the engine's [EmptyTrace] lines to see which clear/reset produced it.
    if rows.isEmpty {
      VibeDebugLog.log(
        "[EmptyTrace] ChatMainView.setRows EMPTY chatId=%@ progress=%@ bridge=%@",
        engineChatId.isEmpty ? "-" : String(engineChatId.suffix(12)),
        agentProgressSubtitle ?? "nil",
        bridgeProvider.isEmpty ? "-" : bridgeProvider)
    }
    chatListView.setRows(rows)
    let nextHasPeerResponse = Self.rowsContainPeerResponse(rows, peerUserId: enginePeerUserId)
    if nextHasPeerResponse != hasPeerResponseInCurrentRows {
      hasPeerResponseInCurrentRows = nextHasPeerResponse
      applyTheme()
      updateHeaderTexts()
      updateProfileTexts()
    }
  }

  func setAuthoritativeRows(_ rows: [[String: Any]]) {
    chatListView.setAuthoritativeRows(rows)
    let nextHasPeerResponse = Self.rowsContainPeerResponse(rows, peerUserId: enginePeerUserId)
    if nextHasPeerResponse != hasPeerResponseInCurrentRows {
      hasPeerResponseInCurrentRows = nextHasPeerResponse
      applyTheme()
      updateHeaderTexts()
      updateProfileTexts()
    }
  }

  func clearRows() {
    chatListView.clearRows()
    hasPeerResponseInCurrentRows = false
    applyTheme()
    updateHeaderTexts()
    updateProfileTexts()
  }

  func animateClearChatDisintegration(completion: @escaping () -> Void) {
    chatListView.animateClearChatDisintegration(completion: completion)
  }

  func setEngineSurfaceId(_ value: String) {
    chatListView.setEngineSurfaceId(value)
  }

  func setRestrictSavingContent(_ restricted: Bool) {
    chatListView.setRestrictSavingContent(restricted)
  }

  func setDefersEngineStateRefreshes(_ value: Bool) {
    if defersEngineStateRefreshes == value { return }
    defersEngineStateRefreshes = value
    VibeDebugLog.log("[ChatMainView] defersEngineStateRefreshes=%@", value ? "true" : "false")
    // The flag gates connection/presence chrome, so repaint it here rather than
    // waiting on an incidental layout pass.
    updateHeaderTexts()
  }

  /// Freeze the transcript's geometry while this chat is off (or leaving) the screen.
  /// See `ChatListView.setGeometryFrozenForDismissal`.
  func setGeometryFrozenForDismissal(_ frozen: Bool) {
    chatListView.setGeometryFrozenForDismissal(frozen)
  }

  func dismissGifPanel() {
    chatListView.dismissGifPanel()
  }

  func setEngineStateUpdatesSuspended(_ suspended: Bool) {
    if engineStateUpdatesSuspended == suspended { return }
    engineStateUpdatesSuspended = suspended
    if suspended {
      // Drop any in-flight / queued snapshot without touching visible header/profile state.
      engineStateRefreshGeneration &+= 1
      engineStateRefreshWorkItem?.cancel()
      engineStateRefreshWorkItem = nil
      return
    }
    guard !defersEngineStateRefreshes else { return }
    scheduleEngineStateRefresh(force: true, reason: "hostBecameVisible")
  }

  func setDefersTranscriptUpdatesForPresentation(_ value: Bool) {
    chatListView.setDefersTranscriptUpdatesForPresentation(value)
  }

  func beginNavigationPushPrestaging() {
    chatListView.beginNavigationPushPrestaging()
  }

  func setNavigationPrestageSafeAreaBottom(_ inset: CGFloat) {
    chatListView.setNavigationPrestageSafeAreaBottom(inset)
  }

  @discardableResult
  func finishNavigationPushPrestaging() -> Bool {
    chatListView.finishNavigationPushPrestaging()
  }

  func completeTranscriptPresentation() {
    chatListView.completeTranscriptPresentation()
  }

  func setEngineChatId(_ value: String) {
    engineChatId = value.trimmingCharacters(in: .whitespacesAndNewlines)
    VibeDebugLog.log("[ChatMainView][Pin] setEngineChatId=%@", engineChatId)
    chatListView.setEngineChatId(value)
    guard !defersEngineStateRefreshes else {
      updateHeaderTexts()
      updateProfileTexts()
      updateAvatarViews()
      return
    }
    scheduleEngineStateRefresh(force: true, reason: "setEngineChatId")
    fetchAgentConfigForCurrentChat()
    updateAvatarViews()
  }

  func setEngineMyUserId(_ value: String) {
    chatListView.setEngineMyUserId(value)
  }

  func setEnginePeerUserId(_ value: String) {
    enginePeerUserIdRaw = value.trimmingCharacters(in: .whitespacesAndNewlines)
    enginePeerUserId = enginePeerUserIdRaw.uppercased()
    surfacePresenceOnline = nil
    hasPeerResponseInCurrentRows = false
    chatListView.setEnginePeerUserId(value)
    if enginePeerUserId.isEmpty {
      engineLastSeenTimestampMs = nil
      updateHeaderTexts()
      updateProfileTexts()
      updateAvatarViews()
      return
    }
    guard !defersEngineStateRefreshes else {
      updateHeaderTexts()
      updateProfileTexts()
      updateAvatarViews()
      return
    }
    scheduleEngineStateRefresh(force: true, reason: "setEnginePeerUserId")
    updateAvatarViews()
  }

  func setEnginePeerAgentId(_ value: String) {
    chatListView.setEnginePeerAgentId(value)
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let next = !normalized.isEmpty && ChatOwnedAgentIdsCache.agentIds.contains(normalized)
    guard ownedStandaloneAgentMode != next else { return }
    ownedStandaloneAgentMode = next
    updateChatModeHeaderControls()
    setNeedsLayout()
  }

  /// Host controller asks (at view-appear) to mount the isolated agent surface as this DM's
  /// primary page when its Default view is Agent — passing the provider straight from the route
  /// so it mounts during the push (before the deferred peer-id binding) with no chat-view flash.
  func presentPreferredAgentViewNow(provider: String) {
    chatListView.presentPreferredAgentViewNow(provider: provider)
  }

  func setBridgeProvider(_ value: String) {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard bridgeProvider != normalized else { return }
    bridgeProvider = normalized
    bridgeSessionModel = nil
    bridgeLastKnownRealModel = nil
    bridgeSessionReasoningEffort = nil
    bridgeSessionProjectName = nil
    bridgeSessionProjectPath = nil
    chatListView.setBridgeProvider(normalized)
    updateChatModeHeaderControls()
    applyTheme()
    updateHeaderTexts()
    updateProfileTexts()
    setNeedsLayout()
  }

  /// Scope the chat list to an explicitly-picked History session (or clear with nil).
  /// Required so follow-ups appear under historical isolation and multi-session
  /// bridge rows do not combine on the shared agent DM chatId.
  func setBridgeLoadedSessionId(_ sessionId: String?) {
    chatListView.setBridgeLoadedSessionId(sessionId)
  }

  /// History sheet pick: seed the session title, scope the list, show the custom
  /// skeleton spinner, and request the session transcript from the bridge.
  /// Header shows **Loading…** until rows land (never the idle "Start session" default).
  func loadBridgeHistorySession(provider: String, session: AgentBridgeHistorySession) {
    let topic = session.topic.trimmingCharacters(in: .whitespacesAndNewlines)
    // Seed topic for when load finishes; while in-flight the subtitle is "Loading…".
    if !topic.isEmpty {
      bridgeSessionTopic = topic
    }
    bridgeLastKnownRealModel = nil
    bridgeSessionModel = session.model
    bridgeSessionReasoningEffort = session.reasoningEffort
    bridgeSessionProjectName = session.projectName
    bridgeSessionProjectPath = session.projectPath
    chatListView.loadBridgeSessionIntoChat(provider: provider, session: session)
    updateHeaderTexts()
  }

  /// Enables agent inbox mode: event notifications are filtered out of the
  /// transcript and surfaced via the Inbox banner.
  func setAgentEventInboxMode(enabled: Bool) {
    if agentInboxModeEnabled != enabled {
      agentInboxModeEnabled = enabled
      if !enabled {
        inboxBannerCount = 0
        inboxBannerPreview = nil
        persistentInboxCount = nil
        persistentInboxPreview = nil
        setNeedsLayout()
      }
    }
    chatListView.setEventInboxModeEnabled(enabled)
  }

  private func updateInboxBanner(count: Int, latestPreview: String?) {
    inboxBannerCount = count
    inboxBannerPreview = latestPreview
    renderInboxBanner()
  }

  func setPersistentAgentEventInbox(count: Int, latestPreview: String?) {
    persistentInboxCount = max(0, count)
    persistentInboxPreview = latestPreview
    renderInboxBanner()
  }

  private func renderInboxBanner() {
    let count = max(inboxBannerCount, persistentInboxCount ?? 0)
    let latestPreview = persistentInboxPreview ?? inboxBannerPreview
    // The banner is the inbox surface: show it whenever the agent is in inbox
    // mode, even with zero notifications, so the user always has a place to tap.
    // In batched_summary mode a summary message may not arrive for hours, so a
    // count-gated banner would otherwise stay hidden the whole time.
    let shouldShow = agentInboxModeEnabled
    if shouldShow {
      let title: String
      switch count {
      case 0: title = "Inbox"
      case 1: title = "Inbox · 1 notification"
      default: title = "Inbox · \(count) notifications"
      }
      let body = count == 0 ? "No new notifications" : (latestPreview ?? "Tap to review agent updates")
      inboxBannerView.configure(
        title: title,
        body: body,
        systemImage: count == 0 ? "tray" : "tray.full.fill",
        animateIcon: inboxBannerView.isHidden
      )
    }
    let wasHidden = inboxBannerView.isHidden
    if shouldShow, wasHidden {
      inboxBannerView.alpha = 0.0
      inboxBannerView.isHidden = false
      UIView.animate(withDuration: 0.2) {
        self.inboxBannerView.alpha = self.currentPage == .chat ? 1.0 : 0.0
      }
    } else if !shouldShow, !wasHidden {
      UIView.animate(
        withDuration: 0.2,
        animations: { self.inboxBannerView.alpha = 0.0 },
        completion: { _ in self.inboxBannerView.isHidden = true })
    } else if shouldShow {
      inboxBannerView.alpha = currentPage == .chat ? 1.0 : 0.0
    }
    setNeedsLayout()
  }

  @objc private func handleInboxBannerPressed() {
    guard currentPage == .chat else { return }
    onNativeEvent(["type": "agentInboxPressed"])
  }

  /// Notification rows currently held out of the transcript by inbox mode, in
  /// transcript order (oldest first). Used to populate the Inbox view.
  func currentEventInboxRows() -> [ChatListRow] {
    chatListView.eventInboxRows
  }

  func setEngineChannelBindingEnabled(_ enabled: Bool) {
    chatListView.setEngineChannelBindingEnabled(enabled)
  }

  func setStatusAuthorityEnabled(_ enabled: Bool) {
    chatListView.setStatusAuthorityEnabled(enabled)
  }

  func refreshEngineStateAfterDeferredRouteOpen() {
    guard !defersEngineStateRefreshes else { return }
    scheduleEngineStateRefresh(force: true, reason: "deferredRouteOpen")
    fetchAgentConfigForCurrentChat()
  }

  func setAppearance(_ rawAppearance: [String: Any]) {
    lastRawAppearance = rawAppearance
    appearance = ChatListAppearance.from(raw: rawAppearance)
    chatListView.setAppearance(rawAppearance)
    applyTheme()
    updateHeaderTexts()
    updateProfileTexts()
  }

  func refreshProfileAppearance() {
    applyTheme()
    updateAvatarViews()
    updateHeaderTexts()
    updateProfileTexts()
    setNeedsLayout()
  }

  private func reapplyNativeThemeForCurrentInterfaceStyle() {
    let isDark = ChatListAppearance.resolvedSystemStyle() == .dark
    let rawAppearance = ChatAppearanceDraftStore.chatRawAppearance(isDark: isDark)
    setAppearance(rawAppearance)
  }

  func setContentPaddingBottom(_ value: Double) {
    chatListView.setContentPaddingBottom(value)
  }

  func setContentPaddingTop(_ value: Double) {
    // The native layoutPages() already calculates the correct top padding
    // based on safeAreaInsets + header height. Ignore trivially small JS values
    // (e.g. 0) that would reset the padding and cause the list to render
    // behind the header.
    guard value > 10.0 else { return }
    chatListView.setContentPaddingTop(value)
  }

  func setExternalNavigationHeaderEnabled(_ enabled: Bool) {
    guard externalNavigationHeaderEnabled != enabled else { return }
    externalNavigationHeaderEnabled = enabled
    updateChatModeHeaderControls()
    setNeedsLayout()
  }

  func setPreviewHeaderCenterOnly(_ enabled: Bool) {
    guard previewHeaderCenterOnly != enabled else { return }
    previewHeaderCenterOnly = enabled
    updateChatModeHeaderControls()
    setNeedsLayout()
  }

  func setPreviewHeaderCompactLeading(_ enabled: Bool) {
    guard previewHeaderCompactLeading != enabled else { return }
    previewHeaderCompactLeading = enabled
    updateChatModeHeaderControls()
    setNeedsLayout()
  }

  func setProgressiveHeightWarmupSuppressed(_ suppressed: Bool) {
    chatListView.suppressesProgressiveHeightWarmup = suppressed
  }

  /// Mark this as the home long-press preview list: reuse the real chat's
  /// heights at the narrower card width (no per-hold re-measure) and never
  /// persist narrow-width heights over the real chat's on-disk cache.
  func setEphemeralPreviewMode(_ ephemeral: Bool) {
    chatListView.isEphemeralPreview = ephemeral
  }

  func setVoicePlayback(_ payload: [String: Any]) {
    chatListView.setVoicePlayback(payload)
  }

  func setInputBarEnabled(_ enabled: Bool) {
    chatListView.setInputBarEnabled(enabled)
  }

  func setInputPlaceholder(_ value: String) {
    chatListView.setInputPlaceholder(value)
  }

  func setComposerText(_ value: String, focus: Bool = true) {
    chatListView.setComposerText(value, focus: focus)
  }

  func setNativeSendEnabled(_ enabled: Bool) {
    chatListView.setNativeSendEnabled(enabled)
  }

  func setAgentChatMode(_ enabled: Bool) {
    builtInAgentChatMode = enabled
    chatListView.setAgentChatMode(enabled)
    updateHeaderTexts()
  }

  func setAgentStreaming(_ streaming: Bool) {
    chatListView.setAgentStreaming(streaming)
  }

  func setDebugAnimationPanel(_ enabled: Bool) {
    chatListView.setDebugAnimationPanel(enabled)
  }

  func applyTransactions(_ transactions: [[String: Any]]) {
    chatListView.applyTransactions(transactions)
  }

  func scrollToBottom(animated: Bool) {
    chatListView.scrollToBottom(animated: animated)
  }

  func scrollToMessage(messageId: String, animated: Bool, viewPosition: Double) {
    chatListView.scrollToMessage(
      messageId: messageId, animated: animated, viewPosition: viewPosition)
  }

  func openHeaderSearch() {
    if currentPage != .chat {
      currentPage = .chat
      applyPageState(animated: true, emitEvent: true)
    }
    setHeaderSearchExpanded(true, animated: true)
  }

  func openProfileContent(_ payload: [String: Any]) {
    let messageId =
      (payload["messageId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? ""
    let tab = (payload["tab"] as? String)?.lowercased() ?? ""
    let url = (payload["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let senderName =
      (payload["senderName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let mediaKey =
      (payload["mediaKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let sourceView = payload["sourceView"] as? UIView
    chatListView.openProfileContent(
      messageId: messageId,
      tab: tab,
      urlString: url,
      senderName: senderName,
      mediaKey: mediaKey,
      sourceView: sourceView
    )
  }

  func startSendTransition(_ payload: [String: Any]) {
    chatListView.startSendTransition(payload)
  }

  func playReactionFx(_ payload: [String: Any]) {
    chatListView.playReactionFx(payload)
  }

  // MARK: - Main view inputs

  func setHeaderMode(_ value: String) {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let nextMode = ChatMainHeaderMode(rawValue: normalized) ?? .default
    if headerMode == nextMode { return }
    headerMode = nextMode
    updateChatModeHeaderControls()
    updateHeaderTexts()
    updateAvatarViews()
    setNeedsLayout()
    applyPageState(animated: false, emitEvent: false)
  }

  func setHeaderTitle(_ value: String) {
    chatTitleText = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if profileNameText.isEmpty {
      profileNameText = chatTitleText
    }
    updateHeaderTexts()
    updateProfileTexts()
    updateAvatarViews()
  }

  func setHeaderUnreadCount(_ value: Int) {
    let nextValue = max(0, value)
    guard headerUnreadCount != nextValue else { return }
    headerUnreadCount = nextValue
    updateBackButtonContent()
    setNeedsLayout()
  }

  func setHeaderSubtitle(_ value: String) {
    chatSubtitleText = value.trimmingCharacters(in: .whitespacesAndNewlines)
    updateHeaderTexts()
  }

  func setProfileName(_ value: String) {
    profileNameText = value.trimmingCharacters(in: .whitespacesAndNewlines)
    updateHeaderTexts()
    updateProfileTexts()
  }

  func setProfileHandle(_ value: String) {
    profileHandleText = value.trimmingCharacters(in: .whitespacesAndNewlines)
    updateProfileTexts()
  }

  func setProfileBio(_ value: String) {
    profileBioText = value.trimmingCharacters(in: .whitespacesAndNewlines)
    updateProfileTexts()
  }

  func setGroupMembers(_ rawMembers: [[String: Any]]) {
    var nextNamesByUserId: [String: String] = [:]
    var nextRolesByUserId: [String: String] = [:]
    var nextOrder: [String] = []
    var roleSources: [String: String] = [:]
    for raw in rawMembers {
      let rawId =
        (raw["userId"] as? String)
        ?? (raw["user_id"] as? String)
        ?? (raw["id"] as? String)
        ?? (raw["memberId"] as? String)
      let trimmedId = rawId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !trimmedId.isEmpty else { continue }
      let normalizedId = trimmedId.uppercased()
      let rawName =
        (raw["name"] as? String)
        ?? (raw["username"] as? String)
        ?? (raw["displayName"] as? String)
        ?? (raw["label"] as? String)
        ?? trimmedId
      let displayName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
      if nextNamesByUserId[normalizedId] == nil {
        nextOrder.append(normalizedId)
      }
      nextNamesByUserId[normalizedId] = displayName.isEmpty ? trimmedId : displayName
      if let rawRole =
        (raw["role"] as? String)
        ?? (raw["memberRole"] as? String)
        ?? (raw["member_role"] as? String)
        ?? (raw["participantRole"] as? String)
      {
        let normalizedRole = rawRole.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedRole.isEmpty {
          nextRolesByUserId[normalizedId] = normalizedRole
          if raw["role"] != nil {
            roleSources[normalizedId] = "role"
          } else if raw["memberRole"] != nil {
            roleSources[normalizedId] = "memberRole"
          } else if raw["member_role"] != nil {
            roleSources[normalizedId] = "member_role"
          } else {
            roleSources[normalizedId] = "participantRole"
          }
        }
      } else if let previousRole = groupMemberRoleByUserId[normalizedId], !previousRole.isEmpty {
        // Preserve last-known role when an incomplete payload omits it — stops
        // admin ↔ member flicker when home/list refreshes without role fields.
        nextRolesByUserId[normalizedId] = previousRole
        roleSources[normalizedId] = "preserved"
      } else {
        roleSources[normalizedId] = "missing"
      }
    }
    // If this payload was empty/partial, keep prior roles for ids we already knew
    // that didn't appear — but only when the new list is empty (don't invent).
    if nextOrder.isEmpty, !groupMemberOrder.isEmpty {
      NSLog(
        "[WhoAmI] ChatMainView.setGroupMembers EMPTY-PAYLOAD ignored — keep prior members=%d",
        groupMemberOrder.count
      )
      return
    }
    let config = ChatEngineStore.shared.getConfig()
    let me =
      (config["userId"] as? String)
      ?? (config["myUserId"] as? String)
      ?? (config["user_id"] as? String)
      ?? ""
    let meKey = me.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let myPrev = meKey.isEmpty ? nil : groupMemberRoleByUserId[meKey]
    let myNext = meKey.isEmpty ? nil : nextRolesByUserId[meKey]
    let mySource = meKey.isEmpty ? "no-me" : (roleSources[meKey] ?? "not-in-roster")
    let flipped =
      (myPrev ?? "") != (myNext ?? "")
      && !(myPrev ?? "").isEmpty
      && !(myNext ?? "").isEmpty
    NSLog(
      "[WhoAmI] ChatMainView.setGroupMembers chatMembers=%d me=%@ prevRole=%@ nextRole=%@ source=%@ flipped=%@ isAdmin=%@ sample=[%@]",
      nextOrder.count,
      meKey.isEmpty ? "<unknown>" : String(meKey.prefix(8)),
      myPrev ?? "<nil>",
      myNext ?? "<nil>",
      mySource,
      flipped ? "Y" : "N",
      (myNext == "owner" || myNext == "admin") ? "Y" : "N",
      nextOrder.prefix(6).map { id in
        "\(String(id.prefix(6))):\(nextRolesByUserId[id] ?? "?")/\(roleSources[id] ?? "?")"
      }.joined(separator: " ")
    )
    groupMemberDisplayNameByUserId = nextNamesByUserId
    groupMemberRoleByUserId = nextRolesByUserId
    groupMemberOrder = nextOrder
    groupAvatarMembers = rawMembers
    // Feed the message list its sender directory (name + avatar + agent provider) so
    // incoming group bubbles can show the sender's name label and floating avatar.
    chatListView.setGroupSenderDirectory(rawMembers)
    if !defersEngineStateRefreshes {
      scheduleEngineStateRefresh(force: true, reason: "setGroupMembers")
    }
    updateHeaderTexts()
    updateProfileTexts()
    updateAvatarViews()
  }

  func setGroupMemberCount(_ value: Int?) {
    if let value {
      groupMemberCount = max(0, value)
    } else {
      groupMemberCount = nil
    }
    updateHeaderTexts()
    updateProfileTexts()
  }

  func setAvatarUri(_ value: String?) {
    let next = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard avatarUri != next else { return }
    avatarUri = next
    chatListView.setAvatarUri(next)
    updateAvatarViews()
  }

  func setAvatarGradientColors(startLight: String?, endLight: String?, startDark: String?, endDark: String?) {
    avatarGradientStartLight = startLight
    avatarGradientEndLight = endLight
    avatarGradientStartDark = startDark
    avatarGradientEndDark = endDark
    updateAvatarViews()
  }

  func setIsOnline(_ value: Bool) {
    surfacePresenceOnline = value
    if enginePeerUserId.isEmpty {
      isOnline = value
      if value {
        engineLastSeenTimestampMs = nil
      }
      applyTheme()
      updateHeaderTexts()
      updateProfileTexts()
      return
    } else {
      guard !defersEngineStateRefreshes else {
        updateHeaderTexts()
        updateProfileTexts()
        return
      }
      scheduleEngineStateRefresh(force: true, reason: "setIsOnline")
      return
    }
  }

  func setIsChatMuted(_ value: Bool) {
    if isChatMuted == value { return }
    isChatMuted = value
    updateProfileTexts()
  }

  func setStandaloneProfileMode(_ value: Bool) {
    if standaloneProfileMode == value { return }
    standaloneProfileMode = value
    refreshAgentCardVisibility()
    updateChatModeHeaderControls()
    if value {
      syncProfileHierarchyForMode()
      chatListView.setInputBarEnabled(false)
      chatListView.setNativeSendEnabled(false)
      currentPage = .profile
      pendingNativePageTarget = nil
      pendingNativePageLockUntil = 0.0
      applyPageState(animated: false, emitEvent: false)
    } else {
      chatListView.setInputBarEnabled(true)
      chatListView.setNativeSendEnabled(true)
      currentPage = .chat
      pendingNativePageTarget = nil
      pendingNativePageLockUntil = 0.0
      applyPageState(animated: false, emitEvent: false)
      syncProfileHierarchyForMode()
    }
  }

  func setPage(_ value: String, animated: Bool) {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized == "profile" {
      if currentPage != .profile {
        currentPage = .profile
        applyPageState(animated: animated, emitEvent: false)
      }
      return
    }
    if normalized == "agent" {
      if !standaloneProfileMode {
        return
      }
      onNativeEvent(["type": "headerAgentPressed"])
      return
    }
    if standaloneProfileMode {
      onNativeEvent(["type": "headerBack"])
      return
    }
    var nextPage: ChatMainPage = {
      switch normalized {
      default:
        return .chat
      }
    }()
    if nextPage == .agent && !isGroupOrChannel {
      nextPage = .profile
    }

    let now = CACurrentMediaTime()
    if let pendingTarget = pendingNativePageTarget, now < pendingNativePageLockUntil,
      nextPage != pendingTarget
    {
      return
    }

    if let pendingTarget = pendingNativePageTarget, nextPage == pendingTarget {
      pendingNativePageTarget = nil
      pendingNativePageLockUntil = 0.0
    }

    guard nextPage != currentPage else { return }
    currentPage = nextPage
    applyPageState(animated: animated, emitEvent: true)
  }

  // MARK: - View wiring

  private func configureView() {
    backgroundColor = .clear

    // Behind every page. The chat page deliberately extends up under the header, so the
    // wallpaper has to cover more than the list's own box — which is the other reason it
    // belongs here and not inside the list.
    insertSubview(wallpaperView, at: 0)
    // Cells sample this raster for the frosted backdrop behind bubbles; when it changes
    // (theme switch, resize) the visible ones have to rebind.
    wallpaperView.onSnapshotChanged = { [weak self] in
      guard let self else { return }
      self.chatListView.wallpaperSnapshotDidChange()
    }

    addSubview(pagesHost)
    pagesHost.clipsToBounds = false

    pagesHost.addSubview(chatPage)
    chatPage.addSubview(chatListView)
    // Read-only: the list borrows the raster for bubble backdrops and for the reopen
    // cover's base layer. It owns no wallpaper of its own.
    chatListView.wallpaperSource = wallpaperView
    chatPage.addSubview(pinnedBannerView)
    pinnedBannerView.isHidden = true
    pinnedBannerView.alpha = 0.0
    pinnedBannerView.addTarget(
      self, action: #selector(handlePinnedBannerPressed), for: .touchUpInside)

    chatPage.addSubview(inboxBannerView)
    inboxBannerView.isHidden = true
    inboxBannerView.alpha = 0.0
    inboxBannerView.addTarget(
      self, action: #selector(handleInboxBannerPressed), for: .touchUpInside)
    chatListView.onEventInboxChanged = { [weak self] count, latestPreview in
      self?.updateInboxBanner(count: count, latestPreview: latestPreview)
    }
    // The usage card is an absolute overlay owned and laid out by ChatListView. It does
    // not reserve list/header space, so synchronously relaying its visibility through the
    // whole chat hierarchy only makes the fixed header mask flash during a rows update.
    chatListView.onBridgeUsageBannerVisibilityChanged = nil

    // The DM-level agent runtime view is hosted FULL-SCREEN by the owning controller;
    // forward ChatListView's present/teardown/presence to it (no in-view nesting).
    chatListView.onHostBridgeAgentView = { [weak self] vc in
      self?.onPresentBridgeAgentSurface?(vc)
    }
    chatListView.onTearDownBridgeAgentView = { [weak self] in
      self?.onDismissBridgeAgentSurface?()
    }
    chatListView.hostedBridgeAgentProvider = { [weak self] in
      self?.hostedBridgeAgentProviderProvider?()
    }
    chatListView.hostedBridgeAgentSurfaceMode = { [weak self] in
      self?.hostedBridgeAgentSurfaceModeProvider?()
    }

    pagesHost.addSubview(profilePage)
    profilePage.addSubview(profileScrollView)
    profileScrollView.addSubview(profileContentView)
    profilePage.addSubview(profileMembersNode)
    profilePage.isHidden = true
    profilePage.alpha = 0
    // Same implicit-animation trap as rootWallpaperLayer above.
    for layer in [
      profileWallpaperLayer, profileWallpaperPatternLayer, profileWallpaperPatternMaskLayer,
    ] as [CALayer] {
      layer.actions = [
        "position": NSNull(), "bounds": NSNull(), "frame": NSNull(),
        "contents": NSNull(), "opacity": NSNull(), "hidden": NSNull(),
        "colors": NSNull(), "locations": NSNull(),
      ]
    }
    profileWallpaperPatternLayer.mask = profileWallpaperPatternMaskLayer
    profileWallpaperPatternMaskLayer.contentsGravity = .resizeAspectFill
    profileWallpaperPatternMaskLayer.contentsScale = UIScreen.main.scale
    profilePage.layer.insertSublayer(profileWallpaperLayer, at: 0)
    profilePage.layer.insertSublayer(profileWallpaperPatternLayer, above: profileWallpaperLayer)

    pagesHost.addSubview(agentPage)
    agentPage.addSubview(agentScrollView)
    agentScrollView.addSubview(agentContentView)
    agentContentView.addSubview(agentPromptNode)
    agentPage.isHidden = true
    agentPage.alpha = 0.0
    agentScrollView.showsVerticalScrollIndicator = false
    agentScrollView.alwaysBounceVertical = true
    if #available(iOS 11.0, *) {
      agentScrollView.contentInsetAdjustmentBehavior = .never
    }
    agentScrollView.contentInset = .zero
    agentScrollView.scrollIndicatorInsets = .zero
    agentPromptNode.delegate = self
    profileMembersNode.setMembers([])
    profileMembersNode.onBackTap = { [weak self] in
      self?.setProfileMembersVisible(false, animated: true)
    }

    addSubview(profileHeaderContainer)
    profileHeaderContainer.clipsToBounds = false
    profileHeaderMaskView.isUserInteractionEnabled = false
    profileHeaderContainer.addSubview(profileHeaderMaskView)
    profileHeaderMaskView.addSubview(profileHeaderBlurView)
    profileHeaderBlurView.contentView.addSubview(profileHeaderOverlayView)
    profileHeaderMaskGradientLayer.colors = [
      UIColor.black.withAlphaComponent(0.95).cgColor,
      UIColor.black.withAlphaComponent(0.72).cgColor,
      UIColor.clear.cgColor,
    ]
    profileHeaderMaskGradientLayer.locations = [0.0, 0.58, 1.0]
    profileHeaderMaskView.layer.mask = profileHeaderMaskGradientLayer
    profileHeaderContainer.addSubview(profileHeaderContentView)
    profileHeaderContainer.layer.zPosition = 60.0
    profileHeaderContainer.alpha = 0.0
    profileHeaderContainer.isHidden = true

    profileHeaderContentView.addSubview(profileHeaderStack)

    addSubview(headerContainer)
    headerContainer.clipsToBounds = false
    headerMaskView.isUserInteractionEnabled = false
    headerContainer.addSubview(headerMaskView)
    // Blur stack underneath, pure tint sibling on top (not inside contentView —
    // materials inside contentView still read gray/brown over wallpaper).
    headerMaskView.addSubview(headerMaskBlurView)
    headerMaskView.addSubview(headerMaskBlurBoostView)
    headerMaskView.addSubview(headerMaskOverlayView)
    // Custom soft mask (replaces system topEdgeEffect): multi-stop alpha so the
    // blur+tint plate feathers into the transcript — no hard rectangular cutoff.
    // Keep the top band denser so dark black actually reads, then soft fade.
    headerMaskGradientLayer.colors = [
      UIColor.black.withAlphaComponent(1.0).cgColor,
      UIColor.black.withAlphaComponent(0.96).cgColor,
      UIColor.black.withAlphaComponent(0.72).cgColor,
      UIColor.black.withAlphaComponent(0.32).cgColor,
      UIColor.black.withAlphaComponent(0.08).cgColor,
      UIColor.clear.cgColor,
    ]
    headerMaskGradientLayer.locations = [0.0, 0.22, 0.45, 0.68, 0.86, 1.0]
    headerMaskGradientLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
    headerMaskGradientLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
    headerMaskView.layer.mask = headerMaskGradientLayer
    headerContainer.addSubview(headerContentView)
    headerContainer.layer.zPosition = 50.0

    headerContentView.addSubview(backGlassView)
    headerContentView.addSubview(titleGlassView)
    headerContentView.addSubview(avatarGlassView)
    headerContentView.addSubview(menuGlassView)
    headerContentView.addSubview(savedSearchCancelGlassView)
    backGlassView.contentView.addSubview(backButton)
    titleGlassView.contentView.addSubview(titleButton)
    avatarGlassView.contentView.addSubview(avatarButton)
    menuGlassView.contentView.addSubview(menuButton)
    menuGlassView.contentView.addSubview(savedSearchField)
    savedSearchCancelGlassView.contentView.addSubview(savedSearchCancelButton)
    headerContentView.addSubview(rightActionsGlassView)
    
    rightActionsGlassView.contentView.addSubview(rightActionsStack)
    rightActionsStack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      rightActionsStack.leadingAnchor.constraint(equalTo: rightActionsGlassView.contentView.leadingAnchor),
      rightActionsStack.trailingAnchor.constraint(equalTo: rightActionsGlassView.contentView.trailingAnchor),
      rightActionsStack.topAnchor.constraint(equalTo: rightActionsGlassView.contentView.topAnchor),
      rightActionsStack.bottomAnchor.constraint(equalTo: rightActionsGlassView.contentView.bottomAnchor)
    ])

    profileHeaderContentView.addSubview(profileBackGlassView)
    profileHeaderContentView.addSubview(profileMenuGlassView)
    profileBackGlassView.contentView.addSubview(profileBackButton)
    profileMenuGlassView.contentView.addSubview(profileMenuButton)

    [backButton, titleButton, avatarButton, menuButton, profileBackButton, profileMenuButton, callButton, videoCallButton, historyButton, newChatButton, selectionDoneButton].forEach
    { button in
      button.backgroundColor = .clear
      button.contentHorizontalAlignment = .center
      button.contentVerticalAlignment = .center
      button.clipsToBounds = true
    }

    titleButton.addSubview(chatHeaderStack)

    [
      backGlassView, titleGlassView, avatarGlassView, menuGlassView, profileBackGlassView,
      savedSearchCancelGlassView, profileMenuGlassView, rightActionsGlassView,
    ].forEach { glassView in
      glassView.clipsToBounds = true
      glassView.layer.cornerCurve = .continuous
      glassView.contentView.backgroundColor = .clear
    }

    backButton.setImage(UIImage(systemName: "chevron.backward"), for: .normal)
    backButton.semanticContentAttribute = .forceLeftToRight
    backButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
    backButton.titleLabel?.lineBreakMode = .byClipping
    updateBackButtonContent()
    backButton.addTarget(self, action: #selector(handleBackPressed), for: .touchUpInside)
    titleButton.addTarget(self, action: #selector(handleTitlePressed), for: .touchUpInside)
    menuButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
    menuButton.addTarget(self, action: #selector(handleMenuPressed), for: .touchUpInside)
    menuButton.isHidden = true
    menuGlassView.isHidden = true
    savedSearchCancelGlassView.isHidden = true
    rightActionsGlassView.isHidden = true

    rightActionsStack.axis = .horizontal
    rightActionsStack.alignment = .center
    rightActionsStack.distribution = .fillEqually
    rightActionsStack.spacing = 0

    rightActionsStack.addArrangedSubview(callButton)
    rightActionsStack.addArrangedSubview(videoCallButton)
    rightActionsStack.addArrangedSubview(historyButton)
    rightActionsStack.addArrangedSubview(newChatButton)
    rightActionsStack.addArrangedSubview(selectionDoneButton)

    [callButton, videoCallButton, historyButton, newChatButton, selectionDoneButton].forEach { button in
      button.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        button.heightAnchor.constraint(equalToConstant: 44.0)
      ])
    }

    let actionSymbolConfig = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
    callButton.setImage(UIImage(systemName: "phone"), for: .normal)
    callButton.setPreferredSymbolConfiguration(actionSymbolConfig, forImageIn: .normal)
    videoCallButton.setImage(UIImage(systemName: "video"), for: .normal)
    videoCallButton.setPreferredSymbolConfiguration(actionSymbolConfig, forImageIn: .normal)
    historyButton.setImage(createHistoryIcon(), for: .normal)
    newChatButton.setImage(UIImage(systemName: "plus"), for: .normal)
    newChatButton.setPreferredSymbolConfiguration(actionSymbolConfig, forImageIn: .normal)
    selectionDoneButton.setImage(UIImage(systemName: "checkmark"), for: .normal)
    selectionDoneButton.setPreferredSymbolConfiguration(
      UIImage.SymbolConfiguration(pointSize: 15, weight: .bold), forImageIn: .normal)
    selectionDoneButton.accessibilityIdentifier = "chat.selection.done"
    selectionDoneButton.accessibilityLabel = "Done"
    selectionDoneButton.isHidden = true
    selectionDoneButton.tintColor = .white
    selectionDoneButton.backgroundColor = UIColor.systemBlue
    selectionDoneButton.clipsToBounds = true
    selectionDoneButton.layer.cornerCurve = .continuous
    historyButton.accessibilityIdentifier = "chat.history"
    historyButton.accessibilityLabel = "History"
    newChatButton.accessibilityIdentifier = "chat.new"
    newChatButton.accessibilityLabel = "New Chat"

    callButton.addTarget(self, action: #selector(handlePrimaryTrailingActionPressed), for: .touchUpInside)
    historyButton.addTarget(self, action: #selector(handleHistoryPressed), for: .touchUpInside)
    newChatButton.addTarget(self, action: #selector(handleNewChatPressed), for: .touchUpInside)
    selectionDoneButton.addTarget(self, action: #selector(handleSelectionDonePressed), for: .touchUpInside)

    // TODO: Add actual targets for call/videoCall/history/newChat.
    // historyButton.addTarget(self, action: #selector(handleHistoryPressed), for: .touchUpInside)
    // newChatButton.addTarget(self, action: #selector(handleNewChatPressed), for: .touchUpInside)

    savedSearchField.borderStyle = .none
    savedSearchField.backgroundColor = .clear
    savedSearchField.alpha = 0.0
    savedSearchField.font = UIFont.systemFont(ofSize: 15, weight: .medium)
    savedSearchField.clearButtonMode = .never
    savedSearchField.returnKeyType = .search
    savedSearchField.enablesReturnKeyAutomatically = false
    savedSearchField.autocapitalizationType = .none
    savedSearchField.autocorrectionType = .no
    savedSearchField.spellCheckingType = .no
    savedSearchField.clipsToBounds = false
    savedSearchField.delegate = self
    savedSearchField.addTarget(
      self,
      action: #selector(handleSavedSearchTextChanged),
      for: .editingChanged
    )
    savedSearchCancelButton.setTitle(nil, for: .normal)
    savedSearchCancelButton.setImage(UIImage(systemName: "xmark"), for: .normal)
    savedSearchCancelButton.setPreferredSymbolConfiguration(
      UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold),
      forImageIn: .normal
    )
    savedSearchCancelButton.accessibilityLabel = "Close search"
    savedSearchCancelButton.alpha = 0.0
    savedSearchCancelButton.addTarget(
      self,
      action: #selector(handleSavedSearchCancelPressed),
      for: .touchUpInside
    )

    profileBackButton.setImage(UIImage(systemName: "chevron.backward"), for: .normal)
    profileBackButton.addTarget(self, action: #selector(handleBackPressed), for: .touchUpInside)
    applyProfileHeaderMenuButtonStyle(profileMenuButton)
    profileMenuButton.addTarget(self, action: #selector(handleMenuPressed), for: .touchUpInside)

    avatarButton.addTarget(self, action: #selector(handleAvatarPressed), for: .touchUpInside)
    avatarButton.addSubview(avatarNode)
    // Selection title lives in the TITLE glass (same frame as username/subtitle) so
    // enter/exit is a pure alpha cross-fade — no X/Y translation of the header text.
    // Counter sits alongside the title (horizontal), not under it.
    selectionTitleLabel.text = "Select messages"
    selectionTitleLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
    selectionTitleLabel.textAlignment = .left
    selectionTitleLabel.lineBreakMode = .byTruncatingTail
    selectionCountLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
    selectionCountLabel.textAlignment = .left
    selectionCountLabel.lineBreakMode = .byClipping
    selectionCountLabel.setContentHuggingPriority(.required, for: .horizontal)
    selectionCountLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    selectionHeaderStack.axis = .horizontal
    selectionHeaderStack.alignment = .center
    selectionHeaderStack.distribution = .fill
    selectionHeaderStack.spacing = 6
    selectionHeaderStack.isUserInteractionEnabled = false
    selectionHeaderStack.alpha = 0
    selectionHeaderStack.isHidden = true
    selectionHeaderStack.addArrangedSubview(selectionTitleLabel)
    selectionHeaderStack.addArrangedSubview(selectionCountLabel)
    titleButton.addSubview(selectionHeaderStack)
    // Selection confirm lives in the trailing glass (call/video or search slot).

    let backSymbolConfig = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
    backButton.setPreferredSymbolConfiguration(backSymbolConfig, forImageIn: .normal)
    let menuSymbolConfig = UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
    menuButton.setPreferredSymbolConfiguration(menuSymbolConfig, forImageIn: .normal)
    profileBackButton.setPreferredSymbolConfiguration(backSymbolConfig, forImageIn: .normal)
    if profileMenuButton.configuration == nil {
      profileMenuButton.setPreferredSymbolConfiguration(menuSymbolConfig, forImageIn: .normal)
    }
    chatHeaderStack.axis = .vertical
    // Leading-aligned (next to avatar) — only Home principal is centered.
    chatHeaderStack.alignment = .leading
    chatHeaderStack.distribution = .fill
    chatHeaderStack.spacing = -1

    profileHeaderStack.axis = .vertical
    profileHeaderStack.alignment = .center
    profileHeaderStack.distribution = .fill
    profileHeaderStack.spacing = -1

    [chatTitleLabel, profileTitleLabel].forEach { label in
      label.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
      label.textAlignment = .left
      label.lineBreakMode = .byTruncatingTail
    }
    [chatSubtitleLabel, profileSubtitleLabel].forEach { label in
      label.font = UIFont.systemFont(ofSize: 12, weight: .medium)
      label.textAlignment = .left
      label.lineBreakMode = .byTruncatingTail
      label.isHidden = true
    }

    chatSubtitleDotView.layer.cornerRadius = 3
    chatSubtitleDotView.layer.cornerCurve = .continuous
    chatSubtitleDotView.isHidden = true
    chatSubtitleDotView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      chatSubtitleDotView.widthAnchor.constraint(equalToConstant: 6),
      chatSubtitleDotView.heightAnchor.constraint(equalToConstant: 6),
    ])
    chatSubtitleRow.axis = .horizontal
    chatSubtitleRow.alignment = .center
    chatSubtitleRow.spacing = 4
    // Order: status dot → line spinner → text (matches Home principal).
    // Spinner/dot slots stay laid out (alpha/isHidden carefully) to limit jump.
    chatConnectingSpinner.translatesAutoresizingMaskIntoConstraints = false
    chatConnectingSpinner.setContentHuggingPriority(.required, for: .horizontal)
    chatConnectingSpinner.setContentCompressionResistancePriority(.required, for: .horizontal)
    NSLayoutConstraint.activate([
      chatConnectingSpinner.widthAnchor.constraint(equalToConstant: 11),
      chatConnectingSpinner.heightAnchor.constraint(equalToConstant: 11),
    ])
    chatSubtitleRow.addArrangedSubview(chatSubtitleDotView)
    chatSubtitleRow.addArrangedSubview(chatConnectingSpinner)
    chatSubtitleRow.addArrangedSubview(chatSubtitleLabel)
    chatConnectingSpinner.alpha = 0
    chatConnectingSpinner.isHidden = true

    chatHeaderStack.addArrangedSubview(chatTitleLabel)
    chatHeaderStack.addArrangedSubview(chatSubtitleRow)
    profileHeaderStack.addArrangedSubview(profileTitleLabel)
    profileHeaderStack.addArrangedSubview(profileSubtitleLabel)
    chatHeaderStack.frame = CGRect(x: 12.0, y: 4.0, width: 160.0, height: 36.0)
    profileHeaderStack.frame = CGRect(x: 12.0, y: 4.0, width: 160.0, height: 36.0)
    profileHeaderStack.isUserInteractionEnabled = false

    profileScrollView.showsVerticalScrollIndicator = false
    profileScrollView.alwaysBounceVertical = true
    if #available(iOS 11.0, *) {
      profileScrollView.contentInsetAdjustmentBehavior = .never
    }
    profileScrollView.contentInset = .zero
    profileScrollView.scrollIndicatorInsets = .zero
    profilePage.addGestureRecognizer(profileSwipeBackGesture)

    profileContentView.addSubview(profileAvatarView)
    profileAvatarView.addSubview(profileAvatarNode)
    profileAvatarView.addSubview(profileOnlineDotView)
    profileContentView.addSubview(profileNameLabel)
    profileContentView.addSubview(profileHandleLabel)
    profileContentView.addSubview(profileBioLabel)
    profileContentView.addSubview(profileActionsStack)
    [profileMuteButton, profileSearchButton, profileAudioCallButton, profileVideoCallButton].forEach
    {
      profileActionsStack.addArrangedSubview($0)
    }
    profileContentView.addSubview(profileIdentityCard)
    profileIdentityCard.addSubview(profileUsernameRow)
    profileIdentityCard.addSubview(profileBioRow)
    profileContentView.addSubview(profileTabsCard)
    profileTabsCard.addSubview(profileTabsScrollView)
    profileTabsScrollView.addSubview(profileTabsStack)
    profileContentView.addSubview(profileTabContentContainer)
    profileTabContentContainer.addSubview(profileTabPlaceholderLabel)

    profileIdentityCard.addSubview(profileAgentRow)
    profileAgentRow.addTarget(self, action: #selector(handleAgentRowTapped), for: .touchUpInside)

    profileAvatarView.clipsToBounds = true
    profileOnlineDotView.layer.cornerCurve = .continuous

    profileNameLabel.textAlignment = .center
    profileNameLabel.font = UIFont.systemFont(ofSize: 30, weight: .bold)
    profileHandleLabel.textAlignment = .center
    profileHandleLabel.font = UIFont.systemFont(ofSize: 18, weight: .medium)
    profileBioLabel.textAlignment = .center
    profileBioLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
    profileBioLabel.numberOfLines = 0

    profileActionsStack.axis = .horizontal
    profileActionsStack.alignment = .fill
    profileActionsStack.distribution = .fillEqually
    profileActionsStack.spacing = 8

    profileMuteButton.configure(title: "Mute", symbol: "bell.slash")
    profileSearchButton.configure(title: "Search", symbol: "magnifyingglass")
    profileAudioCallButton.configure(title: "Call", symbol: "phone")
    profileVideoCallButton.configure(title: "Video", symbol: "video")
    profileMuteButton.addTarget(
      self, action: #selector(handleProfileMutePressed), for: .touchUpInside)
    profileSearchButton.addTarget(
      self, action: #selector(handleProfileSearchPressed), for: .touchUpInside)
    profileAudioCallButton.addTarget(
      self, action: #selector(handleProfileAudioCallPressed), for: .touchUpInside)
    profileVideoCallButton.addTarget(
      self, action: #selector(handleProfileVideoCallPressed), for: .touchUpInside)

    profileIdentityCard.clipsToBounds = true
    profileIdentityCard.layer.cornerCurve = .continuous

    profileUsernameRow.addTarget(
      self, action: #selector(handleProfileUsernamePressed), for: .touchUpInside)
    profileBioRow.isEnabled = false

    profileTabsCard.clipsToBounds = true
    profileTabsCard.layer.cornerCurve = .continuous
    profileTabsScrollView.showsHorizontalScrollIndicator = false
    profileTabsScrollView.alwaysBounceHorizontal = true

    profileTabPlaceholderLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
    profileTabPlaceholderLabel.numberOfLines = 0
    profileTabPlaceholderLabel.textAlignment = .left
    profileTabPlaceholderLabel.text =
      "Loading shared media and files from native encrypted cache..."

    profileAgentRow.isHidden = true

    rebuildProfileTabs()
    profileHierarchyAttached = true
    refreshHeaderGlass()
    updateAvatarViews()
    syncProfileHierarchyForMode()
    updateChatModeHeaderControls()

    // Top scroll-edge API is disabled — header uses custom soft blur/tint masking
    // (see applyHeaderChromeSystemStyle / layoutChrome). Bottom edge stays system soft.
  }

  private func ensureProfileHierarchyAttached() {
    guard !profileHierarchyAttached else { return }

    if profilePage.superview !== self {
      profilePage.removeFromSuperview()
      insertSubview(profilePage, belowSubview: headerContainer)
    }
    if agentPage.superview !== self {
      agentPage.removeFromSuperview()
      insertSubview(agentPage, belowSubview: headerContainer)
    }
    if profileHeaderContainer.superview == nil {
      addSubview(profileHeaderContainer)
    }
    bringSubviewToFront(profileHeaderContainer)
    profileHierarchyAttached = true
    setNeedsLayout()
  }

  private func detachProfileHierarchyIfNeeded() {
    guard profileHierarchyAttached else { return }
    profileHeaderContainer.removeFromSuperview()
    profilePage.removeFromSuperview()
    agentPage.removeFromSuperview()
    profileHierarchyAttached = false
  }

  private func syncProfileHierarchyForMode() {
    if standaloneProfileMode {
      ensureProfileHierarchyAttached()
    } else {
      detachProfileHierarchyIfNeeded()
    }
  }

  private var selectionModeActive = false
  private var selectionCount = 0

  private func syncListDispatchers() {
    chatListView.onNativeEvent = NativeEventDispatcher { [weak self] event in
      self?.handleInternalListEvent(event)
      self?.onNativeEvent(event)
    }
    chatListView.onViewportChanged = onViewportChanged
    chatListView.onAgentRunStateChanged = { [weak self] in
      self?.updateHeaderTexts()
    }
  }

  private func handleInternalListEvent(_ event: [String: Any]) {
    if let type = event["type"] as? String, type == "messageSelectionChanged" {
      if let active = event["active"] as? Bool, let count = event["selectedCount"] as? Int {
        let modeChanged = active != self.selectionModeActive
        let countChanged = count != self.selectionCount
        self.selectionModeActive = active
        self.selectionCount = count
        if modeChanged {
          self.updateHeaderForSelectionState(animated: true)
        } else if countChanged && active {
          self.updateSelectionTitleContent(count: count, animated: true)
        }
      }
    } else if let type = event["type"] as? String, type == "messageSelectionAction" {
      // Do not hard-exit selection here — share sheet may still be open; the
      // send path clears selection after dismiss to avoid a mid-sheet flicker.
    }
  }

  /// Cancels in-flight selection header morph (enter/exit).
  private var selectionHeaderAnimator: UIViewPropertyAnimator?

  /// Direct (1:1) chat — not group/channel/saved. Selection left becomes Clear Chat.
  private var selectionShowsClearChat: Bool {
    !isGroupOrChannel && headerMode != .savedMessages
  }

  /// Zero selected → "Select messages"; N selected → "Selected" + count (horizontal).
  private func updateSelectionTitleContent(count: Int, animated: Bool) {
    let empty = count <= 0
    let nextTitle = empty ? "Select messages" : "Selected"
    let nextCount = empty ? "" : "\(count)"
    let showCount = !empty

    let apply = {
      self.selectionTitleLabel.text = nextTitle
      self.selectionCountLabel.text = nextCount
      self.selectionCountLabel.isHidden = !showCount
      self.selectionCountLabel.alpha = showCount ? 1 : 0
      self.setNeedsLayout()
      self.layoutIfNeeded()
    }

    if animated, window != nil {
      // Cross-dissolve title + monospaced digit swap (smooth counter feel).
      UIView.transition(
        with: selectionHeaderStack,
        duration: 0.22,
        options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction]
      ) {
        apply()
      }
    } else {
      apply()
    }
  }

  /// Apply selection chrome *flags* synchronously so layout can measure trailing
  /// checkmark / Clear Chat before the system bar animation runs.
  private func applySelectionChromeFlags(isActive: Bool, count: Int) {
    if isActive {
      if selectionShowsClearChat {
        // Direct chat: left morphs to Clear Chat (functional — engine + server).
        backButton.setTitle(nil, for: .normal)
        backButton.setImage(UIImage(systemName: "trash"), for: .normal)
        backButton.accessibilityLabel = "Clear chat"
        backButton.tintColor = .systemRed
      } else {
        backButton.setTitle(nil, for: .normal)
        backButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        backButton.accessibilityLabel = "Cancel selection"
        backButton.tintColor = nil  // restore from applyHeaderChromeColors
      }
      updateSelectionTitleContent(count: count, animated: false)
      selectionHeaderStack.isHidden = false
      avatarButton.isUserInteractionEnabled = false
      callButton.isHidden = true
      videoCallButton.isHidden = true
      historyButton.isHidden = true
      newChatButton.isHidden = true
      // Saved Messages: search glass becomes the blue checkmark.
      // Everyone else: trailing actions glass holds the checkmark.
      if headerMode == .savedMessages {
        menuButton.isHidden = true
        selectionDoneButton.isHidden = false
        rightActionsGlassView.isHidden = false
        menuGlassView.isHidden = true
      } else {
        selectionDoneButton.isHidden = false
        rightActionsGlassView.isHidden = false
      }
      avatarGlassView.isHidden = false
      applySelectionDoneBlueTint()
    } else {
      backButton.setTitle(nil, for: .normal)
      backButton.setImage(UIImage(systemName: "chevron.backward"), for: .normal)
      backButton.accessibilityLabel = "Back"
      backButton.tintColor = nil
      selectionHeaderStack.isHidden = true
      selectionCountLabel.isHidden = true
      avatarButton.isUserInteractionEnabled = headerMode != .savedMessages
      selectionDoneButton.isHidden = true
      updateHeaderTexts()
      updateChatModeHeaderControls()
    }
  }

  private func applySelectionDoneBlueTint() {
    selectionDoneButton.tintColor = .white
    selectionDoneButton.backgroundColor = UIColor.systemBlue
    selectionDoneButton.clipsToBounds = true
    let side = min(
      max(selectionDoneButton.bounds.width, 44.0),
      max(selectionDoneButton.bounds.height, 44.0)
    )
    selectionDoneButton.layer.cornerRadius = side / 2.0
    selectionDoneButton.layer.cornerCurve = .continuous
  }

  private func updateHeaderForSelectionState(animated: Bool = true) {
    let isActive = selectionModeActive
    let count = selectionCount

    selectionHeaderAnimator?.stopAnimation(true)
    selectionHeaderAnimator = nil

    // Flags first so layout measures Done / Clear before the fade runs.
    applySelectionChromeFlags(isActive: isActive, count: count)

    // CRITICAL: keep titleGlassView frame + avatarGlassView frame stable.
    // Only alpha-crossfade username/subtitle ↔ selection title (no X/Y shift).
    let applyAnimatedChrome = {
      self.selectionHeaderStack.alpha = isActive ? 1 : 0
      self.chatHeaderStack.alpha = isActive ? 0 : 1
      // Avatar fades in place — no translate / scale.
      self.avatarNode.alpha = isActive ? 0 : 1
      self.avatarGlassView.alpha = 1
      self.avatarGlassView.transform = .identity
      self.titleGlassView.alpha = 1
      self.titleGlassView.transform = .identity
      self.chatHeaderStack.transform = .identity
      self.selectionHeaderStack.transform = .identity
      self.setNeedsLayout()
      self.layoutIfNeeded()
    }

    if animated {
      let duration = TimeInterval(UINavigationController.hideShowBarDuration)
      let animator = UIViewPropertyAnimator(duration: max(duration, 0.32), curve: .easeInOut) {
        applyAnimatedChrome()
      }
      animator.addCompletion { [weak self] _ in
        self?.selectionHeaderAnimator = nil
      }
      selectionHeaderAnimator = animator
      animator.startAnimation()
    } else {
      applyAnimatedChrome()
    }
  }

  @objc private func handleSelectionDonePressed() {
    chatListView.clearMessageSelection(animated: true)
  }

  @objc private func handleSelectionClearChatPressed() {
    onNativeEvent(["type": "headerMenuAction", "action": "clearChat"])
  }

  private func updateChatModeHeaderControls() {
    if externalNavigationHeaderEnabled && !savedSearchExpanded {
      headerContainer.isHidden = true
      headerContainer.isUserInteractionEnabled = false
      backGlassView.isHidden = true
      titleGlassView.isHidden = true
      avatarGlassView.isHidden = true
      menuGlassView.isHidden = true
      savedSearchCancelGlassView.isHidden = true
      rightActionsGlassView.isHidden = true
      titleButton.isUserInteractionEnabled = false
      titleButton.showsMenuAsPrimaryAction = false
      titleButton.menu = nil
      return
    }
    headerContainer.isHidden = false
    let usesSavedMessagesHeader = headerMode == .savedMessages
    let searchActive = savedSearchExpanded && currentPage == .chat
    if previewHeaderCompactLeading && !searchActive {
      headerContainer.isUserInteractionEnabled = false
      backGlassView.isHidden = true
      avatarButton.isHidden = false
      avatarGlassView.isHidden = false
      menuGlassView.isHidden = true
      savedSearchCancelGlassView.isHidden = true
      rightActionsGlassView.isHidden = true
      titleGlassView.isHidden = false
      titleButton.isUserInteractionEnabled = false
      titleButton.showsMenuAsPrimaryAction = false
      titleButton.menu = nil
      applyHeaderSearchPresentation()
      return
    }
    if previewHeaderCenterOnly && !searchActive {
      headerContainer.isUserInteractionEnabled = false
      backGlassView.isHidden = true
      avatarGlassView.isHidden = true
      menuGlassView.isHidden = true
      savedSearchCancelGlassView.isHidden = true
      rightActionsGlassView.isHidden = true
      titleGlassView.isHidden = false
      titleButton.isUserInteractionEnabled = false
      titleButton.showsMenuAsPrimaryAction = false
      titleButton.menu = nil
      applyHeaderSearchPresentation()
      return
    }
    headerContainer.isUserInteractionEnabled = true
    avatarButton.isHidden = searchActive
    avatarGlassView.isHidden = searchActive
    avatarButton.isUserInteractionEnabled =
      !usesSavedMessagesHeader && !searchActive && !selectionModeActive
    // The title is a plain tappable name (opens the profile) for every chat now — no
    // per-chat dropdown menu, agent or not.
    titleButton.isUserInteractionEnabled =
      !usesSavedMessagesHeader && !searchActive && !selectionModeActive
    titleButton.showsMenuAsPrimaryAction = false
    titleButton.menu = nil

    let isAgent = !bridgeProvider.isEmpty
    let isOwnedAgent = ownedStandaloneAgentMode
    let isAgentGroup = isGroupOrChannel && chatListView.groupHasBridgeAgentsPublic
    // Agent DMs, multi-agent groups, and the built-in Vibe AI surface: history /
    // new-chat instead of call actions. Plain human groups keep call/video.
    let showAgentHistory =
      (isAgent || isAgentGroup || builtInAgentChatMode) && !usesSavedMessagesHeader && !searchActive
    if selectionModeActive {
      // Selection owns trailing: blue checkmark. Saved Messages search glass hides.
      callButton.isHidden = true
      videoCallButton.isHidden = true
      historyButton.isHidden = true
      newChatButton.isHidden = true
      selectionDoneButton.isHidden = false
      rightActionsGlassView.isHidden = false
      menuButton.isHidden = true
      menuGlassView.isHidden = true
      savedSearchCancelGlassView.isHidden = true
      applySelectionDoneBlueTint()
    } else {
      selectionDoneButton.isHidden = true
      callButton.isHidden =
        (isAgent || isAgentGroup || builtInAgentChatMode || usesSavedMessagesHeader || searchActive)
          && !isOwnedAgent
      videoCallButton.isHidden =
        isOwnedAgent || isAgent || isAgentGroup || builtInAgentChatMode || usesSavedMessagesHeader
          || searchActive
      historyButton.isHidden = isOwnedAgent || !showAgentHistory
      // Agent DMs always have a transport chat id. Gating this control on an empty
      // engineChatId made New Chat unreachable in normal Grok/Claude/Codex sessions.
      // Groups with agents also get New Chat so a report-scoped view can be cleared.
      // Built-in Vibe AI uses the same chrome for conversation History / New Chat.
      newChatButton.isHidden = isOwnedAgent || !showAgentHistory
      callButton.setImage(
        isOwnedAgent ? createAgentSettingsMenuIcon() : UIImage(systemName: "phone"),
        for: .normal
      )
      callButton.accessibilityLabel = isOwnedAgent ? "Agent settings" : "Audio call"
      rightActionsGlassView.isHidden = usesSavedMessagesHeader || searchActive
      menuButton.isHidden = !(usesSavedMessagesHeader || searchActive)
      menuGlassView.isHidden = !(usesSavedMessagesHeader || searchActive)
      savedSearchCancelGlassView.isHidden = !searchActive
      menuButton.setImage(
        UIImage(
          systemName: searchActive
            ? "magnifyingglass"
            : (usesSavedMessagesHeader ? "magnifyingglass" : "ellipsis"),
          withConfiguration: UIImage.SymbolConfiguration(
            pointSize: searchActive || usesSavedMessagesHeader ? 16.0 : 17.0,
            weight: searchActive || usesSavedMessagesHeader ? .medium : .semibold
          )
        ),
        for: .normal
      )
    }
    applyHeaderSearchPresentation()
  }

  private func startObservingChatEngine() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleChatEngineDidChange(_:)),
      name: ChatEngine.didChangeNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppearanceDraftDidChange),
      name: ChatAppearanceDraftStore.didChangeNotification,
      object: nil
    )
  }

  @objc private func handleAppearanceDraftDidChange() {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.handleAppearanceDraftDidChange()
      }
      return
    }
    ChatListAppearance.invalidateBootstrap()
    reapplyNativeThemeForCurrentInterfaceStyle()
  }

  @objc private func handleChatEngineDidChange(_ notification: Notification) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.handleChatEngineDidChange(notification)
      }
      return
    }
    guard !engineStateUpdatesSuspended else { return }
    let changeReason = (notification.userInfo?["reason"] as? String) ?? "(unknown)"
    let changedChatId = (notification.userInfo?["chatId"] as? String) ?? ""
    if changeReason == "surfaceBindingChanged" {
      return
    }
    if changeReason == "chatPinnedUpdated" || changeReason == "chatRowsReloaded"
      || changeReason == "chatMessageInserted" || changeReason == "chatMessageChanged"
    {
      VibeDebugLog.log(
        "[ChatMainView][Pin] engineDidChange reason=%@ changedChatId=%@ engineChatId=%@",
        changeReason,
        changedChatId,
        engineChatId
      )
    }
    // Live agent status fast-path: the agentProgress notification itself carries the
    // label/tool/isActive, so update the header subtitle directly — no engine round-trip,
    // and it works even while engine-state refreshes are deferred (which previously left
    // a live run's header stuck on "Start session" until the deferred snapshot ran).
    if changeReason == "agentProgress", !engineChatId.isEmpty,
      changedChatId.trimmingCharacters(in: .whitespacesAndNewlines) == engineChatId
    {
      let isActive = (notification.userInfo?["isActive"] as? Bool) ?? false
      let nextLabel =
        isActive
        ? Self.friendlyAgentProgressLabel(
          rawLabel: notification.userInfo?["label"] as? String,
          tool: notification.userInfo?["tool"] as? String)
        : nil
      if nextLabel != agentProgressSubtitle {
        agentProgressSubtitle = nextLabel
        updateHeaderTexts()
      }
    }
    guard !defersEngineStateRefreshes else {
      updateHeaderTexts()
      updateProfileTexts()
      return
    }
    guard !engineChatId.isEmpty else { return }
    if let changedChatIdRaw = notification.userInfo?["chatId"] as? String,
      !changedChatIdRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      changedChatIdRaw.trimmingCharacters(in: .whitespacesAndNewlines) != engineChatId
    {
      return
    }
    scheduleEngineStateRefresh(force: false, reason: "engineDidChange:\(changeReason)")
  }

  private func scheduleEngineStateRefresh(force: Bool = false, reason: String) {
    guard !engineStateUpdatesSuspended else { return }
    guard !defersEngineStateRefreshes else {
      updateHeaderTexts()
      updateProfileTexts()
      return
    }

    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    let peerUserId = enginePeerUserId
    let surfaceOnline = surfacePresenceOnline
    let groupMode = isGroupOrChannel
    let isSavedMessagesChat = chatId == "saved_messages"
    let bridgeProviderSnapshot = bridgeProvider
    engineStateRefreshGeneration &+= 1
    let generation = engineStateRefreshGeneration
    engineStateRefreshWorkItem?.cancel()

    let workItem = DispatchWorkItem { [chatId, peerUserId, surfaceOnline, groupMode, isSavedMessagesChat, bridgeProviderSnapshot, generation, force, reason] in
      let startedAt = CFAbsoluteTimeGetCurrent()
      let engine = ChatEngine.shared
      let engineOnline =
        peerUserId.isEmpty || isSavedMessagesChat ? false : engine.isUserOnline(userId: peerUserId)
      let nextOnline = engineOnline || (surfaceOnline == true)
      let nextLastSeen =
        peerUserId.isEmpty || nextOnline || isSavedMessagesChat
        ? nil
        : engine.lastSeenTimestampMs(userId: peerUserId)
      let directTyping =
        !groupMode && !chatId.isEmpty && !isSavedMessagesChat
        ? engine.isTyping(["chatId": chatId])
        : false
      let groupTyping =
        groupMode && !chatId.isEmpty && !isSavedMessagesChat
        ? engine.typingUserIds(chatId: chatId)
        : []
      let agentPayload = !chatId.isEmpty && !isSavedMessagesChat ? engine.agentProgress(chatId: chatId) : nil
      let hasOutstandingApproval =
        !chatId.isEmpty && !isSavedMessagesChat && !bridgeProviderSnapshot.isEmpty
        ? engine.hasOutstandingAgentBridgeAsk(chatId: chatId, provider: bridgeProviderSnapshot)
        : false
      let sessionTopic =
        !chatId.isEmpty && !isSavedMessagesChat && !bridgeProviderSnapshot.isEmpty
        ? engine.agentBridgeSessionTopic(chatId: chatId)
        : nil
      let pinnedPayload: [String: Any]?
      let pinnedContent: ChatMainPinnedBannerContent?
      if isSavedMessagesChat {
        pinnedPayload = ["chatId": chatId, "loading": false, "data": []]
        pinnedContent = nil
      } else if !chatId.isEmpty {
        let payload = engine.getPinnedMessages(["chatId": chatId])
        pinnedPayload = payload
        let topPin = ((payload["data"] as? [[String: Any]]) ?? []).first
        pinnedContent = Self.resolvePinnedBannerContent(chatId: chatId, pin: topPin)
      } else {
        pinnedPayload = nil
        pinnedContent = nil
      }
      let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)

      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        guard self.engineStateRefreshGeneration == generation else { return }
        guard self.engineChatId == chatId, self.enginePeerUserId == peerUserId else { return }
        guard !self.engineStateUpdatesSuspended else { return }
        guard !self.defersEngineStateRefreshes else { return }
        self.applyEngineStateSnapshot(
          chatId: chatId,
          nextOnline: nextOnline,
          nextLastSeen: nextLastSeen,
          directTyping: directTyping,
          groupTyping: groupTyping,
          agentPayload: agentPayload,
          hasOutstandingApproval: hasOutstandingApproval,
          sessionTopic: sessionTopic,
          pinnedPayload: pinnedPayload,
          pinnedContent: pinnedContent,
          force: force,
          reason: reason,
          durationMs: durationMs
        )
      }
    }

    engineStateRefreshWorkItem = workItem
    let delay: DispatchTimeInterval = force ? .milliseconds(0) : .milliseconds(80)
    engineStateRefreshQueue.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  private func applyEngineStateSnapshot(
    chatId: String,
    nextOnline: Bool,
    nextLastSeen: Int64?,
    directTyping: Bool,
    groupTyping: [String],
    agentPayload: [String: Any]?,
    hasOutstandingApproval: Bool,
    sessionTopic: String?,
    pinnedPayload: [String: Any]?,
    pinnedContent: ChatMainPinnedBannerContent?,
    force: Bool,
    reason: String,
    durationMs: Int
  ) {
    AppUIStallWatchdog.shared.updateContext(
      "ChatMainView applyEngineStateSnapshot chatId=\(chatId) reason=\(reason)"
    )
    var shouldUpdateHeader = false
    var shouldUpdateProfile = false

    if force || nextOnline != isOnline || nextLastSeen != engineLastSeenTimestampMs {
      isOnline = nextOnline
      engineLastSeenTimestampMs = nextLastSeen
      applyPresenceTheme()
      shouldUpdateHeader = true
      shouldUpdateProfile = true
    }

    if isGroupOrChannel {
      if updateGroupTypingDisplay(groupTyping, force: force) || directPeerTypingActive {
        directPeerTypingActive = false
        shouldUpdateHeader = true
        shouldUpdateProfile = true
      }
    } else if force || !groupTypingUserIds.isEmpty || directTyping != directPeerTypingActive {
      clearGroupTypingDisplay()
      directPeerTypingActive = directTyping
      shouldUpdateHeader = true
      shouldUpdateProfile = true
    }

    let isAgentActive = (agentPayload?["isActive"] as? Bool) ?? false
    let rawAgentLabel = agentPayload?["label"] as? String
    let rawAgentTool = agentPayload?["tool"] as? String
    let nextAgentLabel =
      isAgentActive ? Self.friendlyAgentProgressLabel(rawLabel: rawAgentLabel, tool: rawAgentTool) : nil
    if force || nextAgentLabel != agentProgressSubtitle {
      agentProgressSubtitle = nextAgentLabel
      shouldUpdateHeader = true
    }

    if force || hasOutstandingApproval != agentAwaitingApproval {
      agentAwaitingApproval = hasOutstandingApproval
      shouldUpdateHeader = true
    }

    if force || sessionTopic != bridgeSessionTopic {
      bridgeSessionTopic = sessionTopic
      shouldUpdateHeader = true
    }

    if shouldUpdateHeader {
      updateHeaderTexts()
    }
    if shouldUpdateProfile {
      updateProfileTexts()
    }

    if let pinnedPayload {
      applyPinnedBannerPayload(
        chatId: chatId,
        payload: pinnedPayload,
        force: force,
        resolvedContent: pinnedContent,
        contentIsResolved: true
      )
    }
  }


  /// Merge a raw engine typing set into the sticky displayed set. Additions show
  /// immediately; a member only leaves once it hasn't been seen typing for the hold
  /// window. Returns true when the displayed set actually changed.
  @discardableResult
  private func updateGroupTypingDisplay(_ engineIds: [String], force: Bool) -> Bool {
    let now = ProcessInfo.processInfo.systemUptime
    for id in engineIds {
      groupTypingLastSeenAt[id.uppercased()] = now
    }
    groupTypingLastSeenAt = groupTypingLastSeenAt.filter {
      now - $0.value < Self.groupTypingHoldSeconds
    }
    let displayed = groupTypingLastSeenAt.keys.sorted()
    scheduleGroupTypingHoldTick()
    guard force || displayed != groupTypingUserIds.map({ $0.uppercased() }).sorted() else {
      return false
    }
    groupTypingUserIds = displayed
    return true
  }

  /// One-shot re-check so held members eventually drop off the header after the
  /// last agent stops typing (no engine event fires for a TTL expiry we held past).
  private func scheduleGroupTypingHoldTick() {
    groupTypingHoldTimer?.invalidate()
    groupTypingHoldTimer = nil
    guard !groupTypingLastSeenAt.isEmpty else { return }
    groupTypingHoldTimer = Timer.scheduledTimer(
      withTimeInterval: 1.0, repeats: false
    ) { [weak self] _ in
      guard let self, self.isGroupOrChannel else { return }
      if self.updateGroupTypingDisplay([], force: false) {
        self.updateHeaderTexts()
        self.updateProfileTexts()
      } else {
        self.scheduleGroupTypingHoldTick()
      }
    }
  }

  private func clearGroupTypingDisplay() {
    groupTypingHoldTimer?.invalidate()
    groupTypingHoldTimer = nil
    groupTypingLastSeenAt.removeAll()
    groupTypingUserIds = []
  }



  private func applyPinnedBannerPayload(
    chatId: String,
    payload: [String: Any],
    force: Bool,
    resolvedContent: ChatMainPinnedBannerContent? = nil,
    contentIsResolved: Bool = false
  ) {
    let pins = (payload["data"] as? [[String: Any]]) ?? []
    let topPin = pins.first
    let nextContent =
      contentIsResolved ? resolvedContent : Self.resolvePinnedBannerContent(chatId: chatId, pin: topPin)
    let nextMessageId = nextContent?.messageId ?? Self.pinnedMessageId(from: topPin)
    let nextTitle = nextContent?.title
    let nextBody = nextContent?.body
    let nextMediaUrl = nextContent?.mediaUrl
    let nextFileName = nextContent?.fileName
    let nextIsFile = nextContent?.isFile == true

    let shouldHide = nextBody == nil
    let bannerChanged =
      nextMessageId != pinnedBannerMessageId
      || nextTitle != pinnedBannerTitle
      || nextBody != pinnedBannerBody
      || nextMediaUrl != pinnedBannerMediaUrl
      || nextFileName != pinnedBannerFileName
      || nextIsFile != pinnedBannerIsFile
      || pinnedBannerView.isHidden != shouldHide
    VibeDebugLog.log(
      "[ChatMainView][Pin] refresh chatId=%@ force=%@ pins=%@ topMessageId=%@ title=%@ nextBody=%@ file=%@ url=%@ currentHidden=%@ shouldHide=%@ changed=%@ loading=%@",
      chatId,
      force ? "true" : "false",
      String(pins.count),
      nextMessageId ?? "(nil)",
      nextTitle ?? "(nil)",
      nextBody ?? "(nil)",
      nextIsFile ? "true" : "false",
      nextMediaUrl ?? "(nil)",
      pinnedBannerView.isHidden ? "true" : "false",
      shouldHide ? "true" : "false",
      bannerChanged ? "true" : "false",
      ((payload["loading"] as? Bool) == true) ? "true" : "false"
    )
    guard force || bannerChanged else { return }

    pinnedBannerMessageId = nextMessageId
    pinnedBannerTitle = nextTitle
    pinnedBannerBody = nextBody
    pinnedBannerMediaUrl = nextMediaUrl
    pinnedBannerFileName = nextFileName
    pinnedBannerIsFile = nextIsFile

    if let nextBody {
      pinnedBannerView.configure(
        title: nextTitle ?? "Pinned Message",
        body: nextBody,
        isFile: nextIsFile,
        animateIcon: bannerChanged
      )
      if pinnedBannerView.isHidden {
        VibeDebugLog.log(
          "[ChatMainView][Pin] show banner messageId=%@ alphaTarget=%@",
          nextMessageId ?? "(nil)",
          currentPage == .chat ? "1.0" : "0.0"
        )
        pinnedBannerView.alpha = 0.0
        pinnedBannerView.isHidden = false
        UIView.animate(withDuration: 0.2) {
          self.pinnedBannerView.alpha = self.currentPage == .chat ? 1.0 : 0.0
        }
      } else {
        VibeDebugLog.log(
          "[ChatMainView][Pin] update banner messageId=%@ alpha=%@",
          nextMessageId ?? "(nil)",
          currentPage == .chat ? "1.0" : "0.0"
        )
        pinnedBannerView.alpha = currentPage == .chat ? 1.0 : 0.0
      }
      setNeedsLayout()
    } else {
      if pinnedBannerView.isHidden {
        pinnedBannerView.alpha = 0.0
      } else {
        VibeDebugLog.log("[ChatMainView][Pin] hide banner (no body)")
        UIView.animate(
          withDuration: 0.18,
          animations: {
            self.pinnedBannerView.alpha = 0.0
          },
          completion: { _ in
            self.pinnedBannerView.isHidden = true
            self.setNeedsLayout()
          }
        )
      }
    }
  }

  private static func pinnedMessageId(from pin: [String: Any]?) -> String? {
    guard let pin else { return nil }
    let raw = pin["messageId"] ?? pin["message_id"] ?? pin["id"]
    if let value = raw as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = raw as? NSNumber {
      return value.stringValue
    }
    return nil
  }

  private static func resolvePinnedBannerContent(chatId: String, pin: [String: Any]?) -> ChatMainPinnedBannerContent? {
    guard let pin else { return nil }

    let messageId = pinnedMessageId(from: pin)
    var type = normalizedPinnedString(pin["type"] ?? pin["messageType"] ?? pin["message_type"])?.lowercased()
    var text = normalizedPinnedString(pin["text"] ?? pin["plainContent"] ?? pin["plain_content"])
    var caption = normalizedPinnedString(pin["caption"])
    var fileName = normalizedPinnedString(pin["fileName"] ?? pin["file_name"])
    var mediaUrl = normalizedPinnedString(pin["mediaUrl"] ?? pin["media_url"])

    if let messageId {
      if let message = ChatEngine.shared.getLiveMessageRow(["chatId": chatId, "messageId": messageId]) {
        type = normalizedPinnedString(message["type"] ?? message["messageType"] ?? message["message_type"])?
          .lowercased() ?? type
        text = text ?? normalizedPinnedString(message["text"] ?? message["plainContent"] ?? message["plain_content"])
        caption = caption ?? normalizedPinnedString(message["caption"])
        fileName = fileName ?? normalizedPinnedString(message["fileName"] ?? message["file_name"])
        mediaUrl = mediaUrl ?? normalizedPinnedString(message["mediaUrl"] ?? message["media_url"])
      } else {
        let rows = ChatEngine.shared.getChatRows(["chatId": chatId])
        for row in rows.reversed() {
          guard (row["kind"] as? String) == "message" else { continue }
          guard let message = row["message"] as? [String: Any] else { continue }
          guard normalizedPinnedString(message["id"]) == messageId else { continue }

          type =
            normalizedPinnedString(message["type"] ?? message["messageType"] ?? message["message_type"])?
            .lowercased() ?? type
          text = text ?? normalizedPinnedString(message["text"] ?? message["plainContent"] ?? message["plain_content"])
          caption = caption ?? normalizedPinnedString(message["caption"])
          fileName = fileName ?? normalizedPinnedString(message["fileName"] ?? message["file_name"])
          mediaUrl = mediaUrl ?? normalizedPinnedString(message["mediaUrl"] ?? message["media_url"])
          break
        }
      }
    }

    let inferredName = inferredPinnedFileName(from: mediaUrl)
    let resolvedFileName = fileName ?? inferredName
    let isFile = isPinnedFileType(type) || resolvedFileName != nil || looksLikePinnedFileURL(mediaUrl)
    let title = isFile ? "Pinned File" : "Pinned Message"
    let resolvedBody: String
    if isFile {
      if let resolvedFileName {
        resolvedBody = "File: \(resolvedFileName)"
      } else if let caption {
        resolvedBody = caption
      } else if let text {
        resolvedBody = text
      } else {
        resolvedBody = "Pinned file"
      }
    } else if let text {
      resolvedBody = text
    } else if let caption {
      resolvedBody = caption
    } else if let mediaUrl {
      resolvedBody = mediaUrl
    } else {
      resolvedBody = "Pinned message"
    }

    return ChatMainPinnedBannerContent(
      title: title,
      body: resolvedBody,
      messageId: messageId,
      isFile: isFile,
      mediaUrl: mediaUrl,
      fileName: resolvedFileName
    )
  }

  private static func normalizedPinnedString(_ value: Any?) -> String? {
    if let str = value as? String {
      let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let num = value as? NSNumber {
      return num.stringValue
    }
    return nil
  }

  private static func isPinnedFileType(_ value: String?) -> Bool {
    guard let normalized = value?.lowercased() else { return false }
    return normalized == "file" || normalized == "music"
  }

  private static func looksLikePinnedFileURL(_ value: String?) -> Bool {
    guard let value else { return false }
    let normalized = value.lowercased()
    if normalized.contains("/api/agent/document/") || normalized.contains("/uploads/agent-docs/") {
      return true
    }
    let documentExtensions = [
      ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".csv", ".txt", ".rtf", ".ppt", ".pptx",
      ".zip", ".json", ".md",
    ]
    return documentExtensions.contains { normalized.contains($0) }
  }

  private static func inferredPinnedFileName(from value: String?) -> String? {
    guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }
    let parsedURL = URL(string: raw)
    let componentRaw: String
    if let parsedURL {
      componentRaw = parsedURL.lastPathComponent
    } else {
      componentRaw =
        raw
        .components(separatedBy: "?")
        .first?
        .components(separatedBy: "#")
        .first?
        .components(separatedBy: "/")
        .last ?? ""
    }
    let component = componentRaw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !component.isEmpty else { return nil }
    if component == "document" || component == "agent-docs" {
      return nil
    }
    return component.removingPercentEncoding ?? component
  }


  private func buildProfileContent(rows: [[String: Any]]) -> (
    mediaItems: [ChatMainProfileMediaItem],
    musicItems: [ChatMainProfileFileItem],
    fileItems: [ChatMainProfileFileItem],
    linkItems: [ChatMainProfileLinkItem],
    pinnedItems: [ChatMainProfilePinnedItem]
  ) {
    var mediaItems: [ChatMainProfileMediaItem] = []
    var musicItems: [ChatMainProfileFileItem] = []
    var fileItems: [ChatMainProfileFileItem] = []
    var linkItems: [ChatMainProfileLinkItem] = []
    var pinnedItems: [ChatMainProfilePinnedItem] = []
    var seenLinks = Set<String>()

    for row in rows.reversed() {
      guard normalizedProfileString(row["kind"]) == "message" else { continue }
      guard let message = row["message"] as? [String: Any] else { continue }

      let messageId = normalizedProfileString(message["id"]) ?? UUID().uuidString
      let type = normalizedProfileString(message["type"])?.lowercased() ?? "text"
      let text = normalizedProfileString(message["text"]) ?? ""
      let caption = normalizedProfileString(message["caption"]) ?? ""
      let mediaUrl = normalizedProfileString(message["mediaUrl"]) ?? ""
      let fileNameRaw = normalizedProfileString(message["fileName"])
      let timestampMs = profileTimestampMs(from: message)
      let dateSubtitle = formatProfileDate(timestampMs)

      if !mediaUrl.isEmpty && ["image", "video", "gif", "sticker"].contains(type) {
        mediaItems.append(
          ChatMainProfileMediaItem(
            messageId: messageId,
            type: type,
            mediaUrl: mediaUrl
          ))
      }

      if type == "music" || type == "file" {
        let fileName =
          (fileNameRaw?.isEmpty == false
            ? fileNameRaw! : "\(type.uppercased())-\(messageId.prefix(6))")
        let fileItem = ChatMainProfileFileItem(
          messageId: messageId,
          type: type,
          fileName: fileName,
          mediaUrl: mediaUrl.isEmpty ? nil : mediaUrl,
          fileSize: parseInt64(message["fileSize"]),
          timestampMs: timestampMs
        )
        if type == "music" {
          musicItems.append(fileItem)
        } else {
          fileItems.append(fileItem)
        }
      }

      if let url = firstDetectedURL(from: text) ?? firstDetectedURL(from: caption)
        ?? firstDetectedURL(from: mediaUrl)
      {
        let isAgentDoc =
          url.contains("/api/agent/document/") || url.contains("/uploads/agent-docs/")
        if !isAgentDoc && !seenLinks.contains(url) {
          seenLinks.insert(url)
          linkItems.append(
            ChatMainProfileLinkItem(
              messageId: messageId,
              url: url,
              subtitle: dateSubtitle
            ))
        }
      }

      let isPinned = (message["isPinned"] as? Bool) == true || (message["pinned"] as? Bool) == true
      if isPinned {
        let pinnedText =
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          ? text
          : (caption.isEmpty ? type.capitalized : caption)
        pinnedItems.append(
          ChatMainProfilePinnedItem(
            messageId: messageId,
            text: pinnedText,
            subtitle: dateSubtitle
          ))
      }
    }

    return (mediaItems, musicItems, fileItems, linkItems, pinnedItems)
  }

  private func normalizedProfileString(_ value: Any?) -> String? {
    guard let value else { return nil }
    if let string = value as? String {
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let number = value as? NSNumber {
      return number.stringValue
    }
    return nil
  }

  private func parseInt64(_ value: Any?) -> Int64? {
    guard let value else { return nil }
    if let intValue = value as? Int64 { return intValue }
    if let intValue = value as? Int { return Int64(intValue) }
    if let number = value as? NSNumber { return number.int64Value }
    if let string = value as? String, let parsed = Int64(string) { return parsed }
    return nil
  }

  private func profileTimestampMs(from message: [String: Any]) -> Int64 {
    if let direct = parseInt64(message["timestampMs"]) { return direct }
    if let direct = parseInt64(message["timestamp_ms"]) { return direct }
    if let direct = parseInt64(message["timestamp"]) {
      return direct < 2_000_000_000 ? direct * 1000 : direct
    }
    if let timestampString = message["timestamp"] as? String {
      if let parsedDouble = Double(timestampString) {
        let ms = parsedDouble < 2_000_000_000 ? parsedDouble * 1000.0 : parsedDouble
        return Int64(ms)
      }
      let iso8601 = ISO8601DateFormatter()
      if let parsedDate = iso8601.date(from: timestampString) {
        return Int64(parsedDate.timeIntervalSince1970 * 1000.0)
      }
    }
    return Int64(Date().timeIntervalSince1970 * 1000.0)
  }

  private func firstDetectedURL(from source: String?) -> String? {
    guard let source, !source.isEmpty else { return nil }
    guard
      let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)
    else { return nil }
    let range = NSRange(location: 0, length: (source as NSString).length)
    guard let match = detector.firstMatch(in: source, options: [], range: range) else { return nil }
    return match.url?.absoluteString
  }

  private func formatProfileDate(_ timestampMs: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
    return Self.profileListDateFormatter.string(from: date)
  }

  private func formatFileSize(_ bytes: Int64?) -> String? {
    guard let bytes, bytes > 0 else { return nil }
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1024 * 1024 {
      return String(format: "%.1f KB", Double(bytes) / 1024.0)
    }
    return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
  }

  private func profileTabCount(_ tab: ChatMainProfileTab) -> Int {
    switch tab {
    case .media: return profileMediaItems.count
    case .music: return profileMusicItems.count
    case .files: return profileFileItems.count
    case .links: return profileLinkItems.count
    case .pinned: return profilePinnedItems.count
    }
  }

  private func profileTabLabel(_ tab: ChatMainProfileTab) -> String {
    switch tab {
    case .media: return "Media"
    case .music: return "Music"
    case .files: return "Files"
    case .links: return "Links"
    case .pinned: return "Pinned"
    }
  }

  private func rebuildProfileTabs() {
    let nextVisibleTabs = ChatMainProfileTab.allCases.filter { profileTabCount($0) > 0 }
    let needsStructureUpdate = nextVisibleTabs != profileVisibleTabs
    profileVisibleTabs = nextVisibleTabs

    if !profileVisibleTabs.isEmpty, !profileVisibleTabs.contains(profileActiveTab) {
      profileActiveTab = profileVisibleTabs[0]
      profileTabContentNeedsReload = true
    }

    if needsStructureUpdate {
      profileTabsStack.subviews.forEach { $0.removeFromSuperview() }
      profileTabButtons.removeAll()

      for tab in profileVisibleTabs {
        let button = ChatMainProfileTabNode()
        button.setTitle("\(profileTabLabel(tab)) \(profileTabCount(tab))")
        button.addTarget(self, action: #selector(handleProfileTabPressed(_:)), for: .touchUpInside)
        profileTabsStack.addSubview(button)
        profileTabButtons[tab] = button
      }
    } else {
      for tab in profileVisibleTabs {
        profileTabButtons[tab]?.setTitle("\(profileTabLabel(tab)) \(profileTabCount(tab))")
      }
    }

    applyProfileTabTheme()
    setNeedsLayout()
  }

  private func applyProfileTabTheme() {
    let activeTextColor = appearance.textColorThem
    let normalTextColor = appearance.timeColorThem.withAlphaComponent(0.95)
    let activeBackgroundColor = appearance.textColorThem.withAlphaComponent(0.12)
    for tab in profileVisibleTabs {
      guard let button = profileTabButtons[tab] else { continue }
      button.isActive = tab == profileActiveTab
      button.applyTheme(
        activeTextColor: activeTextColor,
        normalTextColor: normalTextColor,
        activeBackgroundColor: activeBackgroundColor
      )
    }
  }

  @objc private func handleProfileTabPressed(_ sender: ChatMainProfileTabNode) {
    guard
      let pair = profileTabButtons.first(where: { $0.value === sender }),
      pair.key != profileActiveTab
    else { return }
    profileActiveTab = pair.key
    profileTabContentNeedsReload = true
    applyProfileTabTheme()
    setNeedsLayout()
  }

  private func reloadProfileTabContentIfNeeded(contentWidth: CGFloat) -> CGFloat {
    let normalizedWidth = max(1.0, contentWidth)
    if !profileTabContentNeedsReload && abs(normalizedWidth - profileLastTabContentWidth) < 0.5 {
      return profileTabContentContainer.bounds.height
    }

    profileTabContentNeedsReload = false
    profileLastTabContentWidth = normalizedWidth

    let cardBg = appearance.isDark ? Self.themeDarkCard : Self.themeLightCard
    let textColor = appearance.textColorThem
    let subtitleColor = appearance.timeColorThem.withAlphaComponent(0.9)
    let separatorColor = appearance.timeColorThem.withAlphaComponent(0.18)
    let highlightColor = appearance.textColorThem.withAlphaComponent(0.06)

    profileTabContentContainer.subviews.forEach { subview in
      if subview !== profileTabPlaceholderLabel {
        subview.removeFromSuperview()
      }
    }

    profileTabPlaceholderLabel.frame = .zero
    profileTabPlaceholderLabel.isHidden = true
    profileTabPlaceholderLabel.textColor = subtitleColor

    if !profileSummaryHistoryLoaded {
      profileTabPlaceholderLabel.text =
        "Loading shared media and files from native encrypted cache..."
      profileTabPlaceholderLabel.isHidden = false
      profileTabPlaceholderLabel.frame = CGRect(
        x: 0.0, y: 0.0, width: normalizedWidth, height: 48.0)
      profileTabContentContainer.frame = CGRect(
        x: profileTabContentContainer.frame.minX,
        y: profileTabContentContainer.frame.minY,
        width: normalizedWidth,
        height: 48.0
      )
      return 48.0
    }

    guard !profileVisibleTabs.isEmpty else {
      profileTabPlaceholderLabel.text = "No shared content yet."
      profileTabPlaceholderLabel.isHidden = false
      profileTabPlaceholderLabel.frame = CGRect(
        x: 0.0, y: 0.0, width: normalizedWidth, height: 40.0)
      profileTabContentContainer.frame = CGRect(
        x: profileTabContentContainer.frame.minX,
        y: profileTabContentContainer.frame.minY,
        width: normalizedWidth,
        height: 40.0
      )
      return 40.0
    }

    switch profileActiveTab {
    case .media:
      let items = profileMediaItems
      guard !items.isEmpty else {
        profileTabPlaceholderLabel.text = "No media yet."
        profileTabPlaceholderLabel.isHidden = false
        profileTabPlaceholderLabel.frame = CGRect(
          x: 0.0, y: 0.0, width: normalizedWidth, height: 40.0)
        profileTabContentContainer.frame = CGRect(
          x: profileTabContentContainer.frame.minX,
          y: profileTabContentContainer.frame.minY,
          width: normalizedWidth,
          height: 40.0
        )
        return 40.0
      }

      let gridGap: CGFloat = 3.0
      let columns: CGFloat = 3.0
      let cellSize = floor((normalizedWidth - (gridGap * (columns - 1.0))) / columns)
      for (index, item) in items.enumerated() {
        let cell = ChatMainProfileMediaCellNode()
        let column = CGFloat(index % Int(columns))
        let row = CGFloat(index / Int(columns))
        cell.frame = CGRect(
          x: column * (cellSize + gridGap),
          y: row * (cellSize + gridGap),
          width: cellSize,
          height: cellSize
        )
        cell.tag = index
        cell.configure(urlString: item.mediaUrl, isVideo: item.type == "video")
        cell.applyTheme(
          placeholderTintColor: appearance.timeColorThem.withAlphaComponent(0.72),
          placeholderBackgroundColor: appearance.textColorThem.withAlphaComponent(0.06)
        )
        cell.addTarget(
          self, action: #selector(handleProfileMediaCellPressed(_:)), for: .touchUpInside)
        profileTabContentContainer.addSubview(cell)
      }
      let rows = ceil(CGFloat(items.count) / columns)
      let totalHeight = max(0.0, rows * cellSize + max(0.0, rows - 1.0) * gridGap)
      profileTabContentContainer.frame = CGRect(
        x: profileTabContentContainer.frame.minX,
        y: profileTabContentContainer.frame.minY,
        width: normalizedWidth,
        height: totalHeight
      )
      return totalHeight

    case .music, .files, .links, .pinned:
      let card = UIView()
      card.backgroundColor = cardBg
      card.layer.cornerRadius = 24.0
      card.layer.cornerCurve = .continuous
      profileTabContentContainer.addSubview(card)

      var rows: [(title: String, subtitle: String, titleColor: UIColor?, selector: Selector)] = []
      switch profileActiveTab {
      case .music:
        rows = profileMusicItems.map { item in
          let subtitleParts = [formatFileSize(item.fileSize), formatProfileDate(item.timestampMs)]
            .compactMap { $0 }
          return (
            item.fileName,
            subtitleParts.joined(separator: " · "),
            nil,
            #selector(handleProfileMusicRowPressed(_:))
          )
        }
      case .files:
        rows = profileFileItems.map { item in
          let subtitleParts = [formatFileSize(item.fileSize), formatProfileDate(item.timestampMs)]
            .compactMap { $0 }
          return (
            item.fileName,
            subtitleParts.joined(separator: " · "),
            nil,
            #selector(handleProfileFileRowPressed(_:))
          )
        }
      case .links:
        rows = profileLinkItems.map { item in
          (
            item.url,
            item.subtitle,
            appearance.bubbleMeGradient.last ?? appearance.textColorMe,
            #selector(handleProfileLinkRowPressed(_:))
          )
        }
      case .pinned:
        rows = profilePinnedItems.map { item in
          (
            item.text,
            item.subtitle,
            nil,
            #selector(handleProfilePinnedRowPressed(_:))
          )
        }
      case .media:
        rows = []
      }

      guard !rows.isEmpty else {
        profileTabPlaceholderLabel.text = "No content yet."
        profileTabPlaceholderLabel.isHidden = false
        profileTabPlaceholderLabel.frame = CGRect(
          x: 0.0, y: 0.0, width: normalizedWidth, height: 40.0)
        card.removeFromSuperview()
        profileTabContentContainer.frame = CGRect(
          x: profileTabContentContainer.frame.minX,
          y: profileTabContentContainer.frame.minY,
          width: normalizedWidth,
          height: 40.0
        )
        return 40.0
      }

      let rowHeight: CGFloat = 62.0
      for (index, row) in rows.enumerated() {
        let rowNode = ChatMainProfileListRowNode()
        rowNode.frame = CGRect(
          x: 0.0,
          y: CGFloat(index) * rowHeight,
          width: normalizedWidth,
          height: rowHeight
        )
        rowNode.tag = index
        rowNode.configure(
          title: row.title,
          subtitle: row.subtitle,
          titleColor: row.titleColor,
          showsSeparator: index < rows.count - 1
        )
        rowNode.applyTheme(
          titleColor: textColor,
          subtitleColor: subtitleColor,
          separatorColor: separatorColor,
          highlightedColor: highlightColor
        )
        rowNode.addTarget(self, action: row.selector, for: .touchUpInside)
        card.addSubview(rowNode)
      }
      let totalHeight = rowHeight * CGFloat(rows.count)
      card.frame = CGRect(x: 0.0, y: 0.0, width: normalizedWidth, height: totalHeight)
      profileTabContentContainer.frame = CGRect(
        x: profileTabContentContainer.frame.minX,
        y: profileTabContentContainer.frame.minY,
        width: normalizedWidth,
        height: totalHeight
      )
      return totalHeight
    }
  }

  @objc private func handleProfileMediaCellPressed(_ sender: ChatMainProfileMediaCellNode) {
    let index = sender.tag
    guard index >= 0, index < profileMediaItems.count else { return }
    let item = profileMediaItems[index]
    onNativeEvent([
      "type": "profileContentPressed",
      "tab": "media",
      "messageId": item.messageId,
      "url": item.mediaUrl,
    ])
  }

  @objc private func handleProfileMusicRowPressed(_ sender: ChatMainProfileListRowNode) {
    let index = sender.tag
    guard index >= 0, index < profileMusicItems.count else { return }
    let item = profileMusicItems[index]
    onNativeEvent([
      "type": "profileContentPressed",
      "tab": "music",
      "messageId": item.messageId,
      "url": item.mediaUrl ?? "",
      "fileName": item.fileName,
    ])
  }

  @objc private func handleProfileFileRowPressed(_ sender: ChatMainProfileListRowNode) {
    let index = sender.tag
    guard index >= 0, index < profileFileItems.count else { return }
    let item = profileFileItems[index]
    onNativeEvent([
      "type": "profileContentPressed",
      "tab": "files",
      "messageId": item.messageId,
      "url": item.mediaUrl ?? "",
      "fileName": item.fileName,
    ])
  }

  @objc private func handleProfileLinkRowPressed(_ sender: ChatMainProfileListRowNode) {
    let index = sender.tag
    guard index >= 0, index < profileLinkItems.count else { return }
    let item = profileLinkItems[index]
    onNativeEvent([
      "type": "profileContentPressed",
      "tab": "links",
      "messageId": item.messageId,
      "url": item.url,
    ])
  }

  @objc private func handleProfilePinnedRowPressed(_ sender: ChatMainProfileListRowNode) {
    let index = sender.tag
    guard index >= 0, index < profilePinnedItems.count else { return }
    let item = profilePinnedItems[index]
    onNativeEvent([
      "type": "profileContentPressed",
      "tab": "pinned",
      "messageId": item.messageId,
      "text": item.text,
    ])
  }

  @objc private func handlePinnedBannerPressed() {
    guard currentPage == .chat else { return }
    guard let messageId = pinnedBannerMessageId, !messageId.isEmpty else { return }
    chatListView.scrollToMessage(messageId: messageId, animated: true, viewPosition: 0.2)

    let targetTab: ChatMainProfileTab = {
      if pinnedBannerIsFile, profileVisibleTabs.contains(.files) {
        return .files
      }
      if profileVisibleTabs.contains(.pinned) {
        return .pinned
      }
      return profileActiveTab
    }()
    if targetTab != profileActiveTab {
      profileActiveTab = targetTab
      profileTabContentNeedsReload = true
      rebuildProfileTabs()
      setNeedsLayout()
    }

    if standaloneProfileMode {
      setPage("profile", animated: true)

      if pinnedBannerIsFile,
        let mediaUrl = pinnedBannerMediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
        !mediaUrl.isEmpty
      {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
          self?.chatListView.openPinnedDocument(urlString: mediaUrl)
        }
      }
    }

    var payload: [String: Any] = [
      "type": "pinnedBannerPressed",
      "messageId": messageId,
      "isFile": pinnedBannerIsFile,
      "tab": targetTab.rawValue,
      "standaloneProfileMode": standaloneProfileMode,
    ]
    if let title = pinnedBannerTitle {
      payload["title"] = title
    }
    if let body = pinnedBannerBody {
      payload["body"] = body
    }
    if let mediaUrl = pinnedBannerMediaUrl {
      payload["url"] = mediaUrl
    }
    if let fileName = pinnedBannerFileName {
      payload["fileName"] = fileName
    }
    onNativeEvent(payload)
  }

  private func currentBuilderPanelTheme() -> ChatBuilderPanelTheme {
    let isDarkTheme = appearance.isDark
    return ChatBuilderPanelTheme(
      isDark: isDarkTheme,
      backgroundColor: builderThemeColor(isDarkTheme ? "#121212" : "#F5F4F1"),
      cardColor: builderThemeColor(isDarkTheme ? "#242424" : "#FFFFFF"),
      inputColor: builderThemeColor(isDarkTheme ? "#222222" : "#F2F2F2"),
      textColor: builderThemeColor(isDarkTheme ? "#E8E6F0" : "#1A1A1F"),
      secondaryTextColor: builderThemeColor(isDarkTheme ? "#9896A8" : "#5A5A66"),
      accentColor: builderThemeColor(isDarkTheme ? "#7CB8B8" : "#4A8D8E")
    )
  }

  private func builderThemeColor(_ hex: String) -> UIColor {
    let sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
    guard sanitized.count == 6, let value = Int(sanitized, radix: 16) else { return .systemBackground }
    return UIColor(
      red: CGFloat((value >> 16) & 0xff) / 255.0,
      green: CGFloat((value >> 8) & 0xff) / 255.0,
      blue: CGFloat(value & 0xff) / 255.0,
      alpha: 1.0
    )
  }

  private func synchronizeBuilderPanelPresentation() {
    if builderSetupPanelPayload == nil {
      dismissPresentedBuilderPanelIfNeeded()
      return
    }

    if builderSetupPanelPayload?.pendingUiRequest == nil && currentBuilderReviewSignature() == nil {
      dismissPresentedBuilderPanelIfNeeded()
      return
    }

    presentCurrentBuilderPanel(force: false)
  }

  private func currentBuilderReviewSignature() -> String? {
    guard let panel = builderSetupPanelPayload, !panel.reviewSections.isEmpty else { return nil }
    guard panel.pendingUiRequest == nil else { return nil }
    guard panel.setupState?.status == "review_ready" || panel.setupState == nil else { return nil }

    let sectionSignature =
      panel.reviewSections
      .map { "\($0.id):\($0.requestId):\($0.summary)" }
      .joined(separator: "|")
    return "\(panel.setupState?.status ?? "review")#\(sectionSignature)"
  }

  private func dismissPresentedBuilderPanelIfNeeded() {
    if let navigationController = builderSetupNavigationController,
      navigationController.presentingViewController != nil
    {
      navigationController.dismiss(animated: true)
    }
    builderSetupNavigationController = nil
  }

  private func presentCurrentBuilderPanel(force: Bool) {
    guard let panel = builderSetupPanelPayload else { return }
    if let request = panel.pendingUiRequest {
      presentBuilderRequest(request, panel: panel, force: force)
      return
    }

    if let reviewSignature = currentBuilderReviewSignature() {
      presentBuilderReview(panel.reviewSections, panel: panel, signature: reviewSignature, force: force)
      return
    }

    if force && !panel.activity.isEmpty {
      presentBuilderProgress(panel)
    }
  }

  private func presentBuilderRequest(
    _ request: ChatBuilderUiRequest,
    panel: ChatBuilderPanelPayload,
    force: Bool
  ) {
    if let navigationController = builderSetupNavigationController,
      navigationController.presentingViewController != nil
    {
      return
    }
    if !force && lastPresentedBuilderRequestId == request.id {
      return
    }
    guard let presenter = topMostViewController() else { return }

    let controller = ChatBuilderPanelController(
      mode: .request(request),
      theme: currentBuilderPanelTheme(),
      setupState: panel.setupState,
      activity: panel.activity,
      agentEnabled: panel.agentEnabled
    )
    controller.onSubmitRequest = { [weak self] requestId, answers, summary in
      var payload: [String: Any] = [
        "type": "builderSetupSubmit",
        "requestId": requestId,
        "answers": answers,
      ]
      if let summary, !summary.isEmpty {
        payload["summary"] = summary
      }
      self?.onNativeEvent(payload)
    }
    controller.onCreateDraft = { [weak self] agentEnabled in
      var payload: [String: Any] = ["type": "builderReviewCreateDraft"]
      if let agentEnabled {
        payload["agentEnabled"] = agentEnabled
      }
      self?.onNativeEvent(payload)
    }
    controller.onControllerDismissed = { [weak self] in
      self?.builderSetupNavigationController = nil
    }

    let navigationController = UINavigationController(rootViewController: controller)
    navigationController.modalPresentationStyle = .pageSheet
    if let sheet = navigationController.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.selectedDetentIdentifier = .medium
      sheet.prefersGrabberVisible = false
      sheet.prefersScrollingExpandsWhenScrolledToEdge = true
      sheet.prefersEdgeAttachedInCompactHeight = true
      sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
      sheet.preferredCornerRadius = 28.0
    }

    builderSetupNavigationController = navigationController
    lastPresentedBuilderRequestId = request.id
    lastPresentedBuilderReviewSignature = nil
    presenter.present(navigationController, animated: true)
  }

  private func presentBuilderReview(
    _ sections: [ChatBuilderReviewSection],
    panel: ChatBuilderPanelPayload,
    signature: String,
    force: Bool
  ) {
    if let navigationController = builderSetupNavigationController,
      navigationController.presentingViewController != nil
    {
      return
    }
    if !force && lastPresentedBuilderReviewSignature == signature {
      return
    }
    guard let presenter = topMostViewController() else { return }

    let controller = ChatBuilderPanelController(
      mode: .review(sections),
      theme: currentBuilderPanelTheme(),
      setupState: panel.setupState,
      activity: panel.activity,
      agentEnabled: panel.agentEnabled
    )
    controller.onSubmitRequest = { [weak self] requestId, answers, summary in
      var payload: [String: Any] = [
        "type": "builderSetupSubmit",
        "requestId": requestId,
        "answers": answers,
      ]
      if let summary, !summary.isEmpty {
        payload["summary"] = summary
      }
      self?.onNativeEvent(payload)
    }
    controller.onCreateDraft = { [weak self] agentEnabled in
      var payload: [String: Any] = ["type": "builderReviewCreateDraft"]
      if let agentEnabled {
        payload["agentEnabled"] = agentEnabled
      }
      self?.onNativeEvent(payload)
    }
    controller.onControllerDismissed = { [weak self] in
      self?.builderSetupNavigationController = nil
    }

    let navigationController = UINavigationController(rootViewController: controller)
    navigationController.modalPresentationStyle = .pageSheet
    if let sheet = navigationController.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.selectedDetentIdentifier = .medium
      sheet.prefersGrabberVisible = false
      sheet.prefersScrollingExpandsWhenScrolledToEdge = true
      sheet.prefersEdgeAttachedInCompactHeight = true
      sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
      sheet.preferredCornerRadius = 28.0
    }

    builderSetupNavigationController = navigationController
    lastPresentedBuilderReviewSignature = signature
    lastPresentedBuilderRequestId = nil
    presenter.present(navigationController, animated: true)
  }

  private func presentBuilderProgress(_ panel: ChatBuilderPanelPayload) {
    if let navigationController = builderSetupNavigationController,
      navigationController.presentingViewController != nil
    {
      return
    }
    guard let presenter = topMostViewController() else { return }

    let controller = ChatBuilderPanelController(
      mode: .progress,
      theme: currentBuilderPanelTheme(),
      setupState: panel.setupState,
      activity: panel.activity,
      agentEnabled: panel.agentEnabled
    )
    controller.onSubmitRequest = { [weak self] requestId, answers, summary in
      var payload: [String: Any] = [
        "type": "builderSetupSubmit",
        "requestId": requestId,
        "answers": answers,
      ]
      if let summary, !summary.isEmpty {
        payload["summary"] = summary
      }
      self?.onNativeEvent(payload)
    }
    controller.onCreateDraft = { [weak self] agentEnabled in
      var payload: [String: Any] = ["type": "builderReviewCreateDraft"]
      if let agentEnabled {
        payload["agentEnabled"] = agentEnabled
      }
      self?.onNativeEvent(payload)
    }
    controller.onControllerDismissed = { [weak self] in
      self?.builderSetupNavigationController = nil
    }

    let navigationController = UINavigationController(rootViewController: controller)
    navigationController.modalPresentationStyle = .pageSheet
    if let sheet = navigationController.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.selectedDetentIdentifier = .medium
      sheet.prefersGrabberVisible = false
      sheet.prefersScrollingExpandsWhenScrolledToEdge = true
      sheet.prefersEdgeAttachedInCompactHeight = true
      sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
      sheet.preferredCornerRadius = 28.0
    }

    builderSetupNavigationController = navigationController
    presenter.present(navigationController, animated: true)
  }

  /// System light/dark for glass chrome chips only (not mask plate).
  private var headerChromeIsDark: Bool {
    let style =
      window?.traitCollection.userInterfaceStyle
      ?? traitCollection.userInterfaceStyle
    if style == .unspecified {
      return UIScreen.main.traitCollection.userInterfaceStyle == .dark
    }
    return style == .dark
  }

  /// Mask plate darkness follows **chat theme** (wallpaper), not system UI style.
  /// Using system alone made dark chats still get light/gray materials → brown/gray wash.
  private var headerMaskIsDark: Bool {
    appearance.isDark
  }

  /// Soft header-mask wash: dark = pure black; light = desaturated theme tint (never pure white).
  private func headerMaskWashColor(isDark: Bool) -> UIColor {
    if isDark {
      return UIColor.black
    }
    // Theme wallpaper tint — keep some chroma, no hardcoded white.
    let themeBase =
      appearance.wallpaperGradient.first
      ?? UIColor.secondarySystemBackground.resolvedColor(
        with: UITraitCollection(userInterfaceStyle: .light))
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    guard themeBase.getRed(&r, green: &g, blue: &b, alpha: &a) else {
      return themeBase
    }
    // Mild desaturate toward cool-neutral — less aggressive so tint still reads.
    let target: CGFloat = 0.88
    let mix: CGFloat = 0.35
    let inv = 1.0 - mix
    return UIColor(
      red: (r * inv) + (target * mix),
      green: (g * inv) + (target * mix),
      blue: (b * inv) + (target * mix),
      alpha: 1.0
    )
  }

  private func applyHeaderChromeSystemStyle() {
    // Header chrome + mask both follow **chat theme** dark/light (not system UI style).
    let themeDark = headerMaskIsDark
    let themeStyle: UIUserInterfaceStyle = themeDark ? .dark : .light
    headerContainer.overrideUserInterfaceStyle = themeStyle
    profileHeaderContainer.overrideUserInterfaceStyle = themeStyle
    headerMaskView.overrideUserInterfaceStyle = themeStyle
    headerMaskBlurView.overrideUserInterfaceStyle = themeStyle
    headerMaskBlurBoostView.overrideUserInterfaceStyle = themeStyle
    [
      backGlassView, titleGlassView, avatarGlassView, menuGlassView,
      savedSearchCancelGlassView, rightActionsGlassView,
      profileBackGlassView, profileMenuGlassView,
    ].forEach { $0.overrideUserInterfaceStyle = themeStyle }

    // Double-pass blur: thick base + chrome boost (one style alone is too soft).
    headerMaskBlurView.effect =
      UIBlurEffect(style: themeDark ? .systemThickMaterialDark : .systemThickMaterialLight)
    headerMaskBlurBoostView.effect =
      UIBlurEffect(style: themeDark ? .systemChromeMaterialDark : .systemChromeMaterialLight)
    headerMaskOverlayView.backgroundColor =
      themeDark
      ? UIColor.black.withAlphaComponent(0.88)
      : headerMaskWashColor(isDark: false).withAlphaComponent(0.56)
  }

  private func refreshHeaderGlass() {
    applyHeaderChromeSystemStyle()
    let isDark = headerMaskIsDark

    // Always show custom soft header mask (replaces system top edge API).
    headerMaskView.isHidden = false
    profileHeaderMaskView.isHidden = true

    if #available(iOS 26.0, *) {
      func makeGlassEffect() -> UIGlassEffect {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        // No black/white plate tint — clear glass so chips don’t read as hard black.
        effect.tintColor = .clear
        return effect
      }

      backGlassView.effect = makeGlassEffect()
      titleGlassView.effect = nil // Title stays clear of glass chrome
      avatarGlassView.effect = makeGlassEffect()
      menuGlassView.effect = makeGlassEffect()
      savedSearchCancelGlassView.effect = makeGlassEffect()
      rightActionsGlassView.effect = makeGlassEffect()
      profileBackGlassView.effect = makeGlassEffect()
      profileMenuGlassView.effect = makeGlassEffect()

      let collection = chatListView.collectionView
      // Custom header mask owns the top fade — hide system edge API there.
      collection.topEdgeEffect.isHidden = true
      collection.bottomEdgeEffect.isHidden = false
      collection.bottomEdgeEffect.style = .soft

      profileScrollView.topEdgeEffect.isHidden = true
      profileScrollView.bottomEdgeEffect.isHidden = false
      profileScrollView.bottomEdgeEffect.style = .soft
    } else {
      // Theme dark/light materials (chat appearance, not system-only).
      let material: UIBlurEffect.Style =
        isDark ? .systemMaterialDark : .systemMaterialLight
      backGlassView.effect = UIBlurEffect(style: material)
      titleGlassView.effect = UIBlurEffect(style: material)
      avatarGlassView.effect = UIBlurEffect(style: material)
      menuGlassView.effect = UIBlurEffect(style: material)
      savedSearchCancelGlassView.effect = UIBlurEffect(style: material)
      rightActionsGlassView.effect = UIBlurEffect(style: material)
      profileBackGlassView.effect = UIBlurEffect(style: material)
      profileMenuGlassView.effect = UIBlurEffect(style: material)
    }
  }

  private func applyProfileHeaderMenuButtonStyle(_ button: UIButton) {
    if #available(iOS 26.0, *) {
      var config = UIButton.Configuration.glass()
      config.cornerStyle = .capsule
      config.image = UIImage(
        systemName: "ellipsis",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
      )
      config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
      button.configuration = config
      return
    }

    button.configuration = nil
    button.setImage(UIImage(systemName: "ellipsis"), for: .normal)
  }

  private func markPendingNativePageChange(_ page: ChatMainPage) {
    pendingNativePageTarget = page
    pendingNativePageLockUntil = CACurrentMediaTime() + 2.0
  }

  /// `bringSubviewToFront` dirties the container's layout even when nothing moves.
  /// These run every layout pass, so re-order only when the view isn't already on top.
  private func bringToFrontIfNeeded(_ view: UIView, in container: UIView? = nil) {
    let host = container ?? self
    guard host.subviews.last !== view else { return }
    host.bringSubviewToFront(view)
  }

  /// Header stack setters invalidate its Auto Layout engine even when the value is unchanged,
  /// which turns the next `systemLayoutSizeFitting` into a full re-solve. Assign only on change.
  private func setTextIfNeeded(_ label: UILabel, _ text: String) {
    guard label.text != text else { return }
    label.text = text
  }

  private func setFontIfNeeded(_ label: UILabel, _ font: UIFont) {
    guard label.font != font else { return }
    label.font = font
  }

  private func setHiddenIfNeeded(_ view: UIView, _ hidden: Bool) {
    guard view.isHidden != hidden else { return }
    view.isHidden = hidden
  }

  private func layoutChrome() {
    // A Home mini-preview is already positioned inside the screen safe area.
    // Reusing the window inset here pushes its centered header down a second time.
    let safeTop: CGFloat = (previewHeaderCenterOnly || previewHeaderCompactLeading)
      ? 0.0
      : (window?.safeAreaInsets.top ?? safeAreaInsets.top)
    let headerHeight = safeTop + 60.0
    let contentY = safeTop + 8.0
    let headerContentWidth = max(0.0, bounds.width - 24.0)
    let bridgeHeaderActive =
      !bridgeProvider.isEmpty && headerMode != .savedMessages && !savedSearchExpanded
    let maxCenterWidth = max(0.0, headerContentWidth * (bridgeHeaderActive ? 0.52 : 0.55))
    let hideChatHeader = externalNavigationHeaderEnabled && !savedSearchExpanded
    if hideChatHeader {
      headerContainer.frame = .zero
      headerMaskView.frame = .zero
      headerMaskBlurView.frame = .zero
      headerMaskBlurBoostView.frame = .zero
      headerMaskOverlayView.frame = .zero
      headerMaskGradientLayer.frame = .zero
      headerContentView.frame = .zero
      backGlassView.frame = .zero
      titleGlassView.frame = .zero
      avatarGlassView.frame = .zero
      menuGlassView.frame = .zero
      savedSearchCancelGlassView.frame = .zero
      rightActionsGlassView.frame = .zero
      backButton.frame = .zero
      titleButton.frame = titleGlassView.bounds
      avatarButton.frame = .zero
      menuButton.frame = .zero
      savedSearchField.frame = .zero
      savedSearchCancelButton.frame = .zero
      chatHeaderStack.frame = .zero
      applyHeaderSearchPresentation()
    } else {
      headerContainer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
      // Soft fade band extends below the chip row so blur eases out (not a hard edge).
      let maskFadeExtra: CGFloat = 44.0
      let maskHeight = headerHeight + maskFadeExtra
      headerMaskView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: maskHeight)
      headerMaskBlurView.frame = headerMaskView.bounds
      headerMaskBlurBoostView.frame = headerMaskView.bounds
      // Sibling on top of blur stack (not inside contentView) so black tint is pure.
      headerMaskOverlayView.frame = headerMaskView.bounds
      headerMaskGradientLayer.frame = headerMaskView.bounds
      bringToFrontIfNeeded(headerMaskOverlayView, in: headerMaskView)
      bringToFrontIfNeeded(headerContentView, in: headerContainer)

      headerContentView.frame = CGRect(
        x: 12.0, y: contentY, width: max(0.0, bounds.width - 24.0), height: 44.0)

      let backWidth: CGFloat
      if selectionModeActive {
        // Always show cancel (xmark) glass during selection — never collapse to 0.
        backWidth = 44.0
      } else if (previewHeaderCenterOnly || previewHeaderCompactLeading) && !savedSearchExpanded {
        backWidth = 0.0
      } else {
        backWidth = headerUnreadCount > 0 ? 62.0 : 44.0
      }
      backGlassView.frame = CGRect(x: 0.0, y: 0.0, width: backWidth, height: 44.0)
      
      let subtitleDotWidth: CGFloat = chatSubtitleDotView.isHidden ? 0.0 : 10.0
      let requestedHeaderWidth = max(
        chatTitleLabel.intrinsicContentSize.width,
        chatSubtitleLabel.intrinsicContentSize.width + subtitleDotWidth
      )

      // Selection keeps the same geometry as normal chat (no title X/Y shift).
      // Username/subtitle ↔ "Select messages" / "Selected N" is pure alpha fade.
      // Trailing: blue checkmark (Saved Messages reuses the search trailing slot).
      if selectionModeActive && currentPage == .chat && !savedSearchExpanded {
        menuGlassView.frame = .zero
        savedSearchCancelGlassView.frame = .zero
        selectionDoneButton.frame.size = CGSize(width: 44.0, height: 44.0)
        rightActionsGlassView.frame = CGRect(
          x: headerContentView.bounds.width - 44.0,
          y: 0.0,
          width: 44.0,
          height: 44.0
        )
        let glassMinX = backGlassView.frame.maxX + 8.0
        // Avatar stays a 44 circle (fades content only — no expand / no translate).
        if headerMode == .savedMessages {
          avatarGlassView.frame = CGRect(
            x: glassMinX, y: 0.0, width: 44.0, height: 44.0)
        } else {
          avatarGlassView.frame = CGRect(
            x: glassMinX, y: 0.0, width: 44.0, height: 44.0)
        }
        let titleMinX = avatarGlassView.frame.maxX + 12.0
        let titleMaxX = rightActionsGlassView.frame.minX - 8.0
        titleGlassView.frame = CGRect(
          x: titleMinX,
          y: 0.0,
          width: max(0.0, titleMaxX - titleMinX),
          height: 44.0
        )
      } else if previewHeaderCompactLeading && !savedSearchExpanded {
        menuGlassView.frame = .zero
        savedSearchCancelGlassView.frame = .zero
        rightActionsGlassView.frame = .zero
        avatarGlassView.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        let titleX = avatarGlassView.frame.maxX + 10
        titleGlassView.frame = CGRect(
          x: titleX,
          y: 0,
          width: max(0, headerContentView.bounds.width - titleX),
          height: 44
        )
      } else if previewHeaderCenterOnly && !savedSearchExpanded {
        avatarGlassView.frame = .zero
        menuGlassView.frame = .zero
        savedSearchCancelGlassView.frame = .zero
        rightActionsGlassView.frame = .zero
        
        let centerWidth = min(
          max(140.0, requestedHeaderWidth + 32.0),
          max(140.0, headerContentView.bounds.width - 48.0)
        )
        let centerX = (headerContentView.bounds.width - centerWidth) * 0.5
        titleGlassView.frame = CGRect(x: centerX, y: 0.0, width: centerWidth, height: 44.0)
        
      } else if headerMode == .savedMessages || savedSearchExpanded {
        avatarGlassView.frame = savedSearchExpanded
          ? .zero
          : CGRect(
            x: backGlassView.frame.maxX + 8.0, y: 0.0, width: 44.0, height: 44.0)
        let cancelSpacing: CGFloat = savedSearchExpanded ? 8.0 : 0.0
        let cancelWidth: CGFloat = savedSearchExpanded ? 44.0 : 0.0
        let searchWidth = savedSearchExpanded
          ? max(44.0, headerContentView.bounds.width - cancelWidth - cancelSpacing)
          : 44.0
        menuGlassView.frame = CGRect(
          x: max(0.0, headerContentView.bounds.width - searchWidth - cancelWidth - cancelSpacing),
          y: 0.0,
          width: searchWidth,
          height: 44.0
        )
        savedSearchCancelGlassView.frame = savedSearchExpanded
          ? CGRect(
            x: min(
              headerContentView.bounds.width - cancelWidth,
              menuGlassView.frame.maxX + cancelSpacing
            ),
            y: 0.0,
            width: cancelWidth,
            height: 44.0
          )
          : .zero
        rightActionsGlassView.frame = .zero

        if savedSearchExpanded {
          titleGlassView.frame = .zero
        } else {
          let titleX = avatarGlassView.frame.maxX + 12.0
          let titleMaxX = menuGlassView.frame.minX - 8.0
          titleGlassView.frame = CGRect(
            x: titleX,
            y: 0.0,
            width: max(0.0, min(maxCenterWidth, titleMaxX - titleX)),
            height: 44.0
          )
        }
        
      } else {
        // Setup right actions first (call/video — or selection checkmark).
        var visibleActionCount = 0
        if !callButton.isHidden { visibleActionCount += 1 }
        if !videoCallButton.isHidden { visibleActionCount += 1 }
        if !historyButton.isHidden { visibleActionCount += 1 }
        if !newChatButton.isHidden { visibleActionCount += 1 }
        if !selectionDoneButton.isHidden { visibleActionCount += 1 }

        let actionWidth: CGFloat = 44.0
        let actionSpacing: CGFloat = 0.0
        let totalActionsWidth =
          CGFloat(visibleActionCount) * actionWidth
          + CGFloat(max(0, visibleActionCount - 1)) * actionSpacing

        rightActionsGlassView.frame = CGRect(
          x: headerContentView.bounds.width - max(totalActionsWidth, 0.0),
          y: 0.0,
          width: max(totalActionsWidth, 0.0),
          height: 44.0
        )

        callButton.frame.size = CGSize(width: 44.0, height: 44.0)
        videoCallButton.frame.size = CGSize(width: 44.0, height: 44.0)
        historyButton.frame.size = CGSize(width: 44.0, height: 44.0)
        newChatButton.frame.size = CGSize(width: 44.0, height: 44.0)
        selectionDoneButton.frame.size = CGSize(width: 44.0, height: 44.0)

        menuGlassView.frame = .zero
        savedSearchCancelGlassView.frame = .zero

        // Normal chat chrome (selection handled in the early branch above).
        let glassMinX = backGlassView.frame.maxX + 8.0
        let glassMaxX =
          rightActionsGlassView.frame.minX > 0
          ? rightActionsGlassView.frame.minX - 8.0
          : headerContentView.bounds.width - 8.0
        avatarGlassView.frame = CGRect(
          x: glassMinX, y: 0.0, width: 44.0, height: 44.0)
        let titleMinX = avatarGlassView.frame.maxX + 12.0
        let availableWidth = max(0, glassMaxX - titleMinX)
        titleGlassView.frame = CGRect(
          x: titleMinX,
          y: 0.0,
          width: availableWidth,
          height: 44.0
        )
      }

      backButton.frame = backGlassView.bounds
      titleButton.frame = titleGlassView.bounds
      avatarButton.frame = avatarGlassView.bounds
      if headerMode == .savedMessages || savedSearchExpanded {
        menuButton.frame = savedSearchExpanded
          ? CGRect(x: 10.0, y: 0.0, width: 20.0, height: 44.0)
          : CGRect(x: 0.0, y: 0.0, width: 44.0, height: 44.0)
        savedSearchCancelButton.frame = savedSearchCancelGlassView.bounds
        let fieldMinX: CGFloat = 36.0
        let fieldMaxX = max(fieldMinX, menuGlassView.bounds.width - 12.0)
        savedSearchField.frame = CGRect(
          x: fieldMinX,
          y: 0.0,
          width: max(0.0, fieldMaxX - fieldMinX),
          height: 44.0
        )
      } else {
        menuButton.frame = menuGlassView.bounds
        savedSearchField.frame = .zero
        savedSearchCancelButton.frame = .zero
      }

      [backButton, avatarButton, titleButton, menuButton, savedSearchCancelButton, callButton, videoCallButton, historyButton, newChatButton, selectionDoneButton].forEach {
        control in
        // Capsule when wide (selection pill), circle when 44×44.
        control.layer.cornerRadius = min(control.bounds.width, control.bounds.height) / 2.0
        control.layer.cornerCurve = .continuous
      }
      [backGlassView, avatarGlassView, titleGlassView, menuGlassView, savedSearchCancelGlassView, rightActionsGlassView]
        .forEach { view in
          view.layer.cornerRadius = min(view.bounds.width, view.bounds.height) / 2.0
          view.layer.cornerCurve = .continuous
        }

      // Avatar stays laid out; selection only fades its alpha (no zero frame).
      avatarNode.frame = avatarButton.bounds.insetBy(dx: 4.0, dy: 4.0)
      applySelectionDoneBlueTint()

      let horizontalInset: CGFloat = (headerMode == .savedMessages || savedSearchExpanded) ? 12.0 : 4.0
      let titleInnerWidth = max(0.0, titleButton.bounds.width - (horizontalInset * 2.0))
      let stackSize = chatHeaderStack.systemLayoutSizeFitting(
        CGSize(width: titleInnerWidth, height: UIView.layoutFittingCompressedSize.height),
        withHorizontalFittingPriority: .required,
        verticalFittingPriority: .fittingSizeLevel
      )
      // Username/subtitle and selection title share the same rect — only alpha swaps.
      let titleContentFrame = CGRect(
        x: horizontalInset,
        y: (titleButton.bounds.height - stackSize.height) * 0.5,
        width: titleInnerWidth,
        height: stackSize.height
      )
      chatHeaderStack.frame = titleContentFrame
      if selectionModeActive, !selectionHeaderStack.isHidden {
        let selSize = selectionHeaderStack.systemLayoutSizeFitting(
          CGSize(
            width: titleInnerWidth,
            height: UIView.layoutFittingCompressedSize.height
          ),
          withHorizontalFittingPriority: .fittingSizeLevel,
          verticalFittingPriority: .fittingSizeLevel
        )
        selectionHeaderStack.frame = CGRect(
          x: horizontalInset,
          y: (titleButton.bounds.height - selSize.height) * 0.5,
          width: min(selSize.width, titleInnerWidth),
          height: selSize.height
        )
      } else {
        selectionHeaderStack.frame = .zero
      }
      if subtitleShimmerActive {
        chatHeaderStack.layoutIfNeeded()
        applySubtitleShimmerFrame()
      }
      applyHeaderSearchPresentation()
    }

    profileHeaderContainer.frame = CGRect(x: 0.0, y: 0.0, width: bounds.width, height: headerHeight)
    profileHeaderMaskView.frame = profileHeaderContainer.bounds
    profileHeaderBlurView.frame = profileHeaderMaskView.bounds
    profileHeaderOverlayView.frame = profileHeaderBlurView.bounds
    profileHeaderMaskGradientLayer.frame = profileHeaderMaskView.bounds
    bringToFrontIfNeeded(profileHeaderContentView, in: profileHeaderContainer)
    profileHeaderContentView.frame = CGRect(
      x: 12.0, y: contentY, width: max(0.0, bounds.width - 24.0), height: 44.0)
    profileHeaderContentView.isUserInteractionEnabled = true

    profileBackGlassView.frame = CGRect(x: 0.0, y: 0.0, width: 44.0, height: 44.0)
    profileMenuGlassView.frame = CGRect(
      x: max(0.0, profileHeaderContentView.bounds.width - 44.0), y: 0.0, width: 44.0, height: 44.0)

    let profileReq = max(
      profileTitleLabel.intrinsicContentSize.width, profileSubtitleLabel.intrinsicContentSize.width)
    let profileCenterWidth = min(maxCenterWidth, max(160.0, profileReq + 36.0))
    let profileCenterFrame = CGRect(
      x: (profileHeaderContentView.bounds.width - profileCenterWidth) * 0.5,
      y: 0.0,
      width: profileCenterWidth,
      height: 44.0
    )
    profileHeaderStack.frame = profileCenterFrame.insetBy(dx: 12.0, dy: 4.0)

    profileBackButton.frame = profileBackGlassView.bounds
    profileMenuButton.frame = profileMenuGlassView.bounds

    [profileBackButton, profileMenuButton].forEach { control in
      control.layer.cornerRadius = control.bounds.height / 2.0
    }
    [profileBackGlassView, profileMenuGlassView].forEach { view in
      view.layer.cornerRadius = view.bounds.height / 2.0
    }
  }

  private func applyHeaderSearchPresentation() {
    if externalNavigationHeaderEnabled && !savedSearchExpanded {
      backGlassView.alpha = 0.0
      titleGlassView.alpha = 0.0
      menuGlassView.alpha = 0.0
      avatarGlassView.alpha = 0.0
      savedSearchCancelGlassView.alpha = 0.0
      savedSearchField.alpha = 0.0
      savedSearchField.isUserInteractionEnabled = false
      savedSearchCancelButton.isUserInteractionEnabled = false
      savedSearchCancelGlassView.isUserInteractionEnabled = false
      return
    }
    let searchActive = savedSearchExpanded && currentPage == .chat
    let controlsAlpha: CGFloat = searchActive ? 0.0 : 1.0

    if previewHeaderCompactLeading && !searchActive {
      backGlassView.alpha = 0.0
      menuGlassView.alpha = 0.0
      avatarGlassView.alpha = 1.0
      savedSearchCancelGlassView.alpha = 0.0
      savedSearchField.alpha = 0.0
      savedSearchField.isUserInteractionEnabled = false
      savedSearchCancelButton.isUserInteractionEnabled = false
      savedSearchCancelGlassView.isUserInteractionEnabled = false
      titleGlassView.alpha = 1.0
      chatHeaderStack.alpha = 1.0
      chatHeaderStack.transform = .identity
      return
    }

    if previewHeaderCenterOnly && !searchActive {
      backGlassView.alpha = 0.0
      menuGlassView.alpha = 0.0
      avatarGlassView.alpha = 0.0
      savedSearchCancelGlassView.alpha = 0.0
      savedSearchField.alpha = 0.0
      savedSearchField.isUserInteractionEnabled = false
      savedSearchCancelButton.isUserInteractionEnabled = false
      savedSearchCancelGlassView.isUserInteractionEnabled = false
      titleGlassView.alpha = 1.0
      chatHeaderStack.alpha = 1.0
      chatHeaderStack.transform = .identity
      return
    }

    backGlassView.alpha = controlsAlpha
    titleGlassView.alpha = controlsAlpha
    menuGlassView.alpha = (searchActive || (headerMode == .savedMessages && currentPage == .chat))
      ? 1.0
      : 0.0
    // Selection: avatar glass stays put; title content cross-fades in place.
    if selectionModeActive {
      avatarGlassView.alpha = 1.0
      avatarGlassView.transform = .identity
      chatHeaderStack.alpha = 0.0
      chatHeaderStack.transform = .identity
      selectionHeaderStack.alpha = 1.0
      selectionHeaderStack.transform = .identity
      titleGlassView.alpha = 1.0
      titleGlassView.transform = .identity
    } else {
      avatarGlassView.alpha = (currentPage == .chat && !searchActive) ? 1.0 : 0.0
      avatarGlassView.transform = .identity
      chatHeaderStack.alpha = controlsAlpha
      chatHeaderStack.transform = .identity
      selectionHeaderStack.alpha = 0.0
      selectionHeaderStack.transform = .identity
    }
    backGlassView.transform = .identity
    chatHeaderStack.transform = .identity
    savedSearchField.alpha = searchActive ? 1.0 : 0.0
    savedSearchCancelGlassView.alpha = searchActive ? 1.0 : 0.0
    savedSearchCancelButton.alpha = searchActive ? 1.0 : 0.0
    savedSearchField.isUserInteractionEnabled = searchActive
    savedSearchCancelButton.isUserInteractionEnabled = searchActive
    savedSearchCancelGlassView.isUserInteractionEnabled = searchActive
    savedSearchCancelGlassView.transform = searchActive
      ? .identity
      : CGAffineTransform(translationX: 16.0, y: 0.0)
  }

  private func setHeaderSearchExpanded(
    _ expanded: Bool,
    animated: Bool,
    emitPressed: Bool = false,
    emitDismissed: Bool = false
  ) {
    guard currentPage == .chat else {
      savedSearchExpanded = false
      savedSearchField.resignFirstResponder()
      savedSearchField.text = nil
      chatListView.setSearchModeActive(false)
      chatListView.setSearchQuery("")
      return
    }

    let applyUpdates = {
      self.savedSearchExpanded = expanded
      self.chatListView.setSearchModeActive(expanded)
      self.updateChatModeHeaderControls()
      self.layoutChrome()
    }

    if animated {
      UIView.animate(
        withDuration: 0.4,
        delay: 0.0,
        usingSpringWithDamping: 0.8,
        initialSpringVelocity: 0.2,
        options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
        animations: applyUpdates
      )
    } else {
      applyUpdates()
    }

    if expanded {
      if emitPressed {
        onNativeEvent(["type": "headerSearchPressed"])
      }
      DispatchQueue.main.async { [weak self] in
        self?.savedSearchField.becomeFirstResponder()
      }
    } else {
      savedSearchField.resignFirstResponder()
      savedSearchField.text = nil
      chatListView.setSearchQuery("")
      if emitDismissed {
        onNativeEvent(["type": "headerSearchDismissed"])
      }
    }
  }

  private func layoutPages() {
    let safeTop: CGFloat = (previewHeaderCenterOnly || previewHeaderCompactLeading)
      ? 0.0
      : (window?.safeAreaInsets.top ?? safeAreaInsets.top)
    let headerHeight =
      externalNavigationHeaderEnabled && !savedSearchExpanded
      ? 0.0
      : safeTop + 60.0
    let externalHeaderInset =
      externalNavigationHeaderEnabled && !savedSearchExpanded
      ? safeTop + 44.0
      : headerHeight
    let pinnedBannerVisible =
      pinnedBannerView.isHidden || pinnedBannerView.alpha <= 0.01
      ? false
      : true
    let pinnedBannerInset: CGFloat = pinnedBannerVisible
      ? (ChatPinnedBannerView.preferredHeight + 12.0)
      : 0.0
    let inboxBannerVisible = !(inboxBannerView.isHidden || inboxBannerView.alpha <= 0.01)
    let inboxBannerInset: CGFloat = inboxBannerVisible
      ? (ChatPinnedBannerView.preferredHeight + 12.0)
      : 0.0
    // The usage banner intentionally contributes NO inset here: it floats over the feed
    // below the header (see ChatListView.layoutBridgeUsageBanner), so showing/hiding it
    // never shifts the list content.
    chatListView.setContentPaddingTop(
      Double(externalHeaderInset + 8.0 + pinnedBannerInset + inboxBannerInset))
    pagesHost.frame = CGRect(
      x: 0.0,
      y: headerHeight,
      width: bounds.width,
      height: max(0.0, bounds.height - headerHeight)
    )

    let pageWidth = pagesHost.bounds.width
    let pageHeight = pagesHost.bounds.height

    // Extend chatPage upward behind the header so its wallpaper
    // layer covers the full screen — no gap with a mismatched gradient.
    chatPage.frame = CGRect(
      x: 0.0, y: -headerHeight,
      width: pageWidth, height: pageHeight + headerHeight)
    chatListView.frame = chatPage.bounds
    let bannerWidth = max(0.0, pageWidth - 32.0)
    pinnedBannerView.frame = CGRect(
      x: 16.0,
      y: externalHeaderInset + 8.0,
      width: bannerWidth,
      height: ChatPinnedBannerView.preferredHeight
    )
    bringToFrontIfNeeded(pinnedBannerView, in: chatPage)

    // Inbox banner stacks directly below the pinned banner (or in its slot when
    // there is no pinned message).
    let inboxBannerY =
      pinnedBannerInset > 0.0
      ? pinnedBannerView.frame.maxY + 8.0
      : externalHeaderInset + 8.0
    inboxBannerView.frame = CGRect(
      x: 16.0,
      y: inboxBannerY,
      width: bannerWidth,
      height: ChatPinnedBannerView.preferredHeight
    )
    bringToFrontIfNeeded(inboxBannerView, in: chatPage)

    if standaloneProfileMode {
      profilePage.frame = bounds
    } else {
      profilePage.frame = CGRect(
        x: 0.0, y: -headerHeight,
        width: pageWidth, height: pageHeight + headerHeight)
    }
    profileWallpaperLayer.frame = profilePage.bounds
    profileWallpaperPatternLayer.frame = profilePage.bounds
    profileWallpaperPatternMaskLayer.frame = profileWallpaperPatternLayer.bounds
    profileScrollView.frame = profilePage.bounds

    if standaloneProfileMode {
      agentPage.frame = bounds
    } else {
      agentPage.frame = CGRect(
        x: 0.0, y: -headerHeight,
        width: pageWidth, height: pageHeight + headerHeight)
    }
    agentScrollView.frame = agentPage.bounds
  }

  private func layoutProfileContent() {
    let width = max(1.0, profileScrollView.bounds.width)
    let headerHeight = (window?.safeAreaInsets.top ?? safeAreaInsets.top) + 60.0
    let sideInset: CGFloat = 16.0
    let textInset: CGFloat = 24.0

    profileContentView.frame = CGRect(x: 0.0, y: 0.0, width: width, height: 1.0)

    let avatarSize: CGFloat = 118.0
    profileAvatarView.frame = CGRect(
      x: (width - avatarSize) * 0.5, y: headerHeight + 30.0, width: avatarSize, height: avatarSize)
    profileAvatarView.layer.cornerRadius = avatarSize * 0.5
    profileAvatarNode.frame = profileAvatarView.bounds
    let onlineDotSize: CGFloat = 20.0
    profileOnlineDotView.frame = CGRect(
      x: profileAvatarView.bounds.width - onlineDotSize - 4.0,
      y: profileAvatarView.bounds.height - onlineDotSize - 4.0,
      width: onlineDotSize,
      height: onlineDotSize
    )
    profileOnlineDotView.layer.cornerRadius = onlineDotSize * 0.5
    profileOnlineDotView.layer.borderWidth = 3.0

    profileNameLabel.frame = CGRect(
      x: textInset, y: profileAvatarView.frame.maxY + 16.0, width: width - (textInset * 2),
      height: 38.0
    )
    profileHandleLabel.frame = CGRect(
      x: textInset, y: profileNameLabel.frame.maxY + 2.0, width: width - (textInset * 2),
      height: 24.0)

    let bioSize = profileBioLabel.sizeThatFits(
      CGSize(width: width - (textInset * 2), height: 200.0))
    let bioHeight = profileBioLabel.isHidden ? 0.0 : max(0.0, min(120.0, bioSize.height))
    profileBioLabel.frame = CGRect(
      x: textInset, y: profileHandleLabel.frame.maxY + 10.0, width: width - (textInset * 2),
      height: bioHeight)

    profileActionsStack.frame = CGRect(
      x: sideInset,
      y: profileBioLabel.frame.maxY + 18.0,
      width: width - 32.0,
      height: 64.0
    )

    profileIdentityCard.frame = CGRect(
      x: sideInset,
      y: profileActionsStack.frame.maxY + 18.0,
      width: width - 32.0,
      height: 62.0
    )
    profileIdentityCard.layer.cornerRadius = 24.0
    profileUsernameRow.frame = CGRect(
      x: 0.0, y: 0.0, width: profileIdentityCard.bounds.width, height: 62.0)

    var identityCardHeight: CGFloat = profileUsernameRow.frame.maxY
    let showsSecondaryIdentityRow =
      isGroupOrChannel || !profileBioText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if showsSecondaryIdentityRow {
      profileBioRow.isHidden = false
      profileBioRow.frame = CGRect(
        x: 0.0, y: identityCardHeight, width: profileIdentityCard.bounds.width,
        height: 62.0)
      identityCardHeight = profileBioRow.frame.maxY
    } else {
      profileBioRow.isHidden = true
      profileBioRow.frame = .zero
    }

    if !profileAgentRow.isHidden {
      profileAgentRow.frame = CGRect(
        x: 0.0, y: identityCardHeight, width: profileIdentityCard.bounds.width, height: 62.0)
      identityCardHeight = profileAgentRow.frame.maxY
    } else {
      profileAgentRow.frame = .zero
    }

    profileIdentityCard.frame.size.height = identityCardHeight

    var bottomAnchor = profileIdentityCard.frame.maxY

    let showTabsSection = !profileVisibleTabs.isEmpty || !profileSummaryHistoryLoaded
    if showTabsSection {
      profileTabsCard.isHidden = false
      profileTabContentContainer.isHidden = false

      profileTabsCard.frame = CGRect(
        x: sideInset,
        y: bottomAnchor + 18.0,
        width: width - 32.0,
        height: 50.0
      )
      profileTabsCard.layer.cornerRadius = 20.0

      profileTabsScrollView.frame = profileTabsCard.bounds.insetBy(dx: 6.0, dy: 6.0)
      let tabHeight = profileTabsScrollView.bounds.height
      var tabCursorX: CGFloat = 0.0
      for tab in profileVisibleTabs {
        guard let button = profileTabButtons[tab] else { continue }
        let title = "\(profileTabLabel(tab)) \(profileTabCount(tab))"
        let widthGuess = (title as NSString).size(withAttributes: [
          .font: UIFont.systemFont(ofSize: 16, weight: .medium)
        ]).width
        let buttonWidth = max(72.0, widthGuess + 32.0)
        button.frame = CGRect(x: tabCursorX, y: 0.0, width: buttonWidth, height: tabHeight)
        tabCursorX += buttonWidth + 6.0
      }
      profileTabsStack.frame = CGRect(
        x: 0.0, y: 0.0, width: max(profileTabsScrollView.bounds.width, tabCursorX),
        height: tabHeight)
      profileTabsScrollView.contentSize = CGSize(
        width: max(profileTabsScrollView.bounds.width, tabCursorX), height: tabHeight)

      profileTabContentContainer.frame = CGRect(
        x: sideInset,
        y: profileTabsCard.frame.maxY + 14.0,
        width: width - 32.0,
        height: 0.0
      )
      let tabContentHeight = reloadProfileTabContentIfNeeded(
        contentWidth: profileTabContentContainer.bounds.width)
      profileTabContentContainer.frame.size.height = tabContentHeight
      bottomAnchor = profileTabContentContainer.frame.maxY
    } else {
      profileTabsCard.isHidden = true
      profileTabContentContainer.isHidden = true
    }

    let totalHeight = bottomAnchor + 36.0
    profileContentView.frame = CGRect(x: 0.0, y: 0.0, width: width, height: totalHeight)
    profileScrollView.contentSize = CGSize(width: width, height: totalHeight)
  }

  private func layoutAgentContent() {
    let width = max(1.0, agentScrollView.bounds.width)
    let sideInset: CGFloat = 16.0
    let cardWidth = width - (sideInset * 2.0)
    let cardHeight = agentPromptNode.preferredHeight(for: cardWidth)
    let contentHeight = max(cardHeight + 36.0, agentScrollView.bounds.height)
    agentContentView.frame = CGRect(x: 0.0, y: 0.0, width: width, height: contentHeight)
    agentPromptNode.frame = CGRect(x: sideInset, y: 18.0, width: cardWidth, height: cardHeight)
    agentScrollView.contentSize = CGSize(width: width, height: agentContentView.bounds.height)
  }

  private func layoutProfileMembersContent() {
    profileMembersNode.frame = profilePage.bounds
    profileMembersNode.setTopInset(window?.safeAreaInsets.top ?? safeAreaInsets.top)
    syncProfileMembersLayoutState()
  }

  private func syncProfileMembersLayoutState() {
    profileMembersNode.syncPresentation(hostScrollView: profileScrollView)
  }

  private func setProfileMembersVisible(_ visible: Bool, animated: Bool) {
    if visible == profileMembersNode.isPresented { return }
    profileMembersNode.setPresented(visible, animated: animated, hostScrollView: profileScrollView)
    updateHeaderTexts()
  }

  private func applyTheme() {
    let text = appearance.textColorThem
    let secondary = appearance.timeColorThem.withAlphaComponent(0.85)
    let chatBackground = appearance.wallpaperBase
    let isDarkTheme = appearance.isDark
    let profileBackground = isDarkTheme ? Self.themeDarkBg : Self.themeLightBg
    let profileCardBg = isDarkTheme ? Self.themeDarkCard : Self.themeLightCard
    let actionBg = profileCardBg
    let rowSeparatorColor =
      isDarkTheme
      ? UIColor(white: 1.0, alpha: 0.16) : UIColor(white: 0.0, alpha: 0.08)
    let rowHighlightColor =
      isDarkTheme
      ? UIColor(white: 1.0, alpha: 0.06) : UIColor(white: 0.0, alpha: 0.04)

    backgroundColor = .clear
    // Gradient, pattern, mask and raster all live in the wallpaper view now.
    wallpaperView.apply(appearance)
    // Glass contentViews stay clear — system light/dark tint is on UIGlassEffect / mask only.
    // Do NOT use wallpaper or bubble colors here (that recolored chrome with list content).
    backGlassView.contentView.backgroundColor = .clear
    titleGlassView.contentView.backgroundColor = .clear
    avatarGlassView.contentView.backgroundColor = .clear
    menuGlassView.contentView.backgroundColor = .clear
    savedSearchCancelGlassView.contentView.backgroundColor = .clear
    rightActionsGlassView.contentView.backgroundColor = .clear
    // Glass chips: system style. Mask: chat-theme darkness + thick blur + pure black/tint.
    refreshHeaderGlass()

    profileHeaderContainer.backgroundColor = .clear
    profileHeaderBlurView.effect =
      UIBlurEffect(style: isDarkTheme ? .systemThinMaterialDark : .systemThinMaterialLight)
    profileHeaderOverlayView.backgroundColor =
      profileBackground.withAlphaComponent(isDarkTheme ? 0.42 : 0.72)
    profileBackGlassView.contentView.backgroundColor = profileCardBg.withAlphaComponent(0.68)
    profileMenuGlassView.contentView.backgroundColor = profileCardBg.withAlphaComponent(0.68)

    if selectionModeActive, selectionShowsClearChat {
      backButton.tintColor = .systemRed
    } else {
      backButton.tintColor = text
    }
    updateBackButtonContent()
    menuButton.tintColor =
      headerMode == .savedMessages
      ? secondary.withAlphaComponent(0.74)
      : text
    savedSearchField.textColor = text
    savedSearchField.tintColor = text
    savedSearchField.attributedPlaceholder = NSAttributedString(
      string: "Search messages...",
      attributes: [.foregroundColor: secondary.withAlphaComponent(0.58)]
    )
    savedSearchCancelButton.tintColor = text.withAlphaComponent(0.84)
    profileBackButton.tintColor = text
    profileMenuButton.tintColor = text
    
    let actionTint = text
    [callButton, videoCallButton, historyButton, newChatButton].forEach { btn in
      btn.tintColor = actionTint
    }
    // Selection Done is a filled blue circle with white check — never inherit text tint.
    applySelectionDoneBlueTint()
    
    chatTitleLabel.textColor = text
    profileTitleLabel.textColor = text
    chatSubtitleLabel.textColor = secondary
    profileSubtitleLabel.textColor = secondary
    selectionTitleLabel.textColor = text
    // Counter sits beside "Selected" — same weight/color for a single reading unit.
    selectionCountLabel.textColor = text
    pinnedBannerView.applyTheme(
      textColor: text,
      surfaceColor: chatBackground,
      isDark: isDarkTheme
    )
    inboxBannerView.applyTheme(
      textColor: text,
      surfaceColor: chatBackground,
      isDark: isDarkTheme
    )
    profilePage.backgroundColor = profileBackground
    profileScrollView.backgroundColor = profileBackground
    profileContentView.backgroundColor = profileBackground
    profileMembersNode.applyTheme(backgroundColor: profileBackground)
    agentPage.backgroundColor = profileBackground
    agentScrollView.backgroundColor = profileBackground
    agentContentView.backgroundColor = profileBackground
    applyProfileWallpaperAppearance()
    profileAvatarView.backgroundColor = .clear
    let profileGoldColor = UIColor(red: 244 / 255, green: 182 / 255, blue: 53 / 255, alpha: 1)
    profileNameLabel.textColor = bridgeProvider.isEmpty ? text : profileGoldColor
    applyPresenceTheme()
    profileBioLabel.textColor = secondary

    profileMuteButton.applyTheme(foreground: text, background: actionBg, isDark: isDarkTheme)
    profileSearchButton.applyTheme(foreground: text, background: actionBg, isDark: isDarkTheme)
    profileAudioCallButton.applyTheme(foreground: text, background: actionBg, isDark: isDarkTheme)
    profileVideoCallButton.applyTheme(foreground: text, background: actionBg, isDark: isDarkTheme)

    profileIdentityCard.backgroundColor = profileCardBg
    profileUsernameRow.applyTheme(
      titleColor: text,
      subtitleColor: secondary,
      separatorColor: rowSeparatorColor,
      highlightedColor: rowHighlightColor
    )
    profileBioRow.applyTheme(
      titleColor: text,
      subtitleColor: secondary,
      separatorColor: rowSeparatorColor,
      highlightedColor: UIColor.clear
    )

    profileTabsCard.backgroundColor = profileCardBg
    profileTabPlaceholderLabel.textColor = secondary
    applyProfileTabTheme()
    profileTabContentNeedsReload = true

    profileAgentRow.applyTheme(
      titleColor: text,
      subtitleColor: secondary,
      separatorColor: rowSeparatorColor,
      highlightedColor: rowHighlightColor
    )

    let accentColor =
      appearance.bubbleMeGradient.first ?? UIColor(red: 0.49, green: 0.36, blue: 0.88, alpha: 1.0)
    agentPromptNode.applyTheme(
      textColor: text,
      secondaryTextColor: secondary,
      surfaceColor: profileCardBg,
      accentColor: accentColor
    )
  }

  /// Presence-only styling (dot, border, handle color) — avoids full glass rebuilds on online/last-seen.
  private func applyPresenceTheme() {
    let secondary = appearance.timeColorThem.withAlphaComponent(0.85)
    let isDarkTheme = appearance.isDark
    let profileBackground = isDarkTheme ? Self.themeDarkBg : Self.themeLightBg
    let showsProfilePresence = shouldShowDirectPresence()
    profileOnlineDotView.isHidden = !showsProfilePresence
    profileOnlineDotView.backgroundColor =
      showsProfilePresence && isOnline
      ? UIColor(red: 83.0 / 255.0, green: 224.0 / 255.0, blue: 138.0 / 255.0, alpha: 1.0)
      : appearance.timeColorThem.withAlphaComponent(0.32)
    profileOnlineDotView.layer.borderColor = profileBackground.cgColor
    let profileGoldColor = UIColor(red: 244 / 255, green: 182 / 255, blue: 53 / 255, alpha: 1)
    if !bridgeProvider.isEmpty {
      profileHandleLabel.textColor = profileGoldColor.withAlphaComponent(0.92)
    } else if showsProfilePresence && isOnline {
      profileHandleLabel.textColor =
        UIColor(red: 83.0 / 255.0, green: 224.0 / 255.0, blue: 138.0 / 255.0, alpha: 1.0)
    } else {
      profileHandleLabel.textColor = secondary
    }
  }

  private func applyProfileWallpaperAppearance() {
    profileWallpaperLayer.colors = nil
    profileWallpaperLayer.locations = nil
    profileWallpaperLayer.opacity = 0.0
    profileWallpaperLayer.isHidden = true

    profileWallpaperPatternLayer.isHidden = true
    profileWallpaperPatternLayer.colors = nil
    profileWallpaperPatternLayer.locations = nil
    profileWallpaperPatternLayer.opacity = 0.0
    profileWallpaperPatternMaskLayer.contents = nil
  }


  private func updateHeaderTexts() {
    // Selection owns the title glass ("Select messages" / "Selected N").
    // Don't let Ready/typing presence rewrite the header mid-select.
    if selectionModeActive {
      updateSelectionTitleContent(count: selectionCount, animated: false)
      return
    }
    let bridgeHeaderConfiguration = resolvedBridgeHeaderConfiguration()
    let bridgeConfigurationSubtitle = activeBridgeConfigurationSubtitle(
      bridgeHeaderConfiguration)
    // The primary line is the stable agent identity. Model + effort + repository live
    // together below it and never compete with an asynchronously-updated chat topic.
    let resolvedTitle: String =
      if headerMode == .savedMessages {
        chatTitleText.isEmpty ? "Saved Messages" : chatTitleText
      } else if !isGroupOrChannel, !bridgeProvider.isEmpty {
        AgentBridgeSelectionStore.defaultModelTitle(provider: bridgeProvider)
      } else {
        chatTitleText.isEmpty ? "Chat" : chatTitleText
      }
    // A pending command/plan approval outranks everything else in the subtitle — the
    // agent is blocked on the user, which is the most actionable thing to surface.
    let resolvedApproval =
      (!bridgeProvider.isEmpty && agentAwaitingApproval) ? "Waiting for approval" : nil
    // The built-in VibeAgent transport owns a compact canonical activity state.
    // Its detailed progress-node label stays in the transcript and must never
    // replace Thinking/Working/Typing/Ready in the header.
    let resolvedAgentProgress =
      builtInAgentChatMode ? nil : resolvedAgentProgressSubtitle()
    // A History pick may briefly have no session metadata. Show Loading only during
    // that explicit fetch; once metadata arrives, model/repo replaces it—never topic.
    let historySessionLoading = chatListView.isBridgeHistorySessionLoading()
    let bridgeIdleAction: String? = {
      guard !bridgeProvider.isEmpty, headerMode != .savedMessages else { return nil }
      if historySessionLoading { return "Loading…" }
      return bridgeConfigurationSubtitle.isEmpty ? "Start session" : nil
    }()
    let resolvedDirectTyping = resolvedDirectTypingSubtitle()
    let groupTypingSubtitle = resolvedGroupTypingSubtitle()
    // Synced with Home principal: Connecting → Updating (spinner left + text).
    let connectionPhase =
      defersEngineStateRefreshes ? ConnectionHeaderPhase.none : resolvedConnectionHeaderPhase()
    let engineSubtitle = defersEngineStateRefreshes ? nil : resolvedEnginePresenceSubtitle()
    let trimmedSubtitle = chatSubtitleText.trimmingCharacters(in: .whitespacesAndNewlines)
    let subtitleLower = trimmedSubtitle.lowercased()
    let resolvedSubtitle: String
    if headerMode == .savedMessages {
      resolvedSubtitle = ""
    } else if let resolvedApproval {
      resolvedSubtitle = resolvedApproval
    } else if connectionPhase == .connecting {
      // Offline / socket down — never show "Updating" here.
      resolvedSubtitle = "Connecting"
    } else if connectionPhase == .updating,
      resolvedAgentProgress == nil,
      resolvedDirectTyping == nil,
      groupTypingSubtitle == nil
    {
      // List/history catch-up while connected; yield to live typing/agent work.
      resolvedSubtitle = "Updating"
    } else if isGroupOrChannel, let groupTypingSubtitle {
      // In a group the agents run in parallel, so surface "Claude & Codex typing…"
      // (all active participants) instead of a single agent's working/thinking label.
      // DMs keep the detailed agent-progress subtitle (the branch just below).
      resolvedSubtitle = groupTypingSubtitle
    } else if !isGroupOrChannel, !bridgeProvider.isEmpty, let bridgeIdleAction {
      resolvedSubtitle = bridgeIdleAction
    } else if !isGroupOrChannel, !bridgeProvider.isEmpty {
      resolvedSubtitle = bridgeConfigurationSubtitle
    } else if !isGroupOrChannel, bridgeProvider.isEmpty, let resolvedAgentProgress {
      resolvedSubtitle = resolvedAgentProgress
    } else if let resolvedDirectTyping {
      resolvedSubtitle = resolvedDirectTyping
    } else if let groupTypingSubtitle {
      resolvedSubtitle = groupTypingSubtitle
    } else if connectionPhase == .updating {
      resolvedSubtitle = "Updating"
    } else if let engineSubtitle {
      resolvedSubtitle = engineSubtitle
    } else if isOnline && shouldShowDirectPresence()
      && (trimmedSubtitle.isEmpty || subtitleLower.hasPrefix("last seen")
        || subtitleLower == "offline")
    {
      resolvedSubtitle = "online"
    } else if isGroupOrChannel {
      // At rest: singular/plural member/subscriber count. Typing + connection
      // already took precedence above.
      let countSubtitle = resolvedGroupMemberCountSubtitle()
      if !trimmedSubtitle.isEmpty,
        !Self.isGenericGroupRestSubtitle(trimmedSubtitle, isChannel: isChannel)
      {
        resolvedSubtitle = trimmedSubtitle
      } else {
        resolvedSubtitle = countSubtitle
      }
    } else if trimmedSubtitle.isEmpty
      && headerMode != .savedMessages
      && bridgeProvider.isEmpty
      && !enginePeerUserId.isEmpty
    {
      // shouldShowDirectPresence() stays closed until the peer has actually replied — that
      // gate is intentional (don't hand a stranger your precise online/last-seen status
      // before the conversation is mutual). But a totally empty subtitle reads as broken,
      // not private, so fall back to a vague "last seen recently" instead of real presence.
      resolvedSubtitle = "last seen recently"
    } else {
      resolvedSubtitle = trimmedSubtitle
    }

    setTextIfNeeded(chatTitleLabel, resolvedTitle)
    setTextIfNeeded(chatSubtitleLabel, resolvedSubtitle)
    // Line spinner + Connecting/Updating text — no status dot on connection chrome.
    // Spinner slot stays in layout (alpha only) so subtitle text doesn't jump.
    let showsConnectionChrome =
      connectionPhase != .none
      && (resolvedSubtitle == "Connecting" || resolvedSubtitle == "Updating")
    if showsConnectionChrome {
      chatConnectingSpinner.color = appearance.timeColorThem.withAlphaComponent(0.9)
      setHiddenIfNeeded(chatConnectingSpinner, false)
      chatConnectingSpinner.startAnimating()
      chatConnectingSpinner.alpha = 1
      setHiddenIfNeeded(chatSubtitleLabel, false)
      // Connection chrome: never show the bridge/status colored dot.
      setHiddenIfNeeded(chatSubtitleDotView, true)
      setSubtitleDotPulsing(false)
    } else {
      chatConnectingSpinner.stopAnimating()
      // Collapse the slot: an invisible spinner kept every subtitle indented
      // 15pt off the title's leading edge. The small text shift when
      // Connecting chrome appears is the lesser evil.
      setHiddenIfNeeded(chatConnectingSpinner, true)
      chatConnectingSpinner.alpha = 0
      setHiddenIfNeeded(chatSubtitleLabel, resolvedSubtitle.isEmpty)
    }

    let showsStableBridgeConfiguration =
      !isGroupOrChannel && !bridgeProvider.isEmpty && resolvedApproval == nil
        && !showsConnectionChrome && !bridgeConfigurationSubtitle.isEmpty
        && resolvedSubtitle == bridgeConfigurationSubtitle
    // The stable configuration matches the local CLI header and needs neither a status
    // dot nor shimmer, whether the session is active or idle. Approval/loading chrome
    // remains visually distinct.
    let showsBridgeDot =
      !showsConnectionChrome && !bridgeProvider.isEmpty && !resolvedSubtitle.isEmpty
        && !showsStableBridgeConfiguration
    if !showsConnectionChrome {
      setHiddenIfNeeded(chatSubtitleDotView, !showsBridgeDot)
      if showsBridgeDot {
        let dotColor: UIColor
        if resolvedApproval != nil {
          dotColor = UIColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1.0)
        } else if resolvedAgentProgress != nil || AgentPairingService.lastConnected {
          dotColor = UIColor(red: 83.0 / 255.0, green: 224.0 / 255.0, blue: 138.0 / 255.0, alpha: 1.0)
        } else {
          dotColor = UIColor(red: 1.0, green: 0.27, blue: 0.27, alpha: 1.0)
        }
        chatSubtitleDotView.backgroundColor = dotColor
        setSubtitleDotPulsing(resolvedApproval != nil)
      } else {
        setSubtitleDotPulsing(false)
      }
    }
    // A direct bridge header is deliberately static. Group typing remains animated.
    setSubtitleTextShimmering(isGroupOrChannel && groupTypingSubtitle != nil)

    setFontIfNeeded(
      chatSubtitleLabel,
      showsStableBridgeConfiguration
        ? UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        : UIFont.systemFont(ofSize: 12, weight: .medium))

    let headerStackSpacing: CGFloat = resolvedSubtitle.isEmpty ? 0.0 : -1.0
    if chatHeaderStack.spacing != headerStackSpacing {
      chatHeaderStack.spacing = headerStackSpacing
    }
    setTextIfNeeded(profileTitleLabel, profileNameText.isEmpty ? resolvedTitle : profileNameText)
    let profileSubtitle =
      isGroupOrChannel
      ? (isChannel ? "Channel Profile" : "Group Profile")
      : "Profile"
    setTextIfNeeded(profileSubtitleLabel, profileSubtitle)
    setHiddenIfNeeded(
      profileSubtitleLabel,
      profileSubtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    chatSubtitleLabel.textColor =
      {
        if headerMode == .savedMessages {
          return appearance.timeColorThem.withAlphaComponent(0.0)
        }
        if resolvedApproval != nil {
          return UIColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1.0)
        }
        if showsStableBridgeConfiguration {
          return appearance.timeColorThem.withAlphaComponent(0.85)
        }
        // Red/green is reserved for an actually-live session (progress streaming in) —
        // the idle "Start session" label and everything else below stays plain text, no
        // status color, so green doesn't leak onto a state that isn't live.
        if resolvedAgentProgress != nil {
          return AgentPairingService.lastConnected
            ? UIColor(red: 83.0 / 255.0, green: 224.0 / 255.0, blue: 138.0 / 255.0, alpha: 1.0)
            : UIColor(red: 1.0, green: 0.27, blue: 0.27, alpha: 1.0)
        }
        if resolvedDirectTyping != nil
          || groupTypingSubtitle != nil
          || (bridgeIdleAction == nil && isOnline && shouldShowDirectPresence())
        {
          return UIColor(red: 83.0 / 255.0, green: 224.0 / 255.0, blue: 138.0 / 255.0, alpha: 1.0)
        }
        if bridgeIdleAction != nil, resolvedSubtitle == bridgeIdleAction {
          return appearance.timeColorThem.withAlphaComponent(0.85)
        }
        if showsConnectionChrome {
          return appearance.timeColorThem.withAlphaComponent(0.9)
        }
        return appearance.timeColorThem.withAlphaComponent(0.85)
      }()
    if showsConnectionChrome {
      chatConnectingSpinner.color = chatSubtitleLabel.textColor
    }
  }

  private func resolvedBridgeHeaderConfiguration() -> (
    modelLabel: String?, effortLabel: String?, status: String?, repoLabel: String?
  ) {
    guard !bridgeProvider.isEmpty, headerMode != .savedMessages else {
      return (nil, nil, nil, nil)
    }
    let visible = chatListView.visibleBridgeRunConfiguration(provider: bridgeProvider)
    let historyScoped = chatListView.bridgeHistorySessionId() != nil
    let options = AgentBridgeSelectionStore.selectedRunOptions(provider: bridgeProvider)
    let modelCandidates: [String?] = historyScoped
      ? [bridgeSessionModel, visible.model]
      : [visible.model, options.model]
    let concreteModel = modelCandidates.lazy.compactMap(concreteBridgeModel).first
    if let concreteModel {
      bridgeLastKnownRealModel = concreteModel
    }
    let model = concreteModel ?? bridgeLastKnownRealModel
    let effort: String? = {
      if historyScoped { return bridgeSessionReasoningEffort ?? visible.reasoningEffort }
      if let reported = visible.reasoningEffort { return reported }
      return AgentBridgeRunOptions.effectiveEffort(
        provider: bridgeProvider,
        intelligence: options.intelligence,
        speed: options.speed
      )
    }()
    let modelLabel: String? = model.map { concreteModel in
      var label = AgentBridgeSelectionStore.modelTitle(
        provider: bridgeProvider, model: concreteModel)
      if bridgeProvider == "claude", label.lowercased().hasPrefix("claude ") {
        label = String(label.dropFirst("Claude ".count))
      }
      return label
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: " ", with: "-")
    }
    let effortLabel = effort
      .flatMap(AgentBridgeIntelligenceLevel.fromProviderEffort)
      .map { level in (level == .extraHigh ? "xhigh" : level.title.lowercased()) }

    let selectedRepo = AgentBridgeSelectionStore.selectedRepository(chatId: engineChatId)
    let repoName = historyScoped
      ? firstNonEmptyHeaderValue(bridgeSessionProjectName, visible.repoName, selectedRepo?.name)
      : firstNonEmptyHeaderValue(visible.repoName, selectedRepo?.name)
    let cwd = historyScoped
      ? firstNonEmptyHeaderValue(bridgeSessionProjectPath, visible.cwd, selectedRepo?.cwd, selectedRepo?.path)
      : firstNonEmptyHeaderValue(visible.cwd, selectedRepo?.cwd, selectedRepo?.path)
    let repoLabel = compactBridgeRepositoryLabel(repoName: repoName, cwd: cwd)
    return (modelLabel, effortLabel, visible.status, repoLabel)
  }

  private func activeBridgeConfigurationSubtitle(
    _ configuration: (
      modelLabel: String?, effortLabel: String?, status: String?, repoLabel: String?
    )
  ) -> String {
    let primary = [configuration.modelLabel, configuration.effortLabel]
      .compactMap { value -> String? in
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
      }
      .joined(separator: " ")
    let repo = configuration.repoLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !primary.isEmpty && !repo.isEmpty { return "\(primary) · \(repo)" }
    if !primary.isEmpty { return primary }
    if !repo.isEmpty { return repo }
    return ""
  }

  /// Provider labels are identity fallbacks, not model ids. Treating one as a model
  /// lets a sparse late snapshot regress `opus-4.8 max · ~/Vibe` back to `claude max`.
  private func concreteBridgeModel(_ rawValue: String?) -> String? {
    let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !value.isEmpty else { return nil }
    let normalized = value.lowercased()
    let providerFallback = AgentBridgeSelectionStore.defaultModelTitle(provider: bridgeProvider)
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized != bridgeProvider.lowercased(), normalized != providerFallback,
      normalized != "default", normalized != "auto"
    else {
      return nil
    }
    return value
  }

  private func firstNonEmptyHeaderValue(_ values: String?...) -> String? {
    for value in values {
      let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !trimmed.isEmpty { return trimmed }
    }
    return nil
  }

  private func compactBridgeRepositoryLabel(repoName: String?, cwd: String?) -> String? {
    let path = cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let home = NSHomeDirectory().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if !path.isEmpty {
      let normalized = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      if normalized == home { return "~" }
      if normalized.hasPrefix(home + "/") {
        return "~/" + String(normalized.dropFirst(home.count + 1))
      }
    }
    let name = repoName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !name.isEmpty { return "~/\(name)" }
    guard !path.isEmpty else { return nil }
    let leaf = URL(fileURLWithPath: path).lastPathComponent
    return leaf.isEmpty ? path : leaf
  }

  /// Drives the header's leading status dot: a soft breathing opacity loop while the
  /// agent is doing something live, a steady dot otherwise.
  private func setSubtitleDotPulsing(_ pulsing: Bool) {
    guard pulsing else {
      chatSubtitleDotView.layer.removeAnimation(forKey: "pulse")
      chatSubtitleDotView.layer.opacity = 1.0
      return
    }
    guard chatSubtitleDotView.layer.animation(forKey: "pulse") == nil else { return }
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = 1.0
    animation.toValue = 0.3
    animation.duration = 0.6
    animation.autoreverses = true
    animation.repeatCount = .infinity
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    chatSubtitleDotView.layer.add(animation, forKey: "pulse")
  }

  /// Whether the subtitle should be shimmering — the actual mask/animation is (re)applied
  /// from `layoutChrome()` against the label's real post-layout bounds, same as
  /// `subtitleShimmerActive` drives `applySubtitleShimmerFrame()`.
  private var subtitleShimmerActive = false

  /// Sweeps a gradient mask across the subtitle label while live agent progress is showing
  /// ("Thinking…" etc.) — the exact same shimmer the chat list uses for the "thinking" /
  /// `agent_progress_tree` typing row (see the `messageLabel.layer.mask` block in
  /// `ChatListCell` in ChatListViewCells.swift), just retargeted at this label.
  private func setSubtitleTextShimmering(_ shimmering: Bool) {
    subtitleShimmerActive = shimmering
    guard shimmering else {
      chatSubtitleLabel.layer.mask = nil
      return
    }
    if !(chatSubtitleLabel.layer.mask is CAGradientLayer) {
      let gradientLayer = CAGradientLayer()
      let shimmerColor = appearance.isDark ? UIColor.black : UIColor.white
      let baseColor = shimmerColor.withAlphaComponent(0.35).cgColor
      let highlightColor = shimmerColor.withAlphaComponent(1.0).cgColor
      gradientLayer.colors = [
        baseColor,
        baseColor,
        highlightColor,
        baseColor,
        baseColor,
      ]
      gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
      gradientLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
      chatSubtitleLabel.layer.mask = gradientLayer
    }
    applySubtitleShimmerFrame()
  }

  /// Re-syncs the shimmer mask to the label's current bounds — must run after
  /// `chatHeaderStack` has actually laid out (bounds are wrong/zero right after just setting
  /// text, which is why the old intrinsicContentSize-based sizing produced a broken/invisible
  /// shimmer). Called from `layoutChrome()` every layout pass, matching how the chat list
  /// re-applies its shimmer frame on every cell layout rather than once.
  private func applySubtitleShimmerFrame() {
    guard subtitleShimmerActive,
      let mask = chatSubtitleLabel.layer.mask as? CAGradientLayer,
      chatSubtitleLabel.bounds.width > 0
    else { return }
    
    let labelWidth = chatSubtitleLabel.bounds.width
    let bandWidth: CGFloat = 80.0
    // Make the mask wide enough so it always covers the label during translation
    let maskWidth = max(labelWidth * 3.0 + bandWidth * 3.0, 500.0)
    
    // Calculate the fractional width of the band relative to the huge mask
    let halfBand = (bandWidth / 2.0) / maskWidth
    mask.locations = [
      0.0,
      NSNumber(value: 0.5 - halfBand),
      0.5,
      NSNumber(value: 0.5 + halfBand),
      1.0
    ]
    
    mask.frame = CGRect(x: 0, y: 0, width: maskWidth, height: chatSubtitleLabel.bounds.height)
    
    // We want the center of the mask (which is at maskWidth / 2) to sweep from 0 to labelWidth.
    // We add some padding so the highlight band fully enters and exits the text.
    let sweepStart = -maskWidth / 2.0 - bandWidth
    let sweepEnd = labelWidth - maskWidth / 2.0 + bandWidth
    
    let animation = CABasicAnimation(keyPath: "transform.translation.x")
    animation.fromValue = sweepStart
    animation.toValue = sweepEnd
    animation.duration = 1.5
    animation.repeatCount = .infinity
    animation.isRemovedOnCompletion = false
    mask.add(animation, forKey: "shimmerTranslation")
  }

  private func updateBackButtonContent() {
    let title = headerUnreadCount > 0 ? "\(min(headerUnreadCount, 99))" : nil
    // Match the agent view's header back button exactly: a plain system button with a
    // template image + optional count title. Using UIButton.Configuration here made the
    // icon read larger and added the automatic press "bounce"/scale that lingered on
    // pop — the classic setImage/setTitle path has neither.
    backButton.configuration = nil
    backButton.setImage(UIImage(systemName: "chevron.backward"), for: .normal)
    backButton.setPreferredSymbolConfiguration(
      UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold), forImageIn: .normal)
    backButton.setTitle(title, for: .normal)
    backButton.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
    backButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: title == nil ? 0 : 2, bottom: 0, right: 0)
    backButton.accessibilityLabel =
      headerUnreadCount > 0
      ? "Back, \(headerUnreadCount) unread messages"
      : "Back"
  }

  private func updateProfileTexts() {
    let resolvedTitle = chatTitleText.isEmpty ? "Chat" : chatTitleText
    profileNameLabel.text = profileNameText.isEmpty ? resolvedTitle : profileNameText
    if isGroupOrChannel {
      let fallbackGroupHandle = resolvedGroupMemberCountSubtitle()
      profileHandleLabel.text = profileHandleText.isEmpty ? fallbackGroupHandle : profileHandleText
    } else {
      let fallbackHandle =
        shouldShowDirectPresence()
        ? (resolvedEnginePresenceSubtitle() ?? (isOnline ? "online" : "offline"))
        : ""
      profileHandleLabel.text =
        profileHandleText.isEmpty ? fallbackHandle : profileHandleText
    }
    profileBioLabel.text = profileBioText
    profileBioLabel.isHidden =
      profileBioText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    profileMuteButton.setTitle(isChatMuted ? "Unmute" : "Mute")

    if isGroupOrChannel {
      let showsAgentRow = standaloneProfileMode && isGroupOrChannel
      profileUsernameRow.configure(
        title: isChannel ? "Subscribers" : "Members",
        subtitle: resolvedGroupMembersRowSubtitle(),
        titleColor: appearance.bubbleMeGradient.last ?? appearance.textColorMe,
        showsSeparator: true,
        iconName: "person.3.fill",
        iconTintColor: appearance.textColorMe.withAlphaComponent(0.9),
        iconBackgroundColor: appearance.bubbleThemColor.withAlphaComponent(0.45)
      )
      profileBioRow.configure(
        title: "Live status",
        subtitle: resolvedGroupTypingSubtitle() ?? "No one typing right now",
        titleColor: nil,
        showsSeparator: showsAgentRow,
        iconName: "waveform.path.ecg",
        iconTintColor: appearance.textColorThem.withAlphaComponent(0.95),
        iconBackgroundColor: appearance.bubbleThemColor.withAlphaComponent(0.35)
      )

      let agentName = normalizedAgentString(agentConfig?["name"]) ?? "Vibe AI"
      let enabled = normalizedAgentEnabledValue(agentConfig?["enabled"], defaultValue: false)
      let docsCount = getAgentDocuments().count
      let docsLabel = docsCount == 1 ? "1 file" : "\(docsCount) files"
      let stateLabel = enabled ? "Enabled" : "Disabled"
      profileAgentRow.configure(
        title: "Configuration",
        subtitle: "\(stateLabel) • \(agentName) • \(docsLabel)",
        titleColor: nil,
        showsSeparator: false,
        iconName: "slider.horizontal.3",
        iconTintColor: appearance.textColorThem.withAlphaComponent(0.95),
        iconBackgroundColor: appearance.bubbleThemColor.withAlphaComponent(0.35)
      )
    } else {
      let goldProfileColor = UIColor(red: 244 / 255, green: 182 / 255, blue: 53 / 255, alpha: 1)
      let usernameRowSubtitle: String
      if profileHandleText.isEmpty {
        usernameRowSubtitle =
          "@\(resolvedTitle.replacingOccurrences(of: " ", with: "").lowercased())"
      } else if profileHandleText.lowercased().hasPrefix("id:") {
        usernameRowSubtitle = profileHandleText
      } else if profileHandleText.hasPrefix("@") {
        usernameRowSubtitle = profileHandleText
      } else {
        usernameRowSubtitle = "@\(profileHandleText)"
      }
      let hasBioRow = !profileBioText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      profileUsernameRow.configure(
        title: "Username",
        subtitle: usernameRowSubtitle,
        titleColor: bridgeProvider.isEmpty
          ? (appearance.bubbleMeGradient.last ?? appearance.textColorMe)
          : goldProfileColor,
        showsSeparator: hasBioRow,
        iconName: "at",
        iconTintColor: (bridgeProvider.isEmpty ? appearance.textColorMe : goldProfileColor)
          .withAlphaComponent(0.95),
        iconBackgroundColor: appearance.bubbleThemColor.withAlphaComponent(0.35)
      )
      profileBioRow.configure(
        title: "Bio",
        subtitle: hasBioRow ? profileBioText : "No bio",
        titleColor: nil,
        showsSeparator: false,
        iconName: "text.quote",
        iconTintColor: appearance.textColorThem.withAlphaComponent(0.95),
        iconBackgroundColor: appearance.bubbleThemColor.withAlphaComponent(0.35)
      )

      profileAgentRow.configure(
        title: "AI Agent",
        subtitle: "Available in group profile",
        titleColor: nil,
        showsSeparator: false,
        iconName: "sparkles",
        iconTintColor: appearance.textColorThem.withAlphaComponent(0.95),
        iconBackgroundColor: appearance.bubbleThemColor.withAlphaComponent(0.35)
      )
    }

    let agentDocs = getAgentDocuments().map { (id: $0.id, name: $0.name) }
    agentPromptNode.configure(chatId: engineChatId, config: agentConfig, documents: agentDocs)

    rebuildProfileTabs()
    profileTabContentNeedsReload = true
    setNeedsLayout()
  }

  private func resolvedGroupMemberCount() -> Int {
    if let groupMemberCount, groupMemberCount > 0 { return groupMemberCount }
    return Set(groupMemberOrder + groupTypingUserIds.map { $0.uppercased() }).count
  }

  /// Singular/plural rest subtitle for groups/channels.
  private func resolvedGroupMemberCountSubtitle() -> String {
    let count = resolvedGroupMemberCount()
    if isChannel {
      if count == 1 { return "1 subscriber" }
      return "\(count) subscribers"
    }
    if count == 1 { return "1 member" }
    return "\(count) members"
  }

  /// Host may seed a generic "channel"/"group" label; prefer live count instead.
  private static func isGenericGroupRestSubtitle(_ text: String, isChannel: Bool) -> Bool {
    let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if lower.isEmpty { return true }
    if isChannel {
      return lower == "channel" || lower == "subscribers" || lower == "0 subscribers"
    }
    return lower == "group" || lower == "group chat" || lower == "members" || lower == "0 members"
  }

  private func resolvedGroupMemberDisplayName(_ normalizedUserId: String) -> String {
    if normalizedUserId.starts(with: "00000000-0000-0000-0000-000000000001")
      || normalizedUserId == "SYSTEM"
    {
      return (agentConfig?["name"] as? String) ?? "Vibe "
    }
    if let explicit = groupMemberDisplayNameByUserId[normalizedUserId],
      !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return explicit
    }
    if !enginePeerUserId.isEmpty, normalizedUserId == enginePeerUserId, !profileNameText.isEmpty {
      return profileNameText
    }
    if normalizedUserId.count > 8 {
      return String(normalizedUserId.prefix(8))
    }
    return normalizedUserId
  }

  private func resolvedGroupTypingSubtitle() -> String? {
    let normalizedTypingUsers = Array(Set(groupTypingUserIds.map { $0.uppercased() }))
    guard !normalizedTypingUsers.isEmpty else { return nil }
    // Keep the subtitle short and STABLE: first names only, in a fixed provider order
    // (Claude, Codex, Grok, Agy, then humans alphabetically). No model suffix here —
    // during a fan-out the typing set changes constantly, and a label that swaps
    // content/width on every change reads as flicker, not status.
    // 3+ typers → "Claude, Codex +2 typing…".
    let names: [String] =
      normalizedTypingUsers
      .compactMap { id -> (rank: Int, name: String)? in
        var name =
          groupMemberDisplayNameByUserId[id]?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty {
          name = resolvedGroupMemberDisplayName(id)
        }
        guard !name.isEmpty else { return nil }
        // Short display: first token only ("Claude Code" → "Claude").
        let shortName = name.split(separator: " ").first.map(String.init) ?? name
        let rank: Int =
          switch id {
          case "11111111-1111-1111-1111-111111111111": 0  // claude
          case "22222222-2222-2222-2222-222222222222": 1  // codex
          case "33333333-3333-3333-3333-333333333333": 2  // grok
          case "44444444-4444-4444-4444-444444444444": 3  // agy
          default: 4
          }
        return (rank, shortName)
      }
      .sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.name < $1.name }
      .map(\.name)

    switch names.count {
    case 0:
      return "typing…"
    case 1:
      return "\(names[0]) typing…"
    case 2:
      return "\(names[0]) & \(names[1]) typing…"
    default:
      // Cap at two named agents; remainder as +N.
      return "\(names[0]), \(names[1]) +\(names.count - 2) typing…"
    }
  }

  private func resolvedDirectTypingSubtitle() -> String? {
    guard !isGroupOrChannel, directPeerTypingActive else { return nil }
    return "typing..."
  }

  private func resolvedAgentProgressSubtitle() -> String? {
    let trimmed = agentProgressSubtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Collapses the bridge's per-tool progress label — which can carry a full shell
  /// command, file path, or search query for on-device context — into one of a handful
  /// of user-facing verbs. The chat header shows what Claude/Codex is doing in general
  /// terms, never the raw tool payload.
  private static func friendlyAgentProgressLabel(rawLabel: String?, tool: String?) -> String? {
    let label = (rawLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let tool = (tool ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !label.isEmpty || !tool.isEmpty else { return nil }

    func matches(_ needles: [String]) -> Bool {
      needles.contains { tool.contains($0) || label.contains($0) }
    }

    // Live thinking carries its streamed token counter ("Thinking · 1.2k tokens") — keep
    // it verbatim; it's the one label meant to tick in real time like the desktop CLI,
    // and a token count is not on-device context.
    if label.hasPrefix("thinking"), label.contains("token") {
      return (rawLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    if matches(["approval", "awaiting", "permission"]) { return "Waiting for approval" }
    if matches(["error", "fail"]) { return "Hit an error" }
    if matches(["bash", "shell", "command", "exec"]) { return "Running…" }
    if matches(["read", "grep", "glob", "search", "fetch", "look"]) { return "Reading…" }
    if matches(["write", "edit", "patch", "notebook"]) { return "Editing…" }
    if matches(["think", "reason", "plan"]) { return "Thinking…" }
    return "Working…"
  }

  private func resolvedGroupMembersRowSubtitle() -> String {
    var seen = Set<String>()
    var orderedUserIds: [String] = []
    for rawId in groupMemberOrder {
      let normalized = rawId.uppercased()
      if seen.insert(normalized).inserted {
        orderedUserIds.append(normalized)
      }
    }
    let labels = orderedUserIds.map { resolvedGroupMemberDisplayName($0) }
    let totalCount = max(resolvedGroupMemberCount(), labels.count)
    let countLabel: String = {
      if isChannel {
        return totalCount == 1 ? "1 subscriber" : "\(totalCount) subscribers"
      }
      return totalCount == 1 ? "1 member" : "\(totalCount) members"
    }()
    guard !labels.isEmpty else {
      if totalCount > 0 { return countLabel }
      return isChannel ? "No subscribers" : "No members"
    }
    let shown = labels.prefix(5)
    let suffix = labels.count > shown.count ? " +\(labels.count - shown.count)" : ""
    return "\(countLabel): \(shown.joined(separator: ", "))\(suffix)"
  }

  private func shouldShowDirectPresence() -> Bool {
    headerMode != .savedMessages
      && bridgeProvider.isEmpty
      && !isGroupOrChannel
      && !enginePeerUserId.isEmpty
      && hasPeerResponseInCurrentRows
  }

  private static func rowsContainPeerResponse(
    _ rows: [[String: Any]],
    peerUserId: String
  ) -> Bool {
    let normalizedPeer = peerUserId.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !normalizedPeer.isEmpty else { return false }
    return rows.contains { row in
      let message = (row["message"] as? [String: Any]) ?? row
      if boolValue(message["isMe"]) == false {
        return true
      }
      let fromId = normalizedString(message["fromId"] ?? message["from_id"])?.uppercased()
      return fromId == normalizedPeer
    }
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }

  private static func boolValue(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String {
      switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "1", "true", "yes", "on":
        return true
      case "0", "false", "no", "off":
        return false
      default:
        return nil
      }
    }
    return nil
  }

  private func resolvedEnginePresenceSubtitle() -> String? {
    guard shouldShowDirectPresence() else { return nil }
    if isOnline { return "online" }
    guard let lastSeen = engineLastSeenTimestampMs else { return "last seen recently" }
    return Self.formatLastSeenSubtitle(lastSeen)
  }

  private enum ConnectionHeaderPhase {
    case none
    case connecting
    case updating
  }

  /// Connecting only for network-off / blocked-to-server. Updating for history catch-up.
  /// Bootstrap / mid-configure must not flash "Connecting".
  private func resolvedConnectionHeaderPhase() -> ConnectionHeaderPhase {
    if isOfflineOrBlockedToServerForHeader() {
      return .connecting
    }
    if isHistoryOrCatchUpUpdating() {
      return .updating
    }
    return .none
  }

  private func isEngineConnectedForHeader() -> Bool {
    let status = ChatEngine.shared.getStatus()
    if (status["connected"] as? Bool) == true { return true }
    let stateValue =
      (status["state"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    return stateValue == "native-socket-open" || stateValue == "connected-shadow"
  }

  private func isOfflineOrBlockedToServerForHeader() -> Bool {
    if isEngineConnectedForHeader() { return false }
    let status = ChatEngine.shared.getStatus()
    let stateValue =
      (status["state"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    // A closed/configuring chat socket is not proof that the device cannot reach the
    // service: Home may be healthy over HTTP/LAN while no chat topic currently demands
    // a socket. Treating those bootstrap states as network failure made every otherwise
    // healthy header say "Connecting". Only the transport's explicit offline verdict is
    // allowed to replace presence; history catch-up has its separate "Updating" phase.
    return stateValue == "offline"
  }

  /// True while history / session payload is applying for this chat (Updating only).
  private func isHistoryOrCatchUpUpdating() -> Bool {
    if chatListView.isBridgeHistorySessionLoading() { return true }
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    if !chatId.isEmpty, ChatEngine.shared.isChatHistoryLoading(chatId: chatId) {
      return true
    }
    return isHistoryLoadingSpinnerActive()
  }

  private func isHistoryLoadingSpinnerActive() -> Bool {
    false
  }



  /// Relative last-seen for the chat header. Clock time lives on messages, not here.
  static func formatLastSeenSubtitle(_ timestampMs: Int64) -> String {
    guard timestampMs > 0 else { return "last seen recently" }
    let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
    let now = Date()
    if now.timeIntervalSince(date) < 60 {
      return "last seen just now"
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    let relative = formatter.localizedString(for: date, relativeTo: now)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !relative.isEmpty else { return "last seen recently" }
    return "last seen \(relative)"
  }

  private func updateAvatarViews() {
    let descriptor = ChatAvatarDescriptor(
      title: builtInAgentChatMode ? profileNameText : chatTitleText,
      rawAvatarURI: avatarUri,
      peerUserId: enginePeerUserIdRaw,
      chatId: engineChatId,
      kind: headerMode == .savedMessages ? .savedMessages : .standard,
      isGroup: isGroupOrChannel,
      members: groupAvatarMembers,
      preferPushAvatar: !isGroupOrChannel,
      gradientColors: headerMode == .savedMessages ? nil : userAvatarGradientColors()
    )
    avatarNode.configure(with: descriptor, isDark: appearance.isDark, renderingSide: 36)
    profileAvatarNode.configure(with: descriptor, isDark: appearance.isDark, renderingSide: 118)
  }

  private static func color(fromHex hex: String) -> UIColor? {
    var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
    hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

    var rgb: UInt64 = 0
    guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

    let r, g, b, a: CGFloat
    if hexSanitized.count == 6 {
      r = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
      g = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
      b = CGFloat(rgb & 0x0000FF) / 255.0
      a = 1.0
    } else if hexSanitized.count == 8 {
      r = CGFloat((rgb & 0xFF000000) >> 24) / 255.0
      g = CGFloat((rgb & 0x00FF0000) >> 16) / 255.0
      b = CGFloat((rgb & 0x0000FF00) >> 8) / 255.0
      a = CGFloat(rgb & 0x000000FF) / 255.0
    } else {
      return nil
    }
    return UIColor(red: r, green: g, blue: b, alpha: a)
  }

  private func userAvatarGradientColors() -> (UIColor, UIColor) {
    if appearance.isDark {
      if let start = avatarGradientStartDark, let startColor = Self.color(fromHex: start),
         let end = avatarGradientEndDark, let endColor = Self.color(fromHex: end) {
        return (startColor, endColor)
      }
    } else {
      if let start = avatarGradientStartLight, let startColor = Self.color(fromHex: start),
         let end = avatarGradientEndLight, let endColor = Self.color(fromHex: end) {
        return (startColor, endColor)
      }
    }

    return ChatProfileAppearanceStore.avatarColors(
      title: chatTitleText,
      peerUserId: enginePeerUserIdRaw,
      chatId: engineChatId
    )
  }

  // MARK: - In-place agent runtime host

  /// `fromLayout` marks the call made by `layoutSubviews`: chrome is already laid out and
  /// header text is owned by state setters, so re-running either would re-dirty this pass.
  private func applyPageState(animated: Bool, emitEvent: Bool, fromLayout: Bool = false) {
    if !fromLayout {
      updateHeaderTexts()
    }

    if standaloneProfileMode {
      currentPage = .profile
      headerContainer.alpha = 0.0
      headerContainer.isUserInteractionEnabled = false
      profileHeaderContainer.isHidden = false
      profileHeaderContainer.alpha = 1.0
      profileHeaderContainer.isUserInteractionEnabled = true
      profileHeaderStack.transform = .identity
      profileMenuGlassView.alpha = 1.0
      profilePage.isHidden = false
      profilePage.alpha = 1.0
      profilePage.transform = .identity
      agentPage.isHidden = true
      agentPage.alpha = 0.0
      agentPage.transform = .identity
      pinnedBannerView.alpha = 0.0
      inboxBannerView.alpha = 0.0
      avatarGlassView.alpha = 0.0
      bringToFrontIfNeeded(profileHeaderContainer)
      applyHeaderGlassMorph(chatFactor: 0.0)
      if emitEvent {
        onNativeEvent(["type": "mainPageChanged", "page": currentPage.rawValue])
      }
      return
    }

    if currentPage != .chat {
      currentPage = .chat
    }

    let width = pagesHost.bounds.width
    let profileOffscreenRight = CGAffineTransform(translationX: width, y: 0.0)
    let profileOffscreenLeft = CGAffineTransform(translationX: -width, y: 0.0)
    let agentOffscreenRight = CGAffineTransform(translationX: width, y: 0.0)

    let isChat = currentPage == .chat
    let isProfile = currentPage == .profile
    let isAgent = currentPage == .agent

    if !isProfile && profileMembersNode.isPresented {
      setProfileMembersVisible(false, animated: false)
    }

    let chatHeaderAlpha: CGFloat = isChat ? 1.0 : 0.0
    let profileHeaderAlpha: CGFloat = isChat ? 0.0 : 1.0
    let avatarAlpha: CGFloat = isChat ? 1.0 : 0.0
    let menuAlpha: CGFloat = (isChat && headerMode == .savedMessages) ? 1.0 : 0.0
    let chatHeaderTransform =
      isChat
      ? CGAffineTransform.identity : CGAffineTransform(translationX: -14.0, y: 0.0)
    let profileHeaderTransform =
      isChat
      ? CGAffineTransform(translationX: 14.0, y: 0.0) : CGAffineTransform.identity

    if !isChat && profilePage.isHidden {
      profilePage.transform = isAgent ? profileOffscreenLeft : profileOffscreenRight
      profilePage.alpha = 1.0
      profilePage.isHidden = false
      profileHeaderContainer.isHidden = false
      bringToFrontIfNeeded(profileHeaderContainer)
    }
    if isAgent && agentPage.isHidden {
      agentPage.transform = agentOffscreenRight
      agentPage.alpha = 1.0
      agentPage.isHidden = false
      profileHeaderContainer.isHidden = false
      bringToFrontIfNeeded(profileHeaderContainer)
    }

    headerContainer.isUserInteractionEnabled = isChat
    profileHeaderContainer.isUserInteractionEnabled = !isChat

    let profileTargetTransform =
      isChat
      ? profileOffscreenRight
      : (isProfile ? CGAffineTransform.identity : profileOffscreenLeft)
    let agentTargetTransform = isAgent ? CGAffineTransform.identity : agentOffscreenRight

    let apply = {
      if !fromLayout {
        self.layoutChrome()
      }
      if isChat {
        self.bringToFrontIfNeeded(self.headerContainer)
      } else {
        self.bringToFrontIfNeeded(self.profileHeaderContainer)
      }
      self.profilePage.transform = profileTargetTransform
      self.agentPage.transform = agentTargetTransform
      self.headerContainer.alpha = chatHeaderAlpha
      self.profileHeaderContainer.alpha = profileHeaderAlpha
      self.chatHeaderStack.alpha = 1.0
      self.profileHeaderStack.alpha = 1.0
      self.chatHeaderStack.transform = chatHeaderTransform
      self.profileHeaderStack.transform = profileHeaderTransform
      self.avatarGlassView.alpha = avatarAlpha
      self.menuGlassView.alpha = menuAlpha
      self.savedSearchCancelGlassView.alpha =
        (isChat && self.savedSearchExpanded) ? 1.0 : 0.0
      self.pinnedBannerView.alpha = (isChat && !self.pinnedBannerView.isHidden) ? 1.0 : 0.0
      self.inboxBannerView.alpha = (isChat && !self.inboxBannerView.isHidden) ? 1.0 : 0.0
      self.profileMenuGlassView.alpha = isProfile ? 1.0 : 0.0
      self.applyHeaderGlassMorph(chatFactor: isChat ? 1.0 : 0.0)
      self.applyHeaderSearchPresentation()
    }

    if animated {
      UIView.animate(
        withDuration: 0.34,
        delay: 0.0,
        usingSpringWithDamping: 0.9,
        initialSpringVelocity: 0.32,
        options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction],
        animations: apply
      ) { _ in
        if isChat {
          self.profilePage.isHidden = true
          self.profilePage.alpha = 0
          self.agentPage.isHidden = true
          self.agentPage.alpha = 0
          self.profileHeaderContainer.isHidden = true
        } else if isProfile {
          self.profilePage.isHidden = false
          self.profilePage.alpha = 1.0
          self.agentPage.isHidden = true
          self.agentPage.alpha = 0.0
          self.profileHeaderContainer.isHidden = false
        } else {
          self.profilePage.isHidden = true
          self.profilePage.alpha = 0.0
          self.agentPage.isHidden = false
          self.agentPage.alpha = 1.0
          self.profileHeaderContainer.isHidden = false
        }
      }
    } else {
      apply()
      if isChat {
        profilePage.isHidden = true
        profilePage.alpha = 0.0
        agentPage.isHidden = true
        agentPage.alpha = 0.0
        profileHeaderContainer.isHidden = true
      } else if isProfile {
        profilePage.isHidden = false
        profilePage.alpha = 1.0
        agentPage.isHidden = true
        agentPage.alpha = 0.0
        profileHeaderContainer.isHidden = false
      } else {
        profilePage.isHidden = true
        profilePage.alpha = 0.0
        agentPage.isHidden = false
        agentPage.alpha = 1.0
        profileHeaderContainer.isHidden = false
      }
    }

    if emitEvent {
      onNativeEvent(["type": "mainPageChanged", "page": currentPage.rawValue])
    }
  }

  @objc private func handleProfileSwipeBack(_ gesture: UIScreenEdgePanGestureRecognizer) {
    guard currentPage == .profile || gesture.state == .changed else { return }
    let width = max(1.0, pagesHost.bounds.width)
    let translationX = gesture.translation(in: self).x

    switch gesture.state {
    case .began:
      profileSwipeStartProgress = max(0.0, min(1.0, profilePage.transform.tx / width))
      applyInteractiveProfileSwipe(progress: profileSwipeStartProgress)
    case .changed:
      let progress = max(0.0, min(1.0, profileSwipeStartProgress + (translationX / width)))
      applyInteractiveProfileSwipe(progress: progress)
    case .ended, .cancelled, .failed:
      let progress = max(0.0, min(1.0, profilePage.transform.tx / width))
      let velocityX = gesture.velocity(in: self).x
      let shouldClose = progress > 0.33 || velocityX > 640.0
      profileSwipeStartProgress = 0.0
      if shouldClose {
        markPendingNativePageChange(.chat)
        currentPage = .chat
        applyPageState(animated: true, emitEvent: true)
      } else {
        currentPage = .profile
        applyPageState(animated: true, emitEvent: false)
      }
    default:
      break
    }
  }

  private func applyInteractiveProfileSwipe(progress: CGFloat) {
    let clamped = max(0.0, min(1.0, progress))
    let width = max(1.0, pagesHost.bounds.width)
    profilePage.isHidden = false
    profileHeaderContainer.isHidden = false
    profilePage.transform = CGAffineTransform(translationX: width * clamped, y: 0.0)
    headerContainer.alpha = clamped
    profileHeaderContainer.alpha = 1.0 - clamped
    chatHeaderStack.transform = CGAffineTransform(translationX: -14.0 * (1.0 - clamped), y: 0.0)
    profileHeaderStack.transform = CGAffineTransform(translationX: 14.0 * clamped, y: 0.0)
    avatarGlassView.alpha = clamped
    menuGlassView.alpha = 0.0
    savedSearchCancelGlassView.alpha = 0.0
    headerContainer.isUserInteractionEnabled = false
    profileHeaderContainer.isUserInteractionEnabled = false
    applyHeaderGlassMorph(chatFactor: clamped)
  }

  private func applyHeaderGlassMorph(chatFactor: CGFloat) {
    let clamped = max(0.0, min(1.0, chatFactor))
    titleGlassView.transform = CGAffineTransform(
      translationX: 10.0 * (1.0 - clamped),
      y: 0.0
    )
    avatarGlassView.transform = .identity
    menuGlassView.transform = .identity
    savedSearchCancelGlassView.transform = .identity
    profileBackGlassView.transform = .identity
    profileMenuGlassView.transform = .identity
  }

  override public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer)
    -> Bool
  {
    if gestureRecognizer === profileSwipeBackGesture {
      if profileMembersNode.isPresented { return false }
      if standaloneProfileMode { return false }
      return currentPage == .profile
    }
    return true
  }

  func clearMessageSelection(animated: Bool = true) {
    chatListView.clearMessageSelection(animated: animated)
  }

  func applyPendingForwardDraft(title: String, preview: String) {
    chatListView.applyPendingForwardDraft(title: title, preview: preview)
  }

  @objc private func handleBackPressed() {
    if selectionModeActive {
      if selectionShowsClearChat {
        // Direct chat: left trash → functional Clear Chat (engine + server).
        handleSelectionClearChatPressed()
      } else {
        chatListView.clearMessageSelection()
      }
      return
    }
    if profileMembersNode.isPresented {
      setProfileMembersVisible(false, animated: true)
      return
    }
    if standaloneProfileMode && currentPage == .agent {
      currentPage = .profile
      applyPageState(animated: true, emitEvent: false)
      return
    }
    onNativeEvent(["type": "headerBack"])
  }

  @objc private func handleAvatarPressed() {
    if selectionModeActive {
      // Avatar is inert in selection — Done (checkmark) or Cancel (X) exit mode.
      return
    }
    guard headerMode != .savedMessages else { return }
    guard currentPage == .chat else { return }
    onNativeEvent(["type": "headerAvatarPressed"])
  }

  /// Bridge chats repurpose the title/subtitle tap for session history. The
  /// built-in VibeAgent uses it for model selection. Avatar taps remain the
  /// identity/profile route in both cases.
  @objc private func handleTitlePressed() {
    if selectionModeActive {
      return
    }
    guard headerMode != .savedMessages else { return }
    guard currentPage == .chat else { return }
    if !bridgeProvider.isEmpty {
      onNativeEvent(["type": "agentSessionPressed", "provider": bridgeProvider])
    } else if builtInAgentChatMode {
      onNativeEvent(["type": "agentModelPressed"])
    } else {
      onNativeEvent(["type": "headerAvatarPressed"])
    }
  }

  @objc private func handlePrimaryTrailingActionPressed() {
    if ownedStandaloneAgentMode {
      onNativeEvent(["type": "headerAvatarPressed"])
    } else {
      onNativeEvent(["type": "headerAudioCallPressed"])
    }
  }

  @objc private func handleHistoryPressed() {
    // Built-in Vibe AI: conversation History (server + local chat ids).
    if builtInAgentChatMode {
      onNativeEvent(["type": "agentHistoryPressed"])
      return
    }
    // Agent DM: single provider. Multi-agent group: pick among member agents first
    // (or open the only one). History must open the report/session conversation.
    if !bridgeProvider.isEmpty {
      chatListView.presentBridgeHistorySurface(provider: bridgeProvider)
      return
    }
    chatListView.presentGroupBridgeHistorySurface()
  }

  @objc private func handleNewChatPressed() {
    // Built-in Vibe AI: start a blank conversation; prior chats stay in History.
    if builtInAgentChatMode {
      onNativeEvent(["type": "agentNewChatPressed"])
      return
    }
    chatListView.startNewBridgeSession()
    // Drop the History-session title so the idle header returns to "Start session"
    // instead of the previous pick's topic / "Loading…".
    if bridgeSessionTopic != nil {
      bridgeSessionTopic = nil
    }
    bridgeSessionModel = nil
    bridgeLastKnownRealModel = nil
    bridgeSessionReasoningEffort = nil
    bridgeSessionProjectName = nil
    bridgeSessionProjectPath = nil
    updateHeaderTexts()
    // A history session can be opened while the bridge-connect gate owns the input
    // state. Starting a fresh session from that already-connected chat must restore
    // the native composer; otherwise the view is left as an unusable blank surface.
    chatListView.setInputBarEnabled(true)
    chatListView.setNativeSendEnabled(true)
  }

  @objc private func handleMenuPressed() {
    if currentPage == .chat && savedSearchExpanded {
      setHeaderSearchExpanded(false, animated: true, emitDismissed: true)
      return
    }
    if headerMode == .savedMessages && currentPage == .chat {
      if savedSearchExpanded {
        savedSearchField.becomeFirstResponder()
      } else {
        setHeaderSearchExpanded(true, animated: true, emitPressed: true)
      }
      return
    }
    guard currentPage == .profile else { return }
    guard let presenter = topMostViewController() else { return }

    let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
    sheet.addAction(
      UIAlertAction(title: "Search in Chat", style: .default) { [weak self] _ in
        self?.onNativeEvent(["type": "headerSearchPressed"])
      })
    let muteTitle = isChatMuted ? "Unmute" : "Mute"
    sheet.addAction(
      UIAlertAction(title: muteTitle, style: .default) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "muteToggle"])
      })
    sheet.addAction(
      UIAlertAction(title: "Clear Chat", style: .destructive) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "clearChat"])
      })
    sheet.addAction(
      UIAlertAction(title: "Block User", style: .destructive) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "blockUser"])
      })
    sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

    if let popover = sheet.popoverPresentationController {
      let sourceButton = profileHeaderContainer.isHidden ? menuButton : profileMenuButton
      popover.sourceView = sourceButton
      popover.sourceRect = sourceButton.bounds
      popover.permittedArrowDirections = [.up, .down]
    }
    presenter.present(sheet, animated: true)
  }

  @objc private func handleProfileUsernamePressed() {
    onNativeEvent([
      "type": "profileUsernamePressed",
      "handle": profileHandleText,
      "openMembers": isGroupOrChannel,
    ])
  }

  @objc private func handleProfileMutePressed() {
    onNativeEvent(["type": "headerMenuAction", "action": "muteToggle"])
  }

  @objc private func handleProfileSearchPressed() {
    onNativeEvent(["type": "headerSearchPressed"])
  }

  @objc private func handleSavedSearchTextChanged() {
    chatListView.setSearchQuery(savedSearchField.text ?? "")
    onNativeEvent([
      "type": "headerSearchChanged",
      "text": savedSearchField.text ?? "",
    ])
  }

  @objc private func handleSavedSearchCancelPressed() {
    savedSearchField.text = nil
    onNativeEvent(["type": "headerSearchChanged", "text": ""])
    setHeaderSearchExpanded(false, animated: true, emitDismissed: true)
  }

  public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    if textField === savedSearchField {
      textField.resignFirstResponder()
      return true
    }
    return false
  }

  @objc private func handleProfileAudioCallPressed() {
    onNativeEvent(["type": "headerAudioCallPressed"])
  }

  @objc private func handleProfileVideoCallPressed() {
    onNativeEvent(["type": "headerVideoCallPressed"])
  }

  @objc private func handleAgentRowTapped() {
    onNativeEvent(["type": "headerAgentPressed"])
  }


  // MARK: - Agent Config

  func agentPromptNode(
    _ node: ChatMainProfileAgentPromptNode, didUpdateConfig config: [String: Any]
  ) {
    applyAgentConfigUpdate(config)
  }

  func agentPromptNodeDidRequestDelete(_ node: ChatMainProfileAgentPromptNode) {
    applyAgentConfigDeletion()
  }

  func agentPromptNodeDidRequestFullEditor(_ node: ChatMainProfileAgentPromptNode) {
    presentAgentConfigEditor()
  }

  func setIsGroupOrChannel(_ value: Bool) {
    isGroupOrChannel = value
    if !value { isChannel = false }
    chatListView.setIsGroupOrChannel(value)
    refreshAgentCardVisibility()
    if !defersEngineStateRefreshes {
      scheduleEngineStateRefresh(force: true, reason: "setIsGroupOrChannel")
    }
    updateHeaderTexts()
    updateProfileTexts()
    updateAvatarViews()
  }

  func setChannelShareLink(_ value: String) {
    chatListView.setChannelShareLink(value)
  }

  /// Broadcast channel vs multi-member group. Forwarded so History loading can
  /// pick skeleton (channel) vs modern spinner (direct / group).
  func setIsChannel(_ value: Bool) {
    let next = value && isGroupOrChannel
    let changed = isChannel != next
    isChannel = next
    chatListView.setIsChannel(next)
    if changed {
      updateHeaderTexts()
      updateProfileTexts()
    }
  }

  private func getAgentDocuments() -> [(id: String, name: String, url: String)] {
    return profileFileItems.compactMap { item in
      let url = item.mediaUrl ?? ""
      if url.contains("/agent/document/") || url.contains("/agent-docs/") {
        return (id: item.messageId, name: item.fileName, url: url)
      }
      return nil
    }
  }

  private func refreshAgentCardVisibility() {
    let shouldShow = standaloneProfileMode && isGroupOrChannel
    if !shouldShow && currentPage == .agent {
      currentPage = .profile
      applyPageState(animated: false, emitEvent: false)
    }
    if profileAgentRow.isHidden == !shouldShow { return }
    profileAgentRow.isHidden = !shouldShow
    setNeedsLayout()
  }

  private func fetchAgentConfigForCurrentChat() {
    let currentId = engineChatId
    guard !currentId.isEmpty, currentId != "saved_messages" else { return }
    guard isGroupOrChannel else {
      if agentConfig != nil {
        agentConfig = nil
        updateProfileTexts()
        setNeedsLayout()
      }
      return
    }
    ChatEngine.shared.fetchAgentConfig(chatId: currentId) { [weak self] config in
      guard let self = self, self.engineChatId == currentId else { return }
      let normalized = self.normalizedAgentConfig(config, fallbackChatId: currentId)
      self.agentConfig = normalized
      self.updateProfileTexts()
      self.setNeedsLayout()
    }
  }

  private func applyAgentConfigUpdate(_ config: [String: Any]) {
    guard let normalized = normalizedAgentConfig(config, fallbackChatId: engineChatId) else {
      return
    }
    let currentId = engineChatId
    ChatEngine.shared.saveAgentConfig(chatId: currentId, config: normalized) {
      [weak self] success in
      guard let self = self, self.engineChatId == currentId else { return }
      if success {
        self.agentConfig = normalized
        self.updateProfileTexts()
        self.setNeedsLayout()
        self.fetchAgentConfigForCurrentChat()
      } else {
        print("[ChatMainView] Failed to save agent config natively")
      }
    }
  }

  private func applyAgentConfigDeletion() {
    let currentId = engineChatId
    ChatEngine.shared.deleteAgentConfig(chatId: currentId) { [weak self] success in
      guard let self = self, self.engineChatId == currentId else { return }
      if success {
        self.agentConfig = nil
        self.updateProfileTexts()
        self.setNeedsLayout()
      } else {
        print("[ChatMainView] Failed to delete agent config natively")
      }
    }
  }

  private func presentAgentConfigEditor() {
    guard standaloneProfileMode, isGroupOrChannel else { return }
    setProfileMembersVisible(false, animated: false)
    currentPage = .agent
    applyPageState(animated: true, emitEvent: false)
    setNeedsLayout()

    let currentId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !currentId.isEmpty else { return }
  }

  private func normalizedAgentConfig(_ config: [String: Any]?, fallbackChatId: String)
    -> [String: Any]?
  {
    guard let config else { return nil }
    var normalized: [String: Any] = [:]

    let resolvedChatId =
      normalizedAgentString(config["chat_id"]) ?? normalizedAgentString(config["chatId"])
      ?? fallbackChatId
    normalized["chat_id"] = resolvedChatId

    if let resolvedName = normalizedAgentString(config["name"]) {
      normalized["name"] = resolvedName
    } else {
      normalized["name"] = "Vibe AI"
    }

    let resolvedPrompt =
      normalizedAgentString(config["system_prompt"]) ?? normalizedAgentString(
        config["systemPrompt"])
      ?? ""
    normalized["system_prompt"] = resolvedPrompt

    normalized["enabled"] = normalizedAgentEnabledValue(config["enabled"], defaultValue: true)
    let enabledTools =
      normalizedAgentToolList(config["enabled_tools"])
      ?? normalizedAgentToolList(config["enabledTools"])
    if let enabledTools, !enabledTools.isEmpty {
      normalized["enabled_tools"] = enabledTools
    }

    if let existingId = normalizedAgentString(config["id"]), !existingId.isEmpty {
      normalized["id"] = existingId
    } else if let existingId = config["id"] {
      normalized["id"] = existingId
    }

    if let avatar = normalizedAgentString(config["avatar_url"])
      ?? normalizedAgentString(config["avatarUrl"])
    {
      normalized["avatar_url"] = avatar
    }
    if let createdBy = normalizedAgentString(config["created_by"])
      ?? normalizedAgentString(config["createdBy"])
    {
      normalized["created_by"] = createdBy
    }

    return normalized
  }

  private func normalizedAgentString(_ rawValue: Any?) -> String? {
    if let string = rawValue as? String {
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let number = rawValue as? NSNumber {
      return number.stringValue
    }
    return nil
  }

  private func normalizedAgentEnabledValue(_ rawValue: Any?, defaultValue: Bool) -> Bool {
    guard let rawValue else { return defaultValue }
    if let boolValue = rawValue as? Bool { return boolValue }
    if let numberValue = rawValue as? NSNumber { return numberValue.boolValue }
    if let stringValue = rawValue as? String {
      switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "true", "1", "yes", "on":
        return true
      case "false", "0", "no", "off":
        return false
      default:
        break
      }
    }
    return defaultValue
  }

  private func normalizedAgentToolList(_ rawValue: Any?) -> [String]? {
    guard let rawArray = rawValue as? [Any] else { return nil }
    let normalized =
      rawArray
      .compactMap { value -> String? in
        if let text = value as? String {
          let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
          return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
          return number.stringValue
        }
        return nil
      }
    return normalized
  }

  private func createHistoryIcon(strokeWidth: CGFloat = 1.8) -> UIImage {
    let size = CGSize(width: 24, height: 24)
    let scale = 24.0 / 64.0
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { context in
      let cgContext = context.cgContext
      cgContext.setLineWidth(strokeWidth)
      cgContext.setLineCap(.round)
      cgContext.setLineJoin(.round)
      UIColor.black.setStroke()
      
      let center = CGPoint(x: 35.6 * scale, y: 30.73 * scale)
      let radius: CGFloat = 21.91 * scale
      
      let path = UIBezierPath()
      path.addArc(withCenter: center, radius: radius, startAngle: CGFloat.pi / 2.0, endAngle: CGFloat.pi, clockwise: false)
      cgContext.addPath(path.cgPath)
      cgContext.strokePath()
      
      let arrow = UIBezierPath()
      arrow.move(to: CGPoint(x: 5.79 * scale, y: 21.06 * scale))
      arrow.addLine(to: CGPoint(x: 13.67 * scale, y: 31.35 * scale))
      arrow.addLine(to: CGPoint(x: 23.96 * scale, y: 23.48 * scale))
      cgContext.addPath(arrow.cgPath)
      cgContext.strokePath()
      
      let hands = UIBezierPath()
      hands.move(to: CGPoint(x: 34.95 * scale, y: 14.04 * scale))
      hands.addLine(to: CGPoint(x: 34.95 * scale, y: 32.35 * scale))
      hands.addLine(to: CGPoint(x: 43.26 * scale, y: 38.72 * scale))
      cgContext.addPath(hands.cgPath)
      cgContext.strokePath()
    }.withRenderingMode(.alwaysTemplate)
  }

  /// Minimal two-stroke menu used for an owned agent's settings route. Drawn in
  /// Core Graphics so it stays template-tintable and keeps true rounded 1.5pt
  /// strokes instead of borrowing a three-line or filter-shaped SF Symbol.
  private func createAgentSettingsMenuIcon() -> UIImage {
    let size = CGSize(width: 22, height: 22)
    let format = UIGraphicsImageRendererFormat()
    format.opaque = false
    format.scale = window?.screen.scale ?? traitCollection.displayScale
    return UIGraphicsImageRenderer(size: size, format: format).image { context in
      let cgContext = context.cgContext
      cgContext.setStrokeColor(UIColor.black.cgColor)
      cgContext.setLineWidth(1.5)
      cgContext.setLineCap(.round)
      cgContext.move(to: CGPoint(x: 3.0, y: 7.5))
      cgContext.addLine(to: CGPoint(x: 19.0, y: 7.5))
      cgContext.move(to: CGPoint(x: 3.0, y: 14.5))
      cgContext.addLine(to: CGPoint(x: 19.0, y: 14.5))
      cgContext.strokePath()
    }.withRenderingMode(.alwaysTemplate)
  }

  private func topMostViewController() -> UIViewController? {
    guard
      let root =
        window?.rootViewController
        ?? UIApplication.shared.connectedScenes
        .compactMap({ scene -> UIViewController? in
          guard let windowScene = scene as? UIWindowScene else { return nil }
          return windowScene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        })
        .first
    else { return nil }
    var top = root
    while let presented = top.presentedViewController {
      top = presented
    }
    return top
  }
}
