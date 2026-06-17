# Changelog

All notable changes to zero-native will be documented in this file.

## Unreleased

### New Features

- **Capabilities system**: Per-window structured capabilities with allow/deny scope globs for commands and paths, scoped `$APPDATA` / `$HOME` variables, and the `security.capabilities` manifest block to gate bridge commands and file access on a per-window basis.
- **Content-Security-Policy injection**: Runtime-injected `<meta http-equiv="Content-Security-Policy">` tag for `.html` webview sources via `WebViewSource.htmlWithCsp`, with `security.csp_injected`, `security.csp_invalid`, and `security.csp_skipped` trace events for diagnostics.
- **Bundled plugins**: Eleven reference plugins demonstrating common patterns: clipboard, shell, notification, http, deep-link, store, autostart, single-instance, updater, global-shortcut, and websocket.
- **Channel streaming**: `bridge.Channel(T)` typed value streaming over the bridge with `value` and `end` JSON frames for `i32`, `i64`, `u32`, `u64`, `f32`, `f64`, `bool`, and `[]const u8` payloads.
- **Type-Safe IPC (codegen)**: Comptime TypeScript declaration generator that emits `.d.ts` overloads of `invoke` from `CommandSchema` and `ParamSchema` so `window.zero.invoke` is fully typed in the frontend.
- **Auto-updater**: Built-in updater plugin with manifest-driven update channels, signature verification, and staged rollouts.
- **App Sandbox**: macOS App Sandbox opt-in via the `[security.sandbox]` manifest block, with dynamic entitlements plist generation, `MacOSSandbox` field reference, and code-sign integration.
- **Bridge error codes and policy refinement**: Default-deny command policy, exact-origin checks, wildcard `*` limited to `http(s)`, and explicit `builtin_bridge` policy required for dialogs.

### Improvements

- **Zig 0.17 compatibility**: Bump `minimum_zig_version` to `0.17.0` and migrate the framework, CLI, and example build scripts to the Zig 0.17 toolchain. The migration covers the removed `Allocator.dupeZ` API, the removed `**` array repeat operator (replaced by `@splat`), the new `@typeInfo(T).@"enum"` field layout (`field_names` / `field_values` instead of `fields`), and the removal of the `b.sysroot` build field (replaced by an explicit `sdk_path` argument computed via `std.zig.system.darwin.getSdk`).
- **Documentation site**: Add individual pages and a `Bundled Plugins` matrix for all 11 reference plugins (clipboard, shell, notification, http, deep-link, store, autostart, single-instance, updater, global-shortcut, websocket), a `Type-Safe IPC (Codegen)` reference for the bridge codegen API, and an `App Sandbox` reference documenting the `MacOSSandbox` schema, manifest block, and generated entitlements plist.

## 0.2.0

<!-- release:start -->

### New Features

- **Layered WebView runtime**: Model each native window as a stack of named WebViews, including the reserved startup `main` WebView and child WebViews with frame, layer, zoom, transparency, routing, resizing, reload, and close support across the native backends (#28).
- **JavaScript WebView API**: Add typed `window.zero.webviews.*` helpers and `zero-native.webview.*` built-in bridge commands for create, list, setFrame, navigate, setZoom, setLayer, and close operations (#28).
- **Isolated child WebViews**: Keep child WebViews bridge-isolated by default, allow trusted child chrome with `bridge: true`, enforce navigation policy on child URLs, and scope WebView commands to the calling native window (#28).
- **Browser example**: Add a browser-style example that demonstrates layered WebViews, browser controls, isolated page content, frontend asset handling, and the root `zig build run-browser` command (#28).
- **zero-native skills**: Ship CLI-served agent skills and reference material for building and automating zero-native apps (#38).

### Improvements

- **WebView and bridge documentation**: Document WebView APIs, built-in bridge commands, security boundaries, backend support, packaging, testing, and app model updates (#28, #38).
- **WebView smoke coverage**: Extend automation smoke tests to exercise child WebView create, resize, navigate, and close operations for system WebView and macOS CEF builds (#28).
- **CEF runtime builds**: Harden the CEF runtime workflows across macOS, Linux, and Windows, including Windows runtime build fixes (#25, #26).
- **macOS compatibility**: Set the native app baseline to macOS 11 (#22).
- **Contributor guidance**: Clarify signed commit requirements and contribution PR guidance (#10).

### Bug Fixes

- **Windows WebView builds**: Fix Windows WebView build failures before the layered WebView release.
- **React example dependencies**: Include the missing React example type dependencies (#11).
- **GitHub release notes**: Avoid duplicate contributor lists when creating GitHub releases (#24).
- **macOS package permissions**: Preserve executable permissions for packaged macOS app binaries (#39).

### Contributors

- @Anshuman71
- @PrathamGhaywat
- @ctate
<!-- release:end -->

## 0.1.9

### New Features

- **Linux and Windows desktop support**: Add platform-aware CEF tooling, Linux and Windows desktop build paths, Windows native host plumbing, and cross-platform CEF runtime packaging/release coverage.

### Contributors

- @ctate

## 0.1.8

### Bug Fixes

- **Install completion delay** - Drain redirected GitHub responses during postinstall so npm exits immediately after the native binary is installed.

### Contributors

- @ctate

## 0.1.7

### Improvements

- **Install progress** - Show native binary download progress and checksum status during the npm postinstall step.

### Contributors

- @ctate

## 0.1.6

### Improvements

- **Init next steps** - Print the follow-up commands after scaffolding so users can immediately run their new app.

### Contributors

- @ctate

## 0.1.5

### Bug Fixes

- **macOS local asset loading** - Prefer current-directory asset roots during local `zig build run` so Vite-based examples render their production bundles instead of blank windows.

### Contributors

- @ctate

## 0.1.4

### Bug Fixes

- **Scaffolded app builds** - Ship the framework source tree in the npm package and make `zero-native init` point generated apps at the installed package root so `zig build run` can resolve `src/root.zig`.
- **Long scaffold names** - Keep generated Zig package names within Zig's 32-character manifest limit.
- **Next scaffold builds** - Include the Node.js type package that Next expects for TypeScript projects.
- **Frontend dependency versions** - Generate projects with current Next, React, Vite, Vue, Svelte, and plugin versions.
- **Svelte scaffold builds** - Use the matching Svelte Vite plugin in generated Svelte projects.

### Contributors

- @ctate

## 0.1.3

### Bug Fixes

- **CLI package homepage** - Point npm package metadata at `https://zero-native.dev`.
- **Current-directory init** - Support `zero-native init --frontend <framework>` as shorthand for scaffolding into the current directory.
- **CLI usage errors** - Exit cleanly for invalid CLI arguments instead of printing Zig stack traces for expected user input mistakes.

### Contributors

- @ctate

## 0.1.2

### Bug Fixes

- **npm install fallback** - Do not fail package installation or point global shims at missing binaries when a native release asset is unavailable.
- **Release asset ordering** - Upload the macOS arm64 native binary and `CHECKSUMS.txt` before publishing the npm package so postinstall downloads succeed immediately.

### Contributors

- @ctate

## 0.1.1

### Bug Fixes

- **npm package homepage** - Add the zero-native repository homepage to the CLI package metadata.
- **Chromium example launches** - Stage the CEF framework correctly for the `hello` and `webview` examples when running with `-Dweb-engine=chromium`.
- **Linux WebKitGTK build** - Update navigation policy and external URI handling for current WebKitGTK and GTK4 headers.
- **macOS WebView smoke test** - Use the emitted CLI binary and queue automation early enough for stable CI smoke tests.

### Release Process

- **GitHub releases** - Create missing GitHub releases from marked changelog entries when npm already has the version.
- **CEF runtime release** - Publish the prepared macOS arm64 CEF runtime used by `zero-native cef install`.

### Contributors

- @ctate

## 0.1.0

### Initial Release

- Initial pre-release development version.
