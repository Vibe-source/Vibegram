import UIKit

private enum ChatNativeNewChatQueryKind {
  case userId
  case phone
  case username
}

private struct ChatNativeNewChatTheme {
  let isDark: Bool
  let backgroundColor: UIColor
  let surfaceColor: UIColor
  let textColor: UIColor
  let secondaryTextColor: UIColor
  let primaryColor: UIColor
  let rowAvatarColor: UIColor

  static func resolve(from payload: [String: Any]?) -> ChatNativeNewChatTheme {
    let isDark = (payload?["isDark"] as? Bool) ?? false

    let defaultBackground =
      isDark
      ? UIColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1.0)
      : UIColor(red: 0.96, green: 0.95, blue: 0.94, alpha: 1.0)
    let defaultSurface = isDark ? UIColor(red: 0.14, green: 0.14, blue: 0.16, alpha: 1.0) : .white
    let defaultText = isDark ? UIColor(red: 0.92, green: 0.91, blue: 0.95, alpha: 1.0) : UIColor(
      red: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)
    let defaultSecondaryText =
      isDark
      ? UIColor(red: 0.62, green: 0.60, blue: 0.66, alpha: 1.0)
      : UIColor(red: 0.43, green: 0.42, blue: 0.46, alpha: 1.0)
    let defaultPrimary = isDark ? UIColor(red: 0.49, green: 0.72, blue: 0.72, alpha: 1.0) : UIColor(
      red: 0.24, green: 0.48, blue: 0.85, alpha: 1.0)

    let backgroundColor = chatNativeNewChatColor(payload?["background"]) ?? defaultBackground
    let surfaceColor = chatNativeNewChatColor(payload?["surface"]) ?? defaultSurface
    let textColor = chatNativeNewChatColor(payload?["text"]) ?? defaultText
    let secondaryTextColor = chatNativeNewChatColor(payload?["textSecondary"]) ?? defaultSecondaryText
    let primaryColor = chatNativeNewChatColor(payload?["primary"]) ?? defaultPrimary
    let rowAvatarColor = primaryColor.withAlphaComponent(isDark ? 0.24 : 0.16)

    return ChatNativeNewChatTheme(
      isDark: isDark,
      backgroundColor: backgroundColor,
      surfaceColor: surfaceColor,
      textColor: textColor,
      secondaryTextColor: secondaryTextColor,
      primaryColor: primaryColor,
      rowAvatarColor: rowAvatarColor
    )
  }
}

private struct ChatNativeNewChatUser {
  let userId: String
  let username: String
  let handle: String?
  let phoneNumber: String?
  let profileImage: String?
  let publicKey: String?

  init?(raw: [String: Any]) {
    let resolvedUserId =
      chatNativeNewChatString(raw["userId"])
      ?? chatNativeNewChatString(raw["id"])
    guard let resolvedUserId, !resolvedUserId.isEmpty else { return nil }

    let resolvedHandle =
      chatNativeNewChatString(raw["username"])
      ?? chatNativeNewChatString(raw["handle"])
    let nameKeys = ["displayName", "display_name", "fullName", "full_name", "name"]
    var foundName: String? = nil
    for key in nameKeys {
      if let val = chatNativeNewChatString(raw[key]) {
        if !chatNativeNewChatLooksLikeUUID(val) {
          foundName = val
          break
        }
      }
    }

    if foundName == nil {
      if let h = resolvedHandle, !chatNativeNewChatLooksLikeUUID(h) {
        foundName = h
      }
    }

    let resolvedUsername = foundName ?? "Vibegram User"

    userId = resolvedUserId
    username = resolvedUsername
    handle = resolvedHandle
    phoneNumber =
      chatNativeNewChatString(raw["phoneNumber"])
      ?? chatNativeNewChatString(raw["phone_number"])
      ?? chatNativeNewChatString(raw["phone"])
    profileImage =
      chatNativeNewChatString(raw["profileImage"])
      ?? chatNativeNewChatString(raw["profile_image"])
      ?? chatNativeNewChatString(raw["avatarUrl"])
      ?? chatNativeNewChatString(raw["avatar_url"])
    publicKey =
      chatNativeNewChatString(raw["publicKey"])
      ?? chatNativeNewChatString(raw["public_key"])
      ?? chatNativeNewChatString(raw["friendKey"])
      ?? chatNativeNewChatString(raw["friendPublicKey"])
  }

  var subtitle: String {
    if let phoneNumber, !phoneNumber.isEmpty {
      return phoneNumber
    }
    if let handle, !handle.isEmpty, !chatNativeNewChatLooksLikeUUID(handle),
      handle.localizedCaseInsensitiveCompare(username) != .orderedSame
    {
      return "@\(handle.trimmingCharacters(in: CharacterSet(charactersIn: "@")))"
    }
    return "User is in Vibegram"
  }

  var initials: String {
    let parts = username
      .split(separator: " ")
      .map(String.init)
      .filter { !$0.isEmpty }
    if parts.isEmpty {
      return String(userId.prefix(1)).uppercased()
    }
    if parts.count == 1 {
      return String(parts[0].prefix(1)).uppercased()
    }
    let first = String(parts[0].prefix(1))
    let second = String(parts[1].prefix(1))
    return (first + second).uppercased()
  }

  var payload: [String: Any] {
    var value: [String: Any] = [
      "id": userId,
      "userId": userId,
      "username": username,
      "displayName": username,
    ]
    if let handle { value["handle"] = handle }
    if let phoneNumber { value["phoneNumber"] = phoneNumber }
    if let profileImage { value["profileImage"] = profileImage }
    if let publicKey { value["publicKey"] = publicKey }
    return value
  }
}

private final class ChatNativeNewChatUserCell: UITableViewCell {
  static let reuseIdentifier = "ChatNativeNewChatUserCell"

  private let avatarView = UIView()
  private let avatarLabel = UILabel()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let stack = UIStackView()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    configureLayout()
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    avatarLabel.text = nil
    titleLabel.text = nil
    subtitleLabel.text = nil
  }

  func configure(user: ChatNativeNewChatUser, theme: ChatNativeNewChatTheme) {
    backgroundColor = .clear
    contentView.backgroundColor = .clear

    avatarLabel.text = user.initials
    titleLabel.text = user.username
    subtitleLabel.text = user.subtitle

    avatarView.backgroundColor = theme.rowAvatarColor
    avatarLabel.textColor = theme.primaryColor
    titleLabel.textColor = theme.textColor
    subtitleLabel.textColor = theme.secondaryTextColor
  }

  private func configureLayout() {
    selectionStyle = .none
    accessoryType = .disclosureIndicator

    avatarView.translatesAutoresizingMaskIntoConstraints = false
    avatarView.layer.cornerRadius = 20
    avatarView.clipsToBounds = true
    contentView.addSubview(avatarView)

    avatarLabel.translatesAutoresizingMaskIntoConstraints = false
    avatarLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    avatarLabel.textAlignment = .center
    avatarView.addSubview(avatarLabel)

    stack.axis = .vertical
    stack.alignment = .leading
    stack.spacing = 2
    stack.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(stack)

    titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
    titleLabel.numberOfLines = 1
    stack.addArrangedSubview(titleLabel)

    subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
    subtitleLabel.numberOfLines = 1
    stack.addArrangedSubview(subtitleLabel)

    NSLayoutConstraint.activate([
      avatarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
      avatarView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
      avatarView.widthAnchor.constraint(equalToConstant: 40),
      avatarView.heightAnchor.constraint(equalToConstant: 40),

      avatarLabel.leadingAnchor.constraint(equalTo: avatarView.leadingAnchor),
      avatarLabel.trailingAnchor.constraint(equalTo: avatarView.trailingAnchor),
      avatarLabel.topAnchor.constraint(equalTo: avatarView.topAnchor),
      avatarLabel.bottomAnchor.constraint(equalTo: avatarView.bottomAnchor),

      stack.leadingAnchor.constraint(equalTo: avatarView.trailingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
      stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
    ])
  }
}

final class ChatNativeNewChatViewController: UIViewController,
  UITableViewDataSource,
  UITableViewDelegate,
  UISearchBarDelegate,
  UIAdaptivePresentationControllerDelegate
{
  var onResult: (([String: Any]) -> Void)?

  private let apiBaseUrl: String
  private let authToken: String?
  private let currentUserIdUpper: String
  private let theme: ChatNativeNewChatTheme

  private let searchBar = UISearchBar(frame: .zero)
  private let tableView = UITableView(frame: .zero, style: .plain)
  private let statusLabel = UILabel()
  private let loadingIndicator = UIActivityIndicatorView(style: .medium)

  private var results: [ChatNativeNewChatUser] = []
  private var searchDebounceWorkItem: DispatchWorkItem?
  private var searchTask: URLSessionDataTask?
  private var latestSearchToken: Int = 0
  private var didFinish = false

  init(apiBaseUrl: String, authToken: String?, currentUserId: String, themePayload: [String: Any]?) {
    self.apiBaseUrl = apiBaseUrl
    self.authToken = authToken
    self.currentUserIdUpper = currentUserId.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    self.theme = ChatNativeNewChatTheme.resolve(from: themePayload)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    nil
  }

  deinit {
    searchDebounceWorkItem?.cancel()
    searchTask?.cancel()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    configureLayout()
    configureAppearance()
    if ((ChatEngine.shared.getTransportStatus()["transportMode"] as? String) ?? "direct")
      == "bridge_text"
    {
      searchBar.isUserInteractionEnabled = false
      searchBar.searchTextField.isEnabled = false
      updateStatus("Search is disabled in blackout mode")
      return
    }
    updateStatus("Find by username, phone, or user ID")
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    if ((ChatEngine.shared.getTransportStatus()["transportMode"] as? String) ?? "direct")
      == "bridge_text"
    {
      return
    }
    searchBar.becomeFirstResponder()
  }

  private func configureAppearance() {
    title = "New Chat"
    navigationItem.largeTitleDisplayMode = .never
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .close,
      target: self,
      action: #selector(closeTapped)
    )
    presentationController?.delegate = self

    view.backgroundColor = theme.backgroundColor

    let navAppearance = UINavigationBarAppearance()
    navAppearance.configureWithOpaqueBackground()
    navAppearance.backgroundColor = theme.backgroundColor
    navAppearance.shadowColor = .clear
    navAppearance.titleTextAttributes = [.foregroundColor: theme.textColor]
    navAppearance.largeTitleTextAttributes = [.foregroundColor: theme.textColor]
    navigationController?.navigationBar.standardAppearance = navAppearance
    navigationController?.navigationBar.scrollEdgeAppearance = navAppearance
    navigationController?.navigationBar.compactAppearance = navAppearance
    navigationController?.view.backgroundColor = theme.backgroundColor
    navigationController?.navigationBar.tintColor = theme.textColor

    searchBar.searchBarStyle = .minimal
    searchBar.autocapitalizationType = .none
    searchBar.autocorrectionType = .no
    searchBar.delegate = self
    searchBar.placeholder = "Search username, phone, or ID"
    searchBar.tintColor = theme.primaryColor
    let searchField = searchBar.searchTextField
    searchField.backgroundColor = theme.surfaceColor
    searchField.textColor = theme.textColor
    searchField.attributedPlaceholder = NSAttributedString(
      string: "Search username, phone, or ID",
      attributes: [.foregroundColor: theme.secondaryTextColor.withAlphaComponent(0.86)]
    )

    tableView.backgroundColor = theme.backgroundColor
    tableView.separatorInset = UIEdgeInsets(top: 0, left: 68, bottom: 0, right: 0)
    tableView.separatorColor = theme.secondaryTextColor.withAlphaComponent(0.22)
    tableView.keyboardDismissMode = .interactive
    tableView.rowHeight = 62
    tableView.showsVerticalScrollIndicator = false
    tableView.register(ChatNativeNewChatUserCell.self, forCellReuseIdentifier: ChatNativeNewChatUserCell.reuseIdentifier)
    tableView.dataSource = self
    tableView.delegate = self

    statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
    statusLabel.textAlignment = .center
    statusLabel.numberOfLines = 2
    statusLabel.textColor = theme.secondaryTextColor

    loadingIndicator.color = theme.primaryColor

    loadingIndicator.hidesWhenStopped = true
  }

  private func configureLayout() {
    searchBar.translatesAutoresizingMaskIntoConstraints = false
    tableView.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    loadingIndicator.translatesAutoresizingMaskIntoConstraints = false

    view.addSubview(searchBar)
    view.addSubview(tableView)
    view.addSubview(statusLabel)
    view.addSubview(loadingIndicator)

    NSLayoutConstraint.activate([
      searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
      searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
      searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),

      statusLabel.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 8),
      statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
      statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),

      tableView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      loadingIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      loadingIndicator.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
    ])
  }

  private func updateStatus(_ value: String) {
    statusLabel.text = value
    statusLabel.isHidden = false
  }

  private func scheduleSearch(for rawQuery: String) {
    let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)

    searchDebounceWorkItem?.cancel()
    searchTask?.cancel()
    latestSearchToken += 1

    if query.isEmpty {
      results = []
      tableView.reloadData()
      loadingIndicator.stopAnimating()
      updateStatus("Find by username, phone, or user ID")
      return
    }

    let kind = queryKind(for: query)
    let shouldSearch: Bool
    switch kind {
    case .phone:
      let digitsCount = query.filter(\.isNumber).count
      shouldSearch = digitsCount >= 7
      if !shouldSearch {
        updateStatus("Type at least 7 digits for phone search")
      }
    case .userId:
      shouldSearch = true
    case .username:
      shouldSearch = query.count >= 3
      if !shouldSearch {
        updateStatus("Type at least 3 characters for username search")
      }
    }

    results = []
    tableView.reloadData()
    guard shouldSearch else {
      loadingIndicator.stopAnimating()
      return
    }

    loadingIndicator.startAnimating()
    statusLabel.isHidden = true

    let requestToken = latestSearchToken
    let workItem = DispatchWorkItem { [weak self] in
      self?.performSearch(query: query, kind: kind, requestToken: requestToken)
    }
    searchDebounceWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
  }

  private func performSearch(query: String, kind: ChatNativeNewChatQueryKind, requestToken: Int) {
    guard let url = buildSearchURL(for: query, kind: kind) else {
      completeSearch(requestToken: requestToken, users: [], statusText: "Invalid server URL")
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 14
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if let authToken, !authToken.isEmpty {
      request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
    }

    searchTask = VibeHTTP.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }

      if requestToken != self.latestSearchToken {
        return
      }

      if let error {
        self.completeSearch(
          requestToken: requestToken,
          users: [],
          statusText: "Search failed: \(error.localizedDescription)"
        )
        return
      }

      guard let httpResponse = response as? HTTPURLResponse else {
        self.completeSearch(requestToken: requestToken, users: [], statusText: "Invalid response")
        return
      }

      if httpResponse.statusCode == 404 {
        self.completeSearch(requestToken: requestToken, users: [], statusText: "No user found")
        return
      }

      guard (200...299).contains(httpResponse.statusCode), let data else {
        self.completeSearch(
          requestToken: requestToken,
          users: [],
          statusText: "Search unavailable (\(httpResponse.statusCode))"
        )
        return
      }

      do {
        let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let users = self.parseUsers(from: json)
        let statusText = users.isEmpty ? "No user found" : ""
        self.completeSearch(requestToken: requestToken, users: users, statusText: statusText)
      } catch {
        self.completeSearch(
          requestToken: requestToken,
          users: [],
          statusText: "Could not parse search response"
        )
      }
    }
    searchTask?.resume()
  }

  private func completeSearch(requestToken: Int, users: [ChatNativeNewChatUser], statusText: String) {
    DispatchQueue.main.async {
      guard requestToken == self.latestSearchToken else { return }
      self.loadingIndicator.stopAnimating()
      self.results = users
      self.tableView.reloadData()
      if users.isEmpty {
        self.updateStatus(statusText.isEmpty ? "No user found" : statusText)
      } else {
        self.statusLabel.isHidden = true
      }
    }
  }

  private func parseUsers(from value: Any) -> [ChatNativeNewChatUser] {
    let rawEntries: [[String: Any]]
    if let array = value as? [[String: Any]] {
      rawEntries = array
    } else if let dictionary = value as? [String: Any] {
      if let nestedArray = dictionary["data"] as? [[String: Any]] {
        rawEntries = nestedArray
      } else if let nestedDictionary = dictionary["data"] as? [String: Any] {
        rawEntries = [nestedDictionary]
      } else {
        rawEntries = [dictionary]
      }
    } else {
      rawEntries = []
    }

    var usersById: [String: ChatNativeNewChatUser] = [:]
    for rawEntry in rawEntries {
      guard let user = ChatNativeNewChatUser(raw: rawEntry) else { continue }
      let normalizedId = user.userId.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      if normalizedId.isEmpty || normalizedId == currentUserIdUpper { continue }
      usersById[normalizedId] = user
    }
    return Array(usersById.values).sorted { lhs, rhs in
      lhs.username.localizedCaseInsensitiveCompare(rhs.username) == .orderedAscending
    }
  }

  private func buildSearchURL(for query: String, kind: ChatNativeNewChatQueryKind) -> URL? {
    var base = apiBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }
    guard !base.isEmpty else { return nil }

    let hasApiSuffix = base.lowercased().hasSuffix("/api")
    let pathBase = hasApiSuffix ? base : "\(base)/api"

    let endpoint: String
    switch kind {
    case .userId:
      let encodedId = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
      endpoint = "/user/\(encodedId)"
    case .phone:
      let encodedPhone = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
      endpoint = "/user/phone/\(encodedPhone)"
    case .username:
      let normalizedUsername =
        query.hasPrefix("@") ? String(query.dropFirst()) : query
      let encodedUsername =
        normalizedUsername.lowercased().addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        ?? normalizedUsername.lowercased()
      endpoint = "/user/name/\(encodedUsername)"
    }

    return URL(string: pathBase + endpoint)
  }

  private func queryKind(for query: String) -> ChatNativeNewChatQueryKind {
    if chatNativeNewChatLooksLikeUUID(query) {
      return .userId
    }
    let digitsCount = query.filter(\.isNumber).count
    let phoneCharacters = Set(query).isSubset(
      of: Set("0123456789+-() ".map { $0 })
    )
    if phoneCharacters && digitsCount >= 7 {
      return .phone
    }
    return .username
  }

  @objc private func closeTapped() {
    finish(["action": "cancel"])
  }

  private func finish(_ payload: [String: Any]) {
    guard !didFinish else { return }
    didFinish = true
    searchDebounceWorkItem?.cancel()
    searchTask?.cancel()
    onResult?(payload)
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    finish(["action": "cancel"])
  }

  func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    scheduleSearch(for: searchText)
  }

  func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    searchBar.resignFirstResponder()
    scheduleSearch(for: searchBar.text ?? "")
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    results.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    guard
      let cell = tableView.dequeueReusableCell(
        withIdentifier: ChatNativeNewChatUserCell.reuseIdentifier,
        for: indexPath
      ) as? ChatNativeNewChatUserCell
    else {
      return UITableViewCell()
    }

    cell.configure(user: results[indexPath.row], theme: theme)
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    guard indexPath.row >= 0, indexPath.row < results.count else { return }
    let user = results[indexPath.row]
    tableView.deselectRow(at: indexPath, animated: true)
    finish([
      "action": "select",
      "user": user.payload,
    ])
  }
}

private func chatNativeNewChatString(_ value: Any?) -> String? {
  if let string = value as? String {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
  if let number = value as? NSNumber {
    return number.stringValue
  }
  return nil
}

private func chatNativeNewChatColor(_ value: Any?) -> UIColor? {
  guard let raw = chatNativeNewChatString(value) else { return nil }
  if let hexColor = chatNativeNewChatHexColor(raw) {
    return hexColor
  }
  if let rgbaColor = chatNativeNewChatRGBAColor(raw) {
    return rgbaColor
  }
  return nil
}

private func chatNativeNewChatHexColor(_ value: String) -> UIColor? {
  var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
  if text.hasPrefix("#") {
    text.removeFirst()
  }
  if text.count == 3 {
    text = text.map { "\($0)\($0)" }.joined()
  }
  guard text.count == 6 || text.count == 8 else { return nil }

  var number: UInt64 = 0
  guard Scanner(string: text).scanHexInt64(&number) else { return nil }

  if text.count == 8 {
    let a = CGFloat((number & 0xFF00_0000) >> 24) / 255.0
    let r = CGFloat((number & 0x00FF_0000) >> 16) / 255.0
    let g = CGFloat((number & 0x0000_FF00) >> 8) / 255.0
    let b = CGFloat(number & 0x0000_00FF) / 255.0
    return UIColor(red: r, green: g, blue: b, alpha: a)
  }

  let r = CGFloat((number & 0xFF00_00) >> 16) / 255.0
  let g = CGFloat((number & 0x00FF_00) >> 8) / 255.0
  let b = CGFloat(number & 0x0000_FF) / 255.0
  return UIColor(red: r, green: g, blue: b, alpha: 1.0)
}

private func chatNativeNewChatRGBAColor(_ value: String) -> UIColor? {
  let cleaned = value
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .lowercased()
  guard cleaned.hasPrefix("rgba(") || cleaned.hasPrefix("rgb(") else { return nil }

  let openIndex = cleaned.firstIndex(of: "(")
  let closeIndex = cleaned.lastIndex(of: ")")
  guard let openIndex, let closeIndex, openIndex < closeIndex else { return nil }
  let componentsText = cleaned[cleaned.index(after: openIndex)..<closeIndex]
  let parts = componentsText
    .split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
  guard parts.count == 3 || parts.count == 4 else { return nil }
  guard
    let red = Double(parts[0]),
    let green = Double(parts[1]),
    let blue = Double(parts[2])
  else { return nil }

  let alpha: Double
  if parts.count == 4 {
    alpha = Double(parts[3]) ?? 1.0
  } else {
    alpha = 1.0
  }

  return UIColor(
    red: CGFloat(max(0, min(255, red)) / 255.0),
    green: CGFloat(max(0, min(255, green)) / 255.0),
    blue: CGFloat(max(0, min(255, blue)) / 255.0),
    alpha: CGFloat(max(0, min(1, alpha)))
  )
}

private func chatNativeNewChatLooksLikeUUID(_ value: String) -> Bool {
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  guard trimmed.count == 36 else { return false }
  let pattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
  return trimmed.range(of: pattern, options: .regularExpression) != nil
}
