# 加密备份阶段验证（2026-11-14）

已执行的是隔离原型与可注入业务编排，正式入口仍保持当前行为。依赖、源码hash、许可和上游beta状态见 `tool/spikes/backup_crypto/dependencies.json`。

| 验证 | 结果与实际范围 |
| --- | --- |
| 主机标准互解 | Go age1.3.2 与 Rust age0.12.1，1MiB合成载荷、5类Unicode/空白密码双向互解；10类错误/损坏/超限输入拒绝，共20项通过 |
| KDF/最终认证 | 原生crypto单测5项；真实Dart FFI3项；超限头在构造标准identity/KDF前拒绝，末块缺失/尾随均不发布明文 |
| 大容器 | 实际4294967537字节有效STORE ZIP64，两方向全量互解及SHA256一致，ZIP CRC全读通过；不是完整大库恢复验收 |
| Android profile/AOT | API36 ARM64模拟器，1/64/512MiB×logN16/17/18全量往返hash一致；详见JSON |
| logN18资源 | 20ms采样总进程RSS最高491032576字节（约468MiB），主计时器最大间隙23ms，取消join406ms；不是精确瞬时native/KDF峰值或真机性能 |
| Android release/AOT | 非debuggable隔离包：源库→ZIP→age→完整认证→恢复，3条记录和32044字节有效WAV，追加关系和音频hash一致，重复恢复skipped=3，损坏认证失败时目标库不变 |
| 业务失败/取消 | 受控cipher配合真实SQLite：认证失败无恢复/明文回退、magic识别且需密码异常保留、取消等worker退出后才清理、COMMIT后迟到取消成功；旧v1/v2测试保留 |
| 可读导出 | 独立正文/原始转写/日期/追加来源/引用音频ZIP，无恢复manifest、缓存、模型或凭证，明确未加密且不用于完整恢复 |

实际遇到并修复：Dart isolate闭包夹带DynamicLibrary；Android私有数据硬链接被拒绝；清理password buffer缺少fill值；Flutter将debuggable release按debug产物处理。错误产物被身份门禁拒绝，未安装正式包。最终release使用原生数值结果通道；路径采用与系统桥一致的canonical缓存根。

尚未通过：iOS构建/嵌入和系统文件保护回读、Magic8/iPhone17真机、API24最旧内核、模型共存/低内存/热状态、移动端>4GiB完整库恢复、全部强杀与磁盘故障矩阵、独立安全审计、具体生产依赖接入批准。因此Gate-B整体仍未通过，不改变正式设置默认，也不承诺所有设备均可承受logN18。

正式安装路径每次测试前后比较未变化。正式应用不可run-as，没有读取正式库或计算其指纹；保护依据是构建身份、安装前验证与命名空间隔离，不能宣称已校验正式数据hash。
