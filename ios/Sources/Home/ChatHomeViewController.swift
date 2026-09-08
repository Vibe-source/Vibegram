import Foundation
import UIKit

final class ChatHomeViewController: UIViewController, UITableViewDataSource, UITableViewDelegate,
  ChatHomeCardCellSwipeDelegate
{
  private let tableView = UITableView(frame: .zero, style: .plain)
  private let refreshControl = UIRefreshControl()
  private var rows: [ChatHomeListRow] = []
  private var loadingTask: Task<Void, Never>?

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Chats"
    view.backgroundColor = .systemBackground

    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "Logout",
      style: .plain,
      target: self,
      action: #selector(handleLogout)
    )

    tableView.translatesAutoresizingMaskIntoConstraints = false
    tableView.dataSource = self
    tableView.delegate = self
    tableView.separatorStyle = .none
    tableView.rowHeight = 84
    tableView.register(ChatHomeCardCell.self, forCellReuseIdentifier: ChatHomeCardCell.reuseIdentifier)
    tableView.refreshControl = refreshControl
    refreshControl.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
    view.addSubview(tableView)

    NSLayoutConstraint.activate([
      tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tableView.topAnchor.constraint(equalTo: view.topAnchor),
      tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])

    loadChats()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.setNavigationBarHidden(false, animated: false)
  }

  deinit {
    loadingTask?.cancel()
  }

  @objc private func handleRefresh() {
    loadChats()
  }

  @objc private func handleLogout() {
    ChatEngineStore.shared.clearConfig()
    navigationController?.setViewControllers([WelcomeViewController()], animated: true)
  }

  private func loadChats() {
    refreshControl.beginRefreshing()
    loadingTask?.cancel()
    loadingTask = Task { [weak self] in
      guard let self else { return }
      do {
        guard let config = AppSessionConfig.current else {
          await MainActor.run {
            self.refreshControl.endRefreshing()
            self.navigationController?.setViewControllers([WelcomeViewController()], animated: true)
          }
          return
        }
        let rows = try await ChatHomeService.fetchChats(config: config)
        await MainActor.run {
          self.rows = rows
          self.tableView.reloadData()
          self.refreshControl.endRefreshing()
        }
      } catch {
        await MainActor.run {
          self.refreshControl.endRefreshing()
          self.presentError(error)
        }
      }
    }
  }

  private func presentError(_ error: Error) {
    let alert = UIAlertController(
      title: "Home Load Failed",
      message: error.localizedDescription,
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Retry", style: .default) { [weak self] _ in
      self?.loadChats()
    })
    alert.addAction(UIAlertAction(title: "Auth", style: .default) { [weak self] _ in
      guard let self else { return }
      AuthViewController.present(from: self, mode: .signIn) { [weak self] in
        self?.navigationController?.setViewControllers([ChatHomeViewController()], animated: true)
      }
    })
    present(alert, animated: true)
  }

  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    rows.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let row = rows[indexPath.row]
    guard
      let cell = tableView.dequeueReusableCell(
        withIdentifier: ChatHomeCardCell.reuseIdentifier,
        for: indexPath
      ) as? ChatHomeCardCell
    else {
      return UITableViewCell()
    }

    let isDark = traitCollection.userInterfaceStyle == .dark
    cell.swipeDelegate = self
    cell.selectionStyle = .none
    cell.backgroundColor = .clear
    cell.contentView.backgroundColor = .clear
    cell.configure(
      row: row,
      isDark: isDark,
      avatarBackgroundColor: nil,
      avatarGradientColors: nil,
      unreadBadgeColor: AppThemePalette.resolve(for: isDark ? .dark : .light).accentUIColor,
      isEditing: false,
      isEditSelected: false
    )
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    let row = rows[indexPath.row]
    let controller = UIViewController()
    controller.view.backgroundColor = .systemBackground
    controller.title = row.title

    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.textAlignment = .center
    label.textColor = .secondaryLabel
    label.numberOfLines = 0
    label.text = "Conversation layout is the next native surface to wire into this shell."
    controller.view.addSubview(label)

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 24),
      label.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -24),
      label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
    ])

    navigationController?.pushViewController(controller, animated: true)
  }

  func homeCardCellDidBeginSwipe(_ cell: ChatHomeCardCell) {}

  func homeCardCellDidCloseSwipe(_ cell: ChatHomeCardCell) {}

  func homeCardCell(
    _ cell: ChatHomeCardCell,
    didTriggerSwipeEvent eventType: String,
    chatId: String
  ) {
    let message = "Handled \(eventType) for \(chatId)."
    let alert = UIAlertController(title: "Native Action", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }
}
