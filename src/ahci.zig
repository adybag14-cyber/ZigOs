const std = @import("std");
const pci = @import("pci.zig");
const memory = @import("memory.zig");

const cc = std.os.uefi.cc;

const pci_command_memory_space: u16 = 1 << 1;
const bar_memory_space: u32 = 1;
const bar_type_mask: u32 = 0x6;
const bar_type_32_bit: u32 = 0x0;
const abar_mask: u32 = 0xFFFF_FFF0;

const cap_offset: usize = 0x00;
const ghc_offset: usize = 0x04;
const interrupt_status_offset: usize = 0x08;
const ports_implemented_offset: usize = 0x0C;
const version_offset: usize = 0x10;
const cap2_offset: usize = 0x24;
const bios_handoff_offset: usize = 0x28;
const port_base_offset: usize = 0x100;
const port_stride: usize = 0x80;

pub const DeviceType = enum {
    none,
    sata,
    satapi,
    enclosure_management,
    port_multiplier,
    unknown,
};

pub const Port = struct {
    index: u8,
    sata_status: u32,
    signature: u32,
    task_file_data: u32,
    command: u32,
    sata_error: u32,
    command_issue: u32,
    active: bool,
    device_type: DeviceType,
};

pub const maximum_ports: usize = 32;

pub const Controller = struct {
    pci_function: pci.Function,
    abar: usize,
    pci_command: u16,
    capabilities: u32,
    global_host_control: u32,
    interrupt_status: u32,
    ports_implemented: u32,
    version: u32,
    capabilities2: u32,
    bios_handoff: u32,
    declared_port_count: u8,
    command_slot_count: u8,
    implemented_port_count: u8,
    active_device_count: u8,
    supports_64_bit_dma: bool,
    supports_ncq: bool,
    interface_speed_support: u4,
    retained_port_count: u8,
    ports: [maximum_ports]Port,
};

pub fn inspect(function: pci.Function) ?Controller {
    if (function.class_code != 0x01 or function.subclass != 0x06 or function.programming_interface != 0x01) {
        return null;
    }

    const command = pci.readConfiguration16(function, 0x04);
    if ((command & pci_command_memory_space) == 0) return null;

    const bar5 = pci.readConfiguration32(function, 0x24);
    if ((bar5 & bar_memory_space) != 0) return null;
    if ((bar5 & bar_type_mask) != bar_type_32_bit) return null;
    const abar_u32 = bar5 & abar_mask;
    if (abar_u32 == 0) return null;
    const abar: usize = abar_u32;
    if (!rangeMapped(abar, port_base_offset + maximum_ports * port_stride)) return null;

    const capabilities = read32(abar, cap_offset);
    const ports_implemented = read32(abar, ports_implemented_offset);
    const declared_port_count: u8 = @intCast((capabilities & 0x1F) + 1);
    const command_slot_count: u8 = @intCast(((capabilities >> 8) & 0x1F) + 1);

    var controller = Controller{
        .pci_function = function,
        .abar = abar,
        .pci_command = command,
        .capabilities = capabilities,
        .global_host_control = read32(abar, ghc_offset),
        .interrupt_status = read32(abar, interrupt_status_offset),
        .ports_implemented = ports_implemented,
        .version = read32(abar, version_offset),
        .capabilities2 = read32(abar, cap2_offset),
        .bios_handoff = read32(abar, bios_handoff_offset),
        .declared_port_count = declared_port_count,
        .command_slot_count = command_slot_count,
        .implemented_port_count = 0,
        .active_device_count = 0,
        .supports_64_bit_dma = (capabilities & (@as(u32, 1) << 31)) != 0,
        .supports_ncq = (capabilities & (@as(u32, 1) << 30)) != 0,
        .interface_speed_support = @truncate(capabilities >> 20),
        .retained_port_count = 0,
        .ports = undefined,
    };

    var port_index: u8 = 0;
    while (port_index < maximum_ports) : (port_index += 1) {
        if ((ports_implemented & (@as(u32, 1) << @intCast(port_index))) == 0) continue;
        controller.implemented_port_count += 1;

        const port_base = abar + port_base_offset + @as(usize, port_index) * port_stride;
        const sata_status = read32(port_base, 0x28);
        const signature = read32(port_base, 0x24);
        const detection = sata_status & 0xF;
        const power_management = (sata_status >> 8) & 0xF;
        const active = detection == 3 and power_management == 1;
        if (active) controller.active_device_count += 1;

        if (controller.retained_port_count < controller.ports.len) {
            const retained_index: usize = controller.retained_port_count;
            controller.ports[retained_index] = .{
                .index = port_index,
                .sata_status = sata_status,
                .signature = signature,
                .task_file_data = read32(port_base, 0x20),
                .command = read32(port_base, 0x18),
                .sata_error = read32(port_base, 0x30),
                .command_issue = read32(port_base, 0x38),
                .active = active,
                .device_type = classifySignature(signature, active),
            };
            controller.retained_port_count += 1;
        }
    }

    if (controller.implemented_port_count == 0) return null;
    return controller;
}

fn classifySignature(signature: u32, active: bool) DeviceType {
    if (!active) return .none;
    return switch (signature) {
        0x0000_0101 => .sata,
        0xEB14_0101 => .satapi,
        0xC33C_0101 => .enclosure_management,
        0x9669_0101 => .port_multiplier,
        else => .unknown,
    };
}

fn read32(base: usize, offset: usize) u32 {
    const register: *volatile u32 = @ptrFromInt(base + offset);
    return register.*;
}

fn rangeMapped(address: usize, length: usize) bool {
    const limit: usize = @intCast(memory.four_gib);
    return address < limit and length <= limit - address;
}

const command_list_base_offset: usize = 0x00;
const command_list_base_upper_offset: usize = 0x04;
const fis_base_offset: usize = 0x08;
const fis_base_upper_offset: usize = 0x0C;
const port_interrupt_status_offset: usize = 0x10;
const port_interrupt_enable_offset: usize = 0x14;
const port_command_offset: usize = 0x18;
const port_task_file_data_offset: usize = 0x20;
const port_sata_error_offset: usize = 0x30;
const port_sata_active_offset: usize = 0x34;
const port_command_issue_offset: usize = 0x38;

const command_start: u32 = 1 << 0;
const fis_receive_enable: u32 = 1 << 4;
const fis_receive_running: u32 = 1 << 14;
const command_list_running: u32 = 1 << 15;
const task_file_busy: u32 = 1 << 7;
const task_file_data_request: u32 = 1 << 3;
const task_file_error_status: u32 = 1 << 30;
const global_host_ahci_enable: u32 = 1 << 31;
const identify_device_command: u8 = 0xEC;
const register_host_to_device_fis: u8 = 0x27;
const command_fis_length_dwords: u16 = 5;
const maximum_poll_iterations: usize = 50_000_000;

const CommandHeader = extern struct {
    flags: u16,
    prdt_length: u16,
    prd_byte_count: u32,
    command_table_base: u32,
    command_table_base_upper: u32,
    reserved: [4]u32,
};

const PhysicalRegionDescriptor = extern struct {
    data_base: u32,
    data_base_upper: u32,
    reserved: u32,
    byte_count_and_interrupt: u32,
};

pub const IdentifyResult = struct {
    port_index: u8,
    model: [41]u8,
    serial_number: [21]u8,
    firmware_revision: [9]u8,
    sector_count: u64,
    logical_sector_size: u32,
    capacity_bytes: u64,
    lba48_supported: bool,
    ncq_supported: bool,
    queue_depth: u8,
    command_list_address: usize,
    received_fis_address: usize,
    command_table_address: usize,
    identify_buffer_address: usize,
    transferred_bytes: u32,
};

extern fn zigos_memory_fence() callconv(cc) void;

pub fn identifyFirstSata(controller: Controller, allocator: *memory.FrameAllocator) ?IdentifyResult {
    var target_port: ?u8 = null;
    for (controller.ports[0..controller.retained_port_count]) |port| {
        if (port.active and port.device_type == .sata) {
            target_port = port.index;
            break;
        }
    }
    const port_index = target_port orelse return null;
    const port_base = controller.abar + port_base_offset + @as(usize, port_index) * port_stride;

    var global_control = read32(controller.abar, ghc_offset);
    if ((global_control & global_host_ahci_enable) == 0) {
        global_control |= global_host_ahci_enable;
        write32(controller.abar, ghc_offset, global_control);
        if ((read32(controller.abar, ghc_offset) & global_host_ahci_enable) == 0) return null;
    }

    if (!stopCommandEngine(port_base)) return null;
    if (read32(port_base, port_command_issue_offset) != 0) return null;
    if (read32(port_base, port_sata_active_offset) != 0) return null;

    const command_list_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    const received_fis_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    const command_table_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    const identify_buffer_address = allocator.allocateBelow(memory.four_gib) orelse return null;

    zeroPage(command_list_address);
    zeroPage(received_fis_address);
    zeroPage(command_table_address);
    zeroPage(identify_buffer_address);

    write32(port_base, command_list_base_offset, @truncate(command_list_address));
    write32(port_base, command_list_base_upper_offset, @truncate(command_list_address >> 32));
    write32(port_base, fis_base_offset, @truncate(received_fis_address));
    write32(port_base, fis_base_upper_offset, @truncate(received_fis_address >> 32));
    write32(port_base, port_interrupt_enable_offset, 0);
    write32(port_base, port_interrupt_status_offset, 0xFFFF_FFFF);
    write32(port_base, port_sata_error_offset, 0xFFFF_FFFF);

    const header: *volatile CommandHeader = @ptrFromInt(command_list_address);
    header.* = .{
        .flags = command_fis_length_dwords,
        .prdt_length = 1,
        .prd_byte_count = 0,
        .command_table_base = @truncate(command_table_address),
        .command_table_base_upper = @truncate(command_table_address >> 32),
        .reserved = .{ 0, 0, 0, 0 },
    };

    const command_table = @as([*]volatile u8, @ptrFromInt(command_table_address));
    command_table[0] = register_host_to_device_fis;
    command_table[1] = 1 << 7;
    command_table[2] = identify_device_command;
    command_table[7] = 0;

    const prdt: *volatile PhysicalRegionDescriptor = @ptrFromInt(command_table_address + 0x80);
    prdt.* = .{
        .data_base = @truncate(identify_buffer_address),
        .data_base_upper = @truncate(identify_buffer_address >> 32),
        .reserved = 0,
        .byte_count_and_interrupt = 511 | (@as(u32, 1) << 31),
    };

    zigos_memory_fence();
    if (!startCommandEngine(port_base)) return null;
    if (!waitForTaskFileReady(port_base)) return null;

    write32(port_base, port_interrupt_status_offset, 0xFFFF_FFFF);
    zigos_memory_fence();
    write32(port_base, port_command_issue_offset, 1);

    var completed = false;
    var iteration: usize = 0;
    while (iteration < maximum_poll_iterations) : (iteration += 1) {
        const interrupt_status = read32(port_base, port_interrupt_status_offset);
        if ((interrupt_status & task_file_error_status) != 0) return null;
        if ((read32(port_base, port_command_issue_offset) & 1) == 0) {
            completed = true;
            break;
        }
    }
    if (!completed) return null;
    zigos_memory_fence();

    const transferred_bytes = header.prd_byte_count;
    if (transferred_bytes < 512) return null;
    const words: [*]volatile u16 = @ptrFromInt(identify_buffer_address);
    if (words[0] == 0 or words[0] == 0xFFFF) return null;

    const lba48_supported = (words[83] & (@as(u16, 1) << 10)) != 0;
    const sector_count = if (lba48_supported)
        @as(u64, words[100]) |
            (@as(u64, words[101]) << 16) |
            (@as(u64, words[102]) << 32) |
            (@as(u64, words[103]) << 48)
    else
        @as(u64, words[60]) | (@as(u64, words[61]) << 16);
    if (sector_count == 0) return null;

    const logical_sector_size = decodeLogicalSectorSize(words);
    const capacity_bytes = sector_count *| @as(u64, logical_sector_size);
    var result = IdentifyResult{
        .port_index = port_index,
        .model = undefined,
        .serial_number = undefined,
        .firmware_revision = undefined,
        .sector_count = sector_count,
        .logical_sector_size = logical_sector_size,
        .capacity_bytes = capacity_bytes,
        .lba48_supported = lba48_supported,
        .ncq_supported = (words[76] & (@as(u16, 1) << 8)) != 0,
        .queue_depth = @intCast((words[75] & 0x1F) + 1),
        .command_list_address = command_list_address,
        .received_fis_address = received_fis_address,
        .command_table_address = command_table_address,
        .identify_buffer_address = identify_buffer_address,
        .transferred_bytes = transferred_bytes,
    };
    decodeAtaString(words, 27, 20, &result.model);
    decodeAtaString(words, 10, 10, &result.serial_number);
    decodeAtaString(words, 23, 4, &result.firmware_revision);
    return result;
}

pub fn terminatedSlice(buffer: []const u8) []const u8 {
    var length = buffer.len;
    for (buffer, 0..) |character, index| {
        if (character == 0) {
            length = index;
            break;
        }
    }
    return buffer[0..length];
}

fn stopCommandEngine(port_base: usize) bool {
    var command = read32(port_base, port_command_offset);
    command &= ~command_start;
    write32(port_base, port_command_offset, command);
    if (!waitForPortCommandBitsClear(port_base, command_list_running)) return false;

    command = read32(port_base, port_command_offset);
    command &= ~fis_receive_enable;
    write32(port_base, port_command_offset, command);
    return waitForPortCommandBitsClear(port_base, fis_receive_running);
}

fn startCommandEngine(port_base: usize) bool {
    var command = read32(port_base, port_command_offset);
    command |= fis_receive_enable;
    write32(port_base, port_command_offset, command);
    command |= command_start;
    write32(port_base, port_command_offset, command);

    var iteration: usize = 0;
    while (iteration < maximum_poll_iterations) : (iteration += 1) {
        const current = read32(port_base, port_command_offset);
        if ((current & command_start) != 0 and (current & fis_receive_enable) != 0) return true;
    }
    return false;
}

fn waitForPortCommandBitsClear(port_base: usize, mask: u32) bool {
    var iteration: usize = 0;
    while (iteration < maximum_poll_iterations) : (iteration += 1) {
        if ((read32(port_base, port_command_offset) & mask) == 0) return true;
    }
    return false;
}

fn waitForTaskFileReady(port_base: usize) bool {
    var iteration: usize = 0;
    while (iteration < maximum_poll_iterations) : (iteration += 1) {
        const task_file = read32(port_base, port_task_file_data_offset);
        if ((task_file & (task_file_busy | task_file_data_request)) == 0) return true;
    }
    return false;
}

fn decodeLogicalSectorSize(words: [*]volatile u16) u32 {
    const descriptor = words[106];
    const descriptor_valid = (descriptor & (@as(u16, 1) << 14)) != 0 and
        (descriptor & (@as(u16, 1) << 15)) == 0;
    if (!descriptor_valid or (descriptor & (@as(u16, 1) << 12)) == 0) return 512;

    const words_per_sector = @as(u32, words[117]) | (@as(u32, words[118]) << 16);
    if (words_per_sector < 256) return 512;
    return words_per_sector *| 2;
}

fn decodeAtaString(
    words: [*]volatile u16,
    first_word: usize,
    word_count: usize,
    output: []u8,
) void {
    @memset(output, 0);
    const maximum_characters = @min(word_count * 2, output.len - 1);
    var output_index: usize = 0;
    var word_index: usize = 0;
    while (word_index < word_count and output_index < maximum_characters) : (word_index += 1) {
        const word = words[first_word + word_index];
        output[output_index] = @truncate(word >> 8);
        output_index += 1;
        if (output_index < maximum_characters) {
            output[output_index] = @truncate(word);
            output_index += 1;
        }
    }

    while (output_index > 0 and (output[output_index - 1] == ' ' or output[output_index - 1] == 0)) {
        output_index -= 1;
    }
    output[output_index] = 0;
}

fn zeroPage(address: usize) void {
    const page = @as([*]u8, @ptrFromInt(address))[0..@as(usize, @intCast(memory.page_size))];
    @memset(page, 0);
}

fn write32(base: usize, offset: usize, value: u32) void {
    const register: *volatile u32 = @ptrFromInt(base + offset);
    register.* = value;
    _ = register.*;
}

comptime {
    if (@sizeOf(CommandHeader) != 32) @compileError("AHCI command header must be 32 bytes");
    if (@sizeOf(PhysicalRegionDescriptor) != 16) @compileError("AHCI PRDT entry must be 16 bytes");
}
