# 本轮实施裁决记录

按作出顺序保留各计划的 `Ruling:`；早期无提交授权的限制已被用户后续明确授权提交/推送/合入主分支取代。R1–R6范围限制也已由后续自主实施授权扩展。真机/iOS门禁继续有效。正文中的成本和限制不等于已通过承诺。

## 2026-11-13-architecture-ui-rollout

- Ruling: Work in the existing codex/notecard-ui feature checkout under the approved plan fallback; do not create a HEAD-only worktree that omits WIP — cost if wrong: isolation is provided by snapshots and test data, not a separate source checkout.
- Ruling: M0/C/B headings are not Task N parser headings; retain approved numbering, extract task briefs directly and record file hashes rather than commit ranges — no staging/commits are authorized.
- Ruling: Scope now is M0, C1–C5 and B1–B4 until evidence/real environment gates; R1–R6 remain gated. Device/Xcode absence must not be reported as passed; proceed on independent work.
- Ruling: iOS M0 runtime/build validation blocked by missing full Xcode/device; parsed configurations and source guard verified, Android path ready. Continue C1/C2 independent work, never mark iOS gate passed.

## 2026-11-13-background-capture

- Ruling: C1 tests exercise real bridge/wire validation; native duplicate-creation and claimed-discard invariants are proved against native owner in C2, not by asserting a fake implements itself. Cost if wrong: C2 must retain those integration assertions.
- Ruling: Add client close() to NativeCapturePort to detach streams without cancelling native recording; necessary resource contract absent from plan, no capture lifecycle change.
- Ruling: Flutter integration_test requests androidx.test:runner:1.2+; TLS metadata lookup failed and offline cache had the fitting 1.2.0 artifact but no dynamic version listing. Pin only that existing test-runner request to 1.2.0 in project Gradle, not SDK/cache edits — cost if wrong: native test harness compatibility, checked by unit/integration builds.
- Ruling: Legacy recovery only reads drafts/audio; active native files live in disjoint native-captures root, so no speculative native RPC during every old Notebook.open. Native handoff markers are created only after claim/finalize — preserves old entry without touching active clips — cost: native controller must reconnect before formal switch.

## 2026-11-13-encrypted-backup

- Ruling: Run KDF-before-allocation assertions against real native policy, not a fake cipher claiming its own invariant — native counters and real parser exercised — costs native build prerequisite in explicit spike tests.
- Ruling: [已取代：最终独立Release为非debug，改用nonce数值provider；普通Release不含provider。] Isolated release builds are debuggable solely to read nonce-scoped numeric results with run-as; normal release retains default debuggability and no crypto library — cost: label performance results as isolated AOT, not store-release performance.
- Ruling: Native spike tests moved under tool/spikes/backup_crypto/test so normal host suite has no implicit Rust/dylib prerequisite; core policy tests remain under test/. Explicit spike gate still required — cost: CI must invoke that additional gate.
- Ruling: Android SELinux rejects app-data hard links (native failure at publish stage after fsync); use kernel renameat2(RENAME_NOREPLACE) on Android, keep host hard-link publication — required atomic no-overwrite; cost: unsupported kernels fail closed, API24 oldest device unverified.

## 2026-11-13-app-boundaries-and-ui

- Ruling: New paging may retain only IDs/scores/times in a bounded-query SQLite TEMP ranking table, never an all-results full Record list. Reuse existing indexed/scan matching visitor and keep legacy default path identical; per-query vector computed once, stable score/date/ID keyset pages, invalidate raw/model generations. This avoids rescanning N full matches for every page — cost: temporary disk budget and lifecycle/cancellation must be explicit and tested.
- Ruling: Use an explicitly private, identified, disposable scratch SQLite instead of platform-dependent SQLite TEMP file location. One store cache≤256MiB disk/2MiB SQLite page cache, two query contexts/builders, five-minute retention, query key/score/time/ID only. No original schema changes or plaintext query persisted; cleanup only known owner/version and unlocked foreign-PID directories, unknown versions retained. Cost: additional bounded private scratch IO, platform file-lock behavior needs Android/AOT validation.
- Ruling: Source count can exceed scratch budget; current bounded scratch fails explicitly on resource/IO exhaustion, leaves originals unchanged, no silent result truncation or unbounded in-memory fallback — cost: users must free space/narrow a query in that condition; UI must convey recoverable failure.
- Ruling: Bounded diagnostics use independent versioned SQLite row retention/auto-vacuum and hard page limit rather than text-segment rotation. Native IO runs in one serialized dedicated worker per operation; only closed metadata encoded, no source-store handle. Max5MiB active store /7days /queue256, overload count included in preview/export; optional diagnostics never gate source success — cost: corrupt diagnostics may be unavailable, source remains separate.
- Ruling: Extend claim with capability filter and speechModelVersion, plus optional next retry time at the Storage seam. Readiness must not let an unavailable speech model block embedding, and an empty queue must not poll the whole library. Existing synchronous source commits remain authoritative across sidecar acknowledgement — cost: two independent SQLite commits require reconciliation, never cross-file atomicity.
- Ruling: A failed model manifest now yields an unavailable empty model adapter and a user-visible notice while records/keyword paths remain usable. Replaces the old fail-startup test because optional model configuration cannot gate capture/text data — cost: model features need a later successful reopen; original source failures still fail safely and produce bounded diagnostics.
- Ruling: Full orphan maintenance runs after NotebookSession startup; minimal draft recovery remains before return. Each orphan move takes the capture lock, a media barrier and fresh bounded source-reference check, preventing snapshot races with recording/import/backup. Legacy Notebook.open keeps eager maintenance by default for API/test compatibility — cost: a capture or archive active during a pass defers unvisited maintenance until a later pass/startup.
- Ruling: Do not adopt resident model sessions without the required physical-phone latency/RSS evidence; current per-call native handles release in finally, and close now joins actual in-flight work even when its caller has already been rejected. Native capture startup ownership query remains in C4 controller when that gated adapter is composed; native-captures and legacy queries/drafts stay disjoint. Cost: model load latency remains; no claim of phone memory-pressure/session-reuse acceptance.
- Ruling: Recovery of a claimed native clip needs an explicit discardedRecord acknowledgement, separate from importedRecord/queryCompleted. A durable Dart discard flag precedes byte deletion; native cancellation tombstone precedes native cleanup; source commit checks the flag and source presence before any discard. Plain cancel still rejects claimed source-owned clips. Cost: additive experimental native disposition must be mirrored by future iOS implementation, and Gate-C remains closed; no formal switch.
- Task R5: in_progress; BASE4b946b3. Brief manually extracted because task-start recognizes Task headings but plan uses R5; exact R5 section read. Ruling: no full Xcode/iOS26 SDK available, so native glass prototype cannot pass; implement platform accessibility preferences and opaque operation surfaces now, keep glassSupported=false on native bridge. Cost: no glass visuals until actual platform-layer/keyboard/perf acceptance; no synthetic blur claim.
- Ruling: Update AGENTS backup wording to match actual invariant: logs/diagnostics exclude source content; complete backup must include source content but exclude credentials/models/diagnostics. Previous blanket exclusion of original content from backups contradicted restore purpose. Cost if wrong: documentation semantics need reconfirmation, no runtime format change.


- Final: Ruling: First independent reviewer was quota-interrupted before a verdict; replace it for the one completed whole-branch review rather than claim approval. Cost: fallback model differs; incomplete review remains a merge gate.

## 最终独立审查的保留项

- Final: Ruling: 目标真机锁屏/通话/撤权/路由/功耗按设备不可用保留；成本：不能据模拟器承诺目标手机体验。
- Final: Ruling: iOS native capture/crypto与原生玻璃按SDK/真机门禁保留；成本：普通应用暂不启用这些能力。
- Final: Ruling: 自然中文质量/真实日历/付费云不以合成或受控结果替代；成本：公开发布前仍需实际业务验收。
- Final: Ruling: 历史静态benchmark不逐项重算，保留冻结证据与实现对应；成本：本次审查不重新担保全部历史数值。
- Final: Ruling: 正式数据按授权不读取/安装/操作，用身份与命名空间隔离保护；成本：无法提供内容散列核验。

- Final: Ruling: 保留本轮忽略目录中的故障日志与基线快照，不执行清理；用于可审计追溯并保护既有工作。成本：占用少量本地空间。
