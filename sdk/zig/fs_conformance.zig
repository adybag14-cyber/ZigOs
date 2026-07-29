const zigos = @import("zigos.zig");

const root_path = "/persist/abi14";
const source_path = "/persist/abi14/source.txt";
const renamed_path = "/persist/abi14/renamed.txt";
const temporary_directory = "/persist/abi14/remove";
const temporary_path = "/persist/abi14/remove/gone.txt";
const payload = "alpha-beta-gamma\n";
const replaced_payload = "retained-destination";
const link_path = "/persist/abi14/current";
const hard_link_path = "/persist/abi14/hard-current";
const link_target = "renamed.txt";
const loop_a_path = "/persist/abi14/loop-a";
const loop_b_path = "/persist/abi14/loop-b";
const sparse_path = "/persist/abi14/sparse.bin";
const sparse_offset = 2 * zigos.constants.abi_page_size;
const fsync_payload = "file-fsync-target-v2\n";
const fdatasync_payload = "file-fdatasync-target-v3-with-new-size\n";
const unrelated_dirty_payload = "unrelated-dirty-state";
const unrelated_fdatasync_dirty_payload = "unrelated-fdatasync-dirty-state";

pub export fn zigos_main(
    argc: usize,
    argv: [*]const usize,
    _: [*]const usize,
    _: [*]const zigos.AuxvEntry,
) callconv(.c) u32 {
    if (argc != 2) return 0xE0;
    const mode: [*:0]const u8 = @ptrFromInt(argv[1]);
    if (zigos.stringEqual(mode, "init")) return initialize() catch 0xE1;
    if (zigos.stringEqual(mode, "fsync")) return fileSync() catch 0xE2;
    if (zigos.stringEqual(mode, "fdatasync")) return fileDataSync() catch 0xE3;
    if (zigos.stringEqual(mode, "verify-live")) return verifyBaseline() catch 0xE4;
    if (zigos.stringEqual(mode, "verify")) return verify() catch 0xE5;
    return 0xE6;
}

fn initialize() zigos.Error!u32 {
    try zigos.mkdir(root_path, 0o755);
    const fd = try zigos.open(source_path, .{ .read = true, .write = true, .create = true, .truncate = true }, 0o644);
    try zigos.writeAll(fd, payload);
    const position = try zigos.lseek(fd, 6, .start);
    if (position != 6) return error.InvalidArgument;
    var sample: [4]u8 = undefined;
    if (try zigos.read(fd, &sample) != sample.len or !equal(&sample, "beta")) return error.InvalidArgument;
    try zigos.close(fd);

    const retained = try zigos.open(renamed_path, .{ .read = true, .write = true, .create = true, .truncate = true }, 0o640);
    try zigos.writeAll(retained, replaced_payload);
    if (try zigos.lseek(retained, 0, .start) != 0) return error.InvalidArgument;
    var retained_before: zigos.Stat = undefined;
    try zigos.fstat(retained, &retained_before);

    try zigos.rename(source_path, renamed_path);
    var missing_source: zigos.Stat = undefined;
    if (zigos.stat(source_path, &missing_source)) |_| return error.InvalidArgument else |err| {
        if (err != error.NotFound) return err;
    }
    var visible_after: zigos.Stat = undefined;
    try zigos.stat(renamed_path, &visible_after);
    if (visible_after.node == retained_before.node and visible_after.generation == retained_before.generation)
        return error.InvalidArgument;
    const visible = try zigos.open(renamed_path, .{ .read = true }, 0);
    var visible_payload: [payload.len]u8 = undefined;
    if (try zigos.read(visible, &visible_payload) != visible_payload.len or !equal(&visible_payload, payload))
        return error.InvalidArgument;
    try zigos.close(visible);
    var retained_payload: [replaced_payload.len]u8 = undefined;
    if (try zigos.read(retained, &retained_payload) != retained_payload.len or !equal(&retained_payload, replaced_payload))
        return error.InvalidArgument;
    try zigos.close(retained);
    try zigos.chmod(renamed_path, 0o600);
    try zigos.link(renamed_path, hard_link_path);
    var target_stat: zigos.Stat = undefined;
    var hard_stat: zigos.Stat = undefined;
    try zigos.stat(renamed_path, &target_stat);
    try zigos.stat(hard_link_path, &hard_stat);
    if (target_stat.node != hard_stat.node or target_stat.generation != hard_stat.generation or
        target_stat.link_count != 2 or hard_stat.link_count != 2) return error.InvalidArgument;
    try zigos.symlink(link_target, link_path);
    var stored_target: [32]u8 = undefined;
    const stored_target_length = try zigos.readlink(link_path, &stored_target);
    if (!equal(stored_target[0..stored_target_length], link_target)) return error.InvalidArgument;
    const linked = try zigos.open(link_path, .{ .read = true }, 0);
    var linked_payload: [payload.len]u8 = undefined;
    if (try zigos.read(linked, &linked_payload) != linked_payload.len or !equal(&linked_payload, payload))
        return error.InvalidArgument;
    try zigos.close(linked);
    try zigos.symlink("loop-b", loop_a_path);
    try zigos.symlink("loop-a", loop_b_path);
    if (zigos.open(loop_a_path, .{ .read = true }, 0)) |_| return error.InvalidArgument else |err| {
        if (err != error.Loop) return err;
    }
    try zigos.unlink(loop_a_path);
    try zigos.unlink(loop_b_path);
    const sparse = try zigos.open(sparse_path, .{ .read = true, .write = true, .create = true, .truncate = true }, 0o600);
    try zigos.fallocate(sparse, .{ .keep_size = true }, 0, zigos.constants.abi_page_size);
    var sparse_info: zigos.Stat = undefined;
    try zigos.fstat(sparse, &sparse_info);
    if (sparse_info.size != 0) return error.InvalidArgument;
    if (try zigos.lseek(sparse, sparse_offset, .start) != sparse_offset) return error.InvalidArgument;
    try zigos.writeAll(sparse, "tail");
    try zigos.close(sparse);
    try zigos.mkdir(temporary_directory, 0o755);
    const temporary = try zigos.open(temporary_path, .{ .read = true, .write = true, .create = true, .truncate = true }, 0o600);
    try zigos.writeAll(temporary, "open-after-unlink");
    try zigos.unlink(temporary_path);
    var missing_info: zigos.Stat = undefined;
    if (zigos.stat(temporary_path, &missing_info)) |_| return error.InvalidArgument else |err| {
        if (err != error.NotFound) return err;
    }
    if (try zigos.lseek(temporary, 0, .start) != 0) return error.InvalidArgument;
    var unlinked_sample: [17]u8 = undefined;
    if (try zigos.read(temporary, &unlinked_sample) != unlinked_sample.len or !equal(&unlinked_sample, "open-after-unlink")) return error.InvalidArgument;
    try zigos.close(temporary);
    const replacement = try zigos.open(temporary_path, .{ .write = true, .create = true, .truncate = true }, 0o600);
    try zigos.close(replacement);
    try zigos.unlink(temporary_path);
    try zigos.rmdir(temporary_directory);
    zigos.sync() catch |err| {
        const message = switch (err) {
            error.InputOutput => "fs-api: initial global sync failed input-output\r\n",
            error.NoSpace => "fs-api: initial global sync failed no-space\r\n",
            error.Unsupported => "fs-api: initial global sync failed unsupported\r\n",
            else => "fs-api: initial global sync failed other\r\n",
        };
        try zigos.writeAll(1, message);
        return err;
    };
    try zigos.writeAll(1, "fs-api: init/mkdir/write/seek/replace-rename/chmod/link/nlink/symlink/readlink/fallocate/sparse/open-unlink/rmdir/sync passed\r\n");
    return 0x58;
}

fn fileSync() zigos.Error!u32 {
    const target = try zigos.open(renamed_path, .{ .read = true, .write = true, .truncate = true }, 0);
    try zigos.writeAll(target, fsync_payload);
    try zigos.chmod(renamed_path, 0o640);

    const unrelated = try zigos.open(sparse_path, .{ .read = true, .write = true, .truncate = true }, 0);
    try zigos.writeAll(unrelated, unrelated_dirty_payload);
    try zigos.close(unrelated);

    try zigos.fsync(target);
    try zigos.close(target);
    try zigos.writeAll(1, "fs-api: file-fsync target data/mode committed unrelated dirty state excluded\r\n");
    return 0x5B;
}

fn fileDataSync() zigos.Error!u32 {
    const recovered = try zigos.open(renamed_path, .{ .read = true }, 0);
    var recovered_info: zigos.Stat = undefined;
    try zigos.fstat(recovered, &recovered_info);
    if (recovered_info.mode != 0o640 or recovered_info.size != fsync_payload.len) return error.InvalidArgument;
    var recovered_payload: [fsync_payload.len]u8 = undefined;
    if (try zigos.read(recovered, &recovered_payload) != recovered_payload.len or !equal(&recovered_payload, fsync_payload))
        return error.InvalidArgument;
    try zigos.close(recovered);

    var target_stat: zigos.Stat = undefined;
    var hard_stat: zigos.Stat = undefined;
    try zigos.stat(renamed_path, &target_stat);
    try zigos.stat(hard_link_path, &hard_stat);
    if (target_stat.node != hard_stat.node or target_stat.generation != hard_stat.generation or
        target_stat.link_count != 2 or hard_stat.link_count != 2) return error.InvalidArgument;
    const hard_fd = try zigos.open(hard_link_path, .{ .read = true }, 0);
    var hard_payload: [fsync_payload.len]u8 = undefined;
    if (try zigos.read(hard_fd, &hard_payload) != hard_payload.len or !equal(&hard_payload, fsync_payload))
        return error.InvalidArgument;
    try zigos.close(hard_fd);
    const linked = try zigos.open(link_path, .{ .read = true }, 0);
    var linked_payload: [fsync_payload.len]u8 = undefined;
    if (try zigos.read(linked, &linked_payload) != linked_payload.len or !equal(&linked_payload, fsync_payload))
        return error.InvalidArgument;
    try zigos.close(linked);

    const stable_sparse = try zigos.open(sparse_path, .{ .read = true }, 0);
    var sparse_info: zigos.Stat = undefined;
    try zigos.fstat(stable_sparse, &sparse_info);
    if (sparse_info.size != sparse_offset + 4) return error.InvalidArgument;
    var sparse_prefix: [16]u8 = undefined;
    if (try zigos.read(stable_sparse, &sparse_prefix) != sparse_prefix.len) return error.InvalidArgument;
    for (sparse_prefix) |byte| if (byte != 0) return error.InvalidArgument;
    if (try zigos.lseek(stable_sparse, sparse_offset, .start) != sparse_offset) return error.InvalidArgument;
    var sparse_tail: [4]u8 = undefined;
    if (try zigos.read(stable_sparse, &sparse_tail) != sparse_tail.len or !equal(&sparse_tail, "tail"))
        return error.InvalidArgument;
    try zigos.close(stable_sparse);

    const target = try zigos.open(renamed_path, .{ .read = true, .write = true, .truncate = true }, 0);
    try zigos.writeAll(target, fdatasync_payload);
    try zigos.chmod(renamed_path, 0o600);
    const unrelated = try zigos.open(sparse_path, .{ .read = true, .write = true, .truncate = true }, 0);
    try zigos.writeAll(unrelated, unrelated_fdatasync_dirty_payload);
    try zigos.close(unrelated);
    try zigos.fdatasync(target);
    try zigos.close(target);
    try zigos.writeAll(1, "fs-api: recovered fsync metadata then fdatasync data/size committed dirty mode and unrelated data excluded\r\n");
    return 0x5C;
}

fn verifyBaseline() zigos.Error!u32 {
    const fd = try zigos.open(renamed_path, .{ .read = true }, 0);
    var info: zigos.Stat = undefined;
    try zigos.fstat(fd, &info);
    if (info.mode != 0o600 or info.size != payload.len) return error.InvalidArgument;
    if (try zigos.lseek(fd, 6, .start) != 6) return error.InvalidArgument;
    var sample: [4]u8 = undefined;
    if (try zigos.read(fd, &sample) != sample.len or !equal(&sample, "beta")) return error.InvalidArgument;
    try zigos.close(fd);
    var target_stat: zigos.Stat = undefined;
    var hard_stat: zigos.Stat = undefined;
    try zigos.stat(renamed_path, &target_stat);
    try zigos.stat(hard_link_path, &hard_stat);
    if (target_stat.node != hard_stat.node or target_stat.generation != hard_stat.generation or
        target_stat.link_count != 2 or hard_stat.link_count != 2) return error.InvalidArgument;
    const hard_fd = try zigos.open(hard_link_path, .{ .read = true }, 0);
    var hard_payload: [payload.len]u8 = undefined;
    if (try zigos.read(hard_fd, &hard_payload) != hard_payload.len or !equal(&hard_payload, payload))
        return error.InvalidArgument;
    try zigos.close(hard_fd);
    var stored_target: [32]u8 = undefined;
    const stored_target_length = try zigos.readlink(link_path, &stored_target);
    if (!equal(stored_target[0..stored_target_length], link_target)) return error.InvalidArgument;
    const linked = try zigos.open(link_path, .{ .read = true }, 0);
    var linked_payload: [payload.len]u8 = undefined;
    if (try zigos.read(linked, &linked_payload) != linked_payload.len or !equal(&linked_payload, payload))
        return error.InvalidArgument;
    try zigos.close(linked);
    const sparse = try zigos.open(sparse_path, .{ .read = true, .write = true }, 0);
    var sparse_info: zigos.Stat = undefined;
    try zigos.fstat(sparse, &sparse_info);
    if (sparse_info.size != sparse_offset + 4) return error.InvalidArgument;
    var sparse_prefix: [16]u8 = undefined;
    if (try zigos.read(sparse, &sparse_prefix) != sparse_prefix.len) return error.InvalidArgument;
    for (sparse_prefix) |byte| if (byte != 0) return error.InvalidArgument;
    if (try zigos.lseek(sparse, sparse_offset, .start) != sparse_offset) return error.InvalidArgument;
    var sparse_tail: [4]u8 = undefined;
    if (try zigos.read(sparse, &sparse_tail) != sparse_tail.len or !equal(&sparse_tail, "tail")) return error.InvalidArgument;
    if (zigos.fallocate(sparse, .{ .punch_hole = true }, sparse_offset, zigos.constants.abi_page_size)) |_| return error.InvalidArgument else |err| {
        if (err != error.InvalidArgument) return err;
    }
    try zigos.fallocate(sparse, .{ .keep_size = true, .punch_hole = true }, sparse_offset, zigos.constants.abi_page_size);
    if (try zigos.lseek(sparse, sparse_offset, .start) != sparse_offset) return error.InvalidArgument;
    if (try zigos.read(sparse, &sparse_tail) != sparse_tail.len) return error.InvalidArgument;
    for (sparse_tail) |byte| if (byte != 0) return error.InvalidArgument;
    try zigos.close(sparse);
    try zigos.unlink(sparse_path);
    try zigos.unlink(link_path);
    try zigos.unlink(hard_link_path);
    try zigos.unlink(renamed_path);
    try zigos.rmdir(root_path);
    try zigos.sync();
    try zigos.writeAll(1, "fs-api: baseline/mode/seek/hard-link/symlink/fallocate/sparse/cleanup passed\r\n");
    return 0x59;
}

fn verify() zigos.Error!u32 {
    const fd = try zigos.open(renamed_path, .{ .read = true }, 0);
    var info: zigos.Stat = undefined;
    try zigos.fstat(fd, &info);
    if (info.mode != 0o640 or info.size != fdatasync_payload.len) return error.InvalidArgument;
    if (try zigos.lseek(fd, 0, .start) != 0) return error.InvalidArgument;
    var target_payload: [fdatasync_payload.len]u8 = undefined;
    if (try zigos.read(fd, &target_payload) != target_payload.len or !equal(&target_payload, fdatasync_payload))
        return error.InvalidArgument;
    try zigos.close(fd);
    var target_stat: zigos.Stat = undefined;
    var hard_stat: zigos.Stat = undefined;
    try zigos.stat(renamed_path, &target_stat);
    try zigos.stat(hard_link_path, &hard_stat);
    if (target_stat.node != hard_stat.node or target_stat.generation != hard_stat.generation or
        target_stat.link_count != 2 or hard_stat.link_count != 2) return error.InvalidArgument;
    const hard_fd = try zigos.open(hard_link_path, .{ .read = true }, 0);
    var hard_payload: [fdatasync_payload.len]u8 = undefined;
    if (try zigos.read(hard_fd, &hard_payload) != hard_payload.len or !equal(&hard_payload, fdatasync_payload))
        return error.InvalidArgument;
    try zigos.close(hard_fd);
    var stored_target: [32]u8 = undefined;
    const stored_target_length = try zigos.readlink(link_path, &stored_target);
    if (!equal(stored_target[0..stored_target_length], link_target)) return error.InvalidArgument;
    const linked = try zigos.open(link_path, .{ .read = true }, 0);
    var linked_payload: [fdatasync_payload.len]u8 = undefined;
    if (try zigos.read(linked, &linked_payload) != linked_payload.len or !equal(&linked_payload, fdatasync_payload))
        return error.InvalidArgument;
    try zigos.close(linked);
    const sparse = try zigos.open(sparse_path, .{ .read = true, .write = true }, 0);
    var sparse_info: zigos.Stat = undefined;
    try zigos.fstat(sparse, &sparse_info);
    if (sparse_info.size != sparse_offset + 4) return error.InvalidArgument;
    var sparse_prefix: [16]u8 = undefined;
    if (try zigos.read(sparse, &sparse_prefix) != sparse_prefix.len) return error.InvalidArgument;
    for (sparse_prefix) |byte| if (byte != 0) return error.InvalidArgument;
    if (try zigos.lseek(sparse, sparse_offset, .start) != sparse_offset) return error.InvalidArgument;
    var sparse_tail: [4]u8 = undefined;
    if (try zigos.read(sparse, &sparse_tail) != sparse_tail.len or !equal(&sparse_tail, "tail")) return error.InvalidArgument;
    if (zigos.fallocate(sparse, .{ .punch_hole = true }, sparse_offset, zigos.constants.abi_page_size)) |_| return error.InvalidArgument else |err| {
        if (err != error.InvalidArgument) return err;
    }
    try zigos.fallocate(sparse, .{ .keep_size = true, .punch_hole = true }, sparse_offset, zigos.constants.abi_page_size);
    if (try zigos.lseek(sparse, sparse_offset, .start) != sparse_offset) return error.InvalidArgument;
    if (try zigos.read(sparse, &sparse_tail) != sparse_tail.len) return error.InvalidArgument;
    for (sparse_tail) |byte| if (byte != 0) return error.InvalidArgument;
    try zigos.close(sparse);
    try zigos.unlink(sparse_path);
    try zigos.unlink(link_path);
    try zigos.unlink(hard_link_path);
    try zigos.unlink(renamed_path);
    try zigos.rmdir(root_path);
    try zigos.sync();
    try zigos.writeAll(1, "fs-api: recovery/fsync-metadata/fdatasync-data-only/hard-link/symlink/sparse-isolation/cleanup passed\r\n");
    return 0x59;
}

fn equal(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}
