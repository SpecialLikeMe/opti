//! Installing artifacts into the store and removing them again.
//!
//! Installing extracts a `.pkg.tar.*` into its own versioned prefix, records
//! exactly which files landed there, and links executables into the shared
//! `bin/`. Removing replays that record in reverse.
//!
//! Nothing here writes outside `layout.root`, which is what keeps uninstall
//! total: opti never scatters files across the host filesystem, so there is
//! nothing to miss.

const std = @import("std");
const io = @import("../io.zig");
const extract = @import("../mkpkg/extract.zig");
const dep = @import("../mkpkg/dep.zig");
const layout_mod = @import("layout.zig");
const manifest_mod = @import("manifest.zig");

pub const Layout = layout_mod.Layout;
pub const Manifest = manifest_mod.Manifest;

pub const Error = error{
    MissingPkginfo,
    AlreadyInstalled,
    NotInstalled,
};

/// Metadata members carried inside a package but not part of its payload.
const metadata_members = [_][]const u8{
    ".PKGINFO", ".BUILDINFO", ".MTREE", ".INSTALL", ".CHANGELOG",
};

fn isMetadata(name: []const u8) bool {
    for (metadata_members) |m| {
        if (std.mem.eql(u8, name, m)) return true;
    }
    return false;
}

pub const InstallResult = struct {
    name: []const u8,
    version: []const u8,
    file_count: usize,
    link_count: usize,
    size: u64,
};

/// Extract `artifact` into the store and record what it owns.
pub fn install(
    gpa: std.mem.Allocator,
    io_ctx: std.Io,
    lay: Layout,
    artifact: []const u8,
    out: *std.Io.Writer,
) !InstallResult {
    const data = try io.readFile(io_ctx, gpa, artifact, .limited(1 << 31));
    defer gpa.free(data);

    // Unpack into a staging directory first: the final prefix depends on the
    // version, which is only known once .PKGINFO has been read.
    const staging = try std.fmt.allocPrint(gpa, "{s}/cache/.staging", .{lay.root});
    defer gpa.free(staging);
    io.removeTree(io_ctx, staging) catch {};
    try io.makePath(io_ctx, staging);
    errdefer io.removeTree(io_ctx, staging) catch {};

    const format = extract.detect(artifact);
    // Package payloads are already rooted at usr/, etc/ — nothing to strip.
    try extract.extract(gpa, io_ctx, data, staging, format, 0);

    const info_path = try std.fmt.allocPrint(gpa, "{s}/.PKGINFO", .{staging});
    defer gpa.free(info_path);
    if (!io.exists(io_ctx, info_path)) return Error.MissingPkginfo;

    const info = try io.readFile(io_ctx, gpa, info_path, .limited(1 << 20));
    defer gpa.free(info);

    const name = manifest_mod.pkginfoField(info, "pkgname") orelse return Error.MissingPkginfo;
    const version = manifest_mod.pkginfoField(info, "pkgver") orelse return Error.MissingPkginfo;
    const arch = manifest_mod.pkginfoField(info, "arch") orelse "any";
    const desc = manifest_mod.pkginfoField(info, "pkgdesc") orelse "";

    const depends = try manifest_mod.pkginfoList(gpa, info, "depend");
    defer gpa.free(depends);

    const prefix = try lay.store(gpa, name, version);
    defer gpa.free(prefix);

    if (io.exists(io_ctx, prefix)) return Error.AlreadyInstalled;

    // Drop the metadata members; only the payload belongs in the prefix.
    for (metadata_members) |member| {
        const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ staging, member });
        defer gpa.free(p);
        std.Io.Dir.cwd().deleteFile(io_ctx, p) catch {};
    }

    if (std.fs.path.dirname(prefix)) |parent| try io.makePath(io_ctx, parent);
    try std.Io.Dir.renameAbsolute(staging, prefix, io_ctx);

    const files = try collectFiles(gpa, io_ctx, prefix);
    defer freeList(gpa, files);

    var size: u64 = 0;
    for (files) |rel| {
        const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ prefix, rel });
        defer gpa.free(full);
        const st = std.Io.Dir.cwd().statFile(io_ctx, full, .{}) catch continue;
        size += st.size;
    }

    const links = try linkBinaries(gpa, io_ctx, lay, prefix, files);
    defer freeList(gpa, links);

    var arena = std.heap.ArenaAllocator.init(gpa);
    const record: Manifest = .{
        .arena = arena,
        .name = name,
        .version = version,
        .arch = arch,
        .description = desc,
        .installed_at = @intCast(std.Io.Timestamp.now(io_ctx, .real).toSeconds()),
        .size = size,
        .prefix = prefix,
        .depends = depends,
        .files = files,
        .links = links,
    };

    const text = try record.render(gpa);
    defer gpa.free(text);
    arena.deinit();

    const db_dir = try lay.db(gpa, name);
    defer gpa.free(db_dir);
    try io.makePath(io_ctx, db_dir);

    const manifest_path = try lay.manifest(gpa, name);
    defer gpa.free(manifest_path);
    try io.writeFile(io_ctx, manifest_path, text);

    try out.print("installed {s} {s} -> {s}\n", .{ name, version, prefix });

    return .{
        .name = name,
        .version = version,
        .file_count = files.len,
        .link_count = links.len,
        .size = size,
    };
}

/// Every regular file and symlink under `prefix`, relative to it.
fn collectFiles(gpa: std.mem.Allocator, io_ctx: std.Io, prefix: []const u8) ![][]const u8 {
    var dir = try std.Io.Dir.cwd().openDir(io_ctx, prefix, .{ .iterate = true });
    defer dir.close(io_ctx);

    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io_ctx)) |entry| {
        if (entry.kind == .directory) continue;
        try out.append(gpa, try gpa.dupe(u8, entry.path));
    }
    return out.toOwnedSlice(gpa);
}

fn freeList(gpa: std.mem.Allocator, items: []const []const u8) void {
    for (items) |s| gpa.free(s);
    gpa.free(items);
}

/// Symlink the package's executables into the shared bin/ directory.
fn linkBinaries(
    gpa: std.mem.Allocator,
    io_ctx: std.Io,
    lay: Layout,
    prefix: []const u8,
    files: []const []const u8,
) ![][]const u8 {
    const bin_dir = try lay.bin(gpa);
    defer gpa.free(bin_dir);
    try io.makePath(io_ctx, bin_dir);

    var links: std.ArrayList([]const u8) = .empty;
    errdefer links.deinit(gpa);

    const lib_dir = try lay.lib(gpa);
    defer gpa.free(lib_dir);
    try io.makePath(io_ctx, lib_dir);

    for (files) |rel| {
        const is_bin = std.mem.startsWith(u8, rel, "usr/bin/") or
            std.mem.startsWith(u8, rel, "bin/");
        // Shared objects are linked too, so RPATH into the shared lib
        // directory resolves other packages' libraries.
        const is_lib = (std.mem.startsWith(u8, rel, "usr/lib/") or
            std.mem.startsWith(u8, rel, "lib/")) and
            std.mem.indexOf(u8, rel, ".so") != null;

        if (!is_bin and !is_lib) continue;

        const base = std.fs.path.basename(rel);
        if (base.len == 0) continue;

        const target = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ prefix, rel });
        defer gpa.free(target);
        const link_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{
            if (is_bin) bin_dir else lib_dir,
            base,
        });
        defer gpa.free(link_path);

        // Last install wins, matching how a later package shadows an earlier
        // one on PATH.
        std.Io.Dir.cwd().deleteFile(io_ctx, link_path) catch {};
        std.Io.Dir.cwd().symLink(io_ctx, target, link_path, .{}) catch continue;

        // Recorded relative to the store root, so removal knows which farm the
        // link went into.
        try links.append(gpa, try std.fmt.allocPrint(gpa, "{s}/{s}", .{
            if (is_bin) "bin" else "lib",
            base,
        }));
    }
    return links.toOwnedSlice(gpa);
}

/// Read a package's install record.
pub fn read(
    gpa: std.mem.Allocator,
    io_ctx: std.Io,
    lay: Layout,
    name: []const u8,
) !Manifest {
    const path = try lay.manifest(gpa, name);
    defer gpa.free(path);

    if (!io.exists(io_ctx, path)) return Error.NotInstalled;

    const text = try io.readFile(io_ctx, gpa, path, .limited(1 << 24));
    defer gpa.free(text);
    return manifest_mod.parse(gpa, text);
}

/// Installed packages that declare a dependency on `name`.
///
/// Depends are recorded at install time but were never consulted; without this
/// check, removing a library silently breaks everything linked against it.
/// Caller owns the returned names.
pub fn requiredBy(
    gpa: std.mem.Allocator,
    io_ctx: std.Io,
    lay: Layout,
    name: []const u8,
) ![][]const u8 {
    const installed = try list(gpa, io_ctx, lay);
    defer freeList(gpa, installed);

    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);

    for (installed) |other| {
        if (std.mem.eql(u8, other, name)) continue;

        var record = read(gpa, io_ctx, lay, other) catch continue;
        defer record.deinit();

        for (record.depends) |spec| {
            // Compare on the bare name: the recorded spec may carry a version
            // constraint, as in `openssl>=3`.
            const d = dep.Dep.parse(spec);
            if (std.mem.eql(u8, d.name, name)) {
                try out.append(gpa, try gpa.dupe(u8, other));
                break;
            }
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Remove a package: its links, its prefix, then its record.
pub fn remove(
    gpa: std.mem.Allocator,
    io_ctx: std.Io,
    lay: Layout,
    name: []const u8,
    out: *std.Io.Writer,
) !void {
    var record = try read(gpa, io_ctx, lay, name);
    defer record.deinit();

    for (record.links) |link| {
        const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ lay.root, link });
        defer gpa.free(p);
        std.Io.Dir.cwd().deleteFile(io_ctx, p) catch {};
    }

    // The prefix is self-contained, so this removes every file the package
    // owns without consulting the file list.
    if (record.prefix.len > 0) io.removeTree(io_ctx, record.prefix) catch {};

    const db_dir = try lay.db(gpa, name);
    defer gpa.free(db_dir);
    io.removeTree(io_ctx, db_dir) catch {};

    try out.print("removed {s} {s} ({d} files)\n", .{ name, record.version, record.files.len });
}

/// Names of every installed package, sorted.
pub fn list(gpa: std.mem.Allocator, io_ctx: std.Io, lay: Layout) ![][]const u8 {
    const db_root = try lay.dbRoot(gpa);
    defer gpa.free(db_root);

    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);

    var dir = std.Io.Dir.cwd().openDir(io_ctx, db_root, .{ .iterate = true }) catch {
        return out.toOwnedSlice(gpa);
    };
    defer dir.close(io_ctx);

    var it = dir.iterate();
    while (try it.next(io_ctx)) |entry| {
        if (entry.kind != .directory) continue;
        try out.append(gpa, try gpa.dupe(u8, entry.name));
    }

    const names = try out.toOwnedSlice(gpa);
    std.mem.sort([]const u8, names, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return names;
}

const testing = std.testing;

test "metadata members are recognised" {
    try testing.expect(isMetadata(".PKGINFO"));
    try testing.expect(isMetadata(".MTREE"));
    try testing.expect(isMetadata(".INSTALL"));
    try testing.expect(!isMetadata("usr/bin/curl"));
    try testing.expect(!isMetadata(".hidden-real-file"));
}
