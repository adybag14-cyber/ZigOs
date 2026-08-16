const zigos = @import("zigos.zig");

const maximum_path: usize = 255;
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
        zigos.writeAll(2, "usage: pwd\r\n") catch {};
        return status_usage;
    }

    var path: [maximum_path + 1]u8 = undefined;
    const cwd = zigos.getcwd(&path) catch {
        zigos.writeAll(2, "pwd: error\r\n") catch {};
        return status_failure;
    };
    zigos.writeAll(1, cwd) catch return status_failure;
    zigos.writeAll(1, "\r\n") catch return status_failure;
    return status_success;
}
