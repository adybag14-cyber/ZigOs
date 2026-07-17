const std = @import("std");
const apic = @import("apic.zig");

const cc = std.os.uefi.cc;
const channel0_data_port: u16 = 0x40;
const command_port: u16 = 0x43;
const channel0_one_shot_lo_hi: u8 = 0x30;
const input_frequency_hz: u64 = 1_193_182;

extern fn zigos_out8(port: u16, value: u8) callconv(cc) void;
extern fn zigos_wait_for_interrupt() callconv(cc) void;

var interrupt_count: u32 = 0;

pub fn reset() void {
    @atomicStore(u32, &interrupt_count, 0, .release);
}

pub fn count() u32 {
    return @atomicLoad(u32, &interrupt_count, .acquire);
}

pub fn armOneShotMilliseconds(milliseconds: u32) ?u16 {
    if (milliseconds == 0) return null;
    const numerator = input_frequency_hz * @as(u64, milliseconds);
    const divisor_u64 = (numerator + 999) / 1000;
    if (divisor_u64 == 0 or divisor_u64 > std.math.maxInt(u16)) return null;
    const divisor: u16 = @intCast(divisor_u64);

    zigos_out8(command_port, channel0_one_shot_lo_hi);
    zigos_out8(channel0_data_port, @truncate(divisor));
    zigos_out8(channel0_data_port, @truncate(divisor >> 8));
    return divisor;
}

pub fn waitForInterrupt() void {
    zigos_wait_for_interrupt();
}

export fn zigos_pit_irq_handler() callconv(cc) void {
    _ = @atomicRmw(u32, &interrupt_count, .Add, 1, .acq_rel);
    apic.acknowledgeInterrupt();
}
