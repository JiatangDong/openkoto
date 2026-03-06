import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { NewMaterialDialog } from "./NewMaterialDialog";

const invokeMock = vi.fn();
const openMock = vi.fn();

vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));

vi.mock("@tauri-apps/plugin-dialog", () => ({
  open: (...args: unknown[]) => openMock(...args),
}));

vi.mock("./NewArticleForm", () => ({
  NewArticleForm: () => <div>new article form</div>,
}));

vi.mock("./WebImportForm", () => ({
  WebImportForm: () => <div>web import form</div>,
}));

vi.mock("./BookImportForm", () => ({
  BookImportForm: () => <div>book import form</div>,
}));

vi.mock("./YouTubeImportForm", () => ({
  YouTubeImportForm: () => <div>youtube import form</div>,
}));

vi.mock("./LocalVideoImportForm", () => ({
  LocalVideoImportForm: () => <div>local video import form</div>,
}));

vi.mock("./LocalAudioImportForm", () => ({
  LocalAudioImportForm: () => <div>local audio import form</div>,
}));

describe("NewMaterialDialog theme styling", () => {
  beforeEach(() => {
    invokeMock.mockReset();
    openMock.mockReset();
    invokeMock.mockResolvedValue(null);
  });

  it("uses primary styling for each active material tab", async () => {
    render(<NewMaterialDialog isOpen onClose={() => {}} />);

    const user = userEvent.setup();
    const expectations = [
      { name: "newArticle.title", forbiddenClass: "text-blue-500" },
      { name: "网页导入", forbiddenClass: "text-blue-500" },
      { name: "导入书籍", forbiddenClass: "text-purple-500" },
      { name: "youtubeImport.title", forbiddenClass: "text-red-500" },
      { name: "localImport.title", forbiddenClass: "text-accent-foreground" },
      { name: "本地音频", forbiddenClass: "text-green-500" },
    ];

    for (const { name, forbiddenClass } of expectations) {
      const tab = screen.getByRole("button", { name });
      await user.click(tab);

      expect(tab.className).toContain("bg-primary/10");
      expect(tab.className).toContain("text-primary");
      expect(tab.className).not.toContain(forbiddenClass);
    }
  });
});
