/// Storage-neutral hierarchy facts consumed by ``FileTreeModel`` and its native renderers.
///
/// Renderers intentionally receive these facts through the model instead of retaining a
/// `PreparedTree`. A later lazy store can therefore expose only discovered nodes without
/// changing the renderer-facing contract.
internal protocol FileTreeHierarchyQuery<Node> {
    associatedtype Node: Identifiable

    var count: Int { get }
    var rootIDs: [Node.ID] { get }
    var preorderIDs: [Node.ID] { get }

    func contains(_ id: Node.ID) -> Bool
    func node(for id: Node.ID) -> Node?
    func childIDs(of id: Node.ID) -> [Node.ID]
    func parentID(of id: Node.ID) -> Node.ID?
    func depth(of id: Node.ID) -> Int?
    func siblingIndex(of id: Node.ID) -> Int?
    func siblingCount(of id: Node.ID) -> Int
    func isExpandable(_ id: Node.ID) -> Bool
    func ancestorIDs(of id: Node.ID) -> [Node.ID]
}

/// Adapts the existing immutable eager hierarchy to the storage-neutral query seam.
///
/// `PreparedTree` uses copy-on-write collections, so retaining it here does not duplicate its
/// index buffers.
internal struct PreparedTreeHierarchyQuery<Node: Identifiable>: FileTreeHierarchyQuery {
    private let tree: PreparedTree<Node>

    init(_ tree: PreparedTree<Node>) {
        self.tree = tree
    }

    var count: Int { tree.count }
    var rootIDs: [Node.ID] { tree.rootIDs }
    var preorderIDs: [Node.ID] { tree.preorderIDs }

    func contains(_ id: Node.ID) -> Bool { tree.contains(id) }
    func node(for id: Node.ID) -> Node? { tree.node(for: id) }
    func childIDs(of id: Node.ID) -> [Node.ID] { tree.childrenByID[id] ?? [] }
    func parentID(of id: Node.ID) -> Node.ID? { tree.parentID(of: id) }
    func depth(of id: Node.ID) -> Int? { tree.depth(of: id) }
    func siblingIndex(of id: Node.ID) -> Int? { tree.siblingIndexByID[id] }
    func siblingCount(of id: Node.ID) -> Int { tree.siblingCount(of: id) }
    func isExpandable(_ id: Node.ID) -> Bool { tree.isExpandable(id) }
    func ancestorIDs(of id: Node.ID) -> [Node.ID] { tree.ancestorIDs(of: id) }
}

extension PreparedTreeHierarchyQuery: Sendable where Node: Sendable, Node.ID: Sendable {}
