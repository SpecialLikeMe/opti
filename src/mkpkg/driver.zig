//! Orchestrates a build end to end: read metadata, lay out the work tree,
//! retrieve sources, run the lifecycle, tidy the image, and emit one artifact
//! per output package.

const std = @import("std");
const io = @import("../io.zig");
const srcinfo = @import("srcinfo.zig");
const sources = @import("sources.zig");
const archive = @import("archive.zig");
const lifecycle = @import("lifecycle.zig");
const tidy = @import("tidy.zig");
const generate = @import("generate.zig");

pub const Error = error{ MissingPkgbuild, MissingSrcinfo };

/// Layout of a build work tree, mirroring makepkg's.
pub const Layout = struct {
    startdir: []const u8,
    pkgbuild: []const u8,
    srcdir: []const u8,
    /// Parent of the per-package staging roots.
    pkgbase_dir: []const u8,

    pub fn init(gpa: std.mem.Allocator, startdir: []const u8) !Layout {
        return .{
            .startdir = startdir,
            .pkgbuild = try std.fmt.allocPrint(gpa, "{s}/PKGBUILD", .{startdir}),
            .srcdir = try std.fmt.allocPrint(gpa, "{s}/src", .{startdir}),
            .pkgbase_dir = try std.fmt.allocPrint(gpa, "{s}/pkg", .{startdir}),
        };
    }

    pub fn deinit(self: Layout, gpa: std.mem.Allocator) void {
        gpa.free(self.pkgbuild);
        gpa.free(self.srcdir);
        gpa.free(self.pkgbase_dir);
    }
};

pub fn build(
    gpa: std.mem.Allocator,
    io_ctx: std.Io,
    env: *std.process.Environ.Map,
    out: *std.Io.Writer,
    startdir: []const u8,
    config_in: lifecycle.Config,
) !void {
    const pre = lifecycle.preflight(io_ctx);
    if (!pre.ok()) {
        try out.writeAll("missing required build tools:");
        for (pre.items()) |tool| try out.print(" {s}", .{tool});
        try out.writeAll("\n");
        return error.StageFailed;
    }

    const layout = try Layout.init(gpa, startdir);
    defer layout.deinit(gpa);

    if (!io.exists(io_ctx, layout.pkgbuild)) return Error.MissingPkgbuild;

    // Architecture, target triple and job count come from the machine rather
    // than from hardcoded defaults.
    var config = config_in;
    var host = try lifecycle.detectHost(gpa, io_ctx, startdir);
    defer host.deinit();
    host.applyTo(&config);

    const meta_path = try std.fmt.allocPrint(gpa, "{s}/.SRCINFO", .{startdir});
    defer gpa.free(meta_path);

    // Prefer the committed .SRCINFO — reading it executes nothing. Fall back to
    // deriving metadata from the PKGBUILD so a bare one still builds, the way
    // makepkg works.
    const text = if (io.exists(io_ctx, meta_path))
        try io.readFile(io_ctx, gpa, meta_path, .limited(1 << 20))
    else
        try generate.fromPkgbuild(gpa, io_ctx, env, layout.pkgbuild, startdir);
    defer gpa.free(text);

    var meta = try srcinfo.parse(gpa, text, config.carch);
    defer meta.deinit();

    try io.makePath(io_ctx, layout.srcdir);

    var version = try meta.version(gpa);
    defer gpa.free(version);

    try out.print("building {s} {s}\n", .{ meta.pkgbase, version });
    try out.flush();

    if (meta.sources.len > 0) {
        try out.writeAll("retrieving sources\n");
        try out.flush();
        try sources.acquire(gpa, io_ctx, out, &meta, layout.startdir, layout.srcdir);
    }

    var ctx: lifecycle.Context = .{
        .pkgbuild = layout.pkgbuild,
        .startdir = layout.startdir,
        .srcdir = layout.srcdir,
        .pkgdir = layout.pkgbase_dir,
        .pkgbase = meta.pkgbase,
        .pkgver = meta.pkgver,
        .pkgrel = meta.pkgrel,
        .config = config,
    };

    // pkgver() runs after sources are in place: VCS packages derive their
    // version from the checked-out tree.
    const capture = try std.fmt.allocPrint(gpa, "{s}/.opti-pkgver", .{layout.startdir});
    defer gpa.free(capture);

    if (try lifecycle.runPkgver(gpa, io_ctx, env, ctx, capture)) |derived| {
        defer gpa.free(derived);
        gpa.free(version);
        version = if (meta.epoch) |e|
            try std.fmt.allocPrint(gpa, "{s}:{s}-{s}", .{ e, derived, meta.pkgrel })
        else
            try std.fmt.allocPrint(gpa, "{s}-{s}", .{ derived, meta.pkgrel });
        ctx.pkgver = derived;
        try out.print("  pkgver: {s}\n", .{version});
    }
    io.removeTree(io_ctx, capture) catch {};

    inline for (.{ .prepare, .build, .check }) |stage| {
        const outcome = try lifecycle.runStage(gpa, io_ctx, env, ctx, stage);
        try out.print("  {s}: {s}\n", .{ @tagName(stage), @tagName(outcome) });
        try out.flush();
    }

    const opts = tidy.Options.fromSrcInfo(&meta);

    for (meta.packages) |pkg| {
        try packageOne(gpa, io_ctx, env, out, &meta, pkg, layout, &ctx, version, config, opts);
    }
}

/// Stage, tidy and archive a single output package.
fn packageOne(
    gpa: std.mem.Allocator,
    io_ctx: std.Io,
    env: *std.process.Environ.Map,
    out: *std.Io.Writer,
    meta: *const srcinfo.SrcInfo,
    pkg: srcinfo.Package,
    layout: Layout,
    ctx: *lifecycle.Context,
    version: []const u8,
    config: lifecycle.Config,
    opts: tidy.Options,
) !void {
    const pkgdir = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ layout.pkgbase_dir, pkg.pkgname });
    defer gpa.free(pkgdir);

    try io.makePath(io_ctx, pkgdir);
    ctx.pkgdir = pkgdir;

    // Split PKGBUILDs put each payload in package_<pkgname>(); a single-package
    // one uses plain package(). Try the specific name first.
    const specific = try std.fmt.allocPrint(gpa, "package_{s}", .{pkg.pkgname});
    defer gpa.free(specific);

    var outcome = try lifecycle.runNamed(gpa, io_ctx, env, ctx.*, specific, true);
    if (outcome == .absent) {
        outcome = try lifecycle.runNamed(gpa, io_ctx, env, ctx.*, "package", true);
    }
    if (outcome == .absent) return lifecycle.Error.MissingPackageFunction;

    try out.print("  package({s}): ran\n", .{pkg.pkgname});
    try out.flush();

    const report = try tidy.run(gpa, io_ctx, pkgdir, opts);
    try out.print(
        "  tidy: {d} stripped, {d} removed, {d} compressed\n",
        .{ report.stripped, report.removed, report.compressed },
    );

    // The install= scriptlet lives next to the PKGBUILD and travels inside the
    // artifact as .INSTALL.
    var script: ?[]u8 = null;
    defer if (script) |s| gpa.free(s);
    if (pkg.install) |name| {
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ layout.startdir, name });
        defer gpa.free(path);
        script = io.readFile(io_ctx, gpa, path, .limited(1 << 20)) catch null;
    }

    const bytes = try archive.build(gpa, io_ctx, pkgdir, .{
        .pkgname = pkg.pkgname,
        .pkgbase = meta.pkgbase,
        .version = version,
        .pkgdesc = pkg.pkgdesc,
        .url = pkg.url,
        .arch = config.carch,
        .packager = config.packager,
        .builddate = @intCast(std.Io.Timestamp.now(io_ctx, .real).toSeconds()),
        .licenses = pkg.licenses,
        .depends = pkg.depends,
        .provides = pkg.provides,
        .conflicts = pkg.conflicts,
        .replaces = pkg.replaces,
        .backup = pkg.backup,
        .install_script = script,
        .options = meta.options,
    }, .gzip, layout.startdir);
    defer gpa.free(bytes);

    const out_path = try std.fmt.allocPrint(gpa, "{s}/{s}-{s}-{s}{s}", .{
        layout.startdir,
        pkg.pkgname,
        version,
        config.carch,
        archive.Compression.gzip.extension(),
    });
    defer gpa.free(out_path);

    try io.writeFile(io_ctx, out_path, bytes);
    try out.print("built {s} ({d} bytes)\n", .{ out_path, bytes.len });
    try out.flush();
}
