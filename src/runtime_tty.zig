const std = @import("std");
const runtime_abi = @import("runtime_abi.zig");
const runtime_process = @import("runtime_process.zig");

pub const input_capacity: usize = 4096;
pub const edit_capacity: usize = 256;
const terminal_wait_key: u64 = 0x5454_5900_0000_0001;

pub const EchoAction = enum(u8) {
    none,
    byte,
    erase_one,
    erase_line,
    newline,
    interrupt,
    bell,
};

pub const FeedResult = struct {
    echo: EchoAction = .none,
    byte: u8 = 0,
    erased: usize = 0,
    wakeups: usize = 0,
    signalled: usize = 0,
};

pub const ReadStatus = enum(u8) {
    complete,
    eof,
    blocked,
};

pub const ReadResult = struct {
    status: ReadStatus,
    count: usize = 0,
};

pub const Report = struct {
    foreground_process_group: u32,
    foreground_session: u32,
    buffered_bytes: usize,
    edited_bytes: usize,
    eof_events: usize,
    submitted_lines: u64,
    bytes_submitted: u64,
    bytes_read: u64,
    blocked_reads: u64,
    reader_wakeups: u64,
    erase_events: u64,
    interrupt_events: u64,
    overflow_events: u64,
};

pub const Tty = struct {
    controller_handle: u64 = 0,
    foreground_process_group: u32 = 0,
    foreground_session: u32 = 0,
    input: [input_capacity]u8 = @splat(0),
    input_read: usize = 0,
    input_write: usize = 0,
    input_count: usize = 0,
    edit: [edit_capacity]u8 = @splat(0),
    edit_length: usize = 0,
    eof_events: usize = 0,
    ignore_next_lf: bool = false,
    echo_enabled: bool = true,
    canonical_enabled: bool = true,
    signals_enabled: bool = true,
    submitted_lines: u64 = 0,
    bytes_submitted: u64 = 0,
    bytes_read: u64 = 0,
    blocked_reads: u64 = 0,
    reader_wakeups: u64 = 0,
    erase_events: u64 = 0,
    interrupt_events: u64 = 0,
    overflow_events: u64 = 0,

    pub fn init(controller_handle: u64) Tty {
        var tty: Tty = .{};
        tty.initialize(controller_handle);
        return tty;
    }

    pub fn initialize(self: *Tty, controller_handle: u64) void {
        self.* = .{ .controller_handle = controller_handle };
    }

    pub fn setForeground(self: *Tty, processes: *const runtime_process.Table, process_handle: u64) runtime_process.Error!void {
        const process = try processes.get(process_handle);
        if (process.process_group == 0 or process.session == 0) return runtime_process.Error.InvalidState;
        self.foreground_process_group = process.process_group;
        self.foreground_session = process.session;
        self.edit_length = 0;
        self.ignore_next_lf = false;
    }

    pub fn foregroundMatches(self: *const Tty, processes: *const runtime_process.Table, process_handle: u64) runtime_process.Error!bool {
        const process = try processes.get(process_handle);
        return self.foreground_process_group != 0 and
            process.process_group == self.foreground_process_group and
            process.session == self.foreground_session;
    }

    pub fn feed(self: *Tty, processes: *runtime_process.Table, byte: u8) FeedResult {
        if (self.ignore_next_lf and byte == '\n') {
            self.ignore_next_lf = false;
            return .{};
        }
        self.ignore_next_lf = byte == '\r';
        const normalized = if (byte == '\r') '\n' else byte;

        if (self.signals_enabled and normalized == 0x03) {
            self.edit_length = 0;
            self.interrupt_events +%= 1;
            const signalled = if (self.foreground_process_group == 0)
                0
            else
                processes.sendGroupSignal(self.controller_handle, self.foreground_process_group, 2) catch 0;
            if (signalled != 0) self.applyInterruptDefault(processes);
            return .{
                .echo = if (self.echo_enabled) .interrupt else .none,
                .signalled = signalled,
            };
        }

        if (self.canonical_enabled) {
            return self.feedCanonical(processes, normalized);
        }
        if (!self.pushByte(normalized)) {
            self.overflow_events +%= 1;
            return .{ .echo = if (self.echo_enabled) .bell else .none };
        }
        const wakeups = processes.wakeMatching(.terminal_read, terminal_wait_key, true);
        self.reader_wakeups +%= wakeups;
        self.bytes_submitted +%= 1;
        return .{
            .echo = if (self.echo_enabled) .byte else .none,
            .byte = normalized,
            .wakeups = wakeups,
        };
    }

    pub fn read(
        self: *Tty,
        processes: *runtime_process.Table,
        process_handle: u64,
        output: []u8,
    ) runtime_process.Error!ReadResult {
        if (!(try self.foregroundMatches(processes, process_handle))) return runtime_process.Error.PermissionDenied;
        if (output.len == 0) return .{ .status = .complete };
        if (self.input_count != 0) {
            const count = @min(output.len, self.input_count);
            for (output[0..count]) |*destination| {
                destination.* = self.input[self.input_read];
                self.input_read = (self.input_read + 1) % self.input.len;
                self.input_count -= 1;
            }
            self.bytes_read +%= count;
            return .{ .status = .complete, .count = count };
        }
        if (self.eof_events != 0) {
            self.eof_events -= 1;
            return .{ .status = .eof };
        }
        try processes.block(process_handle, .terminal_read, terminal_wait_key);
        self.blocked_reads +%= 1;
        return .{ .status = .blocked };
    }

    pub fn poll(
        self: *const Tty,
        processes: *const runtime_process.Table,
        process_handle: u64,
        requested: u16,
    ) runtime_process.Error!u16 {
        if (!(try self.foregroundMatches(processes, process_handle))) return runtime_process.Error.PermissionDenied;
        var ready: u16 = 0;
        if (self.input_count != 0 or self.eof_events != 0) ready |= runtime_abi.poll_readable;
        return ready & requested;
    }

    pub fn report(self: *const Tty) Report {
        return .{
            .foreground_process_group = self.foreground_process_group,
            .foreground_session = self.foreground_session,
            .buffered_bytes = self.input_count,
            .edited_bytes = self.edit_length,
            .eof_events = self.eof_events,
            .submitted_lines = self.submitted_lines,
            .bytes_submitted = self.bytes_submitted,
            .bytes_read = self.bytes_read,
            .blocked_reads = self.blocked_reads,
            .reader_wakeups = self.reader_wakeups,
            .erase_events = self.erase_events,
            .interrupt_events = self.interrupt_events,
            .overflow_events = self.overflow_events,
        };
    }

    fn applyInterruptDefault(self: *const Tty, processes: *runtime_process.Table) void {
        for (0..runtime_process.maximum_processes) |slot| {
            const process = processes.processAt(slot) orelse continue;
            if (process.process_group != self.foreground_process_group or process.terminal()) continue;
            const handle = process.handle;
            processes.exit(handle, 130) catch {};
        }
    }

    fn feedCanonical(self: *Tty, processes: *runtime_process.Table, byte: u8) FeedResult {
        switch (byte) {
            0x08, 0x7F => {
                if (self.edit_length == 0) return .{};
                self.edit_length -= 1;
                self.erase_events +%= 1;
                return .{ .echo = if (self.echo_enabled) .erase_one else .none, .erased = 1 };
            },
            0x15 => {
                const erased = self.edit_length;
                self.edit_length = 0;
                if (erased != 0) self.erase_events +%= 1;
                return .{ .echo = if (self.echo_enabled and erased != 0) .erase_line else .none, .erased = erased };
            },
            0x04 => {
                if (self.edit_length == 0) {
                    self.eof_events +%= 1;
                    const wakeups = processes.wakeMatching(.terminal_read, terminal_wait_key, true);
                    self.reader_wakeups +%= wakeups;
                    return .{ .wakeups = wakeups };
                }
                return self.commitLine(processes, false);
            },
            '\n' => return self.commitLine(processes, true),
            '\t', 0x20...0x7E => {
                if (self.edit_length >= self.edit.len) {
                    self.overflow_events +%= 1;
                    return .{ .echo = if (self.echo_enabled) .bell else .none };
                }
                self.edit[self.edit_length] = byte;
                self.edit_length += 1;
                return .{ .echo = if (self.echo_enabled) .byte else .none, .byte = byte };
            },
            else => return .{},
        }
    }

    fn commitLine(self: *Tty, processes: *runtime_process.Table, include_newline: bool) FeedResult {
        const required = self.edit_length + @intFromBool(include_newline);
        if (required > self.input.len - self.input_count) {
            self.edit_length = 0;
            self.overflow_events +%= 1;
            return .{ .echo = if (self.echo_enabled) .bell else .none };
        }
        for (self.edit[0..self.edit_length]) |byte| _ = self.pushByte(byte);
        if (include_newline) _ = self.pushByte('\n');
        self.bytes_submitted +%= required;
        self.submitted_lines +%= 1;
        self.edit_length = 0;
        const wakeups = processes.wakeMatching(.terminal_read, terminal_wait_key, true);
        self.reader_wakeups +%= wakeups;
        return .{
            .echo = if (self.echo_enabled and include_newline) .newline else .none,
            .wakeups = wakeups,
        };
    }

    fn pushByte(self: *Tty, byte: u8) bool {
        if (self.input_count >= self.input.len) return false;
        self.input[self.input_write] = byte;
        self.input_write = (self.input_write + 1) % self.input.len;
        self.input_count += 1;
        return true;
    }
};

test "canonical terminal blocks edits wakes and returns one line" {
    var processes = runtime_process.Table.init(0);
    const root = processes.initHandle();
    const child = try processes.spawn(root, .userspace, "reader", &.{}, 0, 0, 0, 1, .{});
    try processes.setProcessGroup(root, child, 0);
    var tty = Tty.init(root);
    try tty.setForeground(&processes, child);

    var bytes: [32]u8 = undefined;
    try std.testing.expectEqual(ReadStatus.blocked, (try tty.read(&processes, child, &bytes)).status);
    try std.testing.expectEqual(runtime_process.State.blocked, (try processes.get(child)).state);
    _ = tty.feed(&processes, 'a');
    _ = tty.feed(&processes, 'b');
    try std.testing.expectEqual(EchoAction.erase_one, tty.feed(&processes, 0x7F).echo);
    _ = tty.feed(&processes, 'c');
    const submitted = tty.feed(&processes, '\r');
    try std.testing.expectEqual(EchoAction.newline, submitted.echo);
    try std.testing.expectEqual(@as(usize, 1), submitted.wakeups);
    try std.testing.expectEqual(runtime_process.State.runnable, (try processes.get(child)).state);

    const read_result = try tty.read(&processes, child, &bytes);
    try std.testing.expectEqual(ReadStatus.complete, read_result.status);
    try std.testing.expectEqualStrings("ac\n", bytes[0..read_result.count]);
    try std.testing.expectEqual(@as(u16, 0), try tty.poll(&processes, child, runtime_abi.poll_readable));
}

test "terminal foreground isolation eof and interrupt semantics" {
    var processes = runtime_process.Table.init(0);
    const root = processes.initHandle();
    const foreground = try processes.spawn(root, .userspace, "front", &.{}, 0, 0, 0, 1, .{});
    const background = try processes.spawn(root, .userspace, "back", &.{}, 0, 0, 0, 1, .{});
    try processes.setProcessGroup(root, foreground, 0);
    try processes.setProcessGroup(root, background, 0);
    var tty = Tty.init(root);
    try tty.setForeground(&processes, foreground);

    var byte: [1]u8 = undefined;
    try std.testing.expectError(runtime_process.Error.PermissionDenied, tty.read(&processes, background, &byte));
    _ = tty.feed(&processes, 0x04);
    try std.testing.expectEqual(ReadStatus.eof, (try tty.read(&processes, foreground, &byte)).status);

    const interrupted = tty.feed(&processes, 0x03);
    try std.testing.expectEqual(EchoAction.interrupt, interrupted.echo);
    try std.testing.expectEqual(@as(usize, 1), interrupted.signalled);
    try std.testing.expectEqual(runtime_process.State.zombie, (try processes.get(foreground)).state);
    try std.testing.expectEqual(@as(u32, 130), (try processes.get(foreground)).exit_status);
}
