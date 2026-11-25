# #20 按住录音实施计划

> For agentic workers: Use superpowers:executing-plans inline; fresh read-only review after implementation.

**Goal:** 连续手记首页按下准备、真正启动后计时、松手保存、上滑取消并可移回，提交后只出现一条可回放记录。
**Architecture:** 在现有 HomeComposer 中新增集中处理指针意图的 HoldRecorder；普通路径委托 CaptureController，受控路径委托既有 CaptureSessionController，不管理WAV/SQL，不增加第二采集所有者。保留点按录音面板与快捷入口。
**Tech Stack:** 当前锁定 Flutter/Dart，无新增依赖或迁移。
**Spec:** docs/superpowers/specs/2026-11-15-continuous-notebook-interaction-spec.md §2–3；GitHub #20。设计已由用户选择并授权实施，沿用当前工作区 #17–19 WIP，不重新设计或请求审批。

## 约束与布局

- 不提交/暂存/推送，不动正式包数据；隔离runner校验测试ID，nonce临时资料。
- token沿用现有黑白灰、17正文/14辅助/系统中文字体；红色只表达录音/取消，文案同时表达状态，减少动态不增加脉冲动画。
- 底部主按钮改“按住说话”，下方“点按录音”。反馈浮在主按钮上方，不改变按下的按钮矩形；失败后的操作可在松手后展开。模式/点按/主页面导航在手势期间不可再次启动会话，文字草稿保持。
- 单指所有权，忽略第二触点。相对按下原点上滑64逻辑像素进入取消，移回40以内退出，24像素滞回；系统pointer cancel与生命周期inactive触发保护性停止，而非明确丢弃。无最低时长。
- preparing松手立即废止，等待迟到工作收尾；权限inactive使意图失效，首次授权后需再主动按。actual recording才显示时间。
- 两分钟/系统结束先发生时锁定保存决定，迟到手势不能转为删除。native当前会话不可被新的按住意图冒领。

## Review Focus

1. native通知使父组件换成收起条，不能移走手指下的入口。
2. 启动迟到/首次权限导致inactive/页面销毁后不能继续采集。
3. 截止先发生后上滑松手不能丢弃或重复创建。
4. 失败重试、取消失败必须留可解释且可恢复路径；不能因为换输入模式丢失音频。
5. 320双倍字体、键盘、辅助激活与多指输入，按钮不漂移。

### Task 1: App级手势回归与接入

- [x] 写 test/hold_recording_test.dart，使用真实临时Notebook、现有MicrophoneInput接缝、可控PCM与SQLite故障，先运行看到主入口缺失失败。
- [x] 实现 lib/ui/hold_recorder.dart 与 HomeComposer/HomePage/App 参数接入；Native start 增加默认兼容的 reuseCurrent 参数，hold拒绝冒领旧会话；测试先覆盖此拒绝。
- [x] 验证down/move/up普通保存、上滑明确取消、移回、启动/授权迟到、system cancel/生命周期、无PCM、保存失败重试、截止先受理、多指和固定矩形；保留点按与草稿原断言。

### Task 2: 独立包交互与截图

- [x] 增加 integration_test/hold_recording_test.dart 与 protected runner case（核验ID后才授予测试包麦克风），工具安全测试先红后绿。
- [x] 独立Profile包跑真实指针与临时音频：正常、明确取消、写入故障/重试；浅深录音/取消候选/成功状态截图并检查。未实测自然语音与iOS不宣称已验收。

### Task 3: 完整验证与独立审查

- [x] 更新仅因授权入口变化受影响的旧UI断言，不削弱音频、故障或并发保护。
- [x] bash tool/check.sh与独立只读review，修复确认问题后复测；git diff --check/最终范围审查。报告截图与剩余平台边界，无提交推送。

## 完成记录

- Task 1 complete：主入口缺失先红，随后完成真实临时音频的手势闭环；20项App回归及旧入口迁移保留全部资料断言。复用既有v1原生discard标记保护取消失败后的终态意图，无schema变更。
- Task 2 complete：安全runner case先因拒绝未知case失败，再核验ID/先安装后授予测试麦克风通过；最终Profile run 47e9c059-9a15-4cdb-ac74-67ea2469bb53 实际DeviceMicrophone路径正常2、取消2、故障重试1，10张最终截图已核对。
- Task 3 complete：独立review_hold20列出done后丢触点、取消失败后截止、已有键盘焦点绕过导航，均先复现失败再修正；同批up/down释放和失败文案亦红绿。最终38项Python、静态检查、361项Flutter及设备Profile通过，git diff --check通过。没有未处理的评审Minor。
- 保留当前工作区及先前WIP，未提交/推送/暂存或修改议题状态。验收材料：docs/validation/2026-11-16-hold-recording/README.md。
