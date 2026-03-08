# Kimi CN/Global Provider Split Design

## Summary

Split the existing single `moonshot` provider into two independent providers:

- `moonshot-cn`: Moonshot China / Kimi China API
- `moonshot-global`: Moonshot Global API

The user-visible goal is to let users choose the China and Global Kimi offerings separately in settings, with each provider using its own official base URL and model sync endpoint.

## Goals

- Expose two distinct Kimi providers in the settings UI.
- Route China requests to `https://api.moonshot.cn/v1`.
- Route Global requests to `https://api.moonshot.ai/v1`.
- Keep existing Kimi-specific capabilities working for both providers.
- Preserve compatibility for existing saved configs that still use `moonshot`.

## Non-Goals

- Splitting the model catalog into two manually curated lists.
- Adding a third "region" selector under one provider.
- Changing unrelated provider configuration behavior.

## Current State

The app currently uses a single `moonshot` provider across:

- Settings provider dropdown and preset model list
- Settings model sync endpoint
- Rust chat/completion service
- Rust file upload support
- Rust subtitle extraction routing
- Kimi-specific behavior checks such as thinking mode and video understanding

All of those paths currently target `api.moonshot.cn`.

## Proposed Design

### Provider identifiers

Introduce two provider ids:

- `moonshot-cn`
- `moonshot-global`

Retain `moonshot` only as a legacy config value for backward compatibility when reading old saved settings.

### User-facing labels

Expose two distinct provider labels in the UI:

- Chinese locale: `月之暗面 (Kimi 中国版)` and `Moonshot AI (Kimi 国际版)`
- English locale: `Moonshot AI (Kimi China)` and `Moonshot AI (Kimi Global)`
- Japanese locale: equivalent localized labels

### Endpoint mapping

Centralize Kimi endpoint resolution so each capability derives URLs from provider identity instead of hardcoded strings.

- `moonshot-cn`
  - base URL: `https://api.moonshot.cn/v1`
  - chat completions: `/chat/completions`
  - models: `/models`
  - files: `/files`
- `moonshot-global`
  - base URL: `https://api.moonshot.ai/v1`
  - chat completions: `/chat/completions`
  - models: `/models`
  - files: `/files`

### Model handling

Use the same preset model list for both providers initially. Model sync will fetch from each provider's own `/models` endpoint, so any future divergence is handled by the provider API instead of by a manually duplicated hardcoded list.

### Legacy compatibility

Old configs with `api_provider: "moonshot"` should behave as China configs.

Compatibility policy:

- Existing `moonshot` configs continue to work without migration.
- UI displays legacy configs using the China provider label.
- New configs should only save `moonshot-cn` or `moonshot-global`.

This avoids forcing a config migration during this change.

## Implementation Areas

### Frontend

- Update the settings provider list to include both new providers.
- Duplicate Kimi preset model mapping so both providers show the same default choices.
- Update model sync logic to call the correct `/models` endpoint for each provider.
- Update any provider-specific UI checks that currently only look for `moonshot`.
- Keep legacy `moonshot` readable when editing existing configs.

### Backend

- Centralize Moonshot base URL resolution in Rust.
- Update chat/completion routing to use provider-specific endpoints.
- Update file upload routing to support both providers.
- Update subtitle extraction routing to support both providers.
- Expand Kimi-specific feature checks from `moonshot` to all Kimi provider ids, including legacy `moonshot`.

## Risks

### Legacy configs become uneditable

If the settings UI only recognizes new provider ids, old configs could lose preset models or show blank provider labels. Mitigation: explicitly treat `moonshot` as a China alias in frontend and backend matching.

### Missed hardcoded endpoints

There are multiple Moonshot call sites across TypeScript and Rust. Mitigation: replace direct string checks systematically and verify with repository search.

### Incomplete feature parity

Kimi-only logic such as thinking mode or video input could accidentally remain bound to one provider id. Mitigation: centralize provider predicate helpers and reuse them.

## Testing Strategy

- Add or update frontend tests around provider resolution where practical.
- Add or update agent-worker/provider tests only if provider resolution there is affected.
- Add Rust unit tests for provider URL resolution if there is an appropriate test location.
- Run targeted frontend and Rust test suites covering settings/provider behavior.
- Search the repository after implementation to ensure no unintended `provider == "moonshot"` or hardcoded `api.moonshot.cn` usages remain outside legacy compatibility handling.

## Rollout Notes

- Existing users keep working with their saved `moonshot` configs.
- New users can explicitly choose China or Global in the provider dropdown.
- No config migration is required for this release.
