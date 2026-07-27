//! `optimkp.toml` — opti's equivalent of `makepkg.conf`.
//!
//! Arch's `makepkg.conf` is read from `/etc/`, which is exactly the sort of
//! distro-specific assumption opti avoids. Instead the same settings live in a
//! TOML file resolved from the most specific location available:
//!
//!   1. `<pkgbuild dir>/optimkp.toml`   per-package override
//!   2. `$XDG_CONFIG_HOME/opti/optimkp.toml` or `~/.config/opti/optimkp.toml`
//!   3. `/etc/opti/optimkp.toml`        machine-wide
//!
//! The first file found wins outright; settings are not merged across files,
//! so what a given file says is what applies. Anything a file omits keeps the
//! built-in default, which is itself derived from the host where possible.
//!
//! ```toml
//! [build]
//! cflags   = "-O2 -pipe -fno-plt"
//! ldflags  = "-Wl,-O1"
//! makeflags = "-j8"          # omit to use one job per detected CPU
//! carch    = "x86_64"        # omit to detect
//! packager = "Devon <me@example.com>"
//!
//! [package]
//! compression = "zstd"       # zstd | gzip | none
//!
//! [options]                  # defaults for options=() a PKGBUILD omits
//! strip = true
//! docs  = false
//! ```

const std = @import("std");
const toml = @import("toml.zig");
const lifecycle = @import("lifecycle.zig");
const tidy = @import("tidy.zig");
const archive = @import("archive.zig");

pub const file_name = "optimkp.toml";

/// Default zstd level, matching Arch's packaging defaults. Lower it in
/// `optimkp.toml` on memory-constrained machines: zstd's own footprint at high
/// levels dwarfs opti's, which stays around 10 MB regardless of package size.
pub const default_level: u8 = 19;

pub const Error = error{UnknownCompression};

/// Settings loaded from disk. Every field is optional: absent means "keep the
/// built-in or detected value".
pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    /// Where the settings came from, for reporting. Empty when none was found.
    source_path: []const u8 = "",

    cflags: ?[]const u8 = null,
    cxxflags: ?[]const u8 = null,
    ldflags: ?[]const u8 = null,
    makeflags: ?[]const u8 = null,
    carch: ?[]const u8 = null,
    chost: ?[]const u8 = null,
    packager: ?[]const u8 = null,
    compression: ?archive.Compression = null,
    /// zstd level. Higher is smaller but costs the zstd process considerably
    /// more memory, which matters on constrained machines.
    compression_level: ?u8 = null,
    /// Option defaults, applied before the PKGBUILD's own `options=()`.
    option_overrides: []const OptionOverride = &.{},

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }

    pub fn found(self: Config) bool {
        return self.source_path.len > 0;
    }

    /// Apply to a lifecycle config, leaving unset fields alone.
    pub fn applyTo(self: Config, target: *lifecycle.Config) void {
        if (self.cflags) |v| target.cflags = v;
        if (self.cxxflags) |v| target.cxxflags = v;
        if (self.ldflags) |v| target.ldflags = v;
        if (self.makeflags) |v| target.makeflags = v;
        if (self.carch) |v| target.carch = v;
        if (self.chost) |v| target.chost = v;
        if (self.packager) |v| target.packager = v;
    }

    /// Apply option defaults. The PKGBUILD's own `options=()` is applied after
    /// this, so a package always overrides the machine's preference.
    pub fn applyOptions(self: Config, target: *tidy.Options) void {
        for (self.option_overrides) |o| {
            inline for (@typeInfo(tidy.Options).@"struct".fields) |f| {
                if (f.type == bool and std.mem.eql(u8, f.name, o.name)) {
                    @field(target, f.name) = o.value;
                }
            }
        }
    }
};

pub const OptionOverride = struct {
    name: []const u8,
    value: bool,
};

/// Locate and load the most specific config file. Returns an empty Config when
/// none exists, which is not an error.
pub fn load(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    pkgbuild_dir: []const u8,
) !Config {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var candidates: std.ArrayList([]const u8) = .empty;
    try candidates.append(a, try std.fmt.allocPrint(a, "{s}/{s}", .{ pkgbuild_dir, file_name }));

    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        try candidates.append(a, try std.fmt.allocPrint(a, "{s}/opti/{s}", .{ xdg, file_name }));
    } else if (env.get("HOME")) |home| {
        try candidates.append(a, try std.fmt.allocPrint(a, "{s}/.config/opti/{s}", .{ home, file_name }));
    }
    try candidates.append(a, try std.fmt.allocPrint(a, "/etc/opti/{s}", .{file_name}));

    for (candidates.items) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(256 * 1024)) catch continue;
        var doc = try toml.parse(gpa, text);
        defer doc.deinit();

        const fields = try readFields(a, doc, path);
        // The arena is moved in only now: it carries mutable state, so copying
        // it before these allocations finish would leave the result holding a
        // stale snapshot and leak everything allocated after.
        return fields.attach(arena);
    }

    return .{ .arena = arena };
}

/// Everything read from a document, without the arena that backs it.
const Fields = struct {
    source_path: []const u8 = "",
    cflags: ?[]const u8 = null,
    cxxflags: ?[]const u8 = null,
    ldflags: ?[]const u8 = null,
    makeflags: ?[]const u8 = null,
    carch: ?[]const u8 = null,
    chost: ?[]const u8 = null,
    packager: ?[]const u8 = null,
    compression: ?archive.Compression = null,
    compression_level: ?u8 = null,
    option_overrides: []const OptionOverride = &.{},

    fn attach(self: Fields, arena: std.heap.ArenaAllocator) Config {
        return .{
            .arena = arena,
            .source_path = self.source_path,
            .cflags = self.cflags,
            .cxxflags = self.cxxflags,
            .ldflags = self.ldflags,
            .makeflags = self.makeflags,
            .carch = self.carch,
            .chost = self.chost,
            .packager = self.packager,
            .compression = self.compression,
            .compression_level = self.compression_level,
            .option_overrides = self.option_overrides,
        };
    }
};

fn readFields(a: std.mem.Allocator, doc: toml.Table, path: []const u8) !Fields {
    var f: Fields = .{ .source_path = try a.dupe(u8, path) };

    // Values are duped because `doc` owns its own arena and is freed by the
    // caller as soon as this returns.
    if (doc.getString("build.cflags")) |v| f.cflags = try a.dupe(u8, v);
    if (doc.getString("build.cxxflags")) |v| f.cxxflags = try a.dupe(u8, v);
    if (doc.getString("build.ldflags")) |v| f.ldflags = try a.dupe(u8, v);
    if (doc.getString("build.makeflags")) |v| f.makeflags = try a.dupe(u8, v);
    if (doc.getString("build.carch")) |v| f.carch = try a.dupe(u8, v);
    if (doc.getString("build.chost")) |v| f.chost = try a.dupe(u8, v);
    if (doc.getString("build.packager")) |v| f.packager = try a.dupe(u8, v);

    if (doc.getString("package.compression")) |v| {
        f.compression = try parseCompression(v);
    }
    if (doc.getInteger("package.compression_level")) |v| {
        f.compression_level = std.math.cast(u8, v) orelse default_level;
    }

    var overrides: std.ArrayList(OptionOverride) = .empty;
    inline for (@typeInfo(tidy.Options).@"struct".fields) |field| {
        if (field.type == bool) {
            if (doc.getBool("options." ++ field.name)) |value| {
                try overrides.append(a, .{ .name = field.name, .value = value });
            }
        }
    }
    f.option_overrides = try overrides.toOwnedSlice(a);

    return f;
}

fn parseCompression(name: []const u8) Error!archive.Compression {
    if (std.mem.eql(u8, name, "zstd")) return .zstd;
    if (std.mem.eql(u8, name, "gzip") or std.mem.eql(u8, name, "gz")) return .gzip;
    if (std.mem.eql(u8, name, "none")) return .none;
    return Error.UnknownCompression;
}

const testing = std.testing;

test "compression names" {
    try testing.expectEqual(archive.Compression.zstd, try parseCompression("zstd"));
    try testing.expectEqual(archive.Compression.gzip, try parseCompression("gzip"));
    try testing.expectEqual(archive.Compression.gzip, try parseCompression("gz"));
    try testing.expectEqual(archive.Compression.none, try parseCompression("none"));
    try testing.expectError(Error.UnknownCompression, parseCompression("bzip2"));
}

test "settings apply over defaults, absent ones do not" {
    const text =
        \\[build]
        \\cflags = "-Os"
        \\packager = "Tester <t@example.com>"
    ;
    var doc = try toml.parse(testing.allocator, text);
    defer doc.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    var cfg = (try readFields(arena.allocator(), doc, "test")).attach(arena);
    defer cfg.deinit();

    var target: lifecycle.Config = .{};
    const original_ldflags = target.ldflags;
    cfg.applyTo(&target);

    try testing.expectEqualStrings("-Os", target.cflags);
    try testing.expectEqualStrings("Tester <t@example.com>", target.packager);
    // Not mentioned in the file, so untouched.
    try testing.expectEqualStrings(original_ldflags, target.ldflags);
}

test "option defaults are collected" {
    const text =
        \\[options]
        \\strip = false
        \\staticlibs = true
    ;
    var doc = try toml.parse(testing.allocator, text);
    defer doc.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    var cfg = (try readFields(arena.allocator(), doc, "test")).attach(arena);
    defer cfg.deinit();

    var opts: tidy.Options = .{};
    cfg.applyOptions(&opts);

    try testing.expect(!opts.strip);
    try testing.expect(opts.staticlibs);
    // Untouched keeps its default.
    try testing.expect(opts.zipman);
}

test "no config file at all reports not found" {
    // What `load` returns when nothing exists on any search path.
    var cfg: Config = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    defer cfg.deinit();

    try testing.expect(!cfg.found());
    try testing.expectEqual(@as(?[]const u8, null), cfg.cflags);

    // Applying it must leave every default untouched.
    var target: lifecycle.Config = .{};
    const before = target;
    cfg.applyTo(&target);
    try testing.expectEqualStrings(before.cflags, target.cflags);
    try testing.expectEqualStrings(before.packager, target.packager);
}
