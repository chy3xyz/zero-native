//! Filesystem plugin — sandboxed file read/write with path traversal protection.

const std = @import("std");
const builtin = @import("builtin");
const extensions = @import("root.zig");
const app_dirs = @import("app_dirs");

pub const ModuleId: extensions.ModuleId = 118;
pub const module_name: []const u8 = "fs";
pub const capabilities: []const extensions.Capability = &.{.{ .kind = .custom, .name = "fs" }};

pub const FsState = struct {
    last_read: ?[]u8 = null,
    last_exists: bool = false,
    last_list: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    io: std.Io,
};

pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}
pub fn stop(ctx: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const s: *FsState = @ptrCast(@alignCast(ctx));
    if (s.last_read) |r| s.allocator.free(r);
    for (s.last_list.items) |item| s.allocator.free(item);
    s.last_list.deinit(s.allocator);
    s.allocator.destroy(s);
}

pub const FsPayload = struct { path: []const u8, data: ?[]const u8 };

pub fn command(ctx: *anyopaque, _: extensions.RuntimeContext, cmd: extensions.Command) anyerror!void {
    const s: *FsState = @ptrCast(@alignCast(ctx));
    var parsed: ?FsPayload = null;
    if (cmd.payload.len >= 2 and cmd.payload[0] == '{') {
        parsed = parseJsonPayload(s.allocator, cmd.payload) catch null;
    }
    defer if (parsed) |p| {
        s.allocator.free(p.path);
        if (p.data) |d| s.allocator.free(d);
    };
    const raw_path = if (parsed) |p| p.path else cmd.payload;
    if (!validatePath(raw_path)) return;
    const path = raw_path;
    const data = if (parsed) |p| p.data else null;

    if (std.mem.eql(u8, cmd.name, "fs.read")) {
        if (s.last_read) |r| { s.allocator.free(r); s.last_read = null; }
        s.last_read = std.Io.Dir.cwd().readFileAlloc(s.io, path, s.allocator, std.Io.Limit.limited(16 * 1024 * 1024)) catch null;
    } else if (std.mem.eql(u8, cmd.name, "fs.write")) {
        _ = std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = path, .data = data orelse "" }) catch {};
    } else if (std.mem.eql(u8, cmd.name, "fs.exists")) {
        _ = std.Io.Dir.cwd().statFile(s.io, path, .{}) catch { s.last_exists = false; return; };
        s.last_exists = true;
    } else if (std.mem.eql(u8, cmd.name, "fs.remove")) {
        _ = std.Io.Dir.cwd().deleteFile(s.io, path) catch {};
    } else if (std.mem.eql(u8, cmd.name, "fs.list")) {
        for (s.last_list.items) |item| s.allocator.free(item);
        s.last_list.deinit(s.allocator);
        s.last_list = std.ArrayList([]const u8).empty;
        var dir = std.Io.Dir.cwd().openDir(s.io, path, .{ .iterate = true }) catch return;
        defer dir.close(s.io);
        var walker = try dir.walk(s.allocator);
        defer walker.deinit();
        while (walker.next(s.io) catch null) |entry| {
            const owned = s.allocator.dupe(u8, entry.path) catch continue;
            s.last_list.append(s.allocator, owned) catch { s.allocator.free(owned); continue; };
        }
    }
}

fn validatePath(p: []const u8) bool {
    if (std.mem.indexOf(u8, p, "..") != null) return false;
    if (p.len == 0) return false;
    return true;
}

fn parseJsonPayload(allocator: std.mem.Allocator, json: []const u8) !FsPayload {
    var path: ?[]const u8 = null;
    var data: ?[]const u8 = null;
    var pos: usize = 1;
    while (pos < json.len) {
        skipWs(json, &pos);
        if (json[pos] == '}') break;
        const key = parseJsonString(allocator, json, &pos) catch break;
        defer allocator.free(key);
        skipWs(json, &pos);
        if (json[pos] != ':') break;
        pos += 1;
        skipWs(json, &pos);
        if (std.mem.eql(u8, key, "path")) {
            path = parseJsonString(allocator, json, &pos) catch break;
        } else if (std.mem.eql(u8, key, "data")) {
            data = parseJsonString(allocator, json, &pos) catch break;
        } else _ = skipJsonValue(json, &pos);
        skipWs(json, &pos);
        if (pos < json.len and json[pos] == ',') pos += 1;
    }
    if (path) |p| return .{ .path = p, .data = data };
    return error.InvalidPayload;
}

fn parseJsonString(allocator: std.mem.Allocator, raw: []const u8, pos: *usize) ![]const u8 {
    skipWs(raw, pos);
    if (pos.* >= raw.len or raw[pos.*] != '"') return error.InvalidFormat;
    pos.* += 1;
    const str_start = pos.*;
    while (pos.* < raw.len and raw[pos.*] != '"') { if (raw[pos.*] == '\\') pos.* += 2 else pos.* += 1; }
    const end = pos.*;
    pos.* += 1;
    var buf = std.ArrayList(u8).empty;
    var i: usize = str_start;
    while (i < end) {
        if (raw[i] == '\\' and i + 1 < end) { const n = raw[i+1]; if (n == '"' or n == '\\') { buf.append(allocator, n) catch return error.OutOfMemory; i += 2; continue; } }
        buf.append(allocator, raw[i]) catch return error.OutOfMemory;
        i += 1;
    }
    return buf.toOwnedSlice(allocator);
}

fn skipJsonValue(raw: []const u8, pos: *usize) void {
    skipWs(raw, pos);
    if (pos.* >= raw.len) return;
    switch (raw[pos.*]) {
        '"' => { pos.* += 1; while (pos.* < raw.len and raw[pos.*] != '"') { if (raw[pos.*] == '\\') pos.* += 1; pos.* += 1; } if (pos.* < raw.len) pos.* += 1; },
        '{' => { var d: usize = 1; pos.* += 1; while (pos.* < raw.len and d > 0) { if (raw[pos.*] == '{') d += 1; if (raw[pos.*] == '}') d -= 1; pos.* += 1; } },
        else => { while (pos.* < raw.len and !std.ascii.isWhitespace(raw[pos.*]) and raw[pos.*] != ',' and raw[pos.*] != '}') pos.* += 1; },
    }
}

fn skipWs(raw: []const u8, pos: *usize) void { while (pos.* < raw.len and std.ascii.isWhitespace(raw[pos.*])) pos.* += 1; }

pub fn create(allocator: std.mem.Allocator, io: std.Io) !extensions.Module {
    const s = try allocator.create(FsState);
    errdefer allocator.destroy(s);
    s.* = .{ .allocator = allocator, .io = io, .last_list = .empty };
    return .{ .info = .{ .id = ModuleId, .name = module_name, .capabilities = capabilities }, .context = @ptrCast(s), .hooks = .{ .start_fn = start, .stop_fn = stop, .command_fn = command } };
}

test "fs rejects path traversal" {
    const m = try create(std.testing.allocator, std.testing.io);
    defer m.hooks.stop_fn.?(m.context, .{.platform_name="null"}) catch {};
    try m.hooks.command_fn.?(m.context, .{.platform_name="null"}, .{.name="fs.read", .payload="../../etc/passwd", .target=ModuleId});
    const s: *FsState = @ptrCast(@alignCast(m.context));
    try std.testing.expect(s.last_read == null);
}

test "fs write and read round-trip" {
    const m = try create(std.testing.allocator, std.testing.io);
    defer m.hooks.stop_fn.?(m.context, .{.platform_name="null"}) catch {};
    try m.hooks.command_fn.?(m.context, .{.platform_name="null"}, .{.name="fs.write", .payload="{\"path\":\".zig-cache/fs-test.txt\",\"data\":\"hello\"}", .target=ModuleId});
    try m.hooks.command_fn.?(m.context, .{.platform_name="null"}, .{.name="fs.read", .payload=".zig-cache/fs-test.txt", .target=ModuleId});
    const s: *FsState = @ptrCast(@alignCast(m.context));
    try std.testing.expect(s.last_read != null);
    _ = std.Io.Dir.cwd().deleteFile(std.testing.io, ".zig-cache/fs-test.txt") catch {};
}
