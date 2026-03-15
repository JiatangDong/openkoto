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
    .sort((left, right) => left.sort_order - right.sort_order || left.name.localeCompare(right.name));
}

export function renderPromptTemplate(template: string, context: PromptTemplateContext) {
  return template.replace(/\{([a-z_]+)\}/g, (_match, key: keyof PromptTemplateContext) => context[key] ?? "");
}
