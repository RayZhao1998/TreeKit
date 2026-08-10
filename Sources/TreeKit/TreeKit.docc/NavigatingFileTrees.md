# Navigate and Observe a File Tree

Route commands through the model's visible projection and observe focused interaction state
without depending on a native row index or the global revision.

## Navigate the visible projection

Focus identifies the row that receives the next command. It remains independent from selection,
which can contain zero, one, or many identities. Use the visible traversal methods for command
handlers:

```swift
func handleMoveDown(model: FileTreeModel<FileTreePath>) {
    model.focusNextItem()
}

func handleMoveToParent(model: FileTreeModel<FileTreePath>) {
    model.focusParentItem()
}
```

``FileTreeModel/focusFirstItem()``, ``FileTreeModel/focusLastItem()``,
``FileTreeModel/focusNextItem()``, and ``FileTreeModel/focusPreviousItem()`` traverse
``FileTreeModel/visibleRows``. Collapsed descendants and rows filtered out by search do not take
part. First and last return `nil` for an empty projection; next and previous clamp at their visible
boundary.

``FileTreeModel/focusParentItem()`` uses the current projected row's parent. Use
``FileTreeModel/focusNearestItem(to:)`` after a collapse or data update: it chooses the requested
visible identity, its closest visible ancestor, or the last retained visible position when the
identity was removed.

These operations request nearest-edge scrolling in a mounted AppKit or UIKit renderer. They move
focus without changing selection.

## Scroll without forcing selection

``FileTreeModel/scrollTo(_:position:focus:)`` expands the target's ancestors and queues a native
scroll without selecting it:

```swift
model.scrollTo(path, position: .center)
model.scrollTo(path, focus: false)
```

The first call also updates model focus and asks the native tree to accept keyboard focus. The
second call preserves both selection and model focus. The existing
``FileTreeModel/reveal(_:select:position:focus:)`` method exposes the same independent controls
when a caller also wants optional selection.

## Observe only interaction state

Use ``FileTreeModel/selectionChanges`` and ``FileTreeModel/focusChanges`` for inspectors, command
availability, breadcrumbs, and other sibling UI:

```swift
let selectionSubscription = model.selectionChanges.sink { selection in
    inspector.selection = selection
}

let focusSubscription = model.focusChanges.sink { focusedID in
    commandRouter.target = focusedID
}
```

Each Combine publisher emits its current value on subscription and then only distinct changes.
Expansion, search, data, and reveal revisions do not emit when that interaction value stayed the
same. SwiftUI can consume the same publisher with `onReceive`; AppKit and UIKit controllers can
retain the returned cancellable directly.

Native AppKit selection changes and UIKit selection or focus-engine changes synchronize these same
model values. Programmatic and native interaction therefore share one command target and one
selection state.
