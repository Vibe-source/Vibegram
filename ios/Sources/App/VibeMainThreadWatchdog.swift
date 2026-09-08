import Foundation
import UIKit

/// Watches the main run loop from a background queue and reports every stretch where the
/// main thread stopped advancing: how long, which run-loop mode, its run-state and stack.
final class VibeMainThreadWatchdog {

  static let shared = VibeMainThreadWatchdog()

  /// Below this a busy main thread is ordinary frame work; above it a person perceives
  /// the app as having stopped.
  private let hangThreshold: CFTimeInterval = 0.35
  /// How often the watcher samples: fine enough to time a hang, coarse enough to be free.
  private let sampleInterval: CFTimeInterval = 0.05
  /// Repeat interval for the "still blocked" line during one continuous hang.
  private let ongoingReportInterval: CFTimeInterval = 1.0
  /// A gap between watcher ticks larger than this means the process was suspended, so
  /// the busy stamp is pocket time rather than a hang. Generous, since a late tick is cheap.
  private static let suspensionSampleGap: CFTimeInterval = 2.0
  /// Later than CoreAnimation's commit observer, so a slow commit is still inside the
  /// measured busy window when the idle observer clears it.
  private static let idleObserverOrder: CFIndex = 3_000_000

  private let queue = DispatchQueue(label: "vibe.mainthread.watchdog", qos: .utility)
  private var timer: DispatchSourceTimer?
  private var busyObserver: CFRunLoopObserver?
  private var idleObserver: CFRunLoopObserver?

  // MARK: Shared state

  // Written by the observers on main, read by the watcher off it. Guarded by the cheapest
  // lock available, because the write side runs on every main run-loop iteration.

  /// Heap-allocated: `&property` of an inline lock yields a pointer Swift may move,
  /// which silently breaks the mutual exclusion.
  private let lock: UnsafeMutablePointer<os_unfair_lock> = {
    let pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    pointer.initialize(to: os_unfair_lock())
    return pointer
  }()
  private var busySince: CFTimeInterval = 0
  private var busyMode: String = ""
  /// Longest hang seen, for the one-line summary when the app backgrounds.
  private var worstHang: CFTimeInterval = 0

  // MARK: Watcher state (watchdog queue only)

  private var reportedHangStart: CFTimeInterval = 0
  private var lastOngoingReport: CFTimeInterval = 0
  /// Captured when the hang is detected, not at recovery: by then the main thread has
  /// moved on, and the interesting breadcrumb is the one it was standing on.
  private var reportedHangActivity = "?"
  private var reportedHangMode = "?"
  /// Scheduler state at detection: `running` means a busy loop, `waiting` a blocking call.
  private var reportedHangState: MainThreadRunState?
  /// The main thread's own stack, sampled while it was stopped at detection time.
  private var reportedHangStack: [StackFrame] = []
  /// When the watcher itself last ran. A main-thread hang never delays this queue, so a
  /// gap here means the *process* stopped, not the main thread. See `sample`.
  private var lastSampleAt: CFTimeInterval = 0

  /// The main thread's mach port, captured on `start()`. `pthread_mach_thread_np` must
  /// be asked on the thread itself and returns a borrowed name that needs no release.
  private var mainThreadPort: mach_port_t = 0

  private init() {}

  /// Installs the observers and starts watching. Safe to call once, from the main thread.
  func start() {
    guard busyObserver == nil else { return }

    mainThreadPort = pthread_mach_thread_np(pthread_self())

    // Order 0: stamps the start of a busy stretch before any other observer has run.
    let busyActivities: CFRunLoopActivity = [.beforeSources, .afterWaiting]
    let busy = CFRunLoopObserverCreateWithHandler(
      kCFAllocatorDefault, busyActivities.rawValue, true, 0
    ) { [weak self] _, _ in
      guard let self else { return }
      let now = CACurrentMediaTime()
      os_unfair_lock_lock(self.lock)
      let alreadyBusy = self.busySince != 0
      os_unfair_lock_unlock(self.lock)
      // Only the START of a stretch is stamped; restamping each iteration would reset
      // the clock and no hang would ever be long enough to see.
      guard !alreadyBusy else { return }
      // Read here, on main, while the loop is in it: it is what separates "froze while
      // you were dragging" from "froze on its own".
      let mode = (CFRunLoopCopyCurrentMode(CFRunLoopGetMain())?.rawValue as String?) ?? "?"
      os_unfair_lock_lock(self.lock)
      if self.busySince == 0 {
        self.busySince = now
        self.busyMode = mode
      }
      os_unfair_lock_unlock(self.lock)
    }
    // Late order: the loop counts as idle only once CoreAnimation has committed, so a
    // slow commit is measured as busy instead of falling between the two observers.
    let idleActivities: CFRunLoopActivity = [.beforeWaiting, .exit]
    let idle = CFRunLoopObserverCreateWithHandler(
      kCFAllocatorDefault, idleActivities.rawValue, true, Self.idleObserverOrder
    ) { [weak self] _, _ in
      guard let self else { return }
      os_unfair_lock_lock(self.lock)
      self.busySince = 0
      self.busyMode = ""
      os_unfair_lock_unlock(self.lock)
    }
    guard let busy, let idle else { return }
    CFRunLoopAddObserver(CFRunLoopGetMain(), busy, .commonModes)
    CFRunLoopAddObserver(CFRunLoopGetMain(), idle, .commonModes)
    busyObserver = busy
    idleObserver = idle

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + sampleInterval, repeating: sampleInterval)
    timer.setEventHandler { [weak self] in self?.sample() }
    timer.resume()
    self.timer = timer

    NSLog(
      "[MainHang] watchdog armed — reporting main-thread blocks over %.0fms",
      hangThreshold * 1000)
  }

  /// One-line summary of the worst hang seen so far, so a session that felt bad leaves
  /// a number behind even if nobody was reading the stream at the time.
  func reportSessionSummary(reason: String) {
    os_unfair_lock_lock(lock)
    let worst = worstHang
    os_unfair_lock_unlock(lock)
    guard worst > 0 else { return }
    NSLog("[MainHang] session summary (%@) — worst main-thread block %.2fs", reason, worst)
  }

  // MARK: Watching

  private func sample() {
    let sampledAt = CACurrentMediaTime()
    let sinceLastSample = lastSampleAt > 0 ? sampledAt - lastSampleAt : 0
    lastSampleAt = sampledAt
    // A missed watcher tick means iOS suspended the whole process, so the busy stamp is
    // stale pocket time rather than a hang. Discard it and start the next window clean.
    if sinceLastSample > Self.suspensionSampleGap {
      os_unfair_lock_lock(lock)
      busySince = 0
      busyMode = ""
      os_unfair_lock_unlock(lock)
      reportedHangStart = 0
      lastOngoingReport = 0
      return
    }

    os_unfair_lock_lock(lock)
    let since = busySince
    let mode = busyMode
    os_unfair_lock_unlock(lock)

    guard since > 0 else {
      // Main is idle. If it was hanging, this is the recovery.
      if reportedHangStart > 0 {
        let duration = CACurrentMediaTime() - reportedHangStart
        NSLog("[MainHang] RECOVERED after %.2fs", duration)
        let fields = Self.runFields(reportedHangState)
        // Durable copy: `NSLog` exists only while a console is attached, and the stack
        // is compacted so a diagnostics export keeps the rest of the session.
        VibeLog.warning(
          "main thread blocked \(String(format: "%.2f", duration))s during \(reportedHangActivity)",
          category: "mainhang",
          metadata: [
            "seconds": String(format: "%.2f", duration),
            "mode": reportedHangMode,
            "during": reportedHangActivity,
            "run": fields.run,
            "cpu": fields.cpu,
            "stack": Self.compactStack(reportedHangStack),
          ])
        VibeOpenTrace.shared.noteHang(
          seconds: duration, mode: reportedHangMode, activity: reportedHangActivity)
        reportedHangStart = 0
        lastOngoingReport = 0
        reportedHangState = nil
        reportedHangStack = []
      }
      return
    }

    let now = CACurrentMediaTime()
    let blockedFor = now - since
    guard blockedFor >= hangThreshold else { return }

    os_unfair_lock_lock(lock)
    if blockedFor > worstHang { worstHang = blockedFor }
    os_unfair_lock_unlock(lock)

    if reportedHangStart != since {
      // A new hang. Announce it as soon as it crosses the threshold rather than waiting
      // to see how long it runs; a hang that ends in a kill never reports its length.
      reportedHangStart = since
      lastOngoingReport = now
      reportedHangMode = mode.isEmpty ? "?" : mode
      reportedHangActivity = VibeOpenTrace.shared.activity
      // Run-state first (read-only), then the stack, which briefly stops the thread.
      reportedHangState = Self.mainThreadRunState(mainThreadPort)
      reportedHangStack = captureMainThreadStack()
      let fields = Self.runFields(reportedHangState)
      NSLog(
        "[MainHang] BLOCKED %.2fs mode=%@ during=%@ run=%@ cpu=%@ — main thread is not advancing; no touches or frames are being serviced",
        blockedFor, reportedHangMode, reportedHangActivity, fields.run, fields.cpu)
      Self.logFrames(reportedHangStack)
      return
    }

    if now - lastOngoingReport >= ongoingReportInterval {
      lastOngoingReport = now
      // Re-sample: one stack says where it started, a later one says whether it is
      // stuck in one call or grinding through a loop of them.
      let ongoingState = Self.mainThreadRunState(mainThreadPort)
      let ongoing = captureMainThreadStack()
      let fields = Self.runFields(ongoingState)
      NSLog(
        "[MainHang] STILL BLOCKED %.2fs mode=%@ during=%@ run=%@ cpu=%@", blockedFor,
        mode.isEmpty ? "?" : mode, reportedHangActivity, fields.run, fields.cpu)
      Self.logFrames(ongoing)
      // A hang long enough to repeat may end in a kill that never reaches the recovery
      // path, so this one goes to the durable log as well.
      VibeLog.warning(
        "main thread STILL blocked \(String(format: "%.2f", blockedFor))s during \(reportedHangActivity)",
        category: "mainhang",
        metadata: [
          "seconds": String(format: "%.2f", blockedFor),
          "mode": mode.isEmpty ? "?" : mode,
          "during": reportedHangActivity,
          "run": fields.run,
          "cpu": fields.cpu,
          "stack": Self.compactStack(ongoing),
        ])
    }
  }

  private static func logFrames(_ frames: [StackFrame]) {
    for (index, frame) in frames.enumerated() {
      NSLog("[MainHang]   %@", frame.line(index: index))
    }
  }

  // MARK: Probing the main thread's run-state

  /// Read-only snapshot from `thread_info`: whether main is burning CPU or parked.
  private struct MainThreadRunState {
    let run: String
    let cpuUsage: Int32
    let idle: Bool

    /// `cpu_usage` on the `TH_USAGE_SCALE` scale, as `thread_info` reports it.
    var cpu: String { "\(cpuUsage)/\(TH_USAGE_SCALE)" }
  }

  private static func runFields(_ state: MainThreadRunState?) -> (run: String, cpu: String) {
    (state?.run ?? "?", state?.cpu ?? "?")
  }

  /// Ported from `AppUIStallWatchdog.mainThreadStateDescription`. Does not suspend the
  /// thread or walk its stack, so it is safe at any time from the watchdog queue.
  private static func mainThreadRunState(_ machThread: mach_port_t) -> MainThreadRunState? {
    guard machThread != 0 else { return nil }
    var info = thread_basic_info()
    // THREAD_BASIC_INFO_COUNT is a compound C macro that does not import into Swift;
    // derive the integer-word count from the struct size instead.
    var count = mach_msg_type_number_t(
      MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        thread_info(machThread, thread_flavor_t(THREAD_BASIC_INFO), rebound, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return nil }
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
    return MainThreadRunState(run: runLabel, cpuUsage: info.cpu_usage, idle: idle)
  }

  // MARK: Sampling the main thread's stack

  // While the main thread is suspended it may hold the malloc or dyld lock, so nothing
  // between `thread_suspend` and `thread_resume` may allocate or call `dladdr`.

  /// Deep enough to cross UIKit into app code; bounded so a cyclic frame chain cannot spin.
  private static let maxStackDepth = 48

  private func captureMainThreadStack() -> [StackFrame] {
    #if arch(arm64)
      let thread = mainThreadPort
      guard thread != MACH_PORT_NULL else { return [.note("<no main-thread port>")] }

      // Everything the suspended window touches is allocated here, before the suspend.
      var addresses: [UInt64] = []
      addresses.reserveCapacity(Self.maxStackDepth + 2)
      var state = arm_thread_state64_t()
      var count = mach_msg_type_number_t(
        MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
      var slot = (next: UInt64(0), returnAddress: UInt64(0))

      guard thread_suspend(thread) == KERN_SUCCESS else {
        return [.note("<thread_suspend failed>")]
      }

      let readState = withUnsafeMutablePointer(to: &state) { statePointer in
        statePointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { rebound in
          thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), rebound, &count)
        }
      }

      if readState == KERN_SUCCESS {
        // Frame records are { saved FP, saved LR } at [fp], [fp+8]. Only register reads,
        // `vm_read_overwrite` and appends into reserved capacity happen in this window.
        var frame = state.__fp
        var previousFrame: UInt64 = 0
        while addresses.count < Self.maxStackDepth {
          let framePointer = Self.stripPointerAuth(frame)
          // Stacks grow down, so a next frame not strictly above the current one is
          // either garbage or a cycle; either way the walk is over.
          guard framePointer != 0, framePointer % 8 == 0, framePointer > previousFrame else {
            break
          }
          guard Self.readMemory(at: framePointer, into: &slot) else { break }
          let returnAddress = Self.stripPointerAuth(slot.returnAddress)
          guard returnAddress != 0 else { break }
          addresses.append(returnAddress)
          previousFrame = framePointer
          frame = slot.next
        }
      }

      thread_resume(thread)

      guard readState == KERN_SUCCESS else { return [.note("<thread_get_state failed>")] }
      // A frameless leaf has not saved LR to its frame yet, so its caller exists only
      // in the register; add it unless the walk already found the same address.
      var ordered: [UInt64] = [Self.stripPointerAuth(state.__pc)]
      let linkRegister = Self.stripPointerAuth(state.__lr)
      if linkRegister != 0, linkRegister != addresses.first {
        ordered.append(linkRegister)
      }
      ordered.append(contentsOf: addresses)
      return Self.symbolicate(ordered)
    #else
      return [.note("<stack sampling requires arm64>")]
    #endif
  }

  /// arm64e signs return addresses and frame pointers in the high bits. Masking to the
  /// user-space range makes them resolvable and is a no-op for unsigned ones.
  private static func stripPointerAuth(_ value: UInt64) -> UInt64 {
    value & 0x0000_7FFF_FFFF_FFFF
  }

  /// Reads one frame record out of the suspended thread's stack with `vm_read_overwrite`,
  /// which returns a failure code instead of trapping on an unmapped address.
  private static func readMemory(
    at address: UInt64, into slot: inout (next: UInt64, returnAddress: UInt64)
  ) -> Bool {
    var readSize: vm_size_t = 0
    let wanted = vm_size_t(MemoryLayout<UInt64>.size * 2)
    let result = withUnsafeMutablePointer(to: &slot) { destination -> kern_return_t in
      vm_read_overwrite(
        mach_task_self_,
        vm_address_t(address),
        wanted,
        vm_address_t(UInt(bitPattern: destination)),
        &readSize)
    }
    return result == KERN_SUCCESS && readSize == wanted
  }

  // MARK: Symbolication

  /// One symbolicated frame. `image` is empty for a marker such as a failed suspend.
  private struct StackFrame {
    let address: UInt64
    let image: String
    let symbol: String?
    /// From the symbol start, or from the image base when there is no symbol.
    let offset: UInt64
    let isApp: Bool

    static func note(_ text: String) -> StackFrame {
      StackFrame(address: 0, image: "", symbol: text, offset: 0, isApp: false)
    }

    /// `image symbol+off`, with app frames marked `*`. Feeds the durable log.
    var compact: String {
      guard !image.isEmpty else { return symbol ?? "?" }
      let location: String
      if let symbol {
        location = "\(symbol)+\(offset)"
      } else if image == "???" {
        location = String(format: "0x%llx", address)
      } else {
        location = String(format: "?+0x%llx", offset)
      }
      return (isApp ? "*" : "") + image + " " + location
    }

    /// The verbose console form: index, image, symbol and offset.
    func line(index: Int) -> String {
      guard !image.isEmpty else { return String(format: "%2d  %@", index, symbol ?? "?") }
      guard let symbol else {
        return String(format: "%2d  %@ 0x%016llx", index, image, address)
      }
      return String(format: "%2d  %@ %@ + %llu", index, image, symbol, offset)
    }
  }

  /// Frames from inside the app bundle (the executable and any embedded framework) are
  /// the ones a reader can act on, so they are marked in the compact stack.
  private static let appBundlePath = Bundle.main.bundlePath
  private static let appExecutableName = Bundle.main.executableURL?.lastPathComponent ?? ""

  private static func symbolicate(_ addresses: [UInt64]) -> [StackFrame] {
    addresses.map { address in
      var info = Dl_info()
      guard let pointer = UnsafeRawPointer(bitPattern: UInt(address)),
        dladdr(pointer, &info) != 0
      else {
        return StackFrame(address: address, image: "???", symbol: nil, offset: 0, isApp: false)
      }
      let path = info.dli_fname.map { String(cString: $0) } ?? ""
      let image = path.isEmpty ? "???" : (path as NSString).lastPathComponent
      let isApp =
        !path.isEmpty
        && (path.hasPrefix(appBundlePath)
          || (!appExecutableName.isEmpty && image == appExecutableName))
      guard let nameCString = info.dli_sname else {
        let base = UInt64(UInt(bitPattern: info.dli_fbase))
        return StackFrame(
          address: address, image: image, symbol: nil, offset: address &- base, isApp: isApp)
      }
      let symbol = demangle(String(cString: nameCString))
      let offset = address &- UInt64(UInt(bitPattern: info.dli_saddr))
      return StackFrame(address: address, image: image, symbol: symbol, offset: offset, isApp: isApp)
    }
  }

  /// `swift_demangle` lives in the Swift runtime but is not exposed to Swift source.
  /// Resolving it by name keeps pretty names without a bridging header.
  private typealias SwiftDemangleFunction = @convention(c) (
    UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
  ) -> UnsafeMutablePointer<CChar>?

  private static let swiftDemangle: SwiftDemangleFunction? = {
    // RTLD_DEFAULT — search every loaded image.
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else {
      return nil
    }
    return unsafeBitCast(symbol, to: SwiftDemangleFunction.self)
  }()

  private static func demangle(_ name: String) -> String {
    guard name.hasPrefix("$s") || name.hasPrefix("_$s"), let demangler = swiftDemangle,
      let output = demangler(name, name.utf8.count, nil, nil, 0)
    else { return name }
    defer { free(output) }
    return String(cString: output)
  }

  // MARK: Compact stack

  /// Innermost entries kept in the durable log, after identical runs are collapsed.
  private static let compactFrameLimit = 12
  /// Upper bound on the compact stack's length; the tail is replaced by "…" past it.
  private static let compactCharacterBudget = 900
  /// Demangled Swift names can run long; clip each frame so twelve fit the budget.
  private static let compactFrameCharacterLimit = 140

  /// The version that goes in the durable log: innermost frames first, every image kept,
  /// app frames marked `*`, runs of one frame shown once with a count.
  private static func compactStack(_ frames: [StackFrame]) -> String {
    guard !frames.isEmpty else { return "<none>" }
    // Collapse runs first so a recursion reads as one entry with a count.
    var entries: [(text: String, count: Int)] = []
    for frame in frames {
      let text = clip(frame.compact, to: compactFrameCharacterLimit)
      if let last = entries.last, last.text == text {
        entries[entries.count - 1].count += 1
      } else {
        entries.append((text: text, count: 1))
      }
    }
    var output = ""
    var emitted = 0
    for entry in entries.prefix(compactFrameLimit) {
      let piece = entry.count > 1 ? "\(entry.text) ×\(entry.count)" : entry.text
      let separator = output.isEmpty ? "" : " ← "
      guard output.count + separator.count + piece.count + 2 <= compactCharacterBudget else {
        break
      }
      output += separator + piece
      emitted += 1
    }
    if output.isEmpty {
      output = clip(entries[0].text, to: compactCharacterBudget - 2)
      emitted = 1
    }
    if emitted < entries.count { output += " …" }
    return output
  }

  private static func clip(_ text: String, to limit: Int) -> String {
    text.count <= limit ? text : String(text.prefix(max(limit - 1, 0))) + "…"
  }
}
