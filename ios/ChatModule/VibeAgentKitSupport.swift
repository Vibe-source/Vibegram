import Foundation
import UIKit
import SwiftUI

enum VibeAgentKitChatRole: String {
  case user
  case assistant
  case agent

  var isUser: Bool {
    self == .user
  }
}

enum VibeAgentKitMessageAction {
  case copy
  case thumbUp
  case thumbDown
  case regenerate
}

struct VibeAgentKitChatAppearance {
  let isDark: Bool
  let background: UIColor
  let surface: UIColor
  let surfaceElevated: UIColor
  let text: UIColor
  let textSecondary: UIColor
  let textTertiary: UIColor
  let border: UIColor
  let primary: UIColor
  let userBubbleBackground: UIColor
  let userBubbleText: UIColor
  let userBubbleBorder: UIColor

  static let fallback = VibeAgentKitChatAppearance(
    isDark: true,
    background: UIColor.black,
    surface: UIColor(red: 0.1294, green: 0.1098, blue: 0.1020, alpha: 1.0),
    surfaceElevated: UIColor(red: 0.2118, green: 0.1725, blue: 0.1490, alpha: 1.0),
    text: UIColor(red: 0.9529, green: 0.9451, blue: 0.9294, alpha: 1.0),
    textSecondary: UIColor(red: 0.7137, green: 0.6980, blue: 0.6706, alpha: 1.0),
    textTertiary: UIColor(red: 0.5451, green: 0.5294, blue: 0.5020, alpha: 1.0),
    border: UIColor(red: 0.2667, green: 0.2118, blue: 0.1843, alpha: 1.0),
    primary: UIColor(red: 0.7608, green: 0.6078, blue: 0.4784, alpha: 1.0),
    // Neutral near-black — matches Resolo's dark-mode user bubble color (0.105, 0.105, 0.110)
    userBubbleBackground: UIColor(red: 0.105, green: 0.105, blue: 0.110, alpha: 1.0),
    userBubbleText: UIColor(red: 0.9529, green: 0.9451, blue: 0.9294, alpha: 1.0),
    userBubbleBorder: UIColor(red: 0.2667, green: 0.2118, blue: 0.1843, alpha: 1.0)
  )

  static let lightFallback = VibeAgentKitChatAppearance(
    isDark: false,
    background: UIColor(red: 0.9569, green: 0.9529, blue: 0.9412, alpha: 1.0),
    surface: UIColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
    surfaceElevated: UIColor(red: 0.9490, green: 0.9412, blue: 0.9294, alpha: 1.0),
    text: UIColor(red: 0.0627, green: 0.0627, blue: 0.0706, alpha: 1.0),
    textSecondary: UIColor(red: 0.5020, green: 0.4902, blue: 0.4784, alpha: 1.0),
    textTertiary: UIColor(red: 0.6980, green: 0.6784, blue: 0.6039, alpha: 1.0),
    border: UIColor(red: 0.9216, green: 0.9098, blue: 0.8902, alpha: 1.0),
    primary: UIColor(red: 0.9686, green: 0.5490, blue: 0.2706, alpha: 1.0),
    userBubbleBackground: UIColor(red: 0.9412, green: 0.9333, blue: 0.9176, alpha: 1.0),
    userBubbleText: UIColor(red: 0.0627, green: 0.0627, blue: 0.0706, alpha: 1.0),
    userBubbleBorder: .clear
  )
}

struct VibeAgentKitImageAttachment: Equatable {
  let id: String
  let name: String?
  let mime: String?
  let sourceURI: String?
  let dataBase64: String?
}

struct VibeAgentKitChatMessage: Equatable {
  var id: String
  var role: VibeAgentKitChatRole
  var text: String
  var timestamp: String
  var timestampMs: Int64
  var isStreaming: Bool
  var isError: Bool
  var hasInitialResponseText: Bool
  var hasFinalResponseText: Bool
  var initialResponseText: String?
  var progressStartedAt: String?
  var progressCompletedAt: String?
  var progress: [String]
  var progressItems: [VibeAgentKitProgressItem]
  /// Subagent (Claude Task tool) children grouped by their parent Task node id.
  /// `progressItems` only carries the depth-0 main feed (incl. the compact Task row);
  /// the subagent's own steps live here and render only in the read-only subagent view.
  var subagentChildren: [String: [VibeAgentKitProgressItem]]
  var sourceMessageId: String?
  var runtime: ChatListRow.AgentRuntimeSummary?
  var attachments: [VibeAgentKitImageAttachment]
  /// A /compact context-summary turn — renders as a centered, collapsible mid-chat
  /// divider ("Context compacted") rather than a left assistant bubble. `text` holds
  /// the raw summary that the divider reveals when expanded.
  var isCompactionSummary: Bool
  /// System status rows such as "[Request interrupted by user]" render as centered,
  /// muted dividers instead of assistant or user bubbles.
  var systemDividerText: String?

  init(
    id: String,
    role: VibeAgentKitChatRole,
    text: String,
    timestamp: String,
    timestampMs: Int64,
    isStreaming: Bool = false,
    isError: Bool = false,
    hasInitialResponseText: Bool = false,
    hasFinalResponseText: Bool = false,
    initialResponseText: String? = nil,
    progressStartedAt: String? = nil,
    progressCompletedAt: String? = nil,
    progress: [String] = [],
    progressItems: [VibeAgentKitProgressItem] = [],
    subagentChildren: [String: [VibeAgentKitProgressItem]] = [:],
    sourceMessageId: String? = nil,
    runtime: ChatListRow.AgentRuntimeSummary? = nil,
    attachments: [VibeAgentKitImageAttachment] = [],
    isCompactionSummary: Bool = false,
    systemDividerText: String? = nil
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.timestamp = timestamp
    self.timestampMs = timestampMs
    self.isStreaming = isStreaming
    self.isError = isError
    self.hasInitialResponseText = hasInitialResponseText
    self.hasFinalResponseText = hasFinalResponseText
    self.initialResponseText = initialResponseText
    self.progressStartedAt = progressStartedAt
    self.progressCompletedAt = progressCompletedAt
    self.progress = progress
    self.progressItems = progressItems
    self.subagentChildren = subagentChildren
    self.sourceMessageId = sourceMessageId
    self.runtime = runtime
    self.attachments = attachments
    self.isCompactionSummary = isCompactionSummary
    self.systemDividerText = systemDividerText
  }
}

struct VibeAgentKitProgressBadge: Equatable {
  let label: String?
  let query: String?
  let domain: String?
  let sublabel: String?
  let url: String?
  let image: String?

  static func from(raw: [String: Any]) -> VibeAgentKitProgressBadge? {
    let label = vibeAgentKitNormalizedString(raw["label"])
    let query = vibeAgentKitNormalizedString(raw["query"])
    let domain = vibeAgentKitNormalizedString(raw["domain"])
    let sublabel = vibeAgentKitNormalizedString(raw["sublabel"])
    let url = vibeAgentKitNormalizedString(raw["url"])
    let image = vibeAgentKitNormalizedString(raw["image"])
    guard
      label != nil || query != nil || domain != nil || sublabel != nil || url != nil || image != nil
    else {
      return nil
    }

    return VibeAgentKitProgressBadge(
      label: label,
      query: query,
      domain: domain,
      sublabel: sublabel,
      url: url,
      image: image
    )
  }

  var displayText: String {
    label ?? query ?? domain ?? sublabel ?? url ?? "Item"
  }
}

struct VibeAgentKitTodoItem: Equatable {
  let content: String
  let status: String
  let activeForm: String?
}

struct VibeAgentKitProgressItem: Equatable {
  let label: String
  let badges: [VibeAgentKitProgressBadge]
  let eventType: String
  let recipient: String?
  let platform: String?
  let format: String?
  let messageContent: String?
  let messagePreview: String?
  let voiceUrl: String?
  let voiceDuration: Double?
  let status: String?
  let isRecording: Bool
  let recordingStartTime: Double?
  let tool: String?
  let image: String?
  let itemType: String?
  let sourceUrl: String?
  // Per-node detail (full-page agent view step rows). Defaulted so the legacy
  // agent-stream constructor (`from(label:raw:)`) keeps compiling unchanged; the
  // bridge full-page path (`VibeAgentKitMap.progressItem`) populates them.
  // `nodeId` keys this row's inline expand state; `command`/`patch`/`fileContent`
  // are the decrypted expand-layer bodies; `lineStart`/`lineEnd` drive the read
  // preview's "(12–48)" range.
  var nodeId: String? = nil
  var command: String? = nil
  var patch: String? = nil
  var fileName: String? = nil
  var fileContent: String? = nil
  var lineStart: Int? = nil
  var lineEnd: Int? = nil
  // Subagent (Claude Task tool) grouping: a parent Task item carries `subagentType`
  // (e.g. "explore") and renders as a tappable "🤖 Subagent" row; its children carry
  // `parentId` and live only in the read-only subagent view.
  var parentId: String? = nil
  var subagentType: String? = nil
  // True only for a REAL Claude Task-tool subagent: task-kind nodes always carry
  // `subagentType` when they come from an actual Task tool call (bridge + server
  // both set it from the tool's subagent_type). A "task" node WITHOUT one is a
  // synthetic working placeholder (e.g. the bridge's running-task node) — rendering
  // those as "Subagent" rows painted phantom spinning Subagent cells in the chat.
  var isRealSubagent: Bool {
    guard (itemType ?? "") == "task" else { return false }
    return !(subagentType ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  // Thinking-node metrics: reasoning token count + how long the turn spent thinking,
  // so a "thinking" row can render "Thinking · N tokens" / "Thought for Ns".
  var tokens: Int? = nil
  var durationMs: Int? = nil
  var todos: [VibeAgentKitTodoItem]? = nil
  // Absolute epoch-ms the node started (server-stamped). A `teamworker` row uses it
  // to drive a live 1Hz elapsed clock ("Calling… · 0m 07s") from the spawn beat until
  // the worker settles; nil on old servers → the row falls back to its static status.
  var startedAtMs: Int64? = nil

  static func from(label: String, raw: [String: Any]?, eventType: String = "progress")
    -> VibeAgentKitProgressItem
  {
    let rawBadges = raw?["badges"] as? [[String: Any]] ?? []
    let badges = rawBadges.compactMap(VibeAgentKitProgressBadge.from(raw:))

    return VibeAgentKitProgressItem(
      label: label,
      badges: badges,
      eventType: vibeAgentKitNormalizedString(raw?["eventType"]) ?? eventType,
      recipient: vibeAgentKitNormalizedString(raw?["recipient"]),
      platform: vibeAgentKitNormalizedString(raw?["platform"]),
      format: vibeAgentKitNormalizedString(raw?["format"]),
      messageContent: vibeAgentKitNormalizedString(raw?["messageContent"])
        ?? vibeAgentKitNormalizedString(raw?["thinkingText"])
        ?? vibeAgentKitNormalizedString(raw?["thinking_text"])
        ?? vibeAgentKitNormalizedString(raw?["thinking_summary"]),
      messagePreview: vibeAgentKitNormalizedString(raw?["messagePreview"]),
      voiceUrl: vibeAgentKitNormalizedString(raw?["voiceUrl"]),
      voiceDuration: doubleValue(raw?["voiceDuration"]),
      status: vibeAgentKitNormalizedString(raw?["status"]),
      isRecording: boolValue(raw?["isRecording"]) ?? false,
      recordingStartTime: doubleValue(raw?["recordingStartTime"]),
      tool: vibeAgentKitNormalizedString(raw?["tool"]),
      image: vibeAgentKitNormalizedString(raw?["image"]),
      itemType: vibeAgentKitNormalizedString(raw?["itemType"]) ?? vibeAgentKitNormalizedString(raw?["kind"]),
      sourceUrl: vibeAgentKitNormalizedString(raw?["sourceUrl"])
    )
  }

  // NOTE: the `from(VibeAgentKitChatProgressItem)` converter was dropped during the
  // port — Vibe maps its own agent-stream data into VibeAgentKitProgressItem directly.

  var detailLines: [String] {
    var lines: [String] = []

    if let status, !status.isEmpty {
      lines.append(status.capitalized)
    }
    if let recipient, !recipient.isEmpty {
      lines.append(recipient)
    }
    if let platform, !platform.isEmpty {
      lines.append(platform.capitalized)
    }
    if let messagePreview, !messagePreview.isEmpty {
      lines.append(messagePreview)
    } else if let messageContent, !messageContent.isEmpty {
      lines.append(messageContent)
    }
    if let sourceUrl, !sourceUrl.isEmpty {
      lines.append(sourceUrl)
    }

    return lines
  }
}

struct VibeAgentKitChatTool: Equatable {
  let id: String
  let name: String
  let icon: String?
  let type: String?
  let category: String?
  let description: String?
  var routeAgent: String? = nil
  var routeAgents: [String] = []

  var systemSymbolName: String {
    if id == "web_search" {
      return "globe"
    }
    if id == "marketplace" {
      return "bag"
    }
    if id == "real_estate" || category == "property" {
      return "building.2"
    }
    if id == "tasks_events" {
      return "calendar.badge.clock"
    }
    if id == "travel" {
      return "airplane"
    }
    if id == "image_generation" || type == "image" {
      return "photo"
    }
    if id == "video_generation" || type == "video" {
      return "video"
    }
    if id == "content" {
      return "square.and.pencil"
    }
    if id == "analytics" {
      return "chart.bar"
    }
    if category == "document" {
      return "doc.text"
    }
    if category == "data" {
      return "magnifyingglass"
    }
    return "sparkles"
  }

  var normalizedDisplayName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // NOTE: the `mediaGeneration(for:)` helper was dropped during the port — it
  // referenced Resolo's media-generation model and isn't used by the agent view.

  var composerPlaceholder: String {
    if id == "web_search" {
      return "Search the web..."
    }
    if id == "real_estate" || category == "property" {
      return "Ask about Dubai property..."
    }
    if type == "image" || id == "image_generation" {
      return "Describe image..."
    }
    if type == "video" || id == "video_generation" {
      return "Describe video..."
    }
    return "Ask with \(normalizedDisplayName)..."
  }
}

func applyVibeAgentKitGlass(
  to view: UIVisualEffectView,
  isDark: Bool,
  interactive: Bool = true,
  cornerRadius: CGFloat? = nil
) {
  let effect = UIGlassEffect()
  effect.isInteractive = interactive
  view.effect = effect

  if let cornerRadius {
    view.layer.cornerRadius = cornerRadius
    view.layer.cornerCurve = .continuous
  }
  view.clipsToBounds = true
  view.contentView.backgroundColor = .clear
}

func animateVibeAgentKitPressDown(_ control: UIControl) {
  UIView.animate(withDuration: 0.08) {
    control.alpha = 0.72
    control.transform = CGAffineTransform(scaleX: 0.992, y: 0.992)
  }
}

func animateVibeAgentKitPressUp(_ control: UIControl) {
  UIView.animate(
    withDuration: 0.16,
    delay: 0,
    options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
  ) {
    control.alpha = 1
    control.transform = .identity
  }
}

func addVibeAgentKitPressAnimation(to control: UIControl) {
  control.addAction(
    UIAction { [weak control] _ in
      guard let control else { return }
      animateVibeAgentKitPressDown(control)
    },
    for: [.touchDown, .touchDragEnter]
  )
  control.addAction(
    UIAction { [weak control] _ in
      guard let control else { return }
      animateVibeAgentKitPressUp(control)
    },
    for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
  )
}

func formattedTime(_ timestampMs: Int64) -> String {
  let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000)
  return timeFormatter.string(from: date)
}

private let timeFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "h:mm a"
  return formatter
}()

func timestampMs(from isoString: String) -> Int64 {
  if let date = ISO8601DateFormatter().date(from: isoString) {
    return Int64(date.timeIntervalSince1970 * 1000)
  }

  let fallback = DateFormatter()
  fallback.locale = Locale(identifier: "en_US_POSIX")
  fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
  if let date = fallback.date(from: isoString) {
    return Int64(date.timeIntervalSince1970 * 1000)
  }

  return Int64(Date().timeIntervalSince1970 * 1000)
}

func vibeAgentKitNormalizedString(_ raw: Any?) -> String? {
  if let value = raw as? String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
  if let number = raw as? NSNumber {
    return number.stringValue
  }
  return nil
}

func intValue(_ raw: Any?) -> Int? {
  if let value = raw as? Int {
    return value
  }
  if let number = raw as? NSNumber {
    return number.intValue
  }
  if let text = raw as? String {
    return Int(text)
  }
  return nil
}

func doubleValue(_ raw: Any?) -> Double? {
  if let value = raw as? Double {
    return value
  }
  if let value = raw as? Float {
    return Double(value)
  }
  if let number = raw as? NSNumber {
    return number.doubleValue
  }
  if let text = raw as? String {
    return Double(text)
  }
  return nil
}

func boolValue(_ raw: Any?) -> Bool? {
  if let value = raw as? Bool {
    return value
  }
  if let number = raw as? NSNumber {
    return number.boolValue
  }
  if let text = raw as? String {
    switch text.lowercased() {
    case "true", "1", "yes":
      return true
    case "false", "0", "no":
      return false
    default:
      return nil
    }
  }
  return nil
}

func vibeAgentKitParseColor(_ hex: String?) -> UIColor? {
  guard var hex else {
    return nil
  }
  hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !hex.isEmpty else {
    return nil
  }

  if hex.hasPrefix("#") {
    hex.removeFirst()
  }

  guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else {
    return nil
  }

  if hex.count == 6 {
    return UIColor(
      red: CGFloat((value & 0xFF0000) >> 16) / 255.0,
      green: CGFloat((value & 0x00FF00) >> 8) / 255.0,
      blue: CGFloat(value & 0x0000FF) / 255.0,
      alpha: 1
    )
  }

  return UIColor(
    red: CGFloat((value & 0xFF000000) >> 24) / 255.0,
    green: CGFloat((value & 0x00FF0000) >> 16) / 255.0,
    blue: CGFloat((value & 0x0000FF00) >> 8) / 255.0,
    alpha: CGFloat(value & 0x000000FF) / 255.0
  )
}

func vibeAgentKitColorWithAlpha(_ color: UIColor, _ alpha: CGFloat) -> UIColor {
  color.withAlphaComponent(alpha)
}

// A progress node / runtime status that means "still working" (vs done/failed). Shared
// across the cell and the conversation VC (e.g. to spin a running subagent's indicator).
let vibeAgentKitRunningStepStatuses: Set<String> = [
  "active", "in-progress", "in_progress", "pending", "queued", "running", "streaming", "working",
]

enum VibeAgentDiffPalette {
  static let additionText = UIColor(red: 0.18, green: 0.74, blue: 0.25, alpha: 1.0)
  static let deletionText = UIColor(red: 0.92, green: 0.24, blue: 0.34, alpha: 1.0)

  static func additionBackground(isDark: Bool) -> UIColor {
    isDark
      ? UIColor(red: 0.12, green: 0.28, blue: 0.16, alpha: 1.0)
      : UIColor(red: 0.88, green: 0.97, blue: 0.90, alpha: 1.0)
  }

  static func deletionBackground(isDark: Bool) -> UIColor {
    isDark
      ? UIColor(red: 0.35, green: 0.13, blue: 0.15, alpha: 1.0)
      : UIColor(red: 0.99, green: 0.88, blue: 0.89, alpha: 1.0)
  }
}

/// SF Symbol for a Claude/Codex tool-node kind — used by the loader line and the
/// tool sheet rows so the feed reads with native icons instead of emoji.
func vibeAgentKitToolSymbol(forKind kind: String?) -> String {
  switch (kind ?? "").lowercased() {
  case "bash", "run": return "terminal"
  case "edit": return "pencil"
  case "write", "create": return "square.and.pencil"
  case "read": return "doc.text"
  case "search", "grep", "glob": return "magnifyingglass"
  case "web", "fetch": return "globe"
  case "task": return "sparkles"
  case "todo", "planning": return "checklist"
  case "thinking": return "brain"
  case "compacting": return "arrow.down.right.and.arrow.up.left"
  case "mcp": return "server.rack"
  case "tool": return "wrench.and.screwdriver"
  default: return "wrench.and.screwdriver"
  }
}

// NOTE: Removed Resolo leftovers that the agent view never uses and that broke
// the build: the `nativeRole`/`nativeMessage` round-trip extensions (the latter
// referenced a dropped `VibeAgentKitProgressItem.from(_:)` overload that no longer
// exists) and `CameraImagePicker` (an unprefixed, unused SwiftUI camera picker that
// risked colliding with app types). None are part of the rendering primitives.
