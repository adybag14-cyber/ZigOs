const zigos = @import("zigos.zig");

const status_success: u32 = 0;
const status_failure: u32 = 1;
const status_usage: u32 = 2;

pub export fn zigos_main(
    argc: usize,
    _: [*]const usize,
    _: [*]const usize,
    _: [*]const zigos.AuxvEntry,
) callconv(.c) u32 {
    if (argc != 1) {
        zigos.writeAll(2, "usage: fsck\r\n") catch {};
        return status_usage;
    }

    const clean = zigos.fscheck() catch |err| {
        const message = switch (err) {
            error.InputOutput => "fsck: input/output error\r\n",
            error.Unsupported => "fsck: unavailable\r\n",
            else => "fsck: error\r\n",
        };
        zigos.writeAll(2, message) catch {};
        return status_failure;
    };
    if (!clean) {
        zigos.writeAll(2, "fsck: corrupt\r\n") catch {};
        return status_failure;
    }
    zigos.writeAll(1, "fsck: clean\r\n") catch return status_failure;
    return status_success;
}
