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
        zigos.writeAll(2, "usage: mv SOURCE DEST\r\n") catch {};
        return status_usage;
    }
    if (argv[1] == 0 or argv[2] == 0) return status_failure;
    const source: [*:0]const u8 = @ptrFromInt(argv[1]);
    const destination: [*:0]const u8 = @ptrFromInt(argv[2]);
    zigos.rename(source, destination) catch |err| return printError(err);
    return status_success;
}

fn printError(err: zigos.Error) u32 {
    const message = switch (err) {
        error.NotFound => "mv: not found\r\n",
        error.NotDirectory => "mv: not a directory\r\n",
        error.IsDirectory => "mv: is a directory\r\n",
        error.PermissionDenied, error.AccessDenied => "mv: permission denied\r\n",
        error.ReadOnly => "mv: read-only filesystem\r\n",
        error.NameTooLong => "mv: name too long\r\n",
        error.Busy => "mv: busy\r\n",
        error.NotEmpty => "mv: not empty\r\n",
        error.CrossDevice => "mv: cross-device rename\r\n",
        error.NoSpace => "mv: no space\r\n",
        else => "mv: error\r\n",
    };
    zigos.writeAll(2, message) catch {};
    return status_failure;
}
