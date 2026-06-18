//! Key-value store plugin with optional disk persistence.
//!
//! Commands are routed by `cmd.name` only; any argument string lives in
//! `cmd.payload`. Supported commands:
//! - `store.set` — `cmd.payload` is `"key|value"`, split on the first `|`.
//!   An empty `key` is silently rejected.
//! - `store.get` — `cmd.payload` is the key. The most recent value (or
//!   `null` for misses) is recorded in `state.last_get` for inspection.
//! - `store.remove` — `cmd.payload` is the key. The key is removed from the
//!   store and `state.last_get` is cleared.
//!
//! When `store_path` is non-empty at creation time, the plugin loads
//! persisted data from the JSON file on `start` and writes back after
//! every mutation (`set` / `remove`). The file format is a flat JSON
//! object: `{"key":"value",…}`. Save errors are silently ignored so
//! that a transient disk failure never blocks the app.

const std = @import("std");
const extensions = @import("root.zig");

pub const ModuleId: extensions.ModuleId = 105;

/// In-memory key-value store plugin state with optional disk backing.
///
/// `values` owns both the keys and the values: each key is allocated through
/// `state.allocator` when inserted, and each value is a freshly duplicated
/// slice so `stop` can release them deterministically. `last_get` holds the
/// most recent value retrieved via `store.get` so callers can inspect it
/// from tests (the extension `Command` has no return channel).
pub const StoreState = struct {
    values: std.StringHashMap([]u8),
    last_get: ?[]u8,
    /// When non-empty, every mutation is persisted to this JSON file.
    store_path: []const u8,
    io: std.Io,
    allocator: std.mem.Allocator,
};

/// Plugin lifecycle hooks ----------------------------------------------------

pub fn start(context: *anyopaque, runtime: extensions.RuntimeContext) anyerror!void {
    _ = runtime;
    const state: *StoreState = @ptrCast(@alignCast(context));
    loadFromDisk(state) catch {};
}

pub fn stop(context: *anyopaque, runtime: extensions.RuntimeContext) anyerror!void {
    _ = runtime;
    const state: *StoreState = @ptrCast(@alignCast(context));
    freeAll(state);
    state.allocator.destroy(state);
}

/// Command dispatch ----------------------------------------------------------

/// Commands are routed by `cmd.name`; the argument string (if any) lives in
/// `cmd.payload`. `store.set` expects `"key|value"` (split on the first `|`);
/// `store.get` and `store.remove` treat the whole payload as the key.

pub fn command(context: *anyopaque, runtime: extensions.RuntimeContext, cmd: extensions.Command) anyerror!void {
    _ = runtime;
    const state: *StoreState = @ptrCast(@alignCast(context));

    if (std.mem.eql(u8, cmd.name, "store.set")) {
        try handleSet(state, cmd.payload);
        return;
    }
    if (std.mem.eql(u8, cmd.name, "store.get")) {
        try handleGet(state, cmd.payload);
        return;
    }
    if (std.mem.eql(u8, cmd.name, "store.remove")) {
        try handleRemove(state, cmd.payload);
        return;
    }
}

/// Factory ------------------------------------------------------------------

/// `store_path` may be empty to disable persistence.
pub fn create(allocator: std.mem.Allocator, io: std.Io, store_path: []const u8) !extensions.Module {
    const state = try allocator.create(StoreState);
    errdefer allocator.destroy(state);

    const owned_path = if (store_path.len > 0) try allocator.dupe(u8, store_path) else "";
    errdefer if (owned_path.len > 0) allocator.free(owned_path);

    state.* = .{
        .values = std.StringHashMap([]u8).init(allocator),
        .last_get = null,
        .store_path = owned_path,
        .io = io,
        .allocator = allocator,
    };

    const caps = [_]extensions.Capability{.{ .kind = .custom, .name = "store" }};

    return .{
        .info = .{
            .id = ModuleId,
            .name = "store",
            .capabilities = &caps,
        },
        .context = @ptrCast(state),
        .hooks = .{
            .start_fn = start,
            .stop_fn = stop,
            .command_fn = command,
        },
    };
}

// ─── Persistence ───────────────────────────────────────────────────────────

const max_store_file_size = 512 * 1024; // 512 KiB

fn loadFromDisk(state: *StoreState) !void {
    if (state.store_path.len == 0) return;
    const cwd = std.Io.Dir.cwd();
    const raw = cwd.readFileAlloc(state.io, state.store_path, state.allocator, std.Io.Limit.limited(max_store_file_size)) catch |err| {
        if (err == error.NotFound) return;
        return err;
    };
    defer state.allocator.free(raw);

    var pos: usize = 0;
    skipWhitespace(raw, &pos);
    if (pos >= raw.len or raw[pos] != '{') return;
    pos += 1;

    while (pos < raw.len) {
        skipWhitespace(raw, &pos);
        if (pos >= raw.len) break;
        if (raw[pos] == '}') break;

        // Parse key string
        const key = parseJsonString(state.allocator, raw, &pos) catch break;
        defer state.allocator.free(key);

        skipWhitespace(raw, &pos);
        if (pos >= raw.len or raw[pos] != ':') break;
        pos += 1;
        skipWhitespace(raw, &pos);

        // Parse value string
        const value = parseJsonString(state.allocator, raw, &pos) catch break;
        defer state.allocator.free(value);

        // Insert into map
        const owned_key = state.allocator.dupe(u8, key) catch break;
        errdefer state.allocator.free(owned_key);
        const owned_value = state.allocator.dupe(u8, value) catch {
            state.allocator.free(owned_key);
            break;
        };
        state.values.put(owned_key, owned_value) catch {
            state.allocator.free(owned_key);
            state.allocator.free(owned_value);
            break;
        };

        skipWhitespace(raw, &pos);
        if (pos < raw.len and raw[pos] == ',') pos += 1;
    }
}

fn saveToDisk(state: *StoreState) void {
    if (state.store_path.len == 0) return;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(state.allocator);
    buf.append(state.allocator, '{') catch return;
    var first = true;
    var iter = state.values.iterator();
    while (iter.next()) |entry| {
        if (!first) buf.append(state.allocator, ',') catch return;
        first = false;
        buf.append(state.allocator, '"') catch return;
        appendJsonEscaped(&buf, state.allocator, entry.key_ptr.*) catch return;
        buf.appendSlice(state.allocator, "\":\"") catch return;
        appendJsonEscaped(&buf, state.allocator, entry.value_ptr.*) catch return;
        buf.append(state.allocator, '"') catch return;
    }
    buf.append(state.allocator, '}') catch return;
    _ = std.Io.Dir.cwd().writeFile(state.io, .{ .sub_path = state.store_path, .data = buf.items }) catch {};
}

fn parseJsonString(allocator: std.mem.Allocator, raw: []const u8, pos: *usize) ![]const u8 {
    skipWhitespace(raw, pos);
    if (pos.* >= raw.len or raw[pos.*] != '"') return error.InvalidFormat;
    pos.* += 1;
    const str_start = pos.*;
    while (pos.* < raw.len and raw[pos.*] != '"') {
        if (raw[pos.*] == '\\') pos.* += 2 else pos.* += 1;
    }
    if (pos.* >= raw.len) return error.InvalidFormat;
    const end = pos.*;
    pos.* += 1;
    // Simple unescape — handles only \\ and \" for now
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

fn appendJsonEscaped(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => try buf.append(allocator, c),
        }
    }
}

fn skipWhitespace(raw: []const u8, pos: *usize) void {
    while (pos.* < raw.len and std.ascii.isWhitespace(raw[pos.*])) pos.* += 1;
}

// ─── Command helpers ───────────────────────────────────────────────────────

fn handleSet(state: *StoreState, payload: []const u8) anyerror!void {
    const separator = std.mem.indexOfScalar(u8, payload, '|') orelse return;
    const key = payload[0..separator];
    const value = payload[separator + 1 ..];
    if (key.len == 0) return;

    const owned_key = try state.allocator.dupe(u8, key);
    errdefer state.allocator.free(owned_key);

    const owned_value = try state.allocator.dupe(u8, value);
    errdefer state.allocator.free(owned_value);

    // `put` clobbers any existing entry — release the previous key/value first.
    if (state.values.fetchRemove(owned_key)) |previous| {
        state.allocator.free(previous.key);
        state.allocator.free(previous.value);
    }

    try state.values.put(owned_key, owned_value);
    saveToDisk(state);
}

fn handleGet(state: *StoreState, payload: []const u8) anyerror!void {
    if (state.values.get(payload)) |value| {
        const owned = try state.allocator.dupe(u8, value);
        freeLastGet(state);
        state.last_get = owned;
    } else {
        freeLastGet(state);
        state.last_get = null;
    }
}

fn handleRemove(state: *StoreState, payload: []const u8) anyerror!void {
    if (state.values.fetchRemove(payload)) |entry| {
        state.allocator.free(entry.key);
        state.allocator.free(entry.value);
    }
    if (state.last_get) |previous| {
        state.allocator.free(previous);
        state.last_get = null;
    }
    saveToDisk(state);
}

fn freeLastGet(state: *StoreState) void {
    if (state.last_get) |previous| {
        state.allocator.free(previous);
        state.last_get = null;
    }
}

fn freeAll(state: *StoreState) void {
    var iterator = state.values.iterator();
    while (iterator.next()) |entry| {
        state.allocator.free(entry.key_ptr.*);
        state.allocator.free(entry.value_ptr.*);
    }
    state.values.deinit();
    freeLastGet(state);
    if (state.store_path.len > 0) state.allocator.free(state.store_path);
}

// ─── Tests ─────────────────────────────────────────────────────────────────

test "plugin_store: set then get records the value" {
    const allocator = std.testing.allocator;
    var module = try create(allocator, std.testing.io, "");
    defer stopModule(&module, allocator);

    const runtime = extensions.RuntimeContext{ .platform_name = "null" };

    try command(module.context, runtime, .{
        .name = "store.set",
        .payload = "hello|world",
        .target = ModuleId,
    });
    try command(module.context, runtime, .{
        .name = "store.get",
        .payload = "hello",
        .target = ModuleId,
    });

    const state: *StoreState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(state.last_get != null);
    try std.testing.expectEqualStrings("world", state.last_get.?);
    try std.testing.expectEqual(@as(usize, 1), state.values.count());
}

test "plugin_store: get without prior set leaves last_get empty" {
    const allocator = std.testing.allocator;
    var module = try create(allocator, std.testing.io, "");
    defer stopModule(&module, allocator);

    const runtime = extensions.RuntimeContext{ .platform_name = "null" };
    try command(module.context, runtime, .{
        .name = "store.get",
        .payload = "missing",
        .target = ModuleId,
    });

    const state: *StoreState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(state.last_get == null);
}

test "plugin_store: set replaces the previous value and frees it" {
    const allocator = std.testing.allocator;
    var module = try create(allocator, std.testing.io, "");
    defer stopModule(&module, allocator);

    const runtime = extensions.RuntimeContext{ .platform_name = "null" };

    try command(module.context, runtime, .{ .name = "store.set", .payload = "color|red", .target = ModuleId });
    try command(module.context, runtime, .{ .name = "store.set", .payload = "color|blue", .target = ModuleId });
    try command(module.context, runtime, .{ .name = "store.get", .payload = "color", .target = ModuleId });

    const state: *StoreState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqualStrings("blue", state.last_get.?);
    try std.testing.expectEqual(@as(usize, 1), state.values.count());
}

test "plugin_store: remove clears the value" {
    const allocator = std.testing.allocator;
    var module = try create(allocator, std.testing.io, "");
    defer stopModule(&module, allocator);

    const runtime = extensions.RuntimeContext{ .platform_name = "null" };

    try command(module.context, runtime, .{ .name = "store.set", .payload = "alpha|one", .target = ModuleId });
    try command(module.context, runtime, .{ .name = "store.remove", .payload = "alpha", .target = ModuleId });

    const state: *StoreState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqual(@as(usize, 0), state.values.count());

    // Subsequent get should clear last_get.
    try command(module.context, runtime, .{ .name = "store.get", .payload = "alpha", .target = ModuleId });
    try std.testing.expect(state.last_get == null);
}

test "plugin_store: multiple keys coexist" {
    const allocator = std.testing.allocator;
    var module = try create(allocator, std.testing.io, "");
    defer stopModule(&module, allocator);

    const runtime = extensions.RuntimeContext{ .platform_name = "null" };

    try command(module.context, runtime, .{ .name = "store.set", .payload = "a|1", .target = ModuleId });
    try command(module.context, runtime, .{ .name = "store.set", .payload = "b|2", .target = ModuleId });
    try command(module.context, runtime, .{ .name = "store.set", .payload = "c|3", .target = ModuleId });

    const state: *StoreState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqual(@as(usize, 3), state.values.count());

    try command(module.context, runtime, .{ .name = "store.get", .payload = "a", .target = ModuleId });
    try std.testing.expectEqualStrings("1", state.last_get.?);
    try command(module.context, runtime, .{ .name = "store.get", .payload = "b", .target = ModuleId });
    try std.testing.expectEqualStrings("2", state.last_get.?);
    try command(module.context, runtime, .{ .name = "store.get", .payload = "c", .target = ModuleId });
    try std.testing.expectEqualStrings("3", state.last_get.?);

    // Removing one key does not disturb the others.
    try command(module.context, runtime, .{ .name = "store.remove", .payload = "b", .target = ModuleId });
    try std.testing.expectEqual(@as(usize, 2), state.values.count());
    try command(module.context, runtime, .{ .name = "store.get", .payload = "a", .target = ModuleId });
    try std.testing.expectEqualStrings("1", state.last_get.?);
    try command(module.context, runtime, .{ .name = "store.get", .payload = "c", .target = ModuleId });
    try std.testing.expectEqualStrings("3", state.last_get.?);
}

test "plugin_store: start and stop are idempotent through the registry" {
    const allocator = std.testing.allocator;
    var module = try create(allocator, std.testing.io, "");

    const modules = [_]extensions.Module{module};
    const registry = extensions.ModuleRegistry{ .modules = &modules };
    const runtime = extensions.RuntimeContext{ .platform_name = "null" };

    try registry.startAll(runtime);
    try registry.stopAll(runtime);

    // After `stop` the module's context pointer is dangling; nothing else
    // should dereference it. The standalone `stopModule` helper used by the
    // other tests avoids the registry so we can assert on freed state.
    module.context = undefined;
}

test "plugin_store: registers in ModuleRegistry without id collisions" {
    const allocator = std.testing.allocator;
    var module = try create(allocator, std.testing.io, "");

    const modules = [_]extensions.Module{module};
    const registry = extensions.ModuleRegistry{ .modules = &modules };
    try registry.validate();
    try std.testing.expect(registry.hasCapability(.custom));

    stopModule(&module, allocator);
}

test "plugin_store: persistence round-trip via .zig-cache" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = ".zig-cache/test-store-plug.json";
    _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var module = try create(allocator, io, path);
        defer stopModule(&module, allocator);
        const runtime = extensions.RuntimeContext{ .platform_name = "null" };

        try module.hooks.start_fn.?(module.context, runtime);
        try command(module.context, runtime, .{ .name = "store.set", .payload = "persist|yes", .target = ModuleId });
        try command(module.context, runtime, .{ .name = "store.set", .payload = "count|42", .target = ModuleId });
    }

    {
        var module = try create(allocator, io, path);
        defer stopModule(&module, allocator);
        const runtime = extensions.RuntimeContext{ .platform_name = "null" };

        try module.hooks.start_fn.?(module.context, runtime);
        const state: *StoreState = @ptrCast(@alignCast(module.context));
        try std.testing.expectEqual(@as(usize, 2), state.values.count());
        try std.testing.expectEqualStrings("yes", state.values.get("persist").?);
        try std.testing.expectEqualStrings("42", state.values.get("count").?);
    }
}

test "plugin_store: persistence tolerates missing file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = ".zig-cache/test-store-missing.json";
    _ = std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var module = try create(allocator, io, path);
    defer stopModule(&module, allocator);
    const runtime = extensions.RuntimeContext{ .platform_name = "null" };

    try module.hooks.start_fn.?(module.context, runtime);
    const state: *StoreState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqual(@as(usize, 0), state.values.count());
}

test "plugin_store: no path disables persistence" {
    const allocator = std.testing.allocator;
    var module = try create(allocator, std.testing.io, "");
    defer stopModule(&module, allocator);
    const runtime = extensions.RuntimeContext{ .platform_name = "null" };

    try module.hooks.start_fn.?(module.context, runtime);
    try command(module.context, runtime, .{ .name = "store.set", .payload = "noop|1", .target = ModuleId });

    const state: *StoreState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqual(@as(usize, 1), state.values.count());
    try std.testing.expectEqualStrings("1", state.values.get("noop").?);
}

fn stopModule(module: *extensions.Module, allocator: std.mem.Allocator) void {
    _ = allocator;
    stop(module.context, .{ .platform_name = "null" }) catch {};
}
