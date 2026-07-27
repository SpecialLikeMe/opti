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

/// Recursively copy the contents of `src` into `dest`, creating `dest`.
pub fn copyTree(
    io: std.Io,
    gpa: std.mem.Allocator,
    src: []const u8,
    dest: []const u8,
) !void {
    var src_dir = try Dir.cwd().openDir(io, src, .{ .iterate = true });
    defer src_dir.close(io);

    try makePath(io, dest);
    var dest_dir = try Dir.cwd().openDir(io, dest, .{});
    defer dest_dir.close(io);

    var walker = try src_dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => dest_dir.createDirPath(io, entry.path) catch {},
            .file => {
                // Parent directories are visited before their contents, but a
                // walk order is not guaranteed, so ensure it exists.
                if (std.fs.path.dirname(entry.path)) |parent| {
                    dest_dir.createDirPath(io, parent) catch {};
                }
                src_dir.copyFile(entry.path, dest_dir, entry.path, io, .{}) catch {};
            },
            else => {},
        }
    }
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
