import UIKit

enum ChatAvatarKind: Equatable {
  case standard, savedMessages, archive
}

struct ChatAvatarDescriptor {
    let title: String
    let rawAvatarURI: String?
    let peerUserId: String?
    let chatId: String?
    let kind: ChatAvatarKind
    let isGroup: Bool
    let members: [[String: Any]]
    let preferPushAvatar: Bool
    let gradientColors: (UIColor, UIColor)?
}

final class ChatAvatarNodeView: UIView {
  private let gradientLayer = CAGradientLayer()
  private let fallbackImageView = UIImageView()
  private let imageView = UIImageView()
  private let initialsLabel = UILabel()

  private var currentImageKey: String?
  private var loadTask: Task<Void, Never>?
  private var loadGeneration: UInt = 0
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }
    
    private func setup() {
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        
        layer.addSublayer(gradientLayer)
        
        fallbackImageView.isUserInteractionEnabled = false
        fallbackImageView.contentMode = .scaleAspectFit
        fallbackImageView.tintColor = .white
        addSubview(fallbackImageView)
        
        initialsLabel.isUserInteractionEnabled = false
        initialsLabel.textAlignment = .center
        initialsLabel.textColor = .white
        initialsLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        initialsLabel.adjustsFontSizeToFitWidth = true
        initialsLabel.minimumScaleFactor = 0.1
        initialsLabel.baselineAdjustment = .alignCenters
        addSubview(initialsLabel)
        
        imageView.isUserInteractionEnabled = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
        
        clipsToBounds = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAvatarImageReplaced(_:)),
            name: ChatAvatarImageStore.didReplaceNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        gradientLayer.frame = bounds
        let iconInset = max(4, bounds.width * 0.30)
        fallbackImageView.frame = bounds.insetBy(dx: iconInset, dy: iconInset)
        imageView.frame = bounds
        initialsLabel.frame = bounds
        
        let corner = bounds.width / 2.0
        layer.cornerRadius = corner
        imageView.layer.cornerRadius = corner
        
        let fontSize = max(10, bounds.width * 0.4)
        if fontSize > 0 {
            initialsLabel.font = .systemFont(ofSize: fontSize, weight: .semibold)
        }
        
        CATransaction.commit()
    }
    
    static func fallbackInitials(from name: String) -> String {
        VibeAvatarFallback.initials(from: name)
    }

    /// Telegram-style room fallbacks use one clear glyph. Direct-person avatars retain
    /// their compact two-initial treatment when a full name is available.
    static func fallbackText(from name: String, isGroupOrChannel: Bool) -> String {
        guard isGroupOrChannel else { return fallbackInitials(from: name) }
        let parts = name.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
        guard let first = parts.first?.first else { return "" }
        return String(first).uppercased()
    }
    
    func configure(with descriptor: ChatAvatarDescriptor, isDark: Bool, renderingSide: CGFloat? = nil) {
        loadGeneration &+= 1
        let generation = loadGeneration
        loadTask?.cancel()
        loadTask = nil
        
        switch descriptor.kind {
        case .savedMessages, .archive:
            imageView.image = nil
            imageView.isHidden = true
            initialsLabel.isHidden = true
            fallbackImageView.isHidden = false
            currentImageKey = nil
            
            let colors: (UIColor, UIColor)
            if isDark {
                colors = (UIColor(red: 77/255.0, green: 217/255.0, blue: 229/255.0, alpha: 1),
                          UIColor(red: 43/255.0, green: 165/255.0, blue: 181/255.0, alpha: 1))
            } else {
                colors = (UIColor(red: 43/255.0, green: 165/255.0, blue: 181/255.0, alpha: 1),
                          UIColor(red: 0/255.0, green: 122/255.0, blue: 124/255.0, alpha: 1))
            }
            setGradient(colors, vertical: true)
            
            if descriptor.kind == .savedMessages {
                fallbackImageView.image = UIImage(systemName: "bookmark.fill")
            } else {
                fallbackImageView.image = UIImage(systemName: "archivebox.fill")
            }
            
        case .standard:
            fallbackImageView.isHidden = true
            
            let colors = descriptor.gradientColors ?? ChatProfileAppearanceStore.avatarColors(title: descriptor.title, peerUserId: descriptor.peerUserId, chatId: descriptor.chatId)
            setGradient(colors, vertical: true)
            
            initialsLabel.text = ChatAvatarNodeView.fallbackText(
                from: descriptor.title,
                isGroupOrChannel: descriptor.isGroup
            )
            
            var resolvedURLString = ChatAvatarURLResolver.resolve(
                rawAvatar: descriptor.rawAvatarURI,
                peerUserId: descriptor.peerUserId,
                chatId: descriptor.chatId,
                preferPushAvatar: descriptor.preferPushAvatar
            )
            if (resolvedURLString == nil || resolvedURLString!.isEmpty), let raw = descriptor.rawAvatarURI, !raw.isEmpty {
                resolvedURLString = raw
            }
            
            let usableSlots = GroupCompositeAvatar.slots(from: descriptor.members)
            let usable = Array(usableSlots.prefix(4))
            
            if let url = resolvedURLString, !url.isEmpty {
                let imageKey = "url_\(url)"
                if currentImageKey == imageKey && imageView.image != nil {
                    imageView.isHidden = false
                    initialsLabel.isHidden = true
                    return
                }
                if currentImageKey == imageKey && loadTask != nil {
                    return
                }
                
                if imageView.image == nil {
                    initialsLabel.isHidden = false
                    imageView.isHidden = true
                } else {
                    imageView.isHidden = false
                    initialsLabel.isHidden = true
                }
                
                currentImageKey = imageKey
                
                if let cached = ChatAvatarImageStore.cached(for: url) {
                    imageView.image = cached
                    imageView.isHidden = false
                    initialsLabel.isHidden = true
                } else {
                    loadTask = Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        let image = await ChatAvatarImageStore.load(from: url)
                        guard !Task.isCancelled, self.loadGeneration == generation,
                          self.currentImageKey == imageKey else { return }
                        self.loadTask = nil
                        if let img = image {
                            self.imageView.image = img
                            self.imageView.isHidden = false
                            self.initialsLabel.isHidden = true
                        } else {
                            if self.currentImageKey == imageKey {
                                self.imageView.image = nil
                                self.imageView.isHidden = true
                                self.initialsLabel.isHidden = false
                            }
                        }
                    }
                }
                
            } else if descriptor.isGroup && usable.count >= 2 {
                let side = renderingSide ?? (bounds.width > 0 ? bounds.width : 60.0)
                let imageKey = GroupCompositeAvatar.cacheKey(for: usable, side: side)
                
                if currentImageKey == imageKey && imageView.image != nil {
                    imageView.isHidden = false
                    initialsLabel.isHidden = true
                    return
                }
                if currentImageKey == imageKey && loadTask != nil {
                    return
                }
                
                if imageView.image == nil {
                    initialsLabel.isHidden = false
                    imageView.isHidden = true
                } else {
                    imageView.isHidden = false
                    initialsLabel.isHidden = true
                }
                
                currentImageKey = imageKey
                
                if let cached = ChatAvatarImageStore.cached(for: imageKey) {
                    imageView.image = cached
                    imageView.isHidden = false
                    initialsLabel.isHidden = true
                } else {
                    loadTask = Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        let image = await GroupCompositeAvatar.composedImage(members: descriptor.members, side: side, isDark: isDark)
                        guard !Task.isCancelled, self.loadGeneration == generation,
                          self.currentImageKey == imageKey else { return }
                        self.loadTask = nil
                        if let img = image {
                            self.imageView.image = img
                            self.imageView.isHidden = false
                            self.initialsLabel.isHidden = true
                        } else {
                            if self.currentImageKey == imageKey {
                                self.imageView.image = nil
                                self.imageView.isHidden = true
                                self.initialsLabel.isHidden = false
                            }
                        }
                    }
                }
            } else {
                imageView.image = nil
                imageView.isHidden = true
                initialsLabel.isHidden = false
                currentImageKey = nil
            }
        }
    }
    
    @objc private func handleAvatarImageReplaced(_ notification: Notification) {
        guard let key = notification.object as? String,
              currentImageKey == "url_\(key)",
              let image = ChatAvatarImageStore.cached(for: key) else { return }
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        imageView.image = image
        imageView.isHidden = false
        initialsLabel.isHidden = true
    }

    func prepareForReuse() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
    }
    
    private func setGradient(_ colors: (UIColor, UIColor), vertical: Bool = false) {
        gradientLayer.colors = [colors.0.cgColor, colors.1.cgColor]
        gradientLayer.locations = [0.0, 1.0]
        gradientLayer.startPoint = vertical ? CGPoint(x: 0.5, y: 0) : CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = vertical ? CGPoint(x: 0.5, y: 1) : CGPoint(x: 1, y: 1)
    }
}
