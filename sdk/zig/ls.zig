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
        zigos.writeAll(2, "usage: ls [PATH]\r\n") catch {};
        return status_usage;
    }
    const path: [*:0]const u8 = if (argc == 2) @ptrFromInt(argv[1]) else ".";
    return listDirectory(path);
}

fn listDirectory(path: [*:0]const u8) u32 {
    const fd = zigos.open(path, .{ .read = true }, 0) catch |err| return printError(err);
    defer zigos.close(fd) catch {};
    var entries: [8]zigos.DirectoryEntry = undefined;
    while (true) {
        const count = zigos.getdents(fd, &entries) catch |err| return printError(err);
        if (count == 0) return status_success;
        for (entries[0..count]) |entry| {
            if (entry.name_length > entry.name.len) return status_failure;
            zigos.writeAll(1, entry.name[0..entry.name_length]) catch return status_failure;
            if (entry.kind == 1) zigos.writeAll(1, "/") catch return status_failure;
            zigos.writeAll(1, "\r\n") catch return status_failure;
        }
    }
}

fn printError(err: zigos.Error) u32 {
    const message = switch (err) {
        error.NotFound => "ls: not found\r\n",
        error.NotDirectory => "ls: not a directory\r\n",
        error.PermissionDenied, error.AccessDenied => "ls: permission denied\r\n",
        error.InputOutput => "ls: input/output error\r\n",
        error.NameTooLong => "ls: name too long\r\n",
        else => "ls: error\r\n",
    };
    zigos.writeAll(2, message) catch {};
    return status_failure;
}
