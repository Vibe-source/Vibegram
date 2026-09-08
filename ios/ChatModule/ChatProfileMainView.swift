import SwiftUI
import UIKit
import AVFoundation
import PhotosUI

import CoreImage.CIFilterBuiltins

private struct ChatEncryptionVerifyView: View {
  let chatId: String
  let peerUserId: String
  let peerName: String
  private let pendingSignatureKey: Data?
  private let safetyCode: String?
  private let keyArtHue: CGFloat
  private let keyArtLevels: [Int]?
  private let identityChanged: Bool

  @Environment(\.dismiss) private var dismiss
  @State private var acceptanceFailed = false

  init(chatId: String, peerUserId: String, peerName: String) {
    self.chatId = chatId
    self.peerUserId = peerUserId
    self.peerName = peerName
    // A joiner claims no KeyPackage, so it can reach this screen holding no pin
    // at all; the group's own tree is the missing half.
    VibeSecureSessions.shared.ensurePeerPinned(chatId: chatId, peerUserId: peerUserId)
    let pending = VibeSecureTrust.pendingChange(userId: peerUserId)
    pendingSignatureKey = pending
    identityChanged = pending != nil

    let signatureKey = pending ?? VibeSecureTrust.pinnedKey(userId: peerUserId)
    if let mine = VibeSecureSessions.shared.mySignatureKey(), let signatureKey {
      safetyCode = VibeSecureTrust.safetyCodeHex(myKey: mine, peerKey: signatureKey)
    } else {
      safetyCode = nil
    }
    let art = safetyCode.flatMap { Self.keyArtGrid(for: $0) }
    keyArtHue = art?.hue ?? 0
    keyArtLevels = art?.levels
  }

  var body: some View {
    VStack(spacing: 0) {
      if identityChanged {
        Label("Encryption identity changed", systemImage: "exclamationmark.triangle.fill")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.orange)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 20)
          .padding(.vertical, 12)
          .background(Color.orange.opacity(0.12))
      }
      qrSurface
      keyBar
    }
    .background(Color(.systemBackground))
    .navigationTitle("Verify Encryption")
    .navigationBarTitleDisplayMode(.inline)
  }

  /// The code itself is the surface — no card, no light backing. It fills the
  /// band and sits dead centre so the art reads as the screen, not an image on one.
  private var qrSurface: some View {
    ZStack {
      if let keyArtLevels {
        let side = UIScreen.main.bounds.width
        let palette = Self.keyArtPalette(hue: keyArtHue).map { Color($0) }
        // Drawn as vector tiles, not an upscaled bitmap — no resampling blur.
        Canvas { context, size in
          let tile = size.width / CGFloat(Self.keyArtDimension)
          for index in keyArtLevels.indices {
            let row = CGFloat(index / Self.keyArtDimension)
            let column = CGFloat(index % Self.keyArtDimension)
            let rect = CGRect(
              x: column * tile,
              y: row * tile,
              width: tile + 0.5,
              height: tile + 0.5
            )
            context.fill(Path(rect), with: .color(palette[keyArtLevels[index]]))
          }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
      } else {
        Text("Encryption identity is not available yet.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(32)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var keyBar: some View {
    VStack(spacing: 14) {
      if let safetyCode {
        keyBlock(safetyCode)
      }
      Text(peerCaption)
        .font(.footnote.weight(.medium))
        .multilineTextAlignment(.center)
        .foregroundStyle(.primary)
      Text(assurance)
        .font(.footnote)
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
      if identityChanged {
        Button("Accept Identity Change") {
          let accepted = VibeSecureTrust.acceptPendingChange(
            userId: peerUserId,
            expectedSignatureKey: pendingSignatureKey
          )
          if accepted {
            dismiss()
          } else {
            acceptanceFailed = true
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(.orange)

        if acceptanceFailed {
          Text("The identity changed again. Close this screen and verify the latest code.")
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 20)
    .padding(.top, 18)
    .padding(.bottom, 28)
  }

  private var peerCaption: String {
    let name = peerName.trimmingCharacters(in: .whitespacesAndNewlines)
    return "This key belongs to your chat with \(name.isEmpty ? peerUserId : name)"
  }

  /// Code + seeded art for the profile row preview — same source as this sheet.
  static func rowIdentity(peerUserId: String) -> (code: String, art: UIImage)? {
    let signatureKey = VibeSecureTrust.pendingChange(userId: peerUserId)
      ?? VibeSecureTrust.pinnedKey(userId: peerUserId)
    guard let mine = VibeSecureSessions.shared.mySignatureKey(), let signatureKey else { return nil }
    let code = VibeSecureTrust.safetyCodeHex(myKey: mine, peerKey: signatureKey)
    // Rendered at exact device pixels so the row preview never resamples.
    let side = (26 * UIScreen.main.scale).rounded()
    guard !code.isEmpty, let art = keyArtImage(for: code, side: side) else { return nil }
    return (code, art)
  }

  private var assurance: String {
    if identityChanged {
      return "This contact reinstalled or changed device. Until this new code matches theirs, treat the chat as unverified."
    }
    return "If your contact sees this exact code, no one else can read this chat — not Vibe, not the server."
  }

  /// Four rows of four groups — the shape an eye scans for a mismatch.
  private func keyBlock(_ code: String) -> some View {
    let groups = stride(from: 0, to: code.count, by: 4).map { offset -> String in
      let start = code.index(code.startIndex, offsetBy: offset)
      let end = code.index(start, offsetBy: min(4, code.count - offset))
      return String(code[start..<end])
    }
    let rows = stride(from: 0, to: groups.count, by: 4).map { offset in
      Array(groups[offset..<min(offset + 4, groups.count)])
    }
    return VStack(spacing: 8) {
      ForEach(rows.indices, id: \.self) { row in
        HStack(spacing: 14) {
          ForEach(rows[row].indices, id: \.self) { column in
            Text(rows[row][column])
              .font(.system(.title3, design: .monospaced))
              .fontWeight(.medium)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .center)
    .textSelection(.enabled)
  }

  /// Soft tonal tiles in one seeded tint; both peers derive the same image from
  /// the order-independent safety code.
  fileprivate static let keyArtDimension = 12

  /// One tint per identity, in tonal steps off white — no second hue anywhere.
  fileprivate static func keyArtPalette(hue: CGFloat) -> [UIColor] {
    [
      UIColor(hue: hue, saturation: 0.04, brightness: 1.00, alpha: 1),
      UIColor(hue: hue, saturation: 0.11, brightness: 0.96, alpha: 1),
      UIColor(hue: hue, saturation: 0.20, brightness: 0.89, alpha: 1),
      UIColor(hue: hue, saturation: 0.32, brightness: 0.80, alpha: 1),
    ]
  }

  fileprivate static func keyArtGrid(for code: String) -> (hue: CGFloat, levels: [Int])? {
    let bytes = Array(code.utf8)
    guard !bytes.isEmpty else { return nil }

    var seed: UInt32 = 2_166_136_261
    for byte in bytes {
      seed = (seed ^ UInt32(byte)) &* 16_777_619
    }
    var state = seed
    let count = keyArtDimension * keyArtDimension
    var levels: [Int] = []
    levels.reserveCapacity(count)
    for index in 0..<count {
      state = state &* 1_664_525 &+ 1_013_904_223 &+ UInt32(bytes[index % bytes.count])
      levels.append(Int((state >> 30) & 3))
    }
    return (CGFloat(seed % 360) / 360, levels)
  }

  /// Bitmap for the small profile-row preview; the full screen draws vectors instead.
  private static func keyArtImage(for code: String, side: CGFloat) -> UIImage? {
    guard let grid = keyArtGrid(for: code) else { return nil }
    let palette = keyArtPalette(hue: grid.hue)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(
      size: CGSize(width: side, height: side),
      format: format
    )
    let tile = side / CGFloat(keyArtDimension)

    return renderer.image { context in
      for index in grid.levels.indices {
        let row = CGFloat(index / keyArtDimension)
        let column = CGFloat(index % keyArtDimension)
        context.cgContext.setFillColor(palette[grid.levels[index]].cgColor)
        context.cgContext.fill(
          CGRect(x: column * tile, y: row * tile, width: tile + 0.5, height: tile + 0.5)
        )
      }
    }.withRenderingMode(.alwaysOriginal)
  }

}

enum ChatProfileAppearanceMode: String, CaseIterable, Identifiable {
  case avatar
  case poster
  case banner

  var id: String { rawValue }

  var title: String {
    switch self {
    case .avatar:
      return "Avatar"
    case .poster:
      return "Poster"
    case .banner:
      return "Banner"
    }
  }
}

enum ChatProfileBannerStyle: String, CaseIterable, Identifiable {
  case solid
  case gradient

  var id: String { rawValue }

  var title: String {
    switch self {
    case .solid:
      return "Solid"
    case .gradient:
      return "Gradient"
    }
  }

  /// Defaults missing/unknown values to `.gradient`.
  static func style(id: String?) -> ChatProfileBannerStyle {
    guard let id, let style = allCases.first(where: { $0.rawValue == id }) else {
      return .gradient
    }
    return style
  }
}

struct ChatProfileAppearanceSelection: Codable, Equatable {
  var avatarPaletteID: String
  var posterPaletteID: String
  var avatarGlyph: String?
  var avatarFontStyleID: String?
  var avatarCustomStartHex: String?
  var avatarCustomEndHex: String?
  var posterCustomStartHex: String?
  var posterCustomEndHex: String?
  var posterImageData: Data?
  /// Optional so older UserDefaults payloads decode without these keys.
  var bannerPaletteID: String?
  var bannerStyleID: String?
  var bannerCustomStartHex: String?
  var bannerCustomEndHex: String?

  static let `default` = ChatProfileAppearanceSelection(
    avatarPaletteID: ChatProfileAppearancePalette.defaultAvatarID,
    posterPaletteID: ChatProfileAppearancePalette.defaultPosterID,
    avatarGlyph: nil,
    avatarFontStyleID: nil,
    avatarCustomStartHex: nil,
    avatarCustomEndHex: nil,
    posterCustomStartHex: nil,
    posterCustomEndHex: nil,
    posterImageData: nil,
    bannerPaletteID: nil,
    bannerStyleID: nil,
    bannerCustomStartHex: nil,
    bannerCustomEndHex: nil
  )
}

enum ChatProfileAvatarFontStyle: String, CaseIterable, Identifiable {
  case rounded
  case standard
  case serif
  case mono

  var id: String { rawValue }

  var design: Font.Design {
    switch self {
    case .rounded:
      return .rounded
    case .standard:
      return .default
    case .serif:
      return .serif
    case .mono:
      return .monospaced
    }
  }

  static func style(id: String?) -> ChatProfileAvatarFontStyle {
    guard let id, let style = allCases.first(where: { $0.rawValue == id }) else {
      return .rounded
    }
    return style
  }
}

struct ChatProfileAppearancePalette: Identifiable, Equatable {
  let id: String
  let topHex: String
  let bottomHex: String

  static let defaultAvatarID = "warm-gold"
  static let defaultPosterID = "poster-soft-neutral"

  static let all: [ChatProfileAppearancePalette] =
    VibeAvatarFallback.paletteDefinitions.map {
      ChatProfileAppearancePalette(id: $0.id, topHex: $0.start, bottomHex: $0.end)
    } + [
      ChatProfileAppearancePalette(
        id: "poster-soft-neutral", topHex: "#DCD7CF", bottomHex: "#A9876F"),
      ChatProfileAppearancePalette(id: "poster-black", topHex: "#050507", bottomHex: "#000000"),
    ]

  static let defaultAvatarPalettes: [ChatProfileAppearancePalette] = all.filter {
    $0.id != defaultPosterID && $0.id != "poster-black"
  }

  static func palette(id: String) -> ChatProfileAppearancePalette {
    all.first(where: { $0.id == id }) ?? all[0]
  }

  static func colors(
    for selection: ChatProfileAppearanceSelection,
    mode: ChatProfileAppearanceMode
  ) -> (UIColor, UIColor) {
    switch mode {
    case .avatar:
      let palette = palette(id: selection.avatarPaletteID)
      return (
        uiColor(hex: selection.avatarCustomStartHex ?? palette.topHex),
        uiColor(hex: selection.avatarCustomEndHex ?? palette.bottomHex)
      )
    case .poster:
      let palette = palette(id: selection.posterPaletteID)
      return (
        uiColor(hex: selection.posterCustomStartHex ?? palette.topHex),
        uiColor(hex: selection.posterCustomEndHex ?? palette.bottomHex)
      )
    case .banner:
      // Inherit avatar palette/custom colors until the user sets banner values.
      let hasExplicitBanner =
        selection.bannerPaletteID != nil
        || selection.bannerCustomStartHex != nil
        || selection.bannerCustomEndHex != nil
      if hasExplicitBanner {
        let paletteID = selection.bannerPaletteID ?? selection.avatarPaletteID
        let palette = palette(id: paletteID)
        return (
          uiColor(hex: selection.bannerCustomStartHex ?? palette.topHex),
          uiColor(hex: selection.bannerCustomEndHex ?? palette.bottomHex)
        )
      }
      return colors(for: selection, mode: .avatar)
    }
  }

  static func uiColor(hex raw: String) -> UIColor {
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
}

enum ChatProfileAppearanceStore {
  private static let defaultsPrefix = "chatProfileAppearance.v1."

  static let didChangeNotification = Notification.Name("ChatProfileAppearanceStore.didChange")

  static func selection(title: String?, peerUserId: String?, chatId: String?) -> ChatProfileAppearanceSelection {
    let key = defaultsKey(title: title, peerUserId: peerUserId, chatId: chatId)
    guard let data = UserDefaults.standard.data(forKey: key),
      let decoded = try? JSONDecoder().decode(ChatProfileAppearanceSelection.self, from: data)
    else {
      return defaultSelection(title: title, peerUserId: peerUserId, chatId: chatId)
    }
    return normalizedStoredSelection(decoded, title: title, peerUserId: peerUserId, chatId: chatId)
  }

  static func save(
    _ selection: ChatProfileAppearanceSelection,
    title: String?,
    peerUserId: String?,
    chatId: String?
  ) {
    let key = defaultsKey(title: title, peerUserId: peerUserId, chatId: chatId)
    guard let data = try? JSONEncoder().encode(selection) else { return }
    UserDefaults.standard.set(data, forKey: key)

    var userInfo: [AnyHashable: Any] = [:]
    if let title { userInfo["title"] = title }
    if let peerUserId { userInfo["peerUserId"] = peerUserId }
    if let chatId { userInfo["chatId"] = chatId }
    NotificationCenter.default.post(
      name: didChangeNotification,
      object: nil,
      userInfo: userInfo.isEmpty ? nil : userInfo
    )
  }

  static func avatarColors(title: String?, peerUserId: String?, chatId: String?) -> (UIColor, UIColor) {
    ChatProfileAppearancePalette.colors(
      for: selection(title: title, peerUserId: peerUserId, chatId: chatId),
      mode: .avatar
    )
  }

  static func posterColors(title: String?, peerUserId: String?, chatId: String?) -> (UIColor, UIColor) {
    ChatProfileAppearancePalette.colors(
      for: selection(title: title, peerUserId: peerUserId, chatId: chatId),
      mode: .poster
    )
  }

  static func bannerColors(title: String?, peerUserId: String?, chatId: String?) -> (UIColor, UIColor) {
    let current = selection(title: title, peerUserId: peerUserId, chatId: chatId)
    let colors = ChatProfileAppearancePalette.colors(for: current, mode: .banner)
    switch ChatProfileBannerStyle.style(id: current.bannerStyleID) {
    case .solid:
      return (colors.0, colors.0)
    case .gradient:
      return colors
    }
  }

  static func bannerStyle(title: String?, peerUserId: String?, chatId: String?) -> ChatProfileBannerStyle {
    ChatProfileBannerStyle.style(
      id: selection(title: title, peerUserId: peerUserId, chatId: chatId).bannerStyleID
    )
  }

  static func posterImage(title: String?, peerUserId: String?, chatId: String?) -> UIImage? {
    let selection = selection(title: title, peerUserId: peerUserId, chatId: chatId)
    guard let data = selection.posterImageData else { return nil }
    return UIImage(data: data)
  }

  private static func defaultsKey(title: String?, peerUserId: String?, chatId: String?) -> String {
    let seed = defaultsSeed(title: title, peerUserId: peerUserId, chatId: chatId)
    let safeSeed = seed.isEmpty ? "user" : seed
    return defaultsPrefix + safeSeed
  }

  private static func defaultsSeed(title: String?, peerUserId: String?, chatId: String?) -> String {
    ChatAvatarFallbackStyle.stableSeed(
      title: title,
      peerUserId: peerUserId,
      chatId: chatId
    )
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
  }

  private static func defaultSelection(
    title: String?,
    peerUserId: String?,
    chatId: String?
  ) -> ChatProfileAppearanceSelection {
    var selection = ChatProfileAppearanceSelection.default
    selection.avatarPaletteID = defaultAvatarPaletteID(seed: defaultsSeed(
      title: title,
      peerUserId: peerUserId,
      chatId: chatId
    ))
    selection.posterPaletteID = ChatProfileAppearancePalette.defaultPosterID
    return selection
  }

  private static func normalizedStoredSelection(
    _ selection: ChatProfileAppearanceSelection,
    title: String?,
    peerUserId: String?,
    chatId: String?
  ) -> ChatProfileAppearanceSelection {
    var normalized = selection
    if normalized.posterPaletteID == "warm-cocoa" || normalized.posterPaletteID == "poster-black" {
      normalized.posterPaletteID = ChatProfileAppearancePalette.defaultPosterID
    }
    if normalized.avatarPaletteID == ChatProfileAppearancePalette.defaultAvatarID
      && normalized.avatarCustomStartHex == nil
      && normalized.avatarCustomEndHex == nil
      && normalized.avatarGlyph == nil
      && normalized.avatarFontStyleID == nil
    {
      normalized.avatarPaletteID = defaultAvatarPaletteID(seed: defaultsSeed(
        title: title,
        peerUserId: peerUserId,
        chatId: chatId
      ))
    }
    return normalized
  }

  private static func defaultAvatarPaletteID(seed: String) -> String {
    VibeAvatarFallback.paletteID(for: seed)
  }
}

private extension UIColor {
  var chatProfileHexString: String {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "#000000" }
    return String(
      format: "#%02X%02X%02X",
      Int(round(red * 255.0)),
      Int(round(green * 255.0)),
      Int(round(blue * 255.0))
    )
  }

  func blended(withFraction fraction: CGFloat, of color: UIColor) -> UIColor {
    var red1: CGFloat = 0
    var green1: CGFloat = 0
    var blue1: CGFloat = 0
    var alpha1: CGFloat = 0
    var red2: CGFloat = 0
    var green2: CGFloat = 0
    var blue2: CGFloat = 0
    var alpha2: CGFloat = 0
    guard getRed(&red1, green: &green1, blue: &blue1, alpha: &alpha1),
      color.getRed(&red2, green: &green2, blue: &blue2, alpha: &alpha2)
    else {
      return self
    }
    let clamped = max(0, min(1, fraction))
    return UIColor(
      red: red1 + (red2 - red1) * clamped,
      green: green1 + (green2 - green1) * clamped,
      blue: blue1 + (blue2 - blue1) * clamped,
      alpha: alpha1 + (alpha2 - alpha1) * clamped
    )
  }
}

@MainActor
private final class NativeProfileAvatarModel: ObservableObject {
  @Published var fallbackText: String = "U"
  @Published var loadedImage: UIImage?
  @Published var expandedSize: CGFloat = 100.0
  @Published var collapsedSize: CGFloat = 40.0
  @Published var expandedTopInset: CGFloat = 0.0
  @Published var collapsedTopInset: CGFloat = 0.0
  @Published var scrollOffset: CGFloat = 0.0
  @Published var islandCoverColor: UIColor = UIColor(red: 0.071, green: 0.071, blue: 0.075, alpha: 1.0)
  @Published var fallbackBackgroundColor: UIColor = UIColor(
    red: 222 / 255,
    green: 230 / 255,
    blue: 243 / 255,
    alpha: 1.0
  )
  @Published var fallbackGradientEndColor: UIColor = UIColor(
    red: 139 / 255,
    green: 65 / 255,
    blue: 27 / 255,
    alpha: 1.0
  )
  @Published var fallbackIconTintColor: UIColor = UIColor.darkText

  private var imageUri: String?
  private var imageTask: Task<Void, Never>?

  deinit {
    imageTask?.cancel()
  }

  func setImageUri(_ value: String?) {
    let normalizedValue = value?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty

    guard normalizedValue != imageUri else { return }
    imageUri = normalizedValue
    imageTask?.cancel()

    guard let normalizedValue else {
      loadedImage = nil
      return
    }

    // Serve from cache immediately so reopening the profile shows no fallback flicker.
    if let cached = ChatAvatarImageStore.cached(for: normalizedValue) {
      loadedImage = cached
      return
    }

    // CRITICAL: do NOT clear `loadedImage` here. Clearing forces the giant letter
    // fallback while the new URL loads (race). Keep the previous photo (if any)
    // until the new one arrives; only empty state shows the letter.
    imageTask = Task { [weak self] in
      let image = await NativeProfileAvatarImageLoader.load(from: normalizedValue)
      guard !Task.isCancelled else { return }

      await MainActor.run {
        guard let self, self.imageUri == normalizedValue else { return }
        if let image {
          self.loadedImage = image
        }
      }
    }
  }

  /// Directly set a locally-rendered image that has no source URL — e.g. the group
  /// mosaic composed from member avatars. Clears any pending URL load and the
  /// tracked `imageUri` so a later `setImageUri(nil)` on the same (group) refresh
  /// path is a no-op and doesn't wipe the composite.
  func setComposedImage(_ image: UIImage?) {
    imageTask?.cancel()
    imageUri = nil
    loadedImage = image
  }
}

extension String {
  fileprivate var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}

private enum NativeProfileAvatarImageLoader {
  static func load(from rawValue: String?) async -> UIImage? {
    await ChatAvatarImageStore.load(from: rawValue)
  }
}

enum NativeProfileAvatarHeroMetrics {
  static let topAdjust: CGFloat = 12
  static let islandAnchor: CGFloat = 56
  static let topOffset: CGFloat = 86
  static let collapsedTopOffset: CGFloat = 18
  static let expandedSize: CGFloat = 196
  static let collapsedSize: CGFloat = 34
  static let bottomSpacing: CGFloat = 14

  static func expandedTop(for safeTop: CGFloat) -> CGFloat {
    max(0, safeTop - islandAnchor - topAdjust) + topOffset
  }

  static func collapsedTop(for safeTop: CGFloat) -> CGFloat {
    max(0, safeTop - 18 - collapsedTopOffset)
  }

  static func hostHeight(for safeTop: CGFloat) -> CGFloat {
    expandedTop(for: safeTop) + expandedSize + bottomSpacing
  }
}

private struct NativeProfileAvatarContentView: View {
  @ObservedObject var model: NativeProfileAvatarModel

  var body: some View {
    NativeProfileAvatarLegacyView(model: model)
  }
}

private struct NativeProfileAvatarInnerContent: View {
  let image: UIImage?
  let fallbackText: String
  let fallbackIconTintColor: UIColor
  let fallbackBackgroundColor: UIColor
  let fallbackGradientEndColor: UIColor
  let size: CGFloat

  var body: some View {
    ZStack {
      if let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: size * 3.25, height: size * 2.25)
          .blur(radius: max(22, size * 0.24))
          .opacity(0.50)
          .saturation(1.22)
      }

      if let image {
        ZStack {
          LinearGradient(
            colors: [
              Color(uiColor: fallbackBackgroundColor),
              Color(uiColor: fallbackGradientEndColor),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )

          Image(uiImage: image)
            .resizable()
            .scaledToFill()
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
          Circle()
            .stroke(Color.white.opacity(0.20), lineWidth: 1)
        }
      } else {
        // Match `ChatAvatarNodeView` / Home tiles: vertical gradient + white initial.
        ZStack {
          LinearGradient(
            colors: [
              Color(uiColor: fallbackBackgroundColor),
              Color(uiColor: fallbackGradientEndColor),
            ],
            startPoint: .top,
            endPoint: .bottom
          )

          Text(fallbackText)
            .font(.system(size: max(10.0, size * 0.4), weight: .semibold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .multilineTextAlignment(.center)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
      }
    }
  }
}

private struct NativeProfileAvatarLegacyView: View {
  @ObservedObject var model: NativeProfileAvatarModel

  private var progress: CGFloat {
    max(0.0, min(1.0, model.scrollOffset / 220.0))
  }

  private var currentSize: CGFloat {
    model.expandedSize - (22.0 * progress)
  }

  private var currentTopInset: CGFloat {
    model.expandedTopInset - (10.0 * progress)
  }

  var body: some View {
    NativeProfileAvatarInnerContent(
      image: model.loadedImage,
      fallbackText: model.fallbackText,
      fallbackIconTintColor: model.fallbackIconTintColor,
      fallbackBackgroundColor: model.fallbackBackgroundColor,
      fallbackGradientEndColor: model.fallbackGradientEndColor,
      size: currentSize
    )
    .padding(.top, currentTopInset)
    .opacity(1.0)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}

final class NativeProfileAvatarView: UIView {
  private let model = NativeProfileAvatarModel()
  private let hostingController: UIHostingController<AnyView>
  private var isHostingControllerAttached = false
  private var currentImageUri: String?
  private var currentFallbackText: String = "U"
  private var currentExpandedSize: CGFloat = 100.0
  private var currentCollapsedSize: CGFloat = 40.0
  private var currentExpandedTopInset: CGFloat = 0.0
  private var currentCollapsedTopInset: CGFloat = 0.0
  private var currentScrollOffset: CGFloat = 0.0
  private var currentIslandCoverColor: UIColor = UIColor(red: 0.071, green: 0.071, blue: 0.075, alpha: 1.0)
  private var currentFallbackBackgroundColor: UIColor = UIColor(
    red: 222 / 255,
    green: 230 / 255,
    blue: 243 / 255,
    alpha: 1.0
  )
  private var currentFallbackGradientEndColor: UIColor = UIColor(
    red: 139 / 255,
    green: 65 / 255,
    blue: 27 / 255,
    alpha: 1.0
  )
  private var currentFallbackIconTintColor: UIColor = UIColor.darkText

  override init(frame: CGRect) {
    hostingController = UIHostingController(
      rootView: AnyView(NativeProfileAvatarContentView(model: model))
    )
    super.init(frame: frame)

    backgroundColor = .clear
    clipsToBounds = false

    if #available(iOS 16.4, *) {
      hostingController.safeAreaRegions = []
    }

    let hostedView = hostingController.view!
    hostedView.translatesAutoresizingMaskIntoConstraints = false
    hostedView.backgroundColor = .clear
    hostedView.clipsToBounds = false
    addSubview(hostedView)

    NSLayoutConstraint.activate([
      hostedView.leadingAnchor.constraint(equalTo: leadingAnchor),
      hostedView.trailingAnchor.constraint(equalTo: trailingAnchor),
      hostedView.topAnchor.constraint(equalTo: topAnchor),
      hostedView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil, !isHostingControllerAttached {
      if let parentVC = findNearestViewController() {
        parentVC.addChild(hostingController)
        hostingController.didMove(toParent: parentVC)
        isHostingControllerAttached = true
      }
    } else if window == nil, isHostingControllerAttached {
      hostingController.willMove(toParent: nil)
      hostingController.removeFromParent()
      isHostingControllerAttached = false
    }
  }

  private func findNearestViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let next = responder?.next {
      if let vc = next as? UIViewController {
        return vc
      }
      responder = next
    }
    return nil
  }

  func setImageUri(_ value: String?) {
    let nextValue = value?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty
    guard currentImageUri != nextValue else { return }
    currentImageUri = nextValue
    publishModelChange { $0.setImageUri(nextValue) }
  }

  /// Show a locally-composed image (the group mosaic) with no backing URL.
  func setComposedImage(_ image: UIImage?) {
    currentImageUri = nil
    publishModelChange { $0.setComposedImage(image) }
  }

  func setFallbackText(_ value: String?) {
    let nextValue =
      (value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? value : "U") ?? "U"
    guard currentFallbackText != nextValue else { return }
    currentFallbackText = nextValue
    publishModelChange { $0.fallbackText = nextValue }
  }

  func setExpandedSize(_ value: CGFloat?) {
    let resolved = max(1.0, value ?? 100.0)
    guard currentExpandedSize != resolved else { return }
    currentExpandedSize = resolved
    publishModelChange { $0.expandedSize = resolved }
  }

  func setCollapsedSize(_ value: CGFloat?) {
    let resolved = max(1.0, value ?? 40.0)
    guard currentCollapsedSize != resolved else { return }
    currentCollapsedSize = resolved
    publishModelChange { $0.collapsedSize = resolved }
  }

  func setExpandedTopInset(_ value: CGFloat?) {
    let resolved = max(0.0, value ?? 0.0)
    guard currentExpandedTopInset != resolved else { return }
    currentExpandedTopInset = resolved
    publishModelChange { $0.expandedTopInset = resolved }
  }

  func setCollapsedTopInset(_ value: CGFloat?) {
    let resolved = max(0.0, value ?? 0.0)
    guard currentCollapsedTopInset != resolved else { return }
    currentCollapsedTopInset = resolved
    publishModelChange { $0.collapsedTopInset = resolved }
  }

  func setScrollOffset(_ value: CGFloat?) {
    let resolved = max(0.0, value ?? 0.0)
    guard currentScrollOffset != resolved else { return }
    currentScrollOffset = resolved
    publishModelChange { $0.scrollOffset = resolved }
  }

  func setIslandCoverUIColor(_ value: UIColor) {
    guard currentIslandCoverColor != value else { return }
    currentIslandCoverColor = value
    publishModelChange { $0.islandCoverColor = value }
  }

  func setFallbackGradientUIColors(start: UIColor, end: UIColor) {
    guard currentFallbackBackgroundColor != start || currentFallbackGradientEndColor != end else { return }
    currentFallbackBackgroundColor = start
    currentFallbackGradientEndColor = end
    publishModelChange {
      $0.fallbackBackgroundColor = start
      $0.fallbackGradientEndColor = end
    }
  }

  func setFallbackIconTintUIColor(_ value: UIColor) {
    guard currentFallbackIconTintColor != value else { return }
    currentFallbackIconTintColor = value
    publishModelChange { $0.fallbackIconTintColor = value }
  }

  private func publishModelChange(_ update: @escaping (NativeProfileAvatarModel) -> Void) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      update(self.model)
    }
  }
}

private struct ChatProfileRow {
  let messageId: String
  let type: String
  let text: String
  let mediaUrl: String?
  let localMediaUrl: String?
  let mediaKey: String?
  let fileName: String?
  let fileSize: Int64?
  let timestampMs: Int64?
  let isPinned: Bool
  let isAgentMessage: Bool
  let duration: CGFloat?
  let waveform: [CGFloat]?
  let thumbnailBase64: String?
  let musicCoverURL: String?
  let musicArtist: String?
  let musicSource: String?

  /// Prefers bytes already on disk; the remote URL is ciphertext for sealed media,
  /// so a grid pointed at it decodes nothing and stays on the blur preview.
  var resolvedMediaURL: String? {
    if let local = localMediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !local.isEmpty {
      let path = URL(string: local).flatMap { $0.isFileURL ? $0.path : nil } ?? local
      if FileManager.default.fileExists(atPath: path) {
        return URL(fileURLWithPath: path).absoluteString
      }
    }
    guard let remote = mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !remote.isEmpty
    else { return mediaUrl }
    let vault = VibeMediaVault.shared
    for key in [
      VibeMediaVault.identity(rawURL: remote, mediaKey: mediaKey),
      VibeMediaVault.identity(rawURL: remote, mediaKey: nil),
    ] {
      if let url = vault.cachedURL(for: key, kind: .image) { return url.absoluteString }
      if let url = vault.cachedURL(for: key, kind: .document) { return url.absoluteString }
    }
    return remote
  }

  static func parse(_ raw: [String: Any]) -> ChatProfileRow? {
    let message = raw["message"] as? [String: Any] ?? raw
    let metadata = message["metadata"] as? [String: Any]
    let messageId =
      (message["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? (raw["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? UUID().uuidString
    let type = ((message["type"] as? String) ?? (raw["type"] as? String) ?? "text").lowercased()
    let text =
      (message["text"] as? String)
      ?? (message["caption"] as? String)
      ?? (raw["text"] as? String)
      ?? (raw["caption"] as? String)
      ?? ""
    let localMediaUrl =
      (message["localMediaUrl"] as? String)
      ?? (message["local_media_url"] as? String)
      ?? (metadata?["localMediaUrl"] as? String)
      ?? (metadata?["local_media_url"] as? String)
    let resolvedLocalMediaUrl =
      localMediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines)
    let hasUsableLocalMedia: Bool = {
      guard let resolvedLocalMediaUrl, !resolvedLocalMediaUrl.isEmpty else { return false }
      let localPath: String
      if let parsed = URL(string: resolvedLocalMediaUrl), parsed.isFileURL {
        localPath = parsed.path
      } else {
        localPath = resolvedLocalMediaUrl
      }
      return FileManager.default.fileExists(atPath: localPath)
    }()
    let messageMediaUrl =
      (message["mediaUrl"] as? String) ?? (message["media_url"] as? String)
    let metadataMediaUrl =
      (metadata?["mediaUrl"] as? String) ?? (metadata?["media_url"] as? String)
    let messageAttachmentUrl =
      (message["uri"] as? String) ?? (message["audioUrl"] as? String)
    let metadataAttachmentUrl =
      (metadata?["uri"] as? String) ?? (metadata?["audioUrl"] as? String)
    let remoteMediaUrl =
      messageMediaUrl
      ?? metadataMediaUrl
      ?? messageAttachmentUrl
      ?? metadataAttachmentUrl
      ?? (raw["mediaUrl"] as? String)
    let mediaUrl = hasUsableLocalMedia ? resolvedLocalMediaUrl : remoteMediaUrl
    let mediaKey =
      (message["mediaKey"] as? String)
      ?? (message["media_key"] as? String)
      ?? (metadata?["mediaKey"] as? String)
      ?? (metadata?["media_key"] as? String)
    let fileName =
      (message["fileName"] as? String)
      ?? (message["file_name"] as? String)
      ?? (metadata?["fileName"] as? String)
      ?? (metadata?["file_name"] as? String)
      ?? (raw["fileName"] as? String)

    let messageFileSizeNumber = message["fileSize"] as? NSNumber
    let rawFileSizeNumber = raw["fileSize"] as? NSNumber
    let fileSize = messageFileSizeNumber?.int64Value ?? rawFileSizeNumber?.int64Value

    let timestampRaw =
      message["timestampMs"] ?? message["timestamp"] ?? raw["timestampMs"] ?? raw["timestamp"]
    let timestampMs: Int64? = {
      if let number = timestampRaw as? NSNumber {
        let value = number.int64Value
        return value < 2_000_000_000 ? (value * 1000) : value
      }
      if let text = timestampRaw as? String {
        if let numeric = Double(text), numeric.isFinite {
          let value = Int64(numeric)
          return value < 2_000_000_000 ? (value * 1000) : value
        }
        let parsed = ISO8601DateFormatter().date(from: text)
        if let parsed { return Int64(parsed.timeIntervalSince1970 * 1000.0) }
      }
      return nil
    }()

    let isPinned =
      (message["isPinned"] as? Bool == true)
      || (raw["isPinned"] as? Bool == true)
      || (message["pinned"] as? Bool == true)
      || (raw["pinned"] as? Bool == true)

    let isAgentMessage =
      (message["isAgentMessage"] as? Bool == true)
      || (raw["isAgentMessage"] as? Bool == true)
      || (metadata?["isAgentMessage"] as? Bool == true)
      || ((metadata?["agentBridgeProvider"] as? String)?.isEmpty == false)
      || ((metadata?["agentRuntime"] as? [String: Any]) != nil)

    let duration: CGFloat? = {
      if let val = message["duration"] as? NSNumber { return CGFloat(val.floatValue) }
      if let val = metadata?["duration"] as? NSNumber { return CGFloat(val.floatValue) }
      if let val = raw["duration"] as? NSNumber { return CGFloat(val.floatValue) }
      return nil
    }()

    let waveform = parseChatProfileWaveform(message["waveform"] ?? raw["waveform"])

    let thumbnailBase64 =
      (message["thumbnailBase64"] as? String)
      ?? (message["thumbnail_base64"] as? String)
      ?? (metadata?["thumbnailBase64"] as? String)
      ?? (metadata?["thumbnail_base64"] as? String)
      ?? (raw["thumbnailBase64"] as? String)

    let musicCoverURL =
      (metadata?["cover"] as? String)
      ?? (metadata?["coverUrl"] as? String)
      ?? (metadata?["artworkUrl"] as? String)
      ?? (message["cover"] as? String)
    let musicArtist =
      (metadata?["artist"] as? String)
      ?? (metadata?["uploader"] as? String)
      ?? (message["artist"] as? String)
    let musicSource =
      (metadata?["source"] as? String)
      ?? (metadata?["platform"] as? String)
      ?? (message["source"] as? String)

    return ChatProfileRow(
      messageId: messageId,
      type: type,
      text: text,
      mediaUrl: mediaUrl,
      localMediaUrl: localMediaUrl,
      mediaKey: mediaKey,
      fileName: fileName,
      fileSize: fileSize,
      timestampMs: timestampMs,
      isPinned: isPinned,
      isAgentMessage: isAgentMessage,
      duration: duration,
      waveform: waveform,
      thumbnailBase64: thumbnailBase64,
      musicCoverURL: musicCoverURL,
      musicArtist: musicArtist,
      musicSource: musicSource
    )
  }
}

private func normalizeChatProfileWaveformArray(_ rawList: [Any]) -> [CGFloat]? {
  let values: [CGFloat] = rawList.compactMap { item in
    if let number = item as? NSNumber {
      return CGFloat(truncating: number)
    }
    if let text = item as? String, let value = Double(text) {
      return CGFloat(value)
    }
    return nil
  }
  let normalized = values.filter { $0.isFinite }.map { max(0.0, min(1.0, $0)) }
  return normalized.isEmpty ? nil : normalized
}

private func chatProfileWaveformBitValue(
  data: UnsafeRawPointer,
  length: Int,
  bitOffset: Int,
  bitWidth: Int
) -> Int32 {
  guard length > 0, bitWidth > 0 else { return 0 }

  let byteOffset = bitOffset / 8
  guard byteOffset < length else { return 0 }

  let normalizedData = data.advanced(by: byteOffset)
  let normalizedBitOffset = bitOffset % 8
  let mask = UInt32((1 << bitWidth) - 1)

  var value: UInt32 = 0
  let bytesToCopy = min(MemoryLayout<UInt32>.size, length - byteOffset)
  memcpy(&value, normalizedData, bytesToCopy)

  return Int32((value >> UInt32(normalizedBitOffset)) & mask)
}

private func decodeChatProfileWaveformBitstream(_ data: Data, bitsPerSample: Int = 5) -> [CGFloat]? {
  guard !data.isEmpty, bitsPerSample > 0 else { return nil }

  let sampleCount = (data.count * 8) / bitsPerSample
  guard sampleCount > 0 else { return nil }

  let maxValue = CGFloat((1 << bitsPerSample) - 1)
  var result: [CGFloat] = []
  result.reserveCapacity(sampleCount)

  data.withUnsafeBytes { bytes in
    guard let baseAddress = bytes.baseAddress else { return }
    for index in 0..<sampleCount {
      let value = chatProfileWaveformBitValue(
        data: baseAddress,
        length: data.count,
        bitOffset: index * bitsPerSample,
        bitWidth: bitsPerSample
      )
      result.append(max(0.0, min(1.0, CGFloat(value) / maxValue)))
    }
  }

  return result.isEmpty ? nil : result
}

private func parseChatProfileWaveform(_ raw: Any?) -> [CGFloat]? {
  if let array = raw as? [Any], !array.isEmpty {
    return normalizeChatProfileWaveformArray(array)
  }

  guard let text = raw as? String else { return nil }
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }

  if trimmed.hasPrefix("["),
    let data = trimmed.data(using: .utf8),
    let json = try? JSONSerialization.jsonObject(with: data),
    let array = json as? [Any]
  {
    return normalizeChatProfileWaveformArray(array)
  }

  if let data = Data(base64Encoded: trimmed) {
    return decodeChatProfileWaveformBitstream(data)
  }

  return nil
}

private struct ChatProfileLinkItem {
  let row: ChatProfileRow
  let url: String
}

private enum ChatProfileTab: String, CaseIterable {
  case media
  case music
  case voice
  case gifs
  case files
  case links
  case pinned

  var label: String {
    switch self {
    case .media:
      return "Media"
    case .music:
      return "Music"
    case .voice:
      return "Voice"
    case .gifs:
      return "GIFs"
    case .files:
      return "Files"
    case .links:
      return "Links"
    case .pinned:
      return "Pinned"
    }
  }
}

private enum ChatProfileInfoRow {
  case members
  case identifier
  case agent
  case bio
}

private struct ChatProfileGroupedRowView: View {
  let title: String
  let subtitle: String
  let systemImage: String?
  let showsChevron: Bool
  let titleColor: UIColor
  let subtitleColor: UIColor
  let separatorColor: UIColor
  let isLast: Bool

  private var hasSubtitle: Bool {
    !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: hasSubtitle ? 3 : 0) {
        Text(title)
          .font(.system(size: 17, weight: .regular))
          .foregroundStyle(Color(uiColor: titleColor))
          .lineLimit(1)
          .minimumScaleFactor(0.78)

        if hasSubtitle {
          Text(subtitle)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(Color(uiColor: subtitleColor))
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(Color(uiColor: subtitleColor))
      }

      if showsChevron {
        Image(systemName: "chevron.right")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(Color(uiColor: subtitleColor).opacity(0.75))
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, hasSubtitle ? 11 : 13)
    .frame(maxWidth: .infinity, minHeight: hasSubtitle ? 62 : 48, alignment: .center)
    .overlay(alignment: .bottom) {
      if !isLast {
        Rectangle()
          .fill(Color(uiColor: separatorColor))
          .frame(height: 1.0 / UIScreen.main.scale)
          .padding(.leading, 18)
      }
    }
  }
}

private struct ChatProfileModernRowView: View {
  let title: String
  let subtitle: String
  let value: String
  let iconName: String
  let showsChevron: Bool
  let isDark: Bool
  let titleColor: UIColor
  let subtitleColor: UIColor
  let accentColor: UIColor
  let cardColor: UIColor
  let separatorColor: UIColor

  private var hasSubtitle: Bool {
    !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var hasValue: Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var body: some View {
    HStack(spacing: 14) {
      ZStack {
        Circle()
          .fill(Color(uiColor: accentColor).opacity(isDark ? 0.20 : 0.14))
        Image(systemName: iconName)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(Color(uiColor: accentColor))
      }
      .frame(width: 38, height: 38)

      VStack(alignment: .leading, spacing: hasSubtitle ? 3 : 0) {
        Text(title)
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(Color(uiColor: titleColor))
          .lineLimit(1)
          .minimumScaleFactor(0.78)

        if hasSubtitle {
          Text(subtitle)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(Color(uiColor: subtitleColor))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if hasValue {
        Text(value)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(Color(uiColor: subtitleColor))
          .lineLimit(1)
          .minimumScaleFactor(0.72)
          .padding(.horizontal, 9)
          .padding(.vertical, 5)
          .background(
            Capsule(style: .continuous)
              .fill(Color(uiColor: accentColor).opacity(isDark ? 0.18 : 0.12))
          )
      }

      if showsChevron {
        Image(systemName: "chevron.right")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(Color(uiColor: subtitleColor).opacity(0.76))
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, minHeight: 70, alignment: .center)
    .background(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .fill(.ultraThinMaterial)
    )
    .padding(.horizontal, 14)
    .padding(.vertical, 4)
  }
}

private struct ChatProfileSwiftUITabSummary: Identifiable {
  let tab: ChatProfileTab
  let title: String
  let subtitle: String

  var id: String { tab.rawValue }
}

private struct ChatProfileSwiftUIContentItem: Identifiable {
  let id: String
  let title: String
  let subtitle: String
  let systemImage: String
  /// Optional profile image URL (home/member payload). Glyph fallback when nil.
  var avatarUri: String? = nil
  /// Normalized role key for grouping: owner | admin | member.
  var roleKey: String = "member"
  let payload: [String: Any]
  var kind: String = ""
  var mediaURL: String? = nil
  var mediaKey: String? = nil
  var thumbnailBase64: String? = nil
  var isVideo: Bool = false
  var duration: CGFloat? = nil
  var artist: String? = nil
  var source: String? = nil
  var coverURL: String? = nil
  var detail: String = ""
}

private enum ChatProfileSwiftUIDestination: Hashable {
  case history
  case bridgeHistory
  case bridgeSession(AgentBridgeHistorySession)
  case appearance
  case encryption
  case tab(ChatProfileTab)
  case members
  /// Push (not sheet) — same navigation pattern as New Chat / contact search.
  case addMembers
  case channelAdmins
  case channelSubscribers
  case channelSettings
  case channelRecentActions
  /// Full-page edit for group or channel (not a sheet).
  case editRoom

  var transitionID: String {
    switch self {
    case .history:
      return "chat-history"
    case .bridgeHistory:
      return "bridge-history"
    case .bridgeSession(let session):
      return "bridge-session-\(session.id)"
    case .appearance:
      return "contact-photo-poster"
    case .encryption:
      return "verify-encryption"
    case .tab(let tab):
      return "shared-\(tab.rawValue)"
    case .members:
      return "group-members"
    case .addMembers:
      return "add-group-members"
    case .channelAdmins:
      return "channel-admins"
    case .channelSubscribers:
      return "channel-subscribers"
    case .channelSettings:
      return "channel-settings"
    case .channelRecentActions:
      return "channel-recent-actions"
    case .editRoom:
      return "edit-room"
    }
  }
}

/// Interpolates a 0…1 progress so spacer height and media share one p (no clip-then-fill).
private struct ChatProfileAnimatableProgress<Content: View>: View, Animatable {
  var progress: CGFloat
  var content: (CGFloat) -> Content

  var animatableData: CGFloat {
    get { progress }
    set { progress = min(1, max(0, newValue)) }
  }

  init(progress: CGFloat, @ViewBuilder content: @escaping (CGFloat) -> Content) {
    self.progress = progress
    self.content = content
  }

  var body: some View { content(progress) }
}

private struct ChatProfileScrollOffsetPreferenceKey: PreferenceKey {
  static var defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}
private struct ChatProfileSwiftUITierBadge: View {
  let label: String

  var body: some View {
    Image(systemName: "checkmark.seal.fill")
      .font(.system(size: 16))
      .symbolRenderingMode(.palette)
      .foregroundStyle(Color.primary, Color(red: 1.0, green: 0.78, blue: 0.28))
  }
}

fileprivate class ChatProfileNavigationCoordinator: ObservableObject {
  @Published fileprivate var path: [ChatProfileSwiftUIDestination] = []
}

private struct ChatProfileSwiftUIRootView: View {
  let profileName: String
  let username: String
  let note: String
  let isChatMuted: Bool
  let isDark: Bool
  let historySubtitle: String
  let historyItems: [ChatProfileSwiftUIContentItem]
  let tabSummaries: [ChatProfileSwiftUITabSummary]
  let tabItems: [ChatProfileTab: [ChatProfileSwiftUIContentItem]]
  let appearanceSelection: ChatProfileAppearanceSelection
  let hasProfileImage: Bool
  let avatarUri: String?
  // Kept for host compatibility. Chrome no longer depends on a snapshot inset —
  // the system NavigationStack bar owns safe-area layout (which was the primary
  // cause of the header/scroll jump when this value flipped 0 → real).
  let safeAreaTop: CGFloat
  let isGroupOrChannel: Bool
  /// Channels are group-like but must not show a Members roster.
  let isChannel: Bool
  /// True for real groups (not channels) — every participant can open Members.
  var showsMemberList: Bool { isGroupOrChannel && !isChannel }
  /// Channel owner/admin get an admins/subscribers roster (not the public Members list).
  var showsChannelAdminControls: Bool { isChannel && canManageGroupMembers }
  let isGroupOwner: Bool
  let memberCount: Int?
  let groupMembersSubtitle: String
  let groupMembers: [[String: Any]]
  let canManageGroupMembers: Bool
  let groupBridgeProvider: String?
  /// All bridge agents in the group ("claude"/"codex"/"grok") — one model row each.
  var groupBridgeProviders: [String] = []
  let selectedRepositoryName: String?
  // Bridge (Claude/Codex paired-computer) state. `bridgeProvider` is empty for a
  // normal contact/group profile.
  var bridgeProvider: String = ""
  var bridgeChatId: String = ""
  var chatId: String = ""
  var bridgeConnected: Bool = false
  var bridgePaired: Bool = false
  var bridgeDeviceLabel: String = ""
  var bridgeRunningTasks: [AgentBridgeRunningTask] = []
  // Channel policy snapshot (host setters). Defaults keep group paths unchanged.
  var channelAccessType: String = "private"
  var channelPublicSlug: String = ""
  var channelShareLink: String = ""
  var channelJoinApprovalRequired: Bool = false
  var channelRestrictSavingContent: Bool = false
  var channelSubscriberCount: Int? = nil
  let onScroll: (CGFloat) -> Void
  let onNavigationActiveChanged: (Bool) -> Void
  let onCopyUsername: () -> Void
  let onAction: (String) -> Void
  let onSaveAppearance: (ChatProfileAppearanceSelection) -> Void
  let onContentPressed: ([String: Any]) -> Void
  let onMembersAdded: ([[String: Any]]) -> Void
  /// Fired when the Members destination appears so the host can re-log / hydrate
  /// the roster (empty cache is the usual reason "No members yet" shows).
  var onMembersScreenAppeared: (() -> Void)? = nil
  /// Local echoes for channel policy toggles (managers only).
  @State private var joinApprovalLocal: Bool?
  @State private var restrictSavingLocal: Bool?

  @Namespace private var morphNamespace
  @StateObject private var navCoordinator = ChatProfileNavigationCoordinator()
  @State private var localScrollOffset: CGFloat = 0
  /// A pinned shared-content tab hides the info rows; the identity stays visible.
  @State private var sharedContentFocused = false
  @State private var sharedContentFocusArmed = false
  @State private var sharedContentMeasuredHeight: CGFloat = 0
  @State private var lastReportedScrollOffset: CGFloat = -1
  @State private var newChatTrigger = false

  /// Discrete committed state: false = circle, true = full hero banner.
  /// Transitions only via spring — never half-driven by live offset.
  @State private var heroExpanded = false
  @State private var heroImageAvailable = false

  private var canExpandHero: Bool {
    hasProfileImage && heroImageAvailable
  }
  /// Soft 0…1 driven by `heroExpanded` (animates with the spring). ONE shared morph value.
  @State private var heroExpandProgress: CGFloat = 0
  /// Arms a single pull-down expand per overscroll (re-arms at rest).
  @State private var expandGestureArmed = true
  /// Ignore offset events right after a commit (prevents height/bounce re-entry).
  @State private var heroMorphInFlight = false
  /// Seeds the banner once after the remote image becomes available.
  @State private var didAutoExpandHero = false
  /// Unused after we stopped snapping scroll at commit; kept at 0 so launch offset is a no-op.
  @State private var morphCapturedPull: CGFloat = 0
  @State private var lastScrollOffsetSample: CGFloat = 0
  @State private var profileScrollProxy: ScrollViewProxy?
  private let profileScrollTopAnchorID = "profileScrollTop"
  /// Coarse gate so per-sample scroll logging doesn't spam.
  @State private var lastProfileSampleLogOffset: CGFloat = .greatestFiniteMagnitude
  /// Local echo of the selected repo name so the Repository row subtitle updates
  /// immediately when the native Menu picks a repo (without a full host re-render).
  @State private var selectedRepoNameLocal: String?
  /// Per-agent default view (chat vs agent runtime) for Claude/Codex. Seeded from the
  /// store when the section appears; the picker writes back through the store.
  @State private var bridgeDefaultView: AgentBridgeDefaultView = .chat
  /// Local echo of per-agent model picks so the row subtitle refreshes immediately
  /// ("" = explicitly cleared to Default). Source of truth stays the selection store.
  @State private var groupModelSelections: [String: String] = [:]
  /// Local echos so model/permission trailing labels refresh after menu picks.
  @State private var thinkingEnabledLocal = AgentBridgeSelectionStore.isThinkingEnabled()
  @State private var intelligenceLocal = AgentBridgeSelectionStore.selectedIntelligence()
  @State private var workModeLocal = AgentBridgeSelectionStore.selectedWorkMode()
  @State private var showAddMembersSheet = false
  @State private var showUsernameQR = false
  @State private var encryptionRowArt: UIImage?
  @State private var encryptionRowCode = ""
  @State private var inlineEditDestination: ChatProfileSwiftUIDestination?
  /// Live channel profile from `GET /api/channel/:id` (admins, settings, actions).
  @State private var channelProfileCache: ChannelProfileService.Profile?
  @State private var channelSettingsLocal = ChannelProfileService.Settings.default
  /// Share sheet for the channel's public/invite link.
  @State private var isSharingChannelLink = false

  private var rowFill: Color {
    isDark
      ? Color.white.opacity(0.06)
      : Color.white.opacity(0.70)
  }

  /// Effective model pick for an agent: the in-view echo wins ("" = cleared), else the
  /// stored selection.
  private func groupSelectedModel(_ provider: String) -> String? {
    if let local = groupModelSelections[provider] {
      return local.isEmpty ? nil : local
    }
    return AgentBridgeSelectionStore.selectedRunOptions(provider: provider).model
  }

  private func groupModelSubtitle(_ provider: String) -> String {
    guard let selected = groupSelectedModel(provider) else { return "Default model" }
    return AgentBridgeSelectionStore.modelChoices(provider: provider)
      .first(where: { $0.value == selected })?.title ?? selected
  }

  private var separatorColor: Color {
    Color(uiColor: isDark ? UIColor.white.withAlphaComponent(0.10) : UIColor.black.withAlphaComponent(0.08))
  }

  private var avatarGradientColors: (UIColor, UIColor) {
    ChatProfileAppearancePalette.colors(for: appearanceSelection, mode: .avatar)
  }

  private var posterGradientColors: (UIColor, UIColor) {
    ChatProfileAppearancePalette.colors(for: appearanceSelection, mode: .poster)
  }

  /// Chat-theme accent — same colorize-by-theme result used by profile rows.
  private var themeAccent: Color {
    Color(uiColor: ChatListAppearance.current.accent)
  }

  private var pageColor: Color {
    isDark ? Color.black : Color(uiColor: UIColor.systemGroupedBackground)
  }

  private var identityPrimary: Color {
    isDark ? Color.white : Color.black.opacity(0.92)
  }

  private var identitySecondary: Color {
    isDark ? Color.white.opacity(0.72) : Color.black.opacity(0.50)
  }

  private var posterImage: UIImage? {
    guard let data = appearanceSelection.posterImageData else { return nil }
    return UIImage(data: data)
  }

  private var showsGoldTier: Bool {
    !bridgeProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var goldTierColor: Color {
    Color(red: 0.96, green: 0.72, blue: 0.22)
  }

  private var profileInitial: String {
    let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "U" : String(trimmed.prefix(1)).uppercased()
  }

  private var avatarDisplayText: String {
    let glyph = appearanceSelection.avatarGlyph?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !glyph.isEmpty { return glyph }
    // Same initial rules as Home / chat `ChatAvatarNodeView` fallbacks.
    return ChatAvatarNodeView.fallbackText(
      from: profileName,
      isGroupOrChannel: isGroupOrChannel
    )
  }

  /// "N members" / "N subscribers" under the room name. Prefers the server
  /// count, falling back to the loaded roster. Nil for a 1:1 DM.
  private var groupHeaderSubtitle: String? {
    guard isGroupOrChannel else { return nil }
    let count: Int = {
      if isChannel, let subscriberCount = channelSubscriberCount, subscriberCount > 0 {
        return subscriberCount
      }
      if let memberCount, memberCount > 0 { return memberCount }
      return groupMembers.count
    }()
    if isChannel {
      return count == 1 ? "1 subscriber" : "\(count) subscribers"
    }
    guard count > 0 else { return nil }
    return count == 1 ? "1 member" : "\(count) members"
  }

  private var effectiveJoinApproval: Bool {
    joinApprovalLocal ?? channelJoinApprovalRequired
  }

  private var effectiveRestrictSaving: Bool {
    restrictSavingLocal ?? channelRestrictSavingContent
  }

  private var channelTypeLabel: String {
    let host = channelAccessType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let fromSettings = channelSettingsLocal.channelType
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let resolved = (host == "public" || host == "private") ? host : fromSettings
    return resolved == "public" ? "Public" : "Private"
  }

  /// Absolute, pasteable link for this channel: its public handle when public, otherwise
  /// the invite token. Built through `VibeShareLinks` so it always names the host that
  /// actually resolves the link (the server sends relative `/r/…` and `/j/…` paths).
  private var channelShareURL: String? {
    let candidates = [
      channelShareLink,
      channelSettingsLocal.inviteLink ?? "",
      channelPublicSlug.isEmpty ? "" : "/r/\(channelPublicSlug)",
    ]

    for candidate in candidates {
      let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty { continue }
      if let absolute = VibeShareLinks.absolute(trimmed) { return absolute }
    }
    return nil
  }

  private var channelLinkDisplay: String {
    VibeShareLinks.display(channelShareURL) ?? "Invite link"
  }

  /// Committed hero band ≈ 55% of screen (reads taller than half on device).
  /// Pixel-rounded so spacer + morph never settle on fractional heights.
  private var heroBaseHeight: CGFloat {
    Self.pixelRound(UIScreen.main.bounds.height * 0.55)
  }

  /// Extra top air under nav for avatar + reflection.
  private var avatarTopAir: CGFloat { 76 }

  private var avatarCircleSize: CGFloat { 104 }

  /// Spacer clears ONLY the pinned avatar (circle or hero). Name + actions live in scroll.
  private var avatarPinHeight: CGFloat {
    Self.pixelRound(avatarTopAir + avatarCircleSize + 10)
  }

  /// Spacer height stays lockstep with the media for one shared morph value.
  private var scrollHeaderSpacer: CGFloat {
    avatarPinHeight + (heroBaseHeight - avatarPinHeight) * effectiveHeroProgress
  }

  private var heroCollapseTravel: CGFloat {
    Self.pixelRound(max(1, heroBaseHeight - avatarPinHeight - identityClusterLayoutHeight))
  }

  /// Home-style live collapse: the header consumes scroll one-for-one before rows continue.
  private var liveHeroCollapseOffset: CGFloat {
    guard canExpandHero, heroExpanded, !heroMorphInFlight else { return 0 }
    return min(max(0, localScrollOffset), heroCollapseTravel)
  }

  private var postHeroCollapseScrollOffset: CGFloat {
    max(0, localScrollOffset - liveHeroCollapseOffset)
  }

  /// A photo profile opens as a banner and scrubs continuously into the compact avatar.
  private var effectiveHeroProgress: CGFloat {
    if canExpandHero, !didAutoExpandHero { return 1 }
    if canExpandHero, heroExpanded, !heroMorphInFlight {
      return 1 - liveHeroCollapseOffset / heroCollapseTravel
    }
    return heroExpandProgress
  }

  /// Fixed page reflection (outside ScrollView).
  private var pageReflectionHeight: CGFloat {
    Self.pixelRound(heroBaseHeight + 48)
  }

  /// Align morph/spacer heights to physical pixels (kills 1–2px end jump).
  private static func pixelRound(_ value: CGFloat) -> CGFloat {
    let scale = UIScreen.main.scale
    return (value * scale).rounded() / scale
  }

  /// Safe-area top for pin baseline (updated from geometry).
  @State private var safeAreaTopInset: CGFloat = 59

  /// Fixed layout height reserved in the scroll content for the identity cluster.
  private var identityClusterLayoutHeight: CGFloat {
    Self.pixelRound(28 + 3 + 15 + 10 + 62 + 6)
  }

  /// Natural top under the *collapsed* circle only — never driven by hero spacer.
  /// (Using scrollHeaderSpacer here shoved the floating cluster down during expand.)
  private var identityNaturalTopY: CGFloat {
    Self.pixelRound(avatarPinHeight)
  }

  /// Pin stop under the status bar / island — keep tight so sticky name sits
  /// near the nav, not mid-screen.
  private var identityStickyTopY: CGFloat {
    Self.pixelRound(max(0, safeAreaTopInset - 46))
  }

  private var sharedContentPinnedTopY: CGFloat {
    Self.pixelRound(identityStickyTopY + 44)
  }

  /// Scroll range the tab jump needs, parked after the last row instead of as a
  /// gap above it.
  private var sharedContentTailSpace: CGFloat {
    guard sharedContentMeasuredHeight > 0 else { return 0 }
    let needed = UIScreen.main.bounds.height - sharedContentPinnedTopY
    return max(0, needed - sharedContentMeasuredHeight - 140)
  }

  /// How far the cluster can travel before it clamps (no jump — pure clamp).
  private var identityTravelDistance: CGFloat {
    max(1, identityNaturalTopY - identityStickyTopY)
  }

  /// Scroll distance clamped to the pin travel window (scale + sticky).
  private var identityClampedScroll: CGFloat {
    min(max(0, localScrollOffset), identityTravelDistance)
  }

  /// 0 free … 1 fully pinned. Tracks pin travel so name/actions scale with scroll.
  private var identityPinProgress: CGFloat {
    let heroFade = max(0, 1 - effectiveHeroProgress / 0.15)
    return min(1, max(0, identityClampedScroll / identityTravelDistance)) * heroFade
  }

  /// Mild scale for the whole identity cluster (name + actions stay glued).
  private var identityClusterScale: CGFloat {
    1 - 0.16 * identityPinProgress
  }

  /// Sticky offset for the *in-scroll* collapsed identity: when it would pass
  /// under the nav, pin it. Zero while hero is expanded (identity lives on media).
  /// Extra y while expand springs off an overscroll, so the band does not jump to rest first.
  private func morphLaunchOffset(_ raw: CGFloat) -> CGFloat {
    guard heroMorphInFlight, heroExpanded else { return 0 }
    let p = min(1, max(0, raw))
    return morphCapturedPull * (1 - p)
  }

  /// Travel that carries the single identity cluster from under the circle up onto
  /// the hero bottom, plus the collapsed sticky pin (which only applies at p≈0).
  private var identityClusterRideOffset: CGFloat {
    identityRideOffset(effectiveHeroProgress)
  }

  private func identityRideOffset(_ raw: CGFloat) -> CGFloat {
    let p = min(1, max(0, raw))
    return -(identityClusterLayoutHeight + 16) * p
      + collapsedIdentityStickyOffset * (1 - p)
  }

  private func heroSpacer(_ raw: CGFloat) -> CGFloat {
    let p = min(1, max(0, raw))
    return avatarPinHeight + (heroBaseHeight - avatarPinHeight) * p
  }

  private var collapsedIdentityStickyOffset: CGFloat {
    guard effectiveHeroProgress < 0.5 else { return 0 }
    // Content Y of identity top ≈ media band height; screen Y = that − scroll.
    let screenY = scrollHeaderSpacer - localScrollOffset
    return max(0, identityStickyTopY - screenY)
  }

  /// Soft avatar scroll blend — continuous via identityPinProgress (no cliff).
  /// Scale + fade only; the join blur is a theme material overlay, not in the image.
  /// Dissolve window once the hero is down: the circle fades out over a short
  /// scroll rather than riding the page up.
  private var avatarDissolveProgress: CGFloat {
    guard effectiveHeroProgress < 0.02 else { return 0 }
    return min(1, max(0, postHeroCollapseScrollOffset / Self.avatarDissolveTravel))
  }

  /// Counter-offset that holds the circle in place — it drifts 10pt, not the full scroll.
  private var avatarDissolveHold: CGFloat {
    guard effectiveHeroProgress < 0.02 else { return 0 }
    let travelled = min(max(0, postHeroCollapseScrollOffset), Self.avatarDissolveTravel)
    return travelled - 10 * avatarDissolveProgress
  }

  private static let avatarDissolveTravel: CGFloat = 56

  private var scrollAvatarScale: CGFloat {
    1 - 0.34 * avatarDissolveProgress
  }
  private var scrollAvatarOpacity: CGFloat {
    1 - avatarDissolveProgress
  }

  // Slightly underdamped ("soft") springs — a touch of settle instead of a hard,
  // critically-damped stop — collapse (hero->avatar) is faster than expand.
  private static let heroExpandSpring = Animation.spring(response: 0.32, dampingFraction: 0.90)
  private static let heroCollapseSpring = Animation.spring(response: 0.12, dampingFraction: 0.95)

  var body: some View {
    NavigationStack(path: $navCoordinator.path) {
      // ONE scroll layer: media, identity and rows are all in the same ScrollView.
      ZStack(alignment: .top) {
        pageColor.ignoresSafeArea()

        // Media + rows are ONE scroll unit — the media band is the first scroll
        // element (see profileHeroScrollBand), so rows can never gap from the image
        // on pull-down or slide behind it on scroll-up.
        ScrollViewReader { scrollProxy in
          ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
              // Zero-height anchor: commit snaps the REAL scroll position here so it
              // matches the `localScrollOffset = 0` state write instead of drifting
              // (mismatch there = the list/image jump once the morph freeze lifts).
              Color.clear
                .frame(height: 0)
                .id(profileScrollTopAnchorID)

              offsetReader(heroHeight: scrollHeaderSpacer)

              ChatProfileAnimatableProgress(
                progress: canExpandHero ? effectiveHeroProgress : 0
              ) { p in
                VStack(spacing: 0) {
                  profileHeroScrollBand(progress: p)

                  profileIdentityCluster(
                    expand: p,
                    useCenter: p < 0.5
                  )
                  .frame(height: identityClusterLayoutHeight * (1 - p), alignment: .top)
                  .offset(y: identityRideOffset(p))
                  .zIndex(20)
                }
              }
              .offset(y: liveHeroCollapseOffset)
              .padding(.bottom, liveHeroCollapseOffset)
              .zIndex(20)

              VStack(spacing: 18) {
                profileInfoSection
                  .opacity(sharedContentFocused ? 0 : 1)
                if !bridgeProvider.isEmpty {
                  defaultViewSection
                }
                if !isGroupOrChannel {
                  VStack(spacing: 0) {
                    sharedContentScrollAnchor
                    sharedContentSection
                  }
                }
                if !isGroupOrChannel {
                  dangerSection
                  Color.clear
                    .frame(height: sharedContentTailSpace)
                }
              }
              .padding(.horizontal, 22)
              .padding(.top, 12)
              .padding(.bottom, 66)
            }
          }
          .coordinateSpace(name: "profile-scroll")
          .scrollIndicators(.never)
          .chatProfileBounceBehavior()
          // Stops an in-flight pan/rubber-band the instant commit fires — otherwise
          // the finger (or bounce-back physics) keeps moving the REAL offset for the
          // whole 0.28s spring while we've frozen the state var at 0, and it all
          // catches up in one jump when the freeze lifts (the "noisy soft jump").
          .onAppear { profileScrollProxy = scrollProxy }
          .onChange(of: localScrollOffset) { _, offset in
            guard sharedContentFocused, sharedContentFocusArmed,
              offset < identityTravelDistance
            else { return }
            withAnimation(.easeOut(duration: 0.18)) { sharedContentFocused = false }
          }
        }
        .ignoresSafeArea(edges: .top)
        .background(Color.clear)
        .zIndex(2)

      }
      .overlay {
        if let inlineEditDestination {
          destinationView(for: inlineEditDestination)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(pageColor.ignoresSafeArea())
            .transition(.opacity)
        }
      }
      .background {
        GeometryReader { geo in
          Color.clear
            .onAppear { safeAreaTopInset = geo.safeAreaInsets.top }
            .onChange(of: geo.safeAreaInsets.top) { _, next in
              safeAreaTopInset = next
            }
        }
      }
      .navigationBarTitleDisplayMode(.inline)
      .navigationBarBackButtonHidden(true)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          if (inlineEditDestination == nil || !navCoordinator.path.isEmpty),
            navCoordinator.path.last != .editRoom,
            navCoordinator.path.last != .channelSettings
          {
            Button {
              if navCoordinator.path.isEmpty {
                NSLog("[ProfileNavigation] close-root chatId=%@", bridgeChatId)
                onAction("headerBack")
              } else {
                NSLog("[ProfileNavigation] pop-inner depth=%d", navCoordinator.path.count)
                navCoordinator.path.removeLast()
              }
            } label: {
              Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
            }
          }
        }
        // Group/channel: Edit only (no ⋯ menu). DM/default: no trailing chrome.
        ToolbarItem(placement: .topBarTrailing) {
          if navCoordinator.path.isEmpty, inlineEditDestination == nil,
            isGroupOrChannel, canManageGroupMembers
          {
            Button("Edit") {
              withAnimation(.easeOut(duration: 0.16)) {
                inlineEditDestination = isChannel ? .channelSettings : .editRoom
              }
            }
            .font(.system(size: 17, weight: .semibold))
          }
        }
      }
      // Match Home: hide the bar background — no solid color / blue chrome args.
      .toolbarBackground(.hidden, for: .navigationBar)
      // Must live ON the stack root content so path / link pushes resolve.
      // Channel / members / bridge-session destinations use a normal Settings-style
      // push. Zoom transitions read as a morph/"pop" and also SIGBUS'd on members.
      .navigationDestination(for: ChatProfileSwiftUIDestination.self) { destination in
        switch destination {
        case .encryption,
          .members,
          .bridgeSession,
          .channelAdmins,
          .channelSubscribers,
          .channelSettings,
          .channelRecentActions,
          .editRoom:
          destinationView(for: destination)
            .toolbarBackground(.hidden, for: .navigationBar)
        default:
          destinationView(for: destination)
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationTransition(.zoom(sourceID: destination.transitionID, in: morphNamespace))
        }
      }
    }
    .background(pageColor)
    .onAppear {
      if selectedRepoNameLocal == nil {
        selectedRepoNameLocal = selectedRepositoryName
      }
      autoExpandHeroIfPhoto()
      loadEncryptionRowArt()
    }
    .onChange(of: canExpandHero) { _, _ in autoExpandHeroIfPhoto() }
    .onChange(of: selectedRepositoryName) { _, next in
      selectedRepoNameLocal = next
    }
    .onChange(of: navCoordinator.path.isEmpty) { _, isEmpty in
      onNavigationActiveChanged(!isEmpty || inlineEditDestination != nil)
    }
    .onChange(of: inlineEditDestination) { _, destination in
      onNavigationActiveChanged(destination != nil || !navCoordinator.path.isEmpty)
    }
    .task(id: isChannel ? bridgeChatId : "") {
      guard isChannel, !bridgeChatId.isEmpty else { return }
      await loadChannelProfile()
    }
    .sheet(isPresented: $showAddMembersSheet) {
      addMembersSheetContent
    }
    .sheet(isPresented: $showUsernameQR) {
      usernameQRSheet
    }
  }

  @MainActor
  private func loadChannelProfile() async {
    guard let config = AppSessionConfig.current else { return }
    do {
      let profile = try await ChannelProfileService.fetchProfile(
        chatId: bridgeChatId, config: config)
      channelProfileCache = profile
      channelSettingsLocal = profile.settings
      joinApprovalLocal = profile.settings.joinApprovalRequired
      restrictSavingLocal = profile.settings.restrictSavingContent
      // Hydrate host roster when channel GET returned members but local list is empty
      // (avoids empty Administrators/Subscribers right after open).
      if groupMembers.isEmpty {
        let source = profile.members.isEmpty
          ? (profile.administrators + profile.subscribers)
          : profile.members
        if !source.isEmpty {
          let mapped: [[String: Any]] = source.map { member in
            var entry: [String: Any] = [
              "userId": member.userId,
              "name": member.name,
              "role": {
                let r = member.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if r == "agent admin" { return "agent_admin" }
                return r.isEmpty ? "member" : r
              }(),
            ]
            if let username = member.username { entry["username"] = username }
            if let avatar = member.avatarUrl { entry["avatarUrl"] = avatar }
            return entry
          }
          onMembersAdded(mapped)
        }
      }
      // Seed description into the note field via host when empty.
      if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        let desc = profile.description,
        !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        // Host owns profileBio; surface via action so UIKit setProfileBio can run.
        onAction("channelDescription:\(desc)")
      }
    } catch {
      NSLog("[ChannelProfile] load failed chatId=%@ error=%@", bridgeChatId, error.localizedDescription)
    }
  }

  @ViewBuilder
  private var addMembersSheetContent: some View {
    if let config = AppSessionConfig.current {
      AddGroupMembersSheet(
        config: config,
        chatId: bridgeChatId,
        excludedUserIds: Set(
          groupMembers.compactMap { entry -> String? in
            (entry["userId"] as? String)
              ?? (entry["id"] as? String)
              ?? (entry["memberId"] as? String)
              ?? (entry["user_id"] as? String)
          }
        ),
        homeRows: ChatHomeService.cachedRows(config: config),
        onAdded: { raw in
          onMembersAdded(raw)
          showAddMembersSheet = false
        }
      )
      .presentationDetents([.medium, .large])
      .presentationDragIndicator(.visible)
      .presentationBackground(.clear)
    } else {
      Text("Not signed in")
        .presentationDetents([.medium])
        .presentationBackground(.clear)
    }
  }

  /// Photo profiles land already banner-sized — no spring on open, and the fallback
  /// glyph never gets one.
  private func autoExpandHeroIfPhoto() {
    guard canExpandHero, !didAutoExpandHero else { return }
    didAutoExpandHero = true
    var t = Transaction()
    t.disablesAnimations = true
    withTransaction(t) {
      heroExpanded = true
      heroExpandProgress = 1
      localScrollOffset = 0
      lastScrollOffsetSample = 0
      expandGestureArmed = false
      morphCapturedPull = 0
    }
  }

  /// Commit circle ↔ hero. Freezes the offset, then animates ONE progress for spacer+media.
  /// Fallback-only avatars stay a fixed circle so they match Home/chat tiles.
  private func setHeroExpanded(_ expanded: Bool) {
    guard canExpandHero else { return }
    if expanded {
      guard !heroExpanded, !heroMorphInFlight else { return }
    } else if !heroExpanded, !heroMorphInFlight {
      return
    }
    NSLog(
      "[ProfileHeroMorph] commit expanded=%d fromP=%.3f localOffset=%.1f",
      expanded ? 1 : 0, Double(heroExpandProgress), Double(localScrollOffset)
    )
    // Do not scrollTo or disable the pan — both snap content to rest, then the
    // spring runs, and the cancelled gesture needs a new finger ("re-pinch").
    morphCapturedPull = expanded ? min(0, localScrollOffset) : 0
    expandGestureArmed = !expanded
    heroExpanded = expanded
    let target: CGFloat = expanded ? 1 : 0
    if expanded {
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      heroMorphInFlight = true
      withAnimation(Self.heroExpandSpring, completionCriteria: .logicallyComplete) {
        heroExpandProgress = 1
      } completion: { [self] in
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { heroExpandProgress = 1 }
        expandGestureArmed = false
        morphCapturedPull = 0
        heroMorphInFlight = false
        NSLog(
          "[ProfileHeroMorph] settle expanded=1 p=%.3f localOffset=%.1f",
          Double(heroExpandProgress), Double(localScrollOffset)
        )
      }
    } else {
      UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.7)
      heroMorphInFlight = true
      withAnimation(Self.heroCollapseSpring, completionCriteria: .logicallyComplete) {
        heroExpandProgress = 0
      } completion: { [self] in
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { heroExpandProgress = 0 }
        expandGestureArmed = true
        morphCapturedPull = 0
        heroMorphInFlight = false
        NSLog(
          "[ProfileHeroMorph] settle expanded=0 p=%.3f localOffset=%.1f",
          Double(heroExpandProgress), Double(localScrollOffset)
        )
      }
    }
  }

  /// Media band INSIDE the scroll content — one scroll unit with identity + rows.
  /// Expanded: name/actions sit on the hero bottom (still in this band, not a
  /// separate floating layer). Collapsed: media only; identity is the next
  /// sibling in the VStack. Morph/hero stretch unchanged.
  private func profileHeroScrollBand(progress p: CGFloat) -> some View {
    let spacer = heroSpacer(p)
    return GeometryReader { g in
      let minY = g.frame(in: .named("profile-scroll")).minY
      // Pin to the screen top and grow by the LIVE overscroll, scaled by p. A frozen
      // capture decouples the instant the finger keeps pulling — that was the top gap.
      let pull = canExpandHero ? max(0, Self.pixelRound(minY)) * p : 0
      let away = canExpandHero ? max(0, -minY) * p : 0
      let stretch = pull
      ChatProfileAvatarMorphView(
        text: avatarDisplayText,
        fontStyleID: appearanceSelection.avatarFontStyleID,
        imageUri: hasProfileImage ? avatarUri : nil,
        fallbackColors: avatarGradientColors,
        morphEnabled: canExpandHero,
        width: g.size.width,
        collapsedHeight: avatarPinHeight,
        heroBaseHeight: heroBaseHeight,
        expand: p,
        overscrollStretch: stretch,
        topAir: avatarTopAir,
        scrollScale: scrollAvatarScale,
        scrollOpacity: scrollAvatarOpacity,
        parallax: canExpandHero ? Self.pixelRound(away * 0.5) : 0,
        edgeFadeColor: pageColor,
        onImageAvailabilityChanged: { available in
          guard heroImageAvailable != available else { return }
          heroImageAvailable = available
          if !available {
            heroExpanded = false
            heroExpandProgress = 0
            didAutoExpandHero = false
          }
        }
      )
      .blur(radius: 9 * avatarDissolveProgress)
      .frame(
        width: g.size.width,
        height: spacer + stretch,
        alignment: .top
      )
      .overlay(alignment: .bottom) {
        if canExpandHero, p > 0.01 {
          heroJoinFade(width: g.size.width, height: 18)
            .opacity(Double(p))
        }
      }
      .offset(y: -pull + avatarDissolveHold)
      .frame(width: g.size.width, height: spacer + stretch, alignment: .top)
      .contentShape(Rectangle())
      .onTapGesture(count: 2) {
        guard canExpandHero else { return }
        if abs(localScrollOffset) < 40, !heroMorphInFlight {
          setHeroExpanded(!heroExpanded)
        }
      }
    }
    .frame(height: spacer)
  }

  /// Pure blur band at the bottom edge — no gradient color overlay.
  @ViewBuilder
  private func heroJoinFade(width: CGFloat, height: CGFloat) -> some View {
    EmptyView()
  }





  private func offsetReader(heroHeight: CGFloat) -> some View {
    GeometryReader { proxy in
      Color.clear
        .preference(
          key: ChatProfileScrollOffsetPreferenceKey.self,
          value: -proxy.frame(in: .named("profile-scroll")).minY
        )
    }
    .frame(height: 0)
    .onPreferenceChange(ChatProfileScrollOffsetPreferenceKey.self) { value in
      let scale = UIScreen.main.scale
      let nextValue = (value * scale).rounded() / scale
      guard abs(localScrollOffset - nextValue) >= 0.25 else { return }
      let previous = lastScrollOffsetSample
      lastScrollOffsetSample = nextValue
      var t = Transaction()
      t.disablesAnimations = true
      withTransaction(t) {
        localScrollOffset = nextValue
      }

      if abs(nextValue - lastProfileSampleLogOffset) > 8 {
        lastProfileSampleLogOffset = nextValue
        NSLog(
          "[ProfileHeroMorph] sample offset=%.1f p=%.3f spacer=%.1f expanded=%d inFlight=%d armed=%d",
          Double(nextValue), Double(heroExpandProgress), Double(scrollHeaderSpacer),
          heroExpanded ? 1 : 0, heroMorphInFlight ? 1 : 0, expandGestureArmed ? 1 : 0
        )
      }

      if canExpandHero {
        if heroExpanded || heroMorphInFlight && heroExpandProgress > 0.15 {
          if nextValue > 12 {
            NSLog("[ProfileHeroMorph] compact-threshold offset=%.1f", Double(nextValue))
            setHeroExpanded(false)
          }
        } else if !heroMorphInFlight {
          if nextValue > -24 {
            expandGestureArmed = true
          }
          if expandGestureArmed, nextValue < -60 {
            expandGestureArmed = false
            NSLog("[ProfileHeroMorph] pull-threshold offset=%.1f", Double(nextValue))
            setHeroExpanded(true)
          } else if nextValue < -60 {
            NSLog("[ProfileHeroMorph] pull-ignored unarmed offset=%.1f", Double(nextValue))
          }
        }
      }

      _ = previous
      if lastReportedScrollOffset < 0 || abs(lastReportedScrollOffset - nextValue) >= 6.0 {
        lastReportedScrollOffset = nextValue
        onScroll(nextValue)
      }
    }
  }


  /// Name + actions body. Used in-scroll: under the circle when collapsed, on
  /// the hero when expanded. Not a separate overlay layer outside the ScrollView.
  @ViewBuilder
  private func profileIdentityCluster(expand: CGFloat, useCenter _: Bool) -> some View {
    let p = min(1, max(0, expand))
    let inset: CGFloat = 16
    let contentWidth = max(1, UIScreen.main.bounds.width - inset * 2)
    let handleText: String? = {
      if let groupHeaderSubtitle { return groupHeaderSubtitle }
      let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }()
    let titleFont = UIFont.systemFont(ofSize: 28, weight: .medium)
    let subtitleFont = UIFont.systemFont(ofSize: 13, weight: .light)
    let titleWidth = min(
      contentWidth,
      (profileName as NSString).size(withAttributes: [.font: titleFont]).width
        + (showsGoldTier ? 24 : 0)
    )
    let subtitleWidth = handleText.map {
      min(contentWidth, ($0 as NSString).size(withAttributes: [.font: subtitleFont]).width)
    } ?? 0
    let titleCenterOffset = max(0, (contentWidth - titleWidth) * 0.5)
    let subtitleCenterOffset = max(0, (contentWidth - subtitleWidth) * 0.5)
    // Match Home: height clips 1:1 while only inner content fades over the final 30%.
    let actionCollapseY = collapsedIdentityStickyOffset
    let actionRowBand: CGFloat = 62
    let actionBarHeight = max(0, actionRowBand - min(actionCollapseY, actionRowBand))
    let actionContentRatio = actionRowBand > 0 ? actionBarHeight / actionRowBand : 0
    let actionVisibility = max(0, min(1, (actionContentRatio - 0.7) / 0.3))

    VStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 8) {
          Text(profileName)
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(identityPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .multilineTextAlignment(.leading)
          if showsGoldTier {
            ChatProfileSwiftUITierBadge(label: "Gold")
          }
        }
        .offset(x: titleCenterOffset * (1 - p))

        Text(handleText ?? "")
          .font(.system(size: 13, weight: .light))
          .foregroundStyle(identitySecondary)
          .lineLimit(1)
          .multilineTextAlignment(.leading)
          .frame(height: 15, alignment: .leading)
          .opacity(handleText == nil ? 0 : 1)
          .offset(x: subtitleCenterOffset * (1 - p))
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .scaleEffect(identityClusterScale, anchor: .top)
      .padding(.horizontal, inset)

      // Bottom recedes as height shrinks — same clip Home uses on its bar.
      actionRow(contentAlpha: actionVisibility, chipHeight: actionBarHeight)
        .frame(height: actionBarHeight, alignment: .top)
        .clipped()
        .allowsHitTesting(actionBarHeight > actionRowBand * 0.5)
    }
    .frame(maxWidth: .infinity, alignment: .top)
  }

  /// Section title outside the card (topic header).
  @ViewBuilder
  private func profileSectionHeader(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(Color.secondary)
      .textCase(.uppercase)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 6)
      .padding(.bottom, 2)
  }

  private var resolvedRepositorySubtitle: String {
    let local = selectedRepoNameLocal?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !local.isEmpty { return local }
    let passed = selectedRepositoryName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !passed.isEmpty { return passed }
    return "Pick repo for Claude/Codex"
  }

  private var availableRepositories: [AgentBridgeRepository] {
    AgentPairingService.lastStatusSnapshot?.repositories ?? []
  }

  private func selectRepository(_ repo: AgentBridgeRepository) {
    AgentBridgeSelectionStore.select(repo, chatId: bridgeChatId.isEmpty ? nil : bridgeChatId)
    selectedRepoNameLocal = repo.name
  }

  /// ONE always-mounted pill row — identical geometry collapsed or expanded, so the
  /// morph never reshapes it and there is never a second copy.
  @ViewBuilder
  private func actionRow(contentAlpha: CGFloat, chipHeight: CGFloat) -> some View {
    let chipInk = isDark ? Color.white.opacity(0.84) : Color.black.opacity(0.76)
    // Same left/right edge as the section cards below (body pads 22 a side).
    let rowWidth = UIScreen.main.bounds.width - 44
    let count: CGFloat = isGroupOrChannel ? 3 : 4
    let spacing: CGFloat = 8
    let hPad: CGFloat = 0
    let chipH = max(0, chipHeight)
    let chipW = (rowWidth - 2 * hPad - (count - 1) * spacing) / count

    HStack(spacing: spacing) {
      if isGroupOrChannel {
        ChatProfileSwiftUIActionButton(
          title: isChatMuted ? "unmute" : "mute",
          systemImage: isChatMuted ? "bell" : "bell.slash",
          fill: .clear,
          ink: chipInk,
          isDark: isDark,
          chipWidth: chipW,
          chipHeight: chipH,
          contentAlpha: contentAlpha
        ) { onAction("muteToggle") }

        ChatProfileSwiftUIActionButton(
          title: "search",
          systemImage: "magnifyingglass",
          fill: .clear,
          ink: chipInk,
          isDark: isDark,
          chipWidth: chipW,
          chipHeight: chipH,
          contentAlpha: contentAlpha
        ) { onAction("search") }

        Menu {
          Button("Report", systemImage: "exclamationmark.circle") {
            onAction("reportRoom")
          }
          Button("Clear Messages", systemImage: "bubble.left.and.exclamationmark.bubble.right") {
            onAction("clearChat")
          }
          Divider()
          if isGroupOwner {
            Button(
              isChannel ? "Delete Channel" : "Delete Group",
              systemImage: "trash",
              role: .destructive
            ) { onAction("deleteGroup") }
          } else {
            Button(
              isChannel ? "Leave Channel" : "Leave Group",
              systemImage: "rectangle.portrait.and.arrow.right",
              role: .destructive
            ) { onAction("leaveGroup") }
          }
        } label: {
          VStack(spacing: 1) {
            Image(systemName: "ellipsis")
              .font(.system(size: 18, weight: .semibold))
            Text("more")
              .font(.system(size: 10, weight: .medium))
          }
          .foregroundStyle(chipInk)
          .opacity(Double(contentAlpha))
          .frame(width: chipW, height: chipH)
          .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .fill(.ultraThinMaterial)
              .environment(\.colorScheme, isDark ? .dark : .light)
          }
          .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
              .stroke(Color.primary.opacity(0.08), lineWidth: 0.6)
          }
        }
        .buttonStyle(.plain)
      } else {
        ChatProfileSwiftUIActionButton(
          title: "call",
          systemImage: "phone",
          fill: .clear,
          ink: chipInk,
          isDark: isDark,
          chipWidth: chipW,
          chipHeight: chipH,
          contentAlpha: contentAlpha
        ) { onAction("audio") }

        ChatProfileSwiftUIActionButton(
          title: "video",
          systemImage: "video",
          fill: .clear,
          ink: chipInk,
          isDark: isDark,
          chipWidth: chipW,
          chipHeight: chipH,
          contentAlpha: contentAlpha
        ) { onAction("video") }

        ChatProfileSwiftUIActionButton(
          title: "search",
          systemImage: "magnifyingglass",
          fill: .clear,
          ink: chipInk,
          isDark: isDark,
          chipWidth: chipW,
          chipHeight: chipH,
          contentAlpha: contentAlpha
        ) { onAction("search") }

        ChatProfileSwiftUIActionButton(
          title: isChatMuted ? "unmute" : "mute",
          systemImage: isChatMuted ? "bell" : "bell.slash",
          fill: .clear,
          ink: chipInk,
          isDark: isDark,
          chipWidth: chipW,
          chipHeight: chipH,
          contentAlpha: contentAlpha
        ) { onAction("muteToggle") }
      }
    }
    .padding(.horizontal, hPad)
    .frame(width: rowWidth, height: chipH)
  }

  /// Last row of the identity card: the key itself plus its seeded art, no lock glyph.
  private var encryptionKeyRow: some View {
    Button { navCoordinator.path.append(.encryption) } label: {
      HStack(spacing: 10) {
        Text("Encryption key")
          .font(.system(size: 17, weight: .regular))
          .foregroundStyle(.primary)
        Spacer(minLength: 12)
        if let encryptionRowArt {
          Image(uiImage: encryptionRowArt)
            .resizable()
            .interpolation(.none)
            .frame(width: 26, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
          Color.clear
            .frame(width: 26, height: 26)
        }
        Image(systemName: "chevron.right")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.tertiary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.leading, 22)
      .padding(.trailing, 18)
      .padding(.vertical, 11)
      .contentShape(Rectangle())
    }
    .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
  }



  /// Art render is a CIFilter plus a gradient pass — done once, never in a body getter.
  private func loadEncryptionRowArt() {
    guard encryptionRowArt == nil, bridgeProvider.isEmpty, !isGroupOrChannel else { return }
    guard let peer = ChatEngine.shared.peerUserId(chatId: chatId), !peer.isEmpty else { return }
    VibeSecureSessions.shared.ensurePeerPinned(chatId: chatId, peerUserId: peer)
    guard let identity = ChatEncryptionVerifyView.rowIdentity(peerUserId: peer) else { return }
    encryptionRowCode = identity.code
    encryptionRowArt = identity.art
  }

  @ViewBuilder
  private var profileInfoSection: some View {
    if !bridgeProvider.isEmpty {
      // For a Claude/Codex agent there is no username to copy — the identity row
      // becomes the paired computer (label + live connection dot). Tapping it
      // opens the connect / disconnect / reconnect sheet.
      ChatProfileSwiftUISection(fill: rowFill) {
        Button {
          onAction("bridgeConnection")
        } label: {
          bridgeComputerRow(isLast: note.isEmpty)
        }
        .buttonStyle(ChatProfileSwiftUIRowButtonStyle())

        if !note.isEmpty {
          ChatProfileSwiftUIRow(
            title: "note",
            subtitle: note,
            trailingSystemImage: nil,
            showsChevron: false,
            separatorColor: separatorColor,
            isLast: true
          )
        }
      }
    } else if isGroupOrChannel {
      // Channels: channel settings + admin control only.
      // Groups: identity + optional bridge agent models/permissions.
      groupTopicSection
      if !isChannel, groupBridgeProvider != nil {
        groupModelsSection
        groupPermissionsSection
        groupConfigurationSection
      }
    } else {
      // One room: identity, the contact actions and the encryption key share a card.
      ChatProfileSwiftUISection(fill: rowFill) {
        if !username.isEmpty {
          HStack(spacing: 0) {
            Button {
              onCopyUsername()
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text("username")
                  .font(.system(size: 15, weight: .regular))
                  .foregroundStyle(.primary)
                Text(username)
                  .font(.system(size: 17, weight: .regular))
                  .foregroundStyle(themeAccent)
                  .lineLimit(1)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.leading, 22)
              .padding(.vertical, 13)
              .contentShape(Rectangle())
            }
            .buttonStyle(ChatProfileSwiftUIRowButtonStyle())

            Button {
              showUsernameQR = true
            } label: {
              Image(systemName: "qrcode")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(themeAccent)
                .frame(width: 58, height: 58)
                .contentShape(Rectangle())
            }
            .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
            .accessibilityLabel("Show username QR code")
          }
          .overlay(alignment: .bottom) {
            Rectangle()
              .fill(separatorColor)
              .frame(height: 1 / UIScreen.main.scale)
              .padding(.leading, 22)
          }
        }

        if !note.isEmpty {
          ChatProfileSwiftUIRow(
            title: "note",
            subtitle: note,
            trailingSystemImage: nil,
            showsChevron: false,
            separatorColor: separatorColor,
            isLast: false
          )
        }

        Button { onAction("addContact") } label: {
          ChatProfileSwiftUIRow(
            title: "Add to Contacts",
            titleColor: themeAccent,
            separatorColor: separatorColor,
            isLast: false
          )
        }
        .buttonStyle(ChatProfileSwiftUIRowButtonStyle())

        Button(role: .destructive) { onAction("block") } label: {
          ChatProfileSwiftUIRow(
            title: "Block User",
            titleColor: .red,
            separatorColor: separatorColor,
            isLast: false
          )
        }
        .buttonStyle(ChatProfileSwiftUIRowButtonStyle())

        encryptionKeyRow
      }
    }
  }

  /// Group: Edit + Members. Channel: description, admins, subscribers, settings.
  @ViewBuilder
  private var groupTopicSection: some View {
    if isChannel {
      channelProfileSections
    } else if showsMemberList {
      let memberItems = swiftUIMemberItems()
      let previewItems = Array(memberItems.prefix(5))
      let palette = AppThemePalette.resolve(for: isDark ? .dark : .light)

      ChatProfileSwiftUISection(fill: rowFill) {
        if canManageGroupMembers {
          Button {
            showAddMembersSheet = true
          } label: {
            HStack(spacing: 12) {
              Image(systemName: "person.badge.plus")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(themeAccent)
                .frame(width: 42, height: 42)
              Text("Add Members")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(themeAccent)
              Spacer(minLength: 8)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 5)
            .overlay(alignment: .bottom) {
              Rectangle()
                .fill(separatorColor)
                .frame(height: 1 / UIScreen.main.scale)
                .padding(.leading, 70)
            }
          }
          .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
        }

        ForEach(Array(previewItems.enumerated()), id: \.element.id) { index, item in
          Button {
            onContentPressed(item.payload)
          } label: {
            ChatProfileMemberHomeStyleRow(item: item, palette: palette)
              .padding(.horizontal, 16)
              .overlay(alignment: .bottom) {
                if index < previewItems.count - 1 || memberItems.count > previewItems.count {
                  Rectangle()
                    .fill(separatorColor)
                    .frame(height: 1 / UIScreen.main.scale)
                    .padding(.leading, 70)
                }
              }
          }
          .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
        }

        if memberItems.count > previewItems.count || memberItems.isEmpty {
          Button {
            onMembersScreenAppeared?()
            navCoordinator.path.append(.members)
          } label: {
            ChatProfileSwiftUIRow(
              title: memberItems.isEmpty ? "Members" : "View All Members",
              trailingText: memberItems.isEmpty ? groupMembersSubtitle : "\(memberItems.count)",
              showsChevron: true,
              titleColor: themeAccent,
              separatorColor: separatorColor,
              isLast: true
            )
          }
          .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
        }
      }
    }
  }

  /// Compact channel main profile — Telegram-style icon rows that push detail pages.
  @ViewBuilder
  private var channelProfileSections: some View {
    let admins = channelAdministrators
    let humanAdmins = admins.filter { !Self.isAgentAdminRole($0.role) }
    let agentAdmins = admins.filter { Self.isAgentAdminRole($0.role) }
    let subs = channelSubscribers
    let adminCount = max(humanAdmins.count + agentAdmins.count, admins.count)
    let subTotal: Int = {
      if let channelSubscriberCount, channelSubscriberCount > 0 { return channelSubscriberCount }
      if let memberCount, memberCount > 0 { return memberCount }
      let roster = subs.count + admins.count
      return roster > 0 ? roster : groupMembers.count
    }()

    VStack(alignment: .leading, spacing: 14) {
      // People card
      ChatProfileSwiftUISection(fill: rowFill) {
        Button {
          onMembersScreenAppeared?()
          navCoordinator.path.append(.channelAdmins)
        } label: {
          ChatProfileSwiftUIRow(
            title: "Administrators",
            trailingText: adminCount > 0 ? "\(adminCount)" : nil,
            leading: channelRowLeadingIcon(
              "checkmark.shield.fill",
              tint: Color(red: 0.30, green: 0.78, blue: 0.42)
            ),
            showsChevron: true,
            separatorColor: separatorColor,
            isLast: false
          )
        }
        .buttonStyle(ChatProfileSwiftUIRowButtonStyle())

        Button {
          onMembersScreenAppeared?()
          navCoordinator.path.append(.channelSubscribers)
        } label: {
          ChatProfileSwiftUIRow(
            title: "Subscribers",
            trailingText: subTotal > 0 ? "\(subTotal)" : nil,
            leading: channelRowLeadingIcon(
              "person.3.fill",
              tint: Color(red: 0.25, green: 0.55, blue: 0.95)
            ),
            showsChevron: true,
            separatorColor: separatorColor,
            isLast: false
          )
        }
        .buttonStyle(ChatProfileSwiftUIRowButtonStyle())

        // The channel's one shareable link. It existed in the payload but had no UI, so
        // there was no way to get a channel's link out of the app at all.
        if let channelLink = channelShareURL {
          Button {
            isSharingChannelLink = true
          } label: {
            ChatProfileSwiftUIRow(
              title: "Link",
              trailingText: VibeShareLinks.display(channelLink),
              leading: channelRowLeadingIcon(
                "link",
                tint: Color(red: 0.20, green: 0.60, blue: 0.85)
              ),
              showsChevron: true,
              separatorColor: separatorColor,
              isLast: false
            )
          }
          .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
          .sheet(isPresented: $isSharingChannelLink) {
            AppShareSheet(items: [channelLink])
          }
        }

        Button {
          withAnimation(.easeOut(duration: 0.16)) {
            inlineEditDestination = .channelSettings
          }
        } label: {
          ChatProfileSwiftUIRow(
            title: "Channel settings",
            trailingText: channelTypeLabel,
            leading: channelRowLeadingIcon(
              "gearshape.fill",
              tint: Color(red: 0.45, green: 0.48, blue: 0.55)
            ),
            showsChevron: true,
            separatorColor: separatorColor,
            isLast: true
          )
        }
        .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
      }
    }
  }

  private func channelRowLeadingIcon(_ systemName: String, tint: Color) -> AnyView {
    AnyView(
      Image(systemName: systemName)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 30, height: 30)
        .background(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(tint)
        )
    )
  }

  private func channelAdminPeopleSubtitle(humanCount: Int, agentCount: Int) -> String {
    var parts: [String] = []
    if humanCount > 0 {
      parts.append("\(humanCount) admin\(humanCount == 1 ? "" : "s")")
    }
    if agentCount > 0 {
      parts.append("\(agentCount) agent admin\(agentCount == 1 ? "" : "s")")
    }
    if parts.isEmpty { return "No administrators" }
    return parts.joined(separator: " · ")
  }

  private func channelSubscriberCountLabel(
    subscribers: [ChannelProfileService.Member],
    admins: [ChannelProfileService.Member]
  ) -> String {
    let total: Int = {
      if let channelSubscriberCount, channelSubscriberCount > 0 { return channelSubscriberCount }
      if let memberCount, memberCount > 0 { return memberCount }
      let roster = subscribers.count + admins.count
      if roster > 0 { return roster }
      if let profile = channelProfileCache, profile.memberCount > 0 {
        return profile.memberCount
      }
      return groupMembers.count
    }()
    if total == 1 { return "1 subscriber" }
    if total > 0 { return "\(total) subscribers" }
    return "No subscribers yet"
  }

  private static func isAgentAdminRole(_ role: String) -> Bool {
    let r = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return r == "agent_admin" || r == "agent admin"
  }

  private static func isHumanAdminRole(_ role: String) -> Bool {
    let r = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return r == "owner" || r == "admin"
  }

  private static func isAdminLikeRole(_ role: String) -> Bool {
    isHumanAdminRole(role) || isAgentAdminRole(role)
  }

  private static func displayRoleLabel(_ role: String) -> String {
    let r = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch r {
    case "owner": return "Owner"
    case "admin": return "Admin"
    case "agent_admin", "agent admin": return "Agent admin"
    case "subscriber", "member", "": return "Subscriber"
    default: return role.capitalized
    }
  }

  /// Full channel roster: API profile members + host `groupMembers` (union by userId).
  private var channelRosterMembers: [ChannelProfileService.Member] {
    var byId: [String: ChannelProfileService.Member] = [:]

    if let profile = channelProfileCache {
      for member in profile.members {
        byId[member.userId.uppercased()] = Self.normalizedChannelMember(member)
      }
      // Some payloads only send split lists.
      for member in profile.administrators + profile.subscribers {
        let key = member.userId.uppercased()
        if byId[key] == nil {
          byId[key] = Self.normalizedChannelMember(member)
        }
      }
    }

    for entry in groupMembers {
      guard let member = Self.channelMember(from: entry) else { continue }
      let key = member.userId.uppercased()
      // Prefer richer API name when present; always keep role from roster if API was empty.
      if let existing = byId[key] {
        let existingRole = existing.role.lowercased()
        let nextRole = member.role.lowercased()
        // Upgrade generic "member/subscriber" when roster has a stronger role.
        if (existingRole == "member" || existingRole == "subscriber"),
          Self.isAdminLikeRole(nextRole)
        {
          byId[key] = member
        }
      } else {
        byId[key] = member
      }
    }

    return Array(byId.values).sorted { lhs, rhs in
      let lr = Self.adminSortRank(lhs.role)
      let rr = Self.adminSortRank(rhs.role)
      if lr != rr { return lr < rr }
      return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
  }

  private static func adminSortRank(_ role: String) -> Int {
    let r = role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    switch r {
    case "owner": return 0
    case "admin": return 1
    case "agent_admin", "agent admin": return 2
    default: return 3
    }
  }

  private static func normalizedChannelMember(
    _ member: ChannelProfileService.Member
  ) -> ChannelProfileService.Member {
    ChannelProfileService.Member(
      userId: member.userId,
      name: member.name,
      username: member.username,
      avatarUrl: member.avatarUrl,
      role: displayRoleLabel(member.role)
    )
  }

  private static func channelMember(from entry: [String: Any]) -> ChannelProfileService.Member? {
    let userId =
      (entry["userId"] as? String)
      ?? (entry["user_id"] as? String)
      ?? (entry["id"] as? String)
      ?? (entry["memberId"] as? String)
    guard let userId, !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }
    let rawName =
      (entry["name"] as? String)
      ?? (entry["displayName"] as? String)
      ?? (entry["username"] as? String)
    let trimmedName = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let name = trimmedName.isEmpty ? userId : trimmedName
    let rawRole =
      ((entry["role"] as? String)
        ?? (entry["memberRole"] as? String)
        ?? (entry["member_role"] as? String)
        ?? "member")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let avatar =
      (entry["avatarUrl"] as? String)
      ?? (entry["avatar_url"] as? String)
      ?? (entry["avatarUri"] as? String)
      ?? (entry["profileImage"] as? String)
    return ChannelProfileService.Member(
      userId: userId,
      name: name,
      username: entry["username"] as? String,
      avatarUrl: avatar,
      role: displayRoleLabel(rawRole)
    )
  }

  private var channelAdministrators: [ChannelProfileService.Member] {
    channelRosterMembers.filter { Self.isAdminLikeRole($0.role) }
  }

  private var channelSubscribers: [ChannelProfileService.Member] {
    // Non-admin participants. If the only people we know are admins, still surface
    // them here so the list is never empty when the channel has known members
    // (owner should always appear somewhere the user can open).
    let nonAdmins = channelRosterMembers.filter { !Self.isAdminLikeRole($0.role) }
    if !nonAdmins.isEmpty { return nonAdmins }
    // Fall back: show full roster on Subscribers when server didn't split lists
    // (common right after create — only owner exists).
    return channelRosterMembers
  }

  /// Model configuration: repository + per-agent model menus (model on the right).
  @ViewBuilder
  private var groupModelsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      profileSectionHeader("Models")
      ChatProfileSwiftUISection(fill: rowFill) {
      Menu {
        let repos = availableRepositories
        let selected =
          AgentBridgeSelectionStore.selectedRepository(
            chatId: bridgeChatId.isEmpty ? nil : bridgeChatId
          )
        if repos.isEmpty {
          Button("Browse repositories…") {
            if let provider = groupBridgeProvider {
              onAction("bridgeRepository:\(provider)")
            }
          }
        } else {
          ForEach(repos, id: \.id) { repo in
            Button {
              selectRepository(repo)
            } label: {
              if repo.id == selected?.id || repo.cwd == selected?.cwd {
                Label(repo.name, systemImage: "checkmark")
              } else {
                Text(repo.name)
              }
            }
          }
          Divider()
          Button("Browse all…") {
            if let provider = groupBridgeProvider {
              onAction("bridgeRepository:\(provider)")
            }
          }
        }
      } label: {
        // Left title stable; right side is the selected value.
        ChatProfileSwiftUIRow(
          title: "Repository",
          trailingText: resolvedRepositorySubtitle,
          trailingSystemImage: "chevron.up.chevron.down",
          showsChevron: false,
          separatorColor: separatorColor,
          isLast: groupBridgeProviders.isEmpty
        )
      }
      .buttonStyle(ChatProfileSwiftUIRowButtonStyle())

      ForEach(Array(groupBridgeProviders.enumerated()), id: \.element) { index, agentProvider in
        agentProviderMenu(provider: agentProvider, isLast: index == groupBridgeProviders.count - 1)
      }
      }
    }
  }

  /// Nested Menu: Thinking (toggle + levels) on top, latest models, Other Models submenu.
  @ViewBuilder
  private func agentProviderMenu(provider agentProvider: String, isLast: Bool) -> some View {
    let levels = AgentBridgeSelectionStore.intelligenceChoices(
      provider: agentProvider, model: groupSelectedModel(agentProvider))
    let primary = AgentBridgeSelectionStore.primaryModelChoices(provider: agentProvider)
    let other = AgentBridgeSelectionStore.otherModelChoices(provider: agentProvider)
    let selectedModel = groupSelectedModel(agentProvider)

    Menu {
      // Nested Thinking overlay — switch + levels (lives at top of the menu).
      if !levels.isEmpty {
        Menu {
          Toggle(
            "Thinking",
            isOn: Binding(
              get: { thinkingEnabledLocal },
              set: { next in
                thinkingEnabledLocal = next
                AgentBridgeSelectionStore.setThinkingEnabled(next)
              }
            )
          )
          if thinkingEnabledLocal {
            Divider()
            ForEach(levels, id: \.self) { level in
              Button {
                AgentBridgeSelectionStore.setThinkingEnabled(true)
                AgentBridgeSelectionStore.setIntelligence(level)
                thinkingEnabledLocal = true
                intelligenceLocal = level
              } label: {
                if intelligenceLocal == level {
                  Label(level.title, systemImage: "checkmark")
                } else {
                  Text(level.title)
                }
              }
            }
          }
        } label: {
          Label(
            thinkingEnabledLocal ? "Thinking · \(intelligenceLocal.title)" : "Thinking · Off",
            systemImage: "brain"
          )
        }
        Divider()
      }

      // Latest models only at the top level.
      Button {
        AgentBridgeSelectionStore.setModel(provider: agentProvider, model: nil)
        groupModelSelections[agentProvider] = ""
      } label: {
        if selectedModel == nil {
          Label("Default", systemImage: "checkmark")
        } else {
          Text("Default")
        }
      }
      ForEach(primary, id: \.value) { choice in
        Button {
          AgentBridgeSelectionStore.setModel(provider: agentProvider, model: choice.value)
          groupModelSelections[agentProvider] = choice.value
        } label: {
          if selectedModel == choice.value {
            Label(choice.title, systemImage: "checkmark")
          } else {
            Text(choice.title)
          }
        }
      }

      // Older / non-latest models nested under Other Models.
      if !other.isEmpty {
        Menu("Other Models") {
          ForEach(other, id: \.value) { choice in
            Button {
              AgentBridgeSelectionStore.setModel(provider: agentProvider, model: choice.value)
              groupModelSelections[agentProvider] = choice.value
            } label: {
              if selectedModel == choice.value {
                Label(choice.title, systemImage: "checkmark")
              } else {
                Text(choice.title)
              }
            }
          }
        }
      }
    } label: {
      ChatProfileSwiftUIRow(
        title: AgentBridgeProfile.displayName(for: agentProvider),
        trailingText: groupModelSubtitle(agentProvider),
        trailingSystemImage: "chevron.up.chevron.down",
        showsChevron: false,
        separatorColor: separatorColor,
        isLast: isLast
      )
    }
    .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
    .onAppear {
      AgentBridgeSelectionStore.refreshModelsIfPossible()
    }
  }

  /// Permissions (agent work mode) when Claude/Codex present in the group.
  @ViewBuilder
  private var groupPermissionsSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      profileSectionHeader("Permission")
      ChatProfileSwiftUISection(fill: rowFill) {
        Menu {
          ForEach(AgentBridgeWorkMode.allCases) { mode in
            Button {
              AgentBridgeSelectionStore.setWorkMode(mode)
              workModeLocal = mode
              NotificationCenter.default.post(
                name: NSNotification.Name("AgentBridgeWorkModeChanged"), object: nil)
            } label: {
              if workModeLocal == mode {
                Label(mode.title, systemImage: "checkmark")
              } else {
                Label(mode.title, systemImage: mode.icon)
              }
            }
          }
        } label: {
          ChatProfileSwiftUIRow(
            title: "Mode",
            trailingText: workModeLocal.title,
            trailingSystemImage: "chevron.up.chevron.down",
            showsChevron: false,
            separatorColor: separatorColor,
            isLast: true
          )
        }
        .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
      }
    }
  }

  /// Vibe AI agent row → pageSheet editor (not a full-screen push).
  @ViewBuilder
  private var groupConfigurationSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      profileSectionHeader("Agent")
      ChatProfileSwiftUISection(fill: rowFill) {
        Button {
          onAction("agentConfig")
        } label: {
          ChatProfileSwiftUIRow(
            title: "Vibe AI",
            trailingText: nil,
            showsChevron: true,
            separatorColor: separatorColor,
            isLast: true
          )
        }
        .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
      }
    }
  }

  // Identity row for a bridge agent: "Computer" + device label, with a live green
  // dot when the daemon is online. No copy affordance; chevron opens the sheet.
  private func bridgeComputerRow(isLast: Bool) -> some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("computer")
          .font(.system(size: 17, weight: .regular))
          .foregroundStyle(showsGoldTier ? goldTierColor : .primary)
          .lineLimit(1)
        HStack(spacing: 6) {
          if bridgeConnected && !bridgeRunningTasks.isEmpty {
            // A live task on the computer → a spinner so the profile reads as
            // "working right now", not just a static "connected" dot.
            ProgressView().controlSize(.mini)
          } else if bridgeConnected {
            Circle().fill(Color.green).frame(width: 8, height: 8)
          }
          Text(bridgeComputerSubtitle)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(bridgeConnected && !bridgeRunningTasks.isEmpty ? Color.green : Color.secondary)
            .lineLimit(1)
        }
      }

      Spacer(minLength: 12)

      Image(systemName: "chevron.right")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Color.secondary.opacity(0.8))
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 11)
    .frame(maxWidth: .infinity, minHeight: 62, alignment: .center)
    .contentShape(Rectangle())
    .overlay(alignment: .bottom) {
      if !isLast {
        Rectangle()
          .fill(separatorColor)
          .frame(height: 1 / UIScreen.main.scale)
          .padding(.leading, 18)
      }
    }
  }

  private var bridgeComputerSubtitle: String {
    if bridgeConnected && !bridgeRunningTasks.isEmpty {
      let count = bridgeRunningTasks.count
      let label = bridgeDeviceLabel.isEmpty ? "Connected" : bridgeDeviceLabel
      return "\(label) · \(count) running"
    }
    if bridgeConnected {
      return bridgeDeviceLabel.isEmpty ? "Connected" : "\(bridgeDeviceLabel) · Connected"
    }
    if bridgePaired {
      return "Paired · offline — tap to reconnect"
    }
    return "Not connected — tap to connect"
  }

  /// Claude/Codex only: pick whether opening this agent's DM lands in the classic chat
  /// (bubbles + wallpaper) or jumps straight to the full-page agent runtime view.
  private var defaultViewSection: some View {
    ChatProfileSwiftUISection(fill: rowFill) {
      Menu {
        Picker("Default view", selection: bridgeDefaultViewBinding) {
          ForEach(AgentBridgeDefaultView.allCases) { option in
            Text(option.title).tag(option)
          }
        }
      } label: {
        ChatProfileSwiftUIRow(
          title: "Default view",
          subtitle: bridgeDefaultView.subtitle,
          trailingSystemImage: "chevron.up.chevron.down",
          showsChevron: false,
          separatorColor: separatorColor,
          isLast: true
        )
      }
      .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
    }
    .onAppear {
      bridgeDefaultView = AgentBridgeSelectionStore.defaultView(provider: bridgeProvider)
    }
  }

  private var bridgeDefaultViewBinding: Binding<AgentBridgeDefaultView> {
    Binding(
      get: { bridgeDefaultView },
      set: { newValue in
        bridgeDefaultView = newValue
        AgentBridgeSelectionStore.setDefaultView(provider: bridgeProvider, newValue)
      }
    )
  }

  private var historySection: some View {
    ChatProfileSwiftUISection(fill: rowFill) {
      Button {
        navCoordinator.path.append(.history)
      } label: {
        ChatProfileSwiftUIRow(
          title: "Chat History",
          subtitle: historySubtitle,
          trailingSystemImage: nil,
          showsChevron: true,
          separatorColor: separatorColor,
          isLast: true
        )
        .matchedTransitionSource(id: ChatProfileSwiftUIDestination.history.transitionID, in: morphNamespace)
      }
      .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
    }
  }

  private var bridgeDisplayName: String {
    switch bridgeProvider.lowercased() {
    case "claude": return "Claude"
    case "codex": return "Codex"
    case "grok": return "Grok"
    case "agy", "antigravity": return "Agy"
    default: return bridgeProvider.capitalized
    }
  }

  private var bridgeHistorySection: some View {
    ChatProfileSwiftUISection(fill: rowFill) {
      Button {
        navCoordinator.path.append(.bridgeHistory)
      } label: {
        ChatProfileSwiftUIRow(
          title: "Chat History",
          subtitle: bridgeHistorySubtitle,
          trailingSystemImage: nil,
          showsChevron: true,
          separatorColor: separatorColor,
          isLast: true
        )
        .matchedTransitionSource(id: ChatProfileSwiftUIDestination.bridgeHistory.transitionID, in: morphNamespace)
      }
      .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
    }
  }

  private var usernameQRSheet: some View {
    let handle = username.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
    let encoded = handle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? handle
    let value = "vibe://u?username=\(encoded)"

    return NavigationStack {
      VStack(spacing: 22) {
        Spacer(minLength: 24)
        ZStack {
          RoundedRectangle(cornerRadius: 30, style: .continuous)
            .fill(Color.white)
            .frame(width: 248, height: 248)
            .shadow(color: Color.black.opacity(0.14), radius: 24, y: 12)

          if let image = QRCodeRenderer.image(for: value) {
            Image(uiImage: image)
              .interpolation(.none)
              .resizable()
              .scaledToFit()
              .frame(width: 194, height: 194)
          } else {
            Image(systemName: "qrcode")
              .font(.system(size: 72, weight: .light))
              .foregroundStyle(.secondary)
          }
        }

        VStack(spacing: 6) {
          Text(username)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.primary)
          Text("Scan to open this Vibegram profile")
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .frame(maxWidth: .infinity)
      .background(pageColor.ignoresSafeArea())
      .navigationTitle("QR Code")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("Done") { showUsernameQR = false }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  private var bridgeHistorySubtitle: String {
    if !bridgeRunningTasks.isEmpty {
      let count = bridgeRunningTasks.count
      return count == 1 ? "1 running \(bridgeDisplayName) chat" : "\(count) running \(bridgeDisplayName) chats"
    }
    return "\(bridgeDisplayName) conversations on your computer"
  }

  @ViewBuilder
  private var sharedContentSection: some View {
    if !tabSummaries.isEmpty {
      let viewportHeight = max(1, UIScreen.main.bounds.height)
      let pinnedTop = sharedContentPinnedTopY
      ChatProfileSwiftUIExpandedContentView(
        title: "Shared Content",
        items: [],
        fill: rowFill,
        separatorColor: separatorColor,
        onContentPressed: onContentPressed,
        tabs: tabSummaries,
        tabItems: tabItems,
        initialTab: tabSummaries.first?.tab,
        embedded: true,
        onTabPressed: {
          let headerAnchor = UnitPoint(
            x: 0.5,
            y: min(0.35, pinnedTop / viewportHeight)
          )
          sharedContentFocusArmed = false
          withAnimation(.easeOut(duration: 0.34)) {
            sharedContentFocused = true
            profileScrollProxy?.scrollTo(Self.sharedContentAnchorID, anchor: headerAnchor)
          }
          // Re-align after the shrinking identity cluster changes content geometry.
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
            withAnimation(.easeOut(duration: 0.18)) {
              profileScrollProxy?.scrollTo(Self.sharedContentAnchorID, anchor: headerAnchor)
            }
            sharedContentFocusArmed = true
          }
        }
      )
      .background {
        GeometryReader { geo in
          Color.clear
            .onAppear { sharedContentMeasuredHeight = geo.size.height }
            .onChange(of: geo.size.height) { _, next in
              sharedContentMeasuredHeight = next
            }
        }
      }
    }
  }

  static let sharedContentAnchorID = "profileSharedContentTop"

  /// Marker the tab strip scrolls to: tall enough to leave the header clear,
  /// then negated so it costs no layout space.
  private var sharedContentScrollAnchor: some View {
    Color.clear
      .frame(height: 1)
      .id(Self.sharedContentAnchorID)
  }

  // Contact actions moved into profileInfoSection — identity and its actions are one card.

  private var emergencySection: some View {
    ChatProfileSwiftUISection(fill: rowFill) {
      Button { onAction("addToEmergency") } label: {
        ChatProfileSwiftUIRow(title: "Add to Emergency Contacts", separatorColor: separatorColor, isLast: true)
      }
      .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
    }
  }

  @ViewBuilder
  private var dangerSection: some View {
    if isGroupOrChannel {
      // The owner can't just leave — they tear the whole room down. Everyone
      // else leaves.
      ChatProfileSwiftUISection(fill: rowFill) {
        if isGroupOwner {
          Button(role: .destructive) { onAction("deleteGroup") } label: {
            ChatProfileSwiftUIRow(
              title: isChannel ? "Delete Channel" : "Delete Group",
              titleColor: .red,
              separatorColor: separatorColor,
              isLast: true
            )
          }
          .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
        } else {
          Button(role: .destructive) { onAction("leaveGroup") } label: {
            ChatProfileSwiftUIRow(
              title: isChannel ? "Leave Channel" : "Leave Group",
              titleColor: .red,
              separatorColor: separatorColor,
              isLast: true
            )
          }
          .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
        }
      }
    } else {
      ChatProfileSwiftUISection(fill: rowFill) {
        Button(role: .destructive) { onAction("clearChat") } label: {
          ChatProfileSwiftUIRow(
            title: "Clear Chat",
            titleColor: .red,
            separatorColor: separatorColor,
            isLast: true
          )
        }
        .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
      }
    }
  }

  private func closePresentedEditor() {
    if inlineEditDestination != nil {
      withAnimation(.easeOut(duration: 0.16)) {
        inlineEditDestination = nil
      }
    } else if !navCoordinator.path.isEmpty {
      navCoordinator.path.removeLast()
    }
  }

  @ViewBuilder
  private func destinationView(for destination: ChatProfileSwiftUIDestination) -> some View {
    switch destination {
    case .history:
      ChatProfileSwiftUIExpandedContentView(
        title: "Chat History",
        items: historyItems,
        fill: rowFill,
        separatorColor: separatorColor,
        onContentPressed: onContentPressed
      )
    case .bridgeHistory:
      AgentBridgeHistoryInlineView(
        provider: bridgeProvider,
        chatId: bridgeChatId,
        runningTasks: bridgeRunningTasks,
        deviceLabel: bridgeDeviceLabel,
        connected: bridgeConnected,
        paired: bridgePaired,
        onOpenSession: { session in
          navCoordinator.path.append(.bridgeSession(session))
        }
      )
      .background(Color(uiColor: UIColor.systemGroupedBackground))
    case .bridgeSession(let session):
      AgentBridgeRuntimeView(
        provider: bridgeProvider,
        chatId: bridgeChatId,
        session: session,
        subtitle: session.displayProjectName,
        newChatTrigger: $newChatTrigger
      )
      .ignoresSafeArea()
      .navigationTitle(session.topic)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .principal) {
          Text(session.topic)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
        }
        ToolbarItem(placement: .topBarTrailing) {
          HStack(spacing: 14) {
            Button {
              newChatTrigger = true
            } label: {
              Image(systemName: "square.and.pencil")
            }

            Menu {
              Button("Pin", systemImage: "pin") {}
              Button("Files", systemImage: "folder") {}
            } label: {
              Image(systemName: "ellipsis")
            }
          }
          .padding(.trailing, 8)
        }
      }
    case .appearance:
      ChatProfileAppearanceEditorView(
        profileName: profileName,
        avatarUri: avatarUri,
        hasProfileImage: hasProfileImage,
        initialSelection: appearanceSelection,
        onSave: onSaveAppearance
      )
    case .encryption:
      if let peerUserId = ChatEngine.shared.peerUserId(chatId: chatId), !peerUserId.isEmpty {
        ChatEncryptionVerifyView(
          chatId: chatId,
          peerUserId: peerUserId,
          peerName: {
            let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty, name.caseInsensitiveCompare(peerUserId) != .orderedSame {
              return name
            }
            let handle = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !handle.isEmpty else { return "" }
            return handle.hasPrefix("@") ? handle : "@\(handle)"
          }()
        )
      } else {
        Text("Encryption identity is not available yet.")
          .foregroundStyle(.secondary)
          .navigationTitle("Verify Encryption")
      }
    case .tab(let tab):
      ChatProfileSwiftUIExpandedContentView(
        title: "Shared Content",
        items: [],
        fill: rowFill,
        separatorColor: separatorColor,
        onContentPressed: onContentPressed,
        tabs: tabSummaries,
        tabItems: tabItems,
        initialTab: tab
      )
    case .channelAdmins:
      // Reuse the same group member list (avatar + name + role, A–Z sections).
      ChatProfileMembersListView(
        title: "Administrators",
        items: channelMembersAsContentItems(channelAdministrators),
        canAddMembers: false,
        isChannel: true,
        onContentPressed: onContentPressed,
        onAddMembers: {}
      )
    case .channelSubscribers:
      ChatProfileMembersListView(
        title: "Subscribers",
        items: channelMembersAsContentItems(channelSubscribers),
        canAddMembers: false,
        isChannel: true,
        onContentPressed: onContentPressed,
        onAddMembers: {}
      )
    case .channelSettings:
      ChannelSettingsPage(
        chatId: bridgeChatId,
        channelName: profileName,
        channelDescription: note,
        avatarUri: avatarUri,
        canManage: canManageGroupMembers,
        settings: $channelSettingsLocal,
        adminCount: channelAdministrators.count,
        subscriberCount: {
          if let channelSubscriberCount, channelSubscriberCount > 0 {
            return channelSubscriberCount
          }
          if let memberCount, memberCount > 0 { return memberCount }
          return max(channelSubscribers.count, groupMembers.count)
        }(),
        onEditName: {
          withAnimation(.easeOut(duration: 0.16)) {
            inlineEditDestination = .editRoom
          }
        },
        onOpenAppearance: {
          // Photo/poster disabled for channels — identity is edit name/description only.
        },
        onOpenRecentActions: {
          navCoordinator.path.append(.channelRecentActions)
        },
        onOpenAdministrators: {
          onMembersScreenAppeared?()
          navCoordinator.path.append(.channelAdmins)
        },
        onOpenSubscribers: {
          onMembersScreenAppeared?()
          navCoordinator.path.append(.channelSubscribers)
        },
        onDescriptionChanged: { desc in
          onAction("channelDescription:\(desc)")
        },
        onNameChanged: { name in
          onAction("roomEdited:\(name)")
        },
        onAvatarChanged: { url in
          onAction("roomAvatar:\(url)")
        },
        onSettingsChanged: { next in
          channelSettingsLocal = next
        },
        onDismiss: closePresentedEditor
      )
    case .channelRecentActions:
      ChannelRecentActionsPage(actions: channelProfileCache?.recentActions ?? [])
    case .editRoom:
      if let config = AppSessionConfig.current {
        RoomEditPage(
          config: config,
          chatId: bridgeChatId,
          isChannel: isChannel,
          initialName: profileName,
          initialDescription: note,
          initialAvatarUri: avatarUri,
          memberCount: memberCount ?? groupMembers.count,
          onOpenMembers: {
            onMembersScreenAppeared?()
            navCoordinator.path.append(isChannel ? .channelSubscribers : .members)
          },
          onDismiss: closePresentedEditor
        ) { name, description, avatarUrl in
          onAction("roomEdited:\(name)")
          if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onAction("channelDescription:\(description)")
          }
          if let avatarUrl, !avatarUrl.isEmpty {
            onAction("roomAvatar:\(avatarUrl)")
          }
          closePresentedEditor()
        }
      } else {
        Text("Not signed in")
      }
    case .members:
      // Snapshot items once for this destination body — avoid recomputing
      // [String: Any] payloads on every AttributeGraph pass (ForEach churn).
      let memberItems = swiftUIMemberItems()
      ChatProfileMembersListView(
        title: isChannel ? "Channel control" : "Members",
        items: memberItems,
        // Channels are join-based; admins manage roles, not bulk-invite here.
        canAddMembers: canManageGroupMembers && !isChannel,
        isChannel: isChannel,
        onContentPressed: onContentPressed,
        onAddMembers: {
          showAddMembersSheet = true
        }
      )
      .onAppear {
        let count = memberItems.count
        let sample = memberItems.prefix(6).map { item in
          "\(String(item.id.prefix(6))):\(item.subtitle):\(String(item.title.prefix(12)))"
        }.joined(separator: " ")
        NSLog(
          "[WhoAmI] MembersScreen.onAppear chatId=%@ members=%d renderedItems=%d canManage=%@ sample=[%@]",
          bridgeChatId.isEmpty ? "<none>" : String(bridgeChatId.prefix(12)),
          groupMembers.count,
          count,
          canManageGroupMembers ? "Y" : "N",
          sample
        )
        // Defer host hydration out of the navigation transaction (Fable):
        // mutating published roster mid-push was a SIGBUS / AttributeGraph cycle.
        DispatchQueue.main.async {
          onMembersScreenAppeared?()
        }
      }
    case .addMembers:
      // Kept for path compatibility — prefer material sheet (`showAddMembersSheet`).
      Color.clear
        .onAppear {
          if !navCoordinator.path.isEmpty {
            navCoordinator.path.removeLast()
          }
          showAddMembersSheet = true
        }
    }
  }

  private func swiftUIMemberItems() -> [ChatProfileSwiftUIContentItem] {
    chatProfileMemberItems(from: groupMembers).map { item in
      contentItem(fromMemberItem: item)
    }
  }

  private func channelMembersAsContentItems(
    _ members: [ChannelProfileService.Member]
  ) -> [ChatProfileSwiftUIContentItem] {
    members.map { member in
      let roleKey: String = {
        switch member.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "owner": return "owner"
        case "admin": return "admin"
        case "agent admin", "agent_admin": return "agent_admin"
        case "subscriber": return "subscriber"
        default: return "member"
        }
      }()
      let resolved = ChatAvatarURLResolver.resolve(
        rawAvatar: member.avatarUrl,
        peerUserId: member.userId,
        chatId: nil,
        preferPushAvatar: true,
        isAgent: roleKey == "agent_admin",
        agentId: nil,
        displayName: member.name
      )
      var payload: [String: Any] = [
        "type": "groupMemberTapped",
        "userId": member.userId,
        "role": roleKey,
        "name": member.name,
        "canManage": canManageGroupMembers,
      ]
      if let resolved { payload["avatarUri"] = resolved }
      return ChatProfileSwiftUIContentItem(
        id: member.userId,
        title: member.name,
        subtitle: Self.displayRoleLabel(member.role),
        systemImage: roleKey == "owner" || roleKey == "admin" || roleKey == "agent_admin"
          ? "star.circle.fill"
          : "person.circle",
        avatarUri: resolved,
        roleKey: roleKey,
        payload: payload
      )
    }
  }

  private func contentItem(
    fromMemberItem item: ChatGroupMembersViewController.MemberItem
  ) -> ChatProfileSwiftUIContentItem {
    let roleKey: String = {
      switch item.roleLabel.lowercased() {
      case "owner": return "owner"
      case "admin": return "admin"
      case "agent admin", "agent_admin": return "agent_admin"
      case "subscriber": return "subscriber"
      default: return "member"
      }
    }()
    var payload: [String: Any] = [
      "type": "groupMemberTapped",
      "userId": item.userId,
      "role": roleKey,
      "name": item.name,
      "canManage": canManageGroupMembers,
    ]
    if let avatar = item.avatarUri {
      payload["avatarUri"] = avatar
    }
    return ChatProfileSwiftUIContentItem(
      id: item.userId,
      title: item.name,
      subtitle: item.roleLabel,
      systemImage: item.isAdmin || roleKey == "agent_admin"
        ? "star.circle.fill"
        : "person.circle",
      avatarUri: item.avatarUri,
      roleKey: roleKey,
      payload: payload
    )
  }
}

/// Shared roster mapping (home payload → avatar-resolved member rows).
private func chatProfileMemberItems(from raw: [[String: Any]]) -> [ChatGroupMembersViewController.MemberItem] {
  var seen = Set<String>()
  var out: [ChatGroupMembersViewController.MemberItem] = []
  for entry in raw {
    let userId =
      (entry["userId"] as? String)
      ?? (entry["user_id"] as? String)
      ?? (entry["id"] as? String)
      ?? (entry["memberId"] as? String)
    guard let userId, !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      continue
    }
    let key = userId.uppercased()
    guard seen.insert(key).inserted else { continue }
    let rawName =
      (entry["name"] as? String)
      ?? (entry["displayName"] as? String)
      ?? (entry["username"] as? String)
    let trimmedName = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let name = trimmedName.isEmpty ? userId : trimmedName
    let rawRole =
      ((entry["role"] as? String)
        ?? (entry["memberRole"] as? String)
        ?? (entry["member_role"] as? String)
        ?? "member")
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let roleLabel: String
    switch rawRole {
    case "owner": roleLabel = "Owner"
    case "admin": roleLabel = "Admin"
    case "agent_admin": roleLabel = "Agent admin"
    case "subscriber": roleLabel = "Subscriber"
    case "member", "": roleLabel = "Member"
    default: roleLabel = rawRole.capitalized
    }
    let rawAvatar =
      (entry["avatarUrl"] as? String)
      ?? (entry["avatar_url"] as? String)
      ?? (entry["avatarUri"] as? String)
      ?? (entry["profileImage"] as? String)
      ?? (entry["profile_image"] as? String)
      ?? (entry["imageUrl"] as? String)
    let trimmedAvatar = rawAvatar?.trimmingCharacters(in: .whitespacesAndNewlines)
    let resolved = ChatAvatarURLResolver.resolve(
      rawAvatar: (trimmedAvatar?.isEmpty ?? true) ? nil : trimmedAvatar,
      peerUserId: userId,
      chatId: nil,
      preferPushAvatar: true,
      isAgent: rawRole == "agent_admin",
      agentId: rawRole == "agent_admin" ? userId : nil,
      displayName: name
    )
    out.append(
      .init(
        userId: userId,
        name: name,
        roleLabel: roleLabel,
        isAdmin: rawRole == "owner" || rawRole == "admin",
        avatarUri: resolved
      )
    )
  }
  return out
}

/// Members destination: role-grouped plain List (home/New Chat style).
/// No nested cards, no blur chrome — parent NavigationStack owns the bar.
private struct ChatProfileMembersListView: View {
  @Environment(\.colorScheme) private var colorScheme

  let title: String
  let items: [ChatProfileSwiftUIContentItem]
  let canAddMembers: Bool
  var isChannel: Bool = false
  let onContentPressed: ([String: Any]) -> Void
  let onAddMembers: () -> Void

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    List {
      if cleanedItems.isEmpty {
        Section {
          Text(isChannel ? "No subscribers yet" : "No members yet")
            .font(.system(size: 15))
            .foregroundStyle(palette.secondaryText)
            .listRowBackground(Color.clear)
        }
      } else {
        if !owners.isEmpty {
          plainSection(title: owners.count == 1 ? "Owner" : "Owners", rows: owners)
        }
        if !admins.isEmpty {
          plainSection(title: "Admins", rows: admins)
        }
        if !agentAdmins.isEmpty {
          plainSection(
            title: agentAdmins.count == 1 ? "Agent admin" : "Agent admins",
            rows: agentAdmins
          )
        }
        if !membersOnly.isEmpty {
          let memberTitle: String = {
            if isChannel {
              return membersOnly.count == 1 ? "Subscriber" : "Subscribers"
            }
            return membersOnly.count == 1 ? "Member" : "Members"
          }()
          plainSection(title: memberTitle, rows: membersOnly)
        }
      }
    }
    .listStyle(.plain)
    .listSectionSpacing(8)
    .scrollContentBackground(.hidden)
    .background(Color.clear.ignoresSafeArea())
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(false)
    .toolbarBackground(.hidden, for: .navigationBar)
    .toolbar {
      if canAddMembers {
        ToolbarItem(placement: .topBarTrailing) {
          Button(action: onAddMembers) {
            Image(systemName: "person.badge.plus")
          }
          .accessibilityLabel("Add Members")
        }
      }
    }
  }

  /// Drop rows with no usable display name (junk / unhydrated).
  private var cleanedItems: [ChatProfileSwiftUIContentItem] {
    items.filter {
      !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  private var owners: [ChatProfileSwiftUIContentItem] {
    cleanedItems.filter { $0.roleKey == "owner" }
  }
  private var admins: [ChatProfileSwiftUIContentItem] {
    cleanedItems.filter { $0.roleKey == "admin" }
  }
  private var agentAdmins: [ChatProfileSwiftUIContentItem] {
    cleanedItems.filter { $0.roleKey == "agent_admin" }
  }
  private var membersOnly: [ChatProfileSwiftUIContentItem] {
    cleanedItems.filter {
      $0.roleKey != "owner" && $0.roleKey != "admin" && $0.roleKey != "agent_admin"
    }
  }

  @ViewBuilder
  private func plainSection(title: String, rows: [ChatProfileSwiftUIContentItem]) -> some View {
    Section(title) {
      ForEach(rows, id: \.id) { item in
        // Hold only — no tap popup, no swipe. Context menu owns admin actions.
        ChatProfileMemberHomeStyleRow(item: item, palette: palette)
          .contentShape(Rectangle())
          .contextMenu {
            if canAddMembers, item.roleKey != "owner" {
              Button("Manage", systemImage: "person.crop.circle.badge.checkmark") {
                onContentPressed(item.payload)
              }
              if item.roleKey == "member" {
                Button("Promote to Admin", systemImage: "arrow.up.circle") {
                  var p = item.payload
                  p["action"] = "promote"
                  onContentPressed(p)
                }
              }
              if item.roleKey == "admin" {
                Button("Demote to Member", systemImage: "arrow.down.circle") {
                  var p = item.payload
                  p["action"] = "demote"
                  onContentPressed(p)
                }
              }
              Button("Remove from Group", systemImage: "person.badge.minus", role: .destructive) {
                var p = item.payload
                p["action"] = "remove"
                onContentPressed(p)
              }
            }
          }
          .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
          .listRowBackground(Color.clear)
          .listRowSeparatorTint(palette.border.opacity(0.55))
      }
    }
  }
}

/// Home / New Chat list row: shared avatar store + name + optional role (no chevron).
private struct ChatProfileMemberHomeStyleRow: View {
  let item: ChatProfileSwiftUIContentItem
  let palette: AppThemePalette

  @State private var image: UIImage?
  @State private var loadedUri: String?

  private var fallbackGlyph: String {
    let trimmed = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "?" }
    let parts = trimmed.split(separator: " ").prefix(2)
    if parts.count >= 2 {
      return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
    }
    return String(trimmed.prefix(2)).uppercased()
  }

  private var gradient: (UIColor, UIColor) {
    ChatProfileAppearanceStore.avatarColors(
      title: item.title,
      peerUserId: item.id,
      chatId: nil
    )
  }

  var body: some View {
    HStack(spacing: 12) {
      ZStack {
        Circle()
          .fill(
            LinearGradient(
              colors: [Color(uiColor: gradient.0), Color(uiColor: gradient.1)],
              startPoint: .top,
              endPoint: .bottom
            )
          )
        if let image {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .transition(.opacity)
        } else {
          Text(fallbackGlyph)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(palette.buttonText)
        }
      }
      .frame(width: 42, height: 42)
      .clipShape(Circle())
      .overlay(alignment: .bottomTrailing) {
        if item.roleKey == "agent_admin" {
          Image(systemName: "sparkles")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 16, height: 16)
            .background(palette.accent, in: Circle())
            .overlay(Circle().stroke(palette.card, lineWidth: 1.5))
        }
      }
      .animation(.easeInOut(duration: 0.22), value: image != nil)

      VStack(alignment: .leading, spacing: 2) {
        Text(item.title)
          .font(.system(size: 17, weight: .regular))
          .foregroundStyle(palette.text)
          .lineLimit(1)
        if item.roleKey == "owner" || item.roleKey == "admin" || item.roleKey == "agent_admin"
          || item.roleKey == "subscriber"
        {
          Text(item.subtitle)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(palette.secondaryText)
            .lineLimit(1)
        }
      }

      Spacer(minLength: 8)
    }
    .padding(.vertical, 6)
    .frame(minHeight: 52)
    .contentShape(Rectangle())
    .task(id: item.avatarUri ?? item.id) {
      await loadAvatar()
    }
  }

  @MainActor
  private func loadAvatar() async {
    let raw = item.avatarUri?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !raw.isEmpty else {
      // Keep image if any; only clear when no URL.
      if image != nil { return }
      image = nil
      loadedUri = nil
      return
    }
    if let cached = ChatAvatarImageStore.cached(for: raw) {
      withAnimation(.easeInOut(duration: 0.18)) { image = cached }
      loadedUri = raw
      return
    }
    // Keep previous photo while fetching (no initials flash).
    let loaded = await ChatAvatarImageStore.load(from: raw)
    guard !Task.isCancelled else { return }
    let current = item.avatarUri?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard current == raw else { return }
    if let loaded {
      withAnimation(.easeInOut(duration: 0.22)) { image = loaded }
      loadedUri = raw
    }
  }
}

private struct ChatProfileAvatarGlyph: View {
  let text: String
  let fontStyleID: String?
  let size: CGFloat

  var body: some View {
    Text(text)
      .font(.system(size: max(16, size), weight: .bold, design: ChatProfileAvatarFontStyle.style(id: fontStyleID).design))
      .foregroundStyle(.white)
      .lineLimit(1)
      .minimumScaleFactor(0.28)
      .padding(.horizontal, size * 0.26)
  }
}

// MARK: - Page-level fixed reflection (never scrolls)

/// Soft ambient + blurred bloom pinned to the profile page top.
/// Always mounts the black/gradient base (no remove/flash); image crossfades in.
private struct ChatProfilePageReflection: View {
  let imageUri: String?
  let fallbackGlyph: String
  let fontStyleID: String?
  let height: CGFloat

  @State private var image: UIImage?
  @State private var loadedUri: String?

  init(imageUri: String?, fallbackGlyph: String, fontStyleID: String?, height: CGFloat) {
    self.imageUri = imageUri
    self.fallbackGlyph = fallbackGlyph
    self.fontStyleID = fontStyleID
    self.height = height
    let normalized = imageUri?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    // Prime from cache synchronously so open never shows a late pop-in.
    let primed = normalized.flatMap { ChatAvatarImageStore.cached(for: $0) }
    _image = State(initialValue: primed)
    _loadedUri = State(initialValue: primed != nil ? normalized : nil)
  }

  var body: some View {
    GeometryReader { geo in
      let w = geo.size.width
      ZStack(alignment: .top) {
        // Always present — never `if` removed (black flash root cause).
        Color.black
        LinearGradient(
          stops: [
            .init(color: Color.white.opacity(0.07), location: 0.0),
            .init(color: Color.black.opacity(0.18), location: 0.40),
            .init(color: Color.black, location: 1.0),
          ],
          startPoint: .top,
          endPoint: .bottom
        )

        if let image {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: w, height: height)
            .scaleEffect(1.3)
            .blur(radius: 46)
            .opacity(0.40)
            .mask(
              LinearGradient(
                stops: [
                  .init(color: .black.opacity(0.9), location: 0.0),
                  .init(color: .black.opacity(0.6), location: 0.5),
                  .init(color: .black.opacity(0.2), location: 0.8),
                  .init(color: .clear, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
              )
            )
            .transition(.opacity)
        }

        LinearGradient(
          colors: [Color.black.opacity(0.28), Color.clear],
          startPoint: .top,
          endPoint: .bottom
        )
        .frame(height: 90)
      }
      .frame(width: w, height: height)
      .clipped()
    }
    .frame(height: height)
    .task(id: normalizedUri ?? "") { await loadImage() }
  }

  private var normalizedUri: String? {
    let value = imageUri?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }

  @MainActor
  private func loadImage() async {
    let normalized = normalizedUri
    if let normalized, let cached = ChatAvatarImageStore.cached(for: normalized) {
      loadedUri = normalized
      image = cached
      return
    }
    guard let normalized else { return }
    loadedUri = normalized
    let loaded = await ChatAvatarImageStore.loadHero(from: normalized)
    guard !Task.isCancelled else { return }
    withAnimation(.easeOut(duration: 0.22)) {
      image = loaded
    }
  }
}

// MARK: - Avatar shared-value morph (ONE continuous media element, 0→1)

/// Media-only pinned morph. Name + actions live in ScrollView (higher z).
/// No title overlays, no action overlays, no separate Material blur layer.
///
/// IMPORTANT: not `Animatable` — parent already animates `expand` with
/// `withAnimation`. Dual drivers desynced spacer vs media by 1–2px.
private struct ChatProfileAvatarMorphView: View {
  let text: String
  let fontStyleID: String?
  let imageUri: String?
  /// Same vertical gradient used by `ChatAvatarNodeView` / Home tiles.
  let fallbackColors: (UIColor, UIColor)
  /// When false (no photo), stay a fixed circle — no hero expand morph.
  let morphEnabled: Bool
  let width: CGFloat
  let collapsedHeight: CGFloat
  let heroBaseHeight: CGFloat
  /// Shared value 0 = circle, 1 = hero (spring-committed only).
  var expand: CGFloat = 0
  /// Extra height when pulling down in committed hero (realtime stretch).
  var overscrollStretch: CGFloat = 0
  var topAir: CGFloat = 90
  /// Scroll-collapse blend (collapsed circle only). Scale + fade — never blur.
  var scrollScale: CGFloat = 1
  var scrollOpacity: CGFloat = 1
  /// Downward media shift inside the clipped band while it scrolls away (expanded
  /// hero only) — the image trails the scroll at half speed, Telegram-style.
  var parallax: CGFloat = 0
  /// Page background the bottom edge dissolves into, so the image shows no edge.
  var edgeFadeColor: Color = .black
  var onImageAvailabilityChanged: (Bool) -> Void = { _ in }

  @State private var image: UIImage?
  @State private var loadedUri: String?

  init(
    text: String,
    fontStyleID: String?,
    imageUri: String?,
    fallbackColors: (UIColor, UIColor),
    morphEnabled: Bool,
    width: CGFloat,
    collapsedHeight: CGFloat,
    heroBaseHeight: CGFloat,
    expand: CGFloat = 0,
    overscrollStretch: CGFloat = 0,
    topAir: CGFloat = 90,
    scrollScale: CGFloat = 1,
    scrollOpacity: CGFloat = 1,
    parallax: CGFloat = 0,
    edgeFadeColor: Color = .black,
    onImageAvailabilityChanged: @escaping (Bool) -> Void = { _ in }
  ) {
    self.text = text
    self.fontStyleID = fontStyleID
    self.imageUri = imageUri
    self.fallbackColors = fallbackColors
    self.morphEnabled = morphEnabled
    self.width = width
    self.collapsedHeight = collapsedHeight
    self.heroBaseHeight = heroBaseHeight
    self.expand = morphEnabled ? expand : 0
    self.overscrollStretch = morphEnabled ? overscrollStretch : 0
    self.topAir = topAir
    self.scrollScale = scrollScale
    self.scrollOpacity = scrollOpacity
    self.parallax = morphEnabled ? parallax : 0
    self.edgeFadeColor = edgeFadeColor
    self.onImageAvailabilityChanged = onImageAvailabilityChanged
    let normalized = imageUri?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    let primed = normalized.flatMap { ChatAvatarImageStore.cached(for: $0) }
    _image = State(initialValue: primed)
    _loadedUri = State(initialValue: primed != nil ? normalized : nil)
  }

  private var p: CGFloat {
    morphEnabled ? min(1, max(0, expand)) : 0
  }

  private var circleSize: CGFloat { 104 }

  private static func pixelRound(_ value: CGFloat) -> CGFloat {
    let scale = UIScreen.main.scale
    return (value * scale).rounded() / scale
  }

  private var bandHeight: CGFloat {
    collapsedHeight + (heroBaseHeight - collapsedHeight) * p + overscrollStretch
  }

  private var mediaW: CGFloat {
    circleSize + (width - circleSize) * p
  }

  private var mediaH: CGFloat {
    circleSize + (heroBaseHeight - circleSize) * p + overscrollStretch
  }

  private var mediaCorner: CGFloat {
    (circleSize * 0.5) * (1 - p)
  }

  private var mediaTop: CGFloat {
    topAir * (1 - p)
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: mediaCorner, style: .continuous)
    // Scroll blend only while collapsed (p≈0); gated by (1-p). No blur — the image
    // stays sharp through every scroll/morph state.
    let collapseBlend = 1 - p
    let s = 1 + (scrollScale - 1) * collapseBlend
    let o = 1 + (scrollOpacity - 1) * collapseBlend

    // Linear shared p only — no topAttach/sizeGrow (those made expand worse).
    return mediaBody
      .frame(width: mediaW, height: mediaH)
      .clipShape(shape)
      .scaleEffect(s, anchor: .top)
      .opacity(Double(o))
      .frame(width: width, alignment: .center)
      .padding(.top, mediaTop)
      .offset(y: parallax * p)
      .frame(width: width, height: bandHeight, alignment: .top)
      .clipped()
      .animation(nil, value: scrollScale)
      .onAppear { onImageAvailabilityChanged(image != nil) }
      .task(id: normalizedUri ?? "") { await loadImage() }
      .onReceive(NotificationCenter.default.publisher(for: ChatAvatarImageStore.didReplaceNotification)) {
        notification in
        guard let key = notification.object as? String,
          key == normalizedUri,
          let refreshed = ChatAvatarImageStore.cached(for: key)
        else { return }
        image = refreshed
        loadedUri = key
        onImageAvailabilityChanged(true)
      }
  }

  @ViewBuilder
  private var mediaFill: some View {
    if morphEnabled, let image {
      Image(uiImage: image)
        .resizable()
        .scaledToFill()
    } else {
      ZStack {
        LinearGradient(
          colors: [
            Color(uiColor: fallbackColors.0),
            Color(uiColor: fallbackColors.1),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        Text(text)
          .font(.system(
            size: max(10, mediaW * 0.4),
            weight: .semibold,
            design: ChatProfileAvatarFontStyle.style(id: fontStyleID).design
          ))
          .foregroundStyle(.white)
          .minimumScaleFactor(0.4)
          .lineLimit(1)
          .multilineTextAlignment(.center)
      }
    }
  }

  @ViewBuilder
  private var mediaBody: some View {
    // No edge at the bottom: the blur ramps in over a tall band and the colour ramp
    // reaches the page background on the last pixel, so the image dissolves into it.
    let edgeBlurHeight = max(72, min(180, mediaH * 0.42))

    ZStack(alignment: .bottom) {
      mediaFill

      if morphEnabled, let image, p > 0.001 {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
          .frame(width: mediaW, height: mediaH)
          .blur(radius: 44 * p, opaque: true)
          .frame(width: mediaW, height: edgeBlurHeight, alignment: .bottom)
          .clipped()
          .mask(
            LinearGradient(
              stops: [
                .init(color: .black.opacity(0), location: 0),
                .init(color: .black.opacity(0.22), location: 0.3),
                .init(color: .black.opacity(0.72), location: 0.62),
                .init(color: .black, location: 0.86),
                .init(color: .black, location: 1),
              ],
              startPoint: .top,
              endPoint: .bottom
            )
          )
          .opacity(p)

        LinearGradient(
          stops: [
            .init(color: edgeFadeColor.opacity(0), location: 0),
            .init(color: edgeFadeColor.opacity(0.16), location: 0.42),
            .init(color: edgeFadeColor.opacity(0.58), location: 0.72),
            .init(color: edgeFadeColor.opacity(0.94), location: 0.92),
            .init(color: edgeFadeColor, location: 1),
          ],
          startPoint: .top,
          endPoint: .bottom
        )
        .frame(width: mediaW, height: edgeBlurHeight)
        .allowsHitTesting(false)
        .opacity(p)
      }
    }
    .frame(width: mediaW, height: mediaH)
    .clipped()
  }

  private var normalizedUri: String? {
    let value = imageUri?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }

  @MainActor
  private func loadImage() async {
    let normalized = normalizedUri
    if let normalized, let cached = ChatAvatarImageStore.cached(for: normalized) {
      loadedUri = normalized
      image = cached
      onImageAvailabilityChanged(true)
      return
    }
    guard let normalized else {
      loadedUri = nil
      image = nil
      onImageAvailabilityChanged(false)
      return
    }
    loadedUri = normalized
    image = nil
    onImageAvailabilityChanged(false)
    // Hero-quality decode (list cells keep 384; banner needs more pixels).
    let loaded = await ChatAvatarImageStore.loadHero(from: normalized)
    guard !Task.isCancelled, loadedUri == normalized else { return }
    image = loaded
    onImageAvailabilityChanged(loaded != nil)
  }
}

private struct ChatProfileMiniAvatar: View {
  let text: String
  let fontStyleID: String?
  let colors: (UIColor, UIColor)
  let imageUri: String?

  @State private var image: UIImage?
  @State private var loadedUri: String?

  init(text: String, fontStyleID: String?, colors: (UIColor, UIColor), imageUri: String?) {
    self.text = text
    self.fontStyleID = fontStyleID
    self.colors = colors
    self.imageUri = imageUri
    let normalized = imageUri?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    let primed = normalized.flatMap { ChatAvatarImageStore.cached(for: $0) }
    _image = State(initialValue: primed)
    _loadedUri = State(initialValue: primed != nil ? normalized : nil)
  }

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color(uiColor: colors.0), Color(uiColor: colors.1)],
        startPoint: .top,
        endPoint: .bottom
      )

      if loadedUri == normalizedImageUri, let image {
        Image(uiImage: image)
          .resizable()
          .scaledToFill()
      } else {
        ChatProfileAvatarGlyph(text: text, fontStyleID: fontStyleID, size: 20)
      }
    }
    .frame(width: 52, height: 52)
    .clipShape(Circle())
    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
    .task(id: normalizedImageUri ?? "") {
      await loadImage()
    }
  }

  private var normalizedImageUri: String? {
    let value = imageUri?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }

  @MainActor
  private func loadImage() async {
    let normalized = normalizedImageUri
    if loadedUri != normalized {
      loadedUri = normalized
      image = normalized.flatMap { ChatAvatarImageStore.cached(for: $0) }
    }
    guard let normalized else {
      image = nil
      return
    }
    if let cached = ChatAvatarImageStore.cached(for: normalized) {
      image = cached
      return
    }
    let loaded = await ChatAvatarImageStore.load(from: normalized)
    guard !Task.isCancelled, loadedUri == normalized else { return }
    image = loaded
  }
}

private struct ChatProfileAppearanceEditorView: View {
  let profileName: String
  let avatarUri: String?
  let hasProfileImage: Bool
  let onSave: (ChatProfileAppearanceSelection) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var draft: ChatProfileAppearanceSelection
  @State private var mode: ChatProfileAppearanceMode = .avatar
  @State private var selectedPhotoItem: PhotosPickerItem?
  @State private var avatarImage: UIImage?
  @State private var avatarImageUri: String?
  @State private var isCustomizerPresented = false
  @State private var pendingCropImage: UIImageWrapper?

  private struct UIImageWrapper: Identifiable {
    let id = UUID()
    let image: UIImage
  }

  init(
    profileName: String,
    avatarUri: String?,
    hasProfileImage: Bool,
    initialSelection: ChatProfileAppearanceSelection,
    onSave: @escaping (ChatProfileAppearanceSelection) -> Void
  ) {
    self.profileName = profileName
    self.avatarUri = avatarUri
    self.hasProfileImage = hasProfileImage
    self.onSave = onSave
    _draft = State(initialValue: initialSelection)
  }

  private var initial: String {
    let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "U" : String(trimmed.prefix(1)).uppercased()
  }

  private var avatarDisplayText: String {
    let glyph = draft.avatarGlyph?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return glyph.isEmpty ? initial : glyph
  }

  private var backgroundColors: (UIColor, UIColor) {
    ChatProfileAppearancePalette.colors(for: draft, mode: .poster)
  }

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color(uiColor: backgroundColors.0), Color(uiColor: backgroundColors.1)],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 30) {
          Picker("", selection: $mode) {
            ForEach(ChatProfileAppearanceMode.allCases) { option in
              Text(option.title).tag(option)
            }
          }
          .pickerStyle(.segmented)
          .frame(maxWidth: 320)
          .padding(.top, 16)

          ChatProfileAvatarPosterPreview(
            mode: mode,
            displayText: mode == .banner ? profileName : avatarDisplayText,
            selection: draft,
            avatarImage: hasProfileImage ? avatarImage : nil
          )
          .frame(maxWidth: .infinity)
          .padding(.top, 10)

          customizeButton

          if mode == .poster {
            posterPhotoSection
          } else if mode == .banner {
            bannerStylePicker
          } else {
            emojiSection
            memojiSection
            monogramSection
          }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 44)
      }
    }
    .navigationBarBackButtonHidden(true)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button {
          dismiss()
        } label: {
          Image(systemName: "xmark")
            .font(.system(size: 18, weight: .semibold))
        }
      }

      ToolbarItem(placement: .topBarTrailing) {
        Button {
          onSave(draft)
          dismiss()
        } label: {
          Image(systemName: "checkmark")
            .font(.system(size: 20, weight: .semibold))
        }
      }
    }
    .toolbarBackground(.hidden, for: .navigationBar)
    .task(id: normalizedAvatarUri ?? "") {
      await loadAvatarImage()
    }
    .task(id: selectedPhotoItem) {
      await loadSelectedPosterPhoto()
    }
    .sheet(isPresented: $isCustomizerPresented) {
      ChatProfileAppearanceGradientSheet(
        mode: mode,
        displayText: mode == .banner ? profileName : avatarDisplayText,
        selection: $draft,
        onChoose: { selection in
          onSave(selection)
        }
      )
      .presentationDetents(mode == .poster ? Set([.large]) : Set([.medium, .large]))
      .presentationDragIndicator(.visible)
    }
    .fullScreenCover(item: $pendingCropImage) { wrapper in
      ChatProfileImageCropper(image: wrapper.image) { cropped in
        var nextDraft = draft
        if let cropped, let jpeg = cropped.jpegData(compressionQuality: 0.84) {
          nextDraft.posterImageData = jpeg
        }
        draft = nextDraft
        onSave(nextDraft)
        mode = .poster
        pendingCropImage = nil
      } onCancel: {
        pendingCropImage = nil
      }
    }
  }

  private var customizeButton: some View {
    Button {
      isCustomizerPresented = true
    } label: {
      Text("Customize")
        .font(.system(size: 20, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 30)
        .frame(height: 58)
        .background(
          Capsule(style: .continuous)
            .fill(Color.black.opacity(0.28))
        )
        .overlay(
          Capsule(style: .continuous)
            .stroke(Color.white.opacity(0.13), lineWidth: 1)
        )
    }
    .buttonStyle(.plain)
  }

  private var bannerStylePicker: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Style")
        .font(.system(size: 20, weight: .bold))
        .foregroundStyle(.white)

      Picker("", selection: bannerStyleBinding) {
        ForEach(ChatProfileBannerStyle.allCases) { style in
          Text(style.title).tag(style)
        }
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: 240)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var bannerStyleBinding: Binding<ChatProfileBannerStyle> {
    Binding {
      ChatProfileBannerStyle.style(id: draft.bannerStyleID)
    } set: { value in
      var nextDraft = draft
      nextDraft.bannerStyleID = value.rawValue
      draft = nextDraft
      onSave(nextDraft)
    }
  }

  private var posterPhotoSection: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Photos")
        .font(.system(size: 24, weight: .bold))
        .foregroundStyle(.white)

      HStack(spacing: 18) {
        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
          ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
              .fill(Color.black.opacity(0.24))

            Image(systemName: "photo.on.rectangle.angled")
              .font(.system(size: 30, weight: .semibold))
              .foregroundStyle(.white)
          }
          .frame(width: 104, height: 118)
        }
        .buttonStyle(.plain)

        VStack(alignment: .leading, spacing: 6) {
          Text("Choose a Photo")
            .font(.system(size: 24, weight: .bold))
          Text("Poster")
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(.white.opacity(0.74))
        }
        .foregroundStyle(.white)

        Spacer(minLength: 0)
      }

      if draft.posterImageData != nil {
        Button(role: .destructive) {
          var nextDraft = draft
          nextDraft.posterImageData = nil
          draft = nextDraft
          onSave(nextDraft)
        } label: {
          Label("Remove Photo", systemImage: "minus.circle")
        }
        .buttonStyle(.bordered)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var emojiSection: some View {
    ChatProfileHorizontalChoiceSection(title: "Emoji") {
      ForEach(["😀", "😎", "✨", "🔥", "💫", "🌙"], id: \.self) { emoji in
        Button {
          var nextDraft = draft
          nextDraft.avatarGlyph = emoji
          draft = nextDraft
          onSave(nextDraft)
        } label: {
          ChatProfileEmojiTile(text: emoji, colors: avatarTileColors)
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var memojiSection: some View {
    ChatProfileHorizontalChoiceSection(title: "Memoji") {
      ForEach(["🙂", "🤖", "👾", "🧑‍💻"], id: \.self) { emoji in
        Button {
          var nextDraft = draft
          nextDraft.avatarGlyph = emoji
          draft = nextDraft
          onSave(nextDraft)
        } label: {
          ChatProfileEmojiTile(text: emoji, colors: avatarTileColors, roundedRectangle: true)
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var monogramSection: some View {
    ChatProfileHorizontalChoiceSection(title: "Monogram") {
      ForEach(ChatProfileAvatarFontStyle.allCases) { style in
        Button {
          var nextDraft = draft
          nextDraft.avatarGlyph = nil
          nextDraft.avatarFontStyleID = style.rawValue
          draft = nextDraft
          onSave(nextDraft)
        } label: {
          ZStack {
            LinearGradient(
              colors: [Color(uiColor: avatarTileColors.0), Color(uiColor: avatarTileColors.1)],
              startPoint: .top,
              endPoint: .bottom
            )
            ChatProfileAvatarGlyph(text: initial, fontStyleID: style.rawValue, size: 44)
          }
          .frame(width: 96, height: 96)
          .clipShape(Circle())
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var avatarTileColors: (UIColor, UIColor) {
    ChatProfileAppearancePalette.colors(for: draft, mode: .avatar)
  }

  private var normalizedAvatarUri: String? {
    let value = avatarUri?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }

  @MainActor
  private func loadAvatarImage() async {
    let normalized = normalizedAvatarUri
    if avatarImageUri != normalized {
      avatarImageUri = normalized
      avatarImage = normalized.flatMap { ChatAvatarImageStore.cached(for: $0) }
    }
    guard let normalized else {
      avatarImage = nil
      return
    }
    if let cached = ChatAvatarImageStore.cached(for: normalized) {
      avatarImage = cached
      return
    }
    let loaded = await ChatAvatarImageStore.load(from: normalized)
    guard !Task.isCancelled, avatarImageUri == normalized else { return }
    avatarImage = loaded
  }

  @MainActor
  private func loadSelectedPosterPhoto() async {
    guard let selectedPhotoItem else { return }
    guard let data = try? await selectedPhotoItem.loadTransferable(type: Data.self) else { return }
    if let image = UIImage(data: data) {
      pendingCropImage = UIImageWrapper(image: image)
    }
  }
}

private struct ChatProfileHorizontalChoiceSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(title)
        .font(.system(size: 24, weight: .bold))
        .foregroundStyle(.white)

      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 18) {
          content
        }
        .padding(.vertical, 2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct ChatProfileEmojiTile: View {
  let text: String
  let colors: (UIColor, UIColor)
  var roundedRectangle: Bool = false

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color(uiColor: colors.0), Color(uiColor: colors.1)],
        startPoint: .top,
        endPoint: .bottom
      )
      Text(text)
        .font(.system(size: 44))
    }
    .frame(width: 96, height: 96)
    .clipShape(
      RoundedRectangle(cornerRadius: roundedRectangle ? 24 : 48, style: .continuous)
    )
  }
}

private struct ChatProfileAppearanceGradientSheet: View {
  let mode: ChatProfileAppearanceMode
  let displayText: String
  @Binding var selection: ChatProfileAppearanceSelection
  let onChoose: (ChatProfileAppearanceSelection) -> Void

  @Environment(\.dismiss) private var dismiss

  private var backgroundColors: (UIColor, UIColor) {
    ChatProfileAppearancePalette.colors(for: selection, mode: .poster)
  }

  private var isSolidBanner: Bool {
    mode == .banner && ChatProfileBannerStyle.style(id: selection.bannerStyleID) == .solid
  }

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color(uiColor: backgroundColors.0), Color(uiColor: backgroundColors.1)],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      ScrollView(.vertical, showsIndicators: false) {
        VStack(spacing: 26) {
          HStack {
            Button("Cancel") {
              dismiss()
            }
            .font(.system(size: 20, weight: .medium))
            .padding(.horizontal, 22)
            .frame(height: 52)
            .background(Capsule(style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 1))

            Spacer()

            Button("Choose") {
              onChoose(selection)
              dismiss()
            }
            .font(.system(size: 20, weight: .medium))
            .padding(.horizontal, 22)
            .frame(height: 52)
            .background(Capsule(style: .continuous).stroke(Color.white.opacity(0.25), lineWidth: 1))
          }
          .foregroundStyle(.white)
          .padding(.top, 12)

          ChatProfileAvatarPosterPreview(
            mode: mode,
            displayText: displayText,
            selection: selection,
            avatarImage: nil
          )
          .frame(maxWidth: .infinity)

          VStack(alignment: .leading, spacing: 20) {
            Text("Suggestions")
              .font(.system(size: 24, weight: .bold))
              .foregroundStyle(.white)

            ChatProfilePaletteGrid(mode: mode, selection: $selection)

            VStack(spacing: 12) {
              if isSolidBanner {
                ColorPicker("Color", selection: solidBannerColorBinding, supportsOpacity: false)
              } else {
                ColorPicker("Start", selection: customStartBinding, supportsOpacity: false)
                ColorPicker("End", selection: customEndBinding, supportsOpacity: false)
              }
            }
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(
              RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.18))
            )
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 34)
      }
    }
  }

  private var solidBannerColorBinding: Binding<Color> {
    Binding {
      let colors = ChatProfileAppearancePalette.colors(for: selection, mode: .banner)
      return Color(uiColor: colors.0)
    } set: { value in
      let hex = UIColor(value).chatProfileHexString
      selection.bannerCustomStartHex = hex
      selection.bannerCustomEndHex = hex
    }
  }

  private var customStartBinding: Binding<Color> {
    Binding {
      let colors = ChatProfileAppearancePalette.colors(for: selection, mode: mode)
      return Color(uiColor: colors.0)
    } set: { value in
      let hex = UIColor(value).chatProfileHexString
      switch mode {
      case .avatar:
        selection.avatarCustomStartHex = hex
      case .poster:
        selection.posterCustomStartHex = hex
        selection.posterImageData = nil
      case .banner:
        selection.bannerCustomStartHex = hex
      }
    }
  }

  private var customEndBinding: Binding<Color> {
    Binding {
      let colors = ChatProfileAppearancePalette.colors(for: selection, mode: mode)
      return Color(uiColor: colors.1)
    } set: { value in
      let hex = UIColor(value).chatProfileHexString
      switch mode {
      case .avatar:
        selection.avatarCustomEndHex = hex
      case .poster:
        selection.posterCustomEndHex = hex
        selection.posterImageData = nil
      case .banner:
        selection.bannerCustomEndHex = hex
      }
    }
  }
}

private struct ChatProfileAvatarPosterPreview: View {
  let mode: ChatProfileAppearanceMode
  let displayText: String
  let selection: ChatProfileAppearanceSelection
  let avatarImage: UIImage?

  private var avatarColors: (UIColor, UIColor) {
    ChatProfileAppearancePalette.colors(for: selection, mode: .avatar)
  }

  private var posterColors: (UIColor, UIColor) {
    ChatProfileAppearancePalette.colors(for: selection, mode: .poster)
  }

  private var bannerColors: (UIColor, UIColor) {
    let colors = ChatProfileAppearancePalette.colors(for: selection, mode: .banner)
    switch ChatProfileBannerStyle.style(id: selection.bannerStyleID) {
    case .solid:
      return (colors.0, colors.0)
    case .gradient:
      return colors
    }
  }

  private var posterImage: UIImage? {
    guard let data = selection.posterImageData else { return nil }
    return UIImage(data: data)
  }

  var body: some View {
    Group {
      if mode == .banner {
        bannerMessageCard
      } else {
        avatarOrPosterPreview
      }
    }
    .animation(.spring(response: 0.42, dampingFraction: 0.86), value: mode)
    .animation(.easeInOut(duration: 0.2), value: selection.bannerStyleID)
  }

  private var avatarOrPosterPreview: some View {
    let isPoster = mode == .poster
    return ZStack {
      previewBackground(isPoster: isPoster)

      if isPoster {
        avatarCircle(size: 92)
      } else {
        avatarCircle(size: 252)
      }
    }
    .frame(width: isPoster ? 188 : 252, height: isPoster ? 332 : 252)
    .clipShape(RoundedRectangle(cornerRadius: isPoster ? 42 : 126, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: isPoster ? 42 : 126, style: .continuous)
        .stroke(Color.white.opacity(0.16), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.20), radius: 12, x: 0, y: 6)
  }

  private var bannerMessageCard: some View {
    let colors = bannerColors
    let senderName: String = {
      let trimmed = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? "Sender" : trimmed
    }()

    // Untinted outer bubble; palette applies only to the compact quoted-reply panel.
    return VStack(alignment: .leading, spacing: 0) {
      Text(senderName)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white.opacity(0.88))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)

      // Quoted reply preview: curved right-pointing arrow + referenced name + body.
      HStack(alignment: .top, spacing: 0) {
        BannerReplyCurvedArrow()
          .fill(Color(uiColor: colors.0).opacity(0.95), style: FillStyle(eoFill: true))
          .frame(width: 18, height: 18)
          .rotationEffect(.degrees(180))

        VStack(alignment: .leading, spacing: 1) {
          Text(senderName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(uiColor: colors.0).opacity(0.96))
            .lineLimit(1)
          Text("Are you free later?")
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.white.opacity(0.62))
            .lineLimit(1)
        }
      }
      .padding(.leading, 2)
      .padding(.trailing, 5)
      .padding(.top, 2)
      .padding(.bottom, 3)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        LinearGradient(
          colors: [
            Color(uiColor: colors.0).opacity(0.22),
            Color(uiColor: colors.1).opacity(0.16),
          ],
          startPoint: .leading,
          endPoint: .trailing
        )
      )
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .padding(.horizontal, 10)

      Text("Yeah — around 6 works for me.")
        .font(.system(size: 15, weight: .regular))
        .foregroundStyle(.white.opacity(0.96))
        .lineLimit(2)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }
    .frame(maxWidth: 280, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color.black.opacity(0.58))
    )
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(Color.white.opacity(0.14), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 5)
  }

  @ViewBuilder
  private func previewBackground(isPoster: Bool) -> some View {
    if isPoster, let posterImage {
      Image(uiImage: posterImage)
        .resizable()
        .scaledToFill()
    } else {
      LinearGradient(
        colors: [
          Color(uiColor: isPoster ? posterColors.0 : avatarColors.0),
          Color(uiColor: isPoster ? posterColors.1 : avatarColors.1),
        ],
        startPoint: .top,
        endPoint: .bottom
      )
    }
  }

  private func avatarCircle(size: CGFloat) -> some View {
    ZStack {
      LinearGradient(
        colors: [Color(uiColor: avatarColors.0), Color(uiColor: avatarColors.1)],
        startPoint: .top,
        endPoint: .bottom
      )

      if let avatarImage {
        Image(uiImage: avatarImage)
          .resizable()
          .scaledToFill()
      } else {
        ChatProfileAvatarGlyph(
          text: displayText,
          fontStyleID: selection.avatarFontStyleID,
          size: size * 0.46
        )
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
    .shadow(color: Color.black.opacity(0.18), radius: size > 120 ? 10 : 4, x: 0, y: 4)
  }
}

/// Exact user-supplied reply SVG (24×24); the call site rotates it to point right/up.
private struct BannerReplyCurvedArrow: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: svgPoint(10.0303, 6.46967, in: rect))
    path.addCurve(
      to: svgPoint(10.0303, 7.53033, in: rect),
      control1: svgPoint(10.3232, 6.76256, in: rect),
      control2: svgPoint(10.3232, 7.23744, in: rect)
    )
    path.addLine(to: svgPoint(6.31066, 11.25, in: rect))
    path.addLine(to: svgPoint(14.5, 11.25, in: rect))
    path.addCurve(
      to: svgPoint(18.0632, 12.3913, in: rect),
      control1: svgPoint(15.4534, 11.25, in: rect),
      control2: svgPoint(16.8667, 11.5298, in: rect)
    )
    path.addCurve(
      to: svgPoint(20.25, 17, in: rect),
      control1: svgPoint(19.298, 13.2804, in: rect),
      control2: svgPoint(20.25, 14.7556, in: rect)
    )
    path.addCurve(
      to: svgPoint(19.5, 17.75, in: rect),
      control1: svgPoint(20.25, 17.4142, in: rect),
      control2: svgPoint(19.9142, 17.75, in: rect)
    )
    path.addCurve(
      to: svgPoint(18.75, 17, in: rect),
      control1: svgPoint(19.0858, 17.75, in: rect),
      control2: svgPoint(18.75, 17.4142, in: rect)
    )
    path.addCurve(
      to: svgPoint(17.1868, 13.6087, in: rect),
      control1: svgPoint(18.75, 15.2444, in: rect),
      control2: svgPoint(18.0353, 14.2196, in: rect)
    )
    path.addCurve(
      to: svgPoint(14.5, 12.75, in: rect),
      control1: svgPoint(16.3, 12.9702, in: rect),
      control2: svgPoint(15.2133, 12.75, in: rect)
    )
    path.addLine(to: svgPoint(6.31066, 12.75, in: rect))
    path.addLine(to: svgPoint(10.0303, 16.4697, in: rect))
    path.addCurve(
      to: svgPoint(10.0303, 17.5303, in: rect),
      control1: svgPoint(10.3232, 16.7626, in: rect),
      control2: svgPoint(10.3232, 17.2374, in: rect)
    )
    path.addCurve(
      to: svgPoint(8.96967, 17.5303, in: rect),
      control1: svgPoint(9.73744, 17.8232, in: rect),
      control2: svgPoint(9.26256, 17.8232, in: rect)
    )
    path.addLine(to: svgPoint(3.96967, 12.5303, in: rect))
    path.addCurve(
      to: svgPoint(3.96967, 11.4697, in: rect),
      control1: svgPoint(3.67678, 12.2374, in: rect),
      control2: svgPoint(3.67678, 11.7626, in: rect)
    )
    path.addLine(to: svgPoint(8.96967, 6.46967, in: rect))
    path.addCurve(
      to: svgPoint(10.0303, 6.46967, in: rect),
      control1: svgPoint(9.26256, 6.17678, in: rect),
      control2: svgPoint(9.73744, 6.17678, in: rect)
    )
    path.closeSubpath()
    return path
  }

  private func svgPoint(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + (x / 24) * rect.width, y: rect.minY + (y / 24) * rect.height)
  }
}

private struct ChatProfilePaletteGrid: View {
  let mode: ChatProfileAppearanceMode
  @Binding var selection: ChatProfileAppearanceSelection

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 22), count: 5)

  var body: some View {
    LazyVGrid(columns: columns, spacing: 24) {
      ForEach(ChatProfileAppearancePalette.all) { palette in
        Button {
          switch mode {
          case .avatar:
            selection.avatarPaletteID = palette.id
            selection.avatarCustomStartHex = nil
            selection.avatarCustomEndHex = nil
          case .poster:
            selection.posterPaletteID = palette.id
            selection.posterCustomStartHex = nil
            selection.posterCustomEndHex = nil
            selection.posterImageData = nil
          case .banner:
            selection.bannerPaletteID = palette.id
            selection.bannerCustomStartHex = nil
            selection.bannerCustomEndHex = nil
          }
        } label: {
          Circle()
            .fill(
              LinearGradient(
                colors: [
                  Color(uiColor: ChatProfileAppearancePalette.uiColor(hex: palette.topHex)),
                  Color(uiColor: ChatProfileAppearancePalette.uiColor(hex: palette.bottomHex)),
                ],
                startPoint: .top,
                endPoint: .bottom
              )
            )
            .frame(width: 44, height: 44)
            .overlay {
              if isSelected(palette) {
                Circle()
                  .stroke(Color.white, lineWidth: 3)
                  .padding(-4)
              }
            }
        }
        .buttonStyle(.plain)
      }
    }
  }

  private func isSelected(_ palette: ChatProfileAppearancePalette) -> Bool {
    switch mode {
    case .avatar:
      return selection.avatarPaletteID == palette.id
        && selection.avatarCustomStartHex == nil
        && selection.avatarCustomEndHex == nil
    case .poster:
      return selection.posterPaletteID == palette.id
        && selection.posterCustomStartHex == nil
        && selection.posterCustomEndHex == nil
    case .banner:
      if selection.bannerCustomStartHex != nil || selection.bannerCustomEndHex != nil {
        return false
      }
      if let bannerID = selection.bannerPaletteID {
        return bannerID == palette.id
      }
      // Still inheriting avatar until an explicit banner palette is chosen.
      return selection.avatarPaletteID == palette.id
        && selection.avatarCustomStartHex == nil
        && selection.avatarCustomEndHex == nil
    }
  }
}

private extension View {
  @ViewBuilder
  func chatProfileBounceBehavior() -> some View {
    if #available(iOS 16.4, *) {
      // `.always` (not `.basedOnSize`) so the header's overscroll stretch and the
      // sticky name/action-row collapse both work even when the profile body is
      // short enough to fit on one screen without scrolling.
      self.scrollBounceBehavior(.always)
    } else {
      self
    }
  }
}

private struct ChatProfileSwiftUIMaterialBackground: UIViewRepresentable {
  let style: UIBlurEffect.Style

  func makeUIView(context: Context) -> UIVisualEffectView {
    let view = UIVisualEffectView(effect: resolvedEffect)
    view.backgroundColor = .clear
    view.isUserInteractionEnabled = false
    return view
  }

  func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
    uiView.effect = resolvedEffect
  }

  private var resolvedEffect: UIVisualEffect {
    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect(style: .regular)
      effect.isInteractive = false
      return effect
    }
    return UIBlurEffect(style: style)
  }
}


private struct ChatProfileSwiftUISection<Content: View>: View {
  @Environment(\.colorScheme) private var colorScheme

  let fill: Color
  @ViewBuilder let content: Content

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
    VStack(spacing: 0) {
      content
    }
    .background {
      shape.fill(.ultraThinMaterial)
    }
    .clipShape(shape)
  }
}

private struct ChatProfileSwiftUIRow: View {
  let title: String
  var subtitle: String = ""
  /// Value on the trailing edge (e.g. model name) — preferred over subtitle under title.
  var trailingText: String? = nil
  var leading: AnyView? = nil
  var trailingSystemImage: String?
  var showsChevron: Bool = false
  var titleColor: Color = .primary
  let separatorColor: Color
  let isLast: Bool

  var body: some View {
    HStack(spacing: 14) {
      if let leading {
        leading
      }

      VStack(alignment: .leading, spacing: subtitle.isEmpty ? 0 : 4) {
        Text(title)
          .font(.system(size: 17, weight: .regular))
          .foregroundStyle(titleColor)
          .lineLimit(1)
          .minimumScaleFactor(0.76)

        if !subtitle.isEmpty, trailingText == nil {
          Text(subtitle)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Spacer(minLength: 12)

      if let trailingText, !trailingText.isEmpty {
        Text(trailingText)
          .font(.system(size: 15, weight: .regular))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.78)
          .multilineTextAlignment(.trailing)
      }

      if let trailingSystemImage {
        Image(systemName: trailingSystemImage)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.secondary.opacity(0.85))
      }

      if showsChevron {
        Image(systemName: "chevron.right")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(Color.secondary.opacity(0.8))
      }
    }
    .padding(.horizontal, 22)
    .padding(.vertical, (subtitle.isEmpty && trailingText == nil) ? 14 : 13)
    .frame(maxWidth: .infinity, minHeight: (subtitle.isEmpty && trailingText == nil) ? 52 : 58, alignment: .center)
    .contentShape(Rectangle())
    .overlay(alignment: .bottom) {
      if !isLast {
        Rectangle()
          .fill(separatorColor)
          .frame(height: 1 / UIScreen.main.scale)
          .padding(.leading, 22)
      }
    }
  }
}

private struct ChatProfileSwiftUIRowButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background(configuration.isPressed ? Color.primary.opacity(0.07) : Color.clear)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

/// Glass chip: continuous circle→pill via shared expand p.
/// Tree is always the same (label always mounted) — no if-branch remounts.
/// Does NOT force light theme (only image blur scrim does).
private struct ChatProfileSwiftUIActionButton: View {
  let title: String
  let systemImage: String
  let fill: Color
  var ink: Color = .white
  var isDark: Bool = true
  var chipWidth: CGFloat = 56
  var chipHeight: CGFloat = 70
  var contentAlpha: CGFloat = 1
  let action: () -> Void

  @State private var iconAnimating = false

  /// Pill, never a circle — the row keeps one shape through the whole morph.
  private let corner: CGFloat = 14

  private var iconKickAngle: Double {
    if systemImage.hasPrefix("bell") { return -14 }
    if systemImage == "phone" { return -12 }
    if systemImage == "magnifyingglass" { return 9 }
    return 0
  }

  var body: some View {
    Button {
      withAnimation(.spring(response: 0.22, dampingFraction: 0.46)) {
        iconAnimating = true
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.58)) {
          iconAnimating = false
        }
      }
      action()
    } label: {
      VStack(spacing: 1) {
        Image(systemName: systemImage)
          .font(.system(size: 18, weight: .regular))
          .rotationEffect(.degrees(iconAnimating ? iconKickAngle : 0))
          .scaleEffect(iconAnimating ? 1.16 : 1)
          .offset(x: iconAnimating && systemImage == "video" ? 2 : 0)
        Text(title)
          .font(.system(size: 10, weight: .medium))
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }
      .foregroundStyle(ink)
      .opacity(Double(contentAlpha))
      .frame(width: chipWidth, height: chipHeight)
      .background {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        shape
          .fill(.ultraThinMaterial)
          .environment(\.colorScheme, isDark ? .dark : .light)
          .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.6))
      }
      .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
    .buttonStyle(.plain)
    .frame(width: chipWidth, height: chipHeight)
  }
}

private struct ChatProfileSwiftUIExpandedContentView: View {
  let title: String
  let items: [ChatProfileSwiftUIContentItem]
  let fill: Color
  let separatorColor: Color
  let onContentPressed: ([String: Any]) -> Void
  var trailingToolbarSystemImage: String? = nil
  var onTrailingToolbarPressed: (() -> Void)? = nil
  var tabs: [ChatProfileSwiftUITabSummary] = []
  var tabItems: [ChatProfileTab: [ChatProfileSwiftUIContentItem]] = [:]
  var initialTab: ChatProfileTab? = nil
  var embedded = false
  /// Fires after a tab switch so the host can bring the strip up near the header.
  var onTabPressed: (() -> Void)? = nil

  @State private var selectedTab: ChatProfileTab?

  private var activeTab: ChatProfileTab {
    selectedTab ?? initialTab ?? tabs.first?.tab ?? .media
  }

  private var activeItems: [ChatProfileSwiftUIContentItem] {
    tabItems[activeTab] ?? []
  }

  @ViewBuilder
  var body: some View {
    if tabs.isEmpty {
      legacyList
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(false)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
          if let trailingToolbarSystemImage, let onTrailingToolbarPressed {
            ToolbarItem(placement: .topBarTrailing) {
              Button(action: onTrailingToolbarPressed) {
                Image(systemName: trailingToolbarSystemImage)
              }
            }
          }
        }
    } else if embedded {
      sharedBody
    } else {
      ScrollView(.vertical, showsIndicators: false) {
        sharedBody
          .padding(.horizontal, 18)
          .padding(.vertical, 14)
      }
      .background(Color(uiColor: ChatListAppearance.current.wallpaperBase).ignoresSafeArea())
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.hidden, for: .navigationBar)
    }
  }

  private var legacyList: some View {
    List {
      Section {
        if items.isEmpty {
          Text("No items yet")
            .foregroundStyle(.secondary)
        } else {
          ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            Button {
              onContentPressed(item.payload)
            } label: {
              genericRow(item: item, index: index, count: items.count)
            }
            .buttonStyle(.plain)
            .listRowBackground(fill)
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollContentBackground(.hidden)
    .background(Color(uiColor: ChatListAppearance.current.wallpaperBase))
  }

  private var sharedBody: some View {
    VStack(spacing: 14) {
      tabStrip
      sharedItems
    }
  }

  /// Sized by its chips — only a strip too wide for the row falls back to scrolling.
  private var tabStrip: some View {
    HStack(spacing: 0) {
      Spacer(minLength: 0)
      ViewThatFits(in: .horizontal) {
        tabChips
        ScrollView(.horizontal, showsIndicators: false) { tabChips }
      }
      .background {
        if #available(iOS 26.0, *) {
          Capsule(style: .continuous)
            .fill(.clear)
            .glassEffect(.regular.interactive(true), in: .capsule)
        } else {
          Capsule(style: .continuous)
            .fill(.bar)
        }
      }
      Spacer(minLength: 0)
    }
  }

  private var tabChips: some View {
    HStack(spacing: 4) {
      ForEach(tabs) { summary in
        Button {
          withAnimation(.easeInOut(duration: 0.18)) {
            selectedTab = summary.tab
          }
          onTabPressed?()
        } label: {
          Text(summary.title)
            .font(.system(size: 15, weight: activeTab == summary.tab ? .semibold : .medium))
            .foregroundStyle(activeTab == summary.tab ? Color.primary : Color.secondary)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background {
              if activeTab == summary.tab {
                Capsule().fill(Color.primary.opacity(0.13))
              }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(3)
  }

  @ViewBuilder
  private var sharedItems: some View {
    if activeItems.isEmpty {
      Text("No shared content yet")
        .font(.system(size: 15, weight: .regular))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
    } else {
      switch activeTab {
      case .media, .gifs:
        mediaGrid
      case .music:
        musicList
      case .links:
        linksList
      case .voice, .files, .pinned:
        genericList
      }
    }
  }

  private var mediaGrid: some View {
    let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)
    return LazyVGrid(columns: columns, spacing: 3) {
      ForEach(activeItems) { item in
        MediaThumbnail(
          urlString: item.mediaURL,
          isVideo: item.isVideo,
          thumbnailBase64: item.thumbnailBase64,
          mediaKey: item.mediaKey,
          onPressed: { sourceView in
            var payload = item.payload
            payload["sourceView"] = sourceView
            onContentPressed(payload)
          }
        )
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .bottomTrailing) {
          if item.isVideo {
            Image(systemName: "play.fill")
              .font(.system(size: 12, weight: .bold))
              .foregroundStyle(.white)
              .padding(7)
              .background(.black.opacity(0.58), in: Circle())
              .padding(7)
          }
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  private var musicList: some View {
    VStack(spacing: 0) {
      ForEach(Array(activeItems.enumerated()), id: \.element.id) { index, item in
        Button {
          onContentPressed(item.payload)
        } label: {
          HStack(spacing: 12) {
            ZStack {
              MediaThumbnail(
                urlString: item.coverURL,
                isVideo: false,
                thumbnailBase64: item.thumbnailBase64
              )
              Image(systemName: "play.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .shadow(radius: 3)
            }
            .frame(width: 54, height: 54)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
              Text(item.title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
              Text(item.subtitle.isEmpty ? (item.artist ?? "Music") : item.subtitle)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
          }
          .padding(.horizontal, 14)
          .frame(minHeight: 72)
          .overlay(alignment: .bottom) {
            if index != activeItems.count - 1 {
              Rectangle()
                .fill(separatorColor)
                .frame(height: 1 / UIScreen.main.scale)
                .padding(.leading, 80)
            }
          }
        }
        .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
      }
    }
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
  }

  private var linksList: some View {
    VStack(spacing: 12) {
      ForEach(activeItems) { item in
        Button {
          onContentPressed(item.payload)
        } label: {
          VStack(alignment: .leading, spacing: 8) {
            LinkPreview(urlString: item.mediaURL ?? item.title)
              .frame(height: 74)
            if !item.detail.isEmpty, item.detail != item.title {
              Text(item.detail)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
            }
          }
          .padding(10)
          .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
      }
    }
  }

  private var genericList: some View {
    VStack(spacing: 0) {
      ForEach(Array(activeItems.enumerated()), id: \.element.id) { index, item in
        Button {
          onContentPressed(item.payload)
        } label: {
          genericRow(item: item, index: index, count: activeItems.count)
            .padding(.horizontal, 14)
        }
        .buttonStyle(ChatProfileSwiftUIRowButtonStyle())
      }
    }
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
  }

  private func genericRow(
    item: ChatProfileSwiftUIContentItem,
    index: Int,
    count: Int
  ) -> some View {
    HStack(spacing: 14) {
      Image(systemName: item.systemImage)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 28)
      VStack(alignment: .leading, spacing: 4) {
        Text(item.title)
          .font(.system(size: 16, weight: .regular))
          .foregroundStyle(.primary)
          .lineLimit(1)
        if !item.subtitle.isEmpty {
          Text(item.subtitle)
            .font(.system(size: 13, weight: .regular))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer()
    }
    .padding(.vertical, 10)
    .overlay(alignment: .bottom) {
      if index != count - 1 {
        Rectangle()
          .fill(separatorColor)
          .frame(height: 1 / UIScreen.main.scale)
          .padding(.leading, 42)
      }
    }
  }

  private struct MediaThumbnail: UIViewRepresentable {
    let urlString: String?
    let isVideo: Bool
    let thumbnailBase64: String?
    var mediaKey: String? = nil
    var onPressed: ((UIView) -> Void)? = nil

    final class Coordinator: NSObject {
      var onPressed: ((UIView) -> Void)?

      init(onPressed: ((UIView) -> Void)?) {
        self.onPressed = onPressed
      }

      @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let view = recognizer.view as? ChatMainProfileMediaCellNode else { return }
        onPressed?(view.mediaTransitionSourceView)
      }
    }

    func makeCoordinator() -> Coordinator {
      Coordinator(onPressed: onPressed)
    }

    func makeUIView(context: Context) -> ChatMainProfileMediaCellNode {
      let view = ChatMainProfileMediaCellNode()
      if onPressed != nil {
        view.addGestureRecognizer(
          UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        )
      }
      return view
    }

    func updateUIView(_ view: ChatMainProfileMediaCellNode, context: Context) {
      context.coordinator.onPressed = onPressed
      view.configure(
        urlString: urlString,
        isVideo: isVideo,
        thumbnailBase64: thumbnailBase64,
        mediaKey: mediaKey
      )
      view.applyTheme(
        placeholderTintColor: ChatListAppearance.current.timeColorThem,
        placeholderBackgroundColor: ChatListAppearance.current.textColorThem.withAlphaComponent(0.06)
      )
    }
  }

  private struct LinkPreview: UIViewRepresentable {
    let urlString: String

    func makeUIView(context: Context) -> BubbleLinkPreviewView {
      let view = BubbleLinkPreviewView()
      view.isUserInteractionEnabled = false
      return view
    }

    func updateUIView(_ view: BubbleLinkPreviewView, context: Context) {
      guard let url = URL(string: urlString) else {
        view.reset()
        return
      }
      view.configure(url: url, appearance: .current, isMe: false)
    }
  }
}

private final class ChatProfileListRowCell: UITableViewCell {
  static let reuseIdentifier = "ChatProfileListRowCell"

  let rowNode = ChatMainProfileListRowNode()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    contentView.backgroundColor = .clear
    rowNode.isUserInteractionEnabled = false
    contentView.addSubview(rowNode)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    rowNode.frame = contentView.bounds
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    contentConfiguration = nil
    rowNode.isHidden = false
  }

  override func setHighlighted(_ highlighted: Bool, animated: Bool) {
    super.setHighlighted(highlighted, animated: animated)
    rowNode.isHighlighted = highlighted
  }

  override func setSelected(_ selected: Bool, animated: Bool) {
    super.setSelected(selected, animated: animated)
    rowNode.isHighlighted = selected
  }
}

private final class ChatProfileTabStripView: UIView {
  static let preferredHeight: CGFloat = 34.0

  var onSelect: ((ChatProfileTab) -> Void)?

  private let chromeView = UIVisualEffectView(effect: nil)
  private let chromeOverlayView = UIView()
  private let scrollView = UIScrollView()
  private let stackView = UIStackView()
  private let selectionView = UIView()
  private var currentTabs: [ChatProfileTab] = []
  private var activeTab: ChatProfileTab = .media
  private var buttonsByTab: [ChatProfileTab: UIButton] = [:]
  private var isDark = false
  private let selectionFeedback = UISelectionFeedbackGenerator()

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setup()
  }

  private func setup() {
    backgroundColor = .clear
    clipsToBounds = false

    // Glass effect as a pure background — no content inside contentView so
    // UIGlassEffect renders correctly without being blocked by nested views.
    chromeView.translatesAutoresizingMaskIntoConstraints = false
    chromeView.clipsToBounds = true
    chromeView.layer.cornerCurve = .continuous
    chromeView.isUserInteractionEnabled = false
    addSubview(chromeView)

    // Overlay and scroll view are siblings of chromeView, not children of contentView.
    chromeOverlayView.translatesAutoresizingMaskIntoConstraints = false
    chromeOverlayView.isUserInteractionEnabled = false
    addSubview(chromeOverlayView)

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.backgroundColor = .clear
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.alwaysBounceHorizontal = false
    scrollView.delaysContentTouches = false
    scrollView.canCancelContentTouches = true
    addSubview(scrollView)

    selectionView.isUserInteractionEnabled = false
    selectionView.layer.cornerCurve = .continuous
    scrollView.addSubview(selectionView)

    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .horizontal
    stackView.alignment = .fill
    stackView.distribution = .fill
    stackView.spacing = 6.0
    scrollView.addSubview(stackView)

    NSLayoutConstraint.activate([
      chromeView.leadingAnchor.constraint(equalTo: leadingAnchor),
      chromeView.trailingAnchor.constraint(equalTo: trailingAnchor),
      chromeView.topAnchor.constraint(equalTo: topAnchor),
      chromeView.bottomAnchor.constraint(equalTo: bottomAnchor),

      chromeOverlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
      chromeOverlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
      chromeOverlayView.topAnchor.constraint(equalTo: topAnchor),
      chromeOverlayView.bottomAnchor.constraint(equalTo: bottomAnchor),

      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

      stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
    ])

    selectionFeedback.prepare()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    chromeView.layer.cornerRadius = bounds.height * 0.5
    updateSelectionFrame(animated: false)
  }

  func applyTheme(isDark: Bool) {
    self.isDark = isDark
    applyChrome()
  }

  private func applyChrome() {
    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .regular)
      glass.isInteractive = false
      chromeView.effect = glass
    } else {
      let blurStyle: UIBlurEffect.Style =
        isDark ? .systemChromeMaterialDark : .systemChromeMaterialLight
      chromeView.effect = UIBlurEffect(style: blurStyle)
    }

    let primary = isDark ? UIColor(white: 0.95, alpha: 0.96) : UIColor(white: 0.12, alpha: 0.96)
    let secondary = isDark ? UIColor(white: 0.84, alpha: 0.62) : UIColor(white: 0.12, alpha: 0.42)
    if #available(iOS 26.0, *) {
      chromeOverlayView.backgroundColor = .clear
    } else {
      chromeOverlayView.backgroundColor =
        (isDark ? UIColor.black : UIColor.white).withAlphaComponent(isDark ? 0.10 : 0.08)
    }
    selectionView.backgroundColor =
      isDark ? UIColor.white.withAlphaComponent(0.18) : UIColor.black.withAlphaComponent(0.10)

    for (tab, button) in buttonsByTab {
      let selected = tab == activeTab
      button.setTitleColor(selected ? primary : secondary, for: .normal)
      button.alpha = selected ? 1.0 : 0.94
    }
  }

  func configure(
    tabs: [ChatProfileTab],
    activeTab: ChatProfileTab,
    titleProvider: (ChatProfileTab) -> String
  ) {
    let tabsChanged = currentTabs != tabs
    let previousTab = self.activeTab
    self.activeTab = activeTab

    if tabsChanged {
      currentTabs = tabs
      rebuildItems(titleProvider: titleProvider)
    } else {
      updateTitles(titleProvider: titleProvider)
    }

    applyChrome()
    updateSelectionFrame(animated: previousTab != activeTab && !tabsChanged)
    scrollSelectedTabIntoView(animated: previousTab != activeTab)
  }

  private func rebuildItems(titleProvider: (ChatProfileTab) -> String) {
    for arrangedSubview in stackView.arrangedSubviews {
      stackView.removeArrangedSubview(arrangedSubview)
      arrangedSubview.removeFromSuperview()
    }

    buttonsByTab.removeAll()
    selectionView.alpha = 0.0

    for (index, tab) in currentTabs.enumerated() {
      let button = UIButton(type: .system)
      button.translatesAutoresizingMaskIntoConstraints = false
      button.tag = index
      button.contentEdgeInsets = UIEdgeInsets(top: 0.0, left: 10.0, bottom: 0.0, right: 10.0)
      button.titleLabel?.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
      button.titleLabel?.lineBreakMode = .byTruncatingTail
      button.setTitle(titleProvider(tab), for: .normal)
      button.addTarget(self, action: #selector(handleTabButtonPressed(_:)), for: .touchUpInside)
      stackView.addArrangedSubview(button)
      buttonsByTab[tab] = button
    }

    setNeedsLayout()
  }

  private func updateTitles(titleProvider: (ChatProfileTab) -> String) {
    for tab in currentTabs {
      buttonsByTab[tab]?.setTitle(titleProvider(tab), for: .normal)
    }
  }

  private func updateSelectionFrame(animated: Bool) {
    guard let button = buttonsByTab[activeTab] else {
      selectionView.alpha = 0.0
      return
    }

    let targetFrame = button.convert(button.bounds, to: scrollView)
    let applySelection = {
      self.selectionView.frame = targetFrame
      self.selectionView.layer.cornerRadius = targetFrame.height * 0.5
      self.selectionView.alpha = 1.0
    }

    guard animated, window != nil else {
      applySelection()
      return
    }

    UIView.animate(
      withDuration: 0.26,
      delay: 0.0,
      options: [.beginFromCurrentState, .curveEaseInOut, .allowUserInteraction]
    ) {
      applySelection()
    }
  }

  private func scrollSelectedTabIntoView(animated: Bool) {
    guard let button = buttonsByTab[activeTab] else { return }
    let targetFrame = button.convert(button.bounds, to: scrollView).insetBy(dx: -18.0, dy: 0.0)
    scrollView.scrollRectToVisible(targetFrame, animated: animated)
  }

  @objc private func handleTabButtonPressed(_ sender: UIButton) {
    guard currentTabs.indices.contains(sender.tag) else { return }
    let tab = currentTabs[sender.tag]
    guard tab != activeTab else { return }

    selectionFeedback.selectionChanged()
    onSelect?(tab)
  }
}


private final class ChatProfileTabStripCell: UITableViewCell {
  static let reuseIdentifier = "ChatProfileTabStripCell"

  let tabsView = ChatProfileTabStripView()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    contentView.addSubview(tabsView)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    tabsView.frame = contentView.bounds.insetBy(dx: 12.0, dy: 6.0)
  }
}

private final class ChatProfileMediaContentCell: UITableViewCell {
  static let reuseIdentifier = "ChatProfileMediaContentCell"

  private let thumbnailNode = ChatMainProfileMediaCellNode()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    backgroundColor = .clear
    contentView.backgroundColor = .clear

    titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    titleLabel.numberOfLines = 1
    subtitleLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
    subtitleLabel.numberOfLines = 1

    contentView.addSubview(thumbnailNode)
    contentView.addSubview(titleLabel)
    contentView.addSubview(subtitleLabel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let bounds = contentView.bounds.insetBy(dx: 16.0, dy: 8.0)
    thumbnailNode.frame = CGRect(x: bounds.minX, y: bounds.minY, width: 56.0, height: 56.0)
    titleLabel.frame = CGRect(
      x: thumbnailNode.frame.maxX + 12.0,
      y: bounds.minY + 8.0,
      width: max(0.0, bounds.width - 68.0),
      height: 20.0
    )
    subtitleLabel.frame = CGRect(
      x: thumbnailNode.frame.maxX + 12.0,
      y: titleLabel.frame.maxY + 4.0,
      width: max(0.0, bounds.width - 68.0),
      height: 18.0
    )
  }

  override func setHighlighted(_ highlighted: Bool, animated: Bool) {
    super.setHighlighted(highlighted, animated: animated)
    thumbnailNode.isHighlighted = highlighted
    UIView.animate(withDuration: highlighted ? 0.08 : 0.16) {
      self.titleLabel.alpha = highlighted ? 0.74 : 1.0
      self.subtitleLabel.alpha = highlighted ? 0.74 : 1.0
    }
  }

  func configure(
    title: String,
    subtitle: String,
    urlString: String?,
    isVideo: Bool,
    titleColor: UIColor,
    subtitleColor: UIColor,
    placeholderTintColor: UIColor,
    placeholderBackgroundColor: UIColor
  ) {
    titleLabel.text = title
    titleLabel.textColor = titleColor
    subtitleLabel.text = subtitle
    subtitleLabel.textColor = subtitleColor
    thumbnailNode.configure(urlString: urlString, isVideo: isVideo)
    thumbnailNode.applyTheme(
      placeholderTintColor: placeholderTintColor,
      placeholderBackgroundColor: placeholderBackgroundColor
    )
  }
}

private final class ChatProfileVoiceContentCell: UITableViewCell, VoicePlayableCell {
  static let reuseIdentifier = "ChatProfileVoiceContentCell"

  private let chromeView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
  private let chromeOverlayView = UIView()
  let voiceButtonView = VoicePlayProgressView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let dateLabel = UILabel()
  private var messageId: String?
  private var mediaUrl: String?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    backgroundColor = .clear
    contentView.backgroundColor = .clear

    chromeView.clipsToBounds = true
    chromeView.layer.cornerCurve = .continuous
    chromeView.isUserInteractionEnabled = false
    contentView.addSubview(chromeView)
    chromeOverlayView.isUserInteractionEnabled = false
    chromeView.contentView.addSubview(chromeOverlayView)

    voiceButtonView.isUserInteractionEnabled = false
    contentView.addSubview(voiceButtonView)

    titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
    contentView.addSubview(titleLabel)

    subtitleLabel.font = UIFont.systemFont(ofSize: 14, weight: .medium)
    contentView.addSubview(subtitleLabel)

    dateLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
    dateLabel.textAlignment = .right
    contentView.addSubview(dateLabel)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let bounds = contentView.bounds.insetBy(dx: 16.0, dy: 8.0)
    chromeView.frame = contentView.bounds.insetBy(dx: 14.0, dy: 4.0)
    chromeView.layer.cornerRadius = 22.0
    chromeOverlayView.frame = chromeView.bounds

    let buttonSize: CGFloat = 44.0
    voiceButtonView.frame = CGRect(
      x: bounds.minX,
      y: bounds.minY + floor((bounds.height - buttonSize) * 0.5),
      width: buttonSize,
      height: buttonSize
    )

    let textX = voiceButtonView.frame.maxX + 12.0

    let dateWidth: CGFloat = 70.0
    dateLabel.frame = CGRect(
      x: bounds.maxX - dateWidth,
      y: bounds.minY + 6.0,
      width: dateWidth,
      height: 20.0
    )

    let textWidth = max(20.0, dateLabel.frame.minX - textX - 8.0)
    titleLabel.frame = CGRect(
      x: textX,
      y: bounds.minY + 6.0,
      width: textWidth,
      height: 20.0
    )

    subtitleLabel.frame = CGRect(
      x: textX,
      y: titleLabel.frame.maxY + 2.0,
      width: textWidth,
      height: 18.0
    )
  }

  override func setHighlighted(_ highlighted: Bool, animated: Bool) {
    super.setHighlighted(highlighted, animated: animated)
    UIView.animate(withDuration: highlighted ? 0.08 : 0.16) {
      self.contentView.alpha = highlighted ? 0.74 : 1.0
    }
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    VoiceBubblePlaybackCoordinator.shared.unbind(cell: self)
    voiceButtonView.setDownloadState(needsDownload: false, isDownloading: false, progress: nil)
    voiceButtonView.setPlaybackState(isPlaying: false, progress: 0.0, level: 0.0)
  }

  func configure(
    title: String,
    subtitle: String,
    row: ChatProfileRow,
    titleColor: UIColor,
    subtitleColor: UIColor,
    accentColor: UIColor
  ) {
    messageId = row.messageId
    mediaUrl = row.mediaUrl

    titleLabel.text = title
    titleLabel.textColor = titleColor

    subtitleLabel.text = subtitle
    subtitleLabel.textColor = subtitleColor

    let dateMs = row.timestampMs ?? 0
    if dateMs > 0 {
      let date = Date(timeIntervalSince1970: TimeInterval(dateMs) / 1000.0)
      let formatter = DateFormatter()
      formatter.dateStyle = .none
      formatter.timeStyle = .short
      dateLabel.text = formatter.string(from: date)
    } else {
      dateLabel.text = ""
    }
    dateLabel.textColor = subtitleColor.withAlphaComponent(0.6)

    voiceButtonView.applyStyle(fillColor: accentColor, iconTint: .white, ringTint: accentColor)
    chromeView.effect = UIBlurEffect(style: titleColor == UIColor.white ? .systemThinMaterialDark : .systemMaterialLight)
    chromeOverlayView.backgroundColor =
      (titleColor == UIColor.white ? UIColor.white : UIColor.black).withAlphaComponent(titleColor == UIColor.white ? 0.06 : 0.035)
  }

  func applyVoicePlaybackState(isPlaying: Bool, progress: CGFloat, level: CGFloat) {
    voiceButtonView.setPlaybackState(isPlaying: isPlaying, progress: progress, level: level)
  }

  func applyVoiceDownloadState(needsDownload: Bool, isDownloading: Bool, progress: CGFloat?) {
    voiceButtonView.setDownloadState(
      needsDownload: needsDownload,
      isDownloading: isDownloading,
      progress: progress
    )
  }

  func applyVoiceDownloadFailedState() {
    // Compact profile chip: fall back to the plain download affordance.
    voiceButtonView.setDownloadState(needsDownload: true, isDownloading: false, progress: nil)
  }
}

final class ChatProfileMainView: UIView, UITableViewDataSource, UITableViewDelegate {
  public var onViewportChanged = NativeEventDispatcher()
  public var onNativeEvent = NativeEventDispatcher()

  @objc public var surfaceId: String = ""

  private let backgroundGradientLayer = CAGradientLayer()
  private let posterImageLayer = CALayer()
  private let avatarGlassRing = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))

  private let headerMaskContainer = UIView()
  private let headerMaskView = UIView()
  private let headerMaskBlurView = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
  private let headerMaskOverlayView = UIView()
  private let headerMaskGradientLayer = CAGradientLayer()
  private let headerContainer = UIView()
  private let headerContentView = UIView()
  private let backButton = UIButton(type: .system)
  private let menuButton = UIButton(type: .system)
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()

  private let tableView = UITableView(frame: .zero, style: .insetGrouped)
  private let swiftUIContainerView = UIView()
  private var swiftUIHostingController: UIHostingController<AnyView>?
  // Top safe-area inset handed to the SwiftUI root at the last render. Tracked so
  // safeAreaInsetsDidChange can re-render only when the real inset actually
  // arrives (first render often runs pre-window with a 0 inset).
  private var lastRenderedSafeAreaTop: CGFloat = -1.0
  private let floatingAvatarView: NativeProfileAvatarView

  private let heroHeaderView = UIView()
  private let heroBannerView = UIView()
  private let heroNameLabel = UILabel()
  private let heroHandleButton = UIButton(type: .system)
  private let heroBioLabel = UILabel()

  private let actionsStack = UIStackView()
  private let muteActionButton = ChatMainProfileActionNode()
  private let searchActionButton = ChatMainProfileActionNode()
  private let audioActionButton = ChatMainProfileActionNode()
  private let videoActionButton = ChatMainProfileActionNode()

  private var rows: [ChatProfileRow] = []
  private var mediaRows: [ChatProfileRow] = []
  private var voiceRows: [ChatProfileRow] = []
  private var gifRows: [ChatProfileRow] = []
  private var musicRows: [ChatProfileRow] = []
  private var fileRows: [ChatProfileRow] = []
  private var pinnedRows: [ChatProfileRow] = []
  private var linkRows: [ChatProfileLinkItem] = []
  private var availableTabs: [ChatProfileTab] = []
  private var activeTab: ChatProfileTab = .media
  private var profileName = "User"
  private var profileHandle = ""
  private var profileBio = ""
  private var headerTitle = "Profile"
  private var headerSubtitle = ""
  private var avatarUri: String?
  private var avatarResolveGeneration: UInt = 0
  private var isChatMuted = false
  private var isGroupOrChannel = false
  /// Channel rooms share isGroupOrChannel but hide the Members list.
  private var isChannel = false
  private var isOnline = false
  private var groupMemberCount: Int?
  private var groupMembers: [[String: Any]] = []
  /// Sticky role so incomplete member payloads cannot demote admin→member (or empty).
  private var stickyMyGroupRole: String = ""
  // Channel policy snapshot for host setters → SwiftUI root (additive).
  private var channelAccessType: String = "private"
  private var channelPublicSlug: String = ""
  private var channelShareLink: String = ""
  private var channelJoinApprovalRequired = false
  private var channelRestrictSavingContent = false
  private var channelSubscriberCount: Int?

  private var engineChatId = ""
  private var engineMyUserId = ""
  private var enginePeerUserId = ""
  private var agentConfig: [String: Any]?
  // Non-empty ("claude"/"codex"/"grok") when this profile is a paired-computer bridge
  // agent. Drives the "Computer" connection card + the agent-history browser.
  private var bridgeProvider = ""
  private var bridgeConnected = false
  private var bridgePaired = false
  private var bridgeDeviceLabel = ""
  private var bridgeRunningTasks: [AgentBridgeRunningTask] = []
  private var bridgeStatusTask: Task<Void, Never>?
  private var bridgeStatusRefreshWorkItem: DispatchWorkItem?
  private var avatarMorphProgress: CGFloat = 0.0
  private var currentHeroTop: CGFloat = 0.0
  private var currentCollapsedTop: CGFloat = 0.0
  private var currentTextColor: UIColor = .label
  private var currentSecondaryTextColor: UIColor = .secondaryLabel
  private var currentRowSeparatorColor: UIColor = UIColor(white: 0.0, alpha: 0.08)
  private var currentRowHighlightColor: UIColor = UIColor(white: 0.0, alpha: 0.04)
  private var currentRowCardColor: UIColor = UIColor.white
  private var currentRowAccentColor: UIColor = UIColor(
    red: 0.17, green: 0.65, blue: 0.71, alpha: 1.0)
  private var currentRowIconBackgroundColor: UIColor = UIColor(
    red: 0.17,
    green: 0.65,
    blue: 0.71,
    alpha: 0.12
  )
  private var swiftUIScrollOffset: CGFloat = 0.0
  private var swiftUINavigationActive = false
  private var swiftUIRenderBatchDepth = 0
  private var needsBatchedSwiftUIRender = false
  /// Coalesces bursty re-renders (setRows + setGroupMembers + bridge status on open)
  /// into a single rootView assignment so the scroll view is not rebuilt mid-frame.
  private var swiftUIRenderCoalesceScheduled = false
  private var lastSwiftUIRenderSignature: String = ""
  private static let listDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter
  }()

  override init(frame: CGRect) {
    floatingAvatarView = NativeProfileAvatarView()
    super.init(frame: frame)
    configureView()
    applyTheme()
    rebuildDerivedContent()
    reloadHeaderText()
    refreshHeroContent()
    rebuildMenu()
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    guard previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle else {
      return
    }
    ChatListAppearance.invalidateBootstrap()
    applyTheme()
    tableView.reloadData()
    layoutHeroHeaderViewIfNeeded(force: true)
    renderSwiftUIProfile()
  }

  deinit {
    bridgeStatusTask?.cancel()
    bridgeStatusRefreshWorkItem?.cancel()
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func handleAgentBridgeSelectionDidChange() {
    // Repo subtitle is owned by SwiftUI `@State` / Menu selection — do NOT rebuild
    // the whole hosting tree here (that reassignment was a source of open/jump).
  }

  @objc private func handleAppearanceDraftDidChange() {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [weak self] in
        self?.handleAppearanceDraftDidChange()
      }
      return
    }
    ChatListAppearance.invalidateBootstrap()
    applyTheme()
    tableView.reloadData()
    layoutHeroHeaderViewIfNeeded(force: true)
    renderSwiftUIProfile()
  }

  override func safeAreaInsetsDidChange() {
    super.safeAreaInsetsDidChange()
    updateAvatarMetrics()
    setNeedsLayout()
    // Do NOT re-render the SwiftUI tree when the top inset settles. That
    // re-render was the primary cause of the header jumping down and the
    // scroll area shifting up on profile open. The system NavigationStack bar
    // owns chrome layout now; hero metrics no longer depend on safeAreaTop.
    lastRenderedSafeAreaTop = resolvedSafeAreaTop()
  }

  /// The real top safe-area inset to hand the SwiftUI root. Prefers this view's
  /// own inset; falls back to the key window's while the view isn't yet in a
  /// window (its own inset is still 0 then). Chrome positioning depends on this
  /// being the true status-bar/Dynamic-Island height, not the host-stripped 0.
  private func resolvedSafeAreaTop() -> CGFloat {
    if safeAreaInsets.top > 0 { return safeAreaInsets.top }
    return Self.keyWindowSafeAreaTop()
  }

  private static func keyWindowSafeAreaTop() -> CGFloat {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .first { $0.isKeyWindow }?
      .safeAreaInsets.top ?? 0.0
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    attachSwiftUIHostIfNeeded()
    if window == nil {
      bridgeStatusTask?.cancel()
      bridgeStatusRefreshWorkItem?.cancel()
      bridgeStatusRefreshWorkItem = nil
    } else {
      refreshBridgeStatus()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    let safeTop = safeAreaInsets.top
    let headerHeight = safeTop + 62.0
    let headerChromeHeight = headerHeight + 108.0
    updateAvatarMetrics()

    headerMaskContainer.frame = CGRect(x: 0.0, y: 0.0, width: bounds.width, height: headerChromeHeight)
    headerMaskView.frame = headerMaskContainer.bounds
    headerMaskBlurView.frame = headerMaskView.bounds
    headerMaskOverlayView.frame = headerMaskBlurView.bounds
    headerMaskGradientLayer.frame = headerMaskView.bounds
    headerContainer.frame = CGRect(x: 0.0, y: 0.0, width: bounds.width, height: headerHeight)
    headerContentView.frame = CGRect(
      x: 12.0,
      y: safeTop + 8.0,
      width: max(0.0, bounds.width - 24.0),
      height: 44.0
    )
    backButton.frame = CGRect(x: 0.0, y: 0.0, width: 44.0, height: 44.0)
    menuButton.frame = CGRect(
      x: max(0.0, headerContentView.bounds.width - 44.0), y: 0.0, width: 44.0, height: 44.0)
    let textX = backButton.frame.maxX + 12.0
    let textWidth = menuButton.frame.minX - textX - 12.0
    let textAvailable = textWidth > 40.0
    titleLabel.frame =
      textAvailable ? CGRect(x: textX, y: 2.0, width: textWidth, height: 20.0) : .zero
    subtitleLabel.frame =
      textAvailable ? CGRect(x: textX, y: 22.0, width: textWidth, height: 16.0) : .zero
    titleLabel.textAlignment = .center
    subtitleLabel.textAlignment = .center
    titleLabel.isHidden = true
    subtitleLabel.isHidden = true
    titleLabel.alpha = 0.0
    subtitleLabel.alpha = 0.0

    tableView.frame = bounds
    tableView.scrollIndicatorInsets = UIEdgeInsets(
      top: headerHeight, left: 0.0, bottom: 0.0, right: 0.0)
    swiftUIContainerView.frame = bounds
    // First mount happens here, not at init: only now are bounds and safe-area
    // insets real, so the nav bar and hero lay out once instead of during the push.
    if swiftUIHostingController == nil {
      renderSwiftUIProfile()
    }
    attachSwiftUIHostIfNeeded()
    swiftUIHostingController?.view.frame = swiftUIContainerView.bounds

    layoutHeroHeaderViewIfNeeded(force: true)
    layoutActionsForCurrentScroll()

    // Size the background gradient to fill the view
    backgroundGradientLayer.frame = bounds
    posterImageLayer.frame = bounds

    layoutFloatingAvatarView()
    updateAvatarMorphProgress()
    layoutAvatarGlassRing()
    swiftUIContainerView.isHidden = false
    floatingAvatarView.isHidden = true
    avatarGlassRing.isHidden = true
    avatarGlassRing.alpha = 0.0
    headerContainer.isHidden = true
    headerMaskContainer.isHidden = true
    bringSubviewToFront(swiftUIContainerView)
    if let hostView = swiftUIHostingController?.view {
      swiftUIContainerView.bringSubviewToFront(hostView)
    }

    onViewportChanged([
      "width": bounds.width,
      "height": bounds.height,
      "surfaceId": surfaceId,
    ])
  }

  func setProfileOnly(_ value: Bool) {
    _ = value
  }

  func setRows(_ rows: [[String: Any]]) {
    self.rows = rows.compactMap(ChatProfileRow.parse)
    rebuildDerivedContent()
    reloadDataKeepingSelection()
  }

  func setEngineSurfaceId(_ value: String) {
    _ = value
  }

  func performBatchedProfileUpdate(_ updates: () -> Void) {
    swiftUIRenderBatchDepth += 1
    updates()
    swiftUIRenderBatchDepth -= 1
    guard swiftUIRenderBatchDepth == 0 else { return }
    // One avatar rebuild after the whole route lands — avoids racing the
    // floating-avatar host against mid-batch SwiftUI root replacements (SIGSEGV).
    refreshAvatar()
    guard needsBatchedSwiftUIRender else { return }
    needsBatchedSwiftUIRender = false
    renderSwiftUIProfile()
  }

  /// Seed sticky role / channel flag from the chat route (home list `role` + type).
  func setRouteMembership(isChannel: Bool, myRole: String?) {
    // Channels are always multi-party rooms. Promote isGroupOrChannel first so
    // `isChannel = flag && isGroupOrChannel` cannot stick as false when callers
    // only set membership (or set it before setIsGroupOrChannel).
    if isChannel {
      isGroupOrChannel = true
    }
    let nextChannel = isChannel && isGroupOrChannel
    let roleChanged: Bool
    if let role = myRole?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      !role.isEmpty
    {
      roleChanged = stickyMyGroupRole != role
      stickyMyGroupRole = role
    } else {
      roleChanged = false
    }
    let channelChanged = self.isChannel != nextChannel
    self.isChannel = nextChannel
    if channelChanged || roleChanged {
      reloadHeaderText()
      refreshHeroContent()
      renderSwiftUIProfile()
    }
  }

  func setEngineChatId(_ value: String) {
    engineChatId = value.trimmingCharacters(in: .whitespacesAndNewlines)
    fetchAgentConfigForCurrentChat()
    applyTheme()
    refreshAvatar()
    renderSwiftUIProfile()
  }

  func setEngineMyUserId(_ value: String) {
    engineMyUserId = value.trimmingCharacters(in: .whitespacesAndNewlines)
    renderSwiftUIProfile()
  }

  func setEnginePeerUserId(_ value: String) {
    enginePeerUserId = value.trimmingCharacters(in: .whitespacesAndNewlines)
    tableView.reloadData()
    applyTheme()
    refreshAvatar()
    renderSwiftUIProfile()
  }

  func setStatusAuthorityEnabled(_ enabled: Bool) {
    _ = enabled
  }

  func setAppearance(_ rawAppearance: [String: Any]) {
    applyTheme()
    tableView.reloadData()
    layoutHeroHeaderViewIfNeeded(force: true)
    renderSwiftUIProfile()
  }

  func setHeaderTitle(_ value: String) {
    headerTitle = value.trimmingCharacters(in: .whitespacesAndNewlines)
    applyTheme()
    refreshAvatar()
    reloadHeaderText()
    refreshHeroContent()
  }

  func setHeaderSubtitle(_ value: String) {
    headerSubtitle = value.trimmingCharacters(in: .whitespacesAndNewlines)
    reloadHeaderText()
  }

  func setProfileName(_ value: String) {
    profileName = value.trimmingCharacters(in: .whitespacesAndNewlines)
    applyTheme()
    refreshAvatar()
    reloadHeaderText()
    refreshHeroContent()
  }

  func setProfileHandle(_ value: String) {
    profileHandle = value.trimmingCharacters(in: .whitespacesAndNewlines)
    // Fall back to detecting a bridge agent from its reserved username when an
    // explicit provider wasn't supplied by the host.
    if bridgeProvider.isEmpty {
      let handle = profileHandle.lowercased().replacingOccurrences(of: "@", with: "")
      if handle == "claude" || handle == "codex" || handle == "grok" || handle == "agy" || handle == "antigravity" {
        setBridgeProvider(handle)
      }
    }
    refreshHeroContent()
    tableView.reloadData()
    renderSwiftUIProfile()
  }

  /// Marks this profile as a Claude/Codex paired-computer agent so it shows the
  /// "Computer" connection card (connect / disconnect / reconnect) and reads the
  /// agent's own conversation history from the connected computer.
  func setBridgeProvider(_ value: String) {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard normalized == "claude" || normalized == "codex" || normalized == "grok" || normalized == "agy" || normalized == "antigravity" else {
      if !bridgeProvider.isEmpty {
        bridgeProvider = ""
        renderSwiftUIProfile()
      }
      return
    }
    guard normalized != bridgeProvider else { return }
    bridgeProvider = normalized
    refreshBridgeStatus()
    renderSwiftUIProfile()
  }

  private func refreshBridgeStatus() {
    bridgeStatusRefreshWorkItem?.cancel()
    bridgeStatusRefreshWorkItem = nil
    guard !bridgeProvider.isEmpty, window != nil else { return }
    bridgeStatusTask?.cancel()
    bridgeStatusTask = Task { [weak self] in
      guard let config = AppSessionConfig.current else { return }
      // Coalesced: Home polls the same endpoint, and each call is ~700ms of server time.
      let status = try? await AgentPairingService.statusCoalesced(config: config)
      guard let status, !Task.isCancelled else { return }
      await MainActor.run { [weak self] in
        guard let self else { return }
        let nextDeviceLabel = status.devices.first?.label ?? ""
        let nextRunningTasks = status.runningTasks.filter { task in
          let taskProvider = task.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          return taskProvider.isEmpty || taskProvider == self.bridgeProvider
        }
        let changed =
          self.bridgeConnected != status.connected
          || self.bridgePaired != status.paired
          || self.bridgeDeviceLabel != nextDeviceLabel
          || self.bridgeRunningTasks != nextRunningTasks

        self.bridgeConnected = status.connected
        self.bridgePaired = status.paired
        self.bridgeDeviceLabel = nextDeviceLabel
        self.bridgeRunningTasks = nextRunningTasks
        if changed {
          self.renderSwiftUIProfile()
        }
        self.scheduleBridgeStatusRefresh()
      }
    }
  }

  private func scheduleBridgeStatusRefresh() {
    bridgeStatusRefreshWorkItem?.cancel()
    guard !bridgeProvider.isEmpty, window != nil else { return }
    let item = DispatchWorkItem { [weak self] in
      self?.refreshBridgeStatus()
    }
    bridgeStatusRefreshWorkItem = item
    // 3s → 12s when nothing is running. This loop ran the whole time an agent profile was
    // open, on top of Home's own poll, and each call costs the server ~700ms. A live run
    // keeps the old cadence so its task list stays current.
    let delay: TimeInterval = bridgeRunningTasks.isEmpty ? 12.0 : 3.0
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  func setProfileBio(_ value: String) {
    profileBio = value.trimmingCharacters(in: .whitespacesAndNewlines)
    refreshHeroContent()
    tableView.reloadData()
    renderSwiftUIProfile()
  }

  func setAvatarUri(_ value: String?) {
    let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard avatarUri != normalized else { return }
    avatarUri = normalized
    refreshAvatar()
    renderSwiftUIProfile()
  }

  func refreshProfileAppearance() {
    applyTheme()
    refreshAvatar()
    renderSwiftUIProfile()
    setNeedsLayout()
    updateAvatarMorphProgress()
  }

  func setIsOnline(_ value: Bool) {
    if isOnline == value { return }
    isOnline = value
    reloadHeaderText()
    refreshHeroContent()
  }

  func setIsChatMuted(_ value: Bool) {
    if isChatMuted == value { return }
    isChatMuted = value
    updateActionButtons()
    rebuildMenu()
    tableView.reloadData()
    renderSwiftUIProfile()
  }

  func setIsGroupOrChannel(_ value: Bool) {
    if isGroupOrChannel == value { return }
    isGroupOrChannel = value
    if !value {
      isChannel = false
      stickyMyGroupRole = ""
    }
    reloadHeaderText()
    refreshHeroContent()
    refreshAvatar()
    tableView.reloadData()
    // The live profile is the SwiftUI view — it must re-render when group-ness
    // flips, otherwise it keeps the DM layout (contact actions, no member rows).
    renderSwiftUIProfile()
  }

  func setGroupMembers(_ members: [[String: Any]]) {
    // Merge so a partial/stale payload that omits `role` cannot flip admin → member
    // (the admin/member subtitle flicker). Explicit roles always win.
    let prevRole = myGroupRole()
    let merged = Self.mergeGroupMemberPayloads(previous: groupMembers, incoming: members)
    let config = ChatEngineStore.shared.getConfig()
    let me =
      (config["userId"] as? String)
      ?? (config["myUserId"] as? String)
      ?? engineMyUserId
    let meKey = me.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    // Resolve role from merged payload for logging (myGroupRole uses groupMembers).
    let mergedMine = merged.first { entry in
      let id =
        (entry["userId"] as? String)
        ?? (entry["user_id"] as? String)
        ?? (entry["id"] as? String)
        ?? (entry["memberId"] as? String)
      return id?.caseInsensitiveCompare(meKey) == .orderedSame
        || id?.caseInsensitiveCompare(engineMyUserId) == .orderedSame
    }
    let nextRoleRaw =
      (mergedMine?["role"] as? String)
      ?? (mergedMine?["memberRole"] as? String)
      ?? (mergedMine?["member_role"] as? String)
      ?? ""
    let nextRole = nextRoleRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    // Stick explicit roles; never wipe sticky when this payload omitted our role.
    if !nextRole.isEmpty {
      stickyMyGroupRole = nextRole
    }
    let equal = Self.groupMembersSemanticallyEqual(groupMembers, merged)
    NSLog(
      "[WhoAmI] ChatProfile.setGroupMembers incoming=%d merged=%d equal=%@ me=%@ prevRole=%@ nextRole=%@ sticky=%@ isAdmin=%@ isOwner=%@ isChannel=%@ engineMyUserId=%@",
      members.count,
      merged.count,
      equal ? "Y" : "N",
      meKey.isEmpty ? "<unknown>" : String(meKey.prefix(8)),
      prevRole.isEmpty ? "<empty>" : prevRole,
      nextRole.isEmpty ? "<empty>" : nextRole,
      stickyMyGroupRole.isEmpty ? "<empty>" : stickyMyGroupRole,
      (myGroupRole() == "owner" || myGroupRole() == "admin") ? "Y" : "N",
      myGroupRole() == "owner" ? "Y" : "N",
      isChannel ? "Y" : "N",
      engineMyUserId.isEmpty ? "<unset>" : String(engineMyUserId.prefix(8))
    )
    guard !equal else {
      // Still re-render once if this is the first non-empty roster after empty.
      if groupMembers.isEmpty, !merged.isEmpty {
        groupMembers = merged
        if swiftUIRenderBatchDepth > 0 {
          needsBatchedSwiftUIRender = true
          return
        }
        tableView.reloadData()
        renderSwiftUIProfile()
        // Defer mosaic rebuild off the call stack that may still be building the host.
        DispatchQueue.main.async { [weak self] in self?.refreshAvatar() }
      }
      return
    }
    groupMembers = merged
    if swiftUIRenderBatchDepth > 0 {
      // applyRoute batches many setters; one render+avatar at the end (see batch helper).
      needsBatchedSwiftUIRender = true
      return
    }
    tableView.reloadData()
    // Without this the members roster / header count never appear in the live
    // SwiftUI profile — it was only re-rendered by unrelated later setters.
    renderSwiftUIProfile()
    // The group hero is a mosaic composed from these members, so it must rebuild
    // when the roster arrives (members often land after the initial avatar set).
    // Defer so we never mutate the floating-avatar hosting view in the same
    // stack as a full SwiftUI root replacement (device SIGSEGV after applyRoute).
    DispatchQueue.main.async { [weak self] in self?.refreshAvatar() }
  }

  /// Stable merge of group member dictionaries keyed by user id. When an
  /// incoming entry lacks a role (or sends empty), keep the previous non-empty
  /// role so UI does not flicker between Member and Admin.
  private static func mergeGroupMemberPayloads(
    previous: [[String: Any]],
    incoming: [[String: Any]]
  ) -> [[String: Any]] {
    func memberId(_ entry: [String: Any]) -> String? {
      let raw =
        (entry["userId"] as? String)
        ?? (entry["user_id"] as? String)
        ?? (entry["id"] as? String)
        ?? (entry["memberId"] as? String)
      let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return trimmed.isEmpty ? nil : trimmed
    }
    func memberRole(_ entry: [String: Any]) -> String? {
      let raw =
        (entry["role"] as? String)
        ?? (entry["memberRole"] as? String)
        ?? (entry["member_role"] as? String)
        ?? (entry["participantRole"] as? String)
      let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
      return trimmed.isEmpty ? nil : trimmed
    }

    var previousById: [String: [String: Any]] = [:]
    for entry in previous {
      guard let id = memberId(entry) else { continue }
      previousById[id.uppercased()] = entry
    }

    if incoming.isEmpty {
      return previous
    }

    var seen = Set<String>()
    var result: [[String: Any]] = []
    for entry in incoming {
      guard let id = memberId(entry) else { continue }
      let key = id.uppercased()
      guard seen.insert(key).inserted else { continue }
      var next = entry
      if memberRole(next) == nil, let prior = previousById[key], let priorRole = memberRole(prior) {
        next["role"] = priorRole
      } else if let role = memberRole(next) {
        next["role"] = role
      }
      // Normalize identity keys so later lookups are consistent.
      next["userId"] = id
      result.append(next)
    }

    // Keep prior members not present in this (possibly partial) payload only when
    // the incoming list is clearly a subset refresh of known agents/contacts.
    // Full authoritative lists replace the roster.
    if result.count < previous.count / 2, !previous.isEmpty {
      for entry in previous {
        guard let id = memberId(entry) else { continue }
        let key = id.uppercased()
        if seen.insert(key).inserted {
          result.append(entry)
        }
      }
    }
    return result
  }

  private static func groupMembersSemanticallyEqual(
    _ lhs: [[String: Any]],
    _ rhs: [[String: Any]]
  ) -> Bool {
    guard lhs.count == rhs.count else { return false }
    func signature(_ entry: [String: Any]) -> String {
      let id =
        ((entry["userId"] as? String)
          ?? (entry["user_id"] as? String)
          ?? (entry["id"] as? String)
          ?? (entry["memberId"] as? String)
          ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
      let role =
        ((entry["role"] as? String)
          ?? (entry["memberRole"] as? String)
          ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let name =
        ((entry["name"] as? String)
          ?? (entry["displayName"] as? String)
          ?? (entry["username"] as? String)
          ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      return "\(id)|\(role)|\(name)"
    }
    let left = lhs.map(signature).sorted()
    let right = rhs.map(signature).sorted()
    return left == right
  }

  func setGroupMemberCount(_ value: Int?) {
    groupMemberCount = value
    tableView.reloadData()
    renderSwiftUIProfile()
  }

  /// Host-provided channel policy snapshot (additive; does not rename existing APIs).
  /// Lead wires this from home row / `GET /api/channel/:id` without profile networking.
  func setChannelSettings(
    accessType: String? = nil,
    publicSlug: String? = nil,
    shareLink: String? = nil,
    joinApprovalRequired: Bool? = nil,
    restrictSavingContent: Bool? = nil,
    subscriberCount: Int? = nil
  ) {
    if let accessType {
      let trimmed = accessType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if !trimmed.isEmpty {
        channelAccessType = trimmed
      }
    }
    if let publicSlug {
      channelPublicSlug = publicSlug.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let shareLink {
      channelShareLink = shareLink.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let joinApprovalRequired {
      channelJoinApprovalRequired = joinApprovalRequired
    }
    if let restrictSavingContent {
      channelRestrictSavingContent = restrictSavingContent
    }
    if let subscriberCount {
      channelSubscriberCount = max(0, subscriberCount)
    }
    renderSwiftUIProfile()
  }

  /// Re-hydrate the group roster when the Members screen opens empty (stale home
  /// cache that omitted `members`). Tries on-disk cache first, then a live home
  /// fetch. Always logs so device console shows the path taken.
  func refreshGroupMembersFromHome(reason: String) {
    guard isGroupOrChannel else { return }
    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty else {
      NSLog("[WhoAmI] Members.refresh skipped reason=%@ no chatId", reason)
      return
    }

    if !groupMembers.isEmpty {
      NSLog(
        "[WhoAmI] Members.refresh reason=%@ alreadyHave=%d chatId=%@",
        reason,
        groupMembers.count,
        String(chatId.prefix(12))
      )
      return
    }

    if let config = AppSessionConfig.current {
      let cached = ChatHomeService.cachedRows(config: config)
      if let row = cached.first(where: { $0.chatId == chatId }), !row.members.isEmpty {
        NSLog(
          "[WhoAmI] Members.refresh reason=%@ cacheHit=%d chatId=%@",
          reason,
          row.members.count,
          String(chatId.prefix(12))
        )
        setGroupMembers(row.members)
        setGroupMemberCount(row.members.count)
        return
      }
    }

    NSLog(
      "[WhoAmI] Members.refresh reason=%@ emptyLocal+emptyCache fetchingHome chatId=%@",
      reason,
      String(chatId.prefix(12))
    )
    guard let config = AppSessionConfig.current else {
      NSLog("[WhoAmI] Members.refresh reason=%@ no session", reason)
      return
    }
    let fetchChatId = chatId
    Task { [weak self] in
      do {
        let rows = try await ChatHomeService.fetchChats(config: config)
        let members =
          rows.first(where: { $0.chatId == fetchChatId })?.members ?? []
        await MainActor.run {
          guard let self else { return }
          NSLog(
            "[WhoAmI] Members.refresh reason=%@ networkHit=%d chatId=%@",
            reason,
            members.count,
            String(fetchChatId.prefix(12))
          )
          guard !members.isEmpty else { return }
          self.setGroupMembers(members)
          self.setGroupMemberCount(members.count)
          self.reloadVisibleMembersUIKitIfNeeded()
        }
      } catch {
        NSLog(
          "[WhoAmI] Members.refresh reason=%@ networkError=%@",
          reason,
          error.localizedDescription
        )
      }
    }
  }

  /// If the UIKit members screen is already on screen, push the new roster into it.
  private func reloadVisibleMembersUIKitIfNeeded() {
    guard let top = topMostViewController() as? ChatGroupMembersViewController
      ?? topMostViewController()?.navigationController?.topViewController
      as? ChatGroupMembersViewController
    else { return }
    let items = chatProfileMemberItems(from: groupMembers)
    NSLog(
      "[WhoAmI] MembersUIKit.reloadVisible count=%d chatId=%@",
      items.count,
      String(engineChatId.prefix(12))
    )
    top.applyMembers(items)
  }

  func setPage(_ value: String, animated: Bool) {
    _ = animated
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if normalized == "agent" {
      presentAgentConfigEditor()
    }
  }

  private func configureView() {
    clipsToBounds = false

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAgentBridgeSelectionDidChange),
      name: AgentBridgeSelectionStore.didChangeNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleAppearanceDraftDidChange),
      name: ChatAppearanceDraftStore.didChangeNotification,
      object: nil
    )

    // Background gradient
    backgroundGradientLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
    backgroundGradientLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
    layer.insertSublayer(backgroundGradientLayer, at: 0)
    posterImageLayer.contentsGravity = .resizeAspectFill
    posterImageLayer.opacity = 0.0
    layer.insertSublayer(posterImageLayer, above: backgroundGradientLayer)

    // Avatar glass ring
    avatarGlassRing.clipsToBounds = true
    avatarGlassRing.isUserInteractionEnabled = false
    avatarGlassRing.isHidden = true
    avatarGlassRing.alpha = 0.0

    addSubview(headerMaskContainer)
    headerMaskContainer.clipsToBounds = true
    headerMaskContainer.isUserInteractionEnabled = false
    headerMaskContainer.layer.zPosition = 20.0
    headerMaskContainer.alpha = 0.0
    headerMaskView.isUserInteractionEnabled = false
    headerMaskContainer.addSubview(headerMaskView)
    headerMaskView.addSubview(headerMaskBlurView)
    headerMaskBlurView.contentView.addSubview(headerMaskOverlayView)
    headerMaskGradientLayer.colors = [
      UIColor.black.cgColor,
      UIColor.black.cgColor,
      UIColor.black.withAlphaComponent(0.0).cgColor,
    ]
    headerMaskGradientLayer.locations = [0.0, 0.74, 1.0]
    headerMaskView.layer.mask = headerMaskGradientLayer
    addSubview(headerContainer)
    headerContainer.clipsToBounds = false
    headerContainer.isHidden = true
    headerContainer.isUserInteractionEnabled = false
    headerContainer.addSubview(headerContentView)
    headerContainer.layer.zPosition = 60.0
    headerContentView.addSubview(backButton)
    headerContentView.addSubview(menuButton)
    headerContentView.addSubview(titleLabel)
    headerContentView.addSubview(subtitleLabel)

    backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
    backButton.addTarget(self, action: #selector(handleBackPressed), for: .touchUpInside)

    ChatMainProfileHeaderHelpers.applyProfileMenuButtonStyle(menuButton)
    if #available(iOS 14.0, *) {
      menuButton.showsMenuAsPrimaryAction = true
    } else {
      menuButton.addTarget(self, action: #selector(handleLegacyMenuPressed), for: .touchUpInside)
    }

    titleLabel.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
    titleLabel.textAlignment = .center
    titleLabel.isHidden = true
    subtitleLabel.font = UIFont.systemFont(ofSize: 12.0, weight: .regular)
    subtitleLabel.textAlignment = .center
    subtitleLabel.isHidden = true

    tableView.dataSource = self
    tableView.delegate = self
    tableView.separatorStyle = .none
    tableView.register(
      ChatProfileListRowCell.self, forCellReuseIdentifier: ChatProfileListRowCell.reuseIdentifier)
    tableView.register(
      ChatProfileTabStripCell.self, forCellReuseIdentifier: ChatProfileTabStripCell.reuseIdentifier)
    tableView.register(
      ChatProfileMediaContentCell.self,
      forCellReuseIdentifier: ChatProfileMediaContentCell.reuseIdentifier)
    tableView.register(
      ChatProfileVoiceContentCell.self,
      forCellReuseIdentifier: ChatProfileVoiceContentCell.reuseIdentifier)
    tableView.register(
      ChatProfileMediaGridRowCell.self,
      forCellReuseIdentifier: ChatProfileMediaGridRowCell.reuseIdentifier)
    tableView.separatorInset = UIEdgeInsets(top: 0.0, left: 16.0, bottom: 0.0, right: 16.0)
    tableView.contentInsetAdjustmentBehavior = .never
    tableView.estimatedRowHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0
    if #available(iOS 15.0, *) {
      tableView.sectionHeaderTopPadding = 0.0
    }
    tableView.isHidden = true
    tableView.isUserInteractionEnabled = false
    addSubview(tableView)

    floatingAvatarView.clipsToBounds = false
    floatingAvatarView.isUserInteractionEnabled = false

    // Pre-mount the live page color so the first frame never flashes a black or
    // white plate behind the pushed profile.
    backgroundColor = ChatListAppearance.current.wallpaperBase
    swiftUIContainerView.backgroundColor = ChatListAppearance.current.wallpaperBase
    swiftUIContainerView.clipsToBounds = false
    swiftUIContainerView.layer.zPosition = 30.0
    addSubview(swiftUIContainerView)

    swiftUIContainerView.insertSubview(avatarGlassRing, at: 0)
    swiftUIContainerView.insertSubview(floatingAvatarView, at: 0)

    bringSubviewToFront(swiftUIContainerView)
    bringSubviewToFront(headerContainer)

    configureHeroHeaderView()

    configureBackButtonStyle()

    updateActionButtons()
    refreshAvatar()
    renderSwiftUIProfile()
  }

  private func attachSwiftUIHostIfNeeded() {
    guard let host = swiftUIHostingController else { return }
    if host.parent == nil, let parent = nearestViewController() {
      parent.addChild(host)
      host.didMove(toParent: parent)
    }
  }

  private func nearestViewController() -> UIViewController? {
    var responder: UIResponder? = self
    while let next = responder?.next {
      if let viewController = next as? UIViewController {
        return viewController
      }
      responder = next
    }
    return nil
  }

  private func renderSwiftUIProfile() {
    guard swiftUIRenderBatchDepth == 0 else {
      needsBatchedSwiftUIRender = true
      return
    }
    if swiftUIHostingController == nil {
      // A zero-bounds first mount lays the nav bar and hero out at 0pt and then
      // shifts both when the real frame lands mid-push; layoutSubviews mounts it.
      guard bounds.width > 0, bounds.height > 0 else { return }
      performSwiftUIProfileRender()
      return
    }
    // Collapse later updates in the same run loop into one host replacement.
    guard !swiftUIRenderCoalesceScheduled else { return }
    swiftUIRenderCoalesceScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.swiftUIRenderCoalesceScheduled = false
      self.performSwiftUIProfileRender()
    }
  }

  private func performSwiftUIProfileRender() {
    lastRenderedSafeAreaTop = resolvedSafeAreaTop()

    let resolvedName =
      profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? (headerTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "User" : headerTitle)
      : profileName

    let resolvedUsername = resolvedIdentifierRawValue().trimmingCharacters(in: .whitespacesAndNewlines)
    let membersSig = groupMembers.map { entry -> String in
      let id =
        (entry["userId"] as? String) ?? (entry["id"] as? String) ?? (entry["memberId"] as? String)
        ?? ""
      let role = (entry["role"] as? String) ?? (entry["memberRole"] as? String) ?? ""
      let name = (entry["name"] as? String) ?? (entry["username"] as? String) ?? ""
      return "\(id):\(role):\(name)"
    }.joined(separator: ",")
    let tabsSig = availableTabs.map(\.rawValue).joined(separator: ",")
    let signature = [
      resolvedName,
      resolvedUsername,
      engineChatId,
      engineMyUserId,
      "\(isGroupOrChannel)",
      "\(isChannel)",
      "\(isChatMuted)",
      membersSig,
      "\(groupMemberCount ?? -1)",
      "\(canManageGroupMembers)",
      "\(isGroupOwner)",
      stickyMyGroupRole,
      bridgeProvider,
      "\(bridgeConnected)",
      "\(bridgePaired)",
      bridgeDeviceLabel,
      "\(rows.count)",
      tabsSig,
      "\(mediaRows.count)/\(musicRows.count)/\(voiceRows.count)/\(fileRows.count)/\(linkRows.count)",
      AgentBridgeSelectionStore.selectedRepository(
        chatId: engineChatId.isEmpty ? nil : engineChatId
      )?.id ?? "",
      avatarUri ?? "",
      profileBio,
      channelAccessType,
      channelPublicSlug,
      channelShareLink,
      "\(channelJoinApprovalRequired)",
      "\(channelRestrictSavingContent)",
      "\(channelSubscriberCount ?? -1)",
      "\(traitCollection.userInterfaceStyle.rawValue)",
      "\(ChatListAppearance.current.isDark)",
      ChatListAppearance.current.visualKey,
    ].joined(separator: "|")
    // Skip no-op host reassignments that recreate the ScrollView and jump offset.
    if signature == lastSwiftUIRenderSignature, swiftUIHostingController != nil {
      return
    }
    lastSwiftUIRenderSignature = signature

    let effectiveIsDark = (traitCollection.userInterfaceStyle == .unspecified
      ? ChatListAppearance.resolvedSystemStyle()
      : traitCollection.userInterfaceStyle) == .dark

    let rootView = ChatProfileSwiftUIRootView(
      profileName: resolvedName,
      username: resolvedUsername,
      note: profileBio.trimmingCharacters(in: .whitespacesAndNewlines),
      isChatMuted: isChatMuted,
      isDark: effectiveIsDark,
      historySubtitle: latestChatHistorySubtitle(),
      historyItems: swiftUIHistoryItems(),
      tabSummaries: swiftUITabSummaries(),
      tabItems: swiftUITabItems(),
      appearanceSelection: currentAppearanceSelection(resolvedName: resolvedName),
      hasProfileImage: hasResolvedProfileImage,
      avatarUri: resolvedAvatarImageUriForSwiftUI(),
      safeAreaTop: resolvedSafeAreaTop(),
      isGroupOrChannel: isGroupOrChannel,
      isChannel: isChannel,
      isGroupOwner: isGroupOwner,
      memberCount: groupMemberCount ?? (groupMembers.isEmpty ? nil : groupMembers.count),
      groupMembersSubtitle: groupMembersSummary(),
      // Groups always expose the roster. Channels keep it for owner/admin control
      // (Administrators & subscribers); non-admin channel viewers only see a count.
      groupMembers: (isChannel && !canManageGroupMembers) ? [] : groupMembers,
      canManageGroupMembers: canManageGroupMembers,
      groupBridgeProvider: groupBridgeProviderFromMembers(),
      groupBridgeProviders: groupBridgeProvidersFromMembers(),
      selectedRepositoryName: AgentBridgeSelectionStore.selectedRepository(
        chatId: engineChatId.isEmpty ? nil : engineChatId
      )?.name,
      bridgeProvider: bridgeProvider,
      bridgeChatId: engineChatId,
      chatId: engineChatId,
      bridgeConnected: bridgeConnected,
      bridgePaired: bridgePaired,
      bridgeDeviceLabel: bridgeDeviceLabel,
      bridgeRunningTasks: bridgeRunningTasks,
      channelAccessType: channelAccessType,
      channelPublicSlug: channelPublicSlug,
      channelShareLink: channelShareLink,
      channelJoinApprovalRequired: channelJoinApprovalRequired,
      channelRestrictSavingContent: channelRestrictSavingContent,
      channelSubscriberCount: channelSubscriberCount,
      onScroll: { [weak self] offset in
        guard let self else { return }
        self.swiftUIScrollOffset = offset
        self.updateAvatarMorphProgress()
      },
      onNavigationActiveChanged: { [weak self] active in
        guard let self else { return }
        self.swiftUINavigationActive = active
        self.setNeedsLayout()
      },
      onCopyUsername: { [weak self] in
        guard let self else { return }
        let username = self.resolvedIdentifierRawValue().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { return }
        UIPasteboard.general.string = username
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        self.onNativeEvent(["type": "agentToast", "message": "Username copied"])
      },
      onAction: { [weak self] action in
        self?.handleSwiftUIProfileAction(action)
      },
      onSaveAppearance: { [weak self] selection in
        guard let self else { return }
        self.saveCurrentAppearance(selection, resolvedName: resolvedName)
      },
      onContentPressed: { [weak self] payload in
        self?.onNativeEvent(payload)
      },
      onMembersAdded: { [weak self] added in
        guard let self else { return }
        let existingIds = Set(self.groupMembers.compactMap { $0["userId"] as? String })
        let newOnes = added.filter { entry in
          guard let uid = entry["userId"] as? String else { return false }
          return !existingIds.contains(uid)
        }
        guard !newOnes.isEmpty else { return }
        self.setGroupMembers(self.groupMembers + newOnes)
        self.renderSwiftUIProfile()
      },
      onMembersScreenAppeared: { [weak self] in
        self?.refreshGroupMembersFromHome(reason: "membersScreen")
      }
    )
    let erasedRoot = AnyView(rootView)

    if let host = swiftUIHostingController {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        host.rootView = erasedRoot
      }
      host.view.backgroundColor = ChatListAppearance.current.wallpaperBase
      host.view.frame = swiftUIContainerView.bounds
      swiftUIContainerView.bringSubviewToFront(host.view)
    } else {
      let host = UIHostingController(rootView: erasedRoot)
      // Pre-paint the page color so the push never flashes a black or white plate.
      host.view.backgroundColor = ChatListAppearance.current.wallpaperBase
      host.view.isOpaque = true
      host.view.frame = swiftUIContainerView.bounds
      host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      swiftUIContainerView.addSubview(host.view)
      swiftUIContainerView.bringSubviewToFront(host.view)
      swiftUIHostingController = host
      attachSwiftUIHostIfNeeded()
    }
  }

  private func currentAppearanceSelection(resolvedName: String? = nil) -> ChatProfileAppearanceSelection {
    ChatProfileAppearanceStore.selection(
      title: resolvedName ?? (profileName.isEmpty ? headerTitle : profileName),
      peerUserId: enginePeerUserId,
      chatId: engineChatId
    )
  }

  private func saveCurrentAppearance(
    _ selection: ChatProfileAppearanceSelection,
    resolvedName: String? = nil
  ) {
    let name = resolvedName ?? (profileName.isEmpty ? headerTitle : profileName)
    ChatProfileAppearanceStore.save(
      selection,
      title: name,
      peerUserId: enginePeerUserId,
      chatId: engineChatId
    )
    applyTheme()
    refreshAvatar()
    renderSwiftUIProfile()
    setNeedsLayout()
    updateAvatarMorphProgress()
    onNativeEvent(["type": "profileAppearanceUpdated"])
  }

  private var hasResolvedProfileImage: Bool {
    let rawAvatarHasValue =
      avatarUri?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    let hasPushAvatar =
      !isGroupOrChannel && !enginePeerUserId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return rawAvatarHasValue || hasPushAvatar
  }

  private func resolvedAvatarImageUriForSwiftUI() -> String? {
    let rawAvatar = avatarUri
    let preferPushAvatar = !isGroupOrChannel
    return ChatAvatarURLResolver.resolve(
      rawAvatar: rawAvatar,
      peerUserId: enginePeerUserId,
      chatId: engineChatId,
      preferPushAvatar: preferPushAvatar
    )
  }

  private func handleSwiftUIProfileAction(_ action: String) {
    switch action {
    case "muteToggle":
      handleMutePressed()
    case "search":
      handleSearchPressed()
    case "audio":
      handleAudioPressed()
    case "video":
      handleVideoPressed()
    case "bridgeConnection":
      presentBridgeConnection()
    case let value where value.hasPrefix("bridgeRepository:"):
      let provider = String(value.dropFirst("bridgeRepository:".count))
      onNativeEvent(["type": "openAgentPanel", "provider": provider])
    case "agentConfig":
      presentAgentConfigEditor()
    case "headerBack":
      handleBackPressed()
    case "addContact", "shareContact", "createNewContact", "addToExisting":
      onNativeEvent(["type": "profileContactAction", "action": action])
    case "addToEmergency":
      onNativeEvent(["type": "profileContactAction", "action": "addToEmergency"])
    case "clearChat":
      // Same event the chat-header / UIKit menu already emit. Host presents
      // "Clear just for me" vs "Clear for me and …" and drives engine + core.
      onNativeEvent(["type": "headerMenuAction", "action": "clearChat"])
    case "block":
      onNativeEvent(["type": "profileContactAction", "action": "block"])
    case "editGroup", "leaveGroup", "deleteGroup", "reportRoom":
      onNativeEvent([
        "type": "profileGroupAction",
        "action": action,
        "chatId": engineChatId,
        "name": profileName,
        "avatarUri": resolvedAvatarImageUriForSwiftUI() ?? "",
        "description": profileBio,
        // Sheet titles (Edit Channel vs Edit Group) must not depend only on
        // ChatRoute — that can lag a stale home row without type/isChannel.
        "isChannel": isChannel,
        // Prefer full-page edit inside the profile NavigationStack when available.
        "preferPage": true,
      ])
    case let value where value.hasPrefix("channelDescription:"):
      let desc = String(value.dropFirst("channelDescription:".count))
      setProfileBio(desc)
    case let value where value.hasPrefix("roomEdited:"):
      let name = String(value.dropFirst("roomEdited:".count))
      if !name.isEmpty {
        setProfileName(name)
        setHeaderTitle(name)
      }
      renderSwiftUIProfile()
    case let value where value.hasPrefix("roomAvatar:"):
      let url = String(value.dropFirst("roomAvatar:".count))
      if !url.isEmpty {
        setAvatarUri(url)
      }
    case "openMembers":
      presentGroupMembersUIKit()
    case "channelLink":
      onNativeEvent([
        "type": "channelLink",
        "chatId": engineChatId,
        "shareLink": channelShareLink,
        "publicSlug": channelPublicSlug,
        "accessType": channelAccessType,
      ])
    case "channelAgents":
      onNativeEvent([
        "type": "channelAgents",
        "chatId": engineChatId,
      ])
    case let value where value.hasPrefix("channelSetting:"):
      // Format: channelSetting:<setting>:<0|1>
      let body = String(value.dropFirst("channelSetting:".count))
      let parts = body.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      let setting = parts.first.map(String.init) ?? ""
      let rawValue = parts.count > 1 ? String(parts[1]) : ""
      let boolValue = rawValue == "1" || rawValue.lowercased() == "true"
      if setting == "joinApprovalRequired" {
        channelJoinApprovalRequired = boolValue
      } else if setting == "restrictSavingContent" {
        channelRestrictSavingContent = boolValue
      }
      onNativeEvent([
        "type": "channelSetting",
        "chatId": engineChatId,
        "setting": setting,
        "value": boolValue,
      ])
    default:
      break
    }
  }

  /// Crash-safe members screen: UIKit push (not SwiftUI NavigationStack destination).
  private func presentGroupMembersUIKit() {
    // Non-admin channel viewers don't get a roster; owner/admin open Channel control.
    if isChannel, !canManageGroupMembers {
      NSLog(
        "[WhoAmI] MembersUIKit.present skipped — channel non-admin chatId=%@",
        String(engineChatId.prefix(12)))
      return
    }
    let sample = groupMembers.prefix(6).compactMap { entry -> String? in
      let id =
        (entry["userId"] as? String)
        ?? (entry["user_id"] as? String)
        ?? (entry["id"] as? String)
        ?? "?"
      let role = (entry["role"] as? String) ?? (entry["memberRole"] as? String) ?? "?"
      let name = (entry["name"] as? String) ?? (entry["username"] as? String) ?? ""
      return "\(String(id.prefix(6))):\(role):\(String(name.prefix(12)))"
    }.joined(separator: " ")
    NSLog(
      "[WhoAmI] MembersUIKit.present chatId=%@ members=%d canManage=%@ sample=[%@]",
      engineChatId.isEmpty ? "<none>" : String(engineChatId.prefix(12)),
      groupMembers.count,
      canManageGroupMembers ? "Y" : "N",
      sample
    )

    // If roster empty, kick a home refresh first, then present (or re-present).
    if groupMembers.isEmpty {
      refreshGroupMembersFromHome(reason: "openMembersUIKit")
    }

    let items = chatProfileMemberItems(from: groupMembers)

    let controller = ChatGroupMembersViewController()
    controller.chatId = engineChatId
    controller.members = items
    controller.canAddMembers = canManageGroupMembers
    controller.onAddMembers = { [weak self] in
      self?.pushAddGroupMembersPicker()
    }
    controller.onMemberSelected = { [weak self] item in
      self?.onNativeEvent([
        "type": "groupMemberTapped",
        "userId": item.userId,
        "role": item.roleLabel.lowercased(),
        "name": item.name,
        "avatarUri": item.avatarUri ?? "",
        "canManage": self?.canManageGroupMembers ?? false,
      ])
    }
    controller.onPromote = { [weak self] item in
      self?.onNativeEvent([
        "type": "groupMemberTapped",
        "userId": item.userId,
        "role": "member",
        "name": item.name,
        "action": "promote",
        "canManage": true,
      ])
    }
    controller.onDemote = { [weak self] item in
      self?.onNativeEvent([
        "type": "groupMemberTapped",
        "userId": item.userId,
        "role": "admin",
        "name": item.name,
        "action": "demote",
        "canManage": true,
      ])
    }
    controller.onRemove = { [weak self] item in
      self?.onNativeEvent([
        "type": "groupMemberTapped",
        "userId": item.userId,
        "role": item.roleLabel.lowercased(),
        "name": item.name,
        "action": "remove",
        "canManage": true,
      ])
    }

    guard let presenter = topMostViewController() else {
      NSLog("[WhoAmI] MembersUIKit.present failed — no presenter")
      return
    }
    if let nav = presenter.navigationController {
      nav.pushViewController(controller, animated: true)
    } else if let nav = (presenter as? UINavigationController) {
      nav.pushViewController(controller, animated: true)
    } else {
      // Last resort: wrap in nav and present full screen (still not a sheet picker).
      let navigation = UINavigationController(rootViewController: controller)
      navigation.modalPresentationStyle = .fullScreen
      presenter.present(navigation, animated: true)
    }
  }

  /// Material pageSheet for add-members (same family as Edit Group / Vibe sheets).
  private func pushAddGroupMembersPicker() {
    guard let config = AppSessionConfig.current else { return }
    guard let presenter = topMostViewController() else { return }
    let excluded = Set(
      groupMembers.compactMap { entry -> String? in
        (entry["userId"] as? String)
          ?? (entry["id"] as? String)
          ?? (entry["memberId"] as? String)
          ?? (entry["user_id"] as? String)
      }
    )
    let sheet = AddGroupMembersSheet(
      config: config,
      chatId: engineChatId,
      excludedUserIds: excluded,
      homeRows: ChatHomeService.cachedRows(config: config),
      onAdded: { [weak self] added in
        guard let self else { return }
        let existingIds = Set(
          self.groupMembers.compactMap {
            ($0["userId"] as? String) ?? ($0["user_id"] as? String) ?? ($0["id"] as? String)
          }
        )
        let newOnes = added.filter { entry in
          guard let uid = entry["userId"] as? String else { return false }
          return !existingIds.contains(uid)
        }
        if !newOnes.isEmpty {
          self.setGroupMembers(self.groupMembers + newOnes)
        }
      }
    )
    let host = UIHostingController(rootView: sheet)
    // Clear host so system pageSheet glass refracts the profile (chat progress/ask style).
    host.view.backgroundColor = .clear
    host.modalPresentationStyle = .pageSheet
    if let sheetCtrl = host.sheetPresentationController {
      sheetCtrl.detents = [.medium(), .large()]
      sheetCtrl.prefersGrabberVisible = true
      sheetCtrl.preferredCornerRadius = 22
    }
    presenter.present(host, animated: true)
  }

  private func swiftUITabSummaries() -> [ChatProfileSwiftUITabSummary] {
    availableTabs.map {
      ChatProfileSwiftUITabSummary(
        tab: $0,
        title: sharedTitle(for: $0),
        subtitle: sharedSubtitle(for: $0)
      )
    }
  }

  private func swiftUITabItems() -> [ChatProfileTab: [ChatProfileSwiftUIContentItem]] {
    var result: [ChatProfileTab: [ChatProfileSwiftUIContentItem]] = [:]
    for tab in availableTabs {
      result[tab] = swiftUIContentItems(for: tab)
    }
    return result
  }

  private func swiftUIHistoryItems() -> [ChatProfileSwiftUIContentItem] {
    rows.enumerated().map { index, row in
      swiftUIContentItem(for: row, tab: nil, index: index, explicitURL: nil)
    }
  }

  private func swiftUIContentItems(for tab: ChatProfileTab) -> [ChatProfileSwiftUIContentItem] {
    switch tab {
    case .media:
      return mediaRows.enumerated().map { index, row in
        swiftUIContentItem(for: row, tab: tab, index: index, explicitURL: row.mediaUrl)
      }
    case .music:
      return musicRows.enumerated().map { index, row in
        swiftUIContentItem(for: row, tab: tab, index: index, explicitURL: row.mediaUrl)
      }
    case .voice:
      return voiceRows.enumerated().map { index, row in
        swiftUIContentItem(for: row, tab: tab, index: index, explicitURL: row.mediaUrl)
      }
    case .gifs:
      return gifRows.enumerated().map { index, row in
        swiftUIContentItem(for: row, tab: tab, index: index, explicitURL: row.mediaUrl)
      }
    case .files:
      return fileRows.enumerated().map { index, row in
        swiftUIContentItem(for: row, tab: tab, index: index, explicitURL: row.mediaUrl)
      }
    case .links:
      return linkRows.enumerated().map { index, item in
        swiftUIContentItem(for: item.row, tab: tab, index: index, explicitURL: item.url)
      }
    case .pinned:
      return pinnedRows.enumerated().map { index, row in
        swiftUIContentItem(for: row, tab: tab, index: index, explicitURL: row.mediaUrl)
      }
    }
  }

  private func swiftUIContentItem(
    for row: ChatProfileRow,
    tab: ChatProfileTab?,
    index: Int,
    explicitURL: String?
  ) -> ChatProfileSwiftUIContentItem {
    let resolvedTab = tab?.rawValue ?? "history"
    let title: String = {
      if let explicitURL, tab == .links {
        return explicitURL
      }
      if let fileName = row.fileName?.trimmingCharacters(in: .whitespacesAndNewlines), !fileName.isEmpty {
        return fileName
      }
      let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty {
        return text
      }
      switch row.type {
      case "image":
        return "Photo"
      case "video":
        return "Video"
      case "voice":
        return "Voice message"
      case "music":
        return "Music"
      case "file":
        return "File"
      default:
        return row.type.isEmpty ? "Message" : row.type.capitalized
      }
    }()

    let durationText: String? = {
      guard let duration = row.duration, duration.isFinite, duration > 0 else { return nil }
      let seconds = Int(duration.rounded())
      return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }()
    let subtitleParts: [String] = {
      if tab == .music {
        return [row.musicArtist, durationText, formattedRowDate(row)].compactMap { $0 }
      }
      return [row.type.isEmpty ? nil : row.type.capitalized, formattedRowDate(row)]
        .compactMap { $0 }
    }()

    var payload: [String: Any] = [
      "type": "profileContentPressed",
      "tab": resolvedTab,
      "messageId": row.messageId,
    ]
    if let explicitURL, !explicitURL.isEmpty {
      payload["url"] = explicitURL
    } else if let mediaURL = row.resolvedMediaURL, !mediaURL.isEmpty {
      payload["url"] = mediaURL
    }
    if let mediaKey = row.mediaKey, !mediaKey.isEmpty {
      payload["mediaKey"] = mediaKey
    }
    let displayName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
    let senderName =
      !displayName.isEmpty && !Self.looksLikeUUID(displayName)
        && displayName.caseInsensitiveCompare("User") != .orderedSame
      ? displayName : resolvedIdentifierRawValue()
    if !senderName.isEmpty {
      payload["senderName"] = senderName
    }

    return ChatProfileSwiftUIContentItem(
      id: "\(resolvedTab)-\(row.messageId)-\(index)",
      title: title,
      subtitle: subtitleParts.joined(separator: " • "),
      systemImage: swiftUIContentSystemImage(for: tab, row: row),
      payload: payload,
      kind: row.type,
      mediaURL: row.resolvedMediaURL,
      mediaKey: row.mediaKey,
      thumbnailBase64: row.thumbnailBase64,
      isVideo: row.type == "video",
      duration: row.duration,
      artist: row.musicArtist,
      source: row.musicSource,
      coverURL: row.musicCoverURL,
      detail: row.text
    )
  }

  private func swiftUIContentSystemImage(for tab: ChatProfileTab?, row: ChatProfileRow) -> String {
    if let tab {
      return sharedIconName(for: tab)
    }
    switch row.type {
    case "image", "video", "sticker":
      return "photo.on.rectangle.angled"
    case "voice":
      return "waveform"
    case "file", "music":
      return "doc.text.fill"
    default:
      return "message"
    }
  }

  private func configureHeroHeaderView() {
    heroHeaderView.backgroundColor = .clear
    heroHeaderView.clipsToBounds = false

    heroBannerView.clipsToBounds = true
    heroBannerView.layer.cornerCurve = .continuous
    heroBannerView.layer.cornerRadius = 26.0
    heroHeaderView.addSubview(heroBannerView)

    heroNameLabel.font = UIFont.systemFont(ofSize: 30.0, weight: .bold)
    heroNameLabel.textAlignment = .center
    heroBannerView.addSubview(heroNameLabel)

    heroHandleButton.titleLabel?.font = UIFont.systemFont(ofSize: 18.0, weight: .medium)
    heroHandleButton.titleLabel?.lineBreakMode = .byTruncatingTail
    heroHandleButton.contentHorizontalAlignment = .center
    heroHandleButton.addTarget(
      self, action: #selector(handleIdentifierPressed), for: .touchUpInside)
    heroBannerView.addSubview(heroHandleButton)

    heroBioLabel.font = UIFont.systemFont(ofSize: 14.0, weight: .regular)
    heroBioLabel.textAlignment = .center
    heroBioLabel.numberOfLines = 0
    heroBannerView.addSubview(heroBioLabel)

    actionsStack.axis = .horizontal
    actionsStack.distribution = .equalSpacing
    actionsStack.alignment = .center
    actionsStack.spacing = 12.0
    actionsStack.semanticContentAttribute = .forceLeftToRight
    actionsStack.isLayoutMarginsRelativeArrangement = true
    actionsStack.layoutMargins = UIEdgeInsets(top: 0.0, left: 8.0, bottom: 0.0, right: 8.0)
    heroHeaderView.addSubview(actionsStack)

    muteActionButton.addTarget(self, action: #selector(handleMutePressed), for: .touchUpInside)
    searchActionButton.addTarget(self, action: #selector(handleSearchPressed), for: .touchUpInside)
    audioActionButton.addTarget(self, action: #selector(handleAudioPressed), for: .touchUpInside)
    videoActionButton.addTarget(self, action: #selector(handleVideoPressed), for: .touchUpInside)

    [muteActionButton, searchActionButton, audioActionButton, videoActionButton].forEach { button in
      button.translatesAutoresizingMaskIntoConstraints = false
      actionsStack.addArrangedSubview(button)
      // Priority 999 (not required): this stack lives in a tableHeaderView, which
      // AutoLayout sizes to 0×0 for a transient pass before the header gets its real
      // width. At width 0, four REQUIRED 68pt buttons + spacing + margins are
      // unsatisfiable → the "Unable to simultaneously satisfy constraints" storm. At
      // 999 AutoLayout can momentarily collapse them for that pass, then restore the
      // exact 68×70 once the header has a real width — same final layout, no console spam.
      let widthConstraint = button.widthAnchor.constraint(equalToConstant: 68.0)
      let heightConstraint = button.heightAnchor.constraint(equalToConstant: 70.0)
      widthConstraint.priority = .defaultHigh + 1
      heightConstraint.priority = .defaultHigh + 1
      NSLayoutConstraint.activate([widthConstraint, heightConstraint])
    }

    tableView.tableHeaderView = heroHeaderView
  }

  private func layoutHeroHeaderViewIfNeeded(force: Bool) {
    guard tableView.bounds.width > 0 else { return }

    let width = tableView.bounds.width
    let sideInset: CGFloat = 16.0
    let bannerTop: CGFloat = 0.0
    let baseBannerHeight = min(max(bounds.height * 0.50, 390.0), 500.0)
    let stretch: CGFloat = 0.0
    let bannerHeight = baseBannerHeight + stretch
    let bannerFrame = CGRect(
      x: sideInset, y: bannerTop, width: width - (sideInset * 2.0), height: bannerHeight)
    heroBannerView.frame = bannerFrame

    var y =
      currentHeroTop
      + NativeProfileAvatarHeroMetrics.expandedSize
      + NativeProfileAvatarHeroMetrics.bottomSpacing

    let nameHeight: CGFloat = 36.0
    heroNameLabel.frame = CGRect(
      x: 12.0, y: y, width: heroBannerView.bounds.width - 24.0, height: nameHeight)
    y = heroNameLabel.frame.maxY + 18.0

    let handleHeight: CGFloat = 24.0
    heroHandleButton.frame = CGRect(
      x: 12.0, y: y, width: heroBannerView.bounds.width - 24.0, height: handleHeight)
    y = heroHandleButton.isHidden ? y : heroHandleButton.frame.maxY + 8.0

    let bioText = heroBioLabel.text ?? ""
    let bioVisible = !bioText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let maxBioWidth = heroBannerView.bounds.width - 26.0
    let bioHeight: CGFloat = {
      guard bioVisible else { return 0.0 }
      let size = CGSize(width: maxBioWidth, height: CGFloat.greatestFiniteMagnitude)
      let rect = (bioText as NSString).boundingRect(
        with: size,
        options: [.usesLineFragmentOrigin, .usesFontLeading],
        attributes: [.font: heroBioLabel.font as Any],
        context: nil
      )
      return ceil(max(20.0, rect.height))
    }()

    heroBioLabel.isHidden = !bioVisible
    if bioVisible {
      heroBioLabel.frame = CGRect(x: 13.0, y: y, width: maxBioWidth, height: bioHeight)
      y = heroBioLabel.frame.maxY + 14.0
    }

    let actionsHeight: CGFloat = 74.0
    let actionsWidth = min(width - 44.0, 360.0)
    let actionsTop = max(
      heroHandleButton.isHidden ? heroNameLabel.frame.maxY : heroHandleButton.frame.maxY,
      heroBioLabel.isHidden ? 0.0 : heroBioLabel.frame.maxY
    ) + 22.0
    actionsStack.frame = CGRect(
      x: (width - actionsWidth) * 0.5,
      y: actionsTop,
      width: actionsWidth,
      height: actionsHeight
    )
    actionsStack.alpha = 1.0
    actionsStack.transform = .identity

    let actionBottom = actionsStack.frame.maxY

    let finalHeaderHeight = max(heroBannerView.frame.maxY + 24.0, actionBottom + 28.0)

    if force || heroHeaderView.frame.width != width
      || abs(heroHeaderView.frame.height - finalHeaderHeight) > 0.5
    {
      heroHeaderView.frame = CGRect(x: 0.0, y: 0.0, width: width, height: finalHeaderHeight)
      tableView.tableHeaderView = heroHeaderView
    }
  }

  private func updateAvatarMetrics() {
    let topInset = safeAreaInsets.top
    currentHeroTop = NativeProfileAvatarHeroMetrics.expandedTop(for: topInset)
    currentCollapsedTop = NativeProfileAvatarHeroMetrics.collapsedTop(for: topInset)

    floatingAvatarView.setExpandedSize(NativeProfileAvatarHeroMetrics.expandedSize)
    floatingAvatarView.setCollapsedSize(NativeProfileAvatarHeroMetrics.collapsedSize)
    floatingAvatarView.setExpandedTopInset(currentHeroTop)
    floatingAvatarView.setCollapsedTopInset(currentCollapsedTop)
  }

  private func layoutFloatingAvatarView() {
    guard bounds.width > 0 else { return }
    let hostHeight = NativeProfileAvatarHeroMetrics.hostHeight(for: safeAreaInsets.top)

    floatingAvatarView.frame = CGRect(
      x: 0.0,
      y: 0.0,
      width: bounds.width,
      height: hostHeight
    )
    updateAvatarMetrics()
  }

  private func layoutAvatarGlassRing() {
    guard bounds.width > 0 else { return }

    let expandedSize = NativeProfileAvatarHeroMetrics.expandedSize
    let ringPadding: CGFloat = 14.0

    let offset = max(0.0, swiftUIScrollOffset)
    let progress = max(0.0, min(1.0, offset / 220.0))

    let currentSize = expandedSize - (22.0 * progress)
    let ringSize = currentSize + ringPadding

    let centerX = bounds.width * 0.5
    let centerY = currentHeroTop + expandedSize * 0.5 - (10.0 * progress)

    avatarGlassRing.frame = CGRect(
      x: centerX - ringSize * 0.5,
      y: centerY - ringSize * 0.5,
      width: ringSize,
      height: ringSize
    )
    avatarGlassRing.layer.cornerRadius = ringSize * 0.5

    avatarGlassRing.isHidden = true
    avatarGlassRing.alpha = 0.0
  }

  private func layoutActionsForCurrentScroll() {
    layoutHeroHeaderViewIfNeeded(force: false)
  }

  private func applyTheme() {
    let isDark = traitCollection.userInterfaceStyle == .dark
    let resolvedName = profileName.isEmpty ? headerTitle : profileName
    let posterColors = ChatProfileAppearanceStore.posterColors(
      title: resolvedName,
      peerUserId: enginePeerUserId,
      chatId: engineChatId
    )
    let posterTop = posterColors.0
    let posterBottom = posterColors.1
    let posterMid = posterTop.blended(withFraction: 0.42, of: posterBottom)

    backgroundGradientLayer.colors = [
      posterTop.cgColor,
      posterMid.cgColor,
      posterBottom.cgColor,
    ]
    backgroundGradientLayer.locations = [0.0, 0.48, 1.0]

    if let posterImage = ChatProfileAppearanceStore.posterImage(
      title: resolvedName,
      peerUserId: enginePeerUserId,
      chatId: engineChatId
    )?.cgImage {
      posterImageLayer.contents = posterImage
      posterImageLayer.opacity = isDark ? 0.54 : 0.42
    } else {
      posterImageLayer.contents = nil
      posterImageLayer.opacity = 0.0
    }

    let background = UIColor.clear // gradient handles background
    let text = isDark ? UIColor.white : UIColor.black
    let secondary = isDark ? UIColor(white: 0.72, alpha: 1.0) : UIColor(white: 0.44, alpha: 1.0)
    let card =
      isDark
      ? UIColor(red: 43.0 / 255.0, green: 50.0 / 255.0, blue: 58.0 / 255.0, alpha: 0.44)
      : UIColor.white.withAlphaComponent(0.72)
    let rowAccent =
      isDark
      ? UIColor(red: 77 / 255, green: 217 / 255, blue: 229 / 255, alpha: 1.0)
      : UIColor(red: 0 / 255, green: 122 / 255, blue: 124 / 255, alpha: 1.0)
    let fallbackAvatarColors = ChatProfileAppearanceStore.avatarColors(
      title: resolvedName,
      peerUserId: enginePeerUserId,
      chatId: engineChatId
    )
    let fallbackAvatarIconTint = text

    backgroundColor = background
    headerContainer.backgroundColor = .clear
    headerMaskContainer.backgroundColor = .clear
    headerMaskBlurView.effect = { () -> UIVisualEffect? in
      if #available(iOS 26.0, *) {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = true
        return effect
      }
      return UIBlurEffect(style: isDark ? .systemMaterialDark : .systemMaterialLight)
    }()
    headerMaskOverlayView.backgroundColor =
      (isDark ? UIColor.black : UIColor.white).withAlphaComponent(isDark ? 0.12 : 0.10)

    titleLabel.textColor = text
    subtitleLabel.textColor = secondary
    backButton.tintColor = text
    menuButton.tintColor = text

    tableView.backgroundColor = .clear
    tableView.tintColor = .systemBlue
    tableView.separatorColor =
      isDark
      ? UIColor(white: 1.0, alpha: 0.08)
      : UIColor(white: 0.0, alpha: 0.08)

    heroNameLabel.textColor = text
    heroHandleButton.setTitleColor(secondary, for: .normal)
    heroBioLabel.textColor = secondary
    heroBannerView.backgroundColor = .clear

    // Use a dark base for the island cover so avatar morph blends into gradient
    floatingAvatarView.setIslandCoverUIColor(posterTop)
    floatingAvatarView.setFallbackGradientUIColors(
      start: fallbackAvatarColors.0,
      end: fallbackAvatarColors.1
    )
    floatingAvatarView.setFallbackIconTintUIColor(fallbackAvatarIconTint)

    // Avatar glass ring effect
    if isDark {
      avatarGlassRing.effect = UIBlurEffect(style: .systemThinMaterialDark)
      avatarGlassRing.contentView.backgroundColor = .clear
    } else {
      avatarGlassRing.effect = UIBlurEffect(style: .systemThinMaterialLight)
      avatarGlassRing.contentView.backgroundColor = .clear
    }

    currentTextColor = text
    currentSecondaryTextColor = secondary
    currentRowSeparatorColor =
      isDark
      ? UIColor(white: 1.0, alpha: 0.08)
      : UIColor(white: 0.0, alpha: 0.08)
    currentRowHighlightColor =
      isDark
      ? UIColor(white: 1.0, alpha: 0.06)
      : UIColor(white: 0.0, alpha: 0.04)
    currentRowCardColor =
      isDark
      ? UIColor(red: 53.0/255.0, green: 62.0/255.0, blue: 72.0/255.0, alpha: 0.34)
      : UIColor.white.withAlphaComponent(0.68)
    currentRowAccentColor = rowAccent
    currentRowIconBackgroundColor = rowAccent.withAlphaComponent(0.12)

    [muteActionButton, searchActionButton, audioActionButton, videoActionButton].forEach {
      $0.applyTheme(foreground: text, background: card, isDark: isDark)
    }
    configureBackButtonStyle()

    reloadDataKeepingSelection()
  }

  private func resolvedDefaultSubtitleText() -> String {
    if isOnline {
      return "Online"
    }

    if !headerSubtitle.isEmpty {
      return headerSubtitle
    }

    if isGroupOrChannel {
      return isChannel ? "Channel Profile" : "Group Profile"
    }
    return "Profile"
  }

  private func resolvedActiveTabSubtitleText() -> String? {
    return nil
  }


  private func reloadHeaderText() {
    let resolvedName =
      profileName.isEmpty ? (headerTitle.isEmpty ? "Profile" : headerTitle) : profileName
    titleLabel.text = resolvedName
    subtitleLabel.text = resolvedActiveTabSubtitleText() ?? resolvedDefaultSubtitleText()
    renderSwiftUIProfile()
  }

  private func refreshHeroSubheader() {
    heroHandleButton.setTitle(nil, for: .normal)
    heroHandleButton.isHidden = true
  }

  private func refreshHeroContent() {
    let resolvedName =
      profileName.isEmpty ? (headerTitle.isEmpty ? "User" : headerTitle) : profileName
    heroNameLabel.text = resolvedName
    floatingAvatarView.setFallbackText(resolvedAvatarFallbackText())

    refreshHeroSubheader()

    let bio = profileBio.trimmingCharacters(in: .whitespacesAndNewlines)
    heroBioLabel.text = bio

    updateActionButtons()
    layoutHeroHeaderViewIfNeeded(force: true)
    renderSwiftUIProfile()
  }

  private func updateActionButtons() {
    muteActionButton.configure(
      title: isChatMuted ? "Unmute" : "Mute", symbol: isChatMuted ? "bell" : "bell.slash")
    searchActionButton.configure(title: "Search", symbol: "magnifyingglass")
    audioActionButton.configure(title: "Call", symbol: "phone")
    videoActionButton.configure(title: "Video", symbol: "video")
  }

  private func configureBackButtonStyle() {
    let symbol = UIImage(
      systemName: "chevron.left",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 18.0, weight: .semibold)
    )

    if #available(iOS 26.0, *) {
      var config = UIButton.Configuration.glass()
      config.cornerStyle = .capsule
      config.image = symbol
      config.contentInsets = NSDirectionalEdgeInsets(
        top: 10.0, leading: 10.0, bottom: 10.0, trailing: 10.0)
      backButton.configuration = config
      return
    }

    backButton.configuration = nil
    backButton.setImage(symbol, for: .normal)
    backButton.backgroundColor = UIColor.secondarySystemGroupedBackground.withAlphaComponent(0.92)
    backButton.layer.cornerRadius = 21.0
    backButton.layer.cornerCurve = .continuous
  }

  private func updateAvatarMorphProgress() {
    guard bounds.width > 0 else { return }

    let offset = max(0.0, swiftUIScrollOffset)
    let progress = max(0.0, min(1.0, offset / 220.0))
    avatarMorphProgress = progress
    floatingAvatarView.setScrollOffset(offset)
    headerMaskContainer.alpha = 0.0
    headerMaskContainer.isHidden = true
    titleLabel.isHidden = true
    subtitleLabel.isHidden = true
    titleLabel.alpha = 0.0
    subtitleLabel.alpha = 0.0
    layoutActionsForCurrentScroll()

    layoutAvatarGlassRing()
  }

  private func refreshAvatar() {
    avatarResolveGeneration &+= 1
    let generation = avatarResolveGeneration
    floatingAvatarView.setFallbackText(resolvedAvatarFallbackText())
    let fallbackColors = ChatProfileAppearanceStore.avatarColors(
      title: profileName.isEmpty ? headerTitle : profileName,
      peerUserId: enginePeerUserId,
      chatId: engineChatId
    )
    floatingAvatarView.setFallbackGradientUIColors(
      start: fallbackColors.0,
      end: fallbackColors.1
    )
    floatingAvatarView.setFallbackIconTintUIColor(.white)

    let rawAvatar = avatarUri
    let peerUserId = enginePeerUserId
    let chatId = engineChatId
    let preferPushAvatar = !isGroupOrChannel
    let hasRawAvatar =
      rawAvatar?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    let hasPeerUser = !peerUserId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard hasRawAvatar || (preferPushAvatar && hasPeerUser) else {
      // No single avatar. For a group we compose the SAME member-mosaic the home
      // list shows (from the members' avatar URLs we already have) rather than
      // dropping to a bare initials tile.
      if isGroupOrChannel {
        loadGroupCompositeAvatar(generation: generation)
      } else {
        floatingAvatarView.setImageUri(nil)
      }
      return
    }

    DispatchQueue.global(qos: .utility).async { [rawAvatar, peerUserId, chatId, preferPushAvatar, generation] in
      let resolvedUri = ChatAvatarURLResolver.resolve(
        rawAvatar: rawAvatar,
        peerUserId: peerUserId,
        chatId: chatId,
        preferPushAvatar: preferPushAvatar
      )
      DispatchQueue.main.async { [weak self] in
        guard let self, self.avatarResolveGeneration == generation else { return }
        self.floatingAvatarView.setImageUri(resolvedUri)
      }
    }
  }

  /// Build the group mosaic hero from the current members and show it. Falls back
  /// to the initials tile when there aren't at least two members with avatars.
  /// Guarded by `avatarResolveGeneration` so a stale build can't overwrite a newer
  /// avatar (e.g. after the group photo is set).
  private func loadGroupCompositeAvatar(generation: UInt) {
    let members = groupMembers
    let isDark = traitCollection.userInterfaceStyle == .dark
    guard GroupCompositeAvatar.slots(from: members).count >= 2 else {
      floatingAvatarView.setImageUri(nil)
      return
    }
    let side = NativeProfileAvatarHeroMetrics.expandedSize
    Task { [weak self] in
      let image = await GroupCompositeAvatar.composedImage(
        members: members, side: side, isDark: isDark)
      await MainActor.run {
        guard let self, self.avatarResolveGeneration == generation else { return }
        if let image {
          self.floatingAvatarView.setComposedImage(image)
        } else {
          self.floatingAvatarView.setImageUri(nil)
        }
      }
    }
  }

  private func resolvedAvatarFallbackText() -> String {
    let resolvedName =
      profileName.isEmpty ? (headerTitle.isEmpty ? "User" : headerTitle) : profileName
    let text = ChatAvatarNodeView.fallbackText(
      from: resolvedName,
      isGroupOrChannel: isGroupOrChannel
    )
    return text.isEmpty ? "U" : text
  }

  private func isImageOrVideoMediaURL(_ url: String) -> Bool {
    let lower = url.lowercased()
    let imageExt = [".jpg", ".jpeg", ".png", ".gif", ".webp", ".heic", ".heif"]
    let videoExt = [".mp4", ".mov", ".m4v", ".webm"]
    if imageExt.contains(where: { lower.contains($0) }) { return true }
    if videoExt.contains(where: { lower.contains($0) }) { return true }
    // Uploaded chat media URLs often omit extensions — treat non-audio paths as media.
    if lower.contains("/chat-media/") || lower.contains("/uploads/") { return true }
    return false
  }

  private func rebuildDerivedContent() {
    // Include anything with a real media URL / thumbnail, not only strict type tags —
    // agent-group image sends can arrive as image with durable thumbs after reopen.
    mediaRows = rows.filter { row in
      if ["image", "video", "sticker"].contains(row.type) { return true }
      if let url = row.mediaUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty,
        row.type != "voice", row.type != "music", row.type != "file"
      {
        return isImageOrVideoMediaURL(url) || row.thumbnailBase64?.isEmpty == false
      }
      if let thumb = row.thumbnailBase64?.trimmingCharacters(in: .whitespacesAndNewlines),
        !thumb.isEmpty, row.type != "voice"
      {
        return true
      }
      return false
    }
    voiceRows = rows.filter { $0.type == "voice" }
    gifRows = rows.filter { $0.type == "gif" }
    musicRows = rows.filter { $0.type == "music" }
    fileRows = rows.filter { $0.type == "file" }
    pinnedRows = rows.filter { $0.isPinned }

    let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    var links: [ChatProfileLinkItem] = []
    for row in rows {
      guard let detector else { continue }
      guard !row.isAgentMessage else { continue }
      guard !["file", "music", "voice", "image", "video", "sticker", "gif"].contains(row.type) else {
        continue
      }

      let trimmed = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.range(of: #"https?://|www\."#, options: [.regularExpression, .caseInsensitive]) != nil else {
        continue
      }
      let nsText = trimmed as NSString
      let matches = detector.matches(
        in: trimmed, options: [], range: NSRange(location: 0, length: nsText.length))
      if let first = matches.first?.url,
        let scheme = first.scheme?.lowercased(),
        ["http", "https"].contains(scheme)
      {
        links.append(ChatProfileLinkItem(row: row, url: first.absoluteString))
      }
    }
    linkRows = links

    var tabs: [ChatProfileTab] = []
    if !mediaRows.isEmpty { tabs.append(.media) }
    if !musicRows.isEmpty { tabs.append(.music) }
    if !voiceRows.isEmpty { tabs.append(.voice) }
    if !gifRows.isEmpty { tabs.append(.gifs) }
    if !fileRows.isEmpty { tabs.append(.files) }
    if !linkRows.isEmpty { tabs.append(.links) }
    if !pinnedRows.isEmpty { tabs.append(.pinned) }
    availableTabs = tabs
    if !availableTabs.contains(activeTab), let first = availableTabs.first {
      activeTab = first
    }
    reloadHeaderText()
    refreshHeroSubheader()
    syncTabViews()
  }


  private func sharedCount(for tab: ChatProfileTab) -> Int {
    switch tab {
    case .media:
      return mediaRows.count
    case .music:
      return musicRows.count
    case .voice:
      return voiceRows.count
    case .gifs:
      return gifRows.count
    case .files:
      return fileRows.count
    case .links:
      return linkRows.count
    case .pinned:
      return pinnedRows.count
    }
  }

  private func sharedTitle(for tab: ChatProfileTab) -> String {
    switch tab {
    case .media:
      return "Media"
    case .music:
      return "Music"
    case .voice:
      return "Voice"
    case .gifs:
      return "GIFs"
    case .files:
      return "Files"
    case .links:
      return "Links"
    case .pinned:
      return "Pinned"
    }
  }

  private func sharedSubtitle(for tab: ChatProfileTab) -> String {
    let count = sharedCount(for: tab)
    switch tab {
    case .media:
      return count == 1 ? "1 photo or video" : "\(count) photos and videos"
    case .music:
      return count == 1 ? "1 music file" : "\(count) music files"
    case .voice:
      return count == 1 ? "1 voice message" : "\(count) voice messages"
    case .gifs:
      return count == 1 ? "1 GIF" : "\(count) GIFs"
    case .files:
      return count == 1 ? "1 file" : "\(count) files"
    case .links:
      return count == 1 ? "1 shared link" : "\(count) shared links"
    case .pinned:
      return count == 1 ? "1 pinned message" : "\(count) pinned messages"
    }
  }

  private func sharedIconName(for tab: ChatProfileTab) -> String {
    switch tab {
    case .media:
      return "photo.on.rectangle.angled"
    case .music:
      return "music.note"
    case .voice:
      return "waveform"
    case .gifs:
      return "sparkles.tv"
    case .files:
      return "doc.text.fill"
    case .links:
      return "link"
    case .pinned:
      return "pin.fill"
    }
  }

  private func groupMembersSummary() -> String {
    let names = groupMembers.compactMap { member -> String? in
      let displayName =
        (member["name"] as? String)
        ?? (member["displayName"] as? String)
        ?? (member["username"] as? String)
        ?? (member["userId"] as? String)
      let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return trimmed.isEmpty ? nil : trimmed
    }
    guard !names.isEmpty else { return "View all participants" }
    return names.prefix(3).joined(separator: ", ")
  }

  private var canManageGroupMembers: Bool {
    guard isGroupOrChannel else { return false }
    let role = myGroupRole()
    return role == "owner" || role == "admin"
  }

  /// True when the signed-in user is the group's owner (creator). Owners see
  /// "Delete Group" instead of "Leave Group" and can manage admin roles.
  private var isGroupOwner: Bool {
    guard isGroupOrChannel else { return false }
    return myGroupRole() == "owner"
  }

  /// Resolved role for the signed-in user in this group. Prefers an explicit
  /// role on our member row; otherwise keeps the sticky role from home/list so
  /// incomplete payloads cannot flip admin ↔ member (or empty).
  private func myGroupRole() -> String {
    let me = engineMyUserId.trimmingCharacters(in: .whitespacesAndNewlines)
    if !me.isEmpty {
      let mine = groupMembers.first { entry in
        let id =
          (entry["userId"] as? String)
          ?? (entry["user_id"] as? String)
          ?? (entry["id"] as? String)
          ?? (entry["memberId"] as? String)
        return id?.caseInsensitiveCompare(me) == .orderedSame
      }
      let raw =
        (mine?["role"] as? String)
        ?? (mine?["memberRole"] as? String)
        ?? (mine?["member_role"] as? String)
        ?? (mine?["participantRole"] as? String)
        ?? ""
      let resolved = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if !resolved.isEmpty {
        stickyMyGroupRole = resolved
        return resolved
      }
    }
    return stickyMyGroupRole
  }

  /// Every bridge agent present in this group ("claude"/"codex"/"grok"), for the per-agent
  /// settings rows. `groupBridgeProviderFromMembers()` stays the single-value variant
  /// used by rows that only need to know "this group has agents at all".
  private func groupBridgeProvidersFromMembers() -> [String] {
    var providers: [String] = []
    for member in groupMembers {
      let values = [
        member["userId"],
        member["user_id"],
        member["id"],
        member["name"],
        member["displayName"],
        member["username"],
        member["handle"],
        member["label"]
      ]
      .compactMap { value -> String? in
        if let string = value as? String {
          return string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        if let number = value as? NSNumber {
          return number.stringValue.lowercased()
        }
        return nil
      }

      if values.contains("11111111-1111-1111-1111-111111111111")
        || values.contains("00000000-0000-0000-0000-0000000000c1")
        || values.contains("claude")
        || values.contains("@claude")
      {
        if !providers.contains("claude") { providers.append("claude") }
      }
      if values.contains("22222222-2222-2222-2222-222222222222")
        || values.contains("00000000-0000-0000-0000-0000000000c2")
        || values.contains("codex")
        || values.contains("@codex")
      {
        if !providers.contains("codex") { providers.append("codex") }
      }
      if values.contains("33333333-3333-3333-3333-333333333333")
        || values.contains("00000000-0000-0000-0000-0000000000c3")
        || values.contains("grok")
        || values.contains("@grok")
      {
        if !providers.contains("grok") { providers.append("grok") }
      }
      if values.contains("44444444-4444-4444-4444-444444444444")
        || values.contains("00000000-0000-0000-0000-0000000000c4")
        || values.contains("agy")
        || values.contains("@agy")
        || values.contains("antigravity")
        || values.contains("@antigravity")
      {
        if !providers.contains("agy") { providers.append("agy") }
      }
    }
    return providers
  }

  private func groupBridgeProviderFromMembers() -> String? {
    for member in groupMembers {
      let values = [
        member["userId"],
        member["user_id"],
        member["id"],
        member["name"],
        member["displayName"],
        member["username"],
        member["handle"],
        member["label"]
      ]
      .compactMap { value -> String? in
        if let string = value as? String {
          return string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        if let number = value as? NSNumber {
          return number.stringValue.lowercased()
        }
        return nil
      }

      if values.contains("11111111-1111-1111-1111-111111111111")
        || values.contains("00000000-0000-0000-0000-0000000000c1")
        || values.contains("claude")
        || values.contains("@claude")
      {
        return "claude"
      }

      if values.contains("22222222-2222-2222-2222-222222222222")
        || values.contains("00000000-0000-0000-0000-0000000000c2")
        || values.contains("codex")
        || values.contains("@codex")
      {
        return "codex"
      }

      if values.contains("33333333-3333-3333-3333-333333333333")
        || values.contains("00000000-0000-0000-0000-0000000000c3")
        || values.contains("grok")
        || values.contains("@grok")
      {
        return "grok"
      }

      if values.contains("44444444-4444-4444-4444-444444444444")
        || values.contains("00000000-0000-0000-0000-0000000000c4")
        || values.contains("agy")
        || values.contains("@agy")
        || values.contains("antigravity")
        || values.contains("@antigravity")
      {
        return "agy"
      }
    }

    return nil
  }

  private func configureListRowCell(
    _ cell: ChatProfileListRowCell,
    title: String,
    subtitle: String,
    value: String = "",
    iconName: String,
    showsSeparator: Bool,
    showsChevron: Bool = true
  ) {
    cell.rowNode.isHidden = true

    var config = UIListContentConfiguration.subtitleCell()
    config.text = title
    config.textProperties.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
    config.textProperties.color = currentTextColor
    if !subtitle.isEmpty {
      config.secondaryText = subtitle
      config.secondaryTextProperties.font = UIFont.systemFont(ofSize: 13, weight: .regular)
      config.secondaryTextProperties.color = currentSecondaryTextColor
    }
    config.image = UIImage(systemName: iconName)
    config.imageProperties.tintColor = .systemBlue
    cell.contentConfiguration = config

    if !value.isEmpty {
      let badge = UILabel()
      badge.text = value
      badge.font = UIFont.systemFont(ofSize: 15, weight: .medium)
      badge.textColor = currentSecondaryTextColor
      badge.sizeToFit()
      cell.accessoryView = badge
    } else {
      cell.accessoryView = nil
    }
    cell.accessoryType = showsChevron ? .disclosureIndicator : .none

    cell.backgroundColor = .clear
    if #available(iOS 14.0, *) {
      var background = UIBackgroundConfiguration.listGroupedCell()
      background.backgroundColor = .clear
      let isDark = traitCollection.userInterfaceStyle == .dark
      background.visualEffect = UIBlurEffect(style: isDark ? .systemThinMaterialDark : .systemThinMaterialLight)
      cell.backgroundConfiguration = background
    }
  }





  private func resolveSectionTitle(_ section: Section) -> String? {
    return nil
  }


  private func currentContentCount() -> Int {
    switch activeTab {
    case .media:
      return Int(ceil(Double(mediaRows.count) / 3.0))
    case .music:
      return musicRows.count
    case .voice:
      return voiceRows.count
    case .gifs:
      return gifRows.count
    case .files:
      return fileRows.count
    case .links:
      return linkRows.count
    case .pinned:
      return pinnedRows.count
    }
  }

  private func contentRow(at index: Int) -> ChatProfileRow? {
    switch activeTab {
    case .media:
      guard mediaRows.indices.contains(index) else { return nil }
      return mediaRows[index]
    case .music:
      guard musicRows.indices.contains(index) else { return nil }
      return musicRows[index]
    case .voice:
      guard voiceRows.indices.contains(index) else { return nil }
      return voiceRows[index]
    case .gifs:
      guard gifRows.indices.contains(index) else { return nil }
      return gifRows[index]
    case .files:
      guard fileRows.indices.contains(index) else { return nil }
      return fileRows[index]
    case .links:
      guard linkRows.indices.contains(index) else { return nil }
      return linkRows[index].row
    case .pinned:
      guard pinnedRows.indices.contains(index) else { return nil }
      return pinnedRows[index]
    }
  }

  private func contentSubtitle(for row: ChatProfileRow) -> String {
    switch activeTab {
    case .media:
      return formattedRowDate(row) ?? "Media"
    case .music:
      return [row.musicArtist, formattedRowDate(row)].compactMap { $0 }
        .joined(separator: " · ")
    case .voice:
      return [formattedFileSize(row.fileSize), formattedRowDate(row)].compactMap { $0 }
        .joined(separator: " · ")
    case .gifs:
      return formattedRowDate(row) ?? "GIF"
    case .files:
      return [formattedFileSize(row.fileSize), formattedRowDate(row)].compactMap { $0 }
        .joined(separator: " · ")
    case .links:
      return formattedRowDate(row) ?? "Link"
    case .pinned:
      return formattedRowDate(row) ?? "Pinned"
    }
  }

  private func contentTitle(for row: ChatProfileRow, index: Int) -> String {
    switch activeTab {
    case .media:
      if row.type == "video" { return "Video" }
      if row.type == "sticker" { return "Sticker" }
      return "Photo"
    case .music:
      return row.fileName ?? (row.text.isEmpty ? "Music" : row.text)
    case .voice:
      return row.fileName ?? "Voice message"
    case .gifs:
      return "GIF"
    case .files:
      return row.fileName ?? "File"
    case .links:
      return linkRows[index].url
    case .pinned:
      let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
      return text.isEmpty ? "Pinned message" : text
    }
  }



  private func scrollTabsIntoView(animated: Bool) {
  }

  private func syncTabViews() {
  }

  private func updateStickyTabsPresentation() {
  }

  private func resolvedIdentifierText() -> String {
    let handle = resolvedIdentifierRawValue()
    if handle.isEmpty {
      return "Username unavailable"
    }
    return handle
  }

  private func resolvedIdentifierRawValue() -> String {
    let handle = profileHandle.trimmingCharacters(in: .whitespacesAndNewlines)
    if !handle.isEmpty, !handle.lowercased().hasPrefix("id:"), !Self.looksLikeUUID(handle) {
      return handle.hasPrefix("@") ? handle : "@\(handle)"
    }

    let fallbackName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
    if Self.looksLikeUUID(fallbackName) {
      return ""
    }
    let compact =
      fallbackName
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .joined()
      .lowercased()
    if !compact.isEmpty {
      return "@\(compact)"
    }
    return ""
  }

  private static func looksLikeUUID(_ value: String) -> Bool {
    UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
  }

  private func getAgentDocuments() -> [(id: String, name: String, url: String)] {
    return fileRows.compactMap { item in
      let url = item.mediaUrl ?? ""
      if url.contains("/api/agent/document/") || url.contains("/uploads/agent-docs/")
        || url.contains("/agent/document/") || url.contains("/agent-docs/")
      {
        return (
          id: item.messageId,
          name: (item.fileName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? item.fileName!
            : "Document",
          url: url
        )
      }
      return nil
    }
  }

  private func rebuildMenu() {
    if #available(iOS 14.0, *) {
      let clearAction = UIAction(
        title: "Clear Chat",
        image: UIImage(systemName: "trash"),
        attributes: .destructive
      ) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "clearChat"])
      }

      let deleteAction = UIAction(
        title: "Delete",
        image: UIImage(systemName: "xmark.bin"),
        attributes: .destructive
      ) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "delete"])
      }

      let blockAction = UIAction(
        title: "Block",
        image: UIImage(systemName: "hand.raised"),
        attributes: .destructive
      ) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "blockUser"])
      }

      menuButton.menu = UIMenu(children: [clearAction, deleteAction, blockAction])
    }
  }

  @objc private func handleBackPressed() {
    onNativeEvent(["type": "headerBack"])
  }

  @objc private func handleLegacyMenuPressed() {
    guard let presenter = topMostViewController() else { return }
    let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)

    sheet.addAction(
      UIAlertAction(title: "Clear Chat", style: .destructive) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "clearChat"])
      })

    sheet.addAction(
      UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "delete"])
      })

    sheet.addAction(
      UIAlertAction(title: "Block", style: .destructive) { [weak self] _ in
        self?.onNativeEvent(["type": "headerMenuAction", "action": "blockUser"])
      })

    sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

    if let popover = sheet.popoverPresentationController {
      popover.sourceView = menuButton
      popover.sourceRect = menuButton.bounds
      popover.permittedArrowDirections = [.up, .down]
    }

    presenter.present(sheet, animated: true)
  }

  @objc private func handleMutePressed() {
    onNativeEvent(["type": "headerMenuAction", "action": "muteToggle"])
  }

  @objc private func handleSearchPressed() {
    onNativeEvent(["type": "headerSearchPressed"])
  }

  @objc private func handleAudioPressed() {
    onNativeEvent(["type": "headerAudioCallPressed"])
  }

  @objc private func handleVideoPressed() {
    onNativeEvent(["type": "headerVideoCallPressed"])
  }

  @objc private func handleIdentifierPressed() {
    if !availableTabs.isEmpty {
      scrollTabsIntoView(animated: true)
      return
    }

    let raw = resolvedIdentifierRawValue()
    guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    UIPasteboard.general.string = raw
    onNativeEvent(["type": "profileIdPressed", "id": raw])
  }

  private func reloadDataKeepingSelection() {
    tableView.reloadData()
    layoutHeroHeaderViewIfNeeded(force: true)
    syncTabViews()
    updateStickyTabsPresentation()
    renderSwiftUIProfile()
  }

  // MARK: UITableViewDataSource

  private enum Section: Int, CaseIterable {
    case profileInfo
    case chatHistory
    case sharedContent
    case contactActions
    case emergency
    case dangerActions
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    guard scrollView === tableView else { return }
    if scrollView.contentOffset.y < 0.0 {
      layoutHeroHeaderViewIfNeeded(force: false)
    }
    updateAvatarMorphProgress()
  }

  func numberOfSections(in tableView: UITableView) -> Int {
    return Section.allCases.count
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    guard let section = Section(rawValue: section) else { return 0 }

    switch section {
    case .profileInfo:
      return profileInfoRowCount()
    case .chatHistory:
      return rows.isEmpty ? 0 : 1
    case .sharedContent:
      return availableTabs.count
    case .contactActions:
      return 3
    case .emergency:
      return 1
    case .dangerActions:
      return 1
    }
  }

  func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    guard let section = Section(rawValue: section) else { return nil }
    return resolveSectionTitle(section)
  }

  func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
    .leastNormalMagnitude
  }

  func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
    12.0
  }

  func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    guard let section = Section(rawValue: indexPath.section) else {
      return UITableView.automaticDimension
    }

    switch section {
    case .profileInfo:
      return indexPath.row == 1 ? UITableView.automaticDimension : 62.0
    case .chatHistory:
      return 74.0
    case .sharedContent:
      return 58.0
    case .contactActions, .emergency, .dangerActions:
      return 44.0
    }
  }


  private func profileInfoRowCount() -> Int {
    let hasUsername = !resolvedIdentifierRawValue().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasNote = !profileBio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return (hasUsername ? 1 : 0) + (hasNote ? 1 : 0)
  }

  private func profileInfoModel(at row: Int) -> (title: String, subtitle: String, image: String?, copyable: Bool)? {
    var models: [(String, String, String?, Bool)] = []
    let username = resolvedIdentifierRawValue().trimmingCharacters(in: .whitespacesAndNewlines)
    if !username.isEmpty {
      models.append(("username", username, "doc.on.doc", true))
    }
    let note = profileBio.trimmingCharacters(in: .whitespacesAndNewlines)
    if !note.isEmpty {
      models.append(("note", note, nil, false))
    }
    guard models.indices.contains(row) else { return nil }
    let item = models[row]
    return (item.0, item.1, item.2, item.3)
  }

  private func latestChatHistorySubtitle() -> String {
    guard let latest = rows.compactMap({ $0.timestampMs }).max(), latest > 0 else {
      let count = rows.count
      return count == 1 ? "1 message" : "\(count) messages"
    }

    let date = Date(timeIntervalSince1970: TimeInterval(latest) / 1000.0)
    let formatter = DateFormatter()
    formatter.doesRelativeDateFormatting = true
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    let count = rows.count == 1 ? "1 message" : "\(rows.count) messages"
    return "\(count) • \(formatter.string(from: date))"
  }

  private func configureGroupedCell(
    _ cell: UITableViewCell,
    title: String,
    subtitle: String = "",
    image: String? = nil,
    showsChevron: Bool = false,
    isLast: Bool
  ) {
    cell.selectionStyle = showsChevron || image != nil ? .default : .none
    cell.backgroundColor = .clear
    cell.contentView.backgroundColor = .clear
    cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
    cell.contentConfiguration = UIHostingConfiguration {
      ChatProfileGroupedRowView(
        title: title,
        subtitle: subtitle,
        systemImage: image,
        showsChevron: showsChevron,
        titleColor: currentTextColor,
        subtitleColor: currentSecondaryTextColor,
        separatorColor: currentRowSeparatorColor,
        isLast: isLast
      )
    }
    .background(.ultraThinMaterial)
    .margins(.all, 0)
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    guard let section = Section(rawValue: indexPath.section) else {
      return UITableViewCell(style: .default, reuseIdentifier: nil)
    }

    switch section {
    case .profileInfo:
      let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
      let count = profileInfoRowCount()
      if let model = profileInfoModel(at: indexPath.row) {
        configureGroupedCell(
          cell,
          title: model.title,
          subtitle: model.subtitle,
          image: model.image,
          showsChevron: false,
          isLast: indexPath.row == count - 1
        )
      }
      return cell

    case .chatHistory:
      let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
      configureGroupedCell(
        cell,
        title: "Chat History",
        subtitle: latestChatHistorySubtitle(),
        image: nil,
        showsChevron: true,
        isLast: true
      )
      return cell

    case .sharedContent:
      guard availableTabs.indices.contains(indexPath.row) else {
        return UITableViewCell(style: .default, reuseIdentifier: nil)
      }
      let tab = availableTabs[indexPath.row]
      let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
      configureGroupedCell(
        cell,
        title: sharedTitle(for: tab),
        subtitle: sharedSubtitle(for: tab),
        image: nil,
        showsChevron: true,
        isLast: indexPath.row == availableTabs.count - 1
      )
      return cell

    case .contactActions:
      let titles = ["Share Contact", "Create New Contact", "Add to Existing Contact"]
      let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
      cell.textLabel?.text = titles[indexPath.row]
      cell.textLabel?.font = UIFont.systemFont(ofSize: 17, weight: .regular)
      cell.textLabel?.textColor = .systemBlue
      cell.backgroundColor = .secondarySystemGroupedBackground
      return cell

    case .emergency:
      let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
      cell.textLabel?.text = "Add to Emergency Contacts"
      cell.textLabel?.font = UIFont.systemFont(ofSize: 17, weight: .regular)
      cell.textLabel?.textColor = .systemBlue
      cell.backgroundColor = .secondarySystemGroupedBackground
      return cell

    case .dangerActions:
      let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
      cell.textLabel?.text = "Block Contact"
      cell.textLabel?.font = UIFont.systemFont(ofSize: 17, weight: .regular)
      cell.textLabel?.textColor = .systemRed
      cell.backgroundColor = .secondarySystemGroupedBackground
      return cell
    }
  }

  func tableView(
    _ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath
  ) {
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    defer { tableView.deselectRow(at: indexPath, animated: true) }

    guard let section = Section(rawValue: indexPath.section) else { return }

    switch section {
    case .profileInfo:
      guard let model = profileInfoModel(at: indexPath.row), model.copyable else { return }
      UIPasteboard.general.string = model.subtitle
      onNativeEvent(["type": "profileIdPressed", "id": model.subtitle])

    case .chatHistory:
      guard !availableTabs.isEmpty else {
        onNativeEvent(["type": "profileChatHistoryPressed", "chatId": engineChatId])
        return
      }
      let tab = activeTab
      let isDark = traitCollection.userInterfaceStyle == .dark
      var targetRows: [Any] = []
      switch tab {
      case .media: targetRows = mediaRows
      case .music: targetRows = musicRows
      case .voice: targetRows = voiceRows
      case .gifs: targetRows = gifRows
      case .files: targetRows = fileRows
      case .links: targetRows = linkRows
      case .pinned: targetRows = pinnedRows
      }
      guard let sourceCell = tableView.cellForRow(at: indexPath) else { return }
      let controller = ChatProfileExpandedContentViewController(
        profileTab: tab,
        titleText: "Chat History",
        rows: targetRows,
        themeIsDark: isDark,
        sourceView: sourceCell,
        hostView: self
      )
      controller.onContentPressed = { [weak self] payload in
        self?.onNativeEvent(payload)
      }
      topMostViewController()?.present(controller, animated: false)

    case .sharedContent:
      guard availableTabs.indices.contains(indexPath.row) else { return }
      let tab = availableTabs[indexPath.row]
      let isDark = traitCollection.userInterfaceStyle == .dark
      var targetRows: [Any] = []
      switch tab {
      case .media: targetRows = mediaRows
      case .music: targetRows = musicRows
      case .voice: targetRows = voiceRows
      case .gifs: targetRows = gifRows
      case .files: targetRows = fileRows
      case .links: targetRows = linkRows
      case .pinned: targetRows = pinnedRows
      }

      guard let sourceCell = tableView.cellForRow(at: indexPath) else { return }
      let controller = ChatProfileExpandedContentViewController(
        profileTab: tab,
        titleText: sharedTitle(for: tab),
        rows: targetRows,
        themeIsDark: isDark,
        sourceView: sourceCell,
        hostView: self
      )
      controller.onContentPressed = { [weak self] payload in
        self?.onNativeEvent(payload)
      }

      if let presenter = topMostViewController() {
        presenter.present(controller, animated: false)
      }

    case .contactActions:
      let actions = ["shareContact", "createNewContact", "addToExisting"]
      if actions.indices.contains(indexPath.row) {
        onNativeEvent(["type": "profileContactAction", "action": actions[indexPath.row]])
      }

    case .emergency:
      onNativeEvent(["type": "profileContactAction", "action": "addToEmergency"])

    case .dangerActions:
      onNativeEvent(["type": "profileContactAction", "action": "block"])
    }
  }

  private func handleMediaGridTapped(at index: Int) {
    guard activeTab == .media, index >= 0, index < mediaRows.count else { return }
    let row = mediaRows[index]

    if row.type == "video", let mediaUrl = row.mediaUrl, !mediaUrl.isEmpty {
      let resolvedUrlStr = ChatEngine.shared.resolveURLForOpen(mediaUrl) ?? mediaUrl
      guard let url = URL(string: resolvedUrlStr) else { return }

      var options: [String: Any]? = nil
      if url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https",
         let authHeader = ChatEngine.shared.authorizationHeaderForAPI() {
        options = ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": authHeader]]
      }

      let asset = AVURLAsset(url: url, options: options)
      let controller = ChatVideoEditViewController(
        asset: asset,
        initialCaption: row.text,
        headerTitle: "Video",
        previewOnly: true
      )

      if let presenter = topMostViewController() {
        presenter.present(controller, animated: true)
      }
      return
    }

    onNativeEvent([
      "type": "profileContentPressed",
      "tab": activeTab.rawValue,
      "messageId": row.messageId,
      "url": row.mediaUrl ?? ""
    ])
  }

  // MARK: Agent Config

  private func fetchAgentConfigForCurrentChat() {
    let currentId = engineChatId
    guard !currentId.isEmpty else { return }
    ChatEngine.shared.fetchAgentConfig(chatId: currentId) { [weak self] config in
      guard let self, self.engineChatId == currentId else { return }
      self.agentConfig = self.normalizedAgentConfig(config, fallbackChatId: currentId)
      self.tableView.reloadData()
    }
  }

  private func presentAgentConfigEditor() {
    guard isGroupOrChannel else {
      onNativeEvent(["type": "headerAgentPressed"])
      return
    }

    let chatId = engineChatId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatId.isEmpty else { return }
    guard let presenter = topMostViewController() else { return }

    // pageSheet + NavigationStack (same API as AgentBridgeHistorySheet / connect sheets).
    // Root is a summary list; prompt/tools/docs push inside the sheet.
    let model = GroupAgentConfigModel(
      chatId: chatId,
      config: agentConfig,
      documents: getAgentDocuments()
    )
    model.onSave = { [weak self] config in
      guard let self else { return }
      let normalized = self.normalizedAgentConfig(config, fallbackChatId: chatId) ?? config
      ChatEngine.shared.saveAgentConfig(chatId: chatId, config: normalized) { [weak self] success in
        guard let self else { return }
        if success {
          self.agentConfig = normalized
          self.tableView.reloadData()
          self.renderSwiftUIProfile()
        }
      }
    }
    model.onDelete = { [weak self] in
      guard let self else { return }
      ChatEngine.shared.deleteAgentConfig(chatId: chatId) { [weak self] success in
        guard let self else { return }
        if success {
          self.agentConfig = nil
          self.tableView.reloadData()
          self.renderSwiftUIProfile()
        }
      }
    }

    let isDark = traitCollection.userInterfaceStyle == .dark
    let host = UIHostingController(
      rootView: GroupAgentConfigSheet(model: model)
        .preferredColorScheme(isDark ? .dark : .light)
    )
    // Clear host so pageSheet Liquid Glass refracts the profile (same as
    // VibeAgentAskSheet / progress detail sheets — no solid opaque backing).
    host.view.backgroundColor = .clear
    host.modalPresentationStyle = .pageSheet
    if let sheet = host.sheetPresentationController {
      sheet.detents = [
        .medium(),
        .large(),
      ]
      sheet.selectedDetentIdentifier = .medium
      sheet.prefersGrabberVisible = true
      sheet.preferredCornerRadius = 22
    }
    presenter.present(host, animated: true)

    onNativeEvent(["type": "headerAgentPressed"])
  }

  // MARK: Bridge (Claude/Codex) connection + history

  private func presentBridgeConnection() {
    guard !bridgeProvider.isEmpty, let presenter = topMostViewController() else { return }
    AgentBridgeProfile.presentConnection(provider: bridgeProvider, from: presenter)
    // Re-check status when the user returns from the sheet so the card reflects
    // any connect/disconnect they just performed.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      self?.refreshBridgeStatus()
    }
  }

  private func normalizedAgentConfig(_ config: [String: Any]?, fallbackChatId: String)
    -> [String: Any]?
  {
    guard let config else { return nil }
    var normalized: [String: Any] = [:]

    let resolvedChatId =
      normalizedAgentString(config["chat_id"]) ?? normalizedAgentString(config["chatId"])
      ?? fallbackChatId
    normalized["chat_id"] = resolvedChatId

    normalized["name"] = normalizedAgentString(config["name"]) ?? "Vibe AI"

    let resolvedPrompt =
      normalizedAgentString(config["system_prompt"]) ?? normalizedAgentString(
        config["systemPrompt"])
      ?? ""
    normalized["system_prompt"] = resolvedPrompt

    normalized["enabled"] = normalizedAgentEnabledValue(config["enabled"], defaultValue: true)

    if let enabledTools = normalizedAgentToolList(config["enabled_tools"])
      ?? normalizedAgentToolList(config["enabledTools"]),
      !enabledTools.isEmpty
    {
      normalized["enabled_tools"] = enabledTools
    }

    if let id = normalizedAgentString(config["id"]), !id.isEmpty {
      normalized["id"] = id
    }

    if let avatar = normalizedAgentString(config["avatar_url"])
      ?? normalizedAgentString(config["avatarUrl"])
    {
      normalized["avatar_url"] = avatar
    }

    if let createdBy = normalizedAgentString(config["created_by"])
      ?? normalizedAgentString(config["createdBy"])
    {
      normalized["created_by"] = createdBy
    }

    return normalized
  }

  private func normalizedAgentString(_ rawValue: Any?) -> String? {
    if let string = rawValue as? String {
      let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    }
    if let number = rawValue as? NSNumber {
      return number.stringValue
    }
    return nil
  }

  private func normalizedAgentEnabledValue(_ rawValue: Any?, defaultValue: Bool) -> Bool {
    guard let rawValue else { return defaultValue }
    if let boolValue = rawValue as? Bool { return boolValue }
    if let numberValue = rawValue as? NSNumber { return numberValue.boolValue }
    if let stringValue = rawValue as? String {
      switch stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "true", "1", "yes", "on":
        return true
      case "false", "0", "no", "off":
        return false
      default:
        break
      }
    }
    return defaultValue
  }

  private func normalizedAgentToolList(_ rawValue: Any?) -> [String]? {
    guard let rawArray = rawValue as? [Any] else { return nil }
    let normalized =
      rawArray
      .compactMap { value -> String? in
        if let text = value as? String {
          let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
          return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
          return number.stringValue
        }
        return nil
      }
    return normalized.isEmpty ? nil : normalized
  }

  // MARK: Formatting

  private func formattedRowDate(_ row: ChatProfileRow) -> String? {
    guard let timestampMs = row.timestampMs, timestampMs > 0 else { return nil }
    let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
    return Self.listDateFormatter.string(from: date)
  }

  private func formattedFileSize(_ bytes: Int64?) -> String? {
    guard let bytes, bytes > 0 else { return nil }
    if bytes < 1024 {
      return "\(bytes) B"
    }
    if bytes < 1024 * 1024 {
      return String(format: "%.1f KB", Double(bytes) / 1024.0)
    }
    return String(format: "%.1f MB", Double(bytes) / (1024.0 * 1024.0))
  }

  private func topMostViewController() -> UIViewController? {
    let root = window?.rootViewController
    var current = root
    while let presented = current?.presentedViewController {
      current = presented
    }
    return current
  }
}
fileprivate class ChatProfileExpandedContentViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

  let profileTab: ChatProfileTab
  let titleText: String
  let rows: [Any]
  let themeIsDark: Bool
  var onContentPressed: (([String: Any]) -> Void)?

  private let tableView = UITableView(frame: .zero, style: .plain)
  private let headerBlur = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
  private let headerOverlay = UIView()
  private let titleLabel = UILabel()
  private let closeButton = UIButton(type: .system)

  init(profileTab: ChatProfileTab, titleText: String, rows: [Any], themeIsDark: Bool, sourceView: UIView, hostView: UIView) {
    self.profileTab = profileTab
    self.titleText = titleText
    self.rows = rows
    self.themeIsDark = themeIsDark
    super.init(nibName: nil, bundle: nil)
    self.modalPresentationStyle = .overFullScreen
    _ = sourceView
    _ = hostView
  }

  required init?(coder: NSCoder) {
    fatalError()
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = themeIsDark
      ? UIColor(red: 7.0/255.0, green: 10.0/255.0, blue: 15.0/255.0, alpha: 1.0)
      : UIColor(red: 235.0/255.0, green: 240.0/255.0, blue: 243.0/255.0, alpha: 1.0)

    tableView.dataSource = self
    tableView.delegate = self
    tableView.backgroundColor = .clear
    tableView.separatorStyle = .none
    tableView.contentInset = UIEdgeInsets(top: 92, left: 0, bottom: 24, right: 0)

    tableView.register(ChatProfileVoiceContentCell.self, forCellReuseIdentifier: ChatProfileVoiceContentCell.reuseIdentifier)
    tableView.register(ChatProfileMediaGridRowCell.self, forCellReuseIdentifier: ChatProfileMediaGridRowCell.reuseIdentifier)
    tableView.register(ChatProfileMediaContentCell.self, forCellReuseIdentifier: ChatProfileMediaContentCell.reuseIdentifier)
    tableView.register(ChatProfileListRowCell.self, forCellReuseIdentifier: ChatProfileListRowCell.reuseIdentifier)

    view.addSubview(tableView)

    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect(style: .regular)
      effect.isInteractive = true
      headerBlur.effect = effect
    } else {
      headerBlur.effect = UIBlurEffect(style: themeIsDark ? .systemMaterialDark : .systemMaterialLight)
    }
    view.addSubview(headerBlur)
    headerOverlay.isUserInteractionEnabled = false
    headerOverlay.backgroundColor =
      (themeIsDark ? UIColor.black : UIColor.white).withAlphaComponent(themeIsDark ? 0.18 : 0.16)
    headerBlur.contentView.addSubview(headerOverlay)

    titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
    titleLabel.textColor = themeIsDark ? .white : .black
    titleLabel.text = titleText
    headerBlur.contentView.addSubview(titleLabel)

    closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
    closeButton.tintColor = themeIsDark ? .lightGray : .darkGray
    closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
    headerBlur.contentView.addSubview(closeButton)
  }

  @objc private func handleClose() {
    dismiss(animated: true)
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    tableView.frame = view.bounds
    let headerHeight = view.safeAreaInsets.top + 64.0
    headerBlur.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: headerHeight)
    headerOverlay.frame = headerBlur.bounds
    let topInset = headerHeight + 20.0
    if abs(tableView.contentInset.top - topInset) > 0.5 {
      tableView.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: 24, right: 0)
      tableView.scrollIndicatorInsets = UIEdgeInsets(top: headerHeight, left: 0, bottom: 0, right: 0)
    }
    titleLabel.sizeToFit()
    titleLabel.center = CGPoint(x: headerBlur.bounds.midX, y: view.safeAreaInsets.top + 30.0)
    closeButton.frame = CGRect(x: headerBlur.bounds.width - 48, y: view.safeAreaInsets.top + 16.0, width: 32, height: 32)
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    if profileTab == .media {
      return Int(ceil(Double(rows.count) / 3.0))
    }
    return rows.count
  }

  func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
    if profileTab == .media {
      let cols: CGFloat = 3.0
      let padding: CGFloat = 16.0
      let gap: CGFloat = 2.0
      let avail = max(0.0, tableView.bounds.width - padding * 2.0 - gap * (cols - 1))
      let itemHeight = floor(avail / cols)
      return itemHeight + gap
    } else if profileTab == .voice || profileTab == .gifs {
      return 72.0
    }
    return 68.0
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    if profileTab == .media {
      guard let cell = tableView.dequeueReusableCell(withIdentifier: ChatProfileMediaGridRowCell.reuseIdentifier, for: indexPath) as? ChatProfileMediaGridRowCell else { return UITableViewCell() }
      var items: [(url: String?, isVideo: Bool, thumbnailBase64: String?)] = []
      let startIndex = indexPath.row * 3
      for i in 0..<3 {
        let absIndex = startIndex + i
        if absIndex < rows.count, let r = rows[absIndex] as? ChatProfileRow {
          items.append((url: r.mediaUrl, isVideo: r.type == "video", thumbnailBase64: r.thumbnailBase64))
        }
      }
      cell.configure(items: items, startIndex: startIndex, placeholderTintColor: .gray, placeholderBackgroundColor: .darkGray)
      cell.onMediaTapped = { [weak self] index in
        guard let self = self, index < self.rows.count, let r = self.rows[index] as? ChatProfileRow else { return }
        self.onContentPressed?(["type": "profileContentPressed", "tab": self.profileTab.rawValue, "messageId": r.messageId, "url": r.mediaUrl ?? ""])
      }
      return cell
    }

    let rowObj = rows[indexPath.row]
    var r: ChatProfileRow? = rowObj as? ChatProfileRow
    if profileTab == .links, let linkItem = rowObj as? ChatProfileLinkItem { r = linkItem.row }
    guard let row = r else { return UITableViewCell() }

    if profileTab == .voice {
      guard let cell = tableView.dequeueReusableCell(withIdentifier: ChatProfileVoiceContentCell.reuseIdentifier, for: indexPath) as? ChatProfileVoiceContentCell else { return UITableViewCell() }
      cell.configure(title: row.fileName ?? "Voice message", subtitle: "Voice", row: row, titleColor: themeIsDark ? .white : .black, subtitleColor: .gray, accentColor: .systemBlue)
      VoiceBubblePlaybackCoordinator.shared.bind(cell: cell, messageId: row.messageId, mediaURL: row.mediaUrl, mediaKey: row.mediaKey, fileName: row.fileName)
      return cell
    }

    guard let cell = tableView.dequeueReusableCell(withIdentifier: ChatProfileListRowCell.reuseIdentifier, for: indexPath) as? ChatProfileListRowCell else { return UITableViewCell() }
    let title: String
    let subtitle: String
    let iconName: String
    if profileTab == .links, let linkItem = rowObj as? ChatProfileLinkItem {
      title = linkItem.url
      subtitle = "Shared link"
      iconName = "link"
    } else {
      title = row.fileName ?? (row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Item" : row.text)
      subtitle = row.type.capitalized
      iconName = profileTab == .pinned ? "pin.fill" : "doc.text.fill"
    }
    cell.rowNode.isHidden = true
    cell.contentConfiguration = UIHostingConfiguration {
      ChatProfileModernRowView(
        title: title,
        subtitle: subtitle,
        value: "",
        iconName: iconName,
        showsChevron: profileTab != .pinned,
        isDark: themeIsDark,
        titleColor: themeIsDark ? .white : .black,
        subtitleColor: themeIsDark ? UIColor(white: 0.72, alpha: 1.0) : UIColor(white: 0.42, alpha: 1.0),
        accentColor: .systemBlue,
        cardColor: themeIsDark
          ? UIColor(red: 53.0/255.0, green: 62.0/255.0, blue: 72.0/255.0, alpha: 0.30)
          : UIColor.white.withAlphaComponent(0.68),
        separatorColor: themeIsDark ? UIColor.white.withAlphaComponent(0.08) : UIColor.black.withAlphaComponent(0.06)
      )
    }
    .margins(.all, 0)
    cell.backgroundColor = .clear
    cell.contentView.backgroundColor = .clear
    cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    guard profileTab != .media else { return }
    let rowObj = rows[indexPath.row]
    var r: ChatProfileRow? = rowObj as? ChatProfileRow
    if profileTab == .links, let linkItem = rowObj as? ChatProfileLinkItem { r = linkItem.row }
    guard let row = r else { return }

    if profileTab == .voice {
      if let cell = tableView.cellForRow(at: indexPath) as? VoicePlayableCell {
        VoiceBubblePlaybackCoordinator.shared.toggle(cell: cell, messageId: row.messageId, mediaURL: row.mediaUrl, mediaKey: row.mediaKey, fileName: row.fileName)
      }
      return
    }

    var payload: [String: Any] = ["type": "profileContentPressed", "tab": profileTab.rawValue, "messageId": row.messageId]
    if profileTab == .links, let linkItem = rowObj as? ChatProfileLinkItem { payload["url"] = linkItem.url }
    else if let mediaUrl = row.mediaUrl, !mediaUrl.isEmpty { payload["url"] = mediaUrl }

    onContentPressed?(payload)
  }
}
import SwiftUI
import UIKit

struct ChatProfileImageCropper: View {
  let image: UIImage
  let onCrop: (UIImage?) -> Void
  let onCancel: () -> Void

  @State private var scale: CGFloat = 1.0
  @State private var lastScale: CGFloat = 1.0
  @State private var offset: CGSize = .zero
  @State private var lastOffset: CGSize = .zero

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        Color.black.ignoresSafeArea()

        GeometryReader { proxy in
          let side = min(proxy.size.width, proxy.size.height) - 32
          let imageAspect = image.size.width / image.size.height

          let displayWidth = imageAspect > 1 ? side * imageAspect : side
          let displayHeight = imageAspect > 1 ? side : side / imageAspect

          ZStack {
            Image(uiImage: image)
              .resizable()
              .scaledToFit()
              .frame(width: displayWidth, height: displayHeight)
              .scaleEffect(scale)
              .offset(offset)
              .gesture(
                DragGesture()
                  .onChanged { value in
                    offset = CGSize(
                      width: lastOffset.width + value.translation.width,
                      height: lastOffset.height + value.translation.height
                    )
                  }
                  .onEnded { _ in
                    lastOffset = offset
                  }
              )
              .gesture(
                MagnificationGesture()
                  .onChanged { value in
                    scale = max(1.0, lastScale * value)
                  }
                  .onEnded { _ in
                    lastScale = scale
                  }
              )
          }
          .frame(width: side, height: side)
          .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
              .stroke(Color.white.opacity(0.4), lineWidth: 2)
          )
          .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
      }

      HStack {
        Button("Cancel") {
          onCancel()
        }
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(.white)

        Spacer()

        Button("Done") {
          let cropped = renderCroppedImage()
          onCrop(cropped)
        }
        .font(.system(size: 18, weight: .bold))
        .foregroundStyle(.white)
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 20)
      .background(Color.black)
    }
  }

  @MainActor
  private func renderCroppedImage() -> UIImage? {
    let targetSize = CGSize(width: 800, height: 800)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1.0
    let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)

    let result = renderer.image { ctx in
      UIColor.black.setFill()
      ctx.fill(CGRect(origin: .zero, size: targetSize))

      let displayAspect = image.size.width / image.size.height
      let drawWidth = displayAspect > 1 ? targetSize.width * displayAspect : targetSize.width
      let drawHeight = displayAspect > 1 ? targetSize.height : targetSize.height / displayAspect

      let centerX = targetSize.width / 2
      let centerY = targetSize.height / 2

      ctx.cgContext.translateBy(x: centerX, y: centerY)
      ctx.cgContext.scaleBy(x: scale, y: scale)

      let cropWindowWidth: CGFloat = UIScreen.main.bounds.width - 32
      let offsetX = (offset.width / cropWindowWidth) * targetSize.width / scale
      let offsetY = (offset.height / cropWindowWidth) * targetSize.height / scale

      ctx.cgContext.translateBy(x: offsetX, y: offsetY)

      let rect = CGRect(
        x: -drawWidth / 2,
        y: -drawHeight / 2,
        width: drawWidth,
        height: drawHeight
      )

      image.draw(in: rect)
    }

    return result
  }
}
