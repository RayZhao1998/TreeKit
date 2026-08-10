# ``TreeKit``

Render stable, reusable file trees in SwiftUI, AppKit, and UIKit.

## Overview

TreeKit separates immutable hierarchy preparation from long-lived UI state:

1. Convert recursive nodes with ``PreparedTree`` or flat paths with
   ``prepareFileTree(paths:options:)``.
2. Keep a ``FileTreeModel`` alive while the component is mounted.
3. Render the model with SwiftUI ``FileTree`` or native ``FileTreeView``.

The model owns identity-based selection, expansion, focus, search, the visible preorder
projection, path-first mutation transactions, and reveal requests. Native controls own viewport
reuse and platform interaction. Custom renderers receive ``FileTreeRowContext`` and supply only
row content.

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
- ``FileTreePathMutation``
- ``FileTreePathMutationEvent``
- ``FileTreePathMutationError``
- ``FileTreeRenameConfiguration``
- ``FileTreeRenameEvent``
- ``FileTreeRenameError``
- ``FileTreeDragSession``
- ``FileTreeDropTarget``
- ``FileTreeDropPosition``
- ``FileTreeDropProposal``
- ``FileTreeDropMove``
- ``FileTreeDropEvent``
- ``FileTreeDropFailure``
- ``FileTreeDragDropEvent``
- ``FileTreeDragDropError``
- ``FileTreeDragDropConfiguration``
- ``prepareFileTree(paths:options:)``

### State and rows

- ``FileTreeModel``
- ``FileTreeVisibleRow``
- ``FileTreeRowSegment``
- ``FileTreeRowContext``
- ``FileTreeInitialExpansion``
- ``FileTreeSearchMode``
- ``FileTreeScrollPosition``

### Navigation and interaction

- <doc:NavigatingFileTrees>

### Flattening paths

- <doc:FlatteningFileTrees>

### Updating paths

- <doc:MutatingFileTrees>
- <doc:RenamingFileTrees>
- <doc:DraggingFileTrees>

### Rendering

- ``FileTree``
- ``FileTreeView``
- ``FileTreeDefaultRow``
- ``FileTreeConfiguration``
- ``FileTreeSelectionMode``
- ``FileTreeAppearance``
- ``FileTreeEdgeInsets``
