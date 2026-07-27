const zigos = @import("zigos.zig");

const shell_path = "/bin/sh.elf";

pub export fn zigos_main(
    argc: usize,
    argv: [*]const usize,
    envp: [*]const usize,
    _: [*]const zigos.AuxvEntry,
) callconv(.c) u32 {
    if (argc != 1 or !zigos.stringEqual(@ptrFromInt(argv[0]), "init.elf")) return 0xE0;
    const pid = zigos.getpid() catch return 0xE1;
    if (pid != 1) return 0xE2;
    var environment_storage: [zigos.constants.maximum_environment][]const u8 = undefined;
    const environment = zigos.collectEnvironment(envp, &environment_storage) orelse return 0xE3;
    const arguments = [_][]const u8{ "sh.elf", "--login" };
    zigos.writeAll(1, "ZigOs userspace init PID 1\r\n") catch return 0xE4;
    const shell_pid = zigos.spawnv(shell_path, &arguments, environment) catch return 0xE5;
    if (shell_pid != 2) return 0xE6;
    zigos.writeAll(1, "userspace init launched shell PID 2\r\n") catch return 0xE7;
    var status: zigos.WaitStatus = undefined;
    const waited = zigos.wait(shell_pid, false, &status) catch return 0xE8;
    if (waited != shell_pid or status.pid != shell_pid or status.exit_status != 0) return 0xE9;
    zigos.writeAll(1, "userspace init reaped shell PID 2 status 0\r\n") catch return 0xEA;
    zigos.shutdown() catch return 0xEB;
    return 0xEC;
}
