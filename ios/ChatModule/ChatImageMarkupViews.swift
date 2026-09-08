import PencilKit
import SwiftUI
import UIKit

// MARK: - Model

enum ChatImageMarkupMode: String, CaseIterable, Identifiable {
  case draw, sticker, text, ai
  var id: String { rawValue }

  /// The bottom row is hand-editing only. AI is not a fourth kind of pen — it
  /// acts on the whole picture — and sitting it in the tab row both crowded the
  /// row and implied it was one. It lives in the header instead.
  static var tabCases: [ChatImageMarkupMode] { [.draw, .sticker, .text] }
  var title: String {
    switch self {
    case .draw: return "Draw"
    case .sticker: return "Sticker"
    case .text: return "Text"
    case .ai: return "AI"
    }
  }
}

enum ChatImageDrawTool: String, CaseIterable, Identifiable {
  case pen, marker, highlighter, pencil, mono, eraser
  var id: String { rawValue }

  var tipColor: Color {
    switch self {
    case .pen: return Color(red: 0.2, green: 0.45, blue: 1.0)
    case .marker: return Color(red: 1.0, green: 0.55, blue: 0.12)
    case .highlighter: return Color(red: 0.98, green: 0.86, blue: 0.12)
    case .pencil: return Color(red: 0.2, green: 0.85, blue: 0.35)
    case .mono: return Color(white: 0.95)
    case .eraser: return Color(red: 1.0, green: 0.55, blue: 0.72)
    }
  }

  var inkWidth: CGFloat {
    switch self {
    case .pen: return 5
    case .marker: return 14
    case .highlighter: return 26
    case .pencil: return 3.5
    case .mono: return 4
    case .eraser: return 20
    }
  }

  var systemSymbol: String {
    switch self {
    case .pen: return "pencil.tip"
    case .marker: return "paintbrush.pointed.fill"
    case .highlighter: return "highlighter"
    case .pencil: return "pencil"
    case .mono: return "pencil.and.scribble"
    case .eraser: return "eraser.fill"
    }
  }
}

enum ChatImageShapeKind: String, CaseIterable, Identifiable {
  case rectangle, ellipse, bubble, star, arrow
  var id: String { rawValue }
  var title: String {
    switch self {
    case .rectangle: return "Rectangle"
    case .ellipse: return "Ellipse"
    case .bubble: return "Bubble"
    case .star: return "Star"
    case .arrow: return "Arrow"
    }
  }
  var systemImage: String {
    switch self {
    case .rectangle: return "rectangle"
    case .ellipse: return "circle"
    case .bubble: return "bubble.left"
    case .star: return "star"
    case .arrow: return "arrow.up.right"
    }
  }
}

@MainActor
final class ChatImageMarkupModel: ObservableObject {
  @Published var mode: ChatImageMarkupMode = .draw
  @Published var drawTool: ChatImageDrawTool = .pen
  @Published var inkColor: Color = .blue
  @Published var inkOpacity: Double = 1.0
  /// Multiplies the native width for the selected PencilKit instrument. Kept
  /// separate from the tool so the edge paddle can resize every instrument
  /// without changing what is selected.
  @Published var strokeScale: CGFloat = 1.0
  @Published var textFontSize: CGFloat = 28
  @Published var textBold = true
  @Published var textFontName: String = "San Francisco"
  @Published var isEditing = false
  @Published var showShapeMenu = false

  // AI editing. `aiHasSelection` reflects whether the user has dragged a region
  // on the image — when false the edit applies to the whole picture.
  @Published var aiPrompt: String = ""
  @Published var aiIsWorking = false
  @Published var aiHasSelection = false
  @Published var aiCanUndo = false

  var uiColor: UIColor {
    UIColor(inkColor).withAlphaComponent(inkOpacity)
  }

  func makeInk() -> PKInkingTool {
    let color = uiColor
    let width = drawTool.inkWidth * min(max(strokeScale, 0.35), 2.4)
    switch drawTool {
    case .pen, .mono:
      return PKInkingTool(.pen, color: color, width: width)
    case .marker:
      return PKInkingTool(.marker, color: color, width: width)
    case .highlighter:
      return PKInkingTool(
        .marker, color: color.withAlphaComponent(min(0.4, inkOpacity)), width: width)
    case .pencil:
      return PKInkingTool(.pencil, color: color, width: width)
    case .eraser:
      return PKInkingTool(.pen, color: .clear, width: 1)
    }
  }
}

// MARK: - Native Liquid Glass editor header

enum ChatImageEditorHeaderMode: Equatable {
  case viewer
  case markup
  case text
}

@MainActor
final class ChatImageEditorHeaderModel: ObservableObject {
  @Published var mode: ChatImageEditorHeaderMode = .viewer
  @Published var title: String
  @Published var subtitle: String
  @Published var hasMessage: Bool
  @Published var allowsActions: Bool
  @Published var canUndo = false
  @Published var canRedo = false

  init(title: String, subtitle: String, hasMessage: Bool, allowsActions: Bool = true) {
    self.title = title
    self.subtitle = subtitle
    self.hasMessage = hasMessage
    self.allowsActions = allowsActions
  }
}

/// The editor has three logical navigation states, but it is not navigating
/// between three screens. A `GlassEffectContainer` with stable IDs lets the
/// system transform each glass surface in place: most visibly the viewer's
/// ellipsis circle becoming the markup `Clear All` capsule and then `Done`.
struct ChatImageEditorHeader: View {
  @ObservedObject var model: ChatImageEditorHeaderModel
  var onClose: () -> Void
  var onUndo: () -> Void
  var onRedo: () -> Void
  var onClearAll: () -> Void
  var onAI: () -> Void
  var onCancelText: () -> Void
  var onDoneText: () -> Void
  var onShowInChat: () -> Void
  var onSave: () -> Void
  var onReply: () -> Void
  var onDelete: () -> Void

  @Namespace private var glassNamespace

  var body: some View {
    GlassEffectContainer(spacing: 12) {
      ZStack {
        switch model.mode {
        case .viewer:
          viewerHeader
        case .markup:
          markupHeader
        case .text:
          textHeader
        }
      }
      .padding(.horizontal, 14)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .animation(
      .spring(response: 0.44, dampingFraction: 0.82, blendDuration: 0.08),
      value: model.mode)
  }

  private var viewerHeader: some View {
    ZStack {
      HStack {
        glassIconButton(
          systemName: "chevron.backward",
          id: "leading-primary",
          accessibilityLabel: "Close",
          action: onClose)
        Spacer()
        if model.allowsActions {
          viewerMenu
        } else {
          Color.clear.frame(width: 44, height: 44)
        }
      }

      VStack(spacing: 0) {
        Text(model.title.isEmpty ? "Photo" : model.title)
          .font(.system(size: 15, weight: .semibold))
          .lineLimit(1)
          .truncationMode(.middle)
        if !model.subtitle.isEmpty {
          Text(model.subtitle)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .frame(minWidth: 112, maxWidth: 168, minHeight: 44)
      .glassEffect(.regular, in: .capsule)
      .glassEffectID("title", in: glassNamespace)
      // The title is intentionally not a source for Undo/Redo or AI. It simply
      // dematerializes, leaving the edge controls to birth their neighbours.
      .glassEffectTransition(.materialize)
    }
  }

  private var markupHeader: some View {
    HStack(spacing: 8) {
      glassIconButton(
        systemName: "arrow.uturn.backward",
        id: "leading-primary",
        accessibilityLabel: "Undo",
        enabled: model.canUndo,
        action: onUndo)
      glassIconButton(
        systemName: "arrow.uturn.forward",
        id: "leading-secondary",
        accessibilityLabel: "Redo",
        enabled: model.canRedo,
        action: onRedo)
      Spacer(minLength: 20)
      glassIconButton(
        systemName: "sparkles",
        id: "trailing-secondary",
        accessibilityLabel: "Edit with AI",
        action: onAI)
      glassTextButton(
        title: "Clear All",
        id: "trailing-primary",
        action: onClearAll)
    }
  }

  private var textHeader: some View {
    HStack {
      glassTextButton(
        title: "Cancel",
        id: "leading-primary",
        action: onCancelText)
      Spacer()
      glassTextButton(
        title: "Done",
        id: "trailing-primary",
        action: onDoneText)
    }
  }

  private var viewerMenu: some View {
    Menu {
      if model.hasMessage {
        Button(action: onShowInChat) {
          Label("Show in Chat", systemImage: "bubble.left.and.text.bubble.right")
        }
      }
      Button(action: onSave) {
        Label("Save Image", systemImage: "square.and.arrow.down")
      }
      if model.hasMessage {
        Button(action: onReply) {
          Label("Reply", systemImage: "arrowshape.turn.up.left")
        }
        Button(role: .destructive, action: onDelete) {
          Label("Delete", systemImage: "trash")
        }
      }
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .glassEffect(.regular.interactive(true), in: .circle)
        .glassEffectID("trailing-primary", in: glassNamespace)
        .glassEffectTransition(.matchedGeometry)
    }
    .accessibilityLabel("Photo actions")
  }

  private func glassIconButton(
    systemName: String,
    id: String,
    accessibilityLabel: String,
    enabled: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.white.opacity(enabled ? 1 : 0.36))
        .frame(width: 44, height: 44)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(!enabled)
    .glassEffect(.regular.interactive(enabled), in: .circle)
    .glassEffectID(id, in: glassNamespace)
    .glassEffectTransition(.matchedGeometry)
    .accessibilityLabel(accessibilityLabel)
  }

  private func glassTextButton(
    title: String,
    id: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 17)
        .frame(minHeight: 44)
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(true), in: .capsule)
    .glassEffectID(id, in: glassNamespace)
    .glassEffectTransition(.matchedGeometry)
  }
}

// MARK: - Markup bottom chrome (solid black, no wrapper gap — matches system Markup)

struct ChatImageMarkupToolbar: View {
  @ObservedObject var model: ChatImageMarkupModel
  var onCancel: () -> Void
  var onConfirm: () -> Void
  var onColorWheel: () -> Void
  var onAddText: () -> Void
  var onOpenStickers: () -> Void
  var onPickShape: (ChatImageShapeKind) -> Void

  private let palette: [Color] = [
    .red, .orange, .yellow, .green, .cyan, .blue, .purple, .white,
  ]

  /// One height for the close circle, the tab capsule and the confirm circle —
  /// the action row is a single row, so it gets a single measurement.
  fileprivate static let actionSide: CGFloat = 46.0

  var body: some View { editingBar }

  private var editingBar: some View {
    VStack(spacing: 0) {
      // Tool strip — solid black, no material wrapper. Mode changes use a native
      // push so the next tool set has direction instead of popping in place.
      Group {
        switch model.mode {
        case .draw: drawStrip
        case .text: textStrip
        case .sticker: stickerHintStrip
        // AI is not a markup mode any more — it is a field that rides the
        // keyboard (`ChatImageAIPromptBar`), so this bar has nothing to draw
        // for it.
        case .ai: Color.clear.frame(height: 0)
        }
      }
      .id(model.mode)
      .transition(.push(from: .trailing))
      .frame(minHeight: 72)
      .padding(.horizontal, 10)
      .padding(.top, 8)
      .padding(.bottom, 6)
      .animation(.easeInOut(duration: 0.2), value: model.mode)

      // X · Draw/Sticker/Text · ✓ — one row, all three on the same height.
      // The tab capsule used to be a couple of points shorter than the circles
      // beside it, which is the sort of thing you only notice as the row not
      // sitting straight.
      HStack(spacing: 12) {
        Button(action: onCancel) {
          Image(systemName: "xmark")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: Self.actionSide, height: Self.actionSide)
            .glassEffect(.regular.interactive(true), in: .circle)
        }
        .buttonStyle(.plain)

        HStack(spacing: 0) {
          ForEach(ChatImageMarkupMode.tabCases) { mode in
            Button {
              withAnimation(.easeInOut(duration: 0.15)) { model.mode = mode }
              if mode == .sticker { onOpenStickers() }
              // Text is a typing mode; selecting it and getting no keyboard left
              // the tab looking inert until you also knew to tap the picture.
              if mode == .text { onAddText() }
            } label: {
              Text(mode.title)
                .font(.system(size: 15, weight: model.mode == mode ? .semibold : .medium))
                .foregroundStyle(model.mode == mode ? Color.white : Color.white.opacity(0.55))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                  if model.mode == mode {
                    Capsule().fill(Color.white.opacity(0.18))
                  }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        .padding(3)
        .frame(height: Self.actionSide)
        .glassEffect(.regular.interactive(true), in: .capsule)

        Button(action: onConfirm) {
          Image(systemName: "checkmark")
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: Self.actionSide, height: Self.actionSide)
            .glassEffect(.regular.interactive(true), in: .circle)
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 14)
      .padding(.bottom, 10)
    }
    // Clear: the bar floats on the photo like the viewer's does. The solid black
    // plate was the reason the editing surface read as a different app.
    .background(.clear)
    .confirmationDialog("Shapes", isPresented: $model.showShapeMenu, titleVisibility: .hidden) {
      ForEach(ChatImageShapeKind.allCases) { kind in
        Button {
          onPickShape(kind)
        } label: {
          Label(kind.title, systemImage: kind.systemImage)
        }
      }
      Button("Cancel", role: .cancel) {}
    }
  }

  // MARK: Draw strip — pens + colour row, directly above the action row
  //
  // Deliberately part of this bar rather than `PKToolPicker`. The system picker
  // docks to the bottom of the screen with no way to place it, so it always
  // landed *under* the actions and pushed them up when drawing turned on. Pens,
  // colours and actions belong to one block, with the actions on the floor.

  private var drawStrip: some View {
    VStack(spacing: 10) {
      // No tray, no glass, no plate. The pens are the control; a material behind
      // them made the row read as a panel dropped onto the photo, and it also
      // squeezed the pens into the middle instead of letting them use the width.
      HStack(alignment: .bottom, spacing: 0) {
        colorWheelButton
          .frame(maxWidth: .infinity)
        ForEach(ChatImageDrawTool.allCases) { tool in
          Button {
            model.drawTool = tool
          } label: {
            MarkupMarkerView(tool: tool, selected: model.drawTool == tool)
              .frame(width: 42, height: 74)
          }
          .buttonStyle(.plain)
          .frame(maxWidth: .infinity)
        }
        Button {
          model.showShapeMenu = true
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Color.white.opacity(0.16), in: Circle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
      }
      .padding(.horizontal, 8)
      .frame(height: 76, alignment: .bottom)

      // Same treatment for the swatches: evenly spread across the full width, so
      // the two rows share one rhythm instead of the colours bunching left.
      HStack(spacing: 0) {
        ForEach(Array(palette.enumerated()), id: \.offset) { _, c in
          Button {
            model.inkColor = c
            model.inkOpacity = 1
          } label: {
            Circle()
              .fill(c)
              .frame(width: 24, height: 24)
              .overlay(
                Circle().strokeBorder(
                  Color.white.opacity(colorEq(model.inkColor, c) ? 1 : 0.2),
                  lineWidth: colorEq(model.inkColor, c) ? 2.4 : 0.6
                )
              )
              .frame(maxWidth: .infinity)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 14)
    }
  }

  // MARK: Text strip

  private var textStrip: some View {
    VStack(spacing: 8) {
      HStack(spacing: 10) {
        colorWheelButton
        toolChip(system: "textformat", selected: model.textBold) {
          model.textBold.toggle()
        }
        toolChip(system: "text.aligncenter", selected: false) {}
        Menu {
          ForEach(
            ["San Francisco", "Helvetica Neue", "Georgia", "Courier New", "Avenir Next"],
            id: \.self
          ) { name in
            Button(name) { model.textFontName = name }
          }
        } label: {
          HStack(spacing: 4) {
            Text(model.textFontName)
              .font(.system(size: 13, weight: .semibold))
              .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
              .font(.system(size: 9, weight: .semibold))
          }
          .foregroundStyle(.white)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .background(Color.white.opacity(0.12), in: Capsule())
        }
        Spacer(minLength: 0)
        Button(action: onAddText) {
          Image(systemName: "plus")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 34, height: 34)
            .background(Color.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
      }

      HStack(spacing: 9) {
        ForEach(Array(palette.enumerated()), id: \.offset) { _, c in
          Button {
            model.inkColor = c
            model.inkOpacity = 1
          } label: {
            Circle()
              .fill(c)
              .frame(width: 20, height: 20)
              .overlay(
                Circle().strokeBorder(
                  Color.white.opacity(colorEq(model.inkColor, c) ? 1 : 0.2),
                  lineWidth: colorEq(model.inkColor, c) ? 2.2 : 0.6
                )
              )
          }
          .buttonStyle(.plain)
        }
        Spacer(minLength: 0)
      }
    }
  }

  private var stickerHintStrip: some View {
    HStack {
      Text("Pick a sticker or GIF")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(.white.opacity(0.55))
      Spacer()
      Button("Open library", action: onOpenStickers)
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(Color.accentColor)
    }
    .frame(maxWidth: .infinity, minHeight: 56)
  }

  private var colorWheelButton: some View {
    Button(action: onColorWheel) {
      ZStack {
        Circle()
          .fill(
            AngularGradient(
              colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
              center: .center)
          )
          .frame(width: 26, height: 26)
        Circle()
          .strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
          .frame(width: 26, height: 26)
      }
      .frame(width: 36, height: 74, alignment: .bottom)
    }
    .buttonStyle(.plain)
  }

  private func toolChip(system: String, selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: system)
        .font(.system(size: 15, weight: .semibold))
        // Formatting state is neutral, like Markup/Telegram. Blue here looked
        // like a chosen text colour rather than a bold toggle.
        .foregroundStyle(selected ? Color.black : Color.white)
        .frame(width: 34, height: 34)
        .background(
          selected ? Color.white : Color.white.opacity(0.12),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
  }

  private func colorEq(_ a: Color, _ b: Color) -> Bool {
    let ua = UIColor(a)
    let ub = UIColor(b)
    var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
    var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
    ua.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
    ub.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
    return abs(ar - br) < 0.05 && abs(ag - bg) < 0.05 && abs(ab - bb) < 0.05
  }
}

// MARK: - Drawing instruments

struct MarkupMarkerView: View {
  let tool: ChatImageDrawTool
  let selected: Bool

  var body: some View {
    Canvas { context, size in
      let centerX = size.width * 0.5
      let lift: CGFloat = selected ? -5 : 0
      let bottom = size.height - 3 + lift

      let baseRect = CGRect(x: centerX - 13, y: size.height - 27, width: 26, height: 26)
      context.fill(
        Path(ellipseIn: baseRect),
        with: .color(selected ? Color.blue.opacity(0.22) : Color.black.opacity(0.48)))
      context.stroke(
        Path(ellipseIn: baseRect),
        with: .color(
          selected ? Color(red: 0.02, green: 0.55, blue: 1) : Color.white.opacity(0.08)),
        lineWidth: selected ? 3 : 1)

      func fillBarrel(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        let rect = CGRect(x: x, y: y, width: width, height: height)
        let path = Path(roundedRect: rect, cornerRadius: min(3, width * 0.22))
        context.fill(
          path,
          with: .linearGradient(
            Gradient(colors: [Color(white: 0.28), Color(white: 0.055), Color(white: 0.18)]),
            startPoint: CGPoint(x: rect.minX, y: rect.midY),
            endPoint: CGPoint(x: rect.maxX, y: rect.midY)))
        context.stroke(path, with: .color(.white.opacity(0.1)), lineWidth: 0.7)
      }

      func fillBand(_ color: Color, y: CGFloat, width: CGFloat) {
        context.fill(
          Path(CGRect(x: centerX - width * 0.5, y: y, width: width, height: 4)),
          with: .color(color))
      }

      switch tool {
      case .pen:
        let barrelY = 18 + lift
        fillBarrel(x: centerX - 6, y: barrelY, width: 12, height: bottom - barrelY)
        var nib = Path()
        nib.move(to: CGPoint(x: centerX, y: 3 + lift))
        nib.addLine(to: CGPoint(x: centerX + 5, y: barrelY + 1))
        nib.addLine(to: CGPoint(x: centerX - 5, y: barrelY + 1))
        nib.closeSubpath()
        context.fill(
          nib,
          with: .linearGradient(
            Gradient(colors: [tool.tipColor, tool.tipColor.opacity(0.52)]),
            startPoint: CGPoint(x: centerX, y: 3 + lift),
            endPoint: CGPoint(x: centerX, y: barrelY)))
        fillBand(tool.tipColor, y: bottom - 12, width: 12)

      case .marker:
        let barrelY = 21 + lift
        fillBarrel(x: centerX - 7, y: barrelY, width: 14, height: bottom - barrelY)
        var arrow = Path()
        arrow.move(to: CGPoint(x: centerX, y: 1 + lift))
        arrow.addLine(to: CGPoint(x: centerX + 10, y: 11 + lift))
        arrow.addLine(to: CGPoint(x: centerX + 4, y: 11 + lift))
        arrow.addLine(to: CGPoint(x: centerX + 4, y: barrelY + 2))
        arrow.addLine(to: CGPoint(x: centerX - 4, y: barrelY + 2))
        arrow.addLine(to: CGPoint(x: centerX - 4, y: 11 + lift))
        arrow.addLine(to: CGPoint(x: centerX - 10, y: 11 + lift))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(tool.tipColor))
        fillBand(tool.tipColor, y: barrelY + 20, width: 14)

      case .highlighter:
        let barrelY = 15 + lift
        fillBarrel(x: centerX - 8, y: barrelY, width: 16, height: bottom - barrelY)
        var chisel = Path()
        chisel.move(to: CGPoint(x: centerX - 7, y: 5 + lift))
        chisel.addLine(to: CGPoint(x: centerX + 8, y: 1 + lift))
        chisel.addLine(to: CGPoint(x: centerX + 8, y: barrelY + 1))
        chisel.addLine(to: CGPoint(x: centerX - 7, y: barrelY + 1))
        chisel.closeSubpath()
        context.fill(chisel, with: .color(tool.tipColor))
        fillBand(tool.tipColor, y: bottom - 13, width: 16)

      case .pencil:
        let barrelY = 15 + lift
        fillBarrel(x: centerX - 7, y: barrelY, width: 14, height: bottom - barrelY)
        let cap = Path(
          roundedRect: CGRect(x: centerX - 6, y: 2 + lift, width: 12, height: 18),
          cornerRadius: 6)
        context.fill(
          cap,
          with: .linearGradient(
            Gradient(colors: [tool.tipColor.opacity(0.7), tool.tipColor]),
            startPoint: CGPoint(x: centerX - 6, y: 10),
            endPoint: CGPoint(x: centerX + 6, y: 10)))
        fillBand(tool.tipColor, y: barrelY + 24, width: 14)

      case .mono:
        let barrelY = 18 + lift
        fillBarrel(x: centerX - 7, y: barrelY, width: 14, height: bottom - barrelY)
        for diameter in stride(from: CGFloat(26), through: 14, by: -4) {
          let glow = CGRect(
            x: centerX - diameter * 0.5,
            y: 5 + lift - diameter * 0.5 + 7,
            width: diameter,
            height: diameter)
          context.fill(
            Path(ellipseIn: glow),
            with: .color(.white.opacity(diameter == 14 ? 1 : 0.055)))
        }
        fillBand(.white.opacity(0.72), y: barrelY + 7, width: 14)

      case .eraser:
        let barrelY = 23 + lift
        fillBarrel(x: centerX - 8, y: barrelY, width: 16, height: bottom - barrelY)
        let capRect = CGRect(x: centerX - 8.5, y: 1 + lift, width: 17, height: 26)
        let cap = Path(roundedRect: capRect, cornerRadius: 6)
        context.fill(
          cap,
          with: .linearGradient(
            Gradient(colors: [Color(red: 1, green: 0.72, blue: 0.77), tool.tipColor.opacity(0.7)]),
            startPoint: CGPoint(x: capRect.minX, y: capRect.midY),
            endPoint: CGPoint(x: capRect.maxX, y: capRect.midY)))
        fillBand(.white.opacity(0.25), y: barrelY + 5, width: 16)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .animation(.snappy(duration: 0.2), value: selected)
  }
}

// MARK: - View-mode bottom actions (share / markup / delete) — glass SwiftUI

struct ChatImageViewerBottomBar: View {
  var onShare: () -> Void
  var onMarkup: () -> Void
  var onAI: () -> Void
  var onDelete: () -> Void

  /// 44pt is the app's header control size (`ChatMainView` call/history/new-chat
  /// circles), so the viewer's bar sits on the same grid as every other bar in
  /// the app rather than inventing its own.
  static let controlSide: CGFloat = 44.0
  static let glyphSize: CGFloat = 19.0
  static let verticalPadding: CGFloat = 12.0
  static let barHeight: CGFloat = controlSide + verticalPadding * 2.0

  var body: some View {
    HStack(spacing: 0) {
      // Forward arrow, outline weight — the bar is stroke-only throughout, and a
      // filled glyph here was the one solid shape in the row.
      circleButton(system: "arrowshape.turn.up.right", action: onShare)

      Spacer(minLength: 12)

      HStack(spacing: 0) {
        capsuleButton(system: "pencil.tip.crop.circle", action: onMarkup)
        aiWordmarkButton(action: onAI)
      }
      .frame(height: Self.controlSide)
      .padding(.horizontal, 6)
      // Real glass, no material fill: `.ultraThinMaterial` over a dark photo
      // reads as grey, which is exactly what the header pills had.
      .glassEffect(.regular.interactive(true), in: .capsule)

      Spacer(minLength: 12)

      circleButton(system: "trash", action: onDelete)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, Self.verticalPadding)
    .frame(maxWidth: .infinity)
  }

  private func circleButton(system: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: system)
        .font(.system(size: Self.glyphSize, weight: .medium))
        .foregroundStyle(.white)
        .frame(width: Self.controlSide, height: Self.controlSide)
        .glassEffect(.regular.interactive(true), in: .circle)
    }
    .buttonStyle(.plain)
  }

  /// "AI" with sparkles alive around it. A bare `sparkles` glyph is what every
  /// editor uses for filters, so it never said which of the two this was — and a
  /// motionless one said nothing about the thing behind the button being a model
  /// rather than a filter.
  private func aiWordmarkButton(action: @escaping () -> Void) -> some View {
    Button(action: action) {
      ChatImageAISparkleMark()
        .frame(width: Self.controlSide, height: Self.controlSide)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func capsuleButton(system: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: system)
        .font(.system(size: Self.glyphSize, weight: .medium))
        .foregroundStyle(.white)
        .frame(width: Self.controlSide, height: Self.controlSide)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Animated AI wordmark

/// The "AI" mark used in the viewer's bar: the letters carry a colour that
/// travels through them, and three sparkles orbit close in.
///
/// Deliberately tight to the glyphs — a sparkle parked out at the corner of a
/// 44pt button reads as a second, separate icon rather than as the mark being
/// alive. They sit on the letters' own shoulders instead.
struct ChatImageAISparkleMark: View {
  /// One clock for everything, so the sparkles and the colour never drift apart.
  @State private var phase: Double = 0

  private static let sparkles: [(offset: CGSize, size: CGFloat, delay: Double)] = [
    (CGSize(width: -9, height: -8), 8.0, 0.0),
    (CGSize(width: 9.5, height: -6), 6.0, 0.45),
    (CGSize(width: 7, height: 8.5), 5.0, 0.85),
  ]

  var body: some View {
    ZStack {
      Text("AI")
        .font(.system(size: 15, weight: .bold))
        .foregroundStyle(
          LinearGradient(
            colors: [.white, Color(red: 0.72, green: 0.86, blue: 1.0), .white],
            startPoint: .leading, endPoint: .trailing)
        )

      ForEach(Array(Self.sparkles.enumerated()), id: \.offset) { index, sparkle in
        Image(systemName: "sparkle")
          .font(.system(size: sparkle.size, weight: .semibold))
          .foregroundStyle(.white)
          .offset(sparkle.offset)
          .rotationEffect(.degrees(phase * 360 + Double(index) * 40))
          .scaleEffect(0.7 + 0.3 * pulse(delay: sparkle.delay))
          .opacity(0.35 + 0.65 * pulse(delay: sparkle.delay))
      }
    }
    .onAppear {
      // One slow linear cycle drives rotation directly and the twinkles through
      // `pulse`, so nothing needs a second animation of its own.
      withAnimation(.linear(duration: 4.2).repeatForever(autoreverses: false)) {
        phase = 1
      }
    }
  }

  /// A 0…1 triangle wave offset per sparkle, so the three read as a shimmer
  /// rather than one light blinking three times.
  private func pulse(delay: Double) -> Double {
    let t = (phase * 3.0 + delay).truncatingRemainder(dividingBy: 1.0)
    return t < 0.5 ? t * 2 : (1 - t) * 2
  }
}

// MARK: - Text keyboard accessory (ref: color · A · align · emoji · San Francisco)

struct ChatImageTextKeyboardBar: View {
  @ObservedObject var model: ChatImageMarkupModel
  var onColor: () -> Void
  var onEmoji: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Button(action: onColor) {
        ZStack {
          Circle()
            .fill(
              AngularGradient(
                colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center)
            )
            .frame(width: 24, height: 24)
          Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.2).frame(width: 24, height: 24)
        }
      }
      .buttonStyle(.plain)

      Button {
        model.textBold.toggle()
      } label: {
        Image(systemName: "textformat")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(model.textBold ? Color.black : Color.primary)
          .frame(width: 34, height: 34)
          .background(
            model.textBold ? Color.white : Color.white.opacity(0.12),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      .buttonStyle(.plain)

      Image(systemName: "text.aligncenter")
        .font(.system(size: 15, weight: .semibold))
        .frame(width: 34, height: 34)

      Button(action: onEmoji) {
        Image(systemName: "face.smiling")
          .font(.system(size: 15, weight: .semibold))
          .frame(width: 34, height: 34)
      }
      .buttonStyle(.plain)

      Spacer(minLength: 4)

      Menu {
        ForEach(
          ["San Francisco", "Helvetica Neue", "Georgia", "Courier New", "Avenir Next"],
          id: \.self
        ) { name in
          Button(name) { model.textFontName = name }
        }
      } label: {
        HStack(spacing: 4) {
          Text(model.textFontName)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
          Image(systemName: "chevron.up.chevron.down")
            .font(.system(size: 9, weight: .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.clear, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.72), lineWidth: 1))
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity)
    .foregroundStyle(.white)
    .tint(.white)
    .background(.clear)
  }
}

// MARK: - Hosts

@MainActor
final class ChatImageEditorHeaderHost: UIView {
  let model: ChatImageEditorHeaderModel
  private var hosting: UIHostingController<ChatImageEditorHeader>?

  var onClose: (() -> Void)?
  var onUndo: (() -> Void)?
  var onRedo: (() -> Void)?
  var onClearAll: (() -> Void)?
  var onAI: (() -> Void)?
  var onCancelText: (() -> Void)?
  var onDoneText: (() -> Void)?
  var onShowInChat: (() -> Void)?
  var onSave: (() -> Void)?
  var onReply: (() -> Void)?
  var onDelete: (() -> Void)?

  init(title: String, subtitle: String, hasMessage: Bool, allowsActions: Bool = true) {
    model = ChatImageEditorHeaderModel(
      title: title,
      subtitle: subtitle,
      hasMessage: hasMessage,
      allowsActions: allowsActions)
    super.init(frame: .zero)
    backgroundColor = .clear
    isOpaque = false

    let root = ChatImageEditorHeader(
      model: model,
      onClose: { [weak self] in self?.onClose?() },
      onUndo: { [weak self] in self?.onUndo?() },
      onRedo: { [weak self] in self?.onRedo?() },
      onClearAll: { [weak self] in self?.onClearAll?() },
      onAI: { [weak self] in self?.onAI?() },
      onCancelText: { [weak self] in self?.onCancelText?() },
      onDoneText: { [weak self] in self?.onDoneText?() },
      onShowInChat: { [weak self] in self?.onShowInChat?() },
      onSave: { [weak self] in self?.onSave?() },
      onReply: { [weak self] in self?.onReply?() },
      onDelete: { [weak self] in self?.onDelete?() })
    let host = UIHostingController(rootView: root)
    host.view.backgroundColor = .clear
    host.view.isOpaque = false
    addSubview(host.view)
    hosting = host
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    hosting?.view.frame = bounds
  }

  func setMode(_ mode: ChatImageEditorHeaderMode, animated: Bool) {
    guard model.mode != mode else { return }
    if animated {
      withAnimation(.spring(response: 0.44, dampingFraction: 0.82, blendDuration: 0.08)) {
        model.mode = mode
      }
    } else {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { model.mode = mode }
    }
  }

  func updatePage(title: String, subtitle: String, hasMessage: Bool) {
    model.title = title
    model.subtitle = subtitle
    model.hasMessage = hasMessage
  }

  func updateUndo(canUndo: Bool, canRedo: Bool) {
    model.canUndo = canUndo
    model.canRedo = canRedo
  }
}

final class ChatImageMarkupToolbarHost: UIView {
  private let model: ChatImageMarkupModel
  private var hosting: UIHostingController<ChatImageMarkupToolbar>?

  var onCancel: (() -> Void)?
  var onConfirm: (() -> Void)?
  var onColorWheel: (() -> Void)?
  var onAddText: (() -> Void)?
  var onOpenStickers: (() -> Void)?
  var onPickShape: ((ChatImageShapeKind) -> Void)?

  init(model: ChatImageMarkupModel) {
    self.model = model
    super.init(frame: .zero)
    // Transparent, like the viewer's bar: the controls carry their own glass, so
    // a plate behind them would be the one solid rectangle on a floating surface.
    backgroundColor = .clear
    isOpaque = false
    installRoot()
  }

  required init?(coder: NSCoder) { nil }

  private func installRoot() {
    hosting?.view.removeFromSuperview()
    let root = makeRoot()
    let host = UIHostingController(rootView: root)
    host.view.backgroundColor = .clear
    host.view.isOpaque = false
    addSubview(host.view)
    hosting = host
  }

  private func makeRoot() -> ChatImageMarkupToolbar {
    ChatImageMarkupToolbar(
      model: model,
      onCancel: { [weak self] in self?.onCancel?() },
      onConfirm: { [weak self] in self?.onConfirm?() },
      onColorWheel: { [weak self] in self?.onColorWheel?() },
      onAddText: { [weak self] in self?.onAddText?() },
      onOpenStickers: { [weak self] in self?.onOpenStickers?() },
      onPickShape: { [weak self] k in self?.onPickShape?(k) }
    )
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    hosting?.view.frame = bounds
  }

  func preferredHeight(for width: CGFloat) -> CGFloat {
    // A floor rather than a fixed height: the strips differ (draw has two rows,
    // sticker has one), and letting the bar shrink below this makes the action
    // row jump the moment a tab changes.
    let floor: CGFloat = 150
    return max(floor, hosting?.sizeThatFits(in: CGSize(width: width, height: 280)).height ?? 158)
  }

  func refresh() {
    hosting?.rootView = makeRoot()
  }
}

final class ChatImageViewerBottomBarHost: UIView {
  private var hosting: UIHostingController<ChatImageViewerBottomBar>?
  var onShare: (() -> Void)?
  var onMarkup: (() -> Void)?
  var onAI: (() -> Void)?
  var onDelete: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    // Transparent: the bar floats over a full-bleed photo now, so an opaque
    // black plate here would crop the picture it sits on.
    backgroundColor = .clear
    isOpaque = false
    let root = ChatImageViewerBottomBar(
      onShare: { [weak self] in self?.onShare?() },
      onMarkup: { [weak self] in self?.onMarkup?() },
      onAI: { [weak self] in self?.onAI?() },
      onDelete: { [weak self] in self?.onDelete?() }
    )
    let host = UIHostingController(rootView: root)
    host.view.backgroundColor = .clear
    host.view.isOpaque = false
    addSubview(host.view)
    hosting = host
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    hosting?.view.frame = bounds
  }

  var preferredHeight: CGFloat { ChatImageViewerBottomBar.barHeight }
}

// MARK: - AI entry point

/// The AI affordance: the letters "AI" with sparkles orbiting them, not a bare
/// `sparkles` glyph. A sparkle alone says "effects" — every editor uses it for
/// filters — where the wordmark says which of the two things this button is.
final class ChatImageAIGlyphButton: UIControl {
  private let glass = UIVisualEffectView(effect: nil)
  private let titleLabel = UILabel()
  private var sparkles: [UIImageView] = []

  /// Small enough to read as decoration on the word rather than as three more
  /// buttons sitting next to it.
  private static let sparkleSides: [CGFloat] = [9, 6.5, 5]

  override init(frame: CGRect) {
    super.init(frame: frame)

    glass.isUserInteractionEnabled = false
    if #available(iOS 26.0, *) {
      glass.cornerConfiguration = .capsule()
    } else {
      glass.clipsToBounds = true
      glass.layer.cornerCurve = .continuous
    }
    glass.effect = nil
    addSubview(glass)

    titleLabel.text = "AI"
    titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
    titleLabel.textColor = .white
    titleLabel.textAlignment = .center
    titleLabel.isUserInteractionEnabled = false
    addSubview(titleLabel)

    for side in Self.sparkleSides {
      let view = UIImageView(
        image: UIImage(systemName: "sparkle")?.withRenderingMode(.alwaysTemplate))
      view.tintColor = .white
      view.contentMode = .scaleAspectFit
      view.isUserInteractionEnabled = false
      view.bounds = CGRect(x: 0, y: 0, width: side, height: side)
      addSubview(view)
      sparkles.append(view)
    }
  }

  required init?(coder: NSCoder) { nil }

  /// Materialize/dematerialize, so this button joins and leaves the header the
  /// same way every glass pill beside it does rather than fading on its own.
  func setGlassVisible(_ visible: Bool) {
    isUserInteractionEnabled = visible
    titleLabel.alpha = visible ? 1 : 0
    sparkles.forEach { $0.alpha = visible ? $0.alpha : 0 }
    if visible {
      if glass.effect == nil {
        if #available(iOS 26.0, *) {
          let effect = UIGlassEffect()
          effect.isInteractive = true
          glass.effect = effect
        } else {
          glass.effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        }
        startTwinkling()
      }
    } else if glass.effect != nil {
      glass.effect = nil
      stopTwinkling()
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    glass.frame = bounds
    if #unavailable(iOS 26.0) {
      glass.layer.cornerRadius = bounds.height * 0.5
    }
    titleLabel.frame = bounds

    // Around the word, not on it: one above-left, one above-right, one below-right.
    let positions: [CGPoint] = [
      CGPoint(x: bounds.width * 0.20, y: bounds.height * 0.24),
      CGPoint(x: bounds.width * 0.82, y: bounds.height * 0.28),
      CGPoint(x: bounds.width * 0.74, y: bounds.height * 0.78),
    ]
    for (index, view) in sparkles.enumerated() where index < positions.count {
      view.center = positions[index]
    }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    // Animations do not survive leaving the window, so they are (re)started here
    // rather than once at init — but only while the button is actually present,
    // since a dematerialized one has nothing to twinkle.
    if window == nil || glass.effect == nil { stopTwinkling() } else { startTwinkling() }
  }

  private func startTwinkling() {
    for (index, view) in sparkles.enumerated() {
      view.layer.removeAllAnimations()
      view.alpha = 0.35
      view.transform = CGAffineTransform(scaleX: 0.7, y: 0.7)
      // Staggered, so the three read as a shimmer rather than one blinking light.
      UIView.animate(
        withDuration: 1.1,
        delay: Double(index) * 0.36,
        options: [.repeat, .autoreverse, .curveEaseInOut, .allowUserInteraction],
        animations: {
          view.alpha = 1
          view.transform = .identity
        })
    }
  }

  private func stopTwinkling() {
    sparkles.forEach { $0.layer.removeAllAnimations() }
  }

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: 0.12) {
        self.transform =
          self.isHighlighted ? CGAffineTransform(scaleX: 0.94, y: 0.94) : .identity
      }
    }
  }
}

// MARK: - AI prompt bar

/// The AI prompt is a field, not an editing mode.
///
/// It rides the keyboard and nothing else on screen moves for it: no bar swaps
/// itself out, no tool tabs appear, and above all the picture keeps the size it
/// already had. Routing AI through the markup toolbar meant asking for a prompt
/// lit up the whole editor and shrank the photo to make room for tools the
/// prompt has no use for.
final class ChatImageAIPromptBar: UIView, UITextFieldDelegate {
  var onSubmit: ((String) -> Void)?
  var onUndo: (() -> Void)?
  /// Fires when the field hands the keyboard back, so the owner can put the bar
  /// away — except when the owner took the keyboard itself to run an edit.
  var onEndEditing: (() -> Void)?

  static let barHeight: CGFloat = 52.0
  private static let sidePadding: CGFloat = 16.0
  private static let controlSide: CGFloat = 34.0
  private static let capsuleHeight: CGFloat = 46.0

  /// Neutral native blur. A hard-coded blue fill made the prompt read as a
  /// selected control and disconnected it from the translucent keyboard below.
  private let capsule = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
  private let field = UITextField()
  private let sendButton = UIButton(type: .system)
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let undoButton = UIButton(type: .system)

  var text: String {
    get { field.text ?? "" }
    set {
      field.text = newValue
      syncSendEnabled()
    }
  }

  var isWorking = false {
    didSet {
      guard isWorking != oldValue else { return }
      field.isEnabled = !isWorking
      sendButton.isHidden = isWorking
      if isWorking { spinner.startAnimating() } else { spinner.stopAnimating() }
      setNeedsLayout()
    }
  }

  var canUndo = false {
    didSet {
      guard canUndo != oldValue else { return }
      undoButton.isHidden = !canUndo
      setNeedsLayout()
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear

    capsule.contentView.backgroundColor = UIColor.black.withAlphaComponent(0.16)
    capsule.clipsToBounds = true
    capsule.layer.cornerCurve = .continuous
    capsule.layer.borderWidth = 0.5
    capsule.layer.borderColor = UIColor.white.withAlphaComponent(0.16).cgColor
    addSubview(capsule)

    field.borderStyle = .none
    field.font = .systemFont(ofSize: 15)
    field.textColor = .white
    field.tintColor = .white
    field.keyboardAppearance = .dark
    field.returnKeyType = .go
    field.enablesReturnKeyAutomatically = true
    field.autocorrectionType = .no
    field.delegate = self
    field.attributedPlaceholder = NSAttributedString(
      string: "Describe the edit…",
      attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.7)])
    field.addTarget(self, action: #selector(handleTextChanged), for: .editingChanged)
    capsule.contentView.addSubview(field)

    sendButton.setImage(
      UIImage(
        systemName: "arrow.up",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold)),
      for: .normal)
    sendButton.addTarget(self, action: #selector(handleSend), for: .touchUpInside)
    sendButton.layer.cornerRadius = Self.controlSide * 0.5
    sendButton.clipsToBounds = true
    capsule.contentView.addSubview(sendButton)

    spinner.color = .white
    spinner.hidesWhenStopped = true
    capsule.contentView.addSubview(spinner)

    undoButton.setImage(
      UIImage(
        systemName: "arrow.uturn.backward",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)),
      for: .normal)
    undoButton.tintColor = .white
    undoButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
    undoButton.layer.cornerRadius = Self.capsuleHeight * 0.5
    undoButton.clipsToBounds = true
    undoButton.isHidden = true
    undoButton.addTarget(self, action: #selector(handleUndo), for: .touchUpInside)
    addSubview(undoButton)

    syncSendEnabled()
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    let inset = Self.sidePadding
    let capsuleH = Self.capsuleHeight
    let y = (bounds.height - capsuleH) * 0.5

    var capsuleWidth = bounds.width - inset * 2
    if canUndo {
      let side = capsuleH
      undoButton.frame = CGRect(x: bounds.width - inset - side, y: y, width: side, height: side)
      capsuleWidth -= side + 8
    }

    capsule.frame = CGRect(x: inset, y: y, width: max(0, capsuleWidth), height: capsuleH)
    capsule.layer.cornerRadius = capsuleH * 0.5

    let inner = capsule.bounds
    let control = Self.controlSide
    let controlX = inner.maxX - 6 - control
    sendButton.frame = CGRect(
      x: controlX, y: (inner.height - control) * 0.5, width: control, height: control)
    spinner.center = CGPoint(x: controlX + control * 0.5, y: inner.midY)
    field.frame = CGRect(x: 16, y: 0, width: max(0, controlX - 16 - 8), height: inner.height)
  }

  @discardableResult
  override func becomeFirstResponder() -> Bool { field.becomeFirstResponder() }

  @discardableResult
  override func resignFirstResponder() -> Bool { field.resignFirstResponder() }

  override var isFirstResponder: Bool { field.isFirstResponder }

  private var canSend: Bool {
    !isWorking && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func syncSendEnabled() {
    let enabled = canSend
    sendButton.isEnabled = enabled
    sendButton.tintColor = enabled ? .black : UIColor.white.withAlphaComponent(0.45)
    sendButton.backgroundColor =
      enabled ? UIColor.white.withAlphaComponent(0.92) : UIColor.white.withAlphaComponent(0.12)
  }

  @objc private func handleTextChanged() { syncSendEnabled() }

  @objc private func handleSend() {
    guard canSend else { return }
    onSubmit?(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  @objc private func handleUndo() { onUndo?() }

  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    handleSend()
    return false
  }

  func textFieldDidEndEditing(_ textField: UITextField) {
    onEndEditing?()
  }
}
