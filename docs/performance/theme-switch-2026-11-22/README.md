# 最终布局主题性能复验与失败样本诊断

2026-11-22。应用生产代码沿用#19优化；本轮增加测试侧分段观测和失败证据，未通过改大600ms门槛获得通过。

## 已定位的层次

1. #19已验证并修复的UI原因是整页主题插值叠加Material正文颜色插值，以及下拉弹层与主题更新重叠。当前仍采用立即切换根主题、关闭面板正文插值和内联三选一。最终布局原协议响应与#19优化结果接近，没有持续退化证据。
2. 持久化与主题构造不是当前主要耗时：本次各30次独立测量P95为3.290ms、1.478ms；主题选择后的build P95为4.373ms，raster P95为81.055ms。SurfaceFlinger实际报告ANGLE/SwiftShader软件渲染，测试时曾观察到模拟器进程926.9% CPU。软件绘制路径明显慢于UI构建。
3. 不发生主题修改的已选项点击控制，raster P95仍为51.560ms，build P95仅0.612ms。说明剩余慢帧不只由切换主题触发；不能只改偏好存储或主题逻辑就宣布消除了全部掉帧，也不能将超预算帧比例当作物理丢帧率。
4. 先前的600ms失败没有被忽略：三轮失败保留，两轮分段记录显示回调控制第6/7次在693.730/653.121ms才被post-frame观察到；届时偏好、亮度和背景token均正确。第三轮失败之前，真实点按的完整30个样本响应P95为47.489ms。失败发生不等于已经证明实际点按持续卡顿600ms。

最后两轮诊断和关闭探针复测均通过。诊断轮每5ms只读偏好/Theme，不请求额外帧；观察到生命周期resumed、输入时scheduler idle，偏好和界面收敛一致。探针可能影响调度，所以最终比较只采用关闭探针的原协议结果。单个旧超窗的全部系统调度原因没有被因果隔离，保留为运行间抖动证据，不伪称已修复某个应用缺陷。

## 同口径比较

Android API36 ARM64，1080×2400、60Hz、Impeller OpenGLES、SwiftShader；Flutter3.47.9/Dart3.13.7。生产WidgetsFlutterBinding调度，100条合成记录，无模型任务，独立nonce和进程。浅深交替30次，稳定组为后29次，固定600ms帧窗口，nearest-rank P95。沿用#19协议，不将post-frame token响应称为物理显示延迟。

| 稳定29次 | 原始基线 | #19优化后 | 最终布局 |
| --- | ---: | ---: | ---: |
| 背景token响应P95 | 349.014ms | 54.736ms | 55.551ms |
| build P95 | 12.582ms | 4.996ms | 4.373ms |
| raster P95 | 85.261ms | 85.545ms | 81.055ms |
| 超预算帧/窗口内帧 | 213/278 | 225/298 | 259/328 |

最终布局相对原始基线的token响应约下降84%，相对#19结果约增加1.5%；没有A/B/A重复，后者不足以判定性能回归。首次切换20.227ms；静止600ms为0帧。当前软件渲染数据不能证明真机60FPS。

- [最终原始数据](final-timings.json)、[汇总](final-summary.json)、[机器结果](final-result.json)，runId `64e31458-c6ad-424b-9fc0-d9a935082308`。
- [分段诊断原始数据](diagnostic-timings.json)、[汇总](diagnostic-summary.json)、[机器结果](diagnostic-result.json)，runId `7b64ac7d-7971-4a90-b988-329fab982451`；不混入最终比较。
- [先前失败的完整点按/部分控制数据](previous-failed-sample.json)，runId `d9717a28-a6b7-428f-8aa6-10dce8c1593d`；不能冒充整轮通过。[其余两次失败记录](../theme-switch-2026-11-20/)。
- [#19基线和诊断](../theme-switch-2026-11-16/README.md)。

## 复现与边界

```sh
python3 tool/run_isolated_validation.py --platform android --device emulator-5554 --target acceptance --mode profile --case theme-performance
# 仅诊断；最终数字必须关探针重跑
python3 tool/run_isolated_validation.py --platform android --device emulator-5554 --target acceptance --mode profile --case theme-performance --theme-trace
python3 docs/performance/theme-switch-2026-11-16/summarize.py docs/performance/theme-switch-2026-11-22/final-timings.json
```

trace参数只允许Android Profile主题case，工具回归已覆盖合法透传及其他case拒绝。源码不增加生产遥测。失败时保留有界的场景、序号、枚举、数值及当轮frame集合，原600ms断言保持。

只用核验后的`app.nianxia.nianxia.test`与nonce私有缓存；不读正式内容、不授麦克风、不加载模型。Magic8/iPhone17、iOS、系统物理呈现与自然手感仍需[既有#15](https://github.com/destinyTaoTao/nianxia/issues/15)验收。
