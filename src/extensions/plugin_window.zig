const std = @import("std");
const extensions = @import("root.zig");
const platform = @import("platform");

pub const ModuleId: extensions.ModuleId = 123;
pub const module_name: []const u8 = "window";
pub const capabilities: []const extensions.Capability = &.{.{ .kind = .custom, .name = "window" }};
pub const WindowState = struct { label: ?[]u8 = null, allocator: std.mem.Allocator };

pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}
pub fn stop(ctx: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const s: *WindowState = @ptrCast(@alignCast(ctx));
    if (s.label) |l| s.allocator.free(l);
    s.allocator.destroy(s);
}
pub fn command(ctx: *anyopaque, runtime: extensions.RuntimeContext, cmd: extensions.Command) anyerror!void {
    const s: *WindowState = @ptrCast(@alignCast(ctx));
    if (s.label) |l| { s.allocator.free(l); s.label = null; }
    const svc: ?*const platform.PlatformServices = @ptrCast(@alignCast(runtime.services));
    if (svc == null) { if (std.mem.eql(u8, cmd.name, "window.create")) s.label = s.allocator.dupe(u8, cmd.payload) catch return; return; }
    const services = svc.?;

    if (std.mem.eql(u8, cmd.name, "window.create")) {
        _ = services.createWindow(.{ .label = cmd.payload }) catch {};
        s.label = s.allocator.dupe(u8, cmd.payload) catch return;
    } else if (std.mem.eql(u8, cmd.name, "window.focus")) {
        const id = std.fmt.parseInt(platform.WindowId, cmd.payload, 10) catch return;
        _ = services.focusWindow(id) catch {};
    } else if (std.mem.eql(u8, cmd.name, "window.close")) {
        const id = std.fmt.parseInt(platform.WindowId, cmd.payload, 10) catch return;
        _ = services.closeWindow(id) catch {};
    }
}
pub fn create(allocator: std.mem.Allocator) !extensions.Module {
    const s = try allocator.create(WindowState);
    errdefer allocator.destroy(s);
    s.* = .{ .allocator = allocator };
    return .{ .info = .{ .id = ModuleId, .name = module_name, .capabilities = capabilities }, .context = @ptrCast(s), .hooks = .{ .start_fn = start, .stop_fn = stop, .command_fn = command } };
}
test "window create records label" {
    const m = try create(std.testing.allocator);
    defer m.hooks.stop_fn.?(m.context, .{.platform_name="null"}) catch {};
    try m.hooks.command_fn.?(m.context, .{.platform_name="null"}, .{.name="window.create", .payload="settings", .target=ModuleId});
    const s: *WindowState = @ptrCast(@alignCast(m.context));
    try std.testing.expectEqualStrings("settings", s.label.?);
}
test "window focus rejects invalid id" {
    const m = try create(std.testing.allocator);
    defer m.hooks.stop_fn.?(m.context, .{.platform_name="null"}) catch {};
    try m.hooks.command_fn.?(m.context, .{.platform_name="null"}, .{.name="window.focus", .payload="not_a_number", .target=ModuleId});
    const s: *WindowState = @ptrCast(@alignCast(m.context));
    try std.testing.expect(s.label == null);
}
