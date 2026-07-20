//! VCR (record/replay) for deterministic automation testing.
//!
//! Record captures every frame + bridge command into a session file.
//! Replay reads the file, injects commands at the correct frames, and
//! verifies that frame fingerprints match the recording.
//!
//! Session file format (plain text, line-based):
//!   F <frame_index> <command_count> <frame_hash_hex>
//!   B <bridge_payload_json>
//!   # comments

const std = @import("std");
const snapshot_mod = @import("snapshot.zig");
const crypto = std.crypto;

/// Maximum session file size (16 MiB).
pub const max_session_bytes: usize = 16 * 1024 * 1024;

/// A single frame record in a session file.
pub const Frame = struct {
    index: u64,
    command_count: usize,
    hash: u64, // truncated SHA-256 fingerprint
};

/// VCR session — holds the raw lines and parsed frame list.
pub const Session = struct {
    frames: std.ArrayList(Frame),
    lines: std.ArrayList([]const u8), // line in the session file
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Session) void {
        for (self.lines.items) |line| self.allocator.free(line);
        self.lines.deinit(self.allocator);
        self.frames.deinit(self.allocator);
    }
};

/// Compute a deterministic fingerprint for a snapshot input.
pub fn frameHash(input: snapshot_mod.Input) u64 {
    var hasher = crypto.hash.sha2.Sha256.init(.{});
    // Include frame index and command count for uniqueness
    var idx_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &idx_buf, input.diagnostics.frame_index, .little);
    hasher.update(&idx_buf);
    std.mem.writeInt(u64, &idx_buf, input.diagnostics.command_count, .little);
    hasher.update(&idx_buf);

    // Hash window info
    for (input.windows) |window| {
        std.mem.writeInt(u64, &idx_buf, window.id, .little);
        hasher.update(&idx_buf);
        hasher.update(window.title);
        std.mem.writeInt(u64, &idx_buf, @bitCast(window.focused), .little);
        hasher.update(&idx_buf);
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.mem.readInt(u64, digest[0..8], .little);
}

/// Recorder captures frames and bridge commands into a session file.
pub const Recorder = struct {
    io: std.Io,
    file: std.Io.Dir,
    path: []const u8,
    frame_count: u64 = 0,

    pub fn init(io: std.Io, path: []const u8) !Recorder {
        var cwd = std.Io.Dir.cwd();
        _ = cwd.deleteFile(io, path) catch {};
        return .{ .io = io, .file = cwd, .path = path };
    }

    /// Record a frame snapshot. Writes an `F` line to the session file.
    pub fn recordFrame(self: *Recorder, input: snapshot_mod.Input) !void {
        const hash = frameHash(input);
        var line: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "F {d} {d} {x}\n", .{
            input.diagnostics.frame_index,
            input.diagnostics.command_count,
            hash,
        });
        try self.append(text);
        self.frame_count = input.diagnostics.frame_index;
    }

    /// Record a bridge command. Writes a `B` line.
    pub fn recordBridge(self: *Recorder, command: []const u8) !void {
        var line: [512]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "B {s}\n", .{command});
        try self.append(text);
    }

    fn append(self: *Recorder, text: []const u8) !void {
        var file = try self.file.openFile(self.io, self.path, .{
            .mode = .write_only,
            .create = true,
            .append = true,
        });
        defer file.close(self.io);
        _ = file.write(self.io, text) catch {};
    }
};

/// Player reads a session file and verifies frame hashes match.
pub const Player = struct {
    session: Session,
    cursor: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Player {
        var cwd = std.Io.Dir.cwd();
        const raw = try cwd.readFileAlloc(io, path, allocator, std.Io.Limit.limited(max_session_bytes));
        defer allocator.free(raw);

        var session: Session = .{
            .frames = std.ArrayList(Frame).empty,
            .lines = std.ArrayList([]const u8).empty,
            .allocator = allocator,
        };

        var iter = std.mem.splitScalar(u8, raw, '\n');
        while (iter.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \r\t");
            if (line.len == 0 or line[0] == '#') continue;
            const stored = try allocator.dupe(u8, line);
            try session.lines.append(allocator, stored);

            if (line[0] == 'F') {
                // F <frame_index> <command_count> <hash>
                var parts = std.mem.splitScalar(u8, line, ' ');
                _ = parts.next(); // skip 'F'
                const idx_str = parts.next() orelse continue;
                const cmd_str = parts.next() orelse continue;
                const hash_str = parts.next() orelse continue;
                const idx = std.fmt.parseUnsigned(u64, idx_str, 10) catch continue;
                const cmd_count = std.fmt.parseUnsigned(usize, cmd_str, 10) catch continue;
                const hash = std.fmt.parseUnsigned(u64, hash_str, 16) catch continue;
                try session.frames.append(allocator, .{ .index = idx, .command_count = cmd_count, .hash = hash });
            }
        }

        return .{ .session = session };
    }

    pub fn deinit(self: *Player) void {
        self.session.deinit();
    }

    /// Verify the current frame matches the expected fingerprint. Advances
    /// the cursor past frame and bridge lines to the next expected frame.
    /// Returns the expected frame or null if session is complete.
    pub fn verifyFrame(self: *Player, input: snapshot_mod.Input) !?Frame {
        if (self.cursor >= self.session.frames.items.len) return null;
        const expected = self.session.frames.items[self.cursor];
        self.cursor += 1;

        const actual_hash = frameHash(input);
        if (actual_hash != expected.hash) {
            return error.FrameMismatch;
        }
        return expected;
    }

    /// Returns the next bridge command from the session, or null.
    pub fn nextBridgeCommand(self: *Player) ?[]const u8 {
        for (self.session.lines.items[self.cursor..]) |line| {
            if (line.len > 1 and line[0] == 'B' and line[1] == ' ') {
                return line[2..];
            }
        }
        return null;
    }
};
