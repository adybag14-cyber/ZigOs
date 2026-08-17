const zigos = @import("zigos.zig");

const status_success: u32 = 0;
const status_failure: u32 = 1;
const status_usage: u32 = 2;
const default_lines: usize = 10;

pub export fn zigos_main(
    argc: usize,
    argv: [*]const usize,
    _: [*]const usize,
    _: [*]const zigos.AuxvEntry,
) callconv(.c) u32 {
    if (argc != 2) {
        zigos.writeAll(2, "usage: head FILE\r\n") catch {};
        return status_usage;
    }
    const path: [*:0]const u8 = @ptrFromInt(argv[1]);
    const fd = zigos.open(path, .{ .read = true }, 0) catch |err| return printError(err);
    defer zigos.close(fd) catch {};

    var bytes: [512]u8 = undefined;
    var lines: usize = 0;
    while (true) {
        const count = zigos.read(fd, &bytes) catch |err| return printError(err);
        if (count == 0) return status_success;
        var end = count;
        for (bytes[0..count], 0..) |byte, index| {
            if (byte != '\n') continue;
            lines += 1;
            if (lines == default_lines) {
                end = index + 1;
                zigos.writeAll(1, bytes[0..end]) catch return status_failure;
                return status_success;
            }
        }
        zigos.writeAll(1, bytes[0..end]) catch return status_failure;
    }
}

fn printError(err: zigos.Error) u32 {
    const message = switch (err) {
        error.NotFound => "head: not found\r\n",
        error.IsDirectory => "head: is a directory\r\n",
        error.PermissionDenied, error.AccessDenied => "head: permission denied\r\n",
        error.InputOutput => "head: input/output error\r\n",
        error.NameTooLong => "head: name too long\r\n",
        else => "head: error\r\n",
    };
    zigos.writeAll(2, message) catch {};
    return status_failure;
}
