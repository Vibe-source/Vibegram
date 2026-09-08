import UIKit

private let resoloBoldRegex = try! NSRegularExpression(pattern: "\\*\\*(.+?)\\*\\*")
private let resoloItalicRegex = try! NSRegularExpression(
  pattern: "(?<!\\*)\\*(?![\\s*])([^*\n]+?)(?<![\\s*])\\*(?!\\*)"
)
private let resoloStrikethroughRegex = try! NSRegularExpression(pattern: "~~([^~\n]+?)~~")
private let resoloStrayBoldMarkerRegex = try! NSRegularExpression(pattern: "\\*\\*")
private let resoloMarkdownLinkRegex = try! NSRegularExpression(
  pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)"
)
private let resoloInlineCodeRegex = try! NSRegularExpression(pattern: "`([^`]+)`")

enum VibeAgentKitParsedBlock: Equatable {
  case text(String)
  case code(String, String?)
}

enum VibeAgentKitTextRenderer {
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
    // Default ~1.35× body line when callers omit a target — matches WhatsApp-style
    // agent prose density without locking min/max line boxes.
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

  /// Shared paragraph style for a single rendered line/paragraph. `spacingBefore`
  /// is the vertical gap above this paragraph (used to separate paragraphs and
  /// give headings breathing room); `firstLineHeadIndent`/`headIndent` hang list
  /// markers and nested levels so wrapped lines stay under the body text.
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

  static func parseBlocks(_ text: String) -> [VibeAgentKitParsedBlock] {
    var blocks: [VibeAgentKitParsedBlock] = []
    var normalLines: [String] = []
    var codeLines: [String] = []
    var inCodeBlock = false
    var currentLanguage: String?

    for line in text.components(separatedBy: "\n") {
      if line.hasPrefix("```") {
        let fenceInfo = String(line.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        if inCodeBlock {
          let code = codeLines.joined(separator: "\n")
          if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.code(code, currentLanguage))
          }
          codeLines.removeAll()
          currentLanguage = nil
          inCodeBlock = false
        } else {
          let normal = normalLines.joined(separator: "\n")
          if !normal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(.text(normal))
          }
          normalLines.removeAll()
          inCodeBlock = true
          currentLanguage = fenceInfo.isEmpty ? nil : fenceInfo
        }
      } else if inCodeBlock {
        codeLines.append(line)
      } else {
        normalLines.append(line)
      }
    }

    if inCodeBlock, !codeLines.isEmpty {
      blocks.append(.code(codeLines.joined(separator: "\n"), currentLanguage))
    } else if !normalLines.isEmpty {
      let text = normalLines.joined(separator: "\n")
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        blocks.append(.text(text))
      }
    }

    return blocks.isEmpty ? [.text(text)] : blocks
  }

  static func measuredSize(for attributedText: NSAttributedString, width: CGFloat) -> CGSize {
    guard width > 1.0, attributedText.length > 0 else { return .zero }
    let measured = attributedText.boundingRect(
      with: CGSize(width: width, height: .greatestFiniteMagnitude),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      context: nil
    )
    return CGSize(width: ceil(measured.width), height: ceil(measured.height))
  }

  static func measuredTextKitSize(for attributedText: NSAttributedString, width: CGFloat) -> CGSize {
    guard width > 1.0, attributedText.length > 0 else { return .zero }

    let textStorage = NSTextStorage(attributedString: attributedText)
    let layoutManager = NSLayoutManager()
    let textContainer = NSTextContainer(
      size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    )
    textContainer.lineFragmentPadding = 0.0
    textContainer.maximumNumberOfLines = 0
    textContainer.lineBreakMode = .byWordWrapping

    layoutManager.addTextContainer(textContainer)
    textStorage.addLayoutManager(layoutManager)
    layoutManager.ensureLayout(for: textContainer)

    let usedRect = layoutManager.usedRect(for: textContainer)
    return CGSize(width: ceil(usedRect.width), height: ceil(usedRect.height))
  }

  private static func applyLineMarkdown(
    _ text: String,
    font: UIFont,
    textColor: UIColor,
    isRtl: Bool,
    lineSpacing: CGFloat
  ) -> NSAttributedString {
    let result = NSMutableAttributedString()

    // Spacing scales with the body font so the structure reads the same at any
    // text size. Blank lines in the source become inter-paragraph spacing rather
    // than empty rendered lines (the markdown way), and headings get a larger gap
    // above plus a small gap before their body.
    // Paragraphs need a clearly visible gap or the answer reads as one continuous
    // block; headings get a larger gap above so sections are insulated.
    // WhatsApp-style structure: visible paragraph gaps, section headings with
    // breathing room, tight-but-readable list item gaps, nested bullet indents.
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
      if isTableSeparatorLine(rawLine) {
        continue
      }

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
        result.append(applyInlineFormatting(rawLine, baseAttributes: attributes, font: font))
      }

      emittedContent = true
      pendingBlank = false
      previousWasHeading = heading != nil
      previousWasListItem = isListItem
    }

    return result
  }

  /// Leading whitespace → nest level (2 spaces or 1 tab per level).
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
    result.append(applyInlineFormatting(text, baseAttributes: base, font: font))
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
    result.append(applyInlineFormatting(text, baseAttributes: base, font: font))
    return result
  }

  private static func applyInlineFormatting(
    _ text: String,
    baseAttributes: [NSAttributedString.Key: Any],
    font: UIFont
  ) -> NSAttributedString {
    let mutable = NSMutableAttributedString(string: text, attributes: baseAttributes)

    let linkMatches = resoloMarkdownLinkRegex.matches(
      in: mutable.string,
      range: NSRange(mutable.string.startIndex..., in: mutable.string)
    )
    for match in linkMatches.reversed() {
      guard
        let labelRange = Range(match.range(at: 1), in: mutable.string),
        let urlRange = Range(match.range(at: 2), in: mutable.string)
      else {
        continue
      }

      let label = String(mutable.string[labelRange])
      let urlString = String(mutable.string[urlRange])
      mutable.replaceCharacters(
        in: match.range,
        with: NSAttributedString(string: label, attributes: baseAttributes)
      )

      let replacedRange = NSRange(location: match.range.location, length: (label as NSString).length)
      // Only scheme'd targets (http(s):, mailto:, …) become tappable links. Bare
      // file-path references like (/Users/…/File.swift:120) render as clean label
      // text instead of raw `[label](path)` markdown.
      if let url = URL(string: urlString), let scheme = url.scheme, !scheme.isEmpty {
        // Match body text color (not system blue) — white/them text on bubble.
        let linkColor = (baseAttributes[.foregroundColor] as? UIColor) ?? .label
        mutable.addAttribute(.link, value: url, range: replacedRange)
        mutable.addAttribute(.foregroundColor, value: linkColor, range: replacedRange)
        mutable.addAttribute(
          .underlineStyle,
          value: NSUnderlineStyle.single.rawValue,
          range: replacedRange
        )
      }
    }

    let boldMatches = resoloBoldRegex.matches(
      in: mutable.string,
      range: NSRange(mutable.string.startIndex..., in: mutable.string)
    )
    for match in boldMatches.reversed() {
      guard let range = Range(match.range(at: 1), in: mutable.string) else {
        continue
      }
      let boldText = String(mutable.string[range])
      var boldAttributes = baseAttributes
      if let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) {
        boldAttributes[.font] = UIFont(descriptor: descriptor, size: font.pointSize)
      } else {
        boldAttributes[.font] = UIFont.boldSystemFont(ofSize: font.pointSize)
      }
      mutable.replaceCharacters(
        in: match.range,
        with: NSAttributedString(string: boldText, attributes: boldAttributes)
      )
    }

    // Remove stray ** markers — handles unclosed bold tokens during streaming
    // (e.g. "**Header text" with closing ** not yet received shows as "Header text")
    let strayBoldMatches = resoloStrayBoldMarkerRegex.matches(
      in: mutable.string,
      range: NSRange(mutable.string.startIndex..., in: mutable.string)
    )
    for match in strayBoldMatches.reversed() {
      mutable.deleteCharacters(in: match.range)
    }

    let strikeMatches = resoloStrikethroughRegex.matches(
      in: mutable.string,
      range: NSRange(mutable.string.startIndex..., in: mutable.string)
    )
    for match in strikeMatches.reversed() {
      guard let range = Range(match.range(at: 1), in: mutable.string) else {
        continue
      }
      let strikeText = String(mutable.string[range])
      var strikeAttributes = baseAttributes
      strikeAttributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      mutable.replaceCharacters(
        in: match.range,
        with: NSAttributedString(string: strikeText, attributes: strikeAttributes)
      )
    }

    let italicMatches = resoloItalicRegex.matches(
      in: mutable.string,
      range: NSRange(mutable.string.startIndex..., in: mutable.string)
    )
    for match in italicMatches.reversed() {
      guard let range = Range(match.range(at: 1), in: mutable.string) else {
        continue
      }
      let italicText = String(mutable.string[range])
      var italicAttributes = baseAttributes
      if let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
        italicAttributes[.font] = UIFont(descriptor: descriptor, size: font.pointSize)
      } else {
        italicAttributes[.font] = UIFont.italicSystemFont(ofSize: font.pointSize)
      }
      mutable.replaceCharacters(
        in: match.range,
        with: NSAttributedString(string: italicText, attributes: italicAttributes)
      )
    }

    let codeMatches = resoloInlineCodeRegex.matches(
      in: mutable.string,
      range: NSRange(mutable.string.startIndex..., in: mutable.string)
    )
    for match in codeMatches.reversed() {
      guard let range = Range(match.range(at: 1), in: mutable.string) else {
        continue
      }
      let codeText = String(mutable.string[range])
      var codeAttributes = baseAttributes
      // Plain monospace, matching the Codex/native renderer (ChatAgentStreamingText)
      // so inline code reads identically across both agent surfaces.
      codeAttributes[.font] = UIFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
      mutable.replaceCharacters(
        in: match.range,
        with: NSAttributedString(string: codeText, attributes: codeAttributes)
      )
    }

    if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
      for match in detector.matches(
        in: mutable.string,
        options: [],
        range: NSRange(mutable.string.startIndex..., in: mutable.string)
      ).reversed() {
        guard let url = match.url else {
          continue
        }

        var alreadyLinked = false
        mutable.enumerateAttribute(.link, in: match.range, options: []) { value, _, stop in
          if value != nil {
            alreadyLinked = true
            stop.pointee = true
          }
        }
        guard !alreadyLinked else {
          continue
        }

        let display = cleanURLDisplay(url)
        var linkAttributes = baseAttributes
        linkAttributes[.link] = url
        // Same color as bubble body text; underline marks tappable.
        linkAttributes[.foregroundColor] =
          (baseAttributes[.foregroundColor] as? UIColor) ?? .label
        linkAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        mutable.replaceCharacters(
          in: match.range,
          with: NSAttributedString(string: display, attributes: linkAttributes)
        )
      }
    }

    return mutable
  }

  private static func cleanURLDisplay(_ url: URL) -> String {
    guard let host = url.host else {
      return url.absoluteString
    }
    let normalizedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    let path = url.path
    guard !path.isEmpty, path != "/" else {
      return normalizedHost
    }
    let trimmedPath = path.count > 28 ? String(path.prefix(28)) + "\u{2026}" : path
    return normalizedHost + trimmedPath
  }

  private static func isTableSeparatorLine(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.count > 2, trimmed.hasPrefix("|") else {
      return false
    }
    for character in trimmed where character != "|" && character != "-" && character != ":" && character != " " {
      return false
    }
    return true
  }

  private static func parseHeadingLine(_ line: String) -> (Int, String)? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    var level = 0
    var currentIndex = trimmed.startIndex
    while currentIndex < trimmed.endIndex, trimmed[currentIndex] == "#" {
      level += 1
      currentIndex = trimmed.index(after: currentIndex)
    }

    guard level >= 1, level <= 6, currentIndex < trimmed.endIndex, trimmed[currentIndex] == " "
    else {
      return nil
    }

    let text = String(trimmed[trimmed.index(after: currentIndex)...]).trimmingCharacters(
      in: .whitespaces
    )
    return text.isEmpty ? nil : (level, text)
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
    let scale: CGFloat = level <= 1 ? 1.28 : level == 2 ? 1.16 : level == 3 ? 1.06 : 1.0
    let headingFont: UIFont
    if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitBold) {
      headingFont = UIFont(descriptor: descriptor, size: round(baseFont.pointSize * scale))
    } else {
      headingFont = UIFont.boldSystemFont(ofSize: round(baseFont.pointSize * scale))
    }

    let style = makeParagraphStyle(
      isRtl: isRtl,
      lineSpacing: lineSpacing,
      spacingBefore: spacingBefore
    )
    let attributes: [NSAttributedString.Key: Any] = [
      .font: headingFont,
      .foregroundColor: textColor,
      .paragraphStyle: style,
    ]
    // Apply inline formatting so **bold** markers inside headings are stripped/styled
    return applyInlineFormatting(text, baseAttributes: attributes, font: headingFont)
  }
}

final class VibeAgentKitCodeBlockView: UIView {
  private static let collapsedLineLimit = 12
  private static var expandedStorageKeys = Set<String>()

  private let cardView = UIView()
  private let topBarView = UIView()
  private let langLabel = UILabel()
  private let codeLabel = UILabel()
  private let copyButton = UIButton(type: .system)
  private let expandButton = UIButton(type: .system)
  private let copiedLabel = UILabel()

  private var codeContent = ""
  private var codeLanguage: String?
  private var originalBaseFont = UIFont.systemFont(ofSize: 17.0, weight: .regular)
  private var codeFont = UIFont.monospacedSystemFont(ofSize: 13.0, weight: .regular)
  private var baseTextColor = UIColor.white
  private var isExpanded = false
  private var totalLineCount = 0
  private var copyFeedbackWork: DispatchWorkItem?
  private var currentAvailableWidth: CGFloat = 0.0
  private var expansionStorageKey = ""

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
    // Outer clips so frame-based card children never paint outside the AL height
    // the stack assigns (otherwise text/code blocks overlap when height is compressed).
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

    codeLabel.numberOfLines = 0
    codeLabel.backgroundColor = .clear
    cardView.addSubview(codeLabel)

    let config = UIImage.SymbolConfiguration(pointSize: 12.0, weight: .medium)
    copyButton.setImage(UIImage(systemName: "doc.on.doc", withConfiguration: config), for: .normal)
    copyButton.tintColor = UIColor(white: 0.65, alpha: 0.9)
    copyButton.addTarget(self, action: #selector(handleCopy), for: .touchUpInside)
    topBarView.addSubview(copyButton)

    expandButton.setImage(
      UIImage(systemName: "arrow.up.left.and.arrow.down.right", withConfiguration: config),
      for: .normal
    )
    expandButton.tintColor = UIColor(white: 0.65, alpha: 0.9)
    expandButton.addTarget(self, action: #selector(handleExpand), for: .touchUpInside)
    topBarView.addSubview(expandButton)

    copiedLabel.text = "Copied!"
    copiedLabel.font = .systemFont(ofSize: 11.0, weight: .medium)
    copiedLabel.textColor = UIColor.systemGreen
    copiedLabel.alpha = 0.0
    topBarView.addSubview(copiedLabel)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  @discardableResult
  func configure(
    code: String,
    language: String?,
    textColor: UIColor,
    baseFont: UIFont,
    availableWidth: CGFloat,
    storageKey: String
  ) -> CGFloat {
    codeContent = code
    codeLanguage = language
    baseTextColor = textColor
    currentAvailableWidth = availableWidth
    originalBaseFont = baseFont
    expansionStorageKey = storageKey
    isExpanded = Self.expandedStorageKeys.contains(expansionStorageKey)
    codeFont = UIFont.monospacedSystemFont(
      ofSize: max(12.5, baseFont.pointSize - 2.5),
      weight: .regular
    )

    let horizontalPadding: CGFloat = 12.0
    let verticalPadding: CGFloat = 10.0
    let barHeight: CGFloat = 32.0
    let buttonWidth: CGFloat = 30.0
    let cardWidth = max(1.0, availableWidth)
    let labelWidth = max(1.0, cardWidth - horizontalPadding * 2.0)

    langLabel.text = language?.lowercased()
    langLabel.isHidden = language == nil
    totalLineCount = code.components(separatedBy: "\n").count

    let needsCollapse = !isExpanded && totalLineCount > Self.collapsedLineLimit
    let displayCode: String
    if needsCollapse {
      displayCode = code
        .components(separatedBy: "\n")
        .prefix(Self.collapsedLineLimit)
        .joined(separator: "\n")
    } else {
      displayCode = code
    }

    let attributed: NSAttributedString
    if isExpanded {
      attributed = highlightedCode(displayCode, font: codeFont, baseColor: textColor)
    } else {
      attributed = NSAttributedString(
        string: displayCode,
        attributes: [
          .font: codeFont,
          .foregroundColor: textColor.withAlphaComponent(0.88),
        ]
      )
    }
    codeLabel.attributedText = attributed

    let textHeight = ceil(
      attributed.boundingRect(
        with: CGSize(width: labelWidth, height: .greatestFiniteMagnitude),
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        context: nil
      ).height
    )
    let bodyHeight = max(ceil(codeFont.lineHeight), textHeight)
    let cardHeight = barHeight + verticalPadding + bodyHeight + verticalPadding

    cardView.backgroundColor = UIColor(white: 0.5, alpha: 0.09)
    cardView.layer.borderWidth = 0.5
    cardView.layer.borderColor = UIColor(white: 0.5, alpha: 0.18).cgColor
    cardView.frame = CGRect(x: 0.0, y: 0.0, width: cardWidth, height: cardHeight)
    topBarView.frame = CGRect(x: 0.0, y: 0.0, width: cardWidth, height: barHeight)

    langLabel.sizeToFit()
    langLabel.frame = CGRect(
      x: horizontalPadding,
      y: (barHeight - langLabel.frame.height) * 0.5,
      width: langLabel.frame.width,
      height: langLabel.frame.height
    )

    expandButton.frame = CGRect(
      x: cardWidth - buttonWidth - 4.0,
      y: (barHeight - buttonWidth) * 0.5,
      width: buttonWidth,
      height: buttonWidth
    )
    copyButton.frame = CGRect(
      x: expandButton.frame.minX - buttonWidth,
      y: (barHeight - buttonWidth) * 0.5,
      width: buttonWidth,
      height: buttonWidth
    )

    copiedLabel.sizeToFit()
    copiedLabel.frame.origin = CGPoint(
      x: copyButton.frame.minX - copiedLabel.frame.width - 6.0,
      y: (barHeight - copiedLabel.frame.height) * 0.5
    )

    let expandConfig = UIImage.SymbolConfiguration(pointSize: 12.0, weight: .medium)
    let expandIcon = isExpanded
      ? "arrow.down.right.and.arrow.up.left"
      : "arrow.up.left.and.arrow.down.right"
    expandButton.setImage(UIImage(systemName: expandIcon, withConfiguration: expandConfig), for: .normal)
    expandButton.isHidden = totalLineCount <= Self.collapsedLineLimit

    codeLabel.frame = CGRect(
      x: horizontalPadding,
      y: barHeight + verticalPadding,
      width: labelWidth,
      height: bodyHeight
    )

    // Cache the intrinsic height so Auto Layout / stack views cannot crush this
    // card under a sibling text block (root cause of table+code overlap).
    preferredCardHeight = cardHeight + 8.0
    invalidateIntrinsicContentSize()
    return preferredCardHeight
  }

  private var preferredCardHeight: CGFloat = 1.0

  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: max(1.0, preferredCardHeight))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // When the stack sets our width after configure, re-flow the frame-based card
    // so the glass box matches the real bounds (prevents misaligned / overlapping paint).
    let w = bounds.width
    guard w > 1.0, !codeContent.isEmpty else { return }
    if abs(w - currentAvailableWidth) > 0.5 {
      _ = configure(
        code: codeContent,
        language: codeLanguage,
        textColor: baseTextColor,
        baseFont: originalBaseFont,
        availableWidth: w,
        storageKey: expansionStorageKey
      )
    }
  }

  @objc private func handleExpand() {
    isExpanded.toggle()
    if isExpanded {
      Self.expandedStorageKeys.insert(expansionStorageKey)
    } else {
      Self.expandedStorageKeys.remove(expansionStorageKey)
    }

    _ = configure(
      code: codeContent,
      language: codeLanguage,
      textColor: baseTextColor,
      baseFont: originalBaseFont,
      availableWidth: max(currentAvailableWidth, bounds.width),
      storageKey: expansionStorageKey
    )

    if let superview {
      superview.setNeedsLayout()
      superview.layoutIfNeeded()
    }
    NotificationCenter.default.post(name: Notification.Name("VibeAgentKitCodeBlockExpanded"), object: nil)
  }

  @objc private func handleCopy() {
    UIPasteboard.general.string = codeContent
    UIImpactFeedbackGenerator(style: .light).impactOccurred()

    copyFeedbackWork?.cancel()
    copiedLabel.alpha = 0.0
    copyButton.alpha = 0.0

    UIView.animate(withDuration: 0.15) {
      self.copiedLabel.alpha = 1.0
    }

    let work = DispatchWorkItem { [weak self] in
      UIView.animate(withDuration: 0.25) {
        self?.copiedLabel.alpha = 0.0
        self?.copyButton.alpha = 1.0
      }
    }
    copyFeedbackWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
  }

  private func highlightedCode(
    _ code: String,
    font: UIFont,
    baseColor: UIColor
  ) -> NSAttributedString {
    let mutable = NSMutableAttributedString(
      string: code,
      attributes: [
        .font: font,
        .foregroundColor: baseColor.withAlphaComponent(0.88),
      ]
    )
    let fullRange = NSRange(location: 0, length: (code as NSString).length)

    let keywords =
      "func|let|var|if|else|for|while|return|class|struct|enum|import|extension|guard|in|where|as|try|catch|throw|switch|case|default|public|private|protocol|static|const|function|new|this|super|await|async|yield|package|interface|implements|override|final|val|def|namespace|using|fn|mut|use|mod|pub|impl|type|trait|match|loop|break|continue|self|Self|nil|null|true|false|None|Some"
    if let regex = try? NSRegularExpression(pattern: "\\b(\(keywords))\\b") {
      for match in regex.matches(in: code, range: fullRange) {
        mutable.addAttribute(.foregroundColor, value: UIColor.systemPink, range: match.range)
      }
    }

    if let regex = try? NSRegularExpression(pattern: "\\b[A-Z][a-zA-Z0-9_]*\\b|\\b[a-z_]+!") {
      for match in regex.matches(in: code, range: fullRange) {
        mutable.addAttribute(
          .foregroundColor,
          value: UIColor(red: 0.4, green: 0.75, blue: 1.0, alpha: 1.0),
          range: match.range
        )
      }
    }

    if let regex = try? NSRegularExpression(pattern: "\\b\\d+(?:\\.\\d+)?\\b") {
      for match in regex.matches(in: code, range: fullRange) {
        mutable.addAttribute(.foregroundColor, value: UIColor.systemOrange, range: match.range)
      }
    }

    if let regex = try? NSRegularExpression(pattern: "\"(?:\\\\.|[^\"\\\\])*\"|'(?:\\\\.|[^'\\\\])*'") {
      for match in regex.matches(in: code, range: fullRange) {
        mutable.addAttribute(.foregroundColor, value: UIColor.systemGreen, range: match.range)
      }
    }

    if let regex = try? NSRegularExpression(
      pattern: "//.*|#.*|/\\*[\\s\\S]*?\\*/",
      options: [.dotMatchesLineSeparators, .anchorsMatchLines]
    ) {
      for match in regex.matches(in: code, range: fullRange) {
        mutable.addAttribute(
          .foregroundColor,
          value: UIColor(white: 0.55, alpha: 1.0),
          range: match.range
        )
      }
    }

    return mutable
  }
}

private struct VibeAgentKitStreamingRevealSegment {
  let range: NSRange
  let startTime: CFTimeInterval
  let duration: CFTimeInterval
}

final class VibeAgentKitStreamingTextLabel: UITextView {
  private static let streamingFadeAnimationKey = "resolo.streaming.fade"
  private static let streamingChunkFadeDuration: CFTimeInterval = 0.42
  private static let streamingFinalFadeDuration: CFTimeInterval = 0.24
  private static let streamingRevealInitialAlpha: CGFloat = 0.0
  private static let streamingRevealSegmentStagger: CFTimeInterval = 0.0
  private static let streamingRevealSingleSegmentLimit = Int.max
  private static let streamingRevealSegmentMinLength = 44
  private static let streamingRevealSegmentMaxLength = 104
#if DEBUG
  private static let streamingLoggingEnabled = true
#else
  private static let streamingLoggingEnabled = false
#endif

  private var fullAttributedValue: NSAttributedString?
  private var displayedCharacterLength = 0
  private var committedCharacterLength = 0
  private var lastLoggedTargetLength = 0
  private var fadeDisplayLink: CADisplayLink?
  private var revealSegments: [VibeAgentKitStreamingRevealSegment] = []
  private var lastLayoutLogSignature = ""

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

  convenience init() {
    self.init(frame: .zero, textContainer: nil)
  }

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    isEditable = false
    isScrollEnabled = false
    isSelectable = false
    textContainerInset = .zero
    self.textContainer.lineFragmentPadding = 0.0
    self.textContainer.widthTracksTextView = true
    backgroundColor = .clear
    isUserInteractionEnabled = true
    // Telegram-style white (body) links — not system blue.
    linkTextAttributes = [
      .foregroundColor: UIColor.label,
      .underlineStyle: NSUnderlineStyle.single.rawValue,
    ]

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    tapGesture.cancelsTouchesInView = false
    addGestureRecognizer(tapGesture)
  }

  required init?(coder: NSCoder) { return nil }

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

  // MARK: – Public API

  func applyStreamingText(
    _ newAttributedText: NSAttributedString,
    rawText: String,
    isStreaming: Bool
  ) {
    let bodyColor =
      (newAttributedText.length > 0
        ? newAttributedText.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        : nil) ?? textColor ?? .label
    linkTextAttributes = [
      .foregroundColor: bodyColor,
      .underlineStyle: NSUnderlineStyle.single.rawValue,
    ]
    let previousTargetText = fullAttributedValue?.string ?? attributedText?.string ?? ""
    let previousTargetLength = fullAttributedValue?.length ?? attributedText?.length ?? 0
    let currentRenderedString = attributedText?.string ?? ""
    let targetString = newAttributedText.string
    let targetDeltaLength = max(0, newAttributedText.length - previousTargetLength)

    // Only a LIVE turn is worth narrating. A settled cell re-applies its full text
    // on every reuse (`previous=0 rendered=0` — the reused view starts empty, so
    // neither the dedup below nor the skip-work early-return can catch it), and it
    // does so twice per configure: once at `window=nil`, once attached. On a
    // transcript of settled agent turns that is 4 synchronous NSLogs per cell per
    // configure while the finger is on the glass — measured as the scroll lag and
    // flicker in the Vibe AI view.
    if Self.streamingLoggingEnabled, isStreaming,
       targetString != previousTargetText || targetString != currentRenderedString {
      logStreaming(
        "apply streaming=%@ previous=%d rendered=%d target=%d delta=%d reveal=%d rawPreview=%@",
        isStreaming ? "true" : "false",
        previousTargetLength,
        currentRenderedString.count,
        newAttributedText.length,
        targetDeltaLength,
        revealSegments.count,
        appendedPreview(in: targetString as NSString, from: 0)
      )
    }

    // Skip work entirely if nothing changed — saves a TextKit re-typeset
    // on identical updates triggered by SwiftUI dependency invalidations.
    if currentRenderedString == targetString,
       previousTargetText == targetString,
       isStreaming == (fullAttributedValue != nil),
       revealSegments.isEmpty {
      return
    }

    fullAttributedValue = newAttributedText

    if !isStreaming {
      if targetString == previousTargetText, !revealSegments.isEmpty {
        displayedCharacterLength = newAttributedText.length
        startStreamingRevealDisplayLinkIfNeeded()
        lastLoggedTargetLength = newAttributedText.length
        return
      }

      if targetString.hasPrefix(previousTargetText), targetDeltaLength > 0, previousTargetLength > 0 {
        enqueueAppendedReveal(
          attributedText: newAttributedText,
          targetString: targetString,
          appendedStart: min(previousTargetLength, newAttributedText.length)
        )
        lastLoggedTargetLength = newAttributedText.length
        return
      }

      cancelChunkFade()
      displayedCharacterLength = newAttributedText.length
      committedCharacterLength = newAttributedText.length
      setDisplayedText(
        newAttributedText,
        animated: previousTargetLength > 0 && targetString != currentRenderedString,
        fadeDuration: Self.streamingFinalFadeDuration
      )
      lastLoggedTargetLength = newAttributedText.length
      return
    }

    let shouldResetReveal =
      !previousTargetText.isEmpty
      && !targetString.hasPrefix(previousTargetText)
    let isAppendOnly = targetString.hasPrefix(previousTargetText) && targetDeltaLength > 0 && previousTargetLength > 0

    let needsUpdate =
      shouldResetReveal
      || targetDeltaLength > 0
      || (currentRenderedString != targetString && revealSegments.isEmpty)

    guard needsUpdate else {
      if isStreaming && !revealSegments.isEmpty {
        startStreamingRevealDisplayLinkIfNeeded()
      }
      return
    }

    if previousTargetLength == 0, currentRenderedString.isEmpty, newAttributedText.length > 0 {
      // First paint of THIS label instance — fresh, recycled, or a measurement pass.
      // Render the whole thing immediately at full opacity; NEVER fade the initial
      // content up from transparent. A cell recycle or a full-transcript re-push (the
      // bridge re-pushes the whole session every watch tick) hands a fresh label the
      // already-known text with previousTargetLength == 0 — revealing it from alpha 0
      // each time IS the "cell blanks, then the text fades back in" flicker the user
      // sees mid-stream. The gentle reveal is reserved for genuinely APPENDED deltas on
      // a persistent label (the isAppendOnly path below), so streamed content only ever
      // grows, never blinks out. Content stays on screen regardless of the connection.
      cancelChunkFade()
      displayedCharacterLength = newAttributedText.length
      committedCharacterLength = newAttributedText.length
      setDisplayedText(newAttributedText, animated: false)
      lastLoggedTargetLength = newAttributedText.length
      return
    }

    displayedCharacterLength = newAttributedText.length

    if isAppendOnly && !shouldResetReveal {
      enqueueAppendedReveal(
        attributedText: newAttributedText,
        targetString: targetString,
        appendedStart: min(previousTargetLength, newAttributedText.length)
      )
    } else {
      cancelChunkFade()
      committedCharacterLength = newAttributedText.length
      setDisplayedText(newAttributedText, animated: false)
    }

    lastLoggedTargetLength = newAttributedText.length
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    // Same rule as `apply`: narrate LIVE turns only, and never an offscreen
    // (`window == nil`) measurement pass. Settled cells re-typeset on reuse and
    // laid out twice per configure, so this fired 2×/cell on every scroll frame.
    guard Self.streamingLoggingEnabled, window != nil, fullAttributedValue != nil,
      attributedText?.length ?? 0 > 0
    else {
      return
    }
    let layoutSignature =
      "\(attributedText?.length ?? 0)|\(targetCharacterLength)|\(displayedCharacterLength)|"
      + "\(Int(bounds.width.rounded()))|\(Int(bounds.height.rounded()))|\(window == nil)"
    if bounds.width <= 1.0 || bounds.height <= 1.0 {
      logStreaming(
        "layout collapsed attributed=%d bounds=%.1fx%.1f window=%@",
        attributedText?.length ?? 0,
        bounds.width,
        bounds.height,
        window == nil ? "nil" : "yes"
      )
    } else if layoutSignature != lastLayoutLogSignature {
      logStreaming(
        "layout visible=%d target=%d displayed=%d bounds=%.1fx%.1f active=%@ window=%@",
        attributedText?.length ?? 0,
        targetCharacterLength,
        displayedCharacterLength,
        bounds.width,
        bounds.height,
        isRevealActiveForMeasurement ? "true" : "false",
        window == nil ? "nil" : "yes"
      )
      lastLayoutLogSignature = layoutSignature
    }
  }

  func resetStreamingState() {
    cancelChunkFade()
    stopStreamingFadeAnimation()
    fullAttributedValue = nil
    displayedCharacterLength = 0
    committedCharacterLength = 0
    lastLoggedTargetLength = 0
    attributedText = nil
  }

  func measurementAttributedText(
    fallback: NSAttributedString,
    isStreaming: Bool
  ) -> (text: NSAttributedString, source: String) {
    return (fallback, "target")
  }

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    guard let renderedText = attributedText, renderedText.length > 0 else {
      return
    }

    let point = gesture.location(in: self)
    let adjustedPoint = CGPoint(
      x: point.x - textContainerInset.left,
      y: point.y - textContainerInset.top
    )
    let characterIndex = layoutManager.characterIndex(
      for: adjustedPoint,
      in: textContainer,
      fractionOfDistanceBetweenInsertionPoints: nil
    )

    guard characterIndex < renderedText.length else {
      return
    }

    let attributes = renderedText.attributes(at: characterIndex, effectiveRange: nil)
    let url: URL?
    if let value = attributes[.link] as? URL {
      url = value
    } else if let value = attributes[.link] as? String {
      url = URL(string: value)
    } else {
      url = nil
    }

    guard let resolvedURL = url else {
      return
    }

    DispatchQueue.main.async {
      UIApplication.shared.open(resolvedURL)
    }
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
    guard fadeDisplayLink == nil else {
      return
    }

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
    guard appendedRange.length > 0 else {
      return
    }

    let now = CACurrentMediaTime()
    let targetNSString = targetString as NSString
    let ranges = revealRanges(in: targetNSString, appendedRange: appendedRange)
    guard !ranges.isEmpty else {
      return
    }

    var nextStartTime: CFTimeInterval
    if let latestQueuedStart = revealSegments.map(\.startTime).max() {
      nextStartTime = max(now, latestQueuedStart + Self.streamingRevealSegmentStagger)
    } else {
      nextStartTime = now
    }

    for (index, range) in ranges.enumerated() {
      revealSegments.append(
        VibeAgentKitStreamingRevealSegment(
          range: range,
          startTime: nextStartTime + CFTimeInterval(index) * Self.streamingRevealSegmentStagger,
          duration: Self.streamingChunkFadeDuration
        )
      )
    }

    if Self.streamingLoggingEnabled {
      let preview = appendedPreview(in: targetNSString, from: appendedRange.location)
      logStreaming(
        "reveal enqueue segments=%d range=%@ preview=%@",
        ranges.count,
        NSStringFromRange(appendedRange),
        preview
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

    // Ensure the displayed string matches target. Setting attributedText only
    // happens when content actually changed (length differs); otherwise we
    // mutate textStorage attributes in-place below, which avoids tearing down
    // the layout each frame and is the core fix for streaming flicker.
    let currentLength = attributedText?.length ?? 0
    let needsContentUpdate = currentLength != target.length
    if needsContentUpdate {
      UIView.performWithoutAnimation {
        self.attributedText = target
      }
      if invalidateLayout {
        invalidateIntrinsicContentSize()
        setNeedsLayout()
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

    var keepers: [VibeAgentKitStreamingRevealSegment] = []

    for segment in revealSegments {
      let safeRange = NSIntersectionRange(segment.range, storageRange)
      guard safeRange.length > 0 else { continue }

      let rawProgress = CGFloat((timestamp - segment.startTime) / segment.duration)
      let isComplete = rawProgress >= 1.0

      if isComplete {
        // Restore base color (full alpha) for this range.
        target.enumerateAttribute(.foregroundColor, in: safeRange, options: []) { value, range, _ in
          guard let baseColor = value as? UIColor else { return }
          storage.addAttribute(.foregroundColor, value: baseColor, range: range)
        }
      } else {
        let progress = max(0.0, rawProgress)
        let eased = easedRevealProgress(progress)
        let alphaFactor = Self.streamingRevealInitialAlpha
          + (1.0 - Self.streamingRevealInitialAlpha) * eased

        target.enumerateAttribute(.foregroundColor, in: safeRange, options: []) { value, range, _ in
          guard let baseColor = value as? UIColor else { return }
          let resolved = baseColor.resolvedColor(with: traitCollection)
          let baseAlpha = resolved.cgColor.alpha
          storage.addAttribute(
            .foregroundColor,
            value: resolved.withAlphaComponent(baseAlpha * alphaFactor),
            range: range
          )
        }

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
    guard safeRange.length > 0 else {
      return []
    }

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
      ranges.append(NSIntersectionRange(composedRange, safeRange))
      cursor = max(NSMaxRange(composedRange), cursor + 1)
    }

    return ranges.filter { $0.length > 0 }
  }

  private func isRevealBoundary(_ character: String) -> Bool {
    guard let scalar = character.unicodeScalars.last else {
      return false
    }
    if CharacterSet.whitespacesAndNewlines.contains(scalar) {
      return true
    }
    return ".!,;:?)]}\u{060C}\u{061B}\u{061F}".unicodeScalars.contains(scalar)
  }

  private func easedRevealProgress(_ progress: CGFloat) -> CGFloat {
    progress * progress * (3.0 - 2.0 * progress)
  }


  private func setDisplayedText(
    _ attributedText: NSAttributedString,
    animated: Bool,
    fadeDuration: CFTimeInterval = VibeAgentKitStreamingTextLabel.streamingChunkFadeDuration,
    invalidateLayout: Bool = true
  ) {
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
    }
  }

  private func appendedPreview(in string: NSString, from previousLength: Int) -> String {
    guard previousLength < string.length else {
      return ""
    }
    let previewLength = min(24, string.length - previousLength)
    let previewRange = string.rangeOfComposedCharacterSequences(
      for: NSRange(location: previousLength, length: previewLength)
    )
    let preview = string.substring(with: previewRange)
      .replacingOccurrences(of: "\n", with: "\\n")
      .replacingOccurrences(of: "\r", with: "\\r")
    if previewRange.location + previewRange.length < string.length {
      return preview + "…"
    }
    return preview
  }

  private func logStreaming(_ format: String, _ args: CVarArg...) {
    withVaList(args) { pointer in
      NSLogv("[VibeAgentKitStreamingText] " + format, pointer)
    }
  }
}
