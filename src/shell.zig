const std = @import("std");
const input = @import("input.zig");

pub const maximum_line_length: usize = 64;

pub const Response = enum {
    help,
    cpu,
    memory,
    scroll,
    clear_screen,
    empty,
    unknown,
};

pub const Shell = struct {
    line: [maximum_line_length]u8,
    line_length: usize,
    executed_line: [maximum_line_length]u8,
    executed_length: usize,
    command_count: u32,
    rejected_characters: u32,

    pub fn init() Shell {
        return .{
            .line = undefined,
            .line_length = 0,
            .executed_line = undefined,
            .executed_length = 0,
            .command_count = 0,
            .rejected_characters = 0,
        };
    }

    pub fn feed(self: *Shell, event: input.KeyEvent) ?Response {
        if (event.action != .pressed) return null;
        const character = event.ascii;
        if (character == 0) return null;
        if (character == '\n') return self.execute();
        if (character == 0x08 or character == 0x7F) {
            if (self.line_length != 0) self.line_length -= 1;
            return null;
        }
        if (character < 0x20 or character > 0x7E) {
            self.rejected_characters +%= 1;
            return null;
        }
        if (self.line_length >= self.line.len) {
            self.rejected_characters +%= 1;
            return null;
        }
        self.line[self.line_length] = character;
        self.line_length += 1;
        return null;
    }

    pub fn executedCommand(self: *const Shell) []const u8 {
        return self.executed_line[0..self.executed_length];
    }

    pub fn responseText(response: Response) []const u8 {
        return switch (response) {
            .help => "commands: help cpu mem scroll clear",
            .cpu => "cpu: x86-64 SMP online",
            .memory => "memory: normalized UEFI layout active",
            .scroll => "scroll: 32 lines",
            .clear_screen => "clear: screen reset",
            .empty => "",
            .unknown => "error: unknown command",
        };
    }

    fn execute(self: *Shell) Response {
        const command = std.mem.trim(u8, self.line[0..self.line_length], " \t");
        self.executed_length = command.len;
        if (command.len != 0) @memcpy(self.executed_line[0..command.len], command);
        self.line_length = 0;
        self.command_count +%= 1;

        if (command.len == 0) return .empty;
        if (std.mem.eql(u8, command, "help")) return .help;
        if (std.mem.eql(u8, command, "cpu")) return .cpu;
        if (std.mem.eql(u8, command, "mem")) return .memory;
        if (std.mem.eql(u8, command, "scroll")) return .scroll;
        if (std.mem.eql(u8, command, "clear")) return .clear_screen;
        return .unknown;
    }
};
