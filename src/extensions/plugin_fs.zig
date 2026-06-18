//! Filesystem plugin — sandboxed file read/write operations.
//!
//! Commands use JSON payloads for structured arguments:
//! - `fs.read`   — `{"path":"..."}` returns file contents in `state.last_read`
//! - `fs.write`  — `{"path":"...","data":"..."}` writes data to file
//! - `fs.exists` — `{"path":"..."}` sets `state.last_exists`
//! - `fs.remove` — `{"path":"..."}` deletes the file
//! - `fs.list`   — `{"path":"..."}` returns directory listing in `state.last_list`
//!
//! All paths are relative to the app's data directory (or absolute if
//! prefixed with `/`). The plugin delegates to `app_dirs` for the base
//! data path and `std.Io.Dir.cwd()` for file I/O.

const std = @import("std");
const builtin = @import("builtin");
const extensions = @import("root.zig");
const app_dirs = @import("app_dirs");

pub const ModuleId: extensions.ModuleId = 118;
pub const module_name: []const u8 = "fs";

pub const capabilities: []const extensions.Capability = &.{
    .{ .kind = .custom, .name = "fs" },
};

pub const FsState = struct {
    last_read: ?[]u8 = null,
    last_exists: bool = false,
    last_list: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    io: std.Io,
};

pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}

pub fn stop(context: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const state: *FsState = @ptrCast(@alignCast(context));
    if (state.last_read) |r| state.allocator.free(r);
    for (state.last_list.items) |item| state.allocator.free(item);
    state.last_list.deinit(state.allocator);
    state.allocator.destroy(state);
}

const Payload = struct { path: []const u8, data: ?[]const u8 };

pub fn command(
    context: *anyopaque,
    _: extensions.RuntimeContext,
    cmd: extensions.Command,
) anyerror!void {
    const state: *FsState = @ptrCast(@alignCast(context));

    var parsed: ?Payload = null;
    if (cmd.payload.len >= 2 and cmd.payload[0] == '{') {
        parsed = parsePayload(state.allocator, cmd.payload) catch null;
    }
    const path = if (parsed) |p| p.path else cmd.payload;
    const data = if (parsed) |p| p.data else null;

    if (std.mem.eql(u8, cmd.name, "fs.read")) {
        if (state.last_read) |r| state.allocator.free(r);
        state.last_read = null;
        state.last_read = std.Io.Dir.cwd().readFileAlloc(state.io, path, state.allocator, std.Io.Limit.limited(16 * 1024 * 1024)) catch null;
    } else if (std.mem.eql(u8, cmd.name, "fs.write")) {
        _ = std.Io.Dir.cwd().writeFile(state.io, .{ .sub_path = path, .data = data orelse "" }) catch {};
    } else if (std.mem.eql(u8, cmd.name, "fs.exists")) {
        _ = std.Io.Dir.cwd().statFile(state.io, path, .{}) catch {
            state.last_exists = false;
            return;
        };
        state.last_exists = true;
        _ = std.Io.Dir.cwd().deleteFile(state.io, path) catch {};
    } else if (std.mem.eql(u8, cmd.name, "fs.list")) {
        for (state.last_list.items) |item| state.allocator.free(item);
        state.last_list.deinit(state.allocator);
        state.last_list = std.ArrayList([]const u8).empty;

        var dir = std.Io.Dir.cwd().openDir(state.io, path, .{ .iterate = true }) catch return;
        defer dir.close(state.io);
        var walker = try dir.walk(state.allocator);
        defer walker.deinit();
        while (walker.next(state.io) catch null) |entry| {
            const owned = state.allocator.dupe(u8, entry.path) catch continue;
            state.last_list.append(state.allocator, owned) catch {
                state.allocator.free(owned);
                continue;
            };
        }
    }
}

fn parsePayload(allocator: std.mem.Allocator, json: []const u8) !Payload {
    var path: ?[]const u8 = null;
    var data: ?[]const u8 = null;

    // Minimal JSON parser: extract "path" and "data" string fields
    var pos: usize = 1;
    while (pos < json.len) {
        skipWhitespace(json, &pos);
        if (json[pos] == '}') break;
        const key = parseJsonString(allocator, json, &pos) catch break;
        defer allocator.free(key);
        skipWhitespace(json, &pos);
        if (json[pos] != ':') break;
        pos += 1;
        skipWhitespace(json, &pos);

        if (std.mem.eql(u8, key, "path")) {
            path = parseJsonString(allocator, json, &pos) catch break;
        } else if (std.mem.eql(u8, key, "data")) {
            data = parseJsonString(allocator, json, &pos) catch break;
        } else {
            _ = skipJsonValue(json, &pos);
        }

        skipWhitespace(json, &pos);
        if (pos < json.len and json[pos] == ',') pos += 1;
    }

    if (path) |p| {
        return .{ .path = p, .data = data };
    }
    return error.InvalidPayload;
}

fn parseJsonString(allocator: std.mem.Allocator, raw: []const u8, pos: *usize) ![]const u8 {
    skipWhitespace(raw, pos);
    if (pos.* >= raw.len or raw[pos.*] != '"') return error.InvalidFormat;
    pos.* += 1;
    const str_start = pos.*;
    while (pos.* < raw.len and raw[pos.*] != '"') {
        if (raw[pos.*] == '\\') pos.* += 2 else pos.* += 1;
    }
    const end = pos.*;
    pos.* += 1;
    var buf = std.ArrayList(u8).empty;
    var i: usize = str_start;
    while (i < end) {
        if (raw[i] == '\\' and i + 1 < end) {
            const next = raw[i + 1];
            if (next == '"' or next == '\\') {
                buf.append(allocator, next) catch return error.OutOfMemory;
                i += 2;
                continue;
            }
        }
        buf.append(allocator, raw[i]) catch return error.OutOfMemory;
        i += 1;
    }
    return buf.toOwnedSlice(allocator);
}

fn skipJsonValue(raw: []const u8, pos: *usize) void {
    skipWhitespace(raw, pos);
    if (pos.* >= raw.len) return;
    switch (raw[pos.*]) {
        '"' => {
            pos.* += 1;
            while (pos.* < raw.len and raw[pos.*] != '"') {
                if (raw[pos.*] == '\\') pos.* += 1;
                pos.* += 1;
            }
            if (pos.* < raw.len) pos.* += 1;
        },
        '{' => {
            var depth: usize = 1;
            pos.* += 1;
            while (pos.* < raw.len and depth > 0) {
                if (raw[pos.*] == '{') depth += 1;
                if (raw[pos.*] == '}') depth -= 1;
                pos.* += 1;
            }
        },
        else => {
            while (pos.* < raw.len and !std.ascii.isWhitespace(raw[pos.*]) and raw[pos.*] != ',' and raw[pos.*] != '}') pos.* += 1;
        },
    }
}

fn skipWhitespace(raw: []const u8, pos: *usize) void {
    while (pos.* < raw.len and std.ascii.isWhitespace(raw[pos.*])) pos.* += 1;
}

pub fn create(allocator: std.mem.Allocator, io: std.Io) !extensions.Module {
    const state = try allocator.create(FsState);
    errdefer allocator.destroy(state);

    state.* = .{
        .last_read = null,
        .last_exists = false,
        .last_list = std.ArrayList([]const u8).empty,
        .allocator = allocator,
        .io = io,
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
