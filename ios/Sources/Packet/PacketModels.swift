import Foundation

enum PacketTransportMode: String {
  case direct = "direct"
  case bridgeText = "bridge_text"
  case offline = "offline"

  init(_ rawValue: Any?) {
    let normalized = (rawValue as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    // Legacy "packet_mesh" resolves to direct: the proxy is a SOCKS hop now, not a mode.
    self = PacketTransportMode(rawValue: normalized ?? "") ?? .direct
  }
}

/// What `/packet/bootstrap` still carries for us: the proxy entries the server offers.
struct PacketBootstrapPayload: Codable {
  let packetProxyProfiles: [PacketProxyProfile]?

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    packetProxyProfiles =
      try container.decodeIfPresent([PacketProxyProfile].self, forKey: .packetProxyProfiles)
  }
}

/// What the running engine reports back: where it listens and whether it came up.
struct PacketTransportSnapshot {
  let status: String
  let proxyHost: String
  let proxyPort: Int
  let activeBridgeID: String?
  let lastError: String?
}

func packetDecode<T: Decodable>(_ type: T.Type, from object: Any) -> T? {
  guard JSONSerialization.isValidJSONObject(object),
        let data = try? JSONSerialization.data(withJSONObject: object)
  else { return nil }
  return try? JSONDecoder().decode(type, from: data)
}

func packetJSONObject<T: Encodable>(_ value: T) -> [String: Any]? {
  guard let data = try? JSONEncoder().encode(value),
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else { return nil }
  return object
}
