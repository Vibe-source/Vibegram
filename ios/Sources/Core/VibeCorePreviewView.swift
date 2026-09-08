import SwiftUI

/// A throwaway surface that renders **from the Rust core** instead of `ChatEngine`.
///
/// # Why this exists
///
/// P4 points the new render host at the production chat list. That list is
/// ~51,000 lines across six files and owns the commit-first push contract, so a
/// wrong ordering or dedup decision shows up as a visible regression in a real
/// conversation. This screen is the same work aimed somewhere harmless: it
/// exercises the core's **data** layer — ordering, dedup, id healing, deltas,
/// windowing — with no geometry, no anchor preservation, and no production code
/// path involved.
///
/// Deliberately **not** a UICollectionView. Sizing and anchor preservation are
/// where the layout-shift bugs live, and mixing them in here would mean a bug
/// could be either a data bug or a geometry bug with no way to tell them apart.
/// A plain `List` sizes itself; if a row is out of order here, the ordering is
/// wrong, full stop. Geometry gets its own stage on this same screen later.
///
/// # It grades itself
///
/// Reading a list of rows and deciding by eye whether ordering is right is not a
/// test — it is a guess, and it gets harder with every row. So every window the
/// core returns is checked against the invariants in ``VibeCoreInvariantReport``
/// and the verdict is both shown here and written to ``VibeLog`` under the
/// `core` category. An exported log answers "did the core behave" on its own,
/// without the screen and without a description of what was on it.
///
/// Uses Saved-Messages semantics — sealed to self, no peer key to resolve, no
/// network — so it can be driven entirely offline.
struct VibeCorePreviewView: View {
  @StateObject private var model = VibeCorePreviewModel()
  @State private var draft: String = ""

  var body: some View {
    VStack(spacing: 0) {
      verdictBanner

      if model.rows.isEmpty {
        ContentUnavailableView(
          "No rows",
          systemImage: "tray",
          description: Text("Send a message, then run the probes.")
        )
        .frame(maxHeight: .infinity)
      } else {
        transcript
      }

      Divider()
      composer
    }
    .navigationTitle("Core preview")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Run all") { model.runAllProbes() }
      }
    }
    .onAppear { model.start() }
    .onDisappear { model.stop() }
  }

  // MARK: Pieces

  /// The actual result. Everything below it is just evidence for this line.
  private var verdictBanner: some View {
    let clean = model.failures == 0
    return HStack(spacing: 8) {
      Image(systemName: clean ? "checkmark.seal.fill" : "xmark.seal.fill")
        .foregroundStyle(clean ? .green : .red)
      VStack(alignment: .leading, spacing: 1) {
        Text(clean ? model.report.headline : "FAIL — \(model.failures) bad window(s)")
          .font(.subheadline.weight(.semibold))
        Text(model.report.detail)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
      Spacer()
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background((clean ? Color.green : Color.red).opacity(0.10))
  }

  /// Chat-shaped on purpose. Ordering errors are much easier to see against the
  /// familiar bottom-anchored, sender-aligned arrangement than against a table.
  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 6) {
          ForEach(model.rows, id: \.messageId) { row in
            bubble(row).id(row.messageId)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
      }
      .onChange(of: model.rows.count) { _, _ in
        guard let last = model.rows.last else { return }
        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(last.messageId, anchor: .bottom) }
      }
    }
  }

  @ViewBuilder
  private func bubble(_ row: VibeCorePreviewRow) -> some View {
    HStack {
      if row.isOwn { Spacer(minLength: 48) }
      VStack(alignment: row.isOwn ? .trailing : .leading, spacing: 3) {
        Text(row.text.isEmpty ? "(empty)" : row.text)
          .font(.body)
          .foregroundStyle(row.isOwn ? .white : .primary)
        // The order key is printed on every bubble. Ordering is a claim about
        // these two fields, so they belong where the claim can be checked.
        Text("\(row.messageId) · ts \(row.tsMs) · seq \(row.orderSeq)")
          .font(.caption2.monospaced())
          .foregroundStyle(row.isOwn ? .white.opacity(0.75) : .secondary)
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 7)
      .background(
        row.isOwn ? Color.accentColor : Color.secondary.opacity(0.16),
        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
      )
      if !row.isOwn { Spacer(minLength: 48) }
    }
  }

  private var composer: some View {
    VStack(spacing: 8) {
      HStack {
        TextField("Message", text: $draft)
          .textFieldStyle(.roundedBorder)
          .submitLabel(.send)
          .onSubmit(sendDraft)
        Button("Send", action: sendDraft)
          .buttonStyle(.borderedProminent)
      }

      // Each probe targets one property the core is supposed to guarantee.
      // A failure here is a core bug, not a rendering bug — this screen has no
      // sizing code that could be blamed instead.
      HStack {
        Button("Out of order") { model.sendOutOfOrder() }
        Spacer()
        Button("Duplicate id") { model.sendDuplicate() }
        Spacer()
        Button("Burst ×20") { model.sendBurst() }
        Spacer()
        Button("Reset") { model.reset() }
      }
      .font(.caption)
      .buttonStyle(.bordered)
    }
    .padding()
  }

  private func sendDraft() {
    model.send(draft.isEmpty ? "hello" : draft)
    draft = ""
  }
}

/// One rendered row. Flattened from `VibeFfiMessage`.
struct VibeCorePreviewRow: Equatable {
  let messageId: String
  let tsMs: Int64
  let orderSeq: UInt64
  let text: String
  let isOwn: Bool
}

/// The verdict on one window, and the reason behind it.
struct VibeCoreInvariantReport: Equatable {
  var ordering = true
  var unique = true
  var complete = true
  var detail = "no window yet"
  var checked = 0
  var rowCount = 0
  /// Ingested ids that fall inside this window's span — what completeness is
  /// actually measured against.
  var spanned = 0

  var allPassed: Bool { ordering && unique && complete }

  var headline: String {
    guard checked > 0 else { return "Waiting for the first window" }
    if allPassed { return "PASS — \(checked) window\(checked == 1 ? "" : "s") checked" }
    var failed: [String] = []
    if !ordering { failed.append("ordering") }
    if !unique { failed.append("dedup") }
    if !complete { failed.append("gap in window") }
    return "FAIL — \(failed.joined(separator: ", "))"
  }

  /// Grades one window against the three properties the core guarantees.
  ///
  /// - ordering: the total order is `ts_ms ASC, message_id ASC`. Checked over
  ///   adjacent pairs, which is sufficient and finds the first offending pair.
  /// - unique: one row per message id, no matter how many times it arrived.
  /// - complete: **no gaps between the window's own head and tail.**
  ///
  /// That last one is worth being precise about, because the obvious version of
  /// it is wrong. Comparing the window against every id ever ingested fails as
  /// soon as the window fills: the core caps a window at
  /// `VibeWindowPolicy.default_len` (200) and evicts from the head, so older ids
  /// are *supposed* to be absent, and ids ingested after the snapshot was taken
  /// have not arrived yet. Both are correct behaviour, and a check that flags
  /// them reports a failure on every window forever while proving nothing.
  ///
  /// Bounding the check to `[head, tail]` still catches the bug that matters —
  /// a row dropped from the middle of the window — which ordering and dedup
  /// would both happily call a pass.
  static func grade(rows: [VibeCorePreviewRow], expected: [String: Int64])
    -> VibeCoreInvariantReport
  {
    var report = VibeCoreInvariantReport()
    report.checked = 1
    report.rowCount = rows.count

    for (a, b) in zip(rows, rows.dropFirst())
    where (b.tsMs, b.messageId) < (a.tsMs, a.messageId) {
      report.ordering = false
      report.detail = "out of order at \(a.messageId)(ts \(a.tsMs)) → \(b.messageId)(ts \(b.tsMs))"
      break
    }

    let ids = rows.map(\.messageId)
    if Set(ids).count != ids.count {
      report.unique = false
      let dupes = Set(ids.filter { id in ids.filter { $0 == id }.count > 1 })
      report.detail = "duplicate ids \(dupes.sorted().joined(separator: ","))"
    }

    if let head = rows.first, let tail = rows.last {
      let low = (head.tsMs, head.messageId)
      let high = (tail.tsMs, tail.messageId)
      let shouldBePresent = expected.filter { id, ts in (ts, id) >= low && (ts, id) <= high }
      report.spanned = shouldBePresent.count
      let missing = Set(shouldBePresent.keys).subtracting(ids)
      if !missing.isEmpty {
        report.complete = false
        report.detail = "gap inside window: \(missing.sorted().prefix(12).joined(separator: ","))"
      }
    }

    if report.allPassed {
      report.detail =
        "\(rows.count) rows of \(expected.count) ingested — ordered, unique, no gaps"
    }
    return report
  }
}

/// Owns a core handle and republishes its window on the main actor.
@MainActor
final class VibeCorePreviewModel: ObservableObject {
  @Published private(set) var rows: [VibeCorePreviewRow] = []
  @Published private(set) var status: String = "not started"
  @Published private(set) var report = VibeCoreInvariantReport()

  private var handle: VibeCoreHandle?
  private var sink: PreviewSink?
  private let chatId = "core-preview"
  private let ownUserId = "preview-user"
  private var nextTs: Int64 = 1_000
  private var sent = 0

  /// Every distinct id handed to the core, with the timestamp it was sent at.
  /// The completeness check needs a reference the core did not produce,
  /// otherwise it only grades itself; the timestamp is what lets that reference
  /// be narrowed to the window's own span.
  private var expected: [String: Int64] = [:]

  /// Windows checked so far, so the banner reports cumulative confidence rather
  /// than just the most recent frame.
  private var windowsChecked = 0
  /// Published, and never cleared except by Reset. A banner that goes green
  /// again after one bad window hides the only result that mattered.
  @Published private(set) var failures = 0

  /// A passing window is only interesting in bulk. Logging all 503 of a burst
  /// filled the 1500-entry ring with `core` lines and evicted every other
  /// category — the exact failure this screen was built to stop doing to the
  /// export. Failures are always logged in full; successes are sampled.
  private static let verifiedLogSampling = 25

  func start() {
    guard handle == nil else { return }
    let sink = PreviewSink()
    // The sink is called from the Rust worker thread. Everything it hands back
    // is bounced onto the main actor here rather than there, so the worker is
    // never blocked waiting on SwiftUI.
    sink.onWindowRows = { [weak self] rows, note in
      Task { @MainActor in self?.applyWindow(rows, note: note) }
    }
    sink.onNote = { [weak self] note in
      Task { @MainActor in self?.status = note }
    }
    self.sink = sink

    let config = VibeFfiConfig(ownUserId: ownUserId, flushFrameIntervalMs: 0)
    // Isolated from `VibeCoreBridge.sharedCore` on purpose — see the grading
    // fixtures below. `unwrapper: nil`: nothing here is encrypted.
    handle = VibeCoreHandle(config: config, sink: sink, unwrapper: nil)
    status = "core started"
    VibeLog.notice(
      "preview core started", category: "core",
      metadata: ["chat": chatId, "version": VibeCoreBridge.coreVersion])
  }

  func stop() {
    handle?.shutdown()
    handle = nil
    sink = nil
    status = "core stopped"
    VibeLog.info(
      "preview core stopped", category: "core",
      metadata: ["windows": String(windowsChecked), "failures": String(failures)])
  }

  func reset() {
    stop()
    rows = []
    nextTs = 1_000
    sent = 0
    expected = [:]
    windowsChecked = 0
    failures = 0
    report = VibeCoreInvariantReport()
    start()
  }

  /// Normal append.
  func send(_ text: String) {
    sent += 1
    nextTs += 1_000
    ingest(id: "p\(sent)", ts: nextTs, text: text, probe: "append")
  }

  /// A message stamped *earlier* than what is already shown.
  ///
  /// The core must place it in timestamp order, not at the end. This is the
  /// probe for the total order `ts_ms ASC, message_id ASC`.
  func sendOutOfOrder() {
    sent += 1
    let backdated = max(1_000, nextTs - 2_500)
    ingest(id: "p\(sent)", ts: backdated, text: "out-of-order (ts \(backdated))", probe: "reorder")
  }

  /// The same message id twice.
  ///
  /// The core must keep exactly one row. A second row appearing here is the
  /// dedup bug that has no test coverage in the Swift engine today.
  func sendDuplicate() {
    let id = "p\(sent)"
    // Replay at the *original* timestamp, not the current head. A re-send with a
    // different ts is a different question (which timestamp wins), and mixing it
    // in would make a dedup pass or fail for reasons that have nothing to do
    // with dedup — including breaking the completeness reference, which can only
    // record one position per id.
    guard sent > 0, let ts = expected[id] else {
      status = "send something first"
      return
    }
    ingest(id: id, ts: ts, text: "duplicate of \(id)", probe: "dedup")
  }

  /// Twenty messages with shuffled timestamps in one go.
  ///
  /// Single probes prove the easy cases. Interleaving reorders and repeats at
  /// speed is what actually exercises the reducer, and it is the shape real
  /// traffic has when a socket reconnects and replays a backlog.
  func sendBurst() {
    let base = nextTs
    for i in 0..<20 {
      sent += 1
      // Deterministic but non-monotonic: a fixed stride mod a coprime modulus
      // walks the slots in a scrambled order that reproduces exactly on rerun.
      let offset = Int64((i * 7) % 20) * 100
      ingest(id: "p\(sent)", ts: base + offset, text: "burst \(i)", probe: "burst")
      if i % 3 == 0 { ingest(id: "p\(sent)", ts: base + offset, text: "burst \(i)", probe: "burst") }
    }
    nextTs = base + 2_000
  }

  /// The whole battery, in the order that makes each result interpretable.
  func runAllProbes() {
    reset()
    for i in 1...3 { send("seed \(i)") }
    sendOutOfOrder()
    sendDuplicate()
    sendBurst()
    // The one line worth reading in an export. Everything sampled above is
    // supporting evidence for this verdict.
    VibeLog.notice(
      "preview probe battery finished", category: "core",
      metadata: [
        "rows": String(rows.count),
        "ingested": String(expected.count),
        "windows": String(windowsChecked),
        "failures": String(failures),
        "verdict": failures == 0 ? "PASS" : "FAIL",
      ])
  }

  // MARK: Internals

  private func applyWindow(_ incoming: [VibeCorePreviewRow], note: String) {
    rows = incoming
    windowsChecked += 1

    var graded = VibeCoreInvariantReport.grade(rows: incoming, expected: expected)
    graded.checked = windowsChecked
    if !graded.allPassed { failures += 1 }
    report = graded
    status = note

    let meta: [String: String] = [
      "window": String(windowsChecked),
      "rows": String(incoming.count),
      "spanned": String(graded.spanned),
      "ingested": String(expected.count),
      "ordering": graded.ordering ? "ok" : "FAIL",
      "unique": graded.unique ? "ok" : "FAIL",
      "complete": graded.complete ? "ok" : "FAIL",
      "detail": graded.detail,
    ]
    if graded.allPassed {
      if windowsChecked % Self.verifiedLogSampling == 0 {
        VibeLog.info("preview window verified", category: "core", metadata: meta)
      }
    } else {
      // The order itself is the evidence for an ordering failure, so it is
      // recorded here rather than being reconstructed from a screenshot later.
      var failing = meta
      failing["order"] = incoming.map { "\($0.messageId)@\($0.tsMs)" }.joined(separator: ",")
      VibeLog.error("preview window INVARIANT VIOLATED", category: "core", metadata: failing)
    }
  }

  private func ingest(id: String, ts: Int64, text: String, probe: String) {
    guard let handle else {
      status = "core not started"
      VibeLog.warning("preview ingest with no core", category: "core", metadata: ["id": id])
      return
    }
    // Escaped so a quote or backslash in the draft cannot produce a malformed
    // frame and make a UI typo look like a core failure.
    let safe = text
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    let frame = """
      {"id":"\(id)","chat_id":"\(chatId)","sender_id":"\(ownUserId)",\
      "timestamp":\(ts),"content":"\(safe)","type":"text"}
      """
    do {
      try handle.ingestFrame(
        chatId: chatId, json: Data(frame.utf8), source: .savedMessages, receivedAtMs: ts)
      try handle.flush(nowMs: ts + 1)
      try handle.requestWindow(chatId: chatId, nowMs: ts + 2)
      // Last write wins, matching the core: a repeated id is the same message,
      // so the reference must not record it twice or claim two timestamps.
      expected[id] = ts
    } catch {
      status = "ingest failed: \(error)"
      VibeLog.error(
        "preview ingest failed", category: "core",
        metadata: ["id": id, "probe": probe, "error": String(describing: error)])
    }
  }
}

/// Bridges core callbacks to the model. Called on the Rust worker thread.
private final class PreviewSink: VibeDeltaSink {
  var onWindowRows: (([VibeCorePreviewRow], String) -> Void)?
  var onNote: ((String) -> Void)?

  func onDelta(delta: VibeFfiDelta) {
    switch delta.body {
    case .ops(let ops):
      // Not logged. One line per delta is one line per ingest, which is how the
      // last export ended up 100% `core` with everything else evicted. The
      // generation counter is visible in the status line while the screen is up,
      // and a delta that mattered shows up in the window verdict anyway.
      onNote?("delta gen \(delta.baseGeneration)→\(delta.generation), \(ops.count) ops")
    case .reset(let window):
      onNote?("reset, \(window.messages.count) rows")
      VibeLog.info(
        "preview delta reset", category: "core",
        metadata: ["rows": String(window.messages.count)])
    }
  }

  func onWindow(window: VibeFfiWindow) {
    let rows = window.messages.map {
      VibeCorePreviewRow(
        messageId: $0.messageId, tsMs: $0.tsMs, orderSeq: $0.orderSeq, text: $0.text,
        isOwn: $0.authorIsMe)
    }
    onWindowRows?(rows, "window \(rows.count) rows, total known \(window.bounds.totalKnown)")
  }

  func onError(message: String) {
    onNote?("error: \(message)")
    VibeLog.error("preview core error", category: "core", metadata: ["message": message])
  }
}
