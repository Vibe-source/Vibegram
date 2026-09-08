import PhotosUI
import SwiftUI

// MARK: - Channel roster (admins / subscribers)

struct ChannelMemberListPage: View {
  let title: String
  let members: [ChannelProfileService.Member]
  let emptyText: String
  /// When true, split human admins vs agent admins into sections.
  var groupAgentAdmins: Bool = false

  @Environment(\.colorScheme) private var colorScheme

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }

  private var humanMembers: [ChannelProfileService.Member] {
    members.filter { !isAgentAdmin($0.role) }
  }

  private var agentMembers: [ChannelProfileService.Member] {
    members.filter { isAgentAdmin($0.role) }
  }

  var body: some View {
    List {
      if members.isEmpty {
        Text(emptyText)
          .font(.system(size: 15))
          .foregroundStyle(palette.secondaryText)
          .listRowBackground(Color.clear)
      } else if groupAgentAdmins, !agentMembers.isEmpty {
        if !humanMembers.isEmpty {
          Section(humanMembers.count == 1 ? "Administrator" : "Administrators") {
            ForEach(humanMembers, id: \.userId) { member in
              memberRow(member)
            }
          }
        }
        Section(agentMembers.count == 1 ? "Agent admin" : "Agent admins") {
          ForEach(agentMembers, id: \.userId) { member in
            memberRow(member)
          }
        }
      } else {
        ForEach(members, id: \.userId) { member in
          memberRow(member)
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Color.clear.ignoresSafeArea())
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
  }

  @ViewBuilder
  private func memberRow(_ member: ChannelProfileService.Member) -> some View {
    HStack(spacing: 12) {
      memberAvatar(member)
      VStack(alignment: .leading, spacing: 2) {
        Text(member.name)
          .font(.system(size: 16, weight: .medium))
          .foregroundStyle(.primary)
        Text(roleLabel(member.role))
          .font(.system(size: 13))
          .foregroundStyle(palette.secondaryText)
      }
      Spacer(minLength: 0)
    }
    .listRowBackground(palette.card)
  }

  @ViewBuilder
  private func memberAvatar(_ member: ChannelProfileService.Member) -> some View {
    let initial = String(member.name.prefix(1)).uppercased()
    if let urlString = member.avatarUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
      !urlString.isEmpty,
      let url = URL(string: urlString)
    {
      AsyncImage(url: url) { phase in
        switch phase {
        case .success(let image):
          image
            .resizable()
            .scaledToFill()
        default:
          Circle()
            .fill(palette.accent.opacity(0.18))
            .overlay {
              Text(initial)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.accent)
            }
        }
      }
      .frame(width: 40, height: 40)
      .clipShape(Circle())
    } else {
      Circle()
        .fill(palette.accent.opacity(0.18))
        .frame(width: 40, height: 40)
        .overlay {
          Text(initial)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(palette.accent)
        }
    }
  }

  private func roleLabel(_ role: String) -> String {
    let r = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch r {
    case "owner": return "Owner"
    case "admin": return "Admin"
    case "agent_admin", "agent admin": return "Agent admin"
    case "subscriber", "member", "": return "Subscriber"
    default: return role
    }
  }

  private func isAgentAdmin(_ role: String) -> Bool {
    let r = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return r == "agent_admin" || r == "agent admin"
  }
}

// MARK: - Recent actions

struct ChannelRecentActionsPage: View {
  let actions: [ChannelProfileService.RecentAction]

  @Environment(\.colorScheme) private var colorScheme

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }

  var body: some View {
    List {
      if actions.isEmpty {
        Text("No recent actions yet")
          .font(.system(size: 15))
          .foregroundStyle(palette.secondaryText)
          .listRowBackground(Color.clear)
      } else {
        ForEach(actions) { action in
          VStack(alignment: .leading, spacing: 4) {
            HStack {
              Text(action.fromName ?? action.fromId ?? "System")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
              Spacer()
              Text(Self.timeLabel(action.timestampMs))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.secondaryText)
            }
            Text(action.text.isEmpty ? action.type : action.text)
              .font(.system(size: 14))
              .foregroundStyle(palette.secondaryText)
              .lineLimit(3)
          }
          .listRowBackground(palette.card)
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Color.clear.ignoresSafeArea())
    .navigationTitle("Recent actions")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
  }

  private static func timeLabel(_ ms: Int64) -> String {
    guard ms > 0 else { return "" }
    let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000.0)
    let f = DateFormatter()
    f.doesRelativeDateFormatting = true
    f.dateStyle = .short
    f.timeStyle = .short
    return f.string(from: date)
  }
}

// MARK: - Channel settings (page, not sheet) — Telegram-style icon list

struct ChannelSettingsPage: View {
  let chatId: String
  let channelName: String
  var channelDescription: String = ""
  var avatarUri: String? = nil
  let canManage: Bool
  @Binding var settings: ChannelProfileService.Settings
  var adminCount: Int = 0
  var subscriberCount: Int = 0
  let onEditName: () -> Void
  let onOpenAppearance: () -> Void
  let onOpenRecentActions: () -> Void
  var onOpenAdministrators: (() -> Void)? = nil
  var onOpenSubscribers: (() -> Void)? = nil
  var onDescriptionChanged: ((String) -> Void)? = nil
  var onNameChanged: ((String) -> Void)? = nil
  var onAvatarChanged: ((String) -> Void)? = nil
  let onSettingsChanged: (ChannelProfileService.Settings) -> Void
  var onDismiss: (() -> Void)? = nil

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dismiss) private var dismiss
  @State private var isBusy = false
  @State private var errorMessage: String?
  @State private var showTypePicker = false
  @State private var nameLocal: String = ""
  @State private var descriptionLocal: String = ""
  @State private var identitySeeded = false
  @State private var localAvatarUri: String?
  @State private var photoPickerItem: PhotosPickerItem?
  @State private var isUploadingPhoto = false

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }

  private func closePage() {
    if let onDismiss { onDismiss() } else { dismiss() }
  }

  private var resolvedAvatarUri: String? {
    let local = localAvatarUri?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !local.isEmpty { return local }
    let host = avatarUri?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return host.isEmpty ? nil : host
  }

  private var typeLabel: String {
    settings.channelType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "public"
      ? "Public"
      : "Private"
  }

  private var inviteTrailing: String {
    if let link = settings.inviteLink, !link.isEmpty { return "1" }
    if let slug = settings.publicSlug, !slug.isEmpty { return "1" }
    return canManage ? "Add" : "—"
  }

  private var reactionsTrailing: String {
    settings.reactionsEnabled ? "All Reactions" : "Off"
  }

  private var dmsTrailing: String {
    settings.allowDirectMessages ? "On" : "Off"
  }

  var body: some View {
    List {
      // —— Identity: shared avatar node + compact native name/description rows ——
      Section {
        VStack(spacing: 10) {
          ChannelSettingsAvatarNode(
            title: nameLocal.isEmpty ? channelName : nameLocal,
            avatarUri: resolvedAvatarUri,
            chatId: chatId,
            isDark: colorScheme == .dark,
            size: 96
          )
          .frame(width: 96, height: 96)
          .clipShape(Circle())
          .overlay {
            if isUploadingPhoto {
              Circle().fill(Color.black.opacity(0.42))
              ProgressView().tint(.white)
            }
          }

          if canManage {
            PhotosPicker(selection: $photoPickerItem, matching: .images) {
              Text(isUploadingPhoto ? "Uploading…" : "Set New Photo")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Color.accentColor)
            }
            .disabled(isUploadingPhoto)
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)

        // Two compact native rows (name + description), values pre-filled — no push.
        if canManage {
          // Empty title = no placeholder label; text is the live channel name.
          TextField("", text: $nameLocal)
            .font(.system(size: 17))
            .textInputAutocapitalization(.words)
            .submitLabel(.done)
            .onSubmit { Task { await persistIdentity() } }
            .listRowBackground(palette.card)

          TextField("", text: $descriptionLocal, axis: .vertical)
            .font(.system(size: 17))
            .lineLimit(1...4)
            .submitLabel(.done)
            .onSubmit { Task { await persistIdentity() } }
            .listRowBackground(palette.card)
        } else {
          Text(channelName)
            .font(.system(size: 17))
            .listRowBackground(palette.card)
          if !channelDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(channelDescription)
              .font(.system(size: 17))
              .foregroundStyle(.secondary)
              .listRowBackground(palette.card)
          }
        }
      }

      // —— Channel policy / content ——
      Section {
        iconButtonRow(
          title: "Channel Type",
          systemImage: "megaphone.fill",
          tint: Color(red: 0.20, green: 0.55, blue: 0.98),
          trailing: typeLabel,
          showsChevron: canManage
        ) {
          if canManage { showTypePicker = true }
        }

        if canManage, settings.channelType.lowercased() == "public" {
          HStack(spacing: 12) {
            leadingIcon("link", tint: Color(red: 0.98, green: 0.62, blue: 0.20))
            VStack(alignment: .leading, spacing: 2) {
              Text("Public link")
                .font(.system(size: 17))
              TextField("channel_name", text: publicSlugBinding)
                .font(.system(size: 15))
                .foregroundStyle(palette.secondaryText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
          }
          .listRowBackground(palette.card)

          Button {
            Task { await persist(settings) }
          } label: {
            Text("Apply public link")
              .font(.system(size: 16, weight: .medium))
              .foregroundStyle(palette.accent)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .listRowBackground(palette.card)
        }

        iconButtonRow(
          title: "Invite Links",
          systemImage: "link",
          tint: Color(red: 0.98, green: 0.62, blue: 0.20),
          trailing: inviteTrailing,
          showsChevron: canManage
        ) {
          if canManage { Task { await rotateInvite() } }
        }

        iconButtonRow(
          title: "Discussion",
          systemImage: "bubble.left.and.bubble.right.fill",
          tint: Color(red: 0.30, green: 0.78, blue: 0.42),
          trailing: settings.discussionsEnabled ? "On" : "Add",
          showsChevron: canManage
        ) {
          if canManage {
            var s = settings
            s.discussionsEnabled.toggle()
            settings = s
            Task { await persist(s) }
          }
        }

        iconButtonRow(
          title: "Reactions",
          systemImage: "heart.fill",
          tint: Color(red: 0.98, green: 0.35, blue: 0.45),
          trailing: reactionsTrailing,
          showsChevron: canManage
        ) {
          if canManage {
            var s = settings
            s.reactionsEnabled.toggle()
            settings = s
            Task { await persist(s) }
          }
        }

        // Appearance / photo-poster intentionally omitted for channels.

        if canManage {
          iconToggleRow(
            title: "Auto-Translate Messages",
            systemImage: "character.bubble.fill",
            tint: Color(red: 0.62, green: 0.40, blue: 0.95),
            isOn: translateBinding
          )
        }

        iconButtonRow(
          title: "Direct Messages",
          systemImage: "bubble.left.fill",
          tint: Color(red: 0.35, green: 0.55, blue: 0.98),
          trailing: dmsTrailing,
          showsChevron: canManage
        ) {
          if canManage {
            var s = settings
            s.allowDirectMessages.toggle()
            settings = s
            Task { await persist(s) }
          }
        }

        if canManage {
          iconToggleRow(
            title: "Approve new subscribers",
            systemImage: "person.badge.clock.fill",
            tint: Color(red: 0.20, green: 0.65, blue: 0.85),
            isOn: joinApprovalBinding
          )
          iconToggleRow(
            title: "Restrict saving content",
            systemImage: "lock.rectangle.on.rectangle.fill",
            tint: Color(red: 0.55, green: 0.55, blue: 0.60),
            isOn: restrictSavingBinding
          )
        }
      }

      // —— People ——
      Section {
        iconButtonRow(
          title: "Administrators",
          systemImage: "checkmark.shield.fill",
          tint: Color(red: 0.30, green: 0.78, blue: 0.42),
          trailing: adminCount > 0 ? "\(adminCount)" : nil,
          showsChevron: true
        ) {
          onOpenAdministrators?()
        }

        iconButtonRow(
          title: "Subscribers",
          systemImage: "person.3.fill",
          tint: Color(red: 0.25, green: 0.55, blue: 0.95),
          trailing: subscriberCount > 0 ? "\(subscriberCount)" : nil,
          showsChevron: true
        ) {
          onOpenSubscribers?()
        }

        iconButtonRow(
          title: "Recent Actions",
          systemImage: "eye.fill",
          tint: Color(red: 0.98, green: 0.62, blue: 0.20),
          trailing: nil,
          showsChevron: true
        ) {
          onOpenRecentActions()
        }
      }

      if let errorMessage {
        Section {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Color.clear.ignoresSafeArea())
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(true)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Cancel") { closePage() }
          .font(.system(size: 17, weight: .semibold))
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("Done") {
          Task {
            await persistIdentity()
            if errorMessage == nil { closePage() }
          }
        }
        .font(.system(size: 17, weight: .semibold))
        .disabled(isBusy || isUploadingPhoto || nameLocal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .toolbarBackground(.hidden, for: .navigationBar)
    .onAppear {
      if !identitySeeded {
        nameLocal = channelName
        descriptionLocal = channelDescription
        localAvatarUri = avatarUri
        identitySeeded = true
      }
    }
    .onChange(of: channelName) { _, next in
      if nameLocal == channelName || nameLocal.isEmpty { nameLocal = next }
    }
    .onChange(of: channelDescription) { _, next in
      if descriptionLocal == channelDescription || descriptionLocal.isEmpty {
        descriptionLocal = next
      }
    }
    .onChange(of: avatarUri) { _, next in
      if localAvatarUri == nil || localAvatarUri == avatarUri {
        localAvatarUri = next
      }
    }
    .onChange(of: photoPickerItem) { _, item in
      guard let item else { return }
      Task { await loadPickedPhoto(item) }
    }
    .confirmationDialog("Channel Type", isPresented: $showTypePicker, titleVisibility: .visible) {
      Button("Private") {
        var s = settings
        s.channelType = "private"
        settings = s
        Task { await persist(s) }
      }
      Button("Public") {
        var s = settings
        s.channelType = "public"
        settings = s
        Task { await persist(s) }
      }
      Button("Cancel", role: .cancel) {}
    }
    .overlay {
      if isBusy {
        ProgressView().padding().background(.ultraThinMaterial).cornerRadius(10)
      }
    }
  }

  // MARK: Persist identity / photo

  @MainActor
  private func persistIdentity() async {
    guard canManage else { return }
    guard let config = AppSessionConfig.current else { return }
    let trimmedName = nameLocal.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedDesc = descriptionLocal.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { return }
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      let profile = try await ChannelProfileService.update(
        chatId: chatId,
        name: trimmedName,
        description: trimmedDesc,
        config: config
      )
      if !profile.name.isEmpty {
        nameLocal = profile.name
        onNameChanged?(profile.name)
      }
      descriptionLocal = profile.description ?? trimmedDesc
      onDescriptionChanged?(descriptionLocal)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func loadPickedPhoto(_ item: PhotosPickerItem) async {
    guard canManage else { return }
    guard let config = AppSessionConfig.current else { return }
    isUploadingPhoto = true
    errorMessage = nil
    defer { isUploadingPhoto = false }
    do {
      guard let data = try await item.loadTransferable(type: Data.self) else { return }
      let remoteURL = try await ChatRoomCreateService.uploadAvatar(
        imageData: data, config: config)
      let profile = try await ChannelProfileService.update(
        chatId: chatId, avatarUrl: remoteURL, config: config)
      let next = profile.avatarUrl ?? remoteURL
      localAvatarUri = next
      onAvatarChanged?(next)
      onSettingsChanged(profile.settings)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  // MARK: Row builders

  private func leadingIcon(_ systemImage: String, tint: Color) -> some View {
    Image(systemName: systemImage)
      .font(.system(size: 14, weight: .semibold))
      .foregroundStyle(.white)
      .frame(width: 30, height: 30)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(tint)
      )
  }

  private func iconButtonRow(
    title: String,
    systemImage: String,
    tint: Color,
    trailing: String?,
    showsChevron: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 14) {
        leadingIcon(systemImage, tint: tint)
        Text(title)
          .font(.system(size: 17))
          .foregroundStyle(.primary)
          .lineLimit(1)
        Spacer(minLength: 8)
        if let trailing, !trailing.isEmpty {
          Text(trailing)
            .font(.system(size: 16))
            .foregroundStyle(palette.secondaryText)
            .lineLimit(1)
        }
        if showsChevron {
          Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(palette.secondaryText.opacity(0.75))
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowBackground(palette.card)
  }

  private func iconToggleRow(
    title: String,
    systemImage: String,
    tint: Color,
    isOn: Binding<Bool>
  ) -> some View {
    HStack(spacing: 14) {
      leadingIcon(systemImage, tint: tint)
      Text(title)
        .font(.system(size: 17))
        .foregroundStyle(.primary)
        .lineLimit(1)
      Spacer(minLength: 8)
      Toggle("", isOn: isOn)
        .labelsHidden()
    }
    .listRowBackground(palette.card)
  }

  private var publicSlugBinding: Binding<String> {
    Binding(
      get: { settings.publicSlug ?? "" },
      set: { next in
        var s = settings
        s.publicSlug = ChannelCreationSheet.normalizePublicSlug(next)
        settings = s
      }
    )
  }

  private var joinApprovalBinding: Binding<Bool> {
    Binding(
      get: { settings.joinApprovalRequired },
      set: { next in
        var s = settings
        s.joinApprovalRequired = next
        settings = s
        Task { await persist(s) }
      }
    )
  }

  private var restrictSavingBinding: Binding<Bool> {
    Binding(
      get: { settings.restrictSavingContent },
      set: { next in
        var s = settings
        s.restrictSavingContent = next
        settings = s
        Task { await persist(s) }
      }
    )
  }

  private var translateBinding: Binding<Bool> {
    Binding(
      get: { settings.autoTranslateEnabled },
      set: { next in
        var s = settings
        s.autoTranslateEnabled = next
        settings = s
        Task { await persist(s) }
      }
    )
  }

  @MainActor
  private func persist(_ next: ChannelProfileService.Settings) async {
    guard let config = AppSessionConfig.current else { return }
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      let profile = try await ChannelProfileService.update(
        chatId: chatId, settings: next, config: config)
      settings = profile.settings
      onSettingsChanged(profile.settings)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func persistDescription() async {
    guard canManage else { return }
    guard let config = AppSessionConfig.current else { return }
    let trimmed = descriptionLocal.trimmingCharacters(in: .whitespacesAndNewlines)
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      let profile = try await ChannelProfileService.update(
        chatId: chatId,
        description: trimmed,
        config: config
      )
      if let desc = profile.description {
        descriptionLocal = desc
        onDescriptionChanged?(desc)
      } else {
        onDescriptionChanged?(trimmed)
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func rotateInvite() async {
    guard let config = AppSessionConfig.current else { return }
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      let next = try await ChannelProfileService.rotateInviteLink(chatId: chatId, config: config)
      settings = next
      onSettingsChanged(next)
      if let link = next.inviteLink, !link.isEmpty {
        UIPasteboard.general.string = link
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

// MARK: - Shared avatar node (same ChatAvatarNodeView as home/chat)

private struct ChannelSettingsAvatarNode: UIViewRepresentable {
  let title: String
  let avatarUri: String?
  let chatId: String
  let isDark: Bool
  var size: CGFloat = 96

  func makeUIView(context: Context) -> ChatAvatarNodeView {
    let view = ChatAvatarNodeView()
    view.translatesAutoresizingMaskIntoConstraints = false
    return view
  }

  func updateUIView(_ uiView: ChatAvatarNodeView, context: Context) {
    let descriptor = ChatAvatarDescriptor(
      title: title,
      rawAvatarURI: avatarUri,
      peerUserId: nil,
      chatId: chatId,
      kind: .standard,
      isGroup: true,
      members: [],
      preferPushAvatar: false,
      gradientColors: nil
    )
    uiView.configure(with: descriptor, isDark: isDark, renderingSide: size)
  }
}

// MARK: - Room edit page (group/channel) — navigation page, not sheet

struct RoomEditPage: View {
  let config: AppSessionConfig
  let chatId: String
  let isChannel: Bool
  let initialName: String
  let initialDescription: String
  let initialAvatarUri: String?
  let memberCount: Int
  let onOpenMembers: (() -> Void)?
  let onDismiss: (() -> Void)?
  let onSaved: (_ name: String, _ description: String, _ avatarUrl: String?) -> Void

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var descriptionText: String
  @State private var avatarItem: PhotosPickerItem?
  @State private var avatarImage: Image?
  @State private var avatarData: Data?
  @State private var isSaving = false
  @State private var errorMessage: String?

  init(
    config: AppSessionConfig,
    chatId: String,
    isChannel: Bool,
    initialName: String,
    initialDescription: String,
    initialAvatarUri: String?,
    memberCount: Int = 0,
    onOpenMembers: (() -> Void)? = nil,
    onDismiss: (() -> Void)? = nil,
    onSaved: @escaping (String, String, String?) -> Void
  ) {
    self.config = config
    self.chatId = chatId
    self.isChannel = isChannel
    self.initialName = initialName
    self.initialDescription = initialDescription
    self.initialAvatarUri = initialAvatarUri
    self.memberCount = memberCount
    self.onOpenMembers = onOpenMembers
    self.onDismiss = onDismiss
    self.onSaved = onSaved
    _name = State(initialValue: initialName)
    _descriptionText = State(initialValue: initialDescription)
  }

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }

  private func closePage() {
    if let onDismiss { onDismiss() } else { dismiss() }
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 24) {
        PhotosPicker(selection: $avatarItem, matching: .images) {
          VStack(spacing: 10) {
            if let avatarImage {
              avatarImage
                .resizable()
                .scaledToFill()
                .frame(width: 104, height: 104)
                .clipShape(Circle())
            } else {
              ChannelSettingsAvatarNode(
                title: name,
                avatarUri: initialAvatarUri,
                chatId: chatId,
                isDark: colorScheme == .dark,
                size: 104
              )
              .frame(width: 104, height: 104)
              .clipShape(Circle())
            }

            Text("Set Photo")
              .font(.system(size: 17, weight: .regular))
              .foregroundStyle(palette.accent)
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)

        VStack(spacing: 0) {
          TextField(isChannel ? "Channel name" : "Group name", text: $name)
            .font(.system(size: 17, weight: .regular))
            .textInputAutocapitalization(.words)
            .padding(.horizontal, 18)
            .frame(minHeight: 54)

          Rectangle()
            .fill(palette.divider)
            .frame(height: 1 / UIScreen.main.scale)
            .padding(.horizontal, 18)

          TextField("Description", text: $descriptionText, axis: .vertical)
            .font(.system(size: 17, weight: .regular))
            .lineLimit(1...4)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(minHeight: 54, alignment: .top)
        }
        .background(palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

        if let onOpenMembers {
          Button {
            onOpenMembers()
          } label: {
            HStack(spacing: 14) {
              Image(systemName: "person.3.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(palette.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
              Text(isChannel ? "Subscribers and Administrators" : "Members and Administrators")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(palette.text)
              Spacer(minLength: 8)
              if memberCount > 0 {
                Text("\(memberCount)")
                  .foregroundStyle(palette.secondaryText)
              }
              Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(palette.tertiaryText)
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 62)
          }
          .buttonStyle(.plain)
          .background(palette.card)
          .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }

        if let errorMessage {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 18)
      .padding(.bottom, 44)
    }
    .scrollIndicators(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(true)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button("Cancel") { closePage() }
          .font(.system(size: 17, weight: .semibold))
      }
      ToolbarItem(placement: .topBarTrailing) {
        Button("Done") { Task { await save() } }
          .font(.system(size: 17, weight: .semibold))
          .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .overlay {
      if isSaving {
        ProgressView().padding().background(.ultraThinMaterial).cornerRadius(10)
      }
    }
    .onChange(of: avatarItem) { _, newItem in
      Task {
        guard let data = try? await newItem?.loadTransferable(type: Data.self) else { return }
        guard let uiImage = UIImage(data: data) else { return }
        avatarData = data
        avatarImage = Image(uiImage: uiImage)
      }
    }
  }

  @MainActor
  private func save() async {
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      var remoteAvatar: String? = nil
      if let avatarData {
        remoteAvatar = try await ChatRoomCreateService.uploadAvatar(
          imageData: avatarData, config: config)
      }
      if isChannel {
        _ = try await ChannelProfileService.update(
          chatId: chatId,
          name: name.trimmingCharacters(in: .whitespacesAndNewlines),
          description: descriptionText,
          avatarUrl: remoteAvatar,
          config: config
        )
      } else {
        _ = try await GroupUpdateService.update(
          chatId: chatId,
          name: name.trimmingCharacters(in: .whitespacesAndNewlines),
          description: descriptionText,
          avatarUrl: remoteAvatar,
          config: config
        )
      }
      onSaved(
        name.trimmingCharacters(in: .whitespacesAndNewlines),
        descriptionText,
        remoteAvatar ?? initialAvatarUri
      )
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

// MARK: - Channel agent administrators

struct ChannelAgentManagementPage: View {
  let chatId: String
  let onCreateAgent: () -> Void

  @Environment(\.colorScheme) private var colorScheme
  @State private var assignments: [ChannelProfileService.AgentAssignment] = []
  @State private var ownedAgents: [ChannelProfileService.OwnedAgent] = []
  @State private var isLoading = true
  @State private var busyAgentId: String?
  @State private var errorMessage: String?

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }

  private var unattachedAgents: [ChannelProfileService.OwnedAgent] {
    let attached = Set(assignments.map(\.agentId))
    return ownedAgents.filter { !attached.contains($0.id) }
  }

  var body: some View {
    List {
      Section {
        Button(action: onCreateAgent) {
          Label("Create an agent", systemImage: "plus.circle.fill")
            .font(.system(size: 16, weight: .semibold))
        }
      } footer: {
        Text("Agents are standalone identities. This channel only grants a narrowed set of their tools, output modes, and triggers.")
      }

      Section("Agent administrators") {
        if isLoading {
          HStack { Spacer(); ProgressView(); Spacer() }
        } else if assignments.isEmpty {
          Text("No channel agents yet")
            .foregroundStyle(palette.secondaryText)
        } else {
          ForEach(assignments) { assignment in
            NavigationLink {
              ChannelAgentPolicyPage(
                chatId: chatId,
                assignment: assignment,
                baseAgent: ownedAgents.first(where: { $0.id == assignment.agentId }),
                onSaved: { updated in
                  replace(updated)
                },
                onDetached: {
                  assignments.removeAll { $0.agentId == assignment.agentId }
                }
              )
            } label: {
              agentRow(
                name: assignment.displayName,
                subtitle: assignment.status == "active" ? "Agent admin" : "Disabled",
                isBusy: false
              )
            }
          }
        }
      }

      if !unattachedAgents.isEmpty {
        Section("Available agents") {
          ForEach(unattachedAgents) { agent in
            Button {
              Task { await attach(agent) }
            } label: {
              agentRow(
                name: agent.displayName,
                subtitle: agent.status == "published" ? "Add as agent admin" : "Publish before adding",
                isBusy: busyAgentId == agent.id
              )
            }
            .disabled(busyAgentId != nil || agent.status != "published")
          }
        }
      }

      if let errorMessage {
        Section { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Channel agents")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await load() }
    .task { await load() }
  }

  @ViewBuilder
  private func agentRow(name: String, subtitle: String, isBusy: Bool) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "sparkles")
        .foregroundStyle(palette.accent)
        .frame(width: 38, height: 38)
        .background(palette.accent.opacity(0.14), in: Circle())
      VStack(alignment: .leading, spacing: 2) {
        Text(name).foregroundStyle(.primary)
        Text(subtitle).font(.caption).foregroundStyle(palette.secondaryText)
      }
      Spacer()
      if isBusy { ProgressView() }
    }
  }

  @MainActor
  private func load() async {
    guard let config = AppSessionConfig.current else { return }
    isLoading = assignments.isEmpty
    errorMessage = nil
    do {
      async let assignmentRequest = ChannelProfileService.fetchAgentAssignments(
        chatId: chatId, config: config)
      async let agentRequest = ChannelProfileService.fetchOwnedAgents(config: config)
      let (nextAssignments, nextAgents) = try await (assignmentRequest, agentRequest)
      assignments = nextAssignments
      ownedAgents = nextAgents
    } catch {
      errorMessage = error.localizedDescription
    }
    isLoading = false
  }

  @MainActor
  private func attach(_ agent: ChannelProfileService.OwnedAgent) async {
    guard let config = AppSessionConfig.current else { return }
    busyAgentId = agent.id
    errorMessage = nil
    defer { busyAgentId = nil }
    do {
      let assignment = try await ChannelProfileService.attachAgent(
        chatId: chatId, agent: agent, config: config)
      replace(assignment)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func replace(_ assignment: ChannelProfileService.AgentAssignment) {
    assignments.removeAll { $0.agentId == assignment.agentId }
    assignments.append(assignment)
    assignments.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
  }
}

private struct ChannelAgentPolicyPage: View {
  let chatId: String
  let assignment: ChannelProfileService.AgentAssignment
  let baseAgent: ChannelProfileService.OwnedAgent?
  let onSaved: (ChannelProfileService.AgentAssignment) -> Void
  let onDetached: () -> Void

  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @State private var allowedTools: Set<String>
  @State private var allowedOutputModes: Set<String>
  @State private var triggerType: String
  @State private var intervalHours: Int
  @State private var instructions: String
  @State private var isActive: Bool
  @State private var isBusy = false
  @State private var errorMessage: String?

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }
  private var toolChoices: [String] {
    let base = baseAgent?.enabledTools ?? assignment.allowedTools
    return Array(Set(base)).sorted()
  }
  private var outputChoices: [String] {
    let base = baseAgent?.outputModes ?? assignment.allowedOutputModes
    let values = base.isEmpty ? ["text"] : base
    return Array(Set(values)).sorted()
  }

  init(
    chatId: String,
    assignment: ChannelProfileService.AgentAssignment,
    baseAgent: ChannelProfileService.OwnedAgent?,
    onSaved: @escaping (ChannelProfileService.AgentAssignment) -> Void,
    onDetached: @escaping () -> Void
  ) {
    self.chatId = chatId
    self.assignment = assignment
    self.baseAgent = baseAgent
    self.onSaved = onSaved
    self.onDetached = onDetached
    _allowedTools = State(initialValue: Set(assignment.allowedTools))
    _allowedOutputModes = State(initialValue: Set(assignment.allowedOutputModes))
    let trigger = (assignment.triggerConfig["type"] as? String) ?? "manual"
    _triggerType = State(initialValue: trigger)
    let minutes = (assignment.triggerConfig["everyMinutes"] as? NSNumber)?.intValue
      ?? (assignment.triggerConfig["every_minutes"] as? NSNumber)?.intValue
      ?? 240
    _intervalHours = State(initialValue: max(1, minutes / 60))
    _instructions = State(
      initialValue: (assignment.permissions["instructions"] as? String) ?? "")
    _isActive = State(initialValue: assignment.status == "active")
  }

  var body: some View {
    Form {
      Section {
        Toggle("Enabled", isOn: $isActive)
        TextField(
          "Channel-specific instructions",
          text: $instructions,
          axis: .vertical
        )
        .lineLimit(3...8)
      } header: {
        Text("Channel role")
      } footer: {
        Text("These instructions are appended only when this agent works in this channel; its global identity and prompt remain unchanged.")
      }

      Section {
        ForEach(outputChoices, id: \.self) { mode in
          Toggle(modeLabel(mode), isOn: membership(mode, in: $allowedOutputModes))
        }
      } header: {
        Text("Allowed output")
      } footer: {
        Text("Media includes images, files, music, and video. Voice requires the agent's voice capability.")
      }

      Section {
        if toolChoices.isEmpty {
          Text("This agent has no tools enabled.").foregroundStyle(palette.secondaryText)
        } else {
          ForEach(toolChoices, id: \.self) { tool in
            Toggle(toolLabel(tool), isOn: membership(tool, in: $allowedTools))
          }
        }
      } header: {
        Text("Allowed tools")
      } footer: {
        Text("Channel permissions can only narrow the agent's own tools. Connected and custom tools remain scoped to the agent owner.")
      }

      Section {
        Picker("Run", selection: $triggerType) {
          Text("When mentioned").tag("manual")
          Text("On connected events").tag("event")
          Text("On an interval").tag("interval")
        }
        if triggerType == "interval" {
          Stepper("Every \(intervalHours) hour\(intervalHours == 1 ? "" : "s")", value: $intervalHours, in: 1...24)
        }
      } header: {
        Text("Trigger")
      } footer: {
        Text("Event triggers use the agent's connected apps and event filters. Interval execution is stored as channel policy and runs through the same narrowed permissions.")
      }

      if let errorMessage {
        Section { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
      }

      Section {
        Button("Remove agent from channel", role: .destructive) {
          Task { await detach() }
        }
      }
    }
    .navigationTitle(assignment.displayName)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button("Save") { Task { await save() } }
          .disabled(isBusy)
      }
    }
    .overlay { if isBusy { ProgressView().padding().background(.ultraThinMaterial).cornerRadius(10) } }
  }

  private func membership(_ value: String, in values: Binding<Set<String>>) -> Binding<Bool> {
    Binding(
      get: { values.wrappedValue.contains(value) },
      set: { enabled in
        if enabled { values.wrappedValue.insert(value) }
        else { values.wrappedValue.remove(value) }
      }
    )
  }

  private func modeLabel(_ value: String) -> String {
    switch value { case "text": return "Text"; case "media": return "Media & music"; case "voice": return "Voice"; default: return value }
  }

  private func toolLabel(_ value: String) -> String {
    value.replacingOccurrences(of: "_", with: " ").capitalized
  }

  @MainActor
  private func save() async {
    guard let config = AppSessionConfig.current else { return }
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    var trigger: [String: Any] = ["type": triggerType]
    if triggerType == "interval" { trigger["everyMinutes"] = intervalHours * 60 }
    do {
      let updated = try await ChannelProfileService.updateAgentAssignment(
        chatId: chatId,
        agentId: assignment.agentId,
        allowedTools: allowedTools.sorted(),
        allowedOutputModes: allowedOutputModes.sorted(),
        triggerConfig: trigger,
        permissions: ["instructions": instructions.trimmingCharacters(in: .whitespacesAndNewlines)],
        status: isActive ? "active" : "disabled",
        config: config
      )
      onSaved(updated)
      AppToastController.shared.show("Channel agent updated.")
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func detach() async {
    guard let config = AppSessionConfig.current else { return }
    isBusy = true
    errorMessage = nil
    defer { isBusy = false }
    do {
      try await ChannelProfileService.detachAgent(
        chatId: chatId, agentId: assignment.agentId, config: config)
      onDetached()
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
