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
    /// Signature is cryptographically valid but the signer is not listed in
    /// `validpgpkeys`.
    UntrustedKey,
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

/// Verify `signature_path` against `target_path`, and require the signing key
/// to be one the PKGBUILD authorised.
///
/// A bare `gpg --verify` only proves *someone* signed the file with a key in
/// the local keyring. `validpgpkeys` is what names the specific upstream
/// signers, so without checking it any attacker-supplied key that happens to
/// be trusted locally would pass. When the list is empty the PKGBUILD has
/// expressed no constraint and gpg's own trust decision stands.
pub fn verifyDetached(
    gpa: std.mem.Allocator,
    io: std.Io,
    signature_path: []const u8,
    target_path: []const u8,
    validpgpkeys: []const []const u8,
    workdir: []const u8,
) !Outcome {
    if (!exec.exists(io, "gpg")) return Error.VerifierUnavailable;

    const tmp = try std.fmt.allocPrint(gpa, "{s}/.opti-gpg-status", .{workdir});
    defer gpa.free(tmp);

    // --status-fd=1 emits machine-readable lines; VALIDSIG carries the primary
    // key fingerprint that actually made the signature.
    const command = try std.fmt.allocPrint(
        gpa,
        "gpg --batch --status-fd=1 --verify '{s}' '{s}'",
        .{ signature_path, target_path },
    );
    defer gpa.free(command);

    const status_text = exec.capture(gpa, io, command, tmp) catch return Error.SignatureInvalid;
    defer gpa.free(status_text);

    const fingerprint = validsigFingerprint(status_text) orelse return Error.SignatureInvalid;
    if (validpgpkeys.len == 0) return .valid;

    for (validpgpkeys) |key| {
        if (fingerprintMatches(fingerprint, key)) return .valid;
    }
    return Error.UntrustedKey;
}

/// Extract the fingerprint from a `[GNUPG:] VALIDSIG <fpr> ...` status line.
pub fn validsigFingerprint(status_text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, status_text, '\n');
    while (lines.next()) |line| {
        const marker = "VALIDSIG ";
        const idx = std.mem.indexOf(u8, line, marker) orelse continue;
        const rest = line[idx + marker.len ..];
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        if (end == 0) continue;
        return rest[0..end];
    }
    return null;
}

/// PKGBUILDs list keys as full fingerprints or as long key IDs, so compare on
/// the trailing characters rather than requiring an exact match.
pub fn fingerprintMatches(fingerprint: []const u8, declared: []const u8) bool {
    if (declared.len == 0 or declared.len > fingerprint.len) return false;
    const tail = fingerprint[fingerprint.len - declared.len ..];
    return std.ascii.eqlIgnoreCase(tail, declared);
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

test "VALIDSIG fingerprint is extracted" {
    const status =
        "[GNUPG:] NEWSIG\n" ++
        "[GNUPG:] GOODSIG 584D8B1F5C0C4E5D upstream <a@b.c>\n" ++
        "[GNUPG:] VALIDSIG ABCDEF0123456789ABCDEF0123456789ABCDEF01 2026-01-01 0 4 0 1 8 00\n";
    try testing.expectEqualStrings(
        "ABCDEF0123456789ABCDEF0123456789ABCDEF01",
        validsigFingerprint(status).?,
    );
}

test "no VALIDSIG means unverified" {
    const status = "[GNUPG:] BADSIG 584D8B1F5C0C4E5D upstream\n";
    try testing.expectEqual(@as(?[]const u8, null), validsigFingerprint(status));
}

test "declared key may be a fingerprint or a long id" {
    const fpr = "ABCDEF0123456789ABCDEF0123456789ABCDEF01";
    try testing.expect(fingerprintMatches(fpr, fpr));
    // Long key ID: trailing 16 characters.
    try testing.expect(fingerprintMatches(fpr, "ABCDEF0123456789"[0..0] ++ "89ABCDEF0123456789ABCDEF01"[10..]));
    try testing.expect(fingerprintMatches(fpr, "abcdef01"));
    try testing.expect(!fingerprintMatches(fpr, "DEADBEEF"));
    try testing.expect(!fingerprintMatches(fpr, ""));
}
