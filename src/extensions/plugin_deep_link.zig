//! Deep link plugin module — URL scheme handler registration and last-url
//! recording.
//!
//! Commands are routed by `cmd.name` only; any argument string lives in
//! `cmd.payload`. Supported commands:
//! - `deep_link.register` — `cmd.payload` is a URL scheme (e.g. `"myapp"`).
//!   Records it in state, replacing any previously registered scheme.
//! - `deep_link.last_url` — the plugin records the last received deep link
//!   URL for test inspection. On a real platform this is fed by the OS-level
//!   delegate; in tests it is set via `deep_link.last_url` with
//!   `cmd.payload` being the URL.
//!
//! Actual OS-level URL scheme registration requires platform config
//! (Info.plist on macOS, .desktop on Linux, registry on Windows). This
//! plugin records the intent only; `start` logs the scheme via
//! `std.log.debug` and `stop` cleans up the recorded state.

const std = @import("std");
const extensions = @import("root.zig");

/// Unique module id for the deep link plugin.
pub const ModuleId: extensions.ModuleId = 104;

/// Module name used in `ModuleInfo`.
pub const module_name: []const u8 = "deep-link";

/// Capabilities advertised by this module.
pub const capabilities: []const extensions.Capability = &.{
    .{ .kind = .custom, .name = "deep-link" },
};

/// Command-name constants.
pub const cmd_register: []const u8 = "deep_link.register";
pub const cmd_last_url: []const u8 = "deep_link.last_url";

/// Mutable state owned by a deep link module instance.
pub const DeepLinkState = struct {
    scheme: ?[]u8,
    last_url: ?[]u8,
    allocator: std.mem.Allocator,
};

/// Allocate the plugin state and return a `Module` view.
pub fn create(allocator: std.mem.Allocator) !extensions.Module {
    const state = try allocator.create(DeepLinkState);
    errdefer allocator.destroy(state);
    state.* = .{
        .scheme = null,
        .last_url = null,
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

/// Start hook — logs the registered scheme (if any) via `std.log.debug`.
/// On a real platform this would register the URL scheme with the OS.
/// Platform-specific steps are documented below:
///
/// macOS: add `CFBundleURLSchemes` → `["<scheme>"]` in Info.plist
/// Linux: add `MimeType=x-scheme-handler/<scheme>;` in the .desktop file
/// Windows: add `HKEY_CLASSES_ROOT\<scheme>\shell\open\command` registry key
pub fn start(context: *anyopaque, runtime: extensions.RuntimeContext) anyerror!void {
    _ = runtime;
    const state: *DeepLinkState = @ptrCast(@alignCast(context));
    if (state.scheme) |scheme| {
        std.log.debug("deep-link: registered URL scheme '{s}'", .{scheme});
    }
}

/// Stop hook — frees the recorded scheme/url strings and destroys the state.
pub fn stop(context: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const state: *DeepLinkState = @ptrCast(@alignCast(context));
    if (state.scheme) |scheme| state.allocator.free(scheme);
    if (state.last_url) |url| state.allocator.free(url);
    state.allocator.destroy(state);
}

/// Command hook — dispatches `deep_link.register` and `deep_link.last_url`.
pub fn command(
    context: *anyopaque,
    _: extensions.RuntimeContext,
    cmd: extensions.Command,
) anyerror!void {
    const state: *DeepLinkState = @ptrCast(@alignCast(context));

    if (std.mem.eql(u8, cmd.name, cmd_register)) {
        if (cmd.payload.len == 0) return;
        // Free the previous scheme if one was registered.
        if (state.scheme) |old| state.allocator.free(old);
        state.scheme = try state.allocator.dupe(u8, cmd.payload);
        return;
    }

    if (std.mem.eql(u8, cmd.name, cmd_last_url)) {
        if (state.last_url) |old| state.allocator.free(old);
        state.last_url = if (cmd.payload.len > 0)
            try state.allocator.dupe(u8, cmd.payload)
        else
            null;
        return;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const test_runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

test "deep_link: register records the scheme" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);

    try module.hooks.start_fn.?(module.context, test_runtime);
    try module.hooks.command_fn.?(module.context, test_runtime, .{
        .name = "deep_link.register",
        .payload = "myapp",
    });

    const state: *DeepLinkState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(state.scheme != null);
    try std.testing.expectEqualStrings("myapp", state.scheme.?);

    try module.hooks.stop_fn.?(module.context, test_runtime);
}

test "deep_link: subsequent register replaces the old scheme" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);

    try module.hooks.start_fn.?(module.context, test_runtime);
    try module.hooks.command_fn.?(module.context, test_runtime, .{
        .name = "deep_link.register",
        .payload = "first",
    });
    try module.hooks.command_fn.?(module.context, test_runtime, .{
        .name = "deep_link.register",
        .payload = "second",
    });

    const state: *DeepLinkState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqualStrings("second", state.scheme.?);

    try module.hooks.stop_fn.?(module.context, test_runtime);
}

test "deep_link: start and stop do not crash" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);

    try module.hooks.start_fn.?(module.context, test_runtime);
    try module.hooks.stop_fn.?(module.context, test_runtime);
}

test "deep_link: last_url records the payload" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);

    try module.hooks.start_fn.?(module.context, test_runtime);
    try module.hooks.command_fn.?(module.context, test_runtime, .{
        .name = "deep_link.last_url",
        .payload = "myapp://open/profile",
    });

    const state: *DeepLinkState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(state.last_url != null);
    try std.testing.expectEqualStrings("myapp://open/profile", state.last_url.?);

    try module.hooks.stop_fn.?(module.context, test_runtime);
}

test "deep_link: last_url replaces previous url" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);

    try module.hooks.start_fn.?(module.context, test_runtime);
    try module.hooks.command_fn.?(module.context, test_runtime, .{
        .name = "deep_link.last_url",
        .payload = "myapp://first",
    });
    try module.hooks.command_fn.?(module.context, test_runtime, .{
        .name = "deep_link.last_url",
        .payload = "myapp://second",
    });

    const state: *DeepLinkState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqualStrings("myapp://second", state.last_url.?);

    try module.hooks.stop_fn.?(module.context, test_runtime);
}

test "deep_link: registers in a ModuleRegistry" {
    const allocator = std.testing.allocator;
    var module = try create(allocator);

    const modules = [_]extensions.Module{module};
    const registry = extensions.ModuleRegistry{ .modules = &modules };

    try registry.validate();
    try std.testing.expect(registry.hasCapability(.custom));

    try registry.startAll(test_runtime);
    try registry.dispatchCommand(test_runtime, .{
        .name = "deep_link.register",
        .payload = "myapp",
    });
    try registry.dispatchCommand(test_runtime, .{
        .name = "deep_link.last_url",
        .payload = "myapp://test",
    });

    {
        const state: *DeepLinkState = @ptrCast(@alignCast(module.context));
        try std.testing.expectEqualStrings("myapp", state.scheme.?);
        try std.testing.expectEqualStrings("myapp://test", state.last_url.?);
    }

    try registry.stopAll(test_runtime);
    module.context = undefined;
}
