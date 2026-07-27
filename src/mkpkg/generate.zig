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

/// Variables a split package may override inside its `package_<name>()` body.
const override_scalars = "pkgdesc url install changelog";
const override_arrays =
    "groups license depends optdepends provides conflicts replaces backup options";

/// Pull variable assignments out of a function body.
///
/// Split PKGBUILDs declare per-package metadata *inside* `package_<name>()`,
/// so it cannot be read by sourcing the file alone. `declare -f` prints the
/// body; this scans it for assignments to the known variables and tracks
/// parenthesis depth so multi-line array literals are captured whole.
const extract_fn =
    \\extract_pkg_vars() {
    \\  declare -f "$1" 2>/dev/null | awk '
    \\    BEGIN { grab = 0; depth = 0 }
    \\    {
    \\      line = $0
    \\      if (!grab && match(line, /^[ \t]*(pkgdesc|url|install|changelog|groups|license|depends|optdepends|provides|conflicts|replaces|backup|options)\+?=/)) {
    \\        grab = 1; depth = 0
    \\      }
    \\      if (grab) {
    \\        print line
    \\        tmp = line
    \\        opens = gsub(/\(/, "(", tmp)
    \\        closes = gsub(/\)/, ")", tmp)
    \\        depth += opens - closes
    \\        if (depth <= 0) grab = 0
    \\      }
    \\    }'
    \\}
;

const script = extract_fn ++
    \\
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
    \\    (
    \\      # A subshell with the inherited values cleared, so only what the
    \\      # package function itself sets is emitted as an override.
    \\      unset $OPTI_OVERRIDE_SCALARS $OPTI_OVERRIDE_ARRAYS
    \\      vars="$(extract_pkg_vars "package_$p")"
    \\      [ -n "$vars" ] && eval "$vars"
    \\      for k in $OPTI_OVERRIDE_SCALARS; do
    \\        v="${!k}"
    \\        [ -n "$v" ] && printf '\t%s = %s\n' "$k" "$v"
    \\      done
    \\      for k in $OPTI_OVERRIDE_ARRAYS; do
    \\        eval "items=(\"\${$k[@]}\")"
    \\        for item in "${items[@]}"; do
    \\          [ -n "$item" ] && printf '\t%s = %s\n' "$k" "$item"
    \\        done
    \\      done
    \\    )
    \\  done
    \\} > "$OPTI_SRCINFO_OUT"
;

/// Produce `.SRCINFO` text for `pkgbuild`. Caller owns the result.
///
/// Split-package overrides declared inside `package_<name>()` bodies are
/// extracted too, so the generated metadata matches what the build produces.
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
    try env.put("OPTI_OVERRIDE_SCALARS", override_scalars);
    try env.put("OPTI_OVERRIDE_ARRAYS", override_arrays);

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
