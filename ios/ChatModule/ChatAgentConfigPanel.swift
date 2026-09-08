import UIKit
import SwiftUI
import PhotosUI

// Agent configuration and profile surfaces, plus the shared presentation
// primitives consumed by the Agents list page.

// MARK: - Shared agent configuration contracts

private func chatNativeAgentBuilderThemeColor(_ hex: String) -> UIColor {
  let sanitized =
    hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
      of: "#", with: "")
  guard sanitized.count == 6, let value = Int(sanitized, radix: 16) else {
    return .systemBackground
  }

  return UIColor(
    red: CGFloat((value >> 16) & 0xff) / 255.0,
    green: CGFloat((value >> 8) & 0xff) / 255.0,
    blue: CGFloat(value & 0xff) / 255.0,
    alpha: 1.0
  )
}

private func chatNativeAgentNormalizedString(_ value: Any?) -> String? {
  if let string = value as? String {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
  if let number = value as? NSNumber {
    return number.stringValue
  }
  return nil
}


private func chatNativeAgentPromptPreview(_ prompt: String?) -> String? {
  guard let prompt else { return nil }
  let condensed =
    prompt
    .replacingOccurrences(of: "\n", with: " ")
    .replacingOccurrences(of: "\r", with: " ")
    .split(whereSeparator: \.isWhitespace)
    .joined(separator: " ")
    .trimmingCharacters(in: .whitespacesAndNewlines)

  guard !condensed.isEmpty else { return nil }
  if condensed.count <= 72 {
    return condensed
  }

  let cutoffIndex = condensed.index(condensed.startIndex, offsetBy: 72)
  return String(condensed[..<cutoffIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
}

private func chatNativeAgentInitials(_ value: String) -> String {
  let words =
    value
    .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
    .map(String.init)
  let initials = words.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }.joined()
  if !initials.isEmpty {
    return initials
  }
  return String(value.prefix(1)).uppercased()
}

/// A realistic-looking (not a row of bullet dots) placeholder token, so the
/// blur laid over it in `ChatNativeAgentSecretCardView` reads as "real text,
/// hidden" rather than "blurred punctuation". Deterministic per hint so it
/// doesn't visually jitter across re-renders of the same agent.
private func chatNativeAgentMaskedSecret(_ hint: String?) -> String {
  let suffix =
    hint?
    .trimmingCharacters(in: .whitespacesAndNewlines)
    .replacingOccurrences(of: " ", with: "")
    ?? ""
  let normalizedSuffix =
    suffix.isEmpty
    ? ""
    : (suffix.hasPrefix("-") ? suffix : "-\(suffix)")
  let alphabet = Array("abcdef0123456789")
  var seed: UInt64 = 1469598103934665603
  for scalar in (suffix.isEmpty ? "vibeagent" : suffix).unicodeScalars {
    seed = (seed ^ UInt64(scalar.value)) &* 1099511628211
  }
  var filler = ""
  for _ in 0..<24 {
    seed = seed &* 6364136223846793005 &+ 1
    filler.append(alphabet[Int(seed >> 33) % alphabet.count])
  }
  return "vas_\(filler)\(normalizedSuffix)"
}

private func chatNativeAgentNormalizeEventInboxMode(_ value: String?) -> String {
  switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
  case "batched_summary", "batched", "batch", "summary":
    return "batched_summary"
  default:
    return "per_event"
  }
}

private func chatNativeAgentNormalizeSummaryWindowHours(_ value: Int?) -> Int {
  switch value ?? 24 {
  case ...4:
    return 4
  default:
    return 24
  }
}



private func chatNativeAgentInteger(_ value: Any?) -> Int? {
  if let number = value as? NSNumber {
    return number.intValue
  }
  if let number = value as? Int {
    return number
  }
  if let number = value as? Double, number.isFinite {
    return Int(number)
  }
  if let string = value as? String {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch trimmed {
    case "4h":
      return 4
    case "daily", "24h":
      return 24
    default:
      return Int(trimmed)
    }
  }
  return nil
}

private func chatNativeAgentBoolean(_ value: Any?) -> Bool? {
  if let value = value as? Bool {
    return value
  }
  if let value = value as? NSNumber {
    return value.boolValue
  }
  if let value = value as? String {
    switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on":
      return true
    case "0", "false", "no", "off":
      return false
    default:
      return nil
    }
  }
  return nil
}

struct ChatNativeAgentConfigAPIContext {
  let apiBaseURL: URL
  let token: String
}

/// Instant, cached list of the user's own agents — mirrors `ChatHomeRowsCache`'s
/// pattern (Sources/Home/ChatHomeService.swift) so the Agents tab shows what it
/// showed last time immediately on every open, with no spinner/skeleton, then
/// refreshes silently underneath instead of reloading from a blank screen.
enum ChatNativeAgentListCache {
  private static let keyPrefix = "vibe.ios.agentsList.cards.v1"

  static func cards(userID: String) -> [ChatListRow.AgentCard] {
    guard let data = UserDefaults.standard.data(forKey: cacheKey(userID: userID)),
      let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    else { return [] }
    return array.compactMap(ChatListRow.AgentCard.parse)
  }

  static func store(_ cards: [ChatListRow.AgentCard], userID: String) {
    // The list endpoint never sends a plaintext secret, but defend anyway: this
    // cache is a plain UserDefaults plist, not Keychain, so nothing that could
    // ever be a live invoke secret should end up sitting on disk here.
    let payload = cards.map { card -> [String: Any] in
      var raw = card.rawValue
      raw.removeValue(forKey: "latest_secret")
      return raw
    }
    guard JSONSerialization.isValidJSONObject(payload),
      let data = try? JSONSerialization.data(withJSONObject: payload, options: [])
    else { return }
    UserDefaults.standard.set(data, forKey: cacheKey(userID: userID))
  }

  private static func cacheKey(userID: String) -> String {
    let safe =
      userID
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .unicodeScalars
      .map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
      }
    let suffix = String(safe).isEmpty ? "default" : String(safe)
    return "\(keyPrefix).\(suffix)"
  }
}

/// Process-wide cache for the tool catalog (see `loadToolRegistry`).
private enum ChatAgentToolRegistryCache {
  static var tools: [ChatAgentToolInfo]?
  static var pending: [([ChatAgentToolInfo]) -> Void] = []

  static func resolvePending(with tools: [ChatAgentToolInfo]) {
    let waiting = pending
    pending = []
    waiting.forEach { $0(tools) }
  }
}

/// Ids of the current user's own agents, refreshed whenever the Agents tab
/// list loads. Lets a chat conversation cheaply ask "is the person I'm
/// talking to an agent I own?" without threading ownership through the whole
/// shared `ChatRoute`/profile pipeline used by every chat type in the app.
enum ChatOwnedAgentIdsCache {
  static var agentIds: Set<String> = []
}

/// Warms `ChatOwnedAgentIdsCache` from Home's own `onAppear`, so the header→config
/// route works even for a chat opened without ever visiting the Agents tab first
/// (a search result, a deep link, …). Cheap id-only fetch, fire-and-forget.
func chatNativeWarmOwnedAgentIds(config: AppSessionConfig) {
  var base = config.apiBaseURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
  while base.hasSuffix("/") { base.removeLast() }
  let suffix = base.lowercased().hasSuffix("/api") ? "/agents" : "/api/agents"
  guard let url = URL(string: base + suffix) else { return }

  var request = URLRequest(url: url)
  request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
  request.setValue("application/json", forHTTPHeaderField: "Accept")

  ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) { data, response, error in
    guard
      error == nil,
      (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
      let data,
      let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let items = payload["items"] as? [[String: Any]]
    else { return }
    let ids = items.compactMap { chatNativeAgentNormalizedString($0["id"]) }
    DispatchQueue.main.async {
      ChatOwnedAgentIdsCache.agentIds = Set(ids)
    }
  }.resume()
}

/// Shared normalization from a raw `/api/agents` (or `/api/agents/:id`) JSON
/// payload into the client-side `ChatListRow.AgentCard` model. The Agents list
/// page and config routes use the same parsing so cards stay consistent.
func chatNativeAgentParseControlCard(
  raw: [String: Any], apiContext: ChatNativeAgentConfigAPIContext
) -> ChatListRow.AgentCard? {
  guard let agentId = chatNativeAgentNormalizedString(raw["id"]) else { return nil }
  let username = chatNativeAgentNormalizedString(raw["username"])
  var normalized = raw
  normalized["card_id"] = "agent-card:\(agentId):control"
  normalized["agent_id"] = agentId
  normalized["agent_user_id"] = raw["userId"] ?? raw["user_id"]
  normalized["display_name"] = raw["displayName"] ?? raw["display_name"] ?? "Agent"
  normalized["identifier"] = username ?? agentId
  normalized["prompt_status"] =
    chatNativeAgentNormalizedString(raw["systemPrompt"] ?? raw["system_prompt"]) == nil
    ? "Prompt missing"
    : "Prompt ready"
  normalized["prompt_preview"] = raw["systemPrompt"] ?? raw["system_prompt"]
  normalized["system_prompt"] = raw["systemPrompt"] ?? raw["system_prompt"]
  normalized["enabled_tools"] = raw["enabledTools"] ?? raw["enabled_tools"] ?? []
  normalized["output_modes"] = raw["outputModes"] ?? raw["output_modes"] ?? []
  normalized["voice_profile"] = raw["voiceProfile"] ?? raw["voice_profile"]
  normalized["callback_url"] = raw["callbackUrl"] ?? raw["callback_url"]
  normalized["secret_hint"] = raw["secretHint"] ?? raw["secret_hint"]
  normalized["attached_chats"] = raw["attachedChats"] ?? raw["attached_chats"] ?? []
  normalized["approval_rules"] = raw["approvalRules"] ?? raw["approval_rules"] ?? [:]

  var base = apiContext.apiBaseURL.absoluteString
    .trimmingCharacters(in: .whitespacesAndNewlines)
  while base.hasSuffix("/") { base.removeLast() }
  let apiBase = base.lowercased().hasSuffix("/api")
    ? String(base.dropLast(4))
    : base
  normalized["api_base_url"] = apiBase
  normalized["invoke_url"] = "\(apiBase)/api/agents/\(agentId)/invoke"
  normalized["events_url"] = "\(apiBase)/api/agents/\(agentId)/events"
  if let userId = chatNativeAgentNormalizedString(raw["userId"] ?? raw["user_id"]) {
    normalized["agent_dm_link"] = "vibe://chat?friendId=\(userId)"
  }

  if
    let defaultChatId = chatNativeAgentNormalizedString(
      raw["defaultDestinationChatId"] ?? raw["default_destination_chat_id"])
  {
    let chats =
      ((raw["attachedChats"] as? [[String: Any]])
        ?? (raw["attached_chats"] as? [[String: Any]])
        ?? [])
    normalized["default_destination_chat"] =
      chats.first(where: {
        chatNativeAgentNormalizedString($0["chatId"] ?? $0["chat_id"]) == defaultChatId
      })
      ?? ["chat_id": defaultChatId]
  }

  return ChatListRow.AgentCard.parse(normalized)
}

/// Fetches one agent by id and pushes its config screen — used when a chat's
/// header is tapped and the peer turns out to be an agent the user owns.
func chatNativeAgentPushConfig(
  agentId: String,
  apiContext: ChatNativeAgentConfigAPIContext,
  appearance: ChatListAppearance,
  from navigationController: UINavigationController,
  onToast: ((String) -> Void)?
) {
  func push(_ card: ChatListRow.AgentCard) {
    let controller = ChatNativeAgentConfigPanelController(
      card: card, appearance: appearance, apiContext: apiContext
    )
    controller.onToast = onToast
    controller.onOpenAgentChat = { [weak navigationController] _ in
      navigationController?.popViewController(animated: true)
    }
    navigationController.pushViewController(controller, animated: true)
  }

  // Header taps must feel like navigation, not a network operation. The Agents
  // page has already cached the canonical card, including identifiers and attached
  // chats, so use it immediately and let each settings action perform its own API call.
  if let userID = AppSessionConfig.current?.userID,
    let cached = ChatNativeAgentListCache.cards(userID: userID).first(where: {
      $0.agentId == agentId
    })
  {
    push(cached)
    return
  }

  var base = apiContext.apiBaseURL.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
  while base.hasSuffix("/") { base.removeLast() }
  let suffix = base.lowercased().hasSuffix("/api") ? "" : "/api"
  let encodedId = agentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? agentId
  guard let url = URL(string: "\(base)\(suffix)/agents/\(encodedId)") else { return }

  var request = URLRequest(url: url)
  request.setValue("Bearer \(apiContext.token)", forHTTPHeaderField: "Authorization")
  request.setValue("application/json", forHTTPHeaderField: "Accept")

  ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) { data, response, error in
    DispatchQueue.main.async {
      guard
        error == nil,
        (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
        let data,
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let card = chatNativeAgentParseControlCard(raw: payload, apiContext: apiContext)
      else {
        onToast?("Could not open agent settings")
        return
      }
      push(card)
    }
  }.resume()
}

// Internal (not file-private) so `ChatNativeAgentSecretCardRepresentable` can build one
// from plain SwiftUI state (`colorScheme`) when bridging `ChatNativeAgentSecretCardView`
// into the settings Form.
struct ChatNativeAgentConfigTheme {
  let panelTheme: ChatBuilderPanelTheme
  let isDark: Bool
  let destructiveColor: UIColor
  let primaryButtonColor: UIColor
  let secondaryButtonColor: UIColor

  init(appearance: ChatListAppearance) {
    self.init(isDark: appearance.isDark)
  }

  init(isDark: Bool) {
    self.isDark = isDark
    // Derived from the app's real global theme palette (not a one-off hardcoded
    // hex set) so the Agents tab and config screens are pixel-identical to the
    // Home background, card, and accent colors — a mismatched "near-black
    // console" palette here was the root cause of a visible seam against Home.
    let palette = AppThemePalette.resolve(for: isDark ? .dark : .light)
    panelTheme = ChatBuilderPanelTheme(
      isDark: isDark,
      backgroundColor: palette.backgroundUIColor,
      cardColor: palette.cardUIColor,
      inputColor: palette.inputUIColor,
      textColor: palette.textUIColor,
      secondaryTextColor: palette.secondaryTextUIColor,
      accentColor: palette.accentUIColor
    )
    destructiveColor = palette.dangerUIColor
    primaryButtonColor = palette.accentUIColor
    secondaryButtonColor = palette.inputUIColor
  }

  var backgroundColor: UIColor { panelTheme.backgroundColor }
  var cardColor: UIColor { panelTheme.cardColor }
  var inputColor: UIColor { panelTheme.inputColor }
  var textColor: UIColor { panelTheme.textColor }
  var secondaryTextColor: UIColor { panelTheme.secondaryTextColor }
  var accentColor: UIColor { panelTheme.accentColor }

  /// Hairline separator that sits inside cards.
  var separatorColor: UIColor {
    textColor.withAlphaComponent(isDark ? 0.08 : 0.10)
  }

  /// Tinted background for the rounded icon chip on each row.
  var iconChipColor: UIColor {
    accentColor.withAlphaComponent(isDark ? 0.18 : 0.12)
  }

  /// Subtle stroke to lift cards off the near-black canvas.
  var cardStrokeColor: UIColor {
    isDark ? UIColor.white.withAlphaComponent(0.06) : UIColor.black.withAlphaComponent(0.04)
  }

  var positiveColor: UIColor {
    AppThemePalette.resolve(for: isDark ? .dark : .light).successUIColor
  }

  var warningColor: UIColor {
    AppThemePalette.resolve(for: isDark ? .dark : .light).warningUIColor
  }
}

/// Visual treatment for an agent's lifecycle status, used across the hero,
/// list cells and status pills so colour stays consistent.
private struct ChatNativeAgentStatusStyle {
  let title: String
  let color: UIColor
  let symbol: String

  init(status: String, theme: ChatNativeAgentConfigTheme) {
    switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "published", "live", "active":
      title = "Published"
      color = theme.positiveColor
      symbol = "checkmark.seal.fill"
    case "archived":
      title = "Archived"
      color = theme.secondaryTextColor
      symbol = "archivebox.fill"
    default:
      title = "Draft"
      color = theme.warningColor
      symbol = "pencil.circle.fill"
    }
  }
}

func chatNativeAgentIsPublished(_ status: String) -> Bool {
  status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "published"
}

/// A rounded card that groups rows. Optional small-caps header above and a
/// quiet footnote caption below, mirroring iOS settings hierarchy but with a
/// softer, elevated card and an internal divider that's inset past the icon.
private final class ChatNativeAgentConfigSectionView: UIView {
  let contentStack = UIStackView()
  private let cardView = UIView()

  init(title: String?, theme: ChatNativeAgentConfigTheme, footnote: String? = nil) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    cardView.translatesAutoresizingMaskIntoConstraints = false
    cardView.backgroundColor = theme.cardColor
    cardView.layer.cornerRadius = 18.0
    cardView.layer.cornerCurve = .continuous
    cardView.layer.borderWidth = 1.0 / UIScreen.main.scale
    cardView.layer.borderColor = theme.cardStrokeColor.cgColor
    cardView.clipsToBounds = true
    addSubview(cardView)

    contentStack.translatesAutoresizingMaskIntoConstraints = false
    contentStack.axis = .vertical
    contentStack.spacing = 0.0
    cardView.addSubview(contentStack)

    var constraints = [
      cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
      cardView.trailingAnchor.constraint(equalTo: trailingAnchor),
      contentStack.topAnchor.constraint(equalTo: cardView.topAnchor),
      contentStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
      contentStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
      contentStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
    ]

    if let title, !title.isEmpty {
      let titleLabel = UILabel()
      titleLabel.translatesAutoresizingMaskIntoConstraints = false
      titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
      titleLabel.text = title.uppercased()
      titleLabel.textColor = theme.secondaryTextColor
      // Slight letter-spacing reads as deliberate, premium typography.
      let attributed = NSAttributedString(
        string: title.uppercased(),
        attributes: [.kern: 0.6]
      )
      titleLabel.attributedText = attributed
      addSubview(titleLabel)

      constraints.append(contentsOf: [
        titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20.0),
        titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20.0),
        titleLabel.topAnchor.constraint(equalTo: topAnchor),
        cardView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10.0),
      ])
    } else {
      constraints.append(cardView.topAnchor.constraint(equalTo: topAnchor))
    }

    if let footnote, !footnote.isEmpty {
      let footnoteLabel = UILabel()
      footnoteLabel.translatesAutoresizingMaskIntoConstraints = false
      footnoteLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
      footnoteLabel.numberOfLines = 0
      footnoteLabel.text = footnote
      footnoteLabel.textColor = theme.secondaryTextColor
      addSubview(footnoteLabel)
      constraints.append(contentsOf: [
        footnoteLabel.topAnchor.constraint(equalTo: cardView.bottomAnchor, constant: 8.0),
        footnoteLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20.0),
        footnoteLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20.0),
        footnoteLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    } else {
      constraints.append(cardView.bottomAnchor.constraint(equalTo: bottomAnchor))
    }

    NSLayoutConstraint.activate(constraints)
  }

  required init?(coder: NSCoder) {
    return nil
  }
}

/// Trailing accessory affordance for a row. The chevron is the only "drill in"
/// glyph; copy gets its own glyph; control rows manage their own accessory.
private enum ChatNativeAgentRowAccessory {
  case none
  case chevron
  case copy
}

/// A clean settings-style row: a tinted rounded icon chip, a leading title,
/// a trailing value that truncates in the middle (great for URLs), and an
/// optional accessory. This replaces the old stacked title/value layout that
/// wrapped awkwardly to two lines on the left.
private final class ChatNativeAgentConfigRow: UIControl {
  private let highlightView = UIView()
  private let iconChip = UIView()
  private let iconView = UIImageView()
  private let titleLabel = UILabel()
  private let valueLabel = UILabel()
  private let accessoryView = UIImageView()
  private let dividerView = UIView()

  var onTap: (() -> Void)?

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: 0.14) {
        self.highlightView.alpha = self.isHighlighted ? 1.0 : 0.0
      }
    }
  }

  init(
    title: String,
    value: String?,
    theme: ChatNativeAgentConfigTheme,
    symbolName: String? = nil,
    accessory: ChatNativeAgentRowAccessory = .chevron,
    showsDivider: Bool = true,
    destructive: Bool = false,
    valueColor: UIColor? = nil
  ) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear

    highlightView.translatesAutoresizingMaskIntoConstraints = false
    highlightView.backgroundColor = theme.textColor.withAlphaComponent(0.06)
    highlightView.alpha = 0.0
    addSubview(highlightView)

    iconChip.translatesAutoresizingMaskIntoConstraints = false
    iconChip.backgroundColor = destructive
      ? theme.destructiveColor.withAlphaComponent(theme.isDark ? 0.18 : 0.12)
      : theme.iconChipColor
    iconChip.layer.cornerRadius = 8.0
    iconChip.layer.cornerCurve = .continuous
    iconChip.isHidden = symbolName == nil
    addSubview(iconChip)

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.contentMode = .center
    iconView.image =
      symbolName.flatMap {
        UIImage(
          systemName: $0,
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .semibold)
        )
      }
    iconView.tintColor = destructive ? theme.destructiveColor : theme.accentColor
    iconChip.addSubview(iconView)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.font = .systemFont(ofSize: 16.0, weight: .regular)
    titleLabel.textColor = destructive ? theme.destructiveColor : theme.textColor
    titleLabel.numberOfLines = 1
    titleLabel.text = title
    titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    titleLabel.setContentHuggingPriority(.required, for: .horizontal)
    addSubview(titleLabel)

    valueLabel.translatesAutoresizingMaskIntoConstraints = false
    valueLabel.font = .systemFont(ofSize: 15.0, weight: .regular)
    valueLabel.textColor =
      valueColor
      ?? (destructive ? theme.destructiveColor.withAlphaComponent(0.85) : theme.secondaryTextColor)
    valueLabel.numberOfLines = 1
    valueLabel.textAlignment = .right
    valueLabel.lineBreakMode = .byTruncatingMiddle
    valueLabel.text = value
    valueLabel.isHidden = (value ?? "").isEmpty
    valueLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    addSubview(valueLabel)

    accessoryView.translatesAutoresizingMaskIntoConstraints = false
    switch accessory {
    case .none:
      accessoryView.image = nil
      accessoryView.isHidden = true
    case .chevron:
      accessoryView.image = UIImage(
        systemName: "chevron.right",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.0, weight: .semibold)
      )
      accessoryView.tintColor =
        (destructive ? theme.destructiveColor : theme.secondaryTextColor).withAlphaComponent(0.5)
    case .copy:
      accessoryView.image = UIImage(
        systemName: "square.on.square",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 14.0, weight: .regular)
      )
      accessoryView.tintColor = theme.accentColor.withAlphaComponent(0.85)
    }
    accessoryView.contentMode = .center
    addSubview(accessoryView)

    dividerView.translatesAutoresizingMaskIntoConstraints = false
    dividerView.backgroundColor = theme.separatorColor
    dividerView.isHidden = !showsDivider
    addSubview(dividerView)

    let hasAccessory = accessory != .none
    let leadingTitleAnchor = symbolName != nil ? iconChip.trailingAnchor : leadingAnchor
    let leadingTitleConstant: CGFloat = symbolName != nil ? 14.0 : 18.0

    NSLayoutConstraint.activate([
      heightAnchor.constraint(greaterThanOrEqualToConstant: 56.0),

      highlightView.topAnchor.constraint(equalTo: topAnchor),
      highlightView.leadingAnchor.constraint(equalTo: leadingAnchor),
      highlightView.trailingAnchor.constraint(equalTo: trailingAnchor),
      highlightView.bottomAnchor.constraint(equalTo: bottomAnchor),

      iconChip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16.0),
      iconChip.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconChip.widthAnchor.constraint(equalToConstant: 30.0),
      iconChip.heightAnchor.constraint(equalToConstant: 30.0),
      iconView.centerXAnchor.constraint(equalTo: iconChip.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: iconChip.centerYAnchor),

      titleLabel.leadingAnchor.constraint(equalTo: leadingTitleAnchor, constant: leadingTitleConstant),
      titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12.0),
      valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

      accessoryView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16.0),
      accessoryView.centerYAnchor.constraint(equalTo: centerYAnchor),
      accessoryView.widthAnchor.constraint(equalToConstant: 18.0),

      dividerView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      dividerView.trailingAnchor.constraint(equalTo: trailingAnchor),
      dividerView.bottomAnchor.constraint(equalTo: bottomAnchor),
      dividerView.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale),
    ])

    if hasAccessory {
      valueLabel.trailingAnchor.constraint(equalTo: accessoryView.leadingAnchor, constant: -8.0).isActive = true
    } else {
      valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18.0).isActive = true
    }

    addTarget(self, action: #selector(handleTap), for: .touchUpInside)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func hideDivider() {
    dividerView.isHidden = true
  }

  @objc private func handleTap() {
    onTap?()
  }
}

/// Premium identity header: gradient avatar, name, tappable handle, a status
/// pill, and a single prominent lifecycle button that publishes a draft or
/// reverts a published agent back to draft.
private final class ChatNativeAgentHeroHeaderView: UIView {
  private let avatarContainer = UIView()
  private let avatarGradient = CAGradientLayer()
  private let avatarRing = UIView()
  private let badgeLabel = UILabel()
  private let nameLabel = UILabel()
  private let handleButton = UIButton(type: .system)
  private let statusPill = UIView()
  private let statusIcon = UIImageView()
  private let statusLabel = UILabel()
  private let lifecycleButton = UIButton(type: .system)
  private var lifecycleActivity = UIActivityIndicatorView(style: .medium)

  private var theme: ChatNativeAgentConfigTheme?
  private var currentStatus: String = "draft"

  var onCopyHandle: (() -> Void)?
  var onToggleLifecycle: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear

    avatarContainer.translatesAutoresizingMaskIntoConstraints = false
    avatarContainer.layer.cornerRadius = 44.0
    avatarContainer.layer.cornerCurve = .continuous
    avatarContainer.layer.shadowColor = UIColor.black.cgColor
    avatarContainer.layer.shadowOpacity = 0.22
    avatarContainer.layer.shadowOffset = CGSize(width: 0, height: 10)
    avatarContainer.layer.shadowRadius = 22.0
    addSubview(avatarContainer)

    avatarGradient.cornerRadius = 44.0
    avatarGradient.cornerCurve = .continuous
    avatarContainer.layer.addSublayer(avatarGradient)

    avatarRing.translatesAutoresizingMaskIntoConstraints = false
    avatarRing.isUserInteractionEnabled = false
    avatarRing.layer.cornerRadius = 50.0
    avatarRing.layer.cornerCurve = .continuous
    avatarRing.layer.borderWidth = 1.0
    insertSubview(avatarRing, belowSubview: avatarContainer)

    badgeLabel.translatesAutoresizingMaskIntoConstraints = false
    badgeLabel.font = .systemFont(ofSize: 34.0, weight: .bold)
    badgeLabel.textAlignment = .center
    badgeLabel.textColor = .white
    avatarContainer.addSubview(badgeLabel)

    nameLabel.translatesAutoresizingMaskIntoConstraints = false
    nameLabel.font = .systemFont(ofSize: 28.0, weight: .bold)
    nameLabel.textAlignment = .center
    nameLabel.numberOfLines = 2
    addSubview(nameLabel)

    handleButton.translatesAutoresizingMaskIntoConstraints = false
    handleButton.titleLabel?.font = .systemFont(ofSize: 16.0, weight: .semibold)
    handleButton.contentEdgeInsets = UIEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
    handleButton.addTarget(self, action: #selector(handleHandleTap), for: .touchUpInside)
    addSubview(handleButton)

    statusPill.translatesAutoresizingMaskIntoConstraints = false
    statusPill.layer.cornerRadius = 13.0
    statusPill.layer.cornerCurve = .continuous
    addSubview(statusPill)

    statusIcon.translatesAutoresizingMaskIntoConstraints = false
    statusIcon.contentMode = .scaleAspectFit
    statusPill.addSubview(statusIcon)

    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
    statusPill.addSubview(statusLabel)

    lifecycleButton.translatesAutoresizingMaskIntoConstraints = false
    lifecycleButton.titleLabel?.font = .systemFont(ofSize: 16.0, weight: .semibold)
    lifecycleButton.layer.cornerRadius = 14.0
    lifecycleButton.layer.cornerCurve = .continuous
    lifecycleButton.contentEdgeInsets = UIEdgeInsets(top: 13, left: 22, bottom: 13, right: 22)
    lifecycleButton.addTarget(self, action: #selector(handleLifecycleTap), for: .touchUpInside)
    addSubview(lifecycleButton)

    lifecycleActivity.translatesAutoresizingMaskIntoConstraints = false
    lifecycleActivity.hidesWhenStopped = true
    lifecycleButton.addSubview(lifecycleActivity)

    NSLayoutConstraint.activate([
      avatarContainer.topAnchor.constraint(equalTo: topAnchor, constant: 6.0),
      avatarContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
      avatarContainer.widthAnchor.constraint(equalToConstant: 88.0),
      avatarContainer.heightAnchor.constraint(equalToConstant: 88.0),

      avatarRing.centerXAnchor.constraint(equalTo: avatarContainer.centerXAnchor),
      avatarRing.centerYAnchor.constraint(equalTo: avatarContainer.centerYAnchor),
      avatarRing.widthAnchor.constraint(equalToConstant: 100.0),
      avatarRing.heightAnchor.constraint(equalToConstant: 100.0),

      badgeLabel.centerXAnchor.constraint(equalTo: avatarContainer.centerXAnchor),
      badgeLabel.centerYAnchor.constraint(equalTo: avatarContainer.centerYAnchor),

      nameLabel.topAnchor.constraint(equalTo: avatarContainer.bottomAnchor, constant: 18.0),
      nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16.0),
      nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16.0),

      handleButton.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2.0),
      handleButton.centerXAnchor.constraint(equalTo: centerXAnchor),

      statusPill.topAnchor.constraint(equalTo: handleButton.bottomAnchor, constant: 12.0),
      statusPill.centerXAnchor.constraint(equalTo: centerXAnchor),
      statusPill.heightAnchor.constraint(equalToConstant: 26.0),

      statusIcon.leadingAnchor.constraint(equalTo: statusPill.leadingAnchor, constant: 11.0),
      statusIcon.centerYAnchor.constraint(equalTo: statusPill.centerYAnchor),
      statusIcon.widthAnchor.constraint(equalToConstant: 12.0),
      statusIcon.heightAnchor.constraint(equalToConstant: 12.0),

      statusLabel.leadingAnchor.constraint(equalTo: statusIcon.trailingAnchor, constant: 5.0),
      statusLabel.trailingAnchor.constraint(equalTo: statusPill.trailingAnchor, constant: -12.0),
      statusLabel.centerYAnchor.constraint(equalTo: statusPill.centerYAnchor),

      lifecycleButton.topAnchor.constraint(equalTo: statusPill.bottomAnchor, constant: 18.0),
      lifecycleButton.centerXAnchor.constraint(equalTo: centerXAnchor),
      lifecycleButton.bottomAnchor.constraint(equalTo: bottomAnchor),
      lifecycleButton.heightAnchor.constraint(equalToConstant: 48.0),

      lifecycleActivity.centerXAnchor.constraint(equalTo: lifecycleButton.centerXAnchor),
      lifecycleActivity.centerYAnchor.constraint(equalTo: lifecycleButton.centerYAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    avatarGradient.frame = avatarContainer.bounds
  }

  func applyTheme(_ theme: ChatNativeAgentConfigTheme) {
    self.theme = theme
    avatarGradient.colors = [
      theme.accentColor.cgColor,
      theme.accentColor.withAlphaComponent(0.55).cgColor,
    ]
    avatarGradient.startPoint = CGPoint(x: 0, y: 0)
    avatarGradient.endPoint = CGPoint(x: 1, y: 1)
    avatarRing.layer.borderColor = theme.accentColor.withAlphaComponent(0.22).cgColor

    nameLabel.textColor = theme.textColor
    handleButton.tintColor = theme.accentColor
  }

  func configure(card: ChatListRow.AgentCard) {
    guard let theme else { return }
    badgeLabel.text = chatNativeAgentInitials(card.displayName)
    nameLabel.text = card.displayName

    let handle = card.username.flatMap { "@\($0)" } ?? card.identifier
    handleButton.setTitle(handle, for: .normal)

    currentStatus = card.status
    let style = ChatNativeAgentStatusStyle(status: card.status, theme: theme)
    statusPill.backgroundColor = style.color.withAlphaComponent(theme.isDark ? 0.16 : 0.12)
    statusIcon.image = UIImage(
      systemName: style.symbol,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 11.0, weight: .semibold)
    )
    statusIcon.tintColor = style.color
    statusLabel.text = style.title
    statusLabel.textColor = style.color

    applyLifecycleAppearance(loading: false)
  }

  func setLifecycleLoading(_ loading: Bool) {
    applyLifecycleAppearance(loading: loading)
  }

  private func applyLifecycleAppearance(loading: Bool) {
    guard let theme else { return }
    let published = chatNativeAgentIsPublished(currentStatus)
    lifecycleButton.isEnabled = !loading

    if loading {
      lifecycleButton.setTitle("", for: .normal)
      lifecycleActivity.color = published ? theme.secondaryTextColor : .white
      lifecycleActivity.startAnimating()
    } else {
      lifecycleActivity.stopAnimating()
      if published {
        // Already live — offer a quiet "revert to draft" affordance.
        lifecycleButton.setTitle("Revert to Draft", for: .normal)
        lifecycleButton.setTitleColor(theme.textColor, for: .normal)
        lifecycleButton.backgroundColor = theme.inputColor
        lifecycleButton.layer.borderWidth = 0
      } else {
        lifecycleButton.setTitle("Publish Agent", for: .normal)
        lifecycleButton.setTitleColor(.white, for: .normal)
        lifecycleButton.backgroundColor = theme.accentColor
        lifecycleButton.layer.borderWidth = 0
      }
    }
  }

  @objc private func handleHandleTap() {
    onCopyHandle?()
  }

  @objc private func handleLifecycleTap() {
    onToggleLifecycle?()
  }
}

/// A row of pill-shaped filter chips (All / Active / Disabled) — the rounded,
/// Telegram-folder-tab look, in place of a boxed `UISegmentedControl`.
final class ChatNativeAgentPillFilterView: UIView {
  private var buttons: [UIButton] = []
  private var theme: ChatNativeAgentConfigTheme
  private(set) var selectedIndex: Int = 0
  var onChange: ((Int) -> Void)?

  init(titles: [String], theme: ChatNativeAgentConfigTheme) {
    self.theme = theme
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    let stack = UIStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .horizontal
    stack.spacing = 8.0
    stack.alignment = .center
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    for (index, title) in titles.enumerated() {
      let button = UIButton(type: .system)
      button.translatesAutoresizingMaskIntoConstraints = false
      var configuration = UIButton.Configuration.filled()
      configuration.title = title
      configuration.cornerStyle = .capsule
      configuration.contentInsets = NSDirectionalEdgeInsets(
        top: 8.0, leading: 16.0, bottom: 8.0, trailing: 16.0
      )
      button.configuration = configuration
      button.tag = index
      button.titleLabel?.font = .systemFont(ofSize: 13.5, weight: .semibold)
      button.addTarget(self, action: #selector(handleTap(_:)), for: .touchUpInside)
      buttons.append(button)
      stack.addArrangedSubview(button)
    }
    updateAppearance()
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func applyTheme(_ theme: ChatNativeAgentConfigTheme) {
    self.theme = theme
    updateAppearance()
  }

  @objc private func handleTap(_ sender: UIButton) {
    guard sender.tag != selectedIndex else { return }
    selectedIndex = sender.tag
    updateAppearance()
    onChange?(selectedIndex)
  }

  private func updateAppearance() {
    for button in buttons {
      let selected = button.tag == selectedIndex
      var configuration = button.configuration
      configuration?.baseBackgroundColor = selected ? theme.accentColor : theme.inputColor
      configuration?.baseForegroundColor = selected ? .white : theme.secondaryTextColor
      button.configuration = configuration
    }
  }
}

private final class ChatNativeAgentActionButton: UIButton {
  init(title: String, fillColor: UIColor, foregroundColor: UIColor = .white) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    var configuration = UIButton.Configuration.filled()
    configuration.title = title
    configuration.baseBackgroundColor = fillColor
    configuration.baseForegroundColor = foregroundColor
    configuration.cornerStyle = .large
    configuration.contentInsets = NSDirectionalEdgeInsets(
      top: 12.0,
      leading: 18.0,
      bottom: 12.0,
      trailing: 18.0
    )
    self.configuration = configuration
    titleLabel?.font = .systemFont(ofSize: 15.0, weight: .semibold)
  }

  required init?(coder: NSCoder) {
    return nil
  }
}

/// Invoke-secret card. A realistic-looking token sits under an animated frosted
/// blur that lifts on reveal — Telegram-style, not a row of masked dots. Copy
/// and Rotate sit below as paired actions.
// Internal (not file-private) so `ChatNativeAgentSecretCardRepresentable` — the
// SwiftUI bridge that hosts this card inside the settings Form — can name it in a
// non-private signature (`makeUIView(context:) -> ChatNativeAgentSecretCardView`).
final class ChatNativeAgentSecretCardView: UIView {
  private let cardView = UIView()
  private let headerIcon = UIImageView()
  private let headerLabel = UILabel()
  private let tokenSurfaceView = UIView()
  private let tokenLabel = UILabel()
  /// Uses the same Metal particle renderer as Settings' secret-key cover. Keeping
  /// one renderer gives both secret surfaces the same Telegram-style spoiler motion.
  private let tokenCoverRenderer = MetalKeyMaskView.Coordinator()
  private lazy var tokenCoverView: SecureParticleMaskView = {
    let view = SecureParticleMaskView(frame: .zero, device: tokenCoverRenderer.device)
    view.delegate = tokenCoverRenderer
    view.layer.cornerRadius = 7.0
    return view
  }()
  private let tokenSpinner = UIActivityIndicatorView(style: .medium)
  private let revealButton = UIButton(type: .system)
  private let buttonsStack = UIStackView()
  private let copyButton = ChatNativeAgentActionButton(title: "Copy", fillColor: .systemBlue)
  private let rotateButton = ChatNativeAgentActionButton(title: "Rotate", fillColor: .systemGray)
  private let descriptionLabel = UILabel()

  private var theme: ChatNativeAgentConfigTheme?

  var onReveal: (() -> Void)?
  var onCopy: (() -> Void)?
  var onRotate: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = .clear

    cardView.translatesAutoresizingMaskIntoConstraints = false
    cardView.layer.cornerRadius = 18.0
    cardView.layer.cornerCurve = .continuous
    cardView.layer.borderWidth = 1.0 / UIScreen.main.scale
    addSubview(cardView)

    headerIcon.translatesAutoresizingMaskIntoConstraints = false
    headerIcon.image = UIImage(
      systemName: "key.horizontal.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 13.0, weight: .semibold)
    )
    cardView.addSubview(headerIcon)

    headerLabel.translatesAutoresizingMaskIntoConstraints = false
    headerLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
    headerLabel.attributedText = NSAttributedString(string: "INVOKE SECRET", attributes: [.kern: 0.6])
    cardView.addSubview(headerLabel)

    tokenSurfaceView.translatesAutoresizingMaskIntoConstraints = false
    tokenSurfaceView.layer.cornerRadius = 11.0
    tokenSurfaceView.layer.cornerCurve = .continuous
    tokenSurfaceView.clipsToBounds = true
    cardView.addSubview(tokenSurfaceView)

    tokenLabel.translatesAutoresizingMaskIntoConstraints = false
    tokenLabel.font = .monospacedSystemFont(ofSize: 14.0, weight: .regular)
    tokenLabel.textAlignment = .left
    tokenLabel.adjustsFontSizeToFitWidth = true
    tokenLabel.minimumScaleFactor = 0.6
    tokenLabel.lineBreakMode = .byTruncatingTail
    tokenLabel.numberOfLines = 1
    tokenSurfaceView.addSubview(tokenLabel)

    tokenCoverView.translatesAutoresizingMaskIntoConstraints = false
    tokenCoverView.isUserInteractionEnabled = false
    tokenSurfaceView.addSubview(tokenCoverView)

    tokenSpinner.translatesAutoresizingMaskIntoConstraints = false
    tokenSpinner.hidesWhenStopped = true
    tokenSurfaceView.addSubview(tokenSpinner)

    revealButton.translatesAutoresizingMaskIntoConstraints = false
    revealButton.addTarget(self, action: #selector(handleRevealPressed), for: .touchUpInside)
    tokenSurfaceView.addSubview(revealButton)

    buttonsStack.translatesAutoresizingMaskIntoConstraints = false
    buttonsStack.axis = .horizontal
    buttonsStack.spacing = 10.0
    buttonsStack.distribution = .fillEqually
    cardView.addSubview(buttonsStack)
    buttonsStack.addArrangedSubview(copyButton)
    buttonsStack.addArrangedSubview(rotateButton)

    descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
    descriptionLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
    descriptionLabel.numberOfLines = 0
    descriptionLabel.textAlignment = .left
    descriptionLabel.text =
      "Anyone with this secret can invoke your agent. Keep it private and rotate it if it leaks."
    cardView.addSubview(descriptionLabel)

    NSLayoutConstraint.activate([
      cardView.topAnchor.constraint(equalTo: topAnchor),
      cardView.leadingAnchor.constraint(equalTo: leadingAnchor),
      cardView.trailingAnchor.constraint(equalTo: trailingAnchor),
      cardView.bottomAnchor.constraint(equalTo: bottomAnchor),

      headerIcon.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 18.0),
      headerIcon.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18.0),
      headerIcon.widthAnchor.constraint(equalToConstant: 16.0),
      headerIcon.heightAnchor.constraint(equalToConstant: 16.0),

      headerLabel.centerYAnchor.constraint(equalTo: headerIcon.centerYAnchor),
      headerLabel.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: 7.0),
      headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: cardView.trailingAnchor, constant: -18.0),

      tokenSurfaceView.topAnchor.constraint(equalTo: headerIcon.bottomAnchor, constant: 12.0),
      tokenSurfaceView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18.0),
      tokenSurfaceView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18.0),
      tokenSurfaceView.heightAnchor.constraint(equalToConstant: 50.0),

      tokenLabel.leadingAnchor.constraint(equalTo: tokenSurfaceView.leadingAnchor, constant: 14.0),
      tokenLabel.trailingAnchor.constraint(equalTo: revealButton.leadingAnchor, constant: -8.0),
      tokenLabel.centerYAnchor.constraint(equalTo: tokenSurfaceView.centerYAnchor),

      tokenCoverView.leadingAnchor.constraint(equalTo: tokenLabel.leadingAnchor, constant: -4.0),
      tokenCoverView.trailingAnchor.constraint(equalTo: tokenLabel.trailingAnchor, constant: 4.0),
      tokenCoverView.topAnchor.constraint(equalTo: tokenSurfaceView.topAnchor, constant: 6.0),
      tokenCoverView.bottomAnchor.constraint(equalTo: tokenSurfaceView.bottomAnchor, constant: -6.0),

      tokenSpinner.centerYAnchor.constraint(equalTo: tokenSurfaceView.centerYAnchor),
      tokenSpinner.leadingAnchor.constraint(equalTo: tokenSurfaceView.leadingAnchor, constant: 14.0),

      revealButton.trailingAnchor.constraint(equalTo: tokenSurfaceView.trailingAnchor, constant: -8.0),
      revealButton.centerYAnchor.constraint(equalTo: tokenSurfaceView.centerYAnchor),
      revealButton.widthAnchor.constraint(equalToConstant: 40.0),
      revealButton.heightAnchor.constraint(equalToConstant: 40.0),

      buttonsStack.topAnchor.constraint(equalTo: tokenSurfaceView.bottomAnchor, constant: 12.0),
      buttonsStack.leadingAnchor.constraint(equalTo: tokenSurfaceView.leadingAnchor),
      buttonsStack.trailingAnchor.constraint(equalTo: tokenSurfaceView.trailingAnchor),
      buttonsStack.heightAnchor.constraint(equalToConstant: 46.0),

      descriptionLabel.topAnchor.constraint(equalTo: buttonsStack.bottomAnchor, constant: 14.0),
      descriptionLabel.leadingAnchor.constraint(equalTo: tokenSurfaceView.leadingAnchor),
      descriptionLabel.trailingAnchor.constraint(equalTo: tokenSurfaceView.trailingAnchor),
      descriptionLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -18.0),
    ])

    copyButton.addTarget(self, action: #selector(handleCopyPressed), for: .touchUpInside)
    rotateButton.addTarget(self, action: #selector(handleRotatePressed), for: .touchUpInside)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func applyTheme(_ theme: ChatNativeAgentConfigTheme) {
    self.theme = theme
    cardView.backgroundColor = theme.cardColor
    cardView.layer.borderColor = theme.cardStrokeColor.cgColor
    headerIcon.tintColor = theme.secondaryTextColor
    headerLabel.textColor = theme.secondaryTextColor
    tokenLabel.textColor = theme.textColor
    tokenSpinner.color = theme.secondaryTextColor
    descriptionLabel.textColor = theme.secondaryTextColor
    tokenSurfaceView.backgroundColor = theme.inputColor
    revealButton.tintColor = theme.accentColor

    var copyConfiguration = copyButton.configuration
    copyConfiguration?.baseBackgroundColor = theme.primaryButtonColor
    copyConfiguration?.baseForegroundColor = .white
    copyButton.configuration = copyConfiguration

    var rotateConfiguration = rotateButton.configuration
    rotateConfiguration?.baseBackgroundColor = theme.secondaryButtonColor
    rotateConfiguration?.baseForegroundColor = theme.textColor
    rotateButton.configuration = rotateConfiguration
  }

  func configure(
    secret: String?,
    hint: String?,
    isLoading: Bool,
    isRevealed: Bool,
    canReveal: Bool
  ) {
    let revealed = isRevealed && (secret != nil)
    if isLoading {
      tokenLabel.isHidden = true
      tokenCoverView.isHidden = true
      tokenSpinner.startAnimating()
    } else {
      tokenSpinner.stopAnimating()
      tokenLabel.isHidden = false
      // The label underneath always carries real-looking token text (the actual
      // secret when known, a realistic placeholder otherwise) — the shimmer cover
      // is what hides it, not the text content itself, so revealing is a smooth
      // wipe instead of a content swap.
      tokenLabel.text = secret ?? chatNativeAgentMaskedSecret(hint)
      tokenCoverView.isHidden = false
      UIView.animate(withDuration: 0.3) { [tokenCoverView] in
        tokenCoverView.alpha = revealed ? 0.0 : 1.0
      } completion: { [tokenCoverView] _ in
        tokenCoverView.isHidden = revealed
      }
    }

    let eyeSymbol = revealed ? "eye.slash.fill" : "eye.fill"
    revealButton.setImage(
      UIImage(
        systemName: eyeSymbol,
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .semibold)
      ),
      for: .normal
    )
    revealButton.isHidden = !canReveal
    revealButton.isEnabled = !isLoading

    copyButton.isEnabled = !isLoading
    rotateButton.isEnabled = !isLoading
    copyButton.alpha = copyButton.isEnabled ? 1.0 : 0.6
    rotateButton.alpha = rotateButton.isEnabled ? 1.0 : 0.6
  }

  @objc private func handleRevealPressed() {
    onReveal?()
  }

  @objc private func handleCopyPressed() {
    onCopy?()
  }

  @objc private func handleRotatePressed() {
    onRotate?()
  }
}

/// Hosts the UIKit `ChatNativeAgentSecretCardView` — reveal-eye / Copy / Rotate, already
/// fully built — as a section inside the SwiftUI settings Form (`ChatAgentSettingsView`
/// in ChatAgentConfigViews.swift), so the invoke-secret UI stays a single implementation
/// instead of a second SwiftUI-only rebuild.
struct ChatNativeAgentSecretCardRepresentable: UIViewRepresentable {
  let secret: String?
  let hint: String?
  let isLoading: Bool
  let isRevealed: Bool
  let canReveal: Bool
  let isDark: Bool
  let onReveal: () -> Void
  let onCopy: () -> Void
  let onRotate: () -> Void

  func makeUIView(context: Context) -> ChatNativeAgentSecretCardView {
    ChatNativeAgentSecretCardView()
  }

  func updateUIView(_ uiView: ChatNativeAgentSecretCardView, context: Context) {
    uiView.applyTheme(ChatNativeAgentConfigTheme(isDark: isDark))
    uiView.configure(
      secret: secret,
      hint: hint,
      isLoading: isLoading,
      isRevealed: isRevealed,
      canReveal: canReveal
    )
    uiView.onReveal = onReveal
    uiView.onCopy = onCopy
    uiView.onRotate = onRotate
  }

  // Every internal constraint in ChatNativeAgentSecretCardView is relative (leading/trailing
  // to its own bounds), so it has no intrinsic width of its own — without this, SwiftUI has
  // nothing to size it against and the Copy/Rotate row + description label overflow the
  // actual row width instead of wrapping/filling it. Forcing systemLayoutSizeFitting against
  // the row's REAL proposed width is what makes it lay out at that width instead of guessing.
  func sizeThatFits(
    _ proposal: ProposedViewSize, uiView: ChatNativeAgentSecretCardView, context: Context
  ) -> CGSize? {
    // A Form may make an initial measurement pass without proposing a width.
    // Returning the full screen width during that pass made the representable keep
    // that width, so the equal Copy/Rotate buttons overflowed the actual row.
    guard let width = proposal.width, width > 0 else { return nil }
    let fitting = uiView.systemLayoutSizeFitting(
      CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    )
    return CGSize(width: width, height: fitting.height)
  }
}

private final class ChatNativeAgentPromptViewController: UIViewController {
  private let originalPrompt: String
  private let theme: ChatNativeAgentConfigTheme
  private let allowsEditing: Bool
  private let onSave: ((String, @escaping (Bool) -> Void) -> Void)?
  private let textView = UITextView()
  private var isSaving = false

  init(
    prompt: String,
    theme: ChatNativeAgentConfigTheme,
    allowsEditing: Bool = false,
    onSave: ((String, @escaping (Bool) -> Void) -> Void)? = nil
  ) {
    self.originalPrompt = prompt
    self.theme = theme
    self.allowsEditing = allowsEditing
    self.onSave = onSave
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = theme.backgroundColor
    title = allowsEditing ? "Edit Prompt" : "Prompt"

    if allowsEditing {
      navigationItem.rightBarButtonItem = UIBarButtonItem(
        title: "Save",
        style: .done,
        target: self,
        action: #selector(handleSave)
      )
    }

    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.backgroundColor = theme.inputColor
    textView.textColor = theme.textColor
    textView.font = .systemFont(ofSize: 15.0, weight: .regular)
    textView.layer.cornerRadius = 16.0
    textView.layer.cornerCurve = .continuous
    textView.isEditable = allowsEditing
    textView.text = originalPrompt
    textView.delegate = self
    textView.textContainerInset = UIEdgeInsets(top: 16.0, left: 14.0, bottom: 16.0, right: 14.0)
    view.addSubview(textView)

    NSLayoutConstraint.activate([
      textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16.0),
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16.0),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16.0),
      textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16.0),
    ])

    updateSaveButtonState()
  }

  @objc private func handleSave() {
    guard allowsEditing, !isSaving else { return }
    let normalizedPrompt = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedPrompt.isEmpty else { return }

    if normalizedPrompt == originalPrompt.trimmingCharacters(in: .whitespacesAndNewlines) {
      navigationController?.popViewController(animated: true)
      return
    }

    guard let onSave else { return }

    isSaving = true
    updateSaveButtonState()

    onSave(normalizedPrompt) { [weak self] success in
      DispatchQueue.main.async {
        guard let self else { return }
        self.isSaving = false
        self.updateSaveButtonState()
        if success {
          self.navigationController?.popViewController(animated: true)
        }
      }
    }
  }

  private func updateSaveButtonState() {
    guard allowsEditing else { return }
    let normalizedPrompt = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    navigationItem.rightBarButtonItem?.isEnabled =
      !isSaving
      && !normalizedPrompt.isEmpty
      && normalizedPrompt != originalPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

extension ChatNativeAgentPromptViewController: UITextViewDelegate {
  func textViewDidChange(_ textView: UITextView) {
    updateSaveButtonState()
  }
}

private final class ChatNativeAgentDetailViewController: UIViewController {
  private let detailTitle: String
  private let detailValue: String
  private let theme: ChatNativeAgentConfigTheme
  private let onToast: ((String) -> Void)?

  init(
    title: String,
    value: String,
    theme: ChatNativeAgentConfigTheme,
    onToast: ((String) -> Void)?
  ) {
    self.detailTitle = title
    self.detailValue = value
    self.theme = theme
    self.onToast = onToast
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = theme.backgroundColor
    title = detailTitle

    let appearance = UINavigationBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = theme.backgroundColor
    appearance.shadowColor = .clear
    appearance.titleTextAttributes = [.foregroundColor: theme.textColor]
    navigationController?.navigationBar.standardAppearance = appearance
    navigationController?.navigationBar.scrollEdgeAppearance = appearance
    navigationController?.navigationBar.tintColor = theme.accentColor

    let textView = UITextView()
    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.backgroundColor = theme.inputColor
    textView.textColor = theme.textColor
    textView.font = .monospacedSystemFont(ofSize: 15.0, weight: .regular)
    textView.layer.cornerRadius = 12.0
    textView.layer.cornerCurve = .continuous
    textView.isEditable = false
    textView.text = detailValue
    textView.textContainerInset = UIEdgeInsets(top: 16.0, left: 14.0, bottom: 16.0, right: 14.0)
    view.addSubview(textView)

    let copyButton = ChatNativeAgentActionButton(title: "Copy to Clipboard", fillColor: theme.primaryButtonColor)
    copyButton.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(copyButton)

    NSLayoutConstraint.activate([
      textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16.0),
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16.0),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16.0),

      copyButton.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 20.0),
      copyButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16.0),
      copyButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16.0),
      copyButton.heightAnchor.constraint(equalToConstant: 50.0),
      copyButton.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16.0)
    ])

    copyButton.addTarget(self, action: #selector(handleCopy), for: .touchUpInside)
  }

  @objc private func handleCopy() {
    UIPasteboard.general.string = detailValue
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    onToast?("Copied to clipboard")
  }
}

/// A single selectable option in a pushed picker page.
private struct ChatNativeAgentPickerOption {
  let title: String
  let subtitle: String?
  let isSelected: Bool
}

/// A pushed single-select page that replaces the old bottom action sheets.
/// Each option is a full card row with a trailing checkmark — it animates in as
/// a real navigation push, which feels far more intentional than a popover.
private final class ChatNativeAgentOptionPickerViewController: UIViewController {
  private let pickerTitle: String
  private let pickerSubtitle: String?
  private let options: [ChatNativeAgentPickerOption]
  private let theme: ChatNativeAgentConfigTheme
  private let onSelect: (Int) -> Void

  init(
    title: String,
    subtitle: String?,
    options: [ChatNativeAgentPickerOption],
    theme: ChatNativeAgentConfigTheme,
    onSelect: @escaping (Int) -> Void
  ) {
    self.pickerTitle = title
    self.pickerSubtitle = subtitle
    self.options = options
    self.theme = theme
    self.onSelect = onSelect
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = theme.backgroundColor
    title = pickerTitle

    let appearance = UINavigationBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = theme.backgroundColor
    appearance.shadowColor = .clear
    appearance.titleTextAttributes = [.foregroundColor: theme.textColor]
    navigationController?.navigationBar.standardAppearance = appearance
    navigationController?.navigationBar.scrollEdgeAppearance = appearance
    navigationController?.navigationBar.tintColor = theme.accentColor

    let scrollView = UIScrollView()
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.alwaysBounceVertical = true
    view.addSubview(scrollView)

    let stack = UIStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 12.0
    scrollView.addSubview(stack)

    if let pickerSubtitle, !pickerSubtitle.isEmpty {
      let caption = UILabel()
      caption.font = .systemFont(ofSize: 14.0, weight: .regular)
      caption.textColor = theme.secondaryTextColor
      caption.numberOfLines = 0
      caption.text = pickerSubtitle
      stack.addArrangedSubview(caption)
      stack.setCustomSpacing(18.0, after: caption)
    }

    for (index, option) in options.enumerated() {
      stack.addArrangedSubview(makeRow(option: option, index: index))
    }

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20.0),
      stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 18.0),
      stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -18.0),
      stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24.0),
    ])
  }

  private func makeRow(option: ChatNativeAgentPickerOption, index: Int) -> UIView {
    let row = ChatNativeAgentHighlightControl()
    row.translatesAutoresizingMaskIntoConstraints = false
    row.backgroundColor = theme.cardColor
    row.layer.cornerRadius = 16.0
    row.layer.cornerCurve = .continuous
    row.layer.borderWidth = 1.0 / UIScreen.main.scale
    row.layer.borderColor =
      (option.isSelected ? theme.accentColor.withAlphaComponent(0.5) : theme.cardStrokeColor).cgColor
    row.tag = index
    row.addTarget(self, action: #selector(handleSelect(_:)), for: .touchUpInside)

    let textStack = UIStackView()
    textStack.translatesAutoresizingMaskIntoConstraints = false
    textStack.axis = .vertical
    textStack.spacing = 3.0
    textStack.isUserInteractionEnabled = false
    row.addSubview(textStack)

    let titleLabel = UILabel()
    titleLabel.font = .systemFont(ofSize: 16.0, weight: .semibold)
    titleLabel.textColor = theme.textColor
    titleLabel.text = option.title
    titleLabel.numberOfLines = 0
    textStack.addArrangedSubview(titleLabel)

    if let subtitle = option.subtitle, !subtitle.isEmpty {
      let subtitleLabel = UILabel()
      subtitleLabel.font = .systemFont(ofSize: 13.5, weight: .regular)
      subtitleLabel.textColor = theme.secondaryTextColor
      subtitleLabel.text = subtitle
      subtitleLabel.numberOfLines = 0
      textStack.addArrangedSubview(subtitleLabel)
    }

    let check = UIImageView(
      image: UIImage(
        systemName: "checkmark.circle.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 20.0, weight: .semibold)
      )
    )
    check.translatesAutoresizingMaskIntoConstraints = false
    check.tintColor = theme.accentColor
    check.isHidden = !option.isSelected
    check.isUserInteractionEnabled = false
    row.addSubview(check)

    NSLayoutConstraint.activate([
      textStack.topAnchor.constraint(equalTo: row.topAnchor, constant: 15.0),
      textStack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -15.0),
      textStack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 18.0),
      textStack.trailingAnchor.constraint(equalTo: check.leadingAnchor, constant: -12.0),

      check.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -18.0),
      check.centerYAnchor.constraint(equalTo: row.centerYAnchor),
      check.widthAnchor.constraint(equalToConstant: 22.0),

      row.heightAnchor.constraint(greaterThanOrEqualToConstant: 60.0),
    ])

    return row
  }

  @objc private func handleSelect(_ sender: UIControl) {
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    onSelect(sender.tag)
    navigationController?.popViewController(animated: true)
  }
}

/// A pushed single-line text editor used for inline edits (e.g. renaming the
/// agent) so we no longer fall back to a cramped UIAlertController text field.
private final class ChatNativeAgentTextEditViewController: UIViewController, UITextFieldDelegate {
  private let editTitle: String
  private let caption: String?
  private let placeholder: String
  private let initialValue: String
  private let theme: ChatNativeAgentConfigTheme
  private let onSave: (String, @escaping (Bool) -> Void) -> Void

  private let field = UITextField()
  private var isSaving = false

  init(
    title: String,
    caption: String?,
    placeholder: String,
    initialValue: String,
    theme: ChatNativeAgentConfigTheme,
    onSave: @escaping (String, @escaping (Bool) -> Void) -> Void
  ) {
    self.editTitle = title
    self.caption = caption
    self.placeholder = placeholder
    self.initialValue = initialValue
    self.theme = theme
    self.onSave = onSave
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = theme.backgroundColor
    title = editTitle

    let appearance = UINavigationBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = theme.backgroundColor
    appearance.shadowColor = .clear
    appearance.titleTextAttributes = [.foregroundColor: theme.textColor]
    navigationController?.navigationBar.standardAppearance = appearance
    navigationController?.navigationBar.scrollEdgeAppearance = appearance
    navigationController?.navigationBar.tintColor = theme.accentColor

    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "Save", style: .done, target: self, action: #selector(handleSave))

    let surface = UIView()
    surface.translatesAutoresizingMaskIntoConstraints = false
    surface.backgroundColor = theme.cardColor
    surface.layer.cornerRadius = 16.0
    surface.layer.cornerCurve = .continuous
    surface.layer.borderWidth = 1.0 / UIScreen.main.scale
    surface.layer.borderColor = theme.cardStrokeColor.cgColor
    view.addSubview(surface)

    field.translatesAutoresizingMaskIntoConstraints = false
    field.font = .systemFont(ofSize: 17.0, weight: .regular)
    field.textColor = theme.textColor
    field.tintColor = theme.accentColor
    field.text = initialValue
    field.clearButtonMode = .whileEditing
    field.autocapitalizationType = .words
    field.returnKeyType = .done
    field.delegate = self
    field.attributedPlaceholder = NSAttributedString(
      string: placeholder,
      attributes: [.foregroundColor: theme.secondaryTextColor]
    )
    field.addTarget(self, action: #selector(handleFieldChange), for: .editingChanged)
    surface.addSubview(field)

    let captionLabel = UILabel()
    captionLabel.translatesAutoresizingMaskIntoConstraints = false
    captionLabel.font = .systemFont(ofSize: 13.0, weight: .regular)
    captionLabel.textColor = theme.secondaryTextColor
    captionLabel.numberOfLines = 0
    captionLabel.text = caption
    view.addSubview(captionLabel)

    NSLayoutConstraint.activate([
      surface.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20.0),
      surface.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18.0),
      surface.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18.0),
      surface.heightAnchor.constraint(equalToConstant: 56.0),

      field.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16.0),
      field.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -16.0),
      field.centerYAnchor.constraint(equalTo: surface.centerYAnchor),

      captionLabel.topAnchor.constraint(equalTo: surface.bottomAnchor, constant: 10.0),
      captionLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 22.0),
      captionLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -22.0),
    ])

    updateSaveState()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    field.becomeFirstResponder()
  }

  @objc private func handleFieldChange() {
    updateSaveState()
  }

  private func updateSaveState() {
    let trimmed = field.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    navigationItem.rightBarButtonItem?.isEnabled =
      !isSaving && !trimmed.isEmpty && trimmed != initialValue.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  @objc private func handleSave() {
    let trimmed = field.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty, !isSaving else { return }
    isSaving = true
    updateSaveState()
    onSave(trimmed) { [weak self] success in
      DispatchQueue.main.async {
        guard let self else { return }
        self.isSaving = false
        if success {
          self.navigationController?.popViewController(animated: true)
        } else {
          self.updateSaveState()
        }
      }
    }
  }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    handleSave()
    return true
  }
}

/// Dedicated inner page for an agent's notification inbox. A master toggle at the
/// top switches between inline event bubbles (off) and the batched Inbox (on);
/// when on, the owner picks how summaries are delivered — either a rolling
/// interval or fixed clock times. Each option is explained inline so the row
/// labels are self-describing. Times are entered in the device's local timezone
/// and persisted to the backend as UTC "HH:MM".
private final class ChatNativeAgentInboxSettingsViewController: UIViewController {
  /// `onSave(mode, schedule, windowHours, utcTimes, completion)` — `mode` is
  /// "per_event" or "batched_summary"; `schedule` is "interval" or "daily".
  typealias SaveHandler = (String, String, Int, [String], @escaping (Bool) -> Void) -> Void

  private let theme: ChatNativeAgentConfigTheme
  private let onSave: SaveHandler

  private var isEnabled: Bool
  private var schedule: String
  private var windowHours: Int
  /// Delivery times in UTC, "HH:MM", sorted/unique.
  private var utcTimes: [String]
  private var isSaving = false

  private let scrollView = UIScrollView()
  private let stackView = UIStackView()
  private let pendingTimePicker = UIDatePicker()

  private static let windowOptions = [1, 2, 4, 6, 12, 24]

  init(
    mode: String,
    schedule: String?,
    windowHours: Int,
    times: [String],
    theme: ChatNativeAgentConfigTheme,
    onSave: @escaping SaveHandler
  ) {
    self.theme = theme
    self.onSave = onSave
    self.isEnabled = chatNativeAgentNormalizeEventInboxMode(mode) == "batched_summary"
    let normalizedSchedule = (schedule?.lowercased() == "daily") ? "daily" : "interval"
    self.schedule = normalizedSchedule
    self.windowHours = chatNativeAgentNormalizeSummaryWindowHours(windowHours)
    self.utcTimes = ChatNativeAgentInboxSettingsViewController.normalize(times)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { return nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Inbox"
    view.backgroundColor = theme.backgroundColor

    let appearance = UINavigationBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = theme.backgroundColor
    appearance.shadowColor = .clear
    appearance.titleTextAttributes = [.foregroundColor: theme.textColor]
    navigationController?.navigationBar.standardAppearance = appearance
    navigationController?.navigationBar.scrollEdgeAppearance = appearance
    navigationController?.navigationBar.tintColor = theme.accentColor

    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "Save", style: .done, target: self, action: #selector(handleSave))

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.alwaysBounceVertical = true
    scrollView.keyboardDismissMode = .interactive
    view.addSubview(scrollView)

    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .vertical
    stackView.spacing = 22.0
    scrollView.addSubview(stackView)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20.0),
      stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16.0),
      stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16.0),
      stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28.0),
      stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32.0),
    ])

    pendingTimePicker.datePickerMode = .time
    pendingTimePicker.minuteInterval = 5
    if #available(iOS 14.0, *) { pendingTimePicker.preferredDatePickerStyle = .compact }
    pendingTimePicker.tintColor = theme.accentColor

    rebuild()
  }

  // MARK: - Build

  private func rebuild() {
    stackView.arrangedSubviews.forEach {
      stackView.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }

    stackView.addArrangedSubview(buildToggleSection())

    guard isEnabled else { return }

    stackView.addArrangedSubview(buildScheduleSection())

    if schedule == "daily" {
      stackView.addArrangedSubview(buildTimesSection())
    } else {
      stackView.addArrangedSubview(buildWindowSection())
    }
  }

  private func buildToggleSection() -> UIView {
    let section = ChatNativeAgentConfigSectionView(
      title: "Notifications",
      theme: theme,
      footnote:
        isEnabled
        ? "Inbox is on. Incoming notifications are collected behind the Inbox banner and delivered as summaries instead of filling the chat."
        : "Inbox is off. Each notification appears inline in the chat as its own event bubble."
    )
    let row = makePaddedRow()
    let label = makeTitleLabel("Inbox mode")
    let toggle = UISwitch()
    toggle.onTintColor = theme.accentColor
    toggle.isOn = isEnabled
    toggle.addTarget(self, action: #selector(handleToggle(_:)), for: .valueChanged)
    row.addArrangedSubview(label)
    row.addArrangedSubview(UIView())
    row.addArrangedSubview(toggle)
    section.contentStack.addArrangedSubview(row)
    return section
  }

  private func buildScheduleSection() -> UIView {
    let section = ChatNativeAgentConfigSectionView(
      title: "Summary schedule",
      theme: theme,
      footnote:
        schedule == "daily"
        ? "Summaries are delivered at the fixed times you choose below."
        : "Summaries are delivered on a rolling interval after the first new notification."
    )
    let container = makePaddedColumn()
    let control = UISegmentedControl(items: ["Every few hours", "At set times"])
    control.selectedSegmentIndex = schedule == "daily" ? 1 : 0
    control.selectedSegmentTintColor = theme.accentColor
    control.addTarget(self, action: #selector(handleScheduleChange(_:)), for: .valueChanged)
    container.addArrangedSubview(control)
    section.contentStack.addArrangedSubview(container)
    return section
  }

  private func buildWindowSection() -> UIView {
    let section = ChatNativeAgentConfigSectionView(
      title: "Frequency",
      theme: theme,
      footnote: "A summary is posted at most once per window, only when there are new notifications."
    )
    let container = makePaddedColumn()
    let items = Self.windowOptions.map { $0 < 24 ? "\($0)h" : "Daily" }
    let control = UISegmentedControl(items: items)
    control.selectedSegmentIndex = Self.windowOptions.firstIndex(of: windowHours) ?? 2
    control.selectedSegmentTintColor = theme.accentColor
    control.apportionsSegmentWidthsByContent = true
    control.addTarget(self, action: #selector(handleWindowChange(_:)), for: .valueChanged)
    container.addArrangedSubview(control)
    section.contentStack.addArrangedSubview(container)
    return section
  }

  private func buildTimesSection() -> UIView {
    let section = ChatNativeAgentConfigSectionView(
      title: "Delivery times",
      theme: theme,
      footnote: "Times use your device's local time. Add one or more times of day to receive a summary."
    )

    if utcTimes.isEmpty {
      let empty = makePaddedRow()
      let label = makeTitleLabel("No times yet")
      label.textColor = theme.secondaryTextColor
      empty.addArrangedSubview(label)
      empty.addArrangedSubview(UIView())
      section.contentStack.addArrangedSubview(empty)
    } else {
      for utc in utcTimes {
        let row = makePaddedRow()
        let label = makeTitleLabel(Self.localDisplay(forUTC: utc))
        let remove = UIButton(type: .system)
        remove.setImage(UIImage(systemName: "trash"), for: .normal)
        remove.tintColor = theme.destructiveColor
        remove.addAction(
          UIAction { [weak self] _ in self?.removeTime(utc) }, for: .touchUpInside)
        row.addArrangedSubview(label)
        row.addArrangedSubview(UIView())
        row.addArrangedSubview(remove)
        section.contentStack.addArrangedSubview(row)
        section.contentStack.addArrangedSubview(makeDivider())
      }
    }

    let addRow = makePaddedRow()
    let addLabel = makeTitleLabel("Add time")
    pendingTimePicker.setContentHuggingPriority(.required, for: .horizontal)
    let addButton = UIButton(type: .system)
    addButton.setTitle("Add", for: .normal)
    addButton.tintColor = theme.accentColor
    addButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
    addButton.addAction(UIAction { [weak self] _ in self?.addPendingTime() }, for: .touchUpInside)
    addRow.addArrangedSubview(addLabel)
    addRow.addArrangedSubview(UIView())
    addRow.addArrangedSubview(pendingTimePicker)
    addRow.addArrangedSubview(addButton)
    section.contentStack.addArrangedSubview(addRow)
    return section
  }

  // MARK: - Actions

  @objc private func handleToggle(_ sender: UISwitch) {
    isEnabled = sender.isOn
    rebuild()
  }

  @objc private func handleScheduleChange(_ sender: UISegmentedControl) {
    schedule = sender.selectedSegmentIndex == 1 ? "daily" : "interval"
    rebuild()
  }

  @objc private func handleWindowChange(_ sender: UISegmentedControl) {
    if Self.windowOptions.indices.contains(sender.selectedSegmentIndex) {
      windowHours = Self.windowOptions[sender.selectedSegmentIndex]
    }
  }

  private func addPendingTime() {
    let comps = Calendar.current.dateComponents([.hour, .minute], from: pendingTimePicker.date)
    guard let hour = comps.hour, let minute = comps.minute else { return }
    let utc = Self.utcString(localHour: hour, localMinute: minute)
    utcTimes = Self.normalize(utcTimes + [utc])
    rebuild()
  }

  private func removeTime(_ utc: String) {
    utcTimes.removeAll { $0 == utc }
    rebuild()
  }

  @objc private func handleSave() {
    guard !isSaving else { return }
    if isEnabled, schedule == "daily", utcTimes.isEmpty {
      let alert = UIAlertController(
        title: "Add a time",
        message: "Add at least one delivery time, or switch to “Every few hours”.",
        preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: "OK", style: .default))
      present(alert, animated: true)
      return
    }

    isSaving = true
    navigationItem.rightBarButtonItem?.isEnabled = false

    let mode = isEnabled ? "batched_summary" : "per_event"
    onSave(mode, schedule, windowHours, utcTimes) { [weak self] success in
      guard let self else { return }
      self.isSaving = false
      self.navigationItem.rightBarButtonItem?.isEnabled = true
      if success {
        self.navigationController?.popViewController(animated: true)
      }
    }
  }

  // MARK: - Helpers

  private func makePaddedRow() -> UIStackView {
    let row = UIStackView()
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 10.0
    row.isLayoutMarginsRelativeArrangement = true
    row.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
    return row
  }

  private func makePaddedColumn() -> UIStackView {
    let col = UIStackView()
    col.axis = .vertical
    col.spacing = 10.0
    col.isLayoutMarginsRelativeArrangement = true
    col.layoutMargins = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
    return col
  }

  private func makeTitleLabel(_ text: String) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = .systemFont(ofSize: 16.0, weight: .regular)
    label.textColor = theme.textColor
    return label
  }

  private func makeDivider() -> UIView {
    let divider = UIView()
    divider.backgroundColor = theme.separatorColor
    divider.translatesAutoresizingMaskIntoConstraints = false
    divider.heightAnchor.constraint(equalToConstant: 1.0 / UIScreen.main.scale).isActive = true
    return divider
  }

  private static func normalize(_ times: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for value in times {
      let parts = value.split(separator: ":", maxSplits: 1)
      guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]),
        (0...23).contains(h), (0...59).contains(m)
      else { continue }
      let formatted = String(format: "%02d:%02d", h, m)
      if seen.insert(formatted).inserted { out.append(formatted) }
    }
    return out.sorted()
  }

  /// Converts a local clock time to a UTC "HH:MM" string.
  private static func utcString(localHour: Int, localMinute: Int) -> String {
    let offsetMinutes = TimeZone.current.secondsFromGMT() / 60
    let total = ((localHour * 60 + localMinute) - offsetMinutes) % 1440
    let normalized = (total + 1440) % 1440
    return String(format: "%02d:%02d", normalized / 60, normalized % 60)
  }

  /// Formats a stored UTC "HH:MM" into a localized local-time string for display.
  private static func localDisplay(forUTC utc: String) -> String {
    let parts = utc.split(separator: ":", maxSplits: 1)
    guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return utc }
    let offsetMinutes = TimeZone.current.secondsFromGMT() / 60
    let total = ((h * 60 + m) + offsetMinutes) % 1440
    let normalized = (total + 1440) % 1440
    var comps = DateComponents()
    comps.hour = normalized / 60
    comps.minute = normalized % 60
    if let date = Calendar.current.date(from: comps) {
      let formatter = DateFormatter()
      formatter.timeStyle = .short
      return formatter.string(from: date)
    }
    return String(format: "%02d:%02d", normalized / 60, normalized % 60)
  }
}

/// A UIControl that dims slightly while pressed — shared by tappable cards.
final class ChatNativeAgentHighlightControl: UIControl {
  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: 0.12) {
        self.alpha = self.isHighlighted ? 0.7 : 1.0
      }
    }
  }
}


/// A loading placeholder that sweeps a soft highlight across card-shaped rows.
/// The previous version just pulsed opacity on flat blocks, which read as
/// broken; a travelling shimmer reads as "loading" and feels premium.
final class ChatNativeAgentShimmerView: UIView {
  private let gradientLayer = CAGradientLayer()
  private var baseColor: UIColor
  private var highlightColor: UIColor

  init(baseColor: UIColor, highlightColor: UIColor, cornerRadius: CGFloat) {
    self.baseColor = baseColor
    self.highlightColor = highlightColor
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    backgroundColor = baseColor
    layer.cornerRadius = cornerRadius
    layer.cornerCurve = .continuous
    clipsToBounds = true

    gradientLayer.colors = [
      baseColor.cgColor,
      highlightColor.cgColor,
      baseColor.cgColor,
    ]
    gradientLayer.startPoint = CGPoint(x: 0.0, y: 0.5)
    gradientLayer.endPoint = CGPoint(x: 1.0, y: 0.5)
    gradientLayer.locations = [0.0, 0.5, 1.0]
    layer.addSublayer(gradientLayer)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func applyColors(base: UIColor, highlight: UIColor) {
    baseColor = base
    highlightColor = highlight
    backgroundColor = base
    gradientLayer.colors = [base.cgColor, highlight.cgColor, base.cgColor]
  }

  private var animatedWidth: CGFloat = 0

  override func layoutSubviews() {
    super.layoutSubviews()
    // Extend beyond bounds so the sweep enters/exits cleanly.
    gradientLayer.frame = CGRect(x: -bounds.width, y: 0, width: bounds.width * 3.0, height: bounds.height)
    // A CABasicAnimation bakes its toValue in at add-time. Hosted inside a SwiftUI
    // representable (e.g. the secret card, sized via a custom `sizeThatFits`), this
    // view can enter the window and fire `didMoveToWindow` BEFORE SwiftUI resolves
    // its real row width — so the very first `startAnimating()` call adds an
    // animation from 0 to 0 and nothing is ever visibly restarted once the real
    // width lands. Restart whenever the resolved width actually changes instead.
    if bounds.width > 0, abs(bounds.width - animatedWidth) > 0.5 {
      startAnimating()
    }
  }

  // Self-starting: callers that just add this to a hierarchy (e.g. the secret
  // card's cover, which isn't itself a container that already knows to kick
  // off animation the way the skeleton loader's parent does) get the sweep
  // for free once real bounds exist, with no separate wiring required.
  override func didMoveToWindow() {
    super.didMoveToWindow()
    guard window != nil else { return }
    layoutIfNeeded()
    startAnimating()
  }

  func startAnimating() {
    guard bounds.width > 0 else { return }
    animatedWidth = bounds.width
    let animation = CABasicAnimation(keyPath: "transform.translation.x")
    animation.fromValue = 0
    animation.toValue = bounds.width
    animation.duration = 1.2
    animation.repeatCount = .infinity
    animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    gradientLayer.add(animation, forKey: "shimmer")
  }

  /// Re-tints an already-built shimmer (e.g. on theme change) without tearing
  /// down the running sweep animation.
  func updateColors(base: UIColor, highlight: UIColor) {
    backgroundColor = base
    gradientLayer.colors = [base.cgColor, highlight.cgColor, base.cgColor]
  }
}

final class ChatNativeAgentSkeletonView: UIView {
  private var shimmers: [ChatNativeAgentShimmerView] = []
  private var rows: [UIView] = []

  init(theme: ChatNativeAgentConfigTheme) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    let stackView = UIStackView()
    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .vertical
    stackView.spacing = 12.0
    addSubview(stackView)

    NSLayoutConstraint.activate([
      stackView.topAnchor.constraint(equalTo: topAnchor, constant: 14.0),
      stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16.0),
      stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16.0),
    ])

    let base = theme.cardColor
    let highlight = theme.inputColor

    for _ in 0..<6 {
      let row = UIView()
      row.translatesAutoresizingMaskIntoConstraints = false
      row.backgroundColor = theme.cardColor
      row.layer.cornerRadius = 16.0
      row.layer.cornerCurve = .continuous
      row.layer.borderWidth = 1.0 / UIScreen.main.scale
      row.layer.borderColor = theme.cardStrokeColor.cgColor
      row.heightAnchor.constraint(equalToConstant: 74.0).isActive = true

      let avatar = ChatNativeAgentShimmerView(baseColor: base, highlightColor: highlight, cornerRadius: 23.0)
      row.addSubview(avatar)
      let title = ChatNativeAgentShimmerView(baseColor: base, highlightColor: highlight, cornerRadius: 6.0)
      row.addSubview(title)
      let subtitle = ChatNativeAgentShimmerView(baseColor: base, highlightColor: highlight, cornerRadius: 6.0)
      row.addSubview(subtitle)
      shimmers.append(contentsOf: [avatar, title, subtitle])

      NSLayoutConstraint.activate([
        avatar.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14.0),
        avatar.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        avatar.widthAnchor.constraint(equalToConstant: 46.0),
        avatar.heightAnchor.constraint(equalToConstant: 46.0),

        title.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 13.0),
        title.bottomAnchor.constraint(equalTo: row.centerYAnchor, constant: -3.0),
        title.widthAnchor.constraint(equalToConstant: 140.0),
        title.heightAnchor.constraint(equalToConstant: 13.0),

        subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
        subtitle.topAnchor.constraint(equalTo: row.centerYAnchor, constant: 6.0),
        subtitle.widthAnchor.constraint(equalToConstant: 90.0),
        subtitle.heightAnchor.constraint(equalToConstant: 11.0),
      ])

      stackView.addArrangedSubview(row)
      rows.append(row)
    }
  }

  required init?(coder: NSCoder) {
    return nil
  }

  /// Repaint on a theme switch — colours are baked into subviews at init.
  func applyTheme(_ theme: ChatNativeAgentConfigTheme) {
    for row in rows {
      row.backgroundColor = theme.cardColor
      row.layer.borderColor = theme.cardStrokeColor.cgColor
    }
    for shimmer in shimmers {
      shimmer.applyColors(base: theme.cardColor, highlight: theme.inputColor)
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    guard window != nil else { return }
    layoutIfNeeded()
    shimmers.forEach { $0.startAnimating() }
  }
}


final class ChatNativeAgentEmptyStateView: UIView {
  private let iconView = UIImageView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()

  init(theme: ChatNativeAgentConfigTheme) {
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false

    let container = UIStackView()
    container.translatesAutoresizingMaskIntoConstraints = false
    container.axis = .vertical
    container.alignment = .center
    container.spacing = 16.0
    addSubview(container)

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.image = UIImage(
      systemName: "person.crop.circle.badge.questionmark",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 48.0, weight: .light)
    )
    container.addArrangedSubview(iconView)

    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.text = "No Agents Yet"
    titleLabel.font = .systemFont(ofSize: 20.0, weight: .bold)
    titleLabel.textAlignment = .center
    container.addArrangedSubview(titleLabel)

    subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
    subtitleLabel.text = "Create a new agent from the builder to get started."
    subtitleLabel.font = .systemFont(ofSize: 15.0, weight: .regular)
    subtitleLabel.numberOfLines = 0
    subtitleLabel.textAlignment = .center
    container.addArrangedSubview(subtitleLabel)

    applyTheme(theme)

    NSLayoutConstraint.activate([
      container.centerXAnchor.constraint(equalTo: centerXAnchor),
      container.centerYAnchor.constraint(equalTo: centerYAnchor),
      container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 32.0),
      container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32.0)
    ])
  }

  /// Repaint on a theme switch — colours are baked into subviews at init.
  func applyTheme(_ theme: ChatNativeAgentConfigTheme) {
    iconView.tintColor = theme.secondaryTextColor.withAlphaComponent(0.5)
    titleLabel.textColor = theme.textColor
    subtitleLabel.textColor = theme.secondaryTextColor
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

// MARK: - Agent configuration profile

final class ChatNativeAgentConfigPanelController: UIViewController {
  private var card: ChatListRow.AgentCard
  private let injectedApiContext: ChatNativeAgentConfigAPIContext?
  // Falls back to the live session if a caller was ever constructed without a
  // valid context (e.g. resolved from a headless chat transport's own, separately
  // sourced config) — every network action on this screen (Rotate included) was
  // failing with "Missing API session" in exactly that situation, even though the
  // user WAS actually logged in the whole time.
  private var apiContext: ChatNativeAgentConfigAPIContext? {
    if let injectedApiContext { return injectedApiContext }
    guard let config = AppSessionConfig.current else { return nil }
    return ChatNativeAgentConfigAPIContext(apiBaseURL: config.apiBaseURL, token: config.authToken)
  }
  private let theme: ChatNativeAgentConfigTheme
  private var viewModel: ChatAgentConfigViewModel!
  private var activeSecretRequest: URLSessionDataTask?

  var onToast: ((String) -> Void)?
  var onDeleteAgent: ((ChatListRow.AgentCard, @escaping () -> Void) -> Void)?
  var onOpenAgentChat: ((ChatListRow.AgentCard) -> Void)?

  init(
    card: ChatListRow.AgentCard,
    appearance: ChatListAppearance,
    apiContext: ChatNativeAgentConfigAPIContext? = nil
  ) {
    self.card = card
    self.injectedApiContext = apiContext
    self.theme = ChatNativeAgentConfigTheme(appearance: appearance)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  deinit {
    activeSecretRequest?.cancel()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = theme.backgroundColor
    configureNavigation()
    
    viewModel = ChatAgentConfigViewModel(card: card)
    setupViewModelCallbacks()
    // Warm the shared tool-catalog cache now, while the user is looking at the
    // Profile section, so the Tools row never shows a spinner when it's tapped.
    loadToolRegistry { _ in }

    let hostingController = UIHostingController(rootView: ChatAgentSettingsView(viewModel: viewModel))
    addChild(hostingController)
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    hostingController.view.backgroundColor = .clear
    view.addSubview(hostingController.view)
    
    NSLayoutConstraint.activate([
      hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
      hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    
    hostingController.didMove(toParent: self)
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    // Chat surfaces live inside AppRootNavigationController with its system bar
    // hidden. A title alone cannot make that bar reappear, so every config entry
    // path must explicitly restore it before the push transition is rendered.
    navigationController?.setNavigationBarHidden(false, animated: false)
    configureNavigation()
  }

  private func setupViewModelCallbacks() {
    viewModel.onRename = { [weak self] proposedName, completion in
      self?.renameAgent(to: proposedName, completion: completion)
    }
    viewModel.onSavePrompt = { [weak self] proposedPrompt, completion in
      self?.saveSystemPrompt(proposedPrompt, completion: completion)
    }
    viewModel.onSetStatus = { [weak self] publish in
      self?.setStatus(publish: publish)
    }
    viewModel.onCopy = { [weak self] text in
      UIPasteboard.general.string = text
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      self?.onToast?("Copied to clipboard")
    }
    viewModel.onToast = { [weak self] message in
      self?.onToast?(message)
    }
    viewModel.onUpdateEventInboxMode = { [weak self] mode, schedule, hours, times, completion in
      self?.updateEventInboxMode(mode: mode, schedule: schedule, summaryWindowHours: hours, summaryTimes: times, completion: completion)
    }
    viewModel.onPickAvatar = { [weak self] in
      self?.presentAvatarPicker()
    }
    viewModel.onCheckUsername = { [weak self] username, completion in
      self?.checkUsernameAvailability(username, completion: completion)
    }
    viewModel.onSaveUsername = { [weak self] username, completion in
      self?.saveUsername(username, completion: completion)
    }
    viewModel.onLoadToolRegistry = { [weak self] completion in
      self?.loadToolRegistry(completion: completion)
    }
    viewModel.onSaveTools = { [weak self] tools, completion in
      self?.saveTools(tools, completion: completion)
    }
    viewModel.onLoadPromptVariables = { [weak self] completion in
      self?.loadPromptVariables(completion: completion)
    }
    viewModel.onSavePromptVariables = { [weak self] variables, completion in
      self?.savePromptVariables(variables, completion: completion)
    }
    viewModel.onLoadModelRegistry = { [weak self] completion in
      self?.loadModelRegistry(completion: completion)
    }
    viewModel.onSaveModelSelection = { [weak self] provider, modelId, completion in
      self?.saveModelSelection(provider: provider, modelId: modelId, completion: completion)
    }
    viewModel.onSaveVoiceProvider = { [weak self] provider, completion in
      self?.saveVoiceProvider(provider, completion: completion)
    }
    viewModel.onRotateInvokeSecret = { [weak self] completion in
      self?.rotateInvokeSecret(completion: completion)
    }
    viewModel.onLoadWebhookSecret = { [weak self] completion in
      self?.loadWebhookSecret(completion: completion)
    }
  }

  private func configureNavigation() {
    navigationItem.title = "Agent Settings"
    navigationItem.largeTitleDisplayMode = .never
    let appearance = UINavigationBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = theme.backgroundColor
    appearance.shadowColor = .clear
    appearance.titleTextAttributes = [.foregroundColor: theme.textColor]
    navigationController?.navigationBar.standardAppearance = appearance
    navigationController?.navigationBar.scrollEdgeAppearance = appearance
    navigationController?.navigationBar.compactAppearance = appearance
    navigationController?.navigationBar.tintColor = theme.accentColor
    navigationItem.standardAppearance = appearance
    navigationItem.scrollEdgeAppearance = appearance
    navigationItem.compactAppearance = appearance

    if navigationController?.viewControllers.first === self {
      navigationItem.leftBarButtonItem = UIBarButtonItem(
        barButtonSystemItem: .close,
        target: self,
        action: #selector(handleClose)
      )
    }

    let chatItem = UIBarButtonItem(
      image: UIImage(systemName: "bubble.left.and.bubble.right"),
      style: .plain,
      target: self,
      action: #selector(handleOpenChat)
    )
    chatItem.accessibilityLabel = "Open agent chat"
    navigationItem.rightBarButtonItem = chatItem
  }

  private func apiRequestURL(path: String) -> URL? {
    guard let apiContext else { return nil }
    let encodedAgentId =
      card.agentId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? card.agentId
    let resolvedPath =
      path
      .replacingOccurrences(of: "{agent_id}", with: encodedAgentId)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let normalizedPath = resolvedPath.hasPrefix("/") ? String(resolvedPath.dropFirst()) : resolvedPath
    return URL(string: normalizedPath, relativeTo: apiContext.apiBaseURL)
      ?? apiContext.apiBaseURL.appendingPathComponent(normalizedPath)
  }

  private func apiHeaders(_ request: inout URLRequest) {
    guard let apiContext else { return }
    request.setValue("Bearer \(apiContext.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
  }

  private func updateCard(
    displayName: String? = nil,
    username: String? = nil,
    avatarUrl: String? = nil,
    status: String? = nil,
    secret: String? = nil,
    secretHint: String? = nil,
    promptStatus: String? = nil,
    promptPreview: String? = nil,
    systemPrompt: String? = nil,
    modelProvider: String? = nil,
    modelId: String? = nil,
    enabledTools: [String]? = nil,
    eventInboxMode: String? = nil,
    summaryWindowHours: Int? = nil,
    summarySchedule: String? = nil,
    summaryTimes: [String]? = nil,
    incomingChatEnabled: Bool? = nil,
    voiceProvider: String? = nil
  ) {
    card = ChatListRow.AgentCard(
      id: card.id,
      style: card.style,
      agentId: card.agentId,
      agentUserId: card.agentUserId,
      displayName: displayName ?? card.displayName,
      username: username ?? card.username,
      identifier: card.identifier,
      avatarUrl: avatarUrl ?? card.avatarUrl,
      status: status ?? card.status,
      promptStatus: promptStatus ?? card.promptStatus,
      promptPreview: promptPreview ?? card.promptPreview,
      systemPrompt: systemPrompt ?? card.systemPrompt,
      modelProvider: modelProvider ?? card.modelProvider,
      modelId: modelId ?? card.modelId,
      enabledTools: enabledTools ?? card.enabledTools,
      outputModes: card.outputModes,
      voiceProfile: card.voiceProfile,
      voiceProvider: voiceProvider ?? card.voiceProvider,
      callbackURL: card.callbackURL,
      apiBaseURL: card.apiBaseURL,
      invokeURL: card.invokeURL,
      eventsURL: card.eventsURL,
      builderLink: card.builderLink,
      agentDMURL: card.agentDMURL,
      secretHint: secretHint ?? card.secretHint,
      latestSecret: secret ?? card.latestSecret,
      defaultDestinationChat: card.defaultDestinationChat,
      attachedChats: card.attachedChats,
      eventInboxMode:
        chatNativeAgentNormalizeEventInboxMode(eventInboxMode ?? card.eventInboxMode),
      summaryWindowHours:
        chatNativeAgentNormalizeSummaryWindowHours(summaryWindowHours ?? card.summaryWindowHours),
      summarySchedule: summarySchedule ?? card.summarySchedule,
      summaryTimes: summaryTimes ?? card.summaryTimes,
      incomingChatEnabled: incomingChatEnabled ?? card.incomingChatEnabled,
      canDelete: card.canDelete
    )
    viewModel?.card = card
  }




  /// Publishes a draft (POST /publish) or reverts a published agent back to
  /// draft (PUT status: draft). Both endpoints already exist server-side.
  private func setStatus(publish: Bool) {
    let path = publish ? "/api/agents/{agent_id}/publish" : "/api/agents/{agent_id}"
    guard let url = apiRequestURL(path: path) else {
      onToast?("Missing API session")
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = publish ? "POST" : "PUT"
    apiHeaders(&request)
    if !publish {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try? JSONSerialization.data(withJSONObject: ["status": "draft"])
    }

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
      [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else { return }

        if let error {
          NSLog("[ChatNativeAgentConfig] set status failed %@", error.localizedDescription)
          self.onToast?(publish ? "Could not publish agent" : "Could not revert agent")
          return
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let payload = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        guard (200..<300).contains(statusCode) else {
          // Publish refuses on missing prompt / output modes / voice support.
          // Show the server reason so the fix is obvious instead of a retry.
          let serverMessage = chatNativeAgentNormalizedString(payload?["error"])
          self.onToast?(
            serverMessage ?? (publish ? "Could not publish agent" : "Could not revert agent"))
          return
        }

        let resolvedStatus =
          chatNativeAgentNormalizedString(payload?["status"])
          ?? (publish ? "published" : "draft")

        self.updateCard(status: resolvedStatus)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        self.onToast?(publish ? "Published agent" : "Reverted to draft")
      }
    }
    task.resume()
  }


  private func renameAgent(to proposedName: String, completion: @escaping (Bool) -> Void) {
    let normalizedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else {
      onToast?("Name cannot be empty")
      completion(false)
      return
    }
    guard normalizedName != card.displayName else {
      completion(true)
      return
    }
    guard let url = apiRequestURL(path: "/api/agents/{agent_id}") else {
      onToast?("Missing API session")
      completion(false)
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    apiHeaders(&request)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["display_name": normalizedName])

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
      [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else {
          completion(false)
          return
        }

        if let error {
          NSLog("[ChatNativeAgentConfig] rename agent failed %@", error.localizedDescription)
          self.onToast?("Could not rename agent")
          completion(false)
          return
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode), let data else {
          self.onToast?("Could not rename agent")
          completion(false)
          return
        }

        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let updatedName =
          chatNativeAgentNormalizedString(payload?["displayName"])
          ?? chatNativeAgentNormalizedString(payload?["display_name"])
          ?? normalizedName

        self.updateCard(displayName: updatedName)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        self.onToast?("Renamed agent")
        completion(true)
      }
    }

    task.resume()
  }

  private func saveSystemPrompt(_ proposedPrompt: String, completion: @escaping (Bool) -> Void) {
    let normalizedPrompt = proposedPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedPrompt.isEmpty else {
      onToast?("Prompt cannot be empty")
      completion(false)
      return
    }
    guard normalizedPrompt != (card.systemPrompt ?? "").trimmingCharacters(in: .whitespacesAndNewlines) else {
      onToast?("Prompt unchanged")
      completion(true)
      return
    }
    guard let url = apiRequestURL(path: "/api/agents/{agent_id}") else {
      onToast?("Missing API session")
      completion(false)
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    apiHeaders(&request)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["system_prompt": normalizedPrompt])

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
      [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else {
          completion(false)
          return
        }

        if let error {
          NSLog("[ChatNativeAgentConfig] update prompt failed %@", error.localizedDescription)
          self.onToast?("Could not update prompt")
          completion(false)
          return
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode), let data else {
          self.onToast?("Could not update prompt")
          completion(false)
          return
        }

        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let updatedPrompt =
          chatNativeAgentNormalizedString(payload?["systemPrompt"])
          ?? chatNativeAgentNormalizedString(payload?["system_prompt"])
          ?? normalizedPrompt

        self.updateCard(
          promptStatus: "Custom",
          promptPreview: chatNativeAgentPromptPreview(updatedPrompt),
          systemPrompt: updatedPrompt
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        self.onToast?("Updated prompt")
        completion(true)
      }
    }

    task.resume()
  }


  private func updateEventInboxMode(
    mode: String,
    schedule: String,
    summaryWindowHours: Int,
    summaryTimes: [String],
    completion: @escaping (Bool) -> Void
  ) {
    let normalizedMode = chatNativeAgentNormalizeEventInboxMode(mode)
    let normalizedHours = chatNativeAgentNormalizeSummaryWindowHours(summaryWindowHours)
    let normalizedSchedule = schedule.lowercased() == "daily" ? "daily" : "interval"

    guard let url = apiRequestURL(path: "/api/agents/{agent_id}") else {
      onToast?("Missing API session")
      completion(false)
      return
    }

    var eventInbox: [String: Any] = [
      "mode": normalizedMode,
      "summary_window_hours": normalizedHours,
      "summary_schedule": normalizedSchedule,
    ]
    if normalizedSchedule == "daily" {
      eventInbox["summary_times"] = summaryTimes
    }

    let payload: [String: Any] = [
      "approval_rules": [
        "event_inbox": eventInbox,
        "chat_input": [
          "enabled": card.incomingChatEnabled
        ],
      ]
    ]

    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    apiHeaders(&request)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
      [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else { return }

        if let error {
          NSLog("[ChatNativeAgentConfig] update inbox mode failed %@", error.localizedDescription)
          self.onToast?("Could not update inbox mode")
          completion(false)
          return
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode), let data else {
          self.onToast?("Could not update inbox mode")
          completion(false)
          return
        }

        let responsePayload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let approvalRules =
          (responsePayload?["approvalRules"] as? [String: Any])
          ?? (responsePayload?["approval_rules"] as? [String: Any])
        let eventInboxResponse =
          (approvalRules?["event_inbox"] as? [String: Any])
          ?? (approvalRules?["eventInbox"] as? [String: Any])

        let resolvedMode =
          chatNativeAgentNormalizeEventInboxMode(
            chatNativeAgentNormalizedString(eventInboxResponse?["mode"])
              ?? chatNativeAgentNormalizedString(eventInboxResponse?["event_inbox_mode"])
              ?? normalizedMode
          )
        let resolvedHours =
          chatNativeAgentNormalizeSummaryWindowHours(
            chatNativeAgentInteger(eventInboxResponse?["summary_window_hours"])
              ?? chatNativeAgentInteger(eventInboxResponse?["summaryWindowHours"])
              ?? chatNativeAgentInteger(eventInboxResponse?["cadence"])
              ?? normalizedHours
          )
        let resolvedSchedule =
          (chatNativeAgentNormalizedString(eventInboxResponse?["summary_schedule"])?.lowercased()
            == "daily") ? "daily" : normalizedSchedule
        let resolvedTimes =
          ((eventInboxResponse?["summary_times"] as? [Any])
            ?? (eventInboxResponse?["summaryTimes"] as? [Any]))?
          .compactMap { chatNativeAgentNormalizedString($0) } ?? summaryTimes
        let chatInput =
          (approvalRules?["chat_input"] as? [String: Any])
          ?? (approvalRules?["chatInput"] as? [String: Any])
        let resolvedIncomingChat =
          chatNativeAgentBoolean(chatInput?["enabled"])
          ?? self.card.incomingChatEnabled

        self.updateCard(
          eventInboxMode: resolvedMode,
          summaryWindowHours: resolvedHours,
          summarySchedule: resolvedSchedule,
          summaryTimes: resolvedTimes,
          incomingChatEnabled: resolvedIncomingChat
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        self.onToast?("Updated inbox mode")
        completion(true)
      }
    }

    task.resume()
  }

  // MARK: - Profile avatar

  private func presentAvatarPicker() {
    let sheet = UIAlertController(title: "Agent Photo", message: nil, preferredStyle: .actionSheet)
    sheet.addAction(UIAlertAction(title: "Choose from Library", style: .default) { [weak self] _ in
      self?.presentPhotoLibrary()
    })
    if UIImagePickerController.isSourceTypeAvailable(.camera) {
      sheet.addAction(UIAlertAction(title: "Take Photo", style: .default) { [weak self] _ in
        self?.presentCamera()
      })
    }
    if let avatar = card.avatarUrl, !avatar.isEmpty {
      sheet.addAction(UIAlertAction(title: "Remove Photo", style: .destructive) { [weak self] _ in
        self?.saveAvatarUrl("", successToast: "Removed photo")
      })
    }
    sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    if let popover = sheet.popoverPresentationController {
      popover.sourceView = view
      popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
      popover.permittedArrowDirections = []
    }
    present(sheet, animated: true)
  }

  private func presentPhotoLibrary() {
    var config = PHPickerConfiguration()
    config.filter = .images
    config.selectionLimit = 1
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    present(picker, animated: true)
  }

  private func presentCamera() {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.allowsEditing = true
    picker.delegate = self
    present(picker, animated: true)
  }

  private func handlePickedAvatar(_ image: UIImage) {
    onToast?("Uploading photo…")
    uploadAvatarImage(image) { [weak self] urlString in
      guard let self else { return }
      guard let urlString else {
        self.onToast?("Could not upload photo")
        return
      }
      self.saveAvatarUrl(urlString, successToast: "Updated photo")
    }
  }

  /// Uploads a downscaled JPEG to /api/media/upload and returns the public URL.
  private func uploadAvatarImage(_ image: UIImage, completion: @escaping (String?) -> Void) {
    guard let url = apiRequestURL(path: "/api/media/upload") else {
      completion(nil)
      return
    }
    let scaled = chatNativeAgentDownscale(image, maxDimension: 1024)
    guard let data = scaled.jpegData(compressionQuality: 0.85) else {
      completion(nil)
      return
    }

    let boundary = "----VibeAgentAvatar\(UUID().uuidString)"
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    apiHeaders(&request)
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var body = Data()
    func appendField(_ name: String, _ value: String) {
      body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
      body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8) ?? Data())
      body.append("\(value)\r\n".data(using: .utf8) ?? Data())
    }
    appendField("type", "image")
    if let agentUserId = card.agentUserId { appendField("user_id", agentUserId) }
    body.append("--\(boundary)\r\n".data(using: .utf8) ?? Data())
    body.append(
      "Content-Disposition: form-data; name=\"file\"; filename=\"agent-avatar.jpg\"\r\n".data(using: .utf8) ?? Data())
    body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8) ?? Data())
    body.append(data)
    body.append("\r\n".data(using: .utf8) ?? Data())
    body.append("--\(boundary)--\r\n".data(using: .utf8) ?? Data())
    request.httpBody = body

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) { data, response, error in
      DispatchQueue.main.async {
        guard
          error == nil,
          let data,
          (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
          let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let urlString = chatNativeAgentNormalizedString(payload["url"] ?? payload["public_url"])
        else {
          completion(nil)
          return
        }
        completion(urlString)
      }
    }
    task.resume()
  }

  private func saveAvatarUrl(_ urlString: String, successToast: String) {
    guard let url = apiRequestURL(path: "/api/agents/{agent_id}") else {
      onToast?("Missing API session")
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    apiHeaders(&request)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["avatar_url": urlString])

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) { [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else { return }
        guard
          error == nil,
          (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
        else {
          self.onToast?("Could not update photo")
          return
        }
        let payload = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let resolved =
          chatNativeAgentNormalizedString(payload?["avatarUrl"] ?? payload?["avatar_url"])
          ?? (urlString.isEmpty ? nil : urlString)
        self.updateCard(avatarUrl: resolved ?? "")
        self.card = self.cardWithAvatar(resolved)
        self.viewModel?.card = self.card
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        self.onToast?(successToast)
      }
    }
    task.resume()
  }

  /// Rebuilds the card with an explicit avatar value (including nil to clear),
  /// since updateCard's optional-coalescing can't represent "set to nil".
  private func cardWithAvatar(_ avatarUrl: String?) -> ChatListRow.AgentCard {
    let c = card
    return ChatListRow.AgentCard(
      id: c.id, style: c.style, agentId: c.agentId, agentUserId: c.agentUserId,
      displayName: c.displayName, username: c.username, identifier: c.identifier,
      avatarUrl: avatarUrl, status: c.status, promptStatus: c.promptStatus,
      promptPreview: c.promptPreview, systemPrompt: c.systemPrompt,
      modelProvider: c.modelProvider, modelId: c.modelId, enabledTools: c.enabledTools,
      outputModes: c.outputModes, voiceProfile: c.voiceProfile, voiceProvider: c.voiceProvider,
      callbackURL: c.callbackURL,
      apiBaseURL: c.apiBaseURL, invokeURL: c.invokeURL, eventsURL: c.eventsURL,
      builderLink: c.builderLink, agentDMURL: c.agentDMURL, secretHint: c.secretHint,
      latestSecret: c.latestSecret, defaultDestinationChat: c.defaultDestinationChat,
      attachedChats: c.attachedChats, eventInboxMode: c.eventInboxMode,
      summaryWindowHours: c.summaryWindowHours, summarySchedule: c.summarySchedule,
      summaryTimes: c.summaryTimes, incomingChatEnabled: c.incomingChatEnabled,
      canDelete: c.canDelete)
  }

  // MARK: - Handle availability + save

  private func checkUsernameAvailability(
    _ username: String,
    completion: @escaping (Bool, String?) -> Void
  ) {
    guard
      let base = apiRequestURL(path: "/api/agents/username_available"),
      var components = URLComponents(url: base, resolvingAgainstBaseURL: true)
    else {
      completion(false, "unavailable")
      return
    }
    components.queryItems = [
      URLQueryItem(name: "username", value: username),
      URLQueryItem(name: "agent_id", value: card.agentId),
    ]
    guard let url = components.url else {
      completion(false, "unavailable")
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    apiHeaders(&request)

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) { data, response, error in
      DispatchQueue.main.async {
        guard
          error == nil,
          (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
          let data,
          let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
          completion(false, "unavailable")
          return
        }
        let available = (payload["available"] as? Bool) ?? false
        let reason = chatNativeAgentNormalizedString(payload["reason"])
        completion(available, reason)
      }
    }
    task.resume()
  }

  private func saveUsername(
    _ username: String,
    completion: @escaping (Bool, String?) -> Void
  ) {
    guard let url = apiRequestURL(path: "/api/agents/{agent_id}") else {
      completion(false, "Missing API session")
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    apiHeaders(&request)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["username": username])

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) { [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else { return }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        let payload = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }

        guard error == nil, (200..<300).contains(statusCode) else {
          // Server reports e.g. {"error": ":username_taken"} on 422.
          let raw = chatNativeAgentNormalizedString(payload?["error"]) ?? "unavailable"
          completion(false, raw.trimmingCharacters(in: CharacterSet(charactersIn: ":")))
          return
        }
        let resolved =
          chatNativeAgentNormalizedString(payload?["username"]) ?? username
        self.updateCard(username: resolved)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        self.onToast?("Updated handle")
        completion(true, nil)
      }
    }
    task.resume()
  }

  // MARK: - Tools

  private func loadToolRegistry(completion: @escaping ([ChatAgentToolInfo]) -> Void) {
    // The catalog is global (not per-agent) and effectively static for the app
    // session — share one fetch across every agent's config screen instead of
    // re-hitting the network (and flashing a spinner) every time Tools opens.
    if let cached = ChatAgentToolRegistryCache.tools {
      completion(cached)
      return
    }
    ChatAgentToolRegistryCache.pending.append(completion)
    guard ChatAgentToolRegistryCache.pending.count == 1 else { return }

    guard let url = apiRequestURL(path: "/api/agents/tool_registry") else {
      ChatAgentToolRegistryCache.resolvePending(with: [])
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    apiHeaders(&request)

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) { data, response, error in
      DispatchQueue.main.async {
        guard
          error == nil,
          (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
          let data,
          let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let items = payload["items"] as? [[String: Any]]
        else {
          ChatAgentToolRegistryCache.resolvePending(with: [])
          return
        }
        let tools: [ChatAgentToolInfo] = items.compactMap { item in
          guard let id = chatNativeAgentNormalizedString(item["id"]) else { return nil }
          return ChatAgentToolInfo(
            id: id,
            name: chatNativeAgentNormalizedString(item["name"]) ?? id,
            description: chatNativeAgentNormalizedString(item["description"]) ?? "")
        }
        ChatAgentToolRegistryCache.tools = tools
        ChatAgentToolRegistryCache.resolvePending(with: tools)
      }
    }
    task.resume()
  }

  private func saveTools(_ tools: [String], completion: @escaping (Bool) -> Void) {
    guard let url = apiRequestURL(path: "/api/agents/{agent_id}") else {
      onToast?("Missing API session")
      completion(false)
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    apiHeaders(&request)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["enabled_tools": tools])

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) { [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else { return }
        guard
          error == nil,
          (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
        else {
          self.onToast?("Could not update tools")
          completion(false)
          return
        }
        let payload = data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let resolved =
          (payload?["enabledTools"] as? [Any] ?? payload?["enabled_tools"] as? [Any])?
          .compactMap { chatNativeAgentNormalizedString($0) } ?? tools
        self.updateCard(enabledTools: resolved)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        self.onToast?("Updated tools")
        completion(true)
      }
    }
    task.resume()
  }

  // MARK: - Model registry

  private func loadModelRegistry(completion: @escaping (ChatAgentModelRegistry) -> Void) {
    guard let apiContext else {
      completion(.fallback)
      return
    }
    ChatAgentModelRegistryService.load(
      apiBaseURL: apiContext.apiBaseURL,
      token: apiContext.token,
      completion: completion
    )
  }

  private func saveVoiceProvider(_ provider: String, completion: @escaping (Bool) -> Void) {
    guard let url = apiRequestURL(path: "/api/agents/{agent_id}") else {
      onToast?("Missing API session")
      completion(false)
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    apiHeaders(&request)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["voice_provider": provider])

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
      [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else {
          completion(false)
          return
        }
        guard
          error == nil,
          (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
        else {
          self.onToast?("Could not update voice provider")
          completion(false)
          return
        }
        self.updateCard(voiceProvider: provider)
        self.onToast?("Updated voice provider")
        completion(true)
      }
    }
    task.resume()
  }

  private func saveModelSelection(
    provider: String,
    modelId: String,
    completion: @escaping (Bool) -> Void
  ) {
    guard let url = apiRequestURL(path: "/api/agents/{agent_id}") else {
      onToast?("Missing API session")
      completion(false)
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    apiHeaders(&request)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(
      withJSONObject: [
        "model_provider": provider,
        "model_id": modelId,
      ])

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
      [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else {
          completion(false)
          return
        }
        guard
          error == nil,
          (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
          let data,
          let responsePayload =
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
          self.onToast?("Could not update model")
          completion(false)
          return
        }

        let agentPayload =
          (responsePayload["agent"] as? [String: Any])
          ?? responsePayload
        let resolvedProvider =
          chatNativeAgentNormalizedString(
            agentPayload["modelProvider"] ?? agentPayload["model_provider"])
          ?? provider
        let resolvedModelId =
          chatNativeAgentNormalizedString(
            agentPayload["modelId"] ?? agentPayload["model_id"])
          ?? modelId

        self.updateCard(modelProvider: resolvedProvider, modelId: resolvedModelId)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        self.onToast?("Updated model")
        completion(true)
      }
    }
    task.resume()
  }

  private func loadPromptVariables(completion: @escaping ([ChatAgentPromptVariable]) -> Void) {
    guard let url = apiRequestURL(path: "/api/agents/{agent_id}") else {
      completion([])
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    apiHeaders(&request)

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) { data, response, error in
      DispatchQueue.main.async {
        guard
          error == nil,
          (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
          let data,
          let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
          completion([])
          return
        }
        let items =
          (payload["promptVariables"] as? [[String: Any]])
          ?? (payload["prompt_variables"] as? [[String: Any]])
          ?? []
        let variables: [ChatAgentPromptVariable] = items.compactMap { item in
          guard let name = chatNativeAgentNormalizedString(item["name"]) else { return nil }
          return ChatAgentPromptVariable(
            name: name,
            description: chatNativeAgentNormalizedString(item["description"]) ?? "",
            value: (item["value"] as? String) ?? "",
            locked: (item["locked"] as? Bool) ?? false)
        }
        completion(variables)
      }
    }
    task.resume()
  }

  private func savePromptVariables(
    _ variables: [ChatAgentPromptVariable], completion: @escaping (Bool) -> Void
  ) {
    guard let url = apiRequestURL(path: "/api/agents/{agent_id}") else {
      onToast?("Missing API session")
      completion(false)
      return
    }
    // Send every variable so descriptions are preserved. Locked variables are
    // resolved from code at render time on the server, so persisting their
    // displayed value is harmless.
    let payloadVars = variables.map {
      ["name": $0.name, "description": $0.description, "value": $0.value]
    }
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    apiHeaders(&request)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["prompt_variables": payloadVars])

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) { [weak self] _, response, error in
      DispatchQueue.main.async {
        guard let self else { return }
        guard
          error == nil,
          (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
        else {
          self.onToast?("Could not update variables")
          completion(false)
          return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        self.onToast?("Updated prompt variables")
        completion(true)
      }
    }
    task.resume()
  }


  private func updateIncomingChatMode(enabled: Bool) {
    guard enabled != card.incomingChatEnabled else {
      onToast?("Incoming chat unchanged")
      return
    }

    guard let url = apiRequestURL(path: "/api/agents/{agent_id}") else {
      onToast?("Missing API session")
      return
    }

    let payload: [String: Any] = [
      "approval_rules": [
        "event_inbox": [
          "mode": card.eventInboxMode,
          "summary_window_hours": card.summaryWindowHours,
        ],
        "chat_input": [
          "enabled": enabled
        ],
      ]
    ]

    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    apiHeaders(&request)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
      [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else { return }

        if let error {
          NSLog("[ChatNativeAgentConfig] update incoming chat failed %@", error.localizedDescription)
          self.onToast?("Could not update incoming chat")
          return
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(statusCode), let data else {
          self.onToast?("Could not update incoming chat")
          return
        }

        let responsePayload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let approvalRules =
          (responsePayload?["approvalRules"] as? [String: Any])
          ?? (responsePayload?["approval_rules"] as? [String: Any])
        let chatInput =
          (approvalRules?["chat_input"] as? [String: Any])
          ?? (approvalRules?["chatInput"] as? [String: Any])
        let eventInbox =
          (approvalRules?["event_inbox"] as? [String: Any])
          ?? (approvalRules?["eventInbox"] as? [String: Any])

        let resolvedMode =
          chatNativeAgentNormalizeEventInboxMode(
            chatNativeAgentNormalizedString(eventInbox?["mode"])
              ?? chatNativeAgentNormalizedString(eventInbox?["event_inbox_mode"])
              ?? self.card.eventInboxMode
          )
        let resolvedHours =
          chatNativeAgentNormalizeSummaryWindowHours(
            chatNativeAgentInteger(eventInbox?["summary_window_hours"])
              ?? chatNativeAgentInteger(eventInbox?["summaryWindowHours"])
              ?? self.card.summaryWindowHours
          )
        let resolvedIncomingChat =
          chatNativeAgentBoolean(chatInput?["enabled"])
          ?? enabled

        self.updateCard(
          eventInboxMode: resolvedMode,
          summaryWindowHours: resolvedHours,
          incomingChatEnabled: resolvedIncomingChat
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        self.onToast?("Updated incoming chat")
      }
    }

    task.resume()
  }




  /// Mints a brand-new plaintext invoke secret (the old one stops working immediately).
  /// The old secret is hashed at rest and cannot be recovered — this is the ONLY moment
  /// a fresh one is ever visible, so the caller must show it before the user navigates away.
  private func rotateInvokeSecret(completion: @escaping (Bool, String?, String?) -> Void) {
    guard let url = apiRequestURL(path: "/api/agents/{agent_id}/secret/rotate") else {
      onToast?("Missing API session")
      completion(false, nil, nil)
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    apiHeaders(&request)

    activeSecretRequest?.cancel()
    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
      [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else {
          completion(false, nil, nil)
          return
        }

        if let error {
          NSLog("[ChatNativeAgentConfig] rotate secret failed %@", error.localizedDescription)
          self.onToast?("Could not rotate secret")
          completion(false, nil, nil)
          return
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard
          (200..<300).contains(statusCode),
          let data,
          let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let secret = chatNativeAgentNormalizedString(payload["secret"])
        else {
          let serverMessage = data.flatMap {
            (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])
              .flatMap { chatNativeAgentNormalizedString($0["error"]) }
          }
          self.onToast?(serverMessage ?? "Could not rotate secret")
          completion(false, nil, nil)
          return
        }

        let agentPayload = payload["agent"] as? [String: Any]
        let hint =
          chatNativeAgentNormalizedString(agentPayload?["secretHint"] ?? agentPayload?["secret_hint"])
          ?? String(secret.suffix(4))

        self.updateCard(secret: secret, secretHint: hint)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        self.onToast?("New secret ready — copy it now")
        completion(true, secret, hint)
      }
    }
    activeSecretRequest = task
    task.resume()
  }

  /// The webhook signing secret is a SEPARATE, reversibly-stored secret (used to verify
  /// inbound webhook signatures) — unlike the invoke secret above, it can be fetched again
  /// anytime, so this is a plain GET rather than a mint-once rotate.
  private func loadWebhookSecret(completion: @escaping (String?, String?) -> Void) {
    guard let url = apiRequestURL(path: "/api/agents/{agent_id}/secret") else {
      onToast?("Missing API session")
      completion(nil, nil)
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    apiHeaders(&request)

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request) {
      [weak self] data, response, error in
      DispatchQueue.main.async {
        guard let self else {
          completion(nil, nil)
          return
        }

        guard
          error == nil,
          let http = response as? HTTPURLResponse,
          (200..<300).contains(http.statusCode),
          let data,
          let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let secret = chatNativeAgentNormalizedString(payload["secret"])
        else {
          self.onToast?("Could not load webhook secret")
          completion(nil, nil)
          return
        }

        let hint = chatNativeAgentNormalizedString(payload["secretHint"] ?? payload["secret_hint"])
        completion(secret, hint)
      }
    }
    task.resume()
  }

  @objc private func handleClose() {
    dismiss(animated: true)
  }

  @objc private func handleOpenChat() {
    let action = onOpenAgentChat
    let selectedCard = card
    dismiss(animated: true) {
      action?(selectedCard)
    }
  }


  private func closeAfterDelete() {
    if navigationController?.viewControllers.first === self {
      dismiss(animated: true)
    } else {
      navigationController?.popViewController(animated: true)
    }
  }
}

// MARK: - Avatar picker delegates

extension ChatNativeAgentConfigPanelController: PHPickerViewControllerDelegate {
  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard
      let provider = results.first?.itemProvider,
      provider.canLoadObject(ofClass: UIImage.self)
    else { return }
    provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
      guard let image = object as? UIImage else { return }
      DispatchQueue.main.async {
        self?.handlePickedAvatar(image)
      }
    }
  }
}

extension ChatNativeAgentConfigPanelController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  func imagePickerController(
    _ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
  ) {
    picker.dismiss(animated: true)
    let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
    if let image { handlePickedAvatar(image) }
  }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
    picker.dismiss(animated: true)
  }
}

/// Downscales an image so its largest dimension is at most `maxDimension`,
/// preserving aspect ratio. Returns the original if already small enough.
func chatNativeAgentDownscale(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
  let size = image.size
  let longest = max(size.width, size.height)
  guard longest > maxDimension, longest > 0 else { return image }
  let scale = maxDimension / longest
  let target = CGSize(width: size.width * scale, height: size.height * scale)
  let format = UIGraphicsImageRendererFormat.default()
  format.scale = 1
  let renderer = UIGraphicsImageRenderer(size: target, format: format)
  return renderer.image { _ in
    image.draw(in: CGRect(origin: .zero, size: target))
  }
}
