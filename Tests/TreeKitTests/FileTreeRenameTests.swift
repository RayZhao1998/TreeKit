import AppKit
import Combine
import Foundation
import Testing
@testable import TreeKit

@MainActor
struct FileTreeRenameTests {
    @Test
    func commitsAFileRenameThroughTheSharedMutationAndEmitsTypedState() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: ["Sources/Feature.swift", "Sources/Other.swift"],
            initialExpansion: .identifiers(["Sources/"]),
            initialSelection: ["Sources/Feature.swift"]
        )
        var renameEvents: [FileTreeRenameEvent] = []
        var mutationEvents: [FileTreePathMutationEvent] = []
        let renameSubscription = model.renameEvents.sink { renameEvents.append($0) }
        let mutationSubscription = model.mutationEvents.sink { mutationEvents.append($0) }

        try model.startRenaming("Sources/Feature.swift")
        #expect(model.renamingID == "Sources/Feature.swift")
        #expect(model.focusedID == "Sources/Feature.swift")

        try model.commitRenaming("Renamed.swift")

        #expect(model.renamingID == nil)
        #expect(model.renameError == nil)
        #expect(model.preparedTree.contains("Sources/Renamed.swift"))
        #expect(!model.preparedTree.contains("Sources/Feature.swift"))
        #expect(model.selection == ["Sources/Renamed.swift"])
        #expect(model.focusedID == "Sources/Renamed.swift")
        #expect(model.expandedIDs == ["Sources/"])
        #expect(renameEvents == [
            FileTreeRenameEvent(
                sourcePath: try FileTreePath(path: "Sources/Feature.swift"),
                destinationPath: try FileTreePath(path: "Sources/Renamed.swift"),
                kind: .file
            )
        ])
        #expect(mutationEvents == [
            .move(
                from: try FileTreePath(path: "Sources/Feature.swift"),
                to: try FileTreePath(path: "Sources/Renamed.swift")
            )
        ])

        _ = renameSubscription
        _ = mutationSubscription
    }

    @Test
    func directoryRenameRemapsDescendantSelectionExpansionAndFocus() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: ["Sources/Feature/Nested/File.swift"],
            initialExpansion: .identifiers(["Sources/", "Sources/Feature/", "Sources/Feature/Nested/"]),
            initialSelection: ["Sources/Feature/Nested/File.swift"]
        )
        model.focus("Sources/Feature/Nested/File.swift")

        try model.startRenaming("Sources/Feature/")
        try model.commitRenaming("Renamed")

        #expect(model.preparedTree.contains("Sources/Renamed/"))
        #expect(model.preparedTree.contains("Sources/Renamed/Nested/File.swift"))
        #expect(model.selection == ["Sources/Renamed/"])
        #expect(model.focusedID == "Sources/Renamed/")
        #expect(model.expandedIDs.contains("Sources/Renamed/"))
        #expect(model.expandedIDs.contains("Sources/Renamed/Nested/"))
    }

    @Test
    func policyRejectionReportsAnErrorWithoutChangingTheTree() throws {
        let model = try FileTreeModel<FileTreePath>(paths: ["Protected.swift", "Editable.swift"])
        var errors: [FileTreeRenameError] = []
        model.configureRenaming(.init(
            canRename: { $0.path != "Protected.swift" },
            onError: { errors.append($0) }
        ))

        #expect(throws: FileTreeRenameError.policyRejected(path: "Protected.swift")) {
            try model.startRenaming("Protected.swift")
        }
        #expect(model.renamingID == nil)
        #expect(model.preparedTree.preorderIDs == ["Editable.swift", "Protected.swift"])
        #expect(model.renameError == .policyRejected(path: "Protected.swift"))
        #expect(errors == [.policyRejected(path: "Protected.swift")])
    }

    @Test(arguments: ["", "   ", ".", "..", "Nested/Name", "Nested\\Name", "bad\nname"])
    func invalidComponentsKeepTheRenameSessionActive(_ proposedName: String) throws {
        let model = try FileTreeModel<FileTreePath>(paths: ["Original.swift"])
        try model.startRenaming("Original.swift")

        #expect(throws: FileTreeRenameError.self) {
            try model.commitRenaming(proposedName)
        }
        #expect(model.renamingID == "Original.swift")
        #expect(model.preparedTree.contains("Original.swift"))
    }

    @Test
    func duplicateDestinationIsVisibleAndCancelRestoresFocus() throws {
        let model = try FileTreeModel<FileTreePath>(paths: ["First.swift", "Second.swift"])
        try model.startRenaming("First.swift")

        #expect(throws: FileTreeRenameError.duplicateDestination(path: "Second.swift")) {
            try model.commitRenaming("Second.swift")
        }
        #expect(model.renamingID == "First.swift")
        #expect(model.renameError == .duplicateDestination(path: "Second.swift"))

        model.cancelRenaming()
        #expect(model.renamingID == nil)
        #expect(model.renameError == nil)
        #expect(model.focusedID == "First.swift")
        #expect(model.preparedTree.contains("First.swift"))
    }

    @Test
    func appKitProvidesKeyboardCommitAndCancelForTheSharedSession() throws {
        let model = try FileTreeModel<FileTreePath>(paths: ["First.swift", "Second.swift"])
        let view = FileTreeView(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.layoutSubtreeIfNeeded()

        try model.startRenaming("First.swift")
        view.layoutSubtreeIfNeeded()
        let commitField = try #require(findEditableTextField(in: view))
        commitField.stringValue = "Committed.swift"
        _ = commitField.sendAction(commitField.action, to: commitField.target)
        #expect(model.preparedTree.contains("Committed.swift"))
        #expect(model.renamingID == nil)

        try model.startRenaming("Second.swift")
        view.layoutSubtreeIfNeeded()
        let cancelField = try #require(findEditableTextField(in: view))
        cancelField.stringValue = "invalid/name"
        _ = cancelField.sendAction(cancelField.action, to: cancelField.target)
        #expect(model.renamingID == "Second.swift")
        #expect(cancelField.stringValue == "invalid/name")

        cancelField.stringValue = "Cancelled.swift"
        cancelField.cancelOperation(nil)
        #expect(model.preparedTree.contains("Second.swift"))
        #expect(!model.preparedTree.contains("Cancelled.swift"))
        #expect(model.renamingID == nil)

        _ = window
    }

    @Test
    func appKitCancelsRenameWhenTheEditedRowLeavesTheViewport() async throws {
        let paths = (0..<80).map { String(format: "File-%03d.swift", $0) }
        let model = try FileTreeModel<FileTreePath>(paths: paths, options: .init(sort: .inputOrder))
        let view = FileTreeView(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 72),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let outlineView = try #require(findOutlineView(in: view))

        try model.startRenaming(paths[0])
        view.layoutSubtreeIfNeeded()
        #expect(findEditableTextField(in: view) != nil)

        outlineView.scrollRowToVisible(paths.count - 1)
        view.layoutSubtreeIfNeeded()
        await Task.yield()
        await Task.yield()

        #expect(model.renamingID == nil)
        #expect(model.preparedTree.contains(paths[0]))
        _ = window
    }

    private func findEditableTextField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable, !field.isHidden {
            return field
        }
        for child in view.subviews {
            if let field = findEditableTextField(in: child) { return field }
        }
        return nil
    }

    private func findOutlineView(in view: NSView) -> NSOutlineView? {
        if let outlineView = view as? NSOutlineView { return outlineView }
        for child in view.subviews {
            if let outlineView = findOutlineView(in: child) { return outlineView }
        }
        return nil
    }
}
