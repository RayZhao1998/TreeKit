#if canImport(AppKit)
import AppKit
import SwiftUI
import Testing
@testable import TreeKit

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
        view.model = replacement
        #expect(view.model === replacement)

        view.reloadRows()
        _ = view.focusTree()
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
}
#endif
