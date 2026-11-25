# #18 连续手记首页与文字记录验收

2026-11-16。实施范围为首页与文字记录；延续 #17 未提交的录音修复。本轮未提交、推送或修改议题状态。

## 实现

- 首页采用日期分组、左侧时间列和原文摘要；大字体时将时间移到正文上方。保留原时间排序和记录创建 offset，跨页只接续相邻同日，不为分组全量读库。
- 保留全部／收藏及被收藏的追加记录；正文区域滚动，底部说话／写文字入口固定。主题 token 收敛为选定的中性浅深色。
- 首页内嵌文字编辑，空白禁存，明确点击保存；写入失败保留输入和可重试状态，成功后显示新记录并回到全部列表顶部。模式切换保留草稿；返回及离开仍保护未保存内容。
- 文字草稿遇快捷录音不会被清空；录音控制条显示期间，隐藏文字区不能持有焦点。独立审查发现该问题，回归先复现后修复。
- 录音本票仍使用可工作的点按“记一下”；按住手势属于 #20。既有首页主题切换入口与偏好行为暂保留，#19 再处理入口、默认值及切换性能。

## 已执行

`bash tool/check.sh`：36 项 Python 工具测试、静态检查、332 项 Flutter 测试通过。新增首页 App 测试使用真实临时 Notebook 与可控录音端口，覆盖空白、写入故障及重试、95 条分页、创建 offset、详情返回位置、320 逻辑像素双倍字体与键盘、录音收起的草稿及焦点。

受影响 UI 测试的旧“顶部写文字”断言改为底部记录区；滚动测试明确选择记录列表，异步保存测试等待实际列表条目，不把编辑框里的相同文字视为保存成功。

曾有一次完整检查的旧胶囊测试未等到“音频已保存”，单独 4 项及最终完整复跑均通过；未确定该次失败的唯一原因，未改动或削弱其断言。

Android API36 ARM64 模拟器独立 Profile 验证通过：

```sh
python3 tool/run_isolated_validation.py --platform android --device emulator-5554 --target acceptance --mode profile --case continuous-home
```

需使用项目 Flutter/JDK/Android SDK 环境，并将模拟器输入法置于标准底部键盘模式。该 case 不申请麦克风权限，也不加载模型。运行身份、随机标识及结果由受保护 runner 检查；结果见 [android-profile.json](android-profile.json)，最终 runId 为 `648680d5-7867-44f5-b7ef-3f9499e02693`。

真实 IME 显示与收起通过实际 FlutterView inset 从 0 变正再回 0 验证，正常字号保存按钮位置断言在键盘上方；大字体界面检查与实际窗口截图共同核对。合成文本注入使用测试键盘，注入前重建输入连接；不宣称自然中文候选输入已验收。

初期 IME 显示浮动工具栏但 inset 为 0，该轮明确失败，未以伪造 inset 通过。实际窗口确认侧边工具条来自输入法；改用标准底部键盘后通过。测试期间临时修改的 `show_ime_with_hard_keyboard` 与 `stylus_handwriting_enabled` 系统配置均已恢复。输入法呈现模式在模拟器中选为标准键盘。

## 实际截图

以下均来自运行中的独立测试包，只有合成记录。已对照选定“连续手记”视觉稿，检查层级、日期、时间列、深浅色、底部控件及键盘遮挡。

| 状态 | 截图 |
| --- | --- |
| 浅色首页 | [home-light.png](home-light.png) |
| 深色首页 | [home-dark.png](home-dark.png) |
| 文字保存后新记录 | [text-saved.png](text-saved.png) |
| 双倍字体首页 | [home-large-text.png](home-large-text.png) |
| 普通文字区与真实系统键盘 | [native-text-real-keyboard.png](native-text-real-keyboard.png) |
| 双倍字体文字区与真实系统键盘 | [native-text-large-keyboard.png](native-text-large-keyboard.png) |

另保留 [普通文字区 Flutter 截图](text-real-keyboard.png)和[大字体文字区 Flutter 截图](text-large-keyboard.png)。Flutter 捕获不包含系统 IME 独立窗口，可能有暂态画面差异，判断实际遮挡以 `native-` 开头的完整系统截图为准；系统截图在对应 checkpoint 后等待稳定再采集。

## 隔离与未验收范围

安装前核验包 ID 为 `app.nianxia.nianxia.test`；正式应用安装路径前后相同。未读取正式库、音频或凭证，不能据此声称已核对正式数据内容散列。测试仅创建随机 nonce 私有缓存目录，结束时只删除该目录内的合成源库，截图与验证结果保留。

未进行 iOS、Magic8／iPhone17 真机、自然中文输入、真实转写或新录音手势验收；不将 Android 模拟器结果扩大为双端验收。主题切换掉帧未在本票诊断或宣称修复。
