const std = @import("std");
const runner = @import("runner");
const zero_native = @import("zero-native");

pub const panic = std.debug.FullPanic(zero_native.debug.capturePanic);

const index_html = @embedFile("../index.html");

/// Plugin names mirror `app.zon`'s `plugins = .{ ... }` array. The
/// example hardcodes them here because parsing the manifest at
/// runtime would require a `tooling` import on the public API
/// surface — keeping the list local lets the example stay free of
/// extra build dependencies. The `app.zon` is still the source of
/// truth for documentation; changing the manifest requires a matching
/// edit here.
const plugin_names = [_][]const u8{ "clipboard", "notification", "store" };

const WithPluginsApp = struct {
    fn app(self: *@This()) zero_native.App {
        return .{
            .context = self,
            .name = "with-plugins",
            .source = zero_native.WebViewSource.html(index_html),
        };
    }
};

pub fn main(init: std.process.Init) !void {
    var state: WithPluginsApp = .{};
    try runner.runWithOptions(state.app(), .{
        .app_name = "with-plugins",
        .window_title = "With Plugins",
        .bundle_id = "dev.zero_native.with_plugins",
        .icon_path = "assets/icon.icns",
        .plugin_names = &plugin_names,
    }, init);
}

test "with-plugins app uses embedded html source" {
    var state: WithPluginsApp = .{};
    const app = state.app();
    try std.testing.expectEqualStrings("with-plugins", app.name);
    try std.testing.expectEqual(zero_native.WebViewSourceKind.html, app.source.kind);
    try std.testing.expect(std.mem.indexOf(u8, app.source.bytes, "With Plugins") != null);
}

test "plugin list matches the manifest declaration" {
    try std.testing.expectEqual(@as(usize, 3), plugin_names.len);
    try std.testing.expectEqualStrings("clipboard", plugin_names[0]);
    try std.testing.expectEqualStrings("notification", plugin_names[1]);
    try std.testing.expectEqualStrings("store", plugin_names[2]);
}

test "index.html embeds all three plugin buttons" {
    try std.testing.expect(std.mem.indexOf(u8, index_html, "clipboard.write_text") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "notification.notify") != null);
    try std.testing.expect(std.mem.indexOf(u8, index_html, "store.set") != null);
}
