# 紧凑索引：十万条前后对比

日期：2026-11-13。完成上一轮中断后的最终测量与验证。完整原始指标保留在本目录，旧版数据见 [上一版报告](../search-100k-2026-11-13/README.md)。

## 测量范围与方法

- macOS ARM64、10 核、Dart 3.13.7 AOT、SQLite 3.51.0；100,000 条短中文文本、36 字符 UUID、512D Float32 向量。固定种子生成 100 个簇，12 个独立查询各重复 5 次，按全部源向量的精确余弦 Top10 计算召回。
- seed、精确 ground truth、cold、warm、全命中分别执行；最终大规模测量期间没有并行编译或测试。使用标记临时库，无真实用户内容、录音或云请求。
- HNSW 的 M=12、construction ef=80、query ef=200、upper beam=8 保持不变。没有量化、降低向量精度、缩小图参数或减少返回结果。
- 旧版冷建完成时 upper=1，后续在同图上复测 upper=8；新版冷建和查询均为 upper=8。冷建的早期查询均走源库精确路径。下表查询性能采用两版各自独立的最终 warm 进程，另列新版冷建进程内热查询。
- “后台准备”包括从空 sidecar 建立文本倒排、HNSW 和早期查询负载，并非只计图插入 CPU 时间。首查无需等待准备完成。单次冷建与先后运行不能当作严格控制环境的统计因果证明。

## 前后对比

| 指标 | 上一版 | 紧凑版 | 变化 |
| --- | ---: | ---: | ---: |
| 完整后台准备 | 987.890 s | 664.082 s（11.07 分钟） | 减少 32.8% |
| 完成后 sidecar（含当时 WAL/SHM） | 758.434 MiB | 471.902 MiB | 减少 37.8% |
| 热语义查询 p95（60 次） | 29.553 ms | 22.176 ms | 减少 25.0% |
| 选择性关键词 p95（60 次） | 0.349 ms | 0.278 ms | 减少 20.3% |
| 样本 Recall@10 | 1.0 | 1.0 | 12 个查询均为 1.0 |
| 冷建测量进程峰值 RSS | 102.375 MiB | 104.375 MiB | 增加 2.0 MiB |
| 独立 warm 复测进程峰值 RSS | 89.000 MiB | 102.953 MiB | 增加 13.953 MiB |
| 空 sidecar 首次语义结果（单次） | 2212.752 ms | 2433.680 ms | 增加 10.0% |
| 重开后的首次语义查询（单次） | 3168.239 ms | 2939.394 ms | 减少 7.2% |
| 十万条全部命中返回（单次） | 3656.204 ms | 3852.691 ms | 增加 5.4% |
| 全命中结果保留时 RSS | 99.266 MiB | 99.828 MiB | 增加 0.562 MiB |

收益是后台准备、存储体积与热查询；**内存、首查和大结果输出没有全面改善**。RSS 是整个独立进程（含 VM、SQLite 与对象），不是 Dart heap，也不是完整 Flutter App。上述小样本差异不代表所有设备或分布的固定提升/回退幅度。

新版 cold 进程内另测热语义 p95 **22.808 ms**、关键词 p95 **0.279 ms**。构建期间 3 次源库语义查询 p95 2460.513 ms，关键词 p95 462.444 ms。独立 warm 启动完整对账 6883 ms（旧版 9804 ms）；常用字按单日筛选 p95 13.080 ms（旧版 12.537 ms），空日期范围 p95 0.067 ms（旧版 0.058 ms）。平均距离计算两版均为 **1045.08** 次，样本搜索路径工作量未因缩小候选预算而改变。

原始数据：[cold](cold-final.json)、[独立 warm](warm-final.json)、[全命中](all-match-keyword.json)。cold 日志包含完整进度及最终 complete 行，未用中断进度外推最终结果。

## 实现与空间构成

`CompactGraphStore` 实现现有 HnswStore interface：整数节点主键、varint 邻接、按维度计算槽数的约 4KiB Float32 向量块（512D 每块 2 条）。邻接更新不重写向量；预编译 SQL、Float32 view 和 double 累加循环展开减少读写与对象分配。倒排词典改用整数 term ID，事务末合并频次变化并仅删除本批触及的零频项。词典和工作集有界。

| 对象 | 紧凑版空间 |
| --- | ---: |
| 向量块表 | 219.789 MiB |
| 倒排 doc 辅助索引 | 98.875 MiB |
| 倒排主表 | 96.973 MiB |
| 文档表 | 23.859 MiB |
| 邻接节点表 | 7.832 MiB |

全部对象见 [dbstat 布局](index-layout.json)。最终存在 100,000 个文档和节点、50,000 个向量块、9,274,151 个 posting、1,437 个词；待建队列为空。`quick_check` 通过，所有词频与 posting 实际计数一致。完成后总索引 **494,825,472 bytes**，构建中采样最大 **500,058,384 bytes**；测试源库 **463,712,256 bytes**，两者同时占用空间。

## 决策、失败记录与局限

1. 仅升级可重建 sidecar 到格式 3；先确认身份、版本和源库别名，才物理替换已知 v1/v2，以释放旧 SQLite 页。原库 schema 2、备份 v2、原文、音频与原向量不迁移。未知/未来缓存保留并降级。判断错误的代价是误删非缓存，别名/版本/冻结旧缓存回归用于约束此风险。
2. 保留 Float32 和 ANN 参数；只做布局和 double 累加顺序优化。代价是未取得量化可能带来的更大空间收益；召回率仍只对当前分布与查询集成立。
3. 16KiB 块小试后在十万规模暴露额外载荷复制，最终改为约 4KiB。后续采样显示大 BLOB 的 WITHOUT ROWID 布局存在 B-tree 载荷读取热点，最终向量块使用普通 rowid 表与复合唯一键。此前 16KiB、复审前及 WITHOUT ROWID 大规模运行都已中止，日志保留且不视为完成测量；10k 试跑与最终 100k 结果分开。采样支持优化方向，但不能将全部收益归因于单一布局因素。
4. 上轮独立审查发现槽位游标缺失/回退会覆盖缓存向量，已用故障用例完成 RED→GREEN：槽位从已提交节点唯一索引推导，事务失败丢弃 adapter；同时补齐淘汰 flush 异常时的 close。最终测量使用修复后代码，四个测量相关源码的哈希见 [实现指纹](implementation-sha256.json)。按原计划不重复派发复审；本轮继续验证和核对最终 Diff。
5. 本轮完整门禁发现一项 UI 测试的等待误判：输入框和首页都能匹配保存文字，帧空闲不代表存储 worker 已回复。仅修改测试，显式等待新记录行并确认编辑器退出，保留原有断言。首次失败日志保留；没有修改产品 UI 或降低门禁。

仍保留：全命中结果按十万条完整返回，传输/排序/展示和内存随命中数增长；冷建与启动对账仍扫描源库；索引约 472 MiB 之外还要保存源库和模型。未进行搜索分页、常驻推理 worker、真机功耗/热管理、自然中文人工标注集或 iOS 完整构建验收。合成 Recall 不是中文理解准确率，也不保证所有输入的 ANN 召回。

## 数据保护与复现

[源库完整性记录](source-integrity.json) 保存冷建前、全部测量后的 SHA-256，逐字节一致。正式 Android 应用使用独立 `.test` 包隔离验证，正式数据的最终核对见下方验证记录。未提交/推送或安装正式 Release。

```sh
dart compile exe tool/benchmark_search.dart -o /tmp/nianxia-compact-benchmark
/tmp/nianxia-compact-benchmark --records 100000 --dimensions 512 --keep-fixture
# 使用上一步打印的已标记临时夹具路径，以下均为独立进程：
/tmp/nianxia-compact-benchmark --phase warm --home <fixture> --records 100000 --dimensions 512 --ef 200
/tmp/nianxia-compact-benchmark --phase wide --home <fixture> --records 100000 --dimensions 512
```

cold 拒绝已有 sidecar；只接受系统临时目录内的专用标记夹具。warm 不用于声称重新冷建，所有失败/中断样本与最终结果分别保留。

## 最终验证

| 验证 | 实际结果 |
| --- | --- |
| `bash tool/check.sh` | 209 项 Flutter、15 项 Python 通过，`flutter analyze` 无问题 |
| Android API36 / SQLite 3.54.1 | `.test` 包：2 个真实离线 BGE/检索/坏图恢复/日期分页场景，4 个存储升级/备份/未来库拒绝/分页关闭场景通过 |
| Android ARM64 Release | 构建通过，51,187,617 bytes；aapt 核对正式包名，ZIP 核对仅 arm64-v8a；未安装正式包 |
| 正式应用数据 | 主库、WAL 和 6 个 WAV，共 8 文件的 SHA-256 与重构前一致；忽略易变 SHM，模型目录不在该次指纹范围 |
| 合成源库 | cold 前与 cold/warm/全命中测量后 SHA-256 相同 |
| 依赖与 Diff | pubspec.yaml / lock 与本轮前快照一致；已跟踪 Diff 和新增文本空白检查通过 |

完整 [验证记录](validation.json)、[正式资料指纹摘要](official-data-integrity.json)、[主机门禁日志](host-gate.log)、[Android 检索日志](android-search.log)、[Android 存储日志](android-storage.log)、[Release 日志](android-release.log) 均保留。第一次完整门禁的 [UI 失败日志](host-first-failure.log) 也保留，该次在其余输出停滞后中止；修正测试等待后重新完整通过，未用定向通过替代完整门禁。

Release SHA-256：`cb3efd0bd54d4554561e4d8b6e247c4428975dd2001bd34023e67894bbac8571`。构建仍提示 Gradle/AGP/Kotlin 后续支持警告；没有跳过依赖检查、升级工具链、生成正式签名或安装正式包。本轮未进行 Git 提交/推送，已有工作区改动保留。
