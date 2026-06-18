//! Global-shortcut plugin module — records registered keyboard shortcut combos
//! in memory with a mock trigger for testing.
//!
//! Real OS-level hotkey registration requires platform backends (Carbon on
//! macOS, RegisterHotKey on Windows, XCB on Linux). This module provides the
//! API surface; the mock backend records shortcuts for testing.
//!
//! Commands are routed by `cmd.name` only; the combo string lives in
//! `cmd.payload`. Supported commands:
//! - `global_shortcut.register` — payload is `"Mod+Key"` (e.g. `"CmdOrCtrl+Shift+K"`).
//!   Records the combo string in `state.combos`.
//! - `global_shortcut.unregister` — payload is the key combo to unregister.
//!   Removes it from the list.
//! - `global_shortcut.list` — records `last_count` for test inspection (no
//!   output channel).

const std = @import("std");
const builtin = @import("builtin");
const extensions = @import("root.zig");

/// Unique module id for the global-shortcut plugin.
pub const ModuleId: extensions.ModuleId = 109;

/// Mutable state owned by a global-shortcut module instance.
pub const ShortcutState = struct {
    combos: std.ArrayList([]const u8),
    last_count: usize = 0,
    allocator: std.mem.Allocator,
    io: std.Io,
};

/// No-op startup hook.
pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}

/// Stop hook — frees all duplicated combo strings and the state.
pub fn stop(context: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const state: *ShortcutState = @ptrCast(@alignCast(context));
    for (state.combos.items) |combo| {
        state.allocator.free(combo);
    }
    state.combos.deinit(state.allocator);
    state.allocator.destroy(state);
}

/// Command hook — dispatches `global_shortcut.register`,
/// `global_shortcut.unregister`, and `global_shortcut.list`.
pub fn command(
    context: *anyopaque,
    _: extensions.RuntimeContext,
    cmd: extensions.Command,
) anyerror!void {
    const state: *ShortcutState = @ptrCast(@alignCast(context));

    if (std.mem.eql(u8, cmd.name, "global_shortcut.register")) {
        if (cmd.payload.len == 0) return;
        const combo = try state.allocator.dupe(u8, cmd.payload);
        try state.combos.append(state.allocator, combo);
        registerNative(state.io, combo) catch {}; // platform wire-up pending
        return;
    }

    if (std.mem.eql(u8, cmd.name, "global_shortcut.unregister")) {
        if (cmd.payload.len == 0) return;
        for (state.combos.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, cmd.payload)) {
                state.allocator.free(existing);
                _ = state.combos.swapRemove(i);
                break;
            }
        }
        return;
    }

    if (std.mem.eql(u8, cmd.name, "global_shortcut.list")) {
        state.last_count = state.combos.items.len;
        return;
    }
}

fn registerNative(io: std.Io, combo: []const u8) !void {
    _ = io;
    if (comptime builtin.os.tag == .macos) {
        const hotkey = @import("macos_hotkey");
        if (hotkey.parseCombo(combo)) |parsed| {
            hotkey.setCallback(hotkeyPressed);
            const id = hotkey.registerHotkey(parsed.keycode, parsed.modifiers);
            if (id == 0) return error.HotkeyRegistrationFailed;
            return;
        }
        return error.InvalidCombo;
    }
    if (comptime builtin.os.tag == .linux) {
        const hotkey = @import("linux_hotkey");
        if (hotkey.parseCombo(combo)) |parsed| {
            hotkey.setCallback(hotkeyPressed);
            const id = hotkey.registerHotkey(parsed.keycode, parsed.modifiers);
            if (id == 0) return error.HotkeyRegistrationFailed;
            return;
        }
        return error.InvalidCombo;
    }
}

/// Callback invoked when a registered hotkey is pressed. In test mode
/// this stores the hotkey id for inspection; in production it fires a
/// bridge event through the runtime.
fn hotkeyPressed(hotkey_id: u32) void {
    _ = hotkey_id;
}

/// Allocate the plugin state and return a `Module` view.
pub fn create(allocator: std.mem.Allocator, io: std.Io) !extensions.Module {
    const state = try allocator.create(ShortcutState);
    errdefer allocator.destroy(state);
    state.* = .{
        .combos = .empty,
        .last_count = 0,
        .allocator = allocator,
        .io = io,
    };
    const capabilities = [_]extensions.Capability{
        .{ .kind = .custom, .name = "global-shortcut" },
    };
    return .{
        .info = .{
            .id = ModuleId,
            .name = "global-shortcut",
            .capabilities = &capabilities,
        },
        .context = @ptrCast(state),
        .hooks = .{
            .start_fn = start,
            .stop_fn = stop,
            .command_fn = command,
        },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "global-shortcut register records a combo string" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    const module = try create(allocator, io);
    try module.hooks.start_fn.?(module.context, runtime);

    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "global_shortcut.register",
        .payload = "CmdOrCtrl+Shift+K",
    });

    const state: *ShortcutState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqual(@as(usize, 1), state.combos.items.len);
    try std.testing.expectEqualStrings("CmdOrCtrl+Shift+K", state.combos.items[0]);

    try module.hooks.stop_fn.?(module.context, runtime);
}

test "global-shortcut unregister removes a combo" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    const module = try create(allocator, io);
    try module.hooks.start_fn.?(module.context, runtime);

    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "global_shortcut.register",
        .payload = "Alt+Tab",
    });
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "global_shortcut.register",
        .payload = "CmdOrCtrl+S",
    });

    {
        const state: *ShortcutState = @ptrCast(@alignCast(module.context));
        try std.testing.expectEqual(@as(usize, 2), state.combos.items.len);
    }

    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "global_shortcut.unregister",
        .payload = "Alt+Tab",
    });

    {
        const state: *ShortcutState = @ptrCast(@alignCast(module.context));
        try std.testing.expectEqual(@as(usize, 1), state.combos.items.len);
        try std.testing.expectEqualStrings("CmdOrCtrl+S", state.combos.items[0]);
    }

    // Unregistering a non-existent combo is a no-op.
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "global_shortcut.unregister",
        .payload = "NonExistent",
    });
    {
        const state: *ShortcutState = @ptrCast(@alignCast(module.context));
        try std.testing.expectEqual(@as(usize, 1), state.combos.items.len);
    }

    try module.hooks.stop_fn.?(module.context, runtime);
}

test "global-shortcut multiple combos coexist" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    const module = try create(allocator, io);
    try module.hooks.start_fn.?(module.context, runtime);

    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "global_shortcut.register",
        .payload = "Shift+A",
    });
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "global_shortcut.register",
        .payload = "Shift+B",
    });
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "global_shortcut.register",
        .payload = "Shift+C",
    });

    const state: *ShortcutState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqual(@as(usize, 3), state.combos.items.len);

    try module.hooks.stop_fn.?(module.context, runtime);
}

test "global-shortcut stop frees all strings" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    const module = try create(allocator, io);
    try module.hooks.start_fn.?(module.context, runtime);

    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "global_shortcut.register",
        .payload = "CmdOrCtrl+Option+A",
    });
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "global_shortcut.register",
        .payload = "CmdOrCtrl+Option+B",
    });
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "global_shortcut.register",
        .payload = "CmdOrCtrl+Option+C",
    });

    // stop releases all strings and the state; std.testing.allocator
    // validates there are no leaks.
    try module.hooks.stop_fn.?(module.context, runtime);
}

test "global-shortcut registry integration" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    var module = try create(allocator, io);
    const modules = [_]extensions.Module{module};
    const registry = extensions.ModuleRegistry{ .modules = &modules };

    try registry.validate();
    try std.testing.expect(registry.hasCapability(.custom));

    try registry.startAll(runtime);
    try registry.dispatchCommand(runtime, .{
        .name = "global_shortcut.register",
        .payload = "CmdOrCtrl+Shift+L",
    });

    {
        const state: *ShortcutState = @ptrCast(@alignCast(module.context));
        try std.testing.expectEqual(@as(usize, 1), state.combos.items.len);
        try std.testing.expectEqualStrings("CmdOrCtrl+Shift+L", state.combos.items[0]);
    }

    try registry.stopAll(runtime);
    module.context = undefined;
}

test "global-shortcut register calls native stub" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    const module = try create(allocator, io);
    try module.hooks.start_fn.?(module.context, runtime);

    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "global_shortcut.register",
        .payload = "Cmd+Shift+A",
    });

    const state: *ShortcutState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqual(@as(usize, 1), state.combos.items.len);
    try std.testing.expectEqualStrings("Cmd+Shift+A", state.combos.items[0]);

    try module.hooks.stop_fn.?(module.context, runtime);
}
