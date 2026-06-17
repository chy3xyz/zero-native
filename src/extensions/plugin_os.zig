//! OS info plugin — exposes host operating-system metadata to the frontend.
//!
//! Commands:
//! - `os.info` — payload is ignored. Populates `state.last_info` with a JSON
//!   object: `{"arch":"...","os":"...","os_version":"...","hostname":"...","locale":"..."}`.
//!   In tests the population runs and the recorded JSON is asserted.

const std = @import("std");
const builtin = @import("builtin");
const extensions = @import("root.zig");

pub const ModuleId: extensions.ModuleId = 113;
pub const module_name: []const u8 = "os";

pub const capabilities: []const extensions.Capability = &.{
    .{ .kind = .custom, .name = "os" },
};

pub const cmd_info: []const u8 = "os.info";

pub const OsState = struct {
    last_info: ?[]u8 = null,
    allocator: std.mem.Allocator,
};

pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}

pub fn stop(context: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const state: *OsState = @ptrCast(@alignCast(context));
    if (state.last_info) |info| state.allocator.free(info);
    state.allocator.destroy(state);
}

pub fn command(
    context: *anyopaque,
    _: extensions.RuntimeContext,
    cmd: extensions.Command,
) anyerror!void {
    const state: *OsState = @ptrCast(@alignCast(context));
    if (std.mem.eql(u8, cmd.name, cmd_info)) {
        if (state.last_info) |old| state.allocator.free(old);
        state.last_info = try buildInfo(state.allocator);
    }
}

fn buildInfo(allocator: std.mem.Allocator) ![]u8 {
    const arch_str = switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm => "arm",
        .riscv64 => "riscv64",
        .wasm32 => "wasm32",
        else => "unknown",
    };
    const os_str = @tagName(builtin.os.tag);
    const os_version = @tagName(builtin.os.tag); // simplified; real impl would query uname / registry
    const hostname = "localhost"; // simplified; real impl would call uname / GetComputerName
    return std.fmt.allocPrint(
        allocator,
        "{{\"arch\":\"{s}\",\"os\":\"{s}\",\"os_version\":\"{s}\",\"hostname\":\"{s}\",\"locale\":\"en-US\"}}",
        .{ arch_str, os_str, os_version, hostname },
    );
}

pub fn create(allocator: std.mem.Allocator) !extensions.Module {
    const state = try allocator.create(OsState);
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

test "os info records JSON" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);
    defer module.hooks.stop_fn.?(module.context, .{ .platform_name = "null" }) catch {};

    try module.hooks.command_fn.?(module.context, .{ .platform_name = "null" }, .{
        .name = "os.info",
        .payload = "",
        .target = ModuleId,
    });
    const state: *OsState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(state.last_info != null);
    try std.testing.expect(std.mem.indexOf(u8, state.last_info.?, "\"arch\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, state.last_info.?, "\"os\":") != null);
}
