# 提交收尾与逐票证据索引

2026-11-25。用户体验认可后明确授权：整理本轮改动、提交并推送 GitHub、同步子议题实现和验证结果。此授权替代此前实施阶段的“不暂存／提交／推送”；没有授权也没有执行正式数据写入、上架或部署。

实现提交：`2a8f22d4acb84d626ee4a6987523e122801eb651`。同一笔实现包含相互依赖的交互、可靠性修复及回归，不把无法独立运行的中间切片当作可回退版本；验收文档、机器结果和截图另作一笔证据提交。

## 提交前重新执行

- `bash tool/check.sh`：50 Python、静态分析无问题、505 Flutter 通过；1 个 VM service 专用测试在默认门禁跳过。[日志](logs/publish-host-gate.log)。
- `flutter test --enable-vmservice --no-dds test/search_result_retention_test.dart`：单独 1 通过，0/48 保留。[日志](logs/publish-heap-gate.log)。
- 源码摘要仍与最新体验包清单一致；未重跑或操作模拟器。先前同源码 14 类 Android、17 项原生和深浅截图证据仍见[完整报告](README.md)，不声称本次又执行了一遍。
- 显式路径暂存；不纳入 `.superpowers` 的本地工具链缓存、`.zcode`、更早未归档的检索实验／截图。无新增生产依赖、数据迁移、实验默认能力变更。

## 子议题证据

| 子议题 | 实现范围 | 专项结果 | 代表性回归 |
| --- | --- | --- | --- |
| [#17](https://github.com/destinyTaoTao/nianxia/issues/17) | 点按录音闭环 | [专项证据](../../superpowers/plans/2026-11-16-recording-loop.md) | `capture_release_safety_test.dart / capture_page_release_test.dart` |
| [#18](https://github.com/destinyTaoTao/nianxia/issues/18) | 首页与文字记录 | [专项证据](../2026-11-16-continuous-home/README.md) | `continuous_home_test.dart / text_submission_test.dart` |
| [#19](https://github.com/destinyTaoTao/nianxia/issues/19) | 主题偏好与性能 | [专项证据](../../performance/theme-switch-2026-11-22/README.md) | `theme_preferences_test.dart / theme_performance_test.dart` |
| [#20](https://github.com/destinyTaoTao/nianxia/issues/20) | 按住录音 | [专项证据](../2026-11-16-hold-recording/README.md) | `hold_recording_test.dart / capture_limit_hint_test.dart` |
| [#21](https://github.com/destinyTaoTao/nianxia/issues/21) | 文字查找与日期 | [专项证据](../2026-11-19-explicit-search/README.md) | `explicit_search_test.dart` |
| [#22](https://github.com/destinyTaoTao/nianxia/issues/22) | 语音查找确认 | [专项证据](../2026-11-19-voice-query/README.md) | `voice_query_test.dart` |
| [#23](https://github.com/destinyTaoTao/nianxia/issues/23) | 详情、编辑与回放 | [专项证据](../2026-11-19-detail-edit/README.md) | `edit_conflict_test.dart / playback_coordination_test.dart` |
| [#24](https://github.com/destinyTaoTao/nianxia/issues/24) | 文字追加与定位 | [专项证据](../2026-11-20-text-append/README.md) | `text_append_test.dart / text_submission_test.dart` |
| [#25](https://github.com/destinyTaoTao/nianxia/issues/25) | 语音追加与恢复 | [专项证据](../2026-11-20-voice-append/README.md) | `voice_append_test.dart / capture_release_safety_test.dart` |
| [#26](https://github.com/destinyTaoTao/nianxia/issues/26) | 结果溯源与回放 | [专项证据](../2026-11-20-search-origin/README.md) | `search_origin_test.dart / playback_device_test.dart` |
| [#27](https://github.com/destinyTaoTao/nianxia/issues/27) | 按确认范围删除 | [专项证据](../2026-11-20-delete-confirmation/README.md) | `delete_scope_test.dart / delete_confirmation_test.dart` |
| [#28](https://github.com/destinyTaoTao/nianxia/issues/28) | 组合验收与独立包 | [专项证据](README.md) | `integration_test/continuous_workflow_test.dart / tool/tests` |

#18 实施时只展示已接通的点按入口，后续 #20 完成后接通按住入口；这属于计划中的后续演进。#28 原票的“不 Git 提交推送”由用户本次明确授权替代，其余边界保持。子议题的完成指其规格允许的实现和本地／隔离 Android 验收，不能等同双端真机验收。

父规格 #16 和既有平台验收 #15 保持开放；Magic8/iPhone17、iOS、自然语音集、TalkBack/VoiceOver、系统日历实际保存/提醒及长时间温升耗电未验收项仍记录于 #15。主题软件渲染结果不作为真机 60FPS 承诺；详见性能报告的基线、失败样本与对照。

APK 位于本机 `build/isolated-preview/1d8758fd-7430-4682-a1ad-c091f9f160fb/nianxia-continuous-preview.apk`，未把二进制、模型或本地工具链放入源码仓库。包体 71,615,876 bytes，SHA256 `ba0495cf693ed2c67511ecb11b7a7a20c23ab4caa1cae953e8e91d223d0c44b8`；GitHub 读者可用 `python3 tool/run_isolated_preview.py --build-only` 复建独立包，每次新 nonce 会产生新的 APK SHA；该命令需要既有 Flutter/JDK/Android SDK。
