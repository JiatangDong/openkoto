# ShareExtension

分享导入扩展（设计文档 §6.3）。从 Safari / 其他 App 的分享菜单接收网址或选中文本，
写入 App Group 收件箱，主 App 消费后导入书库。

## 实现

- `ShareViewController.swift`：`SLComposeServiceViewController` 子类，把分享的 URL / 纯文本
  组装成 `ImportEnvelope`（定义在 `OKModels`），经 `ShareInbox` 原子写入 App Group inbox，随后 `completeRequest`。
- **不加载 GRDB、不跑迁移、不持有 API Key、不调用 AI**——只依赖 `OKModels`。
- 主 App 启动与回前台时 `ContentStore.importFromInbox()` → `ShareInbox.drain()` 消费并删除任务；
  URL 信封无正文时由主 App 用 `TextImport` 抓取正文。

## 配置

- App Group：`group.com.openkoto.ios`（主 App 与扩展两端 entitlements 一致，见
  `App/OpenKoto.entitlements` 与 `ShareExtension/ShareExtension.entitlements`）。
- 激活规则见 `Info.plist`：支持纯文本、Web URL、Web Page（各上限 1）。
- **真机 / TestFlight**：App Group 需在 Apple Developer 账号里注册并勾选到两个 target 的
  Provisioning Profile；模拟器无需 provisioning 即可用（容器由 CoreSimulator 自动创建）。
