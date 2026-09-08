import UIKit

/// One image in a chat/group media gallery (opened from a bubble or grid tile).
struct ChatMediaGalleryItem: Equatable {
  let id: String
  let messageId: String?
  let mediaURL: String?
  let caption: String
  let seedImage: UIImage?

  static func == (lhs: ChatMediaGalleryItem, rhs: ChatMediaGalleryItem) -> Bool {
    lhs.id == rhs.id
  }
}

/// Full-screen image viewer with swipe paging + bottom filmstrip of chat/group media.
final class ChatMediaGalleryViewController: UIViewController, UIScrollViewDelegate,
  UICollectionViewDataSource, UICollectionViewDelegateFlowLayout
{
  private let items: [ChatMediaGalleryItem]
  private var currentIndex: Int
  private let headerTitle: String
  var onReply: ((ChatMediaGalleryItem) -> Void)?

  private let pagingScrollView = UIScrollView()
  private var pageImageViews: [UIImageView] = []
  private var pageScrollViews: [UIScrollView] = []

  private let topBar = UIView()
  private let closeButton = UIButton(type: .system)
  private let titleLabel = UILabel()
  private let counterLabel = UILabel()

  private let bottomBar = UIView()
  private let captionLabel = UILabel()
  private let filmstripLayout = UICollectionViewFlowLayout()
  private lazy var filmstrip: UICollectionView = {
    filmstripLayout.scrollDirection = .horizontal
    filmstripLayout.minimumLineSpacing = 6
    filmstripLayout.minimumInteritemSpacing = 6
    filmstripLayout.itemSize = CGSize(width: 56, height: 56)
    let cv = UICollectionView(frame: .zero, collectionViewLayout: filmstripLayout)
    cv.backgroundColor = .clear
    cv.showsHorizontalScrollIndicator = false
    cv.dataSource = self
    cv.delegate = self
    cv.register(ChatMediaFilmstripCell.self, forCellWithReuseIdentifier: ChatMediaFilmstripCell.reuseId)
    return cv
  }()

  private let replyButton = UIButton(type: .system)

  init(items: [ChatMediaGalleryItem], startIndex: Int, headerTitle: String) {
    self.items = items
    self.currentIndex = max(0, min(startIndex, max(0, items.count - 1)))
    self.headerTitle = headerTitle
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .overFullScreen
    modalTransitionStyle = .crossDissolve
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    pagingScrollView.isPagingEnabled = true
    pagingScrollView.showsHorizontalScrollIndicator = false
    pagingScrollView.showsVerticalScrollIndicator = false
    pagingScrollView.delegate = self
    pagingScrollView.backgroundColor = .black
    view.addSubview(pagingScrollView)

    for item in items {
      let zoom = UIScrollView()
      zoom.minimumZoomScale = 1.0
      zoom.maximumZoomScale = 3.5
      zoom.showsHorizontalScrollIndicator = false
      zoom.showsVerticalScrollIndicator = false
      zoom.delegate = self
      zoom.backgroundColor = .black
      let imageView = UIImageView()
      imageView.contentMode = .scaleAspectFit
      imageView.clipsToBounds = true
      imageView.isUserInteractionEnabled = true
      if let seed = item.seedImage {
        imageView.image = seed
      }
      zoom.addSubview(imageView)
      pagingScrollView.addSubview(zoom)
      pageScrollViews.append(zoom)
      pageImageViews.append(imageView)
      loadImage(for: item, into: imageView)
    }

    topBar.backgroundColor = UIColor.black.withAlphaComponent(0.35)
    view.addSubview(topBar)

    closeButton.setImage(
      UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)),
      for: .normal
    )
    closeButton.tintColor = .white
    closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
    topBar.addSubview(closeButton)

    titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
    titleLabel.textColor = .white
    titleLabel.textAlignment = .center
    titleLabel.text = headerTitle
    topBar.addSubview(titleLabel)

    counterLabel.font = .systemFont(ofSize: 13, weight: .medium)
    counterLabel.textColor = UIColor.white.withAlphaComponent(0.75)
    counterLabel.textAlignment = .center
    topBar.addSubview(counterLabel)

    bottomBar.backgroundColor = UIColor.black.withAlphaComponent(0.55)
    view.addSubview(bottomBar)

    captionLabel.font = .systemFont(ofSize: 14, weight: .regular)
    captionLabel.textColor = .white
    captionLabel.numberOfLines = 2
    bottomBar.addSubview(captionLabel)

    bottomBar.addSubview(filmstrip)

    replyButton.setTitle("Reply", for: .normal)
    replyButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    replyButton.setTitleColor(.white, for: .normal)
    replyButton.backgroundColor = UIColor.white.withAlphaComponent(0.14)
    replyButton.layer.cornerRadius = 16
    replyButton.layer.cornerCurve = .continuous
    replyButton.addTarget(self, action: #selector(replyTapped), for: .touchUpInside)
    bottomBar.addSubview(replyButton)

    let swipeDown = UIPanGestureRecognizer(target: self, action: #selector(handleDismissPan(_:)))
    view.addGestureRecognizer(swipeDown)

    updateChrome()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let safe = view.safeAreaInsets
    let w = view.bounds.width
    let h = view.bounds.height

    topBar.frame = CGRect(x: 0, y: 0, width: w, height: safe.top + 48)
    closeButton.frame = CGRect(x: 12, y: safe.top + 6, width: 36, height: 36)
    titleLabel.frame = CGRect(x: 56, y: safe.top + 4, width: max(0, w - 112), height: 22)
    counterLabel.frame = CGRect(x: 56, y: safe.top + 26, width: max(0, w - 112), height: 18)

    let filmstripH: CGFloat = 64
    let captionH: CGFloat = 40
    let replyH: CGFloat = 36
    let bottomH = safe.bottom + filmstripH + captionH + replyH + 28
    bottomBar.frame = CGRect(x: 0, y: h - bottomH, width: w, height: bottomH)
    captionLabel.frame = CGRect(x: 16, y: 10, width: w - 32, height: captionH)
    filmstrip.frame = CGRect(x: 12, y: captionLabel.frame.maxY + 4, width: w - 24, height: filmstripH)
    replyButton.frame = CGRect(
      x: 16, y: filmstrip.frame.maxY + 8, width: 88, height: replyH)

    let pageTop = topBar.frame.maxY
    let pageBottom = bottomBar.frame.minY
    let pageH = max(1, pageBottom - pageTop)
    pagingScrollView.frame = CGRect(x: 0, y: pageTop, width: w, height: pageH)
    pagingScrollView.contentSize = CGSize(width: w * CGFloat(items.count), height: pageH)

    for (i, zoom) in pageScrollViews.enumerated() {
      zoom.frame = CGRect(x: w * CGFloat(i), y: 0, width: w, height: pageH)
      zoom.contentSize = CGSize(width: w, height: pageH)
      pageImageViews[i].frame = zoom.bounds
      zoom.zoomScale = 1.0
    }

    if !items.isEmpty {
      pagingScrollView.contentOffset = CGPoint(x: w * CGFloat(currentIndex), y: 0)
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    scrollFilmstripToCurrent(animated: false)
  }

  private func updateChrome() {
    guard !items.isEmpty else { return }
    let item = items[currentIndex]
    counterLabel.text = "\(currentIndex + 1) / \(items.count)"
    let caption = item.caption.trimmingCharacters(in: .whitespacesAndNewlines)
    captionLabel.text = caption.isEmpty ? " " : caption
    filmstrip.reloadData()
    scrollFilmstripToCurrent(animated: true)
  }

  private func scrollFilmstripToCurrent(animated: Bool) {
    guard currentIndex < items.count else { return }
    let path = IndexPath(item: currentIndex, section: 0)
    filmstrip.scrollToItem(at: path, at: .centeredHorizontally, animated: animated)
  }

  private func goToIndex(_ index: Int, animated: Bool) {
    guard index >= 0, index < items.count else { return }
    currentIndex = index
    let x = pagingScrollView.bounds.width * CGFloat(index)
    pagingScrollView.setContentOffset(CGPoint(x: x, y: 0), animated: animated)
    updateChrome()
  }

  private func loadImage(for item: ChatMediaGalleryItem, into imageView: UIImageView) {
    if imageView.image != nil { return }
    guard let raw = item.mediaURL?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
    else { return }

    if raw.hasPrefix("/") || raw.hasPrefix("file:") {
      let path: String
      if let url = URL(string: raw), url.isFileURL {
        path = url.path
      } else {
        path = raw
      }
      if let img = UIImage(contentsOfFile: path) {
        imageView.image = img
      }
      return
    }

    guard let url = URL(string: raw) else { return }
    VibeHTTP.shared.dataTask(with: url) { data, _, _ in
      guard let data, let img = UIImage(data: data) else { return }
      DispatchQueue.main.async {
        imageView.image = img
      }
    }.resume()
  }

  // MARK: - UIScrollViewDelegate

  func viewForZooming(in scrollView: UIScrollView) -> UIView? {
    if scrollView === pagingScrollView { return nil }
    guard let idx = pageScrollViews.firstIndex(of: scrollView) else { return nil }
    return pageImageViews[idx]
  }

  func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    guard scrollView === pagingScrollView else { return }
    let w = max(1, scrollView.bounds.width)
    let idx = Int(round(scrollView.contentOffset.x / w))
    if idx != currentIndex, idx >= 0, idx < items.count {
      currentIndex = idx
      updateChrome()
    }
  }

  func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
    scrollViewDidEndDecelerating(scrollView)
  }

  // MARK: - Filmstrip

  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int)
    -> Int
  {
    items.count
  }

  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath)
    -> UICollectionViewCell
  {
    let cell =
      collectionView.dequeueReusableCell(
        withReuseIdentifier: ChatMediaFilmstripCell.reuseId, for: indexPath)
      as! ChatMediaFilmstripCell
    let item = items[indexPath.item]
    cell.configure(
      image: item.seedImage ?? pageImageViews[safe: indexPath.item]?.image,
      selected: indexPath.item == currentIndex
    )
    if cell.imageView.image == nil {
      loadImage(for: item, into: cell.imageView)
    }
    return cell
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    goToIndex(indexPath.item, animated: true)
  }

  // MARK: - Actions

  @objc private func closeTapped() {
    dismiss(animated: true)
  }

  @objc private func replyTapped() {
    guard currentIndex < items.count else { return }
    let item = items[currentIndex]
    dismiss(animated: true) { [weak self] in
      self?.onReply?(item)
    }
  }

  @objc private func handleDismissPan(_ gr: UIPanGestureRecognizer) {
    let t = gr.translation(in: view)
    guard t.y > 0 else { return }
    if gr.state == .changed {
      let p = min(1, t.y / 280)
      view.transform = CGAffineTransform(translationX: 0, y: t.y * 0.55)
      view.alpha = 1 - p * 0.45
    } else if gr.state == .ended || gr.state == .cancelled {
      let v = gr.velocity(in: view).y
      if t.y > 120 || v > 900 {
        dismiss(animated: true)
      } else {
        UIView.animate(withDuration: 0.22) {
          self.view.transform = .identity
          self.view.alpha = 1
        }
      }
    }
  }
}

private final class ChatMediaFilmstripCell: UICollectionViewCell {
  static let reuseId = "ChatMediaFilmstripCell"
  let imageView = UIImageView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    contentView.clipsToBounds = true
    contentView.layer.cornerRadius = 8
    contentView.layer.cornerCurve = .continuous
    contentView.backgroundColor = UIColor(white: 0.15, alpha: 1)
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    contentView.addSubview(imageView)
  }

  required init?(coder: NSCoder) { nil }

  override func layoutSubviews() {
    super.layoutSubviews()
    imageView.frame = contentView.bounds
  }

  func configure(image: UIImage?, selected: Bool) {
    imageView.image = image
    contentView.layer.borderWidth = selected ? 2 : 0
    contentView.layer.borderColor = UIColor.white.cgColor
    contentView.alpha = selected ? 1 : 0.72
  }
}

private extension Array {
  subscript(safe index: Int) -> Element? {
    guard index >= 0, index < count else { return nil }
    return self[index]
  }
}

enum ChatMediaGalleryModule {
  static func present(
    from presenter: UIViewController,
    items: [ChatMediaGalleryItem],
    startIndex: Int,
    headerTitle: String,
    onReply: ((ChatMediaGalleryItem) -> Void)? = nil
  ) {
    guard !items.isEmpty else { return }
    let vc = ChatMediaGalleryViewController(
      items: items,
      startIndex: startIndex,
      headerTitle: headerTitle
    )
    vc.onReply = onReply
    presenter.present(vc, animated: true)
  }
}
