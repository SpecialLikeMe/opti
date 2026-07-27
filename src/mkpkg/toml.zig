//! Minimal TOML reader covering what `optimkp.toml` needs.
//!
//! Deliberately a subset: `[section]` headers, `key = value` pairs, strings,
//! booleans, integers and single-line arrays of strings. No nested tables,
//! no multi-line strings, no dates. A config file is not a place to need a
//! thousand-line parser, and anything outside this grammar is reported rather
//! than silently misread.

const std = @import("std");

pub const Error = error{
    UnterminatedString,
    UnterminatedArray,
    MissingEquals,
    InvalidValue,
};

pub const Value = union(enum) {
    string: []const u8,
    boolean: bool,
    integer: i64,
    array: []const []const u8,
};

/// A parsed document. Keys are stored fully qualified as `section.key`, so a
/// lookup never has to walk a tree.
pub const Table = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.StringHashMapUnmanaged(Value) = .empty,

    pub fn deinit(self: *Table) void {
        self.arena.deinit();
    }

    pub fn get(self: Table, key: []const u8) ?Value {
        return self.entries.get(key);
    }

    pub fn getString(self: Table, key: []const u8) ?[]const u8 {
        const v = self.get(key) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn getBool(self: Table, key: []const u8) ?bool {
        const v = self.get(key) orelse return null;
        return switch (v) {
            .boolean => |b| b,
            else => null,
        };
    }

    pub fn getInteger(self: Table, key: []const u8) ?i64 {
        const v = self.get(key) orelse return null;
        return switch (v) {
            .integer => |i| i,
            else => null,
        };
    }

    pub fn getArray(self: Table, key: []const u8) ?[]const []const u8 {
        const v = self.get(key) orelse return null;
        return switch (v) {
            .array => |a| a,
            else => null,
        };
    }
};

pub fn parse(gpa: std.mem.Allocator, text: []const u8) !Table {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var entries: std.StringHashMapUnmanaged(Value) = .empty;
    var section: []const u8 = "";

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = stripComment(std.mem.trim(u8, raw, " \t\r"));
        if (line.len == 0) continue;

        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            section = try a.dupe(u8, std.mem.trim(u8, line[1..close], " \t"));
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return Error.MissingEquals;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const rest = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0) return Error.MissingEquals;

        const qualified = if (section.len == 0)
            try a.dupe(u8, key)
        else
            try std.fmt.allocPrint(a, "{s}.{s}", .{ section, key });

        try entries.put(a, qualified, try parseValue(a, rest));
    }

    return .{ .arena = arena, .entries = entries };
}

/// Strip a trailing `#` comment, ignoring `#` inside a quoted string.
fn stripComment(line: []const u8) []const u8 {
    var in_string = false;
    for (line, 0..) |ch, i| {
        switch (ch) {
            '"' => in_string = !in_string,
            '#' => if (!in_string) return std.mem.trim(u8, line[0..i], " \t"),
            else => {},
        }
    }
    return line;
}

fn parseValue(a: std.mem.Allocator, raw: []const u8) !Value {
    if (raw.len == 0) return Error.InvalidValue;

    if (raw[0] == '"') {
        return .{ .string = try parseString(a, raw) };
    }
    if (raw[0] == '[') {
        return .{ .array = try parseArray(a, raw) };
    }
    if (std.mem.eql(u8, raw, "true")) return .{ .boolean = true };
    if (std.mem.eql(u8, raw, "false")) return .{ .boolean = false };

    const n = std.fmt.parseInt(i64, raw, 10) catch return Error.InvalidValue;
    return .{ .integer = n };
}

fn parseString(a: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len < 2 or raw[0] != '"') return Error.UnterminatedString;
    const close = std.mem.lastIndexOfScalar(u8, raw, '"') orelse return Error.UnterminatedString;
    if (close == 0) return Error.UnterminatedString;
    return a.dupe(u8, raw[1..close]);
}

fn parseArray(a: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    const close = std.mem.lastIndexOfScalar(u8, raw, ']') orelse return Error.UnterminatedArray;
    const inner = std.mem.trim(u8, raw[1..close], " \t");

    var items: std.ArrayList([]const u8) = .empty;
    if (inner.len == 0) return items.toOwnedSlice(a);

    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |piece| {
        const trimmed = std.mem.trim(u8, piece, " \t");
        if (trimmed.len == 0) continue;
        try items.append(a, try parseString(a, trimmed));
    }
    return items.toOwnedSlice(a);
}

const testing = std.testing;

test "sections qualify keys" {
    const text =
        \\[build]
        \\cflags = "-O2 -pipe"
        \\[package]
        \\compression = "zstd"
    ;
    var t = try parse(testing.allocator, text);
    defer t.deinit();

    try testing.expectEqualStrings("-O2 -pipe", t.getString("build.cflags").?);
    try testing.expectEqualStrings("zstd", t.getString("package.compression").?);
    try testing.expectEqual(@as(?[]const u8, null), t.getString("cflags"));
}

test "booleans and integers" {
    const text =
        \\[options]
        \\strip = true
        \\docs = false
        \\jobs = 12
    ;
    var t = try parse(testing.allocator, text);
    defer t.deinit();

    try testing.expectEqual(true, t.getBool("options.strip").?);
    try testing.expectEqual(false, t.getBool("options.docs").?);
    try testing.expectEqual(@as(i64, 12), t.getInteger("options.jobs").?);
}

test "arrays of strings" {
    const text =
        \\[build]
        \\purge = ["*.pod", ".packlist"]
        \\empty = []
    ;
    var t = try parse(testing.allocator, text);
    defer t.deinit();

    const purge = t.getArray("build.purge").?;
    try testing.expectEqual(@as(usize, 2), purge.len);
    try testing.expectEqualStrings("*.pod", purge[0]);
    try testing.expectEqualStrings(".packlist", purge[1]);
    try testing.expectEqual(@as(usize, 0), t.getArray("build.empty").?.len);
}

test "comments are ignored" {
    const text =
        \\# leading comment
        \\[build]
        \\cflags = "-O2"   # trailing comment
    ;
    var t = try parse(testing.allocator, text);
    defer t.deinit();
    try testing.expectEqualStrings("-O2", t.getString("build.cflags").?);
}

test "a hash inside a string is not a comment" {
    const text =
        \\[build]
        \\packager = "me #1 <a@b.c>"
    ;
    var t = try parse(testing.allocator, text);
    defer t.deinit();
    try testing.expectEqualStrings("me #1 <a@b.c>", t.getString("build.packager").?);
}

test "wrong type returns null rather than misreading" {
    const text = "[build]\ncflags = \"-O2\"\n";
    var t = try parse(testing.allocator, text);
    defer t.deinit();

    try testing.expectEqual(@as(?bool, null), t.getBool("build.cflags"));
    try testing.expectEqual(@as(?i64, null), t.getInteger("build.cflags"));
}

test "missing equals is an error" {
    try testing.expectError(Error.MissingEquals, parse(testing.allocator, "[a]\nbroken\n"));
}
