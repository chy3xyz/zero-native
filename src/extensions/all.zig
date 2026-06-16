//! Test entry point that imports the extensions module and all bundled plugins
//! so their `test "..."` blocks are discovered by the test runner.
//!
//! The plugin files are imported purely for their side-effect of declaring tests;
//! production code should import `root.zig` (the public API surface) directly.

test {
    _ = @import("root.zig");
    _ = @import("plugin_clipboard.zig");
    _ = @import("plugin_shell.zig");
    _ = @import("plugin_notification.zig");
    _ = @import("plugin_http.zig");
    _ = @import("plugin_store.zig");
    _ = @import("plugin_deep_link.zig");
    _ = @import("plugin_single_instance.zig");
    _ = @import("plugin_autostart.zig");
    _ = @import("plugin_updater.zig");
    _ = @import("plugin_global_shortcut.zig");
    _ = @import("plugin_websocket.zig");
    _ = @import("http_client.zig");
}
