import Foundation

struct AppSessionConfig {
  let apiBaseURL: URL
  let apiBaseURLString: String
  let socketURLString: String
  let userID: String
  let authToken: String
  let transportMode: PacketTransportMode
  let username: String?
  let name: String?
  let secureID: String?
  let publicKeyPem: String?
  let privateKeyPem: String?
  let encryptedPrivateKey: String?
  let tokenExpiresAt: String?
  let identityKey: String?
  let phoneNumber: String?
  let bio: String?
  let profileImage: String?
  let dateOfBirth: String?
  let showLastSeen: Bool?
  let showOnlineStatus: Bool?
  let autoDeleteTimer: Int?
  let privacyLastSeen: String?
  let privacyForward: String?
  let privacyCalls: String?
  let privacyPhoneNumber: String?
  let privacyProfilePhotos: String?
  let privacyBio: String?
  let privacyGifts: String?
  let privacyBirthday: String?
  let privacySavedMusic: String?

  static var defaultAPIBaseURLString: String {
    ChatAvatarURLResolver.resolvedAPIBaseURL()?.absoluteString ?? "https://api.vibegram.io"
  }

  static var current: AppSessionConfig? {
    AppSessionConfig(payload: ChatEngineStore.shared.getConfig())
  }

  init?(payload: [String: Any]) {
    // Prefer stored apiBaseUrl/baseUrl; only fall back to the resolver default
    // (which itself prefers live engine config, then a compile-time host). Never
    // invent a production domain when a non-empty config value is already present.
    let apiBaseURLString =
      Self.normalizedString(payload["apiBaseUrl"] ?? payload["baseUrl"])
      ?? Self.defaultAPIBaseURLString
    guard let apiBaseURL = URL(string: apiBaseURLString),
      let userID = Self.normalizedString(payload["userId"]),
      let authToken = Self.normalizedString(
        payload["authToken"] ?? payload["token"] ?? payload["loginToken"])
    else {
      // Empty/cold-start config is normal; only log partial/broken sessions.
      let hasPartial =
        Self.normalizedString(payload["userId"]) != nil
        || Self.normalizedString(
          payload["authToken"] ?? payload["token"] ?? payload["loginToken"]) != nil
      if hasPartial {
        VibeLog.warning(
          "session config parse failed",
          category: "session",
          metadata: [
            "hasApiBase": Self.normalizedString(payload["apiBaseUrl"] ?? payload["baseUrl"]) == nil
              ? "false" : "true",
            "hasUserId": Self.normalizedString(payload["userId"]) == nil ? "false" : "true",
            "hasToken": Self.normalizedString(
              payload["authToken"] ?? payload["token"] ?? payload["loginToken"]) == nil
              ? "false" : "true",
          ]
        )
      }
      return nil
    }

    self.apiBaseURL = apiBaseURL
    self.apiBaseURLString = apiBaseURLString
    self.socketURLString =
      Self.normalizedString(payload["socketUrl"] ?? payload["url"])
      ?? Self.derivedSocketURL(from: apiBaseURLString)
    self.userID = userID
    self.authToken = authToken
    self.transportMode = PacketTransportMode(payload["transportMode"])
    self.username = Self.normalizedString(payload["username"])
    self.name = Self.normalizedString(payload["name"])
    self.secureID = Self.normalizedString(payload["secureId"])
    self.publicKeyPem =
      Self.normalizedString(payload["publicKeyPem"] ?? payload["publicKey"])
    self.privateKeyPem =
      Self.normalizedString(payload["privateKeyPem"] ?? payload["privateKey"])
    self.encryptedPrivateKey = Self.normalizedString(payload["encryptedPrivateKey"])
    self.tokenExpiresAt = Self.normalizedString(payload["tokenExpiresAt"])
    self.identityKey = Self.normalizedString(payload["identityKey"])
    self.phoneNumber = Self.normalizedString(payload["phoneNumber"])
    self.bio = Self.normalizedString(payload["bio"])
    self.profileImage = Self.normalizedString(payload["profileImage"] ?? payload["profile_image"])
    self.dateOfBirth = Self.normalizedString(payload["dateOfBirth"])
    self.showLastSeen = Self.normalizedBool(payload["showLastSeen"])
    self.showOnlineStatus = Self.normalizedBool(payload["showOnlineStatus"])
    self.autoDeleteTimer = Self.normalizedInt(payload["autoDeleteTimer"])
    self.privacyLastSeen = Self.normalizedString(payload["privacyLastSeen"])
    self.privacyForward = Self.normalizedString(payload["privacyForward"])
    self.privacyCalls = Self.normalizedString(payload["privacyCalls"])
    self.privacyPhoneNumber = Self.normalizedString(payload["privacyPhoneNumber"])
    self.privacyProfilePhotos = Self.normalizedString(payload["privacyProfilePhotos"])
    self.privacyBio = Self.normalizedString(payload["privacyBio"])
    self.privacyGifts = Self.normalizedString(payload["privacyGifts"])
    self.privacyBirthday = Self.normalizedString(payload["privacyBirthday"])
    self.privacySavedMusic = Self.normalizedString(payload["privacySavedMusic"])
  }

  init(
    apiBaseURLString: String,
    socketURLString: String?,
    userID: String,
    authToken: String,
    transportMode: PacketTransportMode = .direct,
    username: String? = nil,
    name: String? = nil,
    secureID: String? = nil,
    publicKeyPem: String? = nil,
    privateKeyPem: String? = nil,
    encryptedPrivateKey: String? = nil,
    tokenExpiresAt: String? = nil,
    identityKey: String? = nil,
    phoneNumber: String? = nil,
    bio: String? = nil,
    profileImage: String? = nil,
    dateOfBirth: String? = nil,
    showLastSeen: Bool? = nil,
    showOnlineStatus: Bool? = nil,
    autoDeleteTimer: Int? = nil,
    privacyLastSeen: String? = nil,
    privacyForward: String? = nil,
    privacyCalls: String? = nil,
    privacyPhoneNumber: String? = nil,
    privacyProfilePhotos: String? = nil,
    privacyBio: String? = nil,
    privacyGifts: String? = nil,
    privacyBirthday: String? = nil,
    privacySavedMusic: String? = nil
  ) {
    let normalizedAPI =
      apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    self.apiBaseURLString = normalizedAPI
    self.apiBaseURL = URL(string: normalizedAPI) ?? URL(string: Self.defaultAPIBaseURLString)!
    self.socketURLString =
      socketURLString?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      ? socketURLString!.trimmingCharacters(in: .whitespacesAndNewlines)
      : Self.derivedSocketURL(from: normalizedAPI)
    self.userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
    self.authToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
    self.transportMode = transportMode
    self.username = Self.normalizedString(username)
    self.name = Self.normalizedString(name)
    self.secureID = Self.normalizedString(secureID)
    self.publicKeyPem = Self.normalizedString(publicKeyPem)
    self.privateKeyPem = Self.normalizedString(privateKeyPem)
    self.encryptedPrivateKey = Self.normalizedString(encryptedPrivateKey)
    self.tokenExpiresAt = Self.normalizedString(tokenExpiresAt)
    self.identityKey = Self.normalizedString(identityKey)
    self.phoneNumber = Self.normalizedString(phoneNumber)
    self.bio = Self.normalizedString(bio)
    self.profileImage = Self.normalizedString(profileImage)
    self.dateOfBirth = Self.normalizedString(dateOfBirth)
    self.showLastSeen = showLastSeen
    self.showOnlineStatus = showOnlineStatus
    self.autoDeleteTimer = autoDeleteTimer
    self.privacyLastSeen = Self.normalizedString(privacyLastSeen)
    self.privacyForward = Self.normalizedString(privacyForward)
    self.privacyCalls = Self.normalizedString(privacyCalls)
    self.privacyPhoneNumber = Self.normalizedString(privacyPhoneNumber)
    self.privacyProfilePhotos = Self.normalizedString(privacyProfilePhotos)
    self.privacyBio = Self.normalizedString(privacyBio)
    self.privacyGifts = Self.normalizedString(privacyGifts)
    self.privacyBirthday = Self.normalizedString(privacyBirthday)
    self.privacySavedMusic = Self.normalizedString(privacySavedMusic)
  }

  var payload: [String: Any] {
    var value: [String: Any] = [
      "apiBaseUrl": apiBaseURLString,
      "baseUrl": apiBaseURLString,
      "socketUrl": socketURLString,
      "url": socketURLString,
      "userId": userID,
      "authToken": authToken,
      "token": authToken,
      "loginToken": authToken,
      "userChannelTopic": "user:\(userID)",
      "transportMode": transportMode.rawValue,
      "identityKey": identityKey ?? "v2",
    ]
    if let username { value["username"] = username }
    if let name { value["name"] = name }
    if let secureID { value["secureId"] = secureID }
    if let publicKeyPem {
      value["publicKeyPem"] = publicKeyPem
      value["publicKey"] = publicKeyPem
    }
    if let privateKeyPem {
      value["privateKeyPem"] = privateKeyPem
      value["privateKey"] = privateKeyPem
    }
    if let encryptedPrivateKey { value["encryptedPrivateKey"] = encryptedPrivateKey }
    if let tokenExpiresAt { value["tokenExpiresAt"] = tokenExpiresAt }
    if let phoneNumber { value["phoneNumber"] = phoneNumber }
    if let bio { value["bio"] = bio }
    if let profileImage { value["profileImage"] = profileImage }
    if let dateOfBirth { value["dateOfBirth"] = dateOfBirth }
    if let showLastSeen { value["showLastSeen"] = showLastSeen }
    if let showOnlineStatus { value["showOnlineStatus"] = showOnlineStatus }
    if let autoDeleteTimer { value["autoDeleteTimer"] = autoDeleteTimer }
    if let privacyLastSeen { value["privacyLastSeen"] = privacyLastSeen }
    if let privacyForward { value["privacyForward"] = privacyForward }
    if let privacyCalls { value["privacyCalls"] = privacyCalls }
    if let privacyPhoneNumber { value["privacyPhoneNumber"] = privacyPhoneNumber }
    if let privacyProfilePhotos { value["privacyProfilePhotos"] = privacyProfilePhotos }
    if let privacyBio { value["privacyBio"] = privacyBio }
    if let privacyGifts { value["privacyGifts"] = privacyGifts }
    if let privacyBirthday { value["privacyBirthday"] = privacyBirthday }
    if let privacySavedMusic { value["privacySavedMusic"] = privacySavedMusic }
    return value
  }

  var bootstrapURL: URL? {
    var base = apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }
    return URL(string: "\(base)/packet/bootstrap")
  }

  static func store(_ config: AppSessionConfig) {
    ChatEngineStore.shared.clearConfig()
    ChatEngineStore.shared.setConfig(config.payload)
    VibeNativeCallManager.shared.syncStoredPushTokens(reason: "app-session-store", force: true)
    // Durable breadcrumb only — never log tokens, keys, phone, or email.
    VibeLog.notice(
      "session config stored",
      category: "session",
      metadata: [
        "apiHost": config.apiBaseURL.host ?? "?",
        "socketHost": URL(string: config.socketURLString)?.host ?? "?",
        "transport": config.transportMode.rawValue,
        "hasToken": config.authToken.isEmpty ? "false" : "true",
      ]
    )
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

  private static func derivedSocketURL(from apiBaseURLString: String) -> String {
    guard var components = URLComponents(string: apiBaseURLString) else {
      return "wss://api.vibegram.io/socket"
    }
    if components.scheme == "https" {
      components.scheme = "wss"
    } else if components.scheme == "http" {
      components.scheme = "ws"
    }
    var path =
      components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if path.lowercased().hasSuffix("api") {
      path =
        String(path.dropLast(3))
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    components.path = "/" + path
    if !components.path.hasSuffix("/socket") {
      components.path =
        components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      components.path =
        components.path.isEmpty ? "/socket" : "/\(components.path)/socket"
    }
    return components.string ?? "wss://api.vibegram.io/socket"
  }
}
