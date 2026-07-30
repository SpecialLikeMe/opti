//! Install records: what is installed, and exactly which files it owns.
//!
//! The file list is what makes uninstall exact rather than a guess. It is
//! captured at install time from the tree actually written, not inferred later
//! from the package, so a partially-extracted install still removes cleanly.
//!
//! Format is the same line-oriented `key = value` shape as `.SRCINFO` and
//! `.PKGINFO`, with repeated keys forming lists. It stays greppable, needs no
//! separate parser, and a truncated write is detectable rather than silently
//! misread as valid.

const std = @import("std");

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,

    name: []const u8 = "",
    version: []const u8 = "",
    arch: []const u8 = "",
    description: []const u8 = "",
    /// Seconds since the epoch.
    installed_at: i64 = 0,
    /// Total bytes of the installed tree.
    size: u64 = 0,
    /// Prefix the files were extracted into.
    prefix: []const u8 = "",
    /// Runtime dependencies, verbatim from `.PKGINFO`.
    depends: []const []const u8 = &.{},
    /// Paths relative to `prefix`.
    files: []const []const u8 = &.{},
    /// Names created under the shared bin/ directory.
    links: []const []const u8 = &.{},

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
    }

    /// Serialise. Caller owns the result.
    pub fn render(self: Manifest, gpa: std.mem.Allocator) ![]u8 {
        var buf: std.Io.Writer.Allocating = .init(gpa);
        errdefer buf.deinit();
        const w = &buf.writer;

        try w.print("name = {s}\n", .{self.name});
        try w.print("version = {s}\n", .{self.version});
        try w.print("arch = {s}\n", .{self.arch});
        if (self.description.len > 0) try w.print("desc = {s}\n", .{self.description});
        try w.print("installed = {d}\n", .{self.installed_at});
        try w.print("size = {d}\n", .{self.size});
        try w.print("prefix = {s}\n", .{self.prefix});

        for (self.depends) |d| try w.print("depend = {s}\n", .{d});
        for (self.links) |l| try w.print("link = {s}\n", .{l});
        // Files last: it is the longest section, and keeping it at the end
        // makes a truncated manifest obvious on inspection.
        for (self.files) |f| try w.print("file = {s}\n", .{f});

        return buf.toOwnedSlice();
    }
};

pub fn parse(gpa: std.mem.Allocator, text: []const u8) !Manifest {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var name: []const u8 = "";
    var version: []const u8 = "";
    var arch: []const u8 = "";
    var description: []const u8 = "";
    var installed_at: i64 = 0;
    var size: u64 = 0;
    var prefix: []const u8 = "";

    var depends: std.ArrayList([]const u8) = .empty;
    var files: std.ArrayList([]const u8) = .empty;
    var links: std.ArrayList([]const u8) = .empty;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len == 0) continue;

        if (std.mem.eql(u8, key, "name")) {
            name = try a.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "version")) {
            version = try a.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "arch")) {
            arch = try a.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "desc")) {
            description = try a.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "installed")) {
            installed_at = std.fmt.parseInt(i64, value, 10) catch 0;
        } else if (std.mem.eql(u8, key, "size")) {
            size = std.fmt.parseInt(u64, value, 10) catch 0;
        } else if (std.mem.eql(u8, key, "prefix")) {
            prefix = try a.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "depend")) {
            try depends.append(a, try a.dupe(u8, value));
        } else if (std.mem.eql(u8, key, "file")) {
            try files.append(a, try a.dupe(u8, value));
        } else if (std.mem.eql(u8, key, "link")) {
            try links.append(a, try a.dupe(u8, value));
        }
    }

    // All allocation must finish before the arena is copied into the result,
    // or it would carry a stale snapshot and leak the rest.
    const out_depends = try depends.toOwnedSlice(a);
    const out_files = try files.toOwnedSlice(a);
    const out_links = try links.toOwnedSlice(a);

    return .{
        .arena = arena,
        .name = name,
        .version = version,
        .arch = arch,
        .description = description,
        .installed_at = installed_at,
        .size = size,
        .prefix = prefix,
        .depends = out_depends,
        .files = out_files,
        .links = out_links,
    };
}

/// Extract a single field from `.PKGINFO`-shaped text.
pub fn pkginfoField(text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), key)) continue;
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len > 0) return value;
    }
    return null;
}

/// Collect every value for a repeated `.PKGINFO` key.
pub fn pkginfoList(
    gpa: std.mem.Allocator,
    text: []const u8,
    key: []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[0..eq], " \t"), key)) continue;
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len > 0) try out.append(gpa, value);
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

test "render and parse round-trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const original: Manifest = .{
        .arena = arena,
        .name = "curl",
        .version = "8.21.0-1",
        .arch = "x86_64",
        .description = "transfer data with URLs",
        .installed_at = 1_700_000_000,
        .size = 4096,
        .prefix = "/var/lib/opti/store/curl-8.21.0-1",
        .depends = &.{ "glibc", "openssl>=3" },
        .files = &.{ "usr/bin/curl", "usr/lib/libcurl.so.4" },
        .links = &.{"curl"},
    };

    const text = try original.render(testing.allocator);
    defer testing.allocator.free(text);
    arena.deinit();

    var back = try parse(testing.allocator, text);
    defer back.deinit();

    try testing.expectEqualStrings("curl", back.name);
    try testing.expectEqualStrings("8.21.0-1", back.version);
    try testing.expectEqualStrings("x86_64", back.arch);
    try testing.expectEqualStrings("transfer data with URLs", back.description);
    try testing.expectEqual(@as(i64, 1_700_000_000), back.installed_at);
    try testing.expectEqual(@as(u64, 4096), back.size);

    try testing.expectEqual(@as(usize, 2), back.depends.len);
    try testing.expectEqualStrings("openssl>=3", back.depends[1]);

    try testing.expectEqual(@as(usize, 2), back.files.len);
    try testing.expectEqualStrings("usr/lib/libcurl.so.4", back.files[1]);

    try testing.expectEqual(@as(usize, 1), back.links.len);
    try testing.expectEqualStrings("curl", back.links[0]);
}

test "paths containing spaces survive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const m: Manifest = .{
        .arena = arena,
        .name = "x",
        .version = "1-1",
        .files = &.{"usr/share/my app/data file.txt"},
    };
    const text = try m.render(testing.allocator);
    defer testing.allocator.free(text);
    arena.deinit();

    var back = try parse(testing.allocator, text);
    defer back.deinit();
    try testing.expectEqualStrings("usr/share/my app/data file.txt", back.files[0]);
}

test "pkginfo field extraction" {
    const info =
        \\pkgname = hello
        \\pkgver = 2.12.1-1
        \\arch = x86_64
        \\depend = glibc
        \\depend = zlib
    ;
    try testing.expectEqualStrings("hello", pkginfoField(info, "pkgname").?);
    try testing.expectEqualStrings("2.12.1-1", pkginfoField(info, "pkgver").?);
    try testing.expectEqual(@as(?[]const u8, null), pkginfoField(info, "url"));

    const deps = try pkginfoList(testing.allocator, info, "depend");
    defer testing.allocator.free(deps);
    try testing.expectEqual(@as(usize, 2), deps.len);
    try testing.expectEqualStrings("zlib", deps[1]);
}

test "an empty manifest parses to empty lists" {
    var m = try parse(testing.allocator, "");
    defer m.deinit();
    try testing.expectEqual(@as(usize, 0), m.files.len);
    try testing.expectEqualStrings("", m.name);
}
