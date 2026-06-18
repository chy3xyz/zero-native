# zero-native × Tauri v2 — Gap Analysis & Roadmap

Last updated: 2026-06-17

A feature-by-feature comparison of [zero-native v0.2.0](https://github.com/chy3xyz/zero-native) (Zig desktop framework, 11 bundled plugins) against [Tauri v2](https://v2.tauri.app) (Rust desktop framework, 32 official plugins, GA Oct 2 2024). The goal is to identify production-readiness gaps and chart a path forward.

---

## Summary

zero-native's **core runtime, capability-based security model, and 11 reference plugins** are competitive. The biggest gaps are in **production distribution (installers + auto-updater + CI/Action)**, **mobile (iOS/Android)**, and **third-party plugin SDK**. Closing these moves the framework from "reference-quality" to "production-grade."

### Zero-native strengths vs. Tauri v2

1. **Capability v2 model** with `$APPDATA` / `$HOME` / `$TEMP` / `$RESOURCE` scope variables — more dynamic than Tauri's `BaseDirectory` enum.
2. **Code-signing hardening** — argv-based spawn, no `sh -c` injection (Tauri's earlier invocation had the same risk).
3. **macOS App Sandbox plist generation** — complete `MacOSSandbox.entitlements()` → `toPlist()` pipeline.
4. **Compile-time TypeScript codegen** — deterministic, no runtime reflection.
5. **Switchable WebView backend** — system webview (WKWebView / WebKitGTK / WebView2) **or** CEF Chromium 144, per app.
6. **Atomic async bridge responder pool** (64-slot `cmpxchgStrong` claim).
7. **Panic capture + fanout trace sinks**.
8. **`zig build run-webview` / `run-browser`** built-in example applications.
9. **`webview_smoke` / `cef_smoke` integration tests** as CI gates.
10. **Single-threaded, predictable runtime** — easier to audit.
11. **`zero-native doctor` / `audit` / `codegen` / `plugins` / `cef` / `skills` / `automate`** CLI surface already broad.
12. **15 granular test steps** (`test-<module>`) wired into `zig build test`.

---

## Gap analysis (severity-ordered)

### 🔴 Tier 1 — Production distribution

| # | Gap | Tauri v2 | zero-native | Where it bites |
|---|---|---|---|---|
| 1 | **Installer generation** | `.msi` (WiX 3), `.exe` (NSIS), `.dmg` (hdiutil), `.deb` (dpkg-deb), `.rpm` (rpmbuild), `.AppImage` (appimagetool), plus iOS `.ipa` and Android `.apk`/`.aab` | Only raw artifacts + `.dmg`/`.zip`/`.tar.gz` archives; `package.zig:artifactReadme` explicitly says "future work" | Blocks every production deployment |
| 2 | **Auto-updater install flow** | Full `tauri-plugin-updater`: check → download → install, with mandatory Ed25519 signature verification, static and dynamic endpoints, `--createUpdaterArtifacts` flag | `updater.check` parses manifest + verifies Ed25519 sig; `updater.download` and `updater.install` are **stubs** (record-only) | App updates impossible without it |
| 3 | **CI / GitHub Action template** | Official `tauri-action` — end-to-end multi-OS build, optional release workflow, code-sign integration | CI exists for `zig build` only; no build-matrix template | Adoption friction for downstream users |
| 4 | **CLI signer tooling** | `tauri signer generate` / `tauri signer sign` for Ed25519 key generation and artifact signing | None | Updater requires signed artifacts |

### 🔴 Tier 2 — Mobile (iOS / Android)

| # | Gap | Tauri v2 | zero-native | Where it bites |
|---|---|---|---|---|
| 5 | **First-class iOS / Android targets** | `tauri ios {init,dev,build,run}`, Xcode project generation, App Store + TestFlight, `--export-method` | `createIosSkeleton` / `createAndroidSkeleton` produce only embed hosts; no Xcode project, no signing, no store upload | Mobile is unusable as a real target |
| 6 | **iOS code signing & notarization** | Automatic; `bundle.macOS.signingIdentity`, ad-hoc / Developer ID / App Store | None for iOS | App Store submission impossible |
| 7 | **Android APK/AAB signing** | `gradle assembleRelease` w/ keystore config | None | Play Store submission impossible |
| 8 | **App-level deep-link handlers** | iOS `CFBundleURLTypes` + universal links, Android `<intent-filter>` + `assetlinks.json`; runtime `getCurrent` / `onOpenUrl` | `deep_link` plugin **records** URL only; OS-level registration is a manifest concern, not actually wired | OAuth / universal-link flows break |
| 9 | **Mobile HMR** | Built-in HMR for iOS / Android, `TAURI_DEV_HOST` config, mobile `tauri.conf.{ios,android}.json` overlays | Only `ZERO_NATIVE_HMR=1` env var; no mobile HMR | Slow iteration on mobile |
| 10 | **Mobile-first plugins** | 9 plugins: `biometric`, `nfc`, `barcode-scanner`, `haptics`, `geolocation` (plus shared `os`, `log`, `process`, `cli`) | None | Mobile-specific UX impossible |
| 11 | **Mobile file / dialog support** | `tauri-plugin-dialog` and `tauri-plugin-fs` work on iOS / Android (limited markers) | `dispatchDialogBridgeCommand` exists but only desktop backends | File pickers on mobile unavailable |

### 🟠 Tier 3 — Plugin ecosystem

| # | Gap | Tauri v2 | zero-native | Where it bites |
|---|---|---|---|---|
| 12 | **Third-party plugin SDK** | Plugin workspace, `tauri-cli plugin new`, `add`/`remove` plugin, per-plugin `default.toml` permission set, plugin docs | 11 bundled static plugins; `zero-native plugins create <name>` scaffolds a new file, but no dynamic loading, no per-plugin permission files | Ecosystem can't grow |
| 13 | **`tauri-plugin-sql`** (SQLite/MySQL/PostgreSQL via `sqlx`) | Yes | None | No first-party DB access |
| 14 | **`tauri-plugin-stronghold`** (encrypted secret vault) | Yes | None | No secrets storage |
| 15 | **`tauri-plugin-localhost`** (in-app localhost server for OAuth callbacks) | Yes | None | OAuth in production webview needs it |
| 16 | **`tauri-plugin-upload`** (multipart / chunked uploads via `Channel`) | Yes | None | No large-file upload primitive |
| 17 | **`tauri-plugin-process`** (exit / relaunch / kill) | Yes | None | App lifecycle from JS missing |
| 18 | **`tauri-plugin-log`** (JS → `tracing` bridge) | Yes | None | No unified logging |
| 19 | **`tauri-plugin-os`** (arch, platform, locale, hostname) | Yes | `platform_info` primitive exists internally; not exposed as a plugin | No JS access to OS info |
| 20 | **`tauri-plugin-cli`** (parse `argv` from JS) | Yes | None | No JS argv handling |
| 21 | **`tauri-plugin-positioner`** (snap windows to tray / corners) | Yes | None | No window positioning helpers |

### 🟠 Tier 4 — Plugin completions (zero-native plugins that are partial)

| # | Gap | zero-native plugin | Current state | Required |
|---|---|---|---|---|
| 22 | **WebSocket** | `plugin_websocket.zig` (925 LoC) | Full RFC 6455 primitives (handshake encode/decode, frame encode/decode, `WsUrl.parse`); `websocket.connect` is record-only; no real TCP | `std.posix` connect loop, actual handshake, frame I/O on stream |
| 23 | **Global shortcut** | `plugin_global_shortcut.zig` (248 LoC) | In-memory combo list; mock trigger for tests | macOS Carbon `RegisterEventHotKey`; Linux XCB / Wayland `keybind`; Windows `RegisterHotKey` |
| 24 | **System tray** | `src/platform/root.zig:TrayOptions`, `src/platform/macos/` | macOS only via AppKit | Linux (`libayatana-appindicator` or StatusNotifierItem), Windows (`Shell_NotifyIcon`) |
| 25 | **Native notifications** | `plugin_notification.zig` | In-memory log only | macOS `NSUserNotificationCenter` / `UNUserNotificationCenter`; Linux `libnotify`; Windows toast notifications |
| 26 | **Clipboard (read native, not just buffer)** | `plugin_clipboard.zig` | In-memory text buffer with commands | Wire platform `read_clipboard` / `write_clipboard` to bridge |

### 🟡 Tier 5 — IPC / security / UX

| # | Gap | Tauri v2 | zero-native | Where it bites |
|---|---|---|---|---|
| 27 | **`Channel<T>` JS API** | `Channel<T>` with `onmessage` in `@tauri-apps/api/core` | `Channel(T)` exists in Zig; no JS `onStream` consumer | Stream IPC only works native→native |
| 28 | **`tauri-specta` equivalent** | First-class via `specta` feature flag + community `tauri-specta` | Comptime codegen covers declared commands; no automatic type extraction from `extensions.Module` types | Type-safe IPC requires manual typing |
| 29 | **Isolation pattern** | Sandboxed `<iframe>` + `SubtleCrypto` per-launch keys, intercepts all IPC | Child webviews are `bridge: false` by default; no SubtleCrypto isolation | Multi-tenant / plugin-marketplace scenarios |
| 30 | **per-plugin permission sets** | Each plugin ships a `default.toml` with `allow-*` / `deny-*` | Capability system exists, but no per-plugin scope files | Plugin author can't bundle their own ACL |
| 31 | **remote URL access** | `capability.json` `remote: { urls: [...] }` for dev server + remote origins | None — Vite dev server is allowed via env, not capability | Multi-origin apps need explicit allowlist |
| 32 | **CSP for `.url` / `.assets` sources** | Generated CSP via HTTP headers / proxy | Emits `security.csp_skipped` | Remote sources lack CSP protection |
| 33 | **Asset protocol** | `asset://` scheme + scope globs + `convertFileSrc` | `WebViewSource.assets` with `root_path` + `entry`; no scheme abstraction | Cross-cutting image / video loading |
| 34 | **Drag & drop events** | `tauri://drag-{enter,over,drop,leave}` + `WindowEvent::DragDrop` | None | File drag-into-app UX missing |
| 35 | **Window effects** (acrylic / blur / mica / NSVisualEffectView) | `WebviewWindow::set_effects` (v2.1) | None | Visual differentiation on Windows / macOS |
| 36 | **Window shadows, progress bar, badges, cursor, theme, background color** | All runtime-mutable | Basic options only | Limited visual / brand customization |
| 37 | **Parent / transient / owner relationships** | `parent`, `transient_for`, `owner` cross-platform | None | Multi-window app structure (modals) |
| 38 | **`tauri icon <png>`** | One PNG → all platform icons (`.icns` / `.ico` / `.png` sizes) | None | Onboarding friction |
| 39 | **`tauri info --interactive`** | Auto-detect and fix common issues | `doctor` is read-only | CI setup |
| 40 | **CLI `completions`** | Bash / Zsh / Fish / PowerShell / Elvish | None | Shell DX |
| 41 | **VS Code extension** | `vscode-tauri` | None | IDE integration |
| 42 | **MCP server** | `mcp-server-tauri` for AI agents | None | AI agent integration |
| 43 | **`tauri migrate`** | Automated v1 → v2 migration (allowlist → capabilities) | None | Not directly applicable, but useful for breaking changes later |
| 44 | **File associations** | `bundle.macOS.fileAssociations` + Windows registry + Linux MIME | None | Document-type apps need it |
| 45 | **Distributed tracing (OTLP exporter)** | N/A | Trace sinks exist; no OTLP / HTTP exporter | Observability at scale |
| 46 | **Mock runtime for tests** | `tauri::test::MockRuntime` | `Runtime.TestHarness()` with `NullPlatform` | Already covered, parity |

---

## Roadmaps

### Wave 24 — Ship updater, installers, CI, and signer CLI

Goal: close the four largest production-distribution gaps so an app can be signed, bundled, updated, and CI-built end-to-end.

- **24-A — Updater download + install** — finish `plugin_updater.zig` `download` (fetch signed bundle, verify Ed25519 sig) and `install` (spawn platform installer / replace app). Add CLI `zero-native package-update` and tests.
- **24-B — Installer generation** — implement `src/tooling/installer.zig` to emit `.msi` (WiX 3), `.exe` (NSIS), `.deb` (dpkg-deb), `.AppImage` (appimagetool). New CLI commands: `package-msi`, `package-deb`, `package-appimage`, `package-nsis`.
- **24-C — iOS / Android app templates** — extend `createIosSkeleton` / `createAndroidSkeleton` to produce real Xcode / Gradle projects, add signing config (`SIGNING_IDENTITY` for iOS, `KEYSTORE_*` for Android), and document `package-ios` / `package-android` for App Store / Play submission.
- **24-D — CI/CD GitHub Action** — write `.github/actions/build-zero-native-app/action.yml` for multi-OS matrix build (macOS / Windows / Linux) with the existing `zig build` + `package` steps; document `tauri-action`-style usage.

### Wave 25 — Complete existing plugins

- 25-A: WebSocket real TCP / handshake / frame I/O.
- 25-B: Global shortcut native registration (Carbon / XCB / `RegisterHotKey`).
- 25-C: System tray all platforms (libayatana-appindicator / StatusNotifierItem / `Shell_NotifyIcon`).
- 25-D: Native notifications all platforms.
- 25-E: Clipboard wired to platform `read_clipboard` / `write_clipboard`.

### Wave 26 — Plugin ecosystem + TS bindings

- 26-A: Third-party plugin loading (dynamic library + manifest).
- 26-B: `tauri-plugin-sql` equivalent (SQLite first).
- 26-C: `tauri-plugin-stronghold` equivalent (encrypted vault).
- 26-D: `tauri-plugin-localhost` equivalent (in-app OAuth callback server).
- 26-E: `tauri-plugin-process` / `-os` / `-log` / `-cli` (small wins).
- 26-F: `tauri-specta` equivalent (full type extraction for `Channel<T>` and `extensions.Module`).

### Wave 27 — Visual / security / DX

- 27-A: Window effects, shadows, progress bar, badges.
- 27-B: Drag & drop events.
- 27-C: Isolation pattern (SubtleCrypto).
- 27-D: Asset protocol (`asset://`).
- 27-E: per-plugin permission TOML files.
- 27-F: `zero-native icon <png>` and `zero-native info --interactive` and shell completions.
- 27-G: VS Code extension + MCP server.

### Wave 28 — Mobile polish

- 28-A: Mobile HMR (`TAURI_DEV_HOST`-equivalent).
- 28-B: Mobile deep-link OS registration.
- 28-C: `biometric`, `nfc`, `barcode-scanner`, `haptics`, `geolocation` plugins.

---

## Tracking

Each wave is a sequence of single-PR affairs:

1. Branch from `main` (e.g. `wave-24-installer`).
2. Implement + test.
3. Update `CHANGELOG.md` under `## Unreleased`.
4. Open PR, run CI, squash-merge when green.

CI gates: `zig build`, `zig build test`, `docs build`, `zero-native audit`. New CI matrix jobs are added as the target matrix grows.
