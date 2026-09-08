import SwiftUI
import UIKit

// MARK: - Sample rows (real ChatListRow payloads)

enum ChatAppearancePreviewSamples {
  static func themRow(text: String, radius: CGFloat, withTail: Bool = true) -> ChatListRow {
    ChatListRow(raw: [
      "kind": "message",
      "key": "appearance-preview-them-\(text.hashValue)",
      "message": [
        "id": "appearance-preview-them-\(abs(text.hashValue))",
        "text": text,
        "timestamp": "22:20",
        "isMe": false,
        "type": "text",
        "bubbleShape": shapeDict(isMe: false, radius: radius, showTail: withTail),
      ],
    ])!
  }

  static func meRow(text: String, radius: CGFloat) -> ChatListRow {
    ChatListRow(raw: [
      "kind": "message",
      "key": "appearance-preview-me-\(text.hashValue)",
      "message": [
        "id": "appearance-preview-me-\(abs(text.hashValue))",
        "text": text,
        "timestamp": "22:20",
        "isMe": true,
        "type": "text",
        "status": "read",
        "bubbleShape": shapeDict(isMe: true, radius: radius, showTail: true),
      ],
    ])!
  }

  static func voiceRow(radius: CGFloat) -> ChatListRow {
    ChatListRow(raw: [
      "kind": "message",
      "key": "appearance-preview-voice",
      "message": [
        "id": "appearance-preview-voice",
        "text": "",
        "timestamp": "22:20",
        "isMe": false,
        "type": "voice",
        "mediaDuration": 23,
        "bubbleShape": shapeDict(isMe: false, radius: radius, showTail: false),
      ],
    ])!
  }

  private static func shapeDict(isMe: Bool, radius: CGFloat, showTail: Bool) -> [String: Any] {
    let r = Double(radius)
    // Match live chat: consecutive/merged corner ≈ 12 when primary is 18 (~0.67×).
    let tight = max(8.0, r * (12.0 / 18.0))
    if isMe {
      return [
        "showTail": showTail,
        "borderTopLeftRadius": r,
        "borderTopRightRadius": r,
        "borderBottomLeftRadius": r,
        "borderBottomRightRadius": tight,
      ]
    }
    return [
      "showTail": showTail,
      "borderTopLeftRadius": r,
      "borderTopRightRadius": r,
      "borderBottomLeftRadius": tight,
      "borderBottomRightRadius": r,
    ]
  }
}

// MARK: - UIKit host (production wallpaper + ChatListCell)

/// Renders appearance previews with the **same** wallpaper pipeline as `ChatListView`
/// and real `ChatListCell` instances (not SwiftUI mock bubbles).
final class ChatAppearanceLiveHostView: UIView {
  private let wallpaperLayer = CAGradientLayer()
  private let patternLayer = CAGradientLayer()
  private let patternMaskLayer = CALayer()
  private let stack = UIStackView()
  private var cells: [ChatListCell] = []
  private var appearance = ChatListAppearance.current
  private var mode: Mode = .full

  enum Mode {
    /// Hub / create-theme: 2 message cells
    case compact
    /// Color editor / corners: them + voice + me
    case full
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    clipsToBounds = true

    wallpaperLayer.startPoint = CGPoint(x: 0, y: 0)
    wallpaperLayer.endPoint = CGPoint(x: 1, y: 1)
    layer.insertSublayer(wallpaperLayer, at: 0)

    patternLayer.startPoint = CGPoint(x: 0, y: 0)
    patternLayer.endPoint = CGPoint(x: 1, y: 1)
    patternLayer.mask = patternMaskLayer
    patternMaskLayer.contentsGravity = .resizeAspectFill
    layer.insertSublayer(patternLayer, at: 1)

    stack.axis = .vertical
    stack.spacing = 8
    stack.alignment = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
    ])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func apply(draft: ChatAppearanceDraft, mode: Mode) {
    self.mode = mode
    appearance = ChatListAppearance.from(draft: draft)
    applyWallpaper()
    rebuildCellsIfNeeded()
    reconfigureCells()
    setNeedsLayout()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    wallpaperLayer.frame = bounds
    patternLayer.frame = bounds
    patternMaskLayer.frame = patternLayer.bounds
    layoutCells()
  }

  // MARK: Wallpaper (mirrors ChatListView.applyWallpaperAppearance)

  private func applyWallpaper() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    wallpaperLayer.colors = appearance.wallpaperGradient.map(\.cgColor)
    wallpaperLayer.opacity = Float(max(0, min(1, appearance.wallpaperOpacity)))
    wallpaperLayer.isHidden = appearance.backgroundMode == "transparent"

    let canShowPattern =
      appearance.backgroundMode != "transparent"
      && appearance.wallpaperPatternGradient.count >= 2
      && appearance.wallpaperPatternOpacity > 0.001
      && (appearance.wallpaperMaskKey?.isEmpty == false)

    // Cache-only: see `ChatWallpaperView.apply`. A miss decodes off-main and re-enters.
    if canShowPattern, let maskKey = appearance.wallpaperMaskKey,
      ChatWallpaperMaskStore.cachedImage(forKey: maskKey) == nil
    {
      ChatWallpaperMaskStore.prewarm(key: maskKey) { [weak self] ok in
        guard ok else { return }
        DispatchQueue.main.async { self?.applyWallpaper() }
      }
    }
    if canShowPattern,
      let maskKey = appearance.wallpaperMaskKey,
      let maskImage = ChatWallpaperMaskStore.cachedImage(forKey: maskKey)
    {
      patternLayer.colors = appearance.wallpaperPatternGradient.map(\.cgColor)
      patternLayer.locations = appearance.wallpaperPatternLocations
      patternLayer.opacity = Float(max(0, min(1, appearance.wallpaperPatternOpacity)))
      patternMaskLayer.contents = maskImage
      patternLayer.isHidden = false
    } else {
      patternLayer.isHidden = true
      patternLayer.colors = nil
      patternMaskLayer.contents = nil
      patternLayer.opacity = 0
    }
    CATransaction.commit()
  }

  // MARK: Cells

  private func rebuildCellsIfNeeded() {
    let count = mode == .compact ? 2 : 3
    if cells.count == count { return }
    cells.forEach { $0.removeFromSuperview() }
    stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
    cells = (0..<count).map { _ in
      let cell = ChatListCell(frame: .zero)
      cell.isUserInteractionEnabled = false
      cell.backgroundColor = .clear
      cell.contentView.backgroundColor = .clear
      // Height container for the cell inside the stack
      let host = UIView()
      host.backgroundColor = .clear
      host.addSubview(cell)
      cell.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        cell.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        cell.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        cell.topAnchor.constraint(equalTo: host.topAnchor),
        cell.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        host.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
      ])
      stack.addArrangedSubview(host)
      return cell
    }
  }

  private func reconfigureCells() {
    let r = appearance.messageCornerRadius
    let rows: [ChatListRow]
    switch mode {
    case .compact:
      rows = [
        ChatAppearancePreviewSamples.themRow(
          text: "How does it work?", radius: r, withTail: false),
        ChatAppearancePreviewSamples.meRow(
          text: "Use your current colors", radius: r),
      ]
    case .full:
      rows = [
        ChatAppearancePreviewSamples.themRow(
          text: "Does he want me to turn from the right or turn from the left? 🤔",
          radius: r),
        ChatAppearancePreviewSamples.voiceRow(radius: r),
        ChatAppearancePreviewSamples.meRow(
          text: "Is that everything? It seemed like he said quite a bit more than that. 😮",
          radius: r),
      ]
    }
    for (cell, row) in zip(cells, rows) {
      cell.applyAppearance(appearance)
      cell.configure(
        row: row,
        hiddenMessageId: nil,
        skipRemoteMediaLoad: true
      )
    }
  }

  private func layoutCells() {
    let width = bounds.width - 24
    guard width > 1 else { return }
    for cell in cells {
      guard let host = cell.superview else { continue }
      // Force layout pass so bubble metrics match production
      cell.bounds = CGRect(x: 0, y: 0, width: width, height: max(host.bounds.height, 60))
      cell.contentView.frame = cell.bounds
      cell.setNeedsLayout()
      cell.layoutIfNeeded()
      // Prefer intrinsic height after layout
      let target = cell.systemLayoutSizeFitting(
        CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
        withHorizontalFittingPriority: .required,
        verticalFittingPriority: .fittingSizeLevel
      )
      let h = max(48, min(160, target.height))
      host.constraints.filter { $0.firstAttribute == .height }.forEach { host.removeConstraint($0) }
      host.heightAnchor.constraint(equalToConstant: h).isActive = true
      cell.frame = CGRect(x: 0, y: 0, width: width, height: h)
      cell.contentView.frame = cell.bounds
    }
  }
}

// MARK: - SwiftUI bridge

struct ChatAppearanceLiveHost: UIViewRepresentable {
  let draft: ChatAppearanceDraft
  var mode: ChatAppearanceLiveHostView.Mode = .full

  func makeUIView(context: Context) -> ChatAppearanceLiveHostView {
    let view = ChatAppearanceLiveHostView()
    view.apply(draft: draft, mode: mode)
    return view
  }

  func updateUIView(_ uiView: ChatAppearanceLiveHostView, context: Context) {
    uiView.apply(draft: draft, mode: mode)
  }
}

// MARK: - Abstract theme / wallpaper thumbs (no message text)

/// Compact tile: wallpaper wash + two bubble capsules + optional emoji.
/// Used in theme grids — never full mock message text.
struct AppearanceThemeThumbView: View {
  let draft: ChatAppearanceDraft
  var emoji: String? = nil
  var selected: Bool = false

  private var appearance: ChatListAppearance {
    ChatListAppearance.from(draft: draft)
  }

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      // Wallpaper (same colors as production model)
      LinearGradient(
        colors: appearance.wallpaperGradient.map { Color(uiColor: $0) },
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      WallpaperPatternPreview(appearance: appearance)

      // Bubble mockups: bounded `HStack` + `Spacer(minLength:)` rows so a
      // narrow tile (the 72pt COLOR THEME strip) never reports an intrinsic
      // width larger than what it was offered. The previous
      // `.frame(width: 44/54).frame(maxWidth: .infinity).padding(20)` chain
      // let the fixed-width capsule win over a tight proposal, inflating
      // this view's (and its clipShape's) width past the frame the caller
      // assigned — which is what bled tiles into their neighbors.
      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 0) {
          Capsule()
            .fill(
              LinearGradient(
                colors: appearance.bubbleThemGradient.map { Color(uiColor: $0) },
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .frame(width: 26, height: 14)
          Spacer(minLength: 6)
        }
        HStack(spacing: 0) {
          Spacer(minLength: 6)
          Capsule()
            .fill(
              LinearGradient(
                colors: appearance.bubbleMeGradient.map { Color(uiColor: $0) },
                startPoint: .leading,
                endPoint: .trailing
              )
            )
            .frame(width: 32, height: 14)
        }
      }
      .padding(10)

      if let emoji {
        Text(emoji)
          .font(.system(size: 16))
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
          .padding(8)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(
          selected
            ? Color(uiColor: ChatListAppearance.brandAccentFallback)
            : Color.white.opacity(0.12),
          lineWidth: selected ? 2.5 : 1
        )
    )
    .shadow(
      color: selected
        ? Color(uiColor: ChatListAppearance.brandAccentFallback).opacity(0.35)
        : .clear,
      radius: selected ? 6 : 0, x: 0, y: selected ? 2 : 0
    )
  }
}

// MARK: - Wallpaper pattern preview (mask over gradient, mirrors ChatWallpaperView)

/// SwiftUI mirror of `ChatWallpaperView`'s `patternLayer` + `patternMaskLayer`: the
/// pattern's own gradient is masked by the wallpaper mask image, never drawn as
/// ordinary image content. The mask (device-resolution SVG rasterization used for
/// `doodles`/`hearts`) is alpha-only — it has no color channels, so treating it as
/// image content (as this used to via `.blendMode(.overlay)`) reads it as solid
/// black with only alpha varying, crushing every swatch toward black. Using it as
/// a `.mask()` reads only its alpha, which is all a mask should ever contribute.
struct WallpaperPatternPreview: View {
  let appearance: ChatListAppearance

  /// Decoded mask, or nil until the off-main decode lands.
  ///
  /// This used to call `ChatWallpaperMaskStore.image(forKey:)` inline in `body`, which
  /// rasterises a full-screen vector on a cache miss. SwiftUI evaluates `body` on the
  /// main thread, so the wallpaper picker — which builds one of these per option —
  /// froze the app for the length of the decode: two `[mainhang]` samples in one
  /// session, 0.51s and 0.75s, both with `WallpaperPatternPreview.body.getter` directly
  /// under `renderAlphaOnly`. Cache hits still resolve on the first `body`, so a
  /// warm picker looks exactly as it did.
  @State private var maskImage: CGImage?

  private var maskKey: String? {
    guard appearance.backgroundMode != "transparent",
      appearance.wallpaperPatternGradient.count >= 2,
      appearance.wallpaperPatternOpacity > 0.001,
      let key = appearance.wallpaperMaskKey, !key.isEmpty
    else { return nil }
    return key
  }

  var body: some View {
    Group {
      if let cgImage = maskImage ?? maskKey.flatMap({ ChatWallpaperMaskStore.cachedImage(forKey: $0) }) {
        patternGradient
          .mask(
            Image(decorative: cgImage, scale: 1, orientation: .up)
              .resizable()
              .scaledToFill()
          )
          .opacity(Double(max(0.04, appearance.wallpaperPatternOpacity)))
          .allowsHitTesting(false)
      }
    }
    .onAppear(perform: loadMaskIfNeeded)
    .onChange(of: appearance.visualKey) { _, _ in
      maskImage = nil
      loadMaskIfNeeded()
    }
  }

  private func loadMaskIfNeeded() {
    guard maskImage == nil, let key = maskKey else { return }
    if let cached = ChatWallpaperMaskStore.cachedImage(forKey: key) {
      maskImage = cached
      return
    }
    ChatWallpaperMaskStore.prewarm(key: key) { ok in
      guard ok else { return }
      DispatchQueue.main.async {
        guard maskKey == key else { return }
        maskImage = ChatWallpaperMaskStore.cachedImage(forKey: key)
      }
    }
  }

  private var patternGradient: LinearGradient {
    LinearGradient(
      gradient: patternGradientStops, startPoint: .topLeading, endPoint: .bottomTrailing)
  }

  private var patternGradientStops: Gradient {
    let colors = appearance.wallpaperPatternGradient.map { Color(uiColor: $0) }
    if let locations = appearance.wallpaperPatternLocations, locations.count == colors.count {
      return Gradient(
        stops: zip(colors, locations).map {
          Gradient.Stop(color: $0, location: CGFloat($1.doubleValue))
        }
      )
    }
    return Gradient(colors: colors)
  }
}

// MARK: - Wallpaper catalog

struct AppearanceWallpaperOption: Identifiable, Equatable {
  let id: String
  let title: String
  /// nil = solid / no pattern
  let maskKey: String?
  let emoji: String
}

enum AppearanceWallpaperCatalog {
  static let all: [AppearanceWallpaperOption] = [
    .init(id: "doodles", title: "Doodles", maskKey: "doodles", emoji: "✏️"),
    .init(id: "music", title: "Music", maskKey: "music", emoji: "🎵"),
    .init(id: "music2", title: "Pulse", maskKey: "music2", emoji: "🎧"),
    .init(id: "food", title: "Food", maskKey: "food", emoji: "🍕"),
    .init(id: "animals", title: "Animals", maskKey: "animals", emoji: "🐱"),
    .init(id: "cosmos", title: "Cosmos", maskKey: "cosmos", emoji: "🚀"),
    .init(id: "none", title: "None", maskKey: nil, emoji: "⬛"),
  ]
}

struct ChatWallpaperPickerView: View {
  @Binding var draft: ChatAppearanceDraft
  @Environment(\.colorScheme) private var colorScheme
  @State private var previewOption: AppearanceWallpaperOption?

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private let columns = [
    GridItem(.flexible(), spacing: 10),
    GridItem(.flexible(), spacing: 10),
    GridItem(.flexible(), spacing: 10),
  ]

  /// A gallery, nothing else. The live preview banner used to sit above this grid, but
  /// it competed with the very artwork it was previewing and the user read its updates
  /// as the picker having already changed their wallpaper. Selection now happens in one
  /// place only: the full-screen preview's Set button.
  var body: some View {
    ScrollView {
      LazyVGrid(columns: columns, spacing: 12) {
        ForEach(AppearanceWallpaperCatalog.all) { option in
          Button {
            previewOption = option
          } label: {
            wallpaperThumb(option: option, selected: selectedId == option.id)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 14)
    }
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Chat Wallpaper")
    .navigationBarTitleDisplayMode(.inline)
    .fullScreenCover(item: $previewOption) { option in
      WallpaperPreviewSheet(option: option, baseDraft: draft) { committed in
        draft = committed
        ChatAppearanceDraftStore.save(committed)
      }
    }
  }

  private var selectedId: String {
    if let key = draft.wallpaperPatternMaskKey, !key.isEmpty {
      return key
    }
    return "none"
  }

  private func wallpaperThumb(option: AppearanceWallpaperOption, selected: Bool) -> some View {
    var thumbDraft = draft
    thumbDraft.wallpaperPatternMaskKey = option.maskKey
    // Thumbs read at a fixed legible intensity. Using the live opacity made every tile
    // fade together whenever the user had turned the pattern down, so the grid stopped
    // showing what it was meant to be choosing between.
    thumbDraft.wallpaperPatternOpacity = option.maskKey == nil ? 0 : 0.34
    let accent = Color(uiColor: ChatListAppearance.brandAccentFallback)
    return ZStack(alignment: .bottomLeading) {
      AppearanceThemeThumbView(draft: thumbDraft, emoji: option.emoji, selected: false)

      Text(option.title)
        .font(.system(size: 11, weight: .semibold))
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.45)))
        .padding(8)

      if selected {
        Image(systemName: "checkmark")
          .font(.system(size: 11, weight: .bold))
          .foregroundColor(.black.opacity(0.85))
          .frame(width: 22, height: 22)
          .background(Circle().fill(accent))
          .padding(8)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
      }
    }
    // Portrait 3:4 tile — matches how a wallpaper actually reads behind a
    // full chat column, rather than the old near-square crop.
    .aspectRatio(3.0 / 4.0, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(selected ? accent : Color.white.opacity(0.10), lineWidth: selected ? 2 : 1)
    )
  }
}

// MARK: - Wallpaper full-screen preview sheet

/// Full-screen preview of one wallpaper.
///
/// Rendered through `ChatAppearanceLiveHost` — the production UIKit pipeline with real
/// `ChatListCell`s — rather than the SwiftUI mock canvas. The mock resolved its colours
/// independently of `ChatWallpaperView`, which is why the preview did not match the
/// wallpaper the chat list actually painted.
///
/// Everything adjustable lives in one floating console at the bottom: colours, pattern
/// intensity, and the commit. `baseDraft` is a snapshot and every edit stays local, so
/// closing without pressing Set Wallpaper cannot change anything.
private struct WallpaperPreviewSheet: View {
  let option: AppearanceWallpaperOption
  let baseDraft: ChatAppearanceDraft
  /// Hands back the fully-resolved draft — wallpaper, colours and intensity together —
  /// so one Set commits everything the console changed.
  var onSet: (ChatAppearanceDraft) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var themeId: String?
  @State private var opacity: Double

  init(
    option: AppearanceWallpaperOption,
    baseDraft: ChatAppearanceDraft,
    onSet: @escaping (ChatAppearanceDraft) -> Void
  ) {
    self.option = option
    self.baseDraft = baseDraft
    self.onSet = onSet
    _themeId = State(initialValue: baseDraft.themeId)
    _opacity = State(
      initialValue: baseDraft.wallpaperPatternOpacity < 0.05
        ? 0.17 : baseDraft.wallpaperPatternOpacity)
  }

  private var previewDraft: ChatAppearanceDraft {
    var next = baseDraft
    if let themeId, themeId != baseDraft.themeId {
      next = next.applying(themeId: themeId)
    }
    next.wallpaperPatternMaskKey = option.maskKey
    next.wallpaperPatternOpacity = option.maskKey == nil ? 0 : opacity
    next.wallpaperKind = option.maskKey == nil ? "solid" : "gradient"
    return next
  }

  private var accent: Color { Color(uiColor: ChatListAppearance.brandAccentFallback) }

  var body: some View {
    ZStack(alignment: .bottom) {
      ChatAppearanceLiveHost(draft: previewDraft, mode: .full)
        .ignoresSafeArea()

      topBar
        .frame(maxHeight: .infinity, alignment: .top)

      console
    }
    .preferredColorScheme(.dark)
  }

  private var topBar: some View {
    HStack {
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 14, weight: .bold))
          .foregroundColor(.white)
          .frame(width: 34, height: 34)
          .background(Circle().fill(.ultraThinMaterial))
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close")

      Spacer()

      Text(option.title)
        .font(.system(size: 17, weight: .semibold))
        .foregroundColor(.white)
        .shadow(color: .black.opacity(0.45), radius: 5)

      Spacer()
      Color.clear.frame(width: 34, height: 34)
    }
    .padding(.horizontal, 16)
    .padding(.top, 12)
  }

  /// One console instead of controls scattered over the artwork: colours, intensity and
  /// the commit stack in a single glass panel, so the wallpaper keeps the whole screen.
  private var console: some View {
    VStack(spacing: 16) {
      VStack(alignment: .leading, spacing: 10) {
        Text("Colors")
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(.white.opacity(0.65))

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 10) {
            ForEach(AppearanceThemeCatalog.plates) { card in
              colorPlate(card: card)
            }
          }
          .padding(.horizontal, 2)
        }
      }

      if option.maskKey != nil {
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("Pattern intensity")
              .font(.system(size: 12, weight: .semibold))
              .foregroundColor(.white.opacity(0.65))
            Spacer()
            Text("\(Int(opacity * 100))%")
              .font(.system(size: 12, weight: .medium, design: .monospaced))
              .foregroundColor(.white.opacity(0.65))
          }
          Slider(value: $opacity, in: 0...0.4)
            .tint(accent)
        }
      }

      Button {
        onSet(previewDraft)
        dismiss()
      } label: {
        Text("Set Wallpaper")
          .font(.system(size: 17, weight: .semibold))
          .foregroundColor(.black.opacity(0.88))
          .frame(maxWidth: .infinity)
          .padding(.vertical, 14)
          .background(Capsule().fill(Color.white.opacity(0.95)))
      }
      .buttonStyle(.plain)
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 26, style: .continuous)
        .fill(.ultraThinMaterial)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 26, style: .continuous)
        .stroke(Color.white.opacity(0.12), lineWidth: 1)
    )
    .padding(.horizontal, 14)
    .padding(.bottom, 14)
  }

  private func colorPlate(card: AppearanceThemeCard) -> some View {
    let resolved = ChatListAppearance.from(draft: baseDraft.applying(themeId: card.id))
    let colors = resolved.wallpaperGradient.map { Color(uiColor: $0) }
    let selected = (themeId ?? baseDraft.themeId) == card.id
    return Button {
      themeId = card.id
    } label: {
      Circle()
        .fill(
          LinearGradient(
            colors: colors.count >= 2 ? colors : [colors.first ?? .gray, colors.first ?? .gray],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        )
        .frame(width: 38, height: 38)
        .overlay(
          Circle().stroke(selected ? accent : Color.white.opacity(0.18), lineWidth: selected ? 2.5 : 1)
        )
        .overlay(
          Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .opacity(selected ? 1 : 0)
        )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(card.title)
  }
}
