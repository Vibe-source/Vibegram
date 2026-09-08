import SwiftUI
import UIKit

// In-app diagnostics viewer for the VibeLog store. Lets the user (or an admin
// walking someone through a bug) see recent structured logs, filter by
// level/category, and export a redacted report to share. This is the "we finally
// know what happened" surface the client was missing.

struct DiagnosticsView: View {
  @State private var entries: [VibeLogEntry] = []
  @State private var minLevel: VibeLogLevel = .debug
  @State private var categoryFilter: String? = nil
  @State private var expanded: Set<UUID> = []
  @State private var shareURL: ShareItem? = nil
  @State private var showClearConfirm = false
  @State private var autoRefresh = true
  @State private var coreSelfTestResult: String = ""
  @State private var coreSelfTestRunning: Bool = false
  @State private var coreBridgeEnabled: Bool = VibeCoreBridge.isEnabled
  @State private var coreShadowEnabled: Bool =
    VibeTimelineUserDefaultsFeatureFlags().flags.vibeTimelineShadowCompareEnabled
  @State private var coreOrderAuthorityEnabled: Bool =
    VibeTimelineUserDefaultsFeatureFlags().flags.vibeTimelineCoreOrderAuthorityEnabled
  @State private var transcriptWindowEnabled: Bool =
    VibeTimelineUserDefaultsFeatureFlags().flags.vibeTranscriptWindowEnabled

  private let refreshTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

  private var categories: [String] { VibeLog.shared.categories() }

  private var filtered: [VibeLogEntry] {
    entries
      .filter { $0.level >= minLevel }
      .filter { categoryFilter == nil || $0.category == categoryFilter }
      .reversed()  // most recent first
  }

  var body: some View {
    List {
      Section {
        deviceContextRow
      }

      Section {
        // The switch only gates `runSelfTest`, which builds a core against the
        // app's own user id. It changes no rendering, so leaving it off is safe
        // and turning it on cannot alter what any chat shows.
        Toggle("Bridge enabled", isOn: $coreBridgeEnabled)
          .onChange(of: coreBridgeEnabled) { _, on in
            VibeCoreBridge.setEnabled(on)
            if !on { coreSelfTestResult = "" }
          }

        Button("Run core self-test") {
          coreSelfTestRunning = true
          VibeCoreBridge.runSelfTest { result in
            DispatchQueue.main.async {
              coreSelfTestResult = result
              coreSelfTestRunning = false
            }
          }
        }
        .disabled(coreSelfTestRunning || !coreBridgeEnabled)

        if !coreSelfTestResult.isEmpty {
          Text(coreSelfTestResult)
            .font(.footnote.monospaced())
        }

        // A throwaway surface rendered from the Rust core instead of
        // ChatEngine. Lets the data layer (ordering, dedup, deltas, windowing)
        // be exercised where a wrong answer costs nothing, before the same
        // host is pointed at the production list in P4.
        //
        // Independent of the switch above: it builds its own core over a
        // scratch chat id, so it works with the bridge off and cannot touch the
        // app's data either way.
        NavigationLink("Core preview list") {
          VibeCorePreviewView()
        }

        // Stage 2: the same core through the real render path — VibeTimelineHost
        // into a UICollectionView with frozen geometry and anchor preservation.
        // This is the stack P4 points at the production list.
        NavigationLink("Core list (UIKit render path)") {
          VibeCoreListPreviewView()
        }

        // P4 rollout gate. Shadow only: the core runs beside your real 1:1 DMs
        // and reports where its ordering differs from the list's. It renders
        // nothing, so the worst case is a log line.
        Toggle("Shadow-compare real DMs", isOn: $coreShadowEnabled)
          .onChange(of: coreShadowEnabled) { _, on in
            // Only the shadow key. This used to also write the RENDER allowlist,
            // which is now a different list on purpose — writing it here would
            // mean arming a diagnostic silently widened what the render gate
            // covers the moment anyone enabled it. The shadow allowlist follows
            // this flag inside the provider.
            UserDefaults.standard.set(
              on, forKey: VibeTimelineUserDefaultsFeatureFlags.shadowCompareKey)
            VibeLog.notice(
              "shadow compare \(on ? "enabled" : "disabled") (reopen a chat to arm)",
              category: "core")
          }

        // The core becomes the list: order and content from one answer.
        //
        // No longer gated on the shadow-compare switch. That gate existed because
        // order authority used to be served by `VibeTimelineShadowProbe`, a second
        // core that had to be armed first; the probe is gone and ordering now comes
        // from the same instance that canonicalized and decrypted the rows, so
        // requiring a diagnostic to be on would only make this switch dead.
        Toggle("Core drives the list (order + content)", isOn: $coreOrderAuthorityEnabled)
          .onChange(of: coreOrderAuthorityEnabled) { _, on in
            UserDefaults.standard.set(
              on, forKey: VibeTimelineUserDefaultsFeatureFlags.coreOrderAuthorityKey)
            VibeLog.notice(
              "core order+content authority \(on ? "ENABLED" : "disabled") (reopen a chat)",
              category: "core")
          }
      } header: {
        Text("Rust core")
      } footer: {
        Text(
          "The preview screens run with the bridge off — they build their own core over a scratch chat. Shadow-compare watches your real 1:1 DMs and only writes to the log; reopen a chat after toggling it.\n\n\"Core orders the list\" is the first setting here that changes what you see: the core reorders the newest messages in a 1:1 DM, and nothing else. Turn it on only after shadow-compare has reported CLEAN — and if the order ever looks wrong, turn it off and reopen the chat.\n\n\"Open DMs on the core\" replaces the chat screen itself for 1:1 DMs — the transcript is rendered by the core, with nothing measured or mounted before the push. Groups, channels, agent chats and Saved Messages keep the old screen no matter what. It is a preview: bubbles look identical because they are the same cell, but hold-to-preview, swipe-to-reply and the message menu are not ported yet, so turn it off to get them back."
        )
      }

      Section {
        Toggle("Bounded transcript window", isOn: $transcriptWindowEnabled)
          .onChange(of: transcriptWindowEnabled) { _, on in
            UserDefaults.standard.set(
              on, forKey: VibeTimelineUserDefaultsFeatureFlags.transcriptWindowKey)
            VibeLog.notice(
              "transcript window \(on ? "ENABLED" : "disabled") (reopen a chat)",
              category: "list")
          }
      } header: {
        Text("Chat list")
      } footer: {
        Text(
          "Off. The list mounts every message in a conversation, and scrolling back through it is not supposed to stop or stall anywhere.\n\nTurning this on caps the mount at the newest 200 messages. Older ones are not dropped — scrolling up re-applies the whole transcript to get them back — but that re-apply is a visible jump, which is why this is a diagnostic and not the default. Use it to check whether a slow conversation is slow because of how many rows are mounted. This one is independent of the Rust core.\n\nThe log line to look for is \"transcript windowed\", with how many rows were shown and how many were withheld."
        )
      }

      Section {
        Picker("Minimum level", selection: $minLevel) {
          ForEach(VibeLogLevel.allCases, id: \.self) { lvl in
            Text(lvl.label).tag(lvl)
          }
        }
        Picker("Category", selection: Binding(
          get: { categoryFilter ?? "" },
          set: { categoryFilter = $0.isEmpty ? nil : $0 }
        )) {
          Text("All").tag("")
          ForEach(categories, id: \.self) { Text($0).tag($0) }
        }
      }

      Section {
        if filtered.isEmpty {
          Text("No log entries yet.")
            .foregroundStyle(.secondary)
            .font(.footnote)
        } else {
          ForEach(filtered) { entry in
            entryRow(entry)
              .contentShape(Rectangle())
              .onTapGesture { toggle(entry.id) }
          }
        }
      } header: {
        Text("\(filtered.count) entr\(filtered.count == 1 ? "y" : "ies")")
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Diagnostics & Logs")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          // Exports what is on screen. A reconnect storm can be 96% of the
          // buffer, and an unfiltered export of that answers no question anyone
          // asked — so the filters apply to the file too, and the file says so.
          Button {
            if let url = VibeLog.shared.exportFileURL(
              header: Self.deviceContext(), minLevel: minLevel, category: categoryFilter)
            {
              shareURL = ShareItem(url: url)
            }
          } label: { Label("Export what's shown", systemImage: "square.and.arrow.up") }

          Button {
            if let url = VibeLog.shared.exportFileURL(header: Self.deviceContext()) {
              shareURL = ShareItem(url: url)
            }
          } label: { Label("Export everything", systemImage: "square.and.arrow.up.on.square") }

          Button {
            autoRefresh.toggle()
          } label: {
            Label(autoRefresh ? "Pause live refresh" : "Resume live refresh",
                  systemImage: autoRefresh ? "pause" : "play")
          }

          Button(role: .destructive) {
            showClearConfirm = true
          } label: { Label("Clear logs", systemImage: "trash") }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
      }
    }
    .sheet(item: $shareURL) { item in
      ActivityView(activityItems: [item.url])
    }
    .confirmationDialog("Clear all diagnostic logs?", isPresented: $showClearConfirm, titleVisibility: .visible) {
      Button("Clear logs", role: .destructive) {
        VibeLog.shared.clear()
        reload()
      }
      Button("Cancel", role: .cancel) {}
    }
    .onAppear { reload() }
    .onReceive(refreshTimer) { _ in if autoRefresh { reload() } }
  }

  // MARK: Rows

  private var deviceContextRow: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(Self.deviceContext().sorted(by: { $0.key < $1.key }), id: \.key) { kv in
        HStack {
          Text(kv.key).foregroundStyle(.secondary)
          Spacer()
          Text(kv.value).multilineTextAlignment(.trailing)
        }
        .font(.caption.monospaced())
      }
    }
  }

  @ViewBuilder
  private func entryRow(_ entry: VibeLogEntry) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text(entry.level.symbol)
        Text(entry.category)
          .font(.caption2.weight(.semibold))
          .padding(.horizontal, 6).padding(.vertical, 1)
          .background(color(for: entry.level).opacity(0.15), in: Capsule())
          .foregroundStyle(color(for: entry.level))
        if entry.repeats > 1 {
          Text("×\(entry.repeats)")
            .font(.caption2.monospaced().weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Color.secondary.opacity(0.18), in: Capsule())
        }
        Spacer()
        Text(shortTime(entry.ts))
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
      }
      Text(entry.message)
        .font(.callout)
        .lineLimit(expanded.contains(entry.id) ? nil : 2)
        .foregroundStyle(entry.level >= .warning ? color(for: entry.level) : .primary)

      if expanded.contains(entry.id) {
        if let meta = entry.metadata, !meta.isEmpty {
          ForEach(meta.sorted(by: { $0.key < $1.key }), id: \.key) { kv in
            Text("\(kv.key): \(kv.value)")
              .font(.caption2.monospaced())
              .foregroundStyle(.secondary)
          }
        }
        Text("\(entry.file):\(entry.line) · \(entry.function) · \(entry.thread)")
          .font(.caption2.monospaced())
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 2)
  }

  // MARK: Helpers

  private func toggle(_ id: UUID) {
    if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
  }

  private func reload() {
    entries = VibeLog.shared.snapshot()
  }

  private func color(for level: VibeLogLevel) -> Color {
    switch level {
    case .debug: return .gray
    case .info: return .blue
    case .notice: return .teal
    case .warning: return .orange
    case .error: return .red
    case .fault: return .purple
    }
  }

  private func shortTime(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: date)
  }

  /// Provenance for an exported log: which build, which device, which settings.
  ///
  /// When two exports disagree, this is what says whether the code changed
  /// underneath them. The Dynamic Type category and layout direction are here
  /// because they are inputs to row geometry — a height report is unreadable
  /// without knowing which text size produced it.
  ///
  /// `@MainActor` because the trait and layout-direction lookups are; both call
  /// sites (the on-screen row and the export buttons) already run there.
  @MainActor
  static func deviceContext() -> [String: String] {
    let device = UIDevice.current
    let info = Bundle.main.infoDictionary
    let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
    let build = (info?["CFBundleVersion"] as? String) ?? "?"
    let isRTL = UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft
    return [
      "app": "\(version) (\(build))",
      "bundle": Bundle.main.bundleIdentifier ?? "?",
      "os": "\(device.systemName) \(device.systemVersion)",
      "device": deviceModelIdentifier(),
      "model": device.model,
      "locale": "\(Locale.current.identifier)\(isRTL ? " RTL" : "")",
      "textSize": UIApplication.shared.preferredContentSizeCategory.rawValue
        .replacingOccurrences(of: "UICTContentSizeCategory", with: ""),
      "freeDiskMB": freeDiskSpaceMB(),
    ]
  }

  /// Free space in MB, or `"?"`. `volumeAvailableCapacityForImportantUsage` is
  /// the number that matters — the raw free-space figure counts purgeable space
  /// the system will not actually hand over.
  private static func freeDiskSpaceMB() -> String {
    let home = URL(fileURLWithPath: NSHomeDirectory())
    guard
      let values = try? home.resourceValues(
        forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
      let capacity = values.volumeAvailableCapacityForImportantUsage
    else { return "?" }
    return String(capacity / (1024 * 1024))
  }

  private static func deviceModelIdentifier() -> String {
    var sysinfo = utsname()
    uname(&sysinfo)
    let mirror = Mirror(reflecting: sysinfo.machine)
    let id = mirror.children.compactMap { ($0.value as? Int8).flatMap { $0 == 0 ? nil : Character(UnicodeScalar(UInt8($0))) } }
    let str = String(id)
    return str.isEmpty ? "?" : str
  }
}

// Identifiable wrapper so `.sheet(item:)` can carry the export URL.
private struct ShareItem: Identifiable {
  let id = UUID()
  let url: URL
}

// UIActivityViewController bridge for the share sheet.
private struct ActivityView: UIViewControllerRepresentable {
  let activityItems: [Any]
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
  }
  func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
