import Foundation
import UIKit

/// Ships client errors from the `VibeLog` ring to `POST /api/client-logs`, where the
/// DevOps team's @monitor reads them. Errors and faults only — the ring keeps the rest.
public enum VibeLogUploader {
  private static let minLevel: VibeLogLevel = .error
  private static let maxBatch = 100
  private static let minInterval: TimeInterval = 300
  private static let highWaterKey = "vibe.clientlog.sent_through"

  private static let queue = DispatchQueue(label: "com.vibegram.vibe.clientlog", qos: .utility)
  private static var lastAttempt: Date?
  private static var inFlight = false

  /// Call on background/foreground transitions and after a crash marker is found.
  public static func flush(reason: String, force: Bool = false) {
    queue.async {
      guard !inFlight else { return }

      if !force, let last = lastAttempt, Date().timeIntervalSince(last) < minInterval { return }

      let sentThrough = UserDefaults.standard.object(forKey: highWaterKey) as? Date ?? .distantPast

      let pending =
        VibeLog.shared.snapshot()
        .filter { $0.level >= minLevel && $0.ts > sentThrough }
        .suffix(maxBatch)

      guard let newest = pending.last?.ts else { return }

      // No session yet is not a failed attempt, so it must not burn the interval.
      guard AppSessionConfig.current != nil else { return }

      lastAttempt = Date()
      inFlight = true

      send(Array(pending), reason: reason) { ok in
        queue.async {
          inFlight = false
          if ok { UserDefaults.standard.set(newest, forKey: highWaterKey) }
        }
      }
    }
  }

  private static func send(
    _ entries: [VibeLogEntry], reason: String, completion: @escaping (Bool) -> Void
  ) {
    guard let config = AppSessionConfig.current else { return completion(false) }

    let url = config.apiBaseURL.appendingPathComponent("api/client-logs")
    let payload: [String: Any] = ["app": appContext(reason: reason), "events": entries.map(event)]

    guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
      return completion(false)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let task = ChatPhoenixClient.makePinnedURLSession().dataTask(with: request, from: body) {
      _, response, _ in
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      completion((200...299).contains(code))
    }
    task.resume()
  }

  private static func event(_ entry: VibeLogEntry) -> [String: Any] {
    let meta =
      entry.metadata.flatMap {
        $0.isEmpty ? nil : " " + $0.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
      } ?? ""

    let repeated = entry.repeats > 1 ? " (×\(entry.repeats))" : ""

    return [
      "level": entry.level.label.lowercased(),
      "tag": entry.category,
      "ts": entry.timestampString,
      "message": "\(entry.message)\(meta)\(repeated) (\(entry.file):\(entry.line))",
    ]
  }

  private static func appContext(reason: String) -> [String: Any] {
    let info = Bundle.main.infoDictionary ?? [:]

    return [
      "platform": "ios",
      "version": info["CFBundleShortVersionString"] as? String ?? "?",
      "build": info["CFBundleVersion"] as? String ?? "?",
      "os": UIDevice.current.systemVersion,
      "device": deviceModel(),
      "reason": reason,
    ]
  }

  private static func deviceModel() -> String {
    var info = utsname()
    uname(&info)
    let raw = withUnsafeBytes(of: &info.machine) { bytes in
      String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
    }
    return raw.isEmpty ? UIDevice.current.model : raw
  }
}

extension URLSession {
  fileprivate func dataTask(
    with request: URLRequest, from body: Data,
    completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void
  ) -> URLSessionUploadTask {
    uploadTask(with: request, from: body, completionHandler: completionHandler)
  }
}
