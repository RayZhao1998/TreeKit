import Foundation
import SwiftUI
import TreeKit

@MainActor
struct ContentView: View {
  // FileTreeView observes the model directly. Keeping the reference in State preserves its
  // lifetime without invalidating this entire split view for every expansion or selection.
  @State private var model: FileTreeModel<FileTreePath>
  @State private var renderer: DemoRenderer

  private let configuration = FileTreeConfiguration(
    appearance: .sourceList,
    rowHeight: 26,
    indentation: 14,
    contentInsets: .init(top: 6, bottom: 6),
    selectionMode: .single,
    allowsEmptySelection: true
  )

  init() {
    _model = State(initialValue: DemoData.makeModel())
    let renderer = ProcessInfo.processInfo.environment["TREEKIT_PERF_RENDERER"]
      .flatMap(DemoRenderer.init(rawValue:)) ?? .swiftUI
    _renderer = State(initialValue: renderer)
  }

  var body: some View {
    VStack(spacing: 0) {
      commandBar
      Divider()

      HSplitView {
        treePane
          .frame(minWidth: 360, idealWidth: 430, maxWidth: 560)

        SelectionDetailView(model: model, renderer: renderer)
          .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(minWidth: 860, minHeight: 560)
    .task {
      await runPerformanceScenarioIfRequested()
    }
  }

  private func runPerformanceScenarioIfRequested() async {
    guard ProcessInfo.processInfo.environment["TREEKIT_PERF_AUTORUN"] == "1" else {
      return
    }

    let environment = ProcessInfo.processInfo.environment
    if let triggerPath = environment["TREEKIT_PERF_TRIGGER_FILE"] {
      while !FileManager.default.fileExists(atPath: triggerPath) {
        guard !Task.isCancelled else { return }
        try? await Task.sleep(for: .milliseconds(50))
      }
    } else {
      let delayMilliseconds = Int64(environment["TREEKIT_PERF_DELAY_MS"] ?? "1000") ?? 1000
      try? await Task.sleep(for: .milliseconds(max(0, delayMilliseconds)))
    }
    emitPerformanceLine(
      "TREEKIT_PERF_START renderer=\(renderer.rawValue) "
        + "targets=\(DemoData.performanceTargets.count)"
    )
    let clock = ContinuousClock()
    var updateTimes: [ContinuousClock.Instant] = []
    updateTimes.reserveCapacity(DemoData.performanceTargets.count)
    for target in DemoData.performanceTargets {
      guard !Task.isCancelled else { return }
      model.reveal(target, position: .center)
      await Task.yield()
      updateTimes.append(clock.now)
      try? await Task.sleep(for: .milliseconds(16))
    }
    let gaps = zip(updateTimes, updateTimes.dropFirst()).map {
      milliseconds(from: $0.duration(to: $1))
    }
    let elapsedMilliseconds = updateTimes.first.map { first in
      updateTimes.last.map { milliseconds(from: first.duration(to: $0)) } ?? 0
    } ?? 0
    let effectiveFPS = elapsedMilliseconds > 0
      ? Double(max(0, updateTimes.count - 1)) / (elapsedMilliseconds / 1_000)
      : 0
    emitPerformanceLine(
      String(
        format: "TREEKIT_PERF_RESULT renderer=%@ updates=%d elapsed_ms=%.2f effective_fps=%.2f gap_p95_ms=%.2f gap_max_ms=%.2f gaps_over_25ms=%d",
        renderer.rawValue,
        updateTimes.count,
        elapsedMilliseconds,
        effectiveFPS,
        percentile(gaps, 0.95),
        gaps.max() ?? 0,
        gaps.count { $0 > 25 }
      )
    )
  }

  private func milliseconds(from duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) * 1_000
      + Double(components.attoseconds) / 1_000_000_000_000_000
  }

  private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = Int((Double(sorted.count - 1) * fraction).rounded())
    return sorted[index]
  }

  private func emitPerformanceLine(_ line: String) {
    guard let data = (line + "\n").data(using: .utf8) else { return }
    try? FileHandle.standardOutput.write(contentsOf: data)
  }

  private var commandBar: some View {
    HStack(spacing: 12) {
      Image(systemName: "point.3.connected.trianglepath.dotted")
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(.tint)

      VStack(alignment: .leading, spacing: 1) {
        Text("TreeKit")
          .font(.headline)
        Text("\(DemoData.repository) · PR #\(DemoData.pullRequest)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 24)

      Link(destination: DemoData.sourceURL) {
        Label("PR #\(DemoData.pullRequest)", systemImage: "arrow.up.right.square")
      }

      Button {
        model.expandAll()
      } label: {
        Label("Expand All", systemImage: "rectangle.expand.vertical")
      }
      .help("Expand every directory")

      Button {
        model.collapseAll()
      } label: {
        Label("Collapse All", systemImage: "rectangle.compress.vertical")
      }
      .help("Collapse every directory")

      Button {
        model.reveal(DemoData.revealTarget, position: .center)
      } label: {
        Label("Reveal", systemImage: "scope")
      }
      .buttonStyle(.borderedProminent)
      .help("Reveal \(DemoData.revealTarget)")
    }
    .controlSize(.small)
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.bar)
  }

  private var treePane: some View {
    VStack(spacing: 0) {
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Changed Files")
            .font(.headline)
          Text(renderer.componentName)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
        }

        Spacer(minLength: 8)

        Picker("Renderer", selection: $renderer) {
          ForEach(DemoRenderer.allCases) { renderer in
            Text(renderer.title).tag(renderer)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 168)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 11)

      Divider()

      treeSurface
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()

      TreeStatusBar(model: model)
    }
  }

  @ViewBuilder
  private var treeSurface: some View {
    switch renderer {
    case .swiftUI:
      FileTree(
        model: model,
        configuration: configuration,
        onActivate: { node in
          model.reveal(node.id, position: .nearest)
        }
      ) { node, context in
        CustomFileTreeRow(
          node: node,
          context: context,
          gitStatus: DemoData.gitStatuses[node.id]
        )
      }

    case .appKit:
      NativeFileTree(model: model, configuration: configuration)
    }
  }
}

@MainActor
private struct TreeStatusBar: View {
  @ObservedObject var model: FileTreeModel<FileTreePath>

  var body: some View {
    HStack(spacing: 7) {
      Circle()
        .fill(.green)
        .frame(width: 7, height: 7)
      Text("\(model.visibleRows.count) visible")
      Text("·")
        .foregroundStyle(.tertiary)
      Text("\(DemoData.changedFileCount.formatted()) changed files")
      Text("·")
        .foregroundStyle(.tertiary)
      Text("\(model.preparedTree.count.formatted()) nodes")
      Spacer()
      Text("shared model")
        .foregroundStyle(.secondary)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .frame(height: 30)
  }
}
