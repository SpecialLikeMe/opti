//! Source acquisition: the `source=()` array turned into a populated $srcdir.
//!
//! For each entry: resolve its local filename, obtain the bytes (download,
//! VCS clone, or read from the PKGBUILD directory), verify it against the
//! checksum array, then either unpack it or copy it through.
//!
//! Downloads are cached next to the PKGBUILD so a rebuild does not refetch,
//! matching makepkg's behaviour.

const std = @import("std");
const io = @import("../io.zig");
const srcinfo = @import("srcinfo.zig");
const verify = @import("verify.zig");
const fetch = @import("fetch.zig");
const extract = @import("extract.zig");
const signature = @import("signature.zig");
const exec = @import("exec.zig");
const git = @import("../install/get.zig");

pub const Error = error{
    ChecksumMissing,
    UnsupportedSource,
};

/// Whether `location` names something to download rather than a local file.
pub fn isRemote(location: []const u8) bool {
    for ([_][]const u8{ "http://", "https://", "ftp://", "ftps://" }) |scheme| {
        if (std.mem.startsWith(u8, location, scheme)) return true;
    }
    return false;
}

/// The filename a source is stored under: the explicit `name::` rename when
/// given, otherwise the final path segment of the location.
pub fn localName(source: srcinfo.Source) []const u8 {
    if (source.rename) |r| return r;
    var end = source.location.len;
    while (end > 0 and source.location[end - 1] == '/') end -= 1;
    return std.fs.path.basename(source.location[0..end]);
}

/// Download, verify and unpack every source into `srcdir`.
pub fn acquire(
    gpa: std.mem.Allocator,
    io_ctx: std.Io,
    out: *std.Io.Writer,
    meta: *const srcinfo.SrcInfo,
    startdir: []const u8,
    srcdir: []const u8,
    skip_checksums: bool,
) !void {
    const sums = if (skip_checksums) null else meta.strongestChecksums();

    for (meta.sources, 0..) |source, index| {
        const name = localName(source);

        if (source.vcs) |scheme| {
            try acquireVcs(gpa, io_ctx, out, scheme, source, name, srcdir);
            continue;
        }

        const cache_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ startdir, name });
        defer gpa.free(cache_path);

        const data = try obtain(gpa, io_ctx, out, source, name, cache_path);
        defer gpa.free(data);

        // Detached signatures are neither unpacked nor copied; they are
        // consumed by the verification pass below.
        if (signature.isSignature(name)) continue;

        if (sums) |set| {
            if (index < set.values.len) {
                verify.verify(set.algorithm, data, set.values[index]) catch |err| {
                    try out.print("  {s}: checksum FAILED\n", .{name});
                    return err;
                };
                try out.print("  {s}: {s} ok\n", .{ name, set.algorithm.keyName() });
            }
        }

        // `noextract=()` names sources that must stay packed in $srcdir, e.g.
        // installers a build script feeds to another tool verbatim.
        const skip_extract = for (meta.noextract) |n| {
            if (std.mem.eql(u8, n, name)) break true;
        } else false;

        const format = if (skip_extract) extract.Format.plain else extract.detect(name);
        if (format.isArchive()) {
            try extract.extract(gpa, io_ctx, data, srcdir, format, 1);
            try out.print("  {s}: extracted\n", .{name});
        } else {
            // Patches, .install files and loose sources are copied through so
            // prepare()/build() can reference them by name inside $srcdir.
            const dest = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ srcdir, name });
            defer gpa.free(dest);
            try io.writeFile(io_ctx, dest, data);
            try out.print("  {s}: copied\n", .{name});
        }
        try out.flush();
    }

    try verifySignatures(gpa, io_ctx, out, meta, startdir);
}

/// Verify every detached signature among the sources.
///
/// Runs after acquisition because a `.sig` entry may be listed before the file
/// it covers. Sources guarded by a signature usually carry `SKIP` in the
/// checksum array, so this is their only integrity check — a signature that
/// cannot be verified is therefore an error, not a warning.
fn verifySignatures(
    gpa: std.mem.Allocator,
    io_ctx: std.Io,
    out: *std.Io.Writer,
    meta: *const srcinfo.SrcInfo,
    startdir: []const u8,
) !void {
    for (meta.sources) |source| {
        const name = localName(source);
        if (!signature.isSignature(name)) continue;

        const target = signature.signedTarget(name) orelse continue;

        const sig_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ startdir, name });
        defer gpa.free(sig_path);
        const target_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ startdir, target });
        defer gpa.free(target_path);

        if (!io.exists(io_ctx, target_path)) continue;

        _ = signature.verifyDetached(
            gpa,
            io_ctx,
            sig_path,
            target_path,
            meta.validpgpkeys,
            startdir,
        ) catch |err| {
            try out.print("  {s}: signature {s}\n", .{ name, switch (err) {
                signature.Error.VerifierUnavailable => "UNVERIFIABLE (gpg not installed)",
                signature.Error.UntrustedKey => "signed by a key not in validpgpkeys",
                else => "INVALID",
            } });
            return err;
        };
        try out.print("  {s}: signature ok\n", .{name});
    }
}

/// Read a source from the download cache or the PKGBUILD directory, fetching
/// it first if it is remote and not yet cached.
fn obtain(
    gpa: std.mem.Allocator,
    io_ctx: std.Io,
    out: *std.Io.Writer,
    source: srcinfo.Source,
    name: []const u8,
    cache_path: []const u8,
) ![]u8 {
    if (io.exists(io_ctx, cache_path)) {
        return io.readFile(io_ctx, gpa, cache_path, .limited(1 << 30));
    }

    if (!isRemote(source.location)) return Error.UnsupportedSource;

    try out.print("  {s}: downloading\n", .{name});
    try out.flush();

    const url = try gpa.dupeZ(u8, source.location);
    defer gpa.free(url);

    const data = try fetch.get(gpa, url);
    errdefer gpa.free(data);

    // Cache next to the PKGBUILD so rebuilds skip the network.
    try io.writeFile(io_ctx, cache_path, data);
    return data;
}

/// Clone a `git+`/`svn+`/`hg+`/`bzr+` source.
///
/// git uses libgit2 directly. The others delegate to their own clients, which
/// have no library binding here and are only needed by the small number of
/// PKGBUILDs that use them.
fn acquireVcs(
    gpa: std.mem.Allocator,
    io_ctx: std.Io,
    out: *std.Io.Writer,
    scheme: []const u8,
    source: srcinfo.Source,
    name: []const u8,
    srcdir: []const u8,
) !void {
    if (!std.mem.eql(u8, scheme, "git")) {
        return acquireOtherVcs(gpa, io_ctx, out, scheme, source, name, srcdir);
    }

    const dest = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ srcdir, name }, 0);
    defer gpa.free(dest);

    if (!io.exists(io_ctx, dest)) {
        const url = try gpa.dupeZ(u8, source.location);
        defer gpa.free(url);

        try out.print("  {s}: cloning\n", .{name});
        try out.flush();
        try git.cloneToDir(url, dest, out);
    } else {
        try out.print("  {s}: already cloned\n", .{name});
    }

    // A pinned revision must be checked out, or the build silently uses
    // whatever the default branch currently points at.
    if (source.fragment) |frag| {
        const rev = try gpa.dupeZ(u8, frag.value);
        defer gpa.free(rev);

        try git.checkoutRef(dest, rev, out);
        try out.print("  {s}: checked out {s}={s}\n", .{ name, frag.kind, frag.value });
    }
}

/// Subversion, Mercurial and Bazaar sources, via their own clients.
fn acquireOtherVcs(
    gpa: std.mem.Allocator,
    io_ctx: std.Io,
    out: *std.Io.Writer,
    scheme: []const u8,
    source: srcinfo.Source,
    name: []const u8,
    srcdir: []const u8,
) !void {
    const tool: []const u8 = if (std.mem.eql(u8, scheme, "svn"))
        "svn"
    else if (std.mem.eql(u8, scheme, "hg"))
        "hg"
    else if (std.mem.eql(u8, scheme, "bzr"))
        "bzr"
    else
        return Error.UnsupportedSource;

    if (!exec.exists(io_ctx, tool)) {
        try out.print("  {s}: {s} client not installed\n", .{ name, tool });
        return Error.UnsupportedSource;
    }

    const dest = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ srcdir, name });
    defer gpa.free(dest);

    if (io.exists(io_ctx, dest)) {
        try out.print("  {s}: already checked out\n", .{name});
        return;
    }

    try out.print("  {s}: fetching via {s}\n", .{ name, tool });
    try out.flush();

    // Each client spells "check out into this directory" differently, and each
    // pins a revision with its own flag.
    const rev = if (source.fragment) |f| f.value else null;

    if (std.mem.eql(u8, tool, "svn")) {
        if (rev) |r| {
            const spec = try std.fmt.allocPrint(gpa, "-r{s}", .{r});
            defer gpa.free(spec);
            try exec.check(io_ctx, &.{ "svn", "checkout", spec, source.location, dest }, .{});
        } else {
            try exec.check(io_ctx, &.{ "svn", "checkout", source.location, dest }, .{});
        }
    } else if (std.mem.eql(u8, tool, "hg")) {
        if (rev) |r| {
            try exec.check(io_ctx, &.{ "hg", "clone", "-u", r, source.location, dest }, .{});
        } else {
            try exec.check(io_ctx, &.{ "hg", "clone", source.location, dest }, .{});
        }
    } else {
        if (rev) |r| {
            const spec = try std.fmt.allocPrint(gpa, "-r{s}", .{r});
            defer gpa.free(spec);
            try exec.check(io_ctx, &.{ "bzr", "branch", spec, source.location, dest }, .{});
        } else {
            try exec.check(io_ctx, &.{ "bzr", "branch", source.location, dest }, .{});
        }
    }

    if (rev) |r| try out.print("  {s}: pinned to {s}\n", .{ name, r });
}

const testing = std.testing;

test "remote detection" {
    try testing.expect(isRemote("https://example.com/x.tar.gz"));
    try testing.expect(isRemote("http://example.com/x.tar.gz"));
    try testing.expect(isRemote("ftp://example.com/x.tar.gz"));
    try testing.expect(!isRemote("local-patch.diff"));
    try testing.expect(!isRemote("/abs/path/file"));
}

test "local name uses rename when present" {
    const s: srcinfo.Source = .{
        .rename = "yay-13.0.1.tar.gz",
        .location = "https://github.com/Jguer/yay/archive/v13.0.1.tar.gz",
    };
    try testing.expectEqualStrings("yay-13.0.1.tar.gz", localName(s));
}

test "local name falls back to basename" {
    const s: srcinfo.Source = .{ .location = "https://example.com/a/b/pkg-1.0.tar.xz" };
    try testing.expectEqualStrings("pkg-1.0.tar.xz", localName(s));
}

test "local name ignores trailing slashes" {
    const s: srcinfo.Source = .{ .location = "https://example.com/repo/" };
    try testing.expectEqualStrings("repo", localName(s));
}
