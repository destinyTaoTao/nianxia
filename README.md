# 念下 · nianxia

本地优先的语音灵感本。Android / iOS Flutter 工程，记录与查找分开，原文始终保留。当前为开发试用版本，真机验收尚未完成。

## 已接入的流程

- 文字记录、时间线、详情、修订、收藏、独立追加与整组删除；SQLite 和私有音频持久化。
- 两分钟短录音、原音频回放、启动恢复检查；先保存，再本地转写。
- 关键词/日期查找、BGE 语义增强、临时语音查询；模型不可用保留文字路径。
- 可信清单固定模型文件和 SHA-256，流式下载后原子启用，默认不下载模型。
- 系统桌面“记一下 / 找一下”快捷动作、Android 快捷设置录音磁贴与透明胶囊、iOS App Intents 接入、原创声纹便笺图标、黑白灰浅深主题。
- 手动事项或整理候选进入系统日历编辑器；Android 保存结果显示未确认，iOS 仅 saved 回调表示成功。
- 用户自带 DeepSeek Key，每次确认单条正文后整理；结果与正文分开，编辑后标过期。不自动重放付费请求。
- 未加密 ZIP 备份（包含可读文本与 WAV），重复跳过、冲突副本和追加关系重映射。索引可重建。

## 当前视觉样式（awesome-flutter）

参考 awesome-flutter 中的 [Forui 分组列表](https://forui.dev/docs/widgets/tile/tile-group) 和 [Shadcn 卡片](https://mariuti.com/flutter-shadcn-ui/components/card/)，将相关内容放在统一的中性面板中。已核验 Forui 0.27.7、shadcn_ui 0.58.0 的维护者文档及 pub.dev 双平台信息；Forui 要求 Flutter 3.47+，本机 3.47.9 满足此最低条件。直接接入需要新增主题及控件迁移，本轮采用现有 SDK 实现视觉方向，未增加运行时依赖，也不以文档平台列表代替 iOS 实测。

浅色采用 #F6F6F6 画布、#FFFFFF 面板、#181818 正文、#606060 辅助文字、#DDDDDD 边界；深色为对应石墨灰层级。统一字体继承、按钮/表单/弹窗、14/16/20px 控件与面板圆角：首页主操作及最近记录分组，查找和完整列表使用独立结果面板，详情正文与编辑使用纸面区域，设置按实际用途分组。未修改保存、下载、云端发送及日历逻辑。

视觉验证扩展到浅/深色的首页、查找、详情、设置、编辑和日历表单，并检查小屏、两倍字体及实际可命中的设置入口。48 项主机测试和静态检查通过；独立 Standards / Spec 评审及后续缩放回归已完成。Android 原生运行与截图见当前交付记录，iOS 和真机继续按原安排后移。

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

备份格式 v1 使用无压缩 ZIP，仅允许 manifest.json、records.txt 与匹配 ID 的音频文件；最大 512 MB / 10,000 条记录，先暂存校验再事务合并。模型、凭证和临时查询不导出。恢复不重放云端请求，派生整理可重新生成。导出原文件在分享返回后清理，是否保存到外部位置以系统/目标应用实际结果为准。

## 验证

主测试边界是应用操作与可观察持久结果，主机测试使用真实临时 SQLite/文件。原生能力单独验证，替身结果不表示硬件或系统通过。运行截图可通过以下可选参数生成，字体文件仅用于本地视觉检查，不打包或提交系统字体：

```sh
flutter test test/visual_test.dart \
  --dart-define=SCREENSHOT_DIR=/absolute/output \
  --dart-define=SCREENSHOT_FONT=/absolute/chinese-font.ttf \
  --dart-define=SCREENSHOT_ICON_FONT=/absolute/MaterialIcons-Regular.otf
```

`integration_test/local_models_test.dart` 验证同一 Android 安装包中的真实 ASR + BGE CPU 路径。先按清单下载模型、tokens/vocab 和 sherpa 官方公开测试 WAV 到本机，再用 `tool/stage_android_models.sh` 放入**开发模拟器**的临时目录；应用内会重新验证模型 SHA-256。请先用 `flutter build apk --debug --target-platform android-arm64` 与 `adb install -r <apk>` 安装开发包，再用 `adb shell pm grant app.nianxia.nianxia android.permission.RECORD_AUDIO` 授权（仅限自己的开发设备）。运行：

```sh
ANDROID_SDK_ROOT=/absolute/android MODEL_FIXTURES=/absolute/fixtures tool/stage_android_models.sh
flutter drive --driver=test_driver/local_models_driver.dart \
  --target=integration_test/local_models_test.dart -d emulator-5554 --no-dds
```

录音适配测试需在开发模拟器内授予麦克风权限。此环境使用 `flutter drive` 接入相同 integration_test 用例，避免当前 SDK `flutter test -d` 的 VM/golden stream 连接问题；不改变测试断言。

这条测试是原生推理与采集/回放的适配测试，不能代替 50 条真实口述、30 条人工标注查询、离线网络检查、来电/锁屏/强杀、真实日历提醒、性能与发热验收。荣耀 Magic8、iPhone 17 的设备结果、iOS 签名安装与真实付费调用仍需相应设备和用户主动提供的测试条件。未完成的 GitHub Issue 保持打开。

## 来源与许可

模型归属：SenseVoiceSmall / FunASR，BGE / BAAI；转换分发：k2-fsa 的 csukuangfj 与 Xenova。SenseVoice 依据 [官方模型卡](https://huggingface.co/FunAudioLLM/SenseVoiceSmall)及 [FunASR 模型许可](docs/licenses/FunASR-MODEL-LICENSE.txt)，BGE 为 [MIT](https://huggingface.co/BAAI/bge-small-zh-v1.5)。运行时及 Dart 依赖许可可在应用“版本与开源许可”中查看。源码归属和模型许可分别核对，不能将 sherpa 的 Apache-2.0 直接当作权重许可。

DeepSeek 使用集成时核验的 [V4-Flash](https://api-docs.deepseek.com/updates/) 非思考、非流式 JSON 输出；固定官方 HTTPS 地址，不允许任意 Base URL。云端格式与来源校验不保证语义完全正确，整理结果仍需用户核对。

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
- `flutter test`：48 项主机测试通过，覆盖应用行为、真实 SQLite/文件、故障注入与界面；包含浅深主题、两倍字体、无障碍触控/标签及减少动态效果。新增胶囊重复呼出、返回保存、编辑保留、拒绝权限转文字、确认丢弃及启动期间退后台回归。
- Android API 36 ARM64 模拟器、飞行模式：通过 `flutter drive` 执行真实 SenseVoice + BGE 同包、语义有/无结果、原生 PCM 录音和 WAV 回放。仅使用公开模型样本和合成文本。
- 1,000 条合成短记录、主机 20 次关键词查询 P95：约 9.4 ms，非手机指标。
- [浅色时间线](docs/screenshots/home-light.png)、[深色时间线](docs/screenshots/home-dark.png)、[查找](docs/screenshots/search-light.png)、[详情](docs/screenshots/detail-light.png)为实际 widget 运行截图，非真机截图。
- Android API 36 ARM64 Release、飞行模式：实际运行通过 URL 冷启动、重复呼出不截断、系统返回保存并返回原系统设置页面、实际点击快捷设置磁贴的热启动、深色主题、原生权限拒绝与首次授权；截图见[录音胶囊](docs/screenshots/android-capsule-recording.png)、[深色胶囊](docs/screenshots/android-capsule-dark.png)、[保存完成](docs/screenshots/android-capsule-saved.png)、[权限失败](docs/screenshots/android-capsule-permission.png)。均为模拟器，未冒充真机。
- 原生重复呼出验证捕获并修复了短暂 `inactive` 被当作退后台而截断录音的问题；隐藏/暂停/分离及 Android 系统息屏事件触发自动保存，音频中断仍通过原生录音状态处理，符合 [Flutter 生命周期语义](https://api.flutter.dev/flutter/dart-ui/AppLifecycleState.html)。冷启动一次 `am start -W` 活动展示约 0.7 秒，只是系统展示耗时，不是采集延迟或 P95。
- Swift 前端语法解析通过；`flutter build ios --no-codesign` 未能构建，提示 `Application not configured for iOS`。本机只有 Command Line Tools，缺少完整 Xcode 与 CocoaPods；此结果不表示 iOS 已构建或安装通过。
- 模拟器 ExoPlayer 释放时观察到 `Handler ... on a dead thread` 警告，回放完成断言及整个 driver 均通过；尚未在真机确认是否复现。
- 真实付费 API、双端真机日历提醒、双端系统备份排除的设备实测均未执行；Android 模拟器通知链路的结果见下节。

Android ARM64 Release 试用包已构建并安装启动，约 **51.0 MB**（不含首次下载的模型），仍使用本地 debug 签名；APK 仅包含 ARM64 与单一 ORT 运行时。产物为 `build/app/outputs/flutter-apk/app-release.apk`，SHA-256：`8c41e052aeec943069657348c7261a0b0baf128d96b438dc680028cb22856057`。

运行集成测试后再构建 Release 时使用上面的正常 `flutter build apk --release --target-platform android-arm64`，让 Flutter 重新生成排除测试插件的注册文件；不要复用测试阶段生成的注册文件直接加 `--no-pub`。Flutter 平台构建应串行执行。

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
