# #20 按住录音、松手保存验收

2026-11-16。本票在既有 #17–19 未提交工作区继续实施；没有暂存、提交、推送、关闭议题或访问正式资料。

## 已实现

- 连续手记底部主入口为“按住说话”，保留“点按录音”及键盘/语义激活的替代路径。顶部/列表仍为原连续手记；不出现侧边菜单。
- 按下进入准备，实际采集启动后才计时。准备期松手、系统取消、inactive或离开会废止启动；迟到授权或设备启动不得继续采集。没有最低录音时长门槛，无有效PCM不提交空记录。
- 主按钮位置固定；反馈浮在按钮上方。相对按下原点上滑64逻辑像素进入取消候选，移回40以内恢复保存，24像素滞回。移动不重启；明确取消无需第二次确认。红色仅表达录音/取消，状态同时有文字，不增加脉冲或假波形。
- 正常松手保存，提交成功才反馈“音频已保存”；系统pointer取消/生命周期打断对已采集音频走停止保存。截止或保存已受理后，迟到的上滑不能删除记录。
- 保存失败停留在可重试状态，可查看待恢复资料，不自动转文字或丢音频；明确取消失败的按钮为“重试取消”，不会偷偷改成保存。失败松手后的主按钮明确标记“录音未保存”。
- 录音期间禁用模式切换、点按、首页导航及既有键盘焦点；恢复后重新启用，原文字草稿保留。成功回列表显示音频入口与转写状态，不强制跳详情。

`lib/ui/hold_recorder.dart` 只协调指针意图：普通路径复用CaptureController；受控原生路径复用CaptureSessionController。原生启动新增默认兼容的reuseCurrent选项，按住路径拒绝冒领已有会话。没有新增生产依赖、数据迁移、录音所有者或内容遥测，原生录音/玻璃/加密门禁保持。

原生取消复用已有v1 discard标记：在发送取消前保存意图，后续截止/重连先处理该意图，不把取消通信失败转成新记录。仍检查已提交记录，不能借取消删除已保存资料。原始schema2及备份v2未改变。

## 实际验证

最终 `bash tool/check.sh` 通过：38项Python工具测试、`flutter analyze` 无问题、361项Flutter测试通过。`git diff --check` 通过。

新增20项App级回归使用真实临时Notebook、PCM/WAV和SQLite故障；覆盖固定矩形、模式锁、正常保存唯一性、上滑/滞回/移回、系统pointer取消、权限与启动迟到、inactive、无PCM、保存失败重试、两分钟采样截止、截止后的pointer取消与恢复、同批up/down、第二触点、受控原生入口稳定/旧会话拒绝、原生后台导入失败与取消通信故障、键盘绕过导航、320双倍字体和等价点按。

独立只读审查确认的一项问题及两项候选均有红绿证据后修复：

1. 自动截止已保存后失去触点，旧实现仍保持holding；现在释放完成态和首页操作。
2. 原生取消通信失败后，后来平台截止曾产生一条记录；现在所有者持有取消意图，并在导入/重连前按既有discard契约处理。
3. 已有设置键盘焦点曾能绕过IgnorePointer打开设置；现在排除焦点，并在导航入口检查hold状态。

自检另外复现并修正了旧录音所有者延迟释放期间接收同批新down、失败文案仍要求已松开的手指松手。原回归中的异步启动等待、非opaque点按面板关闭及大字体停止按钮滚动均等待真实条件；没有降低资料、故障或并发断言。早期静态检查的未使用导入/插值提示已修正，最终完整门禁为绿。

## 独立Android Profile

```sh
python3 tool/run_isolated_validation.py --platform android --device emulator-5554 --target acceptance --mode profile --case hold-recording
```

需项目Flutter/JDK/Android SDK环境。最终 [android-profile.json](android-profile.json)，runId `47e9c059-9a15-4cdb-ac74-67ea2469bb53`。

API36 ARM64模拟器，独立测试ID `app.nianxia.nianxia.test`；使用**实际DeviceMicrophone/平台录音接口**，不使用测试PCM端口，也不加载模型或调用云端。测试前由runner在核验APK身份后只授予测试包麦克风权限。

- 浅深两轮正常按住、进入取消候选、移回、松手各产生一条音频；WAV有有效数据，库内唯一记录。
- 两轮明确上滑取消不新增记录，不出现二次确认，临时draft清理。
- 临时库SQL写入故障不报成功，移除故障后重试仅新增一条。最终库为1条合成文字＋3条音频。
- 采集前后按钮矩形一致，保存后模式及点按按钮重新可用；稳定截图涵盖录音、候选取消、成功、保存失败与重试。

## 实际截图

全部为最终独立包界面，资料为合成文字与本次测试录音。截图等待控件状态稳定；已检查深浅对比、反馈没有裁切、按钮没有漂移、状态文案与成功/失败的操作可达性。

| 状态 | 浅色 | 深色 |
| --- | --- | --- |
| 待录音首页 | [home-light.png](home-light.png) | [home-dark.png](home-dark.png) |
| 正在录音 | [recording-light.png](recording-light.png) | [recording-dark.png](recording-dark.png) |
| 取消候选 | [cancel-candidate-light.png](cancel-candidate-light.png) | [cancel-candidate-dark.png](cancel-candidate-dark.png) |
| 松手保存后 | [saved-light.png](saved-light.png) | [saved-dark.png](saved-dark.png) |

另有 [保存故障](save-failed-light.png)、[重试成功](retry-saved-light.png)。

## 边界

没有覆盖安装、清理、读取或改写正式包的库、音频及凭证；正式包安装路径前后核验相同，不宣称核对了正式文件内容散列。测试只在已核验身份后的nonce私有缓存建资料，结束只删除本次合成源库；结果和截图保留。

已验证Android模拟器的平台采集与本地保存，不代表Magic8/iPhone17真机、iOS、自然手势、系统真实首授权弹窗、来电/锁屏、TalkBack/VoiceOver或自然语音识别质量已验收。这些平台边界仍需实机验证；本票没有开启实验原生录音为默认。
