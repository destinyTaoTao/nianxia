# 平台外观与可访问性

2026-11-14；R5。Android保持中性Material3；iOS使用同一业务动作和实色操作层。没有完整Xcode/iOS26 SDK与真机，原生玻璃叠层/滚动/键盘/触控/帧时间原型无法验收，因此本批不加入自绘模糊或宣称Liquid Glass已支持，`glassSupported`保持false。

## 实现和自动验证

- `PlatformAppearanceAdapter`订阅iOS原生偏好与恢复前台事件；Android使用Flutter实际系统accessibility features。初次读取、后续通知和恢复前台有代际保护，晚到的初始快照不覆盖新设置。未知/失败保留保守实色显示，不影响记录与备份。
- iOS桥接直接读取 `UIAccessibility.isReduceMotionEnabled`、`isReduceTransparencyEnabled`、`isDarkerSystemColorsEnabled`，订阅相应通知。API依据：[Apple UIAccessibility](https://developer.apple.com/documentation/uikit/uiaccessibility/)。本机仅执行 `swiftc -frontend -parse ios/Runner/AppDelegate.swift` 语法检查；未执行UIKit类型检查、iOS编译或原生运行。
- 原生减少动态效果独立于Flutter的disableAnimations，通过MediaQuery、主题过渡和共享弹层AnimationStyle传递到实际页面；高对比提高辅助文字对比；减少透明度保留实色。所有降级保留原按钮动作和语义，不增加用户流程中的技术开关。
- 八项主机合约测试通过：减少透明度/高对比拒绝玻璃；iOS独立动态偏好与即时更新；旧iOS实色仍可停止；非法数据降级；360×640视口双倍字体停止可达并确实提交；快照竞态；实际app根MediaQuery/过渡更新；深浅/高对比正文与辅助色对比均≥4.5:1。根页面Android语义触控目标检查通过，停止按钮高度≥48逻辑像素。

Android API36 ARM64模拟器的独立Profile与非调试Release/AOT均通过扩展UI链路：浅深主题切换、系统文本缩放2倍、第二段真实录音停止并提交、原生IME实际显示和收起、查找输入框位于键盘可见区域之上。结果见 `android-appearance-{profile,release}.json`；截图为 `home-light.png`、`home-large-text.png`、`recorder-large-text.png`、`search-keyboard.png`，已逐图检查。最后一张来自Flutter画面捕获，不包含系统IME独立窗口；键盘存在由实际FlutterView inset从0变正再回0断言。初版从Scaffold已消费的子MediaQuery读取inset导致误判，已改查实际View。自然语言输入只由受控测试键盘完成，未宣称中文IME候选流程通过。

本批完整主机门禁：32项Python、静态分析无问题、312项Flutter测试通过。TalkBack/VoiceOver的自然语音播报、用户导航与真机体验不由语义树测试替代。Native玻璃与iOS系统偏好运行验证在接入完整Xcode和设备后继续；此限制不阻止当前实色UI使用。
