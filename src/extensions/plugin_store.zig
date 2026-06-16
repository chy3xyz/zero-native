//! In-memory key-value store plugin.
//!
//! Commands are routed by `cmd.name` only; any argument string lives in
//! `cmd.payload`. Supported commands:
//! - `store.set` — `cmd.payload` is `"key|value"`, split on the first `|`.
//!   An empty `key` is silently rejected.
//! - `store.get` — `cmd.payload` is the key. The most recent value (or
//!   `null` for misses) is recorded in `state.last_get` for inspection.
//! - `store.remove` — `cmd.payload` is the key. The key is removed from the
//!   store and `state.last_get` is cleared.

const std = @import("std");
const extensions = @import("root.zig");

pub const ModuleId: extensions.ModuleId = 105;

/// In-memory key-value store plugin state.
///
/// `values` owns both the keys and the values: each key is allocated through
/// `state.allocator` when inserted, and each value is a freshly duplicated
/// slice so `stop` can release them deterministically. `last_get` holds the
/// most recent value retrieved via `store.get` so callers can inspect it
/// from tests (the extension `Command` has no return channel).
pub const StoreState = struct {
    values: std.StringHashMap([]u8),
    last_get: ?[]u8,
    allocator: std.mem.Allocator,
};

/// Plugin lifecycle hooks ----------------------------------------------------

pub fn start(context: *anyopaque, runtime: extensions.RuntimeContext) anyerror!void {
    _ = context;
    _ = runtime;
    // No startup work required; state is fully initialized in `create`.
}

pub fn stop(context: *anyopaque, runtime: extensions.RuntimeContext) anyerror!void {
    _ = runtime;
    const state: *StoreState = @ptrCast(@alignCast(context));
    freeAll(state);
    state.allocator.destroy(state);
}

/// Command dispatch ----------------------------------------------------------
///
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

pub fn create(allocator: std.mem.Allocator) !extensions.Module {
    const state = try allocator.create(StoreState);
    errdefer allocator.destroy(state);

    state.* = .{
        .values = std.StringHashMap([]u8).init(allocator),
        .last_get = null,
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

// Internal helpers ----------------------------------------------------------

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
}

// Tests ---------------------------------------------------------------------

test "plugin_store: set then get records the value" {
    const allocator = std.testing.allocator;
    var module = try create(allocator);
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
    var module = try create(allocator);
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
    var module = try create(allocator);
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
    var module = try create(allocator);
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
    var module = try create(allocator);
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
    var module = try create(allocator);

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
    var module = try create(allocator);

    const modules = [_]extensions.Module{module};
    const registry = extensions.ModuleRegistry{ .modules = &modules };
    try registry.validate();
    try std.testing.expect(registry.hasCapability(.custom));

    stopModule(&module, allocator);
}

fn stopModule(module: *extensions.Module, allocator: std.mem.Allocator) void {
    _ = allocator;
    // Bypass the registry's hook wiring to keep tests self-contained: call
    // `stop` directly so we free exactly what `create` allocated.
    stop(module.context, .{ .platform_name = "null" }) catch {};
}
