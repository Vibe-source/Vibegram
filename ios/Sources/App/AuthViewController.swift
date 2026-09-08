import CommonCrypto
import CryptoKit
import Foundation
import Security
import SwiftUI
import UIKit

final class AuthViewController: UIHostingController<NativeAuthSheetView> {
  enum Mode {
    case signIn
    case signUp

    var titleText: String {
      switch self {
      case .signIn:
        return "Sign In"
      case .signUp:
        return "Create Account"
      }
    }

    var buttonTitle: String {
      switch self {
      case .signIn:
        return "Continue"
      case .signUp:
        return "Create Account"
      }
    }

    var subtitleText: String {
      switch self {
      case .signIn:
        return "Use your secret key to unlock your identity."
      case .signUp:
        return "Choose a username and create a private identity."
      }
    }

  }

  private let viewModel: NativeAuthSheetViewModel

  static func present(
    from presenter: UIViewController,
    mode: Mode = .signIn,
    onAuthenticated: (() -> Void)? = nil
  ) {
    if presenter.presentedViewController is AuthViewController {
      return
    }

    let controller = AuthViewController(mode: mode, onAuthenticated: onAuthenticated)
    presenter.present(controller, animated: true)
  }

  init(mode: Mode = .signIn, onAuthenticated: (() -> Void)? = nil) {
    let viewModel = NativeAuthSheetViewModel(mode: mode, onAuthenticated: onAuthenticated)
    self.viewModel = viewModel
    super.init(rootView: NativeAuthSheetView(model: viewModel))
    viewModel.setDismissHandler { [weak self] completion in
      self?.dismiss(animated: true, completion: completion)
    }
    modalPresentationStyle = .automatic
  }

  required init?(coder: NSCoder) {
    nil
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    configureSheet()
    view.backgroundColor = NativeAuthSheetTheme.pageBackgroundUIColor
  }

  private func configureSheet() {
    if let sheet = sheetPresentationController {
      sheet.detents = [.large()]
      sheet.prefersGrabberVisible = false
      sheet.selectedDetentIdentifier = .large
      sheet.preferredCornerRadius = 24
    }
  }
}

struct AuthSheetAlert: Identifiable {
  enum Kind {
    case error
  }

  let id = UUID()
  let title: String
  let message: String
  let kind: Kind
}

@MainActor
final class NativeAuthSheetViewModel: ObservableObject {
  @Published var username = ""
  @Published var secret = ""
  @Published var isLoading = false
  @Published var activeAlert: AuthSheetAlert?

  let mode: AuthViewController.Mode
  private let onAuthenticated: (() -> Void)?
  private var authTask: Task<Void, Never>?
  private var dismissHandler: ((@escaping () -> Void) -> Void)?

  init(mode: AuthViewController.Mode, onAuthenticated: (() -> Void)?) {
    self.mode = mode
    self.onAuthenticated = onAuthenticated
  }

  deinit {
    authTask?.cancel()
  }

  var primaryActionDisabled: Bool {
    if isLoading {
      return true
    }

    switch mode {
    case .signIn:
      return NativeAuthCrypto.normalizeSecret(secret).isEmpty
    case .signUp:
      return NativeAuthCrypto.normalizeUsername(username).isEmpty
    }
  }

  func setDismissHandler(_ handler: @escaping (@escaping () -> Void) -> Void) {
    dismissHandler = handler
  }

  func handleClose() {
    guard !isLoading else { return }
    dismissHandler?({})
  }

  func handleAlert(_ alert: AuthSheetAlert) -> Alert {
    switch alert.kind {
    case .error:
      return Alert(
        title: Text(alert.title),
        message: Text(alert.message),
        dismissButton: .default(Text("OK")) {
          self.activeAlert = nil
        }
      )
    }
  }

  func submit() {
    guard !isLoading else { return }
    switch mode {
    case .signIn:
      startSignIn()
    case .signUp:
      startSignUp()
    }
  }

  private func startSignIn() {
    let normalizedSecret = NativeAuthCrypto.normalizeSecret(secret)
    guard !normalizedSecret.isEmpty else {
      activeAlert = AuthSheetAlert(
        title: "Secret Key Required",
        message: "Enter the Secret Key to continue.",
        kind: .error
      )
      return
    }

    let transportMode = AppSessionConfig.current?.transportMode ?? .direct
    let apiBaseURLString = AppSessionConfig.current?.apiBaseURLString ?? AppSessionConfig.defaultAPIBaseURLString
    isLoading = true
    authTask = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await NativeAuthService.signIn(
          secret: normalizedSecret,
          apiBaseURLString: apiBaseURLString,
          transportMode: transportMode
        )
        await MainActor.run {
          self.persist(
            result.config,
            storedSecret: normalizedSecret,
            shouldShowSecretSavedToast: false
          )
        }
      } catch {
        await MainActor.run {
          self.presentError(title: "Sign In Failed", message: error.localizedDescription)
        }
      }
    }
  }

  private func startSignUp() {
    let normalizedUsername = NativeAuthCrypto.normalizeUsername(username)
    guard NativeAuthCrypto.isValidUsername(normalizedUsername) else {
      activeAlert = AuthSheetAlert(
        title: "Invalid Username",
        message: "Use 3 to 30 letters, numbers, or underscores.",
        kind: .error
      )
      return
    }

    let transportMode = AppSessionConfig.current?.transportMode ?? .direct
    let apiBaseURLString = AppSessionConfig.current?.apiBaseURLString ?? AppSessionConfig.defaultAPIBaseURLString
    isLoading = true
    authTask = Task { [weak self] in
      guard let self else { return }
      do {
        let result = try await NativeAuthService.signUp(
          username: normalizedUsername,
          apiBaseURLString: apiBaseURLString,
          transportMode: transportMode
        )
        await MainActor.run {
          self.persist(
            result.config,
            storedSecret: result.recoverySecret,
            shouldShowSecretSavedToast: false
          )
        }
      } catch {
        await MainActor.run {
          self.presentError(title: "Create Account Failed", message: error.localizedDescription)
        }
      }
    }
  }


  private func persist(
    _ config: AppSessionConfig,
    storedSecret: String?,
    shouldShowSecretSavedToast: Bool
  ) {
    AppSessionConfig.store(config)
    // Store loginSecret AFTER AppSessionConfig.store() because store() calls
    // clearConfig() which wipes all keychain secrets including loginSecret.
    if let storedSecret, !storedSecret.isEmpty {
      _ = SecureKeyStore.shared.storeSecret(key: "loginSecret", value: storedSecret)
    }
    AppProfileController.shared.reset()
    Task.detached {
      await PacketBootstrapService.prefetchIfNeeded(config: config)
    }
    if shouldShowSecretSavedToast {
      AppToastController.shared.show("Secret key saved in Settings > Secret Key.")
    }
    finishAuthenticatedFlow()
  }

  private func finishAuthenticatedFlow() {
    activeAlert = nil
    isLoading = false
    let completion = onAuthenticated
    dismissHandler? {
      completion?()
    }
  }

  private func presentError(title: String, message: String) {
    isLoading = false
    activeAlert = AuthSheetAlert(title: title, message: message, kind: .error)
  }
}

struct NativeAuthSheetView: View {
  @ObservedObject var model: NativeAuthSheetViewModel

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        ScrollView(showsIndicators: false) {
          VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
              Text(model.mode.titleText)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(NativeAuthSheetTheme.text)

              Text(model.mode.subtitleText)
                .font(.system(size: 15))
                .foregroundStyle(NativeAuthSheetTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 8)

            VStack(spacing: 16) {
              if model.mode == .signUp {
                NativeFloatingAuthField(
                  label: "Username",
                  text: $model.username,
                  isSecure: false,
                  textContentType: .username,
                  submitLabel: .go,
                  onSubmit: model.submit
                )
              } else {
                NativeFloatingAuthField(
                  label: "Secret Key",
                  text: $model.secret,
                  isSecure: true,
                  textContentType: .password,
                  submitLabel: .go,
                  onSubmit: model.submit
                )
              }
            }

            Button(action: model.submit) {
              ZStack {
                if model.isLoading {
                  ProgressView()
                    .tint(NativeAuthSheetTheme.primaryForeground)
                    .scaleEffect(0.9)
                } else {
                  Text(model.mode.buttonTitle)
                    .font(.system(size: 16, weight: .semibold))
                }
              }
              .frame(maxWidth: .infinity)
            }
            .buttonStyle(NativeAuthPrimaryButtonStyle())
            .disabled(model.primaryActionDisabled)
          }
          .padding(.horizontal, 20)
          .padding(.vertical, 24)
        }
      }
      .background(NativeAuthSheetTheme.pageBackground.ignoresSafeArea())
      .navigationTitle(model.mode.titleText)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            model.handleClose()
          } label: {
            Image(systemName: "xmark")
              .font(.system(size: 14, weight: .bold))
          }
          .buttonStyle(.plain)
          .disabled(model.isLoading)
        }
      }
    }
    .interactiveDismissDisabled(model.isLoading)
    .alert(item: $model.activeAlert) { alert in
      model.handleAlert(alert)
    }
  }
}

private struct NativeFloatingAuthField: View {
  let label: String
  @Binding var text: String
  let isSecure: Bool
  var keyboardType: UIKeyboardType = .default
  var textContentType: UITextContentType? = nil
  var submitLabel: SubmitLabel = .done
  var onSubmit: (() -> Void)? = nil

  @FocusState private var isFocused: Bool
  @State private var isTextVisible = false

  private var shouldFloat: Bool {
    isFocused || !text.isEmpty
  }

  var body: some View {
    HStack(spacing: 12) {
      ZStack(alignment: .leading) {
        Text(label)
          .font(.system(size: shouldFloat ? 12 : 16, weight: .medium))
          .foregroundStyle(isFocused ? NativeAuthSheetTheme.borderFocused : NativeAuthSheetTheme.muted)
          .offset(y: shouldFloat ? -12 : 0)
          .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isFocused)
          .animation(.spring(response: 0.25, dampingFraction: 0.75), value: text.isEmpty)

        Group {
          if isSecure && !isTextVisible {
            SecureField("", text: $text)
              .focused($isFocused)
              .privacySensitive()
          } else {
            TextField("", text: $text)
              .focused($isFocused)
              .keyboardType(keyboardType)
              .privacySensitive()
          }
        }
        .textInputAutocapitalization(.never)
        .textContentType(textContentType)
        .autocorrectionDisabled()
        .submitLabel(submitLabel)
        .onSubmit {
          onSubmit?()
        }
        .font(.system(size: 16, weight: .regular))
        .foregroundStyle(NativeAuthSheetTheme.fieldText)
        .tint(NativeAuthSheetTheme.fieldText)
        .padding(.top, shouldFloat ? 14 : 0)
      }

      if isSecure {
        Button {
          isTextVisible.toggle()
        } label: {
          Image(systemName: isTextVisible ? "eye.slash" : "eye")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isFocused ? NativeAuthSheetTheme.borderFocused : NativeAuthSheetTheme.muted)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 16)
    .frame(height: NativeAuthSheetTheme.controlHeight)
    .background(Color.clear)
    .overlay(
      RoundedRectangle(
        cornerRadius: NativeAuthSheetTheme.controlCornerRadius,
        style: .continuous
      )
        .stroke(
          isFocused ? NativeAuthSheetTheme.borderFocused : NativeAuthSheetTheme.border,
          lineWidth: isFocused ? 1.2 : 1
        )
    )
  }
}

private struct NativeAuthPrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 16, weight: .semibold))
      .foregroundStyle(NativeAuthSheetTheme.primaryForeground)
      .frame(maxWidth: .infinity)
      .frame(height: NativeAuthSheetTheme.controlHeight)
      .contentShape(
        RoundedRectangle(
          cornerRadius: NativeAuthSheetTheme.controlCornerRadius,
          style: .continuous
        )
      )
      .background(
        RoundedRectangle(
          cornerRadius: NativeAuthSheetTheme.controlCornerRadius,
          style: .continuous
        )
          .fill(configuration.isPressed ? NativeAuthSheetTheme.primaryFillPressed : NativeAuthSheetTheme.primaryFill)
          .overlay(
            RoundedRectangle(
              cornerRadius: NativeAuthSheetTheme.controlCornerRadius,
              style: .continuous
            )
              .stroke(NativeAuthSheetTheme.border.opacity(0.45), lineWidth: 1)
          )
      )
      .opacity(isEnabled ? 1.0 : 0.78)
      .scaleEffect(configuration.isPressed && isEnabled ? 0.985 : 1.0)
      .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
  }
}

private enum NativeAuthSheetTheme {
  static let controlHeight: CGFloat = 52
  static let controlCornerRadius: CGFloat = 26

  static let pageBackgroundUIColor = dynamicUIColor(light: hex(0xFFFFFF), dark: hex(0x1E1E1E))

  static var pageBackground: Color { Color(uiColor: pageBackgroundUIColor) }
  static var text: Color { dynamicColor(light: hex(0x000000), dark: hex(0xF5F5F7)) }
  static var muted: Color { dynamicColor(light: hex(0x8E8E93), dark: hex(0x8E8E93)) }
  static var fieldText: Color { dynamicColor(light: hex(0x000000), dark: hex(0xF5F5F7)) }
  static var border: Color { dynamicColor(light: hex(0xD1D1D6), dark: hex(0x38383A)) }
  static var borderFocused: Color { dynamicColor(light: hex(0x8E8E93), dark: hex(0x545458)) }
  static var primaryFill: Color { dynamicColor(light: hex(0x1D1D1F), dark: hex(0xF5F5F7)) }
  static var primaryFillPressed: Color { dynamicColor(light: hex(0x000000), dark: hex(0xD1D1D6)) }
  static var primaryForeground: Color { dynamicColor(light: hex(0xFFFFFF), dark: hex(0x000000)) }
  static var statusFill: Color { dynamicColor(light: hex(0xF2F2F7), dark: hex(0x2C2C2E)) }

  private static func dynamicColor(light: UIColor, dark: UIColor) -> Color {
    Color(uiColor: dynamicUIColor(light: light, dark: dark))
  }

  private static func dynamicUIColor(light: UIColor, dark: UIColor) -> UIColor {
    UIColor { traits in
      traits.userInterfaceStyle == .dark ? dark : light
    }
  }

  private static func hex(_ value: UInt, alpha: CGFloat = 1.0) -> UIColor {
    UIColor(
      red: CGFloat((value >> 16) & 0xFF) / 255.0,
      green: CGFloat((value >> 8) & 0xFF) / 255.0,
      blue: CGFloat(value & 0xFF) / 255.0,
      alpha: alpha
    )
  }
}

private struct NativeAuthResponse: Decodable {
  let userId: String
  let username: String
  let secureId: String
  let token: String
  let tokenExpiresAt: String?
  let publicKey: String?
  let encryptedPrivateKey: String?
  let phoneNumber: String?
}

struct NativeAuthResult {
  let config: AppSessionConfig
  let recoverySecret: String?
}

enum NativeAuthService {
  static func signUp(
    username: String,
    apiBaseURLString: String,
    transportMode: PacketTransportMode
  ) async throws -> NativeAuthResult {
    let recoverySecret = try NativeAuthCrypto.generateRecoverySecret()
    let keyPair = try NativeAuthCrypto.generateKeyPair()
    let derivedKey = try NativeAuthCrypto.deriveKey(
      passphrase: recoverySecret,
      salt: username
    )
    let encryptedPrivateKey = try NativeAuthCrypto.encryptPrivateKey(
      keyPair.privateKeyPem,
      using: derivedKey
    )
    let response = try await request(
      apiBaseURLString: apiBaseURLString,
      path: "register",
      body: [
        "username": username,
        // v3: the server never sees `recoverySecret` itself — only one-way
        // derivations of it. `credential` becomes the account lookup handle,
        // `password` the auth secret. The KEK stays derived from the raw secret
        // on-device and is never transmitted in any form.
        "credential": NativeAuthCrypto.lookupId(from: recoverySecret),
        "password": NativeAuthCrypto.authSecret(from: recoverySecret),
        "deviceId": UUID().uuidString,
        "identityKey": "v3",
        "publicKey": keyPair.publicKeyPem,
        "encryptedPrivateKey": encryptedPrivateKey,
      ]
    )

    let config = AppSessionConfig(
      apiBaseURLString: apiBaseURLString,
      socketURLString: nil,
      userID: response.userId,
      authToken: response.token,
      transportMode: transportMode,
      username: response.username,
      secureID: response.secureId,
      publicKeyPem: keyPair.publicKeyPem,
      privateKeyPem: keyPair.privateKeyPem,
      encryptedPrivateKey: encryptedPrivateKey,
      tokenExpiresAt: response.tokenExpiresAt,
      identityKey: "v3",
      phoneNumber: response.phoneNumber
    )
    return NativeAuthResult(config: config, recoverySecret: recoverySecret)
  }

  static func signIn(
    secret: String,
    apiBaseURLString: String,
    transportMode: PacketTransportMode
  ) async throws -> NativeAuthResult {
    let deviceId = UUID().uuidString
    let lookupId = NativeAuthCrypto.lookupId(from: secret)
    let authSecret = NativeAuthCrypto.authSecret(from: secret)

    // v3 first. A pre-v3 account's `secure_id` and `password_hash` are derived
    // from the raw secret, so this lookup simply misses and we fall through —
    // there is no way to tell the two account generations apart up front, and
    // asking the server which one it is would leak exactly what we are hiding.
    var usedLegacyIdentity = false
    let response: NativeAuthResponse
    do {
      response = try await request(
        apiBaseURLString: apiBaseURLString,
        path: "login",
        body: [
          "credential": lookupId,
          "password": authSecret,
          "deviceId": deviceId,
        ]
      )
    } catch {
      // Legacy accounts only. The raw secret goes to the server this one last
      // time, because it is the only thing a pre-v3 record can be authenticated
      // against. The upgrade below then re-keys the account so that never
      // happens again for this user. A wrong secret costs one extra request,
      // which is the right trade for not having to distinguish a 401 from a
      // dropped connection here.
      response = try await request(
        apiBaseURLString: apiBaseURLString,
        path: "login",
        body: [
          "credential": secret,
          "password": secret,
          "deviceId": deviceId,
        ]
      )
      usedLegacyIdentity = true
    }
    guard let encryptedPrivateKey = response.encryptedPrivateKey, !encryptedPrivateKey.isEmpty else {
      throw NativeAuthError.message("Key sync unavailable for this account.")
    }

    let derivedKey = try NativeAuthCrypto.deriveKey(
      passphrase: secret,
      salt: response.username
    )
    let privateKeyPem = try NativeAuthCrypto.decryptPrivateKey(
      encryptedPrivateKey,
      using: derivedKey
    )
    let publicKeyPem = try NativeAuthCrypto.derivePublicKeyPem(from: privateKeyPem)

    // Only after the private key has actually been unwrapped — re-keying an
    // account whose key we could not open would strand the user on credentials
    // that no longer match anything they can use.
    var upgradedSecureId: String?
    if usedLegacyIdentity {
      upgradedSecureId = await upgradeIdentityToV3(
        apiBaseURLString: apiBaseURLString,
        token: response.token,
        recoverySecret: secret
      )
    }
    let upgradedToV3 = upgradedSecureId != nil

    let config = AppSessionConfig(
      apiBaseURLString: apiBaseURLString,
      socketURLString: nil,
      userID: response.userId,
      authToken: response.token,
      transportMode: transportMode,
      username: response.username,
      secureID: upgradedSecureId ?? response.secureId,
      publicKeyPem: publicKeyPem,
      privateKeyPem: privateKeyPem,
      encryptedPrivateKey: encryptedPrivateKey,
      tokenExpiresAt: response.tokenExpiresAt,
      identityKey: upgradedToV3 ? "v3" : (usedLegacyIdentity ? "v2" : "v3"),
      phoneNumber: response.phoneNumber
    )
    return NativeAuthResult(config: config, recoverySecret: nil)
  }

  /// Re-keys a pre-v3 account so the raw recovery secret is never sent again.
  ///
  /// Best-effort on purpose: a failure here must not block a login that has
  /// already succeeded. The account stays on v2 and the next sign-in retries.
  /// Note this rotates only `secure_id` and `password_hash` — it deliberately
  /// does **not** touch `encrypted_private_key`, because the KEK derivation is
  /// unchanged. That is what makes this migration non-destructive: the worst
  /// case is a login that has to fall back again, never lost key material.
  /// Returns the account's **new** `secureId` on success, or `nil` if the
  /// upgrade did not happen. The server rotates `secure_id` in lockstep with the
  /// password hash, and the client cannot recompute it (the pepper is
  /// server-side), so the fresh value has to be carried back into the session
  /// config — keeping the stale one would break the next secure-id login.
  private static func upgradeIdentityToV3(
    apiBaseURLString: String,
    token: String,
    recoverySecret: String
  ) async -> String? {
    do {
      let data = try await requestRaw(
        apiBaseURLString: apiBaseURLString,
        path: "upgrade-identity",
        body: [
          "credential": NativeAuthCrypto.lookupId(from: recoverySecret),
          "password": NativeAuthCrypto.authSecret(from: recoverySecret),
          "identityKey": "v3",
        ],
        bearerToken: token
      )
      guard
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let secureId = object["secureId"] as? String,
        !secureId.isEmpty
      else {
        return nil
      }
      return secureId
    } catch {
      return nil
    }
  }

  private static func request(
    apiBaseURLString: String,
    path: String,
    body: [String: Any]
  ) async throws -> NativeAuthResponse {
    let data = try await requestRaw(
      apiBaseURLString: apiBaseURLString, path: path, body: body)
    do {
      return try JSONDecoder().decode(NativeAuthResponse.self, from: data)
    } catch {
      throw NativeAuthError.message("The auth response could not be parsed.")
    }
  }

  /// The POST itself, without assuming the response decodes to
  /// `NativeAuthResponse` — the identity upgrade returns a different shape.
  @discardableResult
  private static func requestRaw(
    apiBaseURLString: String,
    path: String,
    body: [String: Any],
    bearerToken: String? = nil
  ) async throws -> Data {
    var base = apiBaseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasSuffix("/") {
      base.removeLast()
    }
    let apiPathBase = base.lowercased().hasSuffix("/api") ? base : "\(base)/api"
    guard let url = URL(string: "\(apiPathBase)/\(path)") else {
      throw NativeAuthError.message("Invalid API base URL.")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
    if let bearerToken, !bearerToken.isEmpty {
      request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

    let (data, response) = try await VibeHTTP.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw NativeAuthError.message("The server did not return a valid response.")
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      throw parseServerError(data: data, statusCode: httpResponse.statusCode)
    }
    return data
  }

  private static func parseServerError(data: Data, statusCode: Int) -> NativeAuthError {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let message = object["error"] as? String
    else {
      let body = String(data: data, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines)
      if let body, !body.isEmpty {
        let lowered = body.lowercased()
        if lowered.hasPrefix("<!doctype") || lowered.hasPrefix("<html") || lowered.contains("<body") {
          return .message("Request failed with status \(statusCode).")
        }
        return .message(String(body.prefix(180)))
      }
      return .message("Request failed with status \(statusCode).")
    }
    return .message(message)
  }
}

private enum NativeAuthError: LocalizedError {
  case message(String)

  var errorDescription: String? {
    switch self {
    case let .message(message):
      return message
    }
  }
}

private struct NativeAuthKeyPair {
  let publicKeyPem: String
  let privateKeyPem: String
}

private enum NativeAuthCrypto {
  private static let rsaAlgorithmIdentifier: [UInt8] = [
    0x30, 0x0d,
    0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01,
    0x05, 0x00,
  ]

  static func normalizeUsername(_ value: String?) -> String {
    value?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased() ?? ""
  }

  static func normalizeSecret(_ value: String?) -> String {
    let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
    return raw.filter { $0.isHexDigit || $0 == "-" }
  }

  static func isValidUsername(_ username: String) -> Bool {
    guard (3...30).contains(username.count) else { return false }
    return username.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil
  }

  static func generateRecoverySecret() throws -> String {
    let bytes = try randomBytes(count: 24)
    let hex = bytes.map { String(format: "%02X", $0) }.joined()
    return stride(from: 0, to: hex.count, by: 4).map { index in
      let start = hex.index(hex.startIndex, offsetBy: index)
      let end = hex.index(start, offsetBy: min(4, hex.distance(from: start, to: hex.endIndex)), limitedBy: hex.endIndex) ?? hex.endIndex
      return String(hex[start..<end])
    }.joined(separator: "-")
  }

  /// Domain-separated values derived from the recovery secret, so that nothing
  /// the server receives can reconstruct the key-wrapping passphrase.
  ///
  /// The recovery secret used to be sent verbatim as **both** the login
  /// `credential` and the `password`, while the *same* string was also the
  /// PBKDF2 passphrase that wraps the RSA private key — and the server stores a
  /// copy of that wrapped key. Holding both halves, the server could unwrap the
  /// private key at any login and read every message the account had ever sent.
  /// That made end-to-end encryption nominal rather than real.
  ///
  /// HKDF is one-way, so a server holding `lookupId` and `authSecret` cannot
  /// recover the recovery secret and therefore cannot derive the KEK. This only
  /// works because the recovery secret is 24 random bytes (192 bits) — see
  /// `generateRecoverySecret`. It would **not** be sound for a user-chosen
  /// password, which is why one must never be introduced here.
  ///
  /// `deriveKey` below is deliberately left untouched. Keeping the KEK
  /// derivation bit-for-bit identical means `encrypted_private_key` never has to
  /// be re-wrapped, so no migration can destroy key material: the worst failure
  /// is a rejected login, which is recoverable. Re-wrapping would not be.
  static func lookupId(from recoverySecret: String) -> String {
    hkdfHex(recoverySecret, info: "vibe/lookup/v1")
  }

  static func authSecret(from recoverySecret: String) -> String {
    hkdfHex(recoverySecret, info: "vibe/auth/v1")
  }

  private static func hkdfHex(_ secret: String, info: String) -> String {
    let derived = HKDF<SHA256>.deriveKey(
      inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)),
      info: Data(info.utf8),
      outputByteCount: 32
    )
    return derived.withUnsafeBytes { raw in
      raw.map { String(format: "%02X", $0) }.joined()
    }
  }

  static func generateKeyPair() throws -> NativeAuthKeyPair {
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeySizeInBits as String: 2048,
    ]
    var error: Unmanaged<CFError>?
    guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
      throw NativeAuthError.message(
        error?.takeRetainedValue().localizedDescription ?? "Key generation failed.")
    }
    guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
      throw NativeAuthError.message("Public key generation failed.")
    }
    guard let privateKeyData = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
      throw NativeAuthError.message(
        error?.takeRetainedValue().localizedDescription ?? "Private key export failed.")
    }
    guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
      throw NativeAuthError.message(
        error?.takeRetainedValue().localizedDescription ?? "Public key export failed.")
    }

    let normalizedPrivate = containsRSAAlgorithmIdentifier(privateKeyData)
      ? privateKeyData
      : wrapPKCS1PrivateKeyInPKCS8(privateKeyData)
    let normalizedPublic = containsRSAAlgorithmIdentifier(publicKeyData)
      ? publicKeyData
      : wrapRSAPublicKeyInSPKI(publicKeyData)

    return NativeAuthKeyPair(
      publicKeyPem: makePEM(label: "PUBLIC KEY", data: normalizedPublic),
      privateKeyPem: makePEM(label: "PRIVATE KEY", data: normalizedPrivate)
    )
  }

  static func deriveKey(passphrase: String, salt: String) throws -> Data {
    let passphraseData = Data(passphrase.utf8)
    let saltData = Data(normalizeUsername(salt).utf8)
    var derivedKey = Data(count: 32)

    let status = derivedKey.withUnsafeMutableBytes { derivedBytes in
      passphraseData.withUnsafeBytes { passphraseBytes in
        saltData.withUnsafeBytes { saltBytes in
          CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2),
            passphraseBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
            passphraseData.count,
            saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
            saltData.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
            600_000,
            derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
            32
          )
        }
      }
    }

    guard status == kCCSuccess else {
      throw NativeAuthError.message("Key derivation failed.")
    }
    return derivedKey
  }

  static func encryptPrivateKey(_ privateKeyPem: String, using derivedKey: Data) throws -> String {
    let privateKeyData = try decodePEM(privateKeyPem)
    let iv = try randomBytes(count: 12)
    let nonce = try AES.GCM.Nonce(data: iv)
    let sealed = try AES.GCM.seal(
      privateKeyData,
      using: SymmetricKey(data: derivedKey),
      nonce: nonce
    )
    var combined = Data()
    combined.append(iv)
    combined.append(sealed.ciphertext)
    combined.append(sealed.tag)
    return combined.base64EncodedString()
  }

  static func decryptPrivateKey(_ encryptedBase64: String, using derivedKey: Data) throws -> String {
    guard let combined = Data(base64Encoded: encryptedBase64), combined.count > 28 else {
      throw NativeAuthError.message("Encrypted key payload is invalid.")
    }
    let iv = combined.prefix(12)
    let ciphertext = combined.dropFirst(12).dropLast(16)
    let tag = combined.suffix(16)
    let nonce = try AES.GCM.Nonce(data: iv)
    let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
    let decrypted = try AES.GCM.open(sealedBox, using: SymmetricKey(data: derivedKey))

    if let pem = String(data: decrypted, encoding: .utf8),
      pem.contains("BEGIN")
    {
      return pem
        .replacingOccurrences(of: "\\r\\n", with: "\n")
        .replacingOccurrences(of: "\\n", with: "\n")
    }
    let label = containsRSAAlgorithmIdentifier(decrypted) ? "PRIVATE KEY" : "RSA PRIVATE KEY"
    return makePEM(label: label, data: decrypted)
  }

  static func derivePublicKeyPem(from privateKeyPem: String) throws -> String {
    guard let privateKey = makeSecKey(fromPrivateKeyPem: privateKeyPem),
      let publicKey = SecKeyCopyPublicKey(privateKey)
    else {
      throw NativeAuthError.message("Private key import failed.")
    }
    var error: Unmanaged<CFError>?
    guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
      throw NativeAuthError.message(
        error?.takeRetainedValue().localizedDescription ?? "Public key export failed.")
    }
    let normalizedPublic = containsRSAAlgorithmIdentifier(publicKeyData)
      ? publicKeyData
      : wrapRSAPublicKeyInSPKI(publicKeyData)
    return makePEM(label: "PUBLIC KEY", data: normalizedPublic)
  }

  private static func randomBytes(count: Int) throws -> Data {
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes { buffer in
      guard let baseAddress = buffer.baseAddress else { return errSecParam }
      return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
    }
    guard status == errSecSuccess else {
      throw NativeAuthError.message("Secure random generation failed.")
    }
    return data
  }

  private static func decodePEM(_ pem: String) throws -> Data {
    let normalized = pem
      .replacingOccurrences(of: "\\r\\n", with: "\n")
      .replacingOccurrences(of: "\\n", with: "\n")
      .replacingOccurrences(of: "\\r", with: "\n")
      .replacingOccurrences(of: "-----BEGIN [^-]+-----", with: "", options: .regularExpression)
      .replacingOccurrences(of: "-----END [^-]+-----", with: "", options: .regularExpression)
    guard let data = Data(base64Encoded: normalized, options: .ignoreUnknownCharacters) else {
      throw NativeAuthError.message("Key parsing failed.")
    }
    return data
  }

  private static func makePEM(label: String, data: Data) -> String {
    let base64 = data.base64EncodedString()
    let lines = stride(from: 0, to: base64.count, by: 64).map { index -> String in
      let start = base64.index(base64.startIndex, offsetBy: index)
      let end = base64.index(start, offsetBy: min(64, base64.distance(from: start, to: base64.endIndex)), limitedBy: base64.endIndex) ?? base64.endIndex
      return String(base64[start..<end])
    }
    return "-----BEGIN \(label)-----\n\(lines.joined(separator: "\n"))\n-----END \(label)-----"
  }

  private static func makeSecKey(fromPrivateKeyPem privateKeyPem: String) -> SecKey? {
    guard let keyData = try? decodePEM(privateKeyPem) else { return nil }
    let normalizedData: Data
    if privateKeyPem.contains("BEGIN PRIVATE KEY") && !privateKeyPem.contains("BEGIN RSA PRIVATE KEY") {
      normalizedData = extractPKCS1FromPKCS8(keyData) ?? keyData
    } else {
      normalizedData = keyData
    }
    let attrs: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
    ]
    var error: Unmanaged<CFError>?
    let key = SecKeyCreateWithData(normalizedData as CFData, attrs as CFDictionary, &error)
    _ = error?.takeRetainedValue()
    return key
  }

  private static func extractPKCS1FromPKCS8(_ data: Data) -> Data? {
    let bytes = [UInt8](data)
    var offset = 0
    guard offset < bytes.count, bytes[offset] == 0x30 else { return nil }
    offset += 1
    guard let sequenceLength = readDERLength(bytes: bytes, offset: &offset) else { return nil }
    let sequenceEnd = offset + sequenceLength
    guard sequenceEnd <= bytes.count else { return nil }
    guard offset < sequenceEnd, bytes[offset] == 0x02 else { return nil }
    offset += 1
    guard let versionLength = readDERLength(bytes: bytes, offset: &offset) else { return nil }
    offset += versionLength
    guard offset < sequenceEnd, bytes[offset] == 0x30 else { return nil }
    offset += 1
    guard let algorithmLength = readDERLength(bytes: bytes, offset: &offset) else { return nil }
    offset += algorithmLength
    guard offset < sequenceEnd, bytes[offset] == 0x04 else { return nil }
    offset += 1
    guard let keyLength = readDERLength(bytes: bytes, offset: &offset) else { return nil }
    let start = offset
    let end = start + keyLength
    guard end <= sequenceEnd else { return nil }
    return data.subdata(in: start..<end)
  }

  private static func readDERLength(bytes: [UInt8], offset: inout Int) -> Int? {
    guard offset < bytes.count else { return nil }
    let first = Int(bytes[offset])
    offset += 1
    if (first & 0x80) == 0 {
      return first
    }
    let count = first & 0x7f
    guard count > 0, count <= 4, offset + count <= bytes.count else { return nil }
    var value = 0
    for _ in 0..<count {
      value = (value << 8) | Int(bytes[offset])
      offset += 1
    }
    return value
  }

  private static func containsRSAAlgorithmIdentifier(_ data: Data) -> Bool {
    let bytes = [UInt8](data)
    guard bytes.count >= rsaAlgorithmIdentifier.count else { return false }
    let maxIndex = bytes.count - rsaAlgorithmIdentifier.count
    if maxIndex < 0 {
      return false
    }
    for index in 0...maxIndex {
      let slice = Array(bytes[index..<(index + rsaAlgorithmIdentifier.count)])
      if slice == rsaAlgorithmIdentifier {
        return true
      }
    }
    return false
  }

  private static func derEncodeLength(_ length: Int) -> Data {
    if length < 0x80 {
      return Data([UInt8(length)])
    }
    var remaining = length
    var bytes: [UInt8] = []
    while remaining > 0 {
      bytes.insert(UInt8(remaining & 0xff), at: 0)
      remaining >>= 8
    }
    return Data([0x80 | UInt8(bytes.count)] + bytes)
  }

  private static func wrapPKCS1PrivateKeyInPKCS8(_ pkcs1: Data) -> Data {
    let version = Data([0x02, 0x01, 0x00])
    let algorithm = Data(rsaAlgorithmIdentifier)
    let octet = Data([0x04]) + derEncodeLength(pkcs1.count) + pkcs1
    let body = version + algorithm + octet
    return Data([0x30]) + derEncodeLength(body.count) + body
  }

  private static func wrapRSAPublicKeyInSPKI(_ pkcs1: Data) -> Data {
    let algorithm = Data(rsaAlgorithmIdentifier)
    let bitStringPayload = Data([0x00]) + pkcs1
    let bitString = Data([0x03]) + derEncodeLength(bitStringPayload.count) + bitStringPayload
    let body = algorithm + bitString
    return Data([0x30]) + derEncodeLength(body.count) + body
  }
}
