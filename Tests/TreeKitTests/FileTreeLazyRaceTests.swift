import Combine
import Testing
@testable import TreeKit

private struct LazyRaceNode: Identifiable, Equatable, Sendable {
    let id: String
    let mightHaveChildren: Bool
    let searchValue: String

    init(
        _ id: String,
        mightHaveChildren: Bool = false,
        searchValue: String? = nil
    ) {
        self.id = id
        self.mightHaveChildren = mightHaveChildren
        self.searchValue = searchValue ?? id
    }
}

private enum LazyRaceProbeError: Error, Equatable, Sendable {
    case rejected(String)
}

private actor LazyRaceProbe {
    private enum Resolution: Sendable {
        case success([LazyRaceNode])
        case failure(LazyRaceProbeError)
    }

    private var rootCallCount = 0
    private var childCallCounts: [String: Int] = [:]
    private var rootResolution: Resolution?
    private var childResolutions: [String: Resolution] = [:]
    private var pendingRoots: [CheckedContinuation<[LazyRaceNode], any Error>] = []
    private var pendingChildren: [String: [CheckedContinuation<[LazyRaceNode], any Error>]] = [:]

    init(immediateRoots roots: [LazyRaceNode]? = nil) {
        if let roots {
            rootResolution = .success(roots)
        }
    }

    func loadRoots() async throws -> [LazyRaceNode] {
        rootCallCount += 1
        if let rootResolution {
            return try Self.value(from: rootResolution)
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingRoots.append(continuation)
        }
    }

    func loadChildren(of node: LazyRaceNode) async throws -> [LazyRaceNode] {
        childCallCounts[node.id, default: 0] += 1
        if let resolution = childResolutions[node.id] {
            return try Self.value(from: resolution)
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingChildren[node.id, default: []].append(continuation)
        }
    }

    func rootCalls() -> Int {
        rootCallCount
    }

    func childCalls(for id: String) -> Int {
        childCallCounts[id, default: 0]
    }

    func succeedRoots(with roots: [LazyRaceNode]) {
        resolveRoots(.success(roots))
    }

    func failRoots(with error: LazyRaceProbeError) {
        resolveRoots(.failure(error))
    }

    func succeedChildren(of id: String, with children: [LazyRaceNode]) {
        resolveChildren(of: id, with: .success(children))
    }

    func failChildren(of id: String, with error: LazyRaceProbeError) {
        resolveChildren(of: id, with: .failure(error))
    }

    private func resolveRoots(_ resolution: Resolution) {
        rootResolution = resolution
        let continuations = pendingRoots
        pendingRoots = []
        for continuation in continuations {
            Self.resume(continuation, with: resolution)
        }
    }

    private func resolveChildren(of id: String, with resolution: Resolution) {
        childResolutions[id] = resolution
        let continuations = pendingChildren.removeValue(forKey: id) ?? []
        for continuation in continuations {
            Self.resume(continuation, with: resolution)
        }
    }

    private static func value(from resolution: Resolution) throws -> [LazyRaceNode] {
        switch resolution {
        case .success(let nodes):
            return nodes
        case .failure(let error):
            throw error
        }
    }

    private static func resume(
        _ continuation: CheckedContinuation<[LazyRaceNode], any Error>,
        with resolution: Resolution
    ) {
        switch resolution {
        case .success(let nodes):
            continuation.resume(returning: nodes)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}

private actor LazyRaceCancellationGate {
    private var rootCallCount = 0
    private var didStartRoots = false
    private var didObserveTaskCancellation = false
    private var continuation: CheckedContinuation<Void, Never>?

    func loadRoots() async throws -> [LazyRaceNode] {
        rootCallCount += 1
        didStartRoots = true

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                if Task.isCancelled {
                    self.continuation = nil
                    continuation.resume()
                }
            }
        } onCancel: {
            Task {
                await self.releaseForCancellation()
            }
        }

        if Task.isCancelled {
            didObserveTaskCancellation = true
            throw CancellationError()
        }
        return []
    }

    func rootsStarted() -> Bool {
        didStartRoots
    }

    func observedTaskCancellation() -> Bool {
        didObserveTaskCancellation
    }

    func rootCalls() -> Int {
        rootCallCount
    }

    private func releaseForCancellation() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class LazyRaceResetTrigger: @unchecked Sendable {
    private weak var model: FileTreeModel<LazyRaceNode>?
    private var replacementProvider: FileTreeChildrenProvider<LazyRaceNode>?
    private let triggerID: String
    private(set) var didReset = false

    init(triggerID: String) {
        self.triggerID = triggerID
    }

    func install(
        model: FileTreeModel<LazyRaceNode>,
        replacementProvider: FileTreeChildrenProvider<LazyRaceNode>
    ) {
        self.model = model
        self.replacementProvider = replacementProvider
    }

    func classify(_ node: LazyRaceNode) -> Bool {
        if node.id == triggerID,
           !didReset,
           let model,
           let replacementProvider
        {
            didReset = true
            model.reset(childrenProvider: replacementProvider)
        }
        return node.mightHaveChildren
    }
}

@MainActor
private final class LazyRaceSearchResetTrigger {
    private weak var model: FileTreeModel<LazyRaceNode>?
    private var replacementTree: PreparedTree<LazyRaceNode>?
    private let triggerValue: String
    private(set) var didReset = false

    init(triggerValue: String) {
        self.triggerValue = triggerValue
    }

    func install(
        model: FileTreeModel<LazyRaceNode>,
        replacementTree: PreparedTree<LazyRaceNode>
    ) {
        self.model = model
        self.replacementTree = replacementTree
    }

    func searchText(for node: LazyRaceNode) -> String {
        if node.searchValue == triggerValue,
           !didReset,
           let model,
           let replacementTree
        {
            didReset = true
            model.reset(
                replacementTree,
                preservingExpansion: false,
                preservingSelection: false
            )
        }
        return node.searchValue
    }
}

@MainActor
struct FileTreeLazyRaceTests {
    private enum WaitError: Error {
        case rootProviderDidNotStart
        case childProviderDidNotStart(String)
        case providerDidNotObserveCancellation
        case rootStateDidNotBecome(FileTreeChildrenLoadState)
        case childStateDidNotBecome(String, FileTreeChildrenLoadState)
    }

    private func makeProvider(
        probe: LazyRaceProbe
    ) -> FileTreeChildrenProvider<LazyRaceNode> {
        FileTreeChildrenProvider(
            roots: { try await probe.loadRoots() },
            mightHaveChildren: { $0.mightHaveChildren },
            children: { try await probe.loadChildren(of: $0) }
        )
    }

    private func makeModel(
        probe: LazyRaceProbe,
        initialExpansion: FileTreeInitialExpansion<String> = .collapsed,
        initialSelection: Set<String> = []
    ) -> FileTreeModel<LazyRaceNode> {
        FileTreeModel(
            childrenProvider: makeProvider(probe: probe),
            initialExpansion: initialExpansion,
            initialSelection: initialSelection,
            searchText: \LazyRaceNode.id
        )
    }

    private func settleScheduler() async {
        for _ in 0..<64 {
            await Task.yield()
        }
    }

    private func waitForRootCalls(
        _ expectedCount: Int,
        in probe: LazyRaceProbe
    ) async throws {
        for _ in 0..<512 {
            if await probe.rootCalls() >= expectedCount {
                return
            }
            await Task.yield()
        }
        throw WaitError.rootProviderDidNotStart
    }

    private func waitForChildCalls(
        _ expectedCount: Int,
        of id: String,
        in probe: LazyRaceProbe
    ) async throws {
        for _ in 0..<512 {
            if await probe.childCalls(for: id) >= expectedCount {
                return
            }
            await Task.yield()
        }
        throw WaitError.childProviderDidNotStart(id)
    }

    private func waitForRootsToStart(
        in gate: LazyRaceCancellationGate
    ) async throws {
        for _ in 0..<512 {
            if await gate.rootsStarted() {
                return
            }
            await Task.yield()
        }
        throw WaitError.rootProviderDidNotStart
    }

    private func waitForCancellation(
        in gate: LazyRaceCancellationGate
    ) async throws {
        for _ in 0..<512 {
            if await gate.observedTaskCancellation() {
                return
            }
            await Task.yield()
        }
        throw WaitError.providerDidNotObserveCancellation
    }

    private func waitForRoots(
        in model: FileTreeModel<LazyRaceNode>,
        toReach expectedState: FileTreeChildrenLoadState
    ) async throws {
        for _ in 0..<512 {
            if model.rootLoadState == expectedState {
                return
            }
            await Task.yield()
        }
        throw WaitError.rootStateDidNotBecome(expectedState)
    }

    private func waitForChildren(
        of id: String,
        in model: FileTreeModel<LazyRaceNode>,
        toReach expectedState: FileTreeChildrenLoadState
    ) async throws {
        for _ in 0..<512 {
            if model.childrenLoadState(for: id) == expectedState {
                return
            }
            await Task.yield()
        }
        throw WaitError.childStateDidNotBecome(id, expectedState)
    }

    @Test
    func concurrentRootRequestsShareOneProviderOperation() async throws {
        let root = LazyRaceNode("root")
        let probe = LazyRaceProbe()
        let model = makeModel(probe: probe)

        let first = Task { try await model.loadRoots() }
        let second = Task { try await model.loadRoots() }
        try await waitForRootCalls(1, in: probe)
        await settleScheduler()

        #expect(await probe.rootCalls() == 1)
        let revisionBeforeCompletion = model.revision
        let dataRevisionBeforeCompletion = model.dataRevision

        await probe.succeedRoots(with: [root])
        let firstRoots = try await first.value
        let secondRoots = try await second.value

        #expect(firstRoots == [root])
        #expect(secondRoots == [root])
        #expect(model.preparedTree.nodes.map(\.id) == [root.id])
        #expect(model.rootLoadState == .loaded)
        #expect(model.revision == revisionBeforeCompletion + 1)
        #expect(model.dataRevision == dataRevisionBeforeCompletion + 1)
    }

    @Test
    func cancellingOneRootWaiterDetachesWithoutCancellingSharedWork() async throws {
        let root = LazyRaceNode("root")
        let probe = LazyRaceProbe()
        let model = makeModel(probe: probe)
        let cancelledWaiter = Task { try await model.loadRoots() }
        let retainedWaiter = Task { try await model.loadRoots() }
        try await waitForRootCalls(1, in: probe)

        cancelledWaiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelledWaiter.value
        }
        #expect(await probe.rootCalls() == 1)

        await probe.succeedRoots(with: [root])
        #expect(try await retainedWaiter.value == [root])
        #expect(model.rootLoadState == .loaded)
    }

    @Test
    func providerResetPromptlyDetachesWaitersFromNonCooperativeWork() async throws {
        let oldRoot = LazyRaceNode("old")
        let replacementRoot = LazyRaceNode("replacement")
        let oldProbe = LazyRaceProbe()
        let replacementProbe = LazyRaceProbe(immediateRoots: [replacementRoot])
        let model = makeModel(probe: oldProbe)
        let oldWaiter = Task { try await model.loadRoots() }
        try await waitForRootCalls(1, in: oldProbe)

        model.reset(childrenProvider: makeProvider(probe: replacementProbe))
        await #expect(throws: CancellationError.self) {
            try await oldWaiter.value
        }

        #expect(try await model.loadRoots() == [replacementRoot])
        #expect(model.preparedTree.nodes.map(\.id) == [replacementRoot.id])

        // The old provider intentionally ignores task cancellation. Releasing it after the
        // waiter has already detached must not mutate the replacement generation.
        await oldProbe.succeedRoots(with: [oldRoot])
        await settleScheduler()
        #expect(model.preparedTree.nodes.map(\.id) == [replacementRoot.id])
    }

    @Test
    func concurrentChildRequestsShareOneProviderOperation() async throws {
        let root = LazyRaceNode("root", mightHaveChildren: true)
        let child = LazyRaceNode("child")
        let probe = LazyRaceProbe(immediateRoots: [root])
        let model = makeModel(probe: probe)
        _ = try await model.loadRoots()

        let first = Task { try await model.loadChildren(of: root.id) }
        let second = Task { try await model.loadChildren(of: root.id) }
        try await waitForChildCalls(1, of: root.id, in: probe)
        await settleScheduler()

        #expect(await probe.childCalls(for: root.id) == 1)
        let revisionBeforeCompletion = model.revision
        let dataRevisionBeforeCompletion = model.dataRevision

        await probe.succeedChildren(of: root.id, with: [child])
        let firstChildren = try await first.value
        let secondChildren = try await second.value

        #expect(firstChildren == [child])
        #expect(secondChildren == [child])
        #expect(model.preparedTree.children(of: root.id).map(\.id) == [child.id])
        #expect(model.preparedTree.nodes.count == 2)
        #expect(model.revision == revisionBeforeCompletion + 1)
        #expect(model.dataRevision == dataRevisionBeforeCompletion + 1)
    }

    @Test
    func concurrentRootWaitersReceiveOneSharedFailureAndOneFailedPublication() async throws {
        let failure = LazyRaceProbeError.rejected("current failure")
        let probe = LazyRaceProbe()
        let model = makeModel(probe: probe)

        let first = Task { try await model.loadRoots() }
        let second = Task { try await model.loadRoots() }
        try await waitForRootCalls(1, in: probe)
        await settleScheduler()

        #expect(await probe.rootCalls() == 1)
        #expect(model.rootLoadState == .loading)
        let revisionWhileLoading = model.revision
        let loadRevisionWhileLoading = model.loadRevision

        await probe.failRoots(with: failure)

        await #expect(throws: failure) {
            try await first.value
        }
        await #expect(throws: failure) {
            try await second.value
        }

        guard case .failed(let storedFailure) = model.rootLoadState else {
            Issue.record("Expected the shared root failure to remain visible")
            return
        }
        #expect(storedFailure.underlyingError as? LazyRaceProbeError == failure)
        #expect(model.loadRevision == loadRevisionWhileLoading + 1)
        #expect(model.revision == revisionWhileLoading + 1)
        #expect(model.preparedTree.count == 0)
        #expect(await probe.rootCalls() == 1)
    }

    @Test
    func concurrentChildWaitersReceiveOneSharedFailureAndOneFailedPublication() async throws {
        let root = LazyRaceNode("root", mightHaveChildren: true)
        let failure = LazyRaceProbeError.rejected("current child failure")
        let probe = LazyRaceProbe(immediateRoots: [root])
        let model = makeModel(probe: probe)
        _ = try await model.loadRoots()

        let first = Task { try await model.loadChildren(of: root.id) }
        let second = Task { try await model.loadChildren(of: root.id) }
        try await waitForChildCalls(1, of: root.id, in: probe)
        await settleScheduler()

        #expect(await probe.childCalls(for: root.id) == 1)
        #expect(model.childrenLoadState(for: root.id) == .loading)
        let revisionWhileLoading = model.revision
        let loadRevisionWhileLoading = model.loadRevision

        await probe.failChildren(of: root.id, with: failure)

        await #expect(throws: failure) {
            try await first.value
        }
        await #expect(throws: failure) {
            try await second.value
        }

        guard case .failed(let storedFailure) = model.childrenLoadState(for: root.id) else {
            Issue.record("Expected the shared child failure to remain on its branch")
            return
        }
        #expect(storedFailure.underlyingError as? LazyRaceProbeError == failure)
        #expect(model.loadRevision == loadRevisionWhileLoading + 1)
        #expect(model.revision == revisionWhileLoading + 1)
        #expect(model.preparedTree.nodes.map(\.id) == [root.id])
        #expect(await probe.childCalls(for: root.id) == 1)
    }

    @Test
    func repeatedExpansionWhileLoadingDoesNotDuplicateWorkOrNodes() async throws {
        let root = LazyRaceNode("root", mightHaveChildren: true)
        let child = LazyRaceNode("child")
        let probe = LazyRaceProbe(immediateRoots: [root])
        let model = makeModel(probe: probe)
        _ = try await model.loadRoots()

        model.expand(root.id)
        try await waitForChildCalls(1, of: root.id, in: probe)
        model.expand(root.id)
        model.collapse(root.id)
        model.expand(root.id)
        await settleScheduler()

        #expect(await probe.childCalls(for: root.id) == 1)

        await probe.succeedChildren(of: root.id, with: [child])
        try await waitForChildren(of: root.id, in: model, toReach: .loaded)

        #expect(model.expandedIDs == [root.id])
        #expect(model.visibleRows.map(\.id) == [root.id, child.id])
        #expect(model.preparedTree.nodes.map(\.id) == [root.id, child.id])
        #expect(await probe.childCalls(for: root.id) == 1)
    }

    @Test
    func collapseWhileLoadingRetainsTheResultWithoutReopeningTheBranch() async throws {
        let root = LazyRaceNode("root", mightHaveChildren: true)
        let child = LazyRaceNode("child")
        let probe = LazyRaceProbe(immediateRoots: [root])
        let model = makeModel(probe: probe)
        _ = try await model.loadRoots()

        model.expand(root.id)
        try await waitForChildCalls(1, of: root.id, in: probe)
        model.collapse(root.id)
        await probe.succeedChildren(of: root.id, with: [child])
        try await waitForChildren(of: root.id, in: model, toReach: .loaded)

        #expect(model.expandedIDs.isEmpty)
        #expect(model.visibleRows.map(\.id) == [root.id])
        #expect(model.preparedTree.children(of: root.id).map(\.id) == [child.id])

        model.expand(root.id)

        #expect(model.visibleRows.map(\.id) == [root.id, child.id])
        #expect(await probe.childCalls(for: root.id) == 1)
    }

    @Test
    func staleChildSuccessAfterEagerResetCannotReplaceTheNewHierarchy() async throws {
        let oldRoot = LazyRaceNode("old-root", mightHaveChildren: true)
        let staleChild = LazyRaceNode("stale-child")
        let replacement = LazyRaceNode("replacement")
        let probe = LazyRaceProbe(immediateRoots: [oldRoot])
        let model = makeModel(probe: probe)
        _ = try await model.loadRoots()

        let oldLoad = Task { try await model.loadChildren(of: oldRoot.id) }
        try await waitForChildCalls(1, of: oldRoot.id, in: probe)
        let replacementTree = try PreparedTree(roots: [replacement]) { _ in [] }
        model.reset(replacementTree)

        await probe.succeedChildren(of: oldRoot.id, with: [staleChild])
        await #expect(throws: CancellationError.self) {
            try await oldLoad.value
        }
        await settleScheduler()

        #expect(model.preparedTree.nodes.map(\.id) == [replacement.id])
        #expect(model.visibleRows.map(\.id) == [replacement.id])
        #expect(model.rootLoadState == .loaded)
        #expect(model.childrenLoadState(for: oldRoot.id) == .loaded)
    }

    @Test
    func staleChildFailureAfterEagerResetCannotPublishIntoTheNewGeneration() async throws {
        let oldRoot = LazyRaceNode("old-root", mightHaveChildren: true)
        let replacement = LazyRaceNode("replacement")
        let probe = LazyRaceProbe(immediateRoots: [oldRoot])
        let model = makeModel(probe: probe)
        _ = try await model.loadRoots()

        let oldLoad = Task { try await model.loadChildren(of: oldRoot.id) }
        try await waitForChildCalls(1, of: oldRoot.id, in: probe)
        let replacementTree = try PreparedTree(roots: [replacement]) { _ in [] }
        model.reset(replacementTree)
        let revisionAfterReset = model.revision
        let loadRevisionAfterReset = model.loadRevision

        await probe.failChildren(of: oldRoot.id, with: .rejected("obsolete"))
        await #expect(throws: CancellationError.self) {
            try await oldLoad.value
        }
        await settleScheduler()

        #expect(model.preparedTree.nodes.map(\.id) == [replacement.id])
        #expect(model.revision == revisionAfterReset)
        #expect(model.loadRevision == loadRevisionAfterReset)
        #expect(model.childrenLoadState(for: oldRoot.id) == .loaded)
    }

    @Test
    func eagerResetCancelsAStartedCooperativeProviderOperation() async throws {
        let replacement = LazyRaceNode("replacement")
        let gate = LazyRaceCancellationGate()
        let provider = FileTreeChildrenProvider<LazyRaceNode>(
            roots: { try await gate.loadRoots() },
            mightHaveChildren: { $0.mightHaveChildren },
            children: { _ in [] }
        )
        let model = FileTreeModel(
            childrenProvider: provider,
            searchText: \LazyRaceNode.id
        )

        let oldLoad = Task { try await model.loadRoots() }
        try await waitForRootsToStart(in: gate)
        let replacementTree = try PreparedTree(roots: [replacement]) { _ in [] }
        model.reset(replacementTree)
        try await waitForCancellation(in: gate)

        await #expect(throws: CancellationError.self) {
            try await oldLoad.value
        }
        #expect(await gate.rootCalls() == 1)
        #expect(model.preparedTree.nodes.map(\.id) == [replacement.id])
        #expect(model.visibleRows.map(\.id) == [replacement.id])
        #expect(model.rootLoadState == .loaded)
    }

    @Test
    func synchronousResetDuringInitialChildLoadPublicationObsoletesTheRootWaiter() async throws {
        let root = LazyRaceNode("root", mightHaveChildren: true)
        let replacement = LazyRaceNode("replacement")
        let probe = LazyRaceProbe(immediateRoots: [root])
        let model = makeModel(
            probe: probe,
            initialExpansion: .expanded
        )
        let replacementTree = try PreparedTree(roots: [replacement]) { _ in [] }
        var didReset = false
        let subscription = model.$revision.sink { _ in
            guard
                !didReset,
                model.childrenLoadState(for: root.id) == .loading
            else { return }
            didReset = true
            model.reset(replacementTree)
        }

        await #expect(throws: CancellationError.self) {
            try await model.loadRoots()
        }

        #expect(didReset)
        #expect(model.preparedTree.nodes.map(\.id) == [replacement.id])
        #expect(model.visibleRows.map(\.id) == [replacement.id])
        #expect(model.rootLoadState == .loaded)
        #expect(await probe.childCalls(for: root.id) == 0)
        _ = subscription
    }

    @Test
    func synchronousResetDuringChildLoadPublicationObsoletesTheChildWaiter() async throws {
        let root = LazyRaceNode("root", mightHaveChildren: true)
        let replacement = LazyRaceNode("replacement")
        let probe = LazyRaceProbe(immediateRoots: [root])
        let model = makeModel(probe: probe)
        _ = try await model.loadRoots()
        let replacementTree = try PreparedTree(roots: [replacement]) { _ in [] }
        var didReset = false
        let subscription = model.$revision.sink { _ in
            guard
                !didReset,
                model.childrenLoadState(for: root.id) == .loading
            else { return }
            didReset = true
            model.reset(replacementTree)
        }

        await #expect(throws: CancellationError.self) {
            try await model.loadChildren(of: root.id)
        }

        #expect(didReset)
        #expect(model.preparedTree.nodes.map(\.id) == [replacement.id])
        #expect(model.visibleRows.map(\.id) == [replacement.id])
        #expect(model.rootLoadState == .loaded)
        #expect(await probe.childCalls(for: root.id) == 0)
        _ = subscription
    }

    @Test
    func resetDuringRootClassificationRejectsTheStaleRoots() async throws {
        let staleRoot = LazyRaceNode("stale-root", mightHaveChildren: true)
        let currentRoot = LazyRaceNode("current-root")
        let staleProbe = LazyRaceProbe(immediateRoots: [staleRoot])
        let currentProbe = LazyRaceProbe(immediateRoots: [currentRoot])
        let trigger = LazyRaceResetTrigger(triggerID: staleRoot.id)
        let staleProvider = FileTreeChildrenProvider<LazyRaceNode>(
            roots: { try await staleProbe.loadRoots() },
            mightHaveChildren: { node in
                MainActor.assumeIsolated { trigger.classify(node) }
            },
            children: { try await staleProbe.loadChildren(of: $0) }
        )
        let model = FileTreeModel(childrenProvider: staleProvider)
        trigger.install(
            model: model,
            replacementProvider: makeProvider(probe: currentProbe)
        )

        await #expect(throws: CancellationError.self) {
            try await model.loadRoots()
        }
        #expect(trigger.didReset)
        #expect(model.rootLoadState == .unloaded)
        #expect(model.preparedTree.count == 0)

        #expect(try await model.loadRoots() == [currentRoot])
        #expect(model.preparedTree.nodes.map(\.id) == [currentRoot.id])
        #expect(await staleProbe.rootCalls() == 1)
        #expect(await currentProbe.rootCalls() == 1)
    }

    @Test
    func resetDuringChildClassificationRejectsTheStaleChildren() async throws {
        let staleRoot = LazyRaceNode("stale-root", mightHaveChildren: true)
        let staleChild = LazyRaceNode("stale-child", mightHaveChildren: true)
        let currentRoot = LazyRaceNode("current-root")
        let staleProbe = LazyRaceProbe(immediateRoots: [staleRoot])
        let currentProbe = LazyRaceProbe(immediateRoots: [currentRoot])
        await staleProbe.succeedChildren(of: staleRoot.id, with: [staleChild])
        let trigger = LazyRaceResetTrigger(triggerID: staleChild.id)
        let staleProvider = FileTreeChildrenProvider<LazyRaceNode>(
            roots: { try await staleProbe.loadRoots() },
            mightHaveChildren: { node in
                MainActor.assumeIsolated { trigger.classify(node) }
            },
            children: { try await staleProbe.loadChildren(of: $0) }
        )
        let model = FileTreeModel(childrenProvider: staleProvider)
        trigger.install(
            model: model,
            replacementProvider: makeProvider(probe: currentProbe)
        )
        _ = try await model.loadRoots()

        await #expect(throws: CancellationError.self) {
            try await model.loadChildren(of: staleRoot.id)
        }
        #expect(trigger.didReset)
        #expect(model.rootLoadState == .unloaded)
        #expect(model.preparedTree.count == 0)

        #expect(try await model.loadRoots() == [currentRoot])
        #expect(model.preparedTree.nodes.map(\.id) == [currentRoot.id])
        #expect(await staleProbe.childCalls(for: staleRoot.id) == 1)
        #expect(await currentProbe.rootCalls() == 1)
    }

    @Test
    func replacingTheProviderStartsANewGenerationAndIgnoresTheOldRoots() async throws {
        let staleRoot = LazyRaceNode("stale-root")
        let currentRoot = LazyRaceNode("current-root")
        let oldProbe = LazyRaceProbe()
        let newProbe = LazyRaceProbe()
        let model = makeModel(probe: oldProbe)

        let oldLoad = Task { try await model.loadRoots() }
        try await waitForRootCalls(1, in: oldProbe)

        model.reset(
            childrenProvider: makeProvider(probe: newProbe),
            initialExpansion: .collapsed,
            initialSelection: []
        )
        #expect(model.preparedTree.count == 0)
        #expect(model.rootLoadState == .unloaded)

        let newLoad = Task { try await model.loadRoots() }
        try await waitForRootCalls(1, in: newProbe)
        await newProbe.succeedRoots(with: [currentRoot])
        #expect(try await newLoad.value == [currentRoot])

        await oldProbe.succeedRoots(with: [staleRoot])
        await #expect(throws: CancellationError.self) {
            try await oldLoad.value
        }
        await settleScheduler()

        #expect(model.preparedTree.nodes.map(\.id) == [currentRoot.id])
        #expect(model.visibleRows.map(\.id) == [currentRoot.id])
        #expect(model.rootLoadState == .loaded)
        #expect(await oldProbe.rootCalls() == 1)
        #expect(await newProbe.rootCalls() == 1)
    }

    @Test
    func staleRootFailureAfterProviderReplacementCannotPublishIntoTheNewGeneration() async throws {
        let currentRoot = LazyRaceNode("current-root")
        let oldProbe = LazyRaceProbe()
        let newProbe = LazyRaceProbe(immediateRoots: [currentRoot])
        let model = makeModel(probe: oldProbe)

        let oldLoad = Task { try await model.loadRoots() }
        try await waitForRootCalls(1, in: oldProbe)
        model.reset(
            childrenProvider: makeProvider(probe: newProbe),
            initialExpansion: .collapsed,
            initialSelection: []
        )
        #expect(try await model.loadRoots() == [currentRoot])
        let revisionAfterReplacement = model.revision
        let dataRevisionAfterReplacement = model.dataRevision
        let loadRevisionAfterReplacement = model.loadRevision

        await oldProbe.failRoots(with: .rejected("obsolete"))
        await #expect(throws: CancellationError.self) {
            try await oldLoad.value
        }
        await settleScheduler()

        #expect(model.preparedTree.nodes.map(\.id) == [currentRoot.id])
        #expect(model.visibleRows.map(\.id) == [currentRoot.id])
        #expect(model.rootLoadState == .loaded)
        #expect(model.revision == revisionAfterReplacement)
        #expect(model.dataRevision == dataRevisionAfterReplacement)
        #expect(model.loadRevision == loadRevisionAfterReplacement)
        #expect(await oldProbe.rootCalls() == 1)
        #expect(await newProbe.rootCalls() == 1)
    }

    @Test
    func resetBeforeAQueuedRootOperationCommitsKeepsTheReplacementGeneration() async throws {
        let staleRoot = LazyRaceNode("stale-root")
        let currentRoot = LazyRaceNode("current-root")
        let oldProbe = LazyRaceProbe(immediateRoots: [staleRoot])
        let newProbe = LazyRaceProbe(immediateRoots: [currentRoot])
        let model = makeModel(probe: oldProbe)

        model.startLazyRootLoadingIfNeeded()
        model.reset(
            childrenProvider: makeProvider(probe: newProbe),
            initialExpansion: .collapsed,
            initialSelection: []
        )

        #expect(try await model.loadRoots() == [currentRoot])
        await settleScheduler()

        #expect(await oldProbe.rootCalls() == 0)
        #expect(await newProbe.rootCalls() == 1)
        #expect(model.preparedTree.nodes.map(\.id) == [currentRoot.id])
    }

    @Test
    func unrelatedBranchCompletionPreservesSelectionFocusAndNestedExpansion() async throws {
        let left = LazyRaceNode("left", mightHaveChildren: true)
        let nested = LazyRaceNode("nested", mightHaveChildren: true)
        let selectedLeaf = LazyRaceNode("selected-leaf")
        let right = LazyRaceNode("right", mightHaveChildren: true)
        let rightChild = LazyRaceNode("right-child")
        let probe = LazyRaceProbe(immediateRoots: [left, right])
        let model = makeModel(probe: probe)
        _ = try await model.loadRoots()

        model.expand(left.id)
        try await waitForChildCalls(1, of: left.id, in: probe)
        await probe.succeedChildren(of: left.id, with: [nested])
        try await waitForChildren(of: left.id, in: model, toReach: .loaded)

        model.expand(nested.id)
        try await waitForChildCalls(1, of: nested.id, in: probe)
        await probe.succeedChildren(of: nested.id, with: [selectedLeaf])
        try await waitForChildren(of: nested.id, in: model, toReach: .loaded)
        model.select(selectedLeaf.id)

        model.expand(right.id)
        try await waitForChildCalls(1, of: right.id, in: probe)
        await probe.succeedChildren(of: right.id, with: [rightChild])
        try await waitForChildren(of: right.id, in: model, toReach: .loaded)

        #expect(model.expandedIDs == [left.id, nested.id, right.id])
        #expect(model.selection == [selectedLeaf.id])
        #expect(model.focusedID == selectedLeaf.id)
        #expect(
            model.visibleRows.map(\.id)
                == [left.id, nested.id, selectedLeaf.id, right.id, rightChild.id]
        )
        #expect(model.childrenLoadState(for: left.id) == .loaded)
        #expect(model.childrenLoadState(for: nested.id) == .loaded)
    }

    @Test
    func internalLazyTaskDoesNotKeepADiscardedModelAlive() async throws {
        let root = LazyRaceNode("root", mightHaveChildren: true)
        let child = LazyRaceNode("child")
        let probe = LazyRaceProbe(immediateRoots: [root])
        let provider = makeProvider(probe: probe)
        var model: FileTreeModel<LazyRaceNode>? = FileTreeModel(
            childrenProvider: provider,
            searchText: \LazyRaceNode.id
        )
        _ = try await model?.loadRoots()
        model?.expand(root.id)
        try await waitForChildCalls(1, of: root.id, in: probe)

        weak var weakModel = model
        model = nil
        await settleScheduler()

        #expect(weakModel == nil)

        await probe.succeedChildren(of: root.id, with: [child])
        await settleScheduler()
        #expect(weakModel == nil)
    }

    @Test
    func discardingModelCancelsRendererStartedProviderOperation() async throws {
        let gate = LazyRaceCancellationGate()
        let provider = FileTreeChildrenProvider<LazyRaceNode>(
            roots: { try await gate.loadRoots() },
            mightHaveChildren: { $0.mightHaveChildren },
            children: { _ in [] }
        )
        var model: FileTreeModel<LazyRaceNode>? = FileTreeModel(
            childrenProvider: provider,
            searchText: \LazyRaceNode.id
        )

        model?.startLazyRootLoadingIfNeeded()
        try await waitForRootsToStart(in: gate)

        weak var weakModel = model
        model = nil
        try await waitForCancellation(in: gate)

        #expect(weakModel == nil)
        #expect(await gate.rootCalls() == 1)
    }

    @Test
    func resetDuringRootSearchTextRejectsTheStaleSnapshotTransaction() async throws {
        let oldRoot = LazyRaceNode(
            "shared-root",
            mightHaveChildren: true,
            searchValue: "old-root"
        )
        let replacementRoot = LazyRaceNode(
            "shared-root",
            searchValue: "replacement-root"
        )
        let replacementChild = LazyRaceNode("replacement-child")
        let replacementTree = try PreparedTree(roots: [replacementRoot]) { node in
            node.id == replacementRoot.id ? [replacementChild] : []
        }
        let probe = LazyRaceProbe(immediateRoots: [oldRoot])
        let trigger = LazyRaceSearchResetTrigger(triggerValue: oldRoot.searchValue)
        let model = FileTreeModel(
            childrenProvider: makeProvider(probe: probe),
            initialExpansion: .expanded,
            searchText: { trigger.searchText(for: $0) }
        )
        trigger.install(model: model, replacementTree: replacementTree)
        model.openSearch(initialQuery: "replacement-root")

        await #expect(throws: CancellationError.self) {
            try await model.loadRoots()
        }

        #expect(trigger.didReset)
        #expect(model.preparedTree.nodes.map(\.searchValue) == [
            replacementRoot.searchValue,
            replacementChild.searchValue,
        ])
        #expect(model.matchingIDs == [replacementRoot.id])
        #expect(model.expandedIDs.isEmpty)
    }

    @Test
    func resetDuringChildSearchTextRejectsTheStaleSnapshotTransaction() async throws {
        let root = LazyRaceNode("root", mightHaveChildren: true)
        let oldChild = LazyRaceNode("shared-child", searchValue: "old-child")
        let replacementRoot = LazyRaceNode("root", searchValue: "replacement-root")
        let replacementChild = LazyRaceNode(
            "shared-child",
            searchValue: "replacement-child"
        )
        let replacementTree = try PreparedTree(roots: [replacementRoot]) { node in
            node.id == replacementRoot.id ? [replacementChild] : []
        }
        let probe = LazyRaceProbe(immediateRoots: [root])
        await probe.succeedChildren(of: root.id, with: [oldChild])
        let trigger = LazyRaceSearchResetTrigger(triggerValue: oldChild.searchValue)
        let model = FileTreeModel(
            childrenProvider: makeProvider(probe: probe),
            searchText: { trigger.searchText(for: $0) }
        )
        trigger.install(model: model, replacementTree: replacementTree)
        model.openSearch(initialQuery: "replacement-child")
        _ = try await model.loadRoots()
        model.expand(root.id)

        await #expect(throws: CancellationError.self) {
            try await model.loadChildren(of: root.id)
        }

        #expect(trigger.didReset)
        #expect(model.preparedTree.nodes.map(\.searchValue) == [
            replacementRoot.searchValue,
            replacementChild.searchValue,
        ])
        #expect(model.matchingIDs == [replacementChild.id])
        #expect(model.expandedIDs.isEmpty)
    }
}
