# 原生会话与锁屏录音 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 证明两端已开始的两分钟记录录音能跨锁屏/后台可靠收尾，并能在进程终止后幂等恢复有效片段。

**Architecture:** 原生拥有采集、WAV、期限、中断与会话凭据；Flutter 观察和控制，Storage 仍是唯一原始数据库写入者。先从隔离测试入口调用，Gate-C 通过前保留正式入口的当前行为。

**Tech Stack:** Kotlin/AudioRecord/microphone FGS、Swift/AVAudioEngine/AVAudioSession、Flutter MethodChannel/EventChannel；JUnit4/XCTest、现有真实 SQLite/WAV 测试。

**Spec:** [已批准设计](../specs/2026-11-13-architecture-and-interaction-design.md)；必须先完成[总计划 M0](2026-11-13-architecture-ui-rollout.md)。

## Global Constraints

继承总计划全部约束：Android API24/iOS17，16kHz/mono/PCM16，120000ms/3840000 PCM bytes，单会话，SQLite commit 才算保存；记录可后台，查询只前台。无自动恢复采集、无正式包安装、无自动 commit。平台 API 按实际 SDK availability 分支。

## Review Focus

1. 连续快捷动作、stop/cancel 交错和旧事件迟到：只能有一个会话与一个文件所有者。
2. Flutter engine 断开、Activity/面板销毁：记录会话继续，停止期限仍在原生生效。
3. 锁屏文件不可重开：允许延迟入库，不假报已保存或降低全库文件保护。
4. source commit 前后各阶段强杀：不能重复导入、丢弃已保存音频或依赖 finally。
5. 麦克风被策略静音、路由变更或权限撤回：结束并保留有效片段，不把低振幅直接判为来电。

## C1：固定会话协议与受控适配器

**Files:** Create `lib/domain/capture_session.dart`、`lib/platform/native_capture.dart`、`test/native_capture_protocol_test.dart`、`test/support/native_capture_fake.dart`。

**Interfaces:** 新建 `CaptureMode { record, query }`、`NativeCapturePhase { starting, recording, finalizing, finalized, failed, cancelled }`、`CaptureDisposition { importedRecord, queryCompleted }`。
- `CaptureRequest`：sessionId(UUID)、mode、parentId?、createdAtUtc、timezone、offsetMinutes；不接收外部文件路径。
- `CaptureSnapshot`：上述元数据、phase、sequence、elapsedMs、pcmBytes、relativeAudioName?、errorCode?；sequence 在同一会话内单调增长。
- `FinalizedCapture`：经核验的 finalized/handoff 元数据及 PCM 字节数，供 C4 接收。
- `NativeCapturePort`：`Future<CaptureSnapshot> start(CaptureRequest request)`、`Future<CaptureSnapshot?> current()`、`Future<List<CaptureSnapshot>> pending({String? after, int limit = 32})`、`Future<CaptureSnapshot> stop(String id)`、`Future<void> cancel(String id)`、`Future<FinalizedCapture> claim(String id)`、`Future<void> acknowledge(String id,{required CaptureDisposition disposition})`、`Stream<CaptureSnapshot> get events`。
- wire version=1；channel `app.nianxia/capture` / `app.nianxia/capture_events`。record 文件位于原生固定推导的应用私有 `nianxia/native-captures/`，query 位于独立临时子目录；pending按sessionId升序、after排他。`claim` 持久标记 handoff，之后 native cancel 不可直接删文件；importedRecord ack只清会话凭据、不删已转移的正式音频，queryCompleted ack清查询临时音频与凭据；mode/disposition不匹配必须拒绝。

- [ ] **Step 1 — RED:** 写 `duplicateStartReturnsCurrent`、`staleEventCannotReplaceCurrent`、`claimedClipRejectsNativeDiscard`，通过受控端口计数断言：
  ```dart
  expect(fake.startedSessionCount, 1);
  expect(observed.sequence, greaterThan(previous.sequence));
  await expectLater(fake.cancel(claimedId), throwsA(isA<NotebookException>()));
  ```
- [ ] **Step 2 — Observe:** `flutter test test/native_capture_protocol_test.dart`；必须因协议/适配器尚缺而失败，不接受静默 skip。
- [ ] **Step 3 — Implement:** 实现不可变 DTO、序列校验和 bridge；`test/support/native_capture_fake.dart` 提供 startedSessionCount、注入旧事件/延迟 stop/claim 的受控行为。方法不泄露 SQLite handle 或任意目录操作。
- [ ] **Step 4 — GREEN:** 重跑 C1 测试，追加路径穿越 sessionId、未知 wire version、非有限音量/无序事件拒绝用例；真实麦克风不在主机单测中打开。
- [ ] **Step 5 — Checkpoint:** 核对协议文档与代码一致，channel 尚未接入正式构造器；Diff 无生产依赖变更。

## C2：Android 原生采集与 microphone FGS 原型

**Files:** Create `android/app/src/main/kotlin/app/nianxia/nianxia/capture/{NativeCaptureSession,CaptureService,CaptureJournal,PcmWaveSink,CaptureChannel}.kt`；Create `android/app/src/test/kotlin/app/nianxia/nianxia/capture/NativeCaptureSessionTest.kt`；Modify `MainActivity.kt`、`android/app/src/main/AndroidManifest.xml`、`android/app/build.gradle`；Create `integration_test/background_capture_test.dart`。

**Interfaces:** Kotlin 的同名 DTO/协议对应 C1。`NativeCaptureSession` 以单串行执行器持有 AudioRecord、单调时钟和 sink；`CaptureService` 承接系统生命周期；`CaptureJournal` 的 version1 状态为 active/finalized/handoff/discarded。AudioRecord 原始样本不经过 EventChannel，事件只传状态和节流音量。

- [ ] **Step 1 — RED:** `NativeCaptureSessionTest` 用注入音频源/时钟测试 `deadlineStopsWithoutFlutter`、`pcmLimitClipsAtWholeFrames`、`stopCancelOnlyOneFinalization`。断言最多3840000 PCM bytes、偶数字节、终态只一次、超过120000ms不继续采集。测试 source 仅在 test 源集，不为正式包暴露音频注入入口。
- [ ] **Step 2 — Observe:** 增加仅测试用 JUnit4 `4.13.2` 后运行 `./android/gradlew -p android :app:testDebugUnitTest`，观察上述行为失败；无 AudioRecord 的 JVM 环境用受控源，不把它当系统验收。
- [ ] **Step 3 — Implement:** 用 AudioRecord 采集16k PCM；sink 流式写 WAV、完整帧上限、收尾回写长度并 flush。FGS 在可见且已授权时启动；声明 FOREGROUND_SERVICE / FOREGROUND_SERVICE_MICROPHONE 及 service type，service exported=false，通知控制使用不可变 PendingIntent 与当前会话校验。拒绝通知权限仍能回应用停止。
- [ ] **Step 4 — Interruptions:** 处理通话/采集策略静音及路由/权限变化的可用系统信号；正常静音不是错误。中断按现有片段 finalize，不自动再启动；Task Manager Stop 无回调时以已写凭据恢复。
- [ ] **Step 5 — GREEN:** JVM 测试通过后执行 `python3 tool/run_isolated_validation.py --platform android --device "$TEST_DEVICE" --target capture --mode debug --case background-smoke`。case 在前台开始、后台保留、再前台停止并用 `validateWave` 验证；会话可跨 engine detach。只使用 `.test`。
- [ ] **Step 6 — Checkpoint:** 记录 API/OS、权限与通知状态、实际样本长度和中断行为；不因模拟器通过标记荣耀真机通过。

## C3：iOS 原生采集、文件保护与锁屏原型

**Files:** Create `ios/Runner/Capture/{NativeCaptureSession,CaptureJournal,PcmWaveSink,CaptureChannel}.swift`、`ios/RunnerTests/NativeCaptureSessionTests.swift`；Modify `ios/Runner/AppDelegate.swift`、`ios/Runner/Info.plist`、`ios/Runner.xcodeproj/project.pbxproj`；复用 `integration_test/background_capture_test.dart`。

**Interfaces:** Swift 镜像 C1 wire DTO；AVAudioEngine tap 原生转换至16k/mono/PCM16并送 sink。`CaptureJournal` 沿用相同语义，不共享原生实现代码；WAV 编码字节与 Dart 校验器兼容。

- [ ] **Step 1 — RED:** XCTest 写 `testLockCannotReopenCompletedClip`、`testConverterUsesWholePcmFrames`、`testInterruptionFinalizesWithoutAutoResume`、`testMonotonicDeadlineSurvivesObserverDisconnect`；受控信号分别覆盖44.1/48k输入、短/奇数字节、相同stop重放。
- [ ] **Step 2 — Observe:** Xcode与模拟器前置通过后运行 `xcodebuild -workspace ios/Runner.xcworkspace -scheme isolated -configuration Debug-isolated -destination "platform=iOS Simulator,id=$IOS_SIMULATOR_UDID" test`。只有 CLT 时记录无法执行，不用 Dart mock 替代。
- [ ] **Step 3 — Implement:** 配置合适 AVAudioSession、audio background mode和中断通知，iOS17可用路径优先。session由AppDelegate生命周期的强引用持有，不以Flutter channel订阅为唯一owner。对打开音频评估 completeUnlessOpen；仅必要会话凭据评估 completeUntilFirstUserAuthentication。读取实际保护属性并测锁屏访问；不统一降低 SQLite/WAL/全部音频保护。
- [ ] **Step 4 — GREEN:** XCTest通过后执行 `python3 tool/run_isolated_validation.py --platform ios --device "$TEST_DEVICE" --target capture --mode debug --case background-smoke`；native finalized 不代表入库成功，无法锁屏重开时保留待解锁状态。
- [ ] **Step 5 — Checkpoint:** 验证 route 改变时转换/采样计数一致，真实 iPhone 锁屏、音频文件和 journal 属性单独留证；不得用模拟器或 AVAudioRecorder 文档冒充当前 AVAudioEngine 路径验证。

## C4：原生片段与源库幂等交接

**Files:** Create `lib/app/capture_session_controller.dart`、`test/native_capture_handoff_test.dart`；Modify `lib/app/notebook.dart`、`lib/app/notebook_session.dart`、`lib/data/capture_store.dart`；Test `test/architecture_contract_test.dart`、`test/storage_lifecycle_race_test.dart`。

**Interfaces:**
- `CaptureSessionController(NativeCapturePort port, Notebook book, InferenceRuntime runtime)`：`Future<CaptureSnapshot> start({required CaptureMode mode, String? parentId})`、`Future<void> stop()`、`Future<String> finishQuery()`、`Future<void> discard()`、`Future<void> reconnect()`、`CaptureSnapshot? get snapshot`；页面释放订阅不取消记录会话。仅query启动检查speech就绪，record不等待模型。
- `Notebook.acceptNativeCapture(FinalizedCapture clip, {bool standalone = false}) -> Future<Record>`：只接受受管根内、版本/格式已验证的 native 片段；按 sessionId 使用现有 `_withCapture` 与 `finishCapture` 规则。保留现有 `finishCapture`/旧草稿 reader，不能破坏冻结输入。
- record采用 `claim → 校验/转移与 source insert → acknowledge(importedRecord)`。claim期间禁止native直接丢弃；source已存在先核对来源再ack。`reconnect` 开库恢复前先查询原生活动会话，避免 `_recover` 改正在写的文件。
- query的stop只结束采集；`finishQuery()`在前台claim并复用已有 `Notebook.transcribeQuery` 的校验/识别规则，成功或失败都清理查询临时文件并ack(queryCompleted)，不调用acceptNativeCapture。隐藏/锁屏时先stop，恢复前台才识别；进程重启清理旧query而不导入。

- [ ] **Step 1 — RED:** 用真实临时 SQLite/WAV 与受控 native 端点，写 `restartAfterMoveBeforeCommit`、`restartAfterCommitBeforeAck`、`activeClipExcludedFromRecovery`、`deletedParentOffersStandalone`。核心断言：
  ```dart
  expect((await book.records).where((r) => r.id == sessionId).length, 1);
  expect(await File(book.audioPath(saved)).exists(), isTrue);
  expect(fake.ackBeforeCommit, isFalse);
  ```
- [ ] **Step 2 — Observe:** `flutter test test/native_capture_handoff_test.dart`，应在缺少交接/故障处理时失败。
- [ ] **Step 3 — Implement:** 将交接收口到 controller/Notebook。媒体租约覆盖native活动文件与handoff；移动后尚未commit的文件和凭据可恢复。ack仅清native凭据；source commit后即使ack失败也不得把成功改成“录音未保存”。来源字段不一致的同ID碰撞拒绝静默去重。
- [ ] **Step 4 — GREEN:** 重跑 C4 及 `flutter test test/architecture_contract_test.dart test/storage_lifecycle_race_test.dart test/capture_controller_test.dart`。增加discard与import竞争、父记录删除、未来凭据版本、奇数尾帧和已有正式音频的失败恢复。
- [ ] **Step 5 — Checkpoint:** 无新的原始 schema；回到旧正式入口时数据仍可读。原生协议、源库接收与清理意图的故障点有可重复夹具，C5再做真实强杀。

## C5：真机矩阵与 Gate-C

**Files:** Extend `integration_test/background_capture_test.dart`、`tool/run_isolated_validation.py`；Create `docs/validation/2026-11-13-architecture-ui/capture/results.json`、`report.md`（执行后才写结果）。

**Interfaces:** runner case `capture-matrix` 提供前台开始/停止、锁屏/后台提示、重连和本地结果读取；人工设备动作由用户在场执行，不自动拨号或发消息。测试录音仅来自明确同意的非敏感语音/声源。

- [ ] **Step 1 — Fault cases:** 为 `process-kill-active`、`kill-after-finalize`、`kill-after-source-commit` 写测试断言；强杀只针对测试包。重启不自动打开麦克风，query临时音频清理，record只修复真实完整帧。
- [ ] **Step 2 — Device matrix:** 荣耀Magic8与标准iPhone17分别验证锁屏、后台、120秒自动收尾、系统停止、来电、蓝牙/有线路由、权限撤回、无通知授权、重复快捷动作。每个主路径至少3次，开始与保存时延分别至少20样本；记录未执行项。
- [ ] **Step 3 — Performance:** profile/AOT和可交互release分别注明；已授权前台采集P95≤500ms，解锁停止到source提交反馈P95≤1s。锁屏finalize和解锁导入分别报告，不把等待解锁时间排除后冒充整体已保存。
- [ ] **Step 4 — GREEN gate:** 所有核心路径无重复导入、误删、虚假保存、自动重启采集；有效片段可回放/验证，测试包隔离成立。完整Xcode/签名/硬件缺失则该平台 Gate-C 为未通过验收，保留可独立完成部分。
- [ ] **Step 5 — Checkpoint:** 脱敏统计与源码/夹具指纹、失败日志及待办入库；确认现有正式录音入口未被提前替换。Gate-C通过后由R4接入批准UI。

原生职责若须扩展/修补现有插件，先核对当前许可与源码，保持范围最小；不把修改全局 pub cache 作为可交付实现。
