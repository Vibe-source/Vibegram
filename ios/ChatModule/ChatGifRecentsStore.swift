import UIKit

/// GIFs this user has actually sent, kept as local files.
///
/// Bytes, not provider URLs — the send path already downloads them, so recents cost one
/// extra write and never call a third party to render. See
/// `ChatListView.inputBarDidSelectGif`.
final class ChatGifRecentsStore {
  static let shared = ChatGifRecentsStore()

  struct Entry: Codable, Equatable {
    let id: String
    let fileName: String
    let width: Int
    let height: Int
  }

  private let defaultsKey = "chat.gif.recents.v1"
  private let limit = 48
  private let queue = DispatchQueue(label: "vibe.gif.recents")

  private(set) var entries: [Entry] = []

  private init() {
    entries = loadEntries()
  }

  var directory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("GifRecents", isDirectory: true)
    if !FileManager.default.fileExists(atPath: dir.path) {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return dir
  }

  func fileURL(for entry: Entry) -> URL {
    directory.appendingPathComponent(entry.fileName)
  }

  /// Records a sent GIF, newest first. `id` dedupes re-sends of the same GIF.
  func record(id: String, data: Data, width: Int, height: Int) {
    queue.async { [weak self] in
      guard let self, !data.isEmpty else { return }
      let name = "\(id).gif"
      let url = self.directory.appendingPathComponent(name)
      if !FileManager.default.fileExists(atPath: url.path) {
        try? data.write(to: url, options: .atomic)
      }
      var next = self.loadEntries().filter { $0.id != id }
      next.insert(Entry(id: id, fileName: name, width: width, height: height), at: 0)
      let trimmed = Array(next.prefix(self.limit))
      for dropped in next.dropFirst(self.limit) {
        try? FileManager.default.removeItem(at: self.directory.appendingPathComponent(dropped.fileName))
      }
      if let encoded = try? JSONEncoder().encode(trimmed) {
        UserDefaults.standard.set(encoded, forKey: self.defaultsKey)
      }
      DispatchQueue.main.async {
        self.entries = trimmed
        NotificationCenter.default.post(name: Self.didChange, object: nil)
      }
    }
  }

  private func loadEntries() -> [Entry] {
    guard let data = UserDefaults.standard.data(forKey: defaultsKey),
      let decoded = try? JSONDecoder().decode([Entry].self, from: data)
    else { return [] }
    return decoded.filter {
      FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.fileName).path)
    }
  }

  static let didChange = Notification.Name("ChatGifRecentsStoreDidChange")
}
