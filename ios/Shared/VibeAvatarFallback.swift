import UIKit

/// The avatar shown when someone has no profile image.
///
/// Compiled into both the app and the notification service extension, because
/// they must agree: a notification that colours someone differently from the
/// chat list reads as a different person. Keeping two copies in sync by hand is
/// how this codebase lost its notification extension in the first place, so the
/// palette lives here once and `ChatAvatarFallbackStyle` reads it from here.
enum VibeAvatarFallback {
  /// The app's default avatar choices in their stable UI order. The notification
  /// extension compiles this same file, so user-id hashing cannot select a
  /// different tint from `ChatAvatarNodeView`.
  static let paletteDefinitions: [(id: String, start: String, end: String)] = [
    ("warm-gold", "#FFD77A", "#F4A65E"),
    ("aurora", "#B68AF4", "#7D91EA"),
    ("lime", "#C4DC78", "#70BE7D"),
    ("ocean", "#70D8CD", "#4CA7D8"),
    ("ember", "#86C5A5", "#EE7C62"),
    ("rose", "#F6A67F", "#D975C9"),
    ("midnight", "#78A5F5", "#5E72DC"),
    ("earth", "#C9A58A", "#9C7464"),
    ("graphite", "#A0A8B2", "#6D7886"),
    ("ruby", "#ED8491", "#C9586D"),
    ("teal", "#6BCDC9", "#41A9B7"),
    ("mint", "#79DCB3", "#3DB98A"),
    ("coral", "#FF8B6B", "#FF5E79"),
    ("marigold", "#FFE17E", "#F5B15C"),
    ("steel", "#A4B7CF", "#758EAF"),
  ]

  /// Compatibility shape consumed by Home payload models. Avatar-node colors do
  /// not vary by appearance, so both pairs deliberately use the same values.
  static let palettes: [(lightStart: String, lightEnd: String, darkStart: String, darkEnd: String)] =
    paletteDefinitions.map {
      (
        lightStart: $0.start,
        lightEnd: $0.end,
        darkStart: $0.start,
        darkEnd: $0.end
      )
    }

  /// First non-empty of user id, then title, then chat id. The user id leads so
  /// a person keeps their colour even when their display name changes.
  static func stableSeed(title: String?, peerUserId: String?, chatId: String?) -> String {
    let seed = [peerUserId, title, chatId]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
    return seed?.lowercased() ?? ""
  }

  static func paletteIndex(for seed: String) -> Int {
    let normalized = seed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let safeSeed = normalized.isEmpty ? "user" : normalized
    let hash = safeSeed.unicodeScalars.reduce(UInt(0)) { ($0 &* 31) &+ UInt($1.value) }
    return Int(hash % UInt(paletteDefinitions.count))
  }

  static func paletteID(for seed: String) -> String {
    paletteDefinitions[paletteIndex(for: seed)].id
  }

  static func gradient(
    title: String?,
    peerUserId: String?,
    chatId: String? = nil,
    isDark: Bool
  ) -> (UIColor, UIColor) {
    let seed = stableSeed(title: title, peerUserId: peerUserId, chatId: chatId)
    let palette = palettes[paletteIndex(for: seed.isEmpty ? "user" : seed)]
    return (
      color(hex: isDark ? palette.darkStart : palette.lightStart),
      color(hex: isDark ? palette.darkEnd : palette.lightEnd)
    )
  }

  /// Exact `ChatAvatarNodeView` rule: one token yields up to two characters;
  /// multiple tokens use the first character of the first and last tokens.
  static func initials(from name: String) -> String {
    let parts = name.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
    if parts.isEmpty { return "" }
    if parts.count == 1 { return String(parts[0].prefix(2)).uppercased() }
    guard let first = parts.first?.first, let last = parts.last?.first else { return "" }
    return (String(first) + String(last)).uppercased()
  }

  static func color(hex raw: String) -> UIColor {
    var hex = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") { hex.removeFirst() }
    var value: UInt64 = 0
    Scanner(string: hex).scanHexInt64(&value)
    return UIColor(
      red: CGFloat((value >> 16) & 0xff) / 255.0,
      green: CGFloat((value >> 8) & 0xff) / 255.0,
      blue: CGFloat(value & 0xff) / 255.0,
      alpha: 1.0
    )
  }

  /// Renders the gradient disc with initials, or a person glyph when the name
  /// yields nothing usable.
  ///
  /// `isDark` remains for source compatibility; the avatar node deliberately
  /// uses one identity tint in both appearances.
  static func image(
    displayName: String?,
    userId: String?,
    diameter: CGFloat = 120,
    isDark: Bool = false
  ) -> UIImage {
    let name = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let text = initials(from: name)
    let (start, end) = gradient(title: name.isEmpty ? nil : name, peerUserId: userId, isDark: isDark)
    let size = CGSize(width: diameter, height: diameter)

    return UIGraphicsImageRenderer(size: size).image { context in
      let rect = CGRect(origin: .zero, size: size)
      context.cgContext.saveGState()
      context.cgContext.addEllipse(in: rect)
      context.cgContext.clip()

      if let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [start.cgColor, end.cgColor] as CFArray,
        locations: [0, 1]
      ) {
        context.cgContext.drawLinearGradient(
          gradient,
          start: CGPoint(x: 0, y: 0),
          end: CGPoint(x: 0, y: diameter),
          options: []
        )
      } else {
        start.setFill()
        context.cgContext.fill(rect)
      }
      context.cgContext.restoreGState()

      if text.isEmpty {
        let config = UIImage.SymbolConfiguration(pointSize: diameter * 0.48, weight: .medium)
        if let glyph = UIImage(systemName: "person.fill", withConfiguration: config)?
          .withTintColor(.white, renderingMode: .alwaysOriginal)
        {
          let side = diameter * 0.48
          glyph.draw(in: CGRect(
            x: (diameter - side) / 2, y: (diameter - side) / 2, width: side, height: side))
        }
        return
      }

      let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.systemFont(ofSize: diameter * 0.4, weight: .semibold),
        .foregroundColor: UIColor.white,
      ]
      let bounds = (text as NSString).size(withAttributes: attributes)
      (text as NSString).draw(
        at: CGPoint(x: (diameter - bounds.width) / 2, y: (diameter - bounds.height) / 2),
        withAttributes: attributes
      )
    }
  }

  static func imageData(displayName: String?, userId: String?, diameter: CGFloat = 120) -> Data? {
    let image = image(displayName: displayName, userId: userId, diameter: diameter)
    return image.pngData() ?? image.jpegData(compressionQuality: 0.92)
  }
}
