const std = @import("std");
const runtime = @import("../runtime/root.zig");
const platform = @import("platform");

pub const EmbeddedApp = struct {
    app: runtime.App,
    runtime: runtime.Runtime,

    pub fn init(app: runtime.App, platform_value: platform.Platform) EmbeddedApp {
        return .{
            .app = app,
            .runtime = runtime.Runtime.init(.{ .platform = platform_value }),
        };
    }

    pub fn start(self: *EmbeddedApp) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .app_start);
    }

    pub fn resize(self: *EmbeddedApp, surface: platform.Surface) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .{ .surface_resized = surface });
    }

    pub fn frame(self: *EmbeddedApp) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .frame_requested);
    }

    pub fn stop(self: *EmbeddedApp) anyerror!void {
        try self.runtime.dispatchPlatformEvent(self.app, .app_shutdown);
    }
};

const MobileHostApp = struct {
    null_platform: platform.NullPlatform,
    embedded: EmbeddedApp,
    last_error: ?anyerror = null,

    fn create() !*MobileHostApp {
        const allocator = std.heap.page_allocator;
        const self = try allocator.create(MobileHostApp);
        self.null_platform = platform.NullPlatform.init(.{});
        self.embedded = EmbeddedApp.init(.{
            .context = self,
            .name = "zero-native-mobile",
            .source = platform.WebViewSource.html(mobile_html),
        }, self.null_platform.platform());
        return self;
    }
};

const mobile_html =
    \\<!doctype html>
    \\<html>
    \\<body style="font-family: system-ui; padding: 2rem;">
    \\  <h1>zero-native mobile</h1>
    \\  <p>This content is loaded through the zero-native embedded C ABI.</p>
    \\</body>
    \\</html>
;

fn mobileApp(raw: ?*anyopaque) ?*MobileHostApp {
    const pointer = raw orelse return null;
    return @ptrCast(@alignCast(pointer));
}

fn recordError(self: *MobileHostApp, err: anyerror) void {
    self.last_error = err;
}

pub fn zero_native_app_create() ?*anyopaque {
    const self = MobileHostApp.create() catch return null;
    return self;
}

pub fn zero_native_app_destroy(app: ?*anyopaque) void {
    const self = mobileApp(app) orelse return;
    std.heap.page_allocator.destroy(self);
}

pub fn zero_native_app_start(app: ?*anyopaque) void {
    const self = mobileApp(app) orelse return;
    self.embedded.start() catch |err| recordError(self, err);
}

pub fn zero_native_app_stop(app: ?*anyopaque) void {
    const self = mobileApp(app) orelse return;
    self.embedded.stop() catch |err| recordError(self, err);
}

pub fn zero_native_app_resize(app: ?*anyopaque, width: f32, height: f32, scale: f32, surface: ?*anyopaque) void {
    const self = mobileApp(app) orelse return;
    self.embedded.resize(.{
        .size = .{ .width = width, .height = height },
        .scale_factor = scale,
        .native_handle = surface,
    }) catch |err| recordError(self, err);
}

pub fn zero_native_app_touch(app: ?*anyopaque, id: u64, phase: c_int, x: f32, y: f32, pressure: f32) void {
    _ = app;
    _ = id;
    _ = phase;
    _ = x;
    _ = y;
    _ = pressure;
}

pub fn zero_native_app_frame(app: ?*anyopaque) void {
    const self = mobileApp(app) orelse return;
    self.embedded.frame() catch |err| recordError(self, err);
}

pub fn zero_native_app_set_asset_root(app: ?*anyopaque, path: [*]const u8, len: usize) void {
    _ = app;
    _ = path;
    _ = len;
}

pub fn zero_native_app_last_command_count(app: ?*anyopaque) usize {
    const self = mobileApp(app) orelse return 0;
    return self.embedded.runtime.frameDiagnostics().command_count;
}

pub fn zero_native_app_last_error_name(app: ?*anyopaque) [*:0]const u8 {
    const self = mobileApp(app) orelse return "";
    const err = self.last_error orelse return "";
    return @errorName(err);
}

test "embedded app starts and loads source" {
    var null_platform = platform.NullPlatform.init(.{});
    var state: u8 = 0;
    var embedded = EmbeddedApp.init(.{
        .context = &state,
        .name = "embedded",
        .source = platform.WebViewSource.html("<p>Embedded</p>"),
    }, null_platform.platform());

    try embedded.start();
    try @import("std").testing.expectEqualStrings("<p>Embedded</p>", null_platform.loaded_source.?.bytes);
}

test "EmbeddedApp.init stores the supplied app and runtime" {
    var null_platform = platform.NullPlatform.init(.{});
    var context: u8 = 0;
    const app = runtime.App{
        .context = &context,
        .name = "init-test",
        .source = platform.WebViewSource.html("hello"),
    };
    const embedded = EmbeddedApp.init(app, null_platform.platform());

    try std.testing.expectEqualStrings("init-test", embedded.app.name);
    try std.testing.expectEqualStrings("null", embedded.runtime.options.platform.name);
}

const EventCounters = struct {
    start_count: usize = 0,
    stop_count: usize = 0,
    frame_count: usize = 0,
};

fn countingEvent(context: *anyopaque, rt: *runtime.Runtime, event_value: runtime.Event) anyerror!void {
    _ = rt;
    const self: *EventCounters = @ptrCast(@alignCast(context));
    switch (event_value) {
        .lifecycle => |lifecycle| switch (lifecycle) {
            .start => self.start_count += 1,
            .stop => self.stop_count += 1,
            .frame => self.frame_count += 1,
        },
        .command => {},
    }
}

test "EmbeddedApp start/stop/frame delegate to the embedded app and runtime" {
    var null_platform = platform.NullPlatform.init(.{});
    var counters: EventCounters = .{};
    var embedded = EmbeddedApp.init(.{
        .context = &counters,
        .name = "delegate",
        .source = platform.WebViewSource.html("<p>delegate</p>"),
        .event_fn = countingEvent,
    }, null_platform.platform());

    try embedded.start();
    try std.testing.expectEqual(@as(usize, 1), counters.start_count);

    try embedded.frame();
    try std.testing.expectEqual(@as(usize, 1), counters.frame_count);
    try std.testing.expectEqual(@as(u64, 1), embedded.runtime.frame_index);

    try embedded.stop();
    try std.testing.expectEqual(@as(usize, 1), counters.stop_count);
}

fn failingStart(context: *anyopaque, rt: *runtime.Runtime) anyerror!void {
    _ = context;
    _ = rt;
    return error.TestStartFailed;
}

test "EmbeddedApp.start propagates errors from the embedded app start callback" {
    var null_platform = platform.NullPlatform.init(.{});
    var context: u8 = 0;
    var embedded = EmbeddedApp.init(.{
        .context = &context,
        .name = "error",
        .source = platform.WebViewSource.html(""),
        .start_fn = failingStart,
    }, null_platform.platform());

    try std.testing.expectError(error.TestStartFailed, embedded.start());
}
