import Foundation
import UIKit

/// Client for the server-side AI media editors.
///
/// Both endpoints take the user's media **before** it is sealed, and both return
/// raw bytes rather than a URL — nothing is persisted server-side, so the result
/// only comes to rest once it has been sealed through the normal media pipeline.
///
/// The provider limits are not ours to negotiate and they shape the UI:
///   * image (`gpt-image-2`) supports a real region **mask**
///   * video (`gemini-omni-flash-preview`) does **not** — prompt only — and takes
///     at most **10 seconds** of input
enum ChatAIMediaEditService {

  struct EditedImage {
    let data: Data
    let mimeType: String
  }

  struct EditedVideo {
    let data: Data
    let mimeType: String
    /// Pass back as `previousInteractionID` to refine this result rather than
    /// re-editing the original clip.
    let interactionID: String?
  }

  enum EditError: LocalizedError {
    case notConfigured
    case server(String)
    case badResponse

    var errorDescription: String? {
      switch self {
      case .notConfigured: return "You're not signed in."
      case .server(let message): return message
      case .badResponse: return "The editor returned something unexpected."
      }
    }
  }

  /// Longest a 10s video edit may reasonably take end to end.
  private static let videoTimeout: TimeInterval = 600
  private static let imageTimeout: TimeInterval = 180

  // MARK: - Image

  /// - Parameter mask: PNG with an alpha channel, **the same pixel dimensions as
  ///   `image`**, where transparent pixels mark the region to replace. Nil edits
  ///   the whole image.
  static func editImage(
    image: Data,
    mimeType: String = "image/png",
    mask: Data? = nil,
    prompt: String,
    size: String? = nil,
    quality: String? = nil
  ) async throws -> EditedImage {
    var parts: [MultipartPart] = [
      .field(name: "prompt", value: prompt),
      .file(name: "image", filename: "source.\(ext(for: mimeType))", mimeType: mimeType, data: image),
    ]
    if let mask {
      parts.append(.file(name: "mask", filename: "mask.png", mimeType: "image/png", data: mask))
    }
    if let size { parts.append(.field(name: "size", value: size)) }
    if let quality { parts.append(.field(name: "quality", value: quality)) }

    let root = try await post(path: "ai/edit_image", parts: parts, timeout: imageTimeout)

    guard let b64 = root["image_b64"] as? String,
      let data = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters])
    else { throw EditError.badResponse }

    return EditedImage(data: data, mimeType: root["mime_type"] as? String ?? "image/png")
  }

  // MARK: - Video

  /// `video` must already be trimmed to 10 seconds or less; the server rejects
  /// anything longer rather than silently truncating it.
  static func editVideo(
    video: Data,
    mimeType: String = "video/mp4",
    prompt: String,
    previousInteractionID: String? = nil,
    aspectRatio: String? = nil
  ) async throws -> EditedVideo {
    var parts: [MultipartPart] = [
      .field(name: "prompt", value: prompt),
      .file(name: "video", filename: "clip.mp4", mimeType: mimeType, data: video),
    ]
    if let previousInteractionID {
      parts.append(.field(name: "previous_interaction_id", value: previousInteractionID))
    }
    if let aspectRatio { parts.append(.field(name: "aspect_ratio", value: aspectRatio)) }

    let root = try await post(path: "ai/edit_video", parts: parts, timeout: videoTimeout)

    guard let b64 = root["video_b64"] as? String,
      let data = Data(base64Encoded: b64, options: [.ignoreUnknownCharacters])
    else { throw EditError.badResponse }

    return EditedVideo(
      data: data,
      mimeType: root["mime_type"] as? String ?? "video/mp4",
      interactionID: root["interaction_id"] as? String
    )
  }

  // MARK: - Transport

  private static func post(
    path: String,
    parts: [MultipartPart],
    timeout: TimeInterval
  ) async throws -> [String: Any] {
    guard let config = AppSessionConfig.current else { throw EditError.notConfigured }

    let url = config.apiBaseURL.appendingPathComponent("api").appendingPathComponent(path)
    let boundary = "----VibeAIBoundary\(UUID().uuidString)"

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("Bearer \(config.authToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    request.setValue(
      "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    let body = encodeMultipart(parts, boundary: boundary)

    let session = ChatPhoenixClient.makePinnedURLSession()
    let (data, response) = try await session.upload(for: request, from: body)

    let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

    guard let http = response as? HTTPURLResponse else { throw EditError.badResponse }

    guard (200...299).contains(http.statusCode) else {
      // The server's `details` are written to be shown to a person.
      if let details = root["details"] as? String, !details.isEmpty {
        throw EditError.server(details)
      }
      if http.statusCode == 429 {
        throw EditError.server("Too many edits just now — give it a minute.")
      }
      throw EditError.server("The editor is unavailable right now.")
    }

    guard root["success"] as? Bool == true else {
      throw EditError.server((root["details"] as? String) ?? "The edit didn't go through.")
    }

    return root
  }

  // MARK: - Multipart

  private enum MultipartPart {
    case field(name: String, value: String)
    case file(name: String, filename: String, mimeType: String, data: Data)
  }

  private static func encodeMultipart(_ parts: [MultipartPart], boundary: String) -> Data {
    var body = Data()
    let newline = "\r\n"

    for part in parts {
      body.append("--\(boundary)\(newline)".data(using: .utf8) ?? Data())
      switch part {
      case .field(let name, let value):
        body.append(
          "Content-Disposition: form-data; name=\"\(name)\"\(newline)\(newline)".data(using: .utf8)
            ?? Data())
        body.append(value.data(using: .utf8) ?? Data())
      case .file(let name, let filename, let mimeType, let data):
        body.append(
          "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\(newline)"
            .data(using: .utf8) ?? Data())
        body.append("Content-Type: \(mimeType)\(newline)\(newline)".data(using: .utf8) ?? Data())
        body.append(data)
      }
      body.append(newline.data(using: .utf8) ?? Data())
    }

    body.append("--\(boundary)--\(newline)".data(using: .utf8) ?? Data())
    return body
  }

  private static func ext(for mimeType: String) -> String {
    switch mimeType {
    case "image/jpeg", "image/jpg": return "jpg"
    case "image/webp": return "webp"
    default: return "png"
    }
  }
}
