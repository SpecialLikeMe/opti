//! Child process execution.
//!
//! mkpkg shells out for exactly three things: bash (to run PKGBUILD
//! functions), fakeroot (to fake ownership during `package()`), and bsdtar
//! (archive handling). Everything else is implemented in Zig. Keeping the
//! spawn surface in one file makes that boundary auditable.

const std = @import("std");

pub const Error = error{
    /// The child exited with a nonzero status.
    ProcessFailed,
    /// The child was killed or stopped by a signal.
    ProcessSignalled,
};

pub const Options = struct {
    /// Working directory for the child. Inherited when null.
    cwd: ?[]const u8 = null,
    /// Complete replacement environment. Inherited when null.
    env: ?*const std.process.Environ.Map = null,
};

/// Run to completion and return the exit status.
pub fn run(io: std.Io, argv: []const []const u8, opts: Options) !u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (opts.cwd) |p| .{ .path = p } else .inherit,
        .environ_map = opts.env,
    });
    return switch (try child.wait(io)) {
        .exited => |code| code,
        .signal, .stopped => Error.ProcessSignalled,
        .unknown => Error.ProcessFailed,
    };
}

/// Run and require a zero exit status.
pub fn check(io: std.Io, argv: []const []const u8, opts: Options) !void {
    if (try run(io, argv, opts) != 0) return Error.ProcessFailed;
}

/// Whether `name` resolves on PATH. Used for the preflight check, so a missing
/// build tool is reported up front rather than from inside someone's build().
pub fn exists(io: std.Io, name: []const u8) bool {
    const code = run(io, &.{ "sh", "-c", "command -v \"$0\" >/dev/null 2>&1", name }, .{}) catch return false;
    return code == 0;
}

/// Run `command` through a shell and return its trimmed stdout.
///
/// Output is routed through a file rather than a pipe: `std.process.spawn`
/// exposes no capture mode, and a file avoids any risk of deadlocking on a
/// full pipe buffer. `tmp_path` must not contain a single quote.
/// Generous enough for `ldconfig -p`, which runs to roughly 100 KB on a
/// developer machine. A tight limit here fails with `StreamTooLong` and, since
/// callers treat a capture failure as "no output", silently disables whatever
/// depended on it.
const capture_limit = 4 * 1024 * 1024;

pub fn capture(
    gpa: std.mem.Allocator,
    io: std.Io,
    command: []const u8,
    tmp_path: []const u8,
) ![]u8 {
    const script = try std.fmt.allocPrint(gpa, "{s} > '{s}' 2>/dev/null", .{ command, tmp_path });
    defer gpa.free(script);

    try check(io, &.{ "sh", "-c", script }, .{});

    const raw = try std.Io.Dir.cwd().readFileAlloc(io, tmp_path, gpa, .limited(capture_limit));
    defer gpa.free(raw);
    std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    return gpa.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
}
