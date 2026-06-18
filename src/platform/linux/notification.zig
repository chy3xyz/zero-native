//! Linux native notification dispatcher with safe fallbacks.
//!
//! The implementation tries, in order:
//! 1. `dbus-send` calling `org.freedesktop.Notifications.Notify`.
//! 2. `notify-send` (the libnotify CLI wrapper).
//!
//! If neither tool is available or exits non-zero, `show` returns an error so
//! the caller can fall back to an in-memory log or no-op behavior. This keeps
//! CI, headless environments, and cross-compilation working without hard
//! system-library dependencies.

const std = @import("std");

pub const NotificationOptions = struct {
    title: []const u8,
    body: []const u8 = "",
    icon: []const u8 = "",
};

pub const Error = error{
    NotificationFailed,
    OutOfMemory,
};

/// Show a native notification on Linux. Returns `error.NotificationFailed` when
/// no notification backend is available, allowing the caller to fall back.
pub fn show(allocator: std.mem.Allocator, io: std.Io, options: NotificationOptions) Error!void {
    if (try dbusSendNotify(allocator, io, options)) return;
    if (try notifySend(allocator, io, options)) return;
    return error.NotificationFailed;
}

/// Try to post via `dbus-send` directly over the session bus. Returns true on
/// success, false when the tool is missing or the call fails.
fn dbusSendNotify(allocator: std.mem.Allocator, io: std.Io, options: NotificationOptions) !bool {
    const title_arg = std.fmt.allocPrint(allocator, "string:{s}", .{options.title}) catch return error.OutOfMemory;
    defer allocator.free(title_arg);
    const body_arg = std.fmt.allocPrint(allocator, "string:{s}", .{options.body}) catch return error.OutOfMemory;
    defer allocator.free(body_arg);
    const icon_arg = std.fmt.allocPrint(allocator, "string:{s}", .{options.icon}) catch return error.OutOfMemory;
    defer allocator.free(icon_arg);

    const argv = &[_][]const u8{
        "dbus-send",
        "--session",
        "--dest=org.freedesktop.Notifications",
        "--type=method_call",
        "--print-reply",
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications.Notify",
        "string:zero-native",
        "uint32:0",
        icon_arg,
        title_arg,
        body_arg,
        "array:string:",
        "array:dict:",
        "int32:-1",
    };

    return runNotifyTool(allocator, io, argv);
}

/// Try to post via `notify-send`. Returns true on success, false when the tool
/// is missing or the call fails.
fn notifySend(allocator: std.mem.Allocator, io: std.Io, options: NotificationOptions) !bool {
    if (options.body.len == 0 and options.icon.len == 0) {
        const argv = &[_][]const u8{ "notify-send", options.title };
        return runNotifyTool(allocator, io, argv);
    }

    if (options.icon.len > 0 and options.body.len == 0) {
        const icon_arg = std.fmt.allocPrint(allocator, "--icon={s}", .{options.icon}) catch return error.OutOfMemory;
        defer allocator.free(icon_arg);
        const argv = &[_][]const u8{ "notify-send", icon_arg, options.title };
        return runNotifyTool(allocator, io, argv);
    }

    if (options.icon.len == 0 and options.body.len > 0) {
        const argv = &[_][]const u8{ "notify-send", options.title, options.body };
        return runNotifyTool(allocator, io, argv);
    }

    const icon_arg = std.fmt.allocPrint(allocator, "--icon={s}", .{options.icon}) catch return error.OutOfMemory;
    defer allocator.free(icon_arg);
    const argv = &[_][]const u8{ "notify-send", icon_arg, options.title, options.body };
    return runNotifyTool(allocator, io, argv);
}

/// Spawn `argv` and return true only if the child exits cleanly with code 0.
fn runNotifyTool(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !bool {
    _ = allocator;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(io) catch return false;
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "linux notification show tolerates missing tools" {
    // On macOS and headless CI neither dbus-send nor notify-send is expected
    // to succeed. The function must simply not crash and may return an error.
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    show(allocator, io, .{ .title = "test", .body = "body" }) catch |err| switch (err) {
        error.NotificationFailed => {},
        error.OutOfMemory => return err,
    };
}
