import AppKit
import SwiftUI
import TreeKit

/// The smallest bridge needed to mount TreeKit's native AppKit component in this SwiftUI demo.
@MainActor
struct NativeFileTree: NSViewRepresentable {
  let model: FileTreeModel<FileTreePath>
  let configuration: FileTreeConfiguration

  func makeNSView(context: Context) -> FileTreeView<FileTreePath> {
    let treeView = FileTreeView(
      model: model,
      configuration: configuration
    )
    treeView.onActivate = activate
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
  }

  private func activate(_ node: FileTreePath) {
    model.reveal(node.id, position: .nearest)
  }
}
