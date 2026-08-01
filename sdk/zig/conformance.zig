const zigos = @import("zigos.zig");

const start_message = "zig-sdk: start\r\n";
const argc_fail_message = "zig-sdk: bad argc\r\n";
const argv0_fail_message = "zig-sdk: bad argv0\r\n";
const argv1_fail_message = "zig-sdk: bad argv1\r\n";
const argv2_fail_message = "zig-sdk: bad argv2\r\n";
const argv_message = "zig-sdk: argc/argv passed\r\n";
const abi_message = "zig-sdk: ABI discovery passed\r\n";
const startup_vector_message = "zig-sdk: envp/auxv passed\r\n";
const mmap_file_message = "zig-sdk: shared file mmap coherence passed\r\n";
const timestamp_message = "zig-sdk: creation/modify/change/access timestamp separation passed\r\n";
const mount_message = "zig-sdk: tmpfs mount/umount isolation, statfs and busy policy passed\r\n";
const pass_message = "zig-sdk: startup/argv/abi/files/vm/file-mmap/errno/fsync/fdatasync/readv/writev/mount/umount/tmpfs/statfs/stattimes passed\r\n";
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

    var root_fs: zigos.FilesystemStat = undefined;
    try zigos.statfs("/", &root_fs);
    if (root_fs.filesystem_kind != zigos.constants.filesystem_type_ramfs or
        root_fs.block_size != zigos.constants.abi_page_size or root_fs.total_blocks != 256 or
        root_fs.free_blocks > root_fs.total_blocks or root_fs.available_blocks != root_fs.free_blocks or
        root_fs.total_nodes != 96 or root_fs.free_nodes > root_fs.total_nodes or root_fs.mount_id != 1 or
        (root_fs.flags & (zigos.constants.filesystem_stat_shared_blocks | zigos.constants.filesystem_stat_shared_nodes)) !=
            (zigos.constants.filesystem_stat_shared_blocks | zigos.constants.filesystem_stat_shared_nodes) or
        (root_fs.flags & (zigos.constants.filesystem_stat_read_only | zigos.constants.filesystem_stat_synthetic)) != 0)
        return error.InvalidArgument;

    var proc_fs: zigos.FilesystemStat = undefined;
    try zigos.statfs("/proc/version", &proc_fs);
    if (proc_fs.filesystem_kind != zigos.constants.filesystem_type_procfs or proc_fs.total_blocks != 0 or proc_fs.free_blocks != 0 or
        (proc_fs.flags & (zigos.constants.filesystem_stat_read_only | zigos.constants.filesystem_stat_shared_nodes | zigos.constants.filesystem_stat_synthetic)) !=
            (zigos.constants.filesystem_stat_read_only | zigos.constants.filesystem_stat_shared_nodes | zigos.constants.filesystem_stat_synthetic))
        return error.InvalidArgument;

    var boot_fs: zigos.FilesystemStat = undefined;
    try zigos.statfs("/boot", &boot_fs);
    if (boot_fs.filesystem_kind != zigos.constants.filesystem_type_boot_fat or boot_fs.block_size == 0 or
        boot_fs.total_blocks == 0 or boot_fs.free_blocks > boot_fs.total_blocks or
        (boot_fs.flags & zigos.constants.filesystem_stat_read_only) == 0)
        return error.InvalidArgument;
    if ((boot_fs.flags & zigos.constants.filesystem_stat_shared_blocks) != 0) {
        if (boot_fs.block_size != zigos.constants.abi_page_size or boot_fs.total_blocks != 256) return error.InvalidArgument;
    }

    const fd = try zigos.open("/proc/version", .{ .read = true }, 0);
    defer zigos.close(fd) catch {};
    var status: zigos.Stat = undefined;
    try zigos.fstat(fd, &status);
    if (status.kind != 2 or status.readonly != 1 or @sizeOf(zigos.FileTimes) != 32) return error.InvalidArgument;
    var proc_times: zigos.FileTimes = undefined;
    try zigos.statTimes("/proc/version", &proc_times);
    if (proc_times.modified_tick != status.modified_tick) return error.InvalidArgument;

    var bytes: [128]u8 = undefined;
    const count = try zigos.read(fd, &bytes);
    if (count < 5 or !contains(bytes[0..count], "ZigOs")) return error.InvalidArgument;

    const vector_path = "/tmp/zig-sdk-vectors";
    zigos.unlink(vector_path) catch {};
    const vector_fd = try zigos.open(vector_path, .{ .read = true, .write = true, .create = true, .truncate = true }, 0o600);
    var created_times: zigos.FileTimes = undefined;
    try zigos.statTimes(vector_path, &created_times);
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
    try zigos.sleep(2);
    if (vector_status.size != 0 or try zigos.writev(vector_fd, &.{}) != 0 or try zigos.writev(vector_fd, &write_vectors) != 9) return error.InvalidArgument;
    var written_times: zigos.FileTimes = undefined;
    try zigos.statTimes(vector_path, &written_times);
    if (written_times.created_tick != created_times.created_tick or written_times.modified_tick <= created_times.modified_tick or
        written_times.changed_tick <= created_times.changed_tick or written_times.accessed_tick != created_times.accessed_tick)
        return error.InvalidArgument;
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
    try zigos.sleep(2);
    if (try zigos.readv(vector_fd, &read_vectors) != 9 or
        !equal(&first, "ve") or !equal(&second, "cto") or !equal(&third, "r-io")) return error.InvalidArgument;
    var read_times: zigos.FileTimes = undefined;
    try zigos.statTimes(vector_path, &read_times);
    if (read_times.created_tick != created_times.created_tick or read_times.modified_tick != written_times.modified_tick or
        read_times.changed_tick != written_times.changed_tick or read_times.accessed_tick <= written_times.accessed_tick)
        return error.InvalidArgument;
    try zigos.sleep(2);
    try zigos.chmod(vector_path, 0o600);
    var chmod_times: zigos.FileTimes = undefined;
    try zigos.statTimes(vector_path, &chmod_times);
    if (chmod_times.created_tick != created_times.created_tick or chmod_times.modified_tick != written_times.modified_tick or
        chmod_times.accessed_tick != read_times.accessed_tick or chmod_times.changed_tick <= read_times.changed_tick)
        return error.InvalidArgument;
    try zigos.writeAll(1, timestamp_message);
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

    const mapping_path = "/tmp/zig-sdk-mapped";
    zigos.unlink(mapping_path) catch {};
    const mapping_fd = try zigos.open(
        mapping_path,
        .{ .read = true, .write = true, .create = true, .truncate = true },
        0o600,
    );
    try zigos.writeAll(mapping_fd, "mapped-before");
    try zigos.chmod(mapping_path, 0);
    const file_mapping = zigos.mmapFile(
        null,
        13,
        .{ .read = true },
        mapping_fd,
        0,
    ) catch |err| {
        zigos.writeAll(2, "zig-sdk: shared file mmap call failed\r\n") catch {};
        return err;
    };
    if (!equal(file_mapping[0..13], "mapped-before")) {
        zigos.writeAll(2, "zig-sdk: shared file mmap initial bytes failed\r\n") catch {};
        return error.InvalidArgument;
    }
    if (try zigos.lseek(mapping_fd, 0, .start) != 0) return error.InvalidArgument;
    try zigos.writeAll(mapping_fd, "mapped-after!");
    if (!equal(file_mapping[0..13], "mapped-after!")) return error.InvalidArgument;
    var mapped_readback: [13]u8 = undefined;
    if (try zigos.lseek(mapping_fd, 0, .start) != 0 or try zigos.read(mapping_fd, &mapped_readback) != mapped_readback.len or
        !equal(&mapped_readback, file_mapping[0..13])) return error.InvalidArgument;
    try zigos.close(mapping_fd);
    try zigos.unlink(mapping_path);
    if (!equal(file_mapping[0..13], "mapped-after!")) return error.InvalidArgument;
    try zigos.munmap(file_mapping);
    try zigos.writeAll(1, mmap_file_message);
    try testMountSyscalls();
    try zigos.writeAll(1, mount_message);

    _ = zigos.open("/definitely/missing", .{ .read = true }, 0) catch |err| {
        if (err != error.NotFound) return err;
        return;
    };
    return error.InvalidArgument;
}

fn testMountSyscalls() zigos.Error!void {
    if (zigos.umount("/proc", 0)) |_| return error.InvalidArgument else |err| {
        if (err != error.Unsupported) return err;
    }
    const mountpoint = "/mnt";
    const underlay = "/mnt/underlay";
    const temporary = "/mnt/sdk-mounted";
    zigos.unlink(underlay) catch {};
    const underlay_fd = try zigos.open(underlay, .{ .write = true, .create = true, .truncate = true }, 0o600);
    try zigos.close(underlay_fd);
    if (zigos.mount(null, mountpoint, "tmpfs", .{}, null)) |_| return error.InvalidArgument else |err| {
        if (err != error.NotEmpty) return err;
    }
    try zigos.unlink(underlay);
    if (zigos.mount(null, mountpoint, "unsupported", .{}, null)) |_| return error.InvalidArgument else |err| {
        if (err != error.Unsupported) return err;
    }

    try zigos.mount("zig-sdk", mountpoint, "tmpfs", .{}, null);
    var mounted_fs: zigos.FilesystemStat = undefined;
    try zigos.statfs(mountpoint, &mounted_fs);
    if (mounted_fs.filesystem_kind != zigos.constants.filesystem_type_tmpfs or mounted_fs.mount_id <= 1 or
        mounted_fs.total_blocks != 256 or mounted_fs.free_blocks > mounted_fs.total_blocks or
        (mounted_fs.flags & zigos.constants.filesystem_stat_shared_blocks) == 0 or
        (mounted_fs.flags & zigos.constants.filesystem_stat_read_only) != 0)
        return error.InvalidArgument;
    var mounted: zigos.Stat = undefined;
    try zigos.stat(mountpoint, &mounted);
    if (mounted.mount_id <= 1 or mounted.readonly != 0 or mounted.kind != 1) return error.InvalidArgument;
    const mounted_fd = try zigos.open(temporary, .{ .read = true, .write = true, .create = true, .truncate = true }, 0o600);
    try zigos.writeAll(mounted_fd, "isolated-tmpfs");
    if (zigos.umount(mountpoint, 0)) |_| return error.InvalidArgument else |err| {
        if (err != error.Busy) return err;
    }
    try zigos.close(mounted_fd);
    try zigos.chdir(mountpoint);
    if (zigos.umount(mountpoint, 0)) |_| return error.InvalidArgument else |err| {
        if (err != error.Busy) return err;
    }
    try zigos.chdir("/");
    try zigos.umount(mountpoint, 0);
    if (zigos.stat(temporary, &mounted)) |_| return error.InvalidArgument else |err| {
        if (err != error.NotFound) return err;
    }
    try zigos.stat(mountpoint, &mounted);
    if (mounted.mount_id != 1 or mounted.readonly != 0 or mounted.kind != 1) return error.InvalidArgument;

    try zigos.mount(null, mountpoint, "tmpfs", .{ .read_only = true }, null);
    try zigos.stat(mountpoint, &mounted);
    if (mounted.mount_id <= 1 or mounted.readonly != 1) return error.InvalidArgument;
    if (zigos.open(temporary, .{ .write = true, .create = true }, 0o600)) |_| return error.InvalidArgument else |err| {
        if (err != error.ReadOnly) return err;
    }
    try zigos.umount(mountpoint, 0);
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
