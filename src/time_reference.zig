const std = @import("std");
const hpet = @import("hpet.zig");
const acpi_pm_timer = @import("acpi_pm_timer.zig");

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
    acpi_pm_timer,
    pit_channel2,
};

pub const Reference = struct {
    kind: Kind,
    hpet_device: ?hpet.Device,
    pm_timer_device: ?acpi_pm_timer.Device,

    pub fn initialize(hpet_table_address: ?usize, facp_table_address: ?usize) ?Reference {
        if (hpet_table_address) |table_address| {
            if (hpet.initialize(table_address)) |device| {
                return .{
                    .kind = .hpet,
                    .hpet_device = device,
                    .pm_timer_device = null,
                };
            }
        }
        if (facp_table_address) |table_address| {
            if (acpi_pm_timer.initialize(table_address)) |device| {
                return .{
                    .kind = .acpi_pm_timer,
                    .hpet_device = null,
                    .pm_timer_device = device,
                };
            }
        }

        const reference = Reference{
            .kind = .pit_channel2,
            .hpet_device = null,
            .pm_timer_device = null,
        };
        if (!reference.waitNanoseconds(100_000)) return null;
        return reference;
    }

    pub fn waitNanoseconds(self: Reference, nanoseconds: u64) bool {
        if (nanoseconds == 0) return true;
        return switch (self.kind) {
            .hpet => self.hpet_device.?.waitNanoseconds(nanoseconds),
            .acpi_pm_timer => self.pm_timer_device.?.waitNanoseconds(nanoseconds),
            .pit_channel2 => waitPitNanoseconds(nanoseconds),
        };
    }

    pub fn sourceName(self: Reference) []const u8 {
        return switch (self.kind) {
            .hpet => "HPET",
            .acpi_pm_timer => "ACPI PM timer",
            .pit_channel2 => "PIT channel 2",
        };
    }

    pub fn baseAddress(self: Reference) usize {
        return switch (self.kind) {
            .hpet => self.hpet_device.?.base_address,
            .acpi_pm_timer => self.pm_timer_device.?.address,
            .pit_channel2 => 0,
        };
    }

    pub fn periodFemtoseconds(self: Reference) u32 {
        return switch (self.kind) {
            .hpet => self.hpet_device.?.period_femtoseconds,
            .acpi_pm_timer => self.pm_timer_device.?.periodFemtoseconds(),
            .pit_channel2 => 0,
        };
    }

    pub fn timerCount(self: Reference) u8 {
        return switch (self.kind) {
            .hpet => self.hpet_device.?.timer_count,
            .acpi_pm_timer, .pit_channel2 => 1,
        };
    }

    pub fn counter64Bit(self: Reference) bool {
        return switch (self.kind) {
            .hpet => self.hpet_device.?.counter_64_bit,
            .acpi_pm_timer, .pit_channel2 => false,
        };
    }

    pub fn counterBits(self: Reference) u8 {
        return switch (self.kind) {
            .hpet => if (self.hpet_device.?.counter_64_bit) 64 else 32,
            .acpi_pm_timer => self.pm_timer_device.?.counter_bits,
            .pit_channel2 => 0,
        };
    }

    pub fn continuousFrequencyHz(self: Reference) ?u64 {
        return switch (self.kind) {
            .hpet => blk: {
                const period = self.hpet_device.?.period_femtoseconds;
                if (period == 0) break :blk null;
                break :blk @intCast((@as(u128, 1_000_000_000_000_000) + period / 2) / period);
            },
            .acpi_pm_timer => self.pm_timer_device.?.frequencyHz(),
            .pit_channel2 => null,
        };
    }

    pub fn rawCounter(self: Reference) ?u64 {
        return switch (self.kind) {
            .hpet => self.hpet_device.?.readCounter(),
            .acpi_pm_timer => self.pm_timer_device.?.readCounter(),
            .pit_channel2 => null,
        };
    }

    pub fn counterMask(self: Reference) u64 {
        return switch (self.kind) {
            .hpet => if (self.hpet_device.?.counter_64_bit) std.math.maxInt(u64) else std.math.maxInt(u32),
            .acpi_pm_timer => self.pm_timer_device.?.counterMask(),
            .pit_channel2 => 0,
        };
    }

    pub fn addressSpaceName(self: Reference) []const u8 {
        return switch (self.kind) {
            .acpi_pm_timer => switch (self.pm_timer_device.?.address_space) {
                .system_io => "system I/O",
                .system_memory => "system memory",
            },
            .hpet => "system memory",
            .pit_channel2 => "system I/O",
        };
    }
};

pub const ContinuousCounter = struct {
    reference: Reference,
    last_raw: u64,
    extended: u64,
    mask: u64,
    frequency_hz: u64,
    counter_bits: u8,

    pub fn initialize(reference: Reference) ?ContinuousCounter {
        const frequency_hz = reference.continuousFrequencyHz() orelse return null;
        const raw = reference.rawCounter() orelse return null;
        const mask = reference.counterMask();
        if (frequency_hz == 0 or mask == 0) return null;
        return .{
            .reference = reference,
            .last_raw = raw,
            .extended = raw,
            .mask = mask,
            .frequency_hz = frequency_hz,
            .counter_bits = reference.counterBits(),
        };
    }

    pub fn read(self: *ContinuousCounter) u64 {
        const raw = self.reference.rawCounter().?;
        const delta = (raw -% self.last_raw) & self.mask;
        self.extended +%= delta;
        self.last_raw = raw;
        return self.extended;
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
