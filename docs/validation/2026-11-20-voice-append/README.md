# #25 语音追加与音频恢复验收

2026-11-20。普通与受控原生两条追加路径均已实现并验证，未暂存、提交、推送或关闭议题，正式资料未读写。

## 行为

- 语音追加面板默认不开麦，固定显示所属；按住追加、松手保存追加、上滑取消及点按替代复用现有采集所有者。先成功保存音频，再由既有任务转写，录音不等待模型。
- 普通与原生成功均交付真实Record身份，沿#24最多40条窗口定位。截止早于松手时保留手指下入口，松手后才交付一次；迟到通知不重复追加。
- 保存失败保留音频，可原地重试或查看待恢复资料。父消失时解释原因；按住与点按路径均须用户明确确认，才以同一会话身份独立保存。点按权限回退的文字保存也返回实际身份，不冒称已保存音频。
- 原生点按追加收起后可恢复同一会话，从首页录音条返回仍显示所属；保存后打开原详情并定位新片段。路由被系统查找覆盖时延迟消费结果，不误关上层页面。
- 点按丢弃确认期间自动截止保存，会取消自己的确认框并按身份结束自己的录音页，不向bool对话框交付Record；已提交音频不会再被丢弃。

没有新生产依赖或资料格式变化。真实原生验证仅在已有测试包工作区门禁内启用，不更改正式默认能力。

## 主机验证与审查

`bash tool/check.sh`：43项Python工具测试、静态分析无问题、445项Flutter测试通过；`git diff --check` 通过。日志 `/tmp/nianxia-remaining/25-check.log`，数量包含既有WIP回归。

新增20项App回归使用实际临时Notebook/WAV，只替换麦克风、原生端口和播放设备回执。两条路径覆盖默认不开麦、95次后定位、取消、320宽2x、保存故障重试、父删除的两种手势与确认、点按替代、截止和迟到通知。普通路径补授权未决松手及真实两分钟PCM上限；原始正文、实际音频与关系断言保留。转写失败后记录与回放仍存在，迟到转写编辑保护继续由#23回归覆盖。

fresh只读审查2项P2均RED→GREEN：确认期间截止向错误的bool路由返回Record；原生追加收起后所属提示丢失。新增两条截止确认及一条收起/首页恢复回归。所属恢复同时以实际身份驱动原详情定位。公共confirm仅增加可选路由回调，调用方只处理自己的确认框。

验证修正：IgnorePointer反馈层按真实布局边界检查，不要求可点击；原生点按的独立保存等待按钮实际启用后操作。旧HoldMicrophone夹具在重复关闭后又订阅已关闭的单订阅流，已诊断并使stop幂等；不启动迟到麦克风和零记录断言未削弱。清理允许保留卸载界面时已完成提交的录音，不尝试再次丢弃。

## Android实际采集与回放

```sh
python3 tool/run_isolated_validation.py --platform android --device emulator-5554 --target acceptance --mode profile --case voice-append
```

API36 ARM64模拟器、测试ID `app.nianxia.nianxia.test`，runId `b9426dd4-1bcd-45f7-adc9-35262a91300e`。[机器结果](android-profile.json)。普通DeviceMicrophone与实际NativeCaptureBridge各做深浅两轮，共保存4段真实设备WAV；每轮从45次追加开始，保存后实际定位、just_audio进度推进、打开所属记录，并验证原正文不变。

只有转写文字使用受控夹具，用来验证异步来源关系；不证明真实识别质量、音频内容或物理声学效果。单播放器/开始采集停播的真实平台故障回归和实际播放证据同时沿用#23。

20张截图已复核：

| 状态 | 普通深色 | 普通浅色 | 原生深色 | 原生浅色 |
| --- | --- | --- | --- | --- |
| 默认不开麦 | [就绪](ready-ordinary-dark.png) | [就绪](ready-ordinary-light.png) | [就绪](ready-native-dark.png) | [就绪](ready-native-light.png) |
| 按住追加 | [采集](recording-ordinary-dark.png) | [采集](recording-ordinary-light.png) | [采集](recording-native-dark.png) | [采集](recording-native-light.png) |
| 新身份定位 | [定位](focused-ordinary-dark.png) | [定位](focused-ordinary-light.png) | [定位](focused-native-dark.png) | [定位](focused-native-light.png) |
| 实际回放 | [回放](playing-ordinary-dark.png) | [回放](playing-ordinary-light.png) | [回放](playing-native-dark.png) | [回放](playing-native-light.png) |
| 所属记录 | [所属](origin-ordinary-dark.png) | [所属](origin-ordinary-light.png) | [所属](origin-native-dark.png) | [所属](origin-native-light.png) |

原生沿用setValidationWorkspace，仅接受UUID身份，将源资料限制在测试包 `cache/validation-ui/<runId>/nianxia`；普通采集使用同一临时库。结束后退出原生工作区并核对本次nonce目录已删除，结果及截图保留。runner安装前检查APK身份，仅向测试ID授麦克风权限；正式包只核对安装路径元数据，不读取资料。

Magic8/iPhone17、iOS、自然手势/中文输入与TalkBack/VoiceOver人工体验尚未验收，仍关联#15。#26–28继续推进，本报告不等同于整套规格完成。
