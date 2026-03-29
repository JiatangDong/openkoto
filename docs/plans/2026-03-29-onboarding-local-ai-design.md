# Onboarding Local AI Design

**Date:** 2026-03-29

**Goal:** Add a friendly local AI entry to the first-run onboarding flow so users can configure Ollama or LM Studio without opening Settings.

## Problem

The current onboarding model step only presents cloud providers. The app already supports local providers in Settings, but first-run users do not see that option, which makes the product feel cloud-only and increases setup friction for privacy-first users.

## Scope

- Add a `Local AI` option to onboarding step 2 alongside the existing global and China cloud flows.
- Allow first-run users to configure `Ollama` or `LM Studio` directly from onboarding.
- Save the chosen local provider into the existing `model_config` system with `api_provider`, `model`, and `base_url`.
- Keep the rest of onboarding unchanged.

## Non-goals

- No redesign of the full Settings dialog.
- No new backend commands for onboarding-specific model storage.
- No support for additional local runtimes beyond Ollama and LM Studio in this pass.

## Approaches Considered

### Option 1: Add a third top-level onboarding choice for Local AI

Extend the existing provider-selection area from two choices to three: global, China, and local.

This is the recommended approach. It keeps the interaction model consistent and makes local setup visible during first run without adding another onboarding step.

### Option 2: Hide local setup behind a secondary "advanced" section

This is lower risk visually, but it weakens discoverability and does not solve the product problem well enough.

### Option 3: Add a separate onboarding step for local/cloud choice

This would keep each screen simpler, but it lengthens onboarding for everyone and is not justified for a small capability addition.

## Design

### Onboarding layout

Keep the current three-step onboarding structure. In step 2:

- change the top selector from two cards to three cards,
- add a `Local AI` card with a chip/device visual treatment,
- only show local-provider controls when `Local AI` is selected.

### Local provider controls

When `Local AI` is selected, show two nested service cards:

1. `Ollama`
2. `LM Studio`

Both should keep the same rounded-card visual language as the rest of onboarding.

#### Ollama

- default `base_url` to `http://localhost:11434/v1`,
- show a `Sync local models` button,
- fetch models from `http://localhost:11434/api/tags` by trimming `/v1` before building the Ollama endpoint,
- allow users to select a synced model or type a custom model name if sync fails or the desired model is absent.

#### LM Studio

- default `base_url` to `http://localhost:1234/v1`,
- show a plain model input instead of relying on sync,
- explain that LM Studio usually exposes an OpenAI-compatible endpoint and model IDs may vary.

### Save behavior

On onboarding completion:

- always save `onboarding_completed = true` and the base config,
- if the user provided a valid local model selection/input, save a normal `model_config` with:
  - `api_provider = "ollama"` or `"lmstudio"`,
  - `name = "Ollama"` or `"LM Studio"`,
  - `api_key = ""`,
  - `model = <selected or typed model>`,
  - `base_url = <configured URL>`,
- then mark that config active with the existing command.

If the user chose local AI but leaves the model blank, onboarding should still allow skipping configuration exactly like the current cloud flow allows skipping API-key entry.

### Error handling

- Ollama model sync failures should be shown inline and should not block continuing.
- Invalid or empty local model input should only prevent saving a local config, not block onboarding completion.
- Existing cloud-provider behavior should remain unchanged.

### Testing

Frontend coverage should verify:

- the onboarding dialog shows the new local-AI path,
- selecting local AI and finishing with an Ollama model saves a local `model_config` with the correct provider and base URL,
- onboarding still supports skip behavior when no model is configured.

## Recommendation

Implement Option 1 and keep the change narrowly scoped to the onboarding dialog. This gives users a clear first-run path for local AI while reusing the app's existing local-provider runtime support.
