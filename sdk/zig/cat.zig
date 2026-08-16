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
        zigos.writeAll(2, "usage: cat FILE\r\n") catch {};
        return status_usage;
    }
    const path: [*:0]const u8 = @ptrFromInt(argv[1]);
    return streamFile(path);
}

fn streamFile(path: [*:0]const u8) u32 {
    const fd = zigos.open(path, .{ .read = true }, 0) catch |err| return printError(err);
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
        error.NotFound => "cat: not found\r\n",
        error.IsDirectory => "cat: is a directory\r\n",
        error.PermissionDenied, error.AccessDenied => "cat: permission denied\r\n",
        error.InputOutput => "cat: input/output error\r\n",
        error.NameTooLong => "cat: name too long\r\n",
        else => "cat: error\r\n",
    };
    zigos.writeAll(2, message) catch {};
    return status_failure;
}
