const zigos = @import("zigos.zig");

const maximum_line: usize = 512;
const maximum_words: usize = 8;
const maximum_conditional_commands: usize = 4;
const maximum_sequential_lists: usize = 4;
const maximum_pipeline_stages: usize = 4;
const maximum_background_jobs: usize = 4;
const maximum_shell_variables: usize = 4;
const maximum_substitution_output: usize = zigos.constants.maximum_argument_bytes;
const maximum_path: usize = 255;
const status_success: u32 = 0;
const status_failure: u32 = 1;
const status_usage: u32 = 2;
const status_command_not_found: u32 = 127;

comptime {
    if (maximum_words > zigos.constants.maximum_arguments)
        @compileError("shell word capacity exceeds ABI argument capacity");
    if (maximum_words * (zigos.constants.maximum_argument_bytes + 1) > maximum_line + 1)
        @compileError("expanded command storage bound is invalid");
}

var startup_environment: [*]const usize = undefined;
var background_jobs: [maximum_background_jobs]BackgroundJob = @splat(.{});
var shell_variables: [maximum_shell_variables]ShellVariable = @splat(.{});
var history_dirty = false;

const BackgroundJob = struct {
    process_group: u32 = 0,
    remaining: u8 = 0,
    final_pid: u32 = 0,
    final_status: u32 = status_failure,
};

const ShellVariable = struct {
    length: u8 = 0,
    name_length: u8 = 0,
    bytes: [zigos.constants.maximum_environment_bytes]u8 = @splat(0),
};

const Word = struct {
    start: u16 = 0,
    length: u16 = 0,
};

const Command = struct {
    storage: []u8 = &.{},
    words: [maximum_words]Word = undefined,
    count: usize = 0,

    fn slice(self: *const Command, index: usize) []const u8 {
        const word = self.words[index];
        const start: usize = word.start;
        const length: usize = word.length;
        return self.storage[start .. start + length];
    }

    fn sentinel(self: *const Command, index: usize) [*:0]const u8 {
        return @ptrCast(&self.storage[@as(usize, self.words[index].start)]);
    }
};

const ConditionalOperator = enum {
    always,
    and_if,
    or_if,
};

const Pipeline = struct {
    stages: [maximum_pipeline_stages]Command = undefined,
    count: usize = 0,
};

const ConditionalCommand = struct {
    operator: ConditionalOperator = .always,
    pipeline: Pipeline = .{},
};

const ConditionalList = struct {
    commands: [maximum_conditional_commands]ConditionalCommand = undefined,
    count: usize = 0,
};

const CommandLine = struct {
    storage: [maximum_line + 1]u8 = undefined,
    lists: [maximum_sequential_lists]ConditionalList = @splat(.{}),
    count: usize = 0,
    background: bool = false,
};

const banner = "ZigOs userspace shell PID 2\r\n";
const help_text = "help echo pwd cd ls cat cp write append mkdir rm rmdir mv chmod sync pid status fg bg run shutdown\r\n";

pub export fn zigos_main(
    _: usize,
    _: [*]const usize,
    envp: [*]const usize,
    auxv: [*]const zigos.AuxvEntry,
) callconv(.c) u32 {
    startup_environment = envp;
    if (zigos.environmentValue(envp, "PATH") == null or
        zigos.auxiliaryValue(auxv, zigos.constants.aux_pagesz) != zigos.constants.abi_page_size) return 0xF0;
    runStartupFile("/etc/shrc");
    runStartupFile("/home/root/.shrc");
    zigos.writeAll(1, banner) catch return 0xF1;
    shellLoop();
    return 0xF2;
}

fn runStartupFile(path: [*:0]const u8) void {
    const fd = zigos.open(path, .{ .read = true }, 0) catch return;
    defer zigos.close(fd) catch {};
    var line: CommandLine = .{};
    const received = zigos.read(fd, line.storage[0 .. maximum_line + 1]) catch return;
    if (received > maximum_line) return;
    var previous_separator = true;
    for (line.storage[0..received]) |*byte| {
        switch (byte.*) {
            '\r' => byte.* = ' ',
            '\n' => {
                byte.* = if (previous_separator) ' ' else ';';
                previous_separator = true;
            },
            ';' => previous_separator = true,
            ' ', '\t' => {},
            else => previous_separator = false,
        }
    }
    if (!parseCommandLine(&line, received)) return;
    _ = executeCommandLine(&line, status_success);
}

fn shellLoop() void {
    var last_status: u32 = status_success;
    while (true) {
        printPrompt();
        var line: CommandLine = .{};
        const count = readLineWithBackgroundNotifications(&line) catch continue;
        if (count == 0) {
            zigos.writeAll(1, "\r\n") catch {};
            requestShutdown();
        }
        persistHistory(&line, count);
        if (!parseCommandLine(&line, count)) {
            last_status = conditionalSyntaxError();
            continue;
        }
        if (line.count == 0) continue;
        last_status = executeCommandLine(&line, last_status);
    }
}

fn persistHistory(line: *CommandLine, received: usize) void {
    var length = @min(received, maximum_line);
    while (length != 0 and (line.storage[length - 1] == '\r' or line.storage[length - 1] == '\n')) length -= 1;
    if (!segmentHasContent(line.storage[0..], 0, length)) return;
    line.storage[length] = '\n';
    const entry = line.storage[0 .. length + 1];

    const fd = zigos.open("/persist/.sh_history", .{ .write = true, .create = true, .append = true }, 0o600) catch return;
    zigos.writeAll(fd, entry) catch |err| {
        zigos.close(fd) catch {};
        if (err != error.FileTooLarge) return;
        const replacement = zigos.open("/persist/.sh_history", .{ .write = true, .create = true, .truncate = true }, 0o600) catch return;
        defer zigos.close(replacement) catch {};
        zigos.writeAll(replacement, entry) catch return;
        history_dirty = true;
        return;
    };
    zigos.close(fd) catch {};
    history_dirty = true;
}

fn flushHistory() void {
    if (!history_dirty) return;
    const fd = zigos.open("/persist/.sh_history", .{ .write = true }, 0) catch return;
    defer zigos.close(fd) catch {};
    zigos.fsync(fd) catch |err| {
        if (err != error.Unsupported) return;
        zigos.sync() catch return;
    };
    history_dirty = false;
}

fn readLineWithBackgroundNotifications(line: *CommandLine) zigos.Error!usize {
    var descriptors = [_]zigos.PollDescriptor{.{ .fd = 0, .requested = zigos.constants.poll_readable, .returned = 0, .reserved = 0 }};
    while (true) {
        if (!hasBackgroundJobs()) return zigos.read(0, line.storage[0..maximum_line]);
        if (pollBackgroundJobs()) {
            printPrompt();
            continue;
        }
        descriptors[0].returned = 0;
        if ((zigos.poll(&descriptors) catch 0) != 0) return zigos.read(0, line.storage[0..maximum_line]);
        zigos.sleep(1) catch {};
    }
}

fn printPrompt() void {
    var path: [maximum_path + 1]u8 = undefined;
    const cwd = zigos.getcwd(&path) catch "?";
    zigos.writeAll(1, "root@zigos:") catch {};
    zigos.writeAll(1, cwd) catch {};
    zigos.writeAll(1, "$ ") catch {};
}

fn parseCommandLine(line: *CommandLine, received: usize) bool {
    var length = @min(received, maximum_line);
    while (length != 0 and (line.storage[length - 1] == '\r' or line.storage[length - 1] == '\n')) {
        length -= 1;
    }
    line.storage[length] = 0;
    if (!segmentHasContent(line.storage[0..], 0, length)) return true;

    var end = length;
    while (end != 0 and isSpace(line.storage[end - 1])) : (end -= 1) {}
    if (end != 0 and line.storage[end - 1] == '&' and
        (end == 1 or line.storage[end - 2] != '&'))
    {
        line.background = true;
        line.storage[end - 1] = 0;
        end -= 1;
        if (!segmentHasContent(line.storage[0..], 0, end)) return false;
    }

    var segment_start: usize = 0;
    var scan: usize = 0;
    while (scan < end) : (scan += 1) {
        if (line.storage[scan] != ';') continue;
        if (line.count == maximum_sequential_lists) return false;
        line.storage[scan] = 0;
        if (!parseConditionalList(&line.lists[line.count], line.storage[0..], segment_start, scan)) return false;
        line.count += 1;
        segment_start = scan + 1;
    }

    if (segmentHasContent(line.storage[0..], segment_start, end)) {
        if (line.count == maximum_sequential_lists) return false;
        if (!parseConditionalList(&line.lists[line.count], line.storage[0..], segment_start, end)) return false;
        line.count += 1;
    } else if (line.count == 0) {
        return false;
    }
    return !line.background or validBackgroundList(&line.lists[line.count - 1]);
}

fn validBackgroundList(list: *const ConditionalList) bool {
    if (list.count != 1 or list.commands[0].operator != .always) return false;
    const pipeline = &list.commands[0].pipeline;
    for (pipeline.stages[0..pipeline.count]) |stage| {
        if (isBuiltin(stage.slice(0)) or assignmentNameLength(stage.slice(0)) != null or commandHasExpansion(&stage)) return false;
    }
    return true;
}

fn segmentHasContent(storage: []const u8, segment_start: usize, segment_end: usize) bool {
    for (storage[segment_start..segment_end]) |byte| {
        if (!isSpace(byte)) return true;
    }
    return false;
}

fn parseConditionalList(list: *ConditionalList, storage: []u8, segment_start: usize, segment_end: usize) bool {
    if (!segmentHasContent(storage, segment_start, segment_end)) return false;

    var command_start = segment_start;
    var scan = segment_start;
    var next_operator: ConditionalOperator = .always;
    while (scan + 1 < segment_end) {
        const operator: ?ConditionalOperator = if (storage[scan] == '&' and storage[scan + 1] == '&')
            .and_if
        else if (storage[scan] == '|' and storage[scan + 1] == '|')
            .or_if
        else
            null;
        if (storage[scan] == '&' and operator == null) return false;
        if (operator == null) {
            scan += 1;
            continue;
        }
        if (list.count >= maximum_conditional_commands - 1) return false;
        storage[scan] = 0;
        storage[scan + 1] = 0;
        var pipeline: Pipeline = .{};
        if (!parsePipelineSegment(&pipeline, storage, command_start, scan)) return false;
        list.commands[list.count] = .{ .operator = next_operator, .pipeline = pipeline };
        list.count += 1;
        next_operator = operator.?;
        scan += 2;
        command_start = scan;
    }

    var pipeline: Pipeline = .{};
    if (!parsePipelineSegment(&pipeline, storage, command_start, segment_end)) return false;
    list.commands[list.count] = .{ .operator = next_operator, .pipeline = pipeline };
    list.count += 1;
    return true;
}

fn parsePipelineSegment(pipeline: *Pipeline, storage: []u8, segment_start: usize, segment_end: usize) bool {
    if (!segmentHasContent(storage, segment_start, segment_end)) return false;
    var stage_start = segment_start;
    var scan = segment_start;
    while (scan < segment_end) : (scan += 1) {
        if (storage[scan] != '|') continue;
        if (pipeline.count >= maximum_pipeline_stages - 1) return false;
        storage[scan] = 0;
        var command: Command = .{ .storage = storage };
        if (!parseCommandSegment(&command, stage_start, scan)) return false;
        pipeline.stages[pipeline.count] = command;
        pipeline.count += 1;
        stage_start = scan + 1;
    }
    var command: Command = .{ .storage = storage };
    if (!parseCommandSegment(&command, stage_start, segment_end)) return false;
    pipeline.stages[pipeline.count] = command;
    pipeline.count += 1;
    return true;
}

fn parseCommandSegment(command: *Command, segment_start: usize, segment_end: usize) bool {
    var index = segment_start;
    while (index < segment_end) {
        while (index < segment_end and isSpace(command.storage[index])) {
            command.storage[index] = 0;
            index += 1;
        }
        if (index == segment_end) break;
        if (command.count == maximum_words) return false;
        const start = index;
        while (index < segment_end and !isSpace(command.storage[index])) : (index += 1) {}
        command.words[command.count] = .{ .start = @intCast(start), .length = @intCast(index - start) };
        command.count += 1;
        if (index < segment_end) {
            command.storage[index] = 0;
            index += 1;
        }
    }
    return command.count != 0;
}

fn executeCommandLine(line: *const CommandLine, previous_status: u32) u32 {
    var status = previous_status;
    for (line.lists[0..line.count], 0..) |list, index| {
        status = if (line.background and index + 1 == line.count)
            executePipelineMode(&list.commands[0].pipeline, status, true)
        else
            executeConditionalList(&list, status);
    }
    return status;
}

fn executeConditionalList(list: *const ConditionalList, previous_status: u32) u32 {
    var status = previous_status;
    for (list.commands[0..list.count]) |entry| {
        const should_execute = switch (entry.operator) {
            .always => true,
            .and_if => status == status_success,
            .or_if => status != status_success,
        };
        if (should_execute) status = executePipeline(&entry.pipeline, status);
    }
    return status;
}

fn executePipeline(pipeline: *const Pipeline, previous_status: u32) u32 {
    return executePipelineMode(pipeline, previous_status, false);
}

fn executePipelineMode(pipeline: *const Pipeline, previous_status: u32, background: bool) u32 {
    if (!background and pipeline.count == 1) return execute(&pipeline.stages[0], previous_status);
    for (pipeline.stages[0..pipeline.count]) |stage| {
        if (isBuiltin(stage.slice(0)) or assignmentNameLength(stage.slice(0)) != null or commandHasExpansion(&stage)) {
            zigos.writeAll(2, "pipeline: external stages only\r\n") catch {};
            return status_usage;
        }
    }

    var environment_storage: [zigos.constants.maximum_environment][]const u8 = undefined;
    const environment = collectShellEnvironment(&environment_storage) orelse return status_failure;
    const shell_group = if (background) 0 else zigos.ttyForegroundProcessGroup(0) catch return status_failure;
    const background_slot: ?usize = if (background) findBackgroundJobSlot() else null;
    if (background and background_slot == null) return status_failure;
    var pipe_pairs: [maximum_pipeline_stages - 1][2]u32 = undefined;
    var pipe_open: [maximum_pipeline_stages - 1][2]bool = @splat(@splat(false));
    var pipe_count: usize = 0;
    while (pipe_count + 1 < pipeline.count) : (pipe_count += 1) {
        zigos.pipe(&pipe_pairs[pipe_count]) catch {
            closePipelinePipeEnds(&pipe_pairs, &pipe_open, pipe_count);
            return status_failure;
        };
        pipe_open[pipe_count] = .{ true, true };
    }
    defer closePipelinePipeEnds(&pipe_pairs, &pipe_open, pipe_count);

    var pids: [maximum_pipeline_stages]u32 = undefined;
    var process_group: u32 = 0;
    var spawned: usize = 0;
    for (pipeline.stages[0..pipeline.count], 0..) |*stage, stage_index| {
        var arguments: [zigos.constants.maximum_arguments][]const u8 = undefined;
        for (stage.words[0..stage.count], 0..) |_, index| arguments[index] = stage.slice(index);
        var path_storage: [maximum_path + 1]u8 = undefined;
        const stdin_source: ?u16 = if (stage_index == 0)
            null
        else
            @intCast(pipe_pairs[stage_index - 1][0]);
        const stdout_source: ?u16 = if (stage_index + 1 == pipeline.count)
            null
        else
            @intCast(pipe_pairs[stage_index][1]);
        const pid = spawnFromPath(
            stage.slice(0),
            &path_storage,
            &arguments,
            stage.count - 1,
            environment,
            true,
            if (stage_index == 0) null else process_group,
            stdin_source,
            stdout_source,
            !background and stage_index == 0,
        ) catch |err| {
            closePipelinePipeEnds(&pipe_pairs, &pipe_open, pipe_count);
            if (!background and spawned != 0) _ = restorePipelineForeground(shell_group);
            reapPipelineChildren(&pids, spawned);
            return if (err == error.NotFound) status_command_not_found else status_failure;
        };
        pids[stage_index] = pid;
        spawned += 1;
        if (stage_index == 0) process_group = pid;
        if (stage_index != 0 and pipe_open[stage_index - 1][0]) {
            zigos.close(@intCast(pipe_pairs[stage_index - 1][0])) catch {};
            pipe_open[stage_index - 1][0] = false;
        }
        if (stage_index + 1 < pipeline.count and pipe_open[stage_index][1]) {
            zigos.close(@intCast(pipe_pairs[stage_index][1])) catch {};
            pipe_open[stage_index][1] = false;
        }
    }

    if (background) {
        const slot = background_slot.?;
        background_jobs[slot] = .{
            .process_group = process_group,
            .remaining = @intCast(spawned),
            .final_pid = pids[spawned - 1],
        };
        return status_success;
    }

    zigos.writeAll(1, "pipeline\r\n") catch {};

    var foreground_job: BackgroundJob = .{
        .process_group = process_group,
        .remaining = @intCast(spawned),
        .final_pid = pids[spawned - 1],
    };
    return waitClaimedForegroundJob(&foreground_job, shell_group) orelse {
        reapPipelineChildren(&pids, spawned);
        _ = restorePipelineForeground(shell_group);
        return status_failure;
    };
}

fn waitForegroundJob(job: *BackgroundJob) ?u32 {
    const shell_group = zigos.ttyForegroundProcessGroup(0) catch return null;
    zigos.ttySetForegroundProcessGroup(0, job.process_group) catch return null;
    return waitClaimedForegroundJob(job, shell_group);
}

fn waitClaimedForegroundJob(job: *BackgroundJob, shell_group: u32) ?u32 {
    const observed = zigos.ttyForegroundProcessGroup(0) catch {
        _ = restorePipelineForeground(shell_group);
        return null;
    };
    if (observed != job.process_group) {
        _ = restorePipelineForeground(shell_group);
        return null;
    }
    while (job.remaining != 0) {
        var status: zigos.WaitStatus = undefined;
        _ = zigos.waitProcessGroup(job.process_group, false, &status) catch {
            _ = restorePipelineForeground(shell_group);
            return null;
        };
        job.remaining -= 1;
        if (status.pid == job.final_pid) job.final_status = status.exit_status;
    }
    if (!restorePipelineForeground(shell_group)) return null;
    return job.final_status;
}

fn restorePipelineForeground(shell_group: u32) bool {
    zigos.ttySetForegroundProcessGroup(0, shell_group) catch return false;
    const observed = zigos.ttyForegroundProcessGroup(0) catch return false;
    if (observed != shell_group) return false;
    return true;
}

fn findBackgroundJobSlot() ?usize {
    for (background_jobs, 0..) |job, index| {
        if (job.process_group == 0) return index;
    }
    return null;
}

fn hasBackgroundJobs() bool {
    for (background_jobs) |job| {
        if (job.process_group != 0) return true;
    }
    return false;
}

fn pollBackgroundJobs() bool {
    var notified = false;
    for (&background_jobs, 0..) |*job, slot| {
        if (job.process_group == 0) continue;
        while (job.remaining != 0) {
            var status: zigos.WaitStatus = undefined;
            const pid = zigos.waitProcessGroup(job.process_group, true, &status) catch {
                job.* = .{};
                notified = true;
                break;
            };
            if (pid == 0) break;
            job.remaining -= 1;
            if (status.pid == job.final_pid) {
                job.final_status = status.exit_status;
            }
        }
        if (job.process_group == 0 or job.remaining != 0) continue;
        if (!notified) zigos.writeAll(1, "\r\n") catch {};
        zigos.writeAll(1, "[") catch {};
        writeDecimal(slot + 1);
        zigos.writeAll(1, "] done ") catch {};
        writeDecimal(job.final_status);
        zigos.writeAll(1, "\r\n") catch {};
        job.* = .{};
        notified = true;
    }
    return notified;
}

fn closePipelinePipeEnds(
    pipe_pairs: *const [maximum_pipeline_stages - 1][2]u32,
    pipe_open: *[maximum_pipeline_stages - 1][2]bool,
    count: usize,
) void {
    for (0..count) |index| {
        for (0..2) |end| {
            if (!pipe_open[index][end]) continue;
            zigos.close(@intCast(pipe_pairs[index][end])) catch {};
            pipe_open[index][end] = false;
        }
    }
}

fn reapPipelineChildren(pids: *const [maximum_pipeline_stages]u32, count: usize) void {
    for (pids[0..count]) |pid| {
        var status: zigos.WaitStatus = undefined;
        _ = zigos.wait(pid, false, &status) catch {};
    }
}

fn isBuiltin(name: []const u8) bool {
    return equal(name, "help") or equal(name, "echo") or equal(name, "pwd") or equal(name, "cd") or
        equal(name, "ls") or equal(name, "cat") or equal(name, "cp") or equal(name, "write") or
        equal(name, "append") or equal(name, "mkdir") or equal(name, "rm") or equal(name, "rmdir") or
        equal(name, "mv") or equal(name, "chmod") or equal(name, "sync") or equal(name, "pid") or
        equal(name, "status") or equal(name, "fg") or equal(name, "bg") or equal(name, "run") or
        equal(name, "shutdown") or equal(name, "exit");
}

fn conditionalSyntaxError() u32 {
    zigos.writeAll(2, "syntax: invalid conditional list\r\n") catch {};
    return status_usage;
}

fn execute(command: *const Command, previous_status: u32) u32 {
    const name = command.slice(0);
    if (command.count == 1) {
        if (assignmentNameLength(name)) |name_length| return assignVariable(name, name_length);
    }
    if (!commandHasExpansion(command)) return executeExpanded(command, previous_status);
    var storage: [maximum_line + 1]u8 = undefined;
    var expanded = expandCommand(command, &storage) orelse return status_failure;
    return executeExpanded(&expanded, previous_status);
}

fn executeExpanded(command: *const Command, previous_status: u32) u32 {
    const name = command.slice(0);
    if (equal(name, "help")) {
        zigos.writeAll(1, help_text) catch return status_failure;
        return status_success;
    } else if (equal(name, "echo")) {
        return commandEcho(command);
    } else if (equal(name, "pwd")) {
        return commandPwd();
    } else if (equal(name, "cd")) {
        if (command.count != 2) return usage();
        zigos.chdir(command.sentinel(1)) catch |err| return printError("cd", err);
        return status_success;
    } else if (equal(name, "ls")) {
        if (command.count > 2) return usage();
        return commandLs(if (command.count == 2) command.sentinel(1) else ".");
    } else if (equal(name, "cat")) {
        if (command.count != 2) return usage();
        return commandCat(command.sentinel(1));
    } else if (equal(name, "cp")) {
        if (command.count != 3) return usage();
        return commandCp(command.sentinel(1), command.sentinel(2));
    } else if (equal(name, "write") or equal(name, "append")) {
        if (command.count < 3) return usage();
        return commandWrite(command, equal(name, "append"));
    } else if (equal(name, "mkdir")) {
        if (command.count != 2) return usage();
        zigos.mkdir(command.sentinel(1), 0o755) catch |err| return printError("mkdir", err);
        return status_success;
    } else if (equal(name, "rm")) {
        if (command.count != 2) return usage();
        zigos.unlink(command.sentinel(1)) catch |err| return printError("rm", err);
        return status_success;
    } else if (equal(name, "rmdir")) {
        if (command.count != 2) return usage();
        zigos.rmdir(command.sentinel(1)) catch |err| return printError("rmdir", err);
        return status_success;
    } else if (equal(name, "mv")) {
        if (command.count != 3) return usage();
        zigos.rename(command.sentinel(1), command.sentinel(2)) catch |err| return printError("mv", err);
        return status_success;
    } else if (equal(name, "chmod")) {
        if (command.count != 3) return usage();
        const mode = parseOctal(command.slice(1)) orelse return usage();
        zigos.chmod(command.sentinel(2), mode) catch |err| return printError("chmod", err);
        return status_success;
    } else if (equal(name, "sync")) {
        return commandSync();
    } else if (equal(name, "pid")) {
        return commandPid();
    } else if (equal(name, "status")) {
        if (command.count != 1) return usage();
        return commandStatus(previous_status);
    } else if (equal(name, "fg") or equal(name, "bg")) {
        return commandJob(command, equal(name, "fg"));
    } else if (equal(name, "run")) {
        if (command.count < 2) return usage();
        return commandRun(command, 1);
    } else if (equal(name, "shutdown") or equal(name, "exit")) {
        if (hasBackgroundJobs()) {
            zigos.writeAll(2, "shutdown: background active\r\n") catch {};
            return status_failure;
        }
        requestShutdown();
    } else {
        return commandRun(command, 0);
    }
}

fn commandEcho(command: *const Command) u32 {
    for (1..command.count) |index| {
        if (index != 1) zigos.writeAll(1, " ") catch return status_failure;
        zigos.writeAll(1, command.slice(index)) catch return status_failure;
    }
    zigos.writeAll(1, "\r\n") catch return status_failure;
    return status_success;
}

fn commandPwd() u32 {
    var path: [maximum_path + 1]u8 = undefined;
    const cwd = zigos.getcwd(&path) catch |err| return printError("pwd", err);
    zigos.writeAll(1, cwd) catch return status_failure;
    zigos.writeAll(1, "\r\n") catch return status_failure;
    return status_success;
}

fn commandLs(path: [*:0]const u8) u32 {
    const fd = zigos.open(path, .{ .read = true }, 0) catch |err| return printError("ls", err);
    defer zigos.close(fd) catch {};
    var entries: [8]zigos.DirectoryEntry = undefined;
    while (true) {
        const count = zigos.getdents(fd, &entries) catch |err| return printError("ls", err);
        if (count == 0) break;
        for (entries[0..count]) |entry| {
            zigos.writeAll(1, entry.name[0..entry.name_length]) catch return status_failure;
            if (entry.kind == 1) zigos.writeAll(1, "/") catch return status_failure;
            zigos.writeAll(1, "\r\n") catch return status_failure;
        }
    }
    return status_success;
}

fn commandCat(path: [*:0]const u8) u32 {
    const fd = zigos.open(path, .{ .read = true }, 0) catch |err| return printError("cat", err);
    defer zigos.close(fd) catch {};
    var bytes: [512]u8 = undefined;
    while (true) {
        const count = zigos.read(fd, &bytes) catch |err| return printError("cat", err);
        if (count == 0) break;
        zigos.writeAll(1, bytes[0..count]) catch return status_failure;
    }
    return status_success;
}

fn commandCp(source: [*:0]const u8, destination: [*:0]const u8) u32 {
    const source_fd = zigos.open(source, .{ .read = true }, 0) catch |err| return printError("cp", err);
    defer zigos.close(source_fd) catch {};
    var info: zigos.Stat = undefined;
    zigos.fstat(source_fd, &info) catch |err| return printError("cp", err);
    if (info.kind == 1) return printError("cp", error.IsDirectory);
    const destination_fd = zigos.open(
        destination,
        .{ .write = true, .create = true, .truncate = true },
        info.mode | 0o200,
    ) catch |err| return printError("cp", err);
    defer zigos.close(destination_fd) catch {};
    var bytes: [512]u8 = undefined;
    while (true) {
        const count = zigos.read(source_fd, &bytes) catch |err| return printError("cp", err);
        if (count == 0) break;
        zigos.writeAll(destination_fd, bytes[0..count]) catch |err| return printError("cp", err);
    }
    return status_success;
}

fn commandWrite(command: *const Command, append: bool) u32 {
    const fd = zigos.open(
        command.sentinel(1),
        .{ .write = true, .create = true, .truncate = !append, .append = append },
        0o644,
    ) catch |err| return printError(if (append) "append" else "write", err);
    defer zigos.close(fd) catch {};
    for (2..command.count) |index| {
        if (index != 2) zigos.writeAll(fd, " ") catch |err| return printError("write", err);
        zigos.writeAll(fd, command.slice(index)) catch |err| return printError("write", err);
    }
    zigos.writeAll(fd, "\n") catch |err| return printError("write", err);
    return status_success;
}

fn commandSync() u32 {
    zigos.sync() catch |err| return printError("sync", err);
    zigos.writeAll(1, "writable mounts synchronized\r\n") catch return status_failure;
    return status_success;
}

fn commandPid() u32 {
    const pid = zigos.getpid() catch |err| return printError("pid", err);
    writeDecimal(pid);
    zigos.writeAll(1, "\r\n") catch return status_failure;
    return status_success;
}

fn commandStatus(previous_status: u32) u32 {
    writeDecimal(previous_status);
    zigos.writeAll(1, "\r\n") catch return status_failure;
    return status_success;
}

fn commandJob(command: *const Command, foreground: bool) u32 {
    if (command.count > 2) return status_usage;
    const slot: usize = if (command.count == 2) blk: {
        const value = command.slice(1);
        if (value.len != 1 or value[0] < '1' or value[0] > '0' + maximum_background_jobs) return status_usage;
        break :blk value[0] - '1';
    } else findActiveJobSlot() orelse return status_failure;
    const job = &background_jobs[slot];
    if (job.process_group == 0) return status_failure;
    if (!foreground) return status_success;
    const final_status = waitForegroundJob(job) orelse return status_failure;
    job.* = .{};
    return final_status;
}

fn findActiveJobSlot() ?usize {
    for (background_jobs, 0..) |job, slot| {
        if (job.process_group != 0) return slot;
    }
    return null;
}

fn commandRun(command: *const Command, program_index: usize) u32 {
    const program = command.slice(program_index);
    const extra_count = command.count - program_index - 1;
    if (extra_count + 1 > zigos.constants.maximum_arguments) return usage();
    var arguments: [zigos.constants.maximum_arguments][]const u8 = undefined;
    for (0..extra_count) |index| arguments[index + 1] = command.slice(program_index + 1 + index);
    var environment_storage: [zigos.constants.maximum_environment][]const u8 = undefined;
    const environment = collectShellEnvironment(&environment_storage) orelse return status_failure;
    var path_storage: [maximum_path + 1]u8 = undefined;
    const pid = spawnFromPath(program, &path_storage, &arguments, extra_count, environment, false, null, null, null, false) catch |err| {
        _ = printError("run", err);
        return switch (err) {
            error.NotFound => status_command_not_found,
            else => status_failure,
        };
    };
    var status: zigos.WaitStatus = undefined;
    _ = zigos.wait(pid, false, &status) catch |err| return printError("wait", err);
    zigos.writeAll(1, "process ") catch return status_failure;
    writeDecimal(status.pid);
    zigos.writeAll(1, " exited ") catch return status_failure;
    writeDecimal(status.exit_status);
    zigos.writeAll(1, "\r\n") catch return status_failure;
    return status.exit_status;
}

fn commandHasExpansion(command: *const Command) bool {
    for (command.words[0..command.count]) |word| {
        const start: usize = word.start;
        const value = command.storage[start .. start + @as(usize, word.length)];
        if (substitutionProgram(value) != null or containsScalar(value, '*') or value[0] == '~') return true;
    }
    return false;
}

fn substitutionProgram(word: []const u8) ?[]const u8 {
    if (word.len < 4 or word[0] != '$' or word[1] != '(' or word[word.len - 1] != ')') return null;
    const program = word[2 .. word.len - 1];
    if (program.len == 0 or containsScalar(program, '(') or containsScalar(program, ')')) return null;
    return program;
}

fn expandCommand(command: *const Command, storage: *[maximum_line + 1]u8) ?Command {
    var result: Command = .{ .storage = storage };
    var cursor: usize = 0;
    for (command.words[0..command.count], 0..) |_, index| {
        const word = command.slice(index);
        if (substitutionProgram(word)) |program| {
            if (index == 0) return null;
            var captured: [maximum_substitution_output]u8 = undefined;
            const count = captureSubstitution(program, &captured) orelse return null;
            if (!appendExpandedWord(&result, storage, &cursor, captured[0..count])) return null;
        } else if (containsScalar(word, '*')) {
            if (index == 0 or !expandWildcard(word, &result, storage, &cursor)) return null;
        } else if (word[0] == '~') {
            if (word.len != 1 and word[1] != '/') return null;
            const home = "/home/root";
            var expanded: [zigos.constants.maximum_argument_bytes]u8 = undefined;
            const length = home.len + word.len - 1;
            if (length > expanded.len) return null;
            @memcpy(expanded[0..home.len], home);
            @memcpy(expanded[home.len..length], word[1..]);
            if (!appendExpandedWord(&result, storage, &cursor, expanded[0..length])) return null;
        } else if (!appendExpandedWord(&result, storage, &cursor, word)) return null;
    }
    return result;
}

fn appendExpandedWord(result: *Command, storage: *[maximum_line + 1]u8, cursor: *usize, word: []const u8) bool {
    if (word.len == 0 or word.len > zigos.constants.maximum_argument_bytes or result.count == result.words.len) return false;
    @memcpy(storage[cursor.* .. cursor.* + word.len], word);
    storage[cursor.* + word.len] = 0;
    result.words[result.count] = .{ .start = @intCast(cursor.*), .length = @intCast(word.len) };
    result.count += 1;
    cursor.* += word.len + 1;
    return true;
}

fn expandWildcard(word: []const u8, result: *Command, storage: *[maximum_line + 1]u8, cursor: *usize) bool {
    const star = indexOfScalar(word, '*') orelse return false;
    if (indexOfScalar(word[star + 1 ..], '*') != null) return false;
    var slash: ?usize = null;
    for (word, 0..) |byte, index| if (byte == '/') {
        slash = index;
    };
    const component_start = if (slash) |index| index + 1 else 0;
    if (star < component_start) return false;
    const pattern = word[component_start..];
    const pattern_star = star - component_start;
    const prefix = pattern[0..pattern_star];
    const suffix = pattern[pattern_star + 1 ..];
    var directory: [maximum_path + 1]u8 = undefined;
    const directory_path: [*:0]const u8 = if (slash) |index| blk: {
        const length = if (index == 0) 1 else index;
        @memcpy(directory[0..length], word[0..length]);
        directory[length] = 0;
        break :blk @ptrCast(&directory);
    } else ".";
    const fd = zigos.open(directory_path, .{ .read = true }, 0) catch return false;
    defer zigos.close(fd) catch {};
    var matches: usize = 0;
    var entries: [8]zigos.DirectoryEntry = undefined;
    while (true) {
        const count = zigos.getdents(fd, &entries) catch return false;
        if (count == 0) break;
        for (entries[0..count]) |entry| {
            const name = entry.name[0..entry.name_length];
            if (name.len < prefix.len + suffix.len or !equal(name[0..prefix.len], prefix) or !equal(name[name.len - suffix.len ..], suffix)) continue;
            var path: [zigos.constants.maximum_argument_bytes]u8 = undefined;
            const base = word[0..component_start];
            if (base.len + name.len > path.len) return false;
            @memcpy(path[0..base.len], base);
            @memcpy(path[base.len .. base.len + name.len], name);
            if (!appendExpandedWord(result, storage, cursor, path[0 .. base.len + name.len])) return false;
            matches += 1;
        }
    }
    return matches != 0;
}

fn captureSubstitution(program: []const u8, output: []u8) ?usize {
    var environment_storage: [zigos.constants.maximum_environment][]const u8 = undefined;
    const environment = collectShellEnvironment(&environment_storage) orelse return null;
    var pair: [2]u32 = undefined;
    zigos.pipe(&pair) catch return null;
    defer zigos.close(@intCast(pair[0])) catch {};
    defer zigos.close(@intCast(pair[1])) catch {};
    var arguments: [zigos.constants.maximum_arguments][]const u8 = undefined;
    var path_storage: [maximum_path + 1]u8 = undefined;
    const pid = spawnFromPath(program, &path_storage, &arguments, 0, environment, true, null, null, @intCast(pair[1]), false) catch return null;
    zigos.close(@intCast(pair[1])) catch return null;
    var total: usize = 0;
    while (total < output.len) {
        const count = zigos.read(@intCast(pair[0]), output[total..]) catch {
            reapSubstitution(pid);
            return null;
        };
        if (count == 0) break;
        total += count;
    }
    if (total == output.len) {
        var extra: [1]u8 = undefined;
        if ((zigos.read(@intCast(pair[0]), &extra) catch 1) != 0) {
            zigos.close(@intCast(pair[0])) catch {};
            reapSubstitution(pid);
            return null;
        }
    }
    var status: zigos.WaitStatus = undefined;
    _ = zigos.wait(pid, false, &status) catch return null;
    if (status.exit_status != 0) return null;
    while (total != 0 and (output[total - 1] == '\n' or output[total - 1] == '\r')) total -= 1;
    if (total == 0) return null;
    for (output[0..total]) |byte| if (byte == 0) return null;
    return total;
}

fn reapSubstitution(pid: u32) void {
    var status: zigos.WaitStatus = undefined;
    _ = zigos.wait(pid, false, &status) catch {};
}

fn assignmentNameLength(value: []const u8) ?usize {
    const name_length = indexOfScalar(value, '=') orelse return null;
    if (name_length == 0) return null;
    for (value[0..name_length], 0..) |byte, index| {
        const alpha = (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or byte == '_';
        if (!alpha and (index == 0 or byte < '0' or byte > '9')) return null;
    }
    return name_length;
}

fn assignVariable(entry: []const u8, name_length: usize) u32 {
    if (entry.len > zigos.constants.maximum_environment_bytes) return status_usage;
    var free: ?*ShellVariable = null;
    for (&shell_variables) |*variable| {
        if (variable.length == 0) {
            if (free == null) free = variable;
        } else if (variable.name_length == name_length and equal(variable.bytes[0..name_length], entry[0..name_length])) {
            free = variable;
            break;
        }
    }
    const variable = free orelse return status_failure;
    @memcpy(variable.bytes[0..entry.len], entry);
    variable.length = @intCast(entry.len);
    variable.name_length = @intCast(name_length);
    return status_success;
}

fn shellEnvironmentValue(key: []const u8) ?[]const u8 {
    for (&shell_variables) |*variable| {
        if (variable.length != 0 and variable.name_length == key.len and equal(variable.bytes[0..key.len], key))
            return variable.bytes[key.len + 1 .. variable.length];
    }
    return zigos.environmentValue(startup_environment, key);
}

fn collectShellEnvironment(output: *[zigos.constants.maximum_environment][]const u8) ?[]const []const u8 {
    const inherited = zigos.collectEnvironment(startup_environment, output) orelse return null;
    var count = inherited.len;
    for (&shell_variables) |*variable| {
        if (variable.length == 0) continue;
        var replaced = false;
        for (0..inherited.len) |index| {
            const name_length = indexOfScalar(output[index], '=') orelse continue;
            if (variable.name_length == name_length and equal(variable.bytes[0..name_length], output[index][0..name_length])) {
                output[index] = variable.bytes[0..variable.length];
                replaced = true;
                break;
            }
        }
        if (replaced) continue;
        if (count == output.len) return null;
        output[count] = variable.bytes[0..variable.length];
        count += 1;
    }
    return output[0..count];
}

fn executableName(path: []const u8) []const u8 {
    var last: usize = 0;
    for (path, 0..) |byte, index| {
        if (byte == '/') last = index + 1;
    }
    return path[last..];
}

fn spawnFromPath(
    program: []const u8,
    path_storage: *[maximum_path + 1]u8,
    arguments: *[zigos.constants.maximum_arguments][]const u8,
    extra_count: usize,
    environment: []const []const u8,
    grouped: bool,
    process_group: ?u32,
    stdin_source: ?u16,
    stdout_source: ?u16,
    claim_foreground: bool,
) zigos.Error!u32 {
    if (program.len == 0) return error.InvalidArgument;
    if (containsScalar(program, '/')) {
        const path = buildExecutablePath("", program, path_storage) orelse return error.NameTooLong;
        arguments[0] = executableName(path);
        return spawnResolved(path, arguments[0 .. extra_count + 1], environment, grouped, process_group, stdin_source, stdout_source, claim_foreground);
    }
    const path_value = shellEnvironmentValue("PATH") orelse "/bin:/persist";
    var start: usize = 0;
    while (start <= path_value.len) {
        const remaining = path_value[start..];
        const separator = indexOfScalar(remaining, ':') orelse remaining.len;
        const directory = remaining[0..separator];
        if (directory.len != 0) {
            const path = buildExecutablePath(directory, program, path_storage) orelse return error.NameTooLong;
            arguments[0] = executableName(path);
            const candidate: ?u32 = spawnResolved(
                path,
                arguments[0 .. extra_count + 1],
                environment,
                grouped,
                process_group,
                stdin_source,
                stdout_source,
                claim_foreground,
            ) catch |err| switch (err) {
                error.NotFound => null,
                else => return err,
            };
            if (candidate) |pid| return pid;
        }
        if (separator == remaining.len) break;
        start += separator + 1;
    }
    return error.NotFound;
}

fn spawnResolved(
    path: []const u8,
    arguments: []const []const u8,
    environment: []const []const u8,
    grouped: bool,
    process_group: ?u32,
    stdin_source: ?u16,
    stdout_source: ?u16,
    claim_foreground: bool,
) zigos.Error!u32 {
    if (!grouped) return zigos.spawnv(path, arguments, environment);
    const remap = stdin_source != null or stdout_source != null;
    return if (process_group) |group|
        if (remap)
            zigos.spawnvInProcessGroupWithPipelineIo(path, arguments, environment, group, stdin_source, stdout_source)
        else
            zigos.spawnvInProcessGroup(path, arguments, environment, group)
    else if (claim_foreground)
        zigos.spawnvNewForegroundProcessGroupWithPipelineIo(path, arguments, environment, stdin_source, stdout_source)
    else if (remap)
        zigos.spawnvNewProcessGroupWithPipelineIo(path, arguments, environment, stdin_source, stdout_source)
    else
        zigos.spawnvNewProcessGroup(path, arguments, environment);
}

fn buildExecutablePath(directory: []const u8, program: []const u8, output: *[maximum_path + 1]u8) ?[]const u8 {
    const direct = containsScalar(program, '/');
    const prefix = if (direct or directory.len == 0) "" else directory;
    const separator = if (prefix.len == 0 or prefix[prefix.len - 1] == '/') "" else "/";
    const suffix = if (endsWith(program, ".elf")) "" else ".elf";
    const length = prefix.len + separator.len + program.len + suffix.len;
    if (length > maximum_path) return null;
    @memcpy(output[0..prefix.len], prefix);
    @memcpy(output[prefix.len .. prefix.len + separator.len], separator);
    const program_start = prefix.len + separator.len;
    @memcpy(output[program_start .. program_start + program.len], program);
    @memcpy(output[program_start + program.len .. length], suffix);
    output[length] = 0;
    return output[0..length];
}

fn indexOfScalar(bytes: []const u8, value: u8) ?usize {
    for (bytes, 0..) |byte, index| {
        if (byte == value) return index;
    }
    return null;
}

fn requestShutdown() noreturn {
    flushHistory();
    zigos.shutdown() catch while (true) zigos.yield() catch {};
    while (true) asm volatile ("pause");
}

fn usage() u32 {
    zigos.writeAll(2, "usage\r\n") catch {};
    return status_usage;
}

fn printError(operation: []const u8, err: zigos.Error) u32 {
    zigos.writeAll(2, operation) catch {};
    zigos.writeAll(2, ": ") catch {};
    zigos.writeAll(2, errorName(err)) catch {};
    zigos.writeAll(2, "\r\n") catch {};
    return status_failure;
}

fn errorName(err: zigos.Error) []const u8 {
    return switch (err) {
        error.NotFound => "not found",
        error.Unsupported => "unsupported",
        error.InputOutput => "input/output error",
        error.ReadOnly => "read-only filesystem",
        else => "error",
    };
}

fn writeDecimal(value: u64) void {
    var output: [20]u8 = undefined;
    var remaining = value;
    var start = output.len;
    while (true) {
        start -= 1;
        output[start] = @intCast('0' + remaining % 10);
        remaining /= 10;
        if (remaining == 0) break;
    }
    zigos.writeAll(1, output[start..]) catch {};
}

fn parseOctal(value: []const u8) ?u16 {
    if (value.len == 0) return null;
    var result: u16 = 0;
    for (value) |byte| {
        if (byte < '0' or byte > '7' or result > 0o77) return null;
        result = result * 8 + (byte - '0');
    }
    return result;
}

fn equal(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}

fn endsWith(value: []const u8, suffix: []const u8) bool {
    if (suffix.len > value.len) return false;
    return equal(value[value.len - suffix.len ..], suffix);
}

fn containsScalar(value: []const u8, needle: u8) bool {
    for (value) |byte| if (byte == needle) return true;
    return false;
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}
