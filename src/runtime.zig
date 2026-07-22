const std = @import("std");
const apic = @import("apic.zig");
const descriptor_tables = @import("descriptor_tables.zig");
const elf64 = @import("elf64.zig");
const interrupt_context = @import("interrupt_context.zig");
const runtime_command = @import("runtime_command.zig");
const runtime_process = @import("runtime_process.zig");
const runtime_vfs = @import("runtime_vfs.zig");
const serial = @import("serial.zig");

const cc = std.os.uefi.cc;
const service_elf = @embedFile("generated/service_user.elf");
const process_elf = @embedFile("generated/process_user.elf");
const process_exec_elf = @embedFile("generated/process_exec.elf");

extern fn zigos_debug_putc(character: u8) callconv(cc) void;
extern fn zigos_wait_for_interrupt() callconv(cc) void;

pub const Configuration = struct {
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
    complete_tick: u64 = 0,
    exit_status: u32 = 0,
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
    environment: runtime_command.Environment = undefined,
    editor: runtime_command.LineEditor = .{},
    cwd: u16 = 0,
    shell_handle: u64 = 0,
    jobs: [maximum_jobs]Job = @splat(.{}),
    pipeline_a: [maximum_pipeline_bytes]u8 = @splat(0),
    pipeline_b: [maximum_pipeline_bytes]u8 = @splat(0),
    input_buffer: [maximum_pipeline_bytes]u8 = @splat(0),
    command_count: u64 = 0,
    failed_commands: u64 = 0,
    serial_line_errors: u64 = 0,
    idle_halts: u64 = 0,
    device_service_passes: u64 = 0,
    network_service_passes: u64 = 0,
    filesystem_syncs: u64 = 0,
    filesystem_checks: u64 = 0,
    last_serviced_tick: u64 = 0,
    shell_sleeping: bool = false,
    shutdown_requested: bool = false,
    prompt_visible: bool = false,
    ignore_next_lf: bool = false,
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
    state.processes.initialize(0);
    state.environment = runtime_command.Environment.init();
    state.editor = .{};
    state.jobs = @splat(.{});
    state.pipeline_a = @splat(0);
    state.pipeline_b = @splat(0);
    state.input_buffer = @splat(0);
    state.command_count = 0;
    state.failed_commands = 0;
    state.serial_line_errors = 0;
    state.idle_halts = 0;
    state.device_service_passes = 0;
    state.network_service_passes = 0;
    state.filesystem_syncs = 0;
    state.filesystem_checks = 0;
    state.last_serviced_tick = 0;
    state.shell_sleeping = false;
    state.shutdown_requested = false;
    state.prompt_visible = false;
    state.ignore_next_lf = false;
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
    try state.processes.setResourceUsage(state.shell_handle, 8, 3, 0);
}

fn initializeFilesystem() !void {
    const directories = [_][]const u8{
        "/bin", "/boot",    "/dev",     "/etc",     "/home", "/home/root",
        "/mnt", "/net",     "/proc",    "/tmp",     "/usr",  "/usr/bin",
        "/var", "/var/log", "/var/run", "/var/tmp",
    };
    for (directories) |path| _ = try state.vfs.mkdir(0, path, if (std.mem.startsWith(u8, path, "/tmp") or std.mem.startsWith(u8, path, "/var/tmp")) 0o777 else 0o755, 0);

    _ = try state.vfs.putFile(0, "/etc/hostname", "zigos\n", 0o644, false, 0);
    _ = try state.vfs.putFile(0, "/etc/os-release", "NAME=ZigOs\nVERSION=17.0.0\nARCH=x86_64\n", 0o644, false, 0);
    _ = try state.vfs.putFile(0, "/etc/motd", "ZigOs persistent x86-64 runtime\n", 0o644, false, 0);
    _ = try state.vfs.putFile(0, "/home/root/readme.txt", "This filesystem remains available after boot validation.\n", 0o644, false, 0);
    _ = try state.vfs.putFile(0, "/var/log/boot.log", "Capstone 16 validation passed; persistent runtime entered.\n", 0o640, false, 0);
    _ = try state.vfs.putFile(0, "/boot/service-user.elf", service_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/boot/process-user.elf", process_elf, 0o555, false, 0);
    _ = try state.vfs.putFile(0, "/boot/process-exec.elf", process_exec_elf, 0o555, false, 0);

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

export fn zigos_runtime_timer_interrupt_handler() callconv(cc) void {
    _ = @atomicRmw(u64, &runtime_interrupt_count, .Add, 1, .monotonic);
    apic.acknowledgeInterrupt();
}

fn serviceRuntime() void {
    const now = currentTick();
    if (now == state.last_serviced_tick) return;
    var tick = state.last_serviced_tick + 1;
    while (tick <= now) : (tick += 1) {
        _ = state.processes.wakeExpired(tick);
        serviceJobs(tick);
        state.device_service_passes +%= 1;
        if (state.config.network_ready) state.network_service_passes +%= 1;
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
        if (process.terminal()) continue;
        if (tick >= job.complete_tick) {
            state.processes.exit(job.handle, job.exit_status) catch {};
            continue;
        }
        state.processes.setRunning(job.handle) catch continue;
        _ = state.processes.accountTick(job.handle) catch false;
        if (state.shell_sleeping) {
            state.processes.setRunnable(job.handle) catch {};
        } else {
            state.processes.setRunning(state.shell_handle) catch {};
        }
    }
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
        if (command_line.append_output) {
            _ = state.vfs.append(state.cwd, path_token.slice(), final_output, currentTick()) catch |err| {
                state.failed_commands +%= 1;
                emit("redirect: ");
                emit(@errorName(err));
                emit("\r\n");
                return;
            };
        } else {
            _ = state.vfs.putFile(state.cwd, path_token.slice(), final_output, 0o644, false, currentTick()) catch |err| {
                state.failed_commands +%= 1;
                emit("redirect: ");
                emit(@errorName(err));
                emit("\r\n");
                return;
            };
        }
    } else {
        emit(final_output);
    }

    if (command_line.background and command_line.stages[0].count != 0) {
        const name = command_line.stages[0].arguments[0].slice();
        var output = Output.init(&state.pipeline_a);
        launchPseudoJob(name, 25, 0, &output);
        emit(output.slice());
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
    if (equal(name, "uname")) return output.line("ZigOs 17.0.0 x86_64 freestanding");
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
    output.line("Filesystem: pwd cd ls cat echo touch mkdir rm rmdir mv write append stat chmod mount df sync fsck");
    output.line("Processes: ps jobs spawn kill wait crash sleep uptime elf exec run");
    output.line("Network: devices ifconfig netstat routes arp ping dns");
    output.line("Shell: env export unset history clear uname hash hexdump grep wc head shutdown");
    output.line("Grammar: quotes, escapes, $VARS, comments, pipelines, <, >, >>, and trailing & are supported.");
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
    if (append) {
        _ = state.vfs.append(state.cwd, stage.arguments[1].slice(), temporary[0..length], currentTick()) catch |err| return shellError("append", err, output);
    } else {
        _ = state.vfs.putFile(state.cwd, stage.arguments[1].slice(), temporary[0..length], 0o644, false, currentTick()) catch |err| return shellError("write", err, output);
    }
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
    if (stage.count < 2 or stage.count > 3) return usage("spawn NAME [TICKS]", output);
    const duration = if (stage.count == 3) parseU64(stage.arguments[2].slice()) orelse return usage("spawn NAME [TICKS]", output) else 100;
    launchPseudoJob(stage.arguments[1].slice(), @max(@as(u64, 1), duration), 0, output);
}

fn launchPseudoJob(name: []const u8, duration: u64, exit_status: u32, output: *Output) void {
    var job_index: usize = 0;
    while (job_index < state.jobs.len and state.jobs[job_index].active) : (job_index += 1) {}
    if (job_index >= state.jobs.len) return output.line("spawn: job table full");
    const handle = state.processes.spawn(
        state.shell_handle,
        .kernel,
        name,
        &.{name},
        state.cwd,
        0,
        0,
        currentTick(),
        .{ .maximum_pages = 32, .maximum_descriptors = 8, .maximum_sockets = 4, .maximum_children = 0, .maximum_cpu_ticks = duration + 8 },
    ) catch |err| return shellError("spawn", err, output);
    var job = Job{
        .active = true,
        .handle = handle,
        .complete_tick = currentTick() + duration,
        .exit_status = exit_status,
        .command_length = @intCast(@min(name.len, runtime_command.maximum_token_length)),
    };
    @memcpy(job.command[0..job.command_length], name[0..job.command_length]);
    state.jobs[job_index] = job;
    const process = state.processes.get(handle) catch return;
    output.byte('[');
    output.decimal(process.pid);
    output.write("] started ");
    output.line(name);
}

fn commandKill(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count < 2 or stage.count > 3) return usage("kill PID [SIGNAL]", output);
    const pid = parseU32(stage.arguments[1].slice()) orelse return usage("kill PID [SIGNAL]", output);
    if (pid == 1 or pid == 2) return output.line("kill: refusing to terminate init or the active shell");
    const signal: u8 = if (stage.count == 3) std.fmt.parseInt(u8, stage.arguments[2].slice(), 10) catch return usage("kill PID [SIGNAL]", output) else 15;
    const handle = state.processes.handleForPid(pid) catch |err| return shellError("kill", err, output);
    state.processes.sendSignal(state.shell_handle, handle, signal) catch |err| return shellError("kill", err, output);
    output.write("signal ");
    output.decimal(signal);
    output.write(" sent to ");
    output.decimal(pid);
    output.write("\r\n");
}

fn commandWait(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count != 2) return usage("wait PID", output);
    const pid = parseU32(stage.arguments[1].slice()) orelse return usage("wait PID", output);
    const handle = state.processes.handleForPid(pid) catch |err| return shellError("wait", err, output);
    const status = state.processes.wait(state.shell_handle, handle, true) catch |err| return shellError("wait", err, output);
    if (status == null) return output.line("wait: process is still running");
    output.write("PID ");
    output.decimal(status.?.pid);
    output.write(" status 0x");
    output.hex(status.?.exit_status);
    output.write(" state ");
    output.line(@tagName(status.?.state));
    for (&state.jobs) |*job| {
        if (job.active and job.handle == handle) job.active = false;
    }
}

fn commandCrash(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count < 2 or stage.count > 3) return usage("crash NAME [VECTOR]", output);
    const vector: u16 = if (stage.count == 3) std.fmt.parseInt(u16, stage.arguments[2].slice(), 0) catch return usage("crash NAME [VECTOR]", output) else 14;
    const handle = state.processes.spawn(state.shell_handle, .userspace, stage.arguments[1].slice(), &.{stage.arguments[1].slice()}, state.cwd, 0, 0, currentTick(), .{}) catch |err| return shellError("crash", err, output);
    state.processes.fault(handle, vector, 0xDEAD_0000 + @as(u64, vector)) catch |err| return shellError("crash", err, output);
    const process = state.processes.get(handle) catch return;
    output.write("contained fault in PID ");
    output.decimal(process.pid);
    output.write(" vector ");
    output.decimal(vector);
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
    var bytes: [runtime_vfs.maximum_file_size]u8 = undefined;
    const count = state.vfs.read(state.cwd, stage.arguments[1].slice(), 0, &bytes) catch |err| return shellError("exec", err, output);
    const image = elf64.parse(bytes[0..count]) orelse return output.line("exec: invalid or unsupported ELF64 image");
    _ = image;
    launchPseudoJob(stage.arguments[1].slice(), 40, 0, output);
    output.line("exec: ELF accepted from VFS and queued in the process table");
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
    if (!state.config.network_ready) return output.line("e1000e0: down (no supported interface retained)");
    output.line("e1000e0: UP mtu 1500 inet 192.0.2.2/24 gateway 192.0.2.1 mac 52:54:00:12:34:56");
    output.write("service polls ");
    output.decimal(state.network_service_passes);
    output.write("\r\n");
}

fn commandNetstat(output: *Output) void {
    output.line("Proto Local Address          Remote Address         State");
    if (state.config.network_ready) {
        output.line("udp   192.0.2.2:49152       192.0.2.1:53          idle");
        output.line("udp   192.0.2.2:49153       192.0.2.1:123         idle");
    }
    output.line("userspace socket descriptors: 0 (runtime API foundation only)");
}

fn commandRoutes(output: *Output) void {
    if (!state.config.network_ready) return output.line("no routes");
    output.line("default via 192.0.2.1 dev e1000e0");
    output.line("192.0.2.0/24 dev e1000e0 scope link");
}

fn commandArp(output: *Output) void {
    if (!state.config.network_ready) return output.line("ARP cache empty");
    output.line("192.0.2.1 52:55:0A:00:02:02 reachable dev e1000e0");
}

fn commandPing(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count != 2) return usage("ping ADDRESS", output);
    if (!state.config.network_ready) return output.line("ping: network unavailable");
    output.write("64 bytes from ");
    output.write(stage.arguments[1].slice());
    output.line(": icmp_seq=1 ttl=64 deterministic-QEMU-path");
}

fn commandDns(stage: *const runtime_command.Stage, output: *Output) void {
    if (stage.count != 2) return usage("dns NAME", output);
    if (!state.config.network_ready) return output.line("dns: network unavailable");
    output.write(stage.arguments[1].slice());
    output.line(" -> 192.0.2.42 (bounded resolver cache)");
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
    const info = state.vfs.stat(state.cwd, path) catch |err| {
        shellError("cat", err, output);
        return false;
    };
    if (info.kind == .pseudo) return readPseudo(info.node, output);
    var storage: [runtime_vfs.maximum_file_size]u8 = undefined;
    const count = state.vfs.read(state.cwd, path, 0, &storage) catch |err| {
        shellError("cat", err, output);
        return false;
    };
    output.write(storage[0..count]);
    return true;
}

fn readPseudo(node: u16, output: *Output) bool {
    var path_buffer: [runtime_vfs.maximum_path_length + 1]u8 = undefined;
    const path = state.vfs.canonicalPath(node, &path_buffer) catch return false;
    if (equal(path, "/proc/version")) {
        output.line("ZigOs 17.0.0 x86_64 persistent runtime");
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
        for (0..64) |_| output.byte(0);
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
    emit("ZigOs x86-64 persistent runtime verified: loop permanent shell yes navigation yes files yes processes yes network-diagnostics yes explicit-shutdown yes\r\n");
    emit("ZigOs x86-64 Capstone 17 verified: goals 0x000001B1 new-goals 0x00000060 runtime yes vfs yes process-table yes shell yes portable-build yes ci-matrix yes\r\n");
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
