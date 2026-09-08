import SwiftUI
import UIKit

// MARK: - JSON value (tolerant)

/// Recursive JSON value for open `data` / extension bags.
/// Unknown structure is preserved; callers pull typed fields with helpers.
enum VibeJSONValue: Decodable, Equatable, Hashable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case null
  case array([VibeJSONValue])
  case object([String: VibeJSONValue])

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
      return
    }
    if let b = try? container.decode(Bool.self) {
      self = .bool(b)
      return
    }
    if let i = try? container.decode(Int64.self) {
      self = .number(Double(i))
      return
    }
    if let d = try? container.decode(Double.self) {
      self = .number(d)
      return
    }
    if let s = try? container.decode(String.self) {
      self = .string(s)
      return
    }
    if let a = try? container.decode([VibeJSONValue].self) {
      self = .array(a)
      return
    }
    if let o = try? container.decode([String: VibeJSONValue].self) {
      self = .object(o)
      return
    }
    throw DecodingError.dataCorruptedError(
      in: container,
      debugDescription: "Unsupported JSON value"
    )
  }

  /// Bridge from the codebase’s raw `[String: Any]` / `NSNumber` style payloads.
  static func fromAny(_ any: Any?) -> VibeJSONValue? {
    guard let any else { return .null }
    if any is NSNull { return .null }
    switch any {
    case let s as String:
      return .string(s)
    case let b as Bool:
      return .bool(b)
    case let i as Int:
      return .number(Double(i))
    case let i as Int64:
      return .number(Double(i))
    case let d as Double:
      return .number(d)
    case let f as Float:
      return .number(Double(f))
    case let n as NSNumber:
      // Bool bridges to NSNumber; detect via CFBoolean.
      if CFGetTypeID(n) == CFBooleanGetTypeID() {
        return .bool(n.boolValue)
      }
      return .number(n.doubleValue)
    case let a as [Any]:
      return .array(a.compactMap { fromAny($0) })
    case let d as [String: Any]:
      var out: [String: VibeJSONValue] = [:]
      out.reserveCapacity(d.count)
      for (k, v) in d {
        if let j = fromAny(v) { out[k] = j }
      }
      return .object(out)
    default:
      return nil
    }
  }

  var stringValue: String? {
    if case .string(let s) = self { return s }
    return nil
  }

  var numberValue: Double? {
    if case .number(let n) = self { return n }
    return nil
  }

  var boolValue: Bool? {
    if case .bool(let b) = self { return b }
    return nil
  }

  var arrayValue: [VibeJSONValue]? {
    if case .array(let a) = self { return a }
    return nil
  }

  var objectValue: [String: VibeJSONValue]? {
    if case .object(let o) = self { return o }
    return nil
  }
}

// MARK: - Models

/// `vibe.content.v1` envelope. Unknown extra keys are ignored by `Decodable`.
struct VibeContentEnvelope: Decodable, Equatable {
  var contract: String
  var parts: [VibeContentPart]
  var fallbackText: String

  enum CodingKeys: String, CodingKey {
    case contract, parts, fallbackText
  }

  init(contract: String, parts: [VibeContentPart], fallbackText: String) {
    self.contract = contract
    self.parts = parts
    self.fallbackText = fallbackText
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    contract = try c.decode(String.self, forKey: .contract)
    parts = try c.decodeIfPresent([VibeContentPart].self, forKey: .parts) ?? []
    fallbackText = try c.decodeIfPresent(String.self, forKey: .fallbackText) ?? ""
  }

  init?(raw: [String: Any]) {
    guard let contract = Self.string(raw["contract"]), !contract.isEmpty else { return nil }
    let fallback = Self.string(raw["fallbackText"]) ?? ""
    let rawParts = raw["parts"] as? [Any] ?? []
    let parts: [VibeContentPart] = rawParts.compactMap { item in
      guard let dict = item as? [String: Any] else { return nil }
      return VibeContentPart(raw: dict)
    }
    self.contract = contract
    self.parts = parts
    self.fallbackText = fallback
  }

  private static func string(_ any: Any?) -> String? {
    if let s = any as? String { return s }
    if let n = any as? NSNumber { return n.stringValue }
    return nil
  }
}

/// Single content part. Unknown kinds and unknown fields are preserved / ignored
/// (must-ignore-with-fallback). Core kinds: text, media, card, actions, status,
/// citations, error; registered ext: `vibe.call`.
struct VibeContentPart: Decodable, Equatable, Hashable {
  var kind: String
  var schemaVersion: Int
  var text: String
  var data: [String: VibeJSONValue]
  var mediaType: String?
  var url: String?
  var required: Bool

  enum CodingKeys: String, CodingKey {
    case kind, schemaVersion, text, data, mediaType, url, required
  }

  init(
    kind: String,
    schemaVersion: Int = 1,
    text: String,
    data: [String: VibeJSONValue] = [:],
    mediaType: String? = nil,
    url: String? = nil,
    required: Bool = false
  ) {
    self.kind = kind
    self.schemaVersion = schemaVersion
    self.text = text
    self.data = data
    self.mediaType = mediaType
    self.url = url
    self.required = required
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
    schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
    data = try c.decodeIfPresent([String: VibeJSONValue].self, forKey: .data) ?? [:]
    mediaType = try c.decodeIfPresent(String.self, forKey: .mediaType)
    url = try c.decodeIfPresent(String.self, forKey: .url)
    required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
  }

  /// Raw-dict style used elsewhere in the chat / agent pipeline.
  init?(raw: [String: Any]) {
    guard let kind = Self.string(raw["kind"])?.trimmingCharacters(in: .whitespacesAndNewlines),
      !kind.isEmpty
    else { return nil }

    let text = Self.string(raw["text"]) ?? ""
    let schema: Int = {
      if let i = raw["schemaVersion"] as? Int { return i }
      if let n = raw["schemaVersion"] as? NSNumber { return n.intValue }
      if let d = raw["schemaVersion"] as? Double { return Int(d) }
      return 1
    }()
    let required: Bool = {
      if let b = raw["required"] as? Bool { return b }
      if let n = raw["required"] as? NSNumber { return n.boolValue }
      return false
    }()

    var data: [String: VibeJSONValue] = [:]
    if let dict = raw["data"] as? [String: Any] {
      for (k, v) in dict {
        if let j = VibeJSONValue.fromAny(v) { data[k] = j }
      }
    }

    self.kind = kind
    self.schemaVersion = max(1, schema)
    self.text = text
    self.data = data
    self.mediaType = Self.string(raw["mediaType"])
    self.url = Self.string(raw["url"])
    self.required = required
  }

  // MARK: data helpers

  func dataString(_ key: String) -> String? {
    data[key]?.stringValue
  }

  func dataNumber(_ key: String) -> Double? {
    data[key]?.numberValue
  }

  func dataBool(_ key: String) -> Bool? {
    data[key]?.boolValue
  }

  func dataArray(_ key: String) -> [VibeJSONValue]? {
    data[key]?.arrayValue
  }

  func dataObject(_ key: String) -> [String: VibeJSONValue]? {
    data[key]?.objectValue
  }

  private static func string(_ any: Any?) -> String? {
    if let s = any as? String { return s }
    if let n = any as? NSNumber { return n.stringValue }
    return nil
  }
}

// MARK: - Parts view

/// Renders structured `vibe.content.v1` parts that the existing text/media bubble
/// does not own. Pass host accent + action/link/call callbacks from the cell hook.
struct VibeContentPartsView: View {
  let parts: [VibeContentPart]
  let accent: Color
  let onAction: (String) -> Void
  let onCallRequested: () -> Void
  let onOpenLink: (URL) -> Void

  /// Local dark-theme tokens (Aurora-inspired; accent is injected).
  private enum Theme {
    static let corner: CGFloat = 14
    static let chipCorner: CGFloat = 12
    static let surface = Color.white.opacity(0.06)
    static let surfaceElevated = Color.white.opacity(0.09)
    static let border = Color.white.opacity(0.12)
    static let borderStrong = Color.white.opacity(0.18)
    static let textPrimary = Color.white.opacity(0.94)
    static let textSecondary = Color.white.opacity(0.58)
    static let textTertiary = Color.white.opacity(0.42)
    static let danger = Color(red: 1.0, green: 0.38, blue: 0.42)
    static let dangerSoft = Color(red: 1.0, green: 0.38, blue: 0.42).opacity(0.14)
    static let warning = Color(red: 1.0, green: 0.72, blue: 0.28)
    static let warningSoft = Color(red: 1.0, green: 0.72, blue: 0.28).opacity(0.12)
    static let success = Color(red: 0.31, green: 0.86, blue: 0.62)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
        partRow(part)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func partRow(_ part: VibeContentPart) -> some View {
    switch part.kind {
    case "text", "media":
      // Existing bubble owns body text + media attachments.
      EmptyView()
    case "card":
      cardView(part)
    case "actions":
      actionsView(part)
    case "citations":
      citationsView(part)
    case "status":
      statusView(part)
    case "error":
      errorView(part)
    case "vibe.call":
      callView(part)
    default:
      unknownView(part)
    }
  }

  // MARK: card

  @ViewBuilder
  private func cardView(_ part: VibeContentPart) -> some View {
    let title = part.dataString("title")
    let subtitle = part.dataString("subtitle")
    let link = part.dataString("link")
    let fields = parseFields(part.dataArray("fields"))

    VStack(alignment: .leading, spacing: 10) {
      if let title, !title.isEmpty {
        Text(title)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(Theme.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if let subtitle, !subtitle.isEmpty {
        Text(subtitle)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(accent.opacity(0.95))
          .fixedSize(horizontal: false, vertical: true)
      }

      if title == nil && subtitle == nil {
        Text(part.text)
          .font(.system(size: 14, weight: .regular))
          .foregroundStyle(Theme.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if !fields.isEmpty {
        LazyVGrid(
          columns: [
            GridItem(.flexible(minimum: 72), spacing: 8, alignment: .leading),
            GridItem(.flexible(minimum: 72), spacing: 8, alignment: .leading),
          ],
          alignment: .leading,
          spacing: 8
        ) {
          ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
            VStack(alignment: .leading, spacing: 2) {
              Text(field.label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .textCase(.uppercase)
              Text(field.value)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(.top, 2)
      }

      if let link, let url = Self.url(from: link) {
        Button {
          onOpenLink(url)
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "arrow.up.right.square")
              .font(.system(size: 13, weight: .semibold))
            Text(domainLabel(for: url) ?? "Open link")
              .font(.system(size: 13, weight: .semibold))
              .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(Theme.textTertiary)
          }
          .foregroundStyle(accent)
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
          .background(accent.opacity(0.12))
          .clipShape(RoundedRectangle(cornerRadius: Theme.chipCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Theme.surface)
    .clipShape(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
        .stroke(Theme.border, lineWidth: 1)
    )
  }

  // MARK: actions

  @ViewBuilder
  private func actionsView(_ part: VibeContentPart) -> some View {
    let items = parseActionItems(part.dataArray("items"))
    if items.isEmpty {
      // Never blank — fall back to text lane.
      Text(part.text)
        .font(.system(size: 14))
        .foregroundStyle(Theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      VibeContentFlowLayout(spacing: 8, lineSpacing: 8) {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
          actionControl(item)
        }
      }
    }
  }

  @ViewBuilder
  private func actionControl(_ item: ActionItem) -> some View {
    if item.kind == "select", !item.options.isEmpty {
      Menu {
        ForEach(Array(item.options.enumerated()), id: \.offset) { _, opt in
          Button(opt.label) {
            onAction(opt.id)
          }
        }
      } label: {
        actionLabel(
          title: item.label,
          style: item.style,
          trailing: "chevron.up.chevron.down"
        )
      }
    } else {
      Button {
        onAction(item.id)
      } label: {
        actionLabel(title: item.label, style: item.style, trailing: nil)
      }
      .buttonStyle(.plain)
    }
  }

  private func actionLabel(title: String, style: String, trailing: String?) -> some View {
    let normalized = style.lowercased()
    let isPrimary = normalized == "primary"
    let isDanger = normalized == "danger" || normalized == "destructive"
    // secondary + default + unknown → outline
    let isOutline = !isPrimary && !isDanger

    let fg: Color = {
      if isPrimary { return .white }
      if isDanger { return Theme.danger }
      return accent
    }()
    let bg: Color = {
      if isPrimary { return accent }
      if isDanger { return Theme.dangerSoft }
      return Color.clear
    }()
    let border: Color = {
      if isPrimary { return accent.opacity(0.35) }
      if isDanger { return Theme.danger.opacity(0.45) }
      return accent.opacity(0.55)
    }()

    return HStack(spacing: 6) {
      Text(title)
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
      if let trailing {
        Image(systemName: trailing)
          .font(.system(size: 10, weight: .bold))
      }
    }
    .foregroundStyle(fg)
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .background(bg)
    .clipShape(Capsule(style: .continuous))
    .overlay(
      Capsule(style: .continuous)
        .stroke(isOutline || isDanger || isPrimary ? border : Color.clear, lineWidth: 1)
    )
  }

  // MARK: citations

  @ViewBuilder
  private func citationsView(_ part: VibeContentPart) -> some View {
    let items = parseCitationItems(part.dataArray("items"))
    if items.isEmpty {
      Text(part.text)
        .font(.system(size: 13))
        .foregroundStyle(Theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    } else {
      VStack(alignment: .leading, spacing: 8) {
        Text("Sources")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(Theme.textTertiary)
          .textCase(.uppercase)
          .tracking(0.4)

        VibeContentFlowLayout(spacing: 8, lineSpacing: 8) {
          ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            citationChip(index: index + 1, item: item)
          }
        }
      }
    }
  }

  private func citationChip(index: Int, item: CitationItem) -> some View {
    let url = item.url.flatMap { Self.url(from: $0) }
    let domain = url.flatMap { domainLabel(for: $0) } ?? item.domainFallback

    return Button {
      if let url { onOpenLink(url) }
    } label: {
      HStack(spacing: 8) {
        Text("\(index)")
          .font(.system(size: 11, weight: .bold, design: .rounded))
          .foregroundStyle(accent)
          .frame(width: 20, height: 20)
          .background(accent.opacity(0.16))
          .clipShape(Circle())

        VStack(alignment: .leading, spacing: 1) {
          Text(item.title.isEmpty ? (domain ?? "Source") : item.title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
          if let domain, !domain.isEmpty {
            Text(domain)
              .font(.system(size: 11, weight: .medium))
              .foregroundStyle(Theme.textSecondary)
              .lineLimit(1)
          }
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .background(Theme.surfaceElevated)
      .clipShape(RoundedRectangle(cornerRadius: Theme.chipCorner, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: Theme.chipCorner, style: .continuous)
          .stroke(Theme.border, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .disabled(url == nil)
  }

  // MARK: status

  @ViewBuilder
  private func statusView(_ part: VibeContentPart) -> some View {
    let state = (part.dataString("state") ?? "").lowercased()
    let label = part.dataString("label") ?? part.text
    let progress = part.dataNumber("progress").map { min(1, max(0, $0)) }
    let isActive = state == "thinking" || state == "tool_running" || state == "generating"
    let isDone = state == "done"
    let isError = state == "error"

    HStack(spacing: 10) {
      statusLeading(state: state, progress: progress, isActive: isActive, isDone: isDone, isError: isError)
        .frame(width: 22, height: 22)

      VStack(alignment: .leading, spacing: 4) {
        Text(label.isEmpty ? part.text : label)
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(isError ? Theme.warning : Theme.textPrimary)
          .lineLimit(2)

        if let progress, !isDone {
          GeometryReader { geo in
            ZStack(alignment: .leading) {
              Capsule()
                .fill(Color.white.opacity(0.08))
              Capsule()
                .fill(isError ? Theme.warning : accent)
                .frame(width: max(4, geo.size.width * progress))
            }
          }
          .frame(height: 3)
        }
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(Theme.surface)
    .clipShape(RoundedRectangle(cornerRadius: Theme.chipCorner, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Theme.chipCorner, style: .continuous)
        .stroke(Theme.border, lineWidth: 1)
    )
  }

  @ViewBuilder
  private func statusLeading(
    state: String,
    progress: Double?,
    isActive: Bool,
    isDone: Bool,
    isError: Bool
  ) -> some View {
    if isDone {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(Theme.success)
    } else if isError {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(Theme.warning)
    } else if let progress {
      ZStack {
        Circle()
          .stroke(Color.white.opacity(0.12), lineWidth: 2.5)
        Circle()
          .trim(from: 0, to: progress)
          .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
          .rotationEffect(.degrees(-90))
      }
    } else if isActive {
      ProgressView()
        .progressViewStyle(.circular)
        .tint(accent)
        .scaleEffect(0.85)
    } else {
      Image(systemName: "ellipsis.circle")
        .font(.system(size: 16, weight: .medium))
        .foregroundStyle(Theme.textSecondary)
    }
  }

  // MARK: error

  @ViewBuilder
  private func errorView(_ part: VibeContentPart) -> some View {
    let code = (part.dataString("code") ?? "").lowercased()
    let message = part.dataString("message") ?? part.text
    let retryable = part.dataBool("retryable") ?? (code != "refusal")
    let isRefusal = code == "refusal"

    let caption: String = {
      if isRefusal { return "Request declined" }
      if retryable { return "Something went wrong — you can try again" }
      return "Error"
    }()

    let icon = isRefusal ? "hand.raised.fill" : (retryable ? "arrow.clockwise.circle.fill" : "exclamationmark.octagon.fill")
    let tint = isRefusal ? Theme.warning : Theme.danger
    let soft = isRefusal ? Theme.warningSoft : Theme.dangerSoft

    HStack(alignment: .top, spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.top, 1)

      VStack(alignment: .leading, spacing: 4) {
        Text(caption)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(tint)
        Text(message.isEmpty ? part.text : message)
          .font(.system(size: 13, weight: .regular))
          .foregroundStyle(Theme.textPrimary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(soft)
    .clipShape(RoundedRectangle(cornerRadius: Theme.chipCorner, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Theme.chipCorner, style: .continuous)
        .stroke(tint.opacity(0.35), lineWidth: 1)
    )
  }

  // MARK: vibe.call

  @ViewBuilder
  private func callView(_ part: VibeContentPart) -> some View {
    let label = {
      let fromData = part.dataString("label")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      if !fromData.isEmpty { return fromData }
      let fromText = part.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return fromText.isEmpty ? "Start call" : fromText
    }()

    Button {
      onCallRequested()
    } label: {
      HStack(spacing: 10) {
        ZStack {
          Circle()
            .fill(Color.white.opacity(0.18))
            .frame(width: 34, height: 34)
          Image(systemName: "phone.fill")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
        }
        Text(label)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.white)
          .lineLimit(1)
        Spacer(minLength: 4)
        Image(systemName: "chevron.right")
          .font(.system(size: 12, weight: .bold))
          .foregroundStyle(.white.opacity(0.7))
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(
        LinearGradient(
          colors: [
            accent,
            accent.opacity(0.82),
          ],
          startPoint: .topLeading,
          endPoint: .bottomTrailing
        )
      )
      .clipShape(Capsule(style: .continuous))
      .overlay(
        Capsule(style: .continuous)
          .stroke(Color.white.opacity(0.22), lineWidth: 1)
      )
      .shadow(color: accent.opacity(0.35), radius: 10, y: 4)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }

  // MARK: unknown

  @ViewBuilder
  private func unknownView(_ part: VibeContentPart) -> some View {
    let body = part.text.trimmingCharacters(in: .whitespacesAndNewlines)
    VStack(alignment: .leading, spacing: 6) {
      if part.required {
        HStack(spacing: 6) {
          Image(systemName: "arrow.down.app")
            .font(.system(size: 12, weight: .semibold))
          Text("Needs a newer app to fully display")
            .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(Theme.textTertiary)
      }
      Text(body.isEmpty ? " " : body)
        .font(.system(size: 14, weight: .regular))
        .foregroundStyle(Theme.textPrimary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: parsing helpers

  private struct FieldItem {
    let label: String
    let value: String
  }

  private struct ActionOption {
    let id: String
    let label: String
  }

  private struct ActionItem {
    let id: String
    let label: String
    let style: String
    let kind: String
    let options: [ActionOption]
  }

  private struct CitationItem {
    let title: String
    let url: String?
    let domainFallback: String?
  }

  private func parseFields(_ array: [VibeJSONValue]?) -> [FieldItem] {
    guard let array else { return [] }
    return array.compactMap { value in
      guard let obj = value.objectValue else { return nil }
      let label = obj["label"]?.stringValue ?? ""
      let val = obj["value"]?.stringValue ?? ""
      if label.isEmpty && val.isEmpty { return nil }
      return FieldItem(label: label, value: val)
    }
  }

  private func parseActionItems(_ array: [VibeJSONValue]?) -> [ActionItem] {
    guard let array else { return [] }
    return array.compactMap { value in
      guard let obj = value.objectValue else { return nil }
      let id = obj["id"]?.stringValue ?? ""
      let label = obj["label"]?.stringValue ?? id
      guard !id.isEmpty, !label.isEmpty else { return nil }
      let style = obj["style"]?.stringValue ?? "default"
      let kind = obj["kind"]?.stringValue ?? "button"
      let options: [ActionOption] = (obj["options"]?.arrayValue ?? []).compactMap { opt in
        guard let o = opt.objectValue else { return nil }
        let oid = o["id"]?.stringValue ?? ""
        let olabel = o["label"]?.stringValue ?? oid
        guard !oid.isEmpty else { return nil }
        return ActionOption(id: oid, label: olabel.isEmpty ? oid : olabel)
      }
      return ActionItem(id: id, label: label, style: style, kind: kind, options: options)
    }
  }

  private func parseCitationItems(_ array: [VibeJSONValue]?) -> [CitationItem] {
    guard let array else { return [] }
    return array.compactMap { value in
      guard let obj = value.objectValue else { return nil }
      let title = obj["title"]?.stringValue ?? ""
      let url = obj["url"]?.stringValue
      if title.isEmpty && (url == nil || url?.isEmpty == true) { return nil }
      let domain = url.flatMap { Self.url(from: $0) }.flatMap { domainLabel(for: $0) }
      return CitationItem(title: title, url: url, domainFallback: domain)
    }
  }

  private func domainLabel(for url: URL) -> String? {
    guard let host = url.host, !host.isEmpty else { return nil }
    return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
  }

  private static func url(from string: String) -> URL? {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let u = URL(string: trimmed), u.scheme != nil { return u }
    if trimmed.hasPrefix("//"), let u = URL(string: "https:\(trimmed)") { return u }
    return URL(string: "https://\(trimmed)")
  }
}

// MARK: - Flow layout (wrap)

/// Horizontal flow that wraps to new lines — used for action buttons and citation chips.
private struct VibeContentFlowLayout: Layout {
  var spacing: CGFloat = 8
  var lineSpacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let maxWidth = proposal.width ?? .infinity
    let result = arrange(maxWidth: maxWidth, subviews: subviews)
    return result.size
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    let result = arrange(maxWidth: bounds.width, subviews: subviews)
    for (index, frame) in result.frames.enumerated() {
      guard index < subviews.count else { break }
      subviews[index].place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        proposal: ProposedViewSize(frame.size)
      )
    }
  }

  private struct Arrangement {
    var size: CGSize
    var frames: [CGRect]
  }

  private func arrange(maxWidth: CGFloat, subviews: Subviews) -> Arrangement {
    var frames: [CGRect] = []
    frames.reserveCapacity(subviews.count)
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var totalWidth: CGFloat = 0

    let unlimited = !maxWidth.isFinite || maxWidth <= 0

    for sub in subviews {
      let size = sub.sizeThatFits(.unspecified)
      if !unlimited, x > 0, x + size.width > maxWidth {
        x = 0
        y += rowHeight + lineSpacing
        rowHeight = 0
      }
      frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
      rowHeight = max(rowHeight, size.height)
      x += size.width + spacing
      totalWidth = max(totalWidth, x - spacing)
    }

    let height = y + rowHeight
    let width = unlimited ? totalWidth : maxWidth
    return Arrangement(size: CGSize(width: width, height: height), frames: frames)
  }
}

// MARK: - Preview

#Preview("Content parts — all kinds") {
  let accent = Color(red: 0.1843, green: 0.6196, blue: 0.5765)  // Aurora #2F9E93

  let sample = VibeContentEnvelope(
    contract: "vibe.content.v1",
    parts: [
      VibeContentPart(
        kind: "status",
        text: "Searching the web…",
        data: [
          "state": .string("tool_running"),
          "label": .string("Web search"),
          "progress": .number(0.42),
        ]
      ),
      VibeContentPart(
        kind: "text",
        text: "Bubble owns this text part — hidden here.",
        data: ["format": .string("markdown")]
      ),
      VibeContentPart(
        kind: "media",
        text: "Bubble owns media.",
        mediaType: "image/png",
        url: "vibe-blob://preview/chart.png"
      ),
      VibeContentPart(
        kind: "card",
        text: "Mission loft — $4,200/mo",
        data: [
          "title": .string("Mission loft"),
          "subtitle": .string("$4,200 / month"),
          "link": .string("https://example.com/listings/L1"),
          "fields": .array([
            .object(["label": .string("Beds"), "value": .string("2")]),
            .object(["label": .string("Neighborhood"), "value": .string("Mission")]),
            .object(["label": .string("Sq ft"), "value": .string("980")]),
            .object(["label": .string("Pets"), "value": .string("OK")]),
          ]),
        ]
      ),
      VibeContentPart(
        kind: "citations",
        text: "Sources: climate.gov; IPCC.",
        data: [
          "items": .array([
            .object([
              "title": .string("Global Temperature Anomalies 2023"),
              "url": .string("https://climate.gov/reports/2023-temperature"),
              "snippet": .string("Anomaly +1.1°C."),
            ]),
            .object([
              "title": .string("IPCC AR6 SPM"),
              "url": .string("https://www.ipcc.ch/report/ar6/syr/summary-for-policymakers/"),
            ]),
          ])
        ]
      ),
      VibeContentPart(
        kind: "actions",
        text: "Choose: Approve, Open runbook, or cancel.",
        data: [
          "items": .array([
            .object([
              "id": .string("approve"),
              "label": .string("Approve deploy"),
              "style": .string("primary"),
              "kind": .string("button"),
            ]),
            .object([
              "id": .string("runbook"),
              "label": .string("Open runbook"),
              "style": .string("secondary"),
              "kind": .string("button"),
            ]),
            .object([
              "id": .string("cancel"),
              "label": .string("Cancel"),
              "style": .string("danger"),
              "kind": .string("button"),
            ]),
            .object([
              "id": .string("train"),
              "label": .string("Pick train"),
              "style": .string("default"),
              "kind": .string("select"),
              "options": .array([
                .object(["id": .string("a"), "label": .string("Train A")]),
                .object(["id": .string("b"), "label": .string("Train B")]),
              ]),
            ]),
          ])
        ]
      ),
      VibeContentPart(
        kind: "vibe.call",
        text: "Talk this through live",
        data: [
          "label": .string("Call assistant"),
          "mode": .string("voice"),
        ]
      ),
      VibeContentPart(
        kind: "error",
        text: "I can't help with that request.",
        data: [
          "code": .string("refusal"),
          "message": .string("I can't help with that request."),
          "retryable": .bool(false),
        ]
      ),
      VibeContentPart(
        kind: "error",
        text: "Tool timed out.",
        data: [
          "code": .string("tool_failed"),
          "message": .string("Web search timed out after 30s."),
          "retryable": .bool(true),
        ]
      ),
      VibeContentPart(
        kind: "com.example.widget",
        text: "Custom widget fell back to this text lane.",
        data: ["widgetId": .string("spotify-embed")],
        required: false
      ),
      VibeContentPart(
        kind: "com.vendor.payment",
        text: "Payment sheet unavailable in this build.",
        required: true
      ),
    ],
    fallbackText: "Preview of all vibe.content.v1 part kinds."
  )

  ScrollView {
    VibeContentPartsView(
      parts: sample.parts,
      accent: accent,
      onAction: { _ in },
      onCallRequested: {},
      onOpenLink: { _ in }
    )
    .padding(16)
  }
  .background(Color(red: 0.02, green: 0.02, blue: 0.043))  // #05050B
  .preferredColorScheme(.dark)
}
