# OpenKoto iOS

OpenKoto 的 SwiftUI 原生 iOS 应用。设计文档：[`docs/plans/2026-07-15-ios-app-design.md`](../docs/plans/2026-07-15-ios-app-design.md)。

## 当前状态：M0 脚手架 + 交互原型

- ✅ 工程结构（薄 App 壳 + OpenKotoKit 本地 SwiftPM 多模块包）
- ✅ 设计系统：3 主题（California / Tokyo / Seoul）× 明暗，色值由脚本从桌面版 OKLCH 主题转换生成
- ✅ 原型页面：书库 / 阅读器（逐句 chip + 精讲底部弹层 + TTS 朗读）/ 生词本 / 设置（主题切换可用）
- ✅ 内置公版示例文章（《夢十夜》《Alice in Wonderland》），零配置可体验
- ⚠️ 数据为内存原型（`PrototypeStore`）；AI 精讲为模拟延迟 + 占位内容
- ⏳ M2：GRDB schema、切分算法 1:1 移植、SM-2；M3：真实 AI 客户端（BYOK + Keychain）

## 支持平台

| 平台 | 形态 | 最低版本 |
|---|---|---|
| iPhone | 底部 tab 栏，精讲走半屏 sheet | iOS 18 |
| iPad | 宽屏（≥900×500）自动切侧边栏 + 精讲右侧常驻分栏 | iPadOS 18 |
| Mac | Mac Catalyst，一套代码 | macOS 15 |

宽窄判定只有一处真值：`OKDesignSystem/Layout/OKCanvas.swift`（纯宽高，不用 size class——
它在 macOS 不存在、Catalyst 下恒为 regular，且 iPad 的 regular 覆盖 744→1366pt 差 1.8 倍）。

## 运行

```bash
open OpenKoto.xcodeproj   # Xcode 26+，选 iOS 18+ 模拟器直接 Run
```

命令行：

```bash
# iOS
xcodebuild -project OpenKoto.xcodeproj -scheme OpenKoto \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# Mac Catalyst（-allowProvisioningUpdates 不能省，见下方「Mac 特有的坑」）
xcodebuild -project OpenKoto.xcodeproj -scheme OpenKoto \
  -destination 'platform=macOS,variant=Mac Catalyst' -allowProvisioningUpdates build

# 非 UI 逻辑单测（无需模拟器，含布局决策的纯函数）
cd Packages/OpenKotoKit && swift test
```

启动参数（截图/UI 测试用）：

| 参数 | 作用 |
|---|---|
| `-prototypeDemo` | 自动打开第一篇示例文章并选中首句 |
| `-startTabLibrary` / `-startTabVocabulary` / `-startTabStatistics` / `-startTabSettings` | 启动直接落在指定页 |
| `-statsScrollReading` | 统计页滚到阅读时长区 |
| `-seedStatsDemo`（仅 DEBUG） | 种子数据填满统计图表 |
| `-app.interfaceLanguage zh-Hans` | 覆盖界面语言 |
| `-okForceWideCanvas` / `-okForceCompactCanvas` | 强制宽/窄布局分支（本机无法脚本旋转模拟器，靠它在任意设备上覆盖两条分支） |

> 截图脚本必须**串行**跑：`xcrun simctl shutdown all` 会把并行任务的模拟器一起关掉，
> 拿到的会是另一台设备的画面。

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
- 视图文件用 `#if os(iOS)` 包裹，保证 `swift test` 在 macOS 可编译。
  **Catalyst 下 `os(iOS)` 为真**，所以这些条件不妨碍 Mac 版
- 布局决策（宽窄判定、可读宽度、滚动脱离、浮层落点、图表轴抽稀）一律抽成
  平台无关的纯函数放进 `swift test`：UI 层的回归靠截图肉眼比对，成本高且不可回归，
  纯函数是唯一能自动守住的层
- 宽屏适配走共用 modifier，不要逐页硬改：`readableTextWidth` / `adaptiveDetailPane` /
  `okRowActions` / `readingClock` / `okSheetSizing`

### Mac 特有的坑（改动时留意）

- **`okRowActions` 必须同时给 contextMenu**：Catalyst 的 List 行不支持横扫，
  只写 `swipeActions` 的功能在 Mac 上完全不可达
- **App Group 在 Mac 上要带 Team ID 前缀**：由 pbxproj 的 `OK_APP_GROUP_ID[sdk=macosx*]`
  注入进 Info.plist（自定义键不能用 `INFOPLIST_KEY_*`，会被静默丢弃）
- **Keychain 四个查询都要带 `kSecUseDataProtectionKeychain`**：只带一部分会出现
  "写进去读不出来"，表现为用户配好的 API Key 重启后消失
- **Catalyst 构建必须拿到描述文件**，否则上一条根本不生效：macOS 的
  data-protection keychain 要求调用方持有 keychain 访问组。`OpenKoto-Catalyst.entitlements`
  里的 `keychain-access-groups` 就是用来强制 Xcode 去申请描述文件的 ——
  没有它时那些沙盒 entitlement 都不需要描述文件，Xcode 直接签完了事，
  产物既无 `application-identifier` 也无访问组，`SecItemAdd` 返回
  `errSecMissingEntitlement(-34018)` 静默失败。**Xcode.app 构建同样中招**，
  不是命令行独有。命令行因此必须带 `-allowProvisioningUpdates`。
  用 `scripts/check-catalyst-keychain.sh` 一条命令验产物有没有资格
- **外部媒体书签在沙盒下必须 `.withSecurityScope`**（见 `MediaBookmark`），
  否则退出重开后视频永远显示"媒体不可用"
- 以上四条失败时**都不报错**，只是功能静默消失
