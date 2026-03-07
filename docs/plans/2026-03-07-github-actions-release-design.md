# GitHub Actions Release Design

## Goal

将 OpenKoto Desktop 的正式发布切换到 GitHub Actions 多平台构建，不再把本地手工打包视为正式 release。

本次正式版本号改为：

- `0.5.6`

目标平台：

- macOS Apple Silicon
- macOS Intel
- Windows

不包含 Linux。

## Current State

- 仓库已经有现成工作流：
  - [release.yml](/Users/rqq/TextLingo/.github/workflows/release.yml)
  - [release-dev.yml](/Users/rqq/TextLingo/.github/workflows/release-dev.yml)
- 当前 `release.yml` 已经具备：
  - tag 触发
  - `ci-gate`
  - Tauri 多平台矩阵
- 但它还不是完整的正式发布方案，主要问题：
  - release notes 过于简陋
  - `releaseDraft: true`
  - 当前正式发布纪律不够清晰

## Design Decision

采用最小改造方案：

- 继续使用现有 `release.yml`
- 继续使用 tag 驱动正式发布
- 不引入新的 release orchestration workflow
- 本地打包只作为开发验证，不作为正式发布手段

## Versioning

正式版提升为：

- `0.5.6`

需要统一更新：

- [textlingo-desktop/package.json](/Users/rqq/TextLingo/textlingo-desktop/package.json)
- [textlingo-desktop/src-tauri/Cargo.toml](/Users/rqq/TextLingo/textlingo-desktop/src-tauri/Cargo.toml)
- [textlingo-desktop/src-tauri/tauri.conf.json](/Users/rqq/TextLingo/textlingo-desktop/src-tauri/tauri.conf.json)

应用内显示版本：

- [App.tsx](/Users/rqq/TextLingo/textlingo-desktop/src/App.tsx) 使用 `__APP_VERSION__`
- [vite.config.ts](/Users/rqq/TextLingo/textlingo-desktop/vite.config.ts) 从 `tauri.conf.json.version` 读取

所以只要以上三处统一，应用内显示和安装包版本会自动变成 `0.5.6`。

## Release Workflow Behavior

### Trigger

- `push` tag: `v*`

### Gate

正式 release 仍然必须经过：

- frontend typecheck
- frontend coverage
- Rust tests

### Platforms

矩阵保留：

- `macos-latest` + `aarch64-apple-darwin`
- `macos-latest` + `x86_64-apple-darwin`
- `windows-latest`

### Release State

正式版应改为：

- `releaseDraft: false`
- `prerelease: false`

## Release Notes

正式 release notes 需要在 workflow 中提供完整文案，不再使用一句占位文本。

本次 `v0.5.6` 应至少包含：

- 可编辑思维导图
- 思维导图本地保存
- 助手面板 `1/3 / 2/3 / 全屏`
- 修复思维导图切换导致布局异常
- 统一文章/书籍右侧 AI 助手
- PDF / EPUB / TXT 书籍接入思维导图

## Publish Discipline

以后正式发布规则固定为：

1. 合并到 `main`
2. 更新版本号
3. push `main`
4. push `vX.Y.Z`
5. GitHub Actions 自动出包并创建正式 release

不再使用：

- 本地手工上传 release asset
- 手工创建 GitHub 正式 release

## This Release

因为当前已经存在本地手工 `v0.5.5` 构建和手工 release 痕迹，本次不回收 `v0.5.5`，直接以 GitHub Actions 重新发布：

- `v0.5.6`

这样更干净，也避免对现有 tag/release 做危险改写。
