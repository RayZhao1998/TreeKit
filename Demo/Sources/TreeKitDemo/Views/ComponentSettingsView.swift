import SwiftUI
import TreeKit

@MainActor
struct ComponentSettingsView: View {
  @ObservedObject var model: FileTreeModel<FileTreePath>
  @ObservedObject var lazyRaceController: DemoLazyRaceController
  let renderer: DemoRenderer
  let dataSource: DemoDataSource
  let allowsPathMutations: Bool
  @Binding var configuration: FileTreeConfiguration
  @Binding var rowStyle: DemoRowStyle
  let onFocusNativeTree: () -> Void
  let onReloadNativeRows: () -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        modelSummary
        DemoControlPanel(
          model: model,
          lazyRaceController: lazyRaceController,
          renderer: renderer,
          dataSource: dataSource,
          allowsPathMutations: allowsPathMutations,
          configuration: $configuration,
          rowStyle: $rowStyle,
          onFocusNativeTree: onFocusNativeTree,
          onReloadNativeRows: onReloadNativeRows
        )
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(24)
    }
    .background(.background)
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: "switch.2")
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 2) {
        Text("Component Settings")
          .font(.title3.weight(.semibold))
        Text(renderer.componentName)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
      }
      Spacer()
      Label("Live", systemImage: "circle.fill")
        .font(.caption.weight(.medium))
        .foregroundStyle(.green)
    }
  }

  private var modelSummary: some View {
    HStack(spacing: 10) {
      metricCard(value: model.preparedTree.count, label: "Nodes")
      metricCard(value: model.visibleRows.count, label: "Visible")
      metricCard(value: model.expandedIDs.count, label: "Expanded")
      metricCard(value: model.selection.count, label: "Selected")
    }
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
    .padding(11)
    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
  }
}
