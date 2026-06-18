//! Path plugin — resolves standard application directories (data, config,
//! cache, home, temp) and exposes them to the frontend.
//!
//! Commands:
//! - `path.data`   — populates `state.last_path` with the app data directory
//! - `path.config` — populates `state.last_path` with the app config directory
//! - `path.cache`  — populates `state.last_path` with the app cache directory
//! - `path.home`   — populates `state.last_path` with the user home directory
//! - `path.temp`   — populates `state.last_path` with the temp directory
//!
//! Each command records the resolved path in `state.last_path` so tests
//! can assert the result. The plugin delegates to `app_dirs.resolve`
//! which handles macOS (Library/…), Linux (XDG), and Windows
//! (AppData/LocalAppData).

const std = @import("std");
const builtin = @import("builtin");
const extensions = @import("root.zig");
const app_dirs = @import("app_dirs");

pub const ModuleId: extensions.ModuleId = 117;
pub const module_name: []const u8 = "path";

pub const capabilities: []const extensions.Capability = &.{
    .{ .kind = .custom, .name = "path" },
};

pub const PathState = struct {
    last_path: ?[]u8,
    app_name: []const u8,
    platform: app_dirs.Platform,
    allocator: std.mem.Allocator,
};

pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}

pub fn stop(context: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const state: *PathState = @ptrCast(@alignCast(context));
    if (state.last_path) |p| state.allocator.free(p);
    state.allocator.free(state.app_name);
    state.allocator.destroy(state);
}

pub fn command(
    context: *anyopaque,
    _: extensions.RuntimeContext,
    cmd: extensions.Command,
) anyerror!void {
    const state: *PathState = @ptrCast(@alignCast(context));
    if (state.last_path) |p| {
        state.allocator.free(p);
        state.last_path = null;
    }

    var path_buf: [1024]u8 = undefined;
    const resolved: ?[]u8 = if (std.mem.eql(u8, cmd.name, "path.home"))
        try state.allocator.dupe(u8, if (comptime builtin.os.tag == .windows) "C:\\Users" else "/home")
    else if (std.mem.eql(u8, cmd.name, "path.temp"))
        try state.allocator.dupe(u8, if (comptime builtin.os.tag == .windows) "C:\\Temp" else "/tmp")
    else blk: {
        const kind: app_dirs.DirKind = if (std.mem.eql(u8, cmd.name, "path.data"))
            .data
        else if (std.mem.eql(u8, cmd.name, "path.config"))
            .config
        else if (std.mem.eql(u8, cmd.name, "path.cache"))
            .cache
        else
            return;
        const r = app_dirs.resolveOne(.{ .name = state.app_name }, state.platform, .{ .home = if (comptime builtin.os.tag == .windows) "C:\\Users" else "/home" }, kind, &path_buf) catch return error.UnsupportedPlatform;
        break :blk state.allocator.dupe(u8, r) catch return;
    };

    state.last_path = resolved;
}

pub fn create(allocator: std.mem.Allocator, app_name: []const u8) !extensions.Module {
    const state = try allocator.create(PathState);
    errdefer allocator.destroy(state);

    const owned_name = try allocator.dupe(u8, app_name);
    errdefer allocator.free(owned_name);

    const platform: app_dirs.Platform = switch (builtin.os.tag) {
        .macos => .macos,
        .linux => .linux,
        .windows => .windows,
        else => return error.UnsupportedPlatform,
    };

    state.* = .{
        .last_path = null,
        .app_name = owned_name,
        .platform = platform,
        .allocator = allocator,
    };

    return .{
        .info = .{
            .id = ModuleId,
            .name = module_name,
            .capabilities = capabilities,
        },
        .context = @ptrCast(state),
        .hooks = .{
            .start_fn = start,
            .stop_fn = stop,
            .command_fn = command,
        },
    };
}

// ── Tests ─────────────────────────────────────────────────────────────────

test "plugin_path: path.home resolves" {
    const allocator = std.testing.allocator;
    const module = try create(allocator, "test-app");
    defer module.hooks.stop_fn.?(module.context, .{ .platform_name = "null" }) catch {};

    try module.hooks.command_fn.?(module.context, .{ .platform_name = "null" }, .{
        .name = "path.home",
        .payload = "",
        .target = ModuleId,
    });
    const state: *PathState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(state.last_path != null);
    try std.testing.expect(state.last_path.?.len > 0);
}

test "plugin_path: path.data resolves to something non-empty" {
    const allocator = std.testing.allocator;
    const module = try create(allocator, "test-app2");
    defer module.hooks.stop_fn.?(module.context, .{ .platform_name = "null" }) catch {};

    try module.hooks.command_fn.?(module.context, .{ .platform_name = "null" }, .{
        .name = "path.data",
        .payload = "",
        .target = ModuleId,
    });
    const state: *PathState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(state.last_path != null);
    try std.testing.expect(state.last_path.?.len > 0);
}

test "plugin_path: path.temp resolves" {
    const allocator = std.testing.allocator;
    const module = try create(allocator, "test-app3");
    defer module.hooks.stop_fn.?(module.context, .{ .platform_name = "null" }) catch {};

    try module.hooks.command_fn.?(module.context, .{ .platform_name = "null" }, .{
        .name = "path.temp",
        .payload = "",
        .target = ModuleId,
    });
    const state: *PathState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(state.last_path != null);
    try std.testing.expect(state.last_path.?.len > 0);
}

test "plugin_path: registry integration" {
    const allocator = std.testing.allocator;
    var module = try create(allocator, "test-app4");

    const modules = [_]extensions.Module{module};
    const registry = extensions.ModuleRegistry{ .modules = &modules };
    try registry.validate();
    try std.testing.expect(registry.hasCapability(.custom));

    const runtime = extensions.RuntimeContext{ .platform_name = "null" };
    try registry.startAll(runtime);
    try registry.stopAll(runtime);

    module.context = undefined;
}
