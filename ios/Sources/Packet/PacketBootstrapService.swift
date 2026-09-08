import Foundation

/// Pulls the proxy entries the server offers into Settings → Proxy. Runs direct: it is a
/// list of hops to try, so fetching it through a hop that may be down would be circular.
enum PacketBootstrapService {
  static func prefetchIfNeeded(config: AppSessionConfig) async {
    guard config.transportMode == .direct else { return }
    _ = try? await refresh(config: config)
  }

  @discardableResult
  static func refresh(config: AppSessionConfig) async throws -> PacketBootstrapPayload {
    guard let url = config.bootstrapURL else {
      throw PacketRuntimeError.invalidBootstrap("packet bootstrap url invalid")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw PacketRuntimeError.invalidBootstrap("packet bootstrap response invalid")
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw PacketRuntimeError.invalidBootstrap(
        "packet bootstrap request failed with status \(httpResponse.statusCode)\(body.isEmpty ? "" : ": \(body)")"
      )
    }

    let payload = try JSONDecoder().decode(PacketBootstrapPayload.self, from: data)
    if let serverProfiles = payload.packetProxyProfiles {
      PacketProxyStore.shared.mergeServerProfiles(serverProfiles)
    }
    return payload
  }
}
