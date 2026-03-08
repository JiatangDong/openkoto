# Agent Mode MVP Design

**Date:** 2026-03-08

## Goal

在现有 OpenKoto 桌面端中新增一个可演进的 `Agent` 模式，同时保留当前右侧 Assistant 的高频快速问答能力。

第一阶段目标不是做“万能 AI”，而是做一个用户能立刻感知差异、技术链路可控、后续能持续扩展的最小版本：

- 右侧助手分成 `快问` 和 `Agent`
- `快问` 保持快速翻译/解释/问答体验
- `Agent` 通过 OpenCode runtime 调用极少量 App Tools
- 第一批工具只支持：
  - `get_current_material`
  - `list_materials`
  - `open_material`

## Product Decision

### Main entry

采用“双入口，但主入口在素材内右侧”的方案：

- **主入口**
  - 素材阅读页右侧助手
- **次入口**
  - 素材列表页的全局 Agent 入口

这样既不破坏当前阅读场景中的高频使用路径，也为后续跨素材任务保留扩展空间。

### Interaction mode split

右侧助手明确分成两档：

- `快问`
- `Agent`

不采用“一个智能助手内部自动判断快问还是 agent”的做法。原因：

- 简单翻译/解释应该保持单次模型调用，响应尽可能快
- Agent 模式天然包含额外的推理、工具选择和工具执行链路，速度通常更慢
- 如果让系统自动切换，用户会无法建立稳定预期

因此第一阶段必须明确产品边界：

- **快问**
  - 面向快响应
  - 主打翻译、解释、总结、语法、改写
  - 不走 agent runtime
- **Agent**
  - 面向“让 AI 调用软件能力”
  - 主打列出素材、查看当前素材、打开素材
  - 走 OpenCode runtime

## Current Project Context

当前项目已经具备搭建该能力的关键基础设施：

- React 侧已有统一右侧助手壳组件 [AssistantSidebarShell.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/AssistantSidebarShell.tsx)
- 文章页已用该壳组件组织 `讲解 / 思维导图 / 对话`，见 [ArticleReader.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx)
- 设置页已有统一模型配置体系，见 [SettingsDialog.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/SettingsDialog.tsx)
- Tauri 侧已经有 agent worker 管理器与 OpenCode 迁移方向，见 [agent_worker.rs](/Users/rqq/TextLingo/textlingo-desktop/src-tauri/src/agent_worker.rs) 和 [2026-03-07-opencode-agent-runtime-design.md](/Users/rqq/TextLingo/docs/plans/2026-03-07-opencode-agent-runtime-design.md)

这意味着第一阶段不需要新建第二套模型设置，也不需要另起一套独立 AI 页面。正确方向是在现有阅读器右侧助手上继续演进。

## Scope

### In Scope

- 右侧助手增加 `快问 / Agent` 一级模式切换
- `快问` 保留当前快问能力和模型设置来源
- 新增最小 `AgentPanel`
- Agent runtime 新增 `assistant.agent_turn` 任务类型
- 打通最小 App Tools：
  - `get_current_material`
  - `list_materials`
  - `open_material`
- `open_material` 成功后真正驱动前端切换到对应素材

### Out of Scope

- 不在第一阶段支持批量翻译落库
- 不在第一阶段支持生成试卷、题目解析、结构化教育任务
- 不在第一阶段支持复杂多任务调度
- 不在第一阶段支持通用全文检索或将素材全文暴露给 agent
- 不在第一阶段替换或重构思维导图任务链路

## Architecture

### Three-lane model

第一阶段应明确保留三条独立职责链：

- **Quick Ask lane**
  - 现有快速问答能力
  - 单次模型调用优先
  - 不使用 App Tools
- **Agent lane**
  - OpenCode runtime
  - 面向任务型交互
  - 可调用受控 App Tools
- **App Tools lane**
  - 由 Rust/Tauri 持有和执行
  - Worker 不直接读写前端状态，也不直接访问素材底层存储

### Why not unify execution path

不建议把 `快问` 和 `Agent` 合并到一条运行时：

- 快问的优化目标是低延迟
- Agent 的优化目标是任务成功率和可解释性
- 两者共享 UI 入口可以，但不应共享同一执行模型

## UI Design

### Reader sidebar structure

第一阶段保持 [AssistantSidebarShell.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/AssistantSidebarShell.tsx) 作为壳层，不在壳组件里塞业务逻辑。

新增一层模式切换：

- `快问`
- `Agent`

推荐层次：

1. 顶部第一层：`快问 | Agent`
2. 如果是 `快问`
   - 继续显示现有内容型 tab
   - 第一阶段最少保留 `讲解 / 对话`
3. 如果是 `Agent`
   - 不再显示内容型 tab
   - 直接渲染 `AgentPanel`

### Why Agent is not a peer tab

不建议直接把 `Agent` 做成和 `讲解 / 对话 / 思维导图` 平级的一个 tab。原因：

- `讲解 / 对话 / 思维导图` 是内容型能力
- `Agent` 是工作模式，不是单一内容页签
- 后续继续增加 App Tools 时，`Agent` 将承载更多任务型交互，和内容 tab 混在同一层会让信息架构失真

### Agent panel MVP

第一版 `AgentPanel` 只需要以下区块：

- 能力提示
  - 告诉用户当前只支持查看当前素材、列出素材、打开素材
- 消息流
- 输入框
- 执行状态条
  - 例如：`理解任务中 / 调用工具中 / 已完成`
- 最近工具调用记录

不做：

- 多任务管理器
- artifact 区
- 复杂计划树
- 高级日志面板

## App Tools Design

第一阶段只开放三个低风险工具。

### `get_current_material`

用于让 agent 知道当前打开素材是什么，返回最小元信息：

- `id`
- `title`
- `type`
- `created_at`
- `translated`

### `list_materials`

用于按极简单条件列出素材，不支持复杂 DSL 或全文检索。

建议输入：

- `keyword?`
- `type?`
- `limit?`

建议输出只包含素材概要信息：

- `id`
- `title`
- `type`
- `created_at`
- `translated`

第一阶段不要返回全文内容，避免把性能、token 成本和权限边界问题提前带进来。

### `open_material`

这是第一阶段唯一一个“会驱动 UI 行为”的工具。

输入：

- `material_id`

输出：

- `success`
- `opened_material_id`

同时在 Rust 层向前端 emit 一个事件，要求顶层页面真正切换到该素材，而不是只在 worker 内部记录“打开成功”。

## Runtime Design

### Task model

第一阶段不做“长期会话型 agent runtime”，而采用“单轮任务型 agent”：

- 前端每次发一条 Agent 消息
- Rust 发起一次 `agent.run`
- 任务类型为 `assistant.agent_turn`
- worker 产出这一轮的结果
- 前端自行维护消息历史

### Why single-turn first

这样做与现有 worker 架构更贴近，也更容易控制复杂度：

- 可以复用现有 `task.started / task.progress / task.log / task.result / task.error`
- 不必先设计长生命周期 session 管理
- 更容易诊断工具调用和任务失败

### Protocol extension

在现有 [protocol.ts](/Users/rqq/TextLingo/textlingo-desktop/agent-worker/src/protocol.ts) 基础上扩展 `agent.run` 输入，加入与 `assistant.agent_turn` 对应的输入结构：

- `user_message`
- `conversation`
- `ui_context`

其中 `ui_context` 至少包含：

- `current_article_id`
- `display_language`

第一阶段工具调用记录无需额外新增复杂事件类型，可直接复用：

- `task.log`
  - `source: "tool"`
  - `message: "calling list_materials(keyword=N1)"`

前端可据此渲染“工具记录区”。

## Frontend Data Flow

### Agent turn flow

1. 用户在 `AgentPanel` 输入消息
2. React 调用 Tauri command 发起一次 `assistant.agent_turn`
3. Rust 获取当前 active model config
4. Rust 将其归一化为 runtime provider config
5. Rust 启动或复用 OpenCode worker
6. worker 根据 prompt 判断是否调用工具
7. 工具执行通过 Rust bridge 回调
8. worker 生成最终自然语言回复
9. 前端显示：
   - 回复内容
   - 状态
   - 工具调用记录

### Open material flow

`open_material` 除了向 worker 返回工具结果，还要触发 UI 跳转：

1. tool 执行成功
2. Rust emit 事件，例如 `agent://open-material`
3. 顶层 [App.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/App.tsx) 监听该事件
4. App 复用现有文章选择逻辑切换到指定素材

这样可以保持：

- worker 不直接控制 React 状态
- Rust 仍是应用行为的受控入口

## Model Strategy

Agent 模式不应创建独立模型配置页面，应直接复用设置页中已有的用户模型配置。

但在产品层建议给不同模型增加能力认知：

- 适合快问
- 适合 Agent
- 实验性

第一阶段可以先不做复杂能力探测，但后续必须考虑：

- 并非所有 provider 都适合工具调用
- 并非所有模型都适合结构化输出

## Risks

### Boundary confusion

如果 `快问` 和 `Agent` 文案不清晰，用户会不知道何时该用哪个模式。第一阶段必须在 Agent 面板显式展示当前能力范围。

### Invisible success

如果 `open_material` 只在后端成功而前端没有实际切换，用户会认为 Agent 是假的。因此“真正打开素材”必须成为独立验收项。

### Runtime latency

如果第一版就引入长 session、复杂工具集合和过长上下文，Agent 首屏响应会明显变慢。单轮任务型设计是控制风险的关键。

### Overexposed content

如果过早让 Agent 读取大量全文内容，会立即引入上下文成本和权限边界问题。因此第一阶段工具仅提供素材概要能力。

## Acceptance Criteria

第一阶段满足以下四点即可视为 MVP 成功：

1. 用户可以在右侧助手切换 `快问 / Agent`
2. Agent 可以回答当前素材的基本信息
3. Agent 可以列出符合简单条件的素材
4. Agent 可以打开某个素材，且应用界面真实切换成功

## Recommendation

第一阶段应该严格聚焦在“清晰模式分层 + 极小工具集 + 真正驱动软件动作”这三件事上：

1. 保留 `快问` 的速度优势
2. 让 `Agent` 明确承担软件操作能力
3. 先用只读和低风险工具把链路跑通

只要这一步成立，后续再扩展：

- 批量翻译
- 上传题目解析
- 试卷生成
- 跨素材自动化任务

都会自然得多，也更容易持续演进。
