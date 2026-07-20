//! `zero-native audit` — checks an `app.zon` manifest against production
//! best practices and reports findings.
//!
//! The audit runs a fixed set of rules against the manifest. Each rule
//! either reports a single `Finding` or no-ops. Findings are tagged
//! `info`/`warn`/`@"error"` so callers can apply different exit-code
//! policies (e.g. fail on any `@"error"`).

const std = @import("std");
const manifest_tool = @import("manifest.zig");
const platform_info = @import("platform_info");

pub const Severity = enum {
    info,
    warn,
    @"error",
};

pub const Finding = struct {
    severity: Severity,
    category: []const u8,
    message: []const u8,
    suggestion: ?[]const u8 = null,
};

pub const Report = struct {
    findings: []Finding,

    /// Frees the findings slice and every owned string within it.
    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.findings) |finding| {
            allocator.free(finding.message);
            if (finding.suggestion) |suggestion| allocator.free(suggestion);
        }
        allocator.free(self.findings);
        self.findings = &.{};
    }

    /// Returns the count of findings with the supplied severity.
    pub fn count(self: Report, severity: Severity) usize {
        var total: usize = 0;
        for (self.findings) |finding| {
            if (finding.severity == severity) total += 1;
        }
        return total;
    }

    /// Returns `true` if at least one finding has severity `@"error"`.
    pub fn hasErrors(self: Report) bool {
        return self.count(.@"error") > 0;
    }

    /// Returns the highest severity present in the report, or `.info` if
    /// there are no findings. Mirrors `severityExitCode` so callers can
    /// branch on either the tag or the numeric exit code.
    pub fn highestSeverity(self: Report) Severity {
        if (self.hasErrors()) return .@"error";
        if (self.count(.warn) > 0) return .warn;
        return .info;
    }
};

/// Maps a single severity to a process exit code. `info` exits 0 so a
/// manifest with only informational findings is considered clean;
/// `warn` exits 1 to surface non-blocking issues; `@"error"` exits 2 to
/// signal blocking findings that should fail CI.
pub fn severityExitCode(severity: Severity) u8 {
    return switch (severity) {
        .info => 0,
        .warn => 1,
        .@"error" => 2,
    };
}

const Ctx = struct {
    allocator: std.mem.Allocator,
    findings: std.ArrayList(Finding),

    fn add(self: *Ctx, severity: Severity, category: []const u8, message: []const u8, suggestion: ?[]const u8) !void {
        try self.findings.append(self.allocator, .{
            .severity = severity,
            .category = category,
            .message = try self.allocator.dupe(u8, message),
            .suggestion = if (suggestion) |text| try self.allocator.dupe(u8, text) else null,
        });
    }
};

/// Reads the manifest at `manifest_path` and produces a `Report` of
/// findings. The caller owns the returned `Report`; free with
/// `report.deinit(allocator)`.
pub fn audit(allocator: std.mem.Allocator, io: std.Io, manifest_path: []const u8) !Report {
    return auditIn(std.Io.Dir.cwd(), allocator, io, manifest_path);
}

/// Like `audit` but reads the manifest from `base_dir`. Used by the test
/// suite to scope manifests inside a temporary directory.
pub fn auditIn(base_dir: std.Io.Dir, allocator: std.mem.Allocator, io: std.Io, manifest_path: []const u8) !Report {
    const metadata = try manifest_tool.readMetadataIn(base_dir, allocator, io, manifest_path);
    defer metadata.deinit(allocator);

    var ctx: Ctx = .{ .allocator = allocator, .findings = .empty };
    errdefer ctx.findings.deinit(allocator);

    const is_macos = platform_info.Target.current().os == .macos;

    // Rule 1: wildcard origins.
    for (metadata.security.navigation.allowed_origins) |origin| {
        if (std.mem.eql(u8, origin, "*")) {
            try ctx.add(.warn, "security", "navigation.allowed_origins contains a wildcard \"*\"", "replace \"*\" with the explicit origins your app loads (e.g. \"zero://app\", \"https://api.example.com\")");
            break;
        }
    }

    // Rule 2: empty capabilities list.
    if (metadata.capabilities.len == 0) {
        try ctx.add(.info, "capabilities", "no structured capabilities declared", "consider listing the windows and permissions the app needs; deny-by-default is enforced when the list is empty");
    }

    // Rule 3: macOS App Sandbox off.
    if (is_macos and !metadata.security.sandbox.sandbox) {
        try ctx.add(.warn, "sandbox", "App Sandbox is disabled on macOS", "set security.sandbox.sandbox = true and adjust the file_read/file_write lists");
    }

    // Rule 4: no icons.
    if (metadata.icons.len == 0) {
        try ctx.add(.warn, "metadata", "no icons declared", "add an icons list (e.g. .{ \"assets/icon.icns\" }) so packaged builds pick up the right artwork");
    }

    // Rule 5: placeholder version.
    if (std.mem.eql(u8, metadata.version, "0.0.0") or std.mem.eql(u8, metadata.version, "0.1.0")) {
        try ctx.add(.warn, "metadata", "version is a placeholder", "set a real semver version (e.g. \"1.0.0\") before publishing");
    }

    // Rule 6: macOS without .icns icon.
    if (platformHas(metadata.platforms, "macos")) {
        if (!iconsIncludeExt(metadata.icons, ".icns")) {
            try ctx.add(.warn, "icons", "macOS is targeted but no .icns icon is listed", "add an icon. icns to the icons list (e.g. .{ \"assets/icon.icns\" })");
        }
    }

    // Rule 7: Windows without .ico icon.
    if (platformHas(metadata.platforms, "windows")) {
        if (!iconsIncludeExt(metadata.icons, ".ico")) {
            try ctx.add(.warn, "icons", "Windows is targeted but no .ico icon is listed", "add an icon. ico to the icons list (e.g. .{ \"assets/icon.ico\" })");
        }
    }

    // Rule 8: empty platforms list.
    if (metadata.platforms.len == 0) {
        try ctx.add(.warn, "metadata", "platforms list is empty", "declare the platforms this app targets (e.g. .{ \"macos\", \"linux\", \"windows\" })");
    }

    // Rule 9: CEF engine with no dir.
    if (std.mem.eql(u8, metadata.web_engine, "cef") and metadata.cef.dir.len == 0) {
        try ctx.add(.@"error", "web-engine", "web_engine = \"cef\" but cef.dir is empty", "set cef.dir to the CEF runtime path (e.g. \"third_party/cef/macos\")");
    }

    // Rule 10: updater feed_url without public_key.
    if (metadata.updates.feed_url.len > 0 and metadata.updates.public_key.len == 0) {
        try ctx.add(.warn, "updates", "updates.feed_url is set but updates.public_key is empty", "generate an Ed25519 keypair and add the base64-encoded public key to sign updates");
    }

    // Rule 11: plugins declared but no bridge commands.
    if (metadata.plugins.len > 0 and metadata.bridge_commands.len == 0) {
        try ctx.add(.info, "bridge", "plugins are enabled but no bridge commands are declared", "add bridge commands to expose plugin functionality to the frontend (e.g. .{ .name = \"clipboard.write_text\" })");
    }

    // Rule 12: deep-link schemes without the deep-link plugin.
    if (metadata.deep_link_schemes.len > 0 and !pluginListContains(metadata.plugins, "deep-link")) {
        try ctx.add(.warn, "plugins", "deep_link_schemes declared but \"deep-link\" plugin is not enabled", "add \"deep-link\" to the .plugins list");
    }

    // Rule 13: no plugins declared.
    if (metadata.plugins.len == 0) {
        try ctx.add(.info, "plugins", "no plugins declared — the app has no native capabilities beyond bridge commands", "enable plugins like \"clipboard\", \"store\", \"notification\" to add native features");
    }

    // Rule 14: excessive allowed origins.
    if (metadata.security.navigation.allowed_origins.len > 10) {
        try ctx.add(.warn, "security", "navigation.allowed_origins has many entries — review for unnecessary exposure", "limit origins to only those the app actually loads");
    }

    return .{ .findings = try ctx.findings.toOwnedSlice(allocator) };
}

fn platformHas(platforms: []const []const u8, target: []const u8) bool {
    for (platforms) |p| {
        if (std.mem.eql(u8, p, target)) return true;
    }
    return false;
}

fn iconsIncludeExt(icons: []const []const u8, ext: []const u8) bool {
    for (icons) |icon| {
        if (std.mem.endsWith(u8, icon, ext)) return true;
    }
    return false;
}

fn pluginListContains(plugins: []const []const u8, name: []const u8) bool {
    for (plugins) |p| {
        if (std.mem.eql(u8, p, name)) return true;
    }
    return false;
}

fn printReport(report: Report) void {
    if (report.findings.len == 0) {
        std.debug.print("no findings\n", .{});
        return;
    }
    for (report.findings) |finding| {
        const prefix: []const u8 = switch (finding.severity) {
            .info => "[i]",
            .warn => "[!]",
            .@"error" => "[X]",
        };
        if (finding.suggestion) |suggestion| {
            std.debug.print("{s} [{s}] {s}\n    // fix: {s}\n", .{ prefix, finding.category, finding.message, suggestion });
        } else {
            std.debug.print("{s} [{s}] {s}\n", .{ prefix, finding.category, finding.message });
        }
    }
    std.debug.print("\nsummary: {d} info, {d} warn, {d} error\n", .{
        report.count(.info),
        report.count(.warn),
        report.count(.@"error"),
    });
}

fn usage() void {
    std.debug.print(
        \\usage: zero-native audit [app.zon]
        \\
        \\Reads the manifest and reports production-readiness findings.
        \\Defaults to ./app.zon.
        \\
        \\Exits 0 when only info findings are reported, 1 when warnings
        \\are present, and 2 when blocking errors are found.
        \\
    , .{});
}

/// Runs the audit against `manifest_path`, prints the findings, and
/// returns the highest-severity exit code (0/1/2). `args` is accepted
/// for symmetry with `run` and is reserved for future flags.
pub fn auditRun(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8, manifest_path: []const u8) !u8 {
    _ = args;
    var report = try audit(allocator, io, manifest_path);
    defer report.deinit(allocator);
    printReport(report);
    return severityExitCode(report.highestSeverity());
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    var path: []const u8 = "app.zon";
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return 0;
        }
        path = arg;
    }
    return auditRun(allocator, io, args, path);
}

const auditFixture =
    \\.{
    \\  .id = "com.example.audit",
    \\  .name = "audit-good",
    \\  .version = "1.2.3",
    \\  .icons = .{ "assets/icon.icns" },
    \\  .platforms = .{ "macos" },
    \\  .plugins = .{ "clipboard" },
    \\  .bridge = .{
    \\    .commands = .{
    \\      .{ .name = "clipboard.write_text" },
    \\    },
    \\  },
    \\  .security = .{
    \\    .navigation = .{
    \\      .allowed_origins = .{ "zero://app", "zero://inline" },
    \\    },
    \\    .sandbox = .{
    \\      .sandbox = true,
    \\    },
    \\  },
    \\  .capabilities = .{
    \\    .{
    \\      .identifier = "core",
    \\      .description = "core capabilities",
    \\      .windows = .{ "main" },
    \\      .permissions = .{
    \\        .{ .identifier = "window:allow-close" },
    \\      },
    \\    },
    \\  },
    \\}
;

test "audit on a known-good manifest produces 0 errors" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "app.zon", .data = auditFixture });

    var report = try auditIn(tmp.dir, allocator, io, "app.zon");
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), report.count(.@"error"));
    try std.testing.expectEqual(@as(usize, 0), report.findings.len);
}

test "audit on wildcard origin produces a warning" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const manifest_text =
        \\.{
        \\  .id = "com.example.audit",
        \\  .name = "audit-wildcard",
        \\  .version = "1.2.3",
        \\  .icons = .{ "assets/icon.icns" },
        \\  .platforms = .{ "macos" },
        \\  .security = .{
        \\    .navigation = .{
        \\      .allowed_origins = .{ "*" },
        \\    },
        \\    .sandbox = .{
        \\      .sandbox = true,
        \\    },
        \\  },
        \\  .capabilities = .{
        \\    .{
        \\      .identifier = "core",
        \\      .description = "core capabilities",
        \\      .windows = .{ "main" },
        \\      .permissions = .{
        \\        .{ .identifier = "window:allow-close" },
        \\      },
        \\    },
        \\  },
        \\}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "app.zon", .data = manifest_text });

    var report = try auditIn(tmp.dir, allocator, io, "app.zon");
    defer report.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), report.count(.warn));
    try std.testing.expectEqualStrings("security", report.findings[0].category);
}

test "audit on placeholder version 0.0.0 produces a warning" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const manifest_text =
        \\.{
        \\  .id = "com.example.audit",
        \\  .name = "audit-version",
        \\  .version = "0.0.0",
        \\  .icons = .{ "assets/icon.png" },
        \\  .platforms = .{ "macos" },
        \\  .security = .{
        \\    .navigation = .{
        \\      .allowed_origins = .{ "zero://app" },
        \\    },
        \\    .sandbox = .{
        \\      .sandbox = true,
        \\    },
        \\  },
        \\  .capabilities = .{
        \\    .{
        \\      .identifier = "core",
        \\      .description = "core capabilities",
        \\      .windows = .{ "main" },
        \\      .permissions = .{
        \\        .{ .identifier = "window:allow-close" },
        \\      },
        \\    },
        \\  },
        \\}
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "app.zon", .data = manifest_text });

    var report = try auditIn(tmp.dir, allocator, io, "app.zon");
    defer report.deinit(allocator);

    var found: usize = 0;
    for (report.findings) |finding| {
        if (finding.severity == .warn and std.mem.eql(u8, finding.category, "metadata")) found += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), found);
}

test "Report.deinit frees all findings" {
    const allocator = std.testing.allocator;
    var report = Report{ .findings = &.{} };
    report.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), report.findings.len);
}

test "severityExitCode maps info to 0" {
    try std.testing.expectEqual(@as(u8, 0), severityExitCode(.info));
}

test "severityExitCode maps warn to 1" {
    try std.testing.expectEqual(@as(u8, 1), severityExitCode(.warn));
}

test "severityExitCode maps error to 2" {
    try std.testing.expectEqual(@as(u8, 2), severityExitCode(.@"error"));
}
