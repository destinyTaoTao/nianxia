# #19 主题切换采样与诊断

2026-11-16。结果只代表本次 Android 模拟器，未声明真机掉帧已经解决。

## 条件与口径

- 同一 `emulator-5554`，Android API36 ARM64，1080×2400，60.000004Hz；Flutter 3.47.9 / Dart 3.13.7，Android **Profile** 包，Impeller OpenGLES。SurfaceFlinger 实际报告 ANGLE / SwiftShader 软件渲染。
- 每轮独立进程、随机 nonce 私有缓存，100 条合成记录、无模型任务；固定先保存深色。首页打开真实设置，交替选择浅／深各30次。首轮为进程内首次切换，稳定样本为余下29次，不等同于应用冷启动。
- 每次输入前确保选择控件可见并稳定。旧版选项菜单打开后，以点选具体选项为起点；新版以内联单选项点按为起点。故这是“选择主题后”的响应，不包含打开旧菜单的耗时。
- `brightnessUs` / `canvasUs`：输入至框架 post-frame 读取根 `ThemeData` 的亮度／背景 token 达到目标。**不是物理屏幕呈现时间，也不是所有控件动画完成时间**。600ms 内未观察到目标即失败。正文实际颜色另外由首帧 widget 回归断言验证。
- 以相同 Timeline 单调时钟，采集输入后600ms内 buildStart 的全部 `FrameTiming`，报告 build/raster P95。超预算指 build 或 raster 任一超过1000/Hz ms；这是窗口中已产生帧的比例，不是物理丢帧率，`totalSpan` 也不能用来推算FPS。
- 使用普通 `WidgetsFlutterBinding` 的生产调度，`LiveWidgetController` 注入真实控件点击；settle/pump 均在窗口外。两轮600ms静止对照均为0帧。采样期间未并行运行主机重型测试。
- P95 取排序后的 nearest-rank，即 ceil(0.95×N)。帧统计合并对应组内所有样本，完整数值见 JSON；[summarize.py](summarize.py) 可复算。

## 有效结果

稳定29次：

| 阶段 | 根背景 token 响应 P95 | build P95 | raster P95 | 超预算帧／全部帧 |
| --- | ---: | ---: | ---: | ---: |
| 修改前：整页180ms＋下拉选择 | 349.014ms | 12.582ms | 85.261ms | 213/278，76.62% |
| 整页立即切换＋内联选择 | 137.829ms | 5.912ms | 86.264ms | 231/300，77.00% |
| 最终：同时取消面板正文渐变 | 54.736ms | 4.996ms | 85.545ms | 225/298，75.50% |

进程内首次切换：修改前268.787ms、最终20.117ms；build为22.943→12.484ms，raster为89.200→112.941ms，超预算9/10→5/9。单次结果不作稳定性能结论。

- [有效基线](baseline-production.json)，runId `843a2b89-3dd0-4495-84aa-578c4313ed05`；[汇总](baseline-production-summary.json)。
- [中间方案](root-only-radio.json)，runId `e77c7bca-968b-4640-95e6-b6ca4893b502`；[汇总](root-only-radio-summary.json)。
- [最终方案](optimized-production.json)，runId `bbb8a282-9f80-4db3-9ba1-34c75f678094`；[汇总](optimized-production-summary.json)。

结论：本轮根背景响应和UI构建开销下降；raster P95基本不变，不能宣布60FPS或掉帧根因已全部消除。三个阶段含控件布局变化，且没有A/B/A重复，数字有运行间噪声；不能把中间到最终的全部差值只归给两行代码。

## 假设与证据

1. **整页插值叠加组件正文插值延后稳定颜色。** 原180ms根主题在保存成功首帧仍是旧色，取消后根背景立即到目标；但 `PaperSurface` 的 `Material` 默认还以200ms改变继承正文。回归实测背景已白，正文仍 `0xfff2f2f2`，期望 `0xff181818`。将该面板 Material 的动画时长设为0后断言通过，Ink 点击反馈仍保留。
2. **下拉弹层关闭与主题更新可能叠加。** 设置改为内联三选一，避免额外弹层。另有直接调用真实选择回调的30次控制，但它不包含手势／Ink，不与真实输入延迟混算。基线回调控制稳定canvas P95为325.064ms，最终45.659ms；不能独立量化菜单开销。
3. **SQLite 写入或主题工厂构造阻塞。** 各独立30次，基线/最终存储P95为2.515/2.494ms，构造浅深主题对为1.284/1.123ms，远小于实际切换窗口。没有因此增加主题缓存或改存储架构。
4. **软件渲染与普通点击也产生慢帧。** 最终在主样本之后额外30次点击已选深色，控件不提交偏好且不切换主题；稳定29次仍有raster P95 50.679ms、171/425（40.24%）超预算。说明慢帧不只出现在主题变化时；主题路径自身仍比该控制更重，不能把剩余问题全部归因环境。

最初使用 `fullyLive` 测试绑定会持续绘制，相关帧统计不作为最终结论，原始探索数据单独放在 [exploratory-fully-live](exploratory-fully-live/README.md)。

## 复现与边界

使用项目 Flutter/JDK/Android SDK 环境：

```sh
python3 tool/run_isolated_validation.py --platform android --device emulator-5554 --target acceptance --mode profile --case theme-performance
python3 docs/performance/theme-switch-2026-11-16/summarize.py docs/performance/theme-switch-2026-11-16/optimized-production.json
```

受保护runner核验独立测试包 `app.nianxia.nianxia.test`，不授权麦克风、不加载正式库。Profile只通过固定测试包的run-as读取nonce结果；正式安装路径前后保持，不读取正式资料内容。源库结束时只清理本次nonce目录，数字结果保留。iOS该自动采样入口明确拒绝，未扩大原生provider权限。

[baseline.patch](baseline.patch) 是从最终生产文件回到本轮基线的定向差异，包含此前 #18 首页；只用于另一个副本中的基线复测，勿覆盖当前WIP。应用后沿用同一采样入口。新增但未引用的偏好scope不会参与旧版采样。

未验收 Magic8／iPhone17 实机、iOS和系统物理呈现延迟。需要在目标设备补同条件Profile采样及手感验收，才能判断用户原先的掉帧是否仍然存在。没有新增生产内容遥测或依赖。
