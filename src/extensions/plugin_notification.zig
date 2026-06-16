const std = @import("std");
const extensions = @import("root.zig");

pub const ModuleId: extensions.ModuleId = 102;

/// A single recorded notification. The slices are owned by the parent
/// `NotificationState` and freed in `stop`.
pub const Notification = struct {
    title: []const u8,
    message: []const u8,
};

/// In-memory state for the notification plugin. Records every emitted
/// notification so it can be inspected in tests.
pub const NotificationState = struct {
    notifications: std.ArrayList(Notification),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) NotificationState {
        return .{
            .notifications = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NotificationState) void {
        for (self.notifications.items) |entry| {
            self.allocator.free(entry.title);
            self.allocator.free(entry.message);
        }
        self.notifications.deinit(self.allocator);
    }
};

/// Module name used in the `ModuleInfo`.
pub const module_name: []const u8 = "notification";

/// Capabilities advertised by this module.
pub const capabilities: []const extensions.Capability = &.{
    .{ .kind = .custom, .name = "notification" },
};

/// Command-name constants. Payloads are appended after a `:` separator when
/// supplied (e.g. "notification.notify:hello|world"); commands with no
/// payload use the bare name.
pub const cmd_notify: []const u8 = "notification.notify";
pub const cmd_list: []const u8 = "notification.list";
pub const cmd_clear: []const u8 = "notification.clear";

/// No-op startup hook. The notification plugin has no external resources to
/// acquire before it can begin accepting commands.
pub fn start(context: *anyopaque, runtime: extensions.RuntimeContext) anyerror!void {
    _ = context;
    _ = runtime;
}

/// Frees the state owned by this module. Mirrors `create`'s allocator.
pub fn stop(context: *anyopaque, runtime: extensions.RuntimeContext) anyerror!void {
    _ = runtime;
    const self: *NotificationState = @ptrCast(@alignCast(context));
    self.deinit();
    self.allocator.destroy(self);
}

/// Routes commands by name. The payload (if any) is supplied after a `:` in
/// `cmd.name`, e.g. "notification.notify:title|message". Supported commands:
/// - `notification.notify` — payload "title|message" (splits on first '|').
///   If no '|' is present, the whole payload is the title and the message is
///   empty. Appends to the recorded list.
/// - `notification.list` — clears the recorded list (no output channel).
/// - `notification.clear` — clears the recorded list.
pub fn command(context: *anyopaque, runtime: extensions.RuntimeContext, cmd: extensions.Command) anyerror!void {
    _ = runtime;
    const self: *NotificationState = @ptrCast(@alignCast(context));

    const parsed = parseCommand(cmd.name);

    if (std.mem.eql(u8, parsed.head, cmd_notify)) {
        try appendNotification(self, parsed.payload);
        return;
    }

    if (std.mem.eql(u8, parsed.head, cmd_list) or std.mem.eql(u8, parsed.head, cmd_clear)) {
        clearNotifications(self);
        return;
    }
}

/// Splits a command string into its routing head and payload. The payload is
/// everything after the first `:`. The `:` is omitted so callers can pass
/// bare command names like "notification.notify".
fn parseCommand(raw: []const u8) struct { head: []const u8, payload: []const u8 } {
    if (std.mem.indexOfScalar(u8, raw, ':')) |index| {
        return .{ .head = raw[0..index], .payload = raw[index + 1 ..] };
    }
    return .{ .head = raw, .payload = "" };
}

fn appendNotification(self: *NotificationState, payload: []const u8) !void {
    const separator = std.mem.indexOfScalar(u8, payload, '|');
    const raw_title = if (separator) |index| payload[0..index] else payload;
    const raw_message = if (separator) |index| payload[index + 1 ..] else "";

    const title = try self.allocator.dupe(u8, raw_title);
    errdefer self.allocator.free(title);
    const message = try self.allocator.dupe(u8, raw_message);
    errdefer self.allocator.free(message);

    try self.notifications.append(self.allocator, .{
        .title = title,
        .message = message,
    });
}

fn clearNotifications(self: *NotificationState) void {
    for (self.notifications.items) |entry| {
        self.allocator.free(entry.title);
        self.allocator.free(entry.message);
    }
    self.notifications.clearRetainingCapacity();
}

/// Allocates a new `NotificationState` and wraps it in a `Module`.
/// Caller is responsible for invoking `start` and `stop`.
pub fn create(allocator: std.mem.Allocator) !extensions.Module {
    const state = try allocator.create(NotificationState);
    errdefer allocator.destroy(state);
    state.* = NotificationState.init(allocator);

    return .{
        .info = .{
            .id = ModuleId,
            .name = module_name,
            .capabilities = capabilities,
        },
        .context = @ptrCast(state),
        .hooks = .{
            .start_fn = start,
            .stop_fn = stop,
            .command_fn = command,
        },
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "notification plugin records, lists, and clears notifications" {
    const allocator = std.testing.allocator;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    const module = try create(allocator);
    try module.hooks.start_fn.?(module.context, runtime);

    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "notification.notify:hello|world",
    });
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "notification.notify:title-only",
    });
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "notification.notify:a|b|c",
    });

    const state: *NotificationState = @ptrCast(@alignCast(module.context));
    try std.testing.expectEqual(@as(usize, 3), state.notifications.items.len);
    try std.testing.expectEqualStrings("hello", state.notifications.items[0].title);
    try std.testing.expectEqualStrings("world", state.notifications.items[0].message);
    try std.testing.expectEqualStrings("title-only", state.notifications.items[1].title);
    try std.testing.expectEqualStrings("", state.notifications.items[1].message);
    try std.testing.expectEqualStrings("a", state.notifications.items[2].title);
    try std.testing.expectEqualStrings("b|c", state.notifications.items[2].message);

    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "notification.list",
    });
    try std.testing.expectEqual(@as(usize, 0), state.notifications.items.len);

    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "notification.notify:again|message",
    });
    try std.testing.expectEqual(@as(usize, 1), state.notifications.items.len);

    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "notification.clear",
    });
    try std.testing.expectEqual(@as(usize, 0), state.notifications.items.len);

    try module.hooks.stop_fn.?(module.context, runtime);
}

test "notification plugin registers with a ModuleRegistry" {
    const allocator = std.testing.allocator;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    var module = try create(allocator);
    const modules = [_]extensions.Module{module};
    var registry: extensions.ModuleRegistry = .{ .modules = &modules };

    try registry.startAll(runtime);
    try registry.dispatchCommand(runtime, .{
        .name = "notification.notify:ping|pong",
    });
    try registry.dispatchCommand(runtime, .{ .name = "notification.clear" });
    try registry.stopAll(runtime);

    // stop consumed the context; the module handle is invalidated, so drop it
    // without invoking stop_fn again.
    module.context = undefined;

    try std.testing.expect(registry.hasCapability(.custom));
}

test "notification stop frees all recorded items" {
    const allocator = std.testing.allocator;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    const module = try create(allocator);
    try module.hooks.start_fn.?(module.context, runtime);

    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "notification.notify:first|one",
    });
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "notification.notify:second|two",
    });
    try module.hooks.command_fn.?(module.context, runtime, .{
        .name = "notification.notify:third|three",
    });

    // stop releases the state and all owned strings; std.testing.allocator
    // validates there are no leaks.
    try module.hooks.stop_fn.?(module.context, runtime);
}
