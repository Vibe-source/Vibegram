import UIKit

/// Still-frame "computer" sheet:
final class VibeAgentComputerPreviewViewController: UIViewController {
  private let chatId: String
  private let agentUserId: String?
  private let appearance: VibeAgentKitChatAppearance
  private let fallbackNote: String?
  private var changeObserver: NSObjectProtocol?

  private let imageView: UIImageView = {
    let iv = UIImageView()
    iv.contentMode = .scaleAspectFit
    iv.backgroundColor = .black
    iv.translatesAutoresizingMaskIntoConstraints = false
    return iv
  }()

  private let liveDot: UIView = {
    let v = UIView()
    v.backgroundColor = UIColor(red: 0.16, green: 0.78, blue: 0.45, alpha: 1)
    v.layer.cornerRadius = 4
    v.isHidden = true
    v.translatesAutoresizingMaskIntoConstraints = false
    return v
  }()

  private let labelView: UILabel = {
    let l = UILabel()
    l.font = .systemFont(ofSize: 15, weight: .semibold)
    l.textColor = .white
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
  }()

  private let closeButton: UIButton = {
    let btn = UIButton(type: .system)
    btn.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
    btn.tintColor = UIColor.white.withAlphaComponent(0.85)
    btn.translatesAutoresizingMaskIntoConstraints = false
    return btn
  }()

  private let noteLabel: UILabel = {
    let l = UILabel()
    l.font = .systemFont(ofSize: 12, weight: .medium)
    l.textColor = UIColor.white.withAlphaComponent(0.6)
    l.numberOfLines = 2
    l.isHidden = true
    l.translatesAutoresizingMaskIntoConstraints = false
    return l
  }()

  init(
    chatId: String, appearance: VibeAgentKitChatAppearance, fallbackNote: String? = nil,
    agentUserId: String? = nil
  ) {
    self.chatId = chatId
    self.agentUserId = agentUserId
    self.appearance = appearance
    self.fallbackNote = fallbackNote
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }

  required init?(coder: NSCoder) { return nil }

  deinit {
    if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    view.addSubview(imageView)
    view.addSubview(liveDot)
    view.addSubview(labelView)
    view.addSubview(noteLabel)
    view.addSubview(closeButton)
    closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

    noteLabel.text = fallbackNote
    noteLabel.isHidden = fallbackNote == nil

    NSLayoutConstraint.activate([
      noteLabel.topAnchor.constraint(equalTo: labelView.bottomAnchor, constant: 2),
      noteLabel.leadingAnchor.constraint(equalTo: labelView.leadingAnchor),
      noteLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12),

      imageView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 52),
      imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      imageView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

      labelView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      labelView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
      labelView.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -12),

      liveDot.centerYAnchor.constraint(equalTo: labelView.centerYAnchor),
      liveDot.leadingAnchor.constraint(equalTo: labelView.trailingAnchor, constant: 8),
      liveDot.widthAnchor.constraint(equalToConstant: 8),
      liveDot.heightAnchor.constraint(equalToConstant: 8),

      closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
      closeButton.widthAnchor.constraint(equalToConstant: 32),
      closeButton.heightAnchor.constraint(equalToConstant: 32),
    ])

    refresh()
    changeObserver = NotificationCenter.default.addObserver(
      forName: ChatEngine.didChangeNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let self else { return }
      guard (note.userInfo?["reason"] as? String) == "agentPreview",
        (note.userInfo?["chatId"] as? String) == self.chatId
      else { return }
      if let pinned = self.agentUserId, !pinned.isEmpty,
        (note.userInfo?["agentUserId"] as? String) != pinned
      { return }
      self.refresh()
    }
  }

  @objc private func closeTapped() {
    dismiss(animated: true)
  }

  private func refresh() {
    guard
      let preview = ChatEngine.shared.latestAgentPreview(chatId: chatId, agentUserId: agentUserId)
    else {
      labelView.text = "Computer"
      noteLabel.text = fallbackNote ?? "Waiting for the first frame…"
      noteLabel.isHidden = false
      liveDot.isHidden = true
      return
    }
    imageView.image = preview.image
    labelView.text = preview.label
    noteLabel.isHidden = fallbackNote == nil
    liveDot.isHidden = ChatEngine.shared.activeIsolatedRunId(chatId: chatId) != preview.runId
  }
}
