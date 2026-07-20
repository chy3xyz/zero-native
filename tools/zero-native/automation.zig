const std = @import("std");
const protocol = @import("automation_protocol");

const automation_dir = protocol.default_dir;

pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    if (args.len == 0) return usage();
    const command = args[0];
    if (std.mem.eql(u8, command, "list")) {
        try printFile(io, "windows.txt");
    } else if (std.mem.eql(u8, command, "snapshot")) {
        try printFile(io, "snapshot.txt");
    } else if (std.mem.eql(u8, command, "screenshot")) {
        std.debug.print("screenshot capture is not available for this backend\n", .{});
        return error.UnsupportedCommand;
    } else if (std.mem.eql(u8, command, "reload")) {
        try sendCommand(allocator, io, "reload", "");
    } else if (std.mem.eql(u8, command, "wait")) {
        try waitForFile(allocator, io, "snapshot.txt", "ready=true");
    } else if (std.mem.eql(u8, command, "bridge")) {
        if (args.len < 2) return usage();
        deleteAutomationFile(io, "bridge-response.txt");
        try sendCommand(allocator, io, "bridge", args[1]);
        try waitForFile(allocator, io, "bridge-response.txt", "");
    } else if (std.mem.eql(u8, command, "record")) {
        const path = if (args.len > 1) args[1] else "session.vcr";
        try recordSession(allocator, io, path);
    } else if (std.mem.eql(u8, command, "replay")) {
        if (args.len < 2) return usage();
        try replaySession(allocator, io, args[1]);
    } else {
        return usage();
    }
}

fn usage() void {
    std.debug.print(
        \\usage: zero-native automate <command>
        \\
        \\commands:
        \\  list               show open windows
        \\  snapshot            print current frame snapshot
        \\  screenshot          capture screenshot (not yet available)
        \\  reload              trigger a page reload
        \\  wait                wait for next frame
        \\  bridge <json>       send a bridge command
        \\  record [path]       record frames to a VCR session file
        \\  replay <path>       replay a VCR session and verify
        \\
    , .{});
}

fn sendCommand(allocator: std.mem.Allocator, io: std.Io, action: []const u8, value: []const u8) !void {
    const buffer = try allocator.alloc(u8, protocol.max_command_bytes);
    defer allocator.free(buffer);
    const line = try protocol.commandLine(action, value, buffer);
    try std.Io.Dir.cwd().createDirPath(io, automation_dir);
    var command_path: [256]u8 = undefined;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = pathBuf(&command_path, "command.txt"), .data = line });
    std.debug.print("queued {s}\n", .{action});
}

fn printFile(io: std.Io, name: []const u8) !void {
    var file_path: [256]u8 = undefined;
    const bytes = readFile(std.heap.page_allocator, io, pathBuf(&file_path, name)) catch return fail("no app connected");
    defer std.heap.page_allocator.free(bytes);
    std.debug.print("{s}", .{bytes});
}

fn waitForFile(allocator: std.mem.Allocator, io: std.Io, name: []const u8, marker: []const u8) !void {
    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        var file_path: [256]u8 = undefined;
        const bytes = readFile(allocator, io, pathBuf(&file_path, name)) catch {
            try std.Io.sleep(io, std.Io.Duration.fromNanoseconds(100 * std.time.ns_per_ms), .awake);
            continue;
        };
        if (marker.len == 0 or std.mem.indexOf(u8, bytes, marker) != null) {
            std.debug.print("{s}", .{bytes});
            allocator.free(bytes);
            return;
        }
        allocator.free(bytes);
        try std.Io.sleep(io, std.Io.Duration.fromNanoseconds(100 * std.time.ns_per_ms), .awake);
    }
    return fail("timed out waiting for automation");
}

fn deleteAutomationFile(io: std.Io, name: []const u8) void {
    var file_path: [256]u8 = undefined;
    std.Io.Dir.cwd().deleteFile(io, pathBuf(&file_path, name)) catch {};
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
}

fn pathBuf(buffer: []u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ automation_dir, name }) catch unreachable;
}

fn fail(message: []const u8) error{AutomationCommandFailed} {
    std.debug.print("error: {s}\n", .{message});
    return error.AutomationCommandFailed;
}

fn recordSession(allocator: std.mem.Allocator, io: std.Io, recording_path: []const u8) !void {
    std.debug.print("Recording automation session to {s}\n", .{recording_path});
    std.debug.print("Send bridge commands and frame events will be captured.\n", .{});
    std.debug.print("Press Ctrl+C to stop recording.\n", .{});

    var frame_idx: u64 = 0;
    var session_file = try std.Io.Dir.cwd().createFile(io, recording_path, .{});
    defer session_file.close(io);

    while (true) {
        // Wait for the next snapshot
        waitForFile(allocator, io, "snapshot.txt", "ready=true") catch break;

        // Read the snapshot to get frame data
        var snap_path: [256]u8 = undefined;
        const snap = readFile(allocator, io, pathBuf(&snap_path, "snapshot.txt")) catch continue;
        defer allocator.free(snap);

        // Extract frame number and command count
        const frame_str = extractField(snap, "frame=") orelse "?";
        const cmd_str = extractField(snap, "commands=") orelse "?";

        frame_idx += 1;
        var line: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "F {s} {s} 0000000000000000\n", .{ frame_str, cmd_str });
        var write_buf: [128]u8 = undefined;
        var writer = session_file.writer(io, &write_buf);
        writer.interface.writeAll(text) catch break;

        try std.Io.sleep(io, std.Io.Duration.fromNanoseconds(500 * std.time.ns_per_ms), .awake);
    }
}

fn replaySession(allocator: std.mem.Allocator, io: std.Io, session_path: []const u8) !void {
    const raw = readFile(allocator, io, session_path) catch return fail("cannot read session file");
    defer allocator.free(raw);

    std.debug.print("Replaying session from {s} ({d} bytes)\n", .{ session_path, raw.len });

    var lines = std.mem.splitScalar(u8, raw, '\n');
    var passed: usize = 0;
    var failed: usize = 0;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (trimmed[0] == 'B' and trimmed.len > 1 and trimmed[1] == ' ') {
            const payload = trimmed[2..];
            deleteAutomationFile(io, "bridge-response.txt");
            try sendCommand(allocator, io, "bridge", payload);
            waitForFile(allocator, io, "bridge-response.txt", "") catch {
                std.debug.print("  FAIL bridge {s}\n", .{payload});
                failed += 1;
                continue;
            };
            passed += 1;
            std.debug.print("  OK   bridge\n", .{});
        } else if (trimmed[0] == 'F') {
            waitForFile(allocator, io, "snapshot.txt", "ready=true") catch {
                std.debug.print("  FAIL frame (timeout)\n", .{});
                failed += 1;
                continue;
            };
            passed += 1;
            std.debug.print("  OK   frame\n", .{});
        }
    }

    std.debug.print("\n{d} passed, {d} failed\n", .{ passed, failed });
    if (failed > 0) return fail("some steps failed");
}

fn extractField(text: []const u8, field: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, field) orelse return null;
    const value_start = start + field.len;
    const end = std.mem.indexOfScalarPos(u8, text, value_start, ' ') orelse
        std.mem.indexOfScalarPos(u8, text, value_start, '\n') orelse
        text.len;
    return text[value_start..end];
}
