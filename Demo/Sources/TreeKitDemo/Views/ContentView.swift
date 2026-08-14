import Foundation
import SwiftUI
import TreeKit

@MainActor
struct ContentView: View {
  // FileTreeView observes the model directly. Keeping the reference in State preserves its
  // lifetime without invalidating this entire split view for every expansion or selection.
  @State private var model: FileTreeModel<FileTreePath>
  @StateObject private var lazyRaceController: DemoLazyRaceController
  @State private var renderer: DemoRenderer
  @State private var dataSource: DemoDataSource
  @State private var configuration: FileTreeConfiguration
  @State private var rowStyle: DemoRowStyle = .custom
  @State private var nativeFocusRequest = 0
  @State private var nativeReloadRequest = 0

  init() {
    let environment = ProcessInfo.processInfo.environment
    let dataSource = environment["TREEKIT_DEMO_DATA_SOURCE"]
      .flatMap(DemoDataSource.init(rawValue:)) ?? .eager
    let lazyRaceController = DemoData.makeLazyRaceController()
    _lazyRaceController = StateObject(wrappedValue: lazyRaceController)
    _model = State(initialValue: DemoData.makeModel(
      dataSource: dataSource,
      lazyRaceController: lazyRaceController
    ))
    _dataSource = State(initialValue: dataSource)
    let renderer = environment["TREEKIT_PERF_RENDERER"]
      .flatMap(DemoRenderer.init(rawValue:)) ?? .swiftUI
    _renderer = State(initialValue: renderer)
    _configuration = State(
      initialValue: FileTreeConfiguration(
        appearance: .sourceList,
        rowHeight: 26,
        indentation: 14,
        contentInsets: .init(top: 6, bottom: 6),
        selectionMode: .single,
        allowsEmptySelection: true
      )
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      commandBar
      Divider()

      HSplitView {
        treePane
          .frame(minWidth: 360, idealWidth: 430, maxWidth: 560)

        ComponentSettingsView(
          model: model,
          lazyRaceController: lazyRaceController,
          renderer: renderer,
          dataSource: dataSource,
          allowsPathMutations: dataSource == .eager,
          configuration: $configuration,
          rowStyle: $rowStyle,
          onFocusNativeTree: { nativeFocusRequest &+= 1 },
          onReloadNativeRows: { nativeReloadRequest &+= 1 }
        )
          .id(ObjectIdentifier(model))
          .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(minWidth: 860, minHeight: 560)
    .onChange(of: dataSource) { nextDataSource in
      lazyRaceController.prepareForModelReplacement()
      model = DemoData.makeModel(
        dataSource: nextDataSource,
        lazyRaceController: lazyRaceController
      )
    }
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

      Picker("Data source", selection: $dataSource) {
        ForEach(DemoDataSource.allCases) { source in
          Text(source.title).tag(source)
        }
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .frame(width: 124)
      .help(dataSource.summary)

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
      .disabled(!model.preparedTree.contains(DemoData.revealTarget))
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
          Text(dataSource.summary)
            .font(.caption2)
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

      TreeSearchBar(model: model)
        .id(ObjectIdentifier(model))

      Divider()

      treeSurface
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      Divider()

      TreeStatusBar(model: model, dataSource: dataSource)
    }
  }

  @ViewBuilder
  private var treeSurface: some View {
    switch renderer {
    case .swiftUI:
      if rowStyle == .builtIn {
        FileTree(
          model: model,
          configuration: configuration,
          onActivate: activate
        )
      } else {
        FileTree(
          model: model,
          configuration: configuration,
          onActivate: activate
        ) { node, context in
          CustomFileTreeRow(
            node: node,
            context: context,
            gitStatus: DemoData.gitStatuses[node.id],
            icons: configuration.icons
          )
        }
      }

    case .appKit:
      NativeFileTree(
        model: model,
        configuration: configuration,
        focusRequest: nativeFocusRequest,
        reloadRequest: nativeReloadRequest
      )
    }
  }

  private func activate(_ node: FileTreePath) {
    model.reveal(node.id, position: .nearest)
  }
}

@MainActor
private struct TreeSearchBar: View {
  @ObservedObject var model: FileTreeModel<FileTreePath>
  @State private var query = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)

      TextField("Search canonical paths", text: $query)
        .textFieldStyle(.plain)
        .focused($isFocused)
        .onChange(of: isFocused) { focused in
          if focused, !model.isSearchOpen {
            model.openSearch(initialQuery: query)
          }
        }
        .onChange(of: query) { value in
          guard model.isSearchOpen || !value.isEmpty else { return }
          model.setSearchQuery(value)
        }
        .onSubmit {
          model.focusNextSearchMatch()
        }

      if model.isSearchOpen {
        Text(model.matchingIDs.count.formatted())
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(model.matchingIDs.isEmpty ? .secondary : .primary)
          .accessibilityLabel("\(model.matchingIDs.count) matches")

        Button {
          model.focusPreviousSearchMatch()
        } label: {
          Image(systemName: "chevron.up")
        }
        .buttonStyle(.borderless)
        .disabled(model.matchingIDs.isEmpty)
        .help("Previous match")

        Button {
          model.focusNextSearchMatch()
        } label: {
          Image(systemName: "chevron.down")
        }
        .buttonStyle(.borderless)
        .disabled(model.matchingIDs.isEmpty)
        .help("Next match")

        Button {
          query = ""
          model.closeSearch()
          isFocused = false
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Close search")
      }

      Picker(
        "Search projection",
        selection: Binding(
          get: { model.searchMode },
          set: { model.setSearchMode($0) }
        )
      ) {
        ForEach(FileTreeSearchMode.allCases, id: \.self) { mode in
          Text(mode.demoTitle).tag(mode)
        }
      }
      .labelsHidden()
      .pickerStyle(.menu)
      .frame(width: 112)
    }
    .controlSize(.small)
    .padding(.horizontal, 12)
    .frame(height: 34)
    .background(.quaternary.opacity(0.35))
  }
}

@MainActor
private struct TreeStatusBar: View {
  @ObservedObject var model: FileTreeModel<FileTreePath>
  let dataSource: DemoDataSource

  var body: some View {
    HStack(spacing: 7) {
      if dataSource == .lazy, model.rootLoadState != .loaded {
        ProgressView()
          .controlSize(.mini)
      } else {
        Circle()
          .fill(.green)
          .frame(width: 7, height: 7)
      }
      Text(dataSource.title)
        .fontWeight(.medium)
      Text("·")
        .foregroundStyle(.tertiary)
      Text("\(model.visibleRows.count) visible")
      if model.isSearchOpen {
        Text("·")
          .foregroundStyle(.tertiary)
        Text("\(model.matchingIDs.count) matches")
      }
      Text("·")
        .foregroundStyle(.tertiary)
      Text("\(DemoData.changedFileCount.formatted()) changed files")
      Text("·")
        .foregroundStyle(.tertiary)
      Text("\(model.preparedTree.count.formatted()) nodes")
      Spacer()
      Text(dataSource == .lazy ? "on-demand model" : "shared model")
        .foregroundStyle(.secondary)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .frame(height: 30)
  }
}

private extension FileTreeSearchMode {
  var demoTitle: String {
    switch self {
    case .expandMatches: "Expand"
    case .collapseNonMatches: "Collapse"
    case .hideNonMatches: "Filter"
    }
  }
}
