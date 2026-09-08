import SwiftUI
import UIKit

enum AppVectorGlyph {
  case story
  case compose
}

struct AppVectorIcon: View {
  let glyph: AppVectorGlyph
  let tint: Color
  var lineWidth: CGFloat = 1.5

  var body: some View {
    GeometryReader { geometry in
      ZStack {
        switch glyph {
        case .story:
          storyPath(in: geometry.size)
            .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        case .compose:
          composePaths(in: geometry.size)
            .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
      }
    }
    .aspectRatio(1, contentMode: .fit)
  }

  private func storyPath(in size: CGSize) -> Path {
    let scale = min(size.width, size.height) / 24.0
    let rect = CGRect(
      x: (size.width - 24.0 * scale) * 0.5,
      y: (size.height - 24.0 * scale) * 0.5,
      width: 24.0 * scale,
      height: 24.0 * scale
    )

    var path = Path()
    let center = CGPoint(x: rect.midX, y: rect.midY)
    path.addArc(
      center: center,
      radius: 9.0 * scale,
      startAngle: .degrees(-39),
      endAngle: .degrees(-70),
      clockwise: false
    )
    path.move(to: CGPoint(x: rect.minX + 12.0 * scale, y: rect.minY + 8.0 * scale))
    path.addLine(to: CGPoint(x: rect.minX + 12.0 * scale, y: rect.minY + 16.0 * scale))
    path.move(to: CGPoint(x: rect.minX + 8.0 * scale, y: rect.minY + 12.0 * scale))
    path.addLine(to: CGPoint(x: rect.minX + 16.0 * scale, y: rect.minY + 12.0 * scale))
    return path
  }

  private func composePaths(in size: CGSize) -> Path {
    let scale = min(size.width, size.height) / 21.0
    let rect = CGRect(
      x: (size.width - 21.0 * scale) * 0.5,
      y: (size.height - 21.0 * scale) * 0.5,
      width: 21.0 * scale,
      height: 21.0 * scale
    )

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
    }

    var path = Path()
    path.move(to: point(14.0, 1.0))
    path.addQuadCurve(to: point(14.0, 4.0), control: point(15.25, 2.25))
    path.addLine(to: point(4.5, 13.5))
    path.addLine(to: point(1.5, 14.5))
    path.addLine(to: point(2.5, 10.6))
    path.addLine(to: point(12.0, 1.1))
    path.addQuadCurve(to: point(14.0, 1.0), control: point(13.0, 0.25))

    path.move(to: point(6.5, 14.5))
    path.addLine(to: point(14.5, 14.5))

    path.move(to: point(12.5, 3.5))
    path.addLine(to: point(13.5, 4.5))
    return path
  }
}
/// The proxy shield, traced from the shipped 24×24 artwork. Active fills the crest and
/// knocks the check out of it; off strokes the same outlines.
struct AppProxyShieldIcon: View {
  let isActive: Bool
  let tint: Color

  var body: some View {
    GeometryReader { geometry in
      let scale = min(geometry.size.width, geometry.size.height) / 24
      let origin = CGPoint(
        x: (geometry.size.width - 24 * scale) / 2,
        y: (geometry.size.height - 24 * scale) / 2
      )

      if isActive {
        ZStack {
          shieldPath(scale: scale, origin: origin).fill(tint)
          checkPath(scale: scale, origin: origin)
            .stroke(
              style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round, lineJoin: .round)
            )
            .blendMode(.destinationOut)
        }
        .compositingGroup()
      } else {
        ZStack {
          shieldPath(scale: scale, origin: origin)
            .stroke(
              tint,
              style: StrokeStyle(lineWidth: 1.6 * scale, lineCap: .round, lineJoin: .round)
            )
          checkPath(scale: scale, origin: origin)
            .stroke(
              tint,
              style: StrokeStyle(lineWidth: 1.6 * scale, lineCap: .round, lineJoin: .round)
            )
        }
      }
    }
    .aspectRatio(1, contentMode: .fit)
  }

  private func shieldPath(scale: CGFloat, origin: CGPoint) -> Path {
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
    }
    var path = Path()
    path.move(to: point(11.887, 21.98))
    path.addCurve(
      to: point(12.113, 21.98), control1: point(11.963, 22.006), control2: point(12.037, 22.007))
    path.addCurve(to: point(20, 11.253), control1: point(13.084, 21.65), control2: point(20, 19.018))
    path.addLine(to: point(20, 4.304))
    path.addCurve(
      to: point(19.697, 3.915), control1: point(20, 4.12), control2: point(19.875, 3.96))
    path.addLine(to: point(12.097, 2.012))
    path.addCurve(
      to: point(11.903, 2.012), control1: point(12.033, 1.996), control2: point(11.967, 1.996))
    path.addLine(to: point(4.303, 3.915))
    path.addCurve(to: point(4, 4.304), control1: point(4.125, 3.96), control2: point(4, 4.12))
    path.addLine(to: point(4, 11.252))
    path.addCurve(
      to: point(11.887, 21.98), control1: point(4, 18.939), control2: point(10.918, 21.639))
    path.closeSubpath()
    return path
  }

  private func checkPath(scale: CGFloat, origin: CGPoint) -> Path {
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: origin.x + x * scale, y: origin.y + y * scale)
    }
    var path = Path()
    path.move(to: point(8, 12))
    path.addLine(to: point(11, 15))
    path.addLine(to: point(16, 8))
    return path
  }
}

enum AppStoryVectorGlyph {
  case close
  case download
  case text
  case emoji
  case music
  case settings
  case edit
  case delete
  case send
  case color
  case alignLeft
  case alignCenter
  case alignRight
}

extension UIImage {
  /// Returns a code-owned vector glyph formatted as a template image.
  static func appStoryGlyph(_ glyph: AppStoryVectorGlyph, pointSize: CGFloat = 24.0) -> UIImage {
    let targetSize = CGSize(width: pointSize, height: pointSize)
    let renderer = UIGraphicsImageRenderer(size: targetSize)
    let image = renderer.image { context in
      let cgContext = context.cgContext
      cgContext.setShouldAntialias(true)
      cgContext.setAllowsAntialiasing(true)

      let scale = pointSize / 24.0
      cgContext.scaleBy(x: scale, y: scale)

      UIColor.black.setStroke()
      UIColor.black.setFill()

      switch glyph {
      case .close:
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 6.5, y: 6.5))
        path.addLine(to: CGPoint(x: 17.5, y: 17.5))
        path.move(to: CGPoint(x: 17.5, y: 6.5))
        path.addLine(to: CGPoint(x: 6.5, y: 17.5))
        path.lineWidth = 2.0
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()

      case .download:
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 12.0, y: 4.5))
        path.addLine(to: CGPoint(x: 12.0, y: 14.0))
        path.move(to: CGPoint(x: 7.5, y: 9.5))
        path.addLine(to: CGPoint(x: 12.0, y: 14.0))
        path.addLine(to: CGPoint(x: 16.5, y: 9.5))
        path.move(to: CGPoint(x: 5.0, y: 19.0))
        path.addLine(to: CGPoint(x: 19.0, y: 19.0))
        path.lineWidth = 2.0
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()

      case .text:
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 5.0, y: 6.0))
        path.addLine(to: CGPoint(x: 19.0, y: 6.0))
        path.move(to: CGPoint(x: 12.0, y: 6.0))
        path.addLine(to: CGPoint(x: 12.0, y: 18.5))
        path.move(to: CGPoint(x: 9.0, y: 18.5))
        path.addLine(to: CGPoint(x: 15.0, y: 18.5))
        path.lineWidth = 2.0
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()

      case .emoji:
        let facePath = UIBezierPath(
          arcCenter: CGPoint(x: 12.0, y: 12.0),
          radius: 8.5,
          startAngle: 0,
          endAngle: .pi * 2,
          clockwise: true
        )
        facePath.lineWidth = 1.8
        facePath.stroke()

        let leftEye = UIBezierPath(
          arcCenter: CGPoint(x: 8.5, y: 9.5),
          radius: 1.2,
          startAngle: 0,
          endAngle: .pi * 2,
          clockwise: true
        )
        leftEye.fill()

        let rightEye = UIBezierPath(
          arcCenter: CGPoint(x: 15.5, y: 9.5),
          radius: 1.2,
          startAngle: 0,
          endAngle: .pi * 2,
          clockwise: true
        )
        rightEye.fill()

        let smilePath = UIBezierPath(
          arcCenter: CGPoint(x: 12.0, y: 11.5),
          radius: 5.0,
          startAngle: .pi * 0.25,
          endAngle: .pi * 0.75,
          clockwise: true
        )
        smilePath.lineWidth = 1.8
        smilePath.lineCapStyle = .round
        smilePath.stroke()

      case .music:
        let note1 = UIBezierPath(
          arcCenter: CGPoint(x: 7.0, y: 16.5),
          radius: 2.2,
          startAngle: 0,
          endAngle: .pi * 2,
          clockwise: true
        )
        note1.fill()

        let note2 = UIBezierPath(
          arcCenter: CGPoint(x: 16.0, y: 14.5),
          radius: 2.2,
          startAngle: 0,
          endAngle: .pi * 2,
          clockwise: true
        )
        note2.fill()

        let stems = UIBezierPath()
        stems.move(to: CGPoint(x: 9.0, y: 16.5))
        stems.addLine(to: CGPoint(x: 9.0, y: 6.5))
        stems.move(to: CGPoint(x: 18.0, y: 14.5))
        stems.addLine(to: CGPoint(x: 18.0, y: 4.5))
        stems.lineWidth = 1.8
        stems.stroke()

        let beam = UIBezierPath()
        beam.move(to: CGPoint(x: 9.0, y: 6.5))
        beam.addLine(to: CGPoint(x: 18.0, y: 4.5))
        beam.lineWidth = 2.6
        beam.lineCapStyle = .round
        beam.stroke()

      case .settings:
        let centerCircle = UIBezierPath(
          arcCenter: CGPoint(x: 12.0, y: 12.0),
          radius: 3.0,
          startAngle: 0,
          endAngle: .pi * 2,
          clockwise: true
        )
        centerCircle.lineWidth = 1.8
        centerCircle.stroke()

        let gearPath = UIBezierPath()
        let teethCount = 6
        let innerR: CGFloat = 6.0
        let outerR: CGFloat = 8.5
        for i in 0..<teethCount {
          let angle1 = (CGFloat(i) * 2.0 * .pi / CGFloat(teethCount)) - 0.2
          let angle2 = (CGFloat(i) * 2.0 * .pi / CGFloat(teethCount)) + 0.2

          let p1 = CGPoint(x: 12.0 + innerR * cos(angle1), y: 12.0 + innerR * sin(angle1))
          let p2 = CGPoint(x: 12.0 + outerR * cos(angle1), y: 12.0 + outerR * sin(angle1))
          let p3 = CGPoint(x: 12.0 + outerR * cos(angle2), y: 12.0 + outerR * sin(angle2))
          let p4 = CGPoint(x: 12.0 + innerR * cos(angle2), y: 12.0 + innerR * sin(angle2))

          if i == 0 {
            gearPath.move(to: p1)
          } else {
            gearPath.addLine(to: p1)
          }
          gearPath.addLine(to: p2)
          gearPath.addLine(to: p3)
          gearPath.addLine(to: p4)
        }
        gearPath.close()
        gearPath.lineWidth = 1.8
        gearPath.lineCapStyle = .round
        gearPath.lineJoinStyle = .round
        gearPath.stroke()

      case .edit:
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 15.5, y: 4.5))
        path.addLine(to: CGPoint(x: 19.5, y: 8.5))
        path.addLine(to: CGPoint(x: 8.5, y: 19.5))
        path.addLine(to: CGPoint(x: 4.5, y: 19.5))
        path.addLine(to: CGPoint(x: 4.5, y: 15.5))
        path.close()
        path.move(to: CGPoint(x: 12.5, y: 7.5))
        path.addLine(to: CGPoint(x: 16.5, y: 11.5))
        path.lineWidth = 1.8
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()

      case .delete:
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 9.5, y: 4.5))
        path.addLine(to: CGPoint(x: 14.5, y: 4.5))
        path.move(to: CGPoint(x: 5.0, y: 7.0))
        path.addLine(to: CGPoint(x: 19.0, y: 7.0))
        path.move(to: CGPoint(x: 6.5, y: 7.0))
        path.addLine(to: CGPoint(x: 7.5, y: 19.5))
        path.addLine(to: CGPoint(x: 16.5, y: 19.5))
        path.addLine(to: CGPoint(x: 17.5, y: 7.0))
        path.move(to: CGPoint(x: 10.0, y: 10.5))
        path.addLine(to: CGPoint(x: 10.0, y: 16.0))
        path.move(to: CGPoint(x: 14.0, y: 10.5))
        path.addLine(to: CGPoint(x: 14.0, y: 16.0))
        path.lineWidth = 1.8
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()

      case .send:
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 12.0, y: 19.0))
        path.addLine(to: CGPoint(x: 12.0, y: 5.0))
        path.move(to: CGPoint(x: 6.0, y: 11.0))
        path.addLine(to: CGPoint(x: 12.0, y: 5.0))
        path.addLine(to: CGPoint(x: 18.0, y: 11.0))
        path.lineWidth = 2.2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()

      case .color:
        let palette = UIBezierPath(
          arcCenter: CGPoint(x: 12.0, y: 12.0),
          radius: 8.5,
          startAngle: 0,
          endAngle: .pi * 2,
          clockwise: true
        )
        palette.lineWidth = 1.8
        palette.stroke()

        let dot1 = UIBezierPath(arcCenter: CGPoint(x: 9.0, y: 10.0), radius: 1.3, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        dot1.fill()

        let dot2 = UIBezierPath(arcCenter: CGPoint(x: 15.0, y: 10.0), radius: 1.3, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        dot2.fill()

        let dot3 = UIBezierPath(arcCenter: CGPoint(x: 12.0, y: 15.0), radius: 1.3, startAngle: 0, endAngle: .pi * 2, clockwise: true)
        dot3.fill()

      case .alignLeft:
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 4.5, y: 6.0))
        path.addLine(to: CGPoint(x: 19.5, y: 6.0))
        path.move(to: CGPoint(x: 4.5, y: 10.0))
        path.addLine(to: CGPoint(x: 13.5, y: 10.0))
        path.move(to: CGPoint(x: 4.5, y: 14.0))
        path.addLine(to: CGPoint(x: 17.5, y: 14.0))
        path.move(to: CGPoint(x: 4.5, y: 18.0))
        path.addLine(to: CGPoint(x: 11.5, y: 18.0))
        path.lineWidth = 2.0
        path.lineCapStyle = .round
        path.stroke()

      case .alignCenter:
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 4.5, y: 6.0))
        path.addLine(to: CGPoint(x: 19.5, y: 6.0))
        path.move(to: CGPoint(x: 7.5, y: 10.0))
        path.addLine(to: CGPoint(x: 16.5, y: 10.0))
        path.move(to: CGPoint(x: 5.5, y: 14.0))
        path.addLine(to: CGPoint(x: 18.5, y: 14.0))
        path.move(to: CGPoint(x: 8.5, y: 18.0))
        path.addLine(to: CGPoint(x: 15.5, y: 18.0))
        path.lineWidth = 2.0
        path.lineCapStyle = .round
        path.stroke()

      case .alignRight:
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 4.5, y: 6.0))
        path.addLine(to: CGPoint(x: 19.5, y: 6.0))
        path.move(to: CGPoint(x: 10.5, y: 10.0))
        path.addLine(to: CGPoint(x: 19.5, y: 10.0))
        path.move(to: CGPoint(x: 6.5, y: 14.0))
        path.addLine(to: CGPoint(x: 19.5, y: 14.0))
        path.move(to: CGPoint(x: 12.5, y: 18.0))
        path.addLine(to: CGPoint(x: 19.5, y: 18.0))
        path.lineWidth = 2.0
        path.lineCapStyle = .round
        path.stroke()
      }
    }
    return image.withRenderingMode(.alwaysTemplate)
  }
}
