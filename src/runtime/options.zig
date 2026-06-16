const platform = @import("../platform/root.zig");
const trace = @import("trace");
const bridge = @import("../bridge/root.zig");
const extensions = @import("../extensions/root.zig");
const security = @import("../security/root.zig");
const automation = @import("../automation/root.zig");
const window_state = @import("../window_state/root.zig");

/// Configuration passed to `Runtime.init`.
pub const Options = struct {
    /// Platform implementation providing native services.
    platform: platform.Platform,
    /// Optional trace sink for structured logs.
    trace_sink: ?trace.Sink = null,
    /// Optional filesystem path for platform logs.
    log_path: ?[]const u8 = null,
    /// Optional extension module registry.
    extensions: ?extensions.ModuleRegistry = null,
    /// Optional custom bridge dispatcher.
    bridge: ?bridge.Dispatcher = null,
    /// Policy governing built-in JS bridge commands.
    builtin_bridge: bridge.Policy = .{},
    /// Security and navigation policy.
    security: security.Policy = .{},
    /// Optional automation server for tests.
    automation: ?automation.Server = null,
    /// Optional persisted window state store.
    window_state_store: ?window_state.Store = null,
    /// Enables the JavaScript window/WebView API.
    js_window_api: bool = false,
};
