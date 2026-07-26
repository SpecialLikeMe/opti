const std = @import("std");

extern fn system(cmd: [*:0]const u8) c_int;

const cmds = enum {
    install,
    uninstall,
    version,
};

pub fn main() !void {
    //init gpa
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    //get proc args
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    //turn the str into an enum instance
    const cmd = std.meta.stringToEnum(cmds, argv[1]) orelse {
        std.debug.print("Unknown command: {s}\n", .{argv[1]});
        return;
    };

    switch (cmd) {
        .install => {
            
        },
    }
}