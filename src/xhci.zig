const std = @import("std");
const pci = @import("pci.zig");
const memory = @import("memory.zig");
const paging = @import("paging.zig");

const pci_command_memory_space: u16 = 1 << 1;
const bar_io_space: u32 = 1;
const bar_type_mask: u32 = 0x6;
const bar_type_32_bit: u32 = 0x0;
const bar_type_64_bit: u32 = 0x4;
const bar_address_mask: u32 = 0xFFFF_FFF0;
const maximum_ports: usize = 32;

pub const Port = struct {
    number: u8,
    port_status_control: u32,
    connected: bool,
    enabled: bool,
    powered: bool,
    speed_id: u4,
};

pub const Controller = struct {
    pci_function: pci.Function,
    base_address: usize,
    mapping_base: u64,
    mapping_bytes: u64,
    mapping_table_pages: u64,
    pci_command: u16,
    capability_length: u8,
    hci_version: u16,
    structural_parameters1: u32,
    structural_parameters2: u32,
    structural_parameters3: u32,
    capability_parameters1: u32,
    capability_parameters2: u32,
    doorbell_offset: u32,
    runtime_offset: u32,
    extended_capability_offset: u32,
    maximum_slots: u8,
    maximum_interrupters: u16,
    maximum_ports: u8,
    supports_64_bit_addressing: bool,
    context_size_64_bytes: bool,
    connected_port_count: u8,
    retained_port_count: u8,
    ports: [maximum_ports]Port,
};

pub fn inspect(function: pci.Function, allocator: *memory.FrameAllocator) ?Controller {
    if (function.class_code != 0x0C or
        function.subclass != 0x03 or
        function.programming_interface != 0x30)
    {
        return null;
    }

    const command = pci.readConfiguration16(function, 0x04);
    if ((command & pci_command_memory_space) == 0) return null;
    const bar0 = pci.readConfiguration32(function, 0x10);
    if ((bar0 & bar_io_space) != 0) return null;
    const bar_type = bar0 & bar_type_mask;
    if (bar_type != bar_type_32_bit and bar_type != bar_type_64_bit) return null;

    var base: u64 = bar0 & bar_address_mask;
    if (bar_type == bar_type_64_bit) {
        base |= @as(u64, pci.readConfiguration32(function, 0x14)) << 32;
    }
    if (base == 0 or base > std.math.maxInt(usize)) return null;
    const base_address: usize = @intCast(base);
    const mapping = paging.mapIdentityMmio(allocator, base, 0x10_000) orelse return null;

    const capability_length = read8(base_address, 0x00);
    if (capability_length < 0x20 or capability_length > 0x80) return null;
    const hci_version = read16(base_address, 0x02);
    const structural_parameters1 = read32(base_address, 0x04);
    const structural_parameters2 = read32(base_address, 0x08);
    const structural_parameters3 = read32(base_address, 0x0C);
    const capability_parameters1 = read32(base_address, 0x10);
    const doorbell_offset = read32(base_address, 0x14) & 0xFFFF_FFFC;
    const runtime_offset = read32(base_address, 0x18) & 0xFFFF_FFE0;
    const capability_parameters2 = read32(base_address, 0x1C);
    const extended_capability_offset = ((capability_parameters1 >> 16) & 0xFFFF) * 4;
    const maximum_slots: u8 = @truncate(structural_parameters1);
    const maximum_interrupters: u16 = @truncate(structural_parameters1 >> 8);
    const maximum_port_count: u8 = @truncate(structural_parameters1 >> 24);
    if (maximum_slots == 0 or maximum_port_count == 0 or maximum_port_count > maximum_ports) return null;
    if (doorbell_offset < capability_length or runtime_offset < capability_length) return null;
    const required_end = @max(
        @as(u64, capability_length) + 0x400 + @as(u64, maximum_port_count) * 0x10,
        @max(@as(u64, doorbell_offset) + 4, @as(u64, runtime_offset) + 0x20),
    );
    if (required_end > mapping.requested_size) return null;

    var controller = Controller{
        .pci_function = function,
        .base_address = base_address,
        .mapping_base = mapping.mapped_base,
        .mapping_bytes = mapping.mapped_bytes,
        .mapping_table_pages = mapping.table_pages,
        .pci_command = command,
        .capability_length = capability_length,
        .hci_version = hci_version,
        .structural_parameters1 = structural_parameters1,
        .structural_parameters2 = structural_parameters2,
        .structural_parameters3 = structural_parameters3,
        .capability_parameters1 = capability_parameters1,
        .capability_parameters2 = capability_parameters2,
        .doorbell_offset = doorbell_offset,
        .runtime_offset = runtime_offset,
        .extended_capability_offset = extended_capability_offset,
        .maximum_slots = maximum_slots,
        .maximum_interrupters = maximum_interrupters,
        .maximum_ports = maximum_port_count,
        .supports_64_bit_addressing = (capability_parameters1 & 1) != 0,
        .context_size_64_bytes = (capability_parameters1 & (@as(u32, 1) << 2)) != 0,
        .connected_port_count = 0,
        .retained_port_count = 0,
        .ports = undefined,
    };

    const operational_base = base_address + capability_length;
    var port_number: u8 = 1;
    while (port_number <= maximum_port_count) : (port_number += 1) {
        const port_offset = 0x400 + (@as(usize, port_number) - 1) * 0x10;
        if (@as(u64, capability_length) + port_offset + 4 > mapping.requested_size) return null;
        const port_status_control = read32(operational_base, port_offset);
        const connected = (port_status_control & 1) != 0;
        if (connected) controller.connected_port_count += 1;
        controller.ports[controller.retained_port_count] = .{
            .number = port_number,
            .port_status_control = port_status_control,
            .connected = connected,
            .enabled = (port_status_control & (@as(u32, 1) << 1)) != 0,
            .powered = (port_status_control & (@as(u32, 1) << 9)) != 0,
            .speed_id = @truncate(port_status_control >> 10),
        };
        controller.retained_port_count += 1;
    }
    if (controller.connected_port_count == 0) return null;
    return controller;
}

fn read8(base: usize, offset: usize) u8 {
    const register: *const volatile u8 = @ptrFromInt(base + offset);
    return register.*;
}

fn read16(base: usize, offset: usize) u16 {
    return @as(u16, read8(base, offset)) |
        (@as(u16, read8(base, offset + 1)) << 8);
}

fn read32(base: usize, offset: usize) u32 {
    const register: *const volatile u32 = @ptrFromInt(base + offset);
    return register.*;
}
