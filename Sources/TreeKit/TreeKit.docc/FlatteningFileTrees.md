# Flatten Empty Directory Chains

Compress directory-only chains into one visible row while retaining every canonical path identity.

## Enable flattening

Set ``FileTreePathOptions/flattenEmptyDirectories`` when the model is created:

```swift
let model = try FileTreeModel<FileTreePath>(
    paths: paths,
    options: .init(flattenEmptyDirectories: true)
)
```

Change the projection at runtime without rebuilding the model:

```swift
model.setFlattenEmptyDirectories(false)
```

Flattening changes only the visible projection. The prepared hierarchy, path-mutation input,
selection, expansion, focus, and search state remain canonical. A chain stops at a file, a
directory with zero or multiple children, or a search boundary.

## Render a flattened row

The terminal directory owns the row's interaction identity. Its row context exposes all
represented directories as ordered ``FileTreeRowSegment`` values:

```swift
FileTree(model: model) { item, context in
    Text(context.displayedPathSegments.joined(separator: " / "))
}
```

Use ``FileTreeRowContext/representedIDs`` when caller-owned decoration data belongs to any
component in the chain. Selection, focus, disclosure, keyboard navigation, activation, and native
accessibility continue to target the terminal identity so SwiftUI, AppKit, and UIKit share the
same interaction semantics.

Search recomputes chains from the matching projection. Path mutations and
``FileTreeModel/resetPaths(_:options:preservingExpansion:preservingSelection:)`` install a new
canonical hierarchy first and then rebuild the flattened rows deterministically.

## Ownership boundary

TreeKit flattens and renders an already known path hierarchy. The caller still owns filesystem
enumeration, directory watching, persistence, authorization, and lazy child loading. Enabling
flattening never reads or changes the filesystem.
