//! Parsing for dependency strings as they appear in PKGBUILD/.SRCINFO
//! `depends`, `makedepends`, `provides` and `conflicts` entries.
//!
//! Three shapes occur in practice:
//!
//!     git                 plain name, any version
//!     pacman>6.1          name with a version constraint
//!     libcurl.so=4-64     soname with an ABI version
//!
//! The soname form matters: roughly half of all dependency strings resolve
//! through `provides` rather than through a package name, and the ABI version
//! is load-bearing. Matching `libcurl.so` while ignoring the `=4-64` would
//! happily satisfy a consumer with an incompatible ABI.

const std = @import("std");

pub const Op = enum {
    any,
    eq,
    lt,
    le,
    gt,
    ge,

    pub fn text(op: Op) []const u8 {
        return switch (op) {
            .any => "",
            .eq => "=",
            .lt => "<",
            .le => "<=",
            .gt => ">",
            .ge => ">=",
        };
    }
};

pub const Dep = struct {
    /// Package name, or soname when `is_soname` is set.
    name: []const u8,
    op: Op = .any,
    /// Constraint operand. For sonames this is the ABI ("4-64"), otherwise a
    /// package version ("1.24", "6.1-2", "2:1.9.6-1").
    version: ?[]const u8 = null,
    /// Set when `name` denotes a shared object rather than a package name.
    is_soname: bool = false,

    /// Borrows from `s`; the result is only valid while `s` lives.
    pub fn parse(s: []const u8) Dep {
        const raw = std.mem.trim(u8, s, " \t");

        const idx = std.mem.indexOfAny(u8, raw, "<>=") orelse return .{
            .name = raw,
            .is_soname = isSoname(raw),
        };

        const name = raw[0..idx];
        var op: Op = undefined;
        var vstart: usize = undefined;

        if (raw[idx] == '=') {
            op = .eq;
            vstart = idx + 1;
        } else if (idx + 1 < raw.len and raw[idx + 1] == '=') {
            op = if (raw[idx] == '>') .ge else .le;
            vstart = idx + 2;
        } else {
            op = if (raw[idx] == '>') .gt else .lt;
            vstart = idx + 1;
        }

        const version = raw[vstart..];
        return .{
            .name = name,
            .op = op,
            // An operator with an empty operand is malformed; treat it as
            // unconstrained rather than carrying an empty version around.
            .version = if (version.len == 0) null else version,
            .is_soname = isSoname(name),
        };
    }
};

/// Arch spells shared-object provides as `libfoo.so`, so the suffix is the
/// only reliable discriminator between a soname and a package name.
pub fn isSoname(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".so");
}

const testing = std.testing;

test "plain name" {
    const d = Dep.parse("git");
    try testing.expectEqualStrings("git", d.name);
    try testing.expectEqual(Op.any, d.op);
    try testing.expectEqual(@as(?[]const u8, null), d.version);
    try testing.expect(!d.is_soname);
}

test "version constraints" {
    const ge = Dep.parse("go>=1.24");
    try testing.expectEqualStrings("go", ge.name);
    try testing.expectEqual(Op.ge, ge.op);
    try testing.expectEqualStrings("1.24", ge.version.?);

    const gt = Dep.parse("pacman>6.1");
    try testing.expectEqualStrings("pacman", gt.name);
    try testing.expectEqual(Op.gt, gt.op);
    try testing.expectEqualStrings("6.1", gt.version.?);

    const le = Dep.parse("glibc<=2.36");
    try testing.expectEqual(Op.le, le.op);
    try testing.expectEqualStrings("2.36", le.version.?);

    const lt = Dep.parse("foo<2");
    try testing.expectEqual(Op.lt, lt.op);
    try testing.expectEqualStrings("2", lt.version.?);
}

test "soname with abi" {
    const d = Dep.parse("libcurl.so=4-64");
    try testing.expect(d.is_soname);
    try testing.expectEqualStrings("libcurl.so", d.name);
    try testing.expectEqual(Op.eq, d.op);
    try testing.expectEqualStrings("4-64", d.version.?);
}

test "bare soname carries no abi" {
    const d = Dep.parse("libcurl.so");
    try testing.expect(d.is_soname);
    try testing.expectEqualStrings("libcurl.so", d.name);
    try testing.expectEqual(Op.any, d.op);
}

test "epoch in version is preserved" {
    const d = Dep.parse("libgit2>=1:1.9.6-1");
    try testing.expectEqualStrings("libgit2", d.name);
    try testing.expectEqualStrings("1:1.9.6-1", d.version.?);
}

test "surrounding whitespace is trimmed" {
    const d = Dep.parse("  git  ");
    try testing.expectEqualStrings("git", d.name);
}

test "operator with empty operand is unconstrained" {
    const d = Dep.parse("foo>=");
    try testing.expectEqualStrings("foo", d.name);
    try testing.expectEqual(@as(?[]const u8, null), d.version);
}
