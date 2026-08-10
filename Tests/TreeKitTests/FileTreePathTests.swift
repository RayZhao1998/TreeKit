import Testing
@testable import TreeKit

struct FileTreePathTests {
    @Test
    func normalizesPathsAndCollapsesCanonicalDuplicates() throws {
        let tree = try prepareFileTree(
            paths: [
                "Sources//./TreeKit/FileTree.swift",
                "Sources/TreeKit/FileTree.swift",
                "./README.md",
                "Empty//./"
            ],
            options: .init(sort: .inputOrder)
        )

        #expect(
            tree.nodes.map(\.id) == [
                "Sources/",
                "Sources/TreeKit/",
                "Sources/TreeKit/FileTree.swift",
                "README.md",
                "Empty/"
            ]
        )
        #expect(tree.count == 5)
        #expect(tree.node(for: "Sources/")?.name == "Sources")
        #expect(tree.node(for: "Sources/")?.kind == .directory)
        #expect(tree.node(for: "README.md")?.kind == .file)
    }

    @Test
    func synthesizesImplicitAncestorDirectories() throws {
        let tree = try prepareFileTree(paths: ["Sources/TreeKit/FileTreePath.swift"])

        #expect(tree.roots.map(\.id) == ["Sources/"])
        #expect(tree.children(of: "Sources/").map(\.id) == ["Sources/TreeKit/"])
        #expect(
            tree.children(of: "Sources/TreeKit/").map(\.id)
                == ["Sources/TreeKit/FileTreePath.swift"]
        )
        #expect(
            tree.ancestorIDs(of: "Sources/TreeKit/FileTreePath.swift")
                == ["Sources/", "Sources/TreeKit/"]
        )
    }

    @Test
    func appliesEachSiblingSortPolicyDeterministically() throws {
        let paths = [
            "z.txt",
            "beta/file.swift",
            "a.txt",
            "alpha/file.swift"
        ]

        let inputOrder = try prepareFileTree(
            paths: paths,
            options: .init(sort: .inputOrder)
        )
        let lexicographic = try prepareFileTree(
            paths: paths,
            options: .init(sort: .lexicographic)
        )
        let foldersFirst = try prepareFileTree(
            paths: paths,
            options: .init(sort: .foldersFirst)
        )

        #expect(inputOrder.roots.map(\.id) == ["z.txt", "beta/", "a.txt", "alpha/"])
        #expect(lexicographic.roots.map(\.id) == ["a.txt", "alpha/", "beta/", "z.txt"])
        #expect(foldersFirst.roots.map(\.id) == ["alpha/", "beta/", "a.txt", "z.txt"])
    }

    @Test
    func rejectsEmptyAbsoluteAndParentTraversingPaths() {
        #expect(throws: FileTreePathError.emptyPath) {
            try prepareFileTree(paths: ["./"])
        }
        #expect(throws: FileTreePathError.absolutePath(path: "/Sources/App.swift")) {
            try prepareFileTree(paths: ["/Sources/App.swift"])
        }
        #expect(throws: FileTreePathError.parentTraversal(path: "Sources/../README.md")) {
            try prepareFileTree(paths: ["Sources/../README.md"])
        }
    }

    @Test
    func rejectsFileDirectoryIdentityCollisionsInEitherInputOrder() {
        #expect(
            throws: FileTreePathError.kindConflict(
                path: "Sources",
                existing: .file,
                incoming: .directory
            )
        ) {
            try prepareFileTree(paths: ["Sources", "Sources/File.swift"])
        }

        #expect(
            throws: FileTreePathError.kindConflict(
                path: "Sources",
                existing: .directory,
                incoming: .file
            )
        ) {
            try prepareFileTree(paths: ["Sources/File.swift", "Sources"])
        }
    }
}

@MainActor
struct FileTreePathModelTests {
    @Test
    func createsAModelDirectlyFromPaths() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: ["Sources/App.swift", "README.md"],
            initialExpansion: .expanded,
            initialSelection: ["README.md"]
        )

        #expect(model.preparedTree.count == 3)
        #expect(model.expandedIDs == ["Sources/"])
        #expect(model.selection == ["README.md"])
        #expect(model.visibleRows.map(\.id) == ["Sources/", "Sources/App.swift", "README.md"])
    }

    @Test
    func addAndRemoveUpdateCollapsedBranchesAndPruneRemovedState() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: ["Root/Existing.swift"],
            initialSelection: ["Root/Existing.swift"]
        )
        var events: [FileTreePathMutationEvent] = []
        let subscription = model.onMutation { events.append($0) }
        let initialRevision = model.revision

        try model.add("Root//./New.swift")

        #expect(model.revision == initialRevision + 1)
        #expect(model.preparedTree.node(for: "Root/New.swift") != nil)
        #expect(model.visibleRows.map(\.id) == ["Root/"])
        #expect(model.selection == ["Root/Existing.swift"])

        model.select("Root/New.swift")
        try model.remove("Root/New.swift")

        #expect(model.preparedTree.node(for: "Root/New.swift") == nil)
        #expect(model.selection.isEmpty)
        #expect(model.focusedID == nil)
        #expect(
            events == [
                .add(path: try FileTreePath(path: "Root/New.swift")),
                .remove(path: try FileTreePath(path: "Root/New.swift"))
            ]
        )
        _ = subscription
    }

    @Test
    func removingTheLastChildRetainsAnExplicitDirectory() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: ["Root/", "Root/Child.swift"]
        )

        try model.remove("Root/Child.swift")

        #expect(model.preparedTree.nodes.map(\.id) == ["Root/"])
        #expect(model.preparedTree.node(for: "Root/")?.kind == .directory)
    }

    @Test
    func rootAddAndDirectoryRemovalAreSingleStateTransactions() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: ["Root/Folder/Selected.swift", "Root/Keep.swift"],
            initialExpansion: .identifiers(["Root/", "Root/Folder/"]),
            initialSelection: ["Root/Folder/Selected.swift"]
        )

        try model.add("RootFile.swift")
        #expect(model.preparedTree.roots.map(\.id) == ["Root/", "RootFile.swift"])

        try model.remove("Root/Folder/")

        #expect(model.preparedTree.node(for: "Root/Folder/") == nil)
        #expect(model.preparedTree.node(for: "Root/Folder/Selected.swift") == nil)
        #expect(model.selection.isEmpty)
        #expect(model.focusedID == nil)
        #expect(model.expandedIDs == ["Root/"])
        #expect(model.visibleRows.map(\.id) == ["Root/", "Root/Keep.swift", "RootFile.swift"])
    }

    @Test
    func movingAnImplicitDirectoryRemapsInteractionState() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: [
                "Source/Folder/Target.swift",
                "Source/Keep.swift",
                "Destination/Existing.swift"
            ],
            initialExpansion: .identifiers(["Source/", "Source/Folder/", "Destination/"]),
            initialSelection: ["Source/Folder/Target.swift"]
        )
        var events: [FileTreePathMutationEvent] = []
        let subscription = model.onMutation(.move) { events.append($0) }

        try model.move("Source/Folder/", to: "Destination/Folder/")

        #expect(model.preparedTree.node(for: "Source/Folder/") == nil)
        #expect(model.preparedTree.node(for: "Destination/Folder/Target.swift") != nil)
        #expect(model.selection == ["Destination/Folder/Target.swift"])
        #expect(model.focusedID == "Destination/Folder/Target.swift")
        #expect(model.expandedIDs.contains("Source/"))
        #expect(model.expandedIDs.contains("Destination/"))
        #expect(model.expandedIDs.contains("Destination/Folder/"))
        #expect(
            events == [
                .move(
                    from: try FileTreePath(path: "Source/Folder/"),
                    to: try FileTreePath(path: "Destination/Folder/")
                )
            ]
        )
        _ = subscription
    }

    @Test
    func rejectsInvalidMutationsWithoutPublishingPartialState() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: ["Root/Existing.swift", "Root/Folder/Child.swift"]
        )
        var events: [FileTreePathMutationEvent] = []
        let subscription = model.onMutation { events.append($0) }
        let initialRevision = model.revision
        let initialIDs = model.preparedTree.nodes.map(\.id)

        #expect(
            throws: FileTreePathMutationError.duplicateIdentity(
                path: "Root/Existing.swift"
            )
        ) {
            try model.add("Root/Existing.swift")
        }
        #expect(
            throws: FileTreePathMutationError.identityNotFound(path: "Missing.swift")
        ) {
            try model.remove("Missing.swift")
        }
        #expect(
            throws: FileTreePathError.kindConflict(
                path: "Root",
                existing: .directory,
                incoming: .file
            )
        ) {
            try model.add("Root")
        }
        #expect(
            throws: FileTreePathMutationError.invalidDestination(path: "Missing/")
        ) {
            try model.move("Root/Existing.swift", to: "Missing/Existing.swift")
        }
        #expect(
            throws: FileTreePathMutationError.kindMismatch(
                path: "Moved/",
                expected: .file,
                actual: .directory
            )
        ) {
            try model.move("Root/Existing.swift", to: "Moved/")
        }
        #expect(
            throws: FileTreePathMutationError.moveIntoDescendant(
                source: "Root/",
                destination: "Root/New/Nested/"
            )
        ) {
            try model.move("Root/", to: "Root/New/Nested/")
        }
        #expect(
            throws: FileTreePathMutationError.moveIntoDescendant(
                source: "Root/",
                destination: "Root/New/"
            )
        ) {
            try model.batch([
                .add(path: "Temporary.swift"),
                .move(from: "Root/", to: "Root/New/")
            ])
        }
        #expect(throws: FileTreePathError.parentTraversal(path: "../Invalid.swift")) {
            try model.resetPaths(["../Invalid.swift"])
        }

        #expect(model.revision == initialRevision)
        #expect(model.preparedTree.nodes.map(\.id) == initialIDs)
        #expect(model.preparedTree.node(for: "Temporary.swift") == nil)
        #expect(events.isEmpty)
        _ = subscription
    }

    @Test
    func batchPublishesOneCanonicalTransaction() throws {
        let model = try FileTreeModel<FileTreePath>(paths: ["Root/Old.swift"])
        var events: [FileTreePathMutationEvent] = []
        var countsObservedByEvent: [Int] = []
        let subscription = model.onMutation { event in
            events.append(event)
            countsObservedByEvent.append(model.preparedTree.count)
        }
        let initialRevision = model.revision

        try model.batch([
            .add(path: "Root//New.swift"),
            .move(from: "Root/New.swift", to: "Root/Renamed.swift"),
            .remove(path: "Root/Old.swift")
        ])

        #expect(model.revision == initialRevision + 1)
        #expect(model.preparedTree.nodes.map(\.id) == ["Root/", "Root/Renamed.swift"])
        #expect(countsObservedByEvent == [2])
        #expect(
            events == [
                .batch([
                    .add(path: try FileTreePath(path: "Root/New.swift")),
                    .move(
                        from: try FileTreePath(path: "Root/New.swift"),
                        to: try FileTreePath(path: "Root/Renamed.swift")
                    ),
                    .remove(path: try FileTreePath(path: "Root/Old.swift"))
                ])
            ]
        )
        _ = subscription
    }

    @Test
    func resetPathsPreservesRetainedStateAndEmitsExplicitInputs() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: ["Folder/Keep.swift", "Folder/Remove.swift"],
            initialExpansion: .identifiers(["Folder/"]),
            initialSelection: ["Folder/Keep.swift"]
        )
        var events: [FileTreePathMutationEvent] = []
        let subscription = model.onMutation(.reset) { events.append($0) }

        try model.resetPaths(["Folder/Keep.swift", "New.swift"])

        #expect(model.expandedIDs == ["Folder/"])
        #expect(model.selection == ["Folder/Keep.swift"])
        #expect(model.focusedID == "Folder/Keep.swift")
        #expect(model.preparedTree.node(for: "Folder/Remove.swift") == nil)
        #expect(
            events == [
                .reset(paths: [
                    try FileTreePath(path: "Folder/Keep.swift"),
                    try FileTreePath(path: "New.swift")
                ])
            ]
        )
        _ = subscription
    }

    @Test
    func activeSearchRefreshesAfterMutations() throws {
        let model = try FileTreeModel<FileTreePath>(paths: ["Root/Existing.swift"])
        model.openSearch(initialQuery: "new")
        #expect(model.visibleRows.isEmpty)

        try model.add("Root/New.swift")
        #expect(model.matchingIDs == ["Root/New.swift"])
        #expect(model.visibleRows.map(\.id) == ["Root/", "Root/New.swift"])

        try model.remove("Root/New.swift")
        #expect(model.matchingIDs.isEmpty)
        #expect(model.visibleRows.isEmpty)
    }
}
