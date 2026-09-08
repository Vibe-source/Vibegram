import AuthenticationServices
import SwiftUI
import UIKit

/// Settings → Connected Apps: multi-platform OAuth connectors (GitHub first).
struct PlatformConnectorsView: View {
  @Environment(\.colorScheme) private var colorScheme
  @State private var catalog: [PlatformCatalogItem] = []
  @State private var connections: [PlatformConnection] = []
  @State private var isLoading = true
  @State private var busyProvider: String?
  @State private var errorMessage: String?
  @State private var toastMessage: String?

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    List {
      if let errorMessage {
        Section {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }

      Section {
        Text(
          "Connect platforms once. Coding agents (Claude, Codex, Grok) and your Vibe agents can use them for PR work and other tools — tokens never leave the server."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .listRowBackground(Color.clear)
      }

      if !connections.isEmpty {
        Section("Connected") {
          ForEach(connections) { connection in
            connectionRow(connection)
          }
        }
      }

      Section("Available") {
        ForEach(catalog) { item in
          catalogRow(item)
        }
      }

      Section("Agent access") {
        Text(
          "After connecting GitHub, Claude/Codex/Grok automatically receive a grant for PR tools. Grant a Vibe agent from that agent’s settings → tools (enable Call Platform)."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
    }
    .navigationTitle("Connected Apps")
    .navigationBarTitleDisplayMode(.inline)
    .overlay {
      if isLoading {
        ProgressView()
      }
    }
    .refreshable { await reload() }
    .task { await reload() }
    .alert("Notice", isPresented: Binding(
      get: { toastMessage != nil },
      set: { if !$0 { toastMessage = nil } }
    )) {
      Button("OK", role: .cancel) { toastMessage = nil }
    } message: {
      Text(toastMessage ?? "")
    }
  }

  @ViewBuilder
  private func connectionRow(_ connection: PlatformConnection) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        providerIcon(connection.provider)
        VStack(alignment: .leading, spacing: 2) {
          Text(providerTitle(connection.provider))
            .font(.body.weight(.semibold))
          Text("@\(connection.externalAccountLogin ?? connection.title)")
            .font(.footnote)
            .foregroundStyle(.secondary)
          Text(connection.status.capitalized)
            .font(.caption2)
            .foregroundStyle(connection.status == "active" ? .green : .orange)
        }
        Spacer()
        Button("Disconnect", role: .destructive) {
          Task { await disconnect(connection) }
        }
        .font(.footnote.weight(.semibold))
        .disabled(busyProvider != nil)
      }

      if !connection.capabilities.isEmpty {
        Text(connection.capabilities.prefix(6).joined(separator: " · "))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      let bridgeGrants = connection.grants.filter { $0.granteeType == "bridge_agent" && $0.enabled }
      if !bridgeGrants.isEmpty {
        Text("Agents: " + bridgeGrants.map(\.granteeId).sorted().joined(separator: ", "))
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private func catalogRow(_ item: PlatformCatalogItem) -> some View {
    let connected = connections.contains(where: { $0.provider == item.id && $0.status == "active" })
    HStack(spacing: 12) {
      providerIcon(item.id)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.name)
          .font(.body.weight(.medium))
        Text(item.description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
        if item.isComingSoon {
          Text("Coming soon")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
        } else if item.status == "needs_config" {
          Text("Server OAuth keys not set")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
        }
      }
      Spacer()
      if connected {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(.green)
      } else if item.isComingSoon {
        Text("Soon")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      } else {
        Button {
          Task { await connect(provider: item.id) }
        } label: {
          if busyProvider == item.id {
            ProgressView().controlSize(.small)
          } else {
            Text("Connect")
              .font(.footnote.weight(.semibold))
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(busyProvider != nil)
      }
    }
    .padding(.vertical, 4)
  }

  private func providerIcon(_ provider: String) -> some View {
    let system: String
    switch provider {
    case "github": system = "chevron.left.forwardslash.chevron.right"
    case "microsoft_excel": system = "tablecells"
    case "slack": system = "number"
    case "linear": system = "line.3.horizontal"
    case "google_calendar": system = "calendar"
    default: system = "link"
    }
    return Image(systemName: system)
      .font(.system(size: 18, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 36, height: 36)
      .background(providerColor(provider))
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private func providerColor(_ provider: String) -> Color {
    switch provider {
    case "github": return Color(red: 0.13, green: 0.13, blue: 0.14)
    case "microsoft_excel": return Color(red: 0.13, green: 0.50, blue: 0.30)
    case "slack": return Color(red: 0.29, green: 0.18, blue: 0.36)
    case "linear": return Color(red: 0.35, green: 0.40, blue: 0.95)
    case "google_calendar": return Color(red: 0.20, green: 0.45, blue: 0.85)
    default: return Color.accentColor
    }
  }

  private func providerTitle(_ provider: String) -> String {
    catalog.first(where: { $0.id == provider })?.name ?? provider.replacingOccurrences(of: "_", with: " ").capitalized
  }

  @MainActor
  private func reload() async {
    guard let config = AppSessionConfig.current else {
      errorMessage = "Sign in to manage connected apps."
      isLoading = false
      return
    }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      async let catalogTask = PlatformConnectorsService.fetchCatalog(config: config)
      async let connectionsTask = PlatformConnectorsService.fetchConnections(config: config)
      catalog = try await catalogTask
      connections = try await connectionsTask
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func connect(provider: String) async {
    guard let config = AppSessionConfig.current else {
      errorMessage = "Sign in to connect apps."
      return
    }
    busyProvider = provider
    errorMessage = nil
    defer { busyProvider = nil }
    do {
      let anchor = presentationAnchor()
      _ = try await PlatformConnectorsService.connect(
        provider: provider,
        config: config,
        presentationAnchor: anchor
      )
      connections = try await PlatformConnectorsService.fetchConnections(config: config)
      toastMessage = "Connected \(providerTitle(provider)). Agents can use it for PR work."
    } catch let error as PlatformConnectorsError {
      if case .oauthCancelled = error { return }
      errorMessage = error.localizedDescription
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func disconnect(_ connection: PlatformConnection) async {
    guard let config = AppSessionConfig.current else { return }
    busyProvider = connection.provider
    defer { busyProvider = nil }
    do {
      try await PlatformConnectorsService.revoke(connectionId: connection.id, config: config)
      connections = try await PlatformConnectorsService.fetchConnections(config: config)
      toastMessage = "Disconnected \(providerTitle(connection.provider))."
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func presentationAnchor() -> ASPresentationAnchor {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
      return window
    }
    if let scene = scenes.first {
      return UIWindow(windowScene: scene)
    }
    return scenes.flatMap(\.windows).first ?? UIWindow(frame: UIScreen.main.bounds)
  }
}
