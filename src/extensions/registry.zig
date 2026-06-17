//! Build a `ModuleRegistry` from a `tooling.manifest.Metadata` by
//! instantiating the plugins named in `metadata.plugins`.
//!
//! Known plugin names (compile-time dispatch table — no dynamic loading):
//! - "clipboard"
//! - "shell"
//! - "notification"
//! - "http"
//! - "deep-link"
//! - "store"
//! - "autostart"
//! - "single-instance"
//! - "updater"
//! - "global-shortcut"
//! - "websocket"
//! - "process"
//! - "os"
//! - "log"
//! - "cli"
//!
//! Unknown names return `error.UnknownPlugin` so typos in `app.zon` are
//! caught at load time.

const std = @import("std");
const extensions = @import("root.zig");
const tooling = @import("tooling");

const plugin_autostart = @import("plugin_autostart.zig");
const plugin_clipboard = @import("plugin_clipboard.zig");
const plugin_cli = @import("plugin_cli.zig");
const plugin_deep_link = @import("plugin_deep_link.zig");
const plugin_global_shortcut = @import("plugin_global_shortcut.zig");
const plugin_http = @import("plugin_http.zig");
const plugin_log = @import("plugin_log.zig");
const plugin_notification = @import("plugin_notification.zig");
const plugin_os = @import("plugin_os.zig");
const plugin_process = @import("plugin_process.zig");
const plugin_shell = @import("plugin_shell.zig");
const plugin_single_instance = @import("plugin_single_instance.zig");
const plugin_store = @import("plugin_store.zig");
const plugin_updater = @import("plugin_updater.zig");
const plugin_websocket = @import("plugin_websocket.zig");

pub const Error = error{
    UnknownPlugin,
    OutOfMemory,
};

pub const Options = struct {
    /// Io handle used by plugins that perform filesystem or network I/O
    /// (http, single-instance, autostart, updater). The default
    /// `std.testing.io` keeps the helper allocation-free for simple unit
    /// tests; production callers should pass a real `std.Io`.
    io: std.Io = std.testing.io,
    /// App name passed to the autostart plugin. Defaults to
    /// `metadata.id` so the helper is usable without a separate
    /// `Options` block.
    app_name: ?[]const u8 = null,
    /// Current version passed to the updater plugin. Defaults to
    /// `metadata.version`.
    current_version: ?[]const u8 = null,
    /// Update manifest URL passed to the updater plugin. Defaults to an
    /// empty string, which the updater stores without fetching.
    manifest_url: []const u8 = "",
    /// Base64 Ed25519 public key for signature verification. Empty
    /// disables verification.
    public_key_b64: []const u8 = "",
};

/// Instantiate every plugin named in `metadata.plugins` and return them as
/// a freshly allocated slice. The caller owns the slice plus each module's
/// internal state and must release them with `deinitRegistry`.
///
/// Plugins are created in declaration order. `create` errors propagate
/// directly to the caller; partial creation is rolled back via `errdefer`.
pub fn loadFromManifest(allocator: std.mem.Allocator, metadata: tooling.manifest.Metadata) ![]extensions.Module {
    return loadFromManifestWithOptions(allocator, metadata, .{});
}

/// Same as `loadFromManifest` but accepts an `Options` block for callers
/// that need to customise the Io handle or plugin-specific configuration.
pub fn loadFromManifestWithOptions(
    allocator: std.mem.Allocator,
    metadata: tooling.manifest.Metadata,
    options: Options,
) ![]extensions.Module {
    if (metadata.plugins.len == 0) return &.{};
    const modules = try allocator.alloc(extensions.Module, metadata.plugins.len);
    var populated: usize = 0;
    errdefer {
        stopLoaded(modules[0..populated]);
        allocator.free(modules);
    }

    const app_name = options.app_name orelse metadata.id;
    const current_version = options.current_version orelse metadata.version;

    for (metadata.plugins, 0..) |name, index| {
        modules[index] = try createPlugin(allocator, options.io, name, .{
            .app_name = app_name,
            .current_version = current_version,
            .manifest_url = options.manifest_url,
            .public_key_b64 = options.public_key_b64,
        });
        populated = index + 1;
    }
    return modules;
}

/// Stop every module and free the registry slice. Safe to call with an
/// empty slice (no-op).
pub fn deinitRegistry(allocator: std.mem.Allocator, modules: []extensions.Module) void {
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };
    for (modules) |module| {
        if (module.hooks.stop_fn) |stop_fn| {
            stop_fn(module.context, runtime) catch {};
        }
    }
    if (modules.len > 0) allocator.free(modules);
}

/// Stops every module in `modules[0..populated]` without freeing the
/// underlying allocation. Used by the `errdefer` inside
/// `loadFromManifestWithOptions` so partial creation does not double-free
/// when the function returns the full-length `modules` slice to the caller.
fn stopLoaded(modules: []const extensions.Module) void {
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };
    for (modules) |module| {
        if (module.hooks.stop_fn) |stop_fn| {
            stop_fn(module.context, runtime) catch {};
        }
    }
}

const PluginConfig = struct {
    app_name: []const u8,
    current_version: []const u8,
    manifest_url: []const u8,
    public_key_b64: []const u8,
};

/// Single dispatch point so `loadFromManifestWithOptions` can stay linear
/// in `metadata.plugins.len`. Each branch is the minimal call to the
/// plugin's `create` — production wiring (autostart base dir, updater
/// public key, etc.) is left to the caller via `Options`.
fn createPlugin(
    allocator: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    config: PluginConfig,
) !extensions.Module {
    if (std.mem.eql(u8, name, "clipboard")) {
        return plugin_clipboard.create(allocator);
    } else if (std.mem.eql(u8, name, "shell")) {
        return plugin_shell.create(allocator);
    } else if (std.mem.eql(u8, name, "notification")) {
        return plugin_notification.create(allocator);
    } else if (std.mem.eql(u8, name, "http")) {
        return plugin_http.create(allocator, io);
    } else if (std.mem.eql(u8, name, "deep-link")) {
        return plugin_deep_link.create(allocator);
    } else if (std.mem.eql(u8, name, "store")) {
        return plugin_store.create(allocator);
    } else if (std.mem.eql(u8, name, "autostart")) {
        return plugin_autostart.create(allocator, io, config.app_name, null);
    } else if (std.mem.eql(u8, name, "single-instance")) {
        return plugin_single_instance.create(allocator, io);
    } else if (std.mem.eql(u8, name, "updater")) {
        return plugin_updater.create(allocator, io, config.current_version, config.manifest_url, config.public_key_b64);
    } else if (std.mem.eql(u8, name, "global-shortcut")) {
        return plugin_global_shortcut.create(allocator, io);
    } else if (std.mem.eql(u8, name, "websocket")) {
        return plugin_websocket.create(allocator);
    } else if (std.mem.eql(u8, name, "process")) {
        return plugin_process.create(allocator);
    } else if (std.mem.eql(u8, name, "os")) {
        return plugin_os.create(allocator);
    } else if (std.mem.eql(u8, name, "log")) {
        return plugin_log.create(allocator);
    } else if (std.mem.eql(u8, name, "cli")) {
        return plugin_cli.create(allocator);
    }
    return error.UnknownPlugin;
}

// ── Tests ──────────────────────────────────────────────────────────────────

fn makeMetadata(allocator: std.mem.Allocator, names: []const []const u8) !tooling.manifest.Metadata {
    const id = try allocator.dupe(u8, "com.example.app");
    const name = try allocator.dupe(u8, "example");
    const version = try allocator.dupe(u8, "1.2.3");
    const web_engine = try allocator.dupe(u8, "system");
    const cef_dir = try allocator.dupe(u8, "third_party/cef/macos");
    // `Metadata.deinit` unconditionally frees `security.navigation.external_links.action`,
    // so callers that build `Metadata` directly must supply a duped value (the
    // `"deny"` default literal would crash the allocator). An empty `&.{}` is
    // skipped by `deinit`'s `len > 0` guard, but that would diverge from the
    // runtime semantics, so we duplicate the conventional default.
    const action = try allocator.dupe(u8, "deny");
    errdefer {
        allocator.free(id);
        allocator.free(name);
        allocator.free(version);
        allocator.free(web_engine);
        allocator.free(cef_dir);
        allocator.free(action);
    }
    const plugins = try allocator.alloc([]const u8, names.len);
    for (names, 0..) |value, index| {
        plugins[index] = try allocator.dupe(u8, value);
    }
    return .{
        .id = id,
        .name = name,
        .version = version,
        .plugins = plugins,
        .web_engine = web_engine,
        .cef = .{ .dir = cef_dir, .auto_install = false },
        .security = .{
            .navigation = .{
                .external_links = .{ .action = action },
            },
        },
    };
}

test "registry loads all 11 plugins successfully" {
    const allocator = std.testing.allocator;
    const all_names = [_][]const u8{
        "clipboard",
        "shell",
        "notification",
        "http",
        "deep-link",
        "store",
        "autostart",
        "single-instance",
        "updater",
        "global-shortcut",
        "websocket",
    };

    const metadata = try makeMetadata(allocator, &all_names);
    defer metadata.deinit(allocator);

    const modules = try loadFromManifest(allocator, metadata);
    defer deinitRegistry(allocator, modules);

    try std.testing.expectEqual(@as(usize, all_names.len), modules.len);
    for (modules) |module| {
        try std.testing.expect(module.info.id != 0);
    }
}

test "registry loads a subset of plugins" {
    const allocator = std.testing.allocator;
    const subset = [_][]const u8{ "clipboard", "http" };

    const metadata = try makeMetadata(allocator, &subset);
    defer metadata.deinit(allocator);

    const modules = try loadFromManifest(allocator, metadata);
    defer deinitRegistry(allocator, modules);

    try std.testing.expectEqual(@as(usize, subset.len), modules.len);
    try std.testing.expectEqualStrings("clipboard", modules[0].info.name);
    try std.testing.expectEqualStrings("http", modules[1].info.name);
}

test "registry returns UnknownPlugin for an unknown name" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "clipboard", "definitely-not-a-plugin" };

    const metadata = try makeMetadata(allocator, &names);
    defer metadata.deinit(allocator);

    const result = loadFromManifest(allocator, metadata);
    try std.testing.expectError(error.UnknownPlugin, result);
}

test "registry returns empty slice when no plugins are listed" {
    const allocator = std.testing.allocator;
    const empty: []const []const u8 = &.{};

    const metadata = try makeMetadata(allocator, empty);
    defer metadata.deinit(allocator);

    const modules = try loadFromManifest(allocator, metadata);
    try std.testing.expectEqual(@as(usize, 0), modules.len);
}

test "registry produces modules with unique non-zero ids" {
    const allocator = std.testing.allocator;
    const all_names = [_][]const u8{
        "clipboard",
        "shell",
        "notification",
        "http",
        "deep-link",
        "store",
        "autostart",
        "single-instance",
        "updater",
        "global-shortcut",
        "websocket",
    };

    const metadata = try makeMetadata(allocator, &all_names);
    defer metadata.deinit(allocator);

    const modules = try loadFromManifest(allocator, metadata);
    defer deinitRegistry(allocator, modules);

    for (modules, 0..) |module, index| {
        try std.testing.expect(module.info.id != 0);
        for (modules[0..index]) |previous| {
            try std.testing.expect(previous.info.id != module.info.id);
        }
    }
}

test "registry deinitRegistry is a no-op for an empty slice" {
    const allocator = std.testing.allocator;
    // Should not crash, leak, or fail.
    deinitRegistry(allocator, &.{});
}
