const std = @import("std");
const assets_tool = @import("assets.zig");
const cef = @import("cef.zig");
const codesign = @import("codesign.zig");
const diagnostics = @import("diagnostics");
const manifest_tool = @import("manifest.zig");
const security = @import("security");
const web_engine_tool = @import("web_engine.zig");

pub const PackageTarget = enum {
    macos,
    windows,
    linux,
    ios,
    android,

    pub fn parse(value: []const u8) ?PackageTarget {
        const info = @typeInfo(PackageTarget).@"enum";
        inline for (info.field_names, info.field_values) |field_name, field_value| {
            if (std.mem.eql(u8, value, field_name)) return @enumFromInt(field_value);
        }
        return null;
    }
};

pub const SigningMode = enum {
    none,
    adhoc,
    identity,

    pub fn parse(value: []const u8) ?SigningMode {
        if (std.mem.eql(u8, value, "none")) return .none;
        if (std.mem.eql(u8, value, "adhoc") or std.mem.eql(u8, value, "ad-hoc")) return .adhoc;
        if (std.mem.eql(u8, value, "identity")) return .identity;
        return null;
    }
};

pub const WebEngine = web_engine_tool.Engine;

pub const SigningConfig = struct {
    mode: SigningMode = .none,
    identity: ?[]const u8 = null,
    entitlements: ?[]const u8 = null,
    profile: ?[]const u8 = null,
    team_id: ?[]const u8 = null,
};

/// Outcome of `runSigning`. The `plan` field is always owned by the caller
/// and must be released with `deinit`.
pub const SigningResult = struct {
    /// Text written to `Contents/Resources/signing-plan.txt`. Owned.
    plan: []u8,
    /// Whether the bundle was actually signed successfully.
    ok: bool,
    /// The signing mode that was attempted.
    mode: SigningMode,
    /// The identity used when `mode == .identity`, otherwise null.
    identity: ?[]const u8,

    pub fn deinit(self: SigningResult, allocator: std.mem.Allocator) void {
        allocator.free(self.plan);
    }
};

pub const PackageOptions = struct {
    metadata: manifest_tool.Metadata,
    target: PackageTarget = .macos,
    optimize: []const u8 = "Debug",
    output_path: []const u8,
    binary_path: ?[]const u8 = null,
    assets_dir: []const u8 = "assets",
    frontend: ?manifest_tool.FrontendMetadata = null,
    web_engine: WebEngine = .system,
    cef_dir: []const u8 = web_engine_tool.default_cef_dir,
    signing: SigningConfig = .{},
    archive: bool = false,
    /// When true (the default), `runSigning` returns an error if codesign or
    /// notarization fails. Set to false to keep the previous opt-in soft
    /// failure mode where an unsigned bundle is produced with a plan file
    /// describing the failure.
    fail_on_signing_error: bool = true,
};

pub const PackageStats = struct {
    path: []const u8,
    artifact_name: []const u8 = "",
    target: PackageTarget = .macos,
    signing_mode: SigningMode = .none,
    asset_count: usize = 0,
    web_engine: WebEngine = .system,
    archive_path: ?[]const u8 = null,
};

pub fn artifactName(buffer: []u8, metadata: manifest_tool.Metadata, target: PackageTarget, optimize: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}-{s}-{s}-{s}{s}", .{
        metadata.name,
        metadata.version,
        @tagName(target),
        optimize,
        artifactSuffix(target),
    });
}

pub fn createPackage(allocator: std.mem.Allocator, io: std.Io, options: PackageOptions) !PackageStats {
    var stats = switch (options.target) {
        .macos => try createMacosApp(allocator, io, options),
        .windows, .linux => try createDesktopArtifact(allocator, io, options),
        .ios => try createIosArtifact(allocator, io, options),
        .android => try createAndroidArtifact(allocator, io, options),
    };
    if (options.archive) {
        const archive_path = try createArchive(allocator, io, options);
        if (archive_path) |path| {
            stats.archive_path = path;
        }
    }
    return stats;
}

pub fn printDiagnostic(stats: PackageStats) void {
    var buffer: [256]u8 = undefined;
    var message_buffer: [192]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    diagnostics.formatShort(.{
        .severity = .info,
        .code = diagnostics.code("package", "created"),
        .message = std.fmt.bufPrint(&message_buffer, "created {s} artifact at {s}", .{ @tagName(stats.target), stats.path }) catch "created package",
    }, &writer) catch return;
    std.debug.print("{s}\n", .{writer.buffered()});
    if (stats.archive_path) |archive| {
        std.debug.print("  archive: {s}\n", .{archive});
    }
}

pub fn createLocalPackage(io: std.Io, output_path: []const u8) !PackageStats {
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.zero_native.local",
        .name = "zero-native-local",
        .version = "0.1.0",
    };
    return createMacosApp(std.heap.page_allocator, io, .{
        .metadata = metadata,
        .output_path = output_path,
        .binary_path = null,
    });
}

pub fn createMacosApp(allocator: std.mem.Allocator, io: std.Io, options: PackageOptions) !PackageStats {
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, options.output_path);
    var package_dir = try cwd.openDir(io, options.output_path, .{});
    defer package_dir.close(io);
    try package_dir.createDirPath(io, "Contents/MacOS");
    try package_dir.createDirPath(io, "Contents/Resources");

    const executable_name = std.fs.path.basename(options.metadata.name);
    if (options.binary_path) |binary_path| {
        const executable_subpath = try std.fmt.allocPrint(allocator, "Contents/MacOS/{s}", .{executable_name});
        defer allocator.free(executable_subpath);
        try copyFileToDir(allocator, io, package_dir, binary_path, executable_subpath);
        try makeExecutable(package_dir, io, executable_subpath);
    } else {
        try writeFile(package_dir, io, "Contents/MacOS/README.txt", "No app binary was supplied for this local package.\n");
    }

    const info_plist = try macosInfoPlist(allocator, options.metadata, executable_name);
    defer allocator.free(info_plist);
    try writeFile(package_dir, io, "Contents/Info.plist", info_plist);
    try writeFile(package_dir, io, "Contents/PkgInfo", "APPL????");
    try writeFile(package_dir, io, "Contents/Resources/README.txt", "Unsigned local zero-native macOS app bundle.\n");
    const assets_output = try assetOutputPath(allocator, options.output_path, "Contents/Resources", options);
    defer allocator.free(assets_output);
    const bundle_stats = try assets_tool.bundle(allocator, io, options.assets_dir, assets_output);
    try copyMacosIcon(allocator, io, package_dir, options);
    try writeReport(allocator, package_dir, io, "Contents/Resources/package-manifest.zon", options, executable_name, bundle_stats.asset_count);
    if (options.web_engine == .chromium) {
        try cef.ensureLayout(io, options.cef_dir);
        try copyMacosCefRuntime(allocator, io, package_dir, options.cef_dir);
    }

    // Generate sandbox entitlements plist if the app declares App Sandbox.
    var sandbox_entitlements_path: ?[]const u8 = null;
    if (options.metadata.security.sandbox.sandbox) {
        const sandbox_ents = try security.sandbox.entitlements(options.metadata.security.sandbox, allocator);
        defer security.sandbox.freeEntitlements(allocator, sandbox_ents);
        const plist = try security.sandbox.toPlist(allocator, sandbox_ents);
        defer allocator.free(plist);
        const ent_path = try std.fmt.allocPrint(allocator, "{s}.entitlements", .{options.output_path});
        sandbox_entitlements_path = ent_path;
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ent_path, .data = plist });
    }
    defer if (sandbox_entitlements_path) |path| allocator.free(path);

    const signing_result = try runSigning(allocator, io, package_dir, options, sandbox_entitlements_path);
    defer signing_result.deinit(allocator);

    return .{
        .path = options.output_path,
        .artifact_name = std.fs.path.basename(options.output_path),
        .target = .macos,
        .signing_mode = options.signing.mode,
        .asset_count = bundle_stats.asset_count,
        .web_engine = options.web_engine,
    };
}

pub fn createIosSkeleton(io: std.Io, output_path: []const u8) !PackageStats {
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, output_path);
    var dir = try cwd.openDir(io, output_path, .{});
    defer dir.close(io);
    try dir.createDirPath(io, "zero-nativeHost");
    try writeFile(dir, io, "README.md", iosReadme());
    try writeFile(dir, io, "Info.plist", iosInfoPlist());
    try writeFile(dir, io, "zero-nativeHost/ZeroNativeHostViewController.swift", iosViewController());
    try writeFile(dir, io, "zero-nativeHost/zero_native.h", embedHeader());
    return .{ .path = output_path, .target = .ios };
}

/// Generates a real, buildable Xcode project (`project.pbxproj`) for an
/// iOS app. The template is based on the project's own example
/// (`examples/ios/ZeroNativeIOSExample.xcodeproj/project.pbxproj`) with the
/// app name and bundle id parameterized.
///
/// UUIDs are fixed 24-char hex identifiers; they are required to be
/// unique within a single project and consistent across regenerations, so
/// the same hard-coded block is reused. The Swift sources, frameworks,
/// bridging header, and Info.plist references follow the file names
/// produced by `createIosFullApp`.
///
/// To avoid `{{` / `}}` brace escaping for the pbxproj's literal braces
/// and to keep the source readable, the template uses `__APP_NAME__` and
/// `__APP_ID__` as placeholders and performs two `std.mem.replaceOwned`
/// substitutions.
fn generatePbxproj(allocator: std.mem.Allocator, app_name: []const u8, app_id: []const u8) ![]u8 {
    // The template is built with explicit \t and \n escapes inside a
    // regular `"..."` string. Zig 0.17 rejects raw tab characters in raw
    // multi-line strings, so we assemble the pbxproj with `++` concat.
    const t = "\t";
    const nl = "\n";
    const template =
        "// !$*UTF8*$!" ++ nl ++
        "{" ++ nl ++
        t ++ "archiveVersion = 1;" ++ nl ++
        t ++ "classes = {" ++ nl ++
        t ++ "};" ++ nl ++
        t ++ "objectVersion = 56;" ++ nl ++
        t ++ "objects = {" ++ nl ++
        nl ++
        "/* Begin PBXBuildFile section */" ++ nl ++
        t ++ t ++ "100000000000000000000001 /* AppDelegate.swift in Sources */ = {isa = PBXBuildFile; fileRef = 100000000000000000000011 /* AppDelegate.swift */; };" ++ nl ++
        t ++ t ++ "100000000000000000000002 /* SceneDelegate.swift in Sources */ = {isa = PBXBuildFile; fileRef = 100000000000000000000012 /* SceneDelegate.swift */; };" ++ nl ++
        t ++ t ++ "100000000000000000000003 /* ViewController.swift in Sources */ = {isa = PBXBuildFile; fileRef = 100000000000000000000013 /* ViewController.swift */; };" ++ nl ++
        t ++ t ++ "100000000000000000000004 /* libzero-native.a in Frameworks */ = {isa = PBXBuildFile; fileRef = 100000000000000000000015 /* libzero-native.a */; };" ++ nl ++
        t ++ t ++ "100000000000000000000005 /* Main.storyboard in Resources */ = {isa = PBXBuildFile; fileRef = 100000000000000000000017 /* Main.storyboard */; };" ++ nl ++
        t ++ t ++ "100000000000000000000006 /* LaunchScreen.storyboard in Resources */ = {isa = PBXBuildFile; fileRef = 100000000000000000000018 /* LaunchScreen.storyboard */; };" ++ nl ++
        t ++ t ++ "100000000000000000000007 /* Assets.xcassets in Resources */ = {isa = PBXBuildFile; fileRef = 100000000000000000000019 /* Assets.xcassets */; };" ++ nl ++
        "/* End PBXBuildFile section */" ++ nl ++
        nl ++
        "/* Begin PBXFileReference section */" ++ nl ++
        t ++ t ++ "100000000000000000000010 /* __APP_NAME__.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = \"__APP_NAME__.app\"; sourceTree = BUILT_PRODUCTS_DIR; };" ++ nl ++
        t ++ t ++ "100000000000000000000011 /* AppDelegate.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AppDelegate.swift; sourceTree = \"<group>\"; };" ++ nl ++
        t ++ t ++ "100000000000000000000012 /* SceneDelegate.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SceneDelegate.swift; sourceTree = \"<group>\"; };" ++ nl ++
        t ++ t ++ "100000000000000000000013 /* ViewController.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ViewController.swift; sourceTree = \"<group>\"; };" ++ nl ++
        t ++ t ++ "100000000000000000000014 /* Bridging-Header.h */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = \"Bridging-Header.h\"; sourceTree = \"<group>\"; };" ++ nl ++
        t ++ t ++ "100000000000000000000015 /* libzero-native.a */ = {isa = PBXFileReference; lastKnownFileType = archive.ar; path = \"Libraries/libzero-native.a\"; sourceTree = SOURCE_ROOT; };" ++ nl ++
        t ++ t ++ "100000000000000000000016 /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; };" ++ nl ++
        t ++ t ++ "100000000000000000000017 /* Main.storyboard */ = {isa = PBXFileReference; lastKnownFileType = file.storyboard; path = Main.storyboard; sourceTree = \"<group>\"; };" ++ nl ++
        t ++ t ++ "100000000000000000000018 /* LaunchScreen.storyboard */ = {isa = PBXFileReference; lastKnownFileType = file.storyboard; path = LaunchScreen.storyboard; sourceTree = \"<group>\"; };" ++ nl ++
        t ++ t ++ "100000000000000000000019 /* Assets.xcassets */ = {isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; };" ++ nl ++
        t ++ t ++ "100000000000000000000020 /* __APP_NAME__.entitlements */ = {isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = \"__APP_NAME__.entitlements\"; sourceTree = \"<group>\"; };" ++ nl ++
        "/* End PBXFileReference section */" ++ nl ++
        nl ++
        "/* Begin PBXFrameworksBuildPhase section */" ++ nl ++
        t ++ t ++ "100000000000000000000021 /* Frameworks */ = {" ++ nl ++
        t ++ t ++ t ++ "isa = PBXFrameworksBuildPhase;" ++ nl ++
        t ++ t ++ t ++ "buildActionMask = 2147483647;" ++ nl ++
        t ++ t ++ t ++ "files = (" ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000004 /* libzero-native.a in Frameworks */," ++ nl ++
        t ++ t ++ t ++ ");" ++ nl ++
        t ++ t ++ t ++ "runOnlyForDeploymentPostprocessing = 0;" ++ nl ++
        t ++ t ++ "};" ++ nl ++
        "/* End PBXFrameworksBuildPhase section */" ++ nl ++
        nl ++
        "/* Begin PBXGroup section */" ++ nl ++
        t ++ t ++ "100000000000000000000030 = {" ++ nl ++
        t ++ t ++ t ++ "isa = PBXGroup;" ++ nl ++
        t ++ t ++ t ++ "children = (" ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000040 /* __APP_NAME__ */," ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000015 /* libzero-native.a */," ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000050 /* Products */," ++ nl ++
        t ++ t ++ t ++ ");" ++ nl ++
        t ++ t ++ t ++ "sourceTree = \"<group>\";" ++ nl ++
        t ++ t ++ "};" ++ nl ++
        t ++ t ++ "100000000000000000000040 /* __APP_NAME__ */ = {" ++ nl ++
        t ++ t ++ t ++ "isa = PBXGroup;" ++ nl ++
        t ++ t ++ t ++ "children = (" ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000011 /* AppDelegate.swift */," ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000012 /* SceneDelegate.swift */," ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000013 /* ViewController.swift */," ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000014 /* Bridging-Header.h */," ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000016 /* Info.plist */," ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000017 /* Main.storyboard */," ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000018 /* LaunchScreen.storyboard */," ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000019 /* Assets.xcassets */," ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000020 /* __APP_NAME__.entitlements */," ++ nl ++
        t ++ t ++ t ++ ");" ++ nl ++
        t ++ t ++ t ++ "path = __APP_NAME__;" ++ nl ++
        t ++ t ++ t ++ "sourceTree = \"<group>\";" ++ nl ++
        t ++ t ++ "};" ++ nl ++
        t ++ t ++ "100000000000000000000050 /* Products */ = {" ++ nl ++
        t ++ t ++ t ++ "isa = PBXGroup;" ++ nl ++
        t ++ t ++ t ++ "children = (" ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000010 /* __APP_NAME__.app */," ++ nl ++
        t ++ t ++ t ++ ");" ++ nl ++
        t ++ t ++ t ++ "name = Products;" ++ nl ++
        t ++ t ++ t ++ "sourceTree = \"<group>\";" ++ nl ++
        t ++ t ++ "};" ++ nl ++
        "/* End PBXGroup section */" ++ nl ++
        nl ++
        "/* Begin PBXNativeTarget section */" ++ nl ++
        t ++ t ++ "100000000000000000000060 /* __APP_NAME__ */ = {" ++ nl ++
        t ++ t ++ t ++ "isa = PBXNativeTarget;" ++ nl ++
        t ++ t ++ t ++ "buildConfigurationList = 100000000000000000000090 /* Build configuration list for PBXNativeTarget \"__APP_NAME__\" */;" ++ nl ++
        t ++ t ++ t ++ "buildPhases = (" ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000070 /* Sources */," ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000021 /* Frameworks */," ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000071 /* Resources */," ++ nl ++
        t ++ t ++ t ++ ");" ++ nl ++
        t ++ t ++ t ++ "buildRules = (" ++ nl ++
        t ++ t ++ t ++ ");" ++ nl ++
        t ++ t ++ t ++ "dependencies = (" ++ nl ++
        t ++ t ++ t ++ ");" ++ nl ++
        t ++ t ++ t ++ "name = __APP_NAME__;" ++ nl ++
        t ++ t ++ t ++ "productName = __APP_NAME__;" ++ nl ++
        t ++ t ++ t ++ "productReference = 100000000000000000000010 /* __APP_NAME__.app */;" ++ nl ++
        t ++ t ++ t ++ "productType = \"com.apple.product-type.application\";" ++ nl ++
        t ++ t ++ "};" ++ nl ++
        "/* End PBXNativeTarget section */" ++ nl ++
        nl ++
        "/* Begin PBXProject section */" ++ nl ++
        t ++ t ++ "100000000000000000000080 /* Project object */ = {" ++ nl ++
        t ++ t ++ t ++ "isa = PBXProject;" ++ nl ++
        t ++ t ++ t ++ "attributes = {" ++ nl ++
        t ++ t ++ t ++ t ++ "BuildIndependentTargetsInParallel = 1;" ++ nl ++
        t ++ t ++ t ++ t ++ "LastSwiftUpdateCheck = 1600;" ++ nl ++
        t ++ t ++ t ++ t ++ "LastUpgradeCheck = 1600;" ++ nl ++
        t ++ t ++ t ++ t ++ "TargetAttributes = {" ++ nl ++
        t ++ t ++ t ++ t ++ t ++ "100000000000000000000060 = {" ++ nl ++
        t ++ t ++ t ++ t ++ t ++ t ++ "CreatedOnToolsVersion = 16.0;" ++ nl ++
        t ++ t ++ t ++ t ++ t ++ "};" ++ nl ++
        t ++ t ++ t ++ t ++ "};" ++ nl ++
        t ++ t ++ t ++ "};" ++ nl ++
        t ++ t ++ t ++ "buildConfigurationList = 100000000000000000000081 /* Build configuration list for PBXProject \"__APP_NAME__\" */;" ++ nl ++
        t ++ t ++ t ++ "compatibilityVersion = \"Xcode 14.0\";" ++ nl ++
        t ++ t ++ t ++ "developmentRegion = en;" ++ nl ++
        t ++ t ++ t ++ "hasScannedForEncodings = 0;" ++ nl ++
        t ++ t ++ t ++ "knownRegions = (" ++ nl ++
        t ++ t ++ t ++ t ++ "en," ++ nl ++
        t ++ t ++ t ++ t ++ "Base," ++ nl ++
        t ++ t ++ t ++ ");" ++ nl ++
        t ++ t ++ t ++ "mainGroup = 100000000000000000000030;" ++ nl ++
        t ++ t ++ t ++ "productRefGroup = 100000000000000000000050 /* Products */;" ++ nl ++
        t ++ t ++ t ++ "projectDirPath = \"\";" ++ nl ++
        t ++ t ++ t ++ "projectRoot = \"\";" ++ nl ++
        t ++ t ++ t ++ "targets = (" ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000060 /* __APP_NAME__ */," ++ nl ++
        t ++ t ++ t ++ ");" ++ nl ++
        t ++ t ++ "};" ++ nl ++
        "/* End PBXProject section */" ++ nl ++
        nl ++
        "/* Begin PBXResourcesBuildPhase section */" ++ nl ++
        t ++ t ++ "100000000000000000000071 /* Resources */ = {" ++ nl ++
        t ++ t ++ t ++ "isa = PBXResourcesBuildPhase;" ++ nl ++
        t ++ t ++ t ++ "buildActionMask = 2147483647;" ++ nl ++
        t ++ t ++ t ++ "files = (" ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000005 /* Main.storyboard in Resources */," ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000006 /* LaunchScreen.storyboard in Resources */," ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000007 /* Assets.xcassets in Resources */," ++ nl ++
        t ++ t ++ t ++ ");" ++ nl ++
        t ++ t ++ t ++ "runOnlyForDeploymentPostprocessing = 0;" ++ nl ++
        t ++ t ++ "};" ++ nl ++
        "/* End PBXResourcesBuildPhase section */" ++ nl ++
        nl ++
        "/* Begin PBXSourcesBuildPhase section */" ++ nl ++
        t ++ t ++ "100000000000000000000070 /* Sources */ = {" ++ nl ++
        t ++ t ++ t ++ "isa = PBXSourcesBuildPhase;" ++ nl ++
        t ++ t ++ t ++ "buildActionMask = 2147483647;" ++ nl ++
        t ++ t ++ t ++ "files = (" ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000001 /* AppDelegate.swift in Sources */," ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000002 /* SceneDelegate.swift in Sources */," ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000003 /* ViewController.swift in Sources */," ++ nl ++
        t ++ t ++ t ++ ");" ++ nl ++
        t ++ t ++ t ++ "runOnlyForDeploymentPostprocessing = 0;" ++ nl ++
        t ++ t ++ "};" ++ nl ++
        "/* End PBXSourcesBuildPhase section */" ++ nl ++
        nl ++
        "/* Begin XCBuildConfiguration section */" ++ nl ++
        t ++ t ++ "100000000000000000000082 /* Debug */ = {" ++ nl ++
        t ++ t ++ t ++ "isa = XCBuildConfiguration;" ++ nl ++
        t ++ t ++ t ++ "buildSettings = {" ++ nl ++
        t ++ t ++ t ++ t ++ "IPHONEOS_DEPLOYMENT_TARGET = 15.0;" ++ nl ++
        t ++ t ++ t ++ t ++ "SDKROOT = iphoneos;" ++ nl ++
        t ++ t ++ t ++ t ++ "SWIFT_VERSION = 5.0;" ++ nl ++
        t ++ t ++ t ++ "};" ++ nl ++
        t ++ t ++ t ++ "name = Debug;" ++ nl ++
        t ++ t ++ "};" ++ nl ++
        t ++ t ++ "100000000000000000000083 /* Release */ = {" ++ nl ++
        t ++ t ++ t ++ "isa = XCBuildConfiguration;" ++ nl ++
        t ++ t ++ t ++ "buildSettings = {" ++ nl ++
        t ++ t ++ t ++ t ++ "IPHONEOS_DEPLOYMENT_TARGET = 15.0;" ++ nl ++
        t ++ t ++ t ++ t ++ "SDKROOT = iphoneos;" ++ nl ++
        t ++ t ++ t ++ t ++ "SWIFT_VERSION = 5.0;" ++ nl ++
        t ++ t ++ t ++ "};" ++ nl ++
        t ++ t ++ t ++ "name = Release;" ++ nl ++
        t ++ t ++ "};" ++ nl ++
        t ++ t ++ "100000000000000000000091 /* Debug */ = {" ++ nl ++
        t ++ t ++ t ++ "isa = XCBuildConfiguration;" ++ nl ++
        t ++ t ++ t ++ "buildSettings = {" ++ nl ++
        t ++ t ++ t ++ t ++ "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;" ++ nl ++
        t ++ t ++ t ++ t ++ "CODE_SIGN_ENTITLEMENTS = __APP_NAME__/__APP_NAME__.entitlements;" ++ nl ++
        t ++ t ++ t ++ t ++ "CODE_SIGN_STYLE = Automatic;" ++ nl ++
        t ++ t ++ t ++ t ++ "DEVELOPMENT_TEAM = \"\";" ++ nl ++
        t ++ t ++ t ++ t ++ "GENERATE_INFOPLIST_FILE = NO;" ++ nl ++
        t ++ t ++ t ++ t ++ "INFOPLIST_FILE = __APP_NAME__/Info.plist;" ++ nl ++
        t ++ t ++ t ++ t ++ "LD_RUNPATH_SEARCH_PATHS = \"$(inherited) @executable_path/Frameworks\";" ++ nl ++
        t ++ t ++ t ++ t ++ "LIBRARY_SEARCH_PATHS = \"$(PROJECT_DIR)/Libraries\";" ++ nl ++
        t ++ t ++ t ++ t ++ "OTHER_LDFLAGS = \"$(inherited) -lzero-native\";" ++ nl ++
        t ++ t ++ t ++ t ++ "PRODUCT_BUNDLE_IDENTIFIER = \"__APP_ID__\";" ++ nl ++
        t ++ t ++ t ++ t ++ "PRODUCT_NAME = \"$(TARGET_NAME)\";" ++ nl ++
        t ++ t ++ t ++ t ++ "SWIFT_OBJC_BRIDGING_HEADER = __APP_NAME__/Bridging-Header.h;" ++ nl ++
        t ++ t ++ t ++ t ++ "SWIFT_VERSION = 5.0;" ++ nl ++
        t ++ t ++ t ++ t ++ "TARGETED_DEVICE_FAMILY = \"1,2\";" ++ nl ++
        t ++ t ++ t ++ "};" ++ nl ++
        t ++ t ++ t ++ "name = Debug;" ++ nl ++
        t ++ t ++ "};" ++ nl ++
        t ++ t ++ "100000000000000000000092 /* Release */ = {" ++ nl ++
        t ++ t ++ t ++ "isa = XCBuildConfiguration;" ++ nl ++
        t ++ t ++ t ++ "buildSettings = {" ++ nl ++
        t ++ t ++ t ++ t ++ "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;" ++ nl ++
        t ++ t ++ t ++ t ++ "CODE_SIGN_ENTITLEMENTS = __APP_NAME__/__APP_NAME__.entitlements;" ++ nl ++
        t ++ t ++ t ++ t ++ "CODE_SIGN_STYLE = Automatic;" ++ nl ++
        t ++ t ++ t ++ t ++ "DEVELOPMENT_TEAM = \"\";" ++ nl ++
        t ++ t ++ t ++ t ++ "GENERATE_INFOPLIST_FILE = NO;" ++ nl ++
        t ++ t ++ t ++ t ++ "INFOPLIST_FILE = __APP_NAME__/Info.plist;" ++ nl ++
        t ++ t ++ t ++ t ++ "LD_RUNPATH_SEARCH_PATHS = \"$(inherited) @executable_path/Frameworks\";" ++ nl ++
        t ++ t ++ t ++ t ++ "LIBRARY_SEARCH_PATHS = \"$(PROJECT_DIR)/Libraries\";" ++ nl ++
        t ++ t ++ t ++ t ++ "OTHER_LDFLAGS = \"$(inherited) -lzero-native\";" ++ nl ++
        t ++ t ++ t ++ t ++ "PRODUCT_BUNDLE_IDENTIFIER = \"__APP_ID__\";" ++ nl ++
        t ++ t ++ t ++ t ++ "PRODUCT_NAME = \"$(TARGET_NAME)\";" ++ nl ++
        t ++ t ++ t ++ t ++ "SWIFT_OBJC_BRIDGING_HEADER = __APP_NAME__/Bridging-Header.h;" ++ nl ++
        t ++ t ++ t ++ t ++ "SWIFT_VERSION = 5.0;" ++ nl ++
        t ++ t ++ t ++ t ++ "TARGETED_DEVICE_FAMILY = \"1,2\";" ++ nl ++
        t ++ t ++ t ++ "};" ++ nl ++
        t ++ t ++ t ++ "name = Release;" ++ nl ++
        t ++ t ++ "};" ++ nl ++
        "/* End XCBuildConfiguration section */" ++ nl ++
        nl ++
        "/* Begin XCConfigurationList section */" ++ nl ++
        t ++ t ++ "100000000000000000000081 /* Build configuration list for PBXProject \"__APP_NAME__\" */ = {" ++ nl ++
        t ++ t ++ t ++ "isa = XCConfigurationList;" ++ nl ++
        t ++ t ++ t ++ "buildConfigurations = (" ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000082 /* Debug */," ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000083 /* Release */," ++ nl ++
        t ++ t ++ t ++ ");" ++ nl ++
        t ++ t ++ t ++ "defaultConfigurationIsVisible = 0;" ++ nl ++
        t ++ t ++ t ++ "defaultConfigurationName = Release;" ++ nl ++
        t ++ t ++ "};" ++ nl ++
        t ++ t ++ "100000000000000000000090 /* Build configuration list for PBXNativeTarget \"__APP_NAME__\" */ = {" ++ nl ++
        t ++ t ++ t ++ "isa = XCConfigurationList;" ++ nl ++
        t ++ t ++ t ++ "buildConfigurations = (" ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000091 /* Debug */," ++ nl ++
        t ++ t ++ t ++ t ++ "100000000000000000000092 /* Release */," ++ nl ++
        t ++ t ++ t ++ ");" ++ nl ++
        t ++ t ++ t ++ "defaultConfigurationIsVisible = 0;" ++ nl ++
        t ++ t ++ t ++ "defaultConfigurationName = Release;" ++ nl ++
        t ++ t ++ "};" ++ nl ++
        "/* End XCConfigurationList section */" ++ nl ++
        t ++ "};" ++ nl ++
        t ++ "rootObject = 100000000000000000000080 /* Project object */;" ++ nl ++
        "}" ++ nl;

    // Substitute placeholders. We use a sentinel token that won't collide
    // with anything in the template.
    const out = try std.mem.replaceOwned(u8, allocator, template, "__APP_NAME__", app_name);
    defer allocator.free(out);
    const final_pbxproj = try std.mem.replaceOwned(u8, allocator, out, "__APP_ID__", app_id);
    return final_pbxproj;
}

/// Generates a complete, buildable iOS Xcode project in `<base_dir>/<app_name>/`.
///
/// Layout produced:
///   <base_dir>/<app_name>/AppDelegate.swift
///   <base_dir>/<app_name>/SceneDelegate.swift
///   <base_dir>/<app_name>/ViewController.swift
///   <base_dir>/<app_name>/Info.plist
///   <base_dir>/<app_name>/Main.storyboard
///   <base_dir>/<app_name>/LaunchScreen.storyboard
///   <base_dir>/<app_name>/<app_name>.entitlements
///   <base_dir>/<app_name>/Bridging-Header.h
///   <base_dir>/<app_name>/Assets.xcassets/Contents.json
///   <base_dir>/<app_name>/Assets.xcassets/AppIcon.appiconset/Contents.json
///   <base_dir>/<app_name>/<app_name>.xcodeproj/project.pbxproj
///   <base_dir>/README.md
///
/// `icon_path` is accepted for API compatibility; icon generation is stubbed
/// (the `AppIcon.appiconset/Contents.json` placeholder is written). The
/// `deep_link_scheme`, when non-null, becomes the app's URL scheme; when null
/// the `CFBundleURLTypes` key is omitted.
///
/// Deviation from the task spec: the function takes `io: std.Io` and
/// `base_dir: std.Io.Dir` rather than `output_dir: []const u8`, to match the
/// rest of the `package.zig` API and to keep the test self-contained
/// (so it can use `std.testing.tmpDir`).
pub fn createIosFullApp(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_dir: std.Io.Dir,
    app_name: []const u8,
    app_id: []const u8,
    app_version: []const u8,
    icon_path: ?[]const u8,
    deep_link_scheme: ?[]const u8,
) !void {
    _ = icon_path;

    const entitlements_name = try std.fmt.allocPrint(allocator, "{s}.entitlements", .{app_name});
    defer allocator.free(entitlements_name);

    const xcodeproj_subpath = try std.fmt.allocPrint(allocator, "{s}/{s}.xcodeproj", .{ app_name, app_name });
    defer allocator.free(xcodeproj_subpath);
    const assets_subpath = try std.fmt.allocPrint(allocator, "{s}/Assets.xcassets", .{app_name});
    defer allocator.free(assets_subpath);
    const icon_subpath = try std.fmt.allocPrint(allocator, "{s}/Assets.xcassets/AppIcon.appiconset", .{app_name});
    defer allocator.free(icon_subpath);

    try base_dir.createDirPath(io, app_name);
    try base_dir.createDirPath(io, xcodeproj_subpath);
    try base_dir.createDirPath(io, assets_subpath);
    try base_dir.createDirPath(io, icon_subpath);

    var app_dir = try base_dir.openDir(io, app_name, .{});
    defer app_dir.close(io);

    var xcodeproj_dir = try base_dir.openDir(io, xcodeproj_subpath, .{});
    defer xcodeproj_dir.close(io);

    var assets_dir = try base_dir.openDir(io, assets_subpath, .{});
    defer assets_dir.close(io);

    var icon_dir = try base_dir.openDir(io, icon_subpath, .{});
    defer icon_dir.close(io);

    try app_dir.writeFile(io, .{ .sub_path = "AppDelegate.swift", .data = appDelegateSwift() });
    try app_dir.writeFile(io, .{ .sub_path = "SceneDelegate.swift", .data = sceneDelegateSwift() });
    try app_dir.writeFile(io, .{ .sub_path = "ViewController.swift", .data = viewControllerSwift() });
    try app_dir.writeFile(io, .{ .sub_path = "Main.storyboard", .data = mainStoryboard() });
    try app_dir.writeFile(io, .{ .sub_path = "LaunchScreen.storyboard", .data = launchScreenStoryboard() });
    try app_dir.writeFile(io, .{ .sub_path = entitlements_name, .data = iosFullEntitlements() });

    const info_plist = try iosFullInfoPlist(allocator, app_name, app_id, app_version, deep_link_scheme);
    defer allocator.free(info_plist);
    try app_dir.writeFile(io, .{ .sub_path = "Info.plist", .data = info_plist });

    const bridging_header = try iosFullBridgingHeader(allocator, app_name);
    defer allocator.free(bridging_header);
    try app_dir.writeFile(io, .{ .sub_path = "Bridging-Header.h", .data = bridging_header });

    try assets_dir.writeFile(io, .{ .sub_path = "Contents.json", .data = assetsContentsJson() });
    try icon_dir.writeFile(io, .{ .sub_path = "Contents.json", .data = iconContentsJson() });

    const pbxproj = try generatePbxproj(allocator, app_name, app_id);
    defer allocator.free(pbxproj);
    try xcodeproj_dir.writeFile(io, .{ .sub_path = "project.pbxproj", .data = pbxproj });

    const readme = try iosFullReadme(allocator, app_name);
    defer allocator.free(readme);
    try base_dir.writeFile(io, .{ .sub_path = "README.md", .data = readme });
}

pub fn createAndroidSkeleton(io: std.Io, output_path: []const u8) !PackageStats {
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, output_path);
    var dir = try cwd.openDir(io, output_path, .{});
    defer dir.close(io);
    try dir.createDirPath(io, "app/src/main/java/dev/zero_native");
    try dir.createDirPath(io, "app/src/main/cpp");
    try writeFile(dir, io, "README.md", androidReadme());
    try writeFile(dir, io, "settings.gradle", "pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }\ndependencyResolutionManagement { repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS); repositories { google(); mavenCentral() } }\nrootProject.name = 'zero-nativeHost'\ninclude ':app'\n");
    try writeFile(dir, io, "app/build.gradle", "plugins { id 'com.android.application' version '8.5.0' }\n\nandroid { namespace 'dev.zero_native'; compileSdk 35\n    defaultConfig { applicationId 'dev.zero_native'; minSdk 26; targetSdk 35; versionCode 1; versionName '0.1.0' }\n}\n");
    try writeFile(dir, io, "app/src/main/AndroidManifest.xml", androidManifest());
    try writeFile(dir, io, "app/src/main/java/dev/zero_native/MainActivity.kt", androidActivity());
    try writeFile(dir, io, "app/src/main/cpp/zero_native_jni.c", androidJni());
    try writeFile(dir, io, "app/src/main/cpp/zero_native.h", embedHeader());
    return .{ .path = output_path, .target = .android };
}

/// Generate a complete, buildable Gradle project for the `--full` Android app
/// template under `<output_dir>/<app_name>/`. The project is self-contained
/// except for `gradle-wrapper.jar` (a 0-byte placeholder) and `gradlew` /
/// `gradlew.bat` (4-line stubs); the user is expected to run
/// `gradle wrapper` once inside the generated project to populate them.
pub fn createAndroidFullApp(
    allocator: std.mem.Allocator,
    io: std.Io,
    output_dir: []const u8,
    app_name: []const u8,
    app_id: []const u8,
    app_version: []const u8,
    deep_link_scheme: ?[]const u8,
) !void {
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, output_dir);
    const project_root = try std.fs.path.join(allocator, &.{ output_dir, app_name });
    defer allocator.free(project_root);
    try cwd.createDirPath(io, project_root);
    var dir = try cwd.openDir(io, project_root, .{});
    defer dir.close(io);

    // Translate the dotted application id into a package directory by
    // replacing each '.' with a path separator. e.g. "com.example.demo"
    // becomes "app/src/main/java/com/example/demo".
    var pkg_buf = std.ArrayList(u8).empty;
    defer pkg_buf.deinit(allocator);
    try pkg_buf.appendSlice(allocator, "app/src/main/java/");
    {
        var seg_start: usize = 0;
        for (app_id, 0..) |ch, i| {
            if (ch == '.') {
                try pkg_buf.appendSlice(allocator, app_id[seg_start..i]);
                try pkg_buf.append(allocator, '/');
                seg_start = i + 1;
            }
        }
        try pkg_buf.appendSlice(allocator, app_id[seg_start..]);
    }
    const java_pkg_path = try pkg_buf.toOwnedSlice(allocator);
    defer allocator.free(java_pkg_path);

    try dir.createDirPath(io, "gradle/wrapper");
    try dir.createDirPath(io, "app/src/main/cpp");
    try dir.createDirPath(io, java_pkg_path);
    try dir.createDirPath(io, "app/src/main/res/values");
    try dir.createDirPath(io, "app/src/main/res/mipmap-anydpi-v26");
    try dir.createDirPath(io, "app/src/main/res/drawable");

    {
        const data = try androidFullSettingsGradle(allocator, app_name);
        defer allocator.free(data);
        try writeFile(dir, io, "settings.gradle", data);
    }
    try writeFile(dir, io, "build.gradle", androidFullRootBuildGradle());
    try writeFile(dir, io, "gradle.properties", androidFullGradleProperties());
    try writeFile(dir, io, "gradle/wrapper/gradle-wrapper.properties", androidFullGradleWrapperProperties());
    try writeFile(dir, io, "gradle/wrapper/gradle-wrapper.jar", "");
    try writeFile(dir, io, "gradlew", androidFullGradlewStub());
    try writeFile(dir, io, "gradlew.bat", androidFullGradlewBatStub());
    {
        const data = try androidFullAppBuildGradle(allocator, app_id, app_version);
        defer allocator.free(data);
        try writeFile(dir, io, "app/build.gradle", data);
    }
    try writeFile(dir, io, "app/proguard-rules.pro", "");

    {
        const data = try androidFullManifest(allocator, app_name, deep_link_scheme);
        defer allocator.free(data);
        try writeFile(dir, io, "app/src/main/AndroidManifest.xml", data);
    }

    const activity_kt_path = try std.fs.path.join(allocator, &.{ java_pkg_path, "MainActivity.kt" });
    defer allocator.free(activity_kt_path);
    {
        const data = try androidFullActivity(allocator, app_id);
        defer allocator.free(data);
        try writeFile(dir, io, activity_kt_path, data);
    }

    {
        const data = try androidFullCmake(allocator, app_name);
        defer allocator.free(data);
        try writeFile(dir, io, "app/src/main/cpp/CMakeLists.txt", data);
    }
    try writeFile(dir, io, "app/src/main/cpp/zero_native_jni.c", androidFullJni());

    {
        const data = try androidFullStringsXml(allocator, app_name);
        defer allocator.free(data);
        try writeFile(dir, io, "app/src/main/res/values/strings.xml", data);
    }
    {
        const data = try androidFullThemesXml(allocator, app_name);
        defer allocator.free(data);
        try writeFile(dir, io, "app/src/main/res/values/themes.xml", data);
    }
    try writeFile(dir, io, "app/src/main/res/values/colors.xml", androidFullColorsXml());
    try writeFile(dir, io, "app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml", androidFullLauncherIconXml());
    try writeFile(dir, io, "app/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml", androidFullLauncherIconXml());
    try writeFile(dir, io, "app/src/main/res/drawable/ic_launcher_foreground.xml", androidFullLauncherForegroundXml());

    {
        const data = try androidFullReadme(allocator, app_name);
        defer allocator.free(data);
        try writeFile(dir, io, "README.md", data);
    }
}

fn androidFullSettingsGradle(allocator: std.mem.Allocator, app_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\pluginManagement {{
        \\    repositories {{
        \\        google()
        \\        mavenCentral()
        \\        gradlePluginPortal()
        \\    }}
        \\}}
        \\dependencyResolutionManagement {{
        \\    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
        \\    repositories {{
        \\        google()
        \\        mavenCentral()
        \\    }}
        \\}}
        \\rootProject.name = "{s}"
        \\include ':app'
        \\
    , .{app_name});
}

fn androidFullRootBuildGradle() []const u8 {
    return
        \\plugins {
        \\    id 'com.android.application' version '8.1.0' apply false
        \\}
        \\
    ;
}

fn androidFullGradleProperties() []const u8 {
    return
        \\org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8
        \\android.useAndroidX=true
        \\android.nonTransitiveRClass=true
        \\
    ;
}

fn androidFullGradleWrapperProperties() []const u8 {
    return
        \\distributionBase=GRADLE_USER_HOME
        \\distributionPath=wrapper/dists
        \\zipStoreBase=GRADLE_USER_HOME
        \\zipStorePath=wrapper/dists
        \\distributionUrl=https\://services.gradle.org/distributions/gradle-8.5-bin.zip
        \\
    ;
}

fn androidFullGradlewStub() []const u8 {
    return
        \\#!/usr/bin/env sh
        \\# Placeholder gradlew stub. Run `gradle wrapper` inside this project to overwrite with the real script.
        \\exit 0
        \\
    ;
}

fn androidFullGradlewBatStub() []const u8 {
    return "@rem Placeholder gradlew.bat stub. Run `gradle wrapper` to overwrite.\r\n@rem Placeholder; do not rely on this stub.\r\nexit /b 0\r\n";
}

fn androidFullAppBuildGradle(allocator: std.mem.Allocator, app_id: []const u8, app_version: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\plugins {{
        \\    id 'com.android.application'
        \\}}
        \\android {{
        \\    namespace '{s}'
        \\    compileSdk 34
        \\    defaultConfig {{
        \\        applicationId '{s}'
        \\        minSdk 23
        \\        targetSdk 34
        \\        versionCode 1
        \\        versionName '{s}'
        \\    }}
        \\    buildTypes {{
        \\        release {{
        \\            minifyEnabled true
        \\            proguardFiles getDefaultProguardFile('proguard-android-optimize.txt'), 'proguard-rules.pro'
        \\        }}
        \\    }}
        \\    compileOptions {{
        \\        sourceCompatibility JavaVersion.VERSION_17
        \\        targetCompatibility JavaVersion.VERSION_17
        \\    }}
        \\    externalNativeBuild {{
        \\        cmake {{
        \\            path 'src/main/cpp/CMakeLists.txt'
        \\        }}
        \\    }}
        \\}}
        \\dependencies {{
        \\    implementation 'androidx.appcompat:appcompat:1.6.1'
        \\    implementation 'androidx.core:core-ktx:1.12.0'
        \\}}
        \\
    , .{ app_id, app_id, app_version });
}

fn androidFullManifest(allocator: std.mem.Allocator, app_name: []const u8, deep_link_scheme: ?[]const u8) ![]const u8 {
    if (deep_link_scheme) |scheme| {
        return std.fmt.allocPrint(allocator,
            \\<?xml version="1.0" encoding="utf-8"?>
            \\<manifest xmlns:android="http://schemas.android.com/apk/res/android">
            \\    <uses-permission android:name="android.permission.INTERNET" />
            \\    <application
            \\        android:label="@string/app_name"
            \\        android:icon="@mipmap/ic_launcher"
            \\        android:roundIcon="@mipmap/ic_launcher_round"
            \\        android:theme="@style/Theme.{s}">
            \\        <activity
            \\            android:name=".MainActivity"
            \\            android:exported="true">
            \\            <intent-filter>
            \\                <action android:name="android.intent.action.MAIN" />
            \\                <category android:name="android.intent.category.LAUNCHER" />
            \\            </intent-filter>
            \\            <intent-filter android:autoVerify="false">
            \\                <action android:name="android.intent.action.VIEW" />
            \\                <category android:name="android.intent.category.DEFAULT" />
            \\                <category android:name="android.intent.category.BROWSABLE" />
            \\                <data android:scheme="{s}" />
            \\            </intent-filter>
            \\        </activity>
            \\    </application>
            \\</manifest>
            \\
        , .{ app_name, scheme });
    }
    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<manifest xmlns:android="http://schemas.android.com/apk/res/android">
        \\    <uses-permission android:name="android.permission.INTERNET" />
        \\    <application
        \\        android:label="@string/app_name"
        \\        android:icon="@mipmap/ic_launcher"
        \\        android:roundIcon="@mipmap/ic_launcher_round"
        \\        android:theme="@style/Theme.{s}">
        \\        <activity
        \\            android:name=".MainActivity"
        \\            android:exported="true">
        \\            <intent-filter>
        \\                <action android:name="android.intent.action.MAIN" />
        \\                <category android:name="android.intent.category.LAUNCHER" />
        \\            </intent-filter>
        \\        </activity>
        \\    </application>
        \\</manifest>
        \\
    , .{app_name});
}

fn androidFullActivity(allocator: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\package {s}
        \\
        \\import android.os.Bundle
        \\import androidx.appcompat.app.AppCompatActivity
        \\import android.webkit.WebView
        \\
        \\class MainActivity : AppCompatActivity() {{
        \\    override fun onCreate(savedInstanceState: Bundle?) {{
        \\        super.onCreate(savedInstanceState)
        \\        val webView = WebView(this)
        \\        webView.settings.javaScriptEnabled = true
        \\        setContentView(webView)
        \\        webView.loadUrl("http://127.0.0.1:5173")
        \\    }}
        \\}}
        \\
    , .{app_id});
}

fn androidFullCmake(allocator: std.mem.Allocator, app_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\cmake_minimum_required(VERSION 3.22.1)
        \\
        \\project({s} C)
        \\
        \\add_library({s} SHARED zero_native_jni.c)
        \\
    , .{ app_name, app_name });
}

fn androidFullJni() []const u8 {
    return
        \\#include <jni.h>
        \\
        \\JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
        \\    (void)vm;
        \\    (void)reserved;
        \\    return JNI_VERSION_1_6;
        \\}
        \\
    ;
}

fn androidFullStringsXml(allocator: std.mem.Allocator, app_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<resources>
        \\    <string name="app_name">{s}</string>
        \\</resources>
        \\
    , .{app_name});
}

fn androidFullThemesXml(allocator: std.mem.Allocator, app_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<resources>
        \\    <style name="Theme.{s}" parent="Theme.AppCompat.DayNight.NoActionBar" />
        \\</resources>
        \\
    , .{app_name});
}

fn androidFullColorsXml() []const u8 {
    return
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<resources>
        \\    <color name="ic_launcher_background">#FFFFFF</color>
        \\</resources>
        \\
    ;
}

fn androidFullLauncherIconXml() []const u8 {
    return
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
        \\    <background android:drawable="@color/ic_launcher_background" />
        \\    <foreground android:drawable="@drawable/ic_launcher_foreground" />
        \\</adaptive-icon>
        \\
    ;
}

fn androidFullLauncherForegroundXml() []const u8 {
    return
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<vector xmlns:android="http://schemas.android.com/apk/res/android"
        \\    android:width="108dp"
        \\    android:height="108dp"
        \\    android:viewportWidth="108"
        \\    android:viewportHeight="108">
        \\    <path
        \\        android:fillColor="#000000"
        \\        android:pathData="M0,0h108v108h-108z" />
        \\</vector>
        \\
    ;
}

fn androidFullReadme(allocator: std.mem.Allocator, app_name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\# {s}
        \\
        \\Android --full app generated by zero-native.
        \\
        \\## Build
        \\
        \\```
        \\cd {s}
        \\./gradlew assembleDebug
        \\```
        \\
        \\Output: `app/build/outputs/apk/debug/app-debug.apk`.
        \\
        \\## Release
        \\
        \\Configure `signingConfigs.release` (keystore, alias, passwords) in
        \\`app/build.gradle`, then run `./gradlew assembleRelease`. This
        \\template does not ship a keystore.
        \\
    , .{ app_name, app_name });
}

fn createDesktopArtifact(allocator: std.mem.Allocator, io: std.Io, options: PackageOptions) !PackageStats {
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, options.output_path);
    var dir = try cwd.openDir(io, options.output_path, .{});
    defer dir.close(io);
    try dir.createDirPath(io, "bin");
    try dir.createDirPath(io, "resources");

    const executable_name = if (options.target == .windows)
        try std.fmt.allocPrint(allocator, "{s}.exe", .{options.metadata.name})
    else
        try allocator.dupe(u8, options.metadata.name);
    defer allocator.free(executable_name);

    if (options.binary_path) |binary_path| {
        const binary_subpath = try std.fmt.allocPrint(allocator, "bin/{s}", .{executable_name});
        defer allocator.free(binary_subpath);
        try copyFileToDir(allocator, io, dir, binary_path, binary_subpath);
    } else {
        try writeFile(dir, io, "bin/README.txt", "Build the app binary separately and place it here for this target.\n");
    }

    const assets_output = try assetOutputPath(allocator, options.output_path, "resources", options);
    defer allocator.free(assets_output);
    const bundle_stats = try assets_tool.bundle(allocator, io, options.assets_dir, assets_output);
    try writeFile(dir, io, "README.txt", artifactReadme(options.target));
    if (options.target == .linux) {
        try dir.createDirPath(io, "share/applications");
        try dir.createDirPath(io, "share/icons");
        const desktop_entry = try linuxDesktopEntry(allocator, options.metadata);
        defer allocator.free(desktop_entry);
        const desktop_path = try std.fmt.allocPrint(allocator, "share/applications/{s}.desktop", .{options.metadata.name});
        defer allocator.free(desktop_path);
        try writeFile(dir, io, desktop_path, desktop_entry);
        if (options.metadata.icons.len > 0) {
            copyFileToDir(allocator, io, dir, options.metadata.icons[0], "share/icons/app-icon.png") catch |err| {
                std.log.warn("package.linux_icon_copy_failed: icon={s} error={s}", .{ options.metadata.icons[0], @errorName(err) });
            };
        }
    }
    if (options.web_engine == .chromium) {
        const cef_platform = cefPlatformForTarget(options.target) orelse return error.UnsupportedWebEngine;
        try cef.ensureLayoutFor(io, cef_platform, options.cef_dir);
        try copyDesktopCefRuntime(allocator, io, dir, options.target, options.cef_dir);
    }
    try writeReport(allocator, dir, io, "package-manifest.zon", options, executable_name, bundle_stats.asset_count);
    return .{ .path = options.output_path, .artifact_name = std.fs.path.basename(options.output_path), .target = options.target, .asset_count = bundle_stats.asset_count, .web_engine = options.web_engine };
}

fn createIosArtifact(allocator: std.mem.Allocator, io: std.Io, options: PackageOptions) !PackageStats {
    _ = try createIosSkeleton(io, options.output_path);
    var dir = try std.Io.Dir.cwd().openDir(io, options.output_path, .{});
    defer dir.close(io);
    try dir.createDirPath(io, "Libraries");
    if (options.binary_path) |binary_path| try copyFileToDir(allocator, io, dir, binary_path, "Libraries/libzero-native.a");
    try writeReport(allocator, dir, io, "package-manifest.zon", options, "libzero-native.a", 0);
    return .{ .path = options.output_path, .artifact_name = std.fs.path.basename(options.output_path), .target = .ios, .web_engine = options.web_engine };
}

fn createAndroidArtifact(allocator: std.mem.Allocator, io: std.Io, options: PackageOptions) !PackageStats {
    _ = try createAndroidSkeleton(io, options.output_path);
    var dir = try std.Io.Dir.cwd().openDir(io, options.output_path, .{});
    defer dir.close(io);
    try dir.createDirPath(io, "app/src/main/cpp/lib");
    if (options.binary_path) |binary_path| try copyFileToDir(allocator, io, dir, binary_path, "app/src/main/cpp/lib/libzero-native.a");
    try writeReport(allocator, dir, io, "package-manifest.zon", options, "libzero-native.a", 0);
    return .{ .path = options.output_path, .artifact_name = std.fs.path.basename(options.output_path), .target = .android, .web_engine = options.web_engine };
}

fn writeFile(dir: std.Io.Dir, io: std.Io, path: []const u8, bytes: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn assetOutputPath(allocator: std.mem.Allocator, output_path: []const u8, resources_subpath: []const u8, options: PackageOptions) ![]const u8 {
    if (options.frontend) |frontend| {
        return std.fs.path.join(allocator, &.{ output_path, resources_subpath, frontend.dist });
    }
    return std.fs.path.join(allocator, &.{ output_path, resources_subpath });
}

fn macosInfoPlist(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata, executable_name: []const u8) ![]const u8 {
    const icon_name = macosIconFile(metadata);
    const bundle_id = try xmlEscapeAlloc(allocator, metadata.id);
    defer allocator.free(bundle_id);
    const name = try xmlEscapeAlloc(allocator, metadata.name);
    defer allocator.free(name);
    const display_name = try xmlEscapeAlloc(allocator, metadata.displayName());
    defer allocator.free(display_name);
    const executable = try xmlEscapeAlloc(allocator, executable_name);
    defer allocator.free(executable);
    const icon = try xmlEscapeAlloc(allocator, icon_name);
    defer allocator.free(icon);
    const version = try xmlEscapeAlloc(allocator, metadata.version);
    defer allocator.free(version);

    var buf = std.ArrayList(u8).empty;
    try buf.appendSlice(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleIdentifier</key>
        \\
    );
    try buf.appendSlice(allocator, "  <string>");
    try buf.appendSlice(allocator, bundle_id);
    try buf.appendSlice(allocator, "</string>\n");

    try buf.appendSlice(allocator, "  <key>CFBundleName</key>\n  <string>");
    try buf.appendSlice(allocator, name);
    try buf.appendSlice(allocator, "</string>\n");

    try buf.appendSlice(allocator, "  <key>CFBundleDisplayName</key>\n  <string>");
    try buf.appendSlice(allocator, display_name);
    try buf.appendSlice(allocator, "</string>\n");

    try buf.appendSlice(allocator, "  <key>CFBundleExecutable</key>\n  <string>");
    try buf.appendSlice(allocator, executable);
    try buf.appendSlice(allocator, "</string>\n");

    try buf.appendSlice(allocator, "  <key>CFBundleIconFile</key>\n  <string>");
    try buf.appendSlice(allocator, icon);
    try buf.appendSlice(allocator, "</string>\n");

    try buf.appendSlice(allocator,
        \\  <key>CFBundlePackageType</key>
        \\  <string>APPL</string>
        \\  <key>LSMinimumSystemVersion</key>
        \\  <string>11.0</string>
        \\  <key>CFBundleShortVersionString</key>
        \\
    );
    try buf.appendSlice(allocator, "  <string>");
    try buf.appendSlice(allocator, version);
    try buf.appendSlice(allocator, "</string>\n");

    try buf.appendSlice(allocator, "  <key>CFBundleVersion</key>\n  <string>");
    try buf.appendSlice(allocator, version);
    try buf.appendSlice(allocator, "</string>\n");

    // URL types for deep-link schemes
    if (metadata.deep_link_schemes.len > 0) {
        try buf.appendSlice(allocator,
            \\  <key>CFBundleURLTypes</key>
            \\  <array>
            \\    <dict>
            \\      <key>CFBundleURLName</key>
            \\
        );
        try buf.appendSlice(allocator, "      <string>");
        try buf.appendSlice(allocator, bundle_id);
        try buf.appendSlice(allocator, "</string>\n");

        try buf.appendSlice(allocator, "      <key>CFBundleURLSchemes</key>\n      <array>\n");
        for (metadata.deep_link_schemes) |scheme| {
            const escaped = try xmlEscapeAlloc(allocator, scheme);
            defer allocator.free(escaped);
            try buf.appendSlice(allocator, "        <string>");
            try buf.appendSlice(allocator, escaped);
            try buf.appendSlice(allocator, "</string>\n");
        }
        try buf.appendSlice(allocator, "      </array>\n    </dict>\n  </array>\n");
    }

    try buf.appendSlice(allocator, "</dict>\n</plist>\n");
    return buf.toOwnedSlice(allocator);
}

fn embedHeader() []const u8 {
    return
    \\#pragma once
    \\#include <stdint.h>
    \\#include <stddef.h>
    \\void *zero_native_app_create(void);
    \\void zero_native_app_destroy(void *app);
    \\void zero_native_app_start(void *app);
    \\void zero_native_app_stop(void *app);
    \\void zero_native_app_resize(void *app, float width, float height, float scale, void *surface);
    \\void zero_native_app_touch(void *app, uint64_t id, int phase, float x, float y, float pressure);
    \\void zero_native_app_frame(void *app);
    \\void zero_native_app_set_asset_root(void *app, const char *path, uintptr_t len);
    \\uintptr_t zero_native_app_last_command_count(void *app);
    \\
    ;
}

fn iosReadme() []const u8 {
    return "iOS zero-native host skeleton. Link libzero-native.a and call the functions in zero-nativeHost/zero_native.h from the view controller.\n";
}

fn iosInfoPlist() []const u8 {
    return
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.zero_native.ios</string><key>CFBundleName</key><string>zero-nativeHost</string></dict></plist>
    \\
    ;
}

fn iosViewController() []const u8 {
    return
    \\import UIKit
    \\import WebKit
    \\
    \\final class ZeroNativeHostViewController: UIViewController {
    \\    private let webView = WKWebView(frame: .zero)
    \\    override func viewDidLoad() {
    \\        super.viewDidLoad()
    \\        webView.frame = view.bounds
    \\        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    \\        view.addSubview(webView)
    \\    }
    \\}
    \\
    ;
}

fn appDelegateSwift() []const u8 {
    return
    \\import UIKit
    \\
    \\@main
    \\final class AppDelegate: UIResponder, UIApplicationDelegate {
    \\
    \\    func application(_ application: UIApplication,
    \\                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    \\        return true
    \\    }
    \\
    \\    func application(_ application: UIApplication,
    \\                     configurationForConnecting connectingSceneSession: UISceneSession,
    \\                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
    \\        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    \\    }
    \\}
    \\
    ;
}

fn sceneDelegateSwift() []const u8 {
    return
    \\import UIKit
    \\
    \\final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    \\
    \\    var window: UIWindow?
    \\
    \\    func scene(_ scene: UIScene,
    \\               willConnectTo session: UISceneSession,
    \\               options connectionOptions: UIScene.ConnectionOptions) {
    \\        guard let windowScene = scene as? UIWindowScene else { return }
    \\        let window = UIWindow(windowScene: windowScene)
    \\        window.rootViewController = ViewController()
    \\        window.makeKeyAndVisible()
    \\        self.window = window
    \\    }
    \\}
    \\
    ;
}

fn viewControllerSwift() []const u8 {
    return
    \\import UIKit
    \\import WebKit
    \\
    \\final class ViewController: UIViewController {
    \\
    \\    private let webView = WKWebView(frame: .zero)
    \\
    \\    // The local dev server URL the app loads on launch. Override at build
    \\    // time by editing this constant or by changing Info.plist to inject
    \\    // a different origin via the bridge.
    \\    private static let WEBVIEW_URL = URL(string: "http://127.0.0.1:5173")!
    \\
    \\    override func viewDidLoad() {
    \\        super.viewDidLoad()
    \\        view.backgroundColor = .systemBackground
    \\        webView.frame = view.bounds
    \\        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    \\        view.addSubview(webView)
    \\        webView.load(URLRequest(url: ViewController.WEBVIEW_URL))
    \\    }
    \\}
    \\
    ;
}

fn mainStoryboard() []const u8 {
    return
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<document type="com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB" version="3.0" toolsVersion="22154" targetRuntime="iOS.CocoaTouch" propertyAccessControl="none" useAutolayout="YES" useTraitCollections="YES" useSafeAreas="YES" colorMatched="YES" initialViewController="launch-screen-id">
    \\    <device id="retina6_1" orientation="portrait" appearance="light"/>
    \\    <dependencies>
    \\        <plugIn identifier="com.apple.InterfaceBuilder.IBCocoaTouchPlugin" version="22131"/>
    \\        <capability name="Safe area layout guides" minToolsVersion="9.0"/>
    \\        <capability name="documents saved in the Xcode 8 format" minToolsVersion="8.0"/>
    \\    </dependencies>
    \\    <scenes>
    \\        <scene sceneID="launch-scene-id">
    \\            <objects>
    \\                <viewController id="launch-screen-id" sceneMemberID="viewController">
    \\                    <view key="view" contentMode="scaleToFill" id="launch-screen-view-id">
    \\                        <rect key="frame" x="0.0" y="0.0" width="375" height="667"/>
    \\                        <autoresizingMask key="autoresizingMask" widthSizable="YES" heightSizable="YES"/>
    \\                        <color key="backgroundColor" systemColor="systemBackgroundColor"/>
    \\                        <viewLayoutGuide key="safeArea" id="launch-screen-safe-area-id"/>
    \\                    </view>
    \\                </viewController>
    \\                <placeholder placeholderIdentifier="IBFirstResponder" id="launch-screen-fr-id" userLabel="First Responder" sceneMemberID="firstResponder"/>
    \\            </objects>
    \\            <point key="canvasLocation" x="53" y="375"/>
    \\        </scene>
    \\    </scenes>
    \\</document>
    \\
    ;
}

fn launchScreenStoryboard() []const u8 {
    return
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<document type="com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB" version="3.0" toolsVersion="22154" targetRuntime="iOS.CocoaTouch" propertyAccessControl="none" useAutolayout="YES" useTraitCollections="YES" useSafeAreas="YES" colorMatched="YES" launchScreen="YES" useLaunchScreenStoryboard="YES">
    \\    <device id="retina6_1" orientation="portrait" appearance="light"/>
    \\    <dependencies>
    \\        <plugIn identifier="com.apple.InterfaceBuilder.IBCocoaTouchPlugin" version="22131"/>
    \\        <capability name="Safe area layout guides" minToolsVersion="9.0"/>
    \\        <capability name="documents saved in the Xcode 8 format" minToolsVersion="8.0"/>
    \\    </dependencies>
    \\    <scenes>
    \\        <scene sceneID="EHf-IW-A2E">
    \\            <objects>
    \\                <viewController id="01J-lp-oVM" sceneMemberID="viewController">
    \\                    <view key="view" contentMode="scaleToFill" id="Ze5-6b-2t3">
    \\                        <rect key="frame" x="0.0" y="0.0" width="375" height="667"/>
    \\                        <autoresizingMask key="autoresizingMask" widthSizable="YES" heightSizable="YES"/>
    \\                        <color key="backgroundColor" systemColor="systemBackgroundColor"/>
    \\                        <viewLayoutGuide key="safeArea" id="6Tk-OE-BBY"/>
    \\                    </view>
    \\                </viewController>
    \\                <placeholder placeholderIdentifier="IBFirstResponder" id="iYj-Kq-Ea1" userLabel="First Responder" sceneMemberID="firstResponder"/>
    \\            </objects>
    \\            <point key="canvasLocation" x="53" y="375"/>
    \\        </scene>
    \\    </scenes>
    \\</document>
    \\
    ;
}

fn iosFullEntitlements() []const u8 {
    return
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0">
    \\<dict>
    \\</dict>
    \\</plist>
    \\
    ;
}

fn iosFullBridgingHeader(allocator: std.mem.Allocator, app_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "#import \"{s}.h\"\n", .{app_name});
}

fn assetsContentsJson() []const u8 {
    return "{\"info\":{\"author\":\"xcode\",\"version\":1}}\n";
}

fn iconContentsJson() []const u8 {
    return "{\"images\":[{\"idiom\":\"universal\",\"platform\":\"ios\",\"size\":\"1024x1024\"}],\"info\":{\"author\":\"xcode\",\"version\":1}}\n";
}

fn iosFullReadme(allocator: std.mem.Allocator, app_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\# {s} (zero-native iOS full template)
        \\
        \\A complete, buildable iOS Xcode project generated by `zero-native` with
        \\a UIKit + WKWebView host. The app loads `WEBVIEW_URL` from
        \\`ViewController.swift` and is wired up via the scene-based lifecycle
        \\(`AppDelegate` + `SceneDelegate`).
        \\
        \\## Build
        \\
        \\```sh
        \\cd {s}
        \\open {s}.xcodeproj
        \\```
        \\
        \\In Xcode, open **Signing & Capabilities** for the `{s}` target and set
        \\your **Team** (the generated project ships with `DEVELOPMENT_TEAM = ""`
        \\and `CODE_SIGN_STYLE = Automatic`). Pick a real device or an iOS
        \\Simulator destination and press **Run**.
        \\
        \\## Project layout
        \\
        \\```
        \\{s}/
        \\  AppDelegate.swift
        \\  SceneDelegate.swift
        \\  ViewController.swift
        \\  Main.storyboard          # placeholder; the runtime entry point is SceneDelegate
        \\  LaunchScreen.storyboard
        \\  Info.plist
        \\  {s}.entitlements         # empty; add capabilities (e.g. Associated Domains) as needed
        \\  Bridging-Header.h        # exposes the zero-native C ABI to Swift
        \\  Assets.xcassets/
        \\    Contents.json
        \\    AppIcon.appiconset/
        \\      Contents.json        # placeholder; drop a 1024x1024 PNG named AppIcon.png here
        \\{s}.xcodeproj/
        \\  project.pbxproj
        \\```
        \\
    , .{ app_name, app_name, app_name, app_name, app_name, app_name, app_name });
}

fn iosFullInfoPlist(
    allocator: std.mem.Allocator,
    app_name: []const u8,
    app_id: []const u8,
    app_version: []const u8,
    deep_link_scheme: ?[]const u8,
) ![]u8 {
    const url_types_block = if (deep_link_scheme) |scheme| blk: {
        const xml_scheme = try xmlEscapeAlloc(allocator, scheme);
        defer allocator.free(xml_scheme);
        const xml_app_id = try xmlEscapeAlloc(allocator, app_id);
        defer allocator.free(xml_app_id);
        break :blk try std.fmt.allocPrint(allocator,
            \\  <key>CFBundleURLTypes</key>
            \\  <array>
            \\    <dict>
            \\      <key>CFBundleURLName</key>
            \\      <string>{s}</string>
            \\      <key>CFBundleURLSchemes</key>
            \\      <array>
            \\        <string>{s}</string>
            \\      </array>
            \\    </dict>
            \\  </array>
            \\
        , .{ xml_app_id, xml_scheme });
    } else "";
    defer if (deep_link_scheme != null) allocator.free(url_types_block);

    const xml_name = try xmlEscapeAlloc(allocator, app_name);
    defer allocator.free(xml_name);
    const xml_version = try xmlEscapeAlloc(allocator, app_version);
    defer allocator.free(xml_version);

    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleDevelopmentRegion</key>
        \\  <string>en</string>
        \\  <key>CFBundleDisplayName</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleExecutable</key>
        \\  <string>$(EXECUTABLE_NAME)</string>
        \\  <key>CFBundleIdentifier</key>
        \\  <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
        \\  <key>CFBundleInfoDictionaryVersion</key>
        \\  <string>6.0</string>
        \\  <key>CFBundleName</key>
        \\  <string>$(PRODUCT_NAME)</string>
        \\  <key>CFBundlePackageType</key>
        \\  <string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
        \\  <key>CFBundleShortVersionString</key>
        \\  <string>{s}</string>
        \\  <key>CFBundleVersion</key>
        \\  <string>1</string>
        \\  <key>LSRequiresIPhoneOS</key>
        \\  <true/>
        \\  <key>UILaunchStoryboardName</key>
        \\  <string>LaunchScreen</string>
        \\  <key>UIRequiredDeviceCapabilities</key>
        \\  <array>
        \\    <string>armv7</string>
        \\  </array>
        \\  <key>UISupportedInterfaceOrientations</key>
        \\  <array>
        \\    <string>UIInterfaceOrientationPortrait</string>
        \\    <string>UIInterfaceOrientationLandscapeLeft</string>
        \\    <string>UIInterfaceOrientationLandscapeRight</string>
        \\  </array>
        \\  <key>UISupportedInterfaceOrientations~ipad</key>
        \\  <array>
        \\    <string>UIInterfaceOrientationPortrait</string>
        \\    <string>UIInterfaceOrientationPortraitUpsideDown</string>
        \\    <string>UIInterfaceOrientationLandscapeLeft</string>
        \\    <string>UIInterfaceOrientationLandscapeRight</string>
        \\  </array>
        \\  <key>UIApplicationSceneManifest</key>
        \\  <dict>
        \\    <key>UIApplicationSupportsMultipleScenes</key>
        \\    <false/>
        \\    <key>UISceneConfigurations</key>
        \\    <dict>
        \\      <key>UIWindowSceneSessionRoleApplication</key>
        \\      <array>
        \\        <dict>
        \\          <key>UISceneConfigurationName</key>
        \\          <string>Default Configuration</string>
        \\          <key>UISceneDelegateClassName</key>
        \\          <string>$(PRODUCT_MODULE_NAME).SceneDelegate</string>
        \\        </dict>
        \\      </array>
        \\    </dict>
        \\  </dict>
        \\  <key>NSAppTransportSecurity</key>
        \\  <dict>
        \\    <key>NSAllowsLocalNetworking</key>
        \\    <true/>
        \\    <key>NSExceptionDomains</key>
        \\    <dict>
        \\      <key>localhost</key>
        \\      <dict>
        \\        <key>NSExceptionAllowsInsecureHTTPLoads</key>
        \\        <true/>
        \\        <key>NSIncludesSubdomains</key>
        \\        <true/>
        \\      </dict>
        \\    </dict>
        \\  </dict>
        \\{s}</dict>
        \\</plist>
        \\
    , .{ xml_name, xml_version, url_types_block });
}

fn androidReadme() []const u8 {
    return "Android zero-native host skeleton. Copy libzero-native.a into the NDK build and wire the JNI bridge in app/src/main/cpp.\n";
}

fn androidManifest() []const u8 {
    return "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\"><application android:theme=\"@style/AppTheme\"><activity android:name=\".MainActivity\" android:exported=\"true\"><intent-filter><action android:name=\"android.intent.action.MAIN\"/><category android:name=\"android.intent.category.LAUNCHER\"/></intent-filter></activity></application></manifest>\n";
}

fn androidActivity() []const u8 {
    return
    \\package dev.zero_native
    \\
    \\import android.app.Activity
    \\import android.os.Bundle
    \\import android.view.MotionEvent
    \\import android.view.SurfaceHolder
    \\import android.view.SurfaceView
    \\
    \\class MainActivity : Activity(), SurfaceHolder.Callback {
    \\    private var app: Long = 0
    \\    override fun onCreate(savedInstanceState: Bundle?) {
    \\        super.onCreate(savedInstanceState)
    \\        val surface = SurfaceView(this)
    \\        surface.holder.addCallback(this)
    \\        setContentView(surface)
    \\        app = nativeCreate()
    \\        nativeStart(app)
    \\    }
    \\    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) { nativeResize(app, width.toFloat(), height.toFloat(), 1f, holder.surface) }
    \\    override fun surfaceCreated(holder: SurfaceHolder) {}
    \\    override fun surfaceDestroyed(holder: SurfaceHolder) { nativeStop(app) }
    \\    override fun onTouchEvent(event: MotionEvent): Boolean {
    \\        nativeTouch(app, event.getPointerId(0).toLong(), event.actionMasked, event.x, event.y, event.pressure)
    \\        nativeFrame(app)
    \\        return true
    \\    }
    \\    external fun nativeCreate(): Long
    \\    external fun nativeStart(app: Long)
    \\    external fun nativeStop(app: Long)
    \\    external fun nativeResize(app: Long, width: Float, height: Float, scale: Float, surface: Any)
    \\    external fun nativeTouch(app: Long, id: Long, phase: Int, x: Float, y: Float, pressure: Float)
    \\    external fun nativeFrame(app: Long)
    \\}
    \\
    ;
}

fn androidJni() []const u8 {
    return
    \\#include <jni.h>
    \\#include "zero_native.h"
    \\JNIEXPORT jlong JNICALL Java_dev_zero_1native_MainActivity_nativeCreate(JNIEnv *env, jobject self) { (void)env; (void)self; return (jlong)zero_native_app_create(); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeStart(JNIEnv *env, jobject self, jlong app) { (void)env; (void)self; zero_native_app_start((void*)app); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeStop(JNIEnv *env, jobject self, jlong app) { (void)env; (void)self; zero_native_app_stop((void*)app); zero_native_app_destroy((void*)app); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeResize(JNIEnv *env, jobject self, jlong app, jfloat w, jfloat h, jfloat scale, jobject surface) { (void)env; (void)self; zero_native_app_resize((void*)app, w, h, scale, surface); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeTouch(JNIEnv *env, jobject self, jlong app, jlong id, jint phase, jfloat x, jfloat y, jfloat pressure) { (void)env; (void)self; zero_native_app_touch((void*)app, (uint64_t)id, phase, x, y, pressure); }
    \\JNIEXPORT void JNICALL Java_dev_zero_1native_MainActivity_nativeFrame(JNIEnv *env, jobject self, jlong app) { (void)env; (void)self; zero_native_app_frame((void*)app); }
    \\
    ;
}

fn artifactSuffix(target: PackageTarget) []const u8 {
    return switch (target) {
        .macos => ".app",
        .windows, .linux, .ios, .android => "",
    };
}

fn artifactReadme(target: PackageTarget) []const u8 {
    return switch (target) {
        .windows => "Windows zero-native artifact directory. Installer generation is future work.\n",
        .linux => "Linux zero-native artifact directory. AppImage, Flatpak, and tarball generation are future work.\n",
        else => "zero-native artifact directory.\n",
    };
}

fn macosIconFile(metadata: manifest_tool.Metadata) []const u8 {
    if (metadata.icons.len == 0) return "AppIcon.icns";
    return std.fs.path.basename(metadata.icons[0]);
}

fn copyMacosIcon(allocator: std.mem.Allocator, io: std.Io, package_dir: std.Io.Dir, options: PackageOptions) !void {
    if (options.metadata.icons.len == 0) {
        try writeFile(package_dir, io, "Contents/Resources/AppIcon.icns", "placeholder: replace with a real macOS .icns before distributing\n");
        return;
    }
    const icon_path = options.metadata.icons[0];
    const dest = try std.fmt.allocPrint(allocator, "Contents/Resources/{s}", .{std.fs.path.basename(icon_path)});
    defer allocator.free(dest);
    const icon_bytes = readPath(allocator, io, icon_path) catch |err| switch (err) {
        error.FileNotFound => {
            try writeFile(package_dir, io, dest, "placeholder: configured app icon was not found; replace with a real macOS .icns before distributing\n");
            return;
        },
        else => return err,
    };
    defer allocator.free(icon_bytes);
    if (!isValidIcns(icon_bytes)) {
        std.debug.print("warning: {s} does not appear to be a valid .icns file; replace before distributing\n", .{icon_path});
    }
    try writeFile(package_dir, io, dest, icon_bytes);
}

fn isValidIcns(bytes: []const u8) bool {
    if (bytes.len < 8) return false;
    return std.mem.eql(u8, bytes[0..4], "icns");
}

fn xmlEscapeAlloc(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (value) |ch| {
        switch (ch) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            0...8, 11...12, 14...0x1f => return error.InvalidName,
            else => try out.append(allocator, ch),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn desktopEntryEscapeAlloc(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (value) |ch| {
        switch (ch) {
            0...8, 11...12, 14...0x1f => return error.InvalidName,
            '\n', '\r', '\t' => try out.append(allocator, ' '),
            else => try out.append(allocator, ch),
        }
    }
    return out.toOwnedSlice(allocator);
}

fn zonStringAlloc(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    for (value) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            0...8, 11...12, 14...0x1f => {
                const escaped = try std.fmt.allocPrint(allocator, "\\x{x:0>2}", .{ch});
                defer allocator.free(escaped);
                try out.appendSlice(allocator, escaped);
            },
            else => try out.append(allocator, ch),
        }
    }
    try out.append(allocator, '"');
    return out.toOwnedSlice(allocator);
}

fn copyFileToDir(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, source_path: []const u8, dest_subpath: []const u8) !void {
    _ = allocator;
    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), source_path, dir, dest_subpath, io, .{ .make_path = true, .replace = true });
}

fn makeExecutable(dir: std.Io.Dir, io: std.Io, subpath: []const u8) !void {
    if (!std.Io.File.Permissions.has_executable_bit) return;

    var file = try dir.openFile(io, subpath, .{});
    defer file.close(io);
    const current_mode = (try file.stat(io)).permissions.toMode();
    const execute_if_readable = (current_mode & 0o444) >> 2;
    try file.setPermissions(io, .fromMode(current_mode | execute_if_readable));
}

fn readPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    return reader.interface.allocRemaining(allocator, .limited(128 * 1024 * 1024));
}

fn writeReport(allocator: std.mem.Allocator, dir: std.Io.Dir, io: std.Io, subpath: []const u8, options: PackageOptions, executable_name: []const u8, asset_count: usize) !void {
    const capabilities = try capabilityLines(allocator, options.metadata.feature_capabilities);
    defer allocator.free(capabilities);
    const frontend = try frontendLines(allocator, options.frontend);
    defer allocator.free(frontend);
    const artifact = try zonStringAlloc(allocator, std.fs.path.basename(options.output_path));
    defer allocator.free(artifact);
    const target = try zonStringAlloc(allocator, @tagName(options.target));
    defer allocator.free(target);
    const version = try zonStringAlloc(allocator, options.metadata.version);
    defer allocator.free(version);
    const app_id = try zonStringAlloc(allocator, options.metadata.id);
    defer allocator.free(app_id);
    const executable = try zonStringAlloc(allocator, executable_name);
    defer allocator.free(executable);
    const optimize = try zonStringAlloc(allocator, options.optimize);
    defer allocator.free(optimize);
    const web_engine = try zonStringAlloc(allocator, @tagName(options.web_engine));
    defer allocator.free(web_engine);
    const signing = try zonStringAlloc(allocator, @tagName(options.signing.mode));
    defer allocator.free(signing);
    const report = try std.fmt.allocPrint(allocator,
        \\.{{
        \\  .artifact = {s},
        \\  .target = {s},
        \\  .version = {s},
        \\  .app_id = {s},
        \\  .executable = {s},
        \\  .optimize = {s},
        \\  .web_engine = {s},
        \\  .signing = {s},
        \\  .asset_count = {d},
        \\{s}
        \\  .capabilities = .{{
        \\{s}
        \\  }},
        \\}}
        \\
    , .{
        artifact,
        target,
        version,
        app_id,
        executable,
        optimize,
        web_engine,
        signing,
        asset_count,
        frontend,
        capabilities,
    });
    defer allocator.free(report);
    try writeFile(dir, io, subpath, report);
}

fn capabilityLines(allocator: std.mem.Allocator, capabilities: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (capabilities) |capability| {
        const escaped = try zonStringAlloc(allocator, capability);
        defer allocator.free(escaped);
        try out.appendSlice(allocator, "    ");
        try out.appendSlice(allocator, escaped);
        try out.appendSlice(allocator, ",\n");
    }
    return out.toOwnedSlice(allocator);
}

fn frontendLines(allocator: std.mem.Allocator, frontend: ?manifest_tool.FrontendMetadata) ![]const u8 {
    if (frontend) |config| {
        const dist = try zonStringAlloc(allocator, config.dist);
        defer allocator.free(dist);
        const entry = try zonStringAlloc(allocator, config.entry);
        defer allocator.free(entry);
        return std.fmt.allocPrint(allocator,
            \\  .frontend = .{{ .dist = {s}, .entry = {s}, .spa_fallback = {} }},
            \\
        , .{ dist, entry, config.spa_fallback });
    }
    return allocator.dupe(u8, "");
}

fn copyMacosCefRuntime(allocator: std.mem.Allocator, io: std.Io, app_dir: std.Io.Dir, cef_dir: []const u8) !void {
    try app_dir.createDirPath(io, "Contents/Frameworks");
    try app_dir.createDirPath(io, "Contents/Resources/cef");

    const framework_src = try std.fs.path.join(allocator, &.{ cef_dir, "Release", "Chromium Embedded Framework.framework" });
    defer allocator.free(framework_src);
    try copyTree(allocator, io, framework_src, app_dir, "Contents/Frameworks/Chromium Embedded Framework.framework");

    const resources_src = try std.fs.path.join(allocator, &.{ cef_dir, "Resources" });
    defer allocator.free(resources_src);
    copyTree(allocator, io, resources_src, app_dir, "Contents/Resources/cef") catch |err| {
        switch (err) {
            error.FileNotFound => std.log.warn("package.cef_resource_missing: src={s} error={s}", .{ resources_src, @errorName(err) }),
            else => {
                std.log.err("package.cef_resource_copy_failed: src={s} error={s}", .{ resources_src, @errorName(err) });
                return err;
            },
        }
    };
}

fn copyDesktopCefRuntime(allocator: std.mem.Allocator, io: std.Io, package_dir: std.Io.Dir, target: PackageTarget, cef_dir: []const u8) !void {
    switch (target) {
        .linux, .windows => {},
        else => return error.UnsupportedWebEngine,
    }
    try package_dir.createDirPath(io, "bin");
    try package_dir.createDirPath(io, "resources/cef");

    const release_src = try std.fs.path.join(allocator, &.{ cef_dir, "Release" });
    defer allocator.free(release_src);
    try copyTree(allocator, io, release_src, package_dir, "bin");

    const resources_src = try std.fs.path.join(allocator, &.{ cef_dir, "Resources" });
    defer allocator.free(resources_src);
    copyTree(allocator, io, resources_src, package_dir, "resources/cef") catch |err| {
        switch (err) {
            error.FileNotFound => std.log.warn("package.cef_resource_missing: src={s} error={s}", .{ resources_src, @errorName(err) }),
            else => {
                std.log.err("package.cef_resource_copy_failed: src={s} error={s}", .{ resources_src, @errorName(err) });
                return err;
            },
        }
    };

    const locales_src = try std.fs.path.join(allocator, &.{ cef_dir, "locales" });
    defer allocator.free(locales_src);
    copyTree(allocator, io, locales_src, package_dir, "bin/locales") catch |err| {
        switch (err) {
            error.FileNotFound => std.log.warn("package.cef_resource_missing: src={s} error={s}", .{ locales_src, @errorName(err) }),
            else => {
                std.log.err("package.cef_resource_copy_failed: src={s} error={s}", .{ locales_src, @errorName(err) });
                return err;
            },
        }
    };
}

fn cefPlatformForTarget(target: PackageTarget) ?cef.Platform {
    const current = cef.Platform.current() catch null;
    return switch (target) {
        .macos => if (current) |platform| switch (platform) {
            .macosx64, .macosarm64 => platform,
            else => .macosarm64,
        } else .macosarm64,
        .linux => if (current) |platform| switch (platform) {
            .linux64, .linuxarm64 => platform,
            else => .linux64,
        } else .linux64,
        .windows => if (current) |platform| switch (platform) {
            .windows64, .windowsarm64 => platform,
            else => .windows64,
        } else .windows64,
        .ios, .android => null,
    };
}

fn copyTree(allocator: std.mem.Allocator, io: std.Io, source_path: []const u8, dest_dir: std.Io.Dir, dest_subpath: []const u8) !void {
    var source_dir = try std.Io.Dir.cwd().openDir(io, source_path, .{ .iterate = true });
    defer source_dir.close(io);
    try dest_dir.createDirPath(io, dest_subpath);

    var walker = try source_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const dest = try std.fs.path.join(allocator, &.{ dest_subpath, entry.path });
        defer allocator.free(dest);
        switch (entry.kind) {
            .directory => try dest_dir.createDirPath(io, dest),
            .file => try std.Io.Dir.copyFile(source_dir, entry.path, dest_dir, dest, io, .{ .make_path = true, .replace = true }),
            else => {},
        }
    }
}

fn runSigning(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, options: PackageOptions, sandbox_entitlements_path: ?[]const u8) !SigningResult {
    const Plan = struct {
        text: []u8,
        ok: bool,
    };
    const plan_info: Plan = blk: {
        switch (options.signing.mode) {
            .none => break :blk .{
                .text = try allocator.dupe(u8, "signing=none\nunsigned local package\n"),
                .ok = false,
            },
            .adhoc => {
                const result = if (sandbox_entitlements_path) |ent_path|
                    codesign.signAdHocWithEntitlements(io, options.output_path, ent_path)
                else
                    codesign.signAdHoc(io, options.output_path);
                const result_actual = result catch |err| {
                    if (options.fail_on_signing_error) return err;
                    std.log.warn("package.signing_failed: command=\"codesign --sign - {s}\" error={s}", .{ options.output_path, @errorName(err) });
                    break :blk .{
                        .text = try allocator.dupe(u8, "signing=adhoc\ncodesign --sign - failed; bundle is unsigned\n"),
                        .ok = false,
                    };
                };
                if (result_actual.ok) break :blk .{
                    .text = try allocator.dupe(u8, "signing=adhoc\nad-hoc signed\n"),
                    .ok = true,
                };
                if (options.fail_on_signing_error) return error.SigningFailed;
                break :blk .{
                    .text = try allocator.dupe(u8, "signing=adhoc\ncodesign --sign - failed; bundle is unsigned\n"),
                    .ok = false,
                };
            },
            .identity => {
                const identity = options.signing.identity orelse {
                    if (options.fail_on_signing_error) return error.NoIdentity;
                    break :blk .{
                        .text = try allocator.dupe(u8, "signing=identity\nno identity provided; bundle is unsigned\n"),
                        .ok = false,
                    };
                };
                const entitlements = sandbox_entitlements_path orelse options.signing.entitlements;
                const result = codesign.signIdentity(io, options.output_path, identity, entitlements) catch |err| {
                    if (options.fail_on_signing_error) return err;
                    std.log.warn("package.signing_failed: command=\"codesign --sign {s} {s}\" identity={s} error={s}", .{ identity, options.output_path, identity, @errorName(err) });
                    break :blk .{
                        .text = try allocator.dupe(u8, "signing=identity\ncodesign failed; bundle is unsigned\n"),
                        .ok = false,
                    };
                };
                if (result.ok) break :blk .{
                    .text = try std.fmt.allocPrint(allocator, "signing=identity\nsigned with {s}\n", .{identity}),
                    .ok = true,
                };
                if (options.fail_on_signing_error) return error.SigningFailed;
                break :blk .{
                    .text = try allocator.dupe(u8, "signing=identity\ncodesign failed; bundle is unsigned\n"),
                    .ok = false,
                };
            },
        }
    };
    errdefer allocator.free(plan_info.text);
    try writeFile(dir, io, "Contents/Resources/signing-plan.txt", plan_info.text);

    return .{
        .plan = plan_info.text,
        .ok = plan_info.ok,
        .mode = options.signing.mode,
        .identity = options.signing.identity,
    };
}

fn linuxDesktopEntry(allocator: std.mem.Allocator, metadata: manifest_tool.Metadata) ![]const u8 {
    const display_name = try desktopEntryEscapeAlloc(allocator, metadata.displayName());
    defer allocator.free(display_name);
    const executable = try desktopEntryEscapeAlloc(allocator, metadata.name);
    defer allocator.free(executable);

    var buf = std.ArrayList(u8).empty;
    try buf.appendSlice(allocator,
        \\[Desktop Entry]
        \\Type=Application
        \\
    );
    try buf.appendSlice(allocator, "Name=");
    try buf.appendSlice(allocator, display_name);
    try buf.appendSlice(allocator, "\nExec=");
    try buf.appendSlice(allocator, executable);
    try buf.appendSlice(allocator, "\nIcon=app-icon\nCategories=Utility;\nComment=");
    try buf.appendSlice(allocator, display_name);
    try buf.appendSlice(allocator, " desktop application\n");

    if (metadata.deep_link_schemes.len > 0) {
        try buf.appendSlice(allocator, "MimeType=");
        for (metadata.deep_link_schemes, 0..) |scheme, i| {
            if (i > 0) try buf.append(allocator, ';');
            try buf.appendSlice(allocator, "x-scheme-handler/");
            try buf.appendSlice(allocator, scheme);
        }
        try buf.append(allocator, ';');
        try buf.append(allocator, '\n');
    }

    try buf.append(allocator, '\n');
    return buf.toOwnedSlice(allocator);
}

fn runArchiveCommand(io: std.Io, argv: []const []const u8, cwd: ?[]const u8) !void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
        .cwd = if (cwd) |c| .{ .path = c } else .inherit,
    }) catch return error.ArchiveCommandFailed;
    const term = child.wait(io) catch return error.ArchiveCommandFailed;
    switch (term) {
        .exited => |code| if (code == 0) return,
        else => {},
    }
    return error.ArchiveCommandFailed;
}

fn createArchive(allocator: std.mem.Allocator, io: std.Io, options: PackageOptions) !?[]const u8 {
    const archive_path = try archivePath(allocator, options);

    var argv: [10][]const u8 = undefined;
    var argv_len: usize = 0;
    var cwd: ?[]const u8 = null;

    switch (options.target) {
        .macos => {
            argv[0] = "hdiutil";
            argv[1] = "create";
            argv[2] = "-volname";
            argv[3] = options.metadata.displayName();
            argv[4] = "-srcfolder";
            argv[5] = options.output_path;
            argv[6] = "-ov";
            argv[7] = "-format";
            argv[8] = "UDZO";
            argv[9] = archive_path;
            argv_len = 10;
        },
        .windows => {
            argv[0] = "zip";
            argv[1] = "-r";
            argv[2] = archive_path;
            argv[3] = ".";
            argv_len = 4;
            cwd = options.output_path;
        },
        .linux => {
            argv[0] = "tar";
            argv[1] = "czf";
            argv[2] = archive_path;
            argv[3] = "-C";
            argv[4] = options.output_path;
            argv[5] = ".";
            argv_len = 6;
        },
        .ios, .android => {
            allocator.free(archive_path);
            return null;
        },
    }

    runArchiveCommand(io, argv[0..argv_len], cwd) catch |err| {
        std.log.err("package.archive_failed: command={s} error={s}", .{ argv[0], @errorName(err) });
        allocator.free(archive_path);
        return null;
    };
    return archive_path;
}

pub fn archivePath(allocator: std.mem.Allocator, options: PackageOptions) ![]const u8 {
    const dir = std.fs.path.dirname(options.output_path) orelse ".";
    return std.fmt.allocPrint(allocator, "{s}/{s}-{s}-{s}-{s}{s}", .{
        dir,
        options.metadata.name,
        options.metadata.version,
        @tagName(options.target),
        options.optimize,
        archiveSuffix(options.target),
    });
}

fn archiveSuffix(target: PackageTarget) []const u8 {
    return switch (target) {
        .macos => ".dmg",
        .windows => ".zip",
        .linux => ".tar.gz",
        .ios, .android => "",
    };
}

test "archive path includes correct suffix per platform" {
    const metadata: manifest_tool.Metadata = .{ .id = "dev.example.app", .name = "demo", .version = "1.2.3" };
    const macos_path = try archivePath(std.testing.allocator, .{ .metadata = metadata, .target = .macos, .output_path = "zig-out/package/demo.app" });
    defer std.testing.allocator.free(macos_path);
    try std.testing.expect(std.mem.endsWith(u8, macos_path, ".dmg"));
    const linux_path = try archivePath(std.testing.allocator, .{ .metadata = metadata, .target = .linux, .output_path = "zig-out/package/demo" });
    defer std.testing.allocator.free(linux_path);
    try std.testing.expect(std.mem.endsWith(u8, linux_path, ".tar.gz"));
    const win_path = try archivePath(std.testing.allocator, .{ .metadata = metadata, .target = .windows, .output_path = "zig-out/package/demo" });
    defer std.testing.allocator.free(win_path);
    try std.testing.expect(std.mem.endsWith(u8, win_path, ".zip"));
}

test "linux desktop entry contains app name" {
    const metadata: manifest_tool.Metadata = .{ .id = "dev.example.app", .name = "demo", .display_name = "Demo App", .version = "1.2.3" };
    const entry = try linuxDesktopEntry(std.testing.allocator, metadata);
    defer std.testing.allocator.free(entry);
    try std.testing.expect(std.mem.indexOf(u8, entry, "Name=Demo App") != null);
    try std.testing.expect(std.mem.indexOf(u8, entry, "Exec=demo") != null);
}

test "artifact names include metadata target and optimize mode" {
    var buffer: [128]u8 = undefined;
    const metadata: manifest_tool.Metadata = .{ .id = "dev.example.app", .name = "demo", .version = "1.2.3" };
    try std.testing.expectEqualStrings("demo-1.2.3-macos-Debug.app", try artifactName(&buffer, metadata, .macos, "Debug"));
}

test "plist template includes identity executable and version" {
    const metadata: manifest_tool.Metadata = .{ .id = "dev.example.app", .name = "demo", .display_name = "Demo App", .version = "1.2.3", .icons = &.{"assets/icon.icns"} };
    const plist = try macosInfoPlist(std.testing.allocator, metadata, "demo");
    defer std.testing.allocator.free(plist);
    try std.testing.expect(std.mem.indexOf(u8, plist, "CFBundleIdentifier") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "CFBundleDisplayName") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "dev.example.app") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "Demo App") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "icon.icns") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "LSMinimumSystemVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "11.0") != null);
}

test "copying files preserves executable permissions" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;

    var cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(std.testing.io, ".zig-cache/test-package-copy-mode");
    try cwd.createDirPath(std.testing.io, ".zig-cache/test-package-copy-mode/dest");
    defer cwd.deleteTree(std.testing.io, ".zig-cache/test-package-copy-mode") catch {}; // best-effort cleanup

    const source_path = ".zig-cache/test-package-copy-mode/source-bin";
    var source = try cwd.createFile(std.testing.io, source_path, .{ .permissions = .executable_file });
    try source.writeStreamingAll(std.testing.io, "test binary");
    source.close(std.testing.io);

    var dest_dir = try cwd.openDir(std.testing.io, ".zig-cache/test-package-copy-mode/dest", .{});
    defer dest_dir.close(std.testing.io);
    try copyFileToDir(std.testing.allocator, std.testing.io, dest_dir, source_path, "Contents/MacOS/app");

    var dest = try dest_dir.openFile(std.testing.io, "Contents/MacOS/app", .{});
    defer dest.close(std.testing.io);
    const dest_permissions = (try dest.stat(std.testing.io)).permissions;
    try std.testing.expect((dest_permissions.toMode() & 0o111) != 0);
}

test "macOS app executable is marked executable" {
    if (!std.Io.File.Permissions.has_executable_bit) return error.SkipZigTest;

    var cwd = std.Io.Dir.cwd();
    try cwd.deleteTree(std.testing.io, ".zig-cache/test-package-macos-mode");
    try cwd.createDirPath(std.testing.io, ".zig-cache/test-package-macos-mode/assets");
    defer cwd.deleteTree(std.testing.io, ".zig-cache/test-package-macos-mode") catch {}; // best-effort cleanup

    const source_path = ".zig-cache/test-package-macos-mode/source-bin";
    try cwd.writeFile(std.testing.io, .{ .sub_path = source_path, .data = "test binary" });

    const metadata: manifest_tool.Metadata = .{ .id = "dev.example.app", .name = "mode-test", .version = "1.2.3" };
    _ = try createMacosApp(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .output_path = ".zig-cache/test-package-macos-mode/ModeTest.app",
        .binary_path = source_path,
        .assets_dir = ".zig-cache/test-package-macos-mode/assets",
    });

    var app_dir = try cwd.openDir(std.testing.io, ".zig-cache/test-package-macos-mode/ModeTest.app", .{});
    defer app_dir.close(std.testing.io);
    var executable = try app_dir.openFile(std.testing.io, "Contents/MacOS/mode-test", .{});
    defer executable.close(std.testing.io);
    const permissions = (try executable.stat(std.testing.io)).permissions;
    try std.testing.expect((permissions.toMode() & 0o111) != 0);
}

test "chromium desktop packages require a matching CEF layout" {
    const metadata: manifest_tool.Metadata = .{
        .id = "dev.demo",
        .name = "demo",
        .version = "0.1.0",
    };

    try std.testing.expectError(error.MissingLayout, createPackage(std.testing.allocator, std.testing.io, .{
        .metadata = metadata,
        .target = .linux,
        .output_path = ".zig-cache/test-package-linux-chromium",
        .web_engine = .chromium,
        .cef_dir = ".zig-cache/missing-linux-cef",
    }));
}

test "package report records target signing and assets" {
    const metadata: manifest_tool.Metadata = .{ .id = "dev.example.app", .name = "demo", .version = "1.2.3" };
    var cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(std.testing.io, ".zig-cache/test-package-report");
    var dir = try cwd.openDir(std.testing.io, ".zig-cache/test-package-report", .{});
    defer dir.close(std.testing.io);
    try writeReport(std.testing.allocator, dir, std.testing.io, "package-manifest.zon", .{
        .metadata = metadata,
        .target = .linux,
        .output_path = ".zig-cache/test-package-report",
        .signing = .{ .mode = .none },
    }, "demo", 2);
    var buffer: [512]u8 = undefined;
    var file = try dir.openFile(std.testing.io, "package-manifest.zon", .{});
    defer file.close(std.testing.io);
    const len = try file.readPositionalAll(std.testing.io, &buffer, 0);
    try std.testing.expect(std.mem.indexOf(u8, buffer[0..len], ".target = \"linux\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffer[0..len], ".asset_count = 2") != null);
}

test "createAndroidFullApp writes a complete Gradle project" {
    var cwd = std.Io.Dir.cwd();
    const base = ".zig-cache/test-android-full-app";
    try cwd.deleteTree(std.testing.io, base);
    defer cwd.deleteTree(std.testing.io, base) catch {}; // best-effort cleanup

    try createAndroidFullApp(
        std.testing.allocator,
        std.testing.io,
        base,
        "DemoApp",
        "com.example.demo",
        "1.0.0",
        "myapp",
    );

    var project_dir = try cwd.openDir(std.testing.io, base ++ "/DemoApp", .{});
    defer project_dir.close(std.testing.io);

    const expected_files = [_][]const u8{
        "settings.gradle",
        "build.gradle",
        "gradle.properties",
        "gradle/wrapper/gradle-wrapper.properties",
        "gradle/wrapper/gradle-wrapper.jar",
        "gradlew",
        "gradlew.bat",
        "app/build.gradle",
        "app/proguard-rules.pro",
        "app/src/main/AndroidManifest.xml",
        "app/src/main/java/com/example/demo/MainActivity.kt",
        "app/src/main/cpp/CMakeLists.txt",
        "app/src/main/cpp/zero_native_jni.c",
        "app/src/main/res/values/strings.xml",
        "app/src/main/res/values/themes.xml",
        "app/src/main/res/values/colors.xml",
        "app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml",
        "app/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml",
        "app/src/main/res/drawable/ic_launcher_foreground.xml",
        "README.md",
    };
    for (expected_files) |rel_path| {
        var f = try project_dir.openFile(std.testing.io, rel_path, .{});
        f.close(std.testing.io);
    }

    // AndroidManifest.xml should embed the deep-link scheme.
    {
        var buffer: [4096]u8 = undefined;
        var file = try project_dir.openFile(std.testing.io, "app/src/main/AndroidManifest.xml", .{});
        defer file.close(std.testing.io);
        const len = try file.readPositionalAll(std.testing.io, &buffer, 0);
        try std.testing.expect(std.mem.indexOf(u8, buffer[0..len], "<data android:scheme=\"myapp\" />") != null);
        try std.testing.expect(std.mem.indexOf(u8, buffer[0..len], "Theme.DemoApp") != null);
    }

    // strings.xml should declare the app name.
    {
        var buffer: [1024]u8 = undefined;
        var file = try project_dir.openFile(std.testing.io, "app/src/main/res/values/strings.xml", .{});
        defer file.close(std.testing.io);
        const len = try file.readPositionalAll(std.testing.io, &buffer, 0);
        try std.testing.expect(std.mem.indexOf(u8, buffer[0..len], "<string name=\"app_name\">DemoApp</string>") != null);
    }

    // MainActivity.kt should be a Kotlin file in the right package.
    {
        var buffer: [2048]u8 = undefined;
        var file = try project_dir.openFile(std.testing.io, "app/src/main/java/com/example/demo/MainActivity.kt", .{});
        defer file.close(std.testing.io);
        const len = try file.readPositionalAll(std.testing.io, &buffer, 0);
        try std.testing.expect(std.mem.indexOf(u8, buffer[0..len], "package com.example.demo") != null);
        try std.testing.expect(std.mem.indexOf(u8, buffer[0..len], "AppCompatActivity") != null);
        try std.testing.expect(std.mem.indexOf(u8, buffer[0..len], "loadUrl(\"http://127.0.0.1:5173\")") != null);
    }

    // app/build.gradle should wire up the application id and version.
    {
        var buffer: [4096]u8 = undefined;
        var file = try project_dir.openFile(std.testing.io, "app/build.gradle", .{});
        defer file.close(std.testing.io);
        const len = try file.readPositionalAll(std.testing.io, &buffer, 0);
        try std.testing.expect(std.mem.indexOf(u8, buffer[0..len], "applicationId 'com.example.demo'") != null);
        try std.testing.expect(std.mem.indexOf(u8, buffer[0..len], "versionName '1.0.0'") != null);
    }
}

test "createAndroidFullApp omits deep-link filter when scheme is null" {
    var cwd = std.Io.Dir.cwd();
    const base = ".zig-cache/test-android-full-app-no-scheme";
    try cwd.deleteTree(std.testing.io, base);
    defer cwd.deleteTree(std.testing.io, base) catch {}; // best-effort cleanup

    try createAndroidFullApp(
        std.testing.allocator,
        std.testing.io,
        base,
        "NoSchemeApp",
        "dev.example.noscheme",
        "0.1.0",
        null,
    );

    var project_dir = try cwd.openDir(std.testing.io, base ++ "/NoSchemeApp", .{});
    defer project_dir.close(std.testing.io);

    var buffer: [4096]u8 = undefined;
    var file = try project_dir.openFile(std.testing.io, "app/src/main/AndroidManifest.xml", .{});
    defer file.close(std.testing.io);
    const len = try file.readPositionalAll(std.testing.io, &buffer, 0);
    try std.testing.expect(std.mem.indexOf(u8, buffer[0..len], "android.intent.action.VIEW") == null);
    try std.testing.expect(std.mem.indexOf(u8, buffer[0..len], "Theme.NoSchemeApp") != null);
}

test "generatePbxproj produces a buildable Xcode project" {
    const allocator = std.testing.allocator;
    const pbxproj = try generatePbxproj(allocator, "MyApp", "com.example.myapp");
    defer allocator.free(pbxproj);

    // Required sections and entries.
    try std.testing.expect(std.mem.indexOf(u8, pbxproj, "// !$*UTF8*$!") != null);
    try std.testing.expect(std.mem.indexOf(u8, pbxproj, "PBXProject") != null);
    try std.testing.expect(std.mem.indexOf(u8, pbxproj, "PBXNativeTarget") != null);
    try std.testing.expect(std.mem.indexOf(u8, pbxproj, "PBXSourcesBuildPhase") != null);
    try std.testing.expect(std.mem.indexOf(u8, pbxproj, "PBXResourcesBuildPhase") != null);
    try std.testing.expect(std.mem.indexOf(u8, pbxproj, "PBXFrameworksBuildPhase") != null);
    try std.testing.expect(std.mem.indexOf(u8, pbxproj, "XCConfigurationList") != null);
    // App name and bundle id are substituted.
    try std.testing.expect(std.mem.indexOf(u8, pbxproj, "MyApp.app") != null);
    try std.testing.expect(std.mem.indexOf(u8, pbxproj, "PRODUCT_BUNDLE_IDENTIFIER = \"com.example.myapp\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, pbxproj, "name = MyApp;") != null);
    // Bridging header path uses the target name.
    try std.testing.expect(std.mem.indexOf(u8, pbxproj, "SWIFT_OBJC_BRIDGING_HEADER = MyApp/Bridging-Header.h;") != null);
    // Swift sources are listed in the build phase.
    try std.testing.expect(std.mem.indexOf(u8, pbxproj, "AppDelegate.swift in Sources") != null);
    try std.testing.expect(std.mem.indexOf(u8, pbxproj, "SceneDelegate.swift in Sources") != null);
    try std.testing.expect(std.mem.indexOf(u8, pbxproj, "ViewController.swift in Sources") != null);
    // libzero-native is wired in Frameworks.
    try std.testing.expect(std.mem.indexOf(u8, pbxproj, "libzero-native.a in Frameworks") != null);
    // Entitlements reference is parameterized.
    try std.testing.expect(std.mem.indexOf(u8, pbxproj, "CODE_SIGN_ENTITLEMENTS = MyApp/MyApp.entitlements;") != null);
}

test "createIosFullApp writes a complete Xcode project" {
    var cwd = std.Io.Dir.cwd();
    const base = ".zig-cache/test-ios-full-app";
    try cwd.deleteTree(std.testing.io, base);
    defer cwd.deleteTree(std.testing.io, base) catch {};

    try cwd.createDirPath(std.testing.io, base);
    var base_dir = try cwd.openDir(std.testing.io, base, .{});
    defer base_dir.close(std.testing.io);

    try createIosFullApp(
        std.testing.allocator,
        std.testing.io,
        base_dir,
        "DemoApp",
        "dev.example.demo",
        "1.0.0",
        null,
        "myapp",
    );

    var project_dir = try base_dir.openDir(std.testing.io, "DemoApp", .{});
    defer project_dir.close(std.testing.io);

    // project.pbxproj must be a buildable Xcode project.
    {
        var pbxproj_dir = try project_dir.openDir(std.testing.io, "DemoApp.xcodeproj", .{});
        defer pbxproj_dir.close(std.testing.io);
        var file = try pbxproj_dir.openFile(std.testing.io, "project.pbxproj", .{});
        defer file.close(std.testing.io);
        const pbxproj_stat = try file.stat(std.testing.io);
        try std.testing.expect(pbxproj_stat.size > 1000); // a real pbxproj is well over 1KB
    }

    // Info.plist must contain the deep-link scheme.
    {
        var buffer: [8192]u8 = undefined;
        var file = try project_dir.openFile(std.testing.io, "Info.plist", .{});
        defer file.close(std.testing.io);
        const len = try file.readPositionalAll(std.testing.io, &buffer, 0);
        try std.testing.expect(std.mem.indexOf(u8, buffer[0..len], "CFBundleURLSchemes") != null);
        try std.testing.expect(std.mem.indexOf(u8, buffer[0..len], "myapp") != null);
    }
}

test "createIosFullApp omits deep-link when scheme is null" {
    var cwd = std.Io.Dir.cwd();
    const base = ".zig-cache/test-ios-full-app-no-scheme";
    try cwd.deleteTree(std.testing.io, base);
    defer cwd.deleteTree(std.testing.io, base) catch {};

    try cwd.createDirPath(std.testing.io, base);
    var base_dir = try cwd.openDir(std.testing.io, base, .{});
    defer base_dir.close(std.testing.io);

    try createIosFullApp(
        std.testing.allocator,
        std.testing.io,
        base_dir,
        "PlainApp",
        "dev.example.plain",
        "0.1.0",
        null,
        null,
    );

    var project_dir = try base_dir.openDir(std.testing.io, "PlainApp", .{});
    defer project_dir.close(std.testing.io);

    var buffer: [8192]u8 = undefined;
    var file = try project_dir.openFile(std.testing.io, "Info.plist", .{});
    defer file.close(std.testing.io);
    const len = try file.readPositionalAll(std.testing.io, &buffer, 0);
    try std.testing.expect(std.mem.indexOf(u8, buffer[0..len], "CFBundleURLSchemes") == null);
}
