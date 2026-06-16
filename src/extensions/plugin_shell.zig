//! Shell plugin module — spawns child processes via `std.process.spawn`.
//!
//! Commands are routed by `cmd.name` only; the argv for `shell.execute`
//! lives in `cmd.payload` as a `|`-separated list (e.g. `"sh|-c|true"`).
//! When `cmd.payload` is empty the plugin falls back to the safe default
//! `["true"]` so the test suite always exercises a real spawn. The
//! `command_fn` hands the parsed argv to `std.process.spawn`, waits for
//! the child, and records the exit code into `state.last_exit_code` so
//! tests can inspect the outcome. Spawn failures, non-exit terminations,
//! and malformed payloads are all reported as
//! `spawn_failure_exit_code` (currently `-1`).

const std = @import("std");
const extensions = @import("root.zig");

/// Unique module id for the shell plugin.
pub const ModuleId: extensions.ModuleId = 101;

/// Module name used in `ModuleInfo`.
pub const module_name: []const u8 = "shell";

/// Capabilities advertised by this module.
pub const capabilities: []const extensions.Capability = &.{
    .{ .kind = .custom, .name = "shell" },
};

/// Routing head matched against `cmd.name` for the execute command.
pub const cmd_execute: []const u8 = "shell.execute";

/// Maximum number of argv parts accepted in a single `shell.execute` payload.
/// Commands that exceed this limit are recorded as `spawn_failure_exit_code`
/// rather than silently truncating the argv.
pub const max_argv: usize = 32;

/// Default argv used when the caller dispatches `shell.execute` with an empty
/// `cmd.payload`. `/usr/bin/true` always exits 0 and is universally available
/// on the platforms zero-native targets, so the test suite can exercise the
/// spawn path without crafting a custom command.
pub const default_argv: []const []const u8 = &.{"true"};

/// Sentinel exit code recorded when `std.process.spawn` fails, the child is
/// terminated by a signal, or the parsed argv is empty or oversized.
pub const spawn_failure_exit_code: i32 = -1;

/// Mutable state owned by a shell module instance.
///
/// `io_thread` is a `std.Io.Threaded` instance whose allocator is wired to
/// `allocator`; `std.process.spawn` needs the Io's allocator to format the
/// internal argv buffer, and the global single-threaded instance defaults to
/// `.failing`, so each plugin owns a fresh `Threaded` initialised with its
/// own allocator.
pub const ShellState = struct {
    last_exit_code: i32 = 0,
    io_thread: std.Io.Threaded,
    allocator: std.mem.Allocator,
};

// ---------------------------------------------------------------------------
// Lifecycle hooks
// ---------------------------------------------------------------------------

/// No-op startup hook. The shell plugin holds no external resources to
/// acquire before it can begin accepting commands — `io_thread` is wired up
/// during `create`.
pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}

/// Stop hook — tears down the owned `Threaded` instance and frees the state.
/// Mirrors `create`'s allocator exactly. Safe to call only once per `create`.
pub fn stop(context: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const state: *ShellState = @ptrCast(@alignCast(context));
    const allocator = state.allocator;
    state.io_thread.deinit();
    allocator.destroy(state);
}

/// Command hook — routes `shell.execute` calls to `executeCommand`.
///
/// The argv is read from `cmd.payload` as a `|`-separated list. An empty
/// payload falls back to `default_argv` (`["true"]`) so test code can
/// exercise the spawn path without supplying explicit arguments.
pub fn command(
    context: *anyopaque,
    _: extensions.RuntimeContext,
    cmd: extensions.Command,
) anyerror!void {
    const state: *ShellState = @ptrCast(@alignCast(context));
    if (std.mem.eql(u8, cmd.name, cmd_execute)) {
        state.last_exit_code = executeCommand(state.io_thread.io(), cmd.payload);
    }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Spawn the child described by `payload` (pipe-separated argv) and return
/// its exit code, or `spawn_failure_exit_code` on any failure path. An empty
/// payload falls back to `default_argv` (`["true"]`). Stdout and stderr are
/// routed to the null device so test output stays clean.
fn executeCommand(io: std.Io, payload: []const u8) i32 {
    if (payload.len == 0) return runArgv(io, default_argv);

    var argv_storage: [max_argv][]const u8 = undefined;
    var argv_len: usize = 0;
    var iter = std.mem.splitScalar(u8, payload, '|');
    while (iter.next()) |part| {
        if (argv_len >= argv_storage.len) return spawn_failure_exit_code;
        argv_storage[argv_len] = part;
        argv_len += 1;
    }
    if (argv_len == 0) return runArgv(io, default_argv);

    return runArgv(io, argv_storage[0..argv_len]);
}

/// Spawn `argv` and return the child's exit code, or `spawn_failure_exit_code`
/// on any failure path.
fn runArgv(io: std.Io, argv: []const []const u8) i32 {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return spawn_failure_exit_code;

    const term = child.wait(io) catch return spawn_failure_exit_code;
    return switch (term) {
        .exited => |code| @intCast(code),
        else => spawn_failure_exit_code,
    };
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

/// Allocate a `ShellState` and wrap it in a `Module`. The caller is
/// responsible for invoking `start` and `stop`; failure to call `stop` will
/// leak the `Threaded` instance and the state itself.
pub fn create(allocator: std.mem.Allocator) !extensions.Module {
    const state = try allocator.create(ShellState);
    errdefer allocator.destroy(state);

    state.* = .{
        .last_exit_code = 0,
        .io_thread = std.Io.Threaded.init(allocator, .{}),
        .allocator = allocator,
    };

    return .{
        .info = .{
            .id = ModuleId,
            .name = module_name,
            .capabilities = capabilities,
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

test "shell execute records exit code 0 for a successful child" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    try module.hooks.start_fn.?(module.context, runtime);
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "shell.execute",
        .payload = "sh|-c|true",
    });

    const state: *ShellState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqual(@as(i32, 0), state.last_exit_code);

    try module.hooks.stop_fn.?(module.context, runtime);
}

test "shell execute records a non-zero exit code from the child" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    try module.hooks.start_fn.?(module.context, runtime);
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "shell.execute",
        .payload = "sh|-c|exit 7",
    });

    const state: *ShellState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqual(@as(i32, 7), state.last_exit_code);

    try module.hooks.stop_fn.?(module.context, runtime);
}

test "shell execute records spawn_failure_exit_code for an unknown command" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    try module.hooks.start_fn.?(module.context, runtime);
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "shell.execute",
        .payload = "/zero-native-shell-no-such-binary-xyz123",
    });

    const state: *ShellState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqual(spawn_failure_exit_code, state.last_exit_code);

    try module.hooks.stop_fn.?(module.context, runtime);
}

test "shell execute uses default_argv when payload is empty" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    try module.hooks.start_fn.?(module.context, runtime);
    // Empty payload → plugin falls back to `default_argv` ("true"), which
    // always exits 0. This keeps the spawn path covered by smoke tests
    // even when callers do not supply an explicit payload.
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "shell.execute",
    });

    const state: *ShellState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqual(@as(i32, 0), state.last_exit_code);

    try module.hooks.stop_fn.?(module.context, runtime);
}

test "shell start and stop do not crash" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };
    try module.hooks.start_fn.?(module.context, runtime);
    try module.hooks.stop_fn.?(module.context, runtime);
}

test "shell registers in a ModuleRegistry and dispatches through the registry" {
    const allocator = std.testing.allocator;
    var module = try create(allocator);
    const modules = [_]extensions.Module{module};
    const registry = extensions.ModuleRegistry{ .modules = &modules };
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    try registry.validate();
    try std.testing.expect(registry.hasCapability(.custom));

    try registry.startAll(runtime);
    try registry.dispatchCommand(runtime, .{
        .name = "shell.execute",
        .payload = "sh|-c|true",
    });

    // Inspect the recorded exit code before the registry tears the state down.
    {
        const state: *ShellState = @ptrCast(@alignCast(module.context));
        try std.testing.expectEqual(@as(i32, 0), state.last_exit_code);
    }

    try registry.stopAll(runtime);
    // stop consumed the state; the module handle is invalidated.
    module.context = undefined;
}
