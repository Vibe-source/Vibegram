import MetalKit
import SwiftUI

struct MetalKeyMaskView: UIViewRepresentable {
  let isRevealed: Bool
  let palette: AppThemePalette

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> SecureParticleMaskView {
    let view = SecureParticleMaskView(frame: .zero, device: context.coordinator.device)
    view.delegate = context.coordinator
    view.setSurfaceColor(palette.cardUIColor)
    context.coordinator.setConcealed(!isRevealed, animated: false)
    return view
  }

  func updateUIView(_ uiView: SecureParticleMaskView, context: Context) {
    uiView.setSurfaceColor(palette.cardUIColor)
    context.coordinator.setConcealed(!isRevealed, animated: true)
  }

  final class Coordinator: NSObject, MTKViewDelegate {
    enum Appearance {
      case standard
      case softSpoiler
      /// Independent 2D wander; fills a media frame instead of streaming left-to-right.
      case freeFloat
    }

    let device: MTLDevice?

    private let commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private let quadBuffer: MTLBuffer?
    private let particleBuffer: MTLBuffer?
    private let particleCount: Int
    private let baseRadius: Float
    private let motionMode: Float
    private var startTime = CACurrentMediaTime()
    private var revealProgress: Float = 0
    private var revealTarget: Float = 0
    private var revealStartProgress: Float = 0
    private var revealStartTime = CACurrentMediaTime()
    private var revealDuration: CFTimeInterval = 0

    init(appearance: Appearance = .standard) {
      device = MTLCreateSystemDefaultDevice()
      commandQueue = device?.makeCommandQueue()
      let quadVertices: [SIMD2<Float>] = [
        SIMD2(-1, -1),
        SIMD2(1, -1),
        SIMD2(-1, 1),
        SIMD2(1, 1),
      ]
      let particles = Self.makeParticles(appearance: appearance)
      particleCount = particles.count
      switch appearance {
      case .standard:
        baseRadius = 1.2
        motionMode = 0
      case .softSpoiler:
        baseRadius = 0.58
        motionMode = 0
      case .freeFloat:
        baseRadius = 0.38
        motionMode = 1
      }
      quadBuffer = device?.makeBuffer(
        bytes: quadVertices,
        length: MemoryLayout<SIMD2<Float>>.stride * quadVertices.count
      )
      particleBuffer = device?.makeBuffer(
        bytes: particles,
        length: MemoryLayout<Particle>.stride * particles.count
      )
      super.init()
      setupPipeline()
    }

    private func setupPipeline() {
      guard let device else { return }

      let shaderSource = """
      #include <metal_stdlib>
      using namespace metal;

      struct Particle {
          float2 basePosition;
          float speed;
          float wobble;
          float size;
          float timeOffset;
          float4 color;
      };

      struct Uniforms {
          float2 viewportSize;
          float time;
          float baseRadius;
          float revealProgress;
          float motionMode;
      };

      struct VertexOut {
          float4 position [[position]];
          float2 localPoint;
          float4 color;
          float alpha;
      };

      vertex VertexOut vertex_main(
          uint vertexID [[vertex_id]],
          uint instanceID [[instance_id]],
          constant float2 *quadVertices [[buffer(0)]],
          constant Particle *particles [[buffer(1)]],
          constant Uniforms &uniforms [[buffer(2)]]
      ) {
          Particle particle = particles[instanceID];
          float2 quad = quadVertices[vertexID];

          float width = uniforms.viewportSize.x;
          float height = uniforms.viewportSize.y;
          float halfWidth = width * 0.5;
          float halfHeight = height * 0.5;

          float2 center;
          float radius;
          float flight = 0.0;
          if (uniforms.motionMode > 0.5) {
              float2 origin = particle.basePosition * float2(halfWidth, halfHeight);
              float t = uniforms.time;
              float group = floor(fract(particle.timeOffset * 0.017) * 7.0);
              float groupPhase = group * 1.37;
              float2 sharedFlow = float2(
                  sin(t * 0.10) * width * 0.026,
                  cos(t * 0.08) * height * 0.022);
              float groupClock = t * particle.speed * 0.48 + groupPhase;
              float2 groupFlow = float2(
                  sin(groupClock),
                  cos(groupClock * 0.83 + groupPhase * 0.21)) * particle.wobble * 0.85;
              float2 localFloat = float2(
                  sin(t * 0.14 + particle.timeOffset * 0.035),
                  cos(t * 0.12 + particle.timeOffset * 0.05)) * 0.22;
              float2 floated = origin + sharedFlow + groupFlow + localFloat;
              float wx = fmod(floated.x + halfWidth, width);
              if (wx < 0.0) { wx += width; }
              wx -= halfWidth;
              float wy = fmod(floated.y + halfHeight, height);
              if (wy < 0.0) { wy += height; }
              wy -= halfHeight;
              center = float2(wx, wy);
              float spatialPhase = dot(particle.basePosition, float2(2.4, -1.8));
              float pulse = 0.5 + 0.5 * sin(t * 0.38 + spatialPhase + groupPhase * 0.16);
              radius = uniforms.baseRadius * particle.size * (0.94 + 0.08 * pulse);
          } else {
              float rawX = particle.basePosition.x + (uniforms.time * particle.speed) + particle.timeOffset;
              float wrappedX = fmod(rawX + halfWidth, width);
              if (wrappedX < 0.0) {
                  wrappedX += width;
              }
              wrappedX -= halfWidth;
              float randomA = fract(particle.timeOffset * 0.017);
              float randomB = fract(particle.timeOffset * 0.131);
              float stagger = randomA * 0.28;
              flight = clamp((uniforms.revealProgress - stagger) / (1.0 - stagger), 0.0, 1.0);
              float acceleration = flight * flight;
              float flyX = (flight * 0.12 + acceleration * 0.88) * width * (0.72 + randomA * 0.58);
              float fanDirection = randomB * 2.0 - 1.0;
              float flyY = acceleration * fanDirection * height * (0.12 + randomA * 0.18);
              float waveY = sin((uniforms.time * 2.0) + particle.timeOffset) * particle.wobble;
              center = float2(wrappedX + flyX, particle.basePosition.y + waveY + flyY);
              radius = uniforms.baseRadius * particle.size * (1.0 + flight * 0.32);
          }
          float2 point = center + quad * radius;
          float2 ndc = float2(point.x / max(halfWidth, 1.0), point.y / max(halfHeight, 1.0));

          VertexOut out;
          out.position = float4(ndc.x, ndc.y, 0.0, 1.0);
          out.localPoint = quad;

          float edgeX = 1.0 - smoothstep(0.94, 1.14, abs(center.x) / max(halfWidth, 1.0));
          float edgeY = 1.0 - smoothstep(0.94, 1.14, abs(center.y) / max(halfHeight, 1.0));
          float flightAlpha = 1.0 - smoothstep(0.68, 0.98, flight);
          float contrast = 1.0;
          if (uniforms.motionMode > 0.5) {
              float group = floor(fract(particle.timeOffset * 0.017) * 7.0);
              float spatialPhase = dot(particle.basePosition, float2(2.1, -1.6));
              float waveA = 0.5 + 0.5 * sin(uniforms.time * 0.42 + spatialPhase + group * 0.19);
              float waveB = 0.5 + 0.5 * cos(uniforms.time * 0.29 - spatialPhase * 0.61);
              contrast = smoothstep(0.22, 0.86, waveA * 0.58 + waveB * 0.42);
              out.color = float4(particle.color.rgb * mix(0.78, 1.16, contrast), particle.color.a);
              out.alpha = edgeX * edgeY * mix(0.40, 0.82, contrast);
          } else {
              out.color = particle.color;
              out.alpha = edgeX * flightAlpha;
          }
          return out;
      }

      fragment float4 fragment_main(VertexOut in [[stage_in]]) {
          float dist = length(in.localPoint);
          float circle = 1.0 - smoothstep(0.72, 1.0, dist);
          float alpha = in.color.a * circle * in.alpha;
          return float4(in.color.rgb, alpha);
      }
      """

      do {
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "vertex_main")
        descriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
      } catch {
        print("Failed to create particle pipeline: \\(error)")
      }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
      let now = CACurrentMediaTime()
      let resolvedRevealProgress = currentRevealProgress(at: now)
      if let maskView = view as? SecureParticleMaskView {
        maskView.setRevealProgress(CGFloat(resolvedRevealProgress))
      }

      guard
        let drawable = view.currentDrawable,
        let descriptor = view.currentRenderPassDescriptor,
        let pipelineState,
        let commandQueue,
        let quadBuffer,
        let particleBuffer
      else {
        return
      }

      var uniforms = Uniforms(
        viewportSize: SIMD2(Float(view.bounds.width), Float(view.bounds.height)),
        time: Float(now - startTime),
        baseRadius: baseRadius,
        revealProgress: motionMode > 0.5 ? 0 : resolvedRevealProgress,
        motionMode: motionMode
      )

      let commandBuffer = commandQueue.makeCommandBuffer()
      let encoder = commandBuffer?.makeRenderCommandEncoder(descriptor: descriptor)
      encoder?.setRenderPipelineState(pipelineState)
      encoder?.setVertexBuffer(quadBuffer, offset: 0, index: 0)
      encoder?.setVertexBuffer(particleBuffer, offset: 0, index: 1)
      encoder?.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
      encoder?.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: particleCount)
      encoder?.endEncoding()

      commandBuffer?.present(drawable)
      commandBuffer?.commit()
    }

    func setConcealed(_ concealed: Bool, animated: Bool) {
      let target: Float = concealed ? 0 : 1
      guard abs(target - revealTarget) > 0.001 else { return }

      let now = CACurrentMediaTime()
      revealProgress = currentRevealProgress(at: now)
      revealStartProgress = revealProgress
      revealTarget = target
      revealStartTime = now
      revealDuration = animated ? (concealed ? 0.30 : 0.90) : 0

      if !animated {
        revealProgress = target
      }
    }

    private func currentRevealProgress(at now: CFTimeInterval) -> Float {
      guard revealDuration > 0 else { return revealProgress }

      let linear = Float(min(max((now - revealStartTime) / revealDuration, 0), 1))
      // Reveal stays close to linear through the middle so the particle flight is
      // readable. Re-conceal remains a quicker ease-out.
      let eased =
        revealTarget > revealStartProgress
        ? linear * linear * (3 - 2 * linear)
        : 1 - pow(1 - linear, 3)
      revealProgress = revealStartProgress + (revealTarget - revealStartProgress) * eased
      if linear >= 1 {
        revealProgress = revealTarget
        revealDuration = 0
      }
      return revealProgress
    }

    private static func makeParticles(appearance: Appearance) -> [Particle] {
      if appearance == .freeFloat {
        return (0..<1600).map { _ in
          let hot = Float.random(in: 0...1) > 0.84
          let lightness: Float = hot ? Float.random(in: 0.90...1.0) : Float.random(in: 0.58...0.78)
          return Particle(
            basePosition: SIMD2(Float.random(in: -1...1), Float.random(in: -1...1)),
            speed: Float.random(in: 0.04...0.08),
            wobble: Float.random(in: 0.4...0.9),
            size: Float.random(in: 0.20...0.42),
            timeOffset: Float.random(in: 0...1000),
            color: SIMD4(lightness, lightness, lightness, hot ? Float.random(in: 0.26...0.40) : Float.random(in: 0.10...0.20))
          )
        }
      }
      let isSoft = appearance == .softSpoiler
      return (0..<(isSoft ? 1_250 : 800)).map { _ in
        let rand = Float.random(in: 0...1)
        let yBase = Float.random(in: -1...1)
        let yCluster = (yBase >= 0 ? 1 : -1) * pow(abs(yBase), 2) * 16.0
        let lightness: Float =
          isSoft ? Float.random(in: 0.54...0.78)
          : (rand > 0.6 ? 1.0 : Float.random(in: 0.3...0.6))
        let size: Float =
          isSoft ? Float.random(in: 0.35...0.9)
          : (rand > 0.8 ? Float.random(in: 1.2...1.8) : Float.random(in: 0.4...0.9))

        return Particle(
          basePosition: SIMD2(Float.random(in: -300...300), yCluster),
          speed: Float.random(in: isSoft ? 12...26 : 5...15),
          wobble: Float.random(in: isSoft ? 1.0...4.0 : 0.5...3.0),
          size: size,
          timeOffset: Float.random(in: 0...1000),
          color: SIMD4(lightness, lightness, lightness, isSoft ? 0.32 : 0.9)
        )
      }
    }
  }
}

private struct Particle {
  let basePosition: SIMD2<Float>
  let speed: Float
  let wobble: Float
  let size: Float
  let timeOffset: Float
  let color: SIMD4<Float>
}

private struct Uniforms {
  let viewportSize: SIMD2<Float>
  let time: Float
  let baseRadius: Float
  let revealProgress: Float
  let motionMode: Float
}

final class SecureParticleMaskView: MTKView {
  private let highlightLayer = CAGradientLayer()
  private var surfaceComponents = SIMD4<Double>(0, 0, 0, 0)
  private var revealProgress: CGFloat = 0
  private var particlesOnlyOverlay = false

  override init(frame: CGRect, device: MTLDevice?) {
    super.init(frame: frame, device: device)

    backgroundColor = UIColor(red: 35 / 255, green: 39 / 255, blue: 47 / 255, alpha: 1)
    clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    colorPixelFormat = .bgra8Unorm
    framebufferOnly = false
    isOpaque = false
    preferredFramesPerSecond = 60
    enableSetNeedsDisplay = false
    isPaused = false

    layer.cornerRadius = 12
    layer.cornerCurve = .continuous
    layer.masksToBounds = true
    layer.borderWidth = 1 / UIScreen.main.scale
    layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor

    highlightLayer.colors = [
      UIColor.white.withAlphaComponent(0.05).cgColor,
      UIColor.clear.cgColor,
    ]
    highlightLayer.locations = [0, 0.35]
    highlightLayer.startPoint = CGPoint(x: 0.5, y: 0)
    highlightLayer.endPoint = CGPoint(x: 0.5, y: 1)
    layer.addSublayer(highlightLayer)
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    highlightLayer.frame = bounds
  }

  func setSurfaceColor(_ color: UIColor) {
    backgroundColor = .clear
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
    surfaceComponents = SIMD4(Double(red), Double(green), Double(blue), Double(alpha))
    applySurfaceOpacity()
  }

  func setRevealProgress(_ progress: CGFloat) {
    revealProgress = min(max(progress, 0), 1)
    applySurfaceOpacity()
  }

  /// Transparent clear so particles sit on a sibling blurred still, not a card fill.
  func prepareAsMediaOverlay() {
    particlesOnlyOverlay = true
    backgroundColor = .clear
    clearColor = MTLClearColorMake(0, 0, 0, 0)
    isOpaque = false
    highlightLayer.isHidden = true
    highlightLayer.opacity = 0
    layer.borderWidth = 0
    layer.cornerRadius = 0
    layer.masksToBounds = true
  }

  private func applySurfaceOpacity() {
    if particlesOnlyOverlay {
      clearColor = MTLClearColorMake(0, 0, 0, 0)
      highlightLayer.opacity = 0
      return
    }
    let surfaceAlpha = 1 - revealProgress * revealProgress * (3 - 2 * revealProgress)
    clearColor = MTLClearColor(
      red: surfaceComponents.x,
      green: surfaceComponents.y,
      blue: surfaceComponents.z,
      alpha: surfaceComponents.w * Double(surfaceAlpha)
    )
    highlightLayer.opacity = Float(surfaceAlpha)
    layer.borderColor = UIColor.white.withAlphaComponent(0.08 * surfaceAlpha).cgColor
  }
}
