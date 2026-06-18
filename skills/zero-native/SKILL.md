---
name: zero-native
description: Discovery skill for zero-native, a Zig desktop app shell for building native apps with web UIs. Use when the user asks what zero-native is, how to build a zero-native app, scaffold a frontend app, configure app.zon, choose a WebView engine, add bridge commands, package an app, test a running app, or automate a zero-native WebView shell. Also use when implementing, debugging, or extending zero-native itself (plugins, platform, bridge, packaging).
allowed-tools: Bash(zero-native:*), Bash(npx zero-native:*), Bash(zig build:*), Bash(zig build test:*), Bash(zig build test-extensions:*)
hidden: true
---

# zero-native — AI Developer Reference

## Project Overview

zero-native is a Zig desktop app shell. It provides a native macOS/Linux/Windows shell that hosts web frontends through the platform WebView (WKWebView/WebKitGTK) or bundled Chromium/CEF.

**Current state**: Beta (~4.1/5 production readiness). macOS production-ready. Linux functional. Windows build paths exist but C/C++ host incomplete.

**Repo**: `chy3xyz/zero-native` | **Zig version**: `0.17.0-dev.813+2153f8143`

## Quick Build Commands

```bash
zig build                    # Build CLI
zig build test               # Framework tests
zig build test-extensions    # Plugin integration tests
zig build -Dsqlite=true      # With SQLite plugin
cd docs && pnpm build        # Docs site
```

## Critical Zig 0.17 API Differences

When writing Zig code for this project, these are the most common pitfalls:

1. **ArrayList is unmanaged**: `var list = std.ArrayList(T).empty;` then `list.append(allocator, item)`.
2. **No `std.process.getenv`**: Use `std.c.getenv` (needs libc) or bypass.
3. **No `std.time.milliTimestamp`**: Check available timestamp fn; `std.time.nanoTimestamp()` may work.
4. **No multi-char literals**: Use hex e.g. `0x6B657962` instead of `'keyb'`.
5. **`anyopaque` not allowed in extern fn params**: Use `*anyopaque` or `?*anyopaque`.
6. **`@cImport` needs `link_libc = true`**: Pure Zig test targets can't use `@cImport`.
7. **Strict unused-parameter linting**: Use `comptime if` to eliminate dead branches rather than `_ = param`.

## Architecture

```
src/root.zig              # Public C ABI + re-exports
src/runtime/root.zig      # Runtime: event loop, windows, bridge, plugins
src/platform/root.zig     # PlatformServices interface, NullPlatform
src/platform/macos/root.zig  # MacPlatform (AppKit host)
src/platform/linux/root.zig  # LinuxPlatform (GTK host)
src/extensions/           # Plugin system: 24 bundled plugins
src/extensions/loader.zig    # Low-level plugin dispatch
src/extensions/registry.zig  # High-level dispatch (uses Metadata)
src/extensions/all.zig       # Integration test
src/bridge/               # Bridge types, Channel<T>, codegen
src/tooling/              # CLI: manifest, package, installer, templates
src/primitives/           # geometry, app_dirs, trace, json, etc.
tools/zero-native/main.zig  # CLI entry point
packages/zero-native/     # npm wrapper
docs/                     # Next.js docs site
```

## Plugin Development

Adding a new plugin (for agents):

1. Create `src/extensions/plugin_<name>.zig` with ModuleId/start/stop/command/create
2. Register in `src/extensions/registry.zig` (import + createPlugin dispatch)
3. Register in `src/extensions/loader.zig` (import + createPlugin dispatch)
4. Add to `src/extensions/all.zig` (import, bump array, add create call)
5. Add plugin name to `all_names` lists in registry tests
6. Assign unique ModuleId (current range: 100-124)

Plugin template:
```zig
pub const ModuleId: extensions.ModuleId = <id>;
pub const module_name: []const u8 = "<name>";
pub fn create(allocator: std.mem.Allocator, ...) !extensions.Module { ... }
pub fn start(context: *anyopaque, runtime: extensions.RuntimeContext) anyerror!void {}
pub fn stop(context: *anyopaque, runtime: extensions.RuntimeContext) anyerror!void {}
pub fn command(context: *anyopaque, runtime: extensions.RuntimeContext, cmd: extensions.Command) anyerror!void {}
```

To access PlatformServices (dialogs, windows, tray):
```zig
const platform = @import("platform");
const services: ?*const platform.PlatformServices = @ptrCast(@alignCast(runtime.services));
```

## Known Limitations

- Windows host not implemented (tray/notifications/dialogs/shortcuts return UnsupportedService)
- Linux shortcuts: parsing exists, no X11 C bridge
- env plugin: `std.c.getenv` needs libc; records key only in test
- wss:// works via httpz/OpenSSL, no end-to-end test

## Plugin Reference

24 bundled plugins (ModuleId 100-124). Key plugins for app development:

| Plugin | ID | Commands |
|--------|:--:|------|
| clipboard | 100 | write_text, read_text |
| notification | 102 | notify |
| store | 105 | set, get, remove (disk-persisted) |
| updater | 108 | check, download, install (Ed25519) |
| websocket | 110 | connect, send, close (ws:// + wss://) |
| path | 117 | data, config, cache, home, temp |
| fs | 118 | read, write, exists, remove, list |
| dialog | 119 | open, save, message |
| random | 121 | bytes, uuid |
| crypto | 122 | sha256, sha1 |
| window | 123 | create, focus, close |
| tray | 124 | init, add, update |
