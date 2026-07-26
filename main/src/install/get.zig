const std = @import("std");

/// Clones a URL to a directory by passing the entire C namespace into the function.
/// 'curl' is anytype, allowing you to pass the result of any @cImport block.
pub fn cloneToDir(curl: anytype, url: []const u8, dir: []const u8) !void {
    // 1. Initialize the easy transfer handle using the passed namespace parameter
    const handle = curl.curl_easy_init() orelse return error.CurlInitFailed;
    defer curl.curl_easy_cleanup(handle);

    // 2. Ensure target directory exists and open it contextually
    var target_dir = try std.fs.cwd().makeOpenPath(dir, .{});
    defer target_dir.close();

    // 3. Extract the file name from the trailing edge of the URL string
    var it = std.mem.splitBackwardsScalar(u8, url, '/');
    const filename = it.first();
    if (filename.len == 0) return error.InvalidUrlFilename;

    // 4. Create the output file natively within that directory
    var file = try target_dir.createFile(filename, .{});
    defer file.close();

    // 5. Declare a static, non-capturing C-ABI compliant callback
    const closures = struct {
        fn writeCallback(data: [*]u8, size: usize, nmemb: usize, userp: *anyopaque) callconv(.C) usize {
            const total_size = size * nmemb;
            const f: *std.fs.File = @ptrCast(@alignCast(userp));
            f.writeAll(data[0..total_size]) catch return 0;
            return total_size;
        }
    };

    // 6. Configure options on your handle using the passed namespace's constants
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_URL, url.ptr);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEFUNCTION, closures.writeCallback);
    _ = curl.curl_easy_setopt(handle, curl.CURLOPT_WRITEDATA, &file);

    // 7. Execute the synchronized download transfer
    const res = curl.curl_easy_perform(handle);

    // 8. Evaluate execution errors and prune broken artifacts on failure
    if (res != curl.CURLE_OK) {
        target_dir.deleteFile(filename) catch {};
        return error.CurlTransferFailed;
    }
}