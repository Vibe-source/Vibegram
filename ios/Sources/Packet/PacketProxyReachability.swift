import Foundation
import Network
import os

/// TCP-connect probe per proxy entry: is the endpoint answering, and how fast.
/// Measures the endpoint itself, so a result is real whether or not the engine is running.
@MainActor
final class PacketProxyReachability: ObservableObject {
  static let shared = PacketProxyReachability()

  enum Status: Equatable {
    case unknown
    case checking
    case live(Int)
    case unavailable

    var pingMs: Int? {
      if case let .live(ms) = self { return ms }
      return nil
    }
  }

  @Published private(set) var statuses: [UUID: Status] = [:]
  /// Whether real traffic survives the running proxy — a bound SOCKS port proves nothing.
  @Published private(set) var tunnel: Status = .unknown

  private var lastProbedAt: [UUID: Date] = [:]
  private var tunnelProbeInFlight = false
  private let staleAfter: TimeInterval = 60

  private init() {}

  /// Fetches through the local SOCKS port. The endpoint can answer while the tunnel behind
  /// it is dead (bad credentials, blocked exit), and only this call can tell the difference.
  func probeTunnel(proxyHost: String, proxyPort: Int, apiBase: URL) {
    guard !tunnelProbeInFlight, proxyPort > 0 else { return }
    tunnelProbeInFlight = true
    if tunnel == .unknown { tunnel = .checking }

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 8
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.connectionProxyDictionary = [
      "SOCKSEnable": 1,
      "SOCKSProxy": proxyHost,
      "SOCKSPort": proxyPort,
    ]
    var request = URLRequest(url: apiBase)
    request.httpMethod = "HEAD"

    Task {
      let start = Date()
      let session = URLSession(configuration: configuration)
      defer { tunnelProbeInFlight = false }
      do {
        _ = try await session.data(for: request)
        tunnel = .live(Int(Date().timeIntervalSince(start) * 1000))
      } catch {
        tunnel = .unavailable
      }
    }
  }

  func resetTunnel() {
    tunnel = .unknown
  }

  func status(for profile: PacketProxyProfile) -> Status {
    statuses[profile.id] ?? .unknown
  }

  /// Probes anything never checked or checked over a minute ago.
  func refreshIfStale(_ profiles: [PacketProxyProfile]) {
    let now = Date()
    for profile in profiles {
      let last = lastProbedAt[profile.id]
      guard last == nil || now.timeIntervalSince(last!) > staleAfter else { continue }
      probe(profile)
    }
  }

  func probe(_ profile: PacketProxyProfile) {
    let host = profile.endpointHost
    let port = profile.endpointPort
    guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
      statuses[profile.id] = .unavailable
      return
    }

    statuses[profile.id] = .checking
    lastProbedAt[profile.id] = Date()

    Task {
      let result = await Self.tcpProbe(host: host, port: nwPort)
      statuses[profile.id] = result
    }
  }

  private static func tcpProbe(host: String, port: NWEndpoint.Port) async -> Status {
    let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
    return await withCheckedContinuation { continuation in
      let finished = OSAllocatedUnfairLock(initialState: false)
      let start = Date()

      func finish(_ status: Status) {
        let alreadyDone = finished.withLock { done -> Bool in
          if done { return true }
          done = true
          return false
        }
        guard !alreadyDone else { return }
        connection.cancel()
        continuation.resume(returning: status)
      }

      connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
          finish(.live(Int(Date().timeIntervalSince(start) * 1000)))
        case .failed, .cancelled:
          finish(.unavailable)
        default:
          break
        }
      }
      connection.start(queue: .global(qos: .utility))
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4) {
        finish(.unavailable)
      }
    }
  }
}
