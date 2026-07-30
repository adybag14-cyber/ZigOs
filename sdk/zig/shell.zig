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
    "cp SOURCE DEST       copy through descriptors\r\n" ++
    "write PATH TEXT      replace a file\r\n" ++
    "append PATH TEXT     append to a file\r\n" ++
    "mkdir PATH           create a directory\r\n" ++
    "rm PATH              remove a file\r\n" ++
    "rmdir PATH           remove an empty directory\r\n" ++
    "mv SOURCE DEST       rename within a mount\r\n" ++
    "chmod MODE PATH      change permission bits\r\n" ++
    "sync                 commit /persist to NVMe\r\n" ++
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
    } else if (equal(name, "cp")) {
        if (command.count != 3) return usage("cp SOURCE DESTINATION");
        commandCp(command.sentinel(1), command.sentinel(2));
    } else if (equal(name, "write") or equal(name, "append")) {
        if (command.count < 3) return usage(if (equal(name, "append")) "append PATH TEXT..." else "write PATH TEXT...");
        commandWrite(command, equal(name, "append"));
    } else if (equal(name, "mkdir")) {
        if (command.count != 2) return usage("mkdir PATH");
        zigos.mkdir(command.sentinel(1), 0o755) catch |err| return printError("mkdir", err);
    } else if (equal(name, "rm")) {
        if (command.count != 2) return usage("rm PATH");
        zigos.unlink(command.sentinel(1)) catch |err| return printError("rm", err);
    } else if (equal(name, "rmdir")) {
        if (command.count != 2) return usage("rmdir PATH");
        zigos.rmdir(command.sentinel(1)) catch |err| return printError("rmdir", err);
    } else if (equal(name, "mv")) {
        if (command.count != 3) return usage("mv SOURCE DESTINATION");
        zigos.rename(command.sentinel(1), command.sentinel(2)) catch |err| return printError("mv", err);
    } else if (equal(name, "chmod")) {
        if (command.count != 3) return usage("chmod MODE PATH");
        const mode = parseOctal(command.slice(1)) orelse return usage("chmod MODE PATH");
        zigos.chmod(command.sentinel(2), mode) catch |err| return printError("chmod", err);
    } else if (equal(name, "sync")) {
        commandSync();
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

fn commandCp(source: [*:0]const u8, destination: [*:0]const u8) void {
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
    var total: usize = 0;
    var bytes: [512]u8 = undefined;
    while (true) {
        const count = zigos.read(source_fd, &bytes) catch |err| return printError("cp", err);
        if (count == 0) break;
        zigos.writeAll(destination_fd, bytes[0..count]) catch |err| return printError("cp", err);
        total += count;
    }
    zigos.writeAll(1, "copied ") catch {};
    writeDecimal(total);
    zigos.writeAll(1, " bytes\r\n") catch {};
}

fn commandWrite(command: *const Command, append: bool) void {
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
}

fn commandSync() void {
    zigos.sync() catch |err| return printError("sync", err);
    zigos.writeAll(1, "writable mounts synchronized\r\n") catch {};
}

fn commandPid() void {
    const pid = zigos.getpid() catch |err| return printError("pid", err);
    writeDecimal(pid);
    zigos.writeAll(1, "\r\n") catch {};
}

fn commandRun(command: *const Command, program_index: usize) void {
    const program = command.slice(program_index);
    const extra_count = command.count - program_index - 1;
    if (extra_count + 1 > zigos.constants.maximum_arguments) {
        zigos.writeAll(2, "run: too many arguments\r\n") catch {};
        return;
    }
    var arguments: [zigos.constants.maximum_arguments][]const u8 = undefined;
    for (0..extra_count) |index| arguments[index + 1] = command.slice(program_index + 1 + index);
    var environment_storage: [zigos.constants.maximum_environment][]const u8 = undefined;
    const environment = zigos.collectEnvironment(startup_environment, &environment_storage) orelse {
        zigos.writeAll(2, "run: invalid inherited environment\r\n") catch {};
        return;
    };
    var path_storage: [maximum_path + 1]u8 = @splat(0);
    const pid = spawnFromPath(program, &path_storage, &arguments, extra_count, environment) catch |err| return printError("run", err);
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

fn spawnFromPath(
    program: []const u8,
    path_storage: *[maximum_path + 1]u8,
    arguments: *[zigos.constants.maximum_arguments][]const u8,
    extra_count: usize,
    environment: []const []const u8,
) zigos.Error!u32 {
    if (program.len == 0) return error.InvalidArgument;
    if (containsScalar(program, '/')) {
        const path = buildExecutablePath("", program, path_storage) orelse return error.NameTooLong;
        arguments[0] = executableName(path);
        return zigos.spawnv(path, arguments[0 .. extra_count + 1], environment);
    }
    const path_value = zigos.environmentValue(startup_environment, "PATH") orelse "/bin:/persist";
    var start: usize = 0;
    while (start <= path_value.len) {
        const remaining = path_value[start..];
        const separator = indexOfScalar(remaining, ':') orelse remaining.len;
        const directory = remaining[0..separator];
        if (directory.len != 0) {
            const path = buildExecutablePath(directory, program, path_storage) orelse return error.NameTooLong;
            arguments[0] = executableName(path);
            const candidate: ?u32 = zigos.spawnv(path, arguments[0 .. extra_count + 1], environment) catch |err| switch (err) {
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
        error.AlreadyExists => "already exists",
        error.NotEmpty => "directory not empty",
        error.CrossDevice => "cross-device operation",
        error.ReadOnly => "read-only filesystem",
        error.InputOutput => "input/output error",
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
