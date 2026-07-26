const std = @import("std");
const web = @import("get");

pub fn install(allocator: std.mem.Allocator, curl: anytype, pkg: []const u8) !void {
    const dir = std.fmt.allocPrint(allocator, "/var/lib/opti/{nm}", .{ .nm = pkg});
    _ = try web.clone_to_dir()
}