import UIKit

final class ChatAgentConfigViewController: UIViewController {
  var chatId: String = ""
  var agentConfig: [String: Any]?
  var documents: [(id: String, name: String, url: String)] = []
  var onSave: (([String: Any]) -> Void)?
  var onDelete: (() -> Void)?

  private let scrollView = UIScrollView()
  private let mainStack = UIStackView()

  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  
  private let documentsLabel = UILabel()
  private let documentsStack = UIStackView()

  private let modelCard = UIView()
  private let modelLabel = UILabel()

  private let nameLabel = UILabel()
  private let nameField = UITextField()
  private let promptLabel = UILabel()
  private let generatePromptButton = UIButton(type: .system)
  private let generateInputLabel = UILabel()
  private let generateInputField = UITextField()
  private let promptTextView = UITextView()
  private let promptHintLabel = UILabel()
  private let toolsLabel = UILabel()
  private let toolsCardContainer = UIView()
  private let toolsCardStack = UIStackView()
  private let enabledLabel = UILabel()
  private let enabledToggle = UISwitch()

  private let deleteButton = UIButton(type: .system)

  private struct Theme {
    static let background = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
    static let cardBackground = UIColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1.0)
    static let primaryText = UIColor.white
    static let secondaryText = UIColor(white: 0.65, alpha: 1.0)
    static let accent = ChatListAppearance.brandAccentFallback
  }

  private let toolOptions: [(id: String, title: String, subtitle: String)] = [
    ("search_google", "Web Search", "Search Google for up-to-date results"),
    ("analyze_image", "Image Analysis", "Understand images and OCR text"),
    ("analyze_document", "Document Analysis", "Read and summarize document files"),
    ("create_document", "Create Document", "Generate formatted document drafts"),
  ]
  private var toolTogglesById: [String: UISwitch] = [:]

  override func viewDidLoad() {
    super.viewDidLoad()
    configureNavigation()
    configureViews()
    setupConstraints()
  }

  // Layout is handled by AutoLayout constraints in configureViews and setupConstraints.

  private func configureNavigation() {
    navigationItem.title = agentConfig == nil ? "Add AI Agent" : "Edit AI Agent"
    navigationItem.largeTitleDisplayMode = .never

    let saveTitle = agentConfig == nil ? "Create" : "Save"
    let saveItem = UIBarButtonItem(
      title: saveTitle, style: .prominent, target: self, action: #selector(handleSave))
    navigationItem.rightBarButtonItem = saveItem

    if navigationController?.viewControllers.first === self || presentingViewController != nil {
      navigationItem.leftBarButtonItem = UIBarButtonItem(
        barButtonSystemItem: .close,
        target: self,
        action: #selector(handleCancel)
      )
    }
    
    let appearance = UINavigationBarAppearance()
    appearance.configureWithOpaqueBackground()
    appearance.backgroundColor = Theme.background
    appearance.titleTextAttributes = [.foregroundColor: Theme.primaryText]
    navigationController?.navigationBar.standardAppearance = appearance
    navigationController?.navigationBar.scrollEdgeAppearance = appearance
    navigationController?.navigationBar.tintColor = Theme.accent
  }

  private func configureViews() {
    view.backgroundColor = Theme.background

    scrollView.keyboardDismissMode = .interactive
    scrollView.alwaysBounceVertical = true
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scrollView)

    mainStack.axis = .vertical
    mainStack.spacing = 28
    mainStack.isLayoutMarginsRelativeArrangement = true
    mainStack.layoutMargins = UIEdgeInsets(top: 24, left: 20, bottom: 40, right: 20)
    mainStack.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(mainStack)

    // MARK: - Header Section
    let headerStack = UIStackView()
    headerStack.axis = .vertical
    headerStack.spacing = 4
    
    titleLabel.font = UIFont.systemFont(ofSize: 32.0, weight: .bold)
    titleLabel.textColor = Theme.primaryText
    titleLabel.text = "Agent Settings"
    headerStack.addArrangedSubview(titleLabel)

    subtitleLabel.font = UIFont.systemFont(ofSize: 15.0, weight: .medium)
    subtitleLabel.textColor = Theme.secondaryText
    subtitleLabel.text = "Single native model backend"
    headerStack.addArrangedSubview(subtitleLabel)
    
    mainStack.addArrangedSubview(headerStack)

    // MARK: - Model Card
    modelCard.backgroundColor = Theme.cardBackground
    modelCard.layer.cornerRadius = 14.0
    modelCard.layer.cornerCurve = .continuous
    
    modelLabel.font = UIFont.systemFont(ofSize: 15.0, weight: .semibold)
    modelLabel.textColor = Theme.primaryText
    modelLabel.text = "Model: Native default"
    modelLabel.translatesAutoresizingMaskIntoConstraints = false
    modelCard.addSubview(modelLabel)
    
    mainStack.addArrangedSubview(modelCard)

    // MARK: - Agent Name
    let nameStack = UIStackView()
    nameStack.axis = .vertical
    nameStack.spacing = 8
    
    nameLabel.font = UIFont.systemFont(ofSize: 13.0, weight: .bold)
    nameLabel.textColor = Theme.secondaryText
    nameLabel.text = "AGENT NAME"
    nameStack.addArrangedSubview(nameLabel)

    nameField.font = UIFont.systemFont(ofSize: 16.0, weight: .medium)
    nameField.textColor = Theme.primaryText
    nameField.layer.cornerRadius = 12.0
    nameField.layer.cornerCurve = .continuous
    nameField.backgroundColor = Theme.cardBackground
    nameField.leftView = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 14.0, height: 1.0))
    nameField.leftViewMode = .always
    nameField.attributedPlaceholder = NSAttributedString(
      string: "Vibe AI",
      attributes: [.foregroundColor: Theme.secondaryText.withAlphaComponent(0.5)]
    )
    nameField.text = (agentConfig?["name"] as? String) ?? ""
    nameStack.addArrangedSubview(nameField)
    
    mainStack.addArrangedSubview(nameStack)

    // MARK: - System Prompt
    let promptSectionStack = UIStackView()
    promptSectionStack.axis = .vertical
    promptSectionStack.spacing = 16
    
    let promptHeaderStack = UIStackView()
    promptHeaderStack.axis = .horizontal
    promptHeaderStack.alignment = .center
    
    promptLabel.font = UIFont.systemFont(ofSize: 13.0, weight: .bold)
    promptLabel.textColor = Theme.secondaryText
    promptLabel.text = "SYSTEM PROMPT"
    promptHeaderStack.addArrangedSubview(promptLabel)
    
    let spacer = UIView()
    promptHeaderStack.addArrangedSubview(spacer)

    generatePromptButton.setTitle("Generate", for: .normal)
    generatePromptButton.titleLabel?.font = UIFont.systemFont(ofSize: 13.0, weight: .bold)
    generatePromptButton.tintColor = Theme.accent
    generatePromptButton.backgroundColor = Theme.cardBackground
    generatePromptButton.layer.cornerRadius = 14.0
    generatePromptButton.layer.cornerCurve = .continuous
    generatePromptButton.contentEdgeInsets = UIEdgeInsets(top: 6.0, left: 12.0, bottom: 6.0, right: 12.0)
    generatePromptButton.addTarget(self, action: #selector(handleGeneratePromptTapped), for: .touchUpInside)
    promptHeaderStack.addArrangedSubview(generatePromptButton)
    
    promptSectionStack.addArrangedSubview(promptHeaderStack)
    
    let genInputStack = UIStackView()
    genInputStack.axis = .vertical
    genInputStack.spacing = 6
    
    generateInputLabel.font = UIFont.systemFont(ofSize: 12.0, weight: .bold)
    generateInputLabel.textColor = Theme.secondaryText
    generateInputLabel.text = "GENERATE FROM INPUT"
    genInputStack.addArrangedSubview(generateInputLabel)

    generateInputField.font = UIFont.systemFont(ofSize: 15.0, weight: .regular)
    generateInputField.textColor = Theme.primaryText
    generateInputField.layer.cornerRadius = 12.0
    generateInputField.layer.cornerCurve = .continuous
    generateInputField.backgroundColor = Theme.cardBackground
    generateInputField.leftView = UIView(frame: CGRect(x: 0.0, y: 0.0, width: 14.0, height: 1.0))
    generateInputField.leftViewMode = .always
    generateInputField.attributedPlaceholder = NSAttributedString(
      string: "e.g. Helpful PM assistant for sprint planning",
      attributes: [.foregroundColor: Theme.secondaryText.withAlphaComponent(0.5)]
    )
    generateInputField.autocapitalizationType = .sentences
    genInputStack.addArrangedSubview(generateInputField)
    
    promptSectionStack.addArrangedSubview(genInputStack)

    let textViewContainer = UIView()
    textViewContainer.backgroundColor = Theme.cardBackground
    textViewContainer.layer.cornerRadius = 12.0
    textViewContainer.layer.cornerCurve = .continuous
    
    promptTextView.font = UIFont.systemFont(ofSize: 16.0, weight: .regular)
    promptTextView.textColor = Theme.primaryText
    promptTextView.backgroundColor = .clear
    promptTextView.textContainerInset = UIEdgeInsets(top: 14.0, left: 10.0, bottom: 14.0, right: 10.0)
    promptTextView.text = normalizedPrompt(from: agentConfig)
    promptTextView.delegate = self
    promptTextView.translatesAutoresizingMaskIntoConstraints = false
    textViewContainer.addSubview(promptTextView)

    promptHintLabel.font = UIFont.systemFont(ofSize: 15.0, weight: .regular)
    promptHintLabel.textColor = Theme.secondaryText.withAlphaComponent(0.6)
    promptHintLabel.numberOfLines = 0
    promptHintLabel.text = "Describe how this agent should behave in the group."
    promptHintLabel.translatesAutoresizingMaskIntoConstraints = false
    textViewContainer.addSubview(promptHintLabel)
    
    promptSectionStack.addArrangedSubview(textViewContainer)
    mainStack.addArrangedSubview(promptSectionStack)

    // MARK: - Tools
    let initialEnabledTools = Set(currentEnabledTools())
    let toolsSectionStack = UIStackView()
    toolsSectionStack.axis = .vertical
    toolsSectionStack.spacing = 8
    
    toolsLabel.font = UIFont.systemFont(ofSize: 13.0, weight: .bold)
    toolsLabel.textColor = Theme.secondaryText
    toolsLabel.text = "ENABLED TOOLS"
    toolsSectionStack.addArrangedSubview(toolsLabel)

    toolsCardContainer.backgroundColor = Theme.cardBackground
    toolsCardContainer.layer.cornerRadius = 14.0
    toolsCardContainer.layer.cornerCurve = .continuous
    
    toolsCardStack.axis = .vertical
    toolsCardStack.spacing = 0
    toolsCardStack.translatesAutoresizingMaskIntoConstraints = false
    toolsCardContainer.addSubview(toolsCardStack)
    
    for (index, option) in toolOptions.enumerated() {
      let row = UIView()
      
      let title = UILabel()
      title.font = UIFont.systemFont(ofSize: 15.0, weight: .bold)
      title.textColor = Theme.primaryText
      title.text = option.title
      title.translatesAutoresizingMaskIntoConstraints = false
      row.addSubview(title)

      let subtitle = UILabel()
      subtitle.font = UIFont.systemFont(ofSize: 13.0, weight: .medium)
      subtitle.textColor = Theme.secondaryText
      subtitle.text = option.subtitle
      subtitle.translatesAutoresizingMaskIntoConstraints = false
      row.addSubview(subtitle)

      let toggle = UISwitch()
      toggle.onTintColor = Theme.accent
      toggle.isOn = initialEnabledTools.contains(option.id)
      toggle.translatesAutoresizingMaskIntoConstraints = false
      row.addSubview(toggle)
      
      NSLayoutConstraint.activate([
        row.heightAnchor.constraint(equalToConstant: 64),
        
        title.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
        title.topAnchor.constraint(equalTo: row.topAnchor, constant: 12),
        
        subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
        subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
        subtitle.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -16),
        
        toggle.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
        toggle.centerYAnchor.constraint(equalTo: row.centerYAnchor)
      ])
      
      if index < toolOptions.count - 1 {
        let separator = UIView()
        separator.backgroundColor = Theme.background
        separator.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            separator.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1)
        ])
      }

      toolsCardStack.addArrangedSubview(row)
      toolTogglesById[option.id] = toggle
    }
    
    toolsSectionStack.addArrangedSubview(toolsCardContainer)
    mainStack.addArrangedSubview(toolsSectionStack)

    // MARK: - Documents
    let docsSectionStack = UIStackView()
    docsSectionStack.axis = .vertical
    docsSectionStack.spacing = 8
    
    documentsLabel.font = UIFont.systemFont(ofSize: 13.0, weight: .bold)
    documentsLabel.textColor = Theme.secondaryText
    documentsLabel.text = "AGENT DOCUMENTS"
    docsSectionStack.addArrangedSubview(documentsLabel)
    
    documentsStack.axis = .vertical
    documentsStack.spacing = 10.0
    documentsStack.distribution = .equalSpacing
    docsSectionStack.addArrangedSubview(documentsStack)
    
    if !documents.isEmpty {
      for (index, doc) in documents.enumerated() {
        let row = UIControl()
        row.backgroundColor = Theme.cardBackground
        row.layer.cornerRadius = 12.0
        row.layer.cornerCurve = .continuous
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(equalToConstant: 52).isActive = true
        row.tag = index
        row.addTarget(self, action: #selector(handleDocumentTapped(_:)), for: .touchUpInside)
        row.addTarget(self, action: #selector(handleDocumentTouchDown(_:)), for: [.touchDown, .touchDragEnter])
        row.addTarget(self, action: #selector(handleDocumentTouchUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchDragExit, .touchCancel])
        
        let icon = UIImageView(image: UIImage(systemName: "doc.text.fill"))
        icon.tintColor = Theme.accent
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(icon)
        
        let label = UILabel()
        label.text = doc.name
        label.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        label.textColor = Theme.primaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)

        let chevron = UIImageView(
          image: UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
          ))
        chevron.tintColor = Theme.secondaryText.withAlphaComponent(0.5)
        chevron.contentMode = .scaleAspectFit
        chevron.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(chevron)
        
        NSLayoutConstraint.activate([
          icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
          icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
          icon.widthAnchor.constraint(equalToConstant: 22),
          icon.heightAnchor.constraint(equalToConstant: 22),
          
          label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
          label.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -10),
          label.centerYAnchor.constraint(equalTo: row.centerYAnchor),

          chevron.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
          chevron.centerYAnchor.constraint(equalTo: row.centerYAnchor),
          chevron.widthAnchor.constraint(equalToConstant: 12),
          chevron.heightAnchor.constraint(equalToConstant: 16),
        ])
        
        documentsStack.addArrangedSubview(row)
      }
      mainStack.addArrangedSubview(docsSectionStack)
    }

    // MARK: - Enabled Toggle
    let enabledStack = UIStackView()
    enabledStack.axis = .horizontal
    enabledStack.alignment = .center
    
    enabledLabel.font =  UIFont.systemFont(ofSize: 16.0, weight: .bold)
    enabledLabel.textColor = Theme.primaryText
    enabledLabel.text = "Agent Enabled"
    enabledStack.addArrangedSubview(enabledLabel)
    
    let enabledSpacer = UIView()
    enabledStack.addArrangedSubview(enabledSpacer)

    enabledToggle.onTintColor = Theme.accent
    enabledToggle.isOn = normalizedEnabled(from: agentConfig, defaultValue: true)
    enabledStack.addArrangedSubview(enabledToggle)
    
    let enabledCard = UIView()
    enabledCard.backgroundColor = Theme.cardBackground
    enabledCard.layer.cornerRadius = 14.0
    enabledCard.layer.cornerCurve = .continuous
    
    enabledStack.translatesAutoresizingMaskIntoConstraints = false
    enabledCard.addSubview(enabledStack)
    
    NSLayoutConstraint.activate([
      enabledCard.heightAnchor.constraint(equalToConstant: 60),
      enabledStack.topAnchor.constraint(equalTo: enabledCard.topAnchor),
      enabledStack.leadingAnchor.constraint(equalTo: enabledCard.leadingAnchor, constant: 16),
      enabledStack.trailingAnchor.constraint(equalTo: enabledCard.trailingAnchor, constant: -16),
      enabledStack.bottomAnchor.constraint(equalTo: enabledCard.bottomAnchor)
    ])
    
    mainStack.addArrangedSubview(enabledCard)
    mainStack.setCustomSpacing(32, after: enabledCard)

    // MARK: - Delete Button
    if agentConfig != nil {
      deleteButton.setTitle("Remove Agent", for: .normal)
      deleteButton.titleLabel?.font = UIFont.systemFont(ofSize: 16.0, weight: .bold)
      deleteButton.setTitleColor(.systemRed, for: .normal)
      deleteButton.layer.cornerRadius = 14.0
      deleteButton.layer.cornerCurve = .continuous
      deleteButton.backgroundColor = Theme.cardBackground
      deleteButton.addTarget(self, action: #selector(handleDelete), for: .touchUpInside)
      mainStack.addArrangedSubview(deleteButton)
    }

    refreshPromptHintVisibility()
  }

  private func setupConstraints() {
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

      mainStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      mainStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      mainStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      mainStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
      mainStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
      
      modelCard.heightAnchor.constraint(equalToConstant: 52),
      modelLabel.leadingAnchor.constraint(equalTo: modelCard.leadingAnchor, constant: 16),
      modelLabel.centerYAnchor.constraint(equalTo: modelCard.centerYAnchor),
      
      nameField.heightAnchor.constraint(equalToConstant: 52),
      generateInputField.heightAnchor.constraint(equalToConstant: 48),
      
      promptTextView.topAnchor.constraint(equalTo: promptTextView.superview!.topAnchor),
      promptTextView.leadingAnchor.constraint(equalTo: promptTextView.superview!.leadingAnchor),
      promptTextView.trailingAnchor.constraint(equalTo: promptTextView.superview!.trailingAnchor),
      promptTextView.bottomAnchor.constraint(equalTo: promptTextView.superview!.bottomAnchor),
      promptTextView.superview!.heightAnchor.constraint(equalToConstant: 200),
      
      promptHintLabel.topAnchor.constraint(equalTo: promptTextView.superview!.topAnchor, constant: 14),
      promptHintLabel.leadingAnchor.constraint(equalTo: promptTextView.superview!.leadingAnchor, constant: 14),
      promptHintLabel.trailingAnchor.constraint(equalTo: promptTextView.superview!.trailingAnchor, constant: -14),
      
      toolsCardStack.topAnchor.constraint(equalTo: toolsCardContainer.topAnchor),
      toolsCardStack.leadingAnchor.constraint(equalTo: toolsCardContainer.leadingAnchor),
      toolsCardStack.trailingAnchor.constraint(equalTo: toolsCardContainer.trailingAnchor),
      toolsCardStack.bottomAnchor.constraint(equalTo: toolsCardContainer.bottomAnchor)
    ])
    
    if agentConfig != nil {
       deleteButton.heightAnchor.constraint(equalToConstant: 56).isActive = true
    }
  }

  @objc private func handleCancel() {
    closeEditor()
  }

  @objc private func handleSave() {
    let name = nameField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let prompt = promptTextView.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

    guard !prompt.isEmpty else {
      let alert = UIAlertController(
        title: "System Prompt Required",
        message: "Please enter a system prompt before saving this agent.",
        preferredStyle: .alert
      )
      alert.addAction(UIAlertAction(title: "OK", style: .default))
      present(alert, animated: true)
      return
    }
    let selectedTools = selectedEnabledTools()
    guard !selectedTools.isEmpty else {
      presentSimpleAlert(
        title: "Enable At Least One Tool",
        message: "Select at least one tool for this agent.")
      return
    }

    var config: [String: Any] = [
      "chat_id": chatId,
      "name": name.isEmpty ? "Vibe AI" : name,
      "system_prompt": prompt,
      "enabled": enabledToggle.isOn,
      "enabled_tools": selectedTools,
    ]
    if let existingId = agentConfig?["id"] {
      config["id"] = existingId
    }

    onSave?(config)
    closeEditor()
  }

  @objc private func handleDelete() {
    let alert = UIAlertController(
      title: "Remove AI Agent",
      message: "This will remove the agent and clear its memory. This action cannot be undone.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
    alert.addAction(
      UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
        self?.onDelete?()
        self?.closeEditor()
      })
    present(alert, animated: true)
  }

  private func closeEditor() {
    if let nav = navigationController, nav.viewControllers.count > 1 {
      nav.popViewController(animated: true)
      return
    }
    dismiss(animated: true)
  }

  private func refreshPromptHintVisibility() {
    promptHintLabel.isHidden = !(promptTextView.text ?? "").isEmpty
  }

  private func normalizedPrompt(from config: [String: Any]?) -> String {
    guard let config else { return "" }
    let snake =
      (config["system_prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !snake.isEmpty { return snake }
    return
      (config["systemPrompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private func normalizedEnabled(from config: [String: Any]?, defaultValue: Bool) -> Bool {
    guard let raw = config?["enabled"] else { return defaultValue }
    if let bool = raw as? Bool { return bool }
    if let number = raw as? NSNumber { return number.boolValue }
    if let string = raw as? String {
      switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "true", "1", "yes", "on":
        return true
      case "false", "0", "no", "off":
        return false
      default:
        break
      }
    }
    return defaultValue
  }

  private func currentEnabledTools() -> [String] {
    if let explicit = normalizedToolList(agentConfig?["enabled_tools"]), !explicit.isEmpty {
      return explicit
    }
    if let explicit = normalizedToolList(agentConfig?["enabledTools"]), !explicit.isEmpty {
      return explicit
    }
    return ["search_google", "analyze_image", "analyze_document", "create_document"]
  }

  @objc private func handleGeneratePromptTapped() {
    let input = generateInputField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !input.isEmpty else {
      generateInputField.becomeFirstResponder()
      return
    }
    let selectedTools = selectedEnabledTools()
    guard !selectedTools.isEmpty else {
      presentSimpleAlert(
        title: "Enable At Least One Tool",
        message: "Select at least one tool before generating.")
      return
    }
    generatePromptButton.isEnabled = false
    generatePromptButton.setTitle("Generating...", for: .normal)
    ChatEngine.shared.generateAgentPrompt(
      chatId: chatId,
      input: input,
      enabledTools: selectedTools
    ) { [weak self] payload in
      guard let self else { return }
      self.generatePromptButton.isEnabled = true
      self.generatePromptButton.setTitle("Generate", for: .normal)
      let generated =
        (payload?["systemPrompt"] as? String)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !generated.isEmpty else {
        self.presentSimpleAlert(
          title: "Generation Failed",
          message: "Could not generate a prompt. Try adjusting your input.")
        return
      }
      self.promptTextView.text = generated
      self.refreshPromptHintVisibility()
    }
  }

  private func selectedEnabledTools() -> [String] {
    var out: [String] = []
    for option in toolOptions {
      if toolTogglesById[option.id]?.isOn == true {
        out.append(option.id)
      }
    }
    return out
  }

  private func normalizedToolList(_ raw: Any?) -> [String]? {
    guard let rawList = raw as? [Any] else { return nil }
    let normalized =
      rawList
      .compactMap { item -> String? in
        if let text = item as? String {
          let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
          return trimmed.isEmpty ? nil : trimmed
        }
        if let number = item as? NSNumber {
          return number.stringValue
        }
        return nil
      }
    return normalized.isEmpty ? nil : normalized
  }

  @objc private func handleDocumentTapped(_ sender: UIControl) {
    let index = sender.tag
    guard index >= 0, index < documents.count else { return }
    let doc = documents[index]
    
    let isText = doc.name.lowercased().hasSuffix(".csv") || doc.name.lowercased().hasSuffix(".md") || doc.name.lowercased().hasSuffix(".txt") || doc.name.lowercased().hasSuffix(".json")
    guard isText else {
       if let url = URL(string: doc.url) {
           UIApplication.shared.open(url)
       }
       return
    }
    
    let overlay = UIView(frame: view.bounds)
    overlay.backgroundColor = UIColor.black.withAlphaComponent(0.4)
    overlay.alpha = 0.0
    view.addSubview(overlay)
    
    let indicator = UIActivityIndicatorView(style: .large)
    indicator.center = view.center
    indicator.startAnimating()
    overlay.addSubview(indicator)
    
    UIView.animate(withDuration: 0.2) { overlay.alpha = 1.0 }
    
    let cleanUrlString = doc.url.replacingOccurrences(of: "vibe://", with: "https://") 
    guard let url = URL(string: cleanUrlString) else {
      UIView.animate(withDuration: 0.2, animations: { overlay.alpha = 0.0 }) { _ in overlay.removeFromSuperview() }
      return
    }
    
    var request = URLRequest(url: url)
    if let authHeader = ChatEngine.shared.authorizationHeaderForAPI() {
       request.setValue(authHeader, forHTTPHeaderField: "Authorization")
    }
    
    let task = VibeHTTP.shared.dataTask(with: request) { [weak self] data, response, error in
       DispatchQueue.main.async {
          UIView.animate(withDuration: 0.2, animations: { overlay.alpha = 0.0 }) { _ in overlay.removeFromSuperview() }
          guard let self = self, let data = data, let text = String(data: data, encoding: .utf8) else {
             self?.presentSimpleAlert(title: "Error", message: "Failed to load document content.")
             return
          }
          let preview = AgentDocumentPreviewController(title: doc.name, text: text)
          let nav = UINavigationController(rootViewController: preview)
          self.present(nav, animated: true)
       }
    }
    task.resume()
  }

  @objc private func handleDocumentTouchDown(_ sender: UIControl) {
    UIView.animate(withDuration: 0.08) {
      sender.alpha = 0.72
      sender.transform = CGAffineTransform(scaleX: 0.992, y: 0.992)
    }
  }

  @objc private func handleDocumentTouchUp(_ sender: UIControl) {
    UIView.animate(withDuration: 0.16, delay: 0.0, options: [.curveEaseOut]) {
      sender.alpha = 1.0
      sender.transform = .identity
    }
  }

  private func presentSimpleAlert(title: String, message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true)
  }
}

extension ChatAgentConfigViewController: UITextViewDelegate {
  func textViewDidChange(_ textView: UITextView) {
    refreshPromptHintVisibility()
  }
}


private final class AgentDocumentPreviewController: UIViewController {
  private let previewTitle: String
  private let textContent: String
  private let textView = UITextView()

  init(title: String, text: String) {
    self.previewTitle = title
    self.textContent = text
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    title = previewTitle
    navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(handleDone))

    textView.translatesAutoresizingMaskIntoConstraints = false
    textView.isEditable = false
    textView.alwaysBounceVertical = true
    textView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    textView.text = textContent

    view.addSubview(textView)
    NSLayoutConstraint.activate([
      textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      textView.topAnchor.constraint(equalTo: view.topAnchor),
      textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
  }
  @objc private func handleDone() { dismiss(animated: true) }
}
