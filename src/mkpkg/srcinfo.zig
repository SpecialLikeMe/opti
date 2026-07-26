//! Parser for `.SRCINFO`, the static metadata file the AUR requires alongside
//! every PKGBUILD.
//!
//! This exists so that dependency resolution never has to execute anything. A
//! PKGBUILD is a bash script, and reading `depends` from it means sourcing
//! untrusted code before the user has consented to anything. `.SRCINFO` is
//! plain key/value text and carries the same fields, so bash is confined to
//! the build lifecycle where it is genuinely unavoidable.
//!
//! Format: `key = value` lines, indentation insignificant. A `pkgbase` line
//! opens the shared section; each `pkgname` line opens a split-package
//! section which inherits from the base and may override it. Keys may carry an
//! architecture suffix (`depends_x86_64`).

const std = @import("std");
const dep = @import("dep.zig");
const verify = @import("verify.zig");

pub const Dep = dep.Dep;

/// One checksum array, positionally aligned with `sources`.
pub const ChecksumSet = struct {
    algorithm: verify.Algorithm,
    values: []const []const u8,
};

pub const Source = struct {
    /// Local filename from the `name::url` form, when present.
    rename: ?[]const u8 = null,
    /// Location with any VCS prefix removed.
    location: []const u8,
    /// VCS scheme from a `git+`/`svn+`/`hg+`/`bzr+` prefix.
    vcs: ?[]const u8 = null,
};

/// One output package. A non-split PKGBUILD produces exactly one of these.
pub const Package = struct {
    pkgname: []const u8,
    pkgdesc: []const u8 = "",
    url: []const u8 = "",
    /// Scriptlet filename from `install=`, stored in the artifact as `.INSTALL`.
    install: ?[]const u8 = null,
    depends: []const Dep = &.{},
    provides: []const Dep = &.{},
    conflicts: []const Dep = &.{},
    replaces: []const Dep = &.{},
    licenses: []const []const u8 = &.{},
    /// Config files pacman preserves across upgrades.
    backup: []const []const u8 = &.{},
};

pub const SrcInfo = struct {
    arena: std.heap.ArenaAllocator,

    pkgbase: []const u8 = "",
    pkgver: []const u8 = "",
    pkgrel: []const u8 = "",
    epoch: ?[]const u8 = null,
    pkgdesc: []const u8 = "",
    url: []const u8 = "",

    licenses: []const []const u8 = &.{},
    depends: []const Dep = &.{},
    makedepends: []const Dep = &.{},
    checkdepends: []const Dep = &.{},
    provides: []const Dep = &.{},
    conflicts: []const Dep = &.{},
    replaces: []const Dep = &.{},

    sources: []const Source = &.{},
    checksums: []const ChecksumSet = &.{},
    /// `options=()` entries, `!` prefix retained (e.g. `!lto`).
    options: []const []const u8 = &.{},
    /// Sources listed in `noextract=()`, left packed in $srcdir.
    noextract: []const []const u8 = &.{},

    /// Output packages, always at least one.
    packages: []const Package = &.{},

    pub fn deinit(self: *SrcInfo) void {
        self.arena.deinit();
    }

    /// The strongest checksum array present. makepkg validates only one array,
    /// preferring the strongest, so a PKGBUILD carrying both md5sums and
    /// b2sums is checked against b2sums.
    pub fn strongestChecksums(self: SrcInfo) ?ChecksumSet {
        var best: ?ChecksumSet = null;
        for (self.checksums) |set| {
            if (best == null or set.algorithm.strength() > best.?.algorithm.strength()) {
                best = set;
            }
        }
        return best;
    }

    /// Whether `options` contains `name` (as `name`), or its negation `!name`.
    pub fn option(self: SrcInfo, name: []const u8) ?bool {
        for (self.options) |o| {
            if (o.len > 0 and o[0] == '!') {
                if (std.mem.eql(u8, o[1..], name)) return false;
            } else if (std.mem.eql(u8, o, name)) return true;
        }
        return null;
    }

    /// Full version string, `[epoch:]pkgver-pkgrel`.
    pub fn version(self: SrcInfo, gpa: std.mem.Allocator) ![]u8 {
        if (self.epoch) |e| {
            return std.fmt.allocPrint(gpa, "{s}:{s}-{s}", .{ e, self.pkgver, self.pkgrel });
        }
        return std.fmt.allocPrint(gpa, "{s}-{s}", .{ self.pkgver, self.pkgrel });
    }
};

const vcs_schemes = [_][]const u8{ "git", "svn", "hg", "bzr" };

/// Mutable accumulator for one section of the file.
const Section = struct {
    pkgname: []const u8 = "",
    pkgdesc: ?[]const u8 = null,
    url: ?[]const u8 = null,
    install: ?[]const u8 = null,
    depends: std.ArrayList(Dep) = .empty,
    provides: std.ArrayList(Dep) = .empty,
    conflicts: std.ArrayList(Dep) = .empty,
    replaces: std.ArrayList(Dep) = .empty,
    licenses: std.ArrayList([]const u8) = .empty,
    backup: std.ArrayList([]const u8) = .empty,
};

/// Parse `text`, keeping only entries applicable to `arch`. The result owns
/// its own storage and does not borrow from `text`.
pub fn parse(gpa: std.mem.Allocator, text: []const u8, arch: []const u8) !SrcInfo {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    // Scalars are collected locally: an ArenaAllocator carries mutable state,
    // so copying it into the result before allocation finishes would leave the
    // result holding a stale snapshot and leak everything allocated after.
    var pkgbase: []const u8 = "";
    var pkgver: []const u8 = "";
    var pkgrel: []const u8 = "";
    var epoch: ?[]const u8 = null;

    var makedepends: std.ArrayList(Dep) = .empty;
    var checkdepends: std.ArrayList(Dep) = .empty;
    var sources: std.ArrayList(Source) = .empty;
    var options: std.ArrayList([]const u8) = .empty;
    var noextract: std.ArrayList([]const u8) = .empty;

    const algorithm_count = @typeInfo(verify.Algorithm).@"enum".fields.len;
    var sums: [algorithm_count]std.ArrayList([]const u8) = @splat(.empty);

    var base: Section = .{};
    var splits: std.ArrayList(Section) = .empty;
    // Points at whichever section subsequent keys belong to.
    var current: *Section = &base;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len == 0) continue;

        if (std.mem.eql(u8, key, "pkgbase")) {
            pkgbase = try a.dupe(u8, value);
            current = &base;
            continue;
        }
        if (std.mem.eql(u8, key, "pkgname")) {
            try splits.append(a, .{ .pkgname = try a.dupe(u8, value) });
            current = &splits.items[splits.items.len - 1];
            continue;
        }

        // Fields valid in either a base or a split-package section.
        if (std.mem.eql(u8, key, "pkgdesc")) {
            current.pkgdesc = try a.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "url")) {
            current.url = try a.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "install")) {
            current.install = try a.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "license")) {
            try current.licenses.append(a, try a.dupe(u8, value));
        } else if (std.mem.eql(u8, key, "backup")) {
            try current.backup.append(a, try a.dupe(u8, value));
        } else if (matches(key, "depends", arch)) {
            try current.depends.append(a, Dep.parse(try a.dupe(u8, value)));
        } else if (matches(key, "provides", arch)) {
            try current.provides.append(a, Dep.parse(try a.dupe(u8, value)));
        } else if (matches(key, "conflicts", arch)) {
            try current.conflicts.append(a, Dep.parse(try a.dupe(u8, value)));
        } else if (matches(key, "replaces", arch)) {
            try current.replaces.append(a, Dep.parse(try a.dupe(u8, value)));
        } else if (current != &base) {
            // Remaining keys are base-only; ignore them inside split sections.
            continue;
        } else if (std.mem.eql(u8, key, "pkgver")) {
            pkgver = try a.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "pkgrel")) {
            pkgrel = try a.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "epoch")) {
            epoch = try a.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "options")) {
            try options.append(a, try a.dupe(u8, value));
        } else if (std.mem.eql(u8, key, "noextract")) {
            try noextract.append(a, try a.dupe(u8, value));
        } else if (matches(key, "makedepends", arch)) {
            try makedepends.append(a, Dep.parse(try a.dupe(u8, value)));
        } else if (matches(key, "checkdepends", arch)) {
            try checkdepends.append(a, Dep.parse(try a.dupe(u8, value)));
        } else if (matches(key, "source", arch)) {
            try sources.append(a, try parseSource(a, value));
        } else if (checksumAlgorithm(key, arch)) |alg| {
            try sums[@intFromEnum(alg)].append(a, try a.dupe(u8, value));
        }
    }

    var checksums: std.ArrayList(ChecksumSet) = .empty;
    for (&sums, 0..) |*list, idx| {
        if (list.items.len == 0) continue;
        try checksums.append(a, .{
            .algorithm = @enumFromInt(idx),
            .values = try list.toOwnedSlice(a),
        });
    }

    // A PKGBUILD with no explicit pkgname still produces one package.
    if (splits.items.len == 0) {
        try splits.append(a, .{ .pkgname = pkgbase });
    }

    var packages: std.ArrayList(Package) = .empty;
    for (splits.items) |*s| {
        try packages.append(a, try finalize(a, s, &base));
    }

    // Every allocation must complete before `arena` is copied into the result,
    // including these, since toOwnedSlice may reallocate.
    const out_base_licenses = try base.licenses.toOwnedSlice(a);
    const out_base_depends = try base.depends.toOwnedSlice(a);
    const out_base_provides = try base.provides.toOwnedSlice(a);
    const out_base_conflicts = try base.conflicts.toOwnedSlice(a);
    const out_base_replaces = try base.replaces.toOwnedSlice(a);
    const out_makedepends = try makedepends.toOwnedSlice(a);
    const out_checkdepends = try checkdepends.toOwnedSlice(a);
    const out_sources = try sources.toOwnedSlice(a);
    const out_checksums = try checksums.toOwnedSlice(a);
    const out_options = try options.toOwnedSlice(a);
    const out_noextract = try noextract.toOwnedSlice(a);
    const out_packages = try packages.toOwnedSlice(a);

    return .{
        .arena = arena,
        .pkgbase = pkgbase,
        .pkgver = pkgver,
        .pkgrel = pkgrel,
        .epoch = epoch,
        .pkgdesc = base.pkgdesc orelse "",
        .url = base.url orelse "",
        .licenses = out_base_licenses,
        .depends = out_base_depends,
        .makedepends = out_makedepends,
        .checkdepends = out_checkdepends,
        .provides = out_base_provides,
        .conflicts = out_base_conflicts,
        .replaces = out_base_replaces,
        .sources = out_sources,
        .checksums = out_checksums,
        .options = out_options,
        .noextract = out_noextract,
        .packages = out_packages,
    };
}

/// Merge a split-package section over the base. Scalars fall back to the base
/// when unset; arrays are inherited only when the split declares none, which
/// matches how makepkg overrides package-level variables.
fn finalize(a: std.mem.Allocator, s: *Section, base: *const Section) !Package {
    return .{
        .pkgname = s.pkgname,
        .pkgdesc = s.pkgdesc orelse base.pkgdesc orelse "",
        .url = s.url orelse base.url orelse "",
        .install = s.install orelse base.install,
        .depends = try inherit(a, &s.depends, base.depends.items),
        .provides = try inherit(a, &s.provides, base.provides.items),
        .conflicts = try inherit(a, &s.conflicts, base.conflicts.items),
        .replaces = try inherit(a, &s.replaces, base.replaces.items),
        .licenses = try inheritStrings(a, &s.licenses, base.licenses.items),
        .backup = try inheritStrings(a, &s.backup, base.backup.items),
    };
}

fn inherit(a: std.mem.Allocator, own: *std.ArrayList(Dep), from_base: []const Dep) ![]const Dep {
    if (own.items.len > 0) return own.toOwnedSlice(a);
    return from_base;
}

fn inheritStrings(
    a: std.mem.Allocator,
    own: *std.ArrayList([]const u8),
    from_base: []const []const u8,
) ![]const []const u8 {
    if (own.items.len > 0) return own.toOwnedSlice(a);
    return from_base;
}

/// True for `base` itself or for `base_<arch>` matching the target.
/// `optdepends` deliberately does not match `depends`.
fn matches(key: []const u8, base: []const u8, arch: []const u8) bool {
    if (std.mem.eql(u8, key, base)) return true;
    if (key.len > base.len + 1 and
        std.mem.startsWith(u8, key, base) and
        key[base.len] == '_')
    {
        return std.mem.eql(u8, key[base.len + 1 ..], arch);
    }
    return false;
}

/// Recognise `sha256sums` and its arch-suffixed form. The suffix is matched
/// from the end because architecture names themselves contain underscores
/// (`x86_64`), so splitting on the last underscore would be wrong.
fn checksumAlgorithm(key: []const u8, arch: []const u8) ?verify.Algorithm {
    if (verify.Algorithm.fromKeyName(key)) |alg| return alg;

    if (key.len > arch.len + 1 and
        std.mem.endsWith(u8, key, arch) and
        key[key.len - arch.len - 1] == '_')
    {
        return verify.Algorithm.fromKeyName(key[0 .. key.len - arch.len - 1]);
    }
    return null;
}

fn parseSource(a: std.mem.Allocator, value: []const u8) !Source {
    var rename: ?[]const u8 = null;
    var location = value;

    if (std.mem.indexOf(u8, value, "::")) |i| {
        rename = try a.dupe(u8, value[0..i]);
        location = value[i + 2 ..];
    }

    var vcs: ?[]const u8 = null;
    for (vcs_schemes) |scheme| {
        if (location.len > scheme.len and
            std.mem.startsWith(u8, location, scheme) and
            location[scheme.len] == '+')
        {
            vcs = scheme;
            location = location[scheme.len + 1 ..];
            break;
        }
    }

    return .{
        .rename = rename,
        .location = try a.dupe(u8, location),
        .vcs = vcs,
    };
}

const testing = std.testing;

// Trimmed from the real aur.archlinux.org/yay.git .SRCINFO.
const yay_srcinfo =
    \\pkgbase = yay
    \\  pkgdesc = Yet another yogurt. Pacman wrapper and AUR helper written in go.
    \\  pkgver = 13.0.1
    \\  pkgrel = 1
    \\  url = https://github.com/Jguer/yay
    \\  arch = x86_64
    \\  arch = aarch64
    \\  license = GPL-3.0-or-later
    \\  makedepends = go>=1.24
    \\  depends = pacman>6.1
    \\  depends = git
    \\  optdepends = sudo: privilege elevation
    \\  options = !lto
    \\  source = yay-13.0.1.tar.gz::https://github.com/Jguer/yay/archive/v13.0.1.tar.gz
    \\  sha256sums = b77454bce87110180a1b6664c2d260de78124c9894b71101610ba84f551eb0d0
    \\
    \\pkgname = yay
    \\
;

// Real .SRCINFO files are tab-indented; Zig multiline literals cannot hold a
// literal tab, so this fixture uses escapes to cover the actual on-disk form.
const tab_indented = "pkgbase = curl\n\tpkgver = 8.21.0\n\tprovides = libcurl.so=4-64\n\tdepends = glibc\n";

const hello_srcinfo = "pkgbase = hello\n" ++
    "\tpkgver = 2.12.1\n" ++
    "\tpkgrel = 1\n" ++
    "\tarch = x86_64\n" ++
    "\tsource = https://ftp.gnu.org/gnu/hello/hello-2.12.1.tar.gz\n" ++
    "\tsha256sums = 8d99142afd92576f30b0cd7cb42a8dc6809998bc5d607d88761f512e26c7db20\n" ++
    "\npkgname = hello\n";

test "tab-indented input parses" {
    var si = try parse(testing.allocator, tab_indented, "x86_64");
    defer si.deinit();

    try testing.expectEqualStrings("curl", si.pkgbase);
    try testing.expectEqualStrings("8.21.0", si.pkgver);
    try testing.expectEqualStrings("libcurl.so", si.provides[0].name);
    try testing.expectEqualStrings("glibc", si.depends[0].name);
}

test "plain url source is captured" {
    var si = try parse(testing.allocator, hello_srcinfo, "x86_64");
    defer si.deinit();

    try testing.expectEqual(@as(usize, 1), si.sources.len);
    try testing.expectEqualStrings(
        "https://ftp.gnu.org/gnu/hello/hello-2.12.1.tar.gz",
        si.sources[0].location,
    );
    try testing.expectEqual(@as(?[]const u8, null), si.sources[0].rename);

    const sums = si.strongestChecksums().?;
    try testing.expectEqual(verify.Algorithm.sha256, sums.algorithm);
    try testing.expectEqual(@as(usize, 1), sums.values.len);
}

test "parses yay metadata" {
    var si = try parse(testing.allocator, yay_srcinfo, "x86_64");
    defer si.deinit();

    try testing.expectEqualStrings("yay", si.pkgbase);
    try testing.expectEqualStrings("13.0.1", si.pkgver);
    try testing.expectEqualStrings("1", si.pkgrel);
    try testing.expectEqual(@as(?[]const u8, null), si.epoch);

    try testing.expectEqual(@as(usize, 1), si.packages.len);
    try testing.expectEqualStrings("yay", si.packages[0].pkgname);
}

test "dependency constraints survive parsing" {
    var si = try parse(testing.allocator, yay_srcinfo, "x86_64");
    defer si.deinit();

    try testing.expectEqual(@as(usize, 2), si.depends.len);
    try testing.expectEqualStrings("pacman", si.depends[0].name);
    try testing.expectEqual(dep.Op.gt, si.depends[0].op);
    try testing.expectEqualStrings("6.1", si.depends[0].version.?);
    try testing.expectEqualStrings("git", si.depends[1].name);

    try testing.expectEqual(@as(usize, 1), si.makedepends.len);
    try testing.expectEqualStrings("go", si.makedepends[0].name);
    try testing.expectEqual(dep.Op.ge, si.makedepends[0].op);
}

test "optdepends is not mistaken for depends" {
    var si = try parse(testing.allocator, yay_srcinfo, "x86_64");
    defer si.deinit();

    for (si.depends) |d| {
        try testing.expect(!std.mem.startsWith(u8, d.name, "sudo"));
    }
}

test "source rename is split from url" {
    var si = try parse(testing.allocator, yay_srcinfo, "x86_64");
    defer si.deinit();

    try testing.expectEqual(@as(usize, 1), si.sources.len);
    try testing.expectEqualStrings("yay-13.0.1.tar.gz", si.sources[0].rename.?);
    try testing.expectEqualStrings(
        "https://github.com/Jguer/yay/archive/v13.0.1.tar.gz",
        si.sources[0].location,
    );
}

test "vcs prefix is stripped" {
    const text =
        \\pkgbase = example
        \\  source = example::git+https://example.com/repo.git
        \\
    ;
    var si = try parse(testing.allocator, text, "x86_64");
    defer si.deinit();

    try testing.expectEqualStrings("git", si.sources[0].vcs.?);
    try testing.expectEqualStrings("https://example.com/repo.git", si.sources[0].location);
}

test "arch-suffixed keys are filtered by target" {
    const text =
        \\pkgbase = example
        \\  depends = common
        \\  depends_x86_64 = only-on-amd64
        \\  depends_aarch64 = only-on-arm
        \\
    ;
    var si = try parse(testing.allocator, text, "x86_64");
    defer si.deinit();

    try testing.expectEqual(@as(usize, 2), si.depends.len);
    try testing.expectEqualStrings("common", si.depends[0].name);
    try testing.expectEqualStrings("only-on-amd64", si.depends[1].name);
}

test "soname provides keep their abi" {
    const text =
        \\pkgbase = curl
        \\  provides = libcurl.so=4-64
        \\
    ;
    var si = try parse(testing.allocator, text, "x86_64");
    defer si.deinit();

    try testing.expect(si.provides[0].is_soname);
    try testing.expectEqualStrings("4-64", si.provides[0].version.?);
}

test "epoch is captured and shapes the version" {
    const text =
        \\pkgbase = libgit2
        \\  epoch = 1
        \\  pkgver = 1.9.6
        \\  pkgrel = 2
        \\
    ;
    var si = try parse(testing.allocator, text, "x86_64");
    defer si.deinit();

    try testing.expectEqualStrings("1", si.epoch.?);
    const v = try si.version(testing.allocator);
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("1:1.9.6-2", v);
}

test "version without epoch" {
    var si = try parse(testing.allocator, hello_srcinfo, "x86_64");
    defer si.deinit();

    const v = try si.version(testing.allocator);
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("2.12.1-1", v);
}

test "split packages inherit and override the base" {
    const text =
        \\pkgbase = demo
        \\  pkgver = 1.0
        \\  pkgrel = 1
        \\  pkgdesc = shared description
        \\  depends = base-dep
        \\
        \\pkgname = demo
        \\
        \\pkgname = demo-docs
        \\  pkgdesc = just the docs
        \\  depends = doc-dep
        \\
    ;
    var si = try parse(testing.allocator, text, "x86_64");
    defer si.deinit();

    try testing.expectEqual(@as(usize, 2), si.packages.len);

    // Declares nothing of its own: inherits both fields from the base.
    try testing.expectEqualStrings("demo", si.packages[0].pkgname);
    try testing.expectEqualStrings("shared description", si.packages[0].pkgdesc);
    try testing.expectEqualStrings("base-dep", si.packages[0].depends[0].name);

    // Overrides both.
    try testing.expectEqualStrings("demo-docs", si.packages[1].pkgname);
    try testing.expectEqualStrings("just the docs", si.packages[1].pkgdesc);
    try testing.expectEqual(@as(usize, 1), si.packages[1].depends.len);
    try testing.expectEqualStrings("doc-dep", si.packages[1].depends[0].name);
}

test "a package is synthesized when no pkgname is declared" {
    const text = "pkgbase = solo\n\tpkgver = 1\n\tpkgrel = 1\n";
    var si = try parse(testing.allocator, text, "x86_64");
    defer si.deinit();

    try testing.expectEqual(@as(usize, 1), si.packages.len);
    try testing.expectEqualStrings("solo", si.packages[0].pkgname);
}

test "options are recorded with negation intact" {
    var si = try parse(testing.allocator, yay_srcinfo, "x86_64");
    defer si.deinit();

    try testing.expectEqual(@as(usize, 1), si.options.len);
    try testing.expectEqualStrings("!lto", si.options[0]);
    try testing.expectEqual(@as(?bool, false), si.option("lto"));
    try testing.expectEqual(@as(?bool, null), si.option("strip"));
}

test "positive options are detected" {
    const text = "pkgbase = x\n\toptions = strip\n\toptions = !docs\n";
    var si = try parse(testing.allocator, text, "x86_64");
    defer si.deinit();

    try testing.expectEqual(@as(?bool, true), si.option("strip"));
    try testing.expectEqual(@as(?bool, false), si.option("docs"));
}

test "install scriptlet and backup files" {
    const text =
        \\pkgbase = svc
        \\  pkgver = 1
        \\  pkgrel = 1
        \\  install = svc.install
        \\  backup = etc/svc.conf
        \\  noextract = blob.bin
        \\
        \\pkgname = svc
        \\
    ;
    var si = try parse(testing.allocator, text, "x86_64");
    defer si.deinit();

    try testing.expectEqualStrings("svc.install", si.packages[0].install.?);
    try testing.expectEqualStrings("etc/svc.conf", si.packages[0].backup[0]);
    try testing.expectEqualStrings("blob.bin", si.noextract[0]);
}
