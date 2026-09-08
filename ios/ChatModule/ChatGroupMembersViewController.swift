import UIKit
import SwiftUI

/// Group members roster — home-list style (plain rows, avatar + name).
/// Pushed on the profile navigation stack. Add lives only in the nav trailing button.
final class ChatGroupMembersViewController: UIViewController {
  struct MemberItem {
    let userId: String
    let name: String
    let roleLabel: String
    let isAdmin: Bool
    let avatarUri: String?
  }

  var chatId: String = ""
  var members: [MemberItem] = []
  var canAddMembers: Bool = false
  var onAddMembers: (() -> Void)?
  var onMemberSelected: ((MemberItem) -> Void)?
  /// Optional host hooks for long-press / swipe admin actions.
  var onPromote: ((MemberItem) -> Void)?
  var onDemote: ((MemberItem) -> Void)?
  var onRemove: ((MemberItem) -> Void)?

  private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterial))
  private let tableView = UITableView(frame: .zero, style: .plain)
  private let emptyLabel = UILabel()

  private var owners: [MemberItem] {
    members.filter { $0.roleLabel == "Owner" && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
  }
  private var admins: [MemberItem] {
    members.filter { $0.roleLabel == "Admin" && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
  }
  private var regulars: [MemberItem] {
    members.filter {
      $0.roleLabel != "Owner" && $0.roleLabel != "Admin"
        && !$0.name.trimmingCharacters(in: .whitespaces).isEmpty
    }
  }

  private enum SectionKind {
    case owners
    case admins
    case members
    case empty
  }

  private var sectionKinds: [SectionKind] {
    var kinds: [SectionKind] = []
    let hasAny = !owners.isEmpty || !admins.isEmpty || !regulars.isEmpty
    if !hasAny {
      kinds.append(.empty)
    } else {
      if !owners.isEmpty { kinds.append(.owners) }
      if !admins.isEmpty { kinds.append(.admins) }
      if !regulars.isEmpty { kinds.append(.members) }
    }
    return kinds
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    setup()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    NSLog(
      "[WhoAmI] MembersUIKit.viewWillAppear chatId=%@ members=%d canAdd=%@",
      chatId.isEmpty ? "<none>" : String(chatId.prefix(12)),
      members.count,
      canAddMembers ? "Y" : "N"
    )
    tableView.reloadData()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    blurView.frame = view.bounds
    tableView.frame = view.bounds
    emptyLabel.frame = CGRect(x: 24, y: 160, width: view.bounds.width - 48, height: 40)
  }

  func applyMembers(_ next: [MemberItem]) {
    // Drop junk rows (no id / no usable name).
    members = next.filter {
      !$0.userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    tableView.reloadData()
  }

  private func setup() {
    title = "Members"
    view.backgroundColor = .clear
    navigationItem.largeTitleDisplayMode = .never

    // Soft material background (not solid black).
    blurView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(blurView)

    tableView.dataSource = self
    tableView.delegate = self
    tableView.backgroundColor = .clear
    tableView.separatorStyle = .singleLine
    tableView.separatorInset = UIEdgeInsets(top: 0, left: 90, bottom: 0, right: 22)
    tableView.rowHeight = 76
    tableView.register(
      ChatGroupMemberHomeStyleCell.self,
      forCellReuseIdentifier: ChatGroupMemberHomeStyleCell.reuseId
    )
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "empty_cell")
    tableView.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 24, right: 0)
    tableView.tableFooterView = UIView()
    view.addSubview(tableView)

    emptyLabel.isHidden = true

    // Add Members only as trailing nav action — never a list tab/row.
    if canAddMembers {
      navigationItem.rightBarButtonItem = UIBarButtonItem(
        image: UIImage(systemName: "person.badge.plus"),
        style: .plain,
        target: self,
        action: #selector(addMembersTapped)
      )
      navigationItem.rightBarButtonItem?.accessibilityLabel = "Add Members"
    }

    // Parent navigation owns the bar chrome.
    let appearance = UINavigationBarAppearance()
    appearance.configureWithDefaultBackground()
    navigationItem.standardAppearance = appearance
    navigationItem.scrollEdgeAppearance = appearance
    navigationItem.compactAppearance = appearance
  }

  @objc private func addMembersTapped() {
    onAddMembers?()
  }

  private func items(for kind: SectionKind) -> [MemberItem] {
    switch kind {
    case .owners: return owners
    case .admins: return admins
    case .members: return regulars
    default: return []
    }
  }

  private func sectionTitle(for kind: SectionKind) -> String? {
    switch kind {
    case .owners: return owners.count == 1 ? "Owner" : "Owners"
    case .admins: return "Admins"
    case .members: return regulars.count == 1 ? "Member" : "Members"
    default: return nil
    }
  }
}

extension ChatGroupMembersViewController: UITableViewDataSource, UITableViewDelegate {
  func numberOfSections(in tableView: UITableView) -> Int {
    sectionKinds.count
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    guard section < sectionKinds.count else { return 0 }
    switch sectionKinds[section] {
    case .empty: return 1
    case .owners, .admins, .members:
      return items(for: sectionKinds[section]).count
    }
  }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    guard section < sectionKinds.count else { return nil }
    return sectionTitle(for: sectionKinds[section])
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let kind = sectionKinds[indexPath.section]
    switch kind {
    case .empty:
      let cell = tableView.dequeueReusableCell(withIdentifier: "empty_cell", for: indexPath)
      var content = UIListContentConfiguration.subtitleCell()
      content.text = "No members yet"
      content.secondaryText = "Pull to refresh the home list, then reopen."
      content.textProperties.color = .secondaryLabel
      content.secondaryTextProperties.color = .tertiaryLabel
      cell.contentConfiguration = content
      cell.backgroundColor = .clear
      cell.selectionStyle = .none
      return cell

    case .owners, .admins, .members:
      let cell = tableView.dequeueReusableCell(
        withIdentifier: ChatGroupMemberHomeStyleCell.reuseId,
        for: indexPath
      ) as! ChatGroupMemberHomeStyleCell
      let item = items(for: kind)[indexPath.row]
      cell.configure(item: item)
      return cell
    }
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    // Tap does nothing — hold (context menu) owns member actions.
    tableView.deselectRow(at: indexPath, animated: true)
  }

  // Long-press context menu (hold) — not a static tab menu.
  func tableView(
    _ tableView: UITableView,
    contextMenuConfigurationForRowAt indexPath: IndexPath,
    point: CGPoint
  ) -> UIContextMenuConfiguration? {
    let kind = sectionKinds[indexPath.section]
    guard kind != .empty else { return nil }
    let list = items(for: kind)
    guard indexPath.row < list.count else { return nil }
    let item = list[indexPath.row]

    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      guard let self else { return nil }
      var children: [UIMenuElement] = []

      // Hold only — no swipe. Manage opens the material sheet; quick actions
      // still available as direct menu items.
      if self.canAddMembers, item.roleLabel != "Owner" {
        children.append(
          UIAction(
            title: "Manage",
            image: UIImage(systemName: "person.crop.circle.badge.checkmark")
          ) { _ in
            self.onMemberSelected?(item)
          }
        )
        if item.roleLabel == "Member" {
          children.append(
            UIAction(title: "Promote to Admin", image: UIImage(systemName: "arrow.up.circle")) { _ in
              self.onPromote?(item)
            }
          )
        } else if item.roleLabel == "Admin" {
          children.append(
            UIAction(title: "Demote to Member", image: UIImage(systemName: "arrow.down.circle")) { _ in
              self.onDemote?(item)
            }
          )
        }
        children.append(
          UIAction(
            title: "Remove from Group",
            image: UIImage(systemName: "person.badge.minus"),
            attributes: .destructive
          ) { _ in
            self.onRemove?(item)
          }
        )
      }

      return children.isEmpty ? nil : UIMenu(title: item.name, children: children)
    }
  }
}

// MARK: - Home-style member cell (avatar + name + role)

private final class ChatGroupMemberHomeStyleCell: UITableViewCell {
  static let reuseId = "ChatGroupMemberHomeStyleCell"

  private let avatarView = UIImageView()
  private let fallbackLabel = UILabel()
  private let nameLabel = UILabel()
  private let roleLabel = UILabel()
  private let chevron = UIImageView()

  private var loadToken = UUID()
  private var configuredUserId: String = ""
  private var configuredURL: String = ""

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    backgroundColor = .clear
    contentView.backgroundColor = .clear

    avatarView.translatesAutoresizingMaskIntoConstraints = false
    avatarView.contentMode = .scaleAspectFill
    avatarView.clipsToBounds = true
    avatarView.layer.cornerRadius = 28
    contentView.addSubview(avatarView)

    fallbackLabel.translatesAutoresizingMaskIntoConstraints = false
    fallbackLabel.font = .systemFont(ofSize: 18, weight: .bold)
    fallbackLabel.textColor = .white
    fallbackLabel.textAlignment = .center
    contentView.addSubview(fallbackLabel)

    nameLabel.translatesAutoresizingMaskIntoConstraints = false
    nameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
    nameLabel.textColor = .label
    nameLabel.lineBreakMode = .byTruncatingTail
    contentView.addSubview(nameLabel)

    roleLabel.translatesAutoresizingMaskIntoConstraints = false
    roleLabel.font = .systemFont(ofSize: 14, weight: .regular)
    roleLabel.textColor = .secondaryLabel
    contentView.addSubview(roleLabel)

    chevron.translatesAutoresizingMaskIntoConstraints = false
    chevron.image = UIImage(systemName: "chevron.right")
    chevron.tintColor = UIColor.secondaryLabel.withAlphaComponent(0.55)
    chevron.contentMode = .scaleAspectFit
    contentView.addSubview(chevron)

    NSLayoutConstraint.activate([
      avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
      avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      avatarView.widthAnchor.constraint(equalToConstant: 56),
      avatarView.heightAnchor.constraint(equalToConstant: 56),

      fallbackLabel.centerXAnchor.constraint(equalTo: avatarView.centerXAnchor),
      fallbackLabel.centerYAnchor.constraint(equalTo: avatarView.centerYAnchor),

      nameLabel.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
      nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
      nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),

      roleLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
      roleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -8),
      roleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 3),
      roleLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -16),

      chevron.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22),
      chevron.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      chevron.widthAnchor.constraint(equalToConstant: 12),
      chevron.heightAnchor.constraint(equalToConstant: 16),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    // Keep loadToken identity switch in configure — do not blank the image here
    // so a recycled cell can still paint from disk/memory before configure runs.
    loadToken = UUID()
    configuredUserId = ""
    configuredURL = ""
  }

  func configure(item: ChatGroupMembersViewController.MemberItem) {
    let sameEntity = configuredUserId == item.userId
    configuredUserId = item.userId
    nameLabel.text = item.name
    if item.roleLabel == "Owner" || item.roleLabel == "Admin" {
      roleLabel.text = item.roleLabel
      roleLabel.isHidden = false
    } else {
      roleLabel.text = nil
      roleLabel.isHidden = true
    }

    let colors = ChatProfileAppearanceStore.avatarColors(
      title: item.name,
      peerUserId: item.userId,
      chatId: nil
    )
    avatarView.backgroundColor = colors.0
    fallbackLabel.text = ChatHomeCardCell.getFallbackInitials(from: item.name)

    let resolved = ChatAvatarURLResolver.resolve(
      rawAvatar: item.avatarUri,
      peerUserId: item.userId,
      chatId: nil,
      preferPushAvatar: true,
      isAgent: false,
      agentId: nil,
      displayName: item.name
    ) ?? item.avatarUri

    let url = resolved?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let urlChanged = url != configuredURL
    configuredURL = url

    // Memory/disk hit: paint immediately (no initials flash).
    if !url.isEmpty, let cached = ChatAvatarImageStore.cached(for: url) {
      VibeAvatarDisplay.apply(
        cached,
        to: avatarView,
        fallbackLabel: fallbackLabel,
        animated: sameEntity && urlChanged,
        keepPreviousIfNil: false
      )
      return
    }

    // Same entity + same URL still loading: keep whatever is on screen.
    if sameEntity, !urlChanged, avatarView.image != nil {
      fallbackLabel.isHidden = true
      return
    }

    // New entity with no cache: show initials only.
    if !sameEntity || urlChanged {
      if !sameEntity {
        avatarView.image = nil
        fallbackLabel.isHidden = false
      }
      // URL changed but same entity: keep previous photo until new load finishes.
    }

    guard !url.isEmpty else {
      VibeAvatarDisplay.apply(
        nil,
        to: avatarView,
        fallbackLabel: fallbackLabel,
        animated: false,
        keepPreviousIfNil: false
      )
      return
    }

    let token = UUID()
    loadToken = token
    let userId = item.userId
    Task { @MainActor in
      let image = await ChatAvatarImageStore.load(from: url)
      guard self.loadToken == token, self.configuredUserId == userId else { return }
      VibeAvatarDisplay.apply(
        image,
        to: self.avatarView,
        fallbackLabel: self.fallbackLabel,
        animated: self.avatarView.image != nil,
        keepPreviousIfNil: true
      )
    }
  }
}
