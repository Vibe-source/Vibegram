import UIKit

private enum ChatNativeAgentRowPresentationKind: String {
  case legacy
  case assistant
  case assistantProgressTree
  case assistantActions
  case assistantAgentCard
}

private enum ChatNativeAgentMessageAction: String {
  case copy
  case thumbUp
  case thumbDown
  case regenerate
}

// MARK: - Agent Bubble Long-Press Menu Overlay

final class ChatNativeAgentBubbleMenuOverlay: UIView {
  private let backgroundView = UIView()
  private let menuCard = UIVisualEffectView(effect: nil)
  private let menuStack = UIStackView()
  private let sourceFrame: CGRect
  private let text: String
  private let messageId: String
  private let onAction: (String) -> Void
  private var isDismissing = false

  init(
    sourceView: UIView,
    sourceFrame: CGRect,
    text: String,
    messageId: String,
    onAction: @escaping (String) -> Void
  ) {
    self.sourceFrame = sourceFrame
    self.text = text
    self.messageId = messageId
    self.onAction = onAction
    super.init(frame: .zero)

    backgroundView.backgroundColor = UIColor.black.withAlphaComponent(0.25)
    backgroundView.alpha = 0.0
    addSubview(backgroundView)

    let blurStyle: UIBlurEffect.Style = .systemMaterial
    menuCard.effect = UIBlurEffect(style: blurStyle)
    menuCard.layer.cornerRadius = 14.0
    menuCard.layer.cornerCurve = .continuous
    menuCard.clipsToBounds = true
    menuCard.alpha = 0.0
    addSubview(menuCard)

    menuStack.axis = .vertical
    menuStack.spacing = 0.0
    menuCard.contentView.addSubview(menuStack)

    let actions: [(String, String, String)] = [
      ("doc.on.doc", "Copy", "copy"),
      ("arrow.clockwise", "Regenerate", "regenerate"),
    ]

    for (index, item) in actions.enumerated() {
      let button = makeMenuItem(
        icon: item.0,
        title: item.1,
        actionId: item.2,
        showDivider: index < actions.count - 1
      )
      menuStack.addArrangedSubview(button)
    }

    let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap))
    tap.cancelsTouchesInView = false
    backgroundView.addGestureRecognizer(tap)
  }

  required init?(coder: NSCoder) {
    fatalError()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    backgroundView.frame = bounds

    let menuWidth: CGFloat = 180.0
    let menuHeight = menuStack.systemLayoutSizeFitting(
      CGSize(width: menuWidth, height: UIView.layoutFittingCompressedSize.height)
    ).height
    menuStack.frame = CGRect(x: 0, y: 0, width: menuWidth, height: menuHeight)

    let safeBottom = bounds.height - safeAreaInsets.bottom - 10.0
    let menuY = min(sourceFrame.maxY + 6.0, safeBottom - menuHeight)
    let menuX = max(16.0, min(sourceFrame.minX, bounds.width - menuWidth - 16.0))
    menuCard.frame = CGRect(x: menuX, y: menuY, width: menuWidth, height: menuHeight)
  }

  func animateIn() {
    setNeedsLayout()
    layoutIfNeeded()
    menuCard.transform = CGAffineTransform(scaleX: 0.9, y: 0.9).translatedBy(x: 0, y: -8)

    UIView.animate(withDuration: 0.22, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0, options: .allowUserInteraction) {
      self.backgroundView.alpha = 1.0
      self.menuCard.alpha = 1.0
      self.menuCard.transform = .identity
    }
  }

  private func animateOut(completion: (() -> Void)? = nil) {
    guard !isDismissing else { return }
    isDismissing = true
    UIView.animate(withDuration: 0.18, delay: 0, options: .curveEaseIn) {
      self.backgroundView.alpha = 0.0
      self.menuCard.alpha = 0.0
      self.menuCard.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
    } completion: { _ in
      self.removeFromSuperview()
      completion?()
    }
  }

  @objc private func handleBackgroundTap() {
    animateOut()
  }

  private func makeMenuItem(icon: String, title: String, actionId: String, showDivider: Bool) -> UIView {
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false

    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    let config = UIImage.SymbolConfiguration(pointSize: 15.0, weight: .medium)
    button.setImage(UIImage(systemName: icon, withConfiguration: config), for: .normal)
    button.setTitle("  \(title)", for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 15.0, weight: .regular)
    button.contentHorizontalAlignment = .leading
    button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
    button.accessibilityIdentifier = actionId
    button.addTarget(self, action: #selector(handleMenuAction(_:)), for: .touchUpInside)
    container.addSubview(button)

    if showDivider {
      let divider = UIView()
      divider.translatesAutoresizingMaskIntoConstraints = false
      divider.backgroundColor = UIColor.separator.withAlphaComponent(0.3)
      container.addSubview(divider)
      NSLayoutConstraint.activate([
        divider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
        divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        divider.heightAnchor.constraint(equalToConstant: 0.5),
      ])
    }

    NSLayoutConstraint.activate([
      button.topAnchor.constraint(equalTo: container.topAnchor),
      button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      button.heightAnchor.constraint(equalToConstant: 44.0),
    ])

    return container
  }

  @objc private func handleMenuAction(_ sender: UIButton) {
    guard let actionId = sender.accessibilityIdentifier else { return }
    animateOut { [onAction] in
      onAction(actionId)
    }
  }
}

// MARK: - User Message Long-Press Menu Overlay (Glass, No Reactions)

final class ChatNativeAgentUserMenuOverlay: UIView {
  private let backgroundGlassView: UIVisualEffectView
  private let menuCard: UIVisualEffectView
  private let menuStack = UIStackView()
  private let sourceFrame: CGRect
  private let text: String
  private let messageId: String
  private let onAction: (String) -> Void
  private var isDismissing = false

  init(
    sourceFrame: CGRect,
    text: String,
    messageId: String,
    appearance: ChatListAppearance,
    onAction: @escaping (String) -> Void
  ) {
    self.sourceFrame = sourceFrame
    self.text = text
    self.messageId = messageId
    self.onAction = onAction

    let bgStyle: UIBlurEffect.Style =
      appearance.isDark ? .systemMaterialDark : .systemMaterialLight
    self.backgroundGlassView = UIVisualEffectView(effect: UIBlurEffect(style: bgStyle))

    let colorOverlay = UIView()
    let overlayBase: UIColor = appearance.isDark ? .black : .white
    let overlayAlpha: CGFloat = appearance.isDark ? 0.42 : 0.32
    colorOverlay.backgroundColor = overlayBase.withAlphaComponent(overlayAlpha)
    colorOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    self.backgroundGlassView.contentView.addSubview(colorOverlay)

    if #available(iOS 26.0, *) {
      let glass = UIGlassEffect(style: .regular)
      self.menuCard = UIVisualEffectView(effect: glass)
      self.menuCard.layer.cornerRadius = 14.0
      self.menuCard.layer.cornerCurve = .continuous
    } else {
      self.menuCard = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
      self.menuCard.layer.cornerRadius = 14.0
      self.menuCard.layer.cornerCurve = .continuous
    }
    self.menuCard.clipsToBounds = true

    super.init(frame: .zero)

    backgroundGlassView.alpha = 0
    addSubview(backgroundGlassView)

    menuCard.alpha = 0
    addSubview(menuCard)

    menuStack.axis = .vertical
    menuStack.spacing = 0
    menuCard.contentView.addSubview(menuStack)

    let actions: [(String, String, String)] = [
      ("doc.on.doc", "Copy", "copy"),
      ("trash", "Delete", "delete"),
    ]

    for (index, item) in actions.enumerated() {
      let button = makeMenuItem(
        icon: item.0,
        title: item.1,
        actionId: item.2,
        isDestructive: item.2 == "delete",
        showDivider: index < actions.count - 1
      )
      menuStack.addArrangedSubview(button)
    }

    let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap))
    tap.cancelsTouchesInView = false
    backgroundGlassView.addGestureRecognizer(tap)
  }

  required init?(coder: NSCoder) { fatalError() }

  override func layoutSubviews() {
    super.layoutSubviews()
    backgroundGlassView.frame = bounds

    let menuWidth: CGFloat = 200.0
    let menuHeight = menuStack.systemLayoutSizeFitting(
      CGSize(width: menuWidth, height: UIView.layoutFittingCompressedSize.height)
    ).height
    menuStack.frame = CGRect(x: 0, y: 0, width: menuWidth, height: menuHeight)

    let safeTop = safeAreaInsets.top + 10.0
    let safeBottom = bounds.height - safeAreaInsets.bottom - 10.0

    // Place menu above or below source depending on space
    var menuY = sourceFrame.maxY + 8.0
    if menuY + menuHeight > safeBottom {
      menuY = sourceFrame.minY - menuHeight - 8.0
    }
    menuY = max(safeTop, min(safeBottom - menuHeight, menuY))

    // Align near the right side (user messages are on the right)
    let menuX = max(16.0, min(sourceFrame.maxX - menuWidth, bounds.width - menuWidth - 16.0))
    menuCard.frame = CGRect(x: menuX, y: menuY, width: menuWidth, height: menuHeight)
  }

  func animateIn() {
    setNeedsLayout()
    layoutIfNeeded()
    menuCard.transform = CGAffineTransform(scaleX: 0.9, y: 0.9).translatedBy(x: 0, y: -8)

    UIView.animate(
      withDuration: 0.3,
      delay: 0,
      usingSpringWithDamping: 0.82,
      initialSpringVelocity: 0,
      options: .allowUserInteraction
    ) {
      self.backgroundGlassView.alpha = 1.0
      self.menuCard.alpha = 1.0
      self.menuCard.transform = .identity
    }
  }

  private func animateOut(completion: (() -> Void)? = nil) {
    guard !isDismissing else { return }
    isDismissing = true
    UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseIn) {
      self.backgroundGlassView.alpha = 0
      self.menuCard.alpha = 0
      self.menuCard.transform = CGAffineTransform(scaleX: 0.95, y: 0.95)
    } completion: { _ in
      self.removeFromSuperview()
      completion?()
    }
  }

  @objc private func handleBackgroundTap() {
    animateOut()
  }

  private func makeMenuItem(
    icon: String,
    title: String,
    actionId: String,
    isDestructive: Bool,
    showDivider: Bool
  ) -> UIView {
    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false

    let button = UIButton(type: .system)
    button.translatesAutoresizingMaskIntoConstraints = false
    let config = UIImage.SymbolConfiguration(pointSize: 15.0, weight: .medium)
    button.setImage(UIImage(systemName: icon, withConfiguration: config), for: .normal)
    button.setTitle("  \(title)", for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 15.0, weight: .regular)
    button.tintColor = isDestructive ? .systemRed : .label
    button.contentHorizontalAlignment = .leading
    button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
    button.accessibilityIdentifier = actionId
    button.addTarget(self, action: #selector(handleMenuAction(_:)), for: .touchUpInside)
    container.addSubview(button)

    if showDivider {
      let divider = UIView()
      divider.translatesAutoresizingMaskIntoConstraints = false
      divider.backgroundColor = UIColor.separator.withAlphaComponent(0.3)
      container.addSubview(divider)
      NSLayoutConstraint.activate([
        divider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
        divider.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        divider.heightAnchor.constraint(equalToConstant: 0.5),
      ])
    }

    NSLayoutConstraint.activate([
      button.topAnchor.constraint(equalTo: container.topAnchor),
      button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      button.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      button.heightAnchor.constraint(equalToConstant: 44.0),
    ])

    return container
  }

  @objc private func handleMenuAction(_ sender: UIButton) {
    guard let actionId = sender.accessibilityIdentifier else { return }
    animateOut { [onAction] in
      onAction(actionId)
    }
  }
}

// MARK: - Agent Message Views

private final class ChatNativeAgentPlainTextView: UIView {
  // Progress row path (isProgress=true)
  private let baseLabel = ChatNativeStreamingTextLabel()
  private let shimmerLabel = ChatNativeStreamingTextLabel()
  private let shimmerGradient = CAGradientLayer()
  private var isShimmering = false
  private let shimmerBandWidth: CGFloat = 190.0
  private let shimmerTravelPadding: CGFloat = 180.0
  private var shimmerAnimatedWidth: CGFloat = 0.0

  // Block-render path (isProgress=false)
  private var blockViews: [UIView] = []
  private var blockFrames: [CGRect] = []
  private var lastBlockSignature: String = ""

  // Shared state
  private var lastText: String?
  private var lastRowKey: String?
  private var cachedProgressFrame: CGRect = .zero

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    [baseLabel, shimmerLabel].forEach {
      $0.numberOfLines = 0
      $0.backgroundColor = .clear
      addSubview($0)
    }
    shimmerLabel.isUserInteractionEnabled = false

    shimmerGradient.startPoint = CGPoint(x: 0, y: 0.5)
    shimmerGradient.endPoint = CGPoint(x: 1, y: 0.5)
    shimmerGradient.locations = [0.0, 0.18, 0.38, 0.50, 0.62, 0.82, 1.0]
    shimmerLabel.layer.mask = shimmerGradient
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func configure(
    row: ChatListRow,
    appearance: ChatListAppearance,
    availableWidth: CGFloat
  ) -> CGFloat {
    let isProgress = row.messageType == "agent_progress"
    let text = (row.plainContent ?? row.text).trimmingCharacters(in: .whitespacesAndNewlines)

    let topPadding: CGFloat = isProgress ? 8.0 : 0.0
    let bottomPadding: CGFloat = isProgress ? 6.0 : 14.0
    let leftPadding: CGFloat = 8.0
    let rightPadding: CGFloat = 32.0
    let labelWidth = max(1.0, availableWidth - leftPadding - rightPadding)

    if isProgress {
      // --- Progress path: shimmer label pair ---
      let font = UIFont.systemFont(ofSize: 11.5, weight: .medium)
      let lineHeight: CGFloat = 16.0
      let baseColor = appearance.timeColorThem.withAlphaComponent(0.35)
      let highlightColor = appearance.timeColorThem.withAlphaComponent(0.85)

      let baseAttributed = ChatNativeAgentTextRenderer.makeAttributedText(
        text: text, font: font, textColor: baseColor, lineHeight: lineHeight)
      let highlightAttributed = ChatNativeAgentTextRenderer.makeAttributedText(
        text: text, font: font, textColor: highlightColor, lineHeight: lineHeight)

      let measuredSize = ChatNativeAgentTextRenderer.measuredSize(for: baseAttributed, width: labelWidth)
      let textHeight = max(ceil(font.lineHeight), measuredSize.height)
      let textWidth = min(labelWidth, measuredSize.width)

      let shouldTransition = lastText != text || lastRowKey != row.key
      if shouldTransition {
        UIView.transition(with: self, duration: 0.22, options: [.transitionCrossDissolve, .allowUserInteraction]) {
          self.baseLabel.applyStreamingText(baseAttributed, rawText: text, isStreaming: false)
          self.shimmerLabel.applyStreamingText(highlightAttributed, rawText: text, isStreaming: false)
        }
      } else {
        baseLabel.applyStreamingText(baseAttributed, rawText: text, isStreaming: false)
        shimmerLabel.applyStreamingText(highlightAttributed, rawText: text, isStreaming: false)
      }

      lastText = text
      lastRowKey = row.key

      cachedProgressFrame = CGRect(x: leftPadding, y: topPadding, width: textWidth, height: textHeight)

      // hide block views
      blockViews.forEach { $0.isHidden = true }
      baseLabel.isHidden = false
      shimmerLabel.isHidden = false

      startShimmerAnimation()
      setNeedsLayout()
      return topPadding + textHeight + bottomPadding

    } else {
      // --- Block-render path ---
      stopShimmerAnimation()
      baseLabel.isHidden = true
      shimmerLabel.isHidden = true

      let font = UIFont.systemFont(ofSize: 18, weight: .regular)
      let lineHeight: CGFloat = 26.0
      let textColor = appearance.textColorThem
      let isStreaming = row.isStreamingText
      var blocks = ChatNativeAgentTextRenderer.parseBlocks(text).filter { block in
        // No diff → no "0 files changed · Review" card (see agentRuntimeHasDiff).
        if case .agentRuntime(let runtime) = block { return agentRuntimeHasDiff(runtime) }
        return true
      }
      // The runtime/diff card is the end-of-turn summary — never render it while
      // the turn is still streaming (it reappears once the row is no longer live).
      if !isStreaming, let runtime = row.agentRuntime,
        agentRuntimeHasDiff(runtime),
        !blocks.contains(where: {
          if case .agentRuntime = $0 { return true }
          return false
        })
      {
        blocks.append(.agentRuntime(runtime))
      }

      // Rebuild subviews only when block structure changes
      let signature = blocks.map { block -> String in
        switch block {
        case .text: return "T"
        case .code: return "C"
        case .agentPack: return "P"
        case .agentRuntime: return "R"
        }
      }.joined()

      if signature != lastBlockSignature {
        blockViews.forEach { $0.removeFromSuperview() }
        blockViews = blocks.map { block -> UIView in
          switch block {
          case .text:
            let label = ChatNativeStreamingTextLabel()
            label.numberOfLines = 0
            label.backgroundColor = .clear
            addSubview(label)
            return label
          case .code:
            let card = AgentCodeBlockView()
            addSubview(card)
            return card
          case .agentPack:
            let packView = AgentIntegrationPackView()
            addSubview(packView)
            return packView
          case .agentRuntime:
            let runtimeView = AgentRuntimeSummaryView()
            addSubview(runtimeView)
            return runtimeView
          }
        }
        lastBlockSignature = signature
      } else {
        blockViews.forEach { $0.isHidden = false }
      }

      // Find index of last text block for streaming animation
      var lastTextIdx: Int? = nil
      for (i, block) in blocks.enumerated() {
        if case .text = block { lastTextIdx = i }
      }

      // Layout and configure each block
      var yOffset: CGFloat = topPadding
      blockFrames = []
      for (i, block) in blocks.enumerated() {
        let view = blockViews[i]
        view.isHidden = false
        switch block {
        case .text(let content):
          let label = view as! ChatNativeStreamingTextLabel
          let shouldStream = isStreaming && i == lastTextIdx
          let attributed = ChatNativeAgentTextRenderer.makeAttributedText(
            text: content, font: font, textColor: textColor, lineHeight: lineHeight)
          let measured = ChatNativeAgentTextRenderer.measuredSize(for: attributed, width: labelWidth)
          let h = max(ceil(font.lineHeight), measured.height)
          label.applyStreamingText(attributed, rawText: content, isStreaming: shouldStream)
          let frame = CGRect(x: leftPadding, y: yOffset, width: labelWidth, height: h)
          blockFrames.append(frame)
          yOffset += h + 6.0

        case .code(let content, let lang):
          let card = view as! AgentCodeBlockView
          // Allow code cards to use the full horizontal area (reduce right padding)
          let cardAvailableWidth = max(1.0, availableWidth - leftPadding)
          let cardHeight = card.configure(
            code: content,
            language: lang,
            textColor: textColor,
            baseFont: font,
            availableWidth: cardAvailableWidth,
            storageKey: "\(row.key)#\(i)"
          )
          let frame = CGRect(x: leftPadding, y: yOffset, width: cardAvailableWidth, height: cardHeight)
          blockFrames.append(frame)
          yOffset += cardHeight + 6.0
        case .agentPack(let pack):
          let packView = view as! AgentIntegrationPackView
          let packAvailableWidth = max(1.0, availableWidth - leftPadding)
          let packHeight = packView.configure(
            pack: pack,
            textColor: textColor,
            availableWidth: packAvailableWidth,
            storageKey: "\(row.key)#\(i)"
          )
          blockFrames.append(
            CGRect(x: leftPadding, y: yOffset, width: packAvailableWidth, height: packHeight)
          )
          yOffset += packHeight + 6.0
        case .agentRuntime(let runtime):
          let runtimeView = view as! AgentRuntimeSummaryView
          let runtimeAvailableWidth = max(1.0, availableWidth - leftPadding)
          let runtimeHeight = runtimeView.configure(
            runtime: runtime,
            textColor: textColor,
            availableWidth: runtimeAvailableWidth,
            isExpanded: false
          )
          blockFrames.append(
            CGRect(x: leftPadding, y: yOffset, width: runtimeAvailableWidth, height: runtimeHeight)
          )
          yOffset += runtimeHeight + 6.0
        }
      }

      lastText = text
      lastRowKey = row.key

      setNeedsLayout()
      return yOffset + bottomPadding
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Progress path
    baseLabel.frame = cachedProgressFrame
    shimmerLabel.frame = cachedProgressFrame
    updateShimmerGradientFrame()
    if isShimmering, abs(shimmerAnimatedWidth - shimmerLabel.bounds.width) > 1.0 {
      restartShimmerAnimation()
    }
    // Block path
    for (i, view) in blockViews.enumerated() where i < blockFrames.count {
      view.frame = blockFrames[i]
    }
  }

  private func startShimmerAnimation() {
    guard !isShimmering else { return }
    isShimmering = true
    shimmerLabel.isHidden = false
    shimmerLabel.alpha = 1.0

    shimmerGradient.colors = [
      UIColor.clear.cgColor,
      UIColor.black.withAlphaComponent(0.10).cgColor,
      UIColor.black.withAlphaComponent(0.54).cgColor,
      UIColor.black.cgColor,
      UIColor.black.withAlphaComponent(0.54).cgColor,
      UIColor.black.withAlphaComponent(0.10).cgColor,
      UIColor.clear.cgColor,
    ]
    updateShimmerGradientFrame()
    restartShimmerAnimation()
  }

  // Size the shimmer band relative to the (often short) progress text so the
  // highlight visibly sweeps left→right across the label instead of glinting the
  // whole word at once. Band ≈ 55% of the text, clamped to a sensible range, and
  // the lead-in/out padding stays small so the highlight spends its time on text.
  private func effectiveShimmerBand() -> (band: CGFloat, padding: CGFloat) {
    let contentWidth = max(shimmerLabel.bounds.width, 1.0)
    let band = max(36.0, min(shimmerBandWidth, contentWidth * 0.55))
    let padding = min(shimmerTravelPadding, band * 0.6)
    return (band, padding)
  }

  private func restartShimmerAnimation() {
    shimmerGradient.removeAnimation(forKey: "shimmerTranslate")
    shimmerGradient.transform = CATransform3DIdentity

    let contentWidth = max(shimmerLabel.bounds.width, 1.0)
    shimmerAnimatedWidth = contentWidth
    let (band, padding) = effectiveShimmerBand()

    let animation = CABasicAnimation(keyPath: "transform.translation.x")
    animation.fromValue = 0.0
    animation.toValue = contentWidth + band + padding * 2.0
    animation.duration = 2.45
    animation.repeatCount = .infinity
    animation.timingFunction = CAMediaTimingFunction(name: .linear)
    shimmerGradient.add(animation, forKey: "shimmerTranslate")
  }

  private func stopShimmerAnimation() {
    guard isShimmering else { return }
    isShimmering = false
    shimmerGradient.removeAnimation(forKey: "shimmerTranslate")
    shimmerGradient.transform = CATransform3DIdentity
    shimmerAnimatedWidth = 0.0
    shimmerLabel.isHidden = true
  }

  private func updateShimmerGradientFrame() {
    let (band, padding) = effectiveShimmerBand()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shimmerGradient.frame = CGRect(
      x: -(band + padding),
      y: 0.0,
      width: band,
      height: max(shimmerLabel.bounds.height, 18.0)
    )
    CATransaction.commit()
  }
}

private final class ChatNativeAgentProgressStepView: UIView {
  private let connectorView = UIView()
  private let dotView = UIView()
  private let baseLabel = ChatNativeStreamingTextLabel()
  private let shimmerLabel = ChatNativeStreamingTextLabel()
  private let shimmerGradient = CAGradientLayer()
  private var cachedConnectorFrame: CGRect = .zero
  private var cachedDotFrame: CGRect = .zero
  private var cachedLabelFrame: CGRect = .zero
  private var isPulsing = false
  private var isShimmering = false
  private let shimmerBandWidth: CGFloat = 190.0
  private let shimmerTravelPadding: CGFloat = 180.0
  private var shimmerAnimatedWidth: CGFloat = 0.0
  private var lastNodeId: String?
  private var lastLabelText: String?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    connectorView.isHidden = true
    addSubview(connectorView)

    dotView.isHidden = true
    addSubview(dotView)

    [baseLabel, shimmerLabel].forEach {
      $0.numberOfLines = 0
      $0.backgroundColor = .clear
      addSubview($0)
    }

    shimmerGradient.startPoint = CGPoint(x: 0, y: 0.5)
    shimmerGradient.endPoint = CGPoint(x: 1, y: 0.5)
    shimmerGradient.locations = [0.0, 0.18, 0.38, 0.50, 0.62, 0.82, 1.0]
    shimmerLabel.layer.mask = shimmerGradient
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func configure(
    node: ChatListRow.AgentProgressNode,
    appearance: ChatListAppearance,
    availableWidth: CGFloat
  ) -> CGFloat {
    let indent = CGFloat(node.depth) * 18.0
    let topPadding: CGFloat = 6.0
    let bottomPadding: CGFloat = 8.0
    let dotSize: CGFloat = node.depth == 0 ? 8.0 : 6.0
    let dotX = 8.0 + indent
    let labelX = dotX + dotSize + 10.0
    let labelWidth = max(1.0, availableWidth - labelX - 8.0)
    let font = UIFont.systemFont(ofSize: node.depth == 0 ? 12.0 : 11.0, weight: node.depth == 0 ? .semibold : .medium)
    let lineHeight: CGFloat = node.depth == 0 ? 16.0 : 14.0
    let textColor: UIColor

    switch node.status {
    case "complete":
      textColor = appearance.textColorThem.withAlphaComponent(0.78)
      dotView.backgroundColor = appearance.timeColorThem.withAlphaComponent(0.72)
      stopPulse()
    case "error":
      textColor = UIColor.systemRed.withAlphaComponent(0.94)
      dotView.backgroundColor = UIColor.systemRed.withAlphaComponent(0.88)
      stopPulse()
    default:
      textColor = appearance.textColorThem.withAlphaComponent(node.depth == 0 ? 0.96 : 0.90)
      dotView.backgroundColor = appearance.textColorThem.withAlphaComponent(node.depth == 0 ? 0.94 : 0.78)
      startPulse()
    }

    connectorView.isHidden = node.depth == 0
    connectorView.backgroundColor =
      appearance.timeColorThem.withAlphaComponent(node.depth == 0 ? 0.0 : 0.28)
    dotView.isHidden = false

    let isRunning = node.status != "complete" && node.status != "error"
    let baseColor = isRunning ? textColor.withAlphaComponent(0.35) : textColor
    let highlightColor = isRunning ? textColor.withAlphaComponent(0.85) : textColor

    let attributed = ChatNativeAgentTextRenderer.makeAttributedText(
      text: node.label,
      font: font,
      textColor: baseColor,
      lineHeight: lineHeight
    )
    let highlightAttributed = ChatNativeAgentTextRenderer.makeAttributedText(
      text: node.label,
      font: font,
      textColor: highlightColor,
      lineHeight: lineHeight
    )

    let measuredSize = ChatNativeAgentTextRenderer.measuredSize(for: attributed, width: labelWidth)
    let textHeight = max(ceil(font.lineHeight), measuredSize.height)
    let textWidth = min(labelWidth, measuredSize.width)

    let shouldTransition = lastNodeId != node.id || lastLabelText != node.label
    if shouldTransition {
      UIView.transition(
        with: self,
        duration: 0.22,
        options: [.transitionCrossDissolve, .allowUserInteraction]
      ) {
        self.performLabelUpdate(
          baseAttributed: attributed,
          highlightAttributed: highlightAttributed,
          text: node.label
        )
      }
    } else {
      performLabelUpdate(
        baseAttributed: attributed,
        highlightAttributed: highlightAttributed,
        text: node.label
      )
    }
    lastNodeId = node.id
    lastLabelText = node.label

    if isRunning {
      startShimmerAnimation()
    } else {
      stopShimmerAnimation()
    }

    cachedConnectorFrame = CGRect(
      x: dotX + floor((dotSize - 1.0) * 0.5),
      y: 0.0,
      width: 1.0 / UIScreen.main.scale,
      height: topPadding + textHeight + bottomPadding
    )
    cachedDotFrame = CGRect(
      x: dotX,
      y: topPadding + 4.0,
      width: dotSize,
      height: dotSize
    )
    cachedLabelFrame = CGRect(
      x: labelX,
      y: topPadding,
      width: textWidth,
      height: textHeight
    )

    setNeedsLayout()
    return topPadding + textHeight + bottomPadding
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    connectorView.frame = cachedConnectorFrame
    dotView.frame = cachedDotFrame
    dotView.layer.cornerRadius = cachedDotFrame.width * 0.5
    baseLabel.frame = cachedLabelFrame
    shimmerLabel.frame = cachedLabelFrame
    updateShimmerGradientFrame()
    if isShimmering, abs(shimmerAnimatedWidth - shimmerLabel.bounds.width) > 1.0 {
      restartShimmerAnimation()
    }
  }

  private func performLabelUpdate(
    baseAttributed: NSAttributedString,
    highlightAttributed: NSAttributedString,
    text: String
  ) {
    baseLabel.applyStreamingText(baseAttributed, rawText: text, isStreaming: false)
    shimmerLabel.applyStreamingText(highlightAttributed, rawText: text, isStreaming: false)
  }

  private func startPulse() {
    guard !isPulsing else { return }
    isPulsing = true

    let scale = CABasicAnimation(keyPath: "transform.scale")
    scale.fromValue = 0.92
    scale.toValue = 1.16
    scale.duration = 0.85
    scale.autoreverses = true
    scale.repeatCount = .infinity
    scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    dotView.layer.add(scale, forKey: "agentProgressPulseScale")

    let opacity = CABasicAnimation(keyPath: "opacity")
    opacity.fromValue = 0.55
    opacity.toValue = 1.0
    opacity.duration = 0.85
    opacity.autoreverses = true
    opacity.repeatCount = .infinity
    opacity.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    dotView.layer.add(opacity, forKey: "agentProgressPulseOpacity")
  }

  private func stopPulse() {
    guard isPulsing else { return }
    isPulsing = false
    dotView.layer.removeAnimation(forKey: "agentProgressPulseScale")
    dotView.layer.removeAnimation(forKey: "agentProgressPulseOpacity")
  }

  private func startShimmerAnimation() {
    guard !isShimmering else { return }
    isShimmering = true
    shimmerLabel.isHidden = false
    shimmerLabel.alpha = 1.0

    shimmerGradient.colors = [
      UIColor.clear.cgColor,
      UIColor.black.withAlphaComponent(0.10).cgColor,
      UIColor.black.withAlphaComponent(0.54).cgColor,
      UIColor.black.cgColor,
      UIColor.black.withAlphaComponent(0.54).cgColor,
      UIColor.black.withAlphaComponent(0.10).cgColor,
      UIColor.clear.cgColor,
    ]
    updateShimmerGradientFrame()
    restartShimmerAnimation()
  }

  // See ChatNativeAgentPlainTextView.effectiveShimmerBand — band sized to the
  // text so the highlight sweeps a short progress label instead of glinting it
  // whole.
  private func effectiveShimmerBand() -> (band: CGFloat, padding: CGFloat) {
    let contentWidth = max(shimmerLabel.bounds.width, 1.0)
    let band = max(36.0, min(shimmerBandWidth, contentWidth * 0.55))
    let padding = min(shimmerTravelPadding, band * 0.6)
    return (band, padding)
  }

  private func restartShimmerAnimation() {
    shimmerGradient.removeAnimation(forKey: "stepShimmerTranslate")
    shimmerGradient.transform = CATransform3DIdentity

    let contentWidth = max(shimmerLabel.bounds.width, 1.0)
    shimmerAnimatedWidth = contentWidth
    let (band, padding) = effectiveShimmerBand()

    let animation = CABasicAnimation(keyPath: "transform.translation.x")
    animation.fromValue = 0.0
    animation.toValue = contentWidth + band + padding * 2.0
    animation.duration = 2.45
    animation.repeatCount = .infinity
    animation.timingFunction = CAMediaTimingFunction(name: .linear)
    shimmerGradient.add(animation, forKey: "stepShimmerTranslate")
  }

  private func stopShimmerAnimation() {
    guard isShimmering else { return }
    isShimmering = false
    shimmerGradient.removeAnimation(forKey: "stepShimmerTranslate")
    shimmerGradient.transform = CATransform3DIdentity
    shimmerAnimatedWidth = 0.0
    shimmerLabel.isHidden = true
  }

  private func updateShimmerGradientFrame() {
    let (band, padding) = effectiveShimmerBand()
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    shimmerGradient.frame = CGRect(
      x: -(band + padding),
      y: 0.0,
      width: band,
      height: max(shimmerLabel.bounds.height, 18.0)
    )
    CATransaction.commit()
  }
}

private final class ChatNativeAgentProgressTreeView: UIView {
  private let cardView = UIView()
  private var stepViews: [ChatNativeAgentProgressStepView] = []
  private var cachedCardFrame: CGRect = .zero
  private var cachedStepFrames: [CGRect] = []
  private var lastNodeIds: [String] = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    cardView.layer.cornerCurve = .continuous
    cardView.layer.cornerRadius = 16.0
    addSubview(cardView)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  // Compact, Claude-Code-style label for an enriched tool node:
  //   "Read ChatEngine.swift", "Edit chat.ex  +12 −3", "Run git status", …
  private func agentNodeDisplayLabel(_ node: ChatListRow.AgentProgressNode) -> String {
    guard let kind = node.kind, !kind.isEmpty else { return node.label }
    // Verb + target is the CLI shape (target = path/command). Native server steps reuse the
    // same coarse kinds but ship a written label and no target — see chatAgentNodeCompactLabel.
    if node.target?.isEmpty != false, !node.label.isEmpty, kind != "todo" {
      return node.label
    }
    let verb: String
    switch kind {
    case "read": verb = "Read"
    case "edit": verb = "Edit"
    case "write": verb = "Create"
    case "bash": verb = "Run"
    case "search": verb = "Search"
    case "web": verb = "Fetch"
    case "task": verb = "Step"
    case "todo":
      let a = node.action?.lowercased() ?? ""
      if a == "create" || a == "created" { return "Created Task" }
      if a == "update" || a == "updated" { return "Updated Task" }
      return "Create Task or Update Task"
    default: return node.label
    }
    var text = verb
    if let target = node.target, !target.isEmpty {
      text += " \(target)"
    }
    var stats: [String] = []
    if let added = node.added, added > 0 { stats.append("+\(added)") }
    if let removed = node.removed, removed > 0 { stats.append("−\(removed)") }
    if !stats.isEmpty {
      text += "  " + stats.joined(separator: " ")
    }
    return text
  }

  private func normalizedNodeStatus(_ status: String) -> String {
    switch status.lowercased() {
    case "error", "failed", "failure":
      return "error"
    default:
      return "running"
    }
  }

  func configure(
    row: ChatListRow,
    appearance: ChatListAppearance,
    availableWidth: CGFloat
  ) -> CGFloat {
    let nodes = row.agentProgressNodes

    // Bridge/CLI agents (Claude, Codex) emit a flat sequence of enriched tool
    // nodes (each carries a `kind`). For those we render the FULL live feed —
    // Read/Edit/Write/Run rows building up as Claude works — like Claude Code.
    // The built-in Vibe AI agent emits a NESTED tree (depth > 0, no kind); we
    // keep its original minimalist behavior of showing only the last node.
    let isFlatToolFeed =
      !nodes.isEmpty
      && nodes.allSatisfy { $0.depth == 0 }
      && nodes.contains { ($0.kind?.isEmpty == false) }

    let displayNodes: [ChatListRow.AgentProgressNode]
    if isFlatToolFeed {
      let maxVisible = 6
      displayNodes = nodes.suffix(maxVisible).map { node in
        ChatListRow.AgentProgressNode(
          id: node.id,
          label: agentNodeDisplayLabel(node),
          status: normalizedNodeStatus(node.status),
          depth: 0,
          kind: node.kind,
          target: node.target,
          added: node.added,
          removed: node.removed
        )
      }
    } else if let lastNode = nodes.last {
      // Inline design: show only the deepest (last) running node as a single
      // flat row. Force depth=0 so there is no indentation or connector line.
      displayNodes = [
        ChatListRow.AgentProgressNode(
          id: lastNode.id, label: lastNode.label, status: lastNode.status, depth: 0)
      ]
    } else {
      displayNodes = []
    }

    while stepViews.count < displayNodes.count {
      let view = ChatNativeAgentProgressStepView()
      view.alpha = 0.0
      stepViews.append(view)
      cardView.addSubview(view)
    }
    while stepViews.count > displayNodes.count {
      stepViews.removeLast().removeFromSuperview()
    }

    cardView.backgroundColor = .clear
    cardView.layer.borderWidth = 0.0
    cardView.layer.borderColor = UIColor.clear.cgColor

    guard !displayNodes.isEmpty else {
      cachedCardFrame = .zero
      cachedStepFrames = []
      setNeedsLayout()
      return 0
    }

    let innerPaddingY: CGFloat = 2.0
    let innerWidth = max(1.0, availableWidth)
    var currentY = innerPaddingY
    var nextStepFrames: [CGRect] = []
    let nextNodeIds = displayNodes.map(\.id)

    for (index, node) in displayNodes.enumerated() {
      let stepHeight = stepViews[index].configure(
        node: node,
        appearance: appearance,
        availableWidth: innerWidth
      )
      nextStepFrames.append(CGRect(x: 0.0, y: currentY, width: innerWidth, height: stepHeight))
      currentY += stepHeight
    }

    cachedCardFrame = CGRect(x: 0.0, y: 0.0, width: innerWidth, height: currentY + innerPaddingY)
    cachedStepFrames = nextStepFrames
    setNeedsLayout()

    if nextNodeIds != lastNodeIds {
      for (index, stepView) in stepViews.enumerated() where index < nextNodeIds.count {
        if !lastNodeIds.contains(nextNodeIds[index]) {
          stepView.alpha = 0.0
          UIView.animate(withDuration: 0.24, delay: 0.03 * Double(index), options: [.curveEaseOut, .allowUserInteraction]) {
            stepView.alpha = 1.0
          }
        } else {
          stepView.alpha = 1.0
        }
      }
      lastNodeIds = nextNodeIds
    }

    return cachedCardFrame.maxY + 4.0
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    cardView.frame = cachedCardFrame
    for (index, stepView) in stepViews.enumerated() where index < cachedStepFrames.count {
      stepView.frame = cachedStepFrames[index]
    }
  }
}

final class ChatNativeAgentActionBarView: UIView {
  private let buttonSize: CGFloat = 28.0
  private let spacing: CGFloat = 2.0
  private let copyButton = UIButton(type: .system)
  private let thumbUpButton = UIButton(type: .system)
  private let thumbDownButton = UIButton(type: .system)
  private let regenerateButton = UIButton(type: .system)
  private lazy var orderedButtons: [UIButton] = [
    copyButton, thumbUpButton, thumbDownButton, regenerateButton,
  ]
  private var regenerateWidth: CGFloat = 28.0
  private var sourceMessageId: String = ""
  private var sourceText: String = ""
  private var regeneratePrompt: String = ""

  var onNativeEvent: (([String: Any]) -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    configureButton(copyButton, symbolName: "doc.on.doc", action: .copy)
    configureButton(thumbUpButton, symbolName: "hand.thumbsup", action: .thumbUp)
    configureButton(thumbDownButton, symbolName: "hand.thumbsdown", action: .thumbDown)
    configureButton(
      regenerateButton,
      symbolName: "arrow.trianglehead.2.counterclockwise",
      action: .regenerate
    )
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func configure(
    row: ChatListRow,
    appearance: ChatListAppearance,
    availableWidth: CGFloat
  ) -> CGFloat {
    sourceMessageId = row.agentActionSourceId ?? ""
    sourceText = row.agentActionSourceText ?? row.plainContent ?? row.text
    regeneratePrompt = row.agentRegeneratePrompt ?? ""

    let iconColor = appearance.timeColorThem.withAlphaComponent(0.55)

    [copyButton, thumbUpButton, thumbDownButton, regenerateButton].forEach { button in
      button.tintColor = iconColor
      button.backgroundColor = .clear
    }

    let hasSourceText = !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    copyButton.isHidden = !hasSourceText
    thumbUpButton.isHidden = !hasSourceText
    thumbDownButton.isHidden = !hasSourceText
    let hasRegeneratePrompt =
      !regeneratePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    regenerateButton.isHidden = !hasRegeneratePrompt

    let normalizedSourceText = sourceText.lowercased()
    let isRetryState =
      normalizedSourceText.contains("retry")
      || normalizedSourceText.contains("interrupted")
      || normalizedSourceText.contains("timed out")
      || normalizedSourceText.contains("connection lost")
      || normalizedSourceText.contains("went wrong")
    regenerateWidth = hasRegeneratePrompt && isRetryState ? 76.0 : buttonSize
    var regenerateConfiguration = UIButton.Configuration.plain()
    regenerateConfiguration.contentInsets = NSDirectionalEdgeInsets(
      top: 4.0,
      leading: isRetryState ? 9.0 : 4.0,
      bottom: 4.0,
      trailing: isRetryState ? 9.0 : 4.0
    )
    regenerateConfiguration.image = UIImage(
      systemName: "arrow.trianglehead.2.counterclockwise",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 14.0, weight: .regular)
    )
    if isRetryState {
      regenerateConfiguration.title = "Retry"
      regenerateConfiguration.imagePadding = 5.0
      regenerateConfiguration.background.backgroundColor = iconColor.withAlphaComponent(0.10)
      regenerateConfiguration.background.cornerRadius = buttonSize * 0.5
    }
    regenerateButton.configuration = regenerateConfiguration

    setNeedsLayout()
    return buttonSize + 4.0
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Frame-based layout (no UIStackView / Auto Layout) so the bar can collapse
    // to zero width inside pre-layout / headless transport cells without ever
    // emitting unsatisfiable-constraint warnings.
    var x: CGFloat = 8.0
    for button in orderedButtons where !button.isHidden {
      let width = (button === regenerateButton) ? regenerateWidth : buttonSize
      button.frame = CGRect(x: x, y: 0.0, width: width, height: buttonSize)
      x += width + spacing
    }
  }

  private func configureButton(
    _ button: UIButton,
    symbolName: String,
    action: ChatNativeAgentMessageAction
  ) {
    let config = UIImage.SymbolConfiguration(pointSize: 14.0, weight: .regular)
    var buttonConfiguration = UIButton.Configuration.plain()
    buttonConfiguration.contentInsets = NSDirectionalEdgeInsets(
      top: 4.0,
      leading: 4.0,
      bottom: 4.0,
      trailing: 4.0
    )
    buttonConfiguration.image = UIImage(systemName: symbolName, withConfiguration: config)
    button.configuration = buttonConfiguration
    button.frame.size = CGSize(width: buttonSize, height: buttonSize)
    button.accessibilityIdentifier = action.rawValue
    button.addTarget(self, action: #selector(handleButtonTap(_:)), for: .touchUpInside)
    addSubview(button)
  }

  @objc private func handleButtonTap(_ sender: UIButton) {
    guard let actionRaw = sender.accessibilityIdentifier,
      let action = ChatNativeAgentMessageAction(rawValue: actionRaw)
    else {
      return
    }

    onNativeEvent?([
      "type": "agentMessageAction",
      "action": action.rawValue,
      "sourceMessageId": sourceMessageId,
      "sourceText": sourceText,
      "regeneratePrompt": regeneratePrompt,
    ])
  }
}

private final class ChatNativeAgentCardView: UIControl {
  private let cardView = UIView()
  private let avatarView = UIView()
  private let avatarLabel = UILabel()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let statusLabel = UILabel()
  private let openLabel = UILabel()
  private let arrowView = UIImageView()
  private var cachedCardFrame: CGRect = .zero
  private var cachedAvatarFrame: CGRect = .zero
  private var cachedTitleFrame: CGRect = .zero
  private var cachedSubtitleFrame: CGRect = .zero
  private var cachedStatusFrame: CGRect = .zero
  private var cachedOpenFrame: CGRect = .zero
  private var cachedArrowFrame: CGRect = .zero
  private var currentCard: ChatListRow.AgentCard?
  var onNativeEvent: (([String: Any]) -> Void)?

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: 0.14) {
        self.cardView.alpha = self.isHighlighted ? 0.82 : 1.0
        self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.985, y: 0.985) : .identity
      }
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    cardView.layer.cornerCurve = .continuous
    cardView.layer.cornerRadius = 14.0
    cardView.isUserInteractionEnabled = false
    addSubview(cardView)

    avatarView.layer.cornerCurve = .continuous
    avatarView.layer.cornerRadius = 18.0
    cardView.addSubview(avatarView)

    avatarLabel.font = .systemFont(ofSize: 13.0, weight: .bold)
    avatarLabel.textAlignment = .center
    avatarView.addSubview(avatarLabel)

    titleLabel.font = .systemFont(ofSize: 15.0, weight: .semibold)
    titleLabel.numberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail
    cardView.addSubview(titleLabel)

    subtitleLabel.font = .systemFont(ofSize: 12.0, weight: .regular)
    subtitleLabel.numberOfLines = 1
    subtitleLabel.lineBreakMode = .byTruncatingTail
    cardView.addSubview(subtitleLabel)

    statusLabel.font = .systemFont(ofSize: 10.0, weight: .semibold)
    statusLabel.textAlignment = .center
    statusLabel.layer.cornerRadius = 8.0
    statusLabel.layer.cornerCurve = .continuous
    statusLabel.clipsToBounds = true
    cardView.addSubview(statusLabel)

    openLabel.text = "Open"
    openLabel.font = .systemFont(ofSize: 12.0, weight: .semibold)
    openLabel.textAlignment = .right
    cardView.addSubview(openLabel)

    arrowView.image = UIImage(
      systemName: "chevron.right",
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 11.0, weight: .semibold)
    )
    cardView.addSubview(arrowView)

    addTarget(self, action: #selector(handleTap), for: .touchUpInside)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  func configure(
    row: ChatListRow,
    appearance: ChatListAppearance,
    availableWidth: CGFloat
  ) -> CGFloat {
    guard let card = row.agentCard else {
      currentCard = nil
      cachedCardFrame = .zero
      return 0.0
    }
    currentCard = card

    let outerLeft: CGFloat = 6.0
    let outerRight: CGFloat = 26.0
    let cardWidth = max(1.0, availableWidth - outerLeft - outerRight)
    let cardHeight: CGFloat = 68.0
    let leftPadding: CGFloat = 12.0
    let rightPadding: CGFloat = 12.0
    let arrowSize = CGSize(width: 12.0, height: 12.0)

    cardView.backgroundColor = appearance.bubbleThemColor.withAlphaComponent(0.26)
    cardView.layer.borderWidth = 0.5
    cardView.layer.borderColor = appearance.dayBorderColor.withAlphaComponent(0.28).cgColor

    avatarView.backgroundColor = appearance.textColorThem.withAlphaComponent(0.10)
    avatarLabel.text = String(
      card.displayName
        .split(separator: " ")
        .prefix(2)
        .compactMap { $0.first }
    ).uppercased()
    avatarLabel.textColor = appearance.textColorThem
    titleLabel.text = card.displayName
    titleLabel.textColor = appearance.textColorThem
    subtitleLabel.text = card.username.map { "@\($0)" } ?? "Agent"
    subtitleLabel.textColor = appearance.timeColorThem.withAlphaComponent(0.78)
    statusLabel.text = "  \(card.status.capitalized)  "
    statusLabel.textColor = appearance.textColorThem.withAlphaComponent(0.82)
    statusLabel.backgroundColor = appearance.textColorThem.withAlphaComponent(0.08)
    openLabel.textColor = appearance.textColorThem.withAlphaComponent(0.72)

    arrowView.tintColor = appearance.timeColorThem.withAlphaComponent(0.45)

    cachedAvatarFrame = CGRect(x: leftPadding, y: 16.0, width: 36.0, height: 36.0)
    let arrowX = cardWidth - rightPadding - arrowSize.width
    let arrowY = (cardHeight - arrowSize.height) * 0.5
    cachedArrowFrame = CGRect(x: arrowX, y: arrowY, width: arrowSize.width, height: arrowSize.height)

    let openWidth: CGFloat = 34.0
    cachedOpenFrame = CGRect(
      x: arrowX - openWidth - 5.0,
      y: 25.0,
      width: openWidth,
      height: 18.0
    )
    let textX = cachedAvatarFrame.maxX + 10.0
    let textRight = cachedOpenFrame.minX - 10.0
    let textWidth = max(1.0, textRight - textX)
    let titleHeight: CGFloat = 18.0
    cachedTitleFrame = CGRect(x: textX, y: 13.0, width: textWidth, height: titleHeight)
    let statusWidth = min(58.0, max(42.0, statusLabel.intrinsicContentSize.width))
    cachedStatusFrame = CGRect(
      x: textRight - statusWidth,
      y: 38.0,
      width: statusWidth,
      height: 16.0
    )
    cachedSubtitleFrame = CGRect(
      x: textX,
      y: 36.0,
      width: max(1.0, cachedStatusFrame.minX - textX - 6.0),
      height: 18.0
    )

    cachedCardFrame = CGRect(x: outerLeft, y: 2.0, width: cardWidth, height: cardHeight)

    setNeedsLayout()
    return cachedCardFrame.maxY + 6.0
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    cardView.frame = cachedCardFrame
    avatarView.frame = cachedAvatarFrame
    avatarLabel.frame = avatarView.bounds
    titleLabel.frame = cachedTitleFrame
    subtitleLabel.frame = cachedSubtitleFrame
    statusLabel.frame = cachedStatusFrame
    openLabel.frame = cachedOpenFrame
    arrowView.frame = cachedArrowFrame
  }

  @objc private func handleTap() {
    guard let currentCard else { return }
    onNativeEvent?([
      "type": "agentCardPressed",
      "card": currentCard.rawValue,
    ])
  }
}

private final class ChatNativeAgentRowHostView: UIView {
  private let legacyCell = ChatListCell(frame: .zero)
  private let assistantView = ChatNativeAgentPlainTextView()
  private let assistantProgressTreeView = ChatNativeAgentProgressTreeView()
  private let assistantActionsView = ChatNativeAgentActionBarView()
  private let assistantAgentCardView = ChatNativeAgentCardView()
  private var currentPresentationKind: ChatNativeAgentRowPresentationKind?
  private var cachedSubviewFrame: CGRect = .zero
  private var currentRowText: String = ""
  private var currentSourceMessageId: String = ""
  private var currentAppearance = ChatListAppearance.current
  private let longPressGesture = UILongPressGestureRecognizer()

  var onNativeEvent: (([String: Any]) -> Void)? {
    didSet {
      assistantActionsView.onNativeEvent = onNativeEvent
      assistantAgentCardView.onNativeEvent = onNativeEvent
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    legacyCell.isUserInteractionEnabled = false
    assistantView.isUserInteractionEnabled = true
    assistantProgressTreeView.isUserInteractionEnabled = false
    assistantActionsView.isUserInteractionEnabled = true
    assistantAgentCardView.isUserInteractionEnabled = true
    addSubview(legacyCell)
    addSubview(assistantView)
    addSubview(assistantProgressTreeView)
    addSubview(assistantActionsView)
    addSubview(assistantAgentCardView)

    longPressGesture.minimumPressDuration = 0.5
    longPressGesture.addTarget(self, action: #selector(handleLongPress(_:)))
    addGestureRecognizer(longPressGesture)
  }

  required init?(coder: NSCoder) {
    return nil
  }

  @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
    guard gesture.state == .began else { return }
    guard currentPresentationKind == .legacy else { return }
    let trimmedText = currentRowText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else { return }

    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    showUserBubbleMenu(text: trimmedText)
  }

  private func showUserBubbleMenu(text: String) {
    guard let window = window else { return }
    let sourceFrame = legacyCell.convert(legacyCell.bounds, to: window)
    let overlay = ChatNativeAgentUserMenuOverlay(
      sourceFrame: sourceFrame,
      text: text,
      messageId: currentSourceMessageId,
      appearance: currentAppearance,
      onAction: { [weak self] action in
        guard let self else { return }
        self.onNativeEvent?([
          "type": "agentMessageAction",
          "action": action,
          "sourceMessageId": self.currentSourceMessageId,
          "sourceText": text,
        ])
      }
    )
    overlay.frame = window.bounds
    window.addSubview(overlay)
    overlay.animateIn()
  }

  func configure(
    row: ChatListRow,
    appearance: ChatListAppearance,
    availableWidth: CGFloat
  ) -> CGFloat {
    currentAppearance = appearance
    let nextKind: ChatNativeAgentRowPresentationKind = {
      if row.kind == .message && row.isAgentMessage {
        switch row.messageType {
        case "agent_progress_tree":
          return .assistantProgressTree
        case "agent_actions":
          return .assistantActions
        case "agent_card":
          return .assistantAgentCard
        default:
          return .assistant
        }
      }
      return .legacy
    }()
    currentPresentationKind = nextKind
    legacyCell.isHidden = nextKind != .legacy
    assistantView.isHidden = nextKind != .assistant
    assistantProgressTreeView.isHidden = nextKind != .assistantProgressTree
    assistantActionsView.isHidden = nextKind != .assistantActions
    assistantAgentCardView.isHidden = nextKind != .assistantAgentCard

    // Track text for long-press copy — only on user ("me") messages
    longPressGesture.isEnabled = nextKind == .legacy
    if nextKind == .legacy {
      currentRowText = row.plainContent ?? row.text
      currentSourceMessageId = row.agentActionSourceId ?? row.messageId ?? row.key
    } else if nextKind == .assistant {
      currentRowText = row.plainContent ?? row.text
      currentSourceMessageId = row.agentActionSourceId ?? row.messageId ?? row.key
    } else {
      currentRowText = ""
      currentSourceMessageId = ""
    }

    switch nextKind {
    case .legacy:
      let cellWidth = max(1.0, availableWidth - (messageHorizontalInset * 2.0))
      let height: CGFloat
      if row.kind == .day {
        height = 30.0
      } else {
        height = measureMessageBubbleLayout(row: row, rowWidth: cellWidth).bubbleHeight
      }
      legacyCell.applyAppearance(appearance)
      legacyCell.configure(row: row, hiddenMessageId: nil)
      cachedSubviewFrame = CGRect(
        x: messageHorizontalInset,
        y: 0.0,
        width: cellWidth,
        height: height
      )
      setNeedsLayout()
      return height

    case .assistant:
      let height = assistantView.configure(
        row: row,
        appearance: appearance,
        availableWidth: availableWidth
      )
      cachedSubviewFrame = CGRect(x: 0.0, y: 0.0, width: availableWidth, height: height)
      setNeedsLayout()
      return height

    case .assistantActions:
      let height = assistantActionsView.configure(
        row: row,
        appearance: appearance,
        availableWidth: availableWidth
      )
      cachedSubviewFrame = CGRect(x: 0.0, y: 0.0, width: availableWidth, height: height)
      setNeedsLayout()
      return height

    case .assistantProgressTree:
      let height = assistantProgressTreeView.configure(
        row: row,
        appearance: appearance,
        availableWidth: availableWidth
      )
      cachedSubviewFrame = CGRect(x: 0.0, y: 0.0, width: availableWidth, height: height)
      setNeedsLayout()
      return height

    case .assistantAgentCard:
      let height = assistantAgentCardView.configure(
        row: row,
        appearance: appearance,
        availableWidth: availableWidth
      )
      cachedSubviewFrame = CGRect(x: 0.0, y: 0.0, width: availableWidth, height: height)
      setNeedsLayout()
      return height
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    switch currentPresentationKind {
    case .legacy:
      legacyCell.frame = cachedSubviewFrame
    case .assistant:
      assistantView.frame = cachedSubviewFrame
    case .assistantActions:
      assistantActionsView.frame = cachedSubviewFrame
    case .assistantAgentCard:
      assistantAgentCardView.frame = cachedSubviewFrame
    case .assistantProgressTree:
      assistantProgressTreeView.frame = cachedSubviewFrame
    case .none:
      break
    }
  }
}

final class ChatNativeAgentMessagesView: UIView {
  private let scrollView = UIScrollView()
  private let contentView = UIView()
  private let stackView = UIStackView()
  private let topPaddingView = UIView()
  private let spacerView = UIView()
  private let mainRowsStack = UIStackView()
  private let progressRowsStack = UIStackView()
  private let footerRowsStack = UIStackView()
  private let bottomPaddingView = UIView()
  private var topPaddingConstraint: NSLayoutConstraint!
  private var spacerConstraint: NSLayoutConstraint!
  private var bottomPaddingConstraint: NSLayoutConstraint!

  private var currentMainRows: [ChatListRow] = []
  private var currentProgressRows: [ChatListRow] = []
  private var currentFooterRows: [ChatListRow] = []
  private var mainRowHosts: [ChatNativeAgentRowHostView] = []
  private var progressRowHosts: [ChatNativeAgentRowHostView] = []
  private var footerRowHosts: [ChatNativeAgentRowHostView] = []
  private var mainRowKeys: [String] = []
  private var mainRowKinds: [String] = []
  private var progressRowKeys: [String] = []
  private var progressRowKinds: [String] = []
  private var footerRowKeys: [String] = []
  private var footerRowKinds: [String] = []
  private var appearance = ChatListAppearance.current
  private var lastKnownWidth: CGFloat = 0.0
  private var keyboardHeight: CGFloat = 0.0
  private var pendingStreamingTextLayoutInvalidation = false

  private let contentHorizontalInset: CGFloat = 10.0
  private let bottomStickThreshold: CGFloat = 56.0

  var onTap: (() -> Void)?
  var onNativeEvent: (([String: Any]) -> Void)? {
    didSet {
      syncHostEventHandlers()
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.backgroundColor = .clear
    scrollView.keyboardDismissMode = .interactive
    scrollView.showsVerticalScrollIndicator = false
    scrollView.alwaysBounceVertical = true
    if #available(iOS 11.0, *) {
      scrollView.contentInsetAdjustmentBehavior = .never
    }
    addSubview(scrollView)

    contentView.translatesAutoresizingMaskIntoConstraints = false
    contentView.backgroundColor = .clear
    scrollView.addSubview(contentView)

    stackView.translatesAutoresizingMaskIntoConstraints = false
    stackView.axis = .vertical
    stackView.alignment = .fill
    stackView.distribution = .fill
    stackView.spacing = 2.0
    contentView.addSubview(stackView)

    topPaddingView.translatesAutoresizingMaskIntoConstraints = false
    spacerView.translatesAutoresizingMaskIntoConstraints = false
    bottomPaddingView.translatesAutoresizingMaskIntoConstraints = false
    topPaddingView.backgroundColor = .clear
    spacerView.backgroundColor = .clear
    bottomPaddingView.backgroundColor = .clear
    mainRowsStack.axis = .vertical
    mainRowsStack.alignment = .fill
    mainRowsStack.distribution = .fill
    mainRowsStack.spacing = 2.0
    mainRowsStack.backgroundColor = .clear
    progressRowsStack.axis = .vertical
    progressRowsStack.alignment = .fill
    progressRowsStack.distribution = .fill
    progressRowsStack.spacing = 2.0
    progressRowsStack.backgroundColor = .clear
    footerRowsStack.axis = .vertical
    footerRowsStack.alignment = .fill
    footerRowsStack.distribution = .fill
    footerRowsStack.spacing = 2.0
    footerRowsStack.backgroundColor = .clear

    stackView.addArrangedSubview(topPaddingView)
    stackView.addArrangedSubview(spacerView)
    stackView.addArrangedSubview(mainRowsStack)
    stackView.addArrangedSubview(progressRowsStack)
    stackView.addArrangedSubview(footerRowsStack)
    stackView.addArrangedSubview(bottomPaddingView)

    topPaddingConstraint = topPaddingView.heightAnchor.constraint(equalToConstant: 0.0)
    spacerConstraint = spacerView.heightAnchor.constraint(equalToConstant: 0.0)
    bottomPaddingConstraint = bottomPaddingView.heightAnchor.constraint(equalToConstant: 0.0)

    NSLayoutConstraint.activate([
      scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
      scrollView.topAnchor.constraint(equalTo: topAnchor),
      scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

      contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

      stackView.leadingAnchor.constraint(
        equalTo: contentView.leadingAnchor, constant: contentHorizontalInset),
      stackView.trailingAnchor.constraint(
        equalTo: contentView.trailingAnchor, constant: -contentHorizontalInset),
      stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
      stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

      topPaddingConstraint,
      spacerConstraint,
      bottomPaddingConstraint,
    ])

    let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
    tapGesture.cancelsTouchesInView = false
    scrollView.addGestureRecognizer(tapGesture)

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(keyboardWillChangeFrame(_:)),
      name: UIResponder.keyboardWillChangeFrameNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(keyboardWillHide(_:)),
      name: UIResponder.keyboardWillHideNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleStreamingTextLayoutInvalidated(_:)),
      name: .chatNativeStreamingTextLayoutInvalidated,
      object: nil
    )
  }

  required init?(coder: NSCoder) {
    return nil
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let width = bounds.width
    guard abs(width - lastKnownWidth) > 0.5 else { return }
    lastKnownWidth = width
    reconfigureVisibleRows()
  }

  func applyAppearance(_ appearance: ChatListAppearance) {
    self.appearance = appearance
    reconfigureVisibleRows()
  }

  func setRows(
    _ rawRows: [[String: Any]],
    topPadding: CGFloat,
    spacerHeight: CGFloat,
    bottomPadding: CGFloat,
    scrollToBottom shouldScrollToBottom: Bool,
    animated: Bool
  ) {
    let parsedRows = rawRows.compactMap(ChatListRow.init)
    let partitioned = Self.partitionRows(parsedRows)
    let preservedOffsetY = scrollView.contentOffset.y
    let distanceBeforeUpdate = currentDistanceFromBottom()

    let assignConstraints = {
      self.topPaddingConstraint.constant = topPadding
      self.spacerConstraint.constant = spacerHeight
      self.bottomPaddingConstraint.constant = bottomPadding
    }

    if animated {
      UIView.animate(
        withDuration: 0.35, delay: 0.0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.0,
        options: [.allowUserInteraction, .beginFromCurrentState]
      ) {
        assignConstraints()
        self.layoutIfNeeded()
      }
    } else {
      assignConstraints()
    }

    let nextMainKeys = partitioned.main.map(\.key)
    let nextMainKinds = partitioned.main.map(Self.presentationSignature(for:))
    if nextMainKeys != mainRowKeys || nextMainKinds != mainRowKinds {
      rebuildRows(partitioned.main, in: mainRowsStack, hosts: &mainRowHosts)
      mainRowKeys = nextMainKeys
      mainRowKinds = nextMainKinds
    } else {
      currentMainRows = partitioned.main
      reconfigureRows(currentMainRows, hosts: mainRowHosts)
    }

    let nextProgressKeys = partitioned.progress.map(\.key)
    let nextProgressKinds = partitioned.progress.map(Self.presentationSignature(for:))
    if nextProgressKeys != progressRowKeys || nextProgressKinds != progressRowKinds {
      rebuildRows(partitioned.progress, in: progressRowsStack, hosts: &progressRowHosts)
      progressRowKeys = nextProgressKeys
      progressRowKinds = nextProgressKinds
    } else {
      currentProgressRows = partitioned.progress
      reconfigureRows(currentProgressRows, hosts: progressRowHosts)
    }

    let nextFooterKeys = partitioned.footer.map(\.key)
    let nextFooterKinds = partitioned.footer.map(Self.presentationSignature(for:))
    if nextFooterKeys != footerRowKeys || nextFooterKinds != footerRowKinds {
      rebuildRows(partitioned.footer, in: footerRowsStack, hosts: &footerRowHosts)
      footerRowKeys = nextFooterKeys
      footerRowKinds = nextFooterKinds
    } else {
      currentFooterRows = partitioned.footer
      reconfigureRows(currentFooterRows, hosts: footerRowHosts)
    }

    layoutIfNeeded()

    if shouldScrollToBottom || distanceBeforeUpdate <= bottomStickThreshold {
      self.scrollToBottom(animated: animated)
      return
    }

    let minOffset = -scrollView.adjustedContentInset.top
    let maxOffset = max(
      minOffset,
      scrollView.contentSize.height - scrollView.bounds.height
        + scrollView.adjustedContentInset.bottom
    )
    let clampedOffset = max(minOffset, min(maxOffset, preservedOffsetY))
    scrollView.setContentOffset(CGPoint(x: 0.0, y: clampedOffset), animated: false)
  }

  func scrollToBottom(animated: Bool) {
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.layoutIfNeeded()
      let minOffset = -self.scrollView.adjustedContentInset.top
      let targetY = max(
        minOffset,
        self.scrollView.contentSize.height - self.scrollView.bounds.height
          + self.scrollView.adjustedContentInset.bottom
      )
      self.scrollView.setContentOffset(CGPoint(x: 0.0, y: targetY), animated: animated)
    }
  }

  private func rebuildRows(
    _ rows: [ChatListRow],
    in hostStack: UIStackView,
    hosts: inout [ChatNativeAgentRowHostView]
  ) {
    for host in hosts {
      hostStack.removeArrangedSubview(host)
      host.removeFromSuperview()
    }
    hosts.removeAll()

    for (offset, _) in rows.enumerated() {
      let host = ChatNativeAgentRowHostView()
      host.onNativeEvent = onNativeEvent
      hosts.append(host)
      hostStack.insertArrangedSubview(host, at: offset)
    }
    if hostStack === mainRowsStack {
      currentMainRows = rows
      reconfigureRows(currentMainRows, hosts: hosts)
    } else if hostStack === progressRowsStack {
      currentProgressRows = rows
      reconfigureRows(currentProgressRows, hosts: hosts)
    } else {
      currentFooterRows = rows
      reconfigureRows(currentFooterRows, hosts: hosts)
    }
  }

  private func reconfigureVisibleRows() {
    syncHostEventHandlers()
    reconfigureRows(currentMainRows, hosts: mainRowHosts)
    reconfigureRows(currentProgressRows, hosts: progressRowHosts)
    reconfigureRows(currentFooterRows, hosts: footerRowHosts)
  }

  private func reconfigureRows(_ rows: [ChatListRow], hosts: [ChatNativeAgentRowHostView]) {
    guard hosts.count == rows.count else { return }
    let width = max(1.0, bounds.width - (contentHorizontalInset * 2.0))
    for (index, row) in rows.enumerated() {
      let host = hosts[index]
      host.onNativeEvent = onNativeEvent
      let height = host.configure(row: row, appearance: appearance, availableWidth: width)
      if let heightConstraint = host.constraints.first(where: {
        $0.firstAttribute == .height && $0.relation == .equal
      }) {
        heightConstraint.constant = height
      } else {
        host.heightAnchor.constraint(equalToConstant: height).isActive = true
      }
    }
  }

  private static func presentationSignature(for row: ChatListRow) -> String {
    if row.kind == .message && row.isAgentMessage {
      switch row.messageType {
      case "agent_progress_tree":
        return ChatNativeAgentRowPresentationKind.assistantProgressTree.rawValue
      case "agent_actions":
        return ChatNativeAgentRowPresentationKind.assistantActions.rawValue
      case "agent_card":
        return ChatNativeAgentRowPresentationKind.assistantAgentCard.rawValue
      default:
        return ChatNativeAgentRowPresentationKind.assistant.rawValue
      }
    }
    return ChatNativeAgentRowPresentationKind.legacy.rawValue
  }

  private static func partitionRows(_ rows: [ChatListRow]) -> (
    main: [ChatListRow], progress: [ChatListRow], footer: [ChatListRow]
  ) {
    // Progress rows are now inline with the response stream — no separate partition
    return (rows, [], [])
  }

  @objc private func handleTap() {
    onTap?()
  }

  @objc private func handleStreamingTextLayoutInvalidated(_ notification: Notification) {
    guard
      let sourceView = notification.object as? UIView,
      sourceView.isDescendant(of: self)
    else {
      return
    }
    guard !pendingStreamingTextLayoutInvalidation else { return }

    pendingStreamingTextLayoutInvalidation = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.pendingStreamingTextLayoutInvalidation = false
      guard self.window != nil else { return }

      let distanceFromBottom = self.currentDistanceFromBottom()
      let wasNearBottom = distanceFromBottom <= self.bottomStickThreshold

      self.reconfigureVisibleRows()
      UIView.animate(
        withDuration: 0.24,
        delay: 0.0,
        options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseOut]
      ) {
        self.layoutIfNeeded()
      } completion: { [weak self] _ in
        guard let self else { return }
        if wasNearBottom {
          self.scrollToBottom(animated: false)
        } else {
          self.restoreStationaryDistance(distanceFromBottom)
        }
      }
    }
  }

  @objc private func keyboardWillChangeFrame(_ notification: Notification) {
    applyKeyboardFrame(notification, hidden: false)
  }

  @objc private func keyboardWillHide(_ notification: Notification) {
    applyKeyboardFrame(notification, hidden: true)
  }

  private func applyKeyboardFrame(_ notification: Notification, hidden: Bool) {
    guard let info = notification.userInfo else { return }
    let duration =
      (info[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
    let curveRaw =
      (info[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
    let options = UIView.AnimationOptions(rawValue: curveRaw << 16)
    let distanceBeforeInsetChange = currentDistanceFromBottom()
    let nextKeyboardHeight: CGFloat

    if hidden {
      nextKeyboardHeight = 0.0
    } else if let endFrame = info[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
      let endFrameInView = convert(endFrame, from: nil)
      let intersection = bounds.intersection(endFrameInView)
      nextKeyboardHeight = max(0.0, intersection.height)
    } else {
      nextKeyboardHeight = 0.0
    }

    keyboardHeight = nextKeyboardHeight

    UIView.animate(withDuration: duration, delay: 0.0, options: options) { [weak self] in
      guard let self else { return }
      self.applyKeyboardInsets()
      self.layoutIfNeeded()
      if distanceBeforeInsetChange <= self.bottomStickThreshold {
        self.scrollToBottom(animated: false)
      } else {
        self.restoreStationaryDistance(distanceBeforeInsetChange)
      }
    }
  }

  private func applyKeyboardInsets() {
    scrollView.contentInset.bottom = keyboardHeight
    scrollView.verticalScrollIndicatorInsets.bottom = keyboardHeight
  }

  private func currentDistanceFromBottom() -> CGFloat {
    let minOffset = -scrollView.adjustedContentInset.top
    let targetY = max(
      minOffset,
      scrollView.contentSize.height - scrollView.bounds.height
        + scrollView.adjustedContentInset.bottom
    )
    return max(0.0, targetY - scrollView.contentOffset.y)
  }

  private func restoreStationaryDistance(_ distanceFromBottom: CGFloat) {
    let minOffset = -scrollView.adjustedContentInset.top
    let maxOffset = max(
      minOffset,
      scrollView.contentSize.height - scrollView.bounds.height
        + scrollView.adjustedContentInset.bottom
    )
    let targetY = max(minOffset, min(maxOffset, maxOffset - distanceFromBottom))
    scrollView.setContentOffset(CGPoint(x: 0.0, y: targetY), animated: false)
  }

  private func syncHostEventHandlers() {
    let groups = [mainRowHosts, progressRowHosts, footerRowHosts]
    for hosts in groups {
      for host in hosts {
        host.onNativeEvent = onNativeEvent
      }
    }
  }
}
