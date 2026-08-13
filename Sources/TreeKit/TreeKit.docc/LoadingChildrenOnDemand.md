# Loading Children on Demand

Discover large or remote hierarchies one expanded branch at a time.

## Create a provider-backed model

Use ``FileTreeChildrenProvider`` when preparing every node up front would retain unnecessary
data or block the main actor. Nodes and their identifiers must be `Sendable` because provider
closures run asynchronously.

```swift
let provider = FileTreeChildrenProvider<ProjectNode>(
    roots: { try await repository.roots() },
    mightHaveChildren: { $0.isDirectory },
    children: { try await repository.children(of: $0.id) }
)

let model = FileTreeModel(childrenProvider: provider)
```

SwiftUI ``FileTree`` and native ``FileTreeView`` start loading roots when they mount. Before a
renderer exists, call ``FileTreeModel/loadRoots()`` explicitly. Siblings remain in the order
returned by the provider.

## Present loading state

`mightHaveChildren` lets TreeKit present disclosure before a directory has known children.
Expanding it transitions ``FileTreeRowContext/childrenLoadState`` from
``FileTreeChildrenLoadState/unloaded`` through ``FileTreeChildrenLoadState/loading`` to
``FileTreeChildrenLoadState/loaded``.

```swift
FileTree(model: model) { node, context in
    HStack {
        Text(node.name)
        Spacer()
        if context.childrenLoadState == .loading {
            ProgressView().controlSize(.small)
        }
    }
}
```

Use ``FileTreeModel/rootLoadState`` for a root-level placeholder because no row exists until roots
arrive. A successful child result is retained for the model lifetime, including an empty result,
so collapse and re-expansion do not fetch it again.

## Keep external policy outside the renderer

TreeKit validates and publishes discovered nodes, but the provider remains responsible for file
system or service access, watching, persistence, and cache invalidation. Search operates over
discovered nodes. Loading failures are currently thrown by ``FileTreeModel/loadRoots()`` and
``FileTreeModel/loadChildren(of:)`` and return the branch to `unloaded`; a later lifecycle layer
can add persistent failure presentation and retry policy without synthetic nodes.
