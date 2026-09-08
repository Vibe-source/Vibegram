import Combine
import SwiftUI
import UIKit

/// Settings → Proxy: the Use Proxy switch and the saved-proxy list. Native grouped list, so
/// edit mode brings the system's own row shift, delete badges and drag handles.
struct ProxySheetView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  let onDismiss: () -> Void

  @StateObject private var model = ProxyListModel()
  @State private var editing: PacketProxyProfile?

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    List {
      Section {
        Toggle("Use Proxy", isOn: $model.useProxy)
          .tint(.green)
      }

      Section {
        Button {
          editing = PacketProxyProfile()
        } label: {
          Label("Add Configuration", systemImage: "plus")
            .font(.system(size: 15))
            .foregroundStyle(palette.accent)
        }

        ForEach(model.profiles) { profile in
          ProxyRow(
            profile: profile,
            isSelected: model.activeID == profile.id,
            state: model.state(for: profile),
            onEdit: { editing = profile }
          )
          .contentShape(Rectangle())
          .onTapGesture { model.activate(profile) }
        }
        .onDelete(perform: model.delete)
        .onMove(perform: model.move)
      } header: {
        Text("Configurations")
      } footer: {
        if model.profiles.isEmpty {
          Text("Add a vless:// or trojan:// link to route this app through it.")
        }
      }
    }
    .listStyle(.insetGrouped)
    .tint(palette.accent)
    .navigationTitle("Proxy")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button {
          dismiss()
          onDismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        if !model.profiles.isEmpty {
          EditButton()
        }
      }
    }
    .sheet(item: $editing) { profile in
      NavigationStack {
        ProxyConfigurationEditor(profile: profile) { saved in
          model.save(saved)
        }
      }
    }
    .onAppear { model.appeared() }
    .onDisappear { model.disappeared() }
    .onReceive(NotificationCenter.default.publisher(for: PacketProxyStore.didChangeNotification)) {
      _ in model.reload()
    }
  }

}

// MARK: - Row

/// The chat list's menu glyph, two lines: full width over a short one.
private struct ProxyConfigGlyph: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let inset = rect.width * 0.08
    let top = rect.minY + rect.height * 0.34
    let bottom = rect.minY + rect.height * 0.66
    path.move(to: CGPoint(x: rect.minX + inset, y: top))
    path.addLine(to: CGPoint(x: rect.maxX - inset, y: top))
    path.move(to: CGPoint(x: rect.minX + inset, y: bottom))
    path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.38, y: bottom))
    return path
  }
}

/// What the row reports: the endpoint probe when idle, the engine's own state when running.
enum ProxyRowState: Equatable {
  case probing
  case reachable(Int)
  case unreachable
  case connecting
  case connected(Int?)
  case failed(String)
  case invalid(String)
}

private struct ProxyRow: View {
  @Environment(\.editMode) private var editMode

  let profile: PacketProxyProfile
  let isSelected: Bool
  let state: ProxyRowState
  let onEdit: () -> Void

  private var isEditing: Bool { editMode?.wrappedValue.isEditing == true }

  var body: some View {
    HStack(spacing: 10) {
      marker
        .frame(width: 16)

      VStack(alignment: .leading, spacing: 1) {
        title
        Text(detail)
          .font(.system(size: 13))
          .foregroundStyle(detailColor)
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      // Hidden in edit mode: the system already puts its drag handle here.
      if !isEditing {
        Button(action: onEdit) {
          ProxyConfigGlyph()
            .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
      }
    }
  }

  @ViewBuilder
  private var marker: some View {
    switch state {
    case .connecting:
      ProgressView().controlSize(.mini)
    case .connected:
      Image(systemName: "checkmark")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Color.green)
    default:
      Image(systemName: "checkmark")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.primary)
        .opacity(isSelected ? 1 : 0)
    }
  }

  /// Unnamed entries read as `host:port`, with the port dimmed like the system does.
  private var title: some View {
    let host = profile.endpointHost
    let named = profile.displayName != host
    return HStack(spacing: 0) {
      Text(profile.displayName)
        .foregroundStyle(.primary)
      if !named, !host.isEmpty {
        Text(":\(profile.endpointPort)")
          .foregroundStyle(.secondary)
      }
    }
    .font(.system(size: 16, weight: .medium))
    .lineLimit(1)
  }

  /// Active tunnel says connected. Ping is only for idle probe rows.
  private var detail: String {
    switch state {
    case .probing: return "checking…"
    case let .reachable(ms): return "ping \(ms) ms"
    case .unreachable: return "unavailable"
    case .connecting: return "connecting…"
    case .connected: return "connected"
    case let .failed(message): return message
    case let .invalid(message): return message
    }
  }

  /// A ping is a live endpoint, so it reads green whether or not this entry is the active one.
  private var detailColor: Color {
    switch state {
    case .reachable, .connected: return .green
    case .failed, .invalid: return .red
    default: return .secondary
    }
  }
}

// MARK: - List model

@MainActor
final class ProxyListModel: ObservableObject {
  @Published var profiles: [PacketProxyProfile] = []
  @Published var activeID: UUID?
  @Published var useProxy: Bool = PacketProxyStore.shared.useProxy {
    didSet {
      guard useProxy != PacketProxyStore.shared.useProxy else { return }
      PacketProxyStore.shared.setUseProxy(useProxy)
      reload()
    }
  }

  @Published private var engineStatus = ""
  @Published private var enginePort = 0
  @Published private var engineError: String?

  private let store = PacketProxyStore.shared
  private let reachability = PacketProxyReachability.shared
  private var pollTimer: Timer?
  private var reachabilityObserver: AnyCancellable?

  init() {
    reload()
  }

  func appeared() {
    reload()
    reachability.refreshIfStale(profiles)
    reachabilityObserver = reachability.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async { self?.objectWillChange.send() }
    }
    // The engine publishes its port from a background start and nothing notifies SwiftUI.
    // Reads the config once per tick and only publishes on a change, so idle costs nothing.
    refreshEngineSnapshot()
    pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.refreshEngineSnapshot() }
    }
  }

  func disappeared() {
    pollTimer?.invalidate()
    pollTimer = nil
    reachabilityObserver = nil
  }

  func reload() {
    profiles = store.profiles
    activeID = store.activeProfile?.id
    if useProxy != store.useProxy { useProxy = store.useProxy }
  }

  /// The engine's own state, not the stored config: the config is written once at start, so a
  /// tunnel that dies afterwards (bad credentials, blocked exit) never shows up there.
  private func refreshEngineSnapshot() {
    let config = ChatEngineStore.shared.getConfig()
    let port = (config["packetProxyPort"] as? NSNumber)?.intValue ?? 0
    let live = PacketProxyEngine.stats()
    let status = (live?.state ?? (config["packetStatus"] as? String) ?? "").lowercased()
    let error = live?.lastError ?? (config["packetLastError"] as? String)

    if status != engineStatus { engineStatus = status }
    if port != enginePort { enginePort = port }
    if error != engineError { engineError = error }

    guard useProxy, port > 0 else {
      reachability.resetTunnel()
      return
    }
    if let apiBase = AppSessionConfig.current?.apiBaseURL {
      reachability.probeTunnel(
        proxyHost: (config["packetProxyHost"] as? String) ?? "127.0.0.1",
        proxyPort: port,
        apiBase: apiBase
      )
    }
  }

  /// Engine state wins for the entry actually carrying traffic; everything else reports its probe.
  func state(for profile: PacketProxyProfile) -> ProxyRowState {
    if let error = profile.validationError { return .invalid(error) }

    guard useProxy, activeID == profile.id else {
      switch reachability.status(for: profile) {
      case .unknown, .checking: return .probing
      case let .live(ms): return .reachable(ms)
      case .unavailable: return .unreachable
      }
    }

    if engineStatus == "failed", let error = engineError { return .failed(Self.shortError(error)) }
    guard enginePort > 0 else { return .connecting }

    // Connected only once real traffic has come back through the proxy.
    switch reachability.tunnel {
    case let .live(ms):
      return .connected(ms)
    case .unavailable:
      return .failed(engineError.map(Self.shortError) ?? "proxy not passing traffic")
    case .unknown, .checking:
      return .connecting
    }
  }

  /// Engine errors arrive as multi-line warnings; the row gets the first line only.
  private static func shortError(_ raw: String) -> String {
    let line = raw.split(separator: "\n").first.map(String.init) ?? raw
    return line.count > 80 ? String(line.prefix(80)) + "…" : line
  }

  /// No re-probe here — the ping is already on screen and re-measuring would make it jump.
  func activate(_ profile: PacketProxyProfile) {
    store.activate(id: profile.id)
    reload()
    refreshEngineSnapshot()
  }

  func save(_ profile: PacketProxyProfile) {
    store.upsert(profile)
    reload()
    reachability.probe(profile)
  }

  func delete(at offsets: IndexSet) {
    for index in offsets.sorted(by: >) where profiles.indices.contains(index) {
      store.delete(id: profiles[index].id)
    }
    reload()
  }

  func move(fromOffsets source: IndexSet, toOffset destination: Int) {
    store.move(fromOffsets: source, toOffset: destination)
    reload()
  }
}

// MARK: - Per-proxy configuration

/// Packet's server editor, field for field, against a Vibe proxy entry.
struct ProxyConfigurationEditor: View {
  @Environment(\.dismiss) private var dismiss

  @State private var draft: PacketProxyProfile
  @State private var settingsError: String?
  @State private var revealsSecret = false
  private let onSave: (PacketProxyProfile) -> Void
  private let isNew: Bool

  init(profile: PacketProxyProfile, onSave: @escaping (PacketProxyProfile) -> Void) {
    self._draft = State(initialValue: profile)
    self.isNew = profile.normalizedServerURL.isEmpty && profile.normalizedCarrierURI.isEmpty
    self.onSave = onSave
  }

  var body: some View {
    Form {
      if let settingsError {
        Section {
          InlineFieldError(text: settingsError)
        }
      }

      Section {
        HStack {
          Text("Name")
          Spacer()
          TextField(
            "", text: $draft.name,
            prompt: Text(draft.displayName).foregroundColor(.secondary)
          )
          .textInputAutocapitalization(.words)
          .multilineTextAlignment(.trailing)
          .foregroundStyle(.secondary)
        }

        Picker("Stack Mode", selection: $draft.stack) {
          ForEach(PacketProxyStack.allCases) { stack in
            Text(stack.title).tag(stack)
          }
        }
      } header: {
        Text("Profile Details")
      }

      if draft.usesCarrier {
        Section {
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text("Link")
              Spacer()
              TextField("trojan:// or vless://", text: $draft.carrierURI)
                .keyboardType(.URL)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }

            if let error = carrierURIError {
              InlineFieldError(text: error)
            }
          }

          HStack {
            Text("Local Port")
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
              TextField("10808", text: $draft.carrierProxyPort)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)

              if let error = carrierPortError {
                InlineFieldError(text: error)
              }
            }
          }
        } header: {
          Text("Carrier")
        } footer: {
          Text("Trojan or VLESS carrier link.")
        }
      }

      if draft.stack == .directSock {
        Section {
          Toggle("TLS Fragmentation", isOn: $draft.fragmentEnabled)

          if draft.fragmentEnabled {
            fragmentSizeField(placeholder: "100")
          }
        } header: {
          Text("Advanced")
        }
      } else {
        Section {
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(draft.transport == .reality ? "Link" : "Server URL")
              Spacer()
              TextField(
                draft.transport == .reality ? "vless://…reality…" : "https://example.com",
                text: $draft.serverURL
              )
              .keyboardType(.URL)
              .multilineTextAlignment(.trailing)
              .foregroundStyle(.secondary)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            }

            if let error = serverURLError {
              InlineFieldError(text: error)
            }
          }

          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text("Password")
              Spacer()
              Group {
                if revealsSecret {
                  TextField("Required", text: $draft.secret)
                } else {
                  SecureField("Required", text: $draft.secret)
                }
              }
              .multilineTextAlignment(.trailing)
              .foregroundStyle(.secondary)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()

              Button(action: { revealsSecret.toggle() }) {
                Image(systemName: revealsSecret ? "eye.slash" : "eye")
                  .foregroundStyle(.secondary)
              }
              .buttonStyle(.plain)
            }

            if let error = secretError {
              InlineFieldError(text: error)
            }
          }
        } header: {
          Text("Server Info")
        }

        Section {
          HStack {
            Text("Listen Port")
            Spacer()
            TextField("Auto", text: $draft.listenPort)
              .keyboardType(.numberPad)
              .multilineTextAlignment(.trailing)
              .foregroundStyle(.secondary)
          }

          Picker("Transport", selection: $draft.transport) {
            ForEach(PacketProxyTransport.allCases) { transport in
              Text(transport.title).tag(transport)
            }
          }

          if draft.transport == .obfs {
            HStack {
              Text("Obfs Key")
              Spacer()
              SecureField("Optional", text: $draft.obfsKey)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }

            HStack {
              Text("First-Hop Proxy")
              Spacer()
              TextField("Optional", text: $draft.upstreamProxy)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
          }
        } header: {
          Text("Network")
        }

        Section {
          overrideField("CDN Edge", text: $draft.cdnEdge, placeholder: "cdn.example.com:80")
          overrideField("Host Override", text: $draft.hostOverride, placeholder: "cdn.example.com")
          overrideField("SNI Override", text: $draft.sniOverride, placeholder: "gateway.icloud.com")
        } header: {
          Text("Fronting")
        } footer: {
          Text("Leave blank unless your network requires them.")
        }

        Section {
          Toggle("TLS Fragmentation", isOn: $draft.fragmentEnabled)

          if draft.fragmentEnabled {
            fragmentSizeField(placeholder: "40")
          }
        } header: {
          Text("Advanced")
        }
      }
    }
    .scrollDismissesKeyboard(.interactively)
    .navigationTitle(isNew ? "New Proxy" : "Edit Proxy")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("Save", action: save)
          .fontWeight(.semibold)
      }
    }
    .onChange(of: draft) { _, _ in settingsError = nil }
  }

  private func fragmentSizeField(placeholder: String) -> some View {
    HStack {
      Text("Fragment Size")
      Spacer()
      VStack(alignment: .trailing, spacing: 4) {
        TextField(placeholder, text: $draft.fragmentSize)
          .keyboardType(.numberPad)
          .multilineTextAlignment(.trailing)
          .foregroundStyle(.secondary)

        if let error = fragmentSizeError {
          InlineFieldError(text: error)
        }
      }
    }
  }

  /// Same shape as Server Info: label left, value right — not a header stacked over a field.
  private func overrideField(
    _ label: String,
    text: Binding<String>,
    placeholder: String
  ) -> some View {
    HStack {
      Text(label)
      Spacer()
      TextField(placeholder, text: text)
        .keyboardType(.URL)
        .multilineTextAlignment(.trailing)
        .foregroundStyle(.secondary)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }
  }

  private var serverURLError: String? {
    guard let settingsError else { return nil }
    return settingsError.localizedCaseInsensitiveContains("server url") ? "Required" : nil
  }

  private var secretError: String? {
    guard let settingsError else { return nil }
    return settingsError.localizedCaseInsensitiveContains("shared secret") ? "Required" : nil
  }

  private var carrierURIError: String? {
    guard let settingsError else { return nil }
    if settingsError.localizedCaseInsensitiveContains("carrier link is required") {
      return "Required"
    }
    if settingsError.localizedCaseInsensitiveContains("trojan:// or vless://") {
      return "Use trojan:// or vless://"
    }
    return nil
  }

  private var carrierPortError: String? {
    guard let settingsError else { return nil }
    return settingsError.localizedCaseInsensitiveContains("carrier port") ? "1024-65535" : nil
  }

  private var fragmentSizeError: String? {
    guard let settingsError else { return nil }
    return settingsError.localizedCaseInsensitiveContains("fragment size") ? "1-1000" : nil
  }

  private func save() {
    if let validationError = draft.validationError {
      UINotificationFeedbackGenerator().notificationOccurred(.warning)
      settingsError = validationError
      return
    }
    onSave(draft)
    dismiss()
  }
}

private struct InlineFieldError: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption)
      .foregroundStyle(.red)
  }
}
