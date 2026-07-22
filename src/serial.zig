const std = @import("std");

const cc = std.os.uefi.cc;
const com1_base: u16 = 0x03F8;
const receive_ready: u8 = 1 << 0;
const overrun_error: u8 = 1 << 1;
const parity_error: u8 = 1 << 2;
const framing_error: u8 = 1 << 3;
const break_interrupt: u8 = 1 << 4;
const transmit_ready: u8 = 1 << 5;
const maximum_poll_count: usize = 1_000_000;

extern fn zigos_out8(port: u16, value: u8) callconv(cc) void;
extern fn zigos_in8(port: u16) callconv(cc) u8;

var ready: bool = false;

pub fn initialize() bool {
    ready = false;

    zigos_out8(com1_base + 1, 0x00);
    zigos_out8(com1_base + 3, 0x80);
    zigos_out8(com1_base + 0, 0x01);
    zigos_out8(com1_base + 1, 0x00);
    zigos_out8(com1_base + 3, 0x03);
    zigos_out8(com1_base + 2, 0xC7);

    zigos_out8(com1_base + 4, 0x1E);
    zigos_out8(com1_base + 0, 0xAE);
    if (zigos_in8(com1_base + 0) != 0xAE) return false;

    zigos_out8(com1_base + 4, 0x0F);
    ready = true;
    return true;
}

pub fn isReady() bool {
    return ready;
}

pub fn putByte(value: u8) bool {
    if (!ready) return false;

    var polls: usize = 0;
    while ((zigos_in8(com1_base + 5) & transmit_ready) == 0) : (polls += 1) {
        if (polls >= maximum_poll_count) {
            ready = false;
            return false;
        }
    }

    zigos_out8(com1_base, value);
    return true;
}

pub fn write(text: []const u8) bool {
    for (text) |character| {
        if (!putByte(character)) return false;
    }
    return true;
}

pub const ReceiveStatus = struct {
    byte: ?u8,
    line_error: bool,
};

pub fn tryRead() ReceiveStatus {
    if (!ready) return .{ .byte = null, .line_error = false };
    const status = zigos_in8(com1_base + 5);
    const line_error = (status & (overrun_error | parity_error | framing_error | break_interrupt)) != 0;
    if ((status & receive_ready) == 0) return .{ .byte = null, .line_error = line_error };
    return .{ .byte = zigos_in8(com1_base), .line_error = line_error };
}

pub fn tryReadByte() ?u8 {
    return tryRead().byte;
}

pub fn drain(output: []u8) usize {
    var count: usize = 0;
    while (count < output.len) {
        output[count] = tryReadByte() orelse break;
        count += 1;
    }
    return count;
}

pub fn basePort() u16 {
    return com1_base;
}
