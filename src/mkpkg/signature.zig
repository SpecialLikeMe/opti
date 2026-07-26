//! PGP signature verification for sources.
//!
//! A PKGBUILD may ship a detached signature alongside a tarball (`foo.tar.gz`
//! plus `foo.tar.gz.sig`), listing the acceptable signing keys in
//! `validpgpkeys`. Such sources normally carry `SKIP` in the checksum array,
//! because the signature is the integrity check — so skipping verification
//! here would leave them checked by nothing at all.
//!
//! Verification delegates to `gpg`. There is no PGP implementation in std, and
//! reimplementing one would be a poor trade against a tool that is present
//! wherever signed sources are actually used. When `gpg` is absent, a signed
//! source is reported rather than silently accepted.

const std = @import("std");
const exec = @import("exec.zig");
const srcinfo = @import("srcinfo.zig");

pub const Error = error{
    SignatureInvalid,
    /// A detached signature exists but no verifier is installed.
    VerifierUnavailable,
};

pub const Outcome = enum {
    /// Signature present and valid.
    valid,
    /// Nothing to verify for this source.
    absent,
};

/// Whether `name` is a detached signature rather than a payload.
pub fn isSignature(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".sig") or
        std.mem.endsWith(u8, name, ".asc") or
        std.mem.endsWith(u8, name, ".sign");
}

/// The payload a signature covers, e.g. `foo.tar.gz.sig` -> `foo.tar.gz`.
pub fn signedTarget(name: []const u8) ?[]const u8 {
    inline for (.{ ".sig", ".asc", ".sign" }) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return name[0 .. name.len - ext.len];
    }
    return null;
}

/// Verify `signature_path` against `target_path`.
pub fn verifyDetached(
    io: std.Io,
    signature_path: []const u8,
    target_path: []const u8,
) !Outcome {
    if (!exec.exists(io, "gpg")) return Error.VerifierUnavailable;

    const status = try exec.run(io, &.{
        "gpg", "--batch", "--quiet", "--verify", signature_path, target_path,
    }, .{});

    if (status != 0) return Error.SignatureInvalid;
    return .valid;
}

const testing = std.testing;

test "signature filenames are recognised" {
    try testing.expect(isSignature("foo-1.0.tar.gz.sig"));
    try testing.expect(isSignature("foo-1.0.tar.gz.asc"));
    try testing.expect(isSignature("foo-1.0.tar.gz.sign"));
    try testing.expect(!isSignature("foo-1.0.tar.gz"));
}

test "signed target is derived" {
    try testing.expectEqualStrings("foo.tar.gz", signedTarget("foo.tar.gz.sig").?);
    try testing.expectEqualStrings("foo.tar.xz", signedTarget("foo.tar.xz.asc").?);
    try testing.expectEqual(@as(?[]const u8, null), signedTarget("foo.tar.gz"));
}
