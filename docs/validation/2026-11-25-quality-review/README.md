# 已实现部分质量清理与验收（2026-11-25）

> 提交收尾更新：用户随后明确授权提交、推送及同步子议题。本文“未提交／不推送”等表述记录验收时点的状态；当前授权、提交前重跑结果及逐票证据索引见 [publication.md](publication.md)。正式数据保护、实验默认门禁及未验收平台限制继续适用。

本轮对现有连续手记实现做 Standards / Spec 两轴审查、故障复现、一次最终修复及验证。R1–R8 已完成；没有借此增加产品功能、切换视觉方向或启用实验默认项。代码仍是未提交 WIP，HEAD 保持 `93cb09b58d19fe26b6e619d9d86a4e442f015faf`。测试通过不等于双平台正式发布验收。

## 结果与改动

| 范围 | 原问题及完成结果 | 主要证据 |
| --- | --- | --- |
| R1 转写 | running 写入失败会泄漏在途标记；失败状态写回可能盖住原异常。统一 try/finally，真实 SQLite 故障后可重试且保留原始错误和音频。 | `test/transcription_recovery_test.dart` |
| R2 录音所有权 | 锁定版本 SDK 的 cancel 未等待 native 回执；停止失败后可能提前放行。改为实际 stop 确认，跨页面/资料库保留物理占用，提供同库重试；未用过的麦克风不为关闭而创建。 | `test/device_microphone_test.dart`、`test/capture_release_safety_test.dart` |
| R3 收尾 | 查询临时文件失败会跳过收尾；流错误、异步 observer cancel 可能未处理。区分设备未停和文件未删，页面移除立即脱离 PCM，实际 writer flush 完成后才校验保存。 | 上述安全测试及 `test/capture_page_release_test.dart` |
| R4 任务容量 | 终态/旧修订任务无限积累。每次认领有界修剪 256 行，真实 SQLITE_FULL 时分批回收并重试一次；保留当前失败次数、运行租约、未知未来 sidecar 和原始资料。 | `test/local_job_retention_test.dart` 的真实满库测试 |
| R5 诚实反馈 | 父记录开始前删除、尚无片段时错误宣称音频保留。现在明确尚未开始，无无效独立保存入口；已有实际片段的主动保存/幂等不变。 | 普通/native App 回归及父删除截图 |
| R6 美观与可访问 | 点按、按住、native 共用 105 秒临近两分钟提示；固定按住按钮位置、liveRegion、320 宽 2 倍字可操作，沿用深浅中性 token。 | `test/capture_limit_hint_test.dart`、18 张主机截图 |
| R7 可观测 | 将现有诊断实际接入录音阶段、源写入和搜索；取消/迟到/失败分类正确，关闭排空，不重复计数，不记录正文、查询、源 ID、路径或凭证。诊断故障不阻止业务。 | `test/operation_diagnostics_test.dart` |
| R8 维护性 | 共享“仅完成自己拥有的 route”规则；清理录音/确认页不会 pop 掉后来打开的无关页面。查询子路由只保留活动引用。 | 实际 Navigator 与生命周期测试 |

最终审查又确认并修复：同库入口无法重试释放、WAV writer 关闭竞争、已完成搜索被关闭监听器持有、查询重试错误被重置、生命周期 popUntil 误关新页面。两个诊断分类问题按本轮观测验收要求提升优先级并修复。作者最终检查另复现 observer cancel 未处理错误，同一修复轮完成。没有延后这些已确认问题；没有进行无限重复 review。

搜索结果的服务端堆 GC 回归：资料库仍打开时，修复前 **48/48** 个已完成结果被保留，修复后 **0/48**。这证明该引用泄漏解除，不代表整进程 RSS 或设备内存下降幅度。

## 实际验证

| 检查 | 结果 | 记录 |
| --- | --- | --- |
| `bash tool/check.sh` | 50 Python 通过；Flutter analyze 无问题；505 Flutter 通过、1 个服务专用测试跳过 | [host-gate.log](logs/host-gate.log) |
| `flutter test --enable-vmservice --no-dds test/search_result_retention_test.dart` | 单独运行上述跳过项，1 通过，堆保留 0/48 | [heap-gate.log](logs/heap-gate.log) |
| Android `./gradlew :app:testDebugUnitTest` | XML 17 测试，0 failure/error/skipped；Gradle 成功，复用既有 native 输出 | [native-unit.log](logs/native-unit.log) |
| `flutter test test/visual_test.dart`（SCREENSHOT_DIR、系统中文字体、Material icon 字体） | 9 通过，18 PNG；检查深浅、窄屏 2 倍字、临近截止及父删除状态 | [visual.log](logs/visual.log)、[主机截图](screenshots/host) |
| 受保护 Android runner | 14 类用例通过；19 次成功运行包含最后 5 类受影响复跑，156 PNG | [runs.json](android/runs.json)、[android-final.log](logs/android-final.log) |
| 最新独立体验包 | 包身份/源码摘要/安装 APK SHA 一致；首页/设置可操作；杀进程重启后新 ready 回执且深色偏好保留 | [manifest](experience-manifest.json)、[重启回执](experience-restart-ready.json) |

14 类：hold-recording、voice-query、detail-edit、text-append、voice-append、search-origin、delete-confirmation、explicit-search、continuous-home、local-jobs、diagnostics、continuous-workflow、theme-performance、engine-reconnect。前 13 类 Profile；engine-reconnect 最终采用 Release native-result 模式。最终 observer 收尾改动后复跑 hold-recording、voice-query、detail-edit、voice-append、continuous-workflow；其余覆盖不受该改动影响。所有最终源码经过完整主机门禁。

可复现 runner 命令为：

```sh
python3 tool/run_isolated_validation.py --platform android --device emulator-5556 --target acceptance --case <case> --mode profile
python3 tool/run_isolated_validation.py --platform android --device emulator-5556 --target capture --case engine-reconnect --mode release
python3 tool/run_isolated_preview.py --device emulator-5556
```

失败记录如实保留：[android-initial.log](logs/android-initial.log) 的最后一个 engine Profile driver 未退出，不计整体通过。应用 checkpoint 已证明同进程换 engine、原 native owner 继续 PCM 且重开源行数为 1；driver 仍粘连销毁的 engine。仅中断已核实身份的该 driver，再用 Release native-result 模式通过相同验收：[engine-reconnect.json](android/engine-reconnect.json)。首轮新 AVD 无正式包时 runner 错把 `pm path` 空退出当错误；修复为第二次成功 metadata 查询证明不存在，否则 fail closed，补两项工具回归后再跑，未安装正式包绕过校验。

连续工作流使用公开指定 note/query PCM 与实际 SenseVoice/BGE，2 次 ASR、1 次 BGE、**0 网络尝试**，断网状态核验并恢复。它验证真实模型与保存/检索闭环，不代替自然说话、物理麦克风真机质量验收。其余部分 UI 路径采用受控识别结果，以稳定验证状态和错误交互。

## 主题与容量实测的边界

主题 100 条记录、30 次切换，排除首冷样本后 29 次 warm，600ms 帧窗口，60Hz 模拟器。P95 实测如下，原始证据 [theme-summary.json](android/theme-summary.json)、[theme-timings.json](android/theme-timings.json)：

| 指标 | P95 ms |
| --- | ---: |
| 实际选择至主题 canvas 响应 | 63.934 |
| callback 对照响应 | 24.329 |
| 重选相同项对照响应 | 20.294 |
| 实际选择 build / raster / total | 8.107 / 74.117 / 129.696 |
| callback 对照 raster | 69.142 |
| 相同项对照 raster | 46.915 |
| SQLite 独立写入 | 1.765 |
| 深浅 ThemeData 构造一对 | 1.303 |

新建 AVD 为 OpenGL 软件渲染、2 CPU，与此前 ANGLE/Vulkan、4 CPU 不同，**不能据此作同条件优化前后比较，也没有达到稳定 60 FPS 的证据**。对照结果提示栅格/模拟器开销仍明显；不据此把所有卡顿归因于单一因素。此前同环境的主题优化证据仍见 `docs/performance/theme-switch-2026-11-22/README.md`。

本轮主机全套中的 20k 恢复 3353ms、最大事件间隔 15ms；10k/64D 合成检索 Recall@10=1.0、缓存 17,383,424 bytes，关键词 scan/index P95 39.1/2.226ms、semantic P95 6.938ms。均为主机/合成测试，不能转述为手机性能承诺。

## 独立体验包与安全边界

最新 APK：[nianxia-continuous-preview.apk](/Users/xiaodeng/chatgpt/nianxia/build/isolated-preview/1d8758fd-7430-4682-a1ad-c091f9f160fb/nianxia-continuous-preview.apk)。ARM64 Profile，应用名「念下·测试」，ID `app.nianxia.nianxia.test`，71,615,876 bytes（68.30 MiB），模型不内置在 APK 中。

- APK SHA256：`ba0495cf693ed2c67511ecb11b7a7a20c23ab4caa1cae953e8e91d223d0c44b8`。
- 源码摘要：`50f2bff745a84d193a8426733da41e3dd6963a5908671483bf3dcd600c2e6ebe`；摘要覆盖 runner 定义的 Dart、Android 源、模型清单、pubspec/lock 与 preview 入口，不等于整个 Git diff 摘要。
- 安装、运行及模型验证仅在专用临时 AVD `nianxia-quality25` / emulator-5556，资料库及演示记录均为合成测试资料。原 emulator-5554 的旧体验包保留。最终将专用 AVD 从无窗口模式重启为可见窗口（保留它自己的测试数据）；核对启动日志窗口创建、boot 完成、最新 APK SHA、前台 Activity 及 ready 回执，并截图确认深色首页，留给用户体验。CUA 不能绑定该未打包 Qt 进程，前台内容由专用 ADB 路径及截图验证。
- 只从指定公共 staging 复制四份清单 SHA 核验模型和两份公开 PCM，未读取原模拟器应用私有资料。正式包仅核对安装 metadata，未读写正式记录、音频、凭证，未覆盖安装/清理正式应用。
- source schema2、备份 v2、冻结旧夹具兼容契约未变；依赖/锁文件、minSdk/iOS 部署配置未改。native/玻璃/实验加密默认门禁、云端默认关闭与逐条确认保留。
- 诊断是有界、尽力记录的本机操作证据，不提供防篡改审计保证；保留原队列/文件/周期预算，业务不依赖日志成功。
- 未暂存、提交或推送；原有大量 WIP 原地保留。最终 `git diff --check` 和新增证据敏感信息检查通过。

截图：[浅色首页](experience-home.png)、[深色重启首页](experience-home-dark.png)、[可见模拟器当前首页](experience-visible-home.png)、[设置](experience-settings.png)、[Android 流程](screenshots/android)。共 179 PNG = 18 主机 + 156 Android 流程 + 5 体验截图；不是 179 次独立人工验收。

## 审查裁决及代价

1. 依用户要求在现有 WIP 上执行而不建提交历史；代价是本轮与此前改动混在大 diff 中，故保留计划、ledger 和验证证据。
2. 未收到物理停止确认就保留占用；允许失败/已移除 owner 的重试释放。代价是无法确认设备状态时暂时阻止新录音/播放，避免重叠占用。
3. 关闭资料库时按既有空结果契约结束搜索，并移除完成监听；代价是关闭后的迟到结果不交付，不让无响应模型无限拖住关闭和诊断。
4. 只关闭注册并仍活动的查询子页/确认框；代价是新增此类 route 时需显式传递 ownership，实际交错回归防止误关其他页面。
5. 正式包缺失必须有独立成功 metadata 证明；代价是 PackageManager/transport 不可用时停止验收，不猜测、不绕过。
6. 取消/迟到诊断从 Minor 提升为本轮必修；代价是增加实际关闭/取消回归，避免新增观测误报。最终审查确认的问题无延期项。

Magic8/iPhone17 真机、完整 iOS/Xcode、自然中文语音集、TalkBack/VoiceOver、系统日历真实保存、云端可选链路和长时间温升耗电仍需原平台验收清单范围内的独立验证。本轮不能对这些未执行项声称通过，也不能保证不存在其他缺陷。
