# 念下 · nianxia

本地优先的语音灵感本。Android / iOS Flutter 工程，记录与查找分开，原文始终保留。当前为开发试用版本，真机验收尚未完成。

## 已接入的流程

- 文字记录、时间线、详情、修订、收藏、独立追加与整组删除；SQLite 和私有音频持久化。
- 两分钟短录音、原音频回放、启动恢复检查；先保存，再本地转写。
- 关键词/日期查找、BGE 语义增强、临时语音查询；模型不可用保留文字路径。
- 可信清单固定模型文件和 SHA-256，流式下载后原子启用，默认不下载模型。
- 系统桌面“记一下 / 找一下”快捷动作、原创声纹便笺图标、黑白灰浅深主题。
- 手动事项或整理候选进入系统日历编辑器；Android 保存结果显示未确认，iOS 仅 saved 回调表示成功。
- 用户自带 DeepSeek Key，每次确认单条正文后整理；结果与正文分开，编辑后标过期。不自动重放付费请求。
- 未加密 ZIP 备份（包含可读文本与 WAV），重复跳过、冲突副本和追加关系重映射。索引可重建。

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

## Spec

独立评审初稿发现 3 项实现错误，均已修复：

- **P1 两分钟自动保存**：#3 要求“到达自动停止保存”，原计时/字节限制冲突；修复与 Standards 第一项相同。
- **P1 恢复后编辑再导入**：#14 要求“ID相同内容不同保留冲突副本并提示”，原历史指纹直接跳过。现在核验当前正文、元数据、音频哈希及父关系，生成冲突副本并更新映射；`backup_test.dart` 验证再导入与重复导入。
- **P2 收藏追加不可见**：#10 要求收藏在时间线/详情可见，原收藏页仍只选根记录。现在显示收藏追加并保留所属记录导航，`ui_test.dart` 验证用户操作路径。

未发现实质范围扩张。该轴另有 **1 项未完成的验收范围**：#15 的 Magic8/iPhone 17、iOS 安装、真实提醒、50 条口述、30 条人工标注查询及手机性能/发热。代码和模拟器通过不能替代这些验收，因此不关闭对应 Issue。该轴最严重实现错误为 P1，已修；完整产品验收仍未完成。

## 本轮实际验证

- `flutter analyze`：通过。
- `flutter test`：31 项主机测试通过，覆盖应用行为、真实 SQLite/文件、故障注入与界面；包含浅深主题、两倍字体、无障碍触控/标签及减少动态效果。
- Android API 36 ARM64 模拟器、飞行模式：通过 `flutter drive` 执行真实 SenseVoice + BGE 同包、语义有/无结果、原生 PCM 录音和 WAV 回放。仅使用公开模型样本和合成文本。
- 1,000 条合成短记录、主机 20 次关键词查询 P95：约 8.5 ms，非手机指标。
- [浅色时间线](docs/screenshots/home-light.png)、[深色时间线](docs/screenshots/home-dark.png)、[查找](docs/screenshots/search-light.png)、[详情](docs/screenshots/detail-light.png)为实际 widget 运行截图，非真机截图。
- Swift 前端语法解析通过；`flutter build ios --no-codesign` 未能构建，提示 `Application not configured for iOS`。本机只有 Command Line Tools，缺少完整 Xcode 与 CocoaPods；此结果不表示 iOS 已构建或安装通过。
- 模拟器 ExoPlayer 释放时观察到 `Handler ... on a dead thread` 警告，回放完成断言及整个 driver 均通过；尚未在真机确认是否复现。
- 真实付费 API、真实日历提醒、双端系统备份排除的设备实测均未执行。

Android ARM64 Release 试用包已构建并安装启动，约 **50.9 MB**（不含首次下载的模型），仍使用本地 debug 签名；APK 仅包含 ARM64 与单一 ORT 运行时。产物为 `build/app/outputs/flutter-apk/app-release.apk`，SHA-256：`07b7a03f7dd78134d625a43a87fb6f80fd852f028ee7b66f57eec11bda3f7817`。

运行集成测试后再构建 Release 时使用上面的正常 `flutter build apk --release --target-platform android-arm64`，让 Flutter 重新生成排除测试插件的注册文件；不要复用测试阶段生成的注册文件直接加 `--no-pub`。Flutter 平台构建应串行执行。

Release 包还在模拟器中通过实际界面完成了文字创建、持久显示和关键词查找；Android 包管理器核验未设置 ALLOW_BACKUP，当前模拟器没有日历编辑应用，因此真实保存及提醒仍未验证。
