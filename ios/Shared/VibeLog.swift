import Foundation
import os

// MARK: - VibeLog
//
// Persistent, structured, redacting client-side diagnostics for Vibe.
//
// Why this exists: before this, iOS logging was `NSLog` / `os_log` behind a
// DEBUG-only verbose flag (`VibeDebugLog`). Nothing survived a relaunch, nothing
// surfaced in-app, and nothing could be exported — so when something broke in a
// shipped build there was no record to look at. VibeLog is the durable layer:
//
//   • Structured entries (level, category, message, metadata, file/func/line, thread).
//   • A bounded on-disk ring (rotating JSONL) that survives relaunch + crashes.
//   • Secret/PII redaction on the way in, so an exported log is safe to share.
//   • A crash/last-gasp breadcrumb (uncaught exceptions + fatal signals) surfaced
//     on the NEXT launch as "the previous session terminated abnormally".
//   • os_log mirroring so Console.app still works during development.
//
// Foundation-only by design: it lives in `Shared/` and compiles into both the app
// and the notification service extension (each writes into its own container).
//
// Usage:
//   VibeLog.error("push sync failed", category: "push", metadata: ["status": "500"])
//   VibeLog.info("chat opened", category: "chat")
// and read them back in the in-app Diagnostics screen (see DiagnosticsView).

public enum VibeLogLevel: Int, Codable, CaseIterable, Comparable, Sendable {
  case debug = 0
  case info = 1
  case notice = 2
  case warning = 3
  case error = 4
  case fault = 5

  public static func < (lhs: VibeLogLevel, rhs: VibeLogLevel) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public var label: String {
    switch self {
    case .debug: return "DEBUG"
    case .info: return "INFO"
    case .notice: return "NOTICE"
    case .warning: return "WARN"
    case .error: return "ERROR"
    case .fault: return "FAULT"
    }
  }

  public var symbol: String {
    switch self {
    case .debug: return "•"
    case .info: return "ℹ️"
    case .notice: return "◦"
    case .warning: return "⚠️"
    case .error: return "⛔️"
    case .fault: return "💥"
    }
  }

  fileprivate var osType: OSLogType {
    switch self {
    case .debug: return .debug
    case .info: return .info
    case .notice: return .default
    case .warning: return .default
    case .error: return .error
    case .fault: return .fault
    }
  }
}

public struct VibeLogEntry: Codable, Identifiable, Sendable {
  public let id: UUID
  public let ts: Date
  public let level: VibeLogLevel
  public let category: String
  public let message: String
  public let metadata: [String: String]?
  public let file: String
  public let function: String
  public let line: Int
  public let thread: String

  /// How many identical events this row stands for.
  ///
  /// A reconnect loop emits the same two lines hundreds of times, which used to
  /// evict everything else from a 1500-entry ring and leave an export that was
  /// 96% one repeated failure. Collapsing repeats keeps the *rare* lines — the
  /// ones worth exporting — alive in the buffer. See ``VibeLog/appendLocked(_:)``.
  public var repeats: Int = 1

  /// Timestamp of the most recent occurrence. Equals ``ts`` until a repeat folds in.
  public var lastTs: Date?

  public var timestampString: String {
    VibeLog.isoFormatter.string(from: ts)
  }

  /// One canonical single-line rendering used for both the file (JSONL carries the
  /// struct; this is the human export) and the in-app row subtitle.
  public var singleLine: String {
    let meta = metadata.flatMap { $0.isEmpty ? nil : " " + $0.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ") } ?? ""
    var repeated = ""
    if repeats > 1 {
      let last = lastTs.map { VibeLog.isoFormatter.string(from: $0) } ?? timestampString
      repeated = " (×\(repeats), through \(last))"
    }
    return "\(timestampString) [\(level.label)] [\(category)] \(message)\(meta)\(repeated) (\(file):\(line) \(thread))"
  }
}

extension VibeLogEntry {
  /// Decodes tolerantly so JSONL written by an older build — which had no
  /// `repeats`/`lastTs` — still replays instead of being silently dropped.
  /// Declared in an extension so the memberwise initialiser survives.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    ts = try c.decode(Date.self, forKey: .ts)
    level = try c.decode(VibeLogLevel.self, forKey: .level)
    category = try c.decode(String.self, forKey: .category)
    message = try c.decode(String.self, forKey: .message)
    metadata = try c.decodeIfPresent([String: String].self, forKey: .metadata)
    file = try c.decode(String.self, forKey: .file)
    function = try c.decode(String.self, forKey: .function)
    line = try c.decode(Int.self, forKey: .line)
    thread = try c.decode(String.self, forKey: .thread)
    repeats = try c.decodeIfPresent(Int.self, forKey: .repeats) ?? 1
    lastTs = try c.decodeIfPresent(Date.self, forKey: .lastTs)
  }
}

public final class VibeLog {
  public static let shared = VibeLog()

  // Serial queue guards the ring buffer + file handle. Logging never blocks the
  // caller's thread beyond the enqueue.
  private let queue = DispatchQueue(label: "com.vibegram.vibe.vibelog", qos: .utility)
  private let osLogger = Logger(subsystem: "com.mohammadshayani.vibe.native", category: "VibeLog")

  // In-memory ring for the Diagnostics UI (most-recent-last).
  private var ring: [VibeLogEntry] = []
  private let ringCapacity = 1500

  // Rotating JSONL on disk: current + one previous. ~1MB total ceiling.
  private let maxFileBytes = 512 * 1024
  private var currentBytes = 0
  private var didBootstrap = false

  // Async-signal-safe crash marker: an fd we can `write()` to from a signal
  // handler (only write/raise/signal are called there).
  private static var crashMarkerFD: Int32 = -1

  private init() {}

  // MARK: Paths

  private var baseDir: URL {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return root.appendingPathComponent("Diagnostics", isDirectory: true)
  }
  private var currentURL: URL { baseDir.appendingPathComponent("vibe-current.log") }
  private var previousURL: URL { baseDir.appendingPathComponent("vibe-previous.log") }
  private var crashMarkerURL: URL { baseDir.appendingPathComponent("vibe-crash.marker") }

  // MARK: Bootstrap

  /// Call once, early in app launch (and safe to call from the NSE). Prepares the
  /// store, replays a crash breadcrumb from a previous run, and installs the
  /// uncaught-exception + fatal-signal handlers. Idempotent.
  public func bootstrap(appContext: [String: String] = [:]) {
    queue.sync {
      guard !didBootstrap else { return }
      didBootstrap = true

      try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
      if let attrs = try? FileManager.default.attributesOfItem(atPath: currentURL.path),
        let size = attrs[.size] as? NSNumber
      {
        currentBytes = size.intValue
      } else {
        currentBytes = 0
      }
      loadRecentFromDiskLocked()
      openCrashMarkerLocked()
    }

    replayCrashMarkerIfNeeded()
    installExceptionHandler()
    installSignalHandlers()

    var ctx = appContext
    ctx["pid"] = String(ProcessInfo.processInfo.processIdentifier)
    log(.notice, "session start", category: "lifecycle", metadata: ctx)
  }

  // MARK: Public logging API

  public static func debug(_ m: @autoclosure () -> String, category: String = "app", metadata: [String: String]? = nil, file: String = #fileID, function: String = #function, line: Int = #line) {
    shared.log(.debug, m(), category: category, metadata: metadata, file: file, function: function, line: line)
  }
  public static func info(_ m: @autoclosure () -> String, category: String = "app", metadata: [String: String]? = nil, file: String = #fileID, function: String = #function, line: Int = #line) {
    shared.log(.info, m(), category: category, metadata: metadata, file: file, function: function, line: line)
  }
  public static func notice(_ m: @autoclosure () -> String, category: String = "app", metadata: [String: String]? = nil, file: String = #fileID, function: String = #function, line: Int = #line) {
    shared.log(.notice, m(), category: category, metadata: metadata, file: file, function: function, line: line)
  }
  public static func warning(_ m: @autoclosure () -> String, category: String = "app", metadata: [String: String]? = nil, file: String = #fileID, function: String = #function, line: Int = #line) {
    shared.log(.warning, m(), category: category, metadata: metadata, file: file, function: function, line: line)
  }
  public static func error(_ m: @autoclosure () -> String, category: String = "app", metadata: [String: String]? = nil, file: String = #fileID, function: String = #function, line: Int = #line) {
    shared.log(.error, m(), category: category, metadata: metadata, file: file, function: function, line: line)
  }
  public static func fault(_ m: @autoclosure () -> String, category: String = "app", metadata: [String: String]? = nil, file: String = #fileID, function: String = #function, line: Int = #line) {
    shared.log(.fault, m(), category: category, metadata: metadata, file: file, function: function, line: line)
  }

  /// Log an Error value with its localized description + domain/code when available.
  public static func error(_ error: Error, _ context: String = "", category: String = "app", metadata: [String: String]? = nil, file: String = #fileID, function: String = #function, line: Int = #line) {
    let ns = error as NSError
    var meta = metadata ?? [:]
    meta["domain"] = ns.domain
    meta["code"] = String(ns.code)
    let msg = context.isEmpty ? ns.localizedDescription : "\(context): \(ns.localizedDescription)"
    shared.log(.error, msg, category: category, metadata: meta, file: file, function: function, line: line)
  }

  public func log(_ level: VibeLogLevel, _ message: String, category: String = "app", metadata: [String: String]? = nil, file: String = #fileID, function: String = #function, line: Int = #line) {
    let safeMessage = VibeLogRedactor.redact(message)
    let safeMeta = metadata.map { dict in
      dict.reduce(into: [String: String]()) { acc, kv in acc[kv.key] = VibeLogRedactor.redactValue(key: kv.key, value: kv.value) }
    }
    let entry = VibeLogEntry(
      id: UUID(),
      ts: Date(),
      level: level,
      category: category,
      message: safeMessage,
      metadata: safeMeta,
      file: shortFile(file),
      function: function,
      line: line,
      thread: Thread.isMainThread ? "main" : "bg"
    )

    // Console mirror (immediate, unbuffered) — outside the serial queue so Console
    // ordering doesn't wait on disk.
    osLogger.log(level: level.osType, "[\(category, privacy: .public)] \(safeMessage, privacy: .public)")

    queue.async { [weak self] in self?.appendLocked(entry) }
  }

  // MARK: Reads / export

  public func snapshot() -> [VibeLogEntry] {
    queue.sync { ring }
  }

  public func categories() -> [String] {
    queue.sync { Array(Set(ring.map { $0.category })).sorted() }
  }

  /// Full human-readable export: header + in-memory ring, all already redacted.
  ///
  /// `minLevel` and `category` mirror whatever the diagnostics screen is showing.
  /// Exporting the unfiltered buffer sounds more helpful than it is: one chatty
  /// subsystem produces a file where the interesting lines are a rounding error,
  /// and whoever receives it has to filter anyway. The header records what was
  /// excluded so a filtered export can never be mistaken for a complete one.
  public func exportText(
    header: [String: String] = [:],
    minLevel: VibeLogLevel = .debug,
    category: String? = nil
  ) -> String {
    queue.sync {
      let selected = ring.filter {
        $0.level >= minLevel && (category == nil || $0.category == category)
      }
      var out = "=== Vibe diagnostics export ===\n"
      out += "generated: \(Self.isoFormatter.string(from: Date()))\n"
      for (k, v) in header.sorted(by: { $0.key < $1.key }) { out += "\(k): \(v)\n" }
      out += "entries (in-memory ring): \(ring.count)\n"
      if selected.count != ring.count {
        out += "filter: level>=\(minLevel.label) category=\(category ?? "all")\n"
        out += "entries (after filter): \(selected.count)\n"
      }
      let folded = ring.reduce(0) { $0 + max(0, $1.repeats - 1) }
      if folded > 0 { out += "repeats folded: \(folded)\n" }
      out += "categories: "
      out += Dictionary(grouping: ring, by: \.category)
        .map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " ")
      out += "\n===============================\n\n"
      out += selected.map { $0.singleLine }.joined(separator: "\n")
      out += "\n"
      return out
    }
  }

  /// Writes the export to a temp file and returns its URL (for a share sheet).
  public func exportFileURL(
    header: [String: String] = [:],
    minLevel: VibeLogLevel = .debug,
    category: String? = nil
  ) -> URL? {
    let text = exportText(header: header, minLevel: minLevel, category: category)
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("vibe-diagnostics-\(Int(Date().timeIntervalSince1970)).txt")
    do {
      try text.data(using: .utf8)?.write(to: url)
      return url
    } catch {
      osLogger.error("export write failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  public func clear() {
    queue.sync {
      ring.removeAll()
      try? FileManager.default.removeItem(at: currentURL)
      try? FileManager.default.removeItem(at: previousURL)
      currentBytes = 0
    }
    log(.notice, "diagnostics cleared", category: "lifecycle")
  }

  // MARK: - Locked internals (run on `queue`)

  /// How far back to look for an identical event before treating one as new.
  ///
  /// Not just the previous entry: a reconnect loop alternates ("connecting",
  /// "receive failed", "connecting", …) so last-entry-only comparison collapses
  /// nothing. A short window catches interleaved pairs while still keeping two
  /// genuinely different events in a busy log apart.
  private static let coalesceLookBack = 12
  private static let coalesceWindow: TimeInterval = 300

  private func appendLocked(_ entry: VibeLogEntry) {
    // Fold a repeat into the row already in the ring instead of appending.
    // The row keeps its original position and first-seen timestamp; only the
    // count and last-seen move. Disk is skipped entirely for repeats, which is
    // what stops a reconnect storm from rotating the on-disk log and destroying
    // the history someone is trying to export.
    let cutoff = entry.ts.addingTimeInterval(-Self.coalesceWindow)
    for i in stride(from: ring.count - 1, through: max(0, ring.count - Self.coalesceLookBack), by: -1)
    where i < ring.count {
      let candidate = ring[i]
      if (candidate.lastTs ?? candidate.ts) < cutoff { break }
      if candidate.level == entry.level, candidate.category == entry.category,
        candidate.message == entry.message, candidate.line == entry.line,
        candidate.file == entry.file, candidate.metadata == entry.metadata
      {
        ring[i].repeats += 1
        ring[i].lastTs = entry.ts
        return
      }
    }

    ring.append(entry)
    if ring.count > ringCapacity { ring.removeFirst(ring.count - ringCapacity) }

    guard let line = try? Self.jsonEncoder.encode(entry), var data = String(data: line, encoding: .utf8) else { return }
    data += "\n"
    guard let bytes = data.data(using: .utf8) else { return }

    if currentBytes + bytes.count > maxFileBytes { rotateLocked() }

    if let handle = try? FileHandle(forWritingTo: ensureCurrentFileLocked()) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: bytes)
      currentBytes += bytes.count
    }
  }

  private func ensureCurrentFileLocked() -> URL {
    if !FileManager.default.fileExists(atPath: currentURL.path) {
      FileManager.default.createFile(atPath: currentURL.path, contents: nil)
      currentBytes = 0
    }
    return currentURL
  }

  private func rotateLocked() {
    try? FileManager.default.removeItem(at: previousURL)
    try? FileManager.default.moveItem(at: currentURL, to: previousURL)
    FileManager.default.createFile(atPath: currentURL.path, contents: nil)
    currentBytes = 0
  }

  private func loadRecentFromDiskLocked() {
    var entries: [VibeLogEntry] = []
    for url in [previousURL, currentURL] {
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
      for line in text.split(separator: "\n") {
        guard let data = line.data(using: .utf8),
              let entry = try? Self.jsonDecoder.decode(VibeLogEntry.self, from: data) else { continue }
        entries.append(entry)
      }
    }
    if entries.count > ringCapacity { entries.removeFirst(entries.count - ringCapacity) }
    ring = entries
  }

  // MARK: - Crash breadcrumb

  private func openCrashMarkerLocked() {
    let path = crashMarkerURL.path
    if !FileManager.default.fileExists(atPath: path) {
      FileManager.default.createFile(atPath: path, contents: nil)
    }
    Self.crashMarkerFD = open(path, O_WRONLY | O_APPEND)
  }

  /// If a previous run left a crash marker, surface it as a warning entry, then
  /// truncate the marker so we don't re-report it.
  private func replayCrashMarkerIfNeeded() {
    let url = crashMarkerURL
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    log(.fault, "previous session terminated abnormally", category: "crash", metadata: ["marker": text.trimmingCharacters(in: .whitespacesAndNewlines)])
    // Truncate the marker (keep the fd valid for this run's handlers).
    try? "".data(using: .utf8)?.write(to: url)
  }

  private func installExceptionHandler() {
    NSSetUncaughtExceptionHandler { exception in
      let stack = exception.callStackSymbols.prefix(12).joined(separator: " | ")
      VibeLog.shared.log(
        .fault,
        "uncaught exception: \(exception.name.rawValue) — \(exception.reason ?? "nil")",
        category: "crash",
        metadata: ["stack": String(stack.prefix(1500))]
      )
      // Best-effort synchronous flush already happened via appendLocked on the queue;
      // give it a beat before the process is torn down.
      VibeLog.shared.queue.sync {}
    }
  }

  private func installSignalHandlers() {
    let fatal: [Int32] = [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP]
    for sig in fatal {
      signal(sig) { received in
        // ASYNC-SIGNAL-SAFE ONLY. No Foundation, no heap allocation — write a
        // fixed StaticString marker to the pre-opened fd, then re-raise.
        if VibeLog.crashMarkerFD >= 0 {
          let marker: StaticString = "signal\n"
          marker.withUTF8Buffer { buf in
            if let base = buf.baseAddress {
              _ = write(VibeLog.crashMarkerFD, base, buf.count)
            }
          }
        }
        signal(received, SIG_DFL)
        raise(received)
      }
    }
  }

  // MARK: - Helpers / formatters

  private func shortFile(_ file: String) -> String {
    // #fileID is "Module/Path.swift" — keep just the filename.
    (file as NSString).lastPathComponent
  }

  static let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  fileprivate static let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
  }()

  fileprivate static let jsonDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }()
}

// MARK: - Redaction
//
// Everything logged is scrubbed BEFORE it touches memory or disk, so an exported
// diagnostics file is safe to hand to support. Targeted patterns (not a blanket
// scrub) so the logs stay useful for debugging.

enum VibeLogRedactor {
  private static let placeholder = "‹redacted›"

  // Keys whose values are always sensitive (metadata + JSON bodies).
  // Prefer specific fragments over a bare "auth" match so keys like "author"
  // stay useful; authorization/authtoken/bearer still match.
  private static let sensitiveKeyFragments = [
    "password", "passcode", "token", "secret", "authorization", "authtoken",
    "login_token", "logintoken", "bearer", "apns", "voip", "credential", "cookie",
    "privatekey", "private_key", "encryptedprivatekey", "session", "otp",
    "phonenumber", "phone_number", "email",
  ]

  private static let patterns: [(NSRegularExpression, String)] = {
    func rx(_ p: String) -> NSRegularExpression {
      try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }
    return [
      // Bearer <token> (header values and free text)
      (rx("(bearer\\s+)[A-Za-z0-9._\\-+/=]{6,}"), "$1\(placeholder)"),
      // x-vibe-auth: Bearer … (whole value after the header name)
      (rx("(x-vibe-auth\\s*:\\s*)[^\\s,;]+"), "$1\(placeholder)"),
      // Vibe agent secrets
      (rx("vas_[A-Za-z0-9._\\-]{6,}"), "vas_\(placeholder)"),
      // PEM private keys (single-line or with whitespace)
      (rx("-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"), "\(placeholder)pem"),
      // JSON "sensitiveKey":"value"
      (rx("(\"(?:password|passcode|token|authtoken|login_token|secret|authorization|apns[a-z_]*|voip[a-z_]*|credential|cookie|encryptedprivatekey|private_key|otp|email|phone|phonenumber)\"\\s*:\\s*\")[^\"]*(\")"), "$1\(placeholder)$2"),
      // key=value in query/log strings
      (rx("(?:token|secret|password|authtoken|login_token|credential|apikey|api_key|email|phone)=[^\\s&\"]+"), placeholder),
      // Full URLs with query strings — keep origin+path, drop query (tokens often live there)
      (rx("(https?://[^\\s\"'?#]+)(\\?[^\\s\"']*)"), "$1?\(placeholder)"),
      // Email addresses
      (rx("\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b"), "\(placeholder)email"),
      // E.164 phone numbers
      (rx("\\+\\d{8,15}"), "\(placeholder)phone"),
      // Long hex blobs (apns/device tokens, sha hashes) — 32+ hex chars
      (rx("\\b[0-9a-f]{32,}\\b"), "\(placeholder)hex"),
    ]
  }()

  static func redact(_ input: String) -> String {
    var s = input
    for (regex, template) in patterns {
      let range = NSRange(s.startIndex..<s.endIndex, in: s)
      s = regex.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
    }
    return s
  }

  static func redactValue(key: String, value: String) -> String {
    let lowerKey = key.lowercased()
    if sensitiveKeyFragments.contains(where: { lowerKey.contains($0) }) {
      return value.isEmpty ? value : "\(placeholder)(\(value.count))"
    }
    // Keys that often carry full request URLs
    if lowerKey == "url" || lowerKey.hasSuffix("url") || lowerKey == "uri" {
      return redactURLForLog(value)
    }
    return redact(value)
  }

  /// Host + path only; never keep query strings (common token vehicle).
  static func redactURLForLog(_ raw: String) -> String {
    guard let components = URLComponents(string: raw), let host = components.host else {
      return redact(raw)
    }
    let scheme = components.scheme ?? "https"
    let path = components.path.isEmpty ? "" : components.path
    let hasQuery = components.query != nil && !(components.query?.isEmpty ?? true)
    return hasQuery ? "\(scheme)://\(host)\(path)?\(placeholder)" : "\(scheme)://\(host)\(path)"
  }
}
