#if canImport(AppKit)
import AppKit
import Combine

/// A native AppKit file-tree view backed by `NSOutlineView` row reuse.
///
/// AppKit callers provide and update native row views directly. The optional reusable view is
/// the content returned by a previous invocation for the recycled outline cell.
@MainActor
public final class FileTreeView<Node: Identifiable>: NSView {
    public typealias RowProvider = @MainActor (
        _ node: Node,
        _ context: FileTreeRowContext<Node.ID>,
        _ reusableView: NSView?
    ) -> NSView

    public var model: FileTreeModel<Node> {
        didSet {
            guard oldValue !== model else { return }
            oldValue.cancelActiveRename()
            normalizeModelSelectionIfNeeded()
            coordinator.invalidateModel()
            coordinator.synchronize(forceRowReload: true)
            bindToModel()
        }
    }

    public var configuration: FileTreeConfiguration {
        didSet {
            applyConfiguration()
            if !normalizeModelSelectionIfNeeded() {
                coordinator.synchronize(forceRowReload: true)
            }
        }
    }

    public var rowProvider: RowProvider {
        didSet { coordinator.reloadMountedRows() }
    }

    /// Called for a leaf double-click, or for any double-click when branch toggling is disabled.
    public var onActivate: ((Node) -> Void)?

    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private var coordinator: Coordinator!
    private var modelObservation: AnyCancellable?
    private var lastLayoutDirection: NSUserInterfaceLayoutDirection?

    public init(
        model: FileTreeModel<Node>,
        configuration: FileTreeConfiguration = .init(),
        rowProvider: @escaping RowProvider
    ) {
        self.model = model
        self.configuration = configuration
        self.rowProvider = rowProvider
        super.init(frame: .zero)

        coordinator = Coordinator(owner: self)
        configureHierarchyView()
        observeViewportChanges()
        applyConfiguration()
        normalizeModelSelectionIfNeeded()
        coordinator.synchronize(forceRowReload: true)
        bindToModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(model:configuration:rowProvider:)")
    }

    /// Reloads mounted row content after caller-owned decoration data changes.
    public func reloadRows(withIDs identifiers: Set<Node.ID>? = nil) {
        if let identifiers {
            coordinator.reloadRows(withIDs: identifiers)
        } else {
            coordinator.reloadMountedRows()
        }
    }

    /// Makes the native outline view first responder.
    @discardableResult
    public func focusTree() -> Bool {
        window?.makeFirstResponder(outlineView) ?? false
    }

    public override func layout() {
        super.layout()
        let direction = userInterfaceLayoutDirection
        if direction != lastLayoutDirection {
            lastLayoutDirection = direction
            applyContentInsets(for: direction)
        }
    }

    private func configureHierarchyView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false

        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        outlineView.headerView = nil
        outlineView.backgroundColor = .clear
        outlineView.intercellSpacing = .zero
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.target = coordinator
        outlineView.doubleAction = #selector(Coordinator.didDoubleClick(_:))
        outlineView.registerForDraggedTypes([Coordinator.pathPasteboardType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setAccessibilityRole(.outline)
        outlineView.setAccessibilityLabel("File tree")

        let column = NSTableColumn(identifier: Coordinator.columnIdentifier)
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private func observeViewportChanges() {
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewportBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @objc private func viewportBoundsDidChange(_ notification: Notification) {
        coordinator.cancelRenameIfOffscreen()
    }

    private func applyConfiguration() {
        outlineView.style = configuration.appearance == .sourceList ? .sourceList : .plain
        outlineView.selectionHighlightStyle = .regular
        outlineView.rowHeight = configuration.rowHeight
        outlineView.indentationPerLevel = configuration.indentation
        outlineView.allowsMultipleSelection = configuration.selectionMode == .multiple
        outlineView.allowsEmptySelection = configuration.allowsEmptySelection
        outlineView.gridStyleMask = configuration.showsSeparators ? .solidHorizontalGridLineMask : []
        let direction = userInterfaceLayoutDirection
        lastLayoutDirection = direction
        applyContentInsets(for: direction)
    }

    private func applyContentInsets(for direction: NSUserInterfaceLayoutDirection) {
        let insets = configuration.contentInsets
        let left = direction == .rightToLeft ? insets.trailing : insets.leading
        let right = direction == .rightToLeft ? insets.leading : insets.trailing
        scrollView.contentView.contentInsets = NSEdgeInsets(
            top: insets.top,
            left: left,
            bottom: insets.bottom,
            right: right
        )
    }

    private func bindToModel() {
        modelObservation = model.$revision
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                if !self.normalizeModelSelectionIfNeeded() {
                    self.coordinator.synchronize()
                }
            }
    }

    @discardableResult
    private func normalizeModelSelectionIfNeeded() -> Bool {
        var normalizedSelection = model.selection

        if configuration.selectionMode == .single, normalizedSelection.count > 1 {
            if let focusedID = model.focusedID, normalizedSelection.contains(focusedID) {
                normalizedSelection = [focusedID]
            } else if let firstSelectedID = model.preparedTree.preorderIDs
                .first(where: normalizedSelection.contains) {
                normalizedSelection = [firstSelectedID]
            }
        }

        if !configuration.allowsEmptySelection,
           normalizedSelection.isEmpty,
           let firstVisibleID = model.visibleRows.first?.id {
            normalizedSelection = [firstVisibleID]
        }

        guard normalizedSelection != model.selection else { return false }
        model.setSelection(normalizedSelection)
        return true
    }
}

public extension FileTreeView where Node == FileTreePath {
    /// Creates a native file tree with TreeKit's built-in icon-and-name row.
    convenience init(
        model: FileTreeModel<FileTreePath>,
        configuration: FileTreeConfiguration = .init()
    ) {
        self.init(model: model, configuration: configuration) { node, context, reusableView in
            let row = (reusableView as? AppKitDefaultFileTreeRowView)
                ?? AppKitDefaultFileTreeRowView()
            row.update(with: node, segments: context.segments)
            return row
        }
    }
}

@MainActor
private extension FileTreeView {
    final class ItemBox: NSObject {
        let id: Node.ID

        init(id: Node.ID) {
            self.id = id
        }

        override var hash: Int { id.hashValue }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? ItemBox else { return false }
            return id == other.id
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        static var columnIdentifier: NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("TreeKit.FileTree.Column")
        }

        static var pathPasteboardType: NSPasteboard.PasteboardType {
            NSPasteboard.PasteboardType("software.trees.TreeKit.paths")
        }

        private static var cellIdentifier: NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("TreeKit.FileTree.Row")
        }

        weak var owner: FileTreeView?

        private var boxesByID: [Node.ID: ItemBox] = [:]
        private var appliedDataRevision: UInt64?
        private var appliedExpansionRevision: UInt64?
        private var appliedSearchRevision: UInt64?
        private var appliedRenameRevision: UInt64?
        private var requestedExpandedIDs: Set<Node.ID> = []
        private var appliedExpandedIDs: Set<Node.ID> = []
        private var knownNativeExpandedIDs: Set<Node.ID> = []
        private var pendingCollapseIDs: Set<Node.ID> = []
        private var appliedSelection: Set<Node.ID> = []
        private var appliedFocusedID: Node.ID?
        private var appliedRenamingID: Node.ID?
        private var appliedRevealSequence: UInt64 = 0
        private var isApplyingModelState = false
        private var hoveredDropPath: String?
        private var hoverExpansionTask: Task<Void, Never>?

        init(owner: FileTreeView) {
            self.owner = owner
        }

        func invalidateModel() {
            boxesByID = [:]
            appliedDataRevision = nil
            appliedExpansionRevision = nil
            appliedSearchRevision = nil
            appliedRenameRevision = nil
            requestedExpandedIDs = []
            appliedExpandedIDs = []
            knownNativeExpandedIDs = []
            pendingCollapseIDs = []
            appliedSelection = []
            appliedFocusedID = nil
            appliedRenamingID = nil
            appliedRevealSequence = 0
            hoveredDropPath = nil
            hoverExpansionTask?.cancel()
            hoverExpansionTask = nil
        }

        func synchronize(forceRowReload: Bool = false) {
            guard let owner else { return }
            let outlineView = owner.outlineView

            isApplyingModelState = true
            defer { isApplyingModelState = false }

            var dataChanged = false
            var searchChanged = false
            if appliedDataRevision != owner.model.dataRevision {
                boxesByID.removeAll(keepingCapacity: true)
                boxesByID.reserveCapacity(owner.model.preparedTree.count)
                for id in owner.model.preparedTree.preorderIDs {
                    boxesByID[id] = ItemBox(id: id)
                }
                outlineView.reloadData()
                appliedDataRevision = owner.model.dataRevision
                appliedSearchRevision = owner.model.searchRevision
                appliedExpansionRevision = nil
                requestedExpandedIDs = []
                appliedExpandedIDs = []
                knownNativeExpandedIDs = []
                pendingCollapseIDs = []
                appliedSelection = []
                appliedFocusedID = nil
                dataChanged = true
            } else if appliedSearchRevision != owner.model.searchRevision {
                outlineView.reloadData()
                appliedSearchRevision = owner.model.searchRevision
                appliedExpansionRevision = nil
                requestedExpandedIDs = []
                appliedExpandedIDs = []
                knownNativeExpandedIDs = []
                pendingCollapseIDs = []
                searchChanged = true
            }

            var expansionChangedIDs: Set<Node.ID> = []
            if appliedExpansionRevision != owner.model.expansionRevision {
                expansionChangedIDs = requestedExpandedIDs.symmetricDifference(
                    owner.model.renderedExpandedIDs
                )
                applyExpansion(to: outlineView)
                requestedExpandedIDs = owner.model.renderedExpandedIDs
                appliedExpansionRevision = owner.model.expansionRevision
            }

            let selectionChangedIDs = appliedSelection.symmetricDifference(owner.model.selection)
            let focusChangedIDs: Set<Node.ID> = appliedFocusedID == owner.model.focusedID
                ? []
                : Set([appliedFocusedID, owner.model.focusedID].compactMap { $0 })
            var renameChangedIDs: Set<Node.ID> = []
            if appliedRenameRevision != owner.model.renameRevision {
                if appliedRenamingID != owner.model.activeRenamingID {
                    renameChangedIDs = Set(
                        [appliedRenamingID, owner.model.activeRenamingID].compactMap { $0 }
                    )
                }
                let shouldRestoreTreeFocus = appliedRenamingID != nil
                    && owner.model.activeRenamingID == nil
                appliedRenamingID = owner.model.activeRenamingID
                appliedRenameRevision = owner.model.renameRevision
                if shouldRestoreTreeFocus {
                    _ = owner.window?.makeFirstResponder(outlineView)
                }
            }
            if dataChanged || searchChanged || !selectionChangedIDs.isEmpty
                || !focusChangedIDs.isEmpty {
                applySelection(to: outlineView)
            }

            let rowIDsToReload = expansionChangedIDs
                .union(selectionChangedIDs)
                .union(focusChangedIDs)
                .union(renameChangedIDs)
            if forceRowReload || dataChanged || searchChanged {
                reloadMountedRows()
            } else if !rowIDsToReload.isEmpty {
                reloadRows(withIDs: rowIDsToReload)
            }

            applyRevealRequest(to: outlineView)
        }

        func reloadMountedRows() {
            guard let owner else { return }
            let outlineView = owner.outlineView
            let visibleRows = outlineView.rows(in: outlineView.visibleRect)
            guard visibleRows.location != NSNotFound, visibleRows.length > 0 else { return }
            var rowIndexes = IndexSet(
                integersIn: visibleRows.location..<(visibleRows.location + visibleRows.length)
            )
            if let activeID = owner.model.activeRenamingID,
               hasMountedRenameEditor(for: activeID, in: outlineView),
               let box = boxesByID[activeID] {
                let activeRow = outlineView.row(forItem: box)
                if activeRow >= 0 { rowIndexes.remove(activeRow) }
            }
            guard !rowIndexes.isEmpty else { return }
            outlineView.reloadData(
                forRowIndexes: rowIndexes,
                columnIndexes: IndexSet(integer: 0)
            )
        }

        func reloadRows(withIDs identifiers: Set<Node.ID>) {
            guard let owner else { return }
            let outlineView = owner.outlineView
            let indexes = Set(identifiers.compactMap { id -> Int? in
                let renderedID = owner.model.visibleRow(for: id)?.id ?? id
                if renderedID == owner.model.activeRenamingID,
                   hasMountedRenameEditor(for: renderedID, in: outlineView) {
                    return nil
                }
                guard let box = boxesByID[renderedID] else { return nil }
                let row = outlineView.row(forItem: box)
                return row >= 0 ? row : nil
            })
            guard !indexes.isEmpty else { return }
            outlineView.reloadData(
                forRowIndexes: IndexSet(indexes),
                columnIndexes: IndexSet(integer: 0)
            )
        }

        private func hasMountedRenameEditor(
            for id: Node.ID,
            in outlineView: NSOutlineView
        ) -> Bool {
            guard let box = boxesByID[id] else { return false }
            let row = outlineView.row(forItem: box)
            guard row >= 0,
                  let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false)
                    as? AppKitTreeRowHostCell
            else { return false }
            return cell.activeRenameID?.base as? Node.ID == id
        }

        func cancelRenameIfOffscreen() {
            guard let owner, let id = owner.model.activeRenamingID else { return }
            guard let box = boxesByID[id] else {
                owner.model.cancelActiveRename()
                return
            }
            let row = owner.outlineView.row(forItem: box)
            let mountedRows = owner.outlineView.rows(in: owner.outlineView.visibleRect)
            guard row >= 0, mountedRows.location != NSNotFound,
                  NSLocationInRange(row, mountedRows)
            else {
                owner.model.cancelActiveRename()
                return
            }
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            numberOfChildrenOfItem item: Any?
        ) -> Int {
            IDs(for: item).count
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            child index: Int,
            ofItem item: Any?
        ) -> Any {
            let id = IDs(for: item)[index]
            return boxesByID[id] as Any
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let owner, let box = item as? ItemBox else { return false }
            return owner.model.isRenderedExpandable(box.id)
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            pasteboardWriterForItem item: Any
        ) -> (any NSPasteboardWriting)? {
            guard
                let owner,
                let pathModel = owner.model as? FileTreeModel<FileTreePath>,
                let box = item as? ItemBox,
                let id = box.id as? String,
                let session = try? pathModel.makeDragSession(startingAt: id)
            else { return nil }

            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setPropertyList(
                session.sourcePaths.map(\.path),
                forType: Self.pathPasteboardType
            )
            return pasteboardItem
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: any NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            guard
                let owner,
                let pathModel = owner.model as? FileTreeModel<FileTreePath>,
                let session = dragSession(from: info.draggingPasteboard),
                let target = dropTarget(item: item, childIndex: index, model: pathModel),
                pathModel.canDrop(session, target: target)
            else {
                cancelHoverExpansion()
                return []
            }

            scheduleHoverExpansion(for: target, model: pathModel)
            outlineView.setDropItem(item, dropChildIndex: index)
            return .move
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            acceptDrop info: any NSDraggingInfo,
            item: Any?,
            childIndex index: Int
        ) -> Bool {
            defer { cancelHoverExpansion() }
            guard
                let owner,
                let pathModel = owner.model as? FileTreeModel<FileTreePath>,
                let session = dragSession(from: info.draggingPasteboard),
                let target = dropTarget(item: item, childIndex: index, model: pathModel)
            else { return false }
            do {
                try pathModel.performDrop(session, target: target)
                return true
            } catch {
                return false
            }
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            cancelHoverExpansion()
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            viewFor tableColumn: NSTableColumn?,
            item: Any
        ) -> NSView? {
            guard
                let owner,
                let box = item as? ItemBox,
                let node = owner.model.preparedTree.node(for: box.id)
            else { return nil }

            let cell = (outlineView.makeView(withIdentifier: Self.cellIdentifier, owner: nil)
                as? AppKitTreeRowHostCell) ?? AppKitTreeRowHostCell()
            cell.identifier = Self.cellIdentifier
            let context = rowContext(for: box.id, in: outlineView)
            let content = owner.rowProvider(node, context, cell.contentView)
            cell.setContentView(content)
            cell.configureRename(
                id: box.id,
                isRenaming: context.isRenaming,
                value: (node as? FileTreePath)?.name ?? "",
                onCommit: { [weak owner] name in
                    owner?.model.submitActiveRename(name) ?? false
                },
                onCancel: { [weak owner] in
                    owner?.model.cancelActiveRename()
                }
            )
            return cell
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            didRemove rowView: NSTableRowView,
            forRow row: Int
        ) {
            guard
                let owner,
                let cell = rowView.view(atColumn: 0) as? AppKitTreeRowHostCell,
                let id = cell.activeRenameID?.base as? Node.ID,
                owner.model.activeRenamingID == id
            else { return }

            Task { @MainActor [weak self] in
                guard let self, let owner = self.owner,
                      owner.model.activeRenamingID == id else { return }
                guard let currentBox = self.boxesByID[id] else {
                    owner.model.cancelActiveRename()
                    return
                }
                let currentRow = outlineView.row(forItem: currentBox)
                if currentRow < 0 || outlineView.rowView(atRow: currentRow, makeIfNecessary: false) == nil {
                    owner.model.cancelActiveRename()
                }
            }
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            owner?.configuration.rowHeight ?? 22
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard
                !isApplyingModelState,
                let owner,
                let outlineView = notification.object as? NSOutlineView
            else { return }

            let selection = Set(outlineView.selectedRowIndexes.compactMap { row in
                (outlineView.item(atRow: row) as? ItemBox)?.id
            })
            let focusedID = (outlineView.item(atRow: outlineView.selectedRow) as? ItemBox)?.id
            owner.model.synchronizeSelection(selection, focusedID: focusedID)
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard
                !isApplyingModelState,
                let owner,
                let box = notification.userInfo?["NSObject"] as? ItemBox
            else { return }
            owner.model.expand(box.id)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard
                !isApplyingModelState,
                let owner,
                let box = notification.userInfo?["NSObject"] as? ItemBox
            else { return }

            let isForcedSearchExpansion = owner.model.isRenderedExpanded(box.id)
                && !owner.model.expandedIDs.contains(box.id)
            owner.model.collapse(box.id)

            // Search projections can force a canonically collapsed ancestor open. Native
            // disclosure clicks still collapse NSOutlineView directly, so replay the model's
            // rendered expansion when the canonical collapse above intentionally changed nothing.
            // Defer until AppKit has finished its native collapse transaction; expanding from
            // inside the did-collapse notification violates NSOutlineView's internal state.
            if isForcedSearchExpansion {
                appliedExpansionRevision = nil
                Task { @MainActor [weak self] in
                    self?.synchronize()
                }
            }
        }

        @objc func didDoubleClick(_ sender: NSOutlineView) {
            guard
                let owner,
                sender.clickedRow >= 0,
                let box = sender.item(atRow: sender.clickedRow) as? ItemBox,
                let node = owner.model.preparedTree.node(for: box.id)
            else { return }

            if owner.configuration.expandsBranchesOnDoubleClick,
               owner.model.isRenderedExpandable(box.id) {
                owner.model.toggleExpansion(of: box.id)
            } else {
                owner.onActivate?(node)
            }
        }

        private func IDs(for item: Any?) -> [Node.ID] {
            guard let owner else { return [] }
            if let box = item as? ItemBox {
                return owner.model.renderedChildIDs(of: box.id)
            }
            return owner.model.renderedRootIDs
        }

        private func dragSession(from pasteboard: NSPasteboard) -> FileTreeDragSession? {
            guard
                let propertyList = pasteboard.propertyList(forType: Self.pathPasteboardType)
                    as? [String]
            else { return nil }
            let paths = propertyList.compactMap { try? FileTreePath(path: $0) }
            guard !paths.isEmpty else { return nil }
            return FileTreeDragSession(sourcePaths: paths)
        }

        private func dropTarget(
            item: Any?,
            childIndex index: Int,
            model: FileTreeModel<FileTreePath>
        ) -> FileTreeDropTarget? {
            let parentPath = (item as? ItemBox)
                .flatMap { $0.id as? String }
                .flatMap { model.preparedTree.node(for: $0) }
            if index == NSOutlineViewDropOnItemIndex {
                guard let parentPath else { return .init(path: nil, position: .inside) }
                return .init(path: parentPath, position: .inside)
            }

            let childIDs: [String]
            if let parentPath {
                childIDs = model.renderedChildIDs(of: parentPath.id)
            } else {
                childIDs = model.renderedRootIDs
            }
            if childIDs.indices.contains(index),
               let child = model.preparedTree.node(for: childIDs[index]) {
                return .init(path: child, position: .before)
            }
            if let lastID = childIDs.last,
               let last = model.preparedTree.node(for: lastID) {
                return .init(path: last, position: .after)
            }
            if let parentPath {
                return .init(path: parentPath, position: .inside)
            }
            return .init(path: nil, position: .inside)
        }

        private func scheduleHoverExpansion(
            for target: FileTreeDropTarget,
            model: FileTreeModel<FileTreePath>
        ) {
            guard target.position == .inside,
                  let path = target.path,
                  path.kind == .directory,
                  !model.expandedIDs.contains(path.id)
            else {
                cancelHoverExpansion()
                return
            }
            guard hoveredDropPath != path.id else { return }
            cancelHoverExpansion()
            hoveredDropPath = path.id
            let delay = model.dragDropOpenDelay
            hoverExpansionTask = Task { @MainActor [weak self, weak model] in
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard let self, self.hoveredDropPath == path.id, let model else { return }
                model.expand(path.id)
            }
        }

        private func cancelHoverExpansion() {
            hoveredDropPath = nil
            hoverExpansionTask?.cancel()
            hoverExpansionTask = nil
        }

        private func rowContext(
            for id: Node.ID,
            in outlineView: NSOutlineView
        ) -> FileTreeRowContext<Node.ID> {
            guard let owner else {
                preconditionFailure("A mounted tree coordinator must have an owner")
            }
            let tree = owner.model.preparedTree
            let projectedRow = owner.model.visibleRow(for: id)
            let visibleIndex = boxesByID[id].map { outlineView.row(forItem: $0) } ?? -1
            return FileTreeRowContext(
                id: id,
                visibleIndex: visibleIndex,
                depth: projectedRow?.depth ?? tree.depthByID[id] ?? 0,
                parentID: projectedRow?.parentID ?? tree.parentByID[id],
                siblingIndex: projectedRow?.siblingIndex ?? tree.siblingIndexByID[id] ?? 0,
                siblingCount: projectedRow?.siblingCount ?? tree.siblingCount(of: id),
                isExpandable: owner.model.isRenderedExpandable(id),
                isExpanded: owner.model.isRenderedExpanded(id),
                isSelected: owner.model.selection.contains(id),
                isFocused: owner.model.focusedID == id,
                isSearchMatch: owner.model.isSearchMatch(id),
                isRenaming: owner.model.activeRenamingID == id,
                segments: projectedRow?.segments ?? [
                    FileTreeRowSegment(
                        id: id,
                        label: (tree.nodesByID[id] as? FileTreePath)?.name
                            ?? String(describing: id),
                        isTerminal: true
                    )
                ]
            )
        }

        private func applyExpansion(to outlineView: NSOutlineView) {
            guard let owner else { return }
            let target = owner.model.renderedExpandedIDs
            pendingCollapseIDs.subtract(target)

            let collapsing = knownNativeExpandedIDs.subtracting(target)
                .union(pendingCollapseIDs)
                .sorted {
                (owner.model.preparedTree.depth(of: $0) ?? 0)
                    > (owner.model.preparedTree.depth(of: $1) ?? 0)
            }
            for id in collapsing {
                if let box = boxesByID[id] {
                    guard outlineView.row(forItem: box) >= 0 else {
                        pendingCollapseIDs.insert(id)
                        appliedExpandedIDs.remove(id)
                        continue
                    }
                    outlineView.collapseItem(box)
                    if outlineView.isItemExpanded(box) {
                        pendingCollapseIDs.insert(id)
                    } else {
                        pendingCollapseIDs.remove(id)
                        appliedExpandedIDs.remove(id)
                        knownNativeExpandedIDs.remove(id)
                    }
                }
            }

            // Collapsing an ancestor can make a descendant's native expansion unknowable or
            // inactive. Remove only previously applied branches from the cache; desired hidden
            // branches will be retried below when their ancestors become visible.
            appliedExpandedIDs = Set(appliedExpandedIDs.filter { id in
                guard let box = boxesByID[id] else { return false }
                guard outlineView.row(forItem: box) >= 0 else { return false }
                return outlineView.isItemExpanded(box)
            })

            let expanding = target.subtracting(appliedExpandedIDs).sorted {
                (owner.model.preparedTree.depth(of: $0) ?? 0)
                    < (owner.model.preparedTree.depth(of: $1) ?? 0)
            }
            for id in expanding {
                if let box = boxesByID[id] {
                    outlineView.expandItem(box)
                    if outlineView.row(forItem: box) >= 0, outlineView.isItemExpanded(box) {
                        appliedExpandedIDs.insert(id)
                        knownNativeExpandedIDs.insert(id)
                    }
                }
            }

            // A newly expanded ancestor can reveal a pending native branch that the model has
            // since collapsed. Retry only those known IDs instead of scanning the complete tree.
            let retryingCollapse = pendingCollapseIDs.sorted {
                (owner.model.preparedTree.depth(of: $0) ?? 0)
                    > (owner.model.preparedTree.depth(of: $1) ?? 0)
            }
            for id in retryingCollapse {
                if let box = boxesByID[id] {
                    guard outlineView.row(forItem: box) >= 0 else { continue }
                    outlineView.collapseItem(box)
                    if !outlineView.isItemExpanded(box) {
                        pendingCollapseIDs.remove(id)
                        appliedExpandedIDs.remove(id)
                        knownNativeExpandedIDs.remove(id)
                    }
                }
            }
        }

        private func applySelection(to outlineView: NSOutlineView) {
            guard let owner else { return }
            let rows = owner.model.selection.compactMap { id -> Int? in
                guard let box = boxesByID[id] else { return nil }
                let row = outlineView.row(forItem: box)
                return row >= 0 ? row : nil
            }

            outlineView.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
            appliedSelection = owner.model.selection
            appliedFocusedID = owner.model.focusedID
        }

        private func applyRevealRequest(to outlineView: NSOutlineView) {
            guard
                let owner,
                let request = owner.model.revealRequest,
                request.sequence != appliedRevealSequence,
                let box = boxesByID[request.id]
            else { return }

            appliedRevealSequence = request.sequence
            let row = outlineView.row(forItem: box)
            guard row >= 0 else { return }

            outlineView.scrollRowToVisible(row)
            let rowRect = outlineView.rect(ofRow: row)
            let visibleRect = owner.scrollView.contentView.visibleRect

            switch request.position {
            case .nearest:
                break
            case .center:
                outlineView.scroll(
                    NSPoint(x: visibleRect.origin.x, y: max(0, rowRect.midY - visibleRect.height / 2))
                )
            case .top:
                outlineView.scroll(NSPoint(x: visibleRect.origin.x, y: max(0, rowRect.minY)))
            }

            if request.focus {
                _ = owner.window?.makeFirstResponder(outlineView)
            }
        }
    }
}

@MainActor
private final class AppKitTreeRowHostCell: NSTableCellView {
    private(set) var contentView: NSView?
    private let renameField = AppKitRenameTextField()
    private(set) var activeRenameID: AnyHashable?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        renameField.translatesAutoresizingMaskIntoConstraints = false
        renameField.isHidden = true
        addSubview(renameField)
        NSLayoutConstraint.activate([
            renameField.leadingAnchor.constraint(equalTo: leadingAnchor),
            renameField.trailingAnchor.constraint(equalTo: trailingAnchor),
            renameField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func setContentView(_ view: NSView) {
        guard contentView !== view else { return }
        contentView?.removeFromSuperview()
        contentView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        addSubview(renameField, positioned: .above, relativeTo: view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
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
            renameField.isHidden = true
            renameField.onCommit = nil
            renameField.onCancel = nil
            return
        }

        let nextID = AnyHashable(id)
        let isStarting = activeRenameID != nextID
        if isStarting {
            renameField.stringValue = value
            activeRenameID = nextID
        }
        renameField.representedID = nextID
        renameField.onCommit = onCommit
        renameField.onCancel = onCancel
        renameField.isHidden = false
        if isStarting {
            renameField.selectText(nil)
            Task { @MainActor [weak self] in
                guard let self, !self.renameField.isHidden else { return }
                _ = self.window?.makeFirstResponder(self.renameField)
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        activeRenameID = nil
        renameField.isHidden = true
        renameField.onCommit = nil
        renameField.onCancel = nil
    }
}

@MainActor
private final class AppKitRenameTextField: NSTextField {
    var representedID: AnyHashable?
    var onCommit: ((String) -> Bool)?
    var onCancel: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = true
        isBezeled = true
        bezelStyle = .roundedBezel
        target = self
        action = #selector(commitRename)
        focusRingType = .default
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:)")
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    @objc private func commitRename() {
        if onCommit?(stringValue) == false {
            selectText(nil)
            _ = window?.makeFirstResponder(self)
        }
    }
}

@MainActor
private final class AppKitDefaultFileTreeRowView: NSView {
    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        iconView.contentTintColor = .secondaryLabelColor

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.lineBreakMode = .byTruncatingMiddle

        addSubview(iconView)
        addSubview(nameField)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            nameField.trailingAnchor.constraint(equalTo: trailingAnchor),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func update(
        with node: FileTreePath,
        segments: [FileTreeRowSegment<String>]
    ) {
        nameField.stringValue = segments.map(\.label).joined(separator: " / ")
        iconView.image = NSImage(
            systemSymbolName: node.kind == .directory ? "folder" : "doc",
            accessibilityDescription: node.kind == .directory ? "Folder" : "File"
        )
    }
}
#endif
