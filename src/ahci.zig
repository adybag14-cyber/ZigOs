const pci = @import("pci.zig");
const memory = @import("memory.zig");

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
