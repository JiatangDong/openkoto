import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

import { AssistantSidebarShell } from "./AssistantSidebarShell";

const localStorageStore = new Map<string, string>();

describe("AssistantSidebarShell", () => {
  beforeEach(() => {
    localStorageStore.clear();
    Object.defineProperty(window, "localStorage", {
      value: {
        getItem: (key: string) => localStorageStore.get(key) ?? null,
        setItem: (key: string, value: string) => {
          localStorageStore.set(key, value);
        },
        removeItem: (key: string) => {
          localStorageStore.delete(key);
        },
      },
      configurable: true,
    });
  });

  afterEach(() => {
    cleanup();
  });

  it("renders tabs and switches assistant layout modes with persistence", async () => {
    render(
      <AssistantSidebarShell
        storageKey="test-assistant-mode"
        tabs={[
          { value: "mind_map", label: "思维导图", content: <div>Mind Map Content</div> },
          { value: "chat", label: "对话", content: <div>Chat Content</div> },
        ]}
        defaultTab="mind_map"
        mainContent={<div>Main Content</div>}
      />,
    );

    const shell = screen.getByTestId("assistant-sidebar-shell");
    const mainPane = screen.getByTestId("assistant-sidebar-main-pane");
    const assistantPane = screen.getByTestId("assistant-sidebar-pane");

    expect(shell).toHaveAttribute("data-assistant-mode", "compact");
    expect(mainPane).toHaveAttribute("data-hidden", "false");
    expect(assistantPane).toHaveAttribute("data-assistant-mode", "compact");
    expect(screen.getByText("Mind Map Content")).toBeInTheDocument();

    await userEvent.click(screen.getByRole("button", { name: "对话" }));
    expect(screen.getByText("Chat Content")).toBeInTheDocument();

    await userEvent.click(screen.getByRole("button", { name: "2/3" }));
    expect(shell).toHaveAttribute("data-assistant-mode", "wide");
    expect(assistantPane).toHaveAttribute("data-assistant-mode", "wide");
    expect(window.localStorage.getItem("test-assistant-mode")).toBe("wide");

    await userEvent.click(screen.getByRole("button", { name: "全屏" }));
    expect(shell).toHaveAttribute("data-assistant-mode", "full");
    expect(mainPane).toHaveAttribute("data-hidden", "true");
    expect(assistantPane).toHaveAttribute("data-assistant-mode", "full");
    expect(window.localStorage.getItem("test-assistant-mode")).toBe("full");
  });

  it("restores the persisted layout mode on mount", () => {
    localStorageStore.set("test-assistant-mode", "wide");

    render(
      <AssistantSidebarShell
        storageKey="test-assistant-mode"
        tabs={[
          { value: "mind_map", label: "思维导图", content: <div>Mind Map Content</div> },
          { value: "chat", label: "对话", content: <div>Chat Content</div> },
        ]}
        defaultTab="chat"
        mainContent={<div>Main Content</div>}
      />,
    );

    expect(screen.getByTestId("assistant-sidebar-shell")).toHaveAttribute("data-assistant-mode", "wide");
    expect(screen.getByText("Chat Content")).toBeInTheDocument();
  });

  it("keeps the assistant pane stretchable inside nested flex layouts", async () => {
    render(
      <AssistantSidebarShell
        storageKey="test-assistant-mode"
        tabs={[
          { value: "mind_map", label: "思维导图", content: <div>Mind Map Content</div> },
          { value: "chat", label: "对话", content: <div>Chat Content</div> },
        ]}
        defaultTab="chat"
        mainContent={<div>Main Content</div>}
      />,
    );

    const shell = screen.getByTestId("assistant-sidebar-shell");
    const mainPane = screen.getByTestId("assistant-sidebar-main-pane");
    const assistantPane = screen.getByTestId("assistant-sidebar-pane");
    const activeTabContent = screen.getByText("Chat Content").parentElement;

    expect(shell.className).toContain("min-h-0");
    expect(mainPane.className).toContain("min-h-0");
    expect(assistantPane.className).toContain("min-h-0");
    expect(activeTabContent?.className).toContain("min-h-0");
  });
});
