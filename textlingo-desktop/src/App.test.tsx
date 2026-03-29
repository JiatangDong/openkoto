import type { ButtonHTMLAttributes } from "react";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";

import App from "./App";

const invokeMock = vi.fn();
const getApiClientMock = vi.fn();

vi.stubGlobal("__APP_VERSION__", "test");

vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));

vi.mock("./components/features/ArticleList", () => ({
  ArticleList: () => <div>ArticleList</div>,
}));

vi.mock("./components/features/ArticleReader", () => ({
  ArticleReader: () => <div>ArticleReader</div>,
}));

vi.mock("./components/features/BookReader", () => ({
  BookReader: () => <div>BookReader</div>,
}));

vi.mock("./components/features/NewMaterialDialog", () => ({
  NewMaterialDialog: () => null,
}));

vi.mock("./components/features/FavoritesPage", () => ({
  FavoritesPage: () => <div>FavoritesPage</div>,
}));

vi.mock("./components/features/SettingsDialog", () => ({
  SettingsButton: () => <button type="button">settings</button>,
}));

vi.mock("./components/features/ApiQuickSwitcher", () => ({
  ApiQuickSwitcher: ({ onConfigChange }: { onConfigChange: () => void }) => (
    <button type="button" onClick={onConfigChange}>
      Reload Config
    </button>
  ),
}));

vi.mock("./components/features/UpdateChecker", () => ({
  UpdateChecker: () => null,
}));

vi.mock("./components/ui/button", () => ({
  Button: ({ children, ...props }: ButtonHTMLAttributes<HTMLButtonElement>) => (
    <button type="button" {...props}>
      {children}
    </button>
  ),
}));

vi.mock("./components/features/OnboardingDialog", () => ({
  OnboardingDialog: ({
    isOpen,
    onFinish,
  }: {
    isOpen: boolean;
    onFinish: () => void;
  }) =>
    isOpen ? (
      <div>
        <div>Onboarding Visible</div>
        <button type="button" onClick={onFinish}>
          Finish Onboarding
        </button>
      </div>
    ) : null,
}));

vi.mock("./lib/api", () => ({
  getApiClient: (...args: unknown[]) => getApiClientMock(...args),
}));

vi.mock("./lib/hooks/useAgentOpenMaterialListener", () => ({
  useAgentOpenMaterialListener: () => undefined,
}));

describe("App onboarding", () => {
  it("does not reopen onboarding in the same session after the user finishes it", async () => {
    const completedConfig = {
      onboarding_completed: true,
      active_model_id: undefined,
      model_configs: [],
      target_language: "zh-CN",
      interface_language: "en",
      prompt_features: [],
    };

    let configState: "missing" | "completed" = "missing";

    invokeMock.mockImplementation((command: string) => {
      if (command === "get_config") {
        return Promise.resolve(configState === "completed" ? completedConfig : null);
      }

      if (command === "list_articles_cmd") {
        return Promise.resolve([]);
      }

      throw new Error(`Unexpected command: ${command}`);
    });

    render(<App />);

    expect(await screen.findByText("Onboarding Visible")).toBeInTheDocument();

    configState = "completed";
    await userEvent.click(screen.getByRole("button", { name: "Finish Onboarding" }));

    await waitFor(() => {
      expect(screen.queryByText("Onboarding Visible")).not.toBeInTheDocument();
    });

    configState = "missing";
    await userEvent.click(screen.getByRole("button", { name: "Reload Config" }));

    await waitFor(() => {
      expect(screen.queryByText("Onboarding Visible")).not.toBeInTheDocument();
    });
  });
});
