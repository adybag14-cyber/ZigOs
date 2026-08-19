const zigos = @import("zigos.zig");

const status_success: u32 = 0;
const status_failure: u32 = 1;
const status_usage: u32 = 2;
const maximum_document_bytes: usize = 4096;
// The canonical TTY accepts at most 256 edited bytes before the line delimiter.
// Keep that full payload and frame delimiters independently of read() boundaries.
const maximum_command_bytes: usize = 256;
const input_chunk_bytes: usize = 512;

var document: [maximum_document_bytes]u8 = undefined;
var document_length: usize = 0;

const CommandKind = enum {
    line,
    eof,
    input_error,
    too_long,
};

const CommandRead = struct {
    kind: CommandKind,
    length: usize = 0,
};

const CommandReader = struct {
    pending: [input_chunk_bytes]u8 = undefined,
    pending_start: usize = 0,
    pending_end: usize = 0,
    line: [maximum_command_bytes]u8 = undefined,
    line_length: usize = 0,
    overflowed: bool = false,
    ignore_next_lf: bool = false,

    fn next(self: *CommandReader, output: *[maximum_command_bytes]u8) CommandRead {
        while (true) {
            if (self.pending_start == self.pending_end) {
                const received = zigos.read(0, &self.pending) catch return .{ .kind = .input_error };
                if (received == 0) {
                    if (self.overflowed) {
                        self.line_length = 0;
                        self.overflowed = false;
                        return .{ .kind = .too_long };
                    }
                    if (self.line_length == 0) return .{ .kind = .eof };
                    return self.finish(output);
                }
                self.pending_start = 0;
                self.pending_end = received;
            }

            const byte = self.pending[self.pending_start];
            self.pending_start += 1;

            if (self.ignore_next_lf) {
                self.ignore_next_lf = false;
                if (byte == '\n') continue;
            }
            if (byte == '\r') {
                self.ignore_next_lf = true;
                return self.finish(output);
            }
            if (byte == '\n') return self.finish(output);
            if (self.overflowed) continue;
            if (self.line_length == self.line.len) {
                self.overflowed = true;
                continue;
            }
            self.line[self.line_length] = byte;
            self.line_length += 1;
        }
    }

    fn finish(self: *CommandReader, output: *[maximum_command_bytes]u8) CommandRead {
        if (self.overflowed) {
            self.line_length = 0;
            self.overflowed = false;
            return .{ .kind = .too_long };
        }
        const length = self.line_length;
        @memcpy(output[0..length], self.line[0..length]);
        self.line_length = 0;
        return .{ .kind = .line, .length = length };
    }
};

pub export fn zigos_main(
    argc: usize,
    argv: [*]const usize,
    _: [*]const usize,
    _: [*]const zigos.AuxvEntry,
) callconv(.c) u32 {
    if (argc != 2) {
        zigos.writeAll(2, "usage: edit FILE\r\n") catch {};
        return status_usage;
    }
    const path: [*:0]const u8 = @ptrFromInt(argv[1]);
    if (!loadDocument(path)) return status_failure;

    zigos.writeAll(1, "edit: ") catch return status_failure;
    writeDecimal(document_length) catch return status_failure;
    zigos.writeAll(1, " bytes\r\ncommands: p | a TEXT | d | w | wq | q\r\n") catch return status_failure;

    var reader: CommandReader = .{};
    var command: [maximum_command_bytes]u8 = undefined;
    while (true) {
        zigos.writeAll(1, "edit> ") catch return status_failure;
        const received = reader.next(&command);
        switch (received.kind) {
            .eof => return status_success,
            .input_error => {
                zigos.writeAll(2, "edit: input error\r\n") catch {};
                return status_failure;
            },
            .too_long => {
                zigos.writeAll(2, "edit: command too long\r\n") catch {};
                continue;
            },
            .line => {},
        }
        const line = command[0..received.length];
        if (line.len == 0) continue;

        if (equal(line, "p")) {
            if (!printDocument()) return status_failure;
        } else if (equal(line, "d")) {
            if (!deleteLastLine()) zigos.writeAll(2, "edit: document is empty\r\n") catch {};
        } else if (equal(line, "w")) {
            if (!saveDocument(path)) return status_failure;
        } else if (equal(line, "wq")) {
            if (!saveDocument(path)) return status_failure;
            return status_success;
        } else if (equal(line, "q")) {
            return status_success;
        } else if (line.len == 1 and line[0] == 'a') {
            if (!appendLine("")) zigos.writeAll(2, "edit: document full\r\n") catch {};
        } else if (line.len >= 2 and line[0] == 'a' and line[1] == ' ') {
            if (!appendLine(line[2..])) zigos.writeAll(2, "edit: document full\r\n") catch {};
        } else {
            zigos.writeAll(2, "edit: command must be p, a TEXT, d, w, wq or q\r\n") catch {};
        }
    }
}

fn loadDocument(path: [*:0]const u8) bool {
    document_length = 0;
    const fd = zigos.open(path, .{ .read = true }, 0) catch |err| {
        if (err == error.NotFound) return true;
        printFileError(err);
        return false;
    };
    defer zigos.close(fd) catch {};

    var bytes: [512]u8 = undefined;
    while (true) {
        const count = zigos.read(fd, &bytes) catch |err| {
            printFileError(err);
            return false;
        };
        if (count == 0) return true;
        if (count > document.len - document_length) {
            zigos.writeAll(2, "edit: file exceeds 4096 bytes\r\n") catch {};
            return false;
        }
        @memcpy(document[document_length .. document_length + count], bytes[0..count]);
        document_length += count;
    }
}

fn printDocument() bool {
    if (document_length == 0) return true;
    zigos.writeAll(1, document[0..document_length]) catch return false;
    if (document[document_length - 1] != '\n') zigos.writeAll(1, "\r\n") catch return false;
    return true;
}

fn appendLine(text: []const u8) bool {
    if (text.len + 1 > document.len - document_length) return false;
    @memcpy(document[document_length .. document_length + text.len], text);
    document_length += text.len;
    document[document_length] = '\n';
    document_length += 1;
    return true;
}

fn deleteLastLine() bool {
    if (document_length == 0) return false;
    var end = document_length;
    if (document[end - 1] == '\n') end -= 1;
    while (end != 0 and document[end - 1] != '\n') end -= 1;
    document_length = end;
    return true;
}

fn saveDocument(path: [*:0]const u8) bool {
    const fd = zigos.open(path, .{ .write = true, .create = true, .truncate = true }, 0o644) catch |err| {
        printFileError(err);
        return false;
    };
    defer zigos.close(fd) catch {};
    zigos.writeAll(fd, document[0..document_length]) catch |err| {
        printFileError(err);
        return false;
    };
    zigos.fsync(fd) catch |err| {
        if (err == error.Unsupported) {
            zigos.sync() catch |sync_err| {
                printFileError(sync_err);
                return false;
            };
        } else {
            printFileError(err);
            return false;
        }
    };
    zigos.writeAll(1, "edit: wrote ") catch return false;
    writeDecimal(document_length) catch return false;
    zigos.writeAll(1, " bytes\r\n") catch return false;
    return true;
}

fn writeDecimal(value: u64) zigos.Error!void {
    var output: [20]u8 = undefined;
    var remaining = value;
    var start = output.len;
    while (true) {
        start -= 1;
        output[start] = @intCast('0' + remaining % 10);
        remaining /= 10;
        if (remaining == 0) break;
    }
    try zigos.writeAll(1, output[start..]);
}

fn equal(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}

fn printFileError(err: zigos.Error) void {
    const message = switch (err) {
        error.NotFound => "edit: not found\r\n",
        error.IsDirectory => "edit: is a directory\r\n",
        error.PermissionDenied, error.AccessDenied => "edit: permission denied\r\n",
        error.ReadOnly => "edit: read-only filesystem\r\n",
        error.NoSpace => "edit: no space\r\n",
        error.NameTooLong => "edit: name too long\r\n",
        error.InputOutput => "edit: input/output error\r\n",
        else => "edit: error\r\n",
    };
    zigos.writeAll(2, message) catch {};
}
