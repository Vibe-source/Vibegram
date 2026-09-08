import SwiftUI
import PhotosUI

struct ChatGroupCreationSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @EnvironmentObject private var coordinator: AppShellCoordinator

  let config: AppSessionConfig
  let homeRows: [ChatHomeListRow]
  let onCreated: (ChatRoute) -> Void

  enum Step: Hashable {
    case members
  }

  @State private var path = NavigationPath()
  @State private var groupName = ""
  @State private var groupDescription = ""
  @State private var selectedMembers = Set<ContactSearchUser>()
  @State private var searchQuery = ""
  @FocusState private var isQueryFieldFocused: Bool
  @State private var isSearchPresented = false
  @State private var searchResults: [ContactSearchUser] = []
  @State private var isSearching = false
  @State private var searchTask: Task<Void, Never>?
  @State private var isCreating = false
  @State private var errorMessage: String?
  @State private var avatarItem: PhotosPickerItem?
  @State private var avatarImage: Image?
  @State private var avatarData: Data?

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var trimmedGroupName: String {
    groupName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func contactUser(for row: ChatHomeListRow) -> ContactSearchUser? {
    ContactSearchUser(payload: [
      "userId": row.peerUserId ?? row.chatId,
      "username": row.title,
      "profileImage": row.avatarUri ?? "",
      "isAgent": row.isBuiltInAgentSurface || row.isBridgeAgentSurface,
      "tier": row.isGoldTier ? "gold" : "free",
    ])
  }

  var body: some View {
    NavigationStack(path: $path) {
      // Identity first (avatar / name / optional description), then members.
      infoStepView
        .background(palette.background.ignoresSafeArea())
        .navigationTitle("New Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button {
              dismiss()
            } label: {
              Image(systemName: "xmark")
            }
            .accessibilityLabel("Close")
          }
          ToolbarItem(placement: .topBarTrailing) {
            Button("Next") {
              path.append(Step.members)
            }
            .disabled(trimmedGroupName.isEmpty)
          }
        }
        .navigationDestination(for: Step.self) { step in
          if step == .members {
            membersStepView
              .background(palette.background.ignoresSafeArea())
              .navigationTitle("Add Members")
              .navigationBarTitleDisplayMode(.inline)
              .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                  Button("Create") {
                    Task { await createGroup() }
                  }
                  .disabled(isCreating || trimmedGroupName.isEmpty || selectedMembers.isEmpty)
                }
              }
          }
        }
        .onChange(of: avatarItem) { _, newItem in
          Task {
            guard let data = try? await newItem?.loadTransferable(type: Data.self) else { return }
            guard let uiImage = UIImage(data: data) else { return }
            self.avatarData = data
            self.avatarImage = Image(uiImage: uiImage)
          }
        }
        .overlay {
          if isCreating {
            ZStack {
              Color.black.opacity(0.3).ignoresSafeArea()
              ProgressView()
                .padding()
                .background(palette.card)
                .cornerRadius(8)
            }
          }
        }
    }
  }

  private var membersStepView: some View {
    VStack(spacing: 0) {
      if let errorMessage {
        Text(errorMessage)
          .font(.footnote)
          .foregroundStyle(.red)
          .padding()
      }

      List {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
          if isSearching {
            HStack {
              Spacer()
              ProgressView()
              Spacer()
            }
            .listRowBackground(Color.clear)
          } else if searchResults.isEmpty {
            Text("No users found.")
              .foregroundStyle(palette.secondaryText)
              .listRowBackground(Color.clear)
          } else {
            groupedUsersSection(users: searchResults)
          }
        } else {
          groupedUsersSection(users: homeRows.compactMap(contactUser(for:)))
        }
      }
      .listStyle(.plain)
      .searchable(
        text: $searchQuery,
        isPresented: $isSearchPresented,
        placement: .navigationBarDrawer(displayMode: .automatic),
        prompt: "Search friends to add..."
      )
      .onChange(of: searchQuery) { _, newValue in
        scheduleSearch(query: newValue)
      }
    }
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
      Section(letter) {
        ForEach(grouped[letter] ?? [], id: \.userID) { user in
          memberRow(user: user)
        }
      }
    }
  }

  @ViewBuilder
  private func memberRow(user: ContactSearchUser) -> some View {
    let isSelected = selectedMembers.contains(user)
    Button {
      if isSelected {
        selectedMembers.remove(user)
      } else {
        selectedMembers.insert(user)
      }
    } label: {
      ContactSearchResultRow(user: user, isSaved: isSelected, palette: palette)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var infoStepView: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text("Enter a name and add a profile image for the group.")
          .font(.subheadline)
          .foregroundStyle(palette.secondaryText)
          .padding(.horizontal)
          .padding(.top)

        VStack(spacing: 0) {
          HStack(spacing: 16) {
            PhotosPicker(selection: $avatarItem, matching: .images) {
              if let avatarImage {
                avatarImage
                  .resizable()
                  .scaledToFill()
                  .frame(width: 56, height: 56)
                  .clipShape(Circle())
              } else {
                Image(systemName: "camera.fill")
                  .font(.title2)
                  .foregroundStyle(palette.accent)
                  .frame(width: 56, height: 56)
                  .background(palette.accent.opacity(0.12))
                  .clipShape(Circle())
              }
            }
            .buttonStyle(.plain)

            TextField("Group name", text: $groupName)
              .font(.body)
              .submitLabel(.next)
          }
          .padding()

          Divider().padding(.leading, 16)

          TextField("Description (optional)", text: $groupDescription, axis: .vertical)
            .font(.body)
            .lineLimit(2...5)
            .padding()
        }
        .background(palette.card)
        .cornerRadius(12)
        .padding(.horizontal)

        if let errorMessage {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
            .padding(.horizontal)
        }

        Spacer(minLength: 24)
      }
    }
  }

  private func scheduleSearch(query: String) {
    searchTask?.cancel()
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      searchResults = []
      isSearching = false
      return
    }

    isSearching = true
    searchTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 300_000_000)
      if Task.isCancelled { return }

      do {
        let results = try await ContactSearchService.search(config: config, query: trimmed)
        if !Task.isCancelled {
          self.searchResults = results
          self.isSearching = false
        }
      } catch {
        if !Task.isCancelled {
          self.searchResults = []
          self.isSearching = false
        }
      }
    }
  }

  @MainActor
  private func createGroup() async {
    isCreating = true
    errorMessage = nil
    defer { isCreating = false }

    do {
      var remoteAvatarUrl: String? = nil
      if let avatarData {
        remoteAvatarUrl = try await ChatRoomCreateService.uploadAvatar(imageData: avatarData, config: config)
      }

      let members = Array(selectedMembers)
      let memberIds = members.map { $0.userID }
      let trimmedDescription = groupDescription.trimmingCharacters(in: .whitespacesAndNewlines)
      let descriptionPayload: String? = trimmedDescription.isEmpty ? nil : trimmedDescription
      let result = try await ChatRoomCreateService.create(
        kind: .group,
        config: config,
        name: trimmedGroupName,
        description: descriptionPayload,
        memberIds: memberIds,
        avatarUrl: remoteAvatarUrl
      )

      // Prefer server roster when present; otherwise local selection + owner.
      let ownMember: [String: Any] = [
        "userId": config.userID,
        "name": config.name ?? config.username ?? "You",
        "role": "owner",
      ]
      let otherMembers: [[String: Any]] = members.map {
        ["userId": $0.userID, "name": $0.username, "role": "member"]
      }
      let localFallback = [ownMember] + otherMembers
      let resolvedMembers: [[String: Any]] = {
        let fromResult = result.members
        if !fromResult.isEmpty { return fromResult }
        return localFallback
      }()
      let avatar = result.avatarUrl ?? remoteAvatarUrl
      let role = result.role ?? "owner"

      let route = ChatRoute(
        chatId: result.chatID,
        title: result.name,
        peerUserId: nil,
        avatarURI: avatar,
        isGroup: true,
        myRole: role,
        initialRows: [],
        members: resolvedMembers,
        roomDescription: result.roomDescription ?? descriptionPayload,
        memberCount: result.memberCount ?? resolvedMembers.count,
        createdAt: result.createdAt
      )
      onCreated(route)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

/// Member picker for an *existing* group, pushed from the group profile's
/// "Members" screen. Same search/selection building blocks as
/// `ChatGroupCreationSheet` above, minus the name/avatar step — adding
/// members doesn't create a new room.
/// Push destination (NavigationStack) for adding members — same material/API as
/// New Chat / `ContactSearchView`: plain List, A–Z sections, home-style rows.
struct AddGroupMembersPickerView: View {
  @Environment(\.colorScheme) private var colorScheme

  let config: AppSessionConfig
  let chatId: String
  let excludedUserIds: Set<String>
  let onAdded: ([[String: Any]]) -> Void

  @State private var selectedMembers = Set<ContactSearchUser>()
  @State private var searchQuery = ""
  @State private var searchResults: [ContactSearchUser] = []
  @State private var isSearching = false
  @State private var hasSearched = false
  @State private var searchTask: Task<Void, Never>?
  @State private var isSaving = false
  @State private var errorMessage: String?
  @State private var isSearchPresented = false

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var candidates: [ContactSearchUser] {
    searchResults.filter { !excludedUserIds.contains($0.userID) }
  }

  private var selectedOrdered: [ContactSearchUser] {
    Array(selectedMembers).sorted {
      $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
    }
  }

  var body: some View {
    List {
      if !selectedOrdered.isEmpty {
        Section("Selected") {
          ForEach(selectedOrdered) { user in
            ContactSearchResultRow(user: user, isSaved: true, palette: palette)
              .contentShape(Rectangle())
              .onTapGesture { selectedMembers.remove(user) }
              .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
              .listRowBackground(Color.clear)
          }
        }
      }

      if let errorMessage {
        Section {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
            .listRowBackground(Color.clear)
        }
      }

      if !candidates.isEmpty {
        groupedUsersSection(users: candidates)
      } else if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Section {
          Text("Search for people to add. They join as members.")
            .font(.system(size: 14))
            .foregroundStyle(palette.secondaryText)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
      } else if isSearching {
        Section {
          HStack {
            Spacer()
            ProgressView()
            Spacer()
          }
          .listRowBackground(Color.clear)
          .listRowSeparator(.hidden)
        }
      } else if hasSearched {
        Section {
          Text("No people found.")
            .foregroundStyle(palette.secondaryText)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Add Members")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    .searchable(
      text: $searchQuery,
      isPresented: $isSearchPresented,
      placement: .navigationBarDrawer(displayMode: .automatic),
      prompt: "Username, phone, or ID"
    )
    .onChange(of: searchQuery) { _, newValue in
      scheduleSearch(query: newValue)
    }
    .onAppear { isSearchPresented = true }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button(selectedOrdered.isEmpty ? "Add" : "Add (\(selectedOrdered.count))") {
          Task { await addSelectedMembers() }
        }
        .fontWeight(.semibold)
        .disabled(selectedMembers.isEmpty || isSaving)
      }
    }
    .overlay {
      if isSaving {
        ZStack {
          Color.black.opacity(0.25).ignoresSafeArea()
          ProgressView()
            .padding(16)
            .background(palette.card)
            .cornerRadius(10)
        }
      }
    }
  }

  @ViewBuilder
  private func groupedUsersSection(users: [ContactSearchUser]) -> some View {
    var unique: [ContactSearchUser] = []
    var seen = Set<String>()
    for user in users {
      if seen.insert(user.userID).inserted {
        unique.append(user)
      }
    }
    let grouped = Dictionary(grouping: unique) { user in
      String(user.username.prefix(1)).uppercased()
    }
    let keys = grouped.keys.sorted()

    return ForEach(keys, id: \.self) { letter in
      Section(letter) {
        ForEach(grouped[letter] ?? []) { user in
          let selected = selectedMembers.contains(user)
          ContactSearchResultRow(user: user, isSaved: selected, palette: palette)
            .contentShape(Rectangle())
            .onTapGesture {
              if selected {
                selectedMembers.remove(user)
              } else {
                selectedMembers.insert(user)
              }
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(palette.border)
        }
      }
    }
  }

  private func scheduleSearch(query: String) {
    searchTask?.cancel()
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      searchResults = []
      isSearching = false
      hasSearched = false
      return
    }
    isSearching = true
    searchTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 350_000_000)
      if Task.isCancelled { return }
      do {
        let results = try await ContactSearchService.search(config: config, query: trimmed)
        if !Task.isCancelled {
          searchResults = results
          isSearching = false
          hasSearched = true
        }
      } catch {
        if !Task.isCancelled {
          searchResults = []
          isSearching = false
          hasSearched = true
        }
      }
    }
  }

  @MainActor
  private func addSelectedMembers() async {
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    let selected = Array(selectedMembers)
    do {
      let results = try await GroupMembersUpdateService.addMembers(
        chatId: chatId,
        memberIds: selected.map(\.userID),
        config: config
      )
      let addedIds = Set(results.filter(\.added).map(\.userId))
      guard !addedIds.isEmpty else {
        errorMessage = "Couldn't add the selected members."
        return
      }
      let addedRaw: [[String: Any]] = selected
        .filter { addedIds.contains($0.userID) }
        .map {
          [
            "userId": $0.userID,
            "name": $0.username,
            "role": "member",
            "profileImage": $0.profileImage ?? "",
            "avatarUri": $0.profileImage ?? "",
          ]
        }
      onAdded(addedRaw)
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

/// Legacy sheet entry point — multi-select with A–Z home seeds + search (New Chat style).
struct AddGroupMembersSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  let config: AppSessionConfig
  let chatId: String
  let excludedUserIds: Set<String>
  /// Home-list seeds for A–Z browsing (same avatar path as New Chat).
  var homeRows: [ChatHomeListRow] = []
  let onAdded: ([[String: Any]]) -> Void

  @State private var selectedMembers = Set<ContactSearchUser>()
  @State private var searchQuery = ""
  @State private var searchResults: [ContactSearchUser] = []
  @State private var isSearching = false
  @State private var searchTask: Task<Void, Never>?
  @State private var isSaving = false
  @State private var errorMessage: String?
  @FocusState private var isSearchFocused: Bool

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private var seedUsers: [ContactSearchUser] {
    homeRows.compactMap { row -> ContactSearchUser? in
      guard let peer = row.peerUserId, !peer.isEmpty else { return nil }
      if excludedUserIds.contains(peer) { return nil }
      return ContactSearchUser(payload: [
        "userId": peer,
        "username": row.title,
        "profileImage": row.avatarUri ?? "",
        "isAgent": row.isBuiltInAgentSurface || row.isBridgeAgentSurface || row.isAgentFriend,
        "agentId": row.peerAgentId ?? "",
        "tier": row.isGoldTier ? "gold" : "free",
      ])
    }
  }

  private var candidates: [ContactSearchUser] {
    let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    let source = trimmed.isEmpty ? seedUsers : searchResults
    return source.filter { !excludedUserIds.contains($0.userID) }
  }

  private var selectedOrdered: [ContactSearchUser] {
    Array(selectedMembers).sorted {
      $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
    }
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        // In-sheet search (not .searchable) — avoids detent jumps with keyboard.
        HStack(spacing: 10) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(palette.secondaryText)
          TextField("Search people…", text: $searchQuery)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($isSearchFocused)
          if !searchQuery.isEmpty {
            Button {
              searchQuery = ""
              scheduleSearch(query: "")
            } label: {
              Image(systemName: "xmark.circle.fill")
                .foregroundStyle(palette.secondaryText)
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.05))
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)

        if !selectedOrdered.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              ForEach(selectedOrdered) { user in
                Button {
                  selectedMembers.remove(user)
                } label: {
                  HStack(spacing: 6) {
                    Text(user.username)
                      .font(.system(size: 13, weight: .semibold))
                      .lineLimit(1)
                    Image(systemName: "xmark")
                      .font(.system(size: 10, weight: .bold))
                  }
                  .foregroundStyle(palette.buttonText)
                  .padding(.horizontal, 10)
                  .padding(.vertical, 7)
                  .background(Capsule(style: .continuous).fill(palette.accent))
                }
                .buttonStyle(.plain)
              }
            }
            .padding(.horizontal, 16)
          }
          .padding(.bottom, 8)
        }

        if let errorMessage {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        }

        // A–Z list (home seeds) or search results — ContactSearchResultRow uses shared avatars.
        List {
          let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty, isSearching {
            Section {
              HStack {
                Spacer()
                ProgressView()
                Spacer()
              }
              .listRowBackground(Color.clear)
            }
          } else if candidates.isEmpty {
            Section {
              Text(
                trimmed.isEmpty
                  ? "No contacts to show. Search by username, phone, or ID."
                  : "No people found."
              )
              .font(.system(size: 14))
              .foregroundStyle(palette.secondaryText)
              .listRowBackground(Color.clear)
              .listRowSeparator(.hidden)
            }
          } else {
            sheetGroupedUsersSection(users: candidates)
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
      }
      .background(Color.clear)
      .navigationTitle("Add Members")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.hidden, for: .navigationBar)
      .onChange(of: searchQuery) { _, newValue in
        scheduleSearch(query: newValue)
      }
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
          }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button(selectedOrdered.isEmpty ? "Add" : "Add (\(selectedOrdered.count))") {
            Task { await addSelectedMembers() }
          }
          .fontWeight(.semibold)
          .disabled(selectedMembers.isEmpty || isSaving)
        }
      }
      .overlay {
        if isSaving {
          ZStack {
            Color.black.opacity(0.25).ignoresSafeArea()
            ProgressView()
              .padding()
              .background(
                .ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
    .presentationBackground(.clear)
  }

  private func sheetGroupedUsersSection(users: [ContactSearchUser]) -> some View {
    var unique: [ContactSearchUser] = []
    var seen = Set<String>()
    for user in users {
      if seen.insert(user.userID).inserted {
        unique.append(user)
      }
    }
    let grouped = Dictionary(grouping: unique) { user in
      String(user.username.prefix(1)).uppercased()
    }
    let keys = grouped.keys.sorted()

    return ForEach(keys, id: \.self) { letter in
      Section(letter) {
        ForEach(grouped[letter] ?? [], id: \.userID) { user in
          let selected = selectedMembers.contains(user)
          Button {
            if selected {
              selectedMembers.remove(user)
            } else {
              selectedMembers.insert(user)
            }
          } label: {
            ContactSearchResultRow(user: user, isSaved: selected, palette: palette)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
          .listRowBackground(Color.clear)
          .listRowSeparatorTint(palette.border)
        }
      }
    }
  }

  private func scheduleSearch(query: String) {
    searchTask?.cancel()
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      searchResults = []
      isSearching = false
      return
    }

    isSearching = true
    searchTask = Task { @MainActor in
      try? await Task.sleep(nanoseconds: 300_000_000)
      if Task.isCancelled { return }

      do {
        let results = try await ContactSearchService.search(config: config, query: trimmed)
        if !Task.isCancelled {
          self.searchResults = results
          self.isSearching = false
        }
      } catch {
        if !Task.isCancelled {
          self.searchResults = []
          self.isSearching = false
        }
      }
    }
  }

  @MainActor
  private func addSelectedMembers() async {
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }

    let selected = Array(selectedMembers)
    do {
      let results = try await GroupMembersUpdateService.addMembers(
        chatId: chatId,
        memberIds: selected.map(\.userID),
        config: config
      )
      let addedIds = Set(results.filter(\.added).map(\.userId))
      guard !addedIds.isEmpty else {
        errorMessage = "Couldn't add the selected members."
        return
      }
      let addedRaw: [[String: Any]] = selected
        .filter { addedIds.contains($0.userID) }
        .map {
          [
            "userId": $0.userID,
            "name": $0.username,
            "role": "member",
            "profileImage": $0.profileImage ?? "",
            "avatarUri": $0.profileImage ?? "",
          ]
        }
      onAdded(addedRaw)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

/// Owner/admin editor for an existing group's identity — name, photo and
/// description. Saves via `GroupUpdateService.update` (PUT /group/:id) and hands
/// the fresh values back so the open profile + home row update without waiting
/// for a home reload.
struct GroupEditSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  let config: AppSessionConfig
  let chatId: String
  let initialAvatarUri: String?
  let isChannel: Bool
  let onSaved: (_ name: String, _ description: String, _ avatarUrl: String?) -> Void

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
    initialName: String,
    initialDescription: String,
    initialAvatarUri: String?,
    isChannel: Bool = false,
    onSaved: @escaping (String, String, String?) -> Void
  ) {
    self.config = config
    self.chatId = chatId
    self.initialAvatarUri = initialAvatarUri
    self.isChannel = isChannel
    self.onSaved = onSaved
    _name = State(initialValue: initialName)
    _descriptionText = State(initialValue: initialDescription)
  }

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 20) {
        HStack(spacing: 16) {
          PhotosPicker(selection: $avatarItem, matching: .images) {
            avatarThumb
          }
          .buttonStyle(.plain)

          TextField(isChannel ? "Channel name" : "Group name", text: $name)
            .font(.body)
            .submitLabel(.done)
        }
        .padding()
        .background(palette.card)
        .cornerRadius(12)
        .padding(.horizontal)

        VStack(alignment: .leading, spacing: 6) {
          Text("Description")
            .font(.headline)
            .padding(.horizontal, 4)
          TextField(
            isChannel ? "What's this channel about?" : "What's this group about?",
            text: $descriptionText,
            axis: .vertical
          )
            .lineLimit(2...5)
            .padding()
            .background(palette.card)
            .cornerRadius(12)
        }
        .padding(.horizontal)

        if let errorMessage {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.red)
            .padding(.horizontal)
        }

        Spacer()
      }
      .padding(.top)
      // Glass sheet: let the frosted material (below) show through instead of a
      // flat solid fill. The inner cards keep their tint for text contrast.
      .background(Color.clear)
      .navigationTitle(isChannel ? "Edit Channel" : "Edit Group")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button { dismiss() } label: { Image(systemName: "xmark") }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Save") { Task { await save() } }
            .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .overlay {
        if isSaving {
          ZStack {
            Color.black.opacity(0.3).ignoresSafeArea()
            ProgressView()
              .padding()
              .background(palette.card)
              .cornerRadius(8)
          }
        }
      }
      .onChange(of: avatarItem) { _, newItem in
        Task {
          guard let data = try? await newItem?.loadTransferable(type: Data.self) else { return }
          guard let uiImage = UIImage(data: data) else { return }
          self.avatarData = data
          self.avatarImage = Image(uiImage: uiImage)
        }
      }
    }
    // Frosted-glass sheet surface (replaces the old solid dark background).
    .presentationBackground(.ultraThinMaterial)
  }

  @ViewBuilder
  private var avatarThumb: some View {
    if let avatarImage {
      avatarImage
        .resizable()
        .scaledToFill()
        .frame(width: 56, height: 56)
        .clipShape(Circle())
    } else if let uri = initialAvatarUri?.trimmingCharacters(in: .whitespacesAndNewlines),
      !uri.isEmpty, let url = URL(string: uri) {
      AsyncImage(url: url) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        Image(systemName: "camera.fill")
          .font(.title2)
          .foregroundStyle(palette.accent)
      }
      .frame(width: 56, height: 56)
      .clipShape(Circle())
    } else {
      Image(systemName: "camera.fill")
        .font(.title2)
        .foregroundStyle(palette.accent)
        .frame(width: 56, height: 56)
        .background(palette.accent.opacity(0.12))
        .clipShape(Circle())
    }
  }

  private func save() async {
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      var remoteAvatarUrl: String? = nil
      if let avatarData {
        remoteAvatarUrl = try await ChatRoomCreateService.uploadAvatar(
          imageData: avatarData, config: config)
      }
      let result = try await GroupUpdateService.update(
        chatId: chatId,
        name: name,
        description: descriptionText,
        avatarUrl: remoteAvatarUrl,
        config: config
      )
      onSaved(
        result.name ?? name.trimmingCharacters(in: .whitespacesAndNewlines),
        result.description ?? descriptionText,
        result.avatarUrl ?? remoteAvatarUrl ?? initialAvatarUri
      )
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

// MARK: - Member admin actions (home material sheet)

/// Frosted sheet for promote / demote / remove — same surface as GroupEditSheet.
struct GroupMemberActionsSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme

  let name: String
  let role: String
  let onPromote: () -> Void
  let onDemote: () -> Void
  let onRemove: () -> Void

  private var palette: AppThemePalette { AppThemePalette.resolve(for: colorScheme) }

  private var roleLabel: String {
    switch role.lowercased() {
    case "owner": return "Owner"
    case "admin": return "Admin"
    default: return "Member"
    }
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 14) {
        VStack(spacing: 4) {
          Text(name)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(palette.text)
            .multilineTextAlignment(.center)
          Text(roleLabel)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(palette.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)

        VStack(spacing: 0) {
          if role.lowercased() == "admin" {
            actionRow(title: "Dismiss as Admin", systemImage: "arrow.down.circle", destructive: false) {
              onDemote()
              dismiss()
            }
            divider
          } else {
            actionRow(title: "Make Admin", systemImage: "arrow.up.circle", destructive: false) {
              onPromote()
              dismiss()
            }
            divider
          }
          actionRow(title: "Remove from Group", systemImage: "person.badge.minus", destructive: true) {
            onRemove()
            dismiss()
          }
        }
        .background(
          (colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.05))
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)

        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .background(Color.clear)
      .navigationTitle("Member")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.hidden, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button { dismiss() } label: {
            Image(systemName: "xmark")
              .font(.system(size: 15, weight: .semibold))
          }
        }
      }
    }
    .presentationBackground(.clear)
    .presentationDetents([.medium])
    .presentationDragIndicator(.visible)
  }

  private var divider: some View {
    Rectangle()
      .fill(palette.border.opacity(0.55))
      .frame(height: 1 / UIScreen.main.scale)
      .padding(.leading, 52)
  }

  private func actionRow(
    title: String,
    systemImage: String,
    destructive: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 14) {
        Image(systemName: systemImage)
          .font(.system(size: 17, weight: .regular))
          .foregroundStyle(destructive ? Color.red : palette.text)
          .frame(width: 24)
        Text(title)
          .font(.system(size: 17, weight: .regular))
          .foregroundStyle(destructive ? Color.red : palette.text)
        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 16)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
