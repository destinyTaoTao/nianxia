# 原生录音阶段验证（2026-11-14）

当前为测试入口原型，正式录音尚未切换。Dart协议/桥、Kotlin进程owner、固定PCM16单声道16kHz WAV、monotonic两分钟/3840000字节上限、microphone FGS、持久会话凭据和可注入源库交接均已实现。

已执行：实际Android API36 ARM64模拟器前台开始→隐藏后继续→停止WAV校验；实际SLEEP熄屏后native screen unavailable且PCM继续增长，停止后WAV有效，自己的夹具清理。熄屏操控限定qemu=1、正确nonce checkpoint和当前前台测试包，finally唤醒，不改PIN/安全设置。最新源码复测仍通过。

12项JVM测试覆盖重复开始、原生deadline/样本上限、奇数字节边界、已claim不可丢弃、record ack不删音频/query ack只清临时查询、中断不自动重启、cancel清理期间重入、未知/损坏journal与有效项共存、启动失败清理期间重入，以及查询/已丢弃片段清理失败时保留凭据和tombstone以便重试。它们不证明Android系统/音频硬件行为。

真实临时SQLite/WAV测试覆盖：移动后提交前重启、提交后ack前重连、来源不一致拒绝、native活动目录不被旧恢复扫描改写、父记录删除后等待独立保存确认、未来marker保留、原有音频不被覆盖、查询不入源库/锁屏待前台、多片段中单项失败不阻止后续导入。SQLite COMMIT为保存边界，ack清理失败只保留warning。关闭页面/bridge不取消native记录owner。

独立只读审查发现三项P2，均补到RED后修复并在完整门禁中通过：不可导入片段阻塞后续、不可读journal阻塞pending、start失败异步释放时过早允许重试。没有用mock自身行为代替native所有权或SQLite事务断言。

本轮追加实际进程强杀：在测试nonce对应的录音进行中、native finalized后、source COMMIT后尚未ack三个阶段force-stop独立测试包，重启不自动开麦，有效片段恰好入库一次；查询进行中强杀后清理临时音频且零source行。每个场景都有独立JSON证据，仅删除自己的随机UUID夹具。

两分钟真实后台采集：没有Flutter stop调用，原生在elapsed=120000ms自动收尾；实际观察120536ms、有效PCM3837952字节/WAV时长119936ms，验证后清理。此结果不包含真机省电策略。

仍未执行：完整Xcode/iOS原生采集/锁屏文件保护、Magic8/iPhone17真机来电/蓝牙与有线路由/权限撤回/系统停止、engine真正销毁后的系统矩阵和20样本P95。因此Gate-C整体尚未通过；模拟器熄屏不是安全锁屏与真机通话验收，也不代表自然语音质量。硬件项按用户要求保留；debug故障编排不冒充release故障验收，CLI对未提供编排的release故障case提前拒绝。
