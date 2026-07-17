const std = @import("std");

pub const queue_capacity: usize = 32;

pub const Source = enum(u8) {
    ps2,
    usb_hid,
};

pub const Action = enum(u8) {
    pressed,
    released,
};

pub const KeyEvent = struct {
    sequence: u64,
    source: Source,
    action: Action,
    usage: u8,
    modifiers: u8,
    ascii: u8,
};

pub const Queue = struct {
    events: [queue_capacity]KeyEvent,
    head: u32,
    tail: u32,
    next_sequence: u64,
    dropped: u32,

    pub fn init() Queue {
        return .{
            .events = undefined,
            .head = 0,
            .tail = 0,
            .next_sequence = 1,
            .dropped = 0,
        };
    }

    pub fn count(self: *const Queue) usize {
        return @intCast(self.head -% self.tail);
    }

    pub fn push(self: *Queue, source: Source, action: Action, usage: u8, modifiers: u8) bool {
        if (usage == 0) return false;
        if (self.count() >= self.events.len) {
            self.dropped +%= 1;
            return false;
        }
        const index: usize = @intCast(self.head % self.events.len);
        self.events[index] = .{
            .sequence = self.next_sequence,
            .source = source,
            .action = action,
            .usage = usage,
            .modifiers = modifiers,
            .ascii = usageToAscii(usage, modifiers),
        };
        self.next_sequence +%= 1;
        self.head +%= 1;
        return true;
    }

    pub fn pop(self: *Queue) ?KeyEvent {
        if (self.tail == self.head) return null;
        const index: usize = @intCast(self.tail % self.events.len);
        const event = self.events[index];
        self.tail +%= 1;
        return event;
    }

    pub fn applyPs2Set1(self: *Queue, scan_code: u8) bool {
        if (scan_code == 0xE0 or scan_code == 0xE1) return false;
        const released = (scan_code & 0x80) != 0;
        const make_code = scan_code & 0x7F;
        const usage = ps2Set1ToHidUsage(make_code) orelse return false;
        return self.push(
            .ps2,
            if (released) .released else .pressed,
            usage,
            0,
        );
    }

    pub fn applyHidReport(
        self: *Queue,
        previous_keys: *[6]u8,
        previous_modifiers: *u8,
        modifiers: u8,
        keys: [6]u8,
    ) usize {
        var emitted: usize = 0;
        for (previous_keys.*) |usage| {
            if (usage != 0 and !containsUsage(keys, usage)) {
                if (self.push(.usb_hid, .released, usage, previous_modifiers.*)) emitted += 1;
            }
        }
        for (keys) |usage| {
            if (usage != 0 and !containsUsage(previous_keys.*, usage)) {
                if (self.push(.usb_hid, .pressed, usage, modifiers)) emitted += 1;
            }
        }
        previous_keys.* = keys;
        previous_modifiers.* = modifiers;
        return emitted;
    }
};

pub fn usageToAscii(usage: u8, modifiers: u8) u8 {
    const shifted = (modifiers & 0x22) != 0;
    if (usage >= 0x04 and usage <= 0x1D) {
        const base: u8 = if (shifted) 'A' else 'a';
        return base + (usage - 0x04);
    }
    if (usage >= 0x1E and usage <= 0x26) {
        const unshifted = "123456789";
        const shifted_values = "!@#$%^&*(";
        const index: usize = usage - 0x1E;
        return if (shifted) shifted_values[index] else unshifted[index];
    }
    if (usage == 0x27) return if (shifted) ')' else '0';
    return switch (usage) {
        0x28 => '\n',
        0x2B => '\t',
        0x2C => ' ',
        0x2D => if (shifted) '_' else '-',
        0x2E => if (shifted) '+' else '=',
        0x2F => if (shifted) '{' else '[',
        0x30 => if (shifted) '}' else ']',
        0x31 => if (shifted) '|' else '\\',
        0x33 => if (shifted) ':' else ';',
        0x34 => if (shifted) '"' else '\'',
        0x35 => if (shifted) '~' else '`',
        0x36 => if (shifted) '<' else ',',
        0x37 => if (shifted) '>' else '.',
        0x38 => if (shifted) '?' else '/',
        else => 0,
    };
}

fn ps2Set1ToHidUsage(make_code: u8) ?u8 {
    return switch (make_code) {
        0x1E => 0x04,
        0x30 => 0x05,
        0x2E => 0x06,
        0x20 => 0x07,
        0x12 => 0x08,
        0x21 => 0x09,
        0x22 => 0x0A,
        0x23 => 0x0B,
        0x17 => 0x0C,
        0x24 => 0x0D,
        0x25 => 0x0E,
        0x26 => 0x0F,
        0x32 => 0x10,
        0x31 => 0x11,
        0x18 => 0x12,
        0x19 => 0x13,
        0x10 => 0x14,
        0x13 => 0x15,
        0x1F => 0x16,
        0x14 => 0x17,
        0x16 => 0x18,
        0x2F => 0x19,
        0x11 => 0x1A,
        0x2D => 0x1B,
        0x15 => 0x1C,
        0x2C => 0x1D,
        0x02...0x0A => 0x1E + (make_code - 0x02),
        0x0B => 0x27,
        0x1C => 0x28,
        0x0E => 0x2A,
        0x0F => 0x2B,
        0x39 => 0x2C,
        0x0C => 0x2D,
        0x0D => 0x2E,
        0x1A => 0x2F,
        0x1B => 0x30,
        0x2B => 0x31,
        0x27 => 0x33,
        0x28 => 0x34,
        0x29 => 0x35,
        0x33 => 0x36,
        0x34 => 0x37,
        0x35 => 0x38,
        else => null,
    };
}

fn containsUsage(keys: [6]u8, usage: u8) bool {
    for (keys) |candidate| {
        if (candidate == usage) return true;
    }
    return false;
}

comptime {
    if (queue_capacity == 0 or !std.math.isPowerOfTwo(queue_capacity)) {
        @compileError("keyboard event queue capacity must be a nonzero power of two");
    }
}
