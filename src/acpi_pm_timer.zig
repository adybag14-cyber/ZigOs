const std = @import("std");
const memory = @import("memory.zig");

const cc = std.os.uefi.cc;
const frequency_hz_value: u64 = 3_579_545;
const legacy_pm_timer_block_offset: usize = 76;
const pm_timer_length_offset: usize = 91;
const flags_offset: usize = 112;
const extended_pm_timer_block_offset: usize = 208;
const timer_value_extended: u32 = 1 << 8;
const minimum_legacy_fadt_length: usize = pm_timer_length_offset + 1;
const minimum_flags_fadt_length: usize = flags_offset + @sizeOf(u32);
const minimum_extended_fadt_length: usize = extended_pm_timer_block_offset + @sizeOf(GenericAddress);
const maximum_poll_iterations: usize = 100_000_000;

extern fn zigos_in32(port: u16) callconv(cc) u32;

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

pub const AddressSpace = enum(u8) {
    system_memory,
    system_io,
};

pub const Device = struct {
    address_space: AddressSpace,
    address: usize,
    counter_bits: u8,

    pub fn frequencyHz(_: Device) u64 {
        return frequency_hz_value;
    }

    pub fn periodFemtoseconds(_: Device) u32 {
        return 279_365_115;
    }

    pub fn counterMask(self: Device) u64 {
        return if (self.counter_bits == 32) 0xFFFF_FFFF else 0x00FF_FFFF;
    }

    pub fn readCounter(self: Device) u64 {
        const raw: u32 = switch (self.address_space) {
            .system_io => zigos_in32(@intCast(self.address)),
            .system_memory => @as(*volatile u32, @ptrFromInt(self.address)).*,
        };
        return @as(u64, raw) & self.counterMask();
    }

    pub fn elapsedTicks(self: Device, start: u64, current: u64) u64 {
        return (current -% start) & self.counterMask();
    }

    pub fn waitNanoseconds(self: Device, nanoseconds: u64) bool {
        if (nanoseconds == 0) return true;
        const numerator = @as(u128, nanoseconds) * frequency_hz_value;
        const ticks_u128 = (numerator + 999_999_999) / 1_000_000_000;
        if (ticks_u128 == 0 or ticks_u128 > self.counterMask()) return false;
        const ticks: u64 = @intCast(ticks_u128);
        const start = self.readCounter();
        var iteration: usize = 0;
        while (iteration < maximum_poll_iterations) : (iteration += 1) {
            if (self.elapsedTicks(start, self.readCounter()) >= ticks) return true;
        }
        return false;
    }
};

pub fn initialize(fadt_address: usize) ?Device {
    if (!rangeMapped(fadt_address, @sizeOf(SdtHeader))) return null;
    const header: *const SdtHeader = @ptrFromInt(fadt_address);
    if (!std.mem.eql(u8, &header.signature, "FACP")) return null;
    const table_length: usize = @intCast(header.length);
    if (table_length < minimum_legacy_fadt_length or !rangeMapped(fadt_address, table_length)) return null;
    if (!checksumValid(fadt_address, table_length)) return null;

    const flags = if (table_length >= minimum_flags_fadt_length)
        readU32(fadt_address + flags_offset)
    else
        0;
    const counter_bits: u8 = if ((flags & timer_value_extended) != 0) 32 else 24;

    if (table_length >= minimum_extended_fadt_length) {
        const gas: *const GenericAddress = @ptrFromInt(fadt_address + extended_pm_timer_block_offset);
        if (gas.address != 0) {
            if (deviceFromGas(gas.*, counter_bits)) |device| return device;
        }
    }

    const legacy_address = readU32(fadt_address + legacy_pm_timer_block_offset);
    const timer_length = readU8(fadt_address + pm_timer_length_offset);
    if (legacy_address == 0 or legacy_address > std.math.maxInt(u16) or timer_length < 4) return null;
    return .{
        .address_space = .system_io,
        .address = @intCast(legacy_address),
        .counter_bits = counter_bits,
    };
}

fn deviceFromGas(gas: GenericAddress, counter_bits: u8) ?Device {
    if (gas.register_bit_offset != 0) return null;
    if (gas.register_bit_width != 0 and gas.register_bit_width < counter_bits) return null;
    return switch (gas.address_space_id) {
        0 => blk: {
            if (gas.address == 0 or gas.address >= memory.four_gib) break :blk null;
            const address: usize = @intCast(gas.address);
            if (!rangeMapped(address, @sizeOf(u32))) break :blk null;
            break :blk .{
                .address_space = .system_memory,
                .address = address,
                .counter_bits = counter_bits,
            };
        },
        1 => blk: {
            if (gas.address == 0 or gas.address > std.math.maxInt(u16)) break :blk null;
            break :blk .{
                .address_space = .system_io,
                .address = @intCast(gas.address),
                .counter_bits = counter_bits,
            };
        },
        else => null,
    };
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

fn readU8(address: usize) u8 {
    return @as(*const u8, @ptrFromInt(address)).*;
}

fn readU32(address: usize) u32 {
    const bytes: [*]const u8 = @ptrFromInt(address);
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

comptime {
    if (@sizeOf(SdtHeader) != 36) @compileError("ACPI SDT header must be 36 bytes");
    if (@sizeOf(GenericAddress) != 12) @compileError("ACPI GAS must be 12 bytes");
}
