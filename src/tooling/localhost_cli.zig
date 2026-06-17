//! `zero-native localhost` — ephemeral OAuth callback server.
//!
//! Starts an HTTP server on `127.0.0.1:<port>` (default 0 = random ephemeral
//! port), captures the first GET request path, and writes it to stdout as a
//! JSON object `{ "port": 12345, "path": "/callback?code=..." }`.
//!
//! The server exits after the first request or after a timeout (default
//! 5 minutes). This mirrors the behavior of `tauri-plugin-localhost` used
//! for OAuth PKCE redirects.

const std = @import("std");

const LocalhostOptions = struct {
    port: u16 = 0,
    timeout_ms: u32 = 5 * 60 * 1000,
    output_json: bool = true,
};

fn usage() void {
    std.debug.print(
        \\\usage: zero-native localhost [--port N] [--timeout-ms N] [--text]
        \\
        \\\Starts an HTTP server on 127.0.0.1 and prints the first captured GET
        \\\request path. Defaults to a random port and 5-minute timeout.
        \\
    , .{});
}

/// Run the callback server. Returns the captured path as an owned string,
/// or null if the timeout expired before any request arrived.
///
/// If `options.port` is non-zero, that exact port is used. If it is zero,
/// the implementation scans the ephemeral range 12000-12199 and binds to
/// the first free port, then reports the chosen port.
pub fn run(io: std.Io, allocator: std.mem.Allocator, options: LocalhostOptions) !?[]u8 {
    const port = if (options.port != 0)
        options.port
    else
        try findFreePort(io, 12000, 12199);

    const addr = try std.Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var listener = try addr.listen(io, .{ .mode = .stream });
    defer listener.deinit(io);

    _ = &listener;

    if (options.output_json) {
        std.debug.print("{{\"port\":{d}}}\n", .{port});
    } else {
        std.debug.print("listening on http://127.0.0.1:{d}/\n", .{port});
    }

    var remaining_ms: i64 = options.timeout_ms;
    while (remaining_ms > 0) {
        const conn = listener.accept(io) catch |err| switch (err) {
            error.WouldBlock => {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
                remaining_ms -= 50;
                continue;
            },
            error.Canceled => return null,
            else => {
                std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
                remaining_ms -= 50;
                continue;
            },
        };
        defer conn.close(io);

        var buffer: [4096]u8 = undefined;
        var iovec: [1][]u8 = .{buffer[0..]};
        const read_size = conn.read(io, &iovec) catch continue;
        if (read_size == 0) continue;

        const request = buffer[0..read_size];
        const path = parseGetPath(request) orelse continue;

        // Respond with a friendly HTML page.
        const response =
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/html; charset=utf-8\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "<html><body>Authorization complete. You may close this window.</body></html>";
        var write_buffer: [512]u8 = undefined;
        var net_writer = conn.writer(io, &write_buffer);
        _ = net_writer.interface.writeAll(response) catch {};

        if (options.output_json) {
            const out = try std.fmt.allocPrint(allocator, "{{\"port\":{d},\"path\":\"{s}\"}}\n", .{ port, path });
            return out;
        } else {
            const owned = try allocator.dupe(u8, path);
            return owned;
        }
    }

    return null;
}

fn findFreePort(io: std.Io, start: u16, end: u16) !u16 {
    var port: u16 = start;
    while (port <= end) : (port += 1) {
        const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch continue;
        if (addr.listen(io, .{ .mode = .stream })) |scan_listener| {
            var owned_listener = scan_listener;
            owned_listener.deinit(io);
            return port;
        } else |_| {
            continue;
        }
    }
    return error.NoFreePort;
}

fn parseGetPath(request: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, request, "GET ")) return null;
    const after_get = request[4..];
    const end = std.mem.indexOf(u8, after_get, " HTTP/1.") orelse return null;
    return after_get[0..end];
}

/// CLI entry point used by `tools/zero-native/main.zig`.
/// Returns an exit code (0 = captured, 1 = timeout/error).
pub fn runCli(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) u8 {
    var port: u16 = 0;
    var timeout_ms: u32 = 5 * 60 * 1000;
    var output_json = true;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return 0;
        } else if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("missing value for --port\n", .{});
                return 2;
            }
            port = std.fmt.parseUnsigned(u16, args[i], 10) catch {
                std.debug.print("invalid --port value: {s}\n", .{args[i]});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--timeout-ms")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("missing value for --timeout-ms\n", .{});
                return 2;
            }
            timeout_ms = std.fmt.parseUnsigned(u32, args[i], 10) catch {
                std.debug.print("invalid --timeout-ms value: {s}\n", .{args[i]});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--text")) {
            output_json = false;
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            return 2;
        }
    }

    const result = run(io, allocator, .{
        .port = port,
        .timeout_ms = timeout_ms,
        .output_json = output_json,
    }) catch |err| {
        std.debug.print("server failed: {t}\n", .{err});
        return 1;
    };

    if (result) |path| {
        defer allocator.free(path);
        std.debug.print("{s}", .{path});
        return 0;
    } else {
        std.debug.print("timeout: no callback received within {d} ms\n", .{timeout_ms});
        return 1;
    }
}

test "parseGetPath extracts path from GET line" {
    const req = "GET /callback?code=abc&state=xyz HTTP/1.1\r\nHost: localhost\r\n\r\n";
    const path = parseGetPath(req).?;
    try std.testing.expectEqualStrings("/callback?code=abc&state=xyz", path);
}
