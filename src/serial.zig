const std = @import("std");

const cc = std.os.uefi.cc;
const com1_base: u16 = 0x03F8;
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

pub fn basePort() u16 {
    return com1_base;
}
