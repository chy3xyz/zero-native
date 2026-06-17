//! `zero-native codegen` — emit a TypeScript `.d.ts` from a manifest's
//! bridge command schemas.
//!
//! Reads `app.zon`, walks `metadata.bridge_commands`, asks
//! `bridge.codegen.generateTypeScript` to produce the declaration string,
//! and writes it to `--out` (defaults to `zero-native.d.ts` next to the
//! manifest). The output type-signatures each command as taking an opaque
//! string payload and returning a `string` (async handlers), which is the
//! minimum surface required by callers that bridge JSON payloads through.

const std = @import("std");
const bridge_codegen = @import("bridge_codegen");
const manifest_tool = @import("manifest.zig");

pub const Error = error{
    MissingOutArg,
    WriteFailed,
};

/// Parses args for `--out <path>` and a positional manifest path, reads
/// the manifest, builds a `CommandSchema` slice, calls
/// `bridge.codegen.generateTypeScript`, and writes the result.
pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    try runIn(allocator, io, std.Io.Dir.cwd(), args);
}

/// Like `run` but reads the manifest from and writes the output to `base_dir`.
pub fn runIn(allocator: std.mem.Allocator, io: std.Io, base_dir: std.Io.Dir, args: []const []const u8) !void {
    var out_path: ?[]const u8 = null;
    var manifest_path: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--out")) {
            if (index + 1 >= args.len) return error.MissingOutArg;
            index += 1;
            out_path = args[index];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else {
            manifest_path = arg;
        }
    }
    const path = manifest_path orelse "app.zon";

    const metadata = try manifest_tool.readMetadataIn(base_dir, allocator, io, path);
    defer metadata.deinit(allocator);

    const commands = try buildSchemas(allocator, metadata.bridge_commands);
    defer if (commands.len > 0) allocator.free(commands);

    const generated = try bridge_codegen.generateTypeScript(allocator, commands);
    defer allocator.free(generated);

    const output = out_path orelse "zero-native.d.ts";
    var file = try base_dir.createFile(io, output, .{});
    defer file.close(io);
    try file.writePositionalAll(io, generated, 0);

    std.debug.print("wrote {s} (commands: {d})\n", .{ output, commands.len });
}

/// Translates `metadata.bridge_commands` into the codegen's `CommandSchema`
/// representation. Each command takes a single opaque string payload and
/// returns a `Promise<string>` (async handlers always resolve with a JSON
/// string payload).
fn buildSchemas(
    allocator: std.mem.Allocator,
    commands: []const manifest_tool.BridgeCommandMetadata,
) ![]const bridge_codegen.CommandSchema {
    if (commands.len == 0) return &.{};
    const schemas = try allocator.alloc(bridge_codegen.CommandSchema, commands.len);
    for (commands, 0..) |command, slot| {
        schemas[slot] = .{
            .name = command.name,
            .params = &.{
                .{ .name = "payload", .type_name = "string" },
            },
            .result = "string",
        };
    }
    return schemas;
}

fn printUsage() void {
    std.debug.print(
        \\usage: zero-native codegen [--out <path>] [app.zon]
        \\
        \\Reads bridge command schemas from the manifest and writes a TypeScript
        \\.d.ts file with `invoke()` overloads. Defaults: app.zon in cwd,
        \\zero-native.d.ts next to the manifest.
        \\
    , .{});
}

test "codegen run writes a .d.ts with declare module and invoke overloads" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const manifest_text =
        \\.{
        \\  .id = "com.example.codegen",
        \\  .name = "codegen-test",
        \\  .version = "1.0.0",
        \\  .bridge = .{
        \\    .commands = .{
        \\      .{ .name = "native.ping", .origins = .{ "zero://app" } },
        \\      .{ .name = "native.echo", .permissions = .{ "filesystem" } },
        \\      .{ .name = "native.shutdown" },
        \\    },
        \\  },
        \\}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "app.zon", .data = manifest_text });

    const out_path = "codegen-output.d.ts";
    try runIn(allocator, io, tmp.dir, &.{ "app.zon", "--out", out_path });

    const contents = try tmp.dir.readFileAlloc(io, out_path, allocator, .limited(64 * 1024));
    defer allocator.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "declare module \"zero-native\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "export function invoke(cmd: \"native.ping\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "export function invoke(cmd: \"native.echo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "export function invoke(cmd: \"native.shutdown\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Promise<string>") != null);
}

test "codegen run uses app.zon and zero-native.d.ts by default" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const manifest_text =
        \\.{
        \\  .id = "com.example.defaults",
        \\  .name = "defaults-test",
        \\  .version = "0.1.0",
        \\  .bridge = .{
        \\    .commands = .{
        \\      .{ .name = "native.ping" },
        \\      .{ .name = "native.echo" },
        \\    },
        \\  },
        \\}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "app.zon", .data = manifest_text });

    try runIn(allocator, io, tmp.dir, &.{"app.zon"});

    const contents = try tmp.dir.readFileAlloc(io, "zero-native.d.ts", allocator, .limited(64 * 1024));
    defer allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "export function invoke(cmd: \"native.ping\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "export function invoke(cmd: \"native.echo\"") != null);
}