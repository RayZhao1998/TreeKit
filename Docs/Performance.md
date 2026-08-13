# Performance baseline

This baseline measures TreeKit's macOS renderers with the Demo's reproducible
[`oven-sh/bun` PR #30412](https://diffshub.com/oven-sh/bun/pull/30412) fixture.
The fixture contains 2,188 changed files and produces 2,455 prepared nodes after TreeKit adds
implicit directories.

## Environment

- Release configuration, Swift 6, warnings treated as errors
- MacBook Pro (Mac16,8), Apple M4 Pro (8 performance + 4 efficiency cores), 24 GB memory
- macOS 26.5.2 (25F84), Xcode 26.1 (17B55)
- Foreground app on a 2560 × 1440 external display with a 75 Hz maximum refresh rate

## Workload and metrics

The hidden Demo benchmark is enabled with `TREEKIT_PERF_AUTORUN=1`. It reveals 300 paths
distributed across the fixture, then repeats them in reverse, for 600 cross-tree operations.
Each operation changes selection, expands the required ancestors, centers the native viewport,
and yields the main actor so the UI transaction can run before the next requested 16 ms pause.

`effective_fps` is the number of completed UI update transactions per second. It is intentionally
not described as compositor-presented FPS: this component performs discrete, non-animated tree
updates, so it does not continuously produce Core Animation frames. CPU and resident memory
(RSS) were sampled from the process once per second with `ps`. macOS `%CPU` is relative to one
logical CPU, so 42% means about 0.42 logical cores, not 42% of the whole machine.

Apple's Animation Hitches instrument was also recorded for both renderers. The exported
`hitches-updates` table contained zero events in both 15-second runs. Apple recommends this
instrument for finding hitches in scrolling and animations; see
[Understanding hitches in your app](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app).

## Results

| Metric | SwiftUI `FileTree` | AppKit `FileTreeView` |
| --- | ---: | ---: |
| Operations | 600 | 600 |
| Elapsed | 18,240.97 ms | 17,770.43 ms |
| Effective UI update rate | 32.84 updates/s | 33.71 updates/s |
| Update gap p95 | 39.92 ms | 38.63 ms |
| Maximum update gap | 47.28 ms | 48.37 ms |
| Gaps over 25 ms | 571 | 536 |
| Stress CPU average | 42.30% | 41.79% |
| Stress CPU maximum | 49.0% | 45.2% |
| Idle RSS before stress | 107.89 MiB | 100.06 MiB |
| Peak RSS | 125.19 MiB | 120.14 MiB |
| Animation Hitches update events | 0 | 0 |

The native AppKit surface is 2.6% faster in this run and uses about 5 MiB less absolute peak
RSS. The two CPU profiles are effectively close. Neither renderer sustains a 60 Hz update
cadence under this deliberately severe workload, which forces a different branch reveal and
viewport jump on every transaction. This is a baseline from one machine and one run, not a
cross-device guarantee.

## First optimization pass

The first pass made three code-backed changes:

- `reveal` now inserts the first newly visible ancestor subtree once, using the final expansion
  set, instead of rebuilding the complete visible projection.
- The Demo keeps its shared model reference without observing it from the whole split-view
  container. Only the status and selection-detail leaves observe published values. Native
  `FileTreeView` instances already subscribe to the model directly.
- `PreparedTree` omits leaf-only empty child arrays and derives sibling counts instead of storing
  a redundant dictionary entry for every node.

The same 600-operation Release workload produced:

| Metric | SwiftUI before | SwiftUI after | AppKit before | AppKit after |
| --- | ---: | ---: | ---: | ---: |
| Elapsed | 18,240.97 ms | 16,539.27 ms | 17,770.43 ms | 16,410.35 ms |
| Effective UI update rate | 32.84/s | 36.22/s | 33.71/s | 36.50/s |
| Update gap p95 | 39.92 ms | 36.28 ms | 38.63 ms | 35.98 ms |
| Gaps over 25 ms | 571 | 395 | 536 | 402 |
| Sampled stress CPU average | 42.30% | 36.69% | 41.79% | 36.62% |
| Sampled stress CPU maximum | 49.0% | 44.5% | 45.2% | 41.6% |

Elapsed time improved by 9.3% for SwiftUI and 7.7% for AppKit in these final profile runs. A
preceding repeat reached 16,152.95 ms and 15,969.96 ms respectively, which also shows the
run-to-run variation of this UI workload. The improvement at 2,455 nodes is mostly from narrowing
observation: before the change, each model transaction
also invalidated the command bar, split view, tree representable, and surrounding content. The
incremental reveal change is expected to matter more as the visible projection grows.

The model also omits empty child arrays for leaves and derives sibling count rather than storing a
dictionary entry per node. For this fixture, the child dictionary drops from 2,455 entries to
about 267 branch entries, and the 2,455-entry sibling-count dictionary disappears. A `heap` and
`vmmap` snapshot at the identical 600-operation end state reported:

| Metric | SwiftUI before | SwiftUI after | AppKit before | AppKit after |
| --- | ---: | ---: | ---: | ---: |
| Heap allocations | 246,912 | 243,249 | 212,720 | 193,539 |
| Heap allocated bytes | 42.89 MiB | 42.16 MiB | 39.31 MiB | 36.87 MiB |
| Physical footprint | 61.5 MiB | 59.0 MiB | 55.2 MiB | 50.8 MiB |
| Peak physical footprint | 63.3 MiB | 60.8 MiB | 57.1 MiB | 55.2 MiB |

That is evidence of lower retained memory for this scenario, but not a universal per-node
guarantee: framework page residency and allocator state still vary between launches. The larger
scale reduction requires loading fewer nodes rather than only packing eager indexes. The shipped
provider-backed lifecycle and its remaining roadmap are in [`LazyLoading.md`](LazyLoading.md).

## Reproduction

Build and stage the Release app first:

```sh
TREEKIT_BUILD_CONFIGURATION=release ./script/build_and_run.sh --verify
```

Launch one renderer with a trigger file and stdout capture:

```sh
open -n -F \
  -o /tmp/treekit-performance.log \
  --env TREEKIT_PERF_AUTORUN=1 \
  --env TREEKIT_PERF_RENDERER=swiftUI \
  --env TREEKIT_PERF_TRIGGER_FILE=/tmp/treekit-performance.trigger \
  dist/TreeKitDemo.app

touch /tmp/treekit-performance.trigger
```

The app writes a `TREEKIT_PERF_RESULT` line containing the operation count, elapsed time,
effective update rate, p95/maximum update gap, and the number of gaps over 25 ms. Use `appKit`
for `TREEKIT_PERF_RENDERER` to test the native renderer. Use fresh trigger and log paths for
each run.
