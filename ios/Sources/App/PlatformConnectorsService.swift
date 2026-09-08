import AuthenticationServices
import Foundation
import UIKit

// MARK: - Models

struct PlatformCatalogItem: Identifiable, Equatable {
  let id: String
  let name: String
  let description: String
  let icon: String
  let category: String
  let status: String
  let capabilities: [PlatformCapability]

  var isReady: Bool { status == "ready" || status == "needs_config" }
  var isComingSoon: Bool { status == "coming_soon" }
}

struct PlatformCapability: Identifiable, Equatable {
  let id: String
  let name: String
  let description: String
}

struct PlatformConnection: Identifiable, Equatable {
  let id: String
  let provider: String
  let externalAccountLogin: String?
  let displayName: String?
  let status: String
  let scopes: [String]
  let capabilities: [String]
  let grants: [PlatformGrant]
  let avatarURL: String?

  var title: String {
    displayName?.nilIfBlank
      ?? externalAccountLogin?.nilIfBlank
      ?? provider.capitalized
  }
}

struct PlatformGrant: Identifiable, Equatable {
  let id: String
  let granteeType: String
  let granteeId: String
  let capabilities: [String]
  let enabled: Bool
}

enum PlatformConnectorsError: LocalizedError {
  case invalidConfiguration
  case invalidResponse
  case oauthCancelled
  case oauthFailed(String)
  case http(Int, String)

  var errorDescription: String? {
    switch self {
    case .invalidConfiguration:
      return "The current account session is unavailable."
    case .invalidResponse:
      return "The connectors service returned an invalid response."
    case .oauthCancelled:
      return "Sign-in was cancelled."
    case .oauthFailed(let detail):
      return detail.isEmpty ? "Connection failed." : detail
    case let .http(code, body):
      let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
      if detail.contains("oauth_not_configured") {
        return "GitHub OAuth is not configured on the server yet (needs GITHUB_CLIENT_ID / SECRET)."
      }
      return detail.isEmpty ? "Request failed (\(code))." : "Request failed (\(code)): \(detail)"
    }
  }
}

// MARK: - Service

enum PlatformConnectorsService {
  static func fetchCatalog(config: AppSessionConfig) async throws -> [PlatformCatalogItem] {
    let object = try await request(config: config, method: "GET", path: "/platforms/catalog")
    let items = object["items"] as? [[String: Any]] ?? []
    return items.compactMap(decodeCatalogItem)
  }

  static func fetchConnections(config: AppSessionConfig) async throws -> [PlatformConnection] {
    let object = try await request(config: config, method: "GET", path: "/platforms/connections")
    let items = object["items"] as? [[String: Any]] ?? []
    return items.compactMap(decodeConnection)
  }

  static func revoke(connectionId: String, config: AppSessionConfig) async throws {
    _ = try await request(
      config: config,
      method: "DELETE",
      path: "/platforms/connections/\(pathEscape(connectionId))"
    )
  }

  static func upsertGrant(
    connectionId: String,
    granteeType: String,
    granteeId: String,
    capabilities: [String] = [],
    enabled: Bool = true,
    config: AppSessionConfig
  ) async throws -> PlatformGrant {
    let object = try await request(
      config: config,
      method: "POST",
      path: "/platforms/connections/\(pathEscape(connectionId))/grants",
      body: [
        "granteeType": granteeType,
        "granteeId": granteeId,
        "capabilities": capabilities,
        "enabled": enabled,
      ]
    )
    guard let raw = object["grant"] as? [String: Any], let grant = decodeGrant(raw) else {
      throw PlatformConnectorsError.invalidResponse
    }
    return grant
  }

  /// Starts OAuth and presents ASWebAuthenticationSession. Completes when the
  /// server redirects to `vibe://platforms/oauth?...`.
  @MainActor
  static func connect(
    provider: String,
    config: AppSessionConfig,
    presentationAnchor: ASPresentationAnchor
  ) async throws -> PlatformConnection? {
    let start = try await request(
      config: config,
      method: "POST",
      path: "/platforms/connections/\(pathEscape(provider))/authorize",
      body: [:]
    )
    guard let authorizeURLString = start["authorizeUrl"] as? String
            ?? start["authorize_url"] as? String,
      let authorizeURL = URL(string: authorizeURLString)
    else {
      throw PlatformConnectorsError.invalidResponse
    }

    let callbackURL = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
      let session = ASWebAuthenticationSession(
        url: authorizeURL,
        callbackURLScheme: "vibe"
      ) { callbackURL, error in
        if let error {
          let ns = error as NSError
          if ns.domain == ASWebAuthenticationSessionErrorDomain,
            ns.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
          {
            cont.resume(throwing: PlatformConnectorsError.oauthCancelled)
          } else {
            cont.resume(throwing: error)
          }
          return
        }
        guard let callbackURL else {
          cont.resume(throwing: PlatformConnectorsError.oauthFailed("Missing callback"))
          return
        }
        cont.resume(returning: callbackURL)
      }
      session.presentationContextProvider = PlatformOAuthPresenter.shared
      PlatformOAuthPresenter.shared.anchor = presentationAnchor
      session.prefersEphemeralWebBrowserSession = false
      if !session.start() {
        cont.resume(throwing: PlatformConnectorsError.oauthFailed("Could not start browser session"))
      }
    }

    let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)
    var query: [String: String] = [:]
    for item in components?.queryItems ?? [] {
      if let value = item.value {
        query[item.name] = value
      }
    }
    let status = query["status"] ?? ""
    if status != "success" {
      throw PlatformConnectorsError.oauthFailed(query["error"] ?? "oauth_failed")
    }

    // Server already completed token exchange on the callback; refresh list.
    let connections = try await fetchConnections(config: config)
    if let id = query["connectionId"] {
      return connections.first(where: { $0.id == id }) ?? connections.first(where: { $0.provider == provider })
    }
    return connections.first(where: { $0.provider == provider })
  }

  // MARK: - HTTP

  private static func request(
    config: AppSessionConfig,
    method: String,
    path: String,
    body: [String: Any]? = nil
  ) async throws -> [String: Any] {
    guard let url = apiURL(base: config.apiBaseURLString, path: path) else {
      throw PlatformConnectorsError.invalidConfiguration
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 30
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    let (data, response) = try await VibeHTTP.shared.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw PlatformConnectorsError.invalidResponse
    }
    guard (200...299).contains(response.statusCode) else {
      throw PlatformConnectorsError.http(
        response.statusCode,
        String(data: data, encoding: .utf8) ?? ""
      )
    }
    if data.isEmpty { return [:] }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw PlatformConnectorsError.invalidResponse
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

  private static func pathEscape(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
  }

  // MARK: - Decode

  private static func decodeCatalogItem(_ raw: [String: Any]) -> PlatformCatalogItem? {
    guard let id = string(raw["id"]) else { return nil }
    let caps = (raw["capabilities"] as? [[String: Any]] ?? []).compactMap { c -> PlatformCapability? in
      guard let cid = string(c["id"]) else { return nil }
      return PlatformCapability(
        id: cid,
        name: string(c["name"]) ?? cid,
        description: string(c["description"]) ?? ""
      )
    }
    return PlatformCatalogItem(
      id: id,
      name: string(raw["name"]) ?? id.capitalized,
      description: string(raw["description"]) ?? "",
      icon: string(raw["icon"]) ?? "link",
      category: string(raw["category"]) ?? "other",
      status: string(raw["status"]) ?? "coming_soon",
      capabilities: caps
    )
  }

  private static func decodeConnection(_ raw: [String: Any]) -> PlatformConnection? {
    guard let id = string(raw["id"]), let provider = string(raw["provider"]) else { return nil }
    let grants = (raw["grants"] as? [[String: Any]] ?? []).compactMap(decodeGrant)
    let metadata = raw["metadata"] as? [String: Any] ?? [:]
    return PlatformConnection(
      id: id,
      provider: provider,
      externalAccountLogin: string(raw["externalAccountLogin"] ?? raw["external_account_login"]),
      displayName: string(raw["displayName"] ?? raw["display_name"]),
      status: string(raw["status"]) ?? "active",
      scopes: stringList(raw["scopes"]),
      capabilities: stringList(raw["capabilities"]),
      grants: grants,
      avatarURL: string(metadata["avatar_url"] ?? metadata["avatarUrl"])
    )
  }

  private static func decodeGrant(_ raw: [String: Any]) -> PlatformGrant? {
    guard let id = string(raw["id"]) else { return nil }
    return PlatformGrant(
      id: id,
      granteeType: string(raw["granteeType"] ?? raw["grantee_type"]) ?? "",
      granteeId: string(raw["granteeId"] ?? raw["grantee_id"]) ?? "",
      capabilities: stringList(raw["capabilities"]),
      enabled: (raw["enabled"] as? Bool) ?? true
    )
  }

  private static func string(_ value: Any?) -> String? {
    guard let value else { return nil }
    if let s = value as? String {
      let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
      return t.isEmpty ? nil : t
    }
    return nil
  }

  private static func stringList(_ value: Any?) -> [String] {
    guard let list = value as? [Any] else { return [] }
    return list.compactMap { string($0) }
  }
}

// MARK: - OAuth presenter

private final class PlatformOAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
  static let shared = PlatformOAuthPresenter()
  var anchor: ASPresentationAnchor?

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    if let anchor { return anchor }
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
      return window
    }
    if let scene = scenes.first {
      return UIWindow(windowScene: scene)
    }
    // Last resort: any existing application window.
    return scenes.flatMap(\.windows).first ?? UIWindow(frame: UIScreen.main.bounds)
  }
}

private extension String {
  var nilIfBlank: String? {
    let t = trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
  }
}
