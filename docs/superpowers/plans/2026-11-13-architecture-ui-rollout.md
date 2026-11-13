# 架构与 UI 重构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按已批准设计交付可靠的双平台本地语音本；先证明锁屏录音和加密备份可行，再实施应用与 UI 重构。

**Architecture:** 保留 Flutter 模块化单体、单一 Storage isolate 和原始数据契约。录音由原生会话持有，备份保留 ZIP64 业务载荷并评估标准 age 密码容器。两个风险阶段均有独立退出条件，未通过时不将试验实现接入正式入口。

**Tech Stack:** Flutter 3.47.9 / Dart 3.13.7、SQLite、Kotlin/JVM17、Swift/XCTest；age 实现及 native 绑定待隔离原型验证。

**Spec:** [已批准设计](../specs/2026-11-13-architecture-and-interaction-design.md)、ADR-0001/0002/0003；执行者必须同时阅读设计和对应专项计划。

## Global Constraints

- Android 最低 API24、iOS17；先不升级 Flutter、Gradle、AGP、Kotlin、模型或 ANN 参数。
- 一万条为日常容量验收，十万条为规模压力测试；音频另按总时长与磁盘占用设预算。
- 记录录音 16kHz/mono/PCM16，最长 120000ms，PCM 数据最多 3840000 bytes；WAV 由现有校验器验证。
- 记录录音支持已开始后的锁屏/后台；临时查询隐藏/锁屏结束采集，不自动成为记录。
- SQLite 提交才可提示“已保存”；未知云端/日历结果不自动重放。旧任务不能覆盖新正文或复活删除记录。
- 原始 schema2、备份v2及冻结v1夹具保持；必要的新 schema 必须独立迁移，不能修改旧夹具来迎合实现。
- 密码完整备份与明文可读导出分开；无密码托管；正文/音频/Key/密码不进入诊断。
- 所有试验仅用标记临时目录和独立测试包。不得卸载、清理、覆盖安装正式 `app.nianxia.nianxia`，不得读取真实内容作夹具。
- 不提交、不推送、不部署、不创建正式签名；每个任务以 Diff 和证据检查点代替技能模板中的自动 commit。
- 保护当前全部 WIP。执行前重新检查并发改动；若创建 worktree，必须保留完整当前 WIP，不能把纯 HEAD 当作当前基线。不能安全复制时保持源工作区并隔离测试数据。
- 下文的新增文件、类型和命令均为实施目标，并非声称当前已存在。环境缺项应报告，不能把未执行记作通过。

## Review Focus

1. 原生会话仍打开音频时，启动恢复/导出/删除不能改写或清理该文件：C4 的活动会话与媒体租约测试。
2. 文件已移动/数据库已提交但 native ack 丢失，重启不能重复导入或删除已保存音频：C4 的交接强杀点测试。
3. 设备锁定、Flutter 无回调或系统直接终止，录音仍须有明确收尾/恢复状态：C2/C3/C5 真机矩阵。
4. 恶意 KDF 头、末块丢失、取消恰逢认证/提交完成，原库不能部分改变或误报回滚：B1/B3/B4 测试。
5. 查询翻页期间编辑/删除/换模型，结果不能混合代际；搜索全命中不能先传整库正文：R1 的分页与有界载荷测试。

## 路线与交付物

| 顺序 | 专项 | 独立交付 | 下一阶段条件 |
| --- | --- | --- | --- |
| 0 | M0：环境和隔离 | 两端可核验的测试包、受保护 runner、基线清单 | 测试包身份可证明，无法核验时禁止安装 |
| 1 | [录音 C1–C5](2026-11-13-background-capture.md) | 原生会话原型、交接协议、两端锁屏/中断证据 | Gate-C 通过后才能替换正式录音入口 |
| 2 | [备份 B1–B4](2026-11-13-encrypted-backup.md) | age 互解与资源原型、加密恢复保护 | Gate-B 通过后才能默认输出加密完整备份 |
| 3 | [应用/UI R1–R6](2026-11-13-app-boundaries-and-ui.md) | 分页、诊断、任务与批准 UI、完整验收 | 前两项均通过；UI 材质失败可降级，不取消录音/数据门禁 |

C 与 B 可使用同一隔离基础，但先执行 C 的最短真机闭环，再执行 B。硬件/签名阻塞时可继续另一项独立工作；相应平台仍标未验证，不跳过门禁进入正式替换。

## M0：建立可证明的验证边界

**Files:**
- Create: `tool/validation_preflight.py`、`tool/run_isolated_validation.py`、`tool/tests/test_validation_preflight.py`、`tool/tests/test_isolated_validation_runner.py`。
- Create: `integration_test/support/isolated_validation.dart`、`ios/Runner.xcodeproj/xcshareddata/xcschemes/isolated.xcscheme`。
- Modify: `ios/Runner.xcodeproj/project.pbxproj`、`ios/Runner/Info.plist`、`ios/Runner/AppDelegate.swift`、`android/app/src/main/kotlin/app/nianxia/nianxia/MainActivity.kt`。
- Preserve: 现有 `tool/run_android_model_tests.py` 仅允许模拟器的限制；不为真机新需求削弱其既有检查。

**Interfaces:**
- `python3 tool/validation_preflight.py --json`：只读返回工具路径/版本、实际 Xcode SDK、可用构建条件及失败项；不安装/切换 Xcode、不改权限/签名、不打印凭证。
- `python3 tool/run_isolated_validation.py --platform android|ios --device ID --target capture|backup|acceptance --mode debug|profile|release --case CASE`：目标和 case 白名单，显式设备，无默认设备。自动化 case 使用 integration driver；release 交互 case 采用安装后测试面板与结果文件，不假设 release 有 VM service。
- Dart `Future<void> requireIsolatedValidation()`：原生实际包 ID/Bundle ID 必须为 `app.nianxia.nianxia.test`，且根目录位于该测试沙箱；不能只信 `--dart-define`。

- [ ] **Step 1 — RED:** Python tests 用受控 subprocess 断言正式包 ID、设备不匹配、签名错误、非白名单 case 均在 install 前失败；无 uninstall/clear/retry-by-removal。执行 `python3 -m unittest tool.tests.test_validation_preflight tool.tests.test_isolated_validation_runner -v`，观察指定断言失败。
- [ ] **Step 2 — Implement:** 创建只读 preflight 与受保护 runner。Android 复用现有目标自动 `.test` 规则并从 APK 实际 badging 核对；iOS 增加共享 `isolated` scheme 和 `Debug-isolated/Profile-isolated/Release-isolated`，仅这些配置设置 Bundle ID `.test`、显示名“念下·测试”，保留原 Runner 配置。按现有 SPM 工程接入，不凭空添加 Podfile。
- [ ] **Step 3 — GREEN:** 重跑上述 Python 命令并检查 `xcodebuild -showBuildSettings -workspace ios/Runner.xcworkspace -scheme isolated -configuration Debug-isolated` 的真实 Bundle ID；Xcode 缺失时只能完成前一部分，iOS 保持未执行。
- [ ] **Step 4 — Baseline:** 从当前 WIP 生成仅源码/锁文件/夹具/应用包身份的本地指纹，记录工具与 OS。若能安全读取正式沙箱则另存本地文件散列，不导出内容；读不到须注明，不能以包路径未变代替数据未变。
- [ ] **Step 5 — Boundary smoke:** runner 在一次性测试沙箱中建一条非敏感文字，重开仍存在；核验正式应用没有被替换。记录结果到 `docs/validation/2026-11-13-architecture-ui/environment.json`，没有原文、Key、设备序列号或 VM-service token。
- [ ] **Step 6 — Checkpoint:** 检查新增配置及最终 Diff；阶段只改测试基础，不改变正式录音/备份入口。

### 已核实环境与执行变量

本次规划只读检查：Flutter3.47.9/Dart3.13.7；`xcode-select -p` 为 `/Library/Developer/CommandLineTools`；Go 在 PATH，cargo/rustc/age 未在 PATH；当前没有 iOS Podfile，已有 Flutter SPM 工程引用。完整 Xcode、真实设备连接和签名尚未验证；不自动安装工具或注册 Apple 凭证。

执行前把下列变量设为核验后的实际值；`TEST_DEVICE`及`IOS_SIMULATOR_UDID`必须明确填写实际目标，不使用占位符或自动选择设备。真实手机可以承载独立测试包，正式应用始终不可作为安装/清理目标：

```sh
export PATH="/Users/xiaodeng/.local/share/nianxia-toolchain/flutter/bin:$PATH"
export FLUTTER_BIN="/Users/xiaodeng/.local/share/nianxia-toolchain/flutter/bin/flutter"
export ANDROID_SDK_ROOT="/Users/xiaodeng/.local/share/nianxia-toolchain/android"
```

真机签名/信任、解锁与通话场景需要用户在设备上配合；这不阻塞可独立执行的主机和 Android 测试。Xcode 未就绪时不得标记 iPhone Gate-C/Gate-B 通过。

## 阶段证据与回退

- 每项结果记录源码指纹、设备/OS/构建模式、测试名、样本数、成功/失败/未执行及局限，放入同一 `docs/validation/2026-11-13-architecture-ui/` 的对应阶段子目录；只保存脱敏统计与合成夹具指纹。
- 音频与密码试验夹具只留在受管测试目录，不纳入仓库、诊断或云上传；阶段结束前清理经过明确归属标记的测试产物。
- Gate-C 失败：保留现有正式前台录音入口，原型只在测试入口；报告具体平台与失败模式，不静默删掉已确认的后台需求。
- Gate-B 失败：不把明文 ZIP 伪装成加密备份；保留已存在的明文导入与明确标识的可读导出，重新评估标准实现/绑定，不自创协议或静默降低 KDF。
- 新 schema 若必要，开放新版写入前准备迁移快照及兼容拒绝；开放写入后不能仅换旧 APK 回滚。sidecar 只可重建已知缓存版本。
- 没有新增生产依赖或原始迁移的自动授权步骤；专项 gate 给出具体版本、许可、资源和风险后，列明拟接入变更供审阅。

## 整体出口

- [ ] Gate-C 与 Gate-B 分平台有证据，不能用主机/模拟器代替真机。
- [ ] R1–R6 完成，受影响回归与 `bash tool/check.sh` 通过；两端 release 构建、隔离包身份和批准 UI 的运行截图可核对。
- [ ] 原始内容、音频与关系保留；未知库拒绝重置；备份 v1/v2 冻结输入兼容；离线记查、手动日历真实保存/提醒及可恢复失败验收。
- [ ] 密钥/正文不在诊断；正式数据边界核验；检查最终 Diff，明确未执行项。无 Git 提交/推送或正式包覆盖安装。

## 计划自审

覆盖映射：录音/交接→C1–C5；加密/旧包/可读导出→B1–B4/R4；分页→R1；诊断/恢复入口→R2/R4；任务/运行时→R3；浅深/玻璃/无障碍→R4/R5；离线/质量/日历/设备→R6。五项 Review Focus 均有指定失败用例。后续专项引用同一 capture 与 crypto interface；数值未知项由有退出条件的原型测量解决，不交给用户猜算法。

方案和计划本身不代表上述测试已执行。本轮只创建计划并更新设计批准状态。

参考：[Flutter iOS schemes/flavors](https://docs.flutter.dev/deployment/flavors-ios)、[Flutter SPM](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers)。
