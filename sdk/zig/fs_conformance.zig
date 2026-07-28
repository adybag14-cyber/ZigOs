const zigos = @import("zigos.zig");

const root_path = "/persist/abi14";
const source_path = "/persist/abi14/source.txt";
const renamed_path = "/persist/abi14/renamed.txt";
const temporary_directory = "/persist/abi14/remove";
const temporary_path = "/persist/abi14/remove/gone.txt";
const payload = "alpha-beta-gamma\n";
const replaced_payload = "retained-destination";

pub export fn zigos_main(
    argc: usize,
    argv: [*]const usize,
    _: [*]const usize,
    _: [*]const zigos.AuxvEntry,
) callconv(.c) u32 {
    if (argc != 2) return 0xE0;
    const mode: [*:0]const u8 = @ptrFromInt(argv[1]);
    if (zigos.stringEqual(mode, "init")) return initialize() catch 0xE1;
    if (zigos.stringEqual(mode, "verify")) return verify() catch 0xE2;
    return 0xE3;
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
    try zigos.sync();
    try zigos.writeAll(1, "fs-api: init/mkdir/write/seek/replace-rename/chmod/open-unlink/rmdir/sync passed\r\n");
    return 0x58;
}

fn verify() zigos.Error!u32 {
    const fd = try zigos.open(renamed_path, .{ .read = true }, 0);
    var info: zigos.Stat = undefined;
    try zigos.fstat(fd, &info);
    if (info.mode != 0o600 or info.size != payload.len) return error.InvalidArgument;
    if (try zigos.lseek(fd, 6, .start) != 6) return error.InvalidArgument;
    var sample: [4]u8 = undefined;
    if (try zigos.read(fd, &sample) != sample.len or !equal(&sample, "beta")) return error.InvalidArgument;
    try zigos.close(fd);
    try zigos.unlink(renamed_path);
    try zigos.rmdir(root_path);
    try zigos.sync();
    try zigos.writeAll(1, "fs-api: recovery/mode/seek/cleanup passed\r\n");
    return 0x59;
}

fn equal(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}
