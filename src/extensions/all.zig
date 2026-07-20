//! Test entry point that imports the extensions module and all bundled plugins
//! so their `test "..."` blocks are discovered by the test runner.
//!
//! The plugin files are imported purely for their side-effect of declaring tests;
//! production code should import `root.zig` (the public API surface) directly.

const std = @import("std");
const extensions = @import("root.zig");

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
    _ = @import("plugin_process.zig");
    _ = @import("plugin_os.zig");
    _ = @import("plugin_log.zig");
    _ = @import("plugin_cli.zig");
    _ = @import("plugin_sql.zig");
    _ = @import("http_client.zig");
    _ = @import("registry.zig");
    _ = @import("loader_test.zig");
}

// All-plugins compatibility check. Instantiates every bundled plugin, packs
// them into a single `ModuleRegistry`, and verifies:
//
// - every `ModuleId` is unique (no two plugins collide)
// - `validate` accepts the full set (no duplicate ids, dependencies resolve)
// - every plugin's `start_fn` runs without error
// - every advertised `CapabilityKind` is observable via `hasCapability`
//
// Uses `std.testing.allocator` so any leak in a plugin's `create`/`stop`
// pairing surfaces as a test failure.
test "all bundled plugins register without conflicts" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    const clipboard = @import("plugin_clipboard.zig");
    const shell = @import("plugin_shell.zig");
    const notification = @import("plugin_notification.zig");
    const http = @import("plugin_http.zig");
    const deep_link = @import("plugin_deep_link.zig");
    const store = @import("plugin_store.zig");
    const autostart = @import("plugin_autostart.zig");
    const single_instance = @import("plugin_single_instance.zig");
    const updater = @import("plugin_updater.zig");
    const global_shortcut = @import("plugin_global_shortcut.zig");
    const websocket = @import("plugin_websocket.zig");
    const process_mod = @import("plugin_process.zig");
    const os_mod = @import("plugin_os.zig");
    const log_mod = @import("plugin_log.zig");
    const cli_mod = @import("plugin_cli.zig");
    const sql_mod = @import("plugin_sql.zig");
    const path_mod = @import("plugin_path.zig");
    const fs_mod = @import("plugin_fs.zig");
    const dialog_mod = @import("plugin_dialog.zig");
    const env_mod = @import("plugin_env.zig");
    const random_mod = @import("plugin_random.zig");
    const crypto_mod = @import("plugin_crypto.zig");
    const window_mod = @import("plugin_window.zig");
    const tray_mod = @import("plugin_tray.zig");
    const surface_mod = @import("plugin_surface.zig");

    var modules: [25]extensions.Module = undefined;

    modules[0] = try clipboard.create(allocator);
    modules[1] = try shell.create(allocator);
    modules[2] = try notification.create(allocator);
    modules[3] = try http.create(allocator, io);
    modules[4] = try deep_link.create(allocator, &.{});
    modules[5] = try store.create(allocator, io, "");
    // `autostart.create` with a non-null `base_dir` skips the home-directory
    // lookup, so the test never depends on `$HOME`. The path itself does not
    // need to exist because we never call `autostart.enable`.
    modules[6] = try autostart.create(allocator, io, "all-plugins-test", ".zig-cache/all-plugins-test");
    modules[7] = try single_instance.create(allocator, io);
    modules[8] = try updater.create(allocator, io, "0.0.0", "http://localhost/manifest.json", "", false);
    modules[9] = try global_shortcut.create(allocator, io);
    modules[10] = try websocket.create(allocator);
    modules[11] = try process_mod.create(allocator);
    modules[12] = try os_mod.create(allocator);
    modules[13] = try log_mod.create(allocator);
    modules[14] = try cli_mod.create(allocator);
    modules[15] = try sql_mod.create(allocator);
    modules[16] = try path_mod.create(allocator, "all-plugins-test");
    modules[17] = try fs_mod.create(allocator, io);
    modules[18] = try dialog_mod.create(allocator);
    modules[19] = try env_mod.create(allocator);
    modules[20] = try random_mod.create(allocator);
    modules[21] = try crypto_mod.create(allocator);
    modules[22] = try window_mod.create(allocator);
    modules[23] = try tray_mod.create(allocator);
    modules[24] = try surface_mod.create(allocator);

    // Walk modules in reverse on failure so each `create`'s allocation
    // (and the state struct) is paired with a matching `stop_fn`. We
    // update `initialised` after every successful call.
    var initialised: usize = 0;
    defer {
        var index = initialised;
        while (index > 0) {
            index -= 1;
            modules[index].hooks.stop_fn.?(modules[index].context, runtime) catch {};
        }
    }

    const registry = extensions.ModuleRegistry{ .modules = &modules };

    // No duplicate ModuleIds and every declared dependency resolves.
    try registry.validate();

    // Every plugin's start hook is a no-op that still returns success.
    for (modules) |module| {
        try module.hooks.start_fn.?(module.context, runtime);
    }

    // Every advertised capability kind is observable from the registry.
    for (modules) |module| {
        for (module.info.capabilities) |capability| {
            try std.testing.expect(registry.hasCapability(capability.kind));
        }
    }

    // ModuleIds are pairwise unique.
    for (modules, 0..) |module, index| {
        for (modules[0..index]) |previous| {
            try std.testing.expect(previous.info.id != module.info.id);
        }
    }

    // All modules are now initialised; the defer will tear them all down.
    initialised = modules.len;
}
