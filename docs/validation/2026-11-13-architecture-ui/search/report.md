# 摘要检索分页验证（2026-11-14）

新API为 `Notebook.searchPage(SearchQuery, after:, cancellation:, embedder:)`。每页最多40条摘要，标题≤120/片段≤150 Unicode标量，含日期、时区、追加来源和音频标记；不携带正文/转写/整理结果/向量。旧 `Notebook.search` 全Record签名及排序/分数字节保持。新分页明确score降序、创建时间降序、ID升序；游标时间用整数微秒，避免不同ISO精度字符串排序错误。

匹配复用现有关键词索引/扫描与语义打分，不收集全量Record再切页。private scratch SQLite只登记query随机标识、记录ID、score和时间；关键词可完整遍历，语义仍使用现有有界候选。最终页通过原始库重新投影摘要，来源变化、删除、模型切换或外部写入使游标reset；同一查询后续页不重复推理。

缓存约束：两份查询上下文/两份构建任务，64条元数据批量写入，SQLite页缓存2MiB、scratch文件上限256MiB，五分钟闲置过期。回收只处理本功能已识别版本且非当前PID、可取得独占owner锁的目录；未知版本/活动owner保留。枚举最多16个目录，异常清理不影响原始库。普通开库不进行此扫描，首次分页时才准备，正常关闭清理受管工作目录。此缓存是可丢弃数据，不进入完整备份，不增加原始schema。

| 实测 | 结果 |
| --- | --- |
| Host 10,001条长正文同分同日 | 251页、每页≤40，无重复/遗漏；Unicode预算、取消、来源/模型代际、双Notebook活动缓存保护、坏索引回退、关键词/语义与旧API同规则通过 |
| Host 100,000条全命中 | 首屏1114ms、剩余2500页中的2499页868ms、全遍历1982ms，返回100000，最大单页27108字节，scratch约15.5MB |
| Host进程RSS | 20ms采样峰值301776896字节，包含JIT及索引/夹具；不代表Flutter/model/手机 |
| Android API36 ARM64 profile/AOT | 真实10001行、251页、代际reset通过；精确时延和总进程RSS见同目录JSON。Dart HTTP被阻止，不申请麦克风，不加载模型 |
| Android release/AOT | 非debuggable独立包10001行/251页及代际reset通过，无VM service；数值结果经测试专用native provider读取 |
| 原始库完整性 | 十万条前后source SQLite SHA256相同；所有夹具由测试创建并清理，未访问正式库 |

保留不利数据：初版逐条提交scratch和OR游标条件导致首屏13275ms、全遍历23064ms，见 `host-100k-full-match-before.json`。改成每64条同一scratch事务、统一升序的负score/负时间tuple范围索引后得到上表结果；旧报告的setupMs包含整个运行，只能作总耗时，不能当作独立夹具创建耗时。初版和最终夹具source hash一致。

限制：单次主机/模拟器合成测试，不是P95，也不包含中文真实查询标注、ASR/embedding延迟、真机模型共存/热状态/VoiceOver/TalkBack。五分钟闲置或两查询缓存被替换会reset；容量/文件IO受限时明确失败并保留原始数据，不静默截断。正式UI切换在后续R4；主机性能不冒充目标手机验收。
