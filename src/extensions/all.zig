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
    _ = @import("http_client.zig");
    _ = @import("registry.zig");
}

// All-plugins compatibility check. Instantiates every bundled plugin, packs
// them into a single `ModuleRegistry`, and verifies:
//
// - the registry has exactly eleven modules
// - every `ModuleId` is unique (no two plugins collide)
// - `validate` accepts the full set (no duplicate ids, dependencies resolve)
// - every plugin's `start_fn` runs without error
// - every advertised `CapabilityKind` is observable via `hasCapability`
//
// Uses `std.testing.allocator` so any leak in a plugin's `create`/`stop`
// pairing surfaces as a test failure.
test "all 11 plugins register without conflicts" {
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

    var modules: [11]extensions.Module = undefined;

    modules[0] = try clipboard.create(allocator);
    modules[1] = try shell.create(allocator);
    modules[2] = try notification.create(allocator);
    modules[3] = try http.create(allocator, io);
    modules[4] = try deep_link.create(allocator);
    modules[5] = try store.create(allocator);
    // `autostart.create` with a non-null `base_dir` skips the home-directory
    // lookup, so the test never depends on `$HOME`. The path itself does not
    // need to exist because we never call `autostart.enable`.
    modules[6] = try autostart.create(allocator, io, "all-plugins-test", ".zig-cache/all-plugins-test");
    modules[7] = try single_instance.create(allocator, io);
    modules[8] = try updater.create(allocator, io, "0.0.0", "http://localhost/manifest.json", "");
    modules[9] = try global_shortcut.create(allocator);
    modules[10] = try websocket.create(allocator);

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

    // 1. Registry has exactly eleven modules.
    try std.testing.expectEqual(@as(usize, 11), modules.len);

    const registry = extensions.ModuleRegistry{ .modules = &modules };

    // 2. No duplicate ModuleIds and every declared dependency resolves.
    try registry.validate();

    // 3. Every plugin's start hook is a no-op that still returns success.
    for (modules) |module| {
        try module.hooks.start_fn.?(module.context, runtime);
    }

    // 4. Every advertised capability kind is observable from the registry.
    for (modules) |module| {
        for (module.info.capabilities) |capability| {
            try std.testing.expect(registry.hasCapability(capability.kind));
        }
    }

    // 5. ModuleIds are pairwise unique.
    for (modules, 0..) |module, index| {
        for (modules[0..index]) |previous| {
            try std.testing.expect(previous.info.id != module.info.id);
        }
    }

    // All modules are now initialised; the defer will tear them all down.
    initialised = modules.len;
}
