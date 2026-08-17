const zigos = @import("zigos.zig");

const status_success: u32 = 0;
const status_failure: u32 = 1;
const status_usage: u32 = 2;
const maximum_output_bytes: usize = 256;
const row_bytes: usize = 16;
const hex_digits = "0123456789ABCDEF";

pub export fn zigos_main(
    argc: usize,
    argv: [*]const usize,
    _: [*]const usize,
    _: [*]const zigos.AuxvEntry,
) callconv(.c) u32 {
    if (argc != 2) {
        zigos.writeAll(2, "usage: hexdump FILE\r\n") catch {};
        return status_usage;
    }
    const path: [*:0]const u8 = @ptrFromInt(argv[1]);
    const fd = zigos.open(path, .{ .read = true }, 0) catch |err| return printError(err);
    defer zigos.close(fd) catch {};

    var offset: usize = 0;
    var row: [row_bytes]u8 = undefined;
    while (offset < maximum_output_bytes) {
        const remaining = maximum_output_bytes - offset;
        const count = zigos.read(fd, row[0..@min(row.len, remaining)]) catch |err| return printError(err);
        if (count == 0) return status_success;
        writeRow(offset, row[0..count]) catch return status_failure;
        offset += count;
        if (count < row.len) return status_success;
    }
    return status_success;
}

fn writeRow(offset: usize, row: []const u8) zigos.Error!void {
    try writeHexFixed(offset, 4);
    try zigos.writeAll(1, "  ");
    for (0..row_bytes) |column| {
        if (column < row.len) {
            try writeHexFixed(row[column], 2);
        } else {
            try zigos.writeAll(1, "  ");
        }
        try zigos.writeAll(1, " ");
    }
    try zigos.writeAll(1, " ");
    for (row) |byte| {
        const visible = if (byte >= 0x20 and byte <= 0x7e) byte else '.';
        try zigos.writeAll(1, &[_]u8{visible});
    }
    try zigos.writeAll(1, "\r\n");
}

fn writeHexFixed(value: u64, digits: usize) zigos.Error!void {
    var output: [4]u8 = undefined;
    var position = digits;
    while (position != 0) {
        position -= 1;
        const shift: u6 = @intCast(position * 4);
        output[digits - position - 1] = hex_digits[@as(u4, @truncate(value >> shift))];
    }
    try zigos.writeAll(1, output[0..digits]);
}

fn printError(err: zigos.Error) u32 {
    const message = switch (err) {
        error.NotFound => "hexdump: not found\r\n",
        error.IsDirectory => "hexdump: is a directory\r\n",
        error.PermissionDenied, error.AccessDenied => "hexdump: permission denied\r\n",
        error.InputOutput => "hexdump: input/output error\r\n",
        error.NameTooLong => "hexdump: name too long\r\n",
        else => "hexdump: error\r\n",
    };
    zigos.writeAll(2, message) catch {};
    return status_failure;
}
