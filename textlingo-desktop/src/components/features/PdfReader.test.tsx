import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useEffect } from "react";

import { PdfReader } from "./PdfReader";

const invokeMock = vi.fn();

vi.mock("@tauri-apps/api/core", () => ({
  invoke: (...args: unknown[]) => invokeMock(...args),
}));

vi.mock("react-pdf", () => ({
  pdfjs: {
    GlobalWorkerOptions: {
      workerSrc: "",
    },
  },
  Document: ({
    children,
    onLoadSuccess,
  }: {
    children: React.ReactNode;
    onLoadSuccess?: ({ numPages }: { numPages: number }) => void;
  }) => {
    useEffect(() => {
      onLoadSuccess?.({ numPages: 5 });
    }, [onLoadSuccess]);

    return <div data-testid="pdf-document">{children}</div>;
  },
  Page: ({ pageNumber }: { pageNumber: number }) => <div data-testid="pdf-page">Page {pageNumber}</div>,
}));

vi.mock("./BookmarkSidebar", () => ({
  BookmarkSidebar: () => null,
}));

describe("PdfReader", () => {
  beforeEach(() => {
    invokeMock.mockReset();
    Object.defineProperty(window, "localStorage", {
      value: {
        getItem: vi.fn(() => null),
        setItem: vi.fn(),
        removeItem: vi.fn(),
      },
      configurable: true,
    });
  });

  afterEach(() => {
    cleanup();
  });

  it("anchors the next-page button to the reader container instead of the window edge", async () => {
    render(<PdfReader bookPath="http://127.0.0.1/test.pdf" title="Test PDF" />);

    const nextButton = await screen.findByTitle("下一页");

    expect(nextButton.className).not.toContain("fixed");
    expect(nextButton.className).toContain("absolute");
  });

  it("changes pages when the user scrolls the mouse wheel over the reader", async () => {
    render(<PdfReader bookPath="http://127.0.0.1/test.pdf" title="Test PDF" />);

    await waitFor(() => {
      expect(screen.getByText("1/5")).toBeInTheDocument();
    });

    const contentArea = screen.getByTitle("下一页").parentElement;
    expect(contentArea).not.toBeNull();

    fireEvent.wheel(contentArea as HTMLElement, { deltaY: 100 });
    expect(screen.getByText("2/5")).toBeInTheDocument();

    fireEvent.wheel(contentArea as HTMLElement, { deltaY: -100 });
    expect(screen.getByText("1/5")).toBeInTheDocument();
  });
});
