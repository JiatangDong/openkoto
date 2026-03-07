export interface RuntimeModelConfig {
  id: string;
  name: string;
  api_provider: string;
  api_key: string;
  model: string;
  is_default: boolean;
  base_url?: string;
}

export type ResolvedRuntimeProvider =
  | {
      kind: "openai_compatible";
      provider: string;
      model: string;
      api_key?: string;
      baseUrl: string;
    }
  | {
      kind: "native_google";
      provider: string;
      model: string;
      api_key: string;
    }
  | {
      kind: "native_anthropic";
      provider: string;
      model: string;
      api_key: string;
    }
  | {
      kind: "unsupported";
      provider: string;
      reason: string;
    };

const OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1";
const OPENAI_BASE_URL = "https://api.openai.com/v1";
const OLLAMA_BASE_URL = "http://127.0.0.1:11434/v1";
const LMSTUDIO_BASE_URL = "http://127.0.0.1:1234/v1";

function resolveDefaultBaseUrl(provider: string) {
  switch (provider) {
    case "openai":
      return OPENAI_BASE_URL;
    case "openrouter":
      return OPENROUTER_BASE_URL;
    case "ollama":
      return OLLAMA_BASE_URL;
    case "lmstudio":
      return LMSTUDIO_BASE_URL;
    default:
      return undefined;
  }
}

export function resolveRuntimeProvider(config: RuntimeModelConfig): ResolvedRuntimeProvider {
  const provider = config.api_provider;
  const baseUrl = config.base_url?.trim() || resolveDefaultBaseUrl(provider);

  if (provider === "google" || provider === "google-ai-studio") {
    return {
      kind: "native_google",
      provider,
      model: config.model,
      api_key: config.api_key,
    };
  }

  if (provider === "anthropic") {
    return {
      kind: "native_anthropic",
      provider,
      model: config.model,
      api_key: config.api_key,
    };
  }

  if (
    ["openai", "openai-compatible", "openrouter", "ollama", "lmstudio"].includes(provider) &&
    baseUrl
  ) {
    return {
      kind: "openai_compatible",
      provider,
      model: config.model,
      api_key: config.api_key,
      baseUrl,
    };
  }

  return {
    kind: "unsupported",
    provider,
    reason: `Provider ${provider} is not supported for the agent runtime`,
  };
}
