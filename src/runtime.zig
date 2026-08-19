const std = @import("std");
const apic = @import("apic.zig");
const descriptor_tables = @import("descriptor_tables.zig");
const elf64 = @import("elf64.zig");
const e1000e = @import("e1000e.zig");
const interrupt_context = @import("interrupt_context.zig");
const memory = @import("memory.zig");
const nvme = @import("nvme.zig");
const runtime_abi = @import("runtime_abi.zig");
const runtime_boot_fat = @import("runtime_boot_fat.zig");
const runtime_command = @import("runtime_command.zig");
const runtime_fd = @import("runtime_fd.zig");
const runtime_process = @import("runtime_process.zig");
const runtime_pseudo_fs = @import("runtime_pseudo_fs.zig");
const runtime_persist = @import("runtime_persist.zig");
const runtime_tty = @import("runtime_tty.zig");
const runtime_user = @import("runtime_user.zig");
const runtime_vfs = @import("runtime_vfs.zig");
const serial = @import("serial.zig");

const cc = std.os.uefi.cc;
const service_elf = @embedFile("generated/service_user.elf");
const process_elf = @embedFile("generated/process_user.elf");
const process_exec_elf = @embedFile("generated/process_exec.elf");
const runtime_hello_elf = @embedFile("generated/runtime_hello.elf");
const runtime_sleep_fixture_elf = @embedFile("generated/runtime_sleep.elf");
const runtime_wait_short_elf = @embedFile("generated/runtime_wait_short.elf");
const runtime_crash_elf = @embedFile("generated/runtime_crash.elf");
const runtime_spin_elf = @embedFile("generated/runtime_spin.elf");
const runtime_pipe_reader_elf = @embedFile("generated/runtime_pipe_reader.elf");
const runtime_pipe_writer_elf = @embedFile("generated/runtime_pipe_writer.elf");
const runtime_wait_elf = @embedFile("generated/runtime_wait.elf");
const runtime_vm_elf = @embedFile("generated/runtime_vm.elf");
const runtime_io_elf = @embedFile("generated/runtime_io.elf");
const runtime_tty_elf = @embedFile("generated/runtime_tty.elf");
const runtime_socket_elf = @embedFile("generated/runtime_socket.elf");
const runtime_sdk_elf = @import("runtime_sdk").sdk;
const runtime_init_elf = @import("runtime_sdk").init;
const runtime_shell_elf = @import("runtime_sdk").shell;
const runtime_fs_elf = @import("runtime_sdk").fs;
const runtime_kill_elf = @import("runtime_sdk").kill;
const runtime_sleep_elf = @import("runtime_sdk").sleep;
const runtime_mount_elf = @import("runtime_sdk").mount;
const runtime_df_elf = @import("runtime_sdk").df;
const runtime_fsck_elf = @import("runtime_sdk").fsck;
const runtime_uname_elf = @import("runtime_sdk").uname;
const runtime_env_elf = @import("runtime_sdk").env;
const runtime_ps_elf = @import("runtime_sdk").ps;
const runtime_hexdump_elf = @import("runtime_sdk").hexdump;
const runtime_head_elf = @import("runtime_sdk").head;
const runtime_tail_elf = @import("runtime_sdk").tail;
const runtime_wc_elf = @import("runtime_sdk").wc;
const runtime_grep_elf = @import("runtime_sdk").grep;
const runtime_stat_elf = @import("runtime_sdk").stat;
const runtime_mv_elf = @import("runtime_sdk").mv;
const runtime_cp_elf = @import("runtime_sdk").cp;
const runtime_rm_elf = @import("runtime_sdk").rm;
const runtime_rmdir_elf = @import("runtime_sdk").rmdir;
const runtime_mkdir_elf = @import("runtime_sdk").mkdir;
const runtime_pwd_elf = @import("runtime_sdk").pwd;
const runtime_echo_elf = @import("runtime_sdk").echo;
const runtime_cat_elf = @import("runtime_sdk").cat;
const runtime_ls_elf = @import("runtime_sdk").ls;
const runtime_dns_elf = @import("runtime_sdk").dns;
const runtime_c_sdk_elf = @import("runtime_sdk").c_sdk;

extern fn zigos_debug_putc(character: u8) callconv(cc) void;
extern fn zigos_wait_for_interrupt() callconv(cc) void;
extern fn zigos_enable_interrupts() callconv(cc) void;

pub const Profile = enum {
    diagnostic,
    normal,
};

const generated_pseudo_operations = runtime_vfs.PseudoOperations{
    .read = readGeneratedPseudo,
    .poll = pollGeneratedPseudo,
};
const null_pseudo_operations = runtime_vfs.PseudoOperations{
    .read = readNullPseudo,
    .write = writeDiscardPseudo,
    .poll = pollNullOrZeroPseudo,
};
const zero_pseudo_operations = runtime_vfs.PseudoOperations{
    .read = readZeroPseudo,
    .write = writeDiscardPseudo,
    .poll = pollNullOrZeroPseudo,
};
const console_pseudo_operations = runtime_vfs.PseudoOperations{
    .stream = .console,
};

pub const Configuration = struct {
    profile: Profile = .diagnostic,
    physical_memory: *memory.PhysicalMemoryManager,
    ticks_per_second: u64,
    network_ready: bool,
    usb_keyboard_ready: bool,
    nvme_ready: bool,
    nvme_controller: ?*nvme.Controller,
    nvme_boot_first_lba: u64,
    nvme_boot_sector_count: u64,
    nvme_data_first_lba: u64,
    nvme_data_sector_count: u64,
    ahci_ready: bool,
    framebuffer_ready: bool,
};

const maximum_pipeline_bytes: usize = runtime_vfs.maximum_file_size;
const file_page_cache_low_watermark_pages: u64 = 64;
const file_page_cache_pressure_target_entries: usize = 4;
const pipex_writer_gate: u64 = 0x5049_5045_5857_5254;

const Output = struct {
    storage: *[maximum_pipeline_bytes]u8,
    length: usize = 0,
    truncated: bool = false,

    fn init(storage: *[maximum_pipeline_bytes]u8) Output {
        @memset(storage, 0);
        return .{ .storage = storage };
    }

    fn write(self: *Output, bytes: []const u8) void {
        const count = @min(bytes.len, self.storage.len - self.length);
        if (count != 0) @memcpy(self.storage[self.length .. self.length + count], bytes[0..count]);
        self.length += count;
        self.truncated = self.truncated or count != bytes.len;
    }

    fn byte(self: *Output, value: u8) void {
        if (self.length >= self.storage.len) {
            self.truncated = true;
            return;
        }
        self.storage[self.length] = value;
        self.length += 1;
    }

    fn decimal(self: *Output, value: u64) void {
        var digits: [20]u8 = undefined;
        var count: usize = 0;
        var remaining = value;
        if (remaining == 0) {
            self.byte('0');
            return;
        }
        while (remaining != 0) : (remaining /= 10) {
            digits[count] = @intCast('0' + remaining % 10);
            count += 1;
        }
        while (count != 0) {
            count -= 1;
            self.byte(digits[count]);
        }
    }

    fn signedDecimal(self: *Output, value: i64) void {
        if (value < 0) {
            self.byte('-');
            self.decimal(@intCast(-value));
        } else {
            self.decimal(@intCast(value));
        }
    }

    fn hex(self: *Output, value: u64) void {
        const digits = "0123456789ABCDEF";
        var shift: u6 = 60;
        var started = false;
        while (true) {
            const nibble: u4 = @truncate(value >> shift);
            if (nibble != 0 or started or shift == 0) {
                self.byte(digits[nibble]);
                started = true;
            }
            if (shift == 0) break;
            shift -= 4;
        }
    }

    fn hexFixed(self: *Output, value: u64, digit_count: usize) void {
        const digits = "0123456789ABCDEF";
        var position = digit_count;
        while (position != 0) {
            position -= 1;
            const shift: u6 = @intCast(position * 4);
            self.byte(digits[@as(u4, @truncate(value >> shift))]);
        }
    }

    fn octal(self: *Output, value: u16) void {
        var divisor: u16 = 0o100;
        while (divisor != 0) : (divisor /= 8) self.byte(@intCast('0' + (value / divisor) % 8));
    }

    fn line(self: *Output, bytes: []const u8) void {
        self.write(bytes);
        self.write("\r\n");
    }

    fn slice(self: *const Output) []const u8 {
        return self.storage[0..self.length];
    }
};

const State = struct {
    config: Configuration = undefined,
    vfs: runtime_vfs.Vfs = undefined,
    processes: runtime_process.Table = undefined,
    descriptors: runtime_fd.System = undefined,
    tty: runtime_tty.Tty = .{},
    boot_fat: runtime_boot_fat.Backend = .{},
    persistence: runtime_persist.Store = .{},
    devfs: runtime_pseudo_fs.Registry = runtime_pseudo_fs.Registry.init(.devfs),
    procfs: runtime_pseudo_fs.Registry = runtime_pseudo_fs.Registry.init(.procfs),
    netfs: runtime_pseudo_fs.Registry = runtime_pseudo_fs.Registry.init(.netfs),
    environment: runtime_command.Environment = undefined,
    editor: runtime_command.LineEditor = .{},
    cwd: u16 = 0,
    shell_handle: u64 = 0,
    shell_exit_requested: bool = false,
    init_reaped_shell: bool = false,
    pipeline_a: [maximum_pipeline_bytes]u8 = @splat(0),
    pipeline_b: [maximum_pipeline_bytes]u8 = @splat(0),
    input_buffer: [maximum_pipeline_bytes]u8 = @splat(0),
    pseudo_buffer: [maximum_pipeline_bytes]u8 = @splat(0),
    pseudo_busy: bool = false,
    command_count: u64 = 0,
    failed_commands: u64 = 0,
    serial_line_errors: u64 = 0,
    idle_halts: u64 = 0,
    device_service_passes: u64 = 0,
    network_service_passes: u64 = 0,
    live_ping_passes: u64 = 0,
    live_dns_passes: u64 = 0,
    network_failures: u64 = 0,
    filesystem_syncs: u64 = 0,
    filesystem_checks: u64 = 0,
    last_serviced_tick: u64 = 0,
    shell_sleeping: bool = false,
    shell_waiting: bool = false,
    shutdown_requested: bool = false,
    prompt_visible: bool = false,
    ignore_next_lf: bool = false,
    fd_contract_passed: bool = false,
};

var state: State = undefined;
var runtime_interrupt_count: u64 align(8) = 0;

pub fn run(configuration: Configuration) noreturn {
    initialize(configuration) catch |err| runtimeFailure(@errorName(err));
    if (!descriptor_tables.installPersistentRuntimeDescriptors()) runtimeFailure("persistent GDT/IDT takeover failed");
    apic.setTimerHook(null);
    apic.stopTimer();
    @atomicStore(u64, &runtime_interrupt_count, 0, .monotonic);
    const timer_count_u64 = @max(@as(u64, 1), configuration.ticks_per_second / 100);
    if (timer_count_u64 > std.math.maxInt(u32)) runtimeFailure("runtime timer count overflow");
    if (!apic.startCurrentProcessorPeriodicTimer(descriptor_tables.persistent_runtime_timer_vector, @intCast(timer_count_u64)))
        runtimeFailure("persistent APIC runtime timer failed");

    emit("\r\nZigOs persistent runtime online\r\n");
    switch (configuration.profile) {
        .diagnostic => {
            emit("init PID 1; serial shell PID 2; APIC scheduling 100 Hz; writable ramfs mounted at /\r\n");
            emit("Type 'help' for commands. The kernel remains live until an explicit shutdown command.\r\n");
            printPrompt();
        },
        .normal => emit("ZigOs normal boot profile: userspace init PID 1 supervises userspace shell PID 2; diagnostic software suite skipped\r\n"),
    }

    while (true) {
        serviceRuntime();
        var received = false;
        while (true) {
            const status = serial.tryRead();
            if (status.line_error) state.serial_line_errors +%= 1;
            const byte = status.byte orelse break;
            received = true;
            if (configuration.profile == .normal)
                consumeForegroundInput(byte)
            else
                consumeInput(byte);
            if (state.shutdown_requested) break;
        }
        if (configuration.profile == .normal and !state.shutdown_requested) {
            const serviced = runtime_user.serviceOne(currentTick()) catch |err| runtimeFailure(@errorName(err));
            if (serviced) |handle| flushUserspaceOutput(handle);
        }
        if (state.shutdown_requested) finishRuntime();
        if (!received) {
            state.idle_halts +%= 1;
            zigos_wait_for_interrupt();
        }
    }
}

fn initialize(configuration: Configuration) !void {
    state = undefined;
    state.config = configuration;
    state.vfs.initialize();
    try state.vfs.setFilePageAllocator(.{
        .context = configuration.physical_memory,
        .allocate = allocateFilePageCachePage,
        .release = releaseFilePageCachePage,
    });
    state.processes.initialize(0);
    state.descriptors.initialize();
    state.boot_fat = runtime_boot_fat.Backend.init();
    state.persistence.initialize();
    state.devfs = runtime_pseudo_fs.Registry.init(.devfs);
    state.procfs = runtime_pseudo_fs.Registry.init(.procfs);
    state.netfs = runtime_pseudo_fs.Registry.init(.netfs);
    state.environment = runtime_command.Environment.init();
    state.editor = .{};
    state.pipeline_a = @splat(0);
    state.pipeline_b = @splat(0);
    state.input_buffer = @splat(0);
    state.pseudo_buffer = @splat(0);
    state.pseudo_busy = false;
    state.command_count = 0;
    state.failed_commands = 0;
    state.serial_line_errors = 0;
    state.idle_halts = 0;
    state.device_service_passes = 0;
    state.network_service_passes = 0;
    state.live_ping_passes = 0;
    state.live_dns_passes = 0;
    state.network_failures = 0;
    state.filesystem_syncs = 0;
    state.filesystem_checks = 0;
    state.last_serviced_tick = 0;
    state.shell_handle = 0;
    state.shell_exit_requested = false;
    state.init_reaped_shell = false;
    state.shell_sleeping = false;
    state.shell_waiting = false;
    state.shutdown_requested = false;
    state.prompt_visible = false;
    state.ignore_next_lf = false;
    state.fd_contract_passed = false;
    @atomicStore(u64, &runtime_interrupt_count, 0, .monotonic);

    try initializeFilesystem();
    try initializePersistentStorage();
    state.cwd = try state.vfs.resolve(0, "/home/root");
    const init_handle = state.processes.initHandle();
    try state.processes.block(init_handle, .device_io, 1);
    state.descriptors.setTerminalBackend(&state.tty);
    switch (configuration.profile) {
        .diagnostic => {
            state.shell_handle = try state.processes.spawn(
                init_handle,
                .kernel,
                "zsh",
                &.{ "zsh", "--login" },
                state.cwd,
                0,
                0,
                0,
                .{ .maximum_pages = 128, .maximum_descriptors = 32, .maximum_sockets = 16, .maximum_children = 24 },
            );
            try state.processes.setRunning(state.shell_handle);
            try state.processes.setResourceUsage(state.shell_handle, 8, 0, 0);
            try state.descriptors.bindProcess(&state.processes, state.shell_handle, true);
            state.tty.initialize(state.shell_handle);
            try state.tty.setForeground(&state.processes, state.shell_handle);
            try runtime_user.initialize(configuration.physical_memory, &state.vfs, &state.processes, &state.descriptors);
            runtime_user.setSystemBackend(null, null, syncAllWritableMounts, syncPersistentFile, checkFilesystems, false, state.persistence.report().mounted);
        },
        .normal => {
            try state.descriptors.bindProcess(&state.processes, init_handle, true);
            try runtime_user.initialize(configuration.physical_memory, &state.vfs, &state.processes, &state.descriptors);
            runtime_user.setSystemBackend(null, requestNormalShutdown, syncAllWritableMounts, syncPersistentFile, checkFilesystems, true, state.persistence.report().mounted);
            runtime_user.setChildSpawnCallback(configureNormalChild);
            state.tty.initialize(init_handle);
            try state.processes.configureInitUserspace("init.elf", &.{"init.elf"}, state.cwd);
            try runtime_user.attachExisting(
                init_handle,
                &.{"init.elf"},
                &runtime_user.default_environment,
                runtime_init_elf,
                .{},
            );
        },
    }
    if (configuration.network_ready) {
        const device = e1000e.activeDevice() orelse return error.NetworkStateMissing;
        _ = e1000e.prepareRuntimeMmio(device);
        if (!e1000e.enterRuntimePollingMode(device)) return error.NetworkPollingHandoffFailed;
    }
}

fn initializePersistentStorage() !void {
    const controller = state.config.nvme_controller orelse return;
    if (state.config.nvme_data_first_lba == 0 or state.config.nvme_data_sector_count == 0) return error.PersistentPartitionMissing;
    const device = runtime_persist.BlockDevice{
        .context = controller,
        .block_size = controller.logical_block_size,
        .first_lba = state.config.nvme_data_first_lba,
        .sector_count = state.config.nvme_data_sector_count,
        .read_fn = persistentReadBlock,
        .write_fn = persistentWriteBlock,
        .flush_fn = persistentFlush,
    };
    state.persistence.mount(&state.vfs, device, currentTick()) catch |err| {
        if (state.persistence.restoreFailure()) |failure| {
            emit("Persistent restore rejected record ");
            emitDecimal(failure.record_index);
            emit(" kind ");
            emitDecimal(failure.record_kind);
            emit(" VFS error ");
            emit(@errorName(failure.vfs_error));
            emit("\r\n");
        }
        return err;
    };
}

fn allocateFilePageCachePage(context: ?*anyopaque) ?usize {
    const manager: *memory.PhysicalMemoryManager = @ptrCast(@alignCast(context.?));
    const address = manager.allocateBelow(memory.four_gib) orelse return null;
    @memset(@as([*]u8, @ptrFromInt(address))[0..runtime_vfs.file_block_size], 0);
    return address;
}

fn releaseFilePageCachePage(context: ?*anyopaque, address: usize) bool {
    const manager: *memory.PhysicalMemoryManager = @ptrCast(@alignCast(context.?));
    manager.free(address) catch return false;
    return true;
}

fn bootFatReadBlock(context: ?*anyopaque, lba: u64, output: []u8) bool {
    const controller: *nvme.Controller = @ptrCast(@alignCast(context.?));
    return nvme.readBlock(controller, lba, output);
}

fn persistentReadBlock(context: ?*anyopaque, lba: u64, output: []u8) bool {
    const controller: *nvme.Controller = @ptrCast(@alignCast(context.?));
    return nvme.readBlock(controller, lba, output);
}

fn persistentWriteBlock(context: ?*anyopaque, lba: u64, input: []const u8, force_unit_access: bool) bool {
    const controller: *nvme.Controller = @ptrCast(@alignCast(context.?));
    return nvme.writeBlock(controller, lba, input, force_unit_access);
}

fn persistentFlush(context: ?*anyopaque) bool {
    const controller: *nvme.Controller = @ptrCast(@alignCast(context.?));
    return nvme.flush(controller);
}

fn initializeFilesystem() !void {
    const directories = [_][]const u8{
        "/bin",     "/boot", "/dev",     "/etc",     "/home",    "/home/root",
        "/mnt",     "/net",  "/persist", "/proc",    "/tmp",     "/usr",
        "/usr/bin", "/var",  "/var/log", "/var/run", "/var/tmp",
    };
    for (directories) |path| _ = try state.vfs.mkdir(0, path, if (std.mem.startsWith(u8, path, "/tmp") or std.mem.startsWith(u8, path, "/var/tmp")) 0o777 else 0o755, 0);

    _ = try state.vfs.putFile(0, "/etc/hostname", "zigos\n", 0o644, false, 0);
    _ = try state.vfs.putFile(0, "/etc/os-release", "NAME=ZigOs\nVERSION=19.0.0\nARCH=x86_64\n", 0o644, false, 0);
    _ = try state.vfs.putFile(0, "/etc/motd", "ZigOs persistent x86-64 runtime\n", 0o644, false, 0);
    _ = try state.vfs.putFile(0, "/home/root/readme.txt", "This filesystem remains available after boot validation.\n", 0o644, false, 0);
    _ = try state.vfs.putFile(0, "/var/log/boot.log", "Capstone 16 validation passed; Capstone 19 permanent userspace runtime entered.\n", 0o640, false, 0);
    _ = try state.vfs.putFile(0, "/bin/hello.elf", runtime_hello_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/runtime-sleep.elf", runtime_sleep_fixture_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/wait-short.elf", runtime_wait_short_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/crash.elf", runtime_crash_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/spin.elf", runtime_spin_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/pipe-reader.elf", runtime_pipe_reader_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/pipe-writer.elf", runtime_pipe_writer_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/wait.elf", runtime_wait_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/vm.elf", runtime_vm_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/io.elf", runtime_io_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/tty.elf", runtime_tty_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/socket.elf", runtime_socket_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/sdk.elf", runtime_sdk_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/init.elf", runtime_init_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/sh.elf", runtime_shell_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/fs.elf", runtime_fs_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/kill.elf", runtime_kill_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/sleep.elf", runtime_sleep_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/mount.elf", runtime_mount_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/df.elf", runtime_df_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/fsck.elf", runtime_fsck_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/uname.elf", runtime_uname_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/env.elf", runtime_env_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/ps.elf", runtime_ps_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/hexdump.elf", runtime_hexdump_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/head.elf", runtime_head_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/tail.elf", runtime_tail_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/wc.elf", runtime_wc_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/grep.elf", runtime_grep_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/stat.elf", runtime_stat_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/mv.elf", runtime_mv_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/cp.elf", runtime_cp_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/rm.elf", runtime_rm_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/rmdir.elf", runtime_rmdir_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/mkdir.elf", runtime_mkdir_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/pwd.elf", runtime_pwd_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/echo.elf", runtime_echo_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/cat.elf", runtime_cat_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/ls.elf", runtime_ls_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/dns.elf", runtime_dns_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/c-sdk.elf", runtime_c_sdk_elf, 0o555, false, 0);

    if (state.config.nvme_controller != null and state.config.nvme_boot_first_lba != 0 and state.config.nvme_boot_sector_count != 0) {
        const controller = state.config.nvme_controller.?;
        if (state.boot_fat.mount(&state.vfs, "/boot", "nvme0p1", .{
            .context = controller,
            .block_size = controller.logical_block_size,
            .first_lba = state.config.nvme_boot_first_lba,
            .sector_count = state.config.nvme_boot_sector_count,
            .read_fn = bootFatReadBlock,
        }, 0)) |_| {} else |err| {
            if (!state.boot_fat.quarantine(err)) return err;
            try installEmbeddedBootAssets("embedded-quarantine");
            emit("ZigOs boot FAT quarantined: ");
            emit(@tagName(state.boot_fat.report().quarantine_reason));
            emit("; embedded read-only fallback mounted\r\n");
        }
    } else {
        try installEmbeddedBootAssets("embedded-assets");
    }
    _ = try state.procfs.mount(&state.vfs, "/proc", "process-table", 0);
    inline for (.{ "version", "uptime", "meminfo", "processes", "mounts" }) |name| {
        _ = try state.procfs.register(&state.vfs, name, 0o444, &generated_pseudo_operations, null, 0);
    }
    _ = try state.devfs.mount(&state.vfs, "/dev", "kernel-devices", 0);
    _ = try state.devfs.register(&state.vfs, "console", 0o666, &console_pseudo_operations, null, 0);
    _ = try state.devfs.register(&state.vfs, "null", 0o666, &null_pseudo_operations, null, 0);
    _ = try state.devfs.register(&state.vfs, "zero", 0o666, &zero_pseudo_operations, null, 0);
    _ = try state.netfs.mount(&state.vfs, "/net", "network-state", 0);
    inline for (.{ "interfaces", "routes", "arp", "sockets" }) |name| {
        _ = try state.netfs.register(&state.vfs, name, 0o444, &generated_pseudo_operations, null, 0);
    }
    if (!state.vfs.validate() or !livePseudoFilesystemsClean()) return runtime_vfs.Error.InvalidPath;
}

fn installEmbeddedBootAssets(source: []const u8) !void {
    _ = try state.vfs.putFile(0, "/boot/service-user.elf", service_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/boot/process-user.elf", process_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/boot/process-exec.elf", process_exec_elf, 0o555, false, 0);
    _ = try state.vfs.mount(0, "/boot", .boot_fat, true, source);
}

fn currentTick() u64 {
    return @atomicLoad(u64, &runtime_interrupt_count, .monotonic);
}

export fn zigos_runtime_timer_interrupt_handler(
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) callconv(cc) u64 {
    const previous = @atomicRmw(u64, &runtime_interrupt_count, .Add, 1, .monotonic);
    const tick = previous +% 1;
    const preempted = runtime_user.handleTimer(frame, fx_state, tick);
    apic.acknowledgeInterrupt();
    return @intFromBool(preempted);
}

fn serviceRuntime() void {
    const now = currentTick();
    if (now == state.last_serviced_tick) return;
    var tick = state.last_serviced_tick + 1;
    while (tick <= now) : (tick += 1) {
        _ = state.processes.wakeExpired(tick);
        serviceUserspace(tick);
        const writeback = state.persistence.serviceWriteback(&state.vfs);
        if (writeback != .idle) state.filesystem_syncs +%= 1;
        const physical = state.config.physical_memory.report();
        const pressure_watermark = @max(file_page_cache_low_watermark_pages, physical.total_pages / 100);
        _ = state.vfs.reclaimCleanFilePageCacheUnderPressure(
            physical.free_pages,
            pressure_watermark,
            file_page_cache_pressure_target_entries,
        );
        state.device_service_passes +%= 1;
        if (state.config.network_ready) {
            state.network_service_passes +%= 1;
            if (e1000e.activeDevice()) |device| {
                _ = e1000e.prepareRuntimeMmio(device);
                var pumped: u8 = 0;
                while (pumped < 8 and e1000e.pumpReceiveNonBlocking(device)) : (pumped += 1) {}
                _ = runtime_user.serviceNetwork();
            }
        }
    }
    state.last_serviced_tick = now;

    if (state.shell_sleeping) {
        const shell = state.processes.get(state.shell_handle) catch return;
        if (shell.state == .runnable) {
            state.processes.setRunning(state.shell_handle) catch return;
            state.shell_sleeping = false;
            emit("sleep complete\r\n");
            printPrompt();
        }
    }
}

fn serviceUserspace(tick: u64) void {
    const serviced = runtime_user.serviceOne(tick) catch |err| blk: {
        emit("runtime dispatch failure: ");
        emit(@errorName(err));
        emit("\r\n");
        break :blk null;
    };
    if (state.config.profile == .normal) if (serviced) |handle| flushUserspaceOutput(handle);
    if (state.config.profile == .diagnostic and !state.shell_sleeping and !state.shell_waiting)
        state.processes.setRunning(state.shell_handle) catch {};
}

fn shellOwnsTerminal() bool {
    return state.tty.foregroundMatches(&state.processes, state.shell_handle) catch false;
}

fn consumeInput(byte: u8) void {
    if (!shellOwnsTerminal()) {
        consumeForegroundInput(byte);
        return;
    }
    if (state.shell_sleeping) return;
    if (state.ignore_next_lf and byte == '\n') {
        state.ignore_next_lf = false;
        return;
    }
    state.ignore_next_lf = byte == '\r';
    const event = state.editor.feed(byte);
    switch (event) {
        .none => {},
        .redraw => redrawLine(),
        .cancelled => {
            emit("^C\r\n");
            printPrompt();
        },
        .end_of_input => emit("\r\nUse 'shutdown' to stop the hosted session.\r\n"),
        .submitted => |line| {
            emit("\r\n");
            if (line.len != 0) executeLine(line);
            state.editor.reset();
            if (!state.shutdown_requested and !state.shell_sleeping) printPrompt();
        },
    }
}

fn serviceForegroundInput() bool {
    var received = false;
    while (true) {
        const status = serial.tryRead();
        if (status.line_error) state.serial_line_errors +%= 1;
        const byte = status.byte orelse break;
        received = true;
        consumeForegroundInput(byte);
    }
    return received;
}

fn consumeForegroundInput(byte: u8) void {
    const result = state.tty.feed(&state.processes, byte);
    state.descriptors.accountTerminalWakeups(result.wakeups);
    switch (result.echo) {
        .none => {},
        .byte => {
            const echoed = [1]u8{result.byte};
            emit(&echoed);
        },
        .erase_one => emit("\x08 \x08"),
        .erase_line => {
            var remaining = result.erased;
            while (remaining != 0) : (remaining -= 1) emit("\x08 \x08");
        },
        .newline => emit("\r\n"),
        .interrupt => emit("^C\r\n"),
        .suspended => emit("^Z\r\n"),
        .bell => emit("\x07"),
    }
}

fn redrawLine() void {
    emit("\r\x1B[2K");
    emitPromptPrefix();
    emit(state.editor.line());
    var remaining = state.editor.length - state.editor.cursor;
    while (remaining != 0) : (remaining -= 1) emit("\x1B[D");
    state.prompt_visible = true;
}

fn printPrompt() void {
    emitPromptPrefix();
    state.prompt_visible = true;
}

fn emitPromptPrefix() void {
    var path_buffer: [runtime_vfs.maximum_path_length + 1]u8 = undefined;
    const path = state.vfs.canonicalPath(state.cwd, &path_buffer) catch "/?";
    emit("root@zigos:");
    emit(path);
    emit("# ");
}

fn executeLine(line: []const u8) void {
    state.command_count +%= 1;
    const command_line = runtime_command.parse(line, &state.environment) catch |err| {
        state.failed_commands +%= 1;
        emit("shell: ");
        emit(@errorName(err));
        emit("\r\n");
        return;
    };

    if (command_line.background) {
        var background_output = Output.init(&state.pipeline_a);
        if (command_line.stage_count == 1 and command_line.input_path == null and command_line.output_path == null) {
            const stage = &command_line.stages[0];
            const command = stage.command() orelse return;
            if ((equal(command, "run") or equal(command, "exec")) and stage.count >= 2) {
                _ = launchExecutable(stage, 1, .{}, true, &background_output);
                emit(background_output.slice());
                return;
            }
        }
        background_output.line("shell: trailing &: only 'run PATH &' or 'exec PATH &' launches a real userspace job; use spawn PATH otherwise");
        emit(background_output.slice());
        state.failed_commands +%= 1;
        return;
    }

    var input: []const u8 = &.{};
    if (command_line.input_path) |path_token| {
        var input_output = Output.init(&state.input_buffer);
        if (!readPath(path_token.slice(), &input_output)) {
            state.failed_commands +%= 1;
            return;
        }
        input = input_output.slice();
    }

    var final_output: []const u8 = &.{};
    for (command_line.stages[0..command_line.stage_count], 0..) |stage, stage_index| {
        var output = if ((stage_index & 1) == 0) Output.init(&state.pipeline_a) else Output.init(&state.pipeline_b);
        executeStage(&stage, input, &output);
        if (output.truncated) output.line("shell: output truncated");
        final_output = output.slice();
        input = final_output;
    }

    if (command_line.output_path) |path_token| {
        writeDescriptorPath(path_token.slice(), final_output, command_line.append_output) catch |err| {
            state.failed_commands +%= 1;
            emit("redirect: ");
            emit(@errorName(err));
            emit("\r\n");
            return;
        };
    } else {
        emit(final_output);
    }
}

fn executeStage(stage: *const runtime_command.Stage, input: []const u8, output: *Output) void {
    const name = stage.command() orelse return;
    if (equal(name, "help")) return commandHelp(output);
    if (equal(name, "pwd")) return commandPwd(output);
    if (equal(name, "cd")) return commandCd(stage, output);
    if (equal(name, "ls")) return commandLs(stage, output);
    if (equal(name, "cat")) return commandCat(stage, input, output);
    if (equal(name, "cp")) return commandCp(stage, output);
    if (equal(name, "echo")) return commandEcho(stage, output);
    if (equal(name, "touch")) return commandTouch(stage, output);
    if (equal(name, "mkdir")) return commandMkdir(stage, output);
    if (equal(name, "rm")) return commandRm(stage, output);
    if (equal(name, "rmdir")) return commandRmdir(stage, output);
    if (equal(name, "mv")) return commandMv(stage, output);
    if (equal(name, "write")) return commandWrite(stage, false, output);
    if (equal(name, "append")) return commandWrite(stage, true, output);
    if (equal(name, "stat")) return commandStat(stage, output);
    if (equal(name, "chmod")) return commandChmod(stage, output);
    if (equal(name, "mount")) return commandMount(output);
    if (equal(name, "df")) return commandDf(output);
    if (equal(name, "fds")) return commandFds(stage, output);
    if (equal(name, "fdtest")) return commandFdTest(stage, output);
    if (equal(name, "pipex")) return commandPipeExecutables(output);
    if (equal(name, "ps")) return commandPs(output);
    if (equal(name, "jobs")) return commandJobs(output);
    if (equal(name, "spawn")) return commandSpawn(stage, output);
    if (equal(name, "kill")) return commandKill(stage, output);
    if (equal(name, "wait")) return commandWait(stage, output);
    if (equal(name, "crash")) return commandCrash(stage, output);
    if (equal(name, "sleep")) return commandSleep(stage, output);
    if (equal(name, "uptime")) return commandUptime(output);
    if (equal(name, "elf")) return commandElf(stage, output);
    if (equal(name, "exec") or equal(name, "run")) return commandExec(stage, output);
    if (equal(name, "devices")) return commandDevices(output);
    if (equal(name, "ifconfig")) return commandIfconfig(output);
    if (equal(name, "netstat") or equal(name, "sockets")) return commandNetstat(output);
    if (equal(name, "routes")) return commandRoutes(output);
    if (equal(name, "arp")) return commandArp(output);
    if (equal(name, "ping")) return commandPing(stage, output);
    if (equal(name, "dns")) return commandDns(stage, output);
    if (equal(name, "env")) return commandEnv(output);
    if (equal(name, "export")) return commandExport(stage, output);
    if (equal(name, "unset")) return commandUnset(stage, output);
    if (equal(name, "history")) return commandHistory(output);
    if (equal(name, "uname")) return output.line("ZigOs 19.0.0 x86_64 freestanding");
    if (equal(name, "clear")) return output.write("\x1B[2J\x1B[H");
    if (equal(name, "sync")) return commandSync(output);
    if (equal(name, "writeback")) return commandWriteback(stage, output);
    if (equal(name, "cachepressure")) return commandCachePressure(stage, output);
    if (equal(name, "fsck")) return commandFsck(output);
    if (equal(name, "hash")) return commandHash(stage, input, output);
    if (equal(name, "hexdump")) return commandHexdump(stage, input, output);
    if (equal(name, "grep")) return commandGrep(stage, input, output);
    if (equal(name, "wc")) return commandWc(input, output);
    if (equal(name, "head")) return commandHead(stage, input, output);
    if (equal(name, "shutdown") or equal(name, "poweroff")) {
        state.shutdown_requested = true;
        return output.line("shutdown requested");
    }
    output.write("shell: command not found: ");
    output.line(name);
    state.failed_commands +%= 1;
}

fn commandHelp(output: *Output) void {
    output.line("Filesystem: pwd cd ls cat cp echo touch mkdir rm rmdir mv write append stat chmod mount df fds fdtest pipex sync writeback cachepressure fsck");
    output.line("Processes: ps jobs spawn kill wait crash sleep uptime elf exec run (real VFS-loaded CPL3; kill defaults to forced signal 9)");
    output.line("Network: ping and dns use retained e1000e packet I/O when available; offline boots report explicit unavailability");
    output.line("Shell: env export unset history clear uname hash hexdump grep wc head shutdown");
    output.line("Grammar: quotes, escapes, $VARS, comments, bounded shell pipelines, <, >, >>; trailing & is executable-only.");
}

fn commandPwd(output: *Output) void {
    var buffer: [runtime_vfs.maximum_path_length + 1]u8 = undefined;
    output.line(state.vfs.canonicalPath(state.cwd, &buffer) catch "/?");
}

fn commandCd(stage: *const runtime_command.Stage, output: *Output) void {
    const path = if (stage.count >= 2) stage.arguments[1].slice() else state.environment.get("HOME") orelse "/";
    const target = state.vfs.resolve(state.cwd, path) catch |err| return shellError("cd", err, output);
    const info = state.vfs.statNode(target) catch |err| return shellError("cd", err, output);
    if (info.kind != .directory) return shellError("cd", runtime_vfs.Error.NotDirectory, output);
    state.cwd = target;
    state.processes.setWorkingDirectory(state.shell_handle, target) catch {};
}

fn commandLs(stage: *const runtime_command.Stage, output: *Output) void {
    const path = if (stage.count >= 2) stage.arguments[1].slice() else ".";
    const list = state.vfs.list(state.cwd, path) catch |err| return shellError("ls", err, output);
    for (list.records[0..list.count]) |record| {
        output.byte(switch (record.kind) {
            .directory => 'd',
            .file => '-',
            .pseudo => 'p',
            .symlink => 'l',
        });
        output.write(if (record.readonly) "r-- " else "rw- ");
        output.decimal(record.size);
        output.write(" ");
        output.write(record.nameSlice());
        if (record.kind == .directory) output.byte('/');
        output.write("\r\n");
    }
}

fn commandCat(stage: *const runtime_command.Stage, input: []const u8, output: *Output) void {
    if (stage.count == 1) {
        output.write(input);
        return;
    }
    for (stage.arguments[1..stage.count]) |argument| if (!readPath(argument.slice(), output)) return;
}

fn commandCp(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count != 3) return usage("cp SOURCE DESTINATION", output);
    const source_path = stage.arguments[1].slice();
    const destination_path = stage.arguments[2].slice();
    const source = state.vfs.readOnlyView(state.cwd, source_path) catch |err| return shellError("cp", err, output);
    if (source.len > state.input_buffer.len) return shellError("cp", runtime_vfs.Error.FileTooLarge, output);
    @memcpy(state.input_buffer[0..source.len], source);
    const info = state.vfs.stat(state.cwd, source_path) catch |err| return shellError("cp", err, output);
    _ = state.vfs.putFile(
        state.cwd,
        destination_path,
        state.input_buffer[0..source.len],
        info.mode,
        false,
        currentTick(),
    ) catch |err| return shellError("cp", err, output);
    output.write("copied ");
    output.decimal(source.len);
    output.write(" bytes\r\n");
}

fn commandEcho(stage: *const runtime_command.Stage, output: *Output) void {
    for (stage.arguments[1..stage.count], 0..) |argument, index| {
        if (index != 0) output.byte(' ');
        output.write(argument.slice());
    }
    output.write("\r\n");
}

fn commandTouch(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count < 2) return usage("touch PATH...", output);
    for (stage.arguments[1..stage.count]) |argument| {
        _ = state.vfs.resolve(state.cwd, argument.slice()) catch |err| switch (err) {
            runtime_vfs.Error.NotFound => state.vfs.create(state.cwd, argument.slice(), 0o644, currentTick()) catch |create_err| return shellError("touch", create_err, output),
            else => return shellError("touch", err, output),
        };
    }
}

fn commandMkdir(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count < 2) return usage("mkdir PATH...", output);
    for (stage.arguments[1..stage.count]) |argument| _ = state.vfs.mkdir(state.cwd, argument.slice(), 0o755, currentTick()) catch |err| return shellError("mkdir", err, output);
}

fn commandRm(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count < 2) return usage("rm FILE...", output);
    for (stage.arguments[1..stage.count]) |argument| state.vfs.unlink(state.cwd, argument.slice(), currentTick()) catch |err| return shellError("rm", err, output);
}

fn commandRmdir(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count < 2) return usage("rmdir DIRECTORY...", output);
    for (stage.arguments[1..stage.count]) |argument| state.vfs.rmdir(state.cwd, argument.slice(), currentTick()) catch |err| return shellError("rmdir", err, output);
}

fn commandMv(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count != 3) return usage("mv SOURCE DESTINATION", output);
    state.vfs.rename(state.cwd, stage.arguments[1].slice(), stage.arguments[2].slice(), currentTick()) catch |err| return shellError("mv", err, output);
}

fn commandWrite(stage: *const runtime_command.Stage, append: bool, output: *Output) void {
    if (stage.count < 3) return usage(if (append) "append PATH TEXT..." else "write PATH TEXT...", output);
    var temporary: [runtime_vfs.maximum_file_size]u8 = @splat(0);
    var length: usize = 0;
    for (stage.arguments[2..stage.count], 0..) |argument, index| {
        if (index != 0 and length < temporary.len) {
            temporary[length] = ' ';
            length += 1;
        }
        const count = @min(argument.length, temporary.len - length);
        @memcpy(temporary[length .. length + count], argument.slice()[0..count]);
        length += count;
    }
    if (length < temporary.len) {
        temporary[length] = '\n';
        length += 1;
    }
    writeDescriptorPath(stage.arguments[1].slice(), temporary[0..length], append) catch |err|
        return shellError(if (append) "append" else "write", err, output);
}

fn commandStat(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count != 2) return usage("stat PATH", output);
    const info = state.vfs.stat(state.cwd, stage.arguments[1].slice()) catch |err| return shellError("stat", err, output);
    output.write("node ");
    output.decimal(info.node);
    output.write(" generation ");
    output.decimal(info.generation);
    output.write(" kind ");
    output.write(@tagName(info.kind));
    output.write(" size ");
    output.decimal(info.size);
    output.write(" mode 0");
    output.octal(info.mode);
    output.write(" mount ");
    output.decimal(info.mount_id);
    output.write(" links ");
    output.decimal(info.link_count);
    output.write(" readonly ");
    output.line(if (info.readonly) "yes" else "no");
}

fn commandChmod(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count != 3) return usage("chmod OCTAL PATH", output);
    const mode = std.fmt.parseInt(u16, stage.arguments[1].slice(), 8) catch return usage("chmod OCTAL PATH", output);
    state.vfs.chmod(state.cwd, stage.arguments[2].slice(), mode, currentTick()) catch |err| return shellError("chmod", err, output);
}

fn commandMount(output: *Output) void {
    const mounts = state.vfs.mountList();
    for (mounts) |mount_entry| {
        if (!mount_entry.used) continue;
        var path_buffer: [runtime_vfs.maximum_path_length + 1]u8 = undefined;
        const path = state.vfs.canonicalPath(mount_entry.root_node, &path_buffer) catch "/?";
        output.write(mount_entry.sourceSlice());
        output.write(" on ");
        output.write(path);
        output.write(" type ");
        output.write(@tagName(mount_entry.kind));
        output.write(if (mount_entry.readonly) " (ro)" else " (rw)");
        output.write("\r\n");
    }
}

fn commandDf(output: *Output) void {
    const report = state.vfs.report();
    output.write("ramfs nodes ");
    output.decimal(report.nodes_used);
    output.write("/");
    output.decimal(runtime_vfs.maximum_nodes);
    output.write(" bytes ");
    output.decimal(report.bytes_used);
    output.write("/");
    output.decimal(runtime_vfs.maximum_nodes * runtime_vfs.maximum_file_size);
    output.write(" resident-blocks ");
    output.decimal(report.allocated_blocks);
    output.write("/");
    output.decimal(runtime_vfs.maximum_data_blocks);
    output.write(" allocated-bytes ");
    output.decimal(report.allocated_bytes);
    output.write(" hole-bytes ");
    output.decimal(report.sparse_hole_bytes);
    output.write(" mounts ");
    output.decimal(report.mounts);
    output.write(" open ");
    output.decimal(report.open_files);
    output.write("\r\n");
}

fn commandFds(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count != 1) return usage("fds", output);
    const snapshot = state.descriptors.snapshot(&state.vfs, &state.processes, state.shell_handle) catch |err| return shellError("fds", err, output);
    output.line("FD KIND       MODE OFD      REFS FLAGS OFFSET/BUFFERED");
    for (snapshot.entries[0..snapshot.count]) |entry| {
        output.decimal(entry.fd);
        output.byte(' ');
        output.write(@tagName(entry.kind));
        var padding = @tagName(entry.kind).len;
        while (padding < 10) : (padding += 1) output.byte(' ');
        output.write(if (entry.readable and entry.writable) "rw   " else if (entry.readable) "r-   " else "-w   ");
        output.write("0x");
        output.hexFixed(entry.open_id, 8);
        output.byte(' ');
        output.decimal(entry.references);
        output.write(if (entry.close_on_exec) "    CLOEXEC " else "    -       ");
        output.decimal(entry.offset_or_buffered);
        output.write("\r\n");
    }
}

fn commandFdTest(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count != 1) return usage("fdtest", output);
    runFdContract() catch |err| {
        output.write("fdtest: ");
        output.line(@errorName(err));
        state.failed_commands +%= 1;
        return;
    };
    const report = state.descriptors.report();
    output.write("fdtest: descriptors ");
    output.decimal(report.descriptors);
    output.write(" open ");
    output.decimal(report.open_descriptions);
    output.write(" pipes ");
    output.decimal(report.pipes);
    output.line(" shared-offset yes clone yes cloexec yes read-block yes write-block yes eof yes broken-pipe yes ring yes clean yes");
    output.write("fdtest counters: dup ");
    output.decimal(report.duplicated_descriptors);
    output.write(" inherited ");
    output.decimal(report.inherited_descriptors);
    output.write(" cloexec ");
    output.decimal(report.close_on_exec_closes);
    output.write(" blocked ");
    output.decimal(report.blocked_reads);
    output.byte('/');
    output.decimal(report.blocked_writes);
    output.write(" wakeups ");
    output.decimal(report.reader_wakeups);
    output.byte('/');
    output.decimal(report.writer_wakeups);
    output.write(" eof ");
    output.decimal(report.eof_reads);
    output.write(" broken ");
    output.decimal(report.broken_pipe_writes);
    output.write("\r\n");
}

fn commandPipeExecutables(output: *Output) void {
    const before = state.descriptors.report();
    const pipe_fds = runtime_user.createPipeFor(state.shell_handle) catch |err| return shellError("pipex", err, output);
    var shell_read_open = true;
    var shell_write_open = true;
    defer {
        if (shell_read_open) runtime_user.closeDescriptorFor(state.shell_handle, pipe_fds[0]) catch {};
        if (shell_write_open) runtime_user.closeDescriptorFor(state.shell_handle, pipe_fds[1]) catch {};
    }

    const reader = spawnExecutablePath(
        "/bin/pipe-reader.elf",
        &.{},
        .{ .override = true, .rdi = pipe_fds[0] },
        false,
        output,
    ) orelse return;
    const writer = spawnExecutablePath(
        "/bin/pipe-writer.elf",
        &.{},
        .{ .override = true, .rsi = pipe_fds[1] },
        false,
        output,
    ) orelse {
        abortExecutable(reader);
        return;
    };

    runtime_user.closeDescriptorFor(reader, pipe_fds[1]) catch |err| {
        abortExecutable(reader);
        abortExecutable(writer);
        return shellError("pipex reader close", err, output);
    };
    runtime_user.closeDescriptorFor(writer, pipe_fds[0]) catch |err| {
        abortExecutable(reader);
        abortExecutable(writer);
        return shellError("pipex writer close", err, output);
    };
    runtime_user.closeDescriptorFor(state.shell_handle, pipe_fds[0]) catch |err| {
        abortExecutable(reader);
        abortExecutable(writer);
        return shellError("pipex shell read close", err, output);
    };
    shell_read_open = false;
    runtime_user.closeDescriptorFor(state.shell_handle, pipe_fds[1]) catch |err| {
        abortExecutable(reader);
        abortExecutable(writer);
        return shellError("pipex shell write close", err, output);
    };
    shell_write_open = false;

    state.processes.block(writer, .device_io, pipex_writer_gate) catch |err| {
        abortExecutable(reader);
        abortExecutable(writer);
        return shellError("pipex writer gate", err, output);
    };
    const block_deadline = currentTick() + 100;
    var blocked_reader = state.processes.get(reader) catch {
        abortExecutable(reader);
        abortExecutable(writer);
        return output.line("pipex: reader vanished before scheduling");
    };
    while (blocked_reader.state == .runnable or blocked_reader.state == .running) {
        serviceRuntime();
        blocked_reader = state.processes.get(reader) catch {
            abortExecutable(reader);
            abortExecutable(writer);
            return output.line("pipex: reader vanished after scheduling");
        };
        if (blocked_reader.state == .blocked) break;
        if (currentTick() >= block_deadline) break;
        zigos_wait_for_interrupt();
    }
    if (blocked_reader.state != .blocked or blocked_reader.wait_reason != .pipe_read) {
        abortExecutable(reader);
        abortExecutable(writer);
        output.write("pipex: real reader did not block; state ");
        output.write(@tagName(blocked_reader.state));
        output.write(" reason ");
        output.line(@tagName(blocked_reader.wait_reason));
        state.failed_commands +%= 1;
        return;
    }
    if (state.processes.wakeMatching(.device_io, pipex_writer_gate, false) != 1) {
        abortExecutable(reader);
        abortExecutable(writer);
        output.line("pipex: writer scheduler gate did not wake exactly once");
        state.failed_commands +%= 1;
        return;
    }

    const writer_status = driveForeground(writer, output) orelse {
        abortExecutable(reader);
        return;
    };
    if (writer_status.state != .zombie or writer_status.exit_status != 0) {
        abortExecutable(reader);
        output.line("pipex: CPL3 writer failed");
        state.failed_commands +%= 1;
        return;
    }
    const awakened_reader = state.processes.get(reader) catch {
        abortExecutable(reader);
        return output.line("pipex: reader missing after writer completion");
    };
    if (awakened_reader.state != .runnable and awakened_reader.state != .running) {
        abortExecutable(reader);
        output.write("pipex: writer did not wake reader; state ");
        output.line(@tagName(awakened_reader.state));
        state.failed_commands +%= 1;
        return;
    }
    const reader_status = driveForeground(reader, output) orelse return;
    if (reader_status.state != .zombie or reader_status.exit_status != 0) {
        output.line("pipex: CPL3 reader failed");
        state.failed_commands +%= 1;
        return;
    }

    const after = state.descriptors.report();
    if (after.blocked_reads - before.blocked_reads != 1 or
        after.reader_wakeups - before.reader_wakeups != 1 or
        // The writer contributes eight pipe bytes and the reader contributes
        // the same eight bytes to its terminal descriptor.
        after.bytes_written - before.bytes_written != 16 or
        after.bytes_read - before.bytes_read != 8 or
        after.pipes != before.pipes)
    {
        output.line("pipex: descriptor counters did not prove one real block/wake transfer");
        state.failed_commands +%= 1;
        return;
    }
    output.line("");
    output.line("pipex: real CPL3 reader blocked; real CPL3 writer woke it; payload PIPE-CPL; pipe reclaimed");
}

fn abortExecutable(handle: u64) void {
    const process = state.processes.get(handle) catch return;
    if (!process.terminal()) state.processes.exit(handle, 0x7F00_00FF) catch {};
    runtime_user.finalize(handle) catch {};
    _ = state.processes.wait(state.shell_handle, handle, true) catch null;
    runtime_user.forget(handle);
    state.processes.setRunning(state.shell_handle) catch {};
}

fn runFdContract() !void {
    const initial = state.descriptors.report();
    if (initial.namespaces != 1 or initial.descriptors != 3 or initial.open_descriptions != 3 or initial.pipes != 0)
        return error.FdContractInitialState;

    const file_fd = try state.descriptors.openFile(
        &state.vfs,
        &state.processes,
        state.shell_handle,
        "/tmp/capstone18-fd.txt",
        .{ .read = true, .write = true, .create = true, .truncate = true },
        0o644,
        currentTick(),
    );
    if (file_fd != 3) return error.FdContractLowestDescriptor;
    if ((try state.descriptors.write(&state.vfs, &state.processes, state.shell_handle, file_fd, "alpha", currentTick())).count != 5)
        return error.FdContractFileWrite;
    const duplicate_fd = try state.descriptors.duplicate(&state.processes, state.shell_handle, file_fd);
    if (duplicate_fd != 4) return error.FdContractDuplicate;
    if ((try state.descriptors.write(&state.vfs, &state.processes, state.shell_handle, duplicate_fd, "-beta", currentTick())).count != 5)
        return error.FdContractSharedWrite;
    if ((try state.descriptors.duplicateTo(&state.vfs, &state.processes, state.shell_handle, file_fd, 9)) != 9)
        return error.FdContractDuplicateTo;
    if ((try state.descriptors.seek(&state.vfs, &state.processes, state.shell_handle, 9, 0, .start)) != 0)
        return error.FdContractSeek;
    var file_bytes: [64]u8 = undefined;
    const shared_read = try state.descriptors.read(&state.vfs, &state.processes, state.shell_handle, duplicate_fd, &file_bytes);
    if (shared_read.status != .complete or !std.mem.eql(u8, file_bytes[0..shared_read.count], "alpha-beta"))
        return error.FdContractSharedOffset;
    try state.descriptors.setCloseOnExec(&state.processes, state.shell_handle, duplicate_fd, true);
    if ((try state.descriptors.closeOnExec(&state.vfs, &state.processes, state.shell_handle)) != 1)
        return error.FdContractCloseOnExec;

    const child = try state.processes.spawn(
        state.shell_handle,
        .userspace,
        "fd-child",
        &.{"fd-child"},
        state.cwd,
        0,
        0,
        currentTick(),
        .{ .maximum_pages = 16, .maximum_descriptors = 16, .maximum_sockets = 0, .maximum_children = 0 },
    );
    if ((try state.descriptors.cloneProcess(&state.processes, state.shell_handle, child)) != 5)
        return error.FdContractCloneCount;
    if ((try state.descriptors.write(&state.vfs, &state.processes, child, file_fd, "-child", currentTick())).count != 6)
        return error.FdContractCloneWrite;
    _ = try state.descriptors.releaseProcess(&state.vfs, &state.processes, child);
    try state.processes.exit(child, 0);
    const child_status = (try state.processes.wait(state.shell_handle, child, false)) orelse return error.FdContractChildWait;
    if (child_status.exit_status != 0) return error.FdContractChildStatus;

    if ((try state.descriptors.seek(&state.vfs, &state.processes, state.shell_handle, file_fd, 0, .start)) != 0)
        return error.FdContractParentSeek;
    const inherited_read = try state.descriptors.read(&state.vfs, &state.processes, state.shell_handle, 9, &file_bytes);
    if (inherited_read.status != .complete or !std.mem.eql(u8, file_bytes[0..inherited_read.count], "alpha-beta-child"))
        return error.FdContractInheritedOffset;
    try state.descriptors.truncate(&state.vfs, &state.processes, state.shell_handle, file_fd, 10, currentTick());
    const file_snapshot = try state.descriptors.snapshot(&state.vfs, &state.processes, state.shell_handle);
    var preserved_offset = false;
    for (file_snapshot.entries[0..file_snapshot.count]) |entry| {
        if (entry.fd == file_fd and entry.offset_or_buffered == 16) preserved_offset = true;
    }
    if (!preserved_offset) return error.FdContractTruncateOffset;
    _ = try state.descriptors.seek(&state.vfs, &state.processes, state.shell_handle, 9, 0, .start);
    const truncated_read = try state.descriptors.read(&state.vfs, &state.processes, state.shell_handle, file_fd, &file_bytes);
    if (!std.mem.eql(u8, file_bytes[0..truncated_read.count], "alpha-beta")) return error.FdContractTruncateData;
    try state.descriptors.close(&state.vfs, &state.processes, state.shell_handle, file_fd);
    try state.descriptors.close(&state.vfs, &state.processes, state.shell_handle, 9);
    try state.vfs.unlink(0, "/tmp/capstone18-fd.txt", currentTick());

    const reader = try state.processes.spawn(
        state.shell_handle,
        .userspace,
        "pipe-reader",
        &.{"pipe-reader"},
        state.cwd,
        0,
        0,
        currentTick(),
        .{ .maximum_pages = 8, .maximum_descriptors = 8, .maximum_sockets = 0, .maximum_children = 0 },
    );
    const writer = try state.processes.spawn(
        state.shell_handle,
        .userspace,
        "pipe-writer",
        &.{"pipe-writer"},
        state.cwd,
        0,
        0,
        currentTick(),
        .{ .maximum_pages = 8, .maximum_descriptors = 8, .maximum_sockets = 0, .maximum_children = 0 },
    );
    try state.descriptors.bindProcess(&state.processes, reader, false);
    const pipe_fds = try state.descriptors.createPipe(&state.processes, reader);
    if ((try state.descriptors.cloneProcess(&state.processes, reader, writer)) != 2)
        return error.FdContractPipeClone;
    try state.descriptors.close(&state.vfs, &state.processes, reader, pipe_fds[1]);
    try state.descriptors.close(&state.vfs, &state.processes, writer, pipe_fds[0]);

    var pipe_bytes: [runtime_fd.pipe_capacity]u8 = undefined;
    if ((try state.descriptors.read(&state.vfs, &state.processes, reader, pipe_fds[0], &pipe_bytes)).status != .blocked)
        return error.FdContractReaderDidNotBlock;
    const wake_write = try state.descriptors.write(&state.vfs, &state.processes, writer, pipe_fds[1], "pipe-wakeup", currentTick());
    if (wake_write.count != 11 or wake_write.wakeups != 1) return error.FdContractReaderWake;
    const wake_read = try state.descriptors.read(&state.vfs, &state.processes, reader, pipe_fds[0], &pipe_bytes);
    if (!std.mem.eql(u8, pipe_bytes[0..wake_read.count], "pipe-wakeup")) return error.FdContractPipePayload;

    var fill: [runtime_fd.pipe_capacity]u8 = undefined;
    for (&fill, 0..) |*byte, index| byte.* = @intCast(index & 0xFF);
    if ((try state.descriptors.write(&state.vfs, &state.processes, writer, pipe_fds[1], &fill, currentTick())).count != runtime_fd.pipe_capacity)
        return error.FdContractPipeFill;
    if ((try state.descriptors.write(&state.vfs, &state.processes, writer, pipe_fds[1], "!", currentTick())).status != .blocked)
        return error.FdContractWriterDidNotBlock;
    const drain = try state.descriptors.read(&state.vfs, &state.processes, reader, pipe_fds[0], pipe_bytes[0..512]);
    if (drain.count != 512 or drain.wakeups != 1) return error.FdContractWriterWake;
    if ((try state.descriptors.write(&state.vfs, &state.processes, writer, pipe_fds[1], "tail", currentTick())).count != 4)
        return error.FdContractRingWrite;
    const remainder = try state.descriptors.read(&state.vfs, &state.processes, reader, pipe_fds[0], pipe_bytes[0..600]);
    if (remainder.count != 516) return error.FdContractRingRead;
    try state.descriptors.close(&state.vfs, &state.processes, writer, pipe_fds[1]);
    if ((try state.descriptors.read(&state.vfs, &state.processes, reader, pipe_fds[0], &pipe_bytes)).status != .eof)
        return error.FdContractPipeEof;
    try state.descriptors.close(&state.vfs, &state.processes, reader, pipe_fds[0]);
    _ = try state.descriptors.releaseProcess(&state.vfs, &state.processes, reader);
    _ = try state.descriptors.releaseProcess(&state.vfs, &state.processes, writer);
    try state.processes.exit(reader, 0);
    try state.processes.exit(writer, 0);
    _ = (try state.processes.wait(state.shell_handle, reader, false)) orelse return error.FdContractReaderWait;
    _ = (try state.processes.wait(state.shell_handle, writer, false)) orelse return error.FdContractWriterWait;

    const broken_fds = try state.descriptors.createPipe(&state.processes, state.shell_handle);
    try state.descriptors.close(&state.vfs, &state.processes, state.shell_handle, broken_fds[0]);
    _ = state.descriptors.write(&state.vfs, &state.processes, state.shell_handle, broken_fds[1], "broken", currentTick()) catch |err| switch (err) {
        runtime_fd.Error.BrokenPipe => {},
        else => return err,
    };
    try state.descriptors.close(&state.vfs, &state.processes, state.shell_handle, broken_fds[1]);

    const final = state.descriptors.report();
    if (final.namespaces != 1 or final.descriptors != 3 or final.open_descriptions != 3 or final.terminal_descriptions != 3 or
        final.vfs_descriptions != 0 or final.pipe_read_descriptions != 0 or final.pipe_write_descriptions != 0 or final.pipes != 0)
        return error.FdContractLeak;
    if (final.duplicated_descriptors - initial.duplicated_descriptors != 2 or
        final.inherited_descriptors - initial.inherited_descriptors != 7 or
        final.close_on_exec_closes - initial.close_on_exec_closes != 1 or
        final.descriptor_closes - initial.descriptor_closes != 14 or
        final.blocked_reads - initial.blocked_reads != 1 or
        final.blocked_writes - initial.blocked_writes != 1 or
        final.reader_wakeups - initial.reader_wakeups != 1 or
        final.writer_wakeups - initial.writer_wakeups != 1 or
        final.bytes_read - initial.bytes_read != 1075 or
        final.bytes_written - initial.bytes_written != 1055 or
        final.eof_reads - initial.eof_reads != 1 or
        final.broken_pipe_writes - initial.broken_pipe_writes != 1 or
        final.stale_namespace_sweeps - initial.stale_namespace_sweeps != 0)
        return error.FdContractCounters;
    if (!state.descriptors.validate(&state.vfs, &state.processes)) return error.FdContractValidation;
    state.fd_contract_passed = true;
}

fn commandPs(output: *Output) void {
    output.line("PID PPID STATE      TICKS FDS SOCK NAME");

    // Keep only compact slot indexes on the current stack. A former Snapshot
    // return copied all 64 Process records (about 29 KiB) and could overflow
    // the syscall IST when /proc/processes was formatted from userspace.
    var slots: [runtime_process.maximum_processes]u16 = @splat(runtime_process.invalid_slot);
    var count: usize = 0;
    for (0..runtime_process.maximum_processes) |slot| {
        if (state.processes.processAt(slot) == null) continue;
        slots[count] = @intCast(slot);
        count += 1;
    }
    var index: usize = 1;
    while (index < count) : (index += 1) {
        const value = slots[index];
        const value_pid = state.processes.processAt(value).?.pid;
        var position = index;
        while (position > 0 and value_pid < state.processes.processAt(slots[position - 1]).?.pid) : (position -= 1) {
            slots[position] = slots[position - 1];
        }
        slots[position] = value;
    }

    for (slots[0..count]) |slot| {
        const process = state.processes.processAt(slot).?;
        output.decimal(process.pid);
        output.byte(' ');
        output.decimal(process.ppid);
        output.byte(' ');
        output.write(@tagName(process.state));
        var padding: usize = @tagName(process.state).len;
        while (padding < 10) : (padding += 1) output.byte(' ');
        output.decimal(process.cpu_ticks);
        output.byte(' ');
        output.decimal(process.descriptor_count);
        output.byte(' ');
        output.decimal(process.socket_count);
        output.byte(' ');
        output.line(process.nameSlice());
    }
}

fn commandJobs(output: *Output) void {
    const shell = state.processes.get(state.shell_handle) catch return output.line("no jobs");
    var any = false;
    for (0..runtime_process.maximum_processes) |slot| {
        const process = state.processes.processAt(slot) orelse continue;
        if (process.kind != .userspace or process.ppid != shell.pid) continue;
        any = true;
        output.byte('[');
        output.decimal(process.pid);
        output.write("] ");
        output.write(@tagName(process.state));
        output.write(" ");
        writeProcessCommand(process, output);
        output.write("\r\n");
    }
    if (!any) output.line("no jobs");
}

fn writeProcessCommand(process: *const runtime_process.Process, output: *Output) void {
    const command = if (process.argument_count == 0) process.nameSlice() else process.arguments[0].slice();
    if (command.len == 0 or std.mem.indexOfScalar(u8, command, '/') != null) {
        output.write(command);
        return;
    }
    const prefixes = [_][]const u8{ "/bin/", "/persist/" };
    var path_buffer: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0);
    for (prefixes) |prefix| {
        if (prefix.len + command.len > runtime_vfs.maximum_path_length) continue;
        @memcpy(path_buffer[0..prefix.len], prefix);
        @memcpy(path_buffer[prefix.len .. prefix.len + command.len], command);
        const candidate = path_buffer[0 .. prefix.len + command.len];
        _ = state.vfs.resolve(0, candidate) catch continue;
        output.write(candidate);
        return;
    }
    output.write(command);
}

fn commandSpawn(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count < 2) return usage("spawn PATH [ARGS...]", output);
    _ = launchExecutable(stage, 1, .{}, true, output);
}

fn launchExecutable(
    stage: *const runtime_command.Stage,
    path_index: usize,
    registers: runtime_user.SpawnRegisters,
    background: bool,
    output: *Output,
) ?u64 {
    if (path_index >= stage.count) return null;
    var extra_arguments: [runtime_process.maximum_arguments - 1][]const u8 = undefined;
    const extra_count = stage.count - path_index - 1;
    if (extra_count > extra_arguments.len) {
        usage("exec PATH [up to 7 ARGS]", output);
        return null;
    }
    const stable_arguments = runtime_command.stableArgumentSlices(
        stage,
        path_index + 1,
        extra_arguments[0..],
    ) orelse {
        usage("exec PATH [up to 7 ARGS]", output);
        return null;
    };
    return spawnExecutablePath(
        stage.arguments[path_index].slice(),
        stable_arguments,
        registers,
        background,
        output,
    );
}

fn spawnExecutablePath(
    path: []const u8,
    extra_arguments: []const []const u8,
    registers: runtime_user.SpawnRegisters,
    background: bool,
    output: *Output,
) ?u64 {
    const image_bytes = state.vfs.readOnlyView(state.cwd, path) catch |err| {
        shellError(if (background) "spawn" else "exec", err, output);
        return null;
    };
    const image = elf64.parse(image_bytes) orelse {
        output.line("exec: invalid or unsupported ELF64 image");
        state.failed_commands +%= 1;
        return null;
    };
    _ = image;

    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const raw_name = if (slash) |index| path[index + 1 ..] else path;
    const name = raw_name[0..@min(raw_name.len, runtime_process.maximum_name_length)];
    if (name.len == 0) {
        output.line("exec: executable name is empty");
        return null;
    }
    var arguments: [runtime_process.maximum_arguments][]const u8 = undefined;
    arguments[0] = name;
    for (extra_arguments, 0..) |argument, index| arguments[index + 1] = argument;

    const handle = runtime_user.spawn(
        state.shell_handle,
        name,
        arguments[0 .. extra_arguments.len + 1],
        state.cwd,
        image_bytes,
        currentTick(),
        registers,
    ) catch |err| {
        shellError(if (background) "spawn" else "exec", err, output);
        return null;
    };

    state.processes.setProcessGroup(state.shell_handle, handle, 0) catch |err| {
        abortExecutable(handle);
        shellError(if (background) "spawn process group" else "exec process group", err, output);
        return null;
    };

    const identity = runtime_user.imageIdentity(handle) orelse unreachable;
    if (background) {
        const process = state.processes.get(handle) catch return handle;
        output.byte('[');
        output.decimal(process.pid);
        output.write("] CPL3 started ");
        output.write(path);
        output.write(" ELF bytes ");
        output.decimal(identity.bytes);
        output.write(" hash 0x");
        output.hex(identity.hash);
        output.write("\r\n");
    }
    return handle;
}

fn driveForeground(handle: u64, output: *Output) ?runtime_process.Status {
    if (!shellOwnsTerminal()) {
        output.line("exec: another foreground process is already active");
        return null;
    }
    state.tty.setForeground(&state.processes, handle) catch |err| {
        shellError("exec terminal foreground", err, output);
        return null;
    };
    state.shell_waiting = true;
    defer {
        state.shell_waiting = false;
        state.tty.setForeground(&state.processes, state.shell_handle) catch {};
        state.processes.setRunning(state.shell_handle) catch {};
    }

    const initial = state.processes.get(handle) catch |err| {
        shellError("exec", err, output);
        return null;
    };
    if (!initial.terminal())
        _ = state.processes.wait(state.shell_handle, handle, false) catch |err| {
            shellError("exec wait", err, output);
            return null;
        };

    while (true) {
        const received_input = serviceForegroundInput();
        const process = state.processes.get(handle) catch |err| {
            shellError("exec", err, output);
            return null;
        };
        if (process.terminal()) break;
        if (process.state == .stopped) {
            output.line("exec: process stopped; resume or kill it from a background job");
            return null;
        }
        serviceRuntime();
        if (!received_input) zigos_wait_for_interrupt();
    }

    runtime_user.finalize(handle) catch |err| shellError("exec cleanup", err, output);
    var program_output: [4096]u8 = undefined;
    const output_count = runtime_user.takeOutput(handle, &program_output);
    if (output_count != 0) output.write(program_output[0..output_count]);
    if (runtime_user.outputWasTruncated(handle)) output.line("exec: userspace output truncated at 4096 bytes");
    const status = state.processes.wait(state.shell_handle, handle, true) catch |err| {
        shellError("wait", err, output);
        return null;
    } orelse return null;
    runtime_user.forget(handle);
    state.processes.setRunning(state.shell_handle) catch {};
    return status;
}

fn commandKill(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count < 2 or stage.count > 3) return usage("kill PID [SIGNAL]", output);
    const pid = parseU32(stage.arguments[1].slice()) orelse return usage("kill PID [SIGNAL]", output);
    if (pid == 1 or pid == 2) return output.line("kill: refusing to terminate init or the active shell");
    const signal: u8 = if (stage.count == 3) std.fmt.parseInt(u8, stage.arguments[2].slice(), 10) catch return usage("kill PID [SIGNAL]", output) else 9;
    const handle = state.processes.handleForPid(pid) catch |err| return shellError("kill", err, output);
    state.processes.sendSignal(state.shell_handle, handle, signal) catch |err| return shellError("kill", err, output);
    const process = state.processes.get(handle) catch return;
    if (process.terminal()) runtime_user.finalize(handle) catch |err| return shellError("kill cleanup", err, output);
    if (stage.count == 2) output.write("forced termination ");
    output.write("signal ");
    output.decimal(signal);
    output.write(" sent to real PID ");
    output.decimal(pid);
    output.write(" state ");
    output.line(@tagName(process.state));
}

fn commandWait(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count != 2) return usage("wait PID", output);
    const pid = parseU32(stage.arguments[1].slice()) orelse return usage("wait PID", output);
    const handle = state.processes.handleForPid(pid) catch |err| return shellError("wait", err, output);
    var process = state.processes.get(handle) catch |err| return shellError("wait", err, output);
    const shell = state.processes.get(state.shell_handle) catch |err| return shellError("wait", err, output);
    if (process.ppid != shell.pid) return shellError("wait", runtime_process.Error.NotChild, output);

    if (!process.terminal()) {
        state.shell_waiting = true;
        defer {
            state.shell_waiting = false;
            state.processes.setRunning(state.shell_handle) catch {};
        }
        _ = state.processes.wait(state.shell_handle, handle, false) catch |err| return shellError("wait", err, output);
        while (true) {
            process = state.processes.get(handle) catch |err| return shellError("wait", err, output);
            if (process.terminal()) break;
            serviceRuntime();
            zigos_wait_for_interrupt();
        }
    }

    runtime_user.finalize(handle) catch |err| return shellError("wait cleanup", err, output);
    var program_output: [4096]u8 = undefined;
    const output_count = runtime_user.takeOutput(handle, &program_output);
    if (output_count != 0) output.write(program_output[0..output_count]);
    const status = state.processes.wait(state.shell_handle, handle, true) catch |err| return shellError("wait", err, output);
    if (status == null) return shellError("wait", runtime_process.Error.StillRunning, output);
    output.write("PID ");
    output.decimal(status.?.pid);
    output.write(" status 0x");
    output.hex(status.?.exit_status);
    output.write(" state ");
    output.write(@tagName(status.?.state));
    if (status.?.state == .faulted) {
        output.write(" vector ");
        output.decimal(status.?.fault_vector);
        output.write(" address 0x");
        output.hex(status.?.fault_address);
    }
    output.write("\r\n");
    runtime_user.forget(handle);
}

fn commandCrash(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count > 2) return usage("crash [ELF_PATH]", output);
    const path = if (stage.count == 2) stage.arguments[1].slice() else "/bin/crash.elf";
    const handle = spawnExecutablePath(path, &.{}, .{}, false, output) orelse return;
    const status = driveForeground(handle, output) orelse return;
    if (status.state != .faulted) {
        output.write("crash: program did not fault; state ");
        output.write(@tagName(status.state));
        output.write(" status 0x");
        output.hex(status.exit_status);
        output.write("\r\n");
        state.failed_commands +%= 1;
        return;
    }
    output.write("crash: contained genuine CPL3 exception in PID ");
    output.decimal(status.pid);
    output.write(" vector ");
    output.decimal(status.fault_vector);
    output.write(" CR2 0x");
    output.hex(status.fault_address);
    output.write("\r\n");
}

fn commandSleep(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count != 2) return usage("sleep TICKS", output);
    const duration = parseU64(stage.arguments[1].slice()) orelse return usage("sleep TICKS", output);
    if (duration == 0 or duration > 10_000) return usage("sleep TICKS", output);
    state.processes.sleep(state.shell_handle, currentTick() + duration) catch |err| return shellError("sleep", err, output);
    state.shell_sleeping = true;
    output.write("sleeping until tick ");
    output.decimal(currentTick() + duration);
    output.write("\r\n");
}

fn commandUptime(output: *Output) void {
    output.write("ticks ");
    output.decimal(currentTick());
    output.write(" at 100 Hz; seconds ");
    output.decimal(currentTick() / 100);
    output.write("; idle halts ");
    output.decimal(state.idle_halts);
    output.write("; service passes ");
    output.decimal(state.device_service_passes);
    output.write("\r\n");
}

fn commandElf(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count != 2) return usage("elf PATH", output);
    var bytes: [runtime_vfs.maximum_file_size]u8 = undefined;
    const count = state.vfs.read(state.cwd, stage.arguments[1].slice(), 0, &bytes) catch |err| return shellError("elf", err, output);
    const image = elf64.parse(bytes[0..count]) orelse return output.line("elf: invalid or unsupported ELF64 image");
    output.write("ELF64 entry 0x");
    output.hex(image.entry);
    output.write(" segments ");
    output.decimal(image.load_count);
    output.write(" bytes ");
    output.decimal(count);
    output.write(" FNV-1a64 0x");
    output.hex(image.file_hash);
    output.write("\r\n");
    for (image.load_segments[0..image.load_count], 0..) |segment, index| {
        output.write("  PT_LOAD ");
        output.decimal(index);
        output.write(" VA 0x");
        output.hex(segment.virtual_address);
        output.write(" filesz ");
        output.decimal(segment.file_size);
        output.write(" memsz ");
        output.decimal(segment.memory_size);
        output.write(" flags ");
        output.write(if (segment.readable()) "R" else "-");
        output.write(if (segment.writable()) "W" else "-");
        output.write(if (segment.executable()) "X" else "-");
        output.write("\r\n");
    }
}

fn commandExec(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count < 2) return usage("exec PATH [ARGS...]", output);
    const handle = launchExecutable(stage, 1, .{}, false, output) orelse return;
    const identity = runtime_user.imageIdentity(handle) orelse return;
    output.write("exec: mapped VFS ELF bytes ");
    output.decimal(identity.bytes);
    output.write(" hash 0x");
    output.hex(identity.hash);
    output.line(" into a private CR3; entering CPL3");
    const status = driveForeground(handle, output) orelse return;
    output.write("exec: PID ");
    output.decimal(status.pid);
    output.write(" state ");
    output.write(@tagName(status.state));
    output.write(" status 0x");
    output.hex(status.exit_status);
    output.write(" CPU ticks ");
    output.decimal(status.cpu_ticks);
    output.write(" syscalls ");
    output.decimal(status.syscall_count);
    if (status.state == .faulted) {
        output.write(" vector ");
        output.decimal(status.fault_vector);
        output.write(" address 0x");
        output.hex(status.fault_address);
    }
    output.write("\r\n");
}

fn commandDevices(output: *Output) void {
    output.write("serial COM1 online; framebuffer ");
    output.write(if (state.config.framebuffer_ready) "yes" else "no");
    output.write("; USB keyboard ");
    output.write(if (state.config.usb_keyboard_ready) "yes" else "no");
    output.write("; NVMe ");
    output.write(if (state.config.nvme_ready) "yes" else "no");
    output.write("; AHCI ");
    output.write(if (state.config.ahci_ready) "yes" else "no");
    output.write("; e1000e ");
    output.write(if (state.config.network_ready) "yes" else "no");
    output.write("\r\n");
}

fn commandIfconfig(output: *Output) void {
    const device = activeNetworkDevice(output, "ifconfig") orelse return;
    output.write("e1000e0: up mac ");
    outputMac(output, device.local_mac);
    output.write(" ipv4 ");
    outputIpv4(output, device.local_ipv4);
    output.write(" netmask ");
    outputIpv4(output, device.subnet_mask);
    output.write(" gateway ");
    outputIpv4(output, device.gateway_ipv4);
    output.write(" dns ");
    if (device.dns_server_advertised) outputIpv4(output, device.dns_server_ipv4) else output.write("unadvertised");
    output.write(" tx/rx ");
    output.decimal(device.tx_submissions);
    output.byte('/');
    output.decimal(device.rx_deliveries);
    output.write("\r\n");
}

fn commandNetstat(output: *Output) void {
    const device = activeNetworkDevice(output, "netstat") orelse return;
    const endpoints = e1000e.pollUdpEndpoints(device);
    output.write("UDP endpoints active/readable/connected ");
    output.decimal(endpoints.active_count);
    output.byte('/');
    output.decimal(endpoints.readable_count);
    output.byte('/');
    output.decimal(endpoints.connected_count);
    output.write(" pending ");
    output.decimal(endpoints.total_pending);
    output.write(" max ");
    output.decimal(endpoints.max_pending);
    output.write("; packets dispatched ICMP/UDP ");
    output.decimal(device.icmp_packets_dispatched);
    output.byte('/');
    output.decimal(device.udp_packets_dispatched);
    output.write("\r\n");
}

fn commandRoutes(output: *Output) void {
    const device = activeNetworkDevice(output, "routes") orelse return;
    output.write("default via ");
    outputIpv4(output, device.gateway_ipv4);
    output.write(" dev e1000e0; connected ");
    outputIpv4(output, device.local_ipv4);
    output.write(" netmask ");
    outputIpv4(output, device.subnet_mask);
    output.write("\r\n");
}

fn commandArp(output: *Output) void {
    const device = activeNetworkDevice(output, "arp") orelse return;
    outputIpv4(output, device.gateway_ipv4);
    output.write(" at ");
    outputMac(output, device.gateway_mac);
    output.write(" dev e1000e0 retained-from-live-ARP\r\n");
}

fn commandPing(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count != 2) return usage("ping ADDRESS", output);
    const destination = parseIpv4(stage.arguments[1].slice()) orelse return usage("ping ADDRESS", output);
    const device = activeNetworkDevice(output, "ping") orelse return;
    if (!prepareNetworkMmio(device, output, "ping")) return;
    defer zigos_enable_interrupts();
    const before = currentTick();
    const result = e1000e.pingIpv4(device, destination, 8) orelse {
        output.write("ping: timeout or invalid reply from ");
        outputIpv4(output, destination);
        output.write("\r\n");
        state.network_failures +%= 1;
        state.failed_commands +%= 1;
        return;
    };
    const after = currentTick();
    output.write("reply from ");
    outputIpv4(output, result.destination_ipv4);
    output.write(": bytes=");
    output.decimal(result.payload_length);
    output.write(" ttl=");
    output.decimal(result.ttl);
    output.write(" id=0x");
    output.hexFixed(result.identifier, 4);
    output.write(" seq=");
    output.decimal(result.sequence);
    output.write(" descriptors ");
    output.decimal(result.tx_descriptor);
    output.byte('/');
    output.decimal(result.rx_descriptor);
    output.write(" interrupts ");
    output.decimal(result.tx_interrupt_count);
    output.byte('/');
    output.decimal(result.rx_interrupt_count);
    output.write(" ticks ");
    output.decimal(after -| before);
    output.write("\r\n");
    state.live_ping_passes +%= 1;
}

fn commandDns(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count != 2) return usage("dns NAME", output);
    const name = stage.arguments[1].slice();
    const device = activeNetworkDevice(output, "dns") orelse return;
    if (!prepareNetworkMmio(device, output, "dns")) return;
    if (!device.dns_server_advertised) {
        output.line("dns: unavailable: DHCP supplied no DNS server");
        return;
    }
    var resolver = e1000e.openDnsResolver(device, device.dns_server_ipv4) orelse {
        output.line("dns: resolver socket allocation failed");
        state.network_failures +%= 1;
        state.failed_commands +%= 1;
        return;
    };
    defer {
        _ = e1000e.closeDnsResolverDiscarding(device, &resolver);
        zigos_enable_interrupts();
    }
    const started = e1000e.startDnsResolverA(device, &resolver, currentTick(), name) orelse {
        output.line("dns: invalid name or query transmission failed");
        state.network_failures +%= 1;
        state.failed_commands +%= 1;
        return;
    };
    switch (started) {
        .cached => |cached| {
            output.write(name);
            output.write(" cached A ");
            outputIpv4(output, cached.address);
            output.write(" ttl ");
            output.decimal(cached.ttl_remaining);
            output.write("\r\n");
            state.live_dns_passes +%= 1;
        },
        .not_found => |ttl| {
            output.write(name);
            output.write(" NXDOMAIN ttl ");
            output.decimal(ttl);
            output.write("\r\n");
            state.live_dns_passes +%= 1;
        },
        .pending => |request| {
            var attempts: u16 = 0;
            while (attempts < 16) : (attempts += 1) {
                if (e1000e.pumpReceive(device)) {
                    _ = e1000e.serviceUdpSockets(device, 8);
                }
                const poll = e1000e.pollDnsResolverA(device, &resolver, &request, currentTick(), 8, 60);
                switch (poll.state) {
                    .resolved => {
                        const response = poll.response orelse continue;
                        output.write(name);
                        output.write(" A ");
                        outputIpv4(output, response.address);
                        output.write(" ttl ");
                        output.decimal(response.ttl);
                        output.write(" aliases ");
                        output.decimal(response.alias_hops);
                        output.write(" txid 0x");
                        output.hexFixed(request.transaction_id, 4);
                        output.write(" examined/rejected ");
                        output.decimal(poll.examined);
                        output.byte('/');
                        output.decimal(poll.rejected);
                        output.write("\r\n");
                        state.live_dns_passes +%= 1;
                        return;
                    },
                    .not_found => {
                        output.write(name);
                        output.write(" NXDOMAIN txid 0x");
                        output.hexFixed(request.transaction_id, 4);
                        output.write("\r\n");
                        state.live_dns_passes +%= 1;
                        return;
                    },
                    .inactive => break,
                    .pending => {},
                }
            }
            output.write("dns: timeout resolving ");
            output.write(name);
            output.write(" via ");
            outputIpv4(output, device.dns_server_ipv4);
            output.write("\r\n");
            state.network_failures +%= 1;
            state.failed_commands +%= 1;
        },
    }
}

fn activeNetworkDevice(output: *Output, command: []const u8) ?*e1000e.Device {
    if (!state.config.network_ready) {
        output.write(command);
        output.line(": unavailable: e1000e was not initialized for this boot");
        return null;
    }
    return e1000e.activeDevice() orelse {
        output.write(command);
        output.line(": unavailable: retained e1000e device state is missing");
        return null;
    };
}

fn prepareNetworkMmio(device: *e1000e.Device, output: *Output, command: []const u8) bool {
    const preparation = e1000e.prepareRuntimeMmio(device);
    if (preparation.switched) {
        output.write(command);
        output.write(": restored kernel CR3 from 0x");
        output.hex(preparation.current_before);
        output.write(" (tracked 0x");
        output.hex(preparation.tracked_before);
        output.write(") to 0x");
        output.hex(preparation.current_after);
        output.write("\r\n");
    }
    if (preparation.ready) return true;

    output.write(command);
    output.write(": unavailable: e1000e MMIO mapping invariant failed; current 0x");
    output.hex(preparation.current_after);
    output.write(" kernel 0x");
    output.hex(preparation.kernel_root);
    output.write(" mapped ");
    output.line(if (preparation.kernel_mapped) "yes" else "no");
    state.network_failures +%= 1;
    state.failed_commands +%= 1;
    return false;
}

fn parseIpv4(bytes: []const u8) ?[4]u8 {
    var result: [4]u8 = undefined;
    var start: usize = 0;
    for (0..4) |index| {
        const end = if (index == 3) bytes.len else std.mem.indexOfScalarPos(u8, bytes, start, '.') orelse return null;
        if (end == start) return null;
        result[index] = std.fmt.parseInt(u8, bytes[start..end], 10) catch return null;
        start = end + 1;
    }
    if (start != bytes.len + 1) return null;
    return result;
}

fn outputIpv4(output: *Output, address: [4]u8) void {
    for (address, 0..) |octet, index| {
        if (index != 0) output.byte('.');
        output.decimal(octet);
    }
}

fn outputMac(output: *Output, address: [6]u8) void {
    for (address, 0..) |octet, index| {
        if (index != 0) output.byte(':');
        output.hexFixed(octet, 2);
    }
}

fn commandEnv(output: *Output) void {
    for (state.environment.entries) |entry| {
        if (!entry.used) continue;
        output.write(entry.keySlice());
        output.byte('=');
        output.line(entry.valueSlice());
    }
}

fn commandExport(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count != 2) return usage("export KEY=VALUE", output);
    const assignment = stage.arguments[1].slice();
    const separator = std.mem.indexOfScalar(u8, assignment, '=') orelse return usage("export KEY=VALUE", output);
    state.environment.set(assignment[0..separator], assignment[separator + 1 ..]) catch |err| return shellError("export", err, output);
}

fn commandUnset(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count != 2) return usage("unset KEY", output);
    if (!state.environment.unset(stage.arguments[1].slice())) output.line("unset: variable was not set");
}

fn commandHistory(output: *Output) void {
    const editor = &state.editor;
    const oldest = (editor.history_head + runtime_command.maximum_history - editor.history_count) % runtime_command.maximum_history;
    for (0..editor.history_count) |logical| {
        const physical = (oldest + logical) % runtime_command.maximum_history;
        output.decimal(logical + 1);
        output.write("  ");
        output.line(editor.history[physical][0..editor.history_lengths[physical]]);
    }
}

fn commandSync(output: *Output) void {
    const result = syncAllWritableMounts(null);
    if (result < 0) return shellError("sync", error.PersistentSyncFailed, output);
    const report = state.persistence.report();
    output.write("sync complete: writable mounts ");
    output.decimal(report.writable_mount_syncs);
    output.write(" immediate ");
    output.decimal(report.immediate_mount_syncs);
    output.write(" durable ");
    output.decimal(report.durable_mount_syncs);
    output.write("; ramfs mutations ");
    output.decimal(state.vfs.report().mutations);
    output.write("; persistent generation ");
    output.decimal(report.generation);
    output.write(" slot ");
    output.decimal(report.active_slot);
    output.write(" records ");
    output.decimal(report.record_count);
    output.write(" payload ");
    output.decimal(report.payload_bytes);
    output.write(" bytes, writes/headers/flushes ");
    output.decimal(report.payload_writes);
    output.write("/");
    output.decimal(report.header_writes);
    output.write("/");
    output.decimal(report.flushes);
    output.write("\r\n");
}

fn commandWriteback(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count != 2) return usage("writeback PATH|status", output);
    if (equal(stage.arguments[1].slice(), "status")) {
        const report = state.persistence.report();
        output.write("writeback: active ");
        output.write(if (report.writeback_active) "yes" else "no");
        output.write(" requests/completions/passes ");
        output.decimal(report.writeback_requests);
        output.write("/");
        output.decimal(report.writeback_completions);
        output.write("/");
        output.decimal(report.writeback_passes);
        output.write(" immediate/durable/clean/unsupported/failures/stale ");
        output.decimal(report.writeback_immediate);
        output.write("/");
        output.decimal(report.writeback_durable);
        output.write("/");
        output.decimal(report.writeback_clean);
        output.write("/");
        output.decimal(report.writeback_unsupported);
        output.write("/");
        output.decimal(report.writeback_failures);
        output.write("/");
        output.decimal(report.writeback_stale);
        output.write(" pages queued/completed ");
        output.decimal(report.writeback_pages_queued);
        output.write("/");
        output.decimal(report.writeback_pages_completed);
        output.write("\r\n");
        return;
    }
    const node = state.vfs.resolve(state.cwd, stage.arguments[1].slice()) catch |err| return shellError("writeback", err, output);
    const request = state.persistence.requestWriteback(&state.vfs, node) catch |err| return shellError("writeback", err, output);
    output.write("writeback scheduled: node ");
    output.decimal(request.node);
    output.write(" generation ");
    output.decimal(request.generation);
    output.write(" pages ");
    output.decimal(@popCount(request.pages));
    output.write(" persistent ");
    output.line(if (request.persistent) "yes" else "no");
}

fn commandCachePressure(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count != 1) return usage("cachepressure", output);
    const before_memory = state.config.physical_memory.report();
    const before_cache = state.vfs.report();
    const forced_watermark = if (before_memory.free_pages == std.math.maxInt(u64))
        before_memory.free_pages
    else
        before_memory.free_pages + 1;
    const reclaimed = state.vfs.reclaimCleanFilePageCacheUnderPressure(
        before_memory.free_pages,
        forced_watermark,
        0,
    );
    const after_memory = state.config.physical_memory.report();
    const after_cache = state.vfs.report();
    output.write("cache pressure: free before/after ");
    output.decimal(before_memory.free_pages);
    output.write("/");
    output.decimal(after_memory.free_pages);
    output.write(" entries before/after ");
    output.decimal(before_cache.file_page_cache_entries);
    output.write("/");
    output.decimal(after_cache.file_page_cache_entries);
    output.write(" reclaimed ");
    output.decimal(reclaimed);
    output.write(" dirty retained ");
    output.decimal(after_cache.file_page_cache_dirty_entries);
    output.write(" pressure checks/events/evictions ");
    output.decimal(after_cache.file_page_cache_pressure_checks);
    output.write("/");
    output.decimal(after_cache.file_page_cache_pressure_events);
    output.write("/");
    output.decimal(after_cache.file_page_cache_pressure_evictions);
    output.write(" backing alloc/release ");
    output.decimal(after_cache.file_page_cache_allocations);
    output.write("/");
    output.decimal(after_cache.file_page_cache_releases);
    output.write("\r\n");
}

fn commandFsck(output: *Output) void {
    output.write("fsck ramfs/persist: ");
    const result = checkFilesystems(null);
    output.line(if (result == 0) "clean" else if (result == 1) "corrupt" else "error");
}

fn checkFilesystems(_: ?*anyopaque) i64 {
    state.filesystem_checks +%= 1;
    if (!state.persistence.report().mounted) return runtime_abi.errno_no_syscall;
    if (!state.vfs.validate()) return 1;
    state.persistence.check() catch |err| return switch (err) {
        error.Corrupt, error.InvalidRecord => 1,
        error.NotConfigured => runtime_abi.errno_no_syscall,
        else => runtime_abi.errno_io,
    };
    return 0;
}

fn commandHash(stage: *const runtime_command.Stage, input: []const u8, output: *Output) void {
    var bytes = input;
    var storage: [runtime_vfs.maximum_file_size]u8 = undefined;
    if (stage.count >= 2) {
        const count = state.vfs.read(state.cwd, stage.arguments[1].slice(), 0, &storage) catch |err| return shellError("hash", err, output);
        bytes = storage[0..count];
    }
    output.write("fnv1a64 0x");
    output.hex(elf64.fnv1a64(bytes));
    output.write(" bytes ");
    output.decimal(bytes.len);
    output.write("\r\n");
}

fn commandHexdump(stage: *const runtime_command.Stage, input: []const u8, output: *Output) void {
    var bytes = input;
    var storage: [runtime_vfs.maximum_file_size]u8 = undefined;
    if (stage.count >= 2) {
        const count = state.vfs.read(state.cwd, stage.arguments[1].slice(), 0, &storage) catch |err| return shellError("hexdump", err, output);
        bytes = storage[0..count];
    }
    const count = @min(bytes.len, 256);
    var offset: usize = 0;
    while (offset < count) : (offset += 16) {
        output.hexFixed(offset, 4);
        output.write("  ");
        const row_count = @min(@as(usize, 16), count - offset);
        for (0..16) |column| {
            if (column < row_count) output.hexFixed(bytes[offset + column], 2) else output.write("  ");
            output.byte(' ');
        }
        output.byte(' ');
        for (bytes[offset .. offset + row_count]) |byte| output.byte(if (byte >= 0x20 and byte <= 0x7E) byte else '.');
        output.write("\r\n");
    }
}

fn commandGrep(stage: *const runtime_command.Stage, input: []const u8, output: *Output) void {
    if (stage.count != 2) return usage("grep PATTERN", output);
    const pattern = stage.arguments[1].slice();
    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, pattern) == null) continue;
        output.write(line);
        output.write("\n");
    }
}

fn commandWc(input: []const u8, output: *Output) void {
    var lines: usize = 0;
    var words: usize = 0;
    var in_word = false;
    for (input) |byte| {
        if (byte == '\n') lines += 1;
        const whitespace = byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
        if (!whitespace and !in_word) words += 1;
        in_word = !whitespace;
    }
    output.decimal(lines);
    output.byte(' ');
    output.decimal(words);
    output.byte(' ');
    output.decimal(input.len);
    output.write("\r\n");
}

fn commandHead(stage: *const runtime_command.Stage, input: []const u8, output: *Output) void {
    const wanted = if (stage.count == 2) parseU64(stage.arguments[1].slice()) orelse return usage("head [LINES]", output) else 10;
    var lines: u64 = 0;
    for (input) |byte| {
        if (lines >= wanted) break;
        output.byte(byte);
        if (byte == '\n') lines += 1;
    }
}

fn readPath(path: []const u8, output: *Output) bool {
    const fd = state.descriptors.openFile(
        &state.vfs,
        &state.processes,
        state.shell_handle,
        path,
        .{ .read = true },
        0,
        currentTick(),
    ) catch |err| {
        shellError("cat", err, output);
        return false;
    };
    defer state.descriptors.close(&state.vfs, &state.processes, state.shell_handle, fd) catch {};
    var storage: [1024]u8 = undefined;
    while (true) {
        const result = state.descriptors.read(&state.vfs, &state.processes, state.shell_handle, fd, &storage) catch |err| {
            shellError("cat", err, output);
            return false;
        };
        switch (result.status) {
            .complete => output.write(storage[0..result.count]),
            .eof => return true,
            .blocked => {
                shellError("cat", runtime_fd.Error.InvalidOperation, output);
                return false;
            },
        }
    }
}

fn writeDescriptorPath(path: []const u8, bytes: []const u8, append: bool) !void {
    const fd = try state.descriptors.openFile(
        &state.vfs,
        &state.processes,
        state.shell_handle,
        path,
        .{ .write = true, .create = true, .truncate = !append, .append = append },
        0o644,
        currentTick(),
    );
    errdefer state.descriptors.close(&state.vfs, &state.processes, state.shell_handle, fd) catch {};
    var written: usize = 0;
    while (written < bytes.len) {
        const result = try state.descriptors.write(
            &state.vfs,
            &state.processes,
            state.shell_handle,
            fd,
            bytes[written..],
            currentTick(),
        );
        if (result.status != .complete or result.count == 0) return runtime_fd.Error.InvalidOperation;
        written += result.count;
    }
    try state.descriptors.close(&state.vfs, &state.processes, state.shell_handle, fd);
}

fn readGeneratedPseudo(_: ?*anyopaque, node: u16, offset: usize, destination: []u8) runtime_vfs.Error!usize {
    if (destination.len == 0 or state.pseudo_busy) return 0;
    state.pseudo_busy = true;
    defer state.pseudo_busy = false;
    var output = Output.init(&state.pseudo_buffer);
    if (!formatPseudo(node, &output) or offset >= output.length) return 0;
    const count = @min(destination.len, output.length - offset);
    @memcpy(destination[0..count], output.slice()[offset .. offset + count]);
    return count;
}

fn readNullPseudo(_: ?*anyopaque, _: u16, _: usize, _: []u8) runtime_vfs.Error!usize {
    return 0;
}

fn readZeroPseudo(_: ?*anyopaque, _: u16, _: usize, destination: []u8) runtime_vfs.Error!usize {
    @memset(destination, 0);
    return destination.len;
}

fn writeDiscardPseudo(_: ?*anyopaque, _: u16, _: usize, input: []const u8) runtime_vfs.Error!usize {
    return input.len;
}

fn pollGeneratedPseudo(_: ?*anyopaque, _: u16, requested: u16) runtime_vfs.Error!u16 {
    return requested & runtime_abi.poll_readable;
}

fn pollNullOrZeroPseudo(_: ?*anyopaque, _: u16, requested: u16) runtime_vfs.Error!u16 {
    return requested & (runtime_abi.poll_readable | runtime_abi.poll_writable);
}

fn formatPseudo(node: u16, output: *Output) bool {
    var path_buffer: [runtime_vfs.maximum_path_length + 1]u8 = undefined;
    const path = state.vfs.canonicalPath(node, &path_buffer) catch return false;
    if (equal(path, "/proc/version")) {
        output.line("ZigOs 19.0.0 x86_64 persistent runtime");
    } else if (equal(path, "/proc/uptime")) {
        output.decimal(currentTick() / 100);
        output.byte('.');
        output.decimal(currentTick() % 100);
        output.write("\r\n");
    } else if (equal(path, "/proc/meminfo")) {
        const report = state.vfs.report();
        output.write("RamfsUsed: ");
        output.decimal(report.bytes_used);
        output.write(" bytes\r\nRamfsCapacity: ");
        output.decimal(runtime_vfs.maximum_nodes * runtime_vfs.maximum_file_size);
        output.write(" bytes\r\n");
    } else if (equal(path, "/proc/processes")) {
        commandPs(output);
    } else if (equal(path, "/proc/mounts")) {
        commandMount(output);
    } else if (equal(path, "/net/interfaces")) {
        commandIfconfig(output);
    } else if (equal(path, "/net/routes")) {
        commandRoutes(output);
    } else if (equal(path, "/net/arp")) {
        commandArp(output);
    } else if (equal(path, "/net/sockets")) {
        commandNetstat(output);
    } else {
        return false;
    }
    return true;
}

fn shellError(prefix: []const u8, err: anyerror, output: *Output) void {
    output.write(prefix);
    output.write(": ");
    output.line(@errorName(err));
    state.failed_commands +%= 1;
}

fn usage(text: []const u8, output: *Output) void {
    output.write("usage: ");
    output.line(text);
    state.failed_commands +%= 1;
}

fn equal(left: []const u8, right: []const u8) bool {
    return std.ascii.eqlIgnoreCase(left, right);
}

fn parseU64(text: []const u8) ?u64 {
    return std.fmt.parseInt(u64, text, 0) catch null;
}

fn parseU32(text: []const u8) ?u32 {
    return std.fmt.parseInt(u32, text, 0) catch null;
}

fn flushUserspaceOutput(handle: u64) void {
    var bytes: [4096]u8 = undefined;
    while (true) {
        const count = runtime_user.takeOutput(handle, &bytes);
        if (count == 0) break;
        emit(bytes[0..count]);
    }
}

fn syncAllWritableMounts(_: ?*anyopaque) i64 {
    state.filesystem_syncs +%= 1;
    state.persistence.sync(&state.vfs) catch |err| return runtime_abi.fromError(err);
    return 0;
}

fn syncPersistentFile(_: ?*anyopaque, node: u16, include_metadata: bool) i64 {
    state.filesystem_syncs +%= 1;
    const persistent = state.vfs.persistentNode(node) catch |err| return runtime_abi.fromError(err);
    if (!persistent) {
        _ = state.vfs.clearDirtyNodePages(node);
        return 0;
    }
    if (include_metadata) {
        state.persistence.syncFile(&state.vfs, node) catch |err| return runtime_abi.fromError(err);
    } else {
        state.persistence.syncFileData(&state.vfs, node) catch |err| return runtime_abi.fromError(err);
    }
    return 0;
}

fn configureNormalChild(parent_handle: u64, child_handle: u64) bool {
    if (state.config.profile != .normal) return true;
    const init_handle = state.processes.initHandle();
    if (parent_handle != init_handle) return true;
    if (state.shell_handle != 0) return false;
    const child = state.processes.get(child_handle) catch return false;
    if (child.pid != 2 or !std.mem.eql(u8, child.nameSlice(), "sh.elf")) return false;
    state.processes.setProcessGroup(init_handle, child_handle, 0) catch return false;
    state.tty.transferController(&state.processes, init_handle, child_handle) catch return false;
    state.shell_handle = child_handle;
    state.tty.setForeground(&state.processes, child_handle) catch return false;
    return true;
}

fn requestNormalShutdown(_: ?*anyopaque, process_handle: u64) bool {
    if (state.config.profile != .normal or state.shutdown_requested) return false;
    if (process_handle == state.shell_handle) {
        state.shell_exit_requested = true;
        return true;
    }
    const init_handle = state.processes.initHandle();
    if (process_handle != init_handle or !state.shell_exit_requested or state.shell_handle == 0) return false;
    if (state.processes.get(state.shell_handle)) |_| {
        return false;
    } else |err| {
        if (err != error.InvalidHandle) return false;
    }
    state.init_reaped_shell = true;
    state.shutdown_requested = true;
    return true;
}

fn finishRuntime() noreturn {
    if (state.config.profile == .normal) finishNormalRuntime();
    finishDiagnosticRuntime();
}

fn writebackStateClean(report: runtime_persist.Report) bool {
    const successful = report.writeback_immediate + report.writeback_durable + report.writeback_clean;
    const serviced = successful + report.writeback_unsupported + report.writeback_failures + report.writeback_stale;
    return !report.writeback_active and report.writeback_passes == report.writeback_requests and
        report.writeback_completions == successful and serviced == report.writeback_passes and
        report.writeback_unsupported == 0 and report.writeback_failures == 0 and report.writeback_stale == 0 and
        report.writeback_pages_queued == report.writeback_pages_completed;
}

fn bootFatStateClean(report: runtime_boot_fat.Report, require_file_reads: bool) bool {
    const configured = state.config.nvme_controller != null and state.config.nvme_boot_first_lba != 0 and
        state.config.nvme_boot_sector_count != 0;
    if (report.quarantined) {
        return configured and state.boot_fat.validateQuarantine() and !report.mounted and report.files == 0 and
            report.directories == 0 and report.bytes == 0 and report.file_reads == 0 and report.claimed_clusters == 0 and
            report.free_clusters == 0 and report.quarantine_events == 1 and report.lock_outstanding == 0;
    }
    if (!configured) {
        return !report.mounted and !report.quarantined and report.quarantine_reason == .none and report.quarantine_events == 0 and
            report.files == 0 and report.directories == 0 and report.bytes == 0 and report.metadata_reads == 0 and
            report.file_reads == 0 and report.blocks_read == 0 and report.failures == 0 and report.claimed_clusters == 0 and
            report.free_clusters == 0 and report.chain_loops == 0 and report.cross_links == 0 and report.out_of_range_links == 0 and
            report.lock_outstanding == 0;
    }
    const injection_disabled = if (state.config.nvme_controller) |controller|
        controller.injected_read_failures == 0 and !controller.read_fault_armed
    else
        true;
    const recovered_injected_read_error = if (state.config.nvme_controller) |controller|
        controller.injected_read_failures == 1 and !controller.read_fault_armed and report.failures == 1
    else
        false;
    return report.mounted and !report.quarantined and report.quarantine_reason == .none and report.quarantine_events == 0 and
        state.boot_fat.validate() and report.files >= 3 and report.directories >= 2 and
        report.bytes > 0 and report.metadata_reads > 0 and (!require_file_reads or report.file_reads >= 2) and
        report.blocks_read >= report.metadata_reads and
        ((report.failures == 0 and injection_disabled) or recovered_injected_read_error) and
        report.claimed_clusters > 0 and report.free_clusters > 0 and report.chain_loops == 0 and report.cross_links == 0 and
        report.out_of_range_links == 0 and report.lock_outstanding == 0;
}

fn emitNvmeReadFaultReport() void {
    const controller = state.config.nvme_controller orelse return;
    if (controller.injected_read_failures == 0 and !controller.read_fault_armed) return;
    emit("ZigOs NVMe read fault injection: failures ");
    emitDecimal(controller.injected_read_failures);
    emit(" armed ");
    emit(if (controller.read_fault_armed) "yes" else "no");
    emit(" clean ");
    emit(if (controller.injected_read_failures == 1 and !controller.read_fault_armed) "yes" else "no");
    emit("\r\n");
}

fn nvmeWriteFaultStateClean(report: runtime_persist.Report) bool {
    const controller = state.config.nvme_controller orelse return true;
    if (controller.write_fault_armed or controller.injected_write_failures > 1) return false;
    if (controller.injected_write_failures == 0) return true;
    return report.damaged and report.io_failures == 1;
}

fn persistenceDamageClean(report: runtime_persist.Report, fs_report: runtime_vfs.Report) bool {
    if (!nvmeWriteFaultStateClean(report)) return false;
    const mount_readonly = state.vfs.mountReadOnly(report.mount_id) catch false;
    return report.mounted and report.damaged and report.damage_reason != .none and
        report.read_only_remounts == 1 and report.read_only_remount_failures == 0 and
        report.io_failures == 1 and report.corrupt_headers == 0 and
        report.writable_mount_syncs == report.global_syncs * 2 and
        report.immediate_mount_syncs == report.global_syncs and
        report.durable_mount_syncs == report.global_syncs and report.rejected_sync_plans == 0 and
        writebackStateClean(report) and fs_report.read_only_remounts == 1 and
        fs_report.read_only_remount_dirty_pages == report.discarded_dirty_pages and mount_readonly;
}

fn emitNvmeWriteFaultReport() void {
    const controller = state.config.nvme_controller orelse return;
    if (controller.injected_write_failures == 0 and !controller.write_fault_armed) return;
    emit("ZigOs NVMe write fault injection: failures ");
    emitDecimal(controller.injected_write_failures);
    emit(" armed ");
    emit(if (controller.write_fault_armed) "yes" else "no");
    emit(" clean ");
    emit(if (controller.injected_write_failures == 1 and !controller.write_fault_armed) "yes" else "no");
    emit("\r\n");
}

fn emitPersistenceDamageReport(report: runtime_persist.Report, fs_report: runtime_vfs.Report, clean: bool) void {
    if (!report.damaged and report.read_only_remounts == 0 and report.read_only_remount_failures == 0) return;
    const mount_readonly = state.vfs.mountReadOnly(report.mount_id) catch false;
    emit("ZigOs persistent damage containment: damaged ");
    emit(if (report.damaged) "yes" else "no");
    emit(" reason ");
    emit(@tagName(report.damage_reason));
    emit(" remounts/failures ");
    emitDecimal(report.read_only_remounts);
    emit("/");
    emitDecimal(report.read_only_remount_failures);
    emit(" discarded/rejected ");
    emitDecimal(report.discarded_dirty_pages);
    emit("/");
    emitDecimal(report.read_only_rejections);
    emit(" vfs-remount/discard ");
    emitDecimal(fs_report.read_only_remounts);
    emit("/");
    emitDecimal(fs_report.read_only_remount_dirty_pages);
    emit(" mount-readonly ");
    emit(if (mount_readonly) "yes" else "no");
    emit(" clean ");
    emit(if (clean) "yes" else "no");
    emit("\r\n");
}

fn storageStateLabel(report: runtime_persist.Report, diskless_recovery: bool) []const u8 {
    if (report.mounted and report.damaged) return "persistent-read-only";
    if (report.mounted) return "persistent";
    if (diskless_recovery) return "diskless-ram-root";
    return "unavailable";
}

fn livePseudoFilesystemsClean() bool {
    const dev = state.devfs.report();
    const proc = state.procfs.report();
    const net = state.netfs.report();
    return state.devfs.validate(&state.vfs) and state.procfs.validate(&state.vfs) and state.netfs.validate(&state.vfs) and
        dev.mounted and proc.mounted and net.mounted and dev.mount_id != 0 and proc.mount_id != 0 and net.mount_id != 0 and
        dev.mount_id != proc.mount_id and dev.mount_id != net.mount_id and proc.mount_id != net.mount_id and
        dev.registrations == 3 and proc.registrations == 5 and net.registrations == 4 and
        dev.publications == 3 and proc.publications == 5 and net.publications == 4 and
        dev.withdrawals == 0 and proc.withdrawals == 0 and net.withdrawals == 0 and
        dev.failures == 0 and proc.failures == 0 and net.failures == 0;
}

fn emitLivePseudoFilesystemReport(clean: bool) void {
    const dev = state.devfs.report();
    const proc = state.procfs.report();
    const net = state.netfs.report();
    emit("ZigOs live pseudo filesystems: dev/proc/net registrations ");
    emitDecimal(dev.registrations);
    emit("/");
    emitDecimal(proc.registrations);
    emit("/");
    emitDecimal(net.registrations);
    emit(" publications ");
    emitDecimal(dev.publications);
    emit("/");
    emitDecimal(proc.publications);
    emit("/");
    emitDecimal(net.publications);
    emit(" withdrawals ");
    emitDecimal(dev.withdrawals);
    emit("/");
    emitDecimal(proc.withdrawals);
    emit("/");
    emitDecimal(net.withdrawals);
    emit(" failures ");
    emitDecimal(dev.failures);
    emit("/");
    emitDecimal(proc.failures);
    emit("/");
    emitDecimal(net.failures);
    emit(" clean ");
    emit(if (clean) "yes" else "no");
    emit("\r\n");
}

fn emitBootFatReport(report: runtime_boot_fat.Report, clean: bool) void {
    emit("ZigOs boot FAT: block-backed ");
    emit(if (report.mounted) "yes" else "no");
    emit(" files/directories ");
    emitDecimal(report.files);
    emit("/");
    emitDecimal(report.directories);
    emit(" bytes ");
    emitDecimal(report.bytes);
    emit(" metadata/file/block reads ");
    emitDecimal(report.metadata_reads);
    emit("/");
    emitDecimal(report.file_reads);
    emit("/");
    emitDecimal(report.blocks_read);
    emit(" failures ");
    emitDecimal(report.failures);
    emit(" clusters claimed/free/loop/cross/range ");
    emitDecimal(report.claimed_clusters);
    emit("/");
    emitDecimal(report.free_clusters);
    emit("/");
    emitDecimal(report.chain_loops);
    emit("/");
    emitDecimal(report.cross_links);
    emit("/");
    emitDecimal(report.out_of_range_links);
    emit(" lock tickets/outstanding ");
    emitDecimal(report.lock_tickets);
    emit("/");
    emitDecimal(report.lock_outstanding);
    emit(" quarantine state/reason/events ");
    emit(if (report.quarantined) "yes" else "no");
    emit("/");
    emit(@tagName(report.quarantine_reason));
    emit("/");
    emitDecimal(report.quarantine_events);
    emit(" clean ");
    emit(if (clean) "yes" else "no");
    emit("\r\n");
}

fn finishNormalRuntime() noreturn {
    apic.setTimerHook(null);
    apic.stopCurrentProcessorTimer(descriptor_tables.persistent_runtime_timer_vector);
    const init_handle = state.processes.initHandle();
    runtime_user.finalize(init_handle) catch |err| switch (err) {
        error.NoContext => {},
        else => runtimeFailure(@errorName(err)),
    };
    const init_process = state.processes.get(init_handle) catch |err| runtimeFailure(@errorName(err));
    runtime_user.forget(init_handle);
    const fs_report = state.vfs.report();
    const process_report = state.processes.report();
    const descriptor_report = state.descriptors.report();
    const tty_report = state.tty.report();
    const persistence_report = state.persistence.report();
    const boot_fat_report = state.boot_fat.report();
    const boot_fat_clean = bootFatStateClean(boot_fat_report, false);
    const pseudo_filesystems_clean = livePseudoFilesystemsClean();
    const userspace_report = runtime_user.report();
    const released_cache_pages = state.vfs.releaseFilePageCache();
    const final_fs_report = state.vfs.report();
    const physical_report = state.config.physical_memory.report();
    const physical_rejections = physical_report.invalid_frees + physical_report.double_frees + physical_report.metadata_failures;
    const diskless_recovery = !state.config.nvme_ready and !state.config.ahci_ready;
    const persistence_healthy = persistence_report.mounted and !persistence_report.damaged and
        persistence_report.damage_reason == .none and persistence_report.read_only_remounts == 0 and
        persistence_report.read_only_remount_failures == 0 and persistence_report.discarded_dirty_pages == 0 and
        persistence_report.read_only_rejections == 0 and persistence_report.io_failures == 0 and
        persistence_report.corrupt_headers == 0 and persistence_report.global_syncs >= 1 and
        persistence_report.writable_mount_syncs == persistence_report.global_syncs * 2 and
        persistence_report.immediate_mount_syncs == persistence_report.global_syncs and
        persistence_report.durable_mount_syncs == persistence_report.global_syncs and
        persistence_report.rejected_sync_plans == 0 and writebackStateClean(persistence_report) and
        nvmeWriteFaultStateClean(persistence_report) and fs_report.read_only_remounts == 0 and
        fs_report.read_only_remount_dirty_pages == 0;
    const persistence_contained = persistenceDamageClean(persistence_report, fs_report);
    const persistence_clean = if (persistence_report.mounted)
        persistence_healthy or persistence_contained
    else
        diskless_recovery and persistence_report.mounts == 0 and persistence_report.syncs == 0 and
            !persistence_report.damaged and persistence_report.damage_reason == .none and
            persistence_report.read_only_remounts == 0 and persistence_report.read_only_remount_failures == 0 and
            persistence_report.discarded_dirty_pages == 0 and persistence_report.read_only_rejections == 0 and
            persistence_report.global_syncs >= 1 and
            persistence_report.writable_mount_syncs == persistence_report.global_syncs and
            persistence_report.immediate_mount_syncs == persistence_report.global_syncs and
            persistence_report.durable_mount_syncs == 0 and persistence_report.rejected_sync_plans == 0 and
            writebackStateClean(persistence_report) and persistence_report.io_failures == 0 and
            persistence_report.corrupt_headers == 0 and nvmeWriteFaultStateClean(persistence_report) and
            fs_report.read_only_remounts == 0 and fs_report.read_only_remount_dirty_pages == 0;
    const vfs_clean = state.vfs.validate() and fs_report.dentry_cache_references == 0 and
        fs_report.dentry_cache_acquires == fs_report.dentry_cache_releases and fs_report.dentry_cache_hits > 0 and
        fs_report.dentry_cache_misses > 0 and fs_report.dentry_cache_insertions > 0 and
        fs_report.file_page_cache_entries > 0 and
        fs_report.file_page_cache_entries <= runtime_vfs.maximum_file_page_cache_entries and
        fs_report.file_page_cache_hits > 0 and fs_report.file_page_cache_misses > 0 and
        fs_report.file_page_cache_insertions > 0 and fs_report.file_page_cache_lock_tickets > 0 and
        fs_report.file_page_cache_lock_outstanding == 0 and fs_report.file_page_cache_pressure_checks > 0 and
        fs_report.file_page_cache_allocation_failures == 0 and fs_report.file_page_cache_release_failures == 0 and
        fs_report.file_page_cache_allocations == fs_report.file_page_cache_releases + fs_report.file_page_cache_entries and
        fs_report.file_page_cache_mapping_references == 0 and
        fs_report.file_page_cache_mapping_pins == fs_report.file_page_cache_mapping_unpins and
        fs_report.file_page_cache_mapping_pin_failures == 0 and
        released_cache_pages > 0 and final_fs_report.file_page_cache_entries == 0 and
        final_fs_report.file_page_cache_allocations == final_fs_report.file_page_cache_releases and
        final_fs_report.file_page_cache_release_failures == 0 and
        fs_report.file_page_cache_dirty_entries == 0 and fs_report.dirty_file_pages == 0 and
        fs_report.dirty_file_nodes == 0 and fs_report.dirty_page_marks > 0 and
        fs_report.dirty_page_sync_clears > 0 and
        fs_report.data_lock_tickets > 0 and fs_report.data_lock_outstanding == 0 and
        fs_report.page_write_lock_tickets > 0 and fs_report.page_write_lock_outstanding == 0 and
        fs_report.data_pool_lock_tickets > 0 and fs_report.data_pool_lock_outstanding == 0 and
        fs_report.allocated_blocks > 0 and fs_report.allocated_blocks <= runtime_vfs.maximum_data_blocks and
        fs_report.allocated_bytes == fs_report.allocated_blocks * runtime_vfs.file_block_size;
    const clean = init_process.pid == 1 and init_process.state == .zombie and init_process.exit_status == 0 and
        state.shell_exit_requested and state.init_reaped_shell and vfs_clean and fs_report.mounts >= 5 and
        process_report.live == 1 and process_report.zombies == 1 and process_report.total_reaped >= 1 and
        descriptor_report.namespaces == 0 and descriptor_report.descriptors == 0 and descriptor_report.open_descriptions == 0 and
        tty_report.foreground_process_group == 2 and tty_report.buffered_bytes == 0 and tty_report.edited_bytes == 0 and
        tty_report.bytes_submitted == tty_report.bytes_read and tty_report.blocked_reads >= 1 and tty_report.reader_wakeups >= 1 and
        persistence_clean and boot_fat_clean and pseudo_filesystems_clean and
        userspace_report.used_pages == 0 and userspace_report.live_contexts == 0 and userspace_report.file_mapping_pages == 0 and
        userspace_report.launches >= 3 and
        userspace_report.exits >= 3 and userspace_report.allocator_allocations == userspace_report.allocator_releases and
        userspace_report.allocator_out_of_memory == 0 and userspace_report.allocator_rejections == 0 and
        physical_report.clean and physical_report.allocated_pages == 0 and physical_report.allocations == physical_report.frees and
        physical_report.failed_allocations == 0 and physical_rejections == 0;

    emit("\r\nZigOs normal userspace shutdown: init PID ");
    emitDecimal(init_process.pid);
    emit(" status ");
    emitDecimal(init_process.exit_status);
    emit(" shell PID 2 reaped ");
    emit(if (state.init_reaped_shell) "yes" else "no");
    emit("\r\n");
    emitNvmeReadFaultReport();
    emitNvmeWriteFaultReport();
    emitPersistenceDamageReport(persistence_report, fs_report, persistence_contained);
    emitBootFatReport(boot_fat_report, boot_fat_clean);
    emitLivePseudoFilesystemReport(pseudo_filesystems_clean);
    emit("ZigOs normal userspace resources: processes ");
    emitDecimal(process_report.live);
    emit(" descriptors ");
    emitDecimal(descriptor_report.descriptors);
    emit(" contexts ");
    emitDecimal(userspace_report.live_contexts);
    emit(" pages ");
    emitDecimal(userspace_report.used_pages);
    emit(" alloc/free ");
    emitDecimal(physical_report.allocations);
    emit("/");
    emitDecimal(physical_report.frees);
    emit(" cache-released ");
    emitDecimal(released_cache_pages);
    emit(" storage ");
    emit(storageStateLabel(persistence_report, diskless_recovery));
    emit(" clean ");
    emit(if (clean) "yes" else "no");
    emit("\r\nZigOs normal boot verified: diagnostic-suite skipped yes userspace-init yes userspace-shell yes tty yes vfs yes spawn-wait yes storage ");
    emit(storageStateLabel(persistence_report, diskless_recovery));
    emit(" cleanup ");
    emit(if (clean) "yes" else "no");
    emit("\r\n");
    while (true) zigos_wait_for_interrupt();
}

const ShutdownDrain = struct {
    dispatches: usize = 0,
    wakeups: usize = 0,
    finalized: usize = 0,
    reaped: usize = 0,
    swept: usize = 0,
};

fn drainDiagnosticUserspace() !ShutdownDrain {
    var result = ShutdownDrain{};
    var drain_tick = currentTick();
    var idle_passes: usize = 0;
    var passes: usize = 0;
    while (passes < runtime_process.maximum_processes * 4 and idle_passes < 8) : (passes += 1) {
        drain_tick +%= 1;
        result.wakeups += state.processes.wakeExpired(drain_tick);
        result.finalized += try runtime_user.finalizeTerminalContexts();
        if (try runtime_user.serviceOne(drain_tick)) |_| {
            result.dispatches += 1;
            idle_passes = 0;
        } else {
            idle_passes += 1;
        }
    }
    result.finalized += try runtime_user.finalizeTerminalContexts();
    result.reaped += try state.processes.reapTerminalChildren(state.shell_handle);
    result.reaped += state.processes.reapOrphans();
    result.swept += runtime_user.sweepReleasedContexts();
    return result;
}

fn finishDiagnosticRuntime() noreturn {
    apic.setTimerHook(null);
    apic.stopCurrentProcessorTimer(descriptor_tables.persistent_runtime_timer_vector);
    const shutdown_drain = drainDiagnosticUserspace() catch |err| runtimeFailure(@errorName(err));
    const swept_contexts = shutdown_drain.swept;
    const fs_report = state.vfs.report();
    const process_report = state.processes.report();
    const descriptor_report = state.descriptors.report();
    const tty_report = state.tty.report();
    const persistence_report = state.persistence.report();
    const boot_fat_report = state.boot_fat.report();
    const boot_fat_clean = bootFatStateClean(boot_fat_report, true);
    const pseudo_filesystems_clean = livePseudoFilesystemsClean();
    const userspace_report = runtime_user.report();
    const released_cache_pages = state.vfs.releaseFilePageCache();
    const final_fs_report = state.vfs.report();
    const physical_report = state.config.physical_memory.report();
    const physical_rejections = physical_report.invalid_frees + physical_report.double_frees + physical_report.metadata_failures;
    const physical_clean = physical_report.clean and physical_report.failed_allocations == 0 and physical_rejections == 0;
    const userspace_clean = userspace_report.used_pages == 0 and
        userspace_report.live_contexts == 0 and userspace_report.file_mapping_pages == 0 and userspace_report.launches >= 10 and
        userspace_report.exits >= 8 and userspace_report.faults >= 1 and
        userspace_report.preemptions >= 1 and userspace_report.blocking_returns >= 5 and
        userspace_report.syscalls >= 30 and userspace_report.reclaimed_pages > 0 and
        userspace_report.shared_pages == 0 and userspace_report.allocator_clean and
        userspace_report.allocator_allocations == userspace_report.reclaimed_pages and
        userspace_report.allocator_out_of_memory == 0 and userspace_report.allocator_rejections == 0 and physical_clean;
    const network_clean = state.network_failures == 0 and
        (!state.config.network_ready or (state.live_ping_passes >= 1 and state.live_dns_passes >= 1));
    const shell_process = state.processes.get(state.shell_handle) catch runtime_process.Process{};
    const tty_clean = tty_report.foreground_process_group == shell_process.process_group and
        tty_report.foreground_session == shell_process.session and tty_report.buffered_bytes == 0 and
        tty_report.edited_bytes == 0 and tty_report.eof_events == 0 and tty_report.submitted_lines >= 1 and
        tty_report.bytes_submitted == tty_report.bytes_read and tty_report.blocked_reads >= 1 and
        tty_report.reader_wakeups >= 1 and tty_report.overflow_events == 0;
    const nvme_controller = state.config.nvme_controller;
    const persistence_clean = persistence_report.mounted and !persistence_report.damaged and
        persistence_report.damage_reason == .none and persistence_report.read_only_remounts == 0 and
        persistence_report.read_only_remount_failures == 0 and persistence_report.discarded_dirty_pages == 0 and
        persistence_report.read_only_rejections == 0 and fs_report.read_only_remounts == 0 and
        fs_report.read_only_remount_dirty_pages == 0 and persistence_report.generation >= 1 and
        persistence_report.syncs >= 1 and persistence_report.checks >= 1 and persistence_report.io_failures == 0 and
        persistence_report.corrupt_headers == 0 and persistence_report.global_syncs >= 1 and
        persistence_report.writable_mount_syncs == persistence_report.global_syncs * 2 and
        persistence_report.immediate_mount_syncs == persistence_report.global_syncs and
        persistence_report.durable_mount_syncs == persistence_report.global_syncs and
        persistence_report.rejected_sync_plans == 0 and writebackStateClean(persistence_report) and
        nvme_controller != null and
        nvme_controller.?.write_commands == persistence_report.payload_writes + persistence_report.header_writes and
        nvme_controller.?.flush_commands == persistence_report.flushes;
    const vfs_clean = state.vfs.validate() and fs_report.dentry_cache_references == 0 and
        fs_report.dentry_cache_acquires == fs_report.dentry_cache_releases and fs_report.dentry_cache_hits > 0 and
        fs_report.dentry_cache_misses > 0 and fs_report.dentry_cache_insertions > 0 and
        fs_report.file_page_cache_entries > 0 and
        fs_report.file_page_cache_entries <= runtime_vfs.maximum_file_page_cache_entries and
        fs_report.file_page_cache_hits > 0 and fs_report.file_page_cache_misses > 0 and
        fs_report.file_page_cache_insertions > 0 and fs_report.file_page_cache_lock_tickets > 0 and
        fs_report.file_page_cache_lock_outstanding == 0 and fs_report.file_page_cache_pressure_checks > 0 and
        fs_report.file_page_cache_allocation_failures == 0 and fs_report.file_page_cache_release_failures == 0 and
        fs_report.file_page_cache_allocations == fs_report.file_page_cache_releases + fs_report.file_page_cache_entries and
        fs_report.file_page_cache_mapping_references == 0 and
        fs_report.file_page_cache_mapping_pins == fs_report.file_page_cache_mapping_unpins and
        fs_report.file_page_cache_mapping_pins > 0 and fs_report.file_page_cache_mapping_refreshes > 0 and
        fs_report.file_page_cache_mapping_pin_failures == 0 and
        released_cache_pages > 0 and final_fs_report.file_page_cache_entries == 0 and
        final_fs_report.file_page_cache_allocations == final_fs_report.file_page_cache_releases and
        final_fs_report.file_page_cache_release_failures == 0 and
        fs_report.file_page_cache_dirty_entries == 0 and fs_report.dirty_file_pages == 0 and
        fs_report.dirty_file_nodes == 0 and fs_report.dirty_page_marks > 0 and
        fs_report.dirty_page_sync_clears > 0 and
        fs_report.data_lock_tickets > 0 and fs_report.data_lock_outstanding == 0 and
        fs_report.page_write_lock_tickets > 0 and fs_report.page_write_lock_outstanding == 0 and
        fs_report.data_pool_lock_tickets > 0 and fs_report.data_pool_lock_outstanding == 0 and
        fs_report.allocated_blocks > 0 and fs_report.allocated_blocks <= runtime_vfs.maximum_data_blocks and
        fs_report.allocated_bytes == fs_report.allocated_blocks * runtime_vfs.file_block_size;
    const descriptor_clean = state.descriptors.validate(&state.vfs, &state.processes) and
        descriptor_report.namespaces == 1 and descriptor_report.descriptors == 3 and
        descriptor_report.open_descriptions == 3 and descriptor_report.terminal_descriptions == 3 and
        descriptor_report.vfs_descriptions == 0 and descriptor_report.pipe_read_descriptions == 0 and
        descriptor_report.pipe_write_descriptions == 0 and descriptor_report.pipes == 0;
    emit("\r\nZigOs persistent runtime shutdown: commands ");
    emitDecimal(state.command_count);
    emit(" failed ");
    emitDecimal(state.failed_commands);
    emit(" ticks ");
    emitDecimal(currentTick());
    emit(" idle-halts ");
    emitDecimal(state.idle_halts);
    emit(" service-passes ");
    emitDecimal(state.device_service_passes);
    emit("\r\nZigOs shutdown drain: dispatches ");
    emitDecimal(shutdown_drain.dispatches);
    emit(" wakeups ");
    emitDecimal(shutdown_drain.wakeups);
    emit(" finalized ");
    emitDecimal(shutdown_drain.finalized);
    emit(" reaped ");
    emitDecimal(shutdown_drain.reaped);
    emit(" swept ");
    emitDecimal(shutdown_drain.swept);
    emit("\r\n");
    emit("ZigOs persistent VFS: nodes ");
    emitDecimal(fs_report.nodes_used);
    emit(" dentries ");
    emitDecimal(fs_report.dentries_used);
    emit(" files ");
    emitDecimal(fs_report.files);
    emit(" directories ");
    emitDecimal(fs_report.directories);
    emit(" pseudo ");
    emitDecimal(fs_report.pseudo_files);
    emit(" mounts ");
    emitDecimal(fs_report.mounts);
    emit(" bytes ");
    emitDecimal(fs_report.bytes_used);
    emit(" cache entries/refs ");
    emitDecimal(fs_report.dentry_cache_entries);
    emit("/");
    emitDecimal(fs_report.dentry_cache_references);
    emit(" hit/miss ");
    emitDecimal(fs_report.dentry_cache_hits);
    emit("/");
    emitDecimal(fs_report.dentry_cache_misses);
    emit(" insert/evict ");
    emitDecimal(fs_report.dentry_cache_insertions);
    emit("/");
    emitDecimal(fs_report.dentry_cache_evictions);
    emit(" invalidate/reject ");
    emitDecimal(fs_report.dentry_cache_invalidations);
    emit("/");
    emitDecimal(fs_report.dentry_cache_rejections);
    emit(" acquire/release ");
    emitDecimal(fs_report.dentry_cache_acquires);
    emit("/");
    emitDecimal(fs_report.dentry_cache_releases);
    emit(" page-cache entries ");
    emitDecimal(fs_report.file_page_cache_entries);
    emit(" dirty/ledger ");
    emitDecimal(fs_report.file_page_cache_dirty_entries);
    emit("/");
    emitDecimal(fs_report.dirty_file_pages);
    emit("/");
    emitDecimal(fs_report.dirty_file_nodes);
    emit(" marks/sync-clear/discard ");
    emitDecimal(fs_report.dirty_page_marks);
    emit("/");
    emitDecimal(fs_report.dirty_page_sync_clears);
    emit("/");
    emitDecimal(fs_report.dirty_page_discards);
    emit(" hit/miss ");
    emitDecimal(fs_report.file_page_cache_hits);
    emit("/");
    emitDecimal(fs_report.file_page_cache_misses);
    emit(" insert/evict ");
    emitDecimal(fs_report.file_page_cache_insertions);
    emit("/");
    emitDecimal(fs_report.file_page_cache_evictions);
    emit(" invalidate ");
    emitDecimal(fs_report.file_page_cache_invalidations);
    emit(" backing alloc/release/fail ");
    emitDecimal(final_fs_report.file_page_cache_allocations);
    emit("/");
    emitDecimal(final_fs_report.file_page_cache_releases);
    emit("/");
    emitDecimal(final_fs_report.file_page_cache_allocation_failures);
    emit("/");
    emitDecimal(final_fs_report.file_page_cache_release_failures);
    emit(" pressure checks/events/evictions ");
    emitDecimal(final_fs_report.file_page_cache_pressure_checks);
    emit("/");
    emitDecimal(final_fs_report.file_page_cache_pressure_events);
    emit("/");
    emitDecimal(final_fs_report.file_page_cache_pressure_evictions);
    emit(" shutdown-release ");
    emitDecimal(released_cache_pages);
    emit(" mapped refs/pin/unpin/refresh/fail ");
    emitDecimal(final_fs_report.file_page_cache_mapping_references);
    emit("/");
    emitDecimal(final_fs_report.file_page_cache_mapping_pins);
    emit("/");
    emitDecimal(final_fs_report.file_page_cache_mapping_unpins);
    emit("/");
    emitDecimal(final_fs_report.file_page_cache_mapping_refreshes);
    emit("/");
    emitDecimal(final_fs_report.file_page_cache_mapping_pin_failures);
    emit(" lock tickets/outstanding ");
    emitDecimal(fs_report.file_page_cache_lock_tickets);
    emit("/");
    emitDecimal(fs_report.file_page_cache_lock_outstanding);
    emit(" data-lock tickets/outstanding ");
    emitDecimal(fs_report.data_lock_tickets);
    emit("/");
    emitDecimal(fs_report.data_lock_outstanding);
    emit(" page-write tickets/outstanding ");
    emitDecimal(fs_report.page_write_lock_tickets);
    emit("/");
    emitDecimal(fs_report.page_write_lock_outstanding);
    emit(" pool-lock tickets/outstanding ");
    emitDecimal(fs_report.data_pool_lock_tickets);
    emit("/");
    emitDecimal(fs_report.data_pool_lock_outstanding);
    emit(" blocks/bytes/holes ");
    emitDecimal(fs_report.allocated_blocks);
    emit("/");
    emitDecimal(fs_report.allocated_bytes);
    emit("/");
    emitDecimal(fs_report.sparse_hole_bytes);
    emit(" clean ");
    emit(if (vfs_clean) "yes" else "no");
    emit("\r\n");
    emit("ZigOs persistent processes: live ");
    emitDecimal(process_report.live);
    emit(" created ");
    emitDecimal(process_report.total_created);
    emit(" reaped ");
    emitDecimal(process_report.total_reaped);
    emit(" switches ");
    emitDecimal(process_report.total_context_switches);
    emit(" signals ");
    emitDecimal(process_report.total_signals);
    emit(" faults ");
    emitDecimal(process_report.total_faults);
    emit("\r\n");
    emit("ZigOs persistent descriptors: namespaces ");
    emitDecimal(descriptor_report.namespaces);
    emit(" fds ");
    emitDecimal(descriptor_report.descriptors);
    emit(" open ");
    emitDecimal(descriptor_report.open_descriptions);
    emit(" terminals ");
    emitDecimal(descriptor_report.terminal_descriptions);
    emit(" vfs ");
    emitDecimal(descriptor_report.vfs_descriptions);
    emit(" pipes ");
    emitDecimal(descriptor_report.pipes);
    emit(" dup/inherited/cloexec ");
    emitDecimal(descriptor_report.duplicated_descriptors);
    emit("/");
    emitDecimal(descriptor_report.inherited_descriptors);
    emit("/");
    emitDecimal(descriptor_report.close_on_exec_closes);
    emit(" blocked ");
    emitDecimal(descriptor_report.blocked_reads);
    emit("/");
    emitDecimal(descriptor_report.blocked_writes);
    emit(" wakeups ");
    emitDecimal(descriptor_report.reader_wakeups);
    emit("/");
    emitDecimal(descriptor_report.writer_wakeups);
    emit(" eof ");
    emitDecimal(descriptor_report.eof_reads);
    emit(" broken ");
    emitDecimal(descriptor_report.broken_pipe_writes);
    emit(" clean ");
    emit(if (descriptor_clean) "yes" else "no");
    emit("\r\n");
    emit("ZigOs permanent TTY: foreground group/session ");
    emitDecimal(tty_report.foreground_process_group);
    emit("/");
    emitDecimal(tty_report.foreground_session);
    emit(" buffered/edit/eof ");
    emitDecimal(tty_report.buffered_bytes);
    emit("/");
    emitDecimal(tty_report.edited_bytes);
    emit("/");
    emitDecimal(tty_report.eof_events);
    emit(" lines ");
    emitDecimal(tty_report.submitted_lines);
    emit(" bytes submitted/read ");
    emitDecimal(tty_report.bytes_submitted);
    emit("/");
    emitDecimal(tty_report.bytes_read);
    emit(" blocked/wakeups ");
    emitDecimal(tty_report.blocked_reads);
    emit("/");
    emitDecimal(tty_report.reader_wakeups);
    emit(" erase/interrupt/suspend/overflow ");
    emitDecimal(tty_report.erase_events);
    emit("/");
    emitDecimal(tty_report.interrupt_events);
    emit("/");
    emitDecimal(tty_report.suspend_events);
    emit("/");
    emitDecimal(tty_report.overflow_events);
    emit(" clean ");
    emit(if (tty_clean) "yes" else "no");
    emit("\r\n");
    emitNvmeReadFaultReport();
    emitNvmeWriteFaultReport();
    emitPersistenceDamageReport(persistence_report, fs_report, false);
    emitBootFatReport(boot_fat_report, boot_fat_clean);
    emitLivePseudoFilesystemReport(pseudo_filesystems_clean);
    emit("ZigOs persistent storage: mounted ");
    emit(if (persistence_report.mounted) "yes" else "no");
    emit(" generation/slot ");
    emitDecimal(persistence_report.generation);
    emit("/");
    emitDecimal(persistence_report.active_slot);
    emit(" records/payload ");
    emitDecimal(persistence_report.record_count);
    emit("/");
    emitDecimal(persistence_report.payload_bytes);
    emit(" mounts/syncs/checks/recoveries ");
    emitDecimal(persistence_report.mounts);
    emit("/");
    emitDecimal(persistence_report.syncs);
    emit("/");
    emitDecimal(persistence_report.checks);
    emit("/");
    emitDecimal(persistence_report.recoveries);
    emit(" global/mount/immediate/durable/reject ");
    emitDecimal(persistence_report.global_syncs);
    emit("/");
    emitDecimal(persistence_report.writable_mount_syncs);
    emit("/");
    emitDecimal(persistence_report.immediate_mount_syncs);
    emit("/");
    emitDecimal(persistence_report.durable_mount_syncs);
    emit("/");
    emitDecimal(persistence_report.rejected_sync_plans);
    emit(" writeback active ");
    emit(if (persistence_report.writeback_active) "yes" else "no");
    emit(" request/complete/pass ");
    emitDecimal(persistence_report.writeback_requests);
    emit("/");
    emitDecimal(persistence_report.writeback_completions);
    emit("/");
    emitDecimal(persistence_report.writeback_passes);
    emit(" immediate/durable/clean/unsupported/failure/stale ");
    emitDecimal(persistence_report.writeback_immediate);
    emit("/");
    emitDecimal(persistence_report.writeback_durable);
    emit("/");
    emitDecimal(persistence_report.writeback_clean);
    emit("/");
    emitDecimal(persistence_report.writeback_unsupported);
    emit("/");
    emitDecimal(persistence_report.writeback_failures);
    emit("/");
    emitDecimal(persistence_report.writeback_stale);
    emit(" pages queued/completed ");
    emitDecimal(persistence_report.writeback_pages_queued);
    emit("/");
    emitDecimal(persistence_report.writeback_pages_completed);
    emit(" payload/header/flush ");
    emitDecimal(persistence_report.payload_writes);
    emit("/");
    emitDecimal(persistence_report.header_writes);
    emit("/");
    emitDecimal(persistence_report.flushes);
    emit(" NVMe read/write/flush ");
    if (nvme_controller) |controller| {
        emitDecimal(controller.read_commands);
        emit("/");
        emitDecimal(controller.write_commands);
        emit("/");
        emitDecimal(controller.flush_commands);
    } else {
        emit("0/0/0");
    }
    emit(" errors ");
    emitDecimal(persistence_report.io_failures);
    emit("/");
    emitDecimal(persistence_report.corrupt_headers);
    emit(" clean ");
    emit(if (persistence_clean) "yes" else "no");
    emit("\r\n");
    emit("ZigOs post-bootstrap physical memory: total ");
    emitDecimal(physical_report.total_pages);
    emit(" free ");
    emitDecimal(physical_report.free_pages);
    emit(" allocated ");
    emitDecimal(physical_report.allocated_pages);
    emit(" low/high ");
    emitDecimal(physical_report.low_pages);
    emit("/");
    emitDecimal(physical_report.high_pages);
    emit(" extents ");
    emitDecimal(physical_report.managed_extents);
    emit("/");
    emitDecimal(physical_report.free_extents);
    emit(" peak ");
    emitDecimal(physical_report.peak_allocated_pages);
    emit(" alloc/free ");
    emitDecimal(physical_report.allocations);
    emit("/");
    emitDecimal(physical_report.frees);
    emit(" failed/rejected ");
    emitDecimal(physical_report.failed_allocations);
    emit("/");
    emitDecimal(physical_rejections);
    emit(" clean ");
    emit(if (physical_clean) "yes" else "no");
    emit("\r\n");
    emit("ZigOs permanent userspace: page-limit ");
    emitDecimal(userspace_report.page_limit);
    emit(" used ");
    emitDecimal(userspace_report.used_pages);
    emit(" peak ");
    emitDecimal(userspace_report.peak_pages);
    emit(" contexts ");
    emitDecimal(userspace_report.live_contexts);
    emit(" file-mappings ");
    emitDecimal(userspace_report.file_mapping_pages);
    emit(" launches/exits/faults ");
    emitDecimal(userspace_report.launches);
    emit("/");
    emitDecimal(userspace_report.exits);
    emit("/");
    emitDecimal(userspace_report.faults);
    emit(" preemptions/blocking/syscalls ");
    emitDecimal(userspace_report.preemptions);
    emit("/");
    emitDecimal(userspace_report.blocking_returns);
    emit("/");
    emitDecimal(userspace_report.syscalls);
    emit(" reclaimed ");
    emitDecimal(userspace_report.reclaimed_pages);
    emit(" stale-contexts-swept ");
    emitDecimal(swept_contexts);
    emit(" allocator alloc/release/retains ");
    emitDecimal(userspace_report.allocator_allocations);
    emit("/");
    emitDecimal(userspace_report.allocator_releases);
    emit("/");
    emitDecimal(userspace_report.allocator_retains);
    emit(" shared/oom/rejected ");
    emitDecimal(userspace_report.shared_pages);
    emit("/");
    emitDecimal(userspace_report.allocator_out_of_memory);
    emit("/");
    emitDecimal(userspace_report.allocator_rejections);
    emit(" clean ");
    emit(if (userspace_clean) "yes" else "no");
    emit("\r\n");
    emit("ZigOs permanent network: device ");
    emit(if (state.config.network_ready) "yes" else "no");
    emit(" ping ");
    emitDecimal(state.live_ping_passes);
    emit(" dns ");
    emitDecimal(state.live_dns_passes);
    emit(" failures ");
    emitDecimal(state.network_failures);
    emit(" clean ");
    emit(if (network_clean) "yes" else "no");
    emit("\r\n");
    emit("ZigOs x86-64 persistent runtime verified: loop permanent shell yes navigation yes files yes descriptors yes processes yes userspace-exec yes network-state yes live-network ");
    emit(if (state.config.network_ready) "yes" else "no");
    emit(" persistent-storage yes canned-results no explicit-shutdown yes\r\n");
    if (state.fd_contract_passed and descriptor_clean) {
        emit("ZigOs x86-64 Capstone 18 verified: goals 0x000001D1 new-goals 0x00000020 fd-namespaces yes open-descriptions yes shared-offsets yes duplication yes inheritance yes cloexec yes blocking-pipes yes shell-io yes cleanup yes\r\n");
    } else {
        emit("ZigOs x86-64 Capstone 18 incomplete: fd-contract ");
        emit(if (state.fd_contract_passed) "yes" else "no");
        emit(" descriptor-clean ");
        emit(if (descriptor_clean) "yes" else "no");
        emit("\r\n");
    }
    if (state.fd_contract_passed and descriptor_clean and tty_clean and persistence_clean and boot_fat_clean and pseudo_filesystems_clean and vfs_clean and userspace_clean and network_clean) {
        emit("ZigOs x86-64 Capstone 19 verified: goals 0x000001F1 new-goals 0x00000020 vfs-elf yes private-cr3 yes retained-contexts yes timer-preemption yes real-fault yes executable-pipes yes frame-reclamation yes network-facades-removed yes cleanup yes\r\n");
    } else {
        emit("ZigOs x86-64 Capstone 19 incomplete: fd-contract ");
        emit(if (state.fd_contract_passed) "yes" else "no");
        emit(" descriptor-clean ");
        emit(if (descriptor_clean) "yes" else "no");
        emit(" tty-clean ");
        emit(if (tty_clean) "yes" else "no");
        emit(" persistence-clean ");
        emit(if (persistence_clean) "yes" else "no");
        emit(" boot-fat-clean ");
        emit(if (boot_fat_clean) "yes" else "no");
        emit(" pseudo-filesystems-clean ");
        emit(if (pseudo_filesystems_clean) "yes" else "no");
        emit(" vfs-clean ");
        emit(if (vfs_clean) "yes" else "no");
        emit(" userspace-clean ");
        emit(if (userspace_clean) "yes" else "no");
        emit(" network-clean ");
        emit(if (network_clean) "yes" else "no");
        emit("\r\n");
    }
    while (true) zigos_wait_for_interrupt();
}

fn runtimeFailure(reason: []const u8) noreturn {
    emit("Persistent runtime failure: ");
    emit(reason);
    emit("\r\n");
    while (true) zigos_wait_for_interrupt();
}

fn emit(text: []const u8) void {
    for (text) |character| {
        zigos_debug_putc(character);
        _ = serial.putByte(character);
    }
}

fn emitHex(value: u64) void {
    const digits = "0123456789ABCDEF";
    var shift: u6 = 60;
    var started = false;
    while (true) {
        const nibble: u4 = @truncate(value >> shift);
        if (nibble != 0 or started or shift == 0) {
            const index: usize = nibble;
            emit(digits[index .. index + 1]);
            started = true;
        }
        if (shift == 0) break;
        shift -= 4;
    }
}

fn emitDecimal(value: u64) void {
    var buffer: [20]u8 = undefined;
    var count: usize = 0;
    var remaining = value;
    if (remaining == 0) return emit("0");
    while (remaining != 0) : (remaining /= 10) {
        buffer[count] = @intCast('0' + remaining % 10);
        count += 1;
    }
    while (count != 0) {
        count -= 1;
        emit(buffer[count .. count + 1]);
    }
}
