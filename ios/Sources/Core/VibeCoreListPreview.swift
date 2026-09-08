import SwiftUI
import UIKit

/// Stage 2 of the preview surface: the **real** render path.
///
/// The SwiftUI list in ``VibeCorePreviewView`` proves the data layer — order,
/// dedup, windowing — by having no geometry code that could be blamed for a
/// wrong answer. This screen is the opposite half: the same core driving
/// `VibeTimelineHost` → `VibeCollectionMessageListHost`, which is a real
/// `UICollectionView` with a real custom layout and real anchor preservation.
/// It is the exact stack P4 points at the production list, aimed somewhere a
/// mistake costs nothing.
///
/// The two counters at the top are the ones that matter:
///
/// - **settled-geometry violations** must be `0`. A non-zero value means a row
///   that was already on screen changed height, which is the month-long bug.
/// - **measured vs reused** shows the frozen-geometry cache working. Sending
///   into a 200-row window should measure ~1 row and reuse the rest; if measured
///   climbs with every send, rows are being re-measured and the freeze is broken.
struct VibeCoreListPreviewView: View {
  @StateObject private var model = VibeCoreListPreviewModel()
  @State private var draft: String = ""

  var body: some View {
    VStack(spacing: 0) {
      banner
      VibeCoreListRepresentable(model: model)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider()
      composer
    }
    .navigationTitle("Core list (UIKit)")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { model.start() }
    .onDisappear { model.stop() }
  }

  private var banner: some View {
    let clean = model.violations == 0
    return VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Image(systemName: clean ? "checkmark.seal.fill" : "xmark.seal.fill")
          .foregroundStyle(clean ? .green : .red)
        Text(
          clean
            ? "Nothing on screen moved" : "\(model.violations) visible jump(s)"
        )
        .font(.subheadline.weight(.semibold))
        Spacer()
      }
      Text(model.stats)
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background((clean ? Color.green : Color.red).opacity(0.10))
  }

  private var composer: some View {
    VStack(spacing: 8) {
      HStack {
        TextField("Message", text: $draft)
          .textFieldStyle(.roundedBorder)
          .submitLabel(.send)
          .onSubmit(send)
        Button("Send", action: send).buttonStyle(.borderedProminent)
      }
      HStack {
        Button("Seed 250") { model.seed(250) }
        Spacer()
        Button("Long msg") { model.sendLong() }
        Spacer()
        Button("Backdate") { model.sendBackdated() }
        Spacer()
        Button("Reset") { model.reset() }
      }
      .font(.caption)
      .buttonStyle(.bordered)
    }
    .padding()
  }

  private func send() {
    model.send(draft.isEmpty ? "hello" : draft)
    draft = ""
  }
}

/// Hosts the `UICollectionView` and hands it its size.
private struct VibeCoreListRepresentable: UIViewRepresentable {
  let model: VibeCoreListPreviewModel

  func makeUIView(context: Context) -> UIView {
    let container = UIView()
    let listView = model.listView
    listView.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(listView)
    NSLayoutConstraint.activate([
      listView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      listView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      listView.topAnchor.constraint(equalTo: container.topAnchor),
      listView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    return container
  }

  func updateUIView(_ view: UIView, context: Context) {
    // Deliberately empty. Width arrives from the collection view's own
    // `layoutSubviews`, not from here — SwiftUI calls `updateUIView` before
    // layout, so asking the container for its width answers `0` and then never
    // gets asked again. That produced 114 skipped mounts and a list measured
    // against a placeholder width.
  }
}

/// Owns the core, the adapter, and the UIKit host for the preview.
@MainActor
final class VibeCoreListPreviewModel: ObservableObject {
  @Published private(set) var violations = 0
  @Published private(set) var stats = "not started"

  let listHost = VibeCollectionMessageListHost()
  var listView: UIView { listHost.view }

  private var handle: VibeCoreHandle?
  private var sink: ListPreviewSink?
  private var timelineHost: VibeTimelineHost?
  private let chatId = "core-list-preview"
  private let ownUserId = "preview-user"
  private var nextTs: Int64 = 1_000
  private var sent = 0
  private var width: CGFloat = 0

  private static let longBody = String(
    repeating: "This paragraph exists to produce a tall bubble that wraps over several lines. ",
    count: 6)

  func start() {
    guard handle == nil else { return }
    let host = VibeTimelineHost(chatId: chatId, listHost: listHost)
    host.onDiagnostic = { [weak self] message, meta in
      self?.logHostEvent("list preview: \(message)", meta: meta, isFailure: true)
    }
    // The core is the only thing that can answer "what should be on screen", so
    // a resync is a fresh window request, not a replay from a local mirror.
    host.onNeedsResync = { [weak self] in self?.requestWindow() }
    timelineHost = host

    // Width arrives from the list itself, when it is actually laid out.
    listHost.onWidthChange = { [weak self] newWidth in
      guard let self else { return }
      self.width = newWidth
      self.timelineHost?.setEnvironment(width: newWidth)
      self.refreshStats()
    }
    if listHost.currentWidth > 0 { host.setEnvironment(width: listHost.currentWidth) }

    listHost.onDiagnostic = { [weak self] message, meta, isFailure in
      guard let self else { return }
      self.logHostEvent("list preview host: \(message)", meta: meta, isFailure: isFailure)
      self.refreshStats()
    }

    let sink = ListPreviewSink()
    sink.onWindow = { [weak self] window in
      Task { @MainActor in
        self?.timelineHost?.mount(window: window, reason: .engineReconcile)
        self?.refreshStats()
      }
    }
    sink.onDelta = { [weak self] delta in
      Task { @MainActor in
        self?.timelineHost?.ingest(delta: delta)
        self?.refreshStats()
      }
    }
    self.sink = sink

    // Its own handle, deliberately not `VibeCoreBridge.sharedCore`: this screen
    // feeds adversarial synthetic fixtures — scrambled timestamps, duplicate ids —
    // and those must never land in the reducer that serves real conversations.
    // `unwrapper: nil` for the same reason the fixtures are plaintext: there is
    // nothing here to decrypt, and a probe screen has no business holding the
    // Keychain seam.
    handle = VibeCoreHandle(
      config: VibeFfiConfig(ownUserId: ownUserId, flushFrameIntervalMs: 8), sink: sink,
      unwrapper: nil)
    refreshStats()
  }

  func stop() {
    timelineHost?.shutdown()
    timelineHost = nil
    handle?.shutdown()
    handle = nil
    sink = nil
  }

  func reset() {
    stop()
    nextTs = 1_000
    sent = 0
    violations = 0
    start()
  }

  /// One message, delivered as a **delta**.
  ///
  /// Deliberately does not request a window. Asking for one turns every send
  /// into a full re-mount, which looks fine and proves nothing: it never
  /// exercises the incremental op path, and anchor preservation only runs on
  /// transactions. The first run of this screen did exactly that — 87 updates,
  /// 87 full mounts, zero transactions.
  func send(_ text: String) {
    sent += 1
    nextTs += 1_000
    ingest(id: "L\(sent)", ts: nextTs, text: text)
    flush()
  }

  /// A bubble tall enough that a height mistake is unmissable.
  func sendLong() {
    sent += 1
    nextTs += 1_000
    ingest(id: "L\(sent)", ts: nextTs, text: Self.longBody)
    flush()
  }

  /// A message old enough to land near the **top** of the window.
  ///
  /// This is the §5.4 "insert above viewport" row. The previous version backdated
  /// by 30 s, which after a 250-message seed put it about thirty rows from the
  /// end — still below the viewport, so it tested bottom-following rather than
  /// preservation and looked like the list had simply scrolled.
  ///
  /// Landing it a quarter of the way into the window puts it above anything the
  /// viewport is showing in almost any scroll position, which is the case that
  /// must not move the screen. The verdict is the `anchorDrifted` counter, not
  /// the eye.
  func sendBackdated() {
    sent += 1
    let span = nextTs - 1_000
    let backdated = max(1_000, nextTs - (span * 3) / 4)
    ingest(id: "L\(sent)", ts: backdated, text: "backdated \(sent) (ts \(backdated))")
    flush()
  }

  /// Fills past the 200-row window cap so head eviction is exercised.
  func seed(_ count: Int) {
    for _ in 0..<count {
      sent += 1
      nextTs += 1_000
      ingest(id: "L\(sent)", ts: nextTs, text: "seeded message \(sent)")
    }
    requestWindow()
  }

  // MARK: Internals

  /// Routes a host event to the log, sampling the successes.
  ///
  /// The first version wrote one `info` line per host event and put the running
  /// `reused` counter in its metadata. That defeats `VibeLog`'s repeat
  /// coalescing — every line differs by one number, so nothing folds — and a
  /// single visit to this screen produced **1,355 of the 1,500** entries in the
  /// ring, evicting the real-chat data the export existed to carry. That is the
  /// third time a diagnostic in this project has destroyed its own evidence.
  ///
  /// Failures still log every time; there are never many of them, and each one
  /// is the point. Successes are sampled, and only the sampled line pays for the
  /// counters.
  private func logHostEvent(_ message: String, meta: [String: String], isFailure: Bool) {
    if isFailure {
      VibeLog.error(message, category: "core", metadata: enriched(meta))
      return
    }
    hostEvents += 1
    guard hostEvents % Self.hostEventLogInterval == 1 else { return }
    VibeLog.info(message, category: "core", metadata: enriched(meta))
  }

  private func enriched(_ meta: [String: String]) -> [String: String] {
    var enriched = meta
    if let stats = timelineHost?.measurementStats {
      enriched["measured"] = String(stats.measured)
      enriched["reused"] = String(stats.reused)
      enriched["remeasureAll"] = String(stats.invalidations)
      enriched["placeholderSized"] = String(stats.placeholders)
    }
    enriched["settledHeightChanges"] = String(listHost.settledGeometryViolations)
    enriched["anchorDrifted"] = String(listHost.anchorDriftViolations)
    enriched["event"] = String(hostEvents)
    return enriched
  }

  private var hostEvents = 0
  private static let hostEventLogInterval = 100

  private func refreshStats() {
    // Both counters feed one verdict: either the list moved something the user
    // was looking at, or it did not.
    violations = listHost.settledGeometryViolations + listHost.anchorDriftViolations
    guard let host = timelineHost else {
      stats = "core not started"
      return
    }
    let m = host.measurementStats
    let drift = listHost.worstAnchorDrift
    stats =
      "measured \(m.measured) · reused \(m.reused) · commits \(listHost.appliedTransactions) · "
      + "rejected \(listHost.rejectedTransactions) · "
      + "height \(listHost.settledGeometryViolations) · anchor \(listHost.anchorDriftViolations)"
      + (drift > 0 ? String(format: " (worst %.1fpt)", drift) : "")
  }

  /// Pushes what has been ingested so the core emits a delta.
  private func flush() {
    guard let handle else { return }
    try? handle.flush(nowMs: nextTs + 1)
  }

  /// Asks for the whole window. Bulk loads and resyncs only — never a single send.
  private func requestWindow() {
    guard let handle else { return }
    try? handle.flush(nowMs: nextTs + 1)
    try? handle.requestWindow(chatId: chatId, nowMs: nextTs + 2)
  }

  private func ingest(id: String, ts: Int64, text: String) {
    guard let handle else { return }
    let safe = text
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let frame = """
      {"id":"\(id)","chat_id":"\(chatId)","sender_id":"\(sent % 3 == 0 ? "peer" : ownUserId)",\
      "timestamp":\(ts),"content":"\(safe)","type":"text"}
      """
    do {
      try handle.ingestFrame(
        chatId: chatId, json: Data(frame.utf8), source: .chatTopic, receivedAtMs: ts)
    } catch {
      VibeLog.error(
        "list preview ingest failed", category: "core",
        metadata: ["id": id, "error": String(describing: error)])
    }
  }
}

/// Forwards core callbacks. Called on the Rust worker thread.
private final class ListPreviewSink: VibeDeltaSink {
  var onWindow: ((VibeFfiWindow) -> Void)?
  var onDelta: ((VibeFfiDelta) -> Void)?

  func onDelta(delta: VibeFfiDelta) { onDelta?(delta) }
  func onWindow(window: VibeFfiWindow) { onWindow?(window) }
  func onError(message: String) {
    VibeLog.error("list preview core error", category: "core", metadata: ["message": message])
  }
}
