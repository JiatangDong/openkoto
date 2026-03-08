# Agent Mode MVP Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a first-pass `快问 / Agent` split in the reader sidebar, with a minimal OpenCode-backed agent that can inspect the current material, list materials, and open a selected material in the app.

**Architecture:** Keep `快问` on the existing fast chat path and introduce a separate `Agent` execution lane. React owns sidebar mode and conversation state, Rust owns app tools and UI navigation events, and the Node worker owns agent orchestration plus tool selection through a small host/worker bridge.

**Tech Stack:** React 19 + Vite + Vitest, Tauri 2 + Rust tests, Node worker in `textlingo-desktop/agent-worker`, OpenCode SDK, i18next locales.

---

### Task 1: Add the Agent Sidebar Shell

**Files:**
- Create: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/AssistantModeSwitcher.tsx`
- Create: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/AgentPanel.tsx`
- Create: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/AgentPanel.test.tsx`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/locales/zh.json`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/locales/en.json`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/locales/ja.json`

**Step 1: Write the failing test**

```tsx
it("shows agent capability hints and an input box", () => {
  render(
    <AgentPanel
      articleId="article-1"
      articleTitle="Sample"
      targetLanguage="zh-CN"
      onSubmitTurn={vi.fn()}
    />,
  );

  expect(screen.getByText("查看当前素材")).toBeInTheDocument();
  expect(screen.getByText("列出素材")).toBeInTheDocument();
  expect(screen.getByText("打开素材")).toBeInTheDocument();
  expect(screen.getByPlaceholderText("让 AI 帮你操作软件")).toBeInTheDocument();
});
```

**Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/rqq/TextLingo/textlingo-desktop
npm test -- src/components/features/AgentPanel.test.tsx
```

Expected: FAIL with missing `AgentPanel` / `AssistantModeSwitcher` modules.

**Step 3: Write minimal implementation**

```tsx
export function AssistantModeSwitcher(props: {
  value: "quick" | "agent";
  onChange: (value: "quick" | "agent") => void;
}) {
  return (
    <div className="flex gap-1 rounded-xl border border-border bg-card p-1">
      <Button variant={props.value === "quick" ? "default" : "ghost"} onClick={() => props.onChange("quick")}>
        快问
      </Button>
      <Button variant={props.value === "agent" ? "default" : "ghost"} onClick={() => props.onChange("agent")}>
        Agent
      </Button>
    </div>
  );
}
```

```tsx
export function AgentPanel(...) {
  return (
    <div className="flex h-full flex-col">
      <div className="border-b border-border p-4 text-sm text-muted-foreground">
        <p>当前支持：查看当前素材 / 列出素材 / 打开素材</p>
      </div>
      <div className="flex-1 overflow-y-auto p-4" />
      <div className="border-t border-border p-4">
        <Input placeholder="让 AI 帮你操作软件" />
      </div>
    </div>
  );
}
```

**Step 4: Run test to verify it passes**

Run:

```bash
cd /Users/rqq/TextLingo/textlingo-desktop
npm test -- src/components/features/AgentPanel.test.tsx
```

Expected: PASS.

**Step 5: Commit**

```bash
git -C /Users/rqq/TextLingo add \
  textlingo-desktop/src/components/features/AssistantModeSwitcher.tsx \
  textlingo-desktop/src/components/features/AgentPanel.tsx \
  textlingo-desktop/src/components/features/AgentPanel.test.tsx \
  textlingo-desktop/src/locales/zh.json \
  textlingo-desktop/src/locales/en.json \
  textlingo-desktop/src/locales/ja.json
git -C /Users/rqq/TextLingo commit -m "feat: add agent sidebar shell"
```

### Task 2: Split the Reader Sidebar Into Quick and Agent Modes

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReader.tsx`
- Create: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/ArticleReaderAgentMode.test.tsx`
- Create: `/Users/rqq/TextLingo/textlingo-desktop/src/lib/hooks/useAgentOpenMaterialListener.ts`
- Create: `/Users/rqq/TextLingo/textlingo-desktop/src/lib/hooks/useAgentOpenMaterialListener.test.tsx`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/App.tsx`

**Step 1: Write the failing tests**

```tsx
it("switches the sidebar from quick tabs to the agent panel", async () => {
  render(<ArticleReader article={sampleArticle} />);

  expect(screen.getByRole("button", { name: "讲解" })).toBeInTheDocument();
  await userEvent.click(screen.getByRole("button", { name: "Agent" }));

  expect(screen.queryByRole("button", { name: "讲解" })).not.toBeInTheDocument();
  expect(screen.getByText("当前支持：查看当前素材 / 列出素材 / 打开素材")).toBeInTheDocument();
});
```

```tsx
it("calls onOpenMaterial when the app emits agent://open-material", async () => {
  const onOpenMaterial = vi.fn();
  mockListen("agent://open-material", { materialId: "article-2" });

  renderHook(() => useAgentOpenMaterialListener(onOpenMaterial));

  expect(onOpenMaterial).toHaveBeenCalledWith("article-2");
});
```

**Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/rqq/TextLingo/textlingo-desktop
npm test -- \
  src/components/features/ArticleReaderAgentMode.test.tsx \
  src/lib/hooks/useAgentOpenMaterialListener.test.tsx
```

Expected: FAIL because `ArticleReader` has no sidebar mode split and the listener hook does not exist.

**Step 3: Write minimal implementation**

```tsx
const [assistantMode, setAssistantMode] = useState<"quick" | "agent">("quick");

const quickTabs = [
  { value: "explanation", label: t("articleReader.explanation"), content: ... },
  { value: "chat", label: t("articleReader.chat"), content: ... },
];

const agentTabs = [
  {
    value: "agent",
    label: t("agent.mode"),
    content: <AgentPanel articleId={article.id} articleTitle={article.title} targetLanguage={targetLanguage} />,
  },
];
```

```ts
export function useAgentOpenMaterialListener(onOpenMaterial: (materialId: string) => void) {
  useEffect(() => {
    let unlisten: UnlistenFn | undefined;
    void listen<{ materialId: string }>("agent://open-material", (event) => {
      onOpenMaterial(event.payload.materialId);
    }).then((fn) => {
      unlisten = fn;
    });
    return () => {
      unlisten?.();
    };
  }, [onOpenMaterial]);
}
```

**Step 4: Run tests to verify they pass**

Run:

```bash
cd /Users/rqq/TextLingo/textlingo-desktop
npm test -- \
  src/components/features/ArticleReaderAgentMode.test.tsx \
  src/lib/hooks/useAgentOpenMaterialListener.test.tsx
```

Expected: PASS.

**Step 5: Commit**

```bash
git -C /Users/rqq/TextLingo add \
  textlingo-desktop/src/components/features/ArticleReader.tsx \
  textlingo-desktop/src/components/features/ArticleReaderAgentMode.test.tsx \
  textlingo-desktop/src/lib/hooks/useAgentOpenMaterialListener.ts \
  textlingo-desktop/src/lib/hooks/useAgentOpenMaterialListener.test.tsx \
  textlingo-desktop/src/App.tsx
git -C /Users/rqq/TextLingo commit -m "feat: split reader assistant into quick and agent modes"
```

### Task 3: Add Rust Host-Side Assistant Tool Types and Commands

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src-tauri/src/types.rs`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src-tauri/src/commands.rs`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src-tauri/src/lib.rs`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/lib/tauri.ts`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src-tauri/tests/commands_test.rs`

**Step 1: Write the failing Rust tests**

```rust
#[test]
fn material_summary_from_article_maps_book_and_media_types() {
    let article = Article {
        id: "article-1".into(),
        title: "N1 Reading".into(),
        content: "body".into(),
        source_type: Some("web".into()),
        book_type: Some("pdf".into()),
        translated: true,
        created_at: "2026-03-08T00:00:00Z".into(),
        ..sample_article_defaults()
    };

    let summary = material_summary_from_article(&article);

    assert_eq!(summary.material_type, "pdf");
    assert!(summary.translated);
}
```

```rust
#[test]
fn filter_material_summaries_applies_keyword_and_type() {
    let items = vec![
        sample_material_summary("1", "N1 PDF", "pdf"),
        sample_material_summary("2", "Podcast", "audio"),
    ];

    let result = filter_material_summaries(&items, Some("N1"), Some("pdf"), 20);

    assert_eq!(result.len(), 1);
    assert_eq!(result[0].id, "1");
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
cargo test --manifest-path /Users/rqq/TextLingo/textlingo-desktop/src-tauri/Cargo.toml --test commands_test
```

Expected: FAIL with missing helper functions and assistant tool structs.

**Step 3: Write minimal implementation**

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MaterialSummary {
    pub id: String,
    pub title: String,
    pub material_type: String,
    pub created_at: String,
    pub translated: bool,
}
```

```rust
pub fn material_summary_from_article(article: &Article) -> MaterialSummary {
    let material_type = article
        .book_type
        .clone()
        .or_else(|| article.source_type.clone())
        .unwrap_or_else(|| "article".to_string());

    MaterialSummary {
        id: article.id.clone(),
        title: article.title.clone(),
        material_type,
        created_at: article.created_at.clone(),
        translated: article.translated,
    }
}
```

```rust
#[tauri::command]
pub async fn run_agent_turn_cmd(...) -> Result<AgentTask, String> { ... }
```

Note:
- Add helper commands for current material and list filtering.
- Register the new commands in `src-tauri/src/lib.rs`.
- Mirror new types in `textlingo-desktop/src/lib/tauri.ts`.

**Step 4: Run tests to verify they pass**

Run:

```bash
cargo test --manifest-path /Users/rqq/TextLingo/textlingo-desktop/src-tauri/Cargo.toml --test commands_test
cd /Users/rqq/TextLingo/textlingo-desktop
npm test -- src/lib/tauri.ts
```

Expected: Rust tests PASS. The TypeScript type update has no direct test, so rely on later `npm run typecheck`.

**Step 5: Commit**

```bash
git -C /Users/rqq/TextLingo add \
  textlingo-desktop/src-tauri/src/types.rs \
  textlingo-desktop/src-tauri/src/commands.rs \
  textlingo-desktop/src-tauri/src/lib.rs \
  textlingo-desktop/src/lib/tauri.ts \
  textlingo-desktop/src-tauri/tests/commands_test.rs
git -C /Users/rqq/TextLingo commit -m "feat: add assistant tool host commands"
```

### Task 4: Extend the Worker Protocol for `assistant.agent_turn` and Host Tool Calls

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/agent-worker/src/protocol.ts`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/agent-worker/src/protocol.test.ts`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/agent-worker/src/runtime.ts`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/agent-worker/src/runtime.test.ts`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/agent-worker/src/index.ts`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/agent-worker/src/index.test.ts`
- Create: `/Users/rqq/TextLingo/textlingo-desktop/agent-worker/src/assistantTask.ts`
- Create: `/Users/rqq/TextLingo/textlingo-desktop/agent-worker/src/assistantTask.test.ts`

**Step 1: Write the failing worker tests**

```ts
it("parses an assistant.agent_turn request", () => {
  const request = parseAgentRunRequest(JSON.stringify({
    id: "req-1",
    type: "request",
    method: "agent.run",
    params: {
      task_id: "task-1",
      task_type: "assistant.agent_turn",
      provider_config: sampleProviderConfig,
      input: {
        user_message: "打开标题带 N1 的 PDF",
        conversation: [],
        ui_context: { current_article_id: "article-1", display_language: "zh-CN" },
      },
    },
  }));

  expect(request.params.task_type).toBe("assistant.agent_turn");
});
```

```ts
it("writes a tool log when the assistant task calls list_materials", async () => {
  const events: unknown[] = [];
  await executeAgentRunRequest(sampleAssistantRequest, {
    runAssistantTask: async (_, deps) => {
      deps.log?.("info", 'calling list_materials(keyword="N1")', "tool");
      return { reply: "找到 1 个素材" };
    },
    writeEvent: (event) => events.push(event),
  });

  expect(events.some((event) => JSON.stringify(event).includes("list_materials"))).toBe(true);
});
```

**Step 2: Run tests to verify they fail**

Run:

```bash
cd /Users/rqq/TextLingo/textlingo-desktop/agent-worker
npm test -- src/protocol.test.ts src/runtime.test.ts src/index.test.ts src/assistantTask.test.ts
```

Expected: FAIL because the protocol only accepts `mind_map.generate` and there is no assistant task implementation.

**Step 3: Write minimal implementation**

```ts
const assistantRunInputSchema = z.object({
  user_message: z.string().min(1),
  conversation: z.array(z.object({
    role: z.enum(["user", "assistant"]),
    content: z.string().min(1),
  })).default([]),
  ui_context: z.object({
    current_article_id: z.string().optional(),
    display_language: z.string().min(1),
  }),
});
```

```ts
if (request.params.task_type === "assistant.agent_turn") {
  return runAssistantTask(
    {
      taskId: request.params.task_id,
      userMessage: request.params.input.user_message,
      conversation: request.params.input.conversation,
      uiContext: request.params.input.ui_context,
    },
    deps,
  );
}
```

```ts
export async function runAssistantTask(input, deps) {
  deps.log?.("info", "starting assistant turn", "runtime");
  return {
    reply: "MVP reply placeholder",
    toolCalls: [],
  };
}
```

**Step 4: Run tests to verify they pass**

Run:

```bash
cd /Users/rqq/TextLingo/textlingo-desktop/agent-worker
npm test -- src/protocol.test.ts src/runtime.test.ts src/index.test.ts src/assistantTask.test.ts
```

Expected: PASS.

**Step 5: Commit**

```bash
git -C /Users/rqq/TextLingo add \
  textlingo-desktop/agent-worker/src/protocol.ts \
  textlingo-desktop/agent-worker/src/protocol.test.ts \
  textlingo-desktop/agent-worker/src/runtime.ts \
  textlingo-desktop/agent-worker/src/runtime.test.ts \
  textlingo-desktop/agent-worker/src/index.ts \
  textlingo-desktop/agent-worker/src/index.test.ts \
  textlingo-desktop/agent-worker/src/assistantTask.ts \
  textlingo-desktop/agent-worker/src/assistantTask.test.ts
git -C /Users/rqq/TextLingo commit -m "feat: add assistant agent turn runtime"
```

### Task 5: Bridge Host Tools Through the Rust Worker Manager

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src-tauri/src/agent_worker.rs`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src-tauri/tests/agent_worker_test.rs`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src-tauri/src/commands.rs`

**Step 1: Write the failing Rust tests**

```rust
#[test]
fn build_assistant_worker_request_serializes_conversation_and_ui_context() {
    let request = build_assistant_worker_request(
        &sample_assistant_task(),
        Some("article-1".to_string()),
        "打开最近的 PDF".to_string(),
        vec![],
        &sample_provider_config(),
    );

    assert_eq!(request["params"]["task_type"], "assistant.agent_turn");
    assert_eq!(request["params"]["input"]["ui_context"]["current_article_id"], "article-1");
}
```

```rust
#[test]
fn worker_tool_log_entries_are_preserved_for_agent_tasks() {
    let event = parse_worker_event_line(r#"{"type":"event","event":"task.log","payload":{"task_id":"task-1","level":"info","source":"tool","message":"calling list_materials(keyword=N1)","timestamp":"2026-03-08T00:00:00Z"}}"#).unwrap();

    let entry = worker_event_log_entry(&event).unwrap();

    assert!(entry.1.contains("list_materials"));
}
```

**Step 2: Run tests to verify they fail**

Run:

```bash
cargo test --manifest-path /Users/rqq/TextLingo/textlingo-desktop/src-tauri/Cargo.toml --test agent_worker_test
```

Expected: FAIL because there is no assistant request builder or host bridge for agent turns.

**Step 3: Write minimal implementation**

```rust
pub fn build_assistant_worker_request(
    task_id: &str,
    provider_config: &RuntimeProviderConfig,
    user_message: &str,
    conversation: &[AssistantConversationMessage],
    current_article_id: Option<&str>,
    display_language: &str,
) -> serde_json::Value {
    serde_json::json!({
        "id": task_id,
        "type": "request",
        "method": "agent.run",
        "params": {
            "task_id": task_id,
            "task_type": "assistant.agent_turn",
            "provider_config": provider_config,
            "input": {
                "user_message": user_message,
                "conversation": conversation,
                "ui_context": {
                    "current_article_id": current_article_id,
                    "display_language": display_language,
                }
            }
        }
    })
}
```

```rust
pub fn submit_assistant_turn(...) -> Result<(), String> {
    self.ensure_started(app_handle)?;
    let request = build_assistant_worker_request(...);
    writeln!(stdin, "{}", request)?;
    Ok(())
}
```

Note:
- Keep tool execution in Rust.
- Emit `agent://open-material` from Rust when the `open_material` tool succeeds.
- Reuse `task.log` with `source = tool` for the frontend activity feed.

**Step 4: Run tests to verify they pass**

Run:

```bash
cargo test --manifest-path /Users/rqq/TextLingo/textlingo-desktop/src-tauri/Cargo.toml --test agent_worker_test
```

Expected: PASS.

**Step 5: Commit**

```bash
git -C /Users/rqq/TextLingo add \
  textlingo-desktop/src-tauri/src/agent_worker.rs \
  textlingo-desktop/src-tauri/tests/agent_worker_test.rs \
  textlingo-desktop/src-tauri/src/commands.rs
git -C /Users/rqq/TextLingo commit -m "feat: bridge host tools into agent worker"
```

### Task 6: Wire `AgentPanel` to the New Command and Verify End-to-End

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/AgentPanel.tsx`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/components/features/AgentPanel.test.tsx`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/lib/tauri.ts`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src/App.tsx`

**Step 1: Write the failing integration-style frontend test**

```tsx
it("submits an agent turn and renders tool activity plus the assistant reply", async () => {
  mockInvoke("run_agent_turn_cmd", { task_id: "task-1" });
  mockTaskEvents([
    taskStarted("task-1"),
    taskLog("task-1", "tool", 'calling list_materials(keyword="N1")'),
    taskResult("task-1", { reply: "我找到了 1 个 PDF 素材" }),
  ]);

  render(<AgentPanel articleId="article-1" articleTitle="Sample" targetLanguage="zh-CN" />);

  await userEvent.type(screen.getByPlaceholderText("让 AI 帮你操作软件"), "找出标题带 N1 的 PDF");
  await userEvent.click(screen.getByRole("button", { name: "发送" }));

  expect(await screen.findByText("我找到了 1 个 PDF 素材")).toBeInTheDocument();
  expect(screen.getByText('calling list_materials(keyword="N1")')).toBeInTheDocument();
});
```

**Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/rqq/TextLingo/textlingo-desktop
npm test -- src/components/features/AgentPanel.test.tsx
```

Expected: FAIL because the panel is still a placeholder and does not submit turns or render runtime activity.

**Step 3: Write minimal implementation**

```tsx
const [messages, setMessages] = useState<AgentMessage[]>([]);
const [toolLogs, setToolLogs] = useState<string[]>([]);

const handleSubmit = async () => {
  const task = await invoke<AgentTask>("run_agent_turn_cmd", {
    articleId,
    userMessage: input,
    conversation: messages,
    displayLanguage: targetLanguage,
  });

  await subscribeToTask(task.id, {
    onLog: (line) => setToolLogs((prev) => [...prev, line]),
    onResult: (payload) => setMessages((prev) => [...prev, { role: "assistant", content: payload.reply }]),
  });
};
```

**Step 4: Run full verification**

Run:

```bash
cd /Users/rqq/TextLingo/textlingo-desktop
npm test -- \
  src/components/features/AgentPanel.test.tsx \
  src/components/features/ArticleReaderAgentMode.test.tsx \
  src/lib/hooks/useAgentOpenMaterialListener.test.tsx
npm run typecheck

cd /Users/rqq/TextLingo/textlingo-desktop/agent-worker
npm test -- src/protocol.test.ts src/runtime.test.ts src/index.test.ts src/assistantTask.test.ts
npm run typecheck

cargo test --manifest-path /Users/rqq/TextLingo/textlingo-desktop/src-tauri/Cargo.toml --test commands_test --test agent_worker_test
```

Expected:
- Frontend Vitest: PASS
- Frontend `typecheck`: PASS
- Worker Vitest + `typecheck`: PASS
- Rust tests: PASS

**Step 5: Commit**

```bash
git -C /Users/rqq/TextLingo add \
  textlingo-desktop/src/components/features/AgentPanel.tsx \
  textlingo-desktop/src/components/features/AgentPanel.test.tsx \
  textlingo-desktop/src/lib/tauri.ts \
  textlingo-desktop/src/App.tsx
git -C /Users/rqq/TextLingo commit -m "feat: wire reader agent panel to runtime"
```
