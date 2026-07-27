//! The PKGBUILD build lifecycle.
//!
//! This is the one place bash is unavoidable. `prepare()`, `build()`,
//! `check()` and `package()` are bash functions, not data, so running them
//! means sourcing the PKGBUILD. Metadata is deliberately read elsewhere (see
//! `srcinfo.zig`) so that resolving dependencies never executes anything.
//!
//! The contract mirrors makepkg's: the PKGBUILD is sourced, the working
//! directory is `$srcdir`, `package()` writes into `$pkgdir`, and `$pkgdir`
//! ownership is faked so the build need not run as root.

const std = @import("std");
const exec = @import("exec.zig");

/// Exit status the wrapper script uses to report "this function is not
/// defined in the PKGBUILD", distinct from the function itself failing.
const absent_status: u8 = 66;

pub const Error = error{ StageFailed, MissingPackageFunction };

pub const Stage = enum {
    prepare,
    build,
    check,
    package,

    /// `package()` runs under fakeroot so that `install -o root` and chown
    /// calls succeed without real privileges; the recorded ownership is what
    /// ends up in the artifact's metadata.
    pub fn needsFakeroot(s: Stage) bool {
        return s == .package;
    }

    /// Only `package()` is mandatory; the rest are optional in a PKGBUILD.
    pub fn required(s: Stage) bool {
        return s == .package;
    }
};

pub const Outcome = enum { ran, absent };

/// Build flags, standing in for `makepkg.conf`. Arch's own file hardcodes
/// distro paths and assumptions, so opti ships its own rather than reading
/// `/etc/makepkg.conf`.
pub const Config = struct {
    carch: []const u8 = "x86_64",
    chost: []const u8 = "x86_64-pc-linux-gnu",
    cflags: []const u8 = "-O2 -pipe -fno-plt -fexceptions",
    cxxflags: []const u8 = "-O2 -pipe -fno-plt -fexceptions",
    ldflags: []const u8 = "-Wl,-O1 -Wl,--sort-common -Wl,--as-needed",
    makeflags: []const u8 = "-j4",
    packager: []const u8 = "opti",

    /// Appended to LDFLAGS as `-Wl,-rpath,<dir>`. Source builds therefore get
    /// their RPATH at compile time and need no patchelf afterwards; only
    /// prebuilt binaries require rewriting.
    store_rpath: ?[]const u8 = null,
};

pub const Context = struct {
    /// Absolute path to the PKGBUILD to source.
    pkgbuild: []const u8,
    /// Directory containing the PKGBUILD.
    startdir: []const u8,
    /// Where sources are extracted and built.
    srcdir: []const u8,
    /// Staging root that `package()` populates.
    pkgdir: []const u8,

    pkgbase: []const u8,
    pkgver: []const u8,
    pkgrel: []const u8,

    config: Config = .{},
    flags: Flags = .{},
};

/// Run one lifecycle stage. Returns `.absent` when the PKGBUILD does not
/// define that function, which is not an error for optional stages.
pub fn runStage(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    ctx: Context,
    stage: Stage,
) !Outcome {
    const outcome = try runNamed(gpa, io, env, ctx, @tagName(stage), stage.needsFakeroot());
    if (outcome == .absent and stage.required()) return Error.MissingPackageFunction;
    return outcome;
}

/// Run an arbitrary PKGBUILD function by name. Split packages need this: their
/// payload lives in `package_<pkgname>()` rather than plain `package()`.
pub fn runNamed(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    ctx: Context,
    func: []const u8,
    use_fakeroot: bool,
) !Outcome {
    try populateEnv(gpa, env, ctx);

    const script = try std.fmt.allocPrint(gpa,
        \\set -e
        \\source "$OPTI_PKGBUILD"
        \\cd "$srcdir"
        \\if declare -f {s} >/dev/null 2>&1; then
        \\    {s}
        \\else
        \\    exit {d}
        \\fi
    , .{ func, func, absent_status });
    defer gpa.free(script);

    const argv: []const []const u8 = if (use_fakeroot)
        &.{ "fakeroot", "--", "bash", "-c", script }
    else
        &.{ "bash", "-c", script };

    const status = try exec.run(io, argv, .{ .cwd = ctx.srcdir, .env = env });

    if (status == absent_status) return .absent;
    if (status != 0) return Error.StageFailed;
    return .ran;
}

/// Evaluate `pkgver()` and return what it printed.
///
/// This is how VCS packages derive a version from the checked-out source. The
/// value is captured through a file rather than a pipe so the function's own
/// stdout (git chatter and the like) stays visible to the user.
pub fn runPkgver(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    ctx: Context,
    capture_path: []const u8,
) !?[]u8 {
    try populateEnv(gpa, env, ctx);
    try env.put("OPTI_PKGVER_OUT", capture_path);

    const script = try std.fmt.allocPrint(gpa,
        \\set -e
        \\source "$OPTI_PKGBUILD"
        \\cd "$srcdir"
        \\if declare -f pkgver >/dev/null 2>&1; then
        \\    pkgver > "$OPTI_PKGVER_OUT"
        \\else
        \\    exit {d}
        \\fi
    , .{absent_status});
    defer gpa.free(script);

    const status = try exec.run(io, &.{ "bash", "-c", script }, .{
        .cwd = ctx.srcdir,
        .env = env,
    });

    if (status == absent_status) return null;
    if (status != 0) return Error.StageFailed;

    const raw = try std.Io.Dir.cwd().readFileAlloc(io, capture_path, gpa, .limited(4096));
    defer gpa.free(raw);

    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try gpa.dupe(u8, trimmed);
}

/// Rewrite the `pkgver=` assignment in the PKGBUILD, as makepkg does after
/// evaluating `pkgver()`. Without this the file on disk keeps claiming the
/// stale version, and anything reading it afterwards disagrees with the
/// artifact that was just produced.
pub fn writeBackPkgver(
    gpa: std.mem.Allocator,
    io: std.Io,
    pkgbuild: []const u8,
    new_version: []const u8,
) !void {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, pkgbuild, gpa, .limited(1 << 20));
    defer gpa.free(text);

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    var replaced = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.writer.writeByte('\n');
        first = false;

        // Only the top-level assignment, never the pkgver() function header.
        if (!replaced and std.mem.startsWith(u8, line, "pkgver=")) {
            try out.writer.print("pkgver={s}", .{new_version});
            replaced = true;
            continue;
        }
        try out.writer.writeAll(line);
    }

    if (!replaced) return;
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = pkgbuild, .data = out.written() });
}

/// Build-flag switches driven by `options=()`.
pub const Flags = struct {
    /// `!buildflags` clears CFLAGS/CXXFLAGS/LDFLAGS entirely; some packages
    /// miscompile with distro hardening applied.
    buildflags: bool = true,
    /// `lto` enables link-time optimisation; off by default, as in makepkg.
    lto: bool = false,
    /// `debug` adds debug info to the compiled output.
    debug: bool = false,

    pub fn fromOptions(meta: anytype) Flags {
        var f: Flags = .{};
        if (meta.option("buildflags")) |v| f.buildflags = v;
        if (meta.option("lto")) |v| f.lto = v;
        if (meta.option("debug")) |v| f.debug = v;
        return f;
    }
};

const lto_flag = " -flto=auto";
const debug_flag = " -g";

/// Populate the environment contract a PKGBUILD expects to see.
fn populateEnv(
    gpa: std.mem.Allocator,
    env: *std.process.Environ.Map,
    ctx: Context,
) !void {
    const c = ctx.config;

    try env.put("OPTI_PKGBUILD", ctx.pkgbuild);
    try env.put("startdir", ctx.startdir);
    try env.put("srcdir", ctx.srcdir);
    try env.put("pkgdir", ctx.pkgdir);
    try env.put("pkgbase", ctx.pkgbase);
    try env.put("pkgname", ctx.pkgbase);
    try env.put("pkgver", ctx.pkgver);
    try env.put("pkgrel", ctx.pkgrel);

    try env.put("CARCH", c.carch);
    try env.put("CHOST", c.chost);
    try env.put("MAKEFLAGS", c.makeflags);
    try env.put("PACKAGER", c.packager);

    // `!buildflags` means the PKGBUILD wants a clean compiler environment.
    if (!ctx.flags.buildflags) {
        try env.put("CFLAGS", "");
        try env.put("CXXFLAGS", "");
        try env.put("LDFLAGS", "");
        return;
    }

    const extra = try std.fmt.allocPrint(gpa, "{s}{s}", .{
        if (ctx.flags.lto) lto_flag else "",
        if (ctx.flags.debug) debug_flag else "",
    });
    defer gpa.free(extra);

    const cflags = try std.fmt.allocPrint(gpa, "{s}{s}", .{ c.cflags, extra });
    defer gpa.free(cflags);
    try env.put("CFLAGS", cflags);

    const cxxflags = try std.fmt.allocPrint(gpa, "{s}{s}", .{ c.cxxflags, extra });
    defer gpa.free(cxxflags);
    try env.put("CXXFLAGS", cxxflags);

    const ldflags = if (c.store_rpath) |rpath|
        try std.fmt.allocPrint(gpa, "{s}{s} -Wl,-rpath,{s}", .{ c.ldflags, if (ctx.flags.lto) lto_flag else "", rpath })
    else
        try std.fmt.allocPrint(gpa, "{s}{s}", .{ c.ldflags, if (ctx.flags.lto) lto_flag else "" });
    defer gpa.free(ldflags);
    try env.put("LDFLAGS", ldflags);
}

/// Host values detected at build time, replacing makepkg.conf's hardcoded
/// defaults. Owns its own storage.
pub const Host = struct {
    arena: std.heap.ArenaAllocator,
    carch: []const u8,
    chost: []const u8,
    makeflags: []const u8,

    pub fn deinit(self: *Host) void {
        self.arena.deinit();
    }

    /// Apply over a Config, leaving other fields untouched.
    pub fn applyTo(self: Host, config: *Config) void {
        config.carch = self.carch;
        config.chost = self.chost;
        config.makeflags = self.makeflags;
    }
};

/// Probe the machine for architecture, target triple and CPU count. Falls back
/// to the Config defaults for anything that cannot be determined.
pub fn detectHost(gpa: std.mem.Allocator, io: std.Io, workdir: []const u8) !Host {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const tmp = try std.fmt.allocPrint(a, "{s}/.opti-probe", .{workdir});
    const defaults: Config = .{};

    const carch = exec.capture(a, io, "uname -m", tmp) catch
        try a.dupe(u8, defaults.carch);
    const chost = exec.capture(a, io, "gcc -dumpmachine", tmp) catch
        try a.dupe(u8, defaults.chost);

    const nproc = exec.capture(a, io, "nproc", tmp) catch try a.dupe(u8, "1");
    const makeflags = try std.fmt.allocPrint(a, "-j{s}", .{if (nproc.len > 0) nproc else "1"});

    return .{
        .arena = arena,
        .carch = if (carch.len > 0) carch else defaults.carch,
        .chost = if (chost.len > 0) chost else defaults.chost,
        .makeflags = makeflags,
    };
}

/// Tools the lifecycle requires on the host. Reported together so a missing
/// one surfaces before a build starts rather than partway through it.
///
/// Archive handling is native, so no tar implementation appears here; `bsdtar`
/// is consulted only as a fallback for bzip2 and zip sources.
pub const required_tools = [_][]const u8{ "bash", "fakeroot" };

pub const Preflight = struct {
    missing: [required_tools.len][]const u8 = undefined,
    count: usize = 0,

    pub fn ok(self: Preflight) bool {
        return self.count == 0;
    }

    pub fn items(self: *const Preflight) []const []const u8 {
        return self.missing[0..self.count];
    }
};

pub fn preflight(io: std.Io) Preflight {
    var result: Preflight = .{};
    for (required_tools) |tool| {
        if (!exec.exists(io, tool)) {
            result.missing[result.count] = tool;
            result.count += 1;
        }
    }
    return result;
}

const testing = std.testing;

test "only package is mandatory" {
    try testing.expect(Stage.package.required());
    try testing.expect(!Stage.build.required());
    try testing.expect(!Stage.prepare.required());
    try testing.expect(!Stage.check.required());
}

test "fakeroot is confined to package" {
    try testing.expect(Stage.package.needsFakeroot());
    try testing.expect(!Stage.build.needsFakeroot());
}

test "build flags follow options" {
    const srcinfo = @import("srcinfo.zig");

    const off = "pkgbase = x\n\toptions = !buildflags\n";
    var a = try srcinfo.parse(std.testing.allocator, off, "x86_64");
    defer a.deinit();
    try testing.expect(!Flags.fromOptions(&a).buildflags);

    const on = "pkgbase = x\n\toptions = lto\n\toptions = debug\n";
    var b = try srcinfo.parse(std.testing.allocator, on, "x86_64");
    defer b.deinit();
    const f = Flags.fromOptions(&b);
    try testing.expect(f.lto);
    try testing.expect(f.debug);
    try testing.expect(f.buildflags);
}

test "lto and debug default off" {
    const f: Flags = .{};
    try testing.expect(f.buildflags);
    try testing.expect(!f.lto);
    try testing.expect(!f.debug);
}

test "stage names match PKGBUILD function names" {
    try testing.expectEqualStrings("prepare", @tagName(Stage.prepare));
    try testing.expectEqualStrings("package", @tagName(Stage.package));
}
