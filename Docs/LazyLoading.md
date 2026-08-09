# 懒加载设计

TreeKit 1.x 有意采用 eager（一次性完整加载）的 `PreparedTree`。对于几千个已知节点，
这仍然是最简单、最快的方案，同时能将文件系统访问排除在渲染组件之外。但是，包含生成目录、
依赖存储或远程节点的仓库可能增长到数十万个条目；在这种规模下，预先保留所有节点和路径
就不再是合适的权衡。

本文档定义了添加懒加载子节点时的兼容性边界。它描述的是设计目标，并不表示下文中的类型
已经存在。

## 保留 eager 路径

懒加载应当以增量方式加入。现有的 `PreparedTree`、`FileTreeModel(preparedTree)`、
`FileTree` 和 `FileTreeView` 调用方式必须继续正常工作，且不会被迫引入异步行为。
最终，eager adapter 应当与懒加载 provider 使用同一套内部节点存储，让 renderer 共享
同一个状态机，而不是维护两套并行实现。

在公开 provider 之前，renderer 代码应停止通过 model 的公共 `preparedTree` 属性直接查询。
应当由 model 提供一组精简的查询接口，包括节点、父节点、子节点、深度、兄弟位置和是否可展开。
这样可以更换底层存储，而不会把 arena 或缓存布局泄漏到 UI 接口中。

## Provider 边界

Provider 需要提供三项相互独立的能力：

```swift
public struct FileTreeChildrenProvider<Node: Identifiable & Sendable>: Sendable {
    public var roots: @Sendable () async throws -> [Node]
    public var mightHaveChildren: @Sendable (Node) -> Bool
    public var children: @Sendable (Node) async throws -> [Node]
}
```

必须提供 `mightHaveChildren`，因为在子节点尚未加载时，界面就需要确定是否显示 disclosure。
这些闭包可以枚举文件系统、查询远程服务或读取内存中的测试数据；TreeKit 不应拥有这些策略。

每个可展开节点都需要明确的状态：

```text
unloaded -> loading(generation) -> loaded
                    |                 |
                    +----> failed <---+
```

- 同一节点的并发展开请求共享同一个 task。
- 默认情况下，折叠节点不会丢弃已经成功加载的结果，避免反复展开和折叠造成抖动。
- `reset` 会取消尚未完成的 task，并递增 generation。即使某个 task 无法立即取消，来自旧
  generation 的结果也会被忽略。
- 失败状态与对应节点保持关联，并且可以显式重试。
- 加载完成的子节点必须先验证其 ID 是否稳定且全局唯一，然后才能通过一次原子 model transaction
  发布。

加载和失败状态应放入 `FileTreeRowContext`，使自定义 row 能显示进度或提供重试操作，而不需要
虚构假的 `Node`。原生 disclosure、选择状态和辅助功能仍由 renderer 负责。

## Reveal 与缓存

如果一个节点的祖先从未被发现，仅凭该节点的 ID 无法执行 reveal。因此，懒加载接口需要提供
可选的 provider 路径解析器，或者提供显式路径操作，例如 `reveal(path: [Node.ID])`。TreeKit
随后可以按顺序加载每个缺失的祖先、合并已有的加载请求，并在确认目标节点存在后再应用选择和滚动。

第一个实现应当在 model 的生命周期内保留已经加载的子节点。经过测量后，可以添加有界 LRU
或基于成本的淘汰机制；但淘汰策略必须明确如何处理选择状态、嵌套展开、正在执行的 reveal，
以及调用方拥有的 metadata。静默的定时淘汰会让树的交互行为变得不可预测。

## 懒加载之后的内存优化

懒加载会移除影响规模的主要乘数：尚未发现的节点不会占用 model 或 renderer 的存储空间。
如果对 10 万以上已加载节点的 profiling 仍然表明需要更深入的优化，后续步骤应当是：

1. 使用紧凑的整数索引缓冲区存储层级关系，同时在公共边界保留调用方提供的 ID。
2. 避免在内部索引中重复保存完整路径；路径构造或字符串驻留应留在 path adapter 中，
   而不应成为 renderer 的要求。
3. 将 Git 状态、诊断信息和 badge 等 decoration 保存在调用方拥有的存储中，并使用
   `reloadRows(withIDs:)` 进行定向刷新。
4. 只有在 heap profiling 能够证明某种淘汰策略确实有价值后，才添加明确的已加载节点成本上限。

Demo 已经遵循第 3 项：Git 状态存放在 `FileTreePath` 之外。TreeKit 也已经使用扁平的可见行投影
和原生 viewport 复用，因此，与把 renderer 换成另一种列表抽象相比，懒加载和紧凑的底层存储
具有更高的预期收益。

## 验收条件

只有当测试覆盖以下场景时，懒加载实现才算准备就绪：取消、过期结果、重试、重复 ID、隐藏节点展开、
通过未加载祖先执行 reveal、加载期间 reset、选择状态保留、确定性排序和缓存策略。性能验证应当对比
2,500、100,000 以及至少 500,000 个潜在节点下的 eager 和 lazy 模式，并报告已加载节点数量、
physical footprint、峰值 footprint、主线程耗时和可见内容更新延迟。
