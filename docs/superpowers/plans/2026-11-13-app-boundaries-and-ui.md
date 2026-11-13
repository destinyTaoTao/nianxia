# 应用职责、检索与批准 UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在录音/加密门禁通过后，接入有界检索、任务诊断和已批准的首页、录音、查找浅深主题，完成真实设备闭环。

**Architecture:** 沿用现有 Flutter 页面和 SDK Listenable，以少量页面状态承接异步请求；收口实现细节暴露，保留 Notebook/Storage 的深层行为。原始数据契约保持，新增可重建任务状态与本地诊断分别独立管理。

**Tech Stack:** Flutter3.47.9/Dart3.13.7、SQLite/storage isolate、现有推理运行时、已通过C/B门禁的原生适配器；不新增状态管理/ORM/向量数据库。

**Spec:** [已批准设计与所有视觉稿](../specs/2026-11-13-architecture-and-interaction-design.md)；[总计划](2026-11-13-architecture-ui-rollout.md)、[C1–C5](2026-11-13-background-capture.md)、[B1–B4](2026-11-13-encrypted-backup.md)。

## Global Constraints

继承总计划；Gate-C/Gate-B未通过时不切换正式入口。首页顶部查找、底部单一记一下、顶部写文字；录音可收起而非取消；查询先核对文字。Android API24/iOS17与现有原始schema/备份兼容保持；任何必要原始迁移另行明确，不自动改旧夹具。无commit/push或正式包覆盖。

## Review Focus

1. 同分同日期大结果和长正文，分页不得重复/遗漏，也不能先全量hydrate再切片。
2. 索引/后台任务更新不应把首页已加载窗口和滚动位置清空。
3. 诊断失败、坏任务sidecar或未来版本，不能阻止原文读取/录音保存。
4. 面板收起、查询返回、字体放大/键盘出现，停止与保存状态仍可理解可操作。
5. 开启减少动态/透明度、高对比或旧iOS，操作层应降级，不失去按钮或可读性。

## R1：新增有界摘要检索与代际游标

**Files:** Create `lib/domain/search_page.dart`、`test/search_pagination_test.dart`、`test/search_payload_bounds_test.dart`；Modify `lib/app/record_search.dart`、`lib/app/notebook.dart`、`lib/data/storage.dart`、`lib/data/record_search_store.dart`、`lib/data/search_index.dart`；Test existing `test/search_candidate_batch_test.dart`、`test/indexed_search_test.dart`。

**Interfaces:**
- `SearchQuery({required String text, DateTime? from, DateTime? to})`；`SearchCancellation`有cancel/requested。
- `SearchHitSummary`仅含id、title≤120 Unicode标量、snippet≤150标量、createdAt/timezone/offset、parentId?、hasAudio/durationMs、`MatchKind { keyword, semantic }`；不携带完整body/transcript/organization/vector。
- `SearchPage`含entries、opaque next cursor、reset、semanticApproximate、fallbackReason?、knownTotal?。cursor带版本、查询身份、内容/模型代际、稳定排序位置。
- `Notebook.searchPage(SearchQuery query,{SearchCursor? after, Embedder? embedder, SearchCancellation? cancellation,int limit=40}) -> Future<SearchPage>`；Storage对应异步调用持有归一化查询向量/代际，不重复推理每页。
- 新分页排序score降序、createdAt降序、ID升序；新API明确最后tie-break。保留现有 `Notebook.search` 的签名和完整Record结果兼容，旧排序/分数字节回归不因新API被改写。两者共用匹配规则，不复制另一套分词/向量评分。

- [ ] **Step 1 — RED:** 写 `wideMatchesStayBounded`、`tiePagesNoDuplicates`、`editDeleteModelChangeResetsCursor`、`cancelStopsFurtherPages`。使用真实临时库至少10001条、长正文和同日/同分数据，断言：
  ```dart
  expect(page.entries.length, lessThanOrEqualTo(40));
  expect(allIds.toSet().length, allIds.length);
  expect(nextAfterEdit.reset, isTrue);
  expect(payload.containsKey('body'), isFalse);
  ```
- [ ] **Step 2 — Observe:** `flutter test test/search_pagination_test.dart test/search_payload_bounds_test.dart`，观察缺少分页/摘要导致失败。
- [ ] **Step 3 — Implement:** 在storage worker使用索引访问路径、有限候选/堆和稳定游标；不得用现有全量SearchResults先收齐完整正文再切页。关键词完整命中可遍历、语义候选有界；内容/模型代际变更返回reset，外部写入与坏索引仍走可靠回退。
- [ ] **Step 4 — GREEN:** 重跑R1及existing两组测试；检查真实payload、SQL访问与取消后扫描停止。十万全命中测首屏及全部页分别报告，不能只测选择性查询。保留已有ANN参数/向量精度和最近source批量取数优化。
- [ ] **Step 5 — Checkpoint:** 兼容API和新增摘要API的使用方列清；首页/查找切换到新API在R4。大数据性能测试与重型构建串行运行，记录完整进程RSS而非只看heap。

## R2：有界本地诊断，不影响业务结果

**Files:** Create `lib/domain/diagnostic_event.dart`、`lib/data/diagnostics_store.dart`、`lib/app/diagnostics.dart`、`test/diagnostics_privacy_test.dart`、`test/diagnostics_retention_test.dart`；Modify `lib/app/background_tasks.dart`、`lib/app/notebook_session.dart`、`lib/app/backup.dart`。

**Interfaces:** `DiagnosticEvent`为封闭字段：事件枚举/阶段/随机traceId/结果枚举/错误码/elapsedMs/attempt/sourceRevision?/软件与模型代际，不接收任意Exception、正文Map或文件路径。`LocalDiagnostics.record(DiagnosticEvent event) -> Future<void>`、`previewExport() -> Future<DiagnosticExportPreview>`、`export() -> Future<File>`；preview只含时间范围、包含项和大小。构造器可注入clock和受管目录。

- [ ] **Step 1 — RED:** `contentNeverSerialized`、`ioFailureCannotFailSavedOperation`、`sizeOrAgeEvictsOldest`：原文/查询/Key/密码/路径的哨兵字符串不出现在文件，写入失败不改变已成功保存结果，文件≤5MiB且保留≤7天。
- [ ] **Step 2 — Observe:** `flutter test test/diagnostics_privacy_test.dart test/diagnostics_retention_test.dart`。
- [ ] **Step 3 — Implement:** 独立于源库的有界异步写入和轮转，待写队列上限256条；超载可丢诊断并保留计数，不能阻塞音频或记录提交。启动和未知异常先归类脱敏；无自动上传。
- [ ] **Step 4 — GREEN:** 重跑R2，并在源库打不开、只读/满盘诊断目录、时钟回拨下验证原文和安全错误仍可访问。导出只在用户动作后创建受管副本。
- [ ] **Step 5 — Checkpoint:** 追溯是有限诊断，不引入正文历史/永久审计；大日志/路径/SQL参数泄漏检查通过。

## R3：任务持久状态、运行时生命周期与启动分段

**Files:** Create `lib/domain/local_job.dart`、`lib/data/local_job_store.dart`、`test/local_job_recovery_test.dart`、`test/inference_lifecycle_test.dart`；Modify `lib/data/storage.dart`、`lib/app/background_tasks.dart`、`lib/app/inference_runtime.dart`、`lib/platform/local_models.dart`、`lib/app/notebook.dart`、`lib/app/notebook_session.dart`；Test `test/background_runtime_test.dart`、`test/notebook_session_test.dart`。

**Interfaces:**
- `LocalJob`字段key、`JobKind { transcription, embedding }`、sourceId/revision、modelGeneration、`JobState { pending, running, succeeded, failed, cancelled, stale }`、attempt、nextAttemptAt、leaseToken、errorCode?。不存正文/向量副本，不含付费云整理任务。
- 新 `jobs.sqlite` 是version1可重建任务sidecar，由Storage worker拥有；原始schema2不变。原始转写状态仍以现有records列为准；缓存丢失可从source分批对账，不把任务库当数据源。未知未来sidecar保留并降级，不覆盖。
- Notebook新增 `claimLocalJob() -> Future<LocalJob?>`、`finishLocalJob(LocalJob job,{required JobOutcome outcome}) -> Future<void>`，其中 `JobOutcome { succeeded, failedTransient, failedPermanent, stale, cancelled }`；finish验证lease。source CAS写回仍经已有transcribe/index方法。
- InferenceRuntime新增 `Future<void> close()`、`void setCaptureActive(bool active)`；保留dispose兼容，close等待真正释放worker/session。UI不操作LocalModels.queue。

- [ ] **Step 1 — RED:** `sourceCommittedBeforeJobAckDoesNotRepeatInference`、`newRevisionInvalidatesOldLease`、`futureJobsStoreDoesNotBlockRecords`、`closeWaitsForNativeRelease`、`capturePriorityPausesQueuedWork`；用受控runtime和真实SQLite/sidecar断言不重放已完成本地结果、旧任务不覆盖正文、close后没有活跃worker。
- [ ] **Step 2 — Observe:** `flutter test test/local_job_recovery_test.dart test/inference_lifecycle_test.dart`。
- [ ] **Step 3 — Implement:** 每批最多32个source对账，按来源revision/模型代际去重；本地短暂错误最多3次总尝试，重试延迟1s/5s，永久/空间/认证错误等待人工处理。跨source commit与sidecar ack用幂等对账恢复，不能假装两个SQLite文件共享事务；running重启恢复，本地云调用不进入自动重放队列。
- [ ] **Step 4 — Runtime and startup:** 先查询原生会话及最小兼容/交接恢复，再后台维护完整孤儿/索引扫描；lease保护所有活动文件。测当前每次加载与一个可释放session复用方案；只有真机延迟/内存证据支持才保留复用，不能为降低延迟无界常驻ASR和embedding。
- [ ] **Step 5 — GREEN:** 重跑R3及existing两组测试；source变化/删除、worker退出、模型热换、队列满64、启动遇到坏/未来sidecar、采集中收到维护请求均有回归。内存警告释放闲置模型，迟到结果拒绝和实际资源释放分别断言。
- [ ] **Step 6 — Checkpoint:** 若现有原始契约确实不足，不临时给schema2添加未知表；提出精确独立迁移及回滚影响，再审批该必要变更。当前计划选择sidecar，不预先引入原始迁移。

## R4：按批准稿落地页面与数据管理

**Files:** Modify `lib/ui/{theme,app,common,home,recorder,search,settings,capsule,detail,editor}.dart`、`lib/platform/capture_controller.dart`、`lib/app/notebook.dart`；Create `lib/ui/recovery.dart`、`lib/domain/recovery_entry.dart`、`test/approved_ui_flows_test.dart`、`test/recovery_ui_test.dart`；Test `test/recorder_ui_test.dart`、`test/settings_test.dart`、`test/async_pagination_ui_test.dart`。

**Interfaces:** 页面仅依赖C4 controller、Notebook业务读写、R1摘要分页、B3备份能力、R2诊断preview/export。`Notebook.recoveryPage({String? after,int limit=40}) -> Future<RecoveryPage>`（entries/next），`RecoveryEntry`含受管ID、类别、日期/时长/大小和安全错误原因；新增 `exportRecoveryEntry(String id) -> Future<File>`、`discardRecoveryEntry(String id) -> Future<void>`，只解析受管ID，不接收任意路径。

- [ ] **Step 1 — RED:** `homeUsesTopSearchSingleCaptureAction`、`collapseDoesNotDiscardRecording`、`queryRequiresConfirmationAndStopsWhenHidden`、`restoreNeedsPasswordAndShowsConflictSummary`、`recoveryDiscardNeedsConfirmation`。断言“收起”不会调用cancel，控制条可返回同session；未source commit前无“已保存”；语音查询编辑后仍须点查找。
- [ ] **Step 2 — Observe:** `flutter test test/approved_ui_flows_test.dart test/recovery_ui_test.dart`。
- [ ] **Step 3 — Tokens and flows:** 用frontend-design执行，匹配 `docs/design/ui/2026-11-13/` 四份已批准图。浅/深canvas #FFFFFF/#212121、secondary #F7F7F8/#303030、ink #171717/#F5F5F5、muted #666666/#B4B4B4、line #E5E5E5/#4A4A4A；正文17/辅助14逻辑尺寸起点。首页顶部找一下/语音、底部唯一记一下、顶部写文字；录音收起后底部换控制条，不能再开第二段。
- [ ] **Step 4 — Data management:** 设置中区分默认“密码完整备份”和“导出文本与音频（未加密）”；确认密码、丢失无法找回、旧明文导入、预检冲突/空间/取消边界。待恢复/隔离资料可试听、导出、确认删除；分享返回不宣称外部已保存。诊断导出先预览包含项。所有动作有进行中/成功/失败状态。
- [ ] **Step 5 — GREEN:** 重跑R4及existing三组测试，验证大字体纵向按钮、键盘、Android返回/iOS返回、缺模型/拒权限、空/错误/正在准备、恢复取消及父记录删除；不以pump空闲替代storage异步完成。
- [ ] **Step 6 — Checkpoint:** Gate-C/B均通过后才把native capture与加密完整备份设为默认；旧公开接口/现有测试兼容保留。实际页面不展示isolate、SQL、KDF、队列等实现术语。

## R5：平台材质、动态偏好与运行视觉验证

**Files:** Create `lib/platform/appearance.dart`、`lib/ui/platform_controls.dart`、`test/platform_appearance_test.dart`；Modify `ios/Runner/AppDelegate.swift`、`lib/ui/theme.dart`、`lib/ui/common.dart`；只有原型通过才Create `ios/Runner/Appearance/GlassToolbar.swift`并登记工程引用。

**Interfaces:** `PlatformAppearance`含reduceMotion/reduceTransparency/increaseContrast/glassSupported；adapter发布系统变化。`PlatformControls.operationSurface(Widget child) -> Widget`隐藏原生/实色选择，不改变按钮业务动作或触控语义。

- [ ] **Step 1 — RED:** `reducedTransparencyForcesOpaqueSurface`、`iosReduceMotionIndependentOfDisableAnimations`、`oldIosRetainsActions`、`largeTextKeepsStopReachable`。断言系统偏好变化即时生效，所有fallback仍有可访问名称和相同主动作。
- [ ] **Step 2 — Observe:** `flutter test test/platform_appearance_test.dart`。
- [ ] **Step 3 — Platform prototype:** iOS26+仅底部操作层评估UIKit/SwiftUI原生玻璃，核验platform view叠层/滚动/键盘/触控/动态字体/帧时间。旧系统、减少透明度/高对比或合成性能不合格时实色降级；Android保持中性Material3，不做大面积模糊。直接用实际SDK的reduceMotion与原生偏好，不能只检查disableAnimations。
- [ ] **Step 4 — GREEN and capture:** 两端浅深、字体放大、VoiceOver/TalkBack、减少动态/透明度、高对比和键盘状态实际运行；截图与源图同视口并排检查。验证正文对比≥4.5:1、触控目标iOS44pt/Android48dp，末尾内容不被底部层遮挡。记录素材变化而非静态图声明通过。
- [ ] **Step 5 — Checkpoint:** 原生玻璃失败可以按已批准方案降级；不得用自绘blur宣称原生Liquid Glass已验收。截图只含非敏感夹具，保存 `docs/validation/2026-11-13-architecture-ui/ui/`。

## R6：最终业务、性能、隐私与文档验收

**Files:** Extend `integration_test/app_acceptance_test.dart`（create）、`integration_test/indexed_search_test.dart`、`tool/run_isolated_validation.py`；Modify `README.md`、`docs/mvp-design.md`、`docs/data-storage.md`、`docs/architecture-review.md`，仅将已确认事实/边界同步到 `AGENTS.md`（执行此项前读writing-for-agents，不新增长期偏好）。Create 执行结果 `docs/validation/2026-11-13-architecture-ui/final-report.md`。

**Interfaces:** runner `--target acceptance --case offline-end-to-end`与`--case performance`，只允许测试包及非敏感测试数据；复用现有 `tool/benchmark_search.dart`，新增分页场景参数时保留旧参数行为。

- [ ] **Step 1 — Targeted RED/GREEN:** acceptance断言飞行模式录音→保存→转写→查找→回放/编辑；编辑/删除期间任务不能覆盖/复活；付费整理只用受控transport，不在未授权时发真实请求。失败先补对应回归再修复，不削弱断言。
- [ ] **Step 2 — Host gate:** `bash tool/check.sh`（Python+analyze+Flutter全部）通过；完整gate后不无理由重复。新增/保留native XCTest/JUnit及Android隔离存储/检索集成分别报告。
- [ ] **Step 3 — Device quality/perf:** Magic8/iPhone17各记录OS/模型/构建；一万条已加载模型的文字查找首屏P95≤1s，30秒ASR P95≤15s；十万条冷建/首查/热查/全命中分页、长正文、源+索引+模型空间、完整进程RSS与连续使用发热分别报告。至少50条口述/30条人工标注查询，Top3目标≥90%，无答案/否定/改口另审；调参与验收集分开。
- [ ] **Step 4 — Calendar/privacy:** 两端人工确认系统日历保存/取消/提醒；Android unknown准确展示且不重插。验证模型下载/主动单条云整理外无内容外发、系统备份边界、日志无内容/Key；真实付费云调用仍需独立测试Key/预算授权，不用受控测试宣称已通过真实服务。
- [ ] **Step 5 — Release/data boundary:** 两端release构建、签名状态与包ID核验，安装仅隔离目标；正式数据可核验的散列与基线比较，不能读取时明确局限。检查锁文件/冻结夹具、最终Diff、无密钥/内容/不相关改动；版本未知拒绝与迁移恢复测试保留。
- [ ] **Step 6 — Document and gate:** README保留当前状态入口，历史性能留原报告；AGENTS删除过时“尚无产品代码”并区分自动备份排除、诊断脱敏、用户加密完整备份及明文可读导出。报告已通过/失败/未执行与影响；不能把构建、合成Recall或静态图当真机业务通过。

本阶段结束不包含公开发布、正式签名创建、Git提交/推送或覆盖安装正式应用；这些需要后续明确指令。
