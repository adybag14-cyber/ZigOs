const zigos = @import("zigos.zig");

const start_message = "zig-sdk: start\r\n";
const argc_fail_message = "zig-sdk: bad argc\r\n";
const argv0_fail_message = "zig-sdk: bad argv0\r\n";
const argv1_fail_message = "zig-sdk: bad argv1\r\n";
const argv2_fail_message = "zig-sdk: bad argv2\r\n";
const argv_message = "zig-sdk: argc/argv passed\r\n";
const abi_message = "zig-sdk: ABI discovery passed\r\n";
const pass_message = "zig-sdk: startup/argv/abi/files/vm/errno passed\r\n";
const fail_message = "zig-sdk: failed\r\n";

pub export fn zigos_main(argc: usize, argv: [*]const usize) callconv(.c) u32 {
    zigos.writeAll(1, start_message) catch return 0xE1;
    if (argc != 3) {
        zigos.writeAll(2, argc_fail_message) catch {};
        return 0xE4;
    }
    if (!zigos.stringEqual(argument(argv, 0), "sdk.elf")) {
        zigos.writeAll(2, argv0_fail_message) catch {};
        return 0xE5;
    }
    if (!zigos.stringEqual(argument(argv, 1), "alpha")) {
        zigos.writeAll(2, argv1_fail_message) catch {};
        return 0xE6;
    }
    if (!zigos.stringEqual(argument(argv, 2), "beta")) {
        zigos.writeAll(2, argv2_fail_message) catch {};
        return 0xE7;
    }
    zigos.writeAll(1, argv_message) catch return 0xE8;
    run() catch {
        zigos.writeAll(2, fail_message) catch {};
        return 0xE2;
    };
    zigos.writeAll(1, pass_message) catch return 0xE3;
    return 0x56;
}

fn argument(argv: [*]const usize, index: usize) [*:0]const u8 {
    return @ptrFromInt(argv[index]);
}

fn run() zigos.Error!void {
    var info: zigos.AbiInfo = undefined;
    try zigos.queryAbi(&info);
    if (info.magic != zigos.constants.abi_magic or info.major != zigos.constants.abi_major or
        info.page_size != zigos.constants.abi_page_size or info.size != @sizeOf(zigos.AbiInfo) or
        (info.capabilities & zigos.constants.capability_vfs) == 0 or
        (info.capabilities & zigos.constants.capability_virtual_memory) == 0 or
        (info.capabilities & zigos.constants.capability_terminal) == 0)
    {
        return error.InvalidArgument;
    }
    try zigos.writeAll(1, abi_message);

    const fd = try zigos.open("/proc/version", .{ .read = true }, 0);
    defer zigos.close(fd) catch {};
    var status: zigos.Stat = undefined;
    try zigos.fstat(fd, &status);
    if (status.kind != 2 or status.readonly != 1) return error.InvalidArgument;

    var bytes: [128]u8 = undefined;
    const count = try zigos.read(fd, &bytes);
    if (count < 5 or !contains(bytes[0..count], "ZigOs")) return error.InvalidArgument;

    const mapping = try zigos.mmap(null, zigos.constants.abi_page_size, .{ .read = true, .write = true }, .{});
    mapping[0] = 0x5A;
    mapping[mapping.len - 1] = 0xA5;
    try zigos.mprotect(mapping, .{ .read = true });
    try zigos.mprotect(mapping, .{ .read = true, .write = true });
    if (mapping[0] != 0x5A or mapping[mapping.len - 1] != 0xA5) return error.InvalidArgument;
    try zigos.munmap(mapping);

    _ = zigos.open("/definitely/missing", .{ .read = true }, 0) catch |err| {
        if (err != error.NotFound) return err;
        return;
    };
    return error.InvalidArgument;
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        var equal = true;
        for (needle, 0..) |byte, offset| {
            if (haystack[index + offset] != byte) {
                equal = false;
                break;
            }
        }
        if (equal) return true;
    }
    return false;
}
