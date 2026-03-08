export const LEGACY_KIMI_PROVIDER = "moonshot";
export const KIMI_CHINA_PROVIDER = "moonshot-cn";
export const KIMI_GLOBAL_PROVIDER = "moonshot-global";

export type KimiProvider =
  | typeof KIMI_CHINA_PROVIDER
  | typeof KIMI_GLOBAL_PROVIDER;

export function normalizeKimiProvider(provider: string): KimiProvider | null {
  if (provider === LEGACY_KIMI_PROVIDER || provider === KIMI_CHINA_PROVIDER) {
    return KIMI_CHINA_PROVIDER;
  }

  if (provider === KIMI_GLOBAL_PROVIDER) {
    return KIMI_GLOBAL_PROVIDER;
  }

  return null;
}

export function isKimiProvider(provider: string): boolean {
  return normalizeKimiProvider(provider) !== null;
}

export function getKimiBaseUrl(provider: string): string | null {
  const normalized = normalizeKimiProvider(provider);

  if (normalized === KIMI_CHINA_PROVIDER) {
    return "https://api.moonshot.cn/v1";
  }

  if (normalized === KIMI_GLOBAL_PROVIDER) {
    return "https://api.moonshot.ai/v1";
  }

  return null;
}

export function getKimiModelsUrl(provider: string): string | null {
  const baseUrl = getKimiBaseUrl(provider);

  return baseUrl ? `${baseUrl}/models` : null;
}
