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

        private static var cellIdentifier: NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("TreeKit.FileTree.Row")
        }

        weak var owner: FileTreeView?

        private var boxesByID: [Node.ID: ItemBox] = [:]
        private var appliedDataRevision: UInt64?
        private var appliedExpansionRevision: UInt64?
        private var appliedSearchRevision: UInt64?
        private var requestedExpandedIDs: Set<Node.ID> = []
        private var appliedExpandedIDs: Set<Node.ID> = []
        private var knownNativeExpandedIDs: Set<Node.ID> = []
        private var pendingCollapseIDs: Set<Node.ID> = []
        private var appliedSelection: Set<Node.ID> = []
        private var appliedFocusedID: Node.ID?
        private var appliedRevealSequence: UInt64 = 0
        private var isApplyingModelState = false

        init(owner: FileTreeView) {
            self.owner = owner
        }

        func invalidateModel() {
            boxesByID = [:]
            appliedDataRevision = nil
            appliedExpansionRevision = nil
            appliedSearchRevision = nil
            requestedExpandedIDs = []
            appliedExpandedIDs = []
            knownNativeExpandedIDs = []
            pendingCollapseIDs = []
            appliedSelection = []
            appliedFocusedID = nil
            appliedRevealSequence = 0
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
            let focusChangedIDs = Set([appliedFocusedID, owner.model.focusedID].compactMap { $0 })
            applySelection(to: outlineView)

            let rowIDsToReload = expansionChangedIDs
                .union(selectionChangedIDs)
                .union(focusChangedIDs)
            if forceRowReload || dataChanged || searchChanged {
                reloadMountedRows()
            } else if !rowIDsToReload.isEmpty {
                reloadRows(withIDs: rowIDsToReload)
            }

            applyRevealRequest(to: outlineView)
        }

        func reloadMountedRows() {
            guard let outlineView = owner?.outlineView else { return }
            let visibleRows = outlineView.rows(in: outlineView.visibleRect)
            guard visibleRows.location != NSNotFound, visibleRows.length > 0 else { return }
            outlineView.reloadData(
                forRowIndexes: IndexSet(
                    integersIn: visibleRows.location..<(visibleRows.location + visibleRows.length)
                ),
                columnIndexes: IndexSet(integer: 0)
            )
        }

        func reloadRows(withIDs identifiers: Set<Node.ID>) {
            guard let owner else { return }
            let outlineView = owner.outlineView
            let indexes = Set(identifiers.compactMap { id -> Int? in
                let renderedID = owner.model.visibleRow(for: id)?.id ?? id
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
            return cell
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

    func setContentView(_ view: NSView) {
        guard contentView !== view else { return }
        contentView?.removeFromSuperview()
        contentView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
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
