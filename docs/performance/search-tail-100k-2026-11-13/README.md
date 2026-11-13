# 建图后查询尾延迟与位模式验证

日期：2026-11-13。承接 [上一轮内存/首查优化](../search-memory-100k-2026-11-13/README.md)。本次确认并优化的是 ANN 候选回读的逐条 SQL 成本；历史单次 26.374ms p95 没有在新的低开销对照中稳定复现，不能将它唯一归因于 GC 或固定的算法退化。

## 相同条件的前后对照

100,000 条短中文文本／UUID／512D 固定种子合成向量，macOS ARM64、10 核、Dart3.13.7 AOT、SQLite3.51.0。每版从同一个源库的独立克隆和空 sidecar 完整建图，然后在**同一进程立即执行全部 60 次混合热查询**。没有丢弃第一轮、隐藏预热、强制 GC、减少候选或并行运行重型测试/构建。

| 指标 | 原逐条路径 | 每批 16 条 |
| --- | ---: | ---: |
| 冷建同进程语义 p50 | 19.695 ms | 15.664 ms |
| 冷建同进程语义 p95 | 21.798 ms | **17.320 ms（减少20.5%）** |
| 冷建同进程语义最大值 | 22.612 ms | 18.269 ms |
| 独立重开进程语义 p95 | 21.307 ms | **17.309 ms** |
| 同进程每次语义查询平均 process CPU | 20.574 ms | 16.362 ms |
| 128 个 ANN 候选的源库 SELECT | 389 次 | **29 次** |
| Recall@10 | 1.0 | 1.0 |
| 完整后台准备 | 636.001 s | 632.391 s |
| 冷建进程峰值 RSS | 91.719 MiB | 92.172 MiB |
| 独立 warm 进程峰值 RSS | 92.156 MiB | 93.563 MiB |
| 完成后 sidecar | 471.902 MiB | 471.902 MiB |

代价：本轮独立查询进程峰值约增加 **1.406 MiB**，冷建进程约增加 0.453 MiB，未声称内存也改善。批量路径不参与主要建图工作；约 3.6 秒的准备时间差只作为观察值，不归因于批量回读或当作固定加速。

第一轮 12 次语义查询没有排除：其 p95 为 22.612→16.617ms；后 48 次为 21.798→17.676ms。结果见 [统计摘要](comparison-summary.json)、[原版冷建](before-measure.json)、[新版冷建](after-measure.json)、[原版独立warm](before-warm.json)、[新版独立warm](after-warm.json)。原始每次查询的 wall/CPU、缺页、context switch、距离计算及源记录数保留在 queryTrace。

每版各一次完整冷建，独立 warm 每次 60 样本。这是当前主机/分布下的对照，未建立跨设备长期 p95 保证，不包含 Flutter UI、BGE/ASR 推理或操作系统文件缓存清除后的冷磁盘性能。

## 诊断：确认了什么，没有确认什么

1. **确认存在逐条候选/元数据查询。** 原路径对每个候选先读 sidecar 的记录 ID，再调用 `get()`，其中每条记录重复读取 organization/search model 元数据。通过真实 SQLite statement trace，在 128 命中的同一 fixture 中记录到 389 次源库 SELECT；新路径 29 次。计数是源库 SELECT，不是全部 SQLite 调用或磁盘读取次数。见 [原版计数](source-sql-before.json)、[新版计数](source-sql-after.json)。CPU 均值和正常 wall p95 的下降与减少这部分工作一致。
2. **冷建后慢样本不能全部解释成计算或 GC。** 单独开启 verbose GC 的诊断运行，冷建后 p95=49.001ms、最大82.230ms；最慢样本 process CPU=21.761ms，voluntary switches=324，major faults/block input 均记录为0；附近 GC 暂停多在0.1–2.2ms。它提示存在非 CPU 的等待，不能由这些聚合计数唯一定位磁盘、SQLite 锁或具体调度机制。GC 时间戳与 main stopwatch 原点不同且有四舍五入，也不能逐条精确配对。
3. **诊断运行不是正式基线。** verbose GC 及系统瞬时状态可能改变时序；其原始结果单独保留为 [诊断冷建](diagnostic-before-measure.json)、[诊断warm](diagnostic-before-warm.json) 及对应日志。正式 before/after 都关闭 GC 日志，分别使用冻结的前后 AOT 字节码、完全相同的测量 wrapper 与查询序列。CPU helper 在 stopwatch 外采样，未向生产代码添加埋点，也没有调整 VM heap 参数。
4. **历史26.374ms仍是一个单次样本。** 本轮同条件原版 p95=21.798ms，接近其独立warm21.307ms，未表现固定的同进程退化；不能把历史26.374或诊断49直接与新版17.320相减来宣称更大收益。本轮能确认的改进是减少已复现的 SQL/分配成本，并在正式对照中将 p95 降低约20.5%。

process CPU 包含该进程的其他线程，可能因并发 GC 而大于查询 wall；二者之差不是精确的主线程阻塞时间。计数含义参照 [Apple getrusage 说明](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/getrusage.2.html)。SQL 计数使用 statement callback，不在 callback 内重入数据库，参照 [SQLite trace_v2](https://www.sqlite.org/c3ref/trace_v2.html)。

## 实现与行为保持

- `RecordRepository.getBatch()` 最多读64条完整记录，使用原有 `_query/_record` 解码，每批只读取一次两种模型元数据。空列表不执行查询，缺失 ID 跳过；返回值不约定 SQL 行顺序。
- `SearchIndex` 实际每批16个 ANN 候选，批读 ID 和完整记录，建立映射后仍按**原始 ANN 顺序**评分，沿用原有全文、日期、修订、模型检查和精确余弦排序。没有新增异步间隙。
- 保留 organization、transcript、favorite、父子关系和 vectorRevision 等完整字段，搜索结果仍剥离 vector 工作载荷；没有为提速丢弃派生字段。
- 重复 vector_key 作为坏缓存进入既有原文扫描/重建；保护该分支的 mutation 先失败、恢复后通过，不用静默覆盖映射隐藏原文。
- 临时完整记录批次限制16条，不是总结果内存上限。大 organization、长原文和全量结果的实际峰值仍与数据相关；本轮主要测量短文本，未承诺所有负载均降低 RSS。

HNSW M=12、construction ef=80、query ef=200、upper beam=8、候选预算、原精度 Float32 与 double 计算均不变；页缓存预算仍为2MiB，原库schema2/备份v2/sidecar3和生产依赖未变。

## 补齐位模式与顺序测试

新测试直接比较 Float64 位串与 Float32 原始字节，覆盖：

- ±0、最小/最大次正规数、最小正常数、最大有限值及混合极端幅度；包括保留负零和下溢后的符号。
- 140 组固定种子有限指数模式，长度含1/2/3/4/511/512/513，与原稳定归一化算法逐位差分，并确认输入未修改。
- Float32 正负零、正负 subnormal/normal 边界与最大有限值，在 offset0/1/2/3/4 切片中解码/编码逐字节回环；输入缓冲区之后修改，不影响已解码结果。
- 正负 infinity、quiet/signaling NaN、全零向量的拒绝与原始输入保护。

故意破坏 signed zero、清零 Float32 subnormal、将归一化改为 Float32 的3个 mutants 均被新测试抓住，随后恢复精确原始源码字节。证据见 [变异验证](bit-mutations.json) 和 mutant 日志；**本轮没有改动生产归一化/codec数值实现**。

另补齐同分且同创建时间的 frozen legacy 顺序：旧/新128个结果的完整内容与顺序一致，vectorRevision另作断言。见 [旧顺序](tied-order-before.json)、[新顺序](tied-order-after.json)。独立只读复审无 Critical/Important，指出的顺序/修订断言缺口已在计划验收中补齐；没有生产修复或重复派发复审。

## 数据、召回与验证

- 每版 cold/warm 的12个查询各重复5次，Recall@10 均为1.0，平均距离计算均为1045.08；不是自然中文理解准确率或全部分布的 ANN 召回保证。
- 单独比较全部12个查询的**完整有序结果、分数Float64位串、vectorRevision、原文片段及完整Record内容摘要**，每项一致：[原版](results-before.json)、[新版](results-after.json)。它独立于计时，不向计时过程加入序列化工作。
- [源库完整性](source-integrity.json)：两个正式对照源库在全部操作后，仍与原始463,712,256-byte夹具 SHA-256 `add387b847714862a5244f63fc0610b6beefca8feb7341278aa8db87b0924fb3` 一致。
- [完整图内容](graph-integrity.json)：全部docs/指纹、100k节点邻接、50k Float32块与entry逐行摘要一致；9,274,151 postings、1437词、pending=0，两个quick_check通过；索引仍494,825,472 bytes。
- [正式资料](official-data-integrity.json)：正式库、WAL、6 WAV共8文件的每项SHA-256不变；不包含易变SHM，模型目录不在该次指纹范围。正式应用未安装、清数据或修改。

最终 [验证记录](validation.json)：`bash tool/check.sh` **220 Flutter + 15 Python，通过；analyzer clean**。Android API36 / SQLite3.54.1 独立 `.test` 包 Debug 通过9个检索/位模式/批量合同及4个存储场景；**ARM64 Profile AOT 再通过9个合同**，包含真实离线BGE、坏图恢复与完整位模式测试。Profile 是 AOT 数值验证，不是手机性能验收。

普通 ARM64 Release 51,187,617 bytes 构建、包名 `app.nianxia.nianxia` 和仅arm64-v8a检查通过，未安装；SHA-256 `0072756ae368fd3290f6b90fcc9e2fefc9ebf68ac695f5103d129e7d0b5d5cd6`。依赖、已有冻结迁移夹具和正式签名配置未变；工具链后续支持提示保留，未跳过门禁。

证据：[主机](host-gate.log)、[Android Debug](android-search.log)、[存储](android-storage.log)、[ARM64 AOT](android-aot.log)、[AOT包记录](native-aot.json)、[Release](android-release.log)、[独立审查](independent-review.json)、[前源码指纹](before-implementation-sha256.json)、[后源码指纹](after-implementation-sha256.json)、[测量字节码指纹](measurement-binaries.json)。Native日志中的localhost VM服务鉴权路径已打码。首轮新增测试lint问题修正后重新完整通过，未添加linter waiver。

没有Git提交/推送或正式包安装，原有WIP保留。iOS完整构建、真实big-endian硬件、真机长期负载/电耗和大organization峰值仍未由本轮验证。

## 复现与原始记录

[benchmark_probe.dart.txt](benchmark_probe.dart.txt) 是保留原查询序列的诊断wrapper，CPU helper源码在 [metrics.c.txt](metrics.c.txt)。复制到临时文件后：

```sh
clang -dynamiclib -O2 /tmp/nianxia-tail-metrics.c -o /tmp/nianxia-tail-metrics.dylib
dart compile aot-snapshot -p .dart_tool/package_config.json /tmp/nianxia-tail-benchmark.dart -o /tmp/nianxia-tail.aot
dartaotruntime /tmp/nianxia-tail.aot --phase measure --home <新标记夹具> --records 100000 --dimensions 512
# 相同完成图，用新进程执行 --phase warm / --phase wide
```

只允许系统临时目录内的 `.synthetic-search-benchmark` 夹具，cold拒绝已有sidecar。源库和gold用现有 `tool/benchmark_search.dart` 的 seed/gold 阶段或同源独立克隆准备。前/后代码各自编译，不能用同一个字节码冒充前后两版；计时对照不加 `--verbose-gc`。该flag只用于已单独保留的诊断记录。

完整JSON中没有删除不利结果。原始 [before冷建日志](before-measure.log)、[after冷建日志](after-measure.log)、独立warm/wide日志与GC诊断日志均保留。[本轮patch](changes.patch) 仅描述此轮增量，旧WIP快照位置记录于 `/tmp/nianxia-tail-before-home`；在副本中复现，不在正式资料或当前共享工作区反向应用patch。
