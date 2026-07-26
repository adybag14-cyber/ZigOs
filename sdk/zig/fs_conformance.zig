const zigos = @import("zigos.zig");

const root_path = "/persist/abi14";
const source_path = "/persist/abi14/source.txt";
const renamed_path = "/persist/abi14/renamed.txt";
const temporary_directory = "/persist/abi14/remove";
const temporary_path = "/persist/abi14/remove/gone.txt";
const payload = "alpha-beta-gamma\n";

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
    try zigos.rename(source_path, renamed_path);
    try zigos.chmod(renamed_path, 0o600);
    try zigos.mkdir(temporary_directory, 0o755);
    const temporary = try zigos.open(temporary_path, .{ .write = true, .create = true, .truncate = true }, 0o600);
    try zigos.close(temporary);
    try zigos.unlink(temporary_path);
    try zigos.rmdir(temporary_directory);
    try zigos.sync();
    try zigos.writeAll(1, "fs-api: init/mkdir/write/seek/rename/chmod/unlink/rmdir/sync passed\r\n");
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
