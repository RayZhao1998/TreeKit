import Combine
import Foundation

/// A completed inline rename expressed in canonical path identities.
public struct FileTreeRenameEvent: Equatable, Sendable {
    public let sourcePath: FileTreePath
    public let destinationPath: FileTreePath
    public let kind: FileTreePath.Kind

    public init(
        sourcePath: FileTreePath,
        destinationPath: FileTreePath,
        kind: FileTreePath.Kind
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.kind = kind
    }
}

/// Validation failures produced by the shared inline-rename workflow.
public enum FileTreeRenameError: Error, Equatable, Sendable {
    case noFocusedItem
    case noActiveRename
    case identityNotFound(path: String)
    case policyRejected(path: String)
    case emptyName
    case invalidComponent(name: String)
    case duplicateDestination(path: String)
    case mutation(FileTreePathMutationError)
}

extension FileTreeRenameError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noFocusedItem:
            "No focused file tree item is available to rename."
        case .noActiveRename:
            "No inline rename is active."
        case .identityNotFound(let path):
            "No file tree item exists at '\(path)'."
        case .policyRejected(let path):
            "Renaming '\(path)' is not allowed."
        case .emptyName:
            "A file or directory name cannot be empty."
        case .invalidComponent(let name):
            "'\(name)' is not a valid single path component."
        case .duplicateDestination(let path):
            "A file tree item already exists at '\(path)'."
        case .mutation(let error):
            error.localizedDescription
        }
    }
}

/// Caller policy and lifecycle hooks for inline rename.
public struct FileTreeRenameConfiguration {
    public var canRename: @MainActor (FileTreePath) -> Bool
    public var onRename: @MainActor (FileTreeRenameEvent) -> Void
    public var onError: @MainActor (FileTreeRenameError) -> Void

    public init(
        canRename: @escaping @MainActor (FileTreePath) -> Bool = { _ in true },
        onRename: @escaping @MainActor (FileTreeRenameEvent) -> Void = { _ in },
        onError: @escaping @MainActor (FileTreeRenameError) -> Void = { _ in }
    ) {
        self.canRename = canRename
        self.onRename = onRename
        self.onError = onError
    }
}

@MainActor
public extension FileTreeModel where Node == FileTreePath {
    /// The canonical identity currently being renamed, if an inline session is active.
    var renamingID: String? { activeRenamingID }

    /// The most recent inline-rename validation error.
    var renameError: FileTreeRenameError? { activeRenameError }

    /// Typed events emitted after a rename has completed through the shared path mutation.
    var renameEvents: AnyPublisher<FileTreeRenameEvent, Never> {
        renameSubject().eraseToAnyPublisher()
    }

    /// Replaces rename policy and lifecycle hooks without changing an active tree projection.
    func configureRenaming(_ configuration: FileTreeRenameConfiguration) {
        fileTreeRenameConfiguration = configuration
    }

    /// Starts inline rename for a canonical identity, or for the focused row when omitted.
    ///
    /// A flattened directory chain resolves to its terminal interaction identity. The target is
    /// revealed, selected, and focused before native AppKit or UIKit mounts the editor.
    func startRenaming(_ id: String? = nil) throws {
        guard let requestedID = id ?? focusedID else {
            try failRename(.noFocusedItem)
        }
        guard preparedTree.contains(requestedID) else {
            try failRename(.identityNotFound(path: requestedID))
        }
        let targetID = canonicalInteractionID(for: requestedID)
        guard let source = preparedTree.node(for: targetID) else {
            try failRename(.identityNotFound(path: targetID))
        }
        let configuration = fileTreeRenameConfiguration ?? .init()
        guard configuration.canRename(source) else {
            try failRename(.policyRejected(path: source.path))
        }

        if isSearchOpen {
            closeSearch()
        }
        reveal(targetID, select: true, position: .nearest, focus: true)
        beginRenameSession(
            id: targetID,
            commit: { [weak self] name in
                guard let self else { return .failure(.noActiveRename) }
                do {
                    try self.commitRenaming(name)
                    return .success(())
                } catch let error as FileTreeRenameError {
                    return .failure(error)
                } catch {
                    return .failure(.noActiveRename)
                }
            },
            cancel: { [weak self] in
                self?.restoreFocusAfterRename()
            }
        )
    }

    /// Commits the active rename as a same-parent path mutation.
    ///
    /// Validation failures leave the editor and hierarchy unchanged and are also delivered to
    /// the configured `onError` hook.
    func commitRenaming(_ proposedName: String) throws {
        guard let sourceID = renamingID else {
            try failRename(.noActiveRename)
        }
        guard let source = preparedTree.node(for: sourceID) else {
            try failRename(.identityNotFound(path: sourceID))
        }

        let configuration = fileTreeRenameConfiguration ?? .init()
        guard configuration.canRename(source) else {
            try failRename(.policyRejected(path: source.path))
        }

        let trimmedComponent = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedComponent.isEmpty else { try failRename(.emptyName) }
        let component = proposedName
        let invalidScalars = component.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
        guard component != ".", component != "..",
              !component.contains("/"), !component.contains("\\"), !invalidScalars
        else {
            try failRename(.invalidComponent(name: proposedName))
        }

        let destinationString = Self.renameDestination(for: source, component: component)
        guard destinationString != source.path else {
            clearRenameSession(publishing: true)
            restoreFocusAfterRename()
            return
        }
        guard !preparedTree.contains(destinationString) else {
            try failRename(.duplicateDestination(path: destinationString))
        }

        let destination: FileTreePath
        do {
            destination = try FileTreePath(path: destinationString, kind: source.kind)
        } catch {
            try failRename(.invalidComponent(name: proposedName))
        }

        // End the editor before the path mutation publishes its single coherent hierarchy update.
        clearRenameSession(publishing: false)
        do {
            try move(source.path, to: destination.path)
        } catch let error as FileTreePathMutationError {
            try failRename(.mutation(error))
        }

        let event = FileTreeRenameEvent(
            sourcePath: source,
            destinationPath: destination,
            kind: source.kind
        )
        configuration.onRename(event)
        renameSubject().send(event)
        restoreFocusAfterRename()
    }

    /// Cancels the active editor without mutating the hierarchy.
    func cancelRenaming() {
        cancelActiveRename()
    }

    private func renameSubject() -> PassthroughSubject<FileTreeRenameEvent, Never> {
        if let fileTreeRenameSubject { return fileTreeRenameSubject }
        let subject = PassthroughSubject<FileTreeRenameEvent, Never>()
        fileTreeRenameSubject = subject
        return subject
    }

    private func failRename(_ error: FileTreeRenameError) throws -> Never {
        reportRenameError(error)
        (fileTreeRenameConfiguration ?? .init()).onError(error)
        throw error
    }

    private func restoreFocusAfterRename() {
        if focusedID == nil || focusedID.map({ !preparedTree.contains($0) }) == true {
            focusNearestItem()
        }
    }

    private static func renameDestination(
        for source: FileTreePath,
        component: String
    ) -> String {
        let identity = source.kind == .directory
            ? String(source.path.dropLast())
            : source.path
        let parent = identity.lastIndex(of: "/").map {
            String(identity[...$0])
        } ?? ""
        return parent + component + (source.kind == .directory ? "/" : "")
    }
}
