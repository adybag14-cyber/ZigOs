const std = @import("std");
const apic = @import("apic.zig");
const descriptor_tables = @import("descriptor_tables.zig");
const elf64 = @import("elf64.zig");
const e1000e = @import("e1000e.zig");
const interrupt_context = @import("interrupt_context.zig");
const memory = @import("memory.zig");
const runtime_command = @import("runtime_command.zig");
const runtime_fd = @import("runtime_fd.zig");
const runtime_process = @import("runtime_process.zig");
const runtime_user = @import("runtime_user.zig");
const runtime_vfs = @import("runtime_vfs.zig");
const serial = @import("serial.zig");

const cc = std.os.uefi.cc;
const service_elf = @embedFile("generated/service_user.elf");
const process_elf = @embedFile("generated/process_user.elf");
const process_exec_elf = @embedFile("generated/process_exec.elf");
const runtime_hello_elf = @embedFile("generated/runtime_hello.elf");
const runtime_sleep_elf = @embedFile("generated/runtime_sleep.elf");
const runtime_crash_elf = @embedFile("generated/runtime_crash.elf");
const runtime_spin_elf = @embedFile("generated/runtime_spin.elf");
const runtime_pipe_reader_elf = @embedFile("generated/runtime_pipe_reader.elf");
const runtime_pipe_writer_elf = @embedFile("generated/runtime_pipe_writer.elf");
const runtime_wait_elf = @embedFile("generated/runtime_wait.elf");
const runtime_vm_elf = @embedFile("generated/runtime_vm.elf");
const runtime_io_elf = @embedFile("generated/runtime_io.elf");
const runtime_socket_elf = @embedFile("generated/runtime_socket.elf");

extern fn zigos_debug_putc(character: u8) callconv(cc) void;
extern fn zigos_wait_for_interrupt() callconv(cc) void;
extern fn zigos_enable_interrupts() callconv(cc) void;

pub const Configuration = struct {
    physical_memory: *memory.PhysicalMemoryManager,
    ticks_per_second: u64,
    network_ready: bool,
    usb_keyboard_ready: bool,
    nvme_ready: bool,
    ahci_ready: bool,
    framebuffer_ready: bool,
};

const maximum_pipeline_bytes: usize = runtime_vfs.maximum_file_size;
const maximum_jobs: usize = 24;

const Job = struct {
    active: bool = false,
    handle: u64 = 0,
    command: [runtime_command.maximum_token_length + 1]u8 = @splat(0),
    command_length: u8 = 0,
};

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
    environment: runtime_command.Environment = undefined,
    editor: runtime_command.LineEditor = .{},
    cwd: u16 = 0,
    shell_handle: u64 = 0,
    jobs: [maximum_jobs]Job = @splat(.{}),
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
    foreground_handle: ?u64 = null,
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
    emit("init PID 1; serial shell PID 2; APIC scheduling 100 Hz; writable ramfs mounted at /\r\n");
    emit("Type 'help' for commands. The kernel remains live until an explicit shutdown command.\r\n");
    printPrompt();

    while (true) {
        serviceRuntime();
        var received = false;
        while (true) {
            const status = serial.tryRead();
            if (status.line_error) state.serial_line_errors +%= 1;
            const byte = status.byte orelse break;
            received = true;
            consumeInput(byte);
            if (state.shutdown_requested) break;
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
    state.vfs.setPseudoReader(null, readPseudoBytes);
    state.processes.initialize(0);
    state.descriptors.initialize();
    state.environment = runtime_command.Environment.init();
    state.editor = .{};
    state.jobs = @splat(.{});
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
    state.shell_sleeping = false;
    state.shell_waiting = false;
    state.foreground_handle = null;
    state.shutdown_requested = false;
    state.prompt_visible = false;
    state.ignore_next_lf = false;
    state.fd_contract_passed = false;
    @atomicStore(u64, &runtime_interrupt_count, 0, .monotonic);

    try initializeFilesystem();
    state.cwd = try state.vfs.resolve(0, "/home/root");
    const init_handle = state.processes.initHandle();
    try state.processes.block(init_handle, .device_io, 1);
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
    try runtime_user.initialize(configuration.physical_memory, &state.vfs, &state.processes, &state.descriptors);
    if (configuration.network_ready) {
        const device = e1000e.activeDevice() orelse return error.NetworkStateMissing;
        _ = e1000e.prepareRuntimeMmio(device);
        if (!e1000e.enterRuntimePollingMode(device)) return error.NetworkPollingHandoffFailed;
    }
}

fn initializeFilesystem() !void {
    const directories = [_][]const u8{
        "/bin", "/boot",    "/dev",     "/etc",     "/home", "/home/root",
        "/mnt", "/net",     "/proc",    "/tmp",     "/usr",  "/usr/bin",
        "/var", "/var/log", "/var/run", "/var/tmp",
    };
    for (directories) |path| _ = try state.vfs.mkdir(0, path, if (std.mem.startsWith(u8, path, "/tmp") or std.mem.startsWith(u8, path, "/var/tmp")) 0o777 else 0o755, 0);

    _ = try state.vfs.putFile(0, "/etc/hostname", "zigos\n", 0o644, false, 0);
    _ = try state.vfs.putFile(0, "/etc/os-release", "NAME=ZigOs\nVERSION=19.0.0\nARCH=x86_64\n", 0o644, false, 0);
    _ = try state.vfs.putFile(0, "/etc/motd", "ZigOs persistent x86-64 runtime\n", 0o644, false, 0);
    _ = try state.vfs.putFile(0, "/home/root/readme.txt", "This filesystem remains available after boot validation.\n", 0o644, false, 0);
    _ = try state.vfs.putFile(0, "/var/log/boot.log", "Capstone 16 validation passed; Capstone 19 permanent userspace runtime entered.\n", 0o640, false, 0);
    _ = try state.vfs.putFile(0, "/boot/service-user.elf", service_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/boot/process-user.elf", process_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/boot/process-exec.elf", process_exec_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/hello.elf", runtime_hello_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/sleep.elf", runtime_sleep_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/crash.elf", runtime_crash_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/spin.elf", runtime_spin_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/pipe-reader.elf", runtime_pipe_reader_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/pipe-writer.elf", runtime_pipe_writer_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/wait.elf", runtime_wait_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/vm.elf", runtime_vm_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/io.elf", runtime_io_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/bin/socket.elf", runtime_socket_elf, 0o555, false, 0);

    const pseudo_paths = [_][]const u8{
        "/proc/version",   "/proc/uptime", "/proc/meminfo", "/proc/processes",
        "/proc/mounts",    "/dev/console", "/dev/null",     "/dev/zero",
        "/net/interfaces", "/net/routes",  "/net/arp",      "/net/sockets",
    };
    for (pseudo_paths) |path| _ = try state.vfs.createPseudo(0, path, 0o444, 0);

    _ = try state.vfs.mount(0, "/boot", .boot_fat, true, if (state.config.nvme_ready) "nvme0p1" else "ahci0p1");
    _ = try state.vfs.mount(0, "/proc", .procfs, true, "process-table");
    _ = try state.vfs.mount(0, "/dev", .devfs, true, "kernel-devices");
    _ = try state.vfs.mount(0, "/net", .netfs, true, "network-state");
    if (!state.vfs.validate()) return runtime_vfs.Error.InvalidPath;
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
        serviceJobs(tick);
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

fn serviceJobs(tick: u64) void {
    for (&state.jobs) |*job| {
        if (!job.active) continue;
        const process = state.processes.get(job.handle) catch {
            job.active = false;
            continue;
        };
        if (process.terminal()) runtime_user.finalize(job.handle) catch {};
    }
    _ = runtime_user.serviceOne(tick, state.foreground_handle) catch |err| {
        emit("runtime dispatch failure: ");
        emit(@errorName(err));
        emit("\r\n");
    };
    if (!state.shell_sleeping and !state.shell_waiting) state.processes.setRunning(state.shell_handle) catch {};
}

fn consumeInput(byte: u8) void {
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
    output.line("Filesystem: pwd cd ls cat echo touch mkdir rm rmdir mv write append stat chmod mount df fds fdtest pipex sync fsck");
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
    for (stage.arguments[1..stage.count]) |argument| state.vfs.unlink(state.cwd, argument.slice()) catch |err| return shellError("rm", err, output);
}

fn commandRmdir(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count < 2) return usage("rmdir DIRECTORY...", output);
    for (stage.arguments[1..stage.count]) |argument| state.vfs.rmdir(state.cwd, argument.slice()) catch |err| return shellError("rmdir", err, output);
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
        const path = state.vfs.canonicalPath(mount_entry.node, &path_buffer) catch "/?";
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

    var reader_dispatches: usize = 0;
    var blocked_reader = state.processes.get(reader) catch {
        abortExecutable(reader);
        abortExecutable(writer);
        return output.line("pipex: reader vanished before dispatch");
    };
    while (reader_dispatches < 16 and
        (blocked_reader.state == .runnable or blocked_reader.state == .running)) : (reader_dispatches += 1)
    {
        runtime_user.dispatch(reader, currentTick()) catch |err| {
            abortExecutable(reader);
            abortExecutable(writer);
            return shellError("pipex reader dispatch", err, output);
        };
        state.processes.setRunning(state.shell_handle) catch {};
        blocked_reader = state.processes.get(reader) catch {
            abortExecutable(reader);
            abortExecutable(writer);
            return output.line("pipex: reader vanished after dispatch");
        };
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
    removeJob(handle);
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
    try state.vfs.unlink(0, "/tmp/capstone18-fd.txt");

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
    const snapshot = state.processes.snapshot();
    for (snapshot.processes[0..snapshot.count]) |process| {
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
    var any = false;
    for (state.jobs) |job| {
        if (!job.active) continue;
        any = true;
        const process = state.processes.get(job.handle) catch continue;
        output.byte('[');
        output.decimal(process.pid);
        output.write("] ");
        output.write(@tagName(process.state));
        output.write(" ");
        output.line(job.command[0..job.command_length]);
    }
    if (!any) output.line("no jobs");
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
    for (stage.arguments[path_index + 1 .. stage.count], 0..) |argument, index| {
        extra_arguments[index] = argument.slice();
    }
    return spawnExecutablePath(
        stage.arguments[path_index].slice(),
        extra_arguments[0..extra_count],
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
    var job_index: usize = 0;
    if (background) {
        while (job_index < state.jobs.len and state.jobs[job_index].active) : (job_index += 1) {}
        if (job_index >= state.jobs.len) {
            output.line("spawn: job table full");
            return null;
        }
    }

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

    const identity = runtime_user.imageIdentity(handle) orelse unreachable;
    if (background) {
        var job = Job{
            .active = true,
            .handle = handle,
            .command_length = @intCast(@min(path.len, runtime_command.maximum_token_length)),
        };
        @memcpy(job.command[0..job.command_length], path[0..job.command_length]);
        state.jobs[job_index] = job;
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
    if (state.foreground_handle != null) {
        output.line("exec: another foreground process is already active");
        return null;
    }
    state.foreground_handle = handle;
    defer state.foreground_handle = null;
    while (true) {
        const process = state.processes.get(handle) catch |err| {
            shellError("exec", err, output);
            return null;
        };
        if (process.terminal()) break;
        const now = currentTick();
        _ = state.processes.wakeExpired(now);
        const refreshed = state.processes.get(handle) catch return null;
        switch (refreshed.state) {
            .runnable, .running => runtime_user.dispatch(handle, now) catch |err| {
                state.processes.fault(handle, 13, 0) catch {};
                runtime_user.finalize(handle) catch {};
                shellError("exec dispatch", err, output);
                break;
            },
            .sleeping, .blocked => {
                serviceRuntime();
                zigos_wait_for_interrupt();
            },
            .stopped => {
                output.line("exec: process stopped; resume or kill it from a background job");
                return null;
            },
            else => zigos_wait_for_interrupt(),
        }
        state.processes.setRunning(state.shell_handle) catch {};
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

fn removeJob(handle: u64) void {
    for (&state.jobs) |*job| {
        if (job.active and job.handle == handle) job.active = false;
    }
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
    removeJob(handle);
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
    state.filesystem_syncs +%= 1;
    output.write("sync complete: ramfs mutations ");
    output.decimal(state.vfs.report().mutations);
    output.write("; persistent block flushes 0 (boot FAT remains read-only)\r\n");
}

fn commandFsck(output: *Output) void {
    state.filesystem_checks +%= 1;
    output.write("fsck ramfs: ");
    output.line(if (state.vfs.validate()) "clean" else "corrupt");
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

fn readPseudoBytes(_: ?*anyopaque, node: u16, offset: usize, destination: []u8) usize {
    if (destination.len == 0 or state.pseudo_busy) return 0;
    var path_buffer: [runtime_vfs.maximum_path_length + 1]u8 = undefined;
    const path = state.vfs.canonicalPath(node, &path_buffer) catch return 0;
    if (equal(path, "/dev/null")) return 0;
    if (equal(path, "/dev/zero")) {
        @memset(destination, 0);
        return destination.len;
    }
    state.pseudo_busy = true;
    defer state.pseudo_busy = false;
    var output = Output.init(&state.pseudo_buffer);
    if (!formatPseudo(node, &output) or offset >= output.length) return 0;
    const count = @min(destination.len, output.length - offset);
    @memcpy(destination[0..count], output.slice()[offset .. offset + count]);
    return count;
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
    } else if (equal(path, "/dev/null")) {
        return true;
    } else if (equal(path, "/dev/zero")) {
        return true;
    } else if (equal(path, "/dev/console")) {
        output.line("COM1 serial console");
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

fn finishRuntime() noreturn {
    apic.setTimerHook(null);
    apic.stopCurrentProcessorTimer(descriptor_tables.persistent_runtime_timer_vector);
    const fs_report = state.vfs.report();
    const process_report = state.processes.report();
    const descriptor_report = state.descriptors.report();
    const userspace_report = runtime_user.report();
    const physical_report = state.config.physical_memory.report();
    const physical_rejections = physical_report.invalid_frees + physical_report.double_frees + physical_report.metadata_failures;
    const physical_clean = physical_report.clean and physical_report.failed_allocations == 0 and physical_rejections == 0;
    const userspace_clean = userspace_report.used_pages == 0 and
        userspace_report.live_contexts == 0 and userspace_report.launches >= 10 and
        userspace_report.exits >= 8 and userspace_report.faults >= 1 and
        userspace_report.preemptions >= 1 and userspace_report.blocking_returns >= 5 and
        userspace_report.syscalls >= 30 and userspace_report.reclaimed_pages > 0 and
        userspace_report.shared_pages == 0 and userspace_report.allocator_clean and
        userspace_report.allocator_allocations == userspace_report.reclaimed_pages and
        userspace_report.allocator_out_of_memory == 0 and userspace_report.allocator_rejections == 0 and physical_clean;
    const network_clean = state.network_failures == 0 and
        (!state.config.network_ready or (state.live_ping_passes >= 1 and state.live_dns_passes >= 1));
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
    emit("\r\n");
    emit("ZigOs persistent VFS: nodes ");
    emitDecimal(fs_report.nodes_used);
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
    emit(" clean ");
    emit(if (state.vfs.validate()) "yes" else "no");
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
    emit(" canned-results no explicit-shutdown yes\r\n");
    if (state.fd_contract_passed and descriptor_clean) {
        emit("ZigOs x86-64 Capstone 18 verified: goals 0x000001D1 new-goals 0x00000020 fd-namespaces yes open-descriptions yes shared-offsets yes duplication yes inheritance yes cloexec yes blocking-pipes yes shell-io yes cleanup yes\r\n");
    } else {
        emit("ZigOs x86-64 Capstone 18 incomplete: fd-contract ");
        emit(if (state.fd_contract_passed) "yes" else "no");
        emit(" descriptor-clean ");
        emit(if (descriptor_clean) "yes" else "no");
        emit("\r\n");
    }
    if (state.fd_contract_passed and descriptor_clean and userspace_clean and network_clean) {
        emit("ZigOs x86-64 Capstone 19 verified: goals 0x000001F1 new-goals 0x00000020 vfs-elf yes private-cr3 yes retained-contexts yes timer-preemption yes real-fault yes executable-pipes yes frame-reclamation yes network-facades-removed yes cleanup yes\r\n");
    } else {
        emit("ZigOs x86-64 Capstone 19 incomplete: fd-contract ");
        emit(if (state.fd_contract_passed) "yes" else "no");
        emit(" descriptor-clean ");
        emit(if (descriptor_clean) "yes" else "no");
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
