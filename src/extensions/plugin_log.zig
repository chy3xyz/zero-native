//! Log plugin — records log messages emitted by the frontend.
//!
//! Commands:
//! - `log.write` — payload is `"level|message"`, split on the first `|`.
//!   `level` is one of `trace`, `debug`, `info`, `warn`, `error`. The full
//!   entry (level + message) is appended to `state.entries` so tests can
//!   inspect what was logged.

const std = @import("std");
const extensions = @import("root.zig");

pub const ModuleId: extensions.ModuleId = 114;
pub const module_name: []const u8 = "log";

pub const capabilities: []const extensions.Capability = &.{
    .{ .kind = .custom, .name = "log" },
};

pub const cmd_write: []const u8 = "log.write";
pub const cmd_clear: []const u8 = "log.clear";

pub const LogLevel = enum { trace, debug, info, warn, err };

pub const LogEntry = struct {
    level: LogLevel,
    message: []const u8,
};

pub const LogState = struct {
    entries: std.ArrayList(LogEntry),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *LogState) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.message);
        }
        self.entries.deinit(self.allocator);
    }
};

pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}

pub fn stop(context: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const state: *LogState = @ptrCast(@alignCast(context));
    state.deinit();
    state.allocator.destroy(state);
}

pub fn command(
    context: *anyopaque,
    _: extensions.RuntimeContext,
    cmd: extensions.Command,
) anyerror!void {
    const state: *LogState = @ptrCast(@alignCast(context));
    if (std.mem.eql(u8, cmd.name, cmd_write)) {
        try appendEntry(state, cmd.payload);
    } else if (std.mem.eql(u8, cmd.name, cmd_clear)) {
        clearEntries(state);
    }
}

fn parseLevel(raw: []const u8) LogLevel {
    if (std.mem.eql(u8, raw, "trace")) return .trace;
    if (std.mem.eql(u8, raw, "debug")) return .debug;
    if (std.mem.eql(u8, raw, "info")) return .info;
    if (std.mem.eql(u8, raw, "warn")) return .warn;
    if (std.mem.eql(u8, raw, "error")) return .err;
    return .info;
}

fn appendEntry(state: *LogState, payload: []const u8) !void {
    const sep = std.mem.indexOfScalar(u8, payload, '|') orelse {
        try state.entries.append(state.allocator, .{ .level = .info, .message = try state.allocator.dupe(u8, payload) });
        return;
    };
    const level = parseLevel(payload[0..sep]);
    const message = try state.allocator.dupe(u8, payload[sep + 1 ..]);
    errdefer state.allocator.free(message);
    try state.entries.append(state.allocator, .{ .level = level, .message = message });
}

fn clearEntries(state: *LogState) void {
    for (state.entries.items) |entry| {
        state.allocator.free(entry.message);
    }
    state.entries.clearRetainingCapacity();
}

pub fn create(allocator: std.mem.Allocator) !extensions.Module {
    const state = try allocator.create(LogState);
    errdefer allocator.destroy(state);
    state.* = .{ .entries = .empty, .allocator = allocator };

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

test "log write records level and message" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);
    defer module.hooks.stop_fn.?(module.context, .{ .platform_name = "null" }) catch {};

    try module.hooks.command_fn.?(module.context, .{ .platform_name = "null" }, .{
        .name = "log.write",
        .payload = "warn|something happened",
        .target = ModuleId,
    });
    const state: *LogState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqual(@as(usize, 1), state.entries.items.len);
    try std.testing.expectEqual(LogLevel.warn, state.entries.items[0].level);
    try std.testing.expectEqualStrings("something happened", state.entries.items[0].message);
}

test "log clear empties entries" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);
    defer module.hooks.stop_fn.?(module.context, .{ .platform_name = "null" }) catch {};

    try module.hooks.command_fn.?(module.context, .{ .platform_name = "null" }, .{
        .name = "log.write",
        .payload = "info|hello",
        .target = ModuleId,
    });
    try module.hooks.command_fn.?(module.context, .{ .platform_name = "null" }, .{
        .name = "log.clear",
        .payload = "",
        .target = ModuleId,
    });
    const state: *LogState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqual(@as(usize, 0), state.entries.items.len);
}
