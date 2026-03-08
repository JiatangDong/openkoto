import { renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { useAgentOpenMaterialListener } from "./useAgentOpenMaterialListener";

const listenMock = vi.fn();
let capturedHandler: ((event: { payload: { materialId: string } }) => void) | null = null;

vi.mock("@tauri-apps/api/event", () => ({
  listen: (...args: unknown[]) => listenMock(...args),
}));

describe("useAgentOpenMaterialListener", () => {
  beforeEach(() => {
    capturedHandler = null;
    listenMock.mockReset();
    listenMock.mockImplementation(async (_eventName: string, handler: typeof capturedHandler) => {
      capturedHandler = handler;
      return () => {};
    });
  });

  afterEach(() => {
    vi.clearAllMocks();
  });

  it("calls onOpenMaterial when the app emits agent://open-material", async () => {
    const onOpenMaterial = vi.fn();

    renderHook(() => useAgentOpenMaterialListener(onOpenMaterial));

    expect(listenMock).toHaveBeenCalledWith("agent://open-material", expect.any(Function));

    capturedHandler?.({ payload: { materialId: "article-2" } });

    expect(onOpenMaterial).toHaveBeenCalledWith("article-2");
  });
});
