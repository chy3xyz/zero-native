# Changelog

All notable changes to zero-native will be documented in this file.

<!-- release:start -->
## 0.3.0 — 2026-06-16

### Plugins — 24 bundled (up from 11)

- **8 new plugins**: path (app directories), fs (file I/O), dialog (open/save/message), env (environment variables), random (crypto random + UUID), crypto (SHA-256/SHA-1), window (multi-window), tray (system tray)
- **Plugin persistence**: store plugin now writes to disk (JSON file) when `store_path` is set, with auto-save on mutation
- **WebSocket TLS**: `websocket.connect` supports `wss://` via httpz/OpenSSL, real TCP + TLS stream handshake and frame I/O
- **Global shortcuts**: macOS Carbon `RegisterEventHotKey` bridge (appkit_host.m), Linux X11 keycode parsing (hotkey.zig), all platforms wired through plugin
- **Updater wiring**: `.updates` block in `app.zon` → Metadata → registry → plugin config; `updater.check` fetches feed via HTTP/HTTPS when payload is empty; `check_on_start` auto-fetches
- **Plugin real implementations**: process.exit calls `std.process.exit` in production; store disk persistence; clipboard native read/write (pbcopy/xclip/Get-Clipboard); deep-link .deep_link_schemes parsed from app.zon; notification/Linux tray runtime-detected
- **Third-party plugin SDK**: `extensions.Plugin` type, `extensions.definePlugin`, `Runtime.loadPlugins` accepts `custom_plugins`, loader/registry fallback
- **SQLite plugin**: `sql.open/execute/select/close` with conditional `-Dsqlite` build flag and comptime stub

### Platform

- **macOS**: native notifications (UNUserNotificationCenter / NSUserNotification), open/save/message dialogs, Carbon global shortcuts, Info.plist CFBundleURLTypes
- **Linux**: native notifications (dbus-send / notify-send), runtime-detected libayatana-appindicator3 tray, .desktop MIME x-scheme-handler, developer extras + console-to-stdout
- **Windows**: Pure-Zig platform rewrite — no C++ host required. Win32 user32/kernel32/shell32 extern declarations, window creation (CreateWindowExW), message pump (GetMessageW), 30+ externs declared, compiles on all targets via comptime guards

### DevTools

- macOS WKWebView: developer extras always enabled (right-click → Inspect Element)
- Linux WebKitGTK: developer extras + console-to-stdout enabled via settings
- app.zon: `.debug.devtools` flag in metadata

### Infrastructure

- CI matrix: ubuntu/macos/windows all build; macOS runs `zig build test`
- Reusable `build-zero-native-app` GitHub Action
- CI Zig version aligned to 0.17.0-dev.813+2153f8143
- Minimal Zig version bumped to 0.17.0
- Repository org: vercel-labs → chy3xyz

### Docs

- README: 24-plugin matrix, beta status, updated app.zon example
- AGENTS.md: AI developer guide (Zig 0.17 gotchas, architecture, plugin checklist)
- skills/zero-native/SKILL.md: project reference for AI agents
- 5 new plugin doc pages (process, os, log, cli, sql)
- field name fix: capabilities → feature_capabilities

<!-- release:end -->

## Unreleased

### New Features

- **Plugin scaffolding**: `zero-native plugins create <name>` subcommand that scaffolds a `plugin_<name>.zig` file with a complete module lifecycle, command dispatch, and passing test.
- **Auto-updater download/install**: `updater.download` fetches the platform-specific bundle via `http_client.request`, verifies the Ed25519 signature against the manifest entry, and writes to `<TMPDIR>/zero-native-update/<platform>-<version>.bin`; `updater.install` spawns the platform installer (`open` on macOS, `dpkg -i` / `chmod +x` on Linux, `msiexec /i` on Windows) and records the staging path. New CLI `updater sign|verify` for Ed25519 key management.
- **Plugin platform stubs**: `notification.notify` calls a `postOsNotification` stub; `clipboard.write_text` and `.read_text` call `writeNativeClipboard` / `readNativeClipboard` stubs; `global_shortcut.register` calls a `registerNative` stub. All stubs succeed on all platforms; per-platform native wiring (NSUserNotificationCenter / NSPasteboard / Carbon RegisterEventHotKey / libayatana-appindicator / Windows tray) is documented and future work.
- **Linux tray stub**: `createTray`, `updateTrayMenu`, and `removeTray` succeed on Linux (return success instead of `UnsupportedService`). The real libayatana-appindicator / StatusNotifierItem implementation is future work.
- **Plugin ecosystem**: four new bundled plugins — `process` (`exit`, `relaunch`), `os` (`info`), `log` (`write`, `clear`), and `cli` (`args`, `matches`). Registered in `extensions/all.zig`, `loader.zig`, and `registry.zig`.
- **OAuth callback server**: new `zero-native localhost` CLI command that starts an ephemeral HTTP server on `127.0.0.1`, captures the first GET request path, and prints `{ "port": N, "path": "/..." }` for OAuth PKCE redirects.
- **Installer generation**: `zero-native package-installer <msi|nsis|deb|appimage> [app.zon]` subcommand that produces real platform installers by shelling out to WiX 3, NSIS, `dpkg-deb`, or `appimagetool`. Missing tools surface as `InstallerToolNotFound`.
- **iOS / Android app templates**: `createIosFullApp` and `createAndroidFullApp` produce complete Xcode / Gradle projects (`.xcodeproj/project.pbxproj`, `Info.plist`, `Main.storyboard`, `Bridging-Header.h`, `Assets.xcassets` on iOS; `settings.gradle`, `app/build.gradle`, `AndroidManifest.xml`, `MainActivity.kt`, `gradle-wrapper.properties` on Android) ready for signing and store submission.
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
- **Test coverage**: Wire previously-skipped plugin and channel tests into `zig build test` so the bundled plugin matrix and the `bridge.Channel(T)` streaming IPC are exercised on every CI run.
- **Runtime split**: Pull the `Runtime` type, the bridge `Dispatcher`, the `Channel(T)` streaming helper, the `Metadata` parser, the `Capability` matcher, the `ModuleRegistry`, and the macOS `MacOSSandbox` plist generator into focused modules with their own public reference documentation.
- **Trace and error handling**: Stable `security.csp_*`, `security.command_denied`, and `bridge.*` trace events; explicit `Error` codes on the bridge envelope; structured plugin `Command.payload` field; new `ModuleId` `u64` namespace; `Runtime.createStreamChannel` helper that wires a typed channel straight to `completeBridgeResponse`.

### Security

- **Shell command injection in codesign**: Replace the `sh -c` codesign/notary invocation with an argv-based `std.process.spawn` so caller-supplied paths can no longer smuggle shell metacharacters; the old `codesign --sign <app_path>` form was vulnerable to inputs like `; rm -rf ~`.
- **Code-signing failure surfacing**: Codesign errors now log `codesign.sign_failed`, `codesign.notarize_submit_failed`, and `codesign.staple_failed` with the failed argv and the underlying `@errorName` so signing regressions are visible from CI output.
- **Capabilities as the authoritative gate**: When the manifest declares any structured capability, the per-window lookup supersedes the legacy `permissions` list for command and path checks, eliminating the silent fall-through between the two policy layers.

### Documentation

- **Bundled plugins matrix**: A `Bundled Plugins` page and an individual page per plugin (clipboard, shell, notification, http, deep-link, store, autostart, single-instance, updater, global-shortcut, websocket) documenting lifecycle, configuration, and JS API.
- **Type-Safe IPC reference**: A `Type-Safe IPC (Codegen)` page covering `CommandSchema`, `ParamSchema`, `defineCommand`, and `generateTypeScript` with a sample `.d.ts` output.
- **App Sandbox reference**: An `App Sandbox` page documenting the `MacOSSandbox` schema, the `toPlist` output, and the code-sign integration with a generated plist excerpt.
- **Capabilities deep dive**: A `Capabilities` page covering deny-overrides-allow, scope variables, glob syntax, per-window targeting, and the difference between command and path lookups.
- **Examples index**: A new `Examples` page listing all nine `examples/` projects with their frontends, descriptions, and `zig build run` instructions, plus a `npx zero-native init` snippet.
- **API reference**: A new `API Reference` section in the navigation with type-level pages for `Runtime`, `Dispatcher`, `Channel`, `Metadata`, `Capability`, `ModuleRegistry`, and `Sandbox` linking back to the conceptual pages.

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
