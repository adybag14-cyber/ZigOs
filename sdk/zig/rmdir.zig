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
        zigos.writeAll(2, "usage: rmdir DIR\r\n") catch {};
        return status_usage;
    }
    if (argv[1] == 0) return status_failure;
    const path: [*:0]const u8 = @ptrFromInt(argv[1]);
    zigos.rmdir(path) catch |err| return printError(err);
    return status_success;
}

fn printError(err: zigos.Error) u32 {
    const message = switch (err) {
        error.NotFound => "rmdir: not found\r\n",
        error.NotDirectory => "rmdir: not a directory\r\n",
        error.NotEmpty => "rmdir: not empty\r\n",
        error.PermissionDenied, error.AccessDenied => "rmdir: permission denied\r\n",
        error.ReadOnly => "rmdir: read-only filesystem\r\n",
        error.NameTooLong => "rmdir: name too long\r\n",
        error.Busy => "rmdir: busy\r\n",
        else => "rmdir: error\r\n",
    };
    zigos.writeAll(2, message) catch {};
    return status_failure;
}
