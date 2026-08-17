const zigos = @import("zigos.zig");

const status_match: u32 = 0;
const status_no_match: u32 = 1;
const status_usage: u32 = 2;
const maximum_pattern_bytes = zigos.constants.maximum_argument_bytes;

pub export fn zigos_main(
    argc: usize,
    argv: [*]const usize,
    _: [*]const usize,
    _: [*]const zigos.AuxvEntry,
) callconv(.c) u32 {
    if (argc != 3) {
        zigos.writeAll(2, "usage: grep PATTERN FILE\r\n") catch {};
        return status_usage;
    }
    const pattern_ptr: [*:0]const u8 = @ptrFromInt(argv[1]);
    const path: [*:0]const u8 = @ptrFromInt(argv[2]);
    const pattern_len = boundedLength(pattern_ptr) orelse {
        zigos.writeAll(2, "grep: pattern too long\r\n") catch {};
        return status_usage;
    };
    const pattern = pattern_ptr[0..pattern_len];

    const fd = zigos.open(path, .{ .read = true }, 0) catch |err| return printError(err);
    defer zigos.close(fd) catch {};

    var prefix: [maximum_pattern_bytes]u8 = @splat(0);
    buildPrefix(pattern, &prefix);
    var bytes: [512]u8 = undefined;
    var position: usize = 0;
    var line_start: usize = 0;
    var matched = pattern.len == 0;
    var match_state: usize = 0;
    var any_match = false;

    while (true) {
        const count = zigos.read(fd, &bytes) catch |err| return printError(err);
        if (count == 0) {
            if (position > line_start and matched) {
                outputRange(fd, line_start, position, &bytes) catch |err| return printError(err);
                any_match = true;
            }
            return if (any_match) status_match else status_no_match;
        }

        var restart = false;
        for (bytes[0..count]) |byte| {
            position += 1;
            if (!matched and pattern.len != 0) {
                while (match_state != 0 and pattern[match_state] != byte) {
                    match_state = prefix[match_state - 1];
                }
                if (pattern[match_state] == byte) match_state += 1;
                if (match_state == pattern.len) matched = true;
            }
            if (byte != '\n') continue;

            const line_end = position;
            if (matched) {
                outputRange(fd, line_start, line_end, &bytes) catch |err| return printError(err);
                any_match = true;
                _ = zigos.lseek(fd, @intCast(line_end), .start) catch |err| return printError(err);
                restart = true;
            }
            line_start = line_end;
            matched = pattern.len == 0;
            match_state = 0;
            if (restart) break;
        }
        if (restart) continue;
    }
}

fn boundedLength(value: [*:0]const u8) ?usize {
    var length: usize = 0;
    while (length <= maximum_pattern_bytes) : (length += 1) {
        if (value[length] == 0) return length;
    }
    return null;
}

fn buildPrefix(pattern: []const u8, prefix: *[maximum_pattern_bytes]u8) void {
    if (pattern.len == 0) return;
    var length: usize = 0;
    var index: usize = 1;
    while (index < pattern.len) {
        if (pattern[index] == pattern[length]) {
            length += 1;
            prefix[index] = @intCast(length);
            index += 1;
        } else if (length != 0) {
            length = prefix[length - 1];
        } else {
            prefix[index] = 0;
            index += 1;
        }
    }
}

fn outputRange(fd: u16, start: usize, end: usize, scratch: *[512]u8) zigos.Error!void {
    _ = try zigos.lseek(fd, @intCast(start), .start);
    var remaining = end - start;
    while (remaining != 0) {
        const limit = @min(remaining, scratch.len);
        const count = try zigos.read(fd, scratch[0..limit]);
        if (count == 0) return error.InputOutput;
        try zigos.writeAll(1, scratch[0..count]);
        remaining -= count;
    }
}

fn printError(err: zigos.Error) u32 {
    const message = switch (err) {
        error.NotFound => "grep: not found\r\n",
        error.IsDirectory => "grep: is a directory\r\n",
        error.NotSeekable => "grep: not seekable\r\n",
        error.PermissionDenied, error.AccessDenied => "grep: permission denied\r\n",
        error.InputOutput => "grep: input/output error\r\n",
        error.NameTooLong => "grep: name too long\r\n",
        else => "grep: error\r\n",
    };
    zigos.writeAll(2, message) catch {};
    return status_usage;
}
