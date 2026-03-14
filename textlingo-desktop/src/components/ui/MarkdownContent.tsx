import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

import { cn } from "../../lib/utils";

interface MarkdownContentProps {
  content: string;
  className?: string;
}

export function MarkdownContent({ content, className }: MarkdownContentProps) {
  return (
    <div
      className={cn(
        "max-w-none break-words [&>p]:mb-3 [&>p:last-child]:mb-0 [&>ul]:mb-3 [&>ul:last-child]:mb-0 [&>ol]:mb-3 [&>ol:last-child]:mb-0",
        className,
      )}
    >
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={{
          p: ({ className: nextClassName, children, ...props }) => (
            <p className={cn("leading-relaxed", nextClassName)} {...props}>
              {children}
            </p>
          ),
          ul: ({ className: nextClassName, children, ...props }) => (
            <ul className={cn("list-disc pl-5", nextClassName)} {...props}>
              {children}
            </ul>
          ),
          ol: ({ className: nextClassName, children, ...props }) => (
            <ol className={cn("list-decimal pl-5", nextClassName)} {...props}>
              {children}
            </ol>
          ),
          li: ({ className: nextClassName, children, ...props }) => (
            <li className={cn("mb-1", nextClassName)} {...props}>
              {children}
            </li>
          ),
          pre: ({ className: nextClassName, children, ...props }) => (
            <pre className={cn("mb-3 overflow-x-auto rounded-md bg-muted/60 p-3 last:mb-0", nextClassName)} {...props}>
              {children}
            </pre>
          ),
          code: ({ className: nextClassName, children, ...props }) =>
            nextClassName ? (
              <code className={cn("block font-mono text-xs", nextClassName)} {...props}>
                {children}
              </code>
            ) : (
              <code className="rounded bg-muted/80 px-1 py-0.5 font-mono text-[0.85em]" {...props}>
                {children}
              </code>
            ),
          table: ({ className: nextClassName, children, ...props }) => (
            <div className="my-3 overflow-x-auto overscroll-x-contain touch-pan-x [-webkit-overflow-scrolling:touch] last:mb-0">
              <table className={cn("min-w-full w-max table-auto border-collapse text-left text-sm", nextClassName)} {...props}>
                {children}
              </table>
            </div>
          ),
          thead: ({ className: nextClassName, children, ...props }) => (
            <thead className={cn("border-b border-border/80", nextClassName)} {...props}>
              {children}
            </thead>
          ),
          tbody: ({ className: nextClassName, children, ...props }) => (
            <tbody className={cn("[&_tr:last-child]:border-b-0", nextClassName)} {...props}>
              {children}
            </tbody>
          ),
          tr: ({ className: nextClassName, children, ...props }) => (
            <tr className={cn("border-b border-border/60", nextClassName)} {...props}>
              {children}
            </tr>
          ),
          th: ({ className: nextClassName, children, ...props }) => (
            <th
              className={cn(
                "bg-muted/40 px-3 py-2 font-semibold text-foreground whitespace-normal break-words [word-break:break-word]",
                nextClassName,
              )}
              {...props}
            >
              {children}
            </th>
          ),
          td: ({ className: nextClassName, children, ...props }) => (
            <td
              className={cn("px-3 py-2 align-top whitespace-normal break-words [word-break:break-word]", nextClassName)}
              {...props}
            >
              {children}
            </td>
          ),
        }}
      >
        {content}
      </ReactMarkdown>
    </div>
  );
}
