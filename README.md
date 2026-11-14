# 念下 · nianxia

本地优先的语音灵感本。Android / iOS Flutter 工程，记录与查找分开，原文始终保留。当前为开发试用版本，真机验收尚未完成。

## 当前架构与 UI 验证（2026-11-14）

已落地摘要分页、可恢复本地任务、有界脱敏诊断，以及批准的深浅主题、录音收起/返回、恢复资料管理、备份密码与取消流程。Android独立包通过真实锁屏采集、实际120秒上限、强杀恢复、Flutter引擎销毁重连；实验age备份通过互操作及完整恢复链路。完整清单、复现和未执行项目见 [最终验收报告](docs/validation/2026-11-13-architecture-ui/final-report.md)。

本轮普通应用仍保留兼容录音与明确标注的明文备份；新的原生录音和密码备份需要Gate-C/B真机/iOS证据后才默认启用。iOS原生Liquid Glass未验收，采用实色降级；Android保持中性Material3。Magic8/iPhone17、完整Xcode、自然语音质量、真机性能/耗电及日历保存提醒仍待接入验证。正式应用未覆盖安装或清数据，正式资料本轮未读取；不能以安装路径不变推导内容散列不变。

下方性能与交付记录保留历史日期和当时结论，不作为当前验证总数或Git状态。

## 建图后的查询尾延迟与位模式（2026-11-13）

同源十万条／512D、关闭GC日志的前后完整冷建对照：建图同进程语义p95 **21.798→17.320ms**，最大22.612→18.269ms；独立重开p95 **21.307→17.309ms**。128候选的源库SELECT从389降到29，完整有序结果与分数位串一致，Recall@10保持100%，索引仍471.902MiB。每批16条回读完整记录，再按原ANN顺序评分，保留全部派生字段和vectorRevision，ANN/数值/数据格式未改。

历史26.374ms未稳定复现；单独GC诊断的49.001ms受不同采样条件影响，不作直接基线。新对照冷建632.391秒（旧636.001），不宣称建图固定加速；独立warm进程峰值RSS约增加1.406MiB，保留此取舍。全程保留最初12次查询，没有预热排除、强制GC或缩小候选。

位模式测试补齐signed zero、subnormal、有限/非有限边界、非对齐字节回环及旧算法逐位差分；3类错误变异均被抓住。220Flutter+15Python/analyzerclean，Android独立包Debug9检索/数值/批量+4存储场景、ARM64 Profile AOT9合同、Release构建/包身份检查通过。完整源库、图内容及正式库/WAL/6音频共8文件不变；未安装正式包、未提交/推送。证据和复现见 [尾延迟报告](docs/performance/search-tail-100k-2026-11-13/README.md)。

## 内存与首次查询优化（2026-11-13）

十万条／512D 主机 AOT 复测：归一化改为单个 Float64 缓冲区，Float32 解码保留自有连续数据，索引指纹使用 Uint8 拼接；源库及 sidecar 连接明确使用 2MiB 建议页缓存预算。保留向量精度、HNSW 参数和所有原始数据格式。

| 指标 | 优化前 | 优化后 |
| --- | ---: | ---: |
| 3 组成对首查中位数 | 2.487 秒 | 0.995 秒 |
| 首查峰值 RSS 中位数 | 61.250 MiB | 27.766 MiB |
| 3 次独立 warm 峰值 RSS 中位数 | 102.641 MiB | 92.141 MiB |
| 3 次 warm 语义 p95 中位数 | 23.420 ms | 21.439 ms |
| 完整后台准备（单次） | 664.082 秒 | 647.563 秒 |
| 冷建峰值 RSS（单次） | 104.375 MiB | 91.328 MiB |

Recall@10 保持 100%，索引仍为 471.902MiB；所有文档指纹、节点邻接、Float32 向量块与源库字节一致，正式应用库/WAL/6 个音频共 8 文件哈希不变。完整冷建进程另一次首查为 1.295 秒，热语义 p95 为 26.374ms（上轮 22.808），独立最终 warm 为 22.146ms（上轮22.176），不宣称所有尾延迟都改善。合成结果不等于中文理解质量或真机验收；页缓存预算不是总 RSS 硬上限。

最终 213 Flutter、15 Python、静态分析、Android 2 检索+4 存储场景与 ARM64 Release 构建/包身份检查通过；独立只读审查没有重要问题，数值位模式覆盖的 minor 边界保留在报告。依赖与冻结夹具未变，未安装正式包、未提交/推送，既有 WIP 保留。原因、分步候选和全部原始结果见 [内存与首查报告](docs/performance/search-memory-100k-2026-11-13/README.md)。

## 紧凑索引最终验证（2026-11-13）

十万条短文本／UUID／512D Float32、Mac ARM64 独立 AOT 实测。缓存升级到格式 3：整数邻接与词典、独立向量块、预编译 SQL 和 double 累加优化；原库 schema 2、备份 v2、原文及音频不迁移，HNSW 参数不变。

| 指标 | 上一版 | 紧凑版 |
| --- | ---: | ---: |
| 完整后台准备 | 987.890 秒 | 664.082 秒（减少 32.8%） |
| 完成后索引 | 758.434 MiB | 471.902 MiB（减少 37.8%） |
| 独立热语义 p95 | 29.553 ms | 22.176 ms |
| 选择性关键词 p95 | 0.349 ms | 0.278 ms |
| 样本 Recall@10 | 100% | 100%（12 个查询） |
| 冷建进程峰值 RSS | 102.375 MiB | 104.375 MiB |
| 独立热查询进程峰值 RSS | 89.000 MiB | 102.953 MiB |

收益集中于后台准备、体积和热查询；首查 2.434 秒（旧版 2.213），全命中十万条返回 3.853 秒（旧版 3.656），没有全面改善。RSS 包含整个测量进程；不包含 Flutter UI/BGE/ASR 的端到端性能，合成召回不等于中文理解准确率，也不代表手机已验收。完整原始指标、空间构成、失败/中断试验、复现和限制见 [紧凑索引报告](docs/performance/search-compact-100k-2026-11-13/README.md)。

最终 `tool/check.sh`：209 项 Flutter、15 项 Python、静态分析通过；期间发现并修正一项 UI 测试的异步等待误判，产品行为不变。Android API36 独立 `.test` 包的 2 个离线检索及 4 个存储场景通过；ARM64 Release 51.2MB 构建和包身份检查通过，未安装正式包。正式库/WAL/6 个音频共 8 文件与重构前哈希一致，合成源库测量前后逐字节相同，依赖清单/锁文件未变。无 Git 提交/推送，已有改动保留；iOS 完整构建和双平台真机仍待验收。

## 上一版：首次结果与十万条验证（2026-11-13）

首次语义结果不再等待文本索引或整张图：先按页检索原库，索引在后台继续准备；准备中的向量参与精确计算，语义结果保留有界 TopK。后台事务合并邻接更新、保留不变的向量载荷，采用短节点标识和整数倒排引用；缓存独立升级至格式 2，原始 schema 2、备份 v2 和 WAV 保持不变。关闭排空查询后停止后台续建，查询不等待整库建完。

100,000 条短文本／UUID／512D 合成向量、Mac ARM64 独立 AOT 检索进程实测：

| 指标 | 结果 |
| --- | --- |
| 从空 sidecar 首次语义结果 | 2.213 秒 |
| 最终热语义查询 p95 | 29.553 ms，样本 Recall@10=100% |
| 选择性关键词 p95 | 0.349 ms |
| 构建／最终查询复测进程峰值 RSS | 分别 102.375／89.000 MiB |
| 完成后索引体积 | 758.434 MiB（含当时 WAL/SHM） |
| 十万条全命中关键词 | 3.656 秒，保留结果时 RSS 99.266 MiB |

完整后台准备仍需约 16.46 分钟，图和文本都在准备时可先查原记录。十万条验证暴露的上层单路贪心漏召回已修复为 beam=8；保持底层 ef=200，在同一完成图上复测从 91.7% 达到 100%，保留失败数据。结果全量返回、节点页内空闲及真机电耗仍有后续空间。这些数值不包含 Flutter UI 或 BGE/ASR 推理，也不是中文理解准确率。环境、分阶段内存、原始 JSON、复现命令与局限见 [十万条性能报告](docs/performance/search-100k-2026-11-13/README.md)。

本轮最终主机门禁：196 项 Flutter、15 项 Python、静态分析通过；包含原始资料、迁移/备份、后台关闭、派生写入饥饿、压缩与查询交错、缓存别名保护和上层导航回归。Android 独立 `.test` 包的 6 个业务场景、ARM64 Release 构建（51.2MB）通过；正式应用 8 个数据文件和十万条测试源库前后 SHA-256 一致，未升级正式包。已有工作区改动保留，未提交/推送。下方为上一阶段记录。

## 离线索引检索（2026-11-13）

常规关键词查找改用 Unicode 字符倒排，保留中文单字/双字/长子串、全半角、大小写与标点匹配；语义查找改用磁盘 HNSW 候选及原始向量精确重排。两者都在 storage isolate 本地运行，不新增生产依赖或网络请求。日期范围选择更小的访问路径，并用 tuple 游标避免同日翻页重复扫描。界面标明近似语义匹配，精确关键词命中保持完整。

索引保存在可重建的 `search-index.sqlite`，原始 schema 2、备份 v2 和 WAV 不变。源提交独立于缓存，覆盖编辑/删除/迟到写回、模型切换、外部写入、rowid 复用、索引损坏及未来缓存版本。初次文本准备不等待 HNSW 构建；待建图队列持久化，每 8 条图事务让出 worker，期间可继续关键词查找及记录操作。

本轮完整门禁：188 项 Flutter、15 项 Python 测试通过，静态分析无问题。真实 SQLite 的 10,000 条 64D 合成数据中，10 次选择性关键词查询 p95：旧扫描 57.699 ms、倒排 0.496 ms；12 次语义查询 p95 10.461 ms、Recall@10=100%、平均约 293 次向量距离计算。初次文本准备 3.010 s、首次语义图构建 29.586 s、重开对账 0.460 s，sidecar 约 54.6 MB。这是同次主机测试的合成夹具数据，不代表手机或真实中文检索质量；冷建仍有成本，大量关键词命中的返回成本仍与命中数相关。

Android API36 / SQLite 3.54.1：独立 `.test` 包通过 2 个检索业务场景（真实离线 BGE、重开/坏图恢复、1,000 条同日多页及索引计划）和原有 4 个存储升级/备份场景。检索测试禁止 HTTP、不申请麦克风权限、不采集录音；正式应用的数据库/WAL/音频等 8 个文件前后 SHA-256 一致。ARM64 Release 构建通过，约 51.2 MB，仅构建、未覆盖安装正式包；Diff 检查通过，既有改动保留，未提交/推送。详细约束与剩余边界见 [数据存储说明](docs/data-storage.md)。iOS 完整构建、双平台真机和十万条容量仍待验证。

## 专用存储 isolate 与异步读取（2026-11-12）

正式数据库连接、升级、快照、检索排名与恢复事务统一移到持久 storage isolate。首页每页 40 条摘要，详情/追加按需读取，后台每批查询 32 个待处理项；索引通知不重置首页，内容刷新保留已浏览窗口。恢复保持一个事务提交，关闭排空已接收操作，原 schema 2、备份格式 2 与冻结 v1 夹具保留。

完整主机门禁：154 项 Flutter 测试、14 项工具测试通过，静态分析无问题。2 万条真实恢复的一次主机实测为 4193 ms，10 ms 定时器最大事件间隔 39 ms；这是事件循环响应回归，不是真机 P95 或无限容量承诺。Android API36 独立 `.test` 包通过 4 个存储业务用例（原生 SQLite 3.54.1、v1 升级/备份/拒绝未来版本/分页和关闭重开），正式库、WAL 与音频等 8 个数据文件前后 SHA-256 一致。

深浅主题、详情、查找与表单布局与截图检查通过。ARM64 Release 约 51.1 MB，仅构建，未覆盖安装正式应用；仍是 debug 签名试用包。iOS 完整 Xcode 与双平台真机验收仍待完成。设计、并发与取消契约见 [数据存储说明](docs/data-storage.md) 和 [架构审查报告](docs/architecture-review.md)。

## 模拟器真实麦克风（2026-11-12 修复）

本机收音故障已定位到 API36 虚拟音频层的小缓冲导致 `pcm_readi I/O error` 后持续补静音。使用经过 SHA 校验的私有系统镜像副本调整缓冲，保留原 SDK、同一 AVD 数据盘和正式 App。实体扬声器→MOONDROP Rays USB 真麦克风→正式 App 的 24.576 秒录音、完整转写和回放通过，语音查询与确认查找通过，冷启动后再次通过。用户暂时不方便口述，个人自然语音质量留待体验。

原有5条记录、5个音频和全部模型文件字段/哈希保持一致；新增保留1条标明麦克风测试的录音，当前6条。下次重启须使用 `ANDROID_SDK_ROOT=... python3 tool/emulator_microphone.py`，避免普通启动恢复旧配置。工具不结束正在运行的模拟器、不清数据，14项工具测试通过。具体命令、适用版本、截图和回退见 [模拟器麦克风说明](docs/android-emulator-microphone.md)。下方保留之前的排查与验收记录。

## 数据安全与升级保障（2026-11-12）

第一阶段已落地：schema 2 将原始记录与版本化整理/向量缓存分表；v1 升级使用一致快照、原始列比对、事务与完整性校验，未知版本/结构拒绝打开。原始音频不重写，未知孤儿文件移入隔离目录；明确删除和未提交导入副本以持久清理日志恢复。启动失败会释放数据库/模型资源。

备份 v2 保留单个 ZIP 操作，改为 STORE ZIP64 与有界分块，兼容 v1 导入。真实超过 512 MiB 音频包、10,001 条记录往返、冲突与重复、取消、空间不足、SQL 失败均有回归。坏缓存不会阻断详情或备份，本地缺失音频也可从有效备份恢复完整副本。详细格式、资源上限及后续迁移要求见 [数据存储设计](docs/data-storage.md)。

本轮验证：`tool/check.sh` 通过（7 项 Python、120 项 Flutter，静态分析无问题）；独立进程在 DELETE/WAL 的六个迁移阶段遭 OS 强制终止后，12 次均可直接通过生产入口重试升级。Android API 36 / SQLite 3.54.1 的三项存储场景通过，另五项 ASR/BGE/录音转写/语音与语义查询场景通过；全部在独立 `.test` 包运行，未卸载或清理正式包。独立静态复核发现的两项问题已补回归并复核修复。Android ARM64 Release 构建通过（约 51.1 MB），仅生成安装包，正式包未覆盖安装。Swift 语法解析通过，完整 iOS 构建与真机升级、超过 4 GiB 实包、自然口述及长期性能仍未验证。以下保留早期各轮验收记录，数量不代表当前最新测试数。

## 模拟器覆盖升级验收（2026-11-12）

已使用 `adb -s emulator-5554 install -r` 覆盖安装正式 Release，未卸载或清数据；新旧签名一致，安装后 APK SHA 与本次构建一致。升级前先归档数据库、WAL、音频与模型。schema 1→2 后及全部验收结束时，原4条记录的12个原始字段逐值一致，原4个WAV和6个模型目录文件SHA-256均一致。当前保留原4条及1条标为“升级回归测试”的带音频样例，5条语义索引就绪；正式App停在深色首页。

实际操作：原生录音停止落盘、失败保留、测试音频恢复后自动转写、回放到结尾和重新转写、关键词与非原文语义查询均已检查。正向转写使用已知合成WAV经系统文件选择器导入，不能代表自然麦克风口述通过；SDK注入未得到有效语音，不宣称收音问题已解决。测试结束恢复宿主麦克风入口为开启，无录音或注入任务运行。

正式设置页生成v2备份（5条/5音频）；系统分享无本地保存目标，使用ADB将已生成包另存到Downloads，并取消分享，没有发送到云服务。ZIP CRC、原始字段和音频SHA校验通过。系统选择器重复导入显示“新增0、跳过5、冲突0”；只删除本轮新增样例后再恢复显示“新增1、跳过4、冲突0”，样例正文/转写/修订与音频SHA恢复一致。最终完整性检查通过，无临时查询文件或待清理日志。Downloads保留 `nianxia-upgrade-roundtrip-v2.zip` 供手动体验。

发现并修复两处提示：无正文的失败录音不再显示“等待转写”；共享识别引擎不再声称查询音频已保留，文件保留由业务层处理。两处均有回归；`tool/check.sh`通过（122 Flutter、7 Python、analyzer clean），Android隔离模型5场景重新通过，ARM64 Release构建并再次覆盖安装。截图：[升级后首页](docs/screenshots/android-upgraded-home.png)、[样例转写详情](docs/screenshots/android-upgraded-transcription.png)、[语义找回](docs/screenshots/android-upgraded-semantic.png)、[删除样例后恢复](docs/screenshots/android-upgraded-restore.png)、[查询失败提示](docs/screenshots/android-upgraded-query-error.png)。

## 当前完成度（2026-11-10 核查）

整体设计适合个人和小范围试用：快捷记录与查找分开，正文、原始音频和派生结果独立，SQLite 与应用操作层承接一致性，硬件和外部系统留在适配边界。当前首页主次入口明确，沿用中性主题；本轮优先补齐失败恢复，未引入新的架构或控件框架。

| 范围 | 当前状态 |
| --- | --- |
| #2–#14 核心功能 | 已接入，主机测试和 Android 试用构建可运行；各票中的设备、质量与性能条件仍须验收 |
| 本轮确认的代码缺陷 | 4 项已修复：失败录音丢弃确认、导出容量、恢复取消边界、系统文件选择异常 |
| 本轮验证 | 57 项主机测试、`flutter analyze`、ARM64 Release 构建及模拟器安装通过；数据增量独立静态复核通过 |
| iOS | 本机开发目录仍为 Command Line Tools，完整 Xcode 构建、签名和安装未完成 |
| 完整验收 #15 | Magic8/iPhone 17、50 条口述、30 条人工标注查询、真实提醒、性能/发热与系统备份排除实测未完成 |
| 可选付费整理 | 受控响应测试已覆盖；真实调用仍需用户提供测试 Key、非敏感内容和付费测试授权 |

本轮新增 5 项回归先观察到失败，再修复通过。保存失败后关闭有音频的面板必须确认，取消确认保留恢复片段；ZIP 同时检查正文、清单与最终封装大小，超限清理临时包；恢复在异步音频核验后、事务前再次检查取消；文件选择异常有反馈，等待选择时禁用重复操作，取消后释放状态。原有数据与音频保留。UI 增量经过自审、主机操作回归和模拟器检查；未以此宣称完整无障碍或真机通过。

本轮实际界面核查（Android API 36 ARM64 Release）：

1. [首页](docs/screenshots/android-audit-home.png)：录音、文字、查找层级清楚，未准备转写时可见准备入口。
2. [设置](docs/screenshots/android-audit-settings.png)：分组、隐私说明与外观入口可读；低频说明较多，后续可据试用反馈压缩。
3. [恢复确认](docs/screenshots/android-audit-restore-confirm.png)：导入前说明冲突、副本与未加密边界。
4. [系统文件选择器](docs/screenshots/android-audit-picker.png)：成功打开，无本地可选备份；本次不导入或改变既有记录。
5. [取消后返回](docs/screenshots/android-audit-restore-cancelled.png)：显示“已取消选择备份”，导出和恢复入口重新可用；检查结束返回首页。

采集失败和平台异常由适配边界注入验证，容量回归使用真实临时 SQLite、有效 WAV 和文件；未将模拟器静音音频后端计为真实麦克风验证。Android 构建仍有既有 Gradle/AGP/Kotlin 后续支持和 SDK XML 工具版本提示，未跳过校验。

## 已接入的流程

- 文字记录、时间线、详情、修订、收藏、独立追加与整组删除；SQLite 和私有音频持久化。
- 两分钟短录音、原音频回放、启动恢复检查；先保存，再本地转写。
- 关键词/日期查找、BGE 语义增强、临时语音查询；模型不可用保留文字路径。
- 可信清单固定模型文件和 SHA-256，流式下载后原子启用，默认不下载模型。
- 系统桌面“记一下 / 找一下”快捷动作、Android 快捷设置录音磁贴与透明胶囊、iOS App Intents 接入、原创声纹便笺图标、黑白灰浅深主题。
- 手动事项或整理候选进入系统日历编辑器；Android 保存结果显示未确认，iOS 仅 saved 回调表示成功。
- 用户自带 DeepSeek Key，每次确认单条正文后整理；结果与正文分开，编辑后标过期。不自动重放付费请求。
- 未加密 ZIP 备份（包含可读文本与 WAV），重复跳过、冲突副本和追加关系重映射。索引可重建。

## 当前视觉样式（便笺布局）

按已确认的单列便笺预览落地现有 Flutter UI，继续使用系统控件与项目原创标记，没有新增运行时依赖。默认深色，首页右上角可切换深浅主题，设置仍保留浅色、深色和跟随系统；选择保存在本地，重启后继续使用。首页直接切换全部/收藏，滚动查看完整记录，底部固定“记一下 / 写文字”；收藏追加记录仍可单独找回所属记录。

深色使用 #212121 画布、#303030 便笺与输入区、#393939 选中层、#F5F5F5 正文和主按钮、#B4B4B4 辅助文字；浅色使用 #FFFFFF 画布、#F7F7F8 列表、白色便笺、#171717 正文和主按钮、#666666 辅助文字。这些是项目自定 token，不是官方 ChatGPT 标准。便笺 22px 圆角、胶囊按钮，保留 48dp 触控和两倍字体布局。

录音面板使用真实时长与音量，停止成功落盘才反馈；失败仍可重试、确认丢弃或转文字。查找保留关键词即时检索、日期和降级路径，语音识别后可先修改查询，再明确确认查找；查询不会成为笔记。详情保留原文、音频和原始转写，底部固定编辑/追加入口，日历、云端发送确认及独立追加的数据语义保持不变。原始音频播放器在首次播放时才创建，未加载时不开放拖动进度；播放结束恢复播放按钮，单击即可从头重播。

本轮主机 widget 截图：[浅色首页](docs/screenshots/notecard-home-light.png)、[深色首页](docs/screenshots/notecard-home-dark.png)、[录音面板](docs/screenshots/notecard-recorder-dark.png)、[查找](docs/screenshots/notecard-search-dark.png)、[详情](docs/screenshots/notecard-detail-dark.png)。截图使用临时样例与测试采集适配，不表示真机录音、回放或模型质量已经验收。下方保留此前界面迭代和平台验证记录。

2026-11-11：`flutter test` 69 项通过、`flutter analyze` 无问题、Android ARM64 Release 构建并覆盖安装到 `nianxia-api36` / `emulator-5554`（Android 16 / API 36）。实际点击验证录音停止保存、两分钟自动保存、丢弃确认/继续录制、播放/暂停/跳转，文字查找/无结果/模型缺失提示，详情编辑/追加/所属记录，深浅主题、主题冷启动保留以及系统两倍字体。系统字体已恢复 1.0，麦克风权限已恢复，模拟器停在深色首页；原有数据保留，新增合成测试记录仍保留。

实测修复：明确查找后收起键盘，保留输入期间即时检索；多行摘要不重复标题，也不误删正文中的真实重复首行；新建录音/文字及录音失败转文字保存成功后退出收藏并回到列表顶部，取消保留上下文；主题选择持久化，写入失败时提示且保留原选择。回归覆盖这些路径及 SQLite 只读故障。

本轮 Android 实际截图：[深色首页](docs/screenshots/android-notecard-home-dark.png)、[浅色首页](docs/screenshots/android-notecard-home-light.png)、[录音](docs/screenshots/android-notecard-recorder.png)、[查找](docs/screenshots/android-notecard-search.png)、[详情](docs/screenshots/android-notecard-detail.png)、[系统两倍字体](docs/screenshots/android-notecard-large-font.png)。模拟器采用 `-audio none` 绕过宿主 CoreAudio 初始化阻塞，因此录制/回放验证的是静音音频链路和交互，不代表真实收音或音质通过；上述 UI 检查阶段尚未准备模型；后续完整模型验收结果见“验证”一节。iOS、真机仍未执行。

视觉验证扩展到浅/深色的首页、查找、详情、设置、编辑和日历表单，并检查小屏、两倍字体及实际可命中的设置入口。52 项主机测试和静态检查通过；独立 Standards / Spec 评审及后续缩放回归已完成。Android 原生运行与截图见当前交付记录，iOS 和真机继续按原安排后移。

后续流程打磨：查找支持一键清空、结果数量、无结果时放宽日期和失败重试；搜索框与结果共同滚动，修复小屏大字加键盘的溢出。录音面板以真实时长、音量和中文状态为中心；日历按事项、时间提醒分组，并修复大字体提醒选项横向溢出。检索算法、录音控制器及系统日历桥未变。

当前截图：[Android 浅色首页](docs/screenshots/android-polish-home-light.png)、[深色首页](docs/screenshots/android-polish-home-dark.png)、[详情](docs/screenshots/android-polish-detail.png)、[设置分组](docs/screenshots/android-polish-settings.png)；[深色编辑页](docs/screenshots/widget-polish-editor-dark.png)为主机 widget 渲染。原生导航验证完成后已返回首页，回放进度轨道与 48dp 手势区域保持可用。

本轮流程截图：[查找无结果](docs/screenshots/android-flow-search-empty.png)、[日历分组](docs/screenshots/android-flow-calendar.png)、[两倍字体日历](docs/screenshots/android-flow-calendar-large-type.png)、[浅色录音](docs/screenshots/android-flow-recorder-light.png)、[深色录音](docs/screenshots/android-flow-recorder-dark.png)。录音截图与确认丢弃流程使用模拟器临时 `-audio none` 后端，不能作为真实采集或回放验收。

本机默认音频后端在启动麦克风时可复现 QEMU 宿主线程卡住；线程采样落在 `AUD_open_in → coreaudio_init_impl → AudioDeviceCreateIOProcID → CoreAudio`。冷启动仍复现，静音后端可运行录音界面。真实 USB 输入设备尚待重连复测，未修改应用录音控制器或系统默认音频设备。

## 试用反馈：首页更直接

2026-11-09 按试用反馈将时间线首页调整为轻量操作首页：主入口“录音记一下”，并列次级入口“写文字 / 找一下”，下方显示最近三条；“全部记录”进入完整列表及收藏。未转写录音使用创建时间作显示名称，完整原文和音频保持不变。首页显示未就绪的离线转写及准备入口，直接进入模型下载区域；不自动下载或发起云端请求。

沿用现有中性色、系统字体、原创标记及减少动态效果；记录行缩短间距，查找页减少技术术语。两倍字体时次级动作纵向排列。新增应用操作回归覆盖最近三条与完整列表、模型未准备到就绪的提示变化，并扩大记录列表的大字及触控验证。44 项主机测试、分析器和 ARM64 Release 构建通过；本轮 Standards / Spec 独立静态评审均未发现新增确定性问题，不代表 iOS 或真机已验收。

运行截图：[新版首页](docs/screenshots/android-dashboard-light.png)、[深色首页](docs/screenshots/android-dashboard-dark.png)、[离线功能准备](docs/screenshots/android-model-preparation.png)。Android 模拟器实际检查了模型准备入口、完整列表及收藏、文字编辑返回、已有记录查找和深浅主题切换；当前模拟器保留在新版首页。

## 快捷呼出录音

Android 下拉快捷设置，编辑并添加“记一下”磁贴；也可长按桌面图标选择“记一下”。无需先进入记录列表，直接显示顶部录音胶囊。停止落盘成功才显示已保存，系统返回键也会停止保存；确认丢弃会删除未保存音频。完成后点击“返回原应用”。离开前保留尚未保存的文字编辑，后续查找也不清空编辑栈。

应用内录音失败且没有音频草稿时，可直接“写文字”；从详情追加语音发起时可“追加文字”，保存后仍属于原记录。有音频草稿的失败保留重试保存/丢弃，查询失败不进入笔记编辑器。新增四项公开操作回归验证权限拒绝、追加关系、查询边界及有效片段重试。 Android 实际拒绝权限后已核对[新建文字入口](docs/screenshots/android-recorder-text-fallback.png)和[追加文字入口](docs/screenshots/android-recorder-append-fallback.png)，检查进入对应编辑器并空白返回；权限与浅色首页已恢复。

支持只含操作的 `nianxia://capture` / `nianxia://search` 链接；Android 还提供 `app.nianxia.CAPTURE` Intent。手机 AI 键若允许绑定应用快捷动作或 URL，可指向录音入口；不宣称所有厂商按键都可绑定。应用设置中提供说明及复制录音链接。没有新增悬浮窗、无障碍服务、后台麦克风或常驻监听权限；切换应用/锁屏停止保存，启动阶段退到后台也不继续开始采集。

iOS 接入“记一下/找一下”App Intents，可供系统快捷指令及操作按钮配置；也可用“打开 URL”动作。系统会将应用带到前台的胶囊界面，可能需要解锁，不是跨应用悬浮窗或 Dynamic Island Live Activity。iOS 不使用私有退后台 API，“完成”返回记录页。**这些 iOS 原生代码尚未通过完整 Xcode 构建或设备验证。**

平台接口依据：[Android TileService](https://developer.android.com/reference/android/service/quicksettings/TileService)、[Flutter 透明 Activity](https://docs.flutter.dev/add-to-app/android/add-flutter-screen)、[Apple AppShortcutsProvider](https://developer.apple.com/documentation/appintents/appshortcutsprovider)。Android 14+ 磁贴使用 PendingIntent，旧系统使用对应旧 API；URL 交接保留冷启动 pending 动作，并禁用重复的 Flutter 默认深链处理。

## 本地运行

本轮本机 SDK 位于 `$HOME/.local/share/nianxia-toolchain/flutter`，没有改写 shell 配置。当前终端可先执行 `export PATH="$HOME/.local/share/nianxia-toolchain/flutter/bin:$PATH"`；若需要本轮专用仓库初始化配置，再临时设置 `GRADLE_USER_HOME="$HOME/.local/share/nianxia-toolchain/gradle-home"`。

本轮工具链：Flutter **3.47.9** / Dart **3.13.7**，JDK **17**，Android compile/target **36**、min **24**、NDK **28.2.13676358**；Android 试用构建限 ARM64。iOS 工程最低 **17.0**，需完整 Xcode、签名及依赖安装环境；这些是构建配置，不代表已通过所有对应系统的测试。

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d <device-id>
flutter build apk --debug --target-platform android-arm64
# 完整 Xcode 环境中执行，当前电脑尚不能验证：
flutter build ios --no-codesign
```

Android 采用已通过配置阶段的 Gradle **8.14.3** / AGP **8.13.1** / Kotlin **2.2.21**。Flutter 对这组版本有将来移除支持的提示；升级时须重新跑插件与同包推理验证。本次没有跳过依赖检查或降低验证断言。若 Gradle 插件仓库握手失败，可在**本机专用** Gradle user home 的 init.d 中优先配置官方 Maven Central / Google，保持工程仓库不指向非官方镜像。GitHub 资产下载失败时，可从同一官方 release 的 assets API 获取文件，并保留 wrapper / SQLite 既有 SHA-256 核验。

默认 Android 调试包及当前 release 配置使用本地 debug 签名，仅用于试用，不能直接用于应用商店发布。没有自动提交、上传或部署脚本。

## 模型与隐私

模型文件不进入安装包，清单在 `assets/models.json`，使用固定 Hugging Face revision。SenseVoice INT8 与 tokens 约 **239.55 MB**；BGE INT8 与 vocab 约 **24.01 MB**；无需解压，内存占用不能据此推断。下载会访问模型分发服务；转写、查询和索引不上传内容。

Android 语音和 embedding 使用 sherpa 携带的 ORT 1.28.2；embedding 通过 `onnxruntime` Dart 包的稳定 C API 调用，排除其旧 Android 二进制。iOS 的 sherpa 框架隐藏了通用 ORT 符号，embedding 由该 Dart 包的独立 ORT 1.15.1 依赖提供；双端均串行执行并在任务结束释放模型。iOS 组合仍须实际构建及真机核验。BGE 使用固定 Xenova INT8 转换、区分大小写的 BERT WordPiece、CLS pooling、L2 归一化及中文 query 指令；长正文分窗聚合。模型版本变化使用不同目录，索引绑定当前正文修订。

内容位于应用私有目录。Android 禁用自动备份并配置 cloud/device-transfer 排除；iOS 启动时配置并核验目录排除。Key 存 Keychain/Keystore 支持的安全存储，iOS 使用 this-device-only 可访问级别；无账号、遥测或共享服务密钥。**本地文件及导出文件不宣称已加密。** 导出选择云盘、使用同步日历或主动确认云端整理，会使对应内容离开设备。

当前导出备份格式 v2：单个 STORE ZIP64、分块原始记录和可读文本、原始 WAV，移除旧整包 512 MiB / 10,000 条限制；保留单条/元数据/空间预算与严格校验。兼容 v1 导入，最终事务合并、重复跳过、冲突副本及追加关系重映射。模型、凭证、缓存和临时查询不导出，不重放云端请求。分享返回后清理应用内导出原件，是否另存以目标应用实际结果为准。完整契约和升级边界见 [数据存储设计](docs/data-storage.md)。

## 验证

2026-11-11 完整模型补验：Android API 36 ARM64 中，SenseVoice 与 BGE 已在正式应用私有目录就绪，四个文件 SHA-256 与固定清单一致。飞行模式、Wi-Fi/移动数据关闭、`Active default network: none` 下，五个原生场景通过：ASR/BGE 同包推理、原生 PCM 录音与回放、公开及已知 TTS 语音识别、录音落盘→后台转写→语音查询确认→语义结果→编辑/删除索引、静音失败仍保留原音频且查询不入库。完整场景在 integration debug 包执行，正式 Release 覆盖安装后再次确认模型就绪及正常入口；主机测试 70 项、静态检查和 ARM64 Release 构建通过。

实测修复模型校验尚未完成时提前显示“下载模型”的问题：现在显示“正在检查本地模型…”，完成后显示已就绪或下载入口，避免误触重复下载；延期校验回归先失败再通过。截图：[模型就绪](docs/screenshots/android-models-ready.png)、[录音转写详情](docs/screenshots/android-model-recording-transcribed-detail.png)、[语音查询确认](docs/screenshots/android-model-voice-query-review.png)、[语义结果](docs/screenshots/android-model-semantic-voice-result.png)、[无关查询无结果](docs/screenshots/android-model-semantic-unrelated-empty.png)。

测试执行事故：首次 `flutter drive` 未带 `--keep-app-running`，驱动结束时默认卸载并清除了模拟器应用数据，旧记录未能从备份/快照恢复。模型已从同 SHA-256 的公开缓存恢复；该次结束时正式笔记库为空，未恢复旧记录。现已通过恢复入口加入下文四条新音频样例。测试已改为独立包和私有目录，并实测运行前后正式笔记、音频的完整归档 SHA-256 一致；以下命令使用隔离入口。网络、正常字体和麦克风授权已恢复，最终回到深色首页；未做真机收音或自然口述质量验收。

主测试边界是应用操作与可观察持久结果，主机测试使用真实临时 SQLite/文件。原生能力单独验证，替身结果不表示硬件或系统通过。运行截图可通过以下可选参数生成，字体文件仅用于本地视觉检查，不打包或提交系统字体：

```sh
flutter test test/visual_test.dart \
  --dart-define=SCREENSHOT_DIR=/absolute/output \
  --dart-define=SCREENSHOT_FONT=/absolute/chinese-font.ttf \
  --dart-define=SCREENSHOT_ICON_FONT=/absolute/MaterialIcons-Regular.otf
```

Android 模型测试使用独立包 `app.nianxia.nianxia.test`（桌面名“念下·测试”）。所有 `integration_test/` 目标和 `tool/manual_audio_demo.dart` 目标在任何构建模式中都固定使用该包名；普通 Debug 也与正式 Release 隔离。测试入口校验自身私有缓存路径，仅使用 `/data/local/tmp/nianxia-models` 的可信公开模型，笔记写入测试包的临时目录。正式 App 的私有数据目录不参与测试。

先按固定清单准备模型及官方 `zh.wav` 到本机，`MODEL_FIXTURES` 包含 `sensevoice.int8.onnx`、`tokens.txt`、`bge.int8.onnx`、`vocab.txt`、`zh.wav`，然后使用唯一推荐入口：

```sh
ANDROID_SERIAL=emulator-5554 ANDROID_SDK_ROOT=/absolute/android MODEL_FIXTURES=/absolute/fixtures tool/stage_android_models.sh
python3 tool/run_android_model_tests.py --target smoke
python3 tool/run_android_model_tests.py --target full
```

脚本固定 Debug、模型目标白名单和 `--keep-app-running`，只接受 QEMU 模拟器；安装前通过 aapt 核对 `.test` 包名，使用 `adb install -r`，安装失败即停止，无卸载/清数据回退。安装、授权或驱动失败也会再次核对正式 App 的安装路径。`ANDROID_SDK_ROOT` 与 Flutter/JDK 按本机配置，Flutter 不在 PATH 时可设置 `FLUTTER_BIN`。脚本的错误包、真实设备、安装/授权/驱动失败分支由 `python3 -m unittest discover -s tool/tests` 验证，已加入 `tool/check.sh`。

完整链路另需三段 16kHz 单声道 PCM16 测试音频。macOS 已安装 Tingting 和 ffmpeg 时可准备：

```sh
say -v Tingting -r 165 -o /tmp/nianxia-note.aiff '给数据库建立索引，可以加快查询速度。'
say -v Tingting -r 165 -o /tmp/nianxia-query.aiff '怎样优化数据库的查询性能'
ffmpeg -y -i /tmp/nianxia-note.aiff -ar 16000 -ac 1 -c:a pcm_s16le /tmp/nianxia-note.wav
ffmpeg -y -i /tmp/nianxia-query.aiff -ar 16000 -ac 1 -c:a pcm_s16le /tmp/nianxia-query.wav
ffmpeg -y -f lavfi -i anullsrc=r=16000:cl=mono -t 1 -c:a pcm_s16le /tmp/nianxia-silence.wav
adb -s emulator-5554 push /tmp/nianxia-note.wav /data/local/tmp/nianxia-models/note.wav
adb -s emulator-5554 push /tmp/nianxia-query.wav /data/local/tmp/nianxia-models/query.wav
adb -s emulator-5554 push /tmp/nianxia-silence.wav /data/local/tmp/nianxia-models/silence.wav
```

完整集成包含真实 ASR/BGE、原生 PCM/回放、录音后台转写、语音确认后查找、查询清理、语义正负对照和编辑/删除索引。测试音频仅替换麦克风输入边界，模型、文件、SQLite与控件均真实。截图位于测试包的 `code_cache/model-check-results`，通过 `adb exec-out run-as app.nianxia.nianxia.test cat <路径>` 提取。测试结束无需覆盖安装正式 App。

这条测试是原生推理与采集/回放的适配测试，不能代替 50 条真实口述、30 条人工标注查询、离线网络检查、来电/锁屏/强杀、真实日历提醒、性能与发热验收。荣耀 Magic8、iPhone 17 的设备结果、iOS 签名安装与真实付费调用仍需相应设备和用户主动提供的测试条件。未完成的 GitHub Issue 保持打开。

## 模拟器手动体验音频样例

正式“念下”中已通过恢复入口加入四条带音频样例：数据库优化、周末散步、产品讨论、番茄炒蛋，音频开头均说“测试记录”，总计约34.5秒。由真实本地模型转写和建立索引；详情可回放、查看原始转写、重新转写和编辑。第三条“上午十点”出现数字识别误差，保留原始结果便于体验核对纠错。

当前宿主 CoreAudio 输入有故障。独立“念下·测试”的 `tool/manual_audio_demo.dart` 提供明确标注的预置 PCM 音频输入，使用真实 ASR/BGE、文件、SQLite 和相同产品界面，数据位于测试包自己的 `manual-demo` 目录，与正式 App 独立。顶部选择主题，点“找一下→语音查找”，等顶部显示“音频输入完成”后停止，核对文字再查找；“记一下”也可使用所选预置音频体验保存转写。

体验模式需要在公开模型缓存目录另外放置 `manual-demo.zip`（四条待转写音频备份）及 `voice-demo-query-1.wav` 至 `voice-demo-query-4.wav`。准备后运行 `python3 tool/run_android_model_tests.py --target demo`；脚本同样核对测试包身份，安装后直接打开体验界面，不启动测试驱动。重复打开不会再次导入样例。自动化测试会替换测试包入口，重新运行 demo 命令即可恢复体验入口，正式 App 始终不参与。

预置查询为“怎样加快数据库的查询速度”“周末去公园走走拍照”“讨论产品原型和交互方案”“番茄炒蛋怎么做”。这些与记录全文不同，供语义找回对照。预置输入不代表真实麦克风收音通过。

本次安全测试回归：7 项 Python 脚本测试、71 项 Flutter 主机测试、静态检查通过，五个原生场景通过（包含播放结束后单击重播）。在正式 App 已有四条新样例时运行隔离测试，运行前后笔记与音频完整归档 SHA-256 均为 `705f8b6c2c2a5292f46432d648bfc8a9942e870c6a4eec3d3b300d79b9389544`。四种预置语音查询均已实际点击识别并找回对应记录，详情重新转写通过。截图：[正式样例](docs/screenshots/android-safe-formal-samples.png)、[语音确认](docs/screenshots/android-safe-voice-review.png)、[语义结果](docs/screenshots/android-safe-semantic-result.png)。

### 真实麦克风补验（2026-11-11）

已取消模拟器进程的 `QEMU_AUDIO_IN_DRV=none`，恢复 `coreaudio` 并启用 `-allow-host-audio`。当前宿主输入为 MOONDROP Rays USB；macOS 直接采集正常，本轮 Android 读取音频未再复现 CoreAudio 初始化卡住。但实体扬声器拾音对照在 Android 端电平仍偏低，未通过有效语音检查；48kHz 输入与 SDK 注入对照也未解决，已撤回实验设置，不运行实时桥接服务。用户当前不方便口述，因此真实说话转写和语音查找仍未验收，不能将入口已开启视为修复完成。正式 App 现有数据已先备份，未重装或清除；生产录音逻辑和语音检测门槛未变。

## 来源与许可

模型归属：SenseVoiceSmall / FunASR，BGE / BAAI；转换分发：k2-fsa 的 csukuangfj 与 Xenova。SenseVoice 依据 [官方模型卡](https://huggingface.co/FunAudioLLM/SenseVoiceSmall)及 [FunASR 模型许可](docs/licenses/FunASR-MODEL-LICENSE.txt)，BGE 为 [MIT](https://huggingface.co/BAAI/bge-small-zh-v1.5)。运行时及 Dart 依赖许可可在应用“版本与开源许可”中查看。源码归属和模型许可分别核对，不能将 sherpa 的 Apache-2.0 直接当作权重许可。

DeepSeek 请求使用 `deepseek-v4-flash` 兼容别名，明确关闭思考并使用非流式 JSON 输出。2026-11-10 核对[官方模型说明](https://api-docs.deepseek.com/quick_start/pricing/)：该旧别名仍被接受，原对应模型已退役，实际由 DeepSeek-V4.1-Flash-1017 提供服务；因此不能将请求中的别名视为锁定的模型版本。[请求参数](https://api-docs.deepseek.com/api/create-chat-completion/)与[JSON 输出规则](https://api-docs.deepseek.com/guides/json_mode/)仍兼容当前实现，包括空白响应检查。固定官方 HTTPS 地址，不允许任意 Base URL。此核对未调用付费 API；格式与来源校验不保证语义完全正确，整理结果仍需用户核对。

## Standards

独立评审初稿发现 3 项规范问题，均已修复并做回归验证：

- **P1 两分钟保存边界**：墙钟计时后停止会产生略超两分钟的样本，原校验会拒绝整段；违反可靠保存规则。改为 PCM 样本边界落盘，再停止设备，`capture_controller_test.dart` 验证跨过上限的最后一帧仍保存完整两分钟。
- **P2 备份上限不对称**：原导出可生成恢复拒绝的 10,001 条备份；违反可恢复要求。导出与恢复共享 10,000 条上限，`backup_test.dart` 验证生成前拒绝且原记录保留。
- **P2 查询停止失败清理**：原生 stop 失败会绕过转写中的 finally；违反查询临时文件清理规则。统一停止、关闭文件及删除路径，`capture_controller_test.dart` 注入 stop 失败验证立即清理。

该轴共 3 项，最严重为 P1，已修；没有额外保留的 code smell 建议。

胶囊增量的独立 Standards 评审未发现新增硬性规范违例，另提出 **P1 待核对路径**：胶囊完成后转查找仍会弹出并销毁隐藏编辑器。现已移除强制清空导航栈，回归覆盖“未保存编辑 → 胶囊保存 → 查找 → 返回原编辑”，正文保留。

## Spec

独立评审初稿发现 3 项实现错误，均已修复：

- **P1 两分钟自动保存**：#3 要求“到达自动停止保存”，原计时/字节限制冲突；修复与 Standards 第一项相同。
- **P1 恢复后编辑再导入**：#14 要求“ID相同内容不同保留冲突副本并提示”，原历史指纹直接跳过。现在核验当前正文、元数据、音频哈希及父关系，生成冲突副本并更新映射；`backup_test.dart` 验证再导入与重复导入。
- **P2 收藏追加不可见**：#10 要求收藏在时间线/详情可见，原收藏页仍只选根记录。现在显示收藏追加并保留所属记录导航，`ui_test.dart` 验证用户操作路径。

未发现实质范围扩张。该轴另有 **1 项未完成的验收范围**：#15 的 Magic8/iPhone 17、iOS 安装、真实提醒、50 条口述、30 条人工标注查询及手机性能/发热。代码和模拟器通过不能替代这些验收，因此不关闭对应 Issue。该轴最严重实现错误为 P1，已修；完整产品验收仍未完成。

胶囊增量独立 Spec 评审发现 **1 项 P2 缺口**：拒绝麦克风后缺少规格要求的文字入口，现已添加“写文字”并通过用户操作回归；未发现范围蔓延或其他已确认的增量错误。该轴仍保留双端真机及 iOS 原生行为的验收缺口。

## 本轮实际验证

- `flutter analyze`：通过。
- `flutter test`：52 项主机测试通过，覆盖应用行为、真实 SQLite/文件、故障注入与界面；包含浅深主题、两倍字体、无障碍触控/标签及减少动态效果。新增胶囊重复呼出、返回保存、编辑保留、拒绝权限转文字、确认丢弃及启动期间退后台回归。
- Android API 36 ARM64 模拟器、飞行模式：通过 `flutter drive` 执行真实 SenseVoice + BGE 同包、语义有/无结果、原生 PCM 录音和 WAV 回放。仅使用公开模型样本和合成文本。
- 1,000 条合成短记录、主机 20 次关键词查询 P95：约 9.4 ms，非手机指标。
- [浅色时间线](docs/screenshots/home-light.png)、[深色时间线](docs/screenshots/home-dark.png)、[查找](docs/screenshots/search-light.png)、[详情](docs/screenshots/detail-light.png)为实际 widget 运行截图，非真机截图。
- Android API 36 ARM64 Release、飞行模式：实际运行通过 URL 冷启动、重复呼出不截断、系统返回保存并返回原系统设置页面、实际点击快捷设置磁贴的热启动、深色主题、原生权限拒绝与首次授权；截图见[录音胶囊](docs/screenshots/android-capsule-recording.png)、[深色胶囊](docs/screenshots/android-capsule-dark.png)、[保存完成](docs/screenshots/android-capsule-saved.png)、[权限失败](docs/screenshots/android-capsule-permission.png)。均为模拟器，未冒充真机。
- 原生重复呼出验证捕获并修复了短暂 `inactive` 被当作退后台而截断录音的问题；隐藏/暂停/分离及 Android 系统息屏事件触发自动保存，音频中断仍通过原生录音状态处理，符合 [Flutter 生命周期语义](https://api.flutter.dev/flutter/dart-ui/AppLifecycleState.html)。冷启动一次 `am start -W` 活动展示约 0.7 秒，只是系统展示耗时，不是采集延迟或 P95。
- Swift 前端语法解析通过；`flutter build ios --no-codesign` 未能构建，提示 `Application not configured for iOS`。此前构建未通过；当前已安装 CocoaPods 1.17.0，开发目录仍为 Command Line Tools，完整 Xcode 尚未就绪。此结果不表示 iOS 已构建或安装通过，iOS 工作继续按用户安排后移。
- 模拟器 ExoPlayer 释放时观察到 `Handler ... on a dead thread` 警告，回放完成断言及整个 driver 均通过；尚未在真机确认是否复现。
- 真实付费 API、双端真机日历提醒、双端系统备份排除的设备实测均未执行；Android 模拟器通知链路的结果见下节。

当前便笺 UI 的 Android ARM64 Release 试用包已构建，约 **51.0 MB**（不含首次下载的模型），仍使用本地 debug 签名；APK 仅包含 ARM64 与单一 ORT 运行时。本轮已覆盖安装运行并完成上述 UI 交互复测；既有原生能力验证记录见上文。产物为 `build/app/outputs/flutter-apk/app-release.apk`，最新覆盖升级验收包 SHA-256：`5cf4a356887cf37cf6951466cb96a2b20b3c89fc0181ada1b34d4db73bb883e3`。

运行集成测试后再构建 Release 时使用上面的正常 `flutter build apk --release --target-platform android-arm64`，让 Flutter 重新生成排除测试插件的注册文件；不要复用测试阶段生成的注册文件直接加 `--no-pub`。Flutter 的分析、主机测试与平台构建应串行执行，避免生成的插件注册文件互相覆盖。

Release 包还在模拟器中通过实际界面完成了文字创建、持久显示和关键词查找；Android 包管理器核验未设置 ALLOW_BACKUP，此前仅凭 `resolve-activity` 的空结果判断缺少日历应用不充分。本轮实际启动验证发现 Google 日历存在，但离线首启进入联网账号页；专用模拟器现配置 Etar 离线日历用于接入验证，真机保存与提醒仍未验收。

## 当前模拟器阶段

用户于 2026-11-09 明确将真机验收后移，先使用模拟器推进。当前 Android API 36 ARM64 已验证；物理 AI 键、真机录音质量、耗电和发热仍留在后续验收中。

- **录音生命周期**：Release 中连续验证 0.5 秒、0.5 秒、1 秒息屏，均停止落盘且唤醒不自动续录；录音中强杀后重启恢复有效片段。短暂 `inactive` 不可靠地代表息屏，最终实现使用受保护的系统 `SCREEN_OFF` 广播；亮屏解锁的重复快捷动作仍不截断。启动时检查交互/锁屏状态，未知、异常和 500ms 超时不开始采集。回归还覆盖权限等待中息屏和迟到响应。
- **日历接入**：通过念下记录进入 Etar 1.0.57 的系统编辑器，核对标题、日期、08:20–08:50 和时区正确传递；提醒没有通用预填，Android 页现明确为“计划提醒时间”，逐项展示需手动设置的值。本次在接收端手动设为 0 分钟后保存，观察到对应合成事项的日历通知，返回念下仍如实显示保存未确认；另验证系统页取消后也返回未确认，没有虚报保存成功。这条合成事项保存时已略过开始时刻，因此不作为准点或通知延迟验证。
- **后台定时通知未通过**：另建合成事项 `Scheduled202611090903`，09:01 提前保存 09:03 开始、0 分钟提醒的事件，退出念下并息屏。系统于 09:03:00.026 将 `EVENT_REMINDER` 送达 Etar；Etar 的 `AlertWorker` 随后因 `ForegroundServiceStartNotAllowedException` 失败，观察窗口内未出现该事项通知。该结果保留为接收端兼容性限制，不能用前台保存后的通知代替后台准点验收；从后台启动前台服务的限制见 [Android 官方说明](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)。
- **日历条件隔离验证通过**：仅为 Etar 临时设置电池优化豁免，经系统编辑器直接创建 `BatteryCheck202611090912`（09:12 开始、0 分钟提醒），09:09 提前保存后退到后台并息屏；09:12:04 轮询时对应通知已出现，随后实际打开通知栏核对。此试验用于隔离接收端限制，不替代念下到日历的字段传递测试，也不将 5 秒轮询结果当作通知延迟指标。原电池设置已恢复，念下没有增加后台权限或电池豁免要求。
- **模拟来电通过**：录音期间注入来电，以 Android 电话状态确认 `RINGING(1) → OFFHOOK(2) → IDLE(0)`，通过系统接听键接通；胶囊停止保存，结束通话后未自动续录。最终取消测试电话并恢复飞行模式。模拟器控制台通话列表曾为空，而 Android 无线日志已收到来电，验收以 Android 实际状态为准；此结果仍不是运营商真机通话验证。
- **测试环境**：Etar 仅安装在专用 AVD 中，不进入念下安装包。使用无同步账号的离线日历和合成内容，联系人访问拒绝；Google 日历在此 AVD 中停用以避免离线首启账号页，非产品要求。Etar 来自其项目链接的 [F-Droid 分发页](https://f-droid.org/packages/ws.xsoh.etar/)，APK SHA-256 `dae01d93c8920aa63845868db2190bcc4aa6ff8410b1289de1ce27b1bb89c599`，安装前通过 APK 签名验证。
- **验证边界**：虚拟 GSM 来电现已通过 Android 状态和保存界面验证，运营商通话留待真机。iOS Simulator 同样需要完整 Xcode；本机 macOS 26.5.1 当前只有 Command Line Tools。App Store 查询到的最新版 Xcode 27.2 最低要求 macOS 26.6，需使用兼容旧版；官方下载需要 Apple 登录，命令行安装要求管理员认证，电脑控制工具另报告 Mac 锁屏。iOS 构建/运行仍未执行，参见 [Apple 模拟器安装说明](https://developer.apple.com/documentation/safari-developer-tools/installing-xcode-and-simulators)。

### Standards

本阶段独立审阅未发现新增的确定性规范缺陷。系统接收器注册/注销、Dart 监听释放成对；不增加权限、生产依赖或内容外发。运行时发现的息屏时序问题已改为系统事件驱动，并补回归。

### Spec

本阶段独立审阅未发现新增的确定性规格偏差。提醒核对、息屏保存、重复入口保护保持既定范围；iOS 和真机延期项不计为已完成。本阶段新增确定性问题：Standards 0，Spec 0。

本阶段运行截图：[提醒计划](docs/screenshots/android-calendar-plan.png)、[接收端字段](docs/screenshots/android-calendar-editor.png)、[通知](docs/screenshots/android-calendar-notification.png)、[取消回执](docs/screenshots/android-calendar-cancel.png)、[强杀恢复](docs/screenshots/android-recovery.png)、[息屏保存](docs/screenshots/android-screen-off-saved.png)、[条件性定时通知](docs/screenshots/android-calendar-scheduled.png)、[来电保存](docs/screenshots/android-call-saved.png)。
