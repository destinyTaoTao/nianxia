# #15 自动验收补齐与 Android 候选包检查

2026-11-26。基于 `e6ba4689f7400c78e6e7d9dbd23b7e55aacee366`，生产源码摘要 `50f2bff745a84d193a8426733da41e3dd6963a5908671483bf3dcd600c2e6ebe`，与11/25实际体验及Android集成证据一致。本轮不改产品行为、不更新依赖/数据格式、不启用实验默认能力。

后续收尾授权：用户已明确要求提交、推送本轮验收资料并同步#15。验证阶段的“不提交/推送/改写议题”限制由此次授权替代；正式数据保护、禁止安装正式包及真机待验收边界继续适用。GitHub只归档对照、检查结果、日志和复现脚本，APK、模型和本机工具链不纳入源码提交。

## 已完成的自动工作

- [48条用户故事与7条综合门槛逐项对照](acceptance-matrix.md)，对应[机器矩阵](acceptance-matrix.json)。每条包含实现、测试、归档Android结果（如适用）和真实平台/外部授权缺口。没有把“有测试”当成“两端已验收”。
- 重新执行完整主机门禁：50 Python通过、Flutter analyze无问题、505 Flutter通过，1项VM-service专用测试在默认门禁跳过；单独堆回收测试通过，0/48结果保留。
- 实际重跑Android原生 `./gradlew :app:testDebugUnitTest --rerun`：17项通过，0 failure/error/skipped。仅测试任务强制重跑，前置编译任务可复用缓存；这是JVM测试，不是真机执行。
- 构建普通与隔离ARM64 Release，各通过19项APK检查；以实际错配APK做负向对照，身份、标签、provider和权限校验拒绝错包。
- 只执行本机构建、APK静态检查、临时库主机测试和原生JVM测试。未安装、启动或操作任一设备/模拟器，用户正在使用的体验包保持原状。

## 候选包实测

| 项目 | 普通Release，仅供检查 | 隔离Release体验候选 |
| --- | --- | --- |
| 入口 | `lib/main.dart` | `integration_test/preview/main.dart` |
| 应用ID | `app.nianxia.nianxia` | `app.nianxia.nianxia.test` |
| 标签 | 念下 | 念下·测试 |
| APK字节 | 51,728,673 | 51,794,281 |
| MiB | 49.33 | 49.39 |
| 构建耗时 | 48.348秒 | 32.059秒 |
| 模式/ABI | Release / arm64-v8a | Release / arm64-v8a |
| minSdk / targetSdk | 24 / 36 | 24 / 36 |
| debuggable | false | false |
| 签名 | Android Debug试用签名，v2验证通过 | 同左 |
| 验证provider | 未声明 | 仅独立包声明受限结果provider |
| 安装/启动/运行验收 | 未执行 | 未执行 |
| 正式分发就绪 | 否 | 否 |

大小是本次APK，不含离线模型；不将不同构建模式/入口的包体差异解释为优化收益。签名有效且非debuggable不等于正式分发签名。当前仍需要目标设备安装、生命周期、硬件、质量与性能验收。

隔离候选包：[nianxia-test-release-candidate.apk](/Users/xiaodeng/chatgpt/nianxia/build/t14-candidates/2026-11-26/4dadd0dc-756d-42e8-8056-40a95589909b/nianxia-test-release-candidate.apk)。仅完成构建与静态检查，未宣称新Release已启动成功。不会自动安装替换当前 `.test` 体验包。

普通包存于同一目录 `nianxia-ordinary-release-INSPECTION-ONLY.apk`，其ID与正式应用一致，**不得用它覆盖安装来做本轮体验**。本轮仅检查该文件，没有安装正式ID。

- 普通APK SHA256：`fbc24ecb96c46039f9996527a418ca1f4c9bcae18c56272d89b902b216ae1d55`。
- 隔离APK SHA256：`8648199431edecae6ca8b7f3de53ddcc9f7d2698e03e69aae5f120e53bc72f0e`。
- [构建命令/耗时、哈希、权限、native库与检查结果](android-candidates.json)，以及[正/负对照](inspection-negative-control.json)。本机artifact目录另有每包manifest。

19项包检查覆盖：准确ID/标签、非debuggable、minSdk24、targetSdk36、仅ARM64、allowBackup=false、明文HTTP关闭、实际打包备份规则与云备份/迁移排除所有声明域、未混入实验age库/模型权重/SQLite/WAV/keystore文件、模型清单与源码一致、模型许可文件存在、验证provider按包区分、签名验证/v2签名、预期权限集合。

这些检查不是全面安全认证。`.db/.wav/.keystore`等文件未打包不等于完成全二进制秘密扫描；allowBackup及规则存在不等于已证明所有OEM系统迁移行为；INTERNET权限仍用于主动模型下载和逐条授权云整理，不据此宣称整个应用无网络行为。原生录音service声明保留，普通Dart入口未注入受控native capture；没有以“组件存在”声称后台能力已默认启用。

## 证据与复现

| 检查 | 记录 |
| --- | --- |
| 需求原文与当前环境 | [#1快照](issue-1-snapshot.json)、[#15快照](issue-15-snapshot.json)、[环境/源码摘要](environment.json) |
| 主机门禁 | [host-gate.log](logs/host-gate.log) |
| 单独堆回收 | [heap-gate.log](logs/heap-gate.log) |
| 原生检查 | [实际重跑日志](logs/native-unit.log)、[XML汇总](native-unit-results.json)、[首次缓存任务记录](logs/native-unit-cached.log) |
| 本次构建 | [普通构建](logs/ordinary-build.log)、[隔离构建](logs/isolated-build.log) |
| APK原始检查 | [aapt/apksigner输出](apk-inspection)、[检查脚本](inspect_candidates.py) |
| 上一轮同源码Android运行 | [11/25完整报告](../2026-11-25-quality-review/README.md)、[14类结果](../2026-11-25-quality-review/android/runs.json) |

需要既有Flutter、Android SDK、JDK17、Gradle缓存环境；构建任务串行执行。普通包命令：

```sh
flutter build apk --release --target-platform android-arm64
```

隔离包使用 `integration_test/preview/main.dart`、`--release`、`--target-platform android-arm64`，并传入当次 `UI_PREVIEW_RUN_ID`（UUID v4）与上述 `UI_PREVIEW_SOURCE_DIGEST`；完整命令见构建JSON。构建输出会覆盖通用 `app-release.apk`，所以每次完成后立即复制到独立归档目录再构建下一包。

只读重验两个归档APK（工具路径按本机替换，apksigner需要JAVA_HOME）：

```sh
python3 docs/validation/2026-11-26-t14-automatic/inspect_candidates.py \
  --artifacts /absolute/path/to/candidate-directory \
  --output /tmp/t14-inspection-repeat \
  --tools /absolute/path/to/android/build-tools/36.0.0 \
  --source docs/validation/2026-11-26-t14-automatic/environment.json
```

脚本只读取APK并输出证据，不含adb/install/清理设备命令。实际Release压缩资源名称，备份XML由manifest资源ID→resources表→APK真实路径解析；不要求ZIP内保留源码的`res/xml/backup_rules.xml`文件名。初次检查因沿用源码路径失败，排查后修正检查方式，未修改产品包。另一次脚本调用未继承JAVA_HOME，使用既有JDK17后通过；构建日志中的Gradle/SDK版本提醒保留，没有为消除提醒升级依赖。

一次独立证据审查指出：首次原生任务为UP-TO-DATE，不能把既有17项XML说成本次新执行。已保留首次日志，核验本机Gradle task help支持仅重跑该任务的`--rerun`后实际重跑；最终日志中测试任务无UP-TO-DATE标记，新的XML17项无失败。其余未发现需修复的Important/Critical证据缺陷；不承诺不存在其他问题。

## #15 仍然开放的验收

1. Magic8与iPhone17接入、系统/内存配置、信任与签名安装。当前Mac只有CommandLineTools，未发现完整Xcode；iOS构建与运行尚无通过证据。
2. 两端自然麦克风、来电/撤权/锁屏/系统回收、真实飞行模式闭环与系统文件选择/导出恢复。
3. 至少50条自然口述、30条人工标注有答案查询和无答案/冲突集；独立验收集，不能用TTS或重复向量代替。
4. 真机P95：前台点击至采集≤500ms、停止至保存≤1s、30秒ASR≤15s、1000条热查询≤1s；冷启动/语音查询单列，并报告峰值内存、发热/耗电。先约20次基线，之后检查长尾。
5. 测试日历的真实保存/取消/未知回执和提醒；TalkBack/VoiceOver、图标与自然手势/主题帧呈现。
6. 可选云整理真实调用需要另行授权测试Key与预算，不读取现有凭证，不自动调用付费服务。
7. 双端可安装试用版本、已知限制和两周小范围反馈。实验原生后台录音/加密/玻璃继续按各自门禁处理，不为验收自动开启。

验证完成时未提交/推送或改写GitHub议题；用户随后明确授权归档提交并同步#15，状态以Git历史及议题记录为准。#15七条综合条件仍未整项完成，真机项目保留待验收。正式记录、音频、凭证、系统日历和设备设置均未访问/修改。
