//! Post-`package()` cleanup of the staged image, equivalent to makepkg's
//! `tidy_install`.
//!
//! `options=()` in a PKGBUILD toggles these; each is on or off by default and
//! a `!name` entry negates it. They run against `$pkgdir` after `package()`
//! and before the artifact is assembled.

const std = @import("std");
const exec = @import("exec.zig");
const srcinfo = @import("srcinfo.zig");

pub const Options = struct {
    /// Strip symbols from ELF binaries. Dominates installed size.
    strip: bool = true,
    /// Remove libtool `.la` files, which hardcode build-host paths.
    libtool: bool = false,
    /// Keep static `.a` libraries.
    staticlibs: bool = false,
    /// Keep `/usr/share/doc`.
    docs: bool = true,
    /// Compress man and info pages.
    zipman: bool = true,
    /// Remove leftover build artifacts.
    purge: bool = true,
    /// Keep directories that ended up empty.
    emptydirs: bool = false,

    /// Apply a PKGBUILD's `options=()` over the defaults.
    pub fn fromSrcInfo(meta: *const srcinfo.SrcInfo) Options {
        var o: Options = .{};
        inline for (@typeInfo(Options).@"struct".fields) |f| {
            if (f.type == bool) {
                if (meta.option(f.name)) |set| @field(o, f.name) = set;
            }
        }
        return o;
    }
};

/// Files deleted when `purge` is enabled.
const purge_targets = [_][]const u8{ ".packlist", "*.pod" };

/// Suffixes removed when `docs` is disabled.
const doc_dirs = [_][]const u8{ "usr/share/doc", "usr/share/gtk-doc" };

pub const Report = struct {
    stripped: usize = 0,
    removed: usize = 0,
    compressed: usize = 0,
};

/// Run every enabled cleanup over `pkgdir`.
pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    pkgdir: []const u8,
    opts: Options,
) !Report {
    var report: Report = .{};

    if (!opts.docs) {
        for (doc_dirs) |sub| {
            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ pkgdir, sub });
            defer gpa.free(path);
            std.Io.Dir.cwd().deleteTree(io, path) catch continue;
            report.removed += 1;
        }
    }

    var dir = try std.Io.Dir.cwd().openDir(io, pkgdir, .{ .iterate = true });
    defer dir.close(io);

    // Collect first: mutating the tree while walking it is not safe.
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }

    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        try paths.append(gpa, try gpa.dupe(u8, entry.path));
    }

    for (paths.items) |rel| {
        const full = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ pkgdir, rel });
        defer gpa.free(full);

        if (!opts.libtool and std.mem.endsWith(u8, rel, ".la")) {
            dir.deleteFile(io, rel) catch {};
            report.removed += 1;
            continue;
        }
        if (!opts.staticlibs and std.mem.endsWith(u8, rel, ".a")) {
            dir.deleteFile(io, rel) catch {};
            report.removed += 1;
            continue;
        }
        if (opts.purge and shouldPurge(rel)) {
            dir.deleteFile(io, rel) catch {};
            report.removed += 1;
            continue;
        }
        if (opts.zipman and isManPage(rel)) {
            if (gzipFile(gpa, io, full)) {
                report.compressed += 1;
            } else |_| {}
            continue;
        }
        if (opts.strip and isElf(io, full)) {
            // Best effort: a binary we cannot strip is not a build failure.
            exec.check(io, &.{ "strip", "--strip-unneeded", full }, .{}) catch {};
            report.stripped += 1;
        }
    }

    if (!opts.emptydirs) report.removed += try pruneEmptyDirs(gpa, io, dir);

    return report;
}

/// Remove directories left empty after the other passes.
///
/// Deepest-first, repeated until nothing changes: removing a leaf can leave
/// its parent empty, and a single pass would miss that.
fn pruneEmptyDirs(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !usize {
    var removed: usize = 0;

    while (true) {
        var candidates: std.ArrayList([]const u8) = .empty;
        defer {
            for (candidates.items) |p| gpa.free(p);
            candidates.deinit(gpa);
        }

        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            try candidates.append(gpa, try gpa.dupe(u8, entry.path));
        }

        // Sort by descending length so children are attempted before parents.
        std.mem.sort([]const u8, candidates.items, {}, struct {
            fn longerFirst(_: void, a: []const u8, b: []const u8) bool {
                return a.len > b.len;
            }
        }.longerFirst);

        var removed_this_pass: usize = 0;
        for (candidates.items) |path| {
            // Fails with DirNotEmpty when the directory still holds something,
            // which is exactly the test we want.
            dir.deleteDir(io, path) catch continue;
            removed_this_pass += 1;
        }

        removed += removed_this_pass;
        if (removed_this_pass == 0) break;
    }

    return removed;
}

fn shouldPurge(rel: []const u8) bool {
    for (purge_targets) |target| {
        if (std.mem.startsWith(u8, target, "*")) {
            if (std.mem.endsWith(u8, rel, target[1..])) return true;
        } else if (std.mem.endsWith(u8, rel, target)) return true;
    }
    return false;
}

pub fn isManPage(rel: []const u8) bool {
    if (std.mem.endsWith(u8, rel, ".gz")) return false;
    return std.mem.indexOf(u8, rel, "usr/share/man/") != null or
        std.mem.indexOf(u8, rel, "usr/share/info/") != null;
}

/// Detect ELF by magic rather than by extension: shared objects, executables
/// and kernel modules have no consistent naming.
///
/// Reads only the header. Using `readFileAlloc` with a 4-byte limit would be
/// wrong — it reports `StreamTooLong` for any longer file, which is every real
/// binary.
fn isElf(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);

    var magic: [4]u8 = undefined;
    var bufs = [_][]u8{&magic};
    const n = file.readStreaming(io, &bufs) catch return false;
    return n == 4 and std.mem.eql(u8, &magic, "\x7fELF");
}

fn gzipFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 28));
    defer gpa.free(data);

    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer out.deinit();

    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);

    var comp = try std.compress.flate.Compress.init(&out.writer, window, .gzip, .default);
    try comp.writer.writeAll(data);
    try comp.finish();

    const gz_path = try std.fmt.allocPrint(gpa, "{s}.gz", .{path});
    defer gpa.free(gz_path);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = gz_path, .data = out.written() });
    try std.Io.Dir.cwd().deleteFile(io, path);
}

const testing = std.testing;

test "defaults match makepkg" {
    const o: Options = .{};
    try testing.expect(o.strip);
    try testing.expect(o.zipman);
    try testing.expect(o.purge);
    try testing.expect(o.docs);
    try testing.expect(!o.staticlibs);
    try testing.expect(!o.libtool);
    try testing.expect(!o.emptydirs);
}

test "options negation is applied" {
    const text = "pkgbase = x\n\toptions = !strip\n\toptions = staticlibs\n";
    var si = try srcinfo.parse(testing.allocator, text, "x86_64");
    defer si.deinit();

    const o = Options.fromSrcInfo(&si);
    try testing.expect(!o.strip);
    try testing.expect(o.staticlibs);
    // Untouched options keep their defaults.
    try testing.expect(o.zipman);
}

test "man and info pages are recognised" {
    try testing.expect(isManPage("usr/share/man/man1/hello.1"));
    try testing.expect(isManPage("usr/share/info/hello.info"));
    try testing.expect(!isManPage("usr/share/man/man1/hello.1.gz"));
    try testing.expect(!isManPage("usr/bin/hello"));
}

test "purge targets" {
    try testing.expect(shouldPurge("usr/lib/perl5/.packlist"));
    try testing.expect(shouldPurge("usr/share/thing.pod"));
    try testing.expect(!shouldPurge("usr/bin/hello"));
}
