#if canImport(UIKit)
import Combine
import UIKit

/// A virtualized UIKit renderer for a ``FileTreeModel``.
///
/// `FileTreeView` keeps expansion, selection, focus, and reveal state in the model. The
/// collection view only mounts fixed-height rows that are on screen, and passes a cell's
/// previously rendered content view back to `rowProvider` for caller-controlled reuse.
@MainActor
public final class FileTreeView<Node: Identifiable>: UIView,
    UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout,
    UICollectionViewDragDelegate,
    UICollectionViewDropDelegate,
    UIGestureRecognizerDelegate
{
    /// Produces the caller-owned content portion of a native row.
    ///
    /// Return `reusableView` after updating it whenever possible. Returning a different view
    /// replaces the content currently hosted by that collection-view cell.
    public typealias RowProvider = @MainActor (
        _ node: Node,
        _ context: FileTreeRowContext<Node.ID>,
        _ reusableView: UIView?
    ) -> UIView

    /// The sole source of hierarchy, expansion, selection, focus, and reveal state.
    public var model: FileTreeModel<Node> {
        didSet {
            guard oldValue !== model else { return }
            cancelDropHoverExpansion()
            oldValue.cancelActiveRename()
            observedModelIdentifier = nil
            observedRenamingID = nil
            lastRevealSequence = nil
            bindToModel()
        }
    }

    /// Rendering and native interaction behavior.
    public var configuration: FileTreeConfiguration {
        didSet {
            guard oldValue != configuration else { return }
            applyConfiguration()
            synchronizeFromModel()
        }
    }

    /// Creates or updates the caller-owned content portion of each mounted row.
    public var rowProvider: RowProvider {
        didSet {
            refreshMountedRows()
        }
    }

    /// Invoked for UIKit's primary item action, such as a direct tap or keyboard activation.
    public var onActivate: ((Node) -> Void)?

    private let flowLayout: UICollectionViewFlowLayout
    private let collectionView: UICollectionView
    private var revisionCancellable: AnyCancellable?

    private var observedModelIdentifier: ObjectIdentifier?
    private var observedDataRevision: UInt64?
    private var observedExpansionRevision: UInt64?
    private var observedSearchRevision: UInt64?
    private var observedRenamingID: Node.ID?
    private var visibleIndexByID: [Node.ID: Int] = [:]
    private var lastRevealSequence: UInt64?

    private var isSynchronizing = false
    private var synchronizationPending = false
    private var lastLayoutDirection: UIUserInterfaceLayoutDirection?
    private var lastCollectionWidth: CGFloat?
    private var currentDropTarget: FileTreeDropTarget?
    private var hoveredDropPath: String?
    private var hoverExpansionTask: Task<Void, Never>?

    /// Creates a UIKit tree renderer backed by a stable model.
    public init(
        model: FileTreeModel<Node>,
        configuration: FileTreeConfiguration = .init(),
        rowProvider: @escaping RowProvider
    ) {
        self.model = model
        self.configuration = configuration
        self.rowProvider = rowProvider

        let flowLayout = UICollectionViewFlowLayout()
        flowLayout.scrollDirection = .vertical
        flowLayout.minimumLineSpacing = 0
        flowLayout.minimumInteritemSpacing = 0
        flowLayout.estimatedItemSize = .zero
        self.flowLayout = flowLayout

        collectionView = UICollectionView(frame: .zero, collectionViewLayout: flowLayout)
        super.init(frame: .zero)

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.dragDelegate = self
        collectionView.dropDelegate = self
        collectionView.dragInteractionEnabled = true
        collectionView.register(
            UIKitFileTreeCell.self,
            forCellWithReuseIdentifier: UIKitFileTreeCell.reuseIdentifier
        )

        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let backgroundTap = UITapGestureRecognizer(target: self, action: #selector(clearSelectionFromBackground(_:)))
        backgroundTap.cancelsTouchesInView = false
        backgroundTap.delegate = self
        collectionView.addGestureRecognizer(backgroundTap)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleExpansionFromDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delegate = self
        collectionView.addGestureRecognizer(doubleTap)
        backgroundTap.require(toFail: doubleTap)

        applyConfiguration()
        bindToModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FileTreeView does not support initialization from a coder")
    }

    /// Reloads mounted row content after caller-owned decoration data changes.
    public func reloadRows(withIDs identifiers: Set<Node.ID>? = nil) {
        guard let identifiers else {
            refreshMountedRows()
            return
        }

        for case let cell as UIKitFileTreeCell in collectionView.visibleCells {
            guard
                let indexPath = collectionView.indexPath(for: cell),
                let row = visibleRow(at: indexPath.item),
                !identifiers.isDisjoint(with: row.representedIDs)
            else { continue }
            configure(cell, at: indexPath)
        }
    }

    /// Asks the native collection view to become first responder.
    @discardableResult
    public func focusTree() -> Bool {
        collectionView.becomeFirstResponder()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()

        let collectionWidth = collectionView.bounds.width
        if collectionWidth != lastCollectionWidth {
            lastCollectionWidth = collectionWidth
            flowLayout.invalidateLayout()
        }

        let direction = effectiveUserInterfaceLayoutDirection
        if direction != lastLayoutDirection {
            lastLayoutDirection = direction
            applyLayoutInsets(for: direction)
        }
    }

    public override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let focusedID = model.focusedID,
           let index = visibleIndexByID[focusedID],
           let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0))
        {
            return [cell]
        }
        return [collectionView]
    }

    public override func didUpdateFocus(
        in context: UIFocusUpdateContext,
        with coordinator: UIFocusAnimationCoordinator
    ) {
        super.didUpdateFocus(in: context, with: coordinator)

        let previousCell = treeCell(containing: context.previouslyFocusedView)
        let nextCell = treeCell(containing: context.nextFocusedView)

        if let nextCell,
           let indexPath = collectionView.indexPath(for: nextCell),
           let row = visibleRow(at: indexPath.item) {
            model.focus(row.id)
        } else if previousCell != nil {
            model.focus(nil)
        }

        coordinator.addCoordinatedAnimations {
            previousCell?.refreshFocusAppearance()
            nextCell?.refreshFocusAppearance()
        }
    }

    // MARK: - Model synchronization

    private func bindToModel() {
        revisionCancellable = model.$revision.sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.synchronizeFromModel()
            }
        }
    }

    private func synchronizeFromModel() {
        guard !isSynchronizing else {
            synchronizationPending = true
            return
        }

        isSynchronizing = true
        defer {
            isSynchronizing = false
            if synchronizationPending {
                synchronizationPending = false
                synchronizeFromModel()
            }
        }

        normalizeModelSelectionIfNeeded()

        let shouldRestoreTreeFocus = observedRenamingID != nil && model.activeRenamingID == nil
        observedRenamingID = model.activeRenamingID

        let modelIdentifier = ObjectIdentifier(model)
        let structureChanged = observedModelIdentifier != modelIdentifier
            || observedDataRevision != model.dataRevision
            || observedExpansionRevision != model.expansionRevision
            || observedSearchRevision != model.searchRevision

        if structureChanged {
            observedModelIdentifier = modelIdentifier
            observedDataRevision = model.dataRevision
            observedExpansionRevision = model.expansionRevision
            observedSearchRevision = model.searchRevision
            rebuildVisibleIndex()
            collectionView.reloadData()
        }

        synchronizeCollectionSelection()
        refreshMountedRows()
        consumeRevealRequestIfNeeded()
        if shouldRestoreTreeFocus {
            collectionView.becomeFirstResponder()
            setNeedsFocusUpdate()
        }
    }

    private func normalizeModelSelectionIfNeeded() {
        var normalizedSelection = model.selection

        if case .single = configuration.selectionMode, normalizedSelection.count > 1 {
            if let focusedID = model.focusedID, normalizedSelection.contains(focusedID) {
                normalizedSelection = [focusedID]
            } else if let firstSelectedID = model.preparedTree.preorderIDs
                .first(where: normalizedSelection.contains) {
                normalizedSelection = [firstSelectedID]
            }
        }

        if !configuration.allowsEmptySelection,
           normalizedSelection.isEmpty,
           let firstVisibleID = model.visibleRows.first?.id
        {
            normalizedSelection = [firstVisibleID]
        }

        if normalizedSelection != model.selection {
            model.setSelection(normalizedSelection)
        }
    }

    private func rebuildVisibleIndex() {
        visibleIndexByID.removeAll(keepingCapacity: true)
        visibleIndexByID.reserveCapacity(model.visibleRows.count)
        for (index, row) in model.visibleRows.enumerated() {
            visibleIndexByID[row.id] = index
        }
    }

    private func synchronizeCollectionSelection() {
        let currentIndexPaths = Set(collectionView.indexPathsForSelectedItems ?? [])
        let desiredIndexPaths = Set(model.selection.compactMap { id -> IndexPath? in
            guard let index = visibleIndexByID[id] else { return nil }
            return IndexPath(item: index, section: 0)
        })

        for indexPath in currentIndexPaths.subtracting(desiredIndexPaths) {
            collectionView.deselectItem(at: indexPath, animated: false)
        }
        for indexPath in desiredIndexPaths.subtracting(currentIndexPaths) {
            collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        }
    }

    private func consumeRevealRequestIfNeeded() {
        guard let request = model.revealRequest,
              request.sequence != lastRevealSequence,
              let index = visibleIndexByID[request.id]
        else { return }

        lastRevealSequence = request.sequence
        let indexPath = IndexPath(item: index, section: 0)
        collectionView.layoutIfNeeded()

        switch request.position {
        case .center:
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
        case .top:
            collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
        case .nearest:
            scrollToNearestEdgeIfNeeded(indexPath)
        }

        if request.focus {
            collectionView.layoutIfNeeded()
            collectionView.becomeFirstResponder()
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    private func scrollToNearestEdgeIfNeeded(_ indexPath: IndexPath) {
        guard let attributes = collectionView.layoutAttributesForItem(at: indexPath) else {
            collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
            return
        }

        let visibleBounds = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        if attributes.frame.minY < visibleBounds.minY {
            collectionView.scrollToItem(at: indexPath, at: .top, animated: false)
        } else if attributes.frame.maxY > visibleBounds.maxY {
            collectionView.scrollToItem(at: indexPath, at: .bottom, animated: false)
        }
    }

    // MARK: - Rendering

    private func applyConfiguration() {
        collectionView.allowsMultipleSelection = {
            if case .multiple = configuration.selectionMode { return true }
            return false
        }()
        applyLayoutInsets(for: effectiveUserInterfaceLayoutDirection)
        flowLayout.invalidateLayout()
        refreshMountedRows()
    }

    private func applyLayoutInsets(for direction: UIUserInterfaceLayoutDirection) {
        let insets = configuration.contentInsets
        let left = direction == .rightToLeft ? insets.trailing : insets.leading
        let right = direction == .rightToLeft ? insets.leading : insets.trailing
        flowLayout.sectionInset = UIEdgeInsets(
            top: insets.top,
            left: left,
            bottom: insets.bottom,
            right: right
        )
        flowLayout.invalidateLayout()
    }

    private func refreshMountedRows() {
        for case let cell as UIKitFileTreeCell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell) else { continue }
            configure(cell, at: indexPath)
        }
    }

    private func configure(_ cell: UIKitFileTreeCell, at indexPath: IndexPath) {
        guard let row = visibleRow(at: indexPath.item) else { return }
        let context = makeContext(for: row, at: indexPath.item)
        let nodeID = row.id

        cell.configure(
            context: context,
            configuration: configuration,
            contentProvider: { [rowProvider] reusableView in
                rowProvider(row.node, context, reusableView)
            },
            onToggleExpansion: { [weak self] in
                self?.model.toggleExpansion(of: nodeID)
            }
        )
        cell.configureRename(
            id: nodeID,
            isRenaming: context.isRenaming,
            value: (row.node as? FileTreePath)?.name ?? "",
            onCommit: { [weak self] name in
                self?.model.submitActiveRename(name) ?? false
            },
            onCancel: { [weak self] in
                self?.model.cancelActiveRename()
            }
        )
    }

    private func visibleRow(at index: Int) -> FileTreeVisibleRow<Node>? {
        guard model.visibleRows.indices.contains(index) else { return nil }
        return model.visibleRows[index]
    }

    private func makeContext(
        for row: FileTreeVisibleRow<Node>,
        at index: Int
    ) -> FileTreeRowContext<Node.ID> {
        FileTreeRowContext(
            id: row.id,
            visibleIndex: index,
            depth: row.depth,
            parentID: row.parentID,
            siblingIndex: row.siblingIndex,
            siblingCount: row.siblingCount,
            isExpandable: model.isRenderedExpandable(row.id),
            isExpanded: model.isRenderedExpanded(row.id),
            isSelected: model.selection.contains(row.id),
            isFocused: model.focusedID == row.id,
            isSearchMatch: model.isSearchMatch(row.id),
            isRenaming: model.activeRenamingID == row.id,
            segments: row.segments
        )
    }

    // MARK: - UICollectionViewDataSource

    public func numberOfSections(in collectionView: UICollectionView) -> Int {
        1
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        model.visibleRows.count
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: UIKitFileTreeCell.reuseIdentifier,
            for: indexPath
        ) as! UIKitFileTreeCell
        configure(cell, at: indexPath)
        return cell
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        didEndDisplaying cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard let renamingID = model.activeRenamingID,
              let treeCell = cell as? UIKitFileTreeCell,
              treeCell.activeRenameID == AnyHashable(renamingID)
        else { return }
        guard let currentIndex = visibleIndexByID[renamingID] else {
            model.cancelActiveRename()
            return
        }
        guard collectionView.cellForItem(
            at: IndexPath(item: currentIndex, section: indexPath.section)
        ) == nil else {
            return
        }
        model.cancelActiveRename()
    }

    // MARK: - Native drag and drop

    public func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: any UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard
            let pathModel = model as? FileTreeModel<FileTreePath>,
            let id = visibleRow(at: indexPath.item)?.id as? String,
            let dragSession = try? pathModel.makeDragSession(startingAt: id)
        else { return [] }

        return dragSession.sourcePaths.map { path in
            let item = UIDragItem(itemProvider: NSItemProvider(object: path.path as NSString))
            item.localObject = dragSession
            return item
        }
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        itemsForAddingTo session: any UIDragSession,
        at indexPath: IndexPath,
        point: CGPoint
    ) -> [UIDragItem] {
        []
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        canHandle session: any UIDropSession
    ) -> Bool {
        guard let pathModel = model as? FileTreeModel<FileTreePath> else { return false }
        return session.localDragSession != nil
            && session.items.contains {
                ($0.localObject as? FileTreeDragSession)?.originID
                    == pathModel.fileTreeDragDropOriginID
            }
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        dropSessionDidUpdate session: any UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        guard
            let pathModel = model as? FileTreeModel<FileTreePath>,
            let dragSession = session.items.compactMap({
                $0.localObject as? FileTreeDragSession
            }).first,
            let target = dropTarget(
                at: session.location(in: collectionView),
                destinationIndexPath: destinationIndexPath,
                model: pathModel
            ),
            pathModel.canDrop(dragSession, target: target)
        else {
            currentDropTarget = nil
            cancelDropHoverExpansion()
            return UICollectionViewDropProposal(operation: .forbidden)
        }

        currentDropTarget = target
        scheduleDropHoverExpansion(for: target, model: pathModel)
        let intent: UICollectionViewDropProposal.Intent = target.position == .inside
            && target.path != nil
            ? .insertIntoDestinationIndexPath
            : .insertAtDestinationIndexPath
        return UICollectionViewDropProposal(operation: .move, intent: intent)
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        performDropWith coordinator: any UICollectionViewDropCoordinator
    ) {
        defer {
            currentDropTarget = nil
            cancelDropHoverExpansion()
        }
        guard
            let pathModel = model as? FileTreeModel<FileTreePath>,
            let dragSession = coordinator.items.compactMap({
                $0.dragItem.localObject as? FileTreeDragSession
            }).first,
            let target = currentDropTarget
        else { return }

        do {
            let event = try pathModel.performDrop(dragSession, target: target)
            let fallbackRenderedID = target.path.flatMap {
                pathModel.visibleRow(for: $0.id)?.id
            }
            for (offset, item) in coordinator.items.enumerated() {
                let destinationID = event.moves.indices.contains(offset)
                    ? event.moves[offset].destinationPath.id
                    : nil
                let renderedID = destinationID.flatMap {
                    pathModel.visibleRow(for: $0)?.id
                } ?? fallbackRenderedID
                guard let renderedID,
                      let finalIndex = pathModel.visibleRows.firstIndex(where: {
                          $0.id == renderedID
                      })
                else { continue }
                coordinator.drop(
                    item.dragItem,
                    toItemAt: IndexPath(item: finalIndex, section: 0)
                )
            }
        } catch {
            return
        }
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        dropSessionDidExit session: any UIDropSession
    ) {
        currentDropTarget = nil
        cancelDropHoverExpansion()
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        dropSessionDidEnd session: any UIDropSession
    ) {
        currentDropTarget = nil
        cancelDropHoverExpansion()
    }

    private func dropTarget(
        at location: CGPoint,
        destinationIndexPath: IndexPath?,
        model: FileTreeModel<FileTreePath>
    ) -> FileTreeDropTarget? {
        let proposedIndexPath = destinationIndexPath.flatMap { indexPath in
            visibleRow(at: indexPath.item) == nil ? nil : indexPath
        } ?? collectionView.indexPathForItem(at: location)
        guard let indexPath = proposedIndexPath,
              let row = visibleRow(at: indexPath.item),
              let id = row.id as? String,
              let path = model.preparedTree.node(for: id)
        else {
            return .init(path: nil, position: .inside)
        }

        let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame
            ?? collectionView.cellForItem(at: indexPath)?.frame
            ?? .zero
        let relativeY = frame.height > 0 ? (location.y - frame.minY) / frame.height : 0.5
        if path.kind == .directory, relativeY >= 0.25, relativeY <= 0.75 {
            return model.renderedDropTarget(for: path.id, position: .inside)
        }
        return model.renderedDropTarget(
            for: path.id,
            position: relativeY < 0.5 ? .before : .after
        )
    }

    private func scheduleDropHoverExpansion(
        for target: FileTreeDropTarget,
        model: FileTreeModel<FileTreePath>
    ) {
        guard target.position == .inside,
              let path = target.path,
              path.kind == .directory,
              !model.expandedIDs.contains(path.id)
        else {
            cancelDropHoverExpansion()
            return
        }
        guard hoveredDropPath != path.id else { return }
        cancelDropHoverExpansion()
        hoveredDropPath = path.id
        let delay = model.dragDropOpenDelay
        hoverExpansionTask = Task { @MainActor [weak self, weak model] in
            if delay > 0 {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled,
                  let self, self.hoveredDropPath == path.id, let model else { return }
            model.expand(path.id)
        }
    }

    private func cancelDropHoverExpansion() {
        hoveredDropPath = nil
        hoverExpansionTask?.cancel()
        hoverExpansionTask = nil
    }

    // MARK: - UICollectionViewDelegate

    public func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        let horizontalInsets = flowLayout.sectionInset.left + flowLayout.sectionInset.right
        return CGSize(
            width: max(1, collectionView.bounds.width - horizontalInsets),
            height: configuration.rowHeight
        )
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        shouldDeselectItemAt indexPath: IndexPath
    ) -> Bool {
        configuration.allowsEmptySelection || (collectionView.indexPathsForSelectedItems?.count ?? 0) > 1
    }

    public func collectionView(
        _ collectionView: UICollectionView,
        canFocusItemAt indexPath: IndexPath
    ) -> Bool {
        true
    }

    public func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let row = visibleRow(at: indexPath.item) else { return }
        switch configuration.selectionMode {
        case .single:
            model.select(row.id)
        case .multiple:
            model.select(row.id, extendingSelection: true)
        }
    }

    public func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        guard case .multiple = configuration.selectionMode,
              let row = visibleRow(at: indexPath.item)
        else { return }

        var selection = model.selection
        selection.remove(row.id)
        if !selection.isEmpty || configuration.allowsEmptySelection {
            model.setSelection(selection)
        } else {
            synchronizeCollectionSelection()
        }
    }

    @available(iOS 16.0, tvOS 16.0, *)
    public func collectionView(
        _ collectionView: UICollectionView,
        performPrimaryActionForItemAt indexPath: IndexPath
    ) {
        guard let node = visibleRow(at: indexPath.item)?.node else { return }
        onActivate?(node)
    }

    // MARK: - Gestures

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        var touchedView: UIView? = touch.view
        while let view = touchedView, view !== collectionView {
            if view is UIControl { return false }
            touchedView = view.superview
        }

        let point = touch.location(in: collectionView)
        let isOnRow = collectionView.indexPathForItem(at: point) != nil
        if let tap = gestureRecognizer as? UITapGestureRecognizer, tap.numberOfTapsRequired == 2 {
            return isOnRow && configuration.expandsBranchesOnDoubleClick
        }
        return !isOnRow && configuration.allowsEmptySelection
    }

    @objc private func clearSelectionFromBackground(_ gestureRecognizer: UITapGestureRecognizer) {
        guard gestureRecognizer.state == .ended, configuration.allowsEmptySelection else { return }
        model.deselectAll()
    }

    @objc private func toggleExpansionFromDoubleTap(_ gestureRecognizer: UITapGestureRecognizer) {
        guard gestureRecognizer.state == .ended, configuration.expandsBranchesOnDoubleClick else { return }
        let point = gestureRecognizer.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point),
              let row = visibleRow(at: indexPath.item),
              model.preparedTree.isExpandable(row.id)
        else { return }
        model.toggleExpansion(of: row.id)
    }

    private func treeCell(containing view: UIView?) -> UIKitFileTreeCell? {
        var candidate = view
        while let current = candidate, current !== collectionView {
            if let cell = current as? UIKitFileTreeCell {
                return cell
            }
            candidate = current.superview
        }
        return nil
    }
}

public extension FileTreeView where Node == FileTreePath {
    /// Creates a native file tree with TreeKit's built-in icon-and-name row.
    convenience init(
        model: FileTreeModel<FileTreePath>,
        configuration: FileTreeConfiguration = .init()
    ) {
        self.init(model: model, configuration: configuration) { node, context, reusableView in
            let row = (reusableView as? UIKitDefaultFileTreeRowView)
                ?? UIKitDefaultFileTreeRowView()
            row.update(with: node, segments: context.segments)
            return row
        }
    }
}

@MainActor
private final class UIKitFileTreeCell: UICollectionViewCell {
    static let reuseIdentifier = "TreeKit.UIKitFileTreeCell"

    private let disclosureButton = UIButton(type: .system)
    private let hostedContentView = UIView()
    private let separatorView = UIView()
    private let renameField = UIKitRenameTextField()

    private var renderedContentView: UIView?
    private var onToggleExpansion: (() -> Void)?
    private var rowDepth = 0
    private var indentation: CGFloat = 0
    private var appearance: FileTreeAppearance = .sourceList
    private var isFocusedRow = false
    private var showsSeparator = false
    private(set) var activeRenameID: AnyHashable?
    private var onCommitRename: ((String) -> Bool)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentView.clipsToBounds = true

        let normalBackground = UIView()
        normalBackground.backgroundColor = .clear
        backgroundView = normalBackground
        selectedBackgroundView = UIView()

        disclosureButton.tintColor = .secondaryLabel
        disclosureButton.addTarget(self, action: #selector(toggleExpansion), for: .touchUpInside)
        disclosureButton.accessibilityIdentifier = "TreeKit.Disclosure"

        hostedContentView.clipsToBounds = true
        separatorView.isUserInteractionEnabled = false

        contentView.addSubview(disclosureButton)
        contentView.addSubview(hostedContentView)
        contentView.addSubview(separatorView)
        renameField.isHidden = true
        renameField.backgroundColor = .systemBackground
        renameField.borderStyle = .roundedRect
        renameField.returnKeyType = .done
        renameField.clearButtonMode = .never
        renameField.addTarget(self, action: #selector(commitRename), for: .editingDidEndOnExit)
        contentView.addSubview(renameField)
        updateSelectionAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("UIKitFileTreeCell does not support initialization from a coder")
    }

    override var isSelected: Bool {
        didSet { updateSelectionAppearance() }
    }

    override var isHighlighted: Bool {
        didSet { updateSelectionAppearance() }
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateSelectionAppearance()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onToggleExpansion = nil
        disclosureButton.isHidden = true
        separatorView.isHidden = true
        isFocusedRow = false
        activeRenameID = nil
        onCommitRename = nil
        renameField.isHidden = true
        renameField.onCancel = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let bounds = contentView.bounds
        let disclosureWidth = min(20, bounds.width)
        let indent = max(0, CGFloat(rowDepth) * indentation)
        let gap: CGFloat = 2
        let direction = effectiveUserInterfaceLayoutDirection

        let contentFrame: CGRect
        if direction == .rightToLeft {
            let disclosureMaxX = max(0, bounds.width - min(indent, bounds.width))
            let disclosureMinX = max(0, disclosureMaxX - disclosureWidth)
            disclosureButton.frame = CGRect(
                x: disclosureMinX,
                y: 0,
                width: disclosureWidth,
                height: bounds.height
            )
            contentFrame = CGRect(
                x: 0,
                y: 0,
                width: max(0, disclosureMinX - gap),
                height: bounds.height
            )
        } else {
            let disclosureMinX = min(indent, bounds.width)
            disclosureButton.frame = CGRect(
                x: disclosureMinX,
                y: 0,
                width: min(disclosureWidth, max(0, bounds.width - disclosureMinX)),
                height: bounds.height
            )
            let contentMinX = min(bounds.width, disclosureButton.frame.maxX + gap)
            contentFrame = CGRect(
                x: contentMinX,
                y: 0,
                width: max(0, bounds.width - contentMinX),
                height: bounds.height
            )
        }

        hostedContentView.frame = contentFrame
        renderedContentView?.frame = hostedContentView.bounds
        renameField.frame = hostedContentView.frame

        let separatorHeight = 1 / max(1, traitCollection.displayScale)
        separatorView.frame = CGRect(
            x: contentFrame.minX,
            y: max(0, bounds.height - separatorHeight),
            width: max(0, bounds.width - contentFrame.minX),
            height: separatorHeight
        )

        let selectionFrame: CGRect
        switch appearance {
        case .plain:
            selectionFrame = bounds
        case .sourceList:
            selectionFrame = bounds.insetBy(dx: 2, dy: 1)
        }
        backgroundView?.frame = selectionFrame
        selectedBackgroundView?.frame = selectionFrame
    }

    func configure<ID: Hashable>(
        context: FileTreeRowContext<ID>,
        configuration: FileTreeConfiguration,
        contentProvider: (_ reusableView: UIView?) -> UIView,
        onToggleExpansion: @escaping () -> Void
    ) {
        rowDepth = context.depth
        indentation = configuration.indentation
        appearance = configuration.appearance
        isFocusedRow = context.isFocused
        showsSeparator = configuration.showsSeparators
        self.onToggleExpansion = onToggleExpansion

        disclosureButton.isHidden = !context.isExpandable
        disclosureButton.isEnabled = context.isExpandable
        disclosureButton.setImage(
            UIImage(systemName: context.isExpanded ? "chevron.down" : "chevron.right"),
            for: .normal
        )
        disclosureButton.accessibilityLabel = context.isExpanded ? "Collapse" : "Expand"

        let nextContentView = contentProvider(renderedContentView)
        if nextContentView !== renderedContentView {
            renderedContentView?.removeFromSuperview()
            renderedContentView = nextContentView
            nextContentView.translatesAutoresizingMaskIntoConstraints = true
            nextContentView.frame = hostedContentView.bounds
            nextContentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            hostedContentView.addSubview(nextContentView)
        }

        isSelected = context.isSelected
        separatorView.isHidden = !showsSeparator
        separatorView.backgroundColor = .separator
        updateSelectionAppearance()
        setNeedsLayout()
    }

    func configureRename<ID: Hashable>(
        id: ID,
        isRenaming: Bool,
        value: String,
        onCommit: @escaping (String) -> Bool,
        onCancel: @escaping () -> Void
    ) {
        guard isRenaming else {
            activeRenameID = nil
            onCommitRename = nil
            renameField.isHidden = true
            renameField.onCancel = nil
            return
        }

        let nextID = AnyHashable(id)
        let isStarting = activeRenameID != nextID
        if isStarting {
            renameField.text = value
            activeRenameID = nextID
        }
        onCommitRename = onCommit
        renameField.onCancel = onCancel
        renameField.isHidden = false
        contentView.bringSubviewToFront(renameField)
        setNeedsLayout()
        if isStarting {
            Task { @MainActor [weak self] in
                guard let self, !self.renameField.isHidden else { return }
                self.renameField.becomeFirstResponder()
                self.renameField.selectAll(nil)
            }
        }
    }

    private func updateSelectionAppearance() {
        let selectionColor: UIColor
        switch appearance {
        case .plain:
            selectionColor = .systemFill
            selectedBackgroundView?.layer.cornerRadius = 0
        case .sourceList:
            let alpha: CGFloat = isFocusedRow || isFocused ? 0.28 : 0.18
            selectionColor = tintColor.withAlphaComponent(alpha)
            selectedBackgroundView?.layer.cornerRadius = 5
        }
        selectedBackgroundView?.backgroundColor = selectionColor
        selectedBackgroundView?.alpha = isHighlighted ? 0.72 : 1
    }

    func refreshFocusAppearance() {
        updateSelectionAppearance()
    }

    @objc private func toggleExpansion() {
        onToggleExpansion?()
    }

    @objc private func commitRename() {
        if onCommitRename?(renameField.text ?? "") == false {
            renameField.becomeFirstResponder()
            renameField.selectAll(nil)
        }
    }

}

@MainActor
private final class UIKitRenameTextField: UITextField {
    var onCancel: (() -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(
                input: UIKeyCommand.inputEscape,
                modifierFlags: [],
                action: #selector(cancelFromKeyboard)
            )
        ]
    }

    @objc private func cancelFromKeyboard() {
        onCancel?()
    }
}

@MainActor
private final class UIKitDefaultFileTreeRowView: UIView {
    private let iconView = UIImageView()
    private let nameLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        iconView.tintColor = .secondaryLabel

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.lineBreakMode = .byTruncatingMiddle

        addSubview(iconView)
        addSubview(nameLabel)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("UIKitDefaultFileTreeRowView does not support initialization from a coder")
    }

    func update(
        with node: FileTreePath,
        segments: [FileTreeRowSegment<String>]
    ) {
        nameLabel.text = segments.map(\.label).joined(separator: " / ")
        iconView.image = UIImage(systemName: node.kind == .directory ? "folder" : "doc")
        accessibilityLabel = segments.map(\.label).joined(separator: " / ")
        accessibilityValue = node.kind == .directory ? "Folder" : "File"
    }
}
#endif
