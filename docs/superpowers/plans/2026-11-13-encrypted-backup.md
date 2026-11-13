# 密码加密备份 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 用标准密码容器保护完整备份，证明两端互解、资源有界、认证完整、取消/失败不伤原库，并保留旧包导入及明文可读导出。

**Architecture:** age passphrase 包裹现有 STORE ZIP64 v2；不改原始 schema 和内部恢复契约。先做主机参考互操作，再验证 Android/iOS native 适配器，最后在隔离入口接现有 BackupService。Gate-B通过前不改变正式设置页默认行为。

**Tech Stack:** 现有 Dart isolate/SQLite/ZIP64、标准 age；原型优先评估 Rust age 经最小 C ABI，Go age 作为主机互操作参考；具体版本、许可和生产绑定在门禁中锁定。

**Spec:** [已批准设计](../specs/2026-11-13-architecture-and-interaction-design.md)、[ADR-0003](../../adr/0003-password-encrypted-backups.md)、[总计划 M0](2026-11-13-architecture-ui-rollout.md)。

## Global Constraints

继承总计划全部约束。现有备份v2、v1 reader及冻结夹具保持；不自行设计密码协议，不以ZipCrypto或WinZip AES密码参数代替已批准的方向。密码不托管/不保存/不进日志；认证失败不降级解析明文。只测隔离数据，不覆盖正式包，不自动commit。

## Review Focus

1. 恶意 KDF 头在计算前被拒绝，不吃光内存或无限计算。
2. 最后一块/认证尾被截断时，即使前面已经解出文件也不能进入恢复事务。
3. 中文、emoji、组合字符、首尾空白密码互操作一致，不擅自trim或归一化。
4. 取消期间 native worker 还在写文件，清理必须等其停止，不能先删工作目录。
5. 空间不足、source commit前后中断和旧明文包混入，不能部分合并或把成功误报取消。

## B1：有界容器契约和主机参考互操作

**Files:** Create `lib/domain/backup_operation.dart`、`lib/platform/backup_cipher.dart`、`test/backup_cipher_contract_test.dart`；Create `tool/spikes/backup_crypto/{run.py,reference/go.mod,reference/main.go}`、`tool/spikes/backup_crypto/dependencies.json`。

**Interfaces:**
- `KdfPolicy({int writeLogN = 18, int maxReadLogN = 18, int maxHeaderBytes = 65536})`：原型默认强度和读取上限明确；16/17仅作资源对照，不成为自动降级策略。
- `BackupCancel`：`void cancel()`、`bool get requested`，取消状态跨worker传递；UI可显示“正在取消”，不能把尚在跑的KDF称为已停止。
- `BackupCipher`：`Future<void> encrypt({required String inputPath, required String outputPath, required Uint8List passwordUtf8, required KdfPolicy policy, required BackupCancel cancel, void Function(double)? progress})`；`decrypt`同签名。调用方给受管路径，成功表示完整容器处理结束；输出使用partial，失败不交付半成品。
- `BackupCipherFailure` 类型：authentication/resourceLimit/invalidContainer/cancelled/ioFailure；向上层仅给安全错误码。authentication用户文案为“密码不正确，或备份已损坏”。同一domain文件定义 `BackupPasswordRequired implements Exception`，用于尚未提供密码的加密输入。
- 原生适配器必须把header上限和KDF上限传到标准reader的实际执行前检查，不只在Dart侧写常量。

- [ ] **Step 1 — RED:** 写 `rejectWorkFactorBeforeKdf`、`missingFinalChunkNeverReportsSuccess`、`cipherFailureNeverTriggersPlainZipFallback`，以受控cipher/KDF调用计数断言上限拒绝时KDF计数为0、失败时恢复回调计数为0。运行 `flutter test test/backup_cipher_contract_test.dart`，观察缺失行为失败。
- [ ] **Step 2 — Reference harness:** `run.py --phase host-contract --fixture-bytes 1048576` 只创建标记临时夹具。先从官方源码选定参考版本并把精确版本/commit、源URL、hash、许可写入dependencies.json；禁止`@latest`和无锁依赖。Go参考只运行主机，不把它当iOS可嵌入方案。
- [ ] **Step 3 — Interop tests:** 相同合成载荷的参考工具→候选、候选→参考双向互解，SHA-256相同；密码覆盖中文/emoji/组合字符及前后空格。变更密码、任意密文位、删除/重排块、缺final/尾随垃圾均拒绝；标准测试向量来源与版本入记录。
- [ ] **Step 4 — GREEN:** 重跑Dart契约及host-contract。断言完整消费、终结认证和错误路径，不只检查解出的前几字节。此阶段没有移动端、生产依赖或“已审计”结论。
- [ ] **Step 5 — Checkpoint:** 固定两个适配器（受控/标准候选）跨同一interface验证；记录binding独立维护/许可/审计证据缺口，不能把底层历史审计当作本项目集成审计。

## B2：移动端可嵌入原型与资源门禁

**Files:** Create `tool/spikes/backup_crypto/native/{Cargo.toml,Cargo.lock,src/lib.rs,include/nianxia_age.h}`、`tool/spikes/backup_crypto/lib/age_cipher_spike.dart`、`integration_test/backup_crypto_test.dart`；Modify `tool/run_isolated_validation.py`、测试目标的Android/iOS构建引用。生成库只在受管build目录；此时不把实验绑定加入正式pubspec。

**Interfaces:** 候选C ABI `nx_age_create`创建操作句柄并复制必要参数，`nx_age_run`在worker运行，`nx_age_cancel`请求取消，`nx_age_free`仅在run结束后释放。参数覆盖B1 policy，返回明确错误码；不在主isolate执行KDF或全文件转换。适配器满足B1 `BackupCipher`。

- [ ] **Step 1 — RED:** `integration_test/backup_crypto_test.dart` 写 `kdfLimitReachedBeforeAllocation`、`cancelWaitsForNativeWriter`、`cipherRoundTripUsesBoundedBuffers`。断言超上限头未启动KDF，取消完成后工作文件不再增长，输入/输出hash一致，所有native handle可关闭。用runner的 `--target backup --case cipher-smoke` 观察未接入时失败。
- [ ] **Step 2 — Prototype build:** 先核验并准备Rust/Android NDK/iOS targets，明确缺项；以Rust age和最小FFI作第一候选，Cargo.lock和源码revision固定，实验引用只进测试目标/isolated scheme。若其格式、参数限制或平台嵌入不满足，记录失败并评估另一标准实现，不在应用内拼自研密码协议。
- [ ] **Step 3 — Device matrix:** `python3 tool/run_isolated_validation.py --platform android --device "$TEST_DEVICE" --target backup --mode profile --case cipher-resources`，iOS同命令改platform。记录1/64/512MiB载荷的端到端耗时、总进程RSS、KDF阶段峰值、温度/低内存情况；对比logN16/17/18，写入候选仍以18为基准，失败不暗降。
- [ ] **Step 4 — Cancellation:** 测开始前、KDF中、流式中、final认证前后取消；若标准实现KDF不可抢占，立即返回“正在取消”状态，实际完成后才关闭/清理，记录最坏等待，不承诺即时停止。password byte buffer尽力清零，UI文本及时清除，不宣称GC语言中所有历史副本都被安全擦除。
- [ ] **Step 5 — Core gate:** 两端profile/AOT和release交互冒烟均互解，边界输入不OOM、无主线程长阻塞、无worker关闭竞态。以空闲模型释放后的工作负载测量，另列模型共存压力；不得删除不利结果。若KDF18在目标设备不可接受，返回选型/支持范围评审，不能自动改16。
- [ ] **Step 6 — Production proposal:** 给出具体候选版本/依赖、ABI、许可证、包体增量、总RSS/耗时、取消上界及已知风险。只有该具体生产接入变更获批后再把绑定移出spike；未获批时可继续旧包校验、空间与UI测试，不绕过约定新增生产依赖。

主机C1互解通过不能替代本阶段；目前cargo/rustc/age未在PATH，iOS Xcode/签名未验证，都是前置核验项，不预设已具备。

## B3：接入现有备份编排，保持恢复原子性

**Files:** Modify `lib/app/backup.dart`、`lib/platform/backup_cipher.dart`、`lib/data/backup_codec.dart`、`lib/app/notebook.dart`；Create `lib/data/readable_export.dart`、`test/encrypted_backup_test.dart`、`test/backup_crypto_cancellation_test.dart`、`test/readable_export_test.dart`；Test `test/backup_v2_test.dart`、`test/backup_entry_validation_test.dart`。若生产adapter为FFI，新增 `lib/platform/age_backup_cipher.dart`；具体平台构建文件列入B2接入清单。

**Interfaces:**
- 保留现有 `BackupService.export({progress})` 的旧完整ZIP语义供既有调用兼容，不把它直接改名为可读导出；新增 `Future<File> exportEncrypted({required Uint8List passwordUtf8, void Function(double)? progress})`，成功输出 `.zip.age`。
- 新增 `BackupService.exportReadable({void Function(double)? progress}) -> Future<File>`，在同一一致快照/媒体租约下仅生成可读正文、时间/追加来源说明及引用音频的ZIP，不含恢复manifest、模型、Key、向量或整理缓存。`encodeReadableExport(String snapshot,String home,String work,String output,SendPort progress) -> Future<int>` 在新codec文件中实现，独立入口明确未加密，不宣称它可完整恢复。
- `BackupService.restore(File source,{Uint8List? passwordUtf8, void Function(double)? progress}) -> Future<RestoreReport>`：magic选择age或旧ZIP；encrypted却无密码抛 `BackupPasswordRequired` 供UI进入密码输入态，不按明文继续。现有无密码旧ZIP调用保持兼容。
- `BackupService`构造器可注入B1 `BackupCipher`，沿用现有 `cancelled` 属性并桥接B1取消对象。首次接入仅由隔离入口使用新方法；设置默认切换在R4。
- 加密输出：snapshot→ZIP.partial→age.partial→成功后rename交付。恢复：age完整认证→私有ZIP→现有decode/prepareRestore→mergeRestore；COMMIT后迟到取消不推翻成功。

- [ ] **Step 1 — RED:** 写 `authFailureDoesNotOpenRestoreTransaction`、`cancelBeforeFinalNeverMerges`、`lateCancelAfterCommitReportsSuccess`、`spaceBudgetIncludesBothContainers`、`readableExportContainsOnlyTextAndAudio`；真实临时SQLite/有效WAV、受控cipher记录merge调用计数与原库hash，失败时均不变；可读包无恢复manifest/派生结果，旧export语义保持。执行 `flutter test test/encrypted_backup_test.dart test/backup_crypto_cancellation_test.dart test/readable_export_test.dart`，观察指定行为失败。
- [ ] **Step 2 — Implement:** 接入完整认证后的业务管线，保留media lease、version/reference/path/CRC/hash检查及冲突合并。让 `BackupPasswordRequired` 和安全分类后的 `BackupCipherFailure` 穿过现有 `_exclusive` 的泛化catch，否则UI无法区分需密码/认证/资源限制；测试明确断言此契约。对export计S+Z+C，对restore计源密文副本+解密ZIP+解包媒体+incoming DB+最终媒体复制，含安全余量；无法获空间信息时说明限制，I/O失败仍安全中止。
- [ ] **Step 3 — Cleanup:** 为受管exports/imports目录登记归属与操作状态，启动恢复清理过期partial/明文中间件。只有worker确实停止才能删目录；清理失败保留warning，不把已提交备份/恢复误报为失败。文件保护与系统自动备份排除在两端回读验证。
- [ ] **Step 4 — GREEN:** 重跑B3及 `flutter test test/backup_v2_test.dart test/backup_entry_validation_test.dart`；旧v1/v2读取、重复/冲突、缺音频、cancel、关闭及空间不足原有断言保留。
- [ ] **Step 5 — Checkpoint:** 原始schema不变；文件magic而非扩展名决定格式；密码/路径/原文不进入异常日志；用户错误文案不泄露内部KDF/SQL细节。

## B4：大文件、故障恢复与 Gate-B

**Files:** Extend `integration_test/backup_crypto_test.dart`、`test/encrypted_backup_test.dart`、`tool/spikes/backup_crypto/run.py`；Create `docs/validation/2026-11-13-architecture-ui/backup/results.json`、`report.md`（执行后）。

**Interfaces:** runner `backup-matrix` 验证真实备份链；主机 `run.py --phase large-container --minimum-bytes 4294967297` 创建实际有效STORE ZIP64载荷。运行前按B3并存预算检查临时空间，不用sparse头部假装完整写读通过。

- [ ] **Step 1 — Fault tests:** 覆盖KDF头过大、无效magic、wrong-password、块/末块破坏、非法尾随、read-only/磁盘满、worker异常退出、解密后进程终止、COMMIT前后取消。断言原库/既有音频指纹、冲突副本和恢复清理状态正确。
- [ ] **Step 2 — Large round trip:** 两端真实文件到文件处理>4GiB、标准参考工具互解；内部完整备份恢复至少一次真实ZIP64大包。若空间/设备不足，记录该项未执行，不能宣称完整大包支持已验收。
- [ ] **Step 3 — Device evidence:** `python3 tool/run_isolated_validation.py --platform android --device "$TEST_DEVICE" --target backup --mode release --case backup-matrix`，iOS同样；release无VM service时用测试面板及脱敏结果文件，不借debug结果冒充release。导入后文字、原始转写、音频、时间和追加关系可核对。
- [ ] **Step 4 — GREEN gate:** 格式互解、KDF硬限、取消后资源释放、认证先于合并、旧包兼容、空间/大文件均有明确结果；两端核心路径通过。重启没有不受管明文暂存，不能删除外部原备份或用户其他文件。
- [ ] **Step 5 — Checkpoint:** 保留失败与成功统计、固定依赖与测试指纹。Gate-B通过后R4将默认完整备份切到加密，并继续独立提供明确标识的明文可读导出。

参考：[age规范](https://c2sp.org/age@v1.1.0)、[Go参考实现](https://github.com/FiloSottile/age)、[Rust候选及其状态](https://docs.rs/age/latest/age/)、[scrypt RFC7914](https://www.rfc-editor.org/rfc/rfc7914)。参考实现及移动绑定的成熟度分别核验，不以“使用标准”替代集成验证。
