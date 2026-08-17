const zigos = @import("zigos.zig");

const status_success: u32 = 0;
const status_failure: u32 = 1;
const status_usage: u32 = 2;
const maximum_ticks: u64 = 100_000;

pub export fn zigos_main(
    argc: usize,
    argv: [*]const usize,
    _: [*]const usize,
    _: [*]const zigos.AuxvEntry,
) callconv(.c) u32 {
    if (argc != 2 or argv[1] == 0) return usage();
    const text: [*:0]const u8 = @ptrFromInt(argv[1]);
    const ticks = parseUnsigned(text) orelse return usage();
    if (ticks == 0 or ticks > maximum_ticks) return usage();
    zigos.sleep(ticks) catch |err| return printError(err);
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
    zigos.writeAll(2, "usage: sleep TICKS\r\n") catch {};
    return status_usage;
}

fn printError(err: zigos.Error) u32 {
    const message = switch (err) {
        error.InvalidArgument => "sleep: invalid duration\r\n",
        else => "sleep: error\r\n",
    };
    zigos.writeAll(2, message) catch {};
    return status_failure;
}
