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

    /// The visible projection in depth-first preorder.
    public private(set) var visibleRows: [FileTreeVisibleRow<Node>]

    /// Advances once after each complete model transaction.
    @Published public private(set) var revision: UInt64 = 0

    internal var dataRevision: UInt64 = 0
    internal var expansionRevision: UInt64 = 0
    internal var revealRequest: FileTreeRevealRequest<Node.ID>?

    private var visibleIndexByID: [Node.ID: Int] = [:]
    private var revealSequence: UInt64 = 0

    /// Creates a stable tree model from prepared data.
    public init(
        _ preparedTree: PreparedTree<Node>,
        initialExpansion: FileTreeInitialExpansion<Node.ID> = .collapsed,
        initialSelection: Set<Node.ID> = []
    ) {
        let selection = initialSelection.filtering { preparedTree.contains($0) }
        let expandedIDs = Self.expandedIDs(for: initialExpansion, in: preparedTree)
        self.preparedTree = preparedTree
        self.selection = selection
        self.expandedIDs = expandedIDs
        self.focusedID = preparedTree.preorderIDs.first { selection.contains($0) }
        self.visibleRows = Self.makeVisibleRows(in: preparedTree, expandedIDs: expandedIDs)
        rebuildVisibleIndex()
    }

    /// Replaces the complete hierarchy atomically from the renderer's perspective.
    ///
    /// Retained identities preserve selection and expansion by default. Removed identities are
    /// pruned before AppKit receives the new snapshot.
    public func reset(
        _ preparedTree: PreparedTree<Node>,
        preservingExpansion: Bool = true,
        preservingSelection: Bool = true
    ) {
        let nextExpansion = preservingExpansion
            ? expandedIDs.filtering { preparedTree.contains($0) && preparedTree.isExpandable($0) }
            : []
        let nextSelection = preservingSelection
            ? selection.filtering { preparedTree.contains($0) }
            : []

        self.preparedTree = preparedTree
        self.expandedIDs = nextExpansion
        self.selection = nextSelection
        self.focusedID = focusedID.flatMap { preparedTree.contains($0) ? $0 : nil }
        rebuildVisibleRows()
        dataRevision &+= 1
        expansionRevision &+= 1
        publishChange()
    }

    /// Replaces selection with known identifiers from the current hierarchy.
    public func setSelection(_ identifiers: Set<Node.ID>) {
        let valid = identifiers.filtering { preparedTree.contains($0) }
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
        guard focusedID != id else { return }
        guard let id else {
            focusedID = nil
            publishChange()
            return
        }
        guard preparedTree.contains(id) else { return }
        focusedID = id
        publishChange()
    }

    /// Expands one branch. Expanding a hidden descendant records state without forcing ancestors open.
    public func expand(_ id: Node.ID) {
        guard preparedTree.isExpandable(id), expandedIDs.insert(id).inserted else { return }
        insertVisibleDescendants(of: id)
        expansionRevision &+= 1
        publishChange()
    }

    /// Collapses one branch while retaining nested descendants' expansion state.
    public func collapse(_ id: Node.ID) {
        guard expandedIDs.remove(id) != nil else { return }
        removeVisibleDescendants(of: id)
        expansionRevision &+= 1
        publishChange()
    }

    /// Toggles one branch's expansion state.
    public func toggleExpansion(of id: Node.ID) {
        if expandedIDs.contains(id) {
            collapse(id)
        } else {
            expand(id)
        }
    }

    /// Replaces expansion with known branch identifiers.
    public func setExpandedIDs(_ identifiers: Set<Node.ID>) {
        let valid = identifiers.filtering {
            preparedTree.contains($0) && preparedTree.isExpandable($0)
        }
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

    /// Expands all ancestors, optionally selects the item, and asks the mounted view to scroll.
    public func reveal(
        _ id: Node.ID,
        select: Bool = true,
        position: FileTreeScrollPosition = .nearest,
        focus: Bool = true
    ) {
        guard preparedTree.contains(id) else { return }

        var newlyExpandedAncestors: [Node.ID] = []
        for ancestorID in preparedTree.ancestorIDs(of: id) where preparedTree.isExpandable(ancestorID) {
            if !expandedIDs.contains(ancestorID) {
                newlyExpandedAncestors.append(ancestorID)
            }
        }
        if let firstNewlyExpandedAncestor = newlyExpandedAncestors.first {
            expandedIDs.formUnion(newlyExpandedAncestors)
            insertVisibleDescendants(of: firstNewlyExpandedAncestor)
            expansionRevision &+= 1
        }

        if select {
            selection = [id]
        }
        focusedID = id
        revealSequence &+= 1
        revealRequest = FileTreeRevealRequest(
            sequence: revealSequence,
            id: id,
            position: position,
            focus: focus
        )
        publishChange()
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
        expandedIDs: Set<Node.ID>
    ) -> [FileTreeVisibleRow<Node>] {
        makeVisibleRows(startingAt: tree.rootIDs, in: tree, expandedIDs: expandedIDs)
    }

    private static func makeVisibleRows(
        startingAt startIDs: [Node.ID],
        in tree: PreparedTree<Node>,
        expandedIDs: Set<Node.ID>
    ) -> [FileTreeVisibleRow<Node>] {
        var result: [FileTreeVisibleRow<Node>] = []
        var stack = Array(startIDs.reversed())

        while let id = stack.popLast() {
            guard let node = tree.nodesByID[id] else { continue }
            result.append(
                FileTreeVisibleRow(
                    node: node,
                    depth: tree.depthByID[id] ?? 0,
                    parentID: tree.parentByID[id],
                    siblingIndex: tree.siblingIndexByID[id] ?? 0,
                    siblingCount: tree.siblingCount(of: id)
                )
            )

            if expandedIDs.contains(id) {
                stack.append(contentsOf: (tree.childrenByID[id] ?? []).reversed())
            }
        }

        return result
    }

    private func rebuildVisibleRows() {
        visibleRows = Self.makeVisibleRows(in: preparedTree, expandedIDs: expandedIDs)
        rebuildVisibleIndex()
    }

    private func insertVisibleDescendants(of id: Node.ID) {
        guard let index = visibleIndexByID[id] else { return }
        let rows = Self.makeVisibleRows(
            startingAt: preparedTree.childrenByID[id] ?? [],
            in: preparedTree,
            expandedIDs: expandedIDs
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
        visibleIndexByID.reserveCapacity(visibleRows.count)
        for (index, row) in visibleRows.enumerated() {
            visibleIndexByID[row.id] = index
        }
    }

    internal func synchronizeSelection(_ identifiers: Set<Node.ID>, focusedID: Node.ID?) {
        let valid = identifiers.filtering { preparedTree.contains($0) }
        let validFocus = focusedID.flatMap { preparedTree.contains($0) ? $0 : nil }
        guard valid != selection || validFocus != self.focusedID else { return }
        selection = valid
        self.focusedID = validFocus
        publishChange()
    }

    private func publishChange() {
        revision &+= 1
    }
}

private extension Set {
    func filtering(_ predicate: (Element) throws -> Bool) rethrows -> Set<Element> {
        try Set(filter(predicate))
    }
}
