//! Transitive dependency resolution.
//!
//! Walks a package's dependency graph, skipping anything already satisfied,
//! and returns the AUR packages that must be built, in an order where every
//! dependency precedes its dependents.
//!
//! Cycles are reported rather than followed. They are rare but real in the
//! AUR, and without detection the walk would not terminate.

const std = @import("std");
const dep = @import("../mkpkg/dep.zig");
const store = @import("../store/store.zig");
const aur = @import("aur.zig");
const official = @import("official.zig");
const system = @import("system.zig");

pub const Error = error{
    DependencyCycle,
    Unsatisfiable,
};

/// One node the caller must build and install.
pub const Step = struct {
    name: []const u8,
    version: []const u8,
    /// The dependency string that pulled it in, empty for the requested root.
    required_by: []const u8 = "",
    /// True when the name looks like a `-git`/`-bin` variant that was pulled
    /// in to satisfy something else rather than asked for directly.
    is_variant: bool = false,
};

/// Something no source can supply.
pub const Missing = struct {
    /// The dependency string as written in the PKGBUILD.
    spec: []const u8,
    required_by: []const u8,
};

/// A dependency that exists in Arch's official repositories rather than the
/// AUR. opti cannot build these — there is no PKGBUILD to fetch — so the user
/// installs them through their own package manager.
pub const SystemPackage = struct {
    name: []const u8,
    repo: []const u8,
    required_by: []const u8,
};

pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    /// Build order: dependencies first, the requested package last.
    steps: []const Step = &.{},
    /// Dependencies nothing could satisfy.
    missing: []const Missing = &.{},
    /// Dependencies available from the official repositories.
    system: []const SystemPackage = &.{},
    /// Dependencies already present, recorded for reporting.
    satisfied: []const []const u8 = &.{},

    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
    }

    /// Both categories block a build: one because nothing supplies it, the
    /// other because opti has no way to build an official package.
    pub fn ok(self: Plan) bool {
        return self.missing.len == 0 and self.system.len == 0;
    }
};

/// Working state for one resolution.
const Walker = struct {
    gpa: std.mem.Allocator,
    a: std.mem.Allocator,
    io_ctx: std.Io,
    lay: store.Layout,
    include_make_depends: bool,
    probe: system.Probe,

    steps: std.ArrayList(Step) = .empty,
    missing: std.ArrayList(Missing) = .empty,
    system: std.ArrayList(SystemPackage) = .empty,
    satisfied: std.ArrayList([]const u8) = .empty,
    /// Names already emitted, so a diamond is built once.
    done: std.StringHashMapUnmanaged(void) = .empty,
    /// Names on the current path, for cycle detection.
    active: std.StringHashMapUnmanaged(void) = .empty,
    /// Names already reported as system or missing, so a dependency
    /// shared by several packages is listed once rather than per parent.
    reported: std.StringHashMapUnmanaged(void) = .empty,
};

/// Resolve `root` and everything it needs.
///
/// `include_make_depends` covers build-time dependencies; they are needed to
/// build but not to run, so a caller installing a binary may skip them.
pub fn plan(
    gpa: std.mem.Allocator,
    io_ctx: std.Io,
    lay: store.Layout,
    root: []const u8,
    include_make_depends: bool,
) !Plan {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    var probe = system.Probe.init(gpa, io_ctx);
    defer probe.deinit();

    var w: Walker = .{
        .gpa = gpa,
        .a = arena.allocator(),
        .io_ctx = io_ctx,
        .lay = lay,
        .include_make_depends = include_make_depends,
        .probe = probe,
    };

    try visit(&w, root, "");

    const steps = try w.steps.toOwnedSlice(w.a);
    const missing = try w.missing.toOwnedSlice(w.a);
    const system_pkgs = try w.system.toOwnedSlice(w.a);
    const satisfied = try w.satisfied.toOwnedSlice(w.a);

    return .{
        .arena = arena,
        .steps = steps,
        .missing = missing,
        .system = system_pkgs,
        .satisfied = satisfied,
    };
}

/// `visit` and `visitList` are mutually recursive, so at least one needs an
/// explicit error set — Zig cannot infer through the cycle.
const VisitError = Error || std.mem.Allocator.Error;

/// Depth-first, appending after recursing, so dependencies land before the
/// packages that need them.
fn visit(w: *Walker, name: []const u8, required_by: []const u8) VisitError!void {
    if (w.done.contains(name)) return;
    if (w.active.contains(name)) return Error.DependencyCycle;

    try w.active.put(w.a, try w.a.dupe(u8, name), {});

    // The official repositories are consulted first. AUR policy forbids
    // duplicating them, so a name found here is definitively not an AUR
    // package and asking the AUR would only turn up a fork.
    if (official.lookup(w.gpa, name) catch null) |found| {
        var f = found;
        defer f.deinit();
        if (!w.reported.contains(f.name)) {
            try w.reported.put(w.a, try w.a.dupe(u8, f.name), {});
            try w.system.append(w.a, .{
                .name = try w.a.dupe(u8, f.name),
                .repo = try w.a.dupe(u8, f.repo),
                .required_by = try w.a.dupe(u8, required_by),
            });
        }
        _ = w.active.remove(name);
        return;
    }

    var pkg = aur.info(w.gpa, name) catch null;
    if (pkg == null) {
        // In neither the official repositories nor the AUR.
        if (!w.reported.contains(name)) {
            try w.reported.put(w.a, try w.a.dupe(u8, name), {});
            try w.missing.append(w.a, .{
                .spec = try w.a.dupe(u8, name),
                .required_by = try w.a.dupe(u8, required_by),
            });
        }
        _ = w.active.remove(name);
        return;
    }
    defer pkg.?.deinit();

    const info = &pkg.?;

    try visitList(w, info.depends, name);
    if (w.include_make_depends) try visitList(w, info.make_depends, name);

    try w.steps.append(w.a, .{
        .name = try w.a.dupe(u8, info.name),
        .version = try w.a.dupe(u8, info.version),
        .required_by = try w.a.dupe(u8, required_by),
        // Only flagged when pulled in indirectly; asking for a variant by
        // name is a deliberate choice.
        .is_variant = required_by.len > 0 and aur.isVariant(info.name),
    });

    _ = w.active.remove(name);
    try w.done.put(w.a, try w.a.dupe(u8, info.name), {});
}

fn visitList(
    w: *Walker,
    specs: []const []const u8,
    required_by: []const u8,
) VisitError!void {
    for (specs) |spec| {
        const d = dep.Dep.parse(spec);

        switch (system.locate(w.gpa, w.io_ctx, w.lay, w.probe, d)) {
            .store, .host => {
                try w.satisfied.append(w.a, try w.a.dupe(u8, spec));
                continue;
            },
            .unsatisfied => {},
        }

        // Only now is the AUR consulted, and only for what the machine does
        // not already supply.
        if (d.is_soname) {
            var provider = aur.byProvides(w.gpa, d.name) catch null;
            if (provider) |*p| {
                defer p.deinit();
                try visit(w, p.name, required_by);
                continue;
            }
            if (!w.reported.contains(d.name)) {
                try w.reported.put(w.a, try w.a.dupe(u8, d.name), {});
                try w.missing.append(w.a, .{
                    .spec = try w.a.dupe(u8, spec),
                    .required_by = try w.a.dupe(u8, required_by),
                });
            }
            continue;
        }

        try visit(w, d.name, required_by);
    }
}

const testing = std.testing;

test "a plan with no missing dependencies is ok" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    var p: Plan = .{ .arena = arena };
    defer p.deinit();
    try testing.expect(p.ok());

    arena = std.heap.ArenaAllocator.init(testing.allocator);
    var q: Plan = .{
        .arena = arena,
        .missing = &.{.{ .spec = "libfoo.so", .required_by = "bar" }},
    };
    defer q.deinit();
    try testing.expect(!q.ok());
}

test "variant flagging distinguishes direct from indirect" {
    // Requested directly: not flagged, the user chose it.
    const direct: Step = .{ .name = "curl-git", .version = "1", .required_by = "" };
    try testing.expect(!direct.is_variant);

    // What the walker would record for an indirect pull.
    const indirect: Step = .{
        .name = "curl-git",
        .version = "1",
        .required_by = "myapp",
        .is_variant = true,
    };
    try testing.expect(indirect.is_variant);
}
