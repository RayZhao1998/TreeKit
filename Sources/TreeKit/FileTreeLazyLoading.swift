import Foundation

/// The availability of one branch's children in a provider-backed tree.
public enum FileTreeChildrenLoadState: Equatable, Hashable, Sendable {
    /// Children have not been requested yet.
    case unloaded

    /// A request is currently awaiting the provider.
    case loading

    /// The provider has returned the complete child collection, including an empty collection.
    case loaded
}

/// Asynchronous hierarchy callbacks for a tree whose nodes should be discovered on demand.
///
/// Return roots and siblings in display order. TreeKit retains successful results, so collapsing
/// and re-expanding a loaded branch does not call `children` again. The provider owns external
/// storage, file-system observation, and cache invalidation.
public struct FileTreeChildrenProvider<Node: Identifiable> {
    /// Loads the top-level nodes in display order.
    public var roots: @Sendable () async throws -> [Node]

    /// Returns whether an unloaded node should present a disclosure control.
    public var mightHaveChildren: @Sendable (Node) -> Bool

    /// Loads one node's complete direct-child collection in display order.
    public var children: @Sendable (Node) async throws -> [Node]

    public init(
        roots: @escaping @Sendable () async throws -> [Node],
        mightHaveChildren: @escaping @Sendable (Node) -> Bool,
        children: @escaping @Sendable (Node) async throws -> [Node]
    ) {
        self.roots = roots
        self.mightHaveChildren = mightHaveChildren
        self.children = children
    }
}

extension FileTreeChildrenProvider: Sendable where Node: Sendable, Node.ID: Sendable {}

public extension FileTreeModel where Node: Sendable, Node.ID: Sendable {
    /// Creates a model that discovers roots and branch children from an asynchronous provider.
    ///
    /// Roots begin loading when a SwiftUI, AppKit, or UIKit renderer mounts. Call ``loadRoots()``
    /// explicitly when the model is used before it is mounted. Initial expansion is applied as
    /// matching nodes are discovered; `.expanded` therefore walks the complete provider tree.
    convenience init(
        childrenProvider: FileTreeChildrenProvider<Node>,
        initialExpansion: FileTreeInitialExpansion<Node.ID> = .collapsed,
        initialSelection: Set<Node.ID> = [],
        searchMode: FileTreeSearchMode = .hideNonMatches,
        searchText: @escaping (Node) -> String = { String(describing: $0.id) }
    ) {
        let emptyTree: PreparedTree<Node>
        do {
            emptyTree = try PreparedTree(roots: []) { _ in [] }
        } catch {
            preconditionFailure("An empty tree cannot fail preparation: \(error)")
        }

        self.init(
            emptyTree,
            initialExpansion: .collapsed,
            initialSelection: [],
            searchMode: searchMode,
            searchText: searchText
        )
        configureLazyLoading(
            provider: childrenProvider,
            initialExpansion: initialExpansion,
            initialSelection: initialSelection
        )
    }

    /// Loads and publishes provider roots. Repeated calls return the retained result.
    @discardableResult
    func loadRoots() async throws -> [Node] {
        guard let provider = lazyChildrenProvider else { return preparedTree.roots }
        if rootLoadState == .loaded { return lazyRootNodes }

        if rootLoadState == .unloaded {
            rootLoadState = .loading
            publishLoadStateChange()
        }

        do {
            let roots = try await provider.roots()
            let staged = try makeLazySnapshot(
                roots: roots,
                childrenByID: [:]
            )
            var potentialIDs: Set<Node.ID> = []
            var states: [Node.ID: FileTreeChildrenLoadState] = [:]
            classifyLazyNodes(
                roots,
                provider: provider,
                potentialIDs: &potentialIDs,
                states: &states
            )

            lazyRootNodes = roots
            lazyChildrenByID = [:]
            lazyPotentiallyExpandableIDs = potentialIDs
            lazyChildrenLoadStates = states
            rootLoadState = .loaded

            let initial = initialLazyState(in: staged, adding: roots)
            replacePreparedTree(
                staged,
                expandedIDs: expandedIDs.union(initial.expandedIDs),
                selection: selection.union(initial.selectedIDs),
                focusedID: focusedID ?? initial.focusedID
            )
            startInitiallyExpandedLazyLoads()
            return roots
        } catch {
            rootLoadState = .unloaded
            publishLoadStateChange()
            throw error
        }
    }

    /// Loads and publishes one discovered node's children. Successful results are retained.
    @discardableResult
    func loadChildren(of id: Node.ID) async throws -> [Node] {
        guard let provider = lazyChildrenProvider,
              let node = knownNode(for: id)
        else { return preparedTree.children(of: id) }

        if lazyChildrenLoadStates[id] == .loaded {
            return lazyChildrenByID[id] ?? []
        }
        if lazyChildrenLoadStates[id] == .unloaded {
            lazyChildrenLoadStates[id] = .loading
            publishLoadStateChange(for: [id])
        }

        do {
            let children = try await provider.children(node)
            var nextChildrenByID = lazyChildrenByID
            nextChildrenByID[id] = children
            let staged = try makeLazySnapshot(
                roots: lazyRootNodes,
                childrenByID: nextChildrenByID
            )

            var potentialIDs = lazyPotentiallyExpandableIDs
            potentialIDs.remove(id)
            var states = lazyChildrenLoadStates
            states[id] = .loaded
            classifyLazyNodes(
                children,
                provider: provider,
                potentialIDs: &potentialIDs,
                states: &states
            )

            lazyChildrenByID = nextChildrenByID
            lazyPotentiallyExpandableIDs = potentialIDs
            lazyChildrenLoadStates = states

            let initial = initialLazyState(in: staged, adding: children)
            replacePreparedTree(
                staged,
                expandedIDs: expandedIDs.union(initial.expandedIDs),
                selection: selection.union(initial.selectedIDs),
                focusedID: focusedID ?? initial.focusedID
            )
            startInitiallyExpandedLazyLoads()
            return children
        } catch {
            lazyChildrenLoadStates[id] = .unloaded
            publishLoadStateChange(for: [id])
            throw error
        }
    }
}

extension FileTreeModel {
    private struct LazyInitialState {
        var expandedIDs: Set<Node.ID>
        var selectedIDs: Set<Node.ID>
        var focusedID: Node.ID?
    }

    private var lazyInitialExpansion: FileTreeInitialExpansion<Node.ID> {
        get { lazyInitialExpansionStorage ?? .collapsed }
        set { lazyInitialExpansionStorage = newValue }
    }

    private var lazyInitialSelection: Set<Node.ID> {
        get { lazyInitialSelectionStorage ?? [] }
        set { lazyInitialSelectionStorage = newValue }
    }

    internal func configureLazyLoading(
        provider: FileTreeChildrenProvider<Node>,
        initialExpansion: FileTreeInitialExpansion<Node.ID>,
        initialSelection: Set<Node.ID>
    ) where Node: Sendable, Node.ID: Sendable {
        lazyChildrenProvider = provider
        lazyInitialExpansion = initialExpansion
        lazyInitialSelection = initialSelection
        rootLoadState = .unloaded
        requestLazyRootLoad = { [weak self] in
            Task { @MainActor [weak self] in
                try? await self?.loadRoots()
            }
        }
        requestLazyChildrenLoad = { [weak self] id in
            Task { @MainActor [weak self] in
                try? await self?.loadChildren(of: id)
            }
        }
    }

    private func makeLazySnapshot(
        roots: [Node],
        childrenByID: [Node.ID: [Node]]
    ) throws -> PreparedTree<Node> {
        try PreparedTree(roots: roots) { node in
            childrenByID[node.id] ?? []
        }
    }

    private func classifyLazyNodes(
        _ nodes: [Node],
        provider: FileTreeChildrenProvider<Node>,
        potentialIDs: inout Set<Node.ID>,
        states: inout [Node.ID: FileTreeChildrenLoadState]
    ) {
        for node in nodes {
            if provider.mightHaveChildren(node) {
                potentialIDs.insert(node.id)
                states[node.id] = .unloaded
            } else {
                potentialIDs.remove(node.id)
                states[node.id] = .loaded
            }
        }
    }

    private func initialLazyState(
        in tree: PreparedTree<Node>,
        adding nodes: [Node]
    ) -> LazyInitialState {
        var pendingSelection = lazyInitialSelection
        let selectedIDs = pendingSelection.intersection(Set(nodes.map(\.id)))
        pendingSelection.subtract(selectedIDs)
        lazyInitialSelection = pendingSelection
        let expandedIDs = Set(nodes.compactMap { node -> Node.ID? in
            guard lazyPotentiallyExpandableIDs.contains(node.id) else { return nil }
            if lazyExpandAllRequested {
                return node.id
            }
            switch lazyInitialExpansion {
            case .collapsed:
                return nil
            case .expanded:
                return node.id
            case .depth(let requestedDepth):
                guard let depth = tree.depth(of: node.id), depth < max(0, requestedDepth) else {
                    return nil
                }
                return node.id
            case .identifiers(let identifiers):
                return identifiers.contains(node.id) ? node.id : nil
            }
        })
        return LazyInitialState(
            expandedIDs: expandedIDs,
            selectedIDs: selectedIDs,
            focusedID: tree.preorderIDs.first(where: selectedIDs.contains)
        )
    }

    private func startInitiallyExpandedLazyLoads() {
        startLazyChildrenLoadingIfNeeded(for: expandedIDs)
        if lazyExpandAllRequested && lazyPotentiallyExpandableIDs.isEmpty {
            lazyExpandAllRequested = false
        }
    }
}
