const std = @import("std");

/// Permission grant that allows creating and managing application windows.
pub const permission_window = "window";
/// Permission grant that allows reading from and writing to the local filesystem.
pub const permission_filesystem = "filesystem";
/// Permission grant that allows reading from and writing to the system clipboard.
pub const permission_clipboard = "clipboard";
/// Permission grant that allows making outbound network requests.
pub const permission_network = "network";

/// Action taken when the application requests to open an external hyperlink.
pub const ExternalLinkAction = enum(c_int) {
    /// External links are blocked and not opened.
    deny = 0,
    /// External links are handed off to the system's default browser.
    open_system_browser = 1,
};

/// Policy controlling how external hyperlinks are handled.
pub const ExternalLinkPolicy = struct {
    /// The action to take when an external link is activated.
    action: ExternalLinkAction = .deny,
    /// Optional list of URL patterns that are allowed regardless of `action`.
    allowed_urls: []const []const u8 = &.{},
};

/// Policy controlling which origins the application is permitted to navigate to.
pub const NavigationPolicy = struct {
    /// Origins the application may navigate to. A value of `"*"` matches only
    /// `http://` and `https://` origins; other schemes must be listed explicitly.
    allowed_origins: []const []const u8 = &.{ "zero://app", "zero://inline" },
    /// Policy applied to links that navigate outside the allowed origins.
    external_links: ExternalLinkPolicy = .{},
};

/// Security policy describing requested capabilities and navigation rules.
pub const Policy = struct {
    /// Permission grants the application requests, e.g. `permission_window`.
    permissions: []const []const u8 = &.{},
    /// Navigation rules for the application.
    navigation: NavigationPolicy = .{},
};

/// Returns `true` if `grants` contains `permission`.
pub fn hasPermission(grants: []const []const u8, permission: []const u8) bool {
    for (grants) |grant| {
        if (std.mem.eql(u8, grant, permission)) return true;
    }
    return false;
}

/// Returns `true` if `grants` contains every permission in `required`.
pub fn hasPermissions(grants: []const []const u8, required: []const []const u8) bool {
    for (required) |permission| {
        if (!hasPermission(grants, permission)) return false;
    }
    return true;
}

/// Returns `true` if `origin` is allowed by `allowed_origins`.
/// A wildcard entry `"*"` matches only `http://` and `https://` origins;
/// `file://`, `zero://`, and other schemes must be listed explicitly so
/// bridge permissions cannot be hijacked by local HTML files or inline pages.
pub fn allowsOrigin(allowed_origins: []const []const u8, origin: []const u8) bool {
    for (allowed_origins) |allowed| {
        if (std.mem.eql(u8, allowed, "*")) {
            // Wildcard only matches http(s) origins. file://, zero://, and
            // other schemes must be listed explicitly so bridge permissions
            // cannot be hijacked by local HTML files or inline pages.
            if (std.mem.startsWith(u8, origin, "http://") or
                std.mem.startsWith(u8, origin, "https://")) return true;
            continue;
        }
        if (std.mem.eql(u8, allowed, origin)) return true;
    }
    return false;
}

test "permission checks require every requested grant" {
    try std.testing.expect(hasPermissions(&.{ permission_window, permission_filesystem }, &.{permission_window}));
    try std.testing.expect(!hasPermissions(&.{permission_window}, &.{ permission_window, permission_filesystem }));
}

test "origin checks support exact origins and wildcard" {
    try std.testing.expect(allowsOrigin(&.{ "zero://app", "zero://inline" }, "zero://inline"));
    try std.testing.expect(allowsOrigin(&.{"*"}, "https://example.invalid"));
    try std.testing.expect(!allowsOrigin(&.{"zero://app"}, "https://example.invalid"));
}

test "wildcard origin does not match file or zero schemes" {
    try std.testing.expect(allowsOrigin(&.{"*"}, "https://example.com"));
    try std.testing.expect(allowsOrigin(&.{"*"}, "http://example.com"));
    try std.testing.expect(!allowsOrigin(&.{"*"}, "file:///Users/n0x/index.html"));
    try std.testing.expect(!allowsOrigin(&.{"*"}, "zero://app"));
    try std.testing.expect(!allowsOrigin(&.{"*"}, "zero://inline"));
    // file:// and zero:// origins must be listed explicitly even when "*" is present.
    try std.testing.expect(allowsOrigin(&.{ "*", "zero://app" }, "zero://app"));
    try std.testing.expect(!allowsOrigin(&.{"*"}, "file:///Users/n0x/index.html"));
}

test "security policy property tests" {
    // hasPermission
    try std.testing.expect(!hasPermission(&[_][]const u8{}, "window"));
    try std.testing.expect(hasPermission(&.{permission_window}, "window"));
    try std.testing.expect(!hasPermission(&.{permission_window}, "filesystem"));
    try std.testing.expect(!hasPermission(&.{permission_filesystem}, "file"));

    // hasPermissions
    try std.testing.expect(hasPermissions(&.{permission_window}, &[_][]const u8{}));
    try std.testing.expect(!hasPermissions(&[_][]const u8{}, &.{permission_window}));
    try std.testing.expect(hasPermissions(&.{ permission_window, permission_filesystem }, &.{ permission_window, permission_filesystem }));
    try std.testing.expect(!hasPermissions(&.{permission_window}, &.{ permission_window, permission_filesystem }));
    try std.testing.expect(hasPermissions(&.{permission_window}, &.{ permission_window, permission_window }));

    // allowsOrigin
    try std.testing.expect(allowsOrigin(&.{ "zero://app", "zero://inline" }, "zero://inline"));
    try std.testing.expect(!allowsOrigin(&.{"zero://app"}, "zero://inline"));
    try std.testing.expect(allowsOrigin(&.{"*"}, "http://example.com"));
    try std.testing.expect(allowsOrigin(&.{"*"}, "https://example.com"));
    try std.testing.expect(!allowsOrigin(&.{"*"}, "file:///Users/n0x/index.html"));
    try std.testing.expect(!allowsOrigin(&.{"*"}, "zero://app"));
    try std.testing.expect(!allowsOrigin(&.{"*"}, "ftp://example.com"));
    try std.testing.expect(!allowsOrigin(&.{"*"}, ""));
    try std.testing.expect(allowsOrigin(&.{ "*", "zero://app" }, "zero://app"));
    try std.testing.expect(!allowsOrigin(&.{ "*", "http://example.com" }, "zero://app"));
    try std.testing.expect(!allowsOrigin(&[_][]const u8{}, "https://example.com"));
}
