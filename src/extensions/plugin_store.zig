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
/// The extension `Command` carries no separate payload, so we encode the
/// payload alongside the command identifier in `cmd.name` using a single
/// `|` separator: `"store.set|<key>|<value>"` for set, and
/// `"store.get|<key>"` / `"store.remove|<key>"` for the others. We split
/// command-from-payload first, then split payload as needed.

pub fn command(context: *anyopaque, runtime: extensions.RuntimeContext, cmd: extensions.Command) anyerror!void {
    _ = runtime;
    const state: *StoreState = @ptrCast(@alignCast(context));

    const command_name, const payload = splitFirst(cmd.name);

    if (std.mem.eql(u8, command_name, "store.set")) {
        try handleSet(state, payload);
        return;
    }
    if (std.mem.eql(u8, command_name, "store.get")) {
        try handleGet(state, payload);
        return;
    }
    if (std.mem.eql(u8, command_name, "store.remove")) {
        try handleRemove(state, payload);
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
    const key, const value = splitFirst(payload);
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
    const key = payload;

    if (state.values.get(key)) |value| {
        const owned = try state.allocator.dupe(u8, value);
        freeLastGet(state);
        state.last_get = owned;
    } else {
        freeLastGet(state);
        state.last_get = null;
    }
}

fn handleRemove(state: *StoreState, payload: []const u8) anyerror!void {
    try removeKey(state, payload);
    if (state.last_get) |previous| {
        state.allocator.free(previous);
        state.last_get = null;
    }
}

fn removeKey(state: *StoreState, key: []const u8) !void {
    if (state.values.fetchRemove(key)) |entry| {
        state.allocator.free(entry.key);
        state.allocator.free(entry.value);
    }
}

/// Split on the first `|` byte. Returns the part before as the first tuple
/// element and the remainder (which may itself contain `|`) as the second.
fn splitFirst(input: []const u8) struct { []const u8, []const u8 } {
    if (std.mem.indexOfScalar(u8, input, '|')) |index| {
        return .{ input[0..index], input[index + 1 ..] };
    }
    return .{ input, "" };
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

    try command(module.context, runtime, .{ .name = "store.set|hello|world", .target = ModuleId });
    try command(module.context, runtime, .{ .name = "store.get|hello", .target = ModuleId });

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
    try command(module.context, runtime, .{ .name = "store.get|missing", .target = ModuleId });

    const state: *StoreState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(state.last_get == null);
}

test "plugin_store: set replaces the previous value and frees it" {
    const allocator = std.testing.allocator;
    var module = try create(allocator);
    defer stopModule(&module, allocator);

    const runtime = extensions.RuntimeContext{ .platform_name = "null" };

    try command(module.context, runtime, .{ .name = "store.set|color|red", .target = ModuleId });
    try command(module.context, runtime, .{ .name = "store.set|color|blue", .target = ModuleId });
    try command(module.context, runtime, .{ .name = "store.get|color", .target = ModuleId });

    const state: *StoreState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqualStrings("blue", state.last_get.?);
    try std.testing.expectEqual(@as(usize, 1), state.values.count());
}

test "plugin_store: remove clears the value" {
    const allocator = std.testing.allocator;
    var module = try create(allocator);
    defer stopModule(&module, allocator);

    const runtime = extensions.RuntimeContext{ .platform_name = "null" };

    try command(module.context, runtime, .{ .name = "store.set|alpha|one", .target = ModuleId });
    try command(module.context, runtime, .{ .name = "store.remove|alpha", .target = ModuleId });

    const state: *StoreState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqual(@as(usize, 0), state.values.count());

    // Subsequent get should clear last_get.
    try command(module.context, runtime, .{ .name = "store.get|alpha", .target = ModuleId });
    try std.testing.expect(state.last_get == null);
}

test "plugin_store: multiple keys coexist" {
    const allocator = std.testing.allocator;
    var module = try create(allocator);
    defer stopModule(&module, allocator);

    const runtime = extensions.RuntimeContext{ .platform_name = "null" };

    try command(module.context, runtime, .{ .name = "store.set|a|1", .target = ModuleId });
    try command(module.context, runtime, .{ .name = "store.set|b|2", .target = ModuleId });
    try command(module.context, runtime, .{ .name = "store.set|c|3", .target = ModuleId });

    const state: *StoreState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqual(@as(usize, 3), state.values.count());

    try command(module.context, runtime, .{ .name = "store.get|a", .target = ModuleId });
    try std.testing.expectEqualStrings("1", state.last_get.?);
    try command(module.context, runtime, .{ .name = "store.get|b", .target = ModuleId });
    try std.testing.expectEqualStrings("2", state.last_get.?);
    try command(module.context, runtime, .{ .name = "store.get|c", .target = ModuleId });
    try std.testing.expectEqualStrings("3", state.last_get.?);

    // Removing one key does not disturb the others.
    try command(module.context, runtime, .{ .name = "store.remove|b", .target = ModuleId });
    try std.testing.expectEqual(@as(usize, 2), state.values.count());
    try command(module.context, runtime, .{ .name = "store.get|a", .target = ModuleId });
    try std.testing.expectEqualStrings("1", state.last_get.?);
    try command(module.context, runtime, .{ .name = "store.get|c", .target = ModuleId });
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
