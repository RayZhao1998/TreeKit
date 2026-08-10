import Combine
import Foundation

/// Stable, model-first state for a rendered file tree.
///
/// Keep one model alive for the lifetime of a tree surface. Replace its prepared data with
/// ``reset(_:preservingExpansion:preservingSelection:)`` and mutate selection or expansion
/// through the methods below instead of rebuilding the SwiftUI view hierarchy.
@MainActor
public final class FileTreeModel<Node: Identifiable>: ObservableObject {
    /// The immutable hierarchy currently presented by the model.
    public private(set) var preparedTree: PreparedTree<Node>

    /// Stable identity-based selection. Selection may contain collapsed descendants.
    public private(set) var selection: Set<Node.ID>

    /// Stable identity-based branch expansion.
    public private(set) var expandedIDs: Set<Node.ID>

    /// The focused row identity, if any.
    public private(set) var focusedID: Node.ID?

    internal private(set) var activeRenamingID: Node.ID?
    internal private(set) var activeRenameError: FileTreeRenameError?

    /// Emits the current selection immediately, then only distinct selection changes.
    ///
    /// Use this publisher for sibling UI that does not need to observe unrelated model revisions.
    public var selectionChanges: AnyPublisher<Set<Node.ID>, Never> {
        selectionChangeSubject()
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    /// Emits the current focused identity immediately, then only distinct focus changes.
    ///
    /// Focus is independent from selection, so command routing can move through visible rows
    /// without changing the selected identities.
    public var focusChanges: AnyPublisher<Node.ID?, Never> {
        focusChangeSubject()
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    /// The visible projection in depth-first preorder.
    public private(set) var visibleRows: [FileTreeVisibleRow<Node>]

    /// The normalized, path-style query for the current search session.
    public private(set) var searchQuery: String

    /// Matching identities in deterministic prepared-tree preorder.
    public private(set) var matchingIDs: [Node.ID]

    /// Whether the model currently owns an open search session.
    public private(set) var isSearchOpen: Bool

    /// The projection policy applied while search is open with a nonempty query.
    public private(set) var searchMode: FileTreeSearchMode

    /// Advances once after each complete model transaction.
    @Published public private(set) var revision: UInt64 = 0

    internal var dataRevision: UInt64 = 0
    internal var expansionRevision: UInt64 = 0
    internal var searchRevision: UInt64 = 0
    internal var renameRevision: UInt64 = 0
    internal var revealRequest: FileTreeRevealRequest<Node.ID>?
    internal private(set) var renderedExpandedIDs: Set<Node.ID>

    private var visibleIndexByID: [Node.ID: Int] = [:]
    private var revealSequence: UInt64 = 0
    private var lastFocusedVisibleIndex: Int?
    private var matchingIDSet: Set<Node.ID> = []
    private var searchVisibleIDSet: Set<Node.ID>?
    private var normalizedSearchTextByID: [Node.ID: String]?
    internal var pathFlattenEmptyDirectories = false
    private let searchText: (Node) -> String
    private var selectionChangesSubject: CurrentValueSubject<Set<Node.ID>, Never>?
    private var focusChangesSubject: CurrentValueSubject<Node.ID?, Never>?
    internal var fileTreePathMutationState: FileTreePathMutationState? = nil
    internal var fileTreePathMutationSubject: PassthroughSubject<
        FileTreePathMutationEvent,
        Never
    >? = nil
    internal var fileTreeRenameConfiguration: FileTreeRenameConfiguration? = nil
    internal var fileTreeRenameSubject: PassthroughSubject<FileTreeRenameEvent, Never>? = nil
    private var activeRenameCommit: ((String) -> Result<Void, FileTreeRenameError>)?
    private var activeRenameCancel: (() -> Void)?

    /// Creates a stable tree model from prepared data.
    public init(
        _ preparedTree: PreparedTree<Node>,
        initialExpansion: FileTreeInitialExpansion<Node.ID> = .collapsed,
        initialSelection: Set<Node.ID> = [],
        searchMode: FileTreeSearchMode = .hideNonMatches,
        searchText: @escaping (Node) -> String = { String(describing: $0.id) }
    ) {
        let selection = initialSelection.filtering { preparedTree.contains($0) }
        let expandedIDs = Self.expandedIDs(for: initialExpansion, in: preparedTree)
        let pathOptions = (preparedTree as? PreparedTree<FileTreePath>)?.fileTreePathOptions
        self.preparedTree = preparedTree
        self.selection = selection
        self.expandedIDs = expandedIDs
        self.focusedID = preparedTree.preorderIDs.first { selection.contains($0) }
        self.pathFlattenEmptyDirectories = pathOptions?.flattenEmptyDirectories ?? false
        self.activeRenamingID = nil
        self.activeRenameError = nil
        self.visibleRows = Self.makeVisibleRows(
            in: preparedTree,
            expandedIDs: expandedIDs,
            flattenEmptyDirectories: pathOptions?.flattenEmptyDirectories ?? false
        )
        self.searchQuery = ""
        self.matchingIDs = []
        self.isSearchOpen = false
        self.searchMode = searchMode
        self.renderedExpandedIDs = expandedIDs
        self.searchText = searchText
        self.lastFocusedVisibleIndex = nil
        rebuildVisibleIndex()
        if pathFlattenEmptyDirectories {
            self.selection = Set(selection.map { interactionID(for: $0) })
            self.expandedIDs = Set(expandedIDs.map { canonicalInteractionID(for: $0) }).filtering {
                preparedTree.isExpandable($0)
            }
            self.focusedID = focusedID.map { interactionID(for: $0) }
            self.renderedExpandedIDs = self.expandedIDs
            rebuildVisibleRows()
        }
        rememberFocusedVisibleIndex()
    }

    /// Replaces the complete hierarchy atomically from the renderer's perspective.
    ///
    /// Retained identities preserve selection and expansion by default. Removed identities are
    /// pruned before AppKit receives the new snapshot.
    public func reset(
        _ nextPreparedTree: PreparedTree<Node>,
        preservingExpansion: Bool = true,
        preservingSelection: Bool = true
    ) {
        let nextExpansion = preservingExpansion
            ? expandedIDs.filtering {
                nextPreparedTree.contains($0) && nextPreparedTree.isExpandable($0)
            }
            : []
        let nextSelection = preservingSelection
            ? selection.filtering { nextPreparedTree.contains($0) }
            : []
        let nextFocus = focusedID.flatMap { nextPreparedTree.contains($0) ? $0 : nil }

        // A generic prepared tree cannot distinguish caller-supplied directories from synthesized
        // ancestors. Treat every prepared FileTreePath node as explicit if callers later use the
        // path-first mutation interface. `resetPaths` retains the more precise source-path state.
        if let fileTree = nextPreparedTree as? PreparedTree<FileTreePath> {
            var state = FileTreePathMutationState(preparedTree: fileTree)
            state.options.flattenEmptyDirectories = pathFlattenEmptyDirectories
            fileTreePathMutationState = state
        }

        replacePreparedTree(
            nextPreparedTree,
            expandedIDs: nextExpansion,
            selection: nextSelection,
            focusedID: nextFocus
        )
    }

    internal func replacePreparedTree(
        _ nextPreparedTree: PreparedTree<Node>,
        expandedIDs nextExpansion: Set<Node.ID>,
        selection nextSelection: Set<Node.ID>,
        focusedID nextFocus: Node.ID?
    ) {
        clearRenameSession(publishing: false)
        preparedTree = nextPreparedTree
        expandedIDs = nextExpansion.filtering {
            nextPreparedTree.contains($0) && nextPreparedTree.isExpandable($0)
        }
        selection = nextSelection.filtering { nextPreparedTree.contains($0) }
        focusedID = nextFocus.flatMap { nextPreparedTree.contains($0) ? $0 : nil }
        normalizedSearchTextByID = nil
        refreshSearchMatches(selectingFallbackFocus: true)
        rebuildVisibleRows()
        selection = Set(selection.map { interactionID(for: $0) })
        focusedID = focusedID.map { interactionID(for: $0) }
        let projectedExpansion = Set(expandedIDs.map { canonicalInteractionID(for: $0) }).filtering {
            nextPreparedTree.isExpandable($0)
        }
        if projectedExpansion != expandedIDs {
            expandedIDs = projectedExpansion
            rebuildVisibleRows()
        }
        dataRevision &+= 1
        expansionRevision &+= 1
        searchRevision &+= 1
        publishChange()
    }

    internal func pathMutationSubject() -> PassthroughSubject<
        FileTreePathMutationEvent,
        Never
    > {
        if let fileTreePathMutationSubject {
            return fileTreePathMutationSubject
        }
        let subject = PassthroughSubject<FileTreePathMutationEvent, Never>()
        fileTreePathMutationSubject = subject
        return subject
    }

    internal func beginRenameSession(
        id: Node.ID,
        commit: @escaping (String) -> Result<Void, FileTreeRenameError>,
        cancel: @escaping () -> Void
    ) {
        activeRenamingID = id
        activeRenameError = nil
        activeRenameCommit = commit
        activeRenameCancel = cancel
        renameRevision &+= 1
        publishChange()
    }

    @discardableResult
    internal func submitActiveRename(_ name: String) -> Bool {
        guard let activeRenameCommit else { return false }
        switch activeRenameCommit(name) {
        case .success:
            return true
        case .failure:
            return false
        }
    }

    internal func cancelActiveRename() {
        guard activeRenamingID != nil else { return }
        let cancel = activeRenameCancel
        clearRenameSession(publishing: true)
        cancel?()
    }

    internal func clearRenameSession(publishing: Bool) {
        let hadSession = activeRenamingID != nil || activeRenameError != nil
        activeRenamingID = nil
        activeRenameError = nil
        activeRenameCommit = nil
        activeRenameCancel = nil
        guard hadSession else { return }
        renameRevision &+= 1
        guard publishing else { return }
        publishChange()
    }

    internal func reportRenameError(_ error: FileTreeRenameError) {
        activeRenameError = error
        renameRevision &+= 1
        publishChange()
    }

    private func selectionChangeSubject() -> CurrentValueSubject<Set<Node.ID>, Never> {
        if let selectionChangesSubject {
            return selectionChangesSubject
        }
        let subject = CurrentValueSubject<Set<Node.ID>, Never>(selection)
        selectionChangesSubject = subject
        return subject
    }

    private func focusChangeSubject() -> CurrentValueSubject<Node.ID?, Never> {
        if let focusChangesSubject {
            return focusChangesSubject
        }
        let subject = CurrentValueSubject<Node.ID?, Never>(focusedID)
        focusChangesSubject = subject
        return subject
    }

    /// Replaces selection with known identifiers from the current hierarchy.
    public func setSelection(_ identifiers: Set<Node.ID>) {
        let valid = Set(identifiers.compactMap { id -> Node.ID? in
            guard preparedTree.contains(id) else { return nil }
            return interactionID(for: id)
        })
        guard valid != selection else { return }

        selection = valid
        if let focusedID, valid.contains(focusedID) {
            publishChange()
            return
        }
        focusedID = preparedTree.preorderIDs.first { valid.contains($0) }
        publishChange()
    }

    /// Selects one identifier, optionally preserving the existing selection.
    public func select(_ id: Node.ID, extendingSelection: Bool = false) {
        guard preparedTree.contains(id) else { return }
        let id = interactionID(for: id)
        let previousSelection = selection
        let previousFocus = focusedID
        if extendingSelection {
            selection.insert(id)
        } else {
            selection = [id]
        }
        focusedID = id
        if selection != previousSelection || focusedID != previousFocus {
            publishChange()
        }
    }

    /// Toggles one identifier in the selection.
    public func toggleSelection(of id: Node.ID) {
        guard preparedTree.contains(id) else { return }
        let id = interactionID(for: id)
        if selection.remove(id) == nil {
            selection.insert(id)
        }
        focusedID = id
        publishChange()
    }

    /// Clears selection without changing expansion.
    public func deselectAll() {
        setSelection([])
    }

    /// Updates the focused row identity without changing selection.
    public func focus(_ id: Node.ID?) {
        guard let id else {
            guard focusedID != nil else { return }
            focusedID = nil
            publishChange()
            return
        }
        guard preparedTree.contains(id) else { return }
        let targetID = interactionID(for: id)
        guard focusedID != targetID else { return }
        focusedID = targetID
        publishChange()
    }

    /// Focuses the first row in the current visible projection.
    @discardableResult
    public func focusFirstItem() -> Node.ID? {
        guard !visibleRows.isEmpty else {
            focus(nil)
            return nil
        }
        return focusVisibleItem(at: visibleRows.startIndex)
    }

    /// Focuses the last row in the current visible projection.
    @discardableResult
    public func focusLastItem() -> Node.ID? {
        guard !visibleRows.isEmpty else {
            focus(nil)
            return nil
        }
        return focusVisibleItem(at: visibleRows.index(before: visibleRows.endIndex))
    }

    /// Focuses the next visible row, clamping at the final row.
    @discardableResult
    public func focusNextItem() -> Node.ID? {
        guard !visibleRows.isEmpty else {
            focus(nil)
            return nil
        }
        guard let currentIndex = nearestVisibleIndex(to: focusedID) else {
            return focusVisibleItem(at: visibleRows.startIndex)
        }
        return focusVisibleItem(at: min(visibleRows.index(before: visibleRows.endIndex), currentIndex + 1))
    }

    /// Focuses the previous visible row, clamping at the first row.
    @discardableResult
    public func focusPreviousItem() -> Node.ID? {
        guard !visibleRows.isEmpty else {
            focus(nil)
            return nil
        }
        guard let currentIndex = nearestVisibleIndex(to: focusedID) else {
            return focusVisibleItem(at: visibleRows.index(before: visibleRows.endIndex))
        }
        return focusVisibleItem(at: max(visibleRows.startIndex, currentIndex - 1))
    }

    /// Focuses the visible parent of the focused row without changing selection.
    @discardableResult
    public func focusParentItem() -> Node.ID? {
        guard let focusedID else { return nil }
        if let row = visibleRow(for: focusedID), let parentID = row.parentID {
            return focusVisibleItem(id: parentID)
        }
        guard let nearestIndex = nearestVisibleIndex(to: focusedID) else { return nil }
        return focusVisibleItem(at: nearestIndex)
    }

    /// Focuses an identity when visible, its closest visible ancestor when hidden, or the nearest
    /// retained visible index when the preferred identity was removed.
    ///
    /// Passing `nil` keeps a visible current focus. Otherwise it recovers from the last focused
    /// row position and finally falls back to the first visible row.
    @discardableResult
    public func focusNearestItem(to preferredID: Node.ID? = nil) -> Node.ID? {
        guard !visibleRows.isEmpty else {
            focus(nil)
            return nil
        }
        if let index = nearestVisibleIndex(to: preferredID ?? focusedID) {
            return focusVisibleItem(at: index)
        }
        if let lastFocusedVisibleIndex {
            return focusVisibleItem(at: min(lastFocusedVisibleIndex, visibleRows.count - 1))
        }
        return focusVisibleItem(at: visibleRows.startIndex)
    }

    /// Expands one branch. Expanding a hidden descendant records state without forcing ancestors open.
    public func expand(_ id: Node.ID) {
        let id = canonicalInteractionID(for: id)
        guard preparedTree.isExpandable(id), expandedIDs.insert(id).inserted else { return }
        if hasActiveSearchQuery {
            rebuildVisibleRows()
        } else {
            renderedExpandedIDs = expandedIDs
            insertVisibleDescendants(of: id)
        }
        expansionRevision &+= 1
        publishChange()
    }

    /// Collapses one branch while retaining nested descendants' expansion state.
    public func collapse(_ id: Node.ID) {
        let id = canonicalInteractionID(for: id)
        guard expandedIDs.remove(id) != nil else { return }
        if hasActiveSearchQuery {
            rebuildVisibleRows()
        } else {
            renderedExpandedIDs = expandedIDs
            removeVisibleDescendants(of: id)
        }
        expansionRevision &+= 1
        publishChange()
    }

    /// Toggles one branch's expansion state.
    public func toggleExpansion(of id: Node.ID) {
        let id = canonicalInteractionID(for: id)
        if expandedIDs.contains(id) {
            collapse(id)
        } else {
            expand(id)
        }
    }

    /// Replaces expansion with known branch identifiers.
    public func setExpandedIDs(_ identifiers: Set<Node.ID>) {
        let valid = Set(identifiers.compactMap { id -> Node.ID? in
            guard preparedTree.contains(id) else { return nil }
            let interactionID = canonicalInteractionID(for: id)
            return preparedTree.isExpandable(interactionID) ? interactionID : nil
        })
        guard valid != expandedIDs else { return }
        expandedIDs = valid
        rebuildVisibleRows()
        expansionRevision &+= 1
        publishChange()
    }

    /// Expands every branch in one projection update.
    public func expandAll() {
        setExpandedIDs(Set(preparedTree.preorderIDs.filter { preparedTree.isExpandable($0) }))
    }

    /// Collapses every branch in one projection update.
    public func collapseAll() {
        setExpandedIDs([])
    }

    /// Opens search and optionally applies an initial query.
    public func openSearch(initialQuery: String = "") {
        applySearch(query: initialQuery, isOpen: true)
    }

    /// Closes search, clears its matches, and restores the canonical expansion projection.
    public func closeSearch() {
        guard isSearchOpen else { return }
        applySearch(query: "", isOpen: false)
    }

    /// Opens search if needed and replaces its normalized query.
    public func setSearchQuery(_ query: String) {
        applySearch(query: query, isOpen: true)
    }

    /// Changes how active matches are projected without changing canonical expansion state.
    public func setSearchMode(_ mode: FileTreeSearchMode) {
        guard mode != searchMode else { return }
        let previouslyVisibleSelection = Set(selection.filter { visibleRow(for: $0) != nil })
        searchMode = mode
        rebuildVisibleRows()
        normalizeSearchInteractionIfNeeded(
            remappingPreviouslyVisibleSelection: previouslyVisibleSelection
        )
        expansionRevision &+= 1
        searchRevision &+= 1
        publishChange()
    }

    /// Focuses the next matching visible row, clamping at the final match.
    public func focusNextSearchMatch() {
        focusSearchMatch(offset: 1)
    }

    /// Focuses the previous matching visible row, clamping at the first match.
    public func focusPreviousSearchMatch() {
        focusSearchMatch(offset: -1)
    }

    /// Expands all ancestors, optionally selects the item, and asks the mounted view to scroll.
    public func reveal(
        _ id: Node.ID,
        select: Bool = true,
        position: FileTreeScrollPosition = .nearest,
        focus: Bool = true
    ) {
        guard preparedTree.contains(id) else { return }
        let id = interactionID(for: id)
        // Filtering search modes own the rendered identity set. Expand-matches keeps the complete
        // hierarchy, so a reveal may still make a currently collapsed target visible.
        guard !hasActiveSearchQuery
            || searchMode == .expandMatches
            || visibleRow(for: id) != nil
        else { return }

        var newlyExpandedAncestors: [Node.ID] = []
        var resolvedAncestorIDs: Set<Node.ID> = []
        for canonicalAncestorID in preparedTree.ancestorIDs(of: id) {
            let ancestorID = interactionID(for: canonicalAncestorID)
            guard preparedTree.isExpandable(ancestorID),
                  resolvedAncestorIDs.insert(ancestorID).inserted,
                  !expandedIDs.contains(ancestorID)
            else { continue }
            newlyExpandedAncestors.append(ancestorID)
        }
        if let firstNewlyExpandedAncestor = newlyExpandedAncestors.first {
            expandedIDs.formUnion(newlyExpandedAncestors)
            if hasActiveSearchQuery {
                rebuildVisibleRows()
            } else {
                renderedExpandedIDs = expandedIDs
                insertVisibleDescendants(of: firstNewlyExpandedAncestor)
            }
            expansionRevision &+= 1
        }

        if select {
            selection = [id]
        }
        if focus {
            focusedID = id
        }
        revealSequence &+= 1
        revealRequest = FileTreeRevealRequest(
            sequence: revealSequence,
            id: id,
            position: position,
            focus: focus
        )
        publishChange()
    }

    /// Reveals and scrolls to one item without forcing selection.
    ///
    /// Pass `focus: false` to preserve model focus while still expanding ancestors and scrolling.
    /// Requests for identities excluded by an active search projection are ignored.
    public func scrollTo(
        _ id: Node.ID,
        position: FileTreeScrollPosition = .nearest,
        focus: Bool = true
    ) {
        reveal(id, select: false, position: position, focus: focus)
    }

    /// Returns a safe copy of a visible row range.
    public func visibleRows(in range: Range<Int>) -> [FileTreeVisibleRow<Node>] {
        let lowerBound = max(0, min(range.lowerBound, visibleRows.count))
        let upperBound = max(lowerBound, min(range.upperBound, visibleRows.count))
        return Array(visibleRows[lowerBound..<upperBound])
    }

    /// Returns a visible row by identity, or `nil` when it is hidden by a collapsed ancestor.
    public func visibleRow(for id: Node.ID) -> FileTreeVisibleRow<Node>? {
        guard let index = visibleIndexByID[id] else { return nil }
        return visibleRows[index]
    }

    internal var renderedRootIDs: [Node.ID] {
        renderedRowIDs(startingAt: preparedTree.rootIDs)
    }

    internal func renderedChildIDs(of id: Node.ID) -> [Node.ID] {
        let terminalID = interactionID(for: id)
        return renderedRowIDs(startingAt: preparedTree.childrenByID[terminalID] ?? [])
    }

    internal func isRenderedExpandable(_ id: Node.ID) -> Bool {
        !renderedChildIDs(of: interactionID(for: id)).isEmpty
    }

    internal func isRenderedExpanded(_ id: Node.ID) -> Bool {
        renderedExpandedIDs.contains(interactionID(for: id))
    }

    internal func isSearchMatch(_ id: Node.ID) -> Bool {
        guard let row = visibleRow(for: id) else { return matchingIDSet.contains(id) }
        return row.representedIDs.contains(where: matchingIDSet.contains)
    }

    private static func expandedIDs(
        for initialExpansion: FileTreeInitialExpansion<Node.ID>,
        in tree: PreparedTree<Node>
    ) -> Set<Node.ID> {
        switch initialExpansion {
        case .collapsed:
            return []
        case .expanded:
            return Set(tree.preorderIDs.filter { tree.isExpandable($0) })
        case .depth(let depth):
            let clampedDepth = max(0, depth)
            return Set(tree.preorderIDs.filter {
                tree.isExpandable($0) && (tree.depth(of: $0) ?? .max) < clampedDepth
            })
        case .identifiers(let identifiers):
            return identifiers.filtering { tree.contains($0) && tree.isExpandable($0) }
        }
    }

    private static func makeVisibleRows(
        in tree: PreparedTree<Node>,
        expandedIDs: Set<Node.ID>,
        visibleIDSet: Set<Node.ID>? = nil,
        flattenEmptyDirectories: Bool
    ) -> [FileTreeVisibleRow<Node>] {
        makeVisibleRows(
            startingAt: tree.rootIDs,
            in: tree,
            expandedIDs: expandedIDs,
            visibleIDSet: visibleIDSet,
            flattenEmptyDirectories: flattenEmptyDirectories,
            depth: 0,
            parentID: nil
        )
    }

    private static func makeVisibleRows(
        startingAt startIDs: [Node.ID],
        in tree: PreparedTree<Node>,
        expandedIDs: Set<Node.ID>,
        visibleIDSet: Set<Node.ID>? = nil,
        flattenEmptyDirectories: Bool,
        depth: Int,
        parentID: Node.ID?
    ) -> [FileTreeVisibleRow<Node>] {
        var result: [FileTreeVisibleRow<Node>] = []
        let visibleStartIDs = visibleIDSet.map { visibleIDs in
            startIDs.filter(visibleIDs.contains)
        } ?? startIDs
        var stack = visibleStartIDs.enumerated().reversed().map { index, id in
            (
                headID: id,
                depth: depth,
                parentID: parentID,
                siblingIndex: index,
                siblingCount: visibleStartIDs.count
            )
        }

        while let pending = stack.popLast() {
            let representedIDs = flattenedDirectoryChain(
                startingAt: pending.headID,
                in: tree,
                visibleIDSet: visibleIDSet,
                enabled: flattenEmptyDirectories
            )
            guard
                let terminalID = representedIDs.last,
                let node = tree.nodesByID[terminalID]
            else { continue }
            let segments = representedIDs.enumerated().map { index, id in
                FileTreeRowSegment(
                    id: id,
                    label: rowLabel(for: id, in: tree),
                    isTerminal: index == representedIDs.count - 1
                )
            }
            result.append(
                FileTreeVisibleRow(
                    node: node,
                    depth: pending.depth,
                    parentID: pending.parentID,
                    siblingIndex: pending.siblingIndex,
                    siblingCount: pending.siblingCount,
                    segments: segments
                )
            )

            if expandedIDs.contains(terminalID) {
                let childIDs = visibleIDSet.map { visibleIDs in
                    (tree.childrenByID[terminalID] ?? []).filter(visibleIDs.contains)
                } ?? (tree.childrenByID[terminalID] ?? [])
                stack.append(
                    contentsOf: childIDs.enumerated().reversed().map { index, childID in
                        (
                            headID: childID,
                            depth: pending.depth + 1,
                            parentID: Optional(terminalID),
                            siblingIndex: index,
                            siblingCount: childIDs.count
                        )
                    }
                )
            }
        }

        return result
    }

    private static func flattenedDirectoryChain(
        startingAt headID: Node.ID,
        in tree: PreparedTree<Node>,
        visibleIDSet: Set<Node.ID>?,
        enabled: Bool
    ) -> [Node.ID] {
        guard enabled, isPathDirectory(headID, in: tree) else { return [headID] }

        var result = [headID]
        var currentID = headID
        while let childIDs = tree.childrenByID[currentID], childIDs.count == 1,
              let childID = childIDs.first,
              visibleIDSet?.contains(childID) != false,
              isPathDirectory(childID, in: tree) {
            result.append(childID)
            currentID = childID
        }
        return result
    }

    private static func isPathDirectory(
        _ id: Node.ID,
        in tree: PreparedTree<Node>
    ) -> Bool {
        (tree.nodesByID[id] as? FileTreePath)?.kind == .directory
    }

    private static func rowLabel(
        for id: Node.ID,
        in tree: PreparedTree<Node>
    ) -> String {
        (tree.nodesByID[id] as? FileTreePath)?.name ?? String(describing: id)
    }

    internal func rebuildVisibleRows() {
        rebuildSearchProjectionState()
        visibleRows = Self.makeVisibleRows(
            in: preparedTree,
            expandedIDs: renderedExpandedIDs,
            visibleIDSet: searchVisibleIDSet,
            flattenEmptyDirectories: pathFlattenEmptyDirectories
        )
        rebuildVisibleIndex()
    }

    private func insertVisibleDescendants(of id: Node.ID) {
        guard let index = visibleIndexByID[id] else { return }
        let row = visibleRows[index]
        let terminalID = row.id
        let rows = Self.makeVisibleRows(
            startingAt: preparedTree.childrenByID[terminalID] ?? [],
            in: preparedTree,
            expandedIDs: expandedIDs,
            flattenEmptyDirectories: pathFlattenEmptyDirectories,
            depth: row.depth + 1,
            parentID: terminalID
        )
        guard !rows.isEmpty else { return }
        visibleRows.insert(contentsOf: rows, at: index + 1)
        rebuildVisibleIndex()
    }

    private func removeVisibleDescendants(of id: Node.ID) {
        guard let index = visibleIndexByID[id] else { return }
        let depth = visibleRows[index].depth
        var end = index + 1
        while end < visibleRows.count, visibleRows[end].depth > depth {
            end += 1
        }
        guard end > index + 1 else { return }
        visibleRows.removeSubrange((index + 1)..<end)
        rebuildVisibleIndex()
    }

    private func rebuildVisibleIndex() {
        visibleIndexByID.removeAll(keepingCapacity: true)
        visibleIndexByID.reserveCapacity(
            visibleRows.reduce(into: 0) { $0 += $1.segments.count }
        )
        for (index, row) in visibleRows.enumerated() {
            for id in row.representedIDs {
                visibleIndexByID[id] = index
            }
        }
    }

    private func interactionID(for id: Node.ID) -> Node.ID {
        if let visibleID = visibleRow(for: id)?.id {
            return visibleID
        }
        return canonicalInteractionID(for: id, visibleIDSet: searchVisibleIDSet)
    }

    private func canonicalInteractionID(
        for id: Node.ID,
        visibleIDSet: Set<Node.ID>? = nil
    ) -> Node.ID {
        return Self.flattenedDirectoryChain(
            startingAt: id,
            in: preparedTree,
            visibleIDSet: visibleIDSet,
            enabled: pathFlattenEmptyDirectories
        ).last ?? id
    }

    internal func setPathFlattenEmptyDirectories(
        _ enabled: Bool,
        publishing: Bool
    ) {
        guard pathFlattenEmptyDirectories != enabled else { return }
        pathFlattenEmptyDirectories = enabled
        rebuildVisibleRows()

        selection = Set(selection.map { interactionID(for: $0) })
        expandedIDs = Set(expandedIDs.map { canonicalInteractionID(for: $0) }).filtering {
            preparedTree.isExpandable($0)
        }
        focusedID = focusedID.map { interactionID(for: $0) }
        rebuildVisibleRows()

        guard publishing else { return }
        dataRevision &+= 1
        expansionRevision &+= 1
        publishChange()
    }

    private func renderedRowIDs(startingAt startIDs: [Node.ID]) -> [Node.ID] {
        let visibleStartIDs = searchVisibleIDSet.map { visibleIDs in
            startIDs.filter(visibleIDs.contains)
        } ?? startIDs
        return visibleStartIDs.compactMap { headID in
            Self.flattenedDirectoryChain(
                startingAt: headID,
                in: preparedTree,
                visibleIDSet: searchVisibleIDSet,
                enabled: pathFlattenEmptyDirectories
            ).last
        }
    }

    private func rememberFocusedVisibleIndex() {
        guard let focusedID, let index = visibleIndexByID[focusedID] else { return }
        lastFocusedVisibleIndex = index
    }

    private func nearestVisibleIndex(to candidateID: Node.ID?) -> Int? {
        guard let candidateID else { return nil }
        if let index = visibleIndexByID[candidateID] {
            return index
        }
        guard preparedTree.contains(candidateID) else { return nil }
        return preparedTree.ancestorIDs(of: candidateID).reversed().lazy
            .compactMap { self.visibleIndexByID[$0] }
            .first
    }

    @discardableResult
    private func focusVisibleItem(id: Node.ID) -> Node.ID? {
        guard let index = visibleIndexByID[id] else { return focusedID }
        return focusVisibleItem(at: index)
    }

    @discardableResult
    private func focusVisibleItem(at index: Int) -> Node.ID? {
        guard visibleRows.indices.contains(index) else { return focusedID }
        let id = visibleRows[index].id
        focusedID = id
        lastFocusedVisibleIndex = index
        revealSequence &+= 1
        revealRequest = FileTreeRevealRequest(
            sequence: revealSequence,
            id: id,
            position: .nearest,
            focus: true
        )
        publishChange()
        return id
    }

    private var hasActiveSearchQuery: Bool {
        isSearchOpen && !searchQuery.isEmpty
    }

    private func applySearch(query: String, isOpen: Bool) {
        let normalizedQuery = isOpen ? Self.normalizeSearchQuery(query) : ""
        guard self.isSearchOpen != isOpen || searchQuery != normalizedQuery else { return }

        self.isSearchOpen = isOpen
        searchQuery = normalizedQuery
        refreshSearchMatches(selectingFallbackFocus: true)
        rebuildVisibleRows()
        normalizeSearchInteractionIfNeeded()
        expansionRevision &+= 1
        searchRevision &+= 1
        publishChange()
    }

    private func refreshSearchMatches(selectingFallbackFocus: Bool) {
        guard hasActiveSearchQuery else {
            matchingIDs = []
            matchingIDSet = []
            return
        }

        let searchTextByID: [Node.ID: String]
        if let normalizedSearchTextByID {
            searchTextByID = normalizedSearchTextByID
        } else {
            var generated: [Node.ID: String] = [:]
            generated.reserveCapacity(preparedTree.count)
            for id in preparedTree.preorderIDs {
                guard let node = preparedTree.nodesByID[id] else { continue }
                generated[id] = Self.normalizeSearchQuery(searchText(node))
            }
            normalizedSearchTextByID = generated
            searchTextByID = generated
        }

        matchingIDs = preparedTree.preorderIDs.filter { id in
            searchTextByID[id]?.contains(searchQuery) == true
        }
        matchingIDSet = Set(matchingIDs)

        if selectingFallbackFocus,
           !matchingIDs.isEmpty,
           focusedID.map(matchingIDSet.contains) != true {
            focusedID = matchingIDs[0]
        }
    }

    private func normalizeSearchInteractionIfNeeded(
        remappingPreviouslyVisibleSelection previouslyVisibleSelection: Set<Node.ID> = []
    ) {
        if !hasActiveSearchQuery {
            selection = Set(selection.map { interactionID(for: $0) })
            focusedID = focusedID.map { interactionID(for: $0) }
            return
        }
        selection = Set(selection.map { selectedID in
            if let row = visibleRow(for: selectedID) { return row.id }
            guard previouslyVisibleSelection.contains(selectedID) else { return selectedID }
            return preparedTree.ancestorIDs(of: selectedID).reversed().lazy
                .compactMap { self.visibleRow(for: $0)?.id }
                .first ?? selectedID
        })
        if let focusedID, let row = visibleRow(for: focusedID) {
            self.focusedID = row.id
        }
        let visibleMatchIDs = visibleSearchMatchIDs()
        guard !visibleMatchIDs.isEmpty else { return }
        if let focusedID, let row = visibleRow(for: focusedID),
           row.representedIDs.contains(where: matchingIDSet.contains) {
            self.focusedID = row.id
        } else {
            focusedID = visibleMatchIDs[0]
        }
    }

    private func rebuildSearchProjectionState() {
        guard hasActiveSearchQuery else {
            renderedExpandedIDs = expandedIDs
            searchVisibleIDSet = nil
            return
        }

        var requiredExpandedIDs: Set<Node.ID> = []
        var contextualVisibleIDs: Set<Node.ID> = []
        requiredExpandedIDs.reserveCapacity(matchingIDs.count)
        contextualVisibleIDs.reserveCapacity(matchingIDs.count)

        for matchingID in matchingIDs {
            contextualVisibleIDs.insert(matchingID)
            if preparedTree.isExpandable(matchingID) {
                requiredExpandedIDs.insert(matchingID)
            }

            var ancestorID = preparedTree.parentByID[matchingID]
            while let currentAncestorID = ancestorID {
                let inserted = contextualVisibleIDs.insert(currentAncestorID).inserted
                if preparedTree.isExpandable(currentAncestorID) {
                    requiredExpandedIDs.insert(currentAncestorID)
                }
                // Matches are visited in preorder. An ancestor already collected here was
                // therefore processed earlier together with the rest of its path to the root.
                guard inserted else { break }
                ancestorID = preparedTree.parentByID[currentAncestorID]
            }
        }

        func projectedRequiredExpansion(
            visibleIDSet: Set<Node.ID>?
        ) -> Set<Node.ID> {
            Set(requiredExpandedIDs.compactMap { id in
                let terminalID = Self.flattenedDirectoryChain(
                    startingAt: id,
                    in: preparedTree,
                    visibleIDSet: visibleIDSet,
                    enabled: pathFlattenEmptyDirectories
                ).last ?? id
                return preparedTree.isExpandable(terminalID) ? terminalID : nil
            })
        }

        switch searchMode {
        case .expandMatches:
            renderedExpandedIDs = expandedIDs.union(
                projectedRequiredExpansion(visibleIDSet: nil)
            )
            searchVisibleIDSet = nil
        case .collapseNonMatches:
            renderedExpandedIDs = projectedRequiredExpansion(visibleIDSet: nil)
            searchVisibleIDSet = nil
        case .hideNonMatches:
            renderedExpandedIDs = projectedRequiredExpansion(
                visibleIDSet: contextualVisibleIDs
            )
            searchVisibleIDSet = contextualVisibleIDs
        }
    }

    private func focusSearchMatch(offset: Int) {
        let visibleMatchIDs = visibleSearchMatchIDs()
        guard !visibleMatchIDs.isEmpty else { return }
        let currentIndex = focusedID.flatMap { visibleMatchIDs.firstIndex(of: $0) }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = min(visibleMatchIDs.count - 1, max(0, currentIndex + offset))
        } else {
            nextIndex = offset > 0 ? 0 : visibleMatchIDs.count - 1
        }

        let nextID = visibleMatchIDs[nextIndex]
        guard focusedID != nextID else { return }
        focusedID = nextID
        revealSequence &+= 1
        revealRequest = FileTreeRevealRequest(
            sequence: revealSequence,
            id: nextID,
            position: .nearest,
            focus: true
        )
        publishChange()
    }

    private func visibleSearchMatchIDs() -> [Node.ID] {
        var seen: Set<Node.ID> = []
        seen.reserveCapacity(matchingIDs.count)
        return matchingIDs.compactMap { matchingID in
            guard let id = visibleRow(for: matchingID)?.id, seen.insert(id).inserted else {
                return nil
            }
            return id
        }
    }

    private static func normalizeSearchQuery(_ query: String) -> String {
        query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
            .lowercased()
    }

    internal func synchronizeSelection(_ identifiers: Set<Node.ID>, focusedID: Node.ID?) {
        let valid = identifiers.filtering { preparedTree.contains($0) }
        let validFocus = focusedID.flatMap { preparedTree.contains($0) ? $0 : nil }
        guard valid != selection || validFocus != self.focusedID else { return }
        selection = valid
        self.focusedID = validFocus
        publishChange()
    }

    internal func publishChange() {
        rememberFocusedVisibleIndex()
        selectionChangesSubject?.send(selection)
        focusChangesSubject?.send(focusedID)
        revision &+= 1
    }
}

private extension Set {
    func filtering(_ predicate: (Element) throws -> Bool) rethrows -> Set<Element> {
        try Set(filter(predicate))
    }
}
