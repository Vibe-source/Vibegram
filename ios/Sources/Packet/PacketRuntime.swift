import Foundation

enum PacketRuntimeError: LocalizedError {
  case invalidBootstrap(String)
  case startFailed(String)

  var errorDescription: String? {
    switch self {
    case let .invalidBootstrap(message), let .startFailed(message):
      return message
    }
  }
}

/// Owns the packet engine process: starts the active proxy entry and publishes the
/// loopback port it bound. Nothing here knows about chat — it only opens the hop.
final class PacketRuntime {
  static let shared = PacketRuntime()

  private let queue = DispatchQueue(label: "vibe.packet.runtime")
  private var currentSnapshot: PacketTransportSnapshot?
  private var currentProfileID: UUID?

  private init() {
    PacketProxyEngine.installLogCallback()
  }

  /// Starts the engine for the active entry in Settings → Proxy, or returns the running one.
  @discardableResult
  func ensureStarted() throws -> PacketTransportSnapshot {
    let store = PacketProxyStore.shared
    guard store.useProxy else {
      throw PacketRuntimeError.startFailed("proxy is off")
    }
    guard let profile = store.activeProfile else {
      throw PacketRuntimeError.invalidBootstrap("no proxy selected")
    }
    if let error = profile.validationError {
      throw PacketRuntimeError.invalidBootstrap(error)
    }
    return try queue.sync { try startLocked(profile: profile) }
  }

  /// The HTTP session for the current route. Starts the engine on demand, so call it off
  /// the main thread; on main it kicks the start and hands back what is ready now.
  func session() -> URLSession {
    guard PacketProxyStore.shared.useProxy else { return .shared }
    guard PacketProxyRoute.current() == nil else { return VibeHTTP.shared }

    if Thread.isMainThread {
      Task.detached(priority: .utility) { try? PacketRuntime.shared.ensureStarted() }
      return VibeHTTP.shared
    }
    do {
      try ensureStarted()
    } catch {
      NSLog("[PacketRuntime] proxy start failed: %@", error.localizedDescription)
    }
    return VibeHTTP.shared
  }

  func stop(resetToDirect: Bool = false) {
    // Async on purpose: the stop FFI can hang on a wedged engine and this is called from
    // the main thread. The serial queue still preserves stop→start ordering.
    queue.async { [self] in
      stopLocked(resetToDirect: resetToDirect)
    }
  }

  private func startLocked(profile: PacketProxyProfile) throws -> PacketTransportSnapshot {
    if let snapshot = currentSnapshot, currentProfileID == profile.id, snapshot.proxyPort > 0 {
      return snapshot
    }

    stopLocked(resetToDirect: false)

    let port = Int(PacketProxyEngine.start(profile: profile))
    guard port > 0 else {
      let message = "packet engine start failed (code \(port))"
      ChatEngineStore.shared.updateConfig([
        "packetStatus": "failed",
        "packetLastError": message,
        "packetProxyPort": nil,
      ])
      VibeHTTP.reset()
      throw PacketRuntimeError.startFailed(message)
    }

    let stats = PacketProxyEngine.stats()
    let snapshot = PacketTransportSnapshot(
      status: stats?.state ?? "running",
      proxyHost: "127.0.0.1",
      proxyPort: Int(stats?.listenPort ?? UInt16(port)),
      activeBridgeID: profile.id.uuidString,
      lastError: stats?.lastError
    )

    currentSnapshot = snapshot
    currentProfileID = profile.id
    ChatEngineStore.shared.updateConfig([
      "packetStatus": snapshot.status,
      "packetProxyHost": snapshot.proxyHost,
      "packetProxyPort": snapshot.proxyPort,
      "activePacketBridgeId": snapshot.activeBridgeID,
      "packetLastError": snapshot.lastError,
    ])
    VibeHTTP.reset()
    return snapshot
  }

  private func stopLocked(resetToDirect: Bool) {
    PacketProxyEngine.stop()
    currentSnapshot = nil
    currentProfileID = nil
    ChatEngineStore.shared.updateConfig([
      "packetStatus": resetToDirect ? PacketTransportMode.direct.rawValue : "idle",
      "packetProxyPort": nil,
      "packetLastError": nil,
    ])
    VibeHTTP.reset()
  }
}
