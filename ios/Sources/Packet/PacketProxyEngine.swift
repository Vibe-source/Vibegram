import Foundation

/// Thin Swift layer over the packet client FFI. Starts the engine as a loopback SOCKS5
/// proxy for this app only — no VPN, no tunnel provider — and returns the port it bound.
enum PacketProxyEngine {
  private static var installedLogCallback = false
  private static let logLock = NSLock()

  static func installLogCallback() {
    logLock.lock()
    defer { logLock.unlock() }
    guard !installedLogCallback else { return }
    installedLogCallback = true
    phantom_set_log_callback(packetEngineLogCallback)
  }

  /// Returns the bound SOCKS5 port, or a negative packet error code.
  static func start(profile: PacketProxyProfile) -> Int32 {
    installLogCallback()

    switch profile.stack {
    case .directSock:
      return startCarrier(profile)
    case .packetChain:
      let carrierPort = startCarrier(profile)
      guard carrierPort > 0 else { return carrierPort }
      return startNative(profile, upstreamProxyOverride: "http://127.0.0.1:\(carrierPort)")
    case .packetNative:
      return startNative(profile, upstreamProxyOverride: nil)
    }
  }

  static func stop() {
    installLogCallback()
    phantom_stop_client()
    phantom_stop_layered_carrier()
  }

  static func stats() -> PacketProxyRuntimeStats? {
    guard let raw = phantom_copy_stats_json() else { return nil }
    defer { phantom_free_string(raw) }
    guard let data = String(cString: raw).data(using: .utf8) else { return nil }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try? decoder.decode(PacketProxyRuntimeStats.self, from: data)
  }

  // MARK: - Start paths

  private static func startCarrier(_ profile: PacketProxyProfile) -> Int32 {
    profile.normalizedCarrierURI.withCString { uri in
      phantom_start_layered_carrier_full(
        uri,
        profile.effectiveCarrierProxyPort,
        profile.fragmentEnabled ? 1 : 0,
        profile.fragmentSizeValue
      )
    }
  }

  private static func startNative(
    _ profile: PacketProxyProfile,
    upstreamProxyOverride: String?
  ) -> Int32 {
    let transport = profile.effectiveTransport
    let upstreamProxy = upstreamProxyOverride ?? profile.normalizedUpstreamProxy
    // REALITY must keep its uTLS ClientHello intact, so fragmentation is forced off.
    let fragmentEnabled = profile.usesReality ? false : profile.fragmentEnabled
    let chromeTLSProfile: Int32 =
      (transport == .stealth || transport == .webSocket || transport == .reality) ? 1 : 0

    return profile.normalizedServerURL.withCString { serverURL in
      profile.effectiveStartSecret.withCString { secret in
        guard profile.usesAdvancedStart else {
          return phantom_start(serverURL, secret, profile.listenPortValue)
        }
        return withOptionalCString(profile.effectiveCDNEdge) { cdnEdge in
          withOptionalCString(profile.normalizedHostOverride) { hostOverride in
            withOptionalCString(profile.effectiveSNIOverride) { sniOverride in
              withOptionalCString(profile.normalizedObfsKey) { obfsKey in
                withOptionalCString(upstreamProxy) { upstream in
                  phantom_start_full(
                    serverURL,
                    secret,
                    profile.listenPortValue,
                    cdnEdge,
                    hostOverride,
                    sniOverride,
                    transport.rawValue,
                    fragmentEnabled ? 1 : 0,
                    profile.fragmentSizeValue,
                    chromeTLSProfile,
                    obfsKey,
                    upstream
                  )
                }
              }
            }
          }
        }
      }
    }
  }

  private static func withOptionalCString<T>(
    _ value: String,
    _ body: (UnsafePointer<CChar>?) -> T
  ) -> T {
    value.isEmpty ? body(nil) : value.withCString(body)
  }
}

/// `phantom_copy_stats_json()` decoded — what the proxy row shows while connected.
struct PacketProxyRuntimeStats: Decodable, Equatable {
  var state = "idle"
  var transport = "Auto"
  var serverHost = ""
  var cdnEdge: String?
  var listenPort: UInt16?
  var bytesUp: UInt64 = 0
  var bytesDown: UInt64 = 0
  var activeStreams: UInt32 = 0
  var totalStreams: UInt64 = 0
  var connectedSince: UInt64?
  var lastPingMs: UInt32?
  var lastError: String?

  var isConnected: Bool { state.lowercased() == "connected" }
}

private func packetEngineLogCallback(_ message: UnsafePointer<CChar>?) {
  guard let message else { return }
  ChatEngineStore.shared.appendJournal([
    "at": Int(Date().timeIntervalSince1970 * 1000),
    "source": "packet",
    "message": String(cString: message),
  ])
}
