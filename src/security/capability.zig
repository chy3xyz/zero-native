//! Capability policies for zero-native apps.
//!
//! A `Capability` declares a named security policy that ties together the
//! windows it applies to and the granular permissions it grants. Each
//! `Permission` carries an identifier (for example
//! `fs:allow-read-text-file`) plus a `ScopeSet` describing the allowed
//! and denied filesystem paths or URL origins.
//!
//! Capabilities extend, but do not replace, the coarse `security.Policy`
//! permission grants. The runtime checks `security.Policy.permissions`
//! before consulting capabilities, then narrows the answer with the
//! capability's `windows` and `permissions` entries. The same deny-
//! overrides-allow rule used in `allowsPath` is honored when a
//! permission's `deny` scopes match even if its `allow` scopes also do,
//! so an app can grant broad read access to `$APPDATA/**` while still
//! blocking `$APPDATA/secret/**`.

const std = @import("std");

/// Kind of scope entry: a filesystem path glob or a URL origin glob.
pub const ScopeKind = enum {
    /// Filesystem path glob, e.g. `$APPDATA/**`.
    path,
    /// URL origin glob, e.g. `https://api.example.com/*`.
    url,
};

/// A single scope entry: a glob pattern paired with the kind of value it
/// matches.
pub const Scope = struct {
    /// Kind of scope (filesystem path or URL origin).
    kind: ScopeKind,
    /// Glob pattern, may contain `$`-prefixed variables like `$APPDATA`,
    /// `$HOME`, `$TEMP`, `$RESOURCE`, `$APP`, `$APPCONFIG`, `$APPLOG`.
    pattern: []const u8,
};

/// Allow/deny scope pair. Deny entries always win over allow entries.
pub const ScopeSet = struct {
    /// Allowed scopes. A path must match at least one allow entry to be
    /// permitted (unless there are no allow entries at all, in which case
    /// any path not matched by deny is allowed).
    allow: []const Scope = &.{},
    /// Denied scopes. Any match denies the path unconditionally.
    deny: []const Scope = &.{},
};

/// A single granular permission within a capability.
pub const Permission = struct {
    /// Permission identifier, e.g. `"fs:allow-read-text-file"` or
    /// `"app:allow-read-config"`.
    identifier: []const u8,
    /// Allow/deny scopes for this permission.
    scopes: ScopeSet = .{},
};

/// A named security capability that applies to one or more windows.
pub const Capability = struct {
    /// Unique identifier for this capability within the manifest.
    identifier: []const u8,
    /// Human-readable description of what this capability grants.
    description: []const u8 = "",
    /// Window labels this capability applies to. Use `"*"` to mean
    /// "all windows".
    windows: []const []const u8,
    /// Granular permissions granted by this capability.
    permissions: []const Permission = &.{},

    /// Frees the strings and arrays owned by this capability. The caller
    /// must have allocated every string and slice stored in the
    /// capability via the supplied allocator.
    pub fn deinit(self: *Capability, allocator: std.mem.Allocator) void {
        allocator.free(self.identifier);
        allocator.free(self.description);
        for (self.windows) |window| allocator.free(window);
        if (self.windows.len > 0) allocator.free(self.windows);
        for (self.permissions) |permission| {
            allocator.free(permission.identifier);
            for (permission.scopes.allow) |scope| allocator.free(scope.pattern);
            if (permission.scopes.allow.len > 0) allocator.free(permission.scopes.allow);
            for (permission.scopes.deny) |scope| allocator.free(scope.pattern);
            if (permission.scopes.deny.len > 0) allocator.free(permission.scopes.deny);
        }
        if (self.permissions.len > 0) allocator.free(self.permissions);
        self.* = undefined;
    }
};

/// Resolver for the `$`-prefixed variables supported inside scope
/// patterns. Empty fields are left unsubstituted.
pub const ScopeVars = struct {
    app: []const u8 = "",
    appconfig: []const u8 = "",
    appdata: []const u8 = "",
    applocaldata: []const u8 = "",
    applog: []const u8 = "",
    home: []const u8 = "",
    temp: []const u8 = "",
    resource: []const u8 = "",
};

/// Returns the length of the longest known variable name prefix
/// starting at `pattern[index]` with a leading `$`. Returns `0` if no
/// known variable matches at that position.
fn variableNameLen(pattern: []const u8, index: usize) usize {
    const variables = [_][]const u8{
        "APPLOCALDATA",
        "APPCONFIG",
        "APPDATA",
        "APPLOG",
        "RESOURCE",
        "TEMP",
        "HOME",
        "APP",
    };
    if (index >= pattern.len or pattern[index] != '$') return 0;
    const remaining = pattern[index + 1 ..];
    var best: usize = 0;
    for (variables) |name| {
        if (remaining.len >= name.len and std.mem.eql(u8, remaining[0..name.len], name)) {
            if (name.len > best) best = name.len;
        }
    }
    return best;
}

/// Returns the value associated with the named variable, or `null` if
/// the name is not recognized.
fn variableValue(name: []const u8, vars: ScopeVars) ?[]const u8 {
    if (std.mem.eql(u8, name, "APP")) return vars.app;
    if (std.mem.eql(u8, name, "APPCONFIG")) return vars.appconfig;
    if (std.mem.eql(u8, name, "APPDATA")) return vars.appdata;
    if (std.mem.eql(u8, name, "APPLOCALDATA")) return vars.applocaldata;
    if (std.mem.eql(u8, name, "APPLOG")) return vars.applog;
    if (std.mem.eql(u8, name, "HOME")) return vars.home;
    if (std.mem.eql(u8, name, "TEMP")) return vars.temp;
    if (std.mem.eql(u8, name, "RESOURCE")) return vars.resource;
    return null;
}

/// Resolves `$`-prefixed variables in `pattern` using `vars`. Returns
/// an allocated string the caller must free with the same allocator.
/// Variables that are unset are replaced with the empty string.
pub fn resolveScope(allocator: std.mem.Allocator, pattern: []const u8, vars: ScopeVars) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var index: usize = 0;
    while (index < pattern.len) {
        const name_len = variableNameLen(pattern, index);
        if (name_len > 0) {
            const name = pattern[index + 1 ..][0..name_len];
            if (variableValue(name, vars)) |value| try out.appendSlice(allocator, value);
            index += 1 + name_len;
            continue;
        }
        try out.append(allocator, pattern[index]);
        index += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// Tests whether `value` matches a glob `pattern`. Supports:
///   `*`  matches any chars except `/`
///   `**` matches any chars including `/`
///   `?`  matches a single char
///   everything else is a literal match.
/// Backslash escaping is not supported.
pub fn matchGlob(pattern: []const u8, value: []const u8) bool {
    var p: usize = 0;
    var v: usize = 0;
    var star_p: ?usize = null;
    var star_v: usize = 0;
    while (v < value.len) {
        if (p < pattern.len) {
            // `**` matches any sequence including `/`.
            if (p + 1 < pattern.len and pattern[p] == '*' and pattern[p + 1] == '*') {
                // Skip a trailing `/` after `**` if present.
                var np: usize = p + 2;
                if (np < pattern.len and pattern[np] == '/') np += 1;
                // If `**` is the last segment, it matches the rest of the value.
                if (np >= pattern.len) return true;
                // Otherwise, try to match the rest of the pattern starting
                // from each subsequent position of the value.
                var scan: usize = v;
                while (scan <= value.len) : (scan += 1) {
                    if (matchGlob(pattern[np..], value[scan..])) return true;
                    if (scan == value.len) break;
                }
                return false;
            }
            if (pattern[p] == '*') {
                // `*` matches any run of chars that does not contain `/`.
                p += 1;
                if (value[v] == '/') return false;
                star_p = p;
                star_v = v;
                continue;
            }
            if (pattern[p] == '?') {
                if (value[v] == '/') return false;
                p += 1;
                v += 1;
                continue;
            }
            if (pattern[p] == value[v]) {
                p += 1;
                v += 1;
                continue;
            }
        }
        // Mismatch: fall back to the most recent `*` if any.
        if (star_p) |sp| {
            p = sp;
            if (star_v + 1 < value.len and value[star_v] == '/') return false;
            star_v += 1;
            v = star_v;
            continue;
        }
        return false;
    }
    // Consume any trailing `*` characters in the pattern.
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

/// Returns `true` iff `scope.kind` matches the requested `kind`.
fn scopeMatchesPathKind(scope: Scope, kind: ScopeKind) bool {
    return scope.kind == kind;
}

/// Returns `true` iff `value` matches any scope in `scopes` that has
/// the given `kind`.
fn anyScopeMatches(scopes: []const Scope, kind: ScopeKind, value: []const u8, vars: ScopeVars) bool {
    for (scopes) |scope| {
        if (!scopeMatchesPathKind(scope, kind)) continue;
        const resolved = resolveScope(std.heap.page_allocator, scope.pattern, vars) catch continue;
        defer std.heap.page_allocator.free(resolved);
        if (matchGlob(resolved, value)) return true;
    }
    return false;
}

/// True iff `path` is allowed by `set` (deny overrides allow). A
/// `$`-prefixed pattern in any scope is resolved using `vars` before
/// matching. A `set` with no allow scopes is deny-by-default (an empty
/// set is deny), so callers must declare at least one allow scope to
/// grant any access.
pub fn allowsPath(set: ScopeSet, path: []const u8, vars: ScopeVars) bool {
    if (anyScopeMatches(set.deny, .path, path, vars)) return false;
    if (set.allow.len == 0) return false;
    return anyScopeMatches(set.allow, .path, path, vars);
}

test "capability module" {
    // `matchGlob`: exact match, `*` without `/`, `**` across `/`,
    // `?` single char, empty pattern matches empty value.
    try std.testing.expect(matchGlob("foo", "foo"));
    try std.testing.expect(!matchGlob("foo", "bar"));
    try std.testing.expect(matchGlob("*.txt", "note.txt"));
    try std.testing.expect(!matchGlob("*.txt", "sub/note.txt"));
    try std.testing.expect(!matchGlob("*.txt", "note.md"));
    try std.testing.expect(matchGlob("a/b/**", "a/b/c/d.txt"));
    try std.testing.expect(matchGlob("a/b/**", "a/b/c"));
    try std.testing.expect(!matchGlob("a/b/**", "a/c/d"));
    try std.testing.expect(matchGlob("a/?/c", "a/b/c"));
    try std.testing.expect(!matchGlob("a/?/c", "a/bb/c"));
    try std.testing.expect(!matchGlob("a/?/c", "a//c"));
    try std.testing.expect(matchGlob("", ""));
    try std.testing.expect(!matchGlob("", "x"));
    try std.testing.expect(!matchGlob("x", ""));
    // `*` after a literal segment behaves the same as standalone.
    try std.testing.expect(matchGlob("dir/*", "dir/file"));
    try std.testing.expect(!matchGlob("dir/*", "dir/sub/file"));
    // `**` matches across `/`.
    try std.testing.expect(matchGlob("dir/**", "dir/sub/file"));
    try std.testing.expect(matchGlob("dir/**", "dir/file"));

    // `resolveScope`: substitutes each known variable. Empty variables
    // expand to the empty string.
    const allocator = std.testing.allocator;
    const vars = ScopeVars{
        .app = "myapp",
        .appconfig = "/cfg",
        .appdata = "/data",
        .applocaldata = "/local",
        .applog = "/log",
        .home = "/home/user",
        .temp = "/tmp",
        .resource = "/res",
    };
    {
        const resolved = try resolveScope(allocator, "$HOME", vars);
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings("/home/user", resolved);
    }
    {
        const resolved = try resolveScope(allocator, "$HOME/file", vars);
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings("/home/user/file", resolved);
    }
    {
        const resolved = try resolveScope(allocator, "$APPDATA/x", vars);
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings("/data/x", resolved);
    }
    {
        const resolved = try resolveScope(allocator, "$APPLOCALDATA", vars);
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings("/local", resolved);
    }
    {
        const resolved = try resolveScope(allocator, "$APPCONFIG", vars);
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings("/cfg", resolved);
    }
    {
        const resolved = try resolveScope(allocator, "$APPLOG", vars);
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings("/log", resolved);
    }
    {
        const resolved = try resolveScope(allocator, "$TEMP", vars);
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings("/tmp", resolved);
    }
    {
        const resolved = try resolveScope(allocator, "$RESOURCE/x", vars);
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings("/res/x", resolved);
    }
    {
        const resolved = try resolveScope(allocator, "$APP", vars);
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings("myapp", resolved);
    }
    // `$APPDATA` is preferred over `$APP` (longest match wins).
    {
        const resolved = try resolveScope(allocator, "$APPDATA", vars);
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings("/data", resolved);
    }
    {
        const resolved = try resolveScope(allocator, "$APP-data", vars);
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings("myapp-data", resolved);
    }
    // Unknown variables are preserved verbatim.
    {
        const resolved = try resolveScope(allocator, "$UNKNOWN/x", vars);
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings("$UNKNOWN/x", resolved);
    }
    const empty_vars: ScopeVars = .{};
    {
        const resolved = try resolveScope(allocator, "$APPDATA/file", empty_vars);
        defer allocator.free(resolved);
        try std.testing.expectEqualStrings("/file", resolved);
    }

    // `allowsPath`: allow-only, deny-only, both (deny wins), empty set.
    const allow_only = ScopeSet{
        .allow = &.{ .{ .kind = .path, .pattern = "/data/**" } },
    };
    try std.testing.expect(allowsPath(allow_only, "/data/x", vars));
    try std.testing.expect(!allowsPath(allow_only, "/other/x", vars));

    const deny_only = ScopeSet{
        .deny = &.{ .{ .kind = .path, .pattern = "/data/secret/**" } },
    };
    // `deny_only` has no allow scope, so by default even a non-matching
    // path is denied. The deny match itself is also denied (deny overrides).
    try std.testing.expect(!allowsPath(deny_only, "/data/public", vars));
    try std.testing.expect(!allowsPath(deny_only, "/data/secret/x", vars));

    const both = ScopeSet{
        .allow = &.{ .{ .kind = .path, .pattern = "/data/**" } },
        .deny = &.{ .{ .kind = .path, .pattern = "/data/secret/**" } },
    };
    try std.testing.expect(allowsPath(both, "/data/x", vars));
    try std.testing.expect(!allowsPath(both, "/data/secret/x", vars));

    const empty: ScopeSet = .{};
    try std.testing.expect(!allowsPath(empty, "/data/x", vars));

    // `url` scopes must not affect path checks.
    const url_scoped = ScopeSet{
        .allow = &.{ .{ .kind = .url, .pattern = "https://example.com/*" } },
    };
    try std.testing.expect(!allowsPath(url_scoped, "/data/x", vars));

    // `Capability.deinit` frees its owned strings/arrays with the
    // testing allocator.
    const id = try allocator.dupe(u8, "main-capability");
    errdefer allocator.free(id);
    const description = try allocator.dupe(u8, "main window capability");
    errdefer allocator.free(description);
    const windows = try allocator.alloc([]const u8, 2);
    windows[0] = try allocator.dupe(u8, "main");
    windows[1] = try allocator.dupe(u8, "settings");
    errdefer {
        for (windows) |window| allocator.free(window);
        allocator.free(windows);
    }
    const allow_pattern = try allocator.dupe(u8, "$APPDATA/**");
    errdefer allocator.free(allow_pattern);
    const deny_pattern = try allocator.dupe(u8, "$APPDATA/secret/**");
    errdefer allocator.free(deny_pattern);
    const allow_scopes = try allocator.alloc(Scope, 1);
    allow_scopes[0] = .{ .kind = .path, .pattern = allow_pattern };
    errdefer allocator.free(allow_scopes);
    const deny_scopes = try allocator.alloc(Scope, 1);
    deny_scopes[0] = .{ .kind = .path, .pattern = deny_pattern };
    errdefer allocator.free(deny_scopes);
    const perm_id = try allocator.dupe(u8, "fs:allow-read-text-file");
    errdefer allocator.free(perm_id);
    const permissions = try allocator.alloc(Permission, 1);
    errdefer allocator.free(permissions);
    permissions[0] = .{
        .identifier = perm_id,
        .scopes = .{ .allow = allow_scopes, .deny = deny_scopes },
    };
    var capability: Capability = .{
        .identifier = id,
        .description = description,
        .windows = windows,
        .permissions = permissions,
    };
    capability.deinit(allocator);
}