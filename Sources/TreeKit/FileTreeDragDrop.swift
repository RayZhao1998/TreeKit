import Combine
import Foundation

/// Placement of dragged paths relative to a canonical drop target.
public enum FileTreeDropPosition: String, Equatable, Sendable {
    case before
    case after
    case inside
}

/// A platform-neutral drop target.
public struct FileTreeDropTarget: Equatable, Sendable {
    /// The hovered canonical item, or `nil` when dropping inside the forest root.
    public let path: FileTreePath?
    public let position: FileTreeDropPosition

    public init(path: FileTreePath?, position: FileTreeDropPosition) {
        self.path = path
        self.position = position
    }

    /// The directory that receives moved paths, or `nil` for the forest root.
    public var destinationDirectoryPath: String? {
        switch position {
        case .inside:
            return path?.kind == .directory ? path?.path : nil
        case .before, .after:
            guard let path else { return nil }
            let logicalPath = path.kind == .directory
                ? String(path.path.dropLast())
                : path.path
            guard let separator = logicalPath.lastIndex(of: "/") else { return nil }
            return String(logicalPath[..<separator]) + "/"
        }
    }
}

/// Canonical sources captured when a native drag begins.
public struct FileTreeDragSession: Equatable, Sendable {
    public let sourcePaths: [FileTreePath]
    internal let originID: UUID?

    public init(sourcePaths: [FileTreePath]) {
        self.sourcePaths = sourcePaths
        self.originID = nil
    }

    internal init(sourcePaths: [FileTreePath], originID: UUID) {
        self.sourcePaths = sourcePaths
        self.originID = originID
    }
}

/// One canonical move produced by a successful drop.
public struct FileTreeDropMove: Equatable, Sendable {
    public let sourcePath: FileTreePath
    public let destinationPath: FileTreePath

    public init(sourcePath: FileTreePath, destinationPath: FileTreePath) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
    }
}

/// A validated drop before it mutates model state.
public struct FileTreeDropProposal: Equatable, Sendable {
    public let sourcePaths: [FileTreePath]
    public let target: FileTreeDropTarget
    public let destinationPaths: [FileTreePath]

    public init(
        sourcePaths: [FileTreePath],
        target: FileTreeDropTarget,
        destinationPaths: [FileTreePath]
    ) {
        self.sourcePaths = sourcePaths
        self.target = target
        self.destinationPaths = destinationPaths
    }
}

/// Payload emitted after an internal drop transaction succeeds.
public struct FileTreeDropEvent: Equatable, Sendable {
    public let proposal: FileTreeDropProposal
    public let moves: [FileTreeDropMove]

    public init(proposal: FileTreeDropProposal, moves: [FileTreeDropMove]) {
        self.proposal = proposal
        self.moves = moves
    }
}

/// Payload emitted when a requested drop is rejected.
public struct FileTreeDropFailure: Equatable, Sendable {
    public let sourcePaths: [FileTreePath]
    public let target: FileTreeDropTarget
    public let error: FileTreeDragDropError

    public init(
        sourcePaths: [FileTreePath],
        target: FileTreeDropTarget,
        error: FileTreeDragDropError
    ) {
        self.sourcePaths = sourcePaths
        self.target = target
        self.error = error
    }
}

/// Typed drag/drop lifecycle events.
public enum FileTreeDragDropEvent: Equatable, Sendable {
    case completed(FileTreeDropEvent)
    case failed(FileTreeDropFailure)
}

/// Validation failures for path-first drag and drop.
public enum FileTreeDragDropError: Error, Equatable, Sendable {
    case noSources
    case foreignSession
    case sourceNotFound(path: String)
    case dragRejected(paths: [String])
    case invalidTarget
    case dropRejected
    case selfDrop(path: String)
    case moveIntoDescendant(source: String, destination: String)
    case duplicateDestination(path: String)
    case mutation(FileTreePathMutationError)
}

extension FileTreeDragDropError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noSources:
            "A drag requires at least one source path."
        case .foreignSession:
            "The native drag originated from a different file tree model."
        case .sourceNotFound(let path):
            "No file tree item exists at '\(path)'."
        case .dragRejected(let paths):
            "Dragging is not allowed for: \(paths.joined(separator: ", "))."
        case .invalidTarget:
            "The requested drop target is not valid."
        case .dropRejected:
            "The drop was rejected by caller policy."
        case .selfDrop(let path):
            "'\(path)' cannot be dropped onto itself."
        case .moveIntoDescendant(let source, let destination):
            "'\(source)' cannot be moved into its descendant '\(destination)'."
        case .duplicateDestination(let path):
            "A file tree item already exists at '\(path)'."
        case .mutation(let error):
            error.localizedDescription
        }
    }
}

/// Caller policy and lifecycle hooks for native drag and drop.
public struct FileTreeDragDropConfiguration {
    public var canDrag: @MainActor ([FileTreePath]) -> Bool
    public var canDrop: @MainActor (FileTreeDropProposal) -> Bool
    public var onDropComplete: @MainActor (FileTreeDropEvent) -> Void
    public var onDropError: @MainActor (FileTreeDropFailure) -> Void
    public var openOnDropDelay: TimeInterval

    public init(
        canDrag: @escaping @MainActor ([FileTreePath]) -> Bool = { _ in true },
        canDrop: @escaping @MainActor (FileTreeDropProposal) -> Bool = { _ in true },
        onDropComplete: @escaping @MainActor (FileTreeDropEvent) -> Void = { _ in },
        onDropError: @escaping @MainActor (FileTreeDropFailure) -> Void = { _ in },
        openOnDropDelay: TimeInterval = 0.7
    ) {
        self.canDrag = canDrag
        self.canDrop = canDrop
        self.onDropComplete = onDropComplete
        self.onDropError = onDropError
        self.openOnDropDelay = max(0, openOnDropDelay)
    }
}

internal struct FileTreeDropReorderPlan {
    let destinationParentID: String?
    let referenceID: String?
    let position: FileTreeDropPosition
    let moves: [FileTreeDropMove]

    var movedDestinationIDs: [String] { moves.map(\.destinationPath.id) }
}

@MainActor
public extension FileTreeModel where Node == FileTreePath {
    /// Typed completion and failure events for requested drops.
    var dragDropEvents: AnyPublisher<FileTreeDragDropEvent, Never> {
        dragDropSubject().eraseToAnyPublisher()
    }

    /// Replaces drag/drop policy, callbacks, and hover-expansion delay.
    func configureDragAndDrop(_ configuration: FileTreeDragDropConfiguration) {
        fileTreeDragDropConfiguration = configuration
    }

    /// Captures one row or its current multi-selection as canonical drag sources.
    func makeDragSession(startingAt id: String) throws -> FileTreeDragSession {
        guard preparedTree.contains(id) else {
            throw FileTreeDragDropError.sourceNotFound(path: id)
        }
        let selectedIDs = selection.contains(id) ? selection : [id]
        let orderedPaths = preparedTree.preorderIDs.compactMap { selectedID -> FileTreePath? in
            guard selectedIDs.contains(selectedID) else { return nil }
            return preparedTree.node(for: selectedID)
        }
        let normalized = normalizedDragSources(orderedPaths)
        guard !normalized.isEmpty else { throw FileTreeDragDropError.noSources }
        let configuration = fileTreeDragDropConfiguration ?? .init()
        guard configuration.canDrag(normalized) else {
            throw FileTreeDragDropError.dragRejected(paths: normalized.map(\.path))
        }
        return FileTreeDragSession(
            sourcePaths: normalized,
            originID: fileTreeDragDropOriginID
        )
    }

    /// Returns a fully resolved proposal without publishing a failure event.
    func dropProposal(
        for session: FileTreeDragSession,
        target: FileTreeDropTarget
    ) throws -> FileTreeDropProposal {
        try resolveDropProposal(session: session, target: target, enforcingPolicy: true)
    }

    /// Lightweight validation for native hover updates.
    func canDrop(
        _ session: FileTreeDragSession,
        target: FileTreeDropTarget
    ) -> Bool {
        (try? resolveDropProposal(session: session, target: target, enforcingPolicy: true)) != nil
    }

    /// Applies one validated drop as an atomic path-mutation transaction.
    @discardableResult
    func performDrop(
        _ session: FileTreeDragSession,
        target: FileTreeDropTarget
    ) throws -> FileTreeDropEvent {
        do {
            let proposal = try resolveDropProposal(
                session: session,
                target: target,
                enforcingPolicy: true
            )
            let moves = zip(proposal.sourcePaths, proposal.destinationPaths).map {
                FileTreeDropMove(sourcePath: $0, destinationPath: $1)
            }
            let referenceID = target.position == .inside ? nil : target.path?.id
            let plan = FileTreeDropReorderPlan(
                destinationParentID: target.destinationDirectoryPath,
                referenceID: referenceID,
                position: target.position,
                moves: moves
            )
            do {
                try applyDrop(moves: moves, reorderPlan: plan)
            } catch let error as FileTreePathMutationError {
                throw FileTreeDragDropError.mutation(error)
            }

            let event = FileTreeDropEvent(proposal: proposal, moves: moves)
            let configuration = fileTreeDragDropConfiguration ?? .init()
            configuration.onDropComplete(event)
            dragDropSubject().send(.completed(event))
            return event
        } catch let error as FileTreeDragDropError {
            let failure = FileTreeDropFailure(
                sourcePaths: session.sourcePaths,
                target: target,
                error: error
            )
            (fileTreeDragDropConfiguration ?? .init()).onDropError(failure)
            dragDropSubject().send(.failed(failure))
            throw error
        }
    }

    internal var dragDropOpenDelay: TimeInterval {
        (fileTreeDragDropConfiguration ?? .init()).openOnDropDelay
    }

    /// Resolves a native rendered row back to the canonical target that owns its placement.
    /// Flattened rows use their first represented segment for before/after and their terminal
    /// segment for inside.
    internal func renderedDropTarget(
        for id: String,
        position: FileTreeDropPosition
    ) -> FileTreeDropTarget? {
        guard let row = visibleRow(for: id) else { return nil }
        let targetID = position == .inside ? row.id : (row.representedIDs.first ?? row.id)
        guard let path = preparedTree.node(for: targetID) else { return nil }
        return FileTreeDropTarget(path: path, position: position)
    }

    private func resolveDropProposal(
        session: FileTreeDragSession,
        target: FileTreeDropTarget,
        enforcingPolicy: Bool
    ) throws -> FileTreeDropProposal {
        guard !session.sourcePaths.isEmpty else { throw FileTreeDragDropError.noSources }
        if let originID = session.originID, originID != fileTreeDragDropOriginID {
            throw FileTreeDragDropError.foreignSession
        }
        let resolvedSources = try session.sourcePaths.map { source -> FileTreePath in
            guard let current = preparedTree.node(for: source.id) else {
                throw FileTreeDragDropError.sourceNotFound(path: source.path)
            }
            return current
        }
        let canonicalSources = normalizedDragSources(resolvedSources)
        let configuration = fileTreeDragDropConfiguration ?? .init()
        if enforcingPolicy, session.originID == nil,
           !configuration.canDrag(canonicalSources) {
            throw FileTreeDragDropError.dragRejected(paths: canonicalSources.map(\.path))
        }

        let canonicalTarget: FileTreePath?
        if let requestedTarget = target.path {
            guard let current = preparedTree.node(for: requestedTarget.id) else {
                throw FileTreeDragDropError.invalidTarget
            }
            canonicalTarget = current
        } else {
            canonicalTarget = nil
        }
        if target.position != .inside, canonicalTarget == nil {
            throw FileTreeDragDropError.invalidTarget
        }
        if target.position == .inside, let canonicalTarget,
           canonicalTarget.kind != .directory {
            throw FileTreeDragDropError.invalidTarget
        }

        if let targetPath = canonicalTarget {
            for source in canonicalSources {
                if source.id == targetPath.id {
                    throw FileTreeDragDropError.selfDrop(path: source.path)
                }
                if source.kind == .directory, targetPath.id.hasPrefix(source.path) {
                    throw FileTreeDragDropError.moveIntoDescendant(
                        source: source.path,
                        destination: targetPath.path
                    )
                }
            }
        }

        let resolvedTarget = FileTreeDropTarget(path: canonicalTarget, position: target.position)
        let parent = resolvedTarget.destinationDirectoryPath ?? ""
        let destinations = try canonicalSources.map { source -> FileTreePath in
            try FileTreePath(
                path: parent + source.name + (source.kind == .directory ? "/" : ""),
                kind: source.kind
            )
        }
        var destinationIDs: Set<String> = []
        var logicalDestinations: Set<String> = []
        for (source, destination) in zip(canonicalSources, destinations) {
            let logicalDestination = destination.kind == .directory
                ? String(destination.path.dropLast())
                : destination.path
            guard destinationIDs.insert(destination.id).inserted,
                  logicalDestinations.insert(logicalDestination).inserted
            else {
                throw FileTreeDragDropError.duplicateDestination(path: destination.path)
            }
            if destination.id == source.id {
                if target.position == .inside {
                    throw FileTreeDragDropError.selfDrop(path: source.path)
                }
                continue
            }
            if preparedTree.contains(destination.id) {
                throw FileTreeDragDropError.duplicateDestination(path: destination.path)
            }
            let oppositeKindID = destination.kind == .directory
                ? logicalDestination
                : destination.path + "/"
            if preparedTree.contains(oppositeKindID) {
                throw FileTreeDragDropError.duplicateDestination(path: destination.path)
            }
            if source.kind == .directory, destination.id.hasPrefix(source.path) {
                throw FileTreeDragDropError.moveIntoDescendant(
                    source: source.path,
                    destination: destination.path
                )
            }
        }

        let proposal = FileTreeDropProposal(
            sourcePaths: canonicalSources,
            target: resolvedTarget,
            destinationPaths: destinations
        )
        if enforcingPolicy, !configuration.canDrop(proposal) {
            throw FileTreeDragDropError.dropRejected
        }
        return proposal
    }

    private func normalizedDragSources(_ sources: [FileTreePath]) -> [FileTreePath] {
        let sourceIDs = Set(sources.map(\.id))
        let orderedSources = preparedTree.preorderIDs.compactMap { id in
            sourceIDs.contains(id) ? preparedTree.node(for: id) : nil
        }
        var normalized: [FileTreePath] = []
        normalized.reserveCapacity(orderedSources.count)
        var activeSelectedDirectoryPath: String?
        for candidate in orderedSources {
            if let activeSelectedDirectoryPath,
               candidate.id.hasPrefix(activeSelectedDirectoryPath) {
                continue
            }
            activeSelectedDirectoryPath = nil
            normalized.append(candidate)
            if candidate.kind == .directory {
                activeSelectedDirectoryPath = candidate.path
            }
        }
        return normalized
    }

    private func dragDropSubject() -> PassthroughSubject<FileTreeDragDropEvent, Never> {
        if let fileTreeDragDropSubject { return fileTreeDragDropSubject }
        let subject = PassthroughSubject<FileTreeDragDropEvent, Never>()
        fileTreeDragDropSubject = subject
        return subject
    }
}
