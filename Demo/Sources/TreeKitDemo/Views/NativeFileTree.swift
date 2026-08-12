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
      configuration: configuration,
      rowProvider: makeNativeRow(node:context:reusing:)
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
    treeView.rowProvider = makeNativeRow(node:context:reusing:)

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

  private func makeNativeRow(
    node: FileTreePath,
    context: FileTreeRowContext<String>,
    reusing reusableView: NSView?
  ) -> NSView {
    let row = (reusableView as? DemoNativeFileTreeRowView)
      ?? DemoNativeFileTreeRowView()
    row.update(
      node: node,
      context: context,
      icons: configuration.icons
    )
    return row
  }

  final class Coordinator {
    var focusRequest = 0
    var reloadRequest = 0
  }
}

@MainActor
private final class DemoNativeFileTreeRowView: NSView {
  private let iconView = NSImageView()
  private let nameField = NSTextField(labelWithString: "")
  private let unloadedView = NSImageView()
  private let progressView = NSProgressIndicator()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
    iconView.contentTintColor = .secondaryLabelColor

    nameField.translatesAutoresizingMaskIntoConstraints = false
    nameField.lineBreakMode = .byTruncatingMiddle

    unloadedView.translatesAutoresizingMaskIntoConstraints = false
    unloadedView.image = NSImage(
      systemSymbolName: "arrow.down.circle",
      accessibilityDescription: "Children load on expansion"
    )
    unloadedView.symbolConfiguration = NSImage.SymbolConfiguration(
      pointSize: 10,
      weight: .regular
    )
    unloadedView.contentTintColor = .secondaryLabelColor
    unloadedView.toolTip = "Children load when this folder expands"

    progressView.translatesAutoresizingMaskIntoConstraints = false
    progressView.style = .spinning
    progressView.controlSize = .small
    progressView.toolTip = "Loading children"

    addSubview(iconView)
    addSubview(nameField)
    addSubview(unloadedView)
    addSubview(progressView)
    NSLayoutConstraint.activate([
      iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: 16),
      iconView.heightAnchor.constraint(equalToConstant: 16),
      nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
      nameField.trailingAnchor.constraint(
        lessThanOrEqualTo: unloadedView.leadingAnchor,
        constant: -6
      ),
      nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
      unloadedView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      unloadedView.centerYAnchor.constraint(equalTo: centerYAnchor),
      unloadedView.widthAnchor.constraint(equalToConstant: 12),
      unloadedView.heightAnchor.constraint(equalToConstant: 12),
      progressView.centerXAnchor.constraint(equalTo: unloadedView.centerXAnchor),
      progressView.centerYAnchor.constraint(equalTo: unloadedView.centerYAnchor),
      progressView.widthAnchor.constraint(equalToConstant: 12),
      progressView.heightAnchor.constraint(equalToConstant: 12)
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("Use init(frame:)")
  }

  func update(
    node: FileTreePath,
    context: FileTreeRowContext<String>,
    icons: FileTreeIcons
  ) {
    nameField.stringValue = context.displayedPathSegments.joined(separator: " / ")
    let icon = icons.image(for: node, isExpanded: context.isExpanded)
    iconView.image = icon
    iconView.contentTintColor = icon?.isTemplate == true ? .secondaryLabelColor : nil

    unloadedView.isHidden = true
    progressView.isHidden = true
    progressView.stopAnimation(nil)
    guard node.kind == .directory else { return }

    switch context.childrenLoadState {
    case .unloaded:
      unloadedView.isHidden = false
    case .loading:
      progressView.isHidden = false
      progressView.startAnimation(nil)
    case .loaded:
      break
    }
  }
}
