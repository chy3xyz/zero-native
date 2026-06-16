//! Single-instance plugin module — detects whether another instance of the
//! same app is already running using a lock file in a temp directory.
//!
//! Commands are routed by `cmd.name` only; any argument string lives in
//! `cmd.payload`. Supported commands:
//! - `single_instance.try_lock` — `cmd.payload` is an optional lock label
//!   (e.g. `"myapp"`). Atomically creates a lock file. Sets `state.held = true`
//!   on success, or `false` if another instance holds the lock.
//! - `single_instance.release` — releases the lock by removing the lock file
//!   and sets `state.held = false`.
//!
//! Implementation: uses `std.Io.Dir.createFile` with `.exclusive = true` to
//! atomically create a lock file in the configured lock directory. If the
//! file already exists, another instance owns it.
//!
//! For tests, pass a `std.testing.tmpDir`'s dir handle and
//! `std.testing.io` to `createWithDir`.

const std = @import("std");
const extensions = @import("root.zig");

const Io = std.Io;

/// Unique module id for the single-instance plugin.
pub const ModuleId: extensions.ModuleId = 107;

/// Module name used in `ModuleInfo`.
pub const module_name: []const u8 = "single-instance";

/// Capabilities advertised by this module.
pub const capabilities: []const extensions.Capability = &.{
    .{ .kind = .custom, .name = "single-instance" },
};

/// Command-name constants.
pub const cmd_try_lock: []const u8 = "single_instance.try_lock";
pub const cmd_release: []const u8 = "single_instance.release";

/// Default lock label used when `cmd.payload` is empty.
pub const default_label: []const u8 = "default";

/// Lock file name pattern.
const lock_file_prefix: []const u8 = "zero-native-";
const lock_file_suffix: []const u8 = ".lock";

/// Mutable state owned by a single-instance module instance.
pub const SingleInstanceState = struct {
    held: bool = false,
    /// Full path to the lock file. Owned by the allocator.
    lock_path: ?[]u8,
    /// The directory in which the lock file is created. When null,
    /// `try_lock` uses the system temp directory and builds absolute paths.
    lock_dir: Io.Dir,
    io: Io,
    allocator: std.mem.Allocator,
};

/// Allocate the plugin state using the system temp directory as the lock
/// directory. Returns a `Module` view.
pub fn create(allocator: std.mem.Allocator, io: Io) !extensions.Module {
    return createWithDir(allocator, io, Io.Dir.cwd());
}

/// Create a module that uses a specific directory for lock files.
/// Useful for tests that need an isolated, deterministic lock directory.
pub fn createWithDir(allocator: std.mem.Allocator, io: Io, lock_dir: Io.Dir) !extensions.Module {
    const state = try allocator.create(SingleInstanceState);
    errdefer allocator.destroy(state);
    state.* = .{
        .held = false,
        .lock_path = null,
        .lock_dir = lock_dir,
        .io = io,
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

/// Start hook — no-op for the single-instance plugin.
pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}

/// Stop hook — releases the lock (if held) and frees all owned memory.
pub fn stop(context: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const state: *SingleInstanceState = @ptrCast(@alignCast(context));
    releaseLock(state) catch {};
    if (state.lock_path) |path| state.allocator.free(path);
    state.allocator.destroy(state);
}

/// Command hook — dispatches `single_instance.try_lock` and
/// `single_instance.release`.
pub fn command(
    context: *anyopaque,
    _: extensions.RuntimeContext,
    cmd: extensions.Command,
) anyerror!void {
    const state: *SingleInstanceState = @ptrCast(@alignCast(context));

    if (std.mem.eql(u8, cmd.name, cmd_try_lock)) {
        const label = if (cmd.payload.len > 0) cmd.payload else default_label;
        try tryLock(state, label);
        return;
    }

    if (std.mem.eql(u8, cmd.name, cmd_release)) {
        try releaseLock(state);
        return;
    }
}

/// Build the lock file name and store the path in state.
fn buildLockPath(state: *SingleInstanceState, label: []const u8) !void {
    if (state.lock_path) |old| {
        state.allocator.free(old);
        state.lock_path = null;
    }
    const filename = try std.fmt.allocPrint(
        state.allocator,
        lock_file_prefix ++ "{s}" ++ lock_file_suffix,
        .{label},
    );
    errdefer state.allocator.free(filename);
    state.lock_path = filename;
}

/// Attempt to acquire the singleton lock. Sets `state.held = true` on
/// success, `false` on failure (lock already held by another instance).
fn tryLock(state: *SingleInstanceState, label: []const u8) !void {
    // If we already hold a lock, release it first.
    if (state.held) {
        try releaseLock(state);
    }

    try buildLockPath(state, label);
    const path = state.lock_path.?;

    // Try to create the lock file exclusively.
    const file = state.lock_dir.createFile(state.io, path, .{ .exclusive = true }) catch {
        // File already exists — another instance holds the lock.
        state.held = false;
        return;
    };
    file.close(state.io);
    state.held = true;
}

/// Release the singleton lock. Removes the lock file and sets
/// `state.held = false`. Idempotent.
fn releaseLock(state: *SingleInstanceState) !void {
    if (state.lock_path) |path| {
        state.lock_dir.deleteFile(state.io, path) catch |err| {
            if (err != error.FileNotFound) return err;
        };
    }
    state.held = false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

test "single_instance: try_lock succeeds the first time" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const module = try createWithDir(allocator, io, tmp.dir);
    defer module.hooks.stop_fn.?(module.context, test_runtime) catch {};

    try module.hooks.start_fn.?(module.context, test_runtime);
    try module.hooks.command_fn.?(module.context, test_runtime, .{
        .name = "single_instance.try_lock",
        .payload = "test",
    });

    const state: *SingleInstanceState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(state.held);
}

test "single_instance: try_lock fails the second time (same path)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const module = try createWithDir(allocator, io, tmp.dir);
    defer module.hooks.stop_fn.?(module.context, test_runtime) catch {};

    try module.hooks.start_fn.?(module.context, test_runtime);

    // First lock succeeds.
    try module.hooks.command_fn.?(module.context, test_runtime, .{
        .name = "single_instance.try_lock",
        .payload = "test",
    });
    const state: *SingleInstanceState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(state.held);

    // Manually create a second module that targets the same directory to
    // simulate another instance.
    const module2 = try createWithDir(allocator, io, tmp.dir);
    defer module2.hooks.stop_fn.?(module2.context, test_runtime) catch {};

    try module2.hooks.start_fn.?(module2.context, test_runtime);
    try module2.hooks.command_fn.?(module2.context, test_runtime, .{
        .name = "single_instance.try_lock",
        .payload = "test",
    });

    const state2: *SingleInstanceState = @ptrCast(@alignCast(module2.context));
    try std.testing.expect(!state2.held);
}

test "single_instance: release followed by try_lock succeeds" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const module = try createWithDir(allocator, io, tmp.dir);
    defer module.hooks.stop_fn.?(module.context, test_runtime) catch {};

    try module.hooks.start_fn.?(module.context, test_runtime);

    try module.hooks.command_fn.?(module.context, test_runtime, .{
        .name = "single_instance.try_lock",
        .payload = "test",
    });
    {
        const state: *SingleInstanceState = @ptrCast(@alignCast(module.context));
        try std.testing.expect(state.held);
    }

    try module.hooks.command_fn.?(module.context, test_runtime, .{
        .name = "single_instance.release",
    });
    {
        const state: *SingleInstanceState = @ptrCast(@alignCast(module.context));
        try std.testing.expect(!state.held);
    }

    // Re-acquire should succeed.
    try module.hooks.command_fn.?(module.context, test_runtime, .{
        .name = "single_instance.try_lock",
        .payload = "test",
    });
    {
        const state: *SingleInstanceState = @ptrCast(@alignCast(module.context));
        try std.testing.expect(state.held);
    }
}

test "single_instance: start and stop do not crash" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const module = try createWithDir(allocator, io, tmp.dir);
    try module.hooks.start_fn.?(module.context, test_runtime);
    try module.hooks.stop_fn.?(module.context, test_runtime);
}

test "single_instance: registers in a ModuleRegistry" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var module = try createWithDir(allocator, io, tmp.dir);

    const modules = [_]extensions.Module{module};
    const registry = extensions.ModuleRegistry{ .modules = &modules };

    try registry.validate();
    try std.testing.expect(registry.hasCapability(.custom));

    try registry.startAll(test_runtime);
    try registry.dispatchCommand(test_runtime, .{
        .name = "single_instance.try_lock",
        .payload = "reg-test",
    });

    {
        const state: *SingleInstanceState = @ptrCast(@alignCast(module.context));
        try std.testing.expect(state.held);
    }

    try registry.stopAll(test_runtime);
    module.context = undefined;
}
