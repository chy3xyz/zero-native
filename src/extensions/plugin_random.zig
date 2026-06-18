const std = @import("std");
const extensions = @import("root.zig");

pub const ModuleId: extensions.ModuleId = 121;
pub const module_name: []const u8 = "random";
pub const capabilities: []const extensions.Capability = &.{.{ .kind = .custom, .name = "random" }};
pub const RandomState = struct { last_bytes: ?[]u8 = null, allocator: std.mem.Allocator };

pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}
pub fn stop(ctx: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const s: *RandomState = @ptrCast(@alignCast(ctx));
    if (s.last_bytes) |b| s.allocator.free(b);
    s.allocator.destroy(s);
}
pub fn command(ctx: *anyopaque, _: extensions.RuntimeContext, cmd: extensions.Command) anyerror!void {
    const s: *RandomState = @ptrCast(@alignCast(ctx));
    if (s.last_bytes) |b| { s.allocator.free(b); s.last_bytes = null; }
    if (std.mem.eql(u8, cmd.name, "random.bytes")) {
        const n = std.fmt.parseInt(usize, cmd.payload, 10) catch 32;
        const buf = s.allocator.alloc(u8, n) catch return;
        var static_seed: u64 = 0;
        static_seed +%= 1;
        var prng = std.Random.DefaultPrng.init(@intCast(@intFromPtr(&s) +% static_seed));
        prng.random().bytes(buf);
        s.last_bytes = buf;
    } else if (std.mem.eql(u8, cmd.name, "random.uuid")) {
        var r: [16]u8 = undefined;
        var static_seed: u64 = 0;
        static_seed +%= 1;
        var prng = std.Random.DefaultPrng.init(@intCast(@intFromPtr(&s) +% static_seed));
        prng.random().bytes(&r);
        r[6] = (r[6] & 0x0f) | 0x40;
        r[8] = (r[8] & 0x3f) | 0x80;
        var uuid: [36]u8 = undefined;
        _ = std.fmt.bufPrint(&uuid, "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}", .{
            std.mem.readInt(u32, r[0..4], .big), std.mem.readInt(u16, r[4..6], .big),
            std.mem.readInt(u16, r[6..8], .big), std.mem.readInt(u16, r[8..10], .big),
            std.mem.readInt(u48, r[10..16], .big),
        }) catch return;
        s.last_bytes = s.allocator.dupe(u8, &uuid) catch return;
    }
}
pub fn create(allocator: std.mem.Allocator) !extensions.Module {
    const s = try allocator.create(RandomState);
    s.* = .{ .allocator = allocator };
    return .{ .info = .{ .id = ModuleId, .name = module_name, .capabilities = capabilities }, .context = @ptrCast(s), .hooks = .{ .start_fn = start, .stop_fn = stop, .command_fn = command } };
}
test "random bytes" {
    const m = try create(std.testing.allocator);
    defer m.hooks.stop_fn.?(m.context, .{.platform_name="null"}) catch {};
    try m.hooks.command_fn.?(m.context, .{.platform_name="null"}, .{.name="random.bytes", .payload="16", .target=ModuleId});
    const s: *RandomState = @ptrCast(@alignCast(m.context));
    try std.testing.expect(s.last_bytes.?.len == 16);
}
