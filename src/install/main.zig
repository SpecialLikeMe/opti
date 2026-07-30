//! Fetching PKGBUILD sources from the AUR.
//!
//! Checkouts land in the source cache, never in the store: one is an input to
//! a build, the other is what got installed.

const std = @import("std");
const io = @import("../io.zig");
const get = @import("get.zig");

/// AUR git endpoint. Official-repo resolution is deliberately not wired up
/// yet: lookups must try the official repos (by name, then by `provides`)
/// before falling back to the AUR, or common libraries resolve to variant
/// packages such as `-git` builds.
const aur_git_base = "https://aur.archlinux.org";

pub const Error = error{PackageNotFound};

/// Clone `pkg` from the AUR into `dest`, refreshing an existing checkout.
/// Returns once `dest` holds a PKGBUILD.
pub fn fetch(
    gpa: std.mem.Allocator,
    io_ctx: std.Io,
    out: *std.Io.Writer,
    pkg: []const u8,
    dest: [:0]const u8,
) !void {
    const url = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}.git", .{ aur_git_base, pkg }, 0);
    defer gpa.free(url);

    // A stale checkout would silently build an old revision, so start clean.
    io.removeTree(io_ctx, dest) catch {};
    if (std.fs.path.dirname(dest)) |parent| try io.makePath(io_ctx, parent);

    try out.print("fetching {s}\n", .{url});
    try out.flush();

    try get.cloneToDir(url, dest, out);

    // The AUR git server serves an empty repository for *any* name, so a
    // successful clone proves nothing about whether the package exists. A
    // real package always carries a PKGBUILD at the repository root.
    const pkgbuild = try std.fmt.allocPrint(gpa, "{s}/PKGBUILD", .{dest});
    defer gpa.free(pkgbuild);

    if (!io.exists(io_ctx, pkgbuild)) {
        io.removeTree(io_ctx, dest) catch {};
        try out.print("package not found in the AUR: {s}\n", .{pkg});
        return Error.PackageNotFound;
    }
}

/// Whether `arg` names a local PKGBUILD directory rather than an AUR package.
pub fn isLocalDir(io_ctx: std.Io, arg: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const probe = std.fmt.bufPrint(&buf, "{s}/PKGBUILD", .{arg}) catch return false;
    return io.exists(io_ctx, probe);
}
