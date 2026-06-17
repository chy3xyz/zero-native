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
