import Combine
import Testing
@testable import TreeKit

@MainActor
struct FileTreeDragDropTests {
    @Test
    func capturesCurrentMultiSelectionAndRemovesDescendantSources() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: ["Folder/Child.swift", "Folder/Nested/Leaf.swift", "Other.swift"],
            initialSelection: ["Folder/", "Folder/Child.swift", "Folder/Nested/Leaf.swift"]
        )

        let session = try model.makeDragSession(startingAt: "Folder/")
        #expect(session.sourcePaths.map(\.path) == ["Folder/"])

        model.setSelection(["Folder/Child.swift", "Other.swift"])
        let multiSession = try model.makeDragSession(startingAt: "Other.swift")
        #expect(multiSession.sourcePaths.map(\.path) == ["Folder/Child.swift", "Other.swift"])
    }

    @Test
    func reordersMultipleInputOrderSiblingsBeforeAndAfter() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: ["A.swift", "B.swift", "C.swift", "D.swift"],
            options: .init(sort: .inputOrder),
            initialSelection: ["A.swift", "C.swift"]
        )
        let session = try model.makeDragSession(startingAt: "A.swift")

        let beforeTarget = FileTreeDropTarget(
            path: try FileTreePath(path: "B.swift"),
            position: .before
        )
        let event = try model.performDrop(session, target: beforeTarget)
        #expect(model.preparedTree.rootIDs == ["A.swift", "C.swift", "B.swift", "D.swift"])
        #expect(event.moves.map(\.sourcePath.path) == ["A.swift", "C.swift"])
        #expect(event.moves.map(\.destinationPath.path) == ["A.swift", "C.swift"])

        model.select("B.swift")
        let secondSession = try model.makeDragSession(startingAt: "B.swift")
        let afterTarget = FileTreeDropTarget(
            path: try FileTreePath(path: "D.swift"),
            position: .after
        )
        try model.performDrop(secondSession, target: afterTarget)
        #expect(model.preparedTree.rootIDs == ["A.swift", "C.swift", "D.swift", "B.swift"])
    }

    @Test
    func movesAcrossDirectoriesAndIntoCollapsedTargets() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: ["Source/One.swift", "Source/Two.swift", "Target/Existing.swift"],
            options: .init(sort: .inputOrder),
            initialExpansion: .identifiers(["Source/"]),
            initialSelection: ["Source/One.swift"]
        )
        let session = try model.makeDragSession(startingAt: "Source/One.swift")
        let target = FileTreeDropTarget(
            path: try FileTreePath(path: "Target/", kind: .directory),
            position: .inside
        )

        let event = try model.performDrop(session, target: target)

        #expect(model.preparedTree.contains("Target/One.swift"))
        #expect(!model.preparedTree.contains("Source/One.swift"))
        #expect(model.selection == ["Target/One.swift"])
        #expect(!model.expandedIDs.contains("Target/"))
        #expect(event.proposal.target.destinationDirectoryPath == "Target/")
        #expect(event.moves == [
            FileTreeDropMove(
                sourcePath: try FileTreePath(path: "Source/One.swift"),
                destinationPath: try FileTreePath(path: "Target/One.swift")
            )
        ])
    }

    @Test
    func flattenedBeforeTargetUsesItsRenderedParent() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: ["src/lib/core/File.swift", "Other.swift"],
            options: .init(sort: .inputOrder, flattenEmptyDirectories: true),
            initialSelection: ["Other.swift"]
        )
        #expect(model.visibleRows.map(\.id) == ["src/lib/core/", "Other.swift"])

        let target = try #require(
            model.renderedDropTarget(for: "src/lib/core/", position: .before)
        )
        #expect(target.path?.id == "src/")
        #expect(target.destinationDirectoryPath == nil)

        let session = try model.makeDragSession(startingAt: "Other.swift")
        try model.performDrop(session, target: target)
        #expect(model.preparedTree.rootIDs == ["Other.swift", "src/"])
    }

    @Test
    func rejectsSelfCyclesDescendantsAndDuplicateDestinations() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: [
                "Folder/Nested/File.swift",
                "Destination/File.swift",
                "Destination/Loose.swift",
                "Loose.swift"
            ]
        )

        let folderSession = try model.makeDragSession(startingAt: "Folder/")
        #expect(throws: FileTreeDragDropError.selfDrop(path: "Folder/")) {
            try model.performDrop(
                folderSession,
                target: .init(
                    path: try FileTreePath(path: "Folder/", kind: .directory),
                    position: .inside
                )
            )
        }
        #expect(throws: FileTreeDragDropError.moveIntoDescendant(
            source: "Folder/",
            destination: "Folder/Nested/"
        )) {
            try model.performDrop(
                folderSession,
                target: .init(
                    path: try FileTreePath(path: "Folder/Nested/", kind: .directory),
                    position: .inside
                )
            )
        }

        let looseSession = try model.makeDragSession(startingAt: "Loose.swift")
        #expect(throws: FileTreeDragDropError.duplicateDestination(path: "Destination/Loose.swift")) {
            try model.performDrop(
                looseSession,
                target: .init(
                    path: try FileTreePath(path: "Destination/File.swift"),
                    position: .before
                )
            )
        }
    }

    @Test
    func policyAndTypedCallbacksReportCompletedAndFailedDrops() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: ["Allowed.swift", "Protected.swift", "Target/"],
            options: .init(sort: .inputOrder)
        )
        var completed: [FileTreeDropEvent] = []
        var failed: [FileTreeDropFailure] = []
        var stream: [FileTreeDragDropEvent] = []
        let subscription = model.dragDropEvents.sink { stream.append($0) }
        model.configureDragAndDrop(.init(
            canDrag: { !$0.contains(where: { $0.path == "Protected.swift" }) },
            canDrop: { !$0.destinationPaths.contains(where: { $0.name == "Blocked.swift" }) },
            onDropComplete: { completed.append($0) },
            onDropError: { failed.append($0) },
            openOnDropDelay: 0.15
        ))

        #expect(throws: FileTreeDragDropError.dragRejected(paths: ["Protected.swift"])) {
            try model.makeDragSession(startingAt: "Protected.swift")
        }

        let allowed = try model.makeDragSession(startingAt: "Allowed.swift")
        let successTarget = FileTreeDropTarget(
            path: try FileTreePath(path: "Target/", kind: .directory),
            position: .inside
        )
        let success = try model.performDrop(allowed, target: successTarget)
        #expect(completed == [success])
        #expect(stream == [.completed(success)])
        #expect(model.dragDropOpenDelay == 0.15)

        model.configureDragAndDrop(.init(
            canDrop: { _ in false },
            onDropError: { failed.append($0) }
        ))
        let moved = try model.makeDragSession(startingAt: "Target/Allowed.swift")
        let failureTarget = FileTreeDropTarget(path: nil, position: .inside)
        #expect(throws: FileTreeDragDropError.dropRejected) {
            try model.performDrop(moved, target: failureTarget)
        }
        #expect(failed.last?.error == .dropRejected)
        #expect(stream.last == .failed(try #require(failed.last)))
        _ = subscription
    }
}
