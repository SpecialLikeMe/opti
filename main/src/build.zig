const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions({});
    const optimize = b.standardOptimizeOption({});

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("./curl/include.c"),
        .target = target,
        .optimize = optimize,
    });

    // 2. Link the libcurl system library flags
    translate_c.linkSystemLibrary("curl", .{});

    const exe = b.addExecutable(.{
        .name = "opti",
        .root_source_file = b.path("./main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // 3. Expose the translated C code as an importable module named "c"
    exe.root_module.addImport("curl", translate_c.createModule());
    exe.linkSystemLibrary("curl");
    exe.linkLibC();

    b.installArtifact(exe);
}
