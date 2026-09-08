import Foundation

/// Gets an MLS session to exist for a chat, which is the one thing
/// `VibeSecureSessions` cannot do for itself: creating a group means talking to
/// the server to fetch the other side's KeyPackage, and joining one means
/// receiving a Welcome that arrived out of band.
///
/// # Why this is a separate type
///
/// `VibeSecureSessions` is pure custody — it holds the identity, the store, and
/// the per-chat sessions, and every one of its methods is synchronous and
/// local. Establishment is the opposite: network-bound, retryable, and racy.
/// Keeping them apart means the custody layer stays trivially auditable, and
/// this layer never has to reason about the ratchet.
///
/// # Never on the engine queue
///
/// Every entry point here returns immediately and does its work on
/// `establishmentQueue` / `URLSession`. `ChatEngine`'s serial queue is the
/// engine's critical path, and an HTTP round-trip on it freezes messaging —
/// the same rule that governs every other network call in the engine.
///
/// # The first-contact race
///
/// Two devices can both decide to establish the same chat at the same instant,
/// each creating a group and adding the other. Both then hold a valid session
/// for one chat id, and neither can read the other's messages. The tie-break is
/// in `resolveCollision` below: both sides apply the *same* rule to the *same*
/// two group ids, so they converge without another round-trip.
enum VibeSecureEstablishment {

  /// How many KeyPackages this device keeps published.
  ///
  /// Each one is consumed by a single peer adding this device to a group, so
  /// the pool is "how many people can start a conversation with me before I
  /// next come online to top it up". Ten is generous for a first release and
  /// cheap: a KeyPackage is a couple of hundred bytes.
  private static let keyPackagePoolSize = 10

  /// Top the pool up when it falls to here. Deliberately not zero — a peer that
  /// finds an empty pool cannot start a conversation at all, so the pool must
  /// refill before it runs dry, not after.
  private static let keyPackageLowWaterMark = 3

  /// Largest group this will establish an MLS session for. Beyond it the chat
  /// is marked ineligible — see `VibeSecureSessions.isIneligible(chatId:)` for
  /// why that is the only workable signal here and what it costs.
  static let maxGroupMembers = 256

  /// How old a group must be before "the server has no Welcome for it" is
  /// treated as abandonment rather than a Welcome still in flight.
  private static let orphanGraceSeconds: TimeInterval = 120

  private static let establishmentQueue = DispatchQueue(
    label: "vibe.secure.establishment", qos: .utility)

  /// Chats with an establishment attempt already in flight.
  ///
  /// Guarded by `establishmentQueue`. Without this, a user hammering send on an
  /// unestablished chat would fire one group creation per tap, and each would
  /// consume one of the peer's finite KeyPackages.
  private static var inFlight: Set<String> = []

  // ── Publishing this device's KeyPackages ────────────────────────────────

  /// Ensures this device has KeyPackages published so peers can add it.
  ///
  /// Safe to call on every launch and every login: it asks the server how many
  /// remain first and does nothing when the pool is healthy.
  static func ensureKeyPackagesPublished(apiBase: URL, token: String?) {
    establishmentQueue.async {
      // Resolving the identity is what discovers a changed signing key and sets
      // the flag below, so reading the flag without this can read `false` on the
      // one launch it matters — see `ensureIdentityResolved`.
      VibeSecureSessions.shared.ensureIdentityResolved()

      // A retired signing key must **not** consult the count. Every package the
      // server holds for this device names the dead key, so the pool looks
      // perfectly healthy at exactly the moment its entire contents are
      // poison — that is why a device in this state logged "published 0
      // KeyPackages" all day while being unreachable. Republish unconditionally
      // and let the server retire the old batch in the same transaction.
      guard !VibeSecureSessions.identityResetPending else {
        publishKeyPackages(
          count: keyPackagePoolSize, apiBase: apiBase, token: token, retireDeviceKeys: true)
        return
      }
      request(
        method: "GET", path: "api/mls/key-packages/count", apiBase: apiBase, token: token,
        body: nil
      ) { object in
        let remaining = (object?["count"] as? Int) ?? 0
        guard remaining <= keyPackageLowWaterMark else { return }
        publishKeyPackages(count: keyPackagePoolSize - remaining, apiBase: apiBase, token: token)
      }
    }
  }

  private static func publishKeyPackages(
    count: Int, apiBase: URL, token: String?, retireDeviceKeys: Bool = false
  ) {
    guard count > 0, let deviceId = VibeSecureDeviceId.loadOrCreate() else { return }
    var encoded: [String] = []
    encoded.reserveCapacity(count)
    for _ in 0..<count {
      guard let package = VibeSecureSessions.shared.freshKeyPackage() else { break }
      encoded.append(package.base64EncodedString())
    }
    guard !encoded.isEmpty else {
      VibeLog.error("[VibeSecure] could not mint any KeyPackage — MLS unavailable to peers")
      return
    }
    var body: [String: Any] = ["deviceId": deviceId, "keyPackages": encoded]
    if retireDeviceKeys { body["retireDeviceKeys"] = true }
    request(
      method: "POST", path: "api/mls/key-packages", apiBase: apiBase, token: token, body: body
    ) { object in
      let published = (object?["count"] as? Int) ?? 0
      guard published > 0 else {
        VibeLog.error("[VibeSecure] KeyPackage publish returned nothing — peers cannot add us")
        return
      }
      if retireDeviceKeys {
        // `retired` must come back true, not merely `success`. A server that
        // predates the flag ignores it, publishes the fresh batch, and answers
        // exactly like one that honoured it — while every KeyPackage signed by
        // the retired key stays claimable, and `claim` hands out the oldest
        // first. Clearing on that reply would rebuild the same broken group and
        // never ask again. Staying pending costs a republish per provisioning
        // pass until the server catches up, which is the cheap side of this.
        guard object?["retired"] as? Bool == true else {
          VibeLog.error(
            "[VibeSecure] server did not retire the old signing key — staying pending;"
              + " KeyPackages naming the dead key are still claimable")
          return
        }
        // Only now. Clearing on the request rather than the response would let
        // a dropped reply strand the device with a server-side pool that still
        // names its retired key, and nothing would ever ask again.
        VibeSecureSessions.identityResetPending = false
        VibeLog.notice(
          "[VibeSecure] retired the old signing key server-side and published"
            + " \(published) fresh KeyPackages")
        return
      }
      VibeLog.info("[VibeSecure] published \(published) KeyPackages")
    }
  }

  // ── Establishing a DM ───────────────────────────────────────────────────

  /// Creates the MLS group for a 1:1 chat and hands the peer its Welcome.
  ///
  /// `completion` runs with `true` only when a session is live and sealed
  /// messages will be readable by the peer. The caller's contract is to keep
  /// the message queued until then — never to send it in the clear.
  ///
  /// Groups are deliberately not handled here. A group needs the full member
  /// list to add everyone in one commit, and that list does not exist at this
  /// layer today (see `docs/secure-core-architecture.md` §4).
  static func establishDirectMessage(
    chatId: String,
    peerUserId: String,
    myUserId: String? = nil,
    apiBase: URL,
    token: String?,
    completion: @escaping (Bool) -> Void
  ) {
    establishmentQueue.async {
      // Dropping the completion here would stall the caller's readiness loop forever.
      guard !inFlight.contains(chatId) else {
        completion(false)
        return
      }
      if VibeSecureSessions.shared.hasSession(chatId: chatId) {
        // A local session is NOT the same thing as an established chat, and treating it
        // as one is why a chat can sit at "not sealing yet — welcomes pending=0
        // delivered=0" for days: those counts mean the server holds no Welcome row at
        // all, so the peer was never told this group exists.
        //
        // The window is real. `createSession` persists the group before the
        // `POST /api/mls/welcomes` below returns, so a kill — or a dropped response — in
        // between leaves a group on disk whose Welcome was never recorded. Every later
        // attempt then short-circuits HERE, which is why a device in this state never
        // issues another `GET /api/mls/key-packages/<peer>` or `POST /api/mls/welcomes`.
        // Confirmed against the 2026-08-07 server log: neither call appears once, while
        // `welcome-status` is polled all day.
        //
        // Recovery lives in `refreshPeerConfirmation`, which is the only place that can
        // tell this state apart from an ordinary wait: `pending == 0 && delivered == 0`
        // means the server holds no Welcome row at all. It discards the orphan there, so
        // the next call through here finds no session and establishes properly. This
        // branch only reports it — a chat sitting on the log line below for more than
        // one confirmation pass means that repair is not running.
        if !VibeSecureSessions.shared.isPeerConfirmed(chatId: chatId) {
          VibeLog.error(
            "MLS session exists but peer never confirmed — chat cannot seal",
            category: "crypto",
            metadata: [
              "chat": String(chatId.prefix(12)),
              "peer": String(peerUserId.prefix(12)),
              "state": "orphaned-group",
              "effect": "outbound messages remain queued",
            ])
        }
        completion(true)
        return
      }
      inFlight.insert(chatId)

      let finish: (Bool) -> Void = { ok in
        establishmentQueue.async {
          inFlight.remove(chatId)
          completion(ok)
        }
      }

      if let me = myUserId?.uppercased(), !me.isEmpty {
        let peer = peerUserId.uppercased()
        if !peer.isEmpty, me > peer {
          // Lower UUID creates the only group. Two groups for one DM are unreadable to each other.
          drainPendingWelcomes(apiBase: apiBase, token: token, selfUserId: myUserId) { joined in
            finish(joined.contains(chatId))
          }
          return
        }
      }

      // Claim one of the peer's published KeyPackages. A 404 here is an
      // ordinary, expected state — that user has not published any, or has run
      // out — and it means this chat cannot be encrypted yet, not that
      // something is broken. The caller must keep the message queued.
      request(
        method: "GET", path: "api/mls/key-packages/\(escaped(peerUserId))", apiBase: apiBase,
        token: token, body: nil
      ) { object in
        guard
          let encoded = object?["keyPackage"] as? String,
          let keyPackage = Data(base64Encoded: encoded)
        else {
          // No peer key means no secure transport. Keep the optimistic draft local
          // and retry establishment without changing encryption schemes.
          VibeLog.info("[VibeSecure] no KeyPackage available for peer in \(chatId)")
          VibeSecureSessions.shared.markPeerKeysUnavailable(chatId: chatId)
          finish(false)
          return
        }
        VibeSecureSessions.shared.clearPeerKeysUnavailable(chatId: chatId)

        // Check who this KeyPackage actually belongs to before letting it into
        // a group. The server chose these bytes, and MLS does not make the
        // server honest — a substituted KeyPackage is a working MITM that
        // nothing else here would notice.
        guard case .trusted = verifyPeer(keyPackage: keyPackage, peerUserId: peerUserId) else {
          finish(false)
          return
        }

        // Create only after the claim succeeds. Creating first would leave a
        // real group on disk for a chat that never got a second member, and
        // `hasSession` would then report a session that nobody else can read.
        guard let session = VibeSecureSessions.shared.createSession(chatId: chatId) else {
          finish(false)
          return
        }
        let commit: VibeFfiCommitOutput
        do {
          commit = try session.addMembers(keyPackages: [keyPackage])
        } catch {
          VibeLog.error("[VibeSecure] add_members failed for \(chatId): \(error)")
          VibeSecureSessions.shared.discard(chatId: chatId)
          finish(false)
          return
        }

        // The commit itself has no existing members to go to — this group had
        // exactly one member until now — so only the Welcome is delivered.
        let ratchetTree = (try? session.exportRatchetTree()) ?? Data()
        request(
          method: "POST", path: "api/mls/welcomes", apiBase: apiBase, token: token,
          body: [
            "recipientUserId": peerUserId,
            "chatId": chatId,
            "welcome": commit.welcome.base64EncodedString(),
            "ratchetTree": ratchetTree.base64EncodedString(),
          ]
        ) { response in
          guard response?["success"] as? Bool == true else {
            // The peer will never learn this group exists, so a message sealed
            // under it would be permanently unreadable to them. Drop it and
            // let the next attempt start clean.
            VibeLog.error("[VibeSecure] welcome delivery failed for \(chatId)")
            VibeSecureSessions.shared.discard(chatId: chatId)
            finish(false)
            return
          }
          VibeLog.info("[VibeSecure] established MLS session for \(chatId)")
          finish(true)
        }
      }
    }
  }

  // ── Trust ───────────────────────────────────────────────────────────────

  enum PeerCheck: Equatable {
    case trusted
    /// The peer's identity key is not the one we pinned. Establishment stops.
    case identityChanged
    /// The KeyPackage did not validate at all — malformed, wrong ciphersuite,
    /// or a bad signature.
    case unreadable
  }

  /// Validates a claimed KeyPackage and compares its identity against the pin.
  ///
  /// Fails closed on `identityChanged`. That will occasionally block a peer who
  /// legitimately reinstalled, and that is the correct trade: the alternative
  /// is accepting any key the server offers, which is precisely the attack.
  /// Clearing it is a deliberate human act — `VibeSecureTrust.acceptChange` —
  /// ideally after comparing a safety number.
  static func verifyPeer(keyPackage: Data, peerUserId: String) -> PeerCheck {
    guard let identity = VibeSecureSessions.shared.inspectKeyPackage(keyPackage) else {
      VibeLog.error("[VibeSecure] peer KeyPackage failed validation for \(peerUserId)")
      return .unreadable
    }
    switch VibeSecureTrust.evaluate(signatureKey: identity.signatureKey, userId: peerUserId) {
    case .pinnedOnFirstContact:
      VibeLog.info("[VibeSecure] pinned identity for \(peerUserId) on first contact")
      return .trusted
    case .matchesPin:
      return .trusted
    case .changed:
      // Loud, because this is either a reinstall or someone in the middle and
      // the two look identical from here.
      VibeLog.error(
        "[VibeSecure] IDENTITY CHANGED for \(peerUserId) — refusing to establish. "
          + "Verify the safety number before accepting.")
      return .identityChanged
    }
  }

  // ── Establishing a group ────────────────────────────────────────────────

  /// Creates the MLS group backing a many-member chat and hands every other
  /// member its Welcome.
  ///
  /// Unlike a DM this needs the membership list, which the client cannot infer
  /// — hence the extra round-trip to `/mls/chats/:id/members`.
  ///
  /// **All-or-nothing.** If any member has no KeyPackage to claim, this gives
  /// up rather than establishing a group that silently excludes them. A member
  /// left out would not fail loudly; they would simply never see the
  /// conversation again, which is far worse than the sender waiting. The
  /// message stays queued and a later attempt retries.
  static func establishGroup(
    chatId: String,
    myUserId: String,
    apiBase: URL,
    token: String?,
    completion: @escaping (Bool) -> Void
  ) {
    establishmentQueue.async {
      guard !inFlight.contains(chatId) else {
        completion(false)
        return
      }
      if VibeSecureSessions.shared.hasSession(chatId: chatId) {
        completion(true)
        return
      }
      inFlight.insert(chatId)

      let finish: (Bool) -> Void = { ok in
        establishmentQueue.async {
          inFlight.remove(chatId)
          completion(ok)
        }
      }

      request(
        method: "GET", path: "api/mls/chats/\(escaped(chatId))/members", apiBase: apiBase,
        token: token, body: nil
      ) { object in
        guard let memberIds = object?["memberIds"] as? [String] else {
          VibeLog.info("[VibeSecure] no member list for \(chatId)")
          finish(false)
          return
        }
        let peers = memberIds.filter { $0 != myUserId }

        // Above this, treat the chat as a broadcast surface rather than a
        // group. Establishing would mean claiming a KeyPackage per member and
        // then a commit every member must process on each join or leave — a
        // storm, not a conversation. WhatsApp caps encrypted groups at 1024
        // for the same reason; this sits well below that because the failure
        // here is a stuck send, not a slow one.
        guard peers.count <= maxGroupMembers else {
          VibeLog.info(
            "[VibeSecure] \(chatId) has \(peers.count) members — over the MLS cap, marking ineligible"
          )
          VibeSecureSessions.shared.markIneligible(chatId: chatId)
          // `true` means "state changed, retry the send" — not "encrypted".
          // The retry now skips the gate and takes the existing path.
          finish(true)
          return
        }

        guard !peers.isEmpty else {
          // A group with only us in it has nobody to encrypt to. Establishing
          // would produce a session no one else can ever join.
          VibeLog.info("[VibeSecure] \(chatId) has no peers to add")
          finish(false)
          return
        }
        claimKeyPackages(for: peers, apiBase: apiBase, token: token) { claimed in
          guard claimed.count == peers.count else {
            VibeLog.info(
              "[VibeSecure] \(chatId) only \(claimed.count)/\(peers.count) KeyPackages — not establishing"
            )
            // A member has published no key, so there is nothing to encrypt to
            // and no amount of waiting changes that on its own. Reporting this
            // as a plain failure left the draft queued for a retry that could
            // only fail the same way, which is how a send stuck as pending
            // *forever* rather than for a moment.
            //
            // `true` means "state changed, re-evaluate the send" — not
            // "encrypted". The gate reads the mark and lets the message go out
            // on the envelope this peer can actually read. Nothing here can
            // downgrade an established chat: the send path checks
            // `isPeerConfirmed` first and that is one-way.
            VibeSecureSessions.shared.markPeerKeysUnavailable(chatId: chatId)
            finish(true)
            return
          }
          VibeSecureSessions.shared.clearPeerKeysUnavailable(chatId: chatId)
          guard let session = VibeSecureSessions.shared.createSession(chatId: chatId) else {
            finish(false)
            return
          }
          let commit: VibeFfiCommitOutput
          do {
            // One commit adds everyone, producing a single Welcome that
            // carries each joiner's secrets keyed to their own KeyPackage —
            // so the same bytes go to every recipient.
            commit = try session.addMembers(keyPackages: peers.compactMap { claimed[$0] })
          } catch {
            VibeLog.error("[VibeSecure] group add_members failed for \(chatId): \(error)")
            VibeSecureSessions.shared.discard(chatId: chatId)
            finish(false)
            return
          }

          let ratchetTree = (try? session.exportRatchetTree()) ?? Data()
          deliverWelcome(
            commit.welcome, ratchetTree: ratchetTree, to: peers, chatId: chatId,
            apiBase: apiBase, token: token
          ) { delivered in
            guard delivered else {
              // Some member will never learn the group exists. Drop it rather
              // than seal messages they can never read.
              VibeLog.error("[VibeSecure] group welcome delivery incomplete for \(chatId)")
              VibeSecureSessions.shared.discard(chatId: chatId)
              finish(false)
              return
            }
            VibeLog.info("[VibeSecure] established group MLS session for \(chatId)")
            finish(true)
          }
        }
      }
    }
  }

  /// Claims one KeyPackage per user, sequentially.
  ///
  /// Sequential rather than concurrent on purpose: each claim consumes a
  /// one-time key server-side, and a burst of parallel claims against the same
  /// user during a retry storm would drain their pool for no benefit. Groups
  /// are established once, so the latency does not sit on a hot path.
  private static func claimKeyPackages(
    for userIds: [String],
    apiBase: URL,
    token: String?,
    completion: @escaping ([String: Data]) -> Void
  ) {
    var claimed: [String: Data] = [:]
    var remaining = userIds

    func next() {
      guard !remaining.isEmpty else {
        completion(claimed)
        return
      }
      let userId = remaining.removeFirst()
      request(
        method: "GET", path: "api/mls/key-packages/\(escaped(userId))", apiBase: apiBase,
        token: token, body: nil
      ) { object in
        if let encoded = object?["keyPackage"] as? String,
          let data = Data(base64Encoded: encoded),
          // Same pin check as a DM. A group is only as private as its least
          // verified member, so one substituted KeyPackage here reads the whole
          // conversation — and because establishment is all-or-nothing, a
          // failure just leaves the group unestablished rather than silently
          // admitting an impostor.
          verifyPeer(keyPackage: data, peerUserId: userId) == .trusted
        {
          claimed[userId] = data
        }
        next()
      }
    }
    next()
  }

  /// Posts one Welcome to each recipient, reporting success only if every one
  /// was accepted.
  private static func deliverWelcome(
    _ welcome: Data,
    ratchetTree: Data,
    to userIds: [String],
    chatId: String,
    apiBase: URL,
    token: String?,
    completion: @escaping (Bool) -> Void
  ) {
    var remaining = userIds
    var allOk = true

    func next() {
      guard !remaining.isEmpty else {
        completion(allOk)
        return
      }
      let userId = remaining.removeFirst()
      request(
        method: "POST", path: "api/mls/welcomes", apiBase: apiBase, token: token,
        body: [
          "recipientUserId": userId,
          "chatId": chatId,
          "welcome": welcome.base64EncodedString(),
          "ratchetTree": ratchetTree.base64EncodedString(),
        ]
      ) { response in
        if response?["success"] as? Bool != true { allOk = false }
        next()
      }
    }
    next()
  }

  // ── Joining from a Welcome ──────────────────────────────────────────────

  /// Fetches and applies every Welcome waiting for this device.
  ///
  /// Called on launch and on socket join. Each Welcome is acked only after the
  /// join succeeds, so a crash mid-join leaves it pending and it is retried
  /// rather than silently lost — losing a Welcome means losing the ability to
  /// read that conversation entirely.
  /// `completion` receives the chat ids that gained a session, so the caller can
  /// release any drafts queued behind the send gate for those chats. Nothing
  /// else would release them — the sender is blocked waiting on exactly this.
  static func drainPendingWelcomes(
    apiBase: URL, token: String?, selfUserId: String?, completion: (([String]) -> Void)? = nil
  ) {
    establishmentQueue.async {
      // Same ordering requirement as `ensureKeyPackagesPublished`: the flag is
      // only true once the identity has been resolved.
      VibeSecureSessions.shared.ensureIdentityResolved()

      // Every Welcome on the server right now targets a KeyPackage signed by
      // the key this device just retired — and the matching private init key is
      // still in the store, so joining would *succeed* and mint a session that
      // is unreadable from birth. Wait for the retirement to land; it deletes
      // these rows in the same transaction that publishes the fresh pool.
      guard !VibeSecureSessions.identityResetPending else {
        VibeLog.info("[VibeSecure] skipping welcome drain until the retired key is cleared")
        completion?([])
        return
      }
      request(
        method: "GET", path: "api/mls/welcomes", apiBase: apiBase, token: token, body: nil
      ) { object in
        guard let welcomes = object?["welcomes"] as? [[String: Any]], !welcomes.isEmpty else {
          completion?([])
          return
        }
        var joined: [String] = []
        for entry in welcomes {
          guard
            let id = entry["id"] as? String,
            let chatId = entry["chatId"] as? String,
            let encoded = entry["welcome"] as? String,
            let welcome = Data(base64Encoded: encoded)
          else { continue }
          let ratchetTree = (entry["ratchetTree"] as? String).flatMap { Data(base64Encoded: $0) }

          let senderUserId = entry["senderUserId"] as? String
          if VibeSecureSessions.shared.groupId(chatId: chatId) != nil {
            guard adoptIncoming(senderUserId: senderUserId, selfUserId: selfUserId) else {
              // Our group wins. Do not ACK: an ACK is how the peer marks their
              // Welcome delivered and starts sealing to a group we never joined.
              continue
            }
            // Deliberately no `discard` here. `joinSession` overwrites both the
            // live session and the stored group id on success, so discarding
            // first buys nothing — and on a *failed* join it would have thrown
            // away a working group in exchange for none at all, leaving the
            // chat worse off than before the Welcome arrived.
          }

          guard
            VibeSecureSessions.shared.joinSession(
              chatId: chatId, welcome: welcome, ratchetTree: ratchetTree) != nil
          else {
            VibeLog.error("[VibeSecure] welcome join failed for \(chatId) — left pending")
            continue
          }
          VibeLog.info("[VibeSecure] joined MLS session for \(chatId)")
          // The joiner claims no KeyPackage, so this is its only chance to pin
          // the peer identity the group actually carries.
          if let senderUserId, senderUserId != selfUserId {
            VibeSecureSessions.shared.ensurePeerPinned(
              chatId: chatId, peerUserId: senderUserId)
          }
          joined.append(chatId)
          ack(id: id, apiBase: apiBase, token: token)
        }
        completion?(joined)
      }
    }
  }

  /// Decides whether an incoming Welcome should replace the session we already
  /// hold for that chat. Returns `true` to adopt the incoming group.
  ///
  /// Both devices see the same pair of user ids and must reach *opposite*
  /// conclusions, or the tie-break does not break anything. Lowest user id
  /// wins its own group; the other side adopts.
  ///
  /// The previous rule compared our stored **group id** against the incoming
  /// **Welcome blob** — two unrelated byte strings of different kinds and
  /// lengths. Its doc claimed both devices ran it "on the same pair of groups",
  /// but each device was comparing its own id against the other's welcome, so
  /// the two answers were independent coin flips: both could keep, or both
  /// could adopt and swap. A Welcome does not carry a readable group id (it is
  /// encrypted to the joiner), so there was never a way to compare the two
  /// groups without staging the join first. User ids are the identifiers both
  /// sides genuinely share.
  ///
  /// Falls back to adopting when either id is missing. An unknown id means we
  /// cannot run the rule at all, and adopting at least converges with a peer
  /// that keeps its own — while declining would leave a chat with a group its
  /// peer has abandoned, which never recovers.
  ///
  /// Messages sealed under the losing group before convergence are unreadable
  /// afterwards. That is a first-contact-only window, and losing a handful of
  /// opening messages is strictly better than the alternative, which is two
  /// devices talking past each other in a conversation that never converges.
  private static func adoptIncoming(senderUserId: String?, selfUserId: String?) -> Bool {
    guard
      let sender = senderUserId?.uppercased(), let me = selfUserId?.uppercased(),
      !sender.isEmpty, !me.isEmpty, sender != me
    else { return true }
    return sender < me
  }

  private static func ack(id: String, apiBase: URL, token: String?) {
    request(
      method: "POST", path: "api/mls/welcomes/\(escaped(id))/ack", apiBase: apiBase, token: token,
      body: nil, completion: { _ in })
  }

  // ── HTTP ────────────────────────────────────────────────────────────────

  /// Percent-encodes a value being spliced into a URL path.
  ///
  /// Deliberately *not* `.urlPathAllowed`, which leaves `/` untouched — an id
  /// containing one would then add path segments rather than be a single
  /// component, and `request` splits the path on `/` to build the URL. These
  /// ids are server-issued UUIDs today, so this is defence rather than a live
  /// bug, but the encoding has to be right for the splice to be safe at all.
  private static func escaped(_ raw: String) -> String {
    let unreserved = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return raw.addingPercentEncoding(withAllowedCharacters: unreserved) ?? raw
  }

  /// One JSON round-trip against the API, on the app's pinned session.
  ///
  /// `completion` receives `nil` for every failure — transport, non-2xx, or
  /// unparseable body. Callers here treat "no answer" and "no" identically:
  /// both mean the session is not established, and the only safe response to
  /// that is to keep the message queued.
  /// Asks the server whether the peer applied the Welcome we sent for `chatId`,
  /// and records the answer so the send path can start sealing.
  ///
  /// This is the missing half of establishment. Creating a group and posting a
  /// Welcome tells us nothing about whether the peer *received* it — MLS reports
  /// no such thing, and a sender cannot test by decrypting its own message. The
  /// server is the only party that knows, because it is the one holding the
  /// undelivered row.
  ///
  /// Cheap and idempotent, so it can hang off chat join beside the rest of
  /// provisioning. Once confirmed it never asks again.
  static func refreshPeerConfirmation(
    chatId: String,
    apiBase: URL,
    token: String?,
    completion: ((Bool) -> Void)? = nil
  ) {
    guard !VibeSecureSessions.shared.isPeerConfirmed(chatId: chatId) else {
      completion?(true)
      return
    }
    guard VibeSecureSessions.shared.groupId(chatId: chatId) != nil else {
      completion?(false)
      return
    }

    establishmentQueue.async {
      request(
        method: "GET",
        path: "api/mls/chats/\(escaped(chatId))/welcome-status",
        apiBase: apiBase,
        token: token,
        body: nil
      ) { object in
        guard let object else {
          completion?(false)
          return
        }
        let pending = (object["pending"] as? Int) ?? 0
        let delivered = (object["delivered"] as? Int) ?? 0
        let incomingPending = (object["incomingPending"] as? Int) ?? 0
        let incomingDelivered = (object["incomingDelivered"] as? Int) ?? 0
        if incomingDelivered > 0 || (delivered > 0 && pending == 0) {
          VibeSecureSessions.shared.markPeerConfirmed(chatId: chatId)
          completion?(true)
          return
        }
        if incomingPending > 0 {
          completion?(false)
          return
        }

        // No sent or received Welcome means this initiator session is orphaned.
        if delivered == 0, pending == 0 {
          let age = VibeSecureSessions.shared.groupAge(chatId: chatId) ?? 0
          if age > orphanGraceSeconds {
            VibeLog.notice(
              "discarding initiator mls group with no server welcome",
              category: "crypto",
              metadata: [
                "chat": String(chatId.prefix(12)),
                "stage": "orphan-discard",
                "age": "\(Int(age))",
              ])
            VibeSecureSessions.shared.discard(chatId: chatId)
          }
          completion?(false)
          return
        }

        VibeLog.info(
          "[VibeSecure] \(chatId) waiting for Welcome acknowledgement — pending=\(pending)"
            + " delivered=\(delivered)")
        completion?(false)
      }
    }
  }

  private static func request(
    method: String,
    path: String,
    apiBase: URL,
    token: String?,
    body: [String: Any]?,
    completion: @escaping ([String: Any]?) -> Void
  ) {
    var url = apiBase
    for component in path.split(separator: "/") {
      url = url.appendingPathComponent(String(component))
    }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if let token = token, !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    if let body = body {
      guard let data = try? JSONSerialization.data(withJSONObject: body) else {
        completion(nil)
        return
      }
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = data
    }
    ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) { data, response, error in
      establishmentQueue.async {
        guard
          error == nil,
          let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
          let data = data,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
          completion(nil)
          return
        }
        completion(object)
      }
    }.resume()
  }
}
