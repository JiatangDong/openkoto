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
  {
    id: "custom.hidden",
    kind: "quick_action",
    name: "Hidden",
    description: "",
    prompt_template: "Hidden {text}",
    requires_selection: true,
    show_in_quick_actions: false,
    icon: "sparkles",
    sort_order: 5,
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
