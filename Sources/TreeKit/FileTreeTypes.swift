import Foundation

/// One canonical item represented inside a visible tree row.
///
/// Path-backed trees use multiple segments when a single-child directory chain is flattened.
/// The final segment owns row selection, focus, disclosure, and activation semantics.
public struct FileTreeRowSegment<ID: Hashable> {
    /// The canonical identity represented by this segment.
    public let id: ID

    /// The caller-facing label displayed for the segment.
    public let label: String

    /// Whether this segment owns the visible row's interaction identity.
    public let isTerminal: Bool

    internal init(id: ID, label: String, isTerminal: Bool) {
        self.id = id
        self.label = label
        self.isTerminal = isTerminal
    }
}

extension FileTreeRowSegment: Sendable where ID: Sendable {}

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

    /// Canonical items represented by this row, ordered from its head to terminal identity.
    public let segments: [FileTreeRowSegment<Node.ID>]

    public var id: Node.ID { node.id }

    /// Every canonical identity represented by the row.
    public var representedIDs: [Node.ID] { segments.map(\.id) }

    /// Labels that should be joined as one compact path when this row is flattened.
    public var displayedPathSegments: [String] { segments.map(\.label) }

    /// Whether multiple canonical directories are presented as one row.
    public var isFlattened: Bool { segments.count > 1 }
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

/// Controls how an active, nonempty search query changes the visible projection.
///
/// Search never mutates the model's canonical selection or expansion sets. These modes only
/// determine the effective expansion and filtering presented by ``FileTreeModel/visibleRows``
/// and the native renderers until the query is cleared or search is closed.
public enum FileTreeSearchMode: CaseIterable, Equatable, Hashable, Sendable {
    /// Preserves canonical expansion and additionally expands every matching branch and ancestor.
    case expandMatches

    /// Starts from a collapsed projection and expands only matching branches and their ancestors.
    /// Nonmatching siblings along those branches remain visible.
    case collapseNonMatches

    /// Shows only matching nodes and the ancestor rows required to retain hierarchy context.
    case hideNonMatches
}

/// The final alignment used by ``FileTreeModel/reveal(_:select:position:focus:)`` and
/// ``FileTreeModel/scrollTo(_:position:focus:)``.
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
    public let isSearchMatch: Bool
    /// Whether children are unknown, loading, failed, or fully available.
    public let childrenLoadState: FileTreeChildrenLoadState
    /// Whether this row currently owns the shared inline-rename editor.
    public let isRenaming: Bool
    public let segments: [FileTreeRowSegment<ID>]

    /// Every canonical identity represented by the row.
    public var representedIDs: [ID] { segments.map(\.id) }

    /// Labels that custom rows can join with their preferred path separator.
    public var displayedPathSegments: [String] { segments.map(\.label) }

    /// Whether multiple canonical directories are presented as one row.
    public var isFlattened: Bool { segments.count > 1 }

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
        isFocused: Bool,
        isSearchMatch: Bool,
        childrenLoadState: FileTreeChildrenLoadState = .loaded,
        isRenaming: Bool = false,
        segments: [FileTreeRowSegment<ID>]
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
        self.isSearchMatch = isSearchMatch
        self.childrenLoadState = childrenLoadState
        self.isRenaming = isRenaming
        self.segments = segments
    }
}

extension FileTreeRowContext: Sendable where ID: Sendable {}
