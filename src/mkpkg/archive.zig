//! Package artifact assembly: `.PKGINFO`, `.MTREE`, and the final tarball.
//!
//! Arch's package format is a tar archive whose first members are metadata:
//! `.PKGINFO` (key/value package metadata), `.BUILDINFO`, an optional
//! `.INSTALL`/`.CHANGELOG`, then `.MTREE` (a gzipped mtree listing used to
//! verify installed files), followed by the payload rooted at the filesystem
//! root.
//!
//! Everything is streamed. File contents go from disk into the archive without
//! being held in memory, so peak usage tracks the number of files rather than
//! their total size — a package with a 2 GB payload does not need 2 GB of RAM.
//!
//! Ownership: `std.tar.Writer` emits uid/gid 0 for every member, which is
//! exactly right here — Arch packages are uniformly root-owned, and any
//! non-root ownership is applied post-install by scriptlets. That also means
//! the archive step needs no fakeroot session of its own; fakeroot is required
//! only while `package()` runs so its `chown`/`install -o` calls succeed.

const std = @import("std");
const srcinfo = @import("srcinfo.zig");
const verify = @import("verify.zig");
const exec = @import("exec.zig");

pub const Error = error{EmptyPackage};

pub const Compression = enum {
    none,
    gzip,
    /// Arch's default. std can decompress zstd but not compress it, so this
    /// path shells out to the `zstd` binary and is selected only when that
    /// binary exists; otherwise gzip is used, which is an equally valid PKGEXT.
    zstd,

    pub fn extension(c: Compression) []const u8 {
        return switch (c) {
            .none => ".pkg.tar",
            .gzip => ".pkg.tar.gz",
            .zstd => ".pkg.tar.zst",
        };
    }

    /// Prefer Arch's default when it is achievable on this host.
    pub fn preferred(io: std.Io) Compression {
        return if (exec.exists(io, "zstd")) .zstd else .gzip;
    }
};

/// Everything needed to write a `.PKGINFO`.
pub const Meta = struct {
    pkgname: []const u8,
    pkgbase: []const u8,
    /// Full version, `[epoch:]pkgver-pkgrel`.
    version: []const u8,
    pkgdesc: []const u8 = "",
    url: []const u8 = "",
    arch: []const u8 = "x86_64",
    packager: []const u8 = "opti",
    builddate: i64 = 0,
    licenses: []const []const u8 = &.{},
    depends: []const srcinfo.Dep = &.{},
    provides: []const srcinfo.Dep = &.{},
    conflicts: []const srcinfo.Dep = &.{},
    replaces: []const srcinfo.Dep = &.{},
    /// Config paths pacman preserves across upgrades.
    backup: []const []const u8 = &.{},
    /// `name: reason` entries.
    optdepends: []const []const u8 = &.{},
    groups: []const []const u8 = &.{},
    /// Contents of the `install=` scriptlet, stored as `.INSTALL`.
    install_script: ?[]const u8 = null,
    /// Contents of the `changelog=` file, stored as `.CHANGELOG`.
    changelog: ?[]const u8 = null,
    /// `options=()` as declared, recorded in `.BUILDINFO`.
    options: []const []const u8 = &.{},
};

/// Metadata for one member. Contents are never held here — only what is needed
/// to write the header and the mtree record.
const Entry = struct {
    /// Path relative to $pkgdir, using '/' separators.
    path: []const u8,
    kind: std.Io.File.Kind,
    mode: u32,
    size: u64 = 0,
    /// Target, for symlinks only.
    link_target: []const u8 = &.{},
    /// Lowercase hex, for regular files only.
    sha256: []const u8 = &.{},
    md5: []const u8 = &.{},
};

const digest_chunk = 64 * 1024;

/// Walk the staged image, recording metadata and hashing file contents in a
/// single streaming pass.
fn collect(gpa: std.mem.Allocator, io: std.Io, pkgdir: []const u8) ![]Entry {
    var dir = try std.Io.Dir.cwd().openDir(io, pkgdir, .{ .iterate = true });
    defer dir.close(io);

    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(gpa);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        // statFile follows symlinks, so it must not gate their inclusion: a
        // link to a path that does not exist inside $pkgdir would otherwise be
        // silently dropped from the package.
        var mode: u32 = 0o777;
        var size: u64 = 0;
        if (entry.kind != .sym_link) {
            const stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
            mode = @intCast(@intFromEnum(stat.permissions) & 0o7777);
            size = stat.size;
        }

        const path = try gpa.dupe(u8, entry.path);
        errdefer gpa.free(path);

        var link_target: []const u8 = &.{};
        var sha: []const u8 = &.{};
        var md5: []const u8 = &.{};

        switch (entry.kind) {
            .sym_link => {
                var link_buf: [std.fs.max_path_bytes]u8 = undefined;
                const len = try entry.dir.readLink(io, entry.basename, &link_buf);
                link_target = try gpa.dupe(u8, link_buf[0..len]);
            },
            .file => {
                const digests = try hashFile(gpa, io, entry.dir, entry.basename);
                sha = digests.sha256;
                md5 = digests.md5;
            },
            else => {},
        }

        try entries.append(gpa, .{
            .path = path,
            .kind = entry.kind,
            .mode = mode,
            .size = size,
            .link_target = link_target,
            .sha256 = sha,
            .md5 = md5,
        });
    }

    return entries.toOwnedSlice(gpa);
}

const Digests = struct { sha256: []const u8, md5: []const u8 };

/// Hash a file in chunks rather than reading it whole.
fn hashFile(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
) !Digests {
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    var md5 = std.crypto.hash.Md5.init(.{});

    if (dir.openFile(io, sub_path, .{})) |file| {
        defer file.close(io);
        var buf: [digest_chunk]u8 = undefined;
        while (true) {
            var bufs = [_][]u8{&buf};
            const n = file.readStreaming(io, &bufs) catch break;
            if (n == 0) break;
            sha.update(buf[0..n]);
            md5.update(buf[0..n]);
        }
    } else |_| {}

    var sha_raw: [32]u8 = undefined;
    var md5_raw: [16]u8 = undefined;
    sha.final(&sha_raw);
    md5.final(&md5_raw);

    return .{
        .sha256 = try toHex(gpa, &sha_raw),
        .md5 = try toHex(gpa, &md5_raw),
    };
}

fn toHex(gpa: std.mem.Allocator, raw: []const u8) ![]const u8 {
    const hex = "0123456789abcdef";
    const out = try gpa.alloc(u8, raw.len * 2);
    for (raw, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0xf];
    }
    return out;
}

fn freeEntries(gpa: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| {
        gpa.free(e.path);
        if (e.link_target.len > 0) gpa.free(e.link_target);
        if (e.sha256.len > 0) gpa.free(e.sha256);
        if (e.md5.len > 0) gpa.free(e.md5);
    }
    gpa.free(entries);
}

/// Render `.PKGINFO`.
pub fn renderPkginfo(gpa: std.mem.Allocator, meta: Meta, installed_size: u64) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    const w = &buf.writer;

    try w.print("# Generated by opti\n", .{});
    try w.print("pkgname = {s}\n", .{meta.pkgname});
    try w.print("pkgbase = {s}\n", .{meta.pkgbase});
    try w.print("pkgver = {s}\n", .{meta.version});
    if (meta.pkgdesc.len > 0) try w.print("pkgdesc = {s}\n", .{meta.pkgdesc});
    if (meta.url.len > 0) try w.print("url = {s}\n", .{meta.url});
    try w.print("builddate = {d}\n", .{meta.builddate});
    try w.print("packager = {s}\n", .{meta.packager});
    try w.print("size = {d}\n", .{installed_size});
    try w.print("arch = {s}\n", .{meta.arch});

    for (meta.licenses) |l| try w.print("license = {s}\n", .{l});
    for (meta.depends) |d| try writeDep(w, "depend", d);
    for (meta.provides) |d| try writeDep(w, "provides", d);
    for (meta.conflicts) |d| try writeDep(w, "conflict", d);
    for (meta.replaces) |d| try writeDep(w, "replaces", d);
    for (meta.optdepends) |o| try w.print("optdepend = {s}\n", .{o});
    for (meta.groups) |g| try w.print("group = {s}\n", .{g});
    for (meta.backup) |b| try w.print("backup = {s}\n", .{b});

    return buf.toOwnedSlice();
}

fn writeDep(w: *std.Io.Writer, key: []const u8, d: srcinfo.Dep) !void {
    if (d.version) |v| {
        try w.print("{s} = {s}{s}{s}\n", .{ key, d.name, d.op.text(), v });
    } else {
        try w.print("{s} = {s}\n", .{ key, d.name });
    }
}

/// Render `.BUILDINFO`, the record of how the package was produced.
pub fn renderBuildinfo(gpa: std.mem.Allocator, meta: Meta, builddir: []const u8) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    const w = &buf.writer;

    try w.print("format = 2\n", .{});
    try w.print("pkgname = {s}\n", .{meta.pkgname});
    try w.print("pkgbase = {s}\n", .{meta.pkgbase});
    try w.print("pkgver = {s}\n", .{meta.version});
    try w.print("pkgarch = {s}\n", .{meta.arch});
    try w.print("packager = {s}\n", .{meta.packager});
    try w.print("builddate = {d}\n", .{meta.builddate});
    try w.print("builddir = {s}\n", .{builddir});
    try w.print("buildtool = opti\n", .{});
    for (meta.options) |o| try w.print("options = {s}\n", .{o});

    return buf.toOwnedSlice();
}

/// Fixed timestamp recorded in the manifest, keeping artifacts reproducible
/// rather than embedding the moment of the build.
const mtree_time: u64 = 0;

/// Escapes an mtree path field. Records are whitespace-delimited, so spaces,
/// tabs and backslashes must be encoded octally.
const MtreePath = struct {
    path: []const u8,

    pub fn format(self: MtreePath, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.path) |ch| {
            switch (ch) {
                ' ' => try w.writeAll("\\040"),
                '\t' => try w.writeAll("\\011"),
                '\n' => try w.writeAll("\\012"),
                '\\' => try w.writeAll("\\134"),
                else => try w.writeByte(ch),
            }
        }
    }
};

/// Render the mtree listing that pacman-style tooling uses to validate an
/// installed package against its manifest.
fn renderMtree(gpa: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(gpa);
    errdefer buf.deinit();
    const w = &buf.writer;

    try w.writeAll("#mtree\n");
    try w.writeAll("/set type=file uid=0 gid=0 mode=644\n");

    for (entries) |e| {
        switch (e.kind) {
            .directory => try w.print(
                "./{f} time={d}.0 mode={o} type=dir\n",
                .{ MtreePath{ .path = e.path }, mtree_time, e.mode },
            ),
            .sym_link => try w.print(
                "./{f} time={d}.0 mode={o} type=link link={f}\n",
                .{
                    MtreePath{ .path = e.path },
                    mtree_time,
                    e.mode,
                    MtreePath{ .path = e.link_target },
                },
            ),
            else => try w.print(
                "./{f} time={d}.0 mode={o} size={d} type=file md5digest={s} sha256digest={s}\n",
                .{ MtreePath{ .path = e.path }, mtree_time, e.mode, e.size, e.md5, e.sha256 },
            ),
        }
    }

    return buf.toOwnedSlice();
}

/// gzip `data` in memory. Used only for `.MTREE`, which is text.
fn gzipBytes(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 64 * 1024);
    errdefer out.deinit();

    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);

    var comp = try std.compress.flate.Compress.init(&out.writer, window, .gzip, .default);
    try comp.writer.writeAll(data);
    try comp.finish();

    return out.toOwnedSlice();
}

/// Build the package artifact from the staged image and write it to
/// `out_path`. Returns the number of bytes written.
pub fn write(
    gpa: std.mem.Allocator,
    io: std.Io,
    pkgdir: []const u8,
    meta: Meta,
    compression: Compression,
    builddir: []const u8,
    out_path: []const u8,
    /// zstd level. Higher compresses better but costs the zstd process
    /// substantially more memory; 19 matches Arch's packaging defaults.
    level: u8,
) !u64 {
    const entries = try collect(gpa, io, pkgdir);
    defer freeEntries(gpa, entries);
    if (entries.len == 0) return Error.EmptyPackage;

    var installed_size: u64 = 0;
    for (entries) |e| installed_size += e.size;

    const pkginfo = try renderPkginfo(gpa, meta, installed_size);
    defer gpa.free(pkginfo);
    const buildinfo = try renderBuildinfo(gpa, meta, builddir);
    defer gpa.free(buildinfo);

    const mtree_text = try renderMtree(gpa, entries);
    defer gpa.free(mtree_text);
    // .MTREE is stored gzipped inside the package regardless of how the
    // package itself is compressed.
    const mtree_gz = try gzipBytes(gpa, mtree_text);
    defer gpa.free(mtree_gz);

    // zstd has no encoder in std, so that path writes a plain tar first and
    // compresses it as a separate step.
    const staging = if (compression == .zstd)
        try std.fmt.allocPrint(gpa, "{s}/.opti-pkg.tar", .{builddir})
    else
        try gpa.dupe(u8, out_path);
    defer gpa.free(staging);

    try writeTar(gpa, io, pkgdir, entries, meta, pkginfo, buildinfo, mtree_gz, compression, staging);

    if (compression == .zstd) {
        defer std.Io.Dir.cwd().deleteFile(io, staging) catch {};

        const level_arg = try std.fmt.allocPrint(gpa, "-{d}", .{level});
        defer gpa.free(level_arg);

        exec.check(io, &.{ "zstd", "-q", "-f", level_arg, staging, "-o", out_path }, .{}) catch {
            // Fall back to gzip rather than failing the build outright.
            try writeTar(gpa, io, pkgdir, entries, meta, pkginfo, buildinfo, mtree_gz, .gzip, out_path);
        };
    }

    const stat = try std.Io.Dir.cwd().statFile(io, out_path, .{});
    return stat.size;
}

/// Stream the tar (optionally gzip-wrapped) to `dest`.
fn writeTar(
    gpa: std.mem.Allocator,
    io: std.Io,
    pkgdir: []const u8,
    entries: []const Entry,
    meta: Meta,
    pkginfo: []const u8,
    buildinfo: []const u8,
    mtree_gz: []const u8,
    compression: Compression,
    dest: []const u8,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(io, pkgdir, .{});
    defer dir.close(io);

    const file = try std.Io.Dir.cwd().createFile(io, dest, .{});
    defer file.close(io);

    const out_buf = try gpa.alloc(u8, 256 * 1024);
    defer gpa.free(out_buf);
    var file_writer = file.writer(io, out_buf);

    var window: []u8 = &.{};
    defer if (window.len > 0) gpa.free(window);

    var compressor: ?std.compress.flate.Compress = null;
    var sink: *std.Io.Writer = &file_writer.interface;

    if (compression == .gzip) {
        window = try gpa.alloc(u8, std.compress.flate.max_window_len);
        compressor = try std.compress.flate.Compress.init(sink, window, .gzip, .default);
        sink = &compressor.?.writer;
    }

    var tw: std.tar.Writer = .{ .underlying_writer = sink };

    // Metadata members must come first, in this order.
    try tw.writeFileBytes(".PKGINFO", pkginfo, .{ .mode = 0o644 });
    try tw.writeFileBytes(".BUILDINFO", buildinfo, .{ .mode = 0o644 });
    if (meta.install_script) |script| {
        try tw.writeFileBytes(".INSTALL", script, .{ .mode = 0o644 });
    }
    if (meta.changelog) |log| {
        try tw.writeFileBytes(".CHANGELOG", log, .{ .mode = 0o644 });
    }
    try tw.writeFileBytes(".MTREE", mtree_gz, .{ .mode = 0o644 });

    const read_buf = try gpa.alloc(u8, 256 * 1024);
    defer gpa.free(read_buf);

    for (entries) |e| {
        switch (e.kind) {
            .directory => try tw.writeDir(e.path, .{ .mode = e.mode }),
            .sym_link => try tw.writeLink(e.path, e.link_target, .{ .mode = e.mode }),
            else => {
                // Streamed straight from disk; contents never reach memory.
                const src = try dir.openFile(io, e.path, .{});
                defer src.close(io);

                var reader: std.Io.File.Reader = .initSize(src, io, read_buf, e.size);
                try tw.writeFileStream(e.path, e.size, &reader.interface, .{ .mode = e.mode });
            },
        }
    }

    try tw.finishPedantically();

    if (compressor) |*c| try c.finish();
    try file_writer.interface.flush();
}

const testing = std.testing;

test "pkginfo renders required fields" {
    const meta: Meta = .{
        .pkgname = "hello",
        .pkgbase = "hello",
        .version = "2.12.1-1",
        .pkgdesc = "greeting",
        .arch = "x86_64",
    };
    const text = try renderPkginfo(testing.allocator, meta, 4096);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "pkgname = hello\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "pkgver = 2.12.1-1\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "size = 4096\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "arch = x86_64\n") != null);
}

test "pkginfo renders versioned dependencies" {
    const deps = [_]srcinfo.Dep{
        srcinfo.Dep.parse("glibc"),
        srcinfo.Dep.parse("go>=1.24"),
    };
    const meta: Meta = .{
        .pkgname = "x",
        .pkgbase = "x",
        .version = "1-1",
        .depends = &deps,
    };
    const text = try renderPkginfo(testing.allocator, meta, 0);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "depend = glibc\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "depend = go>=1.24\n") != null);
}

test "gzip round-trips" {
    const original = "hello opti " ** 64;
    const compressed = try gzipBytes(testing.allocator, original);
    defer testing.allocator.free(compressed);

    try testing.expectEqual(@as(u8, 0x1f), compressed[0]);
    try testing.expectEqual(@as(u8, 0x8b), compressed[1]);
    try testing.expect(compressed.len < original.len);
}

test "mtree lists files with both digests" {
    const entries = [_]Entry{
        .{ .path = "usr", .kind = .directory, .mode = 0o755 },
        .{
            .path = "usr/bin/hello",
            .kind = .file,
            .mode = 0o755,
            .size = 3,
            .sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            .md5 = "900150983cd24fb0d6963f7d28e17f72",
        },
    };
    const text = try renderMtree(testing.allocator, &entries);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.startsWith(u8, text, "#mtree\n"));
    try testing.expect(std.mem.indexOf(u8, text, "./usr time=0.0 mode=755 type=dir\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "size=3") != null);
    try testing.expect(std.mem.indexOf(u8, text, "md5digest=900150983cd24fb0d6963f7d28e17f72") != null);
}

test "mtree escapes whitespace in paths" {
    const entries = [_]Entry{
        .{ .path = "usr/share/my app/data file.txt", .kind = .file, .mode = 0o644 },
    };
    const text = try renderMtree(testing.allocator, &entries);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "my\\040app") != null);
    try testing.expect(std.mem.indexOf(u8, text, "data\\040file.txt") != null);
}

test "mtree records symlink targets" {
    const entries = [_]Entry{
        .{ .path = "usr/lib/libx.so", .kind = .sym_link, .mode = 0o777, .link_target = "libx.so.1" },
    };
    const text = try renderMtree(testing.allocator, &entries);
    defer testing.allocator.free(text);

    try testing.expect(std.mem.indexOf(u8, text, "type=link link=libx.so.1") != null);
}

test "hex encoding" {
    const out = try toHex(testing.allocator, &[_]u8{ 0x00, 0x0f, 0xff, 0xa5 });
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("000fffa5", out);
}
