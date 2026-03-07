# GitHub Actions Release Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship OpenKoto Desktop v0.5.6 through GitHub Actions as the official multi-platform release for macOS arm64, macOS x64, and Windows.

**Architecture:** Reuse the existing tag-driven `release.yml` workflow, tighten it into a real production release path, bump the app version to 0.5.6 everywhere, then publish by pushing `main` and the `v0.5.6` tag.

**Tech Stack:** GitHub Actions, Tauri, Node/Vite, Rust, GitHub CLI

---

### Task 1: Update the release workflow for official releases

**Files:**
- Modify: `/Users/rqq/TextLingo/.github/workflows/release.yml`

**Step 1: Write the failing workflow expectations**

Checklist:
- release is not draft
- release body is not placeholder text
- matrix remains macOS arm64, macOS x64, Windows

**Step 2: Inspect current workflow**

Run: `sed -n '1,260p' /Users/rqq/TextLingo/.github/workflows/release.yml`

Expected: see `releaseDraft: true` and placeholder release body

**Step 3: Write minimal implementation**

Change:
- `releaseDraft: false`
- add real multiline release body
- keep current tag trigger and platform matrix

**Step 4: Verify workflow file**

Run: `sed -n '1,260p' /Users/rqq/TextLingo/.github/workflows/release.yml`

Expected: release config reflects official production release behavior

**Step 5: Commit**

```bash
git add /Users/rqq/TextLingo/.github/workflows/release.yml
git commit -m "ci: promote tag workflow to official release pipeline"
```

### Task 2: Bump app version to 0.5.6 everywhere

**Files:**
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/package.json`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/package-lock.json`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src-tauri/Cargo.toml`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src-tauri/Cargo.lock`
- Modify: `/Users/rqq/TextLingo/textlingo-desktop/src-tauri/tauri.conf.json`

**Step 1: Verify current version values**

Run:
- `cat /Users/rqq/TextLingo/textlingo-desktop/package.json`
- `cat /Users/rqq/TextLingo/textlingo-desktop/src-tauri/Cargo.toml`
- `cat /Users/rqq/TextLingo/textlingo-desktop/src-tauri/tauri.conf.json`

**Step 2: Update version**

Set all release-facing version fields to `0.5.6`.

**Step 3: Verify app version propagation**

Run:
- `cat /Users/rqq/TextLingo/textlingo-desktop/package.json`
- `cat /Users/rqq/TextLingo/textlingo-desktop/src-tauri/Cargo.toml`
- `cat /Users/rqq/TextLingo/textlingo-desktop/src-tauri/tauri.conf.json`

Expected: all show `0.5.6`

**Step 4: Commit**

```bash
git add /Users/rqq/TextLingo/textlingo-desktop/package.json /Users/rqq/TextLingo/textlingo-desktop/package-lock.json /Users/rqq/TextLingo/textlingo-desktop/src-tauri/Cargo.toml /Users/rqq/TextLingo/textlingo-desktop/src-tauri/Cargo.lock /Users/rqq/TextLingo/textlingo-desktop/src-tauri/tauri.conf.json
git commit -m "chore: bump desktop version to 0.5.6"
```

### Task 3: Run release verification locally before publishing

**Files:**
- No code changes expected

**Step 1: Run focused frontend regression tests**

Run:
- `npm test -- src/components/features/AssistantSidebarShell.test.tsx src/components/features/BookReader.test.tsx src/components/features/ArticleMindMapPanel.test.tsx`

**Step 2: Run static verification**

Run:
- `npm run typecheck`

**Step 3: Run backend verification**

Run:
- `cargo test --manifest-path /Users/rqq/TextLingo/textlingo-desktop/src-tauri/Cargo.toml`

**Step 4: Confirm all commands exit successfully**

Do not publish if any fail.

### Task 4: Publish v0.5.6 via GitHub Actions

**Files:**
- No code changes expected

**Step 1: Push `main`**

Run:
- `git push origin main`

**Step 2: Create and push the release tag**

Run:
- `git tag v0.5.6`
- `git push origin v0.5.6`

**Step 3: Monitor release workflow**

Run:
- `gh run list --workflow release.yml --limit 5`

**Step 4: Verify release exists**

Run:
- `gh release view v0.5.6 --json url,name,tagName,assets`

Expected:
- release exists
- assets include macOS arm64, macOS x64, and Windows artifacts

**Step 5: Report release URL and assets**

Include the GitHub release link in the final report.
