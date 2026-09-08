import SwiftUI
import UIKit
import WebKit
import OSLog
import Darwin
import Combine

import ContactsUI

enum VibeDebugLog {
  static let verboseEnabled: Bool = {
    #if DEBUG
      let environment = ProcessInfo.processInfo.environment
      let arguments = ProcessInfo.processInfo.arguments
      return environment["VIBE_VERBOSE_LOGS"] == "1"
        || environment["VIBE_UI_TRACE_CONSOLE"] == "1"
        || arguments.contains("-VibeVerboseLogs")
        || arguments.contains("-VibeUITraceConsoleLogs")
        || UserDefaults.standard.bool(forKey: "VibeVerboseLogs")
        || UserDefaults.standard.bool(forKey: "VibeUITraceConsoleLogs")
    #else
      return false
    #endif
  }()

  static func notice(logger: Logger, _ message: String) {
    guard verboseEnabled else { return }
    logger.notice("\(message, privacy: .public)")
  }

  static func log(_ format: String, _ args: CVarArg...) {
    guard verboseEnabled else { return }
    withVaList(args) { pointer in
      NSLogv(format, pointer)
    }
  }

  static func print(_ message: String) {
    guard verboseEnabled else { return }
    Swift.print(message)
  }
}

enum AppUITrace {
  static let subsystem = "com.mohammadshayani.vibe.native"
  private static let logger = Logger(subsystem: subsystem, category: "UITrace")

  static func notice(_ message: String) {
    VibeDebugLog.notice(logger: logger, message)
  }

  static func error(_ message: String) {
    logger.error("\(message, privacy: .public)")
    NSLog("[VibeUITrace][error] %@", message)
    // Persist to the durable diagnostics store so shipped-build errors leave a record.
    VibeLog.error(message, category: "ui")
  }

  static func fault(_ message: String) {
    logger.fault("\(message, privacy: .public)")
    NSLog("[VibeUITrace][fault] %@", message)
    VibeLog.fault(message, category: "ui")
  }
}

final class AppUIStallWatchdog {
  static let shared = AppUIStallWatchdog()

  private let lock = NSLock()
  private let queue = DispatchQueue(label: "com.mohammadshayani.vibe.ui-stall-watchdog", qos: .utility)
  private let stallThresholdSeconds: TimeInterval = 2.0
  private var timer: DispatchSourceTimer?
  private var started = false
  private var active = false
  private var lastMainBeatAt = ProcessInfo.processInfo.systemUptime
  private var latestContext = "launch"
  private var lastReportedStallBucket = -1
  private var wasStalled = false
  /// Mach port for the main thread, captured on the main thread itself. Lets the
  /// background watchdog read the main thread's run-state during a stall to tell
  /// a busy-loop (run=running, high cpu) apart from a blocking wait (run=waiting).
  private var mainMachThread: mach_port_t = 0

  private init() {}

  func start(context: String) {
    var shouldStart = false
    locked {
      latestContext = context
      active = true
      lastMainBeatAt = ProcessInfo.processInfo.systemUptime
      if !started {
        started = true
        shouldStart = true
      }
    }
    guard shouldStart else { return }
    AppUITrace.notice("watchdog start thresholdMs=\(Int(stallThresholdSeconds * 1000)) context=\(context)")
    scheduleMainBeat()

    let source = DispatchSource.makeTimerSource(queue: queue)
    source.schedule(deadline: .now() + 1.0, repeating: 0.75)
    source.setEventHandler { [weak self] in
      self?.checkForStall()
    }
    locked {
      timer = source
    }
    source.resume()
  }

  func setActive(_ isActive: Bool, context: String) {
    locked {
      active = isActive
      latestContext = context
      lastMainBeatAt = ProcessInfo.processInfo.systemUptime
      lastReportedStallBucket = -1
      wasStalled = false
    }
    AppUITrace.notice("watchdog active=\(isActive ? "Y" : "N") context=\(context)")
  }

  func updateContext(_ context: String) {
    locked {
      latestContext = context
    }
  }

  private func scheduleMainBeat() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self else { return }
      self.recordMainBeat()
      self.scheduleMainBeat()
    }
  }

  private func recordMainBeat() {
    let now = ProcessInfo.processInfo.systemUptime
    let recovered: (blockedMs: Int, context: String)? = locked {
      if mainMachThread == 0 {
        mainMachThread = pthread_mach_thread_np(pthread_self())
      }
      let elapsed = now - lastMainBeatAt
      lastMainBeatAt = now
      lastReportedStallBucket = -1
      guard active, wasStalled else { return nil }
      wasStalled = false
      return (Int(elapsed * 1000), latestContext)
    }
    if let recovered {
      AppUITrace.error(
        "main-thread-recovered blockedMs=\(recovered.blockedMs) context=\(recovered.context)"
      )
    }
  }

  private func checkForStall() {
    let now = ProcessInfo.processInfo.systemUptime
    let stalled: (blockedMs: Int, context: String, first: Bool)? = locked {
      guard active else { return nil }
      let elapsed = now - lastMainBeatAt
      guard elapsed >= stallThresholdSeconds else { return nil }
      let bucket = Int(elapsed)
      guard bucket != lastReportedStallBucket else { return nil }
      lastReportedStallBucket = bucket
      let first = !wasStalled
      wasStalled = true
      return (Int(elapsed * 1000), latestContext, first)
    }
    guard let stalled else { return }
    AppUITrace.fault(
      "main-thread-stall blockedMs=\(stalled.blockedMs) context=\(stalled.context)"
    )
    // Probe the main thread's scheduler state once per stall episode. This is the
    // single fact the context label can't give us: whether main is BURNING CPU
    // (run=running → infinite loop / runaway layout) or PARKED (run=waiting →
    // blocked on a synchronous network/lock/FFI call). It narrows the hunt before
    // a full `sample`/Instruments capture pins the exact frame.
    if stalled.first {
      AppUITrace.fault("main-thread-stall \(mainThreadStateDescription())")
      AppUITrace.fault("main-thread-stall backtrace:\n\(captureMainThreadStack())")
    }
  }

  /// Read-only snapshot of the main thread's run-state and CPU usage via
  /// `thread_info`. Safe to call from the watchdog queue — it does not suspend
  /// the thread or walk its stack.
  private func mainThreadStateDescription() -> String {
    let machThread = locked { mainMachThread }
    guard machThread != 0 else { return "threadState=unavailable" }
    var info = thread_basic_info()
    // THREAD_BASIC_INFO_COUNT is a compound C macro that doesn't import into
    // Swift; derive the integer-word count from the struct size instead.
    var count = mach_msg_type_number_t(
      MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        thread_info(machThread, thread_flavor_t(THREAD_BASIC_INFO), rebound, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return "threadState=error(kr=\(kr))" }
    let runLabel: String
    switch Int32(info.run_state) {
    case TH_STATE_RUNNING: runLabel = "running"
    case TH_STATE_STOPPED: runLabel = "stopped"
    case TH_STATE_WAITING: runLabel = "waiting"
    case TH_STATE_UNINTERRUPTIBLE: runLabel = "uninterruptible"
    case TH_STATE_HALTED: runLabel = "halted"
    default: runLabel = "unknown(\(info.run_state))"
    }
    let idle = (Int32(info.flags) & TH_FLAGS_IDLE) != 0
    let hint =
      runLabel == "running"
      ? "likely-infinite-loop" : (runLabel == "waiting" ? "likely-blocking-wait" : "?")
    return
      "threadState run=\(runLabel) cpu=\(info.cpu_usage)/\(TH_USAGE_SCALE) idle=\(idle ? "Y" : "N") hint=\(hint)"
  }

  /// Capture the main thread's call stack during a stall and symbolicate it.
  ///
  /// Safety: while the main thread is suspended we do ZERO heap allocation and
  /// only issue `vm_read_overwrite` (a mach trap that cannot take the malloc
  /// lock). The frame buffer is pre-reserved before the suspend, and `dladdr`
  /// symbolication (which may allocate) runs only after the thread is resumed —
  /// otherwise, if main were suspended inside malloc, the watchdog could deadlock
  /// and never resume it.
  private func captureMainThreadStack() -> String {
    let machThread = locked { mainMachThread }
    guard machThread != 0 else { return "stack=unavailable" }

    var addresses: [UInt] = []
    addresses.reserveCapacity(64)

    guard thread_suspend(machThread) == KERN_SUCCESS else {
      return "stack=suspend-failed"
    }

    var pc: UInt = 0
    var fp: UInt = 0
    var stateOK = false
    #if arch(arm64)
    var state = arm_thread_state64_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &state) { pointer in
      pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { rebound in
          thread_get_state(machThread, thread_state_flavor_t(thread_flavor_t(ARM_THREAD_STATE64)), rebound, &count)
      }
    }
    if kr == KERN_SUCCESS {
      // Strip arm64e pointer-authentication bits (top 16) so dladdr resolves.
      pc = UInt(state.__pc) & 0x0000_FFFF_FFFF_FFFF
      fp = UInt(state.__fp)
      stateOK = true
    }
    #elseif arch(x86_64)
    var state = x86_thread_state64_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &state) { pointer in
      pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { rebound in
        thread_get_state(machThread, thread_state_flavor_t(x86_THREAD_STATE64), rebound, &count)
      }
    }
    if kr == KERN_SUCCESS {
      pc = UInt(state.__rip)
      fp = UInt(state.__rbp)
      stateOK = true
    }
    #endif

    if stateOK {
      addresses.append(pc)
      var currentFP = fp
      var depth = 0
      while currentFP != 0, depth < 48 {
        guard let savedFP = readWord(at: currentFP),
          let retAddr = readWord(at: currentFP + UInt(MemoryLayout<UInt>.size))
        else { break }
        if retAddr == 0 { break }
        addresses.append(retAddr & 0x0000_FFFF_FFFF_FFFF)
        if savedFP <= currentFP { break }  // stack grows down; saved FP is higher
        currentFP = savedFP
        depth += 1
      }
    }

    thread_resume(machThread)  // resume BEFORE symbolication (dladdr may allocate)

    guard stateOK else { return "stack=state-failed" }
    let lines = addresses.enumerated().map { index, address in
      symbolicate(address: address, frame: index)
    }
    return lines.joined(separator: "\n")
  }

  /// Read one machine word from this process's memory without crashing on a bad
  /// address (`vm_read_overwrite` returns an error instead of faulting).
  private func readWord(at address: UInt) -> UInt? {
    var value: UInt = 0
    var outSize: vm_size_t = 0
    let kr = withUnsafeMutableBytes(of: &value) { raw -> kern_return_t in
      guard let base = raw.baseAddress else { return KERN_FAILURE }
      return vm_read_overwrite(
        mach_task_self_,
        vm_address_t(address),
        vm_size_t(raw.count),
        vm_address_t(UInt(bitPattern: base)),
        &outSize)
    }
    return (kr == KERN_SUCCESS && outSize == vm_size_t(MemoryLayout<UInt>.size)) ? value : nil
  }

  private func symbolicate(address: UInt, frame: Int) -> String {
    var info = Dl_info()
    if dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 {
      let symbol = info.dli_sname.map { String(cString: $0) } ?? "?"
      let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
      let symBase = UInt(bitPattern: info.dli_saddr)
      let offset = address >= symBase ? address - symBase : 0
      return "\(frame)  \(image)  \(symbol) + \(offset)"
    }
    return "\(frame)  ???  0x" + String(address, radix: 16)
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

private func appShellRouteLog(_ message: String) {
  let tagged = "[AppShellRoute] \(message)"
  if Thread.isMainThread {
    AppUIStallWatchdog.shared.updateContext(tagged)
  }
  AppUITrace.notice(tagged)
}

enum AppShellTab: Hashable {
  case contacts
  case calls
  case chats
  case settings
  case agents
}

struct ChatRoute: Identifiable, Hashable {
  let chatId: String
  let title: String
  let peerUserId: String?
  /// Non-nil when this chat talks to an AI agent's shadow user. Carried into the
  /// engine binding so outgoing messages are routed to the agent backend instead
  /// of being E2E-encrypted to a human peer.
  let peerAgentId: String?
  /// True when this route opens a "talk to the agent" chat (header shows the
  /// agent name). Independent of `peerAgentId` so the always-available fallback
  /// surface can present as an agent chat before an agent id is known.
  let isAgent: Bool
  let avatarURI: String?
  let isGroup: Bool
  /// `type == "channel"` — profile must not list members (groups still do).
  let isChannel: Bool
  /// Signed-in role in this room when known (`owner`/`admin`/`member`).
  let myRole: String?
  let unreadCount: Int
  let initialRows: [[String: Any]]
  /// Attached agent's event-inbox mode (`per_event` / `batched_summary`). Drives
  /// whether the chat view hides agent event notifications behind the Inbox banner.
  let agentEventInboxMode: String?
  /// `"claude"` / `"codex"` / `"grok"` / `"agy"` when this chat talks to a computer-bridge agent. Drives
  /// the connect-state gate in the chat view: when no paired computer is online the
  /// composer is hidden and a Connect panel is shown instead.
  let bridgeProvider: String?
  /// Group/channel participant list, carried straight from `ChatHomeListRow.members`.
  /// Empty for DMs and for routes built before that data was available.
  let members: [[String: Any]]
  /// Canonical room metadata returned by create/list. Keeping it on the route means
  /// the very first chat/profile frame never waits for a Home refresh to learn it.
  let roomDescription: String?
  let accessType: String
  let publicSlug: String?
  let shareLink: String?
  let joinApprovalRequired: Bool
  let restrictSavingContent: Bool
  let memberCount: Int?
  let createdAt: Double

  /// Groups expose a Members list; channels do not.
  var showsMemberList: Bool { isGroup && !isChannel }

  var roomParticipantCount: Int {
    max(memberCount ?? 0, members.count)
  }

  var roomParticipantSubtitle: String {
    guard isGroup else { return "" }
    let count = roomParticipantCount
    if isChannel {
      return count == 1 ? "1 subscriber" : "\(count) subscribers"
    }
    return count == 1 ? "1 member" : "\(count) members"
  }

  var id: String { chatId }

  /// Reserved shadow-user ids for the computer-bridge agents (seeded server-side).
  static let claudeAgentUserId = "11111111-1111-1111-1111-111111111111"
  static let codexAgentUserId = "22222222-2222-2222-2222-222222222222"
  static let grokAgentUserId = "33333333-3333-3333-3333-333333333333"
  static let agyAgentUserId = "44444444-4444-4444-4444-444444444444"

  /// Resolves the bridge provider for a chat. The reserved user ids are the strong
  /// signal; the name is only consulted for confirmed agent users so a human named
  /// "claude" never trips the gate.
  static func resolveBridgeProvider(
    peerUserId: String?,
    name: String?,
    isAgent: Bool,
    agentId: String? = nil
  ) -> String? {
    let pid = peerUserId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if pid == claudeAgentUserId { return "claude" }
    if pid == codexAgentUserId { return "codex" }
    if pid == grokAgentUserId { return "grok" }
    if pid == agyAgentUserId { return "agy" }
    let aid = agentId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch aid {
    case "claude", claudeAgentUserId:
      return "claude"
    case "codex", codexAgentUserId:
      return "codex"
    case "grok", grokAgentUserId:
      return "grok"
    case "agy", "antigravity", agyAgentUserId:
      return "agy"
    default:
      break
    }
    guard isAgent else { return nil }
    switch name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "claude": return "claude"
    case "codex": return "codex"
    case "grok": return "grok"
    case "agy", "antigravity": return "agy"
    default: return nil
    }
  }

  /// Display name for a bridge provider id.
  static func bridgeDisplayName(for provider: String) -> String {
    switch provider.lowercased() {
    case "claude": return "Claude"
    case "codex": return "Codex"
    case "grok": return "Grok"
    case "agy", "antigravity": return "Agy"
    default: return provider.capitalized
    }
  }

  /// True when this route opens a "talk to the agent" chat.
  var isAgentChat: Bool { isAgent }

  /// True when the attached agent runs in inbox (batched summary) mode, so its
  /// event notifications should be surfaced via the Inbox banner instead of
  /// cluttering the transcript.
  var isAgentInboxMode: Bool {
    switch agentEventInboxMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "batched_summary", "batched", "batch", "summary":
      return true
    default:
      return false
    }
  }

  var isBuiltInAgentSurface: Bool {
    ChatHomeListRow.isBuiltInAgentChatId(chatId)
  }

  /// Whether this chat is handled locally (no server Phoenix channel). True for
  /// Saved Messages.
  var skipsServerChannel: Bool {
    chatId == "saved_messages" || isBuiltInAgentSurface
  }

  var hasPeerResponse: Bool {
    Self.rowsContainPeerResponse(initialRows, peerUserId: peerUserId, isGroup: isGroup, isAgent: isAgent)
  }

  static func rowsContainPeerResponse(
    _ rows: [[String: Any]],
    peerUserId: String?,
    isGroup: Bool,
    isAgent: Bool
  ) -> Bool {
    if isGroup || isAgent {
      return true
    }
    guard let peer = normalizedString(peerUserId)?.uppercased(), !peer.isEmpty else {
      return false
    }
    return rows.contains { row in
      let message = (row["message"] as? [String: Any]) ?? row
      if boolValue(message["isMe"]) == false {
        return true
      }
      let fromId = normalizedString(message["fromId"] ?? message["from_id"])?.uppercased()
      return fromId == peer
    }
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }

  private static func boolValue(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String {
      switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "1", "true", "yes", "on":
        return true
      case "0", "false", "no", "off":
        return false
      default:
        return nil
      }
    }
    return nil
  }

  init(
    chatId: String,
    title: String,
    peerUserId: String?,
    peerAgentId: String? = nil,
    isAgent: Bool = false,
    avatarURI: String?,
    isGroup: Bool,
    isChannel: Bool = false,
    myRole: String? = nil,
    unreadCount: Int = 0,
    initialRows: [[String: Any]],
    agentEventInboxMode: String? = nil,
    bridgeProvider: String? = nil,
    members: [[String: Any]] = [],
    roomDescription: String? = nil,
    accessType: String = "private",
    publicSlug: String? = nil,
    shareLink: String? = nil,
    joinApprovalRequired: Bool = false,
    restrictSavingContent: Bool = false,
    memberCount: Int? = nil,
    createdAt: Double = 0
  ) {
    self.chatId = chatId
    self.title = title
    self.peerUserId = peerUserId
    self.peerAgentId = peerAgentId
    // Channels are multi-party rooms. Force isGroup so isChannel can stick
    // (it used to be `isChannel && isGroup`, which dropped the flag when
    // create/open paths passed isChannel without isGroup).
    let effectiveIsGroup = isGroup || isChannel
    // A group/channel is NEVER an agent DM. Old groups created before the
    // server-side friend_* fix still carry a leaked peerUserId/peerAgentId
    // (Codex/Claude) in their cached home row; without this guard the whole
    // room opens the agent's DM surface.
    let resolvedIsAgent =
      !effectiveIsGroup && (isAgent || (peerAgentId.map { !$0.isEmpty } ?? false))
    self.isAgent = resolvedIsAgent
    self.avatarURI = avatarURI
    self.isGroup = effectiveIsGroup
    self.isChannel = isChannel
    let role = myRole?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    self.myRole = role.isEmpty ? nil : role
    self.unreadCount = max(0, unreadCount)
    self.initialRows = initialRows
    self.agentEventInboxMode = agentEventInboxMode
    self.bridgeProvider =
      bridgeProvider
      ?? (effectiveIsGroup
        ? nil
        : Self.resolveBridgeProvider(
          peerUserId: peerUserId,
          name: title,
          isAgent: resolvedIsAgent,
          agentId: peerAgentId
        ))
    self.members = members
    let description = roomDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.roomDescription = description.isEmpty ? nil : description
    let normalizedAccess = accessType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    self.accessType = normalizedAccess == "public" ? "public" : "private"
    self.publicSlug = Self.normalizedString(publicSlug)
    self.shareLink = Self.normalizedString(shareLink)
    self.joinApprovalRequired = joinApprovalRequired
    self.restrictSavingContent = restrictSavingContent
    self.memberCount = memberCount.map { max(0, $0) }
    self.createdAt = max(0, createdAt)
  }

  init(row: ChatHomeListRow) {
    // Route creation IS the tap: anchor every [ChatOpen] host-stage log to it so the
    // full tap→settled timeline reads out of one log stream.
    VibeChatOpenTap.uptime = ProcessInfo.processInfo.systemUptime
    // Same anchor, durable copy. `initial` is the row's own preview payload — when the
    // open ends up empty, this is the first thing worth knowing: whether Home handed
    // the chat any content to start from at all.
    VibeOpenTrace.shared.begin(
      chatId: row.chatId,
      detail: "initial=\(row.initialMessages.isEmpty ? row.previewRows.count : row.initialMessages.count)")
    // Groups never resolve to a bridge agent — even if a stale/cached row leaked an
    // agent peerUserId (pre-fix "group opens Codex" bug). See the designated init.
    let resolvedBridge =
      row.isGroup
      ? nil
      : ChatRoute.resolveBridgeProvider(
        peerUserId: row.peerUserId,
        name: row.title,
        isAgent: row.isAgentFriend,
        agentId: row.peerAgentId
      )
    let cachedRows = resolvedBridge == nil
      ? (row.initialMessages.isEmpty ? row.previewRows : row.initialMessages)
      : []
    NSLog(
      "[AgentRoute] ChatRoute(row:) chatId=%@ title=%@ isGroup=%@ isChannel=%@ peerUserId=%@ peerAgentId=%@ isAgentFriend=%@ resolvedBridge=%@ members=%d myRole=%@ initial=%d",
      row.chatId, row.title, row.isGroup ? "Y" : "N", row.isChannel ? "Y" : "N",
      row.peerUserId ?? "nil",
      row.peerAgentId ?? "nil", row.isAgentFriend ? "true" : "false", resolvedBridge ?? "nil",
      row.members.count, row.myRole ?? "<nil>", cachedRows.count)
    self.init(
      chatId: row.chatId,
      title: row.title,
      peerUserId: row.peerUserId,
      peerAgentId: row.peerAgentId,
      isAgent: row.isAgentFriend,
      avatarURI: row.avatarUri,
      isGroup: row.isGroup,
      isChannel: row.isChannel,
      myRole: row.myRole,
      unreadCount: row.unreadCount,
      initialRows: cachedRows,
      agentEventInboxMode: row.agentEventInboxMode,
      bridgeProvider: resolvedBridge,
      members: row.members,
      roomDescription: row.roomDescription,
      accessType: row.accessType ?? "private",
      publicSlug: row.publicSlug,
      shareLink: row.shareLink,
      joinApprovalRequired: row.joinApprovalRequired,
      restrictSavingContent: row.restrictSavingContent,
      memberCount: row.memberCount,
      createdAt: row.createdAt
    )
  }

  static func savedMessages(initialRows: [[String: Any]] = []) -> ChatRoute {
    ChatRoute(
      chatId: "saved_messages",
      title: "Saved Messages",
      peerUserId: nil,
      peerAgentId: nil,
      avatarURI: nil,
      isGroup: false,
      unreadCount: 0,
      initialRows: initialRows
    )
  }

  /// Prefer the route's roster; if empty (stale cache / opened before home refresh),
  /// fall back to the on-disk home row so group profile/members still populate.
  static func resolvedMembers(chatId: String, routeMembers: [[String: Any]]) -> [[String: Any]] {
    if !routeMembers.isEmpty { return routeMembers }
    guard let config = AppSessionConfig.current else { return routeMembers }
    let cached = ChatHomeService.cachedRows(config: config)
    if let row = cached.first(where: { $0.chatId == chatId }), !row.members.isEmpty {
      NSLog(
        "[WhoAmI] ChatRoute.resolvedMembers hydrated chatId=%@ fromCache=%d",
        String(chatId.prefix(12)),
        row.members.count
      )
      return row.members
    }
    return routeMembers
  }

  func withMembers(_ members: [[String: Any]]) -> ChatRoute {
    ChatRoute(
      chatId: chatId,
      title: title,
      peerUserId: peerUserId,
      peerAgentId: peerAgentId,
      isAgent: isAgent,
      avatarURI: avatarURI,
      isGroup: isGroup,
      isChannel: isChannel,
      myRole: myRole,
      unreadCount: unreadCount,
      initialRows: initialRows,
      agentEventInboxMode: agentEventInboxMode,
      bridgeProvider: bridgeProvider,
      members: members,
      roomDescription: roomDescription,
      accessType: accessType,
      publicSlug: publicSlug,
      shareLink: shareLink,
      joinApprovalRequired: joinApprovalRequired,
      restrictSavingContent: restrictSavingContent,
      memberCount: memberCount,
      createdAt: createdAt
    )
  }

  static func == (lhs: ChatRoute, rhs: ChatRoute) -> Bool {
    lhs.chatId == rhs.chatId && lhs.peerUserId == rhs.peerUserId
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(chatId)
    hasher.combine(peerUserId)
  }
}

struct PresentedChatRoute: Identifiable, Hashable {
  let requestID: Int
  let route: ChatRoute

  var id: Int { requestID }
}

struct PresentedChatProfileRoute: Identifiable, Hashable {
  let requestID: Int
  let route: ChatRoute

  var id: Int { requestID }
}

enum AppChatNavigationAction {
  case avatar
}

@MainActor
private enum NativeCallRouteBridge {
  @discardableResult
  static func startOutgoing(route: ChatRoute, callType: String) -> [String: Any]? {
    guard route.chatId != "saved_messages",
      let toUserId = normalizedString(route.peerUserId)
    else {
      AppToastController.shared.show("Calls are available in direct chats.")
      return nil
    }
    guard let config = AppSessionConfig.current else {
      AppToastController.shared.show("The current session is unavailable.")
      return nil
    }

    VibeNativeCallManager.shared.start()
    _ = VibeNativeCallEngine.shared.configure(config.payload)
    let now = Int(Date().timeIntervalSince1970 * 1000)
    let callId = "call_\(now)_\(UUID().uuidString.prefix(8))"
    let payload: [String: Any] = [
      "event": "call-start",
      "callId": callId,
      "callType": callType == "video" ? "video" : "voice",
      "toUserId": toUserId,
      "toUserName": route.title,
      "toUserImage": route.avatarURI ?? "",
      "chatId": route.chatId,
    ]
    let status = VibeNativeCallEngine.shared.startOutgoing(payload)
    VibeNativeCallOverlayPresenter.shared.showOutgoing(payload: payload, status: status)
    let accepted = (status["signalingAccepted"] as? Bool) ?? true
    if !accepted {
      AppToastController.shared.show("Could not start call.")
    }
    return status
  }

  private static func normalizedString(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? nil : trimmed
  }
}

@MainActor
private final class VibeNativeCallOverlayPresenter {
  static let shared = VibeNativeCallOverlayPresenter()

  private var observer: NSObjectProtocol?
  private var window: UIWindow?
  private var controller: VibeNativeCallOverlayController?

  private init() {}

  func startObserving() {
    guard observer == nil else { return }
    observer = NotificationCenter.default.addObserver(
      forName: VibeNativeCallEngine.stateDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self,
        let state = notification.userInfo?["state"] as? [String: Any]
      else { return }
      Task { @MainActor in
        self.applyEngineState(state)
      }
    }
  }

  func showOutgoing(payload: [String: Any], status: [String: Any]) {
    startObserving()
    var state = status
    for key in [
      "event", "callId", "callType", "toUserId", "toUserName", "toUserImage", "chatId",
      "signalingAccepted", "signalingQueued", "failureReason",
    ] where state[key] == nil {
      state[key] = payload[key]
    }
    if state["direction"] == nil {
      state["direction"] = "outgoing"
    }
    present(state: state, retryPayload: payload)
  }

  func refreshFromEngine() {
    startObserving()
    applyEngineState(VibeNativeCallEngine.shared.getStatus())
  }

  private func applyEngineState(_ state: [String: Any]) {
    let stateValue = normalizedString(state["state"]) ?? ""
    let direction = normalizedString(state["direction"]) ?? ""
    guard ["ringing", "starting", "connecting", "active", "failed", "ended"].contains(stateValue)
      || (stateValue == "configured" && controller != nil)
    else { return }

    if stateValue == "ended" {
      present(state: state, retryPayload: nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
        guard let self, self.controller?.callId == self.normalizedString(state["callId"] ?? state["call_id"])
        else { return }
        self.hide()
      }
      return
    }

    if direction == "incoming", stateValue == "ringing", UIApplication.shared.applicationState == .active {
      VibeNativeCallManager.shared.presentForegroundIncomingBanner(state)
      return
    }

    if controller == nil, direction == "incoming" || direction == "outgoing" || stateValue == "failed" {
      present(state: state, retryPayload: nil)
    } else {
      controller?.applyState(state, retryPayload: nil)
    }
  }

  private func present(state: [String: Any], retryPayload: [String: Any]?) {
    guard let scene = activeWindowScene() else {
      NSLog("[VibeNativeCall][Overlay] present skipped missing window scene")
      return
    }

    let controller = self.controller ?? VibeNativeCallOverlayController()
    controller.onDismiss = { [weak self] in self?.hide() }
    controller.applyState(state, retryPayload: retryPayload)

    if window == nil {
      let nextWindow = UIWindow(windowScene: scene)
      nextWindow.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 2)
      nextWindow.backgroundColor = .clear
      nextWindow.rootViewController = controller
      nextWindow.makeKeyAndVisible()
      window = nextWindow
      self.controller = controller
    } else if self.controller == nil {
      window?.rootViewController = controller
      self.controller = controller
      window?.isHidden = false
    } else {
      window?.isHidden = false
    }

    NSLog(
      "[VibeNativeCall][Overlay] present state=%@ direction=%@ callId=%@",
      normalizedString(state["state"]) ?? "-",
      normalizedString(state["direction"]) ?? "-",
      normalizedString(state["callId"] ?? state["call_id"]) ?? "-"
    )
  }

  private func hide() {
    controller?.cancelTimers()
    controller = nil
    window?.isHidden = true
    window = nil
  }

  private func activeWindowScene() -> UIWindowScene? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.first(where: { $0.activationState == .foregroundActive })
      ?? scenes.first(where: { $0.activationState == .foregroundInactive })
      ?? scenes.first
  }

  private func normalizedString(_ value: Any?) -> String? {
    guard let raw = value as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

@MainActor
private final class VibeNativeCallOverlayModel: ObservableObject {
  @Published var currentState: [String: Any] = [:]
  @Published var retryPayload: [String: Any]?
  @Published var inlineError: String?

  var onDismiss: (() -> Void)?
  private var timeoutWork: DispatchWorkItem?

  var callId: String? {
    normalizedString(currentState["callId"] ?? currentState["call_id"])
  }

  var displayName: String {
    normalizedString(currentState["toUserName"] ?? currentState["to_user_name"])
      ?? normalizedString(currentState["fromUserName"] ?? currentState["from_user_name"])
      ?? normalizedString(currentState["name"])
      ?? "Vibe Call"
  }

  var initial: String {
    displayName.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "V"
  }

  var directionTitle: String {
    let type = normalizedString(currentState["callType"] ?? currentState["call_type"]) == "video" ? "Video" : "Voice"
    switch normalizedString(currentState["direction"]) {
    case "incoming": return "Incoming \(type) Call"
    case "outgoing": return "Outgoing \(type) Call"
    default: return "\(type) Call"
    }
  }

  var statusText: String {
    if let inlineError { return inlineError }
    switch normalizedString(currentState["state"]) ?? "ringing" {
    case "ringing", "starting": return "Ringing..."
    case "connecting": return "Connecting..."
    case "active": return "Connected"
    case "failed": return friendlyFailureText
    case "ended": return "Call ended"
    default: return "Connecting..."
    }
  }

  var actionSet: VibeNativeCallOverlayActionSet {
    let stateValue = normalizedString(currentState["state"]) ?? "ringing"
    let direction = normalizedString(currentState["direction"]) ?? ""
    if stateValue == "failed" { return .failed }
    if direction == "incoming", stateValue == "ringing" { return .incoming }
    if stateValue == "ended" { return .ended }
    return .active
  }

  func applyState(_ state: [String: Any], retryPayload: [String: Any]?) {
    currentState = mergedState(existing: currentState, incoming: state)
    inlineError = nil
    if let retryPayload {
      self.retryPayload = retryPayload
    }
    if self.retryPayload == nil, normalizedString(currentState["direction"]) == "outgoing" {
      self.retryPayload = outgoingPayload(from: currentState)
    }
    scheduleTimeoutIfNeeded()
  }


  func cancelTimers() {
    timeoutWork?.cancel()
    timeoutWork = nil
  }

  func accept() {
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    applyState(VibeNativeCallEngine.shared.acceptIncoming(currentPayload()), retryPayload: nil)
  }

  func end() {
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    applyState(VibeNativeCallEngine.shared.endCall(currentPayload()), retryPayload: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
      self?.onDismiss?()
    }
  }

  func retry() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    guard var payload = retryPayload ?? outgoingPayload(from: currentState) else {
      inlineError = "Call could not start. Open the chat and try again."
      return
    }
    guard let config = AppSessionConfig.current else {
      inlineError = "Call could not start. Sign in again and retry."
      return
    }
    _ = VibeNativeCallEngine.shared.configure(config.payload)
    let now = Int(Date().timeIntervalSince1970 * 1000)
    payload["event"] = "call-start"
    payload["callId"] = "call_\(now)_\(UUID().uuidString.prefix(8))"
    payload["direction"] = "outbound"
    retryPayload = payload
    applyState(VibeNativeCallEngine.shared.startOutgoing(payload), retryPayload: payload)
  }

  func close() {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    onDismiss?()
  }

  private var friendlyFailureText: String {
    if let reason = normalizedString(currentState["failureReason"]) {
      return reason
    }
    if boolValue(currentState["signalingQueued"]) {
      return "Still waiting for the connection. You can retry the call."
    }
    return "Call could not start. Check the connection and try again."
  }

  private func scheduleTimeoutIfNeeded() {
    timeoutWork?.cancel()
    timeoutWork = nil
    let stateValue = normalizedString(currentState["state"]) ?? ""
    let direction = normalizedString(currentState["direction"]) ?? ""
    guard direction == "outgoing", ["ringing", "starting"].contains(stateValue), let callId else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self,
        self.callId == callId,
        ["ringing", "starting"].contains(self.normalizedString(self.currentState["state"]) ?? "")
      else { return }
      self.applyState(
        VibeNativeCallEngine.shared.failCall(self.currentPayload(), reason: "No answer. You can retry the call."),
        retryPayload: self.retryPayload ?? self.outgoingPayload(from: self.currentState)
      )
    }
    timeoutWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 40, execute: work)
  }

  private func currentPayload() -> [String: Any] {
    var payload = currentState
    if let callId {
      payload["callId"] = callId
    }
    if normalizedString(payload["toUserId"] ?? payload["to_user_id"]) == nil,
      let fromUserId = normalizedString(payload["fromUserId"] ?? payload["from_user_id"])
    {
      payload["toUserId"] = fromUserId
    }
    return payload
  }

  private func outgoingPayload(from state: [String: Any]) -> [String: Any]? {
    guard let toUserId = normalizedString(state["toUserId"] ?? state["to_user_id"]) else {
      return nil
    }
    return [
      "event": "call-start",
      "callType": normalizedString(state["callType"] ?? state["call_type"]) ?? "voice",
      "toUserId": toUserId,
      "toUserName": displayName,
      "toUserImage": normalizedString(state["toUserImage"] ?? state["to_user_image"]) ?? "",
      "chatId": normalizedString(state["chatId"] ?? state["chat_id"]) ?? "",
    ]
  }

  private func mergedState(existing: [String: Any], incoming: [String: Any]) -> [String: Any] {
    var next = existing
    for (key, value) in incoming where !(value is NSNull) {
      next[key] = value
    }
    return next
  }

  private func normalizedString(_ value: Any?) -> String? {
    guard let raw = value as? String else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func boolValue(_ value: Any?) -> Bool {
    switch value {
    case let bool as Bool: return bool
    case let number as NSNumber: return number.boolValue
    case let string as String:
      let raw = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      return raw == "true" || raw == "1" || raw == "yes"
    default: return false
    }
  }
}

private enum VibeNativeCallOverlayActionSet {
  case incoming
  case active
  case failed
  case ended
}

private struct VibeNativeCallOverlayView: View {
  @ObservedObject var model: VibeNativeCallOverlayModel

  var body: some View {
    ZStack {
      Color.black.opacity(0.62).ignoresSafeArea()
      Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()

      VStack(spacing: 0) {
        HStack {
          Spacer()
          if model.actionSet == .failed || model.actionSet == .ended {
            Button(action: model.close) {
              Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)
            .clipShape(Circle())
            .tint(.white.opacity(0.78))
            .accessibilityLabel("Close")
          }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)

        Spacer()

        VStack(spacing: 12) {
          Text(model.initial)
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 104, height: 104)
            .background(.white.opacity(0.14), in: Circle())
            .padding(.bottom, 18)

          Text(model.directionTitle)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.68))

          Text(model.displayName)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)

          Text(model.statusText)
            .font(.system(size: 15))
            .foregroundStyle(.white.opacity(0.78))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, 28)
        }

        Spacer()

        VibeNativeCallOverlayActions(model: model)
          .padding(.bottom, 52)
      }
    }
  }
}

private struct VibeNativeCallOverlayActions: View {
  @ObservedObject var model: VibeNativeCallOverlayModel

  var body: some View {
    HStack(spacing: 28) {
      switch model.actionSet {
      case .incoming:
        action(title: "Decline", symbol: "phone.down.fill", tint: .red, action: model.end)
        action(title: "Accept", symbol: "phone.fill", tint: .green, action: model.accept)
      case .active:
        action(title: "End", symbol: "phone.down.fill", tint: .red, action: model.end)
      case .failed:
        action(title: "Close", symbol: "xmark", tint: .white.opacity(0.16), action: model.close)
        action(title: "Retry", symbol: "arrow.clockwise", tint: .green, action: model.retry)
      case .ended:
        EmptyView()
      }
    }
  }

  private func action(title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
    VStack(spacing: 8) {
      Button(action: action) {
        Image(systemName: symbol)
          .font(.system(size: 22, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 60, height: 60)
      }
      .buttonStyle(.borderedProminent)
      .tint(tint)
      .clipShape(Circle())
      .accessibilityLabel(title)

      Text(title)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.82))
    }
  }
}

private final class VibeNativeCallOverlayController: UIHostingController<VibeNativeCallOverlayView> {
  private let model = VibeNativeCallOverlayModel()

  var onDismiss: (() -> Void)? {
    get { model.onDismiss }
    set { model.onDismiss = newValue }
  }

  var callId: String? { model.callId }

  init() {
    super.init(rootView: VibeNativeCallOverlayView(model: model))
    view.backgroundColor = .clear
  }

  @MainActor @preconcurrency required dynamic init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func applyState(_ state: [String: Any], retryPayload: [String: Any]?) {
    model.applyState(state, retryPayload: retryPayload)
  }

  func cancelTimers() {
    model.cancelTimers()
  }
}

@MainActor
final class AppShellCoordinator: ObservableObject {
  // Per-tab SwiftUI navigation paths. Contacts / Calls / Settings stay pure
  // SwiftUI pages hosted in UIHostingControllers and keep their own in-page
  // navigation through these stacks. The chat conversation is NOT here: it is
  // pushed onto the root navigation controller that wraps the whole tab bar
  // (rootNavigationController), so opening a chat is a native push z-above any
  // tab with a stable, self-owned header.
  @Published var contactsPath: [AppRoute] = []
  @Published var callsPath: [AppRoute] = []
  @Published var settingsPath: [AppRoute] = []
  // Mirror of the active tab so SwiftUI pages that read it (the chat home's
  // search trigger, Settings) stay in sync with the UIKit tab bar.
  @Published var selectedTab: AppShellTab = .chats
  // Bumped to ask the chat home to present the contact-search sheet.
  @Published var chatSearchPresentationRequestID: Int = 0

  // UIKit handles, set by AppRootTabBarController / the root factory.
  weak var tabBarController: UITabBarController?
  // The navigation controller that *wraps the whole tab bar controller*. A chat
  // conversation is pushed here so it slides in z-above ALL four tabs
  // (Calls / Contacts / Home / Settings) — openable from any tab, never nested
  // inside the Chats tab.
  weak var rootNavigationController: UINavigationController?

  /// Select a tab in both our mirror and the UIKit tab bar.
  func selectTab(_ tab: AppShellTab) {
    if selectedTab != tab {
      selectedTab = tab
    }
    guard let index = AppRootTabBarController.tabIndex(for: tab),
      let tabBarController, tabBarController.selectedIndex != index
    else { return }
    tabBarController.selectedIndex = index
  }

  func openChat(_ route: ChatRoute) {
    appShellRouteLog(
      "openChat requested chatId=\(route.chatId) title=\(route.title) fromTab=\(selectedTab)")
    if route.isBuiltInAgentSurface {
      appShellRouteLog(
        "openChat redirecting legacy built-in agent chatId=\(route.chatId) to agent transport")
      openAgentConversation()
      return
    }
    guard let nav = rootNavigationController else {
      appShellRouteLog("openChat skipped: no root navigation controller")
      return
    }
    // Open the chat in place over whatever tab the user is on — no tab switch,
    // no nesting in Home.
    if let top = nav.topViewController as? ChatConversationController, top.chatId == route.chatId {
      appShellRouteLog("openChat ignored duplicate chatId=\(route.chatId)")
      return
    }
    let isDark = nav.traitCollection.userInterfaceStyle == .dark
    let controller = ChatConversationController(
      route: route,
      isDark: isDark,
      onClose: { [weak nav] in
        guard let nav, nav.viewControllers.count > 1 else { return }
        nav.popViewController(animated: true)
      }
    )
    // Stage a bounded REAL transcript behind the still-visible Home page at the exact
    // destination bounds. The previous commit-first path mounted cells after UIKit had
    // attached the destination: that could paint a full-screen chat before the starting
    // transform, then replace/re-pin rows during the slide. Prestaging keeps frame one
    // populated without exposing collection work or geometry changes mid-transition.
    let prePushStartedAt = ProcessInfo.processInfo.systemUptime
    controller.prepareForNavigationPush(in: nav)
    NSLog(
      "[ChatOpen] host-stage pre-push prestage %dms chatId=%@",
      Int((ProcessInfo.processInfo.systemUptime - prePushStartedAt) * 1000),
      String(route.chatId.prefix(12)))
    // The conversation is full-screen above the tab bar controller, so it
    // covers the tab bar by z-order; no hidesBottomBarWhenPushed needed.
    nav.pushViewController(controller, animated: true)
    controller.probePrestageParkingAfterPush(container: nav.view)
  }

  /// Open the AI agent conversation surface, reusing the existing
  /// `ChatNativeAgentView` (which streams over the `agent:<userId>` socket) hosted
  /// in `ChatAgentConversationController` with the same chat composer.
  func openAgentConversation() {
    guard let nav = rootNavigationController else {
      appShellRouteLog("openAgentConversation skipped: no root navigation controller")
      return
    }
    if nav.topViewController is ChatAgentConversationController {
      appShellRouteLog("openAgentConversation ignored duplicate")
      return
    }
    let isDark = nav.traitCollection.userInterfaceStyle == .dark
    let controller = ChatAgentConversationController(
      isDark: isDark,
      onClose: { [weak nav] in
        guard let nav, nav.viewControllers.count > 1 else { return }
        nav.popViewController(animated: true)
      }
    )
    let prePushStartedAt = ProcessInfo.processInfo.systemUptime
    controller.prepareForNavigationPush(in: nav)
    NSLog(
      "[AgentOpen] host-stage pre-push prestage %dms",
      Int((ProcessInfo.processInfo.systemUptime - prePushStartedAt) * 1000))
    nav.pushViewController(controller, animated: true)
  }

  func openStory() {
    guard let nav = rootNavigationController, nav.presentedViewController == nil else { return }
    nav.present(AppNativeStoryViewController(), animated: true)
  }

  /// Pop back to the tab shell. Native back/swipe handle the common case; this
  /// supports programmatic closes.
  func closePresentedChat(requestID: Int? = nil) {
    guard let nav = rootNavigationController, nav.viewControllers.count > 1 else { return }
    nav.popToRootViewController(animated: true)
  }

  func openChatSearch() {
    print("AppShellCoordinator: openChatSearch requested")
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      if self.selectedTab != .chats {
        print("AppShellCoordinator: switching tab to chats before search")
        self.selectTab(.chats)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          print("AppShellCoordinator: triggering chatSearchPresentationRequestID after delay")
          self.chatSearchPresentationRequestID &+= 1
        }
      } else {
        print("AppShellCoordinator: already on chats tab, triggering search immediately")
        self.chatSearchPresentationRequestID &+= 1
      }
    }
  }
}

private enum ChannelRoomLinkJoinResult {
  case opened(ChatRoute)
  case pending(String)
}

/// What a share link points at. `handle` is the Telegram-style bare `@name` form, which
/// the server disambiguates (person, agent, or channel slug) because those three share
/// one namespace.
enum VibeShareLinkTarget: Equatable {
  case room(String)
  case handle(String)
  case user(String)
  case chat(String)
}

/// Single ingress for every Vibe link — room links (`/r/`, `/j/`), `@handle` links, and
/// the `vibe://` deep links the web preview page redirects to. AppDelegate can receive a
/// URL before authentication or before the tab shell exists, so the router retains one
/// pending target and resolves it only after the authenticated coordinator registers.
@MainActor
final class VibeRoomLinkRouter {
  static let shared = VibeRoomLinkRouter()

  private weak var coordinator: AppShellCoordinator?
  private var pendingTarget: VibeShareLinkTarget?
  private var joinTask: Task<Void, Never>?

  private init() {}

  func register(coordinator: AppShellCoordinator) {
    self.coordinator = coordinator
    processPendingIfPossible()
  }

  func handle(url: URL) {
    guard let target = Self.target(from: url) else { return }
    pendingTarget = target
    processPendingIfPossible()
  }

  /// Opens a link the user tapped inside the app (share sheet paste, chat text, QR scan).
  func handle(target: VibeShareLinkTarget) {
    pendingTarget = target
    processPendingIfPossible()
  }

  private func processPendingIfPossible() {
    guard joinTask == nil, let target = pendingTarget, let coordinator,
      let config = AppSessionConfig.current
    else { return }
    pendingTarget = nil
    joinTask = Task { @MainActor [weak self, weak coordinator] in
      defer { self?.joinTask = nil }
      do {
        try await self?.open(target: target, config: config, coordinator: coordinator)
      } catch {
        AppToastController.shared.show(error.localizedDescription)
      }
      self?.processPendingIfPossible()
    }
  }

  private func open(
    target: VibeShareLinkTarget,
    config: AppSessionConfig,
    coordinator: AppShellCoordinator?
  ) async throws {
    switch target {
    case .room(let value):
      switch try await ChannelRoomLinkService.join(value: value, config: config) {
      case .opened(let route):
        coordinator?.openChat(route)
      case .pending(let message):
        AppToastController.shared.show(message)
      }

    case .handle(let handle):
      // One server call says what the handle is; then reuse the ordinary open paths.
      switch try await VibeShareLinkResolver.resolve(handle: handle, config: config) {
      case .room(let value):
        try await open(target: .room(value), config: config, coordinator: coordinator)
      case .user(let userId):
        try await openDirectMessage(userId: userId, config: config, coordinator: coordinator)
      default:
        AppToastController.shared.show("That Vibe link could not be found.")
      }

    case .user(let userId):
      try await openDirectMessage(userId: userId, config: config, coordinator: coordinator)

    case .chat(let chatId):
      let key = chatId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if let row = ChatHomeService.cachedRows(config: config)
        .first(where: { $0.chatId.lowercased() == key })
      {
        coordinator?.openChat(ChatRoute(row: row))
      } else {
        AppToastController.shared.show("Open that chat from your chat list.")
      }
    }
  }

  /// Same steps as opening a contact from search: fetch the peer (for its public key and
  /// agent flags), create-or-reuse the DM, then push the chat.
  private func openDirectMessage(
    userId: String,
    config: AppSessionConfig,
    coordinator: AppShellCoordinator?
  ) async throws {
    // Instant path — the same one `openChat(for:)` already has, and the reason tapping a
    // username (in a forwarded header, a mention, a deep link) felt slow while tapping the
    // same person in the chat list was immediate: this path always awaited TWO sequential
    // round-trips first (contact search for the public key, then create-or-reuse the DM)
    // before it pushed anything. When the DM is already on the home list there is nothing to
    // resolve — push it now and let the peer fetch refresh the key behind the open.
    let peerKey = userId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !peerKey.isEmpty,
      let existing = ChatHomeService.cachedRows(config: config)
        .first(where: {
          ($0.peerUserId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == peerKey && !$0.isGroup
        })
    {
      coordinator?.openChat(ChatRoute(row: existing))
      Task.detached {
        guard
          let user = try? await ContactSearchService.search(config: config, query: userId).first,
          let publicKey = user.publicKey, !publicKey.isEmpty
        else { return }
        _ = ChatEngine.shared.cachePeerPublicKey([
          "chatId": existing.chatId,
          "peerUserId": user.userID,
          "publicKey": publicKey,
        ])
      }
      return
    }

    guard let user = try await ContactSearchService.search(config: config, query: userId).first
    else {
      AppToastController.shared.show("That Vibe user could not be found.")
      return
    }

    let isBridgeAgent = user.bridgeProvider != nil || user.isAgent
    let result = try await ChatDirectMessageService.startChat(
      config: config,
      friendID: user.userID
    )

    if let publicKey = user.publicKey, !publicKey.isEmpty {
      _ = ChatEngine.shared.cachePeerPublicKey([
        "chatId": result.chatID,
        "peerUserId": user.userID,
        "publicKey": publicKey,
      ])
    }

    coordinator?.openChat(
      ChatRoute(
        chatId: result.chatID,
        title: user.username,
        peerUserId: user.userID,
        peerAgentId: user.bridgeAgentRouteId,
        isAgent: isBridgeAgent,
        avatarURI: ChatAvatarURLResolver.resolve(
          rawAvatar: user.profileImage,
          peerUserId: user.userID,
          chatId: result.chatID,
          preferPushAvatar: false
        ),
        isGroup: false,
        initialRows: result.messages,
        bridgeProvider: user.bridgeProvider
      )
    )
  }

  /// Pure parsing — `nonisolated` so AppDelegate can classify a URL before hopping to the
  /// main actor (and so an unrecognized `vibe://` host, e.g. the OAuth callback scheme,
  /// is rejected here rather than mistaken for a room link).
  nonisolated static func target(from url: URL) -> VibeShareLinkTarget? {
    if url.scheme?.lowercased() == "vibe" {
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
      let query = { (key: String) -> String? in
        components?.queryItems?.first(where: { $0.name == key })?.value?
          .trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
      }

      switch url.host?.lowercased() {
      case "u", "user", "handle":
        // The preview page carries the resolved id when it has one, so a tap can skip
        // straight to the DM; the handle is the fallback.
        if let userId = query("userId") ?? query("friendId") { return .user(userId) }
        if let handle = query("handle") ?? query("username") { return .handle(handle) }
        return nil

      case "chat":
        if let chatId = query("chatId") { return .chat(chatId) }
        if let friendId = query("friendId") { return .user(friendId) }
        return nil

      case "room-link", "r", "join", "j":
        for key in ["link", "token", "slug", "value"] {
          if let value = query(key) { return .room(value) }
        }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? nil : .room(path)

      default:
        // Not a share link (e.g. vibe://platforms/oauth, which ASWebAuthenticationSession
        // consumes itself). Leave it alone.
        return nil
      }
    }

    let parts = url.pathComponents.filter { $0 != "/" }
    if parts.count >= 2, ["r", "j"].contains(parts[parts.count - 2]) {
      return .room(url.absoluteString)
    }
    // https://<share host>/<handle>
    if parts.count == 1, let handle = parts.first?.nilIfBlank,
      !VibeShareLinks.isReservedHandle(handle)
    {
      return .handle(handle)
    }
    return nil
  }
}

/// Canonical share-link shapes, mirroring the server's `Vibe.Links`. The server is the
/// source of truth for links it hands out (`shareLink`, `shareUrl`, `publicLink`); this
/// only builds the fallback form and renders links for display.
enum VibeShareLinks {
  /// Single-segment paths the web app owns — never a user handle.
  private static let reservedHandles: Set<String> = [
    "about", "admin", "agent", "agents", "api", "app", "assets", "blog", "bridge",
    "dashboard", "docs", "download", "fonts", "health", "help", "images", "j", "l",
    "login", "logout", "pricing", "privacy", "r", "register", "robots", "settings",
    "signup", "static", "support", "terms", "u", "uploads", "user", "users", "vibe",
    "favicon.ico", "logo.png", "robots.txt", "sw.js", "manifest.json", "index.html",
  ]

  static func isReservedHandle(_ handle: String) -> Bool {
    reservedHandles.contains(handle.lowercased())
  }

  /// Base the app falls back to when the server did not supply a link. Matches the
  /// server default (the API host is what actually resolves these paths today).
  static var baseURLString: String {
    var base =
      (AppSessionConfig.current?.apiBaseURLString).flatMap { $0.nilIfBlank }
      ?? "https://api.vibegram.io"
    while base.hasSuffix("/") { base.removeLast() }
    if base.lowercased().hasSuffix("/api") { base = String(base.dropLast(4)) }
    return base
  }

  static func profileURL(username: String) -> String? {
    guard let handle = username.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
      .nilIfBlank
    else { return nil }
    return "\(baseURLString)/\(handle.lowercased())"
  }

  /// Absolute form of a server link. Mirrors `Vibe.Links.room_url/1`: relative `/r/…` and
  /// `/j/…` paths get the share host, a bare slug is treated as a public channel handle,
  /// and an already-absolute URL is left exactly as the server sent it.
  static func absolute(_ pathOrURL: String?) -> String? {
    guard let value = pathOrURL?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
    else { return nil }
    if value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") {
      return value
    }
    if value.hasPrefix("/") { return baseURLString + value }
    return "\(baseURLString)/r/\(value)"
  }

  /// `https://host/path` -> `host/path`, the form the UI shows.
  static func display(_ link: String?) -> String? {
    guard var value = link?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else {
      return nil
    }
    for prefix in ["https://", "http://"] where value.lowercased().hasPrefix(prefix) {
      value = String(value.dropFirst(prefix.count))
    }
    while value.hasSuffix("/") { value.removeLast() }
    return value.nilIfBlank
  }
}

/// Asks the server what a bare `@handle` points at (person, agent, or channel).
private enum VibeShareLinkResolver {
  static func resolve(handle: String, config: AppSessionConfig) async throws
    -> VibeShareLinkTarget
  {
    let cleaned = handle.trimmingCharacters(in: CharacterSet(charactersIn: "@ /"))
    guard !cleaned.isEmpty else { throw ChatDirectMessageServiceError.invalidPayload }

    var base = config.apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    let pathBase = base.lowercased().hasSuffix("/api") ? base : "\(base)/api"
    guard
      var components = URLComponents(string: "\(pathBase)/links/resolve")
    else { throw ChatDirectMessageServiceError.invalidURL }
    components.queryItems = [URLQueryItem(name: "handle", value: cleaned)]
    guard let url = components.url else { throw ChatDirectMessageServiceError.invalidURL }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 14
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await VibeHTTP.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw ChatDirectMessageServiceError.invalidResponse
    }

    // An older server has no resolver: fall back to treating the handle as a room slug,
    // which is what every pre-existing public link was.
    if http.statusCode == 404 || http.statusCode == 405 {
      return .room(cleaned)
    }
    guard (200...299).contains(http.statusCode) else {
      throw ChatDirectMessageServiceError.http(
        http.statusCode, String(data: data, encoding: .utf8) ?? "")
    }

    guard
      let payload = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        as? [String: Any],
      let target = payload["target"] as? [String: Any],
      let kind = (target["kind"] as? String)?.lowercased()
    else { throw ChatDirectMessageServiceError.invalidPayload }

    switch kind {
    case "channel":
      let slug = (target["public_slug"] as? String) ?? cleaned
      return .room("/r/\(slug)")
    case "user", "agent":
      guard let userId = (target["user_id"] as? String)?.nilIfBlank else {
        throw ChatDirectMessageServiceError.invalidPayload
      }
      return .user(userId)
    default:
      throw ChatDirectMessageServiceError.invalidPayload
    }
  }
}

private enum ChannelRoomLinkService {
  static func join(value: String, config: AppSessionConfig) async throws -> ChannelRoomLinkJoinResult {
    let active = AppSessionConfig.current ?? config
    do {
      return try await joinOnce(value: value, config: active)
    } catch let error as ChatDirectMessageServiceError {
      guard error.isSessionExpired else { throw error }
      let refreshed = try await AppSessionRefreshService.refresh(config: active)
      return try await joinOnce(value: value, config: refreshed)
    }
  }

  private static func joinOnce(
    value: String, config: AppSessionConfig
  ) async throws -> ChannelRoomLinkJoinResult {
    let request = try request(value: value, config: config)
    let payload: [String: Any]
    switch config.transportMode {
    case .offline:
      throw ChatDirectMessageServiceError.transportUnavailable("offline")
    case .bridgeText:
      throw ChatDirectMessageServiceError.transportUnavailable("bridge_text")
    case .direct:
      payload = try await perform(request, session: PacketRuntime.shared.session())
    }

    let status = normalizedString(payload["status"])?.lowercased()
    if status == "pending" || status == "approval_required" {
      let message = normalizedString(payload["message"])
        ?? "Your request to join was sent to the channel administrators."
      return .pending(message)
    }

    let room = (payload["room"] as? [String: Any]) ?? payload
    guard let row = ChatHomeListRow.parse(room) else {
      throw ChatDirectMessageServiceError.invalidPayload
    }
    if let current = AppSessionConfig.current {
      ChatHomeService.upsertCachedRow(row, config: current)
    }
    return .opened(ChatRoute(row: row))
  }

  private static func request(value: String, config: AppSessionConfig) throws -> URLRequest {
    var base = config.apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    let pathBase = base.lowercased().hasSuffix("/api") ? base : "\(base)/api"
    guard let url = URL(string: "\(pathBase)/channel/links/join") else {
      throw ChatDirectMessageServiceError.invalidURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["link": value])
    return request
  }

  private static func perform(
    _ request: URLRequest, session: URLSession
  ) async throws -> [String: Any] {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw ChatDirectMessageServiceError.invalidResponse
    }
    guard (200...299).contains(http.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw ChatDirectMessageServiceError.http(http.statusCode, body)
    }
    guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ChatDirectMessageServiceError.invalidPayload
    }
    return payload
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
  }
}

@MainActor
private final class ChatsViewModel: ObservableObject {
  /// Home carries only enough recent raw rows to paint the first chat viewport. The
  /// complete history remains in ChatEngine and attaches after the navigation push.
  private static let chatFirstPaintTailLimit = 16
  @Published var rows: [ChatHomeListRow] = []
  @Published var archivedRows: [ChatHomeListRow] = []
  @Published var isLoading = false
  @Published var isLoadingArchived = false
  /// Kept for compatibility with the existing view state, but it represents an HTTP
  /// reachability failure now. A realtime-socket reconnect must not label usable cached
  /// chats as generally offline when `/api/chats` is succeeding.
  @Published var isConnecting = false
  /// True while a home-list fetch is in flight *and* we are already connected.
  @Published var isListUpdating = false
  @Published var isWaitingForNetwork = false
  @Published var errorMessage: String?
  @Published var hasLoaded = false
  @Published var hasLoadedArchived = false

  /// Hard-refreshed principal header: Connecting → Updating → Chats.
  /// Connecting only for a proved list-network failure — not socket bootstrap noise.
  var headerState: AppHomeHeaderState {
    if isWaitingForNetwork { return .connecting }
    if isListUpdating || isLoading { return .updating }
    return .ready
  }

  private var backgroundRefreshTask: Task<Void, Never>?
  private var inflightRefreshTask: Task<Void, Never>?
  private var trailingRefreshRequested = false
  private var agentConversationObserver: NSObjectProtocol?
  private var realtimeMessageObserver: NSObjectProtocol?
  private var bridgeStatusObserver: NSObjectProtocol?
  private var foregroundObserver: NSObjectProtocol?
  /// The launch activation is already followed by `loadIfNeeded`'s cached-start refresh.
  /// Treating that same activation as a resume queued a second `/api/chats` trip and a
  /// duplicate history/prewarm pass while the user had begun scrolling.
  private var hasObservedInitialForegroundActivation = false
  private var realtimeRefreshTask: Task<Void, Never>?
  /// Edge detector for the socket coming back up, so one reconnect reconciles once.
  private var wasEngineConnected = false
  /// Wall clock of the last completed `/api/chats` round trip, so realtime traffic
  /// can never chain fetches back to back (see `scheduleRealtimeRefresh`).
  private var lastListFetchFinishedAt: TimeInterval = 0
  private static let realtimeRefreshMinInterval: TimeInterval = 1.5
  private var locallyRemovedChatIDs = Set<String>()
  private var projectedMessageIDsByChat = [String: String]()
  /// Message tombstones projected into Home immediately. A list request already in
  /// flight can legally return the pre-delete preview; filtering it here prevents that
  /// stale response from resurrecting the message after the user navigates back.
  private var locallyDeletedMessageIDsByChat = [String: Set<String>]()
  private var warmingFirstPaintTailChatIDs = Set<String>()

  init() {
    // If this model is created after UIKit already delivered launch activation, the
    // next didBecomeActive is a genuine resume and must not be discarded.
    hasObservedInitialForegroundActivation = UIApplication.shared.applicationState == .active
    refreshConnectionState()

    agentConversationObserver = NotificationCenter.default.addObserver(
      forName: ChatNativeAgentView.conversationsDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.rows = ChatHomeService.rowsIncludingBuiltInAgent(self.rows)
      }
    }

    // A message arrived in one of this user's chats — from a peer OR mirrored from
    // the user's own other device (server emits `new_message` on the user topic,
    // ChatEngine turns it into this signal). Refresh the list in near-real-time so a
    // message sent on the phone shows on the laptop's chat list without a re-open.
    realtimeMessageObserver = NotificationCenter.default.addObserver(
      forName: ChatEngine.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let reason = note.userInfo?["reason"] as? String
        let chatID = Self.normalizedString(note.userInfo?["chatId"])
        // Connection tree always hard-refreshes on engine status churn.
        if reason == "connectionStateChanged"
          || reason == "configure"
          || reason == "engineError"
        {
          self.refreshConnectionState()
          // The socket coming back up is the moment to reconcile whatever it could not
          // deliver while it was down — a background trip, a network change, a server
          // restart. The user topic replays nothing on rejoin, so without this Home can
          // sit on pre-drop state indefinitely even though a push already announced the
          // message.
          Self.resolveEngineConnected { [weak self] connected in
            guard let self else { return }
            if connected, !self.wasEngineConnected {
              self.refreshAfterConnectivityGap(trigger: "reconnect")
            }
            self.wasEngineConnected = connected
          }
        }
        switch reason {
        case "chatCleared":
          if let chatID {
            ChatListView.clearWarmTranscriptSnapshot(chatId: chatID)
            self.removeLocalChat(chatID: chatID, persist: true)
          }
        case "remoteNewMessage":
          if let chatID {
            // The user topic also receives mirrors of messages sent from this
            // device/another device. Project the actual latest row before changing
            // the badge so a self-send never creates a fake "1" on an agent DM.
            // The engine now ingests the mirrored message before posting this, so the
            // projection reads the REAL new row instead of the previous newest one.
            self.applyEngineProjection(
              chatID: chatID,
              reason: "remoteNewMessage",
              changedMessageID: Self.normalizedString(note.userInfo?["messageId"]),
              changedMessageWasInserted: note.userInfo?["inserted"] as? Bool,
              chatIsOnScreen: (note.userInfo?["chatIsOnScreen"] as? Bool) ?? false
            )
          }
          self.scheduleRealtimeRefresh()
        case "chatMessageDeleted":
          if let chatID {
            self.applyEngineProjection(
              chatID: chatID,
              reason: reason ?? "",
              changedMessageID: Self.normalizedString(
                note.userInfo?["messageId"] ?? note.userInfo?["message_id"]),
              chatIsOnScreen: (note.userInfo?["chatIsOnScreen"] as? Bool) ?? true
            )
          }
          // The engine projection is already authoritative and instant. Do not start a
          // list fetch whose response may have been generated before the delete commit.
        case "chatMessageInserted", "chatMessageEdited", "chatMessageChanged",
          "chatMessageReactionChanged", "messageStatusChanged":
          if let chatID {
            // Mutations can arrive from a mounted chat topic or from the user topic
            // while the conversation is closed. Only insert/new-message reasons can
            // change unread counts; status/edit projection is content-only.
            self.applyEngineProjection(
              chatID: chatID,
              reason: reason ?? "",
              changedMessageID: Self.normalizedString(note.userInfo?["messageId"]),
              chatIsOnScreen: (note.userInfo?["chatIsOnScreen"] as? Bool) ?? true
            )
          }
          // Receipts already updated the engine row/status indices. Repaint Home from
          // that local projection immediately; a list fetch would add latency and can
          // race the newer receipt with an older HTTP snapshot.
          if reason != "messageStatusChanged" {
            self.scheduleRealtimeRefresh()
          }
        case "chatDelta", "chatRowsReloaded":
          if let chatID {
            // History/event ingestion already mutated the engine before either signal is
            // posted. Project that local authority into Home in this same main-loop beat
            // and grow its first-frame warm snapshot as well. Previously Home ignored
            // these signals: the log showed 51→55 rows at 21:25:23, but a tap 21 seconds
            // later still carried 16 and only became 59 after viewDidAppear.
            self.applyEngineProjection(
              chatID: chatID,
              reason: reason ?? "",
              changedMessageID: nil,
              chatIsOnScreen: false
            )
          }
        case "remoteChatMutationMiss":
          // The compact canonical edit row is intentionally bounded. If it was absent
          // (old server or oversized metadata), keep the current non-empty first-paint
          // tail and reconcile Home in the background.
          self.scheduleRealtimeRefresh()
        case "agentProgress":
          // Render active bridge work from the local engine immediately. Fetching Home
          // here races the stream and replaces it with an older server preview, which is
          // why every agent row used to remain on "Start session" while it was working.
          if let chatID, self.applyAgentProgress(chatID: chatID) {
            break
          }
          self.scheduleRealtimeRefresh()
        default:
          break
        }
      }
    }

    // A push can land while the app is suspended, and the socket that would have carried
    // the same signal is down for the whole trip. Nothing replays it on the way back, so
    // returning to the foreground has to reconcile the list itself — otherwise Home shows
    // the state it had before the trip while a notification for a newer message is
    // sitting on the lock screen.
    foregroundObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didBecomeActiveNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard let self else { return }
        if !self.hasObservedInitialForegroundActivation {
          self.hasObservedInitialForegroundActivation = true
          AppUITrace.notice("ChatsViewModel resume-refresh skipped initial activation")
          return
        }
        self.refreshAfterConnectivityGap(trigger: "didBecomeActive")
      }
    }

    bridgeStatusObserver = NotificationCenter.default.addObserver(
      forName: AgentPairingService.statusDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      Task { @MainActor [weak self] in
        guard let self else { return }
        // The status lives outside ChatHomeListRow, so publish the existing rows
        // again to reconfigure visible cells as tasks start and finish.
        let status = (note.object as? AgentBridgeStatus) ?? AgentPairingService.lastStatusSnapshot
        let bridgeRows = self.rows.filter(\.isBridgeAgentSurface)
        let matches = bridgeRows.map { row in
          let provider = ChatHomeListRow.bridgeProvider(
            peerUserId: row.peerUserId,
            name: row.title,
            isAgent: row.isAgentFriend,
            agentId: row.peerAgentId
          )
          let isLive = ChatHomeCardCell.hasRunningBridgeTask(chatId: row.chatId, provider: provider)
          return "\(provider ?? "?"):\(String(row.chatId.prefix(12)))=\(isLive ? "live" : "idle")"
        }.joined(separator: ",")
        AppUITrace.notice(
          "ChatHome bridgeStatus tasks=\(status?.runningTasks.count ?? 0) rows=\(bridgeRows.count) [\(matches)]"
        )
        self.rows = Array(self.rows)
      }
    }
  }

  deinit {
    backgroundRefreshTask?.cancel()
    inflightRefreshTask?.cancel()
    realtimeRefreshTask?.cancel()
    if let agentConversationObserver {
      NotificationCenter.default.removeObserver(agentConversationObserver)
    }
    if let realtimeMessageObserver {
      NotificationCenter.default.removeObserver(realtimeMessageObserver)
    }
    if let bridgeStatusObserver {
      NotificationCenter.default.removeObserver(bridgeStatusObserver)
    }
    if let foregroundObserver {
      NotificationCenter.default.removeObserver(foregroundObserver)
    }
  }

  /// True only when the socket is known-up (not mid-bootstrap).
  static func isEngineConnected() -> Bool {
    statusIsConnected(ChatEngine.shared.getStatus())
  }

  /// ``isEngineConnected()`` without blocking the main thread. See `ChatEngine.status(_:)`.
  ///
  /// Answers late rather than never, which matters: the caller uses the result to spot a
  /// `false → true` edge and reconcile what the socket missed while it was down.
  /// Defaulting to `false` on an unavailable read would be non-blocking too, but it
  /// could swallow the edge entirely if no further status change followed, and a Home
  /// screen stuck on pre-drop state is a worse bug than the stall.
  static func resolveEngineConnected(_ completion: @escaping (Bool) -> Void) {
    ChatEngine.shared.status { completion(statusIsConnected($0)) }
  }

  private static func statusIsConnected(_ status: [String: Any]) -> Bool {
    if (status["connected"] as? Bool) == true { return true }
    let stateValue =
      (status["state"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    return stateValue == "native-socket-open" || stateValue == "connected-shadow"
  }

  /// Network off / server unreachable / transport blocked — NOT ordinary bootstrap.
  static func isOfflineOrBlockedToServer() -> Bool {
    let status = ChatEngine.shared.getStatus()
    if (status["connected"] as? Bool) == true { return false }
    let stateValue =
      (status["state"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
    if stateValue == "native-socket-open" || stateValue == "connected-shadow" {
      return false
    }
    // Explicit dead / blocked states only.
    if stateValue == "offline"
      || stateValue == "disconnected"
      || stateValue == "native-socket-closed"
      || stateValue == "native-connect-stale"
      || stateValue == "native-config-missing"
      || stateValue.contains("disconnect")
      || stateValue.contains("unreachable")
      || stateValue.contains("fail")
      || stateValue.contains("error")
    {
      return true
    }
    // Mid-bootstrap / configuring / connecting-native-presence → not "Connecting".
    return false
  }

  private func refreshConnectionState() {
    // Socket health and HTTP reachability are separate. Cached chats remain fully usable
    // while Phoenix reconnects; only an actual failed list request may put Home into the
    // Connecting state. The engine still reconnects independently on foreground/path.
    let next = isWaitingForNetwork && Self.isOfflineOrBlockedToServer()
    if isConnecting != next {
      isConnecting = next
    }
    // Offline never shows "Updating" — clear list-update flag when we drop offline.
    if next, isListUpdating {
      isListUpdating = false
    }
  }

  /// Debounce a light, row-preserving refresh so bursts of incoming messages (group
  /// traffic) coalesce into one fetch instead of a storm. No spinner — the list just
  /// updates its previews/unread in place.
  /// Reconcile after a window in which realtime delivery could not reach this device
  /// (backgrounded, socket down). Rides the same debounce/rate limit as ordinary
  /// realtime traffic, so a reconnect storm still costs one list fetch.
  private func refreshAfterConnectivityGap(trigger: String) {
    guard hasLoaded else { return }
    AppUITrace.notice("ChatsViewModel resume-refresh trigger=\(trigger)")
    scheduleRealtimeRefresh()
  }

  private func scheduleRealtimeRefresh() {
    guard hasLoaded else { return }
    realtimeRefreshTask?.cancel()
    // Debounce (bursts coalesce) AND rate-limit (consecutive bursts can't chain
    // fetches). Without the floor, any signal arriving faster than one fetch takes
    // keeps `trailingRefreshRequested` set and Home refetches the whole list
    // continuously — one 25s media upload produced ~30 back-to-back `/api/chats`
    // round trips, each one competing with the upload for the same link.
    let sinceLastFetch = ProcessInfo.processInfo.systemUptime - lastListFetchFinishedAt
    let cooldown = max(0, Self.realtimeRefreshMinInterval - sinceLastFetch)
    let delay = max(0.18, cooldown)
    realtimeRefreshTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
      guard !Task.isCancelled, let self else { return }
      await self.refresh(preserveRows: true)
    }
  }

  func removeLocalChat(chatID: String, persist: Bool) {
    let normalizedChatID = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedChatID.isEmpty else { return }
    locallyRemovedChatIDs.insert(normalizedChatID)
    projectedMessageIDsByChat.removeValue(forKey: normalizedChatID)
    locallyDeletedMessageIDsByChat.removeValue(forKey: normalizedChatID)

    let previousRows = rows.count
    let previousArchivedRows = archivedRows.count
    rows.removeAll { $0.chatId == normalizedChatID }
    archivedRows.removeAll { $0.chatId == normalizedChatID }
    if persist, let config = AppSessionConfig.current {
      ChatHomeService.removeCachedChat(chatID: normalizedChatID, config: config)
    }
    if previousRows != rows.count || previousArchivedRows != archivedRows.count {
      AppUITrace.notice(
        "ChatsViewModel localRemove chatId=\(String(normalizedChatID.prefix(12))) rows=\(rows.count) archived=\(archivedRows.count)"
      )
    }
  }

  func restoreLocalRow(_ row: ChatHomeListRow) {
    locallyRemovedChatIDs.remove(row.chatId)
    projectedMessageIDsByChat.removeValue(forKey: row.chatId)
    locallyDeletedMessageIDsByChat.removeValue(forKey: row.chatId)
    rows = Self.upserting(row, into: rows)
    if let config = AppSessionConfig.current {
      ChatHomeService.upsertCachedRow(row, config: config)
    }
  }

  /// Project the canonical create response into Home before any background list
  /// fetch. This makes Back from a just-created room deterministic even when
  /// `/api/chats` is slow or the socket has not observed the new membership yet.
  func projectCreatedRoom(_ route: ChatRoute) {
    let nowMs = Date().timeIntervalSince1970 * 1_000.0
    let createdAt = route.createdAt > 0 ? route.createdAt : nowMs
    var payload: [String: Any] = [
      "chatId": route.chatId,
      "type": route.isChannel ? "channel" : "group",
      "isGroup": true,
      "isChannel": route.isChannel,
      "name": route.title,
      "role": route.myRole ?? "owner",
      "members": route.members,
      "memberCount": max(route.roomParticipantCount, route.members.count),
      "createdAt": createdAt,
      "lastMessageAt": createdAt,
      "accessType": route.accessType,
      "joinApprovalRequired": route.joinApprovalRequired,
      "restrictSavingContent": route.restrictSavingContent,
      "messages": [],
    ]
    if route.isChannel {
      payload["subscriberCount"] = max(route.roomParticipantCount, route.members.count)
    }
    if let value = route.avatarURI { payload["avatarUrl"] = value }
    if let value = route.roomDescription { payload["description"] = value }
    if let value = route.publicSlug { payload["publicSlug"] = value }
    if let value = route.shareLink { payload["shareLink"] = value }
    guard let row = ChatHomeListRow.parse(payload) else { return }
    restoreLocalRow(row)
  }

  func markLocalRead(chatID: String) {
    let normalizedChatID = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedChatID.isEmpty else { return }
    let changed = mutateRow(chatID: normalizedChatID) { row in
      guard row.unreadCount > 0 || row.markedUnread else { return row }
      return row.withHomeState(unreadCount: 0, markedUnread: false)
    }
    if changed {
      persistHomeRows()
    }
  }

  /// Project Mark as unread / Mark as read into Home immediately.
  ///
  /// This is purely this user's own list state: the endpoint behind it flips only this
  /// participant's `marked_unread` flag, so nothing here retracts a read receipt already
  /// sent to the peer or rewrites any message's delivery status. Returns the previous
  /// unread state so a failed round trip can be reverted exactly.
  @discardableResult
  func applyLocalUnread(chatID: String, unread: Bool) -> (unreadCount: Int, markedUnread: Bool)? {
    let normalizedChatID = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedChatID.isEmpty,
      let current = rows.first(where: { $0.chatId == normalizedChatID })
        ?? archivedRows.first(where: { $0.chatId == normalizedChatID })
    else { return nil }
    let previous = (unreadCount: current.unreadCount, markedUnread: current.markedUnread)
    if mutateRow(chatID: normalizedChatID, transform: { $0.withLocalUnread(unread) }) {
      persistHomeRows()
    }
    return previous
  }

  func restoreLocalUnread(chatID: String, unreadCount: Int, markedUnread: Bool) {
    let normalizedChatID = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedChatID.isEmpty else { return }
    let changed = mutateRow(chatID: normalizedChatID) { row in
      row.withHomeState(unreadCount: unreadCount, markedUnread: markedUnread)
    }
    if changed {
      persistHomeRows()
    }
  }

  /// Reads the engine WITHOUT blocking, then projects.
  ///
  /// This used to call `ChatEngine.shared.getChatRows` inline. That enters the engine's
  /// serial queue, and on a miss it is a `queue.sync` from the main thread — so every
  /// `chatMessageChanged`/`chatDelta` notification could park the UI behind a decrypt or
  /// a SQLite write. A main-thread stack sample caught it exactly here:
  ///   ChatEngine.syncOnQueue ← ChatEngine.getChatRows ← ChatsViewModel.applyEngineProjection
  ///   ← @MainActor closure in ChatsViewModel.init  … main thread blocked 0.67s
  /// The projection is a list preview and is re-run on the next notification anyway, so
  /// being one engine turn late is free; blocking the thread that draws the list is not.
  private func applyEngineProjection(
    chatID: String,
    reason: String,
    changedMessageID: String? = nil,
    changedMessageWasInserted: Bool? = nil,
    chatIsOnScreen: Bool = false
  ) {
    let normalizedChatID = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedChatID.isEmpty, !locallyRemovedChatIDs.contains(normalizedChatID) else {
      return
    }
    ChatEngine.shared.chatRows(chatId: normalizedChatID) { [weak self] rawEngineRows in
      // `chatRows` guarantees main-thread delivery; assume the isolation rather than
      // hop again, so the common (already-published) case still projects in this turn.
      MainActor.assumeIsolated {
        self?.applyEngineProjection(
          engineRowsRaw: rawEngineRows,
          normalizedChatID: normalizedChatID,
          reason: reason,
          changedMessageID: changedMessageID,
          changedMessageWasInserted: changedMessageWasInserted,
          chatIsOnScreen: chatIsOnScreen)
      }
    }
  }

  private func applyEngineProjection(
    engineRowsRaw: [[String: Any]],
    normalizedChatID: String,
    reason: String,
    changedMessageID: String?,
    changedMessageWasInserted: Bool?,
    chatIsOnScreen: Bool
  ) {
    // Re-checked after the hop: the chat may have been removed while we were away.
    guard !locallyRemovedChatIDs.contains(normalizedChatID) else { return }
    let projectionHomeRow =
      rows.first(where: { $0.chatId == normalizedChatID })
      ?? archivedRows.first(where: { $0.chatId == normalizedChatID })

    if reason == "chatMessageDeleted", let changedMessageID {
      locallyDeletedMessageIDsByChat[normalizedChatID, default: []].insert(changedMessageID)
      if projectedMessageIDsByChat[normalizedChatID] == changedMessageID {
        projectedMessageIDsByChat.removeValue(forKey: normalizedChatID)
      }
    }

    let deletedMessageIDs = locallyDeletedMessageIDsByChat[normalizedChatID] ?? []
    let engineRows = engineRowsRaw
      .filter { row in
        let payload = Self.messagePayload(from: row)
        guard let messageID = Self.messageID(from: payload) ?? Self.messageID(from: row) else {
          return true
        }
        return !deletedMessageIDs.contains(messageID)
      }
    if let changedMessageID,
      reason == "chatMessageEdited" || reason == "chatMessageDeleted"
    {
      ChatListView.applyWarmTranscriptMutation(
        chatId: normalizedChatID,
        messageId: changedMessageID,
        action: reason == "chatMessageEdited" ? "edited" : "deleted",
        sourceRows: engineRows,
        peerDisplayName: projectionHomeRow?.title ?? ""
      )
    }
    guard let latestRow = engineRows.last else {
      if reason == "chatMessageDeleted" || reason == "chatRowsReloaded" {
        let changed = mutateRow(chatID: normalizedChatID) { row in
          row.withHomeState(
            preview: "",
            timeLabel: "",
            previewRows: [],
            initialMessages: []
          )
        }
        if changed {
          persistHomeRows()
        }
        NSLog(
          "[HomeProjection] delete-empty chat=%@ mid=%@ cachedPreviewCleared=%@",
          String(normalizedChatID.prefix(12)),
          changedMessageID.map { String($0.prefix(12)) } ?? "-",
          changed ? "Y" : "N"
        )
      }
      return
    }

    let message = Self.messagePayload(from: latestRow)
    let messageID = Self.messageID(from: message) ?? Self.messageID(from: latestRow)

    // Unread is decided by the message the event actually names, not by whatever happens
    // to be newest: an out-of-order arrival must still count, and a redelivery of a
    // message already on this device must not count twice.
    let changedRow: [String: Any]? = changedMessageID.flatMap { identifier in
      engineRows.last { row in
        let payload = Self.messagePayload(from: row)
        return (Self.messageID(from: payload) ?? Self.messageID(from: row)) == identifier
      }
    }
    let unreadCandidate = Self.messagePayload(from: changedRow ?? latestRow)
    let unreadCandidateID = changedMessageID ?? messageID
    let isIncoming = (Self.boolValue(unreadCandidate["isMe"]) == false)
    let didAlreadyProject =
      unreadCandidateID.flatMap { projectedMessageIDsByChat[normalizedChatID] == $0 } ?? false
    // The engine reports whether its upsert actually inserted; fall back to the
    // last-projected memo when the signal carries no such flag (older server payloads).
    let isNewOnThisDevice = changedMessageWasInserted ?? !didAlreadyProject
    let shouldIncrementUnread = (reason == "chatMessageInserted" || reason == "remoteNewMessage")
      && isIncoming
      && isNewOnThisDevice
      // A message arriving in the conversation the user is currently reading is not
      // unread. Home used to raise a badge behind the open chat and only lose it on the
      // next list fetch.
      && !chatIsOnScreen
    let preview = ChatHomeListRow.homePreviewText(from: message)
    let timeLabel = ChatHomeListRow.homeTimeLabel(from: message)
    let messageAt =
      (message["timestamp"] as? NSNumber)?.doubleValue
      ?? (message["timestampMs"] as? NSNumber)?.doubleValue
      ?? (message["timestamp_ms"] as? NSNumber)?.doubleValue
      ?? Date().timeIntervalSince1970 * 1000

    var keptFirstPaintTail = false
    let changed = mutateRow(chatID: normalizedChatID) { row in
      // Bridge/built-in agent surfaces keep their existing volatility/session behavior.
      // Normal chats only need a bounded latest tail in Home; the complete engine
      // snapshot stays engine-side for asynchronous attachment after the push begins.
      let projectedRows: [[String: Any]]
      if row.isBuiltInAgentSurface || row.isBridgeAgentSurface {
        projectedRows = engineRows
      } else {
        // MERGE, never replace. The engine holds only what this device has ingested; a
        // chat that has never been opened this run can hold exactly the one message that
        // just arrived, and overwriting Home's cached tail with it would make the tap
        // mount a single-row transcript — the opposite of the populated-frame-one
        // contract. Growth is also what lets the tap use real rows immediately.
        let existingTail = Self.filteringDeletedRows(
          row.initialMessages.isEmpty ? row.previewRows : row.initialMessages,
          deletedMessageIDs: deletedMessageIDs
        )
        projectedRows = Self.mergedFirstPaintTail(
          existing: existingTail,
          engineRows: engineRows,
          limit: Self.chatFirstPaintTailLimit
        )
        keptFirstPaintTail = projectedRows.count >= existingTail.count
      }
      return row.withHomeState(
        preview: preview,
        timeLabel: timeLabel.isEmpty ? row.timeLabel : timeLabel,
        unreadCount: shouldIncrementUnread ? row.unreadCount + 1 : row.unreadCount,
        markedUnread: shouldIncrementUnread ? true : row.markedUnread,
        previewRows: projectedRows,
        initialMessages: projectedRows,
        lastMessageAt: max(row.lastMessageAt, messageAt)
      )
    }
    if let unreadCandidateID {
      projectedMessageIDsByChat[normalizedChatID] = unreadCandidateID
    } else if let messageID {
      projectedMessageIDsByChat[normalizedChatID] = messageID
    }
    if changed {
      persistHomeRows()
      // Home's row is only half of the first pushed frame: a chat that has already been
      // warmed mounts its cached parsed snapshot, which was captured before this message
      // existed. Grow it in the same beat so both surfaces agree. (The helper re-checks
      // growth itself and is a no-op for anything else.)
      if keptFirstPaintTail, !chatIsOnScreen,
        let row = rows.first(where: { $0.chatId == normalizedChatID })
          ?? archivedRows.first(where: { $0.chatId == normalizedChatID }),
        !row.isBuiltInAgentSurface, !row.isBridgeAgentSurface
      {
        ChatListView.growWarmTranscriptSnapshot(
          chatId: normalizedChatID,
          sourceRows: engineRows,
          peerDisplayName: row.title
        )
      }
    }
  }

  /// Drop rows the user already deleted on this device from a cached tail.
  private static func filteringDeletedRows(
    _ rows: [[String: Any]],
    deletedMessageIDs: Set<String>
  ) -> [[String: Any]] {
    guard !deletedMessageIDs.isEmpty else { return rows }
    return rows.filter { row in
      let payload = messagePayload(from: row)
      guard let messageID = messageID(from: payload) ?? messageID(from: row) else { return true }
      return !deletedMessageIDs.contains(messageID)
    }
  }

  /// Combine Home's cached first-paint tail with what the engine holds.
  ///
  /// The engine is the authority for any message it knows about, so a shared id always
  /// takes the engine's copy (edits, receipts, media promotion). Ids the cached tail has
  /// never seen are newer traffic and are appended in engine order. When the engine
  /// already covers the whole cached tail it simply wins outright, which keeps its
  /// ordering — including the settle-slot ordering agent replies depend on — intact.
  private static func mergedFirstPaintTail(
    existing: [[String: Any]],
    engineRows: [[String: Any]],
    limit: Int
  ) -> [[String: Any]] {
    guard !engineRows.isEmpty else { return existing }
    guard !existing.isEmpty else { return Array(engineRows.suffix(limit)) }

    var engineRowsByID: [String: [String: Any]] = [:]
    var engineOrder: [String] = []
    for row in engineRows {
      let payload = messagePayload(from: row)
      guard let identifier = messageID(from: payload) ?? messageID(from: row) else { continue }
      if engineRowsByID[identifier] == nil { engineOrder.append(identifier) }
      engineRowsByID[identifier] = row
    }
    guard !engineRowsByID.isEmpty else { return existing }

    var existingIDs = Set<String>()
    var merged: [[String: Any]] = []
    merged.reserveCapacity(existing.count + engineOrder.count)
    for row in existing {
      let payload = messagePayload(from: row)
      guard let identifier = messageID(from: payload) ?? messageID(from: row) else {
        merged.append(row)
        continue
      }
      existingIDs.insert(identifier)
      merged.append(engineRowsByID[identifier] ?? row)
    }
    if existingIDs.isSubset(of: Set(engineOrder)) {
      return Array(engineRows.suffix(limit))
    }
    for identifier in engineOrder where !existingIDs.contains(identifier) {
      if let row = engineRowsByID[identifier] { merged.append(row) }
    }
    return Array(merged.suffix(limit))
  }

  /// Remove locally deleted ids from a server/cached Home row before it is allowed to
  /// replace the immediate engine projection. This is the race fence for Back: the row
  /// can repaint at once while deletion continues in the background.
  private func filteringLocallyDeletedMessages(from row: ChatHomeListRow) -> ChatHomeListRow {
    guard let deletedMessageIDs = locallyDeletedMessageIDsByChat[row.chatId],
      !deletedMessageIDs.isEmpty
    else {
      return row
    }
    let sourceRows = row.initialMessages.isEmpty ? row.previewRows : row.initialMessages
    guard !sourceRows.isEmpty else {
      // A payload-less stale response cannot prove that its preview survived the local
      // deletion. Keep Home's already-cleared projection until a concrete row arrives.
      if let existing = rows.first(where: { $0.chatId == row.chatId }),
        existing.previewRows.isEmpty,
        existing.initialMessages.isEmpty,
        existing.preview.isEmpty
      {
        return row.withHomeState(preview: "", timeLabel: "")
      }
      return row
    }

    let filteredRows = sourceRows.filter { rawRow in
      let payload = Self.messagePayload(from: rawRow)
      guard let messageID = Self.messageID(from: payload) ?? Self.messageID(from: rawRow) else {
        return true
      }
      return !deletedMessageIDs.contains(messageID)
    }
    guard filteredRows.count != sourceRows.count else { return row }
    guard let latestRow = filteredRows.last else {
      return row.withHomeState(
        preview: "",
        timeLabel: "",
        previewRows: [],
        initialMessages: []
      )
    }
    let latestMessage = Self.messagePayload(from: latestRow)
    return row.withHomeState(
      preview: ChatHomeListRow.homePreviewText(from: latestMessage),
      timeLabel: ChatHomeListRow.homeTimeLabel(from: latestMessage),
      previewRows: filteredRows,
      initialMessages: filteredRows
    )
  }

  /// Projects a live bridge status into Home without exposing a raw command/path.
  /// Returns false once the task has settled, allowing the normal debounced refresh to
  /// restore the server's final response preview.
  private func applyAgentProgress(chatID: String) -> Bool {
    let normalizedChatID = chatID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedChatID.isEmpty,
      let progress = ChatEngine.shared.agentProgress(chatId: normalizedChatID),
      (progress["isActive"] as? Bool) == true
    else {
      return false
    }

    let label = Self.friendlyAgentProgressLabel(
      rawLabel: progress["label"] as? String,
      tool: progress["tool"] as? String
    )
    guard !label.isEmpty else { return false }

    let changed = mutateRow(chatID: normalizedChatID) { row in
      guard row.isBridgeAgentSurface else { return row }
      let provider = ChatHomeListRow.bridgeProvider(
        peerUserId: row.peerUserId,
        name: row.title,
        isAgent: row.isAgentFriend,
        agentId: row.peerAgentId
      ) ?? row.title
      // Update the live "… is working…" preview IN PLACE only — do NOT bump
      // lastMessageAt. Bumping it to now on every progress frame shoved the
      // running agent row to the top, and the next server refresh (carrying the
      // real, older timestamp) dropped it back — the row oscillated top↔bottom
      // for the whole run. Position is owned by real messages; streaming
      // progress only rewrites the row's subtitle where it already sits.
      return row.withHomeState(
        preview: "\(ChatRoute.bridgeDisplayName(for: provider)) is \(label)"
      )
    }
    if changed {
      persistHomeRows()
    }
    return changed
  }

  private static func friendlyAgentProgressLabel(rawLabel: String?, tool: String?) -> String {
    let label = (rawLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let tool = (tool ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !label.isEmpty || !tool.isEmpty else { return "working…" }

    func matches(_ values: [String]) -> Bool {
      values.contains { tool.contains($0) || label.contains($0) }
    }
    if matches(["approval", "awaiting", "permission"]) { return "waiting for approval" }
    if matches(["error", "fail"]) { return "working on an error" }
    // Must precede the reading bucket: a host like "research.com" contains "search".
    if matches(["brows", "computer"]) {
      let host = rawLabel?.split(separator: " ").last.map(String.init) ?? ""
      return host.contains(".") ? "browsing \(host)" : "browsing…"
    }
    if matches(["read", "grep", "glob", "search", "fetch", "look"]) { return "reading…" }
    if matches(["write", "edit", "patch", "notebook"]) { return "editing…" }
    if matches(["think", "reason", "plan"]) { return "thinking…" }
    if matches(["bash", "shell", "command", "exec"]) { return "running…" }
    return "working…"
  }

  func loadIfNeeded() async {
    guard !hasLoaded else { return }
    AppUITrace.notice("ChatsViewModel loadIfNeeded start rows=\(rows.count)")
    guard let config = AppSessionConfig.current else {
      if rows.isEmpty {
        errorMessage = "The current session is unavailable."
      }
      AppUITrace.error("ChatsViewModel loadIfNeeded missingSession rows=\(rows.count)")
      return
    }

    let cachedRows = ChatHomeService.cachedRows(config: config)
    if !cachedRows.isEmpty {
      rows = cachedRows
      hasLoaded = true
      isLoading = false
      isListUpdating = false
      isWaitingForNetwork = false
      refreshConnectionState()
      errorMessage = nil
      // Fetch history from the CACHED row list too, instead of waiting for /api/chats.
      // Measured on device (launch 19:34:28.7): cache painted at +0.2s, the socket was up
      // at +1.6s, but the chats-list call took ~6.8s — and every per-chat history fetch
      // was queued behind it, so the first message update landed ~10.4s into the launch.
      // The chat ids are already known here; nothing about them needs the list response.
      // The post-refresh call still runs and de-dupes (historyLoadingChats /
      // historyFullyLoadedChats), so a chat that appeared while we were offline is not
      // missed — it just no longer holds up the ones we already know about.
      warmCachedRows(cachedRows, shouldFetchHistory: true)
      scheduleArchivedLoadIfNeeded()
      AppUITrace.notice(
        "ChatsViewModel restored-cache rows=\(cachedRows.count) schedulingBackgroundRefresh=Y"
      )
      scheduleBackgroundRefreshAfterCachedStart()
      return
    }

    await refresh(preserveRows: false)
  }

  func refresh() async {
    backgroundRefreshTask?.cancel()
    backgroundRefreshTask = nil
    await refresh(preserveRows: false)
  }

  func loadArchivedIfNeeded() async {
    guard !hasLoadedArchived else { return }
    await refreshArchived(preserveRows: true)
  }

  func refreshArchived() async {
    await refreshArchived(preserveRows: false)
  }

  func refreshAll() async {
    await refresh(preserveRows: false)
    await refreshArchived(preserveRows: false)
  }

  private func refresh(preserveRows: Bool) async {
    if let inflightRefreshTask {
      trailingRefreshRequested = true
      await inflightRefreshTask.value
      return
    }

    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.performRefresh(preserveRows: preserveRows)
      while self.trailingRefreshRequested {
        self.trailingRefreshRequested = false
        // A request that landed mid-fetch is real, but it must not turn into an
        // immediate second round trip — that is how a steady signal (upload ticks,
        // a chatty group) turned this into a permanent refetch loop. Let the link
        // breathe for the same floor the debounce uses.
        let sinceLastFetch = ProcessInfo.processInfo.systemUptime - self.lastListFetchFinishedAt
        let cooldown = Self.realtimeRefreshMinInterval - sinceLastFetch
        if cooldown > 0 {
          try? await Task.sleep(nanoseconds: UInt64(cooldown * 1_000_000_000))
        }
        await self.performRefresh(preserveRows: true)
      }
      self.inflightRefreshTask = nil
    }
    inflightRefreshTask = task
    await task.value
  }

  private func performRefresh(preserveRows: Bool) async {
    let startedAt = ProcessInfo.processInfo.systemUptime
    AppUITrace.notice(
      "ChatsViewModel refresh start preserveRows=\(preserveRows ? "Y" : "N") currentRows=\(rows.count)"
    )
    AppUIStallWatchdog.shared.updateContext(
      "ChatsViewModel refresh preserveRows=\(preserveRows ? "Y" : "N") rows=\(rows.count)"
    )
    guard let config = AppSessionConfig.current else {
      if rows.isEmpty {
        errorMessage = "The current session is unavailable."
      }
      AppUITrace.error("ChatsViewModel refresh missingSession rows=\(rows.count)")
      return
    }

    refreshConnectionState()
    isLoading = rows.isEmpty && !preserveRows
    // Background reconciliation is invisible: cached/projected rows remain usable and
    // the principal header stays "Chats". Only a user-visible foreground refresh with
    // existing rows may advertise Updating; initial empty loading still uses isLoading.
    isListUpdating = !preserveRows && !isWaitingForNetwork && !rows.isEmpty
    isWaitingForNetwork = false
    errorMessage = nil
    defer {
      isLoading = false
      isListUpdating = false
      lastListFetchFinishedAt = ProcessInfo.processInfo.systemUptime
    }

    do {
      let fetchedRows: [ChatHomeListRow]
      do {
        fetchedRows = try await ChatHomeService.fetchChats(config: config)
      } catch {
        let isCancellation = error is CancellationError
          || (error as? URLError)?.code == .cancelled
        guard isCancellation else { throw error }
        AppUITrace.notice("ChatsViewModel refresh retry-after-cancel")
        fetchedRows = try await ChatHomeService.fetchChats(config: config)
      }
      // NSLog (not AppUITrace) so the chats-list round trip is visible in the device log
      // next to the socket/history lines — this is the launch's long pole and the number
      // that says whether a slow first launch is the client or the server.
      NSLog(
        "[Launch] /api/chats rows=%d in %dms",
        fetchedRows.count,
        Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))
      // Repair any chat the server considers cleared past a point we are still holding
      // messages before. This is the catch-up path for a `chat-deleted` push that never
      // arrived — see `ChatEngine.applyRemoteMessagesClearedAt`. Cheap and idempotent:
      // the engine keeps the last point it applied per chat and returns immediately when
      // there is nothing new, which is every refresh but the one that matters.
      for fetchedRow in fetchedRows where fetchedRow.messagesClearedAt > 0 {
        ChatEngine.shared.applyRemoteMessagesClearedAt(
          chatId: fetchedRow.chatId,
          clearedAtMs: Int64(fetchedRow.messagesClearedAt))
      }
      let existingRowsByChatID = Dictionary(
        rows.map { ($0.chatId, $0) },
        uniquingKeysWith: { current, _ in current }
      )
      let nextRows = fetchedRows
        .filter { !locallyRemovedChatIDs.contains($0.chatId) }
        .map { rawFetchedRow in
          let fetchedRow = filteringLocallyDeletedMessages(from: rawFetchedRow)
          guard !fetchedRow.isBuiltInAgentSurface, !fetchedRow.isBridgeAgentSurface,
            let existingRow = existingRowsByChatID[fetchedRow.chatId]
          else { return fetchedRow }
          let fetchedTail = fetchedRow.initialMessages.isEmpty
            ? fetchedRow.previewRows
            : fetchedRow.initialMessages
          let existingTail = existingRow.initialMessages.isEmpty
            ? existingRow.previewRows
            : existingRow.initialMessages
          // Order is sticky: keep the highest-seen lastMessageAt so a background
          // refresh that raced a just-arrived local message can't revert the row
          // to a stale slot ("keep that order until a real new update"). Monotonic
          // per row — a genuinely newer server timestamp still wins via max.
          let stickyLastMessageAt = max(existingRow.lastMessageAt, fetchedRow.lastMessageAt)
          // Home responses intentionally carry only a tiny preview. Do not shrink a
          // richer device-restored first-paint tail on every background refresh.
          guard existingTail.count > fetchedTail.count else {
            return fetchedRow.withHomeState(lastMessageAt: stickyLastMessageAt)
          }
          return fetchedRow.withHomeState(
            previewRows: existingTail,
            initialMessages: existingTail,
            lastMessageAt: stickyLastMessageAt
          )
        }
      if Self.rowsSnapshotSignature(nextRows) != Self.rowsSnapshotSignature(rows) {
        // [EmptyTrace] Main (home) list jumps to empty here: a fetch that returned nothing
        // (or everything filtered out) replaces a populated list. Log the transition so the
        // device log shows whether the server returned 0 chats vs. a local filter wiped them.
        if nextRows.isEmpty && !rows.isEmpty {
          VibeDebugLog.log(
            "[EmptyTrace] mainList EMPTY replace was=%d fetched=%d locallyRemoved=%d preserveRows=%@",
            rows.count, fetchedRows.count, locallyRemovedChatIDs.count, preserveRows ? "Y" : "N")
        }
        rows = nextRows
        AppUITrace.notice(
          "ChatsViewModel refresh applied rows=\(nextRows.count) preserveRows=\(preserveRows ? "Y" : "N") durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))"
        )
      } else {
        AppUITrace.notice(
          "ChatsViewModel refresh skipped-identical rows=\(nextRows.count) preserveRows=\(preserveRows ? "Y" : "N") durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))"
        )
      }
      hasLoaded = true
      isWaitingForNetwork = false
      refreshConnectionState()
      warmCachedRows(nextRows, shouldFetchHistory: true)
      scheduleArchivedLoadIfNeeded()
    } catch {
      let offline = ChatHomeService.isOfflineError(error)
      isWaitingForNetwork = offline
      refreshConnectionState()
      // Offline path: Connecting only — never leave "Updating" stuck on.
      if offline {
        isConnecting = true
      }
      if rows.isEmpty {
        errorMessage = error.localizedDescription
      } else {
        errorMessage = nil
      }
      hasLoaded = true
      AppUITrace.error(
        "ChatsViewModel refresh error offline=\(offline ? "Y" : "N") rows=\(rows.count) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)) error=\(error.localizedDescription)"
      )
    }
  }

  private func scheduleArchivedLoadIfNeeded() {
    guard !hasLoadedArchived else { return }
    Task { @MainActor [weak self] in
      await self?.loadArchivedIfNeeded()
    }
  }

  private func refreshArchived(preserveRows: Bool) async {
    guard let config = AppSessionConfig.current else { return }
    isLoadingArchived = archivedRows.isEmpty && !preserveRows
    defer { isLoadingArchived = false }

    do {
      let fetchedRows = try await ChatHomeService.fetchArchivedChats(config: config)
      let nextRows = fetchedRows.filter { !locallyRemovedChatIDs.contains($0.chatId) }
      if Self.rowsSnapshotSignature(nextRows) != Self.rowsSnapshotSignature(archivedRows) {
        archivedRows = nextRows
      }
      hasLoadedArchived = true
    } catch {
      hasLoadedArchived = true
      AppUITrace.error("ChatsViewModel archived refresh error \(error.localizedDescription)")
    }
  }

  private func scheduleBackgroundRefreshAfterCachedStart() {
    backgroundRefreshTask?.cancel()
    AppUITrace.notice("ChatsViewModel scheduleBackgroundRefreshAfterCachedStart")
    backgroundRefreshTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: 450_000_000)
      } catch {
        return
      }
      await self?.refresh(preserveRows: true)
    }
  }

  /// Identity of the last warmed row set, so an unchanged list is not re-warmed.
  private var lastWarmedRowsFingerprint: String?

  private func warmCachedRows(_ rows: [ChatHomeListRow], shouldFetchHistory: Bool) {
    // Foreground fires two `/api/chats` fetches close together — one from becoming
    // active, one from the socket reopening and triggering reconnects — and the second
    // usually returns the byte-identical list. Device log 2026-08-08: `rows=15 in 1001ms`
    // at 11:01:21.9 then `rows=15 in 306ms` at 11:01:23.8, each followed by the same
    // `PREWARM-PLAN` and `history prefetch kicked=14 of 14`. The fetch itself is cheap to
    // repeat; re-running the warm is not — it re-seeds every chat onto the engine's
    // serial queue, re-decodes up to eight full-screen rasters, and fans out fourteen
    // history loads, all to arrive at the state already in memory.
    //
    // Keyed on what the warm actually consumes (chat identity, order, and the preview
    // tail it seeds), so a genuinely changed list still warms — including a reorder,
    // because the raster budget and the prefetch prefix are both order-dependent.
    let fingerprint =
      rows
      .map { "\($0.chatId)|\($0.initialMessages.count)|\($0.previewRows.count)" }
      .joined(separator: ",")
    if fingerprint == lastWarmedRowsFingerprint {
      AppUITrace.notice("ChatsViewModel warmCachedRows SKIP — row set unchanged")
      return
    }
    lastWarmedRowsFingerprint = fingerprint

    let visibleRows = Array(rows.prefix(8))
    // Seed EVERY row, not the top 8, and with the whole preview the payload carries
    // rather than 3 of it. These messages are already in memory — the only cost is one
    // engine-queue hop per chat — and since the seed now persists, this is what gives a
    // chat further down the list something durable to paint on its first open instead of
    // a blank surface waiting on the network.
    // Bridge/agent DMs are included: their settled turns are canonical server messages,
    // and the engine now persists them like any chat (the volatile layer is only the
    // live session state). Excluding them here was one of the reasons an agent DM had
    // nothing durable to paint on a cold open.
    for row in rows
    where !row.isBuiltInAgentSurface && !row.initialMessages.isEmpty {
      ChatEngine.shared.seedRecentChatHistory(
        chatId: row.chatId,
        messages: row.initialMessages,
        limit: 15
      )
    }

    // Home's API/cache may carry only the newest preview message even though the
    // complete encrypted transcript is already persisted on this device. Restore a
    // bounded raw tail off-main while Home is visible, then persist it back into the
    // Home row. The first chat route can now paint eight rows before its first layout
    // pass without ever blocking navigation on ChatEngine's serial queue.
    // ALL rows, not the visible 8: the reported 177ms-empty first open was a chat below
    // the fold — outside this loop it had no tail, no snapshot, and nothing mountable at
    // push time. The loop itself bounds the fan-out.
    warmFirstPaintTailsFromEngineCache(rows)

    // Reopen-raster prewarm, beyond the 3 full-prewarm winners inside the prefix(8): a
    // chat whose raster is not in memory at tap time races the disk decode and commits a
    // blank shell until it lands. Agent rows crowded the visible prefix, so the filter
    // keeps them from spending the budget — but the list is NOT unbounded any more: each
    // raster is a full-screen bitmap and the overlay cache holds 8, so warming all ten
    // chats newest-first made the oldest ones evict the newest, i.e. the chats actually
    // being opened. Bounded, newest-first, and remembered for the foreground re-warm.
    let prewarmChatIds =
      rows
      .filter { !$0.isBuiltInAgentSurface }
      .map { $0.chatId.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    ChatListView.prewarmReopenSnapshotRasters(chatIds: prewarmChatIds)
    // Same set, the other half of a fast open: the prepared-height store is memory-only,
    // so without this the first open of every session measures its whole seed.
    // Recently-opened first: the store keeps three chats, and Home's order can rank
    // the chat the user was just in below that line.
    let mruRank = Dictionary(
      ChatListView.recentlyOpenedChatIds.enumerated().map { ($1, $0) },
      uniquingKeysWith: { first, _ in first })
    let prepareChatIds = prewarmChatIds.enumerated().sorted { lhs, rhs in
      let lhsRank = mruRank[lhs.element] ?? Int.max
      let rhsRank = mruRank[rhs.element] ?? Int.max
      return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
    }.map(\.element)
    ChatEngine.shared.prepareTimelinesAfterLaunch(chatIds: prepareChatIds)
    ChatListCell.prewarmRealization()

    guard shouldFetchHistory else { return }
    // Was `prefix(2)`: only the top TWO chats ever had their history fetched, and a chat
    // that is never fetched is never persisted — so every chat below row 2 opened empty
    // on a cold device and stayed that way, because the same two rows won the race on the
    // next launch too. Measured against the account: 7 chats, 4 of them (57/41/14/6
    // messages) never appeared in a single engine log line. Bounded at 16 so a large
    // account still can't fan out unboundedly; the rest fill in as they are opened.
    let preloadChatIds =
      rows
      .filter { !$0.isBuiltInAgentSurface }
      .prefix(16)
      .map(\.chatId)
    AppUITrace.notice(
      "ChatsViewModel warmCachedRows rows=\(rows.count) preload=\(preloadChatIds.map { String($0.prefix(12)) }.joined(separator: ","))"
    )
    ChatEngine.shared.prefetchChatHistories(chatIds: preloadChatIds)
  }

  private func warmFirstPaintTailsFromEngineCache(_ rows: [ChatHomeListRow]) {
    let tailLimit = Self.chatFirstPaintTailLimit
    // Every cached chat gets a complete parsed warm snapshot below. Only reopen-raster
    // decoding is budgeted: those are full-screen bitmaps, unlike the parsed row data.
    var rasterPrewarmBudget = 3
    // Spend the budget recently-OPENED first, Home's order second — the raster prewarm's
    // rule, adopted here for the same measured reason: Home ranks by last message with
    // pins first, so the chat the user had JUST been chatting in sat below the budget
    // line, got no parsed snapshot, and its cold first open mounted nothing until the
    // async engine snapshot (~180ms of bare wallpaper).
    let mruRank = Dictionary(
      ChatListView.recentlyOpenedChatIds.enumerated().map { ($1, $0) },
      uniquingKeysWith: { first, _ in first })
    let orderedRows = rows.enumerated().sorted { lhs, rhs in
      let lhsRank =
        mruRank[lhs.element.chatId.trimmingCharacters(in: .whitespacesAndNewlines)] ?? Int.max
      let rhsRank =
        mruRank[rhs.element.chatId.trimmingCharacters(in: .whitespacesAndNewlines)] ?? Int.max
      return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
    }.map(\.element)
    // Bound the fan-out (callers now pass every home row, not just the visible 8), but
    // NEVER to fewer chats than the user can actually tap on one screen.
    var remainingWarms = 16
    for row in orderedRows where !row.isBuiltInAgentSurface && !row.isBridgeAgentSurface {
      guard remainingWarms > 0 else { break }
      let chatID = row.chatId.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !chatID.isEmpty, !warmingFirstPaintTailChatIDs.contains(chatID) else { continue }
      remainingWarms -= 1
      warmingFirstPaintTailChatIDs.insert(chatID)
      let allowRasterPrewarm = rasterPrewarmBudget > 0
      let peerDisplayName = row.title
      if allowRasterPrewarm { rasterPrewarmBudget -= 1 }

      DispatchQueue.global(qos: .userInitiated).async { [weak self] in
        let engineRows = ChatEngine.shared.getChatRows(["chatId": chatID])
        if allowRasterPrewarm {
          ChatListView.prewarmWarmTranscriptSnapshot(
            chatId: chatID,
            sourceRows: engineRows,
            peerDisplayName: peerDisplayName
          )
          // Twin prewarm: decode this chat's reopen raster into the overlay cache now,
          // so the first open's shell commit already has content on its first frame
          // instead of racing the disk decode (the cold-open spinner window).
          ChatListView.prewarmReopenSnapshotRaster(chatId: chatID)
        } else if !engineRows.isEmpty {
          // Parsed transcript snapshots are data, not full-screen bitmaps. Keeping only
          // a 16-row tail here meant a chat whose 55 rows were ALREADY restored locally
          // still mounted 16 during the slide, then replaced them with all 55 at
          // viewDidAppear. That late authoritative insert changed content height/offset
          // and was the reported mid-push layout shift. Keep the complete bounded engine
          // snapshot for every tappable Home row; the expensive raster budget above
          // remains limited independently.
          ChatListView.prewarmWarmTranscriptSnapshot(
            chatId: chatID,
            sourceRows: engineRows,
            peerDisplayName: peerDisplayName
          )
        }
        let tail = Array(engineRows.suffix(tailLimit))
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.warmingFirstPaintTailChatIDs.remove(chatID)
          guard !tail.isEmpty else { return }

          guard let existingRow = self.rows.first(where: { $0.chatId == chatID }) else { return }
          let existingTail = existingRow.initialMessages.isEmpty
            ? existingRow.previewRows
            : existingRow.initialMessages
          guard tail.count > existingTail.count else { return }
          var previousCount = 0
          let changed = self.mutateRow(chatID: chatID) { current in
            let currentTail = current.initialMessages.isEmpty
              ? current.previewRows
              : current.initialMessages
            previousCount = currentTail.count
            guard tail.count > currentTail.count else { return current }
            return current.withHomeState(previewRows: tail, initialMessages: tail)
          }
          guard changed, tail.count > previousCount else { return }
          self.persistHomeRows()
          NSLog(
            "[ChatOpen] home-tail WARM chat=%@ previous=%d cached=%d tail=%d",
            String(chatID.prefix(12)), previousCount, engineRows.count, tail.count)
        }
      }
    }
  }

  private func mutateRow(
    chatID: String,
    transform: (ChatHomeListRow) -> ChatHomeListRow
  ) -> Bool {
    var changed = false
    rows = rows.map { row in
      guard row.chatId == chatID else { return row }
      changed = true
      return transform(row)
    }
    archivedRows = archivedRows.map { row in
      guard row.chatId == chatID else { return row }
      changed = true
      return transform(row)
    }
    return changed
  }

  private func persistHomeRows() {
    guard let config = AppSessionConfig.current else { return }
    ChatHomeService.storeCachedRows(rows, config: config)
  }

  private static func upserting(
    _ row: ChatHomeListRow,
    into existingRows: [ChatHomeListRow]
  ) -> [ChatHomeListRow] {
    guard !row.isArchiveEntry else { return existingRows }
    var nextRows = existingRows.filter { $0.chatId != row.chatId && !$0.isArchiveEntry }
    let insertionIndex: Int
    if row.isSavedMessages {
      insertionIndex = 0
    } else {
      insertionIndex =
        nextRows
        .prefix { $0.isSavedMessages || $0.isBuiltInAgentSurface || $0.pinned }
        .count
    }
    nextRows.insert(row, at: min(insertionIndex, nextRows.count))
    return ChatHomeService.rowsIncludingBuiltInAgent(nextRows)
  }

  private static func messagePayload(from row: [String: Any]) -> [String: Any] {
    (row["message"] as? [String: Any]) ?? row
  }

  private static func messageID(from payload: [String: Any]) -> String? {
    normalizedString(payload["id"] ?? payload["messageId"] ?? payload["message_id"] ?? payload["key"])
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }

  private static func boolValue(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String {
      switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "1", "true", "yes", "on":
        return true
      case "0", "false", "no", "off":
        return false
      default:
        return nil
      }
    }
    return nil
  }

  private static func rowsSnapshotSignature(_ rows: [ChatHomeListRow]) -> String {
    rows.map { row in
      [
        row.chatId,
        row.title,
        row.preview,
        row.timeLabel,
        "\(row.unreadCount)",
        "\(row.markedUnread)",
        "\(row.muted)",
        "\(row.pinned)",
        "\(row.archived)",
        "\(row.isTyping)",
        "\(row.isOnline)",
        row.avatarUri ?? "",
        row.peerTier ?? "",
        "\(row.lastMessageAt)",
        row.latestOutgoingDisplayStatus ?? "",
      ].joined(separator: "\u{1F}")
    }.joined(separator: "\u{1E}")
  }
}

private extension ChatHomeListRow {
  func withHomeState(
    preview: String? = nil,
    timeLabel: String? = nil,
    unreadCount: Int? = nil,
    markedUnread: Bool? = nil,
    previewRows: [[String: Any]]? = nil,
    initialMessages: [[String: Any]]? = nil,
    lastMessageAt: Double? = nil
  ) -> ChatHomeListRow {
    ChatHomeListRow(
      chatId: chatId,
      title: title,
      preview: preview ?? self.preview,
      timeLabel: timeLabel ?? self.timeLabel,
      unreadCount: max(0, unreadCount ?? self.unreadCount),
      markedUnread: markedUnread ?? self.markedUnread,
      muted: muted,
      pinned: pinned,
      archived: archived,
      isTyping: isTyping,
      isOnline: isOnline,
      peerUserId: peerUserId,
      avatarUri: avatarUri,
      avatarFallback: avatarFallback,
      avatarGradientStartLight: avatarGradientStartLight,
      avatarGradientEndLight: avatarGradientEndLight,
      avatarGradientStartDark: avatarGradientStartDark,
      avatarGradientEndDark: avatarGradientEndDark,
      isSavedMessages: isSavedMessages,
      isArchiveEntry: isArchiveEntry,
      type: type,
      isGroup: isGroup,
      myRole: myRole,
      isAgentFriend: isAgentFriend,
      peerAgentId: peerAgentId,
      agentEventInboxMode: agentEventInboxMode,
      peerTier: peerTier,
      previewRows: previewRows ?? self.previewRows,
      initialMessages: initialMessages ?? self.initialMessages,
      members: members,
      lastMessageAt: lastMessageAt ?? self.lastMessageAt,
      // Everything below defaults in the initializer, so omitting it silently reset the
      // row: a single realtime projection used to strip a channel's description, access
      // type, public slug, share link, join/save policy and member counts — and
      // `ChatRoute(row:)` reads exactly those when the row is tapped.
      createdAt: createdAt,
      roomDescription: roomDescription,
      accessType: accessType,
      publicSlug: publicSlug,
      shareLink: shareLink,
      joinApprovalRequired: joinApprovalRequired,
      restrictSavingContent: restrictSavingContent,
      memberCount: memberCount,
      subscriberCount: subscriberCount
    )
  }
}

@MainActor
final class ContactDirectoryViewModel: ObservableObject {
  @Published var rows: [ChatHomeListRow] = []
  @Published var isLoading = false
  @Published var errorMessage: String?

  private var hasLoaded = false

  func loadIfNeeded() async {
    guard !hasLoaded else { return }
    await refresh()
  }

  func refresh() async {
    guard let config = AppSessionConfig.current else {
      rows = []
      errorMessage = "The current session is unavailable."
      return
    }

    isLoading = true
    errorMessage = nil
    defer { isLoading = false }

    do {
      let chats = try await ChatHomeService.fetchChats(config: config)
      rows = chats.filter { row in
        !row.isSavedMessages && !row.isGroup && row.peerUserId != nil
          && row.hasVisibleActivity
      }
      hasLoaded = true
    } catch {
      rows = []
      errorMessage = error.localizedDescription
    }
  }
}

private struct ContactsRootView: View {
  @EnvironmentObject private var coordinator: AppShellCoordinator
  var body: some View {
    NavigationStack(path: $coordinator.contactsPath) {
      ContactsPageView()
    }
    .onAppear { appShellRouteLog("ContactsRootView onAppear") }
    .onDisappear { appShellRouteLog("ContactsRootView onDisappear") }
  }
}



private struct CallsRootView: View {
  @EnvironmentObject private var coordinator: AppShellCoordinator
  var body: some View {
    NavigationStack(path: $coordinator.callsPath) {
      CallsPageView()
    }
    .onAppear { appShellRouteLog("CallsRootView onAppear") }
    .onDisappear { appShellRouteLog("CallsRootView onDisappear") }
  }
}

private struct HomeProxyBadge: Equatable {
  enum State: Equatable {
    case off
    case starting
    case active
    case error
  }

  var state: State = .off

  var shieldActive: Bool { state != .off }

  var accessibilityLabel: String {
    switch state {
    case .off: return "Proxy off"
    case .starting: return "Proxy starting"
    case .active: return "Proxy active"
    case .error: return "Proxy error"
    }
  }

  func tint(palette: AppThemePalette) -> Color {
    switch state {
    case .off: return palette.secondaryText.opacity(0.7)
    case .starting: return Color.orange
    case .active: return palette.accent
    case .error: return Color.red
    }
  }
}

private struct ChatHomeScreen: View {
  @EnvironmentObject private var coordinator: AppShellCoordinator
  @Environment(\.colorScheme) private var colorScheme
  @StateObject private var model = ChatsViewModel()
  @State private var isShowingSearch = false
  @State private var isEditingHome = false
  @State private var isShowingArchivedChats = false
  @State private var selectedChatIDs = Set<String>()
  @State private var isStartingChat = false
  @State private var errorMessage: String?
  @State private var isShowingChannelCreation = false
  @State private var roomCreationName = ""
  @State private var isShowingGroupCreation = false
  @State private var pendingCreatedRoomRoute: ChatRoute?
  @State private var pendingSavedContact: ContactSearchUser?
  @State private var queuedSavedContact: ContactSearchUser?
  @State private var isShowingProxy = false
  @State private var proxyBadge = HomeProxyBadge()
  @State private var homeSearchQuery = ""
  @State private var isHomeSearchFocused = false
  /// The overlay's animated pose. Visibility (isHomeSearchFocused) and pose are
  /// separate states: the permanently-mounted surface shows sitting on the
  /// capsule slot, springs to presented, and descends back before hiding.
  @State private var searchPresented = false
  /// Close phase 1: xmark retracts to restore the capsule's full width before
  /// the field descends back onto the in-list slot (executed natively).
  @State private var searchCloseRetracting = false
  @State private var locallyHiddenChatIDs = Set<String>()
  @State private var pendingDeleteConfirmation: ChatHomeDeleteConfirmation?
  @State private var pendingDeletion: ChatHomePendingDeletion?
  @State private var pendingDeletionTask: Task<Void, Never>?
  /// Global username/phone/ID lookups (incl. Claude/Codex) for the search drawer.
  @State private var globalResults: [ContactSearchUser] = []
  @State private var isGlobalSearching = false

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var filteredRows: [ChatHomeListRow] {
    let query = homeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return homeRowsWithArchiveEntry }
    return visibleHomeRows.filter { row in
      row.title.localizedCaseInsensitiveContains(query)
        || row.preview.localizedCaseInsensitiveContains(query)
    }
  }

  private var visibleHomeRows: [ChatHomeListRow] {
    Self.sortedForHome(
      model.rows.filter { row in
        !locallyHiddenChatIDs.contains(row.chatId) && Self.shouldAppearOnHome(row)
      })
  }

  /// Empty 1:1 DMs stay off Home; rooms, saved messages, and agent surfaces stay.
  private static func shouldAppearOnHome(_ row: ChatHomeListRow) -> Bool {
    if row.isSavedMessages || row.isArchiveEntry || row.isGroup { return true }
    if row.isAgentFriend || row.isBuiltInAgentSurface || row.isBridgeAgentSurface {
      return true
    }
    return row.hasVisibleActivity
  }

  /// Home ordering: pinned chats (Saved Messages included), then every other chat by
  /// newest activity. Agent surfaces intentionally share the same recency rules as
  /// people/groups, so a new Claude/Codex/Grok message lands immediately below pins.
  /// Stable within equal keys via `chatId` (not the transient source index) so a
  /// full refresh with the same timestamps cannot reshuffle rows and "jump" the list.
  private static func sortedForHome(_ rows: [ChatHomeListRow]) -> [ChatHomeListRow] {
    rows.sorted { lhs, rhs in
      let lRank = homeSortRank(lhs)
      let rRank = homeSortRank(rhs)
      if lRank != rRank { return lRank < rRank }
      if lhs.lastMessageAt != rhs.lastMessageAt {
        return lhs.lastMessageAt > rhs.lastMessageAt
      }
      // Deterministic tie-break so equal-timestamp rows never swap between refreshes.
      return lhs.chatId < rhs.chatId
    }
  }

  private static func homeSortRank(_ row: ChatHomeListRow) -> Int {
    if row.isSavedMessages || row.pinned { return 0 }
    return 1
  }

  private var visibleArchivedRows: [ChatHomeListRow] {
    model.archivedRows.filter { !locallyHiddenChatIDs.contains($0.chatId) }
  }

  private var homeRowsWithArchiveEntry: [ChatHomeListRow] {
    guard !visibleArchivedRows.isEmpty else { return visibleHomeRows }
    let archiveRow = Self.archiveEntryRow(count: visibleArchivedRows.count)
    var rows = visibleHomeRows.filter { !$0.isArchiveEntry }
    let insertionIndex = rows.first?.isSavedMessages == true ? 1 : 0
    rows.insert(archiveRow, at: insertionIndex)
    return rows
  }

  private var hasHomeRowsForAnyScope: Bool {
    !visibleHomeRows.isEmpty || !visibleArchivedRows.isEmpty
  }

  private var trimmedHomeQuery: String {
    homeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func archiveEntryRow(count: Int) -> ChatHomeListRow {
    ChatHomeListRow(
      chatId: "archive",
      title: "Archived",
      preview: count == 1 ? "1 archived chat" : "\(count) archived chats",
      timeLabel: "",
      unreadCount: 0,
      markedUnread: false,
      muted: false,
      pinned: false,
      archived: false,
      isTyping: false,
      isOnline: false,
      peerUserId: nil,
      avatarUri: nil,
      avatarFallback: "A",
      avatarGradientStartLight: nil,
      avatarGradientEndLight: nil,
      avatarGradientStartDark: nil,
      avatarGradientEndDark: nil,
      isSavedMessages: false,
      isArchiveEntry: true,
      type: "archive_entry",
      isGroup: false,
      isAgentFriend: false,
      peerAgentId: nil,
      agentEventInboxMode: nil,
      peerTier: nil,
      previewRows: [],
      initialMessages: [],
      members: []
    )
  }

  /// Claude/Codex/Grok surfaced instantly on a username prefix (no network). They are
  /// real users but the exact-match `/user/name/:username` lookup only hits on the
  /// full handle, so we offer them as soon as the user starts typing "cl"/"co"/"gr".
  private func agentSuggestions(for query: String) -> [ContactSearchUser] {
    let q = query.lowercased()
    guard !q.isEmpty else { return [] }
    let agents: [(String, String, String)] = [
      (ChatRoute.claudeAgentUserId, "claude", "https://media.vibegram.io/chat-media/agent-profiles/claude.png"),
      (ChatRoute.codexAgentUserId, "codex", "https://media.vibegram.io/chat-media/agent-profiles/codex.png"),
      (ChatRoute.grokAgentUserId, "grok", "https://media.vibegram.io/chat-media/agent-profiles/grok-v2.png"),
      (ChatRoute.agyAgentUserId, "agy", "https://media.vibegram.io/chat-media/agent-profiles/agy.png"),
    ]
    return agents.compactMap { uid, uname, avatar in
      guard uname.hasPrefix(q) else { return nil }
      return ContactSearchUser(payload: [
        "userId": uid,
        "username": uname,
        "displayName": uname.capitalized,
        "isAgent": true,
        "profileImage": avatar,
        "tier": "gold",
      ])
    }
  }

  /// People to show in the search drawer: agent suggestions + global lookups,
  /// de-duplicated and minus anyone already listed under "Chats".
  private var combinedPeopleResults: [ContactSearchUser] {
    var seen = Set<String>()
    var out: [ContactSearchUser] = []
    for user in agentSuggestions(for: trimmedHomeQuery) + globalResults {
      if seen.insert(user.userID.uppercased()).inserted { out.append(user) }
    }
    let existingPeerIds = Set(filteredRows.compactMap { $0.peerUserId?.uppercased() })
    return out.filter { !existingPeerIds.contains($0.userID.uppercased()) }
  }

  @MainActor
  private func runGlobalSearch() async {
    let q = trimmedHomeQuery
    guard q.count >= 2 else {
      globalResults = []
      return
    }
    try? await Task.sleep(nanoseconds: 300_000_000)
    if Task.isCancelled { return }
    guard let config = AppSessionConfig.current else { return }
    isGlobalSearching = true
    defer { isGlobalSearching = false }
    let found = (try? await ContactSearchService.search(config: config, query: q)) ?? []
    if Task.isCancelled { return }
    globalResults = found
  }

  private func openLocalChatRow(_ row: ChatHomeListRow) {
    model.markLocalRead(chatID: row.chatId)
    if !row.isBuiltInAgentSurface, !row.isBridgeAgentSurface, !row.initialMessages.isEmpty {
      ChatEngine.shared.seedRecentChatHistory(
        chatId: row.chatId, messages: row.initialMessages, limit: 3)
    }
    coordinator.openChat(ChatRoute(row: row))
  }

  private func handleGlobalUserTap(_ user: ContactSearchUser) {
    // Must go through closeHomeSearch — a bare state flip would leave the nav
    // bar faded/non-interactive forever.
    closeHomeSearch()
    Task { _ = await openChat(for: user) }
  }

  /// Rows shown in the home table: full list, or filtered when searching with a query.
  /// Focus alone does not swap the table away (avoids flash) — recent avatars open in-header.
  private var homeListDisplayRows: [ChatHomeListRow] {
    if isHomeSearchFocused && !trimmedHomeQuery.isEmpty {
      return filteredRows
    }
    return filteredRows
  }

  private var recentSearchRows: [ChatHomeListRow] {
    filteredRows.filter { !$0.isArchiveEntry }.prefix(16).map { $0 }
  }

  private func openHomeSearch() {
    guard !isHomeSearchFocused else { return }
    SearchMorphProfiler.shared.begin("open")
    searchCloseRetracting = false
    setTabBarHidden(true, animated: true)
    // Header is a pure fade — it never rides the vertical transition. The UIKit
    // alpha fade also disables bar interaction so the nav band passes touches
    // through to the docked field.
    setNavigationBarFaded(true)
    if isEditingHome {
      isEditingHome = false
      selectedChatIDs.removeAll()
    }
    // Two-commit staging. THIS commit is tiny: it only flips the pose flag,
    // and the native controller commits the surface ride + chrome crossfade
    // to the render server inside it. The HEAVY reveal (sheet visibility,
    // clear background, hit gating) lands one runloop later — its ~60ms
    // main-thread stall then runs UNDER the already-committed server-side
    // animations, which keep playing through it. Committing motion and reveal
    // together let the stall eat the first frames every time: "the input
    // disappears instead of traveling".
    searchPresented = true
    DispatchQueue.main.async {
      isHomeSearchFocused = true
    }
  }

  private func closeHomeSearch() {
    guard searchPresented || isHomeSearchFocused, !searchCloseRetracting else { return }
    SearchMorphProfiler.shared.begin("close")
    // Phase 1 (native side reacts to this flag in THIS commit): the focused
    // chrome (glass input + X) starts fading out in place, the keyboard
    // drops, and the old surface — capsule riding its header — starts its
    // descent in the same apply. The X-tap path has already done all of it
    // UIKit-side before this commit exists.
    searchCloseRetracting = true
    // By +0.18 the descent is long committed to the render server; this pose
    // commit only restores chrome (chips/nav/tab fade back in over the moving
    // descent) and its ~40ms body re-eval lands in the spring's tail, where
    // a main-thread stall can't freeze anything visible.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
      setNavigationBarFaded(false)
      SearchMorphProfiler.mark("swiftui pose commit")
      // ONLY the pose flag flips here — the query/results clear is a heavy
      // SwiftUI rebuild (results→recents) and clearing it in this commit
      // stalled the descent's first frames.
      searchPresented = false
      setTabBarHidden(isEditingHome, animated: true)
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
        // Descent is committed to the render server by now — the rebuild's
        // stall lands under an already-running CA animation, invisibly.
        homeSearchQuery = ""
        globalResults = []
      }
      // Phase 3: drop the sheet gate after landing — the capsule needs no
      // reattach: it never left the table header, so identity transform IS
      // the landed state.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
        SearchMorphProfiler.mark("overlay gate off")
        isHomeSearchFocused = false
        searchCloseRetracting = false
      }
    }
  }

  var body: some View {
    NavigationStack {
      ZStack {
        // The unfocused search bar is a PINNED UIKit sibling above the table
        // (collapses its height on scroll, native searchable) — NOT a
        // tableHeaderView and not a SwiftUI safeAreaInset (that fought UIKit
        // contentInset and covered cells).
        listContent
          .ignoresSafeArea(.container, edges: [.top, .bottom])
          // The keyboard must NEVER resize this surface: it rises mid-flight
          // and SwiftUI's avoidance would compress the table right in the
          // spring's fast phase — a layout jump completely outside the
          // animation ("the list is jumping, separated from the search").
          .ignoresSafeArea(.keyboard, edges: .bottom)
          // The background goes CLEAR the instant search focuses: the results
          // sheet (identical palette background) sits BEHIND the list, so the
          // swap is pixel-invisible — and the cells fading out then REVEAL the
          // results that were "already there". Restored instantly at gate-off.
          .background(
            (isHomeSearchFocused ? Color.clear : palette.background)
              .ignoresSafeArea()
          )
          .allowsHitTesting(!isHomeSearchFocused)
          .zIndex(1)

        // Focused search results sheet — PERMANENTLY mounted, pre-warmed, and
        // BELOW the list: it never animates (no fade, no motion). The home
        // cells fading out over it are the reveal; the docked input fades in
        // (in place, never moving) in a UIKit window overlay above everything.
        HomeTelegramSearchView(
          query: $homeSearchQuery,
          visible: isHomeSearchFocused,
          recentRows: recentSearchRows,
          filteredChats: filteredRows.filter { !$0.isArchiveEntry || trimmedHomeQuery.isEmpty },
          people: combinedPeopleResults,
          isGlobalSearching: isGlobalSearching,
          isDark: colorScheme == .dark,
          palette: palette,
          onSelectChat: { openLocalChatRow($0) },
          onSelectPerson: { handleGlobalUserTap($0) }
        )
        // Static sheet: the keyboard must not compress it either — its own
        // scroll view handles content that ends up under the keyboard.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .allowsHitTesting(isHomeSearchFocused)
        .zIndex(0)

        // Edit pills: fixed overlay in the tab-bar band (tab bar only fades).
        if isEditingHome && !isHomeSearchFocused {
          VStack {
            Spacer(minLength: 0)
            ChatHomeEditActionBar(
              selectedCount: selectedChatIDs.count,
              isDark: colorScheme == .dark,
              onMarkRead: { Task { await performHomeEditAction(.markRead) } },
              onMute: { Task { await performHomeEditAction(.mute) } },
              onDelete: { Task { await performHomeEditAction(.delete) } }
            )
            // Sit just above the home indicator — light gap, not full tab-bar height.
            .padding(.bottom, 20)
          }
          .ignoresSafeArea(.container, edges: .bottom)
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .zIndex(2)
        }

        if let pendingDeletion {
          VStack {
            Spacer()
            ChatHomeDeletionUndoToast(
              deletion: pendingDeletion,
              palette: palette,
              undo: undoPendingHomeDelete
            )
            .padding(.horizontal, 14)
            .padding(.bottom, 0)
            .transition(.scale(scale: 0.94).combined(with: .opacity).animation(.easeOut(duration: 0.25)))
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .allowsHitTesting(true)
          .zIndex(4)
        }

        if let confirmation = pendingDeleteConfirmation {
          ChatHomeDeleteDialogView(
            confirmation: confirmation,
            palette: palette,
            deleteForMe: {
              beginPendingHomeDelete(row: confirmation.row, deleteForEveryone: false)
            },
            deleteForEveryone: confirmation.allowsDeleteForEveryone
              ? {
                beginPendingHomeDelete(row: confirmation.row, deleteForEveryone: true)
              } : nil,
            cancel: {
              pendingDeleteConfirmation = nil
            }
          )
          .transition(.opacity.combined(with: .scale(scale: 0.98)))
          .zIndex(5)
        }
      }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: pendingDeletion?.id)
        .animation(.spring(response: 0.22, dampingFraction: 0.9), value: pendingDeleteConfirmation?.id)
        .animation(.easeInOut(duration: 0.22), value: isEditingHome)
        .navigationBarTitleDisplayMode(.inline)
        // The bar is NEVER hidden — hiding collapses the top safe area, which
        // re-insets the table (rows jump) and Y-slides the bar itself. Search
        // focus fades the item contents in place (plus the UIKit bar alpha via
        // setNavigationBarFaded, which also lets band touches reach the docked
        // field). The header never translates.
        // Trailing chrome stays mounted and fades (opacity) on edit/search —
        // never `if !editing` remove, which pops.
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button(isEditingHome ? "Done" : "Edit") {
              withAnimation(.easeInOut(duration: 0.22)) {
                isEditingHome.toggle()
                if !isEditingHome {
                  selectedChatIDs.removeAll()
                }
              }
            }
            .fontWeight(.semibold)
            .tint(colorScheme == .dark ? .white : .black)
            .disabled(filteredRows.isEmpty && !isEditingHome)
            .opacity(searchPresented ? 0 : 1)
            .animation(.easeInOut(duration: 0.16), value: searchPresented)
            .allowsHitTesting(!isHomeSearchFocused)
          }

          ToolbarItem(placement: .principal) {
            AppHomeStatusHeaderView(
              state: model.headerState,
              palette: palette
            )
            .opacity(searchPresented ? 0 : 1)
            .animation(.easeInOut(duration: 0.16), value: searchPresented)
            .allowsHitTesting(!isHomeSearchFocused)
          }

          // System glass sizing (native padding). Fully omit the item in edit
          // so the whole top-right capsule leaves — not an empty glass shell.
          // Search keeps the item mounted and fades it (nav bar also fades).
          if !isEditingHome {
            ToolbarItem(placement: .topBarTrailing) {
              HStack(spacing: 18) {
                // No separate search button here — the list already carries its
                // own inline animated search capsule (tap it directly); a second
                // magnifying-glass in the header was pure duplication.
                Button {
                  isShowingProxy = true
                } label: {
                  AppProxyShieldIcon(
                    isActive: proxyBadge.shieldActive,
                    tint: proxyBadge.tint(palette: palette)
                  )
                  .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel(proxyBadge.accessibilityLabel)

                Button {
                  coordinator.openStory()
                } label: {
                  AppVectorIcon(glyph: .story, tint: colorScheme == .dark ? .white : .black)
                    .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())

                Button {
                  isShowingSearch = true
                } label: {
                  AppVectorIcon(glyph: .compose, tint: colorScheme == .dark ? .white : .black)
                    .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
              }
              .padding(.horizontal, 6)
              .opacity(searchPresented ? 0 : 1)
              .animation(.easeInOut(duration: 0.16), value: searchPresented)
              .allowsHitTesting(!isHomeSearchFocused)
            }
          }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        // Search entry lives in UITableView.tableHeaderView (not safeAreaInset).
        .onChange(of: isHomeSearchFocused) { _, isPresented in
          if isPresented {
            setTabBarHidden(true, animated: true)
            if isEditingHome {
              isEditingHome = false
              selectedChatIDs.removeAll()
            }
          } else {
            if !homeSearchQuery.isEmpty {
              homeSearchQuery = ""
            }
            globalResults = []
            setTabBarHidden(isEditingHome, animated: true)
          }
        }
        .onChange(of: isEditingHome) { _, editing in
          setTabBarHidden(editing, animated: true)
        }
        .onDisappear {
          if isEditingHome {
            setTabBarHidden(false, animated: false)
          }
        }
        .navigationDestination(isPresented: $isShowingArchivedChats) {
          ArchivedChatHomeListScreen(
            model: model,
            palette: palette,
            isDark: colorScheme == .dark,
            hiddenChatIDs: locallyHiddenChatIDs,
            openRow: openLocalChatRow,
            performAction: performHomeRowAction
          )
        }
    }
    .task {
      AppUITrace.notice("ChatHomeScreen task loadIfNeeded")
      await model.loadIfNeeded()
      await model.loadArchivedIfNeeded()
      refreshProxyBadge()
    }
    .onReceive(NotificationCenter.default.publisher(for: PacketProxyStore.didChangeNotification)) { _ in
      refreshProxyBadge()
    }
    .onReceive(NotificationCenter.default.publisher(for: ChatEngine.didChangeNotification)) { _ in
      refreshProxyBadge()
    }
    .task {
      // A desktop-started Codex task now reaches Home as a `bridge-status` push on
      // the socket, so this loop no longer has to discover it. It stays only as a
      // slow safety net for a wedged socket, and skips the request outright while a
      // recent snapshot exists. SwiftUI cancels it when Home disappears.
      while !Task.isCancelled {
        if let config = AppSessionConfig.current {
          await AgentPairingService.refreshStatusIfStale(config: config)
        }
        try? await Task.sleep(nanoseconds: AgentPairingService.statusFallbackIntervalNanos)
      }
    }
    .task(id: homeSearchQuery) {
      await runGlobalSearch()
    }
    .onAppear {
      AppUITrace.notice(
        "ChatHomeScreen onAppear rows=\(model.rows.count) searchRequest=\(coordinator.chatSearchPresentationRequestID)"
      )
      AppUIStallWatchdog.shared.updateContext("ChatHomeScreen appear rows=\(model.rows.count)")
      // Warm the agent-bridge connection status NOW, while the user is still reading the
      // chat list, so opening a Claude/Codex DM resolves the composer-vs-connect-panel
      // gate instantly instead of hiding the input for a network round-trip (the 4–5s
      // late-input + flicker). Throttled, background, non-throwing.
      if let config = AppSessionConfig.current {
        AgentPairingService.warmStatusIfStale(config: config)
        chatNativeWarmOwnedAgentIds(config: config)
      }
      // We no longer present the modal on appear, as we now use search focus
    }
    .onChange(of: coordinator.chatSearchPresentationRequestID) { _, _ in
      AppUITrace.notice(
        "ChatHomeScreen searchRequest changed requestId=\(coordinator.chatSearchPresentationRequestID) selectedTab=\(coordinator.selectedTab)"
      )
      openHomeSearch()
    }
    .sheet(isPresented: $isShowingSearch, onDismiss: presentQueuedSavedContact) {
      if let config = AppSessionConfig.current {
        NavigationStack {
          ContactSearchView(config: config, homeRows: visibleHomeRows) { payload in
            handleSearchPayload(payload)
          }
        }
      }
    }
    .sheet(item: $pendingSavedContact) { user in
      ContactActionSheet(
        user: user,
        onChat: {
          pendingSavedContact = nil
          Task { _ = await openChat(for: user) }
        },
        onCall: {
          pendingSavedContact = nil
          Task {
            let route = await openChat(for: user)
            if let route {
              NativeCallRouteBridge.startOutgoing(route: route, callType: "voice")
            }
          }
        }
      )
    }
    .sheet(isPresented: $isShowingProxy) {
      NavigationStack {
        ProxySheetView(onDismiss: {
          isShowingProxy = false
          refreshProxyBadge()
        })
      }
    }
    .sheet(isPresented: $isShowingGroupCreation, onDismiss: openPendingCreatedRoom) {
      if let config = AppSessionConfig.current {
        ChatGroupCreationSheet(config: config, homeRows: visibleHomeRows) { route in
          model.projectCreatedRoom(route)
          pendingCreatedRoomRoute = route
          isShowingGroupCreation = false
          Task { await model.refresh() }
        }
      }
    }
    .sheet(isPresented: $isShowingChannelCreation, onDismiss: openPendingCreatedRoom) {
      if let config = AppSessionConfig.current {
        ChannelCreationSheet(config: config) { route in
          model.projectCreatedRoom(route)
          pendingCreatedRoomRoute = route
          isShowingChannelCreation = false
          Task { await model.refresh() }
        }
      }
    }
  }

  private func refreshProxyBadge() {
    let enabled = PacketProxyStore.shared.useProxy
    let config = ChatEngineStore.shared.getConfig()
    let status = (config["packetStatus"] as? String)?.lowercased() ?? "idle"
    let port: Int
    if let value = config["packetProxyPort"] as? NSNumber {
      port = value.intValue
    } else if let value = config["packetProxyPort"] as? String {
      port = Int(value) ?? 0
    } else {
      port = 0
    }

    let state: HomeProxyBadge.State
    if !enabled {
      state = .off
    } else if status == "failed" || status.contains("error") {
      state = .error
    } else if port > 0 || ["running", "connected", "ready", "bootstrap_ready"].contains(status) {
      state = .active
    } else {
      state = .starting
    }
    proxyBadge = HomeProxyBadge(state: state)
  }

  private func openPendingCreatedRoom() {
    guard let route = pendingCreatedRoomRoute else { return }
    pendingCreatedRoomRoute = nil
    coordinator.openChat(route)
  }


  @ViewBuilder
  private var listContent: some View {
    if !hasHomeRowsForAnyScope && (!model.hasLoaded || model.isLoading) {
      AppListLoadingView(palette: palette, caption: "Loading chats")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
    } else if !hasHomeRowsForAnyScope {
      AppShellEmptyStateView(
        icon: """
        <?xml version="1.0" encoding="utf-8"?><svg fill="none" viewBox="0 0 800 600" xmlns="http://www.w3.org/2000/svg"><defs><clipPath id="cp-800-600"><rect height="600" width="800" y="0" x="0" /></clipPath><g id="comp_0"><g opacity="0" id="planete Outlines - Group 5"><animate repeatCount="indefinite" attributeName="opacity" dur="3s" begin="0s" calcMode="spline" values="0; 1; 1; 0" keyTimes="0; 0.3; 0.68; 1" keySplines="0.333 0 0.667 1; 0.333 0 0.667 1; 0.333 0 0.667 1" fill="freeze" /><g transform="translate(327.38,267.583)"><animateTransform repeatCount="indefinite" type="translate" attributeName="transform" dur="3s" begin="0s" calcMode="spline" values="327.38 267.583; 482.38 267.583" keyTimes="0; 1" keySplines="0 0 1 1" fill="freeze" /><g transform="scale(0.5,0.5) translate(-171.76,-193.166)"><g id="Group 5" transform="matrix(1,0,0,1,171.76,193.166)"><path fill="#d0d2d3" fill-opacity="1" d="M59.669,-8.242C53.143,-8.242,47.22,-5.677,42.84,-1.506C42.047,-23.225,24.2,-40.592,2.287,-40.592C-17.519,-40.592,-34.001,-26.403,-37.576,-7.638C-39.31,-8.029,-41.111,-8.242,-42.962,-8.242C-56.447,-8.242,-67.378,2.69,-67.378,16.174C-67.378,16.467,-67.367,16.758,-67.356,17.049C-68.756,16.49,-70.279,16.174,-71.878,16.174C-78.62,16.174,-84.086,21.64,-84.086,28.383C-84.086,35.125,-78.62,40.591,-71.878,40.591L59.669,40.591C73.154,40.591,84.086,29.659,84.086,16.174C84.086,2.69,73.154,-8.242,59.669,-8.242Z" /></g></g></g></g><g id="Merged Shape Layer"><g transform="translate(390.319,298.2)"><animateTransform repeatCount="indefinite" type="translate" attributeName="transform" dur="3s" begin="0s" calcMode="spline" values="390.319 298.2; 390.319 282.7; 390.319 319.25; 390.319 298.2" keyTimes="0; 0.293; 0.733; 1" keySplines="0.333 0 0.667 1; 0.333 0 0.667 1; 0.333 0 0.667 1" fill="freeze" /><g transform="rotate(0)"><animateTransform repeatCount="indefinite" type="rotate" attributeName="transform" dur="3s" begin="0s" calcMode="spline" values="0; 35; 0" keyTimes="0; 0.513; 1" keySplines="0.547 0 0.667 1; 0.333 0 0.845 1" fill="freeze" /><g transform="scale(1,1) translate(-664.319,-256.2)"><g id="planete Outlines - Group 3" transform="matrix(0.5,0,0,0.5,515.5,129)"><g id="Group 3" transform="matrix(1,0,0,1,297.638,254.4)"><path fill="#5d68f9" fill-opacity="1" d="M-133.812,-42.171L133.812,-75.141L5.765,75.141L-61.708,18.402L124.227,-71.307L-87.011,-1.534L-133.812,-42.171Z" /></g></g><g id="planete Outlines - Group 2" transform="matrix(0.5,0,0,0.5,515.5,129)"><g id="Group 2" transform="matrix(1,0,0,1,316.247,247.882)"><path fill="#474bd8" fill-opacity="1" d="M-98.335,64.79L-105.619,4.984L105.619,-64.79L-80.316,24.919L-98.335,64.79Z" /></g></g><g id="planete Outlines - Group 1" transform="matrix(0.5,0,0,0.5,515.5,129.001)"><g id="Group 1" transform="matrix(1,0,0,1,236.879,292.737)"><path fill="#3931ac" fill-opacity="1" d="M18.967,-3.189L-18.967,19.935L-0.949,-19.935L18.967,-3.189Z" /></g></g></g></g></g></g><g opacity="0" id="planete Outlines - Group 4"><animate repeatCount="indefinite" attributeName="opacity" dur="2.4s" begin="0s" calcMode="spline" values="0; 0.5; 0.5; 0" keyTimes="0; 0.317; 0.733; 1" keySplines="0 0 1 1; 0 0 1 1; 0 0 1 1" fill="freeze" /><g transform="translate(468.336,323.378)"><animateTransform repeatCount="indefinite" type="translate" attributeName="transform" dur="2.04s" begin="0s" calcMode="spline" values="468.336 323.378; 294.336 323.378" keyTimes="0; 1" keySplines="0 0 1 1" fill="freeze" /><g transform="scale(0.5,0.5) translate(-453.672,-304.756)"><g id="Group 4" transform="matrix(1,0,0,1,453.672,304.756)"><path fill="#d0d2d3" fill-opacity="1" d="M75.134,16.175C74.353,16.175,73.591,16.256,72.85,16.396C72.851,16.322,72.856,16.249,72.856,16.175C72.856,2.691,61.924,-8.241,48.44,-8.241C46.662,-8.241,44.931,-8.046,43.262,-7.685C39.668,-26.427,23.196,-40.591,3.406,-40.591C-16.624,-40.591,-33.254,-26.077,-36.571,-6.995C-38.992,-7.799,-41.578,-8.241,-44.269,-8.241C-57.754,-8.241,-68.685,2.691,-68.685,16.175C-68.685,16.817,-68.652,17.45,-68.604,18.079C-70.494,16.88,-72.728,16.175,-75.133,16.175C-81.875,16.175,-87.341,21.641,-87.341,28.383C-87.341,35.126,-81.875,40.592,-75.133,40.592L75.134,40.592C81.876,40.592,87.342,35.126,87.342,28.383C87.342,21.641,81.876,16.175,75.134,16.175Z" /></g></g></g></g></g></defs><g transform="matrix(1.79,0,0,1.79,-310,-231)" id="Pre-comp 1"><use clip-path="url(#cp-800-600)" height="600" width="800" y="0" x="0" xlink:href="#comp_0" href="#comp_0" /></g></svg>
        """,
        title: model.isWaitingForNetwork ? "Connecting" : "No Messages Yet",
        message: errorMessage ?? model.errorMessage
          ?? (model.isWaitingForNetwork
            ? "Your chats will stay here when the connection returns."
            : "Start a conversation to catch the vibe."),
        buttonTitle: "New Chat",
        palette: palette
      ) {
        isShowingSearch = true
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(palette.background)
    } else {
      ChatHomeNativeListRepresentable(
        rows: filteredRows,
        isDark: colorScheme == .dark,
        isEditing: isEditingHome && !isHomeSearchFocused,
        showsRightCheckmark: false,
        selectedChatIDs: selectedChatIDs,
        // In-list full-capsule search (tableHeaderView) — scrolls with rows, no
        // safeAreaInset / contentInset fight with the UIKit table.
        searchText: $homeSearchQuery,
        isSearchFocused: Binding(
          // The native list keys off the animated POSE alone (searchPresented):
          // motion starts in the tiny pose commit, one runloop BEFORE the
          // heavy reveal commit (isHomeSearchFocused), and restores when the
          // descent starts (not at the later unmount).
          get: { searchPresented },
          set: { focused in
            if focused {
              openHomeSearch()
            } else if searchPresented || isHomeSearchFocused {
              closeHomeSearch()
            }
          }
        ),
        isSearchOverlayVisible: isHomeSearchFocused,
        // Close phase 1: native side retracts the xmark and re-widens the
        // (flying) capsule at the dock before the descent.
        isSearchRetracting: searchCloseRetracting,
        searchDissolveBackground: palette.backgroundUIColor,
        recentRows: recentSearchRows,
        peopleResults: combinedPeopleResults,
        isGlobalSearching: isGlobalSearching,
        onSelect: { row in
          if row.isArchiveEntry {
            selectedChatIDs.removeAll()
            isShowingArchivedChats = true
            Task { await model.loadArchivedIfNeeded() }
            return
          }
          AppUITrace.notice(
            "ChatHomeScreen select chatId=\(String(row.chatId.prefix(12))) title=\(row.title) rows=\(model.rows.count) initialMessages=\(row.initialMessages.count)"
          )
          AppUIStallWatchdog.shared.updateContext(
            "ChatHomeScreen select chatId=\(String(row.chatId.prefix(12))) rows=\(model.rows.count)"
          )
          if !row.isBuiltInAgentSurface, !row.isBridgeAgentSurface, !row.initialMessages.isEmpty {
            ChatEngine.shared.seedRecentChatHistory(
              chatId: row.chatId,
              messages: row.initialMessages,
              limit: 3
            )
          }
          model.markLocalRead(chatID: row.chatId)
          coordinator.openChat(ChatRoute(row: row))
        },
        onToggleSelection: { chatID in
          toggleHomeSelection(chatID)
        },
        onAction: { action, row in
          performHomeRowAction(action, row: row)
        },
        onSelectPerson: { handleGlobalUserTap($0) },
        onRefresh: {
          await model.refreshAll()
        },
        onUnavailableAction: { AppToastController.shared.show($0) }
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func toggleHomeSelection(_ chatID: String) {
    AppUITrace.notice(
      "ChatsRootView toggleSelection chatId=\(String(chatID.prefix(12))) selectedBefore=\(selectedChatIDs.count)"
    )
    if selectedChatIDs.contains(chatID) {
      selectedChatIDs.remove(chatID)
    } else {
      selectedChatIDs.insert(chatID)
    }
  }

  /// Open the "talk to the agent" surface from the header sparkles button. Reuses
  /// the existing native agent view (`ChatNativeAgentView`) which already streams
  /// over the `agent:<userId>` socket, hosted with the same `ChatInputBar`
  /// composer the chat uses.
  private func openAgentChat() {
    AppUITrace.notice("ChatHomeScreen openAgentChat: opening native agent conversation")
    coordinator.openAgentConversation()
  }

  @MainActor
  private func performHomeEditAction(_ action: ChatHomeEditBulkAction) async {
    guard !selectedChatIDs.isEmpty else { return }
    guard let config = AppSessionConfig.current else {
      AppToastController.shared.show("The current session is unavailable.")
      return
    }

    let chatIDs = Array(selectedChatIDs)
    AppUITrace.notice(
      "ChatsRootView bulkAction start action=\(action) selected=\(chatIDs.count)"
    )
    do {
      try await ChatHomeEditService.apply(action: action, chatIDs: chatIDs, config: config)
      selectedChatIDs.removeAll()
      isEditingHome = false
      setTabBarHidden(false, animated: true)
      await model.refresh()
      AppUITrace.notice("ChatsRootView bulkAction done action=\(action)")
    } catch {
      AppUITrace.error("ChatsRootView bulkAction error action=\(action) error=\(error.localizedDescription)")
      AppToastController.shared.show(error.localizedDescription)
    }
  }

  /// Same philosophy as `setTabBarHidden`: fade only, never hide. Hiding the
  /// bar collapses the top safe area — the table's contentInset tracks it and
  /// every row jumps ("home is shifting"), and the system Y-slides the bar.
  /// With alpha 0 + interaction off, the band stays reserved, the header fades
  /// in place, and touches fall through to the search field docked in the band.
  private func setNavigationBarFaded(_ faded: Bool) {
    guard let tab = coordinator.tabBarController,
      let rootView = tab.selectedViewController?.view,
      let bar = Self.findNavigationBar(in: rootView)
    else { return }
    bar.isUserInteractionEnabled = !faded
    UIView.animate(
      withDuration: faded ? 0.16 : 0.20,
      delay: 0,
      options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]
    ) {
      bar.alpha = faded ? 0.0 : 1.0
    }
  }

  private static func findNavigationBar(in view: UIView) -> UINavigationBar? {
    if let bar = view as? UINavigationBar { return bar }
    for sub in view.subviews {
      if let bar = findNavigationBar(in: sub) { return bar }
    }
    return nil
  }

  private func setTabBarHidden(_ hidden: Bool, animated: Bool) {
    guard let tab = coordinator.tabBarController else { return }
    let tabBar = tab.tabBar
    // Fade only — never isHidden. Hiding the tab bar collapses safe area and
    // jumps edit pills / list content. Keep layout band; fade like trailing icons.
    tabBar.isHidden = false
    tabBar.isUserInteractionEnabled = !hidden
    let target: CGFloat = hidden ? 0 : 1
    if animated {
      UIView.animate(
        withDuration: 0.18,
        delay: 0,
        options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]
      ) {
        tabBar.alpha = target
      }
    } else {
      tabBar.alpha = target
    }
  }

  private func performHomeRowAction(_ action: ChatHomeRowAction, row: ChatHomeListRow) {
    guard row.supportsRemoteHomeActions else {
      AppToastController.shared.show("This chat is stored locally and cannot use server actions.")
      return
    }

    if action == .delete {
      requestHomeDelete(row: row)
      return
    }

    guard let config = AppSessionConfig.current else {
      AppToastController.shared.show("The current session is unavailable.")
      return
    }

    // Mark as unread / read is a local list projection first. It used to change nothing
    // until a POST and a full list reload had both finished, so the badge the user just
    // asked for appeared a round trip late.
    var revertUnread: (unreadCount: Int, markedUnread: Bool)?
    if case .markUnread(let unread) = action {
      revertUnread = model.applyLocalUnread(chatID: row.chatId, unread: unread)
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    Task { @MainActor in
      do {
        try await ChatHomeEditService.apply(action: action, chatID: row.chatId, config: config)
        selectedChatIDs.remove(row.chatId)
        if revertUnread == nil {
          UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        await model.refreshAll()
      } catch {
        if let revertUnread {
          model.restoreLocalUnread(
            chatID: row.chatId,
            unreadCount: revertUnread.unreadCount,
            markedUnread: revertUnread.markedUnread
          )
        }
        AppUITrace.error(
          "ChatHomeScreen rowAction error chatId=\(String(row.chatId.prefix(12))) error=\(error.localizedDescription)"
        )
        AppToastController.shared.show(error.localizedDescription)
      }
    }
  }

  private func requestHomeDelete(row: ChatHomeListRow) {
    openPendingSwipeIfNeeded()
    pendingDeleteConfirmation = ChatHomeDeleteConfirmation(row: row)
  }

  private func openPendingSwipeIfNeeded() {
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder),
      to: nil,
      from: nil,
      for: nil
    )
  }

  private func beginPendingHomeDelete(row: ChatHomeListRow, deleteForEveryone: Bool) {
    if let previous = pendingDeletion {
      pendingDeletionTask?.cancel()
      Task { @MainActor in
        await commitHomeDelete(previous)
      }
    }

    pendingDeleteConfirmation = nil
    locallyHiddenChatIDs.insert(row.chatId)
    model.removeLocalChat(chatID: row.chatId, persist: true)
    selectedChatIDs.remove(row.chatId)
    let deletion = ChatHomePendingDeletion(
      row: row,
      deleteForEveryone: deleteForEveryone,
      duration: 5
    )
    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
      pendingDeletion = deletion
    }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    _ = ChatEngine.shared.clearChat([
      "chatId": row.chatId,
      "localOnly": true,
    ])

    pendingDeletionTask?.cancel()
    pendingDeletionTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: UInt64(deletion.duration * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await commitHomeDelete(deletion)
    }
  }

  private func undoPendingHomeDelete() {
    guard let deletion = pendingDeletion else { return }
    pendingDeletionTask?.cancel()
    pendingDeletionTask = nil
    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
      pendingDeletion = nil
    }
    locallyHiddenChatIDs.remove(deletion.row.chatId)
    model.restoreLocalRow(deletion.row)
    if !deletion.row.initialMessages.isEmpty {
      ChatEngine.shared.seedRecentChatHistory(
        chatId: deletion.row.chatId,
        messages: deletion.row.initialMessages,
        limit: 5
      )
    }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }

  @MainActor
  private func commitHomeDelete(_ deletion: ChatHomePendingDeletion) async {
    guard let config = AppSessionConfig.current else {
      restoreFailedHomeDelete(deletion, message: "The current session is unavailable.")
      return
    }

    do {
      try await ChatHomeEditService.deleteChat(
        chatID: deletion.row.chatId,
        config: config,
        deleteForEveryone: deletion.deleteForEveryone
      )
      if pendingDeletion?.id == deletion.id {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
          pendingDeletion = nil
        }
        pendingDeletionTask = nil
      }
      selectedChatIDs.remove(deletion.row.chatId)
      await model.refreshAll()
      AppUITrace.notice(
        "ChatHomeScreen delete committed chatId=\(String(deletion.row.chatId.prefix(12))) forEveryone=\(deletion.deleteForEveryone ? "Y" : "N")"
      )
    } catch {
      restoreFailedHomeDelete(deletion, message: error.localizedDescription)
      AppUITrace.error(
        "ChatHomeScreen delete failed chatId=\(String(deletion.row.chatId.prefix(12))) error=\(error.localizedDescription)"
      )
    }
  }

  private func restoreFailedHomeDelete(_ deletion: ChatHomePendingDeletion, message: String) {
    if pendingDeletion?.id == deletion.id {
      withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
        pendingDeletion = nil
      }
      pendingDeletionTask = nil
    }
    locallyHiddenChatIDs.remove(deletion.row.chatId)
    model.restoreLocalRow(deletion.row)
    if !deletion.row.initialMessages.isEmpty {
      ChatEngine.shared.seedRecentChatHistory(
        chatId: deletion.row.chatId,
        messages: deletion.row.initialMessages,
        limit: 5
      )
    }
    AppToastController.shared.show(message)
  }

  private func handleSearchPayload(_ payload: [String: Any]) {
    guard let action = payload["action"] as? String else {
      isShowingSearch = false
      return
    }

    if action == "cancel" {
      isShowingSearch = false
      return
    }

    if action == "createdRoom", let route = payload["route"] as? ChatRoute {
      isShowingSearch = false
      model.projectCreatedRoom(route)
      pendingCreatedRoomRoute = route
      Task { await model.refresh() }
      return
    }

    if action == "newContact" {
      isShowingSearch = true
      return
    }

    if action == "newGroup" || action == "newChannel" {
      isShowingSearch = false
      roomCreationName = ""
      if action == "newGroup" {
        isShowingGroupCreation = true
      } else {
        isShowingChannelCreation = true
      }
      return
    }

    guard
      ["select", "chat", "call", "saveContact"].contains(action),
      let rawUser = payload["user"] as? [String: Any],
      let user = ContactSearchUser(payload: rawUser)
    else {
      isShowingSearch = false
      errorMessage = "The selected user could not be opened."
      return
    }

    if action == "saveContact" {
      queuedSavedContact = user
      isShowingSearch = false
      return
    }

    isShowingSearch = false
    Task {
      let route = await openChat(for: user)
      if action == "call", let route {
        NativeCallRouteBridge.startOutgoing(route: route, callType: "voice")
      }
    }
  }

  private func presentQueuedSavedContact() {
    guard let user = queuedSavedContact else { return }
    queuedSavedContact = nil
    pendingSavedContact = user
  }

  @MainActor
  private func openChat(for user: ContactSearchUser) async -> ChatRoute? {
    guard let config = AppSessionConfig.current else {
      errorMessage = "The current session is unavailable."
      return nil
    }

    // Instant path: chat already on the home list — don't wait on POST /chat
    // (was ~20–30s when packet fallback ran after a flaky create).
    let peerKey = user.userID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let existing = model.rows.first(where: {
      ($0.peerUserId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == peerKey
        && !$0.isGroup
    }) {
      openLocalChatRow(existing)
      return ChatRoute(row: existing)
    }

    isStartingChat = true
    errorMessage = nil
    defer { isStartingChat = false }

    let isBridgeAgent = user.bridgeProvider != nil || user.isAgent
    do {
      let result = try await ChatDirectMessageService.startChat(
        config: config,
        friendID: user.userID
      )
      if let publicKey = user.publicKey, !publicKey.isEmpty {
        _ = ChatEngine.shared.cachePeerPublicKey([
          "chatId": result.chatID,
          "peerUserId": user.userID,
          "publicKey": publicKey,
        ])
      }
      let route = ChatRoute(
        chatId: result.chatID,
        title: user.username,
        peerUserId: user.userID,
        peerAgentId: user.bridgeAgentRouteId,
        isAgent: user.isAgent || user.bridgeProvider != nil,
        avatarURI: ChatAvatarURLResolver.resolve(
          rawAvatar: user.profileImage,
          peerUserId: user.userID,
          chatId: result.chatID,
          preferPushAvatar: false,
          isAgent: user.isAgent || user.bridgeProvider != nil,
          agentId: user.agentId ?? user.bridgeAgentRouteId,
          displayName: user.handle ?? user.username
        ),
        isGroup: false,
        initialRows: result.messages,
        bridgeProvider: user.bridgeProvider
      )
      // Open immediately — refresh home in the background so a slow list reload
      // never blocks navigation (chat used to land only after refresh).
      coordinator.openChat(route)
      Task { await model.refresh() }
      return route
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }
}


private struct ChatHomeDeleteConfirmation: Identifiable {
  let id = UUID()
  let row: ChatHomeListRow

  var allowsDeleteForEveryone: Bool {
    row.peerUserId != nil && !row.isGroup && !row.isBuiltInAgentSurface
  }
}

private struct ChatHomePendingDeletion: Identifiable {
  let id = UUID()
  let row: ChatHomeListRow
  let deleteForEveryone: Bool
  let startedAt: Date
  let expiresAt: Date
  let duration: TimeInterval

  init(row: ChatHomeListRow, deleteForEveryone: Bool, duration: TimeInterval) {
    let now = Date()
    self.row = row
    self.deleteForEveryone = deleteForEveryone
    self.startedAt = now
    self.duration = duration
    self.expiresAt = now.addingTimeInterval(duration)
  }
}

private struct ChatHomeDeleteDialogView: View {
  let confirmation: ChatHomeDeleteConfirmation
  let palette: AppThemePalette
  let deleteForMe: () -> Void
  let deleteForEveryone: (() -> Void)?
  let cancel: () -> Void

  var body: some View {
    ZStack {
      Color.black.opacity(0.28)
        .ignoresSafeArea()
        .onTapGesture(perform: cancel)

      VStack(spacing: 16) {
        ChatHomeDeleteAvatarView(row: confirmation.row)

        VStack(spacing: 5) {
          Text("Delete chat")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(palette.text)
            .lineLimit(1)

          Text("Are you sure you want to delete the chat with \(confirmation.row.title)?")
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(palette.secondaryText)
            .multilineTextAlignment(.center)
        }

        VStack(spacing: 10) {
          if let deleteForEveryone {
            Button(role: .destructive, action: deleteForEveryone) {
              Text("Delete for me and \(confirmation.row.title)")
                .font(.system(size: 16, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
            }
            .buttonStyle(ChatHomeDialogButtonStyle(
              foreground: palette.danger,
              background: palette.input,
              border: palette.border
            ))
          }

          Button(role: .destructive, action: deleteForMe) {
            Text(deleteForEveryone != nil ? "Delete just for me" : "Delete for me")
              .font(.system(size: 16, weight: .semibold))
              .frame(maxWidth: .infinity)
              .frame(height: 48)
          }
          .buttonStyle(ChatHomeDialogButtonStyle(
            foreground: palette.danger,
            background: palette.input,
            border: palette.border
          ))

          Button(action: cancel) {
            Text("Cancel")
              .font(.system(size: 16, weight: .semibold))
              .frame(maxWidth: .infinity)
              .frame(height: 46)
          }
          .buttonStyle(ChatHomeDialogButtonStyle(
            foreground: palette.text,
            background: palette.input,
            border: palette.border
          ))
        }
      }
      .padding(20)
      .frame(maxWidth: 340)
      .background(AppHomeGlassEffectView(cornerRadius: 24))
      .overlay(
        RoundedRectangle(cornerRadius: 24, style: .continuous)
          .stroke(palette.border, lineWidth: 1)
      )
      .shadow(color: Color.black.opacity(0.18), radius: 30, y: 16)
      .padding(.horizontal, 24)
    }
  }
}

private struct ChatHomeDialogButtonStyle: ButtonStyle {
  let foreground: Color
  let background: Color
  let border: Color

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(foreground)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(configuration.isPressed ? background.opacity(0.74) : background)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(border, lineWidth: 1)
      )
      .scaleEffect(configuration.isPressed ? 0.985 : 1)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

private struct ChatHomeDeleteAvatarView: View {
  let row: ChatHomeListRow

  var body: some View {
    ZStack {
      Circle()
        .fill(avatarGradient)

      if let url = avatarURL {
        AsyncImage(url: url) { phase in
          if let image = phase.image {
            image
              .resizable()
              .scaledToFill()
          } else {
            fallback
          }
        }
      } else {
        fallback
      }
    }
    .frame(width: 72, height: 72)
    .clipShape(Circle())
    .overlay(Circle().stroke(Color.white.opacity(0.24), lineWidth: 1))
  }

  private var avatarURL: URL? {
    guard let avatarUri = row.avatarUri else { return nil }
    return URL(string: avatarUri)
  }

  private var fallback: some View {
    Text(
      ChatAvatarNodeView.fallbackText(
        from: row.title,
        isGroupOrChannel: row.isGroup || row.isChannel
      )
    )
      .font(.system(size: 24, weight: .bold))
      .foregroundStyle(.white)
  }

  private var avatarGradient: LinearGradient {
    let colors = ChatProfileAppearanceStore.avatarColors(
      title: row.title,
      peerUserId: row.peerUserId,
      chatId: row.chatId
    )
    return LinearGradient(
      colors: [Color(uiColor: colors.0), Color(uiColor: colors.1)],
      startPoint: .top,
      endPoint: .bottom
    )
  }
}

private struct ChatHomeDeletionUndoToast: View {
  @Environment(\.colorScheme) private var colorScheme
  let deletion: ChatHomePendingDeletion
  let palette: AppThemePalette
  let undo: () -> Void

  var body: some View {
    TimelineView(.animation) { context in
      let remaining = max(0, deletion.expiresAt.timeIntervalSince(context.date))
      let progress = max(0, min(1, remaining / max(0.1, deletion.duration)))

      HStack(spacing: 12) {
        ZStack {
          Circle()
            .stroke(palette.border.opacity(0.65), lineWidth: 3)
          Circle()
            .trim(from: 0, to: progress)
            .stroke(
              palette.text.opacity(0.7),
              style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
          Text("\(Int(ceil(remaining)))")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(palette.text)
            .monospacedDigit()
        }
        .frame(width: 34, height: 34)

        Text("\(deletion.row.title) deleted")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(palette.text)
          .lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .center)

        Button(action: undo) {
          Text("Undo")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(palette.text)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(
              RoundedRectangle(cornerRadius: 99, style: .continuous)
                .fill(palette.text.opacity(0.12))
            )
        }
        .buttonStyle(.plain)
      }
      .padding(.leading, 12)
      .padding(.trailing, 10)
      .frame(maxWidth: .infinity)
      .frame(height: 58)
      .background(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .fill(palette.card)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .stroke(palette.border.opacity(0.55), lineWidth: 1)
      )
      .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.12), radius: 14, y: 8)
    }
  }
}

private struct AppHomeGlassEffectView: UIViewRepresentable {
  let cornerRadius: CGFloat

  func makeUIView(context: Context) -> UIVisualEffectView {
    let view = UIVisualEffectView(effect: nil)
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect()
      glass.isInteractive = true
      view.effect = glass
      view.contentView.backgroundColor = .clear
    } else {
      view.effect = UIBlurEffect(style: .systemThinMaterial)
    }
    view.layer.cornerRadius = cornerRadius
    view.layer.cornerCurve = .continuous
    view.clipsToBounds = true
    return view
  }
  func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

private struct SettingsRootView: View {
  @EnvironmentObject private var coordinator: AppShellCoordinator
  var body: some View {
    NavigationStack(path: $coordinator.settingsPath) {
      SettingsView()
    }
    .onAppear { appShellRouteLog("SettingsRootView onAppear") }
    .onDisappear { appShellRouteLog("SettingsRootView onDisappear") }
  }
}


enum ChatHomeRowAction: Equatable {
  case markUnread(Bool)
  case pin(Bool)
  case mute(Bool)
  case archive(Bool)
  case delete
}

private extension ChatHomeListRow {
  var hasUnreadState: Bool {
    unreadCount > 0 || markedUnread
  }

  var supportsRemoteHomeActions: Bool {
    !isSavedMessages && !isArchiveEntry && !isBuiltInAgentSurface
  }
}

private enum ChatHomeEditBulkAction {
  case markRead
  case mute
  case delete
}

private enum ChatHomeEditService {
  private enum EditError: LocalizedError {
    case invalidEndpoint
    case requestFailed(String)

    var errorDescription: String? {
      switch self {
      case .invalidEndpoint:
        return "Chat action endpoint is unavailable."
      case .requestFailed(let message):
        return message
      }
    }
  }

  static func apply(
    action: ChatHomeEditBulkAction,
    chatIDs: [String],
    config: AppSessionConfig
  ) async throws {
    for chatID in chatIDs {
      try await apply(action: action, chatID: chatID, config: config)
    }
  }

  static func apply(
    action: ChatHomeRowAction,
    chatID: String,
    config: AppSessionConfig
  ) async throws {
    let endpoint: String
    let method: String
    let body: [String: Any]?

    switch action {
    case .markUnread(let unread):
      endpoint = "/chat/\(chatID)/mark-unread"
      method = "POST"
      body = ["unread": unread]
    case .pin(let pinned):
      endpoint = "/chat/\(chatID)/pin"
      method = "POST"
      body = ["pinned": pinned]
    case .mute(let muted):
      endpoint = "/chat/\(chatID)/mute"
      method = "POST"
      body = ["muted": muted]
    case .archive(let archived):
      endpoint = "/chat/\(chatID)/archive"
      method = "POST"
      body = ["archived": archived]
    case .delete:
      endpoint = "/chats/\(chatID)"
      method = "DELETE"
      body = nil
    }

    try await performRequest(endpoint: endpoint, method: method, body: body, config: config)
  }

  static func deleteChat(
    chatID: String,
    config: AppSessionConfig,
    deleteForEveryone: Bool
  ) async throws {
    try await performRequest(
      endpoint: "/chats/\(chatID)",
      method: "DELETE",
      body: deleteForEveryone ? ["deleteForEveryone": true] : nil,
      config: config
    )
  }

  private static func apply(
    action: ChatHomeEditBulkAction,
    chatID: String,
    config: AppSessionConfig
  ) async throws {
    let endpoint: String
    let method: String
    let body: [String: Any]?

    switch action {
    case .markRead:
      endpoint = "/chat/\(chatID)/mark-unread"
      method = "POST"
      body = ["userId": config.userID, "unread": false]
    case .mute:
      endpoint = "/chat/\(chatID)/mute"
      method = "POST"
      body = ["userId": config.userID, "muted": true]
    case .delete:
      endpoint = "/chats/\(chatID)"
      method = "DELETE"
      body = nil
    }

    try await performRequest(endpoint: endpoint, method: method, body: body, config: config)
  }

  private static func performRequest(
    endpoint: String,
    method: String,
    body: [String: Any]?,
    config: AppSessionConfig
  ) async throws {
    guard let url = apiURL(base: config.apiBaseURLString, path: endpoint) else {
      throw EditError.invalidEndpoint
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 20
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }

    let (data, response) = try await VibeHTTP.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw EditError.requestFailed(responseMessage(from: data))
    }
  }

  private static func apiURL(base rawBase: String, path: String) -> URL? {
    var base = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }
    if base.hasSuffix("/api") {
      base = String(base.dropLast(4))
    }
    return URL(string: base + "/api" + path)
  }

  private static func responseMessage(from data: Data) -> String {
    if
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let message = (json["error"] ?? json["message"] ?? json["reason"]) as? String,
      !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return message
    }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? "Chat action failed."
  }
}

private struct ArchivedChatHomeListScreen: View {
  @ObservedObject var model: ChatsViewModel
  let palette: AppThemePalette
  let isDark: Bool
  let hiddenChatIDs: Set<String>
  let openRow: (ChatHomeListRow) -> Void
  let performAction: (ChatHomeRowAction, ChatHomeListRow) -> Void

  private var visibleRows: [ChatHomeListRow] {
    model.archivedRows.filter { !hiddenChatIDs.contains($0.chatId) }
  }

  var body: some View {
    Group {
      if visibleRows.isEmpty && model.isLoadingArchived {
        AppListLoadingView(palette: palette, caption: "Loading archive")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(palette.background)
      } else if visibleRows.isEmpty {
        VStack(spacing: 10) {
          Image(systemName: "archivebox")
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(palette.secondaryText.opacity(0.75))
          Text("No Archived Chats")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(palette.text)
          Text("Archived conversations will appear here.")
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(palette.secondaryText)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .background(palette.background)
      } else {
        ChatHomeNativeListRepresentable(
          rows: visibleRows,
          isDark: isDark,
          isEditing: false,
          showsRightCheckmark: false,
          selectedChatIDs: [],
          onSelect: openRow,
          onToggleSelection: { _ in },
          onAction: performAction,
          onRefresh: {
            await model.refreshArchived()
          },
          onUnavailableAction: { AppToastController.shared.show($0) }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
      }
    }
    .ignoresSafeArea(.container, edges: .top)
    .background(palette.background.ignoresSafeArea())
    .navigationBarTitleDisplayMode(.inline)
    .task {
      await model.loadArchivedIfNeeded()
    }
  }
}

/// Glass text pills: one left · one center · one right. Glass tint is constant;
/// only label opacity reflects enabled/disabled.
// MARK: - Home search (Telegram-style shared field + close slide-in)

/// Frame-hitch + phase logger for the search focus/blur morph. `begin` starts
/// a 1.2s CADisplayLink watch: any frame gap over ~2 refresh intervals is
/// logged with its offset-from-begin, so a laggy open can be pinned to a
/// phase (pose flip, keyboard, glass-on, native fade). Capture on-device with
/// Console.app filtered to "SearchMorph", or:
///   log stream --predicate 'eventMessage CONTAINS "[SearchMorph]"'
private final class SearchMorphProfiler: NSObject {
  static let shared = SearchMorphProfiler()

  private var link: CADisplayLink?
  private var label = ""
  private var startedAt: CFTimeInterval = 0
  private var lastFrame: CFTimeInterval = 0
  private var hitchCount = 0
  private var worstMs = 0.0

  // Presentation-layer surface probe: reads the ACTUAL on-screen translate of
  // the list and the input pair every frame. A server-side spring reads as a
  // clean monotone curve; a mid-flight commit shows up as a timestamp gap
  // (freeze) followed by a big delta (jump), and table≠pair proves a desync.
  private weak var surfaceTable: CALayer?
  private weak var surfacePair: CALayer?
  private weak var surfaceScroll: UIScrollView?
  private var lastSampleTy = CGFloat.nan
  private var lastSamplePty = CGFloat.nan
  private var lastSampleOff = CGFloat.nan
  private var sampleCount = 0

  private override init() {
    super.init()
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(keyboardWillShow),
      name: UIResponder.keyboardWillShowNotification, object: nil)
    center.addObserver(
      self, selector: #selector(keyboardDidShow),
      name: UIResponder.keyboardDidShowNotification, object: nil)
  }

  func begin(_ label: String) {
    // The tap's UIKit-turn begin and the SwiftUI commit's begin arrive ~20ms
    // apart for the SAME run — a restart would move t0 and skew every mark
    // and hitch timestamp after it.
    if link != nil, self.label == label, CACurrentMediaTime() - startedAt < 1.0 {
      return
    }
    finish(logSummary: false)
    self.label = label
    startedAt = CACurrentMediaTime()
    lastFrame = 0
    hitchCount = 0
    worstMs = 0
    NSLog("[SearchMorph] %@ begin", label)
    let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
    link.add(to: .main, forMode: .common)
    self.link = link
    let generation = startedAt
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
      // Generation guard: a later begin() must not have its watch cut short
      // by this earlier session's scheduled stop.
      guard let self, self.startedAt == generation else { return }
      self.finish(logSummary: true)
    }
  }

  static func mark(_ event: String) {
    let profiler = shared
    guard profiler.link != nil else { return }
    NSLog(
      "[SearchMorph] %@ +%.0fms %@",
      profiler.label, (CACurrentMediaTime() - profiler.startedAt) * 1000, event)
  }

  /// Point the probe at the two riding layers. Called once the shared animator
  /// has started; sampling then runs off the existing display link.
  static func attachSurfaces(table: UIView?, pair: UIView?) {
    let p = shared
    p.surfaceTable = table?.layer
    p.surfacePair = pair?.layer
    p.surfaceScroll = table as? UIScrollView
    p.lastSampleTy = .nan
    p.lastSamplePty = .nan
    p.lastSampleOff = .nan
    p.sampleCount = 0
  }

  @objc private func tick(_ link: CADisplayLink) {
    if lastFrame > 0 {
      let frameMs = (link.timestamp - lastFrame) * 1000
      let expectedMs = link.duration * 1000
      if frameMs > max(expectedMs * 2.2, 20) {
        hitchCount += 1
        worstMs = max(worstMs, frameMs)
        NSLog(
          "[SearchMorph] %@ HITCH +%.0fms frame=%.1fms (budget %.1fms)",
          label, (link.timestamp - startedAt) * 1000, frameMs, expectedMs)
      }
    }
    lastFrame = link.timestamp
    sampleSurfaces(at: link.timestamp)
  }

  private func sampleSurfaces(at timestamp: CFTimeInterval) {
    guard surfaceTable != nil || surfacePair != nil else { return }
    let elapsed = timestamp - startedAt
    guard elapsed < 0.85, sampleCount < 90 else { return }
    let ty = surfaceTable?.presentation()?.affineTransform().ty ?? .nan
    let pty = surfacePair?.presentation()?.affineTransform().ty ?? .nan
    let alpha = surfaceTable?.presentation()?.opacity ?? -1
    let off = surfaceScroll?.contentOffset.y ?? .nan
    // Seed on the first frame (deltas 0), then always carry the last value —
    // the prior version only wrote lastSample* AFTER the moved-guard, so the
    // seed never took and every delta stayed 0: the probe printed nothing.
    let firstSample = lastSampleTy.isNaN && lastSamplePty.isNaN
    let dTy = lastSampleTy.isNaN ? 0 : ty - lastSampleTy
    let dPty = lastSamplePty.isNaN ? 0 : pty - lastSamplePty
    let dOff = lastSampleOff.isNaN ? 0 : off - lastSampleOff
    lastSampleTy = ty
    lastSamplePty = pty
    lastSampleOff = off
    // Log only when something actually moved — a freeze becomes a visible gap
    // in timestamps, the resume frame carries the whole jump in its delta.
    // dOff separates a content-offset jump (list shifts INSIDE the table) from
    // a transform jump (the whole surface snaps).
    guard firstSample || abs(dTy) > 0.3 || abs(dPty) > 0.3 || abs(dOff) > 0.3 else {
      return
    }
    sampleCount += 1
    NSLog(
      "[SearchMorph] %@ surf +%.0fms tableTy=%.1f dT=%.1f pairTy=%.1f dP=%.1f off=%.1f dOff=%.1f a=%.2f desync=%.1f",
      label, elapsed * 1000, ty, dTy, pty, dPty, off, dOff, Double(alpha), ty - pty)
  }

  @objc private func keyboardWillShow() { Self.mark("keyboardWillShow") }
  @objc private func keyboardDidShow() { Self.mark("keyboardDidShow") }

  private func finish(logSummary: Bool) {
    guard link != nil else { return }
    link?.invalidate()
    link = nil
    surfaceTable = nil
    surfacePair = nil
    surfaceScroll = nil
    if logSummary {
      NSLog(
        "[SearchMorph] %@ end — hitches=%ld worst=%.1fms", label, hitchCount, worstMs)
    }
  }
}

/// Shared metrics for the search morph (the capsule itself is UIKit —
/// HomeSearchCapsuleView — and rides in a window overlay).
private enum HomeSearchChrome {
  // Same height as the docked input — a smaller circle floated above/below
  // the field's midline and read as misaligned chrome.
  static let closeSize: CGFloat = HomeSearchCapsuleView.fieldHeight
  /// The X attached INSIDE the field's right end (it rides with the input,
  /// so the field never narrows — no width morph, no internal re-layout).
  static let closeInnerSize: CGFloat = 34

  /// Dock Y for the focused field: centered in the nav band, just under the
  /// status bar. Derived from the key window (status inset only — the nav
  /// band never affects window insets), NOT from a GeometryReader inside an
  /// `ignoresSafeArea` view, whose reported insets under-measure and pushed
  /// the field into the status-bar region.
  static var dockTop: CGFloat {
    let statusTop =
      UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }?.safeAreaInsets.top ?? 59
    return statusTop + 2
  }
}

// MARK: - Focused search surface (overlay)

/// Full-screen focused-search RESULTS SHEET (the input is not here — the
/// native in-list capsule itself flies in a UIKit window overlay above this).
/// It NEVER animates: it sits BELOW the home list, "already there", and the
/// home cells fading out over it are the reveal. Permanently mounted;
/// `visible` is the instant on/off gate.
private struct HomeTelegramSearchView: View {
  @Binding var query: String
  /// Instant visibility (never animated) — flips in the same commit the
  /// capsule flight starts/ends and the list's background goes clear.
  let visible: Bool
  let recentRows: [ChatHomeListRow]
  let filteredChats: [ChatHomeListRow]
  let people: [ContactSearchUser]
  let isGlobalSearching: Bool
  let isDark: Bool
  let palette: AppThemePalette
  let onSelectChat: (ChatHomeListRow) -> Void
  let onSelectPerson: (ContactSearchUser) -> Void

  private var showRecentsStrip: Bool {
    query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    ZStack(alignment: .top) {
      // Full-bleed theme background — the SAME base surface as the home list, so
      // the focused search reads as the home screen with an input on top, not a
      // separate sheet. A transparent band here just exposed the raw (black)
      // window behind the faded nav bar as a ~10px strip under the input; a
      // seamless palette fill removes that with no visible plate (it equals the
      // home background in both light and dark).
      palette.background
        .ignoresSafeArea()
      resultsPane
        .padding(
          .top,
          HomeSearchChrome.dockTop + HomeSearchCapsuleView.fieldHeight + 10)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .ignoresSafeArea(.container, edges: .top)
    // Instant show/hide gate — flipped outside any animation. NO fades here:
    // the sheet is static behind the list; the list's fade is the reveal.
    // Hidden = 0.02, not 0: opacity 0 lets CA prune/derealize the subtree, and
    // re-realizing it on reveal cost a ~54ms frame that froze the flight's
    // first frames ("the input jumps to the header instead of moving"). At
    // 0.02 the layers stay resident behind the opaque list, so the reveal is
    // compositor-only.
    .opacity(visible ? 1 : 0.02)
    .allowsHitTesting(visible)
    .onChange(of: visible) { _, shown in
      SearchMorphProfiler.mark(shown ? "overlay visible" : "overlay hidden")
    }
  }

  private var resultsPane: some View {
    // Results scroll under the pinned bar (searchable-like).
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          Color.clear.frame(height: 0).id("searchResultsTop")
          if showRecentsStrip && !recentRows.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 14) {
                ForEach(recentRows, id: \.chatId) { row in
                  Button {
                    onSelectChat(row)
                  } label: {
                    VStack(spacing: 5) {
                      HomeSearchAvatarView(
                        row: row, isDark: isDark, palette: palette, size: 54)
                      Text(row.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                        .frame(width: 62)
                    }
                  }
                  .buttonStyle(.plain)
                }
              }
              .padding(.horizontal, 16)
              .padding(.bottom, 10)
            }

            HStack {
              Text("Recent")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.secondaryText)
                .textCase(.uppercase)
              Spacer()
              Button("Clear") {
                // Local recents are derived from the live list — clear just resets query focus.
                query = ""
              }
              .font(.system(size: 14, weight: .regular))
              .foregroundStyle(palette.secondaryText)
              .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 6)

            ForEach(Array(recentRows.prefix(24)), id: \.chatId) { row in
              Button { onSelectChat(row) } label: {
                HomeSearchCompactRow(row: row, palette: palette, isDark: isDark)
              }
              .buttonStyle(.plain)
            }
          } else if showRecentsStrip {
            // Empty query, no recents yet.
            ContactSearchStatusView(
              isLoading: false,
              hasSearched: true,
              message: "Search chats and people",
              palette: palette
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
          } else {
            if !filteredChats.isEmpty {
              sectionHeader("Chats")
              ForEach(filteredChats, id: \.chatId) { row in
                Button { onSelectChat(row) } label: {
                  HomeSearchCompactRow(row: row, palette: palette, isDark: isDark)
                }
                .buttonStyle(.plain)
              }
            }
            if !people.isEmpty {
              sectionHeader("People")
              ForEach(people) { user in
                Button { onSelectPerson(user) } label: {
                  HomeSearchCompactPersonRow(user: user, palette: palette, isDark: isDark)
                }
                .buttonStyle(.plain)
              }
            }
            if filteredChats.isEmpty && people.isEmpty {
              ContactSearchStatusView(
                isLoading: isGlobalSearching,
                hasSearched: !isGlobalSearching,
                message: isGlobalSearching
                  ? ""
                  : "No chats or people match \"\(query)\".",
                palette: palette
              )
              .frame(maxWidth: .infinity)
              .padding(.top, 40)
            }
          }
        }
        .padding(.bottom, 24)
      }
      .onChange(of: visible) { _, shown in
        // The pre-warmed pane keeps its scroll offset across sessions — snap
        // back to the top while hidden so every open starts fresh.
        if !shown { proxy.scrollTo("searchResultsTop", anchor: .top) }
      }
    }
  }

  private func sectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(palette.secondaryText)
      .padding(.horizontal, 16)
      .padding(.top, 10)
      .padding(.bottom, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Thin search result row — smaller avatar + tighter spacing (not home card cell).
private struct HomeSearchCompactRow: View {
  let row: ChatHomeListRow
  let palette: AppThemePalette
  let isDark: Bool

  var body: some View {
    HStack(spacing: 12) {
      HomeSearchAvatarView(row: row, isDark: isDark, palette: palette, size: 42)
      VStack(alignment: .leading, spacing: 2) {
        Text(row.title)
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(palette.text)
          .lineLimit(1)
        if !row.preview.isEmpty {
          Text(row.preview)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(palette.secondaryText)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 0)
      if row.unreadCount > 0 {
        Text("\(row.unreadCount)")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(palette.secondaryText)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
  }
}

private struct HomeSearchCompactPersonRow: View {
  let user: ContactSearchUser
  let palette: AppThemePalette
  let isDark: Bool

  var body: some View {
    HStack(spacing: 12) {
      HomeListStyleAvatar(
        title: user.username,
        peerUserId: user.userID,
        chatId: nil,
        avatarURI: user.profileImage,
        fallback: ChatHomeCardCell.getFallbackInitials(from: user.username),
        isDark: isDark,
        palette: palette,
        size: 42
      )
      VStack(alignment: .leading, spacing: 2) {
        Text(user.username)
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(palette.text)
          .lineLimit(1)
        if !user.userID.isEmpty {
          Text(user.userID)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(palette.secondaryText)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
    .contentShape(Rectangle())
  }
}

private struct HomeSearchAvatarView: View {
  let row: ChatHomeListRow
  let isDark: Bool
  let palette: AppThemePalette
  var size: CGFloat = 56

  var body: some View {
    HomeListStyleAvatar(
      title: row.title,
      peerUserId: row.peerUserId,
      chatId: row.chatId,
      avatarURI: row.avatarUri,
      fallback: ChatHomeCardCell.getFallbackInitials(from: row.title),
      isDark: isDark,
      palette: palette,
      isGroupOrChannel: row.isGroup || row.isChannel,
      size: size
    )
  }
}

// MARK: - In-list search header (scrolls with UITableView)

/// Full-capsule search entry pinned at the top of the home list — a floating
/// SIBLING above the table (NOT a tableHeaderView), so it collapses its own
/// height on scroll (native `.searchable`) instead of scrolling away with the
/// rows, and its window position is scroll-independent (the focus-morph takeoff
/// / landing anchor). Tapping opens the focused search surface.
/// Window-level flight layer: passes touches through everywhere except its
/// actual subviews (the flying capsule + close button).
private final class SearchFlightContainerView: UIView {
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let view = super.hitTest(point, with: event)
    return view === self ? nil : view
  }
}

/// The SOLID search capsule. Two roles: the in-list rest input (inside the
/// table header), and the pair's solid twin — a pixel-identical copy that
/// covers the real capsule at takeoff and rides the shared translate while
/// the glass ghost crossfades in over it. The crossfade IS the handoff, so
/// tiny inner-metric differences can never read as a jump.
/// Not private: reused as-is (same pill, same blur fill, same icon/placeholder)
/// wherever another list needs Home's exact search affordance — e.g. the
/// Agents tab — without re-implementing or subtly diverging from it.
final class HomeSearchCapsuleView: UIView {
  static let fieldHeight: CGFloat = 44

  let iconView = UIImageView()
  let textField = UITextField()
  let placeholderLabel = UILabel()
  private let fillView = UIView()
  /// Telegram's rest pose: the icon + "Search" group sits CENTERED in the
  /// capsule; the focused (glass) input is left-aligned, and the flight's
  /// crossfade carries the label from center to left.
  private var centeredConstraint: NSLayoutConstraint!
  private var leadingConstraint: NSLayoutConstraint!
  var onTextChanged: ((String) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.cornerRadius = Self.fieldHeight * 0.5
    layer.cornerCurve = .continuous
    layer.masksToBounds = true

    fillView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(fillView)

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.image = UIImage(systemName: "magnifyingglass")
    iconView.contentMode = .scaleAspectFit
    iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
      pointSize: 15, weight: .medium)
    addSubview(iconView)

    textField.translatesAutoresizingMaskIntoConstraints = false
    textField.font = .systemFont(ofSize: 17, weight: .regular)
    textField.autocorrectionType = .no
    textField.autocapitalizationType = .none
    textField.returnKeyType = .search
    textField.clearButtonMode = .whileEditing
    // Idle in the list: taps go to the header's hit button; the flight
    // controller enables interaction when docked.
    textField.isUserInteractionEnabled = false
    textField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
    addSubview(textField)

    placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
    placeholderLabel.text = "Search"
    placeholderLabel.font = .systemFont(ofSize: 17, weight: .regular)
    placeholderLabel.isUserInteractionEnabled = false
    addSubview(placeholderLabel)

    // Icon position is the single switch between the two poses: everything
    // else (text field, placeholder) chains off it.
    leadingConstraint = iconView.leadingAnchor.constraint(
      equalTo: leadingAnchor, constant: 12)
    // Center the icon+gap+"Search" GROUP: icon(18) + gap(8) + label(≈56) ≈ 82
    // wide → icon's center sits groupWidth/2 − icon/2 ≈ 32 left of center. A
    // fixed offset (not a layout guide) so the animated capsule width can't
    // fight the constraint solver mid-flight.
    centeredConstraint = iconView.centerXAnchor.constraint(
      equalTo: centerXAnchor, constant: -32)
    centeredConstraint.isActive = true

    NSLayoutConstraint.activate([
      fillView.leadingAnchor.constraint(equalTo: leadingAnchor),
      fillView.trailingAnchor.constraint(equalTo: trailingAnchor),
      fillView.topAnchor.constraint(equalTo: topAnchor),
      fillView.bottomAnchor.constraint(equalTo: bottomAnchor),

      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 18),
      iconView.heightAnchor.constraint(equalToConstant: 18),

      textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
      textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      textField.centerYAnchor.constraint(equalTo: centerYAnchor),

      placeholderLabel.leadingAnchor.constraint(equalTo: textField.leadingAnchor),
      placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Track the height so the scroll-collapse COMPRESSES the capsule into a
    // shorter rounded pill (rounded top AND bottom) rather than clipping a
    // fixed 22pt corner — the "clipped top" the native searchable never shows.
    layer.cornerRadius = min(Self.fieldHeight, bounds.height) / 2
  }

  /// Fade ONLY the icon + "Search" content (never the pill fill) — the
  /// scroll-collapse dissolves the label while the pill itself stays solid and
  /// just compresses. Kept off the wrapper so the capsule never goes translucent.
  func setContentAlpha(_ alpha: CGFloat) {
    iconView.alpha = alpha
    textField.alpha = alpha
    placeholderLabel.alpha = alpha
  }

  func applyPalette(isDark: Bool) {
    let palette = AppThemePalette.resolve(for: isDark ? .dark : .light)
    fillView.backgroundColor = palette.inputUIColor
    iconView.tintColor = palette.secondaryTextUIColor
    placeholderLabel.textColor = palette.secondaryTextUIColor
    textField.textColor = palette.textUIColor
  }

  func syncText(_ text: String) {
    if textField.text != text { textField.text = text }
    placeholderLabel.isHidden = !(textField.text ?? "").isEmpty
    applyLayoutPose()
  }

  /// Explicit pose, so the FLIGHT can slide the label center→left inside the
  /// animator (constraint change + layoutIfNeeded in the animation block).
  /// Kept separate from text emptiness: mid-flight external text syncs would
  /// otherwise snap the label back to center outside any animation.
  private var poseCentered = true

  func setLabelPose(centered: Bool) {
    poseCentered = centered
    applyLayoutPose()
  }

  /// Centered while empty at rest (Telegram); left-aligned once text exists
  /// or once the flight has pinned the focused pose.
  private func applyLayoutPose() {
    let centered = poseCentered && (textField.text ?? "").isEmpty
    guard centeredConstraint.isActive != centered else { return }
    if centered {
      leadingConstraint.isActive = false
      centeredConstraint.isActive = true
    } else {
      centeredConstraint.isActive = false
      leadingConstraint.isActive = true
    }
  }

  @objc private func textChanged() {
    placeholderLabel.isHidden = !(textField.text ?? "").isEmpty
    applyLayoutPose()
    onTextChanged?(textField.text ?? "")
  }
}

/// The GLASS focused-search input. It lives in the input PAIR stacked on the
/// solid twin and never animates its own position — the shared surface
/// translate carries the pair slot→dock while the two materials crossfade.
/// Built exactly like ChatPinnedBannerView (the reference for glass done
/// right): ONE `UIGlassEffect` owns the shell via a UIVisualEffectView, ALL
/// content lives inside its `contentView` (never as siblings above the glass,
/// never an opaque fill underneath). It is glass from birth — no solid→glass
/// morph on a single element.
private final class HomeSearchGhostInputView: UIView {
  let textField = UITextField()
  private let blurView = UIVisualEffectView(effect: nil)
  private let iconView = UIImageView()
  private let placeholderLabel = UILabel()
  var onTextChanged: ((String) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear

    blurView.frame = bounds
    blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    blurView.layer.cornerCurve = .continuous
    blurView.layer.cornerRadius = HomeSearchCapsuleView.fieldHeight / 2
    blurView.clipsToBounds = true
    blurView.contentView.backgroundColor = .clear
    addSubview(blurView)

    let content = blurView.contentView

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.image = UIImage(systemName: "magnifyingglass")
    iconView.contentMode = .scaleAspectFit
    iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
      pointSize: 15, weight: .medium)
    content.addSubview(iconView)
    // Same two poses as the solid capsule; the docked input always uses the
    // left-aligned one (the centered pose is the capsule's rest look).
    leadingConstraint = iconView.leadingAnchor.constraint(
      equalTo: content.leadingAnchor, constant: 12)
    centeredConstraint = iconView.centerXAnchor.constraint(
      equalTo: content.centerXAnchor, constant: -32)
    leadingConstraint.isActive = true

    textField.translatesAutoresizingMaskIntoConstraints = false
    textField.font = .systemFont(ofSize: 17, weight: .regular)
    textField.autocorrectionType = .no
    textField.autocapitalizationType = .none
    textField.returnKeyType = .search
    textField.clearButtonMode = .whileEditing
    textField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
    content.addSubview(textField)

    placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
    placeholderLabel.text = "Search"
    placeholderLabel.font = .systemFont(ofSize: 17, weight: .regular)
    placeholderLabel.isUserInteractionEnabled = false
    content.addSubview(placeholderLabel)

    NSLayoutConstraint.activate([
      iconView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 18),
      iconView.heightAnchor.constraint(equalToConstant: 18),

      textField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
      // The X lives OUTSIDE the field now (to its right, in the pair's reserved
      // strip), so the field owns its full narrowed width with normal padding —
      // no internal cutout, no overlaid button.
      textField.trailingAnchor.constraint(
        equalTo: content.trailingAnchor, constant: -14),
      textField.centerYAnchor.constraint(equalTo: content.centerYAnchor),

      placeholderLabel.leadingAnchor.constraint(equalTo: textField.leadingAnchor),
      placeholderLabel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
    ])
  }

  private var leadingConstraint: NSLayoutConstraint!
  private var centeredConstraint: NSLayoutConstraint!
  /// Docked rest pose is left-aligned; the flight slides it from/to the
  /// capsule's centered pose in lockstep with the solid twin.
  private var poseCentered = false

  func setLabelPose(centered: Bool) {
    poseCentered = centered
    applyLayoutPose()
  }

  private func applyLayoutPose() {
    let centered = poseCentered && (textField.text ?? "").isEmpty
    guard centeredConstraint.isActive != centered else { return }
    if centered {
      leadingConstraint.isActive = false
      centeredConstraint.isActive = true
    } else {
      centeredConstraint.isActive = false
      leadingConstraint.isActive = true
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func applyPalette(isDark: Bool) {
    lastIsDark = isDark
    // The field is ONE UIVisualEffectView that switches material between a
    // SOLID colour (rest / in-list look, matching the capsule) and clear GLASS
    // (focused). Apple's rule (WWDC25 "Build a UIKit app with the new design"):
    // to move between solid and glass you animate the `.effect` property
    // (UIColorEffect ↔ UIGlassEffect) — NEVER the alpha (an effect view's
    // material drops out mid-alpha and the field vanishes: the "disappears on
    // tap" bug) and never a tint ramp (that was the colour flicker). No fill
    // lives under or over the shell; the effect IS the fill.
    blurView.contentView.backgroundColor = .clear
    setMaterial(glass: false)
    // Must match HomeSearchCapsuleView's secondary EXACTLY (0.45, not 0.55): the
    // ghost crossfades into the solid capsule on dismiss, and any delta made the
    // "Search" label + magnifier visibly shift tone (brighter→dimmer) at handoff.
    let palette = AppThemePalette.resolve(for: isDark ? .dark : .light)
    iconView.tintColor = palette.secondaryTextUIColor
    placeholderLabel.textColor = palette.secondaryTextUIColor
    textField.textColor = palette.textUIColor
  }

  private var lastIsDark = false

  /// The solid capsule colour for the unfocused material — matched to
  /// HomeSearchCapsuleView.applyPalette so the takeoff/landing handoff to the
  /// real in-list capsule is seamless.
  private var solidFillColor: UIColor {
    AppThemePalette.resolve(for: lastIsDark ? .dark : .light).inputUIColor
  }

  /// Switch the field's material. Callers WRAP this in `UIView.animate { }` so
  /// the system plays its proper materialize/dematerialize (UISwitch-style)
  /// transition between the solid colour and glass — the ONLY flicker-free way.
  ///   · glass == false → UIColorEffect(solid)          (rest / in-list)
  ///   · glass == true  → UIGlassEffect (clear, no tint) (focused)
  func setMaterial(glass: Bool) {
    if glass {
      if #available(iOS 26.0, *) {
        // Clear glass — NO tintColor (the focused field is clear, not a pill).
        let g = UIGlassEffect(style: .regular)
        g.isInteractive = true
        blurView.effect = g
      } else {
        blurView.effect = UIBlurEffect(style: .systemThinMaterial)
      }
    } else {
      if #available(iOS 26.1, *) {
        blurView.effect = UIColorEffect(color: solidFillColor)
      } else {
        // Pre-26.1 has no UIColorEffect(color:) — approximate with a plain fill.
        blurView.effect = nil
        blurView.contentView.backgroundColor = solidFillColor
      }
    }
  }

  func syncText(_ text: String) {
    if textField.text != text { textField.text = text }
    placeholderLabel.isHidden = !(textField.text ?? "").isEmpty
    applyLayoutPose()
  }

  @objc private func textChanged() {
    placeholderLabel.isHidden = !(textField.text ?? "").isEmpty
    onTextChanged?(textField.text ?? "")
  }
}

private final class ChatHomeInListSearchHeader: UIView {
  var onFocusChange: ((Bool) -> Void)?

  let capsuleView = HomeSearchCapsuleView()
  private let hitButton = UIButton(type: .system)

  static let bandHeight: CGFloat = HomeSearchCapsuleView.fieldHeight + 12
  var preferredHeight: CGFloat { Self.bandHeight }

  /// The capsule's slot in bar coordinates — TOP-anchored, height tracks the
  /// band. This bar is a PINNED sibling (not a tableHeaderView); on scroll its
  /// `bounds.height` shrinks from the full band to 0. The capsule keeps a fixed
  /// 6pt top inset (so it never translates UP toward the nav) and COMPRESSES its
  /// own height — the capsule's cornerRadius tracks that height so it stays a
  /// rounded pill (native `.searchable`), never a fixed field clipped at the top
  /// edge. At full band the height is 44 with a 6pt gap to the first row,
  /// identical to the rest pose, so the focus-morph takeoff/landing is unchanged.
  var capsuleSlotFrame: CGRect {
    CGRect(
      x: 16,
      y: 6,
      width: bounds.width - 32,
      height: max(0, bounds.height - 12))
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    // Pinned collapsing bar: as the height shrinks on scroll the capsule slides
    // up past the top edge and must be clipped there (tucks under the nav).
    clipsToBounds = true

    addSubview(capsuleView)

    hitButton.translatesAutoresizingMaskIntoConstraints = false
    hitButton.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
    hitButton.accessibilityLabel = "Search"
    addSubview(hitButton)

    NSLayoutConstraint.activate([
      hitButton.leadingAnchor.constraint(equalTo: leadingAnchor),
      hitButton.trailingAnchor.constraint(equalTo: trailingAnchor),
      hitButton.topAnchor.constraint(equalTo: topAnchor),
      hitButton.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    capsuleView.frame = capsuleSlotFrame
  }

  func apply(
    text: String,
    isFocused: Bool,
    isDark: Bool,
    recentRows: [ChatHomeListRow],
    animated: Bool
  ) {
    _ = isFocused
    _ = recentRows
    _ = animated
    capsuleView.applyPalette(isDark: isDark)
    capsuleView.syncText(text)
  }

  /// Reuses Home's exact resting capsule as a normal in-place search field for
  /// list surfaces that do not mount Home's separate focused-results overlay.
  /// Home leaves this disabled and keeps its full flight choreography.
  func setInlineEditing(
    _ enabled: Bool,
    onTextChanged: ((String) -> Void)?
  ) {
    hitButton.isHidden = enabled
    capsuleView.textField.isUserInteractionEnabled = enabled
    capsuleView.onTextChanged = enabled ? onTextChanged : nil
  }

  @objc private func handleTap() {
    onFocusChange?(true)
  }
}

private final class ChatHomeRecentAvatarCell: UICollectionViewCell {
  static let reuseId = "ChatHomeRecentAvatarCell"
  private let avatar = UIImageView()
  private let fallback = UILabel()
  private let nameLabel = UILabel()
  private var gradientLayer: CAGradientLayer?

  override init(frame: CGRect) {
    super.init(frame: frame)
    avatar.translatesAutoresizingMaskIntoConstraints = false
    avatar.contentMode = .scaleAspectFill
    avatar.clipsToBounds = true
    avatar.layer.cornerRadius = 28
    contentView.addSubview(avatar)

    fallback.translatesAutoresizingMaskIntoConstraints = false
    fallback.font = .systemFont(ofSize: 18, weight: .semibold)
    fallback.textAlignment = .center
    fallback.textColor = .white
    contentView.addSubview(fallback)

    nameLabel.translatesAutoresizingMaskIntoConstraints = false
    nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
    nameLabel.textAlignment = .center
    nameLabel.lineBreakMode = .byTruncatingTail
    contentView.addSubview(nameLabel)

    NSLayoutConstraint.activate([
      avatar.topAnchor.constraint(equalTo: contentView.topAnchor),
      avatar.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      avatar.widthAnchor.constraint(equalToConstant: 56),
      avatar.heightAnchor.constraint(equalToConstant: 56),
      fallback.centerXAnchor.constraint(equalTo: avatar.centerXAnchor),
      fallback.centerYAnchor.constraint(equalTo: avatar.centerYAnchor),
      nameLabel.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 4),
      nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func configure(row: ChatHomeListRow, isDark: Bool) {
    nameLabel.text = row.title
    nameLabel.textColor = (isDark ? UIColor.white : UIColor.black).withAlphaComponent(0.75)
    fallback.text = ChatAvatarNodeView.fallbackText(
      from: row.title,
      isGroupOrChannel: row.isGroup || row.isChannel
    )
    let colors = ChatProfileAppearanceStore.avatarColors(
      title: row.title, peerUserId: row.peerUserId, chatId: row.chatId)
    gradientLayer?.removeFromSuperlayer()
    let g = CAGradientLayer()
    g.colors = [colors.0.cgColor, colors.1.cgColor]
    g.locations = [0.0, 1.0]
    g.startPoint = CGPoint(x: 0.5, y: 0.0)
    g.endPoint = CGPoint(x: 0.5, y: 1.0)
    g.frame = CGRect(x: 0, y: 0, width: 56, height: 56)
    g.cornerRadius = 28
    avatar.layer.insertSublayer(g, at: 0)
    gradientLayer = g
    avatar.image = nil
    fallback.isHidden = false
    gradientLayer?.isHidden = false
    if let uri = row.avatarUri, let cached = ChatAvatarImageStore.cached(for: uri) {
      avatar.image = cached
      fallback.isHidden = true
      gradientLayer?.isHidden = true
    } else if let uri = row.avatarUri, !uri.isEmpty {
      Task { [weak self] in
        let image = await ChatAvatarImageStore.load(from: uri)
        await MainActor.run {
          guard let self else { return }
          if let image {
            self.avatar.image = image
            self.fallback.isHidden = true
            self.gradientLayer?.isHidden = true
          }
        }
      }
    }
  }
}

private struct ChatHomeEditActionBar: View {
  let selectedCount: Int
  let isDark: Bool
  let onMarkRead: () -> Void
  let onMute: () -> Void
  let onDelete: () -> Void

  private var enabled: Bool { selectedCount > 0 }

  var body: some View {
    HStack(spacing: 0) {
      pill("Read All", action: onMarkRead)
        .frame(maxWidth: .infinity, alignment: .leading)
      pill("Mute", action: onMute)
        .frame(maxWidth: .infinity, alignment: .center)
      pill("Delete", action: onDelete)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .padding(.horizontal, 16)
    .padding(.top, 4)
    .padding(.bottom, 0)
  }

  private func pill(_ title: String, action: @escaping () -> Void) -> some View {
    Button {
      guard enabled else { return }
      action()
    } label: {
      Text(title)
        .font(.system(size: 15, weight: .semibold))
        // Only text reacts to off/on — glass stays fully visible.
        .foregroundStyle(
          (isDark ? Color.white : Color.primary).opacity(enabled ? 1.0 : 0.38)
        )
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background {
          // Constant glass (never dimmed by disabled state).
          if #available(iOS 26.0, *) {
            Capsule(style: .continuous)
              .fill(.clear)
              .glassEffect(.regular.interactive(true), in: .capsule)
          } else {
            Capsule(style: .continuous)
              .fill(.regularMaterial)
          }
        }
    }
    .buttonStyle(.plain)
    // Avoid .disabled — it greys the whole control including glass on some OS versions.
    .allowsHitTesting(enabled)
    .fixedSize(horizontal: true, vertical: false)
  }
}

/// Dark near-black sheet (not light-gray ultraThin on dark). Large preferred.
private struct ChatShareSheetPresentationModifier: ViewModifier {
  @Binding var detent: PresentationDetent
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content
      .presentationDetents([.large, .medium], selection: $detent)
      .presentationContentInteraction(.scrolls)
      .presentationDragIndicator(.visible)
      .presentationCornerRadius(28)
      // Theme-based solid — ultraThinMaterial reads as light gray on dark.
      .presentationBackground(
        colorScheme == .dark
          ? Color(red: 0.07, green: 0.07, blue: 0.08)
          : Color(uiColor: .systemBackground)
      )
  }
}

/// Pending forward draft applied when opening a group/channel from the share sheet.
enum ChatPendingForwardStore {
  struct Draft {
    let fromChatId: String
    let messageIds: [String]
    let messagePayloads: [[String: Any]]
    let previewText: String
  }

  private static var drafts: [String: Draft] = [:]

  static func set(_ draft: Draft, for chatId: String) {
    let key = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return }
    drafts[key] = draft
  }

  static func take(for chatId: String) -> Draft? {
    let key = chatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else { return nil }
    return drafts.removeValue(forKey: key)
  }
}

/// Forward target picker — nav-controlled header, home-style in-list search,
/// Select-only multi-pick, glass composer (no bar material).
private struct ShareChatSelectionView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @StateObject private var model = ChatsViewModel()
  @State private var selectedChatIDs = Set<String>()
  @State private var isMultiSelectMode = false
  @State private var isSending = false
  @State private var searchText = ""
  @State private var caption = ""
  @State private var sheetDetent: PresentationDetent = .large
  @FocusState private var captionFocused: Bool
  @FocusState private var searchFocused: Bool

  let previewText: String
  let messageCount: Int
  let onSelect: ([String: Any]) -> Void
  let onOpenTarget: ((ChatHomeListRow) -> Void)?

  init(
    previewText: String = "Message",
    messageCount: Int = 1,
    onSelect: @escaping ([String: Any]) -> Void,
    onOpenTarget: ((ChatHomeListRow) -> Void)? = nil
  ) {
    self.previewText = previewText
    self.messageCount = max(1, messageCount)
    self.onSelect = onSelect
    self.onOpenTarget = onOpenTarget
  }

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var filteredRows: [ChatHomeListRow] {
    let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = model.rows.filter { !$0.isArchiveEntry }
    guard !q.isEmpty else { return base }
    return base.filter {
      $0.title.localizedCaseInsensitiveContains(q)
        || $0.preview.localizedCaseInsensitiveContains(q)
    }
  }

  private var forwardBannerTitle: String {
    messageCount > 1 ? "Forward \(messageCount) Messages" : "Forward Message"
  }

  private var canSend: Bool {
    !selectedChatIDs.isEmpty && !isSending
  }

  var body: some View {
    NavigationStack {
      ZStack(alignment: .bottom) {
        listBody
          // Room for floating composer (no safeAreaInset bar that invents edges).
          .safeAreaPadding(.bottom, isMultiSelectMode || !selectedChatIDs.isEmpty ? 118 : 92)

        forwardComposerBar
      }
      .background(Color.clear)
      .navigationTitle("Forward")
      .navigationBarTitleDisplayMode(.inline)
      // Let NavigationStack own chrome — transparent bar, no drawer searchable.
      .toolbarBackground(.hidden, for: .navigationBar)
      .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
      .toolbar {
        // cancellationAction → single system glass chip (no nested clip).
        ToolbarItem(placement: .cancellationAction) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
          }
          .disabled(isSending)
          .accessibilityLabel("Close")
        }
        ToolbarItem(placement: .confirmationAction) {
          // Native toolbar text swap (Select ↔ Done) — no custom spring.
          Button(isMultiSelectMode ? "Done" : "Select") {
            toggleMultiSelect()
          }
          .fontWeight(.semibold)
          .disabled(isSending)
        }
      }
      .task {
        await model.loadIfNeeded()
      }
    }
    .modifier(ChatShareSheetPresentationModifier(detent: $sheetDetent))
  }

  @ViewBuilder
  private var listBody: some View {
    if model.rows.isEmpty && (!model.hasLoaded || model.isLoading) {
      AppListLoadingView(palette: palette, caption: "Loading chats")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(spacing: 0) {
        // Search lives in the CONTENT (scroll area), not nav drawer —
        // same grammar as Add Members / avoids large header edge.
        forwardSearchField
          .padding(.horizontal, 16)
          .padding(.top, 4)
          .padding(.bottom, 6)

        if filteredRows.isEmpty {
          AppShellEmptyStateView(
            icon: "bubble.left.and.bubble.right",
            title: searchText.isEmpty ? "No Chats" : "No Results",
            message: searchText.isEmpty
              ? "You have no active chats to forward to."
              : "No chats match “\(searchText)”.",
            buttonTitle: nil,
            palette: palette,
            action: nil
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ChatHomeNativeListRepresentable(
            rows: filteredRows,
            isDark: colorScheme == .dark,
            isEditing: false,
            // Circles ONLY in Select mode — default tap auto-sends.
            showsRightCheckmark: isMultiSelectMode,
            selectedChatIDs: selectedChatIDs,
            compactForwardStyle: true,
            onSelect: { row in
              handleRowTap(row)
            },
            onToggleSelection: { _ in },
            onAction: { _, _ in },
            onRefresh: {
              await model.refresh()
            },
            onUnavailableAction: { _ in }
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
  }

  private var forwardSearchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(palette.secondaryText)
      TextField("Search", text: $searchText)
        .focused($searchFocused)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .font(.system(size: 16))
        .foregroundStyle(palette.text)
      if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 15))
            .foregroundStyle(palette.secondaryText.opacity(0.7))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background {
      if #available(iOS 26.0, *) {
        Capsule(style: .continuous)
          .fill(.clear)
          .glassEffect(.regular.interactive(true), in: .capsule)
      } else {
        Capsule(style: .continuous)
          .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06))
      }
    }
  }

  /// No bar material / blur plate — only the message capsule is glass
  /// (matches chat input pill; list scrolls under via clear chrome).
  private var forwardComposerBar: some View {
    VStack(spacing: 6) {
      // Preview strip — transparent, no fill.
      HStack(alignment: .center, spacing: 10) {
        Image(systemName: "arrowshape.turn.up.forward.fill")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(Color.purple)
        Rectangle()
          .fill(Color.purple.opacity(0.85))
          .frame(width: 2, height: 26)
          .clipShape(Capsule())
        VStack(alignment: .leading, spacing: 1) {
          Text(forwardBannerTitle)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.purple)
          Text(previewText)
            .font(.system(size: 12, weight: .regular))
            .foregroundStyle(palette.secondaryText)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)

      HStack(spacing: 8) {
        TextField("Message", text: $caption)
          .focused($captionFocused)
          .font(.system(size: 16))
          .submitLabel(.send)
          .onSubmit {
            if canSend { sendSelected() }
          }
          .padding(.horizontal, 14)
          .padding(.vertical, 10)
          .background {
            if #available(iOS 26.0, *) {
              Capsule(style: .continuous)
                .fill(.clear)
                .glassEffect(.regular.interactive(true), in: .capsule)
            } else {
              Capsule(style: .continuous)
                .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06))
            }
          }

        Button {
          sendSelected()
        } label: {
          Image(systemName: "paperplane.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Circle().fill(canSend ? Color.purple : Color.purple.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        // In default mode send is for multi only; single-tap already auto-sends.
        .opacity(isMultiSelectMode || !selectedChatIDs.isEmpty ? 1 : 0.55)
      }
      .padding(.horizontal, 12)
      .padding(.bottom, 8)
    }
    .padding(.top, 6)
    .background(Color.clear)
  }

  private func toggleMultiSelect() {
    // No custom spring — NavigationStack/toolbar crossfade Select↔Done natively.
    if isMultiSelectMode {
      isMultiSelectMode = false
      selectedChatIDs.removeAll()
    } else {
      isMultiSelectMode = true
    }
  }

  private func handleRowTap(_ row: ChatHomeListRow) {
    guard !isSending else { return }

    if isMultiSelectMode {
      if selectedChatIDs.contains(row.chatId) {
        selectedChatIDs.remove(row.chatId)
      } else {
        selectedChatIDs.insert(row.chatId)
      }
      return
    }

    // Default: no circles — tap DM auto-forwards; group/channel opens with draft.
    if row.isGroup || row.isChannel {
      if let onOpenTarget {
        onOpenTarget(row)
        dismiss()
      } else {
        selectedChatIDs = [row.chatId]
        sendSelected()
      }
      return
    }

    selectedChatIDs = [row.chatId]
    sendSelected()
  }

  private func sendSelected() {
    guard canSend else { return }
    isSending = true
    var payload: [String: Any] = ["chatIds": Array(selectedChatIDs)]
    let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      payload["caption"] = trimmed
    }
    onSelect(payload)
    dismiss()
  }
}

struct ChatHomeNativeListRepresentable: UIViewControllerRepresentable {
  let rows: [ChatHomeListRow]
  let isDark: Bool
  let isEditing: Bool
  let showsRightCheckmark: Bool
  let selectedChatIDs: Set<String>
  /// Denser forward-sheet rows: smaller avatars, name-only, radio morph.
  var compactForwardStyle: Bool = false
  var searchText: Binding<String>? = nil
  var isSearchFocused: Binding<Bool>? = nil
  /// Uses Home's solid in-list capsule as an editable field without invoking
  /// the full Home search flight/results overlay.
  var inlineSearchInteraction: Bool = false
  /// Instant (unanimated) overlay visibility — sheet gate bookkeeping.
  var isSearchOverlayVisible: Bool = false
  /// Close phase 1 — triggers the native retract (xmark out, capsule re-widen).
  var isSearchRetracting: Bool = false
  /// Opaque list-surface color for the search morph: the table dissolves as
  /// ONE opaque surface over the sheet (transparent cells over sheet content
  /// read as two overlapping lists).
  var searchDissolveBackground: UIColor? = nil
  var recentRows: [ChatHomeListRow] = []
  var peopleResults: [ContactSearchUser] = []
  var isGlobalSearching: Bool = false
  let onSelect: (ChatHomeListRow) -> Void
  let onToggleSelection: (String) -> Void
  let onAction: (ChatHomeRowAction, ChatHomeListRow) -> Void
  var onSettingsAction: ((ChatHomeListRow) -> Void)? = nil
  var onSelectPerson: ((ContactSearchUser) -> Void)? = nil
  let onRefresh: () async -> Void
  let onUnavailableAction: (String) -> Void

  func makeUIViewController(context: Context) -> ChatHomeNativeListController {
    let controller = ChatHomeNativeListController()
    controller.onSelect = onSelect
    controller.onToggleSelection = onToggleSelection
    controller.onAction = onAction
    controller.onSettingsAction = onSettingsAction
    controller.onRefresh = onRefresh
    controller.onUnavailableAction = onUnavailableAction
    controller.onSelectPerson = onSelectPerson
    controller.searchTextBinding = searchText
    controller.isSearchFocusedBinding = isSearchFocused
    controller.inlineSearchInteraction = inlineSearchInteraction
    controller.searchOverlayVisibleFlag = isSearchOverlayVisible
    controller.searchRetractingFlag = isSearchRetracting
    controller.searchDissolveBackground = searchDissolveBackground
    controller.showsInListSearch = searchText != nil
    controller.apply(
      rows: rows,
      isDark: isDark,
      isEditing: isEditing,
      showsRightCheckmark: showsRightCheckmark,
      selectedChatIDs: selectedChatIDs,
      compactForwardStyle: compactForwardStyle,
      recentRows: recentRows,
      peopleResults: peopleResults,
      isGlobalSearching: isGlobalSearching
    )
    return controller
  }

  func updateUIViewController(_ uiViewController: ChatHomeNativeListController, context: Context) {
    uiViewController.onSelect = onSelect
    uiViewController.onToggleSelection = onToggleSelection
    uiViewController.onAction = onAction
    uiViewController.onSettingsAction = onSettingsAction
    uiViewController.onRefresh = onRefresh
    uiViewController.onUnavailableAction = onUnavailableAction
    uiViewController.onSelectPerson = onSelectPerson
    uiViewController.searchTextBinding = searchText
    uiViewController.isSearchFocusedBinding = isSearchFocused
    uiViewController.inlineSearchInteraction = inlineSearchInteraction
    uiViewController.searchOverlayVisibleFlag = isSearchOverlayVisible
    uiViewController.searchRetractingFlag = isSearchRetracting
    uiViewController.searchDissolveBackground = searchDissolveBackground
    uiViewController.showsInListSearch = searchText != nil
    uiViewController.apply(
      rows: rows,
      isDark: isDark,
      isEditing: isEditing,
      showsRightCheckmark: showsRightCheckmark,
      selectedChatIDs: selectedChatIDs,
      compactForwardStyle: compactForwardStyle,
      recentRows: recentRows,
      peopleResults: peopleResults,
      isGlobalSearching: isGlobalSearching
    )
  }
}

final class ChatHomeNativeListController: UIViewController, UITableViewDataSource,
  UITableViewDelegate, UIGestureRecognizerDelegate, ChatHomeCardCellSwipeDelegate
{
  private let tableView = UITableView(frame: .zero, style: .plain)
  private lazy var previewHoldRecognizer: UILongPressGestureRecognizer = {
    let recognizer = UILongPressGestureRecognizer(
      target: self,
      action: #selector(handlePreviewHold(_:))
    )
    // A REAL hold, not touch-down: 0.12s of stillness before the gesture even
    // begins. Quick taps and starting swipes never enter the hold path at all
    // — no depress flash on tap, no sink under a swipe, no delayed-feeling
    // push (touch-down tracking made every tap start the hold choreography).
    recognizer.minimumPressDuration = 0.12
    recognizer.allowableMovement = 10
    recognizer.delaysTouchesBegan = false
    recognizer.delaysTouchesEnded = false
    recognizer.cancelsTouchesInView = false
    recognizer.delegate = self
    return recognizer
  }()

  fileprivate var onSelect: (ChatHomeListRow) -> Void = { _ in }
  fileprivate var onToggleSelection: (String) -> Void = { _ in }
  fileprivate var onAction: (ChatHomeRowAction, ChatHomeListRow) -> Void = { _, _ in }
  /// Fires for the Agents-tab-only "Settings" leading swipe action
  /// (`isOwnedAgent` rows). Kept separate from `onAction`/`ChatHomeRowAction`
  /// so ordinary Home chat rows and their exhaustive action switch are
  /// completely untouched by this addition.
  fileprivate var onSettingsAction: ((ChatHomeListRow) -> Void)?
  fileprivate var onRefresh: (() async -> Void)?
  fileprivate var onUnavailableAction: (String) -> Void = { _ in }
  fileprivate var onSelectPerson: ((ContactSearchUser) -> Void)?
  fileprivate var searchTextBinding: Binding<String>?
  fileprivate var isSearchFocusedBinding: Binding<Bool>?
  fileprivate var inlineSearchInteraction = false
  fileprivate var searchOverlayVisibleFlag = false
  fileprivate var searchRetractingFlag = false
  fileprivate var searchDissolveBackground: UIColor?
  /// Telegram's open grammar (verified against slow-mo captures): the OLD
  /// surface slides up by the full slot→dock distance while fading, so the
  /// input is visibly CARRIED to the header by the surface it lives on. A
  /// token −10pt lift read as a static list with a teleporting input.
  private var searchSurfaceLift: CGFloat = 72
  fileprivate var showsInListSearch = false

  private var rows: [ChatHomeListRow] = []
  private var recentRows: [ChatHomeListRow] = []
  private var peopleResults: [ContactSearchUser] = []
  private var isGlobalSearching = false
  private var isDark = false
  private var isEditingMode = false
  private var showsRightCheckmark = false
  private var compactForwardStyle = false
  private var searchHeader: ChatHomeInListSearchHeader?
  private var lastSearchHeaderSignature = ""
  private var presentedSearchFocus = false
  private var presentedSearchOverlay = false
  private var presentedSearchRetract = false
  /// Window-level layer above the SwiftUI results sheet. Holds the input
  /// PAIR — the input's two material variants (solid capsule + glass field)
  /// stacked at one frame — which rides the SAME transform as the table.
  private var searchFlightContainer: UIView?
  /// The riding frame: twin + ghost + attached X, translated by the exact
  /// transform written to the table in the same animator block.
  private var searchPairView: UIView?
  private var searchGhost: HomeSearchGhostInputView?
  /// Solid variant of the input inside the pair; crossfades with the ghost
  /// while both ride. Pixel-identical to the in-list capsule it covers.
  private var searchSolidTwin: HomeSearchCapsuleView?
  private var searchCloseButton: UIButton?
  /// The live shared-translate spring. Held so leaving Home mid-flight can
  /// stopAnimation(true) it — otherwise its completion (settle / tint drain)
  /// fires after the forced teardown and resurrects the morph on the next view.
  private var searchSurfaceAnimator: UIViewPropertyAnimator?
  /// The list's contentOffset the instant search focus began. The focused table
  /// is alpha 0 for the whole morph, but something in the focus/results cycle
  /// drifts its offset by ~one band (55pt) by the time we return — which lands
  /// `past = offset + insetTop` at ≈band, so the pinned bar rebuilds COLLAPSED
  /// on dismiss (the "input is gone after closing; scrolling brings it back").
  /// Captured at open, restored at settle so the list — and thus the bar's
  /// collapse — comes back exactly where it left.
  private var searchOpenContentOffset: CGPoint?

  override var preferredStatusBarStyle: UIStatusBarStyle {
    return isDark ? .lightContent : .darkContent
  }
  private var selectedChatIDs = Set<String>()
  private var lastAppliedSignature = ""
  private weak var openSwipeCell: ChatHomeCardCell?
  private weak var previewHoldCell: ChatHomeCardCell?
  private var previewHoldIndexPath: IndexPath?
  private var activePreviewChatID: String?
  private var previewHoldOrigin = CGPoint.zero
  private var previewHoldOriginalTransform: CGAffineTransform = .identity
  private var previewHoldCommitted = false
  private var previewDepressAnimator: UIViewPropertyAnimator?
  private var previewHoldEngagement: DispatchWorkItem?
  private var pendingPreviewController: ChatHomeMiniPreviewController?
  private var suppressSelectionUntil: CFTimeInterval = 0
  private var bridgeStatusObserver: NSObjectProtocol?
  private var bridgeStatusPollTask: Task<Void, Never>?
  /// Last status signature painted by the poll, so an unchanged tick repaints nothing.
  private var lastBridgeStatusPollSignature: String?
  /// A newly-created Home table must begin at its true rest position
  /// (`-adjustedContentInset.top`). UIKit initializes `contentOffset.y` to zero;
  /// after we add the nav + pinned-search inset, zero already represents a list
  /// scrolled partway down. Apply this exactly once per controller lifetime so
  /// later chat returns and realtime updates preserve the user's scroll position.
  private var hasAppliedInitialTopOffset = false
  private var hasUserDrivenHomeScroll = false

  override func viewSafeAreaInsetsDidChange() {
    super.viewSafeAreaInsetsDidChange()
    updateTopContentInset()
    applyInitialTopOffsetIfNeeded()
    // The pinned bar's top tracks the safe area (nav height). Skipped mid-morph
    // (the nav fade shrinks the safe area then — the bar must stay frozen).
    layoutSearchBar()
  }

  // The SwiftUI host lets the table background extend under the transparent
  // navigation area. The row content still needs UIKit's safe-area clearance so
  // cells do not clip under the nav/search chrome.
  /// True while the search-focus morph owns the list's vertical position —
  /// from the moment focus is committed (open) through the descent, until both
  /// the focus and the retract flags clear at rest. Derived from state (never a
  /// sticky flag) so any interrupted transition — rapid open→close→open, a
  /// dropped settle — self-heals the instant we're genuinely back at rest.
  private var isSearchMorphActive: Bool {
    presentedSearchFocus || presentedSearchRetract
  }

  private func updateTopContentInset(force: Bool = false) {
    // Search-morph freeze. The list rides ONE shared transform to the dock; but
    // focusing fades the nav bar, which shrinks view.safeAreaInsets.top (~116→
    // ~62) and fires viewSafeAreaInsetsDidChange here. Tracking it would set
    // contentInset.top — and, pinned at the top, snap contentOffset by the same
    // ~54px in ONE frame. That is a SECOND, instant lift stacked on the animated
    // transform: the probe's "list shifts 54px on tap" (open, inset drop) and
    // "input shifts at the end of close" (nav-restore inset grow, the +273ms
    // dOff=-54 jump). Hold the inset for the whole flight — the focused table is
    // alpha=0 so the held value is never seen, and the morph starts AND ends at
    // rest, so the held value already equals the true rest inset (no reconcile).
    guard !isSearchMorphActive else { return }
    // Transient safe-area collapse guard. At search teardown the nav bar restores
    // and view.safeAreaInsets.top momentarily reads 0 before settling back to
    // ~116, firing viewSafeAreaInsetsDidChange here mid-glitch. Writing the inset
    // then (top 172→56) shoves contentOffset by the nav height, and the clamp on
    // the way back leaves a ~55pt residue — `past` lands at ≈band and the pinned
    // bar rebuilds COLLAPSED ("search disappears on close; scroll brings it back";
    // logged `uTCI navSafe=0.0 top 172→56 off -172→-56`). Home always shows the
    // inline nav, so navSafe==0 is never a real rest state — ignore it; the real
    // value re-fires this method a frame later.
    if view.safeAreaInsets.top <= 1, !force {
      NSLog("[SearchJump] uTCI SKIP transient navSafe=0 (inset held)")
      return
    }
    // Reserve the pinned search band in the top inset so rows rest BELOW it (the
    // bar is a sibling now, no longer a tableHeaderView adding to contentSize).
    // The inset is CONSTANT (navSafe + full band) at every scroll position — the
    // collapse is purely cosmetic bar-height shrink (layoutSearchBar), never an
    // inset write, so contentOffset is never re-derived mid-scroll (the jump).
    let searchBand =
      (showsInListSearch && searchHeader != nil) ? ChatHomeInListSearchHeader.bandHeight : 0
    let topInset = view.safeAreaInsets.top + searchBand
    // Lift the last rows clear of the always-present tab-bar band. The tab bar
    // is fade-only (never removed), and with .never inset adjustment a 0 bottom
    // inset leaves the newest chats UNDER it, un-scrollable into view. Reserve
    // ONLY the strip where the tab bar actually overlaps the table, computed in
    // window space — a flat tabBar.frame.height over-reserves (the list may
    // already stop above the bar), leaving a big empty gap that reads as the
    // list "force-scrolling to a weird bottom".
    var bottomInset: CGFloat = 0
    if let tabBar = tabBarController?.tabBar, let window = view.window,
      tabBar.window === window
    {
      let tableMaxY = tableView.convert(tableView.bounds, to: window).maxY
      let tabMinY = tabBar.convert(tabBar.bounds, to: window).minY
      bottomInset = max(0, tableMaxY - tabMinY)
    }
    let next = UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
    guard force || tableView.contentInset != next else { return }
    let jumpOldTop = tableView.contentInset.top
    let jumpOffBefore = tableView.contentOffset.y
    tableView.contentInset = next
    tableView.scrollIndicatorInsets = next
    if abs(tableView.contentOffset.y - jumpOffBefore) > 1 || abs(next.top - jumpOldTop) > 1 {
      NSLog(
        "[SearchJump] uTCI navSafe=%.1f top %.1f→%.1f bot→%.1f off %.1f→%.1f force=%d",
        view.safeAreaInsets.top, jumpOldTop, next.top, next.bottom,
        jumpOffBefore, tableView.contentOffset.y, force ? 1 : 0)
    }
  }

  private func applyInitialTopOffsetIfNeeded() {
    guard !hasAppliedInitialTopOffset, isViewLoaded, !isSearchMorphActive else { return }
    guard tableView.bounds.width > 0, tableView.bounds.height > 0 else { return }
    // Home's pinned search band and navigation safe area must both exist before
    // committing the one-shot offset. Marking it while safeAreaInsets is transiently
    // zero would recreate the exact midpoint bug on the next layout pass.
    if showsInListSearch {
      guard searchHeader != nil, view.safeAreaInsets.top > 1 else { return }
    }

    // contentInsetAdjustmentBehavior is `.never`, so the value just committed by
    // updateTopContentInset is the source of truth even before UIKit refreshes its
    // derived `adjustedContentInset` on the following layout pass.
    let topY = -tableView.contentInset.top
    UIView.performWithoutAnimation {
      tableView.setContentOffset(
        CGPoint(x: tableView.contentOffset.x, y: topY),
        animated: false
      )
    }
    hasAppliedInitialTopOffset = true
    layoutSearchBar(force: true)
    AppUITrace.notice(
      "ChatHomeNativeListController initial-top offsetY=\(Int(topY)) insetTop=\(Int(tableView.adjustedContentInset.top)) rows=\(rows.count)"
    )
  }

  private func updateInListSearchHeader(animated: Bool) {
    // Permanent opaque backing (identical to the SwiftUI background behind
    // it) — refreshed every apply so palette flips track it.
    tableView.backgroundColor = searchDissolveBackground ?? .clear
    // The search bar is a PINNED sibling ABOVE the table — NOT a tableHeaderView.
    // A tableHeaderView scrolls with the rows, which (a) made the bar translate
    // AWAY with the list instead of collapsing in place, and (b) drifted the
    // focus-morph takeoff/landing by the scroll offset — the input "lost its
    // position, the list shifted" on dismiss. Pinned, its top stays fixed under
    // the nav; scroll only shrinks its HEIGHT (layoutSearchBar), and its band is
    // reserved in the table's top contentInset so rows never inherit its motion.
    let showHeader = showsInListSearch
    guard showHeader else {
      searchHeader?.removeFromSuperview()
      searchHeader = nil
      if tableView.tableHeaderView != nil { tableView.tableHeaderView = nil }
      return
    }
    // Never leave a legacy tableHeaderView mounted.
    if tableView.tableHeaderView != nil { tableView.tableHeaderView = nil }
    let header: ChatHomeInListSearchHeader
    if let existing = searchHeader {
      header = existing
    } else {
      header = ChatHomeInListSearchHeader(
        frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: ChatHomeInListSearchHeader.bandHeight))
      header.onFocusChange = { [weak self] focused in
        guard let self else { return }
        guard !self.inlineSearchInteraction else { return }
        if focused {
          // UIKit-first: motion starts in this event turn, SwiftUI follows.
          self.beginSearchOpenFromTap()
        } else {
          self.isSearchFocusedBinding?.wrappedValue = focused
        }
      }
      searchHeader = header
      // The controller can receive its first safe-area pass before SwiftUI's configured
      // search header exists. If no finger has owned the list yet, re-arm the one-shot
      // top landing now that the complete nav + search inset can be computed.
      if !hasUserDrivenHomeScroll {
        hasAppliedInitialTopOffset = false
      }
    }
    // Sibling ABOVE the table so the collapsing bar clips over the rows (their
    // tops kiss the bar's bottom edge but never overlap).
    if header.superview !== view {
      header.removeFromSuperview()
      view.addSubview(header)
    }
    view.bringSubviewToFront(header)
    header.apply(
      text: searchTextBinding?.wrappedValue ?? "",
      isFocused: false,
      isDark: isDark,
      recentRows: recentRows,
      animated: animated
    )
    header.setInlineEditing(inlineSearchInteraction) { [weak self] text in
      guard let self, self.searchTextBinding?.wrappedValue != text else { return }
      self.searchTextBinding?.wrappedValue = text
    }
    // External query changes (sheet "Clear", close-time reset) reach the
    // ghost AND its solid twin; while the user types this is an equal-text
    // no-op.
    searchGhost?.syncText(searchTextBinding?.wrappedValue ?? "")
    searchSolidTwin?.syncText(searchTextBinding?.wrappedValue ?? "")
    // SwiftUI can configure/create this header after the controller's only initial
    // layout pass. Commit the complete inset and top landing here as well; otherwise
    // UIKit keeps its default offset 0 while insetTop is 172, so Home opens one band
    // down the list until the user scrolls (the captured "mid page" launch).
    if !hasUserDrivenHomeScroll {
      updateTopContentInset()
      applyInitialTopOffsetIfNeeded()
      // SwiftUI may create/configure the pinned header during the same layout turn in
      // which the table still reports 0x0 bounds. The synchronous attempt correctly
      // refuses to consume the one-shot in that state; retry once after Auto Layout has
      // committed real bounds so offset 0 cannot survive under a 172pt top inset.
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.hasUserDrivenHomeScroll else { return }
        self.updateTopContentInset()
        self.applyInitialTopOffsetIfNeeded()
      }
    }
    // Position + collapse the pinned bar for the current scroll offset.
    layoutSearchBar()
  }

  /// Position the PINNED search bar and drive its collapse. The bar's top is
  /// fixed just under the nav (`view.safeAreaInsets.top`, stable during scroll —
  /// the title is `.inline`, no large-title collapse); its HEIGHT shrinks from
  /// the full band to 0 as the list scrolls up through the band, so the
  /// top-anchored capsule COMPRESSES in place (its cornerRadius tracks the
  /// shrinking height so it stays a rounded pill) and its label cross-fades out
  /// (native `.searchable`) instead of translating up or hard-clipping at one
  /// edge. Purely cosmetic: contentInset is NEVER touched here
  /// (that re-derives contentOffset mid-scroll and jumps) — the inset already
  /// reserves the full band, rows scroll normally, and the bar's bottom edge
  /// tracks the first row's top exactly. Frozen during the morph (the bar's
  /// capsule is alpha 0 then and the flight overlay owns the visuals); `force`
  /// bypasses that gate for the settle/teardown re-layout.
  private func layoutSearchBar(force: Bool = false) {
    guard let header = searchHeader, header.superview === view,
      force || !isSearchMorphActive
    else { return }
    let band = ChatHomeInListSearchHeader.bandHeight
    let navSafe = view.safeAreaInsets.top
    let past = max(0, tableView.contentOffset.y + tableView.adjustedContentInset.top)
    let barHeight = max(0, band - min(past, band))
    let next = CGRect(x: 0, y: navSafe, width: view.bounds.width, height: barHeight)
    if header.frame != next {
      // No implicit animation on this scroll-driven frame write.
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      header.frame = next
      header.layoutIfNeeded()
      CATransaction.commit()
    }
    // Fade ONLY the icon + "Search" text (the pill fill stays solid and just
    // compresses), and FAST — gone once the band drops to ~70% of full height,
    // so the label never lingers into the compressed pill. barHeight is 1:1 with
    // scroll (the pill's bottom must kiss the first row), so this quick text
    // dissolve is what reads as the "immediate" collapse.
    let contentRatio = band > 0 ? barHeight / band : 0
    header.capsuleView.setContentAlpha(max(0, min(1, (contentRatio - 0.7) / 0.3)))
    // Only tappable while meaningfully open — a near-collapsed bar under the nav
    // must not swallow taps meant for the first row.
    header.isUserInteractionEnabled = barHeight > band * 0.5
  }

  private func updateSearchFocusPresentation(animated: Bool) {
    let retracting = searchRetractingFlag
    // A retracting run is never "focused". The close choreography flips
    // searchPresented only at +0.18 — until then the raw binding still reads
    // true, and any apply landing in that window (rows stream in constantly)
    // would look like a fresh focus and relaunch the OPEN flight mid-descent:
    // "the first close is fine, the next ones break".
    let focused =
      (isSearchFocusedBinding?.wrappedValue == true) && !retracting && !presentedSearchRetract
    let focusChanged = focused != presentedSearchFocus
    let overlayChanged = searchOverlayVisibleFlag != presentedSearchOverlay
    let retractChanged = retracting != presentedSearchRetract
    guard focusChanged || overlayChanged || retractChanged || !animated else { return }
    let wasMorphActive = isSearchMorphActive
    presentedSearchFocus = focused
    presentedSearchOverlay = searchOverlayVisibleFlag
    presentedSearchRetract = retracting
    // Morph just fully ended (focus + retract both cleared → back at rest):
    // re-apply the true rest inset once, now that updateTopContentInset is
    // un-gated. A no-op in the common case (held value already equals rest);
    // if a rotation landed mid-freeze, this is the one-frame self-heal.
    if wasMorphActive, !isSearchMorphActive {
      updateTopContentInset()
      // Re-collapse the pinned bar to the current scroll offset now the freeze
      // is lifted (it held full-band through the morph for the takeoff/landing).
      layoutSearchBar(force: true)
    }

    // The list dissolves as ONE OPAQUE SURFACE: background + cells + header
    // ride a single table-level alpha + slide. Per-cell fades left the sheet
    // showing THROUGH the transparent cells — two overlapping lists of
    // content ("list overlap"). An opaque surface at 50% is a clean dissolve;
    // transparent content at 50% over other content is mush.
    guard animated else {
      tableView.backgroundColor = searchDissolveBackground ?? .clear
      tableView.alpha = focused ? 0.0 : 1.0
      tableView.transform =
        focused
        ? CGAffineTransform(translationX: 0, y: -searchSurfaceLift)
        : .identity
      settleSearchFlight(focused: focused)
      return
    }

    if retractChanged && retracting {
      beginSearchCloseRetract()
    }

    guard focusChanged else { return }
    runSearchPoseMotion(focused: focused)
  }

  /// The entire morph (surface ride + chrome crossfade), one tiny UIKit
  /// transaction. Reached two ways: directly from the tap/X UIKit event turn
  /// (primary — commits BEFORE any SwiftUI work exists, so the first frames
  /// always render), or from a SwiftUI-driven focus change (secondary
  /// closers), where presentedSearchFocus gating keeps it from re-running.
  private func runSearchPoseMotion(focused: Bool) {
    // Remember where the list rested at open so the close can put it back exactly
    // (undoing the mid-morph offset drift that otherwise lands the bar collapsed).
    if focused, searchOpenContentOffset == nil {
      searchOpenContentOffset = tableView.contentOffset
    }
    tableView.backgroundColor = searchDissolveBackground ?? .clear
    // The surface slides by the FULL slot→dock distance (Telegram's nav
    // collapse). The bar is now a PINNED sibling (not inside the table), so its
    // window position is INDEPENDENT of tableView.transform — NO transform
    // subtraction (that would double-count). Freeze the bar at FULL band first
    // so takeoff lifts from the full rest slot even if the tap landed while the
    // bar was mid-collapse; this frozen frame then holds through the morph
    // (layoutSearchBar is gated off while isSearchMorphActive) and gives the
    // return its exact landing slot too.
    if focused, let header = searchHeader, let window = view.window {
      header.frame = CGRect(
        x: 0, y: view.safeAreaInsets.top,
        width: view.bounds.width, height: ChatHomeInListSearchHeader.bandHeight)
      header.layoutIfNeeded()
      let slot = header.convert(header.capsuleSlotFrame, to: window)
      let dock = searchDockFrame(in: window, narrowed: false)
      searchSurfaceLift = max(24, slot.minY - dock.minY)
    }
    let lift = searchSurfaceLift
    NSLog(
      "[SearchMorph] list surface %@ lift=%.0f", focused ? "out" : "in", lift)
    if focused {
      beginSearchRideOpen(lift: lift)
    } else {
      beginSearchRideReturn(lift: lift)
    }
  }

  /// THE one shared translate. The table and the input pair move inside a
  /// SINGLE animator block — one spring writes the same transform to both
  /// layers, so the input and the list are one surface by construction and
  /// cannot desync, hitch or not.
  private func runListSurfaceMotion(focused: Bool, lift: CGFloat, pair: UIView?) {
    let spring = UISpringTimingParameters(
      mass: 1,
      stiffness: focused ? 292 : 345,
      damping: focused ? 30.5 : 33.4,
      initialVelocity: .zero)
    let animator = UIViewPropertyAnimator(duration: 0, timingParameters: spring)
    let transform =
      focused ? CGAffineTransform(translationX: 0, y: -lift) : .identity
    animator.addAnimations {
      self.tableView.transform = transform
      pair?.transform = transform
      // The label slides between its centered rest pose and the left focused
      // pose ON the shared spring — the one internal motion, applied to both
      // stacked variants so the crossfade never doubles the label.
      self.searchSolidTwin?.setLabelPose(centered: !focused)
      self.searchSolidTwin?.layoutIfNeeded()
      self.searchGhost?.setLabelPose(centered: !focused)
      self.searchGhost?.layoutIfNeeded()
    }
    animator.addCompletion { [weak self] _ in
      guard let self else { return }
      self.searchSurfaceAnimator = nil
      if focused {
        guard self.presentedSearchFocus else { return }
        SearchMorphProfiler.mark("surface docked")
        // Latch the docked state: the material morph (solid→glass) already ran
        // in-flight via the .effect animation. Pin glass here as a safety if a
        // rapid re-entry clipped the ride; a no-op in the normal case.
        self.searchGhost?.alpha = 1
        self.searchGhost?.setMaterial(glass: true)
        self.searchSolidTwin?.alpha = 0
        self.searchCloseButton?.alpha = 1
      } else {
        guard !self.presentedSearchFocus else { return }
        SearchMorphProfiler.mark("surface settled")
        self.settleSearchFlight(focused: false)
      }
    }
    animator.startAnimation()
    searchSurfaceAnimator = animator
    // Probe the ACTUAL on-screen translate of both layers from here — proves
    // whether the shared spring stays server-side-smooth through the hitches
    // or a commit is snapping the model layer out from under it.
    SearchMorphProfiler.attachSurfaces(table: tableView, pair: pair)
    // The dissolve does NOT ride the spring (its ~0.5s settling tail held a
    // half-blended two-list dwell). Close is slower than open ON PURPOSE:
    // 0.26 @ 0.06 completes ~0.32, right as the return motion visually
    // rests — rows that finish fading in while still drifting read as an
    // "appears, then jumps down" pop once a commit hitch freezes the tail.
    UIView.animate(
      withDuration: focused ? 0.20 : 0.26,
      delay: focused ? 0.0 : 0.06,
      options: [.beginFromCurrentState, .curveEaseInOut]
    ) {
      self.tableView.alpha = focused ? 0.0 : 1.0
    }
  }

  /// UIKit-first open: runs inside the tap's own event turn. The motion is
  /// committed to the render server before SwiftUI evaluates ANYTHING, so
  /// however heavy the Home body re-eval is (~30–60ms), it plays out under
  /// an animation that is already running. presentedSearchFocus is pre-set
  /// so the SwiftUI applies that follow see no focus change and cannot
  /// restart the motion.
  fileprivate func beginSearchOpenFromTap() {
    guard !presentedSearchFocus else { return }
    SearchMorphProfiler.shared.begin("open")
    presentedSearchFocus = true
    runSearchPoseMotion(focused: true)
    // Binding flip on the NEXT runloop: SwiftUI may evaluate a same-turn
    // binding write inside this very transaction, which would re-fatten the
    // flush and eat the takeoff frames all over again.
    DispatchQueue.main.async { [weak self] in
      self?.isSearchFocusedBinding?.wrappedValue = true
    }
  }

  // MARK: Search surface ride (pure UIKit/Core Animation)
  //
  // ONE SHARED TRANSLATE. The list and the input move in the SAME animator
  // block — a single spring writes one transform to the table and to the
  // input PAIR, so they are one surface by construction. The pair is the
  // input's two material variants (solid capsule + glass field) STACKED at
  // one frame, riding together while they crossfade: the input is never in
  // two places, never fades with the rows, and never animates its own
  // position — the shared translate simply carries it slot→dock (the lift
  // is DEFINED as slot.minY − dock.minY). DURING the ride the glass field
  // narrows on its trailing edge (full→narrow) and the X slides IN from just
  // outside that edge into the strip it opens — so the width change reads as
  // the X pushing in from the side; the return mirrors it. The real in-list
  // capsule hides under the pixel-identical twin at takeoff and returns at
  // settle — both swaps at identical frames, invisible.

  private func searchDockFrame(in window: UIWindow, narrowed: Bool) -> CGRect {
    let top = window.safeAreaInsets.top + 2
    let width =
      window.bounds.width - 32 - (narrowed ? HomeSearchChrome.closeSize + 10 : 0)
    return CGRect(
      x: 16, y: top, width: width, height: HomeSearchCapsuleView.fieldHeight)
  }

  private func ensureSearchFlightContainer(in window: UIWindow) -> UIView {
    if let existing = searchFlightContainer, existing.window === window {
      return existing
    }
    searchFlightContainer?.removeFromSuperview()
    let container = SearchFlightContainerView(frame: window.bounds)
    container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    window.addSubview(container)
    searchFlightContainer = container
    return container
  }

  /// The X — a circular glass button the same height as the field (44pt),
  /// sitting OUTSIDE the field in the pair's reserved right strip. Uses the
  /// NATIVE iOS 26 `UIButton.Configuration.glass()`: clear glass matching the
  /// field (no custom tint → no tint mismatch), a capsule shape, and the
  /// system's built-in interactive tap bounce. The old hand-rolled
  /// UIVisualEffectView nested a second glass shell (no proper tap effect) and
  /// carried a 0.12 tint the clear field no longer has.
  private func ensureSearchCloseButton(in pair: UIView) -> UIButton {
    let button: UIButton
    if let existing = searchCloseButton, existing.superview === pair {
      button = existing
    } else {
      searchCloseButton?.removeFromSuperview()
      button = UIButton(type: .custom)
      button.accessibilityLabel = "Close search"
      button.addTarget(self, action: #selector(handleSearchCloseTap), for: .touchUpInside)
      pair.addSubview(button)
      searchCloseButton = button
    }
    let xmark = UIImage(
      systemName: "xmark",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
    if #available(iOS 26.0, *) {
      var config = UIButton.Configuration.glass()
      config.cornerStyle = .capsule
      config.image = xmark
      config.baseForegroundColor = isDark ? .white : .label
      button.configuration = config
    } else {
      button.configuration = nil
      button.setImage(xmark?.withRenderingMode(.alwaysTemplate), for: .normal)
      button.tintColor = isDark ? .white : .label
      button.backgroundColor =
        (isDark ? UIColor.white : UIColor.black).withAlphaComponent(0.08)
      button.layer.cornerRadius = HomeSearchChrome.closeSize / 2
      button.layer.masksToBounds = true
    }
    return button
  }

  private func searchCloseButtonFrame(in pair: UIView) -> CGRect {
    // 44pt — same height as the field — flush to the pair's trailing edge
    // (mirrors the field's 16pt leading margin).
    let size = HomeSearchChrome.closeSize
    return CGRect(
      x: pair.bounds.width - size,
      y: (pair.bounds.height - size) / 2,
      width: size,
      height: size)
  }

  /// The GLASS field's docked frame INSIDE the pair — narrowed on the trailing
  /// edge to clear the X, which now sits OUTSIDE the field (in the reserved
  /// right strip) rather than overlaid inside it. The solid twin still fills the
  /// full pair (it is the full-width in-list capsule), so the open crossfade
  /// pulls the glass's trailing edge in from full→narrow to reveal the X — the
  /// "slight width translate".
  private func searchGhostFrame(in pair: UIView) -> CGRect {
    let reserve = HomeSearchChrome.closeSize + 8
    return CGRect(
      x: 0, y: 0,
      width: max(0, pair.bounds.width - reserve),
      height: pair.bounds.height)
  }

  @objc private func handleSearchCloseTap() {
    // UIKit-first close, mirroring the open: retract NOW in the tap's event
    // turn, the return motion in its own clean runloop at +0.05 (before any
    // SwiftUI descend commit can eat its first frames), and the SwiftUI
    // choreography (nav/tab restore, query clear, gate-off) follows behind —
    // its heavy commits land under the already-running animation. The
    // presented* flags are pre-set so those commits re-run nothing.
    guard presentedSearchFocus else {
      isSearchFocusedBinding?.wrappedValue = false
      return
    }
    SearchMorphProfiler.shared.begin("close")
    if !presentedSearchRetract {
      presentedSearchRetract = true
      beginSearchCloseRetract()
    }
    // Surface return in this SAME event turn — one shared translate carries
    // the list AND the input pair back down while the material converts
    // along the descent, all committed before any SwiftUI work exists.
    presentedSearchFocus = false
    runSearchPoseMotion(focused: false)
    // Next runloop for the same reason as the open: keep THIS transaction
    // (retract + descent) pure so its flush stays tiny.
    DispatchQueue.main.async { [weak self] in
      self?.isSearchFocusedBinding?.wrappedValue = false
    }
  }

  private func ensureSearchPairView(in container: UIView) -> UIView {
    if let existing = searchPairView, existing.superview === container {
      return existing
    }
    searchPairView?.removeFromSuperview()
    let pair = UIView()
    pair.backgroundColor = .clear
    container.addSubview(pair)
    searchPairView = pair
    return pair
  }

  private func ensureSearchGhost(in pair: UIView) -> HomeSearchGhostInputView {
    if let existing = searchGhost, existing.superview === pair {
      return existing
    }
    searchGhost?.removeFromSuperview()
    let ghost = HomeSearchGhostInputView()
    // The ghost's UITextField is the ONE live input — its edits flow into the
    // SwiftUI query binding that drives the results sheet.
    ghost.onTextChanged = { [weak self] text in
      self?.searchTextBinding?.wrappedValue = text
    }
    pair.addSubview(ghost)
    searchGhost = ghost
    return ghost
  }

  private func ensureSearchSolidTwin(in pair: UIView) -> HomeSearchCapsuleView {
    if let existing = searchSolidTwin, existing.superview === pair {
      return existing
    }
    searchSolidTwin?.removeFromSuperview()
    let twin = HomeSearchCapsuleView()
    twin.isUserInteractionEnabled = false
    pair.addSubview(twin)
    searchSolidTwin = twin
    return twin
  }

  private func beginSearchRideOpen(lift: CGFloat) {
    guard let header = searchHeader, let window = view.window else {
      runListSurfaceMotion(focused: true, lift: lift, pair: nil)
      return
    }
    let container = ensureSearchFlightContainer(in: window)
    container.isHidden = false
    window.bringSubviewToFront(container)

    // Rest-space slot. The bar is a pinned sibling now (frozen at full band by
    // runSearchPoseMotion), so its window position is transform-INDEPENDENT — no
    // tableView.transform subtraction. pair.frame is untransformed geometry; the
    // shared translate does ALL the moving.
    let slot = header.convert(header.capsuleSlotFrame, to: window)

    let pair = ensureSearchPairView(in: container)
    pair.frame = slot
    let currentText = searchTextBinding?.wrappedValue ?? ""

    // ONE material, ONE constant color, NO crossfade. The twin is kept
    // allocated (shared code paths reference it) but parked hidden — there is
    // no solid→glass fade. Every crossfade attempt flickered: fading the solid
    // while ramping/draining the glass tint made the field cycle
    // solid→gray-glass→clear and read as the main input "disappearing at the
    // start, then re-entering mid-flight". The field is simply the glass ghost,
    // carrying a fixed tint matched to the resting capsule, from takeoff to
    // dock and back — its alpha is NEVER animated (that alone dropped the effect
    // out) and its tint NEVER changes (that was the color flicker).
    let twin = ensureSearchSolidTwin(in: pair)
    twin.frame = pair.bounds
    twin.applyPalette(isDark: isDark)
    twin.syncText(currentText)
    twin.setLabelPose(centered: true)
    twin.layoutIfNeeded()

    let ghost = ensureSearchGhost(in: pair)
    ghost.frame = pair.bounds
    ghost.applyPalette(isDark: isDark)
    ghost.syncText(currentText)
    ghost.setLabelPose(centered: true)
    // Takes off SOLID (UIColorEffect), pixel-matching the capsule it covers;
    // morphs to glass in-flight via the .effect animation below.
    ghost.setMaterial(glass: false)
    ghost.layoutIfNeeded()

    let close = ensureSearchCloseButton(in: pair)

    // Stack, bottom→top: twin (parked, hidden) · ghost (THE field) · close.
    pair.bringSubviewToFront(ghost)
    pair.bringSubviewToFront(close)

    // A rapid close→reopen leaves the previous run's animations pending (delayed
    // UIView blocks are live CA animations from the moment they're scheduled).
    twin.layer.removeAllAnimations()
    ghost.layer.removeAllAnimations()
    close.layer.removeAllAnimations()
    twin.alpha = 0
    ghost.alpha = 1
    close.alpha = 1
    // The real capsule hands off to the glass at the identical slot (cover is
    // pixel-perfect — see the log below) in this same transaction.
    header.capsuleView.alpha = 0

    // Cover check: the glass (at pairSlot) must sit exactly over the real
    // capsule at takeoff, else hiding the capsule reads as "the input
    // disappears" before the glass appears. Logged once per open.
    let realCapsule =
      header.capsuleView.superview?.convert(header.capsuleView.frame, to: window)
      ?? .zero
    NSLog(
      "[SearchMorph] open cover pairSlot=(%.0f,%.0f,%.0f,%.0f) realCapsule=(%.0f,%.0f,%.0f,%.0f) tableTy=%.1f",
      slot.origin.x, slot.origin.y, slot.width, slot.height,
      realCapsule.origin.x, realCapsule.origin.y, realCapsule.width, realCapsule.height,
      tableView.transform.ty)

    SearchMorphProfiler.mark("ride begin")
    runListSurfaceMotion(focused: true, lift: lift, pair: pair)

    // Material morph solid → clear glass, done Apple's way: animate the .effect
    // property (UIColorEffect → UIGlassEffect) so the system plays its native
    // materialize transition. NO alpha, NO tint ramp — those were the disappear
    // and the colour flicker. One view, one clean material entry.
    UIView.animate(
      withDuration: 0.30, delay: 0.0,
      options: [.beginFromCurrentState, .curveEaseInOut]
    ) {
      ghost.setMaterial(glass: true)
    }

    // The glass also narrows its trailing edge full→narrow to open the strip the
    // X slides into.
    let narrowedGhost = searchGhostFrame(in: pair)
    UIView.animate(
      withDuration: 0.20, delay: 0.0,
      options: [.beginFromCurrentState, .curveEaseInOut]
    ) {
      ghost.frame = narrowedGhost
      ghost.layoutIfNeeded()
    }
    // The X enters FROM OUTSIDE: it starts fully past the pair's trailing edge
    // and SLIDES left into the strip the narrowing glass uncovers. Its alpha is
    // NOT animated (it too owns a glass shell — animating the button's alpha
    // would drop that effect out); it is simply off-screen until it slides in.
    let closeDocked = searchCloseButtonFrame(in: pair)
    close.frame = closeDocked.offsetBy(dx: HomeSearchChrome.closeSize + 8, dy: 0)
    UIView.animate(
      withDuration: 0.22, delay: 0.05,
      options: [.beginFromCurrentState, .curveEaseOut]
    ) {
      close.frame = closeDocked
    }

    // Keyboard AFTER the motion is committed to the render server — its ~90ms
    // main-thread stall can then no longer freeze the first frames.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
      guard let self, self.presentedSearchFocus else { return }
      SearchMorphProfiler.mark("focus request")
      self.searchGhost?.textField.becomeFirstResponder()
    }
  }

  private func beginSearchRideReturn(lift: CGFloat) {
    guard let window = view.window,
      let container = searchFlightContainer,
      let pair = searchPairView, pair.superview === container,
      let ghost = searchGhost, ghost.superview === pair
    else {
      runListSurfaceMotion(focused: false, lift: lift, pair: nil)
      return
    }
    // Re-anchor on the slot's CURRENT rest position (layout may have drifted
    // while docked) — identity transform then lands the pair EXACTLY on the
    // in-list capsule, so the settle handback is pixel-invisible.
    if let header = searchHeader {
      // Pinned sibling, frozen at full band since takeoff → its window frame is
      // the exact landing slot, transform-independent (no tableView.transform
      // subtraction). The descent's transform→identity lands the pair dead on
      // the in-list capsule.
      let slot = header.convert(header.capsuleSlotFrame, to: window)
      // Set the frame under an IDENTITY transform. The pair still carries the
      // −lift transform from the docked/open state; assigning `.frame` while a
      // transform is live makes UIKit bake the transform into position, so the
      // untransformed rest frame becomes slot+lift — the descent then lands
      // `lift` px low and snaps up at the settle handback (probe caught
      // pairVisualY=180 vs capsule 122, delta=58). Clear → set → restore leaves
      // the visual docked but fixes the rest frame to the true slot, so the
      // animator's transform→identity lands the input exactly on the capsule.
      let liveTransform = pair.transform
      pair.transform = .identity
      pair.frame = slot
      pair.transform = liveTransform
    }

    // Twin stays parked/hidden — glass-only descent, mirroring the open.
    let twin = ensureSearchSolidTwin(in: pair)
    twin.frame = pair.bounds
    twin.applyPalette(isDark: isDark)
    twin.syncText(searchTextBinding?.wrappedValue ?? "")
    twin.setLabelPose(centered: false)
    twin.layoutIfNeeded()
    // Stack, bottom→top: twin (parked, hidden) · ghost (THE field) · close.
    pair.bringSubviewToFront(ghost)
    if let close = searchCloseButton, close.superview === pair {
      pair.bringSubviewToFront(close)
    }

    // An open closed within ~0.4s still has delayed animations pending.
    twin.layer.removeAllAnimations()
    ghost.layer.removeAllAnimations()
    twin.alpha = 0
    ghost.alpha = 1
    // Starts from the docked CLEAR GLASS and morphs back to SOLID during the
    // descent (mirror of the open) via the .effect animation — never the alpha,
    // never a tint ramp. Lands solid so the handback to the in-list capsule is
    // solid→solid.
    ghost.setMaterial(glass: true)
    UIView.animate(
      withDuration: 0.28, delay: 0.0,
      options: [.beginFromCurrentState, .curveEaseInOut]
    ) {
      ghost.setMaterial(glass: false)
    }

    // The glass widens narrow→full so the handback to the full-width in-list
    // capsule sees no width step.
    UIView.animate(
      withDuration: 0.20, delay: 0.0,
      options: [.beginFromCurrentState, .curveEaseInOut]
    ) {
      ghost.frame = pair.bounds
      ghost.layoutIfNeeded()
    }
    if let close = searchCloseButton {
      close.layer.removeAllAnimations()
      // Mirror of the open: the X slides back OUT past the trailing edge as the
      // field widens to full. Alpha is not animated (glass shell) — it just
      // slides off-screen.
      let closeOut = searchCloseButtonFrame(in: pair).offsetBy(
        dx: HomeSearchChrome.closeSize + 8, dy: 0)
      close.alpha = 1
      UIView.animate(
        withDuration: 0.18, delay: 0.0,
        options: [.beginFromCurrentState, .curveEaseIn]
      ) {
        close.frame = closeOut
      }
    }
    runListSurfaceMotion(focused: false, lift: lift, pair: pair)
  }

  private func beginSearchCloseRetract() {
    guard let ghost = searchGhost else { return }
    // Resign AFTER this commit — dismissal stalls ~40ms on the main thread.
    DispatchQueue.main.async {
      SearchMorphProfiler.mark("keyboard dismiss request")
      ghost.textField.resignFirstResponder()
    }
  }

  private func settleSearchFlight(focused: Bool) {
    if focused {
      guard let window = view.window else { return }
      let container = ensureSearchFlightContainer(in: window)
      container.isHidden = false
      let dock = searchDockFrame(in: window, narrowed: false)
      let pair = ensureSearchPairView(in: container)
      // Docked invariant: frame = REST slot, transform = −lift. The close
      // animates transform back to identity, so the settled state must be
      // expressed the same way the animated state is.
      pair.frame = dock.offsetBy(dx: 0, dy: searchSurfaceLift)
      pair.transform = CGAffineTransform(translationX: 0, y: -searchSurfaceLift)
      let ghost = ensureSearchGhost(in: pair)
      // Docked glass rests NARROWED (X sits outside it); the animated paths
      // reach this same frame via the crossfade's width translate.
      ghost.frame = searchGhostFrame(in: pair)
      ghost.applyPalette(isDark: isDark)
      ghost.syncText(searchTextBinding?.wrappedValue ?? "")
      ghost.alpha = 1
      ghost.setLabelPose(centered: false)
      ghost.setMaterial(glass: true)  // docked = clear glass
      let close = ensureSearchCloseButton(in: pair)
      close.frame = searchCloseButtonFrame(in: pair)
      close.alpha = 1
      searchSolidTwin?.alpha = 0
      searchHeader?.capsuleView.alpha = 0
      tableView.alpha = 0
      tableView.transform = CGAffineTransform(translationX: 0, y: -searchSurfaceLift)
    } else {
      // Handoff probe: the pair's VISIBLE position at this instant (presentation
      // layer, so any un-settled spring tail is included) vs the real capsule
      // it's about to reveal. A non-zero delta is the px the input snaps at the
      // swap — the user's "rests low, then jumps to top".
      if let pair = searchPairView, let window = view.window,
        let capsule = searchHeader?.capsuleView
      {
        let pairVisualY =
          (pair.layer.presentation()?.frame.origin.y).map {
            $0 + (pair.superview?.frame.origin.y ?? 0)
          } ?? pair.convert(pair.bounds, to: window).origin.y
        let capsuleY =
          capsule.superview?.convert(capsule.frame, to: window).origin.y ?? 0
        NSLog(
          "[SearchMorph] handoff pairVisualY=%.1f capsuleY=%.1f delta=%.1f",
          pairVisualY, capsuleY, pairVisualY - capsuleY)
      }
      searchGhost?.alpha = 0
      searchSolidTwin?.alpha = 0
      searchCloseButton?.alpha = 0
      searchPairView?.transform = .identity
      // The pair hands back to the real in-list capsule at the identical
      // frame — invisible swap.
      searchHeader?.capsuleView.alpha = 1
      searchFlightContainer?.isHidden = true
      tableView.alpha = 1
      tableView.transform = .identity
      // Undo the mid-morph offset drift BEFORE re-collapsing the bar: restore the
      // exact rest offset captured at open, clamped to the current inset. Without
      // this the list returns ~55pt scrolled down and the bar rebuilds collapsed.
      if let openOffset = searchOpenContentOffset {
        let minY = -tableView.adjustedContentInset.top
        let maxY = max(
          minY,
          tableView.contentSize.height - tableView.bounds.height
            + tableView.adjustedContentInset.bottom)
        let y = min(max(openOffset.y, minY), maxY)
        if abs(y - tableView.contentOffset.y) > 0.5 {
          tableView.setContentOffset(CGPoint(x: openOffset.x, y: y), animated: false)
        }
      }
      searchOpenContentOffset = nil
      // Reconcile the revealed pinned bar to the current scroll offset. This
      // settle can run while the retract flag still reads active (isSearchMorph
      // Active), so force past the layoutSearchBar gate. Held full-band for the
      // landing; now snaps to whatever the offset implies (full band when the
      // list is at the top, the normal case after a top-anchored open/close).
      layoutSearchBar(force: true)
      // The opaque backing STAYS — identical to the SwiftUI background
      // behind it, so it's invisible at rest, and no settle/gate-off
      // ordering can ever flash the sheet through the landed list.
    }
  }

  /// Instantly collapse the search morph to its closed rest state — no
  /// animation — when Home is leaving the screen (tab switch or chat push).
  /// The morph's overlay is parented to the window, so without this it floats
  /// over the incoming page. Idempotent and guarded: only runs when a morph is
  /// actually on screen, so a normal navigation off an unsearched Home is a
  /// no-op, and it can't disturb the animated close when the user dismisses
  /// while staying on Home.
  private func forceEndSearchMorph() {
    let containerShowing = (searchFlightContainer?.isHidden == false)
    guard isSearchMorphActive || containerShowing else { return }
    NSLog(
      "[SearchMorph] forceEnd (leaving Home) focus=%d retract=%d containerShowing=%d",
      presentedSearchFocus ? 1 : 0, presentedSearchRetract ? 1 : 0,
      containerShowing ? 1 : 0)

    // Cancel the shared spring FIRST so its completion (settle / tint drain)
    // can't fire after teardown and resurrect the morph on the next view.
    if searchSurfaceAnimator?.state == .active {
      searchSurfaceAnimator?.stopAnimation(true)
    }
    searchSurfaceAnimator = nil

    // The teardown runs inside the transition coordinator's animation context;
    // force it to be a synchronous, un-animated snap so nothing eases visibly.
    UIView.performWithoutAnimation {
      CATransaction.begin()
      CATransaction.setDisableActions(true)

      // Resign BEFORE the inset restore — the keyboard-hide inset handler must
      // not fight updateTopContentInset().
      searchGhost?.textField.resignFirstResponder()

      // Gate down first so updateTopContentInset() (guarded on
      // isSearchMorphActive) is free to restore the frozen inset below.
      presentedSearchFocus = false
      presentedSearchOverlay = false
      presentedSearchRetract = false

      // Drop any pending crossfade opacity/position animations, then snap the
      // overlay to the closed rest state and hand back to the in-list capsule.
      searchPairView?.layer.removeAllAnimations()
      searchSolidTwin?.layer.removeAllAnimations()
      searchGhost?.layer.removeAllAnimations()
      searchCloseButton?.layer.removeAllAnimations()
      searchGhost?.alpha = 0
      searchSolidTwin?.alpha = 0
      searchCloseButton?.alpha = 0
      searchPairView?.transform = .identity
      searchHeader?.capsuleView.alpha = 1
      searchFlightContainer?.isHidden = true
      tableView.alpha = 1
      tableView.transform = .identity

      // The inset was frozen for the duration of the morph — restore it now
      // that the gate is down, so the list rests correctly on return.
      updateTopContentInset()
      // Put the list back where search opened (undo mid-morph drift) so the bar
      // doesn't rebuild collapsed on return to Home.
      if let openOffset = searchOpenContentOffset {
        let minY = -tableView.adjustedContentInset.top
        let maxY = max(
          minY,
          tableView.contentSize.height - tableView.bounds.height
            + tableView.adjustedContentInset.bottom)
        tableView.setContentOffset(
          CGPoint(x: openOffset.x, y: min(max(openOffset.y, minY), maxY)), animated: false)
      }
      searchOpenContentOffset = nil
      // Reposition the pinned bar for the rest offset (gate is down, but force
      // for symmetry with the settle path).
      layoutSearchBar(force: true)

      CATransaction.commit()
    }

    // Flip the SwiftUI binding on the NEXT runloop — writing SwiftUI state
    // inside the disappear/layout pass risks "modifying state during view
    // update". The visual teardown above is already synchronous.
    DispatchQueue.main.async { [weak self] in
      self?.isSearchFocusedBinding?.wrappedValue = false
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    AppUITrace.notice("ChatHomeNativeListController viewDidLoad")
    view.backgroundColor = .clear

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.backgroundColor = .clear
    tableView.separatorStyle = .none
    tableView.sectionHeaderTopPadding = 0
    tableView.contentInsetAdjustmentBehavior = .never
    tableView.rowHeight = 84
    tableView.estimatedRowHeight = 84
    // Smooth scroll: avoid large estimated→actual height pops.
    tableView.estimatedSectionHeaderHeight = 0
    tableView.estimatedSectionFooterHeight = 0
    if #available(iOS 15.0, *) {
      tableView.sectionHeaderTopPadding = 0
    }
    tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    tableView.dataSource = self
    tableView.delegate = self
    tableView.register(ChatHomeCardCell.self, forCellReuseIdentifier: ChatHomeCardCell.reuseIdentifier)
    // No UIRefreshControl — pull-to-refresh spinner removed from home.
    tableView.refreshControl = nil
    tableView.keyboardDismissMode = .onDrag
    tableView.addGestureRecognizer(previewHoldRecognizer)
    bridgeStatusObserver = NotificationCenter.default.addObserver(
      forName: AgentPairingService.statusDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard let self else { return }
      let status = (note.object as? AgentBridgeStatus) ?? AgentPairingService.lastStatusSnapshot
      AppUITrace.notice(
        "ChatHomeNative bridgeStatus notification tasks=\(status?.runningTasks.count ?? 0)"
      )
      self.reconfigureVisibleCellsInPlace()
    }

    view.addSubview(tableView)

    NSLayoutConstraint.activate([
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.topAnchor.constraint(equalTo: view.topAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    if !rows.isEmpty {
      tableView.reloadData()
    }
    updateInListSearchHeader(animated: false)
    updateSearchFocusPresentation(animated: false)
    AppUIStallWatchdog.shared.updateContext(
      "ChatHomeNativeListController viewDidLoad rows=\(rows.count)"
    )
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    updateTopContentInset()
    applyInitialTopOffsetIfNeeded()
    // Re-position/re-collapse the pinned search bar for the current width and
    // scroll offset (rotation, first layout). Not a tableHeaderView anymore —
    // layoutSearchBar owns its geometry (top pinned under nav, height driven by
    // scroll). Skipped mid-morph (frozen); the settle re-runs it.
    layoutSearchBar()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    AppUITrace.notice(
      "ChatHomeNativeListController viewWillAppear rows=\(rows.count) editing=\(isEditingMode ? "Y" : "N")"
    )
    AppUIStallWatchdog.shared.updateContext(
      "ChatHomeNativeListController viewWillAppear rows=\(rows.count)"
    )
    startBridgeStatusPolling()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    ChatWallpaperView.prewarm(
      rawAppearance: ChatAppearanceDraftStore.chatRawAppearance(isDark: isDark),
      size: view.bounds.size,
      scale: view.window?.screen.scale ?? UIScreen.main.scale
    )
    AppUITrace.notice(
      "ChatHomeNativeListController viewDidAppear rows=\(rows.count) contentSize=\(Int(tableView.contentSize.height)) offsetY=\(Int(tableView.contentOffset.y))"
    )
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    // The search morph lives on the WINDOW (above the tab bar and any pushed
    // nav), so if we leave Home mid-morph or while docked it would float over
    // the incoming chat/tab — the "search opens on other pages" bug. End it
    // instantly HERE, before the outgoing transition begins, so the morph is
    // confined to Home. viewWillDisappear (not viewDidDisappear) fires ahead of
    // the transition, so nothing lingers over the incoming screen.
    forceEndSearchMorph()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    AppUITrace.notice(
      "ChatHomeNativeListController viewDidDisappear rows=\(rows.count) offsetY=\(Int(tableView.contentOffset.y))"
    )
    bridgeStatusPollTask?.cancel()
    bridgeStatusPollTask = nil
  }

  deinit {
    bridgeStatusPollTask?.cancel()
    if let bridgeStatusObserver {
      NotificationCenter.default.removeObserver(bridgeStatusObserver)
    }
    // The flight layer lives in the window, not our view tree.
    searchFlightContainer?.removeFromSuperview()
  }

  private func startBridgeStatusPolling() {
    bridgeStatusPollTask?.cancel()
    bridgeStatusPollTask = Task { @MainActor [weak self] in
      while !Task.isCancelled, let self {
        var hasRunningTasks = false
        if let config = AppSessionConfig.current {
          do {
            let status = try await AgentPairingService.statusCoalesced(config: config)
            hasRunningTasks = !status.runningTasks.isEmpty
            AppUITrace.notice(
              "ChatHomeNative bridgeStatus poll connected=\(status.connected) tasks=\(status.runningTasks.count)"
            )
            // Repainting every cell on every tick also re-drove each row's avatar load —
            // visible in the server log as the same 404 avatar fetched every ~3s. Repaint
            // only when the status actually changed, or while a run is live (its progress
            // label ticks).
            let signature =
              "\(status.connected)|\(status.paired)|\(status.runningTasks.count)|\(status.devices.first?.label ?? "")"
            if hasRunningTasks || signature != self.lastBridgeStatusPollSignature {
              self.lastBridgeStatusPollSignature = signature
              self.reconfigureVisibleCellsInPlace()
            }
          } catch {
            AppUITrace.notice(
              "ChatHomeNative bridgeStatus poll failed error=\(error.localizedDescription)"
            )
          }
        } else {
          AppUITrace.notice("ChatHomeNative bridgeStatus poll skipped no session config")
        }
        // Idle Home does not need a 2s heartbeat — each call is ~700ms of server time and
        // this loop ran forever while Home was on screen. Stay responsive only while a run
        // is actually live; the LAN bridge pushes authoritative snapshots either way.
        let seconds: UInt64 = hasRunningTasks ? 3 : 15
        try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
      }
    }
  }

  func apply(
    rows: [ChatHomeListRow],
    isDark: Bool,
    isEditing: Bool,
    showsRightCheckmark: Bool,
    selectedChatIDs: Set<String>,
    compactForwardStyle: Bool = false,
    recentRows: [ChatHomeListRow] = [],
    peopleResults: [ContactSearchUser] = [],
    isGlobalSearching: Bool = false
  ) {
    let nextSignature = Self.signature(
      rows: rows,
      isDark: isDark,
      isEditing: isEditing,
      showsRightCheckmark: showsRightCheckmark,
      selectedChatIDs: selectedChatIDs,
      compactForwardStyle: compactForwardStyle
    )
    let searchSig =
      "\(searchTextBinding?.wrappedValue ?? "")|\(isSearchFocusedBinding?.wrappedValue == true)|\(searchOverlayVisibleFlag)|\(searchRetractingFlag)|\(recentRows.count)|\(peopleResults.count)|\(isGlobalSearching)"
    let signatureUnchanged = nextSignature == lastAppliedSignature
    let searchUnchanged = searchSig == lastSearchHeaderSignature
    if signatureUnchanged && searchUnchanged { return }

    let startedAt = ProcessInfo.processInfo.systemUptime
    let previousRowCount = self.rows.count
    let previousContentOffset = tableView.contentOffset
    let jumpApplyEnter = previousContentOffset.y
    defer {
      let jumpNow = tableView.contentOffset.y
      if abs(jumpNow - jumpApplyEnter) > 1 {
        NSLog(
          "[SearchJump] apply(sync) off %.1f→%.1f insetTop=%.1f navSafe=%.1f ovl=%d",
          jumpApplyEnter, jumpNow, tableView.contentInset.top,
          view.safeAreaInsets.top, searchOverlayVisibleFlag ? 1 : 0)
      }
    }
    AppUITrace.notice(
      "ChatHomeNativeListController apply start previousRows=\(previousRowCount) nextRows=\(rows.count) editing=\(isEditing ? "Y" : "N") selected=\(selectedChatIDs.count) offsetY=\(Int(previousContentOffset.y))"
    )
    AppUIStallWatchdog.shared.updateContext(
      "ChatHomeNativeListController apply nextRows=\(rows.count) previousRows=\(previousRowCount)"
    )
    lastAppliedSignature = nextSignature
    lastSearchHeaderSignature = searchSig
    let previousIDs = self.rows.map(\.chatId)
    let nextIDs = rows.map(\.chatId)
    let orderUnchanged = previousIDs == nextIDs
    let previousEditing = self.isEditingMode
    self.rows = rows
    self.recentRows = recentRows
    self.peopleResults = peopleResults
    self.isGlobalSearching = isGlobalSearching
    self.isDark = isDark
    self.isEditingMode = isEditing
    self.showsRightCheckmark = showsRightCheckmark
    self.compactForwardStyle = compactForwardStyle
    self.selectedChatIDs = selectedChatIDs
    // Forward sheet: denser rows (smaller avatar + name-only). Stable height.
    tableView.rowHeight = compactForwardStyle ? 52 : 84
    tableView.estimatedRowHeight = tableView.rowHeight

    guard isViewLoaded else {
      AppUITrace.notice(
        "ChatHomeNativeListController apply storedUntilViewLoad rows=\(rows.count) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))"
      )
      AppUIStallWatchdog.shared.updateContext(
        "ChatHomeNativeListController apply stored rows=\(rows.count)"
      )
      return
    }

    updateInListSearchHeader(animated: true)
    updateSearchFocusPresentation(animated: true)

    // Search-only header/recents update — don't reload the table body.
    if signatureUnchanged {
      return
    }

    // Editing / selection-only signature change with same order → soft reconfigure.
    // Allow edit-layout animation so checkmarks slide in instead of "pop".
    if orderUnchanged, previousRowCount == rows.count, !rows.isEmpty {
      let editingChanged = previousEditing != isEditing
      reconfigureVisibleCellsInPlace(animateEditLayout: editingChanged)
      if editingChanged {
        UIView.animate(
          withDuration: 0.28,
          delay: 0,
          options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
        ) {
          self.updateTopContentInset(force: true)
          self.tableView.layoutIfNeeded()
        }
      } else {
        updateTopContentInset()
      }
      return
    }

    // Prefer LCS-based insert/delete so chat bumps animate instead of reload pop.
    if previousRowCount > 0, !rows.isEmpty, view.window != nil,
      let delta = Self.animatableRowDelta(fromIDs: previousIDs, toIDs: nextIDs)
    {
      tableView.performBatchUpdates({
        if !delta.deletedIndexPaths.isEmpty {
          tableView.deleteRows(at: delta.deletedIndexPaths, with: .fade)
        }
        if !delta.insertedIndexPaths.isEmpty {
          tableView.insertRows(at: delta.insertedIndexPaths, with: .fade)
        }
      }, completion: { [weak self] _ in
        guard let self else { return }
        let minY = -self.tableView.adjustedContentInset.top
        let maxY = max(
          minY,
          self.tableView.contentSize.height - self.tableView.bounds.height
            + self.tableView.adjustedContentInset.bottom
        )
        let y = min(max(previousContentOffset.y, minY), maxY)
        if abs(y - self.tableView.contentOffset.y) > 1 {
          NSLog(
            "[SearchJump] delta-preserve off %.1f→%.1f prev=%.1f min=%.1f max=%.1f insetTop=%.1f",
            self.tableView.contentOffset.y, y, previousContentOffset.y, minY, maxY,
            self.tableView.contentInset.top)
        }
        self.tableView.setContentOffset(
          CGPoint(x: previousContentOffset.x, y: y), animated: false)
        self.reconfigureVisibleCellsInPlace()
      })
      return
    }

    let shouldPreserveOffset = !rows.isEmpty && view.window != nil
    UIView.performWithoutAnimation {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      tableView.reloadData()
      tableView.layoutIfNeeded()
      if shouldPreserveOffset {
        let minY = -tableView.adjustedContentInset.top
        let maxY = max(
          minY,
          tableView.contentSize.height - tableView.bounds.height
            + tableView.adjustedContentInset.bottom
        )
        let y = min(max(previousContentOffset.y, minY), maxY)
        if abs(y - tableView.contentOffset.y) > 1 {
          NSLog(
            "[SearchJump] reload-preserve off %.1f→%.1f prev=%.1f min=%.1f max=%.1f insetTop=%.1f",
            tableView.contentOffset.y, y, previousContentOffset.y, minY, maxY,
            tableView.contentInset.top)
        }
        tableView.setContentOffset(CGPoint(x: previousContentOffset.x, y: y), animated: false)
      }
      CATransaction.commit()
    }
    AppUITrace.notice(
      "ChatHomeNativeListController apply done rows=\(rows.count) durationMs=\(Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)) contentSize=\(Int(tableView.contentSize.height)) offsetY=\(Int(tableView.contentOffset.y))"
    )
    AppUIStallWatchdog.shared.updateContext(
      "ChatHomeNativeListController apply done rows=\(rows.count)"
    )
  }

  private struct AnimatableRowDelta {
    /// Old-index rows to delete: true removals *and* the source slots of rows that
    /// moved (a move is modelled as delete-at-old + insert-at-new so intermediate
    /// rows slide smoothly and the moved row lands with fresh content).
    let deletedIndexPaths: [IndexPath]
    /// New-index rows to insert: true additions *and* the destination slots of moves.
    let insertedIndexPaths: [IndexPath]
    /// Subset of `deletedIndexPaths` that are genuine removals — only these get the
    /// deletion "wipe" overlay; a row merely floating to the top must not wipe.
    let removedIndexPaths: [IndexPath]
  }

  /// Ids that keep their relative order between the two snapshots stay put; every
  /// other row (added, removed, or reordered) is expressed as a delete+insert. This
  /// makes a chat that jumps to the top on a new message animate instead of doing a
  /// hard `reloadData`, while still animating plain inserts/deletes as before.
  private static func animatableRowDelta(
    from previousRows: [ChatHomeListRow],
    to nextRows: [ChatHomeListRow]
  ) -> AnimatableRowDelta? {
    animatableRowDelta(fromIDs: previousRows.map(\.chatId), toIDs: nextRows.map(\.chatId))
  }

  private static func animatableRowDelta(
    fromIDs previousIDs: [String],
    toIDs nextIDs: [String]
  ) -> AnimatableRowDelta? {
    let previousSet = Set(previousIDs)
    let nextSet = Set(nextIDs)

    guard previousSet.count == previousIDs.count, nextSet.count == nextIDs.count else { return nil }

    let stable = Set(longestCommonSubsequence(previousIDs, nextIDs))

    let deleted = previousIDs.enumerated().compactMap { index, chatId -> IndexPath? in
      stable.contains(chatId) ? nil : IndexPath(row: index, section: 0)
    }
    let inserted = nextIDs.enumerated().compactMap { index, chatId -> IndexPath? in
      stable.contains(chatId) ? nil : IndexPath(row: index, section: 0)
    }
    let removed = previousIDs.enumerated().compactMap { index, chatId -> IndexPath? in
      nextSet.contains(chatId) ? nil : IndexPath(row: index, section: 0)
    }

    guard !deleted.isEmpty || !inserted.isEmpty else { return nil }
    // Keep the animation to a handful of rows; a wholesale reshuffle (initial load,
    // big refresh) still snaps via reloadData rather than animating dozens of rows.
    guard deleted.count + inserted.count <= 8 else { return nil }

    return AnimatableRowDelta(
      deletedIndexPaths: deleted,
      insertedIndexPaths: inserted,
      removedIndexPaths: removed
    )
  }

  /// Ids common to both snapshots that preserve relative order (standard LCS).
  private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
    let n = a.count
    let m = b.count
    guard n > 0, m > 0 else { return [] }
    var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
    for i in stride(from: n - 1, through: 0, by: -1) {
      for j in stride(from: m - 1, through: 0, by: -1) {
        dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
      }
    }
    var result: [String] = []
    var i = 0
    var j = 0
    while i < n, j < m {
      if a[i] == b[j] {
        result.append(a[i])
        i += 1
        j += 1
      } else if dp[i + 1][j] >= dp[i][j + 1] {
        i += 1
      } else {
        j += 1
      }
    }
    return result
  }



  /// Update visible cells without `reloadData` so scroll position and cell
  /// identity stay put when only content (preview/unread/online) changed.
  /// When `animateEditLayout` is true, do **not** wrap in `performWithoutAnimation`
  /// so `ChatHomeCardCell.updateEditingLayout` can spring the checkmark gutter.
  private func reconfigureVisibleCellsInPlace(animateEditLayout: Bool = false) {
    guard let visible = tableView.indexPathsForVisibleRows, !visible.isEmpty else {
      // Nothing on screen yet (or empty) — still need dataSource count in sync.
      if tableView.numberOfRows(inSection: 0) != rows.count {
        UIView.performWithoutAnimation { tableView.reloadData() }
      }
      return
    }
    let apply: () -> Void = {
      for indexPath in visible {
        guard self.rows.indices.contains(indexPath.row),
          let cell = self.tableView.cellForRow(at: indexPath) as? ChatHomeCardCell
        else { continue }
        let row = self.rows[indexPath.row]
        cell.configure(
          row: row,
          isDark: self.isDark,
          avatarBackgroundColor: nil,
          avatarGradientColors: self.resolvedAvatarGradientColors(for: row),
          unreadBadgeColor: AppThemePalette.resolve(for: self.isDark ? .dark : .light).accentUIColor,
          isEditing: self.isEditingMode,
          isEditSelected: self.selectedChatIDs.contains(row.chatId),
          showsRightCheckmark: self.showsRightCheckmark,
          compactForwardStyle: self.compactForwardStyle
        )
        cell.isHidden = row.chatId == self.activePreviewChatID
      }
    }
    if animateEditLayout {
      apply()
    } else {
      UIView.performWithoutAnimation(apply)
    }
  }

  private static func signature(
    rows: [ChatHomeListRow],
    isDark: Bool,
    isEditing: Bool,
    showsRightCheckmark: Bool,
    selectedChatIDs: Set<String>,
    compactForwardStyle: Bool = false
  ) -> String {
    let rowSignature = rows.map { row in
      [
        row.chatId,
        row.title,
        row.preview,
        row.timeLabel,
        "\(row.unreadCount)",
        "\(row.markedUnread)",
        "\(row.muted)",
        "\(row.pinned)",
        "\(row.archived)",
        "\(row.isTyping)",
        "\(row.isOnline)",
        row.avatarUri ?? "",
        row.peerTier ?? "",
        "\(row.lastMessageAt)",
        row.latestOutgoingDisplayStatus ?? "",
        firstPaintTailFingerprint(for: row),
      ].joined(separator: "\u{1F}")
    }
    return rowSignature.joined(separator: "||") + "||\(isDark ? "dark" : "light")||\(isEditing ? "edit" : "normal")||\(showsRightCheckmark ? "check" : "no_check")||\(compactForwardStyle ? "compact" : "full")||\(selectedChatIDs.sorted().joined(separator: ","))"
  }

  /// The visible Home text can stay identical while its background-prefetched chat tail
  /// grows from one row to sixteen. Include only a cheap boundary fingerprint so the
  /// native controller adopts that new first-paint payload without hashing full history.
  private static func firstPaintTailFingerprint(for row: ChatHomeListRow) -> String {
    let tail = row.initialMessages.isEmpty ? row.previewRows : row.initialMessages
    guard !tail.isEmpty else { return "tail:0" }

    func token(_ value: Any?) -> String {
      if let text = value as? String { return text }
      if let number = value as? NSNumber { return number.stringValue }
      return ""
    }
    func messageToken(_ raw: [String: Any]) -> String {
      let message = (raw["message"] as? [String: Any]) ?? raw
      return token(
        message["id"] ?? message["messageId"] ?? message["message_id"]
          ?? raw["id"] ?? raw["messageId"] ?? raw["message_id"] ?? raw["key"])
    }

    let firstID = messageToken(tail[0])
    let newest = tail[tail.count - 1]
    let newestMessage = (newest["message"] as? [String: Any]) ?? newest
    let newestID = messageToken(newest)
    let revision = token(
      newestMessage["updatedAt"] ?? newestMessage["updated_at"]
        ?? newestMessage["editedAt"] ?? newestMessage["edited_at"]
        ?? newestMessage["timestampMs"] ?? newestMessage["timestamp_ms"]
        ?? newestMessage["timestamp"])
    let status = token(
      newestMessage["status"] ?? newestMessage["deliveryStatus"]
        ?? newestMessage["delivery_status"])
    let reactions = ((newestMessage["reactions"] as? [[String: Any]]) ?? [])
      .map { reaction in
        let emoji = token(reaction["emoji"] ?? reaction["reaction"])
        let count = token(reaction["count"])
        let selected = token(reaction["isSelected"] ?? reaction["is_selected"])
        return "\(emoji):\(count):\(selected)"
      }
      .joined(separator: ",")
    return "tail:\(tail.count):\(firstID):\(newestID):\(revision):\(status):\(reactions)"
  }

  private func previewDebugLog(_ message: String) {
    NSLog("[ChatHomePreview] t=%.3f %@", CACurrentMediaTime(), message)
  }

  @objc private func handlePreviewHold(_ recognizer: UILongPressGestureRecognizer) {
    let point = recognizer.location(in: tableView)

    switch recognizer.state {
    case .began:
      guard
        !isEditingMode,
        !presentedSearchFocus,
        presentedViewController == nil,
        let indexPath = tableView.indexPathForRow(at: point),
        rows.indices.contains(indexPath.row),
        !rows[indexPath.row].isArchiveEntry,
        let cell = tableView.cellForRow(at: indexPath) as? ChatHomeCardCell
      else { return }

      openSwipeCell?.closeSwipe(animated: true)
      openSwipeCell = nil
      previewDepressAnimator?.stopAnimation(true)
      previewDepressAnimator = nil
      previewHoldEngagement?.cancel()
      previewHoldEngagement = nil
      clearPendingPreview()
      previewHoldCell = cell
      previewHoldIndexPath = indexPath
      previewHoldOrigin = point
      previewHoldOriginalTransform = cell.transform
      previewHoldCommitted = false
      let row = rows[indexPath.row]
      previewDebugLog(
        "hold began row=\(indexPath.row) point=\(NSCoder.string(for: point))"
      )

      // This is a hold now, not a tap: the tap highlight leaves the card the
      // moment the hold is recognized. Letting it linger into the depress made
      // it settle under the sinking card and flicker out mid-hold.
      cell.setPressOverlaySuppressed(true, animated: true)

      // The hold is already recognized (finger still for 0.12s) — the card
      // sinks for the commit window, easeIn keeping the first frames gentle.
      // A released tap never reaches here at all: minimumPressDuration gates
      // the entire hold path. Commit lands at ~0.42s from touch-down.
      let depress = UIViewPropertyAnimator(duration: 0.30, curve: .easeIn) {
        cell.transform = self.previewHoldOriginalTransform.scaledBy(x: 0.95, y: 0.95)
      }
      depress.addCompletion { [weak self, weak recognizer, weak cell] position in
        guard let self else { return }
        guard position == .end, let recognizer, let cell else { return }
        guard
          self.previewHoldCell === cell,
          self.previewHoldIndexPath == indexPath,
          self.rows.indices.contains(indexPath.row),
          recognizer.state == .began || recognizer.state == .changed,
          self.presentedViewController == nil,
          self.tableView.panGestureRecognizer.state != .began,
          self.tableView.panGestureRecognizer.state != .changed
        else {
          self.cancelPreviewHold(animated: true)
          return
        }

        let currentPoint = recognizer.location(in: self.tableView)
        guard hypot(
          currentPoint.x - self.previewHoldOrigin.x,
          currentPoint.y - self.previewHoldOrigin.y
        ) <= 10 else {
          self.cancelPreviewHold(animated: true)
          return
        }

        self.previewHoldCommitted = true
        self.previewDepressAnimator = nil
        self.suppressSelectionUntil = CACurrentMediaTime() + 0.8
        let holdPointInWindow = self.tableView.convert(self.previewHoldOrigin, to: nil)
        self.previewDebugLog(
          "hold commit row=\(indexPath.row) point=\(NSCoder.string(for: holdPointInWindow))"
        )
        // Single haptic only: the soft engagement tick already fired on the hold
        // (~0.18s). Expansion is silent — a second medium impact here read as a
        // double buzz.
        self.presentMiniPreview(
          for: self.rows[indexPath.row],
          holdPointInWindow: holdPointInWindow,
          sourceCell: cell
        )
      }
      previewDepressAnimator = depress
      depress.startAnimation()

      // The moment the hold visibly engages, a soft tick confirms the grab
      // (the tap highlight was already suppressed at recognition). Cancelled
      // holds/taps never reach this.
      let engagement = DispatchWorkItem { [weak self, weak cell] in
        guard
          let self,
          let cell,
          self.previewHoldCell === cell,
          !self.previewHoldCommitted
        else { return }
        self.previewHoldEngagement = nil
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.7)
      }
      previewHoldEngagement = engagement
      // ~0.18s from touch-down (0.12 recognition + 0.06): even a slow tap has
      // lifted, and the highlight is long gone before the expansion snapshot.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: engagement)

      // Build + lay out the chat preview during the hold, on the next runloop
      // turn so the depress animation is already committed to the render
      // server before the heavy first layout briefly occupies the main thread.
      // It prewarms attached to the window (hidden, behind everything) so the
      // list materializes cells exactly like a real chat open — an offscreen
      // layout left the conversation unmounted/blank once presented.
      DispatchQueue.main.async { [weak self, weak cell] in
        guard
          let self,
          let cell,
          let window = cell.window ?? self.viewIfLoaded?.window,
          self.previewHoldCell === cell,
          !self.previewHoldCommitted,
          self.pendingPreviewController == nil
        else { return }
        let controller = ChatHomeMiniPreviewController(
          row: row,
          isDark: self.isDark,
          avatarGradientColors: self.resolvedAvatarGradientColors(for: row)
        )
        controller.prewarmLayout(
          targetSize: self.predictedPreviewCardSize(for: row),
          attachingTo: window
        )
        self.pendingPreviewController = controller
      }

    case .changed:
      guard !previewHoldCommitted, previewHoldCell != nil else { return }
      let moved = hypot(point.x - previewHoldOrigin.x, point.y - previewHoldOrigin.y)
      let tableIsPanning = tableView.panGestureRecognizer.state == .began
        || tableView.panGestureRecognizer.state == .changed
      if moved > 10 || tableIsPanning {
        cancelPreviewHold(animated: true)
      }

    case .ended, .cancelled, .failed:
      if previewHoldCommitted {
        previewDepressAnimator?.stopAnimation(true)
        previewDepressAnimator = nil
        previewHoldEngagement?.cancel()
        previewHoldEngagement = nil
        previewHoldCell = nil
        previewHoldIndexPath = nil
        previewHoldCommitted = false
      } else {
        cancelPreviewHold(animated: true)
      }

    default:
      break
    }
  }

  private func clearPendingPreview() {
    // The prewarm parks its view hidden inside the window; abandoning the hold
    // must also detach it or it would leak in the hierarchy.
    pendingPreviewController?.view.removeFromSuperview()
    pendingPreviewController = nil
  }

  private func cancelPreviewHold(animated: Bool) {
    // Stopping without finishing also kills a still-delayed depress, so a
    // released tap can never sink the card after the finger is already gone.
    previewDepressAnimator?.stopAnimation(true)
    previewDepressAnimator = nil
    previewHoldEngagement?.cancel()
    previewHoldEngagement = nil
    clearPendingPreview()
    guard let cell = previewHoldCell else {
      previewHoldIndexPath = nil
      previewHoldCommitted = false
      return
    }
    let originalTransform = previewHoldOriginalTransform
    previewDebugLog("hold cancel animated=\(animated ? "Y" : "N")")
    cell.setPressOverlaySuppressed(false, animated: false)
    previewHoldCell = nil
    previewHoldIndexPath = nil
    previewHoldCommitted = false

    let changes = {
      cell.transform = originalTransform
    }
    guard animated else {
      changes()
      return
    }
    UIView.animate(
      withDuration: 0.24,
      delay: 0,
      usingSpringWithDamping: 0.90,
      initialSpringVelocity: 0,
      options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut],
      animations: changes
    )
  }

  /// Same math the overlay resolves after presentation: full-window bounds and
  /// safe insets are known here already, so the prewarm size is exact.
  private func predictedPreviewCardSize(for row: ChatHomeListRow) -> CGSize {
    let host: UIView = viewIfLoaded?.window ?? tableView.window ?? view
    let menuHeight = ChatHomePreviewMetrics.menuHeight(
      rowCount: ChatHomePreviewMetrics.menuRowCount(for: row)
    )
    return ChatHomePreviewMetrics.cardSize(
      in: host.bounds,
      safeInsets: host.safeAreaInsets,
      menuHeight: menuHeight
    )
  }

  private func presentMiniPreview(
    for row: ChatHomeListRow,
    holdPointInWindow: CGPoint,
    sourceCell: ChatHomeCardCell
  ) {
    guard presentedViewController == nil else {
      cancelPreviewHold(animated: true)
      return
    }

    sourceCell.layoutIfNeeded()
    guard let sourceSnapshot = sourceCell.contentView.snapshotView(afterScreenUpdates: false) else {
      cancelPreviewHold(animated: true)
      return
    }
    let sourceFrameInWindow = sourceCell.contentView.convert(sourceCell.contentView.bounds, to: nil)
    previewDebugLog(
      "present source=\(NSCoder.string(for: sourceFrameInWindow)) hold=\(NSCoder.string(for: holdPointInWindow))"
    )
    sourceSnapshot.frame = sourceFrameInWindow
    sourceSnapshot.clipsToBounds = true
    sourceSnapshot.layer.cornerRadius = 22
    sourceSnapshot.layer.cornerCurve = .continuous

    // Prefer the controller prewarmed during the hold; its expensive first
    // layout is already done. Fall back to building one now (still prewarmed
    // synchronously) if the hold committed before the async build ran.
    let previewController: ChatHomeMiniPreviewController
    if let pending = pendingPreviewController, pending.chatId == row.chatId {
      previewController = pending
      pendingPreviewController = nil
    } else {
      clearPendingPreview()
      previewController = ChatHomeMiniPreviewController(
        row: row,
        isDark: isDark,
        avatarGradientColors: resolvedAvatarGradientColors(for: row)
      )
      previewController.prewarmLayout(
        targetSize: predictedPreviewCardSize(for: row),
        attachingTo: sourceCell.window ?? viewIfLoaded?.window
      )
    }
    previewHoldEngagement?.cancel()
    previewHoldEngagement = nil

    let originalTransform = previewHoldOriginalTransform
    let overlay = ChatHomeMiniPreviewOverlayController(
      row: row,
      isDark: isDark,
      sourceFrameInWindow: sourceFrameInWindow,
      holdPointInWindow: holdPointInWindow,
      sourceSnapshot: sourceSnapshot,
      previewController: previewController,
      sourceFrameProvider: { [weak sourceCell] in
        guard let sourceCell, sourceCell.window != nil else { return nil }
        return sourceCell.contentView.convert(sourceCell.contentView.bounds, to: nil)
      },
      onOpen: { [weak self] row in
        self?.onSelect(row)
      },
      onAction: { [weak self] action, row in
        self?.onAction(action, row)
      },
      onFirstFrame: { [weak sourceCell] in
        // The original row disappears only in the transaction that paints the
        // overlay's snapshot at the same spot. Hiding it at present() time left
        // a black hole in the list for the frames UIKit needs to actually
        // mount the presentation. The depress scale resets HERE, invisibly —
        // leaving it applied made the dismiss morph target a 0.95-scaled slot
        // and settled the row scaled-down under the landing card (bad
        // crossfade).
        sourceCell?.isHidden = true
        sourceCell?.transform = originalTransform
      },
      onDismiss: { [weak self] in
        guard let self else { return }
        self.activePreviewChatID = nil
        let sourceIndexPath = self.rows.firstIndex(where: { $0.chatId == row.chatId })
          .map { IndexPath(row: $0, section: 0) }
        let visibleSourceCell = sourceIndexPath.flatMap {
          self.tableView.cellForRow(at: $0) as? ChatHomeCardCell
        }
        for case let visibleCell as ChatHomeCardCell in self.tableView.visibleCells {
          visibleCell.isHidden = false
          visibleCell.setPressOverlaySuppressed(false, animated: false)
        }
        guard let visibleSourceCell else { return }
        // Scale was already reset invisibly at onFirstFrame; enforce identity
        // instantly for reused cells — an animated settle here left the row
        // still moving under the landing card (bad crossfade).
        visibleSourceCell.transform = originalTransform
      }
    )
    overlay.modalPresentationStyle = .overFullScreen
    overlay.modalPresentationCapturesStatusBarAppearance = true

    activePreviewChatID = row.chatId
    present(overlay, animated: false)
    previewHoldCell = nil
    previewHoldIndexPath = nil
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    rows.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    guard
      let cell = tableView.dequeueReusableCell(
        withIdentifier: ChatHomeCardCell.reuseIdentifier,
        for: indexPath
      ) as? ChatHomeCardCell
    else {
      return UITableViewCell()
    }

    let row = rows[indexPath.row]
    cell.swipeDelegate = nil
    cell.setManualSwipeActionsEnabled(false)
    cell.selectionStyle = .none
    cell.backgroundColor = .clear
    cell.contentView.backgroundColor = .clear
    cell.configure(
      row: row,
      isDark: isDark,
      avatarBackgroundColor: nil,
      avatarGradientColors: resolvedAvatarGradientColors(for: row),
      unreadBadgeColor: AppThemePalette.resolve(for: isDark ? .dark : .light).accentUIColor,
      isEditing: isEditingMode,
      isEditSelected: selectedChatIDs.contains(row.chatId),
      showsRightCheckmark: showsRightCheckmark,
      compactForwardStyle: compactForwardStyle
    )
    // Search pose lives on the TABLE (one dissolving surface), never on cells.
    cell.alpha = 1
    cell.transform = .identity
    cell.isHidden = row.chatId == activePreviewChatID
    return cell
  }

  func tableView(
    _ tableView: UITableView,
    willDisplay cell: UITableViewCell,
    forRowAt indexPath: IndexPath
  ) {
    guard let cell = cell as? ChatHomeCardCell, rows.indices.contains(indexPath.row) else {
      return
    }
    cell.isHidden = rows[indexPath.row].chatId == activePreviewChatID
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    guard rows.indices.contains(indexPath.row) else { return }
    if CACurrentMediaTime() < suppressSelectionUntil || presentedViewController != nil {
      tableView.deselectRow(at: indexPath, animated: false)
      return
    }
    openSwipeCell?.closeSwipe(animated: true)
    openSwipeCell = nil
    let row = rows[indexPath.row]
    AppUITrace.notice(
      "ChatHomeNativeListController didSelect row=\(indexPath.row) chatId=\(String(row.chatId.prefix(12))) title=\(row.title) editing=\(isEditingMode ? "Y" : "N") rows=\(rows.count)"
    )
    AppUIStallWatchdog.shared.updateContext(
      "ChatHomeNativeListController didSelect chatId=\(String(row.chatId.prefix(12))) row=\(indexPath.row)"
    )
    if let cell = tableView.cellForRow(at: indexPath) as? ChatHomeCardCell {
      cell.flashPressedFeedback()
    }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    if isEditingMode {
      let chatID = row.chatId
      onToggleSelection(chatID)
      if selectedChatIDs.contains(chatID) {
        selectedChatIDs.remove(chatID)
      } else {
        selectedChatIDs.insert(chatID)
      }
      tableView.reloadRows(at: [indexPath], with: .none)
      return
    }
    onSelect(row)
    tableView.deselectRow(at: indexPath, animated: true)
  }

  func tableView(
    _ tableView: UITableView,
    leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  ) -> UISwipeActionsConfiguration? {
    guard !isEditingMode, rows.indices.contains(indexPath.row) else { return nil }
    let row = rows[indexPath.row]
    guard row.supportsRemoteHomeActions else { return nil }

    let pin = UIContextualAction(
      style: .normal,
      title: row.pinned ? "Unpin" : "Pin"
    ) { [weak self] _, _, completion in
      self?.onAction(.pin(!row.pinned), row)
      completion(true)
    }
    pin.image = UIImage(systemName: row.pinned ? "pin.slash.fill" : "pin.fill")
    pin.backgroundColor = UIColor.systemBlue

    let hasUnread = row.hasUnreadState
    let unread = UIContextualAction(
      style: .normal,
      title: hasUnread ? "Read" : "Unread"
    ) { [weak self] _, _, completion in
      self?.onAction(.markUnread(!hasUnread), row)
      completion(true)
    }
    unread.image = UIImage(systemName: hasUnread ? "message.fill" : "circle.fill")
    unread.backgroundColor = UIColor.systemCyan

    let configuration = UISwipeActionsConfiguration(actions: [pin, unread])
    configuration.performsFirstActionWithFullSwipe = true
    return configuration
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    // Touch-down hold tracking must not delay the table's own pan. A real drag
    // cancels the pending hold in handlePreviewHold while scrolling continues.
    if gestureRecognizer === previewHoldRecognizer
      || otherGestureRecognizer === previewHoldRecognizer
    {
      return gestureRecognizer === tableView.panGestureRecognizer
        || otherGestureRecognizer === tableView.panGestureRecognizer
        || gestureRecognizer is UIPanGestureRecognizer
        || otherGestureRecognizer is UIPanGestureRecognizer
    }
    return false
  }

  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer === previewHoldRecognizer else { return true }
    guard
      !isEditingMode,
      !presentedSearchFocus,
      presentedViewController == nil
    else { return false }
    let point = gestureRecognizer.location(in: tableView)
    guard
      let indexPath = tableView.indexPathForRow(at: point),
      rows.indices.contains(indexPath.row)
    else { return false }
    return !rows[indexPath.row].isArchiveEntry
  }

  func tableView(
    _ tableView: UITableView,
    trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
  ) -> UISwipeActionsConfiguration? {
    guard !isEditingMode, rows.indices.contains(indexPath.row) else { return nil }
    let row = rows[indexPath.row]
    guard row.supportsRemoteHomeActions else { return nil }

    let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
      self?.onAction(.delete, row)
      completion(true)
    }
    delete.image = UIImage(systemName: "trash.fill")

    let archive = UIContextualAction(
      style: .normal,
      title: row.archived ? "Unarchive" : "Archive"
    ) { [weak self] _, _, completion in
      self?.onAction(.archive(!row.archived), row)
      completion(true)
    }
    archive.image = UIImage(systemName: row.archived ? "tray.and.arrow.up.fill" : "archivebox.fill")
    archive.backgroundColor = UIColor.systemGray

    let mute = UIContextualAction(
      style: .normal,
      title: row.muted ? "Unmute" : "Mute"
    ) { [weak self] _, _, completion in
      self?.onAction(.mute(!row.muted), row)
      completion(true)
    }
    mute.image = UIImage(systemName: row.muted ? "speaker.wave.2.fill" : "speaker.slash.fill")
    mute.backgroundColor = UIColor.systemOrange

    let configuration = UISwipeActionsConfiguration(actions: [delete, archive, mute])
    configuration.performsFirstActionWithFullSwipe = false
    return configuration
  }

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    hasUserDrivenHomeScroll = true
    AppUITrace.notice(
      "ChatHomeNativeListController scrollBegin rows=\(rows.count) offsetY=\(Int(scrollView.contentOffset.y))"
    )
    openSwipeCell?.closeSwipe(animated: true)
    openSwipeCell = nil
  }

  /// How far the header band has been scrolled past the top: 0 fully shown,
  /// `preferredHeight` fully tucked. Nil when there's no in-list header.
  private func searchHeaderScrolledPast(_ scrollView: UIScrollView) -> CGFloat? {
    guard showsInListSearch, searchHeader != nil else { return nil }
    return scrollView.contentOffset.y + scrollView.adjustedContentInset.top
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    // Collapse-on-scroll, native `.searchable` style: the pinned bar's HEIGHT
    // shrinks in place as the list scrolls up through the band, so the capsule
    // slides up and clips under the nav — it never moves away with the rows (it
    // is a sibling, not a tableHeaderView). Purely cosmetic: layoutSearchBar
    // only writes the bar's frame, never contentInset (which would re-derive
    // contentOffset mid-scroll and jump). Frozen during the morph.
    guard !isSearchMorphActive, !presentedSearchFocus else { return }
    layoutSearchBar()
  }

  func scrollViewWillEndDragging(
    _ scrollView: UIScrollView,
    withVelocity velocity: CGPoint,
    targetContentOffset: UnsafeMutablePointer<CGPoint>
  ) {
    // Page the search band: if the drag would come to rest with the header only
    // PARTLY collapsed, snap the target to fully-shown or fully-tucked (whichever
    // side, biased by fling direction) so the input never settles half-height —
    // the iOS search-bar collapse. Only the header band is paged; past it the
    // list scrolls freely.
    guard !isSearchMorphActive, !presentedSearchFocus,
      searchHeaderScrolledPast(scrollView) != nil
    else { return }
    let band = searchHeader?.preferredHeight ?? 56
    let restTop = -scrollView.adjustedContentInset.top
    let target = targetContentOffset.pointee.y
    let past = target - restTop
    guard past > 0, past < band else { return }  // only inside the band
    let openBias = velocity.y < -0.1  // flinging down → open
    let closeBias = velocity.y > 0.1  // flinging up → collapse
    let snapCollapsed: Bool
    if closeBias {
      snapCollapsed = true
    } else if openBias {
      snapCollapsed = false
    } else {
      snapCollapsed = past >= band / 2
    }
    targetContentOffset.pointee.y = restTop + (snapCollapsed ? band : 0)
  }

  func homeCardCellDidBeginSwipe(_ cell: ChatHomeCardCell) {
    if let indexPath = tableView.indexPath(for: cell), rows.indices.contains(indexPath.row) {
      AppUITrace.notice(
        "ChatHomeNativeListController swipeBegin row=\(indexPath.row) chatId=\(String(rows[indexPath.row].chatId.prefix(12)))"
      )
    } else {
      AppUITrace.notice("ChatHomeNativeListController swipeBegin row=unknown")
    }
    if openSwipeCell !== cell {
      openSwipeCell?.closeSwipe(animated: true)
    }
    openSwipeCell = cell
  }

  func homeCardCellDidCloseSwipe(_ cell: ChatHomeCardCell) {
    if openSwipeCell === cell {
      openSwipeCell = nil
    }
  }

  func homeCardCell(
    _ cell: ChatHomeCardCell,
    didTriggerSwipeEvent eventType: String,
    chatId: String
  ) {
    if openSwipeCell === cell {
      openSwipeCell = nil
    }
    AppUITrace.notice(
      "ChatHomeNativeListController swipeAction event=\(eventType) chatId=\(String(chatId.prefix(12)))"
    )
    guard let row = rows.first(where: { $0.chatId == chatId }) else {
      onUnavailableAction("Chat action is unavailable.")
      return
    }
    guard row.supportsRemoteHomeActions else {
      onUnavailableAction("This chat cannot be changed from Home.")
      return
    }

    switch eventType {
    case "swipeAgentSettings":
      onSettingsAction?(row)
    case "swipePin":
      onAction(.pin(!row.pinned), row)
    case "swipeMarkRead":
      onAction(.markUnread(!row.hasUnreadState), row)
    case "swipeMute":
      onAction(.mute(!row.muted), row)
    case "swipeArchive":
      onAction(.archive(!row.archived), row)
    case "swipeDelete":
      onAction(.delete, row)
    default:
      onUnavailableAction("Chat action is unavailable.")
    }
  }

  private func resolvedAvatarGradientColors(for row: ChatHomeListRow) -> (UIColor, UIColor)? {
    if !row.isSavedMessages && !row.isArchiveEntry {
      return ChatProfileAppearanceStore.avatarColors(
        title: row.title,
        peerUserId: row.peerUserId,
        chatId: row.chatId
      )
    }

    let startRaw = isDark ? row.avatarGradientStartDark : row.avatarGradientStartLight
    let endRaw = isDark ? row.avatarGradientEndDark : row.avatarGradientEndLight
    guard let startRaw, let endRaw else { return nil }
    guard let startColor = Self.parseHexColor(startRaw), let endColor = Self.parseHexColor(endRaw)
    else { return nil }
    return (startColor, endColor)
  }

  private static func parseHexColor(_ raw: String) -> UIColor? {
    var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") {
      hex.removeFirst()
    }
    guard hex.count == 6 || hex.count == 8 else { return nil }

    var value: UInt64 = 0
    guard Scanner(string: hex).scanHexInt64(&value) else { return nil }

    if hex.count == 6 {
      let r = CGFloat((value >> 16) & 0xFF) / 255.0
      let g = CGFloat((value >> 8) & 0xFF) / 255.0
      let b = CGFloat(value & 0xFF) / 255.0
      return UIColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    let r = CGFloat((value >> 24) & 0xFF) / 255.0
    let g = CGFloat((value >> 16) & 0xFF) / 255.0
    let b = CGFloat((value >> 8) & 0xFF) / 255.0
    let a = CGFloat(value & 0xFF) / 255.0
    return UIColor(red: r, green: g, blue: b, alpha: a)
  }
}

private final class ChatHomeDeletionWipeOverlayView: UIView {
  private let snapshotContainer = UIView()
  private let emitter = CAEmitterLayer()

  init(frame: CGRect, snapshot: UIView?, isDark: Bool) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    clipsToBounds = false
    layer.cornerCurve = .continuous

    snapshotContainer.frame = bounds
    snapshotContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(snapshotContainer)

    if let snapshot {
      snapshot.frame = snapshotContainer.bounds
      snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      snapshotContainer.addSubview(snapshot)
    }

    emitter.emitterPosition = CGPoint(x: bounds.width, y: bounds.midY)
    emitter.emitterSize = CGSize(width: 1, height: bounds.height)
    emitter.emitterShape = .line

    let cell = CAEmitterCell()
    cell.contents = createParticleImage(isDark: isDark)?.cgImage
    cell.birthRate = 6000
    cell.lifetime = 0.55
    cell.velocity = 500
    cell.velocityRange = 250
    cell.emissionLongitude = .pi // Point left
    cell.emissionRange = .pi / 6 // Slight spread
    cell.scale = 0.2
    cell.scaleRange = 0.1
    cell.scaleSpeed = -0.3
    cell.alphaSpeed = -1.5
    cell.yAcceleration = -400 // Go to top

    emitter.emitterCells = [cell]
    layer.addSublayer(emitter)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func animateAndRemove() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
      self.emitter.birthRate = 0
    }

    // Create a moving gradient mask so the cell image itself dissolves right-to-left
    let maskLayer = CAGradientLayer()
    maskLayer.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
    maskLayer.locations = [0.0, 0.05]
    maskLayer.startPoint = CGPoint(x: 1.0, y: 0.5) // Start right
    maskLayer.endPoint = CGPoint(x: 0.0, y: 0.5)   // End left
    maskLayer.frame = bounds
    snapshotContainer.layer.mask = maskLayer

    let duration: TimeInterval = 0.55

    let maskAnimation = CABasicAnimation(keyPath: "locations")
    maskAnimation.fromValue = [-0.1, 0.0]
    maskAnimation.toValue = [1.0, 1.1]
    maskAnimation.duration = duration * 0.8
    maskAnimation.fillMode = .forwards
    maskAnimation.isRemovedOnCompletion = false
    maskLayer.add(maskAnimation, forKey: "maskWipe")

    let moveEmitterAnimation = CABasicAnimation(keyPath: "emitterPosition.x")
    moveEmitterAnimation.fromValue = bounds.width
    moveEmitterAnimation.toValue = 0
    moveEmitterAnimation.duration = duration * 0.8
    moveEmitterAnimation.fillMode = .forwards
    moveEmitterAnimation.isRemovedOnCompletion = false
    emitter.add(moveEmitterAnimation, forKey: "moveEmitter")

    UIView.animate(withDuration: duration, delay: 0, options: .curveEaseOut, animations: {
      // Dissolves perfectly in place, no transform
    }) { _ in
      self.removeFromSuperview()
    }
  }

  private func createParticleImage(isDark: Bool) -> UIImage? {
    let size = CGSize(width: 1, height: 4) // Very thin slice
    UIGraphicsBeginImageContextWithOptions(size, false, 0)
    guard let context = UIGraphicsGetCurrentContext() else { return nil }
    context.setFillColor(isDark ? UIColor.white.withAlphaComponent(0.9).cgColor : UIColor.black.withAlphaComponent(0.9).cgColor)
    context.fill(CGRect(origin: .zero, size: size))
    let image = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return image
  }
}

private protocol ChatHomePreviewActionMenuViewDelegate: AnyObject {
  func homePreviewActionMenu(_ menu: ChatHomePreviewActionMenuView, didSelect action: ChatHomePreviewActionMenuView.Action)
}

/// One source of truth for the preview card + menu geometry so the hold-time
/// prewarm and the overlay's live layout can never disagree about sizes.
private enum ChatHomePreviewMetrics {
  // Small Telegram-style separation between the card's bottom edge and the menu.
  static let menuGap: CGFloat = 8
  static let menuRowHeight: CGFloat = 44
  static let menuVerticalPadding: CGFloat = 12

  // Mirrors ChatHomePreviewActionMenuView.actionItems(): four remote actions
  // (Mark read/unread, Pin, Mute, Delete) when the row supports them, else none.
  static func menuRowCount(for row: ChatHomeListRow) -> Int {
    row.supportsRemoteHomeActions ? 4 : 0
  }

  // The menu's height is deterministic (fixed-height rows inside fixed
  // padding). Measuring the glass wrapper via systemLayoutSizeFitting returns
  // a collapsed height — UIVisualEffectView's contentView is autoresized, not
  // constrained, so no height chain reaches the outer view — which is what
  // made the menu invisible and let the card grow nearly fullscreen.
  static func menuHeight(rowCount: Int) -> CGFloat {
    CGFloat(rowCount) * menuRowHeight + menuVerticalPadding
  }

  static func cardSize(in bounds: CGRect, safeInsets: UIEdgeInsets, menuHeight: CGFloat) -> CGSize {
    guard bounds.width > 1, bounds.height > 1 else { return .zero }
    let availableHeight = max(
      320,
      (bounds.height - safeInsets.bottom - 16) - (safeInsets.top + 12)
    )
    let width = min(max(300, bounds.width - 24), 560)
    let maxHeight = max(320, availableHeight - menuHeight - menuGap)
    let height = max(min(340, maxHeight), min(availableHeight * 0.56, maxHeight))
    return CGSize(width: width, height: height)
  }
}


private final class ChatHomeMiniPreviewOverlayController: UIViewController,
  UIGestureRecognizerDelegate, ChatHomePreviewActionMenuViewDelegate
{
  private struct PreviewLayout {
    let previewFrame: CGRect
    let menuFrame: CGRect
    let assemblyFrame: CGRect
    let menuAnchorX: CGFloat
  }

  private let backgroundGlassView: UIVisualEffectView
  private let colorOverlayView = UIView()
  private let previewGroupView = UIView()
  private let previewAssemblyView = UIView()
  private let previewContainerView = UIView()
  private let sourceSnapshot: UIView
  private let menuView: ChatHomePreviewActionMenuView
  private let previewController: ChatHomeMiniPreviewController
  private let row: ChatHomeListRow
  private let isDark: Bool
  private let sourceFrameInWindow: CGRect
  private let holdPointInWindow: CGPoint
  private let sourceFrameProvider: () -> CGRect?
  private let onOpen: (ChatHomeListRow) -> Void
  private let onAction: (ChatHomeRowAction, ChatHomeListRow) -> Void
  private let onFirstFrame: () -> Void
  private let onDismiss: () -> Void
  private var isClosing = false
  private var isTransitioning = false
  private var didAnimateIn = false
  private var presentationAnimator: UIViewPropertyAnimator?
  private var chromeFadeAnimator: UIViewPropertyAnimator?
  private var backdropFadeAnimator: UIViewPropertyAnimator?
  private var didFinishDismissal = false
  private var dismissStartedAt: CFTimeInterval?
  private var ignoreBackdropTapUntil: CFTimeInterval = 0

  init(
    row: ChatHomeListRow,
    isDark: Bool,
    sourceFrameInWindow: CGRect,
    holdPointInWindow: CGPoint,
    sourceSnapshot: UIView,
    previewController: ChatHomeMiniPreviewController,
    sourceFrameProvider: @escaping () -> CGRect?,
    onOpen: @escaping (ChatHomeListRow) -> Void,
    onAction: @escaping (ChatHomeRowAction, ChatHomeListRow) -> Void,
    onFirstFrame: @escaping () -> Void,
    onDismiss: @escaping () -> Void
  ) {
    self.row = row
    self.isDark = isDark
    self.sourceFrameInWindow = sourceFrameInWindow
    self.holdPointInWindow = holdPointInWindow
    self.sourceSnapshot = sourceSnapshot
    self.sourceFrameProvider = sourceFrameProvider
    self.onOpen = onOpen
    self.onAction = onAction
    self.onFirstFrame = onFirstFrame
    self.onDismiss = onDismiss
    self.backgroundGlassView = UIVisualEffectView(
      effect: UIBlurEffect(style: isDark ? .systemUltraThinMaterialDark : .systemUltraThinMaterialLight)
    )
    self.menuView = ChatHomePreviewActionMenuView(row: row, isDark: isDark)
    // Built and laid out during the hold (prewarm) so presentation has no
    // first-layout stall and the expansion can start on its first frame.
    self.previewController = previewController
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    isDark ? .lightContent : .darkContent
  }

  private func previewDebugLog(_ message: String) {
    NSLog("[ChatHomePreviewOverlay] t=%.3f %@", CACurrentMediaTime(), message)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear

    // Never animate a visual-effect view's alpha. The material remains fully
    // resolved while the source, preview, and menu animate above it.
    backgroundGlassView.frame = view.bounds
    backgroundGlassView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(backgroundGlassView)

    colorOverlayView.backgroundColor = UIColor.black
      .withAlphaComponent(isDark ? 0.55 : 0.42)
    colorOverlayView.frame = backgroundGlassView.contentView.bounds
    colorOverlayView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    backgroundGlassView.contentView.addSubview(colorOverlayView)

    previewGroupView.alpha = 1
    view.addSubview(previewGroupView)

    // Preview and menu are one transition surface. The assembly owns all
    // geometry so the menu cannot lag behind or visually detach from the card.
    previewAssemblyView.backgroundColor = .clear
    previewGroupView.addSubview(previewAssemblyView)

    previewContainerView.clipsToBounds = true
    previewContainerView.layer.cornerRadius = 22
    previewContainerView.layer.cornerCurve = .continuous
    previewContainerView.backgroundColor = isDark ? UIColor(white: 0.07, alpha: 1) : .white
    previewAssemblyView.addSubview(previewContainerView)

    addChild(previewController)
    // The conversation keeps its prewarmed final-size layout — never resized:
    // the container's animating bounds clip-reveal it. Re-framing it here (or
    // scaling it with the container) is what squashed the content mid-flight
    // and redid the expensive first layout during presentation.
    previewContainerView.addSubview(previewController.view)
    // The prewarm parked this view hidden inside the app window; it is the
    // card's real content now.
    previewController.view.isHidden = false
    previewController.didMove(toParent: self)

    // The selected row is the preview's first content state, not a second
    // floating sibling above it. It stays at its natural row size pinned to the
    // container top and only fades — stretching it over the grown card is what
    // smeared the avatar/title across the conversation.
    sourceSnapshot.clipsToBounds = true
    sourceSnapshot.layer.cornerRadius = 22
    sourceSnapshot.layer.cornerCurve = .continuous
    previewContainerView.addSubview(sourceSnapshot)

    menuView.delegate = self
    menuView.alpha = 1
    menuView.isUserInteractionEnabled = false
    previewAssemblyView.addSubview(menuView)

    let tapRecognizer = UITapGestureRecognizer(target: self, action: #selector(handleBackdropTap(_:)))
    tapRecognizer.delegate = self
    tapRecognizer.cancelsTouchesInView = false
    tapRecognizer.delaysTouchesBegan = false
    tapRecognizer.delaysTouchesEnded = false
    view.addGestureRecognizer(tapRecognizer)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    guard !isClosing, !isTransitioning else { return }
    backgroundGlassView.frame = view.bounds
    colorOverlayView.frame = backgroundGlassView.contentView.bounds
    previewGroupView.frame = view.bounds

    let layout = resolvedPreviewLayout()
    guard layout.previewFrame.width > 1, layout.previewFrame.height > 1 else { return }
    previewAssemblyView.transform = .identity
    previewAssemblyView.frame = layout.assemblyFrame

    let finalContainerFrame = CGRect(
      x: layout.previewFrame.minX - layout.assemblyFrame.minX,
      y: layout.previewFrame.minY - layout.assemblyFrame.minY,
      width: layout.previewFrame.width,
      height: layout.previewFrame.height
    )
    previewController.view.frame = CGRect(origin: .zero, size: layout.previewFrame.size)

    menuView.layer.anchorPoint = CGPoint(x: layout.menuAnchorX, y: 0)
    menuView.bounds = CGRect(origin: .zero, size: layout.menuFrame.size)
    let menuFinalPosition = CGPoint(
      x: layout.menuFrame.minX - layout.assemblyFrame.minX
        + layout.menuFrame.width * layout.menuAnchorX,
      y: layout.menuFrame.minY - layout.assemblyFrame.minY
    )

    if didAnimateIn {
      previewContainerView.frame = finalContainerFrame
      menuView.transform = .identity
      menuView.alpha = 1
      menuView.layer.position = menuFinalPosition
      sourceSnapshot.alpha = 0
      previewController.view.alpha = 1
    } else {
      let sourceFrame = sourceFrameInView
      let collapsedContainerFrame = CGRect(
        x: sourceFrame.minX - layout.assemblyFrame.minX,
        y: sourceFrame.minY - layout.assemblyFrame.minY,
        width: sourceFrame.width,
        height: sourceFrame.height
      )
      previewContainerView.frame = collapsedContainerFrame
      sourceSnapshot.frame = CGRect(origin: .zero, size: sourceFrame.size)
      sourceSnapshot.alpha = 1
      previewController.view.alpha = 0
      // The menu is attached below the card's bottom edge from frame one and
      // rides the same spring, so it can never pop in late or detach.
      menuView.transform = CGAffineTransform(scaleX: 0.55, y: 0.55)
      menuView.alpha = 0
      menuView.layer.position = CGPoint(
        x: menuFinalPosition.x,
        y: collapsedContainerFrame.maxY + ChatHomePreviewMetrics.menuGap
      )
    }
    if !didAnimateIn {
      // First real frame: the source row hands off to the snapshot in this
      // same transaction (never a black hole in the list), the conversation
      // rests on its latest message, and the expansion starts immediately —
      // no intermediate "floating card over blur" frame is ever rendered.
      onFirstFrame()
      previewController.snapToLatest()
      animateIn()
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    animateIn()
  }

  private var sourceFrameInView: CGRect {
    view.convert(sourceFrameProvider() ?? sourceFrameInWindow, from: nil)
  }

  private var holdPointInView: CGPoint {
    view.convert(holdPointInWindow, from: nil)
  }

  private func resolvedPreviewLayout() -> PreviewLayout {
    let bounds = view.bounds
    guard bounds.width > 1, bounds.height > 1 else {
      return PreviewLayout(
        previewFrame: .zero,
        menuFrame: .zero,
        assemblyFrame: .zero,
        menuAnchorX: 0.5
      )
    }

    let safeTop = view.safeAreaInsets.top + 12
    let safeBottom = bounds.height - view.safeAreaInsets.bottom - 16
    let safeLeft: CGFloat = 12
    let safeRight = bounds.width - 12

    let menuWidth = min(max(204, bounds.width * 0.50), min(226, bounds.width - 44))
    let menuHeight = ChatHomePreviewMetrics.menuHeight(rowCount: menuView.rowCount)

    // A floating card, not an almost-fullscreen sheet: the height is capped so
    // the menu always fits below it and the group keeps clear margins all
    // around instead of leaving sliver borders at the screen edges.
    let cardSize = ChatHomePreviewMetrics.cardSize(
      in: bounds,
      safeInsets: view.safeAreaInsets,
      menuHeight: menuHeight
    )
    let previewWidth = cardSize.width
    let previewHeight = cardSize.height
    let groupHeight = previewHeight + ChatHomePreviewMetrics.menuGap + menuHeight
    let sourceFrame = sourceFrameInView
    let holdPoint = holdPointInView
    let desiredGroupY = sourceFrame.midY - groupHeight * 0.24
    let groupY = max(safeTop, min(safeBottom - groupHeight, desiredGroupY))
    let previewX = max(safeLeft, min(safeRight - previewWidth, (bounds.width - previewWidth) * 0.5))
    let previewFrame = CGRect(x: previewX, y: groupY, width: previewWidth, height: previewHeight)

    // ONE fixed position, Telegram-style: the menu hangs from the card's RIGHT
    // edge (never under the finger — that slid it right/center per grab). The
    // card is always centered, so right-aligning to it is deterministic.
    let menuX = max(safeLeft, min(safeRight - menuWidth, previewFrame.maxX - menuWidth))
    let menuFrame = CGRect(
      x: menuX,
      y: previewFrame.maxY + ChatHomePreviewMetrics.menuGap,
      width: menuWidth,
      height: menuHeight
    )
    // Grows from the top-right corner to match the right-aligned position.
    let menuAnchorX: CGFloat = 0.85
    let assemblyFrame = previewFrame.union(menuFrame)

    return PreviewLayout(
      previewFrame: previewFrame,
      menuFrame: menuFrame,
      assemblyFrame: assemblyFrame,
      menuAnchorX: menuAnchorX
    )
  }

  private func animateIn() {
    guard !didAnimateIn else { return }
    view.layoutIfNeeded()
    let layout = resolvedPreviewLayout()
    guard layout.previewFrame.width > 1, layout.previewFrame.height > 1 else { return }
    didAnimateIn = true
    isTransitioning = true

    ignoreBackdropTapUntil = CACurrentMediaTime() + 0.36
    previewContainerView.isUserInteractionEnabled = false
    menuView.isUserInteractionEnabled = false

    let finalContainerFrame = CGRect(
      x: layout.previewFrame.minX - layout.assemblyFrame.minX,
      y: layout.previewFrame.minY - layout.assemblyFrame.minY,
      width: layout.previewFrame.width,
      height: layout.previewFrame.height
    )
    let menuFinalPosition = CGPoint(
      x: layout.menuFrame.minX - layout.assemblyFrame.minX
        + layout.menuFrame.width * layout.menuAnchorX,
      y: layout.menuFrame.minY - layout.assemblyFrame.minY
    )
    previewDebugLog(
      "open start source=\(NSCoder.string(for: sourceFrameInView)) hold=\(NSCoder.string(for: holdPointInView)) assembly=\(NSCoder.string(for: layout.assemblyFrame)) preview=\(NSCoder.string(for: layout.previewFrame)) menu=\(NSCoder.string(for: layout.menuFrame)) progress=0.000"
    )

    // Animation blocks capture the views directly, never self: an animator's
    // stored block retaining the overlay kept dismissed previews (and their
    // live ChatMainViews) alive, re-rendering agent cells forever.
    let snapshot = sourceSnapshot
    let container = previewContainerView
    let content: UIView = previewController.view
    let menu = menuView

    // The row chrome leaves first: a fast fade at natural size, gone before the
    // expansion visually takes over, so avatar/title never ride the grown card.
    let chromeAnimator = UIViewPropertyAnimator(duration: 0.10, curve: .easeOut) {
      snapshot.alpha = 0
    }
    // One spring drives the card's clip-reveal and the menu pinned to its
    // bottom edge; both interpolate on the same clock so the menu stays
    // attached the entire flight instead of popping in at the end.
    let animator = UIViewPropertyAnimator(duration: 0.28, dampingRatio: 0.88) {
      container.frame = finalContainerFrame
      content.alpha = 1
      menu.transform = .identity
      menu.alpha = 1
      menu.layer.position = menuFinalPosition
    }
    animator.addCompletion { [weak self] position in
      guard let self else { return }
      guard !self.isClosing else { return }
      self.isTransitioning = false
      self.previewContainerView.isUserInteractionEnabled = true
      self.menuView.isUserInteractionEnabled = true
      // Belt and braces: the conversation must rest on its latest message with
      // no dead space, even if rows arrived while the card was in flight.
      self.previewController.snapToLatest()
      self.previewDebugLog(
        "open finish position=\(String(describing: position)) progress=1.000"
      )
    }
    presentationAnimator = animator
    chromeFadeAnimator = chromeAnimator
    chromeAnimator.startAnimation()
    animator.startAnimation()
  }

  @objc private func handleBackdropTap(_ recognizer: UITapGestureRecognizer) {
    guard CACurrentMediaTime() >= ignoreBackdropTapUntil else { return }
    close(reason: "backdrop")
  }

  func homePreviewActionMenu(
    _ menu: ChatHomePreviewActionMenuView,
    didSelect action: ChatHomePreviewActionMenuView.Action
  ) {
    switch action {
    case .open:
      close(reason: "action.open", after: { [row, onOpen] in onOpen(row) })
    case .markUnread:
      close(reason: "action.unread", after: { [row, onAction] in onAction(.markUnread(!row.hasUnreadState), row) })
    case .pin:
      close(reason: "action.pin", after: { [row, onAction] in onAction(.pin(!row.pinned), row) })
    case .mute:
      close(reason: "action.mute", after: { [row, onAction] in onAction(.mute(!row.muted), row) })
    case .archive:
      close(reason: "action.archive", after: { [row, onAction] in onAction(.archive(!row.archived), row) })
    case .delete:
      close(reason: "action.delete", after: { [row, onAction] in onAction(.delete, row) })
    }
  }

  private func close(reason: String, after action: (() -> Void)? = nil) {
    guard !isClosing else { return }
    isClosing = true
    isTransitioning = true
    dismissStartedAt = CACurrentMediaTime()
    menuView.isUserInteractionEnabled = false
    previewDebugLog("dismiss start reason=\(reason)")

    for running in [presentationAnimator, chromeFadeAnimator] {
      if let running, running.state == .active {
        running.stopAnimation(false)
        running.finishAnimation(at: .current)
      }
    }

    let targetSourceFrame = sourceFrameInView
    let assemblyFrame = previewAssemblyView.frame
    let collapsedContainerFrame = CGRect(
      x: targetSourceFrame.minX - assemblyFrame.minX,
      y: targetSourceFrame.minY - assemblyFrame.minY,
      width: targetSourceFrame.width,
      height: targetSourceFrame.height
    )
    let menuCollapsedPosition = CGPoint(
      x: menuView.layer.position.x,
      y: collapsedContainerFrame.maxY + ChatHomePreviewMetrics.menuGap
    )
    sourceSnapshot.frame = CGRect(origin: .zero, size: targetSourceFrame.size)
    previewDebugLog(
      "dismiss geometry assembly=\(NSCoder.string(for: assemblyFrame)) target=\(NSCoder.string(for: targetSourceFrame)) progress=1.000→0.000"
    )

    // Dismiss is the exact inverse: the card clip-collapses onto the source row
    // with the menu riding its bottom edge, and the row chrome only returns at
    // the very end, once the card is nearly row-sized again. Blocks capture the
    // views, never self (see animateIn — retained blocks leaked the overlay).
    let snapshot = sourceSnapshot
    let container = previewContainerView
    let content: UIView = previewController.view
    let menu = menuView
    let animator = UIViewPropertyAnimator(duration: 0.14, curve: .easeIn) {
      container.frame = collapsedContainerFrame
      content.alpha = 0
      menu.transform = CGAffineTransform(scaleX: 0.45, y: 0.45)
      menu.alpha = 0
      menu.layer.position = menuCollapsedPosition
    }
    let chromeAnimator = UIViewPropertyAnimator(duration: 0.08, curve: .easeIn) {
      snapshot.alpha = 1
    }
    // Backdrop rides the collapse OUT: blur radius → 0 (animating the effect,
    // never a visual-effect view's alpha) + tint → clear. It used to stay
    // fully dimmed for the whole collapse and pop off at the end — the slow,
    // abrupt-feeling dismissal.
    let glass = backgroundGlassView
    let tint = colorOverlayView
    let backdropAnimator = UIViewPropertyAnimator(duration: 0.14, curve: .easeIn) {
      glass.effect = nil
      tint.alpha = 0
    }
    animator.addCompletion { [weak self] position in
      guard let self else { return }
      self.previewDebugLog(
        "dismiss animator finish position=\(String(describing: position)) progress=0.000"
      )
      self.menuView.removeFromSuperview()
      self.finishDismissal(action: action)
    }
    presentationAnimator = animator
    chromeFadeAnimator = chromeAnimator
    backdropFadeAnimator = backdropAnimator
    animator.startAnimation()
    backdropAnimator.startAnimation()
    chromeAnimator.startAnimation(afterDelay: 0.06)
  }

  private func finishDismissal(action: (() -> Void)?) {
    guard !didFinishDismissal else { return }
    didFinishDismissal = true
    // Drop the animators so no stored animation state can outlive dismissal —
    // a retained overlay means a retained live ChatMainView burning CPU.
    presentationAnimator = nil
    chromeFadeAnimator = nil
    backdropFadeAnimator = nil
    let elapsed = dismissStartedAt.map { CACurrentMediaTime() - $0 } ?? 0
    previewDebugLog("dismiss finish elapsed=\(String(format: "%.3f", elapsed))")
    onDismiss()
    dismiss(animated: false, completion: action)
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch)
    -> Bool
  {
    guard CACurrentMediaTime() >= ignoreBackdropTapUntil else { return false }
    let point = touch.location(in: view)
    if previewContainerView.convert(previewContainerView.bounds, to: view).contains(point) { return false }
    if menuView.convert(menuView.bounds, to: view).contains(point) { return false }
    return true
  }

  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard CACurrentMediaTime() >= ignoreBackdropTapUntil else { return false }
    let point = gestureRecognizer.location(in: view)
    if previewContainerView.convert(previewContainerView.bounds, to: view).contains(point) { return false }
    if menuView.convert(menuView.bounds, to: view).contains(point) { return false }
    return true
  }
}

private final class ChatHomePreviewActionMenuView: UIView {
  enum Action: String {
    case open
    case markUnread
    case pin
    case mute
    case archive
    case delete
  }

  weak var delegate: ChatHomePreviewActionMenuViewDelegate?

  private let glassView: UIVisualEffectView
  private let stackView = UIStackView()
  private let row: ChatHomeListRow
  private let isDark: Bool

  var rowCount: Int { stackView.arrangedSubviews.count }

  init(row: ChatHomeListRow, isDark: Bool) {
    self.row = row
    self.isDark = isDark
    // Use the exact liquid-glass construction as the working message-cell menu.
    // Keep Home borderless so the attached edge reads as one continuous surface.
    self.glassView = makeChatContextLiquidGlassView(
      style: isDark ? .systemMaterialDark : .systemMaterial,
      cornerRadius: 24,
      capsuleCorners: false,
      interactive: false
    )
    super.init(frame: .zero)
    setup()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setup() {
    clipsToBounds = false
    glassView.translatesAutoresizingMaskIntoConstraints = false
    // Material and corner shape provide the edge; an explicit outline makes the
    // attached menu read as a separate popover.
    glassView.layer.borderWidth = 0
    addSubview(glassView)

    stackView.axis = .vertical
    stackView.spacing = 0
    stackView.translatesAutoresizingMaskIntoConstraints = false
    glassView.contentView.addSubview(stackView)

    NSLayoutConstraint.activate([
      glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
      glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
      glassView.topAnchor.constraint(equalTo: topAnchor),
      glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
      stackView.leadingAnchor.constraint(equalTo: glassView.contentView.leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: glassView.contentView.trailingAnchor),
      stackView.topAnchor.constraint(equalTo: glassView.contentView.topAnchor, constant: 6),
      stackView.bottomAnchor.constraint(equalTo: glassView.contentView.bottomAnchor, constant: -6),
    ])

    let actions = actionItems()
    for item in actions {
      let rowView = ChatHomePreviewActionRow(item: item, isDark: isDark)
      rowView.addTarget(self, action: #selector(handleRowTap(_:)), for: .touchUpInside)
      stackView.addArrangedSubview(rowView)
    }
  }

  private func actionItems() -> [ChatHomePreviewActionRow.Item] {
    // Four Telegram-style rows: Mark as Read/Unread, Pin/Unpin, Mute/Unmute,
    // Delete. "Open Chat" and "Archive" were dropped — tapping the card already
    // opens it, and archive lives on the swipe action.
    guard row.supportsRemoteHomeActions else { return [] }
    let hasUnread = row.hasUnreadState
    return [
      .init(
        action: .markUnread,
        title: hasUnread ? "Mark as Read" : "Mark as Unread",
        iconName: hasUnread ? "envelope.open.fill" : "envelope.badge.fill",
        isDestructive: false
      ),
      .init(
        action: .pin,
        title: row.pinned ? "Unpin" : "Pin",
        iconName: row.pinned ? "pin.slash.fill" : "pin.fill",
        isDestructive: false
      ),
      .init(
        action: .mute,
        title: row.muted ? "Unmute" : "Mute",
        iconName: row.muted ? "speaker.wave.2.fill" : "speaker.slash.fill",
        isDestructive: false
      ),
      .init(action: .delete, title: "Delete", iconName: "trash.fill", isDestructive: true),
    ]
  }

  @objc private func handleRowTap(_ sender: ChatHomePreviewActionRow) {
    delegate?.homePreviewActionMenu(self, didSelect: sender.item.action)
  }
}

private final class ChatHomePreviewActionRow: UIControl {
  struct Item {
    let action: ChatHomePreviewActionMenuView.Action
    let title: String
    let iconName: String
    let isDestructive: Bool
  }

  let item: Item
  private let iconView = UIImageView()
  private let titleLabel = UILabel()

  init(item: Item, isDark: Bool) {
    self.item = item
    super.init(frame: .zero)
    backgroundColor = .clear

    let textColor: UIColor = item.isDestructive ? .systemRed : (isDark ? .white : .label)
    iconView.image = UIImage(
      systemName: item.iconName,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
    )
    iconView.tintColor = textColor
    iconView.contentMode = .scaleAspectFit
    iconView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(iconView)

    titleLabel.text = item.title
    titleLabel.font = .systemFont(ofSize: 17, weight: .regular)
    titleLabel.textColor = textColor
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(titleLabel)

    let height = heightAnchor.constraint(equalToConstant: 44)
    height.priority = .defaultHigh
    NSLayoutConstraint.activate([
      height,
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 22),
      iconView.heightAnchor.constraint(equalToConstant: 22),
      titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
      titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: 0.10) {
        self.backgroundColor = self.isHighlighted ? UIColor.label.withAlphaComponent(0.08) : .clear
      }
    }
  }
}

private final class ChatHomeMiniPreviewController: UIViewController {
  private let backdropView: UIVisualEffectView
  private let mainView = ChatMainView()
  private let row: ChatHomeListRow
  private let isDark: Bool
  private var didInitialScrollToBottom = false
  private var openedChatChannel = false
  private var pendingEngineRefresh: DispatchWorkItem?

  var chatId: String { row.chatId }

  private static func hexString(from color: UIColor) -> String {
    var r: CGFloat = 0
    var g: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    return String(
      format: "#%02X%02X%02X",
      Int(round(max(0, min(1, r)) * 255)),
      Int(round(max(0, min(1, g)) * 255)),
      Int(round(max(0, min(1, b)) * 255))
    )
  }

  /// Runs the expensive ChatMainView first layout during the hold, before the
  /// overlay is presented, and rests the list on its latest message. The size
  /// comes from the same metrics the overlay uses, so presentation only
  /// confirms frames instead of doing layout work. The view is parked hidden
  /// at the back of the window: the list only materializes cells like a real
  /// chat open when it is window-attached — a detached layout came up blank.
  func prewarmLayout(targetSize: CGSize, attachingTo window: UIWindow?) {
    guard targetSize.width > 1, targetSize.height > 1 else { return }
    view.frame = CGRect(origin: .zero, size: targetSize)
    if let window, view.window == nil {
      view.isHidden = true
      window.insertSubview(view, at: 0)
    }
    // Second parking site: a full-screen chat parked in the WINDOW, not the nav container.
    // `isHidden` is only set on the attach branch, so an already-attached view stays visible.
    flashProbeLog(
      "preview-prewarm parked hidden=\(view.isHidden ? "Y" : "N") "
        + "inWindow=\(view.window == nil ? "N" : "Y") frame=\(NSCoder.string(for: view.frame))")
    view.layoutIfNeeded()
    mainView.layoutIfNeeded()
    mainView.scrollToBottom(animated: false)
  }

  func snapToLatest() {
    mainView.scrollToBottom(animated: false)
  }

  init(row: ChatHomeListRow, isDark: Bool, avatarGradientColors: (UIColor, UIColor)? = nil) {
    self.row = row
    self.isDark = isDark
    let blurStyle: UIBlurEffect.Style = isDark ? .systemUltraThinMaterialDark : .systemUltraThinMaterialLight
    self.backdropView = UIVisualEffectView(effect: UIBlurEffect(style: blurStyle))
    super.init(nibName: nil, bundle: nil)

    view.backgroundColor = .clear
    view.clipsToBounds = true
    // A VC root view autoresizes with its superview by DEFAULT. Inside the
    // overlay the container's bounds are spring-animated for the clip-reveal;
    // without clearing this, the whole conversation (collection view included)
    // was resized along the spring — the "inner content scales" bug and the
    // UICollectionViewFlowLayout invalid-size warnings.
    view.autoresizingMask = []

    backdropView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(backdropView)
    mainView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(mainView)
    NSLayoutConstraint.activate([
      backdropView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      backdropView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      backdropView.topAnchor.constraint(equalTo: view.topAnchor),
      backdropView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      mainView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      mainView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      mainView.topAnchor.constraint(equalTo: view.topAnchor),
      mainView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    backdropView.layer.cornerRadius = 22
    view.layer.cornerRadius = 22
    mainView.layer.cornerRadius = 22
    if #available(iOS 13.0, *) {
      backdropView.layer.cornerCurve = .continuous
      view.layer.cornerCurve = .continuous
      mainView.layer.cornerCurve = .continuous
    }
    backdropView.clipsToBounds = true
    mainView.clipsToBounds = true
    mainView.setExternalNavigationHeaderEnabled(false)
    mainView.setPreviewHeaderCenterOnly(false)
    mainView.setPreviewHeaderCompactLeading(true)
    // The preview only ever shows the resting tail. Its narrower width misses
    // every cached transcript height, so the progressive warmup would re-measure
    // the whole conversation on the main thread (~30s of churn per hold) right
    // under the open/dismiss springs — for heights nobody will ever see.
    mainView.setProgressiveHeightWarmupSuppressed(true)
    // Reuse the real chat's cached heights at the narrow card width instead of
    // re-measuring the visible tail on the main thread during every hold.
    mainView.setEphemeralPreviewMode(true)
    mainView.setAppearance(Self.previewAppearance(isDark: isDark))
    mainView.surfaceId = "home_preview_\(row.chatId)"
    mainView.setEngineSurfaceId(mainView.surfaceId)
    mainView.setEngineChatId(row.chatId)
    mainView.setEnginePeerUserId(row.peerUserId ?? "")
    if let myUserId = Self.normalizedString(
      ChatEngineStore.shared.getConfig()["myUserId"] ?? ChatEngineStore.shared.getConfig()["userId"]
    ) {
      mainView.setEngineMyUserId(myUserId)
    }
    if row.isSavedMessages {
      // Saved Messages uses the bookmark avatar; without the mode the preview
      // header showed a bare initials tile (or nothing at all).
      mainView.setHeaderMode("savedmessages")
    }
    mainView.setHeaderTitle(row.title)
    mainView.setHeaderSubtitle(Self.headerSubtitle(for: row))
    mainView.setProfileName(row.title)
    mainView.setProfileHandle(Self.profileHandle(for: row))
    mainView.setAvatarUri(row.avatarUri)
    if let avatarGradientColors {
      // The card's header avatar must be the exact fallback the home row
      // showed (home resolves via ChatProfileAppearanceStore, not the row's
      // stored hex gradient) — otherwise the morph visibly recolors it.
      let start = Self.hexString(from: avatarGradientColors.0)
      let end = Self.hexString(from: avatarGradientColors.1)
      mainView.setAvatarGradientColors(
        startLight: start, endLight: end, startDark: start, endDark: end)
    } else {
      mainView.setAvatarGradientColors(
        startLight: row.avatarGradientStartLight,
        endLight: row.avatarGradientEndLight,
        startDark: row.avatarGradientStartDark,
        endDark: row.avatarGradientEndDark
      )
    }
    mainView.setIsOnline(Self.isOnline(for: row))
    mainView.setIsChatMuted(row.muted)
    mainView.setGroupMembers(row.members)
    mainView.setIsGroupOrChannel(row.isGroup || row.isChannel)
    mainView.setIsChannel(row.isChannel)
    mainView.setChannelShareLink(row.shareLink ?? "")
    mainView.setStatusAuthorityEnabled(true)
    mainView.setInputBarEnabled(false)
    mainView.isUserInteractionEnabled = true
    mainView.setNativeSendEnabled(false)
    mainView.setPage(ChatConversationPage.chat.rawValue, animated: false)
    refreshPreviewRows()

    preferredContentSize = Self.preferredContentSize()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleChatEngineChanged(_:)),
      name: ChatEngine.didChangeNotification,
      object: nil
    )

    if row.supportsRemoteHomeActions {
      openedChatChannel = true
      // Off the main thread, for the same reason `ChatConversationController` already
      // does this on a background queue: `openChatChannel` ends in `syncOnQueue`, so
      // calling it here made a long-press wait on the engine's serial queue while it was
      // busy. Device export 2026-08-08T08:10:54 caught it at 0.81s, blocking the very
      // gesture that is meant to feel instant — the preview is a read-only surface and
      // nothing in this initializer depends on the channel being open yet.
      let chatId = row.chatId
      let peerUserId = row.peerUserId ?? ""
      DispatchQueue.global(qos: .userInitiated).async {
        _ = ChatEngine.shared.openChatChannel([
          "chatId": chatId,
          "peerUserId": peerUserId,
        ])
      }
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    pendingEngineRefresh?.cancel()
    NotificationCenter.default.removeObserver(
      self,
      name: ChatEngine.didChangeNotification,
      object: nil
    )
    if openedChatChannel {
      _ = ChatEngine.shared.closeChatChannel(["chatId": row.chatId])
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    view.layoutIfNeeded()
    mainView.layoutIfNeeded()
    configurePreviewScrollBehavior()
  }

  private func refreshPreviewRows() {
    mainView.setRows(Self.previewRows(for: row))
    guard !didInitialScrollToBottom else { return }
    didInitialScrollToBottom = true
    DispatchQueue.main.async { [weak self] in
      self?.mainView.scrollToBottom(animated: false)
    }
  }

  private func configurePreviewScrollBehavior() {
    for scrollView in Self.collectScrollViews(in: mainView) {
      scrollView.isScrollEnabled = true
      scrollView.isDirectionalLockEnabled = true
      scrollView.bounces = false
      scrollView.alwaysBounceVertical = false
      scrollView.alwaysBounceHorizontal = false
      scrollView.panGestureRecognizer.cancelsTouchesInView = true
      scrollView.delaysContentTouches = false
      scrollView.canCancelContentTouches = true
    }
  }

  @objc private func handleChatEngineChanged(_ note: Notification) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.handleChatEngineChanged(note)
      }
      return
    }
    guard
      let changedChatId = Self.normalizedString(note.userInfo?["chatId"]),
      changedChatId == row.chatId
    else { return }

    let reason = Self.normalizedString(note.userInfo?["reason"]) ?? ""
    switch reason {
    case "peerTyping", "presenceChanged":
      mainView.setHeaderSubtitle(Self.headerSubtitle(for: row))
      mainView.setIsOnline(Self.isOnline(for: row))
      mainView.setProfileHandle(Self.profileHandle(for: row))
    case "chatRowsReloaded", "chatMessageInserted", "chatMessageEdited", "chatMessageDeleted",
      "chatMessageChanged", "chatMessageReactionChanged", "messageStatusChanged":
      scheduleEngineRowsRefresh()
    default:
      break
    }
  }

  /// Live chats (group agent streams) fire engine changes in bursts; a full
  /// setRows per event re-parses/re-measures agent cells and janks the open
  /// animation. Coalesce refreshes, and never re-render a detached preview.
  private func scheduleEngineRowsRefresh() {
    guard pendingEngineRefresh == nil else { return }
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.pendingEngineRefresh = nil
      guard self.viewIfLoaded?.window != nil else { return }
      self.refreshPreviewRows()
    }
    pendingEngineRefresh = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
  }

  private static func preferredContentSize() -> CGSize {
    let screen = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }
      .first ?? CGSize(width: 390, height: 844)
    let width = max(320, min(screen.width - 10, 560))
    let maxHeight = max(420, screen.height - 190)
    let height = min(maxHeight, screen.height * 0.72)
    return CGSize(width: width, height: height)
  }

  private static func previewRows(for row: ChatHomeListRow) -> [[String: Any]] {
    let engineRows = ChatEngine.shared.getChatRows(["chatId": row.chatId])
    if !engineRows.isEmpty {
      return engineRows
    }
    if !row.previewRows.isEmpty {
      return row.previewRows
    }
    if !row.initialMessages.isEmpty {
      return row.initialMessages
    }
    return fallbackPreviewRows(for: row)
  }

  private static func fallbackPreviewRows(for row: ChatHomeListRow) -> [[String: Any]] {
    let previewText =
      row.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "Start a conversation"
      : row.preview
    let messageId = "preview_message_\(row.chatId)"
    let message: [String: Any] = [
      "id": messageId,
      "text": previewText,
      "timestamp": row.timeLabel,
      "isMe": false,
      "status": "sent",
      "type": "text",
      "isPinned": row.pinned,
      "bubbleShape": [
        "showTail": true,
        "borderTopLeftRadius": 18.0,
        "borderTopRightRadius": 18.0,
        "borderBottomLeftRadius": 4.0,
        "borderBottomRightRadius": 18.0,
      ],
    ]
    return [
      [
        "kind": "message",
        "key": messageId,
        "message": message,
      ]
    ]
  }

  private static func headerSubtitle(for row: ChatHomeListRow) -> String {
    if row.isSavedMessages {
      return "Saved Messages"
    }
    if ChatEngine.shared.isTyping(["chatId": row.chatId]) {
      return "typing..."
    }
    if row.isGroup {
      return row.isChannel ? "channel" : "group"
    }
    guard ChatRoute.rowsContainPeerResponse(
      row.initialMessages.isEmpty ? row.previewRows : row.initialMessages,
      peerUserId: row.peerUserId,
      isGroup: row.isGroup,
      isAgent: row.isAgentFriend
    ) else {
      return ""
    }
    if isOnline(for: row) {
      return "online"
    }
    return "last seen recently"
  }

  private static func isOnline(for row: ChatHomeListRow) -> Bool {
    guard let peerUserId = normalizedString(row.peerUserId) else { return false }
    return ChatEngine.shared.isUserOnline(userId: peerUserId)
  }

  private static func profileHandle(for row: ChatHomeListRow) -> String {
    if row.isSavedMessages {
      return "saved chat"
    }
    if row.isGroup {
      return row.isChannel ? "channel" : "group chat"
    }
    if let peer = normalizedString(row.peerUserId) {
      return "id: \(peer)"
    }
    return headerSubtitle(for: row)
  }

  private static func previewAppearance(isDark: Bool) -> [String: Any] {
    ChatAppearanceDraftStore.chatRawAppearance(isDark: isDark)
  }

  private static func collectScrollViews(in view: UIView) -> [UIScrollView] {
    var result: [UIScrollView] = []
    if let scrollView = view as? UIScrollView {
      result.append(scrollView)
    }
    for subview in view.subviews {
      result.append(contentsOf: collectScrollViews(in: subview))
    }
    return result
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }
}

private struct ContactsPageView: View {
  @EnvironmentObject private var coordinator: AppShellCoordinator
  @Environment(\.colorScheme) private var colorScheme
  @StateObject private var model = ContactDirectoryViewModel()
  @State private var isShowingSearch = false
  @State private var isEditingContacts = false
  @State private var isStartingChat = false
  @State private var errorMessage: String?
  @State private var isShowingChannelCreation = false
  @State private var roomCreationName = ""
  @State private var isShowingGroupCreation = false
  @State private var pendingCreatedRoomRoute: ChatRoute?
  @State private var pendingSavedContact: ContactSearchUser?
  @State private var queuedSavedContact: ContactSearchUser?

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    Group {

      Group {
        if model.rows.isEmpty && model.isLoading {
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.background)
        } else if model.rows.isEmpty {
          AppShellEmptyStateView(
            icon: "person.2",
            title: "No Contacts Yet",
            message: errorMessage ?? model.errorMessage ?? "Find someone by username, phone number, or user ID.",
            buttonTitle: "New Chat",
            palette: palette
          ) {
            isShowingSearch = true
          }
        } else {
          ChatHomeNativeListRepresentable(
            rows: model.rows,
            isDark: colorScheme == .dark,
            isEditing: isEditingContacts,
            showsRightCheckmark: false,
            selectedChatIDs: [],
            onSelect: { row in
              coordinator.openChat(ChatRoute(row: row))
            },
            onToggleSelection: { _ in },
            onAction: { _, _ in },
            onRefresh: { await model.refresh() },
            onUnavailableAction: { _ in }
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(palette.background)
        }
      }
      .background(palette.background.ignoresSafeArea())
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(isEditingContacts ? "Done" : "Edit") {
            withAnimation { isEditingContacts.toggle() }
          }
          .font(.system(size: 17, weight: .semibold))
          .tint(colorScheme == .dark ? .white : .black)
        }

        ToolbarItem(placement: .principal) {
          Text("Contacts")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(colorScheme == .dark ? .white : .black)
        }

        if !isEditingContacts {
          ToolbarItem(placement: .topBarTrailing) {
          HStack(spacing: 18) {
            Button {
            } label: {
              Image("BrandLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(colorScheme == .dark ? .white : .black)
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Button {
            } label: {
              AppVectorIcon(glyph: .story, tint: colorScheme == .dark ? .white : .black)
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Button {
              isShowingSearch = true
            } label: {
              AppVectorIcon(glyph: .compose, tint: colorScheme == .dark ? .white : .black)
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
          }
          .padding(.horizontal, 6)
        }
        }
      }
    }
    .task {
      await model.loadIfNeeded()
    }
    .refreshable {
      await model.refresh()
    }
    .sheet(isPresented: $isShowingSearch, onDismiss: presentQueuedSavedContact) {
      if let config = AppSessionConfig.current {
        Group {
          ContactSearchView(config: config, homeRows: model.rows) { payload in
            handleSearchPayload(payload)
          }
        }
      }
    }
    .sheet(item: $pendingSavedContact) { user in
      ContactActionSheet(
        user: user,
        onChat: {
          pendingSavedContact = nil
          Task { _ = await openChat(for: user) }
        },
        onCall: {
          pendingSavedContact = nil
          Task {
            let route = await openChat(for: user)
            if let route {
              NativeCallRouteBridge.startOutgoing(route: route, callType: "voice")
            }
          }
        }
      )
    }
    .sheet(isPresented: $isShowingGroupCreation, onDismiss: openPendingCreatedRoom) {
      if let config = AppSessionConfig.current {
        ChatGroupCreationSheet(config: config, homeRows: model.rows) { route in
          pendingCreatedRoomRoute = route
          isShowingGroupCreation = false
          Task { await model.refresh() }
        }
      }
    }
    .sheet(isPresented: $isShowingChannelCreation, onDismiss: openPendingCreatedRoom) {
      if let config = AppSessionConfig.current {
        ChannelCreationSheet(config: config) { route in
          pendingCreatedRoomRoute = route
          isShowingChannelCreation = false
          Task { await model.refresh() }
        }
      }
    }
  }

  private func openPendingCreatedRoom() {
    guard let route = pendingCreatedRoomRoute else { return }
    pendingCreatedRoomRoute = nil
    coordinator.openChat(route)
  }

  private func handleSearchPayload(_ payload: [String: Any]) {
    guard let action = payload["action"] as? String else {
      isShowingSearch = false
      return
    }

    if action == "cancel" {
      isShowingSearch = false
      return
    }

    if action == "createdRoom", let route = payload["route"] as? ChatRoute {
      isShowingSearch = false
      pendingCreatedRoomRoute = route
      Task { await model.refresh() }
      return
    }

    if action == "newContact" {
      isShowingSearch = true
      return
    }

    if action == "newGroup" || action == "newChannel" {
      isShowingSearch = false
      roomCreationName = ""
      if action == "newGroup" {
        isShowingGroupCreation = true
      } else {
        isShowingChannelCreation = true
      }
      return
    }

    guard
      ["select", "chat", "call", "saveContact"].contains(action),
      let rawUser = payload["user"] as? [String: Any],
      let user = ContactSearchUser(payload: rawUser)
    else {
      isShowingSearch = false
      errorMessage = "The selected contact could not be opened."
      return
    }

    if action == "saveContact" {
      queuedSavedContact = user
      isShowingSearch = false
      return
    }

    isShowingSearch = false
    Task {
      let route = await openChat(for: user)
      if action == "call", let route {
        NativeCallRouteBridge.startOutgoing(route: route, callType: "voice")
      }
    }
  }

  private func presentQueuedSavedContact() {
    guard let user = queuedSavedContact else { return }
    queuedSavedContact = nil
    pendingSavedContact = user
  }

  @MainActor
  private func openChat(for user: ContactSearchUser) async -> ChatRoute? {
    guard let config = AppSessionConfig.current else {
      errorMessage = "The current session is unavailable."
      return nil
    }

    isStartingChat = true
    errorMessage = nil
    defer { isStartingChat = false }

    let isBridgeAgent = user.bridgeProvider != nil || user.isAgent
    do {
      let result = try await ChatDirectMessageService.startChat(
        config: config,
        friendID: user.userID
      )
      if let publicKey = user.publicKey, !publicKey.isEmpty {
        _ = ChatEngine.shared.cachePeerPublicKey([
          "chatId": result.chatID,
          "peerUserId": user.userID,
          "publicKey": publicKey,
        ])
      }
      let route = ChatRoute(
        chatId: result.chatID,
        title: user.username,
        peerUserId: user.userID,
        peerAgentId: user.bridgeAgentRouteId,
        isAgent: user.isAgent || user.bridgeProvider != nil,
        avatarURI: ChatAvatarURLResolver.resolve(
          rawAvatar: user.profileImage,
          peerUserId: user.userID,
          chatId: result.chatID,
          preferPushAvatar: false,
          isAgent: user.isAgent || user.bridgeProvider != nil,
          agentId: user.agentId ?? user.bridgeAgentRouteId,
          displayName: user.handle ?? user.username
        ),
        isGroup: false,
        initialRows: result.messages,
        bridgeProvider: user.bridgeProvider
      )
      coordinator.openChat(route)
      Task { await model.refresh() }
      return route
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }
}

private struct CallsPageView: View {
  @Environment(\.colorScheme) private var colorScheme
  @State private var isEditingCalls = false

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    Group {
      AppShellEmptyStateView(
        icon: "phone",
        title: "No Calls Yet",
        message: "Recent and active calls will appear here when the call runtime is linked into the standalone shell.",
        buttonTitle: nil,
        palette: palette,
        action: nil
      )
      .background(palette.background.ignoresSafeArea())
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(isEditingCalls ? "Done" : "Edit") {
            withAnimation { isEditingCalls.toggle() }
          }
          .font(.system(size: 17, weight: .semibold))
          .tint(colorScheme == .dark ? .white : .black)
        }

        ToolbarItem(placement: .principal) {
          Text("Calls")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(colorScheme == .dark ? .white : .black)
        }

        if !isEditingCalls {
          ToolbarItem(placement: .topBarTrailing) {
          HStack(spacing: 18) {
            Button {
            } label: {
              Image("BrandLogo")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(colorScheme == .dark ? .white : .black)
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Button {
            } label: {
              AppVectorIcon(glyph: .story, tint: colorScheme == .dark ? .white : .black)
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            Button {
            } label: {
              AppVectorIcon(glyph: .compose, tint: colorScheme == .dark ? .white : .black)
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
          }
          .padding(.horizontal, 6)
        }
        }
      }
    }
  }
}





private enum ChatConversationPage: String {
  case chat
  case profile
  case agent
}

final class ChatProfileRootController: UIViewController, CNContactViewControllerDelegate {
  private let profileView = ChatProfileMainView()
  private var route: ChatRoute
  private var isDark: Bool
  private var onClose: (() -> Void)?
  private var onProfileAppearanceUpdated: (() -> Void)?
  private var onSearchRequested: (() -> Void)?
  private var onContentRequested: (([String: Any]) -> Void)?
  private var isChatMuted = false
  private var rowsRefreshGeneration: UInt = 0

  var chatId: String { route.chatId }

  init(
    route: ChatRoute,
    isDark: Bool,
    onClose: (() -> Void)?,
    onProfileAppearanceUpdated: (() -> Void)? = nil,
    onSearchRequested: (() -> Void)? = nil,
    onContentRequested: (([String: Any]) -> Void)? = nil
  ) {
    self.route = route
    self.isDark = isDark
    self.onClose = onClose
    self.onProfileAppearanceUpdated = onProfileAppearanceUpdated
    self.onSearchRequested = onSearchRequested
    self.onContentRequested = onContentRequested
    super.init(nibName: nil, bundle: nil)
    appShellRouteLog("ChatProfileRootController init chatId=\(route.chatId) title=\(route.title)")
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    return isDark ? .lightContent : .darkContent
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    let background = Self.backgroundColor(isDark: isDark)
    view.backgroundColor = background
    profileView.translatesAutoresizingMaskIntoConstraints = false
    profileView.backgroundColor = background
    view.addSubview(profileView)
    NSLayoutConstraint.activate([
      profileView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      profileView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      profileView.topAnchor.constraint(equalTo: view.topAnchor),
      profileView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    profileView.onNativeEvent.handler = { [weak self] payload in
      self?.handleNativeEvent(payload)
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleChatEngineChanged(_:)),
      name: ChatEngine.didChangeNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppearanceDraftChanged(_:)),
      name: ChatAppearanceDraftStore.didChangeNotification,
      object: nil
    )
    applyRoute()
    refreshRows()
  }

  /// Repaint on wallpaper/theme edits instead of waiting for the next push.
  @objc private func handleAppearanceDraftChanged(_ notification: Notification) {
    ChatListAppearance.invalidateBootstrap()
    let nextIsDark = ChatListAppearance.resolvedSystemStyle() == .dark
    isDark = nextIsDark
    let background = Self.backgroundColor(isDark: nextIsDark)
    view.backgroundColor = background
    profileView.backgroundColor = background
    profileView.setAppearance(Self.resolvedAppearance(isDark: nextIsDark))
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func update(
    route: ChatRoute,
    isDark: Bool,
    onClose: (() -> Void)?,
    onProfileAppearanceUpdated: (() -> Void)? = nil,
    onSearchRequested: (() -> Void)? = nil,
    onContentRequested: (([String: Any]) -> Void)? = nil
  ) {
    let routeChanged = self.route != route
    let themeChanged = self.isDark != isDark
    self.route = route
    self.isDark = isDark
    self.onClose = onClose
    self.onProfileAppearanceUpdated = onProfileAppearanceUpdated
    self.onSearchRequested = onSearchRequested
    self.onContentRequested = onContentRequested

    if themeChanged {
      setNeedsStatusBarAppearanceUpdate()
      view.backgroundColor = Self.backgroundColor(isDark: isDark)
    }
    if routeChanged || themeChanged {
      applyRoute()
      refreshRows()
    }
  }

  private func applyRoute() {
    let surfaceId = "native_profile_\(route.chatId)"
    view.backgroundColor = Self.backgroundColor(isDark: isDark)
    profileView.performBatchedProfileUpdate {
      profileView.surfaceId = surfaceId
      profileView.setProfileOnly(true)
      profileView.setEngineSurfaceId(surfaceId)
      profileView.setEngineChatId(route.chatId)
      profileView.setEnginePeerUserId(route.peerUserId ?? "")
      if let myUserId = Self.normalizedString(
        ChatEngineStore.shared.getConfig()["myUserId"] ?? ChatEngineStore.shared.getConfig()["userId"]
      ) {
        profileView.setEngineMyUserId(myUserId)
      }
      profileView.setAppearance(Self.resolvedAppearance(isDark: isDark))
      if let config = AppSessionConfig.current {
        isChatMuted =
          ChatHomeService.cachedRows(config: config).first(where: { $0.chatId == route.chatId })?.muted
          ?? isChatMuted
      }
      profileView.setIsChatMuted(isChatMuted)
      profileView.setHeaderTitle(route.title)
      profileView.setHeaderSubtitle(Self.routeOnlyHeaderSubtitle(for: route))
      profileView.setProfileName(route.title)
      profileView.setBridgeProvider(route.bridgeProvider ?? "")
      profileView.setProfileHandle(Self.profileHandle(for: route))
      profileView.setProfileBio(route.roomDescription ?? "")
      profileView.setAvatarUri(route.avatarURI)
      let resolvedChannel =
        route.isChannel
        || GroupProfileActionRouter.resolvedIsChannel(chatId: route.chatId)
      profileView.setIsGroupOrChannel(route.isGroup || route.isChannel || resolvedChannel)
      profileView.setRouteMembership(
        isChannel: resolvedChannel,
        myRole: route.myRole
      )
      profileView.setChannelSettings(
        accessType: route.accessType,
        publicSlug: route.publicSlug,
        shareLink: route.shareLink,
        joinApprovalRequired: route.joinApprovalRequired,
        restrictSavingContent: route.restrictSavingContent,
        subscriberCount: route.isChannel ? route.roomParticipantCount : nil
      )
      let routeMemberCount = route.members.count
      // Always hydrate the roster for groups *and* channels so owner/admin role
      // and channel-admin controls work. The SwiftUI profile still hides the
      // public Members list for non-admin channel viewers.
      let resolvedMembers = ChatRoute.resolvedMembers(
        chatId: route.chatId, routeMembers: route.members)
      if route.members.isEmpty, !resolvedMembers.isEmpty {
        self.route = route.withMembers(resolvedMembers)
      }
      profileView.setGroupMembers(resolvedMembers)
      if route.isGroup {
        profileView.setGroupMemberCount(max(route.roomParticipantCount, resolvedMembers.count))
      }
      NSLog(
        "[WhoAmI] ChatProfileRoot.applyRoute groupMembers chatId=%@ route=%d resolved=%d isChannel=%@ myRole=%@ showsMembers=%@",
        String(route.chatId.prefix(12)),
        routeMemberCount,
        resolvedMembers.count,
        route.isChannel ? "Y" : "N",
        route.myRole ?? "<nil>",
        route.showsMemberList ? "Y" : "N"
      )
      profileView.setRows(route.initialRows)
    }
  }

  private func refreshRows(preferInitialRows: Bool = false) {
    rowsRefreshGeneration &+= 1
    let generation = rowsRefreshGeneration
    let chatID = route.chatId

    if preferInitialRows {
      profileView.setRows(route.initialRows)
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let nativeRows = ChatEngine.shared.getChatRows(["chatId": chatID])
      DispatchQueue.main.async { [weak self] in
        guard let self, self.route.chatId == chatID, self.rowsRefreshGeneration == generation else {
          return
        }
        self.profileView.setRows(nativeRows.isEmpty ? self.route.initialRows : nativeRows)
      }
    }
  }

  @objc private func handleChatEngineChanged(_ notification: Notification) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.handleChatEngineChanged(notification)
      }
      return
    }

    let changedChatId = Self.normalizedString(notification.userInfo?["chatId"])
    let changeReason = Self.normalizedString(notification.userInfo?["reason"]) ?? "unknown"
    if route.chatId == "saved_messages", changedChatId == nil {
      return
    }
    guard changedChatId == route.chatId || changedChatId == nil else { return }

    switch changeReason {
    case "chatRowsReloaded", "chatMessageInserted", "chatMessageEdited", "chatMessageDeleted",
      "chatMessageChanged", "chatMessageReactionChanged", "messageStatusChanged",
      "presenceChanged", "peerTyping", "chatMuteChanged":
      refreshRows()
    default:
      break
    }
  }

  private func handleNativeEvent(_ payload: [String: Any]) {
    let type = Self.normalizedString(payload["type"]) ?? ""
    appShellRouteLog("ChatProfileRootController nativeEvent chatId=\(route.chatId) type=\(type)")
    switch type {
    case "headerBack":
      if let navigationController, navigationController.topViewController === self,
        navigationController.viewControllers.count > 1
      {
        navigationController.popViewController(animated: true)
      } else {
        onClose?()
      }
    case "profileAppearanceUpdated":
      profileView.refreshProfileAppearance()
      onProfileAppearanceUpdated?()
    case "agentToast":
      if let message = Self.normalizedString(payload["message"]) {
        AppToastController.shared.show(message)
      }
    case "headerSearchPressed":
      onSearchRequested?()
    case "headerAudioCallPressed":
      NativeCallRouteBridge.startOutgoing(route: route, callType: "voice")
    case "headerVideoCallPressed":
      NativeCallRouteBridge.startOutgoing(route: route, callType: "video")
    case "headerMenuAction":
      let action = Self.normalizedString(payload["action"]) ?? ""
      if action == "clearChat" {
        presentClearChatOptions()
      } else if action == "muteToggle" {
        toggleMute()
      }
    case "profileContentPressed":
      onContentRequested?(payload)
    case "profileContactAction":
      handleProfileContactAction(payload)
    case "profileGroupAction", "groupMemberTapped", "channelLink", "channelSetting", "channelAgents":
      _ = GroupProfileActionRouter.handle(
        payload: payload,
        route: route,
        presenter: topMostPresenter(),
        onClose: { [weak self] in self?.onClose?() },
        onEdited: { [weak self] name, avatarUrl, description in
          guard let self else { return }
          self.profileView.setProfileName(name)
          self.profileView.setHeaderTitle(name)
          self.profileView.setProfileBio(description)
          if let avatarUrl, !avatarUrl.isEmpty { self.profileView.setAvatarUri(avatarUrl) }
        })
    case "openAgentPanel":
      // The group profile's Repository row lands here (the standalone profile push,
      // not ChatConversationController) — without this case the tap did nothing.
      let provider =
        Self.normalizedString(payload["provider"] ?? payload["agentBridgeProvider"])
        ?? route.bridgeProvider
      if let provider, !provider.isEmpty {
        presentBridgeRepositoryPicker(provider: provider)
      }
    default:
      break
    }
  }

  private func presentBridgeRepositoryPicker(provider: String) {
    let displayName = ChatRoute.bridgeDisplayName(for: provider)
    let root = AgentBridgeRepositoryPickerView(
      provider: provider, displayName: displayName, chatId: route.chatId)
      .preferredColorScheme(isDark ? .dark : .light)
    let host = UIHostingController(rootView: root)
    host.modalPresentationStyle = .pageSheet
    host.view.backgroundColor = .clear
    if let sheet = host.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 28
    }
    topMostPresenter().present(host, animated: true)
  }

  private func toggleMute() {
    guard let config = AppSessionConfig.current else {
      AppToastController.shared.show("Unable to update mute")
      return
    }
    let previous = isChatMuted
    let next = !previous
    isChatMuted = next
    profileView.setIsChatMuted(next)
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await ChatHomeEditService.apply(
          action: .mute(next),
          chatID: route.chatId,
          config: config
        )
        AppToastController.shared.show(next ? "Notifications muted" : "Notifications unmuted")
      } catch {
        isChatMuted = previous
        profileView.setIsChatMuted(previous)
        AppToastController.shared.show(error.localizedDescription)
      }
    }
  }

  private func handleProfileContactAction(_ payload: [String: Any]) {
    let action = Self.normalizedString(payload["action"]) ?? ""
    if action == "addContact" {
      AppToastController.shared.show("Added to Contacts")
      return
    }
    guard action == "block", let peerUserId = route.peerUserId else { return }

    let alert = UIAlertController(
      title: "Block \(route.title)?",
      message: "They will no longer be able to contact you.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(UIAlertAction(title: "Block", style: .destructive) { _ in
      let result = ChatEngine.shared.blockUser(["blockedUserId": peerUserId])
      let accepted = (result["accepted"] as? Bool) == true
      AppToastController.shared.show(accepted ? "User blocked" : "Unable to block user")
    })
    topMostPresenter().present(alert, animated: true)
  }

  private func presentClearChatOptions() {
    let presenter = topMostPresenter()
    let canClearForEveryone = route.peerUserId != nil && !route.isGroup && route.chatId != "saved_messages"
    let sheet = UIAlertController(
      title: "Clear Chat",
      message: nil,
      preferredStyle: .actionSheet
    )
    if canClearForEveryone {
      sheet.addAction(
        UIAlertAction(title: "Clear for me and \(route.title)", style: .destructive) {
          [weak self] _ in
          self?.performClearChat(deleteForEveryone: true)
        })
    }
    sheet.addAction(
      UIAlertAction(
        title: canClearForEveryone ? "Clear just for me" : "Clear for me",
        style: .destructive
      ) { [weak self] _ in
        self?.performClearChat(deleteForEveryone: false)
      })
    sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = view
      popover.sourceRect = CGRect(x: view.bounds.midX, y: view.safeAreaInsets.top + 44.0, width: 1.0, height: 1.0)
      popover.permittedArrowDirections = []
    }
    presenter.present(sheet, animated: true)
  }

  private func topMostPresenter() -> UIViewController {
    var presenter: UIViewController = self
    while let presented = presenter.presentedViewController {
      presenter = presented
    }
    return presenter
  }

  private func performClearChat(deleteForEveryone: Bool) {
    if let config = AppSessionConfig.current {
      ChatHomeService.removeCachedChat(chatID: route.chatId, config: config)
    }
    if deleteForEveryone {
      _ = ChatEngine.shared.clearChat([
        "chatId": route.chatId,
        "localOnly": true,
      ])
      profileView.setRows([])
      guard let config = AppSessionConfig.current else {
        AppToastController.shared.show("The current session is unavailable.")
        return
      }
      Task { @MainActor in
        do {
          try await ChatHomeEditService.deleteChat(
            chatID: route.chatId,
            config: config,
            deleteForEveryone: true
          )
          AppToastController.shared.show("Chat cleared for both sides.")
        } catch {
          AppToastController.shared.show(error.localizedDescription)
        }
      }
      return
    }

    _ = ChatEngine.shared.clearChat(["chatId": route.chatId])
    profileView.setRows([])
    AppToastController.shared.show("Chat cleared.")
  }

  private static func backgroundColor(isDark _: Bool) -> UIColor {
    ChatListAppearance.current.wallpaperBase
  }

  private static func resolvedAppearance(isDark: Bool) -> [String: Any] {
    ChatAppearanceDraftStore.chatRawAppearance(isDark: isDark)
  }

  private static func routeOnlyHeaderSubtitle(for route: ChatRoute) -> String {
    if route.chatId == "saved_messages" {
      return "Saved Messages"
    }
    if route.isGroup {
      return route.roomParticipantSubtitle
    }
    return route.peerUserId == nil || !route.hasPeerResponse ? "" : "last seen recently"
  }

  private static func profileHandle(for route: ChatRoute) -> String {
    if route.chatId == "saved_messages" {
      return "Personal notes and media"
    }
    if let peerUserId = normalizedString(route.peerUserId) {
      return peerUserId
    }
    if route.isGroup {
      return route.isChannel ? "Channel" : "Group chat"
    }
    return ""
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }
}

final class ChatConversationController: UIViewController {
  private static let postPresentationActivationDelay: TimeInterval = 0.28

  private let mainView = ChatMainView()
  private var profileView: ChatProfileMainView?
  private var route: ChatRoute
  private var isDark: Bool
  private var onClose: (() -> Void)?
  private var currentPage: ChatConversationPage = .chat
  private var openedChatId: String?
  private var openedChatIdUsesEngineChannel = false
  private var didInitialScroll = false
  private var loggedFirstRealLayout = false
  private var rowsRefreshGeneration: UInt = 0
  private var lastLayoutSignature: String?
  private var hasAppeared = false
  private var pendingDeferredEngineStateRefresh = false
  private var deferredEngineRowsReadyChatId: String?
  private var latestProfileRows: [[String: Any]] = []
  private var pendingRowsForAttachment: [[String: Any]]?
  private var isDismantled = false
  private var pendingRowsForAttachmentChatId: String?
  private var pendingRowsForAttachmentSource: String?
  private var lastAppliedRowsToSurfaceCount = 0
  private var postPresentationActivationWorkItem: DispatchWorkItem?
  private var didRunPostPresentationActivation = false
  private var pendingEngineBinding = false
  private var engineBindingKey: String?
  private var engineBindingUserId: String?
  private var pendingAppearanceForAttachment: [String: Any]?
  private var pendingInputActivationForAttachment = false
  // Computer-bridge agent (Claude/Codex) connect gate. Non-nil while the chat is
  // an unconnected bridge-agent chat: the composer is hidden and a Connect panel
  // is shown until a paired computer comes online.
  private var agentConnectModel: AgentConnectModel?
  private var agentConnectHost: UIHostingController<AgentConnectPanel>?
  private var bridgeConnectedThisSession = false
  /// Pending "show the connect panel" work, deferred a beat so a fast status poll can
  /// reveal the composer with no panel flash. Cancelled the moment we connect.
  private var pendingConnectPanelWork: DispatchWorkItem?
  /// Fresh bridge status verification before the connect panel is allowed to appear.
  /// This prevents a stale disconnected route state from flashing the panel for a
  /// second while the daemon is already online.
  private var pendingConnectStatusTask: Task<Void, Never>?
  /// Home stops its status poll as soon as this page is pushed. Keep group/provider task
  /// authority alive while the conversation is visible so a cloud-only phone still
  /// retires stale CLI/team state even if a terminal stream frame was missed.
  private var bridgeStatusPollTask: Task<Void, Never>?

  /// Destination bounds handed over by `prepareForNavigationPush` before the view exists,
  /// so `loadView` can size it before `viewDidLoad` seeds anything. See that method — a
  /// seed measured at width 0 cannot hit the prepared-height store and sizes the whole
  /// transcript by estimate.
  private var prestagedInitialBounds: CGRect?

  /// The navigation container the prestaged view is parked in until UIKit takes it.
  /// See `prepareForNavigationPush` — the reveal is keyed on leaving THIS superview.
  private weak var prestageParkingSuperview: UIView?
  /// Bumped per push so a late watchdog cannot unhide a view a newer open owns.
  private var prestageRevealToken = 0

  /// The isolated full-screen agent runtime surface (Claude/Codex), hosted as a child VC
  /// over `mainView` when this DM's Default view is Agent or the user taps "See progress".
  /// It owns its full bounds + its own header (no nesting under the chat header → no clip /
  /// overlap), and its back returns to the chat surface.
  private weak var bridgeAgentSurfaceVC: VibeAgentConversationViewController?

  /// The chat currently shown. Used by the coordinator to avoid pushing a
  /// duplicate of the chat already on top of the navigation stack.
  var chatId: String { route.chatId }

  init(route: ChatRoute, isDark: Bool, onClose: (() -> Void)?) {
    self.route = route
    self.isDark = isDark
    self.onClose = onClose
    appShellRouteLog(
      "ChatConversationController init chatId=\(route.chatId) title=\(route.title) dark=\(isDark)")
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Mount and settle the destination invisibly behind the current navigation page so
  /// the native push begins with a populated, final-width transcript. Keeping the work
  /// window-attached is important: collection cells do not materialize correctly in a
  /// detached 0x0 hierarchy, while index 0 remains fully covered by Home.
  func prepareForNavigationPush(in navigationController: UINavigationController) {
    // Phase stamps for the agent open. The total was 208-254ms against 24-46ms for an
    // ordinary chat, and a single number cannot say which half to attack: loading the
    // view, the first layout of 150 rows, or the seed mount inside `finish…`.
    let t0 = ProcessInfo.processInfo.systemUptime
    // Size the view BEFORE loading it.
    //
    // `loadViewIfNeeded()` runs `viewDidLoad`, which applies the route, binds the engine
    // and stashes the seed. All of that used to happen while the view was still 0x0 —
    // `[ZeroBounds] cover-show self=0x0 cv=0x0` on every open. The cost is not cosmetic:
    // prepared heights are keyed by (row, WIDTH), so at width 0 every lookup misses. A
    // device trace showed a chat with 1,368 cached heights reporting
    // `sizing=estimated trust=0 cacheHit=0 storeMiss=1031 width=0` — it had the heights
    // and used none of them, sized 1,386 rows by estimate, and then moved the whole list
    // when the real heights arrived. That is the shift.
    //
    // The destination bounds are known here, so hand them over first and let the seed
    // measure at final width.
    let destinationBounds = navigationController.view.bounds
    if isViewLoaded {
      view.frame = destinationBounds
    } else {
      prestagedInitialBounds = destinationBounds
    }
    loadViewIfNeeded()
    view.frame = destinationBounds
    let tLoad = ProcessInfo.processInfo.systemUptime

    let destinationSafeBottom = max(
      navigationController.view.safeAreaInsets.bottom,
      navigationController.view.window?.safeAreaInsets.bottom ?? 0
    )
    mainView.setNavigationPrestageSafeAreaBottom(destinationSafeBottom)
    mainView.beginNavigationPushPrestaging()
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.isHidden = true
    navigationController.view.insertSubview(view, at: 0)
    UIView.performWithoutAnimation {
      view.setNeedsLayout()
      view.layoutIfNeeded()
      mainView.layoutIfNeeded()
    }
    let tLayout = ProcessInfo.processInfo.systemUptime

    mainView.finishNavigationPushPrestaging()
    let tFinish = ProcessInfo.processInfo.systemUptime
    armPrestageRevealOnReparent(parkedIn: navigationController.view)
    NSLog(
      "[AgentOpen] prestage-phases loadView=%dms firstLayout=%dms finishPrestage=%dms total=%dms",
      Int((tLoad - t0) * 1000), Int((tLayout - tLoad) * 1000),
      Int((tFinish - tLayout) * 1000), Int((tFinish - t0) * 1000))
    // One layout pass before the push, not two.
    //
    // `finishNavigationPushPrestaging` already lays the destination out — that is its
    // job — and this second `layoutIfNeeded` pair re-ran the whole thing to catch the
    // `isHidden` flip, which changes no geometry. On the agent surface that means laying
    // out tall streaming-text turns twice (a device trace shows one at
    // `bounds=332x1511`), and all of it happens *before* `pushViewController` is called:
    // measured at 208-254ms of a completely dead tap, against 27-46ms for an ordinary
    // chat. Visibility is not geometry; the frames are already correct.
  }

  /// Keeps the parked destination hidden until UIKit moves it into the transition
  /// container, then reveals it in that same commit.
  ///
  /// ## The frame this removes
  ///
  /// Reported from a slow-motion capture: on tap, the whole chat flashes full-screen,
  /// disappears, and only then does the push slide begin. That flash is this view —
  /// `prepareForNavigationPush` parks it in the navigation container at full destination
  /// bounds so the transcript lays out at final width, and the old code unhid it on the
  /// line before `pushViewController`. If any commit lands while it is still parked (a
  /// re-parent UIKit defers past that commit, or a `drawHierarchy(afterScreenUpdates:)`
  /// anywhere in the synchronous will-appear path forcing a render), the user gets a full
  /// screen of the destination on top of the page they are still looking at.
  ///
  /// Moving the `isHidden = false` line below `pushViewController` does **not** fix that:
  /// Core Animation commits at the end of the run-loop turn, and both orderings are the
  /// same turn. The only event that reliably separates "parked" from "pushed" is the
  /// re-parent itself, so that is what the reveal is keyed on.
  private func armPrestageRevealOnReparent(parkedIn container: UIView) {
    prestageRevealToken &+= 1
    let token = prestageRevealToken
    prestageParkingSuperview = container
    guard let root = view as? ChatPrestageRootView else {
      // No hook available (a root view we did not create): fall back to the old behaviour
      // rather than pushing a permanently invisible page.
      flashProbeLog(
        "reveal-fallback chat=\(route.chatId.prefix(12)) "
          + "— root is \(type(of: view)), unhiding while parked")
      view.isHidden = false
      return
    }
    root.prestageProbeLabel = String(route.chatId.prefix(12))
    root.onSuperviewChanged = { [weak self] superview in
      guard let self, self.prestageRevealToken == token else { return }
      // Still parked (or detached mid-teardown) — keep it invisible.
      guard let superview, superview !== self.prestageParkingSuperview else { return }
      self.revealPrestagedView(reason: "reparent")
    }
    // The push may never start (a route replaced before it runs, a push cancelled by an
    // interactive pop). Never leave a page hidden forever because of an optimisation.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self, self.prestageRevealToken == token, self.view.isHidden else { return }
      NSLog(
        "[ChatOpen] prestage-reveal WATCHDOG chat=%@ — re-parent never happened",
        String(self.route.chatId.prefix(12)))
      self.revealPrestagedView(reason: "watchdog")
    }
  }

  private func revealPrestagedView(reason: String) {
    guard view.isHidden else { return }
    // Unhiding a view that is STILL parked would recreate the full-screen flash this
    // whole mechanism exists to remove — now on a timer, which is worse than the bug.
    // The watchdog exists so a page is never permanently invisible, not so a parked one
    // gets shown: if the push never took the view, take it out of the container instead.
    // UIKit re-adds it wherever it belongs the moment a transition does start.
    let stillParked = prestageParkingSuperview.map { view.superview === $0 } ?? false
    if let parking = prestageParkingSuperview, view.superview === parking {
      view.removeFromSuperview()
    }
    (view as? ChatPrestageRootView)?.onSuperviewChanged = nil
    prestageParkingSuperview = nil
    view.isHidden = false
    NSLog(
      "[ChatOpen] prestage-reveal chat=%@ by=%@ sinceTapMs=%d",
      String(route.chatId.prefix(12)), reason, VibeChatOpenTap.msSinceTap())
    // Unhiding a still-parked view IS the flash; record the geometry that would make it
    // full-screen, plus whether a transition was actually running.
    flashProbeLog(
      "reveal chat=\(route.chatId.prefix(12)) by=\(reason) "
        + "stillParked=\(stillParked ? "Y" : "N") "
        + "super=\(view.superview.map { String(describing: type(of: $0)) } ?? "nil") "
        + "frame=\(NSCoder.string(for: view.frame)) "
        + "superBounds=\(NSCoder.string(for: view.superview?.bounds ?? .zero)) "
        + "anims=\(view.superview?.layer.animationKeys()?.count ?? 0)")
  }

  /// Was the destination still parked in the navigation container one turn after the push
  /// was asked for? Answers, from any device export, whether UIKit defers the re-parent
  /// past the first commit — the difference between "the reveal hook is enough" and "the
  /// parking itself has to move".
  func probePrestageParkingAfterPush(container: UIView) {
    let token = prestageRevealToken
    DispatchQueue.main.async { [weak self] in
      guard let self, self.prestageRevealToken == token else { return }
      let stillParked = self.view.superview === container
      NSLog(
        "[ChatOpen] prestage-parking chat=%@ stillParked=%@ hidden=%@ sinceTapMs=%d",
        String(self.route.chatId.prefix(12)),
        stillParked ? "Y" : "N", self.view.isHidden ? "Y" : "N",
        VibeChatOpenTap.msSinceTap())
    }
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    return isDark ? .lightContent : .darkContent
  }

  override func loadView() {
    // A root view that can say when UIKit re-parents it. `prepareForNavigationPush`
    // parks this view inside the navigation container to lay the transcript out at final
    // width, and it must stay hidden until the push actually takes it — see that method.
    // `didMoveToSuperview` is the only signal that fires in the same commit as the
    // reparent, which is what makes the reveal frame-exact rather than turn-exact.
    view = ChatPrestageRootView()
    // Before viewDidLoad, so the seed it triggers measures at the destination width.
    if let prestagedInitialBounds {
      view.frame = prestagedInitialBounds
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    logLifecycle("viewDidLoad")

    mainView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(mainView)
    NSLayoutConstraint.activate([
      mainView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      mainView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      mainView.topAnchor.constraint(equalTo: view.topAnchor),
      mainView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    // Resolve those constraints NOW, while the frame from `loadView` is known and before
    // anything below applies the route. A constraint that has not been solved leaves
    // `mainView` — and the collection view inside it — at 0x0, which is precisely the
    // state the seed used to run in. One pass here replaces the estimate-everything
    // seed with a measured one.
    if prestagedInitialBounds != nil {
      UIView.performWithoutAnimation {
        view.layoutIfNeeded()
      }
    }

    mainView.onNativeEvent.handler = { [weak self] payload in
      self?.handleNativeEvent(payload)
    }
    // Host the DM-level agent runtime view as an isolated full-screen surface over the
    // chat (its own header + full bounds). ChatListView's presence logic drives these.
    mainView.onPresentBridgeAgentSurface = { [weak self] vc in
      self?.presentBridgeAgentSurface(vc)
    }
    mainView.onDismissBridgeAgentSurface = { [weak self] in
      self?.dismissBridgeAgentSurface()
    }
    mainView.hostedBridgeAgentProviderProvider = { [weak self] in
      self?.bridgeAgentSurfaceVC?.agentBridgeProvider
    }
    mainView.hostedBridgeAgentSurfaceModeProvider = { [weak self] in
      self?.bridgeAgentSurfaceVC?.surfaceMode
    }
    // Draw the chat's own native header (back / title / avatar). The view fully
    // implements this; it was only disabled so a SwiftUI .toolbar could draw the
    // header instead — the source of the header flicker. Now that the
    // conversation is pushed by a real UIKit UINavigationController (with the
    // system bar hidden), it owns exactly one stable header.
    mainView.setExternalNavigationHeaderEnabled(false)

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleChatEngineChanged(_:)),
      name: ChatEngine.didChangeNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAgentBridgeSelectionChanged(_:)),
      name: AgentBridgeSelectionStore.didChangeNotification,
      object: nil
    )
    // Wallpaper/theme edits land in ChatAppearanceDraftStore, which posts this. Without
    // an observer the surface only re-read appearance inside `applyRoute`, so a chat that
    // was already on screen kept the OLD wallpaper until it was pushed again.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppearanceDraftChanged(_:)),
      name: ChatAppearanceDraftStore.didChangeNotification,
      object: nil
    )

    let applyRouteStartedAt = ProcessInfo.processInfo.systemUptime
    applyRoute(forceChannelRefresh: true)
    NSLog(
      "[ChatOpen] host-stage viewDidLoad applyRouteMs=%d sinceTapMs=%d",
      Int((ProcessInfo.processInfo.systemUptime - applyRouteStartedAt) * 1000),
      VibeChatOpenTap.msSinceTap())
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // This screen draws its own native chat header. Agent Settings temporarily
    // unhides AppRootNavigationController's system bar; reclaim the hidden-bar
    // contract on every return (including an interactive pop that completes).
    navigationController?.setNavigationBarHidden(true, animated: false)
    mainView.setEngineStateUpdatesSuspended(false)
    // Back on screen — bounds and safe area are honest again, so let the insets follow
    // them. Deliberately does not force a recompute; the layout pass that is about to
    // happen anyway does it with the right numbers.
    mainView.setGeometryFrozenForDismissal(false)
    logLifecycle("viewWillAppear")
    logVisualState("viewWillAppear", force: true)
    // If this DM's Default view is Agent, mount the isolated agent surface NOW so it rides this
    // controller's own push transition AS the page — rather than waiting for the deferred peer-id
    // binding (~0.28s after viewDidAppear), which would show the chat first and then morph the
    // agent in over it. ChatListView gates on the per-provider Default-view setting and is
    // one-shot + idempotent, so calling this on every appear is safe.
    let mountDoneAt = ProcessInfo.processInfo.systemUptime
    mountPreferredAgentSurfaceIfNeeded(reason: "viewWillAppear")
    // Flush deferred appearance + rows BEFORE the push animation runs (viewWillAppear
    // fires while the view is already in the window but pre-transition), so the wallpaper
    // and the seeded messages are painted as the chat slides in — not applied a beat later
    // in viewDidAppear, which reads as an empty flash + a soft wallpaper color shift.
    applyPendingAppearanceAfterAttachment(reason: "viewWillAppear")
    let appearanceDoneAt = ProcessInfo.processInfo.systemUptime
    applyPendingRowsAfterAttachment(reason: "viewWillAppear")
    let rowsDoneAt = ProcessInfo.processInfo.systemUptime
    // Resolve the composer/connect-gate as early as possible too: for a Claude/Codex DM
    // this reads the (now proactively warmed) bridge status and lands on a stable input
    // or connect panel before the chat is even fully on screen, instead of activating a
    // beat later in viewDidAppear and visibly swapping in.
    applyPendingInputActivationAfterAttachment(reason: "viewWillAppear")
    NSLog(
      "[ChatOpen] host-stage viewWillAppear appearanceMs=%d rowsMs=%d inputMs=%d sinceTapMs=%d",
      Int((appearanceDoneAt - mountDoneAt) * 1000),
      Int((rowsDoneAt - appearanceDoneAt) * 1000),
      Int((ProcessInfo.processInfo.systemUptime - rowsDoneAt) * 1000),
      VibeChatOpenTap.msSinceTap())
    // The push has begun. Without this the durable timeline jumps straight from
    // `prestage` to `complete` — 600ms on a large chat, most of it main-thread-blocked,
    // with no way to tell how much was spent getting to the transition and how much was
    // the transition itself.
    // What UIKit says the push will take, from UIKit — because `will-appear → did-appear`
    // measures 529–589ms with the main thread completely free (`hang=0.00s`) and is
    // identical on a 12-row chat and a 1,379-row one, so it is the transition itself and
    // not our work. There is no custom animator anywhere in this app, so either UIKit's
    // own push really is ~550ms on this OS (a spring that settles well after the motion
    // reads as finished), or something is delaying the completion callback. Those two
    // have completely different fixes, and guessing between them is how you end up
    // writing a custom transition that fixes nothing.
    let pushMs = Int((transitionCoordinator?.transitionDuration ?? 0) * 1000)
    VibeOpenTrace.shared.mark("will-appear", "pushDur=\(pushMs)ms")
    // Answer the question the comment above poses, instead of reasoning about it.
    //
    // A display link is downstream of every callback that could eat this window, so the
    // two candidates separate cleanly on one number:
    //   * frames ship steadily for the whole ~550ms → UIKit's spring really does take
    //     that long to settle and there is no main-thread work to remove. The fix, if
    //     any, is the curve — not our code.
    //   * frames are dropped → something of ours is running inside the transition, and
    //     `dropped`/`worstGap` size it. The main-thread watchdog cannot see this: it only
    //     reports blocks over 350ms, and 200ms spread across a dozen frames never trips it.
    pushWindowPacer.begin()
    pushWindowStartedAt = ProcessInfo.processInfo.systemUptime
    pushWindowDurationMs = pushMs
  }

  /// Frame delivery during will-appear → did-appear. See `viewWillAppear`.
  private let pushWindowPacer = VibeListFramePacer()
  private var pushWindowStartedAt: TimeInterval = 0
  private var pushWindowDurationMs = 0

  /// The verdict on the push window, in the log that leaves the device.
  ///
  /// `will-appear → did-appear` measures ~550ms on EVERY open — 3 rows, 24 rows, 1103
  /// rows — against a `pushDur` UIKit reports as 350ms. That the number does not move
  /// with content is why it was never chased as our work; that it exceeds the animation
  /// by ~200ms is why it cannot simply be dismissed as the animation either.
  ///
  /// `verdict` is the whole point: `animation-only` means stop looking at our code.
  private func reportPushWindowFrames() {
    pushWindowPacer.end()
    guard pushWindowStartedAt > 0 else { return }
    let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - pushWindowStartedAt) * 1000)
    pushWindowStartedAt = 0
    let dropped = pushWindowPacer.dropped
    let frames = pushWindowPacer.frames
    // A handful of dropped frames is normal for any transition; a fifth of the window is
    // not. Both thresholds are deliberately loose — this is a triage signal, not a gate.
    let verdict: String
    if frames == 0 {
      verdict = "no-frames"
    } else if dropped == 0 {
      verdict = "animation-only"
    } else if dropped * 5 >= frames {
      verdict = "OUR-WORK"
    } else {
      verdict = "mixed"
    }
    // NSLog as well as VibeLog, because this line is the whole point of the pacer and it
    // was invisible in exactly the artifact that gets sent for triage: a device console
    // capture is NSLog-only, so every export so far has carried `viewDidAppear
    // sinceTapMs=620` with no way to tell whether those 620ms were UIKit's spring or our
    // work inside it. Printing it next to that line is what makes the question answerable
    // from a log instead of re-derived by reasoning.
    NSLog(
      "[ChatOpen] push-window chat=%@ verdict=%@ elapsedMs=%d pushDurMs=%d frames=%d "
        + "dropped=%d stutters=%d worstGapMs=%.1f",
      String(route.chatId.prefix(12)), verdict, elapsedMs, pushWindowDurationMs,
      frames, dropped, pushWindowPacer.stutters, pushWindowPacer.worstGapMs)
    VibeLog.info(
      "push window frames", category: "chatopen",
      metadata: [
        "verdict": verdict,
        "elapsedMs": String(elapsedMs),
        "pushDurMs": String(pushWindowDurationMs),
        "frames": String(frames),
        "dropped": String(dropped),
        "stutters": String(pushWindowPacer.stutters),
        "worstGapMs": String(format: "%.1f", pushWindowPacer.worstGapMs),
      ])
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !isDismantled else { return }
    hasAppeared = true
    NSLog(
      "[ChatOpen] host-stage viewDidAppear sinceTapMs=%d", VibeChatOpenTap.msSinceTap())
    VibeOpenTrace.shared.mark("did-appear")
    reportPushWindowFrames()
    logLifecycle("viewDidAppear")
    logVisualState("viewDidAppear", force: true)
    applyPendingAppearanceAfterAttachment(reason: "viewDidAppear")
    applyPendingInputActivationAfterAttachment(reason: "viewDidAppear")
    applyPendingRowsAfterAttachment(reason: "viewDidAppear")
    settleInitialBottomIfNeeded(reason: "viewDidAppear")
    // The navigation transaction is finished. Release the newest coalesced transcript
    // independently of the push; header/masking/composer were already painted locally.
    mainView.completeTranscriptPresentation()
    startVisibleBridgeStatusPollingIfNeeded()
    schedulePostPresentationActivation(reason: "viewDidAppear")
    refreshPersistentAgentInboxSummary()
    applyPendingForwardDraftIfNeeded()
  }

  private var pendingForwardDraft: ChatPendingForwardStore.Draft?

  private func applyPendingForwardDraftIfNeeded() {
    if pendingForwardDraft == nil {
      pendingForwardDraft = ChatPendingForwardStore.take(for: route.chatId)
    }
    guard let draft = pendingForwardDraft else { return }
    let title =
      draft.messageIds.count > 1
      ? "Forward \(draft.messageIds.count) Messages"
      : "Forward Message"
    mainView.applyPendingForwardDraft(title: title, preview: draft.previewText)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if !loggedFirstRealLayout, view.bounds.width > 1, view.bounds.height > 1 {
      loggedFirstRealLayout = true
      VibeDebugLog.log(
        "[ChatOpen] host viewDidLayoutSubviews FIRST-REAL-BOUNDS chatId=%@ view=%.0fx%.0f hasAppeared=%@ pendingRows=%@",
        String(route.chatId.prefix(12)), view.bounds.width, view.bounds.height,
        hasAppeared ? "Y" : "N", pendingRowsForAttachment != nil ? "Y" : "N")
    }
    applyPendingAppearanceAfterAttachment(reason: "viewDidLayoutSubviews")
    applyPendingInputActivationAfterAttachment(reason: "viewDidLayoutSubviews")
    applyPendingRowsAfterAttachment(reason: "viewDidLayoutSubviews")
    settleInitialBottomIfNeeded(reason: "viewDidLayoutSubviews")
    logVisualState("viewDidLayoutSubviews")
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    // Leaves with the chat, like the keyboard — so re-entering never opens onto a panel
    // the user left behind.
    mainView.dismissGifPanel()
    // A pushed Agent Settings page owns the system navigation header. Freeze
    // engine-driven presence/pin/header work in the covered chat so a Phoenix
    // reconnect cannot rebuild iOS 26 glass effects inside the outgoing view.
    // viewWillAppear resumes with one forced catch-up snapshot.
    mainView.setEngineStateUpdatesSuspended(true)
    // Hold the transcript's insets still for the duration of the dismissal. An
    // interactive swipe feeds this view changing bounds and a changing bottom safe area
    // the whole way out, and every one of those recomputes the composer height and the
    // list's bottom inset — invisible on the way out, a jump on the way back.
    mainView.setGeometryFrozenForDismissal(true)
    // Capture while the transcript is still on screen (drawHierarchy needs live
    // content) — this bitmap becomes the next open's first frame.
    let captureStartedAt = ProcessInfo.processInfo.systemUptime
    mainView.captureReopenSnapshot()
    // Timed on the pop path: this runs on main at the exact instant the back-flash is
    // reported, so a long capture here would be a dropped transition frame.
    flashProbeLog(
      "capture-on-dismiss chat=\(route.chatId.prefix(12)) "
        + "ms=\(Int((ProcessInfo.processInfo.systemUptime - captureStartedAt) * 1000))")
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    mainView.persistViewportState()
    bridgeStatusPollTask?.cancel()
    bridgeStatusPollTask = nil
    logLifecycle("viewDidDisappear")
    logVisualState("viewDidDisappear", force: true)
  }

  override func didMove(toParent parent: UIViewController?) {
    super.didMove(toParent: parent)
    logLifecycle("didMoveToParent")
    logVisualState("didMoveToParent", force: true)
  }

  deinit {
    NotificationCenter.default.removeObserver(
      self,
      name: ChatEngine.didChangeNotification,
      object: nil
    )
    NotificationCenter.default.removeObserver(
      self,
      name: AgentBridgeSelectionStore.didChangeNotification,
      object: nil
    )
    postPresentationActivationWorkItem?.cancel()
    pendingConnectStatusTask?.cancel()
    bridgeStatusPollTask?.cancel()
    closeOpenedChatChannel()
  }

  func dismantle() {
    logLifecycle("dismantle")
    isDismantled = true
    postPresentationActivationWorkItem?.cancel()
    postPresentationActivationWorkItem = nil
    bridgeStatusPollTask?.cancel()
    bridgeStatusPollTask = nil
    removeAgentConnectPanel()
    closeOpenedChatChannel()
  }

  func update(route: ChatRoute, isDark: Bool, onClose: (() -> Void)?) {
    let chatChanged = self.route.chatId != route.chatId
    let themeChanged = self.isDark != isDark
    appShellRouteLog(
      "ChatConversationController update oldChatId=\(self.route.chatId) newChatId=\(route.chatId) chatChanged=\(chatChanged) themeChanged=\(themeChanged)")
    self.route = route
    self.isDark = isDark
    self.onClose = onClose
    applyRoute(forceChannelRefresh: chatChanged)
    if themeChanged {
      setNeedsStatusBarAppearanceUpdate()
      applySurfaceAppearance(
        Self.resolvedAppearance(isDark: isDark),
        reason: "themeChanged",
        allowDeferUntilAttached: true
      )
    }
  }

  private func startVisibleBridgeStatusPollingIfNeeded() {
    bridgeStatusPollTask?.cancel()
    bridgeStatusPollTask = nil
    guard route.isGroup || route.isChannel || route.bridgeProvider != nil else { return }
    bridgeStatusPollTask = Task { @MainActor [weak self] in
      // Task start/finish arrives as a `bridge-status` push while this chat is open;
      // the loop is only a fallback for a socket that has stopped delivering.
      while !Task.isCancelled, let self, !self.isDismantled {
        if let config = AppSessionConfig.current {
          await AgentPairingService.refreshStatusIfStale(config: config)
        }
        try? await Task.sleep(nanoseconds: AgentPairingService.statusFallbackIntervalNanos)
      }
    }
  }

  func handleNavigationAction(_ action: AppChatNavigationAction) {
    switch action {
    case .avatar:
      pushProfileView(animated: true)
    }
  }

  func represents(_ route: ChatRoute) -> Bool {
    self.route == route
  }

  private func applyRoute(forceChannelRefresh: Bool) {
    view.backgroundColor = Self.backgroundColor(isDark: isDark)
    // Clear any previous bridge-agent connect gate before reconfiguring; the input
    // activation below re-establishes it when the new route is an unconnected agent.
    resetAgentConnectGate()
    currentPage = .chat
    appShellRouteLog(
      "ChatConversationController applyRoute chatId=\(route.chatId) title=\(route.title) forceRefresh=\(forceChannelRefresh) initialRows=\(route.initialRows.count)")

    let deferSurfaceUntilAttached = view.window == nil && !hasAppeared
    postPresentationActivationWorkItem?.cancel()
    postPresentationActivationWorkItem = nil
    didRunPostPresentationActivation = false
    pendingEngineBinding = true
    pendingDeferredEngineStateRefresh = true
    deferredEngineRowsReadyChatId = nil
    if deferSurfaceUntilAttached {
      appShellRouteLog(
        "ChatConversationController deferEngineState chatId=\(route.chatId) reason=prePresentation")
    } else {
      appShellRouteLog(
        "ChatConversationController deferEngineState chatId=\(route.chatId) reason=routeActivation")
    }

    let surfaceId = "native_chat_\(route.chatId)"
    let routeMemberCount = route.members.count
    let resolvedRouteMembers: [[String: Any]] =
      route.isGroup
      ? ChatRoute.resolvedMembers(chatId: route.chatId, routeMembers: route.members)
      : []
    if route.isGroup, route.members.isEmpty, !resolvedRouteMembers.isEmpty {
      // Keep route in sync so the profile push doesn't re-open with 0 members.
      self.route = route.withMembers(resolvedRouteMembers)
    }
    latestProfileRows = route.initialRows
    lastAppliedRowsToSurfaceCount = 0
    mainView.surfaceId = surfaceId
    mainView.setDefersEngineStateRefreshes(true)
    mainView.setDefersTranscriptUpdatesForPresentation(!hasAppeared)
    // Stamp group/channel layout before binding the chat id. setEngineChatId can restore
    // cached row/height state into the presentation queue; setting these flags afterward
    // would invalidate that cache before the post-transition transcript commit.
    let resolvedChannel =
      route.isChannel || GroupProfileActionRouter.resolvedIsChannel(chatId: route.chatId)
    mainView.setIsGroupOrChannel(route.isGroup || route.isChannel || resolvedChannel)
    mainView.setIsChannel(resolvedChannel)
    mainView.setChannelShareLink(route.shareLink ?? "")
    mainView.setGroupMembers(resolvedRouteMembers)
    mainView.setGroupMemberCount(
      route.isGroup ? max(route.roomParticipantCount, resolvedRouteMembers.count) : nil)
    mainView.setRestrictSavingContent(route.isChannel && route.restrictSavingContent)
    if route.isGroup {
      NSLog(
        "[WhoAmI] ChatConversation.applyRoute groupMembers chatId=%@ route=%d resolved=%d",
        String(route.chatId.prefix(12)),
        routeMemberCount,
        resolvedRouteMembers.count
      )
    }
    // Reply palettes are identity-owned. Bind the cached engine identity BEFORE chat id:
    // setEngineChatId can restore and parse a warm seed immediately, and delaying "me"
    // until the post-push engine attach made reply-to-You banners change color on arrival.
    let engineConfig = ChatEngineStore.shared.getConfig()
    if let currentUserId =
      Self.normalizedString(engineConfig["myUserId"])
        ?? Self.normalizedString(engineConfig["userId"])
    {
      engineBindingUserId = currentUserId
      mainView.setEngineMyUserId(currentUserId)
    }
    // Seed route identity before any header/avatar paint. The chat header fallback
    // color is keyed by peer/chat identity, and waiting for the deferred engine
    // binding lets it briefly render from the title-only default seed.
    mainView.setEngineChatId(route.chatId)
    mainView.setEnginePeerUserId(route.peerUserId ?? "")
    mainView.setStatusAuthorityEnabled(false)
    mainView.setEngineChannelBindingEnabled(false)
    if deferSurfaceUntilAttached {
      appShellRouteLog(
        "ChatConversationController deferEngineBinding chatId=\(route.chatId) reason=prePresentation")
    } else {
      configureEngineBindingIfNeeded(reason: "applyRoute", enableStatusAuthority: false)
    }
    // Theme/header masking is local UI state. Paint it before presentation instead of
    // tying the safe-area chrome to engine attachment or the first transcript layout.
    applySurfaceAppearance(
      Self.resolvedAppearance(isDark: isDark),
      reason: "applyRoute",
      allowDeferUntilAttached: false
    )
    appShellRouteLog(
      "ChatConversationController configureRouteSurfaceStart chatId=\(route.chatId) reason=applyRoute")
    markRouteSurfaceStep("header")
    mainView.setHeaderMode(route.chatId == "saved_messages" ? "savedmessages" : "default")
    mainView.setBridgeProvider(route.bridgeProvider ?? "")
    mountPreferredAgentSurfaceIfNeeded(reason: "applyRoute")
    mainView.setHeaderTitle(route.title)
    mainView.setHeaderUnreadCount(route.unreadCount)
    mainView.setOpeningUnreadCount(route.unreadCount)
    mainView.setProfileName(route.title)
    mainView.setProfileHandle(Self.profileHandle(for: route))
    mainView.setProfileBio(route.roomDescription ?? "")
    markRouteSurfaceStep("avatar")
    mainView.setAvatarUri(route.avatarURI)
    markRouteSurfaceStep("groupAndInput")
    // When the chat talks to an AI agent, bind the agent id so the engine routes
    // sends to the agent backend (peerAgentId) instead of E2E-encrypting to a
    // human peer. Empty string clears it for normal peer/group chats.
    mainView.setEnginePeerAgentId(route.peerAgentId ?? "")
    appShellRouteLog(
      "ChatConversationController agentRouting chatId=\(route.chatId) peerUserId=\(route.peerUserId ?? "nil") peerAgentId=\(route.peerAgentId ?? "nil") bridgeProvider=\(route.bridgeProvider ?? "nil") isAgent=\(route.isAgent) isAgentChat=\(route.isAgentChat)")
    // Inbox mode: when the attached agent batches events, the chat view keeps the
    // transcript clean and surfaces event notifications behind the Inbox banner.
    mainView.setAgentEventInboxMode(enabled: route.isAgentInboxMode)
    refreshPersistentAgentInboxSummary()
    mainView.setInputPlaceholder(
      route.chatId == "saved_messages"
        ? "Saved Message"
        : (route.isAgentChat ? "Message \(route.title)" : "Message"))
    // Mount the composer while the controller is being configured. Normal/group chats
    // are immediately usable; bridge chats still pass through applyAgentConnectGate and
    // therefore preserve their paired-computer requirement.
    applyInputActivation(reason: deferSurfaceUntilAttached ? "applyRoute-prePresentation" : "applyRoute")
    markRouteSurfaceStep("page")
    mainView.setStandaloneProfileMode(false)
    // setStandaloneProfileMode(false) re-enables the composer — re-assert the
    // bridge-agent gate so an unconnected Claude/Codex/Grok chat stays input-less.
    if let provider = route.bridgeProvider, !provider.isEmpty,
      !bridgeConnectedThisSession
    {
      applyAgentConnectGate(provider: provider, reason: "applyRoute-afterProfileMode")
    }
    mainView.setPage(ChatConversationPage.chat.rawValue, animated: false)
    removeProfileView(animated: false)
    appShellRouteLog(
      "ChatConversationController configuredSurface chatId=\(route.chatId) surfaceId=\(surfaceId) peerUserId=\(route.peerUserId ?? "") isGroup=\(route.isGroup) headerMode=\(route.chatId == "saved_messages" ? "savedmessages" : "default") windowAttached=\(view.window != nil)")

    refreshRouteOnlyHeaderState()
    refreshRows(preferInitialRows: true)
    logVisualState("afterApplyRoute", force: true)

    if forceChannelRefresh {
      closeOpenedChatChannel()
    }
    if hasAppeared, view.window != nil {
      schedulePostPresentationActivation(reason: "applyRouteAttached")
    } else {
      appShellRouteLog(
        "ChatConversationController deferOpenChatChannel chatId=\(route.chatId) reason=prePresentation hasAppeared=\(hasAppeared) windowAttached=\(view.window != nil)")
    }
  }

  private func markRouteSurfaceStep(_ step: String) {
    AppUIStallWatchdog.shared.updateContext(
      "ChatConversationController configureRouteSurface.\(step) chatId=\(route.chatId) reason=applyRoute"
    )
  }

  private func mountPreferredAgentSurfaceIfNeeded(reason: String) {
    guard let provider = route.bridgeProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
      !provider.isEmpty
    else { return }
    appShellRouteLog(
      "ChatConversationController primaryAgentMountAttempt chatId=\(route.chatId) provider=\(provider) reason=\(reason) windowAttached=\(view.window != nil) hasAppeared=\(hasAppeared)")
    mainView.presentPreferredAgentViewNow(provider: provider)
  }

  private func applySurfaceAppearance(
    _ appearance: [String: Any],
    reason: String,
    allowDeferUntilAttached: Bool
  ) {
    if allowDeferUntilAttached, view.window == nil {
      pendingAppearanceForAttachment = appearance
      appShellRouteLog(
        "ChatConversationController deferAppearance chatId=\(route.chatId) reason=\(reason) windowAttached=false")
      return
    }
    pendingAppearanceForAttachment = nil
    let startedAt = CFAbsoluteTimeGetCurrent()
    AppUIStallWatchdog.shared.updateContext(
      "ChatConversationController setAppearance chatId=\(route.chatId) reason=\(reason)"
    )
    appShellRouteLog(
      "ChatConversationController setAppearanceStart chatId=\(route.chatId) reason=\(reason)")
    mainView.setAppearance(appearance)
    profileView?.setAppearance(appearance)
    let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
    appShellRouteLog(
      "ChatConversationController setAppearanceDone chatId=\(route.chatId) reason=\(reason) durationMs=\(durationMs)")
  }

  private func applyPendingAppearanceAfterAttachment(reason: String) {
    guard view.window != nil, let appearance = pendingAppearanceForAttachment else { return }
    appShellRouteLog(
      "ChatConversationController applyDeferredAppearance chatId=\(route.chatId) reason=\(reason)")
    applySurfaceAppearance(
      appearance,
      reason: "\(reason)-deferred",
      allowDeferUntilAttached: false
    )
  }

  private func applyInputActivation(reason: String) {
    pendingInputActivationForAttachment = false
    // Computer-bridge agents gate the composer behind a paired computer.
    if let provider = route.bridgeProvider, !provider.isEmpty, !bridgeConnectedThisSession {
      applyAgentConnectGate(provider: provider, reason: reason)
      return
    }
    let startedAt = CFAbsoluteTimeGetCurrent()
    AppUIStallWatchdog.shared.updateContext(
      "ChatConversationController inputActivation chatId=\(route.chatId) reason=\(reason)"
    )
    appShellRouteLog(
      "ChatConversationController inputActivationStart chatId=\(route.chatId) reason=\(reason)")
    mainView.setInputBarEnabled(true)
    mainView.setNativeSendEnabled(true)
    let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
    appShellRouteLog(
      "ChatConversationController inputActivationDone chatId=\(route.chatId) reason=\(reason) durationMs=\(durationMs)")
  }

  // MARK: - Agent bridge connect gate

  /// Hides the composer and shows the Connect panel for an unconnected bridge
  /// agent. The panel polls bridge status and calls back once a computer is online.
  private func applyAgentConnectGate(provider: String, reason: String) {
    // Already known online (warm status cache) → never flash the panel; just reveal
    // the composer. This is the fix for the "we're connected but it shows Connect,
    // then jumps to no panel" flicker on reopen.
    if latestBridgeStatusConnected() {
      let fresh = AgentPairingService.statusIsFresh()
      VibeDebugLog.log(
        "[ChatOpen] connectGate WARM-CONNECTED→input chatId=%@ provider=%@ fresh=%@ reverify=%@",
        String(route.chatId.prefix(12)), provider, fresh ? "Y" : "N", fresh ? "N" : "Y")
      handleBridgeConnected()
      // Only re-verify when the cached status is STALE. If it was just warmed (home
      // appear / a recent open), a redundant poll here is the very thing that flips the
      // composer back to the connect panel for a beat — trust the fresh snapshot.
      if !fresh {
        verifyWarmBridgeConnection(provider: provider, reason: reason)
      }
      return
    }

    appShellRouteLog(
      "ChatConversationController agentConnectGate chatId=\(route.chatId) provider=\(provider) reason=\(reason)")
    mainView.setInputBarEnabled(false)
    mainView.setNativeSendEnabled(false)

    let model: AgentConnectModel
    if let existing = agentConnectModel {
      model = existing
    } else {
      let created = AgentConnectModel(
        provider: provider,
        displayName: ChatRoute.bridgeDisplayName(for: provider)
      )
      created.onConnected = { [weak self] in
        self?.handleBridgeConnected()
      }
      agentConnectModel = created
      model = created
    }

    // Already showing (or already verifying/scheduled to show) — just keep polling.
    guard agentConnectHost == nil, pendingConnectPanelWork == nil, pendingConnectStatusTask == nil else {
      model.startPolling()
      return
    }
    model.startPolling()

    // Fresh warm status that says OFFLINE → present the connect panel immediately from
    // the cached snapshot instead of hiding the composer and awaiting another network
    // poll (the second source of open-time latency). The model keeps polling and flips
    // to the composer the moment the computer comes online.
    if AgentPairingService.statusIsFresh(), AgentPairingService.lastConnected == false {
      if let snapshot = AgentPairingService.lastStatusSnapshot {
        model.status = snapshot
        model.selectedRepository = AgentBridgeSelectionStore.ensureValidSelection(
          from: snapshot.repositories)
      }
      VibeDebugLog.log(
        "[ChatOpen] connectGate FRESH-OFFLINE→panel chatId=%@ provider=%@",
        String(route.chatId.prefix(12)), provider)
      presentAgentConnectPanel(model: model)
      return
    }
    VibeDebugLog.log(
      "[ChatOpen] connectGate COLD→hideInput+poll chatId=%@ provider=%@ (no fresh status)",
      String(route.chatId.prefix(12)), provider)

    let chatId = route.chatId
    let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    pendingConnectStatusTask = Task { [weak self, weak model] in
      var status: AgentBridgeStatus?
      if let config = AppSessionConfig.current {
        status = try? await AgentPairingService.statusCoalesced(config: config)
      }
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self, let model, !Task.isCancelled else { return }
        self.pendingConnectStatusTask = nil
        let currentProvider = self.route.bridgeProvider?
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased() ?? ""
        guard self.route.chatId == chatId, currentProvider == normalizedProvider else { return }
        if let status {
          model.status = status
          model.selectedRepository = AgentBridgeSelectionStore.ensureValidSelection(from: status.repositories)
        }
        if status?.connected == true || self.latestBridgeStatusConnected() {
          self.handleBridgeConnected()
          return
        }
        guard !self.bridgeConnectedThisSession, self.agentConnectHost == nil else { return }
        self.presentAgentConnectPanel(model: model)
      }
    }
  }

  private func latestBridgeStatusConnected() -> Bool {
    AgentPairingService.lastConnected
      || AgentPairingService.lastStatusSnapshot?.connected == true
      || AgentPairingService.lastStatus?.connected == true
  }

  private func verifyWarmBridgeConnection(provider: String, reason: String) {
    let chatId = route.chatId
    let normalizedProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    pendingConnectStatusTask?.cancel()
    pendingConnectStatusTask = Task { [weak self] in
      guard let config = AppSessionConfig.current else { return }
      let status = try? await AgentPairingService.statusCoalesced(config: config)
      guard !Task.isCancelled, status?.connected == false else {
        await MainActor.run { self?.pendingConnectStatusTask = nil }
        return
      }
      await MainActor.run {
        guard let self, !Task.isCancelled else { return }
        self.pendingConnectStatusTask = nil
        let currentProvider = self.route.bridgeProvider?
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .lowercased() ?? ""
        guard self.route.chatId == chatId, currentProvider == normalizedProvider else { return }
        self.bridgeConnectedThisSession = false
        self.applyAgentConnectGate(provider: provider, reason: "\(reason)-verifiedOffline")
      }
    }
  }

  private func presentAgentConnectPanel(model: AgentConnectModel) {
    guard agentConnectHost == nil else { return }
    let host = UIHostingController(rootView: AgentConnectPanel(model: model))
    host.view.backgroundColor = .clear
    addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
    ])
    host.didMove(toParent: self)
    agentConnectHost = host
  }

  private func handleBridgeConnected() {
    guard !bridgeConnectedThisSession else { return }
    bridgeConnectedThisSession = true
    pendingConnectStatusTask?.cancel()
    pendingConnectStatusTask = nil
    pendingConnectPanelWork?.cancel()
    pendingConnectPanelWork = nil
    appShellRouteLog(
      "ChatConversationController agentBridgeConnected chatId=\(route.chatId)")
    removeAgentConnectPanel()
    mainView.setInputBarEnabled(true)
    mainView.setNativeSendEnabled(true)
  }

  private func removeAgentConnectPanel() {
    pendingConnectPanelWork?.cancel()
    pendingConnectPanelWork = nil
    pendingConnectStatusTask?.cancel()
    pendingConnectStatusTask = nil
    agentConnectModel?.stopPolling()
    if let host = agentConnectHost {
      host.willMove(toParent: nil)
      host.view.removeFromSuperview()
      host.removeFromParent()
    }
    agentConnectHost = nil
  }

  private func presentBridgeRepositoryPicker(provider: String) {
    let displayName = ChatRoute.bridgeDisplayName(for: provider)
    let root = AgentBridgeRepositoryPickerView(
      provider: provider, displayName: displayName, chatId: route.chatId)
      .preferredColorScheme(isDark ? .dark : .light)
    let host = UIHostingController(rootView: root)
    host.modalPresentationStyle = .pageSheet
    host.view.backgroundColor = .clear
    if let sheet = host.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 28
    }
    present(host, animated: true)
  }

  /// The bubble chat header's title/subtitle tap for bridge chats — live or idle — opens
  /// this instead of the profile (see `handleTitlePressed`/`agentSessionPressed` in
  /// ChatMainView). Picking a past session loads its transcript into THIS chat via the same
  /// `loadAgentBridgeSessionIntoChat` ingestion the full-page agent view uses; the bubble
  /// view has no "fresh session only" filter, so the rows land through the normal
  /// `ChatEngine.didChangeNotification` → `refreshRows()` path.
  private func presentAgentSessionHistorySheet(provider: String) {
    let status = AgentPairingService.lastStatusSnapshot
    let host = UIHostingController(
      rootView: AgentBridgeHistorySheet(
        provider: provider,
        chatId: route.chatId,
        runningTasks: status?.runningTasks ?? [],
        deviceLabel: AgentPairingService.lastDeviceLabel ?? "",
        connected: AgentPairingService.lastConnected,
        paired: status?.paired ?? false,
        onPick: { [weak self] session in
          self?.loadBridgeSessionIntoChat(provider: provider, session: session)
        }
      )
      .preferredColorScheme(isDark ? .dark : .light)
    )
    host.view.backgroundColor = .clear
    present(host, animated: true)
  }

  private func loadBridgeSessionIntoChat(provider: String, session: AgentBridgeHistorySession) {
    let sessionId = session.resolvedSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sessionId.isEmpty, !sessionId.hasPrefix("running:") else { return }
    // One path with ChatListView: seed header title, show the custom skeleton
    // spinner until rows land, scope historical isolation, and request detail.
    // (Previously this only set the session id + engine load — list went empty
    // with no spinner and the header stayed on "Start session".)
    mainView.loadBridgeHistorySession(provider: provider, session: session)
  }

  /// Clears any active connect gate (used when the host is reused for another chat).
  private func resetAgentConnectGate() {
    removeAgentConnectPanel()
    agentConnectModel = nil
    bridgeConnectedThisSession = false
  }

  private func applyPendingInputActivationAfterAttachment(reason: String) {
    guard view.window != nil, pendingInputActivationForAttachment else { return }
    applyInputActivation(reason: "\(reason)-deferred")
  }

  private func schedulePostPresentationActivation(reason: String) {
    guard view.window != nil, hasAppeared else { return }
    guard !didRunPostPresentationActivation else {
      openChatChannelIfNeeded(reason: "\(reason)-alreadyActivated")
      return
    }
    let chatId = route.chatId
    postPresentationActivationWorkItem?.cancel()
    appShellRouteLog(
      "ChatConversationController schedulePostPresentationActivation chatId=\(chatId) reason=\(reason) delayMs=\(Int(Self.postPresentationActivationDelay * 1000))")
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.route.chatId == chatId, self.view.window != nil, self.hasAppeared else {
        return
      }
      self.didRunPostPresentationActivation = true
      appShellRouteLog(
        "ChatConversationController postPresentationActivation chatId=\(chatId) reason=\(reason)")
      self.configureEngineBindingIfNeeded(
        reason: "\(reason)-postTransition",
        enableStatusAuthority: !self.route.skipsServerChannel && self.route.bridgeProvider == nil
      )
      self.completeDeferredEngineStateRefreshIfNeeded(chatId: chatId)
      self.openChatChannelIfNeeded(reason: "\(reason)-postTransition")
      AppUIStallWatchdog.shared.updateContext(
        "ChatConversationController postPresentationActivation DONE chatId=\(chatId)"
      )
    }
    postPresentationActivationWorkItem = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.postPresentationActivationDelay,
      execute: work
    )
  }

  private func configureEngineBindingIfNeeded(reason: String, enableStatusAuthority: Bool) {
    if route.skipsServerChannel {
      let bindingKey = [
        "local_saved_messages",
        route.chatId,
        "deferred",
      ].joined(separator: "|")
      guard pendingEngineBinding || engineBindingKey != bindingKey else { return }
      pendingEngineBinding = false
      engineBindingKey = bindingKey
      appShellRouteLog(
        "ChatConversationController engineBindingStart chatId=\(route.chatId) reason=\(reason) statusAuthority=N savedMessages=Y")
      mainView.setEngineChannelBindingEnabled(false)
      mainView.setStatusAuthorityEnabled(false)
      appShellRouteLog(
        "ChatConversationController engineBindingSkipSurface chatId=\(route.chatId) reason=\(reason) savedMessages=Y")
      mainView.setEngineSurfaceId("")
      mainView.setEngineChatId(route.chatId)
      mainView.setEnginePeerUserId("")
      loadEngineBindingUserId(chatId: route.chatId, reason: reason)
      appShellRouteLog(
        "ChatConversationController engineBindingDone chatId=\(route.chatId) reason=\(reason) statusAuthority=N savedMessages=Y")
      return
    }

    let surfaceId = "native_chat_\(route.chatId)"
    let bindingKey = [
      surfaceId,
      route.chatId,
      route.peerUserId ?? "",
      enableStatusAuthority ? "status" : "deferred",
    ].joined(separator: "|")
    guard pendingEngineBinding || engineBindingKey != bindingKey else { return }
    pendingEngineBinding = false
    engineBindingKey = bindingKey
    appShellRouteLog(
      "ChatConversationController engineBindingStart chatId=\(route.chatId) reason=\(reason) statusAuthority=\(enableStatusAuthority ? "Y" : "N")")
    mainView.setEngineChannelBindingEnabled(false)
    mainView.setStatusAuthorityEnabled(false)
    appShellRouteLog(
      "ChatConversationController engineBindingSetSurface chatId=\(route.chatId) reason=\(reason)")
    mainView.setEngineSurfaceId(surfaceId)
    appShellRouteLog(
      "ChatConversationController engineBindingSetChatId chatId=\(route.chatId) reason=\(reason)")
    mainView.setEngineChatId(route.chatId)
    appShellRouteLog(
      "ChatConversationController engineBindingSetPeer chatId=\(route.chatId) reason=\(reason)")
    mainView.setEnginePeerUserId(route.peerUserId ?? "")
    if enableStatusAuthority {
      appShellRouteLog(
        "ChatConversationController engineBindingEnableStatus chatId=\(route.chatId) reason=\(reason)")
      mainView.setStatusAuthorityEnabled(true)
    }
    loadEngineBindingUserId(chatId: route.chatId, reason: reason)
    appShellRouteLog(
      "ChatConversationController engineBindingDone chatId=\(route.chatId) reason=\(reason) statusAuthority=\(enableStatusAuthority ? "Y" : "N")")
  }

  private func loadEngineBindingUserId(chatId: String, reason: String) {
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let config = ChatEngineStore.shared.getConfig()
      let myUserId =
        Self.normalizedString(config["myUserId"])
        ?? Self.normalizedString(config["userId"])
      guard let myUserId else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.route.chatId == chatId else { return }
        guard self.engineBindingUserId != myUserId else { return }
        self.engineBindingUserId = myUserId
        AppUIStallWatchdog.shared.updateContext(
          "[AppShellRoute] ChatConversationController engineBindingApplyUserId chatId=\(chatId) reason=\(reason)"
        )
        self.mainView.setEngineMyUserId(myUserId)
        AppUITrace.notice(
          "[AppShellRoute] ChatConversationController engineBindingUserIdApplied chatId=\(chatId) reason=\(reason)"
        )
        AppUIStallWatchdog.shared.updateContext("")
      }
    }
  }

  private func openChatChannelIfNeeded(reason: String) {
    guard openedChatId != route.chatId else { return }
    let chatId = route.chatId
    let peerUserId = route.peerUserId ?? ""
    openedChatId = chatId
    if route.skipsServerChannel {
      openedChatIdUsesEngineChannel = false
      appShellRouteLog(
        "ChatConversationController openChatChannel skipped chatId=\(chatId) reason=\(reason) localSurface=Y")
      return
    }
    openedChatIdUsesEngineChannel = true
    appShellRouteLog(
      "ChatConversationController openChatChannel scheduled chatId=\(chatId) peerUserId=\(peerUserId) reason=\(reason) windowAttached=\(view.window != nil) hasAppeared=\(hasAppeared)")
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self else { return }
      let startedAt = CFAbsoluteTimeGetCurrent()
      appShellRouteLog(
        "ChatConversationController openChatChannel backgroundStart chatId=\(chatId) reason=\(reason)")
      let snapshot = ChatEngine.shared.openChatChannel([
        "chatId": chatId,
        "peerUserId": peerUserId,
      ])
      let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
      appShellRouteLog(
        "ChatConversationController openChatChannel backgroundDone chatId=\(chatId) reason=\(reason) durationMs=\(durationMs)")
      self.appRouteLogOpenResult(chatId: chatId, snapshot: snapshot)
    }
    AppUIStallWatchdog.shared.updateContext(
      "ChatConversationController openChatChannelIfNeeded DONE chatId=\(chatId)"
    )
  }

  private func closeOpenedChatChannel() {
    guard let openedChatId else { return }
    let usesEngineChannel = openedChatIdUsesEngineChannel
    self.openedChatId = nil
    openedChatIdUsesEngineChannel = false
    guard usesEngineChannel else { return }
    let windowAttachedAtSchedule: Bool?
    if Thread.isMainThread {
      windowAttachedAtSchedule = view.window != nil
    } else {
      windowAttachedAtSchedule = nil
    }
    let windowAttachedLabel = windowAttachedAtSchedule.map { String($0) } ?? "unknown"
    appShellRouteLog(
      "ChatConversationController closeChatChannel scheduled chatId=\(openedChatId) windowAttached=\(windowAttachedLabel) mainThread=\(Thread.isMainThread)")
    DispatchQueue.global(qos: .utility).async {
      let snapshot = ChatEngine.shared.closeChatChannel(["chatId": openedChatId])
      let state = Self.normalizedString(snapshot["state"]) ?? "nil"
      let openCount = snapshot["openChatChannelCount"] as? Int ?? -1
      appShellRouteLog(
        "ChatConversationController closeChatChannel finished chatId=\(openedChatId) state=\(state) openChatCount=\(openCount)")
    }
  }

  private func refreshRows(
    preferInitialRows: Bool = false,
    allowAuthoritativeEmpty: Bool = false
  ) {
    rowsRefreshGeneration &+= 1
    let generation = rowsRefreshGeneration
    let chatId = route.chatId
    let initialRows = route.initialRows
    if preferInitialRows {
      // Seed ONLY from the route's in-memory initialRows here — NEVER a synchronous
      // engine read. getChatRows() blocks on the engine's serial queue, which is busy
      // loading history when a chat opens, so calling it here (viewDidLoad, before the
      // push animation) stalled the push by 1–2s for content-heavy chats. The full
      // cached transcript is fetched OFF-THREAD by the async block below. The list
      // coalesces it with this bounded seed and commits only after viewDidAppear, keeping
      // all transcript measurement outside the navigation transaction.
      let firstRowID =
        Self.normalizedString(initialRows.first?["id"])
        ?? Self.normalizedString(initialRows.first?["messageId"])
        ?? "nil"
      VibeDebugLog.log(
        "[ChatOpen] refreshRows seed chatId=%@ initialRows=%d source=initial window=%@ up=%.2f",
        String(chatId.prefix(12)), initialRows.count, view.window != nil ? "Y" : "N",
        ProcessInfo.processInfo.systemUptime)
      // Empty initial seed is worse than nothing — skip applying 0 rows so we don't
      // force an empty paint before the async engine seed lands.
      if !initialRows.isEmpty {
        let didApply = applyRowsToSurface(
          initialRows,
          chatId: chatId,
          source: "initial",
          firstRowID: firstRowID,
          // ChatListView safely accepts rows at 0×0 and explicitly reloads them on
          // its first real-bounds layout. Pre-applying this bounded tail prevents the
          // child list from rendering one empty wallpaper frame before the parent
          // controller consumes its attachment queue.
          allowDeferUntilAttached: false
        )
        if didApply {
          deferredEngineRowsReadyChatId = chatId
          completeDeferredEngineStateRefreshIfNeeded(chatId: chatId)
          settleInitialBottomIfNeeded(reason: "initialRows")
        }
      }
    }

    // Kick the engine read ASAP off-main, but let ChatListView hold its result until the
    // navigation transaction has completed. This overlaps I/O with the push without
    // allowing collection measurement to steal animation frames.
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let nativeRows = ChatEngine.shared.getChatRows(["chatId": chatId])
      // Read this beside the rows, off-main, so "0 rows" has an authority bit attached
      // to the same engine snapshot. Empty while a fetch is still in flight is merely a
      // loading state; empty after a successful history resolution is the transcript.
      // Without this distinction a stale reopen raster can sit over a genuinely empty
      // chat forever, looking like a real but untouchable message.
      let historyIsResolved = ChatEngine.shared.isChatHistoryLoaded(chatId: chatId)
      DispatchQueue.main.async { [weak self] in
        guard let self, self.route.chatId == chatId, self.rowsRefreshGeneration == generation else {
          return
        }
        if nativeRows.isEmpty, allowAuthoritativeEmpty || historyIsResolved {
          self.pendingRowsForAttachment = nil
          self.pendingRowsForAttachmentChatId = nil
          self.pendingRowsForAttachmentSource = nil
          self.latestProfileRows = []
          self.lastAppliedRowsToSurfaceCount = 0
          self.mainView.clearRows()
          self.profileView?.setRows([])
          NSLog(
            "[ChatOpen] controller authoritative-empty chat=%@ source=%@ historyResolved=%@ — cleared rows and stale raster",
            String(chatId.prefix(12)),
            allowAuthoritativeEmpty ? "explicit-delete" : "history",
            historyIsResolved ? "Y" : "N")
          return
        }
        // Never wipe a visible transcript with a transient empty engine read.
        // ChatListView early-seeds from disk/engine during push; a concurrent empty
        // getChatRows (history still loading) used to apply 0 rows and flash wallpaper.
        let isBridgeDM = !(self.route.bridgeProvider ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasVisibleRows =
          !self.latestProfileRows.isEmpty || self.lastAppliedRowsToSurfaceCount > 0
        if nativeRows.isEmpty, hasVisibleRows {
          NSLog(
            "[ChatOpen] refreshRows KEEP visible chat=%@ retained=%d lastApplied=%d initial=%d (skip empty wipe)",
            String(chatId.prefix(12)),
            self.latestProfileRows.count,
            self.lastAppliedRowsToSurfaceCount,
            initialRows.count)
          return
        }
        let fallbackSource: String = {
          if !self.latestProfileRows.isEmpty { return "retained" }
          if isBridgeDM { return "initial" }
          return "initial"
        }()
        let fallbackRows =
          !self.latestProfileRows.isEmpty ? self.latestProfileRows : initialRows
        let rows = nativeRows.isEmpty ? fallbackRows : nativeRows
        // Still empty after fallback — skip applying 0 so we don't force blank paint
        // before history/chatRowsReloaded lands.
        if rows.isEmpty {
          NSLog(
            "[ChatOpen] refreshRows SKIP empty chat=%@ native=0 initial=%d retained=%d",
            String(chatId.prefix(12)), initialRows.count, self.latestProfileRows.count)
          return
        }
        let firstRowID =
          Self.normalizedString(rows.first?["id"])
          ?? Self.normalizedString(rows.first?["messageId"])
          ?? "nil"
        appShellRouteLog(
          "ChatConversationController refreshRows chatId=\(chatId) rows=\(rows.count) nativeRows=\(nativeRows.count) initialRows=\(initialRows.count) retainedRows=\(self.latestProfileRows.count) source=\(nativeRows.isEmpty ? fallbackSource : "native") firstRowId=\(firstRowID)")
        let didApply = self.applyRowsToSurface(
          rows,
          chatId: chatId,
          source: nativeRows.isEmpty ? fallbackSource : "native",
          firstRowID: firstRowID,
          allowDeferUntilAttached: true
        )
        if didApply {
          self.deferredEngineRowsReadyChatId = chatId
          self.completeDeferredEngineStateRefreshIfNeeded(chatId: chatId)
          self.settleInitialBottomIfNeeded(reason: "refreshRows")
          self.logVisualState("afterRefreshRows")
        }
      }
    }
  }

  private func refreshPersistentAgentInboxSummary() {
    guard route.isAgentInboxMode,
      let agentID = route.peerAgentId,
      !agentID.isEmpty,
      let config = AppSessionConfig.current
    else { return }

    Task { [weak self] in
      guard let self else { return }
      do {
        let page = try await AgentInboxAPI.loadPage(
          agentID: agentID,
          config: config,
          limit: 1,
          offset: 0
        )
        let preview = page.items.first.map { item in
          item.body.isEmpty ? item.title : item.body
        }
        await MainActor.run {
          guard self.route.peerAgentId == agentID else { return }
          self.mainView.setPersistentAgentEventInbox(
            count: page.total,
            latestPreview: preview
          )
        }
      } catch {
        // The chat-row fallback remains visible if the persistent request fails.
      }
    }
  }

  @discardableResult
  private func applyRowsToSurface(
    _ rows: [[String: Any]],
    chatId: String,
    source: String,
    firstRowID: String,
    allowDeferUntilAttached: Bool
  ) -> Bool {
    latestProfileRows = rows
    guard route.chatId == chatId else { return false }
    if allowDeferUntilAttached, view.window == nil {
      pendingRowsForAttachment = rows
      pendingRowsForAttachmentChatId = chatId
      pendingRowsForAttachmentSource = source
      VibeDebugLog.log(
        "[ChatOpen] applyRows DEFER chatId=%@ rows=%d source=%@ hasAppeared=%@ (window nil)",
        String(chatId.prefix(12)), rows.count, source, hasAppeared ? "Y" : "N")
      return false
    }
    VibeDebugLog.log(
      "[ChatOpen] applyRows APPLY chatId=%@ rows=%d source=%@ window=%@ hasAppeared=%@ up=%.2f",
      String(chatId.prefix(12)), rows.count, source, view.window != nil ? "Y" : "N",
      hasAppeared ? "Y" : "N", ProcessInfo.processInfo.systemUptime)

    let startedAt = CFAbsoluteTimeGetCurrent()
    AppUIStallWatchdog.shared.updateContext(
      "ChatConversationController setRows chatId=\(chatId) rows=\(rows.count) source=\(source)"
    )
    // UIKit lays out top-down one level per pass, so the host view can already be at
    // full size while the deep collectionView inside the list is still 0×0 (its own
    // layoutSubviews hasn't run yet). A setRows into a 0×0 list reloads zero cells and
    // computes contentSize=0 — the transcript then stays blank until a later layout pass
    // finally sizes the list (the "empty for ~1s then pops in" flash). Force the whole
    // subtree to adopt the host's real bounds NOW so the rows render into a correctly
    // sized list on this runloop.
    if hasAppeared, view.window != nil, view.bounds.width > 1, view.bounds.height > 1 {
      view.layoutIfNeeded()
    }
    if source == "native" || source.hasPrefix("native-") {
      mainView.setAuthoritativeRows(rows)
    } else {
      mainView.setRows(rows)
    }
    lastAppliedRowsToSurfaceCount = rows.count
    if currentPage == .profile {
      profileView?.setRows(rows)
    }
    let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
    VibeDebugLog.log(
      "[ChatOpen] applyRows DONE chatId=%@ rows=%d source=%@ durationMs=%d up=%.2f",
      String(chatId.prefix(12)), rows.count, source, durationMs,
      ProcessInfo.processInfo.systemUptime)
    appShellRouteLog(
      "ChatConversationController setRowsApplied chatId=\(chatId) rows=\(rows.count) source=\(source) durationMs=\(durationMs) firstRowId=\(firstRowID)")
    return true
  }

  private func applyPendingRowsAfterAttachment(reason: String) {
    guard view.window != nil else { return }
    // Hold the pending payload until the host actually has a real size. viewWillAppear
    // fires while the view is in the window but still 0×0 (pre-transition); applying
    // rows there would render into an unsized list AND consume the payload, so the
    // later viewDidLayoutSubviews pass (real bounds) would have nothing to apply. Wait
    // for that real-bounds pass so the rows land in a correctly-sized list.
    guard view.bounds.width > 1, view.bounds.height > 1 else {
      VibeDebugLog.log(
        "[ChatOpen] applyPendingRows WAIT reason=%@ chatId=%@ (host not sized %.0fx%.0f) pending=%@",
        reason, String(route.chatId.prefix(12)), view.bounds.width, view.bounds.height,
        pendingRowsForAttachment != nil ? "Y" : "N")
      return
    }
    guard let rows = pendingRowsForAttachment,
      let chatId = pendingRowsForAttachmentChatId,
      chatId == route.chatId
    else { return }
    let source = pendingRowsForAttachmentSource ?? "pending"
    pendingRowsForAttachment = nil
    pendingRowsForAttachmentChatId = nil
    pendingRowsForAttachmentSource = nil
    let firstRowID =
      Self.normalizedString(rows.first?["id"])
      ?? Self.normalizedString(rows.first?["messageId"])
      ?? "nil"
    appShellRouteLog(
      "ChatConversationController applyDeferredRows reason=\(reason) chatId=\(chatId) rows=\(rows.count) source=\(source)")
    let didApply = applyRowsToSurface(
      rows,
      chatId: chatId,
      source: "\(source)-deferred",
      firstRowID: firstRowID,
      allowDeferUntilAttached: false
    )
    if didApply {
      deferredEngineRowsReadyChatId = chatId
      completeDeferredEngineStateRefreshIfNeeded(chatId: chatId)
      logVisualState("afterApplyDeferredRows", force: true)
    }
  }

  private func completeDeferredEngineStateRefreshIfNeeded(chatId: String) {
    guard didRunPostPresentationActivation else { return }
    guard hasAppeared, pendingDeferredEngineStateRefresh, route.chatId == chatId,
      deferredEngineRowsReadyChatId == chatId
    else { return }
    pendingDeferredEngineStateRefresh = false
    deferredEngineRowsReadyChatId = nil
    appShellRouteLog(
      "ChatConversationController completeDeferredEngineState chatId=\(chatId)")
    configureEngineBindingIfNeeded(
      reason: "completeDeferredEngineState",
      enableStatusAuthority: !route.skipsServerChannel && route.bridgeProvider == nil
    )
    mainView.setDefersEngineStateRefreshes(false)
    mainView.refreshEngineStateAfterDeferredRouteOpen()
    refreshHeaderState()
  }

  private func appRouteLogOpenResult(chatId: String, snapshot: [String: Any]) {
    let state = Self.normalizedString(snapshot["state"]) ?? "nil"
    let openCount = snapshot["openChatChannelCount"] as? Int ?? -1
    let joinedCount = snapshot["nativeJoinedChatCount"] as? Int ?? -1
    let boundSurfaceCount = snapshot["boundSurfaceCount"] as? Int ?? -1
    AppUITrace.notice(
      "[AppShellRoute] ChatConversationController openChatChannelResult chatId=\(chatId) state=\(state) connected=\(snapshot["connected"] as? Bool == true ? "true" : "false") openChatCount=\(openCount) joinedChatCount=\(joinedCount) boundSurfaceCount=\(boundSurfaceCount) keyCount=\(snapshot.count)"
    )
  }

  private func settleInitialBottomIfNeeded(reason: String) {
    guard !didInitialScroll else { return }
    guard view.bounds.width > 0.0, view.bounds.height > 0.0 else { return }
    guard lastAppliedRowsToSurfaceCount > 0 else {
      appShellRouteLog(
        "ChatConversationController deferInitialScroll reason=\(reason) chatId=\(route.chatId) rowsReady=false")
      return
    }
    guard view.window != nil else {
      appShellRouteLog(
        "ChatConversationController deferInitialScroll reason=\(reason) chatId=\(route.chatId) windowAttached=false")
      return
    }
    didInitialScroll = true
    let startedAt = CFAbsoluteTimeGetCurrent()
    AppUIStallWatchdog.shared.updateContext(
      "ChatConversationController initialScroll chatId=\(route.chatId) reason=\(reason)"
    )
    mainView.layoutIfNeeded()
    mainView.scrollToBottom(animated: false)
    let durationMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
    appShellRouteLog(
      "ChatConversationController initialScrollToBottomCompleted reason=\(reason) chatId=\(route.chatId) durationMs=\(durationMs)")
    logLifecycle("initialScrollToBottom reason=\(reason)")
    logVisualState("afterInitialScroll", force: true)
  }

  private func refreshHeaderState() {
    let route = route
    let handle = Self.profileHandle(for: route)
    DispatchQueue.global(qos: .utility).async { [weak self] in
      let subtitle = Self.headerSubtitle(for: route)
      let isOnline = route.hasPeerResponse ? Self.isOnline(for: route) : false
      DispatchQueue.main.async { [weak self] in
        guard let self, self.route == route else { return }
        self.mainView.setHeaderSubtitle(subtitle)
        self.mainView.setIsOnline(isOnline)
        self.mainView.setProfileHandle(handle)
        self.profileView?.setHeaderSubtitle(subtitle)
        self.profileView?.setIsOnline(isOnline)
        self.profileView?.setProfileHandle(handle)
      }
    }
  }

  private func refreshRouteOnlyHeaderState() {
    mainView.setHeaderSubtitle(Self.routeOnlyHeaderSubtitle(for: route))
    mainView.setIsOnline(false)
    mainView.setProfileHandle(Self.profileHandle(for: route))
    profileView?.setHeaderSubtitle(Self.routeOnlyHeaderSubtitle(for: route))
    profileView?.setIsOnline(false)
    profileView?.setProfileHandle(Self.profileHandle(for: route))
  }

  private func profileRouteSnapshot() -> ChatRoute {
    ChatRoute(
      chatId: route.chatId,
      title: route.title,
      peerUserId: route.peerUserId,
      peerAgentId: route.peerAgentId,
      isAgent: route.isAgent,
      avatarURI: route.avatarURI,
      isGroup: route.isGroup,
      unreadCount: route.unreadCount,
      initialRows: latestProfileRows,
      agentEventInboxMode: route.agentEventInboxMode,
      bridgeProvider: route.bridgeProvider,
      // Forward the group participant list — without this the pushed profile
      // always rendered 0 members (header→profile route dropped `members`).
      members: route.members
    )
  }

  private func pushProfileView(animated: Bool) {
    guard route.chatId != "saved_messages" else { return }
    // Talking to one of MY OWN agents: the header opens that agent's settings
    // instead of a normal contact profile (there's nothing to "friend" — it's
    // my own configurable agent), matching how the Agents tab now opens the
    // chat first and reaches settings from inside it.
    if let peerAgentId = route.peerAgentId,
      ChatOwnedAgentIdsCache.agentIds.contains(peerAgentId),
      let config = AppSessionConfig.current,
      let navigationController
    {
      let apiContext = ChatNativeAgentConfigAPIContext(
        apiBaseURL: config.apiBaseURL, token: config.authToken
      )
      chatNativeAgentPushConfig(
        agentId: peerAgentId,
        apiContext: apiContext,
        appearance: .current,
        from: navigationController,
        onToast: { AppToastController.shared.show($0) }
      )
      return
    }
    let profileRoute = profileRouteSnapshot()
    let onClose: () -> Void = { [weak self] in
      guard let self, let navigationController = self.navigationController,
        navigationController.viewControllers.count > 1
      else { return }
      navigationController.popViewController(animated: true)
    }
    let onProfileAppearanceUpdated: () -> Void = { [weak self] in
      self?.mainView.refreshProfileAppearance()
    }
    let onSearchRequested: () -> Void = { [weak self] in
      guard let self else { return }
      if let navigationController = self.navigationController,
        navigationController.topViewController is ChatProfileRootController
      {
        navigationController.popViewController(animated: true)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
        self?.mainView.openHeaderSearch()
      }
    }
    let onContentRequested: ([String: Any]) -> Void = { [weak self] payload in
      self?.mainView.openProfileContent(payload)
    }

    guard let navigationController else {
      showProfileView(animated: animated)
      return
    }

    if let top = navigationController.topViewController as? ChatProfileRootController,
      top.chatId == route.chatId
    {
      top.update(
        route: profileRoute,
        isDark: isDark,
        onClose: onClose,
        onProfileAppearanceUpdated: onProfileAppearanceUpdated,
        onSearchRequested: onSearchRequested,
        onContentRequested: onContentRequested
      )
      return
    }

    let controller = ChatProfileRootController(
      route: profileRoute,
      isDark: isDark,
      onClose: onClose,
      onProfileAppearanceUpdated: onProfileAppearanceUpdated,
      onSearchRequested: onSearchRequested,
      onContentRequested: onContentRequested
    )
    navigationController.pushViewController(controller, animated: animated)
  }

  private func makeProfileViewIfNeeded() -> ChatProfileMainView {
    if let profileView {
      return profileView
    }

    let nextProfileView = ChatProfileMainView()
    nextProfileView.translatesAutoresizingMaskIntoConstraints = false
    nextProfileView.isHidden = true
    nextProfileView.alpha = 0.0
    nextProfileView.onNativeEvent.handler = { [weak self] payload in
      self?.handleNativeEvent(payload)
    }
    view.addSubview(nextProfileView)
    NSLayoutConstraint.activate([
      nextProfileView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      nextProfileView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      nextProfileView.topAnchor.constraint(equalTo: view.topAnchor),
      nextProfileView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    profileView = nextProfileView
    return nextProfileView
  }

  private func configureProfileView(_ profileView: ChatProfileMainView, rows: [[String: Any]]) {
    let surfaceId = "native_profile_\(route.chatId)"
    profileView.performBatchedProfileUpdate {
      profileView.surfaceId = surfaceId
      profileView.setProfileOnly(true)
      profileView.setEngineSurfaceId(surfaceId)
      profileView.setEngineChatId(route.chatId)
      profileView.setEnginePeerUserId(route.peerUserId ?? "")
      if let myUserId = Self.normalizedString(
        ChatEngineStore.shared.getConfig()["myUserId"] ?? ChatEngineStore.shared.getConfig()["userId"]
      ) {
        profileView.setEngineMyUserId(myUserId)
      }
      profileView.setAppearance(Self.resolvedAppearance(isDark: isDark))
      profileView.setHeaderTitle(route.title)
      profileView.setHeaderSubtitle(Self.routeOnlyHeaderSubtitle(for: route))
      profileView.setProfileName(route.title)
      profileView.setBridgeProvider(route.bridgeProvider ?? "")
      profileView.setProfileHandle(Self.profileHandle(for: route))
      profileView.setProfileBio(route.roomDescription ?? "")
      profileView.setAvatarUri(route.avatarURI)
      // Multi-party + channel flags must land together. Missing setRouteMembership
      // left isChannel=false so channel profiles rendered as Group settings.
      // Also re-check home cache so a route built without type still shows Channel.
      let resolvedChannel =
        route.isChannel
        || GroupProfileActionRouter.resolvedIsChannel(chatId: route.chatId)
      profileView.setIsGroupOrChannel(route.isGroup || route.isChannel || resolvedChannel)
      profileView.setRouteMembership(
        isChannel: resolvedChannel,
        myRole: route.myRole
      )
      profileView.setChannelSettings(
        accessType: route.accessType,
        publicSlug: route.publicSlug,
        shareLink: route.shareLink,
        joinApprovalRequired: route.joinApprovalRequired,
        restrictSavingContent: route.restrictSavingContent,
        subscriberCount: route.isChannel ? route.roomParticipantCount : nil
      )
      let routeMemberCount = route.members.count
      let resolvedMembers = ChatRoute.resolvedMembers(
        chatId: route.chatId, routeMembers: route.members)
      if route.members.isEmpty, !resolvedMembers.isEmpty {
        self.route = route.withMembers(resolvedMembers)
      }
      profileView.setGroupMembers(resolvedMembers)
      if route.isGroup {
        profileView.setGroupMemberCount(max(route.roomParticipantCount, resolvedMembers.count))
      }
      NSLog(
        "[WhoAmI] configureProfileView groupMembers chatId=%@ route=%d resolved=%d isChannel=%@ myRole=%@",
        String(route.chatId.prefix(12)),
        routeMemberCount,
        resolvedMembers.count,
        route.isChannel ? "Y" : "N",
        route.myRole ?? "<nil>"
      )
      profileView.setRows(rows)
    }
  }

  private func showProfileView(animated: Bool) {
    guard currentPage != .profile else { return }
    currentPage = .profile
    let profileView = makeProfileViewIfNeeded()
    configureProfileView(profileView, rows: latestProfileRows)
    profileView.layer.removeAllAnimations()
    mainView.layer.removeAllAnimations()
    view.bringSubviewToFront(profileView)
    profileView.isHidden = false
    profileView.alpha = 1.0
    let width = max(view.bounds.width, 1.0)
    guard animated, view.window != nil else {
      profileView.transform = .identity
      mainView.transform = .identity
      return
    }
    profileView.transform = CGAffineTransform(translationX: width, y: 0.0)
    UIView.animate(
      withDuration: 0.34,
      delay: 0.0,
      usingSpringWithDamping: 0.9,
      initialSpringVelocity: 0.28,
      options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
    ) {
      profileView.transform = .identity
      self.mainView.transform = CGAffineTransform(translationX: -width * 0.28, y: 0.0)
    } completion: { _ in
      self.mainView.transform = CGAffineTransform(translationX: -width * 0.28, y: 0.0)
    }
  }

  private func hideProfileView(animated: Bool) {
    guard profileView?.isHidden == false else {
      currentPage = .chat
      return
    }
    removeProfileView(animated: animated)
  }

  private func removeProfileView(animated: Bool) {
    guard let profileView else {
      currentPage = .chat
      mainView.transform = .identity
      return
    }
    currentPage = .chat
    profileView.layer.removeAllAnimations()
    mainView.layer.removeAllAnimations()
    let width = max(view.bounds.width, 1.0)
    guard animated, view.window != nil else {
      profileView.transform = .identity
      profileView.alpha = 0.0
      profileView.isHidden = true
      mainView.transform = .identity
      return
    }
    UIView.animate(
      withDuration: 0.32,
      delay: 0.0,
      usingSpringWithDamping: 0.92,
      initialSpringVelocity: 0.24,
      options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
    ) {
      profileView.transform = CGAffineTransform(translationX: width, y: 0.0)
      profileView.alpha = 1.0
      self.mainView.transform = .identity
    } completion: { _ in
      profileView.transform = .identity
      profileView.alpha = 0.0
      profileView.isHidden = true
      self.mainView.transform = .identity
    }
  }

  private var bridgeAgentSurfaceNav: UINavigationController?

  /// Host the agent runtime VC full-screen over the chat surface (its own header + full
  /// bounds — no nesting/clipping). Back returns to the chat surface.
  private func presentBridgeAgentSurface(_ vc: VibeAgentConversationViewController) {
    dismissBridgeAgentSurface()
    bridgeAgentSurfaceVC = vc
    let nav = UINavigationController(rootViewController: vc)
    nav.navigationBar.prefersLargeTitles = false
    bridgeAgentSurfaceNav = nav
    // Back routing: a primary entry (Default view = Agent) is the DM's own page, so Back
    // exits straight to Home; a "See progress" drill-down peels back to the chat surface.
    if vc.isPrimaryAgentSurface {
      vc.onClose = { [weak self] in self?.exitConversationToHome() }
    } else {
      vc.onClose = { [weak self] in self?.dismissBridgeAgentSurface() }
    }
    addChild(nav)
    nav.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(nav.view)
    NSLayoutConstraint.activate([
      nav.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      nav.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      nav.view.topAnchor.constraint(equalTo: view.topAnchor),
      nav.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    nav.didMove(toParent: self)
    // Primary entry = the DM's own page. The Default-view=Agent path now mounts it BEFORE this
    // controller has appeared, so it rides the controller's own push/present transition — one
    // clean page-in, with the opaque agent view covering the chat from the first frame (no chat
    // flash, no second "morph"). Only animate a separate trailing-edge slide when it's added
    // AFTER the controller is already on screen, so a late mount still reads as a push.
    if vc.isPrimaryAgentSurface && hasAppeared {
      view.layoutIfNeeded()
      nav.view.transform = CGAffineTransform(translationX: view.bounds.width, y: 0.0)
      UIView.animate(
        withDuration: 0.3, delay: 0.0,
        options: [.curveEaseOut, .allowUserInteraction]
      ) {
        nav.view.transform = .identity
      }
    }
    // Keep the Connect panel (if the bridge isn't paired yet) on top so the user can still
    // connect; once connected it's removed and the agent surface underneath is revealed.
    if let connectHost = agentConnectHost {
      view.bringSubviewToFront(connectHost.view)
    }
    appShellRouteLog("ChatConversationController presentAgentSurface chatId=\(route.chatId)")
  }

  /// Exit the whole DM to Home — used when the agent surface is the DM's primary entry, so
  /// Back doesn't strand the user on the (never-intended) chat surface. Mirrors the `.chat`
  /// headerBack exit; the agent overlay rides this controller's pop out to Home, then is
  /// detached once the transition settles so a recycled controller starts clean.
  private func exitConversationToHome() {
    if let onClose {
      onClose()
      DispatchQueue.main.async { [weak self] in
        guard let self, self.presentingViewController != nil, !self.isBeingDismissed else {
          return
        }
        self.dismiss(animated: true)
      }
    } else if let navigationController {
      navigationController.popViewController(animated: true)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      self?.dismissBridgeAgentSurface()
    }
  }

  /// Remove the isolated agent surface, returning to the chat surface underneath.
  private func dismissBridgeAgentSurface() {
    guard let nav = bridgeAgentSurfaceNav else { return }
    nav.willMove(toParent: nil)
    nav.view.removeFromSuperview()
    nav.removeFromParent()
    bridgeAgentSurfaceNav = nil
    bridgeAgentSurfaceVC = nil
    appShellRouteLog("ChatConversationController dismissAgentSurface chatId=\(route.chatId)")
  }

  private func handleNativeEvent(_ payload: [String: Any]) {
    let type = Self.normalizedString(payload["type"]) ?? ""
    appShellRouteLog(
      "ChatConversationController nativeEvent chatId=\(route.chatId) type=\(type) payloadKeys=\(payload.keys.sorted())")
    switch type {
    case "headerBack":
      switch currentPage {
      case .chat:
        if let onClose {
          appShellRouteLog("ChatConversationController dismissPresented chatId=\(route.chatId)")
          onClose()
          DispatchQueue.main.async { [weak self] in
            guard let self, self.presentingViewController != nil, !self.isBeingDismissed else {
              return
            }
            appShellRouteLog(
              "ChatConversationController fallbackSelfDismiss chatId=\(self.route.chatId)")
            self.dismiss(animated: true)
          }
        } else if let navigationController {
          navigationController.popViewController(animated: true)
        }
      case .profile:
        hideProfileView(animated: true)
      case .agent:
        showProfileView(animated: true)
      }
    case "headerAvatarPressed":
      pushProfileView(animated: true)
    case "profileAppearanceUpdated":
      mainView.refreshProfileAppearance()
    case "headerAgentPressed":
      return
    case "agentChatPressed":
      guard
        let agentUserId = Self.normalizedString(
          payload["agentUserId"] ?? payload["agent_user_id"])
      else { return }
      let tappedAgentID = Self.normalizedString(payload["agentId"] ?? payload["agent_id"])
      if agentUserId == route.peerUserId || tappedAgentID == route.peerAgentId {
        return
      }
      let agentName =
        Self.normalizedString(payload["agentName"] ?? payload["agent_name"]) ?? "Agent"
      let agentUsername = Self.normalizedString(
        payload["agentUsername"] ?? payload["agent_username"]
          ?? payload["agentHandle"] ?? payload["agent_handle"])
      let agentID = Self.normalizedString(payload["agentId"] ?? payload["agent_id"])
      let bridgeProvider = Self.normalizedString(payload["provider"] ?? payload["agentBridgeProvider"])
      Task { @MainActor [weak self] in
        guard let self else { return }
        await openAgentDirectChat(
          from: self,
          agentUserId: agentUserId,
          agentName: agentName,
          agentUsername: agentUsername,
          agentId: agentID,
          bridgeProvider: bridgeProvider
        )
      }
    case "agentInboxPressed":
      let inboxRows = mainView.currentEventInboxRows()
      let inboxVC = AgentInboxViewController(
        rows: inboxRows,
        agentTitle: route.title,
        agentID: route.peerAgentId,
        config: AppSessionConfig.current
      )
      let nav = UINavigationController(rootViewController: inboxVC)
      nav.modalPresentationStyle = .pageSheet
      if let sheet = nav.sheetPresentationController {
        sheet.detents = [.large()]
        sheet.prefersGrabberVisible = true
      }
      present(nav, animated: true)
    case "openAgentPanel":
      let payloadProvider =
        Self.normalizedString(payload["provider"] ?? payload["agentBridgeProvider"])
      if let provider = payloadProvider ?? route.bridgeProvider, !provider.isEmpty {
        presentBridgeRepositoryPicker(provider: provider)
      }
    case "agentSessionPressed":
      let payloadProvider =
        Self.normalizedString(payload["provider"] ?? payload["agentBridgeProvider"])
      if let provider = payloadProvider ?? route.bridgeProvider, !provider.isEmpty {
        presentAgentSessionHistorySheet(provider: provider)
      }
    case "agentStopStreaming":
      if let provider = route.bridgeProvider, !provider.isEmpty {
        let result = ChatEngine.shared.sendAgentBridgeControl([
          "chatId": route.chatId,
          "provider": provider,
          "action": "cancel",
        ])
        appShellRouteLog(
          "ChatConversationController bridgeStop chatId=\(route.chatId) provider=\(provider) result=\(result)")
      }
    case "agentToast":
      if let message = Self.normalizedString(payload["message"]) {
        AppToastController.shared.show(message)
      }
    case "headerSearchPressed":
      if currentPage == .profile {
        hideProfileView(animated: true)
	      }
      mainView.openHeaderSearch()
    case "headerAudioCallPressed":
      NativeCallRouteBridge.startOutgoing(route: route, callType: "voice")
    case "headerVideoCallPressed":
      NativeCallRouteBridge.startOutgoing(route: route, callType: "video")
    case "headerMenuAction":
      let action = Self.normalizedString(payload["action"]) ?? ""
      if action == "clearChat" {
        presentClearChatOptions()
      }
    case "mainPageChanged":
      if let page = Self.normalizedString(payload["page"]),
        let resolved = ChatConversationPage(rawValue: page)
      {
        currentPage = resolved
      }
    case "forwardDraftConfirm":
      guard let draft = pendingForwardDraft else { return }
      let caption = (payload["caption"] as? String) ?? ""
      let sent: Int
      if !draft.messagePayloads.isEmpty {
        // Agent (or pre-built) payloads — do not require live engine rows.
        sent = ChatAgentConversationController.forwardAgentMessages(
          messagePayloads: draft.messagePayloads,
          messageIds: draft.messageIds,
          toChatIds: [route.chatId],
          caption: caption
        )
      } else {
        sent = Self.forwardMessages(
          messageIds: draft.messageIds,
          fromChatId: draft.fromChatId,
          toChatIds: [route.chatId],
          caption: caption
        )
      }
      pendingForwardDraft = nil
      if sent > 0 {
        AppToastController.shared.show(
          sent == 1 ? "Message forwarded" : "\(sent) messages forwarded")
      } else {
        AppToastController.shared.show("Couldn't forward those messages")
      }
    case "forwardDraftCancel":
      pendingForwardDraft = nil
    case "inputActionPressed":
      let action = Self.normalizedString(payload["action"]) ?? ""
      switch action {
      case "delete":
        let forEveryone = (payload["forEveryone"] as? Bool) ?? false
        let messageIds = (payload["messageIds"] as? [String]) ?? []
        appShellRouteLog(
          "ChatConversationController delete chatId=\(route.chatId) forEveryone=\(forEveryone) count=\(messageIds.count)")
        for msgId in messageIds {
          _ = ChatEngine.shared.deleteMessage([
            "chatId": route.chatId,
            "messageId": msgId,
            "forEveryone": forEveryone,
          ])
        }
      case "shareInside":
        guard !route.restrictSavingContent else {
          NSLog("[ChatShare] chatShare blocked restrictSavingContent chat=%@", route.chatId)
          AppToastController.shared.show("Forwarding is disabled for this channel")
          mainView.clearMessageSelection()
          return
        }
        let messageIds = (payload["messageIds"] as? [String]) ?? []
        let messagePayloads = (payload["messages"] as? [[String: Any]]) ?? []
        NSLog(
          "[ChatShare] chatShare shareInside chat=%@ ids=%d payloads=%d",
          route.chatId,
          messageIds.count,
          messagePayloads.count
        )
        appShellRouteLog(
          "ChatConversationController shareInside chatId=\(route.chatId) count=\(messageIds.count)")
        guard AppSessionConfig.current != nil else {
          NSLog("[ChatShare] chatShare aborted: no session")
          AppToastController.shared.show("Sign in to forward messages")
          return
        }
        let sourceChatId = route.chatId
        let previewSnippet = Self.forwardPreviewText(
          messageIds: messageIds, messagePayloads: messagePayloads, fromChatId: sourceChatId)
        // Present the picker as a real page sheet (not nested sheet-in-overFullScreen).
        let shareRoot = ShareChatSelectionView(
          previewText: previewSnippet,
          messageCount: max(messageIds.count, messagePayloads.count, 1),
          onSelect: { [weak self] searchPayload in
            guard let self else { return }
            let targetChatIds = (searchPayload["chatIds"] as? [String]) ?? []
            let caption = (searchPayload["caption"] as? String) ?? ""
            NSLog(
              "[ChatShare] chatShare send targets=%d ids=%d captionLen=%d",
              targetChatIds.count,
              messageIds.count,
              caption.count
            )
            let sent = Self.forwardMessages(
              messageIds: messageIds,
              fromChatId: sourceChatId,
              toChatIds: targetChatIds,
              caption: caption
            )
            DispatchQueue.main.async {
              self.mainView.clearMessageSelection(animated: true)
              if sent > 0 {
                AppToastController.shared.show(
                  sent == 1 ? "Message forwarded" : "\(sent) messages forwarded")
              } else {
                AppToastController.shared.show("Couldn't forward those messages")
              }
              NSLog("[ChatShare] chatShare finished sent=%d", sent)
            }
          },
          onOpenTarget: { [weak self] row in
            guard let self else { return }
            ChatPendingForwardStore.set(
              .init(
                fromChatId: sourceChatId,
                messageIds: messageIds,
                messagePayloads: messagePayloads,
                previewText: previewSnippet
              ),
              for: row.chatId
            )
            self.mainView.clearMessageSelection(animated: true)
            let targetRoute = ChatRoute(row: row)
            // Dismiss sheet first, then push the target chat with pending forward.
            self.dismiss(animated: true) {
              DispatchQueue.main.async {
                guard let nav = self.navigationController else { return }
                let isDark = nav.traitCollection.userInterfaceStyle == .dark
                let controller = ChatConversationController(
                  route: targetRoute,
                  isDark: isDark,
                  onClose: { [weak nav] in
                    guard let nav, nav.viewControllers.count > 1 else { return }
                    nav.popViewController(animated: true)
                  }
                )
                nav.pushViewController(controller, animated: true)
              }
            }
          }
        )
        let shareVC = UIHostingController(rootView: shareRoot)
        shareVC.modalPresentationStyle = .pageSheet
        // Near-black host so sheet chrome never flashes light-gray on dark.
        shareVC.view.backgroundColor =
          self.traitCollection.userInterfaceStyle == .dark
          ? UIColor(white: 0.07, alpha: 1)
          : .systemBackground
        if let sheet = shareVC.sheetPresentationController {
          if #available(iOS 16.0, *) {
            sheet.detents = [.large(), .medium()]
            sheet.selectedDetentIdentifier = .large
          } else {
            sheet.detents = [.medium(), .large()]
          }
          sheet.prefersGrabberVisible = true
          sheet.prefersScrollingExpandsWhenScrolledToEdge = true
          sheet.preferredCornerRadius = 28
        }
        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController { presenter = presented }
        NSLog(
          "[ChatShare] chatShare presenting on %@",
          String(describing: Swift.type(of: presenter))
        )
        presenter.present(shareVC, animated: true) {
          NSLog(
            "[ChatShare] chatShare present completion presented=%@",
            presenter.presentedViewController != nil ? "Y" : "N"
          )
        }
      default:
        break
      }
    case "profileGroupAction", "groupMemberTapped", "channelLink", "channelSetting", "channelAgents":
      var presenter: UIViewController = self
      while let presented = presenter.presentedViewController { presenter = presented }
      _ = GroupProfileActionRouter.handle(
        payload: payload,
        route: route,
        presenter: presenter,
        onClose: { [weak self] in
          guard let self else { return }
          if let close = self.onClose { close() } else { self.dismiss(animated: true) }
        },
        onEdited: { [weak self] name, avatarUrl, description in
          guard let self else { return }
          self.mainView.setHeaderTitle(name)
          self.mainView.setProfileName(name)
          self.profileView?.setProfileName(name)
          self.profileView?.setHeaderTitle(name)
          self.profileView?.setProfileBio(description)
          if let avatarUrl, !avatarUrl.isEmpty {
            self.mainView.setAvatarUri(avatarUrl)
            self.profileView?.setAvatarUri(avatarUrl)
          }
        })
    default:
      break
    }
  }

  private func presentClearChatOptions() {
    let presenter = topMostPresenter()
    let canClearForEveryone = route.peerUserId != nil && !route.isGroup && route.chatId != "saved_messages"
    let sheet = UIAlertController(
      title: "Clear Chat",
      message: nil,
      preferredStyle: .actionSheet
    )
    if canClearForEveryone {
      sheet.addAction(
        UIAlertAction(title: "Clear for me and \(route.title)", style: .destructive) {
          [weak self] _ in
          self?.performClearChat(deleteForEveryone: true)
        })
    }
    sheet.addAction(
      UIAlertAction(
        title: canClearForEveryone ? "Clear just for me" : "Clear for me",
        style: .destructive
      ) { [weak self] _ in
        self?.performClearChat(deleteForEveryone: false)
      })
    sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = view
      popover.sourceRect = CGRect(x: view.bounds.midX, y: view.safeAreaInsets.top + 44.0, width: 1.0, height: 1.0)
      popover.permittedArrowDirections = []
    }
    presenter.present(sheet, animated: true)
  }

  private func topMostPresenter() -> UIViewController {
    var presenter: UIViewController = self
    while let presented = presenter.presentedViewController {
      presenter = presented
    }
    return presenter
  }

  /// One-line preview for the share sheet bottom banner.
  fileprivate static func forwardPreviewText(
    messageIds: [String],
    messagePayloads: [[String: Any]],
    fromChatId: String
  ) -> String {
    if let first = messagePayloads.first {
      let msg = unwrapLiveMessageDict(first)
      let text = ((msg["text"] as? String) ?? (msg["plainContent"] as? String) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        return text.count > 72 ? String(text.prefix(69)) + "…" : text
      }
      let type = ((msg["type"] as? String) ?? "message").lowercased()
      return type.capitalized
    }
    if let mid = messageIds.first,
      let row = ChatEngine.shared.getLiveMessageRow([
        "chatId": fromChatId,
        "messageId": mid,
      ])
    {
      let msg = unwrapLiveMessageDict(row)
      let text = ((msg["text"] as? String) ?? (msg["plainContent"] as? String) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        return text.count > 72 ? String(text.prefix(69)) + "…" : text
      }
      let type = ((msg["type"] as? String) ?? "message").lowercased()
      return type.capitalized
    }
    return messageIds.count > 1 ? "\(messageIds.count) messages" : "Message"
  }

  /// Live engine rows are `{ kind, key, message: {...} }`. Flat payloads (agent
  /// share) already are the message dict. Always unwrap before reading fields.
  private static func unwrapLiveMessageDict(_ row: [String: Any]) -> [String: Any] {
    if let nested = row["message"] as? [String: Any] { return nested }
    return row
  }

  private static func metadataDict(from message: [String: Any]) -> [String: Any] {
    if let dict = message["metadata"] as? [String: Any] { return dict }
    if let raw = message["metadata"] as? String,
      let data = raw.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      return obj
    }
    return [:]
  }

  private static func stringField(_ message: [String: Any], _ keys: [String]) -> String? {
    for key in keys {
      if let s = message[key] as? String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
      }
    }
    return nil
  }

  /// Build and send forward payloads for each selected message → each target chat.
  /// Returns how many sends were accepted by the engine.
  @discardableResult
  private static func forwardMessages(
    messageIds: [String],
    fromChatId: String,
    toChatIds: [String],
    caption: String = ""
  ) -> Int {
    guard !messageIds.isEmpty, !toChatIds.isEmpty else { return 0 }
    let meId = AppSessionConfig.current?.userID
    let meName = AppSessionConfig.current?.name ?? AppSessionConfig.current?.username
    let meAvatar = AppSessionConfig.current?.profileImage
    var sent = 0

    for targetChatId in toChatIds {
      let target = targetChatId.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !target.isEmpty, target != fromChatId else { continue }
      for msgId in messageIds {
        guard
          let liveRow = ChatEngine.shared.getLiveMessageRow([
            "chatId": fromChatId,
            "messageId": msgId,
          ])
        else {
          NSLog("[ChatShare] forwardMessages miss live row chat=%@ msg=%@", fromChatId, msgId)
          continue
        }
        // CRITICAL: getLiveMessageRow returns nested { message: {...} }, not flat.
        let message = unwrapLiveMessageDict(liveRow)

        var type = (
          stringField(message, ["type", "messageType", "message_type"]) ?? "text"
        ).lowercased()
        let text =
          stringField(message, ["text", "plainContent", "plain_content"]) ?? ""
        var metadata = metadataDict(from: message)

        // Lift media/music fields from the message body into metadata so
        // ChatListRow (cover/mediaUrl/isForwarded) and sendMessage both see them.
        let mediaKeys = [
          "mediaUrl", "media_url", "localMediaUrl", "local_media_url", "fileName", "file_name",
          "fileSize", "file_size", "duration", "width", "height", "thumbnailBase64",
          "thumbnail_base64", "mediaKey", "media_key", "waveform", "cover", "coverUrl",
          "cover_url", "artwork", "artworkUrl", "artist", "source", "platform", "provider",
          "videoId", "video_id", "latitude", "longitude", "caption", "title",
        ]
        for key in mediaKeys {
          if metadata[key] == nil, let value = message[key] {
            metadata[key] = value
          }
        }
        // Music often arrives as type=text with cover/artist — promote to music.
        if type == "text" || type == "agent_progress_tree" {
          let hasCover =
            stringField(metadata, ["cover", "coverUrl", "cover_url", "artwork", "artworkUrl"])
            != nil
          let hasArtist = stringField(metadata, ["artist", "uploader", "channel"]) != nil
          let mediaURL = stringField(
            metadata, ["mediaUrl", "media_url"])
            ?? stringField(message, ["mediaUrl", "media_url", "localMediaUrl"])
          if hasCover || hasArtist,
            let mediaURL, !mediaURL.isEmpty
          {
            type = "music"
          }
        }

        let authorId =
          stringField(message, ["fromId", "from_id", "senderId", "sender_id"])
          ?? ((message["isMe"] as? Bool) == true ? meId : nil)
        let authorName =
          stringField(message, ["senderName", "sender_name", "title", "agentName"])
          ?? ((message["isMe"] as? Bool) == true ? meName : nil)
        let authorAvatar =
          stringField(message, ["avatarUrl", "avatar_url", "profileImage", "profile_image"])
          ?? ((message["isMe"] as? Bool) == true ? meAvatar : nil)

        metadata["forwardedFromChatId"] = fromChatId
        metadata["forwarded_from_chat_id"] = fromChatId
        metadata["forwardedFromMessageId"] = msgId
        metadata["forwarded_from_message_id"] = msgId
        if let authorId, !authorId.isEmpty {
          metadata["forwardedFromUserId"] = authorId
          metadata["forwarded_from_user_id"] = authorId
        }
        if let authorName, !authorName.isEmpty {
          metadata["forwardedFromName"] = authorName
          metadata["forwarded_from_name"] = authorName
        }
        if let authorAvatar, !authorAvatar.isEmpty {
          metadata["forwardedFromAvatar"] = authorAvatar
          metadata["forwarded_from_avatar"] = authorAvatar
        }
        metadata["isForwarded"] = true
        metadata["is_forwarded"] = true

        // Normalize cover keys ChatListRow reads.
        if metadata["cover"] == nil {
          if let c = stringField(
            metadata, ["coverUrl", "cover_url", "artwork", "artworkUrl", "artwork_url"])
          {
            metadata["cover"] = c
            metadata["coverUrl"] = c
          }
        }

        var payload: [String: Any] = [
          "chatId": target,
          "type": type,
          "text": text,
          "metadata": metadata,
        ]
        // Media types need a non-empty mediaUrl at top-level for sendMessage.
        let mediaUrl =
          stringField(metadata, ["mediaUrl", "media_url"])
          ?? stringField(message, ["mediaUrl", "media_url"])
        if let mediaUrl, !mediaUrl.isEmpty {
          payload["mediaUrl"] = mediaUrl
          metadata["mediaUrl"] = mediaUrl
        }
        var local =
          stringField(metadata, ["localMediaUrl", "local_media_url"])
          ?? stringField(message, ["localMediaUrl", "local_media_url"])
        // Reuse durable voice/music cache so forward never re-downloads first.
        if local == nil || local?.isEmpty == true,
          let mediaUrl = payload["mediaUrl"] as? String,
          let remoteURL = URL(string: mediaUrl),
          let cached = VoiceBubblePlaybackCoordinator.shared.resolvedCachedLocalURL(
            forRemote: remoteURL,
            fileName: stringField(metadata, ["fileName", "file_name"])
          )
        {
          local = cached.absoluteString
        }
        if let local, !local.isEmpty {
          payload["localMediaUrl"] = local
          metadata["localMediaUrl"] = local
          if payload["mediaUrl"] == nil { payload["mediaUrl"] = local }
        }
        if let fileName = stringField(metadata, ["fileName", "file_name"])
          ?? stringField(message, ["fileName", "file_name"])
        {
          payload["fileName"] = fileName
          metadata["fileName"] = fileName
        }
        if let duration = metadata["duration"] ?? message["duration"] {
          payload["duration"] = duration
          metadata["duration"] = duration
        }
        if let thumb = stringField(metadata, ["thumbnailBase64", "thumbnail_base64"])
          ?? stringField(message, ["thumbnailBase64", "thumbnail_base64"])
        {
          payload["thumbnailBase64"] = thumb
          metadata["thumbnailBase64"] = thumb
        }
        if let mediaKey = stringField(metadata, ["mediaKey", "media_key"])
          ?? stringField(message, ["mediaKey", "media_key"])
        {
          payload["mediaKey"] = mediaKey
          metadata["mediaKey"] = mediaKey
        }
        // Music/voice with empty text: give sendMessage a non-empty push preview
        // without changing type — empty text + type music is allowed; empty text
        // + type text is rejected.
        if type == "text", text.isEmpty, payload["mediaUrl"] != nil {
          // Still missing type — infer from presence of media.
          if metadata["cover"] != nil || metadata["artist"] != nil {
            payload["type"] = "music"
            type = "music"
          } else if metadata["waveform"] != nil || metadata["duration"] != nil {
            payload["type"] = "voice"
            type = "voice"
          } else if metadata["width"] != nil || metadata["thumbnailBase64"] != nil {
            payload["type"] = "image"
            type = "image"
          }
        }
        payload["metadata"] = metadata

        NSLog(
          "[ChatShare] forwardMessages send type=%@ hasMedia=%@ hasCover=%@ isFwd=%@ textLen=%d",
          type,
          payload["mediaUrl"] != nil ? "Y" : "N",
          metadata["cover"] != nil ? "Y" : "N",
          (metadata["isForwarded"] as? Bool) == true ? "Y" : "N",
          text.count
        )

        let result = ChatEngine.shared.sendMessage(payload)
        if (result["accepted"] as? Bool) == true {
          sent += 1
        } else {
          appShellRouteLog(
            "forwardMessages rejected type=\(type) reason=\(result["reason"] ?? "unknown")")
          NSLog(
            "[ChatShare] forwardMessages rejected type=%@ reason=%@",
            type,
            String(describing: result["reason"] ?? "unknown")
          )
        }
      }
      // Optional caption: send as a follow-up text after the forwarded messages.
      let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmedCaption.isEmpty {
        _ = ChatEngine.shared.sendMessage([
          "chatId": target,
          "type": "text",
          "text": trimmedCaption,
        ])
      }
    }
    return sent
  }

  private func performClearChat(deleteForEveryone: Bool) {
    // Exit selection chrome before transforming the visible transcript. The
    // destructive mutation starts once exact bubble fragments cover the cells.
    mainView.clearMessageSelection(animated: true)
    mainView.animateClearChatDisintegration { [weak self] in
      self?.commitClearChat(deleteForEveryone: deleteForEveryone)
    }
  }

  private func commitClearChat(deleteForEveryone: Bool) {
    if let config = AppSessionConfig.current {
      ChatHomeService.removeCachedChat(chatID: route.chatId, config: config)
    }
    NSLog(
      "[DeleteTrace] clear commit chat=%@ scope=%@",
      route.chatId,
      deleteForEveryone ? "everyone" : "me"
    )
    if deleteForEveryone {
      _ = ChatEngine.shared.clearChat([
        "chatId": route.chatId,
        "localOnly": true,
      ])
      mainView.clearRows()
      profileView?.setRows([])
      latestProfileRows = []
      guard let config = AppSessionConfig.current else {
        AppToastController.shared.show("The current session is unavailable.")
        return
      }
      Task { @MainActor in
        do {
          try await ChatHomeEditService.deleteChat(
            chatID: route.chatId,
            config: config,
            deleteForEveryone: true
          )
          AppToastController.shared.show("Chat cleared for both sides.")
        } catch {
          AppToastController.shared.show(error.localizedDescription)
        }
      }
      return
    }

    // Functional path: engine wipes local history + queues DELETE /api/chats/:id
    // (server soft-clears via messages_cleared_at / participant delete).
    _ = ChatEngine.shared.clearChat(["chatId": route.chatId])
    mainView.clearRows()
    profileView?.setRows([])
    latestProfileRows = []
    AppToastController.shared.show("Chat cleared.")
  }

  @objc private func handleChatEngineChanged(_ notification: Notification) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.handleChatEngineChanged(notification)
      }
      return
    }

    if hasAppeared && view.window == nil {
      appShellRouteLog(
        "ChatConversationController engineChanged ignoredDetached chatId=\(route.chatId) reason=\(Self.normalizedString(notification.userInfo?["reason"]) ?? "unknown")")
      return
    }
    if isBeingDismissed {
      appShellRouteLog(
        "ChatConversationController engineChanged ignoredDismissing chatId=\(route.chatId) reason=\(Self.normalizedString(notification.userInfo?["reason"]) ?? "unknown")")
      return
    }
    if isDismantled {
      appShellRouteLog(
        "ChatConversationController engineChanged ignoredDismantled chatId=\(route.chatId) reason=\(Self.normalizedString(notification.userInfo?["reason"]) ?? "unknown")")
      return
    }

    let changedChatId = Self.normalizedString(notification.userInfo?["chatId"])
    let changeReason = Self.normalizedString(notification.userInfo?["reason"]) ?? "unknown"
    if changeReason == "surfaceBindingChanged", changedChatId == nil {
      return
    }
    if route.chatId == "saved_messages", changedChatId == nil {
      return
    }
    guard changedChatId == route.chatId || changedChatId == nil else { return }
    appShellRouteLog(
      "ChatConversationController engineChanged routeChatId=\(route.chatId) changedChatId=\(changedChatId ?? "nil") reason=\(changeReason)")

    if pendingDeferredEngineStateRefresh {
      refreshRouteOnlyHeaderState()
    }

    switch changeReason {
    case "engineError":
      let category = Self.normalizedString(notification.userInfo?["category"])
      if category == "bridgeSendFailed",
        let message = Self.normalizedString(notification.userInfo?["error"])
      {
        AppToastController.shared.show(message)
      }
    case "chatRowsReloaded", "chatMessageInserted", "chatMessageEdited", "chatMessageDeleted",
      "chatMessageChanged", "chatMessageReactionChanged", "messageStatusChanged",
      "presenceChanged", "peerTyping", "chatMuteChanged":
      refreshRows(allowAuthoritativeEmpty: changeReason == "chatMessageDeleted")
    default:
      break
    }
  }

  @objc private func handleAgentBridgeSelectionChanged(_ notification: Notification) {
    guard route.bridgeProvider?.isEmpty == false else { return }
    refreshHeaderState()
  }

  /// Repaint immediately when the wallpaper/theme draft is edited, so a chat that is
  /// already on screen picks the change up on selection instead of on the next push.
  /// Off-screen surfaces defer to attachment, which is what `applyRoute` would have done.
  @objc private func handleAppearanceDraftChanged(_ notification: Notification) {
    applySurfaceAppearance(
      Self.resolvedAppearance(isDark: isDark),
      reason: "appearanceDraftChanged",
      allowDeferUntilAttached: true
    )
  }

  private static func isOnline(for route: ChatRoute) -> Bool {
    ChatEngine.shared.isUserOnline(userId: route.peerUserId)
  }

  private static func bridgeHeaderSubtitle(for route: ChatRoute) -> String? {
    guard let provider = route.bridgeProvider?.trimmingCharacters(in: .whitespacesAndNewlines),
      !provider.isEmpty
    else {
      return nil
    }
    let repoName = AgentBridgeSelectionStore.selectedRepository()?.name
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return repoName.isEmpty ? "Pick repository" : repoName
  }

  private static func headerSubtitle(for route: ChatRoute) -> String {
    if route.chatId == "saved_messages" {
      return "Saved Messages"
    }
    if ChatEngine.shared.isTyping(["chatId": route.chatId]) {
      if route.bridgeProvider?.isEmpty == false {
        return "Running task"
      }
      return "typing..."
    }
    if let bridgeSubtitle = bridgeHeaderSubtitle(for: route) {
      return bridgeSubtitle
    }
    if route.isGroup {
      return route.roomParticipantSubtitle
    }
    guard route.hasPeerResponse else { return "" }
    if isOnline(for: route) {
      return "online"
    }
    if let lastSeen = ChatEngine.shared.lastSeenTimestampMs(userId: route.peerUserId),
      let label = lastSeenLabel(from: lastSeen)
    {
      return label
    }
    return route.peerUserId == nil ? "" : "last seen recently"
  }

  private static func routeOnlyHeaderSubtitle(for route: ChatRoute) -> String {
    if route.chatId == "saved_messages" {
      return "Saved Messages"
    }
    if let bridgeSubtitle = bridgeHeaderSubtitle(for: route) {
      return bridgeSubtitle
    }
    if route.isGroup {
      return route.roomParticipantSubtitle
    }
    return route.peerUserId == nil || !route.hasPeerResponse ? "" : "last seen recently"
  }

  private func logLifecycle(_ event: String) {
    let navCount = navigationController?.viewControllers.count ?? 0
    let navTypes =
      navigationController?.viewControllers.map { String(describing: type(of: $0)) }
      .joined(separator: " > ") ?? "nil"
    let rootType = view.window?.rootViewController.map { String(describing: type(of: $0)) } ?? "nil"
    let parentType = parent.map { String(describing: type(of: $0)) } ?? "nil"
    let presentedType = presentingViewController.map { String(describing: type(of: $0)) } ?? "nil"
    appShellRouteLog(
      "ChatConversationController \(event) chatId=\(route.chatId) navCount=\(navCount) nav=\(navTypes) parent=\(parentType) root=\(rootType) presentedBy=\(presentedType)")
  }

  private func logVisualState(_ event: String, force: Bool = false) {
    let viewFrame = NSCoder.string(for: view.frame)
    let viewBounds = NSCoder.string(for: view.bounds)
    let mainFrame = NSCoder.string(for: mainView.frame)
    let mainBounds = NSCoder.string(for: mainView.bounds)
    let windowBounds = view.window.map { NSCoder.string(for: $0.bounds) } ?? "nil"
    let safeInsets = NSCoder.string(for: view.safeAreaInsets)
    let signature =
      "\(viewFrame)|\(viewBounds)|\(mainFrame)|\(mainBounds)|\(windowBounds)|\(view.window != nil)|\(view.isHidden)|\(view.alpha)|\(mainView.isHidden)|\(mainView.alpha)"
    if !force, signature == lastLayoutSignature {
      return
    }
    lastLayoutSignature = signature
    appShellRouteLog(
      "ChatConversationController \(event) chatId=\(route.chatId) viewFrame=\(viewFrame) viewBounds=\(viewBounds) mainFrame=\(mainFrame) mainBounds=\(mainBounds) windowBounds=\(windowBounds) safeInsets=\(safeInsets) hidden=\(view.isHidden) alpha=\(view.alpha) mainHidden=\(mainView.isHidden) mainAlpha=\(mainView.alpha)")
  }

  private static func profileHandle(for route: ChatRoute) -> String {
    if route.chatId == "saved_messages" {
      return "Personal notes and media"
    }
    if let peerUserId = normalizedString(route.peerUserId) {
      return peerUserId
    }
    if route.isGroup {
      return route.isChannel ? "Channel" : "Group chat"
    }
    return ""
  }

  private static func lastSeenLabel(from timestampMs: Int64) -> String? {
    guard timestampMs > 0 else { return nil }
    return ChatMainView.formatLastSeenSubtitle(timestampMs)
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }

  /// The colour under the transcript during the push. Pure black/white here is what showed
  /// through as a solid before the wallpaper painted; take the theme's own base instead.
  private static func backgroundColor(isDark: Bool) -> UIColor {
    ChatListAppearance.from(raw: resolvedAppearance(isDark: isDark)).wallpaperBase
  }

  private static func resolvedAppearance(isDark: Bool) -> [String: Any] {
    ChatAppearanceDraftStore.chatRawAppearance(isDark: isDark)
  }
}

private struct ChatHomeRowView: View {
  let row: ChatHomeListRow
  let palette: AppThemePalette

  var body: some View {
    HStack(spacing: 14) {
      ChatAvatarView(row: row, palette: palette)

      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(row.title)
            .font(.system(size: 17, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(palette.text)

          if row.isGoldTier {
            ChatHomeTierBadgeView(label: "Gold")
          }

          if row.isTyping {
            Text("Typing…")
              .font(.caption)
              .foregroundStyle(palette.secondaryText)
              .lineLimit(1)
          }

          Spacer(minLength: 8)

          if !row.timeLabel.isEmpty {
            Text(row.timeLabel)
              .font(.caption)
              .foregroundStyle(palette.secondaryText)
          }
        }

        HStack(spacing: 8) {
          Text(row.preview.isEmpty ? "No messages yet" : row.preview)
            .font(.subheadline)
            .foregroundStyle(palette.secondaryText)
            .lineLimit(2)

          Spacer(minLength: 8)

          if row.unreadCount > 0 {
            Text("\(row.unreadCount)")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(palette.buttonText)
              .padding(.horizontal, 8)
              .padding(.vertical, 4)
              .background(Capsule(style: .continuous).fill(palette.accent))
          }
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(palette.card)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .stroke(palette.border, lineWidth: 1)
    )
  }
}

private struct ChatHomeTierBadgeView: View {
  let label: String

  var body: some View {
    Image(systemName: "checkmark.seal.fill")
      .font(.system(size: 14))
      .symbolRenderingMode(.palette)
      .foregroundStyle(Color.primary, Color(red: 1.0, green: 0.78, blue: 0.28))
  }
}

private struct ChatAvatarView: View {
  let row: ChatHomeListRow
  let palette: AppThemePalette
  @Environment(\.colorScheme) private var colorScheme
  @State private var avatarImage: UIImage?
  @State private var avatarImageURI: String?

  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      avatarContent
        .frame(width: 54, height: 54)
        .clipShape(Circle())

      if row.isOnline {
        Circle()
          .fill(palette.success)
          .frame(width: 12, height: 12)
          .overlay(
            Circle()
              .stroke(palette.card, lineWidth: 2)
          )
      }
    }
  }

  @ViewBuilder
  private var avatarContent: some View {
    let hasPhoto =
      avatarImageURI == normalizedAvatarURI(row.avatarUri) && avatarImage != nil
    ZStack {
      // Only show letter/glyph when there is no photo — never under a loaded image.
      if !hasPhoto {
        fallbackAvatar
      }
      if hasPhoto, let avatarImage {
        Image(uiImage: avatarImage)
          .resizable()
          .scaledToFill()
      }
    }
    .task(id: row.avatarUri ?? "") {
      await loadAvatarImage(row.avatarUri)
    }
  }

  @ViewBuilder
  private var fallbackAvatar: some View {
    let gradientColors = rowAvatarGradientColors(row: row, palette: palette)
    // While a real avatar URL is loading, keep a quiet gradient (no giant letter)
    // so we don't flash initials over a chat that already has a photo.
    let uri = normalizedAvatarURI(row.avatarUri)
    let quietWhileLoading = uri != nil && avatarImage == nil
    Circle()
      .fill(
        LinearGradient(
          colors: gradientColors,
          startPoint: .top,
          endPoint: .bottom
        )
      )
      .overlay(
        Group {
          if row.isSavedMessages {
            Image(systemName: "bookmark.fill")
              .font(.system(size: 18, weight: .semibold))
          } else if quietWhileLoading {
            EmptyView()
          } else {
            Text(row.avatarFallback)
              .font(.system(size: 16, weight: .semibold))
          }
        }
        .foregroundStyle(palette.buttonText.opacity(0.95))
      )
  }


  private func rowAvatarGradientColors(row: ChatHomeListRow, palette: AppThemePalette) -> [Color] {
    if !row.isSavedMessages {
      let colors = ChatProfileAppearanceStore.avatarColors(
        title: row.title,
        peerUserId: row.peerUserId,
        chatId: row.chatId
      )
      return [Color(uiColor: colors.0), Color(uiColor: colors.1)]
    }

    let startRaw = colorScheme == .dark
      ? (row.avatarGradientStartDark ?? row.avatarGradientStartLight)
      : (row.avatarGradientStartLight ?? row.avatarGradientStartDark)
    let endRaw = colorScheme == .dark
      ? (row.avatarGradientEndDark ?? row.avatarGradientEndLight)
      : (row.avatarGradientEndLight ?? row.avatarGradientEndDark)
    if let startRaw, let endRaw,
      let start = Color(hexString: startRaw),
      let end = Color(hexString: endRaw)
    {
      return [start, end]
    }
    return [palette.accent.opacity(0.9), palette.button.opacity(0.72)]
  }

  private func normalizedAvatarURI(_ rawValue: String?) -> String? {
    let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }

  @MainActor
  private func loadAvatarImage(_ rawValue: String?) async {
    let normalized = normalizedAvatarURI(rawValue)
    if avatarImageURI != normalized {
      avatarImageURI = normalized
      // Prefer cache; keep previous image while the new URI loads so letters
      // never flash over a known photo.
      if let normalized, let cached = ChatAvatarImageStore.cached(for: normalized) {
        avatarImage = cached
      } else if normalized == nil {
        avatarImage = nil
      }
    }
    guard let normalized else {
      avatarImage = nil
      return
    }
    if let cached = ChatAvatarImageStore.cached(for: normalized) {
      avatarImage = cached
      return
    }
    let loaded = await ChatAvatarImageStore.load(from: normalized)
    guard !Task.isCancelled, avatarImageURI == normalized else { return }
    if let loaded {
      avatarImage = loaded
    }
  }
}

struct AppChatNavigationHeaderView: View {
  let route: ChatRoute
  let palette: AppThemePalette

  private var subtitle: String {
    if route.chatId == "saved_messages" {
      return "Saved Messages"
    }
    if route.isGroup {
      return route.roomParticipantSubtitle
    }
    return route.peerUserId == nil || !route.hasPeerResponse ? "" : "last seen recently"
  }

  var body: some View {
    GlassEffectContainer(spacing: 0.0) {
      headerContent
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(width: 172, height: 44)
        .glassEffect(.regular.interactive(true), in: .capsule)
    }
      .frame(width: 172, height: 44)
      .transaction { transaction in
        transaction.disablesAnimations = true
      }
  }

  private var headerContent: some View {
    VStack(alignment: .center, spacing: 0) {
      Text(route.title.isEmpty ? "Chat" : route.title)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(palette.text)
        .multilineTextAlignment(.center)
        .lineLimit(1)
        .truncationMode(.tail)

      if !subtitle.isEmpty {
        Text(subtitle)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(palette.secondaryText)
          .multilineTextAlignment(.center)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
  }
}

struct AppChatNavigationBackButton: View {
  let unreadCount: Int
  let palette: AppThemePalette
  let action: () -> Void

  private var displayedUnreadCount: Int {
    min(max(0, unreadCount), 99)
  }

  var body: some View {
    Button(action: action) {
      Image(systemName: "chevron.left")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(palette.text)
        .frame(width: 36, height: 44, alignment: .center)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .transaction { transaction in
      transaction.disablesAnimations = true
    }
    .accessibilityLabel(
      displayedUnreadCount > 0 ? "Back, \(unreadCount) unread messages" : "Back"
    )
  }
}

struct AppChatNavigationAvatarButton: View {
  let route: ChatRoute
  let palette: AppThemePalette
  let action: () -> Void
  @Environment(\.colorScheme) private var colorScheme
  @State private var avatarImage: UIImage?
  @State private var avatarImageURI: String?

  private var fallbackText: String {
    let trimmed = route.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "U" : String(trimmed.prefix(1)).uppercased()
  }

  var body: some View {
    Button {
      guard route.chatId != "saved_messages" else { return }
      action()
    } label: {
      ZStack {
        avatarContent
          .frame(width: 30, height: 30)
          .clipShape(Circle())
          .overlay(Circle().stroke(palette.secondaryText.opacity(0.16), lineWidth: 0.5))
      }
        .frame(width: 36, height: 44)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(route.chatId == "saved_messages")
    .transaction { transaction in
      transaction.disablesAnimations = true
    }
    .accessibilityLabel(route.chatId == "saved_messages" ? "Saved Messages" : "Open profile")
  }

  @ViewBuilder
  private var avatarContent: some View {
    if route.chatId == "saved_messages" {
      ZStack {
        LinearGradient(
          colors: [
            Color(red: 43 / 255, green: 165 / 255, blue: 181 / 255),
            Color(red: 0 / 255, green: 122 / 255, blue: 124 / 255),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        Image(systemName: "bookmark.fill")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.white)
      }
    } else {
      ZStack {
        fallbackAvatar
        if avatarImageURI == normalizedAvatarURI(route.avatarURI), let avatarImage {
          Image(uiImage: avatarImage)
            .resizable()
            .scaledToFill()
        }
      }
      .task(id: route.avatarURI ?? "") {
        await loadAvatarImage(route.avatarURI)
      }
    }
  }
    @ViewBuilder
    private var fallbackAvatar: some View {
      let colors = routeAvatarGradientColors(route: route)
      ZStack {
        LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
        Text(fallbackText)
          .font(.system(size: 16, weight: .bold))
          .lineLimit(1)
          .minimumScaleFactor(0.5)
          .foregroundStyle(.white)
      }
    }

  private func routeAvatarGradientColors(route: ChatRoute) -> [Color] {
    let colors = ChatProfileAppearanceStore.avatarColors(
      title: route.title,
      peerUserId: route.peerUserId,
      chatId: route.chatId
    )
    return [Color(uiColor: colors.0), Color(uiColor: colors.1)]
  }

  private func normalizedAvatarURI(_ rawValue: String?) -> String? {
    let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }

  @MainActor
  private func loadAvatarImage(_ rawValue: String?) async {
    let normalized = normalizedAvatarURI(rawValue)
    if avatarImageURI != normalized {
      avatarImageURI = normalized
      if let normalized, let cached = ChatAvatarImageStore.cached(for: normalized) {
        avatarImage = cached
      } else if normalized == nil {
        avatarImage = nil
      }
    }
    guard let normalized else {
      avatarImage = nil
      return
    }
    if let cached = ChatAvatarImageStore.cached(for: normalized) {
      avatarImage = cached
      return
    }
    let loaded = await ChatAvatarImageStore.load(from: normalized)
    guard !Task.isCancelled, avatarImageURI == normalized else { return }
    if let loaded {
      avatarImage = loaded
    }
  }
}

private extension Color {
  init?(hexString: String) {
    var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
    self.init(
      red: Double((value >> 16) & 0xFF) / 255.0,
      green: Double((value >> 8) & 0xFF) / 255.0,
      blue: Double(value & 0xFF) / 255.0
    )
  }
}

/// Home principal header tree (hard-refreshed): Connecting → Updating → Chats.
private enum AppHomeHeaderState: Equatable {
  case connecting
  case updating
  case ready

  var title: String {
    switch self {
    case .connecting: return "Connecting"
    case .updating: return "Updating"
    case .ready: return "Chats"
    }
  }

  var showsProgress: Bool {
    switch self {
    case .ready: return false
    case .connecting, .updating: return true
    }
  }
}

private struct AppHomeStatusHeaderView: View {
  let state: AppHomeHeaderState
  let palette: AppThemePalette

  private static let spinnerSize: CGFloat = 12

  var body: some View {
    // Centered principal: spinner (no status dot) + title.
    HStack(spacing: 6) {
      if state.showsProgress {
        AppLineLoadingSpinner(
          size: Self.spinnerSize,
          lineWidth: 1.65,
          color: palette.secondaryText
        )
        .frame(width: Self.spinnerSize, height: Self.spinnerSize)
      }

      Text(state.title)
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(palette.text)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
        .id(state)
    }
    .frame(maxWidth: .infinity, minHeight: 22, alignment: .center)
    .transaction { $0.animation = nil }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(state.title)
  }
}

private struct AppShellEmptyStateView: View {
  let icon: String
  let title: String
  let message: String
  let buttonTitle: String?
  let palette: AppThemePalette
  let action: (() -> Void)?

  var body: some View {
    VStack(spacing: 18) {
      if icon.hasPrefix("<?xml") || icon.hasPrefix("<svg") {
        AppAnimatedSVGView(svgString: icon)
          .frame(width: 120, height: 120)
      } else {
        Image(systemName: icon)
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(palette.accent)
      }

      VStack(spacing: 8) {
        Text(title)
          .font(.system(size: 24, weight: .bold))
          .foregroundStyle(palette.text)

        Text(message)
          .font(.system(size: 15))
          .foregroundStyle(palette.secondaryText)
          .multilineTextAlignment(.center)
      }

      if let buttonTitle, let action {
        Button(buttonTitle, action: action)
          .buttonStyle(AppPrimaryCapsuleButtonStyle(palette: palette))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(.horizontal, 30)
  }
}

/// Centered home-list loading placeholder — thin line spinner (not system ProgressView).
private struct AppListLoadingView: View {
  let palette: AppThemePalette
  var caption: String = "Loading"
  @State private var appeared = false

  var body: some View {
    VStack(spacing: 16) {
      AppLineLoadingSpinner(
        size: 28,
        lineWidth: 2.0,
        color: palette.secondaryText.opacity(0.85)
      )
      Text(caption)
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(palette.secondaryText.opacity(0.85))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .opacity(appeared ? 1 : 0)
    .scaleEffect(appeared ? 1 : 0.94)
    .onAppear {
      withAnimation(.easeOut(duration: 0.28)) {
        appeared = true
      }
    }
  }
}

/// Thin circular line spinner — open arc + continuous rotation (header + page load).
private struct AppLineLoadingSpinner: View {
  var size: CGFloat = 14
  var lineWidth: CGFloat = 1.75
  var color: Color = Color.secondary
  /// Full rotation period in seconds.
  var period: Double = 0.85

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
      let t = context.date.timeIntervalSinceReferenceDate
      let angle = (t.truncatingRemainder(dividingBy: period) / period) * 360.0
      Circle()
        .trim(from: 0.08, to: 0.78)
        .stroke(
          color,
          style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        )
        .frame(width: size, height: size)
        .rotationEffect(.degrees(angle))
    }
    .frame(width: size, height: size)
    .accessibilityLabel("Loading")
  }
}

private struct AppPrimaryCapsuleButtonStyle: ButtonStyle {
  let palette: AppThemePalette

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 16, weight: .semibold))
      .foregroundStyle(palette.buttonText)
      .padding(.horizontal, 22)
      .frame(height: 48)
      .background(
        Capsule(style: .continuous)
          .fill(configuration.isPressed ? palette.button.opacity(0.82) : palette.button)
      )
      .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

private struct AppToastBanner: View {
  let presentation: AppToastController.Presentation
  let palette: AppThemePalette

  private var tint: Color {
    switch presentation.category {
    case .info: return .blue
    case .success: return .green
    case .error: return .red
    case .progress: return .blue
    }
  }

  var body: some View {
    HStack(spacing: 10) {
      CategoryGlyph(category: presentation.category, tint: tint)
      Text(presentation.message)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(palette.text)
        .lineLimit(3)
        .contentTransition(.opacity)
    }
    .padding(.leading, 10)
    .padding(.trailing, 15)
    .padding(.vertical, 9)
    .frame(maxWidth: 420, alignment: .leading)
    .background {
      let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
      shape
        .fill(.regularMaterial)
        .overlay(shape.fill(palette.card.opacity(0.76)))
    }
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(palette.border.opacity(0.86), lineWidth: 0.75)
    )
    .shadow(color: Color.black.opacity(0.16), radius: 16, y: 7)
  }

  private struct CategoryGlyph: View {
    let category: AppToastController.Category
    let tint: Color
    @State private var active = false

    private var systemImage: String {
      switch category {
      case .info: return "info"
      case .success: return "checkmark"
      case .error: return "exclamationmark"
      case .progress: return "arrow.triangle.2.circlepath"
      }
    }

    var body: some View {
      ZStack {
        Circle().fill(tint.opacity(0.16))
        Image(systemName: systemImage)
          .font(.system(size: 13, weight: .bold))
          .foregroundStyle(tint)
          .scaleEffect(active ? 1 : 0.55)
          .rotationEffect(.degrees(category == .progress ? (active ? 360 : 0) : (active ? 0 : -14)))
      }
      .frame(width: 28, height: 28)
      .animation(
        category == .progress
          ? .linear(duration: 0.9).repeatForever(autoreverses: false)
          : .spring(response: 0.34, dampingFraction: 0.52),
        value: active
      )
      .onAppear { active = true }
    }
  }
}

private struct ContactSearchView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  let config: AppSessionConfig
  let homeRows: [ChatHomeListRow]
  let onResult: ([String: Any]) -> Void
  @State private var query = ""
  @State private var savedUserIDs = Set<String>()
  @State private var isSearchPresented = false
  @State private var isShowingNewContact = false
  @State private var isShowingChannelCreation = false

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    contactList
      .listStyle(.plain)
      .background(palette.background.ignoresSafeArea())
      .navigationTitle("New Message")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(
        text: $query,
        isPresented: $isSearchPresented,
        placement: .navigationBarDrawer(displayMode: .automatic),
        prompt: "Username, phone, or ID"
      )
      .onChange(of: query) { _, _ in
        // Main-sheet search is intentionally local; server lookup lives in New Contact.
      }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            onResult(["action": "cancel"])
            dismiss()
          } label: {
            Image(systemName: "xmark")
          }
        }
      }
      .sheet(isPresented: $isShowingNewContact) {
        NavigationStack {
          NewContactSearchView(config: config) { payload in
            isShowingNewContact = false
            onResult(payload)
          }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
      }
      .sheet(isPresented: $isShowingChannelCreation) {
        ChannelCreationSheet(config: config, homeRows: homeRows) { route in
          isShowingChannelCreation = false
          onResult(["action": "createdRoom", "route": route])
        }
      }
  }

  private var contactList: some View {
    List {
      actionSection
      contentSection
    }
  }

  private var actionSection: some View {
    Section {
      ContactSearchActionRow(
        title: "New Group",
        systemImage: "person.2",
        palette: palette
      ) {
        onResult(["action": "newGroup"])
        dismiss()
      }

      ContactSearchActionRow(
        title: "New Contact",
        systemImage: "person.badge.plus",
        palette: palette
      ) {
        isShowingNewContact = true
      }

      ContactSearchActionRow(
        title: "New Channel",
        systemImage: "megaphone",
        palette: palette
      ) {
        isShowingChannelCreation = true
      }
    }
    .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
    .listRowBackground(Color.clear)
    .listRowSeparator(.hidden)
    .listSectionSeparator(.hidden, edges: .top)
    .listSectionSeparator(.visible, edges: .bottom)
    .listSectionSeparatorTint(palette.border)
  }



  @ViewBuilder
  private var contentSection: some View {
    let users = filteredUsers
    if !users.isEmpty {
      groupedUsersSection(users: users)
    } else {
      statusSection
    }
  }

  private var filteredUsers: [ContactSearchUser] {
    let rows = homeRows.filter { row in
      guard !trimmedQuery.isEmpty else { return true }
      return row.title.localizedCaseInsensitiveContains(trimmedQuery)
        || row.preview.localizedCaseInsensitiveContains(trimmedQuery)
        || (row.peerUserId?.localizedCaseInsensitiveContains(trimmedQuery) == true)
    }
    return rows.compactMap(contactUser(for:))
  }

  private func groupedUsersSection(users: [ContactSearchUser]) -> some View {
    var uniqueUsers: [ContactSearchUser] = []
    var seenIDs = Set<String>()
    for user in users {
      if !seenIDs.contains(user.userID) {
        seenIDs.insert(user.userID)
        uniqueUsers.append(user)
      }
    }
    let grouped = Dictionary(grouping: uniqueUsers) { user in
      String(user.username.prefix(1)).uppercased()
    }
    let sortedKeys = grouped.keys.sorted()

    return ForEach(sortedKeys, id: \.self) { letter in
      Section {
        ForEach(grouped[letter]!) { user in
          ContactSearchResultRow(
            user: user,
            isSaved: savedUserIDs.contains(user.userID),
            palette: palette,
            avatarSize: 46,
            rowHorizontalPadding: 12,
            rowVerticalPadding: 7,
            rowMinHeight: 64,
            showsSeparator: true
          )
          .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
          .listRowSeparator(.hidden)
          .contentShape(Rectangle())
          .onTapGesture { open(user, action: "chat") }
          .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
              open(user, action: "call")
            } label: {
              Label("Call", systemImage: "phone.fill")
            }
            .tint(palette.accent)

            if !savedUserIDs.contains(user.userID) {
              Button {
                savedUserIDs.insert(user.userID)
                onResult(["action": "saveContact", "user": user.payload])
              } label: {
                Label("Add", systemImage: "person.badge.plus")
              }
              .tint(palette.accent)
            }
          }
        }
      } header: {
        Text(letter)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(palette.secondaryText)
          .textCase(nil)
      }
    }
  }

  private var statusSection: some View {
    Section {
      ContactSearchStatusView(
        isLoading: false,
        hasSearched: !trimmedQuery.isEmpty,
        message: trimmedQuery.isEmpty ? "" : "No people found in your chats.",
        palette: palette
      )
      .frame(maxWidth: .infinity)
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
    }
  }



  private func contactUser(for row: ChatHomeListRow) -> ContactSearchUser {
    ContactSearchUser(payload: [
      "userId": row.peerUserId ?? row.chatId,
      "username": row.title,
      "displayName": row.title,
      "profileImage": row.avatarUri ?? "",
      "isAgent": row.isAgentFriend,
      "agentId": row.peerAgentId ?? "",
      "tier": row.peerTier ?? "",
    ])!
  }


  private func open(_ user: ContactSearchUser, action: String) {
    onResult(["action": action, "user": user.payload])
    dismiss()
  }
}

/// Compact existing-chat row for the Home search drawer ("Chats" section).
/// Home-list style row used in the searchable drawer. Matches the native
/// `ChatHomeCardCell` layout: 56pt avatar, title/preview/time, same gradient
/// fallback via `ChatProfileAppearanceStore`, and agent CDN avatars when known.
private struct HomeSearchChatRow: View {
  let row: ChatHomeListRow
  let palette: AppThemePalette
  let isDark: Bool

  var body: some View {
    HStack(spacing: 12) {
      HomeListStyleAvatar(
        title: row.title,
        peerUserId: row.peerUserId,
        chatId: row.chatId,
        avatarURI: resolvedAvatarURI,
        fallback: row.avatarFallback,
        isDark: isDark,
        palette: palette,
        isGroupOrChannel: row.isGroup || row.isChannel
      )

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(row.title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(palette.text)
            .lineLimit(1)
          if row.isGoldTier {
            Image(systemName: "checkmark.seal.fill")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(Color(red: 1.0, green: 205 / 255, blue: 84 / 255))
          }
          Spacer(minLength: 8)
          if !row.timeLabel.isEmpty {
            Text(row.timeLabel)
              .font(.system(size: 13, weight: .regular))
              .foregroundStyle(palette.secondaryText)
          }
        }

        HStack(spacing: 6) {
          Text(row.isTyping ? "typing..." : row.preview)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(
              row.isTyping
                ? Color(red: 43 / 255, green: 135 / 255, blue: 210 / 255)
                : palette.secondaryText
            )
            .lineLimit(1)
          Spacer(minLength: 4)
          if row.muted {
            Image(systemName: "bell.slash.fill")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(palette.secondaryText.opacity(0.75))
          }
          if row.pinned {
            Image(systemName: "pin.fill")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(palette.secondaryText.opacity(0.75))
          }
          if row.unreadCount > 0 || row.markedUnread {
            Text(row.unreadCount > 0 ? "\(row.unreadCount)" : " ")
              .font(.system(size: 12, weight: .bold))
              .foregroundStyle(isDark ? Color.black : Color.white)
              .padding(.horizontal, row.unreadCount > 0 ? 7 : 5)
              .padding(.vertical, 2)
              .background(
                Capsule(style: .continuous)
                  .fill(
                    isDark
                      ? Color(red: 157 / 255, green: 216 / 255, blue: 255 / 255)
                      : Color(red: 23 / 255, green: 132 / 255, blue: 209 / 255)
                  )
              )
          }
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(minHeight: 76)
    .contentShape(Rectangle())
  }

  private var resolvedAvatarURI: String? {
    ChatAvatarURLResolver.resolve(
      rawAvatar: row.avatarUri,
      peerUserId: row.peerUserId,
      chatId: row.chatId,
      preferPushAvatar: false,
      isAgent: row.isAgentFriend,
      agentId: row.peerAgentId,
      displayName: row.title
    )
  }

  static func agentAvatarURL(for provider: String) -> String? {
    ChatAvatarURLResolver.bridgeAgentAvatarURL(for: provider)
  }
}

/// Shared circular avatar used by home search rows — same gradient seed + CDN
/// fetch path as the native home list cells (`ChatAvatarImageStore`, not AsyncImage).
private struct HomeListStyleAvatar: View {
  let title: String
  let peerUserId: String?
  let chatId: String?
  let avatarURI: String?
  let fallback: String
  let isDark: Bool
  let palette: AppThemePalette
  var isGroupOrChannel: Bool = false
  var size: CGFloat = 56

  @State private var loadedImage: UIImage?

  var body: some View {
    ZStack {
      Circle()
        .fill(
          LinearGradient(
            colors: [Color(uiColor: gradient.0), Color(uiColor: gradient.1)],
            startPoint: .top,
            endPoint: .bottom
          )
        )
      if let loadedImage {
        Image(uiImage: loadedImage)
          .resizable()
          .scaledToFill()
      } else {
        initials
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .task(id: avatarURI) {
      await loadAvatar()
    }
  }

  private var gradient: (UIColor, UIColor) {
    ChatProfileAppearanceStore.avatarColors(
      title: title,
      peerUserId: peerUserId,
      chatId: chatId
    )
  }

  private var initials: some View {
    Text(
      isGroupOrChannel
        ? ChatAvatarNodeView.fallbackText(from: title, isGroupOrChannel: true)
        : String((fallback.isEmpty ? title : fallback).prefix(2)).uppercased()
    )
      .font(.system(size: size * 0.34, weight: .bold))
      .foregroundStyle(.white)
  }

  @MainActor
  private func loadAvatar() async {
    let uri = avatarURI?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !uri.isEmpty else {
      // No URL — only clear if we must; initials show underneath.
      loadedImage = nil
      return
    }
    // Memory/disk seed: paint before any await (kills cold-launch flash).
    if let cached = ChatAvatarImageStore.cached(for: uri) {
      withAnimation(.easeInOut(duration: 0.18)) {
        loadedImage = cached
      }
      return
    }
    // Keep previous image while fetching (no blank → initials pop).
    let previous = loadedImage
    let image = await ChatAvatarImageStore.load(from: uri)
    let current = avatarURI?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard current == uri else { return }
    if let image {
      withAnimation(.easeInOut(duration: 0.22)) {
        loadedImage = image
      }
    } else if previous == nil {
      loadedImage = nil
    }
  }
}

struct ContactSearchResultRow: View {
  let user: ContactSearchUser
  let isSaved: Bool
  let palette: AppThemePalette
  var avatarSize: CGFloat = 56
  var rowHorizontalPadding: CGFloat = 16
  var rowVerticalPadding: CGFloat = 12
  var rowMinHeight: CGFloat = 76
  var showsSeparator: Bool = false
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack(spacing: 12) {
      HomeListStyleAvatar(
        title: user.username,
        peerUserId: user.userID,
        chatId: nil,
        avatarURI: resolvedProfileImage,
        fallback: String(user.username.prefix(2)),
        isDark: colorScheme == .dark,
        palette: palette,
        size: avatarSize
      )

      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(user.username)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(palette.text)
          if user.isGoldTier {
            Image(systemName: "checkmark.seal.fill")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(Color(red: 1.0, green: 205 / 255, blue: 84 / 255))
          }
        }
        .lineLimit(1)

        Text(subtitleText)
          .font(.system(size: 14, weight: .regular))
          .foregroundStyle(palette.secondaryText)
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      if isSaved {
        Image(systemName: "checkmark.circle.fill")
          .foregroundStyle(palette.accent)
      }
    }
    .padding(.horizontal, rowHorizontalPadding)
    .padding(.vertical, rowVerticalPadding)
    .frame(minHeight: rowMinHeight)
    .overlay(alignment: .bottom) {
      if showsSeparator {
        Rectangle()
          .fill(palette.border.opacity(0.75))
          .frame(height: 0.5)
          .padding(.leading, rowHorizontalPadding + avatarSize + 12)
      }
    }
    .contentShape(Rectangle())
  }

  private var subtitleText: String {
    if user.isAgent || user.bridgeProvider != nil {
      return "Open and start session"
    }
    return ChatEngine.shared.lastSeenTimestampMs(userId: user.userID).flatMap { timestamp -> String? in
      guard timestamp > 0 else { return nil }
      let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
      let formatter = RelativeDateTimeFormatter()
      formatter.unitsStyle = .short
      let relative = formatter.localizedString(for: date, relativeTo: Date())
      let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : "last seen \(trimmed)"
    } ?? "last seen recently"
  }

  /// Same resolver as the home list: agent CDN mark when the peer is Claude/Codex/
  /// Grok/Agy, otherwise payload image / push-avatar.
  private var resolvedProfileImage: String? {
    ChatAvatarURLResolver.resolve(
      rawAvatar: user.profileImage,
      peerUserId: user.userID,
      chatId: nil,
      preferPushAvatar: false,
      isAgent: user.isAgent || user.bridgeProvider != nil,
      agentId: user.agentId ?? user.bridgeAgentRouteId,
      displayName: user.handle ?? user.username
    )
  }
}

private struct ContactActionSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  let user: ContactSearchUser
  let onChat: () -> Void
  let onCall: () -> Void

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          VStack(spacing: 10) {
            HomeListStyleAvatar(
              title: user.username,
              peerUserId: user.userID,
              chatId: nil,
              avatarURI: ChatAvatarURLResolver.resolve(
                rawAvatar: user.profileImage,
                peerUserId: user.userID,
                chatId: nil,
                preferPushAvatar: false,
                isAgent: user.isAgent || user.bridgeProvider != nil,
                agentId: user.agentId ?? user.bridgeAgentRouteId,
                displayName: user.handle ?? user.username
              ),
              fallback: String(user.username.prefix(2)),
              isDark: colorScheme == .dark,
              palette: palette,
              size: 88
            )

            Text(user.username)
              .font(.system(size: 22, weight: .semibold))
              .foregroundStyle(palette.text)
              .lineLimit(1)

            Text(user.subtitle)
              .font(.system(size: 14, weight: .regular))
              .foregroundStyle(palette.secondaryText)
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 12)
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
        }

        Section {
          HStack(spacing: 12) {
            ContactActionButton(title: "Chat", systemImage: "message.fill") {
              dismiss()
              onChat()
            }
            ContactActionButton(title: "Call", systemImage: "phone.fill") {
              dismiss()
              onCall()
            }
          }
          .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
        }
      }
      .listStyle(.insetGrouped)
      .scrollContentBackground(.hidden)
      .background(palette.background.ignoresSafeArea())
      .navigationTitle("Contact")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 13, weight: .semibold))
          }
          .accessibilityLabel("Close")
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }
}

private struct ContactActionButton: View {
  let title: String
  let systemImage: String
  let action: () -> Void
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Button(action: action) {
      VStack(spacing: 6) {
        Image(systemName: systemImage)
          .font(.system(size: 18, weight: .semibold))
        Text(title)
          .font(.system(size: 13, weight: .semibold))
      }
      .foregroundStyle(colorScheme == .dark ? Color.white : Color.primary)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 14)
      .background {
        if #available(iOS 26.0, *) {
          Capsule(style: .continuous)
            .fill(.clear)
            .glassEffect(.regular.interactive(true), in: .capsule)
        } else {
          Capsule(style: .continuous)
            .fill(.regularMaterial)
        }
      }
    }
    .buttonStyle(.plain)
  }
}

private struct ContactSearchActionRow: View {
  let title: String
  let systemImage: String
  let palette: AppThemePalette
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: systemImage)
          .font(.system(size: 18, weight: .regular))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(palette.accent)
          .frame(width: 28, height: 28)

        Text(title)
          .font(.system(size: 16, weight: .regular))
          .foregroundStyle(palette.accent)
          .lineLimit(1)
          .minimumScaleFactor(0.82)

        Spacer(minLength: 8)
      }
      .padding(.vertical, 3)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// Server-backed lookup kept separate from the local New Message list.
private struct NewContactSearchView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @FocusState private var focusedField: Field?

  private enum Field {
    case firstName
    case lastName
    case query
  }

  let config: AppSessionConfig
  let onResult: ([String: Any]) -> Void

  @State private var firstName = ""
  @State private var lastName = ""
  @State private var query = ""
  @State private var results: [ContactSearchUser] = []
  @State private var selectedUser: ContactSearchUser?
  @State private var isLoading = false
  @State private var hasSearched = false
  @State private var statusText = ""
  @State private var searchTask: Task<Void, Never>?

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    List {
      Section {
        HStack(spacing: 12) {
          TextField("First Name", text: $firstName)
            .focused($focusedField, equals: .firstName)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
          Divider()
            .frame(height: 22)
          TextField("Last Name", text: $lastName)
            .focused($focusedField, equals: .lastName)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
        }
        .font(.system(size: 16, weight: .regular))

        HStack(spacing: 10) {
          TextField("Username", text: $query)
            .focused($focusedField, equals: .query)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.default)
          if isLoading {
            ProgressView()
              .controlSize(.small)
          }
        }
        .font(.system(size: 16, weight: .regular))
      }

      if results.isEmpty {
        if isLoading || hasSearched || !statusText.isEmpty {
          Section {
            ContactSearchStatusView(
              isLoading: isLoading,
              hasSearched: hasSearched,
              message: statusText,
              palette: palette
            )
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
          }
        }
      } else {
        Section("People") {
          ForEach(results) { user in
            let isSelected = selectedUser?.userID == user.userID
            ContactSearchResultRow(
              user: user,
              isSaved: isSelected,
              palette: palette,
              avatarSize: 46,
              rowHorizontalPadding: 4,
              rowVerticalPadding: 6,
              rowMinHeight: 56,
              showsSeparator: false
            )
            .listRowBackground(
              isSelected ? palette.accent.opacity(0.12) : nil
            )
            .contentShape(Rectangle())
            .onTapGesture {
              selectedUser = user
              focusedField = nil
            }
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("New Contact")
    .navigationBarTitleDisplayMode(.inline)
    .onChange(of: query) { _, newValue in
      scheduleSearch(query: newValue)
    }
    .onDisappear { searchTask?.cancel() }
    .task {
      focusedField = .query
      statusText = "Search by username."
    }
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button { dismiss() } label: {
          Image(systemName: "xmark")
        }
        .accessibilityLabel("Close")
      }

      ToolbarItem(placement: .topBarTrailing) {
        Button {
          if let selectedUser {
            save(selectedUser)
          }
        } label: {
          Image(systemName: "checkmark")
        }
        .tint(palette.accent)
        .disabled(selectedUser == nil)
        .accessibilityLabel("Save contact")
      }
    }
  }

  private func scheduleSearch(query rawQuery: String) {
    searchTask?.cancel()
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      results = []
      selectedUser = nil
      isLoading = false
      hasSearched = false
      statusText = "Search by username or phone number."
      return
    }

    isLoading = true
    searchTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 300_000_000)
      guard !Task.isCancelled else { return }
      do {
        let found = try await ContactSearchService.search(config: config, query: query)
        guard !Task.isCancelled else { return }
        results = found
        isLoading = false
        hasSearched = true
        if found.count == 1 {
          selectedUser = found[0]
        } else if let current = selectedUser,
          found.contains(where: { $0.userID == current.userID })
        {
          selectedUser = current
        } else {
          selectedUser = nil
        }
        statusText = found.isEmpty ? "No user found for “\(query)”." : ""
      } catch {
        guard !Task.isCancelled else { return }
        results = []
        isLoading = false
        hasSearched = true
        statusText = error.localizedDescription
      }
    }
  }

  private func save(_ user: ContactSearchUser) {
    var payload = user.payload
    let fullName = [firstName, lastName]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    if !fullName.isEmpty {
      payload["contactName"] = fullName
      payload["displayName"] = fullName
    }
    dismiss()
    onResult(["action": "saveContact", "user": payload])
  }
}

private struct ContactSearchStatusView: View {
  let isLoading: Bool
  let hasSearched: Bool
  let message: String
  let palette: AppThemePalette

  var body: some View {
    VStack(spacing: 12) {
      if isLoading {
        ProgressView()
          .tint(palette.secondaryText)
        Text("Searching…")
          .font(.footnote)
          .foregroundStyle(palette.secondaryText)
      } else {
        Image(systemName: hasSearched ? "person.fill.questionmark" : "magnifyingglass")
          .font(.system(size: 30, weight: .regular))
          .foregroundStyle(palette.secondaryText.opacity(0.7))
        Text(displayMessage)
          .font(.footnote)
          .multilineTextAlignment(.center)
          .foregroundStyle(palette.secondaryText)
      }
    }
    .padding(.vertical, 36)
  }

  private var displayMessage: String {
    if !message.isEmpty { return message }
    return hasSearched
      ? "No people found."
      : "Find people by username, phone number, or user ID to start a new chat."
  }
}

struct ContactSearchUser: Identifiable, Hashable, Equatable {
  static func == (lhs: ContactSearchUser, rhs: ContactSearchUser) -> Bool {
    lhs.userID == rhs.userID
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(userID)
  }
  let userID: String
  let username: String
  let handle: String?
  let phoneNumber: String?
  let profileImage: String?
  let publicKey: String?
  let tier: String?
  /// Server `isAgent` flag — true for Claude/Codex (and any other agent shadow user).
  let isAgent: Bool
  /// Server `agentId` — the attached agent's id when `isAgent` is true.
  let agentId: String?

  var id: String { userID }

  var isGoldTier: Bool {
    tier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "gold"
  }

  /// `"claude"` / `"codex"` / `"grok"` when this search result is a computer-bridge agent.
  var bridgeProvider: String? {
    ChatRoute.resolveBridgeProvider(
      peerUserId: userID,
      name: handle ?? username,
      isAgent: isAgent,
      agentId: agentId
    )
  }

  /// `peerAgentId` to bind for engine routing. For a real agent it's the agent id.
  /// For a bridge agent (Claude/Codex, which have no Agent record) it's the shadow
  /// user id — a non-empty value makes the engine send the message in cleartext
  /// (the server resolves the bridge worker from the DM participant) instead of
  /// E2E-encrypting to the agent's placeholder key, which would fail.
  var bridgeAgentRouteId: String? {
    if bridgeProvider != nil { return userID }
    return agentId
  }

  var subtitle: String {
    if let phoneNumber { return phoneNumber }
    if let handle, !handle.isEmpty, !Self.looksLikeUUID(handle), handle.localizedCaseInsensitiveCompare(username) != .orderedSame {
      return "@\(handle.trimmingCharacters(in: CharacterSet(charactersIn: "@")))"
    }
    return "User is in Vibegram"
  }

  var payload: [String: Any] {
    var value: [String: Any] = [
      "userId": userID,
      "id": userID,
      "username": username,
      "displayName": username,
    ]
    if let handle { value["handle"] = handle }
    if let phoneNumber { value["phoneNumber"] = phoneNumber }
    if let profileImage { value["profileImage"] = profileImage }
    if let publicKey { value["publicKey"] = publicKey }
    if let tier { value["tier"] = tier }
    if isAgent { value["isAgent"] = true }
    if let agentId { value["agentId"] = agentId }
    return value
  }

  init?(payload: [String: Any]) {
    guard let userID = Self.normalizedString(payload["userId"] ?? payload["id"]) else {
      return nil
    }

    self.userID = userID
    let rawHandle = Self.normalizedString(payload["username"] ?? payload["handle"])
    let rawDisplayName =
      Self.normalizedString(
        payload["displayName"] ?? payload["display_name"] ?? payload["fullName"] ?? payload["full_name"]
          ?? payload["name"])
      ?? rawHandle
    self.username =
      rawDisplayName.flatMap { Self.looksLikeUUID($0) ? nil : $0 }
      ?? rawHandle.flatMap { Self.looksLikeUUID($0) ? nil : $0 }
      ?? "Vibegram User"
    self.handle = rawHandle
    self.phoneNumber = Self.normalizedString(payload["phoneNumber"] ?? payload["phone_number"] ?? payload["phone"])
    self.profileImage = Self.normalizedString(
      payload["profileImage"] ?? payload["profile_image"] ?? payload["avatarUrl"] ?? payload["avatar_url"])
    self.publicKey = Self.normalizedString(
      payload["publicKey"] ?? payload["public_key"] ?? payload["friendKey"] ?? payload["friendPublicKey"])
    self.tier = Self.normalizedString(
      payload["tier"] ?? payload["friendTier"] ?? payload["friend_tier"] ?? payload["peerTier"]
        ?? payload["peer_tier"] ?? payload["badge"] ?? payload["badgeTier"] ?? payload["badge_tier"])
    self.isAgent = Self.boolValue(payload["isAgent"] ?? payload["is_agent"])
    self.agentId = Self.normalizedString(
      payload["agentId"] ?? payload["agent_id"] ?? payload["friendAgentId"] ?? payload["friend_agent_id"])
  }

  private static func boolValue(_ value: Any?) -> Bool {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String { return ["true", "1", "yes"].contains(value.lowercased()) }
    return false
  }

  private static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }

  private static func looksLikeUUID(_ value: String) -> Bool {
    UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
  }
}

private enum AppSessionRefreshError: LocalizedError {
  case missingSecret

  var errorDescription: String? {
    switch self {
    case .missingSecret:
      return "Session expired. Sign in again."
    }
  }
}

private enum AppSessionRefreshService {
  static func refresh(config: AppSessionConfig) async throws -> AppSessionConfig {
    let rawSecret = SecureKeyStore.shared.retrieveSecret(key: "loginSecret")
    guard
      let secret = rawSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
      !secret.isEmpty
    else {
      throw AppSessionRefreshError.missingSecret
    }

    let result = try await NativeAuthService.signIn(
      secret: secret,
      apiBaseURLString: config.apiBaseURLString,
      transportMode: config.transportMode
    )
    AppSessionConfig.store(result.config)
    _ = SecureKeyStore.shared.storeSecret(key: "loginSecret", value: secret)
    return result.config
  }
}

private func appShellServerErrorMessage(
  statusCode: Int,
  body: String,
  fallback: String
) -> String {
  if
    let data = body.data(using: .utf8),
    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let message = (object["message"] ?? object["error"] ?? object["reason"]) as? String
  {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      return statusCode == 401 ? trimmed : "\(fallback) (\(statusCode)): \(trimmed)"
    }
  }

  let trimmed = appShellSanitizedServerBody(body)
  return trimmed.isEmpty ? "\(fallback) (\(statusCode))." : "\(fallback) (\(statusCode)): \(trimmed)"
}

private func appShellSanitizedServerBody(_ body: String) -> String {
  let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty { return "" }
  let lowered = trimmed.lowercased()
  if lowered.hasPrefix("<!doctype") || lowered.hasPrefix("<html") || lowered.contains("<body") {
    return ""
  }
  return String(trimmed.prefix(180))
}

enum ContactSearchService {
  static func search(config: AppSessionConfig, query: String) async throws -> [ContactSearchUser] {
    let activeConfig = AppSessionConfig.current ?? config
    do {
      return try await performSearch(config: activeConfig, query: query)
    } catch let error as ContactSearchServiceError {
      guard error.isSessionExpired else {
        throw error
      }
      let refreshedConfig = try await AppSessionRefreshService.refresh(config: activeConfig)
      return try await performSearch(config: refreshedConfig, query: query)
    }
  }

  private static func performSearch(config: AppSessionConfig, query: String) async throws -> [ContactSearchUser] {
    guard let url = buildSearchURL(apiBaseURLString: config.apiBaseURLString, query: query) else {
      throw ContactSearchServiceError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 14
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await VibeHTTP.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ContactSearchServiceError.invalidResponse
    }

    if httpResponse.statusCode == 404 {
      return []
    }

    guard (200...299).contains(httpResponse.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw ContactSearchServiceError.http(httpResponse.statusCode, body)
    }

    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return parseUsers(from: object, excluding: config.userID)
  }

  private static func buildSearchURL(apiBaseURLString: String, query: String) -> URL? {
    var base = apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }
    guard !base.isEmpty else { return nil }

    let pathBase = base.lowercased().hasSuffix("/api") ? base : "\(base)/api"
    let endpoint: String
    switch queryKind(for: query) {
    case .userID:
      let encodedID = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
      endpoint = "/user/\(encodedID)"
    case .phone:
      let encodedPhone =
        query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
      endpoint = "/user/phone/\(encodedPhone)"
    case .username:
      let normalized =
        query.hasPrefix("@") ? String(query.dropFirst()) : query
      let encodedName =
        normalized.lowercased().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        ?? normalized.lowercased()
      endpoint = "/user/name/\(encodedName)"
    }

    return URL(string: pathBase + endpoint)
  }

  private static func parseUsers(from value: Any, excluding currentUserID: String) -> [ContactSearchUser] {
    let rawEntries: [[String: Any]]
    if let array = value as? [[String: Any]] {
      rawEntries = array
    } else if let dictionary = value as? [String: Any] {
      if let nestedArray = dictionary["data"] as? [[String: Any]] {
        rawEntries = nestedArray
      } else if let nestedDictionary = dictionary["data"] as? [String: Any] {
        rawEntries = [nestedDictionary]
      } else {
        rawEntries = [dictionary]
      }
    } else {
      rawEntries = []
    }

    let currentUpper = currentUserID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    var usersByID: [String: ContactSearchUser] = [:]
    for rawEntry in rawEntries {
      guard let user = ContactSearchUser(payload: rawEntry) else { continue }
      let normalizedID = user.userID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      if normalizedID.isEmpty || normalizedID == currentUpper { continue }
      usersByID[normalizedID] = user
    }
    return Array(usersByID.values).sorted {
      $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
    }
  }

  private enum QueryKind {
    case userID
    case phone
    case username
  }

  private static func queryKind(for query: String) -> QueryKind {
    let digitsCount = query.filter(\.isNumber).count
    let phoneCharacters = Set(query).isSubset(of: Set("0123456789+-() ".map { $0 }))
    if phoneCharacters && digitsCount >= 7 {
      return .phone
    }
    if looksLikeUUID(query) {
      return .userID
    }
    return .username
  }

  private static func looksLikeUUID(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return UUID(uuidString: trimmed.uppercased()) != nil
  }
}

enum ContactSearchServiceError: LocalizedError {
  case invalidURL
  case invalidResponse
  case http(Int, String)

  var isSessionExpired: Bool {
    switch self {
    case let .http(statusCode, _):
      return statusCode == 401
    default:
      return false
    }
  }

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "The stored API configuration is invalid."
    case .invalidResponse:
      return "The server did not return a valid response."
    case let .http(statusCode, body):
      return appShellServerErrorMessage(statusCode: statusCode, body: body, fallback: "Search unavailable")
    }
  }
}

private struct ChatCreateResult {
  let chatID: String
  let messages: [[String: Any]]
}

enum ChatRoomCreationKind {
  case group
  case channel

  var displayName: String {
    switch self {
    case .group: return "Group"
    case .channel: return "Channel"
    }
  }

  var title: String {
    switch self {
    case .group: return "New Group"
    case .channel: return "New Channel"
    }
  }

  var placeholder: String {
    switch self {
    case .group: return "Group name"
    case .channel: return "Channel name"
    }
  }

  var message: String {
    switch self {
    case .group: return "Create the group now. Members can be added from the group profile."
    case .channel: return "Create a broadcast channel with you as owner."
    }
  }
}

struct ChatRoomCreateResult {
  let chatID: String
  let name: String
  let type: String
  let roomDescription: String?
  let avatarUrl: String?
  let creatorId: String?
  let role: String?
  let members: [[String: Any]]
  let memberCount: Int?
  let subscriberCount: Int?
  let createdAt: Double
  let lastMessageAt: Double
  let accessType: String
  let publicSlug: String?
  let shareLink: String?
  let joinApprovalRequired: Bool
  let restrictSavingContent: Bool
}

enum ChatRoomCreateService {
  static func create(
    kind: ChatRoomCreationKind,
    config: AppSessionConfig,
    name: String,
    description: String? = nil,
    memberIds: [String] = [],
    agentAdminIds: [String] = [],
    avatarUrl: String? = nil,
    accessType: String = "private",
    publicSlug: String? = nil,
    joinApprovalRequired: Bool = false,
    restrictSavingContent: Bool = false
  ) async throws -> ChatRoomCreateResult {
    let activeConfig = AppSessionConfig.current ?? config
    do {
      return try await createOnce(
        kind: kind, config: activeConfig, name: name, description: description,
        memberIds: memberIds, agentAdminIds: agentAdminIds, avatarUrl: avatarUrl,
        accessType: accessType, publicSlug: publicSlug,
        joinApprovalRequired: joinApprovalRequired,
        restrictSavingContent: restrictSavingContent)
    } catch let error as ChatDirectMessageServiceError {
      guard error.isSessionExpired else {
        throw error
      }
      let refreshedConfig = try await AppSessionRefreshService.refresh(config: activeConfig)
      return try await createOnce(
        kind: kind, config: refreshedConfig, name: name, description: description,
        memberIds: memberIds, agentAdminIds: agentAdminIds, avatarUrl: avatarUrl,
        accessType: accessType, publicSlug: publicSlug,
        joinApprovalRequired: joinApprovalRequired,
        restrictSavingContent: restrictSavingContent)
    }
  }

  private static func createOnce(
    kind: ChatRoomCreationKind, config: AppSessionConfig, name: String,
    description: String?, memberIds: [String], agentAdminIds: [String], avatarUrl: String?,
    accessType: String, publicSlug: String?, joinApprovalRequired: Bool,
    restrictSavingContent: Bool
  ) async throws -> ChatRoomCreateResult {
    let request = try buildRequest(
      kind: kind, config: config, name: name, description: description,
      memberIds: memberIds, agentAdminIds: agentAdminIds, avatarUrl: avatarUrl,
      accessType: accessType, publicSlug: publicSlug,
      joinApprovalRequired: joinApprovalRequired,
      restrictSavingContent: restrictSavingContent)

    switch config.transportMode {
    case .offline:
      throw ChatDirectMessageServiceError.transportUnavailable("offline")
    case .bridgeText:
      throw ChatDirectMessageServiceError.transportUnavailable("bridge_text")
    case .direct:
      let result = try await perform(
        request, fallbackName: name, session: PacketRuntime.shared.session())
      Task.detached {
        await PacketBootstrapService.prefetchIfNeeded(config: config)
      }
      return result
    }
  }

  private static func buildRequest(
    kind: ChatRoomCreationKind, config: AppSessionConfig, name: String,
    description: String?, memberIds: [String], agentAdminIds: [String], avatarUrl: String?,
    accessType: String, publicSlug: String?, joinApprovalRequired: Bool,
    restrictSavingContent: Bool
  ) throws -> URLRequest {
    var base = config.apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }

    let pathBase = base.lowercased().hasSuffix("/api") ? base : "\(base)/api"
    let endpoint: String
    switch kind {
    case .group:
      endpoint = "/group"
    case .channel:
      endpoint = "/channel"
    }
    guard let url = URL(string: "\(pathBase)\(endpoint)") else {
      throw ChatDirectMessageServiceError.invalidURL
    }

    var body: [String: Any] = ["name": name]
    if let description {
      body["description"] = description.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let avatarUrl {
      body["avatarUrl"] = avatarUrl
    }
    if case .group = kind {
      body["memberIds"] = memberIds
    } else {
      body["memberIds"] = memberIds
      body["agentAdminIds"] = agentAdminIds
      body["accessType"] = accessType
      if let publicSlug,
        !publicSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        body["publicSlug"] = publicSlug
      }
      body["joinApprovalRequired"] = joinApprovalRequired
      body["restrictSavingContent"] = restrictSavingContent
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  private static func perform(_ request: URLRequest, fallbackName: String, session: URLSession) async throws -> ChatRoomCreateResult {
    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ChatDirectMessageServiceError.invalidResponse
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw ChatDirectMessageServiceError.http(httpResponse.statusCode, body)
    }

    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    guard let payload = object as? [String: Any] else {
      throw ChatDirectMessageServiceError.invalidPayload
    }
    guard let chatID = ChatDirectMessageService.normalizedString(payload["chatId"] ?? payload["chat_id"]) else {
      throw ChatDirectMessageServiceError.invalidPayload
    }
    let name = ChatDirectMessageService.normalizedString(payload["name"]) ?? fallbackName
    let type = ChatDirectMessageService.normalizedString(payload["type"])
      ?? (request.url?.path.contains("/channel") == true ? "channel" : "group")
    let members = (payload["members"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    let createdAt = numericValue(payload["createdAt"] ?? payload["created_at"]) ?? 0
    let lastMessageAt =
      numericValue(payload["lastMessageAt"] ?? payload["last_message_at"])
      ?? createdAt
    let accessType =
      ChatDirectMessageService.normalizedString(payload["accessType"] ?? payload["access_type"])
      ?? "private"
    return ChatRoomCreateResult(
      chatID: chatID,
      name: name,
      type: type,
      roomDescription: ChatDirectMessageService.normalizedString(
        payload["description"] ?? payload["roomDescription"]),
      avatarUrl: ChatDirectMessageService.normalizedString(
        payload["avatarUrl"] ?? payload["avatar_url"]),
      creatorId: ChatDirectMessageService.normalizedString(
        payload["creatorId"] ?? payload["creator_id"]),
      role: ChatDirectMessageService.normalizedString(payload["role"]),
      members: members,
      memberCount: integerValue(payload["memberCount"] ?? payload["member_count"]),
      subscriberCount: integerValue(
        payload["subscriberCount"] ?? payload["subscriber_count"]),
      createdAt: createdAt,
      lastMessageAt: lastMessageAt,
      accessType: accessType,
      publicSlug: ChatDirectMessageService.normalizedString(
        payload["publicSlug"] ?? payload["public_slug"]),
      shareLink: ChatDirectMessageService.normalizedString(
        payload["shareLink"] ?? payload["share_link"]),
      joinApprovalRequired: boolValue(
        payload["joinApprovalRequired"] ?? payload["join_approval_required"]),
      restrictSavingContent: boolValue(
        payload["restrictSavingContent"] ?? payload["restrict_saving_content"])
    )
  }

  private static func numericValue(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let text = value as? String { return Double(text) }
    return nil
  }

  private static func integerValue(_ value: Any?) -> Int? {
    if let number = value as? NSNumber { return number.intValue }
    if let text = value as? String { return Int(text) }
    return nil
  }

  private static func boolValue(_ value: Any?) -> Bool {
    if let value = value as? Bool { return value }
    if let number = value as? NSNumber { return number.boolValue }
    if let text = value as? String {
      return ["1", "true", "yes", "on"].contains(text.lowercased())
    }
    return false
  }

  static func uploadAvatar(imageData: Data, config: AppSessionConfig) async throws -> String {
    let base = config.apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    let pathBase = base.hasSuffix("/") ? String(base.dropLast()) : base
    let endpoint = pathBase.lowercased().hasSuffix("/api") ? "/media/upload" : "/api/media/upload"
    guard let uploadURL = URL(string: "\(pathBase)\(endpoint)") else {
      throw ChatDirectMessageServiceError.invalidURL
    }

    let boundary = "----VibeAvatarBoundary\(UUID().uuidString)"
    var request = URLRequest(url: uploadURL)
    request.httpMethod = "POST"
    request.timeoutInterval = 45
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()
    let appendField = { (name: String, value: String) in
      body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
      body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8) ?? Data())
      body.append("\(value)\r\n".data(using: .utf8) ?? Data())
    }
    appendField("user_id", config.userID)
    appendField("type", "image")

    body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
    body.append("Content-Disposition: form-data; name=\"file\"; filename=\"avatar.jpg\"\r\n".data(using: .utf8) ?? Data())
    body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8) ?? Data())
    body.append(imageData)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8) ?? Data())

    let (data, response) = try await VibeHTTP.shared.upload(for: request, from: body)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw ChatDirectMessageServiceError.invalidResponse
    }
    guard
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let remoteURL = json["url"] as? String ?? json["media_url"] as? String ?? json["mediaUrl"] as? String
    else {
      throw ChatDirectMessageServiceError.invalidResponse
    }
    return remoteURL
  }
}

struct GroupMemberAddResult {
  let userId: String
  let added: Bool
}

/// `POST /api/group/:id/members` — mirrors `ChatRoomCreateService`'s
/// transport-aware request handling (direct → packet-mesh fallback, session
/// refresh on expiry).
enum GroupMembersUpdateService {
  static func addMembers(
    chatId: String, memberIds: [String], config: AppSessionConfig
  ) async throws -> [GroupMemberAddResult] {
    let activeConfig = AppSessionConfig.current ?? config
    do {
      return try await addOnce(chatId: chatId, memberIds: memberIds, config: activeConfig)
    } catch let error as ChatDirectMessageServiceError {
      guard error.isSessionExpired else {
        throw error
      }
      let refreshedConfig = try await AppSessionRefreshService.refresh(config: activeConfig)
      return try await addOnce(chatId: chatId, memberIds: memberIds, config: refreshedConfig)
    }
  }

  private static func addOnce(
    chatId: String, memberIds: [String], config: AppSessionConfig
  ) async throws -> [GroupMemberAddResult] {
    let request = try buildRequest(chatId: chatId, memberIds: memberIds, config: config)

    switch config.transportMode {
    case .offline:
      throw ChatDirectMessageServiceError.transportUnavailable("offline")
    case .bridgeText:
      throw ChatDirectMessageServiceError.transportUnavailable("bridge_text")
    case .direct:
      return try await perform(request, session: PacketRuntime.shared.session())
    }
  }

  private static func buildRequest(
    chatId: String, memberIds: [String], config: AppSessionConfig
  ) throws -> URLRequest {
    var base = config.apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }
    let pathBase = base.lowercased().hasSuffix("/api") ? base : "\(base)/api"
    let encodedId = chatId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? chatId
    guard let url = URL(string: "\(pathBase)/group/\(encodedId)/members") else {
      throw ChatDirectMessageServiceError.invalidURL
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["memberIds": memberIds])
    return request
  }

  private static func perform(_ request: URLRequest, session: URLSession) async throws -> [GroupMemberAddResult] {
    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ChatDirectMessageServiceError.invalidResponse
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw ChatDirectMessageServiceError.http(httpResponse.statusCode, body)
    }

    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    guard let payload = object as? [String: Any], let results = payload["results"] as? [[String: Any]] else {
      throw ChatDirectMessageServiceError.invalidPayload
    }
    return results.compactMap { entry in
      guard let userId = entry["userId"] as? String else { return nil }
      let added = (entry["added"] as? Bool) ?? false
      return GroupMemberAddResult(userId: userId, added: added)
    }
  }
}

struct GroupUpdateResult {
  let chatId: String
  let name: String?
  let description: String?
  let avatarUrl: String?
}

/// Owner/admin group mutations: `PUT /group/:id` (name/description/avatar),
/// `DELETE /group/:id` (owner delete), `POST /group/:id/leave`,
/// `DELETE /group/:id/members/:user_id` (remove) and
/// `PUT /group/:id/members/:user_id/role` (promote/demote). Mirrors the
/// transport-aware handling (direct → packet-mesh fallback, session refresh on
/// expiry) used by `GroupMembersUpdateService`.
enum GroupUpdateService {
  static func update(
    chatId: String, name: String?, description: String?, avatarUrl: String?,
    config: AppSessionConfig
  ) async throws -> GroupUpdateResult {
    var body: [String: Any] = [:]
    if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
      body["name"] = name
    }
    if let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      body["description"] = description
    }
    if let avatarUrl, !avatarUrl.isEmpty {
      body["avatarUrl"] = avatarUrl
    }
    let payload = try await send(
      method: "PUT", path: "/group/\(encoded(chatId))", body: body, config: config)
    return GroupUpdateResult(
      chatId: (payload?["chatId"] as? String) ?? chatId,
      name: payload?["name"] as? String,
      description: payload?["description"] as? String,
      avatarUrl: payload?["avatarUrl"] as? String
    )
  }

  static func delete(chatId: String, config: AppSessionConfig) async throws {
    _ = try await send(
      method: "DELETE", path: "/group/\(encoded(chatId))", body: nil, config: config)
  }

  static func leave(chatId: String, config: AppSessionConfig) async throws {
    _ = try await send(
      method: "POST", path: "/group/\(encoded(chatId))/leave", body: [:], config: config)
  }

  static func removeMember(chatId: String, userId: String, config: AppSessionConfig) async throws {
    _ = try await send(
      method: "DELETE",
      path: "/group/\(encoded(chatId))/members/\(encoded(userId))", body: nil, config: config)
  }

  static func setRole(
    chatId: String, userId: String, role: String, config: AppSessionConfig
  ) async throws {
    _ = try await send(
      method: "PUT",
      path: "/group/\(encoded(chatId))/members/\(encoded(userId))/role",
      body: ["role": role], config: config)
  }

  private static func encoded(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
  }

  @discardableResult
  private static func send(
    method: String, path: String, body: [String: Any]?, config: AppSessionConfig
  ) async throws -> [String: Any]? {
    let activeConfig = AppSessionConfig.current ?? config
    do {
      return try await sendOnce(method: method, path: path, body: body, config: activeConfig)
    } catch let error as ChatDirectMessageServiceError {
      guard error.isSessionExpired else { throw error }
      let refreshed = try await AppSessionRefreshService.refresh(config: activeConfig)
      return try await sendOnce(method: method, path: path, body: body, config: refreshed)
    }
  }

  private static func sendOnce(
    method: String, path: String, body: [String: Any]?, config: AppSessionConfig
  ) async throws -> [String: Any]? {
    let request = try buildRequest(method: method, path: path, body: body, config: config)
    switch config.transportMode {
    case .offline:
      throw ChatDirectMessageServiceError.transportUnavailable("offline")
    case .bridgeText:
      throw ChatDirectMessageServiceError.transportUnavailable("bridge_text")
    case .direct:
      return try await perform(request, session: PacketRuntime.shared.session())
    }
  }

  private static func buildRequest(
    method: String, path: String, body: [String: Any]?, config: AppSessionConfig
  ) throws -> URLRequest {
    var base = config.apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    let pathBase = base.lowercased().hasSuffix("/api") ? base : "\(base)/api"
    guard let url = URL(string: "\(pathBase)\(path)") else {
      throw ChatDirectMessageServiceError.invalidURL
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    if let body {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
    }
    return request
  }

  private static func perform(
    _ request: URLRequest, session: URLSession
  ) async throws -> [String: Any]? {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw ChatDirectMessageServiceError.invalidResponse
    }
    guard (200...299).contains(http.statusCode) else {
      let bodyString = String(data: data, encoding: .utf8) ?? ""
      throw ChatDirectMessageServiceError.http(http.statusCode, bodyString)
    }
    let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    return object as? [String: Any]
  }
}

/// Routes group-profile actions (edit / leave / delete / member management)
/// emitted by `ChatProfileMainView`, shared by the standalone profile controller
/// and the in-conversation profile page. Returns true when it consumed the event.
/// `@MainActor` since every path touches UIKit / toasts; the callers are
/// `UIViewController` handlers (already main-actor isolated), so `handle` is a
/// plain synchronous call for them.
@MainActor
enum GroupProfileActionRouter {
  static func handle(
    payload: [String: Any],
    route: ChatRoute,
    presenter: UIViewController,
    onClose: (() -> Void)?,
    onEdited: ((_ name: String, _ avatarUrl: String?, _ description: String) -> Void)?
  ) -> Bool {
    let type = str(payload["type"]) ?? ""
    let chatId = str(payload["chatId"]) ?? route.chatId

    switch type {
    case "profileGroupAction":
      let isChannel = route.isChannel || bool(payload["isChannel"]) == true
        || Self.cachedIsChannel(chatId: chatId)
      let roomLabel = isChannel ? "Channel" : "Group"
      switch str(payload["action"]) ?? "" {
      case "editGroup":
        presentEditor(
          payload: payload, chatId: chatId, route: route, isChannel: isChannel,
          presenter: presenter, onEdited: onEdited)
      case "reportRoom":
        let alert = UIAlertController(
          title: "Report \(roomLabel)",
          message: "Open the chat and report a message so the review includes the exact content.",
          preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Open Chat", style: .default) { _ in
          onClose?()
        })
        presenter.present(alert, animated: true)
      case "leaveGroup":
        confirmDestructive(
          title: "Leave \(roomLabel)",
          message: "You'll stop receiving messages from \(route.title).",
          confirmTitle: "Leave \(roomLabel)",
          presenter: presenter
        ) {
          await perform(
            chatId: chatId, onClose: onClose,
            success: isChannel ? "You left the channel." : "You left the group."
          ) { config in
            try await GroupUpdateService.leave(chatId: chatId, config: config)
          }
        }
      case "deleteGroup":
        confirmDestructive(
          title: "Delete \(roomLabel)",
          message: "This deletes \(route.title) for everyone. This can't be undone.",
          confirmTitle: "Delete \(roomLabel)",
          presenter: presenter
        ) {
          await perform(
            chatId: chatId, onClose: onClose,
            success: isChannel ? "Channel deleted." : "Group deleted."
          ) { config in
            try await GroupUpdateService.delete(chatId: chatId, config: config)
          }
        }
      default:
        break
      }
      return true

    case "groupMemberTapped":
      presentMemberActions(payload: payload, chatId: chatId, presenter: presenter)
      return true

    case "channelLink":
      shareChannelLink(payload: payload, route: route, presenter: presenter)
      return true

    case "channelSetting":
      updateChannelSetting(payload: payload, chatId: chatId)
      return true

    case "channelAgents":
      presentChannelAgents(chatId: chatId, presenter: presenter)
      return true

    default:
      return false
    }
  }

  private static func presentEditor(
    payload: [String: Any], chatId: String, route: ChatRoute,
    isChannel: Bool? = nil,
    presenter: UIViewController,
    onEdited: ((String, String?, String) -> Void)?
  ) {
    guard let config = AppSessionConfig.current else {
      AppToastController.shared.show("The current session is unavailable.")
      return
    }
    let name = str(payload["name"]) ?? route.title
    let description = str(payload["description"]) ?? route.roomDescription ?? ""
    let avatarUri = str(payload["avatarUri"]) ?? route.avatarURI
    let channel =
      isChannel
      ?? (route.isChannel || bool(payload["isChannel"]) == true || cachedIsChannel(chatId: chatId))
    // Full page (not sheet) for group/channel edit — production NavigationStack page.
    let page = RoomEditPage(
      config: config,
      chatId: chatId,
      isChannel: channel,
      initialName: name,
      initialDescription: description,
      initialAvatarUri: avatarUri
    ) { newName, newDescription, newAvatarUrl in
      onEdited?(newName, newAvatarUrl, newDescription)
      AppToastController.shared.show(channel ? "Channel updated." : "Group updated.")
      if let nav = presenter.navigationController {
        nav.popViewController(animated: true)
      } else {
        presenter.dismiss(animated: true)
      }
    }
    let host = UIHostingController(rootView: page)
    host.view.backgroundColor = .systemBackground
    if let nav = presenter.navigationController {
      nav.pushViewController(host, animated: true)
    } else {
      let wrap = UINavigationController(rootViewController: host)
      wrap.modalPresentationStyle = .pageSheet
      presenter.present(wrap, animated: true)
    }
  }

  private static func presentMemberActions(
    payload: [String: Any], chatId: String, presenter: UIViewController
  ) {
    let userId = str(payload["userId"]) ?? ""
    let name = str(payload["name"]) ?? userId
    let role = (str(payload["role"]) ?? "member").lowercased()
    let canManage = (payload["canManage"] as? Bool) ?? false
    let myId = AppSessionConfig.current?.userID ?? ""
    guard !userId.isEmpty else { return }

    let isSelf = !myId.isEmpty && userId.caseInsensitiveCompare(myId) == .orderedSame
    // Direct hold-menu actions — no intermediate popup.
    let action = (str(payload["action"]) ?? "").lowercased()
    if canManage, !isSelf, role != "owner" {
      switch action {
      case "promote":
        Task {
          await setRole(
            chatId: chatId, userId: userId, role: "admin",
            success: "\(name) is now an admin.")
        }
        return
      case "demote":
        Task {
          await setRole(
            chatId: chatId, userId: userId, role: "member",
            success: "\(name) is no longer an admin.")
        }
        return
      case "remove":
        Task { await removeMember(chatId: chatId, userId: userId, success: "Removed \(name).") }
        return
      default:
        break
      }
    }

    // Manage sheet (hold → Manage). Skip empty/non-manager cases — no OK-only popup.
    guard canManage, !isSelf, role != "owner" else { return }

    let sheet = GroupMemberActionsSheet(
      name: name,
      role: role,
      onPromote: {
        Task {
          await setRole(
            chatId: chatId, userId: userId, role: "admin",
            success: "\(name) is now an admin.")
        }
      },
      onDemote: {
        Task {
          await setRole(
            chatId: chatId, userId: userId, role: "member",
            success: "\(name) is no longer an admin.")
        }
      },
      onRemove: {
        Task { await removeMember(chatId: chatId, userId: userId, success: "Removed \(name).") }
      }
    )
    let host = UIHostingController(rootView: sheet)
    host.view.backgroundColor = .clear
    host.modalPresentationStyle = .pageSheet
    if let detents = host.sheetPresentationController {
      detents.detents = [.medium()]
      detents.prefersGrabberVisible = true
      detents.preferredCornerRadius = 28
    }
    presenter.present(host, animated: true)
  }

  private static func shareChannelLink(
    payload: [String: Any], route: ChatRoute, presenter: UIViewController
  ) {
    guard let config = AppSessionConfig.current else {
      AppToastController.shared.show("The current session is unavailable.")
      return
    }
    if let known = canonicalShareURL(
      str(payload["shareLink"]) ?? route.shareLink,
      publicSlug: str(payload["publicSlug"]) ?? route.publicSlug,
      config: config
    ) {
      presentShareSheet(value: known, presenter: presenter)
      return
    }
    Task { @MainActor in
      do {
        let settings = try await ChannelProfileService.rotateInviteLink(
          chatId: route.chatId, config: config)
        guard let link = canonicalShareURL(
          settings.inviteLink,
          publicSlug: settings.publicSlug,
          config: config
        ) else {
          throw ChannelProfileServiceError.invalidPayload
        }
        presentShareSheet(value: link, presenter: presenter)
      } catch {
        AppToastController.shared.show(error.localizedDescription)
      }
    }
  }

  private static func updateChannelSetting(payload: [String: Any], chatId: String) {
    guard let config = AppSessionConfig.current,
      let setting = str(payload["setting"]),
      ["joinApprovalRequired", "restrictSavingContent"].contains(setting),
      let value = bool(payload["value"])
    else { return }
    Task { @MainActor in
      do {
        _ = try await ChannelProfileService.updatePolicy(
          chatId: chatId, values: [setting: value], config: config)
        AppToastController.shared.show("Channel setting updated.")
      } catch {
        AppToastController.shared.show(error.localizedDescription)
      }
    }
  }

  private static func presentChannelAgents(chatId: String, presenter: UIViewController) {
    let pushBuilder: () -> Void = { [weak presenter] in
      guard let presenter, let nav = presenter.navigationController else { return }
      let controller = ChatAgentConversationController(
        isDark: nav.traitCollection.userInterfaceStyle == .dark,
        onClose: { [weak nav] in nav?.popViewController(animated: true) }
      )
      nav.pushViewController(controller, animated: true)
    }
    let page = ChannelAgentManagementPage(chatId: chatId, onCreateAgent: pushBuilder)
    let host = UIHostingController(rootView: page)
    host.view.backgroundColor = .systemBackground
    if let nav = presenter.navigationController {
      nav.pushViewController(host, animated: true)
    } else {
      let wrapper = UINavigationController(rootViewController: host)
      wrapper.modalPresentationStyle = .pageSheet
      presenter.present(wrapper, animated: true)
    }
  }

  private static func canonicalShareURL(
    _ raw: String?, publicSlug: String?, config: AppSessionConfig
  ) -> String? {
    let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if value.contains("://") { return value }
    var base = config.apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    if base.lowercased().hasSuffix("/api") { base.removeLast(4) }
    if !value.isEmpty {
      return value.hasPrefix("/") ? "\(base)\(value)" : "\(base)/\(value)"
    }
    if let slug = publicSlug?.trimmingCharacters(in: .whitespacesAndNewlines), !slug.isEmpty {
      return "\(base)/r/\(slug)"
    }
    return nil
  }

  private static func presentShareSheet(value: String, presenter: UIViewController) {
    let activity = UIActivityViewController(activityItems: [value], applicationActivities: nil)
    if let popover = activity.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = CGRect(
        x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
      popover.permittedArrowDirections = []
    }
    presenter.present(activity, animated: true)
  }

  private static func confirmDestructive(
    title: String, message: String, confirmTitle: String,
    presenter: UIViewController, action: @escaping () async -> Void
  ) {
    let sheet = UIAlertController(title: title, message: message, preferredStyle: .actionSheet)
    sheet.addAction(
      UIAlertAction(title: confirmTitle, style: .destructive) { _ in
        Task { await action() }
      })
    sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    presentSheet(sheet, on: presenter)
  }

  @MainActor
  private static func perform(
    chatId: String, onClose: (() -> Void)?, success: String,
    _ call: @escaping (AppSessionConfig) async throws -> Void
  ) async {
    guard let config = AppSessionConfig.current else {
      AppToastController.shared.show("The current session is unavailable.")
      return
    }
    do {
      try await call(config)
      ChatHomeService.removeCachedChat(chatID: chatId, config: config)
      AppToastController.shared.show(success)
      onClose?()
    } catch {
      AppToastController.shared.show(error.localizedDescription)
    }
  }

  @MainActor
  private static func setRole(chatId: String, userId: String, role: String, success: String) async {
    guard let config = AppSessionConfig.current else { return }
    do {
      try await GroupUpdateService.setRole(chatId: chatId, userId: userId, role: role, config: config)
      AppToastController.shared.show(success)
    } catch {
      AppToastController.shared.show(error.localizedDescription)
    }
  }

  @MainActor
  private static func removeMember(chatId: String, userId: String, success: String) async {
    guard let config = AppSessionConfig.current else { return }
    do {
      try await GroupUpdateService.removeMember(chatId: chatId, userId: userId, config: config)
      AppToastController.shared.show(success)
    } catch {
      AppToastController.shared.show(error.localizedDescription)
    }
  }

  private static func presentSheet(_ sheet: UIAlertController, on presenter: UIViewController) {
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = presenter.view
      popover.sourceRect = CGRect(
        x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
      popover.permittedArrowDirections = []
    }
    presenter.present(sheet, animated: true)
  }

  private static func str(_ value: Any?) -> String? {
    if let s = value as? String {
      let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
      return t.isEmpty ? nil : t
    }
    if let n = value as? NSNumber { return n.stringValue }
    return nil
  }

  private static func bool(_ value: Any?) -> Bool? {
    if let b = value as? Bool { return b }
    if let n = value as? NSNumber { return n.boolValue }
    if let s = value as? String {
      switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "1", "true", "yes", "on": return true
      case "0", "false", "no", "off": return false
      default: return nil
      }
    }
    return nil
  }

  /// Home-list cache is the source of truth for room type when ChatRoute was
  /// built without `type`/`isChannel` (stale create path or old disk cache).
  private static func cachedIsChannel(chatId: String) -> Bool {
    resolvedIsChannel(chatId: chatId)
  }

  /// Public so profile configure paths can stamp channel chrome without
  /// depending only on ChatRoute.isChannel.
  static func resolvedIsChannel(chatId: String) -> Bool {
    guard let config = AppSessionConfig.current else { return false }
    return ChatHomeService.cachedRows(config: config)
      .first(where: { $0.chatId == chatId })?
      .isChannel == true
  }
}

private enum ChatDirectMessageService {
  static func startChat(
    config: AppSessionConfig,
    friendID: String,
  ) async throws -> ChatCreateResult {
    let activeConfig = AppSessionConfig.current ?? config
    do {
      return try await startChatOnce(
        config: activeConfig, friendID: friendID)
    } catch let error as ChatDirectMessageServiceError {
      guard error.isSessionExpired else {
        throw error
      }
      let refreshedConfig = try await AppSessionRefreshService.refresh(config: activeConfig)
      return try await startChatOnce(
        config: refreshedConfig, friendID: friendID)
    }
  }

  private static func startChatOnce(
    config: AppSessionConfig,
    friendID: String,
  ) async throws -> ChatCreateResult {
    let request = try buildRequest(config: config, friendID: friendID)

    switch config.transportMode {
    case .offline:
      throw ChatDirectMessageServiceError.transportUnavailable("offline")
    case .bridgeText:
      throw ChatDirectMessageServiceError.transportUnavailable("bridge_text")
    case .direct:
      let result = try await perform(request, session: PacketRuntime.shared.session())
      Task.detached {
        await PacketBootstrapService.prefetchIfNeeded(config: config)
      }
      return result
    }
  }

  private static func buildRequest(config: AppSessionConfig, friendID: String) throws -> URLRequest {
    var base = config.apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }

    let pathBase = base.lowercased().hasSuffix("/api") ? base : "\(base)/api"
    guard let url = URL(string: "\(pathBase)/chat") else {
      throw ChatDirectMessageServiceError.invalidURL
    }

    let body: [String: Any] = [
      "myId": config.userID,
      "friendId": friendID,
    ]

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    // Agent open-chat should fail fast — 20s + packet mesh was feeling like ~30s.
    request.timeoutInterval = 12
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }

  private static func perform(_ request: URLRequest, session: URLSession) async throws -> ChatCreateResult {
    let (data, response) = try await session.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse else {
      throw ChatDirectMessageServiceError.invalidResponse
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      let body = String(data: data, encoding: .utf8) ?? ""
      throw ChatDirectMessageServiceError.http(httpResponse.statusCode, body)
    }

    let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    guard let payload = object as? [String: Any] else {
      throw ChatDirectMessageServiceError.invalidPayload
    }
    guard let chatID = normalizedString(payload["chatId"] ?? payload["chat_id"]) else {
      throw ChatDirectMessageServiceError.invalidPayload
    }

    let messages = (payload["messages"] as? [[String: Any]]) ?? []
    return ChatCreateResult(chatID: chatID, messages: messages)
  }

  fileprivate static func normalizedString(_ value: Any?) -> String? {
    if let value = value as? String {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let value = value as? NSNumber {
      return value.stringValue
    }
    return nil
  }
}

@MainActor
private func openAgentDirectChat(
  from presenter: UIViewController,
  agentUserId: String,
  agentName: String,
  agentUsername: String?,
  agentId: String? = nil,
  bridgeProvider: String? = nil
) async {
  guard let config = AppSessionConfig.current else {
    AppToastController.shared.show("The current session is unavailable.")
    return
  }

  do {
    let result = try await ChatDirectMessageService.startChat(
      config: config,
      friendID: agentUserId
    )
    let normalizedUsername =
      agentUsername?
      .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let title =
      normalizedUsername.flatMap { $0.isEmpty ? nil : $0 }
      ?? agentName
    let normalizedAgentId = ChatDirectMessageService.normalizedString(agentId)
    let resolvedBridgeProvider =
      ChatDirectMessageService.normalizedString(bridgeProvider)?.lowercased()
      ?? ChatRoute.resolveBridgeProvider(
        peerUserId: agentUserId,
        name: title,
        isAgent: true,
        agentId: normalizedAgentId
      )
    let routeAgentId = resolvedBridgeProvider != nil
      ? (normalizedAgentId ?? agentUserId)
      : normalizedAgentId
    let route = ChatRoute(
      chatId: result.chatID,
      title: title,
      peerUserId: agentUserId,
      peerAgentId: routeAgentId,
      isAgent: routeAgentId != nil || resolvedBridgeProvider != nil,
      avatarURI: ChatAvatarURLResolver.resolve(
        rawAvatar: nil,
        peerUserId: agentUserId,
        chatId: result.chatID,
        preferPushAvatar: false,
        isAgent: true,
        agentId: routeAgentId,
        displayName: title
      ),
      isGroup: false,
      initialRows: result.messages,
      bridgeProvider: resolvedBridgeProvider
    )
    guard let navigation = presenter.navigationController else { return }
    let controller = ChatConversationController(
      route: route,
      isDark: navigation.traitCollection.userInterfaceStyle == .dark,
      onClose: { [weak navigation] in
        navigation?.popViewController(animated: true)
      }
    )
    navigation.pushViewController(controller, animated: true)
  } catch {
    AppToastController.shared.show(error.localizedDescription)
  }
}

private enum ChatDirectMessageServiceError: LocalizedError {
  case invalidURL
  case invalidResponse
  case invalidPayload
  case http(Int, String)
  case transportUnavailable(String)

  var isSessionExpired: Bool {
    switch self {
    case let .http(statusCode, _):
      return statusCode == 401
    default:
      return false
    }
  }

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "The stored API configuration is invalid."
    case .invalidResponse:
      return "The server did not return a valid response."
    case .invalidPayload:
      return "The chat response could not be parsed."
    case let .http(statusCode, body):
      return appShellServerErrorMessage(statusCode: statusCode, body: body, fallback: "Chat request failed")
    case let .transportUnavailable(mode):
      return "Transport mode \(mode) is not available in the standalone native app."
    }
  }
}

private struct AppAnimatedSVGView: UIViewRepresentable {
  let svgString: String

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.allowsInlineMediaPlayback = true
    configuration.mediaTypesRequiringUserActionForPlayback = []

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.scrollView.isScrollEnabled = false
    webView.scrollView.bounces = false
    webView.isUserInteractionEnabled = false
    return webView
  }

  func updateUIView(_ uiView: WKWebView, context: Context) {
    let html = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no" />
    <style>
      body, html { margin: 0; padding: 0; width: 100%; height: 100%; background-color: transparent; display: flex; justify-content: center; align-items: center; }
      svg { width: 100%; height: 100%; object-fit: contain; }
    </style>
    </head>
    <body>
    \(svgString)
    </body>
    </html>
    """
    uiView.loadHTMLString(html, baseURL: nil)
  }
}

// MARK: - Native UIKit shell

/// Scene-level, non-key overlay used only for transient global toasts.
/// Returning nil keeps every touch routed to the real application window.
private final class AppToastOverlayWindow: UIWindow {
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    nil
  }
}

/// Root view of a pushed chat, which reports when UIKit re-parents it.
///
/// `ChatConversationController.prepareForNavigationPush` parks this view inside the
/// navigation container — hidden — so the transcript can lay out at the destination's
/// real width before the push starts. The parking is the whole reason the seed measures
/// against cached heights instead of estimating, and it must stay invisible: a full-screen
/// chat parked in the container is a full-screen chat on top of the page the user is still
/// looking at.
///
/// Unhiding cannot be done by code position. Core Animation commits state at the end of a
/// run-loop turn, so "unhide before `pushViewController`" and "unhide after it returns"
/// commit the identical frame; the only thing that separates parked from pushed is the
/// re-parent itself. `didMoveToSuperview` fires inside that same commit, which is what
/// makes the reveal frame-exact — no parked frame, and no blank first frame of the slide.
final class ChatPrestageRootView: UIView {
  /// Called on every superview change while a push reveal is armed.
  var onSuperviewChanged: ((UIView?) -> Void)?

  /// Names the parked view in a probe line. Set by whoever parks it.
  var prestageProbeLabel: String = "?"

  override func didMoveToSuperview() {
    super.didMoveToSuperview()
    // Unconditional: the flash is a frame the reveal path does not know it produced,
    // so every parent change is recorded whether or not a reveal is armed.
    flashProbeLog(
      "prestage-root superview chat=\(prestageProbeLabel) "
        + "super=\(superview.map { String(describing: type(of: $0)) } ?? "nil") "
        + "hidden=\(isHidden ? "Y" : "N") alpha=\(String(format: "%.2f", alpha)) "
        + "frame=\(NSCoder.string(for: frame))")
    onSuperviewChanged?(superview)
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    flashProbeLog(
      "prestage-root window chat=\(prestageProbeLabel) window=\(window == nil ? "N" : "Y") "
        + "hidden=\(isHidden ? "Y" : "N") alpha=\(String(format: "%.2f", alpha)) "
        + "frame=\(NSCoder.string(for: frame))")
  }
}

/// Flash probes ride the diagnostics ring, not NSLog — an export is the only way these
/// ever reach us, and NSLog never reaches an export.
func flashProbeLog(_ message: @autoclosure () -> String) {
  VibeLog.info("[FlashProbe] \(message())", category: "chatopen")
}

/// One-line z-order dump of a container, for the flash probes. Index 0 is the back.
func flashProbeSubviewDump(_ container: UIView) -> String {
  container.subviews.enumerated()
    .map { index, view in
      "\(index):\(type(of: view))\(view.isHidden ? "/hidden" : "")"
        + (view.alpha < 0.999 ? String(format: "/a%.2f", view.alpha) : "")
    }
    .joined(separator: " ")
}

/// Root navigation controller that wraps the whole `AppRootTabBarController`.
/// Pushing a `ChatConversationController` here slides it in z-above all four
/// tabs (Calls / Contacts / Home / Settings) — a chat can be opened from any
/// tab and is never nested inside the Chats tab. Its own nav bar stays hidden;
/// each pushed surface draws its own header.
final class AppRootNavigationController: UINavigationController, UIGestureRecognizerDelegate {
  private var toastOverlayWindow: AppToastOverlayWindow?

  override func viewDidLoad() {
    super.viewDidLoad()
    setNavigationBarHidden(true, animated: false)
    interactivePopGestureRecognizer?.delegate = self
    NativeMusicPlayerRootOverlay.shared.install(on: view)
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    installToastOverlayWindowIfNeeded()
  }

  /// The flash is reported as a full-screen frame BEFORE the transition. These dump the
  /// container's z-order at the transition boundary and again one turn later.
  private func logFlashProbeStack(_ phase: String) {
    flashProbeLog(
      "nav \(phase) stack=\(viewControllers.count) subviews=[\(flashProbeSubviewDump(view))]")
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      flashProbeLog("nav \(phase)+1turn subviews=[\(flashProbeSubviewDump(self.view))]")
    }
  }

  override func pushViewController(_ viewController: UIViewController, animated: Bool) {
    logFlashProbeStack("push-enter")
    super.pushViewController(viewController, animated: animated)
  }

  override func popViewController(animated: Bool) -> UIViewController? {
    logFlashProbeStack("pop-enter")
    return super.popViewController(animated: animated)
  }

  override func popToRootViewController(animated: Bool) -> [UIViewController]? {
    logFlashProbeStack("pop-to-root-enter")
    return super.popToRootViewController(animated: animated)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    NativeMusicPlayerRootOverlay.shared.updateLayout()
    NativeMusicPlayerRootOverlay.shared.bringToFront()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    NativeMusicPlayerRootOverlay.shared.updateLayout()
    toastOverlayWindow?.overrideUserInterfaceStyle =
      view.window?.overrideUserInterfaceStyle ?? traitCollection.userInterfaceStyle
  }

  // Keep edge-swipe-back working while the system nav bar is hidden, but only
  // when there is something pushed above the tab shell.
  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    viewControllers.count > 1
  }

  override var childForStatusBarStyle: UIViewController? {
    return topViewController
  }

  deinit {
    toastOverlayWindow?.isHidden = true
    toastOverlayWindow?.rootViewController = nil
  }

  // A UINavigationController is a closed container: adding an unrelated
  // UIHostingController via addChild corrupts its child/appearance bookkeeping,
  // especially when Agent Settings toggles the system navigation bar. Put the
  // non-interactive global toast in its own scene-bound overlay window instead.
  private func installToastOverlayWindowIfNeeded() {
    guard toastOverlayWindow == nil, let windowScene = view.window?.windowScene else {
      return
    }
    let host = UIHostingController(rootView: AppToastHostView())
    host.view.backgroundColor = .clear
    host.view.isUserInteractionEnabled = false

    let overlayWindow = AppToastOverlayWindow(windowScene: windowScene)
    overlayWindow.frame = windowScene.coordinateSpace.bounds
    overlayWindow.backgroundColor = .clear
    overlayWindow.windowLevel = UIWindow.Level(
      rawValue: UIWindow.Level.alert.rawValue - 1.0)
    overlayWindow.overrideUserInterfaceStyle =
      view.window?.overrideUserInterfaceStyle ?? traitCollection.userInterfaceStyle
    overlayWindow.rootViewController = host
    overlayWindow.isHidden = false
    toastOverlayWindow = overlayWindow
  }
}

/// The four-tab shell (Calls / Contacts / Home / Settings). It is itself the
/// root of `AppRootNavigationController`, which is what actually pushes a chat
/// conversation — z-above this whole tab bar — so a chat opens from any tab
/// without nesting. Each tab hosts its SwiftUI page in a `UIHostingController`.
final class AppRootTabBarController: UITabBarController, UITabBarControllerDelegate {
  let coordinator = AppShellCoordinator()

  override var childForStatusBarStyle: UIViewController? {
    return selectedViewController
  }

  /// Tab order; the index maps 1:1 to `AppShellTab`.
  static let orderedTabs: [AppShellTab] = [.calls, .contacts, .chats, .agents, .settings]
  static func tabIndex(for tab: AppShellTab) -> Int? { orderedTabs.firstIndex(of: tab) }

  private var settingsAvatarTask: Task<Void, Never>?
  private var profileCancellable: AnyCancellable?

  override func viewDidLoad() {
    super.viewDidLoad()
    delegate = self
    AppUIStallWatchdog.shared.start(context: "tabshell viewDidLoad")

    // --- Tabs (order: Calls · Contacts · Home · Settings) ----------------
    let callsVC = makeHosted(CallsRootView())
    callsVC.tabBarItem = UITabBarItem(
      title: "Calls", image: UIImage(systemName: "phone"), selectedImage: nil)

    let contactsVC = makeHosted(ContactsRootView())
    contactsVC.tabBarItem = UITabBarItem(
      title: "Contacts", image: UIImage(systemName: "person.circle"), selectedImage: nil)

    let chatHomeVC = UIHostingController(rootView: ChatHomeScreen().environmentObject(coordinator))
    chatHomeVC.tabBarItem = UITabBarItem(
      title: "Chats",
      image: Self.roundedRectTabIcon(systemName: "bubble.left.and.bubble.right.fill", cornerRadius: 6),
      selectedImage: nil)

    let agentsVC = makeAgentsTabRoot()
    agentsVC.tabBarItem = UITabBarItem(
      title: "AI", image: Self.aiTextTabIcon(), selectedImage: nil)

    let settingsVC = makeHosted(SettingsRootView())
    settingsVC.tabBarItem = UITabBarItem(
      title: "Settings", image: UIImage(systemName: "gearshape"), selectedImage: nil)

    viewControllers = [callsVC, contactsVC, chatHomeVC, agentsVC, settingsVC]
    selectedIndex = Self.tabIndex(for: .chats) ?? 2

    // --- Coordinator wiring ----------------------------------------------
    coordinator.tabBarController = self
    coordinator.selectedTab = .chats
    VibeRoomLinkRouter.shared.register(coordinator: coordinator)

    // --- Appearance & lifecycle ------------------------------------------
    configureGlobalNavigationBarAppearance()
    configureGlobalSearchBarAppearance()
    applyTabBarAppearance()
    AppAppearanceController.applyStoredPreference()

    // Force layout so tab bar item labels are fully sized on first paint
    // (avoids text clipping until a tab switch triggers relayout).
    tabBar.setNeedsLayout()
    tabBar.layoutIfNeeded()

    VibeNativeCallOverlayPresenter.shared.startObserving()
    VibeNativeCallOverlayPresenter.shared.refreshFromEngine()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )

    refreshSettingsTabAvatar()

    Task { [weak self] in
      await AppProfileController.shared.loadIfNeeded()
      await MainActor.run { self?.refreshSettingsTabAvatar() }
    }
    profileCancellable = AppProfileController.shared.$profile
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        self?.refreshSettingsTabAvatar()
      }
  }

  deinit {
    settingsAvatarTask?.cancel()
    NotificationCenter.default.removeObserver(self)
  }

  private func makeHosted<Content: View>(_ view: Content) -> UIViewController {
    UIHostingController(rootView: view.environmentObject(coordinator))
  }

  // MARK: Agents tab

  /// The Agents tab root: `ChatAgentsMainViewController`, a real list PAGE (Home-style
  /// pinned search + filters, cached instant render, Home's own row/swipe/hold-preview
  /// engine). It replaced a controller originally written as a presented sheet — the
  /// sheet-as-page mismatch was the source of the broken layout and empty list. Agent
  /// configuration now lives only behind it, in `ChatNativeAgentConfigPanelController`.
  /// No session yet (should not happen — this controller is only ever constructed
  /// post-auth) falls back to an empty placeholder rather than crashing.
  private func makeAgentsTabRoot() -> UIViewController {
    guard let config = AppSessionConfig.current else {
      return UINavigationController(rootViewController: UIViewController())
    }
    let apiContext = ChatNativeAgentConfigAPIContext(
      apiBaseURL: config.apiBaseURL,
      token: config.authToken
    )
    let controller = ChatAgentsMainViewController(
      apiContext: apiContext,
      appearance: .current,
      showsCloseButton: false
    )
    controller.onToast = { message in
      AppToastController.shared.show(message)
    }
    controller.onCreateAgent = { [weak self] in
      // No standalone "create agent" screen exists natively yet — agent creation is a
      // conversational flow the built-in Vibe AI assistant already drives. Judgment call:
      // hand off to that chat rather than build a second creation UI here.
      self?.coordinator.openAgentConversation()
    }
    controller.onOpenAgentChat = { [weak self] card in
      self?.openAgentChatFromAgentsTab(card)
    }
    controller.onDeleteAgent = { [weak self] card, completion in
      self?.deleteAgentFromAgentsTab(card, completion: completion)
    }
    return UINavigationController(rootViewController: controller)
  }

  /// Opens (creating if needed) the DM with a real agent's shadow user — built directly
  /// from the `AgentCard` fields we already have, rather than the generic share-link
  /// pipeline (resolve-by-id via contact search, THEN start chat). That extra search-by-id
  /// round trip was an unnecessary dependency for a chat we can already fully describe,
  /// and is the prime suspect for the reported "tapping a row does nothing" routing bug.
  private func openAgentChatFromAgentsTab(_ card: ChatListRow.AgentCard) {
    guard let agentUserId = card.agentUserId, !agentUserId.isEmpty else {
      AppToastController.shared.show("Agent chat is not available yet")
      return
    }

    // If the owner already has the 1:1 DM with this agent, its chatId is already
    // in `attachedChats` — push instantly, exactly like tapping a Home row, instead
    // of always waiting on a `startChat` round trip first. That network call is
    // now only a first-ever-open fallback, which is what was making every tap on
    // an already-existing agent chat feel delayed.
    if let knownChatId = card.attachedChats.first(where: { ($0.type ?? "dm").lowercased() == "dm" })?.chatId {
      coordinator.openChat(
        ChatRoute(
          chatId: knownChatId,
          title: card.displayName,
          peerUserId: agentUserId,
          peerAgentId: card.agentId,
          isAgent: true,
          avatarURI: ChatAvatarURLResolver.resolve(
            rawAvatar: card.avatarUrl,
            peerUserId: agentUserId,
            chatId: knownChatId,
            preferPushAvatar: false
          ),
          isGroup: false,
          initialRows: []
        )
      )
      return
    }

    guard let config = AppSessionConfig.current else {
      AppToastController.shared.show("The current session is unavailable.")
      return
    }
    Task { @MainActor [weak self] in
      do {
        let result = try await ChatDirectMessageService.startChat(
          config: config, friendID: agentUserId
        )
        self?.coordinator.openChat(
          ChatRoute(
            chatId: result.chatID,
            title: card.displayName,
            peerUserId: agentUserId,
            peerAgentId: card.agentId,
            isAgent: true,
            avatarURI: ChatAvatarURLResolver.resolve(
              rawAvatar: card.avatarUrl,
              peerUserId: agentUserId,
              chatId: result.chatID,
              preferPushAvatar: false
            ),
            isGroup: false,
            initialRows: result.messages
          )
        )
      } catch {
        AppToastController.shared.show("Could not open chat: \(error.localizedDescription)")
      }
    }
  }

  private func deleteAgentFromAgentsTab(
    _ card: ChatListRow.AgentCard, completion: @escaping () -> Void
  ) {
    guard let config = AppSessionConfig.current else {
      AppToastController.shared.show("Missing API session")
      return
    }
    let trimmedId = card.agentId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedId.isEmpty, let url = Self.agentDeleteURL(apiBaseURL: config.apiBaseURL, agentId: trimmedId)
    else { return }

    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let cardTitle = card.displayName
    VibeHTTP.shared.dataTask(with: request) { data, response, error in
      DispatchQueue.main.async {
        if let error {
          NSLog("[AgentsTab] delete agent failed %@", error.localizedDescription)
          AppToastController.shared.show("Could not delete agent")
          return
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode) else {
          AppToastController.shared.show("Delete failed")
          return
        }
        completion()
        AppToastController.shared.show("Deleted \(cardTitle)")
      }
    }.resume()
  }

  /// Mirrors `ChatAgentsMainViewController.agentsURL()`'s base-URL normalization
  /// (the configured API base may or may not already end in `/api`) so this hits the
  /// same `DELETE /api/agents/:id` route the list screen's own GET uses.
  private static func agentDeleteURL(apiBaseURL: URL, agentId: String) -> URL? {
    var base = apiBaseURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") { base.removeLast() }
    let suffix = base.lowercased().hasSuffix("/api") ? "/agents" : "/api/agents"
    let encodedId = agentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? agentId
    return URL(string: "\(base)\(suffix)/\(encodedId)")
  }

  // MARK: Tab selection sync

  /// Re-entrancy guard/counter purely for freeze diagnosis: if a tab change
  /// ping-pongs (selectedIndex ↔ selectedTab) this climbs and the breadcrumbs
  /// show it before the watchdog reports the stall.
  private var didSelectDepth = 0

  func tabBarController(
    _ tabBarController: UITabBarController, shouldSelect viewController: UIViewController
  ) -> Bool {
    // Every tab (including Agents, the former dummy Search slot) now selects normally.
    // Chat search is reachable from a toolbar button on the Chats tab itself instead
    // (see ChatHomeScreen's topBarTrailing item), so nothing needs to intercept here.
    return true
  }

  func tabBarController(
    _ tabBarController: UITabBarController, didSelect viewController: UIViewController
  ) {
    tabBarController.view.endEditing(true)
    let index = tabBarController.selectedIndex
    guard index < Self.orderedTabs.count else { return }
    let tab = Self.orderedTabs[index]
    didSelectDepth += 1
    appShellRouteLog("tab didSelect begin depth=\(didSelectDepth) index=\(index) tab=\(tab)")
    if coordinator.selectedTab != tab {
      coordinator.selectedTab = tab
    }
    appShellRouteLog("tab didSelect end depth=\(didSelectDepth) tab=\(tab)")
    didSelectDepth -= 1
  }

  // MARK: Appearance



  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
      applyTabBarAppearance()
      configureGlobalNavigationBarAppearance()
      configureGlobalSearchBarAppearance()
    }
  }

  private var paletteForCurrentStyle: AppThemePalette {
    AppThemePalette.resolve(for: traitCollection.userInterfaceStyle == .dark ? .dark : .light)
  }

  private func applyTabBarAppearance() {
    let palette = paletteForCurrentStyle
    let appearance = UITabBarAppearance()
    appearance.configureWithTransparentBackground()
    appearance.backgroundColor = .clear
    appearance.shadowColor = .clear

    for itemAppearance in [
      appearance.stackedLayoutAppearance,
      appearance.inlineLayoutAppearance,
      appearance.compactInlineLayoutAppearance,
    ] {
      // Use standard neutral text colors for selected state to match the system behavior without forcing a vibrant accent
      itemAppearance.selected.iconColor = palette.textUIColor
      itemAppearance.selected.titleTextAttributes = [.foregroundColor: palette.textUIColor]
      itemAppearance.normal.iconColor = palette.secondaryTextUIColor
      itemAppearance.normal.titleTextAttributes = [.foregroundColor: palette.secondaryTextUIColor]
    }

    tabBar.standardAppearance = appearance
    tabBar.scrollEdgeAppearance = appearance
    tabBar.tintColor = palette.textUIColor
    tabBar.unselectedItemTintColor = palette.secondaryTextUIColor
  }

  private func configureGlobalNavigationBarAppearance() {
    let appearance = UINavigationBarAppearance()
    appearance.configureWithTransparentBackground()
    appearance.shadowColor = .clear
    appearance.backgroundEffect = nil
    appearance.backgroundColor = .clear
    UINavigationBar.appearance().standardAppearance = appearance
    UINavigationBar.appearance().scrollEdgeAppearance = appearance
    UINavigationBar.appearance().compactAppearance = appearance
  }

  // The transparent navigation bar above leaves .searchable()'s text field with no
  // background of its own, so it reads as a faint, undefined-looking strip. Give it an
  // explicit, theme-aware fill via the appearance proxy since SwiftUI's .searchable()
  // exposes no direct styling hook for the field it creates.
  private func configureGlobalSearchBarAppearance() {
    let palette = paletteForCurrentStyle
    let textFieldAppearance = UITextField.appearance(whenContainedInInstancesOf: [UISearchBar.self])
    textFieldAppearance.backgroundColor = palette.inputUIColor
    textFieldAppearance.textColor = palette.textUIColor
    UISearchBar.appearance().tintColor = palette.textUIColor
  }

  // MARK: Settings tab avatar

  @objc private func handleDidBecomeActive() {
    VibeNativeCallOverlayPresenter.shared.refreshFromEngine()
    refreshSettingsTabAvatar()
    // Keep the direct Mac LAN link warm whenever the app is foregrounded so
    // agent progress can ride Wi‑Fi instead of the flaky cloud relay.
    if AgentRuntimeCrypto.hasKey {
      let cfg = ChatEngineStore.shared.getConfig()
      let userId =
        (cfg["userId"] as? String) ?? (cfg["myUserId"] as? String)
      LanBridgeService.shared.start(userId: userId)
    }
  }

  private func refreshSettingsTabAvatar() {
    settingsAvatarTask?.cancel()
    let profile = AppProfileController.shared.profile
    guard let uri = profile?.profileImage, !uri.isEmpty else {
      applySettingsTabFallback(profile: profile)
      return
    }
    // Immediate paint from memory/disk cache (seeded on photo upload).
    if let cached = ChatAvatarImageStore.cached(for: uri) {
      applySettingsTabImage(cached, cacheKey: uri)
      return
    }
    settingsAvatarTask = Task { [weak self] in
      let image = await ChatAvatarImageStore.load(from: uri)
      if Task.isCancelled { return }
      await MainActor.run {
        if let img = image {
          self?.applySettingsTabImage(img, cacheKey: uri)
        } else {
          self?.applySettingsTabFallback(profile: profile)
        }
      }
    }
  }

  /// Circular tab icons by avatar URI. Rendering one decodes the full-size photo into a
  /// 26pt circle; on the launch path that was measured blocking main for 0.40s.
  private static let settingsTabImageCache = NSCache<NSString, UIImage>()

  private func applySettingsTabFallback(profile: AppUserProfile?) {
    let name = profile?.name ?? profile?.username ?? "U"
    let letters = String(name.prefix(2)).uppercased()
    let colors = ChatProfileAppearanceStore.avatarColors(
      title: profile?.displayName ?? name,
      peerUserId: profile?.userID,
      chatId: profile?.username
    )

    let size: CGFloat = 26
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
    let image = renderer.image { ctx in
      let rect = CGRect(x: 0, y: 0, width: size, height: size)
      UIBezierPath(ovalIn: rect).addClip()
      let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [colors.0.cgColor, colors.1.cgColor] as CFArray,
        locations: [0.0, 1.0]
      )
      if let gradient {
        ctx.cgContext.drawLinearGradient(
          gradient,
          start: CGPoint(x: 0.0, y: 0.0),
          end: CGPoint(x: size, y: size),
          options: []
        )
      } else {
        colors.0.setFill()
        ctx.cgContext.fill(rect)
      }

      let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: size * 0.45, weight: .semibold),
        .foregroundColor: UIColor.white
      ]
      let textSize = letters.size(withAttributes: attributes)
      let textRect = CGRect(
        x: (size - textSize.width) / 2,
        y: (size - textSize.height) / 2,
        width: textSize.width,
        height: textSize.height
      )
      letters.draw(in: textRect, withAttributes: attributes)
    }
    applySettingsTabImage(image, cacheKey: "fallback:\(letters):\(profile?.userID ?? "-")")
  }

  private func applySettingsTabImage(_ image: UIImage?, cacheKey: String?) {
    guard let image else {
      setSettingsTabImage(nil)
      return
    }
    let key = cacheKey.map { $0 as NSString }
    if let key, let cached = Self.settingsTabImageCache.object(forKey: key) {
      setSettingsTabImage(cached)
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let circular = Self.circularTabImage(from: image, size: 26)
      DispatchQueue.main.async { [weak self] in
        if let key, let circular { Self.settingsTabImageCache.setObject(circular, forKey: key) }
        self?.setSettingsTabImage(circular)
      }
    }
  }

  private func setSettingsTabImage(_ circular: UIImage?) {
    guard let settingsIndex = Self.tabIndex(for: .settings),
      let controllers = viewControllers, settingsIndex < controllers.count
    else { return }
    let item = controllers[settingsIndex].tabBarItem
    let resolved = circular ?? UIImage(systemName: "gearshape")
    item?.image = resolved
    item?.selectedImage = resolved
  }

  private static func circularTabImage(from source: UIImage, size: CGFloat) -> UIImage? {
    // Device-scale renderer so @3x tab icons stay sharp (not soft/pressed).
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = UIScreen.main.scale
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
    let image = renderer.image { ctx in
      let rect = CGRect(x: 0, y: 0, width: size, height: size)
      UIBezierPath(ovalIn: rect).addClip()

      // Aspect-fill center-crop — square `draw(in:)` squashes non-square photos.
      let srcW = max(1, source.size.width)
      let srcH = max(1, source.size.height)
      let scale = max(size / srcW, size / srcH)
      let drawW = srcW * scale
      let drawH = srcH * scale
      let drawRect = CGRect(
        x: (size - drawW) * 0.5,
        y: (size - drawH) * 0.5,
        width: drawW,
        height: drawH
      )
      source.draw(in: drawRect)

      ctx.cgContext.resetClip()
      let badgeSize: CGFloat = 8
      let badgeRect = CGRect(x: size - badgeSize, y: size - badgeSize, width: badgeSize, height: badgeSize)
      let badgePath = UIBezierPath(ovalIn: badgeRect)
      UIColor.systemGreen.setFill()
      badgePath.fill()
      UIColor.black.setStroke()
      badgePath.lineWidth = 1.5
      badgePath.stroke()
    }
    return image.withRenderingMode(.alwaysOriginal)
  }

  // MARK: - Custom tab bar icons

  /// Renders an SF Symbol inside a rounded-rect container so the chat icon
  /// gets more pronounced corner radius rather than the default sharp edges.
  private static func roundedRectTabIcon(systemName: String, cornerRadius: CGFloat) -> UIImage? {
    let size: CGFloat = 28
    let config = UIImage.SymbolConfiguration(pointSize: 16, weight: .medium)
    guard let symbol = UIImage(systemName: systemName, withConfiguration: config) else { return nil }
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = UIScreen.main.scale
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format)
    let image = renderer.image { ctx in
      let rect = CGRect(x: 0, y: 0, width: size, height: size)
      UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius).addClip()
      let symbolSize = symbol.size
      let drawRect = CGRect(
        x: (size - symbolSize.width) / 2,
        y: (size - symbolSize.height) / 2,
        width: symbolSize.width,
        height: symbolSize.height
      )
      symbol.draw(in: drawRect)
    }
    return image.withRenderingMode(.alwaysTemplate)
  }

  /// Renders "AI" as a tab bar icon image using a bold rounded system font.
  /// This replaces the generic cpu SF Symbol with clear branding text.
  private static func aiTextTabIcon() -> UIImage? {
    let text = "AI"
    let fontSize: CGFloat = 18
    let font: UIFont
    if let rounded = UIFont(name: "SFProRounded-Bold", size: fontSize) {
      font = rounded
    } else if let descriptor = UIFont.systemFont(ofSize: fontSize, weight: .bold)
      .fontDescriptor.withDesign(.rounded) {
      font = UIFont(descriptor: descriptor, size: fontSize)
    } else {
      font = UIFont.systemFont(ofSize: fontSize, weight: .bold)
    }
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: UIColor.label
    ]
    let textSize = text.size(withAttributes: attributes)
    let padding: CGFloat = 2
    let canvasSize = CGSize(
      width: ceil(textSize.width) + padding * 2,
      height: ceil(textSize.height) + padding
    )
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = UIScreen.main.scale
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
    let image = renderer.image { _ in
      let drawRect = CGRect(
        x: (canvasSize.width - textSize.width) / 2,
        y: (canvasSize.height - textSize.height) / 2,
        width: textSize.width,
        height: textSize.height
      )
      text.draw(in: drawRect, withAttributes: attributes)
    }
    return image.withRenderingMode(.alwaysTemplate)
  }
}

/// Floating toast overlay hosted on `AppRootNavigationController` — one level above
/// the tab shell — so it stays visible above ANY pushed screen (a chat, an agent's
/// settings, ...), not just while the tab bar itself is on screen. A push replaces
/// the tab bar controller's whole view, which used to hide a toast hosted there.
private struct AppToastHostView: View {
  @ObservedObject private var toast = AppToastController.shared
  @Environment(\.colorScheme) private var colorScheme

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }

  var body: some View {
    VStack {
      Spacer()
      if let presentation = toast.presentation {
        AppToastBanner(presentation: presentation, palette: palette)
          .id(presentation.id)
          .padding(.horizontal, 16)
          .padding(.bottom, 18)
          .transition(
            .asymmetric(
              insertion: .scale(scale: 0.82, anchor: .bottom).combined(with: .opacity),
              removal: .scale(scale: 0.94, anchor: .bottom).combined(with: .opacity)
            )
          )
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(.spring(response: 0.32, dampingFraction: 0.76), value: toast.presentation?.id)
    .allowsHitTesting(false)
  }
}

// MARK: - Agent conversation (real chat UI + headless agent transport)

/// The "talk to the agent" surface. Renders with the real chat stack
/// (`ChatMainView` → `ChatListView`: same wallpaper / theme / bubbles / streaming
/// cell / `ChatInputBar`) while a hidden `ChatNativeAgentView` runs headless as
/// the transport + row source — it owns the proven `agent:<userId>` socket,
/// streaming, and persistence, and emits rows in the same `kind`/`message`
/// envelope the chat list consumes. The transcript keeps normal one-to-one chat
/// chronology and bottom anchoring; only the composer's send button becomes a stop
/// button while the agent is streaming.
final class ChatAgentConversationController: UIViewController {
  private let mainView = ChatMainView()
  // Transport-only from birth: this instance is hidden and never renders its own
  // transcript, so it must not build one during init (see `ChatNativeAgentView`).
  private let agentView = ChatNativeAgentView(frame: .zero, transportOnly: true)
  private let isDark: Bool
  private var onClose: (() -> Void)?
  private var didStageInitialRows = false
  /// Anchors the `[AgentOpen]` stage timings — both stored properties above are
  /// constructed before this runs, so `viewDidLoad`'s `sinceInitMs` is the push cost.
  private let createdAt = ProcessInfo.processInfo.systemUptime

  init(isDark: Bool, onClose: (() -> Void)?) {
    self.isDark = isDark
    self.onClose = onClose
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var preferredStatusBarStyle: UIStatusBarStyle {
    isDark ? .lightContent : .darkContent
  }

  /// Reports its own re-parent so the pre-push parking can stay hidden until UIKit takes
  /// it — see `armPrestageRevealOnReparent`.
  override func loadView() {
    view = ChatPrestageRootView()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    let viewDidLoadStartedAt = ProcessInfo.processInfo.systemUptime
    let appearance: [String: Any] = ChatAppearanceDraftStore.chatRawAppearance(isDark: isDark)
    view.backgroundColor = ChatListAppearance.from(raw: appearance).wallpaperBase

    // Same live-repaint contract as ChatConversationController: without this the agent
    // chat keeps whatever wallpaper it was built with until it is rebuilt.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppearanceDraftChanged(_:)),
      name: ChatAppearanceDraftStore.didChangeNotification,
      object: nil
    )

    // Headless transport: in the hierarchy so it gets a window and connects the
    // agent socket, but not a second full-screen chat UI. Full-screen + local
    // message list + blur layers here previously doubled memory with ChatMainView
    // and contributed to SIGKILL (jetsam) when opening Vibe AI.
    agentView.onRowsChanged = { [weak self] rows in
      self?.mainView.setRows(rows)
    }
    agentView.onStreamingStateChanged = { [weak self] streaming in
      self?.mainView.setAgentStreaming(streaming)
    }
    agentView.onHeaderStateChanged = { [weak self] title, subtitle in
      self?.mainView.setHeaderTitle(title)
      self?.mainView.setHeaderSubtitle(subtitle)
    }
    agentView.onNativeEvent.handler = { [weak self] payload in
      self?.handleAgentEvent(payload)
    }
    agentView.surfaceId = "native_agent_transport"
    agentView.prepareForTransportOnly()
    // Skip expensive wallpaper/blur styling on the transport-only instance.
    view.addSubview(agentView)

    // Visible chat surface — the real chat UI, driven directly (no engine).
    mainView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(mainView)
    NSLayoutConstraint.activate([
      mainView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      mainView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      mainView.topAnchor.constraint(equalTo: view.topAnchor),
      mainView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    mainView.onNativeEvent.handler = { [weak self] payload in
      self?.handleMainEvent(payload)
    }
    mainView.setExternalNavigationHeaderEnabled(false)
    mainView.surfaceId = "native_agent_chat"
    mainView.setDefersTranscriptUpdatesForPresentation(true)
    mainView.setDefersEngineStateRefreshes(true)
    mainView.setEngineChannelBindingEnabled(false)
    mainView.setStatusAuthorityEnabled(false)
    mainView.setAppearance(appearance)
    mainView.setHeaderMode("default")
    mainView.setProfileName("Vibe AI")
    mainView.setIsGroupOrChannel(false)
    mainView.setAgentChatMode(true)
    // Give the embedded list the built-in agent chat's canonical id. This surface bypasses
    // applyRoute (where other chats get their engine chat id), so without this the music
    // cells have no chat id and never register into the player-sheet list. Channel binding
    // stays disabled above — this is identity only, so it never rebinds the transcript.
    mainView.setEngineChatId("vibe_agent")
    mainView.setInputPlaceholder("Message Vibe AI")
    mainView.setInputBarEnabled(true)
    // Route sends to us (the agent transport) instead of the chat engine.
    mainView.setNativeSendEnabled(false)
    mainView.setPage(ChatConversationPage.chat.rawValue, animated: false)
    NSLog(
      "[AgentOpen] viewDidLoad bodyMs=%d sinceInitMs=%d",
      Int((ProcessInfo.processInfo.systemUptime - viewDidLoadStartedAt) * 1000),
      Int((ProcessInfo.processInfo.systemUptime - createdAt) * 1000))
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setNavigationBarHidden(true, animated: false)
    mainView.setGeometryFrozenForDismissal(false)
  }

  /// Repaint on wallpaper/theme edits instead of waiting to be rebuilt.
  @objc private func handleAppearanceDraftChanged(_ notification: Notification) {
    mainView.setAppearance(ChatAppearanceDraftStore.chatRawAppearance(isDark: isDark))
  }

  /// Stage the local persisted agent transcript at the real destination bounds before
  /// UIKit starts the push. The previous controller emitted 140 rows from viewDidLoad
  /// while both collection bounds and content size were 0x0, after first restoring 21
  /// unrelated Saved Messages rows; the next layout therefore rebuilt the entire page
  /// during the transition. This follows the normal chat's populated-frame-one contract.
  func prepareForNavigationPush(in navigationController: UINavigationController) {
    loadViewIfNeeded()
    let destinationSafeBottom = max(
      navigationController.view.safeAreaInsets.bottom,
      navigationController.view.window?.safeAreaInsets.bottom ?? 0
    )
    mainView.setNavigationPrestageSafeAreaBottom(destinationSafeBottom)
    mainView.beginNavigationPushPrestaging()
    view.frame = navigationController.view.bounds
    view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.isHidden = true
    navigationController.view.insertSubview(view, at: 0)
    UIView.performWithoutAnimation {
      view.setNeedsLayout()
      view.layoutIfNeeded()
      mainView.layoutIfNeeded()
    }
    stageInitialRowsIfPossible(reason: "pre-push")
    mainView.finishNavigationPushPrestaging()
    UIView.performWithoutAnimation {
      view.layoutIfNeeded()
      mainView.layoutIfNeeded()
    }
    // Same parked-frame defect as the chat surface, same reveal contract — see
    // `ChatConversationController.armPrestageRevealOnReparent`. The view stays hidden
    // until UIKit re-parents it out of the navigation container, so a commit that lands
    // while it is still parked cannot paint a full-screen agent page over Home.
    armPrestageRevealOnReparent(parkedIn: navigationController.view)
  }

  private weak var prestageParkingSuperview: UIView?
  private var prestageRevealToken = 0

  private func armPrestageRevealOnReparent(parkedIn container: UIView) {
    prestageRevealToken &+= 1
    let token = prestageRevealToken
    prestageParkingSuperview = container
    guard let root = view as? ChatPrestageRootView else {
      flashProbeLog("reveal-fallback agent — root is \(type(of: view)), unhiding while parked")
      view.isHidden = false
      return
    }
    root.prestageProbeLabel = "vibe_agent"
    root.onSuperviewChanged = { [weak self] superview in
      guard let self, self.prestageRevealToken == token else { return }
      guard let superview, superview !== self.prestageParkingSuperview else { return }
      self.revealPrestagedView(reason: "reparent")
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self, self.prestageRevealToken == token, self.view.isHidden else { return }
      NSLog("[AgentOpen] prestage-reveal WATCHDOG — re-parent never happened")
      self.revealPrestagedView(reason: "watchdog")
    }
  }

  private func revealPrestagedView(reason: String) {
    guard view.isHidden else { return }
    // Never unhide a view that is still parked — see the chat surface's copy of this.
    let stillParked = prestageParkingSuperview.map { view.superview === $0 } ?? false
    if let parking = prestageParkingSuperview, view.superview === parking {
      view.removeFromSuperview()
    }
    (view as? ChatPrestageRootView)?.onSuperviewChanged = nil
    prestageParkingSuperview = nil
    view.isHidden = false
    NSLog("[AgentOpen] prestage-reveal by=%@", reason)
    flashProbeLog(
      "reveal agent by=\(reason) stillParked=\(stillParked ? "Y" : "N") "
        + "super=\(view.superview.map { String(describing: type(of: $0)) } ?? "nil") "
        + "frame=\(NSCoder.string(for: view.frame)) "
        + "superBounds=\(NSCoder.string(for: view.superview?.bounds ?? .zero)) "
        + "anims=\(view.superview?.layer.animationKeys()?.count ?? 0)")
  }

  private func stageInitialRowsIfPossible(reason: String) {
    guard !didStageInitialRows, mainView.bounds.width > 1, mainView.bounds.height > 1 else {
      return
    }
    didStageInitialRows = true
    let startedAt = ProcessInfo.processInfo.systemUptime
    let rows = agentView.currentHostRows()
    mainView.setAuthoritativeRows(rows)
    agentView.synchronizeHostState(emitRows: false)
    NSLog(
      "[AgentOpen] initial-stage reason=%@ rows=%d bounds=%.0fx%.0f ms=%d",
      reason, rows.count, mainView.bounds.width, mainView.bounds.height,
      Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000))
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // Non-Home entry points may push this controller directly. They still seed on the
    // first usable bounds instead of from viewDidLoad's detached 0x0 hierarchy.
    stageInitialRowsIfPossible(reason: "first-layout")
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    mainView.completeTranscriptPresentation()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    // See the note on the other chat host: an interactive pop drifts the composer
    // height, and the transcript inherits it as a gap on the next open.
    mainView.setGeometryFrozenForDismissal(true)
    mainView.captureReopenSnapshot()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    mainView.persistViewportState()
  }

  private func handleMainEvent(_ payload: [String: Any]) {
    let type = (payload["type"] as? String) ?? ""
    // Always log share-related traffic; throttle other high-volume events.
    if type == "inputActionPressed" || type == "messageSelectionChanged"
      || type == "agentToast" || type.hasPrefix("share")
    {
      NSLog(
        "[ChatShare] agentMainEvent type=%@ keys=%@",
        type,
        payload.keys.sorted().joined(separator: ",")
      )
    }
    switch type {
    case "headerBack":
      onClose?()
    case "headerAvatarPressed":
      pushAgentProfile(animated: true)
    case "agentModelPressed":
      agentView.presentModelPicker(from: self)
    case "profileAppearanceUpdated":
      mainView.refreshProfileAppearance()
    case "sendMessage":
      let text = ((payload["text"] as? String) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return }
      agentView.submitText(text, userMessageId: payload["messageId"] as? String)
    case "agentStopStreaming":
      agentView.stopStreaming()
    case "agentHistoryPressed":
      agentView.presentConversationHistory(from: self)
    case "agentNewChatPressed":
      agentView.startNewChatSession()
    case "openAgentPanel":
      agentView.presentAgentControlPanel(from: self)
    case "agentCreateRequested":
      mainView.setComposerText("Create a new agent", focus: true)
    case "agentChatPressed":
      guard
        let agentUserId =
          (payload["agentUserId"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !agentUserId.isEmpty
      else { return }
      let agentName = (payload["agentName"] as? String) ?? "Agent"
      let agentUsername =
        (payload["agentUsername"] as? String)
        ?? (payload["agentHandle"] as? String)
      let agentID = (payload["agentId"] as? String) ?? (payload["agent_id"] as? String)
      let bridgeProvider = (payload["provider"] as? String) ?? (payload["agentBridgeProvider"] as? String)
      Task { @MainActor [weak self] in
        guard let self else { return }
        await openAgentDirectChat(
          from: self,
          agentUserId: agentUserId,
          agentName: agentName,
          agentUsername: agentUsername,
          agentId: agentID,
          bridgeProvider: bridgeProvider
        )
      }
    case "inputActionPressed":
      handleAgentShareAction(payload)
    case "agentToast":
      if let message = payload["message"] as? String, !message.isEmpty {
        AppToastController.shared.show(message)
      }
    case "messageSelectionChanged":
      let active = (payload["active"] as? Bool) ?? false
      let count = (payload["selectedCount"] as? Int) ?? 0
      NSLog("[ChatShare] agent selectionChanged active=%@ count=%d", active ? "Y" : "N", count)
    default:
      agentView.handleHostEvent(payload)
    }
  }

  /// Share / delete from the Vibe AI surface (does not go through ChatConversationController).
  private func handleAgentShareAction(_ payload: [String: Any]) {
    let action = ((payload["action"] as? String) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let messageIds = (payload["messageIds"] as? [String]) ?? []
    let messages = (payload["messages"] as? [[String: Any]]) ?? []
    let firstType = (messages.first?["type"] as? String) ?? "-"
    NSLog(
      "[ChatShare] agentShare action=%@ ids=%d payloads=%d session=%@ firstType=%@ window=%@",
      action,
      messageIds.count,
      messages.count,
      AppSessionConfig.current != nil ? "Y" : "N",
      firstType,
      view.window != nil ? "Y" : "N"
    )

    switch action {
    case "shareInside":
      guard AppSessionConfig.current != nil else {
        NSLog("[ChatShare] agentShare aborted: no session")
        AppToastController.shared.show("Sign in to forward messages")
        return
      }
      guard !messageIds.isEmpty || !messages.isEmpty else {
        NSLog("[ChatShare] agentShare aborted: empty selection")
        AppToastController.shared.show("Select a message to forward")
        return
      }
      presentAgentShareSheet(messageIds: messageIds, messagePayloads: messages)
    case "shareOutside":
      // shareOutside is usually handled inside ChatListView; log if it reaches here.
      NSLog("[ChatShare] agentShare shareOutside reached host (unexpected)")
    case "delete":
      // Local-only clear for agent transcript selection.
      mainView.clearMessageSelection()
      NSLog("[ChatShare] agentShare delete (selection cleared; agent transcript is local)")
    default:
      NSLog("[ChatShare] agentShare unhandled action=%@", action)
    }
  }

  private func presentAgentShareSheet(
    messageIds: [String],
    messagePayloads: [[String: Any]]
  ) {
    NSLog(
      "[ChatShare] presentAgentShareSheet ids=%d payloads=%d",
      messageIds.count,
      messagePayloads.count
    )
    // Drop keyboard so the sheet isn't covered / mis-presented.
    view.endEditing(true)
    mainView.endEditing(true)

    let presentBlock = { [weak self] in
      guard let self else {
        NSLog("[ChatShare] presentAgentShareSheet aborted: self deallocated")
        return
      }
      if self.presentedViewController != nil {
        NSLog(
          "[ChatShare] presentAgentShareSheet dismissing existing presented=%@",
          String(describing: type(of: self.presentedViewController!))
        )
      }
      let previewSnippet = ChatConversationController.forwardPreviewText(
        messageIds: messageIds, messagePayloads: messagePayloads, fromChatId: "")
      let shareRoot = ShareChatSelectionView(
        previewText: previewSnippet,
        messageCount: max(messageIds.count, messagePayloads.count, 1),
        onSelect: { [weak self] searchPayload in
          guard let self else { return }
          let targetChatIds = (searchPayload["chatIds"] as? [String]) ?? []
          let caption = (searchPayload["caption"] as? String) ?? ""
          NSLog(
            "[ChatShare] agentShare send targets=%d payloads=%d captionLen=%d",
            targetChatIds.count,
            messagePayloads.count,
            caption.count
          )
          let sent = ChatAgentConversationController.forwardAgentMessages(
            messagePayloads: messagePayloads,
            messageIds: messageIds,
            toChatIds: targetChatIds,
            caption: caption
          )
          DispatchQueue.main.async {
            self.mainView.clearMessageSelection(animated: true)
            if sent > 0 {
              AppToastController.shared.show(
                sent == 1 ? "Message forwarded" : "\(sent) messages forwarded")
            } else {
              AppToastController.shared.show("Couldn't forward those messages")
            }
            NSLog("[ChatShare] agentShare finished sent=%d", sent)
          }
        },
        onOpenTarget: { [weak self] row in
          guard let self else { return }
          ChatPendingForwardStore.set(
            .init(
              fromChatId: "",
              messageIds: messageIds,
              messagePayloads: messagePayloads,
              previewText: previewSnippet
            ),
            for: row.chatId
          )
          self.mainView.clearMessageSelection(animated: true)
          let targetRoute = ChatRoute(row: row)
          self.dismiss(animated: true) {
            DispatchQueue.main.async {
              guard let nav = self.navigationController else { return }
              let isDark = nav.traitCollection.userInterfaceStyle == .dark
              let controller = ChatConversationController(
                route: targetRoute,
                isDark: isDark,
                onClose: { [weak nav] in
                  guard let nav, nav.viewControllers.count > 1 else { return }
                  nav.popViewController(animated: true)
                }
              )
              nav.pushViewController(controller, animated: true)
            }
          }
        }
      )
      let shareVC = UIHostingController(rootView: shareRoot)
      shareVC.modalPresentationStyle = .pageSheet
      shareVC.isModalInPresentation = false
      shareVC.view.backgroundColor =
        self.traitCollection.userInterfaceStyle == .dark
        ? UIColor(white: 0.07, alpha: 1)
        : .systemBackground
      if let sheet = shareVC.sheetPresentationController {
        if #available(iOS 16.0, *) {
          sheet.detents = [.large(), .medium()]
          sheet.selectedDetentIdentifier = .large
        } else {
          sheet.detents = [.medium(), .large()]
        }
        sheet.prefersGrabberVisible = true
        sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        sheet.preferredCornerRadius = 28
      }
      var presenter: UIViewController = self
      while let presented = presenter.presentedViewController { presenter = presented }
      // Prefer the navigation controller when available (more reliable sheet host).
      if let nav = self.navigationController {
        var navPresenter: UIViewController = nav
        while let presented = navPresenter.presentedViewController { navPresenter = presented }
        presenter = navPresenter
      }
      NSLog(
        "[ChatShare] agentShare presenting on %@ isViewLoaded=%@ window=%@",
        String(describing: type(of: presenter)),
        self.isViewLoaded ? "Y" : "N",
        self.view.window != nil ? "Y" : "N"
      )
      presenter.present(shareVC, animated: true) {
        let presented = presenter.presentedViewController
        NSLog(
          "[ChatShare] agentShare present completion presented=%@ type=%@",
          presented != nil ? "Y" : "N",
          presented.map { String(describing: type(of: $0)) } ?? "nil"
        )
      }
    }

    if Thread.isMainThread {
      presentBlock()
    } else {
      DispatchQueue.main.async(execute: presentBlock)
    }
  }

  /// Forward from agent transcript payloads (not ChatEngine live rows).
  @discardableResult
  fileprivate static func forwardAgentMessages(
    messagePayloads: [[String: Any]],
    messageIds: [String],
    toChatIds: [String],
    caption: String = ""
  ) -> Int {
    var rows = messagePayloads
    // Fallback: resolve via engine if payloads missing (e.g. older event).
    if rows.isEmpty {
      for mid in messageIds {
        if let row = ChatEngine.shared.getLiveMessageRow([
          "chatId": "vibe_agent",
          "messageId": mid,
        ]) {
          rows.append(row)
        }
      }
    }
    NSLog(
      "[ChatShare] forwardAgentMessages rows=%d targets=%d",
      rows.count,
      toChatIds.count
    )
    guard !rows.isEmpty, !toChatIds.isEmpty else { return 0 }

    let meId = AppSessionConfig.current?.userID
    let meName = AppSessionConfig.current?.name ?? AppSessionConfig.current?.username
    let meAvatar = AppSessionConfig.current?.profileImage
    var sent = 0

    for targetChatId in toChatIds {
      let target = targetChatId.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !target.isEmpty else { continue }
      for row in rows {
        let type = ((row["type"] as? String) ?? "text").lowercased()
        let text = (row["text"] as? String) ?? (row["plainContent"] as? String) ?? ""
        var metadata = (row["metadata"] as? [String: Any]) ?? [:]
        let sourceId = (row["messageId"] as? String) ?? (row["id"] as? String) ?? UUID().uuidString

        metadata["forwardedFromChatId"] = "vibe_agent"
        metadata["forwarded_from_chat_id"] = "vibe_agent"
        metadata["forwardedFromMessageId"] = sourceId
        metadata["forwarded_from_message_id"] = sourceId
        metadata["forwardedFromName"] =
          metadata["forwardedFromName"]
          ?? ((row["isMe"] as? Bool) == true ? (meName ?? "You") : "Vibe AI")
        metadata["forwarded_from_name"] = metadata["forwardedFromName"]
        if let meId, (row["isMe"] as? Bool) == true {
          metadata["forwardedFromUserId"] = meId
          metadata["forwarded_from_user_id"] = meId
        } else {
          metadata["forwardedFromUserId"] = "vibe_agent"
          metadata["forwarded_from_user_id"] = "vibe_agent"
        }
        if let meAvatar, (row["isMe"] as? Bool) == true {
          metadata["forwardedFromAvatar"] = meAvatar
          metadata["forwarded_from_avatar"] = meAvatar
        }
        metadata["isForwarded"] = true
        metadata["is_forwarded"] = true
        // Keep snake_case mirrors for server/history round-trip.
        if let name = metadata["forwardedFromName"] {
          metadata["forwarded_from_name"] = name
        }
        if let uid = metadata["forwardedFromUserId"] {
          metadata["forwarded_from_user_id"] = uid
        }
        if let av = metadata["forwardedFromAvatar"] {
          metadata["forwarded_from_avatar"] = av
        }

        for key in [
          "mediaUrl", "media_url", "localMediaUrl", "local_media_url", "fileName", "file_name",
          "fileSize", "duration", "thumbnailBase64", "mediaKey", "cover", "coverUrl", "cover_url",
          "artwork", "artist", "source", "platform",
        ] {
          if metadata[key] == nil, let value = row[key] {
            metadata[key] = value
          }
        }
        if metadata["cover"] == nil {
          if let c = (metadata["coverUrl"] as? String) ?? (metadata["cover_url"] as? String)
            ?? (metadata["artwork"] as? String)
          {
            metadata["cover"] = c
            metadata["coverUrl"] = c
          }
        }

        var payload: [String: Any] = [
          "chatId": target,
          "type": type == "agent_progress_tree" ? "text" : type,
          "text": text,
          "metadata": metadata,
        ]
        if let mediaUrl = metadata["mediaUrl"] as? String ?? row["mediaUrl"] as? String {
          payload["mediaUrl"] = mediaUrl
        }
        if let local = metadata["localMediaUrl"] as? String ?? row["localMediaUrl"] as? String {
          payload["localMediaUrl"] = local
          payload["mediaUrl"] = payload["mediaUrl"] ?? local
        }
        if let fileName = metadata["fileName"] as? String ?? row["fileName"] as? String {
          payload["fileName"] = fileName
        }
        if let duration = metadata["duration"] ?? row["duration"] {
          payload["duration"] = duration
        }
        if let thumb = metadata["thumbnailBase64"] as? String ?? row["thumbnailBase64"] as? String {
          payload["thumbnailBase64"] = thumb
        }
        if let mediaKey = metadata["mediaKey"] as? String ?? row["mediaKey"] as? String {
          payload["mediaKey"] = mediaKey
        }

        // Agent turns often ship type "text" with media in metadata — normalize music.
        if (payload["type"] as? String) == "text",
          metadata["cover"] != nil || metadata["artist"] != nil,
          payload["mediaUrl"] != nil
        {
          payload["type"] = "music"
        }

        let result = ChatEngine.shared.sendMessage(payload)
        let ok = (result["accepted"] as? Bool) == true
        NSLog(
          "[ChatShare] agentForward target=%@ type=%@ accepted=%@ reason=%@",
          String(target.prefix(12)),
          payload["type"] as? String ?? "?",
          ok ? "Y" : "N",
          String(describing: result["reason"] ?? "")
        )
        if ok { sent += 1 }
      }
      let trimmedCaption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmedCaption.isEmpty {
        _ = ChatEngine.shared.sendMessage([
          "chatId": target,
          "type": "text",
          "text": trimmedCaption,
        ])
      }
    }
    return sent
  }

  private func pushAgentProfile(animated: Bool) {
    let route = ChatRoute(
      chatId: "vibe_agent",
      title: "Vibe AI",
      peerUserId: nil,
      peerAgentId: "vibe_agent",
      isAgent: true,
      avatarURI: nil,
      isGroup: false,
      initialRows: []
    )
    let onClose: () -> Void = { [weak self] in
      guard let self, let navigationController = self.navigationController,
        navigationController.viewControllers.count > 1
      else { return }
      navigationController.popViewController(animated: true)
    }
    let onProfileAppearanceUpdated: () -> Void = { [weak self] in
      self?.mainView.refreshProfileAppearance()
    }

    guard let navigationController else { return }
    if let top = navigationController.topViewController as? ChatProfileRootController,
      top.chatId == route.chatId
    {
      top.update(
        route: route,
        isDark: isDark,
        onClose: onClose,
        onProfileAppearanceUpdated: onProfileAppearanceUpdated
      )
      return
    }

    let controller = ChatProfileRootController(
      route: route,
      isDark: isDark,
      onClose: onClose,
      onProfileAppearanceUpdated: onProfileAppearanceUpdated
    )
    navigationController.pushViewController(controller, animated: animated)
  }

  private func handleAgentEvent(_ payload: [String: Any]) {
    let type = (payload["type"] as? String) ?? ""
    switch type {
    case "agentToast":
      if let message = payload["message"] as? String, !message.isEmpty {
        AppToastController.shared.show(message)
      }
    case "agentCreateRequested":
      mainView.setComposerText("Create a new agent", focus: true)
    case "agentChatPressed":
      guard
        let agentUserId =
          (payload["agentUserId"] as? String)?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !agentUserId.isEmpty
      else { return }
      let agentName = (payload["agentName"] as? String) ?? "Agent"
      let agentUsername =
        (payload["agentUsername"] as? String)
        ?? (payload["agentHandle"] as? String)
      let agentID = (payload["agentId"] as? String) ?? (payload["agent_id"] as? String)
      let bridgeProvider = (payload["provider"] as? String) ?? (payload["agentBridgeProvider"] as? String)
      Task { @MainActor [weak self] in
        guard let self else { return }
        await openAgentDirectChat(
          from: self,
          agentUserId: agentUserId,
          agentName: agentName,
          agentUsername: agentUsername,
          agentId: agentID,
          bridgeProvider: bridgeProvider
        )
      }
    default:
      break
    }
  }
}

// Same file-scoped helper the other App sources carry (AppRuntimeController, SettingsView).
private extension String {
  var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
