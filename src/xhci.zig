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
const page_bytes: usize = 4096;
const trbs_per_page: usize = page_bytes / @sizeOf(Trb);
const maximum_poll_count: usize = 20_000_000;
const usbcmd_run_stop: u32 = 1 << 0;
const usbcmd_host_controller_reset: u32 = 1 << 1;
const usbsts_halted: u32 = 1 << 0;
const usbsts_controller_not_ready: u32 = 1 << 11;
const command_ring_cycle_state: u64 = 1;
const trb_cycle: u32 = 1 << 0;
const trb_toggle_cycle: u32 = 1 << 1;
const trb_type_shift: u5 = 10;
const trb_type_link: u32 = 6;
const trb_type_enable_slot: u32 = 9;
const trb_type_command_completion: u32 = 33;
const completion_success: u8 = 1;
const event_handler_busy: u64 = 1 << 3;
const legacy_capability_id: u8 = 1;
const legacy_bios_owned: u32 = 1 << 16;
const legacy_os_owned: u32 = 1 << 24;
const operational_usbcmd: usize = 0x00;
const operational_usbsts: usize = 0x04;
const operational_pagesize: usize = 0x08;
const operational_crcr: usize = 0x18;
const operational_dcbaap: usize = 0x30;
const operational_config: usize = 0x38;
const interrupter0_offset: usize = 0x20;
const interrupter_iman: usize = 0x00;
const interrupter_imod: usize = 0x04;
const interrupter_erstsz: usize = 0x08;
const interrupter_erstba: usize = 0x10;
const interrupter_erdp: usize = 0x18;

const cc = std.os.uefi.cc;
extern fn zigos_memory_fence() callconv(cc) void;
extern fn zigos_cpu_relax() callconv(cc) void;

const Trb = extern struct {
    parameter: u64,
    status: u32,
    control: u32,
};

const EventRingSegmentTableEntry = extern struct {
    ring_segment_base: u64,
    ring_segment_size: u32,
    reserved: u32,
};

pub const Ownership = struct {
    dcbaa_address: usize,
    command_ring_address: usize,
    event_ring_address: usize,
    erst_address: usize,
    page_size: u32,
    scratchpad_count: u16,
    enabled_slots: u8,
    completion_code: u8,
    slot_id: u8,
    command_pointer: u64,
    event_cycle: u1,
    controller_running: bool,
    legacy_handoff_performed: bool,
};

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

pub fn takeOwnership(
    controller: Controller,
    allocator: *memory.FrameAllocator,
) ?Ownership {
    const operational_base = controller.base_address + controller.capability_length;
    const runtime_base = controller.base_address + controller.runtime_offset;
    const doorbell_base = controller.base_address + controller.doorbell_offset;
    const interrupter_base = runtime_base + interrupter0_offset;

    const legacy_handoff_performed = claimLegacyOwnership(controller) orelse return null;
    if (!stopController(operational_base)) return null;
    if (!resetController(operational_base)) return null;

    const supported_page_sizes = read32(operational_base, operational_pagesize);
    if ((supported_page_sizes & 1) == 0) return null;
    const scratchpad_count = scratchpadCount(controller.structural_parameters2);
    if (scratchpad_count != 0) return null;

    const dcbaa_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    const command_ring_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    const event_ring_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    const erst_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    clearPage(dcbaa_address);
    clearPage(command_ring_address);
    clearPage(event_ring_address);
    clearPage(erst_address);

    const command_ring = trbPage(command_ring_address);
    const link = &command_ring[trbs_per_page - 1];
    link.parameter = command_ring_address;
    link.status = 0;
    link.control = (trb_type_link << trb_type_shift) | trb_toggle_cycle | trb_cycle;

    const erst: *volatile EventRingSegmentTableEntry = @ptrFromInt(erst_address);
    erst.ring_segment_base = event_ring_address;
    erst.ring_segment_size = trbs_per_page;
    erst.reserved = 0;

    write64(operational_base, operational_dcbaap, dcbaa_address);
    write64(
        operational_base,
        operational_crcr,
        @as(u64, @intCast(command_ring_address)) | command_ring_cycle_state,
    );
    write32(interrupter_base, interrupter_erstsz, 1);
    write64(interrupter_base, interrupter_erstba, erst_address);
    write64(interrupter_base, interrupter_erdp, event_ring_address);
    write32(interrupter_base, interrupter_imod, 0);
    write32(interrupter_base, interrupter_iman, 1);
    write32(operational_base, operational_config, controller.maximum_slots);
    zigos_memory_fence();

    var command = read32(operational_base, operational_usbcmd);
    command |= usbcmd_run_stop;
    write32(operational_base, operational_usbcmd, command);
    if (!waitRegisterBits(
        operational_base,
        operational_usbsts,
        usbsts_halted,
        false,
    )) return null;

    const enable_slot = &command_ring[0];
    enable_slot.parameter = 0;
    enable_slot.status = 0;
    enable_slot.control = (trb_type_enable_slot << trb_type_shift) | trb_cycle;
    zigos_memory_fence();
    write32(doorbell_base, 0, 0);

    const event = waitForEvent(event_ring_address, 1) orelse return null;
    const event_type = (event.control >> trb_type_shift) & 0x3F;
    const completion_code: u8 = @truncate(event.status >> 24);
    const slot_id: u8 = @truncate(event.control >> 24);
    const command_pointer = event.parameter & ~@as(u64, 0xF);
    if (event_type != trb_type_command_completion or
        completion_code != completion_success or
        slot_id == 0 or
        slot_id > controller.maximum_slots or
        command_pointer != command_ring_address)
    {
        return null;
    }

    write64(
        interrupter_base,
        interrupter_erdp,
        @as(u64, @intCast(event_ring_address + @sizeOf(Trb))) | event_handler_busy,
    );
    zigos_memory_fence();
    const running = (read32(operational_base, operational_usbsts) & usbsts_halted) == 0;
    if (!running) return null;

    return .{
        .dcbaa_address = dcbaa_address,
        .command_ring_address = command_ring_address,
        .event_ring_address = event_ring_address,
        .erst_address = erst_address,
        .page_size = page_bytes,
        .scratchpad_count = scratchpad_count,
        .enabled_slots = controller.maximum_slots,
        .completion_code = completion_code,
        .slot_id = slot_id,
        .command_pointer = command_pointer,
        .event_cycle = @truncate(event.control),
        .controller_running = running,
        .legacy_handoff_performed = legacy_handoff_performed,
    };
}

fn claimLegacyOwnership(controller: Controller) ?bool {
    if (controller.extended_capability_offset == 0) return false;
    var offset: usize = controller.extended_capability_offset;
    var visited: usize = 0;
    while (offset != 0 and offset + 4 <= 0x10_000 and visited < 64) : (visited += 1) {
        const header = read32(controller.base_address, offset);
        const capability_id: u8 = @truncate(header);
        const next: u8 = @truncate(header >> 8);
        if (capability_id == legacy_capability_id) {
            write32(controller.base_address, offset, header | legacy_os_owned);
            var polls: usize = 0;
            while (polls < maximum_poll_count) : (polls += 1) {
                const value = read32(controller.base_address, offset);
                if ((value & legacy_os_owned) != 0 and (value & legacy_bios_owned) == 0) return true;
                zigos_cpu_relax();
            }
            return null;
        }
        if (next == 0) break;
        offset += @as(usize, next) * 4;
    }
    return false;
}

fn stopController(operational_base: usize) bool {
    var command = read32(operational_base, operational_usbcmd);
    command &= ~usbcmd_run_stop;
    write32(operational_base, operational_usbcmd, command);
    return waitRegisterBits(
        operational_base,
        operational_usbsts,
        usbsts_halted,
        true,
    );
}

fn resetController(operational_base: usize) bool {
    var command = read32(operational_base, operational_usbcmd);
    command |= usbcmd_host_controller_reset;
    write32(operational_base, operational_usbcmd, command);
    if (!waitRegisterBits(
        operational_base,
        operational_usbcmd,
        usbcmd_host_controller_reset,
        false,
    )) return false;
    return waitRegisterBits(
        operational_base,
        operational_usbsts,
        usbsts_controller_not_ready,
        false,
    );
}

fn waitForEvent(event_ring_address: usize, expected_cycle: u1) ?Trb {
    const event: *const volatile Trb = @ptrFromInt(event_ring_address);
    var polls: usize = 0;
    while (polls < maximum_poll_count) : (polls += 1) {
        zigos_memory_fence();
        const control = event.control;
        if ((control & trb_cycle) == expected_cycle) {
            return .{
                .parameter = event.parameter,
                .status = event.status,
                .control = control,
            };
        }
        zigos_cpu_relax();
    }
    return null;
}

fn waitRegisterBits(base: usize, offset: usize, mask: u32, set: bool) bool {
    var polls: usize = 0;
    while (polls < maximum_poll_count) : (polls += 1) {
        const value = read32(base, offset);
        if (((value & mask) != 0) == set) return true;
        zigos_cpu_relax();
    }
    return false;
}

fn scratchpadCount(structural_parameters2: u32) u16 {
    const high = (structural_parameters2 >> 27) & 0x1F;
    const low = (structural_parameters2 >> 21) & 0x1F;
    return @intCast((high << 5) | low);
}

fn clearPage(address: usize) void {
    const bytes = @as([*]u8, @ptrFromInt(address))[0..page_bytes];
    @memset(bytes, 0);
}

fn trbPage(address: usize) [*]volatile Trb {
    return @ptrFromInt(address);
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

fn write32(base: usize, offset: usize, value: u32) void {
    const register: *volatile u32 = @ptrFromInt(base + offset);
    register.* = value;
}

fn write64(base: usize, offset: usize, value: u64) void {
    write32(base, offset, @truncate(value));
    write32(base, offset + 4, @truncate(value >> 32));
}

comptime {
    if (@sizeOf(Trb) != 16) @compileError("xHCI TRB must be 16 bytes");
    if (@sizeOf(EventRingSegmentTableEntry) != 16) {
        @compileError("xHCI ERST entry must be 16 bytes");
    }
}
