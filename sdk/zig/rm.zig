const zigos = @import("zigos.zig");

const status_success: u32 = 0;
const status_failure: u32 = 1;
const status_usage: u32 = 2;

pub export fn zigos_main(
    argc: usize,
    argv: [*]const usize,
    _: [*]const usize,
    _: [*]const zigos.AuxvEntry,
) callconv(.c) u32 {
    if (argc != 2) {
        zigos.writeAll(2, "usage: rm FILE\r\n") catch {};
        return status_usage;
    }
    if (argv[1] == 0) return status_failure;
    const path: [*:0]const u8 = @ptrFromInt(argv[1]);
    zigos.unlink(path) catch |err| return printError(err);
    return status_success;
}

fn printError(err: zigos.Error) u32 {
    const message = switch (err) {
        error.NotFound => "rm: not found\r\n",
        error.IsDirectory => "rm: is a directory\r\n",
        error.NotDirectory => "rm: not a directory\r\n",
        error.PermissionDenied, error.AccessDenied => "rm: permission denied\r\n",
        error.ReadOnly => "rm: read-only filesystem\r\n",
        error.NameTooLong => "rm: name too long\r\n",
        error.Busy => "rm: busy\r\n",
        else => "rm: error\r\n",
    };
    zigos.writeAll(2, message) catch {};
    return status_failure;
}
