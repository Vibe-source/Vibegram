import Foundation
import UIKit

struct SettingsPrivacyPreferences: Equatable {
  var forwardedMessages: AppPrivacyChoice = .everybody
  var calls: AppPrivacyChoice = .everybody
  var phoneNumber: AppPrivacyChoice = .everybody
  var profilePhotos: AppPrivacyChoice = .everybody
  var bio: AppPrivacyChoice = .everybody
  var gifts: AppPrivacyChoice = .everybody
  var birthday: AppPrivacyChoice = .everybody
  var savedMusic: AppPrivacyChoice = .everybody
}

struct SettingsNotificationCategory: Equatable {
  var enabled = true
  var preview = true
  var sound = true
}

struct SettingsNotificationPreferences: Equatable {
  var privateChats = SettingsNotificationCategory()
  var groupChats = SettingsNotificationCategory()
  var channels = SettingsNotificationCategory()
  var stories = SettingsNotificationCategory()
  var reactions = SettingsNotificationCategory()
  var inAppSounds = true
  var inAppVibrate = true
  var inAppPreview = true
  var namesOnLockScreen = true
}

struct SettingsDeviceSession: Identifiable, Equatable {
  let id: String
  let deviceID: String
  let name: String
  let platform: String
  let lastSeenAt: Date?
  let createdAt: Date?
  let expiresAt: Date?
  let isCurrent: Bool

  var lastSeenDescription: String {
    guard let lastSeenAt else { return "Last seen recently" }
    return lastSeenAt.formatted(.relative(presentation: .named))
  }
}

struct SettingsProductionSnapshot: Equatable {
  let privacy: SettingsPrivacyPreferences
  let notifications: SettingsNotificationPreferences
}

enum SettingsProductionServiceError: LocalizedError {
  case invalidConfiguration
  case invalidResponse
  case currentSession
  case http(Int, String)

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration: return "The current account session is unavailable."
    case .invalidResponse: return "The settings service returned an invalid response."
    case .currentSession: return "This device's current session cannot be revoked."
    case let .http(code, body):
      let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
      return detail.isEmpty ? "Settings request failed (\(code))." : "Settings request failed (\(code)): \(detail)"
    }
  }
}

enum SettingsProductionService {
  static func fetch(config: AppSessionConfig) async throws -> SettingsProductionSnapshot {
    let object = try await request(config: config, method: "GET", path: "/settings")
    guard let privacy = object["privacy"] as? [String: Any],
      let notifications = object["notifications"] as? [String: Any]
    else { throw SettingsProductionServiceError.invalidResponse }
    return SettingsProductionSnapshot(
      privacy: decodePrivacy(privacy),
      notifications: decodeNotifications(notifications)
    )
  }

  static func updatePrivacy(_ value: SettingsPrivacyPreferences, config: AppSessionConfig) async throws -> SettingsPrivacyPreferences {
    let object = try await request(
      config: config, method: "PATCH", path: "/settings/privacy",
      body: ["privacy": encodePrivacy(value)]
    )
    guard let privacy = object["privacy"] as? [String: Any] else {
      throw SettingsProductionServiceError.invalidResponse
    }
    return decodePrivacy(privacy)
  }

  static func updateNotifications(_ value: SettingsNotificationPreferences, config: AppSessionConfig) async throws -> SettingsNotificationPreferences {
    let object = try await request(
      config: config, method: "PATCH", path: "/settings/notifications",
      body: ["notifications": encodeNotifications(value)]
    )
    guard let notifications = object["notifications"] as? [String: Any] else {
      throw SettingsProductionServiceError.invalidResponse
    }
    return decodeNotifications(notifications)
  }

  static func registerCurrentDevice(config: AppSessionConfig) async throws -> SettingsDeviceSession {
    let deviceID = SettingsDeviceIdentity.current
    let object = try await request(
      config: config, method: "POST", path: "/account/devices/current",
      body: ["deviceId": deviceID, "name": UIDevice.current.name, "platform": "ios"],
      deviceID: deviceID
    )
    guard let raw = object["device"] as? [String: Any], let session = decodeSession(raw) else {
      throw SettingsProductionServiceError.invalidResponse
    }
    return session
  }

  static func fetchSessions(config: AppSessionConfig) async throws -> [SettingsDeviceSession] {
    let object = try await request(
      config: config, method: "GET", path: "/account/sessions",
      deviceID: SettingsDeviceIdentity.current
    )
    guard let raw = object["sessions"] as? [[String: Any]] else {
      throw SettingsProductionServiceError.invalidResponse
    }
    return raw.compactMap(decodeSession)
  }

  static func revokeSession(id: String, config: AppSessionConfig) async throws {
    _ = try await request(
      config: config, method: "DELETE",
      path: "/account/sessions/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)",
      deviceID: SettingsDeviceIdentity.current
    )
  }

  private static func request(
    config: AppSessionConfig, method: String, path: String,
    body: [String: Any]? = nil, deviceID: String? = nil
  ) async throws -> [String: Any] {
    guard let url = apiURL(base: config.apiBaseURLString, path: path) else {
      throw SettingsProductionServiceError.invalidConfiguration
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    if let deviceID { request.setValue(deviceID, forHTTPHeaderField: "X-Vibe-Device-ID") }
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await VibeHTTP.shared.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw SettingsProductionServiceError.invalidResponse
    }
    guard (200...299).contains(response.statusCode) else {
      if response.statusCode == 409 { throw SettingsProductionServiceError.currentSession }
      throw SettingsProductionServiceError.http(response.statusCode, String(data: data, encoding: .utf8) ?? "")
    }
    if data.isEmpty { return [:] }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw SettingsProductionServiceError.invalidResponse
    }
    return object
  }

  private static func apiURL(base: String, path: String) -> URL? {
    var base = base.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    guard !base.isEmpty else { return nil }
    if !base.lowercased().hasSuffix("/api") { base += "/api" }
    return URL(string: base + path)
  }

  private static func encodePrivacy(_ value: SettingsPrivacyPreferences) -> [String: Any] {
    ["forwarded_messages": value.forwardedMessages.rawValue, "calls": value.calls.rawValue,
     "phone_number": value.phoneNumber.rawValue, "profile_photos": value.profilePhotos.rawValue,
     "bio": value.bio.rawValue, "gifts": value.gifts.rawValue, "birthday": value.birthday.rawValue,
     "saved_music": value.savedMusic.rawValue]
  }

  private static func decodePrivacy(_ raw: [String: Any]) -> SettingsPrivacyPreferences {
    func choice(_ key: String) -> AppPrivacyChoice {
      AppPrivacyChoice(rawValue: raw[key] as? String ?? "") ?? .everybody
    }
    return SettingsPrivacyPreferences(
      forwardedMessages: choice("forwarded_messages"), calls: choice("calls"),
      phoneNumber: choice("phone_number"), profilePhotos: choice("profile_photos"),
      bio: choice("bio"), gifts: choice("gifts"), birthday: choice("birthday"),
      savedMusic: choice("saved_music")
    )
  }

  private static func category(_ raw: Any?) -> SettingsNotificationCategory {
    let value = raw as? [String: Any] ?? [:]
    return SettingsNotificationCategory(
      enabled: value["enabled"] as? Bool ?? true,
      preview: value["preview"] as? Bool ?? true,
      sound: value["sound"] as? Bool ?? true
    )
  }

  private static func decodeNotifications(_ raw: [String: Any]) -> SettingsNotificationPreferences {
    let categories = raw["categories"] as? [String: Any] ?? [:]
    return SettingsNotificationPreferences(
      privateChats: category(categories["private_chats"]), groupChats: category(categories["group_chats"]),
      channels: category(categories["channels"]), stories: category(categories["stories"]),
      reactions: category(categories["reactions"]),
      inAppSounds: raw["in_app_sounds"] as? Bool ?? true,
      inAppVibrate: raw["in_app_vibrate"] as? Bool ?? true,
      inAppPreview: raw["in_app_preview"] as? Bool ?? true,
      namesOnLockScreen: raw["names_on_lock_screen"] as? Bool ?? true
    )
  }

  private static func encodeNotifications(_ value: SettingsNotificationPreferences) -> [String: Any] {
    func encode(_ category: SettingsNotificationCategory) -> [String: Any] {
      ["enabled": category.enabled, "preview": category.preview, "sound": category.sound]
    }
    return ["categories": ["private_chats": encode(value.privateChats), "group_chats": encode(value.groupChats),
      "channels": encode(value.channels), "stories": encode(value.stories), "reactions": encode(value.reactions)],
      "in_app_sounds": value.inAppSounds, "in_app_vibrate": value.inAppVibrate,
      "in_app_preview": value.inAppPreview, "names_on_lock_screen": value.namesOnLockScreen]
  }

  private static func decodeSession(_ raw: [String: Any]) -> SettingsDeviceSession? {
    guard let id = string(raw["id"]), let deviceID = string(raw["deviceId"] ?? raw["device_id"]) else { return nil }
    return SettingsDeviceSession(
      id: id, deviceID: deviceID, name: string(raw["name"]) ?? "Unknown device",
      platform: string(raw["platform"]) ?? "unknown", lastSeenAt: date(raw["lastSeenAt"] ?? raw["last_seen_at"]),
      createdAt: date(raw["createdAt"] ?? raw["created_at"]), expiresAt: date(raw["expiresAt"] ?? raw["expires_at"]),
      isCurrent: raw["isCurrent"] as? Bool ?? raw["is_current"] as? Bool ?? false
    )
  }

  private static func string(_ value: Any?) -> String? {
    if let value = value as? String, !value.isEmpty { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
  }

  private static func date(_ value: Any?) -> Date? {
    guard let value = value as? String else { return nil }
    return ISO8601DateFormatter.settingsFractional.date(from: value) ?? ISO8601DateFormatter.settingsBasic.date(from: value)
  }
}

private enum SettingsDeviceIdentity {
  static let key = "vibe.settings.device-id"
  static var current: String {
    if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty { return existing }
    let value = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    UserDefaults.standard.set(value, forKey: key)
    return value
  }
}

private extension ISO8601DateFormatter {
  static let settingsFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()
  static let settingsBasic = ISO8601DateFormatter()
}

@MainActor
final class SettingsProductionStore: ObservableObject {
  static let shared = SettingsProductionStore()

  @Published private(set) var privacy = SettingsPrivacyPreferences()
  @Published private(set) var notifications = SettingsNotificationPreferences()
  @Published private(set) var sessions: [SettingsDeviceSession] = []
  @Published private(set) var connectionStatus: AgentBridgeStatus?
  @Published private(set) var isLoading = false
  @Published private(set) var isSaving = false
  @Published private(set) var errorMessage: String?

  var currentSession: SettingsDeviceSession? { sessions.first(where: \.isCurrent) }
  private init() {}

  func load() async {
    guard let config = AppSessionConfig.current else { resetForMissingSession(); return }
    guard !isLoading else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      async let snapshot = SettingsProductionService.fetch(config: config)
      async let registered = SettingsProductionService.registerCurrentDevice(config: config)
      async let fetchedSessions = SettingsProductionService.fetchSessions(config: config)
      let (value, current, remoteSessions) = try await (snapshot, registered, fetchedSessions)
      privacy = value.privacy
      notifications = value.notifications
      sessions = remoteSessions.contains(where: { $0.id == current.id }) ? remoteSessions : [current] + remoteSessions
      await refreshConnection()
    } catch {
      handle(error, reason: "settings-load")
    }
  }

  func refreshConnection() async {
    guard let config = AppSessionConfig.current else { connectionStatus = nil; return }
    do { connectionStatus = try await AgentPairingService.status(config: config) }
    catch { handle(error, reason: "settings-connection") }
  }

  func updatePrivacy(_ value: SettingsPrivacyPreferences) async throws {
    try await save { config in self.privacy = try await SettingsProductionService.updatePrivacy(value, config: config) }
  }

  func updateNotifications(_ value: SettingsNotificationPreferences) async throws {
    try await save { config in self.notifications = try await SettingsProductionService.updateNotifications(value, config: config) }
  }

  func revokeSession(id: String) async throws {
    guard sessions.first(where: { $0.id == id })?.isCurrent != true else { throw SettingsProductionServiceError.currentSession }
    try await save { config in
      try await SettingsProductionService.revokeSession(id: id, config: config)
      self.sessions.removeAll { $0.id == id }
    }
  }

  func setAppearance(_ option: AppAppearanceOption) { AppAppearanceController.setOption(option) }
  func setThemePlate(_ option: AppThemePlateOption) { AppThemePlateController.setOption(option) }
  func clearError() { errorMessage = nil }

  private func save(_ operation: (AppSessionConfig) async throws -> Void) async throws {
    guard let config = AppSessionConfig.current else { throw SettingsProductionServiceError.invalidConfiguration }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do { try await operation(config) }
    catch { handle(error, reason: "settings-save"); throw error }
  }

  private func handle(_ error: Error, reason: String) {
    errorMessage = error.localizedDescription
    if case SettingsProductionServiceError.http(401, _) = error {
      Task { await AppSessionGuard.shared.recover(reason: reason) }
    }
  }

  private func resetForMissingSession() {
    privacy = SettingsPrivacyPreferences(); notifications = SettingsNotificationPreferences()
    sessions = []; connectionStatus = nil; isLoading = false; isSaving = false; errorMessage = nil
  }
}
