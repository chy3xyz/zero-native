//! Shell plugin module — spawns child processes via `std.process.spawn`.
//!
//! The extension `Command` struct only carries a routing name and an optional
//! target module id, so the argv for `shell.execute` is encoded directly in
//! `cmd.name` after a single space, e.g. `"shell.execute sh|-c|true"`. The
//! `command_fn` splits the payload on `|` to obtain the argv, hands it to
//! `std.process.spawn`, waits for the child, and records the exit code into
//! `state.last_exit_code` so tests can inspect the outcome. Spawn failures,
//! non-exit terminations, and malformed payloads are all reported as
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
/// The argv is encoded after a single space in `cmd.name`, so the recognised
/// prefix is `"shell.execute "`. Anything else is silently ignored.
pub fn command(
    context: *anyopaque,
    _: extensions.RuntimeContext,
    cmd: extensions.Command,
) anyerror!void {
    const state: *ShellState = @ptrCast(@alignCast(context));
    if (std.mem.startsWith(u8, cmd.name, cmd_execute)) {
        const tail = cmd.name[cmd_execute.len..];
        // Tolerate a missing or extra space between the head and the argv.
        const payload = std.mem.trimStart(u8, tail, " ");
        state.last_exit_code = executeCommand(state.io_thread.io(), payload);
    }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Spawn the child described by `payload` (pipe-separated argv) and return
/// its exit code, or `spawn_failure_exit_code` on any failure path. Stdout
/// and stderr are routed to the null device so test output stays clean.
fn executeCommand(io: std.Io, payload: []const u8) i32 {
    if (payload.len == 0) return spawn_failure_exit_code;

    var argv_storage: [max_argv][]const u8 = undefined;
    var argv_len: usize = 0;
    var iter = std.mem.splitScalar(u8, payload, '|');
    while (iter.next()) |part| {
        if (argv_len >= argv_storage.len) return spawn_failure_exit_code;
        argv_storage[argv_len] = part;
        argv_len += 1;
    }
    if (argv_len == 0) return spawn_failure_exit_code;

    var child = std.process.spawn(io, .{
        .argv = argv_storage[0..argv_len],
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
        .name = "shell.execute sh|-c|true",
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
        .name = "shell.execute sh|-c|exit 7",
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
        .name = "shell.execute /zero-native-shell-no-such-binary-xyz123",
    });

    const state: *ShellState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqual(spawn_failure_exit_code, state.last_exit_code);

    try module.hooks.stop_fn.?(module.context, runtime);
}

test "shell execute tolerates multiple space characters before the payload" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    try module.hooks.start_fn.?(module.context, runtime);
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "shell.execute    sh|-c|true",
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
        .name = "shell.execute sh|-c|true",
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
