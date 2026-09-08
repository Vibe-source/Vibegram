import Foundation

/// Files this user actually sent, newest first. Used by the attachment File sheet.
final class ChatRecentSentFilesStore {
  static let shared = ChatRecentSentFilesStore()

  struct Entry: Codable, Equatable {
    let id: String
    let fileName: String
    let storedName: String
    let byteSize: Int64
    let sentAt: Date
  }

  private let defaultsKey = "chat.recent.sent.files.v1"
  private let limit = 24
  private let queue = DispatchQueue(label: "vibe.recent.sent.files")
  private(set) var entries: [Entry] = []

  static let didChange = Notification.Name("ChatRecentSentFilesStoreDidChange")

  private init() {
    entries = loadEntries()
  }

  var directory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("RecentSentFiles", isDirectory: true)
    if !FileManager.default.fileExists(atPath: dir.path) {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    return dir
  }

  func fileURL(for entry: Entry) -> URL {
    directory.appendingPathComponent(entry.storedName)
  }

  func record(sourceURL: URL, displayName: String, byteSize: Int64) {
    queue.async { [weak self] in
      guard let self else { return }
      let id = UUID().uuidString.lowercased()
      let ext = sourceURL.pathExtension.isEmpty ? "bin" : sourceURL.pathExtension
      let stored = "\(id).\(ext)"
      let dest = self.directory.appendingPathComponent(stored)
      try? FileManager.default.copyItem(at: sourceURL, to: dest)
      guard FileManager.default.fileExists(atPath: dest.path) else { return }
      var next = self.loadEntries()
      next.insert(
        Entry(
          id: id, fileName: displayName, storedName: stored, byteSize: byteSize, sentAt: Date()),
        at: 0)
      let trimmed = Array(next.prefix(self.limit))
      for dropped in next.dropFirst(self.limit) {
        try? FileManager.default.removeItem(at: self.fileURL(for: dropped))
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
      FileManager.default.fileExists(atPath: fileURL(for: $0).path)
    }
  }
}
