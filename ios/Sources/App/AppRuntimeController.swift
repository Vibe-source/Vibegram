import OSLog
import SwiftUI
import UIKit

private let appRuntimeUITraceLogger = Logger(
  subsystem: "com.mohammadshayani.vibe.native",
  category: "UITrace"
)

private func appRuntimeUITrace(_ message: String) {
  VibeDebugLog.notice(logger: appRuntimeUITraceLogger, message)
  VibeDebugLog.log("[VibeUITrace] %@", message)
}

enum AppAppearanceOption: String, CaseIterable, Identifiable {
  case system
  case light
  case dark

  var id: String { rawValue }

  var title: String {
    switch self {
    case .system:
      return "System"
    case .light:
      return "Light"
    case .dark:
      return "Dark"
    }
  }

  var interfaceStyle: UIUserInterfaceStyle {
    switch self {
    case .system:
      return .unspecified
    case .light:
      return .light
    case .dark:
      return .dark
    }
  }
}

enum AppAppearanceController {
  static let storageKey = "vibe.app.appearance"

  static var currentOption: AppAppearanceOption {
    let rawValue =
      UserDefaults.standard.string(forKey: storageKey)
      ?? AppAppearanceOption.system.rawValue
    return AppAppearanceOption(rawValue: rawValue) ?? .system
  }

  static func setOption(_ option: AppAppearanceOption) {
    UserDefaults.standard.set(option.rawValue, forKey: storageKey)
    applyStoredPreference()
    var draft = ChatAppearanceDraftStore.current
    if draft.mode != option.rawValue {
      draft.mode = option.rawValue
      if let themeId = draft.themeId {
        draft = draft.applying(themeId: themeId)
      }
      ChatAppearanceDraftStore.save(draft)
    }
    ChatListAppearance.invalidateBootstrap()
    NotificationCenter.default.post(
      name: ChatAppearanceDraftStore.didChangeNotification,
      object: nil
    )
  }

  static func applyStoredPreference(to window: UIWindow? = nil) {
    let style = currentOption.interfaceStyle

    if let window {
      window.overrideUserInterfaceStyle = style
    }

    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for sceneWindow in windowScene.windows {
        sceneWindow.overrideUserInterfaceStyle = style
      }
    }
  }

  /// iOS renders the app-switcher snapshot in BOTH interface styles, so backgrounding flips
  /// userInterfaceStyle across the hierarchy and every theme handler reruns. Pinning the
  /// window stops that flip at the top instead of paying for it in every view.
  static func pinCurrentStyleForSnapshot() {
    guard currentOption == .system else { return }
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      for sceneWindow in windowScene.windows
      where sceneWindow.overrideUserInterfaceStyle == .unspecified {
        sceneWindow.overrideUserInterfaceStyle = sceneWindow.traitCollection.userInterfaceStyle
      }
    }
  }

  /// Released only once the app is active again, which is what lets a style the user
  /// changed while we were pinned land through the normal trait path.
  static func releaseSnapshotStylePin() {
    guard currentOption == .system else { return }
    applyStoredPreference()
  }
}

enum AppPrivacyChoice: String, CaseIterable, Identifiable {
  case everybody
  case contacts
  case nobody

  var id: String { rawValue }

  var title: String {
    switch self {
    case .everybody:
      return "Everybody"
    case .contacts:
      return "My Contacts"
    case .nobody:
      return "Nobody"
    }
  }
}

enum AppThemePlateOption: String, CaseIterable, Identifiable {
  case glacier
  case zen
  case ocean
  case obsidian
  case music
  case terracotta
  case leaf

  var id: String { rawValue }

  var title: String {
    switch self {
    case .glacier:
      return "Aurora"
    case .zen:
      return "Mist"
    case .ocean:
      return "Fresh"
    case .obsidian:
      return "Mono"
    case .music:
      return "Pulse"
    case .terracotta:
      return "Ember"
    case .leaf:
      return "Leaf"
    }
  }
}

enum AppThemePlateController {
  static let storageKey = "vibe.app.themePlate"

  static var currentOption: AppThemePlateOption {
    let rawValue =
      UserDefaults.standard.string(forKey: storageKey)
      ?? AppThemePlateOption.glacier.rawValue
    return AppThemePlateOption(rawValue: rawValue) ?? .glacier
  }

  static func setOption(_ option: AppThemePlateOption) {
    UserDefaults.standard.set(option.rawValue, forKey: storageKey)
    // Same reason as AppAppearanceController.setOption — the chat draft names its own plate.
    var draft = ChatAppearanceDraftStore.current
    if draft.themeId != option.rawValue {
      draft.themeId = option.rawValue
      ChatAppearanceDraftStore.save(draft)
    }
    ChatListAppearance.invalidateBootstrap()
  }
}

struct AppThemePalette {
  let backgroundUIColor: UIColor
  let secondaryBackgroundUIColor: UIColor
  let cardUIColor: UIColor
  let inputUIColor: UIColor
  let elevatedUIColor: UIColor
  let textUIColor: UIColor
  let secondaryTextUIColor: UIColor
  let tertiaryTextUIColor: UIColor
  let accentUIColor: UIColor
  let accentMutedUIColor: UIColor
  let buttonUIColor: UIColor
  let buttonTextUIColor: UIColor
  let bubbleMeUIColor: UIColor
  let bubbleThemUIColor: UIColor
  let borderUIColor: UIColor
  let dividerUIColor: UIColor
  let overlayUIColor: UIColor
  let successUIColor: UIColor
  let warningUIColor: UIColor
  let dangerUIColor: UIColor

  var background: Color { Color(uiColor: backgroundUIColor) }
  var secondaryBackground: Color { Color(uiColor: secondaryBackgroundUIColor) }
  var card: Color { Color(uiColor: cardUIColor) }
  var input: Color { Color(uiColor: inputUIColor) }
  var elevated: Color { Color(uiColor: elevatedUIColor) }
  var text: Color { Color(uiColor: textUIColor) }
  var secondaryText: Color { Color(uiColor: secondaryTextUIColor) }
  var tertiaryText: Color { Color(uiColor: tertiaryTextUIColor) }
  var accent: Color { Color(uiColor: accentUIColor) }
  var accentMuted: Color { Color(uiColor: accentMutedUIColor) }
  var button: Color { Color(uiColor: buttonUIColor) }
  var buttonText: Color { Color(uiColor: buttonTextUIColor) }
  var bubbleMe: Color { Color(uiColor: bubbleMeUIColor) }
  var bubbleThem: Color { Color(uiColor: bubbleThemUIColor) }
  var border: Color { Color(uiColor: borderUIColor) }
  var divider: Color { Color(uiColor: dividerUIColor) }
  var overlay: Color { Color(uiColor: overlayUIColor) }
  var success: Color { Color(uiColor: successUIColor) }
  var warning: Color { Color(uiColor: warningUIColor) }
  var danger: Color { Color(uiColor: dangerUIColor) }

  static func resolve(
    for colorScheme: ColorScheme,
    plate: AppThemePlateOption = AppThemePlateController.currentOption
  ) -> AppThemePalette {
    let isDark = colorScheme == .dark
    let baseBackground = isDark ? hex(0x000000) : hex(0xFFFFFF)
    let baseSecondaryBackground = isDark ? hex(0x151515) : hex(0xF5F4F1)
    let baseCard = isDark ? hex(0x242424) : hex(0xFFFFFF)
    let baseInput = isDark ? hex(0x222222) : hex(0xF2F2F2)
    let baseElevated = isDark ? hex(0x252530) : hex(0xFFFFFF)
    let text = isDark ? hex(0xE8E6F0) : hex(0x1A1A1F)
    let secondaryText = isDark ? hex(0x9896A8) : hex(0x5A5A66)
    let tertiaryText = isDark ? hex(0x5D5B6B) : hex(0x9A9AA3)

    let accent: UIColor
    let accentMuted: UIColor
    let button: UIColor
    let bubbleMe: UIColor
    let bubbleThem: UIColor

    switch (plate, isDark) {
    case (.glacier, true):
      accent = hex(0x3B8AE8)
      accentMuted = rgba(59, 138, 232, 0.6)
      button = hex(0x3B8AE8)
      bubbleMe = hex(0x3B8AE8)
      bubbleThem = hex(0x242936)
    case (.glacier, false):
      accent = hex(0x3B8AE8)
      accentMuted = rgba(59, 138, 232, 0.6)
      button = hex(0x3B8AE8)
      bubbleMe = hex(0x3B8AE8)
      bubbleThem = hex(0xFFFFFF)
    case (.zen, true):
      accent = hex(0x2F80ED)
      accentMuted = rgba(47, 128, 237, 0.6)
      button = hex(0x2F80ED)
      bubbleMe = hex(0x2F80ED)
      bubbleThem = hex(0x1E2732)
    case (.zen, false):
      accent = hex(0x2F7FE0)
      accentMuted = rgba(47, 127, 224, 0.6)
      button = hex(0x2F7FE0)
      bubbleMe = hex(0x2F7FE0)
      bubbleThem = hex(0xFFFFFF)
    case (.ocean, true):
      accent = hex(0x2C9A68)
      accentMuted = rgba(44, 154, 104, 0.6)
      button = hex(0x2C9A68)
      bubbleMe = hex(0x2C9A68)
      bubbleThem = hex(0x1F2B28)
    case (.ocean, false):
      accent = hex(0x2E9B6E)
      accentMuted = rgba(46, 155, 110, 0.6)
      button = hex(0x2E9B6E)
      bubbleMe = hex(0x2E9B6E)
      bubbleThem = hex(0xFFFFFF)
    case (.obsidian, true):
      accent = hex(0x3D6EA8)
      accentMuted = rgba(61, 110, 168, 0.6)
      button = hex(0x3D6EA8)
      bubbleMe = hex(0x3D6EA8)
      bubbleThem = hex(0x20232B)
    case (.obsidian, false):
      accent = hex(0x4A6FA0)
      accentMuted = rgba(74, 111, 160, 0.6)
      button = hex(0x4A6FA0)
      bubbleMe = hex(0x4A6FA0)
      bubbleThem = hex(0xFFFFFF)
    case (.music, true):
      accent = hex(0xC43B88)
      accentMuted = rgba(196, 59, 136, 0.6)
      button = hex(0xC43B88)
      bubbleMe = hex(0xC43B88)
      bubbleThem = hex(0x2A202D)
    case (.music, false):
      accent = hex(0xC43B88)
      accentMuted = rgba(196, 59, 136, 0.6)
      button = hex(0xC43B88)
      bubbleMe = hex(0xC43B88)
      bubbleThem = hex(0xFFFFFF)
    case (.terracotta, true):
      accent = hex(0xC85A28)
      accentMuted = rgba(200, 90, 40, 0.6)
      button = hex(0xC85A28)
      bubbleMe = hex(0xC85A28)
      bubbleThem = hex(0x29231F)
    case (.terracotta, false):
      accent = hex(0xC85A28)
      accentMuted = rgba(200, 90, 40, 0.6)
      button = hex(0xC85A28)
      bubbleMe = hex(0xC85A28)
      bubbleThem = hex(0xFFFFFF)
    case (.leaf, true):
      accent = hex(0x3A9B4A)
      accentMuted = rgba(58, 155, 74, 0.6)
      button = hex(0x3A9B4A)
      bubbleMe = hex(0x3A9B4A)
      bubbleThem = hex(0x1F2A22)
    case (.leaf, false):
      accent = hex(0x3D9B40)
      accentMuted = rgba(61, 155, 64, 0.6)
      button = hex(0x3D9B40)
      bubbleMe = hex(0x3D9B40)
      bubbleThem = hex(0xFFFFFF)
    }

    return AppThemePalette(
      backgroundUIColor: baseBackground,
      secondaryBackgroundUIColor: baseSecondaryBackground,
      cardUIColor: baseCard,
      inputUIColor: baseInput,
      elevatedUIColor: baseElevated,
      textUIColor: text,
      secondaryTextUIColor: secondaryText,
      tertiaryTextUIColor: tertiaryText,
      accentUIColor: accent,
      accentMutedUIColor: accentMuted,
      buttonUIColor: button,
      buttonTextUIColor: isDark ? hex(0xFAFBFC) : hex(0xFEFEFE),
      bubbleMeUIColor: bubbleMe,
      bubbleThemUIColor: bubbleThem,
      borderUIColor: isDark ? rgba(248, 246, 252, 0.09) : rgba(26, 26, 31, 0.07),
      dividerUIColor: isDark ? rgba(248, 246, 252, 0.05) : rgba(26, 26, 31, 0.035),
      overlayUIColor: isDark ? rgba(13, 13, 18, 0.88) : rgba(250, 249, 247, 0.90),
      successUIColor: isDark ? hex(0x5ABF8F) : hex(0x428A6A),
      warningUIColor: isDark ? hex(0xC9A33D) : hex(0xB89338),
      dangerUIColor: isDark ? hex(0xD45A5A) : hex(0xC44A4A)
    )
  }

  private static func hex(_ value: UInt, alpha: CGFloat = 1.0) -> UIColor {
    UIColor(
      red: CGFloat((value >> 16) & 0xFF) / 255.0,
      green: CGFloat((value >> 8) & 0xFF) / 255.0,
      blue: CGFloat(value & 0xFF) / 255.0,
      alpha: alpha
    )
  }

  private static func rgba(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat)
    -> UIColor
  {
    UIColor(
      red: red / 255.0,
      green: green / 255.0,
      blue: blue / 255.0,
      alpha: alpha
    )
  }
}

@MainActor
final class AppToastController: ObservableObject {
  enum Category: Equatable {
    case info
    case success
    case error
    case progress
  }

  struct Presentation: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let category: Category
  }

  static let shared = AppToastController()

  @Published private(set) var presentation: Presentation?
  var message: String? { presentation?.message }
  private var hideTask: Task<Void, Never>?

  private init() {}

  func show(
    _ message: String,
    category: Category? = nil,
    duration: TimeInterval = 2.6
  ) {
    hideTask?.cancel()
    presentation = Presentation(
      message: message,
      category: category ?? Self.inferredCategory(for: message)
    )
    hideTask = Task { [weak self] in
      guard duration > 0 else { return }
      try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self?.presentation = nil
      }
    }
  }

  func clear() {
    hideTask?.cancel()
    hideTask = nil
    presentation = nil
  }

  private static func inferredCategory(for message: String) -> Category {
    let value = message.lowercased()
    let errorWords = ["error", "fail", "couldn", "unavailable", "required", "missing", "not found", "denied"]
    if errorWords.contains(where: value.contains) { return .error }

    let progressWords = ["sending", "loading", "connecting", "updating", "preparing"]
    if progressWords.contains(where: value.contains) { return .progress }

    let successWords = ["copied", "saved", "updated", "sent", "deleted", "removed", "complete", "success", "thanks"]
    if successWords.contains(where: value.contains) { return .success }
    return .info
  }
}

struct AppUserProfile: Equatable {
  let userID: String
  let username: String
  let name: String?
  let phoneNumber: String?
  let bio: String?
  let dateOfBirth: String?
  let profileImage: String?
  let showLastSeen: Bool
  let showOnlineStatus: Bool
  let autoDeleteTimer: Int?
  let privacyLastSeen: AppPrivacyChoice
  let privacyForward: AppPrivacyChoice
  let privacyCalls: AppPrivacyChoice
  let privacyPhoneNumber: AppPrivacyChoice
  let privacyProfilePhotos: AppPrivacyChoice
  let privacyBio: AppPrivacyChoice
  let privacyGifts: AppPrivacyChoice
  let privacyBirthday: AppPrivacyChoice
  let privacySavedMusic: AppPrivacyChoice
  /// Public share link as the SERVER built it (it owns the share host, which moves when
  /// the domain changes). Nil on older servers; `shareLink` then falls back locally.
  let serverShareLink: String?

  var displayName: String {
    name?.nilIfBlank ?? username
  }

  /// The one link this person can hand to anyone: `vibegram.io/<username>`.
  var shareLink: String? {
    serverShareLink?.nilIfBlank ?? VibeShareLinks.profileURL(username: username)
  }

  /// Same link without the scheme, for display.
  var shareLinkDisplay: String? {
    VibeShareLinks.display(shareLink)
  }

  var subtitle: String {
    if let phoneNumber, !phoneNumber.isEmpty {
      return phoneNumber
    }
    return "@\(username)"
  }

  init?(
    userID: String,
    username: String,
    name: String? = nil,
    phoneNumber: String? = nil,
    bio: String? = nil,
    dateOfBirth: String? = nil,
    profileImage: String? = nil,
    showLastSeen: Bool = true,
    showOnlineStatus: Bool = true,
    autoDeleteTimer: Int? = nil,
    privacyLastSeen: AppPrivacyChoice = .everybody,
    privacyForward: AppPrivacyChoice = .everybody,
    privacyCalls: AppPrivacyChoice = .everybody,
    privacyPhoneNumber: AppPrivacyChoice = .everybody,
    privacyProfilePhotos: AppPrivacyChoice = .everybody,
    privacyBio: AppPrivacyChoice = .everybody,
    privacyGifts: AppPrivacyChoice = .everybody,
    privacyBirthday: AppPrivacyChoice = .everybody,
    privacySavedMusic: AppPrivacyChoice = .everybody,
    serverShareLink: String? = nil
  ) {
    let resolvedUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolvedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !resolvedUserID.isEmpty, !resolvedUsername.isEmpty else { return nil }

    self.userID = resolvedUserID
    self.username = resolvedUsername
    self.name = name?.nilIfBlank
    self.phoneNumber = phoneNumber?.nilIfBlank
    self.bio = bio?.nilIfBlank
    self.dateOfBirth = dateOfBirth?.nilIfBlank
    self.profileImage = profileImage?.nilIfBlank
    self.showLastSeen = showLastSeen
    self.showOnlineStatus = showOnlineStatus
    self.autoDeleteTimer = autoDeleteTimer
    self.privacyLastSeen = privacyLastSeen
    self.privacyForward = privacyForward
    self.privacyCalls = privacyCalls
    self.privacyPhoneNumber = privacyPhoneNumber
    self.privacyProfilePhotos = privacyProfilePhotos
    self.privacyBio = privacyBio
    self.privacyGifts = privacyGifts
    self.privacyBirthday = privacyBirthday
    self.privacySavedMusic = privacySavedMusic
    self.serverShareLink = serverShareLink?.nilIfBlank
  }

  init?(payload: [String: Any], fallbackConfig: AppSessionConfig? = nil) {
    let fallbackUserID = fallbackConfig?.userID ?? ""
    let fallbackUsername = fallbackConfig?.username ?? fallbackConfig?.name ?? ""
    let userID = Self.normalizedString(payload["userId"] ?? payload["id"]) ?? fallbackUserID
    let username =
      Self.normalizedString(payload["username"])
      ?? Self.normalizedString(payload["name"])
      ?? fallbackUsername

    guard let profile = AppUserProfile(
      userID: userID,
      username: username,
      name: Self.normalizedString(payload["name"]) ?? fallbackConfig?.name,
      phoneNumber: Self.normalizedString(payload["phoneNumber"] ?? payload["phone"])
        ?? fallbackConfig?.phoneNumber,
      bio: Self.normalizedString(payload["bio"]) ?? fallbackConfig?.bio,
      dateOfBirth: Self.normalizedString(payload["dateOfBirth"]) ?? fallbackConfig?.dateOfBirth,
      profileImage: Self.normalizedString(payload["profileImage"] ?? payload["profile_image"])
        ?? fallbackConfig?.profileImage,
      showLastSeen: Self.normalizedBool(payload["showLastSeen"]) ?? fallbackConfig?.showLastSeen
        ?? true,
      showOnlineStatus: Self.normalizedBool(payload["showOnlineStatus"])
        ?? fallbackConfig?.showOnlineStatus ?? true,
      autoDeleteTimer: Self.normalizedInt(payload["autoDeleteTimer"])
        ?? fallbackConfig?.autoDeleteTimer,
      privacyLastSeen: Self.normalizedPrivacyChoice(payload["privacyLastSeen"])
        ?? Self.normalizedPrivacyChoice(fallbackConfig?.privacyLastSeen) ?? .everybody,
      privacyForward: Self.normalizedPrivacyChoice(payload["privacyForward"])
        ?? Self.normalizedPrivacyChoice(fallbackConfig?.privacyForward) ?? .everybody,
      privacyCalls: Self.normalizedPrivacyChoice(payload["privacyCalls"])
        ?? Self.normalizedPrivacyChoice(fallbackConfig?.privacyCalls) ?? .everybody,
      privacyPhoneNumber: Self.normalizedPrivacyChoice(payload["privacyPhoneNumber"])
        ?? Self.normalizedPrivacyChoice(fallbackConfig?.privacyPhoneNumber) ?? .everybody,
      privacyProfilePhotos: Self.normalizedPrivacyChoice(payload["privacyProfilePhotos"])
        ?? Self.normalizedPrivacyChoice(fallbackConfig?.privacyProfilePhotos) ?? .everybody,
      privacyBio: Self.normalizedPrivacyChoice(payload["privacyBio"])
        ?? Self.normalizedPrivacyChoice(fallbackConfig?.privacyBio) ?? .everybody,
      privacyGifts: Self.normalizedPrivacyChoice(payload["privacyGifts"])
        ?? Self.normalizedPrivacyChoice(fallbackConfig?.privacyGifts) ?? .everybody,
      privacyBirthday: Self.normalizedPrivacyChoice(payload["privacyBirthday"])
        ?? Self.normalizedPrivacyChoice(fallbackConfig?.privacyBirthday) ?? .everybody,
      privacySavedMusic: Self.normalizedPrivacyChoice(payload["privacySavedMusic"])
        ?? Self.normalizedPrivacyChoice(fallbackConfig?.privacySavedMusic) ?? .everybody,
      serverShareLink: Self.normalizedString(payload["shareLink"] ?? payload["share_link"])
    ) else {
      return nil
    }

    self = profile
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

  private static func normalizedBool(_ value: Any?) -> Bool? {
    if let value = value as? Bool {
      return value
    }
    if let value = value as? NSNumber {
      return value.boolValue
    }
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

  private static func normalizedInt(_ value: Any?) -> Int? {
    if let value = value as? Int {
      return value
    }
    if let value = value as? NSNumber {
      return value.intValue
    }
    if let value = value as? String {
      return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return nil
  }

  private static func normalizedPrivacyChoice(_ value: Any?) -> AppPrivacyChoice? {
    guard let value = normalizedString(value) else { return nil }
    return AppPrivacyChoice(rawValue: value)
  }
}

struct AppUserProfileDraft: Equatable {
  var name: String
  var username: String
  var phoneNumber: String
  var bio: String
  var dateOfBirth: String
  /// Remote URL after media upload — never raw bytes.
  var profileImage: String?

  init(profile: AppUserProfile?) {
    self.name = profile?.name ?? ""
    self.username = profile?.username ?? AppSessionConfig.current?.username ?? ""
    self.phoneNumber = profile?.phoneNumber ?? AppSessionConfig.current?.phoneNumber ?? ""
    self.bio = profile?.bio ?? ""
    self.dateOfBirth = profile?.dateOfBirth ?? ""
    self.profileImage = profile?.profileImage
  }

  var trimmedPayload: [String: Any] {
    var body: [String: Any] = [
      "name": name.trimmingCharacters(in: .whitespacesAndNewlines),
      "username": username.trimmingCharacters(in: .whitespacesAndNewlines),
      "phoneNumber": phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines),
      "bio": bio.trimmingCharacters(in: .whitespacesAndNewlines),
      "dateOfBirth": dateOfBirth.trimmingCharacters(in: .whitespacesAndNewlines),
    ]
    if let profileImage = profileImage?.trimmingCharacters(in: .whitespacesAndNewlines),
      !profileImage.isEmpty
    {
      body["profileImage"] = profileImage
    }
    return body
  }
}

@MainActor
final class AppProfileController: ObservableObject {
  static let shared = AppProfileController()

  @Published private(set) var profile: AppUserProfile?
  @Published private(set) var isLoading = false
  @Published private(set) var errorMessage: String?

  private var hasLoaded = false

  private init() {}

  func loadIfNeeded() async {
    appRuntimeUITrace(
      "AppProfileController loadIfNeeded hasLoaded=\(hasLoaded) isLoading=\(isLoading) hasProfile=\(profile != nil)"
    )
    if profile == nil {
      seedFromCurrentSession()
    }
    guard !hasLoaded, !isLoading else { return }
    await refresh()
  }

  func refresh() async {
    guard !isLoading else {
      appRuntimeUITrace("AppProfileController refresh skipped alreadyLoading")
      return
    }
    guard let config = AppSessionConfig.current else {
      profile = nil
      hasLoaded = false
      errorMessage = nil
      return
    }

    let startedAt = CFAbsoluteTimeGetCurrent()
    appRuntimeUITrace("AppProfileController refresh start userId=\(config.userID)")
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      let fetchedProfile = try await AppProfileService.fetchProfile(config: config)
      profile = fetchedProfile
      hasLoaded = true
      persistProfileToSession(fetchedProfile)
      let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
      appRuntimeUITrace(
        "AppProfileController refresh success durationMs=\(durationMs) hasImage=\(fetchedProfile.profileImage != nil)"
      )
    } catch {
      if let serviceError = error as? AppProfileServiceError, case .http(401, _) = serviceError {
        Task { await AppSessionGuard.shared.recover(reason: "profile-refresh") }
      }
      errorMessage = error.localizedDescription
      if profile == nil {
        seedFromCurrentSession()
      }
      let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
      appRuntimeUITrace(
        "AppProfileController refresh error durationMs=\(durationMs) error=\(error.localizedDescription)"
      )
    }
  }

  func update(_ draft: AppUserProfileDraft) async throws {
    guard let config = AppSessionConfig.current else {
      throw AppProfileServiceError.invalidConfiguration
    }

    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      let updatedProfile = try await AppProfileService.updateProfile(config: config, draft: draft)
      profile = updatedProfile
      hasLoaded = true
      persistProfileToSession(updatedProfile)
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  func updateFields(_ fields: [String: Any]) async throws {
    guard let config = AppSessionConfig.current else {
      throw AppProfileServiceError.invalidConfiguration
    }

    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      let updatedProfile = try await AppProfileService.updateFields(config: config, fields: fields)
      profile = updatedProfile
      hasLoaded = true
      persistProfileToSession(updatedProfile)
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  func reset() {
    profile = nil
    isLoading = false
    errorMessage = nil
    hasLoaded = false
  }

  private func seedFromCurrentSession() {
    guard let config = AppSessionConfig.current else { return }
    profile =
      AppUserProfile(
        userID: config.userID,
        username: config.username ?? config.name ?? config.userID,
        name: config.name,
        phoneNumber: config.phoneNumber,
        bio: config.bio,
        dateOfBirth: config.dateOfBirth,
        profileImage: config.profileImage,
        showLastSeen: config.showLastSeen ?? true,
        showOnlineStatus: config.showOnlineStatus ?? true,
        autoDeleteTimer: config.autoDeleteTimer,
        privacyLastSeen: AppPrivacyChoice(rawValue: config.privacyLastSeen ?? "") ?? .everybody,
        privacyForward: AppPrivacyChoice(rawValue: config.privacyForward ?? "") ?? .everybody,
        privacyCalls: AppPrivacyChoice(rawValue: config.privacyCalls ?? "") ?? .everybody,
        privacyPhoneNumber: AppPrivacyChoice(rawValue: config.privacyPhoneNumber ?? "") ?? .everybody,
        privacyProfilePhotos: AppPrivacyChoice(rawValue: config.privacyProfilePhotos ?? "")
          ?? .everybody,
        privacyBio: AppPrivacyChoice(rawValue: config.privacyBio ?? "") ?? .everybody,
        privacyGifts: AppPrivacyChoice(rawValue: config.privacyGifts ?? "") ?? .everybody,
        privacyBirthday: AppPrivacyChoice(rawValue: config.privacyBirthday ?? "") ?? .everybody,
        privacySavedMusic: AppPrivacyChoice(rawValue: config.privacySavedMusic ?? "")
          ?? .everybody
      )
  }

  private func persistProfileToSession(_ profile: AppUserProfile) {
    let changes: [String: Any?] = [
      "username": profile.username,
      "name": profile.name,
      "phoneNumber": profile.phoneNumber,
      "bio": profile.bio,
      "dateOfBirth": profile.dateOfBirth,
      "profileImage": profile.profileImage,
      "showLastSeen": profile.showLastSeen,
      "showOnlineStatus": profile.showOnlineStatus,
      "autoDeleteTimer": profile.autoDeleteTimer,
      "privacyLastSeen": profile.privacyLastSeen.rawValue,
      "privacyForward": profile.privacyForward.rawValue,
      "privacyCalls": profile.privacyCalls.rawValue,
      "privacyPhoneNumber": profile.privacyPhoneNumber.rawValue,
      "privacyProfilePhotos": profile.privacyProfilePhotos.rawValue,
      "privacyBio": profile.privacyBio.rawValue,
      "privacyGifts": profile.privacyGifts.rawValue,
      "privacyBirthday": profile.privacyBirthday.rawValue,
      "privacySavedMusic": profile.privacySavedMusic.rawValue,
    ]
    let startedAt = CFAbsoluteTimeGetCurrent()
    appRuntimeUITrace("AppProfileController persistProfile schedule keys=\(changes.count)")
    ChatEngineStore.shared.updateConfigAsync(changes) {
      let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
      appRuntimeUITrace("AppProfileController persistProfile done durationMs=\(durationMs)")
    }
  }
}

private enum AppProfileService {
  static func fetchProfile(config: AppSessionConfig) async throws -> AppUserProfile {
    guard let url = apiURL(base: config.apiBaseURLString, path: "/user/\(config.userID)") else {
      throw AppProfileServiceError.invalidConfiguration
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 15
    applyHeaders(&request, token: config.authToken)

    let (data, response) = try await VibeHTTP.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw AppProfileServiceError.invalidResponse
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      throw AppProfileServiceError.http(
        httpResponse.statusCode,
        String(data: data, encoding: .utf8) ?? ""
      )
    }

    guard
      let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        as? [String: Any],
      let profile = AppUserProfile(payload: raw, fallbackConfig: config)
    else {
      throw AppProfileServiceError.invalidResponse
    }
    return profile
  }

  static func updateProfile(config: AppSessionConfig, draft: AppUserProfileDraft) async throws
    -> AppUserProfile
  {
    var body = draft.trimmedPayload
    body["userId"] = config.userID
    return try await sendProfileUpdate(config: config, body: body)
  }

  static func updateFields(config: AppSessionConfig, fields: [String: Any]) async throws
    -> AppUserProfile
  {
    var body = fields
    body["userId"] = config.userID
    return try await sendProfileUpdate(config: config, body: body)
  }

  private static func sendProfileUpdate(config: AppSessionConfig, body: [String: Any]) async throws
    -> AppUserProfile
  {
    guard let url = apiURL(base: config.apiBaseURLString, path: "/user/profile") else {
      throw AppProfileServiceError.invalidConfiguration
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    applyHeaders(&request, token: config.authToken)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await VibeHTTP.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw AppProfileServiceError.invalidResponse
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      throw AppProfileServiceError.http(
        httpResponse.statusCode,
        String(data: data, encoding: .utf8) ?? ""
      )
    }

    guard
      let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        as? [String: Any],
      let profile = AppUserProfile(payload: raw, fallbackConfig: config)
    else {
      throw AppProfileServiceError.invalidResponse
    }
    return profile
  }

  private static func apiURL(base: String, path: String) -> URL? {
    var normalized = base.trimmingCharacters(in: .whitespacesAndNewlines)
    while normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    guard !normalized.isEmpty else { return nil }

    let pathBase = normalized.lowercased().hasSuffix("/api") ? normalized : "\(normalized)/api"
    return URL(string: pathBase + path)
  }

  private static func applyHeaders(_ request: inout URLRequest, token: String) {
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
  }
}

enum AppProfileServiceError: LocalizedError {
  case invalidConfiguration
  case invalidResponse
  case http(Int, String)

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      return "The current session is missing profile configuration."
    case .invalidResponse:
      return "The profile service returned an invalid response."
    case let .http(statusCode, body):
      let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? "Profile update failed (\(statusCode))."
        : "Profile update failed (\(statusCode)): \(trimmed)"
    }
  }
}

@MainActor
enum AppRootControllerFactory {
  static func makeInitialController() -> UIViewController {
    if AppSessionConfig.current != nil {
      return makeAuthenticatedController()
    }
    return makeWelcomeController()
  }

  static func makeAuthenticatedController() -> UIViewController {
    // Native UIKit tab shell wrapped in a root navigation controller. A chat
    // conversation is pushed onto the wrapping nav so it slides in z-above all
    // four tabs (openable from any tab, never nested in Home); the tabs host
    // their SwiftUI pages.
    let tabBarController = AppRootTabBarController()
    let rootNav = AppRootNavigationController(rootViewController: tabBarController)
    tabBarController.coordinator.rootNavigationController = rootNav
    return rootNav
  }

  static func makeWelcomeController() -> UIViewController {
    let navigationController = UINavigationController(rootViewController: WelcomeViewController())
    navigationController.navigationBar.prefersLargeTitles = true
    return navigationController
  }

  static func showAuthenticatedRoot(animated: Bool = true) {
    replaceRoot(with: makeAuthenticatedController(), animated: animated, slideIn: animated)
  }

  static func showWelcomeRoot(animated: Bool = true) {
    replaceRoot(with: makeWelcomeController(), animated: animated, slideIn: false)
  }

  static func signOut(animated: Bool = true) {
    AppProfileController.shared.reset()
    AppToastController.shared.clear()
    ChatEngineStore.shared.clearConfig()
    showWelcomeRoot(animated: animated)
  }

  private static func replaceRoot(with controller: UIViewController, animated: Bool, slideIn: Bool = false) {
    guard let window = activeWindow() else { return }

    let applyRoot = {
      window.rootViewController = controller
      AppAppearanceController.applyStoredPreference(to: window)
      window.makeKeyAndVisible()
    }

    if animated {
      if slideIn {
        let transition = CATransition()
        transition.duration = 0.32
        transition.type = .push
        transition.subtype = .fromRight
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        window.layer.add(transition, forKey: kCATransition)
        applyRoot()
      } else {
        UIView.transition(
          with: window,
          duration: 0.25,
          options: [.transitionCrossDissolve, .allowAnimatedContent]
        ) {
          applyRoot()
        }
      }
    } else {
      applyRoot()
    }
  }

  private static func activeWindow() -> UIWindow? {
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
        return keyWindow
      }
    }
    return nil
  }
}

private extension String {
  var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// Central recovery for an expired or rejected session token.
///
/// When the server stops accepting our `login_token` — a 401 "Token expired" /
/// "Invalid token" on REST, or a refused WebSocket handshake — every data path
/// fails at once. Without recovery the app spins forever retrying the dead token
/// (chats, profile, pinned, and the socket all 401 with the same token).
///
/// Instead we silently re-mint a token from the `loginSecret` kept in the Keychain
/// (the same credential the user signed in with), restore the session, and
/// reconnect — no interaction needed. This pairs with server-side sliding
/// expiration (which keeps actively-used tokens alive) and is the safety net for
/// cold cases: reinstall, a long idle gap, or a token rotated by signing in on
/// another device.
///
/// It deliberately NEVER signs the user out: with key-only login, proactively
/// clearing a session over a transient hiccup (a 5xx on `/login`, or a Keychain
/// read that fails because the device is briefly locked) could strand a user who no
/// longer has their secret key. When a refresh can't succeed we just stay put and
/// retry later — cached content remains, and the user can still act manually.
///
/// Every 401 site may call `recover(reason:)` freely: concurrent and rapid-repeat
/// calls collapse into a single in-flight refresh, and a short throttle stops a
/// burst of already-in-flight stale 401s from hammering `/login`.
actor AppSessionGuard {
  static let shared = AppSessionGuard()

  /// Posted on the main thread after the session token is successfully refreshed,
  /// so polling UI can re-fetch immediately instead of waiting for the next tick.
  static let didRefreshNotification = Notification.Name("Vibe.AppSessionGuard.didRefresh")

  private static let loginSecretKey = "loginSecret"

  private var isRecovering = false
  private var lastAttemptAt: Date?
  /// Minimum spacing between refresh attempts — covers both the post-success window
  /// (stale 401s already on the wire) and back-to-back transient failures.
  private let minAttemptInterval: TimeInterval = 4

  private init() {}

  func recover(reason: String) async {
    if isRecovering { return }
    let now = Date()
    if let last = lastAttemptAt, now.timeIntervalSince(last) < minAttemptInterval { return }
    lastAttemptAt = now
    isRecovering = true
    defer { isRecovering = false }

    guard let config = AppSessionConfig.current else { return }

    let storedSecret = SecureKeyStore.shared.retrieveSecret(key: Self.loginSecretKey)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let secret = storedSecret, !secret.isEmpty else {
      // No credential available right now (never stored, or a transient Keychain
      // read while the device is locked). Don't tear anything down — retry later.
      NSLog("[AppSessionGuard] recover(%@): no loginSecret available, will retry later", reason)
      return
    }

    NSLog("[AppSessionGuard] recover(%@): refreshing session token", reason)
    do {
      let result = try await NativeAuthService.signIn(
        secret: secret,
        apiBaseURLString: config.apiBaseURLString,
        transportMode: config.transportMode
      )
      AppSessionConfig.store(result.config)
      // store() clears Keychain secrets — put the login secret back so a later
      // recovery still has it.
      _ = SecureKeyStore.shared.storeSecret(key: Self.loginSecretKey, value: secret)
      NSLog("[AppSessionGuard] recover(%@): session refreshed, reconnecting", reason)
      await MainActor.run {
        // The socket signature includes the auth token, so connect() tears down the
        // stale socket and rebuilds it with the fresh token; REST paths read the
        // new token from AppSessionConfig on their next call.
        _ = ChatEngine.shared.connect()
        NotificationCenter.default.post(name: Self.didRefreshNotification, object: nil)
      }
    } catch {
      // Could be transient (network drop, a 5xx on /login) or a genuinely dead
      // secret. We can't tell the two apart safely, and signing the user out over a
      // transient failure risks account loss — so never do that here. Just log and
      // let the next 401 retry; if the secret really is dead the user still has
      // cached content and can sign out/in manually.
      NSLog(
        "[AppSessionGuard] recover(%@): refresh failed (%@), will retry later",
        reason, error.localizedDescription)
    }
  }
}
