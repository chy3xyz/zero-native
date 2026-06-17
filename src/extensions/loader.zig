//! Low-level plugin loader. Provides the same dispatch table as
//! `extensions/registry.zig` but without depending on the tooling
//! `Metadata` type, so it can be imported from contexts (such as the
//! runtime) that do not have a `tooling` import wired up.

const std = @import("std");
const extensions = @import("root.zig");

pub const Error = error{
    UnknownPlugin,
    OutOfMemory,
};

const PluginConfig = struct {
    app_name: []const u8 = "",
    current_version: []const u8 = "",
    manifest_url: []const u8 = "",
    public_key_b64: []const u8 = "",
};

/// Instantiates the plugins named in `names` and returns them as a
/// freshly allocated slice. The caller owns the slice plus each
/// module's internal state and must release them with `deinitRegistry`.
///
/// Plugins are created in declaration order; `create` errors propagate
/// directly to the caller and partial creation is rolled back via an
/// `errdefer`. The optional `config` block matches the fields exposed
/// by `registry.Options`; pass an empty `PluginConfig{}` to accept
/// defaults.
pub fn loadFromNames(
    allocator: std.mem.Allocator,
    io: std.Io,
    names: []const []const u8,
    config: PluginConfig,
) ![]extensions.Module {
    if (names.len == 0) return &.{};
    const modules = try allocator.alloc(extensions.Module, names.len);
    var populated: usize = 0;
    errdefer {
        stopLoaded(modules[0..populated]);
        allocator.free(modules);
    }
    for (names, 0..) |name, index| {
        modules[index] = try createPlugin(allocator, io, name, config);
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
/// underlying allocation. Mirrors the same helper in `registry.zig` so
/// the loader can roll back partial creation.
fn stopLoaded(modules: []const extensions.Module) void {
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };
    for (modules) |module| {
        if (module.hooks.stop_fn) |stop_fn| {
            stop_fn(module.context, runtime) catch {};
        }
    }
}

/// Single dispatch point so `loadFromNames` stays linear in `names.len`.
/// Mirrors the same function in `registry.zig`; the two implementations
/// must agree on the supported plugin names. Plugin imports are scoped
/// inside the dispatch branches so that importers (e.g. the runtime
/// tests) do not pull in plugins with additional module dependencies.
fn createPlugin(
    allocator: std.mem.Allocator,
    io: std.Io,
    name: []const u8,
    config: PluginConfig,
) !extensions.Module {
    if (std.mem.eql(u8, name, "clipboard")) {
        return @import("plugin_clipboard.zig").create(allocator);
    } else if (std.mem.eql(u8, name, "shell")) {
        return @import("plugin_shell.zig").create(allocator);
    } else if (std.mem.eql(u8, name, "notification")) {
        return @import("plugin_notification.zig").create(allocator);
    } else if (std.mem.eql(u8, name, "http")) {
        return @import("plugin_http.zig").create(allocator, io);
    } else if (std.mem.eql(u8, name, "deep-link")) {
        return @import("plugin_deep_link.zig").create(allocator);
    } else if (std.mem.eql(u8, name, "store")) {
        return @import("plugin_store.zig").create(allocator);
    } else if (std.mem.eql(u8, name, "autostart")) {
        return @import("plugin_autostart.zig").create(allocator, io, config.app_name, null);
    } else if (std.mem.eql(u8, name, "single-instance")) {
        return @import("plugin_single_instance.zig").create(allocator, io);
    } else if (std.mem.eql(u8, name, "updater")) {
        return @import("plugin_updater.zig").create(allocator, io, config.current_version, config.manifest_url, config.public_key_b64);
    } else if (std.mem.eql(u8, name, "global-shortcut")) {
        return @import("plugin_global_shortcut.zig").create(allocator, io);
    } else if (std.mem.eql(u8, name, "websocket")) {
        return @import("plugin_websocket.zig").create(allocator);
    } else if (std.mem.eql(u8, name, "process")) {
        return @import("plugin_process.zig").create(allocator);
    } else if (std.mem.eql(u8, name, "os")) {
        return @import("plugin_os.zig").create(allocator);
    } else if (std.mem.eql(u8, name, "log")) {
        return @import("plugin_log.zig").create(allocator);
    } else if (std.mem.eql(u8, name, "cli")) {
        return @import("plugin_cli.zig").create(allocator);
    }
    return error.UnknownPlugin;
}
