import UIKit

/// One-time, per-provider disclosure before any media leaves the device for an
/// AI model.
///
/// This exists because AI editing is the one place in the app where a user's
/// media deliberately steps outside the encryption envelope. The sheet says that
/// plainly rather than burying it — it is shown once per provider, and after
/// that the editors carry a permanent visible badge instead.
enum ChatAIMediaConsent {

  enum Provider {
    case openAI
    case google

    var displayName: String {
      switch self {
      case .openAI: return "OpenAI"
      case .google: return "Google"
      }
    }

    fileprivate var defaultsKey: String {
      switch self {
      case .openAI: return "vibe.ai.media.consent.openai"
      case .google: return "vibe.ai.media.consent.google"
      }
    }

    /// Shown on the badge that stays visible in the editor afterwards.
    var badgeText: String {
      "Sent to \(displayName)"
    }

    fileprivate var mediaNoun: String {
      switch self {
      case .openAI: return "photo"
      case .google: return "video clip"
      }
    }

    fileprivate var points: [(String, String)] {
      switch self {
      case .openAI:
        return [
          ("lock.open", "This photo leaves your device unencrypted. This one step is not end-to-end encrypted."),
          ("person.crop.circle.badge.xmark", "OpenAI processes it on their servers to make the edit."),
          ("clock.arrow.circlepath", "The original in your chat is untouched — only the copy you send here is used."),
        ]
      case .google:
        return [
          ("lock.open", "This clip leaves your device unencrypted. This one step is not end-to-end encrypted."),
          ("person.crop.circle.badge.xmark", "Google processes it on their servers to make the edit."),
          ("water.waves", "Edited video carries an invisible SynthID watermark identifying it as AI-generated."),
        ]
      }
    }
  }

  static func hasConsented(to provider: Provider) -> Bool {
    UserDefaults.standard.bool(forKey: provider.defaultsKey)
  }

  /// Presents the disclosure if it has not been accepted yet, then calls
  /// `completion(true)` if the user agreed (or had already agreed).
  static func ensureConsent(
    for provider: Provider,
    from presenter: UIViewController,
    completion: @escaping (Bool) -> Void
  ) {
    guard !hasConsented(to: provider) else {
      completion(true)
      return
    }

    let sheet = ConsentSheetViewController(provider: provider) { accepted in
      if accepted {
        UserDefaults.standard.set(true, forKey: provider.defaultsKey)
      }
      completion(accepted)
    }
    sheet.modalPresentationStyle = .overFullScreen
    // The sheet animates its own blur and card in `viewDidAppear`; a modal
    // transition on top of that would just play the same fade twice.
    presenter.present(sheet, animated: false)
  }

  /// Clears consent — used by the Settings row so the decision is reversible.
  static func revokeAll() {
    for key in [Provider.openAI.defaultsKey, Provider.google.defaultsKey] {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }
}

// MARK: - Sheet

private final class ConsentSheetViewController: UIViewController {

  private let provider: ChatAIMediaConsent.Provider
  private let completion: (Bool) -> Void

  /// Real blur over whatever is behind, not a flat black wash — the editor stays
  /// legible underneath so the sheet reads as a layer, not a new screen.
  private let backdrop = UIVisualEffectView(effect: nil)
  private let card = UIView()

  private static let cardRadius: CGFloat = 30.0
  private static let cardWidth: CGFloat = 360.0
  private static let buttonHeight: CGFloat = 50.0
  private static let buttonRadius: CGFloat = 15.0

  init(provider: ChatAIMediaConsent.Provider, completion: @escaping (Bool) -> Void) {
    self.provider = provider
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    overrideUserInterfaceStyle = .dark

    backdrop.frame = view.bounds
    backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(backdrop)

    let tapOut = UITapGestureRecognizer(target: self, action: #selector(handleCancel))
    backdrop.contentView.addGestureRecognizer(tapOut)

    card.backgroundColor = UIColor(white: 0.10, alpha: 0.98)
    card.layer.cornerRadius = Self.cardRadius
    card.layer.cornerCurve = .continuous
    card.layer.borderWidth = 1.0 / UIScreen.main.scale
    card.layer.borderColor = UIColor(white: 1.0, alpha: 0.12).cgColor
    card.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(card)

    let stack = UIStackView()
    stack.axis = .vertical
    stack.spacing = 14.0
    stack.alignment = .fill
    stack.translatesAutoresizingMaskIntoConstraints = false
    card.addSubview(stack)

    stack.addArrangedSubview(makeBadge())

    let title = UILabel()
    title.text = "Edit this \(provider.mediaNoun) with AI"
    title.font = .systemFont(ofSize: 20.0, weight: .semibold)
    title.textColor = .white
    title.numberOfLines = 0
    stack.addArrangedSubview(title)

    let points = UIStackView()
    points.axis = .vertical
    points.spacing = 12.0
    for (symbol, text) in provider.points {
      points.addArrangedSubview(makePoint(symbol: symbol, text: text))
    }
    stack.addArrangedSubview(points)

    let footnote = UILabel()
    footnote.text = "You'll only be asked once for \(provider.displayName)."
    footnote.font = .systemFont(ofSize: 12.0)
    footnote.textColor = UIColor(white: 1.0, alpha: 0.4)
    footnote.numberOfLines = 0
    stack.addArrangedSubview(footnote)

    let buttons = UIStackView()
    buttons.axis = .horizontal
    buttons.spacing = 10.0
    buttons.distribution = .fillEqually

    let cancel = makeButton(title: "Not now", filled: false)
    cancel.addTarget(self, action: #selector(handleCancel), for: .touchUpInside)
    let accept = makeButton(title: "Continue", filled: true)
    accept.addTarget(self, action: #selector(handleAccept), for: .touchUpInside)
    buttons.addArrangedSubview(cancel)
    buttons.addArrangedSubview(accept)
    stack.addArrangedSubview(buttons)

    stack.setCustomSpacing(16.0, after: title)
    stack.setCustomSpacing(16.0, after: points)
    stack.setCustomSpacing(20.0, after: footnote)

    NSLayoutConstraint.activate([
      card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      // Pinning the width keeps the card from hugging its text into an
      // off-balance column on one provider and a wide slab on the other.
      card.widthAnchor.constraint(equalToConstant: Self.cardWidth),
      card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20.0),

      stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24.0),
      stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20.0),
      stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20.0),
      stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20.0),

      buttons.heightAnchor.constraint(equalToConstant: Self.buttonHeight),
    ])

    card.transform = CGAffineTransform(translationX: 0.0, y: 14.0).scaledBy(x: 0.96, y: 0.96)
    card.alpha = 0.0
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    UIView.animate(
      withDuration: 0.34, delay: 0.0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.0,
      options: [.curveEaseOut]
    ) {
      self.backdrop.effect = UIBlurEffect(style: .systemThinMaterialDark)
      self.card.transform = .identity
      self.card.alpha = 1.0
    }
  }

  /// Fixed-size tinted badge rather than a bare glyph — inside a vertical stack a
  /// plain image view stretches full width and floats away from the title.
  private func makeBadge() -> UIView {
    let container = UIView()
    let badge = UIView()
    badge.backgroundColor = UIColor(white: 1.0, alpha: 0.1)
    badge.layer.cornerRadius = 14.0
    badge.layer.cornerCurve = .continuous
    badge.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(badge)

    let icon = UIImageView(
      image: UIImage(systemName: "sparkles")?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 22.0, weight: .medium)))
    icon.tintColor = .white
    icon.contentMode = .center
    icon.translatesAutoresizingMaskIntoConstraints = false
    badge.addSubview(icon)

    NSLayoutConstraint.activate([
      badge.widthAnchor.constraint(equalToConstant: 48.0),
      badge.heightAnchor.constraint(equalToConstant: 48.0),
      badge.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      badge.topAnchor.constraint(equalTo: container.topAnchor),
      badge.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
      icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
    ])
    return container
  }

  private func makePoint(symbol: String, text: String) -> UIView {
    let row = UIStackView()
    row.axis = .horizontal
    row.spacing = 12.0
    row.alignment = .top

    let icon = UIImageView(
      image: UIImage(systemName: symbol)?.withConfiguration(
        UIImage.SymbolConfiguration(pointSize: 14.0, weight: .medium)))
    icon.tintColor = UIColor(white: 1.0, alpha: 0.55)
    icon.contentMode = .center
    icon.setContentHuggingPriority(.required, for: .horizontal)
    icon.setContentCompressionResistancePriority(.required, for: .horizontal)
    icon.widthAnchor.constraint(equalToConstant: 20.0).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 21.0).isActive = true

    let label = UILabel()
    label.text = text
    label.font = .systemFont(ofSize: 14.0)
    label.textColor = UIColor(white: 1.0, alpha: 0.78)
    label.numberOfLines = 0

    row.addArrangedSubview(icon)
    row.addArrangedSubview(label)
    return row
  }

  private func makeButton(title: String, filled: Bool) -> UIButton {
    let button = UIButton(type: .custom)
    button.setTitle(title, for: .normal)
    button.titleLabel?.font = .systemFont(ofSize: 16.0, weight: .semibold)
    button.setTitleColor(filled ? .black : UIColor(white: 1.0, alpha: 0.92), for: .normal)
    button.backgroundColor = filled ? .white : UIColor(white: 1.0, alpha: 0.1)
    button.layer.cornerRadius = Self.buttonRadius
    button.layer.cornerCurve = .continuous
    button.adjustsImageWhenHighlighted = false
    return button
  }

  @objc private func handleCancel() { finish(accepted: false) }
  @objc private func handleAccept() { finish(accepted: true) }

  private func finish(accepted: Bool) {
    // Held outside the animation closures so the callback survives the sheet
    // being torn down before the completion runs.
    let callback = completion
    UIView.animate(
      withDuration: 0.2, delay: 0.0, options: [.curveEaseIn],
      animations: {
        self.backdrop.effect = nil
        self.card.alpha = 0.0
        self.card.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
      },
      completion: { _ in
        self.dismiss(animated: false) { callback(accepted) }
      })
  }
}
