//! Auto-updater plugin — fetches and applies update manifests.
//!
//! Commands:
//! - `updater.check` — parses payload as manifest JSON, compares versions.
//! - `updater.download` — stub; requires a real HTTP update server.
//! - `updater.install` — stub; requires a real binary update archive.
//!
//! In production, `updater.check` fetches the manifest from
//! `state.manifest_url` via `http_client.request`. For testing, the
//! manifest JSON is passed directly in the command payload.
//!
//! `updater.download` and `updater.install` are documented stubs that
//! require a live update server. They record `downloaded` / `installed`
//! as `false` and leave `archive_path` / `staging_path` null until
//! full network and filesystem integration is wired up.

const std = @import("std");
const extensions = @import("root.zig");
const update_manifest = @import("update_manifest");

/// Unique module id for the updater plugin.
pub const ModuleId: extensions.ModuleId = 108;

/// Module name used in `ModuleInfo`.
pub const module_name: []const u8 = "updater";

/// Capabilities advertised by this module.
pub const capabilities: []const extensions.Capability = &.{
    .{ .kind = .custom, .name = "updater" },
};

/// Routing head for update commands.
pub const cmd_check: []const u8 = "updater.check";
pub const cmd_download: []const u8 = "updater.download";
pub const cmd_install: []const u8 = "updater.install";

/// Mutable state owned by an updater module instance.
pub const UpdaterState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    current_version: []const u8,
    manifest_url: []const u8,
    public_key: ?[32]u8,
    update_available: bool = false,
    manifest: ?update_manifest.Manifest = null,
    downloaded: bool = false,
    archive_path: ?[]u8 = null,
    installed: bool = false,
    staging_path: ?[]u8 = null,
};

// ---------------------------------------------------------------------------
// Lifecycle hooks
// ---------------------------------------------------------------------------

/// No-op startup — all state is set up during `create`.
pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}

/// Stop hook — frees manifest data, owned strings, and the state itself.
pub fn stop(context: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const state: *UpdaterState = @ptrCast(@alignCast(context));
    const allocator = state.allocator;
    deinitState(state);
    allocator.destroy(state);
}

/// Command hook — routes `updater.check`, `.download`, and `.install`.
pub fn command(
    context: *anyopaque,
    _: extensions.RuntimeContext,
    cmd: extensions.Command,
) anyerror!void {
    const state: *UpdaterState = @ptrCast(@alignCast(context));
    if (std.mem.eql(u8, cmd.name, cmd_check)) {
        handleCheck(state, cmd.payload) catch |err| {
            state.update_available = false;
            return err;
        };
    } else if (std.mem.eql(u8, cmd.name, cmd_download)) {
        // Stub: downloads require a real HTTP update server.
        // The payload would be the target platform key (e.g. "macos-aarch64").
        state.downloaded = false;
        state.archive_path = null;
    } else if (std.mem.eql(u8, cmd.name, cmd_install)) {
        // Stub: install requires a downloaded archive on disk.
        state.installed = false;
        state.staging_path = null;
    }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Parse the manifest from `payload` (raw JSON bytes) and compare its
/// version against `state.current_version`. Records the parsed manifest
/// and the availability flag in state.
fn handleCheck(state: *UpdaterState, payload: []const u8) !void {
    // Free any previously parsed manifest.
    if (state.manifest) |*prev| {
        update_manifest.deinitManifest(prev, state.allocator);
    }
    state.manifest = null;

    const manifest = try update_manifest.parseManifest(state.allocator, payload);
    state.manifest = manifest;

    const current = try update_manifest.parseVersion(state.current_version);
    const order = update_manifest.compareVersion(manifest.version, current);
    state.update_available = order == .gt;
}

/// Release all owned strings and manifest data from the state.
fn deinitState(state: *UpdaterState) void {
    if (state.manifest) |*m| {
        update_manifest.deinitManifest(m, state.allocator);
    }
    state.allocator.free(state.current_version);
    state.allocator.free(state.manifest_url);
    if (state.archive_path) |p| state.allocator.free(p);
    if (state.staging_path) |p| state.allocator.free(p);
    state.* = undefined;
}

/// Decode a base64-encoded Ed25519 public key into 32 raw bytes.
/// Returns null if the input is empty, or an error if decoding fails.
fn decodePublicKey(b64: []const u8) ![32]u8 {
    if (b64.len == 0) return error.EmptyKey;
    const key_len = try std.base64.standard.Decoder.calcSizeForSlice(b64);
    if (key_len != 32) return error.InvalidKey;
    var key_bytes: [32]u8 = undefined;
    try std.base64.standard.Decoder.decode(&key_bytes, b64);
    return key_bytes;
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

/// Allocate and initialise an `UpdaterState`, wrapping it in a `Module`.
///
/// `public_key_b64` may be empty to skip signature verification.
/// The caller is responsible for invoking `start` and `stop`.
pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    current_version: []const u8,
    manifest_url: []const u8,
    public_key_b64: []const u8,
) !extensions.Module {
    const state = try allocator.create(UpdaterState);
    errdefer allocator.destroy(state);

    const pk: ?[32]u8 = if (public_key_b64.len > 0)
        try decodePublicKey(public_key_b64)
    else
        null;

    state.* = .{
        .allocator = allocator,
        .io = io,
        .current_version = try allocator.dupe(u8, current_version),
        .manifest_url = try allocator.dupe(u8, manifest_url),
        .public_key = pk,
        .update_available = false,
        .manifest = null,
        .downloaded = false,
        .archive_path = null,
        .installed = false,
        .staging_path = null,
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

test "updater: check detects update available" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const module = try create(allocator, io, "0.1.0", "http://localhost/manifest.json", "");
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    try module.hooks.start_fn.?(module.context, runtime);

    // Pass a manifest with version 1.0.0 as the payload.
    const manifest_json =
        \\{"version":"1.0.0","notes":"major update","platforms":{}}
    ;
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "updater.check",
        .payload = manifest_json,
    });

    const state: *UpdaterState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(state.update_available);
    try std.testing.expect(state.manifest != null);
    try std.testing.expectEqual(@as(u32, 1), state.manifest.?.version.major);

    try module.hooks.stop_fn.?(module.context, runtime);
}

test "updater: check detects same version as no update" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const module = try create(allocator, io, "1.0.0", "http://localhost/manifest.json", "");
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    try module.hooks.start_fn.?(module.context, runtime);

    const manifest_json =
        \\{"version":"1.0.0","notes":"same","platforms":{}}
    ;
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "updater.check",
        .payload = manifest_json,
    });

    const state: *UpdaterState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(!state.update_available);

    try module.hooks.stop_fn.?(module.context, runtime);
}

test "updater: check detects downgrade as no update" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const module = try create(allocator, io, "2.0.0", "http://localhost/manifest.json", "");
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    try module.hooks.start_fn.?(module.context, runtime);

    const manifest_json =
        \\{"version":"1.0.0","notes":"downgrade","platforms":{}}
    ;
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "updater.check",
        .payload = manifest_json,
    });

    const state: *UpdaterState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(!state.update_available);

    try module.hooks.stop_fn.?(module.context, runtime);
}

test "updater: start and stop clean up" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const module = try create(allocator, io, "0.1.0", "http://localhost/manifest.json", "");
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    try module.hooks.start_fn.?(module.context, runtime);
    try module.hooks.stop_fn.?(module.context, runtime);
    // std.testing.allocator will detect leaks.
}

test "updater: registry integration" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var module = try create(allocator, io, "0.1.0", "http://localhost/manifest.json", "");
    const modules = [_]extensions.Module{module};
    const registry = extensions.ModuleRegistry{ .modules = &modules };
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    try registry.validate();
    try std.testing.expect(registry.hasCapability(.custom));

    try registry.startAll(runtime);

    const manifest_json =
        \\{"version":"1.0.0","notes":"reg test","platforms":{}}
    ;
    try registry.dispatchCommand(runtime, .{
        .name = "updater.check",
        .payload = manifest_json,
    });

    {
        const state: *UpdaterState = @ptrCast(@alignCast(module.context));
        try std.testing.expect(state.update_available);
    }

    try registry.stopAll(runtime);
    module.context = undefined;
}

test "updater: download and install are stubs" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const module = try create(allocator, io, "0.1.0", "http://localhost/manifest.json", "");
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    try module.hooks.start_fn.?(module.context, runtime);

    // download stub
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "updater.download",
        .payload = "macos-aarch64",
    });
    {
        const state: *UpdaterState = @ptrCast(@alignCast(module.context));
        try std.testing.expect(!state.downloaded);
        try std.testing.expect(state.archive_path == null);
    }

    // install stub
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "updater.install",
    });
    {
        const state: *UpdaterState = @ptrCast(@alignCast(module.context));
        try std.testing.expect(!state.installed);
        try std.testing.expect(state.staging_path == null);
    }

    try module.hooks.stop_fn.?(module.context, runtime);
}

test "updater: public key decoding" {
    const kp = std.crypto.sign.Ed25519.KeyPair.generate(std.testing.io);
    var b64_buf: [64]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &kp.public_key.bytes);

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const module = try create(allocator, io, "0.1.0", "http://localhost/manifest.json", b64);
    defer {
        const state: *UpdaterState = @ptrCast(@alignCast(module.context));
        deinitState(state);
        allocator.destroy(state);
    }

    const state: *UpdaterState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(state.public_key != null);
    try std.testing.expectEqual(kp.public_key.bytes, state.public_key.?);
}
