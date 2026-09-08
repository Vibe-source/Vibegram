import SwiftUI
import UIKit

// Profile surfaces for a Claude/Codex/Grok bridge agent:
//   * AgentBridgeConnectionSheet — which computer is connected, Disconnect, and
//     Reconnect / Add connection (scan the QR the daemon prints).
//   * AgentBridgeHistoryInlineView — the agent's OWN past Claude/Codex/Grok
//     conversations (topic list), read from the connected computer via the
//     bridge. Pushed into `ChatProfileMainView`'s NavigationStack so it
//     morph-expands from the "Chat History" row. Tapping a topic pushes the
//     dedicated agent runtime surface with the topic header and composer.
//
// The connection sheet is presented; the history is pushed (morph) from
// `ChatProfileMainView` for Claude/Codex/Grok profiles.
//
// `AgentBridgeTranscriptView` below is retained as a standalone fallback
// renderer but is no longer wired into the profile navigation.

enum AgentBridgeProfile {
  static func displayName(for provider: String) -> String {
    switch provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "claude": return "Claude"
    case "codex": return "Codex"
    case "grok": return "Grok"
    default: return provider.capitalized
    }
  }

  @MainActor static func presentConnection(provider: String, from presenter: UIViewController) {
    let model = AgentConnectModel(provider: provider, displayName: displayName(for: provider))
    if let snapshot = AgentPairingService.lastStatusSnapshot {
      model.status = snapshot
      model.selectedRepository = AgentBridgeSelectionStore.ensureValidSelection(from: snapshot.repositories)
    }
    let isDark = presenter.traitCollection.userInterfaceStyle == .dark
    let host = UIHostingController(
      rootView: AgentBridgeConnectionSheet(model: model)
        .preferredColorScheme(isDark ? .dark : .light)
    )
    host.view.backgroundColor = .clear
    host.view.tintColor = isDark ? .white : .black
    host.overrideUserInterfaceStyle = isDark ? .dark : .light
    host.modalPresentationStyle = .pageSheet
    if let sheet = host.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.selectedDetentIdentifier = .medium
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 22
    }
    presenter.present(host, animated: true)
  }

}

// MARK: - Connection sheet (connect / disconnect / reconnect)

struct AgentBridgeConnectionSheet: View {
  @ObservedObject var model: AgentConnectModel
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  @State private var isWorking = false
  @State private var errorMessage: String?
  @State private var transportPreference: AgentBridgeTransportPreference = AgentBridgeTransport.preference
  @State private var lanState: LanBridgeService.State = LanBridgeService.shared.currentState

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }

  private var rowFill: Color {
    colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.04)
  }

  private var transportPreferenceText: String {
    switch transportPreference {
    case .auto: return "Auto"
    case .local: return "Local"
    case .cloud: return "Cloud"
    }
  }

  private var transportPreferenceIcon: String {
    switch transportPreference {
    case .auto: return "arrow.triangle.2.circlepath"
    case .local: return "wifi"
    case .cloud: return "cloud"
    }
  }

  private var sheetTint: Color {
    colorScheme == .dark ? Color.white : Color.black
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          if model.status.connected, let device = model.status.devices.first {
            statusRow(
              icon: "laptopcomputer",
              title: device.label,
              subtitle: "Connected",
              subtitleColor: .green,
              showsDot: true
            )
          } else if model.status.paired {
            statusRow(
              icon: "laptopcomputer.slash",
              title: model.status.devices.first?.label ?? "Your computer",
              subtitle: "Paired — bridge offline",
              subtitleColor: palette.secondaryText
            )
          } else {
            statusRow(
              icon: "laptopcomputer.slash",
              title: "No computer connected",
              subtitle: "Pair one to start",
              subtitleColor: palette.secondaryText
            )
          }

          Button {
            model.beginScan()
          } label: {
            HStack(spacing: 10) {
              if model.isAuthorizing || isWorking {
                ProgressView()
                  .tint(sheetTint)
              } else {
                Image(systemName: "qrcode.viewfinder")
                  .font(.system(size: 17, weight: .semibold))
              }
              Text(model.status.paired || model.status.connected ? "Scan QR to reconnect" : "Scan QR to connect")
                .font(.system(size: 16, weight: .semibold))
            }
            .frame(maxWidth: .infinity, alignment: .center)
          }
          .disabled(isWorking || model.isAuthorizing)
          .foregroundColor(sheetTint)
        } header: {
          Text("Computer")
        }
        .listRowBackground(rowFill)

        Section {
          HStack {
            Text("Connection")
              .font(.system(size: 16, weight: .regular))
              .foregroundStyle(palette.text)
            Spacer()
            Menu {
              Button {
                transportPreference = .auto
                AgentBridgeTransport.preference = .auto
                LanBridgeService.shared.applyPreference(.auto)
              } label: {
                Label("Auto", systemImage: "arrow.triangle.2.circlepath")
              }
              Button {
                transportPreference = .local
                AgentBridgeTransport.preference = .local
                LanBridgeService.shared.applyPreference(.local)
              } label: {
                Label("Local", systemImage: "wifi")
              }
              Button {
                transportPreference = .cloud
                AgentBridgeTransport.preference = .cloud
                LanBridgeService.shared.applyPreference(.cloud)
              } label: {
                Label("Cloud", systemImage: "cloud")
              }
            } label: {
              HStack(spacing: 6) {
                Image(systemName: transportPreferenceIcon)
                  .font(.system(size: 14, weight: .medium))
                Text(transportPreferenceText)
                Image(systemName: "chevron.up.chevron.down")
                  .font(.system(size: 11, weight: .bold))
              }
              .font(.system(size: 15, weight: .medium))
              .foregroundStyle(sheetTint)
            }
          }

          HStack(spacing: 9) {
            lanStatusIndicator
            Text(lanStatusText)
              .font(.system(size: 13.5, weight: .medium))
              .foregroundStyle(palette.text)
              .lineLimit(1)
            Spacer(minLength: 0)
          }
          .padding(.vertical, 2)
        } header: {
          Text("Connection")
        }
        .listRowBackground(rowFill)

        if let errorMessage {
          Section {
            Text(errorMessage)
              .font(.system(size: 13))
              .foregroundStyle(palette.danger)
              .fixedSize(horizontal: false, vertical: true)
          }
          .listRowBackground(rowFill)
        }

        if model.status.paired || model.status.connected {
          Section {
            Button(role: .destructive) {
              disconnect()
            } label: {
              HStack(spacing: 10) {
                Image(systemName: "xmark.circle")
                  .font(.system(size: 17, weight: .semibold))
                Text("Disconnect computer")
                  .font(.system(size: 16, weight: .semibold))
              }
              .frame(maxWidth: .infinity, alignment: .center)
            }
            .disabled(isWorking)
            .foregroundColor(palette.danger)
          }
          .listRowBackground(rowFill)
        }
      }
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      .background(Color.clear)
      .navigationTitle("\(model.displayName) computer")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { dismiss() }
        }
      }
      .tint(sheetTint)
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .presentationBackground(.ultraThinMaterial)
    .onAppear {
      model.startPolling()
      // Kick off local-network discovery of the paired Mac. First run here triggers the
      // iOS local-network permission prompt; thereafter it finds + authenticates the bridge.
      LanBridgeService.shared.start(userId: nil)
    }
    .onDisappear { model.stopPolling() }
    .onReceive(NotificationCenter.default.publisher(for: LanBridgeService.stateChangedNotification)) { _ in
      lanState = LanBridgeService.shared.currentState
    }
    .fullScreenCover(isPresented: $model.isScanning) {
      AgentQRScannerView(
        instruction: "Scan the QR shown on your computer",
        message: model.scannerMessage,
        statusStyle: model.scannerStatusStyle,
        isProcessing: model.isAuthorizing,
        canRetry: model.scannerCanRetry,
        resetToken: model.scannerResetToken,
        onResult: { model.handleScanned($0) },
        onRetry: { model.retryScan() },
        onCancel: { model.cancelScan() }
      )
      .ignoresSafeArea()
    }
  }

  /// A quiet spinner while the link is coming up, a green dot when it's direct, and a
  /// muted dot otherwise — no wording needed to read the state at a glance.
  @ViewBuilder
  private var lanStatusIndicator: some View {
    switch lanState {
    case .searching, .found, .connecting:
      ProgressView()
        .controlSize(.mini)
        .tint(palette.secondaryText)
    case .authenticated:
      Circle().fill(Color.green).frame(width: 8, height: 8)
    default:
      Circle().fill(palette.secondaryText.opacity(0.5)).frame(width: 8, height: 8)
    }
  }

  /// Short, human, jargon-free. Traffic always rides the cloud when there's no direct
  /// link, so anything that isn't a live direct link simply reads "Cloud".
  private var lanStatusText: String {
    switch lanState {
    case .authenticated(let name): return "Direct · \(name)"
    case .searching: return "Looking for your Mac…"
    case .found(let name): return "Connecting to \(name)…"
    case .connecting: return "Connecting…"
    case .idle: return transportPreference == .cloud ? "Cloud" : "Ready"
    case .failed, .unavailable: return "Cloud"
    }
  }

  private func statusRow(
    icon: String,
    title: String,
    subtitle: String,
    subtitleColor: Color,
    showsDot: Bool = false
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(palette.text.opacity(0.85))
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(palette.text)
          .lineLimit(1)
        Text(subtitle)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(subtitleColor)
      }
      Spacer(minLength: 8)
      if showsDot {
        Circle().fill(Color.green).frame(width: 9, height: 9)
      }
    }
    .padding(.vertical, 2)
  }


  private func disconnect() {
    guard let config = AppSessionConfig.current else {
      errorMessage = "The current session is unavailable."
      return
    }
    isWorking = true
    errorMessage = nil
    Task {
      defer { isWorking = false }
      do {
        try await AgentPairingService.revoke(config: config)
        model.stopPolling()
        await MainActor.run { model.status = .disconnected }
        model.startPolling()
      } catch {
        await MainActor.run { errorMessage = error.localizedDescription }
      }
    }
  }
}

// MARK: - History (topics → transcript), read from the connected computer

struct AgentBridgeHistorySession: Identifiable, Hashable {
  let id: String
  let topic: String
  let projectName: String
  let projectPath: String
  let updatedAt: String
  let messageCount: Int
  let isRunning: Bool
  let taskId: String?
  let sessionId: String?
  /// Bridge-reported model id for this session (live task or archived transcript).
  var model: String? = nil
  /// Bridge-reported thinking/reasoning effort (`low`…`max`). Nil when unknown —
  /// never invent a mobile default for archived rows.
  var reasoningEffort: String? = nil
  /// Non-nil when this session's run is blocked on a still-pending ask/command
  /// approval ("ask" | "command" | "plan") — the bridge badges it in the list reply.
  var pendingAskKind: String? = nil

  var resolvedSessionId: String {
    if let sessionId, !sessionId.isEmpty { return sessionId }
    return id
  }

  var projectKey: String {
    let path = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if !path.isEmpty { return path }
    let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "Computer" : name
  }

  var displayProjectName: String {
    let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
    if !name.isEmpty { return name }
    let path = projectPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if !path.isEmpty { return URL(fileURLWithPath: path).lastPathComponent }
    return "Computer"
  }

  /// Compact human label for the history row, e.g. `Opus 4.6 · High Thinking`.
  /// Omits the thinking segment when effort is missing or unmapped.
  func configurationLabel(provider: String) -> String? {
    AgentBridgeSessionConfiguration.compactLabel(
      provider: provider,
      model: model,
      reasoningEffort: reasoningEffort
    )
  }
}

/// Shared formatter for bridge-reported model + thinking effort.
enum AgentBridgeSessionConfiguration {
  /// `Opus 4.6 · High Thinking` / `GPT-5.6 · Medium Thinking` / model-only when effort unknown.
  static func compactLabel(
    provider: String,
    model: String?,
    reasoningEffort: String?
  ) -> String? {
    let modelId = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let modelPart: String? = {
      guard !modelId.isEmpty else { return nil }
      let title = AgentBridgeSelectionStore.modelTitle(provider: provider, model: modelId)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return title.isEmpty ? modelId : title
    }()
    let effortPart: String? = {
      guard let level = AgentBridgeIntelligenceLevel.fromProviderEffort(reasoningEffort) else {
        return nil
      }
      return "\(level.title) Thinking"
    }()
    switch (modelPart, effortPart) {
    case let (m?, e?): return "\(m) · \(e)"
    case let (m?, nil): return m
    case let (nil, e?): return e
    default: return nil
    }
  }
}

private struct AgentBridgeHistoryProjectGroup: Identifiable {
  let id: String
  let name: String
  let sessions: [AgentBridgeHistorySession]
}

struct AgentBridgeTranscriptMessage: Identifiable {
  let id = UUID()
  let role: String
  let text: String
}

// MARK: - History loading skeletons

private struct AgentBridgeShimmerPill: View {
  var width: CGFloat? = nil
  var height: CGFloat
  var cornerRadius: CGFloat = 14
  
  @Environment(\.colorScheme) private var colorScheme
  @State private var phase: CGFloat = -1.0
  
  var body: some View {
    let isDark = colorScheme == .dark
    // Soft monochrome base + a wide, feathered highlight that fades to clear at both
    // ends, so the sweep reads as a gentle glow instead of a hard-edged bar.
    let baseColor = isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03)
    let shineColor = isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)

    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      .fill(baseColor)
      .overlay(
        GeometryReader { geo in
          let w = max(geo.size.width, 1)
          // ~70%-wide highlight band with clear, feathered ends — no visible edge.
          LinearGradient(
            stops: [
              .init(color: .clear, location: 0.0),
              .init(color: shineColor.opacity(0.15), location: 0.25),
              .init(color: shineColor, location: 0.5),
              .init(color: shineColor.opacity(0.15), location: 0.75),
              .init(color: .clear, location: 1.0),
            ],
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: w * 0.7)
          .offset(x: phase * (w + w * 0.7))
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      )
      .frame(width: width, height: height)
      .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
      .onAppear {
        phase = -1.0
        withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
          phase = 1.0
        }
      }
  }
}

private struct AgentBridgeHistoryListSkeleton: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let isDark = colorScheme == .dark
    let baseColor = isDark ? Color(red: 40/255, green: 40/255, blue: 40/255) : Color(red: 221/255, green: 219/255, blue: 221/255)
    
    ScrollView(showsIndicators: false) {
      VStack(spacing: 26) {
        ForEach(0..<7, id: \.self) { _ in
          VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
              .fill(baseColor)
              .frame(width: 180, height: 19)
              .padding(.top, 6)
            RoundedRectangle(cornerRadius: 9, style: .continuous)
              .fill(baseColor)
              .frame(width: 120, height: 19)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.horizontal, 20)
      .padding(.top, 16)
      .modifier(WholeShimmerModifier())
    }
    .allowsHitTesting(false)
    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
  }
}

private struct WholeShimmerModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  @State private var phase: CGFloat = -1.0
  
  func body(content: Content) -> some View {
    let isDark = colorScheme == .dark
    let shimmerColor = isDark ? Color.white.opacity(0.18) : Color.white.opacity(0.55)
    
    return content
      .overlay(
        GeometryReader { geo in
          let w = geo.size.width
          LinearGradient(
            stops: [
              .init(color: .clear, location: 0.0),
              .init(color: shimmerColor.opacity(0.4), location: 0.3),
              .init(color: shimmerColor, location: 0.5),
              .init(color: shimmerColor.opacity(0.4), location: 0.7),
              .init(color: .clear, location: 1.0),
            ],
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: w * 0.8)
          .offset(x: phase * (w * 1.8))
        }
        .mask(content)
      )
      .onAppear {
        phase = -1.0
        withAnimation(.linear(duration: 5.0).repeatForever(autoreverses: false)) {
          phase = 1.0
        }
      }
  }
}


/// Skeleton for the transcript DETAIL: alternating role label + text-line bubbles,
/// so a loading conversation reads as chat bubbles rather than a spinner.
private struct AgentBridgeTranscriptSkeleton: View {
  @State private var phase: CGFloat = -1.0
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let isDark = colorScheme == .dark
    let baseColor = isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03)
    let shineColor = isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.05)

    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        ForEach(0..<5, id: \.self) { index in
          VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
              .fill(baseColor)
              .frame(width: 54, height: 11)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(baseColor)
              .frame(height: 13)
            if index % 2 == 0 {
              RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(baseColor)
                .frame(height: 13)
            }
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(baseColor)
              .frame(width: 220, height: 13)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(18)
      .overlay(
        GeometryReader { geo in
          let w = geo.size.width
          LinearGradient(
            stops: [
              .init(color: .clear, location: 0.0),
              .init(color: shineColor.opacity(0.15), location: 0.25),
              .init(color: shineColor, location: 0.5),
              .init(color: shineColor.opacity(0.15), location: 0.75),
              .init(color: .clear, location: 1.0),
            ],
            startPoint: .leading,
            endPoint: .trailing
          )
          .frame(width: w * 0.7)
          .offset(x: phase * (w + w * 0.7))
        }
        .mask(
          VStack(alignment: .leading, spacing: 18) {
            ForEach(0..<5, id: \.self) { index in
              VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                  .fill(Color.black)
                  .frame(width: 54, height: 11)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                  .fill(Color.black)
                  .frame(height: 13)
                if index % 2 == 0 {
                  RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.black)
                    .frame(height: 13)
                }
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                  .fill(Color.black)
                  .frame(width: 220, height: 13)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        )
      )
    }
    .allowsHitTesting(false)
    .onAppear {
      phase = -1.0
      withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) {
        phase = 1.0
      }
    }
    .transition(.opacity)
  }
}

// Inline history list, designed to be PUSHED into the profile's own
// NavigationStack rather than presented as a sheet. Selecting a topic pushes the
// dedicated agent runtime surface instead of injecting rows into the default chat.
struct AgentBridgeHistoryInlineView: View {
  let provider: String
  let chatId: String
  var runningTasks: [AgentBridgeRunningTask] = []
  var deviceLabel: String = ""
  var connected: Bool = false
  var paired: Bool = false
  let onOpenSession: (AgentBridgeHistorySession) -> Void

  @Environment(\.colorScheme) private var colorScheme

  @State private var sessions: [AgentBridgeHistorySession] = []
  @State private var loading = true
  @State private var errorMessage: String?
  @State private var pendingRequestId: String?
  /// Connection notifications and SwiftUI lifecycle updates can arrive together when
  /// History opens. Keep one list request active so they do not fan out into dozens of
  /// identical bridge reads before the first reply settles the view.
  @State private var listRequestInFlight = false
  @State private var lastListRequestAt: Date?
  
  @State private var requestStartAt: Date?
  @State private var hasReceivedResponse = false
  /// How many times the history push was refused because the transport/bridge topic
  /// wasn't ready yet (cold launch). We keep the skeleton and retry a few times rather
  /// than immediately flashing a "not connected" state — the fix for "reopen History
  /// several times before it loads." Reset on a successful reply and on each fresh open.
  @State private var notReadyRetries = 0
  private static let maxNotReadyRetries = 6

  /// Pre-state: read from AgentPairingService snapshot before the panel opens
  /// so we never flash a stale disconnected state on first open.
  @State private var resolvedConnected: Bool = false
  @State private var resolvedDeviceLabel: String = ""
  @State private var hasConnectedBefore: Bool = false
  /// Retry timer for race-condition recovery (connection arrives after panel open).
  @State private var retryTask: Task<Void, Never>?

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }
  private var displayName: String { AgentBridgeProfile.displayName(for: provider) }
  private var visibleSessions: [AgentBridgeHistorySession] { mergedSessions() }
  private var projectGroups: [AgentBridgeHistoryProjectGroup] {
    var groups: [AgentBridgeHistoryProjectGroup] = []
    var indexByKey: [String: Int] = [:]
    for session in visibleSessions {
      let key = session.projectKey
      if let index = indexByKey[key] {
        var existing = groups[index]
        existing = AgentBridgeHistoryProjectGroup(
          id: existing.id,
          name: existing.name,
          sessions: existing.sessions + [session]
        )
        groups[index] = existing
      } else {
        indexByKey[key] = groups.count
        groups.append(AgentBridgeHistoryProjectGroup(
          id: key,
          name: session.displayProjectName,
          sessions: [session]
        ))
      }
    }
    return groups
  }

  /// The effective connection state: true if either the passed-in prop OR the
  /// pre-state snapshot says connected. This closes the race window.
  private var effectiveConnected: Bool { connected || resolvedConnected }
  /// True while we genuinely don't KNOW the connection state yet — a cold launch where no
  /// status has ever been fetched, or we're still retrying because the transport hasn't
  /// come up. Drives a spinner instead of a hard red "offline" dot, so the panel never
  /// asserts "not connected" before it has actually checked.
  private var isCheckingConnection: Bool {
    if AgentPairingService.lastStatusFetchedAt == nil { return true }
    return (loading && !hasReceivedResponse) || notReadyRetries > 0
  }
  private var effectiveDeviceLabel: String {
    let passed = deviceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    return passed.isEmpty ? resolvedDeviceLabel : passed
  }

  var body: some View {
    Group {
      // Do not expose a lone synthetic running-task row while the real history
      // list is still loading. That caused the visible one-row → full-list jump.
      if sessions.isEmpty && (loading || isCheckingConnection) {
        AgentBridgeHistoryListSkeleton()
      } else if visibleSessions.isEmpty {
        // Empty state (only after we've actually checked — see isCheckingConnection)
        VStack(spacing: 12) {
          Spacer()
          Image(systemName: "clock.badge.exclamationmark")
            .font(.system(size: 40))
            .foregroundStyle(palette.secondaryText.opacity(0.5))
          Text("No history found.")
            .font(.system(size: 15))
            .foregroundStyle(palette.secondaryText)
          Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List {
          ForEach(projectGroups) { group in
            Section {
              ForEach(group.sessions) { session in
                sessionRow(session)
                  .listRowBackground(Color.clear)
              }
            } header: {
              projectHeader(group)
                .listRowBackground(Color.clear)
            }
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
      }
    }
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        VStack(spacing: 2) {
          Text("\(displayName) history")
            .font(.headline)
            .foregroundStyle(palette.text)

          HStack(spacing: 5) {
            if effectiveConnected {
              // Green dot + device name
              Circle().fill(Color.green).frame(width: 7, height: 7)
              if !effectiveDeviceLabel.isEmpty {
                Text(effectiveDeviceLabel)
                  .font(.system(size: 11, weight: .medium))
                  .foregroundStyle(palette.secondaryText)
                  .lineLimit(1)
              }
            } else if paired || hasConnectedBefore || isCheckingConnection {
              // Spinner + device name (connecting / recovering / first-check on cold open)
              ProgressView().controlSize(.mini)
              if !effectiveDeviceLabel.isEmpty {
                Text(effectiveDeviceLabel)
                  .font(.system(size: 11, weight: .medium))
                  .foregroundStyle(palette.secondaryText)
                  .lineLimit(1)
              }
            } else {
              // Red dot + device name (or empty)
              Circle().fill(Color.red).frame(width: 7, height: 7)
              if !effectiveDeviceLabel.isEmpty {
                Text(effectiveDeviceLabel)
                  .font(.system(size: 11, weight: .medium))
                  .foregroundStyle(palette.secondaryText)
                  .lineLimit(1)
              }
            }
          }
          .animation(.easeInOut(duration: 0.25), value: effectiveConnected)
          .animation(.easeInOut(duration: 0.25), value: effectiveDeviceLabel)
        }
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: ChatEngine.didChangeNotification)) { note in
      handle(note)
    }
    .onChange(of: connected) { newValue in
      if newValue {
        hasConnectedBefore = true
        resolvedConnected = true
        // Connection just came in — if we had an error or empty state, retry.
        if sessions.isEmpty || errorMessage != nil {
          requestList()
        }
      }
    }
    .onAppear {
      preStateCheckup()
      seedThenRefresh()
      startRaceConditionRecovery()
    }
    .onDisappear {
      retryTask?.cancel()
      retryTask = nil
    }
  }

  // MARK: - Pre-state checkup

  /// Read the cached snapshot from AgentPairingService BEFORE relying on the
  /// passed-in `connected` prop, which may still be false during the first
  /// render if the status poll hasn't completed yet.
  private func preStateCheckup() {
    if let snapshot = AgentPairingService.lastStatusSnapshot {
      if snapshot.connected {
        resolvedConnected = true
        hasConnectedBefore = true
      }
      if resolvedDeviceLabel.isEmpty {
        resolvedDeviceLabel = snapshot.devices.first?.label ?? ""
      }
    }
    // Also check the lightweight statics
    if AgentPairingService.lastConnected {
      resolvedConnected = true
      hasConnectedBefore = true
    }
    if resolvedDeviceLabel.isEmpty, let lbl = AgentPairingService.lastDeviceLabel {
      resolvedDeviceLabel = lbl
    }
    // Mirror the prop
    if connected {
      resolvedConnected = true
      hasConnectedBefore = true
    }
  }

  // MARK: - Race condition recovery

  /// If the panel opened before the bridge status arrived, poll a few times
  /// in the background to catch a late connection and auto-reload.
  private func startRaceConditionRecovery() {
    guard !effectiveConnected else { return }
    retryTask?.cancel()
    retryTask = Task { @MainActor in
      // Try up to 5 times, 2 seconds apart
      for _ in 0..<5 {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !Task.isCancelled else { return }

        // Re-read the global snapshot
        if let snapshot = AgentPairingService.lastStatusSnapshot, snapshot.connected {
          resolvedConnected = true
          hasConnectedBefore = true
          if let lbl = snapshot.devices.first?.label, !lbl.isEmpty {
            resolvedDeviceLabel = lbl
          }
          requestList()
          return
        }
        if AgentPairingService.lastConnected {
          resolvedConnected = true
          hasConnectedBefore = true
          if let lbl = AgentPairingService.lastDeviceLabel, !lbl.isEmpty {
            resolvedDeviceLabel = lbl
          }
          requestList()
          return
        }
      }
    }
  }

  /// Re-opening the history must NOT flash the skeleton when we already have rows.
  /// Seed from the last payload the engine cached, then refresh quietly in place.
  private func seedThenRefresh() {
    if sessions.isEmpty,
      let payload = ChatEngine.shared.latestAgentBridgeHistoryList(
        chatId: chatId,
        provider: provider
      ),
      (payload["mode"] as? String ?? "list") == "list"
    {
      let cached = Self.sessionItems(from: payload["sessions"]).compactMap { Self.parseSession($0) }
      if !cached.isEmpty {
        sessions = cached
        loading = false
        print("[AgentBridgeHistory] ⚡️ Seeded \(sessions.count) sessions instantly from cache")
      }
    }
    notReadyRetries = 0
    requestList()
  }

  private func projectHeader(_ group: AgentBridgeHistoryProjectGroup) -> some View {
    HStack(spacing: 10) {
      Image(systemName: "folder")
        .font(.system(size: 16, weight: .semibold))
      Text(group.name)
        .font(.system(size: 20, weight: .bold))
      Spacer(minLength: 0)
    }
    .textCase(nil)
    .foregroundStyle(palette.text)
    .padding(.top, 14)
    .padding(.bottom, 6)
  }

  private func sessionRow(_ session: AgentBridgeHistorySession) -> some View {
    Button {
      onOpenSession(session)
    } label: {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 5) {
          HStack(spacing: 7) {
            if session.isRunning {
              ProgressView()
                .controlSize(.small)
                .tint(.green)
            }
            if let topic = visibleTopic(session.topic) {
              Text(topic)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(palette.text)
                .lineLimit(2)
            }
          }
          if let config = session.configurationLabel(provider: provider) {
            Text(config)
              .font(.system(size: 12.5, weight: .medium))
              .foregroundStyle(palette.secondaryText)
              .lineLimit(1)
              .accessibilityLabel("Session configuration: \(config)")
          }
          HStack(spacing: 6) {
            // A run blocked on an Approve/Deny (ask/command/plan) outranks the plain
            // subtitle — surface it so the user knows WHICH conversation is waiting.
            if session.pendingAskKind != nil {
              HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                  .font(.system(size: 11, weight: .semibold))
                Text("Waiting for approval")
                  .font(.system(size: 12, weight: .semibold))
              }
              .foregroundStyle(.orange)
              Text("·")
            }
            // The running state is shown by the spinner next to the title — keep the
            // subtitle to a plain message count + timestamp (no "Live" pill).
            Text("\(session.messageCount) messages")
            if let when = Self.relativeDate(session.updatedAt) {
              Text("·")
              Text(when)
            }
          }
          .font(.system(size: 12))
          .foregroundStyle(palette.secondaryText)
        }
        Spacer(minLength: 8)
        Image(systemName: "chevron.right")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(palette.secondaryText.opacity(0.7))
      }
      .padding(.vertical, 9)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  /// Hide transport/action copy that older payloads used as a synthetic title. It is
  /// not conversation history and should never become a visible fallback row label.
  private func visibleTopic(_ raw: String) -> String? {
    let topic = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !topic.isEmpty else { return nil }
    let normalized = topic.lowercased()
    if normalized == "load session in chat" || normalized == "load this session in chat" {
      return nil
    }
    return topic
  }

  private func requestList() {
    let now = Date()
    if listRequestInFlight {
      // A missing reply must still be recoverable; anything newer is the same load.
      if let started = requestStartAt, now.timeIntervalSince(started) < 8.0 {
        return
      }
      listRequestInFlight = false
    }
    // A few adjacent lifecycle callbacks can arrive after a reply. One short cooldown
    // keeps those callbacks from immediately issuing another identical list request.
    if let previous = lastListRequestAt, now.timeIntervalSince(previous) < 0.75 {
      return
    }
    listRequestInFlight = true
    lastListRequestAt = now

    // Only show the skeleton on a cold load. With rows already on screen (cached or a
    // prior fetch) we refresh silently so re-opening never flashes back to a spinner.
    if visibleSessions.isEmpty { loading = true }
    errorMessage = nil
    let reqId = UUID().uuidString
    let start = Date()
    requestStartAt = start
    hasReceivedResponse = false
    
    print("[AgentBridgeHistory] 🔄 Requesting history list, reqId: \(reqId) at \(start)")
    let result = ChatEngine.shared.requestAgentBridgeHistory([
      "chatId": chatId,
      "provider": provider,
      "mode": "list",
      "requestId": reqId
    ])
    if (result["accepted"] as? Bool) == true {
      pendingRequestId = reqId
      notReadyRetries = 0

      // Race condition recovery: if the WebSocket was still connecting when we pushed,
      // or the response was dropped, retry if we're still stuck in shimmer. The window
      // is deliberately wider than a cold read of a large ~/.claude/projects so we don't
      // mint a fresh requestId (and a duplicate bridge read) while a reply is in flight.
      DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
        if !self.hasReceivedResponse && self.requestStartAt == start {
          print("[AgentBridgeHistory] ⚠️ Timed out waiting for response! Retrying...")
          self.listRequestInFlight = false
          self.requestList()
        }
      }
    } else if notReadyRetries < Self.maxNotReadyRetries {
      // `requestAgentBridgeHistory` initiates the chat-topic join when needed.
      // Wait for the positive JOIN notification and retry immediately from there;
      // the delayed retry is only a fallback if that notification is lost.
      notReadyRetries += 1
      loading = sessions.isEmpty
      listRequestInFlight = false
      lastListRequestAt = nil
      let reason = (result["reason"] as? String) ?? "not_ready"
      print("[AgentBridgeHistory] ⏳ Waiting for chat topic join (attempt \(notReadyRetries), reason=\(reason))")
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        guard self.requestStartAt == start, !self.hasReceivedResponse else { return }
        self.requestList()
      }
    } else {
      listRequestInFlight = false
      loading = false
      errorMessage = "Your computer isn't connected right now. Connect it, then try again."
    }
  }

  private func handle(_ note: Notification) {
    let reason = (note.userInfo?["reason"] as? String) ?? ""
    // The chat topic just (re)joined, or the connection came up. A cold-launch socket flap
    // can exhaust our not-ready retries BEFORE a push can land — the panel then sits on the
    // skeleton or the "isn't connected" message until the user reopens it. Re-fire the list
    // now that the transport is usable. Guarded so it only rescues a STALLED load: skip while
    // a retry cycle is mid-flight (`loading`) so the connection flap can't spawn parallel
    // request chains, and skip once we already have a reply (`hasReceivedResponse`).
    if reason == "chatChannelStateChanged" {
      let changed = (note.userInfo?["chatId"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let mine = changed == nil || changed?.isEmpty == true || changed == chatId
      if mine, !hasReceivedResponse, !listRequestInFlight {
        // Older transports may still reject instead of queueing. In that fallback
        // case, a successful JOIN is the earliest safe moment to retry.
        notReadyRetries = 0
        lastListRequestAt = nil
        print("[AgentBridgeHistory] ⚡️ Chat topic joined — requesting list now")
        requestList()
      }
      return
    }
    if reason == "connectionStateChanged" {
      if !loading, errorMessage != nil || !hasReceivedResponse {
        notReadyRetries = 0
        requestList()
      }
      return
    }
    guard
      let info = note.userInfo,
      (info["reason"] as? String) == "agentBridgeHistory",
      let payload = ChatEngine.shared.latestAgentBridgeHistoryList(
        chatId: chatId,
        provider: provider
      )
    else { return }

    // A `detail` (transcript) reply is cached under the SAME chatId key, so the
    // mode — not the requestId — is what tells a list reply apart from a detail one.
    guard (payload["mode"] as? String ?? "list") == "list" else { return }

    // On a shared agent DM a sibling provider's list reply can land on this chat;
    // ignore anything that isn't for the provider this panel is showing.
    if let replyProvider = (payload["provider"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      !replyProvider.isEmpty,
      replyProvider != provider.lowercased()
    {
      return
    }

    // Intentionally do NOT require the reply's requestId to equal our latest
    // `pendingRequestId`. A cold history read on the bridge can take longer than the
    // retry interval, so the retry timer mints fresh requestIds while a response is
    // still in flight. Gating on an exact match rejected that valid, idempotent list
    // reply and left us retrying forever — the bug this fixes. Any list reply for
    // this chat+provider satisfies the load, so accept it regardless of requestId.
    if let pending = pendingRequestId,
      let rid = info["requestId"] as? String,
      rid != pending
    {
      print("[AgentBridgeHistory] ↩️ Accepting list reply for an earlier request (rid=\(rid) pending=\(pending))")
    }

    if let start = requestStartAt {
      let duration = Date().timeIntervalSince(start)
      print("[AgentBridgeHistory] ✅ Received list response in \(String(format: "%.2f", duration))s")
    }

    hasReceivedResponse = true
    loading = false
    notReadyRetries = 0
    listRequestInFlight = false
    pendingRequestId = nil
    let raw = Self.sessionItems(from: payload["sessions"])
    sessions = raw.compactMap { item in
      Self.parseSession(item)
    }
    let rowSummary = sessions.prefix(3).map { session in
      "\(session.id.prefix(8)){count=\(session.messageCount),live=\(session.isRunning ? "Y" : "N"),title=\(session.topic.prefix(48))}"
    }.joined(separator: " | ")
    let taskSummary = runningTasks
      .filter { task in
        let taskProvider = task.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let providerMatches = taskProvider.isEmpty || taskProvider == provider.lowercased()
        let chatMatches = task.chatId.isEmpty || chatId.isEmpty || task.chatId == chatId
        return providerMatches && chatMatches
      }
      .map { task in
        let sessionId = task.sessionId?.isEmpty == false ? task.sessionId! : "-"
        let matched = sessions.contains(where: { $0.id == sessionId })
        return "\(task.taskId.prefix(12)){session=\(sessionId.prefix(8)),matched=\(matched ? "Y" : "N"),title=\(task.topic.prefix(48))}"
      }
      .joined(separator: " | ")
    print(
      "[AgentBridgeHistory] 📋 Parsed rows=\(sessions.count) tasks=\(runningTasks.count) " +
        "top=[\(rowSummary)] taskLinks=[\(taskSummary)]"
    )
    if sessions.isEmpty && (payload["ok"] as? Bool) == false {
      errorMessage = (payload["error"] as? String) ?? "Couldn't read history from your computer."
    }
  }

  private func mergedSessions() -> [AgentBridgeHistorySession] {
    let listedById = Dictionary(
      sessions.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    func firstText(_ values: String?...) -> String {
      for value in values {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty { return text }
      }
      return ""
    }
    let running = runningTasks.compactMap { task -> AgentBridgeHistorySession? in
      let normalizedProvider = task.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if !normalizedProvider.isEmpty && normalizedProvider != provider.lowercased() { return nil }
      if !task.chatId.isEmpty && !chatId.isEmpty && task.chatId != chatId { return nil }
      let id = task.sessionId?.isEmpty == false ? task.sessionId! : "running:\(task.taskId)"
      let listed = listedById[id]
      // Live task model/effort wins when present; otherwise keep archived metadata.
      let mergedModel = firstText(task.model, listed?.model)
      let mergedEffort = firstText(task.effectiveReasoningEffort, listed?.reasoningEffort)
      return AgentBridgeHistorySession(
        id: id,
        // A matching history row is the conversation source of truth: it carries
        // the original user-derived title and parsed message count. The running
        // status overlay should add live metadata, never replace those fields with
        // a transient progress label and zero messages.
        topic: firstText(listed?.topic, task.topic, "Running task"),
        projectName: firstText(
          listed?.projectName,
          task.projectName,
          task.repoName
        ),
        projectPath: firstText(
          listed?.projectPath,
          task.project,
          task.cwd
        ),
        updatedAt: firstText(task.startedAt, listed?.updatedAt),
        // Even before the rollout file is visible, a running task already has its
        // originating user prompt. Never paint the misleading "0 messages" state.
        messageCount: max(1, listed?.messageCount ?? 0),
        isRunning: true,
        taskId: task.taskId,
        sessionId: task.sessionId,
        model: mergedModel.isEmpty ? nil : mergedModel,
        reasoningEffort: mergedEffort.isEmpty ? nil : mergedEffort,
        pendingAskKind: listed?.pendingAskKind
      )
    }
    // A running-task entry shadows its badged list twin (dedup below keeps the running
    // one) — carry the pending-approval badge over so it isn't lost in the merge.
    let pendingKindById = Dictionary(
      sessions.compactMap { s in s.pendingAskKind.map { (s.id, $0) } },
      uniquingKeysWith: { first, _ in first }
    )
    let badgedRunning = running.map { entry -> AgentBridgeHistorySession in
      guard entry.pendingAskKind == nil, let kind = pendingKindById[entry.id] else { return entry }
      var badged = entry
      badged.pendingAskKind = kind
      return badged
    }
    var seen = Set(badgedRunning.map(\.id))
    return badgedRunning + sessions.filter { session in
      if seen.contains(session.id) { return false }
      seen.insert(session.id)
      return true
    }
  }

  static func parseSession(_ item: [String: Any]) -> AgentBridgeHistorySession? {
    guard let id = (item["id"] as? String), !id.isEmpty else { return nil }
    let projectPath =
      (item["project"] as? String)
      ?? (item["projectPath"] as? String)
      ?? (item["cwd"] as? String)
      ?? ""
    // The bridge marks a session `live` when its transcript file is actively
    // growing (a turn is in flight) — including chats started directly in the
    // desktop's own terminal, which never enter the bridge's runningTasks list.
    // Honor either key so older bridges (no `live`) still parse.
    let live = (item["live"] as? Bool) ?? (item["isRunning"] as? Bool) ?? false
    let model = Self.nonEmptyString(item["model"])
    let reasoningEffort = Self.nonEmptyString(
      item["reasoningEffort"]
        ?? item["reasoning_effort"]
        ?? item["agentBridgeReasoningEffort"]
    )
    return AgentBridgeHistorySession(
      id: id,
      topic: (item["topic"] as? String) ?? "Untitled",
      projectName: (item["projectName"] as? String) ?? "",
      projectPath: projectPath,
      updatedAt: (item["updatedAt"] as? String) ?? "",
      messageCount: (item["messageCount"] as? NSNumber)?.intValue ?? (item["messageCount"] as? Int) ?? 0,
      isRunning: live,
      taskId: nil,
      sessionId: id,
      model: model,
      reasoningEffort: reasoningEffort,
      pendingAskKind: {
        let kind = ((item["pendingAskKind"] as? String) ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return kind.isEmpty ? nil : kind
      }()
    )
  }

  private static func nonEmptyString(_ value: Any?) -> String? {
    if let text = value as? String {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let number = value as? NSNumber {
      let text = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? nil : text
    }
    return nil
  }

  /// `JSONSerialization` normally bridges a nested list directly to
  /// `[[String: Any]]`, but Foundation can surface Phoenix payload arrays as
  /// `[Any]`/`NSDictionary` on a physical device. Normalize both shapes before
  /// parsing so a valid bridge reply never leaves the History sheet on its skeleton.
  static func sessionItems(from raw: Any?) -> [[String: Any]] {
    if let sessions = raw as? [[String: Any]] { return sessions }
    guard let values = raw as? [Any] else { return [] }
    return values.compactMap { value in
      if let session = value as? [String: Any] { return session }
      guard let dictionary = value as? NSDictionary else { return nil }
      var session: [String: Any] = [:]
      for (key, value) in dictionary {
        guard let key = key as? String else { continue }
        session[key] = value
      }
      return session.isEmpty ? nil : session
    }
  }

  static func relativeDate(_ iso: String) -> String? {
    let trimmed = iso.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = formatter.date(from: trimmed)
      ?? ISO8601DateFormatter().date(from: trimmed)
    guard let date else { return nil }
    let rel = RelativeDateTimeFormatter()
    rel.unitsStyle = .abbreviated
    return rel.localizedString(for: date, relativeTo: Date())
  }
}

struct AgentBridgeRuntimeView: UIViewControllerRepresentable {
  let provider: String
  let chatId: String
  let session: AgentBridgeHistorySession
  let subtitle: String
  var newChatTrigger: Binding<Bool>? = nil

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeUIViewController(context: Context) -> VibeAgentConversationViewController {
    // Capture value-type context so the live closures don't retain SwiftUI state.
    let chatId = chatId
    let provider = provider
    let sessionId = session.resolvedSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
    let coordinator = context.coordinator

    let controller = VibeAgentConversationViewController(
      title: session.topic,
      subtitle: subtitle,
      messages: context.coordinator.seedMessages(),
      inputPlaceholder: "Ask \(AgentBridgeProfile.displayName(for: provider))",
      // Render this session's rows. Every session ingests into the same DM chatId
      // (keyed `bridge-<sessionId>-…`), so reading the chat unfiltered would show the
      // default-DM history identically for every session. We isolate to the ingested
      // transcript for this session id, PLUS — once the user sends a follow-up from
      // this view — that follow-up and its resumed reply (the live `agent-stream`
      // bubble and the final message, linked back by source id). Without that, a
      // resume landed in the shared DM with a non-`bridge-` id and was filtered out,
      // so the view looked empty/stuck. We still never pull in another session's
      // ingested history (also `bridge-`prefixed) or the DM's unrelated rows. If the
      // transcript hasn't arrived yet we fall back to live streaming rows so a
      // running task isn't blank. The controller's live observer re-reads this on
      // every engine change.
      messagesProvider: { [weak coordinator] in
        let prefix = "bridge-\(sessionId)-"
        let all = ChatEngine.shared
          .getChatRows(["chatId": chatId])
          .compactMap { ChatListRow(raw: $0) }
        // "New chat" mode: ignore this session's ingested transcript entirely and
        // show only the fresh (non-resumed) turns started from the button onward.
        if coordinator?.forceFreshSession == true {
          let fresh = coordinator?.freshSendIds ?? []
          guard !fresh.isEmpty else { return [] }
          let keep = all.filter { row in
            let mid = row.messageId ?? ""
            if fresh.contains(mid) { return true }
            if let src = row.agentActionSourceId, fresh.contains(src) { return true }
            return false
          }
          return coordinator?.renderMessages(from: keep) ?? VibeAgentKitMap.messages(from: keep)
        }
        // Follow-ups that resume THIS session: identified durably by the resume
        // session id their send stamped into metadata (so a follow-up sent from
        // ANOTHER device folds in too), plus any this device sent locally. Their
        // replies (live stream + final message) link back by source id.
        var followUps = coordinator?.followUpMessageIds ?? []
        for row in all where row.agentBridgeResumeSessionId == sessionId {
          if let mid = row.messageId { followUps.insert(mid) }
        }
        let keep = all.filter { row in
          let mid = row.messageId ?? ""
          if mid.hasPrefix(prefix) { return true }
          guard !followUps.isEmpty else { return false }
          if mid.hasPrefix("bridge-") { return false }
          if followUps.contains(mid) { return true }
          if let src = row.agentActionSourceId, followUps.contains(src) { return true }
          if row.isStreamingText { return true }
          return false
        }
        if !keep.isEmpty {
          return coordinator?.renderMessages(from: keep) ?? VibeAgentKitMap.messages(from: keep)
        }
        let liveRows = all.filter { $0.isStreamingText }
        return coordinator?.renderMessages(from: liveRows) ?? VibeAgentKitMap.messages(from: liveRows)
      },
      // Send continues THIS session on the user's computer and streams back in place.
      onSend: { [weak coordinator] text, options, attachments in
        coordinator?.sendFollowUp(text, options: options, attachments: attachments)
      }
    )
    controller.agentBridgeChatId = chatId
    controller.agentBridgeProvider = provider
    controller.runModel = session.model
    controller.runReasoningEffort = session.reasoningEffort
    controller.avatarTitle = AgentBridgeProfile.displayName(for: provider)
    controller.avatarChatId = chatId
    controller.onNewChat = { [weak coordinator] in coordinator?.startNewChat() }
    // Editing a message reverts its turn's files (handled in the controller) and then
    // re-runs the revised prompt as a fresh task from that reverted state.
    controller.onEditMessage = { [weak coordinator] _ in coordinator?.startNewChat() }
    controller.isEmbeddedInSwiftUI = true
    context.coordinator.controller = controller
    // Show the centered spinner until the session's transcript / live stream lands.
    controller.isLoadingTranscript = true
    context.coordinator.start()
    return controller
  }

  func updateUIViewController(_ controller: VibeAgentConversationViewController, context: Context) {
    context.coordinator.parent = self
    context.coordinator.controller = controller
    if let trigger = newChatTrigger, trigger.wrappedValue {
      DispatchQueue.main.async {
        trigger.wrappedValue = false
        controller.onNewChat?()
      }
    }
  }

  /// Dispatch a message to the agent on the user's computer over the live chat
  /// channel. The server detects the bridge-agent DM and routes to the daemon; the
  /// reply streams back as `agent-stream` / `message` frames that ChatEngine folds
  /// into this chat's rows (rendered via `messagesProvider`).
  static func sendToAgent(
    chatId: String,
    provider: String,
    resumeSessionId: String,
    text: String,
    messageId: String = UUID().uuidString.lowercased(),
    options: AgentBridgeRunOptions? = nil,
    attachments: [String] = []
  ) -> [String: Any] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // An image-only send carries no caption; give the agent (and the bubble) a
    // sensible default so the prompt isn't empty and the row isn't filtered out.
    let body =
      !trimmed.isEmpty
      ? trimmed : (attachments.isEmpty ? "" : "Please take a look at the attached image.")
    guard !body.isEmpty else { return ["accepted": false, "reason": "empty_text"] }
    var metadata: [String: Any] = ["agentBridgeProvider": provider]
    if let repo = AgentBridgeSelectionStore.selectedRepository() {
      metadata["agentBridgeRepoId"] = repo.id
      metadata["agentBridgeRepoName"] = repo.name
      metadata["agentBridgeRepoPath"] = repo.path
      metadata["agentBridgeCwd"] = repo.cwd
      if let computerId = repo.computerId, !computerId.isEmpty {
        metadata["agentBridgeComputerId"] = computerId
      }
      if let computerLabel = repo.computerLabel, !computerLabel.isEmpty {
        metadata["agentBridgeComputerLabel"] = computerLabel
      }
    }
    metadata["agentBridgeWorkMode"] = AgentBridgeSelectionStore.selectedWorkMode().rawValue
    metadata.merge(
      (options ?? AgentBridgeSelectionStore.selectedRunOptions(provider: provider)).payload(provider: provider)
    ) { _, new in new }
    // Sealed image blobs (arte1) the daemon decrypts + writes for the agent to read.
    // The server only ever relays these opaque strings.
    if !attachments.isEmpty {
      metadata["agentBridgeAttachmentsEnc"] = attachments
    }
    // Explicit resume so the message continues the session you opened rather than
    // starting a fresh task (per the resume contract).
    if !resumeSessionId.isEmpty, !resumeSessionId.hasPrefix("running:") {
      metadata["agentBridgeResumeSessionId"] = resumeSessionId
    }
    return ChatEngine.shared.sendMessage([
      "chatId": chatId,
      "type": "text",
      "text": body,
      "messageId": messageId,
      "metadata": metadata,
    ])
  }

  final class Coordinator {
    var parent: AgentBridgeRuntimeView
    weak var controller: VibeAgentConversationViewController?
    private var didOpenChannel = false

    /// Message ids of follow-ups the user sent from THIS view. The live
    /// `messagesProvider` uses these to fold the resumed turn (the follow-up bubble
    /// plus its streaming + final reply, joined by source id) into the rendered
    /// transcript — otherwise a resume lands in the shared DM with a non-`bridge-`
    /// id and gets filtered out, leaving the view looking empty.
    var followUpMessageIds: Set<String> = []

    /// Set once the user taps "new chat": the transcript view is cleared and every
    /// subsequent send starts a brand-new (non-resumed) task instead of continuing
    /// this session. `freshSendIds` scopes the provider to just those new turns.
    var forceFreshSession = false
    var freshSendIds: Set<String> = []
    private var localMessagesById: [String: VibeAgentKitChatMessage] = [:]
    private var localMessageOrder: [String] = []
    private var localWorkingMessageIdBySourceId: [String: String] = [:]

    init(parent: AgentBridgeRuntimeView) {
      self.parent = parent
    }

    /// Begin a fresh conversation: clear what's on screen and flip into fresh-session
    /// mode so the next send opens a new task rather than resuming this one.
    func startNewChat() {
      forceFreshSession = true
      followUpMessageIds.removeAll()
      freshSendIds.removeAll()
      localMessagesById.removeAll()
      localMessageOrder.removeAll()
      localWorkingMessageIdBySourceId.removeAll()
      // A fresh chat is intentionally blank — no spinner, just the empty composer.
      controller?.isLoadingTranscript = false
      controller?.setMessages([])
    }

    func renderMessages(from rows: [ChatListRow]) -> [VibeAgentKitChatMessage] {
      let resolvedSources = Set(rows.compactMap { row -> String? in
        guard row.isAgentMessage || row.isStreamingText else { return nil }
        guard let sourceId = row.agentActionSourceId?.trimmingCharacters(in: .whitespacesAndNewlines),
          !sourceId.isEmpty
        else { return nil }
        return localWorkingMessageIdBySourceId[sourceId] == nil ? nil : sourceId
      })
      for sourceId in resolvedSources {
        if let workingId = localWorkingMessageIdBySourceId.removeValue(forKey: sourceId) {
          localMessagesById.removeValue(forKey: workingId)
          localMessageOrder.removeAll { $0 == workingId }
        }
      }
      let mapped = VibeAgentKitMap.messages(from: rows)
      let mappedIds = Set(mapped.map(\.id))
      let local = localMessageOrder.compactMap { id -> VibeAgentKitChatMessage? in
        guard !mappedIds.contains(id) else { return nil }
        return localMessagesById[id]
      }
      return mapped + local
    }

    private func upsertLocalMessage(_ message: VibeAgentKitChatMessage) {
      localMessagesById[message.id] = message
      if !localMessageOrder.contains(message.id) {
        localMessageOrder.append(message.id)
      }
      controller?.isLoadingTranscript = false
      controller?.reloadLiveMessages()
    }

    private func appendLocalSend(
      messageId: String,
      body: String
    ) {
      let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
      upsertLocalMessage(
        VibeAgentKitChatMessage(
          id: messageId,
          role: .user,
          text: body,
          timestamp: "",
          timestampMs: nowMs
        )
      )
      let workingId = "local-working-\(messageId)"
      localWorkingMessageIdBySourceId[messageId] = workingId
      upsertLocalMessage(
        VibeAgentKitChatMessage(
          id: workingId,
          role: .assistant,
          text: "",
          timestamp: "",
          timestampMs: nowMs + 1,
          isStreaming: true
        )
      )
    }

    private func appendLocalSendFailure(messageId: String, result: [String: Any]) {
      let reason = (result["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      let detail = reason?.isEmpty == false ? reason! : "send_failed"
      upsertLocalMessage(
        VibeAgentKitChatMessage(
          id: "send-error-\(messageId)",
          role: .assistant,
          text: "Message was not delivered to your computer. Reason: \(detail). Reconnect the bridge and send it again.",
          timestamp: "",
          timestampMs: Int64(Date().timeIntervalSince1970 * 1000),
          isError: true
        )
      )
    }

    /// Send a follow-up that resumes this session and surface it inline. We mint the
    /// id up front so we can register it before dispatch; the engine's optimistic
    /// insert + the streamed/final reply then render through `messagesProvider`.
    func sendFollowUp(_ text: String, options: AgentBridgeRunOptions, attachments: [String] = []) {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      // Allow an image-only send (no caption) as long as something is attached.
      guard !trimmed.isEmpty || !attachments.isEmpty else { return }
      let messageId = UUID().uuidString.lowercased()
      // Fresh-chat sends start a new task (no resume id); normal sends resume this
      // session. Track the id in the matching set so the provider renders it.
      let resumeSessionId =
        forceFreshSession
        ? ""
        : parent.session.resolvedSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
      if forceFreshSession {
        freshSendIds.insert(messageId)
      } else {
        followUpMessageIds.insert(messageId)
      }
      let body = trimmed.isEmpty && !attachments.isEmpty
        ? "Please take a look at the attached image."
        : trimmed
      appendLocalSend(messageId: messageId, body: body)
      let result = AgentBridgeRuntimeView.sendToAgent(
        chatId: parent.chatId,
        provider: parent.provider,
        resumeSessionId: resumeSessionId,
        text: trimmed,
        messageId: messageId,
        options: options,
        attachments: attachments
      )
      if (result["accepted"] as? Bool) != true {
        appendLocalSendFailure(messageId: messageId, result: result)
      } else {
        controller?.reloadLiveMessages()
      }
    }

    deinit {
      if didOpenChannel {
        _ = ChatEngine.shared.closeChatChannel(["chatId": parent.chatId])
      }
    }

    func seedMessages() -> [VibeAgentKitChatMessage] {
      // Start empty: the controller shows a centered spinner while the transcript (or
      // the live stream, for a running task) loads — no placeholder "Loading…" bubble.
      []
    }

    /// Join the chat channel (so live frames arrive) and ingest the selected local
    /// session into the chat as rows. From here the controller's own live observer
    /// re-reads `messagesProvider` on every engine change, so seeded history, live
    /// `agent-stream` deltas, and final `message`s all render through one path —
    /// no close-and-reload. The ingest carries each message's E2E `agentRuntimeEnc`
    /// so the file-change cards survive (decrypted by ChatListRow with the phone key).
    func start() {
      _ = ChatEngine.shared.openChatChannel(["chatId": parent.chatId])
      didOpenChannel = true

      let sessionId = parent.session.resolvedSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !sessionId.isEmpty, !sessionId.hasPrefix("running:") else { return }

      let result = ChatEngine.shared.loadAgentBridgeSessionIntoChat([
        "chatId": parent.chatId,
        "provider": parent.provider,
        "sessionId": sessionId,
      ])
      if (result["accepted"] as? Bool) != true {
        controller?.setMessages([
          VibeAgentKitChatMessage(
            id: "offline",
            role: .assistant,
            text: "Your computer is not connected right now.",
            timestamp: "",
            timestampMs: 0,
            isError: true
          )
        ])
      }
    }
  }
}

/// Full-screen sheet wrapper for `AgentBridgeHistoryInlineView`, presented from the
/// chat's History menu (it "slides" up over the chat). Picking a session dismisses and
/// hands it back so the chat loads it into the default view (not the agent view).
struct AgentBridgeHistorySheet: View {
  let provider: String
  let chatId: String
  var runningTasks: [AgentBridgeRunningTask] = []
  var deviceLabel: String = ""
  var connected: Bool = false
  var paired: Bool = false
  let onPick: (AgentBridgeHistorySession) -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    NavigationStack {
      AgentBridgeHistoryInlineView(
        provider: provider,
        chatId: chatId,
        runningTasks: runningTasks,
        deviceLabel: deviceLabel,
        connected: connected,
        paired: paired,
        onOpenSession: { session in
          dismiss()
          onPick(session)
        }
      )
      .background(colorScheme == .dark ? Color.black : Color.white)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(action: { dismiss() }) {
            Image(systemName: "xmark")
              .font(.system(size: 18, weight: .semibold))
              .foregroundStyle(colorScheme == .dark ? Color.white : Color.black)
          }
        }
      }
    }
    .background(colorScheme == .dark ? Color.black : Color.white)
    .presentationBackground(colorScheme == .dark ? Color.black : Color.white)
    .presentationDetents([.medium, .large])
  }
}

struct AgentBridgeTranscriptView: View {
  let provider: String
  let chatId: String
  let sessionId: String
  let topic: String

  @Environment(\.colorScheme) private var colorScheme

  @State private var messages: [AgentBridgeTranscriptMessage] = []
  @State private var loading = true
  @State private var errorMessage: String?
  @State private var pendingRequestId: String?

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }
  private var displayName: String { AgentBridgeProfile.displayName(for: provider) }

  var body: some View {
    Group {
      if loading && messages.isEmpty {
        AgentBridgeTranscriptSkeleton()
      } else if messages.isEmpty {
        Text(errorMessage ?? "This conversation is empty.")
          .font(.system(size: 14))
          .foregroundStyle(palette.secondaryText)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            ForEach(messages) { message in
              VStack(alignment: .leading, spacing: 5) {
                Text(label(for: message.role))
                  .font(.system(size: 12, weight: .bold))
                  .foregroundStyle(color(for: message.role))
                  .textCase(.uppercase)
                if message.text.hasPrefix("```diff") || message.text.contains("diff --git") {
                  SwiftUIDiffView(text: message.text.replacingOccurrences(of: "```diff\n", with: "").replacingOccurrences(of: "```", with: ""))
                } else {
                  Text(message.text)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          .padding(18)
        }
      }
    }
    .navigationTitle(topic)
    .navigationBarTitleDisplayMode(.inline)
    .onReceive(NotificationCenter.default.publisher(for: ChatEngine.didChangeNotification)) { note in
      handle(note)
    }
    .onAppear { requestDetail() }
  }

  private func label(for role: String) -> String {
    switch role.lowercased() {
    case "user": return "You"
    case "assistant": return displayName
    case "developer", "system": return "System"
    default: return role
    }
  }

  private func color(for role: String) -> Color {
    role.lowercased() == "user" ? palette.secondaryText : palette.accent
  }

  private func requestDetail() {
    loading = true
    errorMessage = nil
    let result = ChatEngine.shared.requestAgentBridgeHistory([
      "chatId": chatId,
      "provider": provider,
      "mode": "detail",
      "sessionId": sessionId,
    ])
    if (result["accepted"] as? Bool) == true {
      pendingRequestId = result["requestId"] as? String
    } else {
      loading = false
      errorMessage = "Your computer isn't connected right now."
    }
  }

  private func handle(_ note: Notification) {
    guard
      let info = note.userInfo,
      (info["reason"] as? String) == "agentBridgeHistory",
      let payload = ChatEngine.shared.latestAgentBridgeHistory(chatId: chatId)
    else { return }

    if let pending = pendingRequestId, let rid = info["requestId"] as? String, rid != pending {
      return
    }
    guard (payload["mode"] as? String) == "detail" else { return }
    guard let session = payload["session"] as? [String: Any] else { return }
    // Make sure this detail is for the session we opened.
    if let sid = session["id"] as? String, sid != sessionId { return }

    loading = false
    let raw = session["messages"] as? [[String: Any]] ?? []
    messages = raw.compactMap { item in
      let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !text.isEmpty else { return nil }
      return AgentBridgeTranscriptMessage(role: (item["role"] as? String) ?? "", text: text)
    }
    if messages.isEmpty {
      errorMessage = "This conversation has no readable messages."
    }
  }
}

struct SwiftUIDiffView: View {
  let text: String
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let lines = text.components(separatedBy: .newlines)
    let isDark = colorScheme == .dark

    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
        if line.hasPrefix("+") && !line.hasPrefix("+++") {
          Text(line)
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(VibeAgentDiffPalette.additionBackground(isDark: isDark)))
            .fixedSize(horizontal: false, vertical: true)
        } else if line.hasPrefix("-") && !line.hasPrefix("---") {
          Text(line)
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(VibeAgentDiffPalette.deletionBackground(isDark: isDark)))
            .fixedSize(horizontal: false, vertical: true)
        } else if line.hasPrefix("@@") {
          Text(line)
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.gray.opacity(0.3))
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text(line)
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(isDark ? .white : .black)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .background(Color(UIColor.secondarySystemBackground))
    .cornerRadius(8)
    .clipShape(RoundedRectangle(cornerRadius: 8))
  }
}
