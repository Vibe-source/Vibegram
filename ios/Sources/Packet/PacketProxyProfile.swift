import Foundation

/// One proxy entry, in the field set the packet client's FFI takes — no VPN pieces: the
/// engine runs as a loopback SOCKS5 proxy. See docs/packet-proxy-engine.md.

enum PacketProxyStack: Int32, Codable, CaseIterable, Identifiable {
  /// Packet's own protocol over WS/HTTP/QUIC/stealth/obfs/meek/REALITY.
  case packetNative = 0
  /// A trojan:// or vless:// carrier, spoken directly.
  case directSock = 1
  /// Carrier as first hop, packet native on top of it.
  case packetChain = 2

  var id: Int32 { rawValue }

  var title: String {
    switch self {
    case .packetNative: return "Packet Native"
    case .directSock: return "DirectSock"
    case .packetChain: return "Packet Chain"
    }
  }
}

enum PacketProxyTransport: Int32, Codable, CaseIterable, Identifiable {
  case auto = 0
  case webSocket = 1
  case http = 2
  case stealth = 3
  case obfs = 4
  case meek = 5
  case quic = 6
  /// REALITY outer with uTLS + Vision flow. Raw value must stay 7 — the Rust FFI reads it.
  case reality = 7

  var id: Int32 { rawValue }

  var title: String {
    switch self {
    case .auto: return "Auto"
    case .webSocket: return "WebSocket"
    case .http: return "HTTP"
    case .stealth: return "Stealth"
    case .obfs: return "Obfs"
    case .meek: return "Meek"
    case .quic: return "QUIC"
    case .reality: return "Reality"
    }
  }
}

struct PacketProxyProfile: Codable, Identifiable, Hashable {
  var id: UUID = UUID()
  var name: String = ""
  /// Server-issued mesh bootstrap instead of a hand-configured endpoint.
  var usesServerBootstrap: Bool = false
  var stack: PacketProxyStack = .packetNative
  var transport: PacketProxyTransport = .auto
  var serverURL: String = ""
  var secret: String = ""
  var listenPort: String = ""
  var cdnEdge: String = ""
  var hostOverride: String = ""
  var sniOverride: String = ""
  var obfsKey: String = ""
  var upstreamProxy: String = ""
  var fragmentEnabled: Bool = false
  var fragmentSize: String = "40"
  var carrierURI: String = ""
  var carrierProxyPort: String = "10808"

  init() {}

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    usesServerBootstrap = try c.decodeIfPresent(Bool.self, forKey: .usesServerBootstrap) ?? false
    stack = try c.decodeIfPresent(PacketProxyStack.self, forKey: .stack) ?? .packetNative
    transport = try c.decodeIfPresent(PacketProxyTransport.self, forKey: .transport) ?? .auto
    serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? ""
    secret = try c.decodeIfPresent(String.self, forKey: .secret) ?? ""
    listenPort = try c.decodeIfPresent(String.self, forKey: .listenPort) ?? ""
    cdnEdge = try c.decodeIfPresent(String.self, forKey: .cdnEdge) ?? ""
    hostOverride = try c.decodeIfPresent(String.self, forKey: .hostOverride) ?? ""
    sniOverride = try c.decodeIfPresent(String.self, forKey: .sniOverride) ?? ""
    obfsKey = try c.decodeIfPresent(String.self, forKey: .obfsKey) ?? ""
    upstreamProxy = try c.decodeIfPresent(String.self, forKey: .upstreamProxy) ?? ""
    fragmentEnabled = try c.decodeIfPresent(Bool.self, forKey: .fragmentEnabled) ?? false
    fragmentSize = try c.decodeIfPresent(String.self, forKey: .fragmentSize) ?? "40"
    carrierURI = try c.decodeIfPresent(String.self, forKey: .carrierURI) ?? ""
    carrierProxyPort = try c.decodeIfPresent(String.self, forKey: .carrierProxyPort) ?? "10808"
  }

  // MARK: - Normalized values

  private static func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var normalizedName: String { Self.trimmed(name) }
  var normalizedServerURL: String { Self.trimmed(serverURL) }
  var normalizedSecret: String { Self.trimmed(secret) }
  var normalizedCDNEdge: String { Self.trimmed(cdnEdge) }
  var normalizedHostOverride: String { Self.trimmed(hostOverride) }
  var normalizedSNIOverride: String { Self.trimmed(sniOverride) }
  var normalizedObfsKey: String { Self.trimmed(obfsKey) }
  var normalizedUpstreamProxy: String { Self.trimmed(upstreamProxy) }
  var normalizedCarrierURI: String { Self.trimmed(carrierURI) }

  var usesCarrier: Bool { stack == .directSock || stack == .packetChain }

  var usesReality: Bool {
    transport == .reality
      || normalizedServerURL.lowercased().contains("security=reality")
  }

  var usesCDN: Bool { !normalizedCDNEdge.isEmpty || !normalizedHostOverride.isEmpty }

  /// QUIC needs a :443 edge; port 80 edges are rewritten.
  var effectiveCDNEdge: String {
    let edge = normalizedCDNEdge
    guard transport == .quic else { return edge }
    let host = Self.edgeHost(edge).isEmpty ? serverHost : Self.edgeHost(edge)
    guard !host.isEmpty else { return edge }
    let port = Self.edgePort(edge)
    return port == nil || port == 80 ? "\(host):443" : edge
  }

  var effectiveTransport: PacketProxyTransport {
    if usesReality { return .reality }
    if usesCDN || transport == .webSocket { return .webSocket }
    return transport
  }

  /// REALITY carries its UUID in the link; read it there rather than asking for it twice.
  var effectiveStartSecret: String {
    if usesReality, normalizedSecret.isEmpty { return realityURIUser }
    return normalizedSecret
  }

  /// The link's own `sni=`, so the engine never dials a name the server does not serve.
  var effectiveSNIOverride: String {
    if !normalizedSNIOverride.isEmpty { return normalizedSNIOverride }
    return usesReality ? realityURIQuery("sni") : ""
  }

  private var realityURIUser: String {
    URLComponents(string: normalizedServerURL)?.user ?? ""
  }

  private func realityURIQuery(_ name: String) -> String {
    URLComponents(string: normalizedServerURL)?
      .queryItems?.first { $0.name == name }?.value ?? ""
  }

  var listenPortValue: UInt16 {
    let trimmed = Self.trimmed(listenPort)
    if trimmed.isEmpty || trimmed.lowercased() == "auto" { return 0 }
    return UInt16(trimmed) ?? 0
  }

  var carrierProxyPortValue: UInt16? {
    guard let port = UInt16(Self.trimmed(carrierProxyPort)), port >= 1024 else { return nil }
    return port
  }

  var effectiveCarrierProxyPort: UInt16 { carrierProxyPortValue ?? 10808 }

  var fragmentSizeValue: UInt32 {
    guard fragmentEnabled else { return 40 }
    return min(max(UInt32(Self.trimmed(fragmentSize)) ?? 40, 1), 1000)
  }

  /// Anything beyond plain server+secret has to go through `phantom_start_full`.
  var usesAdvancedStart: Bool {
    usesCarrier || usesReality || usesCDN
      || !normalizedSNIOverride.isEmpty
      || !normalizedObfsKey.isEmpty
      || !normalizedUpstreamProxy.isEmpty
      || transport != .auto
      || fragmentEnabled
  }

  // MARK: - Display

  var displayName: String {
    if !normalizedName.isEmpty { return Self.cleanDisplayName(normalizedName) }
    if usesServerBootstrap { return "Automatic" }
    if usesCarrier { return carrierHost }
    if !normalizedHostOverride.isEmpty { return normalizedHostOverride }
    if !normalizedServerURL.isEmpty { return endpointHost }
    return "New Proxy"
  }

  private static func cleanDisplayName(_ value: String) -> String {
    let regionalIndicatorRange: ClosedRange<UInt32> = 0x1F1E6...0x1F1FF
    let cleaned = String(value.unicodeScalars.filter {
      !regionalIndicatorRange.contains($0.value)
    })
    return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var subtitle: String {
    if usesServerBootstrap { return "Vibe server · mesh bootstrap" }
    if usesCarrier { return "\(carrierProtocolLabel) · \(carrierHost):\(carrierPort)" }
    let host = endpointHost
    return host.isEmpty
      ? "Not configured"
      : "\(effectiveTransport.title) · \(host)"
  }

  var carrierProtocolLabel: String {
    normalizedCarrierURI.lowercased().hasPrefix("vless://") ? "VLESS" : "Trojan"
  }

  var serverHost: String {
    if let host = URL(string: normalizedServerURL)?.host, !host.isEmpty { return host }
    return normalizedServerURL
      .replacingOccurrences(of: "http://", with: "")
      .replacingOccurrences(of: "https://", with: "")
      .split(separator: "/")
      .first
      .map(String.init) ?? ""
  }

  var endpointHost: String {
    if usesCarrier { return carrierHost }
    if usesReality { return serverHost }
    let edge = Self.edgeHost(normalizedCDNEdge)
    return edge.isEmpty ? serverHost : edge
  }

  var endpointPort: Int {
    if usesCarrier { return carrierPort }
    if let edgePort = Self.edgePort(normalizedCDNEdge) { return edgePort }
    if let port = URL(string: normalizedServerURL)?.port, port > 0 { return port }
    if usesReality { return 443 }
    return normalizedServerURL.lowercased().hasPrefix("https://") ? 443 : 80
  }

  var carrierHost: String {
    URL(string: normalizedCarrierURI)?.host ?? ""
  }

  var carrierPort: Int {
    if let port = URL(string: normalizedCarrierURI)?.port, port > 0 { return port }
    return 443
  }

  // MARK: - Validation

  var validationError: String? {
    if usesServerBootstrap { return nil }

    if usesCarrier {
      if normalizedCarrierURI.isEmpty { return "Carrier link is required." }
      let uri = normalizedCarrierURI.lowercased()
      guard uri.hasPrefix("trojan://") || uri.hasPrefix("vless://") else {
        return "Carrier link must start with trojan:// or vless://."
      }
      guard carrierProxyPortValue != nil else { return "Carrier port must be 1024-65535." }
      if stack == .directSock { return nil }
    }

    if usesReality {
      let lower = normalizedServerURL.lowercased()
      guard lower.hasPrefix("vless://"), lower.contains("reality") else {
        return "Reality needs a vless://…security=reality… link as the server URL."
      }
      if fragmentEnabled { return "Turn fragmentation off for REALITY." }
      return nil
    }

    if normalizedServerURL.isEmpty { return "Server URL is required." }
    if normalizedSecret.isEmpty { return "Shared secret is required." }

    if let edgeError = cdnEdgeValidationError { return edgeError }
    if transport == .stealth, !normalizedServerURL.lowercased().hasPrefix("https://") {
      return "Stealth needs an https:// server URL."
    }
    if transport == .obfs, normalizedCDNEdge.isEmpty {
      return "Obfs needs CDN edge set to the direct server IP:port."
    }
    if let proxyError = upstreamProxyValidationError { return proxyError }
    if fragmentEnabled, UInt32(Self.trimmed(fragmentSize)).map({ !(1...1000).contains($0) }) ?? true {
      return "Fragment size must be between 1 and 1000."
    }
    return nil
  }

  var cdnEdgeValidationError: String? {
    let edge = normalizedCDNEdge
    if edge.isEmpty { return nil }
    if edge.allSatisfy(\.isNumber) {
      return "CDN edge must be a host or IP, optionally with :port."
    }
    if edge.hasPrefix(":") || edge.hasSuffix(":") {
      return "CDN edge must look like 185.143.234.235:80 or edge.example.com."
    }
    let parts = edge.split(separator: ":", omittingEmptySubsequences: false)
    if parts.count == 2, let port = Int(parts[1]), !(1...65535).contains(port) {
      return "CDN edge port must be between 1 and 65535."
    }
    return nil
  }

  var upstreamProxyValidationError: String? {
    let proxy = normalizedUpstreamProxy
    if proxy.isEmpty { return nil }
    guard let url = URL(string: proxy),
          let scheme = url.scheme?.lowercased(),
          ["socks", "socks5", "http", "https"].contains(scheme)
    else { return "First hop must be socks5://host:port or http://host:port." }
    guard let host = url.host, !host.isEmpty else { return "First hop is missing a host." }
    guard let port = url.port, (1...65535).contains(port) else {
      return "First-hop port must be between 1 and 65535."
    }
    return nil
  }

  // MARK: - Helpers

  private static func edgeHost(_ edge: String) -> String {
    let value = trimmed(edge)
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    return parts.count == 2 ? trimmed(String(parts[0])) : value
  }

  private static func edgePort(_ edge: String) -> Int? {
    let parts = trimmed(edge).split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, let port = Int(trimmed(String(parts[1]))), (1...65535).contains(port)
    else { return nil }
    return port
  }
}
