import UIKit

/// Multi-agent team progress sheet: one section per worker with status/duration
/// and that worker's step timeline. Lead section also shows the final summary body.
final class VibeAgentTeamRunDetailViewController: UIViewController {
  var onClose: (() -> Void)?
  var onCancelTeam: (() -> Void)?

  private let appearance: VibeAgentKitChatAppearance
  private let titleText: String
  private let bodyText: String
  private let sections: [Section]
  private let running: Bool
  private let canCancel: Bool

  private let scrollView = UIScrollView()
  private let contentStack = UIStackView()
  private let emptyLabel = UILabel()

  struct Section {
    let worker: String
    let label: String
    let statusLine: String
    let isLead: Bool
    let progressItems: [VibeAgentKitProgressItem]
  }

  init(
    title: String,
    bodyText: String,
    sections: [Section],
    running: Bool,
    canCancel: Bool,
    appearance: VibeAgentKitChatAppearance
  ) {
    self.titleText = title
    self.bodyText = bodyText
    self.sections = sections
    self.running = running
    self.canCancel = canCancel
    self.appearance = appearance
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    configureNavigationBar()

    scrollView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.alwaysBounceVertical = true
    view.addSubview(scrollView)

    contentStack.axis = .vertical
    contentStack.spacing = 18
    contentStack.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(contentStack)

    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    emptyLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
    emptyLabel.textColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.7)
    emptyLabel.numberOfLines = 0
    emptyLabel.textAlignment = .center
    emptyLabel.text = "Waiting for team activity…"
    view.addSubview(emptyLabel)

    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      contentStack.topAnchor.constraint(
        equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 14),
      contentStack.leadingAnchor.constraint(
        equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 18),
      contentStack.trailingAnchor.constraint(
        equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -18),
      contentStack.bottomAnchor.constraint(
        equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
      emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
      emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
    ])

    rebuild()
  }

  private func configureNavigationBar() {
    navigationItem.title = titleText
    var right: [UIBarButtonItem] = [
      UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(handleClose))
    ]
    if canCancel, running {
      let stop = UIBarButtonItem(
        image: UIImage(systemName: "stop.fill"),
        style: .plain,
        target: self,
        action: #selector(handleCancelTeam)
      )
      right.insert(stop, at: 0)
    }
    navigationItem.rightBarButtonItems = right
    navigationItem.rightBarButtonItem?.tintColor = appearance.text

    let navBarAppearance = UINavigationBarAppearance()
    navBarAppearance.configureWithTransparentBackground()
    navigationController?.navigationBar.standardAppearance = navBarAppearance
    navigationController?.navigationBar.scrollEdgeAppearance = navBarAppearance
    navigationController?.navigationBar.compactAppearance = navBarAppearance
  }

  @objc private func handleClose() {
    dismiss(animated: true)
  }

  @objc private func handleCancelTeam() {
    onCancelTeam?()
    navigationItem.rightBarButtonItems?.first?.isEnabled = false
    navigationItem.title = "Stopping team…"
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    let dismissed = isBeingDismissed || (navigationController?.isBeingDismissed ?? false)
    if dismissed || isMovingFromParent { onClose?() }
  }

  private func rebuild() {
    contentStack.arrangedSubviews.forEach {
      contentStack.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }

    let hasBody = !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let hasSections = sections.contains { !$0.progressItems.isEmpty || !$0.statusLine.isEmpty }
    emptyLabel.isHidden = hasBody || hasSections

    if hasBody {
      let header = sectionHeader("SUMMARY")
      contentStack.addArrangedSubview(header)
      let body = UILabel()
      body.numberOfLines = 0
      body.font = UIFont.systemFont(ofSize: 15, weight: .regular)
      body.textColor = appearance.text
      body.text = bodyText
      contentStack.addArrangedSubview(body)
      contentStack.setCustomSpacing(10, after: header)
    }

    for section in sections {
      let title = section.isLead ? "\(section.label) · lead" : section.label
      let header = sectionHeader(title.uppercased())
      contentStack.addArrangedSubview(header)

      let status = UILabel()
      status.numberOfLines = 2
      status.font = UIFont.systemFont(ofSize: 13, weight: .medium)
      status.textColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.9)
      status.text = section.statusLine
      contentStack.addArrangedSubview(status)
      contentStack.setCustomSpacing(6, after: header)
      contentStack.setCustomSpacing(8, after: status)

      let items = section.progressItems.filter {
        $0.itemType != "text"
      }
      if items.isEmpty {
        let empty = UILabel()
        empty.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        empty.textColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.65)
        empty.text = section.isLead ? "Lead activity will appear here." : "No steps yet."
        contentStack.addArrangedSubview(empty)
      } else {
        let timeline = VibeAgentActivityTimelineView()
        timeline.configure(items: items, expandedStepIds: [], appearance: appearance)
        contentStack.addArrangedSubview(timeline)
      }
    }
  }

  private func sectionHeader(_ text: String) -> UILabel {
    let label = UILabel()
    label.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
    label.textColor = vibeAgentKitColorWithAlpha(appearance.textSecondary, 0.65)
    label.text = text
    return label
  }
}
