//! Clipboard plugin module — in-memory text buffer with command dispatch.
//!
//! The extension `Command` struct only carries a name and an optional target
//! module id, so there is no in-band payload. The `clipboard.write_text`
//! command populates the buffer with a default sample, and the
//! `clipboard.read_text` command duplicates the current buffer into
//! `state.last_read` for inspection. A future revision that adds a payload
//! channel can swap the default-text write for a payload-driven write without
//! changing the surrounding hooks or registry wiring.

const std = @import("std");
const extensions = @import("root.zig");

/// Unique module id for the clipboard plugin.
pub const ModuleId: extensions.ModuleId = 100;

/// Default text written by the `clipboard.write_text` command.
pub const default_text: []const u8 = "clipboard: hello";

/// Mutable state owned by a clipboard module instance.
pub const ClipboardState = struct {
    text: ?[]u8,
    last_read: ?[]u8,
    allocator: std.mem.Allocator,
};

/// Allocate the plugin state and return a `Module` view.
pub fn create(allocator: std.mem.Allocator) !extensions.Module {
    const state = try allocator.create(ClipboardState);
    errdefer allocator.destroy(state);
    state.* = .{
        .text = null,
        .last_read = null,
        .allocator = allocator,
    };
    const capabilities = [_]extensions.Capability{.{ .kind = .clipboard }};
    return .{
        .info = .{
            .id = ModuleId,
            .name = "clipboard",
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

/// Start hook — no-op for the in-memory clipboard.
pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}

/// Stop hook — frees the buffers and the state. Safe to call once per
/// `create`; subsequent calls would double-free.
pub fn stop(context: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const state: *ClipboardState = @ptrCast(@alignCast(context));
    if (state.text) |text| state.allocator.free(text);
    if (state.last_read) |last| state.allocator.free(last);
    state.allocator.destroy(state);
}

/// Command hook — dispatches `clipboard.write_text` and `clipboard.read_text`.
pub fn command(
    context: *anyopaque,
    _: extensions.RuntimeContext,
    cmd: extensions.Command,
) anyerror!void {
    const state: *ClipboardState = @ptrCast(@alignCast(context));
    if (std.mem.eql(u8, cmd.name, "clipboard.write_text")) {
        if (state.text) |old| state.allocator.free(old);
        state.text = try state.allocator.dupe(u8, default_text);
    } else if (std.mem.eql(u8, cmd.name, "clipboard.read_text")) {
        if (state.last_read) |old| {
            state.allocator.free(old);
            state.last_read = null;
        }
        if (state.text) |text| {
            state.last_read = try state.allocator.dupe(u8, text);
        }
    }
}

test "clipboard write then read round-trips the default text" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };
    const state: *ClipboardState = @ptrCast(@alignCast(module.context));

    try std.testing.expect(state.text == null);
    try std.testing.expect(state.last_read == null);

    try module.hooks.start_fn.?(module.context, runtime);
    try module.hooks.command_fn.?(module.context, runtime, .{ .name = "clipboard.write_text" });
    try std.testing.expect(state.text != null);
    try std.testing.expectEqualStrings(default_text, state.text.?);

    try module.hooks.command_fn.?(module.context, runtime, .{ .name = "clipboard.read_text" });
    try std.testing.expect(state.last_read != null);
    try std.testing.expectEqualStrings(state.text.?, state.last_read.?);

    // `stop` must free the buffers and the state — std.testing.allocator
    // verifies no leaks at the end of the test scope.
    try module.hooks.stop_fn.?(module.context, runtime);
}

test "clipboard start and stop do not crash" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };
    try module.hooks.start_fn.?(module.context, runtime);
    try module.hooks.stop_fn.?(module.context, runtime);
}

test "clipboard registers in a ModuleRegistry" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);
    const modules = [_]extensions.Module{module};
    const registry = extensions.ModuleRegistry{ .modules = &modules };
    try registry.validate();
    try std.testing.expect(registry.hasCapability(.clipboard));

    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };
    try registry.startAll(runtime);
    try registry.stopAll(runtime);
}
