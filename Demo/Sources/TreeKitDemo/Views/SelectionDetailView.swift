import SwiftUI
import TreeKit

@MainActor
struct SelectionDetailView: View {
  @ObservedObject var model: FileTreeModel<FileTreePath>
  let renderer: DemoRenderer

  private var selectedNodes: [FileTreePath] {
    model.preparedTree.nodes.filter { model.selection.contains($0.id) }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        rendererHeader

        if let node = selectedNodes.first {
          selectedNode(node)
        } else {
          VStack(spacing: 10) {
            Image(systemName: "cursorarrow.click")
              .font(.system(size: 34))
              .foregroundStyle(.secondary)
            Text("No Selection")
              .font(.title3.weight(.semibold))
            Text("Select a row in either renderer to inspect it here.")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, minHeight: 260)
        }

        modelSummary
        usageCard
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(28)
    }
    .background(.background)
  }

  private var rendererHeader: some View {
    HStack(spacing: 10) {
      Image(systemName: renderer == .swiftUI ? "swift" : "macwindow")
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 2) {
        Text(renderer == .swiftUI ? "SwiftUI renderer" : "Native AppKit renderer")
          .font(.headline)
        Text(
          "\(DemoData.repository) PR #\(DemoData.pullRequest) · "
            + "\(DemoData.changedFileCount.formatted()) changed files"
        )
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Label("Live", systemImage: "circle.fill")
        .font(.caption.weight(.medium))
        .foregroundStyle(.green)
    }
  }

  private func selectedNode(_ node: FileTreePath) -> some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 14) {
        Image(systemName: node.demoSymbolName(isExpanded: model.expandedIDs.contains(node.id)))
          .font(.system(size: 30, weight: .medium))
          .foregroundStyle(node.demoIconColor)
          .frame(width: 44, height: 44)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

        VStack(alignment: .leading, spacing: 3) {
          Text(node.name)
            .font(.title2.weight(.semibold))
            .lineLimit(1)
          Text(node.path)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
      }

      VStack(spacing: 0) {
        metadataRow("Kind", value: node.kind == .directory ? "Directory" : "File")
        Divider()
        metadataRow(
          "Depth",
          value: String(model.preparedTree.depth(of: node.id) ?? 0)
        )
        Divider()
        metadataRow(
          "Children",
          value: String(model.preparedTree.children(of: node.id).count)
        )
        Divider()
        metadataRow(
          "Git status",
          value: DemoData.gitStatuses[node.id]?.title ?? "Unchanged"
        )
      }
      .padding(.horizontal, 14)
      .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }
  }

  private var modelSummary: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Shared model state")
        .font(.headline)

      HStack(spacing: 10) {
        metricCard(value: model.preparedTree.count, label: "Nodes")
        metricCard(value: model.visibleRows.count, label: "Visible")
        metricCard(value: model.expandedIDs.count, label: "Expanded")
        metricCard(value: model.selection.count, label: "Selected")
      }
    }
  }

  private var usageCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Mounted API")
          .font(.headline)
        Spacer()
        Text(renderer.componentName)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text(renderer == .swiftUI ? swiftUISnippet : appKitSnippet)
        .font(.system(.callout, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }
  }

  private func metadataRow(_ label: String, value: String) -> some View {
    HStack {
      Text(label)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .fontWeight(.medium)
    }
    .padding(.vertical, 9)
  }

  private func metricCard(value: Int, label: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(value, format: .number)
        .font(.title3.weight(.semibold))
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
  }

  private var swiftUISnippet: String {
    """
    FileTree(model: model) { node, context in
        ProjectRow(node: node, context: context)
    }
    """
  }

  private var appKitSnippet: String {
    """
    let treeView = FileTreeView(
        model: model,
        configuration: configuration
    )
    """
  }
}
