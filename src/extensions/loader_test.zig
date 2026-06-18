//! Tests for `extensions/loader.zig`. Lives in a separate file so the
//! tests are only pulled into the `extensions_tests` target (which
//! has the `httpz` and `update_manifest` module dependencies needed
//! to compile the lazy plugin dispatch in `loader.zig`). Putting the
//! tests here keeps the desktop test target (`src/root.zig` root)
//! free of those dependencies, since the runtime only imports the
//! loader at the API level.

const std = @import("std");
const extensions = @import("root.zig");
const loader = @import("loader.zig");

test "loadFromNames instantiates plugins from a raw name list" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{ "clipboard", "store" };

    const modules = try loader.loadFromNames(allocator, std.testing.io, &names, .{});
    defer loader.deinitRegistry(allocator, modules);

    try std.testing.expectEqual(@as(usize, names.len), modules.len);
    try std.testing.expectEqual(@as(extensions.ModuleId, 100), modules[0].info.id);
    try std.testing.expectEqualStrings("clipboard", modules[0].info.name);
    try std.testing.expectEqual(@as(extensions.ModuleId, 105), modules[1].info.id);
    try std.testing.expectEqualStrings("store", modules[1].info.name);
}

test "loadFromNames returns an empty slice for an empty list" {
    const allocator = std.testing.allocator;
    const modules = try loader.loadFromNames(allocator, std.testing.io, &.{}, .{});
    try std.testing.expectEqual(@as(usize, 0), modules.len);
    // Caller still owns the slice (allocator-allocated), so deinit it
    // even though no modules were created.
    loader.deinitRegistry(allocator, modules);
}

test "loadFromNames returns UnknownPlugin for an unknown name" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{"definitely-not-a-plugin"};
    const result = loader.loadFromNames(allocator, std.testing.io, &names, .{});
    try std.testing.expectError(error.UnknownPlugin, result);
}

test "deinitRegistry is a no-op for an empty slice" {
    const allocator = std.testing.allocator;
    // Should not crash, leak, or fail.
    loader.deinitRegistry(allocator, &.{});
}

const CustomPlugin = struct {
    const module_id: extensions.ModuleId = 999;

    fn create(allocator: std.mem.Allocator) !extensions.Module {
        const state = try allocator.create(u32);
        errdefer allocator.destroy(state);
        state.* = 42;
        return .{
            .info = .{
                .id = module_id,
                .name = "custom-plugin",
                .capabilities = &.{.{ .kind = .custom, .name = "custom" }},
            },
            .context = @ptrCast(state),
            .hooks = .{
                .stop_fn = stop,
            },
        };
    }

    fn stop(context: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
        const state: *u32 = @ptrCast(@alignCast(context));
        std.testing.allocator.destroy(state);
    }
};

test "loadFromNames resolves custom plugins from Plugin table" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{"custom-plugin"};
    const custom_plugins = [_]extensions.Plugin{.{
        .name = "custom-plugin",
        .create_fn = CustomPlugin.create,
    }};

    const modules = try loader.loadFromNames(allocator, std.testing.io, &names, .{
        .custom_plugins = &custom_plugins,
    });
    defer loader.deinitRegistry(allocator, modules);

    try std.testing.expectEqual(@as(usize, 1), modules.len);
    try std.testing.expectEqual(CustomPlugin.module_id, modules[0].info.id);
    try std.testing.expectEqualStrings("custom-plugin", modules[0].info.name);
}

test "loadFromNames prefers built-in plugins over custom plugins with the same name" {
    const allocator = std.testing.allocator;
    const names = [_][]const u8{"store"};
    const custom_plugins = [_]extensions.Plugin{.{
        .name = "store",
        .create_fn = CustomPlugin.create,
    }};

    const modules = try loader.loadFromNames(allocator, std.testing.io, &names, .{
        .custom_plugins = &custom_plugins,
    });
    defer loader.deinitRegistry(allocator, modules);

    // The built-in store plugin (id 105) wins over the custom factory.
    try std.testing.expectEqual(@as(extensions.ModuleId, 105), modules[0].info.id);
    try std.testing.expectEqualStrings("store", modules[0].info.name);
}
