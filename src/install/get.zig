//! Safe Zig wrapper around libgit2's clone.

const std = @import("std");
const c = @import("c");

pub const Error = error{ GitInit, GitClone };

/// Clone `url` into `dir`. Both must be null-terminated: libgit2 takes C
/// strings, so a plain `[]const u8` would hand it an unterminated pointer.
pub fn cloneToDir(url: [:0]const u8, dir: [:0]const u8, err_out: *std.Io.Writer) Error!void {
    if (c.git_libgit2_init() < 0) return error.GitInit;
    defer _ = c.git_libgit2_shutdown();

    var opts: c.git_clone_options = undefined;
    if (c.git_clone_options_init(&opts, c.GIT_CLONE_OPTIONS_VERSION) < 0) {
        return error.GitInit;
    }

    var repo: ?*c.git_repository = null;
    if (c.git_clone(&repo, url.ptr, dir.ptr, &opts) < 0) {
        reportLastError(err_out);
        return error.GitClone;
    }
    // Nothing downstream needs the handle yet; the working tree is on disk.
    c.git_repository_free(repo);
}

/// `git_error_last` returns a borrowed pointer that may be null, and its
/// `message` is a C string rather than a slice.
fn reportLastError(err_out: *std.Io.Writer) void {
    const last = c.git_error_last();
    if (last == null) {
        err_out.print("[opti.install] git clone failed (no detail available)\n", .{}) catch {};
        return;
    }
    const msg = if (last.*.message != null)
        std.mem.span(last.*.message)
    else
        "unknown error";
    err_out.print(
        "[opti.install] git clone failed: {s} (class {d})\n",
        .{ msg, last.*.klass },
    ) catch {};
}
