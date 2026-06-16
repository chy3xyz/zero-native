const std = @import("std");
const json = @import("json");

/// Identifies a stream across the bridge.
pub const StreamId = u64;

/// Kinds of frames that can be sent over a streaming channel.
pub const FrameKind = enum { value, end };

/// Returns a JSON string suitable for delivery through the bridge.
/// Caller owns the returned slice and must free with the same allocator.
pub fn encodeFrame(allocator: std.mem.Allocator, id: StreamId, kind: FrameKind, payload_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"stream\":{d},\"kind\":\"{s}\",\"payload\":{s}}}", .{ id, @tagName(kind), payload_json });
}

/// Generic typed streaming channel.
///
/// Supports `i32`, `i64`, `u32`, `u64`, `f32`, `f64`, `bool`, and `[]const u8` payloads.
/// More complex types are not yet supported because Zig 0.17-dev does not have a stable
/// `std.json.stringify`; callers should serialize to a JSON string themselves and then
/// use the underlying `encodeFrame` + writer directly.
pub fn Channel(comptime T: type) type {
    return struct {
        const Writer = *const fn (ctx: *anyopaque, frame_json: []const u8) anyerror!void;

        id: StreamId,
        writer: Writer,
        writer_ctx: *anyopaque,
        allocator: std.mem.Allocator,
        _closed: bool = false,

        /// Send a `T` value as a value frame.
        /// Uses `std.fmt.bufPrint` to serialize T into a tight JSON payload.
        /// If serialization fails, the frame is NOT sent and the error is returned.
        pub fn send(self: *@This(), value: T) !void {
            if (self._closed) return;

            var payload_buffer: [256]u8 = undefined;
            const payload_json = try serializeValue(T, &payload_buffer, value);

            const frame = try encodeFrame(self.allocator, self.id, .value, payload_json);
            defer self.allocator.free(frame);

            self.writer(self.writer_ctx, frame) catch |err| {
                return err;
            };
        }

        /// Close the stream by sending an end frame (idempotent).
        pub fn close(self: *@This()) !void {
            if (self._closed) return;
            self._closed = true;

            const frame = try encodeFrame(self.allocator, self.id, .end, "\"\"");
            defer self.allocator.free(frame);

            self.writer(self.writer_ctx, frame) catch |err| {
                return err;
            };
        }

        /// True if `close` has not been called.
        pub fn isOpen(self: *@This()) bool {
            return !self._closed;
        }
    };
}

/// Serializes `value` of type `T` into a JSON scalar.
/// Works with integers, floats, bools, and byte slices.
fn serializeValue(comptime T: type, buffer: []u8, value: T) ![]const u8 {
    switch (@typeInfo(T)) {
        .Int, .ComptimeInt => {
            return std.fmt.bufPrint(buffer, "{d}", .{value});
        },
        .Float, .ComptimeFloat => {
            return std.fmt.bufPrint(buffer, "{d}", .{value});
        },
        .Bool => {
            return if (value) "true" else "false";
        },
        .Pointer => |ptr| {
            if (ptr.size == .Slice and ptr.child == u8) {
                var writer = std.Io.Writer.fixed(buffer);
                try json.writeString(&writer, value);
                return writer.buffered();
            }
            @compileError("Channel payload type " ++ @typeName(T) ++ " is not supported. Use i32/i64/u32/u64/f32/f64/bool/[]const u8.");
        },
        else => @compileError("Channel payload type " ++ @typeName(T) ++ " is not supported. Use i32/i64/u32/u64/f32/f64/bool/[]const u8."),
    }
}

// --------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------

test "channel module" {
    const TestSink = struct {
        frames: std.ArrayList([]u8),
        allocator: std.mem.Allocator,

        fn write(ctx: *anyopaque, frame_json: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const copy = try self.allocator.dupe(u8, frame_json);
            try self.frames.append(copy);
        }
    };

    // 1. encodeFrame produces valid JSON with the right fields.
    {
        const frame = try encodeFrame(std.testing.allocator, 0, .value, "42");
        defer std.testing.allocator.free(frame);
        try std.testing.expectEqualStrings(
            "{\"stream\":0,\"kind\":\"value\",\"payload\":42}",
            frame,
        );
    }

    {
        const frame = try encodeFrame(std.testing.allocator, 7, .end, "\"\"");
        defer std.testing.allocator.free(frame);
        try std.testing.expectEqualStrings(
            "{\"stream\":7,\"kind\":\"end\",\"payload\":\"\"}",
            frame,
        );
    }

    // 2. Channel(i32).send(42) → writer receives a value frame.
    {
        var sink = TestSink{
            .frames = std.ArrayList([]u8).init(std.testing.allocator),
            .allocator = std.testing.allocator,
        };
        defer {
            for (sink.frames.items) |f| std.testing.allocator.free(f);
            sink.frames.deinit();
        }

        var channel: Channel(i32) = .{
            .id = 1,
            .writer = TestSink.write,
            .writer_ctx = &sink,
            .allocator = std.testing.allocator,
        };
        try channel.send(42);

        try std.testing.expectEqual(@as(usize, 1), sink.frames.items.len);
        try std.testing.expectEqualStrings(
            "{\"stream\":1,\"kind\":\"value\",\"payload\":42}",
            sink.frames.items[0],
        );
        try std.testing.expect(channel.isOpen());
    }

    // 3. Multiple sends produce separate frames.
    {
        var sink = TestSink{
            .frames = std.ArrayList([]u8).init(std.testing.allocator),
            .allocator = std.testing.allocator,
        };
        defer {
            for (sink.frames.items) |f| std.testing.allocator.free(f);
            sink.frames.deinit();
        }

        var channel: Channel(i32) = .{
            .id = 2,
            .writer = TestSink.write,
            .writer_ctx = &sink,
            .allocator = std.testing.allocator,
        };
        try channel.send(10);
        try channel.send(20);
        try channel.send(30);

        try std.testing.expectEqual(@as(usize, 3), sink.frames.items.len);
        try std.testing.expectEqualStrings(
            "{\"stream\":2,\"kind\":\"value\",\"payload\":10}",
            sink.frames.items[0],
        );
        try std.testing.expectEqualStrings(
            "{\"stream\":2,\"kind\":\"value\",\"payload\":20}",
            sink.frames.items[1],
        );
        try std.testing.expectEqualStrings(
            "{\"stream\":2,\"kind\":\"value\",\"payload\":30}",
            sink.frames.items[2],
        );
    }

    // 4. close → writer receives an end frame.
    {
        var sink = TestSink{
            .frames = std.ArrayList([]u8).init(std.testing.allocator),
            .allocator = std.testing.allocator,
        };
        defer {
            for (sink.frames.items) |f| std.testing.allocator.free(f);
            sink.frames.deinit();
        }

        var channel: Channel(i32) = .{
            .id = 3,
            .writer = TestSink.write,
            .writer_ctx = &sink,
            .allocator = std.testing.allocator,
        };
        try channel.send(1);
        try channel.close();

        try std.testing.expectEqual(@as(usize, 2), sink.frames.items.len);
        try std.testing.expectEqualStrings(
            "{\"stream\":3,\"kind\":\"end\",\"payload\":\"\"}",
            sink.frames.items[1],
        );
        try std.testing.expect(!channel.isOpen());
    }

    // 5. close twice → exactly one end frame.
    {
        var sink = TestSink{
            .frames = std.ArrayList([]u8).init(std.testing.allocator),
            .allocator = std.testing.allocator,
        };
        defer {
            for (sink.frames.items) |f| std.testing.allocator.free(f);
            sink.frames.deinit();
        }

        var channel: Channel(i32) = .{
            .id = 4,
            .writer = TestSink.write,
            .writer_ctx = &sink,
            .allocator = std.testing.allocator,
        };
        try channel.close();
        try channel.close();

        // Only one end frame.
        var end_count: usize = 0;
        for (sink.frames.items) |f| {
            if (std.mem.indexOf(u8, f, "\"kind\":\"end\"") != null) end_count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), end_count);
        try std.testing.expectEqual(@as(usize, 1), sink.frames.items.len);
        try std.testing.expect(!channel.isOpen());
    }

    // 6. isOpen reflects state.
    {
        var sink = TestSink{
            .frames = std.ArrayList([]u8).init(std.testing.allocator),
            .allocator = std.testing.allocator,
        };
        defer {
            for (sink.frames.items) |f| std.testing.allocator.free(f);
            sink.frames.deinit();
        }

        var channel: Channel(i32) = .{
            .id = 5,
            .writer = TestSink.write,
            .writer_ctx = &sink,
            .allocator = std.testing.allocator,
        };
        try std.testing.expect(channel.isOpen());
        try channel.close();
        try std.testing.expect(!channel.isOpen());
        try channel.close();
        try std.testing.expect(!channel.isOpen());
    }
}
