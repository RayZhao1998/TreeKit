import Combine
import SwiftUI
import TreeKit

@MainActor
struct DemoControlPanel: View {
  @ObservedObject var model: FileTreeModel<FileTreePath>
  @ObservedObject var lazyRaceController: DemoLazyRaceController
  let renderer: DemoRenderer
  let dataSource: DemoDataSource
  let allowsPathMutations: Bool
  @Binding var configuration: FileTreeConfiguration
  @Binding var rowStyle: DemoRowStyle
  let onFocusNativeTree: () -> Void
  let onReloadNativeRows: () -> Void
  @StateObject private var eventObserver: DemoEventObserver

  @State private var pathSort: DemoPathSort = .foldersFirst
  @State private var generatedSequence = 0
  @State private var latestGeneratedPath: String?

  init(
    model: FileTreeModel<FileTreePath>,
    lazyRaceController: DemoLazyRaceController,
    renderer: DemoRenderer,
    dataSource: DemoDataSource,
    allowsPathMutations: Bool,
    configuration: Binding<FileTreeConfiguration>,
    rowStyle: Binding<DemoRowStyle>,
    onFocusNativeTree: @escaping () -> Void,
    onReloadNativeRows: @escaping () -> Void
  ) {
    self.model = model
    self.lazyRaceController = lazyRaceController
    self.renderer = renderer
    self.dataSource = dataSource
    self.allowsPathMutations = allowsPathMutations
    _configuration = configuration
    _rowStyle = rowStyle
    self.onFocusNativeTree = onFocusNativeTree
    self.onReloadNativeRows = onReloadNativeRows
    let observer = DemoEventObserver(model: model)
    _eventObserver = StateObject(wrappedValue: observer)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Capability Lab")
        .font(.headline)

      configurationControls
      navigationControls
      if dataSource == .lazy {
        lazyRaceControls
      }
      mutationControls
      renameControls
      dragDropControls
      observationLog
    }
    .onAppear(perform: configureModel)
  }

  private func configureModel() {
    model.configureRenaming(.init(
      canRename: { !$0.path.hasPrefix(".github/") },
      onError: { eventObserver.record("Rename error · \($0.localizedDescription)") }
    ))
    model.configureDragAndDrop(.init(
      canDrag: { !$0.contains(where: { $0.path.hasPrefix(".github/") }) },
      canDrop: { proposal in
        !proposal.destinationPaths.contains(where: { $0.path.hasPrefix(".github/") })
      },
      onDropError: { eventObserver.record("Drop error · \($0.error.localizedDescription)") },
      openOnDropDelay: 0.45
    ))
  }

  private var configurationControls: some View {
    GroupBox("FileTreeConfiguration") {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 18) {
          Toggle("Source-list appearance", isOn: sourceListAppearanceBinding)
          Toggle("Multiple selection", isOn: multipleSelectionBinding)
        }
        .toggleStyle(.switch)

        if renderer == .swiftUI {
          Toggle(
            "Use built-in SwiftUI row",
            isOn: Binding(
              get: { rowStyle == .builtIn },
              set: { rowStyle = $0 ? .builtIn : .custom }
            )
          )
          .toggleStyle(.switch)
        }

        HStack(spacing: 14) {
          Picker("Icon set", selection: configurationBinding(\.icons.set)) {
            ForEach(FileTreeBuiltInIconSet.allCases, id: \.self) { iconSet in
              Text(iconSet.demoTitle).tag(iconSet)
            }
          }
          .pickerStyle(.menu)

          Toggle("Colored icons", isOn: configurationBinding(\.icons.colored))
            .toggleStyle(.switch)
            .disabled(configuration.icons.set != .complete)
        }

        Toggle(
          "Flatten empty directory chains",
          isOn: Binding(
            get: { model.flattenEmptyDirectories },
            set: { model.setFlattenEmptyDirectories($0) }
          )
        )
        .toggleStyle(.switch)

        valueSlider(
          "Row height",
          value: configurationBinding(\.rowHeight),
          range: 18...42
        )
        valueSlider(
          "Indentation",
          value: configurationBinding(\.indentation),
          range: 6...30
        )

        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
          GridRow {
            insetField("Top", keyPath: \.top)
            insetField("Leading", keyPath: \.leading)
          }
          GridRow {
            insetField("Bottom", keyPath: \.bottom)
            insetField("Trailing", keyPath: \.trailing)
          }
        }

        HStack(spacing: 14) {
          Toggle("Allow empty", isOn: configurationBinding(\.allowsEmptySelection))
          Toggle(
            "Double-click expands",
            isOn: configurationBinding(\.expandsBranchesOnDoubleClick)
          )
          Toggle("Separators", isOn: configurationBinding(\.showsSeparators))
        }
        .toggleStyle(.checkbox)
      }
      .padding(.top, 4)
    }
  }

  private var navigationControls: some View {
    GroupBox("Visible navigation and selection") {
      VStack(alignment: .leading, spacing: 9) {
        HStack(spacing: 7) {
          actionButton("First", systemImage: "arrow.up.to.line") {
            model.focusFirstItem()
          }
          actionButton("Previous", systemImage: "arrow.up") {
            model.focusPreviousItem()
          }
          actionButton("Parent", systemImage: "arrow.turn.up.left") {
            model.focusParentItem()
          }
          actionButton("Next", systemImage: "arrow.down") {
            model.focusNextItem()
          }
          actionButton("Last", systemImage: "arrow.down.to.line") {
            model.focusLastItem()
          }
        }

        HStack(spacing: 7) {
          Button("Nearest") {
            model.focusNearestItem()
          }
          Button("Scroll only") {
            model.scrollTo(DemoData.revealTarget, position: .center, focus: false)
          }
          Button("Select 2") {
            model.setSelection(Set(DemoData.paths.prefix(2)))
          }
          Button("Deselect") {
            model.deselectAll()
          }
        }

        HStack(spacing: 7) {
          Button("Focus native tree", action: onFocusNativeTree)
            .disabled(renderer != .appKit)
          Button("Reload selected rows", action: onReloadNativeRows)
            .disabled(renderer != .appKit)
        }
        .help("AppKit FileTreeView focusTree() and reloadRows(withIDs:)")
      }
      .controlSize(.small)
      .padding(.top, 4)
    }
  }

  private var mutationControls: some View {
    VStack(alignment: .leading, spacing: 6) {
      GroupBox("Path mutations") {
        VStack(alignment: .leading, spacing: 9) {
          HStack(spacing: 7) {
            Button("Add", action: addGeneratedFile)
            Button("Move", action: moveGeneratedFile)
              .disabled(latestGeneratedPath == nil)
            Button("Remove", action: removeGeneratedFile)
              .disabled(latestGeneratedPath == nil)
            Button("Atomic batch", action: applyBatch)
            Button("Reset fixture", action: resetFixture)
          }

          HStack {
            Picker("Path sort", selection: $pathSort) {
              ForEach(DemoPathSort.allCases) { sort in
                Text(sort.title).tag(sort)
              }
            }
            .pickerStyle(.menu)

            Button("Apply sort") {
              performMutation {
                try model.resetPaths(
                  DemoData.paths,
                  options: .init(sort: pathSort.treeKitValue)
                )
                latestGeneratedPath = nil
              }
            }
          }
        }
        .controlSize(.small)
        .padding(.top, 4)
      }
      .disabled(!allowsPathMutations)

      if !allowsPathMutations {
        Label(
          "Switch to Eager to edit the complete path fixture.",
          systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  private var lazyRaceControls: some View {
    GroupBox("Lazy loading races") {
      VStack(alignment: .leading, spacing: 9) {
        HStack(spacing: 7) {
          Button("Expand ×3", action: startCoalescedExpansion)
            .disabled(
              !model.preparedTree.contains(lazyRaceController.targetID)
                || model.childrenLoadState(for: lazyRaceController.targetID) != .unloaded
            )
            .help("Expand three times and join three callers to one provider operation")
          Button("Collapse loading") {
            model.collapse(lazyRaceController.targetID)
          }
          .disabled(
            model.childrenLoadState(for: lazyRaceController.targetID) != .loading
              || !model.expandedIDs.contains(lazyRaceController.targetID)
          )
          .help("Collapse without cancelling or discarding the in-flight result")
          Button("Reset provider", action: resetLazyProvider)
            .help("Install a new provider generation on the same model")
          Button(
            lazyRaceController.completionButtonTitle,
            action: lazyRaceController.completePendingLoad
          )
          .disabled(!lazyRaceController.hasPendingLoad)
          .help("Release the Demo provider even if its operation was cancelled")
        }

        VStack(alignment: .leading, spacing: 3) {
          Text(lazyTargetSummary)
          Text(
            "generation \(lazyRaceController.generation) · requests "
              + "\(lazyRaceController.currentRequestCount)/\(lazyRaceController.totalRequestCount) "
              + "current/total · provider calls "
              + "\(lazyRaceController.currentProviderCallCount)/"
              + "\(lazyRaceController.totalProviderCallCount)"
          )
          Text(
            "pending \(lazyRaceController.currentPendingCount) current, "
              + "\(lazyRaceController.stalePendingCount) stale · completed "
              + "\(lazyRaceController.acceptedRequestCount) accepted, "
              + "\(lazyRaceController.obsoleteRequestCount) stale, "
              + "\(lazyRaceController.failedRequestCount) failed"
          )
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)

        Label(lazyRaceController.lastOutcome, systemImage: "arrow.triangle.2.circlepath")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .controlSize(.small)
      .padding(.top, 4)
    }
  }

  private var lazyTargetSummary: String {
    let targetID = lazyRaceController.targetID
    guard model.preparedTree.contains(targetID) else {
      return "\(targetID) · roots \(model.rootLoadState.demoTitle)"
    }
    let expansion = model.expandedIDs.contains(targetID) ? "expanded" : "collapsed"
    return "\(targetID) · \(model.childrenLoadState(for: targetID).demoTitle) · \(expansion)"
  }

  private func startCoalescedExpansion() {
    let targetID = lazyRaceController.targetID
    guard model.preparedTree.contains(targetID) else { return }
    let requestGeneration = lazyRaceController.generation
    let requestCount = 3
    lazyRaceController.recordLoadRequests(requestCount, generation: requestGeneration)

    for _ in 0..<requestCount {
      model.expand(targetID)
    }
    for _ in 0..<requestCount {
      Task { @MainActor in
        do {
          _ = try await model.loadChildren(of: targetID)
          lazyRaceController.recordRequestCompletion(
            generation: requestGeneration,
            result: .accepted
          )
        } catch is CancellationError {
          lazyRaceController.recordRequestCompletion(
            generation: requestGeneration,
            result: .obsolete
          )
        } catch {
          lazyRaceController.recordRequestCompletion(
            generation: requestGeneration,
            result: .failed
          )
        }
      }
    }
  }

  private func resetLazyProvider() {
    model.reset(
      childrenProvider: lazyRaceController.makeReplacementProvider(),
      initialExpansion: .collapsed,
      initialSelection: []
    )
    Task { @MainActor in
      try? await model.loadRoots()
    }
  }

  private var observationLog: some View {
    GroupBox("Scoped observation") {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(eventObserver.events.enumerated()), id: \.offset) { _, event in
          Text(event)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1)
        }
        if eventObserver.events.isEmpty {
          Text("Selection, focus, and mutation events appear here.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    }
  }

  private var renameControls: some View {
    GroupBox("Inline rename") {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 7) {
          Button("Rename focused") {
            performMutation { try model.startRenaming() }
          }
          .disabled(model.focusedID == nil || model.renamingID != nil)

          Button("Cancel") {
            model.cancelRenaming()
          }
          .disabled(model.renamingID == nil)

          Button("Try invalid name") {
            performMutation { try model.commitRenaming("invalid/name") }
          }
          .disabled(model.renamingID == nil)
        }

        Text("Enter commits and Escape cancels in the native row editor. .github paths are protected by the Demo policy.")
          .font(.caption)
          .foregroundStyle(.secondary)

        if let error = model.renameError {
          Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
        } else if let renamingID = model.renamingID {
          Label("Editing \(renamingID)", systemImage: "pencil")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .controlSize(.small)
      .padding(.top, 4)
    }
  }

  private var dragDropControls: some View {
    GroupBox("Native drag and drop") {
      VStack(alignment: .leading, spacing: 8) {
        Text("Drag one selected row—or the current multi-selection—between rows. The top, middle, and bottom zones resolve to before, inside, and after; folders expand after a short hover.")
          .font(.caption)
          .foregroundStyle(.secondary)

        HStack(spacing: 7) {
          Button("Drop focused into Demo folder") {
            performMutation { try dropFocusedIntoDemoFolder() }
          }
          .disabled(model.focusedID == nil)

          Text(".github sources and destinations are protected by Demo policy.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .controlSize(.small)
      .padding(.top, 4)
    }
  }

  private var sourceListAppearanceBinding: Binding<Bool> {
    Binding(
      get: { configuration.appearance == .sourceList },
      set: { isSourceList in
        var next = configuration
        next.appearance = isSourceList ? .sourceList : .plain
        configuration = next
      }
    )
  }

  private var multipleSelectionBinding: Binding<Bool> {
    Binding(
      get: { configuration.selectionMode == .multiple },
      set: { allowsMultipleSelection in
        var next = configuration
        next.selectionMode = allowsMultipleSelection ? .multiple : .single
        configuration = next
      }
    )
  }

  private func configurationBinding<Value>(
    _ keyPath: WritableKeyPath<FileTreeConfiguration, Value>
  ) -> Binding<Value> {
    Binding(
      get: { configuration[keyPath: keyPath] },
      set: { value in
        var next = configuration
        next[keyPath: keyPath] = value
        configuration = next
      }
    )
  }

  private func insetBinding(
    _ keyPath: WritableKeyPath<FileTreeEdgeInsets, CGFloat>
  ) -> Binding<CGFloat> {
    Binding(
      get: { configuration.contentInsets[keyPath: keyPath] },
      set: { value in
        var next = configuration
        next.contentInsets[keyPath: keyPath] = value
        configuration = next
      }
    )
  }

  private func valueSlider(
    _ title: String,
    value: Binding<CGFloat>,
    range: ClosedRange<CGFloat>
  ) -> some View {
    HStack {
      Text(title)
        .frame(width: 82, alignment: .leading)
      Slider(value: value, in: range, step: 1)
      Text(value.wrappedValue, format: .number.precision(.fractionLength(0)))
        .font(.system(.caption, design: .monospaced))
        .frame(width: 24, alignment: .trailing)
    }
  }

  private func insetField(
    _ title: String,
    keyPath: WritableKeyPath<FileTreeEdgeInsets, CGFloat>
  ) -> some View {
    Stepper(value: insetBinding(keyPath), in: 0...30, step: 1) {
      HStack {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Text(Int(configuration.contentInsets[keyPath: keyPath]), format: .number)
          .font(.system(.caption, design: .monospaced))
      }
    }
  }

  private func actionButton(
    _ title: String,
    systemImage: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
    }
  }

  private func addGeneratedFile() {
    generatedSequence &+= 1
    let path = "_TreeKitDemo/Generated-\(generatedSequence).swift"
    performMutation {
      try model.add(path)
      latestGeneratedPath = path
      model.scrollTo(path, position: .center)
    }
  }

  private func moveGeneratedFile() {
    guard let source = latestGeneratedPath else { return }
    generatedSequence &+= 1
    let destination = "_TreeKitDemo/Moved-\(generatedSequence).swift"
    performMutation {
      try model.move(source, to: destination)
      latestGeneratedPath = destination
      model.scrollTo(destination, position: .center)
    }
  }

  private func removeGeneratedFile() {
    guard let path = latestGeneratedPath else { return }
    performMutation {
      try model.remove(path)
      latestGeneratedPath = nil
      model.focusNearestItem(to: path)
    }
  }

  private func applyBatch() {
    generatedSequence &+= 1
    let first = "_TreeKitDemo/Batch-\(generatedSequence)-A.swift"
    let second = "_TreeKitDemo/Batch-\(generatedSequence)-B.swift"
    performMutation {
      try model.batch([.add(path: first), .add(path: second)])
      latestGeneratedPath = second
      model.scrollTo(second, position: .center)
    }
  }

  private func resetFixture() {
    performMutation {
      try model.resetPaths(DemoData.paths)
      latestGeneratedPath = nil
      model.reveal(DemoData.initialSelection, position: .center)
    }
  }

  private func dropFocusedIntoDemoFolder() throws {
    guard let focusedID = model.focusedID else { return }
    let targetPath = "_TreeKitDemo/"
    if !model.preparedTree.contains(targetPath) {
      try model.add(targetPath, kind: .directory)
    }
    let session = try model.makeDragSession(startingAt: focusedID)
    try model.performDrop(
      session,
      target: .init(
        path: try FileTreePath(path: targetPath, kind: .directory),
        position: .inside
      )
    )
    model.expand(targetPath)
  }

  private func performMutation(_ action: () throws -> Void) {
    do {
      try action()
    } catch {
      eventObserver.record("Error · \(error.localizedDescription)")
    }
  }
}

private extension FileTreeBuiltInIconSet {
  var demoTitle: String {
    switch self {
    case .minimal: "Minimal"
    case .standard: "Standard"
    case .complete: "Complete"
    case .none: "None"
    }
  }
}

private extension FileTreeChildrenLoadState {
  var demoTitle: String {
    switch self {
    case .unloaded: "unloaded"
    case .loading: "loading"
    case .loaded: "loaded"
    }
  }
}

@MainActor
private final class DemoEventObserver: ObservableObject {
  @Published private(set) var events: [String] = []
  private var cancellables: Set<AnyCancellable> = []

  init(model: FileTreeModel<FileTreePath>) {
    model.selectionChanges
      .sink { [weak self] selection in
        self?.record("Selection · \(selection.count) item(s)")
      }
      .store(in: &cancellables)

    model.focusChanges
      .sink { [weak self] focusedID in
        self?.record("Focus · \(focusedID ?? "none")")
      }
      .store(in: &cancellables)

    model.mutationEvents
      .sink { [weak self] event in
        self?.record("Mutation · \(event.demoDescription)")
      }
      .store(in: &cancellables)

    model.renameEvents
      .sink { [weak self] event in
        self?.record("Rename · \(event.sourcePath.path) → \(event.destinationPath.path)")
      }
      .store(in: &cancellables)

    model.dragDropEvents
      .sink { [weak self] event in
        switch event {
        case .completed(let drop):
          self?.record("Drop · \(drop.moves.count) path(s) → \(drop.proposal.target.demoDescription)")
        case .failed(let failure):
          self?.record("Drop error · \(failure.error.localizedDescription)")
        }
      }
      .store(in: &cancellables)
  }

  func record(_ event: String) {
    guard events.first != event else { return }
    events.insert(event, at: 0)
    if events.count > 7 {
      events.removeLast(events.count - 7)
    }
  }
}

private extension FileTreePathMutationEvent {
  var demoDescription: String {
    switch self {
    case .add(let path): "add \(path.path)"
    case .remove(let path): "remove \(path.path)"
    case .move(let source, let destination): "move \(source.path) → \(destination.path)"
    case .batch(let events): "batch \(events.count) operation(s)"
    case .reset(let paths): "reset \(paths.count) explicit path(s)"
    }
  }
}

private extension FileTreeDropTarget {
  var demoDescription: String {
    let path = path?.path ?? "root"
    return "\(position.rawValue) \(path)"
  }
}
