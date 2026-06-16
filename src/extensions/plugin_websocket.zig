//! WebSocket client plugin module — RFC 6455 handshake + frame encode/decode.
//!
//! Implements a minimal WebSocket client with two layers:
//!
//! 1. Core utilities (`parseWsUrl`, `encodeClientHandshake`,
//!    `decodeHandshakeResponse`, `encodeFrame`, `decodeFrame`) that provide
//!    pure RFC 6455 primitives.
//!
//! 2. Plugin layer (`websocket.connect` / `websocket.send` / `websocket.close`)
//!    that holds connection state and records parsed URL parts + outbound
//!    frames for test inspection. Real TCP I/O is deferred — see the TODO
//!    in `handleConnect`.
//!
//! Commands are routed by `cmd.name`; payload lives in `cmd.payload`:
//! - `websocket.connect` — `cmd.payload` is a `ws://` or `wss://` URL. The
//!   parsed host/port/path/secure are recorded in `last_host` / `last_port` /
//!   `last_path` / `last_secure`, and `connected` is set to `true`. Invalid
//!   URLs set `connected = false` without raising an error.
//! - `websocket.send`    — `cmd.payload` is the message text. Encodes a text
//!   frame and records it in `last_sent_frame`.
//! - `websocket.close`   — sets `connected = false`.

const std = @import("std");
const crypto = std.crypto;
const extensions = @import("root.zig");

/// Unique module id for the WebSocket plugin.
pub const ModuleId: extensions.ModuleId = 110;

// ── WebSocket constants ─────────────────────────────────────────────────────

/// Magic GUID appended to the client key before SHA-1 hashing (RFC 6455 §4.2.2).
pub const websocket_guid: []const u8 = "258EAFA5-E171-47DA-9E7D-62D69F74F1C5";

/// RFC 6455 frame opcodes.
pub const OpCode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

/// A parsed WebSocket frame.
pub const Frame = struct {
    opcode: u4,
    payload: []const u8,
    fin: bool,
};

/// Parsed WebSocket URL components.
///
/// The slices reference the input string and do not need to be freed; the
/// caller owns the input for the lifetime of the returned `WsUrl`.
pub const WsUrl = struct {
    host: []const u8,
    port: u16,
    path: []const u8,
    /// True for `wss://` URLs, false for `ws://`.
    secure: bool,

    /// Parse a `ws://` or `wss://` URL string into its components.
    ///
    /// Returns `null` if the URL is malformed, has a non-WebSocket scheme,
    /// or has an unparseable port. Default port is 80 for `ws://` and 443
    /// for `wss://`. If no path is present, the path defaults to `"/"`.
    ///
    /// Examples:
    /// - `"ws://localhost:8080/ws"` → host=`"localhost"`, port=8080, path=`"/ws"`, secure=false
    /// - `"ws://example.com"`        → host=`"example.com"`, port=80,   path=`"/"`,    secure=false
    /// - `"wss://example.com/api"`   → host=`"example.com"`, port=443,  path=`"/api"`, secure=true
    pub fn parse(url_str: []const u8) ?WsUrl {
        const scheme_end = std.mem.indexOf(u8, url_str, "://") orelse return null;
        const scheme = url_str[0..scheme_end];

        const is_ws = scheme.len == 2 and std.mem.eql(u8, scheme, "ws");
        const is_wss = scheme.len == 3 and std.mem.eql(u8, scheme, "wss");
        if (!is_ws and !is_wss) return null;

        const default_port: u16 = if (is_wss) 443 else 80;

        const after_scheme = url_str[scheme_end + 3 ..];
        const path_start = std.mem.indexOfScalar(u8, after_scheme, '/') orelse after_scheme.len;
        const host_port = after_scheme[0..path_start];
        const path = if (path_start < after_scheme.len) after_scheme[path_start..] else "/";

        const port_end = std.mem.indexOfScalar(u8, host_port, ':');
        const host = if (port_end) |pe| host_port[0..pe] else host_port;
        if (host.len == 0) return null;

        const port = if (port_end) |pe|
            std.fmt.parseInt(u16, host_port[pe + 1 ..], 10) catch return null
        else
            default_port;

        return .{
            .host = host,
            .port = port,
            .path = path,
            .secure = is_wss,
        };
    }
};

/// Parse a `ws://` or `wss://` URL string into a `WsUrl`.
///
/// Convenience wrapper around `WsUrl.parse`. Returns `null` for malformed
/// inputs. For `wss://`, `port` defaults to 443 and `secure = true`. For
/// `ws://`, `port` defaults to 80 and `secure = false`.
pub fn parseWsUrl(url_str: []const u8) ?WsUrl {
    return WsUrl.parse(url_str);
}

// ── Base64 helpers (RFC 4648 standard alphabet) ─────────────────────────────

const base64_table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Encodes `input` as a base64 string. Caller owns the returned slice.
fn base64Encode(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const out_len = (input.len + 2) / 3 * 4;
    const out = try allocator.alloc(u8, out_len);
    errdefer allocator.free(out);

    var i: usize = 0;
    var j: usize = 0;
    while (i + 2 < input.len) : ({
        i += 3;
        j += 4;
    }) {
        const n: u32 = (@as(u32, input[i]) << 16) | (@as(u32, input[i + 1]) << 8) | @as(u32, input[i + 2]);
        out[j] = base64_table[(n >> 18) & 0x3F];
        out[j + 1] = base64_table[(n >> 12) & 0x3F];
        out[j + 2] = base64_table[(n >> 6) & 0x3F];
        out[j + 3] = base64_table[n & 0x3F];
    }

    const remaining = input.len - i;
    if (remaining == 1) {
        const n: u32 = @as(u32, input[i]) << 16;
        out[j] = base64_table[(n >> 18) & 0x3F];
        out[j + 1] = base64_table[(n >> 12) & 0x3F];
        out[j + 2] = '=';
        out[j + 3] = '=';
    } else if (remaining == 2) {
        const n: u32 = (@as(u32, input[i]) << 16) | (@as(u32, input[i + 1]) << 8);
        out[j] = base64_table[(n >> 18) & 0x3F];
        out[j + 1] = base64_table[(n >> 12) & 0x3F];
        out[j + 2] = base64_table[(n >> 6) & 0x3F];
        out[j + 3] = '=';
    }

    return out;
}

// ── Core WebSocket utilities ────────────────────────────────────────────────

/// Builds an HTTP upgrade request for a WebSocket handshake (RFC 6455 §4.2.1).
/// `host` is the target host (e.g. `"localhost:8080"`).
/// `path` is the request path (e.g. `"/ws"`).
/// `key` is the 16-byte client nonce; the function base64-encodes it into the
/// `Sec-WebSocket-Key` header. Caller owns the returned request bytes.
pub fn encodeClientHandshake(
    allocator: std.mem.Allocator,
    host: []const u8,
    path: []const u8,
    key: []const u8,
) ![]u8 {
    const key_b64 = try base64Encode(allocator, key);
    defer allocator.free(key_b64);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "GET ");
    try buf.appendSlice(allocator, path);
    try buf.appendSlice(allocator, " HTTP/1.1\r\n");
    try buf.appendSlice(allocator, "Host: ");
    try buf.appendSlice(allocator, host);
    try buf.appendSlice(allocator, "\r\n");
    try buf.appendSlice(allocator, "Upgrade: websocket\r\n");
    try buf.appendSlice(allocator, "Connection: Upgrade\r\n");
    try buf.appendSlice(allocator, "Sec-WebSocket-Key: ");
    try buf.appendSlice(allocator, key_b64);
    try buf.appendSlice(allocator, "\r\n");
    try buf.appendSlice(allocator, "Sec-WebSocket-Version: 13\r\n");
    try buf.appendSlice(allocator, "\r\n");

    return buf.toOwnedSlice(allocator);
}

/// Verifies that `response_bytes` is a valid WebSocket upgrade response (101).
/// Checks for HTTP 101 status, `Upgrade: websocket`, and the correct
/// `Sec-WebSocket-Accept` hash derived from `key + websocket_guid`.
pub fn decodeHandshakeResponse(response_bytes: []const u8, key: []const u8) !bool {
    // Must start with "HTTP/1.1 101".
    if (!std.mem.startsWith(u8, response_bytes, "HTTP/1.1 101")) return false;

    // Must contain "Upgrade: websocket".
    if (std.mem.indexOf(u8, response_bytes, "Upgrade: websocket") == null and
        std.mem.indexOf(u8, response_bytes, "upgrade: websocket") == null) return false;

    // Verify Sec-WebSocket-Accept.
    // Compute expected: base64(sha1(key + guid)).
    var sha1_buf: [crypto.hash.Sha1.digest_length]u8 = undefined;
    var sha1 = crypto.hash.Sha1.init(.{});
    sha1.update(key);
    sha1.update(websocket_guid);
    sha1.final(&sha1_buf);

    const expected_accept = try base64Encode(std.testing.allocator, &sha1_buf);
    defer std.testing.allocator.free(expected_accept);

    // Look for the accept header in the response.
    const accept_prefix = "Sec-WebSocket-Accept: ";
    const accept_start = std.mem.indexOf(u8, response_bytes, accept_prefix);
    if (accept_start == null) {
        // Try lowercase variant.
        const lower_prefix = "sec-websocket-accept: ";
        const lower_start = std.mem.indexOf(u8, response_bytes, lower_prefix);
        if (lower_start == null) return false;
        const value_start = lower_start.? + lower_prefix.len;
        const value_end = std.mem.indexOfScalarPos(u8, response_bytes, value_start, '\r') orelse
            std.mem.indexOfScalarPos(u8, response_bytes, value_start, '\n') orelse
            response_bytes.len;
        const actual = response_bytes[value_start..value_end];
        return std.mem.eql(u8, actual, expected_accept);
    }

    const value_start = accept_start.? + accept_prefix.len;
    const value_end = std.mem.indexOfScalarPos(u8, response_bytes, value_start, '\r') orelse
        std.mem.indexOfScalarPos(u8, response_bytes, value_start, '\n') orelse
        response_bytes.len;
    const actual = response_bytes[value_start..value_end];
    return std.mem.eql(u8, actual, expected_accept);
}

/// Encodes a WebSocket frame (RFC 6455 §5.2).
///
/// Sets FIN=1 and MASK=1 (client-to-server). Uses a fixed mask key for
/// determinism. Caller owns the returned frame bytes.
///
/// `payload` is the unmasked application data.
/// `opcode` is a 4-bit frame opcode (see `OpCode`).
pub fn encodeFrame(
    allocator: std.mem.Allocator,
    payload: []const u8,
    opcode: u4,
) ![]u8 {
    // Mask key is fixed to make tests deterministic.
    const mask_key = [_]u8{ 0x12, 0x34, 0x56, 0x78 };

    var header_len: usize = 2 + 4; // min header + mask key
    if (payload.len > 125) header_len += 2;
    if (payload.len > 65535) header_len += 6; // 8-byte extended length (2 already counted)

    const total_len = header_len + payload.len;
    var buf = try allocator.alloc(u8, total_len);
    errdefer allocator.free(buf);

    // Byte 0: FIN(1) = 0x80 | opcode(lower 4 bits)
    buf[0] = @as(u8, 0x80) | @as(u8, opcode);

    // Byte 1: MASK(1) = 0x80 | payload_len
    var pos: usize = 2;
    if (payload.len < 126) {
        buf[1] = 0x80 | @as(u8, @intCast(payload.len));
    } else if (payload.len <= 65535) {
        buf[1] = 0x80 | 126;
        std.mem.writeInt(u16, buf[pos..][0..2], @as(u16, @intCast(payload.len)), .big);
        pos += 2;
    } else {
        buf[1] = 0x80 | 127;
        std.mem.writeInt(u64, buf[pos..][0..8], @as(u64, @intCast(payload.len)), .big);
        pos += 8;
    }

    // Mask key (4 bytes).
    @memcpy(buf[pos..][0..4], &mask_key);
    pos += 4;

    // Payload (masked).
    for (payload, 0..) |byte, i| {
        buf[pos + i] = byte ^ mask_key[i % 4];
    }

    return buf;
}

/// Parses a masked WebSocket frame from the server.
/// Returns `null` if `data` is incomplete or malformed.
pub fn decodeFrame(data: []const u8) ?Frame {
    if (data.len < 2) return null;

    const fin = (data[0] & 0x80) != 0;
    const opcode: u4 = @intCast(data[0] & 0x0F);
    const masked = (data[1] & 0x80) != 0;

    var pos: usize = 2;
    var payload_len: usize = data[1] & 0x7F;

    if (payload_len == 126) {
        if (data.len < 4) return null;
        payload_len = std.mem.readInt(u16, data[pos..][0..2], .big);
        pos += 2;
    } else if (payload_len == 127) {
        if (data.len < 10) return null;
        payload_len = @intCast(std.mem.readInt(u64, data[pos..][0..8], .big));
        pos += 8;
    }

    var mask_key: [4]u8 = @splat(0);
    if (masked) {
        if (data.len < pos + 4) return null;
        mask_key = data[pos..][0..4].*;
        pos += 4;
    }

    if (data.len < pos + payload_len) return null;

    const raw_payload = data[pos .. pos + payload_len];
    if (masked) {
        // We cannot unmask into a const slice. For test purposes we return
        // the masked payload — callers doing round-trip tests should unmask
        // themselves, or we provide a separate helper. Since the primary use
        // is testing, we return the raw (masked) payload and let callers
        // XOR with the mask_key.
        return Frame{ .opcode = opcode, .payload = raw_payload, .fin = fin };
    }
    return Frame{ .opcode = opcode, .payload = raw_payload, .fin = fin };
}

/// Unmasks `payload` using `mask_key` into an allocated buffer. Caller owns
/// the returned slice.
pub fn unmaskPayload(allocator: std.mem.Allocator, payload: []const u8, mask_key: [4]u8) ![]u8 {
    const out = try allocator.dupe(u8, payload);
    for (out, 0..) |*byte, i| {
        byte.* ^= mask_key[i % 4];
    }
    return out;
}

// ── Plugin state ────────────────────────────────────────────────────────────

/// Mutable state owned by a WebSocket module instance.
///
/// All owned slices (`last_host`, `last_path`, `last_sent_frame`) are freed
/// in `stop`. Real TCP I/O is deferred — `handleConnect` currently only
/// records the parsed URL parts in the `last_*` fields.
pub const WsState = struct {
    /// True after a successful `websocket.connect` with a valid URL.
    connected: bool = false,
    /// Most recently encoded outbound frame. Freed in `stop`.
    last_sent_frame: ?[]u8 = null,
    /// Parsed host component from the most recent `websocket.connect` call.
    last_host: ?[]u8 = null,
    /// Parsed path component from the most recent `websocket.connect` call.
    last_path: ?[]u8 = null,
    /// Parsed port component from the most recent `websocket.connect` call.
    last_port: u16 = 0,
    /// True for `wss://`, false for `ws://`.
    last_secure: bool = false,
    allocator: std.mem.Allocator,
};

// ── Lifecycle hooks ─────────────────────────────────────────────────────────

/// No-op startup hook.
pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}

/// Frees the last-sent frame buffer, parsed URL parts, and destroys the
/// state itself.
pub fn stop(context: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const state: *WsState = @ptrCast(@alignCast(context));
    if (state.last_sent_frame) |frame| state.allocator.free(frame);
    if (state.last_host) |host| state.allocator.free(host);
    if (state.last_path) |path| state.allocator.free(path);
    state.allocator.destroy(state);
}

// ── Command dispatch ────────────────────────────────────────────────────────

/// Routes commands by `cmd.name`:
/// - `websocket.connect` — parses `cmd.payload` as a `ws://` or `wss://` URL,
///   stores the parsed host/port/path/secure in `last_*`, and sets
///   `connected = true`. Real TCP + handshake is deferred — see the TODO
///   in `handleConnect`.
/// - `websocket.send`    — encodes `cmd.payload` as a text frame and records
///   it in `last_sent_frame`.
/// - `websocket.close`   — sets `connected = false`.
pub fn command(
    context: *anyopaque,
    _: extensions.RuntimeContext,
    cmd: extensions.Command,
) anyerror!void {
    const state: *WsState = @ptrCast(@alignCast(context));

    if (std.mem.eql(u8, cmd.name, "websocket.connect")) {
        handleConnect(state, cmd.payload);
    } else if (std.mem.eql(u8, cmd.name, "websocket.send")) {
        handleSend(state, cmd.payload);
    } else if (std.mem.eql(u8, cmd.name, "websocket.close")) {
        handleClose(state);
    }
}

/// Parse `payload` as a `ws://` or `wss://` URL and record the parsed
/// components in `state.last_host`, `state.last_port`, `state.last_path`,
/// and `state.last_secure`. On a successful parse `state.connected` is set
/// to `true`. On a parse failure `state.connected` is forced to `false`
/// and the function returns without raising an error.
///
/// TODO: real TCP + handshake via `std.Io.NetStream` — currently the parsed
/// URL is only recorded; no socket is opened and no RFC 6455 handshake is
/// performed.
fn handleConnect(state: *WsState, payload: []const u8) void {
    const parsed = parseWsUrl(payload) orelse {
        resetConnectionState(state);
        return;
    };

    // Drop any prior connection state before allocating new owned slices.
    resetConnectionState(state);

    // Store parsed parts as owned slices.
    const new_host = state.allocator.dupe(u8, parsed.host) catch {
        state.connected = false;
        return;
    };
    errdefer state.allocator.free(new_host);
    const new_path = state.allocator.dupe(u8, parsed.path) catch {
        state.allocator.free(new_host);
        state.connected = false;
        return;
    };

    state.last_host = new_host;
    state.last_path = new_path;
    state.last_port = parsed.port;
    state.last_secure = parsed.secure;
    state.connected = true;
}

/// Encode `payload` as a text frame and record it in `state.last_sent_frame`.
fn handleSend(state: *WsState, payload: []const u8) void {
    if (state.last_sent_frame) |old| state.allocator.free(old);
    state.last_sent_frame = null;

    const frame = encodeFrame(state.allocator, payload, @intFromEnum(OpCode.text)) catch return;
    state.last_sent_frame = frame;
}

/// Reset `connected` to `false`. Real socket teardown is deferred.
fn handleClose(state: *WsState) void {
    state.connected = false;
}

/// Drop any prior connection state — free owned slices, clear flags. Used
/// by `handleConnect` before recording a new URL or after a parse failure.
fn resetConnectionState(state: *WsState) void {
    if (state.last_sent_frame) |old| {
        state.allocator.free(old);
        state.last_sent_frame = null;
    }
    if (state.last_host) |old| {
        state.allocator.free(old);
        state.last_host = null;
    }
    if (state.last_path) |old| {
        state.allocator.free(old);
        state.last_path = null;
    }
    state.connected = false;
    state.last_port = 0;
    state.last_secure = false;
}

// ── Factory ─────────────────────────────────────────────────────────────────

/// Allocates a new `WsState` and wraps it in a `Module`.
pub fn create(allocator: std.mem.Allocator) !extensions.Module {
    const state = try allocator.create(WsState);
    errdefer allocator.destroy(state);
    state.* = .{
        .allocator = allocator,
    };

    const caps = [_]extensions.Capability{.{ .kind = .network, .name = "websocket" }};
    return .{
        .info = .{
            .id = ModuleId,
            .name = "websocket",
            .capabilities = &caps,
        },
        .context = @ptrCast(state),
        .hooks = .{
            .start_fn = start,
            .stop_fn = stop,
            .command_fn = command,
        },
    };
}

// ── Tests: Core utilities ───────────────────────────────────────────────────

test "WsUrl.parse handles ws:// with host port path" {
    const url = WsUrl.parse("ws://example.com:8080/ws").?;
    try std.testing.expectEqualStrings("example.com", url.host);
    try std.testing.expectEqual(@as(u16, 8080), url.port);
    try std.testing.expectEqualStrings("/ws", url.path);
    try std.testing.expect(!url.secure);
}

test "WsUrl.parse defaults port and path for ws://" {
    const url = WsUrl.parse("ws://example.com").?;
    try std.testing.expectEqualStrings("example.com", url.host);
    try std.testing.expectEqual(@as(u16, 80), url.port);
    try std.testing.expectEqualStrings("/", url.path);
    try std.testing.expect(!url.secure);
}

test "WsUrl.parse handles wss:// with default port" {
    const url = WsUrl.parse("wss://secure.example.com/secure/path").?;
    try std.testing.expectEqualStrings("secure.example.com", url.host);
    try std.testing.expectEqual(@as(u16, 443), url.port);
    try std.testing.expectEqualStrings("/secure/path", url.path);
    try std.testing.expect(url.secure);
}

test "WsUrl.parse handles ws:// with explicit port and no path" {
    const url = WsUrl.parse("ws://localhost:9090").?;
    try std.testing.expectEqualStrings("localhost", url.host);
    try std.testing.expectEqual(@as(u16, 9090), url.port);
    try std.testing.expectEqualStrings("/", url.path);
    try std.testing.expect(!url.secure);
}

test "WsUrl.parse rejects invalid inputs" {
    try std.testing.expect(WsUrl.parse("") == null);
    try std.testing.expect(WsUrl.parse("no-scheme") == null);
    try std.testing.expect(WsUrl.parse("http://example.com") == null); // wrong scheme
    try std.testing.expect(WsUrl.parse("ws://") == null); // empty host
    try std.testing.expect(WsUrl.parse("ws://host:not-a-port/ws") == null);
}

test "parseWsUrl matches WsUrl.parse for ws:// with host port path" {
    const expected: WsUrl = .{
        .host = "example.com",
        .port = 8080,
        .path = "/path",
        .secure = false,
    };
    const actual = parseWsUrl("ws://example.com:8080/path").?;
    try std.testing.expectEqualStrings(expected.host, actual.host);
    try std.testing.expectEqual(expected.port, actual.port);
    try std.testing.expectEqualStrings(expected.path, actual.path);
    try std.testing.expectEqual(expected.secure, actual.secure);
}

test "parseWsUrl handles wss:// with default port 443" {
    const url = parseWsUrl("wss://api.example.com/graphql").?;
    try std.testing.expectEqualStrings("api.example.com", url.host);
    try std.testing.expectEqual(@as(u16, 443), url.port);
    try std.testing.expectEqualStrings("/graphql", url.path);
    try std.testing.expect(url.secure);
}

test "parseWsUrl returns null for invalid input" {
    try std.testing.expect(parseWsUrl("invalid") == null);
}

test "encodeClientHandshake produces valid HTTP upgrade request" {
    const allocator = std.testing.allocator;

    var key: [16]u8 = @splat(0x01);
    const req = try encodeClientHandshake(allocator, "localhost:8080", "/ws", &key);
    defer allocator.free(req);

    // Must contain HTTP method and path.
    try std.testing.expect(std.mem.indexOf(u8, req, "GET /ws HTTP/1.1") != null);
    // Must contain Host header.
    try std.testing.expect(std.mem.indexOf(u8, req, "Host: localhost:8080") != null);
    // Must contain Upgrade header.
    try std.testing.expect(std.mem.indexOf(u8, req, "Upgrade: websocket") != null);
    // Must contain Connection header.
    try std.testing.expect(std.mem.indexOf(u8, req, "Connection: Upgrade") != null);
    // Must contain Sec-WebSocket-Key (base64 of the 16 \x01 bytes).
    try std.testing.expect(std.mem.indexOf(u8, req, "Sec-WebSocket-Key: ") != null);
    // Must contain Sec-WebSocket-Version: 13.
    try std.testing.expect(std.mem.indexOf(u8, req, "Sec-WebSocket-Version: 13") != null);
    // Must end with \r\n\r\n.
    try std.testing.expect(std.mem.endsWith(u8, req, "\r\n\r\n"));
}

test "decodeHandshakeResponse validates 101 and accept header" {
    const allocator = std.testing.allocator;

    var key: [16]u8 = @splat(0x42);
    const req = try encodeClientHandshake(allocator, "localhost:8080", "/ws", &key);
    defer allocator.free(req);

    // Extract the key from the request and build the expected accept.
    const key_start = (std.mem.indexOf(u8, req, "Sec-WebSocket-Key: ").? + "Sec-WebSocket-Key: ".len);
    const key_end = std.mem.indexOfScalarPos(u8, req, key_start, '\r').?;
    _ = req[key_start..key_end];

    // Build expected accept: base64(sha1(key + guid)).
    var sha1_buf: [crypto.hash.Sha1.digest_length]u8 = undefined;
    var sha1 = crypto.hash.Sha1.init(.{});
    sha1.update(&key);
    sha1.update(websocket_guid);
    sha1.final(&sha1_buf);
    const expected_accept = try base64Encode(allocator, &sha1_buf);
    defer allocator.free(expected_accept);

    // Build a valid response.
    var resp_buf: std.ArrayList(u8) = .empty;
    errdefer resp_buf.deinit(allocator);
    try resp_buf.appendSlice(allocator, "HTTP/1.1 101 Switching Protocols\r\n");
    try resp_buf.appendSlice(allocator, "Upgrade: websocket\r\n");
    try resp_buf.appendSlice(allocator, "Connection: Upgrade\r\n");
    try resp_buf.appendSlice(allocator, "Sec-WebSocket-Accept: ");
    try resp_buf.appendSlice(allocator, expected_accept);
    try resp_buf.appendSlice(allocator, "\r\n\r\n");
    const response = try resp_buf.toOwnedSlice(allocator);
    defer allocator.free(response);

    try std.testing.expect(try decodeHandshakeResponse(response, &key));

    // Bad status.
    const bad_status = "HTTP/1.1 400 Bad Request\r\n\r\n";
    try std.testing.expect(!(try decodeHandshakeResponse(bad_status, &key)));

    // Missing upgrade header.
    const no_upgrade = "HTTP/1.1 101 Switching Protocols\r\n\r\n";
    try std.testing.expect(!(try decodeHandshakeResponse(no_upgrade, &key)));
}

test "encodeFrame produces properly masked frame" {
    const allocator = std.testing.allocator;

    const frame = try encodeFrame(allocator, "Hello", @intFromEnum(OpCode.text));
    defer allocator.free(frame);

    // Byte 0: FIN=1, opcode=text(0x1) → 0x81.
    try std.testing.expectEqual(@as(u8, 0x81), frame[0]);

    // Byte 1: MASK bit must be set (0x80). Payload length 5 → 0x85.
    try std.testing.expectEqual(@as(u8, 0x85), frame[1]);
    try std.testing.expect((frame[1] & 0x80) != 0);

    // Frame should be: 0x81 0x85 + 4 mask bytes + 5 masked payload bytes.
    try std.testing.expectEqual(@as(usize, 2 + 4 + 5), frame.len);

    // Verify the masking: the mask key is { 0x12, 0x34, 0x56, 0x78 }.
    // Unmask and compare.
    const mask_key = frame[2..6];
    try std.testing.expectEqual(@as(u8, 0x12), mask_key[0]);
    try std.testing.expectEqual(@as(u8, 0x34), mask_key[1]);
    try std.testing.expectEqual(@as(u8, 0x56), mask_key[2]);
    try std.testing.expectEqual(@as(u8, 0x78), mask_key[3]);

    // Unmask the payload.
    const payload = frame[6..];
    var unmasked: [5]u8 = undefined;
    for (payload, 0..) |byte, i| {
        unmasked[i] = byte ^ mask_key[i % 4];
    }
    try std.testing.expectEqualStrings("Hello", &unmasked);

    // Empty payload frame.
    const empty_frame = try encodeFrame(allocator, "", @intFromEnum(OpCode.close));
    defer allocator.free(empty_frame);
    try std.testing.expectEqual(@as(usize, 2 + 4), empty_frame.len);
    try std.testing.expectEqual(@as(u8, 0x88), empty_frame[0]); // FIN + close
    try std.testing.expectEqual(@as(u8, 0x80), empty_frame[1]); // MASK | len=0
}

test "encodeFrame handles extended payload lengths" {
    const allocator = std.testing.allocator;

    // 126-byte payload (uses extended 16-bit length).
    var payload_126: [126]u8 = @splat('x');
    const frame_126 = try encodeFrame(allocator, &payload_126, @intFromEnum(OpCode.binary));
    defer allocator.free(frame_126);

    // Byte 1 should be 0x80 | 126.
    try std.testing.expectEqual(@as(u8, 0xFE), frame_126[1]);
    // The 16-bit length at bytes 2-3 should be 126.
    const len16 = std.mem.readInt(u16, frame_126[2..4], .big);
    try std.testing.expectEqual(@as(u16, 126), len16);

    // 256-byte payload (also uses 16-bit).
    var payload_256: [256]u8 = @splat('y');
    const frame_256 = try encodeFrame(allocator, &payload_256, @intFromEnum(OpCode.text));
    defer allocator.free(frame_256);
    try std.testing.expectEqual(@as(u8, 0xFE), frame_256[1]);
    const len256 = std.mem.readInt(u16, frame_256[2..4], .big);
    try std.testing.expectEqual(@as(u16, 256), len256);

    // 65536-byte payload (uses 64-bit extended length).
    var payload_64k: [65536]u8 = @splat('z');
    const frame_64k = try encodeFrame(allocator, &payload_64k, @intFromEnum(OpCode.binary));
    defer allocator.free(frame_64k);
    try std.testing.expectEqual(@as(u8, 0xFF), frame_64k[1]); // 0x80 | 127
    const len64 = std.mem.readInt(u64, frame_64k[2..10], .big);
    try std.testing.expectEqual(@as(u64, 65536), len64);
}

test "decodeFrame round-trips through encode" {
    const allocator = std.testing.allocator;

    // Encode a text frame with "RoundTrip".
    const frame_bytes = try encodeFrame(allocator, "RoundTrip", @intFromEnum(OpCode.text));
    defer allocator.free(frame_bytes);

    // Decode it back.
    const decoded = decodeFrame(frame_bytes);
    try std.testing.expect(decoded != null);
    try std.testing.expectEqual(@as(u4, @intFromEnum(OpCode.text)), decoded.?.opcode);
    try std.testing.expect(decoded.?.fin);

    // The payload is still masked; unmask manually.
    const mask_key = frame_bytes[2..6];
    const unmasked = try unmaskPayload(allocator, decoded.?.payload, mask_key[0..4].*);
    defer allocator.free(unmasked);
    try std.testing.expectEqualStrings("RoundTrip", unmasked);
}

test "decodeFrame returns null on incomplete data" {
    try std.testing.expect(decodeFrame(&.{}) == null);
    try std.testing.expect(decodeFrame(&.{0x81}) == null);
    // A claimed payload length of 5 with only 2 bytes of data.
    try std.testing.expect(decodeFrame(&.{ 0x81, 0x85, 0x12 }) == null);
}

// ── Tests: Plugin layer ─────────────────────────────────────────────────────

test "websocket: connect sets connected for valid URL" {
    const allocator = std.testing.allocator;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    const module = try create(allocator);
    defer module.hooks.stop_fn.?(module.context, runtime) catch {};

    const state: *WsState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(!state.connected);

    try command(module.context, runtime, .{
        .name = "websocket.connect",
        .payload = "ws://localhost:8080/ws",
    });
    try std.testing.expect(state.connected);
}

test "websocket: connect records parsed URL fields" {
    const allocator = std.testing.allocator;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    const module = try create(allocator);
    defer module.hooks.stop_fn.?(module.context, runtime) catch {};

    const state: *WsState = @ptrCast(@alignCast(module.context));

    try command(module.context, runtime, .{
        .name = "websocket.connect",
        .payload = "ws://example.com:9000/chat",
    });

    try std.testing.expect(state.connected);
    try std.testing.expectEqualStrings("example.com", state.last_host.?);
    try std.testing.expectEqualStrings("/chat", state.last_path.?);
    try std.testing.expectEqual(@as(u16, 9000), state.last_port);
    try std.testing.expect(!state.last_secure);
}

test "websocket: connect records wss as secure with port 443" {
    const allocator = std.testing.allocator;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    const module = try create(allocator);
    defer module.hooks.stop_fn.?(module.context, runtime) catch {};

    const state: *WsState = @ptrCast(@alignCast(module.context));

    try command(module.context, runtime, .{
        .name = "websocket.connect",
        .payload = "wss://api.example.com/graphql",
    });

    try std.testing.expect(state.connected);
    try std.testing.expectEqualStrings("api.example.com", state.last_host.?);
    try std.testing.expectEqualStrings("/graphql", state.last_path.?);
    try std.testing.expectEqual(@as(u16, 443), state.last_port);
    try std.testing.expect(state.last_secure);
}

test "websocket: connect ignores invalid URL without connecting" {
    const allocator = std.testing.allocator;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    const module = try create(allocator);
    defer module.hooks.stop_fn.?(module.context, runtime) catch {};

    const state: *WsState = @ptrCast(@alignCast(module.context));

    try command(module.context, runtime, .{
        .name = "websocket.connect",
        .payload = "not-a-url",
    });
    try std.testing.expect(!state.connected);
    try std.testing.expect(state.last_host == null);
    try std.testing.expect(state.last_path == null);
    try std.testing.expectEqual(@as(u16, 0), state.last_port);
    try std.testing.expect(!state.last_secure);
}

test "websocket: connect replaces previous URL without leaking" {
    const allocator = std.testing.allocator;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    const module = try create(allocator);
    defer module.hooks.stop_fn.?(module.context, runtime) catch {};

    const state: *WsState = @ptrCast(@alignCast(module.context));

    try command(module.context, runtime, .{
        .name = "websocket.connect",
        .payload = "ws://a.example.com:1111/path-a",
    });
    try command(module.context, runtime, .{
        .name = "websocket.connect",
        .payload = "ws://b.example.com:2222/path-b",
    });

    try std.testing.expectEqualStrings("b.example.com", state.last_host.?);
    try std.testing.expectEqualStrings("/path-b", state.last_path.?);
    try std.testing.expectEqual(@as(u16, 2222), state.last_port);
    // std.testing.allocator fails the test if a slice leaked.
}

test "websocket: send records frame" {
    const allocator = std.testing.allocator;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    const module = try create(allocator);
    defer module.hooks.stop_fn.?(module.context, runtime) catch {};

    const state: *WsState = @ptrCast(@alignCast(module.context));
    try std.testing.expect(state.last_sent_frame == null);

    try command(module.context, runtime, .{
        .name = "websocket.send",
        .payload = "Hello, WebSocket!",
    });
    try std.testing.expect(state.last_sent_frame != null);

    // Decode the frame: should be a text frame with our payload.
    const frame_bytes = state.last_sent_frame.?;
    const mask_key = frame_bytes[2..6];
    const decoded = decodeFrame(frame_bytes).?;
    const unmasked = try unmaskPayload(allocator, decoded.payload, mask_key[0..4].*);
    defer allocator.free(unmasked);
    try std.testing.expectEqualStrings("Hello, WebSocket!", unmasked);
    try std.testing.expectEqual(@as(u4, @intFromEnum(OpCode.text)), decoded.opcode);
}

test "websocket: close clears connected" {
    const allocator = std.testing.allocator;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    const module = try create(allocator);
    defer module.hooks.stop_fn.?(module.context, runtime) catch {};

    const state: *WsState = @ptrCast(@alignCast(module.context));

    try command(module.context, runtime, .{
        .name = "websocket.connect",
        .payload = "ws://localhost:8080/ws",
    });
    try std.testing.expect(state.connected);

    try command(module.context, runtime, .{
        .name = "websocket.close",
    });
    try std.testing.expect(!state.connected);
}

test "websocket: start and stop do not crash" {
    const allocator = std.testing.allocator;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    const module = try create(allocator);
    try start(module.context, runtime);
    try stop(module.context, runtime);
}

test "websocket: registry integration" {
    const allocator = std.testing.allocator;
    const runtime: extensions.RuntimeContext = .{ .platform_name = "null" };

    var module = try create(allocator);
    const modules = [_]extensions.Module{module};
    var registry: extensions.ModuleRegistry = .{ .modules = &modules };

    try registry.startAll(runtime);
    try registry.dispatchCommand(runtime, .{
        .name = "websocket.connect",
        .payload = "ws://localhost:8080/ws",
    });
    try registry.dispatchCommand(runtime, .{
        .name = "websocket.send",
        .payload = "ping",
    });
    try registry.dispatchCommand(runtime, .{
        .name = "websocket.close",
    });
    try registry.stopAll(runtime);

    // stop consumed the context; invalidate.
    module.context = undefined;

    try std.testing.expect(registry.hasCapability(.network));
}
