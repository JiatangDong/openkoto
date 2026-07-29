# Mac Catalyst 人工冒烟清单

自动化能覆盖的部分已经跑过（见文末「已自动验过」）。这里只剩必须人肉的。

## 先决条件：构建必须拿到描述文件

```bash
./scripts/check-catalyst-keychain.sh   # 10 秒，报 ❌ 就别往下测
```

命令行构建要带 `-allowProvisioningUpdates`，否则会因申请不到描述文件直接失败。
Xcode.app 里 Run 会自动申请。

> **背景（已修复，留档）**：`App/OpenKoto-Catalyst.entitlements` 里的
> `keychain-access-groups` 是必需的，作用是**强制 Xcode 去申请描述文件**。
> 没有它时，那几条沙盒 entitlement 都不需要描述文件，Xcode 直接签完了事，
> 产物既无 `application-identifier` 也无访问组 —— 而 macOS 的
> data-protection keychain 要求调用方持有其一，`SecItemAdd` 会返回
> `errSecMissingEntitlement(-34018)`，**不报错、不弹窗**。
> 现象是：填入 API Key → 保存成功 → 行上没有钥匙图标 → 重启后依然说没配。
> **Xcode.app 构建同样中招**，不是命令行独有的问题。

---

## 1. API Key 存得住吗 ✅ 已验证通过（2026-07-29）

实测路径：设置 → 添加模型 → 填 Key → 保存 → 行上出现钥匙图标 🔑 →
杀进程重启（确认新进程启动时间晚于二进制签名时间）→ 钥匙图标仍在。

回归时重跑这四步即可。钥匙图标就是 `hasKey()` 的可视化，
它调的正是 `SecItemCopyMatching`，图标在 = Keychain 读写都通。

> 若哪天又不见了，先跑 `check-catalyst-keychain.sh`，九成是构建没拿到描述文件。
> 另外**永远不要往 `App/OpenKoto.entitlements`（iOS 那份）加 keychain 访问组** ——
> 会改变默认分组，存量用户已存的 Key 会读不出来。

## 2. 精讲能不能生成（验 `network.client`）

配好真 Key 后，打开《夢十夜》→ 点任意一句 → 右栏应生成翻译+讲解。
沙盒缺 `network.client` 时**所有 AI 调用静默失败**，表现为一直转圈或空白。

## 3. 拖 EPUB 进书库（验 `files.user-selected.read-write`）

从 Finder 拖一个 .epub 到书库窗口 → 应导入成功。
另外走一遍「+ → 导入文件」，两条路径都要过（拖拽和 fileImporter 是两套权限触发点）。

## 4. 外部视频重启后还能播（验 `.withSecurityScope`）

1. 导入一个视频，选**「引用模式」**（不复制进 App，只存书签）
2. 播一下确认正常
3. ⌘Q 退出 → 重开 → 再播

失败表现是「媒体不可用」。这条**只有重启后才会暴露**，当次会话一直是好的。

## 5. Safari 分享（验 App Group 的 Team ID 前缀）

Safari 打开任意网页 → 分享 → OpenKoto → 回 App 看有没有收进来。

失败是**完全静默的**（`ShareInbox.init?` 返回 nil → `guard let` 直接 return，
点了什么都不发生）。已确认 `~/Library/Group Containers/MJFP85U8HQ.group.com.openkoto.ios`
会被创建，但**分享扩展本身在 Catalyst 下的端到端链路没验过**。

## 5b. iCloud 跨设备同步（P3，端到端未验）

**这一条我完全没能验证** —— CloudKit 的往返需要两台设备登同一个 iCloud 账号。
数据层（变更收集、冲突合并、删除传播、复习重放）有 18 条单测顶着，
但"记录真的到了云上、真的又回来了"这一步只能人肉。

先决条件：`./scripts/check-catalyst-keychain.sh` 要报 **✅ CloudKit 容器：有**。

1. 三台设备（iPhone / iPad / Mac）登同一个 iCloud，设置 → iCloud 同步 → 打开
2. A 加一个生词 → B 上出现
3. A 删掉它 → B 上消失
4. **离线冲突（最关键）**：A、B 都断网，各把同一张卡复习一轮 →
   联网后两条复习记录都在，卡片的 `reviewCount` 是 2 而不是 1。
   若只剩 1，说明卡片状态被 last-writer-wins 覆盖了 —— 那是这套设计要防的头号问题
5. 关掉 iCloud 或退出账号 → App 每个功能仍然正常（同步是增强，不是依赖）
6. 全新设备首次同步 → 书籍在**原生模式**下完整可读（正文在数据库里，
   EPUB 文件不同步）；视频显示"媒体不可用"但字幕与精讲都在

## 6. 滚轮脱离字幕自动跟随

打开有字幕的视频 → 播放 → **用滚轮往回滚**（不是拖滚动条）→
应该停止自动跟随并出现「回到当前句」。

`SubtitleFollow.shouldDisengage` 的五种 ScrollPhase 已有单测，但
「滚轮真的产生 `.interacting` 阶段」这一步只能实机验。

## 7. 菜单栏与快捷键

菜单栏「阅读」菜单：↑↓ 换句、⌘P 朗读、⌘⌥0 开关精讲栏、⌘+/⌘- 字号。
复习页 1/2/3 三档评分。

---

## 附：窗口放不大 —— 需要你拍板的一个决策

当前 `TARGETED_DEVICE_FAMILY = "1,2"`（无 `6`），也就是
**「Scale Interface to Match iPad」**模式：整个 UI 按 77% 缩放渲染，
窗口被锁死在 **985×693 点**，在 1512×982 的屏幕上只能占约 65% 宽，拉不满。

改成 `"1,2,6"`（Optimize Interface for Mac）能拿到原生缩放、AppKit 风格控件、
窗口自由缩放，但会改变全部控件的渲染尺寸和留白，等于要把所有页面重看一遍，
且部分 UIKit API 在 Mac idiom 下行为不同。

不是 bug，是一个取舍。建议先按现状发，收到「窗口太小」的反馈再切。

---

## 附：已修复的一个既有 bug（三平台同时坏，非本次适配引入）

统计页三个日期图表的 X 轴标签全部被截成「…」，iPhone 上一样坏（已截图对比确认）。

根因有**两个**，只修一个仍然是一排省略号：

1. `x: .value("date", String(day.dateLocal.suffix(5)))` 是字符串 → 分类轴，
   而 `.automatic(desiredCount: 5)` 只对连续轴生效，不抽稀就是 30 个标签
2. 分类轴默认把标签压进它那一个「类目带」的宽度（30 天时每带约 14pt），
   即使抽稀到 5 个也照样截断

修法见 `StatisticsView.dateAxis(_:)` + `ChartAxis.stridedLabels(_:target:)`
（纯函数，`ChartAxisTests` 5 条断言守着「结果数量不得超过 target」）。
现在 Mac 与 iPhone 都显示 `06-29 07-05 07-11 07-17 07-23`。

---

## 已自动验过，不用重测

- 五个主页面在 Mac 上的版式：阅读器（侧栏 + 限宽正文 + 右侧精讲常驻分栏）、
  书库（2 列网格）、统计（2 列瀑布）、设置（720pt 限宽居中）、生词本
- **右键行操作**：生词行右键弹出「标记已掌握 / 删除」——
  这是当初判断「Mac 上没有右键就等于功能不可达」的那条，已实证通过
- `presentationSizing(.form)`：添加模型 sheet 在 Mac 上尺寸正常（不占满屏也不缩成小方块）
- 模型配置本身（非 Key）重启后仍在
- 侧栏导航、Tab 切换、表单输入、Tab 键跳字段
