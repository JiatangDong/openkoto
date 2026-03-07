# Book Assistant Sidebar Design

## Goal

让 `PDF / EPUB / TXT` 书籍阅读器接入和文章阅读器一致的右侧 AI 助手能力，至少支持：

- `思维导图`
- `对话`
- `1/3 / 2/3 / 全屏` 布局模式

同时避免在文章页和书籍页重复维护两套右侧助手 UI。

## Current State

- 文章页 [ArticleReader.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx) 已经有完整的右侧助手栏：
  - tabs
  - 助手显隐
  - `compact / wide / full`
  - 思维导图面板
- 书籍页 [BookReader.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/BookReader.tsx) 仍是一套独立的简化实现：
  - 固定宽度右栏
  - 只有 `对话`
- [ArticleMindMapPanel.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.tsx) 本身已经只依赖 `Article` 数据，不依赖文章页专属 UI，所以可以直接复用到书籍页。

## Design Decision

采用统一右侧助手壳组件，而不是继续在 `BookReader` 里复制文章页右栏。

新增一个通用组件，例如：

- [AssistantSidebarShell.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/AssistantSidebarShell.tsx)

这个壳组件负责：

- 助手显隐
- `compact / wide / full`
- tab 外壳
- 右上角布局切换按钮
- 主内容区/助手区的双栏布局

页面级组件只负责提供：

- 左侧主内容
- tabs 定义
- 默认 tab
- 空状态内容

## Scope

### In Scope

- 抽取统一助手侧栏壳
- 文章页迁移到统一壳
- 书籍页迁移到统一壳
- 书籍页新增 `思维导图` tab
- 书籍页保留 `对话` tab
- 书籍页支持 `1/3 / 2/3 / 全屏`

### Out of Scope

- 书籍页新增“讲解”tab
- EPUB/PDF 文本提取链路重做
- 思维导图后端生成逻辑改造

## Book Formats

这次 UI 层全部支持：

- `TXT`
- `PDF`
- `EPUB`

但需要明确：

- `TXT` 的 `article.content` 比较完整，导图质量最稳
- `PDF / EPUB` 是否能生成高质量导图，取决于当前导入时 `article.content` 是否包含足够正文
- 本次不重做提取链路，只接通入口和复用现有导图链

## Architecture

### New Shared Shell

统一壳组件接收：

- `storageKey`
- `showAssistant`
- `onShowAssistantChange`
- `tabs`
- `defaultTab`
- `titleBar`
- `mainContent`

并统一管理：

- 当前 tab
- 当前布局模式
- 布局模式持久化
- 主区/助手区 class

### Article Reader

文章页改成：

- 左侧仍然是现有阅读内容
- 右侧 tabs 由统一壳承载
- 内容仍然是：
  - `讲解`
  - `思维导图`
  - `对话`

### Book Reader

书籍页改成：

- 左侧仍然是 `PdfReader / EpubReader / TxtReader`
- 右侧 tabs 改为：
  - `思维导图`
  - `对话`
- `思维导图` 直接复用 [ArticleMindMapPanel.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.tsx)

## Data Flow

### Mind Map

- 书籍页把当前 `article` 直接传给 `ArticleMindMapPanel`
- 面板继续调用现有：
  - `create_mind_map_task_cmd`
  - `get_artifact_cmd`
  - `artifact_save_cmd`

### Chat

- 书籍页继续用 [ArticleChatAssistant.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleChatAssistant.tsx)
- `selectedText` 仍由 `PdfReader / EpubReader / TxtReader` 通过 `onTextSelect` 更新

## UI Rules

### Book Reader Tabs

- 默认 tab：`思维导图`
- 如果用户选中过文本并希望立即问答，后续再考虑自动跳 `对话`
- 本次先不做自动跳转

### Layout

统一沿用文章页规则：

- `compact`
- `wide`
- `full`

但书籍页用不同的 `storageKey`，避免和文章页互相污染用户偏好。

## Testing

需要新增/更新测试覆盖：

- `BookReader` 渲染统一助手壳
- 书籍页出现 `思维导图` 和 `对话`
- 书籍页布局模式可切换并持久化
- 书籍页思维导图 tab 能渲染 `ArticleMindMapPanel`
- 文章页迁移后原有右栏行为不回归

## Risks

### Layout Regression

文章页和书籍页都迁到统一壳后，最容易出问题的是：

- flex 宽度
- tab 内容最小宽度
- `Mind Elixir` 撑开容器

所以统一壳必须在主容器和助手容器上统一使用：

- `min-w-0`
- `overflow-hidden`

### Behavior Drift

文章页已有很多右栏交互逻辑，迁移时要避免：

- tab 文案丢失
- 全屏时主内容隐藏逻辑出错
- 助手显隐按钮行为变化

## Recommendation

先做一次结构重组：

1. 抽统一 `AssistantSidebarShell`
2. 让 `ArticleReader` 和 `BookReader` 都接它
3. 在 `BookReader` 接入 `思维导图 + 对话`

这是最少重复、也最适合后续继续加书籍页 AI 能力的方案。
