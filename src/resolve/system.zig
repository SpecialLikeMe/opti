//! Deciding whether a dependency is already satisfied.
//!
//! Order matters more than anything else here:
//!
//!   1. the opti store   — something opti installed
//!   2. the host system  — a library or program already present
//!   3. the AUR          — only for what neither of the above supplies
//!
//! Checking the host *before* the AUR is what stops base libraries resolving
//! to forks. The AUR does not carry mainline `curl`, so a by-provides lookup
//! for `libcurl.so` answers `curl-c-ares`. Since any machine that can compile
//! anything already has libcurl, step 2 settles it and step 3 is never
//! reached. Reversing the order would quietly swap a fork into every build.

const std = @import("std");
const io = @import("../io.zig");
const dep = @import("../mkpkg/dep.zig");
const exec = @import("../mkpkg/exec.zig");
const vercmp = @import("../mkpkg/vercmp.zig");
const store = @import("../store/store.zig");

pub const Source = enum {
    /// Installed by opti.
    store,
    /// Already present on the machine.
    host,
    /// Nothing supplies it.
    unsatisfied,
};

/// Directories searched for shared libraries, covering the multiarch layouts
/// used across distributions rather than assuming Arch's.
const library_dirs = [_][]const u8{
    "/usr/lib",
    "/usr/lib64",
    "/lib",
    "/lib64",
    "/usr/lib/x86_64-linux-gnu",
    "/usr/lib/aarch64-linux-gnu",
    "/usr/local/lib",
};

/// Directories searched for executables.
const binary_dirs = [_][]const u8{
    "/usr/bin",
    "/bin",
    "/usr/local/bin",
    "/usr/sbin",
    "/sbin",
};

/// Packages the build environment necessarily already has.
///
/// `lifecycle.preflight` already requires a working toolchain, so treating
/// these as present is not an assumption — it is a restatement of a
/// precondition. Without this, every resolution reports `glibc` and `binutils`
/// as missing, because neither installs a binary named after itself nor a
/// `lib<name>.so`.
const assumed_present = [_][]const u8{
    "glibc",     "gcc-libs", "binutils", "bash",  "coreutils",
    "filesystem", "linux-api-headers", "sh",     "make",  "sed",
    "grep",      "gawk",     "findutils", "gzip", "tar",
};

fn isAssumedPresent(name: []const u8) bool {
    for (assumed_present) |p| {
        if (std.mem.eql(u8, name, p)) return true;
    }
    return false;
}

/// Cached view of the host, so a resolution walk does not re-probe per
/// dependency. `ldconfig -p` is the authoritative list of libraries the
/// dynamic linker can actually find, which is far more reliable than guessing
/// filenames in a fixed set of directories.
pub const Probe = struct {
    gpa: std.mem.Allocator,
    io_ctx: std.Io,
    /// Raw `ldconfig -p` output; empty when unavailable.
    ldcache: []const u8 = &.{},

    pub fn init(gpa: std.mem.Allocator, io_ctx: std.Io) Probe {
        const text = exec.capture(gpa, io_ctx, "ldconfig -p", "/tmp/.opti-ldcache") catch
            @as([]u8, &.{});
        return .{ .gpa = gpa, .io_ctx = io_ctx, .ldcache = text };
    }

    pub fn deinit(self: *Probe) void {
        if (self.ldcache.len > 0) self.gpa.free(self.ldcache);
    }

    /// Whether the dynamic linker knows a library whose name starts with
    /// `soname`, so `libfoo.so` is satisfied by an installed `libfoo.so.6`.
    pub fn hasSoname(self: Probe, soname: []const u8) bool {
        var lines = std.mem.splitScalar(u8, self.ldcache, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (!std.mem.startsWith(u8, line, soname)) continue;
            // Guard against `libz.so` matching `libzstd.so.1`: the next
            // character must end the name rather than continue it.
            const rest = line[soname.len..];
            if (rest.len == 0 or rest[0] == ' ' or rest[0] == '.') return true;
        }
        return false;
    }
};

/// Where, if anywhere, `want` is already satisfied.
pub fn locate(
    gpa: std.mem.Allocator,
    io_ctx: std.Io,
    lay: store.Layout,
    probe: Probe,
    want: dep.Dep,
) Source {
    if (satisfiedByStore(gpa, io_ctx, lay, want)) return .store;
    if (satisfiedByHost(gpa, io_ctx, probe, want)) return .host;
    return .unsatisfied;
}

/// An installed opti package matching by name, or by a recorded `provides`.
fn satisfiedByStore(
    gpa: std.mem.Allocator,
    io_ctx: std.Io,
    lay: store.Layout,
    want: dep.Dep,
) bool {
    var record = store.read(gpa, io_ctx, lay, want.name) catch return false;
    defer record.deinit();

    // A version constraint must actually hold, not merely the name matching.
    if (want.version == null) return true;
    return vercmp.satisfies(record.version, want);
}

/// A library or program the machine already provides.
fn satisfiedByHost(
    gpa: std.mem.Allocator,
    io_ctx: std.Io,
    probe: Probe,
    want: dep.Dep,
) bool {
    if (want.is_soname) {
        return probe.hasSoname(want.name) or findLibrary(gpa, io_ctx, want.name);
    }

    if (isAssumedPresent(want.name)) return true;
    if (findBinary(gpa, io_ctx, want.name)) return true;

    // A package name is not a soname, so try the forms actually used in
    // practice. `libmpc` is `libmpc.so`, not `liblibmpc.so` — blindly
    // prefixing `lib` gets every already-`lib`-prefixed package wrong.
    if (std.mem.startsWith(u8, want.name, "lib")) {
        const direct = std.fmt.allocPrint(gpa, "{s}.so", .{want.name}) catch return false;
        defer gpa.free(direct);
        if (probe.hasSoname(direct)) return true;

        // `libfoo` may also ship as `foo.so`.
        const stripped = std.fmt.allocPrint(gpa, "{s}.so", .{want.name[3..]}) catch return false;
        defer gpa.free(stripped);
        if (probe.hasSoname(stripped)) return true;
    }

    const prefixed = std.fmt.allocPrint(gpa, "lib{s}.so", .{want.name}) catch return false;
    defer gpa.free(prefixed);
    return probe.hasSoname(prefixed) or findLibrary(gpa, io_ctx, prefixed);
}

/// Search the standard library directories for `soname`, accepting versioned
/// forms: a `libfoo.so.6` on disk satisfies a request for `libfoo.so`.
pub fn findLibrary(gpa: std.mem.Allocator, io_ctx: std.Io, soname: []const u8) bool {
    for (library_dirs) |dir_path| {
        const exact = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, soname }) catch continue;
        defer gpa.free(exact);
        if (io.exists(io_ctx, exact)) return true;

        var dir = std.Io.Dir.cwd().openDir(io_ctx, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io_ctx);

        var it = dir.iterate();
        while (it.next(io_ctx) catch null) |entry| {
            if (std.mem.startsWith(u8, entry.name, soname)) return true;
        }
    }
    return false;
}

pub fn findBinary(gpa: std.mem.Allocator, io_ctx: std.Io, name: []const u8) bool {
    for (binary_dirs) |dir_path| {
        const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir_path, name }) catch continue;
        defer gpa.free(full);
        if (io.exists(io_ctx, full)) return true;
    }
    return false;
}

const testing = std.testing;

test "library directories cover common layouts" {
    var saw_multiarch = false;
    var saw_lib64 = false;
    for (library_dirs) |d| {
        if (std.mem.indexOf(u8, d, "x86_64-linux-gnu") != null) saw_multiarch = true;
        if (std.mem.eql(u8, d, "/usr/lib64")) saw_lib64 = true;
    }
    // Debian-style multiarch and Fedora-style lib64 must both be searched, or
    // host detection only works on Arch.
    try testing.expect(saw_multiarch);
    try testing.expect(saw_lib64);
}

test "source ordering places the store ahead of the host" {
    try testing.expect(@intFromEnum(Source.store) < @intFromEnum(Source.host));
    try testing.expect(@intFromEnum(Source.host) < @intFromEnum(Source.unsatisfied));
}
