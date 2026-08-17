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
        zigos.writeAll(2, "usage: wc FILE\r\n") catch {};
        return status_usage;
    }
    const path: [*:0]const u8 = @ptrFromInt(argv[1]);
    const fd = zigos.open(path, .{ .read = true }, 0) catch |err| return printError(err);
    defer zigos.close(fd) catch {};

    var bytes: [512]u8 = undefined;
    var byte_count: u64 = 0;
    var line_count: u64 = 0;
    var word_count: u64 = 0;
    var in_word = false;
    while (true) {
        const count = zigos.read(fd, &bytes) catch |err| return printError(err);
        if (count == 0) break;
        byte_count += count;
        for (bytes[0..count]) |byte| {
            if (byte == '\n') line_count += 1;
            const space = isSpace(byte);
            if (!space and !in_word) word_count += 1;
            in_word = !space;
        }
    }
    writeDecimal(line_count) catch return status_failure;
    zigos.writeAll(1, " ") catch return status_failure;
    writeDecimal(word_count) catch return status_failure;
    zigos.writeAll(1, " ") catch return status_failure;
    writeDecimal(byte_count) catch return status_failure;
    zigos.writeAll(1, "\r\n") catch return status_failure;
    return status_success;
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r' or byte == 0x0b or byte == 0x0c;
}

fn writeDecimal(value: u64) zigos.Error!void {
    var output: [20]u8 = undefined;
    var remaining = value;
    var start = output.len;
    while (true) {
        start -= 1;
        output[start] = @intCast('0' + remaining % 10);
        remaining /= 10;
        if (remaining == 0) break;
    }
    try zigos.writeAll(1, output[start..]);
}

fn printError(err: zigos.Error) u32 {
    const message = switch (err) {
        error.NotFound => "wc: not found\r\n",
        error.IsDirectory => "wc: is a directory\r\n",
        error.PermissionDenied, error.AccessDenied => "wc: permission denied\r\n",
        error.InputOutput => "wc: input/output error\r\n",
        error.NameTooLong => "wc: name too long\r\n",
        else => "wc: error\r\n",
    };
    zigos.writeAll(2, message) catch {};
    return status_failure;
}
