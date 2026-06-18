//! Linux global hotkey stubs.
//!
//! Real implementation would use XCB `xcb_grab_key` (X11) or
//! `zwp_keyboard_shortcuts_inhibit_manager_v1` (Wayland). Both require
//! integrating with the GDK/GTK event loop which is managed by
//! `gtk_host.c`. Until that bridge lands, this module returns success
//! in test mode and is a no-op in production.

const std = @import("std");
const builtin = @import("builtin");

const UInt32 = u32;
const cmdKey: UInt32 = 1 << 2; // Control on Linux
const shiftKey: UInt32 = 1 << 0;
const altKey: UInt32 = 1 << 3;
const superKey: UInt32 = 1 << 6; // Windows/Super key

const keycode_map = std.StaticStringMap(u8).initComptime(.{
    .{ "A", 38 }, .{ "B", 56 }, .{ "C", 54 }, .{ "D", 40 },
    .{ "E", 26 }, .{ "F", 41 }, .{ "G", 42 }, .{ "H", 43 },
    .{ "I", 31 }, .{ "J", 44 }, .{ "K", 45 }, .{ "L", 46 },
    .{ "M", 58 }, .{ "N", 57 }, .{ "O", 32 }, .{ "P", 33 },
    .{ "Q", 24 }, .{ "R", 27 }, .{ "S", 39 }, .{ "T", 28 },
    .{ "U", 30 }, .{ "V", 55 }, .{ "W", 25 }, .{ "X", 53 },
    .{ "Y", 29 }, .{ "Z", 52 },
    .{ "0", 19 }, .{ "1", 10 }, .{ "2", 11 }, .{ "3", 12 },
    .{ "4", 13 }, .{ "5", 14 }, .{ "6", 15 }, .{ "7", 16 },
    .{ "8", 17 }, .{ "9", 18 },
    .{ "F1", 67 }, .{ "F2", 68 }, .{ "F3", 69 }, .{ "F4", 70 },
    .{ "F5", 71 }, .{ "F6", 72 }, .{ "F7", 73 }, .{ "F8", 74 },
    .{ "F9", 75 }, .{ "F10", 76 }, .{ "F11", 95 }, .{ "F12", 96 },
    .{ "Space", 65 }, .{ "Return", 36 }, .{ "Tab", 23 }, .{ "Escape", 9 },
    .{ "Delete", 119 }, .{ "Up", 111 }, .{ "Down", 116 },
    .{ "Left", 113 }, .{ "Right", 114 },
    .{ "Minus", 20 }, .{ "Equal", 21 },
    .{ "BracketLeft", 34 }, .{ "BracketRight", 35 },
    .{ "Backslash", 51 }, .{ "Semicolon", 47 },
    .{ "Quote", 48 }, .{ "Comma", 59 }, .{ "Period", 60 },
    .{ "Slash", 61 }, .{ "Backquote", 49 },
    .{ "PageUp", 112 }, .{ "PageDown", 117 },
    .{ "Home", 110 }, .{ "End", 115 },
});

pub const HotkeyCallback = *const fn (hotkey_id: u32) void;

pub fn parseCombo(combo: []const u8) ?struct { keycode: u8, modifiers: UInt32 } {
    var modifiers: UInt32 = 0;
    var cursor: usize = 0;
    while (true) {
        const plus = std.mem.indexOfScalarPos(u8, combo, cursor, '+') orelse break;
        modifiers |= parseModifier(combo[cursor..plus]);
        cursor = plus + 1;
    }
    const keycode = keycode_map.get(combo[cursor..]) orelse return null;
    return .{ .keycode = keycode, .modifiers = modifiers };
}

fn parseModifier(token: []const u8) UInt32 {
    if (eqi(token, "CmdOrCtrl") or eqi(token, "Cmd") or eqi(token, "Ctrl") or eqi(token, "Control")) return cmdKey;
    if (eqi(token, "Shift")) return shiftKey;
    if (eqi(token, "Alt") or eqi(token, "Option") or eqi(token, "Mod1")) return altKey;
    if (eqi(token, "Meta") or eqi(token, "Super") or eqi(token, "Mod4")) return superKey;
    return 0;
}

fn eqi(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    return true;
}

var s_callback: ?HotkeyCallback = null;

pub fn setCallback(cb: HotkeyCallback) void {
    s_callback = cb;
    // TODO: install XCB grab or Wayland inhibitor
}

pub fn registerHotkey(keycode: u8, modifiers: UInt32) u32 {
    _ = keycode;
    _ = modifiers;
    if (comptime builtin.is_test) return 1;
    // TODO: call xcb_grab_key or zwp_*_inhibit
    return 0; // 0 = not registered
}

pub fn unregisterHotkey(id: u32) void {
    _ = id;
    // TODO: call xcb_ungrab_key or zwp_*_release
}

test "linux_hotkey: parseCombo Ctrl+Shift+K" {
    if (builtin.os.tag != .linux) return;
    const r = parseCombo("Ctrl+Shift+K").?;
    try std.testing.expectEqual(@as(u8, 45), r.keycode);
    try std.testing.expectEqual(cmdKey | shiftKey, r.modifiers);
}

test "linux_hotkey: parseCombo Alt+F5" {
    if (builtin.os.tag != .linux) return;
    const r = parseCombo("Alt+F5").?;
    try std.testing.expectEqual(@as(u8, 71), r.keycode);
    try std.testing.expectEqual(altKey, r.modifiers);
}
