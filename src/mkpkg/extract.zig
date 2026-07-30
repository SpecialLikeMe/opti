//! Archive extraction, implemented natively with `std.tar` and `std.compress`
//! so unpacking a source needs no external tools.

const std = @import("std");
const exec = @import("exec.zig");

pub const Error = error{ UnsupportedFormat, NotAnArchive };

pub const Format = enum {
    tar,
    tar_gz,
    tar_xz,
    tar_zst,
    /// std has no bzip2 decoder; handled by the external fallback.
    tar_bz2,
    /// std has no zip reader for this path; handled by the external fallback.
    zip,
    /// Not an archive; the file is copied into $srcdir verbatim.
    plain,

    pub fn isArchive(f: Format) bool {
        return f != .plain;
    }

    /// Whether decoding requires falling back to an external extractor.
    pub fn needsExternal(f: Format) bool {
        return f == .tar_bz2 or f == .zip;
    }
};

/// Classify by filename, the way makepkg does.
pub fn detect(name: []const u8) Format {
    const eq = std.mem.endsWith;
    if (eq(u8, name, ".tar")) return .tar;
    if (eq(u8, name, ".tar.gz") or eq(u8, name, ".tgz")) return .tar_gz;
    if (eq(u8, name, ".tar.xz") or eq(u8, name, ".txz")) return .tar_xz;
    if (eq(u8, name, ".tar.zst") or eq(u8, name, ".tzst")) return .tar_zst;
    if (eq(u8, name, ".tar.bz2") or eq(u8, name, ".tbz2")) return .tar_bz2;
    if (eq(u8, name, ".zip")) return .zip;
    return .plain;
}

/// zstd asserts its output buffer holds a full window plus one max block.
const zstd_buffer_len = std.compress.zstd.default_window_len + std.compress.zstd.block_size_max;

/// Uniform mtime stamped onto everything unpacked from an archive.
///
/// `std.tar` discards the archive's own timestamps, so extracted files would
/// otherwise carry their extraction time and land in effectively arbitrary
/// relative order. Autotools trees detect that as "configure.ac is newer than
/// aclocal.m4" and try to regenerate the build system, which fails on any host
/// lacking the exact automake version the tarball was built with. GNU make
/// only rebuilds when a prerequisite is *strictly* newer, so giving every file
/// one identical timestamp keeps generated files considered up to date.
const uniform_mtime: std.Io.Timestamp = .{
    .nanoseconds = 1_577_836_800 * @as(i96, std.time.ns_per_s),
};

fn normalizeTimestamps(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !void {
    var walker = try dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        // setTimestamps follows symlinks and there is no no-follow option, so
        // a link pointing outside the tree (an absolute target, say) would
        // fail with ENOENT and dump a trace. Their timestamps do not matter
        // for build ordering anyway.
        if (entry.kind == .sym_link) continue;

        // Best effort: a file we cannot stamp is not worth failing the build.
        entry.dir.setTimestamps(io, entry.basename, .{
            .access_timestamp = .{ .new = uniform_mtime },
            .modify_timestamp = .{ .new = uniform_mtime },
        }) catch {};
    }
}

/// Unpack `data` into the already-existing directory `dest`.
///
/// `strip_components` defaults to 1 because source tarballs conventionally
/// contain a single top-level `name-version/` directory, and makepkg's
/// `$srcdir` layout expects that level removed.
pub fn extract(
    gpa: std.mem.Allocator,
    io: std.Io,
    data: []const u8,
    dest: []const u8,
    format: Format,
    strip_components: u32,
) !void {
    if (format.needsExternal()) {
        try extractExternal(gpa, io, data, dest, format, strip_components);
        var ext_dir = try std.Io.Dir.cwd().openDir(io, dest, .{ .iterate = true });
        defer ext_dir.close(io);
        try normalizeTimestamps(gpa, io, ext_dir);
        return;
    }

    var dir = try std.Io.Dir.cwd().openDir(io, dest, .{ .iterate = true });
    defer dir.close(io);

    var input = std.Io.Reader.fixed(data);
    const options: std.tar.ExtractOptions = .{
        .strip_components = strip_components,
        .mode_mode = .executable_bit_only,
    };

    switch (format) {
        .tar => try std.tar.extract(io, dir, &input, options),

        .tar_gz => {
            const buf = try gpa.alloc(u8, std.compress.flate.max_window_len);
            defer gpa.free(buf);
            var decomp = std.compress.flate.Decompress.init(&input, .gzip, buf);
            try std.tar.extract(io, dir, &decomp.reader, options);
        },

        .tar_xz => {
            const buf = try gpa.alloc(u8, 1 << 20);
            var decomp = try std.compress.xz.Decompress.init(&input, gpa, buf);
            defer decomp.deinit();
            try std.tar.extract(io, dir, &decomp.reader, options);
        },

        .tar_zst => {
            const buf = try gpa.alloc(u8, zstd_buffer_len);
            defer gpa.free(buf);
            var decomp = std.compress.zstd.Decompress.init(&input, buf, .{});
            try std.tar.extract(io, dir, &decomp.reader, options);
        },

        .tar_bz2, .zip => unreachable, // routed to extractExternal above
        .plain => return Error.NotAnArchive,
    }

    try normalizeTimestamps(gpa, io, dir);
}

/// Formats std cannot decode (bzip2, zip) are handed to `bsdtar`, which reads
/// both. This is the only archive path that needs a host tool, and it is
/// reached only for these two formats.
fn extractExternal(
    gpa: std.mem.Allocator,
    io: std.Io,
    data: []const u8,
    dest: []const u8,
    format: Format,
    strip_components: u32,
) !void {
    if (!exec.exists(io, "bsdtar")) return Error.UnsupportedFormat;

    const suffix = if (format == .zip) "zip" else "tar.bz2";
    const tmp = try std.fmt.allocPrint(gpa, "{s}/.opti-archive.{s}", .{ dest, suffix });
    defer gpa.free(tmp);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = tmp, .data = data });
    defer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

    const strip = try std.fmt.allocPrint(gpa, "--strip-components={d}", .{strip_components});
    defer gpa.free(strip);

    try exec.check(io, &.{ "bsdtar", "-xf", tmp, "-C", dest, strip }, .{});
}

const testing = std.testing;

test "format detection" {
    try testing.expectEqual(Format.tar_gz, detect("foo-1.0.tar.gz"));
    try testing.expectEqual(Format.tar_gz, detect("foo.tgz"));
    try testing.expectEqual(Format.tar_xz, detect("foo-1.0.tar.xz"));
    try testing.expectEqual(Format.tar_zst, detect("foo-1.0.tar.zst"));
    try testing.expectEqual(Format.tar_bz2, detect("foo-1.0.tar.bz2"));
    try testing.expectEqual(Format.tar, detect("foo.tar"));
}

test "non-archives are plain" {
    try testing.expectEqual(Format.plain, detect("fix-build.patch"));
    try testing.expectEqual(Format.plain, detect("service.install"));
    try testing.expectEqual(Format.plain, detect("README"));
}

test "isArchive" {
    try testing.expect(Format.tar_gz.isArchive());
    try testing.expect(!Format.plain.isArchive());
}
