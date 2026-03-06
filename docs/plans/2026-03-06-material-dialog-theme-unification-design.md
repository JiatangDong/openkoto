# Material Dialog Theme Unification Design

**Date:** 2026-03-06

**Goal:** Unify the "new material" dialog color usage around the active theme's `primary` token so the California theme stays readable and visually consistent.

## Problem

The new material dialog mixes theme-aware neutrals with hard-coded semantic colors. In the current California theme this produces low-contrast purple-on-warm backgrounds, especially in the book import tab and the left navigation selected state.

## Scope

- Update all selected states in the left material-type navigation to use `primary` / `primary-foreground`-aligned styling.
- Update book import hint, file icon accents, and interactive states to use theme tokens instead of hard-coded purple.
- Preserve existing layout, copy, and interaction behavior.

## Non-goals

- No redesign of the modal layout.
- No per-type branded accent colors.
- No changes to unrelated dialogs or global theme files.

## Design

### Navigation

All active material tabs should share a single active treatment based on the theme primary color. Inactive tabs remain muted. This makes the selection model consistent and avoids mixing warm neutrals with arbitrary blue/purple/red/green accents.

### Book import form

The informational hint should use a subtle `primary` background and border with readable foreground text. File type icons can still differ by content type, but they should use theme-safe tokens rather than saturated hard-coded colors that clash with the current palette.

### Verification

Add component tests that fail if the dialog falls back to hard-coded category colors for active tabs or the book import hint.
