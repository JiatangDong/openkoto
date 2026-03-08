# Agent Kimi Runtime And Markdown Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix agent-mode failures after switching to Kimi regional providers and render Markdown only inside assistant reply bubbles in the agent panel.

**Architecture:** Keep the fix local to the agent runtime path. Treat Kimi providers as OpenAI-compatible in both the Node worker and Rust runtime config resolution, using provider-specific default base URLs. In the React panel, render assistant replies with `react-markdown` while leaving all non-assistant text surfaces as plain text.

**Tech Stack:** React 19 + Vite + Vitest, Node agent worker, Rust + cargo tests, Tauri 2.

---

### Task 1: Add failing tests for runtime Kimi provider support

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/agent-worker/src/provider/resolveProvider.test.ts`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src-tauri/tests/agent_worker_test.rs`

**Step 1: Write the failing tests**

```ts
it("maps moonshot-cn to openai_compatible with the China base url", () => {
  const resolved = resolveRuntimeProvider({
    id: "cfg-kimi-cn",
    name: "Kimi CN",
    api_provider: "moonshot-cn",
    api_key: "secret",
    model: "kimi-k2-0711-preview",
    is_default: true,
  });

  expect(resolved.kind).toBe("openai_compatible");
  if (resolved.kind === "openai_compatible") {
    expect(resolved.baseUrl).toBe("https://api.moonshot.cn/v1");
  }
});
```

```rust
#[test]
fn resolve_runtime_provider_config_maps_kimi_to_openai_compatible() {
    let kimi = resolve_runtime_provider_config(&sample_model_config(
        "moonshot-cn",
        "kimi-k2-0711-preview",
        None,
    ));

    assert_eq!(serde_json::to_value(&kimi).unwrap()["kind"], "openai_compatible");
    assert_eq!(
        serde_json::to_value(&kimi).unwrap()["baseUrl"],
        "https://api.moonshot.cn/v1"
    );
}
```

**Step 2: Run tests to verify they fail**

Run: `cd /Users/rqq/TextLingo/textlingo-desktop && npm test -- agent-worker/src/provider/resolveProvider.test.ts`
Expected: FAIL because Kimi providers are currently unsupported.

Run: `cd /Users/rqq/TextLingo/textlingo-desktop/src-tauri && cargo test resolve_runtime_provider_config_maps_kimi_to_openai_compatible`
Expected: FAIL because Rust runtime config resolution does not yet support Kimi providers.

**Step 3: Write minimal implementation**

- Extend the TypeScript runtime provider resolver to recognize `moonshot`, `moonshot-cn`, and `moonshot-global`
- Extend the Rust runtime provider resolver with the same provider identities and default base URLs

**Step 4: Run tests to verify they pass**

Run: `cd /Users/rqq/TextLingo/textlingo-desktop && npm test -- agent-worker/src/provider/resolveProvider.test.ts`
Expected: PASS.

Run: `cd /Users/rqq/TextLingo/textlingo-desktop/src-tauri && cargo test resolve_runtime_provider_config_maps_kimi_to_openai_compatible`
Expected: PASS.

**Step 5: Commit**

```bash
git -C /Users/rqq/TextLingo add \
  textlingo-desktop/agent-worker/src/provider/resolveProvider.ts \
  textlingo-desktop/agent-worker/src/provider/resolveProvider.test.ts \
  textlingo-desktop/src-tauri/src/agent_worker.rs \
  textlingo-desktop/src-tauri/tests/agent_worker_test.rs
git -C /Users/rqq/TextLingo commit -m "fix: support kimi providers in agent runtime"
```

### Task 2: Add failing tests for assistant-only Markdown rendering

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/AgentPanel.test.tsx`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/AgentPanel.tsx`

**Step 1: Write the failing tests**

```tsx
it("renders markdown in assistant reply bubbles only", async () => {
  render(<AgentPanel articleId="article-1" articleTitle="Sample" targetLanguage="zh-CN" />);

  await userEvent.type(screen.getByPlaceholderText("让 AI 帮你操作软件"), "test");
  await userEvent.click(screen.getByRole("button", { name: "发送 Agent 消息" }));

  listenerMap.get("assistant-agent-result://task-1")?.({
    payload: {
      reply: "这是 **重点**\n\n- 第一项",
      action: null,
    },
  });

  expect(await screen.findByText("重点")).toBeInTheDocument();
  expect(screen.getByRole("list")).toBeInTheDocument();
});
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/rqq/TextLingo/textlingo-desktop && npm test -- src/components/features/AgentPanel.test.tsx`
Expected: FAIL because assistant replies are still rendered as plain text.

**Step 3: Write minimal implementation**

- Import `react-markdown` into `AgentPanel`
- Render assistant messages through Markdown
- Keep user messages and logs unchanged

**Step 4: Run test to verify it passes**

Run: `cd /Users/rqq/TextLingo/textlingo-desktop && npm test -- src/components/features/AgentPanel.test.tsx`
Expected: PASS.

**Step 5: Commit**

```bash
git -C /Users/rqq/TextLingo add \
  textlingo-desktop/src/components/features/AgentPanel.tsx \
  textlingo-desktop/src/components/features/AgentPanel.test.tsx
git -C /Users/rqq/TextLingo commit -m "feat: render markdown in agent assistant replies"
```

### Task 3: Run focused regression verification

**Files:**
- Modify: none

**Step 1: Run the focused frontend tests**

Run: `cd /Users/rqq/TextLingo/textlingo-desktop && npm test -- src/components/features/AgentPanel.test.tsx agent-worker/src/provider/resolveProvider.test.ts`
Expected: PASS.

**Step 2: Run the focused Rust tests**

Run: `cd /Users/rqq/TextLingo/textlingo-desktop/src-tauri && cargo test resolve_runtime_provider_config`
Expected: PASS.

**Step 3: Search for stale hardcoded unsupported assumptions**

Run: `cd /Users/rqq/TextLingo && rg -n 'not supported for the agent runtime|moonshot-cn|moonshot-global' textlingo-desktop/agent-worker textlingo-desktop/src-tauri textlingo-desktop/src/components`
Expected: Only intentional unsupported paths remain.

**Step 4: Commit**

```bash
git -C /Users/rqq/TextLingo add -A
git -C /Users/rqq/TextLingo commit -m "test: verify agent kimi runtime and markdown rendering"
```
