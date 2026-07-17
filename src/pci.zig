const std = @import("std");
const memory = @import("memory.zig");

const cc = std.os.uefi.cc;
const configuration_address_port: u16 = 0x0CF8;
const configuration_data_port: u16 = 0x0CFC;
const configuration_enable: u32 = 1 << 31;

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

pub const AccessMethod = enum {
    ecam,
    legacy_io,
};

pub const Function = struct {
    configuration_address: usize,
    access_method: AccessMethod,
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

pub const capability_msi: u8 = 0x05;
pub const capability_pcie: u8 = 0x10;
pub const capability_msix: u8 = 0x11;

pub const CapabilityList = struct {
    present: bool,
    count: u8,
    msi_offset: ?u8,
    msix_offset: ?u8,
    pcie_offset: ?u8,
};

pub const MsixCapability = struct {
    capability_offset: u8,
    control: u16,
    table_size: u16,
    table_bar_index: u3,
    table_offset: u32,
    pending_bar_index: u3,
    pending_offset: u32,
};

pub const Inventory = struct {
    access_method: AccessMethod,
    mcfg_address: ?usize,
    allocation_count: usize,
    scanned_bus_count: usize,
    function_count: usize,
    retained_count: usize,
    bridge_count: usize,
    functions: [maximum_retained_functions]Function,
};

extern fn zigos_out32(port: u16, value: u32) callconv(cc) void;
extern fn zigos_in32(port: u16) callconv(cc) u32;

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

    var inventory = emptyInventory(.ecam, mcfg_address, allocation_count);
    const allocations_address = mcfg_address + @sizeOf(McfgHeader);
    var allocation_index: usize = 0;
    while (allocation_index < allocation_count) : (allocation_index += 1) {
        const allocation_address = allocations_address + allocation_index * @sizeOf(McfgAllocation);
        const allocation: *const McfgAllocation = @ptrFromInt(allocation_address);
        if (!validateAllocation(allocation.*)) return null;

        var bus_value: u16 = allocation.start_bus;
        while (bus_value <= allocation.end_bus) : (bus_value += 1) {
            inventory.scanned_bus_count += 1;
            enumerateEcamBus(&inventory, allocation.*, @intCast(bus_value));
        }
    }
    return inventory;
}

pub fn enumerateLegacy() ?Inventory {
    if (!legacyMechanismAvailable()) return null;
    var inventory = emptyInventory(.legacy_io, null, 0);
    var bus_value: u16 = 0;
    while (bus_value <= std.math.maxInt(u8)) : (bus_value += 1) {
        inventory.scanned_bus_count += 1;
        enumerateLegacyBus(&inventory, @intCast(bus_value));
    }
    return inventory;
}

fn emptyInventory(method: AccessMethod, mcfg_address: ?usize, allocation_count: usize) Inventory {
    return .{
        .access_method = method,
        .mcfg_address = mcfg_address,
        .allocation_count = allocation_count,
        .scanned_bus_count = 0,
        .function_count = 0,
        .retained_count = 0,
        .bridge_count = 0,
        .functions = undefined,
    };
}

fn enumerateEcamBus(inventory: *Inventory, allocation: McfgAllocation, bus: u8) void {
    var device: u8 = 0;
    while (device < 32) : (device += 1) {
        const address = functionAddress(allocation, bus, device, 0);
        if (mmioRead16(address, 0x00) == 0xFFFF) continue;
        retainEcamFunction(inventory, allocation.segment_group, bus, device, 0, address);
        if ((mmioRead8(address, 0x0E) & 0x80) == 0) continue;

        var function: u8 = 1;
        while (function < 8) : (function += 1) {
            const function_address = functionAddress(allocation, bus, device, function);
            if (mmioRead16(function_address, 0x00) == 0xFFFF) continue;
            retainEcamFunction(
                inventory,
                allocation.segment_group,
                bus,
                device,
                function,
                function_address,
            );
        }
    }
}

fn enumerateLegacyBus(inventory: *Inventory, bus: u8) void {
    var device: u8 = 0;
    while (device < 32) : (device += 1) {
        if (legacyRead16(bus, device, 0, 0x00) == 0xFFFF) continue;
        retainLegacyFunction(inventory, bus, device, 0);
        if ((legacyRead8(bus, device, 0, 0x0E) & 0x80) == 0) continue;

        var function: u8 = 1;
        while (function < 8) : (function += 1) {
            if (legacyRead16(bus, device, function, 0x00) == 0xFFFF) continue;
            retainLegacyFunction(inventory, bus, device, function);
        }
    }
}

fn retainEcamFunction(
    inventory: *Inventory,
    segment: u16,
    bus: u8,
    device: u8,
    function: u8,
    address: usize,
) void {
    const retained = Function{
        .configuration_address = address,
        .access_method = .ecam,
        .segment = segment,
        .bus = bus,
        .device = device,
        .function = function,
        .vendor_id = mmioRead16(address, 0x00),
        .device_id = mmioRead16(address, 0x02),
        .class_code = mmioRead8(address, 0x0B),
        .subclass = mmioRead8(address, 0x0A),
        .programming_interface = mmioRead8(address, 0x09),
        .revision = mmioRead8(address, 0x08),
        .header_type = mmioRead8(address, 0x0E),
    };
    retainFunction(inventory, retained);
}

fn retainLegacyFunction(inventory: *Inventory, bus: u8, device: u8, function: u8) void {
    const retained = Function{
        .configuration_address = 0,
        .access_method = .legacy_io,
        .segment = 0,
        .bus = bus,
        .device = device,
        .function = function,
        .vendor_id = legacyRead16(bus, device, function, 0x00),
        .device_id = legacyRead16(bus, device, function, 0x02),
        .class_code = legacyRead8(bus, device, function, 0x0B),
        .subclass = legacyRead8(bus, device, function, 0x0A),
        .programming_interface = legacyRead8(bus, device, function, 0x09),
        .revision = legacyRead8(bus, device, function, 0x08),
        .header_type = legacyRead8(bus, device, function, 0x0E),
    };
    retainFunction(inventory, retained);
}

fn retainFunction(inventory: *Inventory, retained: Function) void {
    if (retained.class_code == 0x06 and retained.subclass == 0x04) inventory.bridge_count += 1;
    if (inventory.retained_count < inventory.functions.len) {
        inventory.functions[inventory.retained_count] = retained;
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

fn legacyMechanismAvailable() bool {
    const original = zigos_in32(configuration_address_port);
    zigos_out32(configuration_address_port, configuration_enable);
    const verified = zigos_in32(configuration_address_port);
    zigos_out32(configuration_address_port, original);
    return verified == configuration_enable;
}

fn legacyAddress(bus: u8, device: u8, function: u8, offset: usize) u32 {
    return configuration_enable |
        (@as(u32, bus) << 16) |
        (@as(u32, device) << 11) |
        (@as(u32, function) << 8) |
        @as(u32, @intCast(offset & 0xFC));
}

fn legacyRead32(bus: u8, device: u8, function: u8, offset: usize) u32 {
    zigos_out32(configuration_address_port, legacyAddress(bus, device, function, offset));
    return zigos_in32(configuration_data_port);
}

fn legacyRead16(bus: u8, device: u8, function: u8, offset: usize) u16 {
    const shift: u5 = @intCast((offset & 0x2) * 8);
    return @truncate(legacyRead32(bus, device, function, offset) >> shift);
}

fn legacyRead8(bus: u8, device: u8, function: u8, offset: usize) u8 {
    const shift: u5 = @intCast((offset & 0x3) * 8);
    return @truncate(legacyRead32(bus, device, function, offset) >> shift);
}

fn legacyWrite16(function: Function, offset: usize, value: u16) void {
    if ((offset & 0x3) == 0x3) return;
    const shift: u5 = @intCast((offset & 0x2) * 8);
    const mask = @as(u32, 0xFFFF) << shift;
    const current = legacyRead32(function.bus, function.device, function.function, offset);
    const updated = (current & ~mask) | (@as(u32, value) << shift);
    zigos_out32(
        configuration_address_port,
        legacyAddress(function.bus, function.device, function.function, offset),
    );
    zigos_out32(configuration_data_port, updated);
}

fn mmioRead8(base: usize, offset: usize) u8 {
    const register: *volatile u8 = @ptrFromInt(base + offset);
    return register.*;
}

fn mmioRead16(base: usize, offset: usize) u16 {
    const low = @as(u16, mmioRead8(base, offset));
    const high = @as(u16, mmioRead8(base, offset + 1));
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

pub fn readConfiguration8(function: Function, offset: usize) u8 {
    return switch (function.access_method) {
        .ecam => mmioRead8(function.configuration_address, offset),
        .legacy_io => legacyRead8(function.bus, function.device, function.function, offset),
    };
}

pub fn readConfiguration16(function: Function, offset: usize) u16 {
    return switch (function.access_method) {
        .ecam => mmioRead16(function.configuration_address, offset),
        .legacy_io => legacyRead16(function.bus, function.device, function.function, offset),
    };
}

pub fn readConfiguration32(function: Function, offset: usize) u32 {
    return switch (function.access_method) {
        .ecam => @as(u32, mmioRead16(function.configuration_address, offset)) |
            (@as(u32, mmioRead16(function.configuration_address, offset + 2)) << 16),
        .legacy_io => legacyRead32(function.bus, function.device, function.function, offset),
    };
}

pub fn writeConfiguration16(function: Function, offset: usize, value: u16) void {
    switch (function.access_method) {
        .ecam => {
            const low: *volatile u8 = @ptrFromInt(function.configuration_address + offset);
            const high: *volatile u8 = @ptrFromInt(function.configuration_address + offset + 1);
            low.* = @truncate(value);
            high.* = @truncate(value >> 8);
        },
        .legacy_io => legacyWrite16(function, offset, value),
    }
}


pub fn inspectCapabilities(function: Function) ?CapabilityList {
    const status = readConfiguration16(function, 0x06);
    if ((status & (1 << 4)) == 0) {
        return .{
            .present = false,
            .count = 0,
            .msi_offset = null,
            .msix_offset = null,
            .pcie_offset = null,
        };
    }

    const header_layout = function.header_type & 0x7F;
    if (header_layout != 0x00 and header_layout != 0x01) return null;
    var offset = readConfiguration8(function, 0x34);
    if (offset == 0) return null;

    var visited: u64 = 0;
    var result = CapabilityList{
        .present = true,
        .count = 0,
        .msi_offset = null,
        .msix_offset = null,
        .pcie_offset = null,
    };
    while (offset != 0) {
        if (offset < 0x40 or (offset & 0x03) != 0) return null;
        const slot: u6 = @intCast(offset >> 2);
        const bit = @as(u64, 1) << slot;
        if ((visited & bit) != 0) return null;
        visited |= bit;
        if (result.count == std.math.maxInt(u8)) return null;
        result.count += 1;

        const capability_id = readConfiguration8(function, offset);
        switch (capability_id) {
            capability_msi => {
                if (result.msi_offset == null) result.msi_offset = offset;
            },
            capability_msix => {
                if (result.msix_offset == null) result.msix_offset = offset;
            },
            capability_pcie => {
                if (result.pcie_offset == null) result.pcie_offset = offset;
            },
            else => {},
        }

        const next = readConfiguration8(function, @as(usize, offset) + 1);
        if (next != 0 and (next < 0x40 or (next & 0x03) != 0)) return null;
        offset = next;
    }
    return result;
}

pub fn findCapability(function: Function, capability_id: u8) ?u8 {
    const capabilities = inspectCapabilities(function) orelse return null;
    return switch (capability_id) {
        capability_msi => capabilities.msi_offset,
        capability_msix => capabilities.msix_offset,
        capability_pcie => capabilities.pcie_offset,
        else => null,
    };
}

pub fn inspectMsix(function: Function) ?MsixCapability {
    const capability_offset = findCapability(function, capability_msix) orelse return null;
    const control = readConfiguration16(function, @as(usize, capability_offset) + 2);
    const table_descriptor = readConfiguration32(function, @as(usize, capability_offset) + 4);
    const pending_descriptor = readConfiguration32(function, @as(usize, capability_offset) + 8);
    const table_bar_index: u3 = @intCast(table_descriptor & 0x7);
    const pending_bar_index: u3 = @intCast(pending_descriptor & 0x7);
    if (table_bar_index >= 6 or pending_bar_index >= 6) return null;
    return .{
        .capability_offset = capability_offset,
        .control = control,
        .table_size = @intCast((control & 0x07FF) + 1),
        .table_bar_index = table_bar_index,
        .table_offset = table_descriptor & 0xFFFF_FFF8,
        .pending_bar_index = pending_bar_index,
        .pending_offset = pending_descriptor & 0xFFFF_FFF8,
    };
}

pub fn decodeMemoryBar(function: Function, bar_index: u3) ?u64 {
    if (bar_index >= 6) return null;
    const offset = 0x10 + @as(usize, bar_index) * 4;
    const low = readConfiguration32(function, offset);
    if ((low & 1) != 0) return null;
    const memory_type = (low >> 1) & 0x3;
    const low_base = @as(u64, low & 0xFFFF_FFF0);
    const base = switch (memory_type) {
        0, 1 => low_base,
        2 => blk: {
            if (bar_index >= 5) return null;
            const high = readConfiguration32(function, offset + 4);
            break :blk low_base | (@as(u64, high) << 32);
        },
        else => return null,
    };
    if (base == 0) return null;
    return base;
}

pub fn writeConfiguration32(function: Function, offset: usize, value: u32) void {
    switch (function.access_method) {
        .ecam => {
            const register: *volatile u32 = @ptrFromInt(function.configuration_address + offset);
            register.* = value;
            _ = register.*;
        },
        .legacy_io => {
            zigos_out32(
                configuration_address_port,
                legacyAddress(function.bus, function.device, function.function, offset),
            );
            zigos_out32(configuration_data_port, value);
        },
    }
}

comptime {
    if (@sizeOf(McfgHeader) != 44) @compileError("ACPI MCFG header must be 44 bytes");
    if (@sizeOf(McfgAllocation) != 16) @compileError("ACPI MCFG allocation must be 16 bytes");
}
