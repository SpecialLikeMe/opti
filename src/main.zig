const std = @import("std");
const io = @import("io.zig");
const install = @import("install/main.zig");
const mkpkg = @import("mkpkg/mkpkg.zig");

pub const version = "0.0.0";

const Command = enum { install, uninstall, build, version };

const usage =
    \\usage: opti <command> [arguments]
    \\
    \\commands:
    \\  install <package>     build and install a package into the opti store
    \\  uninstall <package>   remove a package from the opti store
    \\  build <directory>     run the build lifecycle on a PKGBUILD directory
    \\  version               print the opti version
    \\
    \\build options:
    \\  --nocheck             skip check()
    \\  --skipchecksums       do not validate source checksums
    \\  --holdver             do not run pkgver()
    \\
;

pub fn main(init: std.process.Init) !void {
    var out_buf: [4096]u8 = undefined;
    var out_file = io.stdout(init.io, &out_buf);
    const out = &out_file.interface;

    const ok = dispatch(init, out) catch |err| blk: {
        // Failures are reported by the layer that detects them; anything that
        // reaches here without a message still needs to be visible.
        if (err != install.Error.PackageNotFound) {
            out.print("opti: {t}\n", .{err}) catch {};
        }
        break :blk false;
    };

    out.flush() catch {};
    if (!ok) std.process.exit(1);
}

/// Returns whether the command succeeded, so `main` owns the exit code.
fn dispatch(init: std.process.Init, out: *std.Io.Writer) !bool {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // argv[0] is the program name; a bare `opti` is not an error, just usage.
    if (args.len < 2) {
        try out.writeAll(usage);
        return true;
    }

    const cmd = std.meta.stringToEnum(Command, args[1]) orelse {
        try out.print("unknown command: {s}\n\n{s}", .{ args[1], usage });
        return false;
    };

    switch (cmd) {
        .install => {
            if (args.len < 3) {
                try out.writeAll("install: expected a package name\n");
                return false;
            }
            try install.run(init.gpa, init.io, out, args[2]);
        },
        .uninstall => try out.writeAll("uninstall: not implemented yet\n"),
        .build => {
            var dir: ?[]const u8 = null;
            var opts: mkpkg.driver.BuildOptions = .{};

            for (args[2..]) |arg| {
                if (std.mem.eql(u8, arg, "--nocheck")) {
                    opts.skip_check = true;
                } else if (std.mem.eql(u8, arg, "--skipchecksums")) {
                    opts.skip_checksums = true;
                } else if (std.mem.eql(u8, arg, "--holdver")) {
                    opts.hold_version = true;
                } else if (std.mem.startsWith(u8, arg, "--")) {
                    try out.print("build: unknown option {s}\n", .{arg});
                    return false;
                } else {
                    dir = arg;
                }
            }

            const target = dir orelse {
                try out.writeAll("build: expected a PKGBUILD directory\n");
                return false;
            };
            try mkpkg.driver.build(init.gpa, init.io, init.environ_map, out, target, .{}, opts);
        },
        .version => try out.print("opti {s}\n", .{version}),
    }
    return true;
}

test {
    _ = mkpkg;
}
