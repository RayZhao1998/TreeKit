import Foundation

/// A projected row in the currently visible tree.
public struct FileTreeVisibleRow<Node: Identifiable>: Identifiable {
    /// The caller-owned node rendered by this row.
    public let node: Node

    /// The zero-based hierarchy depth.
    public let depth: Int

    /// The parent identifier, or `nil` for a root.
    public let parentID: Node.ID?

    /// The zero-based position among siblings.
    public let siblingIndex: Int

    /// The total number of siblings at this hierarchy level.
    public let siblingCount: Int

    public var id: Node.ID { node.id }
}

extension FileTreeVisibleRow: Sendable where Node: Sendable, Node.ID: Sendable {}

/// Controls the model's expansion state at initialization.
public enum FileTreeInitialExpansion<ID: Hashable> {
    /// Starts with every branch collapsed.
    case collapsed

    /// Starts with every branch expanded.
    case expanded

    /// Expands branches whose depth is less than this value.
    ///
    /// `.depth(1)` expands root branches, making their direct children visible.
    case depth(Int)

    /// Starts with exactly the supplied branch identifiers expanded.
    case identifiers(Set<ID>)
}

extension FileTreeInitialExpansion: Sendable where ID: Sendable {}

/// The final alignment used by ``FileTreeModel/reveal(_:select:position:focus:)``.
public enum FileTreeScrollPosition: Sendable {
    case nearest
    case center
    case top
}

internal struct FileTreeRevealRequest<ID: Hashable> {
    let sequence: UInt64
    let id: ID
    let position: FileTreeScrollPosition
    let focus: Bool
}

/// Read-only state supplied to a custom SwiftUI, AppKit, or UIKit row provider.
public struct FileTreeRowContext<ID: Hashable> {
    public let id: ID
    public let visibleIndex: Int
    public let depth: Int
    public let parentID: ID?
    public let siblingIndex: Int
    public let siblingCount: Int
    public let isExpandable: Bool
    public let isExpanded: Bool
    public let isSelected: Bool
    public let isFocused: Bool

    internal init(
        id: ID,
        visibleIndex: Int,
        depth: Int,
        parentID: ID?,
        siblingIndex: Int,
        siblingCount: Int,
        isExpandable: Bool,
        isExpanded: Bool,
        isSelected: Bool,
        isFocused: Bool
    ) {
        self.id = id
        self.visibleIndex = visibleIndex
        self.depth = depth
        self.parentID = parentID
        self.siblingIndex = siblingIndex
        self.siblingCount = siblingCount
        self.isExpandable = isExpandable
        self.isExpanded = isExpanded
        self.isSelected = isSelected
        self.isFocused = isFocused
    }
}

extension FileTreeRowContext: Sendable where ID: Sendable {}
