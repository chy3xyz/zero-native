//! SQLite plugin — lightweight embedded SQL database for the frontend.
//!
//! Commands (all payloads are JSON strings):
//! - `sql.open`   — `{"path": "app.db"}`. Opens (or creates) the SQLite database.
//! - `sql.execute` — `{"sql": "CREATE TABLE ..."}` or `{"sql": "INSERT ...", "params": ["value"]}`.
//!   Returns `last_insert_rowid` and `changes` in state.last_result.
//! - `sql.select` — `{"sql": "SELECT ...", "params": ["value"]}`. Returns rows as JSON in state.last_result.
//! - `sql.close`  — closes the database handle.
//!
//! When the build is compiled without `-Dsqlite`, the plugin compiles to a
//! stub that records command names but returns `error.SqliteNotEnabled` for
//! any operation that requires a real database handle.

const std = @import("std");
const extensions = @import("root.zig");
const sqlite_options = @import("sqlite_options");

pub const ModuleId: extensions.ModuleId = 116;
pub const module_name: []const u8 = "sql";

pub const capabilities: []const extensions.Capability = &.{
    .{ .kind = .custom, .name = "sql" },
};

pub const SqlState = struct {
    allocator: std.mem.Allocator,
    db: ?DbHandle = null,
    last_result: ?[]u8 = null,

    pub fn deinit(self: *SqlState) void {
        if (self.db) |*db| db.close();
        if (self.last_result) |r| self.allocator.free(r);
        self.allocator.destroy(self);
    }
};

pub const cmd_open: []const u8 = "sql.open";
pub const cmd_execute: []const u8 = "sql.execute";
pub const cmd_select: []const u8 = "sql.select";
pub const cmd_close: []const u8 = "sql.close";

pub fn start(_: *anyopaque, _: extensions.RuntimeContext) anyerror!void {}

pub fn stop(context: *anyopaque, _: extensions.RuntimeContext) anyerror!void {
    const state: *SqlState = @ptrCast(@alignCast(context));
    state.deinit();
}

pub fn command(
    context: *anyopaque,
    _: extensions.RuntimeContext,
    cmd: extensions.Command,
) anyerror!void {
    const state: *SqlState = @ptrCast(@alignCast(context));

    if (std.mem.eql(u8, cmd.name, cmd_open)) {
        try handleOpen(state, cmd.payload);
    } else if (std.mem.eql(u8, cmd.name, cmd_execute)) {
        try handleExecute(state, cmd.payload);
    } else if (std.mem.eql(u8, cmd.name, cmd_select)) {
        try handleSelect(state, cmd.payload);
    } else if (std.mem.eql(u8, cmd.name, cmd_close)) {
        handleClose(state);
    }
}

pub fn create(allocator: std.mem.Allocator) !extensions.Module {
    const state = try allocator.create(SqlState);
    errdefer allocator.destroy(state);
    state.* = .{ .allocator = allocator };

    return .{
        .info = .{
            .id = ModuleId,
            .name = module_name,
            .capabilities = capabilities,
        },
        .context = @ptrCast(state),
        .hooks = .{
            .start_fn = start,
            .stop_fn = stop,
            .command_fn = command,
        },
    };
}

// ---------------------------------------------------------------------------
// JSON payload helpers
// ---------------------------------------------------------------------------

fn getStringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getArrayField(object: std.json.ObjectMap, key: []const u8) ?std.json.Array {
    const value = object.get(key) orelse return null;
    if (value != .array) return null;
    return value.array;
}

fn jsonValueToString(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| allocator.dupe(u8, s),
        .integer => |n| std.fmt.allocPrint(allocator, "{d}", .{n}),
        .float => |f| std.fmt.allocPrint(allocator, "{d}", .{f}),
        .bool => |b| allocator.dupe(u8, if (b) "true" else "false"),
        .null => allocator.dupe(u8, "null"),
        else => allocator.dupe(u8, ""),
    };
}

fn setResult(state: *SqlState, json: std.json.Value) !void {
    if (state.last_result) |old| state.allocator.free(old);

    var out = std.Io.Writer.Allocating.init(state.allocator);
    defer out.deinit();
    var stringify = std.json.Stringify{
        .writer = &out.writer,
        .options = .{},
    };
    try stringify.write(json);
    state.last_result = try out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// SQLite backend (real when -Dsqlite is enabled, stub otherwise)
// ---------------------------------------------------------------------------

const DbHandle = if (sqlite_options.enabled) struct {
    db: *c.sqlite3,

    fn close(self: *@This()) void {
        _ = c.sqlite3_close(self.db);
    }
} else struct {
    fn close(_: *@This()) void {}
};

const c = if (sqlite_options.enabled)
    struct {
        pub const sqlite3 = opaque {};
        pub const sqlite3_stmt = opaque {};
        pub extern "c" fn sqlite3_open(filename: [*:0]const u8, ppDb: **sqlite3) callconv(.c) c_int;
        pub extern "c" fn sqlite3_close(pDb: *sqlite3) callconv(.c) c_int;
        pub extern "c" fn sqlite3_prepare_v2(
            pDb: *sqlite3,
            zSql: [*:0]const u8,
            nByte: c_int,
            ppStmt: ?**sqlite3_stmt,
            pzTail: ?*?[*:0]const u8,
        ) callconv(.c) c_int;
        pub extern "c" fn sqlite3_step(pStmt: *sqlite3_stmt) callconv(.c) c_int;
        pub extern "c" fn sqlite3_finalize(pStmt: *sqlite3_stmt) callconv(.c) c_int;
        pub extern "c" fn sqlite3_bind_text(
            pStmt: *sqlite3_stmt,
            idx: c_int,
            text: [*]const u8,
            n: c_int,
            destructor: ?*anyopaque,
        ) callconv(.c) c_int;
        pub extern "c" fn sqlite3_bind_int64(pStmt: *sqlite3_stmt, idx: c_int, value: i64) callconv(.c) c_int;
        pub extern "c" fn sqlite3_bind_double(pStmt: *sqlite3_stmt, idx: c_int, value: f64) callconv(.c) c_int;
        pub extern "c" fn sqlite3_bind_null(pStmt: *sqlite3_stmt, idx: c_int) callconv(.c) c_int;
        pub extern "c" fn sqlite3_column_count(pStmt: *sqlite3_stmt) callconv(.c) c_int;
        pub extern "c" fn sqlite3_column_name(pStmt: *sqlite3_stmt, idx: c_int) callconv(.c) ?[*:0]const u8;
        pub extern "c" fn sqlite3_column_text(pStmt: *sqlite3_stmt, idx: c_int) callconv(.c) ?[*:0]const u8;
        pub extern "c" fn sqlite3_column_type(pStmt: *sqlite3_stmt, idx: c_int) callconv(.c) c_int;
        pub extern "c" fn sqlite3_last_insert_rowid(pDb: *sqlite3) callconv(.c) i64;
        pub extern "c" fn sqlite3_changes(pDb: *sqlite3) callconv(.c) c_int;
        pub extern "c" fn sqlite3_errmsg(pDb: *sqlite3) callconv(.c) ?[*:0]const u8;
        pub const SQLITE_OK = 0;
        pub const SQLITE_ROW = 100;
        pub const SQLITE_DONE = 101;
        pub const SQLITE_NULL = 5;
        pub const SQLITE_TEXT = 3;
        pub const SQLITE_TRANSIENT = @as(?*anyopaque, @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))));
    }
else
    struct {};

fn handleOpen(state: *SqlState, payload: []const u8) !void {
    if (state.db != null) return error.AlreadyOpen;

    const parsed = try std.json.parseFromSlice(std.json.Value, state.allocator, payload, .{});
    defer parsed.deinit();

    const path = getStringField(parsed.value.object, "path") orelse return error.MissingPath;

    if (!sqlite_options.enabled) {
        try setResult(state, .{ .string = "sqlite support not enabled; rebuild with -Dsqlite" });
        return error.SqliteNotEnabled;
    }

    var path_z = try state.allocator.alloc(u8, path.len + 1);
    defer state.allocator.free(path_z);
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    var db: *c.sqlite3 = undefined;
    const rc = c.sqlite3_open(@ptrCast(path_z.ptr), &db);
    if (rc != c.SQLITE_OK) return error.OpenFailed;

    state.db = .{ .db = db };
    try setResult(state, .{ .object = .{} });
}

fn handleExecute(state: *SqlState, payload: []const u8) !void {
    const db = state.db orelse return error.NotOpen;

    const parsed = try std.json.parseFromSlice(std.json.Value, state.allocator, payload, .{});
    defer parsed.deinit();

    const sql = getStringField(parsed.value.object, "sql") orelse return error.MissingSql;
    const params_opt = getArrayField(parsed.value.object, "params");

    if (!sqlite_options.enabled) {
        return error.SqliteNotEnabled;
    }

    var sql_z = try state.allocator.alloc(u8, sql.len + 1);
    defer state.allocator.free(sql_z);
    @memcpy(sql_z[0..sql.len], sql);
    sql_z[sql.len] = 0;

    var stmt: *c.sqlite3_stmt = undefined;
    const rc = c.sqlite3_prepare_v2(db.db, @ptrCast(sql_z.ptr), @intCast(sql.len + 1), &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareFailed;

    var bound_texts = std.ArrayList([]const u8).empty;
    defer {
        for (bound_texts.items) |t| state.allocator.free(t);
        bound_texts.deinit(state.allocator);
    }

    if (params_opt) |params| {
        for (params.items, 1..) |param, idx| {
            const text = try jsonValueToString(state.allocator, param);
            try bound_texts.append(state.allocator, text);
            const bind_rc = c.sqlite3_bind_text(stmt, @intCast(idx), text.ptr, @intCast(text.len), null);
            if (bind_rc != c.SQLITE_OK) return error.BindFailed;
        }
    }

    defer _ = c.sqlite3_finalize(stmt);

    const step_rc = c.sqlite3_step(stmt);
    if (step_rc != c.SQLITE_DONE) return error.ExecFailed;

    const rowid = c.sqlite3_last_insert_rowid(db.db);
    const changes = c.sqlite3_changes(db.db);

    var arena = std.heap.ArenaAllocator.init(state.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var result = try std.json.ObjectMap.init(alloc, &.{}, &.{});
    try result.put(alloc, "last_insert_rowid", .{ .integer = rowid });
    try result.put(alloc, "changes", .{ .integer = changes });
    try setResult(state, .{ .object = result });
}

fn handleSelect(state: *SqlState, payload: []const u8) !void {
    const db = state.db orelse return error.NotOpen;

    const parsed = try std.json.parseFromSlice(std.json.Value, state.allocator, payload, .{});
    defer parsed.deinit();

    const sql = getStringField(parsed.value.object, "sql") orelse return error.MissingSql;
    const params_opt = getArrayField(parsed.value.object, "params");

    if (!sqlite_options.enabled) {
        return error.SqliteNotEnabled;
    }

    var sql_z = try state.allocator.alloc(u8, sql.len + 1);
    defer state.allocator.free(sql_z);
    @memcpy(sql_z[0..sql.len], sql);
    sql_z[sql.len] = 0;

    var stmt: *c.sqlite3_stmt = undefined;
    const rc = c.sqlite3_prepare_v2(db.db, @ptrCast(sql_z.ptr), @intCast(sql.len + 1), &stmt, null);
    if (rc != c.SQLITE_OK) return error.PrepareFailed;

    var bound_texts = std.ArrayList([]const u8).empty;
    defer {
        for (bound_texts.items) |t| state.allocator.free(t);
        bound_texts.deinit(state.allocator);
    }

    if (params_opt) |params| {
        for (params.items, 1..) |param, idx| {
            const text = try jsonValueToString(state.allocator, param);
            try bound_texts.append(state.allocator, text);
            const bind_rc = c.sqlite3_bind_text(stmt, @intCast(idx), text.ptr, @intCast(text.len), null);
            if (bind_rc != c.SQLITE_OK) return error.BindFailed;
        }
    }

    defer _ = c.sqlite3_finalize(stmt);

    var arena = std.heap.ArenaAllocator.init(state.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const n_cols = c.sqlite3_column_count(stmt);
    var columns = std.ArrayList([]const u8).empty;
    defer {
        for (columns.items) |col| alloc.free(col);
        columns.deinit(alloc);
    }
    for (0..@intCast(n_cols)) |i| {
        const name = c.sqlite3_column_name(stmt, @intCast(i)) orelse "?";
        try columns.append(alloc, try alloc.dupe(u8, std.mem.sliceTo(name, 0)));
    }

    var rows = std.json.Array.init(alloc);
    while (true) {
        const step_rc = c.sqlite3_step(stmt);
        if (step_rc == c.SQLITE_DONE) break;
        if (step_rc != c.SQLITE_ROW) return error.QueryFailed;

        var row = try std.json.ObjectMap.init(alloc, &.{}, &.{});
        for (columns.items, 0..) |col_name, i| {
            const col_type = c.sqlite3_column_type(stmt, @intCast(i));
            if (col_type == c.SQLITE_NULL) {
                try row.put(alloc, col_name, .null);
            } else {
                const text = c.sqlite3_column_text(stmt, @intCast(i)) orelse "";
                const s = std.mem.sliceTo(text, 0);
                try row.put(alloc, col_name, .{ .string = try alloc.dupe(u8, s) });
            }
        }
        try rows.append(.{ .object = row });
    }

    var result = try std.json.ObjectMap.init(alloc, &.{}, &.{});
    try result.put(alloc, "columns", blk: {
        var arr = std.json.Array.init(alloc);
        for (columns.items) |col| try arr.append(.{ .string = col });
        break :blk .{ .array = arr };
    });
    try result.put(alloc, "rows", .{ .array = rows });
    try setResult(state, .{ .object = result });
}

fn handleClose(state: *SqlState) void {
    if (state.db) |*db| {
        db.close();
        state.db = null;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "sql plugin registers without collisions" {
    const allocator = std.testing.allocator;
    const module = try create(allocator);
    defer module.hooks.stop_fn.?(module.context, .{ .platform_name = "null" }) catch {};

    try std.testing.expectEqual(ModuleId, module.info.id);
    try std.testing.expectEqualStrings("sql", module.info.name);
}

test "sql plugin open returns SqliteNotEnabled when not built with -Dsqlite" {
    if (sqlite_options.enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const module = try create(allocator);
    defer module.hooks.stop_fn.?(module.context, .{ .platform_name = "null" }) catch {};

    const result = module.hooks.command_fn.?(module.context, .{ .platform_name = "null" }, .{
        .name = "sql.open",
        .payload = "{\"path\":\":memory:\"}",
        .target = ModuleId,
    });
    try std.testing.expectError(error.SqliteNotEnabled, result);
}

test "sql plugin in-memory execute and select" {
    if (!sqlite_options.enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const module = try create(allocator);
    defer module.hooks.stop_fn.?(module.context, .{ .platform_name = "null" }) catch {};

    try module.hooks.command_fn.?(module.context, .{ .platform_name = "null" }, .{
        .name = "sql.open",
        .payload = "{\"path\":\":memory:\"}",
        .target = ModuleId,
    });
    try module.hooks.command_fn.?(module.context, .{ .platform_name = "null" }, .{
        .name = "sql.execute",
        .payload = "{\"sql\":\"CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)\"}",
        .target = ModuleId,
    });
    try module.hooks.command_fn.?(module.context, .{ .platform_name = "null" }, .{
        .name = "sql.execute",
        .payload = "{\"sql\":\"INSERT INTO users (name) VALUES (?)\",\"params\":[\"alice\"]}",
        .target = ModuleId,
    });
    try module.hooks.command_fn.?(module.context, .{ .platform_name = "null" }, .{
        .name = "sql.select",
        .payload = "{\"sql\":\"SELECT id, name FROM users WHERE name = ?\",\"params\":[\"alice\"]}",
        .target = ModuleId,
    });

    const state: *SqlState = @ptrCast(@alignCast(module.context));
    const result_json = state.last_result orelse return error.MissingResult;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result_json, .{});
    defer parsed.deinit();

    const rows = parsed.value.object.get("rows") orelse return error.MissingRows;
    try std.testing.expectEqual(@as(usize, 1), rows.array.items.len);
    const name_value = rows.array.items[0].object.get("name") orelse return error.MissingName;
    try std.testing.expectEqualStrings("alice", name_value.string);
}
