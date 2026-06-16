const std = @import("std");
const app_manifest = @import("app_manifest");
const diagnostics = @import("diagnostics");
const raw_manifest = @import("raw_manifest.zig");
const security_pkg = @import("security");
const capability = security_pkg.capability;
const web_engine_tool = @import("web_engine.zig");

pub const ValidationResult = struct {
    ok: bool,
    message: []const u8,
};

pub const Metadata = struct {
    id: []const u8,
    name: []const u8,
    display_name: ?[]const u8 = null,
    version: []const u8,
    icons: []const []const u8 = &.{},
    platforms: []const []const u8 = &.{},
    permissions: []const []const u8 = &.{},
    /// Package-level feature flags such as `"webview"` and `"js_bridge"`.
    /// These feed the `app_manifest.Capability` union validation and are
    /// distinct from the structured `capabilities` field, which carries
    /// per-window security policies consumed at runtime.
    feature_capabilities: []const []const u8 = &.{},
    /// Structured per-window security capabilities. Each entry carries a
    /// unique identifier, the windows it applies to, and the granular
    /// permissions with allow/deny scope globs.
    capabilities: []const capability.Capability = &.{},
    bridge_commands: []const BridgeCommandMetadata = &.{},
    web_engine: []const u8 = "system",
    cef: web_engine_tool.CefConfig = .{},
    frontend: ?FrontendMetadata = null,
    security: SecurityMetadata = .{},
    windows: []const WindowMetadata = &.{},

    pub fn displayName(self: Metadata) []const u8 {
        return self.display_name orelse self.name;
    }

    pub fn deinit(self: Metadata, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        if (self.display_name) |value| allocator.free(value);
        allocator.free(self.version);
        allocator.free(self.web_engine);
        allocator.free(self.cef.dir);
        for (self.icons) |value| allocator.free(value);
        if (self.icons.len > 0) allocator.free(self.icons);
        for (self.platforms) |value| allocator.free(value);
        if (self.platforms.len > 0) allocator.free(self.platforms);
        for (self.permissions) |value| allocator.free(value);
        if (self.permissions.len > 0) allocator.free(self.permissions);
        for (self.feature_capabilities) |value| allocator.free(value);
        if (self.feature_capabilities.len > 0) allocator.free(self.feature_capabilities);
        for (self.capabilities) |cap| deinitCapability(allocator, cap);
        if (self.capabilities.len > 0) allocator.free(self.capabilities);
        for (self.bridge_commands) |command| {
            allocator.free(command.name);
            for (command.permissions) |value| allocator.free(value);
            if (command.permissions.len > 0) allocator.free(command.permissions);
            for (command.origins) |value| allocator.free(value);
            if (command.origins.len > 0) allocator.free(command.origins);
        }
        if (self.bridge_commands.len > 0) allocator.free(self.bridge_commands);
        if (self.frontend) |frontend| {
            allocator.free(frontend.dist);
            allocator.free(frontend.entry);
            if (frontend.dev) |dev| {
                allocator.free(dev.url);
                for (dev.command) |value| allocator.free(value);
                if (dev.command.len > 0) allocator.free(dev.command);
                allocator.free(dev.ready_path);
            }
        }
        for (self.security.navigation.allowed_origins) |value| allocator.free(value);
        if (self.security.navigation.allowed_origins.len > 0) allocator.free(self.security.navigation.allowed_origins);
        // `action` is heap-owned after a successful `parseText`, so it is
        // freed here. The `&.{}` constant in the errdefer path is not
        // freed (it is a read-only sentinel with `.len == 0`).
        if (self.security.navigation.external_links.action.len > 0)
            allocator.free(self.security.navigation.external_links.action);
        for (self.security.navigation.external_links.allowed_urls) |value| allocator.free(value);
        if (self.security.navigation.external_links.allowed_urls.len > 0) allocator.free(self.security.navigation.external_links.allowed_urls);
        for (self.windows) |window| {
            allocator.free(window.label);
            if (window.title) |title| allocator.free(title);
        }
        if (self.windows.len > 0) allocator.free(self.windows);
    }
};

pub const BridgeCommandMetadata = struct {
    name: []const u8,
    permissions: []const []const u8 = &.{},
    origins: []const []const u8 = &.{},
};

pub const WindowMetadata = struct {
    label: []const u8 = "main",
    title: ?[]const u8 = null,
    width: f32 = 720,
    height: f32 = 480,
    x: ?f32 = null,
    y: ?f32 = null,
    restore_state: bool = true,
};

pub const FrontendDevMetadata = struct {
    url: []const u8,
    command: []const []const u8 = &.{},
    ready_path: []const u8 = "/",
    timeout_ms: u32 = 30_000,
};

pub const FrontendMetadata = struct {
    dist: []const u8 = "dist",
    entry: []const u8 = "index.html",
    spa_fallback: bool = true,
    dev: ?FrontendDevMetadata = null,
};

pub const ExternalLinkMetadata = struct {
    action: []const u8 = "deny",
    allowed_urls: []const []const u8 = &.{},
};

pub const NavigationMetadata = struct {
    allowed_origins: []const []const u8 = &.{},
    external_links: ExternalLinkMetadata = .{},
};

pub const SecurityMetadata = struct {
    navigation: NavigationMetadata = .{},
};

const RawManifest = raw_manifest.RawManifest;
const RawBridge = raw_manifest.RawBridge;
const RawBridgeCommand = raw_manifest.RawBridgeCommand;
const RawFrontend = raw_manifest.RawFrontend;
const RawFrontendDev = raw_manifest.RawFrontendDev;
const RawSecurity = raw_manifest.RawSecurity;
const RawNavigation = raw_manifest.RawNavigation;
const RawExternalLinks = raw_manifest.RawExternalLinks;
const RawWindow = raw_manifest.RawWindow;
const RawSecurityCapability = raw_manifest.RawSecurityCapability;
const RawSecurityPermission = raw_manifest.RawSecurityPermission;
const RawSecurityScopeSet = raw_manifest.RawSecurityScopeSet;
const RawSecurityScope = raw_manifest.RawSecurityScope;

pub fn validateFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !ValidationResult {
    const source = try readFile(allocator, io, path);
    defer allocator.free(source);

    const metadata = parseText(allocator, source) catch return .{ .ok = false, .message = "app.zon metadata could not be parsed" };
    defer metadata.deinit(allocator);

    validateIconPaths(metadata.icons) catch return .{ .ok = false, .message = "app.zon icons are invalid" };
    const permissions = parsePermissions(allocator, metadata.permissions) catch return .{ .ok = false, .message = "app.zon permissions are invalid" };
    defer allocator.free(permissions);
    const feature_capabilities = parseCapabilities(allocator, metadata.feature_capabilities) catch return .{ .ok = false, .message = "app.zon feature_capabilities are invalid" };
    defer {
        if (feature_capabilities.len > 0) allocator.free(feature_capabilities);
    }
    const bridge_commands = parseBridgeCommands(allocator, metadata.bridge_commands) catch return .{ .ok = false, .message = "app.zon bridge commands are invalid" };
    defer {
        for (bridge_commands) |command| allocator.free(command.permissions);
        allocator.free(bridge_commands);
    }
    const frontend = if (metadata.frontend) |frontend_value| convertFrontend(frontend_value) else null;
    const parsed_security = convertSecurity(metadata.security) catch return .{ .ok = false, .message = "app.zon security policy is invalid" };
    const windows = try convertWindows(allocator, metadata.windows);
    defer allocator.free(windows);
    const manifest_web_engine = parseWebEngine(metadata.web_engine) catch return .{ .ok = false, .message = "app.zon web engine is invalid" };

    const manifest: app_manifest.Manifest = .{
        .identity = .{ .id = metadata.id, .name = metadata.name, .display_name = metadata.display_name },
        .version = parseVersion(metadata.version) catch return .{ .ok = false, .message = "app.zon version is invalid" },
        .permissions = permissions,
        .capabilities = feature_capabilities,
        .bridge = .{ .commands = bridge_commands },
        .frontend = frontend,
        .security = parsed_security,
        .platforms = parsePlatformSettings(allocator, metadata.platforms) catch return .{ .ok = false, .message = "app.zon platforms are invalid" },
        .windows = windows,
        .cef = .{ .dir = metadata.cef.dir, .auto_install = metadata.cef.auto_install },
        .package = .{ .web_engine = manifest_web_engine },
    };
    app_manifest.validateManifest(manifest) catch return .{ .ok = false, .message = "manifest fields failed semantic validation" };
    return .{ .ok = true, .message = "app.zon is valid" };
}

pub fn readMetadata(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Metadata {
    const source = try readFile(allocator, io, path);
    defer allocator.free(source);
    return parseText(allocator, source);
}

pub fn parseText(allocator: std.mem.Allocator, source: []const u8) !Metadata {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const source_z = try scratch.dupeSentinel(u8, source, 0);
    const raw = try std.zon.parse.fromSliceAlloc(RawManifest, scratch, source_z, null, .{});
    // Build the metadata in two passes and track the heap-allocated
    // `action` separately: the only field that `Metadata.deinit` frees
    // unconditionally. The pre-populated value uses `&.{}` (a read-only
    // constant) so a premature `deinit` does not free garbage; the real
    // `action` allocation is held in a local that the errdefer cleans up
    // until it is committed by `convertRawSecurity`.
    var metadata: Metadata = .{
        .id = try allocator.dupe(u8, raw.id),
        .name = try allocator.dupe(u8, raw.name),
        .display_name = if (raw.display_name) |value| try allocator.dupe(u8, value) else null,
        .version = try allocator.dupe(u8, raw.version),
        .icons = &.{},
        .platforms = &.{},
        .permissions = &.{},
        .feature_capabilities = &.{},
        .capabilities = &.{},
        .bridge_commands = &.{},
        .web_engine = try allocator.dupe(u8, raw.web_engine),
        .cef = .{
            .dir = try allocator.dupe(u8, raw.cef.dir),
            .auto_install = raw.cef.auto_install,
        },
        .frontend = null,
        .security = .{
            .navigation = .{
                .allowed_origins = &.{},
                .external_links = .{
                    // Sentinel: `deinit` checks `action_was_allocated` and
                    // skips freeing this empty constant.
                    .action = &.{},
                    .allowed_urls = &.{},
                },
            },
        },
        .windows = &.{},
    };
    errdefer metadata.deinit(allocator);
    metadata.icons = try duplicateStringList(allocator, raw.icons);
    metadata.platforms = try duplicateStringList(allocator, raw.platforms);
    metadata.permissions = try duplicateStringList(allocator, raw.permissions);
    metadata.feature_capabilities = try duplicateStringList(allocator, raw.feature_capabilities);
    metadata.capabilities = try convertRawSecurityCapabilities(allocator, raw.capabilities);
    metadata.bridge_commands = try convertRawBridgeCommands(allocator, raw.bridge.commands);
    metadata.frontend = try convertRawFrontend(allocator, raw.frontend);
    const action = try allocator.dupe(u8, raw.security.navigation.external_links.action);
    errdefer allocator.free(action);
    metadata.security = .{
        .navigation = .{
            .allowed_origins = try duplicateStringList(allocator, raw.security.navigation.allowed_origins),
            .external_links = .{
                .action = action,
                .allowed_urls = try duplicateStringList(allocator, raw.security.navigation.external_links.allowed_urls),
            },
        },
    };
    metadata.windows = try convertRawWindows(allocator, raw.windows);
    return metadata;
}

fn duplicateStringList(allocator: std.mem.Allocator, values: []const []const u8) ![]const []const u8 {
    if (values.len == 0) return &.{};
    const out = try allocator.alloc([]const u8, values.len);
    for (values, 0..) |value, index| {
        out[index] = try allocator.dupe(u8, value);
    }
    return out;
}

fn convertRawBridgeCommands(allocator: std.mem.Allocator, commands: []const RawBridgeCommand) ![]const BridgeCommandMetadata {
    if (commands.len == 0) return &.{};
    const converted = try allocator.alloc(BridgeCommandMetadata, commands.len);
    for (commands, 0..) |command, index| {
        converted[index] = .{
            .name = try allocator.dupe(u8, command.name),
            .permissions = try duplicateStringList(allocator, command.permissions),
            .origins = try duplicateStringList(allocator, command.origins),
        };
    }
    return converted;
}

/// Converts a list of raw structured capabilities into the runtime
/// `capability.Capability` representation. Every string and slice is
/// duplicated into `allocator`; the caller must release them via
/// `Capability.deinit` plus a final `allocator.free` of the top-level
/// slice.
fn convertRawSecurityCapabilities(
    allocator: std.mem.Allocator,
    raw: []const RawSecurityCapability,
) ![]const capability.Capability {
    if (raw.len == 0) return &.{};
    const converted = try allocator.alloc(capability.Capability, raw.len);
    var populated: usize = 0;
    errdefer {
        for (converted[0..populated]) |cap| deinitCapability(allocator, cap);
        allocator.free(converted);
    }
    for (raw, 0..) |source, index| {
        // Build the struct field-by-field so an errdefer inside the loop
        // can free the partial fields if a later one fails. The whole
        // `converted[index]` is only assigned once every field has been
        // allocated.
        var cap: capability.Capability = .{
            .identifier = try allocator.dupe(u8, source.identifier),
            .description = try allocator.dupe(u8, source.description),
            .windows = &.{},
            .permissions = &.{},
        };
        errdefer deinitCapability(allocator, cap);
        cap.windows = try duplicateStringList(allocator, source.windows);
        cap.permissions = try convertRawSecurityPermissions(allocator, source.permissions);
        converted[index] = cap;
        populated = index + 1;
    }
    return converted;
}

fn convertRawSecurityPermissions(
    allocator: std.mem.Allocator,
    raw: []const RawSecurityPermission,
) ![]const capability.Permission {
    if (raw.len == 0) return &.{};
    const converted = try allocator.alloc(capability.Permission, raw.len);
    var populated: usize = 0;
    errdefer {
        for (converted[0..populated]) |perm| {
            allocator.free(perm.identifier);
            for (perm.scopes.allow) |scope| allocator.free(scope.pattern);
            if (perm.scopes.allow.len > 0) allocator.free(perm.scopes.allow);
            for (perm.scopes.deny) |scope| allocator.free(scope.pattern);
            if (perm.scopes.deny.len > 0) allocator.free(perm.scopes.deny);
        }
        allocator.free(converted);
    }
    for (raw, 0..) |source, index| {
        // Build the permission field-by-field so an errdefer can free the
        // partial fields (identifier) if the scope conversion fails.
        var perm: capability.Permission = .{
            .identifier = try allocator.dupe(u8, source.identifier),
            .scopes = .{},
        };
        errdefer allocator.free(perm.identifier);
        perm.scopes = try convertRawSecurityScopeSet(allocator, source.scopes);
        converted[index] = perm;
        populated = index + 1;
    }
    return converted;
}

fn convertRawSecurityScopeSet(
    allocator: std.mem.Allocator,
    raw: RawSecurityScopeSet,
) !capability.ScopeSet {
    const allow = try convertRawSecurityScopes(allocator, raw.allow);
    errdefer {
        for (allow) |scope| allocator.free(scope.pattern);
        if (allow.len > 0) allocator.free(allow);
    }
    const deny = try convertRawSecurityScopes(allocator, raw.deny);
    return .{ .allow = allow, .deny = deny };
}

fn convertRawSecurityScopes(
    allocator: std.mem.Allocator,
    raw: []const RawSecurityScope,
) ![]const capability.Scope {
    if (raw.len == 0) return &.{};
    const converted = try allocator.alloc(capability.Scope, raw.len);
    var populated: usize = 0;
    errdefer {
        for (converted[0..populated]) |scope| allocator.free(scope.pattern);
        allocator.free(converted);
    }
    for (raw, 0..) |source, index| {
        converted[index] = .{
            .kind = parseScopeKind(source.kind) orelse return error.InvalidScopeKind,
            .pattern = try allocator.dupe(u8, source.pattern),
        };
        populated = index + 1;
    }
    return converted;
}

fn parseScopeKind(value: []const u8) ?capability.ScopeKind {
    if (std.mem.eql(u8, value, "path")) return .path;
    if (std.mem.eql(u8, value, "url")) return .url;
    return null;
}

fn convertRawFrontend(allocator: std.mem.Allocator, frontend: ?RawFrontend) !?FrontendMetadata {
    const value = frontend orelse return null;
    return .{
        .dist = try allocator.dupe(u8, value.dist),
        .entry = try allocator.dupe(u8, value.entry),
        .spa_fallback = value.spa_fallback,
        .dev = if (value.dev) |dev| .{
            .url = try allocator.dupe(u8, dev.url),
            .command = try duplicateStringList(allocator, dev.command),
            .ready_path = try allocator.dupe(u8, dev.ready_path),
            .timeout_ms = dev.timeout_ms,
        } else null,
    };
}

fn convertRawSecurity(allocator: std.mem.Allocator, raw: RawSecurity) !SecurityMetadata {
    // `action` is always heap-owned so that `Metadata.deinit` can unconditionally free it.
    return .{
        .navigation = .{
            .allowed_origins = try duplicateStringList(allocator, raw.navigation.allowed_origins),
            .external_links = .{
                .action = try allocator.dupe(u8, raw.navigation.external_links.action),
                .allowed_urls = try duplicateStringList(allocator, raw.navigation.external_links.allowed_urls),
            },
        },
    };
}

fn convertRawWindows(allocator: std.mem.Allocator, windows: []const RawWindow) ![]const WindowMetadata {
    if (windows.len == 0) return &.{};
    const converted = try allocator.alloc(WindowMetadata, windows.len);
    for (windows, 0..) |window, index| {
        converted[index] = .{
            .label = try allocator.dupe(u8, window.label),
            .title = if (window.title) |title| try allocator.dupe(u8, title) else null,
            .width = window.width,
            .height = window.height,
            .x = window.x,
            .y = window.y,
            .restore_state = window.restore_state,
        };
    }
    return converted;
}

/// Frees a capability plus all of its owned strings/arrays. The capability
/// value is consumed by value so callers iterating over a `const` slice
/// (typical for `Metadata.capabilities`) do not need a mutable pointer.
fn deinitCapability(allocator: std.mem.Allocator, cap: capability.Capability) void {
    allocator.free(cap.identifier);
    allocator.free(cap.description);
    for (cap.windows) |window| allocator.free(window);
    if (cap.windows.len > 0) allocator.free(cap.windows);
    for (cap.permissions) |perm| {
        allocator.free(perm.identifier);
        for (perm.scopes.allow) |scope| allocator.free(scope.pattern);
        if (perm.scopes.allow.len > 0) allocator.free(perm.scopes.allow);
        for (perm.scopes.deny) |scope| allocator.free(scope.pattern);
        if (perm.scopes.deny.len > 0) allocator.free(perm.scopes.deny);
    }
    if (cap.permissions.len > 0) allocator.free(cap.permissions);
}

pub fn parseVersion(value: []const u8) !app_manifest.Version {
    var parts = std.mem.splitScalar(u8, value, '.');
    const major = try parseVersionNumber(parts.next() orelse return error.InvalidVersion);
    const minor = try parseVersionNumber(parts.next() orelse return error.InvalidVersion);
    const patch_text = parts.next() orelse return error.InvalidVersion;
    if (parts.next() != null) return error.InvalidVersion;
    return .{
        .major = major,
        .minor = minor,
        .patch = try parseVersionNumber(patch_text),
    };
}

pub fn printDiagnostic(result: ValidationResult) void {
    const severity: diagnostics.Severity = if (result.ok) .info else .@"error";
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    diagnostics.formatShort(.{ .severity = severity, .code = diagnostics.code("manifest", if (result.ok) "valid" else "invalid"), .message = result.message }, &writer) catch return;
    std.debug.print("{s}\n", .{writer.buffered()});
}

fn readFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
}

fn convertFrontend(frontend: FrontendMetadata) app_manifest.FrontendConfig {
    return .{
        .dist = frontend.dist,
        .entry = frontend.entry,
        .spa_fallback = frontend.spa_fallback,
        .dev = if (frontend.dev) |dev| .{
            .url = dev.url,
            .command = dev.command,
            .ready_path = dev.ready_path,
            .timeout_ms = dev.timeout_ms,
        } else null,
    };
}

fn convertSecurity(metadata_security: SecurityMetadata) !app_manifest.SecurityConfig {
    return .{
        .navigation = .{
            .allowed_origins = if (metadata_security.navigation.allowed_origins.len > 0) metadata_security.navigation.allowed_origins else &.{ "zero://app", "zero://inline" },
            .external_links = .{
                .action = parseExternalLinkAction(metadata_security.navigation.external_links.action) catch return error.InvalidSecurity,
                .allowed_urls = metadata_security.navigation.external_links.allowed_urls,
            },
        },
    };
}

fn convertWindows(allocator: std.mem.Allocator, windows: []const WindowMetadata) ![]const app_manifest.Window {
    if (windows.len == 0) return &.{};
    const converted = try allocator.alloc(app_manifest.Window, windows.len);
    for (windows, 0..) |window, index| {
        converted[index] = .{
            .label = window.label,
            .title = window.title,
            .width = window.width,
            .height = window.height,
            .x = window.x,
            .y = window.y,
            .restore_state = window.restore_state,
        };
    }
    return converted;
}

fn validateIconPaths(icons: []const []const u8) !void {
    for (icons, 0..) |icon, index| {
        try validateRelativePath(icon);
        for (icons[0..index]) |previous| {
            if (std.mem.eql(u8, previous, icon)) return error.DuplicateIcon;
        }
    }
}

fn parseCapabilities(allocator: std.mem.Allocator, values: []const []const u8) ![]const app_manifest.Capability {
    var capabilities: std.ArrayList(app_manifest.Capability) = .empty;
    errdefer capabilities.deinit(allocator);
    for (values) |value| {
        try capabilities.append(allocator, parseCapability(value) catch return error.InvalidCapability);
    }
    return capabilities.toOwnedSlice(allocator);
}

fn parsePermissions(allocator: std.mem.Allocator, values: []const []const u8) ![]const app_manifest.Permission {
    var permissions: std.ArrayList(app_manifest.Permission) = .empty;
    errdefer permissions.deinit(allocator);
    for (values) |value| {
        try permissions.append(allocator, parsePermission(value));
    }
    return permissions.toOwnedSlice(allocator);
}

fn parsePermission(value: []const u8) app_manifest.Permission {
    if (std.mem.eql(u8, value, "network")) return .network;
    if (std.mem.eql(u8, value, "filesystem")) return .filesystem;
    if (std.mem.eql(u8, value, "camera")) return .camera;
    if (std.mem.eql(u8, value, "microphone")) return .microphone;
    if (std.mem.eql(u8, value, "location")) return .location;
    if (std.mem.eql(u8, value, "notifications")) return .notifications;
    if (std.mem.eql(u8, value, "clipboard")) return .clipboard;
    if (std.mem.eql(u8, value, "window")) return .window;
    return .{ .custom = value };
}

fn parseCapability(value: []const u8) !app_manifest.Capability {
    if (std.mem.eql(u8, value, "native_module")) return .native_module;
    if (std.mem.eql(u8, value, "webview")) return .webview;
    if (std.mem.eql(u8, value, "js_bridge")) return .js_bridge;
    if (std.mem.eql(u8, value, "filesystem")) return .filesystem;
    if (std.mem.eql(u8, value, "network")) return .network;
    if (std.mem.eql(u8, value, "clipboard")) return .clipboard;
    return error.InvalidCapability;
}

fn parseBridgeCommands(allocator: std.mem.Allocator, values: []const BridgeCommandMetadata) ![]const app_manifest.BridgeCommand {
    var commands: std.ArrayList(app_manifest.BridgeCommand) = .empty;
    errdefer commands.deinit(allocator);
    for (values) |value| {
        try commands.append(allocator, .{
            .name = value.name,
            .permissions = try parsePermissions(allocator, value.permissions),
            .origins = value.origins,
        });
    }
    return commands.toOwnedSlice(allocator);
}

fn parsePlatformSettings(allocator: std.mem.Allocator, values: []const []const u8) ![]const app_manifest.PlatformSettings {
    if (values.len == 0) return &.{};
    var platforms: std.ArrayList(app_manifest.PlatformSettings) = .empty;
    errdefer platforms.deinit(allocator);
    for (values) |value| {
        try platforms.append(allocator, .{ .platform = parsePlatform(value) });
    }
    return platforms.toOwnedSlice(allocator);
}

fn parsePlatform(value: []const u8) app_manifest.Platform {
    if (std.mem.eql(u8, value, "macos")) return .macos;
    if (std.mem.eql(u8, value, "windows")) return .windows;
    if (std.mem.eql(u8, value, "linux")) return .linux;
    if (std.mem.eql(u8, value, "ios")) return .ios;
    if (std.mem.eql(u8, value, "android")) return .android;
    if (std.mem.eql(u8, value, "web")) return .web;
    return .unknown;
}

fn parseExternalLinkAction(value: []const u8) !app_manifest.ExternalLinkAction {
    if (std.mem.eql(u8, value, "deny")) return .deny;
    if (std.mem.eql(u8, value, "open_system_browser")) return .open_system_browser;
    return error.InvalidAction;
}

fn parseWebEngine(value: []const u8) !app_manifest.WebEngine {
    if (std.mem.eql(u8, value, "system")) return .system;
    if (std.mem.eql(u8, value, "chromium")) return .chromium;
    return error.InvalidWebEngine;
}

fn validateRelativePath(path: []const u8) !void {
    if (path.len == 0) return error.InvalidPath;
    if (path[0] == '/' or path[0] == '\\') return error.InvalidPath;
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '/' or path[2] == '\\')) return error.InvalidPath;
    var segment_start: usize = 0;
    for (path, 0..) |ch, index| {
        if (ch == 0 or ch == '\\') return error.InvalidPath;
        if (ch == '/') {
            try validatePathSegment(path[segment_start..index]);
            segment_start = index + 1;
        }
    }
    try validatePathSegment(path[segment_start..]);
}

fn validatePathSegment(segment: []const u8) !void {
    if (segment.len == 0) return error.InvalidPath;
    if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidPath;
}

fn parseVersionNumber(value: []const u8) !u32 {
    if (value.len == 0) return error.InvalidVersion;
    return std.fmt.parseUnsigned(u32, value, 10);
}

test "manifest metadata parser reads identity version and lists" {
    const metadata = try parseText(std.testing.allocator,
        \\.{
        \\  .id = "com.example.app",
        \\  .name = "example",
        \\  .display_name = "Example App",
        \\  .version = "1.2.3",
        \\  .icons = .{ "assets/icon.png" },
        \\  .platforms = .{ "macos", "linux" },
        \\  .feature_capabilities = .{ "native_module", "webview", "js_bridge" },
        \\  .bridge = .{ .commands = .{ .{ .name = "native.ping" } } },
        \\  .web_engine = "chromium",
        \\  .cef = .{ .dir = "third_party/cef/macos", .auto_install = true },
        \\}
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("com.example.app", metadata.id);
    try std.testing.expectEqualStrings("example", metadata.name);
    try std.testing.expectEqualStrings("Example App", metadata.displayName());
    try std.testing.expectEqualStrings("1.2.3", metadata.version);
    try std.testing.expectEqualStrings("assets/icon.png", metadata.icons[0]);
    try std.testing.expectEqualStrings("linux", metadata.platforms[1]);
    try std.testing.expectEqualStrings("webview", metadata.feature_capabilities[1]);
    try std.testing.expectEqualStrings("native.ping", metadata.bridge_commands[0].name);
    try std.testing.expectEqualStrings("chromium", metadata.web_engine);
    try std.testing.expectEqualStrings("third_party/cef/macos", metadata.cef.dir);
    try std.testing.expect(metadata.cef.auto_install);
    try std.testing.expectEqual(@as(u32, 2), (try parseVersion(metadata.version)).minor);
}

test "manifest metadata parser reads structured security policy" {
    const metadata = try parseText(std.testing.allocator,
        \\.{
        \\  .id = "com.example.app",
        \\  .name = "example",
        \\  .version = "1.2.3",
        \\  .permissions = .{ "window", "filesystem" },
        \\  .bridge = .{
        \\    .commands = .{
        \\      .{ .name = "native.ping", .permissions = .{ "filesystem" }, .origins = .{ "zero://app" } },
        \\    },
        \\  },
        \\  .security = .{
        \\    .navigation = .{
        \\      .allowed_origins = .{ "zero://app", "http://127.0.0.1:5173" },
        \\      .external_links = .{
        \\        .action = "open_system_browser",
        \\        .allowed_urls = .{ "https://example.com/*" },
        \\      },
        \\    },
        \\  },
        \\}
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("window", metadata.permissions[0]);
    try std.testing.expectEqualStrings("native.ping", metadata.bridge_commands[0].name);
    try std.testing.expectEqualStrings("filesystem", metadata.bridge_commands[0].permissions[0]);
    try std.testing.expectEqualStrings("zero://app", metadata.bridge_commands[0].origins[0]);
    try std.testing.expectEqualStrings("http://127.0.0.1:5173", metadata.security.navigation.allowed_origins[1]);
    try std.testing.expectEqualStrings("open_system_browser", metadata.security.navigation.external_links.action);
    try std.testing.expectEqualStrings("https://example.com/*", metadata.security.navigation.external_links.allowed_urls[0]);
}

test "manifest metadata parser reads frontend config" {
    const metadata = try parseText(std.testing.allocator,
        \\.{
        \\  .id = "com.example.app",
        \\  .name = "example",
        \\  .version = "1.2.3",
        \\  .frontend = .{
        \\    .dist = "frontend/dist",
        \\    .entry = "index.html",
        \\    .spa_fallback = false,
        \\    .dev = .{
        \\      .url = "http://127.0.0.1:5173/",
        \\      .command = .{ "npm", "run", "dev" },
        \\      .ready_path = "/health",
        \\      .timeout_ms = 12000,
        \\    },
        \\  },
        \\}
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("frontend/dist", metadata.frontend.?.dist);
    try std.testing.expectEqual(false, metadata.frontend.?.spa_fallback);
    try std.testing.expectEqualStrings("http://127.0.0.1:5173/", metadata.frontend.?.dev.?.url);
    try std.testing.expectEqualStrings("npm", metadata.frontend.?.dev.?.command[0]);
    try std.testing.expectEqual(@as(u32, 12000), metadata.frontend.?.dev.?.timeout_ms);
}

test "Metadata.deinit frees all owned fields" {
    const allocator = std.testing.allocator;

    const id = try allocator.dupe(u8, "com.example.app");
    const name = try allocator.dupe(u8, "example");
    const display_name = try allocator.dupe(u8, "Example App");
    const version = try allocator.dupe(u8, "1.2.3");
    const web_engine = try allocator.dupe(u8, "chromium");
    const cef_dir = try allocator.dupe(u8, "third_party/cef/macos");

    const icons = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(icons);
    icons[0] = try allocator.dupe(u8, "assets/icon.png");

    const platforms = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(platforms);
    platforms[0] = try allocator.dupe(u8, "macos");

    const permissions = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(permissions);
    permissions[0] = try allocator.dupe(u8, "window");

    const feature_capabilities = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(feature_capabilities);
    feature_capabilities[0] = try allocator.dupe(u8, "webview");

    // Build a single structured capability so `Capability.deinit` runs.
    const cap_id = try allocator.dupe(u8, "main-cap");
    errdefer allocator.free(cap_id);
    const cap_description = try allocator.dupe(u8, "main window capability");
    errdefer allocator.free(cap_description);
    const cap_windows_storage = try allocator.alloc([]const u8, 1);
    cap_windows_storage[0] = try allocator.dupe(u8, "main");
    errdefer {
        for (cap_windows_storage) |value| allocator.free(value);
        allocator.free(cap_windows_storage);
    }
    const perm_id = try allocator.dupe(u8, "fs:allow-read-text-file");
    errdefer allocator.free(perm_id);
    const allow_pattern = try allocator.dupe(u8, "$APPDATA/**");
    errdefer allocator.free(allow_pattern);
    const deny_pattern = try allocator.dupe(u8, "$APPDATA/secret/**");
    errdefer allocator.free(deny_pattern);
    const allow_scopes = try allocator.alloc(capability.Scope, 1);
    allow_scopes[0] = .{ .kind = .path, .pattern = allow_pattern };
    errdefer allocator.free(allow_scopes);
    const deny_scopes = try allocator.alloc(capability.Scope, 1);
    deny_scopes[0] = .{ .kind = .path, .pattern = deny_pattern };
    errdefer allocator.free(deny_scopes);
    const cap_permissions = try allocator.alloc(capability.Permission, 1);
    cap_permissions[0] = .{
        .identifier = perm_id,
        .scopes = .{ .allow = allow_scopes, .deny = deny_scopes },
    };
    errdefer allocator.free(cap_permissions);
    const capabilities = try allocator.alloc(capability.Capability, 1);
    errdefer allocator.free(capabilities);
    capabilities[0] = .{
        .identifier = cap_id,
        .description = cap_description,
        .windows = cap_windows_storage,
        .permissions = cap_permissions,
    };

    const bridge_commands = try allocator.alloc(BridgeCommandMetadata, 1);
    errdefer allocator.free(bridge_commands);
    const command_permissions = try allocator.alloc([]const u8, 1);
    command_permissions[0] = try allocator.dupe(u8, "filesystem");
    const command_origins = try allocator.alloc([]const u8, 1);
    command_origins[0] = try allocator.dupe(u8, "zero://app");
    bridge_commands[0] = .{
        .name = try allocator.dupe(u8, "native.ping"),
        .permissions = command_permissions,
        .origins = command_origins,
    };

    const dev_command = try allocator.alloc([]const u8, 2);
    dev_command[0] = try allocator.dupe(u8, "npm");
    dev_command[1] = try allocator.dupe(u8, "run");
    const frontend: ?FrontendMetadata = .{
        .dist = try allocator.dupe(u8, "frontend/dist"),
        .entry = try allocator.dupe(u8, "index.html"),
        .spa_fallback = true,
        .dev = .{
            .url = try allocator.dupe(u8, "http://127.0.0.1:5173/"),
            .command = dev_command,
            .ready_path = try allocator.dupe(u8, "/health"),
            .timeout_ms = 30_000,
        },
    };

    const allowed_origins = try allocator.alloc([]const u8, 2);
    allowed_origins[0] = try allocator.dupe(u8, "zero://app");
    allowed_origins[1] = try allocator.dupe(u8, "https://example.com");
    const allowed_urls = try allocator.alloc([]const u8, 1);
    allowed_urls[0] = try allocator.dupe(u8, "https://example.com/*");
    const parsed_security = SecurityMetadata{
        .navigation = .{
            .allowed_origins = allowed_origins,
            .external_links = .{
                .action = try allocator.dupe(u8, "open_system_browser"),
                .allowed_urls = allowed_urls,
            },
        },
    };

    const windows = try allocator.alloc(WindowMetadata, 1);
    errdefer allocator.free(windows);
    windows[0] = .{
        .label = try allocator.dupe(u8, "main"),
        .title = try allocator.dupe(u8, "Example"),
        .width = 720,
        .height = 480,
        .x = 0,
        .y = 0,
        .restore_state = true,
    };

    const metadata = Metadata{
        .id = id,
        .name = name,
        .display_name = display_name,
        .version = version,
        .icons = icons,
        .platforms = platforms,
        .permissions = permissions,
        .feature_capabilities = feature_capabilities,
        .capabilities = capabilities,
        .bridge_commands = bridge_commands,
        .web_engine = web_engine,
        .cef = .{ .dir = cef_dir, .auto_install = true },
        .frontend = frontend,
        .security = parsed_security,
        .windows = windows,
    };

    metadata.deinit(allocator);
}

test "Metadata.deinit frees default deny action" {
    const metadata = try parseText(std.testing.allocator,
        \\.{
        \\  .id = "com.example.app",
        \\  .name = "example",
        \\  .version = "1.2.3",
        \\}
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("deny", metadata.security.navigation.external_links.action);
}

test "manifest metadata parser reads structured capabilities" {
    const metadata = try parseText(std.testing.allocator,
        \\.{
        \\  .id = "com.example.app",
        \\  .name = "example",
        \\  .version = "1.2.3",
        \\  .capabilities = .{
        \\    .{
        \\      .identifier = "main-fs",
        \\      .description = "main window filesystem access",
        \\      .windows = .{ "main" },
        \\      .permissions = .{
        \\        .{
        \\          .identifier = "fs:allow-read-text-file",
        \\          .scopes = .{
        \\            .allow = .{
        \\              .{ .kind = "path", .pattern = "$APPDATA/**" },
        \\            },
        \\            .deny = .{
        \\              .{ .kind = "path", .pattern = "$APPDATA/secret/**" },
        \\            },
        \\          },
        \\        },
        \\        .{
        \\          .identifier = "network:allow-fetch",
        \\          .scopes = .{
        \\            .allow = .{
        \\              .{ .kind = "url", .pattern = "https://api.example.com/**" },
        \\            },
        \\            .deny = .{
        \\              .{ .kind = "url", .pattern = "https://api.example.com/internal/**" },
        \\            },
        \\          },
        \\        },
        \\      },
        \\    },
        \\    .{
        \\      .identifier = "anywhere-fs",
        \\      .windows = .{ "*" },
        \\      .permissions = .{
        \\        .{ .identifier = "fs:allow-read-text-file" },
        \\      },
        \\    },
        \\  },
        \\}
    );
    defer metadata.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), metadata.capabilities.len);

    try std.testing.expectEqualStrings("main-fs", metadata.capabilities[0].identifier);
    try std.testing.expectEqualStrings("main window filesystem access", metadata.capabilities[0].description);
    try std.testing.expectEqual(@as(usize, 1), metadata.capabilities[0].windows.len);
    try std.testing.expectEqualStrings("main", metadata.capabilities[0].windows[0]);
    try std.testing.expectEqual(@as(usize, 2), metadata.capabilities[0].permissions.len);

    const fs_perm = metadata.capabilities[0].permissions[0];
    try std.testing.expectEqualStrings("fs:allow-read-text-file", fs_perm.identifier);
    try std.testing.expectEqual(@as(usize, 1), fs_perm.scopes.allow.len);
    try std.testing.expectEqual(capability.ScopeKind.path, fs_perm.scopes.allow[0].kind);
    try std.testing.expectEqualStrings("$APPDATA/**", fs_perm.scopes.allow[0].pattern);
    try std.testing.expectEqual(@as(usize, 1), fs_perm.scopes.deny.len);
    try std.testing.expectEqual(capability.ScopeKind.path, fs_perm.scopes.deny[0].kind);
    try std.testing.expectEqualStrings("$APPDATA/secret/**", fs_perm.scopes.deny[0].pattern);

    const net_perm = metadata.capabilities[0].permissions[1];
    try std.testing.expectEqualStrings("network:allow-fetch", net_perm.identifier);
    try std.testing.expectEqual(@as(usize, 1), net_perm.scopes.allow.len);
    try std.testing.expectEqual(capability.ScopeKind.url, net_perm.scopes.allow[0].kind);
    try std.testing.expectEqualStrings("https://api.example.com/**", net_perm.scopes.allow[0].pattern);
    try std.testing.expectEqualStrings("https://api.example.com/internal/**", net_perm.scopes.deny[0].pattern);

    try std.testing.expectEqualStrings("anywhere-fs", metadata.capabilities[1].identifier);
    try std.testing.expectEqualStrings("", metadata.capabilities[1].description);
    try std.testing.expectEqualStrings("*", metadata.capabilities[1].windows[0]);
    try std.testing.expectEqual(@as(usize, 1), metadata.capabilities[1].permissions.len);
    try std.testing.expectEqualStrings("fs:allow-read-text-file", metadata.capabilities[1].permissions[0].identifier);
    try std.testing.expectEqual(@as(usize, 0), metadata.capabilities[1].permissions[0].scopes.allow.len);
    try std.testing.expectEqual(@as(usize, 0), metadata.capabilities[1].permissions[0].scopes.deny.len);
}

test "manifest metadata parser rejects invalid scope kind" {
    const result = parseText(std.testing.allocator,
        \\.{
        \\  .id = "com.example.app",
        \\  .name = "example",
        \\  .version = "1.2.3",
        \\  .capabilities = .{
        \\    .{
        \\      .identifier = "broken",
        \\      .windows = .{ "main" },
        \\      .permissions = .{
        \\        .{
        \\          .identifier = "fs:read",
        \\          .scopes = .{
        \\            .allow = .{ .{ .kind = "bogus", .pattern = "/x" } },
        \\          },
        \\        },
        \\      },
        \\    },
        \\  },
        \\}
    );
    try std.testing.expectError(error.InvalidScopeKind, result);
}
