import Foundation

/// Shares one in-flight `/api/chats` request per list (normal / archived) across
/// every concurrent caller. See `ChatHomeService.coalesced(config:archived:)`.
private actor ChatsRequestCoalescer {
  static let shared = ChatsRequestCoalescer()

  private var inFlight: [Bool: Task<[ChatHomeListRow], Error>] = [:]

  func load(
    archived: Bool,
    using work: @escaping () async throws -> [ChatHomeListRow]
  ) async throws -> [ChatHomeListRow] {
    // A request is already out for this list — ride along with it. Actor
    // reentrancy is what makes this work: `await` below suspends without holding
    // the actor, so later callers can still see and join the in-flight entry.
    if let existing = inFlight[archived] {
      return try await existing.value
    }
    let task = Task { try await work() }
    inFlight[archived] = task
    let result = await task.result
    inFlight[archived] = nil
    return try result.get()
  }
}

enum ChatHomeService {
  static func cachedRows(config: AppSessionConfig) -> [ChatHomeListRow] {
    rowsIncludingBuiltInAgent(ChatHomeRowsCache.rows(userID: config.userID))
  }

  static func storeCachedRows(_ rows: [ChatHomeListRow], config: AppSessionConfig) {
    ChatHomeRowsCache.store(rowsIncludingBuiltInAgent(rows), userID: config.userID)
  }

  static func removeCachedChat(chatID: String, config: AppSessionConfig) {
    let normalizedChatID = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedChatID.isEmpty else { return }
    let nextRows = ChatHomeRowsCache.rows(userID: config.userID)
      .filter { $0.chatId != normalizedChatID }
    ChatHomeRowsCache.store(rowsIncludingBuiltInAgent(nextRows), userID: config.userID)
  }

  static func upsertCachedRow(_ row: ChatHomeListRow, config: AppSessionConfig) {
    guard !row.isArchiveEntry else { return }
    var nextRows = ChatHomeRowsCache.rows(userID: config.userID)
      .filter { $0.chatId != row.chatId && !$0.isArchiveEntry }
    let insertionIndex: Int
    if row.isSavedMessages {
      insertionIndex = 0
    } else {
      insertionIndex =
        nextRows
        .prefix { $0.isSavedMessages || $0.isBuiltInAgentSurface || $0.pinned }
        .count
    }
    nextRows.insert(row, at: min(insertionIndex, nextRows.count))
    ChatHomeRowsCache.store(rowsIncludingBuiltInAgent(nextRows), userID: config.userID)
  }

  static func isOfflineError(_ error: Error) -> Bool {
    if let homeError = error as? ChatHomeServiceError {
      switch homeError {
      case let .transportUnavailable(reason):
        return reason == "offline"
      default:
        return false
      }
    }

    guard let urlError = firstURLError(in: error) else { return false }
    switch urlError.code {
    case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
      .dnsLookupFailed, .internationalRoamingOff, .callIsActive, .dataNotAllowed:
      return true
    default:
      return false
    }
  }

  static func fetchChats(config: AppSessionConfig) async throws -> [ChatHomeListRow] {
    try await coalesced(config: config, archived: false)
  }

  static func fetchArchivedChats(config: AppSessionConfig) async throws -> [ChatHomeListRow] {
    try await coalesced(config: config, archived: true)
  }

  /// `/api/chats` has several independent callers (Home's list, the archived list,
  /// the home view controller, an opened profile) and at launch they fire at the
  /// same moment — production logs showed three or four identical requests landing
  /// within one millisecond of each other, each costing seconds of server time and
  /// each holding one of URLSession's few per-host connections while the rest of
  /// the launch burst queued behind them.
  ///
  /// Concurrent callers now share a single request and all receive its result.
  /// This is a *sharing* window, not a cache: the entry is dropped the moment the
  /// request finishes, so a later refresh still goes to the network.
  private static func coalesced(config: AppSessionConfig, archived: Bool) async throws
    -> [ChatHomeListRow]
  {
    try await ChatsRequestCoalescer.shared.load(archived: archived) {
      try await fetchChats(config: config, archived: archived)
    }
  }

  private static func fetchChats(config: AppSessionConfig, archived: Bool) async throws
    -> [ChatHomeListRow]
  {
    let request = try buildRequest(config: config, archived: archived)
    switch config.transportMode {
    case .offline:
      throw ChatHomeServiceError.transportUnavailable("offline")
    case .bridgeText:
      throw ChatHomeServiceError.transportUnavailable("bridge_text")
    case .direct:
      let rows = try await loadRows(
        config: config,
        request: request,
        session: PacketRuntime.shared.session(),
        archived: archived
      )
      Task.detached {
        await PacketBootstrapService.prefetchIfNeeded(config: config)
      }
      return rows
    }
  }

  private static func buildRequest(config: AppSessionConfig, archived: Bool = false) throws -> URLRequest {
    var base = config.apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }
    let pathBase = base.lowercased().hasSuffix("/api") ? base : "\(base)/api"
    guard
      let encodedUserID = config.userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      let url = URL(string: "\(pathBase)/chats/\(encodedUserID)\(archived ? "?archived=true" : "")")
    else {
      throw ChatHomeServiceError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 18
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    return request
  }

  private static func loadRows(
    config: AppSessionConfig,
    request: URLRequest,
    session: URLSession,
    archived: Bool = false
  ) async throws -> [ChatHomeListRow] {
    async let chats = perform(request, session: session)

    let rows = try await chats
    let filteredRows = rows.filter { !$0.isSavedMessages }

    guard !archived else {
      return filteredRows
    }

    async let savedMessagesRow = fetchSavedMessagesRow(config: config, session: session)

    let combinedRows: [ChatHomeListRow]
    let resolvedSavedMessagesRow =
      await savedMessagesRow
      ?? ChatHomeRowsCache.rows(userID: config.userID).first(where: \.isSavedMessages)
    if let resolvedSavedMessagesRow {
      combinedRows = [resolvedSavedMessagesRow] + filteredRows
    } else {
      combinedRows = filteredRows
    }
    let rowsWithAgent = rowsIncludingBuiltInAgent(combinedRows)
    ChatHomeRowsCache.store(rowsWithAgent, userID: config.userID)
    return rowsWithAgent
  }

  static func rowsIncludingBuiltInAgent(_ rows: [ChatHomeListRow]) -> [ChatHomeListRow] {
    var filteredRows = rows.filter { !$0.isBuiltInAgentSurface }
    let insertionIndex = filteredRows.first?.isSavedMessages == true ? 1 : 0
    filteredRows.insert(builtInAgentRow(), at: min(insertionIndex, filteredRows.count))
    return filteredRows
  }

  private static func builtInAgentRow() -> ChatHomeListRow {
    let summary = ChatNativeAgentView.homeListSummary()
    let timeLabel = summary.map {
      ChatHomeListRow.homeTimeLabel(from: ["timestamp": NSNumber(value: $0.timestampMs)])
    } ?? ""
    return ChatHomeListRow(
      chatId: "vibe",
      title: "Vibe AI",
      preview: summary?.preview ?? "Ask Vibe AI anything",
      timeLabel: timeLabel,
      unreadCount: 0,
      markedUnread: false,
      muted: false,
      pinned: false,
      archived: false,
      isTyping: summary?.preview == "Thinking…",
      isOnline: true,
      peerUserId: nil,
      avatarUri: nil,
      avatarFallback: "V",
      avatarGradientStartLight: "#2F9AA8",
      avatarGradientEndLight: "#207585",
      avatarGradientStartDark: "#4BB6C4",
      avatarGradientEndDark: "#1B6575",
      isSavedMessages: false,
      isArchiveEntry: false,
      type: "vibe_agent",
      isGroup: false,
      isAgentFriend: true,
      peerAgentId: nil,
      agentEventInboxMode: nil,
      peerTier: nil,
      previewRows: [],
      initialMessages: [],
      members: [],
      lastMessageAt: Double(summary?.timestampMs ?? 0)
    )
  }

  private static func perform(_ request: URLRequest, session: URLSession) async throws -> [ChatHomeListRow] {
    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ChatHomeServiceError.invalidResponse
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw ChatHomeServiceError.http(httpResponse.statusCode, body)
    }

    let payload = try parsePayload(data)
    return payload.compactMap(ChatHomeListRow.parse)
  }

  private static func fetchSavedMessagesRow(
    config: AppSessionConfig,
    session: URLSession
  ) async -> ChatHomeListRow? {
    guard let request = try? buildSavedMessagesRequest(config: config) else { return nil }

    do {
      let (data, response) = try await session.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else { return nil }
      guard (200...299).contains(httpResponse.statusCode) else { return nil }

      let messages = try parsePayload(data)
      guard !messages.isEmpty else { return nil }

      let latestMessage = messages.max { lhs, rhs in
        savedMessageTimestamp(lhs) < savedMessageTimestamp(rhs)
      }

      return ChatHomeListRow(
        chatId: "saved_messages",
        title: "Saved Messages",
        preview: latestMessage.map(ChatHomeListRow.homePreviewText(from:)) ?? "",
        timeLabel: latestMessage.map(ChatHomeListRow.homeTimeLabel(from:)) ?? "",
        unreadCount: 0,
        markedUnread: false,
        muted: false,
        pinned: true,
        archived: false,
        isTyping: false,
        isOnline: false,
        peerUserId: nil,
        avatarUri: nil,
        avatarFallback: "V",
        avatarGradientStartLight: nil,
        avatarGradientEndLight: nil,
        avatarGradientStartDark: nil,
        avatarGradientEndDark: nil,
        isSavedMessages: true,
        isArchiveEntry: false,
        type: "saved_messages",
        isGroup: false,
        isAgentFriend: false,
        peerAgentId: nil,
        agentEventInboxMode: nil,
        peerTier: nil,
        previewRows: [],
        initialMessages: ChatHomeListRow.parseServerMessages(messages),
        members: []
      )
    } catch {
      return nil
    }
  }

  private static func parsePayload(_ data: Data) throws -> [[String: Any]] {
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    if let items = object as? [[String: Any]] {
      return items
    }
    if let object = object as? [String: Any] {
      if let items = object["data"] as? [[String: Any]] {
        return items
      }
      if let items = object["chats"] as? [[String: Any]] {
        return items
      }
    }
    if let items = object as? [Any] {
      return items.compactMap { $0 as? [String: Any] }
    }
    throw ChatHomeServiceError.invalidPayload
  }

  private static func buildSavedMessagesRequest(config: AppSessionConfig) throws -> URLRequest {
    var base = config.apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }
    let pathBase = base.lowercased().hasSuffix("/api") ? base : "\(base)/api"
    guard
      let encodedUserID = config.userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      let url = URL(string: "\(pathBase)/saved_messages/\(encodedUserID)")
    else {
      throw ChatHomeServiceError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 18
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    return request
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

  private static func savedMessageTimestamp(_ raw: [String: Any]) -> Int64 {
    if let value = raw["timestamp"] as? NSNumber {
      return value.int64Value
    }
    if let value = raw["timestamp"] as? String {
      return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
    return 0
  }

  private static func firstURLError(in error: Error) -> URLError? {
    if let urlError = error as? URLError {
      return urlError
    }

    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
      return URLError(URLError.Code(rawValue: nsError.code))
    }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
      return firstURLError(in: underlying)
    }
    return nil
  }
}

private enum ChatHomeRowsCache {
  private static let keyPrefix = "vibe.ios.chatHome.rows.v1"

  static func rows(userID: String) -> [ChatHomeListRow] {
    let defaults = UserDefaults.standard
    guard let data = defaults.data(forKey: cacheKey(userID: userID)),
      let object = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else {
      VibeDebugLog.log("[ChatHomeRowsCache] restored rows=0 user=%@", String(userID.prefix(8)))
      return []
    }
    let rows = object.compactMap(ChatHomeListRow.parse)
    VibeDebugLog.log("[ChatHomeRowsCache] restored rows=%d user=%@", rows.count, String(userID.prefix(8)))
    return rows
  }

  static func store(_ rows: [ChatHomeListRow], userID: String) {
    var payload = rows.map { $0.cachePayload() }
    if !JSONSerialization.isValidJSONObject(payload) {
      payload = rows.map { $0.cachePayload(messageLimit: 0) }
    }
    guard JSONSerialization.isValidJSONObject(payload),
      let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
    else {
      VibeDebugLog.log("[ChatHomeRowsCache] skipped invalid payload rows=%d", rows.count)
      return
    }
    UserDefaults.standard.set(data, forKey: cacheKey(userID: userID))
    UserDefaults.standard.synchronize()
    VibeDebugLog.log("[ChatHomeRowsCache] stored rows=%d user=%@", rows.count, String(userID.prefix(8)))
  }

  private static func cacheKey(userID: String) -> String {
    let safeUserID =
      userID
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .unicodeScalars
      .map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
      }
    let suffix = String(safeUserID).isEmpty ? "default" : String(safeUserID)
    return "\(keyPrefix).\(suffix)"
  }
}

enum ChatHomeServiceError: LocalizedError {
  case invalidURL
  case invalidResponse
  case invalidPayload
  case http(Int, String)
  case transportUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "The stored API configuration is invalid."
    case .invalidResponse:
      return "The server did not return a valid response."
    case .invalidPayload:
      return "The chat payload could not be parsed."
    case let .http(status, body):
      let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
      return "Request failed with status \(status)\(trimmed.isEmpty ? "" : ": \(trimmed)")"
    case let .transportUnavailable(mode):
      return "Transport mode \(mode) is not available in the standalone native app."
    }
  }
}
