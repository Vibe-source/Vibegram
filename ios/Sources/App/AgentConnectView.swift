import AVFoundation
import SwiftUI
import UIKit

enum AgentQRScannerStatusStyle: Equatable {
  case idle
  case progress
  case success
  case error
}

/// Drives the "connect your computer" flow shown inside a Claude/Codex/Grok chat while
/// no paired computer is online. The desktop daemon shows a QR; the phone scans it
/// and authorizes the pairing, then waits for the computer to come online.
@MainActor
final class AgentConnectModel: ObservableObject {
  /// `"claude"` / `"codex"` / `"grok"`.
  let provider: String
  /// Display name shown in copy ("Claude" / "Codex" / "Grok").
  let displayName: String

  @Published var status: AgentBridgeStatus = .disconnected
  @Published var isScanning = false
  @Published var isAuthorizing = false
  @Published var didAuthorize = false
  @Published var errorMessage: String?
  @Published var scannerMessage: String?
  @Published var scannerStatusStyle: AgentQRScannerStatusStyle = .idle
  @Published var scannerCanRetry = false
  @Published var scannerResetToken = 0
  @Published var selectedRepository: AgentBridgeRepository?

  /// Invoked once a computer comes online so the host can reveal the input bar.
  var onConnected: (() -> Void)?

  private var pollTask: Task<Void, Never>?
  /// Live `bridge-status` pushes off the socket — the primary signal; the timer below
  /// is only a fallback.
  private var statusObserver: NSObjectProtocol?
  /// Fallback cadence for a wedged socket. Deliberately slow: the push arrives in
  /// milliseconds, so this only has to catch a transport that has stopped delivering.
  private static let statusFallbackInterval: TimeInterval = 20
  /// Guards the one-shot "Connected ✓ → auto-close" transition so a repeated status
  /// can't re-schedule it, and lets us time a soft "computer still offline" hint.
  private var didConfirmConnected = false
  private var authorizedAt: Date?

  init(provider: String, displayName: String) {
    self.provider = provider
    self.displayName = displayName
  }

  func onAppear() {
    startPolling()
  }

  func onDisappear() {
    stopPolling()
  }

  /// Watches bridge status while the panel is up, so it flips to "connected" the
  /// moment the daemon claims its token and joins.
  ///
  /// This used to be a 2.5s `while` loop hitting `/api/agent-bridge/status`, which
  /// never stopped while the model was alive — in production it was a permanent
  /// wall of requests, one every ~3s for the whole foreground session, and each one
  /// cost real server time. The server now pushes `bridge-status` over the socket
  /// the phone is already joined to, which is both free and *faster* than polling:
  /// the push fires on the Presence change itself rather than up to 2.5s later.
  ///
  /// The timer that remains is only a safety net for a wedged socket, at a cadence
  /// where it costs nothing, and it goes through `statusCoalesced` so overlapping
  /// surfaces share one round trip.
  func startPolling() {
    observeStatusPushes()
    guard pollTask == nil else { return }
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        // Trust a fresh snapshot (socket push or another surface's fetch) and skip
        // the request entirely; only reach for the network when nothing is current.
        if !AgentPairingService.statusIsFresh(maxAge: Self.statusFallbackInterval) {
          await self?.refreshStatusOnce()
        }
        if Task.isCancelled { return }
        try? await Task.sleep(nanoseconds: UInt64(Self.statusFallbackInterval * 1_000_000_000))
      }
    }
  }

  func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
    if let statusObserver {
      NotificationCenter.default.removeObserver(statusObserver)
      self.statusObserver = nil
    }
  }

  /// Apply every published bridge status — socket push, LAN snapshot, or another
  /// surface's fetch — so the panel reacts without a request of its own.
  private func observeStatusPushes() {
    guard statusObserver == nil else { return }
    statusObserver = NotificationCenter.default.addObserver(
      forName: AgentPairingService.statusDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard let status = (note.object as? AgentBridgeStatus)
        ?? AgentPairingService.lastStatusSnapshot
      else { return }
      Task { @MainActor [weak self] in
        self?.applyStatus(status)
      }
    }
  }

  func refreshStatusOnce() async {
    guard let config = AppSessionConfig.current else { return }
    do {
      // Coalesced: Home and any open agent profile want the same snapshot, and each
      // uncoalesced call is a full round trip of server time.
      applyStatus(try await AgentPairingService.statusCoalesced(config: config))
    } catch {
      // A 401 here means the whole session token died, not just the bridge — kick
      // off a silent session refresh so the panel stops spinning on a dead token.
      if let pairingError = error as? AgentPairingError, case .http(401, _) = pairingError {
        Task { await AppSessionGuard.shared.recover(reason: "agent-connect-status") }
      }
      // Otherwise transient — keep the last known status and let the next tick retry.
    }
  }

  /// Single place the panel reacts to a bridge status, whichever transport carried
  /// it. Safe to call repeatedly with the same snapshot.
  private func applyStatus(_ next: AgentBridgeStatus) {
    status = next
    selectedRepository = AgentBridgeSelectionStore.ensureValidSelection(from: next.repositories)
    if next.connected {
      stopPolling()
      if isScanning && didAuthorize {
        // Confirm inside the scanner ("Connected") for a beat, then close it — so the
        // user gets a clear "it worked" signal instead of the sheet vanishing silently.
        if !didConfirmConnected {
          didConfirmConnected = true
          showScannerMessage("Connected", style: .success, canRetry: false)
          Task { [weak self] in
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard let self else { return }
            self.isScanning = false
            self.onConnected?()
          }
        }
      } else {
        isScanning = false
        onConnected?()
      }
    } else if isScanning, didAuthorize, let authorizedAt,
      Date().timeIntervalSince(authorizedAt) > 18
    {
      // Authorized, but the computer never came online — surface it instead of an
      // endless "Connecting…" spinner, and let the user retry.
      showScannerMessage(
        "Your computer hasn't come online. Make sure the bridge is running on your Mac, then scan again.",
        style: .error,
        canRetry: true
      )
    }
  }

  func beginScan() {
    errorMessage = nil
    didAuthorize = false
    didConfirmConnected = false
    authorizedAt = nil
    scannerMessage = nil
    scannerStatusStyle = .idle
    scannerCanRetry = false
    scannerResetToken += 1
    isScanning = true
  }

  func cancelScan() {
    isScanning = false
  }

  func retryScan() {
    errorMessage = nil
    didAuthorize = false
    didConfirmConnected = false
    authorizedAt = nil
    isAuthorizing = false
    scannerMessage = nil
    scannerStatusStyle = .idle
    scannerCanRetry = false
    scannerResetToken += 1
  }

  /// A QR was scanned. Parse the pairing request and authorize it against this
  /// (authenticated) account, binding the computer to the user.
  func handleScanned(_ payload: String) {
    // A dedicated key-sync QR (`vibegram-rk:...`) only hands over the E2E runtime
    // key for an already-paired computer. Keep the result inside the scanner so
    // the compact connect sheet never grows/clips around long status text.
    let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
    NSLog(
      "[KeySync] scanned len=\(trimmed.count) prefix=\(String(trimmed.prefix(14))) isRK=\(trimmed.hasPrefix("vibegram-rk:")) isPair=\(trimmed.hasPrefix("vibegram-pair:"))"
    )
    if trimmed.hasPrefix("vibegram-rk:") {
      guard let key = AgentRuntimeCrypto.runtimeKey(fromScanned: payload) else {
        NSLog("[KeySync] runtimeKey(fromScanned:) returned nil — empty/malformed rk payload")
        showScannerMessage("That key QR could not be read. Show a fresh key QR and scan again.", style: .error)
        return
      }
      let stored = AgentRuntimeCrypto.storeKey(key)
      NSLog(
        "[KeySync] storeKey=\(stored) keyB64Len=\(key.count) hasKeyNow=\(AgentRuntimeCrypto.hasKey) account=\(AgentRuntimeCrypto.debugActiveAccountTail())"
      )
      if stored {
        // The key just landed — (re)arm the direct-LAN link now instead of leaving it
        // stuck in `.unavailable` until the next relaunch/foreground.
        LanBridgeService.shared.start(userId: AppSessionConfig.current?.userID)
        // The key-sync QR's job is done the moment the key stores — show a brief
        // confirmation and close, rather than parking on a wall of explanatory text.
        showScannerMessage("Encryption key synced", style: .success, canRetry: false)
        Task { [weak self] in
          try? await Task.sleep(nanoseconds: 1_100_000_000)
          self?.isScanning = false
        }
      } else {
        showScannerMessage("That key QR could not be read. Show a fresh key QR and scan again.", style: .error)
      }
      return
    }
    guard let requestId = AgentPairingService.requestId(fromScanned: payload) else {
      showScannerMessage("That is not a Vibe pairing QR. Show the bridge pairing QR and scan again.", style: .error)
      return
    }
    guard AppSessionConfig.current != nil else {
      showScannerMessage(AgentPairingError.noSession.localizedDescription, style: .error, canRetry: false)
      return
    }
    // The pairing QR carries the E2E key in its `#` fragment; `requestId(fromScanned:)`
    // just stored it. (Re)arm the direct-LAN link right here — this is the missing step
    // that left "local" stuck as unavailable right after a fresh scan.
    LanBridgeService.shared.start(userId: AppSessionConfig.current?.userID)
    isAuthorizing = true
    showScannerMessage("Connecting…", style: .progress, canRetry: false)
    Task { [weak self] in
      guard let self else { return }
      defer { self.isAuthorizing = false }
      do {
        try await self.authorizeWithCurrentSession(requestId: requestId)
        self.didAuthorize = true
        self.authorizedAt = Date()
        // Stay on a single smooth "Connecting…" until the computer actually comes
        // online (then `refreshStatusOnce` flips it to "Connected" and closes the sheet).
        self.showScannerMessage("Connecting…", style: .progress, canRetry: false)
        await self.refreshStatusOnce()
        self.startPolling()
      } catch {
        self.didAuthorize = false
        self.showScannerMessage(
          self.friendlyConnectError(error),
          style: .error
        )
      }
    }
  }

  /// Turns a raw pairing/network error into a short, human "there's a connection problem"
  /// line rather than a stack-flavoured localizedDescription.
  private func friendlyConnectError(_ error: Error) -> String {
    if let pairingError = error as? AgentPairingError {
      switch pairingError {
      case .noSession:
        return "You're signed out. Sign in again, then scan to connect."
      case .http(let code, _) where code == 404 || code == 410:
        return "That pairing QR expired. Show a fresh QR on your computer and scan again."
      default:
        break
      }
    }
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain {
      return "Couldn't reach the server. Check your connection and scan again."
    }
    return "Couldn't connect. Show a fresh QR on your computer and scan again."
  }

  private func authorizeWithCurrentSession(requestId: String) async throws {
    guard let config = AppSessionConfig.current else {
      throw AgentPairingError.noSession
    }
    do {
      try await AgentPairingService.authorize(config: config, requestId: requestId)
    } catch let pairingError as AgentPairingError {
      if case .http(401, _) = pairingError {
        await AppSessionGuard.shared.recover(reason: "agent-connect-authorize")
        if let refreshed = AppSessionConfig.current,
          refreshed.authToken != config.authToken || refreshed.userID != config.userID
        {
          try await AgentPairingService.authorize(config: refreshed, requestId: requestId)
          return
        }
      }
      throw pairingError
    }
  }

  private func showScannerMessage(
    _ message: String,
    style: AgentQRScannerStatusStyle,
    canRetry: Bool? = nil
  ) {
    scannerMessage = message
    scannerStatusStyle = style
    scannerCanRetry = canRetry ?? (style == .error)
  }
}

/// Bottom panel rendered in place of the composer for an unconnected agent chat.
struct AgentConnectPanel: View {
  @ObservedObject var model: AgentConnectModel
  @Environment(\.colorScheme) private var colorScheme

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }
  private var scanButtonTitle: String {
    if model.didAuthorize { return "Waiting for computer…" }
    if model.isAuthorizing { return "Connecting…" }
    return "Scan to connect"
  }

  var body: some View {
    UIGlassWrapper(cornerRadius: 20) {
      VStack(spacing: 14) {
      HStack(spacing: 12) {
        ZStack {
          Circle().fill(palette.accent.opacity(0.16))
          Image(systemName: "laptopcomputer.and.iphone")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(palette.accent)
        }
        .frame(width: 44, height: 44)

        VStack(alignment: .leading, spacing: 3) {
          Text("Connect your computer")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(palette.text)
          Text(
            "\(model.displayName) runs on your own computer with your own subscription. Pair it once to start chatting here."
          )
          .font(.system(size: 13))
          .foregroundStyle(palette.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }

      HStack(spacing: 8) {
        Image(systemName: "lock.shield")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(palette.secondaryText)
        Text("Pairing is end-to-end and revocable. Only you can connect a computer.")
          .font(.system(size: 11.5))
          .foregroundStyle(palette.secondaryText)
        Spacer(minLength: 0)
      }

      Text(
        "On your computer run the bridge — it shows a QR. Scan it here to connect."
      )
      .font(.system(size: 11.5))
      .foregroundStyle(palette.secondaryText)
      .frame(maxWidth: .infinity, alignment: .leading)

      Button(action: { model.beginScan() }) {
        HStack(spacing: 8) {
          if model.isAuthorizing || model.didAuthorize {
            ProgressView().tint(.white)
          } else {
            Image(systemName: "qrcode.viewfinder")
          }
          Text(scanButtonTitle)
            .font(.system(size: 16, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .foregroundStyle(.white)
        .background(palette.accent)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      }
      .disabled(model.isAuthorizing || model.didAuthorize)

      if let errorMessage = model.errorMessage {
        Text(errorMessage)
          .font(.system(size: 12))
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      // Repo selection is intentionally NOT shown here. The connect panel is only
      // about pairing a computer; once connected it's replaced by the composer,
      // whose repo-picker control is the place to choose a repository.
      }
      .padding(16)
    }
    .fixedSize(horizontal: false, vertical: true)
    .padding(.horizontal, 12)
    .padding(.bottom, 8)
    .onAppear { model.onAppear() }
    .onDisappear { model.onDisappear() }
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
}

struct AgentBridgeRepositoryPickerView: View {
  let provider: String
  let displayName: String
  /// Chat the picker was opened from — used to read this chat's session history so
  /// the user can choose to continue a past session instead of starting a new task.
  var chatId: String = ""

  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @State private var status: AgentBridgeStatus = .disconnected
  @State private var selected: AgentBridgeRepository?
  @State private var workMode: AgentBridgeWorkMode = AgentBridgeSelectionStore.selectedWorkMode()
  @State private var isLoading = false
  @State private var errorMessage: String?
  @State private var sessions: [AgentBridgeHistorySession] = []
  @State private var historyRequestId: String?
  @State private var resumeSelectionId: String?

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }

  var body: some View {
    NavigationView {
      Group {
        if status.repositories.isEmpty && isLoading {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if status.repositories.isEmpty {
          VStack(spacing: 14) {
            Image(systemName: status.connected ? "folder.badge.questionmark" : "laptopcomputer.slash")
              .font(.system(size: 36, weight: .semibold))
              .foregroundStyle(palette.secondaryText)
            Text(status.connected ? "No repositories shared" : "Computer offline")
              .font(.system(size: 17, weight: .semibold))
              .foregroundStyle(palette.text)
            if let errorMessage {
              Text(errorMessage)
                .font(.system(size: 13))
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          List {
            Section {
              // Default: start a fresh task for the next message.
              resumeRow(
                title: "Start a new task",
                subtitle: "Each message runs on its own — no shared session",
                icon: "plus.circle",
                isSelected: resumeSelectionId == nil
              ) {
                resumeSelectionId = nil
                AgentBridgeSelectionStore.clearResumeSession(provider: provider)
              }
              ForEach(sessions) { session in
                resumeRow(
                  title: session.topic.isEmpty ? "Session" : session.topic,
                  subtitle: session.projectName.isEmpty
                    ? "\(session.messageCount) messages"
                    : "\(session.projectName) · \(session.messageCount) messages",
                  icon: "arrow.uturn.left.circle",
                  isSelected: resumeSelectionId == session.id
                ) {
                  resumeSelectionId = session.id
                  AgentBridgeSelectionStore.setResumeSession(
                    provider: provider,
                    id: session.id,
                    topic: session.topic
                  )
                }
              }
            } header: {
              Text("Continue a session")
            } footer: {
              Text(sessions.isEmpty
                ? "Past \(displayName) sessions on your computer will appear here."
                : "Pick a session to resume it; otherwise each message starts a new task.")
            }
            .listRowBackground(palette.card)

            Section {
              ForEach(AgentBridgeWorkMode.allCases) { mode in
                Button {
                  workMode = mode
                  AgentBridgeSelectionStore.setWorkMode(mode)
                } label: {
                  HStack(spacing: 12) {
                    Image(systemName: mode.icon)
                      .font(.system(size: 17, weight: .medium))
                      .foregroundStyle(palette.accent)
                      .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                      Text(mode.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.text)
                      Text(mode.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if workMode == mode {
                      Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(palette.accent)
                    }
                  }
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
              }
            } header: {
              Text("Permission")
            }
            .listRowBackground(palette.card)

            Section {
              ForEach(status.repositories, id: \.selectionIdentity) { repo in
                Button {
                  AgentBridgeSelectionStore.select(
                    repo, chatId: chatId.isEmpty ? nil : chatId)
                  selected = repo
                  dismiss()
                } label: {
                  HStack(spacing: 12) {
                    Image(systemName: repo.isGitRepository ? "shippingbox" : "folder")
                      .font(.system(size: 18, weight: .medium))
                      .foregroundStyle(palette.accent)
                      .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                      Text(repo.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                      Text(
                        [repo.computerLabel, repo.path]
                          .compactMap { value in
                            guard let value, !value.isEmpty else { return nil }
                            return value
                          }
                          .joined(separator: " · ")
                      )
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if (selected?.id == repo.id || selected?.cwd == repo.cwd)
                      && (selected?.computerId == nil || selected?.computerId == repo.computerId)
                    {
                      Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(palette.accent)
                    }
                  }
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
              }
            } header: {
              Text(status.devices.count > 1 ? "Computer and repository" : "Repository")
            } footer: {
              if status.devices.count > 1 {
                Text("Each repository is tied to its computer. Your team runs only on the computer you select here.")
              }
            }
            .listRowBackground(palette.card)
          }
          .listStyle(.insetGrouped)
          .scrollContentBackground(.hidden)
          .background(palette.background)
        }
      }
      .background(palette.background.ignoresSafeArea())
      .navigationTitle("\(displayName) repo")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("Close") { dismiss() }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button {
            Task { await refresh() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .disabled(isLoading)
        }
      }
      .task {
        if selected == nil {
          selected = AgentBridgeSelectionStore.selectedRepository(
            chatId: chatId.isEmpty ? nil : chatId)
        }
        resumeSelectionId = AgentBridgeSelectionStore.selectedResumeSession(provider: provider)?.id
        applyCachedHistory()
        loadHistory()
        await refresh()
      }
      .onReceive(NotificationCenter.default.publisher(for: ChatEngine.didChangeNotification)) { note in
        guard (note.userInfo?["reason"] as? String) == "agentBridgeHistory" else { return }
        if let pending = historyRequestId,
          let rid = note.userInfo?["requestId"] as? String,
          rid != pending {
          return
        }
        applyCachedHistory()
      }
    }
  }

  @ViewBuilder
  private func resumeRow(
    title: String,
    subtitle: String,
    icon: String,
    isSelected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: icon)
          .font(.system(size: 17, weight: .medium))
          .foregroundStyle(palette.accent)
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 3) {
          Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(palette.text)
            .lineLimit(1)
          Text(subtitle)
            .font(.system(size: 12))
            .foregroundStyle(palette.secondaryText)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
        if isSelected {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(palette.accent)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  /// Ask the connected computer for this chat's session list (the reply lands via the
  /// `agentBridgeHistory` change notification, then `applyCachedHistory` reads it).
  private func loadHistory() {
    guard !chatId.isEmpty else { return }
    let result = ChatEngine.shared.requestAgentBridgeHistory([
      "chatId": chatId,
      "provider": provider,
      "mode": "list",
    ])
    if (result["accepted"] as? Bool) == true {
      historyRequestId = result["requestId"] as? String
    }
  }

  private func applyCachedHistory() {
    guard
      !chatId.isEmpty,
      let payload = ChatEngine.shared.latestAgentBridgeHistoryList(
        chatId: chatId,
        provider: provider
      ),
      (payload["mode"] as? String ?? "list") == "list"
    else { return }
    let raw = payload["sessions"] as? [[String: Any]] ?? []
    sessions = raw.compactMap { item in
      guard let id = item["id"] as? String, !id.isEmpty else { return nil }
      return AgentBridgeHistorySession(
        id: id,
        topic: (item["topic"] as? String) ?? "Untitled",
        projectName: (item["projectName"] as? String) ?? "",
        projectPath: (item["project"] as? String) ?? (item["projectPath"] as? String) ?? (item["cwd"] as? String) ?? "",
        updatedAt: (item["updatedAt"] as? String) ?? "",
        messageCount: (item["messageCount"] as? NSNumber)?.intValue
          ?? (item["messageCount"] as? Int) ?? 0,
        isRunning: false,
        taskId: nil,
        sessionId: id
      )
    }
  }

  @MainActor
  private func refresh() async {
    guard let config = AppSessionConfig.current else { return }
    isLoading = true
    errorMessage = nil
    defer { isLoading = false }
    do {
      let next = try await AgentPairingService.status(config: config)
      status = next
      selected = AgentBridgeSelectionStore.ensureValidSelection(from: next.repositories)
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

// MARK: - Camera QR scanner

/// SwiftUI wrapper over an AVFoundation QR scanner used to pair a computer.
struct AgentQRScannerView: UIViewControllerRepresentable {
  let instruction: String
  let message: String?
  let statusStyle: AgentQRScannerStatusStyle
  let isProcessing: Bool
  let canRetry: Bool
  let resetToken: Int
  let onResult: (String) -> Void
  let onRetry: () -> Void
  let onCancel: () -> Void

  func makeUIViewController(context: Context) -> AgentQRScannerController {
    let controller = AgentQRScannerController()
    controller.instruction = instruction
    controller.onRetry = onRetry
    controller.onResult = onResult
    controller.onCancel = onCancel
    controller.applyStatus(
      message: message,
      style: statusStyle,
      isProcessing: isProcessing,
      canRetry: canRetry
    )
    controller.applyResetToken(resetToken)
    return controller
  }

  func updateUIViewController(_ controller: AgentQRScannerController, context: Context) {
    controller.instruction = instruction
    controller.onRetry = onRetry
    controller.onResult = onResult
    controller.onCancel = onCancel
    controller.applyStatus(
      message: message,
      style: statusStyle,
      isProcessing: isProcessing,
      canRetry: canRetry
    )
    controller.applyResetToken(resetToken)
  }
}

final class AgentQRScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  var instruction: String = "Scan the QR"
  var onResult: ((String) -> Void)?
  var onRetry: (() -> Void)?
  var onCancel: (() -> Void)?

  private let session = AVCaptureSession()
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private var metadataOutput: AVCaptureMetadataOutput?
  private let sessionQueue = DispatchQueue(label: "vibe.agent.qr.scanner")
  private var hasEmitted = false
  private var lastResetToken = 0
  /// When the visible action button represents a completed success (e.g. the E2E
  /// key finished syncing) it should dismiss the scanner rather than re-arm the
  /// camera — otherwise a finished flow looks like it still wants another scan.
  private var actionDismisses = false
  private let titleLabel = UILabel()
  private let messageLabel = UILabel()
  private let retryButton = UIButton(type: .system)
  private let activityIndicator = UIActivityIndicatorView(style: .large)
  
  private let overlayEffectView = UIVisualEffectView()
  private let overlayMaskLayer = CAShapeLayer()
  private let targetBoxLayer = CAShapeLayer()

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect()
      glass.isInteractive = true
      overlayEffectView.effect = glass
    } else {
      overlayEffectView.effect = UIBlurEffect(style: .systemMaterialDark)
    }
    
    let maskView = UIView()
    overlayMaskLayer.fillColor = UIColor.black.cgColor
    maskView.layer.addSublayer(overlayMaskLayer)
    overlayEffectView.mask = maskView
    view.addSubview(overlayEffectView)
    
    targetBoxLayer.strokeColor = UIColor.white.withAlphaComponent(0.6).cgColor
    targetBoxLayer.fillColor = UIColor.clear.cgColor
    targetBoxLayer.lineWidth = 2
    view.layer.addSublayer(targetBoxLayer)
    
    configureChrome()
    requestCameraAndConfigure()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    startRunning()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    stopRunning()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    previewLayer?.frame = view.bounds
    overlayEffectView.frame = view.bounds
    
    let boxSize: CGFloat = 260
    let boxRect = CGRect(
      x: (view.bounds.width - boxSize) / 2,
      y: (view.bounds.height - boxSize) / 2,
      width: boxSize,
      height: boxSize
    )
    
    let path = UIBezierPath(rect: view.bounds)
    let innerPath = UIBezierPath(roundedRect: boxRect, cornerRadius: 24)
    path.append(innerPath)
    path.usesEvenOddFillRule = true
    
    overlayMaskLayer.path = path.cgPath
    overlayMaskLayer.fillRule = .evenOdd
    overlayEffectView.mask?.frame = view.bounds
    
    targetBoxLayer.path = innerPath.cgPath
    
    if let preview = previewLayer, let output = metadataOutput {
      output.rectOfInterest = preview.metadataOutputRectConverted(fromLayerRect: boxRect)
    }
  }

  // MARK: Camera

  private func requestCameraAndConfigure() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      configureSession()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        DispatchQueue.main.async {
          guard let self else { return }
          if granted {
            self.configureSession()
            self.startRunning()
          } else {
            self.showMessage("Camera access is needed to scan the pairing QR.")
          }
        }
      }
    default:
      showMessage("Camera access is off. Enable it in Settings to scan the pairing QR.")
    }
  }

  private func configureSession() {
    guard
      let device = AVCaptureDevice.default(for: .video),
      let input = try? AVCaptureDeviceInput(device: device),
      session.canAddInput(input)
    else {
      showMessage("This device can't scan a QR code.")
      return
    }
    session.addInput(input)

    let output = AVCaptureMetadataOutput()
    self.metadataOutput = output
    guard session.canAddOutput(output) else {
      showMessage("This device can't scan a QR code.")
      return
    }
    session.addOutput(output)
    output.setMetadataObjectsDelegate(self, queue: .main)
    output.metadataObjectTypes = [.qr]

    let preview = AVCaptureVideoPreviewLayer(session: session)
    preview.videoGravity = .resizeAspectFill
    preview.frame = view.bounds
    view.layer.insertSublayer(preview, at: 0)
    previewLayer = preview
    hideMessage()
  }

  private func startRunning() {
    sessionQueue.async { [weak self] in
      guard let self, !self.session.inputs.isEmpty, !self.session.isRunning else { return }
      self.session.startRunning()
    }
  }

  private func stopRunning() {
    sessionQueue.async { [weak self] in
      guard let self, self.session.isRunning else { return }
      self.session.stopRunning()
    }
  }

  func metadataOutput(
    _ output: AVCaptureMetadataOutput,
    didOutput metadataObjects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    guard
      !hasEmitted,
      let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
      object.type == .qr,
      let value = object.stringValue
    else { return }
    hasEmitted = true
    UINotificationFeedbackGenerator().notificationOccurred(.success)
    stopRunning()
    onResult?(value)
  }

  // MARK: Chrome

  private func configureChrome() {
    let close = UIButton(type: .system)
    close.setImage(
      UIImage(systemName: "xmark.circle.fill"), for: .normal)
    close.tintColor = .white
    close.translatesAutoresizingMaskIntoConstraints = false
    close.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
    view.addSubview(close)

    titleLabel.text = instruction
    titleLabel.textColor = .white
    titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
    titleLabel.textAlignment = .center
    titleLabel.numberOfLines = 0
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(titleLabel)

    messageLabel.textColor = .white
    messageLabel.font = .systemFont(ofSize: 15, weight: .medium)
    messageLabel.textAlignment = .center
    messageLabel.numberOfLines = 0
    messageLabel.isHidden = true
    messageLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(messageLabel)

    activityIndicator.color = .white
    activityIndicator.hidesWhenStopped = true
    activityIndicator.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(activityIndicator)

    retryButton.setTitle("Scan again", for: .normal)
    retryButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    retryButton.tintColor = .black
    retryButton.backgroundColor = .white
    retryButton.layer.cornerCurve = .continuous
    retryButton.layer.cornerRadius = 18
    retryButton.contentEdgeInsets = UIEdgeInsets(top: 9, left: 18, bottom: 9, right: 18)
    retryButton.isHidden = true
    retryButton.translatesAutoresizingMaskIntoConstraints = false
    retryButton.addTarget(self, action: #selector(handleRetry), for: .touchUpInside)
    view.addSubview(retryButton)

    NSLayoutConstraint.activate([
      close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      close.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      close.widthAnchor.constraint(equalToConstant: 32),
      close.heightAnchor.constraint(equalToConstant: 32),

      titleLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 56),
      titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -56),

      activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      activityIndicator.bottomAnchor.constraint(equalTo: messageLabel.topAnchor, constant: -14),

      messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 170),
      messageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
      messageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),

      retryButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 16),
      retryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
    ])
  }

  private func showMessage(_ text: String) {
    messageLabel.text = text
    messageLabel.isHidden = false
  }

  func applyStatus(
    message: String?,
    style: AgentQRScannerStatusStyle,
    isProcessing: Bool,
    canRetry: Bool
  ) {
    loadViewIfNeeded()
    let hasStatus = (message?.isEmpty == false)
    if let message, hasStatus {
      showMessage(message)
    } else {
      hideMessage()
    }
    // While a live status is on screen (Connecting / Connected / error) the top
    // instruction is just noise — hide it so the panel reads as one clear state.
    titleLabel.isHidden = hasStatus && style != .idle
    switch style {
    case .idle, .progress:
      messageLabel.textColor = .white
    case .success:
      messageLabel.textColor = .systemGreen
    case .error:
      messageLabel.textColor = .systemRed
    }
    if isProcessing || style == .progress {
      activityIndicator.startAnimating()
    } else {
      activityIndicator.stopAnimating()
    }
    // A success state that offers a button is a finished flow (the key synced),
    // so the button closes the sheet and is labelled accordingly; every other
    // state re-arms the camera for another attempt.
    actionDismisses = (style == .success)
    retryButton.setTitle(actionDismisses ? "Done" : "Scan again", for: .normal)
    retryButton.isHidden = !canRetry
  }

  func applyResetToken(_ token: Int) {
    loadViewIfNeeded()
    guard token != lastResetToken else { return }
    lastResetToken = token
    resetScan()
  }

  private func hideMessage() {
    messageLabel.isHidden = true
    retryButton.isHidden = true
    activityIndicator.stopAnimating()
  }

  private func resetScan() {
    hasEmitted = false
    titleLabel.isHidden = false
    hideMessage()
    startRunning()
  }

  @objc private func handleClose() {
    onCancel?()
  }

  @objc private func handleRetry() {
    if actionDismisses {
      onCancel?()
      return
    }
    onRetry?()
    resetScan()
  }
}

struct UIGlassWrapper<Content: View>: UIViewRepresentable {
  var cornerRadius: CGFloat
  var strokeColor: Color = .clear
  let content: Content

  init(cornerRadius: CGFloat, strokeColor: Color = .clear, @ViewBuilder content: () -> Content) {
    self.cornerRadius = cornerRadius
    self.strokeColor = strokeColor
    self.content = content()
  }

  func makeUIView(context: Context) -> GlassContainerView<Content> {
    let blurView = UIVisualEffectView()
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect()
      effect.isInteractive = true
      blurView.effect = effect
    } else {
      blurView.effect = UIBlurEffect(style: .systemMaterial)
    }
    blurView.layer.cornerCurve = .continuous
    blurView.layer.cornerRadius = cornerRadius
    if strokeColor != .clear {
      blurView.layer.borderColor = UIColor(strokeColor).cgColor
      blurView.layer.borderWidth = 1.0
    }
    blurView.clipsToBounds = true

    let hostingController = UIHostingController(rootView: content)
    hostingController.view.backgroundColor = .clear
    
    blurView.contentView.addSubview(hostingController.view)
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hostingController.view.leadingAnchor.constraint(equalTo: blurView.contentView.leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: blurView.contentView.trailingAnchor),
      hostingController.view.topAnchor.constraint(equalTo: blurView.contentView.topAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: blurView.contentView.bottomAnchor)
    ])
    
    return GlassContainerView(blurView: blurView, hostingController: hostingController)
  }

  func updateUIView(_ uiView: GlassContainerView<Content>, context: Context) {
    uiView.hostingController.rootView = content
    uiView.hostingController.view.setNeedsUpdateConstraints()
  }
}

final class GlassContainerView<Content: View>: UIView {
  let blurView: UIVisualEffectView
  let hostingController: UIHostingController<Content>

  init(blurView: UIVisualEffectView, hostingController: UIHostingController<Content>) {
    self.blurView = blurView
    self.hostingController = hostingController
    super.init(frame: .zero)
    backgroundColor = .clear
    addSubview(blurView)
    blurView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
      blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
      blurView.topAnchor.constraint(equalTo: topAnchor),
      blurView.bottomAnchor.constraint(equalTo: bottomAnchor)
    ])
  }
  
  required init?(coder: NSCoder) { fatalError() }
  
  override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
    return hostingController.view.systemLayoutSizeFitting(targetSize)
  }
  
  override var intrinsicContentSize: CGSize {
    let size = hostingController.view.intrinsicContentSize
    return CGSize(width: UIView.noIntrinsicMetric, height: size.height)
  }
}
