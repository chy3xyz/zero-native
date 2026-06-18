# Updater app.zon wiring — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `.updates` block to `app.zon`, forward `feed_url`, `public_key`, and `check_on_start` into the updater plugin, and make `updater.check` fetch the feed when the payload is empty.

**Architecture:** Extend `RawManifest`/`Metadata` with an `updates` struct, plumb it through `extensions.registry` and `Runtime.loadPlugins` into the updater plugin's create-time config, then add a network fetch path in `plugin_updater` that is used when `updater.check` receives an empty payload or when `check_on_start` is enabled.

**Tech Stack:** Zig 0.17, `std.zon` parsing, `http_client` (HTTP + HTTPS via httpz), `update_manifest`.

---

### Task 1: Extend the manifest schema with `.updates`

**Files:**
- Modify: `src/tooling/raw_manifest.zig`
- Modify: `src/tooling/manifest.zig`

- [ ] **Step 1: Add `RawUpdates` to `raw_manifest.zig`**

```zig
pub const RawUpdates = struct {
    feed_url: []const u8 = "",
    public_key: []const u8 = "",
    check_on_start: bool = false,
};
```

Add `updates: RawUpdates = .{},` to `RawManifest`.

- [ ] **Step 2: Add `UpdatesMetadata` and field to `manifest.zig`**

```zig
pub const UpdatesMetadata = struct {
    feed_url: []const u8 = "",
    public_key: []const u8 = "",
    check_on_start: bool = false,
};
```

Add `updates: UpdatesMetadata = .{},` to `Metadata`.

- [ ] **Step 3: Copy parsed values in `parseText`**

After `metadata.plugins = try duplicateStringList(...)`:

```zig
metadata.updates = .{
    .feed_url = try allocator.dupe(u8, raw.updates.feed_url),
    .public_key = try allocator.dupe(u8, raw.updates.public_key),
    .check_on_start = raw.updates.check_on_start,
};
```

- [ ] **Step 4: Free owned strings in `Metadata.deinit`**

```zig
if (self.updates.feed_url.len > 0) allocator.free(self.updates.feed_url);
if (self.updates.public_key.len > 0) allocator.free(self.updates.public_key);
```

- [ ] **Step 5: Add parse test**

In `src/tooling/manifest.zig` tests, add a test that parses:

```zig
.{
  .id = "com.example.app",
  .name = "example",
  .version = "1.2.3",
  .updates = .{
    .feed_url = "https://example.com/feed.json",
    .public_key = "base64-key",
    .check_on_start = true,
  },
}
```

and asserts `metadata.updates.feed_url`, `metadata.updates.public_key`, and `metadata.updates.check_on_start`.

---

### Task 2: Make plugin loader config public

**Files:**
- Modify: `src/extensions/loader.zig`

- [ ] **Step 1: Export `PluginConfig`**

Change:

```zig
const PluginConfig = struct {
```

to:

```zig
pub const PluginConfig = struct {
```

This lets `Runtime.loadPlugins` accept the same config type and pass it through unchanged.

---

### Task 3: Let `Runtime.loadPlugins` accept a plugin config

**Files:**
- Modify: `src/runtime/root.zig`

- [ ] **Step 1: Add `config` to `LoadPluginsOptions`**

```zig
pub const LoadPluginsOptions = struct {
    /// Out-of-tree plugins that can be referenced by name from
    /// `plugin_names` alongside the built-in plugins.
    custom_plugins: []const extensions.Plugin = &.{},
    /// Plugin-specific configuration (app name, current version, updater
    /// feed URL / public key, etc.) forwarded to the loader.
    config: extensions_loader.PluginConfig = .{},
};
```

- [ ] **Step 2: Forward `options.config` in `loadPlugins`**

```zig
const modules = try extensions_loader.loadFromNames(allocator, io, plugin_names, .{
    .custom_plugins = options.custom_plugins,
    .config = options.config,
});
```

Wait — `loadFromNames` currently takes `config: PluginConfig` directly, not nested. Pass `options.config` as the `config` argument:

```zig
const modules = try extensions_loader.loadFromNames(allocator, io, plugin_names, options.config);
```

(If you added `.custom_plugins` inside `PluginConfig`, make sure the struct still carries `custom_plugins`.)

- [ ] **Step 3: Run `zig build test`**

Expected: compiles and passes.

---

### Task 4: Wire `extensions.registry` to derive updater config from metadata

**Files:**
- Modify: `src/extensions/registry.zig`

- [ ] **Step 1: Add `check_on_start` to registry `Options`**

```zig
pub const Options = struct {
    // ... existing fields ...
    /// Whether the updater plugin should check for updates on startup.
    /// Defaults to the value from `metadata.updates.check_on_start`.
    check_on_start: bool = false,
};
```

- [ ] **Step 2: Compute effective updater config from metadata or options**

In `loadFromManifestWithOptions`, before the loop:

```zig
const app_name = options.app_name orelse metadata.id;
const current_version = options.current_version orelse metadata.version;
const manifest_url = if (options.manifest_url.len > 0) options.manifest_url else metadata.updates.feed_url;
const public_key_b64 = if (options.public_key_b64.len > 0) options.public_key_b64 else metadata.updates.public_key;
const check_on_start = options.check_on_start or metadata.updates.check_on_start;
```

- [ ] **Step 3: Pass computed values to `createPlugin`**

```zig
modules[index] = try createPlugin(allocator, options.io, name, .{
    .app_name = app_name,
    .current_version = current_version,
    .manifest_url = manifest_url,
    .public_key_b64 = public_key_b64,
    .check_on_start = check_on_start,
    .custom_plugins = options.custom_plugins,
});
```

- [ ] **Step 4: Add `check_on_start` to the internal `PluginConfig`**

```zig
const PluginConfig = struct {
    app_name: []const u8 = "",
    current_version: []const u8 = "",
    manifest_url: []const u8 = "",
    public_key_b64: []const u8 = "",
    check_on_start: bool = false,
    custom_plugins: []const extensions.Plugin = &.{},
};
```

- [ ] **Step 5: Pass `check_on_start` when creating the updater plugin**

```zig
} else if (std.mem.eql(u8, name, "updater")) {
    return plugin_updater.create(allocator, io, config.current_version, config.manifest_url, config.public_key_b64, config.check_on_start);
}
```

- [ ] **Step 6: Add registry test**

Add a test in `src/extensions/registry.zig` that builds metadata with `.updates = { feed_url, public_key, check_on_start = true }` and `plugins = .{"updater"}`, loads modules, and asserts the updater state has the expected values.

---

### Task 5: Make `updater.check` fetch the feed and support `check_on_start`

**Files:**
- Modify: `src/extensions/plugin_updater.zig`

- [ ] **Step 1: Add `check_on_start` to `UpdaterState`**

```zig
pub const UpdaterState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    current_version: []const u8,
    manifest_url: []const u8,
    public_key: ?[32]u8,
    check_on_start: bool = false,
    // ... rest ...
};
```

- [ ] **Step 2: Update `create` signature and state init**

```zig
pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    current_version: []const u8,
    manifest_url: []const u8,
    public_key_b64: []const u8,
    check_on_start: bool,
) !extensions.Module {
```

Set `state.check_on_start = check_on_start;`.

- [ ] **Step 3: Implement `start` to auto-check when configured**

```zig
pub fn start(context: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const state: *UpdaterState = @ptrCast(@alignCast(context));
    if (state.check_on_start and state.manifest_url.len > 0) {
        handleCheck(state, "") catch {};
    }
}
```

- [ ] **Step 4: Fetch the manifest when `handleCheck` receives an empty payload**

```zig
fn handleCheck(state: *UpdaterState, payload: []const u8) !void {
    if (state.manifest) |*prev| {
        update_manifest.deinitManifest(prev, state.allocator);
    }
    state.manifest = null;

    const manifest_json = if (payload.len > 0)
        payload
    else
        try fetchManifestJson(state);
    defer if (payload.len == 0) state.allocator.free(manifest_json);

    const manifest = try update_manifest.parseManifest(state.allocator, manifest_json);
    state.manifest = manifest;

    const current = try update_manifest.parseVersion(state.current_version);
    const order = update_manifest.compareVersion(manifest.version, current);
    state.update_available = order == .gt;
}
```

- [ ] **Step 5: Implement `fetchManifestJson`**

```zig
fn fetchManifestJson(state: *UpdaterState) ![]u8 {
    if (state.manifest_url.len == 0) return error.NoManifestUrl;

    const url = http_client.Url.parse(state.manifest_url) orelse return error.InvalidUrl;
    const response = if (std.mem.eql(u8, url.scheme, "https"))
        try http_client.requestHttps(state.allocator, state.io, .{
            .method = .GET,
            .url = url,
            .max_response_size = 10 * 1024 * 1024,
        })
    else
        try http_client.request(state.allocator, state.io, .{
            .method = .GET,
            .url = url,
            .max_response_size = 10 * 1024 * 1024,
        });
    defer state.allocator.free(response.body);

    if (response.status != 200) return error.DownloadFailed;
    return state.allocator.dupe(u8, response.body);
}
```

Add `NoManifestUrl` to the command error path or allow it to propagate as an error that `start` catches.

- [ ] **Step 6: Update existing tests to pass `check_on_start: false`**

Every `plugin_updater.create(...)` call in tests needs an extra `false` argument. Add a new test that calls `create(..., true)` and asserts `start` does not crash when the URL is unreachable.

---

### Task 6: Update documentation

**Files:**
- Modify: `docs/src/app/updates/page.mdx`
- Modify: `docs/src/app/extensions/plugins/updater/page.mdx`
- Modify: `docs/src/app/extensions/page.mdx`

- [ ] **Step 1: Update `updates` page**

- Remove the outdated "HTTPS not supported" warning.
- Document that `check_on_start = true` causes the runtime to fetch the feed during plugin startup.
- Keep the existing `.updates` block example.

- [ ] **Step 2: Update `updater` plugin page**

- Update the `create` signature to include `check_on_start`.
- Document that `updater.check` with an empty payload fetches from `state.manifest_url`.
- Document the auto-check-on-start behavior.

- [ ] **Step 3: Update `extensions` page example**

If the page shows `runtime.loadPlugins(allocator, io, metadata.plugins, .{})`, update it to show how to pass updater config:

```zig
try runtime.loadPlugins(allocator, io, metadata.plugins, .{
    .config = .{
        .app_name = metadata.id,
        .current_version = metadata.version,
        .manifest_url = metadata.updates.feed_url,
        .public_key_b64 = metadata.updates.public_key,
        .check_on_start = metadata.updates.check_on_start,
    },
});
```

---

### Task 7: Verify everything

- [ ] **Step 1: Run Zig tests**

```bash
zig build test
zig build test-extensions
```

Expected: all pass.

- [ ] **Step 2: Build docs**

```bash
cd docs && pnpm build
```

Expected: no TypeScript/MDX errors.

---

## Self-review

- **Spec coverage:** `.updates` block parsing (Task 1), loader/registry wiring (Tasks 2–4), empty-payload fetch + `check_on_start` (Task 5), docs (Task 6), tests (throughout).
- **Placeholders:** None.
- **Type consistency:** `PluginConfig` gains `check_on_start: bool` and is used by loader, registry, and runtime options.
