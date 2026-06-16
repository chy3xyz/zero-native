const std = @import("std");

pub const SignResult = struct {
    ok: bool,
    message: []const u8,
};

pub const CodesignArgs = struct {
    app_path: []const u8,
    identity: []const u8 = "-",
    entitlements: ?[]const u8 = null,
    hardened_runtime: bool = false,
    deep: bool = true,
};

pub const NotarizeArgs = struct {
    app_path: []const u8,
    team_id: []const u8,
    apple_id: ?[]const u8 = null,
    password_keychain_item: ?[]const u8 = null,
};

pub fn buildSignCommand(buffer: []u8, args: CodesignArgs) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll("codesign --sign ");
    try writer.writeAll(args.identity);
    try writer.writeAll(" --force");
    if (args.deep) try writer.writeAll(" --deep");
    if (args.hardened_runtime) try writer.writeAll(" --options runtime");
    if (args.entitlements) |ent| {
        try writer.writeAll(" --entitlements ");
        try writer.writeAll(ent);
    }
    try writer.writeAll(" ");
    try writer.writeAll(args.app_path);
    return writer.buffered();
}

pub fn buildNotarizeSubmitCommand(buffer: []u8, zip_path: []const u8, args: NotarizeArgs) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll("xcrun notarytool submit ");
    try writer.writeAll(zip_path);
    try writer.writeAll(" --team-id ");
    try writer.writeAll(args.team_id);
    if (args.apple_id) |apple_id| {
        try writer.writeAll(" --apple-id ");
        try writer.writeAll(apple_id);
    }
    if (args.password_keychain_item) |item| {
        try writer.writeAll(" --password @keychain:");
        try writer.writeAll(item);
    }
    try writer.writeAll(" --wait");
    return writer.buffered();
}

pub fn buildStapleCommand(buffer: []u8, app_path: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll("xcrun stapler staple ");
    try writer.writeAll(app_path);
    return writer.buffered();
}

pub fn buildZipCommand(buffer: []u8, app_path: []const u8, zip_path: []const u8) ![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    try writer.writeAll("ditto -c -k --keepParent ");
    try writer.writeAll(app_path);
    try writer.writeAll(" ");
    try writer.writeAll(zip_path);
    return writer.buffered();
}

pub fn signAdHoc(io: std.Io, app_path: []const u8) !SignResult {
    return runSign(io, .{ .app_path = app_path, .identity = "-", .deep = true });
}

pub fn signIdentity(io: std.Io, app_path: []const u8, identity: []const u8, entitlements: ?[]const u8) !SignResult {
    return runSign(io, .{
        .app_path = app_path,
        .identity = identity,
        .entitlements = entitlements,
        .hardened_runtime = true,
        .deep = true,
    });
}

pub fn notarize(allocator: std.mem.Allocator, io: std.Io, args: NotarizeArgs) !SignResult {
    const zip_path = try std.fmt.allocPrint(allocator, "{s}.zip", .{args.app_path});
    defer allocator.free(zip_path);

    var zip_buf: [1024]u8 = undefined;
    const zip_cmd = try buildZipCommand(&zip_buf, args.app_path, zip_path);
    runShell(io, zip_cmd) catch |err| {
        std.log.err("codesign.notarize_zip_failed: error={s}", .{@errorName(err)});
        return .{ .ok = false, .message = "failed to zip app for notarization" };
    };

    var submit_buf: [1024]u8 = undefined;
    const submit_cmd = try buildNotarizeSubmitCommand(&submit_buf, zip_path, args);
    runShell(io, submit_cmd) catch |err| {
        std.log.err("codesign.notarize_submit_failed: error={s}", .{@errorName(err)});
        return .{ .ok = false, .message = "notarytool submit failed" };
    };

    var staple_buf: [512]u8 = undefined;
    const staple_cmd = try buildStapleCommand(&staple_buf, args.app_path);
    runShell(io, staple_cmd) catch |err| {
        std.log.err("codesign.notarize_staple_failed: error={s}", .{@errorName(err)});
        return .{ .ok = false, .message = "stapler staple failed" };
    };

    return .{ .ok = true, .message = "notarization complete" };
}

fn runSign(io: std.Io, args: CodesignArgs) !SignResult {
    var buffer: [1024]u8 = undefined;
    const cmd = try buildSignCommand(&buffer, args);
    runShell(io, cmd) catch |err| {
        std.log.err("codesign.sign_failed: error={s}", .{@errorName(err)});
        return .{ .ok = false, .message = "codesign failed" };
    };
    return .{ .ok = true, .message = "signed" };
}

/// Tokenize a shell-style command string into an argv array suitable for
/// `std.process.spawn`. Handles POSIX-style quoting (single quotes preserve
/// content literally, double quotes allow backslash escapes for `\`, `"`,
/// `` ` ``, `$`, and newline, and a backslash outside quotes escapes the
/// next character). Adjacent quoted and unquoted segments within a single
/// word are concatenated. The returned slice and all contained slices are
/// allocated by `allocator` and share its lifetime.
fn parseShellCommand(allocator: std.mem.Allocator, cmd: []const u8) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (argv.items) |item| allocator.free(item);
        argv.deinit(allocator);
    }

    var pos: usize = 0;
    while (pos < cmd.len) {
        // Skip inter-token whitespace.
        while (pos < cmd.len and std.ascii.isWhitespace(cmd[pos])) : (pos += 1) {}
        if (pos >= cmd.len) break;

        var token: std.ArrayList(u8) = .empty;
        errdefer token.deinit(allocator);
        var in_single = false;
        var in_double = false;

        while (pos < cmd.len) {
            const c = cmd[pos];
            if (in_single) {
                if (c == '\'') {
                    in_single = false;
                    pos += 1;
                } else {
                    try token.append(allocator, c);
                    pos += 1;
                }
            } else if (in_double) {
                if (c == '\\' and pos + 1 < cmd.len) {
                    const next = cmd[pos + 1];
                    if (next == '\\' or next == '"' or next == '`' or next == '$' or next == '\n') {
                        try token.append(allocator, next);
                        pos += 2;
                    } else {
                        try token.append(allocator, c);
                        pos += 1;
                    }
                } else if (c == '"') {
                    in_double = false;
                    pos += 1;
                } else {
                    try token.append(allocator, c);
                    pos += 1;
                }
            } else if (std.ascii.isWhitespace(c)) {
                break;
            } else if (c == '\'') {
                in_single = true;
                pos += 1;
            } else if (c == '"') {
                in_double = true;
                pos += 1;
            } else if (c == '\\' and pos + 1 < cmd.len) {
                try token.append(allocator, cmd[pos + 1]);
                pos += 2;
            } else {
                try token.append(allocator, c);
                pos += 1;
            }
        }
        // Reject unterminated quotes rather than silently running with a
        // truncated argument.
        if (in_single or in_double) return error.UnterminatedQuote;

        const owned = try token.toOwnedSlice(allocator);
        try argv.append(allocator, owned);
    }

    if (argv.items.len == 0) return error.EmptyCommand;
    return argv.items;
}

fn runShell(io: std.Io, cmd: []const u8) !void {
    // Tokenize the command into an argv array and spawn the target process
    // directly. We deliberately do NOT route through `sh -c`: the previous
    // implementation concatenated caller-supplied paths into a single shell
    // string, which allowed shell command injection from any input
    // (for example, a malicious `app_path` containing `; rm -rf ~`). With
    // argv-based spawn every argument is passed verbatim to the target
    // program and shell metacharacters lose their special meaning.
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const argv = parseShellCommand(arena.allocator(), cmd) catch |err| {
        std.log.err("codesign.run_shell.parse_failed: command=\"{s}\" error={s}", .{ cmd, @errorName(err) });
        return err;
    };
    const argv_text = std.mem.join(arena.allocator(), " ", argv) catch cmd;

    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        std.log.err("codesign.run_shell.spawn_failed: argv={s} error={s}", .{ argv_text, @errorName(err) });
        return err;
    };
    _ = child.wait(io) catch |err| {
        std.log.err("codesign.run_shell.wait_failed: argv={s} error={s}", .{ argv_text, @errorName(err) });
        return err;
    };
}

test "ad-hoc sign command is well-formed" {
    var buffer: [512]u8 = undefined;
    const cmd = try buildSignCommand(&buffer, .{ .app_path = "/tmp/Test.app" });
    try std.testing.expectEqualStrings("codesign --sign - --force --deep /tmp/Test.app", cmd);
}

test "identity sign command includes runtime and entitlements" {
    var buffer: [512]u8 = undefined;
    const cmd = try buildSignCommand(&buffer, .{
        .app_path = "/tmp/Test.app",
        .identity = "Developer ID Application: Test",
        .entitlements = "assets/zero-native.entitlements",
        .hardened_runtime = true,
    });
    try std.testing.expectEqualStrings(
        "codesign --sign Developer ID Application: Test --force --deep --options runtime --entitlements assets/zero-native.entitlements /tmp/Test.app",
        cmd,
    );
}

test "notarize submit command includes team id and wait" {
    var buffer: [512]u8 = undefined;
    const cmd = try buildNotarizeSubmitCommand(&buffer, "/tmp/Test.app.zip", .{
        .app_path = "/tmp/Test.app",
        .team_id = "ABCD1234",
    });
    try std.testing.expectEqualStrings("xcrun notarytool submit /tmp/Test.app.zip --team-id ABCD1234 --wait", cmd);
}

test "staple command targets app path" {
    var buffer: [256]u8 = undefined;
    const cmd = try buildStapleCommand(&buffer, "/tmp/Test.app");
    try std.testing.expectEqualStrings("xcrun stapler staple /tmp/Test.app", cmd);
}

test "zip command uses ditto" {
    var buffer: [256]u8 = undefined;
    const cmd = try buildZipCommand(&buffer, "/tmp/Test.app", "/tmp/Test.app.zip");
    try std.testing.expectEqualStrings("ditto -c -k --keepParent /tmp/Test.app /tmp/Test.app.zip", cmd);
}
