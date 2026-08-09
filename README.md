# TreeKit

TreeKit is a model-first file-tree rendering component for SwiftUI, AppKit, and UIKit.
It keeps hierarchy work out of row views, uses stable identities for state, and delegates
viewport reuse, keyboard behavior, and accessibility to native platform controls.

The interface takes its path-first ergonomics and prepared-input boundary from
[`@pierre/trees`](https://trees.software/). The AppKit renderer follows the same practical
direction as CodeEdit's project navigator: `NSOutlineView`, native selection, and reusable rows.

## Requirements

- Swift 6.1+
- macOS 13+
- iOS 16+

## Installation

For local development, add this package in Xcode or to `Package.swift`:

```swift
.package(path: "../TreeKit")
```

After publishing the repository, use its Git URL and a tagged version instead. Add the `TreeKit`
library product to the target's dependencies.

## Demo

`Demo/` is a standalone macOS SwiftPM app that depends on the package through a local path. It
shows a custom SwiftUI ``FileTree`` and the native AppKit ``FileTreeView`` using the same model.
Its bundled fixture contains all 2,188 changed files from
[`oven-sh/bun` PR #30412](https://diffshub.com/oven-sh/bun/pull/30412), including added,
modified, deleted, and renamed paths.

Build, stage, and launch it as a foreground app bundle from the repository root:

```sh
./script/build_and_run.sh
```

Use `./script/build_and_run.sh --verify` to launch and confirm the process. The included
`.codex/environments/environment.toml` exposes the same command as the Codex Run action.
The reproducible stress workload and measured CPU, memory, and effective update-rate baseline
are documented in [`Docs/Performance.md`](Docs/Performance.md).

## Path-first input

Build the hierarchy once, then keep the model alive for as long as the tree is mounted:

```swift
import TreeKit

let model = try FileTreeModel<FileTreePath>(
    paths: [
        "README.md",
        "Sources/TreeKit/FileTreeModel.swift",
        "Sources/TreeKit/SwiftUI/FileTree.swift",
        "Tests/TreeKitTests/PreparedTreeTests.swift"
    ],
    initialExpansion: .depth(1)
)
```

Paths are normalized and use `/` separators. Directory identities have a trailing `/`, so the
directory `Sources` is selected and expanded with the stable ID `Sources/`. Missing ancestors
are synthesized. Inputs must be relative; absolute paths and `..` traversal are rejected. The
default ordering is folders first, then lexicographic by component name.

Call `prepareFileTree(paths:options:)` directly when preparation and model construction happen
at different layers.

## SwiftUI: `FileTree`

`FileTree` uses the built-in file/folder row when its model contains `FileTreePath` values:

```swift
struct ProjectSidebar: View {
    let model: FileTreeModel<FileTreePath>

    var body: some View {
        FileTree(model: model) { item in
            open(item.path)
        }
    }
}
```

The native tree subscribes to the model directly. When a SwiftUI container owns the model but
does not render any of its published values, keep the reference in `@State` instead of observing
it from that whole container. Put counters, selection details, and other model-driven UI in small
`@ObservedObject` leaf views. This prevents a selection or reveal from needlessly updating the
entire surrounding layout and reconfiguring every mounted custom row.

Supply a row builder to replace only the row content. TreeKit still owns disclosure geometry,
indentation, selection hit testing, keyboard behavior, and reuse:

```swift
FileTree(model: model, onActivate: { item in
    open(item.path)
}) { item, context in
    HStack(spacing: 6) {
        Image(systemName: item.kind == .directory ? "folder" : "doc")
        Text(item.name)
        Spacer()
        if let status = gitStatus[item.id] {
            Text(status.label)
                .foregroundStyle(status.color)
        }
    }
    .opacity(context.isSelected ? 1 : 0.92)
}
```

## AppKit and UIKit: `FileTreeView`

The native name is the same on both platforms. Conditional compilation selects an `NSView`
subclass backed by `NSOutlineView` on macOS and a `UIView` subclass backed by
`UICollectionView` on iOS.

For `FileTreePath`, the default native row is available without a provider:

```swift
let treeView = FileTreeView(model: model)
treeView.onActivate = { item in
    open(item.path)
}
```

Native clients can provide reusable row views directly:

```swift
let treeView = FileTreeView(model: model) { item, context, reusableView in
#if canImport(AppKit)
    let label = (reusableView as? NSTextField) ?? NSTextField(labelWithString: "")
    label.stringValue = item.name
    return label
#else
    let label = (reusableView as? UILabel) ?? UILabel()
    label.text = item.name
    return label
#endif
}
```

`FileTreeRowContext` exposes stable identity, depth, sibling position, expansion, selection, and
focus state. Call `reloadRows(withIDs:)` after caller-owned decoration data changes without
rebuilding the hierarchy.

## Arbitrary node types

TreeKit does not require filesystem paths. Any `Identifiable` forest can be prepared while
preserving caller-provided root and sibling order:

```swift
struct ProjectNode: Identifiable {
    let id: UUID
    let title: String
    var children: [ProjectNode]
}

let prepared = try PreparedTree(roots: roots, children: \ProjectNode.children)
let model = FileTreeModel(prepared, initialExpansion: .collapsed)
```

Identifiers must be globally unique and stable. Duplicate identifiers and cycles are rejected
before a model is created.

## Model operations

`FileTreeModel` is the shared state boundary for every renderer:

```swift
model.select(id)
model.toggleSelection(of: id)
model.expand(id)
model.collapse(id)
model.toggleExpansion(of: id)
model.reveal(id, select: true, position: .center)
model.reset(nextPreparedTree)
```

Selection and expansion survive `reset` for retained identities by default. Removed identities
are pruned atomically before the mounted renderer observes the new data.

## Incremental path mutations

`FileTreeModel<FileTreePath>` also exposes the path-first mutation vocabulary used by
`@pierre/trees`. Every successful call installs a complete model transaction before emitting its
typed semantic event:

```swift
let mutationSubscription = model.onMutation { event in
    persist(event) // Retain this cancellable with the surrounding controller.
}

try model.add("Sources/TreeKit/NewRow.swift")
try model.remove("Tests/ObsoleteTests.swift")
try model.move("Sources/Old/", to: "Sources/New/")

try model.batch([
    .add(path: "Sources/Feature.swift"),
    .move(from: "README.md", to: "Docs/README.md"),
    .remove(path: "Legacy/")
])

try model.resetPaths(nextPaths)
```

`add`, `remove`, `move`, `batch`, and `resetPaths` normalize and validate paths before changing
the mounted tree. A batch is ordered and atomic: if any operation fails, the model publishes no
revision or mutation event. Moving a directory remaps valid selection, expansion, and focus IDs;
removals prune identities inside the removed subtree. The destination parent of a move must
already be a directory, and directory destinations retain the trailing `/` convention.

Subscribe through `mutationEvents`, or use `onMutation(_:handler:)` to filter by
`FileTreePathMutationEvent.Kind`. These events report in-memory intent for persistence, logging,
or adjacent UI. TreeKit never creates, deletes, or moves filesystem entries; the caller owns that
side effect and any rollback policy.

## Model-backed search

Search is shared `FileTreeModel` state, so SwiftUI, AppKit, and UIKit always render the same
projection. Queries are trimmed, normalized to `/` separators, and matched case-insensitively
against canonical paths for `FileTreePath` models:

```swift
model.openSearch(initialQuery: "sources\\treekit")

model.searchQuery       // "sources/treekit"
model.matchingIDs       // stable IDs in prepared preorder
model.isSearchOpen      // true

model.focusNextSearchMatch()
model.focusPreviousSearchMatch()
model.setSearchQuery("filetreeview")
model.closeSearch()
```

`FileTreeSearchMode` controls only the effective visible projection. Canonical selection and
expansion remain identity-based and are not rewritten when a query changes:

- `.expandMatches` preserves current expansion and additionally expands every match path.
- `.collapseNonMatches` starts from a collapsed projection and expands match paths, retaining
  nonmatching siblings as context.
- `.hideNonMatches`—the default—shows only matches and the ancestors required to preserve their
  hierarchy.

An open search with an empty query renders the normal expansion projection. In
`.hideNonMatches`, a nonempty query with no matches renders an empty tree. Custom rows can use
`context.isSearchMatch` for highlighting without recomputing the match.

For arbitrary node types, provide the searchable text once when the model is created:

```swift
let model = FileTreeModel(
    prepared,
    searchText: { $0.title }
)
```

## Performance contract

- `PreparedTree` indexes nodes, parents, ordered children, depth, and siblings in O(n) time and
  memory. It stores child arrays only for branches and derives sibling counts instead of retaining
  a redundant per-node index.
- Identity lookup and direct selection changes use hash indexes.
- Expanding or collapsing computes only the affected subtree, mutates one contiguous range, and
  refreshes shifted identity indexes. Complete resets and expansion-set replacements rebuild the
  visible projection once. Revealing a path expands all missing ancestors and inserts the newly
  visible branch in one projection update instead of rebuilding every visible row.
- AppKit and UIKit render only native mounted cells. SwiftUI custom content is hosted inside
  those reused cells rather than recursively constructing the entire tree.
- Row height is fixed by `FileTreeConfiguration`, avoiding whole-tree measurement during scroll.
- Search caches normalized node text once, preserves deterministic prepared preorder, and rebuilds
  only the shared visible projection when its query or mode changes.
- Path mutations stage validation away from mounted state, then install one prepared hierarchy and
  visible projection. Batches may validate ordered intermediate hierarchies, but publish only the
  final projection and one semantic event.

The package intentionally does not enumerate the filesystem, watch directories, or persist
state. The current 1.x model renders an already known hierarchy and can update it through
path-first mutations or complete reset. A compatible lazy-child design for much larger trees is described in
[`Docs/LazyLoading.md`](Docs/LazyLoading.md); it is a roadmap, not a currently shipped API.

## Design references

- [`@pierre/trees` documentation](https://trees.software/docs)
- [`@pierre/trees` prepared input](https://github.com/pierrecomputer/pierre/blob/main/packages/trees/src/preparedInput.ts)
- [`@pierre/trees` visible-row model](https://github.com/pierrecomputer/pierre/blob/main/packages/trees/src/model/publicTypes.ts)
- [CodeEdit project navigator](https://github.com/CodeEditApp/CodeEdit/tree/main/CodeEdit/Features/NavigatorArea/ProjectNavigator)
