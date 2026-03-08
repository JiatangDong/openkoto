import { useEffect } from "react";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export function useAgentOpenMaterialListener(onOpenMaterial: (materialId: string) => void) {
  useEffect(() => {
    let unlisten: UnlistenFn | undefined;

    void listen<{ materialId: string }>("agent://open-material", (event) => {
      onOpenMaterial(event.payload.materialId);
    }).then((fn) => {
      unlisten = fn;
    });

    return () => {
      unlisten?.();
    };
  }, [onOpenMaterial]);
}
