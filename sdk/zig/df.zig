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
    if (argc > 2) {
        zigos.writeAll(2, "usage: df [PATH]\r\n") catch {};
        return status_usage;
    }
    const path: [*:0]const u8 = if (argc == 2) @ptrFromInt(argv[1]) else "/";
    return printFilesystem(path);
}

fn printFilesystem(path: [*:0]const u8) u32 {
    var info: zigos.FilesystemStat = undefined;
    zigos.statfs(path, &info) catch |err| return printError(err);

    zigos.writeAll(1, "type ") catch return status_failure;
    zigos.writeAll(1, filesystemName(info.filesystem_kind)) catch return status_failure;
    zigos.writeAll(1, "\r\nblock-size ") catch return status_failure;
    writeDecimal(info.block_size) catch return status_failure;
    zigos.writeAll(1, "\r\nblocks ") catch return status_failure;
    writeDecimal(info.total_blocks) catch return status_failure;
    zigos.writeAll(1, "\r\nfree ") catch return status_failure;
    writeDecimal(info.free_blocks) catch return status_failure;
    zigos.writeAll(1, "\r\navailable ") catch return status_failure;
    writeDecimal(info.available_blocks) catch return status_failure;
    zigos.writeAll(1, "\r\nnodes ") catch return status_failure;
    writeDecimal(info.total_nodes) catch return status_failure;
    zigos.writeAll(1, "\r\nfree-nodes ") catch return status_failure;
    writeDecimal(info.free_nodes) catch return status_failure;
    zigos.writeAll(1, "\r\nmount ") catch return status_failure;
    writeDecimal(info.mount_id) catch return status_failure;
    zigos.writeAll(1, "\r\nflags ") catch return status_failure;
    zigos.writeAll(1, if ((info.flags & zigos.constants.filesystem_stat_read_only) != 0) "ro" else "rw") catch return status_failure;
    if ((info.flags & zigos.constants.filesystem_stat_shared_blocks) != 0) {
        zigos.writeAll(1, " shared-blocks") catch return status_failure;
    }
    if ((info.flags & zigos.constants.filesystem_stat_shared_nodes) != 0) {
        zigos.writeAll(1, " shared-nodes") catch return status_failure;
    }
    if ((info.flags & zigos.constants.filesystem_stat_synthetic) != 0) {
        zigos.writeAll(1, " synthetic") catch return status_failure;
    }
    zigos.writeAll(1, "\r\n") catch return status_failure;
    return status_success;
}

fn filesystemName(kind: u16) []const u8 {
    return switch (kind) {
        zigos.constants.filesystem_type_ramfs => "ramfs",
        zigos.constants.filesystem_type_tmpfs => "tmpfs",
        zigos.constants.filesystem_type_boot_fat => "boot_fat",
        zigos.constants.filesystem_type_procfs => "procfs",
        zigos.constants.filesystem_type_devfs => "devfs",
        zigos.constants.filesystem_type_netfs => "netfs",
        zigos.constants.filesystem_type_zigos_persist => "zigos_persist",
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

fn printError(err: zigos.Error) u32 {
    const message = switch (err) {
        error.NotFound => "df: not found\r\n",
        error.NotDirectory => "df: not a directory\r\n",
        error.PermissionDenied, error.AccessDenied => "df: permission denied\r\n",
        error.NameTooLong => "df: name too long\r\n",
        error.InputOutput => "df: input/output error\r\n",
        else => "df: error\r\n",
    };
    zigos.writeAll(2, message) catch {};
    return status_failure;
}
