import Combine
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
        #expect(tree.siblingCount(of: "root") == 1)
        #expect(tree.siblingCount(of: "Sources") == 2)
        #expect(tree.siblingCount(of: "App.swift") == 2)
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
    private func makeSearchTree() throws -> PreparedTree<TestNode> {
        try PreparedTree(
            roots: [
                TestNode(
                    id: "Sources/",
                    children: [
                        TestNode(id: "Sources/App.swift"),
                        TestNode(
                            id: "Sources/Support/",
                            children: [TestNode(id: "Sources/Support/Logger.swift")]
                        )
                    ]
                ),
                TestNode(
                    id: "Tests/",
                    children: [TestNode(id: "Tests/AppTests.swift")]
                ),
                TestNode(id: "README.md")
            ],
            children: \.children
        )
    }

    @Test
    func searchFiltersMatchesWithAncestorContextWithoutMutatingIdentityState() throws {
        let model = FileTreeModel(
            try makeSearchTree(),
            initialExpansion: .identifiers(["Sources/"]),
            initialSelection: ["README.md"]
        )

        model.openSearch(initialQuery: " APP ")

        #expect(model.isSearchOpen)
        #expect(model.searchQuery == "app")
        #expect(model.matchingIDs == ["Sources/App.swift", "Tests/AppTests.swift"])
        #expect(
            model.visibleRows.map(\.id)
                == ["Sources/", "Sources/App.swift", "Tests/", "Tests/AppTests.swift"]
        )
        #expect(model.selection == ["README.md"])
        #expect(model.expandedIDs == ["Sources/"])
        #expect(model.focusedID == "Sources/App.swift")

        let stableSearchRevision = model.revision
        model.setSearchQuery("app")
        #expect(model.revision == stableSearchRevision)

        model.closeSearch()

        #expect(!model.isSearchOpen)
        #expect(model.searchQuery.isEmpty)
        #expect(model.matchingIDs.isEmpty)
        #expect(
            model.visibleRows.map(\.id)
                == [
                    "Sources/",
                    "Sources/App.swift",
                    "Sources/Support/",
                    "Tests/",
                    "README.md"
                ]
        )
        #expect(model.selection == ["README.md"])
        #expect(model.expandedIDs == ["Sources/"])
        #expect(model.focusedID == "Sources/App.swift")
    }

    @Test
    func searchProjectionModesHaveDocumentedDeterministicShapes() throws {
        let model = FileTreeModel(
            try makeSearchTree(),
            initialExpansion: .identifiers(["Tests/"])
        )

        model.setSearchMode(.expandMatches)
        model.openSearch(initialQuery: "logger")
        #expect(
            model.visibleRows.map(\.id)
                == [
                    "Sources/",
                    "Sources/App.swift",
                    "Sources/Support/",
                    "Sources/Support/Logger.swift",
                    "Tests/",
                    "Tests/AppTests.swift",
                    "README.md"
                ]
        )

        model.setSearchMode(.collapseNonMatches)
        #expect(
            model.visibleRows.map(\.id)
                == [
                    "Sources/",
                    "Sources/App.swift",
                    "Sources/Support/",
                    "Sources/Support/Logger.swift",
                    "Tests/",
                    "README.md"
                ]
        )

        model.setSearchMode(.hideNonMatches)
        #expect(
            model.visibleRows.map(\.id)
                == ["Sources/", "Sources/Support/", "Sources/Support/Logger.swift"]
        )
        #expect(model.expandedIDs == ["Tests/"])
    }

    @Test
    func broadSearchReusesPreviouslyCollectedAncestorPaths() throws {
        let tree = try PreparedTree(
            roots: [
                TestNode(
                    id: "match-root",
                    children: [
                        TestNode(
                            id: "match-parent",
                            children: [
                                TestNode(id: "match-first"),
                                TestNode(id: "match-second")
                            ]
                        )
                    ]
                )
            ],
            children: \.children
        )
        let model = FileTreeModel(tree)

        model.openSearch(initialQuery: "match")

        #expect(
            model.visibleRows.map(\.id)
                == ["match-root", "match-parent", "match-first", "match-second"]
        )
        #expect(model.renderedExpandedIDs == ["match-root", "match-parent"])
    }

    @Test
    func searchMatchNavigationClampsInVisiblePreorder() throws {
        let tree = try PreparedTree(
            roots: [
                TestNode(id: "A.swift"),
                TestNode(id: "B.swift"),
                TestNode(id: "C.txt"),
                TestNode(id: "D.swift")
            ],
            children: \.children
        )
        let model = FileTreeModel(tree, initialSelection: ["C.txt"])

        model.openSearch(initialQuery: "swift")
        #expect(model.focusedID == "A.swift")

        model.focusNextSearchMatch()
        #expect(model.focusedID == "B.swift")
        model.focusNextSearchMatch()
        #expect(model.focusedID == "D.swift")
        model.focusNextSearchMatch()
        #expect(model.focusedID == "D.swift")
        model.focusPreviousSearchMatch()
        #expect(model.focusedID == "B.swift")
        #expect(model.selection == ["C.txt"])
    }

    @Test
    func clearingSearchRestoresProjectionAndEmptyResultsRemainEmpty() throws {
        let model = FileTreeModel(
            try makeSearchTree(),
            initialExpansion: .identifiers(["Sources/"])
        )

        model.openSearch(initialQuery: "does-not-exist")
        #expect(model.isSearchOpen)
        #expect(model.matchingIDs.isEmpty)
        #expect(model.visibleRows.isEmpty)

        model.setSearchQuery("  ")
        #expect(model.isSearchOpen)
        #expect(model.searchQuery.isEmpty)
        #expect(
            model.visibleRows.map(\.id)
                == [
                    "Sources/",
                    "Sources/App.swift",
                    "Sources/Support/",
                    "Tests/",
                    "README.md"
                ]
        )
    }

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
    func revealSplicesTheFirstNewAncestorSubtreeAndPreservesHiddenExpansion() throws {
        let tree = try PreparedTree(
            roots: [
                TestNode(
                    id: "root",
                    children: [
                        TestNode(
                            id: "first",
                            children: [
                                TestNode(
                                    id: "nested",
                                    children: [TestNode(id: "target")]
                                )
                            ]
                        ),
                        TestNode(
                            id: "second",
                            children: [TestNode(id: "sibling")]
                        )
                    ]
                )
            ],
            children: \.children
        )
        let model = FileTreeModel(tree)

        // A hidden branch can be expanded before any of its ancestors become visible.
        model.expand("nested")
        #expect(model.visibleRows.map(\.id) == ["root"])

        model.reveal("target")
        #expect(model.expandedIDs == ["root", "first", "nested"])
        #expect(model.visibleRows.map(\.id) == ["root", "first", "nested", "target", "second"])

        // Revealing another branch inserts only its newly visible descendants while retaining
        // the already materialized prefix and preorder.
        model.reveal("sibling")
        #expect(model.expandedIDs == ["root", "first", "nested", "second"])
        #expect(
            model.visibleRows.map(\.id)
                == ["root", "first", "nested", "target", "second", "sibling"]
        )
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

    @Test
    func visibleFocusTraversalRespectsCollapsedBranchesRootsAndBoundaries() throws {
        let tree = try PreparedTree(
            roots: [
                TestNode(
                    id: "root",
                    children: [
                        TestNode(
                            id: "folder",
                            children: [TestNode(id: "hidden")]
                        ),
                        TestNode(id: "sibling")
                    ]
                ),
                TestNode(id: "tail")
            ],
            children: \.children
        )
        let model = FileTreeModel(
            tree,
            initialExpansion: .identifiers(["root"])
        )

        #expect(model.visibleRows.map(\.id) == ["root", "folder", "sibling", "tail"])
        #expect(model.focusNextItem() == "root")
        #expect(model.focusNextItem() == "folder")
        #expect(model.focusNextItem() == "sibling")
        #expect(model.focusPreviousItem() == "folder")
        #expect(model.focusParentItem() == "root")
        #expect(model.focusPreviousItem() == "root")
        #expect(model.focusLastItem() == "tail")
        let boundaryRevealSequence = try #require(model.revealRequest?.sequence)
        #expect(model.focusNextItem() == "tail")
        #expect(model.revealRequest?.sequence == boundaryRevealSequence + 1)
        #expect(model.revealRequest?.id == "tail")
        #expect(model.revealRequest?.focus == true)

        model.expand("folder")
        model.focus("folder")
        #expect(model.focusNextItem() == "hidden")
        #expect(model.selection.isEmpty)
    }

    @Test
    func focusNearestRecoversHiddenRemovedAndEmptyFocus() throws {
        let tree = try PreparedTree(
            roots: [
                TestNode(
                    id: "root",
                    children: [
                        TestNode(
                            id: "folder",
                            children: [TestNode(id: "focused")]
                        ),
                        TestNode(id: "other")
                    ]
                )
            ],
            children: \.children
        )
        let model = FileTreeModel(tree, initialExpansion: .expanded)

        model.focus("focused")
        model.collapse("folder")
        #expect(model.focusNearestItem() == "folder")

        model.expand("folder")
        model.focus("focused")
        let replacement = try PreparedTree(
            roots: [
                TestNode(
                    id: "root",
                    children: [TestNode(id: "other"), TestNode(id: "tail")]
                )
            ],
            children: \.children
        )
        model.reset(replacement)

        #expect(model.focusedID == nil)
        #expect(model.focusNearestItem(to: "focused") == "tail")

        let emptyTree = try PreparedTree<TestNode>(roots: [], children: \.children)
        model.reset(emptyTree)
        #expect(model.focusFirstItem() == nil)
        #expect(model.focusNearestItem() == nil)
        #expect(model.focusedID == nil)
    }

    @Test
    func navigationFollowsTheActiveSearchProjection() throws {
        let model = FileTreeModel(try makeSearchTree())
        model.openSearch(initialQuery: "logger")

        #expect(
            model.visibleRows.map(\.id)
                == ["Sources/", "Sources/Support/", "Sources/Support/Logger.swift"]
        )
        #expect(model.focusFirstItem() == "Sources/")
        #expect(model.focusNextItem() == "Sources/Support/")
        #expect(model.focusLastItem() == "Sources/Support/Logger.swift")
        #expect(model.focusParentItem() == "Sources/Support/")
    }

    @Test
    func scrollAndRevealCanPreserveSelectionAndFocusIndependently() throws {
        let tree = try PreparedTree(
            roots: [
                TestNode(
                    id: "root",
                    children: [TestNode(id: "selected"), TestNode(id: "target")]
                )
            ],
            children: \.children
        )
        let model = FileTreeModel(tree, initialSelection: ["selected"])

        model.scrollTo("target", position: .center, focus: false)
        #expect(model.selection == ["selected"])
        #expect(model.focusedID == "selected")
        #expect(model.expandedIDs == ["root"])

        model.scrollTo("target")
        #expect(model.selection == ["selected"])
        #expect(model.focusedID == "target")

        model.reveal("selected", select: false, focus: false)
        #expect(model.selection == ["selected"])
        #expect(model.focusedID == "target")
    }

    @Test
    func revealRejectsTargetsExcludedByActiveSearch() throws {
        let model = FileTreeModel(
            try makeSearchTree(),
            initialSelection: ["README.md"]
        )
        model.openSearch(initialQuery: "logger")
        let focusedID = model.focusedID
        let selection = model.selection
        let revision = model.revision

        model.scrollTo("Tests/AppTests.swift")
        model.reveal("Tests/AppTests.swift")

        #expect(model.visibleRow(for: "Tests/AppTests.swift") == nil)
        #expect(model.focusedID == focusedID)
        #expect(model.selection == selection)
        #expect(model.revealRequest == nil)
        #expect(model.revision == revision)
    }

    @Test
    func scopedInteractionPublishersIgnoreUnrelatedRevisions() throws {
        let tree = try PreparedTree(
            roots: [TestNode(id: "root", children: [TestNode(id: "child")])],
            children: \.children
        )
        let model = FileTreeModel(tree)
        var selectionValues: [Set<String>] = []
        var focusValues: [String?] = []
        let selectionSubscription = model.selectionChanges.sink {
            selectionValues.append($0)
        }
        let focusSubscription = model.focusChanges.sink {
            focusValues.append($0)
        }

        model.expand("root")
        model.focus("root")
        model.focus("root")
        model.select("child")
        model.collapse("root")

        #expect(selectionValues == [[], ["child"]])
        #expect(focusValues == [nil, "root", "child"])
        _ = selectionSubscription
        _ = focusSubscription
    }
}
