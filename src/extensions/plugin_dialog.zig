const std = @import("std");
const extensions = @import("root.zig");
const platform = @import("platform");

pub const ModuleId: extensions.ModuleId = 119;
pub const module_name: []const u8 = "dialog";

pub const capabilities: []const extensions.Capability = &.{.{ .kind = .custom, .name = "dialog" }};

pub const DialogState = struct {
    last_path: ?[]u8 = null,
    last_button: u8 = 0,
    allocator: std.mem.Allocator,
};

pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}
pub fn stop(ctx: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const s: *DialogState = @ptrCast(@alignCast(ctx));
    if (s.last_path) |p| s.allocator.free(p);
    s.allocator.destroy(s);
}

pub fn command(ctx: *anyopaque, runtime: extensions.RuntimeContext, cmd: extensions.Command) anyerror!void {
    const s: *DialogState = @ptrCast(@alignCast(ctx));
    if (s.last_path) |p| { s.allocator.free(p); s.last_path = null; }
    const services: ?*const platform.PlatformServices = @ptrCast(@alignCast(runtime.services));

    if (std.mem.eql(u8, cmd.name, "dialog.open")) {
        if (services) |svc| {
            var buffer: [8192]u8 = undefined;
            const result = svc.showOpenDialog(.{}, &buffer) catch return;
            if (result.count > 0) s.last_path = s.allocator.dupe(u8, result.paths) catch return;
        }
    } else if (std.mem.eql(u8, cmd.name, "dialog.save")) {
        if (services) |svc| {
            var buffer: [1024]u8 = undefined;
            if (svc.showSaveDialog(.{}, &buffer) catch null) |path| {
                s.last_path = s.allocator.dupe(u8, path) catch return;
            }
        }
    } else if (std.mem.eql(u8, cmd.name, "dialog.message")) {
        if (services) |svc| {
            const result = svc.showMessageDialog(.{ .title = cmd.payload }) catch return;
            s.last_button = @intCast(@intFromEnum(result));
        }
    }
}

pub fn create(allocator: std.mem.Allocator) !extensions.Module {
    const s = try allocator.create(DialogState);
    s.* = .{ .allocator = allocator };
    return .{ .info = .{ .id = ModuleId, .name = module_name, .capabilities = capabilities }, .context = @ptrCast(s), .hooks = .{ .start_fn = start, .stop_fn = stop, .command_fn = command } };
}

test "dialog records message button" {
    const m = try create(std.testing.allocator);
    defer m.hooks.stop_fn.?(m.context, .{.platform_name="null"}) catch {};
    try m.hooks.command_fn.?(m.context, .{.platform_name="null"}, .{.name="dialog.message", .payload="hello", .target=ModuleId});
    const s: *DialogState = @ptrCast(@alignCast(m.context));
    try std.testing.expectEqual(@as(u8, 0), s.last_button);
}
