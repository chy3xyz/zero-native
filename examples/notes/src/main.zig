const std = @import("std");
const runner = @import("runner");
const zero_native = @import("zero-native");

pub const panic = std.debug.FullPanic(zero_native.debug.capturePanic);

const html = @embedFile("index.html");

const NotesApp = struct {
    fn app(self: *@This()) zero_native.App {
        return .{
            .context = self,
            .name = "notes",
            .source = zero_native.WebViewSource.html(html),
        };
    }
};

pub fn main(init: std.process.Init) !void {
    var app = NotesApp{};
    try runner.runWithOptions(app.app(), .{
        .app_name = "notes",
        .window_title = "Notes",
        .bundle_id = "dev.zero_native.examples.notes",
        .icon_path = "assets/icon.icns",
    }, init);
}

test "notes app uses inline HTML source" {
    var state = NotesApp{};
    const app = state.app();
    try std.testing.expectEqualStrings("notes", app.name);
    try std.testing.expectEqual(zero_native.WebViewSourceKind.html, app.source.kind);
}
