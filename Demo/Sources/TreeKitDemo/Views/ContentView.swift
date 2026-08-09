import SwiftUI
import TreeKit

@MainActor
struct ContentView: View {
  @StateObject private var model: FileTreeModel<FileTreePath>
  @State private var renderer = DemoRenderer.swiftUI

  private let configuration = FileTreeConfiguration(
    appearance: .sourceList,
    rowHeight: 26,
    indentation: 14,
    contentInsets: .init(top: 6, bottom: 6),
    selectionMode: .single,
    allowsEmptySelection: true
  )

  init() {
    _model = StateObject(wrappedValue: DemoData.makeModel())
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
  }

  private var commandBar: some View {
    HStack(spacing: 12) {
      Image(systemName: "point.3.connected.trianglepath.dotted")
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(.tint)

      VStack(alignment: .leading, spacing: 1) {
        Text("TreeKit")
          .font(.headline)
        Text("One model, native renderers")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 24)

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
      .help("Reveal the AppKit FileTreeView implementation")
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
          Text("Project Navigator")
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

      HStack(spacing: 7) {
        Circle()
          .fill(.green)
          .frame(width: 7, height: 7)
        Text("\(model.visibleRows.count) visible")
        Text("·")
          .foregroundStyle(.tertiary)
        Text("\(model.preparedTree.count) total")
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
