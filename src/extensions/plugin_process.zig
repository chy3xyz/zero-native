//! Process plugin — exposes OS-process control to the frontend.
//!
//! Commands:
//! - `process.exit` — payload is the exit code as decimal text. Records the
//!   requested code in `state.last_exit_code` for inspection. The actual
//!   `std.process.exit` call is invoked by the runtime when it processes
//!   the recorded request; in tests, the recording is the only side effect.
//! - `process.relaunch` — payload is ignored. Records `state.relaunch_requested = true`.

const std = @import("std");
const extensions = @import("root.zig");

pub const ModuleId: extensions.ModuleId = 112;
pub const module_name: []const u8 = "process";

pub const capabilities: []const extensions.Capability = &.{
    .{ .kind = .custom, .name = "process" },
};

pub const cmd_exit: []const u8 = "process.exit";
pub const cmd_relaunch: []const u8 = "process.relaunch";

pub const ProcessState = struct {
    last_exit_code: i32 = 0,
    relaunch_requested: bool = false,
    allocator: std.mem.Allocator,
};

pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}

pub fn stop(context: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const state: *ProcessState = @ptrCast(@alignCast(context));
    state.allocator.destroy(state);
}

pub fn command(
    context: *anyopaque,
    _: extensions.RuntimeContext,
    cmd: extensions.Command,
) anyerror!void {
    const state: *ProcessState = @ptrCast(@alignCast(context));
    if (std.mem.eql(u8, cmd.name, cmd_exit)) {
        const code = std.fmt.parseInt(i32, cmd.payload, 10) catch 0;
        state.last_exit_code = code;
    } else if (std.mem.eql(u8, cmd.name, cmd_relaunch)) {
        state.relaunch_requested = true;
    }
}

pub fn create(allocator: std.mem.Allocator) !extensions.Module {
    const state = try allocator.create(ProcessState);
    errdefer allocator.destroy(state);
    state.* = .{ .allocator = allocator };

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

test "process exit records code" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);
    defer allocator.destroy(@as(*ProcessState, @ptrCast(@alignCast(module.context))));

    try module.hooks.command_fn.?(module.context, .{ .platform_name = "null" }, .{
        .name = "process.exit",
        .payload = "42",
        .target = ModuleId,
    });
    const state: *ProcessState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqual(@as(i32, 42), state.last_exit_code);
}

test "process relaunch records flag" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);
    defer allocator.destroy(@as(*ProcessState, @ptrCast(@alignCast(module.context))));

    try module.hooks.command_fn.?(module.context, .{ .platform_name = "null" }, .{
        .name = "process.relaunch",
        .payload = "",
        .target = ModuleId,
    });
    const state: *ProcessState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(state.relaunch_requested);
}
