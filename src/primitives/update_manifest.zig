//! Update manifest parsing, version comparison, and Ed25519 signature
//! verification for the zero-native auto-updater (Wave 14).
//!
//! ## Manifest format
//! ```json
//! { "version": "1.0.0", "notes": "...",
//!   "platforms": { "macos-aarch64": { "url": "...", "signature": "...", "size": 0 } } }
//! ```

const std = @import("std");

/// A parsed semantic-version triple. All fields are non-negative integers.
pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
};

/// Identifies a target platform for update delivery.
pub const PlatformTarget = struct {
    os: []const u8,
    arch: []const u8,
};

/// Describes one platform-specific update asset.
pub const PlatformEntry = struct {
    url: []const u8,
    signature: []const u8,
    size: usize = 0,
};

/// A parsed update manifest.
pub const Manifest = struct {
    version: Version,
    notes: []const u8 = "",
    platforms: std.StringHashMap(PlatformEntry),
};

/// Parse a dotted version string into a `Version`.
///
/// Accepts "major.minor.patch" with non-negative decimal integers separated
/// by exactly two dots. Rejects non-numeric segments, empty strings, and
/// strings with fewer or more than two dots.
pub fn parseVersion(version_str: []const u8) !Version {
    if (version_str.len == 0) return error.InvalidVersion;

    var parts: [3]u32 = undefined;
    var part_count: usize = 0;
    var iter = std.mem.splitScalar(u8, version_str, '.');
    while (iter.next()) |segment| {
        if (segment.len == 0) return error.InvalidVersion;
        if (part_count >= 3) return error.InvalidVersion;
        const num = std.fmt.parseUnsigned(u32, segment, 10) catch return error.InvalidVersion;
        parts[part_count] = num;
        part_count += 1;
    }
    if (part_count != 3) return error.InvalidVersion;

    return .{
        .major = parts[0],
        .minor = parts[1],
        .patch = parts[2],
    };
}

/// Compare two versions, returning `.lt`, `.eq`, or `.gt`.
/// Compares major first, then minor, then patch.
pub fn compareVersion(a: Version, b: Version) std.math.Order {
    if (a.major < b.major) return .lt;
    if (a.major > b.major) return .gt;
    if (a.minor < b.minor) return .lt;
    if (a.minor > b.minor) return .gt;
    if (a.patch < b.patch) return .lt;
    if (a.patch > b.patch) return .gt;
    return .eq;
}

/// Parse a JSON manifest from raw bytes using `allocator` for all owned
/// memory (strings, hashmap, and entries). The caller must call
/// `deinitManifest` to release the memory.
pub fn parseManifest(allocator: std.mem.Allocator, json_bytes: []const u8) !Manifest {
    var manifest: Manifest = .{
        .version = .{ .major = 0, .minor = 0, .patch = 0 },
        .notes = "",
        .platforms = std.StringHashMap(PlatformEntry).init(allocator),
    };
    errdefer deinitManifest(&manifest, allocator);

    // Pre-allocate a scratch buffer for unescaped string values.
    const scratch_len = json_bytes.len * 2;
    const scratch = try allocator.alloc(u8, scratch_len);
    defer allocator.free(scratch);
    var storage = StringStorage.init(scratch);

    const version_raw = stringField(json_bytes, "version", &storage) orelse {
        return error.InvalidManifest;
    };
    const version_str = try allocator.dupe(u8, version_raw);
    manifest.version = parseVersion(version_str) catch {
        allocator.free(version_str);
        return error.InvalidManifest;
    };
    allocator.free(version_str);

    if (stringField(json_bytes, "notes", &storage)) |notes_raw| {
        manifest.notes = try allocator.dupe(u8, notes_raw);
    }

    // Parse the platforms object.
    const platforms_obj = fieldValue(json_bytes, "platforms") orelse {
        // platforms is technically required, but tolerate its absence.
        return manifest;
    };

    var p_index: usize = 0;
    skipWhitespace(platforms_obj, &p_index);
    if (p_index >= platforms_obj.len or platforms_obj[p_index] != '{') {
        return manifest;
    }
    p_index += 1;

    while (p_index < platforms_obj.len) {
        skipWhitespace(platforms_obj, &p_index);
        if (p_index < platforms_obj.len and platforms_obj[p_index] == '}') {
            break;
        }
        if (p_index < platforms_obj.len and platforms_obj[p_index] == ',') {
            p_index += 1;
            skipWhitespace(platforms_obj, &p_index);
            continue;
        }

        // Read the platform key.
        const key_raw = rawStringValue(platforms_obj, &p_index) catch return error.InvalidManifest;
        const key = try allocator.dupe(u8, key_raw);
        errdefer allocator.free(key);

        skipWhitespace(platforms_obj, &p_index);
        if (p_index >= platforms_obj.len or platforms_obj[p_index] != ':') {
            allocator.free(key);
            return error.InvalidManifest;
        }
        p_index += 1;

        // Read the platform entry object.
        const entry_raw = rawObjectValue(platforms_obj, &p_index) catch return error.InvalidManifest;

        var entry: PlatformEntry = .{ .url = "", .signature = "", .size = 0 };

        // Reset storage for each entry's strings.
        storage = StringStorage.init(scratch);

        const url_raw = stringField(entry_raw, "url", &storage) orelse {
            allocator.free(key);
            return error.InvalidManifest;
        };
        entry.url = try allocator.dupe(u8, url_raw);
        errdefer allocator.free(entry.url);

        if (stringField(entry_raw, "signature", &storage)) |sig_raw| {
            entry.signature = try allocator.dupe(u8, sig_raw);
        }
        errdefer allocator.free(entry.signature);

        if (unsignedField(usize, entry_raw, "size")) |sz| {
            entry.size = sz;
        }

        try manifest.platforms.put(key, entry);

        skipWhitespace(platforms_obj, &p_index);
        if (p_index < platforms_obj.len and platforms_obj[p_index] == ',') {
            p_index += 1;
            continue;
        }
    }

    return manifest;
}

/// Release all memory owned by a Manifest.
pub fn deinitManifest(self: *Manifest, allocator: std.mem.Allocator) void {
    var iter = self.platforms.iterator();
    while (iter.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.url);
        if (entry.value_ptr.signature.len > 0) allocator.free(entry.value_ptr.signature);
    }
    self.platforms.deinit();
    if (self.notes.len > 0) allocator.free(self.notes);
}

/// Verify an Ed25519 signature over `data`.
///
/// `public_key` is the raw 32-byte Ed25519 public key.
/// `signature_b64` is a standard base64-encoded signature (64 bytes decoded).
/// Returns `true` if the signature is valid, `false` otherwise.
/// Returns an error if the base64 decoding fails or the signature length is
/// wrong.
pub fn verifySignature(public_key: [32]u8, data: []const u8, signature_b64: []const u8) !bool {
    // Determine the decoded signature length.
    const sig_len = try std.base64.standard.Decoder.calcSizeForSlice(signature_b64);
    if (sig_len != 64) return error.InvalidSignature;
    var sig_bytes: [64]u8 = undefined;
    try std.base64.standard.Decoder.decode(&sig_bytes, signature_b64);

    const sig = std.crypto.sign.Ed25519.Signature.fromBytes(sig_bytes);
    const pk = std.crypto.sign.Ed25519.PublicKey{ .bytes = public_key };

    std.crypto.sign.Ed25519.Signature.verify(sig, data, pk) catch {
        return false;
    };
    return true;
}

// ---------------------------------------------------------------------------
// Shared StringStorage (compatible with src/primitives/json/root.zig)
// ---------------------------------------------------------------------------

const StringStorage = struct {
    buffer: []u8,
    index: usize = 0,

    fn init(buffer: []u8) StringStorage {
        return .{ .buffer = buffer };
    }

    fn append(self: *StringStorage, bytes: []const u8) !void {
        if (self.index + bytes.len > self.buffer.len) return error.NoSpaceLeft;
        @memcpy(self.buffer[self.index..][0..bytes.len], bytes);
        self.index += bytes.len;
    }

    fn appendByte(self: *StringStorage, byte: u8) !void {
        if (self.index >= self.buffer.len) return error.NoSpaceLeft;
        self.buffer[self.index] = byte;
        self.index += 1;
    }
};

// ---------------------------------------------------------------------------
// JSON helpers (self-contained; mirrors src/primitives/json/root.zig)
// ---------------------------------------------------------------------------

fn skipWhitespace(bytes: []const u8, index: *usize) void {
    while (index.* < bytes.len and std.ascii.isWhitespace(bytes[index.*])) : (index.* += 1) {}
}

fn fieldValue(payload: []const u8, field: []const u8) ?[]const u8 {
    var index: usize = 0;
    skipWhitespace(payload, &index);
    if (index >= payload.len or payload[index] != '{') return null;
    index += 1;
    while (index < payload.len) {
        skipWhitespace(payload, &index);
        if (index < payload.len and payload[index] == '}') return null;
        const key = parseRawString(payload, &index) orelse return null;
        skipWhitespace(payload, &index);
        if (index >= payload.len or payload[index] != ':') return null;
        index += 1;
        skipWhitespace(payload, &index);
        const value_start = index;
        skipValueSpan(payload, &index) orelse return null;
        const value = payload[value_start..index];
        if (std.mem.eql(u8, key, field)) return value;
        skipWhitespace(payload, &index);
        if (index < payload.len and payload[index] == ',') {
            index += 1;
            continue;
        }
        if (index < payload.len and payload[index] == '}') return null;
        return null;
    }
    return null;
}

fn stringField(payload: []const u8, field: []const u8, storage: *StringStorage) ?[]const u8 {
    const value = fieldValue(payload, field) orelse return null;
    return parseStringValue(value, storage) catch null;
}

fn unsignedField(comptime T: type, payload: []const u8, field: []const u8) ?T {
    const value = fieldValue(payload, field) orelse return null;
    return std.fmt.parseUnsigned(T, value, 10) catch null;
}

fn parseStringValue(value: []const u8, storage: *StringStorage) ![]const u8 {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.InvalidJson;
    var index: usize = 1;
    const direct_start = index;
    var copied = false;
    const output_start = storage.index;
    while (index + 1 < value.len) {
        const ch = value[index];
        if (ch == '\\') {
            if (!copied) {
                try storage.append(value[direct_start..index]);
                copied = true;
            }
            index += 1;
            if (index + 1 >= value.len) return error.InvalidJson;
            switch (value[index]) {
                '"' => try storage.appendByte('"'),
                '\\' => try storage.appendByte('\\'),
                '/' => try storage.appendByte('/'),
                'b' => try storage.appendByte(0x08),
                'f' => try storage.appendByte(0x0c),
                'n' => try storage.appendByte('\n'),
                'r' => try storage.appendByte('\r'),
                't' => try storage.appendByte('\t'),
                'u' => {
                    if (index + 4 >= value.len) return error.InvalidJson;
                    const codepoint = try hex4(value[index + 1 .. index + 5]);
                    if (codepoint > 0x7f) return error.NonAsciiEscape;
                    try storage.appendByte(@intCast(codepoint));
                    index += 4;
                },
                else => return error.InvalidJson,
            }
            index += 1;
            continue;
        }
        if (ch <= 0x1f) return error.InvalidJson;
        if (copied) try storage.appendByte(ch);
        index += 1;
    }
    if (!copied) return value[direct_start .. value.len - 1];
    return storage.buffer[output_start..storage.index];
}

fn parseRawString(bytes: []const u8, index: *usize) ?[]const u8 {
    if (index.* >= bytes.len or bytes[index.*] != '"') return null;
    index.* += 1;
    const start = index.*;
    while (index.* < bytes.len) : (index.* += 1) {
        const ch = bytes[index.*];
        if (ch == '"') {
            const value = bytes[start..index.*];
            index.* += 1;
            return value;
        }
        if (ch == '\\') {
            index.* += 1;
            if (index.* >= bytes.len) return null;
        } else if (ch <= 0x1f) {
            return null;
        }
    }
    return null;
}

fn rawStringValue(bytes: []const u8, index: *usize) ![]const u8 {
    skipWhitespace(bytes, index);
    if (index.* >= bytes.len or bytes[index.*] != '"') return error.InvalidJson;
    index.* += 1;
    const start = index.*;
    while (index.* < bytes.len) : (index.* += 1) {
        const ch = bytes[index.*];
        if (ch == '"') {
            const value = bytes[start..index.*];
            index.* += 1;
            return value;
        }
        if (ch == '\\') {
            index.* += 1;
            if (index.* >= bytes.len) return error.InvalidJson;
        } else if (ch <= 0x1f) {
            return error.InvalidJson;
        }
    }
    return error.InvalidJson;
}

fn rawObjectValue(bytes: []const u8, index: *usize) ![]const u8 {
    skipWhitespace(bytes, index);
    if (index.* >= bytes.len or bytes[index.*] != '{') return error.InvalidJson;
    const start = index.*;
    index.* += 1;
    var depth: usize = 1;
    while (index.* < bytes.len) {
        const ch = bytes[index.*];
        if (ch == '"') {
            _ = parseRawString(bytes, index) orelse return error.InvalidJson;
            continue;
        }
        if (ch == '{') depth += 1;
        if (ch == '}') {
            depth -= 1;
            if (depth == 0) {
                const value = bytes[start .. index.* + 1];
                index.* += 1;
                return value;
            }
        }
        if (ch == '\\') {
            index.* += 1;
        }
        index.* += 1;
    }
    return error.InvalidJson;
}

fn skipValueSpan(bytes: []const u8, index: *usize) ?void {
    if (index.* >= bytes.len) return null;
    return switch (bytes[index.*]) {
        '"' => if (parseRawString(bytes, index) != null) {} else null,
        '{' => skipContainerSpan(bytes, index, '{', '}'),
        '[' => skipContainerSpan(bytes, index, '[', ']'),
        else => skipAtomSpan(bytes, index),
    };
}

fn skipContainerSpan(bytes: []const u8, index: *usize, open: u8, close: u8) ?void {
    if (index.* >= bytes.len or bytes[index.*] != open) return null;
    index.* += 1;
    skipWhitespace(bytes, index);
    if (index.* < bytes.len and bytes[index.*] == close) {
        index.* += 1;
        return;
    }
    while (index.* < bytes.len) {
        skipWhitespace(bytes, index);
        if (open == '{') {
            _ = parseRawString(bytes, index) orelse return null;
            skipWhitespace(bytes, index);
            if (index.* >= bytes.len or bytes[index.*] != ':') return null;
            index.* += 1;
            skipWhitespace(bytes, index);
        }
        skipValueSpan(bytes, index) orelse return null;
        skipWhitespace(bytes, index);
        if (index.* < bytes.len and bytes[index.*] == ',') {
            index.* += 1;
            continue;
        }
        if (index.* < bytes.len and bytes[index.*] == close) {
            index.* += 1;
            return;
        }
        return null;
    }
    return null;
}

fn skipAtomSpan(bytes: []const u8, index: *usize) ?void {
    const start = index.*;
    while (index.* < bytes.len) : (index.* += 1) {
        switch (bytes[index.*]) {
            ',', '}', ']', ' ', '\n', '\r', '\t' => break,
            else => {},
        }
    }
    if (index.* == start) return null;
    const atom = bytes[start..index.*];
    if (std.mem.eql(u8, atom, "true") or std.mem.eql(u8, atom, "false") or std.mem.eql(u8, atom, "null")) return;
    _ = std.fmt.parseFloat(f64, atom) catch return null;
}

fn hex4(bytes: []const u8) !u21 {
    if (bytes.len != 4) return error.InvalidJson;
    var result: u21 = 0;
    for (bytes) |ch| {
        result <<= 4;
        result |= hexValue(ch) orelse return error.InvalidJson;
    }
    return result;
}

fn hexValue(ch: u8) ?u21 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "update manifest: parseVersion" {
    {
        const v = try parseVersion("1.2.3");
        try std.testing.expectEqual(@as(u32, 1), v.major);
        try std.testing.expectEqual(@as(u32, 2), v.minor);
        try std.testing.expectEqual(@as(u32, 3), v.patch);
    }
    {
        try std.testing.expectError(error.InvalidVersion, parseVersion("abc"));
    }
    {
        try std.testing.expectError(error.InvalidVersion, parseVersion("1.2"));
    }
    {
        try std.testing.expectError(error.InvalidVersion, parseVersion(""));
    }
    {
        try std.testing.expectError(error.InvalidVersion, parseVersion("1.2.3.4"));
    }
}

test "update manifest: compareVersion" {
    const a = Version{ .major = 1, .minor = 0, .patch = 0 };
    const b = Version{ .major = 1, .minor = 0, .patch = 1 };
    try std.testing.expectEqual(std.math.Order.lt, compareVersion(a, b));

    const c = Version{ .major = 2, .minor = 0, .patch = 0 };
    const d = Version{ .major = 1, .minor = 9, .patch = 9 };
    try std.testing.expectEqual(std.math.Order.gt, compareVersion(c, d));

    const e = Version{ .major = 1, .minor = 0, .patch = 0 };
    const f = Version{ .major = 1, .minor = 0, .patch = 0 };
    try std.testing.expectEqual(std.math.Order.eq, compareVersion(e, f));
}

test "update manifest: parseManifest" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "version": "1.2.3",
        \\  "notes": "This is an update",
        \\  "platforms": {
        \\    "macos-aarch64": {
        \\      "url": "http://example.com/update.tar.gz",
        \\      "signature": "c2lnbmF0dXJlLWRhdGE=",
        \\      "size": 1024
        \\    }
        \\  }
        \\}
    ;
    var manifest = try parseManifest(allocator, json);
    defer deinitManifest(&manifest, allocator);

    try std.testing.expectEqual(@as(u32, 1), manifest.version.major);
    try std.testing.expectEqual(@as(u32, 2), manifest.version.minor);
    try std.testing.expectEqual(@as(u32, 3), manifest.version.patch);
    try std.testing.expectEqualStrings("This is an update", manifest.notes);

    const entry = manifest.platforms.get("macos-aarch64").?;
    try std.testing.expectEqualStrings("http://example.com/update.tar.gz", entry.url);
    try std.testing.expectEqualStrings("c2lnbmF0dXJlLWRhdGE=", entry.signature);
    try std.testing.expectEqual(@as(usize, 1024), entry.size);
}

test "update manifest: deinitManifest frees all strings" {
    const allocator = std.testing.allocator;
    const json =
        \\{"version":"1.0.0","notes":"test","platforms":{"linux-x64":{"url":"http://x","signature":"y","size":1}}}
    ;
    var manifest = try parseManifest(allocator, json);
    deinitManifest(&manifest, allocator);
    // No leak — std.testing.allocator will detect if anything was not freed.
}

test "update manifest: verifySignature round-trip" {
    const kp = std.crypto.sign.Ed25519.KeyPair.generate(std.testing.io);
    const data = "hello world";
    const sig = try kp.sign(data, null);
    const sig_bytes = sig.toBytes();

    var b64_buf: [128]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&b64_buf, &sig_bytes);

    const valid = try verifySignature(kp.public_key.bytes, data, b64);
    try std.testing.expect(valid);

    // Tampered data should fail.
    const invalid = try verifySignature(kp.public_key.bytes, data ++ "x", b64);
    try std.testing.expect(!invalid);
}
