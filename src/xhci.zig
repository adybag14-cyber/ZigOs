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
const trb_type_setup_stage: u32 = 2;
const trb_type_data_stage: u32 = 3;
const trb_type_status_stage: u32 = 4;
const trb_type_address_device: u32 = 11;
const trb_type_transfer_event: u32 = 32;
const trb_type_command_completion: u32 = 33;
const trb_type_port_status_change: u32 = 34;
const completion_success: u8 = 1;
const event_handler_busy: u64 = 1 << 3;
const trb_interrupt_on_short_packet: u32 = 1 << 2;
const trb_interrupt_on_completion: u32 = 1 << 5;
const trb_immediate_data: u32 = 1 << 6;
const trb_direction_in: u32 = 1 << 16;
const setup_transfer_type_in: u32 = 3 << 16;
const usb_request_get_descriptor: u8 = 6;
const usb_descriptor_type_device: u8 = 1;
const usb_device_descriptor_length: usize = 18;
const legacy_capability_id: u8 = 1;
const legacy_bios_owned: u32 = 1 << 16;
const legacy_os_owned: u32 = 1 << 24;
const operational_usbcmd: usize = 0x00;
const operational_usbsts: usize = 0x04;
const operational_pagesize: usize = 0x08;
const operational_crcr: usize = 0x18;
const operational_dcbaap: usize = 0x30;
const operational_config: usize = 0x38;
const port_register_base: usize = 0x400;
const port_register_stride: usize = 0x10;
const portsc_current_connect_status: u32 = 1 << 0;
const portsc_port_enabled: u32 = 1 << 1;
const portsc_port_reset: u32 = 1 << 4;
const portsc_port_power: u32 = 1 << 9;
const portsc_speed_shift: u5 = 10;
const portsc_indicator_mask: u32 = 0x3 << 14;
const portsc_change_mask: u32 = 0x7F << 17;
const portsc_wake_mask: u32 = 0x7 << 25;
const endpoint_type_control: u32 = 4;
const endpoint_error_count: u32 = 3;
const address_device_command_type: u32 = 11;
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
    command_producer_index: u16,
    event_consumer_index: u16,
};

pub const AddressStage = enum(u8) {
    none,
    port_selected,
    port_reset,
    contexts_ready,
    command_submitted,
    event_received,
    output_context_read,
    complete,
};

pub const AddressDiagnostics = struct {
    stage: AddressStage,
    port_number: u8,
    port_status: u32,
    event_type: u8,
    completion_code: u8,
    event_slot_id: u8,
    command_pointer: u64,
    device_address: u8,
    slot_state: u5,
    endpoint0_state: u3,
};

pub var address_diagnostics = AddressDiagnostics{
    .stage = .none,
    .port_number = 0,
    .port_status = 0,
    .event_type = 0,
    .completion_code = 0,
    .event_slot_id = 0,
    .command_pointer = 0,
    .device_address = 0,
    .slot_state = 0,
    .endpoint0_state = 0,
};

pub fn addressStageName(stage: AddressStage) []const u8 {
    return switch (stage) {
        .none => "none",
        .port_selected => "port-selected",
        .port_reset => "port-reset",
        .contexts_ready => "contexts-ready",
        .command_submitted => "command-submitted",
        .event_received => "event-received",
        .output_context_read => "output-context-read",
        .complete => "complete",
    };
}

pub const AddressedDevice = struct {
    port_number: u8,
    port_speed_id: u4,
    slot_id: u8,
    device_address: u8,
    slot_state: u5,
    endpoint0_state: u3,
    endpoint0_max_packet_size: u16,
    context_size: u8,
    device_context_address: usize,
    input_context_address: usize,
    transfer_ring_address: usize,
    completion_code: u8,
    command_pointer: u64,
    reset_port_status: u32,
    skipped_port_status_events: u8,
    transfer_producer_index: u16,
    transfer_cycle: u1,
};

pub const DeviceDescriptor = struct {
    buffer_address: usize,
    length: u8,
    descriptor_type: u8,
    usb_version_bcd: u16,
    device_class: u8,
    device_subclass: u8,
    device_protocol: u8,
    endpoint0_max_packet_size: u8,
    vendor_id: u16,
    product_id: u16,
    device_version_bcd: u16,
    manufacturer_string_index: u8,
    product_string_index: u8,
    serial_string_index: u8,
    configuration_count: u8,
    completion_code: u8,
    transfer_residual: u32,
    endpoint_id: u5,
    slot_id: u8,
    event_trb_pointer: u64,
    skipped_port_status_events: u8,
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
        .command_producer_index = 1,
        .event_consumer_index = 1,
    };
}

pub fn addressConnectedDevice(
    controller: Controller,
    ownership: *Ownership,
    allocator: *memory.FrameAllocator,
) ?AddressedDevice {
    address_diagnostics = .{
        .stage = .none,
        .port_number = 0,
        .port_status = 0,
        .event_type = 0,
        .completion_code = 0,
        .event_slot_id = 0,
        .command_pointer = 0,
        .device_address = 0,
        .slot_state = 0,
        .endpoint0_state = 0,
    };
    const port = firstConnectedPort(controller) orelse return null;
    address_diagnostics.stage = .port_selected;
    address_diagnostics.port_number = port.number;
    const operational_base = controller.base_address + controller.capability_length;
    const doorbell_base = controller.base_address + controller.doorbell_offset;
    const reset_port_status = resetPort(operational_base, port.number) orelse return null;
    address_diagnostics.stage = .port_reset;
    address_diagnostics.port_status = reset_port_status;
    const speed_id: u4 = @truncate(reset_port_status >> portsc_speed_shift);
    const max_packet_size = endpoint0MaxPacketSize(speed_id) orelse return null;
    const context_size: usize = if (controller.context_size_64_bytes) 64 else 32;

    const device_context_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    const input_context_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    const transfer_ring_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    clearPage(device_context_address);
    clearPage(input_context_address);
    clearPage(transfer_ring_address);

    const transfer_ring = trbPage(transfer_ring_address);
    const transfer_link = &transfer_ring[trbs_per_page - 1];
    transfer_link.parameter = transfer_ring_address;
    transfer_link.status = 0;
    transfer_link.control = (trb_type_link << trb_type_shift) | trb_toggle_cycle | trb_cycle;

    const dcbaa = @as([*]volatile u64, @ptrFromInt(ownership.dcbaa_address));
    dcbaa[ownership.slot_id] = device_context_address;

    const input_control = contextDwords(input_context_address);
    input_control[0] = 0;
    input_control[1] = 0x3;

    const slot = contextDwords(input_context_address + context_size);
    slot[0] = (@as(u32, speed_id) << 20) | (@as(u32, 1) << 27);
    slot[1] = @as(u32, port.number) << 16;
    slot[2] = 0;
    slot[3] = 0;

    const endpoint0 = contextDwords(input_context_address + 2 * context_size);
    endpoint0[0] = 0;
    endpoint0[1] = (@as(u32, endpoint_error_count) << 1) |
        (@as(u32, endpoint_type_control) << 3) |
        (@as(u32, max_packet_size) << 16);
    endpoint0[2] = @truncate(@as(u64, @intCast(transfer_ring_address)) | 1);
    endpoint0[3] = @truncate(@as(u64, @intCast(transfer_ring_address)) >> 32);
    endpoint0[4] = 8;
    zigos_memory_fence();
    address_diagnostics.stage = .contexts_ready;

    if (ownership.command_producer_index >= trbs_per_page - 1 or
        ownership.event_consumer_index >= trbs_per_page)
    {
        return null;
    }
    const command_address = ownership.command_ring_address +
        @as(usize, ownership.command_producer_index) * @sizeOf(Trb);
    const command: *volatile Trb = @ptrFromInt(command_address);
    command.parameter = input_context_address;
    command.status = 0;
    command.control = (address_device_command_type << trb_type_shift) |
        (@as(u32, ownership.slot_id) << 24) |
        ownership.event_cycle;
    zigos_memory_fence();
    write32(doorbell_base, 0, 0);
    address_diagnostics.stage = .command_submitted;

    const completion = waitForCommandCompletion(
        controller,
        ownership,
        command_address,
        ownership.slot_id,
    ) orelse return null;
    const event = completion.event;
    const event_type = (event.control >> trb_type_shift) & 0x3F;
    const completion_code: u8 = @truncate(event.status >> 24);
    const event_slot_id: u8 = @truncate(event.control >> 24);
    const command_pointer = event.parameter & ~@as(u64, 0xF);
    address_diagnostics.stage = .event_received;
    address_diagnostics.event_type = @truncate(event_type);
    address_diagnostics.completion_code = completion_code;
    address_diagnostics.event_slot_id = event_slot_id;
    address_diagnostics.command_pointer = command_pointer;
    ownership.command_producer_index += 1;
    zigos_memory_fence();

    const device_slot = contextDwords(device_context_address);
    const device_endpoint0 = contextDwords(device_context_address + context_size);
    const device_address: u8 = @truncate(device_slot[3]);
    const slot_state: u5 = @truncate(device_slot[3] >> 27);
    const endpoint0_state: u3 = @truncate(device_endpoint0[0]);
    address_diagnostics.stage = .output_context_read;
    address_diagnostics.device_address = device_address;
    address_diagnostics.slot_state = slot_state;
    address_diagnostics.endpoint0_state = endpoint0_state;
    if (device_address == 0 or slot_state < 2 or endpoint0_state == 0) return null;

    address_diagnostics.stage = .complete;
    return .{
        .port_number = port.number,
        .port_speed_id = speed_id,
        .slot_id = ownership.slot_id,
        .device_address = device_address,
        .slot_state = slot_state,
        .endpoint0_state = endpoint0_state,
        .endpoint0_max_packet_size = max_packet_size,
        .context_size = @intCast(context_size),
        .device_context_address = device_context_address,
        .input_context_address = input_context_address,
        .transfer_ring_address = transfer_ring_address,
        .completion_code = completion_code,
        .command_pointer = command_pointer,
        .reset_port_status = reset_port_status,
        .skipped_port_status_events = completion.skipped_port_status_events,
        .transfer_producer_index = 0,
        .transfer_cycle = 1,
    };
}

pub fn readDeviceDescriptor(
    controller: Controller,
    ownership: *Ownership,
    device: *AddressedDevice,
    allocator: *memory.FrameAllocator,
) ?DeviceDescriptor {
    if (device.slot_id != ownership.slot_id or
        device.transfer_producer_index > trbs_per_page - 4)
    {
        return null;
    }
    const buffer_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    clearPage(buffer_address);
    const ring = trbPage(device.transfer_ring_address);
    const start_index: usize = device.transfer_producer_index;
    const cycle: u32 = device.transfer_cycle;

    const setup_packet: u64 = @as(u64, 0x80) |
        (@as(u64, usb_request_get_descriptor) << 8) |
        (@as(u64, usb_descriptor_type_device) << 24) |
        (@as(u64, usb_device_descriptor_length) << 48);
    ring[start_index].parameter = setup_packet;
    ring[start_index].status = 8;
    ring[start_index].control = (trb_type_setup_stage << trb_type_shift) |
        trb_immediate_data | setup_transfer_type_in | cycle;

    ring[start_index + 1].parameter = buffer_address;
    ring[start_index + 1].status = usb_device_descriptor_length;
    ring[start_index + 1].control = (trb_type_data_stage << trb_type_shift) |
        trb_interrupt_on_short_packet | trb_direction_in | cycle;

    ring[start_index + 2].parameter = 0;
    ring[start_index + 2].status = 0;
    ring[start_index + 2].control = (trb_type_status_stage << trb_type_shift) |
        trb_interrupt_on_completion | cycle;
    zigos_memory_fence();

    const doorbell_base = controller.base_address + controller.doorbell_offset;
    write32(
        doorbell_base,
        @as(usize, device.slot_id) * @sizeOf(u32),
        1,
    );
    const status_trb_address = device.transfer_ring_address +
        (start_index + 2) * @sizeOf(Trb);
    const completion = waitForTransferCompletion(
        controller,
        ownership,
        status_trb_address,
        device.slot_id,
        1,
    ) orelse return null;
    device.transfer_producer_index += 3;

    const descriptor = @as([*]const u8, @ptrFromInt(buffer_address));
    if (descriptor[0] != usb_device_descriptor_length or
        descriptor[1] != usb_descriptor_type_device)
    {
        return null;
    }
    const max_packet = descriptor[7];
    if (max_packet == 0 or descriptor[17] == 0) return null;

    return .{
        .buffer_address = buffer_address,
        .length = descriptor[0],
        .descriptor_type = descriptor[1],
        .usb_version_bcd = readLittleEndian16(descriptor + 2),
        .device_class = descriptor[4],
        .device_subclass = descriptor[5],
        .device_protocol = descriptor[6],
        .endpoint0_max_packet_size = max_packet,
        .vendor_id = readLittleEndian16(descriptor + 8),
        .product_id = readLittleEndian16(descriptor + 10),
        .device_version_bcd = readLittleEndian16(descriptor + 12),
        .manufacturer_string_index = descriptor[14],
        .product_string_index = descriptor[15],
        .serial_string_index = descriptor[16],
        .configuration_count = descriptor[17],
        .completion_code = completion.completion_code,
        .transfer_residual = completion.transfer_residual,
        .endpoint_id = completion.endpoint_id,
        .slot_id = completion.slot_id,
        .event_trb_pointer = completion.event_trb_pointer,
        .skipped_port_status_events = completion.skipped_port_status_events,
    };
}

const TransferCompletion = struct {
    completion_code: u8,
    transfer_residual: u32,
    endpoint_id: u5,
    slot_id: u8,
    event_trb_pointer: u64,
    skipped_port_status_events: u8,
};

fn waitForTransferCompletion(
    controller: Controller,
    ownership: *Ownership,
    expected_trb_pointer: usize,
    expected_slot_id: u8,
    expected_endpoint_id: u5,
) ?TransferCompletion {
    var skipped_port_status_events: u8 = 0;
    var events_seen: usize = 0;
    while (events_seen < 32) : (events_seen += 1) {
        const event = consumeEvent(controller, ownership) orelse return null;
        const event_type = (event.control >> trb_type_shift) & 0x3F;
        if (event_type == trb_type_port_status_change) {
            skipped_port_status_events +|= 1;
            continue;
        }
        if (event_type != trb_type_transfer_event) return null;
        const completion_code: u8 = @truncate(event.status >> 24);
        const transfer_residual = event.status & 0x00FF_FFFF;
        const endpoint_id: u5 = @truncate(event.control >> 16);
        const slot_id: u8 = @truncate(event.control >> 24);
        const event_trb_pointer = event.parameter & ~@as(u64, 0xF);
        if (completion_code != completion_success or
            slot_id != expected_slot_id or
            endpoint_id != expected_endpoint_id or
            event_trb_pointer != expected_trb_pointer)
        {
            return null;
        }
        return .{
            .completion_code = completion_code,
            .transfer_residual = transfer_residual,
            .endpoint_id = endpoint_id,
            .slot_id = slot_id,
            .event_trb_pointer = event_trb_pointer,
            .skipped_port_status_events = skipped_port_status_events,
        };
    }
    return null;
}

fn readLittleEndian16(bytes: [*]const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn firstConnectedPort(controller: Controller) ?Port {
    for (controller.ports[0..controller.retained_port_count]) |port| {
        if (port.connected) return port;
    }
    return null;
}

fn resetPort(operational_base: usize, port_number: u8) ?u32 {
    if (port_number == 0) return null;
    const offset = port_register_base +
        (@as(usize, port_number) - 1) * port_register_stride;
    const current = read32(operational_base, offset);
    if ((current & portsc_current_connect_status) == 0) return null;
    var reset_value = current & (portsc_port_power | portsc_indicator_mask | portsc_wake_mask);
    reset_value |= portsc_port_reset;
    write32(operational_base, offset, reset_value);

    var polls: usize = 0;
    while (polls < maximum_poll_count) : (polls += 1) {
        const value = read32(operational_base, offset);
        if ((value & portsc_current_connect_status) == 0) return null;
        if ((value & portsc_port_reset) == 0 and (value & portsc_port_enabled) != 0) {
            const clear_changes = value & portsc_change_mask;
            if (clear_changes != 0) {
                const preserved = value & (portsc_port_power | portsc_indicator_mask | portsc_wake_mask);
                write32(operational_base, offset, preserved | clear_changes);
            }
            return value;
        }
        zigos_cpu_relax();
    }
    return null;
}

fn endpoint0MaxPacketSize(speed_id: u4) ?u16 {
    return switch (speed_id) {
        1 => 64,
        2 => 8,
        3 => 64,
        4 => 512,
        else => null,
    };
}

fn contextDwords(address: usize) [*]volatile u32 {
    return @ptrFromInt(address);
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

const CommandCompletion = struct {
    event: Trb,
    skipped_port_status_events: u8,
};

fn waitForCommandCompletion(
    controller: Controller,
    ownership: *Ownership,
    command_address: usize,
    expected_slot_id: u8,
) ?CommandCompletion {
    var skipped_port_status_events: u8 = 0;
    var events_seen: usize = 0;
    while (events_seen < 32) : (events_seen += 1) {
        const event = consumeEvent(controller, ownership) orelse return null;
        const event_type = (event.control >> trb_type_shift) & 0x3F;
        if (event_type == trb_type_port_status_change) {
            skipped_port_status_events +|= 1;
            continue;
        }
        if (event_type != trb_type_command_completion) return null;
        const completion_code: u8 = @truncate(event.status >> 24);
        const slot_id: u8 = @truncate(event.control >> 24);
        const command_pointer = event.parameter & ~@as(u64, 0xF);
        if (completion_code != completion_success or
            slot_id != expected_slot_id or
            command_pointer != command_address)
        {
            return null;
        }
        return .{
            .event = event,
            .skipped_port_status_events = skipped_port_status_events,
        };
    }
    return null;
}

fn consumeEvent(controller: Controller, ownership: *Ownership) ?Trb {
    if (ownership.event_consumer_index >= trbs_per_page) return null;
    const event_address = ownership.event_ring_address +
        @as(usize, ownership.event_consumer_index) * @sizeOf(Trb);
    const event = waitForEvent(event_address, ownership.event_cycle) orelse return null;

    ownership.event_consumer_index += 1;
    if (ownership.event_consumer_index == trbs_per_page) {
        ownership.event_consumer_index = 0;
        ownership.event_cycle ^= 1;
    }
    const interrupter_base = controller.base_address +
        controller.runtime_offset + interrupter0_offset;
    const next_event_address = ownership.event_ring_address +
        @as(usize, ownership.event_consumer_index) * @sizeOf(Trb);
    write64(
        interrupter_base,
        interrupter_erdp,
        @as(u64, @intCast(next_event_address)) | event_handler_busy,
    );
    zigos_memory_fence();
    return event;
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
