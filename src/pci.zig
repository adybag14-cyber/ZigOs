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

const McfgHeader = extern struct {
    header: SdtHeader,
    reserved: u64 align(1),
};

const McfgAllocation = extern struct {
    base_address: u64 align(1),
    segment_group: u16 align(1),
    start_bus: u8,
    end_bus: u8,
    reserved: u32 align(1),
};

pub const Function = struct {
    configuration_address: usize,
    segment: u16,
    bus: u8,
    device: u8,
    function: u8,
    vendor_id: u16,
    device_id: u16,
    class_code: u8,
    subclass: u8,
    programming_interface: u8,
    revision: u8,
    header_type: u8,
};

pub const maximum_retained_functions: usize = 64;

pub const Inventory = struct {
    mcfg_address: usize,
    allocation_count: usize,
    scanned_bus_count: usize,
    function_count: usize,
    retained_count: usize,
    bridge_count: usize,
    functions: [maximum_retained_functions]Function,
};

pub fn enumerate(mcfg_address: usize) ?Inventory {
    if (!rangeMapped(mcfg_address, @sizeOf(McfgHeader))) return null;
    const mcfg: *const McfgHeader = @ptrFromInt(mcfg_address);
    if (!std.mem.eql(u8, &mcfg.header.signature, "MCFG")) return null;

    const table_length: usize = @intCast(mcfg.header.length);
    if (table_length < @sizeOf(McfgHeader) or !rangeMapped(mcfg_address, table_length)) return null;
    if (!checksumValid(mcfg_address, table_length)) return null;

    const allocation_bytes = table_length - @sizeOf(McfgHeader);
    if (allocation_bytes % @sizeOf(McfgAllocation) != 0) return null;
    const allocation_count = allocation_bytes / @sizeOf(McfgAllocation);
    if (allocation_count == 0) return null;

    var inventory = Inventory{
        .mcfg_address = mcfg_address,
        .allocation_count = allocation_count,
        .scanned_bus_count = 0,
        .function_count = 0,
        .retained_count = 0,
        .bridge_count = 0,
        .functions = undefined,
    };

    const allocations_address = mcfg_address + @sizeOf(McfgHeader);
    var allocation_index: usize = 0;
    while (allocation_index < allocation_count) : (allocation_index += 1) {
        const allocation_address = allocations_address + allocation_index * @sizeOf(McfgAllocation);
        const allocation: *const McfgAllocation = @ptrFromInt(allocation_address);
        if (!validateAllocation(allocation.*)) return null;

        var bus_value: u16 = allocation.start_bus;
        while (bus_value <= allocation.end_bus) : (bus_value += 1) {
            inventory.scanned_bus_count += 1;
            const bus: u8 = @intCast(bus_value);
            enumerateBus(&inventory, allocation.*, bus);
        }
    }

    return inventory;
}

fn enumerateBus(inventory: *Inventory, allocation: McfgAllocation, bus: u8) void {
    var device: u8 = 0;
    while (device < 32) : (device += 1) {
        const function_zero_address = functionAddress(allocation, bus, device, 0);
        const vendor_zero = read16(function_zero_address, 0x00);
        if (vendor_zero == 0xFFFF) continue;

        retainFunction(inventory, allocation.segment_group, bus, device, 0, function_zero_address);
        const header_type = read8(function_zero_address, 0x0E);
        if ((header_type & 0x80) == 0) continue;

        var function: u8 = 1;
        while (function < 8) : (function += 1) {
            const address = functionAddress(allocation, bus, device, function);
            if (read16(address, 0x00) == 0xFFFF) continue;
            retainFunction(inventory, allocation.segment_group, bus, device, function, address);
        }
    }
}

fn retainFunction(
    inventory: *Inventory,
    segment: u16,
    bus: u8,
    device: u8,
    function: u8,
    address: usize,
) void {
    const class_code = read8(address, 0x0B);
    const subclass = read8(address, 0x0A);
    if (class_code == 0x06 and subclass == 0x04) inventory.bridge_count += 1;

    if (inventory.retained_count < inventory.functions.len) {
        inventory.functions[inventory.retained_count] = .{
            .configuration_address = address,
            .segment = segment,
            .bus = bus,
            .device = device,
            .function = function,
            .vendor_id = read16(address, 0x00),
            .device_id = read16(address, 0x02),
            .class_code = class_code,
            .subclass = subclass,
            .programming_interface = read8(address, 0x09),
            .revision = read8(address, 0x08),
            .header_type = read8(address, 0x0E),
        };
        inventory.retained_count += 1;
    }
    inventory.function_count += 1;
}

fn validateAllocation(allocation: McfgAllocation) bool {
    if (allocation.start_bus > allocation.end_bus) return false;
    if ((allocation.base_address & 0xFFFFF) != 0) return false;
    if (allocation.base_address >= memory.four_gib) return false;

    const bus_count = @as(u64, allocation.end_bus) - allocation.start_bus + 1;
    const byte_count = bus_count << 20;
    return byte_count <= memory.four_gib - allocation.base_address;
}

fn functionAddress(allocation: McfgAllocation, bus: u8, device: u8, function: u8) usize {
    const bus_offset = (@as(u64, bus) - allocation.start_bus) << 20;
    const device_offset = @as(u64, device) << 15;
    const function_offset = @as(u64, function) << 12;
    return @intCast(allocation.base_address + bus_offset + device_offset + function_offset);
}

fn read8(base: usize, offset: usize) u8 {
    const register: *volatile u8 = @ptrFromInt(base + offset);
    return register.*;
}

fn read16(base: usize, offset: usize) u16 {
    const low = @as(u16, read8(base, offset));
    const high = @as(u16, read8(base, offset + 1));
    return low | (high << 8);
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
    if (@sizeOf(McfgHeader) != 44) @compileError("ACPI MCFG header must be 44 bytes");
    if (@sizeOf(McfgAllocation) != 16) @compileError("ACPI MCFG allocation must be 16 bytes");
}

pub fn readConfiguration8(function: Function, offset: usize) u8 {
    return read8(function.configuration_address, offset);
}

pub fn readConfiguration16(function: Function, offset: usize) u16 {
    return read16(function.configuration_address, offset);
}

pub fn readConfiguration32(function: Function, offset: usize) u32 {
    const low = @as(u32, read16(function.configuration_address, offset));
    const high = @as(u32, read16(function.configuration_address, offset + 2));
    return low | (high << 16);
}

pub fn writeConfiguration16(function: Function, offset: usize, value: u16) void {
    const low: *volatile u8 = @ptrFromInt(function.configuration_address + offset);
    const high: *volatile u8 = @ptrFromInt(function.configuration_address + offset + 1);
    low.* = @truncate(value);
    high.* = @truncate(value >> 8);
}
