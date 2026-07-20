const std = @import("std");
const extensions = @import("root.zig");

pub const ModuleId: extensions.ModuleId = 120;
pub const module_name: []const u8 = "env";
pub const capabilities: []const extensions.Capability = &.{.{ .kind = .custom, .name = "env" }};
pub const EnvState = struct { key: ?[]u8 = null, allocator: std.mem.Allocator };

pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}
pub fn stop(ctx: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const s: *EnvState = @ptrCast(@alignCast(ctx));
    if (s.key) |k| s.allocator.free(k);
    s.allocator.destroy(s);
}
pub fn command(ctx: *anyopaque, _: extensions.RuntimeContext, cmd: extensions.Command) anyerror!void {
    const s: *EnvState = @ptrCast(@alignCast(ctx));
    if (s.key) |k| { s.allocator.free(k); s.key = null; }
    if (std.mem.eql(u8, cmd.name, "env.get")) {
        if (cmd.payload.len == 0) return;
        s.key = s.allocator.dupe(u8, cmd.payload) catch return;
    }
}
pub fn create(allocator: std.mem.Allocator) !extensions.Module {
    const s = try allocator.create(EnvState);
    errdefer allocator.destroy(s);
    s.* = .{ .allocator = allocator };
    return .{ .info = .{ .id = ModuleId, .name = module_name, .capabilities = capabilities }, .context = @ptrCast(s), .hooks = .{ .start_fn = start, .stop_fn = stop, .command_fn = command } };
}
test "env records key" {
    const m = try create(std.testing.allocator);
    defer m.hooks.stop_fn.?(m.context, .{.platform_name="null"}) catch {};
    try m.hooks.command_fn.?(m.context, .{.platform_name="null"}, .{.name="env.get", .payload="PATH", .target=ModuleId});
    const s: *EnvState = @ptrCast(@alignCast(m.context));
    try std.testing.expectEqualStrings("PATH", s.key.?);
}
test "env rejects empty key" {
    const m = try create(std.testing.allocator);
    defer m.hooks.stop_fn.?(m.context, .{.platform_name="null"}) catch {};
    try m.hooks.command_fn.?(m.context, .{.platform_name="null"}, .{.name="env.get", .payload="", .target=ModuleId});
    const s: *EnvState = @ptrCast(@alignCast(m.context));
    try std.testing.expect(s.key == null);
}
