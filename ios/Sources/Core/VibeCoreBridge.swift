import Foundation
import Security

/// Swift-side owner of the Rust timeline core.
///
/// **P2 status: linked but dark.** Nothing in the app reads from this. The chat
/// list, the engine, and every render path are untouched and remain the sole
/// source of truth. This type exists so the link, the threading model, and the
/// callback boundary can be exercised on a real device before any UI depends on
/// them — which is the entire point of a "linked but dark" stage.
///
/// Rollback is deleting the `framework:` line in `ios/project.yml` and
/// regenerating. There is no data migration to undo, because nothing writes.
///
/// # Threading
///
/// The core owns a worker thread and there is **no synchronous read API** — by
/// construction, not by convention. Calls here return immediately; results
/// arrive on ``VibeCoreDeltaSink`` from the Rust worker thread. Anything that
/// touches UIKit as a result must hop to the main queue itself, which is why the
/// sink re-dispatches rather than assuming a thread.
///
/// This is the structural fix for the `[ChatEngine][MAIN-THREAD-HANG]` class of
/// bug: there is nothing for a UI getter to block on.
enum VibeCoreBridge {

  /// Debug switch. Default **off**, and deliberately not a `UserDefaults` read
  /// at call sites scattered around the app — one gate, one place.
  ///
  /// Even when on, this only constructs the core and logs. It changes no
  /// rendering. Turning it on cannot alter what the user sees.
  static var isEnabled: Bool {
    #if DEBUG
      return UserDefaults.standard.bool(forKey: "vibeCoreBridgeEnabled")
    #else
      return false
    #endif
  }

  /// Flips the switch from the diagnostics screen.
  ///
  /// A gate that can only be set by attaching a debugger or editing a plist is a
  /// gate nobody flips, which makes the self-test behind it dead code. Turning it
  /// off tears the worker down rather than leaving an orphan thread running with
  /// nothing able to reach it.
  ///
  /// Release builds ignore this: ``isEnabled`` is compiled to `false` there, so
  /// persisting `true` would only produce a switch that lies.
  static func setEnabled(_ enabled: Bool) {
    #if DEBUG
      UserDefaults.standard.set(enabled, forKey: "vibeCoreBridgeEnabled")
      VibeLog.notice("[VibeCore] bridge \(enabled ? "enabled" : "disabled")", category: "core")
      if !enabled { shutdown() }
    #endif
  }

  private static let queue = DispatchQueue(label: "com.vibegram.core.bridge")
  private static var handle: VibeCoreHandle?

  /// Resolves the RSA private key for the core's key-unwrap seam.
  ///
  /// Set once by whoever owns the Keychain session (the engine). Left `nil`, the
  /// core runs with no way to open an envelope and every encrypted row
  /// canonicalizes to the decryption-failure state — the same thing the shipped
  /// client shows when the Keychain is locked. That is fail-closed on purpose: a
  /// core that cannot get a key must render nothing rather than guess.
  ///
  /// A closure rather than a stored `SecKey` because the key is TTL-cached and
  /// dropped on logout; capturing one here would outlive the lifetime its owner
  /// chose for it.
  ///
  /// Defaults to the box the engine publishes into, so the seam is wired without
  /// any caller having to remember to wire it. Overridable for tests.
  static var privateKeyProvider: (() -> SecKey?)? = { VibeCorePrivateKeyBox.shared.current() }

  /// Routes core callbacks to whoever is showing that chat.
  private static let router = VibeCoreRouter()

  /// The **one** core for the process. Idempotent.
  ///
  /// # Why one and not one per chat
  ///
  /// The reducer is keyed by chat internally and holds the tombstones, id
  /// aliases, settle slots and generations for all of them. A second handle is a
  /// second reducer with a second set of all of that — two cores that disagree
  /// about the same conversation, which is worse than no core. It also means two
  /// worker threads and two copies of every window.
  ///
  /// `ownUserId` is taken from the first caller and pinned. It decides
  /// `author.is_me` and the direction-dependent key-candidate order, so a later
  /// caller passing a different id would silently change how earlier chats
  /// decrypt. A genuine identity change is a logout, which tears this down.
  /// An empty id is refused rather than pinned.
  ///
  /// `own_user_id` decides `author.is_me`, and a frame that carries `senderId`
  /// rather than an explicit `isMe` resolves it by comparing against this. Pinned
  /// empty, every such frame becomes "not me" — while store-restored rows, which
  /// do carry `isMe`, stay correct. The same conversation then renders one way
  /// from one ingest source and the other way from the other, and the transcript
  /// visibly changes sides. Observed on device 2026-08-03.
  ///
  /// It is reachable because the first caller is whichever comes first, and at
  /// launch that is the engine's store-restore ingest — which runs before a chat
  /// surface exists and passes `currentUserIdLocked() ?? ""`. Returning `nil` here
  /// costs that one ingest and lets the next caller, with a real id, bring the
  /// core up correctly. Pinning the empty string would be wrong for the process
  /// lifetime.
  static func sharedCore(ownUserId: String) -> VibeCoreHandle? {
    queue.sync {
      if let handle { return handle }
      guard !ownUserId.isEmpty else {
        NSLog("[VibeCore] core NOT started — ownUserId empty (would render every row as peer)")
        return nil
      }
      let config = VibeFfiConfig(
        ownUserId: ownUserId,
        // One display frame at 120 Hz. Stream sources coalesce up to this
        // barrier; everything else is an immediate barrier.
        flushFrameIntervalMs: 8
      )
      // The key seam. Without it the core holds `VibeDenyAllKeyUnwrapper` and
      // cannot open a single envelope — it would order rows it cannot read.
      let unwrapper = VibeKeychainKeyUnwrapper { privateKeyProvider?() }
      let created = VibeCoreHandle(config: config, sink: router, unwrapper: unwrapper)
      handle = created
      // NSLog, not VibeLog: which identity the core pinned is the first thing to
      // check when the transcript renders on the wrong side, and it has to be
      // visible in a plain device log.
      NSLog(
        "[VibeCore] core up ownUserId=%@ keySeam=%@",
        String(ownUserId.prefix(8)),
        privateKeyProvider == nil ? "ABSENT (fail-closed)" : "wired")
      return created
    }
  }

  /// The running core, without starting one.
  ///
  /// Ingest sites use this: the engine should feed a core that a surface has
  /// already brought up, never spin one up as a side effect of a network reply.
  static var runningCore: VibeCoreHandle? {
    queue.sync { handle }
  }

  /// Subscribes a surface to one chat's window and deltas.
  ///
  /// Callbacks arrive on the Rust worker thread. Observers hop themselves —
  /// hopping here would put a main-queue dispatch between the worker and every
  /// consumer, including ones that do not need it.
  static func addObserver(
    chatId: String,
    onWindow: @escaping (VibeFfiWindow) -> Void,
    onDelta: @escaping (VibeFfiDelta) -> Void
  ) {
    router.register(chatId: chatId, onWindow: onWindow, onDelta: onDelta)
  }

  static func removeObserver(chatId: String) {
    router.unregister(chatId: chatId)
  }

  /// Flushes and quiesces. Call from `didEnterBackground`.
  ///
  /// Deliberately **not** `willResignActive`: Control Centre and Notification
  /// Centre both fire that, and the engine already learned the hard way that
  /// treating it as backgrounding kills a live socket. The core follows the same
  /// signal the engine does.
  static func suspend() {
    queue.sync {
      guard let handle else { return }
      try? handle.suspend()
    }
  }

  /// Tears the worker down. Safe to call more than once.
  static func shutdown() {
    queue.sync {
      handle?.shutdown()
      handle = nil
    }
  }

  /// Drives one round trip through the FFI and reports what came back.
  ///
  /// This is the P2 acceptance check, and it is user-triggered from the
  /// diagnostics screen rather than run at launch: a "linked but dark" stage
  /// must not add work to the launch path it is not yet paying for.
  ///
  /// It proves, on the real device, that the static library linked, the worker
  /// thread spawned, a frame crossed into Rust, a delta came back across the
  /// callback boundary, and shutdown joined cleanly.
  static func runSelfTest(completion: @escaping (String) -> Void) {
    guard isEnabled else {
      completion("VibeCore bridge is OFF (set vibeCoreBridgeEnabled to test)")
      return
    }
    queue.async {
      let probe = VibeCoreProbeSink()
      let config = VibeFfiConfig(ownUserId: "self-test", flushFrameIntervalMs: 0)
      // No unwrapper: the probe frame is plaintext, and the self-test is checking
      // that the link, the worker and the callback boundary work — not crypto.
      let probeHandle = VibeCoreHandle(config: config, sink: probe, unwrapper: nil)

      let chatId = "self-test-chat"
      let frame = """
        {"id":"m1","chat_id":"\(chatId)","sender_id":"peer",\
        "timestamp":1000,"content":"hello from rust","type":"text"}
        """
      do {
        try probeHandle.ingestFrame(
          chatId: chatId,
          json: Data(frame.utf8),
          source: .chatTopic,
          receivedAtMs: 1000
        )
        try probeHandle.flush(nowMs: 2000)
      } catch {
        completion("FAIL submit: \(error)")
        probeHandle.shutdown()
        return
      }

      // The worker is asynchronous by design, so this waits rather than reads.
      let arrived = probe.waitForDelta(timeout: 3.0)
      let count = probe.deltaCount
      probeHandle.shutdown()

      let timeline =
        arrived
        ? "PASS — core v\(VibeCoreBridge.coreVersion), \(count) delta(s), worker joined"
        : "FAIL — no delta within 3s"
      let verdict = [
        timeline,
        VibeCoreBridge.sealSelfTestVerdict(),
        VibeCoreBridge.secureSelfTestVerdict(),
      ].joined(separator: "\n")
      VibeLog.info("[VibeCore] self-test \(verdict)")
      completion(verdict)
    }
  }

  static var coreVersion: String { "0.1.0" }

  /// Builds a sealer over the per-install Keychain store key.
  ///
  /// Returns `nil` when the Keychain refuses to hold a key. A device that cannot
  /// custody a key must keep using the legacy plaintext path — sealing under
  /// anything predictable would be worse than not sealing, because the column is
  /// named `sealed_body` and every reader downstream would trust it.
  ///
  /// `ChatMessageStore` calls this once at open and seals every message body it
  /// writes. A `nil` here is the documented plaintext fallback, not a silent one:
  /// the store logs it and `ChatMessageStore.sealSummary` reports it.
  static func makeSealer() -> VibeStoreSealerHandle? {
    guard let key = VibeCoreStoreKey.loadOrCreate() else {
      VibeLog.error("[VibeCore] no store key available — sealing unavailable")
      return nil
    }
    do {
      return try VibeStoreSealerHandle(storeKey: key)
    } catch {
      VibeLog.error("[VibeCore] sealer construction failed: \(error)")
      return nil
    }
  }

  /// Seals and reopens one row, and proves a relocated row is refused.
  ///
  /// The relocation check is the part worth running on a real device: it is the
  /// difference between "the bytes are encrypted" and "the bytes are bound to
  /// the row they belong to", and it is the property that stops a tampered or
  /// mis-restored database from rendering one chat's message inside another.
  static func sealSelfTestVerdict() -> String {
    guard let sealer = makeSealer() else { return "seal: NO KEY" }
    let probe = Data("store seal probe".utf8)
    do {
      let sealed = try sealer.seal(
        userId: "u-selftest", chatId: "c-selftest", messageId: "m-selftest", plaintext: probe)
      let opened = try sealer.open(
        userId: "u-selftest", chatId: "c-selftest", messageId: "m-selftest",
        sealedBody: sealed.sealedBody, sealNonce: sealed.sealNonce)
      guard opened == probe else { return "seal: ROUND-TRIP MISMATCH" }

      // Same bytes, different address. This must fail.
      let relocated = try? sealer.open(
        userId: "u-selftest", chatId: "c-selftest", messageId: "m-OTHER",
        sealedBody: sealed.sealedBody, sealNonce: sealed.sealNonce)
      guard relocated == nil else { return "seal: RELOCATION NOT REFUSED" }

      return "seal: PASS (round-trip + relocation refused)"
    } catch {
      return "seal: FAIL \(error)"
    }
  }

  /// Drives a real two-member MLS group end to end, in the DM shape.
  ///
  /// This is the linkage proof for `vibe_secure`: identity generation,
  /// KeyPackage publication, an add commit, a join from the Welcome, and a
  /// seal/open across two separate identities — all through the FFI, on device.
  /// A `PASS` here means the whole Rust→uniffi→Swift chain is live.
  ///
  /// Both identities are built against **throwaway stores in a temp directory**,
  /// never the app's real one at `VibeSecureSessions.storePath()`. A self-test
  /// that wrote into the live store would add two fake device identities and a
  /// junk group to the state that real conversations depend on.
  static func secureSelfTestVerdict() -> String {
    do {
      let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("vibe-secure-selftest-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: scratch) }

      let alice = try VibeSecureIdentityHandle.generate(
        deviceId: "alice-selftest",
        dbPath: scratch.appendingPathComponent("alice.sqlite").path)
      let bob = try VibeSecureIdentityHandle.generate(
        deviceId: "bob-selftest",
        dbPath: scratch.appendingPathComponent("bob.sqlite").path)

      // Alice opens the group and adds Bob from his published KeyPackage. The
      // committer adopts the new epoch inside `addMembers`, so she can seal
      // immediately afterwards.
      let aliceSession = try VibeSecureSessionHandle.create(identity: alice)
      let commit = try aliceSession.addMembers(keyPackages: [bob.keyPackage()])
      let bobSession = try VibeSecureSessionHandle.joinFromWelcome(
        identity: bob,
        welcome: commit.welcome,
        ratchetTree: aliceSession.exportRatchetTree()
      )

      let probe = Data("mls probe".utf8)
      let sealed = try aliceSession.seal(plaintext: probe)
      guard sealed.hasPrefix("vmls1.") else { return "mls: WRONG ENVELOPE PREFIX" }
      guard try bobSession.open(envelope: sealed) == probe else {
        return "mls: ROUND-TRIP MISMATCH"
      }

      // A tampered envelope must be refused, not decrypted and not crashed on.
      // This is the case that used to panic before `vibe_secure` grew its panic
      // guard, so it is worth running on a real device rather than trusting the
      // host test suite.
      var tampered = Array(sealed.utf8)
      tampered[tampered.count - 2] = tampered[tampered.count - 2] == UInt8(ascii: "A")
        ? UInt8(ascii: "B") : UInt8(ascii: "A")
      let tamperedEnvelope = String(decoding: tampered, as: UTF8.self)
      if (try? bobSession.open(envelope: tamperedEnvelope)) != nil {
        return "mls: TAMPERED ENVELOPE NOT REFUSED"
      }

      return "mls: PASS (2-member seal/open + tamper refused)"
    } catch {
      return "mls: FAIL \(error)"
    }
  }
}

/// Fans core callbacks out to the surface showing that chat.
///
/// One core serves every chat, so its single sink has to demultiplex. Routing by
/// `chatId` is what lets the reducer stay shared while each surface only ever
/// sees its own conversation.
///
/// Every callback arrives on the core's worker thread, never the main thread.
/// Observers hop themselves before touching UIKit — the worker is single-threaded
/// and a slow observer is backpressure on every other chat.
private final class VibeCoreRouter: VibeDeltaSink {
  private let lock = NSLock()
  private var windowObservers: [String: (VibeFfiWindow) -> Void] = [:]
  private var deltaObservers: [String: (VibeFfiDelta) -> Void] = [:]

  func register(
    chatId: String,
    onWindow: @escaping (VibeFfiWindow) -> Void,
    onDelta: @escaping (VibeFfiDelta) -> Void
  ) {
    lock.lock()
    windowObservers[chatId] = onWindow
    deltaObservers[chatId] = onDelta
    lock.unlock()
  }

  func unregister(chatId: String) {
    lock.lock()
    windowObservers.removeValue(forKey: chatId)
    deltaObservers.removeValue(forKey: chatId)
    lock.unlock()
  }

  func onDelta(delta: VibeFfiDelta) {
    lock.lock()
    let observer = deltaObservers[delta.chatId]
    lock.unlock()
    // No observer is normal: the core keeps reducing chats nobody is looking at,
    // which is exactly what makes reopening one instant.
    observer?(delta)
  }

  func onWindow(window: VibeFfiWindow) {
    lock.lock()
    let observer = windowObservers[window.chatId]
    lock.unlock()
    observer?(window)
  }

  func onError(message: String) {
    // Never fatal on its own. A non-zero rate here is the signal to keep the
    // rollout flag off for that chat class.
    VibeLog.error("[VibeCore] error \(message)")
  }
}

/// Sink used only by ``VibeCoreBridge/runSelfTest(completion:)``.
private final class VibeCoreProbeSink: VibeDeltaSink {
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var count = 0

  var deltaCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func waitForDelta(timeout: TimeInterval) -> Bool {
    semaphore.wait(timeout: .now() + timeout) == .success
  }

  func onDelta(delta: VibeFfiDelta) {
    lock.lock()
    count += 1
    lock.unlock()
    semaphore.signal()
  }

  func onWindow(window: VibeFfiWindow) {}
  func onError(message: String) {
    VibeLog.error("[VibeCore] self-test error \(message)")
  }
}
