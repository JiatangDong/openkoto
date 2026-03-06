import { cleanup, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { vi, afterEach, beforeEach, describe, expect, it } from "vitest";
import { SelectPackDialog } from "./SelectPackDialog";

const invokeMock = vi.fn();

vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));

describe("SelectPackDialog", () => {
  beforeEach(() => {
    invokeMock.mockReset();
  });

  afterEach(() => {
    cleanup();
  });

  it("loads packs and confirms selected pack ids", async () => {
    invokeMock.mockImplementation((command: string) => {
      if (command === "list_word_packs_cmd") {
        return Promise.resolve([
          { id: "p1", name: "未分组", is_system: true },
          { id: "p2", name: "TOEFL", is_system: false },
        ]);
      }
      return Promise.resolve(null);
    });

    const onConfirm = vi.fn();
    const onOpenChange = vi.fn();

    render(
      <SelectPackDialog
        open
        onOpenChange={onOpenChange}
        onConfirm={onConfirm}
        initialSelectedPackIds={["p1"]}
      />
    );

    await screen.findByText("TOEFL");

    await userEvent.click(screen.getByLabelText("TOEFL"));
    await userEvent.click(screen.getByRole("button", { name: "确认" }));

    await waitFor(() => {
      expect(onConfirm).toHaveBeenCalledTimes(1);
      const selected = onConfirm.mock.calls[0][0] as string[];
      expect(selected).toContain("p1");
      expect(selected).toContain("p2");
    });
  });

  it("defaults to the system pack and closes on confirm or cancel", async () => {
    invokeMock.mockImplementation((command: string) => {
      if (command === "list_word_packs_cmd") {
        return Promise.resolve([
          { id: "p1", name: "未分组", is_system: true },
          { id: "p2", name: "TOEFL", is_system: false },
        ]);
      }
      return Promise.resolve(null);
    });

    const onConfirm = vi.fn();
    const onOpenChange = vi.fn();

    render(<SelectPackDialog open onOpenChange={onOpenChange} onConfirm={onConfirm} />);

    await screen.findByText("未分组");
    await userEvent.click(screen.getByRole("button", { name: "确认" }));

    await waitFor(() => {
      expect(onConfirm).toHaveBeenCalledWith(["p1"]);
      expect(onOpenChange).toHaveBeenCalledWith(false);
    });

    await userEvent.click(screen.getByRole("button", { name: "取消" }));
    expect(onOpenChange).toHaveBeenCalledWith(false);
  });

  it("creates a pack from enter key and handles empty state", async () => {
    invokeMock.mockImplementation((command: string, payload?: Record<string, unknown>) => {
      if (command === "list_word_packs_cmd") {
        return Promise.resolve([]);
      }
      if (command === "create_word_pack_cmd") {
        return Promise.resolve({
          id: "p3",
          name: payload?.name ?? "Core",
          is_system: false,
        });
      }
      return Promise.resolve(null);
    });

    const onConfirm = vi.fn();

    render(<SelectPackDialog open onOpenChange={() => {}} onConfirm={onConfirm} />);

    await screen.findByText("暂无合集");
    const input = screen.getByPlaceholderText("新建合集名称");
    await userEvent.type(input, "Core{Enter}");

    await waitFor(() => {
      expect(invokeMock).toHaveBeenCalledWith(
        "create_word_pack_cmd",
        expect.objectContaining({ name: "Core" })
      );
    });
    expect(screen.getByLabelText("Core")).toBeChecked();
  });
});
