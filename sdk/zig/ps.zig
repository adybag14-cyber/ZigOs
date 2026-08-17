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
        zigos.writeAll(2, "usage: ps\r\n") catch {};
        return status_usage;
    }
    const fd = zigos.open("/proc/processes", .{ .read = true }, 0) catch |err| return printError(err);
    defer zigos.close(fd) catch {};

    var bytes: [512]u8 = undefined;
    while (true) {
        const count = zigos.read(fd, &bytes) catch |err| return printError(err);
        if (count == 0) return status_success;
        zigos.writeAll(1, bytes[0..count]) catch return status_failure;
    }
}

fn printError(err: zigos.Error) u32 {
    const message = switch (err) {
        error.NotFound => "ps: procfs unavailable\r\n",
        error.PermissionDenied, error.AccessDenied => "ps: permission denied\r\n",
        error.InputOutput => "ps: input/output error\r\n",
        else => "ps: error\r\n",
    };
    zigos.writeAll(2, message) catch {};
    return status_failure;
}
