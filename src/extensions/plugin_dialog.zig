const std = @import("std");
const extensions = @import("root.zig");
const platform = @import("platform");

pub const ModuleId: extensions.ModuleId = 119;
pub const module_name: []const u8 = "dialog";
pub const capabilities: []const extensions.Capability = &.{.{ .kind = .custom, .name = "dialog" }};
pub const DialogState = struct { last_path: ?[]u8 = null, last_button: u8 = 0, allocator: std.mem.Allocator };

pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}
pub fn stop(ctx: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const s: *DialogState = @ptrCast(@alignCast(ctx));
    if (s.last_path) |p| s.allocator.free(p);
    s.allocator.destroy(s);
}
pub fn command(ctx: *anyopaque, runtime: extensions.RuntimeContext, cmd: extensions.Command) anyerror!void {
    const s: *DialogState = @ptrCast(@alignCast(ctx));
    if (s.last_path) |p| { s.allocator.free(p); s.last_path = null; }
    const svc: ?*const platform.PlatformServices = @ptrCast(@alignCast(runtime.services));
    if (svc == null) return;
    const services = svc.?;

    if (std.mem.eql(u8, cmd.name, "dialog.open")) {
        var buffer: [8192]u8 = undefined;
        const result = services.showOpenDialog(.{}, &buffer) catch return;
        if (result.count > 0) s.last_path = s.allocator.dupe(u8, result.paths) catch return;
    } else if (std.mem.eql(u8, cmd.name, "dialog.save")) {
        var buffer: [1024]u8 = undefined;
        if (services.showSaveDialog(.{}, &buffer) catch null) |p| s.last_path = s.allocator.dupe(u8, p) catch return;
    } else if (std.mem.eql(u8, cmd.name, "dialog.message")) {
        s.last_button = @intCast(@intFromEnum(services.showMessageDialog(.{ .title = cmd.payload }) catch return));
    }
}
pub fn create(allocator: std.mem.Allocator) !extensions.Module {
    const s = try allocator.create(DialogState);
    errdefer allocator.destroy(s);
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
test "dialog null services returns early" {
    const m = try create(std.testing.allocator);
    defer m.hooks.stop_fn.?(m.context, .{.platform_name="null"}) catch {};
    try m.hooks.command_fn.?(m.context, .{.platform_name="null"}, .{.name="dialog.open", .payload="", .target=ModuleId});
    const s: *DialogState = @ptrCast(@alignCast(m.context));
    try std.testing.expect(s.last_path == null);
}
