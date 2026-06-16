//! Autostart plugin module — manages OS-level autostart registration.
//!
//! Platform-specific autostart paths:
//! - macOS:  ~/Library/LaunchAgents/com.<app>.plist
//! - Linux:  ~/.config/autostart/<app>.desktop
//!
//! The plugin accepts an `app_name` parameter in `create` so it can build the
//! canonical path. For testing, pass an explicit `base_dir` to override the
//! home-directory lookup.
//!
//! Commands are routed by `cmd.name`:
//! - `autostart.enable`  — writes the autostart file (creates parent dirs).
//! - `autostart.disable` — removes the autostart file if it exists.
//! - `autostart.status`  — sets `state.enabled` according to file existence.

const std = @import("std");
const extensions = @import("root.zig");

const Io = std.Io;

/// Unique module id for the autostart plugin.
pub const ModuleId: extensions.ModuleId = 106;

/// Mutable state owned by an autostart module instance.
pub const AutostartState = struct {
    enabled: bool = false,
    path: ?[]u8,
    io: Io,
    allocator: std.mem.Allocator,
};

// ── Lifecycle hooks ─────────────────────────────────────────────────────────

pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}

pub fn stop(context: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const state: *AutostartState = @ptrCast(@alignCast(context));
    if (state.path) |path| state.allocator.free(path);
    state.allocator.destroy(state);
}

// ── Command dispatch ────────────────────────────────────────────────────────

pub fn command(
    context: *anyopaque,
    _: extensions.RuntimeContext,
    cmd: extensions.Command,
) anyerror!void {
    const state: *AutostartState = @ptrCast(@alignCast(context));

    if (std.mem.eql(u8, cmd.name, "autostart.enable")) {
        try enableAutostart(state);
    } else if (std.mem.eql(u8, cmd.name, "autostart.disable")) {
        try disableAutostart(state);
    } else if (std.mem.eql(u8, cmd.name, "autostart.status")) {
        state.enabled = fileExists(state);
    }
}

// ── Factory ─────────────────────────────────────────────────────────────────

/// Create an autostart plugin instance.
///
/// `app_name` is used to build the file name (e.g. `com.<name>.plist` on macOS).
/// When `base_dir` is non-null it replaces the home directory; useful for tests.
pub fn create(
    allocator: std.mem.Allocator,
    io: Io,
    app_name: []const u8,
    base_dir: ?[]const u8,
) !extensions.Module {
    const state = try allocator.create(AutostartState);
    errdefer allocator.destroy(state);

    const owns_home = base_dir == null;
    const home = if (owns_home)
        try getHomeDir(allocator)
    else
        base_dir.?;
    errdefer if (owns_home) allocator.free(home);

    const path = try buildAutostartPath(allocator, home, app_name);
    errdefer allocator.free(path);
    if (owns_home) allocator.free(home);

    state.* = .{
        .enabled = false,
        .path = path,
        .io = io,
        .allocator = allocator,
    };

    const capabilities = [_]extensions.Capability{.{ .kind = .custom, .name = "autostart" }};
    return .{
        .info = .{
            .id = ModuleId,
            .name = "autostart",
            .capabilities = &capabilities,
        },
        .context = @ptrCast(state),
        .hooks = .{
            .start_fn = start,
            .stop_fn = stop,
            .command_fn = command,
        },
    };
}

// ── Internal helpers ────────────────────────────────────────────────────────

fn getHomeDir(allocator: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("HOME")) |home| {
        return allocator.dupe(u8, std.mem.sliceTo(home, 0));
    }
    return allocator.dupe(u8, "/tmp");
}

/// Build the canonical autostart path for the current platform.
/// `home` is borrowed; the returned slice is owned and must be freed.
fn buildAutostartPath(
    allocator: std.mem.Allocator,
    home: []const u8,
    app_name: []const u8,
) ![]u8 {
    const target = @import("builtin").target;

    if (target.os.tag == .macos or target.os.tag == .ios or target.os.tag == .tvos or
        target.os.tag == .watchos or target.os.tag == .visionos)
    {
        // macOS: ~/Library/LaunchAgents/com.<app>.plist
        const dir = try std.fs.path.join(allocator, &.{ home, "Library", "LaunchAgents" });
        defer allocator.free(dir);
        const filename = try std.fmt.allocPrint(allocator, "com.{s}.plist", .{app_name});
        defer allocator.free(filename);
        return std.fs.path.join(allocator, &.{ dir, filename });
    } else {
        // Linux / BSD / other: ~/.config/autostart/<app>.desktop
        const dir = try std.fs.path.join(allocator, &.{ home, ".config", "autostart" });
        defer allocator.free(dir);
        const filename = try std.fmt.allocPrint(allocator, "{s}.desktop", .{app_name});
        defer allocator.free(filename);
        return std.fs.path.join(allocator, &.{ dir, filename });
    }
}

fn enableAutostart(state: *AutostartState) !void {
    const path = state.path orelse return;

    // Create parent directories if they don't exist.
    if (std.fs.path.dirname(path)) |parent| {
        Io.Dir.cwd().createDirPath(state.io, parent) catch {};
    }

    const file = try Io.Dir.cwd().createFile(state.io, path, .{});
    defer file.close(state.io);

    var write_buf: [4096]u8 = undefined;
    var writer = file.writer(state.io, &write_buf);

    const target = @import("builtin").target;
    if (target.os.tag == .macos or target.os.tag == .ios or target.os.tag == .tvos or
        target.os.tag == .watchos or target.os.tag == .visionos)
    {
        try writer.interface.writeAll(
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
            \\  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0">
            \\<dict>
            \\    <key>Label</key>
            \\    <string>com.REPLACE_ME</string>
            \\    <key>ProgramArguments</key>
            \\    <array>
            \\        <string>REPLACE_ME</string>
            \\    </array>
            \\    <key>RunAtLoad</key>
            \\    <true/>
            \\</dict>
            \\</plist>
            \\
        );
    } else {
        try writer.interface.writeAll(
            \\[Desktop Entry]
            \\Type=Application
            \\Name=REPLACE_ME
            \\Exec=REPLACE_ME
            \\X-GNOME-Autostart-enabled=true
            \\
        );
    }
    try writer.flush();
}

fn disableAutostart(state: *AutostartState) !void {
    const path = state.path orelse return;
    Io.Dir.cwd().deleteFile(state.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn fileExists(state: *AutostartState) bool {
    const path = state.path orelse return false;
    _ = Io.Dir.cwd().statFile(state.io, path, .{}) catch return false;
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// Build a cleaned-up temp dir path under .zig-cache for testing.
fn makeTestDir(allocator: std.mem.Allocator, io: Io) ![]u8 {
    const base = try std.fs.path.join(allocator, &.{ ".zig-cache", "test-autostart" });
    errdefer allocator.free(base);
    Io.Dir.cwd().createDirPath(io, base) catch {};
    return base;
}

test "plugin_autostart: enable creates the file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const base_dir = try makeTestDir(allocator, io);
    defer allocator.free(base_dir);
    defer { Io.Dir.cwd().deleteTree(io, base_dir) catch {}; }

    const runtime = extensions.RuntimeContext{ .platform_name = "null" };

    const module = try create(allocator, io, "testapp", base_dir);
    defer { module.hooks.stop_fn.?(module.context, runtime) catch {}; }

    const state: *AutostartState = @ptrCast(@alignCast(module.context));

    try std.testing.expect(!state.enabled);
    try std.testing.expect(!fileExists(state));

    try command(module.context, runtime, .{ .name = "autostart.enable" });
    try std.testing.expect(fileExists(state));
}

test "plugin_autostart: disable removes the file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const base_dir = try makeTestDir(allocator, io);
    defer allocator.free(base_dir);
    defer { Io.Dir.cwd().deleteTree(io, base_dir) catch {}; }

    const runtime = extensions.RuntimeContext{ .platform_name = "null" };

    const module = try create(allocator, io, "testapp", base_dir);
    defer { module.hooks.stop_fn.?(module.context, runtime) catch {}; }

    const state: *AutostartState = @ptrCast(@alignCast(module.context));

    try command(module.context, runtime, .{ .name = "autostart.enable" });
    try std.testing.expect(fileExists(state));

    try command(module.context, runtime, .{ .name = "autostart.disable" });
    try std.testing.expect(!fileExists(state));
}

test "plugin_autostart: status reflects file state" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const base_dir = try makeTestDir(allocator, io);
    defer allocator.free(base_dir);
    defer { Io.Dir.cwd().deleteTree(io, base_dir) catch {}; }

    const runtime = extensions.RuntimeContext{ .platform_name = "null" };

    const module = try create(allocator, io, "testapp", base_dir);
    defer { module.hooks.stop_fn.?(module.context, runtime) catch {}; }

    const state: *AutostartState = @ptrCast(@alignCast(module.context));

    try command(module.context, runtime, .{ .name = "autostart.status" });
    try std.testing.expect(!state.enabled);

    try command(module.context, runtime, .{ .name = "autostart.enable" });
    try command(module.context, runtime, .{ .name = "autostart.status" });
    try std.testing.expect(state.enabled);

    try command(module.context, runtime, .{ .name = "autostart.disable" });
    try command(module.context, runtime, .{ .name = "autostart.status" });
    try std.testing.expect(!state.enabled);
}

test "plugin_autostart: start and stop do not crash" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const base_dir = try makeTestDir(allocator, io);
    defer allocator.free(base_dir);
    defer { Io.Dir.cwd().deleteTree(io, base_dir) catch {}; }

    const runtime = extensions.RuntimeContext{ .platform_name = "null" };

    const module = try create(allocator, io, "testapp", base_dir);
    defer { module.hooks.stop_fn.?(module.context, runtime) catch {}; }

    try start(module.context, runtime);
}
