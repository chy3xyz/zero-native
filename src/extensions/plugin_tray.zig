const std = @import("std");
const extensions = @import("root.zig");
const platform = @import("platform");

pub const ModuleId: extensions.ModuleId = 124;
pub const module_name: []const u8 = "tray";
pub const capabilities: []const extensions.Capability = &.{.{ .kind = .custom, .name = "tray" }};

pub const TrayState = struct { items: std.ArrayList(platform.TrayMenuItem), allocator: std.mem.Allocator };

pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}
pub fn stop(ctx: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const s: *TrayState = @ptrCast(@alignCast(ctx));
    for (s.items.items) |item| {
        s.allocator.free(item.label);
    }
    s.items.deinit(s.allocator);
    s.allocator.destroy(s);
}
pub fn command(ctx: *anyopaque, runtime: extensions.RuntimeContext, cmd: extensions.Command) anyerror!void {
    const s: *TrayState = @ptrCast(@alignCast(ctx));
    const services: ?*const platform.PlatformServices = @ptrCast(@alignCast(runtime.services));

    if (std.mem.eql(u8, cmd.name, "tray.init")) {
        const sep = std.mem.indexOfScalar(u8, cmd.payload, '|') orelse return;
        if (services) |svc| _ = svc.createTray(.{
            .icon_path = cmd.payload[0..sep],
            .tooltip = cmd.payload[sep+1..],
            .items = s.items.items,
        }) catch {};
    } else if (std.mem.eql(u8, cmd.name, "tray.add")) {
        const label = s.allocator.dupe(u8, cmd.payload) catch return;
        const item = platform.TrayMenuItem{ .id = @intCast(s.items.items.len), .label = label, .separator = false, .enabled = true };
        s.items.append(s.allocator, item) catch { s.allocator.free(label); };
    } else if (std.mem.eql(u8, cmd.name, "tray.update")) {
        if (services) |svc| _ = svc.updateTrayMenu(s.items.items) catch {};
    }
}
pub fn create(allocator: std.mem.Allocator) !extensions.Module {
    const s = try allocator.create(TrayState);
    s.* = .{ .items = std.ArrayList(platform.TrayMenuItem).empty, .allocator = allocator };
    return .{ .info = .{ .id = ModuleId, .name = module_name, .capabilities = capabilities }, .context = @ptrCast(s), .hooks = .{ .start_fn = start, .stop_fn = stop, .command_fn = command } };
}
test "tray add menu item" {
    const m = try create(std.testing.allocator);
    defer m.hooks.stop_fn.?(m.context, .{.platform_name="null"}) catch {};
    try m.hooks.command_fn.?(m.context, .{.platform_name="null"}, .{.name="tray.add", .payload="Settings", .target=ModuleId});
    const s: *TrayState = @ptrCast(@alignCast(m.context));
    try std.testing.expectEqual(@as(usize, 1), s.items.items.len);
}
