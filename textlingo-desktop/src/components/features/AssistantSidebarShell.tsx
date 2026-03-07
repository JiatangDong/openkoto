import { ReactNode, useEffect, useState } from "react";

import { Tabs, TabsContent, TabsList, TabsTrigger } from "../ui/tabs";
import { Button } from "../ui/button";

export type AssistantPanelMode = "compact" | "wide" | "full";

export interface AssistantSidebarTab {
  value: string;
  label: string;
  content: ReactNode | ((context: { panelMode: AssistantPanelMode }) => ReactNode);
}

interface AssistantSidebarShellProps {
  storageKey: string;
  tabs: AssistantSidebarTab[];
  defaultTab: string;
  mainContent: ReactNode;
  headerContent?: ReactNode;
  showAssistant?: boolean;
  activeTab?: string;
  onTabChange?: (value: string) => void;
  shellTestId?: string;
  mainPaneTestId?: string;
  assistantPaneTestId?: string;
}

const layoutModes: { value: AssistantPanelMode; label: string }[] = [
  { value: "compact", label: "1/3" },
  { value: "wide", label: "2/3" },
  { value: "full", label: "全屏" },
];

export function AssistantSidebarShell({
  storageKey,
  tabs,
  defaultTab,
  mainContent,
  headerContent,
  showAssistant = true,
  activeTab,
  onTabChange,
  shellTestId = "assistant-sidebar-shell",
  mainPaneTestId = "assistant-sidebar-main-pane",
  assistantPaneTestId = "assistant-sidebar-pane",
}: AssistantSidebarShellProps) {
  const [assistantPanelMode, setAssistantPanelMode] = useState<AssistantPanelMode>(() => {
    if (typeof window === "undefined") {
      return "compact";
    }

    const saved = window.localStorage.getItem(storageKey);
    return saved === "wide" || saved === "full" ? saved : "compact";
  });
  const [internalActiveTab, setInternalActiveTab] = useState(defaultTab);
  const resolvedActiveTab = activeTab ?? internalActiveTab;

  useEffect(() => {
    window.localStorage.setItem(storageKey, assistantPanelMode);
  }, [assistantPanelMode, storageKey]);

  const effectivePanelMode = showAssistant ? assistantPanelMode : "compact";

  const mainPaneClass =
    showAssistant && effectivePanelMode === "full"
      ? "hidden"
      : effectivePanelMode === "wide"
        ? "basis-[36%] min-w-0 flex flex-col bg-background relative"
        : "basis-[64%] min-w-0 flex flex-col bg-background relative";

  const assistantPaneClass =
    effectivePanelMode === "full"
      ? "w-full min-w-0 overflow-hidden border-l-0 bg-card flex flex-col shrink-0 transition-all duration-300"
      : effectivePanelMode === "wide"
        ? "basis-[64%] min-w-0 overflow-hidden border-l border-border bg-card flex flex-col shrink-0 transition-all duration-300"
        : "basis-[36%] min-w-[360px] overflow-hidden border-l border-border bg-card flex flex-col shrink-0 transition-all duration-300";

  return (
    <div className="h-full flex overflow-hidden" data-testid={shellTestId} data-assistant-mode={effectivePanelMode}>
      <div
        className={mainPaneClass}
        data-testid={mainPaneTestId}
        data-hidden={showAssistant && effectivePanelMode === "full" ? "true" : "false"}
      >
        {mainContent}
      </div>

      {showAssistant ? (
        <div
          className={assistantPaneClass}
          data-testid={assistantPaneTestId}
          data-assistant-mode={effectivePanelMode}
        >
          <Tabs
            value={resolvedActiveTab}
            onValueChange={(value) => {
              setInternalActiveTab(value);
              onTabChange?.(value);
            }}
            className="flex-1 flex flex-col h-full overflow-hidden"
          >
            <div className="px-4 py-3 border-b border-border bg-card flex items-center gap-3">
              <TabsList className="flex-1">
                {tabs.map((tab) => (
                  <TabsTrigger key={tab.value} value={tab.value} className="flex-1">
                    {tab.label}
                  </TabsTrigger>
                ))}
              </TabsList>

              <div className="flex items-center gap-1 rounded-xl border border-border bg-card p-1">
                {layoutModes.map((mode) => (
                  <Button
                    key={mode.value}
                    variant={assistantPanelMode === mode.value ? "default" : "ghost"}
                    size="sm"
                    className="h-9 px-3"
                    onClick={() => setAssistantPanelMode(mode.value)}
                  >
                    {mode.label}
                  </Button>
                ))}
              </div>
            </div>

            {headerContent ? <div className="border-b border-border bg-card">{headerContent}</div> : null}

            {tabs.map((tab) => (
              <TabsContent key={tab.value} value={tab.value} className="flex-1 overflow-hidden mt-0">
                {typeof tab.content === "function" ? tab.content({ panelMode: effectivePanelMode }) : tab.content}
              </TabsContent>
            ))}
          </Tabs>
        </div>
      ) : null}
    </div>
  );
}
