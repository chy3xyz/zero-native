pub const templates = @import("templates.zig");
pub const manifest = @import("manifest.zig");
pub const raw_manifest = @import("raw_manifest.zig");
pub const assets = @import("assets.zig");
pub const codesign = @import("codesign.zig");
pub const doctor = @import("doctor.zig");
pub const package = @import("package.zig");
pub const installer = @import("installer.zig");
pub const dev = @import("dev.zig");
pub const cef = @import("cef.zig");
pub const web_engine = @import("web_engine.zig");
pub const codegen_cli = @import("codegen_cli.zig");
pub const plugins_cli = @import("plugins_cli.zig");
pub const audit = @import("audit.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
