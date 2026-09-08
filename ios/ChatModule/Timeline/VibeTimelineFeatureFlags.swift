import Foundation

// MARK: - Chat-class eligibility

/// Rollout classes are deliberately separate because their ordering, encryption,
/// and event sources have different risk. A regression in one class must not force
/// an all-or-nothing renderer rollout.
enum VibeTimelineChatClass: UInt8, Sendable, Equatable, CaseIterable {
  case directMessage = 0
  case group = 1
  case channel = 2
  case savedMessages = 3
  case agentDirect = 4
}

struct VibeTimelineChatClassEligibility: OptionSet, Sendable, Equatable {
  let rawValue: UInt32

  init(rawValue: UInt32) {
    self.rawValue = rawValue
  }

  static let directMessage = Self(rawValue: 1 << VibeTimelineChatClass.directMessage.rawValue)
  static let group = Self(rawValue: 1 << VibeTimelineChatClass.group.rawValue)
  static let channel = Self(rawValue: 1 << VibeTimelineChatClass.channel.rawValue)
  static let savedMessages = Self(rawValue: 1 << VibeTimelineChatClass.savedMessages.rawValue)
  static let agentDirect = Self(rawValue: 1 << VibeTimelineChatClass.agentDirect.rawValue)

  static let all: Self = [
    .directMessage,
    .group,
    .channel,
    .savedMessages,
    .agentDirect,
  ]

  func contains(_ chatClass: VibeTimelineChatClass) -> Bool {
    contains(Self(rawValue: 1 << chatClass.rawValue))
  }
}

// MARK: - Feature flags

/// Rollout gates for the async timeline stack.
///
/// **Default-off:** `vibeAsyncTimelineV1Enabled` is `false` unless explicitly set.
/// Debug builds must not flip this on implicitly — qualification requires an intentional
/// enable (UserDefaults key, remote config injection, or test override).
struct VibeTimelineFeatureFlags: Sendable, Equatable {
  /// Parallel `VibeMessageListHost` path. Default `false` until board gates pass.
  var vibeAsyncTimelineV1Enabled: Bool
  /// Dual-apply shadow comparison (ids/metrics only). Independent of async host.
  var vibeTimelineShadowCompareEnabled: Bool
  /// The core orders the production list's tail; `ChatListView` keeps its own
  /// cells, heights and everything else.
  ///
  /// A third gate rather than a mode of `vibeAsyncTimelineV1Enabled`, because it
  /// is a genuinely different risk. Order authority permutes rows the engine
  /// already built and the shadow probe already proves agreement on; the async
  /// host replaces the entire render path. Folding a small reversible step into
  /// the flag that governs the large irreversible one would mean the only way to
  /// try the first is to accept the second.
  var vibeTimelineCoreOrderAuthorityEnabled: Bool
  /// Explicit per-class rollout allowlist **for the render path**. Empty by
  /// default, including when the umbrella flag is accidentally enabled.
  var eligibleChatClasses: VibeTimelineChatClassEligibility
  /// Per-class allowlist for shadow comparison only.
  ///
  /// Deliberately a separate field from ``eligibleChatClasses``. Sharing one
  /// allowlist between "compare quietly and log" and "render this to the user"
  /// couples a diagnostic to a rollout: widening it to gather data would silently
  /// widen what the render gate would cover the moment anyone enabled it. Two
  /// risks, two lists.
  var shadowEligibleChatClasses: VibeTimelineChatClassEligibility
  /// Bounds how many transcript rows the **existing** `ChatListView` parses,
  /// measures and mounts at once.
  ///
  /// Independent of every other gate here, because it governs the shipping list
  /// rather than the core render path. `ChatListView` already contains a full
  /// windowing implementation — scroll-up detection, reveal, prepend, anchor
  /// preservation — wired to the scroll handler and permanently inert, because
  /// the one function that would populate it (`windowedPayloadForParsing`) was
  /// reduced to returning its input unchanged. So today only agent DMs are
  /// capped, and normal DMs, groups and channels mount every message ever sent.
  ///
  /// This flag re-arms that machinery. It is not part of the core migration and
  /// does not wait on it: §2 of the refactor doc lists the bounded window as
  /// achievable in Swift alone, and the 2026-07-23 scale review named the
  /// missing cap as the first thing that breaks at scale.
  var vibeTranscriptWindowEnabled: Bool
  /// Active window override; `nil` uses `VibeTimelineWindowPolicy.defaultActiveWindowCount`.
  var activeWindowOverride: Int?

  init(
    vibeAsyncTimelineV1Enabled: Bool = false,
    vibeTimelineShadowCompareEnabled: Bool = false,
    vibeTimelineCoreOrderAuthorityEnabled: Bool = false,
    vibeTranscriptWindowEnabled: Bool = false,
    eligibleChatClasses: VibeTimelineChatClassEligibility = [],
    shadowEligibleChatClasses: VibeTimelineChatClassEligibility = [],
    activeWindowOverride: Int? = nil
  ) {
    self.vibeAsyncTimelineV1Enabled = vibeAsyncTimelineV1Enabled
    self.vibeTimelineShadowCompareEnabled = vibeTimelineShadowCompareEnabled
    self.vibeTimelineCoreOrderAuthorityEnabled = vibeTimelineCoreOrderAuthorityEnabled
    self.vibeTranscriptWindowEnabled = vibeTranscriptWindowEnabled
    self.eligibleChatClasses = eligibleChatClasses
    self.shadowEligibleChatClasses = shadowEligibleChatClasses
    self.activeWindowOverride = activeWindowOverride
  }

  /// Production defaults: async host off, shadow off, policy default window.
  static let `default` = VibeTimelineFeatureFlags()

  /// Resolved active window after policy clamp.
  var resolvedActiveWindowCount: Int {
    let proposed = activeWindowOverride ?? VibeTimelineWindowPolicy.defaultActiveWindowCount
    return VibeTimelineWindowPolicy.clampActiveWindow(proposed)
  }

  /// The new host is active only when both gates agree. This intentionally fails
  /// closed for unknown/missing remote-config values.
  func isAsyncTimelineEnabled(for chatClass: VibeTimelineChatClass) -> Bool {
    vibeAsyncTimelineV1Enabled && eligibleChatClasses.contains(chatClass)
  }
}

// MARK: - Injectable provider

/// Read-only flag source. Injected by app composition or tests — no process-global singleton.
protocol VibeTimelineFeatureFlagProviding {
  var flags: VibeTimelineFeatureFlags { get }
}

/// Fixed flags for tests and previews.
struct VibeTimelineFixedFeatureFlags: VibeTimelineFeatureFlagProviding {
  let flags: VibeTimelineFeatureFlags

  init(_ flags: VibeTimelineFeatureFlags = .default) {
    self.flags = flags
  }
}

/// UserDefaults-backed provider.
///
/// Missing keys resolve to **false** / policy default in release. In debug the
/// *shadow comparison* pair (flag + DM allowlist) resolves on instead, because it
/// renders nothing and only writes log lines — see the comment at the resolution
/// site. The async-host flag is default-off in every configuration.
///
/// Does not write defaults on read. Enabling the async path requires an explicit write
/// elsewhere (settings, remote config bridge, or test setup).
struct VibeTimelineUserDefaultsFeatureFlags: VibeTimelineFeatureFlagProviding {
  static let asyncTimelineKey = "vibeAsyncTimelineV1Enabled"
  static let shadowCompareKey = "vibeTimelineShadowCompareEnabled"
  static let coreOrderAuthorityKey = "vibeTimelineCoreOrderAuthorityEnabled"
  static let transcriptWindowKey = "vibeTranscriptWindowEnabled"
  static let activeWindowKey = "vibeTimelineActiveWindowCount"
  static let eligibleChatClassesKey = "vibeTimelineEligibleChatClassesMask"

  private let defaults: UserDefaults
  private let asyncKey: String
  private let shadowKey: String
  private let windowKey: String
  private let eligibilityKey: String

  init(
    defaults: UserDefaults = .standard,
    asyncKey: String = VibeTimelineUserDefaultsFeatureFlags.asyncTimelineKey,
    shadowKey: String = VibeTimelineUserDefaultsFeatureFlags.shadowCompareKey,
    windowKey: String = VibeTimelineUserDefaultsFeatureFlags.activeWindowKey,
    eligibilityKey: String = VibeTimelineUserDefaultsFeatureFlags.eligibleChatClassesKey
  ) {
    self.defaults = defaults
    self.asyncKey = asyncKey
    self.shadowKey = shadowKey
    self.windowKey = windowKey
    self.eligibilityKey = eligibilityKey
  }

  /// Opens or closes the render-path gate for 1:1 DMs, both halves at once.
  ///
  /// The two keys are separate for good reason — one says "the async path exists", the
  /// other says "for which chat classes" — but they are useless individually: an armed
  /// flag with an empty allowlist renders nothing, and an allowlist behind a closed flag
  /// is inert. A caller flipping one and forgetting the other sees no change and
  /// concludes the core does not work, which is the failure mode this project has
  /// already hit twice. One switch, both keys.
  static func setDirectMessageRenderPathEnabled(
    _ enabled: Bool, defaults: UserDefaults = .standard
  ) {
    defaults.set(enabled, forKey: asyncTimelineKey)
    defaults.set(
      enabled ? Int(VibeTimelineChatClassEligibility.directMessage.rawValue) : 0,
      forKey: eligibleChatClassesKey)
    VibeLog.notice(
      "[VibeCore] DM render path \(enabled ? "ENABLED" : "disabled")", category: "core")
  }

  /// Whether the DM render path is fully open — both keys, as `canRender` reads them.
  static func isDirectMessageRenderPathEnabled(defaults: UserDefaults = .standard) -> Bool {
    let flags = VibeTimelineUserDefaultsFeatureFlags(defaults: defaults).flags
    return flags.vibeAsyncTimelineV1Enabled
      && flags.eligibleChatClasses.contains(.directMessage)
  }

  var flags: VibeTimelineFeatureFlags {
    // `bool(forKey:)` returns false when unset — correct default-off semantics.
    // Still use `object(forKey:)` so we never treat an accidental non-bool as true.
    let asyncEnabled = defaults.object(forKey: asyncKey) as? Bool ?? false

    // The two gates get different defaults, on purpose.
    //
    // `vibeAsyncTimelineV1Enabled` changes what the user sees, so it stays
    // default-off everywhere including debug — qualification has to be an
    // intentional act.
    //
    // Shadow comparison changes nothing: it feeds the core the rows the engine
    // is already about to render, compares the two orderings, and writes a log
    // line. Its worst failure is a log line. Leaving it off by default meant the
    // only data that can open the read-authority gate was gathered exclusively
    // when someone remembered to flip a switch — which is to say, almost never.
    // Debug builds arm it; release builds still require the explicit write.
    let shadowDefault: Bool
    #if DEBUG
      shadowDefault = true
    #else
      shadowDefault = false
    #endif
    let shadowEnabled = defaults.object(forKey: shadowKey) as? Bool ?? shadowDefault

    // Default-off everywhere, debug included: this one reaches the screen.
    let orderAuthority =
      defaults.object(forKey: Self.coreOrderAuthorityKey) as? Bool ?? false

    // OFF everywhere, debug included. This one reaches the screen, and what it put
    // there was a scroll wall.
    //
    // It was armed in debug on the theory that withheld rows are "merely unmounted"
    // and arrive on scroll like every other messaging app. Two things were wrong with
    // that. The reveal is not a slide, it is a one-shot re-apply of the whole
    // transcript — `history-window REVEAL … visible=1079 of 1079` then a 879-row batch
    // insert — so reaching older history costs a multi-hundred-millisecond main-thread
    // stall and a visible content-size jump, not a scroll. And the seed path never
    // asked the window at all: a cold open mounted the full 979 rows, the first engine
    // flush clamped to 200, and the difference was deleted as zombies
    // (`reconcile ZOMBIES removed=779`, contentH 36230→7439) before the background
    // drain re-inserted them page by page. The cap therefore paid the full mount cost
    // AND charged the reader a wall for it.
    //
    // The cost it was hiding is fixed at the source: `ChatTimelineLayout` memoizes
    // heights by row identity, and `setRows` no longer runs an O(previous × parsed)
    // scan per apply. Mount the transcript.
    //
    // The machinery below (`windowedTranscriptSourceRows`, the reveal path) is left
    // wired and reachable through this key, so a genuinely pathological transcript can
    // still be bounded from the debug menu without restoring the default.
    let transcriptWindowDefault = false
    let transcriptWindow =
      defaults.object(forKey: Self.transcriptWindowKey) as? Bool ?? transcriptWindowDefault

    let eligibilityRaw: UInt32
    if let value = defaults.object(forKey: eligibilityKey) as? Int {
      eligibilityRaw = value >= 0 && UInt64(value) <= UInt64(UInt32.max) ? UInt32(value) : 0
    } else {
      eligibilityRaw = 0
    }
    let windowOverride: Int?
    if let number = defaults.object(forKey: windowKey) as? Int {
      windowOverride = number
    } else if let number = defaults.object(forKey: windowKey) as? NSNumber {
      windowOverride = number.intValue
    } else {
      windowOverride = nil
    }
    // An armed probe with an empty allowlist compares nothing, so the shadow
    // allowlist follows the shadow flag: debug arms the one class P4 covers.
    let shadowClasses: VibeTimelineChatClassEligibility =
      shadowEnabled ? .directMessage : []

    return VibeTimelineFeatureFlags(
      vibeAsyncTimelineV1Enabled: asyncEnabled,
      vibeTimelineShadowCompareEnabled: shadowEnabled,
      vibeTimelineCoreOrderAuthorityEnabled: orderAuthority,
      vibeTranscriptWindowEnabled: transcriptWindow,
      eligibleChatClasses: VibeTimelineChatClassEligibility(rawValue: eligibilityRaw),
      shadowEligibleChatClasses: shadowClasses,
      activeWindowOverride: windowOverride
    )
  }
}

// MARK: - Mutable test store

/// Thread-safe-enough test double (mutate on the test thread only).
/// Not a global singleton — callers hold the instance.
final class VibeTimelineMutableFeatureFlags: @unchecked Sendable, VibeTimelineFeatureFlagProviding {
  private let lock = NSLock()
  private var storage: VibeTimelineFeatureFlags

  init(_ flags: VibeTimelineFeatureFlags = .default) {
    self.storage = flags
  }

  var flags: VibeTimelineFeatureFlags {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func update(_ body: (inout VibeTimelineFeatureFlags) -> Void) {
    lock.lock()
    defer { lock.unlock() }
    body(&storage)
  }

  func setAsyncTimelineEnabled(_ enabled: Bool) {
    update { $0.vibeAsyncTimelineV1Enabled = enabled }
  }
}
