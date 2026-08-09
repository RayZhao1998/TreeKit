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
}
