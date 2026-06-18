//! macOS Carbon hotkey helpers.
//!
//! During test builds the Carbon `extern fn` symbols are not linked
//! (appkit_host is compiled externally), so we provide no-op stubs.
//! In production builds the real Carbon functions are linked.

const std = @import("std");
const builtin = @import("builtin");

const UInt32 = u32;
const cmdKey: UInt32 = 1 << 8;
const shiftKey: UInt32 = 1 << 9;
const optionKey: UInt32 = 1 << 11;
const controlKey: UInt32 = 1 << 12;

const keycode_map = std.StaticStringMap(u8).initComptime(.{
    .{ "A", 0x00 }, .{ "B", 0x0B }, .{ "C", 0x08 }, .{ "D", 0x02 },
    .{ "E", 0x0E }, .{ "F", 0x03 }, .{ "G", 0x05 }, .{ "H", 0x04 },
    .{ "I", 0x22 }, .{ "J", 0x26 }, .{ "K", 0x28 }, .{ "L", 0x25 },
    .{ "M", 0x2E }, .{ "N", 0x2D }, .{ "O", 0x1F }, .{ "P", 0x23 },
    .{ "Q", 0x0C }, .{ "R", 0x0F }, .{ "S", 0x01 }, .{ "T", 0x11 },
    .{ "U", 0x20 }, .{ "V", 0x09 }, .{ "W", 0x0D }, .{ "X", 0x07 },
    .{ "Y", 0x10 }, .{ "Z", 0x06 },
    .{ "0", 0x1D }, .{ "1", 0x12 }, .{ "2", 0x13 }, .{ "3", 0x14 },
    .{ "4", 0x15 }, .{ "5", 0x17 }, .{ "6", 0x16 }, .{ "7", 0x1A },
    .{ "8", 0x1C }, .{ "9", 0x19 },
    .{ "F1", 0x7A }, .{ "F2", 0x78 }, .{ "F3", 0x63 }, .{ "F4", 0x76 },
    .{ "F5", 0x60 }, .{ "F6", 0x61 }, .{ "F7", 0x62 }, .{ "F8", 0x64 },
    .{ "F9", 0x65 }, .{ "F10", 0x6D }, .{ "F11", 0x67 }, .{ "F12", 0x6F },
    .{ "Space", 0x31 },
    .{ "Return", 0x24 }, .{ "Tab", 0x30 }, .{ "Escape", 0x35 },
    .{ "Delete", 0x33 }, .{ "Up", 0x7E }, .{ "Down", 0x7D },
    .{ "Left", 0x7B }, .{ "Right", 0x7C },
    .{ "Minus", 0x1B }, .{ "Equal", 0x18 },
    .{ "BracketLeft", 0x21 }, .{ "BracketRight", 0x1E },
    .{ "Backslash", 0x2A }, .{ "Semicolon", 0x29 },
    .{ "Quote", 0x27 }, .{ "Comma", 0x2B }, .{ "Period", 0x2F },
    .{ "Slash", 0x2C }, .{ "Backquote", 0x32 },
    .{ "PageUp", 0x74 }, .{ "PageDown", 0x79 },
    .{ "Home", 0x73 }, .{ "End", 0x77 },
});

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
    if (eqi(token, "CmdOrCtrl") or eqi(token, "Cmd") or eqi(token, "Meta") or eqi(token, "Super")) return cmdKey;
    if (eqi(token, "Ctrl") or eqi(token, "Control")) return controlKey;
    if (eqi(token, "Shift")) return shiftKey;
    if (eqi(token, "Alt") or eqi(token, "Option")) return optionKey;
    return 0;
}

fn eqi(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    return true;
}

// ── Dispatch: stub in tests, real extern in production ─────────────────────

pub const HotkeyCallback = *const fn (hotkey_id: u32) void;

var s_callback: ?HotkeyCallback = null;

pub fn setCallback(cb: HotkeyCallback) void {
    s_callback = cb;
    if (comptime builtin.is_test) return;
    zero_native_appkit_set_hotkey_callback(&hotkeyBridgeCallback);
}

pub fn registerHotkey(keycode: u8, modifiers: UInt32) u32 {
    if (comptime builtin.is_test) return 1;
    return zero_native_appkit_register_hotkey(keycode, modifiers);
}

pub fn unregisterHotkey(id: u32) void {
    if (comptime builtin.is_test) {
        if (id > id) {} // compile-time trick: never true but "uses" id
        return;
    }
    zero_native_appkit_unregister_hotkey(id);
}

fn hotkeyBridgeCallback(hotkey_id: u32) callconv(.c) void {
    if (s_callback) |cb| cb(hotkey_id);
}

// Extern declarations — only resolved in production builds
extern fn zero_native_appkit_register_hotkey(keycode: u32, modifiers: UInt32) u32;
extern fn zero_native_appkit_unregister_hotkey(hotkey_id: u32) void;
extern fn zero_native_appkit_set_hotkey_callback(callback: ?*const fn (u32) callconv(.c) void) void;

// ── Tests ──────────────────────────────────────────────────────────────────

test "macos_hotkey: parseCombo CmdOrCtrl+Shift+K" {
    if (builtin.os.tag != .macos) return;
    const r = parseCombo("CmdOrCtrl+Shift+K").?;
    try std.testing.expectEqual(@as(u8, 0x28), r.keycode);
    try std.testing.expectEqual(cmdKey | shiftKey, r.modifiers);
}

test "macos_hotkey: parseCombo Alt+F5" {
    if (builtin.os.tag != .macos) return;
    const r = parseCombo("Alt+F5").?;
    try std.testing.expectEqual(@as(u8, 0x60), r.keycode);
    try std.testing.expectEqual(optionKey, r.modifiers);
}

test "macos_hotkey: parseCombo returns null for unknown" {
    if (builtin.os.tag != .macos) return;
    try std.testing.expect(parseCombo("Cmd+UnknownF13") == null);
}

test "macos_hotkey: test-mode registerHotkey returns non-zero" {
    if (builtin.os.tag != .macos) return;
    try std.testing.expect(builtin.is_test);
    const id = registerHotkey(0, 0);
    try std.testing.expect(id != 0);
}
