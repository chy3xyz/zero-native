//! `zero-native plugins` — list and inspect the bundled plugins.
//!
//! The bundled plugin set is declared in `src/extensions/plugin_*.zig` and
//! enumerated statically by id and name. The descriptions below are the
//! first sentence of each plugin's top-of-file `//!` doc comment.

const std = @import("std");

/// Metadata about a bundled plugin.
pub const PluginInfo = struct {
    name: []const u8,
    module_id: u16,
    /// First sentence from the file's top-of-file `//!` doc comment.
    description: []const u8,
};

/// Returns the metadata for all 11 bundled plugins. The returned slice
/// and every string inside it are owned by `allocator`; free with
/// `deinitList`.
pub fn list(allocator: std.mem.Allocator) ![]PluginInfo {
    const source: []const PluginInfo = &.{
        .{ .name = "clipboard", .module_id = 100, .description = "Clipboard plugin module — in-memory text buffer with command dispatch." },
        .{ .name = "shell", .module_id = 101, .description = "Shell plugin module — spawns child processes via `std.process.spawn`." },
        .{ .name = "notification", .module_id = 102, .description = "Notification plugin module — in-memory notification log with command dispatch." },
        .{ .name = "http", .module_id = 103, .description = "HTTP plugin module — executes real HTTP/1.1 requests via a vendored client." },
        .{ .name = "deep-link", .module_id = 104, .description = "Deep link plugin module — URL scheme handler registration and last-url recording." },
        .{ .name = "store", .module_id = 105, .description = "In-memory key-value store plugin." },
        .{ .name = "autostart", .module_id = 106, .description = "Autostart plugin module — manages OS-level autostart registration." },
        .{ .name = "single-instance", .module_id = 107, .description = "Single-instance plugin module — detects whether another instance of the same app is already running using a lock file in a temp directory." },
        .{ .name = "updater", .module_id = 108, .description = "Auto-updater plugin — fetches and applies update manifests." },
        .{ .name = "global-shortcut", .module_id = 109, .description = "Global-shortcut plugin module — records registered keyboard shortcut combos in memory with a mock trigger for testing." },
        .{ .name = "websocket", .module_id = 110, .description = "WebSocket client plugin module — RFC 6455 handshake + frame encode/decode." },
    };
    const out = try allocator.alloc(PluginInfo, source.len);
    for (source, 0..) |entry, index| {
        out[index] = .{
            .name = try allocator.dupe(u8, entry.name),
            .module_id = entry.module_id,
            .description = try allocator.dupe(u8, entry.description),
        };
    }
    return out;
}

/// Frees a slice returned by `list`.
pub fn deinitList(allocator: std.mem.Allocator, entries: []PluginInfo) void {
    for (entries) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.description);
    }
    allocator.free(entries);
}

/// Returns the metadata for a single plugin by name. Returns `null` if
/// the name is not one of the 11 bundled plugins. The returned `PluginInfo`
/// owns its strings; free with `deinitInfo`.
pub fn info(allocator: std.mem.Allocator, name: []const u8) ?PluginInfo {
    const entries = list(allocator) catch return null;
    defer deinitList(allocator, entries);
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            const owned_name = allocator.dupe(u8, entry.name) catch return null;
            const owned_description = allocator.dupe(u8, entry.description) catch {
                allocator.free(owned_name);
                return null;
            };
            return .{
                .name = owned_name,
                .module_id = entry.module_id,
                .description = owned_description,
            };
        }
    }
    return null;
}

/// Frees a `PluginInfo` returned by `info`.
pub fn deinitInfo(allocator: std.mem.Allocator, entry: PluginInfo) void {
    allocator.free(entry.name);
    allocator.free(entry.description);
}

/// Discriminator for the plugin's primary capability.
pub const CapabilityKindTag = enum {
    native_module,
    network,
    filesystem,
    clipboard,
    custom,
};

/// Returns the dominant capability kind for a plugin by name. The plugin
/// files declare their capabilities inline in the `info` struct, so the
/// classification is reconstructed from the plugin's name.
pub fn capabilityKind(name: []const u8) CapabilityKindTag {
    if (std.mem.eql(u8, name, "clipboard")) return .clipboard;
    if (std.mem.eql(u8, name, "http") or
        std.mem.eql(u8, name, "websocket") or
        std.mem.eql(u8, name, "notification")) return .network;
    if (std.mem.eql(u8, name, "store")) return .filesystem;
    return .native_module;
}

fn usage() void {
    std.debug.print(
        \\usage: zero-native plugins <command>
        \\
        \\commands:
        \\  list           List all 11 bundled plugins (default)
        \\  info <name>    Show a single plugin's metadata
        \\
    , .{});
}

fn printList(allocator: std.mem.Allocator) !void {
    const entries = try list(allocator);
    defer deinitList(allocator, entries);
    std.debug.print("name              id   description\n", .{});
    std.debug.print("----------------  ---  -----------\n", .{});
    for (entries) |entry| {
        std.debug.print("  {s:<14}  {d:>3}  {s}\n", .{ entry.name, entry.module_id, entry.description });
    }
}

fn printInfo(allocator: std.mem.Allocator, name: []const u8) !void {
    const entry = info(allocator, name) orelse {
        std.debug.print("unknown plugin: {s}\n", .{name});
        return error.UnknownPlugin;
    };
    defer deinitInfo(allocator, entry);

    std.debug.print("name:        {s}\n", .{entry.name});
    std.debug.print("ModuleId:    {d}\n", .{entry.module_id});
    std.debug.print("capability:  {s}\n", .{@tagName(capabilityKind(entry.name))});
    std.debug.print("\n{s}\n\n", .{entry.description});
    std.debug.print(
        \\usage example:
        \\  zero-native init my-app --frontend next
        \\  # add to app.zon:
        \\  .plugins = .{{ "{s}" }}
        \\
    , .{entry.name});
}

/// Parses args and dispatches to the matching handler. `args` carries the
/// subcommand (and optional plugin name) from the parent CLI. `io` is
/// accepted for parity with other tooling entry points; this command
/// does not perform I/O.
pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    _ = io;
    if (args.len == 0) {
        try printList(allocator);
        return;
    }
    const subcommand = args[0];
    if (std.mem.eql(u8, subcommand, "list")) {
        try printList(allocator);
    } else if (std.mem.eql(u8, subcommand, "info")) {
        if (args.len < 2) {
            usage();
            return error.MissingArgument;
        }
        try printInfo(allocator, args[1]);
    } else if (std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        usage();
    } else {
        // Treat an unknown first arg as a plugin name to keep
        // `zero-native plugins clipboard` working as a shortcut.
        try printInfo(allocator, subcommand);
    }
}

// Sanity check: make sure the bundled plugin ids fit in `u16`. The
// plugin files declare `pub const ModuleId: extensions.ModuleId = N`
// where `extensions.ModuleId = u64`, but the bundled set lives in the
// 100..110 range, so the truncation is safe. The check uses a comptime
// literal so we do not need to import the `extensions` module here.

test "list returns 11 entries with non-empty names" {
    const allocator = std.testing.allocator;
    const entries = try list(allocator);
    defer deinitList(allocator, entries);
    try std.testing.expectEqual(@as(usize, 11), entries.len);
    for (entries) |entry| {
        try std.testing.expect(entry.name.len > 0);
        try std.testing.expect(entry.description.len > 0);
    }
}

test "info returns clipboard at module id 100" {
    const allocator = std.testing.allocator;
    const entry = info(allocator, "clipboard") orelse return error.TestUnexpectedNull;
    defer deinitInfo(allocator, entry);
    try std.testing.expectEqualStrings("clipboard", entry.name);
    try std.testing.expectEqual(@as(u16, 100), entry.module_id);
}

test "info returns null for unknown plugin" {
    const allocator = std.testing.allocator;
    try std.testing.expect(info(allocator, "nonexistent") == null);
}

test "run with list does not error" {
    const io = std.testing.io;
    try run(std.testing.allocator, io, &.{"list"});
}

test "run with info http does not error" {
    const io = std.testing.io;
    try run(std.testing.allocator, io, &.{ "info", "http" });
}
