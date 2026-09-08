import Foundation

enum ChannelProfileServiceError: LocalizedError {
  case invalidURL
  case invalidResponse
  case invalidPayload
  case http(Int, String)

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "The stored API configuration is invalid."
    case .invalidResponse:
      return "The server did not return a valid response."
    case .invalidPayload:
      return "The channel response could not be parsed."
    case let .http(code, body):
      let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { return "Channel request failed (\(code))." }
      return "Channel request failed (\(code)): \(String(trimmed.prefix(180)))"
    }
  }

  var isSessionExpired: Bool {
    if case let .http(code, _) = self { return code == 401 }
    return false
  }
}

/// Production channel profile + settings API (`GET/PUT /api/channel/:id`).
enum ChannelProfileService {
  struct Member: Equatable {
    let userId: String
    let name: String
    let username: String?
    let avatarUrl: String?
    let role: String

    var isAdmin: Bool { role == "owner" || role == "admin" }
  }

  struct Settings: Equatable {
    var channelType: String
    var publicSlug: String?
    var inviteLink: String?
    var joinApprovalRequired: Bool
    var restrictSavingContent: Bool
    var discussionsEnabled: Bool
    var reactionsEnabled: Bool
    var allowDirectMessages: Bool
    var autoTranslateEnabled: Bool

    static let `default` = Settings(
      channelType: "public",
      publicSlug: nil,
      inviteLink: nil,
      joinApprovalRequired: false,
      restrictSavingContent: false,
      discussionsEnabled: false,
      reactionsEnabled: true,
      allowDirectMessages: false,
      autoTranslateEnabled: false
    )

    init(
      channelType: String,
      publicSlug: String? = nil,
      inviteLink: String?,
      joinApprovalRequired: Bool = false,
      restrictSavingContent: Bool = false,
      discussionsEnabled: Bool,
      reactionsEnabled: Bool,
      allowDirectMessages: Bool,
      autoTranslateEnabled: Bool
    ) {
      self.channelType = channelType
      self.publicSlug = publicSlug
      self.inviteLink = inviteLink
      self.joinApprovalRequired = joinApprovalRequired
      self.restrictSavingContent = restrictSavingContent
      self.discussionsEnabled = discussionsEnabled
      self.reactionsEnabled = reactionsEnabled
      self.allowDirectMessages = allowDirectMessages
      self.autoTranslateEnabled = autoTranslateEnabled
    }

    init(raw: [String: Any]?) {
      let map = raw ?? [:]
      channelType =
        (map["channelType"] as? String)
        ?? (map["accessType"] as? String)
        ?? (map["channel_type"] as? String)
        ?? (map["access_type"] as? String)
        ?? "public"
      publicSlug =
        (map["publicSlug"] as? String)
        ?? (map["public_slug"] as? String)
      inviteLink =
        (map["inviteLink"] as? String)
        ?? (map["invite_link"] as? String)
        ?? (map["shareLink"] as? String)
        ?? (map["share_link"] as? String)
      joinApprovalRequired =
        (map["joinApprovalRequired"] as? Bool)
        ?? (map["join_approval_required"] as? Bool)
        ?? false
      restrictSavingContent =
        (map["restrictSavingContent"] as? Bool)
        ?? (map["restrict_saving_content"] as? Bool)
        ?? false
      discussionsEnabled =
        (map["discussionsEnabled"] as? Bool)
        ?? (map["discussions_enabled"] as? Bool)
        ?? false
      reactionsEnabled =
        (map["reactionsEnabled"] as? Bool)
        ?? (map["reactions_enabled"] as? Bool)
        ?? true
      allowDirectMessages =
        (map["allowDirectMessages"] as? Bool)
        ?? (map["allow_direct_messages"] as? Bool)
        ?? false
      autoTranslateEnabled =
        (map["autoTranslateEnabled"] as? Bool)
        ?? (map["auto_translate_enabled"] as? Bool)
        ?? false
    }

    func asJSON() -> [String: Any] {
      var body: [String: Any] = [
        "channelType": channelType,
        "accessType": channelType,
        "joinApprovalRequired": joinApprovalRequired,
        "restrictSavingContent": restrictSavingContent,
        "discussionsEnabled": discussionsEnabled,
        "reactionsEnabled": reactionsEnabled,
        "allowDirectMessages": allowDirectMessages,
        "autoTranslateEnabled": autoTranslateEnabled,
      ]
      if let publicSlug, !publicSlug.isEmpty {
        body["publicSlug"] = publicSlug
      }
      if let inviteLink, !inviteLink.isEmpty {
        body["inviteLink"] = inviteLink
      }
      return body
    }
  }

  struct RecentAction: Identifiable, Equatable {
    let id: String
    let type: String
    let text: String
    let fromId: String?
    let fromName: String?
    let timestampMs: Int64
    let isSystem: Bool
  }

  struct OwnedAgent: Identifiable, Equatable {
    let id: String
    let userId: String?
    let displayName: String
    let status: String
    let enabledTools: [String]
    let outputModes: [String]
  }

  struct AgentAssignment: Identifiable {
    let id: String
    let agentId: String
    let agentUserId: String?
    let displayName: String
    var status: String
    var allowedTools: [String]
    var allowedOutputModes: [String]
    var triggerConfig: [String: Any]
    var permissions: [String: Any]

  }

  struct Profile {
    let chatId: String
    let name: String
    let description: String?
    let avatarUrl: String?
    let myRole: String?
    let memberCount: Int
    let administrators: [Member]
    let subscribers: [Member]
    let members: [Member]
    let settings: Settings
    let recentActions: [RecentAction]
  }

  static func fetchProfile(chatId: String, config: AppSessionConfig) async throws -> Profile {
    let payload = try await send(
      method: "GET", path: "/channel/\(encoded(chatId))", body: nil, config: config)
    return parseProfile(payload, fallbackChatId: chatId)
  }

  static func update(
    chatId: String,
    name: String? = nil,
    description: String? = nil,
    avatarUrl: String? = nil,
    settings: Settings? = nil,
    config: AppSessionConfig
  ) async throws -> Profile {
    var body: [String: Any] = [:]
    if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
      body["name"] = name
    }
    if let description {
      body["description"] = description
    }
    if let avatarUrl, !avatarUrl.isEmpty {
      body["avatarUrl"] = avatarUrl
    }
    if let settings {
      let settingsJSON = settings.asJSON()
      body.merge(settingsJSON) { _, new in new }
      body["settings"] = settingsJSON
    }
    let payload = try await send(
      method: "PUT", path: "/channel/\(encoded(chatId))", body: body, config: config)
    // PUT returns a slim payload — re-fetch full profile so admins/subscribers stay live.
    if payload["administrators"] == nil {
      return try await fetchProfile(chatId: chatId, config: config)
    }
    return parseProfile(payload, fallbackChatId: chatId)
  }

  static func rotateInviteLink(chatId: String, config: AppSessionConfig) async throws -> Settings {
    let payload = try await send(
      method: "POST", path: "/channel/\(encoded(chatId))/invite-link", body: [:], config: config)
    if let settings = payload["settings"] as? [String: Any] {
      return Settings(raw: settings)
    }
    return Settings(
      channelType: "public",
      publicSlug: nil,
      inviteLink: payload["inviteLink"] as? String,
      joinApprovalRequired: false,
      restrictSavingContent: false,
      discussionsEnabled: false,
      reactionsEnabled: true,
      allowDirectMessages: false,
      autoTranslateEnabled: false
    )
  }

  static func updatePolicy(
    chatId: String, values: [String: Any], config: AppSessionConfig
  ) async throws -> Profile {
    let payload = try await send(
      method: "PUT", path: "/channel/\(encoded(chatId))", body: values, config: config)
    if payload["administrators"] == nil {
      return try await fetchProfile(chatId: chatId, config: config)
    }
    return parseProfile(payload, fallbackChatId: chatId)
  }

  static func fetchOwnedAgents(config: AppSessionConfig) async throws -> [OwnedAgent] {
    let payload = try await send(method: "GET", path: "/agents", body: nil, config: config)
    let items = payload["items"] as? [[String: Any]] ?? []
    return items.compactMap { raw in
      guard let id = string(raw["id"]), !id.isEmpty else { return nil }
      return OwnedAgent(
        id: id,
        userId: string(raw["userId"] ?? raw["user_id"]),
        displayName: string(raw["displayName"] ?? raw["display_name"] ?? raw["username"])
          ?? "Agent",
        status: string(raw["status"]) ?? "draft",
        enabledTools: strings(raw["enabledTools"] ?? raw["enabled_tools"]),
        outputModes: strings(raw["outputModes"] ?? raw["output_modes"])
      )
    }
  }

  static func fetchAgentAssignments(
    chatId: String, config: AppSessionConfig
  ) async throws -> [AgentAssignment] {
    let payload = try await send(
      method: "GET", path: "/channel/\(encoded(chatId))/agents", body: nil, config: config)
    return (payload["agents"] as? [[String: Any]] ?? []).compactMap(parseAssignment)
  }

  static func attachAgent(
    chatId: String,
    agent: OwnedAgent,
    config: AppSessionConfig
  ) async throws -> AgentAssignment {
    let payload = try await send(
      method: "POST",
      path: "/channel/\(encoded(chatId))/agents",
      body: [
        "agentId": agent.id,
        "allowedTools": agent.enabledTools,
        "allowedOutputModes": agent.outputModes,
        "triggerConfig": ["type": "manual"],
        "permissions": ["instructions": ""],
      ],
      config: config
    )
    guard let assignment = parseAssignment(payload) else {
      throw ChannelProfileServiceError.invalidPayload
    }
    return assignment
  }

  static func updateAgentAssignment(
    chatId: String,
    agentId: String,
    allowedTools: [String],
    allowedOutputModes: [String],
    triggerConfig: [String: Any],
    permissions: [String: Any],
    status: String,
    config: AppSessionConfig
  ) async throws -> AgentAssignment {
    let payload = try await send(
      method: "PUT",
      path: "/channel/\(encoded(chatId))/agents/\(encoded(agentId))",
      body: [
        "allowedTools": allowedTools,
        "allowedOutputModes": allowedOutputModes,
        "triggerConfig": triggerConfig,
        "permissions": permissions,
        "status": status,
      ],
      config: config
    )
    guard let assignment = parseAssignment(payload) else {
      throw ChannelProfileServiceError.invalidPayload
    }
    return assignment
  }

  static func detachAgent(chatId: String, agentId: String, config: AppSessionConfig) async throws {
    _ = try await send(
      method: "DELETE",
      path: "/channel/\(encoded(chatId))/agents/\(encoded(agentId))",
      body: nil,
      config: config
    )
  }

  // MARK: - HTTP

  private static func send(
    method: String,
    path: String,
    body: [String: Any]?,
    config: AppSessionConfig
  ) async throws -> [String: Any] {
    let active = AppSessionConfig.current ?? config
    return try await sendOnce(method: method, path: path, body: body, config: active)
  }

  private static func sendOnce(
    method: String,
    path: String,
    body: [String: Any]?,
    config: AppSessionConfig
  ) async throws -> [String: Any] {
    var base = config.apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    let pathBase = base.lowercased().hasSuffix("/api") ? base : "\(base)/api"
    guard let url = URL(string: "\(pathBase)\(path)") else {
      throw ChannelProfileServiceError.invalidURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await VibeHTTP.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw ChannelProfileServiceError.invalidResponse
    }
    guard (200...299).contains(http.statusCode) else {
      let bodyText = String(data: data, encoding: .utf8) ?? ""
      throw ChannelProfileServiceError.http(http.statusCode, bodyText)
    }
    if data.isEmpty { return [:] }
    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    guard let payload = object as? [String: Any] else {
      throw ChannelProfileServiceError.invalidPayload
    }
    return payload
  }

  private static func encoded(_ chatId: String) -> String {
    chatId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? chatId
  }

  private static func parseProfile(_ raw: [String: Any], fallbackChatId: String) -> Profile {
    let members = parseMembers(raw["members"] as? [[String: Any]])
    let admins =
      parseMembers(raw["administrators"] as? [[String: Any]]).isEmpty
      ? members.filter(\.isAdmin)
      : parseMembers(raw["administrators"] as? [[String: Any]])
    let subs =
      parseMembers(raw["subscribers"] as? [[String: Any]]).isEmpty
      ? members.filter { !$0.isAdmin }
      : parseMembers(raw["subscribers"] as? [[String: Any]])
    let actions = (raw["recentActions"] as? [[String: Any]] ?? raw["recent_actions"] as? [[String: Any]] ?? [])
      .compactMap { entry -> RecentAction? in
        let id = (entry["id"] as? String) ?? UUID().uuidString
        return RecentAction(
          id: id,
          type: (entry["type"] as? String) ?? "text",
          text: (entry["text"] as? String) ?? "",
          fromId: entry["fromId"] as? String ?? entry["from_id"] as? String,
          fromName: entry["fromName"] as? String ?? entry["from_name"] as? String,
          timestampMs: (entry["timestampMs"] as? NSNumber)?.int64Value
            ?? (entry["timestamp_ms"] as? NSNumber)?.int64Value
            ?? 0,
          isSystem: (entry["isSystem"] as? Bool) ?? (entry["is_system"] as? Bool) ?? false
        )
      }
    return Profile(
      chatId: (raw["chatId"] as? String) ?? (raw["chat_id"] as? String) ?? fallbackChatId,
      name: (raw["name"] as? String) ?? "",
      description: raw["description"] as? String,
      avatarUrl: raw["avatarUrl"] as? String ?? raw["avatar_url"] as? String,
      myRole: raw["myRole"] as? String ?? raw["my_role"] as? String ?? raw["role"] as? String,
      memberCount: (raw["memberCount"] as? NSNumber)?.intValue
        ?? (raw["member_count"] as? NSNumber)?.intValue
        ?? members.count,
      administrators: admins,
      subscribers: subs,
      members: members,
      settings: Settings(raw: raw["settings"] as? [String: Any]),
      recentActions: actions
    )
  }

  private static func parseMembers(_ raw: [[String: Any]]?) -> [Member] {
    (raw ?? []).compactMap { entry in
      let userId =
        (entry["userId"] as? String)
        ?? (entry["user_id"] as? String)
        ?? (entry["id"] as? String)
      guard let userId, !userId.isEmpty else { return nil }
      let name =
        (entry["name"] as? String)
        ?? (entry["username"] as? String)
        ?? userId
      let role =
        ((entry["role"] as? String) ?? "member")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
      return Member(
        userId: userId,
        name: name,
        username: entry["username"] as? String,
        avatarUrl: entry["avatarUrl"] as? String ?? entry["avatar_url"] as? String,
        role: role.isEmpty ? "member" : role
      )
    }
  }

  private static func parseAssignment(_ raw: [String: Any]) -> AgentAssignment? {
    guard let id = string(raw["id"]), let agentId = string(raw["agentId"] ?? raw["agent_id"])
    else { return nil }
    return AgentAssignment(
      id: id,
      agentId: agentId,
      agentUserId: string(raw["agentUserId"] ?? raw["agent_user_id"]),
      displayName: string(raw["displayName"] ?? raw["display_name"]) ?? "Agent",
      status: string(raw["status"]) ?? "active",
      allowedTools: strings(raw["allowedTools"] ?? raw["allowed_tools"]),
      allowedOutputModes: strings(raw["allowedOutputModes"] ?? raw["allowed_output_modes"]),
      triggerConfig: raw["triggerConfig"] as? [String: Any]
        ?? raw["trigger_config"] as? [String: Any]
        ?? [:],
      permissions: raw["permissions"] as? [String: Any] ?? [:]
    )
  }

  private static func string(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func strings(_ value: Any?) -> [String] {
    (value as? [Any] ?? []).compactMap(string).uniqued()
  }
}

private extension Array where Element == String {
  func uniqued() -> [String] {
    var seen = Set<String>()
    return filter { seen.insert($0).inserted }
  }
}
