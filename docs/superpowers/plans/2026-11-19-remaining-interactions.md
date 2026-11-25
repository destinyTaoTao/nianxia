# 剩余连续手记交互实施计划（#22–28）

> For agentic workers: use superpowers:executing-plans inline, test-driven-development, verification-before-completion; fresh read-only review after each independently verifiable vertical slice. No commits or pushes.

**Goal:** 完成父规格剩余全部不需要用户介入的实现、测试、截图及独立体验包，明确设备不可用的验收项。
**Architecture:** 保留现有模块化单体、录音所有者、查询代次、CAS和有界存储。按纵向闭环推进，不引入新生产依赖、迁移或框架。
**Spec:** docs/superpowers/specs/2026-11-15-continuous-notebook-interaction-spec.md §3–6及Testing Decisions；GitHub #22–28各票完整验收条件。
**Tech:** 当前Flutter/Dart、SQLite、现有录音/模型/播放平台适配。

## 全局约束

保留#17–21与既有全部WIP；继续当前获授权工作区，不暂存、提交、推送、关闭议题或发布。正式库/音频/凭证不可读写。实际运行限身份核验的测试ID和nonce私有缓存；普通/受控原生录音、实验加密及玻璃默认门禁不改。schema2/备份v2兼容，日历和单条云整理确认边界保留。中性黑白灰token与已选连续手记布局沿用。平台缺失如实列为待验收，不能以模拟器替代真机。

## 顺序与完成证据

- [x] #22 语音查找：按住说线索/松手识别、点按替代、文字校对/重说/取消、只前台、模型/权限/识别失败、迟到识别与临时文件清理；真实临时库App回归+独立包截图+主机门禁。
- [x] #23 详情及编辑：正文/原音/只读转写分离、播放器互斥和进度、CAS冲突/删除/复制草稿/确认替换、脏状态/大字体；真实库和平台播放验证。
- [x] #24 文字追加：所属上下文、稳定提交身份幂等、父删除后主动独立保存、返回新ID、有界前后窗口与>40次定位、减少动态效果。
- [x] #25 语音追加：复用手势/返回定位、两条采集路径先音频后转写、失败恢复/幂等/原记录消失保护。
- [x] #26 结果溯源：有界父摘要、按需音频、正确原/追加/所属导航和返回、删除/更新期间刷新。
- [x] #27 安全删除：确认范围快照、事务提交原子校验成员/版本、确认期间增删失效、失败/取消及受管音频/检索清理。
- [x] #28 组合交互：前置证据逐项审计、完整本地流程/失败/快捷入口/日历/云边界、主题最终布局性能与有界读取回归、浅深/窄屏/2x/键盘/减少动态/辅助操作、独立体验包与可复现说明。

## #22 实施接口与步骤

消费 `CaptureController(query:true).queryText`、`CaptureSessionController.start(mode:query,reuseCurrent:false)` / `stop(expectedSessionId:)` / `finishQuery(expectedSessionId:)` 及 `Notebook.transcribeQuery` 的真实临时清理契约。不再增加采集所有者。

- [x] RED：新 `test/voice_query_test.dart` 从NianxiaApp进入语音，断言默认不自动开麦、按住/松手识别后仍未检索、用户改词确认才显示真实记录且查询不入库/临时WAV删除。另覆盖取消/重说、暂停/迟到识别、启动权限迟到、活动录音互斥、模型/权限/推理失败与320宽2x。
- [x] GREEN：扩展 `lib/ui/hold_recorder.dart` 的可选query模式和onQuery回调（旧默认行为兼容）；查询完成与保存笔记分开，查询失败只重说/转文字，查询结束/取消/生命周期离开废止迟到结果。`lib/ui/voice_query.dart` 包装原地按住、取消及等价点按，不引入侧边菜单。
- [x] GREEN：`lib/ui/search.dart` 使用查询面板，沿用结果代次/日期/校对逻辑，提供校对重说和取消；`lib/ui/home.dart` 向SearchPage透传既有可注入麦克风，默认仍DeviceMicrophone。
- [x] 验证：`flutter test test/voice_query_test.dart test/hold_recording_test.dart test/recorder_ui_test.dart test/ui_test.dart test/approved_ui_flows_test.dart test/explicit_search_test.dart` 全绿；`bash tool/check.sh` 全绿。protected runner新增voice-query安全case及独立Profile，核验真实采集入口、确认和临时资料清理；可控推理不能冒称真实模型质量。

## Review Focus

1. 录音准备期间/识别期间取消、切后台或离开后，迟到回调不能开麦、写查询或覆盖新草稿。
2. 复用按住手势不能改变现有录音落盘/上滑取消/系统中断/自动截止/互斥与查询临时清理。
3. 编辑、父删除、追加重试、删除确认范围与实际存储提交之间不能产生资料丢失、重复或复活。
4. 有界分页窗口、播放按需加载和导航返回必须在大于40条/大量追加时仍正确，不能全量读取掩盖定位问题。
5. 失败/无模型/权限/小屏/大字体/辅助操作必须保留可行退路，平台和真实模型证据不得由假端口冒充。

## 执行记录

前置：#17–21的当前实现及#21的39 Python/373 Flutter门禁、Android Profile与20张截图存在；将由最终组合验收再次核查。当前目标从#22继续，不修改远端议题状态。后续各票开始前读实际调用链再细化该票接口和回归；不从尚未读到的代码推断方法。

## #23 详情与编辑：第一段实施接口

`openEditor(context,book,record:)` 的既有公开调用兼容；编辑器持有可更新基线Record并提交其revision。正文草稿与冲突快照独立，恢复基线正文即不脏。编辑失败查询真实 `book.get(id)` 区分新版本、删除与一般故障；不能凭错误文案猜CAS结果。复制仅在主动按钮调用Clipboard。查看最新版只读、不替换；载入最新版必须确认并重新读取，删除时保留草稿。保留原音/原始转写，编辑只调用现有book.edit。

- [x] `test/edit_conflict_test.dart` 先RED：正文恢复原样直接返回且revision不变；真实CAS失败保留我的草稿并显示新版本/主动复制；确认载入新版本后以新revision保存；真实删除不复活；SQL写失败保留输入、恢复后重试；320宽2x和键盘下冲突操作可达。
- [x] `lib/ui/editor.dart` 实现以上用户操作；沿用中性token及既有公开入口。不增加版本历史、自动合并、独立保存或新存储契约。
- [x] 播放协调段开始前核对just_audio现有版本和平台接缝，收口单一播放所有者、按需加载/暂停/进度/采集前停止和路由生命周期；以真实WAV、平台替身及独立包验证，不为整库预加载音频。
- [x] 编辑、详情、日历/轻整理旧边界及全门禁通过后，独立包深浅/失败/大字体截图，fresh只读审查和有红绿证据的修复，再进入#24。


### #22 完成记录

18项新增App回归、40项Python及391项Flutter完整门禁通过，analyze无问题。Android实际麦克风Profile通过，runId `29aa651f-b7d7-41da-9565-ec4a03578216`；12张深浅截图核对完成，`docs/validation/2026-11-19-voice-query/README.md`。fresh只读审查4项均RED→GREEN，补修前台/就绪迟到/非正文通知；无遗留审查项。状态为未暂存未提交未推送。#23已开始，编辑器4项RED已复现，正在实现；播放协调和#24–28仍未完成。

### #23 播放协调决定

现有 `AudioPlayback` 每个widget各建JustAudio播放器，离开后才dispose，不能保证多路互斥或采集前停止。沿既有just_audio 0.10.6，不换依赖。新增 `lib/platform/playback_coordinator.dart`，每个Notebook一项播放所有者；App与播放widget保有生命周期引用，仅按用户请求创建输出、加载目标音频。`PlaybackOutput` 是现有平台播放器的窄接口（load/play/pause/stop/seek/dispose及playing/completed/position通知），实际实现包装JustAudio，测试只替换设备输出，不替换widget/协调/真实资料。

公共接口：`PlaybackCoordinator.retain(Notebook,{PlaybackOutput? output})` / `release()`；`toggle(Object owner,String path)` / `seek(Object owner,Duration)` / `stop({Object? owner})`；`static Future<T> startCapture<T>(Notebook,Future<T> Function() start)` 在采集前废止待播放请求并等待停止，期间拒绝新播放。播放加载按代次检查，stop不排在未完成load之后，旧load/异常/完成事件不能恢复旧播放。关闭中的输出也纳入采集屏障。

- [x] `test/playback_coordination_test.dart` 使用实际临时WAV和NianxiaApp、设备输出替身：按需加载/播放暂停/进度/EOF重播；父子详情导航停播且新音频独占；加载未完成时开始普通/原生采集须等停止，迟到load不能播放；离开/后台停播；平台失败可重试，文字无音频入口。先观察缺失行为再实现。
- [x] App持有协调生命周期；`detail.dart` AudioPlayback沿用布局但显示共享所有者状态、绑定路由/释放停止；两个采集所有者在现有启动门禁后、物理start前调用屏障。屏障只管理音频输出，不引入新采集所有者、不改录音默认门禁。
- [x] 独立包实际WAV播放、暂停和seek及采集互斥，配合编辑冲突界面深浅截图。完整门禁与fresh审查通过后才把#23标为完成。

### #23 完成记录

8项编辑、13项播放协调及2项实际SDK设备故障回归通过；完整门禁41 Python、analyze和414 Flutter通过。fresh只读审查4项均有RED→GREEN，未留确认问题。Android实际播放器/麦克风/系统IME Profile runId `51f2bdf0-df31-4e23-81e3-edee81cfed7c` 通过；24张Flutter加2张系统窗口截图已核对，见 `docs/validation/2026-11-19-detail-edit/README.md`。临时IME配置恢复，nonce源库删除；正式资料未访问，未暂存提交推送。下一步#24文字追加，#25–28继续保留完整范围。

## #24 接口与验收

保存沿用Notebook/SQLite worker，不新增schema。`TextSubmission` 是当前保存意图的内存句柄：首次提交冻结正文、时间、父ID和生成ID；同一意图共享在途Future和已成功结果。存储新增原子幂等插入，存在ID只返回既有记录，不覆盖编辑；父已不存在则失败。显式独立保存复用同一ID，不能把未知失败自动转换成独立记录。编辑输入实际变化后开始新意图；录音和旧saveText调用保持兼容。

`openEditor` 成功返回Record，追加页持续显示所属标题。父删除时保留输入，主动确认独立保存后返回其身份。详情以该ID请求有界窗口；RecordPage增加可选previous游标，详情支持aroundId/before，按原createdAt/id稳定顺序取最多40条600字摘要，可前后翻页。定位不遍历所有追加；保存后直接滚到该条，短暂中性突出，减少动态时直接定位。详情只构建这40条窗口，避免累计所有页。

- [x] 真实App RED：所属上下文、空白/取消无记录、保存重复点击、SQLite故障保留、父删除的明确独立确认、95次追加定位/前后浏览/子详情与减少动态。
- [x] Notebook意图与SQLite原子幂等；公开业务测试覆盖并发/超时观察重试、已成功后删除不复活、跨父转换和失败重试。
- [x] 有界窗口存储/worker/详情与编辑器返回身份闭环；同时间戳排序、跨页/失效/删除及摘要长度验证。
- [x] 受影响与完整门禁、独立Profile截图、fresh只读审查及必要红绿修复；不提交推送。

Ruling: 用有界替换窗口而非逐页累计追加来实现双向访问 — #24明确要求按ID定位且不能全量读取，40条窗口沿用既有投影契约 — 代价是“加载更多追加”变为当前窗口前后翻页，必须测试连续浏览没有遗漏。

### #24 完成记录

7项追加App与4项保存/窗口业务测试通过；完整42 Python、analyze、425 Flutter通过。fresh只读审查1项P2覆盖两条系统查找交错，RED→GREEN已修复。Android Profile `89b1c6d8-b0f1-4051-8c40-cf97ed06c6ed`通过，22张深浅截图核对完毕，见 `docs/validation/2026-11-20-text-append/README.md`。旧录音丢弃测试保留全部断言，等待相同完成条件并推进模拟帧，最终完整通过。未动正式资料，未暂存提交推送。下一步#25。

## #25 接口与验收

复用HoldRecorder新增parentId及可选Record身份回调，默认首页/查询行为兼容；不增采集所有者。原地语音追加面板固定显示所属标题，默认不开麦；按住/松手/取消与点按替代同源，成功Record交给#24有界定位及延迟导航。通过现有NativeCaptureScope透传可注入麦克风，默认仍DeviceMicrophone。点按普通/原生面板同时展示所属；文字回退返回实际新身份。

本地CaptureController.retry增加明确standalone参数，UI只在确认后调用；原生沿用saveStandalone。失败保留原音，普通父删除也在转换前解释。Hold失败可以原地重试/明确独立保存，恢复页面处理后按稳定会话ID查回结果；重试和迟到通知不得重复回调或插入。转写仍由既有后台任务和CAS负责，不让录音启动等模型，不更改原生默认门禁。

- [x] 两条路径App RED→GREEN：默认不开麦、按住/取消/所属/95次定位、真实音频与原文关系、保存失败重试、父删除确认独立、点按替代与权限回退、转写失败/编辑保护。
- [x] 独立包实际录音→保存→回放→所属记录深浅截图；平台与控制回执证据分开。
- [x] 主机门禁、fresh只读审查与必要红绿修复，之后继续#26–28。

### #25 当前验证记录

20项新增App回归通过，完整门禁43 Python、analyze无问题、445 Flutter通过，日志 `/tmp/nianxia-remaining/25-check.log`。fresh审查2项P2已分别RED→GREEN：丢弃确认期间截止的bool路由类型/错误返回，两条路径按身份取消自己的确认框并结束自己的录音页；原生追加收起后从首页返回的所属提示与新片段定位。新增 `confirm(onRoute:)` 可选回调只跟踪调用方自己的确认；Home以实际Record和原会话父ID延迟打开所属详情，详情新增可选focusAppendId。

窄屏反馈为IgnorePointer展示层，测试验证其真实边界在所属标题与按钮之间，不把它误作可点控件。迟到授权测试确认旧HoldMicrophone夹具重复关闭后又订阅已关闭的单订阅流；修正夹具stop幂等，保留不启动/不生成记录断言。独立voice-append Profile已启动，需先核对live进程/结果，不能仅因观测超时重启。此case使用原生已有setValidationWorkspace，把真实原生和普通音频都限制在测试包nonce `cache/validation-ui/<runId>/nianxia`，默认能力门禁不变；真实播放+采集，转写文字仅控制夹具，不冒充模型质量。完成截图与记录前#25仍未完成，#26–28仍完整待办。

### #25 完成记录

20项新增App回归、完整43 Python/analyze/445 Flutter通过。fresh审查2项P2、三条交错回归RED→GREEN，原生收起后首页恢复同时定位实际新身份。Android普通DeviceMicrophone及实际NativeCaptureBridge深浅四轮Profile `b9426dd4-1bcd-45f7-adc9-35262a91300e`通过，4段真实采集/回放及20张截图已复核，见 `docs/validation/2026-11-20-voice-append/README.md`。本次nonce工作区退出并删除，不改正式门禁/数据，不提交推送。#26–28仍待完成。

## #26 接口与验收

检索排名/游标不变，在存储worker逐条构造有界命中摘要（标题120、片段150字符），不将整页完整正文累积后再截断；所属标题经同页有界SQL关联获取。SearchHitSummary新增可选parentTitle，未知所属安全降级。音频仍只标有无，点击才get单条当前记录并把真实路径交给#23协调器。紧凑播放按钮与文字结果共存；切换查询/源变更/离开时停止旧所有者，迟到源读取不恢复播放。

原结果/追加结果调用已有openHit保留查询日期位置，所属链接传原ID打开原详情；点击时加载当前资料，删除/变更不展示旧全文，失败明确。新增App测试使用真实父子/音频/95条分页，验证所属链接、身份导航、按需单播放器、回到查询位置、删除交错与320宽2x。存储测试验证有界父摘要和每页投影、不改排名与计数。

- [x] 真实App与摘要业务RED→GREEN，原#21/23/25回归保留。
- [x] 独立Profile深浅导航、回放、返回与失败截图；完整门禁和fresh只读审查。

## #27 接口与验收

增加只在内存和worker消息中使用的DeletionScope（ID、所属、数量、SHA-256摘要），不迁移schema。准备确认时在单个SQLite语句快照中按稳定ID逐行摘要原始字段；不累积整组正文或音频。确认提交在savepoint内重新计算并比较同一范围，再沿原有受管媒体队列删除；成员增减、等数量替换或原始内容变更均使旧确认失效。原delete兼容内部调用，UI只走带scope的提交。原始字段摘要含正文和转写，能检测同ID/同revision替换；可重建索引不参与同意范围。

详情已有更多入口增加防重复提交。整组解释数量，单次追加明确保留所属记录，日历不受影响。取消不写；范围失效/SQL失败留页并要求用户重开确认；成功仅结束自己的详情路由，不能误关系统查找等上层路由。

- [x] 业务RED→GREEN：新增/移除/等数量替换、同ID版本变化、SQL触发器失败原子回滚、单次追加及音频/查找清理。
- [x] App确认/取消/失效重试/失败留页/导航交错，以及窄屏2x；独立包深浅截图及真实SQLite证据。
- [x] 完整门禁、fresh单轮只读审查及必要红绿修复。

## #28 组合验收与体验包

保持生产默认门禁和资料格式。新增受保护continuous-workflow case：公开PCM仅替换麦克风边界，普通录音/松手保存、真实本地SenseVoice/BGE、查询确认、详情、文字与语音追加、再查找和带范围删除串成同一次App流程。runner确认模拟器后断网并恢复原网络状态；Dart HTTP尝试计数必须为0。模型权重从已核验的公开夹具目录读取，不接触任何正式资料。

分别复跑主题生产调度采样（当前最终布局与#19相同协议）、现有平台/日历/单条云同意回归及原生JUnit。跨主题/320/2x/键盘/减少动态证据沿各票加组合辅助操作测试；实际TalkBack/VoiceOver自然体验仍需真机，不冒充人工验收。

交付专用手动入口与保护启动脚本：默认普通采集、nonce私有库，合成种子与自己的模型目录；测试包标识/标签在安装前核验，禁止卸载回退。独立可安装APK及SHA-256归档，区别于自动化testWidgets入口；可在独立包内反复手动体验。无法使用的Magic8/iPhone17/完整Xcode项明确关联#15，其他不需用户介入的部分连续完成。


### #26–28 最终完成记录（2026-11-22）

#26新增7项App/1项投影，后台迟到读取及真实SDK故障重试已红绿修复，18张深浅截图；#27新增3项业务/6项App，事务范围与回滚、路由身份验证通过，14张最终截图，fresh审查无确认P1/P2。#28实际飞行模式SenseVoice/BGE组合闭环通过，8张截图、HTTP尝试0，独立手动入口APK已构建核验并实际启动。48 Python、analyze无问题、462 Flutter完整门禁通过；原生17项此前通过且源码未改变。SemanticsHandle在finally按框架校验前释放，实际语义激活及播放断言保留。

主题旧超窗失败保留，分段诊断及关闭探针原协议最终都通过：真实点按P95 55.551ms，对照#19的54.736ms及原始349.014ms；软件raster慢帧仍在，不能承诺真机60FPS。600ms断言未放宽。测试侧只增加有界失败分段和可选trace，附工具参数门禁回归。

总交付见docs/validation/2026-11-22-final/README.md；APK runId 890b3f06-7bd4-4e78-937c-6a1af9ba9953，实际手动浅深窗口复核后恢复跟随系统。正式内容未读写、未暂存提交推送、远端议题不改。当前所有不需用户介入的工作完成；缺设备/Xcode和自然辅助技术/真实日历等范围保留在开放#15，不冒称双端真机验收。
