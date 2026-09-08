import UIKit

private func fxColor(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> UIColor {
  UIColor(red: red / 255.0, green: green / 255.0, blue: blue / 255.0, alpha: 1.0)
}

/// Palette and particle recipe for one reaction family.
struct ChatReactionEffectProfile {
  let accent: UIColor
  let ring: UIColor
  let replicaGlowColors: [UIColor]
  let replicaCount: Int
  let spread: ClosedRange<CGFloat>
  let rise: ClosedRange<CGFloat>
  let ringEndScale: CGFloat
  let bubblePulseScale: CGFloat
  let flightRotation: CGFloat
  /// Telegram-style shout particles thrown alongside the emoji replicas.
  let words: [String]

  static func make(
    accent: UIColor,
    ring: UIColor,
    glows: [UIColor],
    words: [String] = [],
    count: Int = 9,
    spread: ClosedRange<CGFloat> = 13.0...29.0,
    rise: ClosedRange<CGFloat> = 3.0...12.0,
    ringScale: CGFloat = 2.0,
    bubbleScale: CGFloat = 1.018,
    rotation: CGFloat = 0.05
  ) -> ChatReactionEffectProfile {
    ChatReactionEffectProfile(
      accent: accent,
      ring: ring,
      replicaGlowColors: glows,
      replicaCount: count,
      spread: spread,
      rise: rise,
      ringEndScale: ringScale,
      bubblePulseScale: bubbleScale,
      flightRotation: rotation,
      words: words
    )
  }
}

/// A named reaction family: its curated emoji, the browse groups its tab spans,
/// and the burst every emoji in it plays.
struct ChatReactionCategory {
  let id: String
  let title: String
  let symbolName: String
  let glyph: String
  let emojis: [String]
  let browseGroups: [ChatEmojiCategory]
  let searchHints: [String]
  let effect: ChatReactionEffectProfile
}

/// One source of truth for the picker's tabs and the FX profiles: every emoji
/// resolves to a category, and every category owns a designed burst.
enum ChatReactionCatalog {
  static let collapsedEmojis: [String] = ["⭐️", "❤️", "👍", "👎", "🔥", "🥰", "👏"]

  static let categories: [ChatReactionCategory] = [
    ChatReactionCategory(
      id: "smileys",
      title: "Smileys",
      symbolName: "face.smiling",
      glyph: "😀",
      emojis: [
        "😀", "😃", "😄", "😁", "😆", "😅", "😂", "🤣", "🥲", "🙂", "🙃", "😉", "😊",
        "😇", "😌", "😋", "😛", "😜", "🤪", "😝", "🤗", "🤭", "🤫", "🤔", "🤨", "😐",
        "😑", "😶", "🙄", "😏", "😴", "🤤", "😪", "🤠", "🥳", "😎", "🤓", "🧐", "🤡",
        "👻", "💀", "👽", "🤖", "😺", "😸", "😹",
      ],
      browseGroups: [.smileys],
      searchHints: ["face", "grin", "smil"],
      effect: .make(
        accent: fxColor(250, 194, 31),
        ring: fxColor(255, 224, 102),
        glows: [fxColor(252, 179, 20), fxColor(255, 234, 122), fxColor(255, 205, 60)],
        words: ["HA", "HEH", "lol", "haha", "hehe"],
        count: 11, spread: 16.0...34.0, rise: 6.0...20.0, ringScale: 2.3,
        bubbleScale: 1.024, rotation: 0.12
      )
    ),
    ChatReactionCategory(
      id: "hearts",
      title: "Hearts",
      symbolName: "heart.fill",
      glyph: "❤️",
      emojis: [
        "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💔", "💕", "💞", "💓",
        "💗", "💖", "💘", "💝", "💟", "😍", "🥰", "😘", "😗", "😙", "😚", "😻", "💋",
        "🌹", "💐", "🫶",
      ],
      browseGroups: [],
      searchHints: ["heart", "kiss", "love", "rose"],
      effect: .make(
        accent: fxColor(255, 76, 120),
        ring: fxColor(255, 143, 176),
        glows: [fxColor(255, 64, 110), fxColor(255, 143, 176), fxColor(255, 189, 209)],
        words: ["love", "aww", "xo", "mwah"],
        count: 12, spread: 15.0...33.0, rise: 10.0...26.0, ringScale: 2.5,
        bubbleScale: 1.026, rotation: -0.11
      )
    ),
    ChatReactionCategory(
      id: "hands",
      title: "Gestures",
      symbolName: "hand.thumbsup.fill",
      glyph: "👍",
      emojis: [
        "👍", "👎", "👌", "🤌", "🤏", "✌️", "🤞", "🫰", "🤟", "🤘", "🤙", "👈", "👉",
        "👆", "👇", "☝️", "🫵", "👋", "🤚", "🖐️", "✋", "🖖", "🫱", "🫲", "🫳", "🫴",
        "👏", "🙌", "👐", "🤲", "🤝", "🙏", "💪", "✍️", "🦾", "🫡",
      ],
      browseGroups: [.people],
      searchHints: ["hand", "finger", "thumb"],
      effect: .make(
        accent: fxColor(56, 160, 252),
        ring: fxColor(135, 197, 255),
        glows: [fxColor(69, 168, 255), fxColor(158, 216, 255), fxColor(214, 238, 255)],
        words: ["yes", "ok", "+1", "nice"],
        count: 9, spread: 15.0...31.0, rise: 3.0...12.0, ringScale: 2.1,
        bubbleScale: 1.02, rotation: 0.09
      )
    ),
    ChatReactionCategory(
      id: "moods",
      title: "Feelings",
      symbolName: "face.dashed",
      glyph: "😢",
      emojis: [
        "😢", "😭", "😞", "😔", "😟", "😕", "🙁", "☹️", "😣", "😖", "😫", "😩", "🥺",
        "🥹", "😤", "😠", "😡", "🤬", "😨", "😰", "😱", "😳", "🤯", "🤢", "🤮", "🥵",
        "🥶", "😵", "🫠", "😬", "🤥", "😒", "😓", "🤕", "🤒", "😷",
      ],
      browseGroups: [],
      searchHints: ["cry", "sad", "angry", "pout", "frown", "weary"],
      effect: .make(
        accent: fxColor(120, 143, 190),
        ring: fxColor(168, 186, 219),
        glows: [fxColor(110, 132, 176), fxColor(168, 186, 219), fxColor(214, 224, 240)],
        words: ["omg", "nooo", "ugh", "wow"],
        count: 8, spread: 12.0...26.0, rise: 1.0...9.0, ringScale: 1.9,
        bubbleScale: 1.016, rotation: -0.08
      )
    ),
    ChatReactionCategory(
      id: "animals",
      title: "Animals",
      symbolName: "pawprint.fill",
      glyph: "🐻",
      emojis: [
        "🐶", "🐱", "🐭", "🐹", "🐰", "🦊", "🐻", "🐼", "🐨", "🐯", "🦁", "🐮", "🐷",
        "🐸", "🐵", "🙈", "🙉", "🙊", "🐔", "🐧", "🐦", "🐤", "🦆", "🦅", "🦉", "🦇",
        "🐺", "🐗", "🐴", "🦄", "🐝", "🦋", "🐌", "🐞", "🐢", "🐍", "🐙", "🦀", "🐠",
        "🐬", "🐳", "🦈", "🌸", "🌼", "🌻", "🌈", "🌿", "🍀", "🌳", "🌊",
      ],
      browseGroups: [.nature],
      searchHints: ["cat", "dog", "flower", "tree", "leaf"],
      effect: .make(
        accent: fxColor(94, 190, 122),
        ring: fxColor(152, 219, 170),
        glows: [fxColor(84, 186, 116), fxColor(160, 222, 176), fxColor(226, 244, 210)],
        words: ["aww", "cute", "rawr"],
        count: 10, spread: 14.0...30.0, rise: 8.0...22.0, ringScale: 2.2,
        bubbleScale: 1.021, rotation: 0.1
      )
    ),
    ChatReactionCategory(
      id: "food",
      title: "Food",
      symbolName: "fork.knife",
      glyph: "🍔",
      emojis: [
        "🍏", "🍎", "🍐", "🍊", "🍋", "🍌", "🍉", "🍇", "🍓", "🫐", "🍒", "🍑", "🥭",
        "🍍", "🥝", "🍅", "🥑", "🌽", "🌶️", "🥦", "🍞", "🥐", "🧀", "🥚", "🍳", "🥓",
        "🍔", "🍟", "🍕", "🌭", "🥪", "🌮", "🌯", "🥗", "🍝", "🍜", "🍣", "🍱", "🍩",
        "🍪", "🎂", "🧁", "🍰", "🍫", "🍬", "🍭", "🍿", "☕️", "🍵", "🍺", "🍻", "🥂",
        "🍷", "🥤",
      ],
      browseGroups: [.food],
      searchHints: ["food", "fruit", "drink"],
      effect: .make(
        accent: fxColor(240, 132, 56),
        ring: fxColor(250, 186, 118),
        glows: [fxColor(240, 122, 46), fxColor(250, 190, 118), fxColor(255, 224, 168)],
        words: ["yum", "mmm", "nom"],
        count: 9, spread: 13.0...27.0, rise: 4.0...15.0, ringScale: 2.0,
        bubbleScale: 1.019, rotation: 0.07
      )
    ),
    ChatReactionCategory(
      id: "activity",
      title: "Activity",
      symbolName: "figure.run",
      glyph: "⚽️",
      emojis: [
        "⚽️", "🏀", "🏈", "⚾️", "🥎", "🎾", "🏐", "🏉", "🎱", "🏓", "🏸", "🥅", "🏒",
        "🏑", "🏏", "⛳️", "🏹", "🎣", "🥊", "🥋", "⛸️", "🎿", "⛷️", "🏂", "🏋️", "🤸",
        "⛹️", "🏌️", "🧘", "🏄", "🏊", "🚴", "🚵", "🏆", "🥇", "🥈", "🥉", "🎯", "🎮",
        "🕹️", "🎲", "♟️", "🎸", "🎺", "🥁", "🎧", "🎤", "🎬",
      ],
      browseGroups: [.activity],
      searchHints: ["ball", "sport", "medal", "music"],
      effect: .make(
        accent: fxColor(72, 186, 214),
        ring: fxColor(140, 216, 234),
        glows: [fxColor(58, 178, 210), fxColor(146, 218, 236), fxColor(206, 240, 248)],
        words: ["go", "lets go", "yes"],
        count: 10, spread: 18.0...36.0, rise: 5.0...17.0, ringScale: 2.2,
        bubbleScale: 1.022, rotation: 0.14
      )
    ),
    ChatReactionCategory(
      id: "travel",
      title: "Travel",
      symbolName: "airplane",
      glyph: "✈️",
      emojis: [
        "🚀", "✈️", "🛸", "🚁", "🚂", "🚗", "🏎️", "🏍️", "🛵", "🚲", "⛵️", "🚤", "🛳️",
        "⚓️", "🗺️", "🏝️", "🏔️", "⛰️", "🌋", "🏕️", "🏖️", "🌅", "🌄", "🌇", "🌆", "🏙️",
        "🌃", "🌉", "🗽", "🗼", "🏰", "🎡", "🎢", "🎠", "⛲️", "🧭", "⏳", "🌍", "🌎",
        "🌏", "🛩️", "🚦",
      ],
      browseGroups: [.travel],
      searchHints: ["rocket", "car", "plane", "island"],
      effect: .make(
        accent: fxColor(122, 132, 246),
        ring: fxColor(174, 181, 252),
        glows: [fxColor(110, 122, 246), fxColor(178, 186, 252), fxColor(222, 226, 255)],
        words: ["woosh", "zoom", "go"],
        count: 10, spread: 20.0...42.0, rise: 12.0...30.0, ringScale: 2.4,
        bubbleScale: 1.023, rotation: 0.18
      )
    ),
    ChatReactionCategory(
      id: "objects",
      title: "Objects",
      symbolName: "lightbulb.fill",
      glyph: "💡",
      emojis: [
        "🔥", "⭐️", "🌟", "✨", "💫", "💥", "⚡️", "💧", "💯", "❗️", "❓", "✅", "❌",
        "⚠️", "🔔", "🔒", "🔑", "💰", "💎", "🎁", "💡", "📱", "💻", "⌨️", "🖥️", "📷",
        "🎥", "📺", "⏰", "⏱️", "🔍", "🔧", "🔨", "🧲", "🧪", "💊", "📚", "📝", "✏️",
        "📌", "📎", "📊", "📈", "📉", "🗑️", "🚫", "💤", "💩",
      ],
      browseGroups: [.objects, .symbols],
      searchHints: ["fire", "star", "sparkle", "bolt"],
      effect: .make(
        accent: fxColor(255, 125, 41),
        ring: fxColor(255, 174, 74),
        glows: [fxColor(255, 107, 31), fxColor(255, 179, 61), fxColor(255, 219, 107)],
        words: ["whoa", "boom", "100", "fire"],
        count: 11, spread: 12.0...28.0, rise: 14.0...32.0, ringScale: 2.3,
        bubbleScale: 1.025, rotation: -0.13
      )
    ),
    ChatReactionCategory(
      id: "celebration",
      title: "Party",
      symbolName: "party.popper.fill",
      glyph: "🎉",
      emojis: [
        "🎉", "🎊", "🥳", "🎈", "🎁", "🎂", "🍾", "🥂", "🎆", "🎇", "🧨", "🎀", "🎗️",
        "🏆", "🥇", "👑", "💐", "🪅", "🪩", "🕺", "💃", "🎵", "🎶", "🤩", "🙌",
      ],
      browseGroups: [],
      searchHints: ["party", "confetti", "balloon", "trophy", "celebrat"],
      effect: .make(
        accent: fxColor(242, 74, 135),
        ring: fxColor(250, 176, 64),
        glows: [
          fxColor(255, 69, 130), fxColor(255, 207, 51), fxColor(79, 212, 242),
          fxColor(143, 199, 77),
        ],
        words: ["yay", "woo", "PARTY", "nice"],
        count: 14, spread: 20.0...40.0, rise: 6.0...20.0, ringScale: 2.6,
        bubbleScale: 1.028, rotation: 0.16
      )
    ),
  ]

  /// Quick row first, then every curated emoji, deduped on the normalized form.
  static let allEmojis: [String] = {
    var seen = Set<String>()
    var ordered: [String] = []
    for emoji in ChatReactionCatalog.collapsedEmojis
      + ChatReactionCatalog.categories.flatMap({ $0.emojis })
    where seen.insert(ChatReactionKey.normalized(emoji)).inserted {
      ordered.append(emoji)
    }
    return ordered
  }()

  static var defaultCategory: ChatReactionCategory { categories[0] }

  /// Curated membership first, then the emoji's Unicode block, then smileys.
  static func category(for emoji: String) -> ChatReactionCategory {
    let key = ChatReactionKey.normalized(emoji)
    if let index = curatedIndex[key] { return categories[index] }
    if let group = browseGroup(for: emoji), let index = browseIndex[group] {
      return categories[index]
    }
    return defaultCategory
  }

  static func category(withId id: String) -> ChatReactionCategory? {
    categories.first { $0.id == id }
  }

  /// Which Unicode block an emoji sits in, using the browse ranges the panel shares.
  static func browseGroup(for emoji: String) -> ChatEmojiCategory? {
    guard let scalar = ChatReactionKey.normalized(emoji).unicodeScalars.first else { return nil }
    if scalar.value >= 0x1F1E6, scalar.value <= 0x1F1FF { return .flags }
    for group in ChatEmojiCategory.browseCases
    where group.scalarRanges.contains(where: { $0.contains(scalar.value) }) {
      return group
    }
    return nil
  }

  private static let curatedIndex: [String: Int] = {
    var index: [String: Int] = [:]
    for (position, category) in ChatReactionCatalog.categories.enumerated() {
      for emoji in category.emojis {
        let key = ChatReactionKey.normalized(emoji)
        if index[key] == nil { index[key] = position }
      }
    }
    return index
  }()

  private static let browseIndex: [ChatEmojiCategory: Int] = {
    var index: [ChatEmojiCategory: Int] = [:]
    for (position, category) in ChatReactionCatalog.categories.enumerated() {
      for group in category.browseGroups where index[group] == nil {
        index[group] = position
      }
    }
    return index
  }()
}

final class ChatReactionTransitionCoordinator {
  static let shared = ChatReactionTransitionCoordinator()

  struct Token: Hashable {
    fileprivate let chatId: String
    fileprivate let messageId: String
    fileprivate let id: UUID
  }

  private struct MessageKey: Hashable {
    let chatId: String
    let messageId: String
  }

  private struct Flight {
    let id: UUID
    let emoji: String
    var isFlying: Bool
    var transportAccepted: Bool
  }

  private let lock = NSLock()
  private var flights: [MessageKey: Flight] = [:]

  private init() {}

  func begin(chatId: String, messageId: String, emoji: String) -> Token {
    let token = Token(chatId: chatId, messageId: messageId, id: UUID())
    withLock {
      flights[MessageKey(chatId: chatId, messageId: messageId)] = Flight(
        id: token.id, emoji: emoji, isFlying: true, transportAccepted: false)
    }
    return token
  }

  func isCurrent(_ token: Token) -> Bool {
    withLock {
      flights[MessageKey(chatId: token.chatId, messageId: token.messageId)]?.id == token.id
    }
  }

  func isFlying(chatId: String, messageId: String, emoji: String) -> Bool {
    withLock {
      guard let flight = flights[MessageKey(chatId: chatId, messageId: messageId)] else {
        return false
      }
      return flight.emoji == emoji && flight.isFlying
    }
  }

  func finishFlight(_ token: Token) {
    withLock {
      let key = MessageKey(chatId: token.chatId, messageId: token.messageId)
      guard var flight = flights[key], flight.id == token.id else { return }
      flight.isFlying = false
      if flight.transportAccepted {
        flights.removeValue(forKey: key)
      } else {
        flights[key] = flight
      }
    }
  }

  func resolveTransport(_ token: Token, accepted: Bool) -> Bool {
    withLock {
      let key = MessageKey(chatId: token.chatId, messageId: token.messageId)
      guard var flight = flights[key], flight.id == token.id else { return false }
      if !accepted || !flight.isFlying {
        flights.removeValue(forKey: key)
      } else {
        flight.transportAccepted = true
        flights[key] = flight
      }
      return true
    }
  }

  private func withLock<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}

final class ChatReactionFxModule {
  static let shared = ChatReactionFxModule()

  private init() {}

  func animateReactionFlight(
    emoji: String,
    from sourcePoint: CGPoint,
    to targetPoint: CGPoint,
    in hostView: UIView,
    bubbleView: UIView?,
    completion: @escaping () -> Void
  ) {
    let style = profile(for: emoji, tintOverride: nil)
    let duration: TimeInterval = 0.30

    let container = UIView(frame: hostView.bounds)
    container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.backgroundColor = .clear
    container.isUserInteractionEnabled = false
    container.clipsToBounds = false
    hostView.addSubview(container)

    let source = container.convert(sourcePoint, from: hostView)
    let target = container.convert(targetPoint, from: hostView)
    let wrapper = UIView(frame: CGRect(x: 0, y: 0, width: 44, height: 44))
    wrapper.center = source
    wrapper.alpha = 1
    wrapper.isUserInteractionEnabled = false
    container.addSubview(wrapper)

    let label = UILabel()
    label.text = emoji
    label.font = UIFont.systemFont(ofSize: 30)
    label.textAlignment = .center
    label.frame = wrapper.bounds
    label.alpha = 1
    label.layer.contentsScale = UIScreen.main.scale
    label.layer.shadowColor = UIColor.black.withAlphaComponent(0.26).cgColor
    label.layer.shadowRadius = 5.0
    label.layer.shadowOffset = CGSize(width: 0.0, height: 2.0)
    label.layer.shadowOpacity = 1.0
    wrapper.addSubview(label)

    let dx = target.x - source.x
    let dy = target.y - source.y
    let arcLift = max(18.0, min(48.0, abs(dx) * 0.16 + abs(dy) * 0.10))
    let control = CGPoint(
      x: source.x + (dx * 0.5),
      y: min(source.y, target.y) - arcLift
    )

    let travelPath = UIBezierPath()
    travelPath.move(to: source)
    travelPath.addQuadCurve(to: target, controlPoint: control)

    let position = CAKeyframeAnimation(keyPath: "position")
    position.path = travelPath.cgPath
    position.duration = duration
    position.calculationMode = .paced
    position.timingFunction = CAMediaTimingFunction(name: .easeOut)

    let scale = CAKeyframeAnimation(keyPath: "transform.scale")
    scale.values = [1.0, 1.12, 1.0]
    scale.keyTimes = [0.0, 0.38, 1.0]
    scale.duration = duration

    let rotation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
    rotation.values = [0.0, style.flightRotation, 0.0]
    rotation.keyTimes = [0.0, 0.48, 1.0]
    rotation.duration = duration
    rotation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

    let group = CAAnimationGroup()
    group.animations = [position, scale, rotation]
    group.duration = duration
    wrapper.layer.position = target
    wrapper.layer.add(group, forKey: "reactionFlight")

    if let bubbleView {
      let base = bubbleView.transform
      DispatchQueue.main.asyncAfter(deadline: .now() + (duration * 0.58)) { [weak bubbleView] in
        guard let bubbleView else { return }
        UIView.animate(
          withDuration: 0.08,
          delay: 0.0,
          options: [.curveEaseOut, .beginFromCurrentState]
        ) {
          bubbleView.transform = base.scaledBy(x: style.bubblePulseScale, y: style.bubblePulseScale)
        } completion: { _ in
          UIView.animate(
            withDuration: 0.10,
            delay: 0.0,
            options: [.curveEaseOut, .beginFromCurrentState]
          ) {
            bubbleView.transform = base
          }
        }
      }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
      wrapper.layer.removeAllAnimations()
      wrapper.removeFromSuperview()
      container.removeFromSuperview()
      completion()
    }
  }

  func playLandingEffect(
    emoji: String,
    at point: CGPoint,
    in hostView: UIView,
    tintOverride: UIColor?
  ) {
    let style = profile(for: emoji, tintOverride: tintOverride)

    let effectView = UIView(frame: hostView.bounds)
    effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    effectView.backgroundColor = .clear
    effectView.isUserInteractionEnabled = false
    effectView.clipsToBounds = false
    hostView.addSubview(effectView)
    let arrival = effectView.convert(point, from: hostView)

    let ringRadius: CGFloat = 8.0
    let ringLayer = CAShapeLayer()
    ringLayer.path =
      UIBezierPath(
        ovalIn: CGRect(
          x: -ringRadius, y: -ringRadius, width: ringRadius * 2.0, height: ringRadius * 2.0)
      ).cgPath
    ringLayer.position = arrival
    ringLayer.fillColor = UIColor.clear.cgColor
    ringLayer.strokeColor = style.ring.withAlphaComponent(0.42).cgColor
    ringLayer.lineWidth = 1.0
    ringLayer.shadowColor = style.accent.withAlphaComponent(0.18).cgColor
    ringLayer.shadowOpacity = 1
    ringLayer.shadowRadius = 3
    ringLayer.shadowOffset = .zero
    effectView.layer.addSublayer(ringLayer)

    let ringScale = CABasicAnimation(keyPath: "transform.scale")
    ringScale.fromValue = 0.72
    ringScale.toValue = min(style.ringEndScale, 2.15)
    ringScale.duration = 0.34
    ringScale.timingFunction = CAMediaTimingFunction(name: .easeOut)

    let ringOpacity = CABasicAnimation(keyPath: "opacity")
    ringOpacity.fromValue = 0.42
    ringOpacity.toValue = 0.0
    ringOpacity.duration = 0.34
    ringOpacity.timingFunction = CAMediaTimingFunction(name: .easeOut)

    let ringGroup = CAAnimationGroup()
    ringGroup.animations = [ringScale, ringOpacity]
    ringGroup.duration = 0.34
    ringGroup.fillMode = .forwards
    ringGroup.isRemovedOnCompletion = false
    ringLayer.add(ringGroup, forKey: "ringPulse")

    let count = max(5, style.replicaCount)
    for idx in 0..<count {
      let glow = style.replicaGlowColors[idx % style.replicaGlowColors.count]
      addReplica(
        emoji: emoji,
        index: idx,
        total: count,
        from: arrival,
        glowColor: glow,
        style: style,
        in: effectView
      )
    }


    let words = style.words
    if !words.isEmpty {
      let wordCount = min(words.count, 5)
      let start = Int.random(in: 0..<words.count)
      for idx in 0..<wordCount {
        addWordParticle(
          text: words[(start + idx) % words.count],
          index: idx,
          total: wordCount,
          from: arrival,
          color: style.replicaGlowColors[idx % style.replicaGlowColors.count],
          style: style,
          in: effectView
        )
      }
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
      effectView.removeFromSuperview()
    }
  }

  /// Telegram's coloured shout particles: they fly wider and outlive the emoji replicas.
  private func addWordParticle(
    text: String,
    index: Int,
    total: Int,
    from point: CGPoint,
    color: UIColor,
    style: ChatReactionEffectProfile,
    in effectView: UIView
  ) {
    let size = random(14.0...20.0)
    let base = UIFont.systemFont(ofSize: size, weight: .heavy)
    let font =
      base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
    let label = UILabel()
    label.attributedText = NSAttributedString(
      string: text,
      attributes: [
        .font: font,
        .foregroundColor: color,
        .strokeColor: UIColor.white,
        .strokeWidth: -3.4,
      ])
    label.textAlignment = .center
    label.sizeToFit()
    label.center = point
    label.layer.contentsScale = UIScreen.main.scale
    label.layer.shadowColor = UIColor.black.withAlphaComponent(0.30).cgColor
    label.layer.shadowOpacity = 1
    label.layer.shadowRadius = 2.5
    label.layer.shadowOffset = CGSize(width: 0.0, height: 1.0)
    effectView.addSubview(label)

    // Fan across the upper half so words arc out of the bubble, never straight down.
    let sweep = CGFloat.pi * 1.32
    let angle =
      -CGFloat.pi * 0.5 - (sweep * 0.5) + (sweep * (CGFloat(index) + 0.5) / CGFloat(max(1, total)))
      + random(-0.10...0.10)
    let travel = random(style.spread) * 1.9 + 12.0
    let lift = random(style.rise) * 1.3
    let endPoint = CGPoint(
      x: point.x + cos(angle) * travel,
      y: point.y + sin(angle) * travel - lift
    )
    let control = CGPoint(
      x: (point.x + endPoint.x) * 0.5,
      y: min(point.y, endPoint.y) - random(10.0...26.0)
    )
    let path = UIBezierPath()
    path.move(to: point)
    path.addQuadCurve(to: endPoint, controlPoint: control)

    let duration: CFTimeInterval = 0.58
    let move = CAKeyframeAnimation(keyPath: "position")
    move.path = path.cgPath
    move.calculationMode = .paced
    move.duration = duration
    move.timingFunction = CAMediaTimingFunction(name: .easeOut)

    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
    spin.fromValue = 0.0
    spin.toValue = random(-0.55...0.55)
    spin.duration = duration

    let scale = CAKeyframeAnimation(keyPath: "transform.scale")
    scale.values = [0.35, 1.14, 0.92]
    scale.keyTimes = [0.0, 0.28, 1.0]
    scale.duration = duration
    scale.timingFunctions = [
      CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn),
    ]

    let opacity = CAKeyframeAnimation(keyPath: "opacity")
    opacity.values = [0.0, 1.0, 1.0, 0.0]
    opacity.keyTimes = [0.0, 0.12, 0.66, 1.0]
    opacity.duration = duration

    let group = CAAnimationGroup()
    group.animations = [move, spin, scale, opacity]
    group.duration = duration
    group.fillMode = .forwards
    group.isRemovedOnCompletion = false
    label.layer.add(group, forKey: "wordBurst")

    DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) {
      label.removeFromSuperview()
    }
  }

  private func addReplica(
    emoji: String,
    index: Int,
    total: Int,
    from point: CGPoint,
    glowColor: UIColor,
    style: ChatReactionEffectProfile,
    in effectView: UIView
  ) {
    let replica = UILabel(frame: CGRect(x: 0, y: 0, width: 22, height: 22))
    replica.text = emoji
    replica.font = UIFont.systemFont(ofSize: random(10.0...14.0))
    replica.textAlignment = .center
    replica.center = point
    replica.alpha = 1
    replica.layer.contentsScale = UIScreen.main.scale
    replica.layer.shadowColor = glowColor.withAlphaComponent(0.32).cgColor
    replica.layer.shadowOpacity = 1
    replica.layer.shadowRadius = 3
    replica.layer.shadowOffset = .zero
    effectView.addSubview(replica)

    let baseAngle = (CGFloat(index) / CGFloat(max(1, total))) * .pi * 2.0
    let jitter = random(-0.16...0.16)
    let angle = baseAngle + jitter
    let travel = random(style.spread)
    let rise = random(style.rise)
    let endPoint = CGPoint(
      x: point.x + (cos(angle) * travel),
      y: point.y + (sin(angle) * travel) - rise
    )

    let move = CABasicAnimation(keyPath: "position")
    move.fromValue = point
    move.toValue = endPoint
    move.duration = 0.40
    move.timingFunction = CAMediaTimingFunction(name: .easeOut)

    let opacity = CAKeyframeAnimation(keyPath: "opacity")
    opacity.values = [1.0, 1.0, 0.0]
    opacity.keyTimes = [0.0, 0.62, 1.0]
    opacity.duration = 0.40

    let scale = CAKeyframeAnimation(keyPath: "transform.scale")
    scale.values = [0.55, 1.0, 0.78]
    scale.keyTimes = [0.0, 0.30, 1.0]
    scale.duration = 0.40
    scale.timingFunctions = [
      CAMediaTimingFunction(name: .easeOut),
      CAMediaTimingFunction(name: .easeIn),
    ]

    let group = CAAnimationGroup()
    group.animations = [move, opacity, scale]
    group.duration = 0.40
    group.fillMode = .forwards
    group.isRemovedOnCompletion = false
    replica.layer.add(group, forKey: "replicaBurst")

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
      replica.removeFromSuperview()
    }
  }

  /// Every emoji resolves through its catalog category, so nothing falls back to a stub.
  private func profile(for emoji: String, tintOverride: UIColor?) -> ChatReactionEffectProfile {
    let base = ChatReactionCatalog.category(for: emoji).effect
    guard let tint = tintOverride else { return base }
    return ChatReactionEffectProfile(
      accent: tint,
      ring: tint.withAlphaComponent(0.74),
      replicaGlowColors: [tint, tint.withAlphaComponent(0.76)] + base.replicaGlowColors,
      replicaCount: base.replicaCount,
      spread: base.spread,
      rise: base.rise,
      ringEndScale: base.ringEndScale,
      bubblePulseScale: base.bubblePulseScale,
      flightRotation: base.flightRotation,
      words: base.words
    )
  }

  private static func normalizedEmoji(_ emoji: String) -> String {
    ChatReactionKey.normalized(emoji)
  }

  private func random(_ range: ClosedRange<CGFloat>) -> CGFloat {
    range.lowerBound + CGFloat.random(in: 0.0...1.0) * (range.upperBound - range.lowerBound)
  }
}
