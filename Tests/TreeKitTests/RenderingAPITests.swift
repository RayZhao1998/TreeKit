#if canImport(AppKit)
import AppKit
import Combine
import SwiftUI
import Testing
@testable import TreeKit

private enum RenderingLazyFailure: LocalizedError, Sendable {
    case offline

    var errorDescription: String? { "The Demo provider is offline." }
}

private actor RenderingLazyRootProbe {
    private let root: FileTreePath
    private var calls = 0

    init(root: FileTreePath) {
        self.root = root
    }

    func loadRoots() throws -> [FileTreePath] {
        calls += 1
        if calls == 1 { throw RenderingLazyFailure.offline }
        return [root]
    }

    func callCount() -> Int { calls }
}

private actor RenderingLazyChildProbe {
    private let root: FileTreePath
    private let child: FileTreePath
    private var childCalls = 0

    init(root: FileTreePath, child: FileTreePath) {
        self.root = root
        self.child = child
    }

    func loadRoots() -> [FileTreePath] { [root] }

    func loadChildren() throws -> [FileTreePath] {
        childCalls += 1
        if childCalls == 1 { throw RenderingLazyFailure.offline }
        return [child]
    }

    func callCount() -> Int { childCalls }
}

@MainActor
struct RenderingAPITests {
    @Test
    func constructsDefaultAndCustomSwiftUIInterfaces() throws {
        let model = try FileTreeModel<FileTreePath>(paths: ["Sources/App.swift"])

        let _: FileTree<FileTreePath, FileTreeDefaultRow> = FileTree(model: model)
        let _: FileTree<FileTreePath, FileTreeDefaultRow> = FileTree(model: model) { _ in }
        let _: FileTree<FileTreePath, Text> = FileTree(model: model) { node, _ in
            Text(node.name)
        }
    }

    @Test
    func nativeViewCanReplaceItsStableModel() throws {
        let original = try FileTreeModel<FileTreePath>(paths: ["Original.swift"])
        let replacement = try FileTreeModel<FileTreePath>(paths: ["Replacement.swift"])
        let view = FileTreeView(model: original)

        #expect(view.model === original)
        try original.startRenaming("Original.swift")
        #expect(original.renamingID == "Original.swift")
        view.model = replacement
        #expect(view.model === replacement)
        #expect(original.renamingID == nil)

        view.reloadRows()
        _ = view.focusTree()
    }

    @Test
    func appKitDefaultRootFailureCanRetryWithoutSyntheticRows() async throws {
        let root = try FileTreePath(path: "Root/")
        let probe = RenderingLazyRootProbe(root: root)
        let provider = FileTreeChildrenProvider<FileTreePath>(
            roots: { try await probe.loadRoots() },
            mightHaveChildren: { $0.kind == .directory },
            children: { _ in [] }
        )
        let model = FileTreeModel(childrenProvider: provider)
        let view = FileTreeView(model: model)
        let outlineView = try #require(findOutlineView(in: view))

        await #expect(throws: RenderingLazyFailure.offline) {
            try await model.loadRoots()
        }
        #expect(outlineView.numberOfRows == 0)
        let retryButton = try #require(findVisibleButton(titled: "Retry", in: view))
        #expect(retryButton.accessibilityLabel() == "Retry loading file tree")

        retryButton.performClick(nil)
        for _ in 0..<256 where model.rootLoadState != .loaded {
            await Task.yield()
        }

        #expect(model.rootLoadState == .loaded)
        #expect(outlineView.numberOfRows == 1)
        #expect(await probe.callCount() == 2)
    }

    @Test
    func appKitDoubleClickRetriesAFailedExpandedBranch() async throws {
        let root = try FileTreePath(path: "Root/")
        let child = try FileTreePath(path: "Root/Child.swift")
        let probe = RenderingLazyChildProbe(root: root, child: child)
        let provider = FileTreeChildrenProvider<FileTreePath>(
            roots: { await probe.loadRoots() },
            mightHaveChildren: { $0.kind == .directory },
            children: { _ in try await probe.loadChildren() }
        )
        let model = FileTreeModel(childrenProvider: provider)
        var configuration = FileTreeConfiguration()
        configuration.expandsBranchesOnDoubleClick = true
        let view = FileTreeView(model: model, configuration: configuration)
        _ = try await model.loadRoots()
        model.expand(root.id)

        await #expect(throws: RenderingLazyFailure.offline) {
            try await model.loadChildren(of: root.id)
        }
        #expect(model.expandedIDs == [root.id])
        #expect(model.childrenLoadState(for: root.id).failure != nil)

        view.handleDoubleClick(of: root.id)
        for _ in 0..<256 where model.childrenLoadState(for: root.id) != .loaded {
            await Task.yield()
        }

        #expect(model.childrenLoadState(for: root.id) == .loaded)
        #expect(model.expandedIDs == [root.id])
        #expect(model.preparedTree.contains(child.id))
        #expect(await probe.callCount() == 2)
    }

    @Test
    func appKitCancelsRenameWhenTheViewDetachesFromItsWindow() throws {
        let model = try FileTreeModel<FileTreePath>(paths: ["Original.swift"])
        let view = FileTreeView(model: model)
        let container = NSView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        container.addSubview(view)
        try model.startRenaming("Original.swift")
        #expect(model.renamingID == "Original.swift")

        view.removeFromSuperview()

        #expect(model.renamingID == nil)
        _ = window
    }

    @Test
    func deferredRendererTeardownDoesNotCancelAReplacementRename() async throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: ["First.swift", "Second.swift"]
        )
        try model.startRenaming("First.swift")
        #expect(model.renamingID == "First.swift")
        let staleRevision = model.renameRevision
        let deferredCleanup = Task { @MainActor in
            model.cancelActiveRename(ifRevision: staleRevision)
        }

        try model.startRenaming("Second.swift")
        await deferredCleanup.value

        #expect(model.renamingID == "Second.swift")
    }

    @Test
    func appKitReplaysExpansionRequestedForAHiddenDescendant() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: ["Root/Folder/File.swift"],
            options: .init(sort: .inputOrder)
        )
        let view = FileTreeView(model: model)
        let outlineView = try #require(findOutlineView(in: view))

        #expect(outlineView.numberOfRows == 1)
        model.expand("Root/Folder/")
        #expect(outlineView.numberOfRows == 1)

        model.expand("Root/")
        #expect(outlineView.numberOfRows == 3)

        model.collapse("Root/")
        model.collapse("Root/Folder/")
        model.expand("Root/")
        #expect(outlineView.numberOfRows == 2)
    }

    @Test
    func appKitEnforcesSingleAndNonemptySelectionPolicies() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: ["First.swift", "Second.swift"],
            initialSelection: ["First.swift", "Second.swift"]
        )
        let configuration = FileTreeConfiguration(
            selectionMode: .single,
            allowsEmptySelection: false
        )
        let view = FileTreeView(model: model, configuration: configuration)

        #expect(model.selection == ["First.swift"])
        model.deselectAll()
        #expect(model.selection == ["First.swift"])
        _ = view
    }

    @Test
    func appKitPendingInitialSelectionReplacesNonemptyFallback() async throws {
        let root = try FileTreePath(path: "Root/")
        let initiallySelectedChild = try FileTreePath(path: "Root/Initial.swift")
        let provider = FileTreeChildrenProvider<FileTreePath>(
            roots: { [root] },
            mightHaveChildren: { $0.kind == .directory },
            children: { node in
                node.id == root.id ? [initiallySelectedChild] : []
            }
        )
        let model = FileTreeModel(
            childrenProvider: provider,
            initialSelection: [initiallySelectedChild.id]
        )
        let configuration = FileTreeConfiguration(
            selectionMode: .single,
            allowsEmptySelection: false
        )
        let view = FileTreeView(model: model, configuration: configuration)

        _ = try await model.loadRoots()
        #expect(model.selection == [root.id])
        #expect(model.focusedID == root.id)

        model.expand(root.id)
        for _ in 0..<256 where model.childrenLoadState(for: root.id) != .loaded {
            await Task.yield()
        }

        #expect(model.childrenLoadState(for: root.id) == .loaded)
        #expect(model.selection == [initiallySelectedChild.id])
        #expect(model.focusedID == initiallySelectedChild.id)
        _ = view
    }

    @Test
    func appKitRendersTheSharedSearchProjection() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: [
                "Root/Folder/Target.swift",
                "Root/Other.swift",
                "Outside.swift"
            ],
            options: .init(sort: .inputOrder)
        )
        let view = FileTreeView(model: model)
        let outlineView = try #require(findOutlineView(in: view))

        #expect(outlineView.numberOfRows == 2)

        model.openSearch(initialQuery: "target")
        #expect(model.visibleRows.map(\.id) == ["Root/", "Root/Folder/", "Root/Folder/Target.swift"])
        #expect(outlineView.numberOfRows == 3)

        model.setSearchQuery("missing")
        #expect(model.visibleRows.isEmpty)
        #expect(outlineView.numberOfRows == 0)

        model.closeSearch()
        #expect(outlineView.numberOfRows == 2)
    }

    @Test
    func appKitRendersAndTogglesTheSharedFlattenedProjection() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: [
                "Root/Branch/Leaf/First.swift",
                "Root/Branch/Leaf/Second.swift"
            ],
            options: .init(sort: .inputOrder, flattenEmptyDirectories: true),
            initialExpansion: .identifiers(["Root/Branch/Leaf/"])
        )
        let view = FileTreeView(model: model)
        let outlineView = try #require(findOutlineView(in: view))

        #expect(outlineView.numberOfRows == 3)
        #expect(model.visibleRows[0].representedIDs == [
            "Root/", "Root/Branch/", "Root/Branch/Leaf/"
        ])

        model.setFlattenEmptyDirectories(false)
        #expect(outlineView.numberOfRows == 1)

        model.expand("Root/")
        model.expand("Root/Branch/")
        #expect(outlineView.numberOfRows == 5)
    }

    @Test
    func appKitReloadsAFlattenedRowForAnyRepresentedIdentity() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: ["Root/Branch/Leaf/File.swift"],
            options: .init(sort: .inputOrder, flattenEmptyDirectories: true)
        )
        var renderCount = 0
        let view = FileTreeView(model: model) { _, _, reusableView in
            renderCount += 1
            return reusableView ?? NSView()
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        _ = try #require(findOutlineView(in: view))
        let initialRenderCount = renderCount

        view.reloadRows(withIDs: ["Root/Branch/"])

        #expect(renderCount == initialRenderCount + 1)
        _ = window
    }

    @Test
    func appKitRegistersTheNativePathDragAndDropSurface() throws {
        let model = try FileTreeModel<FileTreePath>(paths: ["A.swift", "B.swift"])
        let view = FileTreeView(model: model)
        let outlineView = try #require(findOutlineView(in: view))

        #expect(
            outlineView.registeredDraggedTypes.contains(
                NSPasteboard.PasteboardType("software.trees.TreeKit.paths")
            )
        )

        outlineView.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        let pasteboardType = NSPasteboard.PasteboardType("software.trees.TreeKit.paths")
        let payloads = try [0, 1].map { row -> [String: Any] in
            let item = try #require(outlineView.item(atRow: row))
            let writer = try #require(
                outlineView.dataSource?.outlineView?(
                    outlineView,
                    pasteboardWriterForItem: item
                ) as? NSPasteboardItem
            )
            return try #require(writer.propertyList(forType: pasteboardType) as? [String: Any])
        }
        #expect(payloads.compactMap { $0["path"] as? String } == ["A.swift", "B.swift"])
        #expect(payloads.allSatisfy { $0["paths"] == nil })
    }

    @Test
    func appKitRestoresAForcedSearchExpansionAfterNativeCollapse() async throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: ["Root/Folder/Target.swift"],
            options: .init(sort: .inputOrder)
        )
        let view = FileTreeView(model: model)
        let outlineView = try #require(findOutlineView(in: view))

        model.openSearch(initialQuery: "target")
        #expect(model.expandedIDs.isEmpty)
        #expect(outlineView.numberOfRows == 3)

        let forcedRoot = try #require(outlineView.item(atRow: 0))
        outlineView.collapseItem(forcedRoot)

        // The renderer waits for NSOutlineView's native collapse transaction to finish before
        // replaying the model's forced search expansion.
        await Task.yield()

        #expect(model.expandedIDs.isEmpty)
        #expect(model.visibleRows.map(\.id) == ["Root/", "Root/Folder/", "Root/Folder/Target.swift"])
        #expect(outlineView.numberOfRows == 3)
        #expect(outlineView.isItemExpanded(forcedRoot))
    }

    @Test
    func mountedAppKitTreeReflectsPathMutationsWithoutModelReplacement() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: ["Root/Existing.swift"],
            initialExpansion: .expanded
        )
        let view = FileTreeView(model: model)
        let outlineView = try #require(findOutlineView(in: view))

        #expect(outlineView.numberOfRows == 2)

        try model.add("Root/New.swift")
        #expect(view.model === model)
        #expect(outlineView.numberOfRows == 3)

        try model.move("Root/New.swift", to: "Root/Renamed.swift")
        #expect(outlineView.numberOfRows == 3)
        #expect(model.preparedTree.node(for: "Root/Renamed.swift") != nil)

        try model.remove("Root/Existing.swift")
        #expect(outlineView.numberOfRows == 2)
    }

    @Test
    func appKitNativeSelectionSynchronizesScopedInteractionState() throws {
        let model = try FileTreeModel<FileTreePath>(
            paths: ["First.swift", "Second.swift"],
            options: .init(sort: .inputOrder)
        )
        let view = FileTreeView(model: model)
        let outlineView = try #require(findOutlineView(in: view))
        var selections: [Set<String>] = []
        var focuses: [String?] = []
        let selectionSubscription = model.selectionChanges.dropFirst().sink {
            selections.append($0)
        }
        let focusSubscription = model.focusChanges.dropFirst().sink {
            focuses.append($0)
        }

        outlineView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        #expect(model.selection == ["Second.swift"])
        #expect(model.focusedID == "Second.swift")
        #expect(selections == [["Second.swift"]])
        #expect(focuses == ["Second.swift"])
        _ = selectionSubscription
        _ = focusSubscription
    }

    private func findOutlineView(in view: NSView) -> NSOutlineView? {
        if let outlineView = view as? NSOutlineView {
            return outlineView
        }
        for subview in view.subviews {
            if let outlineView = findOutlineView(in: subview) {
                return outlineView
            }
        }
        return nil
    }

    private func findVisibleButton(titled title: String, in view: NSView) -> NSButton? {
        if let button = view as? NSButton, !button.isHidden, button.title == title {
            return button
        }
        for subview in view.subviews {
            if let button = findVisibleButton(titled: title, in: subview) {
                return button
            }
        }
        return nil
    }
}
#endif
