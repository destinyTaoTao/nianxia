# age 备份隔离原型

本目录不被正式应用构造器引用。格式为 age passphrase，payload 为现有完整 ZIP64；没有自定义密码协议。默认写入与读取上限均为 logN18，头部最多64KiB。16/17只用于资源比较。`dependencies.json` 和两份 lockfile 固定实际源码及许可信息；Rust age 0.12.1 上游标记 beta/experimental，此绑定没有安全审计。

需要 Rust1.91.1、Go1.26.1、Android NDK28.2.13676358/API24 ARM64；构建脚本也支持本轮仓库忽略目录中的隔离 Rust 工具链。不修改全局工具或 pubspec。Go参考程序需在 reference/ 运行 `go build`，可执行文件输出为 `.superpowers/sdd/2026-11-13-encrypted-backup/age-reference`。模块下载与缓存可以由 GOMODCACHE/GOCACHE 指定隔离目录。

```sh
python3 tool/spikes/backup_crypto/build_native.py --platform host
cargo test --locked --release --manifest-path tool/spikes/backup_crypto/native/Cargo.toml
NIANXIA_AGE_LIBRARY="$PWD/tool/spikes/backup_crypto/native/target/release/libnianxia_age_spike.dylib" flutter test tool/spikes/backup_crypto/test/age_cipher_test.dart
python3 tool/spikes/backup_crypto/run.py --phase host-contract --fixture-bytes 1048576
python3 tool/spikes/backup_crypto/build_native.py --platform android
python3 tool/run_isolated_validation.py --platform android --device emulator-5554 --target backup --mode profile --case cipher-resources
python3 tool/run_isolated_validation.py --platform android --device emulator-5554 --target backup --mode release --case backup-matrix
```

主机动态库示例适用于 macOS。本轮真实执行结果见 `docs/validation/2026-11-13-architecture-ui/backup/`。大文件命令 `run.py --phase large-container --minimum-bytes 4294967297` 写读实际字节并校验有效 STORE ZIP64，需至少四倍载荷及1GiB余量。它验证密码容器，不能证明完整大库恢复通过。

C ABI 在 `native/include/nianxia_age.h`。参数在create时复制，run在独立worker，cancel只请求取消；KDF进行中不能抢占，调用方必须等待run返回再free/清理。文件转换最多64KiB应用缓冲，KDF18自身约需256MiB，进程总RSS还包含Flutter等。错误密码/损坏统一认证失败；EOF和final验证完毕前仅有私有partial。输出原子发布且不覆盖已有文件：Android使用renameat2(RENAME_NOREPLACE)，主机使用同目录硬链接。旧Android内核需另验，不支持则失败，不回退覆盖。

Android动态库只在 `integration_test/backup_crypto_test.dart` 目标打包。隔离release维持非debuggable/AOT，通过只在隔离release清单声明的provider输出受UUID和字段白名单约束的数值结果；它不提供任意文件读取。runner始终先核验APK包名。正式包不包含该库或provider声明，正式设置页不切换默认。

生产候选提案尚未通过：需完整Xcode/iOS与双真机、低内存/模型共存/温度、所有取消阶段、权限/系统保护和完整大库恢复证据，再决定原生绑定生产接入。不能把标准互解、模拟器性能或上游审计替代这些证据。
