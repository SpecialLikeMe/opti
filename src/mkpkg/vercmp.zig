//! Arch version comparison, matching pacman's `vercmp`.
//!
//! Versions look like `[epoch:]pkgver[-pkgrel]`. Comparison walks both strings
//! in parallel, splitting them into runs of digits and runs of letters:
//! numeric runs compare as numbers, alphabetic runs as text, and a numeric run
//! always outranks an alphabetic one. This is why `1.0` is newer than `1.0a` —
//! a trailing alphabetic run loses to nothing at all, which is how release
//! candidates sort below their release.
//!
//! Required before any dependency constraint can be evaluated: `.SRCINFO` says
//! `go>=1.24`, and deciding whether an installed `go` satisfies that is exactly
//! this comparison.

const std = @import("std");
const dep = @import("dep.zig");

const Order = std.math.Order;

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isAlnum(c: u8) bool {
    return isDigit(c) or isAlpha(c);
}

fn stripLeadingZeros(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and s[i] == '0') i += 1;
    return s[i..];
}

/// Compare two full version strings, epoch and pkgrel included.
pub fn compare(a: []const u8, b: []const u8) Order {
    const va = split(a);
    const vb = split(b);

    const epoch = compareFragment(va.epoch, vb.epoch);
    if (epoch != .eq) return epoch;

    const ver = compareFragment(va.version, vb.version);
    if (ver != .eq) return ver;

    // pacman only compares pkgrel when both sides specify one, so `1.0`
    // and `1.0-2` are considered equal rather than the latter being newer.
    if (va.release) |ra| {
        if (vb.release) |rb| return compareFragment(ra, rb);
    }
    return .eq;
}

const Parts = struct {
    epoch: []const u8,
    version: []const u8,
    release: ?[]const u8,
};

fn split(s: []const u8) Parts {
    var rest = s;
    var epoch: []const u8 = "0";

    if (std.mem.indexOfScalar(u8, rest, ':')) |i| {
        epoch = rest[0..i];
        rest = rest[i + 1 ..];
    }

    var release: ?[]const u8 = null;
    if (std.mem.lastIndexOfScalar(u8, rest, '-')) |i| {
        release = rest[i + 1 ..];
        rest = rest[0..i];
    }

    return .{ .epoch = epoch, .version = rest, .release = release };
}

/// Compare one `pkgver`-shaped fragment, ignoring epoch and pkgrel structure.
fn compareFragment(a: []const u8, b: []const u8) Order {
    if (std.mem.eql(u8, a, b)) return .eq;

    var i: usize = 0;
    var j: usize = 0;

    while (i < a.len and j < b.len) {
        while (i < a.len and !isAlnum(a[i])) i += 1;
        while (j < b.len and !isAlnum(b[j])) j += 1;
        if (i >= a.len or j >= b.len) break;

        const a_start = i;
        const b_start = j;
        const numeric = isDigit(a[i]);

        if (numeric) {
            while (i < a.len and isDigit(a[i])) i += 1;
            while (j < b.len and isDigit(b[j])) j += 1;
        } else {
            while (i < a.len and isAlpha(a[i])) i += 1;
            while (j < b.len and isAlpha(b[j])) j += 1;
        }

        const seg_a = a[a_start..i];
        const seg_b = b[b_start..j];

        // The runs are of different kinds: `b` had letters where `a` had
        // digits, or vice versa. Numeric always wins.
        if (seg_b.len == 0) return if (numeric) .gt else .lt;

        if (numeric) {
            // With leading zeros gone, the longer run is the larger number.
            const ta = stripLeadingZeros(seg_a);
            const tb = stripLeadingZeros(seg_b);
            if (ta.len != tb.len) return if (ta.len > tb.len) .gt else .lt;
            const ord = std.mem.order(u8, ta, tb);
            if (ord != .eq) return ord;
            continue;
        }

        const ord = std.mem.order(u8, seg_a, seg_b);
        if (ord != .eq) return ord;
    }

    const a_left = i < a.len;
    const b_left = j < b.len;
    if (!a_left and !b_left) return .eq;

    // A trailing alphabetic run is older than nothing, so `1.0a` < `1.0`.
    if ((!a_left and !isAlpha(b[j])) or (a_left and isAlpha(a[i]))) return .lt;
    return .gt;
}

/// Whether `have` satisfies the constraint carried by `want`.
pub fn satisfies(have: []const u8, want: dep.Dep) bool {
    const constraint = want.version orelse return true;
    return switch (want.op) {
        .any => true,
        .eq => compare(have, constraint) == .eq,
        .lt => compare(have, constraint) == .lt,
        .le => compare(have, constraint) != .gt,
        .gt => compare(have, constraint) == .gt,
        .ge => compare(have, constraint) != .lt,
    };
}

const testing = std.testing;

test "equal versions" {
    try testing.expectEqual(Order.eq, compare("1.0", "1.0"));
    try testing.expectEqual(Order.eq, compare("1.0-1", "1.0-1"));
}

test "numeric ordering" {
    try testing.expectEqual(Order.lt, compare("1.0", "1.1"));
    try testing.expectEqual(Order.gt, compare("1.1", "1.0"));
    try testing.expectEqual(Order.lt, compare("1.0", "1.0.1"));
    try testing.expectEqual(Order.gt, compare("1.0.1", "1.0"));
    try testing.expectEqual(Order.lt, compare("20240101", "20240102"));
}

test "numeric segments ignore leading zeros" {
    try testing.expectEqual(Order.eq, compare("1.007", "1.7"));
    try testing.expectEqual(Order.lt, compare("1.007", "1.8"));
}

test "digits outrank letters" {
    try testing.expectEqual(Order.gt, compare("1.1", "1.a"));
    try testing.expectEqual(Order.lt, compare("1.a", "1.1"));
}

test "trailing letters sort below the bare release" {
    try testing.expectEqual(Order.lt, compare("1.0a", "1.0"));
    try testing.expectEqual(Order.gt, compare("1.0", "1.0a"));
}

test "epoch dominates version" {
    try testing.expectEqual(Order.gt, compare("1:1.0", "2.0"));
    try testing.expectEqual(Order.lt, compare("2.0", "1:1.0"));
    try testing.expectEqual(Order.gt, compare("2:1.0", "1:9.9"));
}

test "pkgrel breaks ties" {
    try testing.expectEqual(Order.lt, compare("1.0-1", "1.0-2"));
    try testing.expectEqual(Order.gt, compare("1.0-2", "1.0-1"));
}

test "pkgrel ignored when either side omits it" {
    try testing.expectEqual(Order.eq, compare("1.0", "1.0-2"));
    try testing.expectEqual(Order.eq, compare("1.0-2", "1.0"));
}

test "real arch versions" {
    try testing.expectEqual(Order.lt, compare("8.21.0-1", "8.22.0-1"));
    try testing.expectEqual(Order.gt, compare("1:1.9.6-1", "1.9.6-1"));
}

test "satisfies evaluates constraints" {
    try testing.expect(satisfies("1.24", dep.Dep.parse("go>=1.24")));
    try testing.expect(satisfies("1.25", dep.Dep.parse("go>=1.24")));
    try testing.expect(!satisfies("1.23", dep.Dep.parse("go>=1.24")));

    try testing.expect(satisfies("6.2", dep.Dep.parse("pacman>6.1")));
    try testing.expect(!satisfies("6.1", dep.Dep.parse("pacman>6.1")));

    try testing.expect(satisfies("2.36", dep.Dep.parse("glibc<=2.36")));
    try testing.expect(!satisfies("2.37", dep.Dep.parse("glibc<=2.36")));
}

test "unconstrained dependency is always satisfied" {
    try testing.expect(satisfies("anything", dep.Dep.parse("git")));
}

test "soname abi must match exactly" {
    const d = dep.Dep.parse("libcurl.so=4-64");
    try testing.expect(satisfies("4-64", d));
    try testing.expect(!satisfies("5-64", d));
}
