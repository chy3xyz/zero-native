//! Crypto plugin — SHA-256 and SHA-1 hashing with hex output.

const std = @import("std");
const extensions = @import("root.zig");

pub const ModuleId: extensions.ModuleId = 122;
pub const module_name: []const u8 = "crypto";
pub const capabilities: []const extensions.Capability = &.{.{ .kind = .custom, .name = "crypto" }};
pub const CryptoState = struct { last_hash: ?[]u8 = null, allocator: std.mem.Allocator };

fn hexEncode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, bytes.len * 2);
    errdefer allocator.free(out);
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0xf];
    }
    return out;
}

pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}
pub fn stop(ctx: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const s: *CryptoState = @ptrCast(@alignCast(ctx));
    if (s.last_hash) |h| s.allocator.free(h);
    s.allocator.destroy(s);
}
pub fn command(ctx: *anyopaque, _: extensions.RuntimeContext, cmd: extensions.Command) anyerror!void {
    const s: *CryptoState = @ptrCast(@alignCast(ctx));
    if (s.last_hash) |h| { s.allocator.free(h); s.last_hash = null; }
    if (std.mem.eql(u8, cmd.name, "crypto.sha256")) {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(cmd.payload, &digest, .{});
        s.last_hash = hexEncode(s.allocator, &digest) catch return;
    } else if (std.mem.eql(u8, cmd.name, "crypto.sha1")) {
        var digest: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
        std.crypto.hash.Sha1.hash(cmd.payload, &digest, .{});
        s.last_hash = hexEncode(s.allocator, &digest) catch return;
    }
}
pub fn create(allocator: std.mem.Allocator) !extensions.Module {
    const s = try allocator.create(CryptoState);
    errdefer allocator.destroy(s);
    s.* = .{ .allocator = allocator };
    return .{ .info = .{ .id = ModuleId, .name = module_name, .capabilities = capabilities }, .context = @ptrCast(s), .hooks = .{ .start_fn = start, .stop_fn = stop, .command_fn = command } };
}
test "crypto sha256 hello" {
    const m = try create(std.testing.allocator);
    defer m.hooks.stop_fn.?(m.context, .{.platform_name="null"}) catch {};
    try m.hooks.command_fn.?(m.context, .{.platform_name="null"}, .{.name="crypto.sha256", .payload="hello", .target=ModuleId});
    const s: *CryptoState = @ptrCast(@alignCast(m.context));
    try std.testing.expectEqualStrings("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824", s.last_hash.?);
}
test "crypto sha256 empty" {
    const m = try create(std.testing.allocator);
    defer m.hooks.stop_fn.?(m.context, .{.platform_name="null"}) catch {};
    try m.hooks.command_fn.?(m.context, .{.platform_name="null"}, .{.name="crypto.sha256", .payload="", .target=ModuleId});
    const s: *CryptoState = @ptrCast(@alignCast(m.context));
    try std.testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", s.last_hash.?);
}
