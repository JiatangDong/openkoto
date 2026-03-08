import { describe, expect, it } from "vitest";

import {
  getKimiBaseUrl,
  getKimiModelsUrl,
  isKimiProvider,
  normalizeKimiProvider,
} from "./kimiProvider";

describe("kimiProvider", () => {
  it("treats legacy moonshot as the China provider", () => {
    expect(normalizeKimiProvider("moonshot")).toBe("moonshot-cn");
    expect(isKimiProvider("moonshot")).toBe(true);
  });

  it("recognizes both explicit Kimi providers", () => {
    expect(isKimiProvider("moonshot-cn")).toBe(true);
    expect(isKimiProvider("moonshot-global")).toBe(true);
    expect(isKimiProvider("openai")).toBe(false);
  });

  it("returns the official regional base URLs", () => {
    expect(getKimiBaseUrl("moonshot-cn")).toBe("https://api.moonshot.cn/v1");
    expect(getKimiBaseUrl("moonshot-global")).toBe("https://api.moonshot.ai/v1");
    expect(getKimiBaseUrl("moonshot")).toBe("https://api.moonshot.cn/v1");
  });

  it("builds the correct model listing URLs", () => {
    expect(getKimiModelsUrl("moonshot-cn")).toBe("https://api.moonshot.cn/v1/models");
    expect(getKimiModelsUrl("moonshot-global")).toBe("https://api.moonshot.ai/v1/models");
  });
});
