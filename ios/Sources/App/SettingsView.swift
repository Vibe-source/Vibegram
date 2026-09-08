import CoreImage
import CoreImage.CIFilterBuiltins
import LocalAuthentication
import PhotosUI
import SwiftUI
import UIKit
import UserNotifications

private enum SettingsRoute: String, Identifiable {
  case profile
  case qr
  case privacy
  case notifications
  case devices
  case secretKey
  case appearance
  case mediaCache
  case connectedApps
  case diagnostics

  var id: String { rawValue }
}

private enum SettingsModal: String, Identifiable {
  case proxy
  case switchAccount

  var id: String { rawValue }
}

struct SettingsView: View {
  @Environment(\.colorScheme) private var colorScheme
  @EnvironmentObject private var coordinator: AppShellCoordinator
  @StateObject private var profileController = AppProfileController.shared
  @StateObject private var productionStore = SettingsProductionStore.shared

  @AppStorage("vibe.settings.notificationsEnabled") private var notificationsEnabled = true
  @AppStorage(AppThemePlateController.storageKey) private var themePlateRaw =
    AppThemePlateOption.glacier.rawValue

  @State private var activeRoute: SettingsRoute?
  @State private var activeModal: SettingsModal?
  @State private var systemNotificationsAuthorized = false
  @State private var notificationSettingsAlertMessage: String?

  private var palette: AppThemePalette {
    _ = themePlateRaw
    return AppThemePalette.resolve(for: colorScheme)
  }

  private var isDark: Bool {
    colorScheme == .dark
  }

  private var currentProfile: AppUserProfile {
    profileController.profile
      ?? AppUserProfile(
        userID: AppSessionConfig.current?.userID ?? "",
        username: AppSessionConfig.current?.username ?? AppSessionConfig.current?.userID ?? "you",
        name: AppSessionConfig.current?.name,
        phoneNumber: AppSessionConfig.current?.phoneNumber,
        bio: AppSessionConfig.current?.bio,
        dateOfBirth: AppSessionConfig.current?.dateOfBirth,
        profileImage: AppSessionConfig.current?.profileImage,
        showLastSeen: AppSessionConfig.current?.showLastSeen ?? true,
        showOnlineStatus: AppSessionConfig.current?.showOnlineStatus ?? true,
        autoDeleteTimer: AppSessionConfig.current?.autoDeleteTimer,
        privacyLastSeen: AppPrivacyChoice(rawValue: AppSessionConfig.current?.privacyLastSeen ?? "")
          ?? .everybody,
        privacyForward: AppPrivacyChoice(rawValue: AppSessionConfig.current?.privacyForward ?? "")
          ?? .everybody,
        privacyCalls: AppPrivacyChoice(rawValue: AppSessionConfig.current?.privacyCalls ?? "")
          ?? .everybody,
        privacyPhoneNumber: AppPrivacyChoice(
          rawValue: AppSessionConfig.current?.privacyPhoneNumber ?? ""
        ) ?? .everybody,
        privacyProfilePhotos: AppPrivacyChoice(
          rawValue: AppSessionConfig.current?.privacyProfilePhotos ?? ""
        ) ?? .everybody,
        privacyBio: AppPrivacyChoice(rawValue: AppSessionConfig.current?.privacyBio ?? "")
          ?? .everybody,
        privacyGifts: AppPrivacyChoice(rawValue: AppSessionConfig.current?.privacyGifts ?? "")
          ?? .everybody,
        privacyBirthday: AppPrivacyChoice(rawValue: AppSessionConfig.current?.privacyBirthday ?? "")
          ?? .everybody,
        privacySavedMusic: AppPrivacyChoice(
          rawValue: AppSessionConfig.current?.privacySavedMusic ?? ""
        ) ?? .everybody
      )
      ?? AppUserProfile(
        userID: "local-user",
        username: "you"
      )!
  }

  private var headerSubtitle: String {
    let parts = [
      currentProfile.phoneNumber?.nilIfBlank,
      "@\(currentProfile.username)",
    ].compactMap { $0 }
    return parts.joined(separator: " • ")
  }

  private var sections: [SettingsNativeSection] {
    [
      SettingsNativeSection(
        title: "ACCOUNTS",
        rows: [
          SettingsNativeRow(
            id: "switch-account",
            icon: "person.2.fill",
            label: "Switch or Add Account",
            detailText: "Current",
            toggleValue: false,
            kind: .link,
            iconColor: UIColor(red: 0 / 255, green: 122 / 255, blue: 255 / 255, alpha: 1),
            divider: true,
            destructive: false
          ),
          SettingsNativeRow(
            id: "edit-profile",
            icon: "person.crop.circle.fill",
            label: "Edit Profile",
            detailText: nil,
            toggleValue: false,
            kind: .link,
            iconColor: UIColor(red: 88 / 255, green: 86 / 255, blue: 214 / 255, alpha: 1),
            divider: true,
            destructive: false
          ),
          SettingsNativeRow(
            id: "saved-messages",
            icon: "bookmark.fill",
            label: "Saved Messages",
            detailText: nil,
            toggleValue: false,
            kind: .link,
            iconColor: UIColor(red: 52 / 255, green: 199 / 255, blue: 89 / 255, alpha: 1),
            divider: true,
            destructive: false
          ),
          SettingsNativeRow(
            id: "your-qr",
            icon: "qrcode",
            // The link is the point of this row, so show it inline instead of "Show".
            label: "Your Link & QR",
            detailText: currentProfile.shareLinkDisplay ?? "Show",
            toggleValue: false,
            kind: .link,
            iconColor: UIColor(red: 0 / 255, green: 199 / 255, blue: 190 / 255, alpha: 1),
            divider: true,
            destructive: false
          ),
          SettingsNativeRow(
            id: "proxy",
            icon: PacketProxyStore.shared.useProxy ? "ProxyShieldActive" : "ProxyShieldInactive",
            label: "Proxy",
            detailText: proxySummary,
            toggleValue: false,
            kind: .link,
            iconColor: UIColor(red: 52 / 255, green: 199 / 255, blue: 89 / 255, alpha: 1),
            divider: true,
            destructive: false
          ),
          SettingsNativeRow(
            id: "connected-apps",
            icon: "link.circle.fill",
            label: "Connected Apps",
            detailText: "GitHub · more",
            toggleValue: false,
            kind: .link,
            iconColor: UIColor(red: 36 / 255, green: 41 / 255, blue: 47 / 255, alpha: 1),
            divider: false,
            destructive: false
          ),
        ]
      ),
      SettingsNativeSection(
        title: "SETTINGS",
        rows: [
          SettingsNativeRow(
            id: "notifications",
            icon: "bell.fill",
            label: "Notifications and Sounds",
            detailText: notificationsEnabled && systemNotificationsAuthorized ? "On" : "Off",
            toggleValue: false,
            kind: .link,
            iconColor: UIColor.systemRed,
            divider: true,
            destructive: false
          ),
          SettingsNativeRow(
            id: "privacy",
            icon: "lock.shield.fill",
            label: "Privacy",
            detailText: "Manage",
            toggleValue: false,
            kind: .link,
            iconColor: UIColor(red: 0 / 255, green: 122 / 255, blue: 255 / 255, alpha: 1),
            divider: true,
            destructive: false
          ),
          SettingsNativeRow(
            id: "devices",
            icon: "desktopcomputer",
            label: "Devices",
            detailText: "Sessions",
            toggleValue: false,
            kind: .link,
            iconColor: UIColor.systemTeal,
            divider: true,
            destructive: false
          ),
          SettingsNativeRow(
            id: "secret-key",
            icon: "key.fill",
            label: "Secret Key",
            detailText: nil,
            toggleValue: false,
            kind: .link,
            iconColor: UIColor(red: 255 / 255, green: 204 / 255, blue: 0 / 255, alpha: 1),
            divider: false,
            destructive: false
          ),
        ]
      ),
      SettingsNativeSection(
        title: "APPEARANCE",
        rows: [
          SettingsNativeRow(
            id: "appearance",
            icon: "moon",
            label: "Appearance",
            detailText: appearanceSummary,
            toggleValue: false,
            kind: .link,
            iconColor: UIColor(red: 175 / 255, green: 82 / 255, blue: 222 / 255, alpha: 1),
            divider: false,
            destructive: false
          )
        ]
      ),
      SettingsNativeSection(
        title: "MEDIA & STORAGE",
        rows: [
          SettingsNativeRow(
            id: "media-cache",
            icon: "internaldrive",
            label: "Media Cache",
            detailText: "Manage",
            toggleValue: false,
            kind: .link,
            iconColor: UIColor(red: 90 / 255, green: 200 / 255, blue: 250 / 255, alpha: 1),
            divider: true,
            destructive: false
          ),
          SettingsNativeRow(
            id: "diagnostics",
            icon: "stethoscope",
            label: "Diagnostics & Logs",
            detailText: "View",
            toggleValue: false,
            kind: .link,
            iconColor: UIColor(red: 52 / 255, green: 199 / 255, blue: 89 / 255, alpha: 1),
            divider: false,
            destructive: false
          ),
        ]
      ),
    ]
  }

  var body: some View {
    SettingsNativeMainViewRepresentable(
      displayName: currentProfile.displayName,
      subtitle: headerSubtitle,
      avatarImageURI: currentProfile.profileImage,
      avatarFallbackText: currentProfile.displayName,
      avatarUserId: currentProfile.userID,
      footerText: "Vibe Mobile",
      sections: sections,
      palette: palette,
      isDark: isDark,
      onRowPress: handleRowPress,
      onRowToggle: handleRowToggle,
      onAvatarTap: nil,
      onSignOut: {
        AppRootControllerFactory.signOut()
      }
    )
    .ignoresSafeArea(.container, edges: [.top, .bottom])
    .background(palette.background.ignoresSafeArea())
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button {
          AppUITrace.notice("SettingsView toolbar qr")
          AppUIStallWatchdog.shared.updateContext("SettingsView toolbar qr")
          activeRoute = .qr
        } label: {
          Image(systemName: "qrcode")
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(palette.text)
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("Edit") {
          AppUITrace.notice("SettingsView toolbar edit")
          AppUIStallWatchdog.shared.updateContext("SettingsView toolbar edit")
          activeRoute = .profile
        }
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(colorScheme == .dark ? .white : .black)
      }
    }
    .onAppear {
      AppUITrace.notice(
        "SettingsView onAppear hasProfile=\(profileController.profile != nil) hasImage=\(currentProfile.profileImage != nil)"
      )
      AppUIStallWatchdog.shared.updateContext("SettingsView appear")
      refreshSystemNotificationStatus()
    }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
      refreshSystemNotificationStatus()
    }
    .alert(
      "Notifications Off",
      isPresented: Binding(
        get: { notificationSettingsAlertMessage != nil },
        set: { if !$0 { notificationSettingsAlertMessage = nil } }
      )
    ) {
      Button("Open Settings") {
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(notificationSettingsAlertMessage ?? "")
    }
    .task {
      AppUITrace.notice("SettingsView task profile load start")
      AppUIStallWatchdog.shared.updateContext("SettingsView profile load")
      await profileController.loadIfNeeded()
      await productionStore.load()
      AppUITrace.notice(
        "SettingsView task profile load done hasProfile=\(profileController.profile != nil)"
      )
    }
    .sheet(item: $activeModal) { modal in
      switch modal {
      case .proxy:
        NavigationStack {
          ProxySheetView(onDismiss: {
            activeModal = nil
          })
        }
      case .switchAccount:
        NavigationStack {
          AccountSwitchSheetView(
            profile: currentProfile,
            onDismiss: {
              activeModal = nil
            },
            onContinue: {
              activeModal = nil
              AppRootControllerFactory.signOut()
            }
          )
        }
      }
    }
    .navigationDestination(item: $activeRoute) { route in
      switch route {
      case .profile:
        ProfileSettingsDetailView(profileController: profileController)
      case .qr:
        UserQRSettingsDetailView(profile: currentProfile)
      case .privacy:
        PrivacySettingsDetailView(
          profileController: profileController,
          productionStore: productionStore
        )
      case .notifications:
        NotificationSettingsDetailView(
          store: productionStore,
          systemAuthorized: systemNotificationsAuthorized,
          onAuthorizationRefresh: refreshSystemNotificationStatus
        )
      case .devices:
        DevicesSettingsDetailView(store: productionStore)
      case .secretKey:
        SecretKeySettingsDetailView()
      case .appearance:
        AppearanceSettingsDetailView()
      case .mediaCache:
        MediaCacheSettingsDetailView()
      case .connectedApps:
        PlatformConnectorsView()
      case .diagnostics:
        DiagnosticsView()
      }
    }
  }

  private var appearanceSummary: String {
    let draft = ChatAppearanceDraftStore.current
    let modeTitle =
      AppAppearanceOption(rawValue: draft.mode)?.title
      ?? draft.mode.capitalized
    if let themeId = draft.themeId,
      let plate = AppThemePlateOption(rawValue: themeId)
    {
      return "\(modeTitle) • \(plate.title)"
    }
    return "\(modeTitle) • Custom"
  }

  private var proxySummary: String {
    guard PacketProxyStore.shared.useProxy else { return "Off" }
    return PacketProxyStore.shared.activeProfile?.displayName ?? "On"
  }

  private func handleRowPress(_ rowID: String) {
    AppUITrace.notice("SettingsView rowPress id=\(rowID)")
    AppUIStallWatchdog.shared.updateContext("SettingsView rowPress id=\(rowID)")
    switch rowID {
    case "switch-account":
      activeModal = .switchAccount
    case "edit-profile":
      activeRoute = .profile
    case "saved-messages":
      openSavedMessages()
    case "your-qr":
      activeRoute = .qr
    case "proxy":
      activeModal = .proxy
    case "connected-apps":
      activeRoute = .connectedApps
    case "privacy":
      activeRoute = .privacy
    case "notifications":
      activeRoute = .notifications
    case "devices":
      activeRoute = .devices
    case "secret-key":
      activeRoute = .secretKey
    case "appearance":
      activeRoute = .appearance
    case "media-cache":
      activeRoute = .mediaCache
    case "diagnostics":
      activeRoute = .diagnostics
    default:
      break
    }
  }

  private func handleRowToggle(_ rowID: String, _ value: Bool) {
    switch rowID {
    case "push-notifications":
      guard value else {
        notificationsEnabled = false
        return
      }
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        DispatchQueue.main.async {
          switch settings.authorizationStatus {
          case .denied:
            notificationSettingsAlertMessage =
              "Vibe notifications are turned off in iOS Settings. Turn them on there to enable this."
          default:
            notificationsEnabled = true
            VibeNativeCallManager.shared.refreshNotificationRegistration(reason: "settings-toggle-enable") { authorized in
              systemNotificationsAuthorized = authorized
            }
          }
        }
      }
    default:
      break
    }
  }

  private func refreshSystemNotificationStatus() {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let authorized =
        settings.authorizationStatus == .authorized
        || settings.authorizationStatus == .provisional
        || settings.authorizationStatus == .ephemeral
      DispatchQueue.main.async {
        systemNotificationsAuthorized = authorized
      }
    }
  }

  private func openSavedMessages() {
    let cachedRows = ChatEngine.shared.getChatRows(["chatId": "saved_messages"])
    NSLog(
      "[AppShellRoute] SettingsView openSavedMessages cachedRows=%d currentTab=%@",
      cachedRows.count,
      String(describing: coordinator.selectedTab)
    )
    coordinator.openChat(
      .savedMessages(initialRows: cachedRows)
    )
  }
}

private struct AccountSwitchSheetView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  let profile: AppUserProfile
  let onDismiss: () -> Void
  let onContinue: () -> Void

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var subtitle: String {
    if let phone = profile.phoneNumber?.nilIfBlank {
      return "\(phone) • @\(profile.username)"
    }
    return "@\(profile.username)"
  }

  var body: some View {
    ZStack {
      palette.background.ignoresSafeArea()

      VStack(spacing: 22) {
        VStack(spacing: 12) {
          SettingsAccountAvatar(profile: profile)

          VStack(spacing: 3) {
            Text(profile.displayName)
              .font(.system(size: 24, weight: .semibold))
              .foregroundStyle(palette.text)
              .lineLimit(1)

            Text(subtitle)
              .font(.system(size: 15, weight: .regular))
              .foregroundStyle(palette.secondaryText)
              .lineLimit(1)
          }
        }
        .padding(.top, 18)

        VStack(spacing: 0) {
          AccountSwitchActionRow(
            icon: "checkmark.circle.fill",
            iconColor: Color(uiColor: UIColor(red: 52 / 255, green: 199 / 255, blue: 89 / 255, alpha: 1)),
            title: profile.displayName,
            subtitle: "Signed in now",
            trailing: "Active",
            palette: palette
          ) {}

          Divider()
            .overlay(palette.secondaryText.opacity(0.12))
            .padding(.leading, 64)

          AccountSwitchActionRow(
            icon: "plus.circle.fill",
            iconColor: Color(uiColor: UIColor(red: 0 / 255, green: 122 / 255, blue: 255 / 255, alpha: 1)),
            title: "Add or Switch Account",
            subtitle: "Continue to Vibe sign in",
            trailing: nil,
            palette: palette,
            action: onContinue
          )
        }
        .background(
          RoundedRectangle(cornerRadius: 28, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
              RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(palette.secondaryText.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 1)
            )
        )

        Text("Vibe keeps this pass scoped to the current account session. To use another account on this device, continue to sign in with that account.")
          .font(.system(size: 14, weight: .regular))
          .foregroundStyle(palette.secondaryText)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 10)

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
    }
    .navigationTitle("Accounts")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Done") {
          onDismiss()
          dismiss()
        }
      }
    }
  }
}

private struct SettingsAccountAvatar: View {
  let profile: AppUserProfile

  var body: some View {
    ZStack {
      Circle()
        .fill(
          LinearGradient(
            colors: [
              Color(uiColor: UIColor(red: 0 / 255, green: 122 / 255, blue: 255 / 255, alpha: 1)),
              Color(uiColor: UIColor(red: 175 / 255, green: 82 / 255, blue: 222 / 255, alpha: 1)),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )

      Text(String(profile.displayName.prefix(1)).uppercased())
        .font(.system(size: 34, weight: .semibold))
        .foregroundStyle(.white)
    }
    .frame(width: 82, height: 82)
  }
}

private struct AccountSwitchActionRow: View {
  let icon: String
  let iconColor: Color
  let title: String
  let subtitle: String
  let trailing: String?
  let palette: AppThemePalette
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 14) {
        ZStack {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(iconColor)
          Image(systemName: icon)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
        }
        .frame(width: 36, height: 36)

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(palette.text)
            .lineLimit(1)
          Text(subtitle)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(palette.secondaryText)
            .lineLimit(1)
        }

        Spacer(minLength: 12)

        if let trailing {
          Text(trailing)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(palette.secondaryText)
        } else {
          Image(systemName: "chevron.right")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(palette.secondaryText.opacity(0.55))
        }
      }
      .contentShape(Rectangle())
      .padding(.horizontal, 16)
      .frame(height: 64)
    }
    .buttonStyle(.plain)
  }
}

private enum PrivacyRoute: Hashable, Identifiable {
  case blockedUsers
  case autoDelete
  case phoneNumber
  case lastSeen
  case profilePhotos
  case bio
  case gifts
  case birthday
  case savedMusic
  case forwardedMessages
  case calls

  var id: String {
    switch self {
    case .blockedUsers:
      return "blockedUsers"
    case .autoDelete:
      return "autoDelete"
    case .phoneNumber:
      return "phoneNumber"
    case .lastSeen:
      return "lastSeen"
    case .profilePhotos:
      return "profilePhotos"
    case .bio:
      return "bio"
    case .gifts:
      return "gifts"
    case .birthday:
      return "birthday"
    case .savedMusic:
      return "savedMusic"
    case .forwardedMessages:
      return "forwardedMessages"
    case .calls:
      return "calls"
    }
  }
}

private struct PrivacySettingsDetailView: View {
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject var profileController: AppProfileController
  @ObservedObject var productionStore: SettingsProductionStore

  @AppStorage("vibe.settings.biometricsEnabled") private var biometricsEnabled = false
  @AppStorage(AppThemePlateController.storageKey) private var themePlateRaw =
    AppThemePlateOption.glacier.rawValue

  @State private var blockedUsers: [AppBlockedUser] = []
  @State private var route: PrivacyRoute?
  @State private var alertMessage: String?
  @State private var isRunningBiometricsToggle = false

  private var palette: AppThemePalette {
    _ = themePlateRaw
    return AppThemePalette.resolve(for: colorScheme)
  }

  private var isDark: Bool {
    colorScheme == .dark
  }

  private var profile: AppUserProfile {
    profileController.profile ?? AppUserProfile(
      userID: AppSessionConfig.current?.userID ?? "",
      username: AppSessionConfig.current?.username ?? "you"
    )!
  }

  private var sections: [SettingsNativeSection] {
    [
      SettingsNativeSection(
        title: nil,
        rows: [
          SettingsNativeRow(
            id: "blocked-users",
            icon: "nosign",
            label: "Blocked Users",
            detailText: blockedUsers.isEmpty ? nil : "\(blockedUsers.count)",
            toggleValue: false,
            kind: .link,
            iconColor: UIColor.systemRed,
            divider: true,
            destructive: false
          ),
          SettingsNativeRow(
            id: "passcode-face-id",
            icon: "faceid",
            label: "Passcode & Face ID",
            detailText: biometricsEnabled ? "On" : "Off",
            toggleValue: false,
            kind: .link,
            iconColor: UIColor.systemGreen,
            divider: true,
            destructive: false
          ),
          SettingsNativeRow(
            id: "auto-delete",
            icon: "clock.fill",
            label: "Auto-Delete Messages",
            detailText: AppAutoDeleteOption.label(for: profile.autoDeleteTimer),
            toggleValue: false,
            kind: .link,
            iconColor: UIColor.systemPurple,
            divider: false,
            destructive: false
          ),
        ]
      ),
      SettingsNativeSection(
        title: "PRIVACY",
        rows: [
          makeChoiceRow(id: "phone-number", label: "Phone Number", value: productionStore.privacy.phoneNumber),
          makeChoiceRow(id: "last-seen", label: "Last Seen & Online", value: profile.privacyLastSeen),
          makeChoiceRow(
            id: "profile-photos",
            label: "Profile Photos",
            value: productionStore.privacy.profilePhotos
          ),
          makeChoiceRow(id: "bio", label: "Bio", value: productionStore.privacy.bio),
          makeChoiceRow(id: "gifts", label: "Gifts", value: productionStore.privacy.gifts),
          makeChoiceRow(id: "birthday", label: "Birthday", value: productionStore.privacy.birthday),
          makeChoiceRow(id: "saved-music", label: "Saved Music", value: productionStore.privacy.savedMusic),
          makeChoiceRow(
            id: "forwarded-messages",
            label: "Forwarded Messages",
            value: productionStore.privacy.forwardedMessages
          ),
          SettingsNativeRow(
            id: "calls",
            icon: "phone.fill",
            label: "Calls",
            detailText: productionStore.privacy.calls.title,
            toggleValue: false,
            kind: .link,
            iconColor: UIColor.systemGreen,
            divider: false,
            destructive: false
          ),
        ]
      ),
    ]
  }

  var body: some View {
    ScrollView(showsIndicators: false) {
      VStack(spacing: 22) {
        ForEach(sections) { section in
          SettingsNativeSectionCard(
            section: section,
            palette: palette,
            isDark: isDark,
            onPress: handleRowPress,
            onToggle: { _, _ in }
          )
        }

        Text(
          "Automatically delete messages for everyone after a period of time in all new chats you start."
        )
        .font(.system(size: 13))
        .foregroundStyle(palette.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 18)
    }
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Privacy")
    .navigationBarTitleDisplayMode(.inline)
    .task {
      await loadBlockedUsers()
    }
    .alert("Privacy", isPresented: Binding(get: {
      alertMessage != nil
    }, set: { if !$0 { alertMessage = nil } })) {
      Button("OK", role: .cancel) {
        alertMessage = nil
      }
    } message: {
      Text(alertMessage ?? "")
    }
    .navigationDestination(item: $route) { nextRoute in
      switch nextRoute {
      case .blockedUsers:
        BlockedUsersDetailView(users: blockedUsers)
      case .autoDelete:
        AutoDeleteSettingsDetailView(currentValue: profile.autoDeleteTimer) { value in
          try await profileController.updateFields(["autoDeleteTimer": value as Any])
        }
      case .phoneNumber:
        PrivacyChoiceDetailView(
          title: "Phone Number",
          currentChoice: productionStore.privacy.phoneNumber
        ) { choice in
          var next = productionStore.privacy
          next.phoneNumber = choice
          try await productionStore.updatePrivacy(next)
        }
      case .lastSeen:
        PrivacyChoiceDetailView(
          title: "Last Seen & Online",
          currentChoice: profile.privacyLastSeen
        ) { choice in
          try await profileController.updateFields([
            "privacyLastSeen": choice.rawValue,
            "showLastSeen": choice != .nobody,
            "showOnlineStatus": choice != .nobody,
          ])
        }
      case .profilePhotos:
        PrivacyChoiceDetailView(
          title: "Profile Photos",
          currentChoice: productionStore.privacy.profilePhotos
        ) { choice in
          var next = productionStore.privacy
          next.profilePhotos = choice
          try await productionStore.updatePrivacy(next)
        }
      case .bio:
        PrivacyChoiceDetailView(title: "Bio", currentChoice: productionStore.privacy.bio) { choice in
          var next = productionStore.privacy
          next.bio = choice
          try await productionStore.updatePrivacy(next)
        }
      case .gifts:
        PrivacyChoiceDetailView(title: "Gifts", currentChoice: productionStore.privacy.gifts) { choice in
          var next = productionStore.privacy
          next.gifts = choice
          try await productionStore.updatePrivacy(next)
        }
      case .birthday:
        PrivacyChoiceDetailView(title: "Birthday", currentChoice: productionStore.privacy.birthday) {
          choice in
          var next = productionStore.privacy
          next.birthday = choice
          try await productionStore.updatePrivacy(next)
        }
      case .savedMusic:
        PrivacyChoiceDetailView(
          title: "Saved Music",
          currentChoice: productionStore.privacy.savedMusic
        ) { choice in
          var next = productionStore.privacy
          next.savedMusic = choice
          try await productionStore.updatePrivacy(next)
        }
      case .forwardedMessages:
        PrivacyChoiceDetailView(
          title: "Forwarded Messages",
          currentChoice: productionStore.privacy.forwardedMessages
        ) { choice in
          var next = productionStore.privacy
          next.forwardedMessages = choice
          try await productionStore.updatePrivacy(next)
        }
      case .calls:
        PrivacyChoiceDetailView(title: "Calls", currentChoice: productionStore.privacy.calls) { choice in
          var next = productionStore.privacy
          next.calls = choice
          try await productionStore.updatePrivacy(next)
        }
      }
    }
  }

  private func makeChoiceRow(id: String, label: String, value: AppPrivacyChoice) -> SettingsNativeRow
  {
    SettingsNativeRow(
      id: id,
      icon: "person.crop.circle.fill",
      label: label,
      detailText: value.title,
      toggleValue: false,
      kind: .link,
      iconColor: UIColor.systemBlue,
      divider: true,
      destructive: false
    )
  }

  private func handleRowPress(_ rowID: String) {
    switch rowID {
    case "blocked-users":
      route = .blockedUsers
    case "passcode-face-id":
      Task {
        await toggleBiometrics()
      }
    case "auto-delete":
      route = .autoDelete
    case "phone-number":
      route = .phoneNumber
    case "last-seen":
      route = .lastSeen
    case "profile-photos":
      route = .profilePhotos
    case "bio":
      route = .bio
    case "gifts":
      route = .gifts
    case "birthday":
      route = .birthday
    case "saved-music":
      route = .savedMusic
    case "forwarded-messages":
      route = .forwardedMessages
    case "calls":
      route = .calls
    default:
      break
    }
  }

  @MainActor
  private func toggleBiometrics() async {
    guard !isRunningBiometricsToggle else { return }
    isRunningBiometricsToggle = true
    defer { isRunningBiometricsToggle = false }

    if biometricsEnabled {
      biometricsEnabled = false
      return
    }

    let context = LAContext()
    var authError: NSError?
    guard
      context.canEvaluatePolicy(
        .deviceOwnerAuthenticationWithBiometrics,
        error: &authError
      )
    else {
      alertMessage = authError?.localizedDescription ?? "This device does not support biometrics."
      return
    }

    do {
      let result = try await context.evaluatePolicy(
        .deviceOwnerAuthenticationWithBiometrics,
        localizedReason: "Authenticate to enable Face ID / Touch ID"
      )
      biometricsEnabled = result
    } catch let evaluationError {
      alertMessage = evaluationError.localizedDescription
    }
  }

  @MainActor
  private func loadBlockedUsers() async {
    guard let config = AppSessionConfig.current else { return }
    do {
      blockedUsers = try await AppBlockedUsersService.fetch(config: config)
    } catch {
      blockedUsers = []
    }
  }
}

private struct PrivacyChoiceDetailView: View {
  @Environment(\.dismiss) private var dismiss
  let title: String
  let currentChoice: AppPrivacyChoice
  let onSelect: (AppPrivacyChoice) async throws -> Void

  @State private var selectedChoice: AppPrivacyChoice
  @State private var saveError: String?
  @State private var isSaving = false

  init(
    title: String,
    currentChoice: AppPrivacyChoice,
    onSelect: @escaping (AppPrivacyChoice) async throws -> Void
  ) {
    self.title = title
    self.currentChoice = currentChoice
    self.onSelect = onSelect
    _selectedChoice = State(initialValue: currentChoice)
  }

  var body: some View {
    List {
      ForEach(AppPrivacyChoice.allCases) { choice in
        Button {
          Task {
            await save(choice)
          }
        } label: {
          HStack {
            Text(choice.title)
              .foregroundStyle(.primary)
            Spacer()
            if choice == selectedChoice {
              Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.tint)
            }
          }
        }
        .disabled(isSaving)
      }

      if let saveError {
        Section {
          Text(saveError)
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
  }

  @MainActor
  private func save(_ choice: AppPrivacyChoice) async {
    guard !isSaving else { return }
    isSaving = true
    saveError = nil
    do {
      try await onSelect(choice)
      selectedChoice = choice
      dismiss()
    } catch {
      saveError = error.localizedDescription
    }
    isSaving = false
  }
}

private struct NotificationSettingsDetailView: View {
  @ObservedObject var store: SettingsProductionStore
  let systemAuthorized: Bool
  let onAuthorizationRefresh: () -> Void

  @AppStorage("vibe.settings.notificationsEnabled") private var notificationsEnabled = true
  @State private var saveError: String?
  @State private var showPermissionNotice = false
  @State private var hasPresentedPermissionNotice = false
  @State private var isUpdatingMasterSwitch = false
  @State private var awaitingSystemSettingsReturn = false

  var body: some View {
    List {
      Section {
        Toggle(
          "Notifications",
          isOn: Binding(
            get: { notificationsEnabled && systemAuthorized },
            set: setMasterEnabled
          )
        )
        .disabled(isUpdatingMasterSwitch)
      }

      Section("MESSAGE NOTIFICATIONS") {
        categoryRow("Private Chats", keyPath: \.privateChats)
        categoryRow("Group Chats", keyPath: \.groupChats)
        categoryRow("Channels", keyPath: \.channels)
        categoryRow("Stories", keyPath: \.stories)
        categoryRow("Reactions", keyPath: \.reactions)
      }

      Section("IN-APP NOTIFICATIONS") {
        preferenceToggle("Sounds", keyPath: \.inAppSounds)
        preferenceToggle("Vibrate", keyPath: \.inAppVibrate)
        preferenceToggle("Preview", keyPath: \.inAppPreview)
        preferenceToggle("Names on Lock Screen", keyPath: \.namesOnLockScreen)
      }

      if let message = saveError ?? store.errorMessage {
        Section {
          Text(message).foregroundStyle(.red)
        }
      }
    }
    .disabled(store.isSaving)
    .listStyle(.insetGrouped)
    .navigationTitle("Notifications")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      refreshPermissionState(promptIfUndetermined: true)
    }
    .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
      refreshPermissionState(
        promptIfUndetermined: false,
        enableAfterSettingsReturn: awaitingSystemSettingsReturn
      )
      awaitingSystemSettingsReturn = false
    }
    .alert("Notifications Are Off", isPresented: $showPermissionNotice) {
      Button("Open Settings") {
        awaitingSystemSettingsReturn = true
        openSystemSettings()
      }
      Button("Not Now", role: .cancel) {}
    } message: {
      Text("Allow notifications in iOS Settings to receive alerts from Vibe.")
    }
  }

  private func openSystemSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }

  private func setMasterEnabled(_ enabled: Bool) {
    guard !isUpdatingMasterSwitch else { return }
    if enabled {
      enableNotifications()
    } else {
      updateMasterPreference(false)
    }
  }

  private func enableNotifications() {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      DispatchQueue.main.async {
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
          updateMasterPreference(true)
          VibeNativeCallManager.shared.refreshNotificationRegistration(
            reason: "settings-master-enable"
          )
        case .notDetermined:
          requestNativePermission()
        case .denied:
          notificationsEnabled = false
          presentPermissionNotice(force: true)
          onAuthorizationRefresh()
        @unknown default:
          notificationsEnabled = false
          presentPermissionNotice(force: true)
          onAuthorizationRefresh()
        }
      }
    }
  }

  private func requestNativePermission() {
    VibeNativeCallManager.shared.refreshNotificationRegistration(
      reason: "settings-native-permission"
    ) { granted in
      onAuthorizationRefresh()
      if granted {
        updateMasterPreference(true)
      } else {
        notificationsEnabled = false
      }
    }
  }

  private func refreshPermissionState(
    promptIfUndetermined: Bool,
    enableAfterSettingsReturn: Bool = false
  ) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      DispatchQueue.main.async {
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
          hasPresentedPermissionNotice = false
          if enableAfterSettingsReturn {
            updateMasterPreference(true)
          } else if notificationsEnabled {
            VibeNativeCallManager.shared.refreshNotificationRegistration(
              reason: "settings-notifications-appear"
            )
          }
          onAuthorizationRefresh()
        case .notDetermined:
          if promptIfUndetermined {
            requestNativePermission()
          } else {
            onAuthorizationRefresh()
          }
        case .denied:
          notificationsEnabled = false
          presentPermissionNotice()
          onAuthorizationRefresh()
        @unknown default:
          notificationsEnabled = false
          presentPermissionNotice()
          onAuthorizationRefresh()
        }
      }
    }
  }

  private func presentPermissionNotice(force: Bool = false) {
    guard force || !hasPresentedPermissionNotice else { return }
    hasPresentedPermissionNotice = true
    showPermissionNotice = true
  }

  private func updateMasterPreference(_ enabled: Bool) {
    guard !isUpdatingMasterSwitch else { return }
    let previous = notificationsEnabled
    notificationsEnabled = enabled
    isUpdatingMasterSwitch = true
    saveError = nil

    Task { @MainActor in
      var next = store.notifications
      next.privateChats.enabled = enabled
      next.groupChats.enabled = enabled
      next.channels.enabled = enabled
      next.stories.enabled = enabled
      next.reactions.enabled = enabled

      do {
        try await store.updateNotifications(next)
      } catch {
        notificationsEnabled = previous
        saveError = error.localizedDescription
      }
      isUpdatingMasterSwitch = false
    }
  }

  private func categoryRow(
    _ title: String,
    keyPath: WritableKeyPath<SettingsNotificationPreferences, SettingsNotificationCategory>
  ) -> some View {
    let category = store.notifications[keyPath: keyPath]
    return NavigationLink {
      NotificationCategoryDetailView(title: title, store: store, keyPath: keyPath)
    } label: {
      HStack {
        Text(title)
        Spacer()
        Text(category.enabled ? "On" : "Off")
          .foregroundStyle(.secondary)
      }
    }
  }

  private func preferenceToggle(
    _ title: String,
    keyPath: WritableKeyPath<SettingsNotificationPreferences, Bool>
  ) -> some View {
    Toggle(title, isOn: Binding(
      get: { store.notifications[keyPath: keyPath] },
      set: { value in
        Task {
          var next = store.notifications
          next[keyPath: keyPath] = value
          do { try await store.updateNotifications(next) }
          catch { saveError = error.localizedDescription }
        }
      }
    ))
  }
}

private struct NotificationCategoryDetailView: View {
  let title: String
  @ObservedObject var store: SettingsProductionStore
  let keyPath: WritableKeyPath<SettingsNotificationPreferences, SettingsNotificationCategory>

  @State private var saveError: String?

  var body: some View {
    List {
      Section {
        categoryToggle("Notifications", keyPath: \.enabled)
      }
      Section("ALERT CONTENT") {
        categoryToggle("Message Preview", keyPath: \.preview)
        categoryToggle("Sound", keyPath: \.sound)
      }
      if let saveError {
        Section { Text(saveError).foregroundStyle(.red) }
      }
    }
    .disabled(store.isSaving)
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
  }

  private func categoryToggle(
    _ title: String,
    keyPath categoryKeyPath: WritableKeyPath<SettingsNotificationCategory, Bool>
  ) -> some View {
    Toggle(title, isOn: Binding(
      get: { store.notifications[keyPath: keyPath][keyPath: categoryKeyPath] },
      set: { value in
        Task {
          var next = store.notifications
          next[keyPath: keyPath][keyPath: categoryKeyPath] = value
          do { try await store.updateNotifications(next) }
          catch { saveError = error.localizedDescription }
        }
      }
    ))
  }
}

private struct DevicesSettingsDetailView: View {
  @ObservedObject var store: SettingsProductionStore
  @State private var pendingRevocation: SettingsDeviceSession?
  @State private var revokeError: String?

  private var otherSessions: [SettingsDeviceSession] {
    store.sessions.filter { !$0.isCurrent }
  }

  var body: some View {
    List {
      if store.isLoading && store.sessions.isEmpty {
        Section { HStack { Spacer(); ProgressView(); Spacer() } }
      }

      if let current = store.currentSession {
        Section("THIS DEVICE") { sessionRow(current) }
      }

      Section("ACTIVE SESSIONS") {
        if otherSessions.isEmpty {
          Text("No other active sessions")
            .foregroundStyle(.secondary)
        } else {
          ForEach(otherSessions) { session in
            Button { pendingRevocation = session } label: { sessionRow(session) }
              .buttonStyle(.plain)
          }
        }
      }

      Section {
        Text("If you do not recognize a session, revoke it immediately and review your account security.")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }

      if let message = revokeError ?? store.errorMessage {
        Section { Text(message).foregroundStyle(.red) }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Devices")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await store.load() }
    .confirmationDialog(
      "Revoke this session?",
      isPresented: Binding(
        get: { pendingRevocation != nil },
        set: { if !$0 { pendingRevocation = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Revoke Session", role: .destructive) {
        guard let session = pendingRevocation else { return }
        pendingRevocation = nil
        Task {
          do { try await store.revokeSession(id: session.id) }
          catch { revokeError = error.localizedDescription }
        }
      }
      Button("Cancel", role: .cancel) { pendingRevocation = nil }
    } message: {
      Text(pendingRevocation.map { "\($0.name) will be signed out of Vibe." } ?? "")
    }
  }

  private func sessionRow(_ session: SettingsDeviceSession) -> some View {
    HStack(spacing: 13) {
      Image(systemName: deviceSymbol(for: session.platform))
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(.white)
        .frame(width: 38, height: 38)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(session.name).font(.body.weight(.medium))
          if session.isCurrent {
            Text("Current")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.green)
          }
        }
        Text("\(session.platform) · \(session.lastSeenDescription)")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if !session.isCurrent {
        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 3)
    .accessibilityElement(children: .combine)
  }

  private func deviceSymbol(for platform: String) -> String {
    let value = platform.lowercased()
    if value.contains("ios") || value.contains("iphone") { return "iphone" }
    if value.contains("mac") { return "laptopcomputer" }
    if value.contains("web") { return "globe" }
    return "desktopcomputer"
  }
}

private enum AppAutoDeleteOption: CaseIterable, Identifiable {
  case off
  case oneHour
  case oneDay
  case oneWeek

  var id: String { title }

  var minutes: Int? {
    switch self {
    case .off:
      return nil
    case .oneHour:
      return 60
    case .oneDay:
      return 1_440
    case .oneWeek:
      return 10_080
    }
  }

  var title: String {
    switch self {
    case .off:
      return "Off"
    case .oneHour:
      return "1 Hour"
    case .oneDay:
      return "1 Day"
    case .oneWeek:
      return "1 Week"
    }
  }

  static func option(for value: Int?) -> AppAutoDeleteOption {
    switch value {
    case 60:
      return .oneHour
    case 1_440:
      return .oneDay
    case 10_080:
      return .oneWeek
    default:
      return .off
    }
  }

  static func label(for value: Int?) -> String {
    option(for: value).title
  }
}

private struct AutoDeleteSettingsDetailView: View {
  @Environment(\.dismiss) private var dismiss
  let currentValue: Int?
  let onSelect: (Int?) async throws -> Void

  @State private var selectedOption: AppAutoDeleteOption
  @State private var isSaving = false
  @State private var saveError: String?

  init(currentValue: Int?, onSelect: @escaping (Int?) async throws -> Void) {
    self.currentValue = currentValue
    self.onSelect = onSelect
    _selectedOption = State(initialValue: AppAutoDeleteOption.option(for: currentValue))
  }

  var body: some View {
    List {
      ForEach(AppAutoDeleteOption.allCases) { option in
        Button {
          Task {
            await save(option)
          }
        } label: {
          HStack {
            Text(option.title)
              .foregroundStyle(.primary)
            Spacer()
            if option == selectedOption {
              Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.tint)
            }
          }
        }
        .disabled(isSaving)
      }

      if let saveError {
        Section {
          Text(saveError)
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("Auto-Delete")
    .navigationBarTitleDisplayMode(.inline)
  }

  @MainActor
  private func save(_ option: AppAutoDeleteOption) async {
    guard !isSaving else { return }
    isSaving = true
    saveError = nil
    do {
      try await onSelect(option.minutes)
      selectedOption = option
      dismiss()
    } catch {
      saveError = error.localizedDescription
    }
    isSaving = false
  }
}

private struct AppearanceSettingsDetailView: View {
  var body: some View {
    // Full Appearance product: hub + inner pages (themes, color editor, corners…).
    AppearanceHubView()
  }
}

private struct AppearanceDevicePreview: View {
  let appearance: AppAppearanceOption
  let plate: AppThemePlateOption

  @Environment(\.colorScheme) private var systemColorScheme

  private var previewScheme: ColorScheme {
    switch appearance {
    case .light: return .light
    case .dark: return .dark
    case .system: return systemColorScheme
    }
  }

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: previewScheme, plate: plate)
  }

  var body: some View {
    VStack(spacing: 10) {
      ZStack {
        RoundedRectangle(cornerRadius: 32, style: .continuous)
          .fill(Color.black)
          .frame(width: 178, height: 318)

        RoundedRectangle(cornerRadius: 27, style: .continuous)
          .fill(palette.background)
          .frame(width: 168, height: 308)
          .overlay {
            VStack(spacing: 0) {
              Capsule()
                .fill(Color.black)
                .frame(width: 58, height: 17)
                .padding(.top, 7)

              HStack {
                Circle().fill(palette.accent).frame(width: 24, height: 24)
                Text("Vibe")
                  .font(.system(size: 10, weight: .semibold))
                  .foregroundStyle(palette.text)
                Spacer()
                Image(systemName: "ellipsis")
                  .font(.system(size: 9, weight: .bold))
                  .foregroundStyle(palette.secondaryText)
              }
              .padding(.horizontal, 13)
              .padding(.top, 12)

              VStack(spacing: 8) {
                previewBubble("Your appearance updates", mine: false)
                previewBubble("across Vibe instantly.", mine: true)
              }
              .frame(maxHeight: .infinity)
              .padding(.horizontal, 12)

              HStack(spacing: 7) {
                Image(systemName: "plus.circle.fill")
                Text("Message")
                Spacer()
                Image(systemName: "mic.fill")
              }
              .font(.system(size: 9))
              .foregroundStyle(palette.secondaryText)
              .padding(.horizontal, 12)
              .frame(height: 32)
              .background(palette.card)
            }
            .clipShape(RoundedRectangle(cornerRadius: 27, style: .continuous))
          }
      }

      Text("Live preview · \(appearance.title) · \(plate.title)")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(palette.secondaryText)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Appearance preview, \(appearance.title), \(plate.title)")
  }

  private func previewBubble(_ text: String, mine: Bool) -> some View {
    Text(text)
      .font(.system(size: 9, weight: .medium))
      .foregroundStyle(mine ? Color.white : palette.text)
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(mine ? palette.accent : palette.card)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
  }
}

private struct ThemePlateCard: View {
  let option: AppThemePlateOption
  let isSelected: Bool
  let colorScheme: ColorScheme

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme, plate: option)
  }

  private var chatPreviewAppearance: ChatListAppearance {
    ChatListAppearance.from(raw: [
      "theme": colorScheme == .dark ? "dark" : "light",
      "backgroundMode": "gradient",
      "wallpaperOpacity": 1.0,
      "nativeThemeId": option.rawValue,
      "nativeThemeIsDark": colorScheme == .dark,
    ])
  }

  var body: some View {
    let appearance = chatPreviewAppearance

    VStack(alignment: .leading, spacing: 14) {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(
          LinearGradient(
            colors: themeColors(appearance.wallpaperGradient, fallback: palette.backgroundUIColor),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .frame(height: 118)
        .overlay(alignment: .topTrailing) {
          if isSelected {
            Image(systemName: "checkmark.circle.fill")
              .font(.system(size: 18))
              .foregroundStyle(palette.accent)
              .padding(10)
          }
        }
        .overlay(alignment: .bottomLeading) {
          VStack(alignment: .leading, spacing: 6) {
            Capsule()
              .fill(
                LinearGradient(
                  colors: themeColors(
                    appearance.bubbleThemGradient,
                    fallback: appearance.bubbleThemColor
                  ),
                  startPoint: .leading,
                  endPoint: .trailing
                )
              )
              .frame(width: 54, height: 8)
            Capsule()
              .fill(
                LinearGradient(
                  colors: themeColors(
                    appearance.bubbleMeGradient,
                    fallback: palette.bubbleMeUIColor
                  ),
                  startPoint: .leading,
                  endPoint: .trailing
                )
              )
              .frame(width: 72, height: 8)
          }
          .padding(14)
        }

      Text(option.title)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(palette.text)
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .fill(palette.card)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(isSelected ? palette.accent : palette.border, lineWidth: isSelected ? 1.5 : 1)
    )
  }

  private func themeColors(_ colors: [UIColor], fallback: UIColor) -> [Color] {
    let resolved: [UIColor]
    if colors.count >= 2 {
      resolved = colors
    } else if let first = colors.first {
      resolved = [first, first]
    } else {
      resolved = [fallback, fallback]
    }
    return resolved.map { Color(uiColor: $0) }
  }
}

/// Contacts-style Edit Profile (Cancel / Done, Set New Photo, name split, bio, rows).
private struct ProfileSettingsDetailView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @ObservedObject var profileController: AppProfileController

  @State private var draft = AppUserProfileDraft(profile: nil)
  @State private var firstName: String = ""
  @State private var lastName: String = ""
  @State private var saveError: String?
  @State private var localAvatarImage: UIImage?
  @State private var photoPickerItem: PhotosPickerItem?
  @State private var isUploadingPhoto = false
  @State private var birthdayDate: Date?

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var baselineDraft: AppUserProfileDraft {
    AppUserProfileDraft(profile: profileController.profile)
  }

  private var composedName: String {
    [firstName, lastName]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private var isDirty: Bool {
    var d = draft
    d.name = composedName
    return d != baselineDraft || localAvatarImage != nil
  }

  private var userId: String {
    profileController.profile?.userID ?? AppSessionConfig.current?.userID ?? ""
  }

  private var avatarGradient: (UIColor, UIColor) {
    ChatProfileAppearanceStore.avatarColors(
      title: composedName.isEmpty ? draft.username : composedName,
      peerUserId: userId.isEmpty ? nil : userId,
      chatId: nil
    )
  }

  var body: some View {
    ScrollView(showsIndicators: false) {
      VStack(spacing: 18) {
        avatarBlock

        // Order matches Contacts-style: photo → names → bio → birthday → number/username/color.
        nameCard
        helperText("Enter your name and add an optional profile photo.")

        bioCard
        helperText("A few words about you.")

        // Backend has date_of_birth — keep birthday.
        birthdayRow
        helperText("Only your contacts can see your birthday.")

        detailsCard

        if let saveError {
          Text(saveError)
            .font(.footnote)
            .foregroundStyle(palette.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .padding(.bottom, 40)
    }
    .background(palette.background.ignoresSafeArea())
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(true)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Cancel") { dismiss() }
          .foregroundStyle(palette.text)
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button(profileController.isLoading || isUploadingPhoto ? "Saving" : "Done") {
          Task { await saveProfile() }
        }
        .fontWeight(.semibold)
        .disabled(
          profileController.isLoading
            || isUploadingPhoto
            || draft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (!isDirty && !isUploadingPhoto && !profileController.isLoading)
        )
      }
    }
    .onAppear {
      seedFromProfile()
    }
    .onChange(of: photoPickerItem) { _, item in
      guard let item else { return }
      Task { await loadPickedPhoto(item) }
    }
  }

  // MARK: - Blocks

  private var avatarBlock: some View {
    VStack(spacing: 10) {
      ZStack {
        Circle()
          .fill(
            LinearGradient(
              colors: [Color(uiColor: avatarGradient.0), Color(uiColor: avatarGradient.1)],
              startPoint: .top,
              endPoint: .bottom
            )
          )
        if let localAvatarImage {
          Image(uiImage: localAvatarImage)
            .resizable()
            .scaledToFill()
        } else if let uri = draft.profileImage, !uri.isEmpty {
          EditProfileRemoteAvatar(uri: uri)
        } else {
          Text(avatarInitial)
            .font(.system(size: 42, weight: .bold))
            .foregroundStyle(.white)
        }

        // Custom drawn spinner (not system ProgressView) while upload is in flight.
        if isUploadingPhoto {
          Circle()
            .fill(Color.black.opacity(0.42))
          EditProfileDrawingSpinner(size: 42, lineWidth: 3.2)
        }
      }
      .frame(width: 120, height: 120)
      .clipShape(Circle())
      .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 1))

      PhotosPicker(selection: $photoPickerItem, matching: .images) {
        Text(isUploadingPhoto ? "Uploading…" : "Set New Photo")
          .font(.system(size: 17, weight: .regular))
          .foregroundStyle(Color.accentColor)
      }
      .disabled(isUploadingPhoto)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 8)
  }

  private var nameCard: some View {
    VStack(spacing: 0) {
      TextField("First Name", text: $firstName)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
      Divider().padding(.leading, 16)
      TextField("Last Name", text: $lastName)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
    .background(roundedCard)
  }

  private var bioCard: some View {
    TextField("Bio", text: $draft.bio, axis: .vertical)
      .lineLimit(2...5)
      .padding(.horizontal, 16)
      .padding(.vertical, 14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(roundedCard)
  }

  private var birthdayRow: some View {
    HStack(spacing: 12) {
      editRowIcon("birthday.cake")

      Text("Birthday")
        .font(.system(size: 17))
        .foregroundStyle(palette.text)

      Spacer()

      if let birthdayDate {
        DatePicker(
          "",
          selection: Binding(
            get: { birthdayDate },
            set: { next in
              self.birthdayDate = next
              draft.dateOfBirth = Self.birthdayFormatter.string(from: next)
            }
          ),
          displayedComponents: .date
        )
        .labelsHidden()
      } else {
        Button("Add") {
          let today = Date()
          birthdayDate = today
          draft.dateOfBirth = Self.birthdayFormatter.string(from: today)
        }
        .foregroundStyle(palette.secondaryText)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(roundedCard)
  }

  private var detailsCard: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        editRowIcon("phone")
        Text("Number")
          .font(.system(size: 17))
          .foregroundStyle(palette.text)
        TextField("Add", text: $draft.phoneNumber)
          .keyboardType(.phonePad)
          .multilineTextAlignment(.trailing)
          .font(.system(size: 17))
          .foregroundStyle(palette.secondaryText)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)

      Divider().padding(.leading, 52)

      HStack(spacing: 12) {
        editRowIcon("at")
        Text("Username")
          .font(.system(size: 17))
          .foregroundStyle(palette.text)
        TextField("@username", text: $draft.username)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .multilineTextAlignment(.trailing)
          .font(.system(size: 17))
          .foregroundStyle(palette.secondaryText)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)

      Divider().padding(.leading, 52)

      NavigationLink {
        AppearanceSettingsDetailView()
      } label: {
        HStack(spacing: 12) {
          editRowIcon("paintbrush")
          Text("Your Color")
            .font(.system(size: 17))
            .foregroundStyle(palette.text)
          Spacer()
          Circle()
            .fill(ChatAppearanceDraftStore.current.accentColor)
            .frame(width: 18, height: 18)
          Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(palette.secondaryText.opacity(0.55))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      }
    }
    .background(roundedCard)
  }

  /// Monochrome / blended icons — same spirit as Settings list (not color tiles).
  private func editRowIcon(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(.system(size: 17, weight: .regular))
      .foregroundStyle(palette.secondaryText.opacity(colorScheme == .dark ? 0.92 : 0.78))
      .frame(width: 24, height: 24)
  }

  private var roundedCard: some View {
    RoundedRectangle(cornerRadius: 14, style: .continuous)
      .fill(palette.card)
  }

  private var avatarInitial: String {
    let seed = firstName.isEmpty ? (draft.username.isEmpty ? "U" : draft.username) : firstName
    return String(seed.prefix(1)).uppercased()
  }

  private static let birthdayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()

  private func helperText(_ text: String) -> some View {
    Text(text)
      .font(.system(size: 13))
      .foregroundStyle(palette.secondaryText)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 4)
  }

  private func seedFromProfile() {
    draft = baselineDraft
    let parts = draft.name.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    firstName = parts.first.map(String.init) ?? ""
    lastName = parts.count > 1 ? String(parts[1]) : ""
    if let raw = draft.dateOfBirth.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
      let parsed = Self.birthdayFormatter.date(from: raw)
    {
      birthdayDate = parsed
    } else {
      birthdayDate = nil
    }
    localAvatarImage = nil
  }

  @MainActor
  private func loadPickedPhoto(_ item: PhotosPickerItem) async {
    isUploadingPhoto = true
    defer {
      isUploadingPhoto = false
      photoPickerItem = nil
    }
    do {
      guard let data = try await item.loadTransferable(type: Data.self),
        let image = UIImage(data: data)
      else {
        saveError = "Couldn't read that photo."
        return
      }
      // Paint immediately in the edit screen.
      localAvatarImage = image

      guard let config = AppSessionConfig.current else {
        saveError = "Not signed in."
        return
      }
      let jpeg = image.jpegData(compressionQuality: 0.85) ?? data
      // Multipart: user_id + type=image + file (avatar.jpg).
      let remoteURL = try await ChatRoomCreateService.uploadAvatar(
        imageData: jpeg,
        config: config
      )
      // Seed memory/disk cache so Settings header + tab bar hit instantly.
      ChatAvatarImageStore.replaceHero(image, for: remoteURL)
      draft.profileImage = remoteURL
      // JSON profile update — profileImage is the remote URL string only.
      _ = try await AppProfileController.shared.updateFields(["profileImage": remoteURL])
      // Keep local paint; Settings / tabs observe AppProfileController.$profile.
      localAvatarImage = image
      saveError = nil
    } catch {
      saveError = error.localizedDescription
    }
  }

  @MainActor
  private func saveProfile() async {
    saveError = nil
    draft.name = composedName
    do {
      try await profileController.update(draft)
      dismiss()
    } catch {
      saveError = error.localizedDescription
    }
  }
}

/// Remote avatar for Edit Profile (cached when possible).
private struct EditProfileRemoteAvatar: View {
  let uri: String
  @State private var image: UIImage?

  var body: some View {
    Group {
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        Color.clear
      }
    }
    .task(id: uri) {
      if let cached = ChatAvatarImageStore.cached(for: uri) {
        image = cached
        return
      }
      image = await ChatAvatarImageStore.load(from: uri)
    }
  }
}

/// Custom stroked arc spinner — drawn, not UIActivityIndicator / ProgressView.
private struct EditProfileDrawingSpinner: View {
  var size: CGFloat = 40
  var lineWidth: CGFloat = 3
  @State private var rotation: Double = 0

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
      let t = context.date.timeIntervalSinceReferenceDate
      let angle = (t.truncatingRemainder(dividingBy: 1.0) / 1.0) * 360.0
      ZStack {
        Circle()
          .stroke(Color.white.opacity(0.18), lineWidth: lineWidth)
        Circle()
          .trim(from: 0.08, to: 0.72)
          .stroke(
            AngularGradient(
              colors: [
                Color.white.opacity(0.15),
                Color.white.opacity(0.95),
              ],
              center: .center
            ),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
          )
          .rotationEffect(.degrees(angle))
      }
      .frame(width: size, height: size)
    }
  }
}

private struct UserQRSettingsDetailView: View {
  @Environment(\.colorScheme) private var colorScheme
  let profile: AppUserProfile
  @State private var isSharing = false

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  /// The QR encodes the SHARE LINK, not the raw user id: scanning it in any camera app
  /// opens the link, which opens Vibe. `vibe:<uuid>` only ever worked inside Vibe.
  private var qrCodeValue: String {
    profile.shareLink ?? "vibe:\(profile.userID)"
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView(showsIndicators: false) {
        VStack(spacing: 32) {
          VStack(spacing: 24) {
            QRCodePanel(value: qrCodeValue, palette: palette)
              .scaleEffect(1.05)

            VStack(spacing: 8) {
              Text(profile.displayName)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(palette.text)

              Text("@\(profile.username)")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(palette.secondaryText)
            }
          }
          .padding(.top, 40)

          if let link = profile.shareLink, let display = profile.shareLinkDisplay {
            VStack(alignment: .leading, spacing: 16) {
              Text("YOUR LINK")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(palette.secondaryText)
                .padding(.leading, 4)

              HStack(spacing: 12) {
                Text(display)
                  .font(.system(size: 16, weight: .medium))
                  .foregroundStyle(palette.text)
                  .lineLimit(1)
                  .minimumScaleFactor(0.7)

                Spacer(minLength: 0)

                Button {
                  UIPasteboard.general.string = link
                  AppToastController.shared.show("Link copied")
                } label: {
                  Image(systemName: "doc.on.doc")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.accent)
                }

                Button {
                  isSharing = true
                } label: {
                  Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.accent)
                }
              }
              .padding(16)
              .background(palette.card)
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

              Text("Anyone with this link can open a chat with you.")
                .font(.system(size: 13))
                .foregroundStyle(palette.secondaryText)
                .padding(.leading, 4)
            }
            .padding(.horizontal, 24)
            .sheet(isPresented: $isSharing) {
              AppShareSheet(items: [link])
            }
          }

          VStack(alignment: .leading, spacing: 16) {
             Text("YOUR UNIQUE ID")
               .font(.system(size: 11, weight: .bold))
               .tracking(1.2)
               .foregroundStyle(palette.secondaryText)
               .padding(.leading, 4)

             HStack {
               Text(profile.userID)
                 .font(.system(.body, design: .monospaced))
                 .foregroundStyle(palette.text)
                 .lineLimit(1)

               Spacer()

               Button {
                 UIPasteboard.general.string = profile.userID
                 AppToastController.shared.show("ID Copied")
               } label: {
                 Image(systemName: "doc.on.doc")
                   .font(.system(size: 14, weight: .medium))
                   .foregroundStyle(palette.accent)
               }
             }
             .padding(16)
             .background(palette.card)
             .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          }
          .padding(.horizontal, 24)
        }
        .padding(.bottom, 32)
      }
    }
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Your QR")
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// Thin UIActivityViewController wrapper for sharing a link out of SwiftUI.
struct AppShareSheet: UIViewControllerRepresentable {
  let items: [Any]

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: items, applicationActivities: nil)
  }

  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct SecretKeySettingsDetailView: View {
  @Environment(\.colorScheme) private var colorScheme
  @State private var isRevealed = false
  @State private var copied = false

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var secretKey: String {
    SecureKeyStore.shared.retrieveSecret(key: "loginSecret") ?? ""
  }

  var body: some View {
    VStack(spacing: 0) {
      ScrollView(showsIndicators: false) {
        VStack(spacing: 32) {
          QRCodePanel(value: secretKey, palette: palette)
            .padding(.top, 40)

          VStack(alignment: .leading, spacing: 16) {
            Text("YOUR SECRET KEY")
              .font(.system(size: 11, weight: .bold))
              .tracking(1.2)
              .foregroundStyle(palette.secondaryText)
              .padding(.leading, 4)

            ZStack {
              // The real key (single line, no wrap)
              Text(secretKey.isEmpty ? "No secret key stored" : secretKey)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 20)

              // The Metal Mask
              if !isRevealed && !secretKey.isEmpty {
                MetalKeyMaskView(isRevealed: isRevealed, palette: palette)
                  .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                  .padding(4)
              }
            }
            .background(palette.card)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
          }
          .padding(.horizontal, 24)

          HStack(spacing: 16) {
            Button {
              guard !secretKey.isEmpty else { return }
              withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                isRevealed.toggle()
              }
              copied = false
            } label: {
              HStack {
                Image(systemName: isRevealed ? "eye.slash.fill" : "eye.fill")
                Text(isRevealed ? "Hide Key" : "Reveal Key")
              }
              .font(.system(size: 16, weight: .semibold))
              .frame(maxWidth: .infinity)
              .frame(height: 54)
              .background(palette.card)
              .foregroundStyle(palette.text)
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
              .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                  .stroke(palette.divider, lineWidth: 1)
              )
            }
            .disabled(secretKey.isEmpty)

            Button {
              guard !secretKey.isEmpty else { return }
              UIPasteboard.general.string = secretKey
              withAnimation { copied = true }
              AppToastController.shared.show("Key Copied")
              DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { copied = false }
              }
            } label: {
              HStack {
                Image(systemName: copied ? "checkmark" : "doc.on.doc.fill")
                Text(copied ? "Copied" : "Copy")
              }
              .font(.system(size: 16, weight: .semibold))
              .frame(maxWidth: .infinity)
              .frame(height: 54)
              .background(palette.accent)
              .foregroundStyle(.white)
              .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(secretKey.isEmpty)
          }
          .padding(.horizontal, 24)

          Text("CRITICAL: Never share your secret key. This key provides full access to your identity and encrypted messages.")
            .font(.system(size: 13))
            .foregroundStyle(palette.danger.opacity(0.8))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .padding(.top, 8)
        }
      }
    }
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Secret Key")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct MediaCacheSettingsDetailView: View {
  @Environment(\.colorScheme) private var colorScheme
  @AppStorage("vibe.settings.media.maxCacheSize") private var maxCacheSize = 100
  @AppStorage("vibe.settings.media.cacheExpiryDays") private var cacheExpiryDays = 7
  @AppStorage("vibe.settings.media.autoPlayNext") private var autoPlayNext = true
  @AppStorage("vibe.settings.media.streamQuality") private var streamQuality = "high"

  @State private var stats = AppMediaCacheController.cacheStats()

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    List {
      Section {
        ForEach(stats.categories) { category in
          HStack(spacing: 12) {
            Image(systemName: category.systemImage)
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(palette.accent)
              .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
              Text(category.title)
                .foregroundStyle(.primary)
              Text("\(category.fileCount) \(category.fileCount == 1 ? "file" : "files")")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(formattedBytes(category.bytesUsed))
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
        }
        SettingsValueLine(title: "Total", value: formattedBytes(stats.totalBytes))
      } header: {
        Text("Downloaded media")
      } footer: {
        Text("Space used by media downloaded from chats. Your own uploads and recordings are stored separately and are never cleared here.")
      }
      .listRowBackground(palette.card)

      Section("Playback") {
        Stepper(value: $maxCacheSize, in: 50...500, step: 25) {
          LabeledContent("Max cache size") {
            Text("\(maxCacheSize) GB")
              .foregroundStyle(.secondary)
          }
        }

        Stepper(value: $cacheExpiryDays, in: 1...60) {
          LabeledContent("Expiry window") {
            Text("\(cacheExpiryDays) days")
              .foregroundStyle(.secondary)
          }
        }

        Toggle("Auto-play next", isOn: $autoPlayNext)

        Picker("Stream quality", selection: $streamQuality) {
          Text("Low").tag("low")
          Text("Medium").tag("medium")
          Text("High").tag("high")
        }
      }
      .listRowBackground(palette.card)

      Section {
        ForEach(stats.categories) { category in
          Button(role: .destructive) {
            AppMediaCacheController.clearCategory(id: category.id)
            refreshStats()
          } label: {
            Text("Clear \(category.title.lowercased())")
          }
          .disabled(category.bytesUsed == 0)
        }

        Button("Clear Expired") {
          AppMediaCacheController.clearExpired(olderThanDays: cacheExpiryDays)
          refreshStats()
        }

        Button("Clear All Downloads", role: .destructive) {
          AppMediaCacheController.clearAll()
          refreshStats()
        }
        .disabled(stats.totalBytes == 0)
      } header: {
        Text("Clear cache")
      } footer: {
        Text("Cleared media re-downloads automatically the next time you open it.")
      }
      .listRowBackground(palette.card)
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Media Cache")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      refreshStats()
    }
  }

  private func refreshStats() {
    stats = AppMediaCacheController.cacheStats()
  }

  private func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

private struct BlockedUsersDetailView: View {
  @Environment(\.colorScheme) private var colorScheme
  let users: [AppBlockedUser]

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    List {
      if users.isEmpty {
        Section {
          ContentUnavailableView("No Blocked Users", systemImage: "nosign")
        }
        .listRowBackground(palette.card)
      } else {
        ForEach(users) { user in
          HStack(spacing: 12) {
            if let urlString = user.profileImage, let url = URL(string: urlString) {
              AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                  image
                    .resizable()
                    .scaledToFill()
                default:
                  fallbackAvatar(for: user)
                }
              }
              .frame(width: 42, height: 42)
              .clipShape(Circle())
            } else {
              fallbackAvatar(for: user)
            }

            VStack(alignment: .leading, spacing: 3) {
              Text(user.displayName)
              Text("@\(user.username)")
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }
          .padding(.vertical, 2)
        }
        .listRowBackground(palette.card)
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Blocked Users")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func fallbackAvatar(for user: AppBlockedUser) -> some View {
    Circle()
      .fill(Color.secondary.opacity(0.16))
      .frame(width: 42, height: 42)
      .overlay(
        Text(String(user.displayName.prefix(1)).uppercased())
          .font(.system(size: 16, weight: .bold))
      )
  }
}

private struct SettingsValueLine: View {
  let title: String
  let value: String

  var body: some View {
    LabeledContent(title) {
      Text(value)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
    }
  }
}

private struct QRCodePanel: View {
  let value: String
  let palette: AppThemePalette
  @State private var renderedImage: UIImage?
  @State private var renderedValue = ""

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 32, style: .continuous)
        .fill(Color.white)
        .frame(width: 240, height: 240)
        .shadow(color: Color.black.opacity(0.12), radius: 24, x: 0, y: 12)
        .overlay(
          RoundedRectangle(cornerRadius: 32, style: .continuous)
            .stroke(Color.black.opacity(0.04), lineWidth: 1)
        )

      if value.isEmpty {
        Image(systemName: "qrcode")
          .font(.system(size: 72, weight: .light))
          .foregroundStyle(palette.secondaryText)
      } else if renderedValue == value, let image = renderedImage {
        Image(uiImage: image)
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .frame(width: 190, height: 190)
      } else {
        ProgressView()
          .tint(.black.opacity(0.42))
      }
    }
    .task(id: value) {
      guard !value.isEmpty else {
        renderedValue = ""
        renderedImage = nil
        return
      }
      let nextImage = await Task.detached(priority: .userInitiated) {
        QRCodeRenderer.image(for: value)
      }.value
      guard !Task.isCancelled else { return }
      renderedValue = value
      renderedImage = nextImage
    }
  }
}

enum QRCodeRenderer {
  static let context = CIContext()

  static func image(for value: String) -> UIImage? {
    guard !value.isEmpty else { return nil }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(value.utf8)
    filter.correctionLevel = "M"
    guard let outputImage = filter.outputImage else { return nil }
    let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
      return nil
    }
    return UIImage(cgImage: cgImage)
  }
}

private struct AppCacheCategoryStat: Identifiable {
  let id: String
  let title: String
  let systemImage: String
  let bytesUsed: Int64
  let fileCount: Int
}

private struct AppMediaCacheStats {
  let categories: [AppCacheCategoryStat]

  var totalBytes: Int64 { categories.reduce(0) { $0 + $1.bytesUsed } }
  var totalFiles: Int { categories.reduce(0) { $0 + $1.fileCount } }
}

/// App-wide DOWNLOAD cache accounting + clearing, reported straight out of `VibeMediaVault`.
///
/// It used to keep its own list of directory NAMES under `Library/Caches` — which meant that the
/// moment chat photos, voice notes and documents moved to durable storage, this screen reported
/// zero bytes for them and its Clear button silently did nothing. The vault is now the single
/// source of truth for where downloaded media lives, so the accounting cannot drift from it
/// again.
///
/// The user's own uploads and recordings (`chat-local-attachments`, `voice-local-imports`,
/// `video-notes`) are not in the vault and are deliberately unreachable from here: clearing them
/// would lose media that cannot be re-downloaded.
private enum AppMediaCacheController {
  static let categories: [(id: String, title: String, systemImage: String, kinds: [VibeMediaKind])] = [
    ("audio", "Voice & Music", "music.note", [.audio]),
    ("photos", "Photos", "photo", [.image, .avatar]),
    ("videos", "Video Previews", "film", [.videoPreview]),
    ("documents", "Documents", "doc.text", [.document, .documentPage]),
  ]

  static func cacheStats() -> AppMediaCacheStats {
    let vault = VibeMediaVault.shared
    let categoryStats = categories.map { category -> AppCacheCategoryStat in
      var bytes: Int64 = 0
      var count = 0
      for kind in category.kinds {
        let usage = vault.usage(for: kind)
        bytes += usage.byteSize
        count += usage.fileCount
      }
      return AppCacheCategoryStat(
        id: category.id,
        title: category.title,
        systemImage: category.systemImage,
        bytesUsed: bytes,
        fileCount: count
      )
    }
    return AppMediaCacheStats(categories: categoryStats)
  }

  /// Explicit, user-pressed. Nothing in the app sweeps on a timer: a file the user waited for
  /// stays until they ask for the space back.
  static func clearExpired(olderThanDays days: Int) {
    let threshold = Date().addingTimeInterval(-Double(max(days, 1)) * 86_400.0)
    VibeMediaVault.shared.clearEntries(olderThan: threshold, kinds: allKinds)
  }

  static func clearAll() {
    VibeMediaVault.shared.clear(kinds: allKinds)
  }

  static func clearCategory(id: String) {
    guard let category = categories.first(where: { $0.id == id }) else { return }
    VibeMediaVault.shared.clear(kinds: category.kinds)
  }

  private static var allKinds: [VibeMediaKind] { categories.flatMap(\.kinds) }
}

private struct AppBlockedUser: Identifiable {
  let id: String
  let username: String
  let displayName: String
  let profileImage: String?

  init?(payload: [String: Any]) {
    guard let id = Self.normalizedString(payload["userId"] ?? payload["id"]),
      let username = Self.normalizedString(payload["username"])
    else {
      return nil
    }

    self.id = id
    self.username = username
    self.displayName =
      Self.normalizedString(payload["name"])
      ?? username
    self.profileImage = Self.normalizedString(payload["profileImage"] ?? payload["profile_image"])
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

private enum AppBlockedUsersService {
  static func fetch(config: AppSessionConfig) async throws -> [AppBlockedUser] {
    guard let url = apiURL(base: config.apiBaseURLString, path: "/user/blocks/\(config.userID)") else {
      return []
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await VibeHTTP.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode)
    else {
      return []
    }

    guard let raw = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
      return []
    }
    return raw.compactMap(AppBlockedUser.init(payload:))
  }

  private static func apiURL(base: String, path: String) -> URL? {
    var normalized = base.trimmingCharacters(in: .whitespacesAndNewlines)
    while normalized.hasSuffix("/") {
      normalized.removeLast()
    }
    guard !normalized.isEmpty else { return nil }

    let pathBase = normalized.lowercased().hasSuffix("/api") ? normalized : "\(normalized)/api"
    return URL(string: pathBase + path)
  }
}

private extension String {
  var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
