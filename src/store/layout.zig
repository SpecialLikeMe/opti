//! On-disk layout of the opti store.
//!
//! One shared store per machine, Homebrew-style: each package gets its own
//! versioned prefix, so removing it is removing a directory and uninstall
//! cannot leave stragglers behind.
//!
//!     /var/lib/opti/
//!       store/<name>-<version>/     installed tree, rooted at usr/, etc/, ...
//!       db/<name>/                  what is installed and which files it owns
//!       bin/                        symlinks onto PATH
//!       cache/src/<name>/           PKGBUILD checkouts
//!       cache/pkg/                  built artifacts
//!
//! Source checkouts live under `cache/`, never under `store/`: one is an input
//! to a build, the other is the thing that got installed, and conflating them
//! makes uninstall ambiguous.
//!
//! `root` is a field rather than a constant so tests can operate on a
//! temporary directory instead of the real one.

const std = @import("std");

pub const default_root = "/var/lib/opti";

pub const Layout = struct {
    root: []const u8 = default_root,

    /// Installed prefix for a specific version.
    pub fn store(self: Layout, gpa: std.mem.Allocator, name: []const u8, version: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}/store/{s}-{s}", .{ self.root, name, version });
    }

    /// Directory holding a package's install record.
    pub fn db(self: Layout, gpa: std.mem.Allocator, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}/db/{s}", .{ self.root, name });
    }

    /// Path of the manifest itself.
    pub fn manifest(self: Layout, gpa: std.mem.Allocator, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}/db/{s}/MANIFEST", .{ self.root, name });
    }

    pub fn dbRoot(self: Layout, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}/db", .{self.root});
    }

    /// Symlink farm placed on the user's PATH.
    pub fn bin(self: Layout, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}/bin", .{self.root});
    }

    /// Symlink farm for shared libraries.
    ///
    /// Source builds get `-Wl,-rpath,<this>` so a binary finds libraries from
    /// other opti packages after being relocated into its own prefix. A single
    /// shared directory rather than per-package RPATHs keeps it correct for
    /// split packages, whose outputs do not share a prefix.
    pub fn lib(self: Layout, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}/lib", .{self.root});
    }

    /// Where a package's PKGBUILD checkout lives.
    pub fn sourceCache(self: Layout, gpa: std.mem.Allocator, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}/cache/src/{s}", .{ self.root, name });
    }

    pub fn packageCache(self: Layout, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}/cache/pkg", .{self.root});
    }
};

const testing = std.testing;

test "paths are derived from the root" {
    const l: Layout = .{ .root = "/tmp/opti-test" };

    const s = try l.store(testing.allocator, "curl", "8.21.0-1");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("/tmp/opti-test/store/curl-8.21.0-1", s);

    const m = try l.manifest(testing.allocator, "curl");
    defer testing.allocator.free(m);
    try testing.expectEqualStrings("/tmp/opti-test/db/curl/MANIFEST", m);

    const b = try l.bin(testing.allocator);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("/tmp/opti-test/bin", b);
}

test "sources are cached outside the store" {
    const l: Layout = .{ .root = "/var/lib/opti" };

    const src = try l.sourceCache(testing.allocator, "yay");
    defer testing.allocator.free(src);
    const st = try l.store(testing.allocator, "yay", "1-1");
    defer testing.allocator.free(st);

    try testing.expect(std.mem.indexOf(u8, src, "/cache/src/") != null);
    // A checkout must never land inside an installed prefix.
    try testing.expect(!std.mem.startsWith(u8, src, st));
}

test "default root" {
    const l: Layout = .{};
    try testing.expectEqualStrings("/var/lib/opti", l.root);
}
