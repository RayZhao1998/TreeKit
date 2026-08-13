import Testing
@testable import TreeKit

private struct LazyTestNode: Identifiable, Equatable, Sendable {
    let id: String
    let mightHaveChildren: Bool

    init(_ id: String, mightHaveChildren: Bool = false) {
        self.id = id
        self.mightHaveChildren = mightHaveChildren
    }
}

private actor LazyProviderProbe {
    let roots: [LazyTestNode]
    let childrenByID: [String: [LazyTestNode]]

    private var rootCallCount = 0
    private var childCallCounts: [String: Int] = [:]

    init(
        roots: [LazyTestNode],
        childrenByID: [String: [LazyTestNode]] = [:]
    ) {
        self.roots = roots
        self.childrenByID = childrenByID
    }

    func loadRoots() -> [LazyTestNode] {
        rootCallCount += 1
        return roots
    }

    func loadChildren(of node: LazyTestNode) -> [LazyTestNode] {
        childCallCounts[node.id, default: 0] += 1
        return childrenByID[node.id] ?? []
    }

    func rootCalls() -> Int {
        rootCallCount
    }

    func childCalls(for id: String) -> Int {
        childCallCounts[id, default: 0]
    }
}

@MainActor
struct FileTreeLazyLoadingTests {
    private enum WaitError: Error {
        case timedOutWaitingForRoots(FileTreeChildrenLoadState)
        case timedOutWaitingForChildren(String, FileTreeChildrenLoadState)
    }

    private func makeModel(
        probe: LazyProviderProbe,
        initialExpansion: FileTreeInitialExpansion<String> = .collapsed,
        initialSelection: Set<String> = []
    ) -> FileTreeModel<LazyTestNode> {
        let provider = FileTreeChildrenProvider<LazyTestNode>(
            roots: { await probe.loadRoots() },
            mightHaveChildren: { $0.mightHaveChildren },
            children: { await probe.loadChildren(of: $0) }
        )
        return FileTreeModel(
            childrenProvider: provider,
            initialExpansion: initialExpansion,
            initialSelection: initialSelection,
            searchText: \LazyTestNode.id
        )
    }

    /// Expansion starts provider work in an unstructured main-actor task. Bound the number of
    /// scheduler turns so a regression fails instead of leaving the test suite suspended.
    private func waitForChildren(
        of id: String,
        in model: FileTreeModel<LazyTestNode>,
        toReach expectedState: FileTreeChildrenLoadState = .loaded
    ) async throws {
        for _ in 0..<256 {
            if model.childrenLoadState(for: id) == expectedState {
                return
            }
            await Task.yield()
        }
        throw WaitError.timedOutWaitingForChildren(id, expectedState)
    }

    private func waitForRoots(
        in model: FileTreeModel<LazyTestNode>,
        toReach expectedState: FileTreeChildrenLoadState = .loaded
    ) async throws {
        for _ in 0..<256 {
            if model.rootLoadState == expectedState {
                return
            }
            await Task.yield()
        }
        throw WaitError.timedOutWaitingForRoots(expectedState)
    }

    @Test
    func emptyRootsPublishAnEmptyLoadedTree() async throws {
        let probe = LazyProviderProbe(roots: [])
        let model = makeModel(probe: probe)

        #expect(model.rootLoadState == .unloaded)
        #expect(model.visibleRows.isEmpty)

        let roots = try await model.loadRoots()

        #expect(roots.isEmpty)
        #expect(model.rootLoadState == .loaded)
        #expect(model.preparedTree.count == 0)
        #expect(model.visibleRows.isEmpty)
        #expect(await probe.rootCalls() == 1)

        _ = try await model.loadRoots()
        #expect(await probe.rootCalls() == 1)
    }

    @Test
    func preservesProviderRootAndSiblingOrder() async throws {
        let rootB = LazyTestNode("root-b", mightHaveChildren: true)
        let rootA = LazyTestNode("root-a")
        let probe = LazyProviderProbe(
            roots: [rootB, rootA],
            childrenByID: [
                rootB.id: [
                    LazyTestNode("child-z"),
                    LazyTestNode("child-a"),
                    LazyTestNode("child-m")
                ]
            ]
        )
        let model = makeModel(probe: probe)

        _ = try await model.loadRoots()
        _ = try await model.loadChildren(of: rootB.id)
        model.expand(rootB.id)

        #expect(model.preparedTree.roots.map(\.id) == ["root-b", "root-a"])
        #expect(
            model.preparedTree.children(of: rootB.id).map(\.id)
                == ["child-z", "child-a", "child-m"]
        )
        #expect(
            model.visibleRows.map(\.id)
                == ["root-b", "child-z", "child-a", "child-m", "root-a"]
        )
        #expect(model.knownSiblingIndex(of: "child-a") == 1)
        #expect(model.knownSiblingCount(of: "child-a") == 3)
    }

    @Test
    func unloadedPotentialBranchShowsDisclosureAndExpansionLoadsChildren() async throws {
        let root = LazyTestNode("root", mightHaveChildren: true)
        let child = LazyTestNode("child")
        let probe = LazyProviderProbe(
            roots: [root],
            childrenByID: [root.id: [child]]
        )
        let model = makeModel(probe: probe)

        _ = try await model.loadRoots()

        #expect(model.childrenLoadState(for: root.id) == .unloaded)
        #expect(model.isRenderedExpandable(root.id))
        #expect(!model.preparedTree.isExpandable(root.id))

        model.expand(root.id)

        #expect(model.expandedIDs == [root.id])
        #expect(model.childrenLoadState(for: root.id) == .loading)

        try await waitForChildren(of: root.id, in: model)

        #expect(model.childrenLoadState(for: root.id) == .loaded)
        #expect(model.visibleRows.map(\.id) == [root.id, child.id])
        #expect(await probe.childCalls(for: root.id) == 1)
    }

    @Test
    func leafNeverLoadsAndEmptyDirectoryStopsShowingDisclosure() async throws {
        let leaf = LazyTestNode("leaf")
        let emptyDirectory = LazyTestNode("empty", mightHaveChildren: true)
        let probe = LazyProviderProbe(
            roots: [leaf, emptyDirectory],
            childrenByID: [emptyDirectory.id: []]
        )
        let model = makeModel(probe: probe)

        _ = try await model.loadRoots()

        model.expand(leaf.id)
        #expect(!model.expandedIDs.contains(leaf.id))
        #expect(model.childrenLoadState(for: leaf.id) == .loaded)
        #expect(!model.isRenderedExpandable(leaf.id))
        #expect(await probe.childCalls(for: leaf.id) == 0)

        #expect(model.isRenderedExpandable(emptyDirectory.id))
        model.expand(emptyDirectory.id)
        try await waitForChildren(of: emptyDirectory.id, in: model)

        #expect(model.childrenLoadState(for: emptyDirectory.id) == .loaded)
        #expect(!model.isRenderedExpandable(emptyDirectory.id))
        #expect(!model.expandedIDs.contains(emptyDirectory.id))
        #expect(model.visibleRows.map(\.id) == [leaf.id, emptyDirectory.id])
        #expect(await probe.childCalls(for: emptyDirectory.id) == 1)
    }

    @Test
    func collapseAndReexpandReuseLoadedChildren() async throws {
        let root = LazyTestNode("root", mightHaveChildren: true)
        let child = LazyTestNode("child")
        let probe = LazyProviderProbe(
            roots: [root],
            childrenByID: [root.id: [child]]
        )
        let model = makeModel(probe: probe)

        _ = try await model.loadRoots()
        model.expand(root.id)
        try await waitForChildren(of: root.id, in: model)

        model.collapse(root.id)
        #expect(model.visibleRows.map(\.id) == [root.id])

        model.expand(root.id)

        #expect(model.visibleRows.map(\.id) == [root.id, child.id])
        #expect(model.childrenLoadState(for: root.id) == .loaded)
        #expect(await probe.childCalls(for: root.id) == 1)
    }

    @Test
    func hiddenDiscoveredDescendantRetainsExpansionUntilAncestorReopens() async throws {
        let root = LazyTestNode("root", mightHaveChildren: true)
        let nested = LazyTestNode("nested", mightHaveChildren: true)
        let leaf = LazyTestNode("leaf")
        let probe = LazyProviderProbe(
            roots: [root],
            childrenByID: [
                root.id: [nested],
                nested.id: [leaf]
            ]
        )
        let model = makeModel(probe: probe)

        _ = try await model.loadRoots()
        model.expand(root.id)
        try await waitForChildren(of: root.id, in: model)
        model.collapse(root.id)

        model.expand(nested.id)
        #expect(model.childrenLoadState(for: nested.id) == .loading)
        try await waitForChildren(of: nested.id, in: model)

        #expect(model.expandedIDs == [nested.id])
        #expect(model.visibleRows.map(\.id) == [root.id])

        model.expand(root.id)

        #expect(model.expandedIDs == [root.id, nested.id])
        #expect(model.visibleRows.map(\.id) == [root.id, nested.id, leaf.id])
        #expect(await probe.childCalls(for: root.id) == 1)
        #expect(await probe.childCalls(for: nested.id) == 1)
    }

    @Test
    func collapseAllCancelsPendingExpandAllTraversal() async throws {
        let root = LazyTestNode("root", mightHaveChildren: true)
        let child = LazyTestNode("child")
        let probe = LazyProviderProbe(
            roots: [root],
            childrenByID: [root.id: [child]]
        )
        let model = makeModel(probe: probe)

        model.expandAll()
        model.collapseAll()

        try await waitForRoots(in: model)

        #expect(model.expandedIDs.isEmpty)
        #expect(model.visibleRows.map(\.id) == [root.id])
        #expect(await probe.childCalls(for: root.id) == 0)
    }

    @Test
    func collapseAllCancelsPendingInitialExpandedPolicy() async throws {
        let root = LazyTestNode("root", mightHaveChildren: true)
        let child = LazyTestNode("child")
        let probe = LazyProviderProbe(
            roots: [root],
            childrenByID: [root.id: [child]]
        )
        let model = makeModel(
            probe: probe,
            initialExpansion: .expanded
        )

        model.startLazyRootLoadingIfNeeded()
        model.collapseAll()
        try await waitForRoots(in: model)

        #expect(model.expandedIDs.isEmpty)
        #expect(model.visibleRows.map(\.id) == [root.id])
        #expect(await probe.childCalls(for: root.id) == 0)
    }

    @Test
    func setExpandedIDsCancelsPendingInitialDepthPolicy() async throws {
        let root = LazyTestNode("root", mightHaveChildren: true)
        let child = LazyTestNode("child")
        let probe = LazyProviderProbe(
            roots: [root],
            childrenByID: [root.id: [child]]
        )
        let model = makeModel(
            probe: probe,
            initialExpansion: .depth(2)
        )

        model.startLazyRootLoadingIfNeeded()
        model.setExpandedIDs([])
        try await waitForRoots(in: model)

        #expect(model.expandedIDs.isEmpty)
        #expect(model.visibleRows.map(\.id) == [root.id])
        #expect(await probe.childCalls(for: root.id) == 0)
    }

    @Test
    func collapseCancelsInitialExpansionForChildrenAlreadyLoading() async throws {
        let root = LazyTestNode("root", mightHaveChildren: true)
        let nested = LazyTestNode("nested", mightHaveChildren: true)
        let leaf = LazyTestNode("leaf")
        let probe = LazyProviderProbe(
            roots: [root],
            childrenByID: [
                root.id: [nested],
                nested.id: [leaf]
            ]
        )
        let model = makeModel(
            probe: probe,
            initialExpansion: .expanded
        )

        _ = try await model.loadRoots()
        #expect(model.childrenLoadState(for: root.id) == .loading)
        model.collapse(root.id)
        try await waitForChildren(of: root.id, in: model)

        #expect(model.expandedIDs.isEmpty)
        #expect(model.visibleRows.map(\.id) == [root.id])
        #expect(model.childrenLoadState(for: nested.id) == .unloaded)
        #expect(await probe.childCalls(for: nested.id) == 0)
    }

    @Test
    func duplicateDiscoveredIdentityDoesNotPublishPartialChildren() async throws {
        let root = LazyTestNode("root", mightHaveChildren: true)
        let probe = LazyProviderProbe(
            roots: [root],
            childrenByID: [root.id: [LazyTestNode("child"), LazyTestNode("child")]]
        )
        let model = makeModel(probe: probe)

        _ = try await model.loadRoots()

        await #expect(throws: TreePreparationError.duplicateIdentifier("child")) {
            try await model.loadChildren(of: root.id)
        }
        #expect(model.childrenLoadState(for: root.id) == .unloaded)
        #expect(model.preparedTree.nodes.map(\.id) == [root.id])
        #expect(model.visibleRows.map(\.id) == [root.id])
    }

    @Test
    func initialDepthAndSelectionApplyAsNodesAreDiscovered() async throws {
        let root = LazyTestNode("root", mightHaveChildren: true)
        let child = LazyTestNode("child")
        let probe = LazyProviderProbe(
            roots: [root],
            childrenByID: [root.id: [child]]
        )
        let model = makeModel(
            probe: probe,
            initialExpansion: .depth(1),
            initialSelection: [root.id]
        )

        _ = try await model.loadRoots()

        #expect(model.selection == [root.id])
        #expect(model.focusedID == root.id)
        #expect(model.expandedIDs == [root.id])

        try await waitForChildren(of: root.id, in: model)

        #expect(model.visibleRows.map(\.id) == [root.id, child.id])
        #expect(await probe.childCalls(for: root.id) == 1)
    }

    @Test
    func consumedInitialSelectionDoesNotOverrideLaterUserInteraction() async throws {
        let initiallySelected = LazyTestNode("selected")
        let branch = LazyTestNode("branch", mightHaveChildren: true)
        let child = LazyTestNode("child")
        let probe = LazyProviderProbe(
            roots: [initiallySelected, branch],
            childrenByID: [branch.id: [child]]
        )
        let model = makeModel(
            probe: probe,
            initialSelection: [initiallySelected.id]
        )

        _ = try await model.loadRoots()
        #expect(model.selection == [initiallySelected.id])
        #expect(model.focusedID == initiallySelected.id)

        model.expand(branch.id)
        model.deselectAll()
        #expect(model.selection.isEmpty)
        #expect(model.focusedID == nil)

        try await waitForChildren(of: branch.id, in: model)

        #expect(model.selection.isEmpty)
        #expect(model.focusedID == nil)
    }

    @Test
    func pendingInitialSelectionDoesNotOverrideAnExplicitClear() async throws {
        let root = LazyTestNode("root", mightHaveChildren: true)
        let initiallySelectedChild = LazyTestNode("initial-child")
        let probe = LazyProviderProbe(
            roots: [root],
            childrenByID: [root.id: [initiallySelectedChild]]
        )
        let model = makeModel(
            probe: probe,
            initialSelection: [initiallySelectedChild.id]
        )

        _ = try await model.loadRoots()
        #expect(model.selection.isEmpty)

        model.deselectAll()
        model.expand(root.id)
        try await waitForChildren(of: root.id, in: model)

        #expect(model.selection.isEmpty)
        #expect(model.focusedID == nil)
    }

    @Test
    func pendingInitialSelectionDoesNotOverrideAReplacementSelection() async throws {
        let branch = LazyTestNode("branch", mightHaveChildren: true)
        let replacement = LazyTestNode("replacement")
        let initiallySelectedChild = LazyTestNode("initial-child")
        let probe = LazyProviderProbe(
            roots: [branch, replacement],
            childrenByID: [branch.id: [initiallySelectedChild]]
        )
        let model = makeModel(
            probe: probe,
            initialSelection: [initiallySelectedChild.id]
        )

        _ = try await model.loadRoots()
        model.setSelection([replacement.id])
        model.expand(branch.id)
        try await waitForChildren(of: branch.id, in: model)

        #expect(model.selection == [replacement.id])
        #expect(model.focusedID == replacement.id)
    }

    @Test
    func pendingInitialSelectionDoesNotOverrideNativeSelectionSynchronization() async throws {
        let root = LazyTestNode("root", mightHaveChildren: true)
        let initiallySelectedChild = LazyTestNode("initial-child")
        let probe = LazyProviderProbe(
            roots: [root],
            childrenByID: [root.id: [initiallySelectedChild]]
        )
        let model = makeModel(
            probe: probe,
            initialSelection: [initiallySelectedChild.id]
        )

        _ = try await model.loadRoots()
        model.synchronizeSelection([], focusedID: nil)
        model.expand(root.id)
        try await waitForChildren(of: root.id, in: model)

        #expect(model.selection.isEmpty)
        #expect(model.focusedID == nil)
    }

    @Test
    func revealSelectionCancelsPendingInitialSelection() async throws {
        let branch = LazyTestNode("branch", mightHaveChildren: true)
        let revealed = LazyTestNode("revealed")
        let initiallySelectedChild = LazyTestNode("initial-child")
        let probe = LazyProviderProbe(
            roots: [branch, revealed],
            childrenByID: [branch.id: [initiallySelectedChild]]
        )
        let model = makeModel(
            probe: probe,
            initialSelection: [initiallySelectedChild.id]
        )

        _ = try await model.loadRoots()
        model.reveal(revealed.id)
        model.expand(branch.id)
        try await waitForChildren(of: branch.id, in: model)

        #expect(model.selection == [revealed.id])
        #expect(model.focusedID == revealed.id)
    }

    @Test
    func pendingInitialSelectionReplacesRendererFallback() async throws {
        let branch = LazyTestNode("branch", mightHaveChildren: true)
        let fallback = LazyTestNode("fallback")
        let initiallySelectedChild = LazyTestNode("initial-child")
        let probe = LazyProviderProbe(
            roots: [branch, fallback],
            childrenByID: [branch.id: [initiallySelectedChild]]
        )
        let model = makeModel(
            probe: probe,
            initialSelection: [initiallySelectedChild.id]
        )

        _ = try await model.loadRoots()
        model.applyRendererSelectionPolicy(
            [fallback.id],
            isProvisionalFallback: true
        )
        model.expand(branch.id)
        try await waitForChildren(of: branch.id, in: model)

        #expect(model.selection == [initiallySelectedChild.id])
        #expect(model.focusedID == initiallySelectedChild.id)
    }

    @Test
    func expandAllTraversesBranchesDiscoveredAfterTheCall() async throws {
        let root = LazyTestNode("root", mightHaveChildren: true)
        let nested = LazyTestNode("nested", mightHaveChildren: true)
        let leaf = LazyTestNode("leaf")
        let probe = LazyProviderProbe(
            roots: [root],
            childrenByID: [
                root.id: [nested],
                nested.id: [leaf]
            ]
        )
        let model = makeModel(probe: probe)

        model.expandAll()

        try await waitForRoots(in: model)
        try await waitForChildren(of: root.id, in: model)
        try await waitForChildren(of: nested.id, in: model)

        #expect(model.expandedIDs == [root.id, nested.id])
        #expect(model.visibleRows.map(\.id) == [root.id, nested.id, leaf.id])
        #expect(await probe.rootCalls() == 1)
        #expect(await probe.childCalls(for: root.id) == 1)
        #expect(await probe.childCalls(for: nested.id) == 1)
    }

    @Test
    func eagerAndLazyModelsKeepTheirSynchronousAndAsyncSemantics() async throws {
        let eagerRoot = LazyTestNode("eager", mightHaveChildren: true)
        let eagerChild = LazyTestNode("eager-child")
        let eagerTree = try PreparedTree(roots: [eagerRoot]) { node in
            node.id == eagerRoot.id ? [eagerChild] : []
        }
        let eagerModel = FileTreeModel(eagerTree, initialExpansion: .expanded)

        let lazyRoot = LazyTestNode("lazy")
        let probe = LazyProviderProbe(roots: [lazyRoot])
        let lazyModel = makeModel(probe: probe)

        #expect(eagerModel.rootLoadState == .loaded)
        #expect(eagerModel.childrenLoadState(for: eagerRoot.id) == .loaded)
        #expect(eagerModel.visibleRows.map(\.id) == [eagerRoot.id, eagerChild.id])
        #expect(lazyModel.rootLoadState == .unloaded)
        #expect(lazyModel.visibleRows.isEmpty)

        let retainedEagerRoots = try await eagerModel.loadRoots()
        let discoveredLazyRoots = try await lazyModel.loadRoots()

        #expect(retainedEagerRoots.map(\.id) == [eagerRoot.id])
        #expect(discoveredLazyRoots.map(\.id) == [lazyRoot.id])
        #expect(eagerModel.visibleRows.map(\.id) == [eagerRoot.id, eagerChild.id])
        #expect(lazyModel.visibleRows.map(\.id) == [lazyRoot.id])
    }
}
