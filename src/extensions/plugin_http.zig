//! HTTP plugin module — record-only stub for an HTTP fetch API.
//!
//! The extension `Command` struct only carries a routing name and an optional
//! target module id, so the method and URL for `http.fetch` are encoded
//! directly in `cmd.name` after the routing head, e.g.
//! `"http.fetch:GET https://example.com"`. The plugin splits on the first
//! `:` to recover the command and the payload, then splits the payload on
//! the first ASCII space to recover the HTTP method and the URL.
//!
//! The plugin is intentionally **record-only**: no actual network request is
//! issued. `state.last_method` and `state.last_url` are populated with
//! allocator-owned duplicates of the parsed slices and `state.last_status`
//! is left at `0`. The extension `Command` has no return channel, so tests
//! inspect these fields directly. Real network support via `std.http.Client`
//! is left for a follow-up once the Zig 0.17-dev API stabilises.

const std = @import("std");
const extensions = @import("root.zig");

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
/// subsequent `http.fetch` / `http.clear` calls). `last_status` is reserved
/// for a future implementation that issues real requests; it stays at `0`
/// while the plugin remains record-only.
pub const HttpState = struct {
    last_method: ?[]u8,
    last_url: ?[]u8,
    last_status: u16 = 0,
    allocator: std.mem.Allocator,
};

// ---------------------------------------------------------------------------
// Lifecycle hooks
// ---------------------------------------------------------------------------

/// No-op startup hook. The http plugin holds no external resources to
/// acquire before it can begin accepting commands.
pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}

/// Stop hook — frees the recorded method/url strings and destroys the
/// state. Mirrors `create`'s allocator exactly. Safe to call only once
/// per `create`; subsequent calls would double-free.
pub fn stop(context: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const state: *HttpState = @ptrCast(@alignCast(context));
    if (state.last_method) |method| state.allocator.free(method);
    if (state.last_url) |url| state.allocator.free(url);
    state.allocator.destroy(state);
}

/// Command hook — routes `http.fetch` and `http.clear` to their handlers.
///
/// Recognised forms (after splitting on the first `:`):
/// - `"http.fetch"` with payload `"METHOD URL"` (split on first space).
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

    const parsed = parseCommand(cmd.name);

    if (std.mem.eql(u8, parsed.head, cmd_fetch)) {
        try handleFetch(state, parsed.payload);
        return;
    }

    if (std.mem.eql(u8, parsed.head, cmd_clear)) {
        clearState(state);
        return;
    }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/// Splits a command string into its routing head and payload. The payload is
/// everything after the first `:`. The `:` is omitted so callers can pass
/// bare command names like `"http.clear"`.
fn parseCommand(raw: []const u8) struct { head: []const u8, payload: []const u8 } {
    if (std.mem.indexOfScalar(u8, raw, ':')) |index| {
        return .{ .head = raw[0..index], .payload = raw[index + 1 ..] };
    }
    return .{ .head = raw, .payload = "" };
}

/// Stores the parsed method and URL into `state`. Splits the payload on the
/// first ASCII space; payloads with no separator are rejected silently
/// (leaving prior state untouched) so callers can detect malformed input by
/// inspecting the state. `last_status` is left at `0` — the plugin is a
/// record-only stub for now.
fn handleFetch(state: *HttpState, payload: []const u8) !void {
    const separator = std.mem.indexOfScalar(u8, payload, ' ') orelse return;
    const raw_method = payload[0..separator];
    const raw_url = payload[separator + 1 ..];
    if (raw_method.len == 0 or raw_url.len == 0) return;

    const owned_method = try state.allocator.dupe(u8, raw_method);
    errdefer state.allocator.free(owned_method);

    const owned_url = try state.allocator.dupe(u8, raw_url);
    errdefer state.allocator.free(owned_url);

    // Replace any previously recorded strings to keep the allocator's
    // outstanding set bounded.
    if (state.last_method) |previous| state.allocator.free(previous);
    if (state.last_url) |previous| state.allocator.free(previous);

    state.last_method = owned_method;
    state.last_url = owned_url;
    state.last_status = 0;
}

/// Releases the recorded method/url and resets `last_status`. Idempotent.
fn clearState(state: *HttpState) void {
    if (state.last_method) |previous| {
        state.allocator.free(previous);
        state.last_method = null;
    }
    if (state.last_url) |previous| {
        state.allocator.free(previous);
        state.last_url = null;
    }
    state.last_status = 0;
}

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

/// Allocates a new `HttpState` and wraps it in a `Module`. The caller is
/// responsible for invoking `start` and `stop`; failure to call `stop` will
/// leak the state and any recorded strings.
pub fn create(allocator: std.mem.Allocator) !extensions.Module {
    const state = try allocator.create(HttpState);
    errdefer allocator.destroy(state);

    state.* = .{
        .last_method = null,
        .last_url = null,
        .last_status = 0,
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

test "http fetch records method and url" {
    const allocator = std.testing.allocator;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    const module = try create(allocator);
    try module.hooks.start_fn.?(module.context, runtime);
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "http.fetch:GET https://example.com",
    });

    const state: *HttpState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(state.last_method != null);
    try std.testing.expect(state.last_url != null);
    try std.testing.expectEqualStrings("GET", state.last_method.?);
    try std.testing.expectEqualStrings("https://example.com", state.last_url.?);
    try std.testing.expectEqual(@as(u16, 0), state.last_status);

    try module.hooks.stop_fn.?(module.context, runtime);
}

test "http fetch replaces previous method and url without leaking" {
    const allocator = std.testing.allocator;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    const module = try create(allocator);
    try module.hooks.start_fn.?(module.context, runtime);

    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "http.fetch:GET https://example.com",
    });
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "http.fetch:POST https://example.org/path",
    });

    const state: *HttpState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqualStrings("POST", state.last_method.?);
    try std.testing.expectEqualStrings("https://example.org/path", state.last_url.?);

    // std.testing.allocator fails the test if the replacement leaked.
    try module.hooks.stop_fn.?(module.context, runtime);
}

test "http clear empties the recorded fields" {
    const allocator = std.testing.allocator;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    const module = try create(allocator);
    try module.hooks.start_fn.?(module.context, runtime);
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "http.fetch:GET https://example.com",
    });
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "http.clear",
    });

    const state: *HttpState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(state.last_method == null);
    try std.testing.expect(state.last_url == null);
    try std.testing.expectEqual(@as(u16, 0), state.last_status);

    try module.hooks.stop_fn.?(module.context, runtime);
}

test "http malformed fetch leaves prior state untouched" {
    const allocator = std.testing.allocator;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    const module = try create(allocator);
    try module.hooks.start_fn.?(module.context, runtime);
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "http.fetch:GET https://example.com",
    });

    // No space → not a valid method/url pair; the plugin leaves the prior
    // values alone so callers can detect the malformed input by inspecting
    // the state.
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "http.fetch:malformed",
    });

    const state: *HttpState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqualStrings("GET", state.last_method.?);
    try std.testing.expectEqualStrings("https://example.com", state.last_url.?);

    try module.hooks.stop_fn.?(module.context, runtime);
}

test "http start and stop do not crash" {
    const allocator = std.testing.allocator;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    const module = try create(allocator);
    try module.hooks.start_fn.?(module.context, runtime);
    try module.hooks.stop_fn.?(module.context, runtime);
}

test "http registers in a ModuleRegistry and dispatches through the registry" {
    const allocator = std.testing.allocator;
    var module = try create(allocator);
    const modules = [_]extensions.Module{module};
    const registry = extensions.ModuleRegistry{ .modules = &modules };
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    try registry.validate();
    try std.testing.expect(registry.hasCapability(.network));

    try registry.startAll(runtime);
    try registry.dispatchCommand(runtime, .{
        .name = "http.fetch:GET https://example.com",
    });
    try registry.dispatchCommand(runtime, .{ .name = "http.clear" });

    // Inspect the recorded fields before the registry tears the state down.
    {
        const state: *HttpState = @ptrCast(@alignCast(module.context));
        try std.testing.expect(state.last_method == null);
        try std.testing.expect(state.last_url == null);
    }

    try registry.stopAll(runtime);
    // stop consumed the state; the module handle is invalidated.
    module.context = undefined;
}
