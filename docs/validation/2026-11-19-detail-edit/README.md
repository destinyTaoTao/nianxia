# #23 详情、回放与编辑保护验收

2026-11-19。继续既有未提交工作区，不暂存、提交、推送或关闭议题。正式资料未读取或写入。

## 结果

- 详情分别呈现当前正文、原音频、只读原始转写与追加。子详情保留所属记录返回入口，不提供递归追加；原有日历核对和单条云整理确认边界保留。
- 每个Notebook共享一个按需创建的播放输出。支持播放、暂停、进度定位和结束重播；切换详情、返回、后台或开始采集时停止旧播放，迟到加载不能恢复旧播放。
- 普通与受控原生采集均在物理开麦前等待停播回执。未确认停播的输出在路由或App销毁后仍须重试，不会被遗忘。实际just_audio停止接口会吞掉部分平台释放异常，因此先取得暂停或静音的设备回执；无法确认时阻止开麦。已确认静音后的解码器释放失败记录封闭枚举诊断，不使今后录音永久卡住。
- 编辑携带基线revision，只提交当前正文。失败保留草稿；区分真实新版本、已删除和一般存储故障。主动复制、只读查看最新版、确认后替换草稿均可用，不自动合并或复活记录。恢复原文即视为未修改，离开修改草稿仍须确认。
- 保存成功只结束自己的编辑路由。保存期间系统查找叠加时，不误关上层页面。App换Notebook时转移播放生命周期所有权。

无新生产依赖、schema或备份格式变更；原生录音等实验能力默认门禁不变。

## 主机测试与审查

`bash tool/check.sh`：41项Python工具测试、静态分析无问题、414项Flutter测试通过；`git diff --check` 通过。该数量包括既有工作区回归，不将全部用例归为本票新增。日志 `/tmp/nianxia21-final-check.log`。

新增8项编辑App测试、13项播放协调App测试及2项真实just_audio facade/MethodChannel故障测试。真实临时SQLite、WAV和用户操作保持实际业务实现，仅控制设备回执、并发时序与故障。覆盖CAS、删除不复活、SQL故障重试、复制/查看/载入、320宽2x键盘可达、原音与转写保留、迟到转写、单播放器、迟到加载、后台、普通/原生开麦屏障及关闭失败。

fresh只读审查的4项问题均有RED→GREEN回归：切换B加载失败后错误沿用A缓存身份；SDK吞掉停止错误仍开麦；保存回调误关上层查找；同一App更换Notebook后生命周期仍绑定旧输出。补充区分未确认停播与已静音后的解码器释放失败，后者诊断仅包含枚举，不含路径或正文。无遗留确认的审查项。

## Android独立Profile

```sh
python3 tool/run_isolated_validation.py --platform android --device emulator-5554 --target acceptance --case detail-edit --mode profile
```

API36 ARM64模拟器、独立ID `app.nianxia.nianxia.test`，runId `51f2bdf0-df31-4e23-81e3-edee81cfed7c`。[机器结果](android-profile.json)。本次实际使用just_audio播放器和DeviceMicrophone，不替换设备输出。8秒低音量合成WAV用于验证播放与暂停/seek；受控文字转写不代表真实模型质量。

深浅主题各验证：实际播放进度推进、暂停后定位到中间且不再推进；真实CAS冲突和查看/确认载入；双倍字体与真实系统IME正inset及收起归零；编辑后原始转写与WAV散列不变；子音频播放；损坏子音频后返回原记录仍实际播放正确文件；返回首页不自播，再经实际麦克风保存新音频。两条初始合成记录最终变为四条，新增两条来自两轮麦克风采集。结束删除本次nonce源库，结果和截图保留。

受保护runner安装前核验测试身份，正式包仅核对安装路径元数据，不检查正式文件内容。主机捕获系统窗口前核对nonce checkpoint、测试身份和前台测试Activity。临时IME配置已逐项恢复。监视脚本最初未处理文件尚未出现时的非JSON输出，已修正；随后这次运行完成并取得两个有效键盘checkpoint。最终主机日志 `/tmp/nianxia-remaining/23-profile-host.log`，runner日志 `/tmp/nianxia-remaining/23-profile.log`。

## 截图

24张Flutter截图与2张真实系统窗口已逐项核对。Flutter捕获不包含独立IME窗口；键盘遮挡以native截图和真实inset断言为准，未宣称自然中文候选输入验收。

| 状态 | 深色 | 浅色 |
| --- | --- | --- |
| 详情 | [详情](detail-dark.png) | [详情](detail-light.png) |
| 播放 | [播放](playing-dark.png) | [播放](playing-light.png) |
| 暂停与定位 | [暂停](paused-dark.png) | [暂停](paused-light.png) |
| 编辑冲突 | [冲突](conflict-dark.png) | [冲突](conflict-light.png) |
| 2x与真实键盘 | [系统窗口](native-editor-keyboard-dark.png) | [系统窗口](native-editor-keyboard-light.png) |
| 查看最新版 | [最新](latest-dark.png) | [最新](latest-light.png) |
| 确认替换 | [确认](replace-dark.png) | [确认](replace-light.png) |
| 编辑后原始转写保留 | [原始转写](edited-original-dark.png) | [原始转写](edited-original-light.png) |
| 子音频 | [子音频](child-playing-dark.png) | [子音频](child-playing-light.png) |
| 损坏文件 | [错误](damaged-child-dark.png) | [错误](damaged-child-light.png) |
| 返回原音恢复 | [恢复](parent-recovered-dark.png) | [恢复](parent-recovered-light.png) |
| 采集保存 | [保存](microphone-saved-dark.png) | [保存](microphone-saved-light.png) |

## 未验收边界

Magic8/iPhone17真机、完整iOS/Xcode、自然输入、TalkBack/VoiceOver和真实模型质量仍未验收，关联既有#15；模拟器声音与设备回执不能证明所有硬件路由的物理声学效果。#24–28仍须继续实现和组合验收，本报告不代表父规格全部完成。
