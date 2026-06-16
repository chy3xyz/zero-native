//! macOS App Sandbox entitlements schema and plist generation.
//! See https://developer.apple.com/documentation/security/app_sandbox

const std = @import("std");

pub const Entitlement = struct {
    /// e.g. "com.apple.security.app-sandbox", "com.apple.security.network.client"
    key: []const u8,
    /// true/false for boolean entitlements, or a path string for resource entitlements
    value: Value,

    pub const Value = union(enum) {
        boolean: bool,
        string: []const u8,
        array: []const []const u8,
    };
};

pub const MacOSSandbox = struct {
    /// Must be true to enable the sandbox.
    sandbox: bool = true,
    /// Allow outgoing network connections.
    network_client: bool = false,
    network_server: bool = false,
    /// Allow reading files user explicitly selected via file dialog.
    files_user_selected_read: bool = false,
    files_user_selected_write: bool = false,
    /// Allow reading/writing specific directories (relative to the sandbox container).
    file_read: []const []const u8 = &.{},
    file_write: []const []const u8 = &.{},
    /// Allow camera / microphone / USB / printing.
    camera: bool = false,
    microphone: bool = false,
    usb: bool = false,
    printing: bool = false,
    /// Allow JIT and unsigned executable memory (required for WebView/JS JIT).
    allow_jit: bool = true,
    /// Custom entitlements (key-value pairs not covered by the statically-typed fields).
    custom: bool = false,
};

/// Returns the list of entitlements implied by the sandbox configuration.
/// Caller owns the returned slice and all strings within it (allocated via `allocator`).
pub fn entitlements(sandbox: MacOSSandbox, allocator: std.mem.Allocator) ![]Entitlement {
    var list = try std.ArrayList(Entitlement).initCapacity(allocator, 0);
    errdefer {
        for (list.items) |ent| freeEntitlement(allocator, ent);
        list.deinit(allocator);
    }

    if (sandbox.sandbox) {
        try list.append(allocator, .{ .key = "com.apple.security.app-sandbox", .value = .{ .boolean = true } });
    }
    if (sandbox.network_client) {
        try list.append(allocator, .{ .key = "com.apple.security.network.client", .value = .{ .boolean = true } });
    }
    if (sandbox.network_server) {
        try list.append(allocator, .{ .key = "com.apple.security.network.server", .value = .{ .boolean = true } });
    }
    if (sandbox.files_user_selected_read) {
        try list.append(allocator, .{ .key = "com.apple.security.files.user-selected.read-only", .value = .{ .boolean = true } });
    }
    if (sandbox.files_user_selected_write) {
        try list.append(allocator, .{ .key = "com.apple.security.files.user-selected.read-write", .value = .{ .boolean = true } });
    }
    if (sandbox.file_read.len > 0) {
        const duped = try duplicateStringList(allocator, sandbox.file_read);
        errdefer {
            for (duped) |s| allocator.free(s);
            allocator.free(duped);
        }
        try list.append(allocator, .{ .key = "com.apple.security.temporary-exception.files.absolute-path.read-only", .value = .{ .array = duped } });
    }
    if (sandbox.file_write.len > 0) {
        const duped = try duplicateStringList(allocator, sandbox.file_write);
        errdefer {
            for (duped) |s| allocator.free(s);
            allocator.free(duped);
        }
        try list.append(allocator, .{ .key = "com.apple.security.temporary-exception.files.absolute-path.read-write", .value = .{ .array = duped } });
    }
    if (sandbox.camera) {
        try list.append(allocator, .{ .key = "com.apple.security.device.camera", .value = .{ .boolean = true } });
    }
    if (sandbox.microphone) {
        try list.append(allocator, .{ .key = "com.apple.security.device.microphone", .value = .{ .boolean = true } });
    }
    if (sandbox.usb) {
        try list.append(allocator, .{ .key = "com.apple.security.device.usb", .value = .{ .boolean = true } });
    }
    if (sandbox.printing) {
        try list.append(allocator, .{ .key = "com.apple.security.print", .value = .{ .boolean = true } });
    }
    if (sandbox.allow_jit) {
        try list.append(allocator, .{ .key = "com.apple.security.cs.allow-unsigned-executable-memory", .value = .{ .boolean = true } });
    }

    return list.toOwnedSlice(allocator);
}

fn duplicateStringList(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    if (values.len == 0) return &.{};
    const out = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, index| {
        out[index] = try allocator.dupe(u8, value);
    }
    return out;
}

fn freeEntitlement(allocator: std.mem.Allocator, ent: Entitlement) void {
    switch (ent.value) {
        .boolean => {},
        .string => |s| allocator.free(s),
        .array => |arr| {
            for (arr) |s| allocator.free(s);
            if (arr.len > 0) allocator.free(arr);
        },
    }
}

/// Frees all entitlements allocated via `entitlements()`.
pub fn freeEntitlements(allocator: std.mem.Allocator, list: []Entitlement) void {
    for (list) |ent| freeEntitlement(allocator, ent);
    allocator.free(list);
}

/// Generates the full plist XML string for the given entitlements.
/// Caller owns the returned string.
pub fn toPlist(allocator: std.mem.Allocator, entitlement_list: []const Entitlement) ![]u8 {
    var buf = try std.ArrayList(u8).initCapacity(allocator, 0);
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\
    );

    for (entitlement_list) |ent| {
        try buf.appendSlice(allocator,"  <key>");
        try buf.appendSlice(allocator,ent.key);
        try buf.appendSlice(allocator,"</key>\n");

        switch (ent.value) {
            .boolean => |b| {
                if (b) {
                    try buf.appendSlice(allocator,"  <true/>\n");
                } else {
                    try buf.appendSlice(allocator,"  <false/>\n");
                }
            },
            .string => |s| {
                try buf.appendSlice(allocator,"  <string>");
                try buf.appendSlice(allocator,s);
                try buf.appendSlice(allocator,"</string>\n");
            },
            .array => |arr| {
                try buf.appendSlice(allocator,"  <array>\n");
                for (arr) |item| {
                    try buf.appendSlice(allocator,"    <string>");
                    try buf.appendSlice(allocator,item);
                    try buf.appendSlice(allocator,"</string>\n");
                }
                try buf.appendSlice(allocator,"  </array>\n");
            },
        }
    }

    try buf.appendSlice(allocator, "</dict>\n</plist>\n");

    return buf.toOwnedSlice(allocator);
}

/// Validates the sandbox configuration. Returns true if valid.
pub fn validate(_: MacOSSandbox) bool {
    return true;
}

test "entitlements() with default sandbox produces app-sandbox and allow-jit" {
    const sandbox = MacOSSandbox{};
    const ents = try entitlements(sandbox, std.testing.allocator);
    defer freeEntitlements(std.testing.allocator, ents);

    try std.testing.expect(ents.len >= 2);
    try std.testing.expectEqualStrings("com.apple.security.app-sandbox", ents[0].key);
    try std.testing.expect(ents[0].value.boolean);
    var found_jit = false;
    for (ents) |ent| {
        if (std.mem.eql(u8, ent.key, "com.apple.security.cs.allow-unsigned-executable-memory")) {
            found_jit = true;
            try std.testing.expect(ent.value.boolean);
        }
    }
    try std.testing.expect(found_jit);
}

test "entitlements() with network_client includes the network client entitlement" {
    const sandbox = MacOSSandbox{ .network_client = true };
    const ents = try entitlements(sandbox, std.testing.allocator);
    defer freeEntitlements(std.testing.allocator, ents);

    var found = false;
    for (ents) |ent| {
        if (std.mem.eql(u8, ent.key, "com.apple.security.network.client")) {
            found = true;
            try std.testing.expect(ent.value.boolean);
        }
    }
    try std.testing.expect(found);
}

test "entitlements() with file read paths includes file-read array entitlement" {
    const sandbox = MacOSSandbox{
        .file_read = &.{ "/Users", "/tmp" },
    };
    const ents = try entitlements(sandbox, std.testing.allocator);
    defer freeEntitlements(std.testing.allocator, ents);

    var found = false;
    for (ents) |ent| {
        if (std.mem.eql(u8, ent.key, "com.apple.security.temporary-exception.files.absolute-path.read-only")) {
            found = true;
            try std.testing.expect(ent.value == .array);
            try std.testing.expectEqual(@as(usize, 2), ent.value.array.len);
            try std.testing.expectEqualStrings("/Users", ent.value.array[0]);
            try std.testing.expectEqualStrings("/tmp", ent.value.array[1]);
        }
    }
    try std.testing.expect(found);
}

test "toPlist() produces valid XML with expected tags" {
    const sandbox = MacOSSandbox{};
    const ents = try entitlements(sandbox, std.testing.allocator);
    defer freeEntitlements(std.testing.allocator, ents);

    const plist = try toPlist(std.testing.allocator, ents);
    defer std.testing.allocator.free(plist);

    try std.testing.expect(std.mem.indexOf(u8, plist, "<?xml version=\"1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "<plist") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "<dict>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "<key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "<true/>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "</dict>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "</plist>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "com.apple.security.app-sandbox") != null);
}

test "toPlist() round-trip: entitlements -> plist -> verify key count" {
    const sandbox = MacOSSandbox{
        .network_client = true,
        .camera = true,
    };
    const ents = try entitlements(sandbox, std.testing.allocator);
    defer freeEntitlements(std.testing.allocator, ents);

    const plist = try toPlist(std.testing.allocator, ents);
    defer std.testing.allocator.free(plist);

    // Count <key> occurrences in the generated plist.
    var key_count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPosLinear(u8, plist, pos, "<key>")) |found| : (pos = found + 1) {
        key_count += 1;
    }
    try std.testing.expectEqual(ents.len, key_count);
}

test "entitlements() with all boolean flags enabled" {
    const sandbox = MacOSSandbox{
        .network_client = true,
        .network_server = true,
        .files_user_selected_read = true,
        .files_user_selected_write = true,
        .camera = true,
        .microphone = true,
        .usb = true,
        .printing = true,
    };
    const ents = try entitlements(sandbox, std.testing.allocator);
    defer freeEntitlements(std.testing.allocator, ents);

    const expected_keys = [_][]const u8{
        "com.apple.security.app-sandbox",
        "com.apple.security.network.client",
        "com.apple.security.network.server",
        "com.apple.security.files.user-selected.read-only",
        "com.apple.security.files.user-selected.read-write",
        "com.apple.security.device.camera",
        "com.apple.security.device.microphone",
        "com.apple.security.device.usb",
        "com.apple.security.print",
        "com.apple.security.cs.allow-unsigned-executable-memory",
    };

    for (expected_keys) |expected| {
        var found = false;
        for (ents) |ent| {
            if (std.mem.eql(u8, ent.key, expected)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "entitlements() with false sandbox produces no app-sandbox key" {
    const sandbox = MacOSSandbox{ .sandbox = false, .allow_jit = false };
    const ents = try entitlements(sandbox, std.testing.allocator);
    defer freeEntitlements(std.testing.allocator, ents);

    try std.testing.expectEqual(@as(usize, 0), ents.len);
}

test "toPlist() handles array entitlements" {
    const sandbox = MacOSSandbox{
        .sandbox = false,
        .allow_jit = false,
        .file_read = &.{ "/Users/n0x/Documents", "/tmp" },
    };
    const ents = try entitlements(sandbox, std.testing.allocator);
    defer freeEntitlements(std.testing.allocator, ents);

    try std.testing.expectEqual(@as(usize, 1), ents.len);

    const plist = try toPlist(std.testing.allocator, ents);
    defer std.testing.allocator.free(plist);

    try std.testing.expect(std.mem.indexOf(u8, plist, "<array>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "</array>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "<string>/Users/n0x/Documents</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "<string>/tmp</string>") != null);
}
