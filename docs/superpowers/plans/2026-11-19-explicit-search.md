# #21 文字查找、日期筛选与恢复实施计划

> For agentic workers: Use superpowers:executing-plans inline; test first, then fresh read-only review.

**Goal:** 显式提交查找、日期快捷筛选、准确区分当前/旧/加载/失败/无结果，并保持详情返回上下文。
**Architecture:** 沿用SearchPage、真实Notebook.searchPage、SearchCancellation和有界摘要。分开输入草稿、已确认请求、已显示结果的查询快照；只在查找/键盘提交/已确认查询的日期应用时请求，不重写存储或相关性排序。
**Spec:** docs/superpowers/specs/2026-11-15-continuous-notebook-interaction-spec.md §4；GitHub #21无依赖，#17–20 WIP保留。
**Tech:** 当前Flutter/Dart，无新增依赖、迁移或数据格式变化。

## 约束与设计

- 当前工作区继续，不暂存、提交、推送或操作正式资料；隔离验证用固定测试ID和nonce目录。
- 沿用中性theme token、系统中文字体、17正文/14辅助。查找输入与页面提交、日期ChoiceChip、结果上下文与原文摘要纵向排列，无聊天/文件夹等新入口。
- 去掉250ms防抖自动查找。输入变更撤销当前代次与分页，旧结果明确“尚未更新”；清空立即清空结果，不发送空查询。
- 日期全部/今天/最近七天/自定义。以book.clock的当地日历日为基准，七天含今天；创建offset与端点包含仍交存储。日期应用沿用已确认词，不丢尚未提交的新输入；结果上下文始终显示实际词与绝对日期。没有已确认词、或语音校对期间，日期选择本身不触发查询。
- 新查询加载/失败保留旧结果并标明实际所属查询与日期；成功才替换。分页只用已确认快照，错误可重试；已知总量才用精确总数，不改变关键词/语义排序。
- 源资料变化时，已确认且与当前输入一致的查询重新刷新并说明；输入草稿已修改时仅标记旧结果失效，等待提交。详情未改数据的返回保留原输入、日期及像素位置。
- #22语音手势不混入；保留现有语音文字校对后确认，以及模型不可用的关键词路径。

## Review Focus

1. 编辑/清空期间的迟到推理或分页回包不能覆盖当前输入/结果。
2. 草稿不同于已确认词时应用日期，不能偷偷查新词或丢草稿/误标结果。
3. 内容变化、游标重启和错误时不能把旧结果或当前页数冒充新结果/总数。
4. 详情返回、追加命中、跨页位置、320双倍字体与键盘的操作可达性。
5. 今天/七天/自定义包含端点与创建offset，模型就绪失败和推理降级。

### Task 1: 显式请求与可追溯结果

- [x] 新test/explicit_search_test.dart真实临时Notebook App测试，先观察输入不应自动发起但旧实现自动发起的失败；补延迟InferenceRuntime与真实SQLite故障。
- [x] 改lib/ui/search.dart，分离draft/confirmed/results快照和代次，保留旧结果、准确状态、重试、source变更及详情返回；不新增业务mock架构。
- [x] 模型降级、迟到推理、清空、错误保留输入/旧结果、分页/无结果测试通过；旧自动查询断言改成用户主动提交，原数据断言保留。

### Task 2: 日期快捷项与实际界面

- [x] 补今天/七天/自定义端点/offset、草稿与确认词分离、大字体与键盘失败回归后实现，沿用现有DateRangePicker。
- [x] protected runner新增explicit-search case和安全测试，独立Profile实际查找/日期/失败重试/详情返回、浅深截图；不授予麦克风、不加载模型。

### Task 3: 验证与审查

- [x] bash tool/check.sh完整门禁；fresh独立只读审查、确认问题红绿修复与必要复测，最终diff检查。
- [x] docs/validation/2026-11-19-explicit-search记录实测与未验收边界；保持未提交状态。


## 完成证据

- Task 1：旧实现自动提交的RED见 `/tmp/nianxia21-red.log`；最终12项真实Notebook查找回归通过。无提交，保留用户既有WIP。
- Task 2：日期和小屏用例通过；新增runner安全测试通过。最终Android Profile runId `90009257-d852-4711-aa5b-a3f4917a2c47` 通过，20张深浅截图已核对，详情见 `docs/validation/2026-11-19-explicit-search/README.md`。
- Task 3：fresh只读审查完成，3项P2以及长组合字符和刷新文案均有RED→GREEN验证；最终 `bash tool/check.sh`：39 Python + analyze无问题 + 373 Flutter通过。最终diff检查通过。
- 审查判断：长组合字符虽低频，但可使页面构建失败，按稳定性问题修复；刷新文案与失效游标状态一起修正，避免把缓存上下文淘汰冒称资料变化。无遗留审查项；无新依赖或数据契约变更。
- 验证时序修正：详情更新提示等待实际呈现；Android在输入及按钮布局稳定后点按，保留原结果和数据断言。不把这些脚本失败归因为正式数据或存储缺陷。
- 当前工作区复核：41项Python、静态分析、414项Flutter测试通过；新增按钮文字启用色稳定断言后的Android Profile runId `0917db63-b50e-4325-a623-6e689fba7e2c` 通过，20张截图与结果JSON已更新。3条合成源记录保持3条，测试nonce源库已清理；正式资料未读取或写入，未提交、推送或关闭议题。
