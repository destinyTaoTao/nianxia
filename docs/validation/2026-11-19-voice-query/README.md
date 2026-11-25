# #22 语音查找与识别文字确认验收

2026-11-19。继续已批准的连续手记设计与#17–21 WIP；没有暂存、提交、推送、关闭议题或操作正式资料。剩余#23–28继续执行，不以本票完成代表整套目标完成。

## 已实现

- 语音入口先展示“按住说出线索”，不自动开麦；按钮位置固定，松手识别、上滑取消、移回继续。另保留“点按说出线索”作为键盘/辅助操作路径。
- 查询复用既有采集所有者和手势；与笔记保存明确区分，不出现保存笔记或恢复为笔记操作。实际识别完成只返回可编辑文字，用户可修改、重说、取消，再主动提交到#21共用的文字/日期/代次逻辑。
- 无模型、权限失败、识别失败或空结果均保留文字退路。活动录音不能启动第二采集；准备期松手和迟到授权不继续开麦。
- 查询仅前台。切后台取消采集及待打开的语音意图；已在运行的识别结果不得覆盖输入。系统返回同步废止面板，退场动画期间的识别不得再弹出查找页。嵌套点按面板全部退出并清理。
- 受控原生自动截止在finalized后单次消费，不等待不存在的松手；停止/领取失败后的重说先清理旧会话，再开放新查询。默认原生门禁不改。
- 完成、失败、取消沿用临时音频清理。取消查询发出非正文变更通知，不再误称“记录已变化”或触发当前查找刷新。没有新增依赖、模型、原始格式或存储迁移。

主要文件：`lib/ui/voice_query.dart`、`lib/ui/hold_recorder.dart`、`lib/ui/search.dart`。`home.dart`透传既有麦克风接缝，`recorder.dart`/`native_recorder.dart`收口查询路由退出，`notebook.dart`仅修正临时查询取消的content通知范围。

## 验证证据

本票最终 `bash tool/check.sh` 通过：40项Python工具测试、静态分析无问题、391项Flutter测试通过。其后#23新增测试和代码属于下一段工作，不混充本票门禁。`git diff --check` 通过。

新增18项App回归以真实临时Notebook、PCM/WAV、可控麦克风/推理和原生端口验证：按住/点按成功均先校对、确认才查找；上滑/文字返回；迟到授权/识别/模型就绪；无模型/权限失败/活动录音互斥；识别失败；后台取消；320双倍字体；两条路径点按嵌套退出；退场识别竞态；原生截止和停止故障后重说；查询不入库、音频清理以及取消不触发正文变化。

独立只读审查确认的4项问题均先红后绿修复：嵌套面板后台退出、系统返回与迟到识别竞态、原生截止单次识别、失败重说前清理。另有普通点按后台识别、模型就绪迟到和临时查询误发正文变化的红绿回归。#21的刷新通知断言定位实际SnackBar，避免同文案的页内说明和浮动提示同时存在时误报；数据、位置、故障断言保持。

## Android独立Profile

```sh
python3 tool/run_isolated_validation.py --platform android --device emulator-5554 --target acceptance --case voice-query --mode profile
```

需项目Flutter/JDK/SDK环境。最终[android-profile.json](android-profile.json)，runId `29aa651f-b7d7-41da-9565-ec4a03578216`。API36 ARM64模拟器，测试身份`app.nianxia.nianxia.test`，正式安装路径前后相同。

使用实际DeviceMicrophone、平台录音接口和真实WAV校验；**只有识别文字及失败输出是受控的**，不是自然语音识别质量证明。两轮深浅均验证入口不自动采集、按住/固定位置/松手、校对改词确认查找、上滑取消与识别失败；始终只有2条合成源记录，临时WAV清理，无查询记录。新增runner安全测试验证安装前核验身份、仅授予测试包麦克风、拒绝正式APK、不清理或卸载应用。

## 实际截图

12张均来自最终通过的独立包，已核对文案、状态、固定按钮、深浅对比和布局，没有裁切或保存笔记动作。

| 状态 | 浅色 | 深色 |
| --- | --- | --- |
| 未采集 | [ready-light.png](ready-light.png) | [ready-dark.png](ready-dark.png) |
| 按住说线索 | [recording-light.png](recording-light.png) | [recording-dark.png](recording-dark.png) |
| 识别文字校对 | [review-light.png](review-light.png) | [review-dark.png](review-dark.png) |
| 改词确认后结果 | [confirmed-light.png](confirmed-light.png) | [confirmed-dark.png](confirmed-dark.png) |
| 上滑取消候选 | [cancel-light.png](cancel-light.png) | [cancel-dark.png](cancel-dark.png) |
| 识别失败与退路 | [failure-light.png](failure-light.png) | [failure-dark.png](failure-dark.png) |

## 边界

没有读取或改写正式库、音频、凭证，也不声称核对正式文件内容散列。资料仅在已核验测试身份的nonce缓存创建，结束仅删除本次合成源库，保留结果和截图。不调用云端、不下载或载入真实识别模型；输入连接为测试文字注入。

真机Magic8/iPhone17、iOS、系统真实权限弹窗、自然识别质量、TalkBack/VoiceOver尚未验收；#28组合及#15设备验收仍需如实保留这些边界。
