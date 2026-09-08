import UIKit

/// Compact prompt capsule for AI video editing.
///
/// Deliberately a capsule that rides just above the tool row rather than a
/// full-width banner — switching the AI tool on must not restructure the screen.
/// There is no region control here: the video model takes prompts only.
final class ChatVideoAIPromptBar: UIView {

  var onSubmit: ((String) -> Void)?
  var onUndo: (() -> Void)?

  private let blurView = UIVisualEffectView(
    effect: UIBlurEffect(style: .systemChromeMaterialDark))
  private let textField = UITextField()
  private let sendButton = UIButton(type: .custom)
  private let spinner = UIActivityIndicatorView(style: .medium)
  private let undoButton = UIButton(type: .custom)
  private let hintLabel = UILabel()

  private(set) var isWorking = false

  override init(frame: CGRect) {
    super.init(frame: frame)

    blurView.clipsToBounds = true
    blurView.layer.cornerCurve = .continuous
    addSubview(blurView)

    textField.placeholder = "Describe the edit…"
    textField.font = .systemFont(ofSize: 15.0)
    textField.textColor = .white
    textField.tintColor = .white
    textField.keyboardAppearance = .dark
    textField.returnKeyType = .go
    textField.attributedPlaceholder = NSAttributedString(
      string: "Describe the edit…",
      attributes: [.foregroundColor: UIColor(white: 1.0, alpha: 0.45)])
    textField.addTarget(self, action: #selector(handleReturn), for: .editingDidEndOnExit)
    textField.addTarget(self, action: #selector(handleTextChanged), for: .editingChanged)
    blurView.contentView.addSubview(textField)

    let config = UIImage.SymbolConfiguration(pointSize: 14.0, weight: .bold)
    sendButton.setImage(UIImage(systemName: "arrow.up", withConfiguration: config), for: .normal)
    sendButton.tintColor = .black
    sendButton.backgroundColor = .white
    sendButton.layer.cornerRadius = 14.0
    sendButton.addTarget(self, action: #selector(handleSubmit), for: .touchUpInside)
    blurView.contentView.addSubview(sendButton)

    spinner.color = .white
    spinner.hidesWhenStopped = true
    blurView.contentView.addSubview(spinner)

    undoButton.setImage(
      UIImage(
        systemName: "arrow.uturn.backward",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 14.0, weight: .semibold)),
      for: .normal)
    undoButton.tintColor = .white
    undoButton.backgroundColor = UIColor(white: 1.0, alpha: 0.16)
    undoButton.layer.cornerRadius = 17.0
    undoButton.isHidden = true
    undoButton.addTarget(self, action: #selector(handleUndo), for: .touchUpInside)
    addSubview(undoButton)

    hintLabel.font = .systemFont(ofSize: 11.0, weight: .medium)
    hintLabel.textColor = UIColor(white: 1.0, alpha: 0.5)
    hintLabel.textAlignment = .center
    addSubview(hintLabel)

    updateSendEnabled()
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  var prompt: String {
    textField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  func clearPrompt() {
    textField.text = ""
    updateSendEnabled()
  }

  func setCanUndo(_ value: Bool) {
    undoButton.isHidden = !value
  }

  /// Shown under the capsule — the selected clip length against the 10s ceiling.
  func setHint(_ text: String) {
    hintLabel.text = text
  }

  func setWorking(_ working: Bool) {
    isWorking = working
    textField.isEnabled = !working
    if working {
      spinner.startAnimating()
      sendButton.isHidden = true
      textField.resignFirstResponder()
    } else {
      spinner.stopAnimating()
      sendButton.isHidden = false
    }
    updateSendEnabled()
  }

  func focus() {
    textField.becomeFirstResponder()
  }

  override func resignFirstResponder() -> Bool {
    textField.resignFirstResponder()
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    let capsuleHeight: CGFloat = 44.0
    let undoSize: CGFloat = 34.0
    let hasUndo = !undoButton.isHidden
    let undoWidth = hasUndo ? undoSize + 8.0 : 0.0

    blurView.frame = CGRect(
      x: 0.0, y: 0.0, width: max(0.0, bounds.width - undoWidth), height: capsuleHeight)
    blurView.layer.cornerRadius = capsuleHeight * 0.5

    if hasUndo {
      undoButton.frame = CGRect(
        x: blurView.frame.maxX + 8.0,
        y: (capsuleHeight - undoSize) * 0.5,
        width: undoSize,
        height: undoSize)
    }

    let trailingInset: CGFloat = 6.0
    let control = CGRect(
      x: blurView.bounds.width - 28.0 - trailingInset,
      y: (capsuleHeight - 28.0) * 0.5,
      width: 28.0,
      height: 28.0)
    sendButton.frame = control
    spinner.center = CGPoint(x: control.midX, y: control.midY)

    textField.frame = CGRect(
      x: 16.0,
      y: 0.0,
      width: max(0.0, control.minX - 24.0),
      height: capsuleHeight)

    hintLabel.frame = CGRect(
      x: 0.0, y: capsuleHeight + 5.0, width: bounds.width, height: 13.0)
  }

  static let preferredHeight: CGFloat = 62.0

  @objc private func handleTextChanged() { updateSendEnabled() }

  @objc private func handleReturn() { handleSubmit() }

  @objc private func handleSubmit() {
    let value = prompt
    guard !value.isEmpty, !isWorking else { return }
    onSubmit?(value)
  }

  @objc private func handleUndo() { onUndo?() }

  private func updateSendEnabled() {
    let enabled = !prompt.isEmpty && !isWorking
    sendButton.isEnabled = enabled
    sendButton.backgroundColor = enabled ? .white : UIColor(white: 1.0, alpha: 0.18)
    sendButton.tintColor = enabled ? .black : UIColor(white: 1.0, alpha: 0.4)
  }
}
