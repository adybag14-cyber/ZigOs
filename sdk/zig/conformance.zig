const zigos = @import("zigos.zig");

const start_message = "zig-sdk: start\r\n";
const argc_fail_message = "zig-sdk: bad argc\r\n";
const argv0_fail_message = "zig-sdk: bad argv0\r\n";
const argv1_fail_message = "zig-sdk: bad argv1\r\n";
const argv2_fail_message = "zig-sdk: bad argv2\r\n";
const argv_message = "zig-sdk: argc/argv passed\r\n";
const abi_message = "zig-sdk: ABI discovery passed\r\n";
const startup_vector_message = "zig-sdk: envp/auxv passed\r\n";
const pass_message = "zig-sdk: startup/argv/abi/files/vm/errno/fsync/fdatasync/readv/writev passed\r\n";
const fail_message = "zig-sdk: failed\r\n";

pub export fn zigos_main(argc: usize, argv: [*]const usize, envp: [*]const usize, auxv: [*]const zigos.AuxvEntry) callconv(.c) u32 {
    zigos.writeAll(1, start_message) catch return 0xE1;
    if (argc != 3) {
        zigos.writeAll(2, argc_fail_message) catch {};
        return 0xE4;
    }
    if (!validExecutableName(argument(argv, 0))) {
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
    if (!startupVectorsValid(envp, auxv)) {
        zigos.writeAll(2, "zig-sdk: bad envp/auxv\r\n") catch {};
        return 0xE9;
    }
    zigos.writeAll(1, startup_vector_message) catch return 0xEA;
    run() catch {
        zigos.writeAll(2, fail_message) catch {};
        return 0xE2;
    };
    zigos.writeAll(1, pass_message) catch return 0xE3;
    return 0x56;
}

fn validExecutableName(value: [*:0]const u8) bool {
    var length: usize = 0;
    while (length < 64 and value[length] != 0) : (length += 1) {
        if (value[length] == '/') return false;
    }
    if (length < 5 or length == 64) return false;
    return value[length - 4] == '.' and value[length - 3] == 'e' and
        value[length - 2] == 'l' and value[length - 1] == 'f';
}

fn argument(argv: [*]const usize, index: usize) [*:0]const u8 {
    return @ptrFromInt(argv[index]);
}

fn startupVectorsValid(envp: [*]const usize, auxv: [*]const zigos.AuxvEntry) bool {
    const path = zigos.environmentValue(envp, "PATH") orelse return false;
    const home = zigos.environmentValue(envp, "HOME") orelse return false;
    const term = zigos.environmentValue(envp, "TERM") orelse return false;
    if (!equal(path, "/bin:/persist") or !equal(home, "/home/root") or !equal(term, "zigos")) return false;
    if (zigos.auxiliaryValue(auxv, zigos.constants.aux_pagesz) != zigos.constants.abi_page_size) return false;
    const version = zigos.auxiliaryValue(auxv, zigos.constants.aux_zigos_abi) orelse return false;
    if (version != (@as(u64, zigos.constants.abi_major) << 32) | zigos.constants.abi_minor) return false;
    const capabilities = zigos.auxiliaryValue(auxv, zigos.constants.aux_zigos_capabilities) orelse return false;
    return (capabilities & zigos.constants.capability_process) != 0 and
        (capabilities & zigos.constants.capability_vfs) != 0 and
        (capabilities & zigos.constants.capability_terminal) != 0;
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

    const vector_path = "/tmp/zig-sdk-vectors";
    zigos.unlink(vector_path) catch {};
    const vector_fd = try zigos.open(vector_path, .{ .read = true, .write = true, .create = true, .truncate = true }, 0o600);
    const write_vectors = [_]zigos.IoVector{
        zigos.constVector("vec"),
        zigos.constVector(""),
        zigos.constVector("tor"),
        zigos.constVector("-io"),
    };
    const invalid_write_vectors = [_]zigos.IoVector{
        zigos.constVector("bad"),
        .{ .pointer = 0, .length = 1 },
    };
    if (zigos.writev(vector_fd, &invalid_write_vectors)) |_| return error.InvalidArgument else |err| {
        if (err != error.Fault) return err;
    }
    var vector_status: zigos.Stat = undefined;
    try zigos.fstat(vector_fd, &vector_status);
    if (vector_status.size != 0 or try zigos.writev(vector_fd, &.{}) != 0 or try zigos.writev(vector_fd, &write_vectors) != 9) return error.InvalidArgument;
    if (try zigos.lseek(vector_fd, 0, .start) != 0) return error.InvalidArgument;
    var first: [2]u8 = undefined;
    var second: [3]u8 = undefined;
    var third: [4]u8 = undefined;
    const read_vectors = [_]zigos.IoVector{
        zigos.mutableVector(&first),
        zigos.mutableVector(&second),
        zigos.mutableVector(&third),
    };
    const invalid_read_vectors = [_]zigos.IoVector{
        zigos.mutableVector(&first),
        .{ .pointer = 0, .length = 1 },
    };
    if (zigos.readv(vector_fd, &invalid_read_vectors)) |_| return error.InvalidArgument else |err| {
        if (err != error.Fault) return err;
    }
    if (try zigos.readv(vector_fd, &read_vectors) != 9 or
        !equal(&first, "ve") or !equal(&second, "cto") or !equal(&third, "r-io")) return error.InvalidArgument;
    var too_many: [zigos.constants.maximum_iovecs + 1]zigos.IoVector = @splat(.{ .pointer = 0, .length = 0 });
    if (zigos.writev(vector_fd, &too_many)) |_| return error.InvalidArgument else |err| {
        if (err != error.InvalidArgument) return err;
    }
    const oversized = [_]zigos.IoVector{.{ .pointer = 0, .length = info.maximum_io_bytes + 1 }};
    if (zigos.writev(vector_fd, &oversized)) |_| return error.InvalidArgument else |err| {
        if (err != error.TooBig) return err;
    }
    try zigos.fsync(vector_fd);
    try zigos.fdatasync(vector_fd);
    try zigos.close(vector_fd);
    try zigos.unlink(vector_path);

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
        var matches = true;
        for (needle, 0..) |byte, offset| {
            if (haystack[index + offset] != byte) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

fn equal(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}
