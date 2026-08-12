import Testing
@testable import TreeKit

struct FileTreeHierarchyQueryTests {
    private struct Node: Identifiable {
        let id: String
        var children: [Node] = []
    }

    @Test
    func eagerAdapterExposesStableHierarchyFacts() throws {
        let tree = try PreparedTree(
            roots: [
                Node(
                    id: "root-a",
                    children: [
                        Node(id: "child-a"),
                        Node(
                            id: "child-b",
                            children: [Node(id: "grandchild")]
                        )
                    ]
                ),
                Node(id: "root-b")
            ],
            children: \.children
        )
        let query = PreparedTreeHierarchyQuery(tree)

        #expect(query.count == 5)
        #expect(query.rootIDs == ["root-a", "root-b"])
        #expect(query.preorderIDs == [
            "root-a", "child-a", "child-b", "grandchild", "root-b"
        ])
        #expect(query.node(for: "child-b")?.id == "child-b")
        #expect(query.childIDs(of: "root-a") == ["child-a", "child-b"])
        #expect(query.parentID(of: "grandchild") == "child-b")
        #expect(query.depth(of: "grandchild") == 2)
        #expect(query.siblingIndex(of: "child-b") == 1)
        #expect(query.siblingCount(of: "child-a") == 2)
        #expect(query.ancestorIDs(of: "grandchild") == ["root-a", "child-b"])
        #expect(query.isExpandable("root-a"))
        #expect(!query.isExpandable("child-a"))
    }

    @Test
    func eagerAdapterReturnsSafeDefaultsForUnknownIdentities() throws {
        let tree = try PreparedTree(
            roots: [Node(id: "root")],
            children: \.children
        )
        let query = PreparedTreeHierarchyQuery(tree)

        #expect(!query.contains("missing"))
        #expect(query.node(for: "missing") == nil)
        #expect(query.childIDs(of: "missing").isEmpty)
        #expect(query.parentID(of: "missing") == nil)
        #expect(query.depth(of: "missing") == nil)
        #expect(query.siblingIndex(of: "missing") == nil)
        #expect(query.siblingCount(of: "missing") == 1)
        #expect(query.ancestorIDs(of: "missing").isEmpty)
        #expect(!query.isExpandable("missing"))
    }

    @Test @MainActor
    func modelQueriesTrackInstalledPreparedTree() throws {
        let initial = try PreparedTree(
            roots: [Node(id: "old")],
            children: \.children
        )
        let replacement = try PreparedTree(
            roots: [Node(id: "new", children: [Node(id: "child")])],
            children: \.children
        )
        let model = FileTreeModel(initial)

        #expect(model.knownNodeIDsInPreorder == ["old"])
        #expect(model.knownNode(for: "old")?.id == "old")

        model.reset(replacement)

        #expect(model.knownNodeCount == 2)
        #expect(model.knownNodeIDsInPreorder == ["new", "child"])
        #expect(model.knownNode(for: "old") == nil)
        #expect(model.knownNode(for: "child")?.id == "child")
        #expect(model.knownParentID(of: "child") == "new")
        #expect(model.knownDepth(of: "child") == 1)
        #expect(model.knownSiblingIndex(of: "child") == 0)
        #expect(model.knownSiblingCount(of: "child") == 1)
        #expect(model.isKnownExpandable("new"))
    }

    @Test @MainActor
    func modelQueriesTrackPathMutations() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: ["Source/Original.swift", "Destination/"]
        )

        try model.add("Source/Added.swift")
        try model.move("Source/Original.swift", to: "Destination/Moved.swift")

        #expect(model.knownNodeCount == model.preparedTree.count)
        #expect(model.knownNodeIDsInPreorder == model.preparedTree.nodes.map(\.id))
        #expect(model.knownNode(for: "Source/Added.swift")?.kind == .file)
        #expect(model.knownNode(for: "Source/Original.swift") == nil)
        #expect(model.knownNode(for: "Destination/Moved.swift")?.kind == .file)
        #expect(model.knownParentID(of: "Destination/Moved.swift") == "Destination/")
    }
}
