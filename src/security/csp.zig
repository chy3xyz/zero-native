//! Content-Security-Policy helpers for zero-native WebViews.
//!
//! CSP is enforced at the WebView layer by injecting a
//! `<meta http-equiv="Content-Security-Policy" content="...">` tag into the
//! document before it is handed to the platform backend. Because the runtime
//! only owns the HTML payload for `.html` sources, CSP injection is limited
//! to that source kind; `.url` and `.assets` sources cannot be rewritten
//! client-side and instead emit a `security.csp_skipped` event so the
//! operator can configure the policy at the server or via HTTP headers.
//!
//! The validation performed here is intentionally narrow: it rejects empty
//! values, values longer than `max_csp_bytes`, and any control character
//! (`< 0x20` or `== 0x7F`). It is not a full CSP grammar validator — that
//! responsibility belongs to the WebView engine. Callers that need stricter
//! checks should run their own policy pipeline before storing the value on a
//! `WebViewSource`.

const std = @import("std");

/// Maximum size, in bytes, of a CSP value that the runtime will accept.
/// Larger values are rejected by `validateCsp` to bound the work performed
/// during injection.
pub const max_csp_bytes: usize = 4096;

/// Returns true iff `csp` looks syntactically plausible: non-empty, ASCII, no
/// control characters, length within `max_csp_bytes`. This is a sanity check,
/// not a full CSP grammar validator.
pub fn validateCsp(csp: []const u8) bool {
    if (csp.len == 0) return false;
    if (csp.len > max_csp_bytes) return false;
    for (csp) |byte| {
        if (byte < 0x20 or byte == 0x7F) return false;
    }
    return true;
}

/// Builds the full meta tag string for a given CSP value. Useful for testing.
pub fn buildCspMetaTag(allocator: std.mem.Allocator, csp: []const u8) ![]u8 {
    const prefix = "<meta http-equiv=\"Content-Security-Policy\" content=\"";
    const suffix = "\">";
    var needed: usize = prefix.len + suffix.len;
    for (csp) |byte| {
        needed += if (byte == '"') 6 else 1;
    }
    const out = try allocator.alloc(u8, needed);
    var writer_index: usize = 0;
    @memcpy(out[writer_index..][0..prefix.len], prefix);
    writer_index += prefix.len;
    for (csp) |byte| {
        if (byte == '"') {
            @memcpy(out[writer_index..][0..6], "&quot;");
            writer_index += 6;
        } else {
            out[writer_index] = byte;
            writer_index += 1;
        }
    }
    @memcpy(out[writer_index..][0..suffix.len], suffix);
    writer_index += suffix.len;
    return out[0..writer_index];
}

/// Returns the HTML with a `<meta http-equiv="Content-Security-Policy" content="...">` tag
/// inserted at the start of `<head>` (or prepended to the document if no `<head>` is present).
/// Caller owns the returned slice and must free with the same allocator.
pub fn injectCspMeta(allocator: std.mem.Allocator, html: []const u8, csp: []const u8) ![]u8 {
    const meta_tag = try buildCspMetaTag(allocator, csp);
    defer allocator.free(meta_tag);
    if (findHeadTag(html)) |head_index| {
        const head_open_end = head_index + "<head".len;
        // Find the closing `>` of the `<head...>` tag, allowing for attributes.
        var cursor: usize = head_open_end;
        while (cursor < html.len and html[cursor] != '>') : (cursor += 1) {}
        const insert_at = if (cursor < html.len) cursor + 1 else head_open_end;
        const head_after = insert_at;
        const out = try allocator.alloc(u8, html.len + meta_tag.len);
        @memcpy(out[0..head_after], html[0..head_after]);
        @memcpy(out[head_after..][0..meta_tag.len], meta_tag);
        @memcpy(out[head_after + meta_tag.len ..][0..html.len - head_after], html[head_after..]);
        return out;
    }
    const out = try allocator.alloc(u8, html.len + meta_tag.len);
    @memcpy(out[0..meta_tag.len], meta_tag);
    @memcpy(out[meta_tag.len..][0..html.len], html);
    return out;
}

/// Case-insensitively locates the start of the first `<head` token in `html`.
/// Returns the index of the `<` or `null` when no match exists. Only used by
/// `injectCspMeta`; exposed for tests.
fn findHeadTag(html: []const u8) ?usize {
    if (html.len < "<head".len) return null;
    var index: usize = 0;
    while (index + "<head".len <= html.len) : (index += 1) {
        if (asciiEqIgnoreCase(html[index..][0.."<head".len], "<head")) {
            return index;
        }
    }
    return null;
}

fn asciiEqIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |lhs, rhs| {
        if (std.ascii.toLower(lhs) != std.ascii.toLower(rhs)) return false;
    }
    return true;
}

test "validateCsp accepts a normal CSP" {
    try std.testing.expect(validateCsp("default-src 'self'"));
    try std.testing.expect(validateCsp("default-src 'self'; script-src 'self' 'unsafe-inline'"));
    try std.testing.expect(validateCsp("default-src 'self'; img-src 'self' data:; connect-src 'self'"));
}

test "validateCsp rejects empty input" {
    try std.testing.expect(!validateCsp(""));
}

test "validateCsp rejects control characters" {
    try std.testing.expect(!validateCsp("default-src 'self'\n"));
    try std.testing.expect(!validateCsp("default-src 'self'\t"));
    try std.testing.expect(!validateCsp("default-src 'self'\r"));
    var with_del: [19]u8 = undefined;
    const prefix = "default-src 'self'";
    @memcpy(with_del[0..prefix.len], prefix);
    with_del[prefix.len] = 0x7F;
    try std.testing.expect(!validateCsp(&with_del));
}

test "validateCsp rejects oversized input" {
    var too_long: [max_csp_bytes + 1]u8 = @splat('a');
    try std.testing.expect(!validateCsp(&too_long));
    var just_right: [max_csp_bytes]u8 = @splat('a');
    try std.testing.expect(validateCsp(&just_right));
}

test "buildCspMetaTag produces a well-formed tag" {
    const allocator = std.testing.allocator;
    const tag = try buildCspMetaTag(allocator, "default-src 'self'");
    defer allocator.free(tag);
    try std.testing.expectEqualStrings(
        "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'self'\">",
        tag,
    );
}

test "buildCspMetaTag escapes double quotes" {
    const allocator = std.testing.allocator;
    const tag = try buildCspMetaTag(allocator, "default-src \"self\"");
    defer allocator.free(tag);
    try std.testing.expectEqualStrings(
        "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src &quot;self&quot;\">",
        tag,
    );
}

test "injectCspMeta inserts the meta tag after a <head> element" {
    const allocator = std.testing.allocator;
    const html = "<html><head></head><body>hi</body></html>";
    const out = try injectCspMeta(allocator, html, "default-src 'self'");
    defer allocator.free(out);
    const expected =
        \\<html><head><meta http-equiv="Content-Security-Policy" content="default-src 'self'"></head><body>hi</body></html>
    ;
    try std.testing.expectEqualStrings(expected, out);
}

test "injectCspMeta prepends the meta tag when no <head> is present" {
    const allocator = std.testing.allocator;
    const html = "<html><body>hi</body></html>";
    const out = try injectCspMeta(allocator, html, "default-src 'self'");
    defer allocator.free(out);
    const expected =
        \\<meta http-equiv="Content-Security-Policy" content="default-src 'self'"><html><body>hi</body></html>
    ;
    try std.testing.expectEqualStrings(expected, out);
}

test "injectCspMeta is case-insensitive on the <head> token" {
    const allocator = std.testing.allocator;
    const html = "<HTML><HEAD><title>x</title></HEAD><body>hi</body></HTML>";
    const out = try injectCspMeta(allocator, html, "default-src 'self'");
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'self'\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<title>x</title>") != null);
    const meta_index = std.mem.indexOf(u8, out, "<meta ").?;
    const title_index = std.mem.indexOf(u8, out, "<title>").?;
    try std.testing.expect(meta_index < title_index);
}
