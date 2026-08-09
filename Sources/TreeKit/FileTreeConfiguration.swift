import CoreGraphics

/// Native selection behavior shared by SwiftUI, AppKit, and UIKit renderers.
public enum FileTreeSelectionMode: Equatable, Sendable {
    case single
    case multiple
}

/// A platform-neutral visual role for the native tree surface.
public enum FileTreeAppearance: Equatable, Sendable {
    case plain
    case sourceList
}

/// Platform-neutral scroll content insets.
public struct FileTreeEdgeInsets: Equatable, Sendable {
    public var top: CGFloat
    public var leading: CGFloat
    public var bottom: CGFloat
    public var trailing: CGFloat

    public init(
        top: CGFloat = 0,
        leading: CGFloat = 0,
        bottom: CGFloat = 0,
        trailing: CGFloat = 0
    ) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }
}

/// Rendering and interaction options shared by every platform adapter.
///
/// Fixed-height rows are intentional: AppKit and UIKit can then reuse only mounted rows and
/// scroll without measuring the complete hierarchy.
public struct FileTreeConfiguration: Equatable, Sendable {
    /// The native default: compact on macOS and touch-sized on iOS.
    public static let defaultRowHeight: CGFloat = {
#if canImport(UIKit)
        44
#else
        22
#endif
    }()

    public var appearance: FileTreeAppearance
    public var rowHeight: CGFloat
    public var indentation: CGFloat
    public var contentInsets: FileTreeEdgeInsets
    public var selectionMode: FileTreeSelectionMode
    public var allowsEmptySelection: Bool
    public var expandsBranchesOnDoubleClick: Bool
    public var showsSeparators: Bool

    public init(
        appearance: FileTreeAppearance = .sourceList,
        rowHeight: CGFloat = FileTreeConfiguration.defaultRowHeight,
        indentation: CGFloat = 13,
        contentInsets: FileTreeEdgeInsets = .init(top: 4, bottom: 4),
        selectionMode: FileTreeSelectionMode = .multiple,
        allowsEmptySelection: Bool = true,
        expandsBranchesOnDoubleClick: Bool = true,
        showsSeparators: Bool = false
    ) {
        self.appearance = appearance
        self.rowHeight = max(1, rowHeight)
        self.indentation = max(0, indentation)
        self.contentInsets = contentInsets
        self.selectionMode = selectionMode
        self.allowsEmptySelection = allowsEmptySelection
        self.expandsBranchesOnDoubleClick = expandsBranchesOnDoubleClick
        self.showsSeparators = showsSeparators
    }
}
