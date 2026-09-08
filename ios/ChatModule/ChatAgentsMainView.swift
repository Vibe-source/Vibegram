import SwiftUI
import UIKit

/// One row identity contract for both list synthesis and edit-mode selection.
/// An agent without a DM yet still needs a stable id before the server creates
/// its first chat.
private func chatAgentsRowID(for card: ChatListRow.AgentCard) -> String {
  card.attachedChats.first(where: {
    ($0.type ?? "dm").lowercased() == "dm"
  })?.chatId ?? "agent-pending:\(card.agentId)"
}

/// Shared edit-mode/selection state for the Agents tab's list, owned by the
/// hosting UIKit controller (its nav-bar "Edit" button flips `isEditing`) and
/// read by the SwiftUI list below — the same split Home itself uses between
/// its own nav chrome and `ChatHomeNativeListController`.
final class ChatAgentsListEditState: ObservableObject {
  @Published var isEditing = false
  @Published var selectedAgentIDs = Set<String>()
}

/// Renders the Agents tab's list by feeding synthesized rows into Home's own
/// `ChatHomeNativeListRepresentable` — real reuse of `ChatHomeCardCell`, its
/// swipe-reveal physics, and the long-press hold-preview morph, not a parallel
/// reimplementation of any of that. `ChatHomeListRow.isOwnedAgent` is the only
/// row-shape difference (swaps Pin/Read for a single Settings swipe action).
/// Search uses Home's exact in-list header via `searchText` (table header,
/// not a safe-area sibling). Placement matches Home: ignore container safe
/// area so the native list owns one top inset (nav + search band), no second
/// SwiftUI band.
struct ChatAgentsNativeListView: View {
  let cards: [ChatListRow.AgentCard]
  let isDark: Bool
  /// Same solid as the Agents root / Home palette background so the table
  /// dissolve surface and empty scroll gaps never flash a different color.
  let listBackground: UIColor
  @ObservedObject var editState: ChatAgentsListEditState
  var searchText: Binding<String>
  let onOpenAgentChat: (ChatListRow.AgentCard) -> Void
  let onOpenSettings: (ChatListRow.AgentCard) -> Void
  let onDeleteAgent: (ChatListRow.AgentCard, @escaping () -> Void) -> Void
  let onBulkDelete: () -> Void
  let onToast: (String) -> Void
  let onRefresh: () async -> Void

  var body: some View {
    let mapped = Self.makeRows(from: cards)
    ZStack {
      ChatHomeNativeListRepresentable(
        rows: mapped.rows,
        isDark: isDark,
        isEditing: editState.isEditing,
        showsRightCheckmark: false,
        selectedChatIDs: editState.selectedAgentIDs,
        searchText: searchText,
        inlineSearchInteraction: true,
        searchDissolveBackground: listBackground,
        onSelect: { row in
          guard let card = mapped.byRowID[row.chatId] else { return }
          if editState.isEditing {
            toggleSelection(row.chatId)
          } else {
            onOpenAgentChat(card)
          }
        },
        onToggleSelection: { chatId in
          toggleSelection(chatId)
        },
        onAction: { action, row in
          guard let card = mapped.byRowID[row.chatId] else { return }
          if case .delete = action {
            onDeleteAgent(card) {}
          }
        },
        onSettingsAction: { row in
          guard let card = mapped.byRowID[row.chatId] else { return }
          onOpenSettings(card)
        },
        onRefresh: onRefresh,
        onUnavailableAction: onToast
      )
      // Match Home's listContent: the native controller owns nav+search insets.
      .ignoresSafeArea(.container, edges: [.top, .bottom])

      // Home edit chrome: fixed bottom pill band (tab bar only fades). Agents
      // only need Delete — same placement / glass style as ChatHomeEditActionBar.
      if editState.isEditing {
        VStack {
          Spacer(minLength: 0)
          ChatAgentsEditActionBar(
            selectedCount: editState.selectedAgentIDs.count,
            isDark: isDark,
            onDelete: onBulkDelete
          )
          .padding(.bottom, 20)
        }
        .ignoresSafeArea(.container, edges: .bottom)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .zIndex(2)
      }
    }
    .animation(.easeInOut(duration: 0.22), value: editState.isEditing)
    .background(Color(uiColor: listBackground).ignoresSafeArea())
  }

  private func toggleSelection(_ chatId: String) {
    if editState.selectedAgentIDs.contains(chatId) {
      editState.selectedAgentIDs.remove(chatId)
    } else {
      editState.selectedAgentIDs.insert(chatId)
    }
  }

  private static func makeRows(
    from cards: [ChatListRow.AgentCard]
  ) -> (rows: [ChatHomeListRow], byRowID: [String: ChatListRow.AgentCard]) {
    var byRowID: [String: ChatListRow.AgentCard] = [:]
    let rows = cards.map { card -> ChatHomeListRow in
      let row = makeRow(from: card)
      byRowID[row.chatId] = card
      return row
    }
    return (rows, byRowID)
  }

  private static func makeRow(from card: ChatListRow.AgentCard) -> ChatHomeListRow {
    // Reuse the real 1:1 DM chatId when one already exists (so the hold-preview
    // morph shows the agent's real recent messages, unmodified) — an agent
    // nobody has messaged yet gets a synthetic placeholder id instead, since
    // no chat has been created server-side for it.
    let chatId = chatAgentsRowID(for: card)
    var row = ChatHomeListRow(
      chatId: chatId,
      title: card.displayName,
      preview: card.username.map { "@\($0)" } ?? card.status.capitalized,
      timeLabel: "",
      unreadCount: 0,
      markedUnread: false,
      muted: false,
      pinned: false,
      archived: false,
      isTyping: false,
      isOnline: false,
      peerUserId: card.agentUserId,
      avatarUri: card.avatarUrl,
      avatarFallback: ChatHomeCardCell.getFallbackInitials(from: card.displayName),
      avatarGradientStartLight: nil,
      avatarGradientEndLight: nil,
      avatarGradientStartDark: nil,
      avatarGradientEndDark: nil,
      isSavedMessages: false,
      isArchiveEntry: false,
      type: "dm",
      isGroup: false,
      isAgentFriend: true,
      peerAgentId: card.agentId,
      agentEventInboxMode: card.eventInboxMode,
      peerTier: nil,
      previewRows: [],
      initialMessages: [],
      members: []
    )
    row.isOwnedAgent = true
    return row
  }
}

/// Home-matching bottom edit pill band (Delete only — agents have no mute/read).
private struct ChatAgentsEditActionBar: View {
  let selectedCount: Int
  let isDark: Bool
  let onDelete: () -> Void

  private var enabled: Bool { selectedCount > 0 }

  var body: some View {
    HStack {
      Spacer(minLength: 0)
      Button {
        guard enabled else { return }
        onDelete()
      } label: {
        Text(selectedCount > 0 ? "Delete (\(selectedCount))" : "Delete")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(
            (isDark ? Color.white : Color.primary).opacity(enabled ? 1.0 : 0.38)
          )
          .padding(.horizontal, 18)
          .padding(.vertical, 10)
          .background {
            if #available(iOS 26.0, *) {
              Capsule(style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.interactive(true), in: .capsule)
            } else {
              Capsule(style: .continuous)
                .fill(.regularMaterial)
            }
          }
      }
      .buttonStyle(.plain)
      .allowsHitTesting(enabled)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
  }
}

/// Root page for the Agents tab. UIKit owns navigation chrome (including the
/// compact filter menu); SwiftUI bridges rows into Home's native list, which
/// owns Home's exact in-list search header via `searchText`.
final class ChatAgentsMainViewController: UIViewController {
  private static let filterTitles = ["All", "Active", "Disabled"]
  private static let vectorIconPointSize: CGFloat = 22

  private let apiContext: ChatNativeAgentConfigAPIContext
  /// Re-read on theme changes. Both were `let`, so this screen kept whatever appearance
  /// was current when the Agents tab was built at launch and never followed a switch.
  private var appearance: ChatListAppearance
  private var theme: ChatNativeAgentConfigTheme
  private let showsCloseButton: Bool
  private let editState = ChatAgentsListEditState()
  private let skeletonView: ChatNativeAgentSkeletonView
  private let emptyStateView: ChatNativeAgentEmptyStateView

  private var listHostingController: UIHostingController<ChatAgentsNativeListView>?
  private var editBarButtonItem: UIBarButtonItem?
  private var addBarButtonItem: UIBarButtonItem?
  private var filterBarButtonItem: UIBarButtonItem?
  /// Source of truth from the server; `cards` is its search/filter projection.
  private var allCards: [ChatListRow.AgentCard] = []
  private var cards: [ChatListRow.AgentCard] = []
  private var searchQuery = ""
  private var selectedFilterIndex = 0
  private var activeTask: URLSessionDataTask?

  var onToast: ((String) -> Void)?
  var onCreateAgent: (() -> Void)?
  var onOpenAgentChat: ((ChatListRow.AgentCard) -> Void)?
  var onDeleteAgent: ((ChatListRow.AgentCard, @escaping () -> Void) -> Void)?

  /// Home trailing chrome tint: pure white / black, not brand accent.
  private var chromeTint: UIColor {
    theme.isDark ? .white : .black
  }

  init(
    apiContext: ChatNativeAgentConfigAPIContext,
    appearance: ChatListAppearance,
    showsCloseButton: Bool = true
  ) {
    self.apiContext = apiContext
    self.appearance = appearance
    self.showsCloseButton = showsCloseButton
    self.theme = ChatNativeAgentConfigTheme(appearance: appearance)
    self.skeletonView = ChatNativeAgentSkeletonView(
      theme: ChatNativeAgentConfigTheme(appearance: appearance)
    )
    self.emptyStateView = ChatNativeAgentEmptyStateView(
      theme: ChatNativeAgentConfigTheme(appearance: appearance)
    )
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  deinit {
    activeTask?.cancel()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    // Extend under the transparent nav so placement matches Home (one content
    // inset from the native list, no solid safe-area plate under the bar).
    edgesForExtendedLayout = .all
    extendedLayoutIncludesOpaqueBars = true
    view.backgroundColor = theme.backgroundColor
    title = "Agents"
    configureNavigation()
    configureList()
    configureSkeleton()

    let cached = ChatNativeAgentListCache.cards(userID: cacheUserID)
    if !cached.isEmpty {
      // Known-good state renders before the first frame. The refresh below is
      // deliberately silent and cannot replace it on a transient failure.
      finishLoading(cards: cached, persist: false, animated: false)
    }
    loadAgents()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    reapplyThemeIfChanged()
    applyNavigationAppearance()
    // Re-apply edit tab-bar fade if we return mid-edit from a pushed screen.
    setTabBarFaded(editState.isEditing, animated: false)
  }

  override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    guard traitCollection.userInterfaceStyle != previous?.userInterfaceStyle else { return }
    reapplyThemeIfChanged()
  }

  /// Repaints when the plate or light/dark changed under us. Cheap and idempotent —
  /// `visualKey` is the same identity the chat surface compares appearances by.
  private func reapplyThemeIfChanged() {
    let next = ChatListAppearance.current
    guard next.visualKey != appearance.visualKey else { return }
    appearance = next
    theme = ChatNativeAgentConfigTheme(appearance: next)
    view.backgroundColor = theme.backgroundColor
    listHostingController?.view.backgroundColor = theme.backgroundColor
    skeletonView.applyTheme(theme)
    emptyStateView.applyTheme(theme)
    refreshListView()
    applyNavigationAppearance()
    updateTrailingChrome()
    updateFilterBarButton()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    // Never leave the tab bar faded after leaving this root.
    if isMovingFromParent || isBeingDismissed {
      setTabBarFaded(false, animated: animated)
    } else if editState.isEditing {
      setTabBarFaded(false, animated: animated)
    }
  }

  /// Best-effort per-account cache identity while the live session is settling.
  private var cacheUserID: String {
    AppSessionConfig.current?.userID ?? apiContext.token
  }

  // MARK: Navigation

  private func applyNavigationAppearance() {
    // Home uses `.toolbarBackground(.hidden)` — transparent bar over the same
    // root background, no solid ~safe-area plate under the title.
    let navigationAppearance = UINavigationBarAppearance()
    navigationAppearance.configureWithTransparentBackground()
    navigationAppearance.backgroundColor = .clear
    navigationAppearance.backgroundEffect = nil
    navigationAppearance.shadowColor = .clear
    navigationAppearance.titleTextAttributes = [
      .foregroundColor: theme.textColor,
      .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
    ]

    navigationController?.navigationBar.standardAppearance = navigationAppearance
    navigationController?.navigationBar.scrollEdgeAppearance = navigationAppearance
    navigationController?.navigationBar.compactAppearance = navigationAppearance
    navigationController?.navigationBar.isTranslucent = true
    navigationController?.navigationBar.tintColor = chromeTint

    // The item-scoped copy avoids a one-frame default hairline when a tab root
    // first becomes visible before the shared navigation bar fully synchronizes.
    navigationItem.standardAppearance = navigationAppearance
    navigationItem.scrollEdgeAppearance = navigationAppearance
    navigationItem.compactAppearance = navigationAppearance
  }

  private func configureNavigation() {
    let editButton = UIBarButtonItem(
      title: "Edit",
      style: .plain,
      target: self,
      action: #selector(handleToggleEditing)
    )
    // Match Home's semibold Edit / Done weight.
    editButton.setTitleTextAttributes(
      [.font: UIFont.systemFont(ofSize: 17, weight: .semibold)],
      for: .normal
    )
    editButton.setTitleTextAttributes(
      [.font: UIFont.systemFont(ofSize: 17, weight: .semibold)],
      for: .disabled
    )
    editBarButtonItem = editButton

    var leadingItems: [UIBarButtonItem] = []
    if showsCloseButton {
      leadingItems.append(
        UIBarButtonItem(
          barButtonSystemItem: .close,
          target: self,
          action: #selector(handleClose)
        )
      )
    }
    leadingItems.append(editButton)
    navigationItem.leftBarButtonItems = leadingItems

    // Custom SVG menu (same vector kit as chat chrome), not SF Symbol.
    let filterButton = UIBarButtonItem(
      image: vectorBarImage(.menu),
      style: .plain,
      target: nil,
      action: nil
    )
    filterButton.accessibilityLabel = "Filter agents"
    filterButton.tintColor = chromeTint
    filterBarButtonItem = filterButton
    updateFilterBarButton()

    // Custom compose SVG — same family as Home's trailing compose control.
    let addButton = UIBarButtonItem(
      image: vectorBarImage(.compose),
      style: .plain,
      target: self,
      action: #selector(handleCreate)
    )
    addButton.accessibilityLabel = "Create agent"
    addButton.tintColor = chromeTint
    addBarButtonItem = addButton
    // First item is trailing-most; keep Create at the edge, filter/menu beside it.
    navigationItem.rightBarButtonItems = [addButton, filterButton]

    // Selection / isEditing publish through `editState` (ObservedObject) into
    // the hosted SwiftUI list — no rootView reassignment needed for those.
    updateEditBarEnabled()
  }

  /// Renders chat-list custom vector glyphs for UIBarButtonItem (template).
  private func vectorBarImage(_ kind: VibeAgentKitChatVectorIcon.Kind) -> UIImage? {
    VibeAgentKitChatVectorIcon.image(kind, color: chromeTint, size: Self.vectorIconPointSize)?
      .withRenderingMode(.alwaysTemplate)
  }

  private func makeFilterMenu() -> UIMenu {
    let actions = Self.filterTitles.enumerated().map { index, title in
      UIAction(
        title: title,
        state: index == selectedFilterIndex ? .on : .off
      ) { [weak self] _ in
        guard let self, self.selectedFilterIndex != index else { return }
        self.selectedFilterIndex = index
        self.updateFilterBarButton()
        self.applyFilter()
      }
    }
    return UIMenu(title: "Filter", children: actions)
  }

  private func updateFilterBarButton() {
    guard let filterBarButtonItem else { return }
    filterBarButtonItem.menu = makeFilterMenu()
    // Keep the custom menu SVG; tint alone signals an active non-default filter.
    filterBarButtonItem.image = vectorBarImage(.menu)
    filterBarButtonItem.tintColor =
      selectedFilterIndex == 0 ? chromeTint : theme.accentColor
  }

  /// Home edit condition: Edit is disabled on an empty list, but stays enabled
  /// while already editing so Done can always exit.
  private func updateEditBarEnabled() {
    editBarButtonItem?.isEnabled = editState.isEditing || !cards.isEmpty
  }

  /// Home edit chrome: fully omit trailing items while editing (no empty glass
  /// shell / no system Delete in the bar — bottom pill owns bulk delete).
  private func updateTrailingChrome() {
    if editState.isEditing {
      navigationItem.rightBarButtonItems = nil
      return
    }
    var trailing: [UIBarButtonItem] = []
    if let addBarButtonItem { trailing.append(addBarButtonItem) }
    if let filterBarButtonItem { trailing.append(filterBarButtonItem) }
    navigationItem.rightBarButtonItems = trailing
  }

  /// Fade tab bar like Home edit mode — never `isHidden` (that collapses safe area).
  private func setTabBarFaded(_ faded: Bool, animated: Bool) {
    guard let tabBar = tabBarController?.tabBar else { return }
    tabBar.isHidden = false
    tabBar.isUserInteractionEnabled = !faded
    let target: CGFloat = faded ? 0 : 1
    if animated {
      UIView.animate(
        withDuration: 0.18,
        delay: 0,
        options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]
      ) {
        tabBar.alpha = target
      }
    } else {
      tabBar.alpha = target
    }
  }

  @objc private func handleClose() {
    dismiss(animated: true)
  }

  @objc private func handleCreate() {
    presentNewAgentSheet()
  }

  /// Native "New Agent" flow: pick a role preset, then POST + publish so the
  /// agent is usable right away. Replaces the old web-delegated create.
  private func presentNewAgentSheet() {
    let sheet = ChatNewAgentView(
      onCancel: { [weak self] in self?.dismiss(animated: true) },
      onCreate: { [weak self] attributes, completion in
        guard let self else {
          completion("Missing session")
          return
        }
        self.createAgent(attributes: attributes) { success, message in
          if success {
            self.dismiss(animated: true)
            self.onToast?("Created agent")
            self.loadAgents()
            completion(nil)
          } else {
            completion(message ?? "Could not create agent")
          }
        }
      },
      onLoadModelRegistry: { [weak self] completion in
        guard let self else {
          completion(.fallback)
          return
        }
        ChatAgentModelRegistryService.load(
          apiBaseURL: self.apiContext.apiBaseURL,
          token: self.apiContext.token,
          completion: completion)
      })
    let host = UIHostingController(rootView: sheet)
    host.modalPresentationStyle = .pageSheet
    if let controller = host.sheetPresentationController {
      controller.detents = [.large()]
      controller.prefersGrabberVisible = true
    }
    host.view.backgroundColor = .clear
    present(host, animated: true)
  }

  private func createAgent(
    attributes: [String: Any],
    completion: @escaping (Bool, String?) -> Void
  ) {
    guard let url = agentsURL() else {
      completion(false, "Missing API session")
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiContext.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try? JSONSerialization.data(withJSONObject: attributes)

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
      [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else {
          completion(false, nil)
          return
        }
        if let error {
          completion(false, error.localizedDescription)
          return
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let payload = data.flatMap {
          (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }
        guard (200..<300).contains(statusCode) else {
          completion(false, (payload?["error"] as? String) ?? "Could not create agent")
          return
        }
        guard
          let agentRaw = payload?["agent"] as? [String: Any],
          let agentId = agentRaw["id"] as? String,
          !agentId.isEmpty
        else {
          completion(false, "Malformed response")
          return
        }
        self.publishCreatedAgent(agentId)
        completion(true, nil)
      }
    }
    task.resume()
  }

  /// Best-effort publish so a freshly created agent is live immediately; a
  /// failure leaves it as a draft the owner can publish from its settings.
  private func publishCreatedAgent(_ agentId: String) {
    guard let base = agentsURL(),
      let url = URL(string: "\(base.absoluteString)/\(agentId)/publish")
    else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(apiContext.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
      [weak self] _, _, _ in
      DispatchQueue.main.async { self?.loadAgents() }
    }
    task.resume()
  }

  @objc private func handleToggleEditing() {
    // Mirror Home: no-op when empty unless exiting edit.
    guard editState.isEditing || !cards.isEmpty else { return }
    editState.isEditing.toggle()
    if !editState.isEditing {
      editState.selectedAgentIDs.removeAll()
    }
    editBarButtonItem?.title = editState.isEditing ? "Done" : "Edit"
    updateEditBarEnabled()
    updateTrailingChrome()
    setTabBarFaded(editState.isEditing, animated: true)
  }

  @objc private func handleBulkDelete() {
    let selectedIDs = editState.selectedAgentIDs
    let selectedCards = allCards.filter {
      selectedIDs.contains(chatAgentsRowID(for: $0))
    }
    guard !selectedCards.isEmpty else { return }
    editState.selectedAgentIDs.removeAll()
    deleteAgents(selectedCards[...])
  }

  /// Requests bulk removals serially so an async confirmation UI never has to
  /// present several destructive prompts at once.
  private func deleteAgents(_ remaining: ArraySlice<ChatListRow.AgentCard>) {
    guard let card = remaining.first else { return }
    requestDelete(card) { [weak self] in
      self?.deleteAgents(remaining.dropFirst())
    }
  }

  // MARK: List

  private func configureList() {
    let hostingController = UIHostingController(rootView: makeListView())
    listHostingController = hostingController
    addChild(hostingController)
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    hostingController.view.backgroundColor = theme.backgroundColor
    // Prevent UIHostingController from stacking a second safe-area inset on
    // top of ChatHomeNativeListController's own contentInset (the "list sits
    // ~30pt too low + solid plate" mismatch vs Home).
    if #available(iOS 16.4, *) {
      hostingController.safeAreaRegions = []
    }
    hostingController.view.insetsLayoutMarginsFromSafeArea = false
    view.addSubview(hostingController.view)
    hostingController.didMove(toParent: self)

    emptyStateView.isHidden = true
    emptyStateView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(emptyStateView)

    // No second safe-area band: the hosted list owns Home's in-list search
    // header, so content and empty/skeleton share the same top edge under the
    // transparent nav (same as Home's ignoresSafeArea listContent).
    NSLayoutConstraint.activate([
      hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
      hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      // Empty state sits under the transparent nav using the same top content
      // band as the list (safeArea top already includes status + bar height).
      emptyStateView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      emptyStateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      emptyStateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      emptyStateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func makeListView() -> ChatAgentsNativeListView {
    ChatAgentsNativeListView(
      cards: cards,
      isDark: theme.isDark,
      listBackground: theme.backgroundColor,
      editState: editState,
      searchText: Binding(
        get: { [weak self] in
          self?.searchQuery ?? ""
        },
        set: { [weak self] text in
          guard let self else { return }
          guard self.searchQuery != text else { return }
          self.searchQuery = text
          self.applyFilter()
        }
      ),
      onOpenAgentChat: { [weak self] card in
        self?.onOpenAgentChat?(card)
      },
      onOpenSettings: { [weak self] card in
        self?.openSettings(for: card)
      },
      onDeleteAgent: { [weak self] card, completion in
        self?.requestDelete(card, completion: completion)
      },
      onBulkDelete: { [weak self] in
        self?.handleBulkDelete()
      },
      onToast: { [weak self] message in
        self?.onToast?(message)
      },
      onRefresh: { [weak self] in
        await MainActor.run {
          self?.loadAgents()
        }
      }
    )
  }

  private func refreshListView() {
    listHostingController?.rootView = makeListView()
  }

  private func openSettings(for card: ChatListRow.AgentCard) {
    let controller = ChatNativeAgentConfigPanelController(
      card: card,
      appearance: appearance,
      apiContext: apiContext
    )
    controller.onToast = onToast
    controller.onOpenAgentChat = onOpenAgentChat
    controller.onDeleteAgent = { [weak self] card, completion in
      self?.requestDelete(card, completion: completion)
    }
    navigationController?.pushViewController(controller, animated: true)
  }

  private func requestDelete(
    _ card: ChatListRow.AgentCard,
    completion: @escaping () -> Void
  ) {
    onDeleteAgent?(card) { [weak self] in
      self?.removeCard(agentId: card.agentId)
      completion()
    }
  }

  private func removeCard(agentId: String) {
    if let card = allCards.first(where: { $0.agentId == agentId }) {
      editState.selectedAgentIDs.remove(chatAgentsRowID(for: card))
    }
    allCards.removeAll { $0.agentId == agentId }
    ChatOwnedAgentIdsCache.agentIds.remove(agentId)
    ChatNativeAgentListCache.store(allCards, userID: cacheUserID)
    applyFilter()
    emptyStateView.isHidden = !allCards.isEmpty
  }

  private func applyFilter() {
    let query = searchQuery
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let selectedFilter = selectedFilterIndex
    cards = allCards.filter { card in
      if !query.isEmpty {
        let searchableText = "\(card.displayName) \(card.username ?? "")".lowercased()
        guard searchableText.contains(query) else { return false }
      }
      switch selectedFilter {
      case 1:
        return chatNativeAgentIsPublished(card.status)
      case 2:
        return !chatNativeAgentIsPublished(card.status)
      default:
        return true
      }
    }
    // Empty filtered projection exits edit (can't select nothing) and disables Edit
    // the same way Home disables it when filteredRows is empty.
    if cards.isEmpty, editState.isEditing {
      editState.isEditing = false
      editState.selectedAgentIDs.removeAll()
      editBarButtonItem?.title = "Edit"
      updateTrailingChrome()
      setTabBarFaded(false, animated: true)
    }
    updateEditBarEnabled()
    refreshListView()
  }

  // MARK: Loading

  private func configureSkeleton() {
    view.addSubview(skeletonView)
    NSLayoutConstraint.activate([
      // Rows sit under the transparent nav (safe-area top), matching Home's
      // content band — not under a second solid plate.
      skeletonView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      skeletonView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      skeletonView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      skeletonView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }

  private func loadAgents() {
    // Loading chrome is only for genuinely unknown state. A cache-backed list
    // remains interactive while its network refresh runs underneath.
    if allCards.isEmpty {
      skeletonView.isHidden = false
      listHostingController?.view.isHidden = true
      emptyStateView.isHidden = true
    }

    guard let url = agentsURL() else {
      if allCards.isEmpty {
        finishLoading(cards: [], persist: false)
        onToast?("Could not load agents")
      }
      return
    }

    var request = URLRequest(url: url)
    request.setValue("Bearer \(apiContext.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    activeTask?.cancel()
    activeTask = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
      [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else { return }
        guard
          error == nil,
          let httpResponse = response as? HTTPURLResponse,
          (200..<300).contains(httpResponse.statusCode),
          let data,
          let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
          // A failed refresh must never erase a list already restored from disk.
          if self.allCards.isEmpty {
            self.finishLoading(cards: [], persist: false)
            self.onToast?("Could not load agents")
          }
          return
        }

        let rawItems = payload["items"] as? [[String: Any]] ?? []
        let parsedCards = rawItems.compactMap {
          chatNativeAgentParseControlCard(raw: $0, apiContext: self.apiContext)
        }
        self.finishLoading(
          cards: parsedCards,
          persist: true,
          animated: self.allCards.isEmpty
        )
      }
    }
    activeTask?.resume()
  }

  private func finishLoading(
    cards: [ChatListRow.AgentCard],
    persist: Bool,
    animated: Bool = true
  ) {
    allCards = cards
    ChatOwnedAgentIdsCache.agentIds = Set(cards.map(\.agentId))
    if persist {
      ChatNativeAgentListCache.store(cards, userID: cacheUserID)
    }
    let hasCards = !cards.isEmpty

    guard animated else {
      skeletonView.isHidden = true
      listHostingController?.view.isHidden = !hasCards
      emptyStateView.isHidden = hasCards
      applyFilter()
      return
    }

    UIView.transition(
      with: view,
      duration: 0.3,
      options: .transitionCrossDissolve,
      animations: {
        self.skeletonView.isHidden = true
        self.listHostingController?.view.isHidden = !hasCards
        self.emptyStateView.isHidden = hasCards
      },
      completion: { _ in
        self.applyFilter()
      }
    )
  }

  private func agentsURL() -> URL? {
    var base = apiContext.apiBaseURL.absoluteString
      .trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }
    let suffix = base.lowercased().hasSuffix("/api") ? "/agents" : "/api/agents"
    return URL(string: base + suffix)
  }
}
