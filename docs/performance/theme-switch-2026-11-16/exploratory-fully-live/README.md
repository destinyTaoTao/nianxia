# 已被替代的探索数据

最初的三轮使用 LiveTestWidgetsFlutterBinding.fullyLive，会持续请求绘制，不能用其窗口帧统计归因主题掉帧，也不作为最终前后对比。后来以普通 WidgetsFlutterBinding 重做基线，并增加静止窗口与同值点击控制。

旧 fullColorUs 仅代表框架 post-frame 中根 ThemeData 的 scaffoldBackgroundColor 达到目标，不能理解为整屏完成渲染。最终有效口径与结果见上级 README。
