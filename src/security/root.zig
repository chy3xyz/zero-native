const std = @import("std");
pub const capability = @import("capability.zig");

/// Re-export of the `capability` sub-module so consumers that depend on
/// `security` (e.g. the tooling module) can access `Capability`, `Scope`,
/// and the helper functions without an extra import declaration.
pub const Capability = capability.Capability;
pub const Permission = capability.Permission;
pub const Scope = capability.Scope;
pub const ScopeKind = capability.ScopeKind;
pub const ScopeSet = capability.ScopeSet;
pub const ScopeVars = capability.ScopeVars;
pub const resolveScope = capability.resolveScope;
pub const matchGlob = capability.matchGlob;
pub const allowsPath = capability.allowsPath;

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
///
/// `capabilities` is an opt-in alternative to `permissions`. When the manifest
/// declares at least one capability, the runtime uses
/// `allowsCommandForWindow`/`allowsPathForWindow` to gate bridge commands and
/// path operations on a per-window basis. When `capabilities` is empty (the
/// default) the existing `permission` grant list is the sole gate, preserving
/// the pre-W7 behavior.
pub const Policy = struct {
    /// Permission grants the application requests, e.g. `permission_window`.
    permissions: []const []const u8 = &.{},
    /// Navigation rules for the application.
    navigation: NavigationPolicy = .{},
    /// Window-scoped capability bundles. See `capability.Capability` for the
    /// shape. Defaults to empty; declaring any capability opts into the
    /// window-aware command and path checks in the runtime.
    capabilities: []const capability.Capability = &.{},
    /// Variables used to expand `$NAME` references inside capability scope
    /// patterns (e.g. `$APPDATA`, `$HOME`). Defaults to all-empty, which
    /// makes any pattern that references a variable expand to a string
    /// containing only its literal prefix.
    scope_vars: capability.ScopeVars = .{},
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

/// Finds the first capability whose `windows` list includes `window_label`.
/// Exact label matches take precedence over the `"*"` wildcard: if a
/// capability explicitly lists `window_label`, it is returned in preference
/// to a `"*"` capability. The `"*"` wildcard is used as a fallback when no
/// exact match exists. Returns `null` when no capability targets the given
/// window. The returned `Capability` is a copy of the entry in the input
/// slice; its borrowed slices remain valid for the lifetime of the caller's
/// `capabilities` array.
pub fn findCapability(
    capabilities: []const capability.Capability,
    window_label: []const u8,
) ?capability.Capability {
    var wildcard: ?capability.Capability = null;
    for (capabilities) |cap| {
        for (cap.windows) |label| {
            if (std.mem.eql(u8, label, window_label)) return cap;
            if (wildcard == null and std.mem.eql(u8, label, "*")) wildcard = cap;
        }
    }
    return wildcard;
}

/// Finds the `Permission` with the given `identifier` inside a capability.
/// Returns `null` when no permission matches.
pub fn findPermission(
    capability_: capability.Capability,
    identifier: []const u8,
) ?capability.Permission {
    for (capability_.permissions) |perm| {
        if (std.mem.eql(u8, perm.identifier, identifier)) return perm;
    }
    return null;
}

/// Returns `true` iff `command` is allowed for `window_label` given a set of
/// capabilities, with deny-overrides-allow precedence.
///
/// The lookup order is: window → capability → permission (identifier matches
/// `command`) → origin check. If no capability targets the window, or no
/// permission with the requested identifier exists, the result is `false`
/// (deny by default).
///
/// Origin matching for command permissions: a permission has `scopes` of kind
/// `url`. The command is allowed if at least one `url` allow scope matches
/// `origin` and no `url` deny scope matches. If the permission has no `url`
/// scopes at all, the command is allowed regardless of origin (subject to the
/// capability's window match). Path scopes are ignored for command matching.
pub fn allowsCommandForWindow(
    capabilities: []const capability.Capability,
    window_label: []const u8,
    command: []const u8,
    origin: []const u8,
) bool {
    const cap = findCapability(capabilities, window_label) orelse return false;
    const perm = findPermission(cap, command) orelse return false;

    var has_url_allow = false;
    var has_url_deny = false;
    for (perm.scopes.allow) |scope| {
        if (scope.kind == .url) has_url_allow = true;
    }
    for (perm.scopes.deny) |scope| {
        if (scope.kind == .url) has_url_deny = true;
    }

    // No url scopes at all: the permission is granted based purely on the
    // capability's window match.
    if (!has_url_allow and !has_url_deny) return true;

    // Deny first.
    for (perm.scopes.deny) |scope| {
        if (scope.kind != .url) continue;
        if (capability.matchGlob(scope.pattern, origin)) return false;
    }
    // Then allow.
    for (perm.scopes.allow) |scope| {
        if (scope.kind != .url) continue;
        if (capability.matchGlob(scope.pattern, origin)) return true;
    }
    return false;
}

/// Returns `true` iff `path` is allowed for the given `permission_identifier`
/// (e.g. `"fs:allow-read-text-file"`) scoped to `window_label`. $-variables
/// in scope patterns are resolved using `scope_vars`. Deny overrides allow.
pub fn allowsPathForWindow(
    capabilities: []const capability.Capability,
    scope_vars: capability.ScopeVars,
    window_label: []const u8,
    permission_identifier: []const u8,
    path: []const u8,
) bool {
    const cap = findCapability(capabilities, window_label) orelse return false;
    const perm = findPermission(cap, permission_identifier) orelse return false;
    return capability.allowsPath(perm.scopes, path, scope_vars);
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

test "findCapability matches window label and wildcard" {
    const caps = [_]capability.Capability{
        .{ .identifier = "main-cap", .windows = &.{"main"} },
        .{ .identifier = "all-cap", .windows = &.{"*"} },
    };
    // Exact label match wins over wildcard.
    try std.testing.expectEqualStrings("main-cap", findCapability(&caps, "main").?.identifier);
    // Wildcard covers any other label.
    try std.testing.expectEqualStrings("all-cap", findCapability(&caps, "anything").?.identifier);
    try std.testing.expectEqualStrings("all-cap", findCapability(&caps, "missing").?.identifier);
    // No capability at all -> null.
    try std.testing.expect(findCapability(&[_]capability.Capability{}, "main") == null);
    // No wildcard, no exact match -> null.
    const no_wildcard = [_]capability.Capability{
        .{ .identifier = "main-only", .windows = &.{"main"} },
    };
    try std.testing.expect(findCapability(&no_wildcard, "missing") == null);
}

test "findPermission returns the matching permission" {
    const cap = capability.Capability{
        .identifier = "test",
        .windows = &.{"*"},
        .permissions = &.{
            .{ .identifier = "fs:read" },
            .{ .identifier = "fs:write" },
        },
    };
    try std.testing.expectEqualStrings("fs:read", findPermission(cap, "fs:read").?.identifier);
    try std.testing.expect(findPermission(cap, "missing") == null);
}

test "allowsCommandForWindow deny by default" {
    try std.testing.expect(!allowsCommandForWindow(&.{}, "main", "fs:read", "zero://inline"));
    const caps = [_]capability.Capability{
        .{ .identifier = "main-cap", .windows = &.{"main"}, .permissions = &.{
            .{ .identifier = "fs:read" },
        } },
    };
    try std.testing.expect(!allowsCommandForWindow(&caps, "settings", "fs:read", "zero://inline"));
    try std.testing.expect(!allowsCommandForWindow(&caps, "main", "fs:write", "zero://inline"));
}

test "allowsCommandForWindow allows when window and command match" {
    const caps = [_]capability.Capability{
        .{ .identifier = "main-cap", .windows = &.{"main"}, .permissions = &.{
            .{ .identifier = "fs:read" },
        } },
    };
    try std.testing.expect(allowsCommandForWindow(&caps, "main", "fs:read", "zero://inline"));
}

test "allowsCommandForWindow allows via wildcard window" {
    const caps = [_]capability.Capability{
        .{ .identifier = "anywhere", .windows = &.{"*"}, .permissions = &.{
            .{ .identifier = "fs:read" },
        } },
    };
    try std.testing.expect(allowsCommandForWindow(&caps, "main", "fs:read", "zero://inline"));
    try std.testing.expect(allowsCommandForWindow(&caps, "settings", "fs:read", "zero://inline"));
}

test "allowsCommandForWindow denies when origin not in url allow scopes" {
    const caps = [_]capability.Capability{
        .{ .identifier = "main-cap", .windows = &.{"main"}, .permissions = &.{
            .{
                .identifier = "fs:read",
                .scopes = .{ .allow = &.{.{ .kind = .url, .pattern = "https://example.com/**" }} },
            },
        } },
    };
    try std.testing.expect(allowsCommandForWindow(&caps, "main", "fs:read", "https://example.com/foo"));
    try std.testing.expect(!allowsCommandForWindow(&caps, "main", "fs:read", "https://other.com/foo"));
}

test "allowsCommandForWindow url deny overrides url allow" {
    const caps = [_]capability.Capability{
        .{ .identifier = "main-cap", .windows = &.{"main"}, .permissions = &.{
            .{
                .identifier = "fs:read",
                .scopes = .{
                    .allow = &.{.{ .kind = .url, .pattern = "https://example.com/**" }},
                    .deny = &.{.{ .kind = .url, .pattern = "https://example.com/private/**" }},
                },
            },
        } },
    };
    try std.testing.expect(allowsCommandForWindow(&caps, "main", "fs:read", "https://example.com/public"));
    try std.testing.expect(!allowsCommandForWindow(&caps, "main", "fs:read", "https://example.com/private/x"));
}

test "allowsPathForWindow resolves $APPDATA and matches path under it" {
    const caps = [_]capability.Capability{
        .{ .identifier = "data", .windows = &.{"main"}, .permissions = &.{
            .{
                .identifier = "fs:read",
                .scopes = .{ .allow = &.{.{ .kind = .path, .pattern = "$APPDATA/**" }} },
            },
        } },
    };
    const vars = capability.ScopeVars{ .appdata = "/data" };
    try std.testing.expect(allowsPathForWindow(&caps, vars, "main", "fs:read", "/data/foo.txt"));
    try std.testing.expect(!allowsPathForWindow(&caps, vars, "main", "fs:read", "/etc/passwd"));
    try std.testing.expect(!allowsPathForWindow(&caps, vars, "settings", "fs:read", "/data/foo.txt"));
}

test "allowsPathForWindow deny under $HOME/.ssh overrides allow $HOME/**" {
    const caps = [_]capability.Capability{
        .{ .identifier = "home", .windows = &.{"main"}, .permissions = &.{
            .{
                .identifier = "fs:read",
                .scopes = .{
                    .allow = &.{.{ .kind = .path, .pattern = "$HOME/**" }},
                    .deny = &.{.{ .kind = .path, .pattern = "$HOME/.ssh/**" }},
                },
            },
        } },
    };
    const vars = capability.ScopeVars{ .home = "/home/u" };
    try std.testing.expect(allowsPathForWindow(&caps, vars, "main", "fs:read", "/home/u/notes.txt"));
    try std.testing.expect(!allowsPathForWindow(&caps, vars, "main", "fs:read", "/home/u/.ssh/id_rsa"));
}

test "allowsPathForWindow returns false when no capability or no permission" {
    const caps = [_]capability.Capability{
        .{ .identifier = "main-cap", .windows = &.{"main"}, .permissions = &.{
            .{ .identifier = "fs:write" },
        } },
    };
    // No matching capability for this window.
    try std.testing.expect(!allowsPathForWindow(&caps, .{}, "settings", "fs:write", "/tmp/x"));
    // Capability matches, but permission identifier does not.
    try std.testing.expect(!allowsPathForWindow(&caps, .{}, "main", "fs:read", "/tmp/x"));
}
