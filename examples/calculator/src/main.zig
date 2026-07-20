const std = @import("std");
const runner = @import("runner");
const zero_native = @import("zero-native");

pub const panic = std.debug.FullPanic(zero_native.debug.capturePanic);

const html = @embedFile("index.html");

const CalcApp = struct {
    fn app(self: *@This()) zero_native.App {
        return .{
            .context = self,
            .name = "calculator",
            .source = zero_native.WebViewSource.html(html),
        };
    }
};

pub fn main(init: std.process.Init) !void {
    var app = CalcApp{};
    try runner.runWithOptions(app.app(), .{
        .app_name = "calculator",
        .window_title = "Calculator",
        .bundle_id = "dev.zero_native.examples.calculator",
        .icon_path = "assets/icon.icns",
    }, init);
}

test "calculator app uses inline HTML source" {
    var state = CalcApp{};
    const app = state.app();
    try std.testing.expectEqualStrings("calculator", app.name);
    try std.testing.expectEqual(zero_native.WebViewSourceKind.html, app.source.kind);
}
