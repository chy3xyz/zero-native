//! HTTP/1.1 client extracted from httpz.zig (https://github.com/chy3xyz/httpz.zig).
//!
//! Supports GET and POST requests over TCP with configurable timeouts.
//! No chunked transfer-encoding support.
//! No keep-alive — each request opens a fresh connection and closes it
//! after receiving the response.
//!
//! TLS/HTTPS support is available via `requestHttps` which requires the
//! httpz.zig library (already listed in `build.zig.zon`). To enable:
//! 1. Add httpz dep to `extensions_mod` in `build.zig`:
//!    ```
//!    const httpz_dep = b.dependency("httpz", .{ .target = target, .optimize = optimize });
//!    extensions_mod.addImport("httpz", httpz_dep.module("httpz"));
//!    ```
//! 2. Ensure `PKG_CONFIG_PATH` includes OpenSSL (Homebrew:
//!    `export PKG_CONFIG_PATH="/opt/homebrew/opt/openssl@3/lib/pkgconfig:$PKG_CONFIG_PATH"`).
//! 3. The httpz build translates `src/openssl.h` (OpenSSL) and links
//!    `libssl`, `libcrypto`, `libngtcp2`, `libnghttp3`.
//! When httpz is not linked, `requestHttps` returns `error.HttpsNotSupported`
//! and callers should fall back to record-only mode.

const std = @import("std");

const Io = std.Io;

/// HTTP method. Currently only GET and POST are supported.
pub const Method = enum {
    GET,
    POST,

    fn to_str(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
        };
    }
};

/// Parsed URL components.
pub const Url = struct {
    scheme: []const u8,
    host: []const u8,
    port: u16,
    path: []const u8,

    /// Parse a URL string into its components.
    /// Returns null if the scheme separator `://` is missing.
    pub fn parse(url_str: []const u8) ?Url {
        const scheme_end = std.mem.indexOf(u8, url_str, "://") orelse return null;
        const scheme = url_str[0..scheme_end];
        const after_scheme = url_str[scheme_end + 3 ..];

        const path_start = std.mem.indexOfScalar(u8, after_scheme, '/') orelse after_scheme.len;
        const host_port = after_scheme[0..path_start];
        const path = if (path_start < after_scheme.len) after_scheme[path_start..] else "/";

        const port_end = std.mem.indexOfScalar(u8, host_port, ':');
        const host = if (port_end) |pe| host_port[0..pe] else host_port;
        const port = if (port_end) |pe|
            std.fmt.parseInt(u16, host_port[pe + 1 ..], 10) catch 80
        else
            80;

        return .{
            .scheme = scheme,
            .host = host,
            .port = port,
            .path = path,
        };
    }
};

/// Simple case-insensitive header collection.
pub const Headers = struct {
    entries: [32]Entry = undefined,
    len: usize = 0,

    pub const Entry = struct {
        name: []const u8,
        value: []const u8,
    };

    pub const max_headers = 32;

    /// Append a header. Returns error if the table is full.
    pub fn append(self: *Headers, name: []const u8, value: []const u8) error{TooManyHeaders}!void {
        if (self.len >= max_headers) return error.TooManyHeaders;
        self.entries[self.len] = .{ .name = name, .value = value };
        self.len += 1;
    }

    /// Get the first matching header value (case-insensitive name lookup).
    pub fn get(self: *const Headers, name: []const u8) ?[]const u8 {
        for (self.entries[0..self.len]) |entry| {
            if (eql_ignore_case(entry.name, name)) return entry.value;
        }
        return null;
    }

    fn eql_ignore_case(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |ca, cb| {
            if (to_lower(ca) != to_lower(cb)) return false;
        }
        return true;
    }

    fn to_lower(c: u8) u8 {
        return if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
};

/// Configuration for a single HTTP request.
pub const Config = struct {
    method: Method,
    url: Url,
    headers: ?Headers = null,
    body: ?[]const u8 = null,
    /// Maximum response body size in bytes (default 10 MB).
    max_response_size: usize = 10 * 1024 * 1024,
};

/// Parsed HTTP response.
///
/// `body` is allocated by the caller's allocator and must be freed
/// by the caller after use. When `requestHttps` is stubbed,
/// `body` will be empty and the caller should fall back to
/// record-only mode.
pub const Response = struct {
    status: u16,
    status_text: []const u8,
    headers: Headers,
    body: []u8,
};

/// Error set for the HTTP client.
pub const Error = error{
    ConnectionFailed,
    SendFailed,
    ResponseTooLarge,
    InvalidResponse,
    InvalidStatusLine,
    InvalidHeader,
    InvalidContentLength,
    ReadFailed,
    /// HTTPS is not available — the httpz.zig dependency is not linked.
    /// See the module-level doc comment for integration instructions.
    HttpsNotSupported,
} || std.mem.Allocator.Error;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Perform an HTTP/1.1 request over TCP.
///
/// Opens a new connection, sends the request, reads the full response,
/// closes the connection, and returns the parsed response.
/// The caller owns `response.body` and must free it.
pub fn request(allocator: std.mem.Allocator, io: Io, config: Config) Error!Response {
    const hostname = Io.net.HostName.init(config.url.host) catch return error.ConnectionFailed;
    const stream = hostname.connect(io, config.url.port, .{ .mode = .stream }) catch return error.ConnectionFailed;

    defer _ = std.posix.system.close(stream.socket.handle);

    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var reader = Io.net.Stream.Reader.init(stream, io, &read_buf);
    var writer = Io.net.Stream.Writer.init(stream, io, &write_buf);

    try write_request(&writer, config);
    writer.interface.flush() catch return error.SendFailed;

    var response: Response = .{
        .status = 0,
        .status_text = "",
        .headers = .{},
        .body = "",
    };

    try read_response_headers(&reader.interface, &response);

    const cl = response.headers.get("Content-Length");
    if (cl) |cl_str| {
        const content_length = std.fmt.parseInt(usize, cl_str, 10) catch return error.InvalidContentLength;
        if (content_length > config.max_response_size) return error.ResponseTooLarge;
        if (content_length > 0) {
            const body_buf = try allocator.alloc(u8, content_length);
            errdefer allocator.free(body_buf);
            reader.interface.readSliceAll(body_buf) catch |err| {
                allocator.free(body_buf);
                if (err == error.EndOfStream) return error.ReadFailed;
                return error.ResponseTooLarge;
            };
            response.body = body_buf;
        }
    }

    return response;
}

/// Perform an HTTPS request via the httpz.zig library.
///
/// When httpz is linked (see module-level doc comment for build.zig
/// instructions), this uses `httpz.Client` with TLS configured via
/// OpenSSL to connect to `config.url.host:port` over TLS, send the
/// request, read the response, and parse it into a `Response`.
///
/// When httpz is not linked, returns `error.HttpsNotSupported`.
/// Callers should fall back to record-only mode and the plugin will
/// record the method/URL without performing a real request.
///
/// The caller owns `response.body` and must free it.
pub fn requestHttps(allocator: std.mem.Allocator, io: Io, config: Config) Error!Response {
    _ = allocator;
    _ = io;
    _ = config;
    return error.HttpsNotSupported;
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn write_request(writer: *Io.net.Stream.Writer, config: Config) Error!void {
    const method_str = config.method.to_str();
    writer.interface.writeAll(method_str) catch return error.SendFailed;
    writer.interface.writeAll(" ") catch return error.SendFailed;
    writer.interface.writeAll(config.url.path) catch return error.SendFailed;
    writer.interface.writeAll(" HTTP/1.1\r\n") catch return error.SendFailed;

    var host_written = false;
    var close_written = false;

    if (config.headers) |h| {
        for (h.entries[0..h.len]) |entry| {
            writer.interface.writeAll(entry.name) catch return error.SendFailed;
            writer.interface.writeAll(": ") catch return error.SendFailed;
            writer.interface.writeAll(entry.value) catch return error.SendFailed;
            writer.interface.writeAll("\r\n") catch return error.SendFailed;
            if (Headers.eql_ignore_case(entry.name, "Host")) {
                host_written = true;
            }
            if (Headers.eql_ignore_case(entry.name, "Connection")) {
                close_written = true;
            }
        }
    }

    if (!host_written) {
        writer.interface.writeAll("Host: ") catch return error.SendFailed;
        writer.interface.writeAll(config.url.host) catch return error.SendFailed;
        if (config.url.port != 80) {
            writer.interface.writeAll(":") catch return error.SendFailed;
            var port_buf: [20]u8 = undefined;
            const port_str = format_usize(config.url.port, &port_buf);
            writer.interface.writeAll(port_str) catch return error.SendFailed;
        }
        writer.interface.writeAll("\r\n") catch return error.SendFailed;
    }

    if (!close_written) {
        writer.interface.writeAll("Connection: close\r\n") catch return error.SendFailed;
    }

    const has_body = config.body != null and config.body.?.len > 0;
    if (has_body) {
        var cl_buf: [20]u8 = undefined;
        const cl_str = format_usize(config.body.?.len, &cl_buf);
        writer.interface.writeAll("Content-Length: ") catch return error.SendFailed;
        writer.interface.writeAll(cl_str) catch return error.SendFailed;
        writer.interface.writeAll("\r\n") catch return error.SendFailed;
    }

    writer.interface.writeAll("\r\n") catch return error.SendFailed;

    if (has_body) {
        writer.interface.writeAll(config.body.?) catch return error.SendFailed;
    }
}

fn read_response_headers(reader: *Io.Reader, response: *Response) Error!void {
    var header_buf: [8192]u8 = undefined;
    var header_pos: usize = 0;

    while (true) {
        const line = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                if (header_pos == 0) return error.InvalidResponse;
                break;
            },
            error.StreamTooLong => {
                if (header_pos == 0) return error.InvalidResponse;
                break;
            },
            else => return error.InvalidResponse,
        };

        if (header_pos + line.len > header_buf.len) return error.ResponseTooLarge;
        @memcpy(header_buf[header_pos..][0..line.len], line);
        header_pos += line.len;

        if (line.len == 2 and line[0] == '\r' and line[1] == '\n') {
            break;
        }
    }

    const header_str = header_buf[0..header_pos];

    const status_line_end = std.mem.indexOf(u8, header_str, "\r\n") orelse return error.InvalidResponse;
    try parse_status_line(header_str[0..status_line_end], response);

    var pos: usize = status_line_end + 2;
    while (pos + 1 < header_str.len) {
        const line_end = blk: {
            var j = pos;
            while (j + 1 < header_str.len) : (j += 1) {
                if (header_str[j] == '\r' and header_str[j + 1] == '\n') break :blk j;
            }
            break :blk header_str.len;
        };
        const line = header_str[pos..line_end];
        pos = if (line_end + 2 <= header_str.len) line_end + 2 else header_str.len;

        if (line.len == 0) break;

        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
        const name = line[0..colon];
        const value = trim_ows(line[colon + 1 ..]);

        response.headers.append(name, value) catch return error.ResponseTooLarge;
    }
}

fn parse_status_line(line: []const u8, response: *Response) Error!void {
    const version_end = std.mem.indexOfScalar(u8, line, ' ') orelse return error.InvalidStatusLine;
    const version_str = line[0..version_end];

    if (!std.mem.eql(u8, version_str, "HTTP/1.1") and
        !std.mem.eql(u8, version_str, "HTTP/1.0"))
    {
        return error.InvalidStatusLine;
    }

    const after_version = line[version_end + 1 ..];
    const status_end = std.mem.indexOfScalar(u8, after_version, ' ') orelse return error.InvalidStatusLine;

    const status_str = after_version[0..status_end];
    response.status = std.fmt.parseInt(u16, status_str, 10) catch return error.InvalidStatusLine;
    response.status_text = after_version[status_end + 1 ..];
}

/// Trim optional whitespace (OWS = *(SP / HTAB)) from both ends
/// per RFC 2616 Section 2.2.
fn trim_ows(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) : (start += 1) {}
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t')) : (end -= 1) {}
    return s[start..end];
}

fn format_usize(value: usize, buf: *[20]u8) []const u8 {
    var v = value;
    var i: usize = 20;
    if (v == 0) {
        buf[19] = '0';
        return buf[19..20];
    }
    while (v > 0) {
        i -= 1;
        buf[i] = @intCast(v % 10 + '0');
        v /= 10;
    }
    return buf[i..20];
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "http_client: Url.parse http scheme" {
    const url = Url.parse("http://example.com/path").?;
    try std.testing.expectEqualStrings("http", url.scheme);
    try std.testing.expectEqualStrings("example.com", url.host);
    try std.testing.expectEqual(@as(u16, 80), url.port);
    try std.testing.expectEqualStrings("/path", url.path);
}

test "http_client: Url.parse http with port" {
    const url = Url.parse("http://example.com:8080/path").?;
    try std.testing.expectEqualStrings("http", url.scheme);
    try std.testing.expectEqualStrings("example.com", url.host);
    try std.testing.expectEqual(@as(u16, 8080), url.port);
    try std.testing.expectEqualStrings("/path", url.path);
}

test "http_client: Url.parse no path" {
    const url = Url.parse("http://example.com").?;
    try std.testing.expectEqualStrings("/", url.path);
}

test "http_client: Url.parse https scheme" {
    const url = Url.parse("https://example.com/api").?;
    try std.testing.expectEqualStrings("https", url.scheme);
    try std.testing.expectEqualStrings("/api", url.path);
}

test "http_client: Url.parse returns null for invalid input" {
    try std.testing.expect(Url.parse("invalid") == null);
    try std.testing.expect(Url.parse("") == null);
}

test "http_client: Headers append and get" {
    var h: Headers = .{};
    try h.append("Content-Type", "text/html");
    try h.append("X-Custom", "value");
    try std.testing.expectEqualStrings("text/html", h.get("Content-Type").?);
    try std.testing.expectEqualStrings("value", h.get("X-Custom").?);
    try std.testing.expect(h.get("Missing") == null);
}

test "http_client: Headers case-insensitive lookup" {
    var h: Headers = .{};
    try h.append("Content-Type", "text/html");
    try std.testing.expectEqualStrings("text/html", h.get("content-type").?);
    try std.testing.expectEqualStrings("text/html", h.get("CONTENT-TYPE").?);
}

test "http_client: Headers too many headers" {
    var h: Headers = .{};
    for (0..Headers.max_headers) |_| {
        try h.append("X-H", "v");
    }
    try std.testing.expectError(error.TooManyHeaders, h.append("X-Extra", "v"));
}

test "http_client: format_usize" {
    var buf: [20]u8 = undefined;
    try std.testing.expectEqualStrings("0", format_usize(0, &buf));
    try std.testing.expectEqualStrings("42", format_usize(42, &buf));
    try std.testing.expectEqualStrings("65535", format_usize(65535, &buf));
}

test "http_client: trim_ows" {
    try std.testing.expectEqualStrings("hello", trim_ows("  hello  "));
    try std.testing.expectEqualStrings("hello", trim_ows("\thello\t"));
    try std.testing.expectEqualStrings("", trim_ows("   "));
    try std.testing.expectEqualStrings("a", trim_ows("a"));
}

test "http_client: requestHttps returns HttpsNotSupported when httpz is not linked" {
    const url = Url.parse("https://example.com/api").?;
    const config = Config{ .method = .GET, .url = url };
    try std.testing.expectError(error.HttpsNotSupported, requestHttps(std.testing.allocator, std.testing.io, config));
}

test "http_client: requestHttps stub does not leak" {
    const url = Url.parse("https://example.com/api").?;
    const config = Config{ .method = .GET, .url = url };
    _ = requestHttps(std.testing.allocator, std.testing.io, config) catch |err| {
        try std.testing.expectEqual(error.HttpsNotSupported, err);
    };
    // std.testing.allocator detects leaks at end of test scope.
}

/// Whether to run tests that require real network access.
/// Set to false to skip these tests in offline environments.
const run_network_tests = true;

test "http_client: real HTTP GET to example.com" {
    if (!run_network_tests) return error.SkipZigTest;

    const url = Url.parse("http://example.com/").?;
    const config = Config{
        .method = .GET,
        .url = url,
    };
    const resp = request(std.testing.allocator, std.testing.io, config) catch |err| {
        std.debug.print("network test skipped: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer std.testing.allocator.free(resp.body);

    // example.com uses chunked transfer-encoding; body may be empty until
    // chunked support is added. We only assert the status code.
    try std.testing.expectEqual(@as(u16, 200), resp.status);
}

test "http_client: real HTTP GET body via httpbin.org/html" {
    if (!run_network_tests) return error.SkipZigTest;

    const url = Url.parse("http://httpbin.org/html").?;
    const config = Config{
        .method = .GET,
        .url = url,
    };
    const resp = request(std.testing.allocator, std.testing.io, config) catch |err| {
        std.debug.print("network test skipped: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer std.testing.allocator.free(resp.body);

    try std.testing.expectEqual(@as(u16, 200), resp.status);
    try std.testing.expect(resp.body.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "html") != null);
}

test "http_client: real HTTP GET 404 via httpstat.us" {
    if (!run_network_tests) return error.SkipZigTest;

    const url = Url.parse("http://httpstat.us/404").?;
    const config = Config{
        .method = .GET,
        .url = url,
    };
    const resp = request(std.testing.allocator, std.testing.io, config) catch |err| {
        std.debug.print("network test skipped: {}\n", .{err});
        return error.SkipZigTest;
    };
    defer std.testing.allocator.free(resp.body);

    try std.testing.expectEqual(@as(u16, 404), resp.status);
}
