import UIKit

/// Structured service-message node from `message.metadata.service`.
/// Discriminated by `kind` so the transcript can centre join/leave/decision
/// notices without sniffing body prose.
struct ChatServiceMessage: Equatable {
  let kind: String
  let text: String
  let status: String
  let templateKey: String?
  let templateArgs: [String: String]
  let actions: [ChatServiceAction]
  let chosenActionId: String?
  let chosenActionLabel: String?
  let chosenByName: String?
  /// Second plain part of a decision node — the exact command / URL / path.
  let detailText: String?
  /// Risk class carried in the decision node, so a cold open still shows the chip.
  let risk: String?

  var hasLiveActions: Bool {
    status == "pending" && !actions.isEmpty
  }

  /// Client-composed display string from structured parts when we know the
  /// template key; otherwise the server-composed `text` fallback.
  var displayText: String {
    if let key = templateKey {
      switch key {
      case "membership.added":
        let actor = templateArgs["actorName"] ?? "Someone"
        let target = templateArgs["targetName"] ?? "someone"
        return "\(actor) added \(target)"
      case "membership.joined":
        let target = templateArgs["targetName"] ?? "Someone"
        return "\(target) joined the group"
      case "membership.removed":
        let actor = templateArgs["actorName"] ?? "Someone"
        let target = templateArgs["targetName"] ?? "someone"
        return "\(actor) removed \(target)"
      case "membership.left":
        let target = templateArgs["targetName"] ?? "Someone"
        return "\(target) left the group"
      case "decision.chosen", "decision.partial":
        let label = chosenActionLabel ?? templateArgs["actionLabel"] ?? "Done"
        let actor = chosenByName ?? templateArgs["actorName"] ?? "Someone"
        return "\(label) · \(actor)"
      case "decision.expired":
        return "Decision expired"
      case "secure.waiting":
        let target = templateArgs["targetName"] ?? "them"
        return "Waiting for \(target) to join"
      case "secure.joined":
        return "Joined"
      default:
        break
      }
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? " " : trimmed
  }

  static func parse(_ raw: Any?) -> ChatServiceMessage? {
    guard let map = raw as? [String: Any] else { return nil }
    let kind = (map["kind"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !kind.isEmpty else { return nil }

    let text = (map["text"] as? String) ?? ""
    let status = (map["status"] as? String) ?? "active"

    var templateKey: String?
    var templateArgs: [String: String] = [:]
    var plainParts: [String] = []
    if let parts = map["parts"] as? [[String: Any]] {
      for part in parts {
        if (part["type"] as? String) == "plain", let value = part["value"] as? String,
          !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
          plainParts.append(value)
        }
        let type = (part["type"] as? String) ?? ""
        if type == "template", let key = part["key"] as? String, !key.isEmpty {
          templateKey = key
          if let args = part["args"] as? [String: Any] {
            for (k, v) in args {
              if let s = v as? String {
                templateArgs[k] = s
              } else if let n = v as? NSNumber {
                templateArgs[k] = n.stringValue
              }
            }
          }
          break
        }
      }
    }

    let decision = map["decision"] as? [String: Any]
    var actions: [ChatServiceAction] = []
    if let rawActions = decision?["actions"] as? [[String: Any]] {
      actions = rawActions.compactMap(ChatServiceAction.parse)
    }

    let chosen = decision?["chosen"] as? [String: Any]
    let chosenActionId = chosen?["actionId"] as? String
    let chosenActionLabel = chosen?["actionLabel"] as? String
    let chosenByName = chosen?["byName"] as? String

    return ChatServiceMessage(
      kind: kind,
      text: text,
      status: status,
      templateKey: templateKey,
      templateArgs: templateArgs,
      actions: actions,
      chosenActionId: chosenActionId,
      chosenActionLabel: chosenActionLabel,
      chosenByName: chosenByName,
      detailText: plainParts.count > 1 ? plainParts[1] : nil,
      risk: decision?["risk"] as? String
    )
  }
}

struct ChatServiceAction: Equatable {
  let id: String
  let label: String
  let style: String
  let token: String
  let confirm: String?

  static func parse(_ raw: [String: Any]) -> ChatServiceAction? {
    let id = (raw["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let label = (raw["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let token = (raw["token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !id.isEmpty, !label.isEmpty, !token.isEmpty else { return nil }
    let style = (raw["style"] as? String) ?? "secondary"
    let confirm = (raw["confirm"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return ChatServiceAction(
      id: id,
      label: label,
      style: style,
      token: token,
      confirm: (confirm?.isEmpty == false) ? confirm : nil
    )
  }
}

enum ChatServiceDecisionClient {
  /// POST `/api/decisions/actions` with the opaque action token.
  static func claim(token: String, completion: @escaping (Result<Void, Error>) -> Void) {
    guard let config = AppSessionConfig.current else {
      completion(.failure(NSError(domain: "ChatServiceDecision", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Not signed in",
      ])))
      return
    }

    var base = config.apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    if base.hasSuffix("/") { base = String(base.dropLast()) }
    guard let url = URL(string: base + "/api/decisions/actions") else {
      completion(.failure(NSError(domain: "ChatServiceDecision", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "Invalid API URL",
      ])))
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])

    VibeHTTP.shared.dataTask(with: request) { data, response, error in
      if let error {
        DispatchQueue.main.async { completion(.failure(error)) }
        return
      }
      let status = (response as? HTTPURLResponse)?.statusCode ?? 0
      if (200...299).contains(status) {
        DispatchQueue.main.async { completion(.success(())) }
        return
      }
      let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
      let code = status == 409 ? 409 : status
      DispatchQueue.main.async {
        completion(
          .failure(
            NSError(
              domain: "ChatServiceDecision",
              code: code,
              userInfo: [NSLocalizedDescriptionKey: body.isEmpty ? "Request failed" : body]
            )
          )
        )
      }
    }.resume()
  }
}

/// Horizontal row of decision action chips under a centred service notice.
final class ChatServiceActionBarView: UIView {
  var onAction: ((ChatServiceAction) -> Void)?

  private var buttons: [UIButton] = []
  private var actions: [ChatServiceAction] = []
  private let spacing: CGFloat = 8
  private let buttonHeight: CGFloat = 32

  func configure(actions: [ChatServiceAction], appearance: ChatListAppearance) {
    self.actions = actions
    buttons.forEach { $0.removeFromSuperview() }
    buttons = []

    for (index, action) in actions.enumerated() {
      let button = UIButton(type: .system)
      var config = UIButton.Configuration.filled()
      config.title = action.label
      config.cornerStyle = .capsule
      config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
      config.baseForegroundColor = foregroundColor(for: action.style, appearance: appearance)
      config.baseBackgroundColor = backgroundColor(for: action.style, appearance: appearance)
      config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
        var outgoing = incoming
        outgoing.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        return outgoing
      }
      button.configuration = config
      button.tag = index
      button.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
      addSubview(button)
      buttons.append(button)
    }
    isHidden = actions.isEmpty
    setNeedsLayout()
  }

  func preferredHeight(for width: CGFloat) -> CGFloat {
    guard !actions.isEmpty else { return 0 }
    return buttonHeight + 8
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    guard !buttons.isEmpty else { return }

    let sizes = buttons.map { button -> CGSize in
      let fit = button.sizeThatFits(CGSize(width: bounds.width, height: buttonHeight))
      return CGSize(width: max(64, ceil(fit.width)), height: buttonHeight)
    }
    let totalWidth = sizes.reduce(CGFloat(0)) { $0 + $1.width } + spacing * CGFloat(max(0, sizes.count - 1))
    var x = max(0, (bounds.width - totalWidth) * 0.5)
    let y = max(0, (bounds.height - buttonHeight) * 0.5)
    for (i, button) in buttons.enumerated() {
      let size = sizes[i]
      button.frame = CGRect(x: floor(x), y: floor(y), width: size.width, height: size.height)
      x += size.width + spacing
    }
  }

  @objc private func tapped(_ sender: UIButton) {
    let index = sender.tag
    guard actions.indices.contains(index) else { return }
    onAction?(actions[index])
  }

  private func foregroundColor(for style: String, appearance: ChatListAppearance) -> UIColor {
    switch style {
    case "primary":
      return .white
    case "destructive":
      return .white
    default:
      return appearance.timeColorThem
    }
  }

  private func backgroundColor(for style: String, appearance: ChatListAppearance) -> UIColor {
    switch style {
    case "primary":
      return appearance.bubbleMeGradient.first ?? appearance.accent
    case "destructive":
      return UIColor.systemRed
    default:
      return appearance.timeColorThem.withAlphaComponent(0.12)
    }
  }
}

/// Approval-card extras between the decision pill and its action bar: a risk chip and
/// the exact command / URL in a selectable monospaced block. Fixed height by design.
final class ChatServiceDecisionCardView: UIView {
  static let chipHeight: CGFloat = 20.0
  static let detailHeight: CGFloat = 54.0
  static let gap: CGFloat = 6.0

  private let riskChip = UILabel()
  private let detailView = UITextView()

  static func height(risk: String?, detail: String?) -> CGFloat {
    var total: CGFloat = 0
    if risk != nil { total += chipHeight + gap }
    if detail != nil { total += detailHeight + gap }
    return total
  }

  static func riskLabel(_ risk: String) -> String {
    switch risk.lowercased() {
    case "external_effect": return "External effect"
    case "credential": return "Credentials"
    case "write_local": return "Writes files"
    case "read": return "Read only"
    default: return risk.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    riskChip.font = .systemFont(ofSize: 11, weight: .semibold)
    riskChip.textAlignment = .center
    riskChip.layer.cornerRadius = ChatServiceDecisionCardView.chipHeight / 2.0
    riskChip.clipsToBounds = true
    addSubview(riskChip)

    detailView.isEditable = false
    detailView.isSelectable = true
    detailView.isScrollEnabled = true
    detailView.alwaysBounceVertical = false
    detailView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    detailView.textContainerInset = UIEdgeInsets(top: 7, left: 8, bottom: 7, right: 8)
    detailView.layer.cornerRadius = 8
    detailView.clipsToBounds = true
    addSubview(detailView)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(risk: String?, detail: String?, appearance: ChatListAppearance) {
    let warning = ["external_effect", "credential"].contains((risk ?? "").lowercased())
    riskChip.isHidden = risk == nil
    if let risk {
      let tint = warning ? UIColor.systemOrange : appearance.dayTextColor
      riskChip.text = Self.riskLabel(risk)
      riskChip.textColor = tint
      riskChip.backgroundColor = tint.withAlphaComponent(0.16)
    }
    detailView.isHidden = detail == nil
    detailView.text = detail ?? ""
    detailView.textColor = appearance.dayTextColor
    detailView.backgroundColor = appearance.dayBackgroundColor
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    var y: CGFloat = 0
    if riskChip.isHidden {
      riskChip.frame = .zero
    } else {
      let fit = riskChip.sizeThatFits(CGSize(width: bounds.width, height: Self.chipHeight))
      let width = min(bounds.width, ceil(fit.width) + 20.0)
      riskChip.frame = CGRect(
        x: floor((bounds.width - width) * 0.5), y: y, width: width, height: Self.chipHeight)
      y += Self.chipHeight + Self.gap
    }
    detailView.frame =
      detailView.isHidden
      ? .zero : CGRect(x: 0, y: y, width: bounds.width, height: Self.detailHeight)
  }
}
