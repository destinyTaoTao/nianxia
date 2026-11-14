# 有界本地诊断验证（2026-11-14）

诊断是可丢弃的有限元数据，不是正文历史或永久审计。事件字段封闭为事件/阶段/结果/安全错误枚举、随机trace、耗时、尝试数、source revision和软件/模型代际；不接收任意Exception/Map/正文/查询/路径/Key。异常只按类型归类，原始message/details不写入。软件代际取Flutter build number，模型代际0表示当前未知，后续运行时提供真实代际。

当前实现用独立version1 SQLite作行轮转和回收，不改原始schema。待写队列256条，批次32条；native IO在独立且串行的worker操作，业务只入队。active数据库硬页数上限5MiB，按设备UTC时钟保留至多7天；时间回拨时保守移除未来条目，导出预览范围按min/max计算。诊断IO/未知版本/源库打不开，不得改变已经保存的业务结果。

导出仅在用户动作后产生，包含严格再解析的封闭字段及丢弃计数。来源不明/额外字段/未来版本不复制。未知未来数据库只读识别、原文件保留；本版本导出副本最多5份/7天，失败partial清理。preview/export合并重复请求，关闭等待已接受的诊断操作；不自动上传。

已通过：

- 9项主机诊断测试：secret/path哨兵不入导出、真实SQLite未知payload字段过滤、future数据库hash保持、写入故障不影响保存或备份、源库开失败仍有安全startup事件、2KiB物理文件预算、size/age/clock rollback、queue压力和导出副本/关闭。
- 完整主机门禁：31 Python、267 Flutter、analyzer clean；原有备份和session生命周期测试保留。
- Android API36 ARM64的profile及非debuggable release/AOT实际测试：8192byte预算内写入/轮转、2000次记录压力下queue≤256并有丢弃计数、导出无正文/查询/Key/password/path哨兵、future-v2数据库原hash不变、诊断不可写时源库仍保存。JSON包含实际物理体积和条目数。

这验证了隔离存储与失败边界，不证明真实设备全部性能/隐私验收。诊断关闭和故障不能替代业务事务检查；未来/损坏诊断可能不可用，原始记录仍独立。UI预览/导出入口在R4接入；没有向云端或第三方发送诊断。默认诊断文件排除于现有完整备份，导出本身只含上述安全元数据。
