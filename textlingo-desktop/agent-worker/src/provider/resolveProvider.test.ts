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

  it("maps moonshot-cn to openai_compatible with the China base url", () => {
    const resolved = resolveRuntimeProvider({
      id: "cfg-4",
      name: "Kimi China",
      api_provider: "moonshot-cn",
      api_key: "secret",
      model: "kimi-k2-0711-preview",
      is_default: false,
    });

    expect(resolved.kind).toBe("openai_compatible");
    if (resolved.kind === "openai_compatible") {
      expect(resolved.baseUrl).toBe("https://api.moonshot.cn/v1");
    }
  });

  it("maps moonshot-global to openai_compatible with the global base url", () => {
    const resolved = resolveRuntimeProvider({
      id: "cfg-5",
      name: "Kimi Global",
      api_provider: "moonshot-global",
      api_key: "secret",
      model: "kimi-k2-0711-preview",
      is_default: false,
    });

    expect(resolved.kind).toBe("openai_compatible");
    if (resolved.kind === "openai_compatible") {
      expect(resolved.baseUrl).toBe("https://api.moonshot.ai/v1");
    }
  });

  it("maps deepseek to openai_compatible with the DeepSeek base url", () => {
    const resolved = resolveRuntimeProvider({
      id: "cfg-6",
      name: "DeepSeek",
      api_provider: "deepseek",
      api_key: "secret",
      model: "deepseek-chat",
      is_default: false,
    });

    expect(resolved.kind).toBe("openai_compatible");
    if (resolved.kind === "openai_compatible") {
      expect(resolved.baseUrl).toBe("https://api.deepseek.com/v1");
    }
  });

  it("maps siliconflow to openai_compatible with the SiliconFlow base url", () => {
    const resolved = resolveRuntimeProvider({
      id: "cfg-7",
      name: "SiliconFlow",
      api_provider: "siliconflow",
      api_key: "secret",
      model: "deepseek-ai/DeepSeek-V3",
      is_default: false,
    });

    expect(resolved.kind).toBe("openai_compatible");
    if (resolved.kind === "openai_compatible") {
      expect(resolved.baseUrl).toBe("https://api.siliconflow.cn/v1");
    }
  });

  it("maps 302ai to openai_compatible with the 302 base url", () => {
    const resolved = resolveRuntimeProvider({
      id: "cfg-8",
      name: "302.AI",
      api_provider: "302ai",
      api_key: "secret",
      model: "gpt-4o",
      is_default: false,
    });

    expect(resolved.kind).toBe("openai_compatible");
    if (resolved.kind === "openai_compatible") {
      expect(resolved.baseUrl).toBe("https://api.302.ai/v1");
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
