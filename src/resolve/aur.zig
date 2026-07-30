//! AUR RPC client.
//!
//! Two lookups matter for resolution: by exact package name, and by `provides`
//! for dependency strings that name a soname rather than a package.
//!
//! The by-provides lookup is dangerous on its own and must never be reached
//! for something the host already supplies. Asking the AUR who provides
//! `libcurl.so` returns variant packages such as `curl-c-ares` — the AUR does
//! not carry mainline curl, because policy forbids duplicating the official
//! repositories. Resolving a base library that way would silently swap it for
//! a fork. See `system.zig` for the ordering that prevents it.

const std = @import("std");
const fetch = @import("../mkpkg/fetch.zig");

pub const Error = error{ RequestFailed, MalformedResponse };

pub const base = "https://aur.archlinux.org/rpc/v5";

/// One AUR package, owning its own storage.
pub const Package = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    package_base: []const u8,
    version: []const u8,
    description: []const u8 = "",
    depends: []const []const u8 = &.{},
    make_depends: []const []const u8 = &.{},
    provides: []const []const u8 = &.{},

    pub fn deinit(self: *Package) void {
        self.arena.deinit();
    }
};

/// Suffixes marking a package as a variant rather than a mainline build.
const variant_suffixes = [_][]const u8{ "-git", "-svn", "-hg", "-bzr", "-bin", "-nightly" };

/// Whether `name` looks like a VCS or prebuilt variant.
///
/// Resolution warns before pulling one of these in as a *dependency*, since
/// picking `foo-git` to satisfy `foo` builds an unreleased revision. Asking for
/// one by name explicitly is fine.
pub fn isVariant(name: []const u8) bool {
    for (variant_suffixes) |suffix| {
        if (std.mem.endsWith(u8, name, suffix)) return true;
    }
    return false;
}

/// Look up an exact package name. Returns null when the AUR has no such
/// package.
pub fn info(gpa: std.mem.Allocator, name: []const u8) !?Package {
    const url = try std.fmt.allocPrintSentinel(
        gpa,
        "{s}/info?arg%5B%5D={s}",
        .{ base, name },
        0,
    );
    defer gpa.free(url);
    return firstResult(gpa, url);
}

/// Find packages declaring `token` in their `provides`.
pub fn byProvides(gpa: std.mem.Allocator, token: []const u8) !?Package {
    const url = try std.fmt.allocPrintSentinel(
        gpa,
        "{s}/search/{s}?by=provides",
        .{ base, token },
        0,
    );
    defer gpa.free(url);
    return firstResult(gpa, url);
}

fn firstResult(gpa: std.mem.Allocator, url: [:0]const u8) !?Package {
    const body = fetch.get(gpa, url) catch return Error.RequestFailed;
    defer gpa.free(body);

    return parseFirst(gpa, body);
}

/// Parse the first entry of an RPC response.
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

    const name = try dupeString(a, entry.get("Name")) orelse return Error.MalformedResponse;
    const pkgbase = try dupeString(a, entry.get("PackageBase")) orelse name;
    const version = try dupeString(a, entry.get("Version")) orelse "";
    const description = try dupeString(a, entry.get("Description")) orelse "";

    const depends = try dupeStringArray(a, entry.get("Depends"));
    const make_depends = try dupeStringArray(a, entry.get("MakeDepends"));
    const provides = try dupeStringArray(a, entry.get("Provides"));

    // The arena is moved in only after every allocation above, or it would
    // carry a stale snapshot and leak the rest.
    return .{
        .arena = arena,
        .name = name,
        .package_base = pkgbase,
        .version = version,
        .description = description,
        .depends = depends,
        .make_depends = make_depends,
        .provides = provides,
    };
}

fn dupeString(a: std.mem.Allocator, value: ?std.json.Value) !?[]const u8 {
    const v = value orelse return null;
    return switch (v) {
        .string => |s| try a.dupe(u8, s),
        else => null,
    };
}

fn dupeStringArray(a: std.mem.Allocator, value: ?std.json.Value) ![]const []const u8 {
    const v = value orelse return &.{};
    const arr = switch (v) {
        .array => |x| x,
        else => return &.{},
    };

    var out: std.ArrayList([]const u8) = .empty;
    for (arr.items) |item| {
        switch (item) {
            .string => |s| try out.append(a, try a.dupe(u8, s)),
            else => {},
        }
    }
    return out.toOwnedSlice(a);
}

const testing = std.testing;

test "variant names are recognised" {
    try testing.expect(isVariant("curl-git"));
    try testing.expect(isVariant("visual-studio-code-bin"));
    try testing.expect(isVariant("foo-svn"));
    try testing.expect(!isVariant("curl"));
    try testing.expect(!isVariant("git"));
    // A name merely containing the text is not a variant.
    try testing.expect(!isVariant("git-lfs"));
}

test "parses an info response" {
    const body =
        \\{"resultcount":1,"results":[{
        \\"Name":"yay","PackageBase":"yay","Version":"13.0.1-1",
        \\"Description":"Pacman wrapper and AUR helper",
        \\"Depends":["pacman>6.1","git"],
        \\"MakeDepends":["go>=1.24"],
        \\"Provides":["yay"]}]}
    ;
    var pkg = (try parseFirst(testing.allocator, body)).?;
    defer pkg.deinit();

    try testing.expectEqualStrings("yay", pkg.name);
    try testing.expectEqualStrings("13.0.1-1", pkg.version);
    try testing.expectEqual(@as(usize, 2), pkg.depends.len);
    try testing.expectEqualStrings("pacman>6.1", pkg.depends[0]);
    try testing.expectEqualStrings("go>=1.24", pkg.make_depends[0]);
}

test "an empty result set is not found" {
    const body = "{\"resultcount\":0,\"results\":[]}";
    try testing.expectEqual(@as(?Package, null), try parseFirst(testing.allocator, body));
}

test "missing optional arrays default to empty" {
    const body =
        \\{"resultcount":1,"results":[{"Name":"minimal","Version":"1-1"}]}
    ;
    var pkg = (try parseFirst(testing.allocator, body)).?;
    defer pkg.deinit();

    try testing.expectEqualStrings("minimal", pkg.name);
    try testing.expectEqual(@as(usize, 0), pkg.depends.len);
    try testing.expectEqual(@as(usize, 0), pkg.provides.len);
    // PackageBase falls back to the name.
    try testing.expectEqualStrings("minimal", pkg.package_base);
}

test "malformed json is rejected" {
    try testing.expectError(Error.MalformedResponse, parseFirst(testing.allocator, "not json"));
}
