const std = @import("std");
const io = @import("io.zig");
const aur = @import("install/main.zig");
const mkpkg = @import("mkpkg/mkpkg.zig");
const store = @import("store/store.zig");
const resolve = @import("resolve/resolve.zig");

pub const version = "0.0.0";

const Command = enum { install, uninstall, remove, build, list, files, version };

const usage =
    \\usage: opti <command> [arguments]
    \\
    \\commands:
    \\  install <dir|package>   build and install a PKGBUILD directory, or an
    \\                          AUR package by name
    \\  uninstall <package>     remove an installed package (alias: remove)
    \\  build <directory>       build a PKGBUILD directory without installing
    \\  list                    list installed packages
    \\  files <package>         list the files a package owns
    \\  version                 print the opti version
    \\
    \\build options:
    \\  --nocheck               skip check()
    \\  --skipchecksums         do not validate source checksums
    \\  --holdver               do not run pkgver()
    \\
;

pub fn main(init: std.process.Init) !void {
    var out_buf: [4096]u8 = undefined;
    var out_file = io.stdout(init.io, &out_buf);
    const out = &out_file.interface;

    const ok = dispatch(init, out) catch |err| blk: {
        // Failures are reported by the layer that detects them; anything that
        // reaches here without a message still needs to be visible.
        if (err != aur.Error.PackageNotFound) {
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

    const lay: store.Layout = .{};

    switch (cmd) {
        .build, .install => {
            var dir: ?[]const u8 = null;
            var opts: mkpkg.driver.BuildOptions = .{};
            var no_confirm = false;

            for (args[2..]) |arg| {
                if (std.mem.eql(u8, arg, "--nocheck")) {
                    opts.skip_check = true;
                } else if (std.mem.eql(u8, arg, "--skipchecksums")) {
                    opts.skip_checksums = true;
                } else if (std.mem.eql(u8, arg, "--holdver")) {
                    opts.hold_version = true;
                } else if (std.mem.eql(u8, arg, "--noconfirm")) {
                    no_confirm = true;
                } else if (std.mem.startsWith(u8, arg, "--")) {
                    try out.print("{s}: unknown option {s}\n", .{ @tagName(cmd), arg });
                    return false;
                } else {
                    dir = arg;
                }
            }

            const target = dir orelse {
                try out.print("{s}: expected a PKGBUILD directory\n", .{@tagName(cmd)});
                return false;
            };

            // Only an install needs its binaries to resolve store libraries; a
            // bare build stays relocatable and unopinionated about RPATH.
            const lib_dir = if (cmd == .install) try lay.lib(init.gpa) else null;
            defer if (lib_dir) |d| init.gpa.free(d);
            opts.store_lib_dir = lib_dir;

            // A local PKGBUILD directory is built as-is. A bare name is an AUR
            // package, and its dependency graph is resolved first.
            if (aur.isLocalDir(init.io, target)) {
                return buildAndInstall(init, out, lay, target, opts, cmd == .install);
            }

            if (cmd == .build) {
                try out.writeAll("build: expected a PKGBUILD directory\n");
                return false;
            }

            var p = try resolve.plan(init.gpa, init.io, lay, target, true);
            defer p.deinit();

            if (!try report(init, out, &p, target, no_confirm)) return false;

            for (p.steps) |step| {
                const cache = try lay.sourceCache(init.gpa, step.name);
                defer init.gpa.free(cache);
                const dest = try init.gpa.dupeZ(u8, cache);
                defer init.gpa.free(dest);

                try aur.fetch(init.gpa, init.io, out, step.name, dest);
                if (!try buildAndInstall(init, out, lay, dest, opts, true)) return false;
            }
        },

        .uninstall, .remove => {
            var name: ?[]const u8 = null;
            var force = false;
            for (args[2..]) |arg| {
                if (std.mem.eql(u8, arg, "--force")) {
                    force = true;
                } else if (std.mem.startsWith(u8, arg, "--")) {
                    try out.print("uninstall: unknown option {s}\n", .{arg});
                    return false;
                } else {
                    name = arg;
                }
            }

            const pkg = name orelse {
                try out.writeAll("uninstall: expected a package name\n");
                return false;
            };

            const dependents = try store.requiredBy(init.gpa, init.io, lay, pkg);
            defer {
                for (dependents) |d| init.gpa.free(d);
                init.gpa.free(dependents);
            }

            if (dependents.len > 0 and !force) {
                try out.print("{s} is required by:\n", .{pkg});
                for (dependents) |d| try out.print("  {s}\n", .{d});
                try out.writeAll("refusing to remove; pass --force to override\n");
                return false;
            }

            try store.remove(init.gpa, init.io, lay, pkg, out);
        },

        .list => {
            const names = try store.list(init.gpa, init.io, lay);
            defer {
                for (names) |n| init.gpa.free(n);
                init.gpa.free(names);
            }
            if (names.len == 0) {
                try out.writeAll("no packages installed\n");
                return true;
            }
            for (names) |name| {
                var record = store.read(init.gpa, init.io, lay, name) catch continue;
                defer record.deinit();
                try out.print("{s} {s}\n", .{ record.name, record.version });
            }
        },

        .files => {
            if (args.len < 3) {
                try out.writeAll("files: expected a package name\n");
                return false;
            }
            var record = try store.read(init.gpa, init.io, lay, args[2]);
            defer record.deinit();
            for (record.files) |f| try out.print("{s}/{s}\n", .{ record.prefix, f });
        },

        .version => try out.print("opti {s}\n", .{version}),
    }
    return true;
}

/// Show the resolution result and ask before proceeding.
/// Returns false when the plan cannot or should not run.
fn report(
    init: std.process.Init,
    out: *std.Io.Writer,
    p: *const resolve.Plan,
    target: []const u8,
    no_confirm: bool,
) !bool {
    if (p.system.len > 0) {
        try out.writeAll("needs packages from Arch's official repositories:\n");
        for (p.system) |s| {
            if (s.required_by.len > 0) {
                try out.print("  {s} ({s}, required by {s})\n", .{ s.name, s.repo, s.required_by });
            } else {
                try out.print("  {s} ({s})\n", .{ s.name, s.repo });
            }
        }
        // opti has no PKGBUILD for an official package and no binary path yet,
        // so these have to come from the host's own package manager.
        try out.writeAll("install these with your system package manager first\n");
    }

    if (p.missing.len > 0) {
        try out.writeAll("cannot resolve:\n");
        for (p.missing) |m| {
            if (m.required_by.len > 0) {
                try out.print("  {s} (required by {s})\n", .{ m.spec, m.required_by });
            } else {
                try out.print("  {s}\n", .{m.spec});
            }
        }
    }

    if (!p.ok()) return false;

    if (p.steps.len == 0) {
        try out.print("{s}: nothing to do\n", .{target});
        return false;
    }

    if (p.satisfied.len > 0) {
        try out.print("already satisfied: {d}\n", .{p.satisfied.len});
    }

    try out.writeAll("the following will be built and installed:\n");
    for (p.steps) |step| {
        if (step.required_by.len == 0) {
            try out.print("  {s} {s}\n", .{ step.name, step.version });
        } else {
            try out.print("  {s} {s}  (for {s})\n", .{ step.name, step.version, step.required_by });
        }
    }

    // A variant pulled in indirectly builds an unreleased or prebuilt fork of
    // something else's dependency, which is rarely what was intended.
    for (p.steps) |step| {
        if (!step.is_variant) continue;
        try out.print(
            "warning: {s} is a variant package pulled in to satisfy {s}\n",
            .{ step.name, step.required_by },
        );
    }

    if (no_confirm) return true;
    if (!io.confirm(init.io, out, "proceed?")) {
        try out.writeAll("aborted\n");
        return false;
    }
    return true;
}

/// Build a PKGBUILD directory, optionally installing what it produces.
fn buildAndInstall(
    init: std.process.Init,
    out: *std.Io.Writer,
    lay: store.Layout,
    dir: []const u8,
    opts: mkpkg.driver.BuildOptions,
    do_install: bool,
) !bool {
    const built = try mkpkg.driver.build(
        init.gpa,
        init.io,
        init.environ_map,
        out,
        dir,
        .{},
        opts,
    );
    defer {
        for (built) |a| init.gpa.free(a);
        init.gpa.free(built);
    }

    if (!do_install) return true;

    if (built.len == 0) {
        try out.writeAll("install: the build produced no artifact\n");
        return false;
    }
    // A split PKGBUILD emits several artifacts; install every one.
    for (built) |artifact| {
        _ = try store.install(init.gpa, init.io, lay, artifact, out);
    }
    return true;
}

test {
    _ = mkpkg;
    _ = store;
    _ = resolve;
    _ = @import("resolve/aur.zig");
    _ = @import("resolve/official.zig");
    _ = @import("resolve/system.zig");
    _ = @import("store/layout.zig");
    _ = @import("store/manifest.zig");
}
