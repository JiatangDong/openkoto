# Assistant Panel Layout Design

## Goal

为文章阅读页右侧助手栏增加固定三档布局切换：

- `1/3` 紧凑模式
- `2/3` 宽屏模式
- `全屏` 模式

并针对思维导图在窄栏状态下的拥挤问题做响应式降级，优先保证脑图画布可用面积。

## Current State

当前右侧助手栏在 [ArticleReader.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx) 中是固定宽度：

- `w-[350px]`
- `md:w-[400px]`

这对“讲解 / 思维导图 / 对话”三种 tab 都是一刀切。思维导图当前在 [ArticleMindMapPanel.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.tsx) 中采用纵向堆叠：

- 标题与摘要卡
- 指标卡
- Mind Elixir 画布
- 节点详情
- Agent 日志

在固定窄栏中，信息密度过高，脑图画布高度虽足够，但横向空间明显不够，且摘要、详情、日志都在抢占可视面积。

## Chosen Approach

采用固定三档宽度切换，而不是自由拖拽：

- `compact`
- `wide`
- `full`

宽度切换在阅读器层统一控制，右侧所有 tab 都共享同一布局模式。

这是最小但完整的方案：

- 用户认知简单
- 实现成本低于自由拖拽
- 思维导图、讲解、对话行为统一
- 后续仍可在此基础上加拖拽

## Layout Model

### Reader-Level State

在 [ArticleReader.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx) 中新增：

- `assistantPanelMode = "compact" | "wide" | "full"`

默认值：

- 首版默认 `compact`

建议持久化到本地 `localStorage`，避免每次重新打开文章都回到默认值。

### Width Behavior

三档模式的目标比例：

- `compact`
  - 左侧阅读区约 `64%`
  - 右侧助手栏约 `36%`
- `wide`
  - 左侧阅读区约 `36%`
  - 右侧助手栏约 `64%`
- `full`
  - 左侧阅读区隐藏
  - 右侧助手栏占满整个内容区

实现上不需要严格数学意义上的三等分，只要视觉上形成明显的：

- 紧凑
- 放大
- 全屏

三种模式即可。

## Control Placement

布局切换按钮放在右侧助手栏顶部 tab 区域，同 `讲解 / 思维导图 / 对话` 并列但视觉弱一层。

推荐形式：

- `1/3`
- `2/3`
- `全屏`

交互要求：

- 始终可见
- 当前模式高亮
- 切换无页面跳转
- 采用轻量过渡动画

## Mind Map Responsive Behavior

### Compact

`compact` 下目标是“尽量把空间留给脑图本体”：

- 顶部摘要卡更紧凑，减少留白
- 指标卡从 3 列改成 1 列或 2 列紧凑栅格
- 节点详情默认折叠
- Agent 日志默认折叠
- 脑图画布占主视觉区域

### Wide

`wide` 下保留当前信息结构，但优化占比：

- 摘要卡高度收缩
- 指标卡保留 3 列
- 节点详情默认展开
- 日志保留在底部，但不放大

### Full

`full` 下脑图应成为主内容：

- 顶部保留 tab 与布局切换
- 摘要卡和统计信息继续展示，但缩成浅层头部
- Mind Elixir 画布显著增大
- 节点详情改为侧边浮层或可折叠信息区
- Agent 日志默认折叠，只在需要时展开

## Component Changes

### ArticleReader

修改 [ArticleReader.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx)：

- 新增 `assistantPanelMode` 状态
- 新增顶部三档切换按钮
- 用模式控制左栏/右栏容器宽度与显隐
- 透传 `panelMode` 给 [ArticleMindMapPanel.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.tsx)

### ArticleMindMapPanel

修改 [ArticleMindMapPanel.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleMindMapPanel.tsx)：

- 新增 `panelMode` prop
- 根据 `panelMode` 调整：
  - 头部卡片布局
  - 指标卡栅格
  - 画布高度
  - 节点详情是否折叠
  - 日志是否折叠

首版不做复杂抽屉系统，只做：

- `compact`：详情与日志折叠
- `wide/full`：详情展开，日志可折叠

## Error Handling

如果本地模式值异常或缺失：

- 回退到 `compact`

如果用户切到 `full` 时没有右侧内容：

- 仍保留空态，而不是自动切回

## Testing Strategy

### ArticleReader Tests

需要补充：

- 默认模式渲染
- 切换到 `wide`
- 切换到 `full`
- `full` 时左侧阅读区隐藏
- 模式切换按钮高亮

### Mind Map Panel Tests

需要补充：

- `compact` 时详情/日志折叠
- `wide` 时正常展开
- `full` 时画布使用更大高度

## Out of Scope

本次不做：

- 拖拽分栏
- 每个 tab 独立记忆宽度
- 复杂浮层动画
- 讲解 / 对话各自的专属响应式重构

## Recommendation Summary

首版采用“阅读器层三档模式 + 思维导图面板响应式降级”的组合：

- 结构清晰
- 实现风险低
- 能直接解决 1/3 状态过挤的问题
- 给后续拖拽分栏留下演进空间
