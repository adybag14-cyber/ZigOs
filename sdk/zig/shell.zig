const zigos = @import("zigos.zig");

const maximum_line: usize = 512;
const maximum_words: usize = 8;
const maximum_path: usize = 255;

var startup_environment: [*]const usize = undefined;

const Word = struct {
    start: usize = 0,
    length: usize = 0,
};

const Command = struct {
    storage: [maximum_line + 1]u8 = @splat(0),
    words: [maximum_words]Word = @splat(.{}),
    count: usize = 0,

    fn slice(self: *const Command, index: usize) []const u8 {
        const word = self.words[index];
        return self.storage[word.start .. word.start + word.length];
    }

    fn sentinel(self: *const Command, index: usize) [*:0]const u8 {
        return @ptrCast(&self.storage[self.words[index].start]);
    }
};

const banner =
    "ZigOs userspace shell PID 2\r\n" ++
    "Type 'help' for commands.\r\n";
const help_text =
    "help                 show this command list\r\n" ++
    "echo [TEXT...]       write text\r\n" ++
    "pwd                  print working directory\r\n" ++
    "cd PATH              change working directory\r\n" ++
    "ls [PATH]            list a directory\r\n" ++
    "cat PATH             stream a file\r\n" ++
    "pid                  print the shell PID\r\n" ++
    "run PROGRAM [ARGS]   spawn with argv/env and wait\r\n" ++
    "shutdown             exit PID 2 and stop ZigOs\r\n";

pub export fn zigos_main(
    _: usize,
    _: [*]const usize,
    envp: [*]const usize,
    auxv: [*]const zigos.AuxvEntry,
) callconv(.c) u32 {
    startup_environment = envp;
    if (zigos.environmentValue(envp, "PATH") == null or
        zigos.auxiliaryValue(auxv, zigos.constants.aux_pagesz) != zigos.constants.abi_page_size) return 0xF0;
    zigos.writeAll(1, banner) catch return 0xF1;
    shellLoop();
    return 0xF2;
}

fn shellLoop() void {
    while (true) {
        printPrompt();
        var command: Command = .{};
        const count = zigos.read(0, command.storage[0..maximum_line]) catch |err| {
            printError("read", err);
            continue;
        };
        if (count == 0) {
            zigos.writeAll(1, "\r\n") catch {};
            requestShutdown();
        }
        parseCommand(&command, count);
        if (command.count == 0) continue;
        execute(&command);
    }
}

fn printPrompt() void {
    var path: [maximum_path + 1]u8 = @splat(0);
    const cwd = zigos.getcwd(&path) catch "?";
    zigos.writeAll(1, "root@zigos:") catch {};
    zigos.writeAll(1, cwd) catch {};
    zigos.writeAll(1, "$ ") catch {};
}

fn parseCommand(command: *Command, received: usize) void {
    var length = @min(received, maximum_line);
    while (length != 0 and (command.storage[length - 1] == '\r' or command.storage[length - 1] == '\n')) {
        length -= 1;
    }
    command.storage[length] = 0;
    var index: usize = 0;
    while (index < length and command.count < maximum_words) {
        while (index < length and isSpace(command.storage[index])) {
            command.storage[index] = 0;
            index += 1;
        }
        if (index == length) break;
        const start = index;
        while (index < length and !isSpace(command.storage[index])) : (index += 1) {}
        const word_length = index - start;
        command.words[command.count] = .{ .start = start, .length = word_length };
        command.count += 1;
        if (index < command.storage.len) command.storage[index] = 0;
        index += @intFromBool(index < length);
    }
}

fn execute(command: *const Command) void {
    const name = command.slice(0);
    if (equal(name, "help")) {
        zigos.writeAll(1, help_text) catch {};
    } else if (equal(name, "echo")) {
        commandEcho(command);
    } else if (equal(name, "pwd")) {
        commandPwd();
    } else if (equal(name, "cd")) {
        if (command.count != 2) return usage("cd PATH");
        zigos.chdir(command.sentinel(1)) catch |err| return printError("cd", err);
    } else if (equal(name, "ls")) {
        if (command.count > 2) return usage("ls [PATH]");
        commandLs(if (command.count == 2) command.sentinel(1) else ".");
    } else if (equal(name, "cat")) {
        if (command.count != 2) return usage("cat PATH");
        commandCat(command.sentinel(1));
    } else if (equal(name, "pid")) {
        commandPid();
    } else if (equal(name, "run")) {
        if (command.count < 2) return usage("run PROGRAM [ARGS...]");
        commandRun(command, 1);
    } else if (equal(name, "shutdown") or equal(name, "exit")) {
        requestShutdown();
    } else {
        commandRun(command, 0);
    }
}

fn commandEcho(command: *const Command) void {
    for (1..command.count) |index| {
        if (index != 1) zigos.writeAll(1, " ") catch {};
        zigos.writeAll(1, command.slice(index)) catch {};
    }
    zigos.writeAll(1, "\r\n") catch {};
}

fn commandPwd() void {
    var path: [maximum_path + 1]u8 = @splat(0);
    const cwd = zigos.getcwd(&path) catch |err| return printError("pwd", err);
    zigos.writeAll(1, cwd) catch {};
    zigos.writeAll(1, "\r\n") catch {};
}

fn commandLs(path: [*:0]const u8) void {
    const fd = zigos.open(path, .{ .read = true }, 0) catch |err| return printError("ls", err);
    defer zigos.close(fd) catch {};
    var entries: [8]zigos.DirectoryEntry = undefined;
    while (true) {
        const count = zigos.getdents(fd, &entries) catch |err| return printError("ls", err);
        if (count == 0) break;
        for (entries[0..count]) |entry| {
            zigos.writeAll(1, entry.name[0..entry.name_length]) catch {};
            if (entry.kind == 1) zigos.writeAll(1, "/") catch {};
            zigos.writeAll(1, "\r\n") catch {};
        }
    }
}

fn commandCat(path: [*:0]const u8) void {
    const fd = zigos.open(path, .{ .read = true }, 0) catch |err| return printError("cat", err);
    defer zigos.close(fd) catch {};
    var bytes: [512]u8 = undefined;
    while (true) {
        const count = zigos.read(fd, &bytes) catch |err| return printError("cat", err);
        if (count == 0) break;
        zigos.writeAll(1, bytes[0..count]) catch return;
    }
}

fn commandPid() void {
    const pid = zigos.getpid() catch |err| return printError("pid", err);
    writeDecimal(pid);
    zigos.writeAll(1, "\r\n") catch {};
}

fn commandRun(command: *const Command, program_index: usize) void {
    const program = command.slice(program_index);
    var path_storage: [maximum_path + 1]u8 = @splat(0);
    const path = executablePath(program, &path_storage) orelse {
        zigos.writeAll(2, "run: program name too long\r\n") catch {};
        return;
    };
    const extra_count = command.count - program_index - 1;
    if (extra_count + 1 > zigos.constants.maximum_arguments) {
        zigos.writeAll(2, "run: too many arguments\r\n") catch {};
        return;
    }
    var arguments: [zigos.constants.maximum_arguments][]const u8 = undefined;
    arguments[0] = executableName(path);
    for (0..extra_count) |index| arguments[index + 1] = command.slice(program_index + 1 + index);
    var environment_storage: [zigos.constants.maximum_environment][]const u8 = undefined;
    const environment = zigos.collectEnvironment(startup_environment, &environment_storage) orelse {
        zigos.writeAll(2, "run: invalid inherited environment\r\n") catch {};
        return;
    };
    const pid = zigos.spawnv(path, arguments[0 .. extra_count + 1], environment) catch |err| return printError("run", err);
    var status: zigos.WaitStatus = undefined;
    _ = zigos.wait(pid, false, &status) catch |err| return printError("wait", err);
    zigos.writeAll(1, "process ") catch {};
    writeDecimal(status.pid);
    zigos.writeAll(1, " exited ") catch {};
    writeDecimal(status.exit_status);
    zigos.writeAll(1, "\r\n") catch {};
}

fn executableName(path: []const u8) []const u8 {
    var last: usize = 0;
    for (path, 0..) |byte, index| {
        if (byte == '/') last = index + 1;
    }
    return path[last..];
}

fn executablePath(program: []const u8, output: *[maximum_path + 1]u8) ?[]const u8 {
    if (program.len == 0) return null;
    if (containsScalar(program, '/')) {
        if (program.len > maximum_path) return null;
        @memcpy(output[0..program.len], program);
        output[program.len] = 0;
        return output[0..program.len];
    }
    const path_value = zigos.environmentValue(startup_environment, "PATH") orelse "/bin";
    if (path_value.len == 0 or containsScalar(path_value, ':')) return null;
    const separator = if (path_value[path_value.len - 1] == '/') "" else "/";
    const suffix = if (endsWith(program, ".elf")) "" else ".elf";
    const length = path_value.len + separator.len + program.len + suffix.len;
    if (length > maximum_path) return null;
    @memcpy(output[0..path_value.len], path_value);
    @memcpy(output[path_value.len .. path_value.len + separator.len], separator);
    const program_start = path_value.len + separator.len;
    @memcpy(output[program_start .. program_start + program.len], program);
    @memcpy(output[program_start + program.len .. length], suffix);
    output[length] = 0;
    return output[0..length];
}

fn requestShutdown() noreturn {
    zigos.writeAll(1, "userspace shell requested shutdown\r\n") catch {};
    zigos.shutdown() catch |err| {
        printError("shutdown", err);
        while (true) zigos.yield() catch {};
    };
    while (true) asm volatile ("pause");
}

fn usage(text: []const u8) void {
    zigos.writeAll(2, "usage: ") catch {};
    zigos.writeAll(2, text) catch {};
    zigos.writeAll(2, "\r\n") catch {};
}

fn printError(operation: []const u8, err: zigos.Error) void {
    zigos.writeAll(2, operation) catch {};
    zigos.writeAll(2, ": ") catch {};
    zigos.writeAll(2, errorName(err)) catch {};
    zigos.writeAll(2, "\r\n") catch {};
}

fn errorName(err: zigos.Error) []const u8 {
    return switch (err) {
        error.NotFound => "not found",
        error.NotDirectory => "not a directory",
        error.IsDirectory => "is a directory",
        error.BadDescriptor => "bad descriptor",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.WouldBlock => "would block",
        error.OutOfMemory, error.NoSpace => "no space",
        error.NameTooLong => "name too long",
        error.Unsupported => "unsupported",
        else => "operation failed",
    };
}

fn writeDecimal(value: u64) void {
    var digits: [20]u8 = undefined;
    var remaining = value;
    var count: usize = 0;
    if (remaining == 0) {
        zigos.writeAll(1, "0") catch {};
        return;
    }
    while (remaining != 0) : (remaining /= 10) {
        digits[count] = @intCast('0' + remaining % 10);
        count += 1;
    }
    var output: [20]u8 = undefined;
    for (0..count) |index| output[index] = digits[count - index - 1];
    zigos.writeAll(1, output[0..count]) catch {};
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
