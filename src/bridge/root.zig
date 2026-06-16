const std = @import("std");
const json = @import("json");
const security = @import("../security/root.zig");

/// Maximum size, in bytes, of an incoming bridge request message.
pub const max_message_bytes: usize = 1024 * 1024;
/// Maximum size, in bytes, of a bridge response written by `writeSuccessResponse` or `writeErrorResponse`.
pub const max_response_bytes: usize = 1024 * 1024;
/// Maximum size, in bytes, of the result buffer supplied to synchronous bridge handlers.
pub const max_result_bytes: usize = 1024 * 1024;
/// Maximum length, in bytes, of a bridge request identifier.
pub const max_id_bytes: usize = 64;
/// Maximum length, in bytes, of a bridge command name.
pub const max_command_bytes: usize = 128;

const null_json = "null";

/// Error codes returned to the web side when a bridge request fails.
pub const ErrorCode = enum {
    invalid_request,
    unknown_command,
    permission_denied,
    handler_failed,
    payload_too_large,
    internal_error,

    /// Returns the JSON string used for the `code` field of an error response.
    pub fn jsonName(self: ErrorCode) []const u8 {
        return @tagName(self);
    }
};

/// Errors that can occur while parsing a bridge request envelope.
pub const ParseError = error{
    InvalidRequest,
    PayloadTooLarge,
};

/// Identifies the origin of a bridge invocation.
pub const Source = struct {
    /// Origin URL of the calling web content.
    origin: []const u8 = "",
    /// Window that sent the invocation.
    window_id: u64 = 1,
    /// Label of the webview that sent the invocation.
    webview_label: []const u8 = "main",
};

/// A parsed bridge request envelope.
pub const Request = struct {
    /// Client-supplied request identifier echoed back in responses.
    id: []const u8,
    /// Command name to dispatch.
    command: []const u8,
    /// Raw JSON payload passed to the handler.
    payload: []const u8 = null_json,
};

/// A bridge request together with its source context.
pub const Invocation = struct {
    /// Request being invoked.
    request: Request,
    /// Source of the invocation.
    source: Source,
};

/// Security policy for a single bridge command.
pub const CommandPolicy = struct {
    /// Command name this policy applies to.
    name: []const u8,
    /// Permissions required to invoke the command.
    permissions: []const []const u8 = &.{},
    /// Origins allowed to invoke the command. Empty means all origins are allowed.
    origins: []const []const u8 = &.{},
};

/// Security policy for the bridge dispatcher.
pub const Policy = struct {
    /// Whether the bridge is enabled. When false, all commands are denied.
    enabled: bool = false,
    /// Global permissions required by all commands.
    permissions: []const []const u8 = &.{},
    /// Per-command policies.
    commands: []const CommandPolicy = &.{},

    /// Returns whether `command` is allowed from `origin` under this policy.
    pub fn allows(self: Policy, command: []const u8, origin: []const u8) bool {
        if (!self.enabled) return false;
        const command_policy = self.find(command) orelse return false;
        if (!security.hasPermissions(self.permissions, command_policy.permissions)) return false;
        if (command_policy.origins.len == 0) return true;
        for (command_policy.origins) |allowed| {
            if (std.mem.eql(u8, allowed, "*")) return true;
            if (std.mem.eql(u8, allowed, origin)) return true;
        }
        return false;
    }

    /// Returns the `CommandPolicy` for `command`, if one exists.
    pub fn find(self: Policy, command: []const u8) ?CommandPolicy {
        for (self.commands) |command_policy| {
            if (std.mem.eql(u8, command_policy.name, command)) return command_policy;
        }
        return null;
    }
};

/// Function signature for synchronous bridge handlers.
/// `context` is the handler's private state. `output` is a scratch buffer for formatting results.
/// Returns the JSON result string, which may point into `output` or be a static string.
pub const HandlerFn = *const fn (context: *anyopaque, invocation: Invocation, output: []u8) anyerror![]const u8;
/// Function signature used by `AsyncResponder` to send a response back to the web side.
/// `context` is the responder's private state. `response` is a complete JSON response string.
pub const AsyncRespondFn = *const fn (context: *anyopaque, source: Source, response: []const u8) anyerror!void;
/// Function signature for asynchronous bridge handlers.
/// `responder` must be used to send the response later.
pub const AsyncHandlerFn = *const fn (context: *anyopaque, invocation: Invocation, responder: AsyncResponder) anyerror!void;

/// A registered synchronous bridge handler.
pub const Handler = struct {
    /// Command name this handler implements.
    name: []const u8,
    /// Opaque context pointer passed to `invoke_fn`.
    context: *anyopaque,
    /// Function invoked to handle the command.
    invoke_fn: HandlerFn,
};

/// Handle used by asynchronous handlers to respond to a bridge request.
pub const AsyncResponder = struct {
    /// Opaque context pointer passed to `respond_fn`.
    context: *anyopaque,
    /// Source of the original request.
    source: Source,
    /// Function called to deliver the response.
    respond_fn: AsyncRespondFn,

    /// Sends `response` back to the web side.
    pub fn respond(self: AsyncResponder, response: []const u8) anyerror!void {
        return self.respond_fn(self.context, self.source, response);
    }

    /// Sends a successful response with `result` as the JSON value.
    pub fn success(self: AsyncResponder, id: []const u8, result: []const u8) anyerror!void {
        var buffer: [max_response_bytes]u8 = undefined;
        try self.respond(writeSuccessResponse(&buffer, id, result));
    }

    /// Sends an error response with the given code and message.
    pub fn fail(self: AsyncResponder, id: []const u8, code: ErrorCode, message: []const u8) anyerror!void {
        var buffer: [max_response_bytes]u8 = undefined;
        try self.respond(writeErrorResponse(&buffer, id, code, message));
    }
};

/// A registered asynchronous bridge handler.
pub const AsyncHandler = struct {
    /// Command name this handler implements.
    name: []const u8,
    /// Opaque context pointer passed to `invoke_fn`.
    context: *anyopaque,
    /// Function invoked to handle the command.
    invoke_fn: AsyncHandlerFn,
    /// Function used to deliver responses from asynchronous handlers.
    /// Defaults to a no-op so existing callers are not required to supply one.
    respond_fn: AsyncRespondFn = asyncNoOpRespond,
};

fn asyncNoOpRespond(context: *anyopaque, source: Source, response: []const u8) anyerror!void {
    _ = context;
    _ = source;
    _ = response;
}

/// Registry of synchronous bridge handlers.
pub const Registry = struct {
    /// Handlers to search.
    handlers: []const Handler = &.{},

    /// Returns the handler registered for `command`, if any.
    pub fn find(self: Registry, command: []const u8) ?Handler {
        for (self.handlers) |handler| {
            if (std.mem.eql(u8, handler.name, command)) return handler;
        }
        return null;
    }
};

/// Registry of asynchronous bridge handlers.
pub const AsyncRegistry = struct {
    /// Handlers to search.
    handlers: []const AsyncHandler = &.{},

    /// Returns the async handler registered for `command`, if any.
    pub fn find(self: AsyncRegistry, command: []const u8) ?AsyncHandler {
        for (self.handlers) |handler| {
            if (std.mem.eql(u8, handler.name, command)) return handler;
        }
        return null;
    }
};

/// Dispatches incoming bridge requests to registered handlers while enforcing policy.
pub const Dispatcher = struct {
    /// Security policy applied to all requests.
    policy: Policy = .{},
    /// Synchronous handlers.
    registry: Registry = .{},
    /// Asynchronous handlers.
    async_registry: AsyncRegistry = .{},

    /// Parses `raw`, checks policy, invokes the registered handler, and writes a JSON response into `output`.
    /// Returns the response string, which points into `output`.
    pub fn dispatch(self: Dispatcher, raw: []const u8, source: Source, output: []u8) []const u8 {
        if (raw.len > max_message_bytes) {
            return writeErrorResponse(output, "", .payload_too_large, "Bridge request is too large");
        }

        const request = parseRequest(raw) catch {
            return writeErrorResponse(output, "", .invalid_request, "Bridge request is malformed");
        };

        if (!self.policy.allows(request.command, source.origin)) {
            return writeErrorResponse(output, request.id, .permission_denied, "Bridge command is not permitted");
        }

        if (self.async_registry.find(request.command)) |async_handler| {
            const responder = AsyncResponder{
                .context = async_handler.context,
                .source = source,
                .respond_fn = async_handler.respond_fn,
            };
            async_handler.invoke_fn(async_handler.context, .{ .request = request, .source = source }, responder) catch |err| {
                return writeErrorResponse(output, request.id, .handler_failed, @errorName(err));
            };
            return output[0..0];
        }

        const handler = self.registry.find(request.command) orelse {
            return writeErrorResponse(output, request.id, .unknown_command, "Bridge command is not registered");
        };

        var result_buffer: [max_result_bytes]u8 = undefined;
        const result = handler.invoke_fn(handler.context, .{ .request = request, .source = source }, &result_buffer) catch |err| {
            return writeErrorResponse(output, request.id, .handler_failed, @errorName(err));
        };
        return writeSuccessResponse(output, request.id, if (result.len == 0) null_json else result);
    }
};

/// Parses a JSON bridge request from `raw`.
/// Returns `error.PayloadTooLarge` if the input exceeds `max_message_bytes`, or `error.InvalidRequest` if the JSON is malformed.
pub fn parseRequest(raw: []const u8) ParseError!Request {
    if (raw.len > max_message_bytes) return error.PayloadTooLarge;
    var index: usize = 0;
    try skipWhitespace(raw, &index);
    try expectByte(raw, &index, '{');

    var id: ?[]const u8 = null;
    var command: ?[]const u8 = null;
    var payload: []const u8 = null_json;

    try skipWhitespace(raw, &index);
    if (peekByte(raw, index) == '}') {
        index += 1;
    } else {
        while (true) {
            try skipWhitespace(raw, &index);
            const key = try parseSimpleString(raw, &index);
            try skipWhitespace(raw, &index);
            try expectByte(raw, &index, ':');
            try skipWhitespace(raw, &index);

            if (std.mem.eql(u8, key, "id")) {
                id = try parseSimpleString(raw, &index);
            } else if (std.mem.eql(u8, key, "command")) {
                command = try parseSimpleString(raw, &index);
            } else if (std.mem.eql(u8, key, "payload")) {
                const start = index;
                try skipJsonValue(raw, &index);
                payload = raw[start..index];
            } else {
                try skipJsonValue(raw, &index);
            }

            try skipWhitespace(raw, &index);
            const next = peekByte(raw, index) orelse return error.InvalidRequest;
            if (next == ',') {
                index += 1;
                continue;
            }
            if (next == '}') {
                index += 1;
                break;
            }
            return error.InvalidRequest;
        }
    }

    try skipWhitespace(raw, &index);
    if (index != raw.len) return error.InvalidRequest;

    const request_id = id orelse return error.InvalidRequest;
    const command_name = command orelse return error.InvalidRequest;
    if (!validId(request_id) or !validCommand(command_name)) return error.InvalidRequest;
    return .{ .id = request_id, .command = command_name, .payload = payload };
}

/// Writes a successful JSON bridge response into `output`.
/// If `result` is empty, the literal `null` is used as the result value.
/// Returns the written slice, or an empty slice if `output` overflows.
pub fn writeSuccessResponse(output: []u8, id: []const u8, result: []const u8) []const u8 {
    const value = if (result.len == 0) null_json else result;
    if (!json.isValidValue(value)) {
        return writeErrorResponse(output, id, .handler_failed, "Bridge command returned invalid JSON");
    }
    var writer = std.Io.Writer.fixed(output);
    writer.writeAll("{\"id\":") catch return output[0..0];
    json.writeString(&writer, id) catch return output[0..0];
    writer.writeAll(",\"ok\":true,\"result\":") catch return output[0..0];
    writer.writeAll(value) catch return output[0..0];
    writer.writeAll("}") catch return output[0..0];
    return writer.buffered();
}

/// Writes an error JSON bridge response into `output`.
/// Returns the written slice, or an empty slice if `output` overflows.
pub fn writeErrorResponse(output: []u8, id: []const u8, code: ErrorCode, message: []const u8) []const u8 {
    var writer = std.Io.Writer.fixed(output);
    writer.writeAll("{\"id\":") catch return output[0..0];
    json.writeString(&writer, id) catch return output[0..0];
    writer.writeAll(",\"ok\":false,\"error\":{\"code\":") catch return output[0..0];
    json.writeString(&writer, code.jsonName()) catch return output[0..0];
    writer.writeAll(",\"message\":") catch return output[0..0];
    json.writeString(&writer, message) catch return output[0..0];
    writer.writeAll("}}") catch return output[0..0];
    return writer.buffered();
}

/// Writes `value` as a JSON-encoded string into `output`.
/// Returns the written slice, or an empty slice if `output` overflows.
pub fn writeJsonStringValue(output: []u8, value: []const u8) []const u8 {
    var writer = std.Io.Writer.fixed(output);
    json.writeString(&writer, value) catch return output[0..0];
    return writer.buffered();
}

/// Returns whether `raw` is a valid JSON value.
pub fn isValidJsonValue(raw: []const u8) bool {
    return json.isValidValue(raw);
}

fn validId(value: []const u8) bool {
    if (value.len == 0 or value.len > max_id_bytes) return false;
    for (value) |ch| {
        if (ch <= 0x1f or ch == '"' or ch == '\\') return false;
    }
    return true;
}

fn validCommand(value: []const u8) bool {
    if (value.len == 0 or value.len > max_command_bytes) return false;
    for (value) |ch| {
        if (ch <= 0x1f or ch == '"' or ch == '\\' or ch == '/' or ch == ' ') return false;
    }
    return true;
}

fn skipWhitespace(raw: []const u8, index: *usize) ParseError!void {
    while (index.* < raw.len) : (index.* += 1) {
        switch (raw[index.*]) {
            ' ', '\n', '\r', '\t' => {},
            else => return,
        }
    }
}

fn expectByte(raw: []const u8, index: *usize, expected: u8) ParseError!void {
    if (peekByte(raw, index.*) != expected) return error.InvalidRequest;
    index.* += 1;
}

fn peekByte(raw: []const u8, index: usize) ?u8 {
    if (index >= raw.len) return null;
    return raw[index];
}

fn parseSimpleString(raw: []const u8, index: *usize) ParseError![]const u8 {
    try expectByte(raw, index, '"');
    const start = index.*;
    while (index.* < raw.len) : (index.* += 1) {
        const ch = raw[index.*];
        if (ch == '"') {
            const value = raw[start..index.*];
            index.* += 1;
            return value;
        }
        if (ch == '\\' or ch <= 0x1f) return error.InvalidRequest;
    }
    return error.InvalidRequest;
}

fn skipJsonValue(raw: []const u8, index: *usize) ParseError!void {
    const start = peekByte(raw, index.*) orelse return error.InvalidRequest;
    switch (start) {
        '"' => try skipJsonString(raw, index),
        '{' => try skipJsonContainer(raw, index, '{', '}'),
        '[' => try skipJsonContainer(raw, index, '[', ']'),
        else => try skipJsonAtom(raw, index),
    }
}

fn skipJsonString(raw: []const u8, index: *usize) ParseError!void {
    try expectByte(raw, index, '"');
    while (index.* < raw.len) : (index.* += 1) {
        const ch = raw[index.*];
        if (ch == '"') {
            index.* += 1;
            return;
        }
        if (ch == '\\') {
            index.* += 1;
            if (index.* >= raw.len) return error.InvalidRequest;
        } else if (ch <= 0x1f) {
            return error.InvalidRequest;
        }
    }
    return error.InvalidRequest;
}

fn skipJsonContainer(raw: []const u8, index: *usize, open: u8, close: u8) ParseError!void {
    try expectByte(raw, index, open);
    try skipWhitespace(raw, index);
    if (peekByte(raw, index.*) == close) {
        index.* += 1;
        return;
    }
    while (true) {
        try skipWhitespace(raw, index);
        if (open == '{') {
            try skipJsonString(raw, index);
            try skipWhitespace(raw, index);
            try expectByte(raw, index, ':');
            try skipWhitespace(raw, index);
        }
        try skipJsonValue(raw, index);
        try skipWhitespace(raw, index);
        const next = peekByte(raw, index.*) orelse return error.InvalidRequest;
        if (next == ',') {
            index.* += 1;
            continue;
        }
        if (next == close) {
            index.* += 1;
            return;
        }
        return error.InvalidRequest;
    }
}

fn skipJsonAtom(raw: []const u8, index: *usize) ParseError!void {
    const start = index.*;
    while (index.* < raw.len) : (index.* += 1) {
        switch (raw[index.*]) {
            ',', '}', ']', ' ', '\n', '\r', '\t' => break,
            else => {},
        }
    }
    if (start == index.*) return error.InvalidRequest;
    const atom = raw[start..index.*];
    if (std.mem.eql(u8, atom, "true") or std.mem.eql(u8, atom, "false") or std.mem.eql(u8, atom, "null")) return;
    _ = std.fmt.parseFloat(f64, atom) catch return error.InvalidRequest;
}

test "bridge parses request envelope and raw payload" {
    const request = try parseRequest(
        \\{"id":"1","command":"native.ping","payload":{"text":"hello","count":2}}
    );
    try std.testing.expectEqualStrings("1", request.id);
    try std.testing.expectEqualStrings("native.ping", request.command);
    try std.testing.expectEqualStrings("{\"text\":\"hello\",\"count\":2}", request.payload);
}

test "bridge rejects malformed or oversized requests" {
    try std.testing.expectError(error.InvalidRequest, parseRequest("{}"));
    try std.testing.expectError(error.InvalidRequest, parseRequest("{\"id\":\"\",\"command\":\"native.ping\"}"));
    try std.testing.expectError(error.InvalidRequest, parseRequest("{\"id\":\"1\",\"command\":\"bad command\"}"));
}

test "bridge writes success and error responses" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "{\"id\":\"abc\",\"ok\":true,\"result\":{\"pong\":true}}",
        writeSuccessResponse(&buffer, "abc", "{\"pong\":true}"),
    );
    try std.testing.expectEqualStrings(
        "{\"id\":\"abc\",\"ok\":false,\"error\":{\"code\":\"permission_denied\",\"message\":\"Denied\"}}",
        writeErrorResponse(&buffer, "abc", .permission_denied, "Denied"),
    );
}

test "bridge validates and writes JSON result values" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("\"hello \\\"user\\\"\"",
        writeJsonStringValue(&buffer, "hello \"user\""));
    try std.testing.expect(isValidJsonValue("{\"pong\":true}"));
    try std.testing.expect(isValidJsonValue("{\"escaped\\\"key\":true}"));
    try std.testing.expect(isValidJsonValue("\"hello\""));
    try std.testing.expect(isValidJsonValue("null"));
    try std.testing.expect(!isValidJsonValue("raw \"user\" text"));
    try std.testing.expect(!isValidJsonValue("{\"partial\":true"));

    const response = writeSuccessResponse(&buffer, "abc", "raw \"user\" text");
    try std.testing.expect(std.mem.indexOf(u8, response, "\"handler_failed\"") != null);
}

test "dispatcher enforces policy and invokes registered handler" {
    const State = struct {
        fn ping(context: *anyopaque, invocation: Invocation, output: []u8) anyerror![]const u8 {
            _ = context;
            _ = output;
            try std.testing.expectEqualStrings("{\"value\":1}", invocation.request.payload);
            try std.testing.expectEqualStrings("zero://inline", invocation.source.origin);
            return "{\"pong\":true}";
        }
    };

    var state: u8 = 0;
    const policies = [_]CommandPolicy{.{ .name = "native.ping", .origins = &.{"zero://inline"} }};
    const handlers = [_]Handler{.{ .name = "native.ping", .context = &state, .invoke_fn = State.ping }};
    const dispatcher: Dispatcher = .{
        .policy = .{ .enabled = true, .commands = &policies },
        .registry = .{ .handlers = &handlers },
    };

    var buffer: [256]u8 = undefined;
    const response = dispatcher.dispatch(
        \\{"id":"1","command":"native.ping","payload":{"value":1}}
    , .{ .origin = "zero://inline" }, &buffer);
    try std.testing.expectEqualStrings("{\"id\":\"1\",\"ok\":true,\"result\":{\"pong\":true}}", response);
}

test "dispatcher rejects invalid handler result JSON" {
    const State = struct {
        fn unsafe(context: *anyopaque, invocation: Invocation, output: []u8) anyerror![]const u8 {
            _ = context;
            _ = invocation;
            _ = output;
            return "hello \"user\"";
        }
    };

    var state: u8 = 0;
    const policies = [_]CommandPolicy{.{ .name = "native.unsafe", .origins = &.{"zero://inline"} }};
    const handlers = [_]Handler{.{ .name = "native.unsafe", .context = &state, .invoke_fn = State.unsafe }};
    const dispatcher: Dispatcher = .{
        .policy = .{ .enabled = true, .commands = &policies },
        .registry = .{ .handlers = &handlers },
    };

    var buffer: [256]u8 = undefined;
    const response = dispatcher.dispatch(
        \\{"id":"1","command":"native.unsafe","payload":null}
    , .{ .origin = "zero://inline" }, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"handler_failed\"") != null);
}

test "dispatcher requires command permissions and matching origins" {
    const policies = [_]CommandPolicy{.{ .name = "native.secure", .permissions = &.{"filesystem"}, .origins = &.{"zero://app"} }};
    const wildcard_policies = [_]CommandPolicy{.{ .name = "native.anywhere", .permissions = &.{"filesystem"}, .origins = &.{"*"} }};
    const dispatcher: Dispatcher = .{
        .policy = .{ .enabled = true, .permissions = &.{"filesystem"}, .commands = &policies },
        .registry = .{},
    };
    const wildcard: Dispatcher = .{
        .policy = .{ .enabled = true, .permissions = &.{"filesystem"}, .commands = &wildcard_policies },
        .registry = .{},
    };
    const denied_by_origin: Dispatcher = .{
        .policy = .{ .enabled = true, .permissions = &.{"filesystem"}, .commands = &policies },
        .registry = .{},
    };
    const denied_by_permission: Dispatcher = .{
        .policy = .{ .enabled = true, .commands = &policies },
        .registry = .{},
    };

    try std.testing.expect(dispatcher.policy.allows("native.secure", "zero://app"));
    try std.testing.expect(wildcard.policy.allows("native.anywhere", "https://example.com"));
    try std.testing.expect(!denied_by_origin.policy.allows("native.secure", "zero://inline"));
    try std.testing.expect(!denied_by_permission.policy.allows("native.secure", "zero://app"));
}

test "dispatcher reports permission denial before unknown command" {
    const dispatcher: Dispatcher = .{};
    var buffer: [256]u8 = undefined;
    const response = dispatcher.dispatch(
        \\{"id":"1","command":"native.ping","payload":null}
    , .{}, &buffer);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"permission_denied\"") != null);
}

test "parseRequest property tests" {
    // parseRequest does not allocate; it returns slices into the input buffer.
    // The helper below uses std.testing.allocator only to build test inputs.
    const make_request = struct {
        fn call(id: []const u8, command: []const u8, payload: ?[]const u8) ![]const u8 {
            if (payload) |p| {
                return std.fmt.allocPrint(std.testing.allocator, "{{\"id\":\"{s}\",\"command\":\"{s}\",\"payload\":{s}}}", .{ id, command, p });
            } else {
                return std.fmt.allocPrint(std.testing.allocator, "{{\"id\":\"{s}\",\"command\":\"{s}\"}}", .{ id, command });
            }
        }
    }.call;

    // Valid inputs: id, command, and payload are parsed correctly.
    {
        const req = try make_request("1", "native.ping", "{\"text\":\"hello\",\"count\":2}");
        defer std.testing.allocator.free(req);
        const parsed = try parseRequest(req);
        try std.testing.expectEqualStrings("1", parsed.id);
        try std.testing.expectEqualStrings("native.ping", parsed.command);
        try std.testing.expectEqualStrings("{\"text\":\"hello\",\"count\":2}", parsed.payload);
    }

    // Empty payload is allowed (omitted payload defaults to "null").
    {
        const req = try make_request("empty", "native.empty", null);
        defer std.testing.allocator.free(req);
        const parsed = try parseRequest(req);
        try std.testing.expectEqualStrings("empty", parsed.id);
        try std.testing.expectEqualStrings("native.empty", parsed.command);
        try std.testing.expectEqualStrings("null", parsed.payload);
    }

    // ID at the maximum length boundary is accepted.
    {
        var id_buffer: [max_id_bytes]u8 = @splat('a');
        const id = id_buffer[0..];
        const req = try make_request(id, "native.ping", null);
        defer std.testing.allocator.free(req);
        const parsed = try parseRequest(req);
        try std.testing.expectEqualStrings(id, parsed.id);
    }

    // Command at the maximum length boundary is accepted.
    {
        var command_buffer: [max_command_bytes]u8 = @splat('b');
        const command = command_buffer[0..];
        const req = try make_request("1", command, null);
        defer std.testing.allocator.free(req);
        const parsed = try parseRequest(req);
        try std.testing.expectEqualStrings(command, parsed.command);
    }

    // Large but within-limit payload is accepted.
    {
        const overhead = "{\"id\":\"1\",\"command\":\"cmd\",\"payload\":\"";
        const overhead_end = "\"}";
        const payload_len = max_message_bytes - overhead.len - overhead_end.len;
        const req = try std.testing.allocator.alloc(u8, max_message_bytes);
        defer std.testing.allocator.free(req);
        @memcpy(req[0..overhead.len], overhead);
        @memset(req[overhead.len..overhead.len + payload_len], 'x');
        @memcpy(req[overhead.len + payload_len..], overhead_end);
        const parsed = try parseRequest(req);
        try std.testing.expectEqualStrings("1", parsed.id);
        try std.testing.expectEqualStrings("cmd", parsed.command);
        try std.testing.expectEqual(payload_len, parsed.payload.len - 2); // subtract surrounding quotes
    }

    // Extra top-level fields are accepted.
    {
        const req = "{\"extra\":true,\"source\":\"web\",\"id\":\"1\",\"command\":\"native.ping\"}";
        const parsed = try parseRequest(req);
        try std.testing.expectEqualStrings("1", parsed.id);
        try std.testing.expectEqualStrings("native.ping", parsed.command);
        try std.testing.expectEqualStrings("null", parsed.payload);
    }

    // Nested objects and arrays inside payload are accepted.
    {
        const req = "{\"id\":\"1\",\"command\":\"native.nested\",\"payload\":{\"a\":[1,{\"b\":true},\"c\"],\"d\":null}}";
        const parsed = try parseRequest(req);
        try std.testing.expectEqualStrings("1", parsed.id);
        try std.testing.expectEqualStrings("native.nested", parsed.command);
        try std.testing.expectEqualStrings("{\"a\":[1,{\"b\":true},\"c\"],\"d\":null}", parsed.payload);
    }

    // Invalid inputs return the expected errors and do not crash.
    try std.testing.expectError(error.InvalidRequest, parseRequest(""));
    try std.testing.expectError(error.InvalidRequest, parseRequest("{"));
    try std.testing.expectError(error.InvalidRequest, parseRequest("not json"));
    try std.testing.expectError(error.InvalidRequest, parseRequest("{\"command\":\"native.ping\"}"));
    try std.testing.expectError(error.InvalidRequest, parseRequest("{\"id\":\"1\"}"));
    try std.testing.expectError(error.InvalidRequest, parseRequest("{\"id\":\"\",\"command\":\"native.ping\"}"));
    try std.testing.expectError(error.InvalidRequest, parseRequest("{\"id\":\"1\",\"command\":\"bad command\"}"));
    try std.testing.expectError(error.InvalidRequest, parseRequest("{\"id\":1,\"command\":\"native.ping\"}"));
    try std.testing.expectError(error.InvalidRequest, parseRequest("{\"id\":\"1\",\"command\":true}"));

    // ID exceeding the maximum length is rejected.
    {
        var id_buffer: [max_id_bytes + 1]u8 = @splat('a');
        const id = id_buffer[0..];
        const req = try make_request(id, "native.ping", null);
        defer std.testing.allocator.free(req);
        try std.testing.expectError(error.InvalidRequest, parseRequest(req));
    }

    // Command exceeding the maximum length is rejected.
    {
        var command_buffer: [max_command_bytes + 1]u8 = @splat('b');
        const command = command_buffer[0..];
        const req = try make_request("1", command, null);
        defer std.testing.allocator.free(req);
        try std.testing.expectError(error.InvalidRequest, parseRequest(req));
    }

    // Total message exceeding the maximum length is rejected.
    {
        const too_large = try std.testing.allocator.alloc(u8, max_message_bytes + 1);
        defer std.testing.allocator.free(too_large);
        @memset(too_large, 'x');
        try std.testing.expectError(error.PayloadTooLarge, parseRequest(too_large));
    }
}

test "Dispatcher dispatch property tests" {
    const make_request = struct {
        fn call(id: []const u8, command: []const u8, payload: ?[]const u8) ![]const u8 {
            if (payload) |p| {
                return std.fmt.allocPrint(std.testing.allocator, "{{\"id\":\"{s}\",\"command\":\"{s}\",\"payload\":{s}}}", .{ id, command, p });
            } else {
                return std.fmt.allocPrint(std.testing.allocator, "{{\"id\":\"{s}\",\"command\":\"{s}\"}}", .{ id, command });
            }
        }
    }.call;

    // Successful dispatch: handler result is wrapped in a success response pointing into `output`.
    {
        const EchoState = struct {
            fn echo(context: *anyopaque, invocation: Invocation, output: []u8) anyerror![]const u8 {
                _ = context;
                return try std.fmt.bufPrint(output, "{{\"echo\":{s}}}", .{invocation.request.payload});
            }
        };

        var state: EchoState = .{};
        const policies = [_]CommandPolicy{.{ .name = "native.echo", .origins = &.{"zero://test"} }};
        const handlers = [_]Handler{.{ .name = "native.echo", .context = &state, .invoke_fn = EchoState.echo }};
        const dispatcher: Dispatcher = .{
            .policy = .{ .enabled = true, .commands = &policies },
            .registry = .{ .handlers = &handlers },
        };

        var output: [512]u8 = undefined;
        const request = try make_request("1", "native.echo", "\"hello\"");
        defer std.testing.allocator.free(request);
        const response = dispatcher.dispatch(request, .{ .origin = "zero://test" }, &output);
        try std.testing.expectEqualStrings("{\"id\":\"1\",\"ok\":true,\"result\":{\"echo\":\"hello\"}}", response);
        try std.testing.expect(@intFromPtr(response.ptr) == @intFromPtr(&output[0]));
    }

    // Unknown command: the command is allowed by policy but has no registered handler.
    {
        const policies = [_]CommandPolicy{.{ .name = "native.unknown", .origins = &.{} }};
        const dispatcher: Dispatcher = .{
            .policy = .{ .enabled = true, .commands = &policies },
            .registry = .{},
        };

        var output: [256]u8 = undefined;
        const request = try make_request("1", "native.unknown", "null");
        defer std.testing.allocator.free(request);
        const response = dispatcher.dispatch(request, .{ .origin = "zero://test" }, &output);
        try std.testing.expect(std.mem.indexOf(u8, response, "\"unknown_command\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "\"ok\":false") != null);
    }

    // Policy denies command: the handler exists but the origin is not permitted.
    {
        const EchoState = struct {
            fn echo(context: *anyopaque, invocation: Invocation, output: []u8) anyerror![]const u8 {
                _ = context;
                _ = invocation;
                _ = output;
                return "null";
            }
        };

        var state: EchoState = .{};
        const policies = [_]CommandPolicy{.{ .name = "native.echo", .origins = &.{"zero://allowed"} }};
        const handlers = [_]Handler{.{ .name = "native.echo", .context = &state, .invoke_fn = EchoState.echo }};
        const dispatcher: Dispatcher = .{
            .policy = .{ .enabled = true, .commands = &policies },
            .registry = .{ .handlers = &handlers },
        };

        var output: [256]u8 = undefined;
        const request = try make_request("1", "native.echo", "null");
        defer std.testing.allocator.free(request);
        const response = dispatcher.dispatch(request, .{ .origin = "zero://denied" }, &output);
        try std.testing.expect(std.mem.indexOf(u8, response, "\"permission_denied\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "\"ok\":false") != null);
    }

    // Async command: dispatch returns an empty slice, and the responder can produce responses later.
    {
        const AsyncState = struct {
            responder: ?AsyncResponder = null,
            response: ?[]const u8 = null,

            fn async_handler(context: *anyopaque, invocation: Invocation, responder: AsyncResponder) anyerror!void {
                const self: *@This() = @ptrCast(@alignCast(context));
                _ = invocation;
                self.responder = responder;
            }

            fn capture_respond(context: *anyopaque, source: Source, response: []const u8) anyerror!void {
                const self: *@This() = @ptrCast(@alignCast(context));
                _ = source;
                self.response = try std.testing.allocator.dupe(u8, response);
            }
        };

        var async_state: AsyncState = .{};
        const policies = [_]CommandPolicy{.{ .name = "native.async", .origins = &.{} }};
        const handlers = [_]AsyncHandler{
            .{
                .name = "native.async",
                .context = &async_state,
                .invoke_fn = AsyncState.async_handler,
                .respond_fn = AsyncState.capture_respond,
            },
        };
        const dispatcher: Dispatcher = .{
            .policy = .{ .enabled = true, .commands = &policies },
            .async_registry = .{ .handlers = &handlers },
        };

        var output: [256]u8 = undefined;
        const request = try make_request("async-1", "native.async", "null");
        defer std.testing.allocator.free(request);
        const response = dispatcher.dispatch(request, .{ .origin = "https://example.com" }, &output);
        try std.testing.expectEqualStrings("", response);
        try std.testing.expect(async_state.responder != null);

        try async_state.responder.?.success("async-1", "{\"done\":true}");
        try std.testing.expect(async_state.response != null);
        try std.testing.expectEqualStrings("{\"id\":\"async-1\",\"ok\":true,\"result\":{\"done\":true}}", async_state.response.?);
        std.testing.allocator.free(async_state.response.?);
        async_state.response = null;

        try async_state.responder.?.fail("async-1", .handler_failed, "boom");
        try std.testing.expect(async_state.response != null);
        try std.testing.expectEqualStrings("{\"id\":\"async-1\",\"ok\":false,\"error\":{\"code\":\"handler_failed\",\"message\":\"boom\"}}", async_state.response.?);
        std.testing.allocator.free(async_state.response.?);
    }

    // Invalid input: malformed JSON is rejected before reaching the registry or policy.
    {
        const dispatcher: Dispatcher = .{};
        var output: [256]u8 = undefined;
        const response = dispatcher.dispatch("not json", .{}, &output);
        try std.testing.expect(std.mem.indexOf(u8, response, "\"invalid_request\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "\"ok\":false") != null);
    }
}
