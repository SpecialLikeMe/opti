//! Source downloading over HTTP(S)/FTP via libcurl.
//!
//! Uses libcurl directly rather than shelling out to the `curl` binary, so a
//! source fetch has no host tool dependency beyond the library opti already
//! links against.

const std = @import("std");
const c = @import("c");

pub const Error = error{
    CurlInit,
    TransferFailed,
    OutOfMemory,
};

/// Accumulates the response body. `oom` is latched because the libcurl write
/// callback has no way to propagate a Zig error out through the C boundary.
const Sink = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    oom: bool = false,
};

fn writeCallback(
    ptr: [*c]u8,
    size: usize,
    nmemb: usize,
    userdata: ?*anyopaque,
) callconv(.c) usize {
    const total = size * nmemb;
    const sink: *Sink = @ptrCast(@alignCast(userdata orelse return 0));
    if (sink.oom) return 0;

    sink.buf.appendSlice(sink.gpa, ptr[0..total]) catch {
        sink.oom = true;
        // Returning a short count tells libcurl to abort the transfer.
        return 0;
    };
    return total;
}

/// Download `url` into memory. Caller owns the returned bytes.
pub fn get(gpa: std.mem.Allocator, url: [:0]const u8) Error![]u8 {
    const handle = c.curl_easy_init() orelse return Error.CurlInit;
    defer c.curl_easy_cleanup(handle);

    var sink: Sink = .{ .gpa = gpa };
    errdefer sink.buf.deinit(gpa);

    _ = c.curl_easy_setopt(handle, c.CURLOPT_URL, url.ptr);
    _ = c.curl_easy_setopt(handle, c.CURLOPT_WRITEFUNCTION, &writeCallback);
    _ = c.curl_easy_setopt(handle, c.CURLOPT_WRITEDATA, &sink);
    // Sources routinely redirect (GitHub release URLs in particular).
    _ = c.curl_easy_setopt(handle, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    // Treat HTTP >=400 as a transfer failure instead of saving an error page.
    _ = c.curl_easy_setopt(handle, c.CURLOPT_FAILONERROR, @as(c_long, 1));
    _ = c.curl_easy_setopt(handle, c.CURLOPT_USERAGENT, "opti/0.0.0");
    _ = c.curl_easy_setopt(handle, c.CURLOPT_NOPROGRESS, @as(c_long, 1));

    const code = c.curl_easy_perform(handle);
    if (sink.oom) return Error.OutOfMemory;
    if (code != c.CURLE_OK) return Error.TransferFailed;

    return sink.buf.toOwnedSlice(gpa);
}

/// Human-readable description of the last libcurl failure code.
pub fn errorString(code: c_uint) []const u8 {
    const msg = c.curl_easy_strerror(code);
    if (msg == null) return "unknown libcurl error";
    return std.mem.span(msg);
}
