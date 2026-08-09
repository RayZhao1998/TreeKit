import Testing
@testable import TreeKit

private struct TestNode: Identifiable, Sendable {
    let id: String
    var children: [TestNode] = []
}

struct PreparedTreeTests {
    @Test
    func preparesStableIndexesInPreorder() throws {
        let input = TestNode(
            id: "root",
            children: [
                TestNode(
                    id: "Sources",
                    children: [
                        TestNode(id: "App.swift"),
                        TestNode(id: "Model.swift")
                    ]
                ),
                TestNode(id: "README.md")
            ]
        )

        let tree = try PreparedTree(roots: [input], children: \.children)

        #expect(tree.count == 5)
        #expect(tree.nodes.map(\.id) == ["root", "Sources", "App.swift", "Model.swift", "README.md"])
        #expect(tree.children(of: "root").map(\.id) == ["Sources", "README.md"])
        #expect(tree.parentID(of: "App.swift") == "Sources")
        #expect(tree.depth(of: "Model.swift") == 2)
        #expect(tree.ancestorIDs(of: "Model.swift") == ["root", "Sources"])
        #expect(tree.isExpandable("Sources"))
        #expect(!tree.isExpandable("README.md"))
    }

    @Test
    func rejectsDuplicateIdentityAndCyclesAtTheSameSeam() {
        let input = TestNode(
            id: "root",
            children: [
                TestNode(id: "duplicate"),
                TestNode(id: "duplicate")
            ]
        )

        #expect(throws: TreePreparationError.duplicateIdentifier("duplicate")) {
            try PreparedTree(roots: [input], children: \.children)
        }
    }
}

@MainActor
struct FileTreeModelTests {
    @Test
    func expansionUpdatesOnlyTheAffectedVisibleProjection() throws {
        let input = TestNode(
            id: "root",
            children: [
                TestNode(
                    id: "folder",
                    children: [TestNode(id: "file")]
                )
            ]
        )
        let tree = try PreparedTree(roots: [input], children: \.children)
        let model = FileTreeModel(tree)

        #expect(model.visibleRows.map(\.id) == ["root"])

        // Hidden descendants can remember expansion without forcing their ancestors open.
        model.expand("folder")
        #expect(model.visibleRows.map(\.id) == ["root"])

        model.expand("root")
        #expect(model.visibleRows.map(\.id) == ["root", "folder", "file"])

        model.collapse("root")
        #expect(model.visibleRows.map(\.id) == ["root"])
        #expect(model.expandedIDs.contains("folder"))
    }

    @Test
    func resetPreservesOnlyRetainedIdentityState() throws {
        let original = try PreparedTree(
            roots: [
                TestNode(
                    id: "root",
                    children: [
                        TestNode(id: "keep"),
                        TestNode(id: "remove")
                    ]
                )
            ],
            children: \.children
        )
        let model = FileTreeModel(
            original,
            initialExpansion: .identifiers(["root"]),
            initialSelection: ["remove"]
        )

        let replacement = try PreparedTree(
            roots: [
                TestNode(
                    id: "root",
                    children: [TestNode(id: "keep")]
                )
            ],
            children: \.children
        )
        model.reset(replacement)

        #expect(model.expandedIDs == ["root"])
        #expect(model.selection.isEmpty)
        #expect(model.visibleRows.map(\.id) == ["root", "keep"])
    }

    @Test
    func revealExpandsAncestorsSelectsAndPublishesOnce() throws {
        let tree = try PreparedTree(
            roots: [
                TestNode(
                    id: "root",
                    children: [
                        TestNode(
                            id: "folder",
                            children: [TestNode(id: "file")]
                        )
                    ]
                )
            ],
            children: \.children
        )
        let model = FileTreeModel(tree)
        let revision = model.revision

        model.reveal("file", position: .center)

        #expect(model.revision == revision + 1)
        #expect(model.expandedIDs == ["root", "folder"])
        #expect(model.selection == ["file"])
        #expect(model.focusedID == "file")
        #expect(model.visibleRows.map(\.id) == ["root", "folder", "file"])
    }

    @Test
    func handlesLargeFlatBranchesWithoutRecursiveViewConstruction() throws {
        let childCount = 20_000
        let root = TestNode(
            id: "root",
            children: (0..<childCount).map { TestNode(id: "file-\($0)") }
        )
        let tree = try PreparedTree(roots: [root], children: \.children)
        let model = FileTreeModel(tree)

        model.expand("root")

        #expect(tree.count == childCount + 1)
        #expect(model.visibleRows.count == childCount + 1)
        #expect(model.visibleRows(in: 10..<20).count == 10)
    }

    @Test
    func selectionDoesNotInvalidateTheExpansionProjection() throws {
        let tree = try PreparedTree(
            roots: [TestNode(id: "root", children: [TestNode(id: "file")])],
            children: \.children
        )
        let model = FileTreeModel(tree)
        let expansionRevision = model.expansionRevision

        model.select("root")
        #expect(model.expansionRevision == expansionRevision)

        model.expand("root")
        #expect(model.expansionRevision == expansionRevision + 1)
    }
}
