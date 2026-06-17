//! `zero-native updater` — Ed25519 signing and verification CLI for the
//! auto-updater.
//!
//! Subcommands:
//! - `sign`   — sign a file with a private key, write base64 signature
//! - `verify` — verify a signature against a public key, exit 0 / 1
//!
//! Keys are base64-encoded; the public key is 32 bytes, the private
//! key seed is 32 bytes (compatible with `std.crypto.sign.Ed25519`).

const std = @import("std");

fn usage() void {
    std.debug.print(
        \\usage: zero-native updater <command>
        \\
        \\commands:
        \\  sign --key <priv_b64> --input <path> --output <sig_path>
        \\  verify --pubkey <b64> --input <path> --sig <b64>
        \\
    , .{});
}

fn signFile(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    const key_b64 = try flagValue(args, "--key") orelse return error.MissingKey;
    const input_path = try flagValue(args, "--input") orelse return error.MissingInput;
    const output_path = try flagValue(args, "--output") orelse return error.MissingOutput;

    const dec = &std.base64.standard.Decoder;
    const enc = &std.base64.standard.Encoder;

    const key_seed_len = try dec.calcSizeForSlice(key_b64);
    if (key_seed_len != 32) return error.InvalidKey;
    var seed: [32]u8 = undefined;
    try dec.decode(&seed, key_b64);

    const keypair = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch return error.KeyGenFailed;

    const input = try std.Io.Dir.cwd().readFileAlloc(io, input_path, allocator, .unlimited);
    defer allocator.free(input);

    const sig = keypair.sign(input, null) catch return error.SignFailed;
    const sig_bytes = sig.toBytes();
    // Base64-encoded size for 64 bytes is ((64 + 2) / 3) * 4 = 88.
    const sig_b64 = try allocator.alloc(u8, 88);
    defer allocator.free(sig_b64);
    const written = enc.encode(sig_b64, &sig_bytes);
    _ = written;

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = sig_b64 });

    std.debug.print("signature written to {s}\n", .{output_path});
}

fn verifyFile(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    const pubkey_b64 = try flagValue(args, "--pubkey") orelse return error.MissingPubkey;
    const input_path = try flagValue(args, "--input") orelse return error.MissingInput;
    const sig_path = try flagValue(args, "--sig") orelse return error.MissingSig;

    // Read the signature from the file at sig_path.
    const sig_b64 = try std.Io.Dir.cwd().readFileAlloc(io, sig_path, allocator, .unlimited);
    defer allocator.free(sig_b64);

    const dec = &std.base64.standard.Decoder;
    const pk_len = try dec.calcSizeForSlice(pubkey_b64);
    if (pk_len != 32) return error.InvalidPubkey;
    var pk_bytes: [32]u8 = undefined;
    try dec.decode(&pk_bytes, pubkey_b64);

    const sig_len = try dec.calcSizeForSlice(sig_b64);
    if (sig_len != 64) return error.InvalidSignature;
    var sig_bytes: [64]u8 = undefined;
    try dec.decode(&sig_bytes, sig_b64);

    const data = try std.Io.Dir.cwd().readFileAlloc(io, input_path, allocator, .unlimited);
    defer allocator.free(data);

    const sig = std.crypto.sign.Ed25519.Signature.fromBytes(sig_bytes);
    const pk = std.crypto.sign.Ed25519.PublicKey{ .bytes = pk_bytes };

    sig.verify(data, pk) catch {
        std.debug.print("INVALID: signature does not match {s}\n", .{input_path});
        return 1;
    };
    std.debug.print("OK: signature matches {s}\n", .{input_path});
    return 0;
}

fn flagValue(args: []const []const u8, flag: []const u8) !?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag)) {
            if (i + 1 >= args.len) return error.MissingValue;
            return args[i + 1];
        }
        i += 1;
    }
    return null;
}

/// Entry point used by `tools/zero-native/main.zig`. The caller is
/// expected to pass `args` starting at the subcommand, e.g.
/// `["sign", "--key", ...]` or `["verify", "--pubkey", ...]`.
/// Returns the process exit code (0 for success, 1 for verify mismatch,
/// 2 for usage error).
pub fn run(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !u8 {
    if (args.len < 1) {
        usage();
        return 2;
    }
    const sub = args[0];
    if (std.mem.eql(u8, sub, "sign")) {
        try signFile(io, allocator, args[1..]);
        return 0;
    } else if (std.mem.eql(u8, sub, "verify")) {
        return try verifyFile(io, allocator, args[1..]);
    } else {
        usage();
        return 2;
    }
}

test "updater_cli: sign and verify round trip" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    // Use a deterministic 32-byte seed.
    var seed: [32]u8 = undefined;
    for (0..32) |i| seed[i] = @intCast(i + 1);
    const kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch return error.SkipZigTest;
    var priv_b64: [44]u8 = undefined;
    const priv_written = std.base64.standard.Encoder.encode(&priv_b64, &seed);
    _ = priv_written;
    var pub_b64: [44]u8 = undefined;
    const pub_written = std.base64.standard.Encoder.encode(&pub_b64, &kp.public_key.bytes);
    _ = pub_written;

    const input_path = ".zig-cache/test-updater-input.bin";
    const sig_path = ".zig-cache/test-updater-input.sig";
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, ".zig-cache");
    try cwd.writeFile(io, .{ .sub_path = input_path, .data = "hello world" });
    defer cwd.deleteFile(io, input_path) catch {};
    defer cwd.deleteFile(io, sig_path) catch {};

    const sign_args = [_][]const u8{
        "sign",
        "--key",  &priv_b64,
        "--input", input_path,
        "--output", sig_path,
    };
    _ = try run(io, allocator, &sign_args);

    const verify_args = [_][]const u8{
        "verify",
        "--pubkey", &pub_b64,
        "--input",  input_path,
        "--sig",    sig_path,
    };
    const code = try run(io, allocator, &verify_args);
    try std.testing.expectEqual(@as(u8, 0), code);
}
