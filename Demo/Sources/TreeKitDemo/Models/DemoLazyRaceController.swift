import Combine
import Foundation
import TreeKit

private enum DemoLazyProviderError: LocalizedError, Sendable {
  case rootsUnavailable
  case branchUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .rootsUnavailable:
      "Demo root request failed. Retry to continue."
    case .branchUnavailable(let id):
      "Demo branch \(id) failed. Retry the real row to continue."
    }
  }
}

/// A Demo-only provider harness that makes lazy-loading races visible and repeatable.
///
/// The selected branch deliberately ignores task cancellation until the user releases it. This
/// lets the Demo prove that a replaced provider generation cannot publish a late result.
@MainActor
final class DemoLazyRaceController: ObservableObject {
  private enum ProviderMode: Equatable, Sendable {
    case race
    case failRootsOnce
    case failTargetOnce
  }

  enum RequestResult {
    case accepted
    case obsolete
    case failed
  }

  private struct PendingLoad {
    let generation: Int
    let continuation: AsyncStream<[FileTreePath]>.Continuation
  }

  let targetID = DemoData.lazyRaceTarget

  @Published private(set) var generation = 0
  @Published private(set) var lastOutcome = "Ready"
  @Published private(set) var revision = 0

  private let catalog: PreparedTree<FileTreePath>
  private var pendingLoads: [PendingLoad] = []
  private var requestsByGeneration: [Int: Int] = [:]
  private var providerCallsByGeneration: [Int: Int] = [:]
  private var acceptedRequestsByGeneration: [Int: Int] = [:]
  private var obsoleteRequestsByGeneration: [Int: Int] = [:]
  private var failedRequestsByGeneration: [Int: Int] = [:]
  private var consumedRootFailureGenerations: Set<Int> = []
  private var consumedTargetFailureGenerations: Set<Int> = []

  init(catalog: PreparedTree<FileTreePath>) {
    self.catalog = catalog
  }

  deinit {
    for load in pendingLoads {
      load.continuation.finish()
    }
  }

  var currentRequestCount: Int {
    requestsByGeneration[generation, default: 0]
  }

  var totalRequestCount: Int {
    requestsByGeneration.values.reduce(0, +)
  }

  var currentProviderCallCount: Int {
    providerCallsByGeneration[generation, default: 0]
  }

  var totalProviderCallCount: Int {
    providerCallsByGeneration.values.reduce(0, +)
  }

  var currentPendingCount: Int {
    pendingLoads.count { $0.generation == generation }
  }

  var stalePendingCount: Int {
    pendingLoads.count { $0.generation != generation }
  }

  var acceptedRequestCount: Int {
    acceptedRequestsByGeneration.values.reduce(0, +)
  }

  var obsoleteRequestCount: Int {
    obsoleteRequestsByGeneration.values.reduce(0, +)
  }

  var failedRequestCount: Int {
    failedRequestsByGeneration.values.reduce(0, +)
  }

  var hasPendingLoad: Bool {
    !pendingLoads.isEmpty
  }

  var completionButtonTitle: String {
    stalePendingCount > 0 ? "Complete stale" : "Complete current"
  }

  func makeInitialProvider() -> FileTreeChildrenProvider<FileTreePath> {
    advanceGeneration(outcome: "Initial lazy provider installed", mode: .race)
  }

  func makeReplacementProvider() -> FileTreeChildrenProvider<FileTreePath> {
    advanceGeneration(outcome: "Provider replaced; old work is now stale", mode: .race)
  }

  func makeRootFailureProvider() -> FileTreeChildrenProvider<FileTreePath> {
    advanceGeneration(outcome: "Root failure scenario installed", mode: .failRootsOnce)
  }

  func makeChildFailureProvider() -> FileTreeChildrenProvider<FileTreePath> {
    advanceGeneration(outcome: "Branch failure scenario installed", mode: .failTargetOnce)
  }

  func recordLoadRequests(_ count: Int, generation requestGeneration: Int) {
    requestsByGeneration[requestGeneration, default: 0] += count
    lastOutcome = "Started \(count) requests for generation \(requestGeneration)"
    publishMetrics()
  }

  func recordRequestCompletion(
    generation requestGeneration: Int,
    result: RequestResult
  ) {
    switch result {
    case .accepted:
      acceptedRequestsByGeneration[requestGeneration, default: 0] += 1
      lastOutcome = "Current completion accepted and cached"
    case .obsolete:
      obsoleteRequestsByGeneration[requestGeneration, default: 0] += 1
      lastOutcome = "Stale completion ignored by the model"
    case .failed:
      failedRequestsByGeneration[requestGeneration, default: 0] += 1
      lastOutcome = "Provider request failed"
    }
    publishMetrics()
  }

  func completePendingLoad() {
    let generationToComplete = pendingLoads.first {
      $0.generation != generation
    }?.generation ?? pendingLoads.first?.generation
    guard let generationToComplete else { return }

    let loads = pendingLoads.filter { $0.generation == generationToComplete }
    pendingLoads.removeAll { $0.generation == generationToComplete }
    let wasStale = generationToComplete != generation
    lastOutcome = wasStale
      ? "Released stale generation \(generationToComplete)"
      : "Released current generation \(generationToComplete)"
    publishMetrics()

    let children = catalog.children(of: targetID)
    for load in loads {
      load.continuation.yield(children)
      load.continuation.finish()
    }
  }

  /// Finishes Demo-owned suspensions before ContentView discards its model.
  func prepareForModelReplacement() {
    guard !pendingLoads.isEmpty else { return }
    let loads = pendingLoads
    pendingLoads.removeAll()
    lastOutcome = "Released pending Demo work before replacing the model"
    publishMetrics()

    let children = catalog.children(of: targetID)
    for load in loads {
      load.continuation.yield(children)
      load.continuation.finish()
    }
  }

  private func advanceGeneration(
    outcome: String,
    mode: ProviderMode
  ) -> FileTreeChildrenProvider<FileTreePath> {
    generation &+= 1
    lastOutcome = "\(outcome) · generation \(generation)"
    publishMetrics()

    let providerGeneration = generation
    let catalog = catalog
    return FileTreeChildrenProvider(
      roots: { [weak self] in
        try await Task.sleep(for: .milliseconds(600))
        if mode == .failRootsOnce,
           await self?.consumeRootFailure(for: providerGeneration) == true
        {
          throw DemoLazyProviderError.rootsUnavailable
        }
        return catalog.roots
      },
      mightHaveChildren: { node in
        catalog.isExpandable(node.id)
      },
      children: { [weak self] node in
        if node.id == DemoData.lazyRaceTarget {
          if mode == .failTargetOnce,
             await self?.consumeTargetFailure(for: providerGeneration) == true
          {
            throw DemoLazyProviderError.branchUnavailable(node.id)
          }
          if mode != .race {
            try await Task.sleep(for: .milliseconds(350))
            return catalog.children(of: node.id)
          }
          guard let stream = await self?.makeTargetLoadStream(
            generation: providerGeneration
          ) else { return [] }
          // Detached waiting intentionally keeps this Demo provider non-cooperative after the
          // model cancels its operation. The user decides when the late value is delivered.
          return await Task.detached {
            for await children in stream {
              return children
            }
            return []
          }.value
        }
        try await Task.sleep(for: .milliseconds(350))
        return catalog.children(of: node.id)
      }
    )
  }

  private func consumeRootFailure(for providerGeneration: Int) -> Bool {
    guard consumedRootFailureGenerations.insert(providerGeneration).inserted else {
      return false
    }
    lastOutcome = "Root request failed for generation \(providerGeneration)"
    publishMetrics()
    return true
  }

  private func consumeTargetFailure(for providerGeneration: Int) -> Bool {
    guard consumedTargetFailureGenerations.insert(providerGeneration).inserted else {
      return false
    }
    lastOutcome = "Branch request failed for generation \(providerGeneration)"
    publishMetrics()
    return true
  }

  private func makeTargetLoadStream(
    generation providerGeneration: Int
  ) -> AsyncStream<[FileTreePath]> {
    providerCallsByGeneration[providerGeneration, default: 0] += 1
    lastOutcome = "Provider call suspended for generation \(providerGeneration)"
    publishMetrics()

    let (stream, continuation) = AsyncStream.makeStream(of: [FileTreePath].self)
    pendingLoads.append(.init(
      generation: providerGeneration,
      continuation: continuation
    ))
    publishMetrics()
    return stream
  }

  private func publishMetrics() {
    revision &+= 1
  }
}
