# Agent Kimi Runtime And Markdown Design

**Date:** 2026-03-08

## Goal

修复 agent 模式在切换到 `moonshot-cn` 或 `moonshot-global` 后因 provider 不被 runtime 支持而失败的问题，并为 agent 模式的 assistant 回复气泡增加 Markdown 渲染。

## Current Context

- 前端设置层已经支持 `moonshot-cn` / `moonshot-global`，相关归一化逻辑在 [textlingo-desktop/src/lib/kimiProvider.ts](/Users/rqq/TextLingo/textlingo-desktop/src/lib/kimiProvider.ts)。
- agent worker 的 TypeScript provider 解析仍只接受 `openai` / `openai-compatible` / `openrouter` / `ollama` / `lmstudio`，见 [textlingo-desktop/agent-worker/src/provider/resolveProvider.ts](/Users/rqq/TextLingo/textlingo-desktop/agent-worker/src/provider/resolveProvider.ts)。
- Tauri 侧 runtime provider 解析同样没有接入 Kimi provider，见 [textlingo-desktop/src-tauri/src/agent_worker.rs](/Users/rqq/TextLingo/textlingo-desktop/src-tauri/src/agent_worker.rs)。
- agent UI 的消息渲染在 [textlingo-desktop/src/components/features/AgentPanel.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/AgentPanel.tsx) 里仍是纯文本；同仓库 [textlingo-desktop/src/components/features/ArticleChatAssistant.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleChatAssistant.tsx) 已经使用 `react-markdown`。

## Recommended Approach

采用最小改动方案：

- 在 agent runtime 的 TS 与 Rust 两侧把 Kimi provider 识别为 `openai_compatible`
- 复用已有的 Kimi base URL 归一化规则，而不是重做一层新的 provider 抽象
- 只给 `AgentPanel` 中 `assistant` 角色的回复气泡增加 Markdown 渲染
- 用户消息、错误信息、工具日志、worker 日志继续保持纯文本

## Why This Approach

- 直接修复当前 bug 的根因，不扩散到设置页或非 agent 路径
- 与现有 Kimi provider split 设计保持一致，避免出现 UI 支持但 runtime 不支持的分叉
- Markdown 范围收窄到 assistant 回复，符合当前需求，也不会影响日志可读性

## Design Details

### Provider Resolution

- TypeScript worker 侧：
  - 在 `resolveRuntimeProvider` 中识别 `moonshot`、`moonshot-cn`、`moonshot-global`
  - 将其归类为 `openai_compatible`
  - 默认 `baseUrl` 分别指向：
    - `moonshot` / `moonshot-cn` -> `https://api.moonshot.cn/v1`
    - `moonshot-global` -> `https://api.moonshot.ai/v1`
- Rust 侧：
  - 在 `resolve_runtime_provider_config` 中加入相同 provider 识别
  - 输出 `RuntimeProviderConfig::OpenAiCompatible`
  - 维持 legacy `moonshot` 作为中国区别名

### UI Rendering

- 在 `AgentPanel` 引入 `react-markdown`
- `assistant` 消息气泡改为 Markdown 渲染
- `user` 消息仍按原样渲染纯文本
- 为 Markdown 内容补最少量样式类，保证列表、段落、行内代码、代码块在当前卡片内可读

### Testing

- TypeScript 单测：
  - 断言 `moonshot-cn` 与 `moonshot-global` 能解析为 `openai_compatible`
  - 断言默认 `baseUrl` 正确
- Rust 单测：
  - 断言 `moonshot-cn` 与 legacy `moonshot` 进入 `openai_compatible` 分支
  - 断言基础 URL 正确
- React 单测：
  - 断言 assistant 回复中的 Markdown 被渲染成对应 DOM
  - 断言 user 消息仍不走 Markdown 渲染

## Non-Goals

- 不做全局统一 provider registry
- 不改 agent 错误框和日志框的渲染策略
- 不引入 HTML 直出或更复杂的 Markdown 插件链
