import AppKit
import SwiftUI
import TreeKit

/// The smallest bridge needed to mount TreeKit's native AppKit component in this SwiftUI demo.
@MainActor
struct NativeFileTree: NSViewRepresentable {
  let model: FileTreeModel<FileTreePath>
  let configuration: FileTreeConfiguration
  let focusRequest: Int
  let reloadRequest: Int

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> FileTreeView<FileTreePath> {
    let treeView = FileTreeView(
      model: model,
      configuration: configuration
    )
    treeView.onActivate = activate
    context.coordinator.focusRequest = focusRequest
    context.coordinator.reloadRequest = reloadRequest
    return treeView
  }

  func updateNSView(_ treeView: FileTreeView<FileTreePath>, context: Context) {
    if treeView.model !== model {
      treeView.model = model
    }
    if treeView.configuration != configuration {
      treeView.configuration = configuration
    }
    treeView.onActivate = activate

    if context.coordinator.focusRequest != focusRequest {
      context.coordinator.focusRequest = focusRequest
      _ = treeView.focusTree()
    }
    if context.coordinator.reloadRequest != reloadRequest {
      context.coordinator.reloadRequest = reloadRequest
      let selectedIDs = model.selection.isEmpty ? nil : model.selection
      treeView.reloadRows(withIDs: selectedIDs)
    }
  }

  private func activate(_ node: FileTreePath) {
    model.reveal(node.id, position: .nearest)
  }

  final class Coordinator {
    var focusRequest = 0
    var reloadRequest = 0
  }
}
