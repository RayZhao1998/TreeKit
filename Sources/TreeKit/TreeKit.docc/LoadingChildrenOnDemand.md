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
``FileTreeChildrenLoadState/unloaded`` through ``FileTreeChildrenLoadState/loading`` to either
``FileTreeChildrenLoadState/loaded`` or ``FileTreeChildrenLoadState/failed(_:)``.

```swift
FileTree(model: model) { node, context in
    HStack {
        Text(node.name)
        Spacer()
        switch context.childrenLoadState {
        case .loading:
            ProgressView().controlSize(.small)
        case .failed(let failure):
            Button("Retry") {
                Task { try? await model.retryChildren(of: context.id) }
            }
            .help(failure.message)
        case .unloaded, .loaded:
            EmptyView()
        }
    }
}
```

Use ``FileTreeModel/rootLoadState`` for root-level state because no row exists until roots arrive,
and call ``FileTreeModel/retryRoots()`` after a root failure. TreeKit's default SwiftUI, AppKit,
and UIKit presentations include accessible progress and retry controls. A successful child result
is retained for the model lifetime, including an empty result, so collapse and re-expansion do not
fetch it again.

## Handle failures and retry

``FileTreeLoadFailure`` retains the provider's concrete error as `underlyingError` and a default
localized `message`. Custom rows can cast the underlying error and provide product-specific copy;
TreeKit never inserts a synthetic loading or error `Node`.

Root and child failures remain attached to their real surface until retry, reset, or a successful
result changes the state. ``FileTreeModel/retryRoots()`` and
``FileTreeModel/retryChildren(of:)`` use the same operation registry as initial loads, so repeated
retry actions join one provider request. A successful retry validates and publishes the complete
result atomically, then clears the failure. Failure and retry preserve current selection, focus,
expansion intent, loaded siblings, and mounted-row identity.

## Coordinate overlapping requests

TreeKit coalesces concurrent root requests and concurrent requests for the same branch. Every
caller awaits the same provider operation and receives the same accepted result or error; repeated
expansion while a branch is loading does not start duplicate provider work or publish duplicate
nodes. Different branches can still load independently.

Collapsing a loading branch only changes expansion state. Its operation continues, and a successful
result is cached while the branch remains collapsed. Selection, focus, nested expansion, and other
loaded branches are read from the model again when that result is published, so unrelated user
interaction is preserved.

Use ``FileTreeModel/reset(childrenProvider:initialExpansion:initialSelection:)`` to replace a
provider on the same model. Reset advances the model generation and cancels its owned operations
before clearing the old hierarchy. A provider may ignore cancellation and return or throw later;
TreeKit rejects both stale success and stale failure, and callers waiting on the obsolete operation
receive `CancellationError`. Reset roots remain `unloaded`, so call ``FileTreeModel/loadRoots()``
after replacing a provider on an already-mounted model. Internally owned loading tasks use a weak
model reference and do not extend the lifetime of a discarded model.

## Keep external policy outside the renderer

TreeKit validates and publishes discovered nodes, but the provider remains responsible for file
system or service access, watching, persistence, and cache invalidation. Search operates over
discovered nodes. Loading failures are thrown by ``FileTreeModel/loadRoots()`` and
``FileTreeModel/loadChildren(of:)`` and retained in the corresponding load state. A current failure
is shared by callers of that operation; an obsolete failure cannot change the new generation.
TreeKit owns retry coordination and state, while the provider continues to own the underlying I/O.
