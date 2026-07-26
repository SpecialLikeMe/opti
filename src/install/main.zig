const std = @import("std");
const io = @import("../io.zig");
const get = @import("get.zig");

/// AUR git endpoint. Official-repo resolution is deliberately not wired up
/// yet: lookups must try the official repos (by name, then by `provides`)
/// before falling back to the AUR, or common libraries resolve to variant
/// packages such as `-git` builds.
const aur_git_base = "https://aur.archlinux.org";

/// Root of the shared, machine-wide store. Packages are installed here rather
/// than system-wide so uninstall stays a directory removal.
const store_root = "/var/lib/opti/store";

pub const Error = error{PackageNotFound};

pub fn run(
    gpa: std.mem.Allocator,
    io_ctx: std.Io,
    out: *std.Io.Writer,
    pkg: []const u8,
) !void {
    const url = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}.git", .{ aur_git_base, pkg }, 0);
    defer gpa.free(url);

    const dir = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ store_root, pkg }, 0);
    defer gpa.free(dir);

    try out.print("fetching {s}\n", .{url});
    try out.flush();

    try get.cloneToDir(url, dir, out);

    // The AUR git server serves an empty repository for *any* name, so a
    // successful clone proves nothing about whether the package exists. A
    // real package always carries a PKGBUILD at the repository root.
    const pkgbuild = try std.fmt.allocPrint(gpa, "{s}/PKGBUILD", .{dir});
    defer gpa.free(pkgbuild);

    if (!io.exists(io_ctx, pkgbuild)) {
        io.removeTree(io_ctx, dir) catch {};
        try out.print("package not found in the AUR: {s}\n", .{pkg});
        return Error.PackageNotFound;
    }

    try out.print("cloned into {s}\n", .{dir});
}
