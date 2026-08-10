#if canImport(SwiftUI)
import SwiftUI

/// The built-in SwiftUI content for a ``FileTreePath`` row.
///
/// The native host continues to own indentation, disclosure, selection, keyboard navigation,
/// and virtualization. Replace this view with the row-builder initializer when a product needs
/// Git decorations, badges, menus, or other custom content.
public struct FileTreeDefaultRow: View {
    public let node: FileTreePath
    public let segments: [FileTreeRowSegment<String>]
    public let isExpanded: Bool
    public let icons: FileTreeIcons

    public init(
        node: FileTreePath,
        isExpanded: Bool = false,
        icons: FileTreeIcons = .complete
    ) {
        self.node = node
        self.segments = [
            FileTreeRowSegment(id: node.id, label: node.name, isTerminal: true)
        ]
        self.isExpanded = isExpanded
        self.icons = icons
    }

    public init(
        node: FileTreePath,
        segments: [FileTreeRowSegment<String>],
        isExpanded: Bool = false,
        icons: FileTreeIcons = .complete
    ) {
        self.node = node
        self.segments = segments
        self.isExpanded = isExpanded
        self.icons = icons
    }

    public var body: some View {
        HStack(spacing: 6) {
            FileTreeIconImage(node: node, isExpanded: isExpanded, icons: icons)
                .frame(width: 16, height: 16)
            Text(segments.map(\.label).joined(separator: " / "))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

#if canImport(AppKit)
import AppKit

/// A SwiftUI file tree with native AppKit virtualization and completely custom row content.
@MainActor
public struct FileTree<Node: Identifiable, RowContent: View>: NSViewRepresentable {
    private let model: FileTreeModel<Node>
    private let configuration: FileTreeConfiguration
    private let onActivate: (Node) -> Void
    private let row: (Node, FileTreeRowContext<Node.ID>) -> RowContent

    public init(
        model: FileTreeModel<Node>,
        configuration: FileTreeConfiguration = .init(),
        onActivate: @escaping (Node) -> Void = { _ in },
        @ViewBuilder row: @escaping (Node, FileTreeRowContext<Node.ID>) -> RowContent
    ) {
        self.model = model
        self.configuration = configuration
        self.onActivate = onActivate
        self.row = row
    }

    public func makeNSView(context: Context) -> FileTreeView<Node> {
        let view = FileTreeView(
            model: model,
            configuration: configuration,
            rowProvider: makeNativeRow(node:context:reusing:)
        )
        view.onActivate = onActivate
        return view
    }

    public func updateNSView(_ nsView: FileTreeView<Node>, context: Context) {
        if nsView.model !== model {
            nsView.model = model
        }
        if nsView.configuration != configuration {
            nsView.configuration = configuration
        }
        nsView.onActivate = onActivate
        nsView.rowProvider = makeNativeRow(node:context:reusing:)
    }

    private func makeNativeRow(
        node: Node,
        context: FileTreeRowContext<Node.ID>,
        reusing reusableView: NSView?
    ) -> NSView {
        let content = row(node, context)
        if let hostingView = reusableView as? NSHostingView<RowContent> {
            hostingView.rootView = content
            return hostingView
        }
        return NSHostingView(rootView: content)
    }
}

#elseif canImport(UIKit)
import UIKit

/// A SwiftUI file tree with native UIKit virtualization and completely custom row content.
@MainActor
public struct FileTree<Node: Identifiable, RowContent: View>: UIViewRepresentable {
    private let model: FileTreeModel<Node>
    private let configuration: FileTreeConfiguration
    private let onActivate: (Node) -> Void
    private let row: (Node, FileTreeRowContext<Node.ID>) -> RowContent

    public init(
        model: FileTreeModel<Node>,
        configuration: FileTreeConfiguration = .init(),
        onActivate: @escaping (Node) -> Void = { _ in },
        @ViewBuilder row: @escaping (Node, FileTreeRowContext<Node.ID>) -> RowContent
    ) {
        self.model = model
        self.configuration = configuration
        self.onActivate = onActivate
        self.row = row
    }

    public func makeUIView(context: Context) -> FileTreeView<Node> {
        let view = FileTreeView(
            model: model,
            configuration: configuration,
            rowProvider: makeNativeRow(node:context:reusing:)
        )
        view.onActivate = onActivate
        return view
    }

    public func updateUIView(_ uiView: FileTreeView<Node>, context: Context) {
        if uiView.model !== model {
            uiView.model = model
        }
        if uiView.configuration != configuration {
            uiView.configuration = configuration
        }
        uiView.onActivate = onActivate
        uiView.rowProvider = makeNativeRow(node:context:reusing:)
    }

    private func makeNativeRow(
        node: Node,
        context: FileTreeRowContext<Node.ID>,
        reusing reusableView: UIView?
    ) -> UIView {
        let configuration = UIHostingConfiguration {
            row(node, context)
        }
        .margins(.all, 0)

        if let contentView = reusableView as? (UIView & UIContentView) {
            contentView.configuration = configuration
            return contentView
        }
        return configuration.makeContentView()
    }
}
#endif

public extension FileTree where Node == FileTreePath, RowContent == FileTreeDefaultRow {
    /// Creates a path-backed tree using TreeKit's built-in file and folder row content.
    init(
        model: FileTreeModel<FileTreePath>,
        configuration: FileTreeConfiguration = .init(),
        onActivate: @escaping (FileTreePath) -> Void = { _ in }
    ) {
        self.init(
            model: model,
            configuration: configuration,
            onActivate: onActivate
        ) { node, context in
            FileTreeDefaultRow(
                node: node,
                segments: context.segments,
                isExpanded: context.isExpanded,
                icons: configuration.icons
            )
        }
    }
}
#endif
