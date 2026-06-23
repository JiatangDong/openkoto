import { afterEach, describe, expect, it, vi } from "vitest";

const invokeMock = vi.fn();
vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));

import { getExtension, isSupportedDropPath, importDroppedPath } from "./dropImport";

describe("dropImport", () => {
  afterEach(() => invokeMock.mockReset());

  it("extracts lowercased extension from path", () => {
    expect(getExtension("/a/b/My File.MP4")).toBe("mp4");
    expect(getExtension("C:\\x\\book.EPUB")).toBe("epub");
    expect(getExtension("/no/ext")).toBe("");
  });

  it("recognizes supported extensions", () => {
    expect(isSupportedDropPath("/x/a.pdf")).toBe(true);
    expect(isSupportedDropPath("/x/a.mp3")).toBe(true);
    expect(isSupportedDropPath("/x/a.srt")).toBe(true);
    expect(isSupportedDropPath("/x/a.png")).toBe(false);
  });

  it("routes by extension to the right import command", async () => {
    invokeMock.mockResolvedValue({ id: "1" });

    await importDroppedPath("/x/book.pdf");
    expect(invokeMock).toHaveBeenCalledWith("import_book_cmd", { filePath: "/x/book.pdf", title: null });

    await importDroppedPath("/x/movie.mkv");
    expect(invokeMock).toHaveBeenCalledWith("import_local_video_cmd", { filePath: "/x/movie.mkv" });

    await importDroppedPath("/x/song.m4a");
    expect(invokeMock).toHaveBeenCalledWith("import_local_video_cmd", { filePath: "/x/song.m4a" });

    await importDroppedPath("/x/subs.srt");
    expect(invokeMock).toHaveBeenCalledWith("import_srt_file_cmd", { filePath: "/x/subs.srt", title: null });
  });

  it("throws unsupported:<name> for unknown types", async () => {
    await expect(importDroppedPath("/x/image.png")).rejects.toThrow("unsupported:image.png");
    expect(invokeMock).not.toHaveBeenCalled();
  });
});
