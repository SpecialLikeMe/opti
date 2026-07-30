//! Lookups against Arch's official repositories.
//!
//! Needed for two reasons. First, error quality: most unsatisfied dependencies
//! are official packages like `go` or `cmake`, and "not found" is useless next
//! to "in extra, install it with your system package manager". Second,
//! correctness: knowing a name belongs to core/extra proves the AUR must not
//! be asked about it, since AUR policy forbids duplicating official packages
//! and a by-provides search would answer with a fork.
//!
//! Uses archlinux.org's JSON search rather than downloading and parsing
//! `core.db` from a mirror. That keeps this to plain JSON at the cost of a
//! request per lookup; swapping in a mirror database later changes only this
//! file.

const std = @import("std");
const fetch = @import("../mkpkg/fetch.zig");

pub const Error = error{MalformedResponse};

pub const endpoint = "https://archlinux.org/packages/search/json";

pub const Package = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    /// core, extra, multilib, ...
    repo: []const u8,
    version: []const u8,
    description: []const u8 = "",

    pub fn deinit(self: *Package) void {
        self.arena.deinit();
    }
};

/// Look up an exact package name in the official repositories.
pub fn lookup(gpa: std.mem.Allocator, name: []const u8) !?Package {
    const url = try std.fmt.allocPrintSentinel(gpa, "{s}/?name={s}", .{ endpoint, name }, 0);
    defer gpa.free(url);

    const body = fetch.get(gpa, url) catch return null;
    defer gpa.free(body);

    return parseFirst(gpa, body);
}

pub fn parseFirst(gpa: std.mem.Allocator, body: []const u8) !?Package {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch {
        return Error.MalformedResponse;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return Error.MalformedResponse,
    };
    const results = switch (root.get("results") orelse return null) {
        .array => |a| a,
        else => return Error.MalformedResponse,
    };
    if (results.items.len == 0) return null;

    const entry = switch (results.items[0]) {
        .object => |o| o,
        else => return Error.MalformedResponse,
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const pkgname = try str(a, entry.get("pkgname")) orelse return Error.MalformedResponse;
    const repo = try str(a, entry.get("repo")) orelse "unknown";
    const version = try str(a, entry.get("pkgver")) orelse "";
    const description = try str(a, entry.get("pkgdesc")) orelse "";

    return .{
        .arena = arena,
        .name = pkgname,
        .repo = repo,
        .version = version,
        .description = description,
    };
}

fn str(a: std.mem.Allocator, value: ?std.json.Value) !?[]const u8 {
    const v = value orelse return null;
    return switch (v) {
        .string => |s| try a.dupe(u8, s),
        else => null,
    };
}

const testing = std.testing;

test "parses a search response" {
    const body =
        \\{"results":[{"pkgname":"go","repo":"extra","pkgver":"1.25.0",
        \\"pkgdesc":"Core compiler tools for the Go programming language"}]}
    ;
    var pkg = (try parseFirst(testing.allocator, body)).?;
    defer pkg.deinit();

    try testing.expectEqualStrings("go", pkg.name);
    try testing.expectEqualStrings("extra", pkg.repo);
    try testing.expectEqualStrings("1.25.0", pkg.version);
}

test "an empty result set is not found" {
    try testing.expectEqual(
        @as(?Package, null),
        try parseFirst(testing.allocator, "{\"results\":[]}"),
    );
}

test "malformed json is rejected" {
    try testing.expectError(Error.MalformedResponse, parseFirst(testing.allocator, "<html>"));
}
