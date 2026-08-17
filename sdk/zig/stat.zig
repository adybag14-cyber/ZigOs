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
        zigos.writeAll(2, "usage: stat PATH\r\n") catch {};
        return status_usage;
    }
    if (argv[1] == 0) return status_failure;
    const path: [*:0]const u8 = @ptrFromInt(argv[1]);
    return printStat(path);
}

fn printStat(path: [*:0]const u8) u32 {
    var info: zigos.Stat = undefined;
    zigos.stat(path, &info) catch |err| return printError(err);
    var owner: zigos.FileOwner = undefined;
    zigos.statOwner(path, &owner) catch |err| return printError(err);
    var times: zigos.FileTimes = undefined;
    zigos.statTimes(path, &times) catch |err| return printError(err);

    zigos.writeAll(1, "type ") catch return status_failure;
    zigos.writeAll(1, kindName(info.kind)) catch return status_failure;
    zigos.writeAll(1, "\r\nmode ") catch return status_failure;
    writeOctalMode(info.mode) catch return status_failure;
    zigos.writeAll(1, "\r\nsize ") catch return status_failure;
    writeDecimal(info.size) catch return status_failure;
    zigos.writeAll(1, "\r\nlinks ") catch return status_failure;
    writeDecimal(info.link_count) catch return status_failure;
    zigos.writeAll(1, "\r\nnode ") catch return status_failure;
    writeDecimal(info.node) catch return status_failure;
    zigos.writeAll(1, " generation ") catch return status_failure;
    writeDecimal(info.generation) catch return status_failure;
    zigos.writeAll(1, " mount ") catch return status_failure;
    writeDecimal(info.mount_id) catch return status_failure;
    zigos.writeAll(1, "\r\nowner ") catch return status_failure;
    writeDecimal(owner.uid) catch return status_failure;
    zigos.writeAll(1, ":") catch return status_failure;
    writeDecimal(owner.gid) catch return status_failure;
    zigos.writeAll(1, "\r\nreadonly ") catch return status_failure;
    zigos.writeAll(1, if (info.readonly != 0) "yes" else "no") catch return status_failure;
    zigos.writeAll(1, "\r\ntimes ") catch return status_failure;
    writeDecimal(times.created_tick) catch return status_failure;
    zigos.writeAll(1, " ") catch return status_failure;
    writeDecimal(times.modified_tick) catch return status_failure;
    zigos.writeAll(1, " ") catch return status_failure;
    writeDecimal(times.changed_tick) catch return status_failure;
    zigos.writeAll(1, " ") catch return status_failure;
    writeDecimal(times.accessed_tick) catch return status_failure;
    zigos.writeAll(1, "\r\n") catch return status_failure;
    return status_success;
}

fn kindName(kind: u8) []const u8 {
    return switch (kind) {
        0 => "file",
        1 => "directory",
        2 => "pseudo",
        3 => "symlink",
        else => "unknown",
    };
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

fn writeOctalMode(value: u16) zigos.Error!void {
    var output: [4]u8 = undefined;
    var remaining = value & 0o7777;
    var index = output.len;
    while (index != 0) {
        index -= 1;
        output[index] = @intCast('0' + (remaining & 7));
        remaining >>= 3;
    }
    try zigos.writeAll(1, &output);
}

fn printError(err: zigos.Error) u32 {
    const message = switch (err) {
        error.NotFound => "stat: not found\r\n",
        error.NotDirectory => "stat: not a directory\r\n",
        error.PermissionDenied, error.AccessDenied => "stat: permission denied\r\n",
        error.NameTooLong => "stat: name too long\r\n",
        error.InputOutput => "stat: input/output error\r\n",
        else => "stat: error\r\n",
    };
    zigos.writeAll(2, message) catch {};
    return status_failure;
}
