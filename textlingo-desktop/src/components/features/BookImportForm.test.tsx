import { render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { BookImportForm } from "./BookImportForm";

const invokeMock = vi.fn();
const openMock = vi.fn();

vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));

vi.mock("@tauri-apps/plugin-dialog", () => ({
  open: (...args: unknown[]) => openMock(...args),
}));

describe("BookImportForm theme styling", () => {
  beforeEach(() => {
    invokeMock.mockReset();
    openMock.mockReset();
  });

  it("uses primary token styling for the import hint", () => {
    render(<BookImportForm />);

    const hint = screen
      .getByText("Supports papers, books, novels, etc...")
      .closest("div");

    expect(hint).not.toBeNull();
    expect(hint?.className).toContain("bg-primary/10");
    expect(hint?.className).toContain("border-primary/20");
    expect(hint?.className).not.toContain("bg-purple-500/10");
    expect(hint?.className).not.toContain("border-purple-500/20");
    expect(hint?.className).not.toContain("text-purple-200/90");
  });
});
