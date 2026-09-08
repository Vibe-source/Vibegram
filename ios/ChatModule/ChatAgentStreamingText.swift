import UIKit

private let chatNativeAgentBoldRegex = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
private let chatNativeAgentMarkdownLinkRegex = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\((https?://[^)]+)\\)")
private let chatNativeAgentInlineCodeRegex = try! NSRegularExpression(pattern: "`([^`]+)`")
/// Bare `@username` mentions (person/agent handles). Length matches server
/// `validate_username_string` (3…30, `[a-z0-9_]`). Lookbehind skips emails (`a@b.com`).
private let chatNativeAgentMentionRegex = try! NSRegularExpression(
  pattern: #"(?<![A-Za-z0-9_])@([A-Za-z0-9_]{3,30})\b"#
)

protocol ChatNativeStreamingTextLabelDelegate: AnyObject {
  func streamingTextLabel(_ label: ChatNativeStreamingTextLabel, didTap url: URL)
}

/// Block type emitted by ChatNativeAgentTextRenderer.parseBlocks.
enum AgentParsedBlock: Equatable {
  case text(String)
  case code(String, String?) // code + optional language
  case agentPack(AgentIntegrationPack)
  case agentRuntime(ChatListRow.AgentRuntimeSummary)
}

/// Whether a finished turn's runtime actually changed anything. Turns that ran without
/// touching a file (greetings, Q&A, failed runs) must not render the "N files changed
/// +X −Y · Review" card — there is no diff to review.
func agentRuntimeHasDiff(_ runtime: ChatListRow.AgentRuntimeSummary?) -> Bool {
  guard let diff = runtime?.diff else { return false }
  let hasPatch = diff.patch?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
  return diff.filesChanged > 0 || diff.additions > 0 || diff.deletions > 0
    || !diff.files.isEmpty || hasPatch
}

struct AgentIntegrationPack: Equatable {
  let agentId: String
  let displayName: String
  let username: String?
  let status: String
  let environment: String
  let eventsURL: String?
  let invokeURL: String?

  var summary: String {
    "Your \(displayName) agent is ready."
  }

  var storageKey: String {
    "agent-pack:\(agentId)"
  }
}

enum ChatNativeAgentTextRenderer {
  static func isRTL(_ text: String) -> Bool {
    text.range(of: "[\\u0600-\\u06FF]", options: .regularExpression) != nil
  }

  static func makeAttributedText(
    text: String,
    font: UIFont,
    textColor: UIColor,
    lineHeight: CGFloat? = nil
  ) -> NSAttributedString {
    let isRtl = isRTL(text)
    // Prefer lineSpacing over min/max lineHeight locks — fixed line boxes make long
    // agent answers look cramped and uneven next to headings/lists. Default to a
    // WhatsApp-like ~1.35× body line when callers omit an explicit target.
    let resolvedLineHeight = lineHeight ?? max(font.lineHeight + 4.0, font.pointSize * 1.35)
    let lineSpacing = max(0.0, resolvedLineHeight - font.lineHeight)
    return applyLineMarkdown(
      text,
      font: font,
      textColor: textColor,
      isRtl: isRtl,
      lineSpacing: lineSpacing
    )
  }

  /// Shared paragraph style for one rendered line/paragraph. `spacingBefore` separates
  /// sections; `firstLineHeadIndent`/`headIndent` hang list markers and nested levels.
  private static func makeParagraphStyle(
    isRtl: Bool,
    lineSpacing: CGFloat,
    spacingBefore: CGFloat,
    firstLineHeadIndent: CGFloat = 0.0,
    headIndent: CGFloat = 0.0
  ) -> NSMutableParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.alignment = isRtl ? .right : .natural
    style.baseWritingDirection = isRtl ? .rightToLeft : .leftToRight
    style.lineBreakMode = .byWordWrapping
    style.lineSpacing = lineSpacing
    style.paragraphSpacingBefore = spacingBefore
    style.firstLineHeadIndent = firstLineHeadIndent
    style.headIndent = headIndent
    return style
  }

  // MARK: - Block parsing

  /// Split raw markdown into text, fenced-code, and structured agent-pack blocks.
  static func parseBlocks(_ text: String) -> [AgentParsedBlock] {
    if let pack = parseAgentIntegrationPack(text) {
      return [.text(pack.summary), .agentPack(pack)]
    }

    var blocks: [AgentParsedBlock] = []
    var normalLines: [String] = []
    var codeLines: [String] = []
    var inCodeBlock = false
    var currentLang: String? = nil
    for line in text.components(separatedBy: "\n") {
      if line.hasPrefix("```") {
        let fenceInfo = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        if inCodeBlock {
          let code = codeLines.joined(separator: "\n")
          if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.code(code, currentLang))
          }
          codeLines = []
          currentLang = nil
          inCodeBlock = false
        } else {
          let normal = normalLines.joined(separator: "\n")
          if !normal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.text(normal))
          }
          normalLines = []
          inCodeBlock = true
          currentLang = fenceInfo.isEmpty ? nil : fenceInfo
        }
      } else if inCodeBlock {
        codeLines.append(line)
      } else {
        normalLines.append(line)
      }
    }
    if inCodeBlock, !codeLines.isEmpty {
      blocks.append(.code(codeLines.joined(separator: "\n"), currentLang))
    } else if !normalLines.isEmpty {
      let t = normalLines.joined(separator: "\n")
      if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blocks.append(.text(t)) }
    }
    return blocks.isEmpty ? [.text(text)] : blocks
  }

  private static func parseAgentIntegrationPack(_ text: String) -> AgentIntegrationPack? {
    let markerCount = [
      "Agent Details:",
      "Environment Variables:",
      "VIBE_AGENT_IDENTIFIER=",
      "API Endpoints:",
    ].filter { text.localizedCaseInsensitiveContains($0) }.count
    guard markerCount >= 2 else { return nil }

    let normalized =
      text
      .replacingOccurrences(of: "**", with: "")
      .replacingOccurrences(of: "__", with: "")
    guard
      let agentId = firstCapture(
        in: normalized,
        pattern: #"(?im)^\s*[-*]?\s*Agent ID\s*:\s*`?([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})`?"#
      ),
      let environment = firstCapture(
        in: normalized,
        pattern: #"(?is)Environment Variables\s*:\s*```[^\n]*\n(.*?)```"#
      )?.trimmingCharacters(in: .whitespacesAndNewlines),
      !environment.isEmpty
    else {
      return nil
    }

    let username =
      firstCapture(
        in: normalized,
        pattern: #"(?im)^\s*[-*]?\s*Username\s*:\s*`?@?([a-z0-9_]{3,64})`?"#
      )
      ?? firstCapture(
        in: normalized,
        pattern: #"(?im)^\s*VIBE_AGENT_IDENTIFIER\s*=\s*([a-z0-9_]{3,64})\s*$"#
      )
    let displayName =
      firstCapture(
        in: normalized,
        pattern: #"(?i)\bYour\s+([^\n]{1,80}?)\s+agent\s+is\s+ready\b"#
      )?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? username
      ?? "Agent"
    let eventsURL = firstCapture(
      in: normalized,
      pattern: #"(?im)^\s*[-*]?\s*Events\s*:\s*(?:\[)?(https?://[^\s\])`]+)"#
    )
    let invokeURL = firstCapture(
      in: normalized,
      pattern: #"(?im)^\s*[-*]?\s*Invoke\s*:\s*(?:\[)?(https?://[^\s\])`]+)"#
    )
    let status =
      normalized.localizedCaseInsensitiveContains("published status")
      || normalized.localizedCaseInsensitiveContains("is published")
      ? "published" : "draft"

    return AgentIntegrationPack(
      agentId: agentId,
      displayName: displayName,
      username: username,
      status: status,
      environment: environment,
      eventsURL: eventsURL,
      invokeURL: invokeURL
    )
  }

  private static func firstCapture(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, range: range),
      match.numberOfRanges > 1,
      let captureRange = Range(match.range(at: 1), in: text)
    else {
      return nil
    }
    return String(text[captureRange])
  }

  // MARK: - Line-level markdown

  /// Processes a normal-text block line by line. Blank source lines become paragraph
  /// gaps (not empty rows); lists hang under their markers; nested bullets indent
  /// with hollow markers so long agent answers read like WhatsApp Meta AI cards.
  private static func applyLineMarkdown(
    _ text: String,
    font: UIFont,
    textColor: UIColor,
    isRtl: Bool,
    lineSpacing: CGFloat
  ) -> NSAttributedString {
    let result = NSMutableAttributedString()

    // Spacing scales with body font. Blank lines → inter-paragraph gap; headings
    // get a larger gap above + a small gap into their body.
    let paragraphGap = max(10.0, (font.pointSize * 0.72).rounded())
    let headingGap = max(14.0, (font.pointSize * 1.0).rounded())
    let headingBodyGap = max(4.0, (font.pointSize * 0.28).rounded())
    let listItemGap = max(4.0, (font.pointSize * 0.28).rounded())
    let listNestStep = max(14.0, (font.pointSize * 0.95).rounded())

    var emittedContent = false
    var pendingBlank = false
    var previousWasHeading = false
    var previousWasListItem = false

    for rawLine in text.components(separatedBy: "\n") {
      if isTableSeparatorLine(rawLine) { continue }

      if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
        if emittedContent { pendingBlank = true }
        continue
      }

      let heading = parseHeadingLine(rawLine)
      let bullet = heading == nil ? parseBulletListLine(rawLine) : nil
      let numbered = (heading == nil && bullet == nil) ? parseNumberedListLine(rawLine) : nil
      let isListItem = bullet != nil || numbered != nil

      var spacingBefore: CGFloat = 0.0
      if emittedContent {
        if heading != nil {
          spacingBefore = headingGap
        } else if previousWasHeading {
          spacingBefore = headingBodyGap
        } else if pendingBlank {
          spacingBefore = (isListItem && previousWasListItem) ? listItemGap : paragraphGap
        } else if isListItem && previousWasListItem {
          spacingBefore = listItemGap
        }
        result.append(NSAttributedString(string: "\n", attributes: [.font: font]))
      }

      if let (level, headingText) = heading {
        result.append(
          renderHeadingLine(
            headingText,
            level: level,
            baseFont: font,
            textColor: textColor,
            isRtl: isRtl,
            lineSpacing: lineSpacing,
            spacingBefore: spacingBefore
          )
        )
      } else if let (nestLevel, listText) = bullet {
        result.append(
          renderBulletListItem(
            listText,
            nestLevel: nestLevel,
            nestStep: listNestStep,
            font: font,
            textColor: textColor,
            isRtl: isRtl,
            lineSpacing: lineSpacing,
            spacingBefore: spacingBefore
          )
        )
      } else if let (nestLevel, prefix, listText) = numbered {
        result.append(
          renderNumberedListItem(
            prefix,
            text: listText,
            nestLevel: nestLevel,
            nestStep: listNestStep,
            font: font,
            textColor: textColor,
            isRtl: isRtl,
            lineSpacing: lineSpacing,
            spacingBefore: spacingBefore
          )
        )
      } else {
        let style = makeParagraphStyle(
          isRtl: isRtl,
          lineSpacing: lineSpacing,
          spacingBefore: spacingBefore
        )
        let attributes: [NSAttributedString.Key: Any] = [
          .font: font,
          .foregroundColor: textColor,
          .paragraphStyle: style,
        ]
        result.append(applyInlineFormatting(rawLine, baseAttrs: attributes, font: font))
      }

      emittedContent = true
      pendingBlank = false
      previousWasHeading = heading != nil
      previousWasListItem = isListItem
    }

    return result
  }

  private static func isTableSeparatorLine(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard t.count > 2, t.hasPrefix("|") else { return false }
    for ch in t { if ch != "|" && ch != "-" && ch != ":" && ch != " " { return false } }
    return true
  }

  private static func parseHeadingLine(_ line: String) -> (Int, String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    var level = 0
    var idx = trimmed.startIndex
    while idx < trimmed.endIndex, trimmed[idx] == "#" {
      level += 1
      idx = trimmed.index(after: idx)
    }
    guard level >= 1, level <= 6, idx < trimmed.endIndex, trimmed[idx] == " " else { return nil }
    let content = String(trimmed[trimmed.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
    return content.isEmpty ? nil : (level, content)
  }

  /// Leading whitespace → nest level (2 spaces or 1 tab per level). Returns
  /// `(nestLevel, body)` for `-` / `*` / `+` / `•` markers.
  private static func parseBulletListLine(_ line: String) -> (Int, String)? {
    let (nestLevel, trimmed) = listNestLevel(line)
    for marker in ["- ", "* ", "+ ", "• ", "○ ", "◦ ", "▪ "] {
      if trimmed.hasPrefix(marker) {
        let text = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (nestLevel, text)
      }
    }
    return nil
  }

  private static func parseNumberedListLine(_ line: String) -> (Int, String, String)? {
    let (nestLevel, trimmed) = listNestLevel(line)
    var idx = trimmed.startIndex
    while idx < trimmed.endIndex, trimmed[idx].isNumber {
      idx = trimmed.index(after: idx)
    }
    guard idx > trimmed.startIndex else { return nil }
    let rest = String(trimmed[idx...])
    guard rest.hasPrefix(". ") else { return nil }
    let prefix = String(trimmed[..<idx]) + "."
    let text = String(rest.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : (nestLevel, prefix, text)
  }

  private static func listNestLevel(_ line: String) -> (Int, String) {
    var spaces = 0
    var idx = line.startIndex
    while idx < line.endIndex {
      let ch = line[idx]
      if ch == " " {
        spaces += 1
      } else if ch == "\t" {
        spaces += 2
      } else {
        break
      }
      idx = line.index(after: idx)
    }
    let nest = min(4, spaces / 2)
    return (nest, String(line[idx...]))
  }

  private static func bulletMarker(for nestLevel: Int) -> String {
    switch nestLevel {
    case 0: return "•  "
    case 1: return "○  "
    default: return "▪  "
    }
  }

  private static func renderBulletListItem(
    _ text: String,
    nestLevel: Int,
    nestStep: CGFloat,
    font: UIFont,
    textColor: UIColor,
    isRtl: Bool,
    lineSpacing: CGFloat,
    spacingBefore: CGFloat
  ) -> NSAttributedString {
    let marker = bulletMarker(for: nestLevel)
    let baseIndent = CGFloat(nestLevel) * nestStep
    let markerWidth = (marker as NSString).size(withAttributes: [.font: font]).width
    let style = makeParagraphStyle(
      isRtl: isRtl,
      lineSpacing: lineSpacing,
      spacingBefore: spacingBefore,
      firstLineHeadIndent: baseIndent,
      headIndent: baseIndent + markerWidth
    )
    let base: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: textColor,
      .paragraphStyle: style,
    ]
    let result = NSMutableAttributedString(string: marker, attributes: base)
    result.append(applyInlineFormatting(text, baseAttrs: base, font: font))
    return result
  }

  private static func renderNumberedListItem(
    _ prefix: String,
    text: String,
    nestLevel: Int,
    nestStep: CGFloat,
    font: UIFont,
    textColor: UIColor,
    isRtl: Bool,
    lineSpacing: CGFloat,
    spacingBefore: CGFloat
  ) -> NSAttributedString {
    let marker = "\(prefix) "
    let baseIndent = CGFloat(nestLevel) * nestStep
    let markerWidth = (marker as NSString).size(withAttributes: [.font: font]).width
    let style = makeParagraphStyle(
      isRtl: isRtl,
      lineSpacing: lineSpacing,
      spacingBefore: spacingBefore,
      firstLineHeadIndent: baseIndent,
      headIndent: baseIndent + markerWidth
    )
    let base: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: textColor,
      .paragraphStyle: style,
    ]
    let result = NSMutableAttributedString(string: marker, attributes: base)
    result.append(applyInlineFormatting(text, baseAttrs: base, font: font))
    return result
  }

  private static func renderHeadingLine(
    _ text: String,
    level: Int,
    baseFont: UIFont,
    textColor: UIColor,
    isRtl: Bool,
    lineSpacing: CGFloat,
    spacingBefore: CGFloat
  ) -> NSAttributedString {
    let scale: CGFloat = level == 1 ? 1.18 : level == 2 ? 1.10 : 1.04
    let headingFont: UIFont = {
      if let d = baseFont.fontDescriptor.withSymbolicTraits(.traitBold) {
        return UIFont(descriptor: d, size: round(baseFont.pointSize * scale))
      }
      return UIFont.boldSystemFont(ofSize: round(baseFont.pointSize * scale))
    }()
    let style = makeParagraphStyle(
      isRtl: isRtl,
      lineSpacing: lineSpacing,
      spacingBefore: spacingBefore
    )
    let attrs: [NSAttributedString.Key: Any] = [
      .font: headingFont,
      .foregroundColor: textColor,
      .paragraphStyle: style,
    ]
    return applyInlineFormatting(text, baseAttrs: attrs, font: headingFont)
  }

  private static func applyInlineFormatting(
    _ text: String,
    baseAttrs: [NSAttributedString.Key: Any],
    font: UIFont
  ) -> NSAttributedString {
    let mutable = NSMutableAttributedString(string: text, attributes: baseAttrs)
    let linkColor = (baseAttrs[.foregroundColor] as? UIColor) ?? .label

    // 1) Markdown links [label](url) — replace first to preserve offsets.
    let linkMatches = chatNativeAgentMarkdownLinkRegex.matches(
      in: mutable.string,
      range: NSRange(mutable.string.startIndex..., in: mutable.string)
    )
    for match in linkMatches.reversed() {
      guard
        let labelRange = Range(match.range(at: 1), in: mutable.string),
        let urlRange = Range(match.range(at: 2), in: mutable.string)
      else { continue }
      let label = String(mutable.string[labelRange])
      let urlString = String(mutable.string[urlRange])
      mutable.replaceCharacters(in: match.range, with: NSAttributedString(string: label, attributes: baseAttrs))
      let replacedRange = NSRange(location: match.range.location, length: (label as NSString).length)
      if let url = URL(string: urlString) {
        mutable.addAttribute(.link, value: url, range: replacedRange)
        // Match body text color (not system blue) — Telegram-style white-on-bubble links.
        mutable.addAttribute(.foregroundColor, value: linkColor, range: replacedRange)
        mutable.addAttribute(
          .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: replacedRange
        )
      }
    }

    // 2) Bold **text**
    let boldMatches = chatNativeAgentBoldRegex.matches(
      in: mutable.string,
      range: NSRange(mutable.string.startIndex..., in: mutable.string)
    )
    for match in boldMatches.reversed() {
      guard let range = Range(match.range(at: 1), in: mutable.string) else { continue }
      let boldText = String(mutable.string[range])
      var boldAttrs = baseAttrs
      if let d = font.fontDescriptor.withSymbolicTraits(.traitBold) {
        boldAttrs[.font] = UIFont(descriptor: d, size: font.pointSize)
      } else {
        boldAttrs[.font] = UIFont.boldSystemFont(ofSize: font.pointSize)
      }
      mutable.replaceCharacters(in: match.range, with: NSAttributedString(string: boldText, attributes: boldAttrs))
    }

    // 3) Inline code `code`
    let codeMatches = chatNativeAgentInlineCodeRegex.matches(
      in: mutable.string,
      range: NSRange(mutable.string.startIndex..., in: mutable.string)
    )
    for match in codeMatches.reversed() {
      guard let range = Range(match.range(at: 1), in: mutable.string) else { continue }
      let codeText = String(mutable.string[range])
      var codeAttrs = baseAttrs
      codeAttrs[.font] = UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
      mutable.replaceCharacters(in: match.range, with: NSAttributedString(string: codeText, attributes: codeAttrs))
    }

    // 4) Auto-detect bare URLs while preserving their exact visible text.
    if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
      let urlMatches = detector.matches(
        in: mutable.string,
        options: [],
        range: NSRange(mutable.string.startIndex..., in: mutable.string)
      ).reversed()
      for m in urlMatches {
        guard let url = m.url else { continue }
        var hasLink = false
        mutable.enumerateAttribute(.link, in: m.range, options: []) { value, _, stop in
          if value != nil { hasLink = true; stop.pointee = true }
        }
        if !hasLink {
          mutable.addAttribute(.link, value: url, range: m.range)
          // Preserve the exact source URL; shortening can remove path identifiers.
          mutable.addAttribute(.foregroundColor, value: linkColor, range: m.range)
          mutable.addAttribute(
            .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range
          )
        }
      }
    }

    // 5) Auto-link @username — keep visible `@handle` text, attach a routeable
    // `vibe://u?handle=` so a tap can push the DM/agent chat immediately.
    applyMentionLinks(to: mutable, baseAttrs: baseAttrs, linkColor: linkColor)

    return mutable
  }

  /// Marks bare `@username` spans as tappable handle links. Skips ranges that
  /// already carry a `.link` (markdown/URL) and skips reserved non-profile tokens
  /// that the share router would refuse (`api`, `settings`, …).
  private static func applyMentionLinks(
    to mutable: NSMutableAttributedString,
    baseAttrs: [NSAttributedString.Key: Any],
    linkColor: UIColor
  ) {
    let fullRange = NSRange(mutable.string.startIndex..., in: mutable.string)
    let matches = chatNativeAgentMentionRegex.matches(in: mutable.string, range: fullRange)
    guard !matches.isEmpty else { return }

    for match in matches.reversed() {
      guard match.numberOfRanges > 1,
        let handleSwiftRange = Range(match.range(at: 1), in: mutable.string)
      else { continue }
      let handle = String(mutable.string[handleSwiftRange])
      let linkRange = match.range
      guard linkRange.location != NSNotFound, linkRange.length > 0 else { continue }

      // Condition: already a link (e.g. markdown label that happens to contain @x).
      var hasLink = false
      mutable.enumerateAttribute(.link, in: linkRange, options: []) { value, _, stop in
        if value != nil {
          hasLink = true
          stop.pointee = true
        }
      }
      if hasLink { continue }

      // Condition: reserved SPA paths are not people/agents — leave as plain text.
      if VibeShareLinks.isReservedHandle(handle) { continue }

      guard let url = URL(string: "vibe://u?handle=\(handle.lowercased())") else { continue }
      var linkAttrs = baseAttrs
      linkAttrs[.link] = url
      linkAttrs[.foregroundColor] = linkColor
      linkAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
      // Keep the original `@username` glyphs; only attach route + underline.
      mutable.addAttributes(linkAttrs, range: linkRange)
    }
  }

  private static func cleanURLDisplay(_ url: URL) -> String {
    guard let host = url.host else { return url.absoluteString }
    let h = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    return "\(h) ↗"
  }

  static func measuredHeight(
    for attributedText: NSAttributedString,
    width: CGFloat
  ) -> CGFloat {
    measuredSize(for: attributedText, width: width).height
  }

  static func measuredWidth(
    for attributedText: NSAttributedString,
    height: CGFloat
  ) -> CGFloat {
    guard height > 1.0, attributedText.length > 0 else { return 0.0 }
    let measured = attributedText.boundingRect(
      with: CGSize(width: .greatestFiniteMagnitude, height: height),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    return ceil(measured.width)
  }

  static func measuredSize(
    for attributedText: NSAttributedString,
    width: CGFloat
  ) -> CGSize {
    guard width > 1.0, attributedText.length > 0 else { return .zero }
    let measured = attributedText.boundingRect(
      with: CGSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    return CGSize(width: ceil(measured.width), height: ceil(measured.height))
  }
}

// MARK: - AgentRuntimeSummaryView

final class AgentRuntimeSummaryView: UIView {
  private final class FileRowView: UIView {
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let pathLabel = UILabel()
    private let statsLabel = UILabel()

    override init(frame: CGRect) {
      super.init(frame: frame)
      [iconView, nameLabel, pathLabel, statsLabel].forEach {
        $0.translatesAutoresizingMaskIntoConstraints = false
        $0.backgroundColor = .clear
        addSubview($0)
      }
      iconView.contentMode = .scaleAspectFit
      nameLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
      pathLabel.font = UIFont.systemFont(ofSize: 13, weight: .regular)
      pathLabel.lineBreakMode = .byTruncatingHead
      statsLabel.textAlignment = .right
    }

    required init?(coder: NSCoder) {
      return nil
    }

    func configure(file: ChatListRow.AgentRuntimeFile, textColor: UIColor) {
      nameLabel.text = file.name
      pathLabel.text = file.path

      let ext = (file.name as NSString).pathExtension.lowercased()
      if ext == "swift" {
        iconView.image = UIImage(systemName: "swift")
        iconView.tintColor = .systemOrange
      } else if ext == "js" || ext == "ts" || ext == "tsx" || ext == "jsx" {
        iconView.image = UIImage(systemName: "curlybraces")
        iconView.tintColor = .systemYellow
      } else {
        iconView.image = UIImage(systemName: "doc.text")
        iconView.tintColor = textColor.withAlphaComponent(0.6)
      }

      let additions = file.additions > 0 ? "+\(file.additions)" : "+0"
      let deletions = file.deletions > 0 ? "-\(file.deletions)" : "-0"
      
      let font = UIFont.systemFont(ofSize: 13, weight: .regular)
      let addAttr = NSAttributedString(string: additions, attributes: [
        .foregroundColor: VibeAgentDiffPalette.additionText,
        .font: font
      ])
      let delAttr = NSAttributedString(string: " \(deletions)", attributes: [
        .foregroundColor: VibeAgentDiffPalette.deletionText,
        .font: font
      ])
      let statsAttr = NSMutableAttributedString()
      statsAttr.append(addAttr)
      statsAttr.append(delAttr)
      statsLabel.attributedText = statsAttr

      nameLabel.textColor = textColor.withAlphaComponent(0.9)
      pathLabel.textColor = textColor.withAlphaComponent(0.4)
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      let iconSize: CGFloat = 16
      let statsSize = statsLabel.sizeThatFits(CGSize(width: bounds.width, height: bounds.height))
      let statsWidth = max(40, statsSize.width)
      let gap: CGFloat = 6
      
      iconView.frame = CGRect(x: 0, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
      statsLabel.frame = CGRect(x: bounds.width - statsWidth, y: 0, width: statsWidth, height: bounds.height)
      
      let nameSize = nameLabel.sizeThatFits(CGSize(width: bounds.width, height: bounds.height))
      let maxNameWidth = min(nameSize.width, bounds.width - iconSize - gap - statsWidth - gap - 20)
      nameLabel.frame = CGRect(x: iconSize + gap, y: 0, width: max(0, maxNameWidth), height: bounds.height)
      
      let pathX = nameLabel.frame.maxX + gap
      pathLabel.frame = CGRect(x: pathX, y: 0, width: max(0, bounds.width - pathX - statsWidth - gap), height: bounds.height)
    }
  }

  private let backgroundView = UIView()
  private let headerContainer = UIView()
  private let titleLabel = UILabel()
  private let titleStatsLabel = UILabel()
  private let chevronImageView = UIImageView(image: UIImage(systemName: "chevron.down"))
  private let reviewContainer = UIView()
  private let reviewIcon = UIImageView(image: UIImage(systemName: "doc.badge.plus"))
  private let reviewLabel = UILabel()
  private let separatorView = UIView()

  private let commandLabel = UILabel()
  private let dirtyLabel = UILabel()
  private let moreLabel = UILabel()
  private let teamStripLabel = UILabel()
  private var fileRows: [FileRowView] = []
  private var runtime: ChatListRow.AgentRuntimeSummary?
  private var textColor: UIColor = .label
  var onToggleExpand: (() -> Void)?
  var onReviewTapped: (() -> Void)?
  var onFileTapped: ((ChatListRow.AgentRuntimeFile) -> Void)?
  private var isExpanded: Bool = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    
    backgroundView.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.72)
    backgroundView.layer.cornerRadius = 12
    backgroundView.layer.cornerCurve = .continuous
    backgroundView.layer.borderWidth = 1
    backgroundView.layer.borderColor = UIColor.separator.withAlphaComponent(0.25).cgColor
    addSubview(backgroundView)

    [headerContainer, separatorView, commandLabel, dirtyLabel, moreLabel, teamStripLabel].forEach {
      $0.backgroundColor = .clear
      addSubview($0)
    }
    teamStripLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
    teamStripLabel.numberOfLines = 2
    teamStripLabel.lineBreakMode = .byTruncatingTail
    
    [titleLabel, titleStatsLabel, chevronImageView, reviewContainer].forEach {
      $0.backgroundColor = .clear
      headerContainer.addSubview($0)
    }

    [reviewIcon, reviewLabel].forEach {
      $0.backgroundColor = .clear
      reviewContainer.addSubview($0)
    }

    titleLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
    titleLabel.numberOfLines = 1
    
    chevronImageView.contentMode = .scaleAspectFit
    
    reviewContainer.layer.cornerRadius = 6
    reviewContainer.layer.borderWidth = 1
    reviewContainer.layer.borderColor = UIColor.separator.withAlphaComponent(0.4).cgColor
    reviewContainer.backgroundColor = UIColor.separator.withAlphaComponent(0.1)
    
    reviewIcon.contentMode = .scaleAspectFit
    reviewLabel.text = "Review"
    reviewLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
    
    separatorView.backgroundColor = UIColor.separator.withAlphaComponent(0.3)
    
    commandLabel.font = UIFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    commandLabel.lineBreakMode = .byTruncatingMiddle
    dirtyLabel.font = UIFont.systemFont(ofSize: 11.5, weight: .regular)
    moreLabel.font = UIFont.systemFont(ofSize: 12, weight: .medium)
    
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleHeaderTap))
    headerContainer.addGestureRecognizer(tap)
    headerContainer.isUserInteractionEnabled = true
    
    let reviewTap = UITapGestureRecognizer(target: self, action: #selector(handleReviewTap))
    reviewContainer.addGestureRecognizer(reviewTap)
    reviewContainer.isUserInteractionEnabled = true
  }

  required init?(coder: NSCoder) {
    return nil
  }

  static func measuredHeight(runtime: ChatListRow.AgentRuntimeSummary, availableWidth: CGFloat, isExpanded: Bool) -> CGFloat {
    _ = availableWidth
    let teamStripExtra: CGFloat =
      (runtime.teamProgressStrip?.isEmpty == false) ? 28 : 0
    if !isExpanded {
      return 12 + 36 + teamStripExtra + 12
    }
    let files = runtime.diff?.files ?? []
    var height: CGFloat = 12 + 36 + teamStripExtra + 1 + 9
    height += CGFloat(min(files.count, 4)) * 32
    height += 3
    
    if runtime.command?.display?.isEmpty == false || runtime.command?.executable?.isEmpty == false {
      height += 18
    }
    if runtime.dirtyBefore {
      height += 17
    }
    if files.count > 4 {
      height += 20
    }
    
    return height + 12
  }

  @discardableResult
  func configure(
    runtime: ChatListRow.AgentRuntimeSummary,
    textColor: UIColor,
    availableWidth: CGFloat,
    isExpanded: Bool
  ) -> CGFloat {
    self.runtime = runtime
    self.textColor = textColor
    self.isExpanded = isExpanded
    let diff = runtime.diff
    let filesChanged = diff?.filesChanged ?? 0
    
    if let strip = runtime.teamProgressStrip, !strip.isEmpty {
      titleLabel.text =
        runtime.status == "running"
        ? (runtime.teamPhaseLabel ?? "Team working") : "Team finished"
      teamStripLabel.text = strip
      teamStripLabel.isHidden = false
      teamStripLabel.textColor = textColor.withAlphaComponent(0.72)
    } else {
      titleLabel.text = filesChanged == 1 ? "1 file changed" : "\(filesChanged) files changed"
      teamStripLabel.text = nil
      teamStripLabel.isHidden = true
    }
    titleLabel.textColor = textColor.withAlphaComponent(0.8)
    
    let font = UIFont.systemFont(ofSize: 14, weight: .regular)
    let addAttr = NSAttributedString(string: "+\(diff?.additions ?? 0)", attributes: [
      .foregroundColor: VibeAgentDiffPalette.additionText,
      .font: font
    ])
    let delAttr = NSAttributedString(string: " -\(diff?.deletions ?? 0)", attributes: [
      .foregroundColor: VibeAgentDiffPalette.deletionText,
      .font: font
    ])
    let statsAttr = NSMutableAttributedString()
    statsAttr.append(addAttr)
    statsAttr.append(delAttr)
    titleStatsLabel.attributedText = statsAttr
    
    chevronImageView.tintColor = textColor.withAlphaComponent(0.5)
    reviewIcon.tintColor = textColor.withAlphaComponent(0.8)
    reviewLabel.textColor = textColor.withAlphaComponent(0.8)
    
    UIView.animate(withDuration: 0.2) {
      self.chevronImageView.transform = isExpanded ? CGAffineTransform(rotationAngle: -.pi) : .identity
    }

    commandLabel.text = runtime.command?.display ?? runtime.command?.executable
    dirtyLabel.text =
      runtime.dirtyBefore
      ? "Repo already had \(runtime.dirtyBeforeCount) change(s) before this run"
      : nil
    let hiddenCount = max(0, (diff?.files.count ?? 0) - 4)
    moreLabel.text = hiddenCount > 0 ? "View \(hiddenCount) more file(s)" : nil

    commandLabel.textColor = textColor.withAlphaComponent(0.5)
    dirtyLabel.textColor = UIColor.systemOrange
    moreLabel.textColor = textColor.withAlphaComponent(0.5)

    let files = Array((diff?.files ?? []).prefix(4))
    while fileRows.count < files.count {
      let row = FileRowView()
      row.isUserInteractionEnabled = true
      let tap = UITapGestureRecognizer(target: self, action: #selector(handleFileTap(_:)))
      row.addGestureRecognizer(tap)
      addSubview(row)
      fileRows.append(row)
    }
    for (index, row) in fileRows.enumerated() {
      if index < files.count {
        row.isHidden = !isExpanded
        row.configure(file: files[index], textColor: textColor)
        row.tag = index
      } else {
        row.isHidden = true
      }
    }
    
    separatorView.isHidden = !isExpanded
    commandLabel.isHidden = !isExpanded || commandLabel.text?.isEmpty ?? true
    dirtyLabel.isHidden = !isExpanded || dirtyLabel.text?.isEmpty ?? true
    moreLabel.isHidden = !isExpanded || moreLabel.text?.isEmpty ?? true

    let height = Self.measuredHeight(runtime: runtime, availableWidth: availableWidth, isExpanded: isExpanded)
    frame.size = CGSize(width: availableWidth, height: height)
    setNeedsLayout()
    return height
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    backgroundView.frame = bounds
    let inset: CGFloat = 16
    let width = max(1, bounds.width - inset * 2)
    var y: CGFloat = 12
    
    // Header
    headerContainer.frame = CGRect(x: inset, y: y, width: width, height: 36)
    let titleSize = titleLabel.sizeThatFits(CGSize(width: width, height: 36))
    titleLabel.frame = CGRect(x: 0, y: 0, width: titleSize.width, height: 36)
    
    let statsSize = titleStatsLabel.sizeThatFits(CGSize(width: width, height: 36))
    titleStatsLabel.frame = CGRect(x: titleLabel.frame.maxX + 6, y: 0, width: statsSize.width, height: 36)
    
    chevronImageView.frame = CGRect(x: titleStatsLabel.frame.maxX + 6, y: (36 - 10) / 2, width: 12, height: 10)
    
    reviewLabel.sizeToFit()
    let reviewW = reviewLabel.frame.width + 12 + 6 + 12
    let reviewH: CGFloat = 28
    reviewContainer.frame = CGRect(x: width - reviewW, y: (36 - reviewH) / 2, width: reviewW, height: reviewH)
    reviewIcon.frame = CGRect(x: 10, y: (reviewH - 14) / 2, width: 12, height: 14)
    reviewLabel.frame = CGRect(x: reviewIcon.frame.maxX + 6, y: 0, width: reviewLabel.frame.width, height: reviewH)
    
    y += 36

    if !teamStripLabel.isHidden {
      let stripH = teamStripLabel.sizeThatFits(CGSize(width: width, height: 40)).height
      let h = max(18, min(36, stripH))
      teamStripLabel.frame = CGRect(x: inset, y: y + 2, width: width, height: h)
      y += h + 6
    } else {
      teamStripLabel.frame = .zero
    }
    
    if !isExpanded { return }
    
    // Separator
    separatorView.frame = CGRect(x: 0, y: y, width: bounds.width, height: 1)
    y += 9
    
    // Files
    for row in fileRows where !row.isHidden {
      row.frame = CGRect(x: inset, y: y, width: width, height: 32)
      y += 32
    }
    
    y += 3
    
    if !commandLabel.isHidden {
      commandLabel.frame = CGRect(x: inset, y: y, width: width, height: 16)
      y += 18
    }
    
    if !dirtyLabel.isHidden {
      dirtyLabel.frame = CGRect(x: inset, y: y, width: width, height: 15)
      y += 17
    }
    
    if !moreLabel.isHidden {
      moreLabel.frame = CGRect(x: inset, y: y + 2, width: width, height: 18)
      y += 20
    }
  }

  @objc private func handleHeaderTap() {
    onToggleExpand?()
  }
  
  @objc private func handleReviewTap() {
    onReviewTapped?()
  }
  
  @objc private func handleFileTap(_ gesture: UITapGestureRecognizer) {
    guard let view = gesture.view as? FileRowView, view.tag >= 0,
          let files = runtime?.diff?.files, view.tag < files.count else { return }
    onFileTapped?(files[view.tag])
  }
}

// MARK: - AgentRuntimeTaskViewController

final class AgentRuntimeTaskViewController: UITabBarController {
  private let row: ChatListRow
  private let runtime: ChatListRow.AgentRuntimeSummary
  private let appearance: ChatListAppearance
  private let chatId: String
  private let fallbackProvider: String?

  private let messagesView = ChatNativeAgentMessagesView()
  private let statusLabel = UILabel()

  init(
    row: ChatListRow,
    runtime: ChatListRow.AgentRuntimeSummary,
    appearance: ChatListAppearance,
    chatId: String,
    fallbackProvider: String?
  ) {
    self.row = row
    self.runtime = runtime
    self.appearance = appearance
    self.chatId = chatId
    self.fallbackProvider = fallbackProvider
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear

    let tabAppearance = UITabBarAppearance()
    tabAppearance.configureWithTransparentBackground()
    tabBar.standardAppearance = tabAppearance
    tabBar.scrollEdgeAppearance = tabAppearance
    tabBar.tintColor = appearance.isDark ? .white : .black
    tabBar.unselectedItemTintColor = (appearance.isDark ? UIColor.white : UIColor.black).withAlphaComponent(0.4)

    let reviewVC = AgentRuntimeTabReviewViewController(patch: runtime.diff?.patch ?? "", appearance: appearance)
    reviewVC.tabBarItem = UITabBarItem(title: "Review", image: UIImage(systemName: "doc.text.magnifyingglass"), tag: 0)

    let filesVC = AgentRuntimeFilesViewController(
      runtime: runtime,
      appearance: appearance,
      chatId: chatId,
      provider: providerForControl()
    )
    filesVC.tabBarItem = UITabBarItem(title: "Files", image: UIImage(systemName: "folder"), tag: 1)

    let consoleVC = AgentRuntimeTabConsoleViewController(messagesView: messagesView)
    consoleVC.tabBarItem = UITabBarItem(title: "Terminal", image: UIImage(systemName: "terminal"), tag: 2)

    self.viewControllers = [reviewVC, filesVC, consoleVC]

    let navBarAppearance = UINavigationBarAppearance()
    navBarAppearance.configureWithTransparentBackground()
    navigationController?.navigationBar.standardAppearance = navBarAppearance
    navigationController?.navigationBar.scrollEdgeAppearance = navBarAppearance
    navigationController?.navigationBar.tintColor = appearance.isDark ? .white : .black

    navigationItem.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .close, target: self, action: #selector(handleDone))

    updateNavigationButtons()
    updateTitle(for: 0)

    messagesView.applyAppearance(appearance)
    messagesView.setRows(
      buildRawRows(),
      topPadding: 10,
      spacerHeight: 0,
      bottomPadding: 18,
      scrollToBottom: false,
      animated: false
    )
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    messagesView.scrollToBottom(animated: false)
  }

  override func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    updateTitle(for: item.tag)
  }

  private func updateTitle(for tag: Int) {
    switch tag {
    case 0:
      title = "Review"
    case 1:
      title = "Files"
    case 2:
      title = "Terminal"
    default:
      title = runtime.provider?.capitalized ?? fallbackProvider?.capitalized ?? "Agent"
    }
  }

  private func updateNavigationButtons() {
    var rightItems: [UIBarButtonItem] = []

    let isRunning = runtime.status == "running" || runtime.controls?.canCancel == true
    if isRunning {
      let stopItem = UIBarButtonItem(
        image: UIImage(systemName: "stop.fill"),
        style: .plain,
        target: self,
        action: #selector(handleStop)
      )
      rightItems.append(stopItem)
    }

    if runtime.controls?.canRevert == true {
      let revertItem = UIBarButtonItem(
        image: UIImage(systemName: "arrow.uturn.backward"),
        style: .plain,
        target: self,
        action: #selector(handleRevert)
      )
      rightItems.append(revertItem)
    }

    let hasPatch = runtime.diff?.patch?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    if hasPatch {
      let copyItem = UIBarButtonItem(
        image: UIImage(systemName: "doc.on.doc"),
        style: .plain,
        target: self,
        action: #selector(handleCopyPatch)
      )
      rightItems.append(copyItem)
    }

    navigationItem.rightBarButtonItems = rightItems
  }

  private func providerForControl() -> String? {
    let provider = runtime.provider ?? fallbackProvider
    let trimmed = provider?.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed?.isEmpty == false ? trimmed : nil
  }

  @objc private func handleDone() {
    dismiss(animated: true)
  }

  @objc private func handleCopyPatch() {
    guard let patch = runtime.diff?.patch, !patch.isEmpty else { return }
    UIPasteboard.general.string = patch
    statusLabel.text = "Patch copied"
    title = "Patch copied"
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
      if let self {
        self.updateTitle(for: self.selectedIndex)
      }
    }
  }

  @objc private func handleStop() {
    sendControl(
      action: "cancel",
      item: navigationItem.rightBarButtonItems?.first { $0.action == #selector(AgentRuntimeTaskViewController.handleStop) },
      pendingTitle: "Stopping",
      doneTitle: "Stop Sent"
    )
  }

  @objc private func handleRevert() {
    let alert = UIAlertController(
      title: "Revert Task Changes",
      message: "This asks the bridge to revert only the files reported by this task.",
      preferredStyle: .actionSheet
    )
    alert.addAction(UIAlertAction(title: "Revert", style: .destructive) { [weak self] _ in
      self?.sendControl(
        action: "revert",
        item: self?.navigationItem.rightBarButtonItems?.first { $0.action == #selector(AgentRuntimeTaskViewController.handleRevert) },
        pendingTitle: "Reverting",
        doneTitle: "Revert Sent"
      )
    })
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    if let popover = alert.popoverPresentationController {
      popover.barButtonItem = navigationItem.rightBarButtonItems?.first { $0.action == #selector(AgentRuntimeTaskViewController.handleRevert) }
    }
    present(alert, animated: true)
  }

  private func sendControl(
    action: String,
    item: UIBarButtonItem?,
    pendingTitle: String,
    doneTitle: String
  ) {
    guard let provider = providerForControl(), !chatId.isEmpty else {
      statusLabel.text = "Bridge control unavailable"
      title = "Control unavailable"
      return
    }
    item?.isEnabled = false
    statusLabel.text = pendingTitle
    title = pendingTitle
    var payload: [String: Any] = [
      "chatId": chatId,
      "provider": provider,
      "action": action,
    ]
    if let taskId = runtime.taskId, !taskId.isEmpty {
      payload["taskId"] = taskId
    }
    // Supervisor team: cancel the whole run (lead + under-hood workers).
    if let teamRunId = runtime.teamRunId, !teamRunId.isEmpty,
      action == "cancel" || action == "stop"
    {
      payload["teamRunId"] = teamRunId
    }
    let result = ChatEngine.shared.sendAgentBridgeControl(payload)
    if (result["accepted"] as? Bool) == true {
      statusLabel.text = doneTitle
      title = doneTitle
    } else {
      let reason = (result["reason"] as? String) ?? "not accepted"
      statusLabel.text = "Control failed: \(reason)"
      title = "Control failed"
      item?.isEnabled = true
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
      if let self {
        self.updateTitle(for: self.selectedIndex)
      }
    }
  }

  private func buildRawRows() -> [[String: Any]] {
    var rows: [[String: Any]] = []
    let timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
    rows.append([
      "kind": "day",
      "key": "runtime-day-\(row.messageId ?? row.key)",
      "label": "Task",
      "timestampMs": timestampMs,
    ])

    let resultText = (row.plainContent ?? row.text).trimmingCharacters(in: .whitespacesAndNewlines)
    let runtimeMessageId = row.messageId ?? row.key
    rows.append(agentMessageRow(
      key: "runtime-result-\(runtimeMessageId)",
      id: runtimeMessageId,
      text: resultText.isEmpty ? statusText() : resultText,
      timestamp: row.timestamp,
      metadata: ["agentRuntime": runtimePayloadDictionary(runtime)]
    ))

    let details = runtimeDetailsText().trimmingCharacters(in: .whitespacesAndNewlines)
    if !details.isEmpty {
      rows.append(agentMessageRow(
        key: "runtime-details-\(runtimeMessageId)",
        id: "\(runtimeMessageId)-details",
        text: details,
        timestamp: row.timestamp,
        metadata: [:]
      ))
    }

    if let patch = runtime.diff?.patch?.trimmingCharacters(in: .whitespacesAndNewlines), !patch.isEmpty {
      let truncated = runtime.diff?.patchTruncated == true ? "\n\nPatch truncated by bridge payload limit." : ""
      rows.append(agentMessageRow(
        key: "runtime-patch-\(runtimeMessageId)",
        id: "\(runtimeMessageId)-patch",
        text: "```diff\n\(patch)\n```\n\(truncated)",
        timestamp: row.timestamp,
        metadata: [:]
      ))
    }

    return rows
  }

  private func agentMessageRow(
    key: String,
    id: String,
    text: String,
    timestamp: String,
    metadata: [String: Any]
  ) -> [String: Any] {
    var message: [String: Any] = [
      "id": id,
      "key": key,
      "text": text,
      "senderId": "agent",
      "senderName": runtime.provider?.capitalized ?? "Agent",
      "timestamp": timestamp,
      "me": false,
      "type": 0,
      "metadata": metadata,
      "bubbleShape": [
        "showTail": true,
        "borderTopLeftRadius": 18,
        "borderTopRightRadius": 18,
        "borderBottomLeftRadius": 18,
        "borderBottomRightRadius": 18,
      ],
    ]

    if metadata.isEmpty {
      message.removeValue(forKey: "metadata")
    }

    return [
      "kind": "message",
      "key": key,
      "message": message,
    ]
  }

  private func runtimePayloadDictionary(_ runtime: ChatListRow.AgentRuntimeSummary) -> [String: Any] {
    var payload: [String: Any] = [
      "status": runtime.status,
      "dirtyBefore": runtime.dirtyBefore,
      "dirtyBeforeCount": runtime.dirtyBeforeCount,
    ]
    put(runtime.taskId, into: &payload, key: "taskId")
    put(runtime.provider, into: &payload, key: "provider")
    put(runtime.repoName, into: &payload, key: "repoName")
    put(runtime.cwd, into: &payload, key: "cwd")
    put(runtime.workMode, into: &payload, key: "workMode")
    put(runtime.model, into: &payload, key: "model")
    put(runtime.advisor, into: &payload, key: "advisor")
    put(runtime.permissionMode, into: &payload, key: "permissionMode")
    put(runtime.sessionId, into: &payload, key: "sessionId")
    put(runtime.threadId, into: &payload, key: "threadId")
    put(runtime.cliVersion, into: &payload, key: "cliVersion")
    if let durationMs = runtime.durationMs { payload["durationMs"] = durationMs }
    if let exitStatus = runtime.exitStatus { payload["exitStatus"] = exitStatus }
    if let command = runtime.command {
      var commandPayload: [String: Any] = [:]
      put(command.executable, into: &commandPayload, key: "executable")
      put(command.display, into: &commandPayload, key: "display")
      payload["command"] = commandPayload
    }
    if let diff = runtime.diff {
      payload["diff"] = [
        "filesChanged": diff.filesChanged,
        "additions": diff.additions,
        "deletions": diff.deletions,
        "files": diff.files.map { file in
          [
            "path": file.path,
            "name": file.name,
            "status": file.status,
            "additions": file.additions,
            "deletions": file.deletions,
          ]
        },
        "patch": diff.patch ?? "",
        "patchTruncated": diff.patchTruncated,
      ]
    }
    if let controls = runtime.controls {
      payload["controls"] = [
        "canCancel": controls.canCancel,
        "canRevert": controls.canRevert,
      ]
    }
    if let usage = runtime.usage {
      var usagePayload: [String: Any] = [:]
      if let value = usage.inputTokens { usagePayload["inputTokens"] = value }
      if let value = usage.cachedInputTokens { usagePayload["cachedInputTokens"] = value }
      if let value = usage.cacheCreationInputTokens { usagePayload["cacheCreationInputTokens"] = value }
      if let value = usage.outputTokens { usagePayload["outputTokens"] = value }
      if let value = usage.reasoningOutputTokens { usagePayload["reasoningOutputTokens"] = value }
      if let value = usage.totalCostUsd { usagePayload["totalCostUsd"] = value }
      if let value = usage.durationMs { usagePayload["durationMs"] = value }
      if let value = usage.durationApiMs { usagePayload["durationApiMs"] = value }
      if let value = usage.ttftMs { usagePayload["ttftMs"] = value }
      if let value = usage.ttftStreamMs { usagePayload["ttftStreamMs"] = value }
      if let value = usage.numTurns { usagePayload["numTurns"] = value }
      if !usagePayload.isEmpty { payload["usage"] = usagePayload }
    }
    if !runtime.availableTools.isEmpty { payload["availableTools"] = runtime.availableTools }
    if !runtime.slashCommands.isEmpty { payload["slashCommands"] = runtime.slashCommands }
    if !runtime.cliCommands.isEmpty { payload["cliCommands"] = runtime.cliCommands }
    if !runtime.providerCommands.isEmpty { payload["providerCommands"] = runtime.providerCommands }
    if !runtime.mcpServers.isEmpty {
      payload["mcpServers"] = runtime.mcpServers.map { server in
        var item: [String: Any] = ["name": server.name]
        put(server.status, into: &item, key: "status")
        return item
      }
    }
    if !runtime.agents.isEmpty { payload["agents"] = runtime.agents }
    if !runtime.skills.isEmpty { payload["skills"] = runtime.skills }
    return payload
  }

  private func put(_ value: String?, into payload: inout [String: Any], key: String) {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    payload[key] = value
  }

  private func statusText() -> String {
    var parts: [String] = []
    if let repo = runtime.repoName, !repo.isEmpty { parts.append(repo) }
    if let cwd = runtime.cwd, !cwd.isEmpty { parts.append(cwd) }
    if let mode = runtime.workMode, !mode.isEmpty {
      parts.append(mode.replacingOccurrences(of: "_", with: " "))
    }
    if let duration = runtime.durationMs, duration > 0 {
      parts.append(String(format: "%.1fs", Double(duration) / 1000.0))
    }
    if runtime.status == "failed", let exit = runtime.exitStatus {
      parts.append("exit \(exit)")
    } else {
      parts.append(runtime.status)
    }
    return parts.joined(separator: "  ")
  }

  private func runtimeDetailsText() -> String {
    var sections: [String] = []
    var overview: [String] = []
    if let model = runtime.model, !model.isEmpty { overview.append("model: \(model)") }
    if let advisor = runtime.advisor, !advisor.isEmpty { overview.append("advisor: \(advisor)") }
    if let permission = runtime.permissionMode, !permission.isEmpty { overview.append("permission: \(permission)") }
    if let cli = runtime.cliVersion, !cli.isEmpty { overview.append("cli: \(cli)") }
    if let session = runtime.sessionId, !session.isEmpty { overview.append("session: \(shortId(session))") }
    if let thread = runtime.threadId, !thread.isEmpty { overview.append("thread: \(shortId(thread))") }
    if !overview.isEmpty {
      sections.append("Runtime\n" + overview.joined(separator: "\n"))
    }
    if let usageText = usageText(runtime.usage) {
      sections.append("Usage\n\(usageText)")
    }
    if !runtime.providerCommands.isEmpty {
      sections.append("Bridge commands\n" + runtime.providerCommands.prefix(8).joined(separator: "  "))
    }
    if !runtime.slashCommands.isEmpty {
      sections.append("Provider slash commands\n" + runtime.slashCommands.prefix(18).map { "/\($0)" }.joined(separator: "  "))
    }
    if !runtime.cliCommands.isEmpty {
      sections.append("CLI commands\n" + runtime.cliCommands.prefix(18).joined(separator: "  "))
    }
    if !runtime.availableTools.isEmpty {
      sections.append("Tools\n" + runtime.availableTools.prefix(20).joined(separator: "  "))
    }
    if !runtime.mcpServers.isEmpty {
      sections.append("MCP\n" + runtime.mcpServers.prefix(8).map { server in
        if let status = server.status, !status.isEmpty {
          return "\(server.name): \(status)"
        }
        return server.name
      }.joined(separator: "\n"))
    }
    return sections.joined(separator: "\n\n")
  }
}

fileprivate func shortId(_ value: String) -> String {
  guard value.count > 12 else { return value }
  return "\(value.prefix(8))...\(value.suffix(4))"
}

fileprivate func usageText(_ usage: ChatListRow.AgentRuntimeUsage?) -> String? {
  guard let usage else { return nil }
  var parts: [String] = []
  if let value = usage.inputTokens { parts.append("input \(value)") }
  if let value = usage.cachedInputTokens { parts.append("cached \(value)") }
  if let value = usage.outputTokens { parts.append("output \(value)") }
  if let value = usage.reasoningOutputTokens { parts.append("reasoning \(value)") }
  if let value = usage.totalCostUsd { parts.append(String(format: "cost $%.4f", value)) }
  if let value = usage.ttftMs { parts.append(String(format: "ttft %.1fs", Double(value) / 1000.0)) }
  if let value = usage.durationMs { parts.append(String(format: "duration %.1fs", Double(value) / 1000.0)) }
  return parts.isEmpty ? nil : parts.joined(separator: "  ")
}

// MARK: - Tab Sub-controllers

class AgentRuntimeTabReviewViewController: UIViewController {
  private let patch: String
  private let appearance: ChatListAppearance
  private let textView = UITextView()

  init(patch: String, appearance: ChatListAppearance) {
    self.patch = patch
    self.appearance = appearance
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { return nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear

    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.isEditable = false
    textView.alwaysBounceVertical = true
    textView.backgroundColor = .clear
    textView.textColor = appearance.isDark ? .white : .label
    textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
    textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
    view.addSubview(textView)

    NSLayoutConstraint.activate([
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      textView.topAnchor.constraint(equalTo: view.topAnchor),
      textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    if !patch.isEmpty {
      let isDark = appearance.isDark
      let font = UIFont.monospacedSystemFont(ofSize: 13.0, weight: .regular)
      let customDiffView = diffLayoutViewForAppearance(
        patch: patch,
        isDark: isDark,
        textColor: appearance.isDark ? .white : .black,
        primaryColor: ChatListAppearance.brandAccentFallback,
        textSecondary: .lightGray,
        font: font
      )
      customDiffView.translatesAutoresizingMaskIntoConstraints = false

      let scrollView = UIScrollView()
      scrollView.translatesAutoresizingMaskIntoConstraints = false
      scrollView.backgroundColor = .clear
      scrollView.alwaysBounceVertical = true
      view.addSubview(scrollView)

      scrollView.addSubview(customDiffView)

      NSLayoutConstraint.activate([
        scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        scrollView.topAnchor.constraint(equalTo: view.topAnchor),
        scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

        customDiffView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
        customDiffView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
        customDiffView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
        customDiffView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
        customDiffView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
      ])

      textView.isHidden = true
    } else {
      textView.text = "No diff available."
    }
  }
}

class AgentRuntimeTabConsoleViewController: UIViewController {
  private let messagesView: ChatNativeAgentMessagesView

  init(messagesView: ChatNativeAgentMessagesView) {
    self.messagesView = messagesView
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { return nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear

    messagesView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(messagesView)

    NSLayoutConstraint.activate([
      messagesView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      messagesView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      messagesView.topAnchor.constraint(equalTo: view.topAnchor),
      messagesView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }
}

fileprivate func diffLayoutViewForAppearance(
  patch: String,
  isDark: Bool,
  textColor: UIColor,
  primaryColor: UIColor,
  textSecondary: UIColor,
  font: UIFont
) -> UIView {
  let box = UIView()
  box.translatesAutoresizingMaskIntoConstraints = false
  box.backgroundColor = .clear

  let stack = UIStackView()
  stack.translatesAutoresizingMaskIntoConstraints = false
  stack.axis = .vertical
  stack.spacing = 0
  box.addSubview(stack)

  NSLayoutConstraint.activate([
    stack.topAnchor.constraint(equalTo: box.topAnchor),
    stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
    stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
    stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
  ])

  var lines = patch.components(separatedBy: "\n")
  if lines.last?.isEmpty == true {
    lines.removeLast()
  }

  let faint = textSecondary.withAlphaComponent(0.55)

  for line in lines {
    if line.hasPrefix("diff ") || line.hasPrefix("---") || line.hasPrefix("+++") || line.hasPrefix("@@") || line.hasPrefix("index ") || line.hasPrefix("new file ") || line.hasPrefix("deleted file ") {
      continue
    }

    let lineRow = UIView()
    lineRow.translatesAutoresizingMaskIntoConstraints = false

    let isAddition = line.hasPrefix("+")
    let isDeletion = line.hasPrefix("-")

    if isAddition {
      lineRow.backgroundColor = VibeAgentDiffPalette.additionBackground(isDark: isDark)
    } else if isDeletion {
      lineRow.backgroundColor = VibeAgentDiffPalette.deletionBackground(isDark: isDark)
    }

    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = font
    label.numberOfLines = 0
    label.lineBreakMode = .byCharWrapping

    if isAddition || isDeletion {
      label.textColor = .white
    } else {
      label.textColor = textColor
    }

    let displayLine: String
    if line.isEmpty {
      displayLine = line
    } else {
      let firstChar = line.first!
      if firstChar == "+" || firstChar == "-" || firstChar == " " {
        displayLine = String(line.dropFirst())
      } else {
        displayLine = line
      }
    }

    label.text = displayLine
    lineRow.addSubview(label)

    NSLayoutConstraint.activate([
      label.topAnchor.constraint(equalTo: lineRow.topAnchor, constant: 4.0),
      label.bottomAnchor.constraint(equalTo: lineRow.bottomAnchor, constant: -4.0),
      label.leadingAnchor.constraint(equalTo: lineRow.leadingAnchor, constant: 16.0),
      label.trailingAnchor.constraint(equalTo: lineRow.trailingAnchor, constant: -16.0),
    ])

    stack.addArrangedSubview(lineRow)
  }

  return box
}


final class AgentRuntimeFilesViewController: UITableViewController {
  private let runtime: ChatListRow.AgentRuntimeSummary
  private let appearance: ChatListAppearance
  private let files: [ChatListRow.AgentRuntimeFile]
  private let chatId: String?
  private let provider: String?

  init(
    runtime: ChatListRow.AgentRuntimeSummary,
    appearance: ChatListAppearance,
    chatId: String? = nil,
    provider: String? = nil
  ) {
    self.runtime = runtime
    self.appearance = appearance
    self.files = runtime.diff?.files ?? []
    self.chatId = chatId
    self.provider = provider
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Files"
    view.backgroundColor = appearance.isDark ? .black : .systemGroupedBackground
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "file")
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    files.count
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  ) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "file", for: indexPath)
    let file = files[indexPath.row]
    var content = UIListContentConfiguration.subtitleCell()
    content.text = file.name
    content.secondaryText = "\(file.path)   +\(file.additions) -\(file.deletions)"
    content.textProperties.font = .systemFont(ofSize: 15, weight: .semibold)
    content.secondaryTextProperties.font = .systemFont(ofSize: 12, weight: .regular)
    cell.contentConfiguration = content
    cell.accessoryType = .disclosureIndicator
    cell.backgroundColor = appearance.isDark ? UIColor.white.withAlphaComponent(0.06) : .secondarySystemGroupedBackground
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let file = files[indexPath.row]
    let controller = AgentRuntimePatchPreviewController(
      file: file,
      patch: runtime.diff?.patch ?? "",
      patchTruncated: runtime.diff?.patchTruncated == true,
      appearance: appearance,
      chatId: chatId,
      provider: provider ?? runtime.provider,
      presentedAsSheet: true
    )
    // The +/- patch opens as a bottom sheet (not another pushed page), so the file
    // list stays underneath and the user can flick between files quickly.
    let nav = UINavigationController(rootViewController: controller)
    nav.modalPresentationStyle = .pageSheet
    if let sheet = nav.sheetPresentationController {
      sheet.detents = [.medium(), .large()]
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 20
      sheet.prefersScrollingExpandsWhenScrolledToEdge = true
    }
    present(nav, animated: true)
  }
}

private final class AgentRuntimePatchPreviewController: UIViewController {
  private let file: ChatListRow.AgentRuntimeFile
  private let patch: String
  private let patchTruncated: Bool
  private let appearance: ChatListAppearance
  private let chatId: String?
  private let provider: String?
  private let presentedAsSheet: Bool
  private let textView = UITextView()

  init(
    file: ChatListRow.AgentRuntimeFile,
    patch: String,
    patchTruncated: Bool,
    appearance: ChatListAppearance,
    chatId: String? = nil,
    provider: String? = nil,
    presentedAsSheet: Bool = false
  ) {
    self.file = file
    self.patch = patch
    self.patchTruncated = patchTruncated
    self.appearance = appearance
    self.chatId = chatId
    self.provider = provider
    self.presentedAsSheet = presentedAsSheet
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = file.name
    view.backgroundColor = .clear

    let navBarAppearance = UINavigationBarAppearance()
    navBarAppearance.configureWithTransparentBackground()
    navigationController?.navigationBar.standardAppearance = navBarAppearance
    navigationController?.navigationBar.scrollEdgeAppearance = navBarAppearance
    navigationController?.navigationBar.tintColor = appearance.isDark ? .white : .black

    var rightItems = [
      UIBarButtonItem(
        image: UIImage(systemName: "doc.on.doc"),
        style: .plain,
        target: self,
        action: #selector(handleCopy)
      )
    ]
    // Open the FULL file (fetched from the bridge, E2E) when we know the chat +
    // provider to route the request — like the Codex/ChatGPT mobile file view.
    if let chatId, !chatId.isEmpty, let provider, !provider.isEmpty {
      rightItems.append(
        UIBarButtonItem(
          image: UIImage(systemName: "doc.text.magnifyingglass"),
          style: .plain,
          target: self,
          action: #selector(handleOpenFile)
        )
      )
    }
    navigationItem.rightBarButtonItems = rightItems
    if presentedAsSheet {
      navigationItem.leftBarButtonItem = UIBarButtonItem(
        barButtonSystemItem: .close,
        target: self,
        action: #selector(handleDone)
      )
    }

    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.isEditable = false
    textView.alwaysBounceVertical = true
    textView.backgroundColor = .clear
    textView.textColor = appearance.isDark ? .white : .label
    textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
    textView.textContainerInset = UIEdgeInsets(top: 64, left: 12, bottom: 24, right: 12)
    view.addSubview(textView)

    NSLayoutConstraint.activate([
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      textView.topAnchor.constraint(equalTo: view.topAnchor),
      textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    textView.attributedText = attributedPreview()
  }

  private func previewText() -> String {
    let chunk = diffChunk(for: file.path, patch: patch)
    if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return patchTruncated ? chunk + "\n\n[Patch truncated]" : chunk
    }
    return """
    \(file.path)
    status: \(file.status)
    additions: \(file.additions)
    deletions: \(file.deletions)

    No per-file patch was included in this payload.
    """
  }

  /// Renders the unified diff with GitHub-style coloring: added lines green,
  /// removed lines red, hunk headers tinted, file metadata muted.
  private func attributedPreview() -> NSAttributedString {
    let font = UIFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    let baseColor: UIColor = appearance.isDark ? .white : .label
    let muted: UIColor = appearance.isDark
      ? UIColor.white.withAlphaComponent(0.45) : UIColor.label.withAlphaComponent(0.45)
    let addText = VibeAgentDiffPalette.additionText
    let delText = VibeAgentDiffPalette.deletionText
    let addBg = VibeAgentDiffPalette.additionBackground(isDark: appearance.isDark)
    let delBg = VibeAgentDiffPalette.deletionBackground(isDark: appearance.isDark)
    let hunkColor: UIColor = appearance.isDark
      ? UIColor.systemTeal : UIColor.systemBlue

    let result = NSMutableAttributedString()
    let lines = previewText().components(separatedBy: "\n")
    for (idx, line) in lines.enumerated() {
      let text = idx == lines.count - 1 ? line : line + "\n"
      var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: baseColor]
      if line.hasPrefix("+++") || line.hasPrefix("---")
        || line.hasPrefix("diff --git") || line.hasPrefix("index ")
        || line.hasPrefix("new file") || line.hasPrefix("deleted file")
        || line.hasPrefix("rename ") || line.hasPrefix("similarity ") {
        attrs[.foregroundColor] = muted
      } else if line.hasPrefix("@@") {
        attrs[.foregroundColor] = hunkColor
      } else if line.hasPrefix("+") {
        attrs[.foregroundColor] = baseColor
        attrs[.backgroundColor] = addBg
      } else if line.hasPrefix("-") {
        attrs[.foregroundColor] = baseColor
        attrs[.backgroundColor] = delBg
      } else if line.hasPrefix("[Patch truncated]") {
        attrs[.foregroundColor] = muted
      }
      result.append(NSAttributedString(string: text, attributes: attrs))
    }
    return result
  }

  @objc private func handleDone() {
    dismiss(animated: true)
  }

  private func diffChunk(for path: String, patch: String) -> String {
    let lines = patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var chunks: [[String]] = []
    var current: [String] = []

    for line in lines {
      if line.hasPrefix("diff --git ") && !current.isEmpty {
        chunks.append(current)
        current = [line]
      } else {
        current.append(line)
      }
    }
    if !current.isEmpty { chunks.append(current) }

    for chunk in chunks {
      let joined = chunk.joined(separator: "\n")
      if joined.contains(" b/\(path)") || joined.contains(" a/\(path)")
        || joined.contains("+++ b/\(path)") || joined.contains("--- a/\(path)")
      {
        return joined
      }
    }
    return ""
  }

  @objc private func handleCopy() {
    UIPasteboard.general.string = textView.text
  }

  @objc private func handleOpenFile() {
    guard let chatId, let provider else { return }
    let viewer = AgentBridgeFileViewerController(
      chatId: chatId,
      provider: provider,
      path: file.path,
      fileName: file.name,
      appearance: appearance
    )
    if let nav = navigationController {
      // Inside a sheet, expand to full height first so the file is readable.
      if let sheet = nav.sheetPresentationController {
        sheet.animateChanges { sheet.selectedDetentIdentifier = .large }
      }
      nav.pushViewController(viewer, animated: true)
    } else {
      present(UINavigationController(rootViewController: viewer), animated: true)
    }
  }
}

// MARK: - AgentBridgeFileViewerController

/// Shows the FULL contents of a file the agent touched, fetched on demand from
/// the user's bridge. The bytes travel E2E-encrypted (`agentFileEnc`); the
/// server only relays the opaque blob. Mirrors the Codex/ChatGPT mobile file view.
final class AgentBridgeFileViewerController: UIViewController {
  private let chatId: String
  private let provider: String
  private let path: String
  private let fileName: String
  private let appearance: ChatListAppearance
  private let requestId = UUID().uuidString

  private let textView = UITextView()
  private let spinner = UIActivityIndicatorView(style: .large)
  private let statusLabel = UILabel()
  private var observer: NSObjectProtocol?
  private var finished = false

  init(
    chatId: String,
    provider: String,
    path: String,
    fileName: String,
    appearance: ChatListAppearance
  ) {
    self.chatId = chatId
    self.provider = provider
    self.path = path
    self.fileName = fileName
    self.appearance = appearance
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { return nil }

  deinit {
    if let observer { NotificationCenter.default.removeObserver(observer) }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = fileName
    view.backgroundColor = appearance.isDark ? .black : .systemBackground
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      image: UIImage(systemName: "doc.on.doc"),
      style: .plain,
      target: self,
      action: #selector(handleCopy)
    )

    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.isEditable = false
    textView.isHidden = true
    textView.alwaysBounceVertical = true
    textView.backgroundColor = .clear
    textView.textColor = appearance.isDark ? .white : .label
    textView.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
    textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
    view.addSubview(textView)

    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    statusLabel.numberOfLines = 0
    statusLabel.textAlignment = .center
    statusLabel.font = .systemFont(ofSize: 14)
    statusLabel.textColor = appearance.isDark ? UIColor.white.withAlphaComponent(0.6) : .secondaryLabel
    statusLabel.text = "Loading file from your computer…"
    view.addSubview(statusLabel)

    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.color = appearance.isDark ? .white : .gray
    spinner.startAnimating()
    view.addSubview(spinner)

    NSLayoutConstraint.activate([
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
      statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
      statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
    ])

    observer = NotificationCenter.default.addObserver(
      forName: ChatEngine.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard let self else { return }
      guard (note.userInfo?["reason"] as? String) == "agentBridgeFile" else { return }
      guard (note.userInfo?["requestId"] as? String) == self.requestId else { return }
      self.deliver()
    }

    let result = ChatEngine.shared.requestAgentBridgeFile([
      "chatId": chatId,
      "provider": provider,
      "path": path,
      "requestId": requestId,
    ])
    if (result["accepted"] as? Bool) != true {
      let reason = (result["reason"] as? String) ?? "request_failed"
      fail("Couldn't reach your computer (\(reason)). Make sure the bridge is running.")
      return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
      guard let self, !self.finished else { return }
      self.fail("Timed out waiting for the file from your computer.")
    }
  }

  private func deliver() {
    guard !finished else { return }
    guard let payload = ChatEngine.shared.latestAgentBridgeFile(requestId: requestId) else { return }
    if (payload["ok"] as? Bool) == false {
      fail((payload["message"] as? String) ?? "The file could not be read.")
      return
    }
    guard let decrypted = AgentRuntimeCrypto.decrypt(payload["agentFileEnc"]),
      let content = decrypted["content"] as? String
    else {
      fail("This file is sealed and can't be opened on this phone yet — sync the encryption key from the bridge.")
      return
    }
    finished = true
    spinner.stopAnimating()
    statusLabel.isHidden = true
    textView.isHidden = false
    let truncated = (decrypted["truncated"] as? Bool) == true
    textView.text = truncated ? content + "\n\n[File truncated — too large to show in full]" : content
  }

  private func fail(_ message: String) {
    guard !finished else { return }
    finished = true
    spinner.stopAnimating()
    textView.isHidden = true
    statusLabel.isHidden = false
    statusLabel.text = message
  }

  @objc private func handleCopy() {
    UIPasteboard.general.string = textView.text
  }
}

// MARK: - AgentIntegrationPackView

final class AgentIntegrationPackView: UIControl, UIGestureRecognizerDelegate {
  /// Same rule as `AgentCodeBlockView`: reachable from a measurement pass, so it is
  /// guarded even though `measuredHeight` is a constant today and does not read it.
  private static var expandedStorageKeys = Set<String>()
  private static let expandedStorageKeysLock = NSLock()
  private static let collapsedHeight: CGFloat = 72.0

  private static func isStorageKeyExpanded(_ key: String) -> Bool {
    expandedStorageKeysLock.lock()
    defer { expandedStorageKeysLock.unlock() }
    return expandedStorageKeys.contains(key)
  }

  private let cardView = UIView()
  private let iconView = UIImageView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let actionLabel = UILabel()
  private let chevronView = UIImageView()
  private let dividerView = UIView()
  private let environmentTitleLabel = UILabel()
  private let environmentView = UIView()
  private let environmentLabel = UILabel()
  private let copyButton = UIButton(type: .system)
  private let endpointsTitleLabel = UILabel()
  private let endpointsLabel = UILabel()

  private var currentPack: AgentIntegrationPack?
  private var currentStorageKey = ""
  private var currentAvailableWidth: CGFloat = 0
  private var currentTextColor = UIColor.label
  private var isExpanded = false

  static func isExpanded(pack: AgentIntegrationPack, storageKey: String? = nil) -> Bool {
    isStorageKeyExpanded(resolvedStorageKey(pack: pack, storageKey: storageKey))
  }

  static func measuredHeight(
    pack: AgentIntegrationPack,
    availableWidth: CGFloat,
    storageKey: String? = nil
  ) -> CGFloat {
    return collapsedHeight
  }

  private static func resolvedStorageKey(
    pack: AgentIntegrationPack,
    storageKey: String?
  ) -> String {
    let override = storageKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return override.isEmpty ? pack.storageKey : override
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    cardView.isUserInteractionEnabled = true
    cardView.layer.cornerRadius = 14.0
    cardView.layer.cornerCurve = .continuous
    cardView.clipsToBounds = true
    addSubview(cardView)

    iconView.contentMode = .center
    iconView.layer.cornerRadius = 18.0
    iconView.layer.cornerCurve = .continuous
    cardView.addSubview(iconView)

    titleLabel.font = .systemFont(ofSize: 14.0, weight: .semibold)
    cardView.addSubview(titleLabel)

    subtitleLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
    subtitleLabel.lineBreakMode = .byTruncatingTail
    cardView.addSubview(subtitleLabel)

    actionLabel.font = .systemFont(ofSize: 12.0, weight: .semibold)
    actionLabel.textAlignment = .right
    cardView.addSubview(actionLabel)

    chevronView.contentMode = .scaleAspectFit
    cardView.addSubview(chevronView)

    cardView.addSubview(dividerView)

    environmentTitleLabel.text = "ENVIRONMENT"
    environmentTitleLabel.font = .systemFont(ofSize: 10.0, weight: .semibold)
    cardView.addSubview(environmentTitleLabel)

    environmentView.layer.cornerRadius = 10.0
    environmentView.layer.cornerCurve = .continuous
    cardView.addSubview(environmentView)

    environmentLabel.numberOfLines = 0
    environmentLabel.font = .monospacedSystemFont(ofSize: 12.0, weight: .regular)
    environmentView.addSubview(environmentLabel)

    copyButton.setImage(
      UIImage(
        systemName: "doc.on.doc",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 12.0, weight: .medium)
      ),
      for: .normal
    )
    copyButton.addTarget(self, action: #selector(handleCopy), for: .touchUpInside)
    environmentView.addSubview(copyButton)

    endpointsTitleLabel.text = "ENDPOINTS"
    endpointsTitleLabel.font = .systemFont(ofSize: 10.0, weight: .semibold)
    cardView.addSubview(endpointsTitleLabel)

    endpointsLabel.numberOfLines = 0
    endpointsLabel.font = .monospacedSystemFont(ofSize: 11.0, weight: .regular)
    endpointsLabel.lineBreakMode = .byTruncatingMiddle
    cardView.addSubview(endpointsLabel)

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleToggle))
    tapGesture.delegate = self
    cardView.addGestureRecognizer(tapGesture)
    accessibilityTraits = .button
  }

  required init?(coder: NSCoder) { return nil }

  @discardableResult
  func configure(
    pack: AgentIntegrationPack,
    textColor: UIColor,
    availableWidth: CGFloat,
    storageKey: String? = nil
  ) -> CGFloat {
    currentPack = pack
    currentAvailableWidth = availableWidth
    currentTextColor = textColor
    currentStorageKey = Self.resolvedStorageKey(pack: pack, storageKey: storageKey)
    isExpanded = Self.isStorageKeyExpanded(currentStorageKey)

    let accent = UIColor.systemTeal
    cardView.backgroundColor = textColor.withAlphaComponent(0.055)
    cardView.layer.borderWidth = 0.5
    cardView.layer.borderColor = textColor.withAlphaComponent(0.14).cgColor
    iconView.backgroundColor = accent.withAlphaComponent(0.16)
    iconView.tintColor = accent
    iconView.image = UIImage(
      systemName: "shippingbox.fill",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 15.0, weight: .semibold)
    )
    titleLabel.text = "Agent pack"
    titleLabel.textColor = textColor
    let identity = pack.username.map { "@\($0)" } ?? pack.displayName
    subtitleLabel.text = "\(identity)  •  \(pack.status.capitalized)"
    subtitleLabel.textColor = textColor.withAlphaComponent(0.62)
    actionLabel.text = "Open"
    actionLabel.textColor = accent
    chevronView.tintColor = accent
    chevronView.image = UIImage(
      systemName: "chevron.right",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 10.0, weight: .semibold)
    )
    dividerView.backgroundColor = textColor.withAlphaComponent(0.10)
    environmentTitleLabel.textColor = textColor.withAlphaComponent(0.48)
    environmentView.backgroundColor = textColor.withAlphaComponent(0.055)
    environmentLabel.text = pack.environment
    environmentLabel.textColor = textColor.withAlphaComponent(0.86)
    copyButton.tintColor = accent
    endpointsTitleLabel.textColor = textColor.withAlphaComponent(0.48)
    endpointsLabel.text = [
      pack.eventsURL.map { "Events  \($0)" },
      pack.invokeURL.map { "Invoke  \($0)" },
    ].compactMap { $0 }.joined(separator: "\n")
    endpointsLabel.textColor = accent

    let hasEndpoints = !(endpointsLabel.text ?? "").isEmpty
    _ = hasEndpoints
    dividerView.isHidden = true
    environmentTitleLabel.isHidden = true
    environmentView.isHidden = true
    endpointsTitleLabel.isHidden = true
    endpointsLabel.isHidden = true

    let height = Self.measuredHeight(
      pack: pack,
      availableWidth: availableWidth,
      storageKey: currentStorageKey
    )
    cardView.frame = CGRect(x: 0.0, y: 0.0, width: availableWidth, height: height)

    iconView.frame = CGRect(x: 12.0, y: 18.0, width: 36.0, height: 36.0)
    let chevronWidth: CGFloat = 12.0
    chevronView.frame = CGRect(
      x: availableWidth - 12.0 - chevronWidth,
      y: 30.0,
      width: chevronWidth,
      height: 12.0
    )
    actionLabel.frame = CGRect(
      x: chevronView.frame.minX - 48.0,
      y: 25.0,
      width: 42.0,
      height: 22.0
    )
    let textX = iconView.frame.maxX + 10.0
    let textWidth = max(1.0, actionLabel.frame.minX - textX - 8.0)
    titleLabel.frame = CGRect(x: textX, y: 17.0, width: textWidth, height: 19.0)
    subtitleLabel.frame = CGRect(x: textX, y: 37.0, width: textWidth, height: 18.0)

    if isExpanded {
      dividerView.frame = CGRect(x: 12.0, y: 71.0, width: availableWidth - 24.0, height: 0.5)
      environmentTitleLabel.frame = CGRect(x: 12.0, y: 83.0, width: availableWidth - 24.0, height: 14.0)
      let environmentY: CGFloat = 103.0
      let endpointCount = [pack.eventsURL, pack.invokeURL].compactMap { $0 }.count
      let endpointBlockHeight: CGFloat = endpointCount > 0 ? 30.0 + CGFloat(endpointCount) * 19.0 : 0.0
      let environmentHeight = max(42.0, height - environmentY - endpointBlockHeight - 12.0)
      environmentView.frame = CGRect(
        x: 12.0,
        y: environmentY,
        width: availableWidth - 24.0,
        height: environmentHeight
      )
      copyButton.frame = CGRect(
        x: environmentView.bounds.width - 38.0,
        y: 4.0,
        width: 34.0,
        height: 34.0
      )
      environmentLabel.frame = CGRect(
        x: 10.0,
        y: 10.0,
        width: environmentView.bounds.width - 54.0,
        height: environmentView.bounds.height - 20.0
      )
      if endpointCount > 0 {
        endpointsTitleLabel.frame = CGRect(
          x: 12.0,
          y: environmentView.frame.maxY + 10.0,
          width: availableWidth - 24.0,
          height: 14.0
        )
        endpointsLabel.frame = CGRect(
          x: 12.0,
          y: endpointsTitleLabel.frame.maxY + 4.0,
          width: availableWidth - 24.0,
          height: CGFloat(endpointCount) * 19.0
        )
      }
    }

    accessibilityLabel = "Agent pack for \(identity)"
    accessibilityValue = isExpanded ? "Expanded" : "Collapsed"
    setNeedsLayout()
    return height
  }

  @objc private func handleToggle() {
    guard let pack = currentPack else { return }
    NotificationCenter.default.post(
      name: Notification.Name("AgentIntegrationPackOpenPanelNotification"),
      object: nil,
      userInfo: ["agentId": pack.agentId, "username": pack.username ?? pack.displayName]
    )
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }

  @objc private func handleCopy() {
    guard let pack = currentPack else { return }
    UIPasteboard.general.string = pack.environment
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldReceive touch: UITouch
  ) -> Bool {
    !(touch.view is UIControl)
  }
}

// MARK: - AgentCodeBlockView

final class AgentCodeBlockView: UIView {
  private static let collapsedLineLimit = 12
  /// Read by `measureBubbleCodeBlockHeight`, which runs off the main thread once a
  /// transcript is measured before it is pushed — while a tap on main can be writing
  /// it. An unguarded `Set` across those two is a data race, and the symptom would be
  /// a corrupt height rather than a crash, i.e. a shift nobody can reproduce.
  private static var expandedStorageKeys = Set<String>()
  private static let expandedStorageKeysLock = NSLock()

  private static func isStorageKeyExpanded(_ key: String) -> Bool {
    expandedStorageKeysLock.lock()
    defer { expandedStorageKeysLock.unlock() }
    return expandedStorageKeys.contains(key)
  }

  private static func setStorageKey(_ key: String, expanded: Bool) {
    expandedStorageKeysLock.lock()
    defer { expandedStorageKeysLock.unlock() }
    if expanded {
      expandedStorageKeys.insert(key)
    } else {
      expandedStorageKeys.remove(key)
    }
  }

  private let cardView = UIView()
  private let topBarView = UIView()
  private let langLabel = UILabel()
  private let scrollView = UIScrollView()
  private let codeLabel = UILabel()
  private let copyButton = UIButton(type: .system)
  private let expandButton = UIButton(type: .system)
  private let copiedLabel = UILabel()
  private var codeContent = ""
  private var codeLang: String?
  private var originalBaseFont = UIFont.systemFont(ofSize: 17.0, weight: .regular)
  private var codeFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
  private var baseTextColor = UIColor.white
  private var isExpanded = false
  private let maxCollapsedLines = AgentCodeBlockView.collapsedLineLimit
  private var totalLineCount = 0
  private var copyFeedbackWork: DispatchWorkItem?
  private var currentAvailableWidth: CGFloat = 0
  private var expansionStorageKey = ""

  static func storageKey(code: String, language: String? = nil, override: String? = nil) -> String {
    let trimmedOverride = override?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmedOverride.isEmpty {
      return trimmedOverride
    }
    return (language ?? "") + "\n" + code
  }

  static func isExpanded(code: String, language: String? = nil, storageKey: String? = nil) -> Bool {
    isStorageKeyExpanded(Self.storageKey(code: code, language: language, override: storageKey))
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    clipsToBounds = true

    cardView.layer.cornerRadius = 10.0
    cardView.layer.cornerCurve = .continuous
    cardView.clipsToBounds = true
    addSubview(cardView)

    topBarView.backgroundColor = UIColor(white: 0.5, alpha: 0.06)
    cardView.addSubview(topBarView)

    langLabel.font = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
    langLabel.textColor = UIColor(white: 0.65, alpha: 0.9)
    topBarView.addSubview(langLabel)

    scrollView.showsHorizontalScrollIndicator = false
    scrollView.showsVerticalScrollIndicator = false
    scrollView.bounces = true
    cardView.addSubview(scrollView)

    codeLabel.numberOfLines = 0
    codeLabel.backgroundColor = .clear
    scrollView.addSubview(codeLabel)

    let cfg = UIImage.SymbolConfiguration(pointSize: 12.0, weight: .medium)
    copyButton.setImage(UIImage(systemName: "square.on.square", withConfiguration: cfg), for: .normal)
    copyButton.tintColor = UIColor(white: 0.65, alpha: 0.9)
    copyButton.addTarget(self, action: #selector(handleCopy), for: .touchUpInside)
    topBarView.addSubview(copyButton)

    expandButton.setImage(UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: cfg), for: .normal)
    expandButton.tintColor = UIColor(white: 0.65, alpha: 0.9)
    expandButton.addTarget(self, action: #selector(handleExpand), for: .touchUpInside)
    topBarView.addSubview(expandButton)

    copiedLabel.text = "Copied!"
    copiedLabel.font = .systemFont(ofSize: 11.0, weight: .medium)
    copiedLabel.textColor = UIColor.systemGreen
    copiedLabel.alpha = 0
    topBarView.addSubview(copiedLabel)
  }

  required init?(coder: NSCoder) { return nil }

  private var preferredCardHeight: CGFloat = 1.0

  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: max(1.0, preferredCardHeight))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let w = bounds.width
    guard w > 1.0, !codeContent.isEmpty else { return }
    if abs(w - currentAvailableWidth) > 0.5 {
      _ = configure(
        code: codeContent,
        language: codeLang,
        textColor: baseTextColor,
        baseFont: originalBaseFont,
        availableWidth: w,
        storageKey: expansionStorageKey
      )
    }
  }

  @discardableResult
  func configure(
    code: String,
    language: String? = nil,
    textColor: UIColor,
    baseFont: UIFont,
    availableWidth: CGFloat,
    storageKey: String? = nil
  ) -> CGFloat {
    codeContent = code
    codeLang = language
    baseTextColor = textColor
    currentAvailableWidth = availableWidth
    originalBaseFont = baseFont
    expansionStorageKey = Self.storageKey(code: code, language: language, override: storageKey)
    isExpanded = Self.isStorageKeyExpanded(expansionStorageKey)
    codeFont = UIFont.monospacedSystemFont(ofSize: max(12.5, baseFont.pointSize - 2.5), weight: .regular)

    let outerH: CGFloat = 0.0
    let hPad: CGFloat = 12.0
    let vPad: CGFloat = 10.0
    let barH: CGFloat = 32.0
    let btnW: CGFloat = 30.0
    let cardWidth = max(1.0, availableWidth - outerH * 2)
    let labelWidth = max(1.0, cardWidth - hPad * 2)

    // Language label
    langLabel.text = language?.lowercased()
    langLabel.isHidden = language == nil

    // Count total lines
    totalLineCount = code.components(separatedBy: "\n").count

    // Determine display text (collapsed vs expanded)
    let displayCode: String
    let needsCollapse = !isExpanded && totalLineCount > maxCollapsedLines
    if needsCollapse {
      displayCode = code.components(separatedBy: "\n").prefix(maxCollapsedLines).joined(separator: "\n")
    } else {
      displayCode = code
    }

    // Plain monospace by default; colorized when expanded
    let attributed: NSAttributedString
    if isExpanded {
      attributed = highlightedCode(displayCode, font: codeFont, baseColor: textColor)
    } else {
      attributed = NSAttributedString(string: displayCode, attributes: [
        .font: codeFont,
        .foregroundColor: textColor.withAlphaComponent(0.88)
      ])
    }
    codeLabel.attributedText = attributed

    let textBounds = attributed.boundingRect(
      with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil
    )
    let textWidth = ceil(textBounds.width)
    let textHeight = ceil(textBounds.height)
    let bodyH = max(ceil(codeFont.lineHeight), textHeight)
    let cardH = barH + vPad + bodyH + vPad

    cardView.backgroundColor = UIColor(white: 0.5, alpha: 0.09)
    cardView.layer.borderWidth = 0.5
    cardView.layer.borderColor = UIColor(white: 0.5, alpha: 0.18).cgColor
    cardView.frame = CGRect(x: outerH, y: 0, width: cardWidth, height: cardH)
    topBarView.frame = CGRect(x: 0, y: 0, width: cardWidth, height: barH)

    // Top bar layout: [langLabel ...  copyBtn  expandBtn]
    langLabel.sizeToFit()
    langLabel.frame = CGRect(x: hPad, y: (barH - langLabel.frame.height) * 0.5,
                             width: langLabel.frame.width, height: langLabel.frame.height)

    expandButton.frame = CGRect(x: cardWidth - btnW - 4.0, y: (barH - btnW) * 0.5, width: btnW, height: btnW)
    copyButton.frame = CGRect(x: expandButton.frame.minX - btnW, y: (barH - btnW) * 0.5, width: btnW, height: btnW)

    copiedLabel.sizeToFit()
    copiedLabel.frame.origin = CGPoint(
      x: copyButton.frame.minX - copiedLabel.frame.width - 6.0,
      y: (barH - copiedLabel.frame.height) * 0.5
    )

    // Update expand icon
    let expandCfg = UIImage.SymbolConfiguration(pointSize: 12.0, weight: .medium)
    let expandIcon = isExpanded
      ? "arrow.down.right.and.arrow.up.left"
      : "arrow.up.left.and.arrow.down.right"
    expandButton.setImage(UIImage(systemName: expandIcon, withConfiguration: expandCfg), for: .normal)
    expandButton.isHidden = totalLineCount <= maxCollapsedLines

    scrollView.frame = CGRect(x: 0, y: barH, width: cardWidth, height: cardH - barH)
    scrollView.contentSize = CGSize(width: textWidth + hPad * 2, height: bodyH + vPad * 2)
    codeLabel.frame = CGRect(x: hPad, y: vPad, width: textWidth, height: bodyH)
    preferredCardHeight = outerH + cardH + 8.0
    invalidateIntrinsicContentSize()
    return preferredCardHeight
  }

  // MARK: - Syntax highlighting (only used in expanded mode)

  private func highlightedCode(_ code: String, font: UIFont, baseColor: UIColor) -> NSAttributedString {
    let mutable = NSMutableAttributedString(string: code, attributes: [
      .font: font,
      .foregroundColor: baseColor.withAlphaComponent(0.88)
    ])
    let fullRange = NSRange(location: 0, length: (code as NSString).length)

    // Keywords
    let kw = "func|let|var|if|else|for|while|return|class|struct|enum|import|extension|guard|in|where|as|try|catch|throw|switch|case|default|public|private|protocol|static|const|function|new|this|super|await|async|yield|package|interface|implements|override|final|val|def|namespace|using|fn|mut|use|mod|pub|impl|type|trait|match|loop|break|continue|self|Self|nil|null|true|false|None|Some"
    if let re = try? NSRegularExpression(pattern: "\\b(\(kw))\\b") {
      for m in re.matches(in: code, range: fullRange) {
        mutable.addAttribute(.foregroundColor, value: UIColor.systemPink, range: m.range)
      }
    }

    // Types / Macros (capitalized words, or word!)
    if let re = try? NSRegularExpression(pattern: "\\b[A-Z][a-zA-Z0-9_]*\\b|\\b[a-z_]+!") {
      for m in re.matches(in: code, range: fullRange) {
        mutable.addAttribute(.foregroundColor, value: UIColor(red: 0.4, green: 0.75, blue: 1.0, alpha: 1.0), range: m.range)
      }
    }

    // Numbers
    if let re = try? NSRegularExpression(pattern: "\\b\\d+(?:\\.\\d+)?\\b") {
      for m in re.matches(in: code, range: fullRange) {
        mutable.addAttribute(.foregroundColor, value: UIColor.systemOrange, range: m.range)
      }
    }

    // Strings
    if let re = try? NSRegularExpression(pattern: "\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'") {
      for m in re.matches(in: code, range: fullRange) {
        mutable.addAttribute(.foregroundColor, value: UIColor.systemGreen, range: m.range)
      }
    }

    // Comments (must be last to override)
    if let re = try? NSRegularExpression(pattern: "//.*|#.*|/\\*[\\s\\S]*?\\*/", options: [.dotMatchesLineSeparators, .anchorsMatchLines]) {
      for m in re.matches(in: code, range: fullRange) {
        mutable.addAttribute(.foregroundColor, value: UIColor(white: 0.55, alpha: 1.0), range: m.range)
      }
    }

    return mutable
  }

  @objc private func handleExpand() {
    isExpanded.toggle()
    Self.setStorageKey(expansionStorageKey, expanded: isExpanded)
    _ = configure(
      code: codeContent,
      language: codeLang,
      textColor: baseTextColor,
      baseFont: originalBaseFont,
      availableWidth: currentAvailableWidth,
      storageKey: expansionStorageKey
    )

    // Trigger parent re-layout
    if let sv = superview {
      sv.setNeedsLayout()
      sv.layoutIfNeeded()
    }
    // Post notification so the table/collection can invalidate its layout
    NotificationCenter.default.post(name: Notification.Name("AgentCodeBlockExpanded"), object: nil)
  }

  @objc private func handleCopy() {
    UIPasteboard.general.string = codeContent
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    copyFeedbackWork?.cancel()
    copiedLabel.alpha = 0
    copyButton.alpha = 0
    UIView.animate(withDuration: 0.15) { self.copiedLabel.alpha = 1.0 }
    let work = DispatchWorkItem { [weak self] in
      UIView.animate(withDuration: 0.25) {
        self?.copiedLabel.alpha = 0
        self?.copyButton.alpha = 1.0
      }
    }
    copyFeedbackWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
  }
}

extension Notification.Name {
  static let chatNativeStreamingTextLayoutInvalidated = Notification.Name(
    "ChatNativeStreamingTextLayoutInvalidated"
  )
}

private struct ChatNativeStreamingRevealSegment {
  let range: NSRange
  let startTime: CFTimeInterval
  let duration: CFTimeInterval
}

// MARK: - ChatNativeStreamingTextLabel

final class ChatNativeStreamingTextLabel: UITextView {
  private static let streamingFadeAnimationKey = "vibe.streaming.fade"
  private static let streamingChunkFadeDuration: CFTimeInterval = 0.42
  private static let streamingFinalFadeDuration: CFTimeInterval = 0.24
  private static let streamingRevealInitialAlpha: CGFloat = 0.0
  private static let streamingRevealSegmentStagger: CFTimeInterval = 0.0
  private static let streamingRevealSingleSegmentLimit = Int.max
  private static let streamingRevealSegmentMinLength = 44
  private static let streamingRevealSegmentMaxLength = 104

  private var fullAttributedValue: NSAttributedString?
  private var displayedCharacterLength = 0
  private var committedCharacterLength = 0
  private var fadeDisplayLink: CADisplayLink?
  private var revealSegments: [ChatNativeStreamingRevealSegment] = []
  private var lastAppliedStreaming = false
  weak var linkDelegate: ChatNativeStreamingTextLabelDelegate?
  private static let uuidRegex = try! NSRegularExpression(pattern: "[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}")

  // Compatibility properties for callers using UILabel API
  var numberOfLines: Int {
    get { textContainer.maximumNumberOfLines }
    set { textContainer.maximumNumberOfLines = newValue }
  }

  var targetCharacterLength: Int {
    fullAttributedValue?.length ?? attributedText?.length ?? 0
  }

  var renderedCharacterLength: Int {
    attributedText?.length ?? 0
  }

  var isRevealActiveForMeasurement: Bool {
    fadeDisplayLink != nil
      || !revealSegments.isEmpty
      || displayedCharacterLength < targetCharacterLength
  }

  required init?(coder: NSCoder) {
    return nil
  }

  /// TextKit 1, deliberately, and this is the most expensive line in the message list.
  ///
  /// Every bubble in every chat owns one of these, and a device census put its
  /// construction at 517us — against 40us for the bubble plate, 46us for the tail and 6us
  /// for a `UILabel`. It is 20% of the whole cell, paid on every mount, because
  /// `UITextView()` on iOS 16+ builds a TextKit 2 `NSTextLayoutManager` stack: viewport
  /// layout, element providers, the lot. None of which this view uses — it renders one
  /// attributed string into a fixed width and never scrolls.
  ///
  /// `usingTextLayoutManager: false` asks for the TextKit 1 `NSLayoutManager` path
  /// instead, which is the older and much cheaper object graph and is exactly what this
  /// class was written against (`textContainer.widthTracksTextView`, the `layoutManager`
  /// glyph enumeration in the reveal code). Keeping the TextKit 2 stack was never a
  /// decision — it is what the plain initializer started returning.
  ///
  /// If this ever needs to move back to TextKit 2, the reveal path's layout-manager use
  /// has to be ported first; `[CellCost] AgentStreamingLabel` is the number to watch.
  convenience init() {
    // Build the TextKit 1 stack by hand and hand it to the designated initializer.
    //
    // `UITextView(usingTextLayoutManager: false)` expresses the same intent in one line
    // and crashed the app on the first cell mount (SIGSEGV during `seed-mount`): that
    // initializer is not overridden here, so delegating to it from a subclass convenience
    // init re-enters this very initializer and overflows the stack. Supplying a container
    // that already has an `NSLayoutManager` is the documented way to ask for TextKit 1 and
    // goes through `init(frame:textContainer:)`, which this class does override.
    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(
      size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    layoutManager.addTextContainer(container)
    storage.addLayoutManager(layoutManager)
    self.init(frame: .zero, textContainer: container)
  }

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    configureForBubbleRendering()
  }

  /// Shared by both initializers. The TextKit-1 path above cannot call
  /// `init(frame:textContainer:)`, so this is the setup both must run.
  private func configureForBubbleRendering() {
    isEditable = false
    isScrollEnabled = false
    isSelectable = false
    self.textContainerInset = .zero
    self.textContainer.lineFragmentPadding = 0
    self.textContainer.widthTracksTextView = true
    backgroundColor = .clear
    isUserInteractionEnabled = true
    // Telegram-style: links use bubble body color (not system blue).
    linkTextAttributes = [
      .foregroundColor: UIColor.label,
      .underlineStyle: NSUnderlineStyle.single.rawValue,
    ]
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    tap.cancelsTouchesInView = false
    addGestureRecognizer(tap)
  }

  deinit {
    cancelChunkFade()
    stopStreamingFadeAnimation()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil {
      if !revealSegments.isEmpty {
        startStreamingRevealDisplayLinkIfNeeded()
      }
    } else {
      fadeDisplayLink?.invalidate()
      fadeDisplayLink = nil
    }
  }

  func applyStreamingText(_ attributedText: NSAttributedString, rawText: String, isStreaming: Bool) {
    _ = rawText
    // UITextView forces system-blue links via linkTextAttributes unless overridden.
    let bodyColor =
      (attributedText.length > 0
        ? attributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        : nil) ?? textColor ?? .label
    linkTextAttributes = [
      .foregroundColor: bodyColor,
      .underlineStyle: NSUnderlineStyle.single.rawValue,
    ]
    let previousTargetText = fullAttributedValue?.string ?? self.attributedText?.string ?? ""
    let previousTargetLength = fullAttributedValue?.length ?? self.attributedText?.length ?? 0
    let currentRenderedString = self.attributedText?.string ?? ""
    let targetString = attributedText.string
    let targetDeltaLength = max(0, attributedText.length - previousTargetLength)

    if currentRenderedString == targetString,
      previousTargetText == targetString,
      isStreaming == lastAppliedStreaming,
      revealSegments.isEmpty
    {
      return
    }

    fullAttributedValue = attributedText
    lastAppliedStreaming = isStreaming

    if !isStreaming {
      if targetString == previousTargetText, !revealSegments.isEmpty {
        displayedCharacterLength = attributedText.length
        startStreamingRevealDisplayLinkIfNeeded()
        return
      }

      if targetString.hasPrefix(previousTargetText),
        targetDeltaLength > 0,
        previousTargetLength > 0
      {
        enqueueAppendedReveal(
          attributedText: attributedText,
          targetString: targetString,
          appendedStart: min(previousTargetLength, attributedText.length)
        )
        return
      }

      cancelChunkFade()
      displayedCharacterLength = attributedText.length
      committedCharacterLength = attributedText.length
      setDisplayedText(
        attributedText,
        animated: previousTargetLength > 0 && targetString != currentRenderedString,
        fadeDuration: Self.streamingFinalFadeDuration
      )
      return
    }

    let shouldResetReveal =
      !previousTargetText.isEmpty
      && !targetString.hasPrefix(previousTargetText)
    let isAppendOnly =
      targetString.hasPrefix(previousTargetText)
      && targetDeltaLength > 0
      && previousTargetLength > 0

    let needsUpdate =
      shouldResetReveal
      || targetDeltaLength > 0
      || (currentRenderedString != targetString && revealSegments.isEmpty)

    guard needsUpdate else {
      if !revealSegments.isEmpty {
        startStreamingRevealDisplayLinkIfNeeded()
      }
      return
    }

    if previousTargetLength == 0, currentRenderedString.isEmpty, attributedText.length > 0 {
      cancelChunkFade()
      displayedCharacterLength = 0
      committedCharacterLength = 0
      enqueueAppendedReveal(
        attributedText: attributedText,
        targetString: targetString,
        appendedStart: 0
      )
      return
    }

    displayedCharacterLength = attributedText.length

    if isAppendOnly && !shouldResetReveal {
      enqueueAppendedReveal(
        attributedText: attributedText,
        targetString: targetString,
        appendedStart: min(previousTargetLength, attributedText.length)
      )
    } else {
      cancelChunkFade()
      committedCharacterLength = attributedText.length
      setDisplayedText(attributedText, animated: false)
    }
  }

  func resetStreamingState() {
    cancelChunkFade()
    stopStreamingFadeAnimation()
    fullAttributedValue = nil
    displayedCharacterLength = 0
    committedCharacterLength = 0
    lastAppliedStreaming = false
    attributedText = nil
  }

  func measurementAttributedText(
    fallback: NSAttributedString,
    isStreaming: Bool
  ) -> (text: NSAttributedString, source: String) {
    _ = isStreaming
    return (fallback, "target")
  }

  private func cancelChunkFade() {
    fadeDisplayLink?.invalidate()
    fadeDisplayLink = nil
    revealSegments.removeAll()
  }

  private func stopStreamingFadeAnimation() {
    layer.removeAnimation(forKey: Self.streamingFadeAnimationKey)
  }

  private func startStreamingRevealDisplayLinkIfNeeded() {
    guard fadeDisplayLink == nil else { return }
    let displayLink = CADisplayLink(target: self, selector: #selector(handleStreamingRevealFrame(_:)))
    displayLink.preferredFramesPerSecond = 60
    displayLink.add(to: .main, forMode: .common)
    fadeDisplayLink = displayLink
  }

  @objc private func handleStreamingRevealFrame(_ displayLink: CADisplayLink) {
    renderStreamingRevealFrame(at: displayLink.timestamp)
  }

  private func enqueueAppendedReveal(
    attributedText: NSAttributedString,
    targetString: String,
    appendedStart: Int
  ) {
    let appendedRange = NSRange(
      location: appendedStart,
      length: max(0, attributedText.length - appendedStart)
    )
    if revealSegments.isEmpty {
      committedCharacterLength = appendedStart
    }
    enqueueRevealSegments(for: appendedRange, in: targetString)
    renderStreamingRevealFrame(at: CACurrentMediaTime(), invalidateLayout: true)
    startStreamingRevealDisplayLinkIfNeeded()
  }

  private func enqueueRevealSegments(for appendedRange: NSRange, in targetString: String) {
    guard appendedRange.length > 0 else { return }
    let now = CACurrentMediaTime()
    let targetNSString = targetString as NSString
    let ranges = revealRanges(in: targetNSString, appendedRange: appendedRange)
    guard !ranges.isEmpty else { return }

    let nextStartTime: CFTimeInterval
    if let latestQueuedStart = revealSegments.map(\.startTime).max() {
      nextStartTime = max(now, latestQueuedStart + Self.streamingRevealSegmentStagger)
    } else {
      nextStartTime = now
    }

    for (index, range) in ranges.enumerated() {
      revealSegments.append(
        ChatNativeStreamingRevealSegment(
          range: range,
          startTime: nextStartTime + CFTimeInterval(index) * Self.streamingRevealSegmentStagger,
          duration: Self.streamingChunkFadeDuration
        )
      )
    }
  }

  private func renderStreamingRevealFrame(
    at timestamp: CFTimeInterval,
    invalidateLayout: Bool = false
  ) {
    guard let target = fullAttributedValue else {
      cancelChunkFade()
      return
    }

    let currentLength = attributedText?.length ?? 0
    let currentString = attributedText?.string ?? ""
    let needsContentUpdate = currentLength != target.length || currentString != target.string
    if needsContentUpdate {
      UIView.performWithoutAnimation {
        self.attributedText = target
      }
      if invalidateLayout {
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        notifyLayoutInvalidated()
      }
    }

    guard !revealSegments.isEmpty else {
      displayedCharacterLength = target.length
      committedCharacterLength = target.length
      return
    }

    let storage = textStorage
    let storageRange = NSRange(location: 0, length: storage.length)
    storage.beginEditing()

    var keepers: [ChatNativeStreamingRevealSegment] = []

    for segment in revealSegments {
      let safeRange = NSIntersectionRange(segment.range, storageRange)
      guard safeRange.length > 0 else { continue }

      let rawProgress = CGFloat((timestamp - segment.startTime) / segment.duration)
      let isComplete = rawProgress >= 1.0

      if isComplete {
        applyRevealAlpha(1.0, to: safeRange, from: target, into: storage)
      } else {
        let progress = max(0.0, rawProgress)
        let eased = easedRevealProgress(progress)
        let alphaFactor =
          Self.streamingRevealInitialAlpha
          + (1.0 - Self.streamingRevealInitialAlpha) * eased
        applyRevealAlpha(alphaFactor, to: safeRange, from: target, into: storage)
        keepers.append(segment)
      }
    }

    storage.endEditing()

    revealSegments = keepers
    displayedCharacterLength = target.length

    if keepers.isEmpty {
      fadeDisplayLink?.invalidate()
      fadeDisplayLink = nil
      committedCharacterLength = target.length
    }
  }

  private func revealRanges(in string: NSString, appendedRange: NSRange) -> [NSRange] {
    let availableRange = NSRange(location: 0, length: string.length)
    let safeRange = NSIntersectionRange(appendedRange, availableRange)
    guard safeRange.length > 0 else { return [] }

    if safeRange.length <= Self.streamingRevealSingleSegmentLimit {
      let composedRange = string.rangeOfComposedCharacterSequences(for: safeRange)
      let range = NSIntersectionRange(composedRange, safeRange)
      return range.length > 0 ? [range] : []
    }

    let limit = NSMaxRange(safeRange)
    var cursor = safeRange.location
    var ranges: [NSRange] = []

    while cursor < limit {
      var segmentEnd = cursor
      var lastSoftBoundaryEnd: Int?
      var segmentLength = 0

      while segmentEnd < limit {
        let composedRange = string.rangeOfComposedCharacterSequence(at: segmentEnd)
        let nextEnd = min(NSMaxRange(composedRange), limit)
        let characterRange = NSRange(location: segmentEnd, length: max(0, nextEnd - segmentEnd))
        let character = characterRange.length > 0 ? string.substring(with: characterRange) : ""

        segmentEnd = nextEnd
        segmentLength += characterRange.length

        if isRevealBoundary(character) {
          lastSoftBoundaryEnd = segmentEnd
          if segmentLength >= Self.streamingRevealSegmentMinLength {
            break
          }
        }

        if segmentLength >= Self.streamingRevealSegmentMaxLength {
          if let boundaryEnd = lastSoftBoundaryEnd, boundaryEnd > cursor {
            segmentEnd = boundaryEnd
          }
          break
        }
      }

      let rawRange = NSRange(location: cursor, length: max(1, segmentEnd - cursor))
      let composedRange = string.rangeOfComposedCharacterSequences(for: rawRange)
      let range = NSIntersectionRange(composedRange, safeRange)
      if range.length > 0 {
        ranges.append(range)
      }
      cursor = max(NSMaxRange(composedRange), cursor + 1)
    }

    return ranges
  }

  private func isRevealBoundary(_ character: String) -> Bool {
    guard let scalar = character.unicodeScalars.last else { return false }
    if CharacterSet.whitespacesAndNewlines.contains(scalar) {
      return true
    }
    return ".!,;:?)]}\u{060C}\u{061B}\u{061F}".unicodeScalars.contains(scalar)
  }

  private func easedRevealProgress(_ progress: CGFloat) -> CGFloat {
    progress * progress * (3.0 - 2.0 * progress)
  }

  private func applyRevealAlpha(
    _ alpha: CGFloat,
    to range: NSRange,
    from target: NSAttributedString,
    into storage: NSTextStorage
  ) {
    let storageRange = NSRange(location: 0, length: storage.length)
    let safeRange = NSIntersectionRange(range, storageRange)
    guard safeRange.length > 0 else { return }

    var appliedForeground = false
    target.enumerateAttribute(.foregroundColor, in: safeRange, options: []) { value, subrange, _ in
      let baseColor = (value as? UIColor) ?? self.textColor ?? .label
      let resolved = baseColor.resolvedColor(with: self.traitCollection)
      let baseAlpha = resolved.cgColor.alpha
      storage.addAttribute(
        .foregroundColor,
        value: resolved.withAlphaComponent(baseAlpha * alpha),
        range: subrange
      )
      appliedForeground = true
    }

    if !appliedForeground {
      let resolved = (textColor ?? .label).resolvedColor(with: traitCollection)
      storage.addAttribute(
        .foregroundColor,
        value: resolved.withAlphaComponent(resolved.cgColor.alpha * alpha),
        range: safeRange
      )
    }
  }

  private func setDisplayedText(
    _ attributedText: NSAttributedString,
    animated: Bool,
    fadeDuration: CFTimeInterval = ChatNativeStreamingTextLabel.streamingChunkFadeDuration,
    invalidateLayout: Bool = true
  ) {
    _ = animated
    _ = fadeDuration
    let renderedText = attributedText.length == 0 ? NSAttributedString() : attributedText
    let currentString = self.attributedText?.string ?? ""
    let targetString = renderedText.string
    let textIsIdentical = currentString == targetString

    stopStreamingFadeAnimation()
    UIView.performWithoutAnimation {
      self.attributedText = renderedText
    }
    if invalidateLayout, !textIsIdentical {
      invalidateIntrinsicContentSize()
      setNeedsLayout()
      notifyLayoutInvalidated()
    }
  }

  private func notifyLayoutInvalidated() {
    DispatchQueue.main.async { [weak self] in
      guard let self, self.window != nil else { return }
      NotificationCenter.default.post(
        name: .chatNativeStreamingTextLayoutInvalidated,
        object: self
      )
    }
  }

  // MARK: - Link tap (layout manager hit-test — no cursor, isSelectable stays false)

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    guard let attributed = attributedText, attributed.length > 0 else { return }
    let point = gesture.location(in: self)
    let adjusted = CGPoint(
      x: point.x - textContainerInset.left,
      y: point.y - textContainerInset.top
    )
    let charIdx = layoutManager.characterIndex(
      for: adjusted, in: textContainer,
      fractionOfDistanceBetweenInsertionPoints: nil
    )
    guard charIdx < attributed.length else { return }
    let attrs = attributed.attributes(at: charIdx, effectiveRange: nil)
    if let linkVal = attrs[.link] {
      var url: URL?
      if let u = linkVal as? URL { url = u }
      else if let s = linkVal as? String { url = URL(string: s) }
      if let url {
        linkDelegate?.streamingTextLabel(self, didTap: url)
        handleTappedURL(url)
      }
    }
  }

  private func handleTappedURL(_ url: URL) {
    // Internal routes (vibe://u?handle=@username, share-host handles, room links,
    // chatId UUIDs) push a chat immediately via the shared share-link router.
    // External http(s) still open the in-app browser.
    if let target = Self.routeTarget(for: url) {
      Task { @MainActor in
        VibeRoomLinkRouter.shared.handle(target: target)
      }
      return
    }

    DispatchQueue.main.async {
      InAppBrowserViewController.present(url: url)
    }
  }

  /// Maps a tapped URL onto a `VibeShareLinkTarget` when the app can open it as a
  /// chat/profile/room. Returns nil for ordinary web links.
  private static func routeTarget(for url: URL) -> VibeShareLinkTarget? {
    if let target = VibeRoomLinkRouter.target(from: url) {
      return target
    }
    // Legacy vibegram paths that embed a chat UUID but weren't classified above.
    if let chatId = extractChatId(from: url) {
      return .chat(chatId)
    }
    return nil
  }

  private static func extractChatId(from url: URL) -> String? {
    // Heuristic: host contains vibe / vibegram and a UUID appears in the path or query
    let host = url.host?.lowercased() ?? ""
    if host.contains("vibe") || host.contains("vibegram") || url.scheme == "vibe" {
      let path = url.path
      let ns = path as NSString
      let range = NSRange(location: 0, length: ns.length)
      if let m = uuidRegex.firstMatch(in: path, range: range) {
        return (ns.substring(with: m.range) as String)
      }
      if let comps = URLComponents(url: url, resolvingAgainstBaseURL: false), let items = comps.queryItems {
        for item in items {
          if (item.name.lowercased().contains("chat") || item.name.lowercased().contains("id")), let v = item.value, !v.isEmpty {
            return v
          }
        }
      }
    }
    return nil
  }
}

/// One-line "what the agent's computer is doing" band under an agent turn — browser host
/// + page, or terminal + command. Fixed height; see docs/row-height-formulas.md §1.5.
final class AgentComputerBandView: UIControl {
  private let plateView = UIView()
  private let glyphView = UIImageView()
  private let primaryLabel = UILabel()
  private let secondaryLabel = UILabel()
  private let controlChip = UILabel()
  private let liveDot = UIView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    plateView.layer.cornerRadius = 8.0
    plateView.layer.borderWidth = 1.0
    plateView.isUserInteractionEnabled = false
    plateView.clipsToBounds = true
    addSubview(plateView)

    glyphView.image = UIImage(systemName: "display")
    glyphView.contentMode = .scaleAspectFit
    plateView.addSubview(glyphView)

    primaryLabel.font = .systemFont(ofSize: 12.0, weight: .semibold)
    primaryLabel.lineBreakMode = .byTruncatingTail
    plateView.addSubview(primaryLabel)

    secondaryLabel.font = .systemFont(ofSize: 12.0, weight: .regular)
    secondaryLabel.lineBreakMode = .byTruncatingTail
    plateView.addSubview(secondaryLabel)

    controlChip.font = .systemFont(ofSize: 10.0, weight: .semibold)
    controlChip.text = "Take control"
    controlChip.textAlignment = .center
    controlChip.layer.cornerRadius = 8.0
    controlChip.clipsToBounds = true
    plateView.addSubview(controlChip)

    liveDot.layer.cornerRadius = 3.0
    liveDot.backgroundColor = UIColor(red: 0.16, green: 0.78, blue: 0.45, alpha: 1.0)
    plateView.addSubview(liveDot)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(
    isShell: Bool, primary: String, secondary: String, live: Bool, showsTakeControl: Bool,
    appearance: VibeAgentKitChatAppearance
  ) {
    plateView.backgroundColor = appearance.surfaceElevated
    plateView.layer.borderColor = appearance.border.cgColor
    glyphView.image = UIImage(systemName: isShell ? "terminal" : "globe")
    glyphView.tintColor = appearance.textSecondary
    primaryLabel.textColor = appearance.text
    primaryLabel.text = primary
    secondaryLabel.textColor = appearance.textTertiary
    secondaryLabel.text = secondary
    secondaryLabel.isHidden = secondary.isEmpty
    controlChip.isHidden = !showsTakeControl
    controlChip.textColor = appearance.primary
    controlChip.backgroundColor = vibeAgentKitColorWithAlpha(appearance.primary, 0.16)
    liveDot.isHidden = !live
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    plateView.frame = bounds
    let inset: CGFloat = 8.0
    let glyphSide: CGFloat = 13.0
    let midY = bounds.height / 2.0
    glyphView.frame = CGRect(
      x: inset, y: midY - glyphSide / 2.0, width: glyphSide, height: glyphSide)
    var trailing = bounds.width - inset
    if !liveDot.isHidden {
      liveDot.frame = CGRect(x: trailing - 6.0, y: midY - 3.0, width: 6.0, height: 6.0)
      trailing = liveDot.frame.minX - 6.0
    }
    if controlChip.isHidden {
      controlChip.frame = .zero
    } else {
      let chipWidth = ceil(controlChip.intrinsicContentSize.width) + 12.0
      controlChip.frame = CGRect(
        x: trailing - chipWidth, y: midY - 8.0, width: chipWidth, height: 16.0)
      trailing = controlChip.frame.minX - 6.0
    }
    var x = glyphView.frame.maxX + 6.0
    let primaryWidth = min(
      ceil(primaryLabel.intrinsicContentSize.width), max(0.0, trailing - x))
    primaryLabel.frame = CGRect(x: x, y: 0.0, width: primaryWidth, height: bounds.height)
    x = primaryLabel.frame.maxX + 6.0
    secondaryLabel.frame = CGRect(
      x: x, y: 0.0, width: max(0.0, trailing - x), height: bounds.height)
  }
}
