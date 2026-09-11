import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { VideoSubtitlePlayer } from "./VideoSubtitlePlayer";
import type { ArticleSegment } from "../../types";

const saveMock = vi.fn();
const invokeMock = vi.fn();
const localStorageStore = new Map<string, string>();

vi.mock("@tauri-apps/plugin-dialog", () => ({
  save: (...args: unknown[]) => saveMock(...args),
}));

vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));

function createSegment(overrides: Partial<ArticleSegment> = {}): ArticleSegment {
  return {
    id: "seg-1",
    article_id: "article-1",
    order: 0,
    text: "Alpha",
    translation: "Beta",
    reading_text: "Alpha reading",
    start_time: 0,
    end_time: 2,
    created_at: "2026-03-30T00:00:00Z",
    is_new_paragraph: true,
    ...overrides,
  };
}

describe("VideoSubtitlePlayer", () => {
  beforeEach(() => {
    saveMock.mockReset();
    invokeMock.mockReset();
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

    Object.defineProperty(HTMLMediaElement.prototype, "play", {
      configurable: true,
      value: vi.fn().mockResolvedValue(undefined),
    });
    Object.defineProperty(HTMLMediaElement.prototype, "pause", {
      configurable: true,
      value: vi.fn(),
    });
  });

  afterEach(() => {
    cleanup();
    vi.clearAllMocks();
  });

  it("renders the view mode control next to the subtitle list actions", () => {
    render(
      <VideoSubtitlePlayer
        videoUrl="http://localhost/video.mp4"
        segments={[createSegment()]}
        selectedSegmentId={null}
        onSegmentClick={vi.fn()}
        fontSize={18}
        viewMode="original"
        onViewModeChange={vi.fn()}
      />
    );

    expect(screen.getByTestId("player-view-mode-trigger")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "videoPlayer.showAllSubtitles (1)" })).toBeInTheDocument();
  });

  it("allows switching the player view mode from the subtitle action row", async () => {
    const onViewModeChange = vi.fn();

    render(
      <VideoSubtitlePlayer
        videoUrl="http://localhost/video.mp4"
        segments={[createSegment()]}
        selectedSegmentId={null}
        onSegmentClick={vi.fn()}
        fontSize={18}
        viewMode="original"
        onViewModeChange={onViewModeChange}
      />
    );

    await userEvent.click(screen.getByTestId("player-view-mode-trigger"));
    await userEvent.click(screen.getByRole("menuitem", { name: "articleReader.viewMode.bilingual" }));

    expect(onViewModeChange).toHaveBeenCalledWith("bilingual");
  });

  it("shows bilingual subtitle content when the view mode is switched", () => {
    render(
      <VideoSubtitlePlayer
        videoUrl="http://localhost/video.mp4"
        segments={[createSegment()]}
        selectedSegmentId={null}
        onSegmentClick={vi.fn()}
        fontSize={18}
        viewMode="bilingual"
      />
    );

    const video = document.querySelector("video");
    expect(video).not.toBeNull();

    if (video) {
      Object.defineProperty(video, "currentTime", {
        configurable: true,
        value: 1,
        writable: true,
      });
      fireEvent.timeUpdate(video);
    }

    expect(screen.getByText("Beta")).toBeInTheDocument();
  });

  function renderPlayingVideo(segments: ArticleSegment[]) {
    const onSegmentClick = vi.fn();
    render(
      <VideoSubtitlePlayer
        videoUrl="http://localhost/video.mp4"
        segments={segments}
        selectedSegmentId={null}
        onSegmentClick={onSegmentClick}
        fontSize={18}
        viewMode="original"
      />
    );

    const video = document.querySelector("video") as HTMLVideoElement;
    Object.defineProperty(video, "currentTime", {
      configurable: true,
      value: 1,
      writable: true,
    });
    Object.defineProperty(video, "paused", {
      configurable: true,
      value: false,
      writable: true,
    });
    fireEvent.timeUpdate(video);

    return { video, onSegmentClick };
  }

  it("toggles play/pause with the Space key", () => {
    const { video } = renderPlayingVideo([createSegment()]);

    fireEvent.keyDown(window, { key: " " });
    expect(video.pause).toHaveBeenCalledTimes(1);

    Object.defineProperty(video, "paused", { configurable: true, value: true });
    fireEvent.keyDown(window, { key: " " });
    expect(video.play).toHaveBeenCalled();
  });

  it("ignores keyboard shortcuts while typing in an input", () => {
    const { video } = renderPlayingVideo([createSegment()]);

    const input = document.createElement("input");
    document.body.appendChild(input);
    fireEvent.keyDown(input, { key: " " });
    input.remove();

    expect(video.pause).not.toHaveBeenCalled();
    expect(video.play).not.toHaveBeenCalled();
  });

  it("seeks to the next/previous subtitle sentence with Arrow keys", () => {
    const segments = [
      createSegment(),
      createSegment({ id: "seg-2", order: 1, text: "Gamma", start_time: 2, end_time: 4 }),
      createSegment({ id: "seg-3", order: 2, text: "Delta", start_time: 4, end_time: 6 }),
    ];
    const { video, onSegmentClick } = renderPlayingVideo(segments);

    fireEvent.keyDown(window, { key: "ArrowRight" });
    expect(onSegmentClick).toHaveBeenCalledWith("seg-2");
    expect(video.currentTime).toBe(2);

    // 模拟 seek 后媒体触发 timeupdate,组件内播放进度随之更新
    fireEvent.timeUpdate(video);

    fireEvent.keyDown(window, { key: "ArrowLeft" });
    expect(onSegmentClick).toHaveBeenLastCalledWith("seg-1");
    expect(video.currentTime).toBe(0);
  });

  it("pauses when clicking the currently playing subtitle instead of replaying it", () => {
    const { video, onSegmentClick } = renderPlayingVideo([createSegment()]);

    fireEvent.click(screen.getByText("Alpha"));

    expect(video.pause).toHaveBeenCalledTimes(1);
    expect(onSegmentClick).not.toHaveBeenCalled();
  });

  it("keeps seek-and-play behavior when clicking a different subtitle sentence", async () => {
    const segments = [
      createSegment(),
      createSegment({ id: "seg-2", order: 1, text: "Gamma", start_time: 2, end_time: 4 }),
    ];
    const { video, onSegmentClick } = renderPlayingVideo(segments);

    await userEvent.click(
      screen.getByRole("button", { name: "videoPlayer.showAllSubtitles (2)" })
    );
    fireEvent.click(screen.getByText("Gamma"));

    expect(onSegmentClick).toHaveBeenCalledWith("seg-2");
    expect(video.currentTime).toBe(2);
    expect(video.play).toHaveBeenCalled();
  });
});
