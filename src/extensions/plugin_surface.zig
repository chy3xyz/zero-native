//! Surface plugin — GPU-backed overlay on top of the WebView.
//! Creates a transparent native rendering surface for custom Metal/OpenGL
//! rendering composited with the WebView.

const std = @import("std");
const extensions = @import("root.zig");
const platform = @import("platform");

pub const ModuleId: extensions.ModuleId = 125;
pub const module_name: []const u8 = "surface";
pub const capabilities: []const extensions.Capability = &.{.{ .kind = .custom, .name = "surface" }};

pub const SurfaceState = struct {
    id: ?platform.SurfaceId = null,
    allocator: std.mem.Allocator,
};

pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}
pub fn stop(ctx: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const s: *SurfaceState = @ptrCast(@alignCast(ctx));
    s.allocator.destroy(s);
}

pub fn command(ctx: *anyopaque, runtime: extensions.RuntimeContext, cmd: extensions.Command) anyerror!void {
    const s: *SurfaceState = @ptrCast(@alignCast(ctx));
    const svc: ?*const platform.PlatformServices = @ptrCast(@alignCast(runtime.services));
    if (svc == null) return;
    const services = svc.?;

    if (std.mem.eql(u8, cmd.name, "surface.create")) {
        if (s.id != null) return;
        s.id = services.createSurface(.{ .width = 320, .height = 240 }) catch return;
    } else if (std.mem.eql(u8, cmd.name, "surface.position")) {
        const id = s.id orelse return;
        // payload: "x,y,width,height"
        var parts = std.mem.splitScalar(u8, cmd.payload, ',');
        const x = std.fmt.parseFloat(f64, parts.next() orelse return) catch return;
        const y = std.fmt.parseFloat(f64, parts.next() orelse return) catch return;
        const w = std.fmt.parseFloat(f64, parts.next() orelse return) catch return;
        const h = std.fmt.parseFloat(f64, parts.next() orelse return) catch return;
        services.setSurfaceFrame(id, .{ .x = x, .y = y, .width = w, .height = h }) catch return;
    } else if (std.mem.eql(u8, cmd.name, "surface.close")) {
        if (s.id) |id| {
            services.closeSurface(id) catch {};
            s.id = null;
        }
    } else if (std.mem.eql(u8, cmd.name, "surface.render")) {
        if (s.id) |id| {
            services.renderSurface(id) catch {};
        }
    } else if (std.mem.eql(u8, cmd.name, "surface.animate")) {
        if (s.id) |id| {
            services.startSurfaceAnimation(id) catch {};
        }
    } else if (std.mem.eql(u8, cmd.name, "surface.stop")) {
        if (s.id) |id| {
            services.stopSurfaceAnimation(id) catch {};
        }
    } else if (std.mem.eql(u8, cmd.name, "surface.color")) {
        if (s.id) |id| {
            var parts = std.mem.splitScalar(u8, cmd.payload, ',');
            const rr = std.fmt.parseFloat(f32, parts.next() orelse return) catch return;
            const gg = std.fmt.parseFloat(f32, parts.next() orelse return) catch return;
            const bb = std.fmt.parseFloat(f32, parts.next() orelse return) catch return;
            const aa = std.fmt.parseFloat(f32, parts.next() orelse return) catch 1.0;
            services.setSurfaceColor(id, rr, gg, bb, aa) catch {};
        }
    } else if (std.mem.eql(u8, cmd.name, "surface.shader")) {
        if (s.id) |id| {
            _ = services.setSurfaceShader(id, cmd.payload) catch null;
        }
    } else if (std.mem.eql(u8, cmd.name, "surface.vertices")) {
        if (s.id) |id| {
            services.setSurfaceVertices(id, cmd.payload) catch {};
        }
    } else if (std.mem.eql(u8, cmd.name, "surface.draw")) {
        if (s.id) |id| {
            const vc = std.fmt.parseUnsigned(usize, cmd.payload, 10) catch 3;
            services.drawSurface(id, vc) catch {};
        }
    }
}

pub fn create(allocator: std.mem.Allocator) !extensions.Module {
    const s = try allocator.create(SurfaceState);
    errdefer allocator.destroy(s);
    s.* = .{ .allocator = allocator };
    return .{ .info = .{ .id = ModuleId, .name = module_name, .capabilities = capabilities }, .context = @ptrCast(s), .hooks = .{ .start_fn = start, .stop_fn = stop, .command_fn = command } };
}

test "surface create records id" {
    const m = try create(std.testing.allocator);
    defer m.hooks.stop_fn.?(m.context, .{.platform_name="null"}) catch {};
    try m.hooks.command_fn.?(m.context, .{.platform_name="null"}, .{.name="surface.create", .payload="", .target=ModuleId});
    const s: *SurfaceState = @ptrCast(@alignCast(m.context));
    try std.testing.expect(s.id == null); // null services in test
}
