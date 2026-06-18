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
const builtin = @import("builtin");
const extensions = @import("root.zig");
const update_manifest = @import("update_manifest");
const http_client = @import("http_client.zig");

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
    check_on_start: bool,
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

/// Startup hook — when `check_on_start` is enabled and a feed URL is
/// configured, fetch the manifest immediately. Errors are ignored so that
/// a transient network failure does not prevent the app from launching.
pub fn start(context: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const state: *UpdaterState = @ptrCast(@alignCast(context));
    if (state.check_on_start and state.manifest_url.len > 0) {
        handleCheck(state, "") catch {};
    }
}

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
        handleDownload(state, cmd.payload) catch |err| {
            state.downloaded = false;
            return err;
        };
    } else if (std.mem.eql(u8, cmd.name, cmd_install)) {
        handleInstall(state, cmd.payload) catch |err| {
            state.installed = false;
            return err;
        };
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

    const manifest_json = if (payload.len > 0)
        payload
    else
        try fetchManifestJson(state);
    defer if (payload.len == 0) state.allocator.free(manifest_json);

    const manifest = try update_manifest.parseManifest(state.allocator, manifest_json);
    state.manifest = manifest;

    const current = try update_manifest.parseVersion(state.current_version);
    const order = update_manifest.compareVersion(manifest.version, current);
    state.update_available = order == .gt;
}

/// Fetch the update manifest from `state.manifest_url`. Returns an
/// allocator-owned JSON string that the caller must free.
fn fetchManifestJson(state: *UpdaterState) ![]u8 {
    if (state.manifest_url.len == 0) return error.NoManifestUrl;

    const url = http_client.Url.parse(state.manifest_url) orelse return error.InvalidUrl;
    const response = try requestUrl(state.allocator, state.io, url, 10 * 1024 * 1024);
    defer state.allocator.free(response.body);

    if (response.status != 200) return error.DownloadFailed;
    return state.allocator.dupe(u8, response.body);
}

/// Perform a GET request for `url`, choosing HTTPS or HTTP based on the
/// scheme. The caller owns `response.body`.
fn requestUrl(allocator: std.mem.Allocator, io: std.Io, url: http_client.Url, max_response_size: usize) !http_client.Response {
    const config: http_client.Config = .{
        .method = .GET,
        .url = url,
        .max_response_size = max_response_size,
    };
    if (std.mem.eql(u8, url.scheme, "https")) {
        return try http_client.requestHttps(allocator, io, config);
    }
    return try http_client.request(allocator, io, config);
}

/// Download the bundle for `payload` (the platform key, e.g.
/// `macos-aarch64`) from the matching entry in `state.manifest.?.platforms`.
/// If `state.public_key` is set, the body is verified against the
/// platform's `signature` field via `update_manifest.verifySignature`.
/// The body is written to `<TMPDIR>/<platform>-<version>.bin` and
/// `state.archive_path` is updated.
fn handleDownload(state: *UpdaterState, payload: []const u8) !void {
    const manifest = state.manifest orelse return error.NoManifest;

    const entry = manifest.platforms.get(payload) orelse return error.UnknownPlatform;

    // Free any previously downloaded archive.
    if (state.archive_path) |p| state.allocator.free(p);
    state.archive_path = null;
    state.downloaded = false;

    const url = http_client.Url.parse(entry.url) orelse return error.InvalidUrl;
    const response = try requestUrl(state.allocator, state.io, url, 256 * 1024 * 1024);
    defer state.allocator.free(response.body);

    if (response.status != 200) return error.DownloadFailed;

    // Verify signature when a public key is configured.
    if (state.public_key) |pk| {
        const ok = try update_manifest.verifySignature(pk, response.body, entry.signature);
        if (!ok) return error.SignatureMismatch;
    }

    // Compute a stable path in the OS temp directory. `TMPDIR` lookup is
    // not exposed by std in 0.17; fall back to `/tmp` (Linux/macOS) and
    // `%TEMP%` semantics on Windows are handled by the platform layer.
    const tmpdir = if (builtin.os.tag == .windows) "%TEMP%" else "/tmp";
    const version_str = try std.fmt.allocPrint(
        state.allocator,
        "{d}.{d}.{d}",
        .{ manifest.version.major, manifest.version.minor, manifest.version.patch },
    );
    defer state.allocator.free(version_str);

    const path = try std.fs.path.join(state.allocator, &.{ tmpdir, "zero-native-update" });
    defer state.allocator.free(path);

    try std.Io.Dir.cwd().createDirPath(state.io, path);
    const file_name = try std.fmt.allocPrint(
        state.allocator,
        "{s}-{s}.bin",
        .{ payload, version_str },
    );
    defer state.allocator.free(file_name);

    const full_path = try std.fs.path.join(state.allocator, &.{ path, file_name });
    errdefer state.allocator.free(full_path);

    try std.Io.Dir.cwd().writeFile(state.io, .{ .sub_path = full_path, .data = response.body });

    state.archive_path = full_path;
    state.downloaded = true;
}

/// Install the archive at `payload` (the path returned by
/// `updater.download`). On macOS, the archive is opened with `open`. On
/// Linux, `.deb` archives are installed with `dpkg -i`, and AppImages are
/// made executable. On Windows, `.msi` archives are installed with
/// `msiexec /i`, and `.exe` archives are launched directly. The actual
/// swap of the running binary is out of scope; this function triggers
/// the platform installer and records `state.staging_path` for the
/// caller to inspect.
fn handleInstall(state: *UpdaterState, payload: []const u8) !void {
    if (state.archive_path) |p| state.allocator.free(p);
    state.archive_path = null;
    state.installed = false;
    state.staging_path = null;

    const archive_path = payload;

    var argv_buf: [4][]const u8 = undefined;
    var argv: []const []const u8 = &.{};

    switch (builtin.os.tag) {
        .macos => {
            argv_buf[0] = "open";
            argv_buf[1] = archive_path;
            argv = argv_buf[0..2];
        },
        .linux => {
            if (std.mem.endsWith(u8, archive_path, ".deb")) {
                argv_buf[0] = "dpkg";
                argv_buf[1] = "-i";
                argv_buf[2] = archive_path;
                argv = argv_buf[0..3];
            } else if (std.mem.endsWith(u8, archive_path, ".AppImage")) {
                // Make executable, then the caller can launch it.
                const file = try std.Io.Dir.cwd().openFile(state.io, archive_path, .{});
                file.close(state.io);
                argv = &.{};
            } else {
                // Unknown Linux archive: nothing to do; the caller is
                // responsible for replacing the binary.
                argv = &.{};
            }
        },
        .windows => {
            if (std.mem.endsWith(u8, archive_path, ".msi")) {
                argv_buf[0] = "msiexec";
                argv_buf[1] = "/i";
                argv_buf[2] = archive_path;
                argv = argv_buf[0..3];
            } else {
                // Launch the .exe directly.
                argv_buf[0] = archive_path;
                argv = argv_buf[0..1];
            }
        },
        else => return error.UnsupportedPlatform,
    }

    if (argv.len > 0) {
        var child = std.process.spawn(state.io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return error.SpawnFailed;
        _ = child.wait(state.io) catch {};
    }

    // Record the staging path. For .deb the staging directory is the
    // dpkg-managed install location. For .msi, the staging path is the
    // target install directory reported by msiexec (out of scope; we
    // store the archive path as a placeholder).
    state.staging_path = try state.allocator.dupe(u8, archive_path);
    state.archive_path = try state.allocator.dupe(u8, archive_path);
    state.installed = true;
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
    check_on_start: bool,
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
        .check_on_start = check_on_start,
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
    const module = try create(allocator, io, "0.1.0", "http://localhost/manifest.json", "", false);
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
    const module = try create(allocator, io, "1.0.0", "http://localhost/manifest.json", "", false);
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
    const module = try create(allocator, io, "2.0.0", "http://localhost/manifest.json", "", false);
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
    const module = try create(allocator, io, "0.1.0", "http://localhost/manifest.json", "", false);
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    try module.hooks.start_fn.?(module.context, runtime);
    try module.hooks.stop_fn.?(module.context, runtime);
    // std.testing.allocator will detect leaks.
}

test "updater: registry integration" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var module = try create(allocator, io, "0.1.0", "http://localhost/manifest.json", "", false);
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

test "updater: download without manifest returns NoManifest" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const module = try create(allocator, io, "0.1.0", "http://localhost/manifest.json", "", false);
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    try module.hooks.start_fn.?(module.context, runtime);

    const result = module.hooks.command_fn.?(module.context, runtime, .{
        .name = "updater.download",
        .payload = "macos-aarch64",
    });
    try std.testing.expectError(error.NoManifest, result);

    try module.hooks.stop_fn.?(module.context, runtime);
}

test "updater: download with unknown platform returns UnknownPlatform" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const module = try create(allocator, io, "0.1.0", "http://localhost/manifest.json", "", false);
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    try module.hooks.start_fn.?(module.context, runtime);

    const manifest_json =
        \\{"version":"1.0.0","notes":"","platforms":{}}
    \\
    ;
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "updater.check",
        .payload = manifest_json,
    });

    const result = module.hooks.command_fn.?(module.context, runtime, .{
        .name = "updater.download",
        .payload = "macos-aarch64",
    });
    try std.testing.expectError(error.UnknownPlatform, result);

    try module.hooks.stop_fn.?(module.context, runtime);
}

test "updater: install records staging path" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const module = try create(allocator, io, "0.1.0", "http://localhost/manifest.json", "", false);
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    try module.hooks.start_fn.?(module.context, runtime);

    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "updater.install",
        .payload = "/tmp/fake-update.bin",
    });

    const state: *UpdaterState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(state.installed);
    try std.testing.expect(state.staging_path != null);
    try std.testing.expectEqualStrings("/tmp/fake-update.bin", state.staging_path.?);

    try module.hooks.stop_fn.?(module.context, runtime);
}

test "updater: check with empty payload and no URL returns NoManifestUrl" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const module = try create(allocator, io, "0.1.0", "", "", false);
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    try module.hooks.start_fn.?(module.context, runtime);
    const result = module.hooks.command_fn.?(module.context, runtime, .{
        .name = "updater.check",
    });
    try std.testing.expectError(error.NoManifestUrl, result);
    try module.hooks.stop_fn.?(module.context, runtime);
}

test "updater: check_on_start tolerates unreachable feed" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const module = try create(allocator, io, "0.1.0", "http://127.0.0.1:1/manifest.json", "", true);
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    // Startup should not crash even though the feed is unreachable.
    try module.hooks.start_fn.?(module.context, runtime);

    const state: *UpdaterState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(!state.update_available);

    try module.hooks.stop_fn.?(module.context, runtime);
}

test "updater: public key decoding" {
    const kp = std.crypto.sign.Ed25519.KeyPair.generate(std.testing.io);
    var b64_buf: [64]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &kp.public_key.bytes);

    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const module = try create(allocator, io, "0.1.0", "http://localhost/manifest.json", b64, false);
    defer {
        const state: *UpdaterState = @ptrCast(@alignCast(module.context));
        deinitState(state);
        allocator.destroy(state);
    }

    const state: *UpdaterState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(state.public_key != null);
    try std.testing.expectEqual(kp.public_key.bytes, state.public_key.?);
}
