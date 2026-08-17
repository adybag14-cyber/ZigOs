const zigos = @import("zigos.zig");

const status_success: u32 = 0;
const status_failure: u32 = 1;
const status_usage: u32 = 2;
const default_signal: u8 = 9;

pub export fn zigos_main(
    argc: usize,
    argv: [*]const usize,
    _: [*]const usize,
    _: [*]const zigos.AuxvEntry,
) callconv(.c) u32 {
    if (argc < 2 or argc > 3 or argv[1] == 0) return usage();
    const pid_value = parseUnsigned(@ptrFromInt(argv[1])) orelse return usage();
    if (pid_value == 0 or pid_value > 0xffffffff) return usage();
    const pid: u32 = @intCast(pid_value);
    if (pid == 1 or pid == 2) {
        zigos.writeAll(2, "kill: refusing init or active shell\r\n") catch {};
        return status_failure;
    }
    const signal: u8 = if (argc == 3) blk: {
        if (argv[2] == 0) return usage();
        const value = parseUnsigned(@ptrFromInt(argv[2])) orelse return usage();
        if (value == 0 or value >= 64) return usage();
        break :blk @intCast(value);
    } else default_signal;
    zigos.kill(pid, signal) catch |err| return printError(err);
    return status_success;
}

fn parseUnsigned(text: [*:0]const u8) ?u64 {
    var value: u64 = 0;
    var index: usize = 0;
    while (index <= zigos.constants.maximum_argument_bytes) : (index += 1) {
        const byte = text[index];
        if (byte == 0) return if (index == 0) null else value;
        if (byte < '0' or byte > '9') return null;
        const digit: u64 = byte - '0';
        if (value > (0xffffffffffffffff - digit) / 10) return null;
        value = value * 10 + digit;
    }
    return null;
}

fn usage() u32 {
    zigos.writeAll(2, "usage: kill PID [SIGNAL]\r\n") catch {};
    return status_usage;
}

fn printError(err: zigos.Error) u32 {
    const message = switch (err) {
        error.NoProcess => "kill: no such process\r\n",
        error.PermissionDenied, error.AccessDenied => "kill: permission denied\r\n",
        error.InvalidArgument => "kill: invalid signal\r\n",
        else => "kill: error\r\n",
    };
    zigos.writeAll(2, message) catch {};
    return status_failure;
}
