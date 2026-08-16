const zigos = @import("zigos.zig");

const status_success: u32 = 0;
const status_failure: u32 = 1;

pub export fn zigos_main(
    argc: usize,
    argv: [*]const usize,
    _: [*]const usize,
    _: [*]const zigos.AuxvEntry,
) callconv(.c) u32 {
    if (argc == 0 or argc > zigos.constants.maximum_arguments) return status_failure;

    var index: usize = 1;
    while (index < argc) : (index += 1) {
        const argument = argumentSlice(argv[index]) orelse return status_failure;
        if (index != 1) zigos.writeAll(1, " ") catch return status_failure;
        zigos.writeAll(1, argument) catch return status_failure;
    }
    zigos.writeAll(1, "\r\n") catch return status_failure;
    return status_success;
}

fn argumentSlice(pointer: usize) ?[]const u8 {
    if (pointer == 0) return null;
    const bytes: [*:0]const u8 = @ptrFromInt(pointer);
    var length: usize = 0;
    while (length <= zigos.constants.maximum_argument_bytes) : (length += 1) {
        if (bytes[length] == 0) return bytes[0..length];
    }
    return null;
}
