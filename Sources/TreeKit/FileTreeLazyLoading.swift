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

// Lazy entry points require Sendable nodes, while eager FileTreeModel remains intentionally
// unconstrained. These wrappers bridge that conditional boundary; every access stays on the
// model's main actor.
internal enum FileTreeLazyLoadOutcome<Node>: @unchecked Sendable {
    case success([Node])
    case failure(any Error)
    case obsolete
}

internal struct FileTreeLazyLoadOperation<Node>: @unchecked Sendable {
    let generation: UInt64
    let token: UInt64
    let task: Task<FileTreeLazyLoadOutcome<Node>, Never>
}

/// Cancels renderer-started provider work when its model is released.
///
/// `FileTreeModel` cannot inspect its generic operation dictionaries from its nonisolated
/// deinitializer when `Node.ID` is not unconditionally `Sendable`. Keeping only type-erased,
/// thread-safe cancellation actions here gives the owner a generic-independent lifetime hook.
internal final class FileTreeLazyOperationLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellations: [UInt64: @Sendable () -> Void] = [:]

    func register(token: UInt64, cancellation: @escaping @Sendable () -> Void) {
        lock.lock()
        cancellations[token] = cancellation
        lock.unlock()
    }

    func remove(token: UInt64) {
        lock.lock()
        cancellations[token] = nil
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let pending = Array(cancellations.values)
        cancellations = [:]
        lock.unlock()

        for cancel in pending {
            cancel()
        }
    }

    deinit {
        cancelAll()
    }
}

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

    /// Replaces the current hierarchy with a new provider-backed generation.
    ///
    /// In-flight work from the previous generation is cancelled before the old hierarchy is
    /// removed. Providers that ignore cancellation may still finish, but their results cannot
    /// mutate this model. Roots remain `.unloaded`; call ``loadRoots()`` explicitly when replacing
    /// a provider on an already-mounted model.
    func reset(
        childrenProvider: FileTreeChildrenProvider<Node>,
        initialExpansion: FileTreeInitialExpansion<Node.ID> = .collapsed,
        initialSelection: Set<Node.ID> = []
    ) {
        let emptyTree: PreparedTree<Node>
        do {
            emptyTree = try PreparedTree(roots: []) { _ in [] }
        } catch {
            preconditionFailure("An empty tree cannot fail preparation: \(error)")
        }

        clearLazyLoadingConfiguration()
        fileTreePathMutationState = nil
        pathFlattenEmptyDirectories = false
        configureLazyLoading(
            provider: childrenProvider,
            initialExpansion: initialExpansion,
            initialSelection: initialSelection
        )
        replacePreparedTree(
            emptyTree,
            expandedIDs: [],
            selection: [],
            focusedID: nil
        )
    }

    /// Loads and publishes provider roots.
    ///
    /// Concurrent calls in the same model generation await one shared provider operation.
    /// Successful results are retained; provider replacement invalidates outstanding callers.
    @discardableResult
    func loadRoots() async throws -> [Node] {
        guard lazyChildrenProvider != nil else { return preparedTree.roots }
        if rootLoadState == .loaded { return lazyRootNodes }
        guard let operation = lazyRootOperation ?? beginLazyRootOperation() else {
            return lazyRootNodes
        }
        return try await value(from: operation)
    }

    /// Loads and publishes one discovered node's children.
    ///
    /// Concurrent requests for the same node share one provider operation. A successful result is
    /// retained across collapse and re-expansion for the lifetime of the provider generation.
    @discardableResult
    func loadChildren(of id: Node.ID) async throws -> [Node] {
        guard lazyChildrenProvider != nil,
              knownNode(for: id) != nil
        else { return preparedTree.children(of: id) }

        if lazyChildrenLoadStates[id] == .loaded {
            return lazyChildrenByID[id] ?? []
        }
        if let operation = lazyChildOperationsByID[id] {
            return try await value(from: operation)
        }
        guard let operation = beginLazyChildOperations(for: [id])[id] else {
            return lazyChildrenByID[id] ?? []
        }
        return try await value(from: operation)
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
            _ = self?.beginLazyRootOperation()
        }
        requestLazyChildrenLoad = { [weak self] ids in
            !(self?.beginLazyChildOperations(for: ids).isEmpty ?? true)
        }
    }

    @discardableResult
    private func beginLazyRootOperation() -> FileTreeLazyLoadOperation<Node>?
    where Node: Sendable, Node.ID: Sendable {
        if let lazyRootOperation {
            return lazyRootOperation
        }
        guard rootLoadState != .loaded, let provider = lazyChildrenProvider else { return nil }

        let generation = lazyLoadGeneration
        lazyLoadSequence &+= 1
        let token = lazyLoadSequence
        let task = Task { @MainActor [weak self, provider] in
            guard !Task.isCancelled else {
                return FileTreeLazyLoadOutcome<Node>.obsolete
            }
            do {
                let roots = try await provider.roots()
                guard !Task.isCancelled, let self else {
                    return FileTreeLazyLoadOutcome<Node>.obsolete
                }
                return self.finishLazyRootLoad(
                    .success(roots),
                    provider: provider,
                    generation: generation,
                    token: token
                )
            } catch {
                guard !Task.isCancelled, let self else {
                    return FileTreeLazyLoadOutcome<Node>.obsolete
                }
                return self.finishLazyRootLoad(
                    .failure(error),
                    provider: provider,
                    generation: generation,
                    token: token
                )
            }
        }
        let operation = FileTreeLazyLoadOperation(
            generation: generation,
            token: token,
            task: task
        )
        lazyOperationLifetime.register(token: token) {
            task.cancel()
        }
        lazyRootOperation = operation
        rootLoadState = .loading
        publishLoadStateChange()
        return operation
    }

    @discardableResult
    private func beginLazyChildOperations(
        for ids: Set<Node.ID>
    ) -> [Node.ID: FileTreeLazyLoadOperation<Node>]
    where Node: Sendable, Node.ID: Sendable {
        guard let provider = lazyChildrenProvider else { return [:] }
        let orderedIDs = knownNodeIDsInPreorder.filter {
            ids.contains($0)
                && lazyChildrenLoadStates[$0] == .unloaded
                && lazyChildOperationsByID[$0] == nil
        }
        guard !orderedIDs.isEmpty else { return [:] }

        let generation = lazyLoadGeneration
        var startedOperations: [Node.ID: FileTreeLazyLoadOperation<Node>] = [:]
        startedOperations.reserveCapacity(orderedIDs.count)
        for id in orderedIDs {
            guard let node = knownNode(for: id) else { continue }
            lazyLoadSequence &+= 1
            let token = lazyLoadSequence
            let task = Task { @MainActor [weak self, provider, node] in
                guard !Task.isCancelled else {
                    return FileTreeLazyLoadOutcome<Node>.obsolete
                }
                do {
                    let children = try await provider.children(node)
                    guard !Task.isCancelled, let self else {
                        return FileTreeLazyLoadOutcome<Node>.obsolete
                    }
                    return self.finishLazyChildLoad(
                        .success(children),
                        of: id,
                        provider: provider,
                        generation: generation,
                        token: token
                    )
                } catch {
                    guard !Task.isCancelled, let self else {
                        return FileTreeLazyLoadOutcome<Node>.obsolete
                    }
                    return self.finishLazyChildLoad(
                        .failure(error),
                        of: id,
                        provider: provider,
                        generation: generation,
                        token: token
                    )
                }
            }
            let operation = FileTreeLazyLoadOperation(
                generation: generation,
                token: token,
                task: task
            )
            lazyOperationLifetime.register(token: token) {
                task.cancel()
            }
            lazyChildOperationsByID[id] = operation
            startedOperations[id] = operation
            lazyChildrenLoadStates[id] = .loading
        }
        publishLoadStateChange(for: Set(orderedIDs))
        return startedOperations
    }

    private func value(
        from operation: FileTreeLazyLoadOperation<Node>
    ) async throws -> [Node] where Node: Sendable, Node.ID: Sendable {
        let outcome = await operation.task.value
        try Task.checkCancellation()
        guard lazyLoadGeneration == operation.generation else {
            throw CancellationError()
        }
        switch outcome {
        case .success(let nodes):
            return nodes
        case .failure(let error):
            throw error
        case .obsolete:
            throw CancellationError()
        }
    }

    private func finishLazyRootLoad(
        _ result: Result<[Node], any Error>,
        provider: FileTreeChildrenProvider<Node>,
        generation: UInt64,
        token: UInt64
    ) -> FileTreeLazyLoadOutcome<Node> {
        guard lazyLoadGeneration == generation,
              lazyRootOperation?.token == token
        else { return .obsolete }
        defer { lazyOperationLifetime.remove(token: token) }

        switch result {
        case .failure(let error):
            lazyRootOperation = nil
            rootLoadState = .unloaded
            publishLoadStateChange()
            guard lazyLoadGeneration == generation else { return .obsolete }
            return .failure(error)

        case .success(let roots):
            do {
                let staged = try makeLazySnapshot(roots: roots, childrenByID: [:])
                var potentialIDs: Set<Node.ID> = []
                var states: [Node.ID: FileTreeChildrenLoadState] = [:]
                classifyLazyNodes(
                    roots,
                    provider: provider,
                    potentialIDs: &potentialIDs,
                    states: &states
                )
                guard lazyLoadGeneration == generation,
                      lazyRootOperation?.token == token
                else { return .obsolete }

                lazyRootOperation = nil
                lazyRootNodes = roots
                lazyChildrenByID = [:]
                lazyPotentiallyExpandableIDs = potentialIDs
                lazyChildrenLoadStates = states
                rootLoadState = .loaded

                let initial = initialLazyState(in: staged, adding: roots)
                let initialSelection = selectionApplyingLazyInitialState(initial)
                replacePreparedTree(
                    staged,
                    expandedIDs: expandedIDs.union(initial.expandedIDs),
                    selection: initialSelection.selection,
                    focusedID: initialSelection.focusedID
                )
                guard lazyLoadGeneration == generation else { return .obsolete }
                startInitiallyExpandedLazyLoads()
                guard lazyLoadGeneration == generation else { return .obsolete }
                return .success(roots)
            } catch {
                guard lazyLoadGeneration == generation,
                      lazyRootOperation?.token == token
                else { return .obsolete }
                lazyRootOperation = nil
                rootLoadState = .unloaded
                publishLoadStateChange()
                guard lazyLoadGeneration == generation else { return .obsolete }
                return .failure(error)
            }
        }
    }

    private func finishLazyChildLoad(
        _ result: Result<[Node], any Error>,
        of id: Node.ID,
        provider: FileTreeChildrenProvider<Node>,
        generation: UInt64,
        token: UInt64
    ) -> FileTreeLazyLoadOutcome<Node> {
        guard lazyLoadGeneration == generation,
              lazyChildOperationsByID[id]?.token == token
        else { return .obsolete }
        defer { lazyOperationLifetime.remove(token: token) }

        switch result {
        case .failure(let error):
            lazyChildOperationsByID[id] = nil
            lazyChildrenLoadStates[id] = .unloaded
            publishLoadStateChange(for: [id])
            guard lazyLoadGeneration == generation else { return .obsolete }
            return .failure(error)

        case .success(let children):
            do {
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
                guard lazyLoadGeneration == generation,
                      lazyChildOperationsByID[id]?.token == token
                else { return .obsolete }

                lazyChildOperationsByID[id] = nil
                lazyChildrenByID = nextChildrenByID
                lazyPotentiallyExpandableIDs = potentialIDs
                lazyChildrenLoadStates = states

                let initial = initialLazyState(in: staged, adding: children)
                let initialSelection = selectionApplyingLazyInitialState(initial)
                replacePreparedTree(
                    staged,
                    expandedIDs: expandedIDs.union(initial.expandedIDs),
                    selection: initialSelection.selection,
                    focusedID: initialSelection.focusedID
                )
                guard lazyLoadGeneration == generation else { return .obsolete }
                startInitiallyExpandedLazyLoads()
                guard lazyLoadGeneration == generation else { return .obsolete }
                return .success(children)
            } catch {
                guard lazyLoadGeneration == generation,
                      lazyChildOperationsByID[id]?.token == token
                else { return .obsolete }
                lazyChildOperationsByID[id] = nil
                lazyChildrenLoadStates[id] = .unloaded
                publishLoadStateChange(for: [id])
                guard lazyLoadGeneration == generation else { return .obsolete }
                return .failure(error)
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

    private func selectionApplyingLazyInitialState(
        _ initial: LazyInitialState
    ) -> (selection: Set<Node.ID>, focusedID: Node.ID?) {
        guard
            !initial.selectedIDs.isEmpty,
            let fallbackSelection = lazyRendererFallbackSelectionStorage
        else {
            return (
                selection.union(initial.selectedIDs),
                focusedID ?? initial.focusedID
            )
        }

        lazyRendererFallbackSelectionStorage = nil
        let retainedSelection = selection.subtracting(fallbackSelection)
        let retainedFocus = focusedID.flatMap { focusedID in
            fallbackSelection.contains(focusedID) ? nil : focusedID
        }
        return (
            retainedSelection.union(initial.selectedIDs),
            retainedFocus ?? initial.focusedID
        )
    }

    private func startInitiallyExpandedLazyLoads() {
        startLazyChildrenLoadingIfNeeded(for: expandedIDs)
        if lazyExpandAllRequested && lazyPotentiallyExpandableIDs.isEmpty {
            lazyExpandAllRequested = false
        }
    }
}
