import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { MarkdownContent } from "./MarkdownContent";

describe("MarkdownContent", () => {
  it("renders GFM tables as semantic table elements", () => {
    const { container } = render(<MarkdownContent content={"| Item | Value |\n| --- | --- |\n| Level | N1 |"} />);

    const table = screen.getByRole("table");
    const scrollWrapper = table.parentElement;
    const levelCell = screen.getByRole("cell", { name: "N1" });

    expect(table).toBeInTheDocument();
    expect(screen.getByRole("columnheader", { name: "Item" })).toBeInTheDocument();
    expect(levelCell).toBeInTheDocument();
    expect(scrollWrapper).toHaveClass("overflow-x-auto");
    expect(scrollWrapper).toHaveClass("overscroll-x-contain");
    expect(scrollWrapper).toHaveClass("[-webkit-overflow-scrolling:touch]");
    expect(table).toHaveClass("w-max");
    expect(table).toHaveClass("min-w-full");
    expect(levelCell).toHaveClass("break-words");
    expect(levelCell).toHaveClass("whitespace-normal");
    expect(container.querySelector("td")).not.toBeNull();
  });
});
