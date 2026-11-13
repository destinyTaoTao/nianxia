---
status: accepted
---

# 核心流程一致，交互与材质分别适配平台

2026-11-13，用户确认 Android 与 iOS 保持相同的记录、查找、编辑、恢复与日历语义，但允许系统控件和视觉材质遵循各自平台习惯。相比强求两端外观一致，此选择优先平台可用性、无障碍与系统集成，并接受分别设计和验证平台呈现的成本。

此决定不指定双原生或 Flutter 技术方案，也不意味着已采用玻璃组件。iPhone 的原生 Liquid Glass 作为待验证候选，Android 以 Material 为设计参考；具体实现须核对项目锁定版本、设备能力、阅读对比度和性能。平台呈现不得改变保存成功、用户确认或日历保存结果等业务含义。

依据：[Apple Liquid Glass 采用指南](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)、[Android Material 3](https://developer.android.com/develop/ui/compose/designsystems/material3)。
