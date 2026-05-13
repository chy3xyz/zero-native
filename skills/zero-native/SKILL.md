---
name: zero-native
description: Discovery skill for zero-native, a Zig desktop app shell for building native apps with web UIs. Use when the user asks what zero-native is, how to build a zero-native app, scaffold a frontend app, configure app.zon, choose a WebView engine, add bridge commands, package an app, test a running app, or automate a zero-native WebView shell.
allowed-tools: Bash(zero-native:*), Bash(npx zero-native:*)
hidden: true
---

# zero-native

zero-native is a Zig desktop app shell for building native desktop apps with web UIs. It uses the platform WebView for small native-footprint apps and can bundle Chromium through CEF where supported.

## Start here

This file is a discovery stub. Load the detailed workflow content from this repository before implementing or explaining zero-native app work:

- `skill-data/core/SKILL.md`: full app-building guide covering the app model, `app.zon`, frontend development, bridge commands, security, packaging, and validation.
- `skill-data/automation/SKILL.md`: running-app inspection and WebView shell automation.

Use `skill-data/core/SKILL.md` for most zero-native app questions. Use `skill-data/automation/SKILL.md` when testing a running app, taking snapshots, requesting reloads, or using the built-in automation server.

## Quick orientation

```bash
npm install -g zero-native
zero-native init my_app --frontend next
cd my_app
zig build run
```

Generated apps center on `app.zon`, `src/main.zig`, `src/runner.zig`, `build.zig`, and `frontend/`. Inspect those files before editing an existing app.
