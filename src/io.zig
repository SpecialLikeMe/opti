//! Central I/O boundary.
//!
//! Every stdout/stderr writer in opti is constructed here so that churn in
//! Zig's `std.Io` API stays contained to this one file. Nothing outside this
//! module should reference `std.Io.File` directly.

const std = @import("std");

pub const Writer = std.Io.Writer;
pub const File = std.Io.File;
pub const Dir = std.Io.Dir;

/// Whether `absolute_path` exists and is reachable.
pub fn exists(io: std.Io, absolute_path: []const u8) bool {
    Dir.accessAbsolute(io, absolute_path, .{}) catch return false;
    return true;
}

/// Recursively remove `absolute_path`. Missing paths are not an error.
pub fn removeTree(io: std.Io, absolute_path: []const u8) !void {
    return Dir.cwd().deleteTree(io, absolute_path);
}

/// Create `absolute_path` and any missing parents.
pub fn makePath(io: std.Io, absolute_path: []const u8) !void {
    return Dir.cwd().createDirPath(io, absolute_path);
}

/// Write `data` to `absolute_path`, replacing any existing file.
pub fn writeFile(io: std.Io, absolute_path: []const u8, data: []const u8) !void {
    return Dir.cwd().writeFile(io, .{ .sub_path = absolute_path, .data = data });
}

/// Read an entire file. Caller owns the result.
pub fn readFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    absolute_path: []const u8,
    limit: std.Io.Limit,
) ![]u8 {
    return Dir.cwd().readFileAlloc(io, absolute_path, gpa, limit);
}

/// Buffered stdout. `buffer` must outlive the returned writer, and the result
/// must not be copied once `&result.interface` has been taken.
pub fn stdout(io: std.Io, buffer: []u8) File.Writer {
    return File.stdout().writer(io, buffer);
}

/// Buffered stderr. Same lifetime rules as `stdout`.
pub fn stderr(io: std.Io, buffer: []u8) File.Writer {
    return File.stderr().writer(io, buffer);
}
