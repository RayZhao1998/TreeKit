import Foundation

/// An immutable, validated hierarchy prepared for repeated tree rendering.
///
/// Preparing a tree builds identity, parent, child, depth, and sibling indexes once. A
/// ``FileTreeModel`` can then replace its data without asking a SwiftUI row to recursively
/// discover the hierarchy.
public struct PreparedTree<Node: Identifiable> {
    internal let rootIDs: [Node.ID]
    internal let nodesByID: [Node.ID: Node]
    internal let childrenByID: [Node.ID: [Node.ID]]
    internal let parentByID: [Node.ID: Node.ID]
    internal let depthByID: [Node.ID: Int]
    internal let siblingIndexByID: [Node.ID: Int]
    internal let preorderIDs: [Node.ID]

    /// Creates a prepared tree while preserving root and sibling order.
    ///
    /// Every identifier must occur exactly once in the forest. Reusing an identifier, including
    /// through a cycle, throws ``TreePreparationError/duplicateIdentifier(_:)``.
    public init(
        roots: [Node],
        children: (Node) -> [Node]
    ) throws {
        let rootsWithPositions = roots.enumerated().map { index, node in
            (node: node, parentID: Optional<Node.ID>.none, depth: 0, siblingIndex: index)
        }

        var stack = Array(rootsWithPositions.reversed())
        var rootIDs: [Node.ID] = roots.map(\.id)
        var nodesByID: [Node.ID: Node] = [:]
        var childrenByID: [Node.ID: [Node.ID]] = [:]
        var parentByID: [Node.ID: Node.ID] = [:]
        var depthByID: [Node.ID: Int] = [:]
        var siblingIndexByID: [Node.ID: Int] = [:]
        var preorderIDs: [Node.ID] = []
        preorderIDs.reserveCapacity(roots.count)

        while let pending = stack.popLast() {
            let id = pending.node.id
            guard nodesByID[id] == nil else {
                throw TreePreparationError.duplicateIdentifier(String(describing: id))
            }

            nodesByID[id] = pending.node
            depthByID[id] = pending.depth
            siblingIndexByID[id] = pending.siblingIndex
            preorderIDs.append(id)

            if let parentID = pending.parentID {
                parentByID[id] = parentID
            }

            let childNodes = children(pending.node)
            let childIDs = childNodes.map(\.id)
            if !childIDs.isEmpty {
                childrenByID[id] = childIDs
            }

            for (index, child) in childNodes.enumerated().reversed() {
                stack.append(
                    (
                        node: child,
                        parentID: id,
                        depth: pending.depth + 1,
                        siblingIndex: index
                    )
                )
            }
        }

        // Keep this mutable during construction so the compiler can infer the generic dictionary
        // storage efficiently, then publish the immutable value below.
        rootIDs = rootIDs.filter { nodesByID[$0] != nil }

        self.rootIDs = rootIDs
        self.nodesByID = nodesByID
        self.childrenByID = childrenByID
        self.parentByID = parentByID
        self.depthByID = depthByID
        self.siblingIndexByID = siblingIndexByID
        self.preorderIDs = preorderIDs
    }

    /// Creates a prepared tree from a non-optional children key path.
    public init(roots: [Node], children: KeyPath<Node, [Node]>) throws {
        try self.init(roots: roots) { $0[keyPath: children] }
    }

    /// Creates a prepared tree from an optional children key path.
    public init(roots: [Node], children: KeyPath<Node, [Node]?>) throws {
        try self.init(roots: roots) { $0[keyPath: children] ?? [] }
    }

    /// The number of nodes in the complete hierarchy, including collapsed nodes.
    public var count: Int { preorderIDs.count }

    /// The roots in caller-provided order.
    public var roots: [Node] { rootIDs.compactMap { nodesByID[$0] } }

    /// Every node in depth-first preorder.
    public var nodes: [Node] { preorderIDs.compactMap { nodesByID[$0] } }

    /// Returns whether the prepared hierarchy contains an identifier.
    public func contains(_ id: Node.ID) -> Bool { nodesByID[id] != nil }

    /// Returns the node for an identifier.
    public func node(for id: Node.ID) -> Node? { nodesByID[id] }

    /// Returns a node's children in caller-provided order.
    public func children(of id: Node.ID) -> [Node] {
        (childrenByID[id] ?? []).compactMap { nodesByID[$0] }
    }

    /// Returns the parent identifier, or `nil` for a root or unknown identifier.
    public func parentID(of id: Node.ID) -> Node.ID? { parentByID[id] }

    /// Returns a node's zero-based hierarchy depth.
    public func depth(of id: Node.ID) -> Int? { depthByID[id] }

    internal func siblingCount(of id: Node.ID) -> Int {
        guard let parentID = parentByID[id] else { return rootIDs.count }
        return childrenByID[parentID]?.count ?? 0
    }

    /// Returns whether a node currently has children.
    public func isExpandable(_ id: Node.ID) -> Bool {
        !(childrenByID[id] ?? []).isEmpty
    }

    /// Returns ancestor identifiers from the root down to the direct parent.
    public func ancestorIDs(of id: Node.ID) -> [Node.ID] {
        var result: [Node.ID] = []
        var current = parentByID[id]

        while let ancestor = current {
            result.append(ancestor)
            current = parentByID[ancestor]
        }

        return result.reversed()
    }
}

extension PreparedTree: Sendable where Node: Sendable, Node.ID: Sendable {}

/// Errors raised while converting caller-owned data into a prepared hierarchy.
public enum TreePreparationError: Error, Equatable, Sendable {
    /// One identifier appeared more than once. A cycle also manifests as a repeated identifier.
    case duplicateIdentifier(String)
}

extension TreePreparationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .duplicateIdentifier(let identifier):
            "Tree node identifiers must be unique. Repeated identifier: \(identifier)"
        }
    }
}
