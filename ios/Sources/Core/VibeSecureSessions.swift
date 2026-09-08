import Foundation
import Security

/// MLS session custody for the chat engine: one device identity, one session per
/// chat, and the two entry points the send/receive path calls.
///
/// # State is persistent
///
/// Ratchet state lives in a SQLite store on disk (`VibeSecureProvider`), and
/// `chat id -> group id` is remembered so a relaunch reloads the *same* group
/// rather than minting a new one and orphaning everything sealed before the
/// restart. That reload happens lazily in `sessionLocked(chatId:)`, which is why
/// nothing else in this type reads the `sessions` dictionary directly.
///
/// # The send gate
///
/// A `vmls1.` envelope is unreadable to a client that has not shipped this code,
/// so sending was gated while an install base might exist. **Receiving is always
/// on** — it costs nothing when no `vmls1.` arrives, and read-before-write is
/// the state a staged rollout needs every device to pass through first.
///
/// # Establishment lives next door
///
/// Sessions are created and joined by `VibeSecureEstablishment`, which is the
/// only part of MLS that needs the network. This type stays purely local and
/// synchronous so that custody of the ratchet is auditable on its own.
///
/// # Callers must fail closed
///
/// `seal` returning `nil` means *this chat has no session*, and the only safe
/// response is to keep the message queued — never to fall through to the
/// plaintext branch. `ChatEngine` does that by reusing the queue-and-replay
/// path it already had for a missing friend key. A caller that treats `nil` as
/// "send it some other way" silently un-encrypts the conversation, which is the
/// one failure mode this whole layer exists to prevent.
///
/// Groups are not established yet, so `seal` still returns `nil` for them and
/// they continue on their existing path. That is a known gap, tracked in
/// docs/secure-core-architecture.md §4 — not a property of this type.
import CryptoKit

final class VibeSecureSessions {

  static let shared = VibeSecureSessions()

  /// Optional kill switch for experimental group MLS sends; human DMs ignore it.
  static var isGroupSendEnabled: Bool {
    guard UserDefaults.standard.object(forKey: "vibe.mls.sendEnabled") != nil else { return true }
    return UserDefaults.standard.bool(forKey: "vibe.mls.sendEnabled")
  }

  /// Chats whose peer has confirmed it applied our Welcome.
  ///
  /// # Why sealing is gated on this and not just on "a session exists"
  ///
  /// MLS gives a sender **no feedback whatsoever**. `create_message` succeeds
  /// whether or not the other side ever joined, and — because a sender cannot
  /// decrypt its own message — a device can seal, store and display an entire
  /// conversation that nobody alive can open. Nothing in the protocol notices,
  /// and nothing in the UI does either: the messages look sent, they ack, they
  /// get delivery ticks.
  ///
  /// That is not hypothetical. On 2026-08-06 sealing was switched on before
  /// establishment had been confirmed end-to-end and every DM went blank on both
  /// sides simultaneously. The server knows the answer — it records `delivered_at`
  /// when the recipient acks the Welcome — the sender simply had no way to ask.
  /// Now it asks, and until the answer is yes it uses the path that already
  /// works.
  ///
  /// Persisted rather than in-memory: confirmation is a fact about the peer's
  /// device, not about this process, and re-deriving it on every launch would
  /// mean a relaunch silently drops back to the older envelope.
  private static let peerConfirmedKey = "vibe.mls.peerConfirmed"

  /// True when the peer for `chatId` has applied our Welcome and can therefore
  /// read what we seal.
  func isPeerConfirmed(chatId: String) -> Bool {
    let confirmed =
      UserDefaults.standard.array(forKey: Self.peerConfirmedKey) as? [String] ?? []
    return confirmed.contains(chatId)
  }

  /// Records that the peer for `chatId` confirmed the join.
  ///
  /// One-way on purpose. A peer that joined stays joined; a transient failure to
  /// reach the status endpoint must not revoke a conversation's encryption,
  /// because that would silently downgrade an established chat back to the older
  /// envelope on a bad network.
  func markPeerConfirmed(chatId: String) {
    queue.sync {
      var confirmed =
        UserDefaults.standard.array(forKey: Self.peerConfirmedKey) as? [String] ?? []
      guard !confirmed.contains(chatId) else { return }
      confirmed.append(chatId)
      UserDefaults.standard.set(confirmed, forKey: Self.peerConfirmedKey)
      VibeLog.notice("[VibeSecure] peer confirmed for \(chatId) — sealing with MLS from now on")
    }
  }

  private let queue = DispatchQueue(label: "vibe.secure.sessions")
  private var identityCache: VibeSecureIdentityHandle?
  private var sessions: [String: VibeSecureSessionHandle] = [:]

  private init() {}

  /// Where this device's **public** signature key is remembered between
  /// launches, so the private half can be found again in the MLS store.
  ///
  /// `UserDefaults` for the same reason group ids are: this is an address, not
  /// a secret. It is the public half of a keypair whose private half never
  /// leaves the Rust store, and peers are handed this exact value inside every
  /// KeyPackage we publish.
  private static let signaturePublicKeyKey = "vibe.mls.identityPublicKey"

  /// Set when this device's signing key changed, so the next network pass
  /// retires the server-side artifacts that still name the old one.
  private static let identityResetPendingKey = "vibe.mls.identityResetPending"

  /// This device's MLS identity, resolved once per process.
  ///
  /// The device id is Keychain-backed and stable across launches, because it is
  /// carried in the MLS credential and is what a safety-number UI will hash. A
  /// per-launch UUID would make this device look like a different party to every
  /// peer on every launch.
  ///
  /// **A stable device id was never enough**, and this shipped without the rest
  /// of it: the old code called `generate`, which mints a fresh signing key
  /// every time, so every cold launch gave this device a new key while keeping
  /// every group it was in. MLS verifies an application message against the
  /// signing key recorded in the sender's leaf node, so from that launch on the
  /// peer could not open a single message — and neither side could tell, because
  /// sealing still succeeded and the group still loaded. Two devices, one group
  /// id, both healthy-looking, neither readable. `load_or_generate` resolves the
  /// key already in the store instead; `core/vibe_secure/tests/identity_persistence.rs`
  /// pins both the failure and the fix.
  ///
  /// The handle is constructed against the on-disk store at `storePath()`, so
  /// key material and group state outlive the process.
  private func identityHandleLocked() -> VibeSecureIdentityHandle? {
    if let identityCache = identityCache { return identityCache }
    guard let deviceId = VibeSecureDeviceId.loadOrCreate() else {
      VibeLog.error("[VibeSecure] no stable device id — MLS unavailable")
      return nil
    }
    guard let dbPath = Self.storePath() else {
      VibeLog.error("[VibeSecure] no store path — MLS unavailable")
      return nil
    }
    let remembered = UserDefaults.standard.data(forKey: Self.signaturePublicKeyKey)
    do {
      let handle = try VibeSecureIdentityHandle.loadOrGenerate(
        deviceId: deviceId, dbPath: dbPath, signaturePublicKey: remembered)
      let current = handle.signatureKey()

      // Written on every construction, not only the first. A restore from
      // backup brings this default back while the backup-excluded MLS store
      // stays gone, so the remembered key stops resolving and Rust mints a new
      // one — and if the stale value survived, the next launch would repeat it
      // forever.
      if current != remembered {
        retireStateForNewIdentityLocked(hadRememberedKey: remembered != nil)
        UserDefaults.standard.set(current, forKey: Self.signaturePublicKeyKey)
      }

      identityCache = handle
      return handle
    } catch {
      VibeLog.error("[VibeSecure] identity load failed: \(error)")
      return nil
    }
  }

  /// Drops everything that is only meaningful under the *previous* signing key.
  ///
  /// A new signing key does not damage the groups on disk — it orphans them.
  /// Every peer's copy of our leaf still names the key we no longer hold, so
  /// those groups can never carry a readable message again in either direction.
  /// Keeping them is strictly worse than dropping them: `hasSession` would keep
  /// answering yes, so establishment would keep short-circuiting and the chat
  /// would stay silently broken forever. Discarding them makes every chat look
  /// unestablished, which is the one state the rest of this file knows how to
  /// recover from.
  ///
  /// **Peer pins go too, and that is the uncomfortable part.** Peers were
  /// regenerating their keys on every launch as well, so every pin we hold names
  /// a key its owner will never sign with again — and `verifyPeer` fails closed
  /// on a changed key, which would make every existing conversation permanently
  /// unable to re-establish. There is no safety-number screen yet for a human to
  /// accept the change through, so clearing the pins is the only route back. It
  /// costs exactly one re-pin per peer: the first-contact substitution window
  /// reopens once, and closes again on the next claim.
  ///
  /// **Retained plaintext is deliberately kept.** It is our own sent text, not
  /// key material, and it is the only source for rendering our own MLS history —
  /// dropping it would blank those rows for no security gain.
  ///
  /// Must not touch `queue`: every caller is already inside it.
  private func retireStateForNewIdentityLocked(hadRememberedKey: Bool) {
    let defaults = UserDefaults.standard
    let groupKeys = defaults.dictionaryRepresentation().keys.filter {
      $0.hasPrefix("vibe.mls.group.") || $0.hasPrefix("vibe.mls.groupSince.")
        || $0.hasPrefix("vibe.mls.peerKeysMissing.")
    }
    for key in groupKeys { defaults.removeObject(forKey: key) }
    defaults.removeObject(forKey: Self.peerConfirmedKey)
    sessions.removeAll()

    // `vibe.mls.ineligible.*` survives on purpose: it records that a chat has
    // more members than MLS is wired for here, which is a fact about the chat,
    // not about this device's key.

    VibeSecureTrust.clearAllPins()

    let orphanedGroups = groupKeys.filter { $0.hasPrefix("vibe.mls.group.") }.count
    let hadPriorState = hadRememberedKey || orphanedGroups > 0
    if hadPriorState {
      // The server still holds KeyPackages signed by the dead key, and
      // `claim` hands out the oldest first — so a peer would claim one, build a
      // group around a leaf we can no longer sign as, and reproduce this bug
      // exactly. Pending Welcomes are the same trap from the other side.
      // `VibeSecureEstablishment` clears both on the next network pass.
      defaults.set(true, forKey: Self.identityResetPendingKey)
      VibeLog.notice(
        "[VibeSecure] device signing key changed — discarded \(orphanedGroups) orphaned"
          + " group(s) and every peer pin; chats will re-establish from scratch")
    }
  }

  /// Resolves this device's identity if it has not been resolved yet.
  ///
  /// **Every reader of `identityResetPending` must call this first.** Resolving
  /// the identity is what *sets* that flag — the two are the same act — so a
  /// caller that reads the flag on a launch where nothing has touched MLS yet
  /// reads `false` from a device whose key is about to change. That is not a
  /// missed opportunity: it means the KeyPackage pool looks healthy while every
  /// entry in it names the dead key, and the Welcome drain adopts a Welcome
  /// built on one. Both of those are the original bug, rebuilt.
  ///
  /// Deliberately not folded into the flag's getter: that would hide a SQLite
  /// open and a possible state wipe inside a property read.
  func ensureIdentityResolved() {
    queue.sync { _ = identityHandleLocked() }
  }

  /// Whether server-side artifacts naming a retired signing key still need
  /// clearing. Cleared by `VibeSecureEstablishment` once they are.
  ///
  /// Only meaningful after `ensureIdentityResolved()` — see its doc.
  static var identityResetPending: Bool {
    get { UserDefaults.standard.bool(forKey: identityResetPendingKey) }
    set { UserDefaults.standard.set(newValue, forKey: identityResetPendingKey) }
  }

  /// Where the MLS ratchet state lives.
  ///
  /// Application Support rather than Caches: the OS may evict Caches under
  /// pressure, and losing this file means losing the ability to read every
  /// message in every established conversation. Excluded from backups for the
  /// same reason the store key is `ThisDeviceOnly` — a restored backup carrying
  /// stale ratchet state is worse than one that re-establishes cleanly.
  private static func storePath() -> String? {
    guard
      let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first
    else { return nil }
    var dir = base.appendingPathComponent("VibeSecure", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      var resourceValues = URLResourceValues()
      resourceValues.isExcludedFromBackup = true
      try? dir.setResourceValues(resourceValues)
    } catch {
      VibeLog.error("[VibeSecure] store directory unavailable: \(error)")
      return nil
    }
    return dir.appendingPathComponent("mls-state.sqlite").path
  }

  /// `chat id -> MLS group id`, so a relaunch can reload the right group.
  ///
  /// Group ids are not secret — they are the address of a group, not a key — so
  /// `UserDefaults` is the right weight here. The secrets are all in the SQLite
  /// store, which the OS sandboxes, and the device identity is in the Keychain.
  private static func storedGroupId(chatId: String) -> Data? {
    UserDefaults.standard.data(forKey: "vibe.mls.group.\(chatId)")
  }

  private static func storeGroupId(_ groupId: Data, chatId: String) {
    UserDefaults.standard.set(groupId, forKey: "vibe.mls.group.\(chatId)")
    UserDefaults.standard.set(
      Date().timeIntervalSince1970, forKey: "vibe.mls.groupSince.\(chatId)")
  }

  /// How long this chat has held its current group, or `nil` if it holds none.
  ///
  /// Exists so a repair path can tell "the server has no Welcome for this group"
  /// from "the Welcome is still in flight". Both look identical in a
  /// welcome-status answer, and acting on the second would discard a group that
  /// was about to work — see `VibeSecureEstablishment.refreshPeerConfirmation`.
  func groupAge(chatId: String) -> TimeInterval? {
    queue.sync {
      guard Self.storedGroupId(chatId: chatId) != nil else { return nil }
      let since = UserDefaults.standard.double(forKey: "vibe.mls.groupSince.\(chatId)")
      // A group stored before this timestamp existed reads as 0. Treating that
      // as "brand new" would make it permanently unrepairable, so it reads as
      // old instead: those are exactly the groups that predate the fix.
      guard since > 0 else { return .greatestFiniteMagnitude }
      return Date().timeIntervalSince1970 - since
    }
  }

  /// Returns the session for `chatId`, reloading it from disk on first use
  /// after a relaunch.
  ///
  /// Without this the in-memory registry would be empty at launch and every
  /// chat would look unestablished, so the app would mint a brand-new group and
  /// orphan every message sealed before the restart.
  private func sessionLocked(chatId: String) -> VibeSecureSessionHandle? {
    if let live = sessions[chatId] { return live }
    // Identity first, group id second, and the order is load-bearing. Resolving
    // the identity is what discovers a changed signing key and wipes the
    // group mappings it orphaned — reading the id first would capture the
    // pre-wipe value and reload the very group the wipe just condemned, which
    // is the whole bug wearing a different hat.
    guard
      let identity = identityHandleLocked(),
      let groupId = Self.storedGroupId(chatId: chatId)
    else { return nil }
    do {
      guard let restored = try identity.loadSession(groupId: groupId)
      else {
        VibeLog.info("[VibeSecure] no persisted group for \(chatId)")
        return nil
      }
      sessions[chatId] = restored
      return restored
    } catch {
      VibeLog.error("[VibeSecure] session reload failed for \(chatId): \(error)")
      return nil
    }
  }

  /// A fresh KeyPackage to publish so peers can add this device to a group.
  ///
  /// Each one is single-use: MLS consumes a KeyPackage's one-time init key when
  /// it adds a member, so the same package must never be handed out twice.
  func freshKeyPackage() -> Data? {
    queue.sync {
      guard let identity = identityHandleLocked() else { return nil }
      do {
        return try identity.keyPackage()
      } catch {
        VibeLog.error("[VibeSecure] key package failed: \(error)")
        return nil
      }
    }
  }

  /// Validates a peer's KeyPackage and reads the identity it claims.
  ///
  /// `nil` means the bytes did not survive validation — malformed, wrong
  /// ciphersuite, bad signature. A non-nil result is *not* proof the key
  /// belongs to the person you asked for; that is what `VibeSecureTrust` is
  /// for.
  func inspectKeyPackage(_ keyPackage: Data) -> VibeFfiKeyPackageIdentity? {
    queue.sync {
      guard let identity = identityHandleLocked() else { return nil }
      do {
        return try identity.inspectKeyPackage(keyPackage: keyPackage)
      } catch {
        VibeLog.error("[VibeSecure] key package inspect failed: \(error)")
        return nil
      }
    }
  }

  /// This device's public signature key — our half of any safety number.
  func mySignatureKey() -> Data? {
    queue.sync {
      guard let identity = identityHandleLocked() else { return nil }
      return try? identity.signatureKey()
    }
  }

  /// The safety number to compare with `peerUserId`, or `nil` before either
  /// side's key is known.
  func safetyNumber(peerUserId: String) -> String? {
    guard
      let mine = mySignatureKey(),
      let theirs = VibeSecureTrust.pinnedKey(userId: peerUserId)
    else { return nil }
    return VibeSecureTrust.safetyNumber(myKey: mine, peerKey: theirs)
  }

  /// Pins the peer identity carried by this chat's own MLS group.
  ///
  /// A joiner never claims a KeyPackage, so `verifyPeer` never runs there and it
  /// would otherwise hold no pin at all — no pin, no safety number.
  @discardableResult
  func ensurePeerPinned(chatId: String, peerUserId: String) -> Bool {
    guard !peerUserId.isEmpty else { return false }
    let keys: [Data] = queue.sync {
      guard let session = sessionLocked(chatId: chatId) else { return [] }
      return (try? session.peerSignatureKeys()) ?? []
    }
    // One peer is the only case where the key maps to `peerUserId` without
    // guessing; an MLS credential carries a device id, not a user id.
    guard keys.count == 1, let peerKey = keys.first, !peerKey.isEmpty else { return false }
    switch VibeSecureTrust.evaluate(signatureKey: peerKey, userId: peerUserId) {
    case .pinnedOnFirstContact:
      VibeLog.info("[VibeSecure] pinned \(peerUserId) from the group tree for \(chatId)")
      return true
    case .matchesPin:
      return true
    case .changed:
      VibeLog.error(
        "[VibeSecure] group identity for \(peerUserId) differs from the pin — awaiting verification")
      return false
    }
  }

  /// Registers a session established elsewhere (group creation or a Welcome).
  func register(session: VibeSecureSessionHandle, chatId: String) {
    queue.sync { sessions[chatId] = session }
  }

  func hasSession(chatId: String) -> Bool {
    queue.sync { sessionLocked(chatId: chatId) != nil }
  }

  /// The MLS group id currently bound to `chatId`, if any.
  ///
  /// Exposed for the first-contact tie-break in `VibeSecureEstablishment`,
  /// which needs to compare our group against an incoming Welcome's without
  /// touching the ratchet.
  func groupId(chatId: String) -> Data? {
    queue.sync {
      guard sessionLocked(chatId: chatId) != nil else { return nil }
      return Self.storedGroupId(chatId: chatId)
    }
  }

  /// Whether this chat has been determined unable to use MLS.
  ///
  /// Today this means exactly one thing: it has more members than
  /// `VibeSecureEstablishment.maxGroupMembers`. Broadcast channels are
  /// indistinguishable from groups at this layer — iOS folds `isChannel` into
  /// `isGroup` before the engine sees it — so the member count is the only
  /// signal available, and without it a channel would queue every message
  /// forever waiting on an establishment that cannot succeed.
  ///
  /// **These chats are not end-to-end encrypted and do not fail closed.** They
  /// keep their existing behaviour, which for a group means plaintext to the
  /// server. That is a deliberate, documented gap — see
  /// docs/secure-core-architecture.md §4 — not an accident.
  ///
  /// Persisted so a relaunch does not re-probe a chat that will never qualify.
  func isIneligible(chatId: String) -> Bool {
    UserDefaults.standard.bool(forKey: "vibe.mls.ineligible.\(chatId)")
  }

  func markIneligible(chatId: String) {
    UserDefaults.standard.set(true, forKey: "vibe.mls.ineligible.\(chatId)")
  }

  // A recent missing-KeyPackage response only rate-limits readiness probes.
  // It never authorizes a different transport.
  private static func peerKeysMissingKey(_ chatId: String) -> String {
    "vibe.mls.peerKeysMissing.\(chatId)"
  }

  /// How long a "no KeyPackage" answer is trusted before we probe again.
  ///
  /// Bounded so a peer who installs the app is not stuck on the older envelope
  /// indefinitely. Chat-open re-establishment usually notices much sooner;
  /// this is the backstop for a chat nobody reopens.
  private static let peerKeysMissingTtl: TimeInterval = 6 * 60 * 60

  /// Records that `chatId` cannot be established because a member has no
  /// published KeyPackage.
  func markPeerKeysUnavailable(chatId: String) {
    UserDefaults.standard.set(
      Date().timeIntervalSince1970, forKey: Self.peerKeysMissingKey(chatId))
  }

  /// True while a recent attempt found a member with no published KeyPackage.
  func peerKeysUnavailable(chatId: String) -> Bool {
    let stamp = UserDefaults.standard.double(forKey: Self.peerKeysMissingKey(chatId))
    guard stamp > 0 else { return false }
    return Date().timeIntervalSince1970 - stamp < Self.peerKeysMissingTtl
  }

  /// Clears the mark once establishment succeeds.
  func clearPeerKeysUnavailable(chatId: String) {
    UserDefaults.standard.removeObject(forKey: Self.peerKeysMissingKey(chatId))
  }

  /// Forgets the session bound to `chatId`.
  ///
  /// Used when an establishment attempt cannot be completed — the peer never
  /// received its Welcome, or we lost the first-contact tie-break — so the
  /// chat looks unestablished again and the next attempt starts clean. Leaving
  /// a half-established group in place is worse than dropping it: `hasSession`
  /// would report a session nobody else can read, and the send path trusts
  /// that answer.
  ///
  /// The group's state is left in the SQLite store rather than deleted. It is
  /// unreachable once the `chat id -> group id` mapping is gone, so this leaks
  /// a small amount of dead state per abandoned attempt; deleting it means
  /// reaching into OpenMLS's storage keyspace, which is a worse trade than
  /// leaking a few kilobytes in a rare path.
  func discard(chatId: String) {
    queue.sync {
      sessions.removeValue(forKey: chatId)
      UserDefaults.standard.removeObject(forKey: "vibe.mls.group.\(chatId)")
      UserDefaults.standard.removeObject(forKey: "vibe.mls.groupSince.\(chatId)")
    }
  }

  /// Creates a new group for `chatId` with this device as its only member.
  func createSession(chatId: String) -> VibeSecureSessionHandle? {
    queue.sync {
      guard let identity = identityHandleLocked() else { return nil }
      do {
        let session = try VibeSecureSessionHandle.create(identity: identity)
        sessions[chatId] = session
        // Persist the address immediately: a crash between here and the first
        // send would otherwise strand a real group on disk that nothing can
        // ever look up again.
        Self.storeGroupId(try session.groupId(), chatId: chatId)
        return session
      } catch {
        VibeLog.error("[VibeSecure] session create failed for \(chatId): \(error)")
        return nil
      }
    }
  }

  /// Joins `chatId`'s group from a Welcome produced by another member.
  func joinSession(chatId: String, welcome: Data, ratchetTree: Data?) -> VibeSecureSessionHandle? {
    let session: VibeSecureSessionHandle? = queue.sync {
      guard let identity = identityHandleLocked() else { return nil }
      do {
        let session = try VibeSecureSessionHandle.joinFromWelcome(
          identity: identity, welcome: welcome, ratchetTree: ratchetTree)
        sessions[chatId] = session
        Self.storeGroupId(try session.groupId(), chatId: chatId)
        return session
      } catch {
        VibeLog.error("[VibeSecure] session join failed for \(chatId): \(error)")
        return nil
      }
    }
    // A joiner never posts a Welcome, so sender-only welcome-status stays 0/0.
    // Confirm here or refreshPeerConfirmation will discard this group as an orphan.
    if session != nil {
      markPeerConfirmed(chatId: chatId)
    }
    return session
  }

  // ── Own-message plaintext ───────────────────────────────────────────────
  //
  // A sender cannot decrypt its own MLS message. `create_message` encrypts to
  // the group's *other* members and OpenMLS refuses to process a message the
  // caller authored — pinned by
  // `a_sender_cannot_open_its_own_message_so_platforms_must_keep_the_plaintext`.
  //
  // The old hybrid envelope hid this: it was dual-wrapped, so the sender could
  // open its own. MLS is not, so when the server echoes a sent message back and
  // the engine re-parses `encryptedContent`, `open` fails and the row renders
  // empty. That is not corruption — the peer reads it fine — it is the sender
  // asking a question that has no answer.
  //
  // So the plaintext is kept here at seal time. Persisted, because the echo can
  // arrive after a relaunch and because scrolling back through your own history
  // must not go blank.

  /// How many of our own messages keep a retained plaintext.
  ///
  /// Bounded because this grows with every message sent and never shrinks on
  /// its own. Beyond the bound the oldest entries drop and those rows fall back
  /// to the locally cached history row, which already carries the text — the
  /// bound costs fidelity in a rare path, not correctness.
  private static let ownPlaintextLimit = 5000

  private static let ownPlaintextKey = "vibe.mls.ownPlaintext"
  private static let ownPlaintextOrderKey = "vibe.mls.ownPlaintext.order"

  /// Retains our own plaintext for `messageId`, and for the envelope if we have it.
  func rememberOwnPlaintext(_ plaintext: String, messageId: String, envelope: String? = nil) {
    queue.sync { retainPlaintextLocked(plaintext, messageId: messageId, envelope: envelope) }
  }

  /// Retains one opened plaintext. Must not touch `queue`: callers hold it.
  private func retainPlaintextLocked(_ plaintext: String, messageId: String?, envelope: String?) {
    var blob = retentionLocked()
    var changed = false
    let primary = messageId ?? envelope.map(Self.envelopePlaintextKey) ?? ""
    guard !primary.isEmpty else { return }
    if blob.store[primary] == nil { blob.order.append(primary) }
    if blob.store[primary] != plaintext {
      blob.store[primary] = plaintext
      changed = true
    }
    if let envelope, messageId != nil {
      let aliasKey = Self.envelopePlaintextKey(envelope)
      if blob.alias[aliasKey] != primary {
        blob.alias[aliasKey] = primary
        changed = true
      }
    }
    while blob.order.count > Self.ownPlaintextLimit {
      let evicted = blob.order.removeFirst()
      blob.store.removeValue(forKey: evicted)
      changed = true
    }
    if let messageId, blob.unrecoverable.remove(messageId) != nil { changed = true }
    if changed { persistRetentionLocked(blob) }
  }

  // ── Sealed retention file ──────────────────────────────────────────────
  // Plaintext used to sit in UserDefaults: unsealed, backed up, rewritten per open.
  // Now one AES-GCM blob under the store key, never backed up, cached in memory.

  private struct RetentionBlob: Codable {
    var store: [String: String] = [:]
    var alias: [String: String] = [:]
    var order: [String] = []
    var unrecoverable: Set<String> = []
  }

  private var retentionCache: RetentionBlob?
  private var retentionKeyCache: SymmetricKey?
  private var loggedTombstones = Set<String>()
  private static let unrecoverableLimit = 4000

  private static var retentionFileURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("vibe-secure", isDirectory: true)
      .appendingPathComponent("retained.v1")
  }

  private func retentionKeyLocked() -> SymmetricKey? {
    if let cached = retentionKeyCache { return cached }
    guard let data = VibeCoreStoreKey.loadOrCreate() else { return nil }
    let key = SymmetricKey(data: data)
    retentionKeyCache = key
    return key
  }

  /// Loads the blob once per process; the first run also adopts the legacy UserDefaults entries.
  private func retentionLocked() -> RetentionBlob {
    if let cached = retentionCache { return cached }
    var blob = RetentionBlob()
    if let key = retentionKeyLocked(),
      let sealed = try? Data(contentsOf: Self.retentionFileURL),
      let box = try? AES.GCM.SealedBox(combined: sealed),
      let plain = try? AES.GCM.open(box, using: key),
      let decoded = try? JSONDecoder().decode(RetentionBlob.self, from: plain)
    {
      blob = decoded
    }
    let defaults = UserDefaults.standard
    if let legacy = defaults.dictionary(forKey: Self.ownPlaintextKey) as? [String: String] {
      let legacyOrder = defaults.stringArray(forKey: Self.ownPlaintextOrderKey) ?? Array(legacy.keys)
      for key in legacyOrder where blob.store[key] == nil {
        guard let text = legacy[key] else { continue }
        blob.store[key] = text
        blob.order.append(key)
      }
      if persistRetentionLocked(blob) {
        defaults.removeObject(forKey: Self.ownPlaintextKey)
        defaults.removeObject(forKey: Self.ownPlaintextOrderKey)
        VibeLog.notice(
          "mls retention migrated off UserDefaults", category: "crypto",
          metadata: ["entries": String(blob.store.count)])
      }
      return blob
    }
    retentionCache = blob
    return blob
  }

  @discardableResult
  private func persistRetentionLocked(_ blob: RetentionBlob) -> Bool {
    retentionCache = blob
    guard let key = retentionKeyLocked(), let plain = try? JSONEncoder().encode(blob),
      let sealed = try? AES.GCM.seal(plain, using: key).combined
    else {
      VibeLog.error("mls retention seal failed", category: "crypto")
      return false
    }
    let url = Self.retentionFileURL
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try sealed.write(
        to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      var marked = url
      try? marked.setResourceValues(values)
      return true
    } catch {
      VibeLog.error(
        "mls retention write failed", category: "crypto",
        metadata: ["err": String("\(error)".prefix(80))])
      return false
    }
  }

  private func isUnrecoverableLocked(messageId: String?) -> Bool {
    guard let messageId else { return false }
    return retentionLocked().unrecoverable.contains(messageId)
  }

  private func markUnrecoverableLocked(messageId: String?) {
    guard let messageId else { return }
    var blob = retentionLocked()
    guard blob.unrecoverable.insert(messageId).inserted else { return }
    if blob.unrecoverable.count > Self.unrecoverableLimit {
      blob.unrecoverable.remove(blob.unrecoverable.first!)
    }
    persistRetentionLocked(blob)
  }

  /// True when this device can never open the row; the engine renders a tombstone instead of retrying.
  func isUnrecoverable(messageId: String) -> Bool {
    queue.sync { isUnrecoverableLocked(messageId: messageId) }
  }

  /// Drops every retained trace of one message. Retention must not outlive the row it
  /// belongs to, so deletes and consumed view-once messages call this.
  func forget(messageId: String) {
    guard !messageId.isEmpty else { return }
    queue.sync {
      var blob = retentionLocked()
      var changed = blob.store.removeValue(forKey: messageId) != nil
      if let index = blob.order.firstIndex(of: messageId) {
        blob.order.remove(at: index)
        changed = true
      }
      for (alias, primary) in blob.alias where primary == messageId {
        blob.alias.removeValue(forKey: alias)
        changed = true
      }
      if blob.unrecoverable.remove(messageId) != nil { changed = true }
      if changed { persistRetentionLocked(blob) }
    }
  }

  /// Bulk form of `forget(messageId:)` — one seal + write for a whole delete batch.
  func forget(messageIds: [String]) {
    let ids = Set(messageIds.filter { !$0.isEmpty })
    guard !ids.isEmpty else { return }
    queue.sync {
      var blob = retentionLocked()
      var changed = false
      for id in ids where blob.store.removeValue(forKey: id) != nil { changed = true }
      let keptOrder = blob.order.filter { !ids.contains($0) }
      if keptOrder.count != blob.order.count {
        blob.order = keptOrder
        changed = true
      }
      for (alias, primary) in blob.alias where ids.contains(primary) {
        blob.alias.removeValue(forKey: alias)
        changed = true
      }
      for id in ids where blob.unrecoverable.remove(id) != nil { changed = true }
      if changed { persistRetentionLocked(blob) }
    }
  }

  /// The plaintext we retained for one of our own messages, if we still have it.
  func ownPlaintext(messageId: String, envelope: String? = nil) -> String? {
    queue.sync { retainedPlaintextLocked(messageId: messageId, envelope: envelope) }
  }

  /// The plaintext retained for a message, if we still have it. Callers hold `queue`.
  private func retainedPlaintextLocked(messageId: String?, envelope: String?) -> String? {
    let blob = retentionLocked()
    if let messageId, let text = blob.store[messageId] { return text }
    guard let envelope else { return nil }
    let key = Self.envelopePlaintextKey(envelope)
    if let text = blob.store[key] { return text }
    if let id = blob.alias[key] { return blob.store[id] }
    return nil
  }

  private static func envelopePlaintextKey(_ envelope: String) -> String {
    "e:" + String(envelope.suffix(24))
  }

  /// Seals a payload for `chatId`, or `nil` if this chat has no MLS session.
  ///
  /// `nil` is the ordinary case today and the caller must fall back to the
  /// existing envelope — it is not an error worth surfacing to the user.
  func seal(chatId: String, plaintext: String) -> String? {
    queue.sync {
      guard let session = sessionLocked(chatId: chatId) else { return nil }
      do {
        return try session.seal(plaintext: Data(plaintext.utf8))
      } catch {
        VibeLog.error("[VibeSecure] seal failed for \(chatId): \(error)")
        return nil
      }
    }
  }

  /// Opens a `vmls1.` envelope for `chatId`.
  ///
  /// Returns `nil` on every failure — no session, wrong session, tampered
  /// ciphertext — and the caller renders the existing decryption-failed state.
  /// Failures are deliberately indistinguishable *to the caller*; the Rust side
  /// already collapses them so that "wrong key" and "tampered" cannot be told
  /// apart.
  ///
  /// `isMine` and `messageId` exist only for the log line, and they matter more
  /// than they look. A self-authored message can never be opened — MLS encrypts
  /// to the group's *other* members — so a failure on our own message is
  /// **expected** and means the retained plaintext was missing, while a failure
  /// on a peer's message means the session genuinely disagrees and is a real
  /// bug. Without that distinction the log is a wall of identical "open failed"
  /// lines that cannot tell those two apart, which is exactly what it was on
  /// 2026-08-06.
  func open(chatId: String, envelope: String, isMine: Bool = false, messageId: String? = nil)
    -> String?
  {
    queue.sync { () -> String? in
      let who = isMine ? "own" : "peer"
      // MLS opens are one-shot: `process_message` drops the ratchet key, so a second
      // open of the same envelope fails and the row blanks on the next reload.
      if let retained = retainedPlaintextLocked(messageId: messageId, envelope: envelope) {
        return retained
      }
      if isUnrecoverableLocked(messageId: messageId) {
        if let messageId, loggedTombstones.insert(messageId).inserted {
          VibeLog.info(
            "mls row tombstoned; not retried", category: "crypto",
            metadata: [
              "chat": String(chatId.prefix(12)), "msg": String(messageId.suffix(12)),
              "stage": "mls-tombstone",
            ])
        }
        return nil
      }
      let session = sessionForEnvelopeLocked(
        chatId: chatId, envelope: envelope, messageId: messageId)
      guard let session else {
        VibeLog.error(
          "mls open has no session",
          category: "crypto",
          metadata: [
            "chat": String(chatId.prefix(12)),
            "msg": messageId.map { String($0.suffix(12)) } ?? "-",
            "mine": isMine ? "Y" : "N",
            "stage": "no-session",
            "group": groupIdHexLocked(chatId: chatId) ?? "none",
            "from": who,
          ])
        return nil
      }
      let header = try? vibeMlsEnvelopeHeader(envelope: envelope)
      do {
        let plaintext = String(decoding: try session.open(envelope: envelope), as: UTF8.self)
        retainPlaintextLocked(plaintext, messageId: messageId, envelope: envelope)
        return plaintext
      } catch {
        var meta: [String: String] = [
          "chat": String(chatId.prefix(12)),
          "msg": messageId.map { String($0.suffix(12)) } ?? "-",
          "group": groupIdHexLocked(chatId: chatId) ?? "none",
          "envEpoch": header.map { String($0.epoch) } ?? "-",
          "groupEpoch": (try? session.epoch()).map(String.init) ?? "-",
          "pending": ((try? session.hasPendingCommit()) ?? false) ? "Y" : "N",
          "content": header?.content ?? "-",
          "err": String((error as NSError).localizedDescription.prefix(80)),
        ]
        if isMine {
          meta["stage"] = "mls-own-expected"
          // Nothing but the retained plaintext could ever open this, and it is gone —
          // retaining it later clears the mark, so a resend still recovers the row.
          markUnrecoverableLocked(messageId: messageId)
          if loggedTombstones.insert("own:" + (messageId ?? String(envelope.suffix(24)))).inserted {
            VibeLog.info("own mls message is not self-openable", category: "crypto", metadata: meta)
          }
        } else {
          meta["stage"] = "mls-open"
          if let envGid = try? vibeMlsGroupIdFromEnvelope(envelope: envelope) {
            meta["envGroup"] = envGid.prefix(8).map { String(format: "%02x", $0) }.joined()
          }
          if let bound = try? session.groupId() {
            meta["boundGroup"] = bound.prefix(8).map { String(format: "%02x", $0) }.joined()
          }
          // Same epoch or older with nothing pending: the ratchet key is spent, so every later
          // open fails the same way. Tombstone it; the engine renders a resend hint instead.
          if let header, let groupEpoch = try? session.epoch(), header.epoch <= groupEpoch,
            ((try? session.hasPendingCommit()) ?? true) == false
          {
            markUnrecoverableLocked(messageId: messageId)
            meta["tombstone"] = "Y"
          }
          VibeLog.error("mls peer open failed", category: "crypto", metadata: meta)
        }
        return nil
      }
    }
  }

  /// Group named on the envelope, not whatever `chatId` last bound.
  /// Both sides used to mint a DM group; chatId then pointed at ours while the peer sealed to theirs.
  private func sessionForEnvelopeLocked(chatId: String, envelope: String, messageId: String?)
    -> VibeSecureSessionHandle?
  {
    let bound = sessionLocked(chatId: chatId)
    let envelopeGroupId = try? vibeMlsGroupIdFromEnvelope(envelope: envelope)
    if let envelopeGroupId {
      let boundId = try? bound?.groupId()
      if boundId != envelopeGroupId {
        if let identity = identityHandleLocked(),
          let restored = try? identity.loadSession(groupId: envelopeGroupId)
        {
          sessions[chatId] = restored
          Self.storeGroupId(envelopeGroupId, chatId: chatId)
          VibeLog.notice(
            "rebound mls group from envelope",
            category: "crypto",
            metadata: [
              "chat": String(chatId.prefix(12)),
              "msg": messageId.map { String($0.suffix(12)) } ?? "-",
              "stage": "envelope-rebind",
            ])
          return restored
        }
        return recoverSessionLocked(chatId: chatId, envelope: envelope, messageId: messageId)
      }
    }
    return bound
      ?? recoverSessionLocked(chatId: chatId, envelope: envelope, messageId: messageId)
  }

  /// Reloads a persisted group whose chat mapping was dropped, using the envelope header.
  private func recoverSessionLocked(chatId: String, envelope: String, messageId: String?)
    -> VibeSecureSessionHandle?
  {
    guard let identity = identityHandleLocked() else { return nil }
    let groupId: Data
    do {
      groupId = try vibeMlsGroupIdFromEnvelope(envelope: envelope)
    } catch {
      VibeLog.error(
        "mls envelope header unreadable",
        category: "crypto",
        metadata: [
          "chat": String(chatId.prefix(12)),
          "msg": messageId.map { String($0.suffix(12)) } ?? "-",
          "stage": "envelope-group-id",
        ])
      return nil
    }
    do {
      guard let restored = try identity.loadSession(groupId: groupId) else {
        VibeLog.error(
          "mls sqlite has no group for envelope",
          category: "crypto",
          metadata: [
            "chat": String(chatId.prefix(12)),
            "msg": messageId.map { String($0.suffix(12)) } ?? "-",
            "stage": "sqlite-miss",
          ])
        return nil
      }
      sessions[chatId] = restored
      Self.storeGroupId(groupId, chatId: chatId)
      VibeLog.notice(
        "rebound mls group from envelope",
        category: "crypto",
        metadata: [
          "chat": String(chatId.prefix(12)),
          "msg": messageId.map { String($0.suffix(12)) } ?? "-",
          "stage": "rebound",
        ])
      return restored
    } catch {
      VibeLog.error(
        "mls session reload failed",
        category: "crypto",
        metadata: [
          "chat": String(chatId.prefix(12)),
          "msg": messageId.map { String($0.suffix(12)) } ?? "-",
          "stage": "sqlite-load",
        ])
      return nil
    }
  }

  /// The MLS group id for a chat, hex-truncated, for logs only.
  ///
  /// Two devices that each created their own group for the same chat is the
  /// failure that looks identical to every other decrypt failure from the
  /// outside — both sides hold a valid session, both seal happily, and neither
  /// can read the other. Printing the group id is what makes that visible
  /// instead of merely suspected.
  ///
  /// **Reads the stored id directly and must never call `groupId(chatId:)`.**
  /// Every caller is already inside `queue.sync`, and that accessor takes the
  /// same serial queue — re-entering it is not a deadlock but an immediate
  /// `__builtin_trap` from libdispatch ("dispatch_sync called on queue already
  /// owned by current thread"), which surfaces as signal 5 with nothing on
  /// stderr. It killed the app on launch on 2026-08-07, from a log line whose
  /// only job was explaining a decrypt failure: the diagnostic crashed on
  /// exactly the failure it existed to describe, so the first MLS history page
  /// with an unopenable row took the process down.
  ///
  /// Reading the stored id is also strictly more informative here than
  /// `groupId(chatId:)` would be, since that returns nil unless a session
  /// loads — which is precisely the branch that cannot load one. "Stored group
  /// exists but no session" and "nothing stored at all" are different bugs.
  private func groupIdHexLocked(chatId: String) -> String? {
    guard let id = Self.storedGroupId(chatId: chatId) else { return nil }
    return id.prefix(8).map { String(format: "%02x", $0) }.joined()
  }

  /// True when `raw` is an MLS envelope. Prefix test only — matches how the Rust
  /// classifier and the shipped `arte1.` detection both work.
  static func isMlsEnvelope(_ raw: String?) -> Bool {
    guard let raw = raw else { return false }
    return raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("vmls1.")
  }
}

/// A stable per-install device identifier for the MLS credential.
///
/// Keychain-backed rather than a `UserDefaults` string so it survives an app
/// reinstall the way the user expects an identity to, and `ThisDeviceOnly` so it
/// never rides a backup onto a second device — two devices sharing one MLS
/// credential is exactly the confusion the credential exists to prevent.
enum VibeSecureDeviceId {

  private static let service = "vibe.secure.identity"
  private static let account = "mls_device_id_v1"
  private static let queue = DispatchQueue(label: "vibe.secure.deviceid")

  static func loadOrCreate() -> String? {
    queue.sync {
      if let existing = load() { return existing }
      let fresh = UUID().uuidString
      return store(fresh) ? fresh : nil
    }
  }

  private static func load() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data,
      let value = String(data: data, encoding: .utf8),
      !value.isEmpty
    else {
      return nil
    }
    return value
  }

  private static func store(_ value: String) -> Bool {
    let attributes: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: Data(value.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ]
    SecItemDelete(attributes as CFDictionary)
    return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
  }
}
