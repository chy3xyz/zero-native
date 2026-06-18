# zero-native

[![CI](https://github.com/chy3xyz/zero-native/actions/workflows/ci.yml/badge.svg)](https://github.com/chy3xyz/zero-native/actions/workflows/ci.yml)

Build native desktop apps with web UI. Tiny binaries. Minimal memory. Instant rebuilds.

24 bundled plugins · Capabilities v2 · Channel streaming · App Sandbox · Auto-updater · Deep-link · Global Shortcuts

zero-native is a Zig desktop app shell for modern web frontends. Use the platform WebView when you want the smallest possible app, or bundle Chromium through CEF when rendering consistency matters.

## Quick Start

Install the CLI:

```bash
npm install -g zero-native
```

Create and run an app:

```bash
zero-native init my_app --frontend next
cd my_app
zig build run
```

The first run installs frontend dependencies, builds the generated native shell, and opens a desktop window rendering your web UI.

Read the full guide at [zero-native.dev/quick-start](https://zero-native.dev/quick-start).

## Why zero-native

### Tiny and fast

System WebView apps do not bundle a browser runtime, so the native shell stays small and starts quickly. Your app uses WKWebView on macOS and WebKitGTK on Linux.

### Choose your web engine

Pick the engine that fits the product. System WebView gives you a lightweight native footprint. Chromium through CEF gives you predictable rendering and a pinned web platform on supported targets.

### Fast native rebuilds

The native layer is Zig, so app logic, bridge commands, and platform integrations rebuild quickly. Your frontend can still use the web tooling you already know.

### Native power without heavy glue

Zig calls C directly, which keeps platform SDKs, native libraries, codecs, and local system integrations within reach when the WebView layer needs to do real native work.

### Explicit security model

The WebView is treated as untrusted by default. Native commands, permissions, navigation, external links, and window APIs are opt-in and policy controlled.

## Status

zero-native is in beta. macOS desktop is production-ready (WKWebView and Chromium/CEF). Linux GTK is functional with runtime-tested plugins. Windows build paths exist but the C/C++ host is not yet complete.

## Bundled Plugins (24 total)

| # | Plugin | ModuleId | Description |
|:--:|------|:--:|------|
| 1 | clipboard | 100 | Native read/write (pbcopy/xclip/Get-Clipboard) |
| 2 | shell | 101 | Spawn child processes |
| 3 | notification | 102 | Native notifications (macOS/Linux) |
| 4 | http | 103 | HTTP/1.1 + HTTPS via httpz/OpenSSL |
| 5 | deep-link | 104 | URL scheme registration + launch routing |
| 6 | store | 105 | Key-value store with JSON disk persistence |
| 7 | autostart | 106 | OS-level autostart file management |
| 8 | single-instance | 107 | Lock file mutex |
| 9 | updater | 108 | Manifest fetch, Ed25519 verify, platform install |
| 10 | global-shortcut | 109 | Hotkey registration (macOS Carbon) |
| 11 | websocket | 110 | RFC 6455 ws:// + wss:// (httpz TLS) |
| 12 | process | 112 | Exit and relaunch |
| 13 | os | 113 | Host OS metadata |
| 14 | log | 114 | Frontend log buffering |
| 15 | cli | 115 | argv and subcommand matching |
| 16 | sql | 116 | Embedded SQLite (`-Dsqlite`) |
| 17 | path | 117 | App data/config/cache/home/temp dirs |
| 18 | fs | 118 | File read/write/exists/remove/list |
| 19 | dialog | 119 | Native open/save/message dialogs |
| 20 | env | 120 | Environment variable access |
| 21 | random | 121 | Crypto random bytes + UUID |
| 22 | crypto | 122 | SHA-256 / SHA-1 hashing |
| 23 | window | 123 | Multi-window create/focus/close |
| 24 | tray | 124 | System tray menu management |

## Core Concepts

`App` is the small Zig object that describes your application: name, WebView source, lifecycle hooks, and optional native services.

`Runtime` owns the event loop, windows, bridge dispatch, automation hooks, tracing, and platform services.

`WebViewSource` tells the runtime what to load: inline HTML, a URL, or packaged frontend assets served from a local app origin.

`app.zon` is the app manifest. It declares app metadata, icons, windows, frontend assets, web engine selection, security policy, bridge permissions, and packaging inputs.

`window.zero.invoke()` is the JavaScript-to-Zig bridge. Calls are size-limited, origin checked, permission checked, and routed only to registered handlers.

## Configuration

Most project-level behavior lives in `app.zon`:

```zig
.{
    .id = "com.example.my-app",
    .name = "my-app",
    .display_name = "My App",
    .version = "0.1.0",
    .web_engine = "system",
    .permissions = .{ "window" },
    .feature_capabilities = .{ "webview", "js_bridge" },
    .plugins = .{ "clipboard", "store", "updater" },
    .updates = .{
        .feed_url = "https://example.com/releases/feed.json",
        .public_key = "base64-ed25519-public-key",
        .check_on_start = true,
    },
    .deep_link_schemes = .{ "myapp" },
    .security = .{
        .navigation = .{
            .allowed_origins = .{ "zero://app", "http://127.0.0.1:5173" },
        },
    },
    .windows = .{
        .{ .label = "main", .title = "My App", .width = 960, .height = 640 },
    },
}
```

Use `.web_engine = "system"` for the platform WebView. On supported macOS builds, use `.web_engine = "chromium"` with a `.cef` config when you want to bundle Chromium.

## Documentation

The full documentation is at [zero-native.dev](https://zero-native.dev).

- [Quick Start](https://zero-native.dev/quick-start)
- [Web Engines](https://zero-native.dev/web-engines)
- [App Model](https://zero-native.dev/app-model)
- [Bridge](https://zero-native.dev/bridge)
- [Security](https://zero-native.dev/security)
- [Packaging](https://zero-native.dev/packaging)

## Examples

Framework-specific starter examples live in `examples/`:

- `examples/next`
- `examples/react`
- `examples/svelte`
- `examples/vue`

Each example is a complete zero-native app with `app.zon`, a Zig shell, and a minimal frontend project. Run one with `zig build run` from its directory.

Mobile embedding examples are available too:

- `examples/ios`
- `examples/android`

These show how an iOS or Android host app links the zero-native C ABI from `libzero-native.a`.

For local framework development, see [CONTRIBUTING.md](./CONTRIBUTING.md).
