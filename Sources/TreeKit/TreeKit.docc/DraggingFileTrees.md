# Drag and Drop File Tree Paths

Resolve native AppKit and UIKit drag interactions into one path-first transaction model.

## Configure policy and events

```swift
model.configureDragAndDrop(.init(
    canDrag: { paths in !paths.contains { protectedPaths.contains($0.id) } },
    canDrop: { proposal in policy.accepts(proposal) },
    onDropComplete: { event in persistence.apply(event.moves) },
    onDropError: { failure in errorPresenter.show(failure.error) },
    openOnDropDelay: 0.7
))
```

Native renderers provide platform drag previews, drop indicators, autoscroll, and delayed folder
expansion. SwiftUI uses the same native host. Starting a selected row captures the current
multi-selection, removes descendants whose selected ancestor already represents them, and keeps
sources in prepared preorder.

## Resolve a target

``FileTreeDropPosition/before`` and ``FileTreeDropPosition/after`` move sources into the target's
parent. ``FileTreeDropPosition/inside`` moves them into a target directory; a `nil` path means the
forest root. ``FileTreeDropTarget/destinationDirectoryPath`` exposes that resolved directory, and
``FileTreeDropProposal/destinationPaths`` contains every complete canonical destination before
policy is evaluated.

```swift
let session = try model.makeDragSession(startingAt: focusedID)
let target = FileTreeDropTarget(path: folder, position: .inside)
let event = try model.performDrop(session, target: target)
```

TreeKit rejects self-drops, duplicate destinations, missing paths, invalid targets, and directory
cycles before installing an atomic mutation. Exact before/after sibling order is retained when the
model uses ``FileTreePathOptions/Sort/inputOrder``. Lexicographic and folders-first models reapply
their declared sort policy after a move.

## Ownership boundary

A successful internal drop updates the in-memory model through the shared move transaction and
emits both mutation and ``FileTreeDragDropEvent`` streams. TreeKit does not move filesystem
entries. The caller owns persistence, authorization, rollback, external drag payloads, and
user-facing error presentation.
