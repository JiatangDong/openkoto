import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { fireEvent } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { OnboardingDialog } from "./OnboardingDialog";

const invokeMock = vi.fn();
const changeLanguageMock = vi.fn();

vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));

vi.mock("react-i18next", () => ({
  useTranslation: () => ({
    t: (key: string) => key,
    i18n: { language: "en", changeLanguage: changeLanguageMock },
  }),
}));

vi.mock("../theme-provider", () => ({
  useTheme: () => ({
    themeName: "seoul",
    themeMode: "light",
    setThemeName: vi.fn(),
    setThemeMode: vi.fn(),
  }),
}));

describe("OnboardingDialog local AI", () => {
  afterEach(() => {
    cleanup();
    invokeMock.mockReset();
    changeLanguageMock.mockReset();
  });

  it("saves an Ollama config from onboarding without requiring an API key", async () => {
    invokeMock.mockImplementation((command: string, payload?: Record<string, unknown>) => {
      if (command === "save_config_cmd") {
        return Promise.resolve("Configuration saved");
      }

      if (command === "save_model_config") {
        return Promise.resolve(payload?.config);
      }

      if (command === "set_active_model_config") {
        return Promise.resolve({ id: payload?.configId });
      }

      throw new Error(`Unexpected command: ${command}`);
    });

    const onFinish = vi.fn();
    render(<OnboardingDialog isOpen onFinish={onFinish} />);

    await userEvent.click(screen.getByRole("button", { name: "onboarding.next" }));
    await userEvent.click(screen.getByText("onboarding.model.localUser"));
    await userEvent.click(screen.getByText("Ollama"));

    fireEvent.change(screen.getByRole("combobox"), { target: { value: "__custom__" } });
    await userEvent.clear(screen.getByPlaceholderText("onboarding.model.localModelPlaceholder"));
    await userEvent.type(screen.getByPlaceholderText("onboarding.model.localModelPlaceholder"), "qwen2.5:7b");
    await userEvent.click(screen.getByRole("button", { name: "onboarding.next" }));
    await userEvent.click(screen.getByRole("button", { name: "onboarding.finish" }));

    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith(
        "save_model_config",
        expect.objectContaining({
          config: expect.objectContaining({
            api_provider: "ollama",
            api_key: "",
            name: "Ollama",
            model: "qwen2.5:7b",
            base_url: "http://localhost:11434/v1",
          }),
        }),
      );
    });

    expect(invokeMock).toHaveBeenCalledWith(
      "set_active_model_config",
      expect.objectContaining({
        configId: expect.any(String),
      }),
    );
    expect(onFinish).toHaveBeenCalled();
  });
});
