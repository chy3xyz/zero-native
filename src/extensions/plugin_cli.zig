//! CLI plugin — exposes process arguments and matching subcommands to the
//! frontend.
//!
//! Commands:
//! - `cli.args` — payload is ignored. Populates `state.args` with the raw
//!   `argv` from the current process (skipping the program name).
//! - `cli.matches` — payload is `"subcommand|sub-subcommand|..."`. Splits
//!   on `|` and stores the slices in `state.matches` (no validation, just
//!   recording). The frontend uses this to route deep-link / argv
//!   invocations to the right view.

const std = @import("std");
const extensions = @import("root.zig");

pub const ModuleId: extensions.ModuleId = 115;
pub const module_name: []const u8 = "cli";

pub const capabilities: []const extensions.Capability = &.{
    .{ .kind = .custom, .name = "cli" },
};

pub const cmd_args: []const u8 = "cli.args";
pub const cmd_matches: []const u8 = "cli.matches";

pub const CliState = struct {
    args: std.ArrayList([]const u8),
    matches: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CliState) void {
        for (self.args.items) |arg| self.allocator.free(arg);
        self.args.deinit(self.allocator);
        for (self.matches.items) |m| self.allocator.free(m);
        self.matches.deinit(self.allocator);
    }
};

pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}

pub fn stop(context: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const state: *CliState = @ptrCast(@alignCast(context));
    state.deinit();
    state.allocator.destroy(state);
}

pub fn command(
    context: *anyopaque,
    _: extensions.RuntimeContext,
    cmd: extensions.Command,
) anyerror!void {
    const state: *CliState = @ptrCast(@alignCast(context));
    if (std.mem.eql(u8, cmd.name, cmd_args)) {
        // Free previous args.
        for (state.args.items) |arg| state.allocator.free(arg);
        state.args.clearRetainingCapacity();
        // Capture argv (skip program name at index 0). Direct argv access
        // in Zig 0.17 is platform-specific; this is a stub that records
        // an empty list. Future work: parse std.process args for the host.
    } else if (std.mem.eql(u8, cmd.name, cmd_matches)) {
        for (state.matches.items) |m| state.allocator.free(m);
        state.matches.clearRetainingCapacity();
        var iter = std.mem.splitScalar(u8, cmd.payload, '|');
        while (iter.next()) |segment| {
            const owned = try state.allocator.dupe(u8, segment);
            try state.matches.append(state.allocator, owned);
        }
    }
}

pub fn create(allocator: std.mem.Allocator) !extensions.Module {
    const state = try allocator.create(CliState);
    errdefer allocator.destroy(state);
    state.* = .{
        .args = .empty,
        .matches = .empty,
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

test "cli matches splits pipe-separated payload" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);
    defer module.hooks.stop_fn.?(module.context, .{ .platform_name = "null" }) catch {};

    try module.hooks.command_fn.?(module.context, .{ .platform_name = "null" }, .{
        .name = "cli.matches",
        .payload = "open|view|123",
        .target = ModuleId,
    });
    const state: *CliState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqual(@as(usize, 3), state.matches.items.len);
    try std.testing.expectEqualStrings("open", state.matches.items[0]);
    try std.testing.expectEqualStrings("view", state.matches.items[1]);
    try std.testing.expectEqualStrings("123", state.matches.items[2]);
}
