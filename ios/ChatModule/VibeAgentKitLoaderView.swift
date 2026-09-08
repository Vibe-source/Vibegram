import MetalKit
import UIKit

private extension Array {
  subscript(safe index: Int) -> Element? {
    guard indices.contains(index) else {
      return nil
    }
    return self[index]
  }
}

private extension UIColor {
  var simd4: SIMD4<Float> {
    var red: CGFloat = 0.0
    var green: CGFloat = 0.0
    var blue: CGFloat = 0.0
    var alpha: CGFloat = 0.0
    if getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
      return SIMD4<Float>(Float(red), Float(green), Float(blue), Float(alpha))
    }

    var white: CGFloat = 0.0
    if getWhite(&white, alpha: &alpha) {
      return SIMD4<Float>(Float(white), Float(white), Float(white), Float(alpha))
    }

    return SIMD4<Float>(1.0, 1.0, 1.0, 1.0)
  }
}

private let resoloAgentLoaderMetalSource = """
#include <metal_stdlib>
using namespace metal;

struct LoaderVertexOut {
  float4 position [[position]];
  float2 uv;
};

struct LoaderUniforms {
  float2 resolution;
  float time;
  float padding;
  float4 colorA;
  float4 colorB;
  float4 colorC;
  float4 colorD;
};

vertex LoaderVertexOut loaderVertex(uint vertexID [[vertex_id]]) {
  float2 positions[6] = {
    float2(-1.0, -1.0),
    float2(1.0, -1.0),
    float2(-1.0, 1.0),
    float2(-1.0, 1.0),
    float2(1.0, -1.0),
    float2(1.0, 1.0)
  };

  LoaderVertexOut out;
  out.position = float4(positions[vertexID], 0.0, 1.0);
  out.uv = positions[vertexID] * 0.5 + 0.5;
  return out;
}

float2 loaderHash2(float2 p) {
  p = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
  return -1.0 + 2.0 * fract(sin(p) * 43758.5453123);
}

float loaderNoise(float2 p) {
  float2 i = floor(p);
  float2 f = fract(p);
  float2 u = f * f * (3.0 - 2.0 * f);
  return mix(
    mix(dot(loaderHash2(i + float2(0.0, 0.0)), f - float2(0.0, 0.0)),
        dot(loaderHash2(i + float2(1.0, 0.0)), f - float2(1.0, 0.0)), u.x),
    mix(dot(loaderHash2(i + float2(0.0, 1.0)), f - float2(0.0, 1.0)),
        dot(loaderHash2(i + float2(1.0, 1.0)), f - float2(1.0, 1.0)), u.x),
    u.y);
}

float loaderBlob(float2 uv, float2 center, float radius) {
  return smoothstep(radius, radius * 0.1, distance(uv, center));
}

fragment float4 loaderFragment(
  LoaderVertexOut in [[stage_in]],
  constant LoaderUniforms &uniforms [[buffer(0)]]
) {
  float2 uv = in.uv;
  float t = uniforms.time * 0.15;

  float2 turbUV = uv * 2.4;
  float nx = loaderNoise(turbUV + float2(t * 0.6, t * 0.4));
  float ny = loaderNoise(turbUV + float2(t * 0.3, t * 0.7) + 5.2);
  float2 uvWarped = uv + float2(nx, ny) * 0.026;

  float2 c1 = float2(0.38 + 0.13 * sin(t * 0.80), 0.34 + 0.12 * cos(t * 0.64));
  float2 c2 = float2(0.66 + 0.12 * cos(t * 0.72), 0.66 + 0.10 * sin(t * 0.78));
  float2 c3 = float2(0.60 + 0.10 * sin(t * 0.94 + 1.2), 0.30 + 0.13 * cos(t * 0.82 + 0.4));
  float2 c4 = float2(0.30 + 0.11 * cos(t * 0.88 + 1.9), 0.60 + 0.10 * sin(t * 0.90 + 0.6));

  float b1 = loaderBlob(uvWarped, c1, 0.54);
  float b2 = loaderBlob(uvWarped, c2, 0.51);
  float b3 = loaderBlob(uvWarped, c3, 0.45);
  float b4 = loaderBlob(uvWarped, c4, 0.42);

  float3 color = mix(uniforms.colorD.rgb, uniforms.colorA.rgb, clamp(uv.y * 0.74 + 0.18, 0.0, 1.0));
  color = mix(color, uniforms.colorB.rgb, b1 * 0.68);
  color = mix(color, uniforms.colorC.rgb, b2 * 0.72);
  color = mix(color, uniforms.colorA.rgb, b3 * 0.40);
  color = mix(color, uniforms.colorB.rgb, b4 * 0.28);

  float swirl = 0.5 + 0.5 * sin((uvWarped.x * 2.3 + uvWarped.y * 2.0) * 1.1 + t * 0.8);
  color = mix(color, uniforms.colorC.rgb, swirl * 0.045);

  float highlight = smoothstep(0.55, 0.0, distance(uv, float2(0.28, 0.22)));
  color += float3(1.0) * highlight * 0.08;

  float vignette = smoothstep(0.90, 0.20, distance(uv, float2(0.5, 0.5)));
  color *= 0.90 + vignette * 0.16;

  return float4(clamp(color, 0.0, 1.0), 1.0);
}
"""

private struct VibeAgentKitAgentLoaderMetalUniforms {
  var resolution: SIMD2<Float>
  var time: Float
  var padding: Float
  var colorA: SIMD4<Float>
  var colorB: SIMD4<Float>
  var colorC: SIMD4<Float>
  var colorD: SIMD4<Float>
}

private final class VibeAgentKitAgentOrbRenderer: NSObject, MTKViewDelegate {
  var palette: [SIMD4<Float>] = [
    SIMD4<Float>(1, 1, 1, 1),
    SIMD4<Float>(1, 1, 1, 1),
    SIMD4<Float>(1, 1, 1, 1),
    SIMD4<Float>(1, 1, 1, 1),
  ]

  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let pipelineState: MTLRenderPipelineState
  private let startTime = CACurrentMediaTime()

  init?(device: MTLDevice) {
    guard
      let commandQueue = device.makeCommandQueue(),
      let library = try? device.makeLibrary(source: resoloAgentLoaderMetalSource, options: nil),
      let vertexFunction = library.makeFunction(name: "loaderVertex"),
      let fragmentFunction = library.makeFunction(name: "loaderFragment")
    else {
      return nil
    }

    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = vertexFunction
    descriptor.fragmentFunction = fragmentFunction
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

    guard let pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor) else {
      return nil
    }

    self.device = device
    self.commandQueue = commandQueue
    self.pipelineState = pipelineState
    super.init()
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func draw(in view: MTKView) {
    guard
      let descriptor = view.currentRenderPassDescriptor,
      let drawable = view.currentDrawable,
      let commandBuffer = commandQueue.makeCommandBuffer(),
      let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
    else {
      return
    }

    let elapsed = Float(CACurrentMediaTime() - startTime)
    var uniforms = VibeAgentKitAgentLoaderMetalUniforms(
      resolution: SIMD2<Float>(
        Float(max(view.drawableSize.width, 1.0)),
        Float(max(view.drawableSize.height, 1.0))
      ),
      time: elapsed,
      padding: 0.0,
      colorA: palette[safe: 0] ?? SIMD4<Float>(1, 1, 1, 1),
      colorB: palette[safe: 1] ?? SIMD4<Float>(1, 1, 1, 1),
      colorC: palette[safe: 2] ?? SIMD4<Float>(1, 1, 1, 1),
      colorD: palette[safe: 3] ?? SIMD4<Float>(1, 1, 1, 1)
    )

    encoder.setRenderPipelineState(pipelineState)
    encoder.setFragmentBytes(
      &uniforms,
      length: MemoryLayout<VibeAgentKitAgentLoaderMetalUniforms>.stride,
      index: 0
    )
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    encoder.endEncoding()

    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}

private final class VibeAgentKitAgentOrbView: UIView {
  // Chat can create and discard loader views rapidly while SwiftUI reconciles
  // the first streaming row. Use the gradient layer here; tiny MTKViews were
  // exhausting CAMetalLayer drawables on-device during long first-response waits.
  private static let usesMetalRendering = false

  private let metalView: MTKView?
  private let renderer: VibeAgentKitAgentOrbRenderer?
  private let fallbackGradientLayer = CAGradientLayer()
  private var isMetalActive = false

  override init(frame: CGRect) {
    let device = Self.usesMetalRendering ? MTLCreateSystemDefaultDevice() : nil
    if let device, let renderer = VibeAgentKitAgentOrbRenderer(device: device) {
      let metalView = MTKView(frame: .zero, device: device)
      metalView.translatesAutoresizingMaskIntoConstraints = false
      metalView.isOpaque = false
      metalView.enableSetNeedsDisplay = false
      metalView.isPaused = true
      metalView.preferredFramesPerSecond = 30
      metalView.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0)
      metalView.backgroundColor = .clear
      metalView.delegate = renderer
      self.metalView = metalView
      self.renderer = renderer
    } else {
      self.metalView = nil
      self.renderer = nil
    }
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    layer.cornerRadius = bounds.width * 0.5
    metalView?.frame = bounds
    fallbackGradientLayer.frame = bounds
  }

  func setMetalActive(_ active: Bool) {
    guard let metalView else { return }
    guard isMetalActive != active else { return }
    isMetalActive = active
    metalView.isPaused = !active
    if active {
      metalView.setNeedsDisplay()
    }
  }

  func applyAppearance(_ appearance: VibeAgentKitChatAppearance) {
    let palette = appearance.isDark
      ? [
        UIColor(red: 0.9040, green: 0.6920, blue: 0.8040, alpha: 1.0),
        UIColor(red: 1.0000, green: 0.6120, blue: 0.3840, alpha: 1.0),
        UIColor(red: 0.6900, green: 0.7560, blue: 0.9800, alpha: 1.0),
        UIColor(red: 0.9500, green: 0.8780, blue: 0.8280, alpha: 1.0),
      ]
      : [
        UIColor(red: 0.9500, green: 0.7820, blue: 0.8560, alpha: 1.0),
        UIColor(red: 1.0000, green: 0.6760, blue: 0.4700, alpha: 1.0),
        UIColor(red: 0.7740, green: 0.8120, blue: 0.9880, alpha: 1.0),
        UIColor(red: 0.9600, green: 0.8960, blue: 0.8500, alpha: 1.0),
      ]

    renderer?.palette = palette.map(\.simd4)
    fallbackGradientLayer.colors = palette.map(\.cgColor)
    fallbackGradientLayer.startPoint = CGPoint(x: 0.18, y: 0.12)
    fallbackGradientLayer.endPoint = CGPoint(x: 0.88, y: 0.88)
  }

  private func setup() {
    clipsToBounds = true
    layer.cornerCurve = .continuous
    layer.addSublayer(fallbackGradientLayer)

    if let metalView {
      addSubview(metalView)
    }
  }
}

private final class VibeAgentKitShimmerLabelView: UIView {
  private let baseLabel = UILabel()
  private let shimmerLabel = UILabel()
  private let shimmerFont = UIFont.systemFont(ofSize: 14.5, weight: .medium)
  private let shimmerBandWidth: CGFloat = 190.0
  private let shimmerTravelPadding: CGFloat = 180.0
  private var isAnimating = false
  private var gradientMask: CAGradientLayer?
  private var animatedWidth: CGFloat = 0.0

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    baseLabel.frame = bounds
    shimmerLabel.frame = bounds
    updateGradientMaskFrame()
    if isAnimating, abs(animatedWidth - bounds.width) > 1.0 {
      restartShimmerAnimation()
    }
  }

  func applyAppearance(_ appearance: VibeAgentKitChatAppearance) {
    let baseColor = appearance.isDark
      ? vibeAgentKitColorWithAlpha(appearance.text, 0.26)
      : vibeAgentKitColorWithAlpha(appearance.text, 0.24)
    let shimmerColor = appearance.isDark
      ? UIColor(white: 1.0, alpha: 0.68)
      : vibeAgentKitColorWithAlpha(appearance.text, 0.58)
    baseLabel.textColor = baseColor
    shimmerLabel.textColor = shimmerColor
  }

  func setText(_ text: String, animated: Bool = true) {
    guard baseLabel.text != text else { return }

    let applyText = {
      self.baseLabel.text = text
      self.shimmerLabel.text = text
      self.invalidateIntrinsicContentSize()
      self.setNeedsLayout()
    }

    guard window != nil, baseLabel.text != nil else {
      applyText()
      return
    }

    guard animated else {
      applyText()
      return
    }

    UIView.transition(
      with: self,
      duration: 0.18,
      options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction]
    ) {
      applyText()
    }
  }

  func startAnimating() {
    guard !isAnimating else { return }
    isAnimating = true
    layoutIfNeeded()

    gradientMask?.removeAnimation(forKey: "resolo.shimmer.translate")
    shimmerLabel.alpha = 0.0

    let gradient = CAGradientLayer()
    gradient.startPoint = CGPoint(x: 0.0, y: 0.5)
    gradient.endPoint = CGPoint(x: 1.0, y: 0.5)
    gradient.colors = [
      UIColor.clear.cgColor,
      UIColor.black.withAlphaComponent(0.10).cgColor,
      UIColor.black.withAlphaComponent(0.54).cgColor,
      UIColor.black.cgColor,
      UIColor.black.withAlphaComponent(0.54).cgColor,
      UIColor.black.withAlphaComponent(0.10).cgColor,
      UIColor.clear.cgColor,
    ]
    gradient.locations = [0.0, 0.18, 0.38, 0.50, 0.62, 0.82, 1.0]
    shimmerLabel.layer.mask = gradient
    gradientMask = gradient
    updateGradientMaskFrame()
    shimmerLabel.alpha = 1.0
    restartShimmerAnimation()
  }

  func stopAnimating() {
    isAnimating = false
    gradientMask?.removeAnimation(forKey: "resolo.shimmer.translate")
    gradientMask?.transform = CATransform3DIdentity
    gradientMask = nil
    shimmerLabel.alpha = 0.0
    shimmerLabel.layer.mask = nil
    animatedWidth = 0.0
  }

  override var intrinsicContentSize: CGSize {
    let base = sizeThatFits(
      CGSize(
        width: bounds.width > 0.0 ? bounds.width : CGFloat.greatestFiniteMagnitude,
        height: CGFloat.greatestFiniteMagnitude
      )
    )
    return CGSize(width: base.width, height: max(18.0, base.height))
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    let availableWidth: CGFloat = size.width.isFinite && size.width > 0.0
      ? size.width
      : CGFloat.greatestFiniteMagnitude
    let labelSize = baseLabel.sizeThatFits(
      CGSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude)
    )
    return CGSize(width: min(labelSize.width, availableWidth), height: max(18.0, labelSize.height))
  }

  private func setup() {
    backgroundColor = .clear
    clipsToBounds = true
    shimmerLabel.alpha = 0.0

    for label in [baseLabel, shimmerLabel] {
      label.font = shimmerFont
      label.textAlignment = .left
      label.numberOfLines = 3
      label.lineBreakMode = .byWordWrapping
      label.clipsToBounds = true
      addSubview(label)
    }
  }

  private func updateGradientMaskFrame() {
    guard let gradientMask else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    gradientMask.frame = CGRect(
      x: -(shimmerBandWidth + shimmerTravelPadding),
      y: 0.0,
      width: shimmerBandWidth,
      height: max(bounds.height, 18.0)
    )
    CATransaction.commit()
  }

  private func restartShimmerAnimation() {
    guard let gradientMask else { return }
    gradientMask.removeAnimation(forKey: "resolo.shimmer.translate")
    gradientMask.transform = CATransform3DIdentity

    let contentWidth = max(bounds.width, 1.0)
    animatedWidth = contentWidth

    let sweep = CABasicAnimation(keyPath: "transform.translation.x")
    sweep.fromValue = 0.0
    sweep.toValue = contentWidth + shimmerBandWidth + shimmerTravelPadding * 2.0
    sweep.duration = 2.45
    sweep.repeatCount = .infinity
    sweep.timingFunction = CAMediaTimingFunction(name: .linear)
    gradientMask.add(sweep, forKey: "resolo.shimmer.translate")
  }
}

final class VibeAgentKitAgentLoaderView: UIControl {
  private let contentStack = UIStackView()
  private let activityIconView = UIImageView()
  private let shimmerLabel = VibeAgentKitShimmerLabelView()
  // Trailing disclosure shown on a completed turn so "Worked · N steps" reads as a
  // tappable toggle (expands the tool sheet); hidden while a turn is in flight.
  private let disclosureIconView = UIImageView()

  private var appearance = VibeAgentKitChatAppearance.fallback
  private var currentText: String = ""
  private var currentActivityIconKind: VibeAgentKitChatVectorIcon.Kind?
  private var isStreamingActive = false

  // Live "Working · M:SS" elapsed clock. The start instant is owned by the host
  // (keyed by message id) and passed in on every reconfigure, so the clock counts
  // up continuously and NEVER restarts as new chunks stream in. The 1s ticker is
  // internal so the time advances even between host reconfigures.
  private var elapsedStartDate: Date?
  private var elapsedTimer: Timer?
  private var isExpandedState = false

  var progressItems: [VibeAgentKitProgressItem] = []
  var onTap: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(
        withDuration: 0.14,
        delay: 0.0,
        options: [.beginFromCurrentState, .allowUserInteraction]
      ) {
        self.alpha = self.isHighlighted ? 0.92 : 1.0
        self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.985, y: 0.985) : .identity
      }
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    contentStack.frame = bounds
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil {
      stopAnimating()
      stopElapsedTimer()
    }
  }

  override var intrinsicContentSize: CGSize {
    sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    let iconWidth: CGFloat = activityIconView.isHidden ? 0.0 : 15.0
    let spacing: CGFloat = activityIconView.isHidden ? 0.0 : contentStack.spacing
    let availableWidth: CGFloat
    if size.width.isFinite && size.width > 0.0 {
      availableWidth = max(0.0, size.width - iconWidth - spacing)
    } else {
      availableWidth = CGFloat.greatestFiniteMagnitude
    }
    let labelSize = shimmerLabel.sizeThatFits(
      CGSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude)
    )
    let width = iconWidth + spacing + labelSize.width
    let height = max(20.0, max(labelSize.height, 12.0))
    return CGSize(width: width, height: height)
  }

  func applyAppearance(_ appearance: VibeAgentKitChatAppearance) {
    self.appearance = appearance
    shimmerLabel.applyAppearance(appearance)
    updateActivityIcon(for: progressItems.last)
  }

  func configure(
    text: String,
    isStreaming: Bool,
    progressItems: [VibeAgentKitProgressItem],
    isExpanded: Bool = false,
    streamingStartDate: Date? = nil
  ) {
    self.progressItems = progressItems
    updateActivityIcon(for: progressItems.last)

    // Live turn: the header is a steady "Working · M:SS" clock that ticks up from
    // the turn's start and never resets (the model just does its job underneath).
    // Finished turn: the passed "Worked for X · N steps" summary.
    if isStreaming, let start = streamingStartDate {
      elapsedStartDate = start
      startElapsedTimer()
      setDisplayedText(workingClockText(), animated: false, updatesLayout: false)
    } else {
      stopElapsedTimer()
      setDisplayedText(resolvedLoaderText(text))
    }

    isUserInteractionEnabled = onTap != nil
    accessibilityTraits = onTap == nil ? [] : [.button]

    // Disclosure only on a finished, tappable summary ("Worked · N steps"); never
    // while the live shimmer is running. A single down chevron rotates from
    // sideways-collapsed to down-open so the toggle does not visually swap symbols.
    disclosureIconView.isHidden = isStreaming || onTap == nil || progressItems.isEmpty
    disclosureIconView.image = UIImage(systemName: "chevron.down")?
      .withRenderingMode(.alwaysTemplate)
    disclosureIconView.tintColor = appearance.isDark
      ? UIColor(white: 1.0, alpha: 0.5)
      : vibeAgentKitColorWithAlpha(appearance.text, 0.42)
    applyDisclosureRotation(expanded: isExpanded, animated: isExpanded != isExpandedState)
    isExpandedState = isExpanded

    if isStreaming && !isStreamingActive {
      isStreamingActive = true
      startAnimating()
    } else if !isStreaming && isStreamingActive {
      isStreamingActive = false
      stopAnimating()
    }
  }

  private func setDisplayedText(
    _ resolved: String,
    animated: Bool = true,
    updatesLayout: Bool = true
  ) {
    guard resolved != currentText else { return }
    let needsInitialLayout = currentText.isEmpty
    currentText = resolved
    shimmerLabel.setText(resolved, animated: animated)
    if updatesLayout || needsInitialLayout {
      invalidateIntrinsicContentSize()
      setNeedsLayout()
    }
  }

  private func applyDisclosureRotation(expanded: Bool, animated: Bool) {
    let target = expanded ? CGAffineTransform.identity : CGAffineTransform(rotationAngle: -CGFloat.pi / 2.0)
    guard animated else { disclosureIconView.transform = target; return }
    UIView.animate(withDuration: 0.22, delay: 0.0, options: [.beginFromCurrentState]) {
      self.disclosureIconView.transform = target
    }
  }

  private func workingClockText() -> String {
    guard let start = elapsedStartDate else { return "Working" }
    let secs = max(0, Int(Date().timeIntervalSince(start)))
    return "Working · \(secs / 60):" + String(format: "%02d", secs % 60)
  }

  private func startElapsedTimer() {
    guard elapsedTimer == nil else { return }
    let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
      guard let self, self.isStreamingActive || self.elapsedStartDate != nil else { return }
      self.setDisplayedText(self.workingClockText(), animated: false, updatesLayout: false)
    }
    RunLoop.main.add(timer, forMode: .common)
    elapsedTimer = timer
  }

  private func stopElapsedTimer() {
    elapsedTimer?.invalidate()
    elapsedTimer = nil
  }

  private func resolvedLoaderText(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "Thinking..." {
      return "Thinking"
    }

    return trimmed
  }

  private func updateActivityIcon(for item: VibeAgentKitProgressItem?) {
    currentActivityIconKind = nil
    let kind = item?.tool ?? item?.itemType
    guard let kind, !kind.isEmpty else {
      activityIconView.image = nil
      activityIconView.alpha = 0.0
      activityIconView.isHidden = true
      return
    }
    // Native SF Symbol for the in-flight / latest tool (terminal, pencil, …) —
    // tinted to match the shimmer text, no emoji.
    activityIconView.image = UIImage(systemName: vibeAgentKitToolSymbol(forKind: kind))
    activityIconView.tintColor = appearance.isDark
      ? UIColor(white: 1.0, alpha: 0.66)
      : vibeAgentKitColorWithAlpha(appearance.text, 0.56)
    activityIconView.alpha = 1.0
    activityIconView.isHidden = false
  }


  private func startAnimating() {
    stopAnimating()
    isStreamingActive = true
    shimmerLabel.startAnimating()
  }

  private func stopAnimating() {
    shimmerLabel.stopAnimating()
    isStreamingActive = false
  }

  private func setup() {
    backgroundColor = .clear

    contentStack.translatesAutoresizingMaskIntoConstraints = false
    contentStack.axis = .horizontal
    contentStack.alignment = .center
    contentStack.spacing = 6.0
    contentStack.distribution = .fill
    // The stack and its labels/icons are display-only. Leaving them interactive
    // makes them the hit-test target, so taps land on the shimmer label instead
    // of this UIControl and `touchUpInside` never fires (the chevron renders but
    // the tap "does nothing"). Disabling interaction on the content subtree lets
    // the control itself receive the touch and drive `onTap`.
    contentStack.isUserInteractionEnabled = false
    addSubview(contentStack)

    contentStack.addArrangedSubview(activityIconView)
    contentStack.addArrangedSubview(shimmerLabel)
    contentStack.addArrangedSubview(disclosureIconView)

    disclosureIconView.translatesAutoresizingMaskIntoConstraints = false
    disclosureIconView.contentMode = .scaleAspectFit
    disclosureIconView.image = UIImage(systemName: "chevron.down")
    disclosureIconView.transform = CGAffineTransform(rotationAngle: -CGFloat.pi / 2.0)
    disclosureIconView.isHidden = true
    disclosureIconView.setContentHuggingPriority(.required, for: .horizontal)
    disclosureIconView.setContentCompressionResistancePriority(.required, for: .horizontal)
    NSLayoutConstraint.activate([
      disclosureIconView.widthAnchor.constraint(equalToConstant: 11.0),
      disclosureIconView.heightAnchor.constraint(equalToConstant: 11.0),
    ])

    activityIconView.translatesAutoresizingMaskIntoConstraints = false
    activityIconView.contentMode = .scaleAspectFit
    activityIconView.alpha = 0.0
    activityIconView.isHidden = true
    activityIconView.setContentHuggingPriority(.required, for: .horizontal)
    activityIconView.setContentCompressionResistancePriority(.required, for: .horizontal)
    NSLayoutConstraint.activate([
      activityIconView.widthAnchor.constraint(equalToConstant: 15.0),
      activityIconView.heightAnchor.constraint(equalToConstant: 15.0),
    ])

    NSLayoutConstraint.activate([
      contentStack.topAnchor.constraint(equalTo: topAnchor),
      contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
      contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
      contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    addTarget(self, action: #selector(handlePressed), for: .touchUpInside)
  }

  @objc private func handlePressed() {
    onTap?()
  }
}

private final class VibeAgentKitAgentProgressRowView: UIView {
  private let railView = UIView()
  private let iconView = UIImageView()
  private let connectorView = UIView()
  private let titleLabel = UILabel()
  private let detailContainer = UIView()
  private let detailLabel = UILabel()
  private let badgesWrapView = UIView()

  private let contentX: CGFloat = 30.0
  private let detailHPad: CGFloat = 10.0
  private let detailVPad: CGFloat = 8.0

  private var badgeViews: [UILabel] = []
  private var showsConnector = false
  private var appearance = VibeAgentKitChatAppearance.fallback

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    railView.frame = CGRect(x: 0.0, y: 0.0, width: 22.0, height: bounds.height)
    iconView.frame = CGRect(x: 2.0, y: 1.0, width: 16.0, height: 16.0)
    connectorView.frame = CGRect(x: 9.5, y: 22.0, width: 1.0, height: max(0.0, bounds.height - 22.0))

    let contentWidth = max(0.0, bounds.width - contentX)
    let titleSize = titleLabel.sizeThatFits(CGSize(width: contentWidth, height: 60.0))
    titleLabel.frame = CGRect(x: contentX, y: 0.0, width: contentWidth, height: titleSize.height)

    var currentY = titleLabel.frame.maxY + 4.0

    if detailContainer.isHidden {
      detailContainer.frame = .zero
      detailLabel.frame = .zero
    } else {
      let textWidth = max(0.0, contentWidth - detailHPad * 2.0)
      let detailSize = detailLabel.sizeThatFits(CGSize(width: textWidth, height: 600.0))
      let boxHeight = detailSize.height + detailVPad * 2.0
      detailContainer.frame = CGRect(x: contentX, y: currentY, width: contentWidth, height: boxHeight)
      detailLabel.frame = CGRect(x: detailHPad, y: detailVPad, width: textWidth, height: detailSize.height)
      currentY = detailContainer.frame.maxY + 8.0
    }

    badgesWrapView.frame = CGRect(
      x: contentX,
      y: currentY,
      width: contentWidth,
      height: max(0.0, bounds.height - currentY)
    )

    layoutBadges(in: badgesWrapView.bounds.width)
  }

  func configure(
    item: VibeAgentKitProgressItem,
    appearance: VibeAgentKitChatAppearance,
    showsConnector: Bool
  ) {
    self.appearance = appearance
    self.showsConnector = showsConnector

    let kind = (item.tool ?? item.itemType ?? "").lowercased()
    let isError = (item.status ?? "").lowercased() == "error" || (item.status ?? "").lowercased() == "failed"
    let iconTint: UIColor = isError
      ? UIColor.systemRed
      : (kind == "thinking"
        ? vibeAgentKitColorWithAlpha(appearance.primary, 0.95)
        : vibeAgentKitColorWithAlpha(appearance.textSecondary, appearance.isDark ? 0.92 : 0.74))
    iconView.image = UIImage(systemName: vibeAgentKitToolSymbol(forKind: kind))
    iconView.tintColor = iconTint
    connectorView.backgroundColor = vibeAgentKitColorWithAlpha(appearance.border, appearance.isDark ? 0.54 : 0.68)
    connectorView.isHidden = !showsConnector

    titleLabel.text = item.label
    titleLabel.textColor = appearance.text

    // Command OUTPUT / todo checklist / reasoning lives in `messageContent`; show
    // it in a rounded, (monospaced for command output) container. Edits/reads have
    // no body → the container hides.
    let detailText = (item.messageContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let isCode = ["bash", "search", "web", "task", "tool"].contains(kind)
    detailLabel.text = detailText
    detailContainer.isHidden = detailText.isEmpty
    detailLabel.font = isCode
      ? UIFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
      : UIFont.systemFont(ofSize: 12.5, weight: .regular)
    detailLabel.textColor = vibeAgentKitColorWithAlpha(appearance.text, appearance.isDark ? 0.86 : 0.86)
    detailContainer.backgroundColor = vibeAgentKitColorWithAlpha(
      appearance.surfaceElevated, appearance.isDark ? 0.60 : 0.78)

    badgeViews.forEach { $0.removeFromSuperview() }
    badgeViews.removeAll()

    for badge in item.badges.prefix(6) {
      let label = UILabel()
      label.font = UIFont.systemFont(ofSize: 11.0, weight: .medium)
      label.textColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, appearance.isDark ? 0.90 : 0.82)
      label.backgroundColor = vibeAgentKitColorWithAlpha(appearance.surfaceElevated, appearance.isDark ? 0.74 : 0.78)
      label.layer.cornerRadius = 10.0
      label.layer.cornerCurve = .continuous
      label.clipsToBounds = true
      label.textAlignment = .center
      label.text = "  \(badge.displayText)  "
      badgesWrapView.addSubview(label)
      badgeViews.append(label)
    }

    setNeedsLayout()
  }

  func preferredHeight(for width: CGFloat) -> CGFloat {
    let contentWidth = max(0.0, width - contentX)
    let titleHeight = titleLabel.sizeThatFits(CGSize(width: contentWidth, height: 60.0)).height
    var height = max(20.0, titleHeight)

    if !detailContainer.isHidden {
      let textWidth = max(0.0, contentWidth - detailHPad * 2.0)
      let detailHeight = detailLabel.sizeThatFits(CGSize(width: textWidth, height: 600.0)).height
      height += 4.0 + detailHeight + detailVPad * 2.0
    }

    if !badgeViews.isEmpty {
      height += 8.0 + measuredBadgesHeight(for: contentWidth)
    }

    return height + 16.0
  }

  private func measuredBadgesHeight(for width: CGFloat) -> CGFloat {
    var cursorX: CGFloat = 0.0
    var cursorY: CGFloat = 0.0
    let spacing: CGFloat = 6.0
    let rowHeight: CGFloat = 22.0

    for badge in badgeViews {
      let badgeWidth = min(width, badge.sizeThatFits(CGSize(width: width, height: rowHeight)).width + 12.0)
      if cursorX > 0.0 && cursorX + badgeWidth > width {
        cursorX = 0.0
        cursorY += rowHeight + spacing
      }
      cursorX += badgeWidth + spacing
    }

    return badgeViews.isEmpty ? 0.0 : cursorY + rowHeight
  }

  private func layoutBadges(in width: CGFloat) {
    var cursorX: CGFloat = 0.0
    var cursorY: CGFloat = 0.0
    let spacing: CGFloat = 6.0
    let rowHeight: CGFloat = 22.0

    for badge in badgeViews {
      let badgeWidth = min(width, badge.sizeThatFits(CGSize(width: width, height: rowHeight)).width + 12.0)
      if cursorX > 0.0 && cursorX + badgeWidth > width {
        cursorX = 0.0
        cursorY += rowHeight + spacing
      }
      badge.frame = CGRect(x: cursorX, y: cursorY, width: badgeWidth, height: rowHeight)
      cursorX += badgeWidth + spacing
    }
  }

  private func setup() {
    backgroundColor = .clear

    addSubview(railView)
    railView.addSubview(iconView)
    railView.addSubview(connectorView)

    iconView.contentMode = .scaleAspectFit
    iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13.0, weight: .medium)
    connectorView.isHidden = true

    titleLabel.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
    titleLabel.numberOfLines = 0
    addSubview(titleLabel)

    detailContainer.layer.cornerRadius = 9.0
    detailContainer.layer.cornerCurve = .continuous
    detailContainer.clipsToBounds = true
    addSubview(detailContainer)

    detailLabel.numberOfLines = 0
    detailLabel.lineBreakMode = .byCharWrapping
    detailContainer.addSubview(detailLabel)

    addSubview(badgesWrapView)
  }
}

final class VibeAgentKitAgentProgressSheetView: UIView, UIGestureRecognizerDelegate {
  private let backdropView = UIControl()
  private let sheetView = UIVisualEffectView(effect: nil)
  private let handleView = UIView()
  private let titleLabel = UILabel()
  private let scrollView = UIScrollView()
  private let contentView = UIView()
  private lazy var panGestureRecognizer = UIPanGestureRecognizer(
    target: self,
    action: #selector(handleSheetPan(_:))
  )

  private var appearance = VibeAgentKitChatAppearance.fallback
  private var items: [VibeAgentKitProgressItem] = []
  private var rowViews: [VibeAgentKitAgentProgressRowView] = []
  private(set) var isPresented = false
  var onDismiss: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setup()
  }

  required init?(coder: NSCoder) {
    return nil
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    backdropView.frame = bounds

    let safeBottom = safeAreaInsets.bottom
    let horizontalInset: CGFloat = 12.0
    let sheetWidth = max(0.0, bounds.width - (horizontalInset * 2.0))
    let rowSpacing: CGFloat = 8.0
    let contentWidth = max(1.0, sheetWidth - 40.0)

    var contentHeight: CGFloat = 0.0
    for (index, rowView) in rowViews.enumerated() {
      let rowHeight = rowView.preferredHeight(for: contentWidth)
      rowView.frame = CGRect(x: 0.0, y: contentHeight, width: contentWidth, height: rowHeight)
      contentHeight += rowHeight
      if index < rowViews.count - 1 {
        contentHeight += rowSpacing
      }
    }

    let topInset: CGFloat = 76.0
    let bottomInset: CGFloat = 18.0 + safeBottom
    let maxSheetHeight = max(280.0, bounds.height * 0.72)
    let sheetHeight = min(maxSheetHeight, topInset + contentHeight + bottomInset)

    sheetView.frame = CGRect(
      x: horizontalInset,
      y: bounds.height - safeBottom - sheetHeight,
      width: sheetWidth,
      height: sheetHeight
    )

    handleView.frame = CGRect(x: (sheetWidth - 36.0) * 0.5, y: 12.0, width: 36.0, height: 4.0)
    titleLabel.frame = CGRect(x: 20.0, y: 28.0, width: sheetWidth - 40.0, height: 22.0)

    let scrollTop = titleLabel.frame.maxY + 14.0
    let scrollHeight = max(0.0, sheetHeight - scrollTop - bottomInset)
    scrollView.frame = CGRect(x: 20.0, y: scrollTop, width: contentWidth, height: scrollHeight)
    contentView.frame = CGRect(x: 0.0, y: 0.0, width: contentWidth, height: contentHeight)
    scrollView.contentSize = contentView.bounds.size
  }

  func applyAppearance(_ appearance: VibeAgentKitChatAppearance) {
    self.appearance = appearance

    backdropView.backgroundColor = UIColor.black.withAlphaComponent(appearance.isDark ? 0.14 : 0.08)

    if #available(iOS 26.0, *) {
      let effect = UIGlassEffect()
      effect.isInteractive = false
      sheetView.effect = effect
    } else {
      let style: UIBlurEffect.Style = appearance.isDark
        ? .systemUltraThinMaterialDark
        : .systemUltraThinMaterialLight
      sheetView.effect = UIBlurEffect(style: style)
    }

    sheetView.layer.cornerRadius = 30.0
    sheetView.layer.cornerCurve = .continuous
    sheetView.clipsToBounds = true
    sheetView.contentView.backgroundColor = .clear

    handleView.backgroundColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, appearance.isDark ? 0.28 : 0.22)
    titleLabel.textColor = vibeAgentKitColorWithAlpha(appearance.text, appearance.isDark ? 0.88 : 0.82)
    rowViews.enumerated().forEach { index, rowView in
      rowView.configure(item: items[index], appearance: appearance, showsConnector: index < items.count - 1)
    }
  }

  func present(items: [VibeAgentKitProgressItem], animated: Bool) {
    guard !items.isEmpty else { return }
    update(items: items)
    isHidden = false
    alpha = 1.0
    isPresented = true
    setNeedsLayout()
    layoutIfNeeded()

    sheetView.transform = CGAffineTransform(translationX: 0.0, y: 26.0)
    backdropView.alpha = 0.0

    let animations = {
      self.sheetView.transform = .identity
      self.backdropView.alpha = 1.0
    }

    guard animated else {
      animations()
      return
    }

    UIView.animate(
      withDuration: 0.24,
      delay: 0.0,
      usingSpringWithDamping: 0.92,
      initialSpringVelocity: 0.0,
      options: [.curveEaseOut, .allowUserInteraction]
    ) {
      animations()
    }
  }

  func dismiss(animated: Bool) {
    guard isPresented || !isHidden else { return }
    isPresented = false

    let completion: (Bool) -> Void = { _ in
      self.isHidden = true
      self.alpha = 0.0
      self.sheetView.transform = .identity
      self.backdropView.alpha = 0.0
      self.onDismiss?()
    }

    guard animated else {
      completion(true)
      return
    }

    UIView.animate(
      withDuration: 0.20,
      delay: 0.0,
      options: [.curveEaseInOut, .allowUserInteraction]
    ) {
      self.sheetView.transform = CGAffineTransform(translationX: 0.0, y: 32.0)
      self.backdropView.alpha = 0.0
    } completion: { finished in
      completion(finished)
    }
  }

  func update(items: [VibeAgentKitProgressItem]) {
    self.items = items
    rebuildRows()
    if !isHidden {
      setNeedsLayout()
      layoutIfNeeded()
    }
  }

  private func rebuildRows() {
    rowViews.forEach { $0.removeFromSuperview() }
    rowViews.removeAll()

    for (index, item) in items.enumerated() {
      let rowView = VibeAgentKitAgentProgressRowView()
      rowView.configure(item: item, appearance: appearance, showsConnector: index < items.count - 1)
      contentView.addSubview(rowView)
      rowViews.append(rowView)
    }

    setNeedsLayout()
  }

  private func setup() {
    isHidden = true
    alpha = 0.0

    addSubview(backdropView)
    addSubview(sheetView)
    backdropView.addTarget(self, action: #selector(handleBackdropPressed), for: .touchUpInside)

    titleLabel.font = UIFont.systemFont(ofSize: 18.0, weight: .semibold)
    titleLabel.text = "Agent Activity"
    sheetView.contentView.addSubview(handleView)
    sheetView.contentView.addSubview(titleLabel)
    sheetView.contentView.addSubview(scrollView)
    scrollView.addSubview(contentView)

    sheetView.layer.cornerCurve = .continuous
    sheetView.clipsToBounds = true
    scrollView.showsVerticalScrollIndicator = false
    scrollView.alwaysBounceVertical = true

    panGestureRecognizer.delegate = self
    sheetView.addGestureRecognizer(panGestureRecognizer)
  }

  @objc private func handleBackdropPressed() {
    dismiss(animated: true)
  }

  @objc private func handleSheetPan(_ gesture: UIPanGestureRecognizer) {
    let translation = gesture.translation(in: self)
    let velocity = gesture.velocity(in: self)
    let positiveTranslationY = max(0.0, translation.y)

    switch gesture.state {
    case .changed:
      let resistance: CGFloat = positiveTranslationY > 120.0
        ? 120.0 + (positiveTranslationY - 120.0) * 0.4
        : positiveTranslationY
      sheetView.transform = CGAffineTransform(translationX: 0.0, y: resistance)
      let progress = min(1.0, resistance / max(200.0, sheetView.bounds.height))
      backdropView.alpha = 1.0 - (progress * 0.85)

    case .ended, .cancelled, .failed:
      let shouldDismiss = positiveTranslationY > 72.0 || velocity.y > 700.0
      if shouldDismiss {
        dismiss(animated: true)
      } else {
        UIView.animate(
          withDuration: 0.32,
          delay: 0.0,
          usingSpringWithDamping: 0.78,
          initialSpringVelocity: max(0.0, velocity.y / 1200.0),
          options: [.curveEaseOut, .allowUserInteraction]
        ) {
          self.sheetView.transform = .identity
          self.backdropView.alpha = 1.0
        }
      }

    default:
      break
    }
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    otherGestureRecognizer.view is UIScrollView
  }

  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer === panGestureRecognizer else { return true }
    let velocity = panGestureRecognizer.velocity(in: self)
    guard velocity.y > 0 else { return false }
    if scrollView.contentOffset.y > 0 { return false }
    return true
  }
}
