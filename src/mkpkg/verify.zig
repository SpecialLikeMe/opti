//! Source integrity verification.
//!
//! PKGBUILDs may carry several checksum arrays at once. makepkg validates the
//! strongest one present, and treats the literal `SKIP` as "no check for this
//! source" — used for VCS sources and for files covered by a PGP signature.

const std = @import("std");

pub const Error = error{ ChecksumMismatch, DigestTooLong };

/// Sentinel meaning "do not verify this source".
pub const skip = "SKIP";

pub const Algorithm = enum {
    md5,
    sha1,
    sha224,
    sha256,
    sha384,
    sha512,
    b2,

    /// Ordering used to pick which array to validate when several are present.
    pub fn strength(a: Algorithm) u8 {
        return switch (a) {
            .md5 => 0,
            .sha1 => 1,
            .sha224 => 2,
            .sha256 => 3,
            .sha384 => 4,
            .sha512 => 5,
            .b2 => 6,
        };
    }

    /// The `.SRCINFO`/PKGBUILD array name for this algorithm.
    pub fn keyName(a: Algorithm) []const u8 {
        return switch (a) {
            .md5 => "md5sums",
            .sha1 => "sha1sums",
            .sha224 => "sha224sums",
            .sha256 => "sha256sums",
            .sha384 => "sha384sums",
            .sha512 => "sha512sums",
            .b2 => "b2sums",
        };
    }

    pub fn fromKeyName(key: []const u8) ?Algorithm {
        inline for (@typeInfo(Algorithm).@"enum".fields) |f| {
            const a: Algorithm = @enumFromInt(f.value);
            if (std.mem.eql(u8, key, a.keyName())) return a;
        }
        return null;
    }
};

/// Longest digest produced here is BLAKE2b-512: 64 bytes -> 128 hex chars.
pub const max_hex_len = 128;

/// Write the lowercase hex digest of `data` into `buf`.
pub fn hexDigest(alg: Algorithm, data: []const u8, buf: []u8) Error![]const u8 {
    const crypto = std.crypto.hash;
    return switch (alg) {
        .md5 => digest(crypto.Md5, data, buf),
        .sha1 => digest(crypto.Sha1, data, buf),
        .sha224 => digest(crypto.sha2.Sha224, data, buf),
        .sha256 => digest(crypto.sha2.Sha256, data, buf),
        .sha384 => digest(crypto.sha2.Sha384, data, buf),
        .sha512 => digest(crypto.sha2.Sha512, data, buf),
        .b2 => digest(crypto.blake2.Blake2b512, data, buf),
    };
}

fn digest(comptime H: type, data: []const u8, buf: []u8) Error![]const u8 {
    var raw: [H.digest_length]u8 = undefined;
    H.hash(data, &raw, .{});

    if (buf.len < raw.len * 2) return Error.DigestTooLong;
    // Formatted by hand rather than via std.fmt so this stays insulated from
    // format-specifier churn across Zig releases.
    const hex = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        buf[i * 2] = hex[b >> 4];
        buf[i * 2 + 1] = hex[b & 0xf];
    }
    return buf[0 .. raw.len * 2];
}

/// Verify `data` against `expected`. Checksums are compared case-insensitively
/// because PKGBUILDs in the wild use both cases.
pub fn verify(alg: Algorithm, data: []const u8, expected: []const u8) Error!void {
    if (std.mem.eql(u8, expected, skip)) return;

    var buf: [max_hex_len]u8 = undefined;
    const actual = try hexDigest(alg, data, &buf);
    if (!std.ascii.eqlIgnoreCase(actual, expected)) return Error.ChecksumMismatch;
}

const testing = std.testing;

test "sha256 of known input" {
    var buf: [max_hex_len]u8 = undefined;
    const got = try hexDigest(.sha256, "abc", &buf);
    try testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        got,
    );
}

test "md5 of known input" {
    var buf: [max_hex_len]u8 = undefined;
    const got = try hexDigest(.md5, "abc", &buf);
    try testing.expectEqualStrings("900150983cd24fb0d6963f7d28e17f72", got);
}

test "verify accepts matching digest in either case" {
    try verify(.sha256, "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    try verify(.sha256, "abc", "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD");
}

test "verify rejects a mismatch" {
    try testing.expectError(Error.ChecksumMismatch, verify(.sha256, "abc", "deadbeef"));
}

test "SKIP bypasses verification" {
    try verify(.sha256, "anything at all", skip);
}

test "algorithm key names round-trip" {
    try testing.expectEqual(Algorithm.sha256, Algorithm.fromKeyName("sha256sums").?);
    try testing.expectEqual(Algorithm.b2, Algorithm.fromKeyName("b2sums").?);
    try testing.expectEqual(@as(?Algorithm, null), Algorithm.fromKeyName("depends"));
}

test "b2 is preferred over sha256" {
    try testing.expect(Algorithm.b2.strength() > Algorithm.sha256.strength());
    try testing.expect(Algorithm.sha256.strength() > Algorithm.md5.strength());
}
