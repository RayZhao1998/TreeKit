import Combine
import Foundation

/// One path-first operation accepted by ``FileTreeModel/batch(_:)``.
public enum FileTreePathMutation: Equatable, Sendable {
    /// Adds a canonical path. Missing directory ancestors are synthesized.
    case add(path: String, kind: FileTreePath.Kind? = nil)

    /// Removes one path. Removing a directory also removes its descendants.
    case remove(path: String)

    /// Moves one path to a complete destination path.
    case move(from: String, to: String)
}

/// A semantic mutation emitted after the model has installed one coherent transaction.
///
/// Payloads contain normalized ``FileTreePath`` values. They describe in-memory tree intent for
/// persistence, logging, and adjacent UI; TreeKit does not mutate the filesystem.
public enum FileTreePathMutationEvent: Equatable, Sendable {
    public enum Kind: CaseIterable, Equatable, Hashable, Sendable {
        case add
        case remove
        case move
        case batch
        case reset
    }

    case add(path: FileTreePath)
    case remove(path: FileTreePath)
    case move(from: FileTreePath, to: FileTreePath)
    case batch([FileTreePathMutationEvent])
    case reset(paths: [FileTreePath])

    public var kind: Kind {
        switch self {
        case .add: .add
        case .remove: .remove
        case .move: .move
        case .batch: .batch
        case .reset: .reset
        }
    }
}

/// Errors raised while applying a path-first model mutation.
public enum FileTreePathMutationError: Error, Equatable, Sendable {
    /// The requested source identity does not exist in the current prepared hierarchy.
    case identityNotFound(path: String)

    /// The requested new identity is already occupied.
    case duplicateIdentity(path: String)

    /// A move destination does not have an existing directory parent.
    case invalidDestination(path: String)

    /// A move destination uses a different item kind than its source.
    case kindMismatch(
        path: String,
        expected: FileTreePath.Kind,
        actual: FileTreePath.Kind
    )

    /// A directory cannot be moved into itself or one of its descendants.
    case moveIntoDescendant(source: String, destination: String)
}

extension FileTreePathMutationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .identityNotFound(let path):
            "No file tree item exists at '\(path)'."
        case .duplicateIdentity(let path):
            "A file tree item already exists at '\(path)'."
        case .invalidDestination(let path):
            "The move destination requires an existing directory at '\(path)'."
        case .kindMismatch(let path, let expected, let actual):
            "The destination '\(path)' must remain \(expected.description), not \(actual.description)."
        case .moveIntoDescendant(let source, let destination):
            "The directory '\(source)' cannot be moved into '\(destination)'."
        }
    }
}

internal struct FileTreePathMutationState {
    var explicitPaths: [String]
    var options: FileTreePathOptions

    init(paths: [String], options: FileTreePathOptions) throws {
        var seenIDs: Set<String> = []
        seenIDs.reserveCapacity(paths.count)
        var explicitPaths: [String] = []
        explicitPaths.reserveCapacity(paths.count)

        for path in paths {
            let canonicalPath = try FileTreePath(path: path)
            if seenIDs.insert(canonicalPath.id).inserted {
                explicitPaths.append(canonicalPath.path)
            }
        }

        self.explicitPaths = explicitPaths
        self.options = options
    }

    init(preparedTree: PreparedTree<FileTreePath>) {
        // Prepared input has no provenance bit for synthesized ancestors, so retain every node.
        // Input order preserves the hierarchy's current root and sibling ordering.
        self.explicitPaths = preparedTree.nodes.map(\.path)
        self.options = preparedTree.fileTreePathOptions ?? .init(sort: .inputOrder)
    }
}

@MainActor
public extension FileTreeModel where Node == FileTreePath {
    /// Whether single-child directory chains are combined in the visible projection.
    var flattenEmptyDirectories: Bool { pathFlattenEmptyDirectories }

    /// Enables or disables compact directory rows without rebuilding canonical topology.
    ///
    /// Existing selection, focus, and expansion are retained by canonical identity. When an
    /// identity becomes part of a flattened row, interaction resolves to that row's terminal
    /// directory, matching `@pierre/trees` semantics.
    func setFlattenEmptyDirectories(_ enabled: Bool) {
        var state = fileTreePathMutationState
            ?? FileTreePathMutationState(preparedTree: preparedTree)
        state.options.flattenEmptyDirectories = enabled
        fileTreePathMutationState = state
        setPathFlattenEmptyDirectories(enabled, publishing: true)
    }

    /// A typed stream of successful path-first mutation transactions.
    var mutationEvents: AnyPublisher<FileTreePathMutationEvent, Never> {
        pathMutationSubject().eraseToAnyPublisher()
    }

    /// Subscribes to every mutation event, or only events of one semantic kind.
    ///
    /// Retain the returned cancellable for as long as the subscription should remain active.
    @discardableResult
    func onMutation(
        _ kind: FileTreePathMutationEvent.Kind? = nil,
        handler: @escaping (FileTreePathMutationEvent) -> Void
    ) -> AnyCancellable {
        pathMutationSubject()
            .filter { event in kind == nil || event.kind == kind }
            .sink(receiveValue: handler)
    }

    /// Adds one path and publishes an `.add` transaction after the hierarchy is installed.
    func add(_ path: String, kind: FileTreePath.Kind? = nil) throws {
        try applyMutations([.add(path: path, kind: kind)], asBatch: false)
    }

    /// Removes one file or directory subtree and publishes a `.remove` transaction.
    func remove(_ path: String) throws {
        try applyMutations([.remove(path: path)], asBatch: false)
    }

    /// Moves one file or directory subtree to a complete canonical destination path.
    ///
    /// The destination's parent directory must already exist. Directory destinations retain the
    /// trailing `/` identity convention.
    func move(_ sourcePath: String, to destinationPath: String) throws {
        try applyMutations(
            [.move(from: sourcePath, to: destinationPath)],
            asBatch: false
        )
    }

    /// Applies ordered operations atomically and publishes exactly one `.batch` transaction.
    ///
    /// If any operation fails, neither model state nor events change. Intermediate prepared trees
    /// remain private to validation; mounted renderers receive only the final projection.
    func batch(_ mutations: [FileTreePathMutation]) throws {
        guard !mutations.isEmpty else { return }
        try applyMutations(mutations, asBatch: true, reorderPlan: nil)
    }

    internal func applyDrop(
        moves: [FileTreeDropMove],
        reorderPlan: FileTreeDropReorderPlan
    ) throws {
        let mutations = moves.compactMap { move -> FileTreePathMutation? in
            guard move.sourcePath.id != move.destinationPath.id else { return nil }
            return .move(from: move.sourcePath.path, to: move.destinationPath.path)
        }
        try applyMutations(mutations, asBatch: true, reorderPlan: reorderPlan)
    }

    /// Replaces all caller-supplied paths and publishes one `.reset` transaction.
    ///
    /// Pass `nil` for `options` to retain the model's current sibling ordering policy.
    func resetPaths(
        _ paths: [String],
        options: FileTreePathOptions? = nil,
        preservingExpansion: Bool = true,
        preservingSelection: Bool = true
    ) throws {
        let currentState = fileTreePathMutationState
            ?? FileTreePathMutationState(preparedTree: preparedTree)
        let nextOptions = options ?? currentState.options
        let nextPreparedTree = try prepareFileTree(paths: paths, options: nextOptions)
        let nextState = try FileTreePathMutationState(paths: paths, options: nextOptions)
        let nextExpansion = preservingExpansion ? expandedIDs : []
        let nextSelection = preservingSelection ? selection : []
        let nextFocus = focusedID

        clearLazyLoadingConfiguration()
        fileTreePathMutationState = nextState
        pathFlattenEmptyDirectories = nextOptions.flattenEmptyDirectories
        replacePreparedTree(
            nextPreparedTree,
            expandedIDs: nextExpansion,
            selection: nextSelection,
            focusedID: nextFocus
        )
        let resetPaths = try nextState.explicitPaths.map { try FileTreePath(path: $0) }
        fileTreePathMutationSubject?.send(.reset(paths: resetPaths))
    }

    private func applyMutations(
        _ mutations: [FileTreePathMutation],
        asBatch: Bool,
        reorderPlan: FileTreeDropReorderPlan? = nil
    ) throws {
        var nextState = fileTreePathMutationState
            ?? FileTreePathMutationState(preparedTree: preparedTree)
        var nextPreparedTree = preparedTree
        var nextSelection = selection
        var nextExpansion = expandedIDs
        var nextFocus = focusedID
        var events: [FileTreePathMutationEvent] = []
        events.reserveCapacity(mutations.count)

        for mutation in mutations {
            let result = try apply(
                mutation,
                state: &nextState,
                preparedTree: nextPreparedTree
            )
            nextPreparedTree = result.preparedTree
            events.append(result.event)

            switch result.event {
            case .add:
                break
            case .remove(let removedPath):
                nextSelection = nextSelection.filteringIDs {
                    !Self.contains($0, in: removedPath)
                }
                nextExpansion = nextExpansion.filteringIDs {
                    !Self.contains($0, in: removedPath)
                }
                if let focusedPath = nextFocus, Self.contains(focusedPath, in: removedPath) {
                    nextFocus = nil
                }
            case .move(let source, let destination):
                nextSelection = Set(nextSelection.map {
                    Self.moving($0, from: source, to: destination)
                })
                nextExpansion = Set(nextExpansion.map {
                    Self.moving($0, from: source, to: destination)
                })
                nextFocus = nextFocus.map {
                    Self.moving($0, from: source, to: destination)
                }
            case .batch, .reset:
                preconditionFailure("Batch application only produces leaf mutation events.")
            }
        }

        if let reorderPlan, nextState.options.sort == .inputOrder {
            nextState = try Self.reordered(
                state: nextState,
                preparedTree: nextPreparedTree,
                originalPreparedTree: preparedTree,
                plan: reorderPlan
            )
            nextPreparedTree = try Self.prepare(state: nextState)
        }

        clearLazyLoadingConfiguration()
        fileTreePathMutationState = nextState
        replacePreparedTree(
            nextPreparedTree,
            expandedIDs: nextExpansion,
            selection: nextSelection,
            focusedID: nextFocus
        )

        if asBatch {
            fileTreePathMutationSubject?.send(.batch(events))
        } else if let event = events.first {
            fileTreePathMutationSubject?.send(event)
        }
    }

    private func apply(
        _ mutation: FileTreePathMutation,
        state: inout FileTreePathMutationState,
        preparedTree: PreparedTree<FileTreePath>
    ) throws -> (
        preparedTree: PreparedTree<FileTreePath>,
        event: FileTreePathMutationEvent
    ) {
        switch mutation {
        case .add(let inputPath, let kind):
            let addedPath = try FileTreePath(path: inputPath, kind: kind)
            guard !preparedTree.contains(addedPath.id) else {
                throw FileTreePathMutationError.duplicateIdentity(path: addedPath.path)
            }

            var candidateState = state
            candidateState.explicitPaths.append(addedPath.path)
            let candidateTree = try Self.prepare(state: candidateState)
            state = candidateState
            return (candidateTree, .add(path: addedPath))

        case .remove(let inputPath):
            let canonicalInput = try FileTreePath(path: inputPath)
            guard let removedPath = preparedTree.node(for: canonicalInput.id) else {
                throw FileTreePathMutationError.identityNotFound(path: canonicalInput.path)
            }

            var candidateState = state
            candidateState.explicitPaths.removeAll {
                Self.contains($0, in: removedPath)
            }
            let candidateTree = try Self.prepare(state: candidateState)
            state = candidateState
            return (candidateTree, .remove(path: removedPath))

        case .move(let sourceInput, let destinationInput):
            let canonicalSource = try FileTreePath(path: sourceInput)
            guard let source = preparedTree.node(for: canonicalSource.id) else {
                throw FileTreePathMutationError.identityNotFound(path: canonicalSource.path)
            }

            let destination = try FileTreePath(path: destinationInput)
            guard destination.kind == source.kind else {
                throw FileTreePathMutationError.kindMismatch(
                    path: destination.path,
                    expected: source.kind,
                    actual: destination.kind
                )
            }
            if source.kind == .directory,
               destination.path != source.path,
               destination.path.hasPrefix(source.path) {
                throw FileTreePathMutationError.moveIntoDescendant(
                    source: source.path,
                    destination: destination.path
                )
            }
            guard !preparedTree.contains(destination.id) else {
                throw FileTreePathMutationError.duplicateIdentity(path: destination.path)
            }

            if let parentID = Self.parentDirectoryID(of: destination) {
                if source.kind == .directory, Self.contains(parentID, in: source) {
                    throw FileTreePathMutationError.moveIntoDescendant(
                        source: source.path,
                        destination: destination.path
                    )
                }
                guard preparedTree.node(for: parentID)?.kind == .directory else {
                    throw FileTreePathMutationError.invalidDestination(path: parentID)
                }
            }

            var candidateState = state
            candidateState.explicitPaths = candidateState.explicitPaths.map { path in
                guard Self.contains(path, in: source) else { return path }
                return Self.moving(path, from: source, to: destination)
            }
            let candidateTree = try Self.prepare(state: candidateState)
            state = candidateState
            return (candidateTree, .move(from: source, to: destination))
        }
    }

    private static func prepare(
        state: FileTreePathMutationState
    ) throws -> PreparedTree<FileTreePath> {
        try prepareFileTree(
            paths: state.explicitPaths,
            options: state.options
        )
    }

    private static func reordered(
        state: FileTreePathMutationState,
        preparedTree: PreparedTree<FileTreePath>,
        originalPreparedTree: PreparedTree<FileTreePath>,
        plan: FileTreeDropReorderPlan
    ) throws -> FileTreePathMutationState {
        let moveBySourceID = Dictionary(
            uniqueKeysWithValues: plan.moves.map { ($0.sourcePath.id, $0) }
        )
        var mappedIDByOriginalID: [String: String] = [:]
        mappedIDByOriginalID.reserveCapacity(originalPreparedTree.count)
        var activeDirectoryMove: FileTreeDropMove?
        for originalID in originalPreparedTree.preorderIDs {
            if let activeDirectoryMove,
               originalID.hasPrefix(activeDirectoryMove.sourcePath.path) {
                mappedIDByOriginalID[originalID] = moving(
                    originalID,
                    from: activeDirectoryMove.sourcePath,
                    to: activeDirectoryMove.destinationPath
                )
                continue
            }
            activeDirectoryMove = nil
            guard let move = moveBySourceID[originalID] else {
                mappedIDByOriginalID[originalID] = originalID
                continue
            }
            mappedIDByOriginalID[originalID] = move.destinationPath.id
            if move.sourcePath.kind == .directory {
                activeDirectoryMove = move
            }
        }

        func mappedID(_ id: String) -> String {
            mappedIDByOriginalID[id] ?? id
        }

        var roots = originalPreparedTree.rootIDs.map(mappedID).filter {
            preparedTree.contains($0) && preparedTree.parentByID[$0] == nil
        }
        var childrenByID: [String: [String]] = [:]
        childrenByID.reserveCapacity(originalPreparedTree.childrenByID.count)
        for originalParentID in originalPreparedTree.preorderIDs {
            let parentID = mappedID(originalParentID)
            guard preparedTree.contains(parentID) else { continue }
            let children = (originalPreparedTree.childrenByID[originalParentID] ?? [])
                .map(mappedID)
                .filter {
                    preparedTree.contains($0) && preparedTree.parentByID[$0] == parentID
                }
            childrenByID[parentID] = children
        }

        var siblings = plan.destinationParentID.flatMap { childrenByID[$0] } ?? roots
        let movedSet = Set(plan.movedDestinationIDs)
        let movedIDs = plan.movedDestinationIDs.filter(preparedTree.contains)
        siblings.removeAll(where: movedSet.contains)

        let insertionIndex: Int
        switch plan.position {
        case .inside:
            insertionIndex = siblings.endIndex
        case .before:
            guard let referenceID = plan.referenceID,
                  let index = siblings.firstIndex(of: referenceID)
            else { throw FileTreePathMutationError.invalidDestination(path: plan.referenceID ?? "") }
            insertionIndex = index
        case .after:
            guard let referenceID = plan.referenceID,
                  let index = siblings.firstIndex(of: referenceID)
            else { throw FileTreePathMutationError.invalidDestination(path: plan.referenceID ?? "") }
            insertionIndex = siblings.index(after: index)
        }
        siblings.insert(contentsOf: movedIDs, at: insertionIndex)
        if let destinationParentID = plan.destinationParentID {
            childrenByID[destinationParentID] = siblings
        } else {
            roots = siblings
        }

        var preorder: [String] = []
        preorder.reserveCapacity(preparedTree.count)
        var stack = Array(roots.reversed())
        while let id = stack.popLast() {
            preorder.append(id)
            let children = childrenByID[id] ?? (preparedTree.childrenByID[id] ?? [])
            stack.append(contentsOf: children.reversed())
        }
        let rank = Dictionary(uniqueKeysWithValues: preorder.enumerated().map { ($1, $0) })

        var nextState = state
        nextState.explicitPaths = try state.explicitPaths.enumerated().sorted { left, right in
            let leftPath = try FileTreePath(path: left.element)
            let rightPath = try FileTreePath(path: right.element)
            return (rank[leftPath.id] ?? Int.max, left.offset)
                < (rank[rightPath.id] ?? Int.max, right.offset)
        }.map(\.element)
        return nextState
    }

    private static func parentDirectoryID(of path: FileTreePath) -> String? {
        let logicalPath = path.kind == .directory
            ? String(path.path.dropLast())
            : path.path
        guard let separator = logicalPath.lastIndex(of: "/") else { return nil }
        return String(logicalPath[..<separator]) + "/"
    }

    private static func contains(_ id: String, in root: FileTreePath) -> Bool {
        id == root.id || (root.kind == .directory && id.hasPrefix(root.path))
    }

    private static func moving(
        _ id: String,
        from source: FileTreePath,
        to destination: FileTreePath
    ) -> String {
        guard contains(id, in: source) else { return id }
        let suffix = id.dropFirst(source.path.count)
        return destination.path + suffix
    }
}

private extension Set where Element == String {
    func filteringIDs(_ predicate: (String) throws -> Bool) rethrows -> Set<String> {
        try Set(filter(predicate))
    }
}

private extension FileTreePath.Kind {
    var description: String {
        switch self {
        case .file: "a file"
        case .directory: "a directory"
        }
    }
}
