# Chat Prompt Features Design

## Goal

让 AI 对话支持可持久化、自定义、可扩展的 prompt 功能库，满足下面几类需求：

- 普通对话使用可自定义的默认 prompt
- 选中文本后的快捷功能不再写死为 `翻译 / 解释 / 语法`
- 用户可以修改内置功能的名称、描述、prompt、显示方式和排序
- 用户可以新增自己的功能卡片，并保存为默认配置

最终效果是：`普通对话` 和 `快捷操作` 都从同一套配置驱动，而不是散落在前端代码里硬编码。

## Current State

- [ArticleChatAssistant.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleChatAssistant.tsx) 当前在前端本地写死了三种快捷功能：
  - `translate`
  - `explain`
  - `grammar`
- 普通对话首轮只在本地模式下拼了一句固定文案：
  - `You are a helpful reading assistant...`
- 这些 prompt 和功能定义都不在设置里，用户无法修改，也无法新增。
- 配置当前统一保存在 `config.json` 对应的 [types.rs](/Users/rqq/TextLingo/textlingo-desktop/src-tauri/src/types.rs) `AppConfig` 里，适合直接扩展，不需要额外存储层。

## Design Decision

采用“全局 Prompt 功能库”方案。

也就是在 `AppConfig` 上新增一组统一的 `prompt_features` 配置，覆盖：

- 普通对话默认 prompt
- 内置快捷功能
- 用户新增的自定义功能

不按模型区分，也不引入多套 profile。第一版先把“全局一套，可编辑、可扩展、可持久化”做好。

这样做的原因：

- 和当前产品结构最契合
- 改动集中在配置、设置页、`ArticleChatAssistant`
- 能无缝覆盖现有功能
- 后续如果要支持导入导出或 profile，也可以在这套模型上继续演进

## Scope

### In Scope

- 在 `AppConfig` 中新增 prompt 功能配置
- 提供默认内置功能并兼容旧配置
- 在设置页增加 `AI 对话功能` 管理入口
- 普通对话改为读取默认 prompt 配置
- 快捷操作改为由配置动态渲染
- 支持新增、编辑、启用/禁用、排序、删除自定义功能
- 支持重置内置功能为默认值

### Out of Scope

- 按模型保存不同的一套 prompt 功能
- profile 模式（如精读模式、考试模式、口语陪练模式）
- prompt 市场、云同步、在线分享
- 对远程后端 `novel-chat` 能力做协议级重构

## UX Design

### Settings Entry

在现有设置页新增一个 `AI 对话功能` 分组。

这个分组展示一个功能卡片列表，包含全部 prompt 功能。列表中第一项为 `普通对话默认 prompt`，后面是可显示在快捷操作区的功能卡片。

### Feature Card Fields

每个功能支持以下字段：

- `名称`
- `描述`
- `prompt 模板`
- `是否需要选中文本`
- `是否显示在快捷操作区`
- `图标`
- `排序`
- `是否启用`

### Built-in vs Custom

内置功能使用固定 `id`，用户可以修改，但不允许真正删除，只允许：

- 禁用
- 隐藏
- 恢复默认

自定义功能允许完整新增和删除。

### Chat Surface Behavior

普通对话区：

- 发送消息时自动应用 `普通对话默认 prompt`
- 不再使用硬编码的首轮提示词

选中文本快捷区：

- 根据配置动态渲染所有 `show_in_quick_actions = true` 且 `enabled = true` 的功能
- 需要选中文本的功能在未选中文本时不可触发
- 自定义功能与内置功能混排，按排序字段展示

## Data Model

在 [types.rs](/Users/rqq/TextLingo/textlingo-desktop/src-tauri/src/types.rs) 的 `AppConfig` 中新增：

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PromptFeature {
    pub id: String,
    pub kind: String,
    pub name: String,
    pub description: String,
    pub prompt_template: String,
    #[serde(default)]
    pub requires_selection: bool,
    #[serde(default)]
    pub show_in_quick_actions: bool,
    pub icon: String,
    #[serde(default)]
    pub sort_order: i32,
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default)]
    pub is_builtin: bool,
    #[serde(default)]
    pub created_at: Option<String>,
    #[serde(default)]
    pub updated_at: Option<String>,
}
```

并在 `AppConfig` 中新增：

```rust
#[serde(default = "default_prompt_features")]
pub prompt_features: Vec<PromptFeature>,
```

### Recommended Built-in IDs

建议内置固定使用这些 `id`：

- `chat.default`
- `selection.translate`
- `selection.explain`
- `selection.grammar`

这样后续可以稳定做：

- 默认值注入
- 内置项恢复默认
- 兼容迁移

### Kind Semantics

建议 `kind` 先只支持两类：

- `chat_default`
- `quick_action`

这样结构够用，也不会提前过度设计。

## Prompt Template Variables

`prompt_template` 支持统一变量替换：

- `{text}`：选中文本
- `{user_input}`：用户在输入框里的原始问题
- `{target_language}`：当前目标语言
- `{source_language}`：当前源语言
- `{article_title}`：文章或书籍标题
- `{current_segment}`：当前上下文片段

规则：

- 未提供的变量替换为空字符串
- `requires_selection = true` 的功能如果没有 `{text}` 对应内容，则不允许触发
- 普通对话默认 prompt 应优先使用 `{user_input}`，避免把输入内容拼接两次

## Execution Rules

### Default Chat

普通对话执行时：

1. 读取 `chat.default`
2. 将变量注入 `prompt_template`
3. 作为系统/前置指令拼入本地聊天请求
4. 再附上用户原始输入

前端不再使用硬编码的：

- 欢迎语之外的固定 prompt
- 首轮 `You are a helpful reading assistant...`

### Quick Actions

快捷功能执行时：

1. 读取对应 `PromptFeature`
2. 用当前上下文替换模板变量
3. 将渲染后的 prompt 作为实际发送内容
4. 在 UI 中保留功能名称和描述，用于解释该操作是什么

这会替代 [ArticleChatAssistant.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleChatAssistant.tsx) 里当前硬编码的本地快捷操作数组。

### Translation Special Case

当前 `translate` 快捷操作走的是独立的 `translate_text` 命令，不是通用对话。

第一版建议保留现有翻译快捷路径，但让其文案和入口来自 `PromptFeature` 配置：

- 内置 `selection.translate` 仍可显示、排序、改名
- 但执行层继续走现有高效翻译命令

这样可以：

- 保持性能和结果稳定
- 避免第一版把翻译路径全部塞回通用对话链路

需要在实现里明确：这是一个“配置驱动的 UI 能力”，但不强制所有功能都必须走同一后端命令。

## Default Values

建议提供以下默认内置项：

### `chat.default`

定位为阅读助手默认 prompt，负责：

- 基于阅读材料答疑
- 优先用目标语言解释
- 结合选中文本和当前片段回答

### `selection.translate`

定位为快速翻译，默认：

- 需要选中文本
- 显示在快捷操作区
- 图标为 `translate`

### `selection.explain`

定位为解释文本含义，默认：

- 需要选中文本
- 显示在快捷操作区
- 图标为 `explain`

### `selection.grammar`

定位为分析语法，默认：

- 需要选中文本
- 显示在快捷操作区
- 图标为 `grammar`

## Migration Strategy

旧用户的 `config.json` 不会包含 `prompt_features` 字段。

因此需要在配置反序列化和默认值层面保证：

- 没有该字段时自动补默认值
- 用户升级后立即可用
- 无需手动初始化

建议策略：

1. 在 `AppConfig` 上为 `prompt_features` 提供默认值函数
2. `load_config` 后如果发现字段为空，也补默认内置项
3. 对内置项做按 `id` 的补齐，而不是只判断整个数组是否为空

按 `id` 补齐更稳，因为可以覆盖这类情况：

- 老版本完全没有字段
- 用户只删掉或损坏了部分配置
- 后续版本新增一个新的内置功能

## UI and Interaction Rules

### Settings List

列表应支持：

- 新建自定义功能
- 编辑任意功能
- 启用/禁用
- 排序
- 恢复内置项默认值
- 删除自定义功能

### Validation

保存前至少校验：

- `name` 不为空
- `prompt_template` 不为空
- `id` 唯一
- `sort_order` 为有效数字

### Icons

第一版不要开放自由上传图标，只允许选择一组受控图标名，例如：

- `sparkles`
- `languages`
- `lightbulb`
- `graduation-cap`
- `book-open`

避免把图标系统一起做复杂。

## Remote Session Considerations

当前远程对话依赖 `streamNovelChat` 与会话上下文，前端仅传：

- `message`
- `selected_text`
- `current_segment`
- `reading_progress`

第一版不修改远程接口协议，采用前端渲染 prompt 的方式兼容：

- 对普通对话：将 `chat.default` 渲染后拼接进用户发送消息
- 对快捷功能：将模板渲染结果直接作为消息正文

这不是最理想的系统 prompt 语义，但能在不改后端协议的前提下先把用户自定义能力做起来。

后续如果远程接口支持显式 `system_prompt` 或 `feature_id`，可以再把这里升级为更干净的协议。

## Testing

需要新增或更新测试覆盖以下范围：

- `AppConfig` 能正确序列化/反序列化 `prompt_features`
- 旧配置缺少该字段时能自动注入默认功能
- 设置页可以新增、编辑、删除自定义功能
- 设置页可以修改内置功能并持久化
- 设置页可以恢复内置功能默认值
- `ArticleChatAssistant` 根据配置渲染快捷功能列表
- 未选中文本时，要求选中文本的功能不可触发
- 普通对话执行时应用 `chat.default`
- 快捷功能执行时完成变量替换
- 旧功能 `translate` 继续走现有快速翻译路径，不发生回归

## Risks

### Prompt Duplication

如果 `chat.default` 的模板本身包含完整用户输入，而执行层又额外追加原始输入，容易造成内容重复。

因此实现时必须明确：

- 普通对话模板只负责提供“前置行为指令”
- 用户问题本身由执行层独立附加

### Remote Prompt Semantics

远程会话当前没有独立 `system prompt` 字段，第一版只能把模板渲染进消息正文。

这意味着：

- 某些模型对“系统约束”的服从度可能不如显式 system role
- 同一 prompt 在本地和远程上的效果可能略有差异

这是第一版接受的折中。

### Feature Sprawl

一旦允许自定义功能，功能数量可能迅速膨胀。

因此第一版必须至少提供：

- 启用/禁用
- 排序
- 是否显示在快捷操作区

否则 UI 很快会失控。

## Recommendation

按以下顺序实现：

1. 扩展 `AppConfig`，加入 `prompt_features` 和默认值注入
2. 在设置页增加 `AI 对话功能` 管理界面
3. 改造 `ArticleChatAssistant`，把普通对话和快捷操作都切到配置驱动
4. 保留 `translate_text` 的独立执行路径，只把入口层改成配置驱动
5. 为配置迁移、UI 编辑和运行时行为补测试

这是当前最稳、最容易交付、也最符合用户需求的一版。
