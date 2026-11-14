# 架构与 UI 执行验收

2026-11-14。范围：用户批准的自用/小范围试用方案，以及当前环境能独立完成的实现和验证。当前处于最终审查/主分支整合前；本文件会在完成后更新状态。目标主分支实际名为`main`，不另建或改名为`master`。

## 交付状态与默认行为

保留Flutter模块化单体、source SQLite schema2、原始WAV与备份v2，新增有界摘要分页、可恢复任务、脱敏诊断、恢复资料管理和批准的深浅UI。原生后台录音与age密码完整备份已有独立原型证据，但Gate-C/B缺iOS与真机，普通应用仍使用兼容录音及明确标注的明文备份；没有把未验收原型默认启用。

Android采用中性Material3；iOS减少动态/透明度和高对比偏好桥已编写并通过语法检查，未编译/运行。原生Liquid Glass原型环境不可用，保持实色，不以自绘模糊宣称已支持。

## 逐项证据

| 范围 | 本轮实际结果 | 证据/限制 |
| --- | --- | --- |
| 安全测试环境M0 | 独立包身份、安装前AAPT、nonce结果、正式包路径前后比较；不卸载/清库回退 | `environment.json`、受保护runner工具测试。正式数据不可run-as，本轮未读取，不能声称散列相等 |
| C1/C2/C4/C5 Android录音 | 真实PCM/WAV、实际SLEEP熄屏增长、实际120秒停止、四个强杀阶段恢复、source commit/ack、当前会话命令隔离 | [录音报告](capture/report.md)；不是安全锁屏/来电/路由真机矩阵 |
| C5实际引擎销毁 | Release同进程、不同FlutterEngine、transport确实detach、同native owner与同session继续PCM；导入/重开恰好1条 | `capture/android-engine-reconnect-release.json`；未用取消订阅或进程重启替代 |
| C3 iOS原生录音 | 未实现/未运行 | 计划要求完整Xcode验证XCTest与文件保护；本机只有CLT，保留门禁 |
| B1–B3加密 | 标准age双向互操作、恶意输入、KDF/EOF认证/取消，真实>4GiB ZIP64容器互解；Android1/64/512MiB资源、非debug release完整备份恢复链 | [备份报告](backup/report.md)；完整>4GiB手机恢复、iOS与旧内核未通过；无自创加密格式 |
| B4备份产品门禁 | 未通过整体Gate-B | 低内存/热状态/真实模型共存、全部磁盘故障与独立安全审计仍保留；普通release不打入实验age库 |
| R1搜索 | 主机100k/2500页无重复遗漏、长正文/Unicode有界；Android10001条/251页Profile与非debug Release | [分页报告](search/report.md)。UI每页≤40条摘要，排名scratch有硬预算，旧全结果API保留兼容 |
| R2诊断 | 5MiB/7天、队列256、封闭字段、未来/坏库不影响原文，AndroidProfile/Release通过 | [诊断报告](diagnostics/report.md)。导出前预览，不包含内容/查询/路径/凭证/密码 |
| R3任务与运行时 | 源提交优先、租约/修订/模型代际恢复、有限重试、同进程owner锁、close等待真实finally | [任务报告](jobs/report.md)。模型仍每次加载释放；未无证据改为常驻会话 |
| R4页面与数据管理 | 顶部查找/写文字、单底部录音；收起同session、父删除确认、恢复导出/丢弃、密码/冲突/取消/诊断预览；Profile与Release真实麦克风链路 | [UI报告](ui/report.md)。兼容正式路径未切换原型 |
| R5外观/可访问性 | 浅深、2倍字体停止可达、Android语义触控48、文本对比≥4.5、实际IME显示/收起，Profile与Release通过 | [平台报告](ui/platform-appearance.md)。TalkBack/VoiceOver自然播报与iOS玻璃实机未验收 |
| R6离线业务 | 飞行模式+Wi-Fi关闭、实际无默认网络；公开TTS语音录制边界→真实ASR→摘要/语义查找→真实回放；迟到结果不覆盖编辑、不复活删除 | `acceptance/offline-release.json`。模型摘要匹配manifest；Dart HTTP尝试0；网络设置finally恢复 |
| R6性能 | Android一万条/512D合成负载、20次关键词首屏P95、真实BGE查询、进程RSS与空间采样 | `acceptance/performance-release.json`。重复向量是规模夹具，不能当人类中文检索质量或真机P95 |
| 日历/云整理 | host受控transport验证单条确认、否定依据、并发删除/编辑及unknown不误报保存 | 双平台真实日历保存/取消/提醒未执行；真实付费云Key/预算未授权，不发真实付费请求 |

## 独立审查状态

首次fresh-context reviewer因额度中断，未给出整体结论。其搜索游标候选已由真实SQLite/widget回归复现并修复：失效后重新请求首屏，而非误报无结果，继续失效时明确要求重试。

替代的完整只读审查已完成，确认一项Important/P2：native最终journal失败后永久finalizing。已修复为冻结最终快照并可重试，任何中间写失败也释放麦克风，删除仍需先持久化tombstone。三项新增原生回归先失败后通过；原生事件传递与实际UI明确显示“保存未完成，请重试”，对应widget回归也先失败后通过。最终主机314/35、native17通过。完整结论、未判定范围及成本见 [独立审查](independent-review.md) 和 [全部裁决](decisions.md)。按计划一次修复后由回归/完整门禁验证，未再派发复审。最新Android Release复验与主分支整合尚在进行。

## 最终自动门禁

`bash tool/check.sh`：35项Python工具测试、静态分析无问题、314项Flutter测试通过。原生17项JVM回归最终通过；正常ARM64 release构建通过（51,401,181字节），AAPT确认正式包ID、非debuggable、未声明测试provider，ZIP确认不含实验age库；apksigner验证为试用Android Debug签名。未安装正式包，详见`normal-release-boundary.json`。完整iOS构建、XCTest、签名及真机未执行。标准age/Rust/Go和FFI测试详见备份报告，其结论不扩大为完整产品安全认证。

Android真实引擎重连和断网测试的中间失败包括：新增测试方法尚不存在、窗口尚未获得焦点、测试读取已消费的Scaffold inset、测试键盘注册时机。已分别保留安全门禁/修正夹具后重测，不通过削弱产品断言制造通过。并发主机门禁期间部分APK构建失败，直接构建可通过；根因未证实，最终Android构建与测试按串行完成，不能归因产品缺陷或宣称并行构建稳定。

## 实测数值的适用范围

Android API36 ARM64模拟器、非调试Release、10000条长正文/512D重复向量夹具：索引准备21,456ms，20次关键词首屏P95为336,824μs，单次真实BGE模型查询首屏67ms；50ms采样全进程RSS最高245,211,136字节，source含WAL/SHM为169,142,248字节，派生/临时为87,628,921字节，校验模型263,562,669字节。空间为测试当时含未checkpoint WAL的实际占用；相同向量不是语义质量数据，延迟不是目标手机承诺。

公开合成语音的当次ASR782ms，整个离线流程50ms采样进程RSS最高532,369,408字节。该短夹具不等于30秒自然语音P95；采样峰值也不是精确瞬时native峰值。模型仍按调用加载/释放，故不宣称常驻模型验证通过。

## 数据、依赖与公开分发边界

- 正式包不覆盖安装、不清数据；只读检查安装位置不证明正式内容散列。本轮不读取真实库、音频、API Key或密码。已有WIP按任务范围保留，未批量暂存无关截图、工具材料或配置。
- 原始schema2、备份v2、冻结v1迁移夹具保持；`pubspec.yaml`、`pubspec.lock`和模型manifest未在本轮架构/UI批次更换。实验crypto依赖单独精确固定，只用于受控目标。
- Android清单`allowBackup=false`、云备份/迁移规则排除和明文HTTP拒绝已检查；iOS路径排除API及配置不替代真实系统备份/设备转移验收。普通本地SQLite/WAV与可读导出没有应用层加密。
- 生产代码的HTTP入口是显式模型下载与用户确认的单条云整理；没有新增遥测。断网闭环证明当次没有Dart HTTP调用和可用默认网络，不是所有OEM/第三方native代码的长期网络审计。
- Android release仍为试用debug签名，未创建正式签名、未发布上架。iOS没有构建产物；两端公开分发门禁未通过。

## 接入硬件后保留的验收

Magic8/iPhone17的实际OS/音频路由、通话/撤权/系统回收、锁屏文件保护；iOS native capture与crypto接入；真实30秒ASR与万条查找P95、峰值内存/热量/电池；50条口述/30条独立人工标注查询的Top3与否定/改口；系统日历保存/取消/提醒；TalkBack/VoiceOver自然体验；iOS26原生玻璃叠层/键盘/触控/性能。上述项目按用户“暂时不方便接入”决定保留，不以模拟或编译结果代替。
