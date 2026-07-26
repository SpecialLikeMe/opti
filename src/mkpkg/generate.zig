//! Derive `.SRCINFO`-shaped metadata from a bare PKGBUILD.
//!
//! `.SRCINFO` only exists because the AUR mandates it. A PKGBUILD written
//! locally, or one taken from anywhere else, has no such file — and real
//! makepkg never needs one. This closes that gap by sourcing the PKGBUILD in
//! bash and printing its variables in the same format the parser already
//! understands, which is exactly what `makepkg --printsrcinfo` does.
//!
//! This is the only place metadata extraction executes anything. It is used
//! solely as a fallback: when a `.SRCINFO` is present it is read directly, so
//! resolving dependencies for AUR packages still requires no code execution.

const std = @import("std");
const exec = @import("exec.zig");

pub const Error = error{GenerateFailed};

/// Scalar variables copied straight across.
const scalar_keys = "pkgdesc pkgver pkgrel epoch url install changelog";

/// Array variables. Names match between PKGBUILD and .SRCINFO.
const array_keys =
    "arch license groups depends makedepends checkdepends optdepends " ++
    "provides conflicts replaces options source noextract backup validpgpkeys " ++
    "md5sums sha1sums sha224sums sha256sums sha384sums sha512sums b2sums";

const script =
    \\set -e
    \\source "$OPTI_PKGBUILD"
    \\{
    \\  base="${pkgbase:-${pkgname[0]}}"
    \\  echo "pkgbase = $base"
    \\  for k in $OPTI_SCALARS; do
    \\    v="${!k}"
    \\    [ -n "$v" ] && printf '\t%s = %s\n' "$k" "$v"
    \\  done
    \\  for k in $OPTI_ARRAYS; do
    \\    eval "items=(\"\${$k[@]}\")"
    \\    for item in "${items[@]}"; do
    \\      [ -n "$item" ] && printf '\t%s = %s\n' "$k" "$item"
    \\    done
    \\  done
    \\  for p in "${pkgname[@]}"; do
    \\    printf '\npkgname = %s\n' "$p"
    \\  done
    \\} > "$OPTI_SRCINFO_OUT"
;

/// Produce `.SRCINFO` text for `pkgbuild`. Caller owns the result.
///
/// Split packages declare their per-package overrides *inside* their
/// `package_<name>()` bodies, which are not evaluated here; those still apply
/// at build time but are not reflected in the generated metadata.
pub fn fromPkgbuild(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    pkgbuild: []const u8,
    workdir: []const u8,
) ![]u8 {
    const out_path = try std.fmt.allocPrint(gpa, "{s}/.opti-srcinfo", .{workdir});
    defer gpa.free(out_path);

    try env.put("OPTI_PKGBUILD", pkgbuild);
    try env.put("OPTI_SRCINFO_OUT", out_path);
    try env.put("OPTI_SCALARS", scalar_keys);
    try env.put("OPTI_ARRAYS", array_keys);

    const status = try exec.run(io, &.{ "bash", "-c", script }, .{
        .cwd = workdir,
        .env = env,
    });
    if (status != 0) return Error.GenerateFailed;

    const text = try std.Io.Dir.cwd().readFileAlloc(io, out_path, gpa, .limited(1 << 20));
    errdefer gpa.free(text);

    std.Io.Dir.cwd().deleteFile(io, out_path) catch {};
    return text;
}
