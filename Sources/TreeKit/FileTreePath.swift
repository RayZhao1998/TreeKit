import Foundation

/// A path-first file tree node.
///
/// `path` is the stable public identity. It is always relative, uses `/` separators, and has
/// no empty or `.` components. Directory identities end in `/`, matching the path convention
/// used by `@pierre/trees`; file identities do not.
public struct FileTreePath: Identifiable, Hashable, Sendable {
    /// The filesystem role represented by a path.
    public enum Kind: Hashable, Sendable {
        case file
        case directory
    }

    /// The canonical relative path used for selection, expansion, and lookup.
    public let path: String

    /// The final path component without a trailing separator.
    public let name: String

    /// Whether this node represents a file or directory.
    public let kind: Kind

    /// Canonical paths are the public identity space for the tree.
    public var id: String { path }

    /// Creates one normalized path value.
    ///
    /// When `kind` is omitted, a trailing `/` (or terminal `.` component) denotes a directory;
    /// otherwise the path denotes a file.
    public init(path: String, kind: Kind? = nil) throws {
        let parsed = try ParsedFileTreePath(path)
        self.init(
            logicalPath: parsed.logicalPath,
            name: parsed.components[parsed.components.count - 1],
            kind: kind ?? parsed.inferredKind
        )
    }

    fileprivate init(logicalPath: String, name: String, kind: Kind) {
        self.path = kind == .directory ? logicalPath + "/" : logicalPath
        self.name = name
        self.kind = kind
    }
}

/// Path shaping options applied before a file tree is rendered.
public struct FileTreePathOptions: Equatable, Sendable {
    /// Sibling ordering used in the prepared hierarchy.
    public enum Sort: Equatable, Sendable {
        /// Retains the order in which each sibling first appears in `paths`.
        case inputOrder

        /// Orders every sibling set by its canonical component name.
        case lexicographic

        /// Places directories before files, ordering each group lexicographically.
        case foldersFirst
    }

    public var sort: Sort

    public init(sort: Sort = .foldersFirst) {
        self.sort = sort
    }
}

/// Errors raised while canonicalizing a path-first file tree.
public enum FileTreePathError: Error, Equatable, Sendable {
    /// The input had no components after repeated separators and `.` were removed.
    case emptyPath

    /// Canonical tree identities are project-relative rather than filesystem-absolute.
    case absolutePath(path: String)

    /// Parent traversal is intentionally unsupported for relative tree identities.
    case parentTraversal(path: String)

    /// One logical path was required to be both a file and a directory.
    case kindConflict(
        path: String,
        existing: FileTreePath.Kind,
        incoming: FileTreePath.Kind
    )
}

extension FileTreePathError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyPath:
            "File tree paths must contain at least one named component."
        case .absolutePath(let path):
            "File tree paths must be relative: \(path)"
        case .parentTraversal(let path):
            "File tree paths cannot contain '..': \(path)"
        case .kindConflict(let path, let existing, let incoming):
            "File tree path '\(path)' cannot be both \(existing.description) and \(incoming.description)."
        }
    }
}

/// Converts a flat, path-first input into an indexed hierarchy ready for rendering.
///
/// A trailing `/` denotes an explicit directory. Other paths denote files. Repeated separators
/// and `.` components are removed, missing ancestors are synthesized as directories, and
/// duplicate canonical paths of the same kind are collapsed. File/directory collisions throw.
public func prepareFileTree(
    paths: [String],
    options: FileTreePathOptions = .init()
) throws -> PreparedTree<FileTreePath> {
    var entriesByLogicalPath: [String: FileTreePath] = [:]
    entriesByLogicalPath.reserveCapacity(paths.count)

    // The empty key is the synthetic forest root. Real paths cannot normalize to an empty key.
    var childPathsByParent: [String: [String]] = [:]
    childPathsByParent.reserveCapacity(paths.count)

    for inputPath in paths {
        let parsed = try ParsedFileTreePath(inputPath)
        var logicalPath = ""
        logicalPath.reserveCapacity(parsed.logicalPath.count)

        for componentIndex in parsed.components.indices {
            let parentPath = logicalPath
            if !logicalPath.isEmpty {
                logicalPath.append("/")
            }
            logicalPath.append(parsed.components[componentIndex])

            let isLeaf = componentIndex == parsed.components.index(before: parsed.components.endIndex)
            let kind: FileTreePath.Kind = isLeaf ? parsed.inferredKind : .directory

            if let existing = entriesByLogicalPath[logicalPath] {
                guard existing.kind == kind else {
                    throw FileTreePathError.kindConflict(
                        path: logicalPath,
                        existing: existing.kind,
                        incoming: kind
                    )
                }
                continue
            }

            let node = FileTreePath(
                logicalPath: logicalPath,
                name: parsed.components[componentIndex],
                kind: kind
            )
            entriesByLogicalPath[logicalPath] = node
            childPathsByParent[parentPath, default: []].append(logicalPath)
        }
    }

    if options.sort != .inputOrder {
        for parentPath in Array(childPathsByParent.keys) {
            guard let children = childPathsByParent[parentPath] else { continue }
            childPathsByParent[parentPath] = children.sorted { leftPath, rightPath in
                guard
                    let left = entriesByLogicalPath[leftPath],
                    let right = entriesByLogicalPath[rightPath]
                else {
                    // Construction above guarantees both entries. This fallback keeps ordering
                    // deterministic if that invariant changes in a future implementation.
                    return leftPath < rightPath
                }

                if options.sort == .foldersFirst, left.kind != right.kind {
                    return left.kind == .directory
                }
                if left.name != right.name {
                    return left.name < right.name
                }
                return left.path < right.path
            }
        }
    }

    var childrenByID: [String: [FileTreePath]] = [:]
    childrenByID.reserveCapacity(childPathsByParent.count)
    for (parentPath, childPaths) in childPathsByParent where !parentPath.isEmpty {
        guard let parent = entriesByLogicalPath[parentPath] else { continue }
        childrenByID[parent.id] = childPaths.compactMap { entriesByLogicalPath[$0] }
    }

    let roots = (childPathsByParent[""] ?? []).compactMap { entriesByLogicalPath[$0] }
    return try PreparedTree(roots: roots) { node in
        childrenByID[node.id] ?? []
    }
}

public extension FileTreeModel where Node == FileTreePath {
    /// Creates a long-lived model directly from a path-first input.
    convenience init(
        paths: [String],
        options: FileTreePathOptions = .init(),
        initialExpansion: FileTreeInitialExpansion<String> = .collapsed,
        initialSelection: Set<String> = []
    ) throws {
        try self.init(
            prepareFileTree(paths: paths, options: options),
            initialExpansion: initialExpansion,
            initialSelection: initialSelection
        )
    }
}

private struct ParsedFileTreePath {
    let components: [String]
    let logicalPath: String
    let inferredKind: FileTreePath.Kind

    init(_ inputPath: String) throws {
        guard inputPath.first != "/" else {
            throw FileTreePathError.absolutePath(path: inputPath)
        }

        let rawComponents = inputPath.split(separator: "/", omittingEmptySubsequences: true)
        let terminalComponent = rawComponents.last
        var components: [String] = []
        components.reserveCapacity(rawComponents.count)

        for rawComponent in rawComponents {
            if rawComponent == "." {
                continue
            }
            if rawComponent == ".." {
                throw FileTreePathError.parentTraversal(path: inputPath)
            }
            components.append(String(rawComponent))
        }

        guard !components.isEmpty else {
            throw FileTreePathError.emptyPath
        }

        self.components = components
        self.logicalPath = components.joined(separator: "/")
        self.inferredKind = inputPath.last == "/" || terminalComponent == "."
            ? .directory
            : .file
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
