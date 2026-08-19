const zigos = @import("zigos.zig");

const status_success: u32 = 0;
const status_failure: u32 = 1;
const status_usage: u32 = 2;

pub export fn zigos_main(
    argc: usize,
    _: [*]const usize,
    _: [*]const usize,
    _: [*]const zigos.AuxvEntry,
) callconv(.c) u32 {
    if (argc != 1) {
        zigos.writeAll(2, "usage: uname\r\n") catch {};
        return status_usage;
    }

    const fd = zigos.open("/proc/version", .{ .read = true }, 0) catch |err| return printError(err);
    defer zigos.close(fd) catch {};

    var bytes: [128]u8 = undefined;
    while (true) {
        const count = zigos.read(fd, &bytes) catch |err| return printError(err);
        if (count == 0) return status_success;
        zigos.writeAll(1, bytes[0..count]) catch return status_failure;
    }
}

fn printError(err: zigos.Error) u32 {
    const message = switch (err) {
        error.NotFound => "uname: procfs unavailable\r\n",
        error.PermissionDenied, error.AccessDenied => "uname: permission denied\r\n",
        error.InputOutput => "uname: input/output error\r\n",
        else => "uname: error\r\n",
    };
    zigos.writeAll(2, message) catch {};
    return status_failure;
}
