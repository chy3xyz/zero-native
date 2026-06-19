const web_engine = @import("web_engine.zig");

pub const RawManifest = struct {
    id: []const u8,
    name: []const u8,
    display_name: ?[]const u8 = null,
    version: []const u8,
    icons: []const []const u8 = &.{},
    platforms: []const []const u8 = &.{},
    permissions: []const []const u8 = &.{},
    /// Simple feature flags (e.g. "webview", "js_bridge") used for
    /// package-level capability validation. These are distinct from the
    /// structured `capabilities` list, which carries per-window security
    /// policies consumed at runtime.
    feature_capabilities: []const []const u8 = &.{},
    bridge: RawBridge = .{},
    web_engine: []const u8 = @tagName(web_engine.default_engine),
    cef: RawCef = .{},
    frontend: ?RawFrontend = null,
    security: RawSecurity = .{},
    windows: []const RawWindow = &.{},
    /// Update feed configuration. When `feed_url` is set and the `updater`
    /// plugin is enabled, the runtime can fetch signed manifests automatically.
    updates: RawUpdates = .{},
    /// Custom URL schemes registered by the deep-link plugin. Each entry is
    /// a scheme name (e.g. "myapp") that macOS, Linux, and Windows will use
    /// to route URL invocations to the packaged app.
    deep_link_schemes: []const []const u8 = &.{},
    /// Debug / development options.
    debug: RawDebug = .{},
    /// Plugin module names enabled for this app (e.g. "clipboard", "shell").
    /// The list is consumed by `extensions.registry.loadFromManifest` to
    /// instantiate matching `extensions.Module` values at startup. Unknown
    /// names cause a hard error so typos are caught at load time.
    plugins: []const []const u8 = &.{},
    /// Structured per-window security capabilities. Each entry describes
    /// a named capability, the windows it targets, and the granular
    /// permissions it grants with allow/deny scope globs.
    capabilities: []const RawSecurityCapability = &.{},
};

pub const RawDebug = struct {
    /// When true, enables the platform WebView's built-in developer tools
    /// (Web Inspector / DevTools). Equivalent to Electron's
    /// `webPreferences.devTools`.
    devtools: bool = false,
};

pub const RawUpdates = struct {
    feed_url: []const u8 = "",
    public_key: []const u8 = "",
    check_on_start: bool = false,
};

pub const RawCef = struct {
    dir: []const u8 = web_engine.default_cef_dir,
    auto_install: bool = false,
};

pub const RawBridge = struct {
    commands: []const RawBridgeCommand = &.{},
};

pub const RawBridgeCommand = struct {
    name: []const u8,
    permissions: []const []const u8 = &.{},
    origins: []const []const u8 = &.{},
};

pub const RawFrontend = struct {
    dist: []const u8 = "dist",
    entry: []const u8 = "index.html",
    spa_fallback: bool = true,
    dev: ?RawFrontendDev = null,
};

pub const RawFrontendDev = struct {
    url: []const u8,
    command: []const []const u8 = &.{},
    ready_path: []const u8 = "/",
    timeout_ms: u32 = 30_000,
};

pub const RawSecurity = struct {
    navigation: RawNavigation = .{},
    sandbox: RawSandbox = .{},
};

pub const RawSandbox = struct {
    sandbox: bool = true,
    network_client: bool = false,
    network_server: bool = false,
    files_user_selected_read: bool = false,
    files_user_selected_write: bool = false,
    file_read: []const []const u8 = &.{},
    file_write: []const []const u8 = &.{},
    camera: bool = false,
    microphone: bool = false,
    usb: bool = false,
    printing: bool = false,
    allow_jit: bool = true,
    custom: bool = false,
};

pub const RawNavigation = struct {
    allowed_origins: []const []const u8 = &.{},
    external_links: RawExternalLinks = .{},
};

pub const RawExternalLinks = struct {
    action: []const u8 = "deny",
    allowed_urls: []const []const u8 = &.{},
};

pub const RawWindow = struct {
    label: []const u8 = "main",
    title: ?[]const u8 = null,
    width: f32 = 720,
    height: f32 = 480,
    x: ?f32 = null,
    y: ?f32 = null,
    restore_state: bool = true,
};

/// Structured security capability entry. Mirrors
/// `security.capability.Capability` but uses borrowed string slices and
/// string-typed scope kinds so the ZON parser can populate it directly.
pub const RawSecurityCapability = struct {
    identifier: []const u8,
    description: []const u8 = "",
    windows: []const []const u8 = &.{},
    permissions: []const RawSecurityPermission = &.{},
};

pub const RawSecurityPermission = struct {
    identifier: []const u8,
    scopes: RawSecurityScopeSet = .{},
};

pub const RawSecurityScopeSet = struct {
    allow: []const RawSecurityScope = &.{},
    deny: []const RawSecurityScope = &.{},
};

/// Scope kind is stored as a string ("path" or "url") so the ZON parser
/// does not need enum metadata; the manifest parser converts to
/// `capability.ScopeKind` while copying the strings into the allocator.
pub const RawSecurityScope = struct {
    kind: []const u8,
    pattern: []const u8,
};
