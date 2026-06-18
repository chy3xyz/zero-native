//! Zero Native public C ABI surface.
//!
//! All `zero_native_app_*` functions MUST be called from the same thread that
//! called `zero_native_app_create`. The runtime is single-threaded by design;
//! the platform event loop, frame scheduling, and bridge dispatch all assume
//! a single owner thread. Calling these functions from multiple threads
//! concurrently is undefined behavior.

pub const geometry = @import("geometry");
pub const assets = @import("assets");
pub const app_dirs = @import("app_dirs");
pub const app_manifest = @import("app_manifest");
pub const trace = @import("trace");
pub const diagnostics = @import("diagnostics");
pub const platform_info = @import("platform_info");

pub const runtime = @import("runtime/root.zig");
pub const platform = @import("platform");
pub const window_state = @import("window_state/root.zig");
pub const asset_server = @import("assets/root.zig");
pub const debug = @import("debug/root.zig");
pub const automation = @import("automation/root.zig");
pub const embed = @import("embed/root.zig");
pub const extensions = @import("extensions/root.zig");
pub const js = @import("js/root.zig");
pub const bridge = @import("bridge/root.zig");
pub const frontend = @import("frontend/root.zig");
pub const security = @import("security");

pub const Runtime = runtime.Runtime;
pub const RuntimeOptions = runtime.Options;
pub const App = runtime.App;
pub const Event = runtime.Event;
pub const LifecycleEvent = runtime.LifecycleEvent;
pub const CommandEvent = runtime.CommandEvent;
pub const TestHarness = runtime.TestHarness;

pub const WebViewSource = platform.WebViewSource;
pub const WebViewSourceKind = platform.WebViewSourceKind;
pub const WebViewAssetSource = platform.WebViewAssetSource;
pub const WebEngine = platform.WebEngine;
pub const AppInfo = platform.AppInfo;
pub const Platform = platform.Platform;
pub const NullPlatform = platform.NullPlatform;
pub const WindowId = platform.WindowId;
pub const WindowOptions = platform.WindowOptions;
pub const WindowCreateOptions = platform.WindowCreateOptions;
pub const WindowInfo = platform.WindowInfo;
pub const WindowState = platform.WindowState;
pub const WindowRestorePolicy = platform.WindowRestorePolicy;
pub const FileFilter = platform.FileFilter;
pub const OpenDialogOptions = platform.OpenDialogOptions;
pub const OpenDialogResult = platform.OpenDialogResult;
pub const SaveDialogOptions = platform.SaveDialogOptions;
pub const MessageDialogStyle = platform.MessageDialogStyle;
pub const MessageDialogResult = platform.MessageDialogResult;
pub const MessageDialogOptions = platform.MessageDialogOptions;
pub const TrayItemId = platform.TrayItemId;
pub const TrayOptions = platform.TrayOptions;
pub const TrayMenuItem = platform.TrayMenuItem;
pub const BridgeDispatcher = bridge.Dispatcher;
pub const BridgePolicy = bridge.Policy;
pub const BridgeCommandPolicy = bridge.CommandPolicy;
pub const BridgeHandler = bridge.Handler;
pub const BridgeRegistry = bridge.Registry;
pub const SecurityPolicy = security.Policy;
pub const NavigationPolicy = security.NavigationPolicy;
pub const ExternalLinkPolicy = security.ExternalLinkPolicy;
pub const ExternalLinkAction = security.ExternalLinkAction;

test {
    @import("std").testing.refAllDecls(@This());
}

/// Create a new zero-native app instance on the calling thread.
/// INTERNAL: not thread-safe — the returned handle is owned by this thread.
pub export fn zero_native_app_create() ?*anyopaque {
    return embed.zero_native_app_create();
}

/// Destroy an app instance previously created on the calling thread.
/// INTERNAL: not thread-safe — must run on the same thread as `zero_native_app_create`.
pub export fn zero_native_app_destroy(app: ?*anyopaque) void {
    embed.zero_native_app_destroy(app);
}

/// Start the app's platform event loop.
/// INTERNAL: not thread-safe — must run on the same thread as `zero_native_app_create`.
pub export fn zero_native_app_start(app: ?*anyopaque) void {
    embed.zero_native_app_start(app);
}

/// Request shutdown of the running app.
/// INTERNAL: not thread-safe — must run on the same thread as `zero_native_app_create`.
pub export fn zero_native_app_stop(app: ?*anyopaque) void {
    embed.zero_native_app_stop(app);
}

/// Notify the runtime that the host surface was resized.
/// INTERNAL: not thread-safe — must run on the same thread as `zero_native_app_create`.
pub export fn zero_native_app_resize(app: ?*anyopaque, width: f32, height: f32, scale: f32, surface: ?*anyopaque) void {
    embed.zero_native_app_resize(app, width, height, scale, surface);
}

/// Forward a touch event to the runtime.
/// INTERNAL: not thread-safe — must run on the same thread as `zero_native_app_create`.
pub export fn zero_native_app_touch(app: ?*anyopaque, id: u64, phase: c_int, x: f32, y: f32, pressure: f32) void {
    embed.zero_native_app_touch(app, id, phase, x, y, pressure);
}

/// Drive a single frame on the runtime.
/// INTERNAL: not thread-safe — must run on the same thread as `zero_native_app_create`.
pub export fn zero_native_app_frame(app: ?*anyopaque) void {
    embed.zero_native_app_frame(app);
}

/// Configure the asset root directory used by the asset server.
/// INTERNAL: not thread-safe — must run on the same thread as `zero_native_app_create`.
pub export fn zero_native_app_set_asset_root(app: ?*anyopaque, path: [*]const u8, len: usize) void {
    embed.zero_native_app_set_asset_root(app, path, len);
}

/// Return the count of bridge commands handled in the most recent frame.
/// INTERNAL: not thread-safe — must run on the same thread as `zero_native_app_create`.
pub export fn zero_native_app_last_command_count(app: ?*anyopaque) usize {
    return embed.zero_native_app_last_command_count(app);
}

/// Return a null-terminated name for the last error recorded on the runtime.
/// INTERNAL: not thread-safe — must run on the same thread as `zero_native_app_create`.
pub export fn zero_native_app_last_error_name(app: ?*anyopaque) [*:0]const u8 {
    return embed.zero_native_app_last_error_name(app);
}
