const std = @import("std");
const memory = @import("memory.zig");

const SdtHeader = extern struct {
    signature: [4]u8,
    length: u32 align(1),
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32 align(1),
    creator_id: u32 align(1),
    creator_revision: u32 align(1),
};

const GenericAddress = extern struct {
    address_space_id: u8,
    register_bit_width: u8,
    register_bit_offset: u8,
    access_size: u8,
    address: u64 align(1),
};

const HpetTable = extern struct {
    header: SdtHeader,
    event_timer_block_id: u32 align(1),
    base_address: GenericAddress,
    hpet_number: u8,
    minimum_clock_tick: u16 align(1),
    page_protection: u8,
};

const capabilities_offset: usize = 0x000;
const configuration_offset: usize = 0x010;
const main_counter_offset: usize = 0x0F0;
const enable_counter: u64 = 1;
const legacy_route_enable: u64 = 1 << 1;

pub const Device = struct {
    base_address: usize,
    period_femtoseconds: u32,
    timer_count: u8,
    counter_64_bit: bool,
    revision: u8,
    vendor_id: u16,

    pub fn start(self: Device) void {
        var configuration = self.read64(configuration_offset);
        configuration &= ~@as(u64, enable_counter | legacy_route_enable);
        self.write64(configuration_offset, configuration);
        self.write64(main_counter_offset, 0);
        self.write64(configuration_offset, configuration | enable_counter);
    }

    pub fn readCounter(self: Device) u64 {
        const value = self.read64(main_counter_offset);
        return if (self.counter_64_bit) value else @as(u32, @truncate(value));
    }

    pub fn waitNanoseconds(self: Device, nanoseconds: u64) bool {
        if (self.period_femtoseconds == 0) return false;
        const numerator = @as(u128, nanoseconds) * 1_000_000;
        const ticks_u128 = (numerator + self.period_femtoseconds - 1) / self.period_femtoseconds;
        if (ticks_u128 == 0) return true;
        if (ticks_u128 > std.math.maxInt(u64)) return false;
        const ticks: u64 = @intCast(ticks_u128);

        const start_value = self.readCounter();
        if (self.counter_64_bit) {
            while (self.readCounter() -% start_value < ticks) {}
        } else {
            if (ticks > std.math.maxInt(u32)) return false;
            const start32: u32 = @truncate(start_value);
            const ticks32: u32 = @intCast(ticks);
            while (@as(u32, @truncate(self.readCounter())) -% start32 < ticks32) {}
        }
        return true;
    }

    fn read64(self: Device, offset: usize) u64 {
        const register: *volatile u64 = @ptrFromInt(self.base_address + offset);
        return register.*;
    }

    fn write64(self: Device, offset: usize, value: u64) void {
        const register: *volatile u64 = @ptrFromInt(self.base_address + offset);
        register.* = value;
        _ = register.*;
    }
};

pub fn initialize(table_address: usize) ?Device {
    if (!rangeMapped(table_address, @sizeOf(HpetTable))) return null;
    const table: *const HpetTable = @ptrFromInt(table_address);
    if (!std.mem.eql(u8, &table.header.signature, "HPET")) return null;
    const table_length: usize = @intCast(table.header.length);
    if (table_length < @sizeOf(HpetTable) or !rangeMapped(table_address, table_length)) return null;
    if (!checksumValid(table_address, table_length)) return null;
    if (table.base_address.address_space_id != 0) return null;
    if (table.base_address.address == 0 or table.base_address.address >= memory.four_gib) return null;

    const base: usize = @intCast(table.base_address.address);
    if (!rangeMapped(base, main_counter_offset + @sizeOf(u64))) return null;
    const capabilities: u64 = @as(*volatile u64, @ptrFromInt(base + capabilities_offset)).*;
    const period: u32 = @truncate(capabilities >> 32);
    if (period == 0) return null;

    const device = Device{
        .base_address = base,
        .period_femtoseconds = period,
        .timer_count = @intCast(((capabilities >> 8) & 0x1F) + 1),
        .counter_64_bit = (capabilities & (@as(u64, 1) << 13)) != 0,
        .revision = @truncate(capabilities),
        .vendor_id = @truncate(capabilities >> 16),
    };
    device.start();
    return device;
}

fn rangeMapped(address: usize, length: usize) bool {
    const limit: usize = @intCast(memory.four_gib);
    return address < limit and length <= limit - address;
}

fn checksumValid(address: usize, length: usize) bool {
    const bytes: [*]const u8 = @ptrFromInt(address);
    var sum: u8 = 0;
    for (0..length) |index| sum +%= bytes[index];
    return sum == 0;
}

comptime {
    if (@sizeOf(GenericAddress) != 12) @compileError("ACPI GAS must be 12 bytes");
    if (@sizeOf(HpetTable) != 56) @compileError("ACPI HPET table must be 56 bytes");
}
