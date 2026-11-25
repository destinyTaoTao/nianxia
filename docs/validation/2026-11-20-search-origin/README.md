# #26 查找结果溯源与按需回放

2026-11-20。结果保留原日期、追加标识，新增有界所属标题及直接回放。所属链接打开原记录，命中标题打开该次内容，返回恢复查询、日期与像素位置。文字没有音频按钮。

存储worker按单条源资料生成120字标题、150字片段，父标题经同页SQL限制120字；整页不累积完整Record/正文，不携带音频文件名。排名、计数及游标协议不变。播放只在点击后读取一条当前记录；复用#23协调器，查询更新/源变化/离开/后台废止旧播放请求，开始采集仍经过停播屏障。

新增7项真实临时库App回归和1项投影业务回归：95条分页及返回位置、父/子/所属身份、两音频互斥、暂停与清空、删除竞态、320宽2x、后台迟到读取及设备错误单击重试；既有分页10001行及SDK故障回归保留。首次测试的惰性列表目标需要先滚动构建，未放宽计数或数据断言。

fresh只读审查确认1项P2：异步get期间切后台可能重新播放，RED→GREEN已修复。真实平台截图又发现故障后仍显示暂停，新增RED→GREEN并让重试强制重新加载；音频文件恢复后单击实测恢复播放。受影响22项播放/查找回归通过，完整门禁见最终组合报告。

Android Profile `80e3bc8d-fe0a-48b7-8f50-9047418f8fbc`通过，[机器结果](android-profile.json)。实际just_audio播放合成10秒WAV；转写文字受控，不代表识别质量。18张最终截图含深浅结果、播放、暂停、所属、返回、追加详情、文件不可用、恢复和删除刷新。结果截图等待界面稳定，避免将启用动画中间帧当完成态。

| 状态 | 深色 | 浅色 |
| --- | --- | --- |
| 结果/所属摘要 | [结果](results-dark.png) | [结果](results-light.png) |
| 实际回放 | [播放](playing-dark.png) | [播放](playing-light.png) |
| 暂停 | [暂停](paused-dark.png) | [暂停](paused-light.png) |
| 所属原记录 | [所属](parent-dark.png) | [所属](parent-light.png) |
| 返回原查询 | [返回](returned-dark.png) | [返回](returned-light.png) |
| 命中追加详情 | [追加](append-dark.png) | [追加](append-light.png) |
| 音频不可用 | [故障](unavailable-dark.png) | [故障](unavailable-light.png) |
| 文件恢复后重试 | [恢复](recovered-dark.png) | [恢复](recovered-light.png) |
| 删除后真实刷新 | [删除](deleted-dark.png) | [删除](deleted-light.png) |

复现：`python3 tool/run_isolated_validation.py --platform android --device emulator-5554 --target acceptance --mode profile --case search-origin`。仅核验后的测试ID与nonce缓存，结束删除本次源库，结果/截图保留；正式内容未读写，未暂存提交推送。
