# Web Engines, Packaging, and Debugging

Use this when choosing system WebView vs Chromium, installing CEF, packaging, signing, running doctor, finding logs, or debugging runtime behavior.

## Web engine choice

Default:

```zig
.web_engine = "system",
```

System mode:

- Uses the OS web engine.
- macOS: WKWebView.
- Linux: WebKitGTK.
- Smallest app footprint.
- Fastest startup.
- Rendering depends on the user's OS.

Chromium mode:

```zig
.web_engine = "chromium",
.cef = .{ .dir = "third_party/cef/macos", .auto_install = false },
```

Chromium mode:

- Bundles CEF.
- Gives predictable Chromium behavior.
- Increases package size and startup cost.
- Requires matching CEF layout at build and package time.

Use Chromium when the product needs a pinned web platform, complex frontend rendering consistency, or Chromium-only behavior. Otherwise prefer `system`.

## CEF setup

Install the prepared runtime:

```bash
zero-native cef install
zero-native doctor --manifest app.zon
```

Pin CEF in app setup or CI when reproducibility matters:

```bash
zero-native cef install --version <version>
```

Useful overrides:

```bash
zig build run -Dweb-engine=chromium -Dcef-dir=third_party/cef/macos
zig build run -Dweb-engine=chromium -Dcef-auto-install=true
zero-native package --web-engine chromium --cef-dir third_party/cef/macos
```

Normal product configuration should live in `app.zon`; CLI/build flags are for temporary overrides.

## Packaging

Simple path:

```bash
zig build package
```

CLI path:

```bash
zero-native package --target macos --manifest app.zon --binary zig-out/bin/MyApp
```

Important package manifest fields:

- `id`: bundle ID, desktop ID, log/state prefix.
- `display_name`: app/menu/window title fallback.
- `version`: package metadata.
- `icons`: copied into package resources.
- `platforms`: intended package targets.
- `frontend`: asset directory and entry file.
- `web_engine` and `cef`: engine and Chromium runtime config.

For frontend apps, package the built frontend assets. The build step usually wires this automatically. If using CLI directly, pass `--assets frontend/dist`.

## macOS packages

`zig build package` creates a `.app` bundle with:

- `Contents/MacOS/<binary>`
- `Contents/Resources/icon.icns`
- `Contents/Info.plist`
- `Contents/Resources/dist/` when frontend assets are configured
- `Contents/Frameworks/Chromium Embedded Framework.framework` for Chromium apps

macOS minimum system version is 11.0.

Signing modes:

```bash
zero-native package --target macos --signing none
zero-native package --target macos --signing adhoc
zero-native package --target macos --signing identity --identity "Developer ID Application: Your Name"
```

For Chromium apps, verify the CEF framework and resources are included and signed before notarization.

## Linux and Windows packages

Linux creates an install tree with:

- `bin/<name>`
- `share/applications/<name>.desktop`
- icons under `share/icons/hicolor/...`

Windows packaging is early support and creates a directory-based distributable layout.

Shortcut commands:

```bash
zero-native package-linux --binary zig-out/bin/MyApp
zero-native package-windows --binary zig-out/bin/MyApp.exe
```

## Doctor and validation

Validate manifest schema:

```bash
zero-native validate app.zon
```

Check environment and package readiness:

```bash
zero-native doctor
zero-native doctor --manifest app.zon --strict
zero-native doctor --manifest app.zon --web-engine chromium --cef-dir third_party/cef/macos
```

Doctor checks:

- host platform
- WebView availability
- manifest validity
- log directory writability
- CEF layout when Chromium is selected
- signing tools

Use `--strict` in CI or before release so warnings fail the command.

## Debugging

Trace modes:

- `off`
- `events`
- `runtime`
- `all`

Build/run flags commonly include:

```bash
zig build run -Dtrace=all
zig build run-webview -Ddebug-overlay=true
```

Log defaults:

- macOS: `~/Library/Logs/<bundle-id>/zero-native.jsonl`
- Linux: `~/.local/state/<bundle-id>/logs/zero-native.jsonl`
- Windows: `%LOCALAPPDATA%\<bundle-id>\Logs\zero-native.jsonl`

Environment variables:

```bash
ZERO_NATIVE_LOG_DIR=/tmp/my-logs zig build run
ZERO_NATIVE_LOG_FORMAT=text zig build run
```

Panic capture:

```zig
pub const panic = std.debug.FullPanic(zero_native.debug.capturePanic);
```

Generated runners usually install panic capture so crashes write `last-panic.txt` and append a fatal trace record.

## Common failures

- App window opens blank: check `WebViewSource`, `frontend.dist`, `frontend.entry`, and allowed origins.
- Dev server never loads: check `app.zon frontend.dev.url`, command, readiness path, and `ZERO_NATIVE_FRONTEND_URL`.
- Bridge call rejects with `permission_denied`: check command origin and permissions in policy.
- Bridge call rejects with `unknown_command`: handler was not registered or command name differs.
- Chromium app fails at launch: check CEF layout, version mismatch, bundle Frameworks layout, and signing.
- Package misses frontend: check `frontend.dist`, frontend build step, and `--assets`.
