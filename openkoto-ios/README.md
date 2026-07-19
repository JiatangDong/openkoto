# OpenKoto iOS

OpenKoto 的 SwiftUI 原生 iOS 应用。设计文档：[`docs/plans/2026-07-15-ios-app-design.md`](../docs/plans/2026-07-15-ios-app-design.md)。

## 当前状态：M0 脚手架 + 交互原型

- ✅ 工程结构（薄 App 壳 + OpenKotoKit 本地 SwiftPM 多模块包）
- ✅ 设计系统：3 主题（California / Tokyo / Seoul）× 明暗，色值由脚本从桌面版 OKLCH 主题转换生成
- ✅ 原型页面：书库 / 阅读器（逐句 chip + 精讲底部弹层 + TTS 朗读）/ 生词本 / 设置（主题切换可用）
- ✅ 内置公版示例文章（《夢十夜》《Alice in Wonderland》），零配置可体验
- ⚠️ 数据为内存原型（`PrototypeStore`）；AI 精讲为模拟延迟 + 占位内容
- ⏳ M2：GRDB schema、切分算法 1:1 移植、SM-2；M3：真实 AI 客户端（BYOK + Keychain）

## 运行

```bash
open OpenKoto.xcodeproj   # Xcode 26+，选 iOS 17+ 模拟器直接 Run
```

命令行：

```bash
xcodebuild -project OpenKoto.xcodeproj -scheme OpenKoto \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# 非 UI 逻辑单测（无需模拟器）
cd Packages/OpenKotoKit && swift test
```

启动参数 `-prototypeDemo`：自动打开第一篇示例文章并选中首句（截图/UI 测试用）。

## 目录

```
App/                    App 壳（@main、Assets、PrivacyInfo）
ShareExtension/         M5：分享导入扩展（只写 App Group inbox）
Packages/OpenKotoKit/   全部业务代码
  Sources/OKModels/         领域模型（零依赖）
  Sources/OKPersistence/    GRDB（M2 落 schema）
  Sources/OKAIClient/       多 Provider LLM 客户端（M3 实现）
  Sources/OKSegmentation/   句子切分（M2 移植桌面算法）
  Sources/OKDesignSystem/   主题 token + 通用组件
  Sources/OKLocalization/   en/zh/ja String Catalog
  Sources/OKFeatures/       各屏幕
scripts/generate_palettes.py  桌面 CSS 主题 → Swift 调色板（改主题后重跑）
```

## 约定

- 分层依赖单向：`OKFeatures → 其余模块 → OKModels`；`OKAIClient` 禁止 import `OKFeatures`
- API Key 只进 Keychain，不进 UserDefaults / 日志 / 导出
- 视图文件用 `#if os(iOS)` 包裹，保证 `swift test` 在 macOS 可编译
