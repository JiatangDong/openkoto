import { render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";

import { SettingsDialog } from "./SettingsDialog";

const invokeMock = vi.fn();

vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));

vi.mock("@tauri-apps/plugin-opener", () => ({
  openUrl: vi.fn(),
}));

vi.mock("react-i18next", () => ({
  useTranslation: () => ({
    t: (key: string, fallback?: string) => fallback ?? key,
    i18n: {
      language: "en",
      changeLanguage: vi.fn(),
    },
  }),
}));

vi.mock("../theme-provider", () => ({
  useTheme: () => ({
    themeName: "tokyo",
    themeMode: "light",
    setThemeName: vi.fn(),
    setThemeMode: vi.fn(),
  }),
}));

describe("SettingsDialog", () => {
  beforeEach(() => {
    invokeMock.mockReset();
    invokeMock.mockResolvedValue({
      model_configs: [],
      target_language: "zh-CN",
      interface_language: "en",
    });
  });

  it("does not render the plugin settings section", async () => {
    render(<SettingsDialog isOpen onClose={() => {}} />);

    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith("get_config");
    });

    expect(screen.queryByText("settings.plugins.title")).not.toBeInTheDocument();
  });
});
