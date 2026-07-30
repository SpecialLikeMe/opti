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
const conf = @import("config.zig");

pub const Error = error{ MissingPkgbuild, MissingSrcinfo };

/// Per-invocation switches, mirroring makepkg's command line.
pub const BuildOptions = struct {
    /// `--nocheck`: skip `check()`, whose test suites are often the slowest
    /// part of a build.
    skip_check: bool = false,
    /// `--skipchecksums`: accept sources without validating them.
    skip_checksums: bool = false,
    /// `--holdver`: do not run `pkgver()`, keeping the declared version.
    hold_version: bool = false,
    /// Shared library directory to bake into RPATH. When set, source builds
    /// resolve their runtime dependencies from the store instead of relying on
    /// the host's library search path.
    store_lib_dir: ?[]const u8 = null,
};

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
    build_opts: BuildOptions,
) ![][]const u8 {
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
    // than from hardcoded defaults...
    var config = config_in;
    var host = try lifecycle.detectHost(gpa, io_ctx, startdir);
    defer host.deinit();
    host.applyTo(&config);

    // ...and optimkp.toml overrides anything it chooses to specify.
    var user_config = try conf.load(gpa, io_ctx, env, startdir);
    defer user_config.deinit();
    user_config.applyTo(&config);
    // Baked into LDFLAGS so relocated binaries can still find store libraries.
    if (build_opts.store_lib_dir) |dir| config.store_rpath = dir;
    if (user_config.found()) {
        try out.print("using {s}\n", .{user_config.source_path});
    }

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
        try sources.acquire(
            gpa,
            io_ctx,
            out,
            &meta,
            layout.startdir,
            layout.srcdir,
            build_opts.skip_checksums,
        );
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
        .flags = lifecycle.Flags.fromOptions(&meta),
    };

    // pkgver() runs after sources are in place: VCS packages derive their
    // version from the checked-out tree.
    const capture = try std.fmt.allocPrint(gpa, "{s}/.opti-pkgver", .{layout.startdir});
    defer gpa.free(capture);

    const derived_opt = if (build_opts.hold_version)
        null
    else
        try lifecycle.runPkgver(gpa, io_ctx, env, ctx, capture);

    if (derived_opt) |derived| {
        defer gpa.free(derived);
        gpa.free(version);
        version = if (meta.epoch) |e|
            try std.fmt.allocPrint(gpa, "{s}:{s}-{s}", .{ e, derived, meta.pkgrel })
        else
            try std.fmt.allocPrint(gpa, "{s}-{s}", .{ derived, meta.pkgrel });
        ctx.pkgver = derived;
        lifecycle.writeBackPkgver(gpa, io_ctx, layout.pkgbuild, derived) catch {};
        try out.print("  pkgver: {s}\n", .{version});
    }
    io.removeTree(io_ctx, capture) catch {};

    inline for (.{ .prepare, .build, .check }) |stage| {
        if (stage == .check and build_opts.skip_check) {
            try out.writeAll("  check: skipped\n");
        } else {
            const outcome = try lifecycle.runStage(gpa, io_ctx, env, ctx, stage);
            try out.print("  {s}: {s}\n", .{ @tagName(stage), @tagName(outcome) });
        }
        try out.flush();
    }

    // Machine preferences first, then the PKGBUILD's own options=(), so a
    // package always wins over a host-wide default.
    var opts: tidy.Options = .{};
    user_config.applyOptions(&opts);
    opts = tidy.Options.overlay(opts, &meta);

    const compression = user_config.compression orelse archive.Compression.preferred(io_ctx);
    const level = user_config.compression_level orelse conf.default_level;

    // Paths of every artifact produced, so the caller can install them.
    var artifacts: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (artifacts.items) |a| gpa.free(a);
        artifacts.deinit(gpa);
    }

    for (meta.packages) |pkg| {
        try packageOne(
            gpa,   io_ctx, env,     out,  &meta, pkg,
            layout, &ctx,  version, config, opts, compression, level,
            &artifacts,
        );
    }

    return artifacts.toOwnedSlice(gpa);
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
    compression: archive.Compression,
    level: u8,
    artifacts: *std.ArrayList([]const u8),
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

    // Debug symbols are staged separately so they can ship as their own
    // package rather than bloating the main one.
    const debug_dir = try std.fmt.allocPrint(
        gpa,
        "{s}/{s}-debug",
        .{ layout.pkgbase_dir, pkg.pkgname },
    );
    defer gpa.free(debug_dir);
    if (opts.debug) try io.makePath(io_ctx, debug_dir);

    const report = try tidy.run(gpa, io_ctx, pkgdir, opts, if (opts.debug) debug_dir else null);
    try out.print(
        "  tidy: {d} stripped, {d} removed, {d} compressed, {d} detached\n",
        .{ report.stripped, report.removed, report.compressed, report.detached },
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

    var changelog: ?[]u8 = null;
    defer if (changelog) |cl| gpa.free(cl);
    if (meta.changelog) |name| {
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ layout.startdir, name });
        defer gpa.free(path);
        changelog = io.readFile(io_ctx, gpa, path, .limited(1 << 20)) catch null;
    }

    const out_path = try std.fmt.allocPrint(gpa, "{s}/{s}-{s}-{s}{s}", .{
        layout.startdir,
        pkg.pkgname,
        version,
        meta.archFor(config.carch),
        compression.extension(),
    });
    errdefer gpa.free(out_path);

    const written = try archive.write(gpa, io_ctx, pkgdir, .{
        .pkgname = pkg.pkgname,
        .pkgbase = meta.pkgbase,
        .version = version,
        .pkgdesc = pkg.pkgdesc,
        .url = pkg.url,
        .arch = meta.archFor(config.carch),
        .packager = config.packager,
        .builddate = @intCast(std.Io.Timestamp.now(io_ctx, .real).toSeconds()),
        .licenses = pkg.licenses,
        .depends = pkg.depends,
        .provides = pkg.provides,
        .conflicts = pkg.conflicts,
        .replaces = pkg.replaces,
        .backup = pkg.backup,
        .optdepends = pkg.optdepends,
        .groups = pkg.groups,
        .install_script = script,
        .changelog = changelog,
        .options = meta.options,
    }, compression, layout.startdir, out_path, level);

    try out.print("built {s} ({d} bytes)\n", .{ out_path, written });
    try out.flush();
    try artifacts.append(gpa, out_path);

    // makepkg's debug packages carry the sources the symbols refer to, so a
    // debugger can show source lines and not just function names.
    if (opts.debug and report.detached > 0) {
        const src_dest = try std.fmt.allocPrint(
            gpa,
            "{s}/usr/src/debug/{s}",
            .{ debug_dir, meta.pkgbase },
        );
        defer gpa.free(src_dest);
        tidy.copyDebugSources(gpa, io_ctx, layout.srcdir, src_dest) catch {};
    }

    if (opts.debug and report.detached > 0) {
        try emitDebugPackage(
            gpa,       io_ctx,  out,     meta, pkg,
            debug_dir, version, config,  compression, level, layout, artifacts,
        );
    }
}

/// Package the detached symbols as `<pkgname>-debug`.
fn emitDebugPackage(
    gpa: std.mem.Allocator,
    io_ctx: std.Io,
    out: *std.Io.Writer,
    meta: *const srcinfo.SrcInfo,
    pkg: srcinfo.Package,
    debug_dir: []const u8,
    version: []const u8,
    config: lifecycle.Config,
    compression: archive.Compression,
    level: u8,
    layout: Layout,
    artifacts: *std.ArrayList([]const u8),
) !void {
    const name = try std.fmt.allocPrint(gpa, "{s}-debug", .{pkg.pkgname});
    defer gpa.free(name);

    const desc = try std.fmt.allocPrint(gpa, "Detached debugging symbols for {s}", .{pkg.pkgname});
    defer gpa.free(desc);

    const path = try std.fmt.allocPrint(gpa, "{s}/{s}-{s}-{s}{s}", .{
        layout.startdir,
        name,
        version,
        meta.archFor(config.carch),
        compression.extension(),
    });
    errdefer gpa.free(path);

    const written = try archive.write(gpa, io_ctx, debug_dir, .{
        .pkgname = name,
        .pkgbase = meta.pkgbase,
        .version = version,
        .pkgdesc = desc,
        .url = pkg.url,
        .arch = meta.archFor(config.carch),
        .packager = config.packager,
        .builddate = @intCast(std.Io.Timestamp.now(io_ctx, .real).toSeconds()),
        .licenses = pkg.licenses,
        .options = meta.options,
    }, compression, layout.startdir, path, level);

    try out.print("built {s} ({d} bytes)\n", .{ path, written });
    try out.flush();
    try artifacts.append(gpa, path);
}
