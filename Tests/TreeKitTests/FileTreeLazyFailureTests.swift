import Testing
@testable import TreeKit

private struct LazyFailureNode: Identifiable, Equatable, Sendable {
    let id: String
    let mightHaveChildren: Bool

    init(_ id: String, mightHaveChildren: Bool = false) {
        self.id = id
        self.mightHaveChildren = mightHaveChildren
    }
}

private enum LazyFailureProbeError: Error, Equatable, Sendable {
    case offline(String)
}

private actor LazyFailureProbe {
    private enum Resolution: Sendable {
        case success([LazyFailureNode])
        case failure(LazyFailureProbeError)
    }

    private var rootCallCount = 0
    private var childCallCounts: [String: Int] = [:]
    private var queuedRootResolutions: [Resolution] = []
    private var queuedChildResolutions: [String: [Resolution]] = [:]
    private var pendingRoots: [CheckedContinuation<[LazyFailureNode], any Error>] = []
    private var pendingChildren: [
        String: [CheckedContinuation<[LazyFailureNode], any Error>]
    ] = [:]

    func loadRoots() async throws -> [LazyFailureNode] {
        rootCallCount += 1
        if !queuedRootResolutions.isEmpty {
            return try Self.value(from: queuedRootResolutions.removeFirst())
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingRoots.append(continuation)
        }
    }

    func loadChildren(of node: LazyFailureNode) async throws -> [LazyFailureNode] {
        childCallCounts[node.id, default: 0] += 1
        if var resolutions = queuedChildResolutions[node.id], !resolutions.isEmpty {
            let resolution = resolutions.removeFirst()
            queuedChildResolutions[node.id] = resolutions
            return try Self.value(from: resolution)
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingChildren[node.id, default: []].append(continuation)
        }
    }

    func enqueueRoots(_ roots: [LazyFailureNode]) {
        queuedRootResolutions.append(.success(roots))
    }

    func enqueueRootFailure(_ error: LazyFailureProbeError) {
        queuedRootResolutions.append(.failure(error))
    }

    func enqueueChildren(_ children: [LazyFailureNode], of id: String) {
        queuedChildResolutions[id, default: []].append(.success(children))
    }

    func enqueueChildFailure(_ error: LazyFailureProbeError, of id: String) {
        queuedChildResolutions[id, default: []].append(.failure(error))
    }

    func succeedRoots(with roots: [LazyFailureNode]) {
        let continuations = pendingRoots
        pendingRoots = []
        continuations.forEach { $0.resume(returning: roots) }
    }

    func succeedChildren(with children: [LazyFailureNode], of id: String) {
        let continuations = pendingChildren.removeValue(forKey: id) ?? []
        continuations.forEach { $0.resume(returning: children) }
    }

    func rootCalls() -> Int { rootCallCount }

    func childCalls(for id: String) -> Int { childCallCounts[id, default: 0] }

    private static func value(from resolution: Resolution) throws -> [LazyFailureNode] {
        switch resolution {
        case .success(let nodes):
            return nodes
        case .failure(let error):
            throw error
        }
    }
}

@MainActor
struct FileTreeLazyFailureTests {
    private func makeProvider(
        probe: LazyFailureProbe
    ) -> FileTreeChildrenProvider<LazyFailureNode> {
        FileTreeChildrenProvider(
            roots: { try await probe.loadRoots() },
            mightHaveChildren: { $0.mightHaveChildren },
            children: { try await probe.loadChildren(of: $0) }
        )
    }

    private func waitForRootCalls(_ count: Int, in probe: LazyFailureProbe) async throws {
        for _ in 0..<512 {
            if await probe.rootCalls() >= count { return }
            await Task.yield()
        }
        Issue.record("Root provider did not reach \(count) calls")
    }

    private func waitForChildCalls(
        _ count: Int,
        of id: String,
        in probe: LazyFailureProbe
    ) async throws {
        for _ in 0..<512 {
            if await probe.childCalls(for: id) >= count { return }
            await Task.yield()
        }
        Issue.record("Child provider for \(id) did not reach \(count) calls")
    }

    @Test
    func rootFailureIsRetainedUntilASuccessfulRetry() async throws {
        let root = LazyFailureNode("root")
        let failure = LazyFailureProbeError.offline("roots")
        let probe = LazyFailureProbe()
        await probe.enqueueRootFailure(failure)
        await probe.enqueueRoots([root])
        let model = FileTreeModel(childrenProvider: makeProvider(probe: probe))

        await #expect(throws: failure) {
            try await model.loadRoots()
        }
        guard case .failed(let storedFailure) = model.rootLoadState else {
            Issue.record("Expected a retained root failure")
            return
        }
        #expect(storedFailure.underlyingError as? LazyFailureProbeError == failure)
        #expect(model.preparedTree.count == 0)

        #expect(try await model.retryRoots() == [root])
        #expect(model.rootLoadState == .loaded)
        #expect(model.visibleRows.map(\.id) == [root.id])
        #expect(await probe.rootCalls() == 2)
    }

    @Test
    func childFailureStaysOnTheRealRowAndRetryPreservesInteractionState() async throws {
        let branch = LazyFailureNode("branch", mightHaveChildren: true)
        let sibling = LazyFailureNode("sibling")
        let child = LazyFailureNode("child")
        let failure = LazyFailureProbeError.offline("children")
        let probe = LazyFailureProbe()
        await probe.enqueueRoots([branch, sibling])
        await probe.enqueueChildFailure(failure, of: branch.id)
        await probe.enqueueChildren([child], of: branch.id)
        let model = FileTreeModel(childrenProvider: makeProvider(probe: probe))
        _ = try await model.loadRoots()
        model.select(sibling.id)
        model.expand(branch.id)

        await #expect(throws: failure) {
            try await model.loadChildren(of: branch.id)
        }
        guard case .failed(let storedFailure) = model.childrenLoadState(for: branch.id) else {
            Issue.record("Expected a retained child failure")
            return
        }
        #expect(storedFailure.underlyingError as? LazyFailureProbeError == failure)
        #expect(model.preparedTree.nodes.map(\.id) == [branch.id, sibling.id])
        #expect(model.selection == [sibling.id])
        #expect(model.focusedID == sibling.id)
        #expect(model.expandedIDs == [branch.id])

        #expect(try await model.retryChildren(of: branch.id) == [child])
        #expect(model.childrenLoadState(for: branch.id) == .loaded)
        #expect(model.preparedTree.nodes.map(\.id) == [branch.id, child.id, sibling.id])
        #expect(model.selection == [sibling.id])
        #expect(model.focusedID == sibling.id)
        #expect(model.expandedIDs == [branch.id])
        #expect(await probe.childCalls(for: branch.id) == 2)
    }

    @Test
    func repeatedRootRetryActionsJoinOneOperation() async throws {
        let root = LazyFailureNode("root")
        let failure = LazyFailureProbeError.offline("roots")
        let probe = LazyFailureProbe()
        await probe.enqueueRootFailure(failure)
        let model = FileTreeModel(childrenProvider: makeProvider(probe: probe))
        await #expect(throws: failure) {
            try await model.loadRoots()
        }

        let firstRetry = Task { try await model.retryRoots() }
        let secondRetry = Task { try await model.retryRoots() }
        try await waitForRootCalls(2, in: probe)
        #expect(await probe.rootCalls() == 2)
        await probe.succeedRoots(with: [root])

        #expect(try await firstRetry.value == [root])
        #expect(try await secondRetry.value == [root])
        #expect(model.rootLoadState == .loaded)
        #expect(await probe.rootCalls() == 2)
    }

    @Test
    func unrelatedBranchCompletionDoesNotRetryAFailedBranch() async throws {
        let failedBranch = LazyFailureNode("failed", mightHaveChildren: true)
        let successfulBranch = LazyFailureNode("successful", mightHaveChildren: true)
        let child = LazyFailureNode("child")
        let failure = LazyFailureProbeError.offline("failed branch")
        let probe = LazyFailureProbe()
        await probe.enqueueRoots([failedBranch, successfulBranch])
        await probe.enqueueChildFailure(failure, of: failedBranch.id)
        await probe.enqueueChildren([child], of: successfulBranch.id)
        let model = FileTreeModel(childrenProvider: makeProvider(probe: probe))
        _ = try await model.loadRoots()

        model.expand(failedBranch.id)
        await #expect(throws: failure) {
            try await model.loadChildren(of: failedBranch.id)
        }
        model.expand(successfulBranch.id)
        #expect(try await model.loadChildren(of: successfulBranch.id) == [child])

        #expect(await probe.childCalls(for: failedBranch.id) == 1)
        #expect(await probe.childCalls(for: successfulBranch.id) == 1)
        #expect(model.childrenLoadState(for: failedBranch.id).failure != nil)
    }

    @Test
    func repeatedChildRetryActionsJoinOneOperation() async throws {
        let branch = LazyFailureNode("branch", mightHaveChildren: true)
        let child = LazyFailureNode("child")
        let failure = LazyFailureProbeError.offline("branch")
        let probe = LazyFailureProbe()
        await probe.enqueueRoots([branch])
        await probe.enqueueChildFailure(failure, of: branch.id)
        let model = FileTreeModel(childrenProvider: makeProvider(probe: probe))
        _ = try await model.loadRoots()
        await #expect(throws: failure) {
            try await model.loadChildren(of: branch.id)
        }

        let firstRetry = Task { try await model.retryChildren(of: branch.id) }
        let secondRetry = Task { try await model.retryChildren(of: branch.id) }
        try await waitForChildCalls(2, of: branch.id, in: probe)
        #expect(await probe.childCalls(for: branch.id) == 2)
        await probe.succeedChildren(with: [child], of: branch.id)

        #expect(try await firstRetry.value == [child])
        #expect(try await secondRetry.value == [child])
        #expect(model.childrenLoadState(for: branch.id) == .loaded)
        #expect(await probe.childCalls(for: branch.id) == 2)
    }

    @Test
    func resetDuringRetryClearsFailureAndObsoletesTheWaiter() async throws {
        let failure = LazyFailureProbeError.offline("roots")
        let staleRoot = LazyFailureNode("stale")
        let replacement = LazyFailureNode("replacement")
        let probe = LazyFailureProbe()
        await probe.enqueueRootFailure(failure)
        let model = FileTreeModel(childrenProvider: makeProvider(probe: probe))
        await #expect(throws: failure) {
            try await model.loadRoots()
        }

        let retry = Task { try await model.retryRoots() }
        try await waitForRootCalls(2, in: probe)
        let replacementTree = try PreparedTree(roots: [replacement]) { _ in [] }
        model.reset(replacementTree)
        await probe.succeedRoots(with: [staleRoot])

        await #expect(throws: CancellationError.self) {
            try await retry.value
        }
        #expect(model.rootLoadState == .loaded)
        #expect(model.preparedTree.nodes.map(\.id) == [replacement.id])
    }
}
