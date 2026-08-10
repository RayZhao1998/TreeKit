# Mutating File Trees

Update one long-lived path model without replacing the SwiftUI, AppKit, or UIKit tree.

## Overview

TreeKit owns the in-memory hierarchy and its identity-based interaction state. Use the semantic
path operations on `FileTreeModel<FileTreePath>` when caller-owned data changes:

```swift
try model.add("Sources/New.swift")
try model.remove("Sources/Obsolete.swift")
try model.move("Sources/Feature/", to: "Archive/Feature/")
```

Paths use the same canonical rules as initial input. Directories end in `/`; move destinations
name the complete new path and require an existing directory parent. Removing a directory removes
its entire subtree. Moving a subtree remaps retained selection, expansion, and focus identities.

## Apply an atomic batch

Use ``FileTreeModel/batch(_:)`` for ordered changes that mounted renderers must observe together:

```swift
try model.batch([
    .add(path: "Sources/Replacement.swift"),
    .remove(path: "Sources/Legacy.swift"),
    .move(from: "README.md", to: "Docs/README.md")
])
```

TreeKit validates every operation against the preceding operation's staged result. It publishes
one revision and one ``FileTreePathMutationEvent/batch(_:)`` event only after the final hierarchy
is valid. An error leaves hierarchy, selection, expansion, focus, search, and revision unchanged.

Use ``FileTreeModel/resetPaths(_:options:preservingExpansion:preservingSelection:)`` when the
caller already has a complete replacement path list. Retained identities preserve interaction
state by default.

Models created with `FileTreeModel(paths:...)` remember which directories were supplied explicitly,
so removing their final child does not remove the empty directory. A model constructed directly
from `PreparedTree<FileTreePath>` has no synthesized-ancestor provenance; TreeKit conservatively
treats every prepared node as explicit when path mutations begin.

## Subscribe to semantic intent

``FileTreeModel/mutationEvents`` is a typed Combine publisher. The `onMutation` convenience can
filter by event kind:

```swift
let subscription = model.onMutation(.move) { event in
    persistenceQueue.enqueue(event)
}
```

Events arrive after the in-memory transaction is installed and use normalized ``FileTreePath``
payloads. They are suitable for filesystem persistence, logging, analytics, or adjacent UI, but
they do not perform those side effects. The caller owns persistence errors and rollback policy;
TreeKit remains a rendering and interaction module rather than a filesystem adapter.
