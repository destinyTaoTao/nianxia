# 连续手记最终交付：#17–28

2026-11-22。已完成选定设计下无需用户介入的实现与本地/Android隔离验证；工作区保留全部既有WIP，未暂存、提交、推送、发布或关闭GitHub议题。正式内容、音频与凭证未读取或修改。

## 独立体验包

[Android ARM64 Profile APK](/Users/xiaodeng/chatgpt/nianxia/build/isolated-preview/890b3f06-7bd4-4e78-937c-6a1af9ba9953/nianxia-continuous-preview.apk)。测试标识`app.nianxia.nianxia.test`，显示名“念下·测试”，普通录音默认路径，未开启原生录音/玻璃/加密实验门禁。

- [构建清单与SHA-256](experience-manifest.json)，APK SHA-256：`59e252710476bf607a4be5ba69eaf9f94819f820d3a01e3bc04f54d4e7c0d963`。
- [实际启动回执](experience-ready.json)，runId `890b3f06-7bd4-4e78-937c-6a1af9ba9953`。清单的sourceDigest是当次生产Dart/Android源及配置摘要，不冒充未提交代码的Git commit。
- 手动入口`integration_test/preview/main.dart`使用普通WidgetsFlutterBinding，持续运行产品App，没有testWidgets、测试驱动或自动完成退出。包含系统快捷入口、screen-off处理和模型许可。
- 私有`cache/continuous-preview/<runId>`内为3条合成原记录、2条追加及自己的模型/诊断。该测试资料会受卸载或清理缓存影响。正式应用库完全独立。
- 模型不打入APK。当前模拟器从指定公开模型夹具复制并逐文件验SHA-256；其他设备需先在设置准备离线模型，之后断网体验。没有种子API Key，不自动发起云整理。
- 已实际启动并操作设置，核对浅深两套正常界面；最后恢复“跟随系统”，停留在首页，供继续手动体验。

| 体验包实际窗口 | 浅色 | 深色 |
| --- | --- | --- |
| 首页 | [首页](experience-home.png) | [首页](experience-home-dark.png) |
| 主题设置 | [设置](experience-settings.png) | [设置](experience-settings-dark.png) |

复建并在核验后的模拟器启动：

```sh
python3 tool/run_isolated_preview.py --device emulator-5554
# 只构建、核验身份和归档，不安装
python3 tool/run_isolated_preview.py --build-only
```

需要项目既有Flutter/JDK/Android SDK环境。每次生成新nonce与清单，安装前核验APK ID和独立标签，只授权测试ID；禁止卸载回退。脚本只对正式包核对安装路径元数据。

建议体验顺序：按住说话并松手保存；待转写后从顶部“找一下”显式查找；打开详情，分别追加文字和语音并核对定位；查找追加时打开该次详情或所属记录，返回核对原位置；从更多菜单分别核对单次/整组删除范围；在设置切换浅深与跟随系统。权限拒绝、无模型和失败路径仍保留文字与重试退路。

## 最终验证

2026-11-22执行`bash tool/check.sh`：48项Python工具测试、`flutter analyze`无问题、462项Flutter测试全部通过。[机器摘要](verification-summary.json)。日志`/tmp/nianxia-remaining/22-final-check.log`；`git diff --check`通过。新增语义操作实际激活原音按钮；此前唯一失败是SemanticsHandle释放晚于框架校验，现已在finally中先释放，保留所有播放/数据断言。

原生`:app:testDebugUnitTest`已有17项通过、0失败/错误（2026-11-20；之后无原生源码修改），本轮未将其说成真机验收。最新独立包构建、安装身份核验、实际启动及主题切换截图通过。工作区没有新增生产依赖、schema迁移或备份格式变化。

| 切片 | 证据及范围 |
| --- | --- |
| #17 点按录音闭环 | [计划与红绿结果](../../superpowers/plans/2026-11-16-recording-loop.md)，控制器、准备/取消/保存恢复回归持续包含在当前门禁 |
| #18 首页文字记录 | [首页验收](../2026-11-16-continuous-home/README.md) |
| #19 主题偏好/性能 | [最终性能诊断与全部失败样本](../../performance/theme-switch-2026-11-22/README.md) |
| #20 按住/松手保存 | [手势、生命周期及点按替代](../2026-11-16-hold-recording/README.md) |
| #21 显式查找 | [20张深浅截图与分页/日期/返回验证](../2026-11-19-explicit-search/README.md) |
| #22 语音查找 | [默认不开麦、校对确认、临时资料清理](../2026-11-19-voice-query/README.md) |
| #23 详情/编辑/播放器 | [正文与原始资料分离、CAS及实际播放器/IME](../2026-11-19-detail-edit/README.md) |
| #24 文字追加 | [幂等、95次后有界定位、父删除保护](../2026-11-20-text-append/README.md) |
| #25 语音追加 | [普通和受控原生实际采集/回放，20张截图](../2026-11-20-voice-append/README.md) |
| #26 溯源与按需回放 | [18张深浅截图、单播放器、失败恢复、后台迟到取消](../2026-11-20-search-origin/README.md) |
| #27 确认范围安全删除 | [14张深浅截图、事务内范围校验/失败回滚](../2026-11-20-delete-confirmation/README.md) |
| #28 跨流程组合 | [实际离线模型组合结果](../2026-11-20-continuous-workflow/android-profile.json)，8张截图如下 |

跨流程runId `962b7f0d-fdee-4cc5-ad42-66068c1db63a`：模拟器飞行模式/Wi-Fi关闭并核验无默认网络，完成按住录音→松手保存→真实SenseVoice/BGE→快捷查找转文字→详情→文字失败保留/重试→语音追加→再查找→按确认范围删除，2次真实ASR、0次Dart HTTP调用。退出恢复原网络设置。仅麦克风边界使用公开合成PCM；SQLite、采集保存、模型、后台任务和UI均为实际实现。它不单独证明保存先于转写的时序屏障，该不变量由专项录音回归覆盖。

[转写后首页](../2026-11-20-continuous-workflow/transcribed.png)、[查找](../2026-11-20-continuous-workflow/found.png)、[保存失败保留](../2026-11-20-continuous-workflow/append-failed.png)、[文字追加](../2026-11-20-continuous-workflow/text-appended.png)、[语音追加](../2026-11-20-continuous-workflow/voice-appended.png)、[再查找及所属](../2026-11-20-continuous-workflow/refound.png)、[整组确认](../2026-11-20-continuous-workflow/delete-confirmed-scope.png)、[删除后刷新](../2026-11-20-continuous-workflow/deleted.png)。已核对状态和来源，成功提示可短暂覆盖底部日期，正文与操作仍可达。

当前门禁保留分页10001行/宽正文的有界投影、跨页计数/失效/删除、95次追加定位、旧schema/备份夹具、迟到转写编辑保护、受管媒体清理、日历确定性和未知回执、单条云确认/不自动重放、隐私及恢复回归。查找每页不累积完整正文，音频点击后只读当前一条；追加定位只替换最多40条窗口，没有用全量读取掩盖定位问题。

## 主题结论与剩余边界

原协议关闭诊断探针后完整通过，真实点按稳定29次背景token响应P95为55.551ms，原始基线349.014ms，#19优化后54.736ms；当前build P95 4.373ms。主要改进仍有效，没有新增布局导致持续退化的证据。

raster P95仍为81.055ms；即使只点击已选项、不改主题，也有51.560ms。模拟器使用SwiftShader软件渲染，不宣称已达到60FPS。先前3轮采样失败及两轮超窗具体记录保留；个别系统调度超窗未被因果隔离，未伪称修复了一个没有复现证据的应用缺陷。完整口径与数值见性能报告。

仅有API36 ARM64模拟器可用；当前Xcode选择仍是CommandLineTools。Magic8/iPhone17、iOS构建及实际生命周期/音频路由、自然中文输入、TalkBack/VoiceOver人工体验、系统日历真实保存/提醒、真实付费云调用、50条口述/30条标注查询和长时温耗仍归[开放的#15](https://github.com/destinyTaoTao/nianxia/issues/15)，不以替身或模拟器替代双端真机通过。
