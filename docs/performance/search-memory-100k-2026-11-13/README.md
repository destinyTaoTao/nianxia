# 内存与首次查询：诊断、优化及十万条复测

日期：2026-11-13。基线为 [上一轮紧凑索引](../search-compact-100k-2026-11-13/README.md)，本轮保留缓存格式 3、原库 schema 2、备份 v2、Float32 原向量和全部 HNSW 参数。没有新增生产依赖、Git 提交/推送或正式包安装。

## 结果

100,000 条短中文文本／UUID／512D 合成向量，macOS ARM64、10 核、Dart 3.13.7 AOT、SQLite 3.51.0。12 个固定查询各重复 5 次，对照全量精确 Top10；不包含 Flutter UI、BGE/ASR 推理或真机端到端性能。

| 指标 | 优化前 | 优化后 | 口径 |
| --- | ---: | ---: | --- |
| 首次语义查询 | 2486.662 ms | 995.267 ms | 3 组成对独立进程的中位数，减少 60.0% |
| 首查进程峰值 RSS | 61.250 MiB | 27.766 MiB | 上述 3 次中位数，减少 54.7% |
| 独立热查询进程峰值 RSS | 102.641 MiB | 92.141 MiB | 每版 3 次进程峰值的中位数，减少 10.2% |
| 热语义查询 p95 | 23.420 ms | 21.439 ms | 每进程 60 次查询，取 3 个 p95 的中位数 |
| 完整后台准备 | 664.082 s | 647.563 s | 各 1 次从空 sidecar 冷建，含早期查询；本次少 16.519 s |
| 冷建进程峰值 RSS | 104.375 MiB | 91.328 MiB | 各 1 次独立冷建进程，减少 12.5% |
| 完成后 sidecar | 471.902 MiB | 471.902 MiB | 都是 494,825,472 bytes，含当时 WAL/SHM |
| Recall@10 | 1.0 | 1.0 | 所有 12 个查询均为 1.0；成对首查也均为 1.0 |
| 全命中十万条返回 | 3852.691 ms | 3601.724 ms | 各 1 次独立进程 |
| 全命中结果保留时 RSS | 99.828 MiB | 86.484 MiB | 各 1 次独立进程 |

首查成对测试按 before1→after1→before2→after2→before3→after3 交错执行，使用同一个源库的独立 APFS 克隆，每次 sidecar 不存在，结束后立即关闭，不继续完整建图。六个源库在执行后都与原始源库逐字节一致。这里的 cold 指新连接和空 sidecar，**没有清除操作系统文件缓存**。它与完整冷建进程的首查样本分开，不拼成一组统计数据。

完整冷建进程中的单次首查为 **1294.948 ms**（上一轮 2433.680 ms）。该进程后续 60 次热语义 p95 为 **26.374 ms**（上一轮 22.808 ms），出现尾部回退；另一个独立最终 warm 进程 p95 为 **22.146 ms**（上一轮 22.176 ms），峰值 RSS 92.094 MiB。所有结果均保留，不宣称每个进程/场景都更快，也不将单次建图的 2.5% 差异当作固定加速保证。

原始结果：[成对首查](repeated-first.json)、[重复 warm 与分步候选](repeated-warm.json)、[冷建](cold-final.json)、[最终 warm](warm-final.json)、[全命中](all-match-keyword.json)、[统计摘要](comparison-summary.json)。最终距离计算平均 **1045.08** 次，与基线相同。

## 原因与证据

### 首查的主要热点是全量源扫描中的向量处理

首次查询不能等待十万节点全部建完，因此从原库逐页读向量并精确计算。每条记录原先经历 Float32→通用 double 列表解码、生成缩放中间列表、生成归一化结果列表，再进行余弦计算。对十万条 512D 数据，这带来大量临时数值对象和列表分配。

分步试验只改一个因素，使用同一个 AOT 分阶段脚本：

| 修改 | 三次源扫描耗时范围 | 该扫描进程峰值 RSS |
| --- | ---: | ---: |
| 原实现 | 2365.606–2370.775 ms | 61.719 MiB |
| 单一 Float64 归一化缓冲区 | 1209.704–1221.425 ms | 59.813 MiB |
| 再将解码结果改为自有 Float32 缓冲区 | 934.673–942.541 ms | 34.516 MiB |
| 最终加入页缓存预算 | 915.435–921.429 ms | 27.938 MiB |

归一化的数值计算保留 double 精度、scale 防溢出方式和求和顺序；将校验/最大幅度扫描合并，并复用一份 Float64 输出。解码保留文件中的 Float32 值，显式 little-endian，分配自己的 Float32 缓冲区，避免引用调用方 BLOB。没有把归一化或余弦计算量化为 Float32，也没有减少候选或提前截断源扫描。

这些归一化、解码、扫描及 repository 代码在上一轮紧凑布局前后逐字相同。因此此前 2.213→2.434 秒的单次差异，**没有足够证据归因于紧凑布局引入了扫描算法回退**；本次优化针对已复现的绝对耗时，并改用成对重复测量。

### 热查询峰值需要区分存活对象、瞬时分配和 native 页缓存

- 新图存储的 512D 向量视图为 2048 bytes，实际 backing buffer 也是 2048 bytes，排除了“小视图意外保留大块向量页”的假设。
- JIT VM-service 诊断中，热查询前后显式 GC 的存活对象差约 8 MiB，而 heap capacity 扩张更多；峰值不能直接解释为相同数量的常驻记录或泄漏。诊断会受 JIT、显式 GC、HTTP profile 响应自身分配影响，不能与 AOT RSS 混用或当作完整差异的因果分摊。见 [诊断摘要](diagnostic-heap-summary.json)。
- 启动对账的旧 SHA 拼接会将每个向量字节展开到通用整数列表。改为 Uint8 拼接后，同一阶段准备结束 RSS 从约 51.2 降至 37.5 MiB，100k 文档指纹与节点映射不变；但该修改加上数值缓冲区后，3 次完整 warm 进程峰值仍为 104.594–105.344 MiB，**尚未解决热查询峰值**。
- 实际主机 SQLite 的源库和 sidecar 连接均默认 `cache_size=2000`、`page_size=4096`，每个连接约 7.8 MiB 的建议页缓存。明确设置连接内 `cache_size=-2048` 后，3 次 warm 峰值为 **92.125–92.156 MiB**，p95 为 **21.023–21.473 ms**，召回均为 1.0。这是最终 warm RSS 改善的主要可控因素；并非说明所有 SQLite 都默认分配 8 MiB。

负 `cache_size` 按 KiB 指定、仅影响当前连接；它是页缓存的建议预算，不是进程/连接总 RSS 硬上限。系统编译选项、其他缓存和被固定的页面仍需分别考虑。[SQLite 官方 cache_size 说明](https://www.sqlite.org/pragma.html#pragma_cache_size)。Float64List 使用双精度连续数据布局，其空间/时间特征见 [Dart 官方说明](https://api.dart.dev/dart-typed_data/Float64List-class.html)。

本轮没有证明存在内存泄漏，也没有对此前 89→103 MiB 的所有差异作精确因果分摊。此次重复基线复现为 101.3–102.7 MiB，最终约 92.1 MiB；最早的 89 MiB 是另一次旧版单次样本，不能据此声称所有历史峰值差异已经消除。

## 数据、召回与兼容性

- [源库证据](source-integrity.json)：最终新夹具和此前夹具的 463,712,256-byte 源库 SHA-256 都是 `add387b847714862a5244f63fc0610b6beefca8feb7341278aa8db87b0924fb3`，冷建、warm、wide 和首查克隆前后不变。
- [完整图内容证据](graph-integrity.json)：逐行验证全部 docs（含 signature）、100k 节点邻接、50k Float32 向量块和 entry point，前后内容哈希相同。旧缓存无需因哈希拼接实现变化而重建。
- [布局与校验](index-layout.json)：100k 文档/节点、9,274,151 个 posting、1437 个词，pending 为空，quick_check 通过，词频与 posting 实际计数一致。侧库物理页/文件总体积保持不变。
- [正式应用指纹](official-data-integrity.json)：主库、WAL、6 个 WAV，共 8 文件的每项 SHA-256 与任务前一致；不包含易变 SHM，模型目录不在该次指纹范围。所有 Android 验证使用独立 `.test` 包，未覆盖安装正式应用。
- pubspec.yaml、lock、冻结迁移夹具均未变化；schema、备份版本、缓存版本、模型代际与 ANN 参数未改变。

## 验证、审查与剩余边界

`bash tool/check.sh`：**213 Flutter + 15 Python 全部通过，analyzer clean**。新增测试先在数值缓冲区和 native cache 预算处失败，再完成修复；覆盖原算法严格数值相等、极端幅度/最小正数、非法向量、非对齐 BLOB、缓冲区自有性和页缓存配置预算。原有编辑/删除/模型代际、坏图恢复、迁移故障、恢复取消及大备份回归继续通过。

Android API36 / SQLite3.54.1 的 **2 个真实离线 BGE/持久检索/恢复/日期分页场景 + 4 个存储升级/备份/未来库拒绝/关闭重开场景**通过。ARM64 Release **51,187,617 bytes** 构建通过，aapt 包名为 `app.nianxia.nianxia`，仅 arm64-v8a，未安装正式包。依然存在工具链后续支持警告；没有跳过依赖门禁或升级工具链。

证据：[最终验证](validation.json)、[主机日志](host-gate.log)、[Android 检索](android-search.log)、[Android 存储](android-storage.log)、[Release](android-release.log)、[实现指纹](implementation-sha256.json)。APK SHA-256：`cdfd102d3672e655c710269ff1a9be57d741c3a957a07780e776160f6966de3e`。

一次 fresh-context 只读独立审查未发现 Critical/Important；[审查摘要](independent-review.json) 保留一项 deferred minor：当前数值相等断言未穷举 Float64 位模式（如 signed zero）及所有 Float32 subnormal 字节夹具，不据此宣称任意输入逐位相同。实测十万条源向量和整图内容已另行验证一致。真实 big-endian、iOS 完整构建、自然中文人工标注、双平台真机电耗/长期运行仍未验收。

结果全量返回仍与命中数增长，页缓存预算可能增加其他负载/设备的 I/O；冷建后同进程尾延迟的回退已保留。此次没有引入搜索分页、缓存自动调参、常驻推理 worker、手动强制 GC 或为压低指标而修改 ANN 参数。

## 复现

```sh
dart compile exe tool/benchmark_search.dart -o /tmp/nianxia-memory-benchmark
/tmp/nianxia-memory-benchmark --records 100000 --dimensions 512 --keep-fixture
/tmp/nianxia-memory-benchmark --phase warm --home <fixture> --records 100000 --dimensions 512
/tmp/nianxia-memory-benchmark --phase wide --home <fixture> --records 100000 --dimensions 512
```

完整 cold、warm、wide 分进程串行执行；测量时没有并行编译、主机测试或 Android 构建。首查重复脚本保留为 [first_probe.dart.txt](first_probe.dart.txt)，阶段脚本为 [stage_probe.dart.txt](stage_probe.dart.txt)：复制到临时 `.dart` 文件后，以 `dart compile exe -p .dart_tool/package_config.json <probe.dart>` 编译。对相同源码快照前后分别编译，在 3 个独立标记临时源库克隆上交错执行；不要在正式资料目录使用。

[本轮增量 patch](changes.patch) 只描述这次四个生产文件和新增测试，不混入此前 WIP；反向复现应在副本中进行。本地原始 WIP 快照位置记于 `/tmp/nianxia-memory-before-home`。所有中间候选、RED/失败记录与最终 raw JSON 均保留；没有将探索性试验冒充最终冷建。
