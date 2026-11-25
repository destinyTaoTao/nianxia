# #24 文字追加与新内容定位验收

2026-11-20。#24实现及验证完成，保留既有WIP，未暂存、提交、推送或关闭议题，未访问正式资料。

## 结果

- 追加编辑只包含本次内容，所属标题固定在滚动区之外；空白禁存，放弃不改原记录。
- 每次保存意图冻结正文、时间、父ID和新ID。并发和观察超时后的重试共享Future；成功后继续返回同一结果，即使记录后来被删除也不重建。SQLite事务内检查既有身份和父记录；已提交身份不覆盖后续编辑。
- 父消失时保留草稿、允许主动复制；只有用户明确确认才用原提交身份保存为独立记录，不自动转换或复活父记录。
- 成功返回新记录身份，按ID取最多40条、每条最多600字的追加摘要窗口，按原createdAt/id顺序前后翻页。95次追加后新内容仍可直接看到；减少动态时直接定位，短暂中性高亮。
- 保存中系统查找覆盖页面时，保留待完成的定位或独立记录跳转；详情恢复当前路由后消费，不关闭上层查找。子详情仍可返回所属记录且无递归追加入口。

schema2、备份v2、生产依赖和录音默认门禁不变。详情采用替换当前窗口的双向浏览，不累计全量追加。

## 主机验证

`bash tool/check.sh` 通过：42项Python工具测试、静态分析无问题、425项Flutter测试。`git diff --check` 通过。日志 `/tmp/nianxia-remaining/24-final-check.log`。总量含既有WIP回归。

新增7项真实Notebook App回归及4项保存/分页业务测试：所属、空白/放弃、重复点击、SQLite失败重试、父删除与独立确认、95次追加定位及双向浏览、320宽2x与键盘、减少动态、两种系统查找交错；同一意图并发/观察超时/成功后删除、未知回执已有身份、同时间戳95条顺序和有界投影、错误所属ID、代次失效。

独立只读审查确认1项P2：系统查找覆盖时漏掉保存结果的后续定位/跳转。两条回归先失败，再经待消费身份和路由恢复处理通过。其余审查范围未发现确认缺陷。

初次门禁一项旧录音丢弃测试未在500ms内关闭；单独原样复跑通过，未确认唯一触发原因。该测试改为等待相同关闭条件、最多10秒，并推进模拟帧；保留文件删除、恢复列表和记录数量断言。最后完整门禁通过，不据单独成功声称录音没有风险。

## Android独立Profile与截图

```sh
python3 tool/run_isolated_validation.py --platform android --device emulator-5554 --target acceptance --mode profile --case text-append
```

API36 ARM64模拟器，测试ID `app.nianxia.nianxia.test`，runId `89b1c6d8-b0f1-4051-8c40-cf97ed06c6ed`。[机器结果](android-profile.json)。深浅两轮各从95次追加验证保存定位、双向窗口、子详情、真实SQLite故障重试、父删除和主动独立保存；核对原正文和实际关系。22张截图已检查，保存通知为短暂覆盖层，随后可继续翻页。

| 状态 | 深色 | 浅色 |
| --- | --- | --- |
| 原详情 | [详情](detail-before-dark.png) | [详情](detail-before-light.png) |
| 空白追加 | [空白](append-empty-dark.png) | [空白](append-empty-light.png) |
| 本次草稿 | [草稿](append-draft-dark.png) | [草稿](append-draft-light.png) |
| 新身份定位 | [定位](saved-focused-dark.png) | [定位](saved-focused-light.png) |
| 前一窗口 | [较早内容](earlier-window-dark.png) | [较早内容](earlier-window-light.png) |
| 子详情 | [详情](child-detail-dark.png) | [详情](child-detail-light.png) |
| 失败保留 | [失败](save-failed-dark.png) | [失败](save-failed-light.png) |
| 重试保存 | [重试](retry-saved-dark.png) | [重试](retry-saved-light.png) |
| 父已删除 | [保留草稿](parent-missing-dark.png) | [保留草稿](parent-missing-light.png) |
| 主动独立确认 | [确认](standalone-confirm-dark.png) | [确认](standalone-confirm-light.png) |
| 独立记录 | [详情](standalone-saved-dark.png) | [详情](standalone-saved-light.png) |

只使用测试包随机nonce私有源库；结束源库已清理，截图和结果保留。runner核验APK身份并只读正式包安装路径元数据，不授予麦克风、不清理或卸载应用；正式身份APK安全回归通过。本票文字由测试输入连接注入，不宣称自然中文输入或真实系统键盘验收。真实系统键盘证据见#23报告。

Magic8/iPhone17、iOS、自然手势与辅助技术人工体验仍待既有#15设备验收。#25–28仍需继续实现与组合验证。
