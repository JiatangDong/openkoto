import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { LocalSubtitleImportForm } from "./LocalSubtitleImportForm";

const invokeMock = vi.fn();
const openMock = vi.fn();

vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));

vi.mock("@tauri-apps/plugin-dialog", () => ({
  open: (...args: unknown[]) => openMock(...args),
}));

describe("Local subtitle import form", () => {
  beforeEach(() => {
    invokeMock.mockReset();
    openMock.mockReset();
    invokeMock.mockResolvedValue({ id: "article-1" });
  });

  afterEach(() => {
    cleanup();
  });

  it("imports a standalone srt file with an optional title", async () => {
    openMock.mockResolvedValue("/tmp/lesson.srt");

    render(<LocalSubtitleImportForm onCancel={() => {}} />);

    const user = userEvent.setup();
    await user.click(screen.getByRole("button", { name: /select subtitle file|选择字幕文件/i }));
    await user.type(
      screen.getByPlaceholderText(/leave empty to use the file name|留空则使用文件名/i),
      "Lesson Title"
    );
    await user.click(screen.getByRole("button", { name: /import|导入/i }));

    expect(invokeMock).toHaveBeenCalledWith("import_srt_file_cmd", {
      filePath: "/tmp/lesson.srt",
      title: "Lesson Title",
    });
  });
});
