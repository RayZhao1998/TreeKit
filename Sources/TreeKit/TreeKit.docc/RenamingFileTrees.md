# Rename File Tree Paths

Run one shared inline-editing workflow across SwiftUI, AppKit, and UIKit.

## Configure policy and feedback

Install caller policy before starting a session:

```swift
model.configureRenaming(.init(
    canRename: { path in !protectedPaths.contains(path.id) },
    onRename: { event in persistence.rename(event.sourcePath, to: event.destinationPath) },
    onError: { error in errorPresenter.show(error.localizedDescription) }
))
```

The hooks execute on the main actor. A rejected policy or invalid name updates
``FileTreeModel/renameError`` and leaves both the hierarchy and active editor unchanged.

## Start, commit, and cancel

Start by canonical identity, or omit it to use model focus:

```swift
try model.startRenaming("Sources/Old.swift")
try model.commitRenaming("New.swift")

model.cancelRenaming()
```

Mounted native rows display an inline text editor above built-in or custom row content. Return
commits and Escape cancels on AppKit and hardware-keyboard UIKit. SwiftUI uses the same native
host, so it receives identical behavior and focus restoration. If the edited row leaves the
mounted viewport, TreeKit cancels the session instead of committing stale input.

Successful commits run through the same-parent path mutation, retaining valid identity state and
emitting both ``FileTreeRenameEvent`` and the corresponding move mutation event. Directory
destinations preserve the trailing `/` identity convention.

## Ownership boundary

TreeKit validates and updates its in-memory model. It does not rename filesystem entries. The
caller owns persistence, authorization, rollback, and user-facing error presentation. Use
``FileTreeModel/renameEvents`` or `onRename` to bridge a successful in-memory intent to those
systems.
