//! HTTP plugin module — executes real HTTP/1.1 requests via a vendored
//! client.
//!
//! Commands are routed by `cmd.name` only; any argument string lives in
//! `cmd.payload`. Supported commands:
//! - `http.fetch` — `cmd.payload` is `"METHOD URL"` (split on the first
//!   ASCII space). With no space, the call is silently rejected (the
//!   previously recorded method/url are left untouched). For `http://`
//!   URLs, a real TCP request is made via the vendored client. For
//!   `https://` URLs, `http_client.requestHttps` is called; if httpz is
//!   not linked it returns `error.HttpsNotSupported` and the plugin
//!   falls back to record-only mode.
//! - `http.clear` — clears the recorded method/url/status/body.
//!
//! The extension `Command` has no return channel, so tests inspect the
//! state fields directly after dispatching a command.

const std = @import("std");
const extensions = @import("root.zig");
const http_client = @import("http_client.zig");

/// Unique module id for the http plugin. The shell plugin uses 101, so we
/// pick from the remaining {103, 104} slots reserved for the W8 plugins.
pub const ModuleId: extensions.ModuleId = 103;

/// Module name used in `ModuleInfo`.
pub const module_name: []const u8 = "http";

/// Capabilities advertised by this module.
pub const capabilities: []const extensions.Capability = &.{
    .{ .kind = .network, .name = "http" },
};

/// Routing head matched against `cmd.name` for the fetch command.
pub const cmd_fetch: []const u8 = "http.fetch";

/// Routing head matched against `cmd.name` for the clear command.
pub const cmd_clear: []const u8 = "http.clear";

/// Mutable state owned by a http module instance.
///
/// `last_method` and `last_url` are allocator-owned slices duplicated from
/// the most recent `http.fetch` payload; both are freed by `stop` (and by
/// subsequent `http.fetch` / `http.clear` calls). `last_body` holds the
/// response body from the most recent real HTTP request and is freed
/// similarly. `last_status` reflects the HTTP status code.
pub const HttpState = struct {
    last_method: ?[]u8,
    last_url: ?[]u8,
    last_body: ?[]u8,
    last_status: u16 = 0,
    allocator: std.mem.Allocator,
    io: std.Io,
};

// ---------------------------------------------------------------------------
// Lifecycle hooks
// ---------------------------------------------------------------------------

/// No-op startup hook. The http plugin holds no external resources to
/// acquire before it can begin accepting commands.
pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}

/// Stop hook — frees the recorded method/url/body strings and destroys the
/// state. Mirrors `create`'s allocator exactly. Safe to call only once
/// per `create`; subsequent calls would double-free.
pub fn stop(context: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const state: *HttpState = @ptrCast(@alignCast(context));
    if (state.last_method) |method| state.allocator.free(method);
    if (state.last_url) |url| state.allocator.free(url);
    if (state.last_body) |body| state.allocator.free(body);
    state.allocator.destroy(state);
}

/// Command hook — routes `http.fetch` and `http.clear` to their handlers.
///
/// Recognised forms:
/// - `"http.fetch"` with `cmd.payload = "METHOD URL"` (split on first space).
/// - `"http.clear"` with no payload.
///
/// Any other command is silently ignored, matching the convention used by
/// the other W8 plugins.
pub fn command(
    context: *anyopaque,
    _: extensions.RuntimeContext,
    cmd: extensions.Command,
) anyerror!void {
    const state: *HttpState = @ptrCast(@alignCast(context));

    if (std.mem.eql(u8, cmd.name, cmd_fetch)) {
        try handleFetch(state, cmd.payload);
        return;
    }

    if (std.mem.eql(u8, cmd.name, cmd_clear)) {
        clearState(state);
        return;
    }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Stores the parsed method and URL into `state`. Splits the payload on
/// the first ASCII space; payloads with no separator are rejected silently
/// (leaving prior state untouched).
///
/// For `http://` URLs, a real TCP request is issued via the vendored
/// http_client. For `https://` URLs, `http_client.requestHttps` is
/// called; if httpz is unavailable it returns `HttpsNotSupported` and the
/// plugin falls back to record-only mode. For any other scheme, the
/// plugin falls back to record-only mode.
///
/// If the HTTP request succeeds, `last_status` and `last_body` are
/// updated. If it fails, the method/url are still recorded but
/// `last_status` remains 0 and any previous body is freed.
fn handleFetch(state: *HttpState, payload: []const u8) !void {
    const separator = std.mem.indexOfScalar(u8, payload, ' ') orelse return;
    const raw_method = payload[0..separator];
    const raw_url = payload[separator + 1 ..];
    if (raw_method.len == 0 or raw_url.len == 0) return;

    const owned_method = try state.allocator.dupe(u8, raw_method);
    errdefer state.allocator.free(owned_method);

    const owned_url = try state.allocator.dupe(u8, raw_url);
    errdefer state.allocator.free(owned_url);

    // Free any previously recorded data to keep allocations bounded.
    if (state.last_method) |previous| state.allocator.free(previous);
    if (state.last_url) |previous| state.allocator.free(previous);
    if (state.last_body) |previous| state.allocator.free(previous);

    state.last_method = owned_method;
    state.last_url = owned_url;
    state.last_body = null;
    state.last_status = 0;

    // Parse the method for the HTTP client.
    const method: http_client.Method = if (std.mem.eql(u8, raw_method, "GET"))
        .GET
    else if (std.mem.eql(u8, raw_method, "POST"))
        .POST
    else
        return; // Unsupported method — record-only fallback.

    const url = http_client.Url.parse(raw_url) orelse return;

    const config = http_client.Config{
        .method = method,
        .url = url,
    };

    const is_https = std.mem.eql(u8, raw_url[0..@min(raw_url.len, 8)], "https://");

    if (is_https) {
        // Attempt HTTPS via httpz. If unavailable, fall back to record-only.
        const https_response = http_client.requestHttps(state.allocator, state.io, config) catch |err| {
            if (err == error.HttpsNotSupported) return; // record-only fallback
            return; // Other errors also fall back to record-only.
        };
        state.last_status = https_response.status;
        state.last_body = https_response.body;
        return;
    }

    // Only attempt real requests for http:// URLs.
    if (!std.mem.eql(u8, raw_url[0..@min(raw_url.len, 7)], "http://")) {
        return; // Unrecognised scheme — record-only fallback.
    }

    // Perform the real HTTP request. On failure we keep the recorded
    // method/url but leave status at 0 (catch returns void).
    const response = http_client.request(state.allocator, state.io, config) catch return;

    state.last_status = response.status;
    state.last_body = response.body;
}

/// Releases the recorded method/url/body and resets `last_status`.
/// Idempotent.
fn clearState(state: *HttpState) void {
    if (state.last_method) |previous| {
        state.allocator.free(previous);
        state.last_method = null;
    }
    if (state.last_url) |previous| {
        state.allocator.free(previous);
        state.last_url = null;
    }
    if (state.last_body) |previous| {
        state.allocator.free(previous);
        state.last_body = null;
    }
    state.last_status = 0;
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

/// Allocates a new `HttpState` and wraps it in a `Module`. The caller is
/// responsible for invoking `start` and `stop`; failure to call `stop` will
/// leak the state and any recorded strings.
pub fn create(allocator: std.mem.Allocator, io: std.Io) !extensions.Module {
    const state = try allocator.create(HttpState);
    errdefer allocator.destroy(state);

    state.* = .{
        .last_method = null,
        .last_url = null,
        .last_body = null,
        .last_status = 0,
        .allocator = allocator,
        .io = io,
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

const test_runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

test "http fetch records method and url" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const module = try create(allocator, io);
    defer assertStop(module);

    try module.hooks.start_fn.?(module.context, test_runtime);
    try module.hooks.command_fn.?(module.context, test_runtime, .{
        .name = "http.fetch",
        .payload = "GET https://example.com",
    });

    const state: *HttpState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(state.last_method != null);
    try std.testing.expect(state.last_url != null);
    try std.testing.expectEqualStrings("GET", state.last_method.?);
    try std.testing.expectEqualStrings("https://example.com", state.last_url.?);
    try std.testing.expectEqual(@as(u16, 0), state.last_status);
    try std.testing.expect(state.last_body == null);
}

test "http fetch replaces previous method and url without leaking" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const module = try create(allocator, io);
    defer assertStop(module);

    try module.hooks.start_fn.?(module.context, test_runtime);

    try module.hooks.command_fn.?(module.context, test_runtime, .{
        .name = "http.fetch",
        .payload = "GET https://example.com",
    });
    try module.hooks.command_fn.?(module.context, test_runtime, .{
        .name = "http.fetch",
        .payload = "POST https://example.org/path",
    });

    const state: *HttpState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqualStrings("POST", state.last_method.?);
    try std.testing.expectEqualStrings("https://example.org/path", state.last_url.?);

    // std.testing.allocator fails the test if the replacement leaked.
}

test "http clear empties the recorded fields" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const module = try create(allocator, io);
    defer assertStop(module);

    try module.hooks.start_fn.?(module.context, test_runtime);
    try module.hooks.command_fn.?(module.context, test_runtime, .{
        .name = "http.fetch",
        .payload = "GET https://example.com",
    });
    try module.hooks.command_fn.?(module.context, test_runtime, .{
        .name = "http.clear",
    });

    const state: *HttpState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(state.last_method == null);
    try std.testing.expect(state.last_url == null);
    try std.testing.expect(state.last_body == null);
    try std.testing.expectEqual(@as(u16, 0), state.last_status);
}

test "http malformed fetch leaves prior state untouched" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const module = try create(allocator, io);
    defer assertStop(module);

    try module.hooks.start_fn.?(module.context, test_runtime);
    try module.hooks.command_fn.?(module.context, test_runtime, .{
        .name = "http.fetch",
        .payload = "GET https://example.com",
    });

    // No space → not a valid method/url pair; the plugin leaves the prior
    // values alone so callers can detect the malformed input by inspecting
    // the state.
    try module.hooks.command_fn.?(module.context, test_runtime, .{
        .name = "http.fetch",
        .payload = "malformed",
    });

    const state: *HttpState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqualStrings("GET", state.last_method.?);
    try std.testing.expectEqualStrings("https://example.com", state.last_url.?);
}

test "http start and stop do not crash" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const module = try create(allocator, io);
    defer assertStop(module);

    try module.hooks.start_fn.?(module.context, test_runtime);
}

test "http registers in a ModuleRegistry and dispatches through the registry" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var module = try create(allocator, io);
    // Not safe to defer stop here because the registry consumes the state;
    // we manually stop below.

    const modules = [_]extensions.Module{module};
    const registry = extensions.ModuleRegistry{ .modules = &modules };

    try registry.validate();
    try std.testing.expect(registry.hasCapability(.network));

    try registry.startAll(test_runtime);
    try registry.dispatchCommand(test_runtime, .{
        .name = "http.fetch",
        .payload = "GET https://example.com",
    });
    try registry.dispatchCommand(test_runtime, .{ .name = "http.clear" });

    // Inspect the recorded fields before the registry tears the state down.
    {
        const state: *HttpState = @ptrCast(@alignCast(module.context));
        try std.testing.expect(state.last_method == null);
        try std.testing.expect(state.last_url == null);
        try std.testing.expect(state.last_body == null);
    }

    try registry.stopAll(test_runtime);
    // stop consumed the state; the module handle is invalidated.
    module.context = undefined;
}

/// Helper to call stop and assert it succeeds. Ensures cleanup even
/// when a preceding assertion fails.
fn assertStop(module: extensions.Module) void {
    module.hooks.stop_fn.?(module.context, test_runtime) catch @panic("stop failed");
}

/// Whether to run tests that require real network access.
/// Set to false to skip these tests in offline environments.
const run_network_tests = true;

test "plugin_http: real HTTP GET to example.com" {
    if (!run_network_tests) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const module = try create(allocator, io);
    defer assertStop(module);

    try module.hooks.start_fn.?(module.context, test_runtime);
    try module.hooks.command_fn.?(module.context, test_runtime, .{
        .name = "http.fetch",
        .payload = "GET http://example.com/",
    });

    const state: *HttpState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqualStrings("GET", state.last_method.?);
    try std.testing.expectEqualStrings("http://example.com/", state.last_url.?);

    if (state.last_status == 0) {
        // Request failed (e.g. network unreachable); skip assertion.
        return error.SkipZigTest;
    }

    // example.com uses chunked encoding; body may be empty.
    // We assert status only until chunked support is added.
    try std.testing.expectEqual(@as(u16, 200), state.last_status);
}

test "plugin_http: real HTTP GET body via httpbin.org/html" {
    if (!run_network_tests) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const module = try create(allocator, io);
    defer assertStop(module);

    try module.hooks.start_fn.?(module.context, test_runtime);
    try module.hooks.command_fn.?(module.context, test_runtime, .{
        .name = "http.fetch",
        .payload = "GET http://httpbin.org/html",
    });

    const state: *HttpState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqualStrings("GET", state.last_method.?);
    try std.testing.expectEqualStrings("http://httpbin.org/html", state.last_url.?);

    if (state.last_status == 0) {
        return error.SkipZigTest;
    }

    try std.testing.expectEqual(@as(u16, 200), state.last_status);
    try std.testing.expect(state.last_body != null);
    try std.testing.expect(state.last_body.?.len > 0);
}

test "plugin_http: real HTTP GET 404 via httpstat.us" {
    if (!run_network_tests) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const module = try create(allocator, io);
    defer assertStop(module);

    try module.hooks.start_fn.?(module.context, test_runtime);
    try module.hooks.command_fn.?(module.context, test_runtime, .{
        .name = "http.fetch",
        .payload = "GET http://httpstat.us/404",
    });

    const state: *HttpState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqualStrings("GET", state.last_method.?);
    try std.testing.expectEqualStrings("http://httpstat.us/404", state.last_url.?);

    if (state.last_status == 0) {
        return error.SkipZigTest;
    }

    try std.testing.expectEqual(@as(u16, 404), state.last_status);
}

test "plugin_http: HTTPS fetch falls back to record-only when httpz is not linked" {
    if (!run_network_tests) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const module = try create(allocator, io);
    defer assertStop(module);

    try module.hooks.start_fn.?(module.context, test_runtime);
    try module.hooks.command_fn.?(module.context, test_runtime, .{
        .name = "http.fetch",
        .payload = "GET https://httpbin.org/status/200",
    });

    const state: *HttpState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqualStrings("GET", state.last_method.?);
    try std.testing.expectEqualStrings("https://httpbin.org/status/200", state.last_url.?);

    // When httpz is not linked, requestHttps returns HttpsNotSupported,
    // so last_status stays at 0 and last_body stays null (record-only).
    // If httpz IS linked and the test gets a real response, the status
    // will be 200. Either outcome is acceptable — the test verifies
    // the plugin does not crash and records the method/URL.
    if (state.last_status != 0) {
        try std.testing.expectEqual(@as(u16, 200), state.last_status);
    }
}
