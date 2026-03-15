# Chat Prompt Features Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a persistent, user-editable prompt feature library for AI chat so default chat behavior and quick actions are config-driven and extensible.

**Architecture:** Extend Rust `AppConfig` with a `prompt_features` collection plus builtin-default merging so old configs upgrade safely. Keep one shared TypeScript prompt-feature model and helper layer for sorting, templating, and builtin reset behavior, then wire that into `SettingsDialog` and `ArticleChatAssistant`. Preserve the existing fast translation command path while moving the trigger surface to prompt-feature configuration.

**Tech Stack:** Tauri 2, Rust, React 19, TypeScript, Vitest, Testing Library

---

### Task 1: Add prompt feature schema and config migration in Rust

**Files:**
- Modify: `textlingo-desktop/src-tauri/src/types.rs`
- Modify: `textlingo-desktop/src-tauri/src/storage.rs`
- Test: `textlingo-desktop/src-tauri/tests/prompt_feature_config_test.rs`

**Step 1: Write the failing Rust config tests**

Create `textlingo-desktop/src-tauri/tests/prompt_feature_config_test.rs` with two integration tests:

```rust
use openkoto_desktop_lib::types::AppConfig;

#[test]
fn deserializing_old_config_injects_builtin_prompt_features() {
    let old_json = r#"{
        "onboarding_completed": true,
        "active_model_id": null,
        "model_configs": [],
        "target_language": "zh-CN",
        "interface_language": "en"
    }"#;

    let config: AppConfig = serde_json::from_str(old_json).expect("config should parse");

    assert!(config.prompt_features.iter().any(|item| item.id == "chat.default"));
    assert!(config.prompt_features.iter().any(|item| item.id == "selection.translate"));
    assert!(config.prompt_features.iter().any(|item| item.id == "selection.explain"));
    assert!(config.prompt_features.iter().any(|item| item.id == "selection.grammar"));
}

#[test]
fn merging_prompt_features_restores_missing_builtin_without_touching_custom_items() {
    let partial_json = r#"{
        "onboarding_completed": true,
        "active_model_id": null,
        "model_configs": [],
        "target_language": "zh-CN",
        "interface_language": "en",
        "prompt_features": [
            {
                "id": "custom.summary",
                "kind": "quick_action",
                "name": "Summary",
                "description": "Summarize selected text",
                "prompt_template": "Summarize: {text}",
                "requires_selection": true,
                "show_in_quick_actions": true,
                "icon": "sparkles",
                "sort_order": 99,
                "enabled": true,
                "is_builtin": false
            }
        ]
    }"#;

    let config: AppConfig = serde_json::from_str(partial_json).expect("config should parse");

    assert!(config.prompt_features.iter().any(|item| item.id == "custom.summary"));
    assert!(config.prompt_features.iter().any(|item| item.id == "chat.default"));
}
```

**Step 2: Run the test to verify it fails**

Run:

```bash
cargo test --manifest-path textlingo-desktop/src-tauri/Cargo.toml prompt_feature_config_test -- --nocapture
```

Expected:

- `FAIL`
- error mentions missing `prompt_features` field or missing `prompt_features` member on `AppConfig`

**Step 3: Write the minimal implementation**

In `textlingo-desktop/src-tauri/src/types.rs`:

- Add `PromptFeature` struct with the approved fields.
- Add helper constructors for builtin items.
- Add `default_prompt_features() -> Vec<PromptFeature>`.
- Add `merge_missing_builtin_prompt_features(features: Vec<PromptFeature>) -> Vec<PromptFeature>`.
- Add `prompt_features` to `AppConfig` with `#[serde(default = "default_prompt_features")]`.
- Update `Default for AppConfig` to include `prompt_features: default_prompt_features()`.

Minimal shape:

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

In `textlingo-desktop/src-tauri/src/storage.rs`:

- After deserializing `AppConfig`, normalize `config.prompt_features` through `merge_missing_builtin_prompt_features`.

**Step 4: Run the test to verify it passes**

Run:

```bash
cargo test --manifest-path textlingo-desktop/src-tauri/Cargo.toml prompt_feature_config_test -- --nocapture
```

Expected:

- `PASS`
- `2 passed`

**Step 5: Commit**

```bash
git add textlingo-desktop/src-tauri/src/types.rs textlingo-desktop/src-tauri/src/storage.rs textlingo-desktop/src-tauri/tests/prompt_feature_config_test.rs
git commit -m "feat: add prompt feature config defaults"
```

### Task 2: Add shared frontend prompt feature types and helper utilities

**Files:**
- Modify: `textlingo-desktop/src/lib/tauri.ts`
- Create: `textlingo-desktop/src/lib/promptFeatures.ts`
- Test: `textlingo-desktop/src/lib/promptFeatures.test.ts`

**Step 1: Write the failing helper tests**

Create `textlingo-desktop/src/lib/promptFeatures.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { getDefaultChatFeature, getVisibleQuickActions, renderPromptTemplate } from "./promptFeatures";

const features = [
  {
    id: "chat.default",
    kind: "chat_default",
    name: "Chat",
    description: "",
    prompt_template: "You are a tutor for {article_title}",
    requires_selection: false,
    show_in_quick_actions: false,
    icon: "sparkles",
    sort_order: 0,
    enabled: true,
    is_builtin: true,
  },
  {
    id: "custom.summary",
    kind: "quick_action",
    name: "Summary",
    description: "",
    prompt_template: "Summarize {text}",
    requires_selection: true,
    show_in_quick_actions: true,
    icon: "sparkles",
    sort_order: 10,
    enabled: true,
    is_builtin: false,
  },
];

describe("promptFeatures helpers", () => {
  it("returns the default chat feature by builtin id", () => {
    expect(getDefaultChatFeature(features)?.id).toBe("chat.default");
  });

  it("filters and sorts visible quick actions", () => {
    expect(getVisibleQuickActions(features).map((item) => item.id)).toEqual(["custom.summary"]);
  });

  it("renders known variables and blanks unknown ones", () => {
    expect(
      renderPromptTemplate("Explain {text} in {target_language}. {missing}", {
        text: "abc",
        target_language: "zh-CN",
      }),
    ).toBe("Explain abc in zh-CN. ");
  });
});
```

**Step 2: Run the test to verify it fails**

Run:

```bash
npm test -- --run textlingo-desktop/src/lib/promptFeatures.test.ts
```

Expected:

- `FAIL`
- module `./promptFeatures` does not exist or exported helpers are missing

**Step 3: Write the minimal implementation**

In `textlingo-desktop/src/lib/tauri.ts`:

- Export `PromptFeature` and add `prompt_features?: PromptFeature[]` to `AppConfig`.

Create `textlingo-desktop/src/lib/promptFeatures.ts` with:

```ts
import type { PromptFeature } from "./tauri";

export interface PromptTemplateContext {
  text?: string;
  user_input?: string;
  target_language?: string;
  source_language?: string;
  article_title?: string;
  current_segment?: string;
}

export function getDefaultChatFeature(features: PromptFeature[] = []) {
  return features.find((item) => item.id === "chat.default" && item.enabled);
}

export function getVisibleQuickActions(features: PromptFeature[] = []) {
  return [...features]
    .filter((item) => item.kind === "quick_action" && item.enabled && item.show_in_quick_actions)
    .sort((a, b) => a.sort_order - b.sort_order || a.name.localeCompare(b.name));
}

export function renderPromptTemplate(template: string, context: PromptTemplateContext) {
  return template.replace(/\{([a-z_]+)\}/g, (_match, key: keyof PromptTemplateContext) => context[key] ?? "");
}
```

Keep this helper layer pure so `SettingsDialog` and `ArticleChatAssistant` can reuse it.

**Step 4: Run the test to verify it passes**

Run:

```bash
npm test -- --run textlingo-desktop/src/lib/promptFeatures.test.ts
```

Expected:

- `PASS`
- `3 passed`

**Step 5: Commit**

```bash
git add textlingo-desktop/src/lib/tauri.ts textlingo-desktop/src/lib/promptFeatures.ts textlingo-desktop/src/lib/promptFeatures.test.ts
git commit -m "feat: add frontend prompt feature helpers"
```

### Task 3: Add prompt feature management UI to SettingsDialog

**Files:**
- Modify: `textlingo-desktop/src/components/features/SettingsDialog.tsx`
- Modify: `textlingo-desktop/src/locales/zh.json`
- Modify: `textlingo-desktop/src/locales/en.json`
- Modify: `textlingo-desktop/src/locales/ja.json`
- Test: `textlingo-desktop/src/components/features/SettingsDialog.test.tsx`

**Step 1: Write the failing settings dialog test**

Create `textlingo-desktop/src/components/features/SettingsDialog.test.tsx` with a focused config-editing case:

```tsx
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { SettingsDialog } from "./SettingsDialog";

const invokeMock = vi.fn();

vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));

vi.mock("react-i18next", () => ({
  useTranslation: () => ({
    t: (_key: string, fallback?: string) => fallback ?? _key,
    i18n: { language: "en", changeLanguage: vi.fn() },
  }),
}));

vi.mock("../theme-provider", () => ({
  useTheme: () => ({
    themeName: "default",
    themeMode: "light",
    setThemeName: vi.fn(),
    setThemeMode: vi.fn(),
  }),
}));

vi.mock("./PluginSettings", () => ({
  PluginSettings: () => null,
}));

it("saves edited prompt features with builtin reset-safe config payload", async () => {
  invokeMock.mockImplementation((command: string) => {
    if (command === "get_config") {
      return Promise.resolve({
        model_configs: [],
        target_language: "zh-CN",
        interface_language: "en",
        prompt_features: [
          {
            id: "chat.default",
            kind: "chat_default",
            name: "Chat",
            description: "Default chat",
            prompt_template: "You are a tutor",
            requires_selection: false,
            show_in_quick_actions: false,
            icon: "sparkles",
            sort_order: 0,
            enabled: true,
            is_builtin: true,
          },
        ],
      });
    }
    return Promise.resolve("ok");
  });

  render(<SettingsDialog isOpen onClose={vi.fn()} onSave={vi.fn()} />);

  await screen.findByText("AI Chat Features");
  await userEvent.click(screen.getByRole("button", { name: "Add feature" }));
  await userEvent.type(screen.getByLabelText("Feature name"), "Summary");
  await userEvent.type(screen.getByLabelText("Prompt template"), "Summarize {text}");
  await userEvent.click(screen.getByRole("button", { name: "Close" }));

  await waitFor(() => {
    expect(invokeMock).toHaveBeenCalledWith(
      "save_config_cmd",
      expect.objectContaining({
        config: expect.objectContaining({
          prompt_features: expect.arrayContaining([
            expect.objectContaining({ id: "chat.default" }),
            expect.objectContaining({ name: "Summary", prompt_template: "Summarize {text}" }),
          ]),
        }),
      }),
    );
  });
});
```

**Step 2: Run the test to verify it fails**

Run:

```bash
npm test -- --run textlingo-desktop/src/components/features/SettingsDialog.test.tsx
```

Expected:

- `FAIL`
- prompt-feature section labels or add-feature UI are missing

**Step 3: Write the minimal implementation**

In `textlingo-desktop/src/components/features/SettingsDialog.tsx`:

- Replace the local `AppConfig` shape with imports from `src/lib/tauri.ts`.
- Add local editing state for `prompt_features`.
- Render a new `AI 对话功能 / AI Chat Features` section before plugins.
- Support:
  - list existing features
  - add custom feature
  - edit fields inline or in a simple card form
  - toggle `enabled`
  - toggle `show_in_quick_actions`
  - reset builtin item to defaults
  - delete custom feature
- Save through existing `save_config_cmd`.

Prefer a small local editor instead of extracting a separate component in the first pass. The code should stay inside `SettingsDialog` unless the file becomes unmanageable.

In locale files:

- add labels for the section title
- add field labels and button text
- add validation copy

Suggested new keys under `settings.promptFeatures`:

```json
{
  "title": "AI Chat Features",
  "add": "Add feature",
  "name": "Feature name",
  "description": "Description",
  "template": "Prompt template",
  "requiresSelection": "Requires selection",
  "showInQuickActions": "Show in quick actions",
  "enabled": "Enabled",
  "icon": "Icon",
  "sortOrder": "Sort order",
  "resetBuiltin": "Reset to default",
  "deleteCustom": "Delete feature"
}
```

**Step 4: Run the test to verify it passes**

Run:

```bash
npm test -- --run textlingo-desktop/src/components/features/SettingsDialog.test.tsx
```

Expected:

- `PASS`
- `1 passed`

**Step 5: Commit**

```bash
git add textlingo-desktop/src/components/features/SettingsDialog.tsx textlingo-desktop/src/components/features/SettingsDialog.test.tsx textlingo-desktop/src/locales/zh.json textlingo-desktop/src/locales/en.json textlingo-desktop/src/locales/ja.json
git commit -m "feat: add prompt feature settings editor"
```

### Task 4: Make ArticleChatAssistant consume prompt features

**Files:**
- Modify: `textlingo-desktop/src/components/features/ArticleChatAssistant.tsx`
- Test: `textlingo-desktop/src/components/features/ArticleChatAssistant.test.tsx`

**Step 1: Write the failing assistant behavior tests**

Create `textlingo-desktop/src/components/features/ArticleChatAssistant.test.tsx`:

```tsx
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { ArticleChatAssistant } from "./ArticleChatAssistant";

const invokeMock = vi.fn();
const listenMock = vi.fn();

vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: (...args: unknown[]) => listenMock(...args),
}));

vi.mock("react-i18next", () => ({
  useTranslation: () => ({
    t: (_key: string, fallback?: string) => fallback ?? _key,
  }),
  Trans: ({ defaults }: { defaults: string }) => defaults,
}));

vi.mock("../../lib/api", () => ({
  getApiClient: () => ({
    isBackendConfigured: () => false,
  }),
}));

it("renders configured quick actions and uses the chat.default prompt for local chat", async () => {
  invokeMock.mockImplementation((command: string) => {
    if (command === "get_active_model_config") {
      return Promise.resolve({
        id: "model-1",
        name: "Test Model",
        model: "gpt-4o-mini",
        api_provider: "openai",
      });
    }
    if (command === "get_config") {
      return Promise.resolve({
        target_language: "zh-CN",
        interface_language: "en",
        model_configs: [],
        prompt_features: [
          {
            id: "chat.default",
            kind: "chat_default",
            name: "Chat",
            description: "",
            prompt_template: "You are a tutor for {article_title}",
            requires_selection: false,
            show_in_quick_actions: false,
            icon: "sparkles",
            sort_order: 0,
            enabled: true,
            is_builtin: true,
          },
          {
            id: "custom.summary",
            kind: "quick_action",
            name: "Summary",
            description: "",
            prompt_template: "Summarize {text}",
            requires_selection: true,
            show_in_quick_actions: true,
            icon: "sparkles",
            sort_order: 1,
            enabled: true,
            is_builtin: false,
          },
        ],
      });
    }
    if (command === "stream_chat_completion") {
      return Promise.resolve("ok");
    }
    return Promise.resolve(null);
  });

  listenMock.mockResolvedValue(() => {});

  render(
    <ArticleChatAssistant
      articleId="article-1"
      articleTitle="Demo Article"
      targetLanguage="zh-CN"
      selectedText="Selected text"
    />,
  );

  expect(await screen.findByRole("button", { name: "Summary" })).toBeInTheDocument();

  await userEvent.type(screen.getByPlaceholderText("Ask a question..."), "Help me");
  await userEvent.keyboard("{Enter}");

  await waitFor(() => {
    expect(invokeMock).toHaveBeenCalledWith(
      "stream_chat_completion",
      expect.objectContaining({
        request: expect.objectContaining({
          messages: expect.arrayContaining([
            expect.objectContaining({
              content: expect.stringContaining("You are a tutor for Demo Article"),
            }),
          ]),
        }),
      }),
    );
  });
});
```

**Step 2: Run the test to verify it fails**

Run:

```bash
npm test -- --run textlingo-desktop/src/components/features/ArticleChatAssistant.test.tsx
```

Expected:

- `FAIL`
- the configured quick action is not rendered or the streamed request does not include the configured default prompt

**Step 3: Write the minimal implementation**

In `textlingo-desktop/src/components/features/ArticleChatAssistant.tsx`:

- Load `AppConfig` with `get_config` during initialization.
- Replace the local hardcoded quick-action list with `getVisibleQuickActions(config.prompt_features)`.
- Build prompt context from:
  - `selectedText`
  - `input`
  - `targetLanguage`
  - `sourceLanguage`
  - `articleTitle`
  - `currentSegment`
- For local chat:
  - render `chat.default`
  - inject it as the leading instruction message before the user message
- For remote chat:
  - render the same prompt and prepend it to the message text until the backend grows first-class system prompt support
- Keep the special fast translation path for builtin translate by matching `id === "selection.translate"` or equivalent builtin action id.

Minimal runtime sketch:

```ts
const defaultChatFeature = getDefaultChatFeature(config?.prompt_features ?? []);
const systemPrompt = defaultChatFeature
  ? renderPromptTemplate(defaultChatFeature.prompt_template, context)
  : "";

if (systemPrompt) {
  requestMessages.unshift({ role: "system", content: systemPrompt } as any);
}
```

and for quick actions:

```ts
const actions = getVisibleQuickActions(config?.prompt_features ?? []);
```

**Step 4: Run the test to verify it passes**

Run:

```bash
npm test -- --run textlingo-desktop/src/components/features/ArticleChatAssistant.test.tsx
```

Expected:

- `PASS`
- `1 passed`

**Step 5: Commit**

```bash
git add textlingo-desktop/src/components/features/ArticleChatAssistant.tsx textlingo-desktop/src/components/features/ArticleChatAssistant.test.tsx
git commit -m "feat: drive chat assistant prompts from config"
```

### Task 5: Run focused regression checks and full targeted verification

**Files:**
- Modify: `textlingo-desktop/src/components/features/SettingsDialog.tsx` if required by regression fixes
- Modify: `textlingo-desktop/src/components/features/ArticleChatAssistant.tsx` if required by regression fixes
- Test: `textlingo-desktop/src/lib/promptFeatures.test.ts`
- Test: `textlingo-desktop/src/components/features/SettingsDialog.test.tsx`
- Test: `textlingo-desktop/src/components/features/ArticleChatAssistant.test.tsx`
- Test: `textlingo-desktop/src-tauri/tests/prompt_feature_config_test.rs`

**Step 1: Run the focused frontend test suite**

Run:

```bash
npm test -- --run textlingo-desktop/src/lib/promptFeatures.test.ts textlingo-desktop/src/components/features/SettingsDialog.test.tsx textlingo-desktop/src/components/features/ArticleChatAssistant.test.tsx
```

Expected:

- all targeted frontend tests `PASS`

**Step 2: Run the focused Rust test suite**

Run:

```bash
cargo test --manifest-path textlingo-desktop/src-tauri/Cargo.toml prompt_feature_config_test -- --nocapture
```

Expected:

- Rust prompt feature tests `PASS`

**Step 3: Run a type-level regression check**

Run:

```bash
npm run typecheck --prefix textlingo-desktop
```

Expected:

- exit code `0`
- no TypeScript errors

**Step 4: Fix any regressions with the smallest patch necessary**

If a regression appears:

- update only the affected file
- rerun only the failing command
- once green, rerun all three verification commands above

**Step 5: Commit**

```bash
git add textlingo-desktop/src/components/features/ArticleChatAssistant.tsx textlingo-desktop/src/components/features/SettingsDialog.tsx textlingo-desktop/src/lib/promptFeatures.ts textlingo-desktop/src/lib/tauri.ts textlingo-desktop/src-tauri/src/types.rs textlingo-desktop/src-tauri/src/storage.rs textlingo-desktop/src/components/features/ArticleChatAssistant.test.tsx textlingo-desktop/src/components/features/SettingsDialog.test.tsx textlingo-desktop/src/lib/promptFeatures.test.ts textlingo-desktop/src-tauri/tests/prompt_feature_config_test.rs textlingo-desktop/src/locales/zh.json textlingo-desktop/src/locales/en.json textlingo-desktop/src/locales/ja.json
git commit -m "feat: add configurable chat prompt features"
```
