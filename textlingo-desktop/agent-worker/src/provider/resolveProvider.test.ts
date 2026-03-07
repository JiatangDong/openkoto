import { describe, expect, it } from "vitest";

import { resolveRuntimeProvider } from "./resolveProvider.js";

describe("resolveRuntimeProvider", () => {
  it("maps google configs to native_google", () => {
    const resolved = resolveRuntimeProvider({
      id: "cfg-1",
      name: "Gemini",
      api_provider: "google",
      api_key: "secret",
      model: "gemini-2.0-flash-exp",
      is_default: true,
    });

    expect(resolved.kind).toBe("native_google");
  });

  it("maps openrouter to openai_compatible with a default base url", () => {
    const resolved = resolveRuntimeProvider({
      id: "cfg-2",
      name: "OpenRouter",
      api_provider: "openrouter",
      api_key: "secret",
      model: "openai/gpt-4o-mini",
      is_default: false,
    });

    expect(resolved.kind).toBe("openai_compatible");
    if (resolved.kind === "openai_compatible") {
      expect(resolved.baseUrl).toContain("openrouter.ai");
    }
  });

  it("marks unsupported providers with a reason", () => {
    const resolved = resolveRuntimeProvider({
      id: "cfg-3",
      name: "Unknown",
      api_provider: "weird-provider",
      api_key: "secret",
      model: "x-1",
      is_default: false,
    });

    expect(resolved.kind).toBe("unsupported");
    if (resolved.kind === "unsupported") {
      expect(resolved.reason).toMatch(/not supported/i);
    }
  });
});
