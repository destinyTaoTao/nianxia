# #21 文字查找、日期筛选与失败恢复验收

2026-11-19。在 #17–20 的既有未提交工作区继续实施，没有暂存、提交、推送、关闭议题或访问正式资料。#21 的 GitHub blocked_by 当前为空，沿已完成的 #17–20 顺序推进。

## 结果

- 查找只由页面“查找”、键盘查找动作或已确认关键词的日期应用触发；去掉250ms输入自动查找。修改输入取消旧代次，清空立即撤销结果。语音仍需校对确认，#22的手势不混入。
- 沿用连续手记的中性色值、文字层级和纵向摘要列表，提供全部、今天、最近七天、自定义。七天包含今天，筛选仍按每条记录创建时的offset和包含端点执行。日期应用沿用已确认词，不丢失尚未提交的新草稿；自定义取消不改变条件。
- 分开输入草稿、已确认请求和已显示结果的查询快照。加载或失败保留旧结果，并明确显示实际关键词、绝对日期及“尚未更新”；成功才替换。旧回包不能覆盖编辑、清空或新请求。
- 只有已知总量才显示“找到N条记录”，未加载完整时显示“已显示N条记录”。保持原相关性和有界40条摘要分页。失效游标重启时立即标旧，刷新原因不冒称资料变化。
- 第一页失败保留输入和旧结果，可直接重试；后续页失败的提示和重试位于列表尾部。游标仍有效则继续该页；已失效则从头刷新，之后仍可继续分页。无结果可改词或清除日期，错误不会冒充无结果。
- 详情返回保留输入、日期和滚动位置，不因键盘焦点自动跳回顶部。资料更新时恢复已加载窗口而非突然收缩到第一页，明确提示重新查找；草稿已修改则仅标旧，等待提交。
- 页面按钮与键盘采用相同的请求身份判断，允许在旧词日期查询加载时提交新草稿。长Unicode组合字符超过领域上限时保留草稿并提示缩短，不在页面构建阶段抛错。

生产改动仅为 `lib/ui/search.dart`，不改变schema2、备份v2、存储排序、模型、依赖或平台门禁。工具改动仅注册受保护的explicit-search用例；其余既有WIP保留。

## 验证

初次验收 `bash tool/check.sh` 通过：39项Python工具测试、`flutter analyze` 无问题、373项Flutter测试通过。受影响的查找、原UI及批准流程共50项也单独通过。

2026-11-19当前工作区复核：`bash tool/check.sh` 通过41项Python工具测试、静态分析和414项Flutter测试；这里包含工作区其他未提交改动的测试，不将增量全部归属于#21。主机门禁曾被两个既有测试文件的括号风格提示阻断，已补大括号，不改变对应测试语义。截图脚本补充按钮文字稳定颜色断言后，再次运行 `flutter analyze` 无问题，并重新通过下述Android Profile。`git diff --check` 通过。主机日志为 `/tmp/nianxia21-final-check.log`，最后一次Profile日志为 `/tmp/nianxia21-stable-profile.log`。

新增12项App级回归使用真实临时Notebook和SQLite，不替换检索业务逻辑。覆盖显式提交、清空、旧结果和错误重试、创建offset跨日、七天首尾与自定义/取消、已确认词与草稿分离、迟到推理、关键词降级、95条跨页详情返回及编辑刷新、320宽双倍字体和键盘下控件可达性、加载中替换请求、真实查询上下文淘汰、分页SQL故障恢复和长组合字符。

独立只读审查的3项P2问题已通过先红后绿的回归修复：失效游标重算状态、旧词加载时的新词提交、分页尾部错误恢复。两项较低频问题也有对应回归：游标重启与资料变化的文案区分，以及合法可见字符数但超出领域UTF-16长度的输入。没有遗留未处理的审查问题。源资料变化通知的测试等待实际异步提示出现，不依赖某一帧立即展示。

测试先在旧实现观察到自动查询失败；审查修复前观察到新词按钮被禁用、游标重算未标旧、尾部重试不可见和长字符页面异常。未降低资料、并发或错误断言。早期静态分析的括号提示已修正。Android脚本初期因布局未稳定时点按而未提交；最终脚本在点按前核对输入值、按钮可用状态并等待布局，数量和实际结果断言保留。

## Android独立Profile

```sh
python3 tool/run_isolated_validation.py --platform android --device emulator-5554 --target acceptance --mode profile --case explicit-search
```

需项目Flutter/JDK/Android SDK环境。最终 [android-profile.json](android-profile.json)，runId `0917db63-b50e-4325-a623-6e689fba7e2c`；API36 ARM64模拟器，独立ID `app.nianxia.nianxia.test`。该结果及下列20张截图已替换为当前工作区的最新通过记录。

两轮深浅主题均验证输入1秒不自动查找、页面提交、今天/七天、修改草稿保留旧结果、慢请求加载、详情返回、临时SQL故障与重试、键盘显式提交无结果、清除日期及清空。全过程3条合成源记录，没有因查找生成记录。

源库、查询、日期和SQLite故障均为实际实现。只有推理时间通过测试runtime控制，用于固定加载态；不加载模型，不授予或操作麦克风，不调用云端。该结果不证明真实模型质量、检索性能或全应用断网验收。文字注入使用测试输入连接，不宣称验证了系统真实输入法。

## 实际截图

以下20张均来自最终通过的独立包；逐张核对深浅主题、实际查询归属、旧结果标记、失败操作、无结果和详情返回界面，未见裁切或状态错配。日期选中状态另有控件断言，截图呈现对应绝对日期。

复核时发现输入后的截图可捕获按钮从禁用到启用的文字颜色过渡帧；脚本现在先等待实际继承文字颜色到达启用色，再截图。重新运行后深浅主题均呈现清晰的启用文字；未据此修改生产主题代码，也不把截图时序问题归为实际查找失败。

| 状态 | 浅色 | 深色 |
| --- | --- | --- |
| 初始页 | [idle-light.png](idle-light.png) | [idle-dark.png](idle-dark.png) |
| 输入未提交 | [typed-light.png](typed-light.png) | [typed-dark.png](typed-dark.png) |
| 查找结果 | [results-light.png](results-light.png) | [results-dark.png](results-dark.png) |
| 今天筛选 | [today-light.png](today-light.png) | [today-dark.png](today-dark.png) |
| 新草稿与旧结果 | [draft-light.png](draft-light.png) | [draft-dark.png](draft-dark.png) |
| 新查询加载中 | [loading-light.png](loading-light.png) | [loading-dark.png](loading-dark.png) |
| 记录详情 | [detail-light.png](detail-light.png) | [detail-dark.png](detail-dark.png) |
| 失败保留旧结果 | [error-light.png](error-light.png) | [error-dark.png](error-dark.png) |
| 重试成功 | [retry-light.png](retry-light.png) | [retry-dark.png](retry-dark.png) |
| 无结果与日期清除入口 | [empty-light.png](empty-light.png) | [empty-dark.png](empty-dark.png) |

## 数据边界与未验收项

受保护runner在安装前核验APK测试身份，前后核对正式包安装路径未变；不读取正式资料，不声称核对正式文件内容散列。仅在测试包nonce私有缓存创建合成源库，结束只删除本次源库，保留结果与截图。新增工具回归确认explicit-search不授予麦克风，不清理或卸载应用，并拒绝正式身份APK。

尚未验收Magic8/iPhone17真机、iOS、自然手势及TalkBack/VoiceOver。真实模型搜索质量和长时性能沿用原验证边界，本票不将测试推理向量当作模型能力证据。
