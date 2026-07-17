const std = @import("std");
const hpet = @import("hpet.zig");

const cc = std.os.uefi.cc;
const pit_input_frequency_hz: u64 = 1_193_182;
const pit_channel2_data_port: u16 = 0x42;
const pit_command_port: u16 = 0x43;
const pit_speaker_control_port: u16 = 0x61;
const pit_channel2_one_shot_lo_hi: u8 = 0xB0;
const pit_gate2: u8 = 1 << 0;
const pit_speaker_enable: u8 = 1 << 1;
const pit_output2: u8 = 1 << 5;
const maximum_pit_chunk_nanoseconds: u64 = 50_000_000;
const maximum_poll_iterations: usize = 100_000_000;

extern fn zigos_out8(port: u16, value: u8) callconv(cc) void;
extern fn zigos_in8(port: u16) callconv(cc) u8;

pub const Kind = enum {
    hpet,
    pit_channel2,
};

pub const Reference = struct {
    kind: Kind,
    hpet_device: ?hpet.Device,

    pub fn initialize(hpet_table_address: ?usize) ?Reference {
        if (hpet_table_address) |table_address| {
            if (hpet.initialize(table_address)) |device| {
                return .{
                    .kind = .hpet,
                    .hpet_device = device,
                };
            }
        }

        const reference = Reference{
            .kind = .pit_channel2,
            .hpet_device = null,
        };
        if (!reference.waitNanoseconds(100_000)) return null;
        return reference;
    }

    pub fn waitNanoseconds(self: Reference, nanoseconds: u64) bool {
        if (nanoseconds == 0) return true;
        return switch (self.kind) {
            .hpet => self.hpet_device.?.waitNanoseconds(nanoseconds),
            .pit_channel2 => waitPitNanoseconds(nanoseconds),
        };
    }

    pub fn sourceName(self: Reference) []const u8 {
        return switch (self.kind) {
            .hpet => "HPET",
            .pit_channel2 => "PIT channel 2",
        };
    }

    pub fn baseAddress(self: Reference) usize {
        return switch (self.kind) {
            .hpet => self.hpet_device.?.base_address,
            .pit_channel2 => 0,
        };
    }

    pub fn periodFemtoseconds(self: Reference) u32 {
        return switch (self.kind) {
            .hpet => self.hpet_device.?.period_femtoseconds,
            .pit_channel2 => 0,
        };
    }

    pub fn timerCount(self: Reference) u8 {
        return switch (self.kind) {
            .hpet => self.hpet_device.?.timer_count,
            .pit_channel2 => 1,
        };
    }

    pub fn counter64Bit(self: Reference) bool {
        return switch (self.kind) {
            .hpet => self.hpet_device.?.counter_64_bit,
            .pit_channel2 => false,
        };
    }
};

fn waitPitNanoseconds(total_nanoseconds: u64) bool {
    const original_control = zigos_in8(pit_speaker_control_port);
    defer zigos_out8(pit_speaker_control_port, original_control);

    var remaining = total_nanoseconds;
    while (remaining != 0) {
        const chunk = @min(remaining, maximum_pit_chunk_nanoseconds);
        const numerator = @as(u128, chunk) * pit_input_frequency_hz;
        const ticks_u128 = (numerator + 999_999_999) / 1_000_000_000;
        if (ticks_u128 == 0 or ticks_u128 > std.math.maxInt(u16)) return false;
        const ticks: u16 = @intCast(ticks_u128);

        const gate_low = original_control & ~@as(u8, pit_gate2 | pit_speaker_enable);
        zigos_out8(pit_speaker_control_port, gate_low);
        zigos_out8(pit_command_port, pit_channel2_one_shot_lo_hi);
        zigos_out8(pit_channel2_data_port, @truncate(ticks));
        zigos_out8(pit_channel2_data_port, @truncate(ticks >> 8));
        zigos_out8(pit_speaker_control_port, gate_low | pit_gate2);

        var iteration: usize = 0;
        while (iteration < maximum_poll_iterations) : (iteration += 1) {
            if ((zigos_in8(pit_speaker_control_port) & pit_output2) != 0) break;
        }
        if (iteration == maximum_poll_iterations) return false;
        remaining -= chunk;
    }
    return true;
}
