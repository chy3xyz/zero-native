const std = @import("std");
const event_mod = @import("event.zig");
const platform = @import("../platform/root.zig");
const Runtime = @import("root.zig").Runtime;

/// App-provided startup callback. Return type is `anyerror` because app
/// implementations may raise arbitrary errors.
const StartFn = *const fn (context: *anyopaque, runtime: *Runtime) anyerror!void;
/// App-provided event callback. Return type is `anyerror` because app
/// implementations may raise arbitrary errors.
const EventFn = *const fn (context: *anyopaque, runtime: *Runtime, event: event_mod.Event) anyerror!void;
/// App-provided source callback. Return type is `anyerror` because app
/// implementations may raise arbitrary errors.
const SourceFn = *const fn (context: *anyopaque) anyerror!platform.WebViewSource;
/// App-provided shutdown callback. Return type is `anyerror` because app
/// implementations may raise arbitrary errors.
const StopFn = *const fn (context: *anyopaque, runtime: *Runtime) anyerror!void;

/// Application binding supplied to `Runtime.run`. Holds the app context and
/// callbacks used to observe and feed the runtime.
pub const App = struct {
    /// Opaque app state passed to every callback.
    context: *anyopaque,
    /// Human-readable name used in logs and traces.
    name: []const u8,
    /// Default webview source for startup windows.
    source: platform.WebViewSource,
    /// Optional callback returning the current webview source.
    source_fn: ?SourceFn = null,
    /// Optional callback invoked at startup.
    start_fn: ?StartFn = null,
    /// Optional callback invoked for each runtime event.
    event_fn: ?EventFn = null,
    /// Optional callback invoked at shutdown.
    stop_fn: ?StopFn = null,

    /// Invokes the configured startup callback, if any.
    pub fn start(self: App, runtime: *Runtime) anyerror!void {
        if (self.start_fn) |start_fn| try start_fn(self.context, runtime);
    }

    /// Invokes the configured event callback, if any.
    pub fn event(self: App, runtime: *Runtime, event_value: event_mod.Event) anyerror!void {
        if (self.event_fn) |event_fn| try event_fn(self.context, runtime, event_value);
    }

    /// Returns the live webview source, preferring `source_fn` over `source`.
    pub fn webViewSource(self: App) anyerror!platform.WebViewSource {
        if (self.source_fn) |source_fn| return source_fn(self.context);
        return self.source;
    }

    /// Invokes the configured shutdown callback, if any.
    pub fn stop(self: App, runtime: *Runtime) anyerror!void {
        if (self.stop_fn) |stop_fn| try stop_fn(self.context, runtime);
    }
};
