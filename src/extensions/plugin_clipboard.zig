//! Clipboard plugin module — in-memory text buffer with optional native OS
//! clipboard sync.
//!
//! Commands are routed by `cmd.name` only; any argument string lives in
//! `cmd.payload`. Supported commands:
//! - `clipboard.write_text` — writes `cmd.payload` to the in-memory buffer and
//!   attempts to push the same text to the host OS clipboard. When
//!   `cmd.payload` is empty, the fixed sample `default_text` is used so the
//!   test suite can exercise the write path without a real clipboard bridge.
//! - `clipboard.read_text` — tries to read from the host OS clipboard first;
//!   if that fails or returns nothing, it falls back to the in-memory buffer.
//!   The result is duplicated into `state.last_read` for inspection.
//!
//! Native clipboard integration is best-effort: if the platform utility is
//! missing, the display server is unreachable, or the child exits with a
//! non-zero status, the plugin silently keeps using the in-memory buffer.

const builtin = @import("builtin");
const std = @import("std");
const extensions = @import("root.zig");

/// Unique module id for the clipboard plugin.
pub const ModuleId: extensions.ModuleId = 100;

/// Default text written by the `clipboard.write_text` command when the
/// caller leaves `cmd.payload` empty. Matches the convention used by the
/// other plugins (a fixed sample so tests have something predictable to
/// assert against without needing a real clipboard bridge).
pub const default_text: []const u8 = "hello from test";

/// Maximum size, in bytes, that the plugin will read back from a native
/// clipboard utility. This bounds the allocation made by `std.process.run`.
const max_clipboard_bytes = 1 * 1024 * 1024;

/// Mutable state owned by a clipboard module instance.
pub const ClipboardState = struct {
    text: ?[]u8,
    last_read: ?[]u8,
    /// Threaded IO instance used to spawn native clipboard utilities.
    /// `std.process.spawn` needs an `Io` with a real allocator; the global
    /// single-threaded instance defaults to `.failing`, so the plugin owns
    /// a fresh `Threaded` initialised with its own allocator.
    io_thread: std.Io.Threaded,
    allocator: std.mem.Allocator,
};

/// Allocate the plugin state and return a `Module` view.
pub fn create(allocator: std.mem.Allocator) !extensions.Module {
    const state = try allocator.create(ClipboardState);
    errdefer allocator.destroy(state);
    state.* = .{
        .text = null,
        .last_read = null,
        .io_thread = std.Io.Threaded.init(allocator, .{}),
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

/// Start hook — no-op for the clipboard plugin.
pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}

/// Stop hook — frees the buffers, tears down the threaded IO instance, and
/// destroys the state. Safe to call once per `create`; subsequent calls would
/// double-free.
pub fn stop(context: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const state: *ClipboardState = @ptrCast(@alignCast(context));
    if (state.text) |text| state.allocator.free(text);
    if (state.last_read) |last| state.allocator.free(last);
    state.io_thread.deinit();
    state.allocator.destroy(state);
}

/// Command hook — dispatches `clipboard.write_text` and `clipboard.read_text`.
pub fn command(
    context: *anyopaque,
    _: extensions.RuntimeContext,
    cmd: extensions.Command,
) anyerror!void {
    const state: *ClipboardState = @ptrCast(@alignCast(context));
    const io = state.io_thread.io();

    if (std.mem.eql(u8, cmd.name, "clipboard.write_text")) {
        if (state.text) |old| state.allocator.free(old);
        const text = if (cmd.payload.len == 0) default_text else cmd.payload;
        state.text = try state.allocator.dupe(u8, text);
        // Push the text to the host OS clipboard. Failures are ignored; the
        // in-memory buffer remains the authoritative fallback.
        writeNativeClipboard(io, text) catch {};
    } else if (std.mem.eql(u8, cmd.name, "clipboard.read_text")) {
        if (state.last_read) |old| {
            state.allocator.free(old);
            state.last_read = null;
        }
        // Try to read from the host OS clipboard first. If that fails or
        // returns nothing, fall back to the in-memory buffer.
        if (readNativeClipboard(io, state.allocator)) |native| {
            defer state.allocator.free(native);
            state.last_read = try state.allocator.dupe(u8, native);
        } else |_| {
            if (state.text) |text| {
                state.last_read = try state.allocator.dupe(u8, text);
            }
        }
    }
}

// -----------------------------------------------------------------------------
// Native clipboard helpers
// -----------------------------------------------------------------------------

/// Errors returned when the native clipboard cannot be used. The command hook
/// treats every error the same way: keep the in-memory buffer as the source of
/// truth.
const NativeClipboardError = error{
    NoClipboardData,
    ClipboardUnavailable,
};

/// Write `text` to the host OS clipboard using the platform utility. Returns
/// an error if the utility is unavailable or the child exits unsuccessfully.
fn writeNativeClipboard(io: std.Io, text: []const u8) !void {
    switch (builtin.os.tag) {
        .macos => return spawnWriteClipboard(io, &.{"pbcopy"}, text),
        .linux => return writeNativeClipboardLinux(io, text),
        .windows => return spawnWriteClipboard(io, &.{"clip"}, text),
        else => return error.ClipboardUnavailable,
    }
}

/// Linux write path: prefer `wl-copy` (Wayland), fall back to `xclip` (X11).
fn writeNativeClipboardLinux(io: std.Io, text: []const u8) !void {
    if (spawnWriteClipboard(io, &.{"wl-copy"}, text)) {
        return;
    } else |_| {}
    return spawnWriteClipboard(io, &.{
        "xclip",
        "-selection",
        "clipboard",
        "-in",
    }, text);
}

/// Read text from the host OS clipboard using the platform utility. The caller
/// owns the returned slice and must free it with the same allocator.
fn readNativeClipboard(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    switch (builtin.os.tag) {
        .macos => return runReadClipboard(io, allocator, &.{"pbpaste"}),
        .linux => return readNativeClipboardLinux(io, allocator),
        .windows => return readNativeClipboardWindows(io, allocator),
        else => return error.ClipboardUnavailable,
    }
}

/// Linux read path: prefer `wl-paste` (Wayland), fall back to `xclip` (X11).
fn readNativeClipboardLinux(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    if (runReadClipboard(io, allocator, &.{"wl-paste"})) |text| {
        return text;
    } else |_| {}
    return runReadClipboard(io, allocator, &.{
        "xclip",
        "-selection",
        "clipboard",
        "-out",
    });
}

/// Windows read path: `powershell.exe -Command Get-Clipboard`. PowerShell
/// appends a trailing newline to console output, so one newline is trimmed to
/// preserve round-trip fidelity.
fn readNativeClipboardWindows(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var text = try runReadClipboard(io, allocator, &.{
        "powershell.exe",
        "-Command",
        "Get-Clipboard",
    });
    errdefer allocator.free(text);

    if (std.mem.endsWith(u8, text, "\r\n")) {
        text = try allocator.realloc(text, text.len - 2);
    } else if (std.mem.endsWith(u8, text, "\n")) {
        text = try allocator.realloc(text, text.len - 1);
    }
    return text;
}

/// Spawn `argv` with `text` piped to its stdin. Returns an error if the
/// utility cannot be spawned, writing fails, or the child exits unsuccessfully.
fn spawnWriteClipboard(io: std.Io, argv: []const []const u8, text: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io);

    // Write the payload to the child's stdin. If writing fails we still close
    // stdin and wait so that the child's stdout/stderr handles are cleaned up.
    var write_err: ?anyerror = null;
    var write_buffer: [4096]u8 = undefined;
    {
        var stdin_writer = child.stdin.?.writer(io, &write_buffer);
        stdin_writer.interface.writeAll(text) catch |err| {
            write_err = err;
        };
        if (write_err == null) {
            stdin_writer.flush() catch |err| {
                write_err = err;
            };
        }
    }
    child.stdin.?.close(io);
    child.stdin = null;

    const term = try child.wait(io);
    if (write_err) |err| return err;
    if (!term.success()) return error.ClipboardUnavailable;
}

/// Run `argv`, capture its stdout, and return it on success. Returns an error
/// if the utility cannot be spawned, the child exits unsuccessfully, or the
/// output is empty.
fn runReadClipboard(io: std.Io, allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = std.Io.Limit.limited(max_clipboard_bytes),
        .stderr_limit = std.Io.Limit.limited(4096),
    });
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);

    if (!result.term.success()) return error.ClipboardUnavailable;
    if (result.stdout.len == 0) return error.NoClipboardData;
    return result.stdout;
}

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "clipboard write then read round-trips the default text" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };
    const state: *ClipboardState = @ptrCast(@alignCast(module.context));

    try std.testing.expect(state.text == null);
    try std.testing.expect(state.last_read == null);

    try module.hooks.start_fn.?(module.context, runtime);
    // Empty payload → plugin uses `default_text`.
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

test "clipboard write honours an explicit payload" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };
    const state: *ClipboardState = @ptrCast(@alignCast(module.context));

    try module.hooks.start_fn.?(module.context, runtime);
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "clipboard.write_text",
        .payload = "typed by the caller",
    });
    try std.testing.expectEqualStrings("typed by the caller", state.text.?);

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

test "native clipboard helpers report FileNotFound for missing utilities" {
    const allocator = std.testing.allocator;
    var io_thread = std.Io.Threaded.init(allocator, .{});
    defer io_thread.deinit();
    const io = io_thread.io();

    const missing_write = &.{
        "zero-native-missing-clipboard-utility-xyz",
    };
    try std.testing.expectError(
        error.FileNotFound,
        spawnWriteClipboard(io, missing_write, "hello"),
    );

    const missing_read = &.{
        "zero-native-missing-clipboard-utility-abc",
    };
    try std.testing.expectError(
        error.FileNotFound,
        runReadClipboard(io, allocator, missing_read),
    );
}
