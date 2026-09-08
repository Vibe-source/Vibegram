import Foundation

/// The proxy list behind Settings → Proxy: the switch, the active entry, the entries.
/// Profiles carry tunnel credentials, so they live in the Keychain, not UserDefaults.
final class PacketProxyStore {
  static let shared = PacketProxyStore()

  static let didChangeNotification = Notification.Name("VibePacketProxyStoreDidChange")

  private let keychainKey = "packetProxyProfiles"
  private let useProxyKey = "vibe.proxy.useProxy"
  private let activeIDKey = "vibe.proxy.activeProfileId"
  private let automaticKey = "vibe.proxy.automatic"
  private let dismissedKey = "vibe.proxy.dismissedServerEntries"

  private let lock = NSLock()
  private var cachedProfiles: [PacketProxyProfile]?

  private init() {}

  // MARK: - Toggle

  var useProxy: Bool {
    get { UserDefaults.standard.bool(forKey: useProxyKey) }
    set {
      UserDefaults.standard.set(newValue, forKey: useProxyKey)
      applyProxyState()
      notifyChanged()
    }
  }

  /// Turns the proxy on/off and re-establishes the chat transport on the new path.
  func setUseProxy(_ on: Bool) {
    UserDefaults.standard.set(on, forKey: useProxyKey)
    applyProxyState()
    notifyChanged()
  }

  /// Picks the entry the engine starts, restarting the transport if the proxy is on.
  func activate(id: UUID) {
    _ = profiles
    UserDefaults.standard.set(id.uuidString, forKey: activeIDKey)
    if useProxy {
      applyProxyState()
    }
    notifyChanged()
  }

  // MARK: - Profiles

  /// Entries are the user's own — Vibe ships none and never rewrites what is stored.
  /// An unreadable Keychain returns empty without caching, so a later save cannot wipe it.
  var profiles: [PacketProxyProfile] {
    lock.lock()
    defer { lock.unlock() }
    if let cached = cachedProfiles { return cached }
    guard var loaded = loadLocked() else { return [] }

    if let legacyAutomatic = loaded.first(where: { $0.usesServerBootstrap }) {
      if activeProfileID == legacyAutomatic.id {
        UserDefaults.standard.removeObject(forKey: activeIDKey)
      }
      loaded.removeAll { $0.usesServerBootstrap }
      saveLocked(loaded)
    }
    UserDefaults.standard.set(false, forKey: automaticKey)
    cachedProfiles = loaded
    return loaded
  }

  var activeProfileID: UUID? {
    get {
      guard let raw = UserDefaults.standard.string(forKey: activeIDKey) else { return nil }
      return UUID(uuidString: raw)
    }
    set {
      UserDefaults.standard.set(newValue?.uuidString, forKey: activeIDKey)
      notifyChanged()
    }
  }

  /// The entry the engine should start. Falls back to the first usable profile so a
  /// deleted or never-picked active entry still leaves the proxy working.
  var activeProfile: PacketProxyProfile? {
    let all = profiles
    if let id = activeProfileID, let match = all.first(where: { $0.id == id }) { return match }
    return all.first { $0.validationError == nil }
  }

  func upsert(_ profile: PacketProxyProfile) {
    guard !profile.usesServerBootstrap else { return }
    mutate { profiles in
      if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
        profiles[index] = profile
      } else {
        profiles.append(profile)
      }
    }
    // Editing the entry that is currently carrying traffic has to restart the engine.
    if useProxy, activeProfile?.id == profile.id {
      applyProxyState()
    }
  }

  func delete(id: UUID) {
    let wasActive = activeProfile?.id == id
    if let doomed = profiles.first(where: { $0.id == id }) {
      rememberDismissed(doomed)
    }
    mutate { profiles in
      profiles.removeAll { $0.id == id }
    }
    if activeProfileID == id {
      UserDefaults.standard.set(activeProfile?.id.uuidString, forKey: activeIDKey)
    }
    if useProxy, wasActive {
      applyProxyState()
    }
  }

  /// List order is the stored order, so a reorder is just a save.
  func move(fromOffsets: IndexSet, toOffset: Int) {
    mutate { profiles in
      profiles.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }
  }

  /// Adds server entries we do not have, matched on endpoint. Purely additive: an existing
  /// entry is never rewritten and one the user deleted is never brought back.
  func mergeServerProfiles(_ incoming: [PacketProxyProfile]) {
    guard !incoming.isEmpty else { return }
    let dismissed = dismissedFingerprints
    mutate { profiles in
      for candidate in incoming where !candidate.usesServerBootstrap {
        guard !dismissed.contains(Self.fingerprint(candidate)) else { continue }
        let exists = profiles.contains {
          Self.fingerprint($0) == Self.fingerprint(candidate)
        }
        if !exists { profiles.append(candidate) }
      }
    }
  }

  private static func fingerprint(_ profile: PacketProxyProfile) -> String {
    "\(profile.normalizedServerURL)|\(profile.normalizedCarrierURI)"
  }

  private var dismissedFingerprints: Set<String> {
    Set(UserDefaults.standard.stringArray(forKey: dismissedKey) ?? [])
  }

  private func rememberDismissed(_ profile: PacketProxyProfile) {
    var all = dismissedFingerprints
    all.insert(Self.fingerprint(profile))
    UserDefaults.standard.set(Array(all), forKey: dismissedKey)
  }

  // MARK: - Engine wiring

  /// Launch-time reconcile: publishes the switch so the first request picks the right
  /// route, and clears any port left over from the previous run.
  func reassertProxyStateOnLaunch() {
    var changes: [String: Any?] = [
      "packetProxyEnabled": useProxy,
      "packetProxyPort": nil,
      "packetStatus": useProxy ? "idle" : PacketTransportMode.direct.rawValue,
    ]
    let stored = (ChatEngineStore.shared.getConfig()["transportMode"] as? String) ?? ""
    if stored.lowercased() == "packet_mesh" {
      changes["transportMode"] = PacketTransportMode.direct.rawValue
    }
    ChatEngineStore.shared.updateConfig(changes)

    // Start eagerly so the first request already has a hop to take.
    guard useProxy else { return }
    DispatchQueue.global(qos: .utility).async {
      try? PacketRuntime.shared.ensureStarted()
    }
  }

  /// Publishes the switch, drops the running engine, then starts the selected entry and
  /// reconnects onto the new route. Clears the port first — the stop is async.
  func applyProxyState() {
    let on = useProxy
    ChatEngineStore.shared.updateConfig([
      "packetProxyEnabled": on,
      "packetProxyPort": nil,
      "packetStatus": on ? "idle" : PacketTransportMode.direct.rawValue,
      "packetLastError": nil,
    ])
    PacketRuntime.shared.stop(resetToDirect: !on)
    VibeHTTP.reset()

    DispatchQueue.global(qos: .utility).async {
      if on {
        try? PacketRuntime.shared.ensureStarted()
      }
      _ = ChatEngine.shared.disconnect()
      _ = ChatEngine.shared.connect()
    }
  }

  // MARK: - Persistence

  /// Writes only on top of state we actually read. A failed load aborts the edit rather
  /// than saving over entries the user still has on the device.
  private func mutate(_ body: (inout [PacketProxyProfile]) -> Void) {
    lock.lock()
    guard var working = cachedProfiles ?? loadLocked() else {
      lock.unlock()
      NSLog("[PacketProxyStore] skipped a write — stored profiles are unreadable")
      return
    }
    body(&working)
    saveLocked(working)
    cachedProfiles = working
    lock.unlock()
    notifyChanged()
  }

  /// nil means the Keychain could not be read or decoded; `[]` means there are none.
  private func loadLocked() -> [PacketProxyProfile]? {
    guard let json = SecureKeyStore.shared.retrieveSecret(key: keychainKey) else {
      return SecureKeyStore.shared.hasSecret(key: keychainKey) ? nil : []
    }
    guard let data = json.data(using: .utf8),
          let decoded = try? JSONDecoder().decode([PacketProxyProfile].self, from: data)
    else { return nil }
    return decoded
  }

  private func saveLocked(_ profiles: [PacketProxyProfile]) {
    guard let data = try? JSONEncoder().encode(profiles),
          let json = String(data: data, encoding: .utf8)
    else { return }
    _ = SecureKeyStore.shared.storeSecret(key: keychainKey, value: json)
  }

  private func notifyChanged() {
    NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
  }
}
