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
    if (argc != 3) {
        zigos.writeAll(2, "usage: cp SOURCE DEST\r\n") catch {};
        return status_usage;
    }
    if (argv[1] == 0 or argv[2] == 0) return status_failure;
    const source: [*:0]const u8 = @ptrFromInt(argv[1]);
    const destination: [*:0]const u8 = @ptrFromInt(argv[2]);
    return copyFile(source, destination);
}

fn copyFile(source: [*:0]const u8, destination: [*:0]const u8) u32 {
    const source_fd = zigos.open(source, .{ .read = true }, 0) catch |err| return printError(err);
    defer zigos.close(source_fd) catch {};

    var source_info: zigos.Stat = undefined;
    zigos.fstat(source_fd, &source_info) catch |err| return printError(err);
    if (source_info.kind == 1) return printError(error.IsDirectory);

    var destination_info: zigos.Stat = undefined;
    if (zigos.stat(destination, &destination_info)) |_| {
        if (destination_info.kind == 1) return printError(error.IsDirectory);
        if (destination_info.mount_id == source_info.mount_id and
            destination_info.node == source_info.node and
            destination_info.generation == source_info.generation)
        {
            zigos.writeAll(2, "cp: same file\r\n") catch {};
            return status_failure;
        }
    } else |err| switch (err) {
        error.NotFound => {},
        else => return printError(err),
    }

    const destination_fd = zigos.open(
        destination,
        .{ .write = true, .create = true, .truncate = true },
        source_info.mode | 0o200,
    ) catch |err| return printError(err);
    defer zigos.close(destination_fd) catch {};

    var bytes: [512]u8 = undefined;
    while (true) {
        const count = zigos.read(source_fd, &bytes) catch |err| return printError(err);
        if (count == 0) return status_success;
        zigos.writeAll(destination_fd, bytes[0..count]) catch |err| return printError(err);
    }
}

fn printError(err: zigos.Error) u32 {
    const message = switch (err) {
        error.NotFound => "cp: not found\r\n",
        error.IsDirectory => "cp: is a directory\r\n",
        error.NotDirectory => "cp: not a directory\r\n",
        error.PermissionDenied, error.AccessDenied => "cp: permission denied\r\n",
        error.ReadOnly => "cp: read-only filesystem\r\n",
        error.NameTooLong => "cp: name too long\r\n",
        error.NoSpace => "cp: no space\r\n",
        error.InputOutput => "cp: input/output error\r\n",
        error.Busy => "cp: busy\r\n",
        else => "cp: error\r\n",
    };
    zigos.writeAll(2, message) catch {};
    return status_failure;
}
