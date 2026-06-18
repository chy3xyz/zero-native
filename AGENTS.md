# Agent Rules

## AI Developer Guide

This document is the primary onboarding reference for AI coding agents working on the zero-native repository.

### Build Commands

```bash
zig build                    # Build the CLI binary
zig build test               # Run framework tests (Linux + macOS)
zig build test-extensions    # Run extension module + plugin tests
zig build run                # Build and run the current app
cd docs && pnpm install && pnpm build  # Build the docs site
```

All test targets pass on macOS. On Linux, `zig build test` requires `libsqlite3-dev`. On Windows, only `zig build` is tested.

### Zig Version

The project builds with **Zig 0.17.0-dev.813+2153f8143**. CI uses `mlugg/setup-zig@v2` with this exact version. The minimum Zig version declared in `build.zig.zon` is `0.17.0`.

### Zig 0.17 API Gotchas

These are the recurring API differences that trip up every agent:

1. **`std.ArrayList` is unmanaged**. Use `.empty` to create, pass allocator to `append`, `appendSlice`, `deinit`, `toOwnedSlice`. Never call `.init(allocator)`.

2. **`std.json` API changed**. `stringifyAlloc` / `valueAlloc` unavailable. Use `std.json.Stringify` + `std.Io.Writer.Allocating` instead.

3. **`std.posix.getenv` does not exist**. For env vars, use `std.c.getenv` when libc is linked, or avoid it in pure-Zig test targets.

4. **`std.time.milliTimestamp` does not exist**. Use `std.time.nanoTimestamp()` or `std.time.microTimestamp()` (check which is actually available in the current dev build).

5. **No multi-character literals**. Carbon four-character codes like `'keyb'` must be hex: `0x6B657962`.

6. **`anyopaque` not allowed as extern fn parameter**. Use `*anyopaque` or `?*anyopaque`.

7. **`@cImport` requires `link_libc = true`** on the compilation module. Pure Zig test targets do not link libc.

8. **".pointless discard of function parameter"** is strict in 0.17. If a parameter is used in one branch and discarded in another, restructure with `comptime if` to eliminate dead branches entirely.

### Project Architecture

```
src/
├── root.zig              # Public C ABI surface + re-exports
├── runtime/root.zig      # Runtime event loop, windows, bridge dispatch
├── platform/
│   ├── root.zig          # PlatformServices interface + NullPlatform
│   ├── macos/root.zig    # MacPlatform (AppKit host bindings)
│   ├── linux/root.zig    # LinuxPlatform (GTK host bindings)
│   └── windows/root.zig  # WindowsPlatform (stub)
├── extensions/
│   ├── root.zig          # Module/Plugin/Capability/ModuleRegistry types
│   ├── loader.zig        # Low-level plugin dispatch (no tooling dep)
│   ├── registry.zig      # High-level plugin dispatch (uses Metadata)
│   ├── all.zig           # Integration test: all 24 plugins
│   └── plugin_*.zig      # Individual plugin modules
├── bridge/               # Bridge types, codegen, Channel<T>
├── tooling/              # CLI tools: manifest, package, installer, templates
├── security/             # CSP, sandbox, capabilities
├── primitives/           # geometry, app_dirs, trace, json, app_manifest, etc.
└── frontend/             # Asset serving, SPA fallback
tools/
├── zero-native/main.zig  # CLI entry point
└── cef/                  # CEF build scripts
packages/zero-native/     # npm package
docs/                     # Next.js documentation site
```

### Plugin Development Convention

Every plugin follows the same pattern:

```zig
// plugin_<name>.zig
pub const ModuleId: extensions.ModuleId = <unique_id>;
pub const module_name: []const u8 = "<name>";
pub const capabilities: []const extensions.Capability = &.{.{ .kind = .custom, .name = "<name>" }};

pub fn create(allocator: std.mem.Allocator, ...) !extensions.Module { ... }
pub fn start(context: *anyopaque, runtime: extensions.RuntimeContext) anyerror!void { ... }
pub fn stop(context: *anyopaque, runtime: extensions.RuntimeContext) anyerror!void { ... }
pub fn command(context: *anyopaque, runtime: extensions.RuntimeContext, cmd: extensions.Command) anyerror!void { ... }
```

Registration checklist when adding a new plugin:
1. Create `src/extensions/plugin_<name>.zig`
2. Import and dispatch in `src/extensions/registry.zig` (createPlugin)
3. Import and dispatch in `src/extensions/loader.zig` (createPlugin)
4. Import and add create call in `src/extensions/all.zig` (bump array size)
5. Add to all_names lists in registry tests
6. Assign a unique ModuleId (current max: 124)

### Testing Patterns

- Plugins use `std.testing.allocator` for leak detection. Always call `stop` or `stop_fn` in defer.
- `runtime: extensions.RuntimeContext` with `platform_name = "null"` for tests. Services will be null.
- Access PlatformServices in plugins via `const services: ?*const platform.PlatformServices = @ptrCast(@alignCast(runtime.services));` — gracefully handle null for tests.
- `zig build test-extensions` runs plugin integration (all.zig).

### Known Limitations

- **Windows host**: C/C++ host files exist (`cef_host.cpp`, `webview2_host.cpp`) but do not implement `zero_native_windows_*` functions. Notification, tray, dialogs, shortcuts return `UnsupportedService` on Windows.
- **Linux shortcuts**: X11/XCB hotkey bridge pending. Parsing exists in `src/platform/linux/hotkey.zig`, but no C bridge yet.
- **env plugin**: Uses `std.c.getenv` which requires libc linking. Currently records key only in pure-Zig test target.
- **wss://**: Works via httpz/OpenSSL but has no end-to-end test (requires running echo server with TLS certs).

## Releasing

Releases are manual, single-PR affairs. The maintainer controls the changelog voice and format.

To prepare a release:

1. Create a branch (e.g. `prepare-v1.2.0`)
2. Bump the version in `packages/zero-native/package.json`
3. Run `npm --prefix packages/zero-native run version:sync` to update all version references
4. Write the changelog entry in `CHANGELOG.md`, wrapped in `<!-- release:start -->` and `<!-- release:end -->` markers
5. Remove the `<!-- release:start -->` and `<!-- release:end -->` markers from the previous release entry; only the latest release should have markers
6. Open a PR and merge to `main`

CI compares the version in `packages/zero-native/package.json` to what's on npm. If it differs, it publishes the CLI package and creates the GitHub release automatically. If npm already has the version but the GitHub release is missing, CI creates the GitHub release from the marked changelog entry.
