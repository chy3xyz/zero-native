---
name: core
description: Explain zero-native and help build zero-native desktop apps. Use when the user asks what zero-native is, how to create a zero-native app, scaffold a frontend app, configure app.zon, choose a web engine, add a JavaScript-to-Zig bridge command, package an app, or debug a zero-native project.
---

# Build zero-native apps

zero-native is a Zig desktop app shell for modern web frontends. Apps run native Zig code around a WebView: WKWebView on macOS, WebKitGTK on Linux, and optionally Chromium through CEF where supported. Prefer the platform WebView for small apps and CEF/Chromium when rendering consistency matters.

## Quick start

Use the CLI for new apps:

```bash
npm install -g zero-native
zero-native init my_app --frontend next
cd my_app
zig build run
```

Frontend choices are `next`, `vite`, `react`, `svelte`, and `vue`. The first `zig build run` installs frontend dependencies, builds the native shell, and opens a desktop window.

## Project shape

A generated app usually has:

- `build.zig`: Zig build graph with platform, web engine, trace, debug overlay, automation, bridge, dev, test, and package steps.
- `build.zig.zon`: Zig package manifest and zero-native dependency.
- `app.zon`: app metadata, icons, windows, frontend assets, web engine, bridge policy, permissions, and navigation policy.
- `src/main.zig`: app state plus `app()` and optional `bridge()` methods.
- `src/runner.zig`: runtime wiring for platform services, tracing, panic capture, window state, security, automation, and bridge setup.
- `frontend/`: the selected framework project.

When modifying a real project, inspect the generated files first and follow the local pattern. The examples in `examples/next`, `examples/react`, `examples/svelte`, and `examples/vue` are complete reference apps.

## Core app model

The minimal Zig app returns `zero_native.App` with `context`, `name`, and a WebView source:

```zig
const App = struct {
    fn app(self: *@This()) zero_native.App {
        return .{
            .context = self,
            .name = "my-app",
            .source = zero_native.WebViewSource.html("<h1>Hello from zero-native</h1>"),
        };
    }
};
```

Use these source constructors:

- `zero_native.WebViewSource.html(content)` for small inline demos.
- `zero_native.WebViewSource.url(address)` for an explicit URL.
- `zero_native.WebViewSource.assets(.{ .root_path = "frontend/dist", .entry = "index.html" })` for packaged frontend assets.

For framework apps, prefer a dynamic source so development loads the local dev server and production loads bundled assets:

```zig
fn source(context: *anyopaque) anyerror!zero_native.WebViewSource {
    const self: *App = @ptrCast(@alignCast(context));
    return zero_native.frontend.sourceFromEnv(self.env_map, .{
        .dist = "frontend/dist",
        .entry = "index.html",
    });
}
```

`sourceFromEnv` reads `ZERO_NATIVE_FRONTEND_URL`; otherwise it serves the configured asset directory.

## app.zon essentials

Keep `app.zon` as the source of truth for app-level behavior:

```zig
.{
    .id = "com.example.my-app",
    .name = "my-app",
    .display_name = "My App",
    .version = "0.1.0",
    .icons = .{ "assets/icon.icns" },
    .platforms = .{ "macos", "linux" },
    .permissions = .{},
    .capabilities = .{ "webview" },
    .frontend = .{
        .dist = "frontend/dist",
        .entry = "index.html",
        .spa_fallback = true,
        .dev = .{
            .url = "http://127.0.0.1:5173/",
            .command = .{ "npm", "--prefix", "frontend", "run", "dev", "--", "--host", "127.0.0.1" },
            .ready_path = "/",
            .timeout_ms = 30000,
        },
    },
    .security = .{
        .navigation = .{
            .allowed_origins = .{ "zero://app", "http://127.0.0.1:5173" },
            .external_links = .{ .action = "deny" },
        },
    },
    .web_engine = "system",
    .windows = .{
        .{ .label = "main", .title = "My App", .width = 960, .height = 640, .restore_state = true },
    },
}
```

Use exact local origins for dev servers. Add `zero://inline` only for inline HTML sources.

## Frontend development

For iterative frontend work, use the managed dev server flow:

```bash
zig build dev
```

Or run the CLI directly after building the binary:

```bash
zero-native dev --manifest app.zon --binary zig-out/bin/MyApp
```

Vite usually uses `http://127.0.0.1:5173/`; Next.js usually uses `http://127.0.0.1:3000/`. The app WebView loads the dev URL directly, so framework HMR remains owned by Vite, Next.js, or the selected dev server.

## Web engine choice

Default to:

```zig
.web_engine = "system",
```

System WebView keeps app size small and startup fast. Use Chromium when the app needs a pinned web platform or tighter rendering consistency:

```zig
.web_engine = "chromium",
.cef = .{ .dir = "third_party/cef/macos", .auto_install = false },
```

Install CEF before building or packaging Chromium apps:

```bash
zero-native cef install
zig build run
```

Use one-off overrides such as `-Dweb-engine=chromium`, `-Dcef-dir=...`, or `-Dcef-auto-install=true` only when appropriate; normal app behavior should come from `app.zon`.

## Bridge commands

Use `window.zero.invoke(command, payload)` for JavaScript-to-Zig calls. Bridge commands are default-deny: a handler must be registered in Zig and allowed by policy.

Handler pattern:

```zig
fn ping(context: *anyopaque, invocation: zero_native.bridge.Invocation, output: []u8) anyerror![]const u8 {
    _ = invocation;
    const self: *App = @ptrCast(@alignCast(context));
    self.ping_count += 1;
    return std.fmt.bufPrint(output, "{{\"message\":\"pong\",\"count\":{d}}}", .{self.ping_count});
}
```

Dispatcher pattern:

```zig
fn bridge(self: *App) zero_native.BridgeDispatcher {
    self.handlers = .{.{ .name = "native.ping", .context = self, .invoke_fn = ping }};
    return .{
        .policy = .{ .enabled = true, .commands = &policies },
        .registry = .{ .handlers = &self.handlers },
    };
}
```

JavaScript pattern:

```javascript
const result = await window.zero.invoke("native.ping", { source: "webview" });
```

Return valid JSON from handlers. For user-controlled strings, use `zero_native.bridge.writeJsonStringValue(output, value)`.

## Security rules

Treat WebView content as untrusted:

- List only needed `permissions` and `capabilities`.
- Prefer exact bridge command origins over `"*"`.
- Keep main-frame navigation allowlisted in `security.navigation.allowed_origins`.
- Keep external links denied unless the product explicitly needs them.
- Use a strict CSP for packaged frontend assets.
- Built-in dialogs are always default-deny and require explicit `builtin_bridge` policy.

Common bridge failure codes are `invalid_request`, `unknown_command`, `permission_denied`, `handler_failed`, `payload_too_large`, and `internal_error`.

## Build, test, and package

Useful commands:

```bash
zig build run
zig build dev
zig build test
zero-native validate app.zon
zero-native doctor --manifest app.zon --strict
zig build package
zero-native package --target macos --manifest app.zon --binary zig-out/bin/MyApp
```

For GUI smoke tests, build with automation enabled and use the `automation` skill:

```bash
zig build run -Dplatform=macos -Dautomation=true
zig-out/bin/zero-native automate snapshot
```

When changing app behavior, add focused Zig tests when the code can run headlessly. Use automation-based tests only for WebView/runtime integration that requires a GUI-capable session.

## Agent workflow

1. Determine whether the user wants an explanation, a new scaffold, a change to an existing app, packaging, or debugging.
2. Read `app.zon`, `src/main.zig`, `src/runner.zig`, and `build.zig` before editing an existing app.
3. Keep app metadata and policies in `app.zon`; keep runtime wiring in `runner.zig`; keep product behavior in app code and frontend files.
4. Prefer generated/example patterns over inventing new build or runtime wiring.
5. Validate with the narrowest useful commands: `zig build test`, `zero-native validate app.zon`, `zero-native doctor --manifest app.zon --strict`, or `zig build run` depending on the change.
