# ``TreeKit``

Render stable, reusable file trees in SwiftUI, AppKit, and UIKit.

## Overview

TreeKit separates immutable hierarchy preparation from long-lived UI state:

1. Convert recursive nodes with ``PreparedTree`` or flat paths with
   ``prepareFileTree(paths:options:)``.
2. Keep a ``FileTreeModel`` alive while the component is mounted.
3. Render the model with SwiftUI ``FileTree`` or native ``FileTreeView``.

The model owns identity-based selection, expansion, focus, search, the visible preorder
projection, and reveal requests. Native controls own viewport reuse and platform interaction.
Custom renderers receive ``FileTreeRowContext`` and supply only row content.

```swift
let model = try FileTreeModel<FileTreePath>(
    paths: [
        "README.md",
        "Sources/TreeKit/FileTreeModel.swift",
        "Sources/TreeKit/SwiftUI/FileTree.swift"
    ],
    initialExpansion: .depth(1)
)
```

## Topics

### Preparing data

- ``PreparedTree``
- ``TreePreparationError``
- ``FileTreePath``
- ``FileTreePathOptions``
- ``FileTreePathError``
- ``prepareFileTree(paths:options:)``

### State and rows

- ``FileTreeModel``
- ``FileTreeVisibleRow``
- ``FileTreeRowContext``
- ``FileTreeInitialExpansion``
- ``FileTreeSearchMode``
- ``FileTreeScrollPosition``

### Rendering

- ``FileTree``
- ``FileTreeView``
- ``FileTreeDefaultRow``
- ``FileTreeConfiguration``
- ``FileTreeSelectionMode``
- ``FileTreeAppearance``
- ``FileTreeEdgeInsets``
