//
//  TableViewLayout.swift
//

import UIKit
import RxSwift

protocol CellEditable {
    func set(editing: Bool, animated: Bool)
}

extension CellEditable {
    func set(editing: Bool, animated: Bool) {
        // Do nothing by default.
    }
}

protocol CollectionEditable: class, CellEditable {
    var collectionView: UICollectionView { get }
    var tableViewLayout: TableViewLayout { get }
    var cellEditingDisposeBag: DisposeBag { get set }

    func setEditing(_ editing: Bool, animated: Bool)
    var isEditing: Bool { get }
}

extension CollectionEditable {
    func set(editing: Bool, animated: Bool) {
        setEditing(editing, animated: animated)
        tableViewLayout.set(editing: editing)

        collectionView.visibleCells
            .forEach { colCell in
                (colCell as? CellEditable)?.set(editing: editing, animated: animated)
        }

        cellEditingDisposeBag = DisposeBag()
        collectionView.rx.willDisplayItem
            .subscribe(onNext: { cell, _ in
                (cell as? CellEditable)?.set(editing: editing, animated: false)
            })
            .addDisposableTo(cellEditingDisposeBag)
    }
}

extension UIDynamicBehavior {
    fileprivate func layoutItem() -> UICollectionViewLayoutAttributes? {
        guard
            let attach = self as? UIAttachmentBehavior,
            let firstItem = attach.items.first as? UICollectionViewLayoutAttributes
        else {
            return nil
        }

        return firstItem
    }

    fileprivate func indexPath() -> IndexPath? {
        return layoutItem()?.indexPath
    }
}

protocol TableViewLayoutDelegate: class {
    func tableViewLayout(startedDraggingItemAt indexPath: IndexPath)
}

class TableViewLayout: UICollectionViewFlowLayout {
    private let moveItemGesture = UILongPressGestureRecognizer()
    private var animator: UIDynamicAnimator!
    private var isEditing = false
    private var dragIndexPath: IndexPath?
    private var dragCenterOffset = CGPoint.zero
    private var dragPoint = CGPoint.zero
    private var targetIndexPath: IndexPath?
    private var visibleIndexPathsSet = Set<IndexPath>()
    private var liftedIndexPaths = Set<IndexPath>()
    private var loweredIndexPaths = Set<IndexPath>()
    private var disposeBag = DisposeBag()

    weak var delegate: TableViewLayoutDelegate?

    private static let itemHeight: CGFloat = 44.0

    override init() {
        super.init()

        commonInit()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)

        commonInit()
    }

    private func commonInit() {
        animator = UIDynamicAnimator.init(collectionViewLayout: self)

        configureItemSizing()

        moveItemGesture.rx.event
            .subscribe(onNext: { [weak self] longPress in
                guard let cv = self?.collectionView else { return }
                let loc = longPress.location(in: cv)
                switch longPress.state {
                case .began:
                    print("BEGAN")
                    if
                        let fromIndexPath = cv.indexPathForItem(at: loc),
                        let fromCenter: CGPoint = self?.layoutAttributesForItem(at: fromIndexPath)?.center
                    {
                        self?.dragIndexPath = fromIndexPath
                        self?.dragCenterOffset = CGPoint(x: loc.x - fromCenter.x, y: loc.y - fromCenter.y)
                        self?.visibleIndexPathsSet.insert(fromIndexPath)
                        self?.targetIndexPath = fromIndexPath
                        self?.updateMovingTarget(from: loc)

                        self?.delegate?.tableViewLayout(startedDraggingItemAt: fromIndexPath)
                    }

                case .changed:
                    // print("CHANGED")
                    self?.updateMovingTarget(from: loc)

                case .cancelled:
                    print("CANCELLED")
                    self?.releaseMovingTarget()

                case .ended:
                    print("ENDED")
                    self?.releaseMovingTarget()

                default:
                    break
                }
            })
            .addDisposableTo(disposeBag)
    }

    // override class var layoutAttributesClass: UICollectionViewLayoutAttributes { return UICollectionViewLayoutAttributes.self }
    override class var invalidationContextClass: AnyClass {
        return UICollectionViewFlowLayoutInvalidationContext.self
    }

    private func configureItemSizing() {
        let width = LayoutCalculations.cellWidthForView(collectionView)
        itemSize = CGSize(width: width, height: TableViewLayout.itemHeight)
        let viewWidth: CGFloat = collectionView?.bounds.width ?? UIScreen.main.applicationFrame.size.width
        let inset = viewWidth / 2.0 - width / 2.0
        sectionInset = UIEdgeInsets(top: 0.0, left: inset, bottom: 0.0, right: inset)
    }

    override func prepare() {
        configureItemSizing()

        if moveItemGesture.view == nil {
            moveItemGesture.isEnabled = false
            collectionView?.addGestureRecognizer(moveItemGesture)
        }

        super.prepare()

        guard let cv = collectionView else { return }

        let visibleRect = cv.bounds.insetBy(dx: 0.0, dy: -100.0)
        let itemsInVisibleRectArray = super.layoutAttributesForElements(in: visibleRect) ?? []
        let itemsIndexPathsInVisibleRectSet = Set<IndexPath>.init(itemsInVisibleRectArray.map { $0.indexPath })

        // Remove no longer visible behaviors.
        animator.behaviors
            .filter { [weak self] behavior -> Bool in
                guard let ip = behavior.indexPath(), ip != self?.dragIndexPath else {
                    return false
                }

                return !itemsIndexPathsInVisibleRectSet.contains(ip)
            }
            .forEach { [weak self] behavior in
                self?.animator.removeBehavior(behavior)
                _ = behavior.indexPath() >>> { self?.visibleIndexPathsSet.remove($0) }
            }

        // Add newly visible behaviors.
        itemsInVisibleRectArray
            .filter { [weak self] item -> Bool in
                return !isTrue(self?.visibleIndexPathsSet.contains(item.indexPath))
            }
            .forEach { [weak self] item in
                var newCenter = item.center
                if isTrue(self?.liftedIndexPaths.contains(item.indexPath)) {
                    newCenter.y -= TableViewLayout.itemHeight
                } else if isTrue(self?.loweredIndexPaths.contains(item.indexPath)) {
                    newCenter.y += TableViewLayout.itemHeight
                }
                self?.addBehavior(for: item, anchor: newCenter)
                self?.visibleIndexPathsSet.insert(item.indexPath)
            }

        // Adjust dragged item position.
        if
            let drag = dragIndexPath,
            let dragAttr = super.layoutAttributesForItem(at: drag)
        {
            let newCenter = CGPoint(x: dragAttr.center.x, y: dragPoint.y - dragCenterOffset.y)

            if let behavior = animator.behaviors.find({ $0.indexPath() == drag }) as? UIAttachmentBehavior {
                behavior.anchorPoint = newCenter
                if let layoutItem = behavior.layoutItem() {
                    layoutItem.center = newCenter
                    animator.updateItem(usingCurrentState: layoutItem)
                }
            } else {
                addBehavior(for: dragAttr, anchor: newCenter)
            }
        }

        // print("prepare")
    }

    /*
    override func invalidateLayout() {
        super.invalidateLayout()

        print("invalidate layout")
    }

    override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        super.invalidateLayout(with: context)

        print("invalidate layout CONTEXT")
    }
    */

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        return animator.items(in: rect) as? [UICollectionViewLayoutAttributes]
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        print(indexPath)
        /*
        guard let attr = super.layoutAttributesForItem(at: indexPath) else { return nil }
        guard let drag = dragIndexPath else { return attr }

        if drag == indexPath {
            attr.center.y = dragPoint.y - dragCenterOffset.y
            return attr
        }

        if let target = targetIndexPath {
            if target <= indexPath {
                attr.center.y += TableViewLayout.itemHeight
            } else {
                attr.center.y -= TableViewLayout.itemHeight
            }
            return attr
        }

        return attr
        */
        return animator.layoutAttributesForCell(at: indexPath) ?? super.layoutAttributesForItem(at: indexPath)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        print("shouldInvalidate")
        let width = LayoutCalculations.cellWidthForView(collectionView)
        return newBounds.width / 2.0 - width / 2.0 != sectionInset.left
    }

    /*
    override var collectionViewContentSize: CGSize {
        return super.collectionViewContentSize
    }

    override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
        print("prepare UPDATES")
        super.prepare(forCollectionViewUpdates: updateItems)
    }

    override func finalizeCollectionViewUpdates() {
        super.finalizeCollectionViewUpdates()
    }

    override func prepare(forAnimatedBoundsChange oldBounds: CGRect) {
        super.prepare(forAnimatedBoundsChange: oldBounds)
    }

    override func finalizeAnimatedBoundsChange() {
        super.finalizeAnimatedBoundsChange()
    }

    override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        return super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)
    }

    override func finalLayoutAttributesForDisappearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        return super.finalLayoutAttributesForDisappearingItem(at: itemIndexPath)
    }
    */

    fileprivate func set(editing: Bool) {
        isEditing = editing
        moveItemGesture.isEnabled = editing
    }

    private func nearestAvailableIndexPath(to point: CGPoint, for indexPath: IndexPath) -> IndexPath? {
        return super.layoutAttributesForElements(in: CGRect(x: 0.0, y: point.y, width: itemSize.width, height: 1.0))?.first?.indexPath
    }

    private func updateMovingTarget(from point: CGPoint) {
        dragPoint = point
        // print(point)

        if
            let drag = dragIndexPath,
            let target = targetIndexPath,
            let maybeIndexPath = nearestAvailableIndexPath(to: point, for: drag),
            target != maybeIndexPath
        {
            print(drag, target, maybeIndexPath)
            var change: CGFloat = 0.0

            if maybeIndexPath > target {
                liftedIndexPaths.insert(maybeIndexPath)
                change = -TableViewLayout.itemHeight
            } else {
                loweredIndexPaths.insert(maybeIndexPath)
                change = TableViewLayout.itemHeight
            }

            if maybeIndexPath == drag {
                liftedIndexPaths.remove(maybeIndexPath)
                loweredIndexPaths.remove(maybeIndexPath)
            }

            targetIndexPath = maybeIndexPath

            if
                let behavior = animator.behaviors.find({ $0.indexPath() == maybeIndexPath }) as? UIAttachmentBehavior,
                let item = super.layoutAttributesForItem(at: maybeIndexPath)
            {
                behavior.anchorPoint.y = item.center.y + change
            }
        }

        /*
        var indexPathsToInvalidate = [IndexPath]()
        dragIndexPath >>> { indexPathsToInvalidate.append($0) }

        defer {
            let context = UICollectionViewFlowLayoutInvalidationContext()
            context.invalidateFlowLayoutDelegateMetrics = false
            context.invalidateFlowLayoutAttributes = true
            context.invalidateItems(at: indexPathsToInvalidate)
            invalidateLayout(with: context)
        }

        if
            let target = targetIndexPath,
            let maybeIndexPath = nearestAvailableIndexPath(to: point),
            target != maybeIndexPath
        {
            targetIndexPath = maybeIndexPath
            collectionView?.performBatchUpdates({ [weak self] in
                self?.collectionView?.reloadItems(at: [target, maybeIndexPath])
            }, completion: nil)
        }
        */
    }

    private func releaseMovingTarget() {
        defer {
            liftedIndexPaths.removeAll()
            loweredIndexPaths.removeAll()
        }

        guard
            let drag = dragIndexPath,
            let origPosition = super.layoutAttributesForItem(at: drag),
            let behavior = animator.behaviors.find({ $0.indexPath() == drag }) as? UIAttachmentBehavior
        else {
            dragIndexPath = nil
            return
        }

        behavior.anchorPoint = origPosition.center
        dragIndexPath = nil
    }

    private func addBehavior(for item: UIDynamicItem, anchor: CGPoint) {
        let spring = UIAttachmentBehavior.init(item: item, attachedToAnchor: anchor)
        spring.length = 0.0
        spring.damping = 0.8
        spring.frequency = 1.0

        animator.addBehavior(spring)
    }
}
