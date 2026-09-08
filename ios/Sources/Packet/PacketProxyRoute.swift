import Foundation

/// The loopback SOCKS5 hop the packet engine binds while Settings → Proxy is on.
/// A hop, not a transport: the chat protocol, media types and sockets are unchanged.
enum PacketProxyRoute {
  static var isEnabled: Bool {
    (ChatEngineStore.shared.getConfig()["packetProxyEnabled"] as? Bool) ?? false
  }

  /// Where the engine listens, or nil when the proxy is off or has not bound a port yet.
  static func current(config: [String: Any]? = nil) -> ChatProxyConfiguration? {
    let resolved = config ?? ChatEngineStore.shared.getConfig()
    guard (resolved["packetProxyEnabled"] as? Bool) ?? false else { return nil }
    guard let port = port(from: resolved["packetProxyPort"]), port > 0 else { return nil }
    let raw = (resolved["packetProxyHost"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return ChatProxyConfiguration(host: (raw?.isEmpty == false) ? raw! : "127.0.0.1", port: port)
  }

  static func apply(_ route: ChatProxyConfiguration, to configuration: URLSessionConfiguration) {
    configuration.connectionProxyDictionary = [
      "SOCKSEnable": 1,
      "SOCKSProxy": route.host,
      "SOCKSPort": route.port,
    ]
  }

  private static func port(from value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return nil
  }
}

/// The session every app HTTP call uses. Identical to `URLSession.shared` with the proxy
/// off; routed through the engine's SOCKS port with it on, so call sites never branch.
enum VibeHTTP {
  private static let lock = NSLock()
  private static var cachedKey = ""
  private static var cachedSession: URLSession?

  static var shared: URLSession {
    guard let route = PacketProxyRoute.current() else { return .shared }
    let key = "\(route.host):\(route.port)"

    lock.lock()
    defer { lock.unlock() }
    if key == cachedKey, let session = cachedSession { return session }

    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 30
    PacketProxyRoute.apply(route, to: configuration)
    let session = URLSession(configuration: configuration)
    cachedSession?.finishTasksAndInvalidate()
    cachedKey = key
    cachedSession = session
    return session
  }

  /// Drops the pooled session so the next call rebuilds on the new route.
  static func reset() {
    lock.lock()
    cachedSession?.invalidateAndCancel()
    cachedSession = nil
    cachedKey = ""
    lock.unlock()
  }
}
