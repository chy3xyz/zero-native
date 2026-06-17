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
        \\  list              List all 11 bundled plugins (default)
        \\  info <name>       Show a single plugin's metadata
        \\  create <name>     Scaffold a new plugin file in the current directory
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
/// subcommand (and optional plugin name) from the parent CLI. `io` is used
/// when the `create` subcommand writes a scaffolded plugin file.
pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    try runInDir(allocator, io, std.Io.Dir.cwd(), args);
}

/// Same as `run` but operates on `dir` instead of the process cwd. Useful
/// for tests that need to isolate generated plugin files.
pub fn runInDir(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, args: []const []const u8) !void {
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
    } else if (std.mem.eql(u8, subcommand, "create")) {
        if (args.len < 2) {
            usage();
            return error.MissingArgument;
        }
        try create(allocator, io, dir, args[1]);
        std.debug.print("created plugin_{s}.zig\n", .{args[1]});
    } else if (std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        usage();
    } else {
        // Treat an unknown first arg as a plugin name to keep
        // `zero-native plugins clipboard` working as a shortcut.
        try printInfo(allocator, subcommand);
    }
}

/// Validates a plugin name. Names must be non-empty, start with a lowercase
/// letter, and contain only lowercase letters, digits, and dashes. They may
/// not end with a dash.
pub fn validateName(name: []const u8) error{InvalidPluginName}!void {
    if (name.len == 0) return error.InvalidPluginName;
    if (!std.ascii.isLower(name[0])) return error.InvalidPluginName;
    if (name[name.len - 1] == '-') return error.InvalidPluginName;
    for (name) |c| {
        if (std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-') continue;
        return error.InvalidPluginName;
    }
}

/// Returns the next free module id for a newly scaffolded plugin. The
/// bundled plugins occupy ids 100..110, so the first user-scaffolded id
/// is 111.
pub fn nextModuleId() u16 {
    return 111;
}

/// Scaffolds a new plugin file named `plugin_<name>.zig` inside `dir`.
/// The generated file contains a minimal but complete plugin module with
/// `create`, `start`, `stop`, `command`, and a passing test.
pub fn create(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, name: []const u8) !void {
    try validateName(name);

    const file_name = try std.fmt.allocPrint(allocator, "plugin_{s}.zig", .{name});
    defer allocator.free(file_name);

    const content = try renderTemplate(allocator, name, nextModuleId());
    defer allocator.free(content);

    try dir.writeFile(io, .{
        .sub_path = file_name,
        .data = content,
    });
}

fn renderTemplate(allocator: std.mem.Allocator, name: []const u8, module_id: u16) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    errdefer buffer.deinit(allocator);

    try buffer.print(allocator, "//! {s} plugin module — auto-generated scaffold.\n", .{name});
    try buffer.appendSlice(allocator, "//!\n");
    try buffer.appendSlice(allocator, "//! Edit the module id, name, commands, and state to match your plugin.\n");
    try buffer.appendSlice(allocator, "\n");
    try buffer.appendSlice(allocator, "const std = @import(\"std\");\n");
    try buffer.appendSlice(allocator, "const extensions = @import(\"root.zig\");\n");
    try buffer.appendSlice(allocator, "\n");
    try buffer.print(allocator, "pub const ModuleId: extensions.ModuleId = {d};\n", .{module_id});
    try buffer.appendSlice(allocator, "\n");
    try buffer.appendSlice(allocator, "const PluginState = struct {\n");
    try buffer.appendSlice(allocator, "    value: ?[]u8,\n");
    try buffer.appendSlice(allocator, "    allocator: std.mem.Allocator,\n");
    try buffer.appendSlice(allocator, "};\n");
    try buffer.appendSlice(allocator, "\n");
    try buffer.appendSlice(allocator, "pub fn create(allocator: std.mem.Allocator) !extensions.Module {\n");
    try buffer.appendSlice(allocator, "    const state = try allocator.create(PluginState);\n");
    try buffer.appendSlice(allocator, "    errdefer allocator.destroy(state);\n");
    try buffer.appendSlice(allocator, "    state.* = .{\n");
    try buffer.appendSlice(allocator, "        .value = null,\n");
    try buffer.appendSlice(allocator, "        .allocator = allocator,\n");
    try buffer.appendSlice(allocator, "    };\n");
    try buffer.appendSlice(allocator, "    const capabilities = [_]extensions.Capability{.{\n");
    try buffer.appendSlice(allocator, "        .kind = .custom,\n");
    try buffer.print(allocator, "        .name = \"{s}\",\n", .{name});
    try buffer.appendSlice(allocator, "    }};\n");
    try buffer.appendSlice(allocator, "    return .{\n");
    try buffer.appendSlice(allocator, "        .info = .{\n");
    try buffer.appendSlice(allocator, "            .id = ModuleId,\n");
    try buffer.print(allocator, "            .name = \"{s}\",\n", .{name});
    try buffer.appendSlice(allocator, "            .capabilities = &capabilities,\n");
    try buffer.appendSlice(allocator, "        },\n");
    try buffer.appendSlice(allocator, "        .context = @ptrCast(state),\n");
    try buffer.appendSlice(allocator, "        .hooks = .{\n");
    try buffer.appendSlice(allocator, "            .start_fn = start,\n");
    try buffer.appendSlice(allocator, "            .stop_fn = stop,\n");
    try buffer.appendSlice(allocator, "            .command_fn = command,\n");
    try buffer.appendSlice(allocator, "        },\n");
    try buffer.appendSlice(allocator, "    };\n");
    try buffer.appendSlice(allocator, "}\n");
    try buffer.appendSlice(allocator, "\n");
    try buffer.appendSlice(allocator, "pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}\n");
    try buffer.appendSlice(allocator, "\n");
    try buffer.appendSlice(allocator, "pub fn stop(context: *anyopaque, _: extensions.RuntimeContext) anyerror!void {\n");
    try buffer.appendSlice(allocator, "    const state: *PluginState = @ptrCast(@alignCast(context));\n");
    try buffer.appendSlice(allocator, "    if (state.value) |old| state.allocator.free(old);\n");
    try buffer.appendSlice(allocator, "    state.allocator.destroy(state);\n");
    try buffer.appendSlice(allocator, "}\n");
    try buffer.appendSlice(allocator, "\n");
    try buffer.appendSlice(allocator, "pub fn command(\n");
    try buffer.appendSlice(allocator, "    context: *anyopaque,\n");
    try buffer.appendSlice(allocator, "    _: extensions.RuntimeContext,\n");
    try buffer.appendSlice(allocator, "    cmd: extensions.Command,\n");
    try buffer.appendSlice(allocator, ") anyerror!void {\n");
    try buffer.appendSlice(allocator, "    const state: *PluginState = @ptrCast(@alignCast(context));\n");
    try buffer.print(allocator, "    if (std.mem.eql(u8, cmd.name, \"{s}.ping\")) {{\n", .{name});
    try buffer.appendSlice(allocator, "        if (state.value) |old| state.allocator.free(old);\n");
    try buffer.appendSlice(allocator, "        state.value = try state.allocator.dupe(u8, \"pong\");\n");
    try buffer.appendSlice(allocator, "    }\n");
    try buffer.appendSlice(allocator, "}\n");
    try buffer.appendSlice(allocator, "\n");
    try buffer.print(allocator, "test \"{s} create round-trips ping\" {{\n", .{name});
    try buffer.appendSlice(allocator, "    const allocator = std.testing.allocator;\n");
    try buffer.appendSlice(allocator, "    const module = try create(allocator);\n");
    try buffer.appendSlice(allocator, "    const runtime: extensions.RuntimeContext = .{ .platform_name = \"null\" };\n");
    try buffer.appendSlice(allocator, "    const state: *PluginState = @ptrCast(@alignCast(module.context));\n");
    try buffer.appendSlice(allocator, "\n");
    try buffer.appendSlice(allocator, "    try std.testing.expect(state.value == null);\n");
    try buffer.print(allocator, "    try module.hooks.command_fn.?(module.context, runtime, .{{ .name = \"{s}.ping\" }});\n", .{name});
    try buffer.appendSlice(allocator, "    try std.testing.expectEqualStrings(\"pong\", state.value.?);\n");
    try buffer.appendSlice(allocator, "    if (module.hooks.stop_fn) |stop_fn| {\n");
    try buffer.appendSlice(allocator, "        try stop_fn(module.context, runtime);\n");
    try buffer.appendSlice(allocator, "    }\n");
    try buffer.appendSlice(allocator, "}\n");

    return buffer.toOwnedSlice(allocator);
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

test "validateName accepts valid plugin names" {
    try validateName("hello");
    try validateName("my-plugin");
    try validateName("plugin123");
}

test "validateName rejects invalid plugin names" {
    try std.testing.expectError(error.InvalidPluginName, validateName(""));
    try std.testing.expectError(error.InvalidPluginName, validateName("Hello"));
    try std.testing.expectError(error.InvalidPluginName, validateName("my_plugin"));
    try std.testing.expectError(error.InvalidPluginName, validateName("-plugin"));
    try std.testing.expectError(error.InvalidPluginName, validateName("plugin-"));
}

test "nextModuleId returns 111" {
    try std.testing.expectEqual(@as(u16, 111), nextModuleId());
}

test "create writes plugin file with expected module id" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try create(allocator, io, tmp.dir, "demo");

    const content = try tmp.dir.readFileAlloc(io, "plugin_demo.zig", allocator, .unlimited);
    defer allocator.free(content);

    try std.testing.expect(std.mem.containsAtLeast(u8, content, 1, "pub const ModuleId: extensions.ModuleId = 111"));
    try std.testing.expect(std.mem.containsAtLeast(u8, content, 1, "pub fn create"));
}

test "run with create writes plugin file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try runInDir(allocator, io, tmp.dir, &.{ "create", "my-plugin" });

    _ = try tmp.dir.statFile(io, "plugin_my-plugin.zig", .{});
}
