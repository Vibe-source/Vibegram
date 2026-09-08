import UIKit
import UserNotifications
import OSLog

private let appDelegateUITraceLogger = Logger(
  subsystem: "com.mohammadshayani.vibe.native",
  category: "UITrace"
)

private func appDelegateUITrace(_ message: String) {
  appDelegateUITraceLogger.notice("\(message, privacy: .public)")
  NSLog("[VibeUITrace] %@", message)
}

@main
final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  var window: UIWindow?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    appDelegateUITrace("AppDelegate didFinishLaunching")
    // Before anything else that could block: the launch path is itself a suspect, and a
    // watchdog installed after the slow part cannot see it.
    VibeMainThreadWatchdog.shared.start()
    // Bring up persistent diagnostics FIRST so any error during launch is captured
    // and a crash from the previous session is surfaced. See Shared/VibeLog.swift.
    let info = Bundle.main.infoDictionary
    let appVersion = (info?["CFBundleShortVersionString"] as? String) ?? "?"
    let appBuild = (info?["CFBundleVersion"] as? String) ?? "?"
    VibeLog.shared.bootstrap(appContext: [
      "launchOptions": launchOptions == nil ? "none" : String(launchOptions!.count),
      "app": "\(appVersion) (\(appBuild))",
      "os": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
    ])
    // Proves the Rust store's whole path (seal → write → page → unseal) against
    // the real on-disk database before anything asks it to hold real rows. Runs
    // on its own background queue, so it costs the launch path nothing.
    VibeCoreStoreBridge.runSelfTest()
    // Giphy SDK key for native GIF panel (Info.plist / env GIPHY_API_KEY).
    ChatGifPanelConfig.shared.reloadFromEnvironment()
    // Legacy packet_mesh sessions carry a transport that no longer exists — drop them to
    // direct before the UI binds to the config.
    ChatEngineStore.shared.migrateLegacyPacketMeshToDirectIfNeeded()
    // Settings → Proxy is the source of truth for the route; re-assert it here so a
    // session config restored from disk can't route through a proxy the user turned off.
    PacketProxyStore.shared.reassertProxyStateOnLaunch()
    // Remembered media pixel sizes — read off-main before any chat can open, because the
    // first lookup lands inside a sizing pass and a media row with no known aspect ratio is
    // mounted as a square and then corrected (a visible list shift).
    ChatMediaNaturalSizeStore.shared.prewarm()
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = AppRootControllerFactory.makeInitialController()
    AppAppearanceController.applyStoredPreference(to: window)
    window.makeKeyAndVisible()

    self.window = window
    // Where a chat open's cost actually goes: cell construction, not sizing. Opt-in — it
    // builds and destroys ~200 views on main and was measured blocking it for 0.44s.
    if ProcessInfo.processInfo.arguments.contains("-VibeCellCostCensus") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        ChatListCell.logConstructionCostCensus()
      }
    }
    configureCallNotifications()
    VibeNativeCallManager.shared.start()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleDidReceiveMemoryWarning),
      name: UIApplication.didReceiveMemoryWarningNotification,
      object: nil
    )
    return true
  }

  func applicationDidBecomeActive(_ application: UIApplication) {
    appDelegateUITrace("AppDelegate didBecomeActive")
    AppAppearanceController.releaseSnapshotStylePin()
    // Resume the main-thread stall watchdog and reset its baseline so the time the
    // process spent suspended in the background is NOT counted as a stall.
    AppUIStallWatchdog.shared.setActive(true, context: "foreground")
  }

  func applicationWillResignActive(_ application: UIApplication) {
    appDelegateUITrace("AppDelegate willResignActive")
    AppAppearanceController.pinCurrentStyleForSnapshot()
  }

  func applicationDidEnterBackground(_ application: UIApplication) {
    appDelegateUITrace("AppDelegate didEnterBackground")
    // Pause the watchdog: once iOS suspends the process the main-beat timer can't
    // tick, so on resume the elapsed wall-clock reads as a bogus ~20s "hang"
    // (cpu=0, run=waiting). Pausing here kills that false positive.
    AppUIStallWatchdog.shared.setActive(false, context: "background")
  }

  func applicationWillEnterForeground(_ application: UIApplication) {
    appDelegateUITrace("AppDelegate willEnterForeground")
    // The reopen-raster overlay cache is memory-only and iOS empties it while the app is
    // suspended, so the first chat opened after a return raced a ~75ms disk decode and
    // committed a bare-wallpaper shell until it landed. Rebuild it here, before the tap.
    ChatListView.rewarmReopenSnapshotRasters()
  }

  func applicationWillTerminate(_ application: UIApplication) {
    appDelegateUITrace("AppDelegate willTerminate")
  }

  func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    // Every vibe:// link goes through one router: room-link (channel invites), u/handle
    // (@username share links), and chat (chatId/friendId). It decides what it can open
    // and ignores the rest, so new link shapes don't need a change here.
    guard url.scheme?.lowercased() == "vibe" else { return false }
    guard let target = VibeRoomLinkRouter.target(from: url) else { return false }
    Task { @MainActor in
      VibeRoomLinkRouter.shared.handle(target: target)
    }
    return true
  }

  func application(
    _ application: UIApplication,
    continue userActivity: NSUserActivity,
    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void
  ) -> Bool {
    guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
      let url = userActivity.webpageURL
    else { return false }
    Task { @MainActor in
      VibeRoomLinkRouter.shared.handle(url: url)
    }
    return true
  }

  @objc private func handleDidReceiveMemoryWarning() {
    appDelegateUITrace("AppDelegate didReceiveMemoryWarning")
    VibeLog.warning("memory warning", category: "lifecycle")
    ChatWallpaperMaskStore.purge()
    ChatAvatarImageStore.purge()
    chatMediaImageCachePurgeForMemoryWarning()
  }

  func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    let handled = VibeNativeCallManager.shared.handleRemoteNotification(
      userInfo: userInfo,
      preferSystemUI: application.applicationState != .active
    )
    completionHandler(handled ? .newData : .noData)
  }

  private func configureCallNotifications() {
    let accept = UNNotificationAction(
      identifier: VibeNativeCallManager.foregroundCallAcceptAction,
      title: "Accept",
      options: [.foreground]
    )
    let decline = UNNotificationAction(
      identifier: VibeNativeCallManager.foregroundCallDeclineAction,
      title: "Decline",
      options: [.destructive]
    )
    let category = UNNotificationCategory(
      identifier: VibeNativeCallManager.foregroundCallCategoryIdentifier,
      actions: [accept, decline],
      intentIdentifiers: [],
      options: []
    )
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.setNotificationCategories([category])
    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
      NSLog(
        "[VibeNativeCall] foreground notification auth granted=%@ error=%@",
        granted ? "true" : "false",
        error?.localizedDescription ?? "nil"
      )
      guard granted else { return }
      DispatchQueue.main.async {
        UIApplication.shared.registerForRemoteNotifications()
      }
    }
  }

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    VibeNativeCallManager.shared.setApnsDeviceToken(deviceToken)
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    NSLog("[VibeNativeCall] APNs registration failed error=%@", error.localizedDescription)
    VibeNativeCallManager.shared.clearApnsDeviceToken()
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    guard notification.request.content.categoryIdentifier == VibeNativeCallManager.foregroundCallCategoryIdentifier else {
      completionHandler([])
      return
    }
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    defer { completionHandler() }
    let payload = response.notification.request.content.userInfo.reduce(into: [String: Any]()) {
      $0[String(describing: $1.key)] = $1.value
    }
    guard response.notification.request.content.categoryIdentifier == VibeNativeCallManager.foregroundCallCategoryIdentifier else {
      // Message / agent-event notifications: open the chat the payload names. Each one
      // now carries its own identity (the push collapse id is the message, not the chat),
      // so tapping a specific item has to land on that item's conversation.
      if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
        let chatId = Self.notificationChatId(from: payload)
      {
        Task { @MainActor in
          VibeRoomLinkRouter.shared.handle(target: .chat(chatId))
        }
      }
      return
    }
    switch response.actionIdentifier {
    case VibeNativeCallManager.foregroundCallAcceptAction:
      _ = VibeNativeCallEngine.shared.acceptIncoming(payload)
    case VibeNativeCallManager.foregroundCallDeclineAction:
      _ = VibeNativeCallEngine.shared.endCall(payload)
    default:
      _ = VibeNativeCallEngine.shared.handleSignal(payload)
    }
  }

  /// The chat a message/agent-event push belongs to. The server sends `chatId` at the
  /// payload root; the nested shapes are the same fallbacks the notification service
  /// extension reads, so both stay in agreement about which chat a notification names.
  private static func notificationChatId(from payload: [String: Any]) -> String? {
    func nested(_ value: Any?) -> [String: Any]? {
      if let dictionary = value as? [String: Any] { return dictionary }
      if let dictionary = value as? [AnyHashable: Any] {
        return dictionary.reduce(into: [String: Any]()) { $0[String(describing: $1.key)] = $1.value }
      }
      return nil
    }
    let candidates: [Any?] = [
      payload["chatId"],
      payload["chat_id"],
      nested(payload["data"])?["chatId"],
      nested(payload["data"])?["chat_id"],
    ]
    for candidate in candidates {
      guard let value = candidate as? String else { continue }
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { return trimmed }
    }
    return nil
  }
}
