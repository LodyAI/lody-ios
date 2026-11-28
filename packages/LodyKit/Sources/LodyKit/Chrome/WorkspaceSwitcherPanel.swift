import LodyDesignSystem
import UIKit

/// The workspace switcher: a floating Liquid Glass menu panel anchored beneath the workspace
/// capsule (never adapted to a sheet, and without a popover arrow so all four corners stay
/// symmetric). It keeps the account email heading, circular logos and single-line trailing-faded
/// names (which a `UIMenu` cannot do), highlighting the active workspace with a concentric
/// selection pill and semibold title instead of a leading checkmark gutter.
/// Choosing a row closes the panel before switching.
@MainActor
final class WorkspaceSwitcherPanel: UIViewController {
  static let cornerRadius: CGFloat = 26
  private static let rowHeight: CGFloat = 48
  private static let headerHeight: CGFloat = 40
  private static let avatarSide: CGFloat = 28
  private static let inset: CGFloat = 8
  private static let rowPillInsetX: CGFloat = 8
  private static let rowPillInsetY: CGFloat = 2
  private static let rowPillCornerRadius: CGFloat = 18
  private static let maxVisibleRows: CGFloat = 8
  private static let edgeMargin: CGFloat = 16
  private static let verticalGap: CGFloat = 8
  private var items: [LodyMenuItem]
  private var accountEmail: String
  private var maxWidth: CGFloat
  private let picked: (String) -> Void
  private let card = UIVisualEffectView(effect: LodyGlass.effect())
  private let scroll = UIScrollView()
  private let stack = UIStackView()
  private var menuTransition: WorkspaceSwitcherTransition?

  init(items: [LodyMenuItem], accountEmail: String, maxWidth: CGFloat, picked: @escaping (String) -> Void) {
    self.items = items
    self.accountEmail = accountEmail
    self.maxWidth = maxWidth
    self.picked = picked
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func configureAnchoredPresentation(from anchor: UIView) {
    let transition = WorkspaceSwitcherTransition(anchor: anchor)
    menuTransition = transition
    modalPresentationStyle = .custom
    transitioningDelegate = transition
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .clear
    view.clipsToBounds = false
    view.accessibilityViewIsModal = true
    if #available(iOS 26.0, *) {
      // UIGlassEffect renders its own specular rim and ambient shadow.
    } else {
      view.layer.shadowColor = UIColor.black.cgColor
      view.layer.shadowOpacity = 0.16
      view.layer.shadowRadius = 20
      view.layer.shadowOffset = CGSize(width: 0, height: 8)
    }
    card.translatesAutoresizingMaskIntoConstraints = false
    card.lodySetCorners(.fixed(Self.cornerRadius))
    card.contentView.clipsToBounds = true
    view.addSubview(card)
    scroll.translatesAutoresizingMaskIntoConstraints = false
    scroll.alwaysBounceVertical = false
    scroll.showsHorizontalScrollIndicator = false
    scroll.accessibilityIdentifier = "workspace-panel"
    card.contentView.addSubview(scroll)
    stack.axis = .vertical
    stack.translatesAutoresizingMaskIntoConstraints = false
    scroll.addSubview(stack)
    NSLayoutConstraint.activate([
      card.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      card.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      card.topAnchor.constraint(equalTo: view.topAnchor),
      card.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: card.contentView.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Self.inset),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Self.inset),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
    ])
    rebuild()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if #available(iOS 26.0, *) { return }
    view.layer.shadowPath = UIBezierPath(roundedRect: view.bounds, cornerRadius: Self.cornerRadius).cgPath
  }

  override func accessibilityPerformEscape() -> Bool {
    dismiss(animated: true)
    return true
  }

  func update(items next: [LodyMenuItem], accountEmail email: String) {
    guard next != items || email != accountEmail else { return }
    items = next
    accountEmail = email
    guard isViewLoaded else { return }
    rebuild()
  }

  func updateMaxWidth(_ next: CGFloat) {
    guard abs(maxWidth - next) > 0.5 else { return }
    maxWidth = next
    guard isViewLoaded else { return }
    resize()
  }

  /// Computes the floating card's frame relative to `anchorRect` within `containerBounds`, aligned
  /// to the leading edge of the capsule and flipping upward only when space above exceeds space below.
  static func panelFrame(
    in containerBounds: CGRect,
    preferredSize: CGSize,
    anchorRect: CGRect,
    safeArea: UIEdgeInsets,
    rtl: Bool
  ) -> (frame: CGRect, opensDownward: Bool) {
    let availableWidth = max(0, containerBounds.width - safeArea.left - safeArea.right - edgeMargin * 2)
    let width = min(preferredSize.width, availableWidth)
    let minX = safeArea.left + edgeMargin
    let maxX = max(minX, containerBounds.width - safeArea.right - edgeMargin - width)
    let rawX = rtl ? anchorRect.maxX - width : anchorRect.minX
    let x = min(max(rawX, minX), maxX)

    let belowTop = anchorRect.maxY + verticalGap
    let availableBelow = max(0, containerBounds.height - safeArea.bottom - edgeMargin - belowTop)
    let aboveBottom = anchorRect.minY - verticalGap
    let availableAbove = max(0, aboveBottom - (safeArea.top + verticalGap))
    let opensDownward = preferredSize.height <= availableBelow || availableBelow >= availableAbove
    let height: CGFloat
    let y: CGFloat
    if opensDownward {
      height = min(preferredSize.height, availableBelow)
      y = belowTop
    } else {
      height = min(preferredSize.height, availableAbove)
      y = aboveBottom - height
    }
    return (CGRect(x: x, y: y, width: width, height: height), opensDownward)
  }

  private func rebuild() {
    stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    if !accountEmail.isEmpty {
      let header = UILabel()
      header.text = accountEmail
      header.font = .preferredFont(forTextStyle: .footnote)
      header.adjustsFontForContentSizeCategory = true
      header.textColor = .secondaryLabel
      header.textAlignment = .center
      header.lineBreakMode = .byTruncatingMiddle
      header.accessibilityTraits = .header
      header.heightAnchor.constraint(equalToConstant: Self.headerHeight).isActive = true
      stack.addArrangedSubview(header)
    }
    for item in items {
      let row = WorkspaceSwitcherRow(
        item: item,
        avatarSide: Self.avatarSide,
        pillInsetX: Self.rowPillInsetX,
        pillInsetY: Self.rowPillInsetY,
        pillCornerRadius: Self.rowPillCornerRadius
      ) { [weak self] in
        self?.rebuild()
      }
      row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
      row.addAction(UIAction { [weak self] _ in self?.choose(item.id) }, for: .touchUpInside)
      stack.addArrangedSubview(row)
    }
    resize()
  }

  private func resize() {
    let regularFont = LodyDesign.font(.body, size: 17, weight: .regular)
    let selectedFont = LodyDesign.font(.body, size: 17, weight: .semibold)
    let names = items.map { item -> CGFloat in
      let font = item.selected ? selectedFont : regularFont
      return ceil((item.title as NSString).size(withAttributes: [.font: font]).width)
    }
    // Leading margin, logo, gap, name, trailing margin.
    let natural = (names.max() ?? 0) + 16 + Self.avatarSide + 12 + 16
    let width = min(max(natural, 200), max(200, min(260, maxWidth)))
    let header = accountEmail.isEmpty ? 0 : Self.headerHeight
    let rows = min(CGFloat(items.count), Self.maxVisibleRows) * Self.rowHeight
    preferredContentSize = CGSize(width: width, height: header + rows + Self.inset * 2)
  }

  private func choose(_ id: String) {
    let picked = picked
    let item = items.first(where: { $0.id == id })
    let current = item?.selected == true
    dismiss(animated: true) {
      if !current || item?.retrySelection == true { picked(id) }
    }
  }
}

@MainActor
private final class WorkspaceSwitcherTransition: NSObject, UIViewControllerTransitioningDelegate {
  private weak var anchor: UIView?

  init(anchor: UIView) {
    self.anchor = anchor
  }

  func presentationController(
    forPresented presented: UIViewController,
    presenting: UIViewController?,
    source: UIViewController
  ) -> UIPresentationController? {
    WorkspaceSwitcherPresentationController(presentedViewController: presented, presenting: presenting, anchor: anchor)
  }

  func animationController(
    forPresented presented: UIViewController,
    presenting: UIViewController,
    source: UIViewController
  ) -> UIViewControllerAnimatedTransitioning? {
    WorkspaceSwitcherAnimator(presenting: true, anchor: anchor)
  }

  func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
    WorkspaceSwitcherAnimator(presenting: false, anchor: anchor)
  }
}

@MainActor
private final class WorkspaceSwitcherPresentationController: UIPresentationController {
  private weak var anchor: UIView?
  private let backdrop = UIView()
  private var lastAnchorRect: CGRect?

  init(presentedViewController: UIViewController, presenting: UIViewController?, anchor: UIView?) {
    self.anchor = anchor
    super.init(presentedViewController: presentedViewController, presenting: presenting)
  }

  override var frameOfPresentedViewInContainerView: CGRect {
    layout(in: containerView).frame
  }

  func opensDownward(in container: UIView?) -> Bool {
    layout(in: container).opensDownward
  }

  func resolvedAnchorRect(in container: UIView) -> CGRect {
    if let anchor, anchor.window != nil {
      let rect = anchor.convert(anchor.bounds, to: container)
      lastAnchorRect = rect
      return rect
    }
    if let lastAnchorRect { return lastAnchorRect }
    let top = container.safeAreaInsets.top
    return CGRect(x: container.safeAreaInsets.left + 16, y: top, width: 44, height: 44)
  }

  private func layout(in container: UIView?) -> (frame: CGRect, opensDownward: Bool) {
    guard let container else { return (.zero, true) }
    let anchorRect = resolvedAnchorRect(in: container)
    let rtl = container.effectiveUserInterfaceLayoutDirection == .rightToLeft
    return WorkspaceSwitcherPanel.panelFrame(
      in: container.bounds,
      preferredSize: presentedViewController.preferredContentSize,
      anchorRect: anchorRect,
      safeArea: container.safeAreaInsets,
      rtl: rtl
    )
  }

  override func presentationTransitionWillBegin() {
    guard let containerView else { return }
    backdrop.backgroundColor = .clear
    backdrop.frame = containerView.bounds
    backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    let tap = UITapGestureRecognizer(target: self, action: #selector(dismissFromBackdrop))
    backdrop.addGestureRecognizer(tap)
    containerView.insertSubview(backdrop, at: 0)
  }

  override func presentationTransitionDidEnd(_ completed: Bool) {
    if !completed { backdrop.removeFromSuperview() }
  }

  override func dismissalTransitionDidEnd(_ completed: Bool) {
    if completed { backdrop.removeFromSuperview() }
  }

  override func containerViewWillLayoutSubviews() {
    super.containerViewWillLayoutSubviews()
    guard let containerView else { return }
    backdrop.frame = containerView.bounds
    if let panel = presentedViewController as? WorkspaceSwitcherPanel {
      let available = containerView.bounds.width - containerView.safeAreaInsets.left - containerView.safeAreaInsets.right - 32
      panel.updateMaxWidth(available)
    }
    guard let presentedView, !presentedViewController.isBeingPresented, !presentedViewController.isBeingDismissed else { return }
    presentedView.frame = frameOfPresentedViewInContainerView
  }

  override func preferredContentSizeDidChange(forChildContentContainer container: any UIContentContainer) {
    super.preferredContentSizeDidChange(forChildContentContainer: container)
    guard let presentedView, !presentedViewController.isBeingPresented, !presentedViewController.isBeingDismissed else { return }
    let target = frameOfPresentedViewInContainerView
    guard presentedView.frame != target else { return }
    UIView.lodySpring(duration: 0.24, bounce: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
      presentedView.frame = target
      presentedView.layoutIfNeeded()
    }
  }

  @objc private func dismissFromBackdrop() {
    presentedViewController.dismiss(animated: true)
  }
}

@MainActor
private final class WorkspaceSwitcherAnimator: NSObject, UIViewControllerAnimatedTransitioning {
  private let presenting: Bool
  private weak var anchor: UIView?

  init(presenting: Bool, anchor: UIView?) {
    self.presenting = presenting
    self.anchor = anchor
  }

  func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
    presenting ? 0.30 : 0.16
  }

  func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {
    let container = transitionContext.containerView
    let reduceMotion = UIAccessibility.isReduceMotionEnabled
    if presenting {
      guard let toController = transitionContext.viewController(forKey: .to),
        let toView = transitionContext.view(forKey: .to)
      else {
        transitionContext.completeTransition(false)
        return
      }
      let finalFrame = transitionContext.finalFrame(for: toController)
      toView.frame = finalFrame
      container.addSubview(toView)
      toView.layoutIfNeeded()
      let presentation = toController.presentationController as? WorkspaceSwitcherPresentationController
      let opensDownward = presentation?.opensDownward(in: container) ?? true
      let collapsed = collapsedTransform(for: finalFrame, in: container, opensDownward: opensDownward)
      toView.alpha = 0
      if !reduceMotion { toView.transform = collapsed }
      UISelectionFeedbackGenerator().selectionChanged()
      UIView.lodySpring(
        duration: transitionDuration(using: transitionContext),
        bounce: 0.12,
        options: [.beginFromCurrentState, .allowUserInteraction]
      ) {
        toView.alpha = 1
        toView.transform = .identity
      } completion: { _ in
        transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
      }
    } else {
      guard let fromController = transitionContext.viewController(forKey: .from),
        let fromView = transitionContext.view(forKey: .from)
      else {
        transitionContext.completeTransition(false)
        return
      }
      let presentation = fromController.presentationController as? WorkspaceSwitcherPresentationController
      let opensDownward = presentation?.opensDownward(in: container) ?? true
      let collapsed = collapsedTransform(for: fromView.frame, in: container, opensDownward: opensDownward)
      UIView.animate(
        withDuration: transitionDuration(using: transitionContext),
        delay: 0,
        options: [.curveEaseIn, .beginFromCurrentState]
      ) {
        fromView.alpha = 0
        if !reduceMotion { fromView.transform = collapsed }
      } completion: { _ in
        let finished = !transitionContext.transitionWasCancelled
        if finished { fromView.removeFromSuperview() }
        transitionContext.completeTransition(finished)
      }
    }
  }

  private func collapsedTransform(for frame: CGRect, in container: UIView, opensDownward: Bool) -> CGAffineTransform {
    let sx: CGFloat = 0.84
    let sy: CGFloat = 0.72
    let rtl = container.effectiveUserInterfaceLayoutDirection == .rightToLeft
    let originX: CGFloat
    if let anchor, anchor.window != nil {
      let rect = anchor.convert(anchor.bounds, to: container)
      originX = rtl ? min(frame.maxX, rect.maxX) : max(frame.minX, rect.minX)
    } else {
      originX = rtl ? frame.maxX : frame.minX
    }
    let originY = opensDownward ? frame.minY : frame.maxY
    let dx = originX - frame.midX
    let dy = originY - frame.midY
    let nudgeY: CGFloat = opensDownward ? -6 : 6
    return CGAffineTransform(
      translationX: dx * (1 - sx),
      y: dy * (1 - sy) + nudgeY
    ).scaledBy(x: sx, y: sy)
  }
}

/// One workspace: concentric selection pill, round logo (its initial until the logo loads) and the
/// name on a single line that fades out at the trailing edge instead of wrapping or truncating.
@MainActor
private final class WorkspaceSwitcherRow: UIControl {
  private static let pressedFill = UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(white: 1, alpha: 0.18)
      : UIColor(white: 0, alpha: 0.12)
  }
  private let selectionPill = UIView()
  private let avatar = UIImageView()
  private let name = LodyFadingLabel()
  private let lock = UIImageView()
  private let isCurrent: Bool

  init(
    item: LodyMenuItem,
    avatarSide: CGFloat,
    pillInsetX: CGFloat,
    pillInsetY: CGFloat,
    pillCornerRadius: CGFloat,
    photoLoaded: @escaping () -> Void
  ) {
    self.isCurrent = item.selected
    super.init(frame: .zero)
    selectionPill.lodySetCorners(.fixed(pillCornerRadius))
    selectionPill.accessibilityIdentifier = "workspace-row-pill:" + item.id
    avatar.image = Self.avatar(item, side: avatarSide, loaded: photoLoaded)
    avatar.layer.cornerRadius = avatarSide / 2
    avatar.clipsToBounds = true
    name.text = item.title
    name.font = LodyDesign.font(.body, size: 17, weight: item.selected ? .semibold : .regular)
    lock.image = UIImage(systemName: "lock.fill")
    lock.tintColor = .secondaryLabel
    lock.contentMode = .scaleAspectFit
    lock.isHidden = !item.encrypted
    lock.accessibilityIdentifier = "workspace-encrypted:" + item.id
    for view in [selectionPill, avatar, name, lock] as [UIView] {
      view.translatesAutoresizingMaskIntoConstraints = false
      view.isUserInteractionEnabled = false
      addSubview(view)
    }
    NSLayoutConstraint.activate([
      selectionPill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pillInsetX),
      selectionPill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pillInsetX),
      selectionPill.topAnchor.constraint(equalTo: topAnchor, constant: pillInsetY),
      selectionPill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pillInsetY),
      avatar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      avatar.centerYAnchor.constraint(equalTo: centerYAnchor),
      avatar.widthAnchor.constraint(equalToConstant: avatarSide),
      avatar.heightAnchor.constraint(equalToConstant: avatarSide),
      name.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 12),
      name.trailingAnchor.constraint(equalTo: lock.leadingAnchor, constant: item.encrypted ? -8 : 0),
      lock.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      lock.centerYAnchor.constraint(equalTo: centerYAnchor),
      lock.widthAnchor.constraint(equalToConstant: item.encrypted ? 16 : 0),
      lock.heightAnchor.constraint(equalToConstant: 16),
      name.topAnchor.constraint(equalTo: topAnchor),
      name.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    applyPillBackground()
    isAccessibilityElement = true
    accessibilityIdentifier = "workspace-row:" + item.id
    accessibilityLabel = item.encrypted ? item.title + ", E2EE" : item.title
    accessibilityTraits = item.selected ? [.button, .selected] : [.button]
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var isHighlighted: Bool {
    didSet { applyPillBackground() }
  }

  private func applyPillBackground() {
    if isHighlighted {
      selectionPill.backgroundColor = Self.pressedFill
    } else if isCurrent {
      selectionPill.backgroundColor = LodyUIColor.fillSelected
    } else {
      selectionPill.backgroundColor = .clear
    }
  }

  /// The cached logo, else the initial while the logo loads (the panel redraws when it arrives).
  private static func avatar(_ item: LodyMenuItem, side: CGFloat, loaded: @escaping () -> Void) -> UIImage {
    if let url = LodyListPhoto.url(item.photo),
      let photo = LodyListPhoto.image(for: url, ready: { _ in loaded() })
    {
      return photo
    }
    return LodyListPhoto.monogram(item.monogram, side: side)
  }
}

/// A single-line label whose overflow fades out at the trailing edge (no ellipsis).
@MainActor
final class LodyFadingLabel: UIView {
  private static let fadeWidth: CGFloat = 28
  private let label = UILabel()
  private let fade = CAGradientLayer()

  var text: String? {
    get { label.text }
    set {
      label.text = newValue
      setNeedsLayout()
    }
  }

  var font: UIFont {
    get { label.font }
    set {
      label.font = newValue
      setNeedsLayout()
    }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    isAccessibilityElement = false
    label.font = LodyDesign.font(.body, size: 17, weight: .regular)
    label.adjustsFontForContentSizeCategory = true
    label.textColor = .lodyInk
    label.numberOfLines = 1
    label.lineBreakMode = .byClipping
    addSubview(label)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override func layoutSubviews() {
    super.layoutSubviews()
    let natural = ceil(label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: bounds.height)).width)
    let width = max(bounds.width, natural)
    let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
    label.frame = CGRect(x: rtl ? bounds.width - width : 0, y: 0, width: width, height: bounds.height)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if natural > bounds.width, bounds.width > 0 {
      fade.frame = bounds
      fade.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
      fade.locations = [0, NSNumber(value: Double(max(0, 1 - Self.fadeWidth / bounds.width))), 1]
      fade.startPoint = CGPoint(x: rtl ? 1 : 0, y: 0.5)
      fade.endPoint = CGPoint(x: rtl ? 0 : 1, y: 0.5)
      layer.mask = fade
    } else {
      layer.mask = nil
    }
    CATransaction.commit()
  }
}
