# #27 确认范围安全删除

2026-11-20。详情更多入口区分整组数量和单次追加；单次明确保留所属及其他追加，解释系统日历事件不受影响。取消不修改资料，成功才结束自己的详情路由；失败留页重试，上层系统查找不被误关。

DeletionScope只包含ID、所属、数量和SHA-256摘要。准备确认在单个SQLite语句快照中逐行计算原始字段，不累积全组正文或读取音频；提交在同一savepoint内重算、比对并删除。增减、等数量替换、同ID/同revision原文改写均使旧确认失效。SQL失败回滚媒体队列和级联删除，继续沿现有受管媒体清理与索引失效契约；不改schema2/备份v2。

3项真实业务与6项App回归通过，覆盖确认期间新增/移除/替换、同ID更新、真实触发器故障、单次保留、音频清理、取消、导航交错及320宽2x。fresh单轮只读审查未发现证据明确的P1/P2；静态审查不替代运行验证。

Android Profile `4173456b-3690-4213-88e2-0262109f1ee1`通过，最终机器结果及14张深浅截图如下。真实SQLite、级联、受管WAV清理和查询执行；录音字节为合成夹具。截图在本次错误提示显示后采集，避免旧通知排队误作故障状态。

| 状态 | 深色 | 浅色 |
| --- | --- | --- |
| 整组范围 | [整组](group-dark.png) | [整组](group-light.png) |
| 单次追加范围 | [单次](single-dark.png) | [单次](single-light.png) |
| 单次成功保留所属 | [保留](single-deleted-dark.png) | [保留](single-deleted-light.png) |
| 旧确认失效 | [变化](scope-changed-dark.png) | [变化](scope-changed-light.png) |
| 重新确认 | [重确认](reconfirmed-dark.png) | [重确认](reconfirmed-light.png) |
| SQL失败留页 | [失败](failed-dark.png) | [失败](failed-light.png) |
| 成功后真实删除 | [成功](deleted-dark.png) | [成功](deleted-light.png) |

复现：`python3 tool/run_isolated_validation.py --platform android --device emulator-5554 --target acceptance --mode profile --case delete-confirmation`。[机器结果](android-profile.json)。完整门禁见最终组合报告。全部资料限核验后的测试包nonce目录，结束源库删除，正式资料未读写。未暂存提交推送或关闭议题。
