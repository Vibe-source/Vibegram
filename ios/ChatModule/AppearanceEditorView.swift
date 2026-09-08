import SwiftUI
import UIKit

// MARK: - Color targeting (color editor)

enum ColorTarget: Equatable {
  case wallpaper(index: Int)
  case wallpaperScroll(index: Int)
  case bubbleMe(index: Int)
  case bubbleThem(index: Int)
  case accent
}

// MARK: - Draft helpers

extension ChatAppearanceDraft {
  /// Apply a native theme plate into this draft (hex fields + mask).
  func applying(themeId: String) -> ChatAppearanceDraft {
    var next = self
    next.themeId = themeId
    let isDark: Bool = {
      switch mode.lowercased() {
      case "light": return false
      case "dark": return true
      default:
        return ChatListAppearance.resolvedSystemStyle() == .dark
      }
    }()
    // Resolve via native preset path (no version key).
    let resolved = ChatListAppearance.from(raw: [
      "theme": isDark ? "dark" : "light",
      "backgroundMode": "gradient",
      "wallpaperOpacity": 1.0,
      "nativeThemeId": themeId,
      "nativeThemeIsDark": isDark,
    ])
    next.wallpaperKind = "gradient"
    next.wallpaperGradient = resolved.wallpaperGradient.map(appearanceUIColorHex)
    next.bubbleMeGradient = resolved.bubbleMeGradient.map(appearanceUIColorHex)
    next.bubbleThemGradient = resolved.bubbleThemGradient.map(appearanceUIColorHex)
    next.accent = appearanceUIColorHex(resolved.accent)
    next.wallpaperPatternMaskKey = resolved.wallpaperMaskKey
    next.wallpaperPatternOpacity = Double(resolved.wallpaperPatternOpacity)
    if resolved.messageCornerRadius > 1 {
      let clamped = max(4.0, min(26.0, Double(resolved.messageCornerRadius)))
      next.messageCornerRadius = (clamped - 4.0) / 22.0
    }
    return next
  }

  var accentColor: Color { Color(hex: accent) ?? Color(red: 0.18, green: 0.62, blue: 0.58) }
}

// MARK: - Shared full-bleed chat canvas

/// Real chat-style surface driven by `ChatListAppearance.from(draft:)`.
/// Used as hub preview, color-editor backdrop, corners sheet, create-theme preview.
struct ChatAppearanceCanvas: View {
  let draft: ChatAppearanceDraft
  var compact: Bool = false
  var showsVoice: Bool = true
  var showsReply: Bool = true

  private var appearance: ChatListAppearance {
    ChatListAppearance.from(draft: draft)
  }

  private var corner: CGFloat { appearance.messageCornerRadius }

  var body: some View {
    ZStack {
      LinearGradient(
        colors: appearance.wallpaperGradient.map { Color(uiColor: $0) },
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      WallpaperPatternPreview(appearance: appearance)

      VStack(alignment: .leading, spacing: compact ? 8 : 10) {
        if !compact {
          dayChip
        }

        themBubble(
          name: showsReply ? "Alex" : nil,
          text: compact
            ? "How does it work?"
            : "Does he want me to turn from the right or turn from the left? 🤔"
        )

        if showsVoice && !compact {
          voiceRow
        }

        if showsReply && !compact {
          replyRow
        }

        meBubble(
          text: compact
            ? "Use your current colors"
            : "Is that everything? It seemed like he said quite a bit more than that. 😮"
        )
      }
      .padding(compact ? 12 : 16)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: compact ? .center : .bottom)
    }
    .clipped()
  }

  private var dayChip: some View {
    Text("Today")
      .font(.system(size: 12, weight: .semibold))
      .foregroundColor(Color(uiColor: appearance.dayTextColor))
      .padding(.horizontal, 12)
      .padding(.vertical, 5)
      .background(
        Capsule().fill(Color(uiColor: appearance.dayBackgroundColor))
      )
      .overlay(
        Capsule().stroke(Color(uiColor: appearance.dayBorderColor), lineWidth: 0.5)
      )
      .frame(maxWidth: .infinity)
  }

  private func themBubble(name: String?, text: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if let name {
        Text(name)
          .font(.system(size: 13, weight: .semibold))
          .foregroundColor(Color(uiColor: appearance.accent))
      }
      Text(text)
        .font(.system(size: compact ? 13 : 15, weight: .regular))
        .foregroundColor(Color(uiColor: appearance.textColorThem))
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(bubbleThemFill)
    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.trailing, compact ? 28 : 48)
  }

  private func meBubble(text: String) -> some View {
    Text(text)
      .font(.system(size: compact ? 13 : 15, weight: .regular))
      .foregroundColor(Color(uiColor: appearance.textColorMe))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .background(bubbleMeFill)
      .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
      .frame(maxWidth: .infinity, alignment: .trailing)
      .padding(.leading, compact ? 28 : 48)
  }

  private var voiceRow: some View {
    let accent = Color(uiColor: appearance.accent)
    let inactive = Color(uiColor: appearance.accent.withAlphaComponent(0.32))
    let heights: [CGFloat] = [8, 14, 10, 18, 12, 16, 9, 15, 11, 17, 10, 14, 8, 16, 12]
    return HStack(spacing: 10) {
      Circle()
        .fill(accent)
        .frame(width: 36, height: 36)
        .overlay(
          Image(systemName: "play.fill")
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(.white)
            .offset(x: 1)
        )
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 2) {
          ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
            RoundedRectangle(cornerRadius: 1, style: .continuous)
              .fill(index % 3 == 0 ? accent : inactive)
              .frame(width: 2.5, height: height)
          }
        }
        Text("0:23")
          .font(.system(size: 11, weight: .medium))
          .foregroundColor(Color(uiColor: appearance.timeColorThem))
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(bubbleThemFill)
    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    .padding(.trailing, 56)
  }

  private var bubbleThemFill: some View {
    LinearGradient(
      colors: appearance.bubbleThemGradient.map { Color(uiColor: $0) },
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  private var bubbleMeFill: some View {
    LinearGradient(
      colors: appearance.bubbleMeGradient.map { Color(uiColor: $0) },
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  private var replyRow: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        RoundedRectangle(cornerRadius: 1.5)
          .fill(Color(uiColor: appearance.accent))
          .frame(width: 3, height: 28)
        VStack(alignment: .leading, spacing: 1) {
          Text("Alex")
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Color(uiColor: appearance.accent))
          Text("Does he want me to turn from the right…")
            .font(.system(size: 12))
            .foregroundColor(Color(uiColor: appearance.textColorThem).opacity(0.75))
            .lineLimit(1)
        }
      }
      Text("Right side. And, uh, with intensity.")
        .font(.system(size: 15))
        .foregroundColor(Color(uiColor: appearance.textColorThem))
    }
    .padding(10)
    .background(bubbleThemFill)
    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    .padding(.trailing, 40)
  }
}

// MARK: - Theme catalog

struct AppearanceThemeCard: Identifiable, Equatable {
  let id: String
  let emoji: String
  let title: String
}

enum AppearanceThemeCatalog {
  static let all: [AppearanceThemeCard] = [
    .init(id: "glacier", emoji: "💎", title: "Aurora"),
    .init(id: "zen", emoji: "🐣", title: "Mist"),
    .init(id: "ocean", emoji: "🏠", title: "Fresh"),
    .init(id: "obsidian", emoji: "☃️", title: "Mono"),
    .init(id: "music", emoji: "💜", title: "Pulse"),
    .init(id: "terracotta", emoji: "🌷", title: "Ember"),
    .init(id: "leaf", emoji: "🎄", title: "Leaf"),
    .init(id: "glacier", emoji: "🎮", title: "Arcade"),  // visual variety; same plate
    .init(id: "music", emoji: "🎓", title: "Studio"),
  ]

  /// Unique plates only (for applying themeId).
  static let plates: [AppearanceThemeCard] = AppThemePlateOption.allCases.map { plate in
    let emoji: String
    switch plate {
    case .glacier: emoji = "💎"
    case .zen: emoji = "🐣"
    case .ocean: emoji = "🌊"
    case .obsidian: emoji = "⬛"
    case .music: emoji = "💜"
    case .terracotta: emoji = "🔥"
    case .leaf: emoji = "🍃"
    }
    return AppearanceThemeCard(id: plate.rawValue, emoji: emoji, title: plate.title)
  }
}

// MARK: - Appearance HUB (Settings entry)

/// Telegram-class Appearance home: live preview, theme strip, inner-page rows.
struct AppearanceHubView: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.dismiss) private var dismiss

  @State private var draft: ChatAppearanceDraft = ChatAppearanceDraftStore.load()
  @State private var showColorEditor = false
  @State private var colorEditorTab: AppearanceColorTab = .accent
  @State private var showCorners = false
  @State private var showCreateTheme = false

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    ScrollView(showsIndicators: false) {
      VStack(spacing: 18) {
        // Live production chat preview (ChatListCell + real wallpaper)
        ChatAppearanceLiveHost(draft: draft, mode: .compact)
          .frame(height: 168)
          .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
              .stroke(palette.border.opacity(0.5), lineWidth: 1)
          )
          .padding(.horizontal, 16)
          .padding(.top, 8)
          .accessibilityLabel("Appearance preview")

        // Theme strip
        VStack(alignment: .leading, spacing: 10) {
          Text("COLOR THEME")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.secondaryText.opacity(0.7))
            .padding(.horizontal, 16)

          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
              ForEach(AppearanceThemeCatalog.plates) { card in
                Button {
                  applyTheme(card.id)
                } label: {
                  themeThumb(card: card, selected: draft.themeId == card.id)
                }
                .buttonStyle(.plain)
              }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
          }
        }

        // Inner pages — primary navigation
        settingsGroup {
          navRow("Chat Themes") {
            ChatThemesView(draft: $draft, onCreate: { showCreateTheme = true })
          }
          groupDivider
          wallpaperRow
          groupDivider
          yourColorRow
          groupDivider
          nightModeRow
          groupDivider
          autoNightRow
        }

        settingsGroup {
          textSizeRow
          groupDivider
          Button {
            showCorners = true
          } label: {
            rowLabel("Message Shape", trailing: chevron)
          }
          .buttonStyle(.plain)
          groupDivider
          animationsRow
        }
      }
      .padding(.bottom, 28)
    }
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Appearance")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { draft = ChatAppearanceDraftStore.load() }
    .onChange(of: draft) { next in
      persist(next)
    }
    .fullScreenCover(isPresented: $showColorEditor) {
      ChatAppearanceColorEditor(
        draft: $draft,
        initialTab: colorEditorTab,
        onCancel: {
          draft = ChatAppearanceDraftStore.load()
          showColorEditor = false
        },
        onSet: { next in
          draft = next
          persist(next)
          showColorEditor = false
        }
      )
    }
    .fullScreenCover(isPresented: $showCorners) {
      MessageCornersView(
        draft: $draft,
        onCancel: {
          draft = ChatAppearanceDraftStore.load()
          showCorners = false
        },
        onSet: { next in
          draft = next
          persist(next)
          showCorners = false
        }
      )
    }
    .sheet(isPresented: $showCreateTheme) {
      NavigationStack {
        CreateThemeView(draft: $draft) {
          showCreateTheme = false
          colorEditorTab = .messages
          showColorEditor = true
        }
      }
      .presentationDetents([.medium, .large])
    }
  }

  // MARK: Rows

  private var groupDivider: some View {
    Divider().padding(.leading, 16)
  }

  private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(spacing: 0, content: content)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(palette.card)
      )
      .padding(.horizontal, 16)
  }

  private func navRow<Dest: View>(_ title: String, @ViewBuilder destination: () -> Dest) -> some View
  {
    NavigationLink(destination: destination) {
      rowLabel(title, trailing: chevron)
    }
    .buttonStyle(.plain)
  }

  private var wallpaperRow: some View {
    NavigationLink {
      ChatWallpaperPickerView(draft: $draft)
    } label: {
      rowLabel("Chat Wallpaper", trailing: chevron)
    }
    .buttonStyle(.plain)
  }

  private var yourColorRow: some View {
    Button {
      colorEditorTab = .accent
      showColorEditor = true
    } label: {
      rowLabel(
        "Your Color",
        trailing: HStack(spacing: 10) {
          Circle()
            .fill(draft.accentColor)
            .frame(width: 22, height: 22)
            .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
          chevron
        }
      )
    }
    .buttonStyle(.plain)
  }

  private var nightModeRow: some View {
    HStack {
      Text("Night Mode")
        .font(.system(size: 17))
        .foregroundStyle(palette.text)
      Spacer()
      Toggle(
        "",
        isOn: Binding(
          get: { draft.mode == "dark" },
          set: { on in
            draft.mode = on ? "dark" : "light"
            if let themeId = draft.themeId {
              draft = draft.applying(themeId: themeId)
            }
            applyAppChrome()
          }
        )
      )
      .labelsHidden()
      .tint(palette.accent)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var autoNightRow: some View {
    Button {
      draft.mode = "system"
      applyAppChrome()
    } label: {
      rowLabel(
        "Auto-Night Mode",
        trailing: HStack(spacing: 8) {
          Text(draft.mode == "system" ? "System" : "Off")
            .font(.system(size: 16))
            .foregroundStyle(palette.secondaryText)
          chevron
        }
      )
    }
    .buttonStyle(.plain)
  }

  private var textSizeRow: some View {
    HStack {
      Text("Text Size")
        .font(.system(size: 17))
        .foregroundStyle(palette.text)
      Spacer()
      Text(String(format: "%.0f%%", draft.textScale * 100))
        .font(.system(size: 16))
        .foregroundStyle(palette.secondaryText)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    // Slider on long-press alternative: expand inline
    .overlay(alignment: .bottom) {
      EmptyView()
    }
    .contextMenu {
      Button("Small") { draft.textScale = 0.9 }
      Button("Default") { draft.textScale = 1.0 }
      Button("Large") { draft.textScale = 1.15 }
      Button("Extra Large") { draft.textScale = 1.3 }
    }
  }

  private var animationsRow: some View {
    HStack {
      Text("Animations")
        .font(.system(size: 17))
        .foregroundStyle(palette.text)
      Spacer()
      Toggle(
        "",
        isOn: Binding(
          get: { draft.animationsEnabled },
          set: { draft.animationsEnabled = $0 }
        )
      )
      .labelsHidden()
      .tint(palette.accent)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private func rowLabel<Trailing: View>(_ title: String, trailing: Trailing?) -> some View {
    HStack {
      Text(title)
        .font(.system(size: 17))
        .foregroundStyle(palette.text)
      Spacer()
      if let trailing {
        trailing
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .contentShape(Rectangle())
  }

  private var chevron: some View {
    Image(systemName: "chevron.right")
      .font(.system(size: 13, weight: .semibold))
      .foregroundStyle(palette.secondaryText.opacity(0.55))
  }

  private func themeThumb(card: AppearanceThemeCard, selected: Bool) -> some View {
    let previewDraft = draft.applying(themeId: card.id)
    return AppearanceThemeThumbView(draft: previewDraft, emoji: card.emoji, selected: selected)
      .frame(width: 72, height: 88)
  }

  private func applyTheme(_ themeId: String) {
    draft = draft.applying(themeId: themeId)
    if let plate = AppThemePlateOption(rawValue: themeId) {
      AppThemePlateController.setOption(plate)
    }
    persist(draft)
  }

  private func persist(_ next: ChatAppearanceDraft) {
    ChatAppearanceDraftStore.save(next)
    applyAppChrome()
  }

  private func applyAppChrome() {
    if let option = AppAppearanceOption(rawValue: draft.mode) {
      AppAppearanceController.setOption(option)
    }
    if let themeId = draft.themeId, let plate = AppThemePlateOption(rawValue: themeId) {
      AppThemePlateController.setOption(plate)
    }
  }
}

// MARK: - Chat Themes page

struct ChatThemesView: View {
  @Binding var draft: ChatAppearanceDraft
  var onCreate: () -> Void
  @Environment(\.colorScheme) private var colorScheme

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  private let columns = [
    GridItem(.flexible(), spacing: 10),
    GridItem(.flexible(), spacing: 10),
    GridItem(.flexible(), spacing: 10),
  ]

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("SELECT A THEME")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(palette.secondaryText.opacity(0.7))
          .padding(.horizontal, 4)

        LazyVGrid(columns: columns, spacing: 10) {
          ForEach(AppearanceThemeCatalog.plates) { card in
            Button {
              draft = draft.applying(themeId: card.id)
              ChatAppearanceDraftStore.save(draft)
              if let plate = AppThemePlateOption(rawValue: card.id) {
                AppThemePlateController.setOption(plate)
              }
            } label: {
              AppearanceThemeThumbView(
                draft: draft.applying(themeId: card.id),
                emoji: card.emoji,
                selected: draft.themeId == card.id
              )
              .frame(height: 112)
            }
            .buttonStyle(.plain)
          }
        }

        Text("BUILD YOUR OWN THEME")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(palette.secondaryText.opacity(0.7))
          .padding(.horizontal, 4)
          .padding(.top, 8)

        Button(action: onCreate) {
          VStack(alignment: .leading, spacing: 10) {
            ChatAppearanceLiveHost(draft: draft, mode: .compact)
              .frame(height: 130)
              .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            Text("Create Theme…")
              .font(.system(size: 16, weight: .semibold))
              .foregroundStyle(Color(uiColor: ChatListAppearance.brandAccentFallback))
          }
          .padding(12)
          .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
              .fill(palette.card)
          )
        }
        .buttonStyle(.plain)

        HStack(spacing: 8) {
          modeChip("Light", selected: draft.mode == "light") {
            setMode(.light)
          }
          modeChip("Dark", selected: draft.mode == "dark") {
            setMode(.dark)
          }
          modeChip("System", selected: draft.mode == "system") {
            setMode(.system)
          }
        }
        .padding(.top, 4)
      }
      .padding(16)
    }
    .background(palette.background.ignoresSafeArea())
    .navigationTitle("Chat Themes")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func setMode(_ option: AppAppearanceOption) {
    AppAppearanceController.setOption(option)
    draft = ChatAppearanceDraftStore.current
  }

  private func modeChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View
  {
    Button(action: action) {
      Text(title)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(selected ? Color.white : palette.text)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(selected ? Color(uiColor: ChatListAppearance.brandAccentFallback) : palette.card)
        )
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Create Theme

struct CreateThemeView: View {
  @Binding var draft: ChatAppearanceDraft
  var onChangeColors: () -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @State private var name: String = "My Theme"

  private var palette: AppThemePalette {
    AppThemePalette.resolve(for: colorScheme)
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button { dismiss() } label: {
          Image(systemName: "xmark")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(palette.text)
            .frame(width: 36, height: 36)
            .background(Circle().fill(palette.card))
        }
        Spacer()
        Text("Create Theme")
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(palette.text)
        Spacer()
        Button {
          ChatAppearanceDraftStore.save(draft)
          dismiss()
        } label: {
          Image(systemName: "checkmark")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color(uiColor: ChatListAppearance.brandAccentFallback)))
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          TextField("Theme name", text: $name)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
              Capsule().fill(palette.card)
            )
            .foregroundStyle(palette.text)

          Text("The theme will be based on your currently selected colors and wallpaper.")
            .font(.system(size: 13))
            .foregroundStyle(palette.secondaryText)

          Text("CHAT PREVIEW")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(palette.secondaryText.opacity(0.7))

          ChatAppearanceLiveHost(draft: draft, mode: .compact)
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

          VStack(spacing: 0) {
            Button(action: onChangeColors) {
              HStack {
                Text("Change Colors")
                  .foregroundStyle(Color(uiColor: ChatListAppearance.brandAccentFallback))
                Spacer()
              }
              .padding(16)
            }
            Divider()
            Button {
              // File import stub — keep row for parity
            } label: {
              HStack {
                Text("Create from File…")
                  .foregroundStyle(Color(uiColor: ChatListAppearance.brandAccentFallback))
                Spacer()
              }
              .padding(16)
            }
          }
          .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(palette.card)
          )

          Text("You can also use a manually edited custom theme file.")
            .font(.system(size: 13))
            .foregroundStyle(palette.secondaryText)
        }
        .padding(16)
      }
    }
    .background(palette.background.ignoresSafeArea())
  }
}

// MARK: - Color editor tabs

enum AppearanceColorTab: Int, CaseIterable {
  case background
  case accent
  case messages

  var title: String {
    switch self {
    case .background: return "Background"
    case .accent: return "Accent"
    case .messages: return "Messages"
    }
  }
}

// MARK: - Full-screen color editor (chat is the canvas)

struct ChatAppearanceColorEditor: View {
  @Binding var draft: ChatAppearanceDraft
  var initialTab: AppearanceColorTab = .background
  var onCancel: () -> Void
  var onSet: (ChatAppearanceDraft) -> Void

  @State private var tab: AppearanceColorTab = .background
  @State private var activeTarget: ColorTarget = .accent
  @State private var pickerHue: Double = 0.55
  @State private var pickerSaturation: Double = 0.55
  @State private var pickerBrightness: Double = 0.75
  @State private var hexInput: String = ""
  @State private var patternOn: Bool = true
  @State private var animateOn: Bool = true
  @State private var showColors: Bool = true

  var body: some View {
    ZStack {
      // Full-bleed production cells + wallpaper
      ChatAppearanceLiveHost(draft: draft, mode: .full)
        .ignoresSafeArea()

      // Soft bottom scrim so controls stay readable
      VStack {
        Spacer()
        LinearGradient(
          colors: [Color.black.opacity(0), Color.black.opacity(0.72), Color.black.opacity(0.92)],
          startPoint: .top,
          endPoint: .bottom
        )
        .frame(height: 420)
        .allowsHitTesting(false)
      }
      .ignoresSafeArea()

      VStack(spacing: 0) {
        // Floating tab pills
        HStack {
          Spacer()
          HStack(spacing: 0) {
            ForEach(AppearanceColorTab.allCases, id: \.rawValue) { item in
              Button {
                tab = item
                retargetForTab()
              } label: {
                Text(item.title)
                  .font(.system(size: 14, weight: .semibold))
                  .foregroundColor(tab == item ? .white : .white.opacity(0.7))
                  .padding(.horizontal, 14)
                  .padding(.vertical, 9)
                  .background(
                    Capsule().fill(tab == item ? Color.white.opacity(0.22) : Color.clear)
                  )
              }
              .buttonStyle(.plain)
            }
          }
          .padding(4)
          .background(Capsule().fill(Color.black.opacity(0.45)))
          .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
          Spacer()
        }
        .padding(.top, 56)

        Spacer()

        VStack(spacing: 12) {
          // Tool row
          HStack(spacing: 10) {
            toolPill(
              title: tab == .background ? "Pattern" : "Animate",
              systemImage: tab == .background ? "checkmark" : "checkmark",
              selected: tab == .background ? patternOn : animateOn
            ) {
              if tab == .background {
                patternOn.toggle()
                draft.wallpaperPatternOpacity = patternOn ? max(0.12, draft.wallpaperPatternOpacity) : 0
              } else {
                animateOn.toggle()
                draft.animationsEnabled = animateOn
              }
            }
            Circle()
              .fill(Color.white.opacity(0.12))
              .frame(width: 44, height: 44)
              .overlay(Image(systemName: "play.fill").foregroundColor(.white.opacity(0.85)))
            toolPill(title: "Colors", systemImage: "circle.lefthalf.filled", selected: showColors) {
              showColors.toggle()
            }
          }

          if showColors {
            // Swatches + hex
            HStack(spacing: 10) {
              ForEach(swatches, id: \.self) { hex in
                Button {
                  applyHex(hex)
                } label: {
                  Circle()
                    .fill(Color(hex: hex) ?? .gray)
                    .frame(width: 28, height: 28)
                    .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                }
                .buttonStyle(.plain)
              }
              HStack {
                TextField("#RRGGBB", text: $hexInput)
                  .textInputAutocapitalization(.characters)
                  .autocorrectionDisabled()
                  .font(.system(size: 15, weight: .medium, design: .monospaced))
                  .foregroundColor(.white)
                  .onSubmit { applyHex(hexInput) }
                Button {
                  hexInput = ""
                } label: {
                  Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
                }
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 10)
              .background(Capsule().fill(Color.white.opacity(0.12)))
            }
            .padding(.horizontal, 4)

            // Hue field (2D) + brightness
            AppearanceHueField(
              hue: $pickerHue,
              saturation: $pickerSaturation,
              brightness: $pickerBrightness
            )
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onChange(of: pickerHue) { _ in pushPickerToDraft() }
            .onChange(of: pickerSaturation) { _ in pushPickerToDraft() }
            .onChange(of: pickerBrightness) { _ in pushPickerToDraft() }

            AppearanceBrightnessBar(hue: pickerHue, saturation: pickerSaturation, brightness: $pickerBrightness)
              .frame(height: 28)
          }

          // Cancel / Set
          HStack(spacing: 12) {
            Button(action: onCancel) {
              Text("Cancel")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Capsule().fill(Color.white.opacity(0.16)))
            }
            Button {
              onSet(draft)
            } label: {
              Text("Set")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.black.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Capsule().fill(Color.white.opacity(0.92)))
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 28)
      }
    }
    .preferredColorScheme(.dark)
    .onAppear {
      tab = initialTab
      patternOn = draft.wallpaperPatternOpacity > 0.02
      animateOn = draft.animationsEnabled
      retargetForTab()
    }
  }

  private var swatches: [String] {
    switch tab {
    case .background:
      return Array(draft.wallpaperGradient.prefix(4))
    case .accent:
      return [draft.accent, "#3B8AE8", "#2C9A68", "#C85A28"]
    case .messages:
      return draft.bubbleMeGradient + draft.bubbleThemGradient.prefix(2)
    }
  }

  private func toolPill(
    title: String, systemImage: String, selected: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 6) {
        if selected {
          Image(systemName: "checkmark")
            .font(.system(size: 12, weight: .bold))
        }
        Text(title)
          .font(.system(size: 14, weight: .semibold))
      }
      .foregroundColor(.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      .background(Capsule().fill(Color.black.opacity(selected ? 0.55 : 0.35)))
      .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
    .buttonStyle(.plain)
  }

  private func retargetForTab() {
    switch tab {
    case .background:
      activeTarget = .wallpaper(index: 0)
    case .accent:
      activeTarget = .accent
    case .messages:
      activeTarget = .bubbleMe(index: 0)
    }
    syncPickerFromDraft()
  }

  private func syncPickerFromDraft() {
    let hex = currentHex()
    hexInput = hex
    let hsb = appearanceHexToHSB(hex)
    pickerHue = hsb.h
    pickerSaturation = hsb.s
    pickerBrightness = hsb.b
  }

  private func currentHex() -> String {
    switch activeTarget {
    case .wallpaper(let i):
      return draft.wallpaperGradient.indices.contains(i) ? draft.wallpaperGradient[i] : "#05050B"
    case .wallpaperScroll(let i):
      return draft.wallpaperScrollGradient.indices.contains(i)
        ? draft.wallpaperScrollGradient[i] : "#05050B"
    case .bubbleMe(let i):
      return draft.bubbleMeGradient.indices.contains(i) ? draft.bubbleMeGradient[i] : "#3B8AE8"
    case .bubbleThem(let i):
      return draft.bubbleThemGradient.indices.contains(i) ? draft.bubbleThemGradient[i] : "#252936"
    case .accent:
      return draft.accent
    }
  }

  private func applyHex(_ raw: String) {
    var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if !cleaned.hasPrefix("#") { cleaned = "#" + cleaned }
    guard cleaned.count == 7 || cleaned.count == 9 else { return }
    hexInput = cleaned
    setHexOnTarget(cleaned)
    let hsb = appearanceHexToHSB(cleaned)
    pickerHue = hsb.h
    pickerSaturation = hsb.s
    pickerBrightness = hsb.b
  }

  private func pushPickerToDraft() {
    let hex = appearanceHSBToHex(
      hue: pickerHue, saturation: pickerSaturation, brightness: pickerBrightness)
    hexInput = hex
    setHexOnTarget(hex)
  }

  private func setHexOnTarget(_ hex: String) {
    // Selecting a custom color clears pure theme lock for freeform edit.
    switch activeTarget {
    case .wallpaper(let i):
      ensureCount(&draft.wallpaperGradient, min: i + 1, fill: "#05050B")
      draft.wallpaperGradient[i] = hex
    case .wallpaperScroll(let i):
      ensureCount(&draft.wallpaperScrollGradient, min: i + 1, fill: "#05050B")
      draft.wallpaperScrollGradient[i] = hex
    case .bubbleMe(let i):
      ensureCount(&draft.bubbleMeGradient, min: max(2, i + 1), fill: "#3B8AE8")
      draft.bubbleMeGradient[i] = hex
    case .bubbleThem(let i):
      ensureCount(&draft.bubbleThemGradient, min: max(2, i + 1), fill: "#252936")
      draft.bubbleThemGradient[i] = hex
    case .accent:
      draft.accent = hex
    }
  }

  private func ensureCount(_ array: inout [String], min: Int, fill: String) {
    while array.count < min { array.append(fill) }
  }
}

// MARK: - Message Shape full-screen

struct MessageCornersView: View {
  @Binding var draft: ChatAppearanceDraft
  var onCancel: () -> Void
  var onSet: (ChatAppearanceDraft) -> Void

  var body: some View {
    ZStack {
      ChatAppearanceLiveHost(draft: draft, mode: .full)
        .ignoresSafeArea()

      VStack {
        Text("Message Shape")
          .font(.system(size: 17, weight: .semibold))
          .foregroundColor(.white)
          .padding(.top, 56)
          .shadow(radius: 4)
        Spacer()
      }

      VStack {
        Spacer()
        VStack(spacing: 16) {
          notchedSlider(
            title: "Corner Radius",
            value: Binding(
              get: { draft.messageCornerRadius },
              set: { draft.messageCornerRadius = $0 }
            ),
            leadingLabel: "Square",
            trailingLabel: "Round"
          )

          notchedSlider(
            title: "Tail Shape",
            value: Binding(
              get: {
                draft.messageTailCurvature
                  ?? Double(ChatAppearanceDraft.defaultMessageTailCurvature)
              },
              set: { draft.messageTailCurvature = $0 }
            ),
            leadingLabel: "Straight",
            trailingLabel: "Curved"
          )

          HStack(spacing: 12) {
            Button(action: onCancel) {
              Text("Cancel")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            Button {
              onSet(draft)
            } label: {
              Text("Set")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
          }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 28)
        .background(
          Rectangle()
            .fill(Color.black.opacity(0.72))
            .ignoresSafeArea(edges: .bottom)
        )
      }
    }
    .preferredColorScheme(.dark)
  }

  private func notchedSlider(
    title: String,
    value: Binding<Double>,
    leadingLabel: String,
    trailingLabel: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title)
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(.white)
        Spacer()
        Text(String(format: "%.0f%%", max(0.0, min(1.0, value.wrappedValue)) * 100.0))
          .font(.system(size: 13, weight: .medium, design: .rounded))
          .foregroundColor(.white.opacity(0.7))
      }

      GeometryReader { geo in
        let thumbSize: CGFloat = 26
        let trackWidth = max(1, geo.size.width - thumbSize)
        let progress = CGFloat(max(0.0, min(1.0, value.wrappedValue)))
        ZStack(alignment: .leading) {
          Capsule()
            .fill(Color.white.opacity(0.2))
            .frame(width: trackWidth, height: 4)
            .offset(x: thumbSize * 0.5)
          Capsule()
            .fill(Color(uiColor: ChatListAppearance.brandAccentFallback))
            .frame(width: max(4, progress * trackWidth), height: 4)
            .offset(x: thumbSize * 0.5)
          HStack {
            ForEach(0..<5, id: \.self) { index in
              Circle()
                .fill(Color.white.opacity(0.55))
                .frame(width: 5, height: 5)
              if index < 4 { Spacer() }
            }
          }
          .frame(width: trackWidth)
          .offset(x: thumbSize * 0.5)
          Circle()
            .fill(Color.white)
            .frame(width: thumbSize, height: thumbSize)
            .shadow(radius: 3)
            .offset(x: progress * trackWidth)
        }
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { drag in
              let normalized = (drag.location.x - thumbSize * 0.5) / trackWidth
              value.wrappedValue = Double(max(0.0, min(1.0, normalized)))
            }
        )
      }
      .frame(height: 28)

      HStack {
        Text(leadingLabel)
        Spacer()
        Text(trailingLabel)
      }
      .font(.system(size: 12, weight: .medium))
      .foregroundColor(.white.opacity(0.58))
    }
    .padding(.horizontal, 8)
  }
}

// MARK: - Hue field + brightness

private struct AppearanceHueField: View {
  @Binding var hue: Double
  @Binding var saturation: Double
  @Binding var brightness: Double

  var body: some View {
    GeometryReader { geo in
      ZStack {
        // Base hue
        LinearGradient(
          colors: stride(from: 0.0, through: 1.0, by: 0.1).map {
            Color(hue: $0, saturation: 1, brightness: 1)
          },
          startPoint: .leading,
          endPoint: .trailing
        )
        // White → transparent (saturation)
        LinearGradient(
          colors: [.white, .white.opacity(0)],
          startPoint: .leading,
          endPoint: .trailing
        )
        // Black overlay (brightness)
        LinearGradient(
          colors: [.clear, .black],
          startPoint: .top,
          endPoint: .bottom
        )

        Circle()
          .strokeBorder(Color.white, lineWidth: 3)
          .frame(width: 28, height: 28)
          .position(
            x: max(14, min(geo.size.width - 14, CGFloat(hue) * geo.size.width)),
            y: max(14, min(geo.size.height - 14, CGFloat(1 - brightness) * geo.size.height))
          )
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            hue = Double(max(0, min(1, value.location.x / max(1, geo.size.width))))
            brightness = Double(
              max(0, min(1, 1 - value.location.y / max(1, geo.size.height))))
            // Keep saturation lively while dragging field
            if saturation < 0.15 { saturation = 0.85 }
          }
      )
    }
  }
}

private struct AppearanceBrightnessBar: View {
  let hue: Double
  let saturation: Double
  @Binding var brightness: Double

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        LinearGradient(
          colors: [
            Color(hue: hue, saturation: saturation, brightness: 0),
            Color(hue: hue, saturation: saturation, brightness: 1),
          ],
          startPoint: .leading,
          endPoint: .trailing
        )
        .clipShape(Capsule())
        Circle()
          .fill(Color.white)
          .frame(width: 22, height: 22)
          .shadow(radius: 2)
          .offset(x: CGFloat(brightness) * geo.size.width - 11)
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            brightness = Double(max(0, min(1, value.location.x / max(1, geo.size.width))))
          }
      )
    }
  }
}

// MARK: - Color utilities

private func appearanceUIColorHex(_ color: UIColor) -> String {
  var r: CGFloat = 0
  var g: CGFloat = 0
  var b: CGFloat = 0
  var a: CGFloat = 0
  if color.getRed(&r, green: &g, blue: &b, alpha: &a) {
    return String(
      format: "#%02X%02X%02X",
      Int(round(r * 255)),
      Int(round(g * 255)),
      Int(round(b * 255))
    )
  }
  return "#000000"
}

private func appearanceHexToHSB(_ hex: String) -> (h: Double, s: Double, b: Double) {
  guard let ui = UIColor(appearanceHex: hex) else { return (0.55, 0.5, 0.7) }
  var h: CGFloat = 0
  var s: CGFloat = 0
  var b: CGFloat = 0
  var a: CGFloat = 0
  ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
  return (Double(h), Double(s), Double(b))
}

private func appearanceHSBToHex(hue: Double, saturation: Double, brightness: Double) -> String {
  let ui = UIColor(
    hue: CGFloat(hue), saturation: CGFloat(saturation), brightness: CGFloat(brightness), alpha: 1)
  return appearanceUIColorHex(ui)
}

private extension UIColor {
  convenience init?(appearanceHex: String) {
    var cleaned = appearanceHex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if cleaned.hasPrefix("#") { cleaned.removeFirst() }
    guard cleaned.count == 6 || cleaned.count == 8 else { return nil }
    var value: UInt64 = 0
    Scanner(string: cleaned).scanHexInt64(&value)
    if cleaned.count == 6 {
      self.init(
        red: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1
      )
    } else {
      self.init(
        red: CGFloat((value >> 24) & 0xFF) / 255,
        green: CGFloat((value >> 16) & 0xFF) / 255,
        blue: CGFloat((value >> 8) & 0xFF) / 255,
        alpha: CGFloat(value & 0xFF) / 255
      )
    }
  }
}

private extension Color {
  init?(hex: String) {
    guard let ui = UIColor(appearanceHex: hex) else { return nil }
    self.init(uiColor: ui)
  }
}

// MARK: - Legacy entry (kept so old call sites compile → routes to color editor)

/// Previous form-based editor. Prefer `AppearanceHubView` as the Settings entry.
struct AppearanceEditorView: View {
  @Binding var draft: ChatAppearanceDraft
  var onCancel: () -> Void
  var onSet: (ChatAppearanceDraft) -> Void
  var showsLiveChatPreview: Bool = true

  var body: some View {
    ChatAppearanceColorEditor(
      draft: $draft,
      initialTab: .background,
      onCancel: onCancel,
      onSet: onSet
    )
  }
}

// Keep name used by previous integrator preview.
struct ChatAppearanceDraftChatPreview: View {
  let draft: ChatAppearanceDraft
  var body: some View {
    ChatAppearanceLiveHost(draft: draft, mode: .compact)
  }
}
