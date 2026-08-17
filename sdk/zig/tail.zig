const zigos = @import("zigos.zig");

const status_success: u32 = 0;
const status_failure: u32 = 1;
const status_usage: u32 = 2;
const default_lines: usize = 10;
const retained_boundaries: usize = default_lines + 1;

pub export fn zigos_main(
    argc: usize,
    argv: [*]const usize,
    _: [*]const usize,
    _: [*]const zigos.AuxvEntry,
) callconv(.c) u32 {
    if (argc != 2) {
        zigos.writeAll(2, "usage: tail FILE\r\n") catch {};
        return status_usage;
    }
    const path: [*:0]const u8 = @ptrFromInt(argv[1]);
    const fd = zigos.open(path, .{ .read = true }, 0) catch |err| return printError(err);
    defer zigos.close(fd) catch {};

    var boundaries: [retained_boundaries]usize = @splat(0);
    var newline_count: usize = 0;
    var position: usize = 0;
    var last_was_newline = false;
    var bytes: [512]u8 = undefined;
    while (true) {
        const count = zigos.read(fd, &bytes) catch |err| return printError(err);
        if (count == 0) break;
        for (bytes[0..count]) |byte| {
            position += 1;
            last_was_newline = byte == '\n';
            if (!last_was_newline) continue;
            boundaries[newline_count % retained_boundaries] = position;
            newline_count += 1;
        }
    }
    if (position == 0) return status_success;

    const logical_lines = newline_count + @intFromBool(!last_was_newline);
    var start: usize = 0;
    if (logical_lines > default_lines) {
        const boundary_number = logical_lines - default_lines;
        start = boundaries[(boundary_number - 1) % retained_boundaries];
    }
    _ = zigos.lseek(fd, @intCast(start), .start) catch |err| return printError(err);
    while (true) {
        const count = zigos.read(fd, &bytes) catch |err| return printError(err);
        if (count == 0) return status_success;
        zigos.writeAll(1, bytes[0..count]) catch return status_failure;
    }
}

fn printError(err: zigos.Error) u32 {
    const message = switch (err) {
        error.NotFound => "tail: not found\r\n",
        error.IsDirectory => "tail: is a directory\r\n",
        error.NotSeekable => "tail: not seekable\r\n",
        error.PermissionDenied, error.AccessDenied => "tail: permission denied\r\n",
        error.InputOutput => "tail: input/output error\r\n",
        error.NameTooLong => "tail: name too long\r\n",
        else => "tail: error\r\n",
    };
    zigos.writeAll(2, message) catch {};
    return status_failure;
}
