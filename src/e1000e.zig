const std = @import("std");
const pci = @import("pci.zig");
const memory = @import("memory.zig");
const paging = @import("paging.zig");
const apic = @import("apic.zig");
const dhcp = @import("dhcp.zig");
const udp = @import("udp.zig");
const tftp = @import("tftp.zig");

const cc = std.os.uefi.cc;
const pci_command_memory_space: u16 = 1 << 1;
const pci_command_bus_master: u16 = 1 << 2;
const pci_command_interrupt_disable: u16 = 1 << 10;
const register_window_bytes: u64 = 128 * 1024;
const maximum_poll_iterations: usize = 200_000_000;

const ctrl_offset: usize = 0x0000;
const status_offset: usize = 0x0008;
const ctrl_ext_offset: usize = 0x0018;
const icr_offset: usize = 0x00C0;
const ims_offset: usize = 0x00D0;
const imc_offset: usize = 0x00D8;
const eiac_offset: usize = 0x00DC;
const ivar_offset: usize = 0x00E4;
const eitr0_offset: usize = 0x00E8;
const rctl_offset: usize = 0x0100;
const tctl_offset: usize = 0x0400;
const tipg_offset: usize = 0x0410;
const rdbal_offset: usize = 0x2800;
const rdbah_offset: usize = 0x2804;
const rdlen_offset: usize = 0x2808;
const rdh_offset: usize = 0x2810;
const rdt_offset: usize = 0x2818;
const rxdctl_offset: usize = 0x2828;
const tdbal_offset: usize = 0x3800;
const tdbah_offset: usize = 0x3804;
const tdlen_offset: usize = 0x3808;
const tdh_offset: usize = 0x3810;
const tdt_offset: usize = 0x3818;
const txdctl_offset: usize = 0x3828;
const tarc0_offset: usize = 0x3840;
const ral0_offset: usize = 0x5400;
const rah0_offset: usize = 0x5404;

const ctrl_reset: u32 = 1 << 26;
const ctrl_set_link_up: u32 = 1 << 6;
const status_link_up: u32 = 1 << 1;
const status_speed_mask: u32 = 0x3 << 6;
const rah_address_valid: u32 = 1 << 31;
const rctl_enable: u32 = 1 << 1;
const rctl_broadcast_accept: u32 = 1 << 15;
const rctl_strip_crc: u32 = 1 << 26;
const tctl_enable: u32 = 1 << 1;
const tctl_pad_short_packets: u32 = 1 << 3;
const tctl_collision_threshold: u32 = 0x0F << 4;
const tctl_collision_distance: u32 = 0x40 << 12;
const queue_enable: u32 = 1 << 25;
const tarc_enable: u32 = 1 << 10;
const ivar_valid: u32 = 0x8;
const ivar_rxq0_shift: u5 = 0;
const ivar_txq0_shift: u5 = 8;
const interrupt_rxq0: u32 = 0x0010_0000;
const interrupt_txq0: u32 = 0x0040_0000;
const interrupt_mask: u32 = interrupt_rxq0 | interrupt_txq0;
const msix_function_mask: u16 = 1 << 14;
const msix_enable: u16 = 1 << 15;
const msix_vector_mask: u32 = 1;
const msi_message_address_base: u32 = 0xFEE0_0000;
pub const interrupt_vector: u8 = 0x49;
pub const msix_table_index: u16 = 0;

const ring_descriptor_count: usize = 8;
const ring_bytes: u32 = ring_descriptor_count * @sizeOf(RxDescriptor);
const completion_queue_capacity: usize = 32;
const software_packet_queue_capacity: usize = 8;
const maximum_software_packet_bytes: usize = 2048;
const all_rx_descriptors_pending: u32 = (1 << ring_descriptor_count) - 1;
const ethernet_minimum_frame_bytes: usize = 60;
const arp_payload_bytes: usize = 42;
const ether_type_arp: u16 = 0x0806;
const ether_type_ipv4: u16 = 0x0800;
const arp_hardware_ethernet: u16 = 1;
const arp_protocol_ipv4: u16 = ether_type_ipv4;
const arp_request: u16 = 1;
const arp_reply: u16 = 2;
const ipv4_header_bytes: usize = 20;
const ipv4_protocol_icmp: u8 = 1;
const ipv4_protocol_udp: u8 = 17;
const ipv4_dont_fragment: u16 = 1 << 14;
const icmp_echo_reply: u8 = 0;
const icmp_echo_request: u8 = 8;
const icmp_header_bytes: usize = 8;
const icmp_identifier: u16 = 0x5A49;
const icmp_sequence: u16 = 1;
const persistent_icmp_identifier: u16 = 0x5A50;
const persistent_icmp_sequence: u16 = 2;
const queued_icmp_identifier: u16 = 0x5A51;
const queued_icmp_sequence: u16 = 3;
const dispatched_icmp_identifier: u16 = 0x5A52;
const dispatched_icmp_sequence: u16 = 4;
const icmp_payload = "ZigOs-ICMP-ECHO!";
const icmp_ipv4_total_bytes: usize = ipv4_header_bytes + icmp_header_bytes + icmp_payload.len;
const icmp_ethernet_frame_bytes: usize = 14 + icmp_ipv4_total_bytes;

const RxDescriptor = extern struct {
    buffer_address: u64,
    length: u16,
    checksum: u16,
    status: u8,
    errors: u8,
    special: u16,
};

const TxDescriptor = extern struct {
    buffer_address: u64,
    length: u16,
    checksum_offset: u8,
    command: u8,
    status: u8,
    checksum_start: u8,
    special: u16,
};

const MsixTableEntry = extern struct {
    message_address_low: u32,
    message_address_high: u32,
    message_data: u32,
    vector_control: u32,
};

const CompletionQueue = struct {
    entries: [completion_queue_capacity]u8,
    head: u32,
    tail: u32,
    enqueued: u64,
    dequeued: u64,
    high_water: u32,
    overflow: u64,
};

pub const Controller = struct {
    pci_function: pci.Function,
    bar0: usize,
    mapped_base: u64,
    mapped_bytes: u64,
    mapping_table_pages: u64,
    pci_command: u16,
    control: u32,
    status: u32,
    control_extended: u32,
    mac_address: [6]u8,
    link_up: bool,
    link_speed_mbps: u16,
};

pub const Packet = struct {
    length: u16,
    source_descriptor: u16,
    interrupt_count: u64,
    interrupt_cause: u32,
    bytes: [maximum_software_packet_bytes]u8,
};

pub const SoftwarePacketQueue = struct {
    entries: [software_packet_queue_capacity]Packet,
    head: u16,
    tail: u16,
    enqueued: u64,
    dequeued: u64,
    dropped: u64,
    high_water: u16,
};

pub const PacketKind = enum(u8) {
    arp,
    icmp,
    udp,
    unknown,
};

pub const Device = struct {
    bar0: usize,
    rx_ring_address: usize,
    tx_ring_address: usize,
    tx_buffer_address: usize,
    rx_buffer_addresses: [ring_descriptor_count]usize,
    tx_producer: u16,
    rx_consumer: u16,
    interrupt_target_apic_id: u8,
    local_mac: [6]u8,
    local_ipv4: [4]u8,
    gateway_mac: [6]u8,
    gateway_ipv4: [4]u8,
    tx_submissions: u64,
    rx_deliveries: u64,
    last_tx_interrupt_count: u64,
    last_rx_interrupt_count: u64,
    tx_cursor_wraps: u16,
    rx_cursor_wraps: u16,
    rx_recycled_descriptors: u16,
    rx_descriptor_wraps: u16,
    previous_recycled_rx_descriptor: ?usize,
    software_rx_queue: SoftwarePacketQueue,
    arp_rx_queue: SoftwarePacketQueue,
    icmp_rx_queue: SoftwarePacketQueue,
    udp_rx_queue: SoftwarePacketQueue,
    packets_dispatched: u64,
    arp_packets_dispatched: u64,
    icmp_packets_dispatched: u64,
    udp_packets_dispatched: u64,
    unknown_packets_dropped: u64,
};

pub const TxCompletion = struct {
    descriptor_index: u16,
    next_cursor: u16,
    frame_length: u16,
    interrupt_count: u64,
    interrupt_cause: u32,
};

pub const ReceivedFrame = struct {
    descriptor_index: u16,
    next_cursor: u16,
    frame_length: u16,
    bytes: []const u8,
    interrupt_count: u64,
    interrupt_cause: u32,
};

pub const PersistentQueueReport = struct {
    tx: TxCompletion,
    rx_descriptor_index: u16,
    rx_next_cursor: u16,
    rx_frame_length: u16,
    rx_interrupt_count: u64,
    rx_interrupt_cause: u32,
    identifier: u16,
    sequence: u16,
    ttl: u8,
    payload_length: u16,
    tx_submissions: u64,
    rx_deliveries: u64,
    tx_cursor_wraps: u16,
    rx_cursor_wraps: u16,
    tx_queue_enqueues: u64,
    tx_queue_dequeues: u64,
    rx_queue_enqueues: u64,
    rx_queue_dequeues: u64,
    queue_overflows: u64,
    tx_pending_mask: u32,
    rx_pending_mask: u32,
};

pub const SoftwarePacketQueueReport = struct {
    tx: TxCompletion,
    dma_rx_descriptor: u16,
    rx_next_cursor: u16,
    packet_length: u16,
    identifier: u16,
    sequence: u16,
    ttl: u8,
    payload_length: u16,
    queue_enqueued: u64,
    queue_dequeued: u64,
    queue_high_water: u16,
    queue_dropped: u64,
    device_tx_cursor: u16,
    device_rx_cursor: u16,
    tx_queue_enqueues: u64,
    tx_queue_dequeues: u64,
    rx_queue_enqueues: u64,
    rx_queue_dequeues: u64,
    completion_queue_overflows: u64,
    tx_pending_mask: u32,
    rx_pending_mask: u32,
};

pub const ProtocolDispatchReport = struct {
    tx: TxCompletion,
    dma_rx_descriptor: u16,
    device_tx_cursor: u16,
    device_rx_cursor: u16,
    packet_length: u16,
    identifier: u16,
    sequence: u16,
    ttl: u8,
    payload_length: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    ingress_dropped: u64,
    packets_dispatched: u64,
    arp_dispatched: u64,
    icmp_dispatched: u64,
    udp_dispatched: u64,
    unknown_dropped: u64,
    icmp_queue_enqueued: u64,
    icmp_queue_dequeued: u64,
    icmp_queue_high_water: u16,
    icmp_queue_dropped: u64,
    tx_queue_enqueues: u64,
    tx_queue_dequeues: u64,
    rx_queue_enqueues: u64,
    rx_queue_dequeues: u64,
    completion_queue_overflows: u64,
    tx_pending_mask: u32,
    rx_pending_mask: u32,
};

pub const NetworkResult = struct {
    rx_ring_address: usize,
    tx_ring_address: usize,
    tx_buffer_address: usize,
    rx_buffer_address: usize,
    descriptor_count: u16,
    msix_capability_offset: u8,
    msix_control: u16,
    msix_table_address: usize,
    msix_vector_count: u16,
    msix_mapping_table_pages: u64,
    interrupt_target_apic_id: u8,
    dhcp_transaction_id: u32,
    dhcp_discover_length: u16,
    dhcp_offer_length: u16,
    dhcp_request_length: u16,
    dhcp_ack_length: u16,
    dhcp_discover_tx_interrupt_count: u64,
    dhcp_offer_rx_interrupt_count: u64,
    dhcp_request_tx_interrupt_count: u64,
    dhcp_ack_rx_interrupt_count: u64,
    dhcp_discover_tx_interrupt_cause: u32,
    dhcp_offer_rx_interrupt_cause: u32,
    dhcp_request_tx_interrupt_cause: u32,
    dhcp_ack_rx_interrupt_cause: u32,
    dhcp_offer_address: [4]u8,
    dhcp_offer_server_identifier: [4]u8,
    dhcp_offer_lease_seconds: u32,
    dhcp_address: [4]u8,
    dhcp_subnet_mask: [4]u8,
    dhcp_router: [4]u8,
    dhcp_dns_server: [4]u8,
    dhcp_router_advertised: bool,
    dhcp_dns_server_advertised: bool,
    dhcp_server_identifier: [4]u8,
    dhcp_server_mac: [6]u8,
    dhcp_lease_seconds: u32,
    dhcp_reply_ttl: u8,
    dhcp_udp_checksum_present: bool,
    tx_interrupt_count: u64,
    rx_interrupt_count: u64,
    tx_interrupt_cause: u32,
    rx_interrupt_cause: u32,
    transmitted_length: u16,
    received_length: u16,
    gateway_mac_address: [6]u8,
    arp_opcode: u16,
    sender_ipv4: [4]u8,
    target_ipv4: [4]u8,
    icmp_transmitted_length: u16,
    icmp_received_length: u16,
    icmp_tx_interrupt_count: u64,
    icmp_rx_interrupt_count: u64,
    icmp_tx_interrupt_cause: u32,
    icmp_rx_interrupt_cause: u32,
    icmp_identifier: u16,
    icmp_sequence: u16,
    icmp_reply_ttl: u8,
    icmp_payload_length: u16,
    tftp_rrq_length: u16,
    tftp_data_frame_lengths: [tftp.expected_block_count]u16,
    tftp_ack_lengths: [tftp.expected_block_count]u16,
    tftp_server_port: u16,
    tftp_block_count: u16,
    tftp_payload_length: u32,
    tftp_payload_fnv1a64: u64,
    tftp_reply_ttl: u8,
    tftp_udp_checksum_present: bool,
    tftp_final_block: bool,
    tftp_tx_tail_after_ack: u16,
    tftp_tx_wrap_count: u16,
    rx_recycled_descriptors: u16,
    rx_descriptor_wrap_count: u16,
    rx_head_after_stream: u16,
    rx_tail_after_stream: u16,
    tftp_rrq_tx_interrupt_count: u64,
    tftp_data_rx_interrupt_count: u64,
    tftp_ack_tx_interrupt_count: u64,
    tftp_rrq_tx_interrupt_cause: u32,
    tftp_data_rx_interrupt_cause: u32,
    tftp_ack_tx_interrupt_cause: u32,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    rx_completion_dequeues: u64,
    tx_completion_high_water: u32,
    rx_completion_high_water: u32,
    completion_queue_overflows: u64,
    tx_pending_mask_after_stream: u32,
    rx_pending_mask_after_stream: u32,
    persistent: PersistentQueueReport,
    software_packet_queue: SoftwarePacketQueueReport,
    protocol_dispatch: ProtocolDispatchReport,
};

var active_bar0: usize = 0;
var active_rx_descriptors: usize = 0;
var active_tx_descriptors: usize = 0;
var interrupts_enabled: bool = false;
var total_interrupt_count: u64 = 0;
var tx_interrupt_count: u64 = 0;
var rx_interrupt_count: u64 = 0;
var last_tx_cause: u32 = 0;
var last_rx_cause: u32 = 0;
var tx_pending_mask: u32 = 0;
var rx_pending_mask: u32 = 0;
var tx_ready_mask: u32 = 0;
var rx_ready_mask: u32 = 0;
var tx_completion_queue: CompletionQueue = undefined;
var rx_completion_queue: CompletionQueue = undefined;
var active_device_storage: ?Device = null;

extern fn zigos_memory_fence() callconv(cc) void;
extern fn zigos_cpu_relax() callconv(cc) void;
extern fn zigos_enable_interrupts() callconv(cc) void;
extern fn zigos_disable_interrupts() callconv(cc) void;

pub fn inspect(function: pci.Function, allocator: *memory.FrameAllocator) ?Controller {
    if (function.vendor_id != 0x8086 or function.device_id != 0x10D3 or
        function.class_code != 0x02 or function.subclass != 0x00)
    {
        return null;
    }

    var command = pci.readConfiguration16(function, 0x04);
    const required_command = pci_command_memory_space | pci_command_bus_master;
    if ((command & required_command) != required_command) {
        command |= required_command;
        pci.writeConfiguration16(function, 0x04, command);
        command = pci.readConfiguration16(function, 0x04);
        if ((command & required_command) != required_command) return null;
    }

    const bar0_u64 = pci.decodeMemoryBar(function, 0) orelse return null;
    if (bar0_u64 > std.math.maxInt(usize)) return null;
    var mapped_base = bar0_u64;
    var mapped_bytes = register_window_bytes;
    var mapping_table_pages: u64 = 0;
    if (!paging.isIdentityRangeMapped(bar0_u64, register_window_bytes)) {
        const mapping = paging.mapIdentityMmio(allocator, bar0_u64, register_window_bytes) orelse return null;
        mapped_base = mapping.mapped_base;
        mapped_bytes = mapping.mapped_bytes;
        mapping_table_pages = mapping.table_pages;
    }

    const bar0: usize = @intCast(bar0_u64);
    const control = read32(bar0, ctrl_offset);
    const status = read32(bar0, status_offset);
    const control_extended = read32(bar0, ctrl_ext_offset);
    const mac_address = readMacAddress(bar0) orelse return null;

    return .{
        .pci_function = function,
        .bar0 = bar0,
        .mapped_base = mapped_base,
        .mapped_bytes = mapped_bytes,
        .mapping_table_pages = mapping_table_pages,
        .pci_command = command,
        .control = control,
        .status = status,
        .control_extended = control_extended,
        .mac_address = mac_address,
        .link_up = (status & status_link_up) != 0,
        .link_speed_mbps = decodeSpeed(status),
    };
}

pub fn initializeAndTestNetwork(
    controller: *Controller,
    allocator: *memory.FrameAllocator,
    target_apic_id: u8,
) ?NetworkResult {
    const saved_mac = controller.mac_address;
    disableInterrupts(controller.bar0);
    write32(controller.bar0, rctl_offset, 0);
    write32(controller.bar0, tctl_offset, 0);
    write32(controller.bar0, ctrl_offset, read32(controller.bar0, ctrl_offset) | ctrl_reset);
    if (!waitRegisterBits(controller.bar0, ctrl_offset, ctrl_reset, false)) return null;
    writeMacAddress(controller.bar0, saved_mac);
    write32(controller.bar0, ctrl_offset, read32(controller.bar0, ctrl_offset) | ctrl_set_link_up);
    if (!waitRegisterBits(controller.bar0, status_offset, status_link_up, true)) return null;
    controller.control = read32(controller.bar0, ctrl_offset);
    controller.status = read32(controller.bar0, status_offset);
    controller.control_extended = read32(controller.bar0, ctrl_ext_offset);
    controller.mac_address = readMacAddress(controller.bar0) orelse return null;
    controller.link_up = true;
    controller.link_speed_mbps = decodeSpeed(controller.status);

    const rx_ring_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    const tx_ring_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    const tx_buffer_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    clearPage(rx_ring_address);
    clearPage(tx_ring_address);
    clearPage(tx_buffer_address);

    var rx_buffer_addresses: [ring_descriptor_count]usize = undefined;
    const rx_descriptors: [*]volatile RxDescriptor = @ptrFromInt(rx_ring_address);
    for (0..ring_descriptor_count) |index| {
        const buffer_address = allocator.allocateBelow(memory.four_gib) orelse return null;
        clearPage(buffer_address);
        rx_buffer_addresses[index] = buffer_address;
        rx_descriptors[index] = .{
            .buffer_address = buffer_address,
            .length = 0,
            .checksum = 0,
            .status = 0,
            .errors = 0,
            .special = 0,
        };
    }
    const tx_descriptors: [*]volatile TxDescriptor = @ptrFromInt(tx_ring_address);
    for (0..ring_descriptor_count) |index| {
        tx_descriptors[index] = std.mem.zeroes(TxDescriptor);
    }

    programReceiveRing(controller.bar0, rx_ring_address);
    programTransmitRing(controller.bar0, tx_ring_address);
    const msix = configureMsix(controller, allocator, target_apic_id) orelse return null;

    active_bar0 = controller.bar0;
    active_rx_descriptors = rx_ring_address;
    active_tx_descriptors = tx_ring_address;
    resetCompletionQueue(&tx_completion_queue);
    resetCompletionQueue(&rx_completion_queue);
    @atomicStore(u32, &tx_pending_mask, 0, .release);
    @atomicStore(u32, &rx_pending_mask, all_rx_descriptors_pending, .release);
    tx_ready_mask = 0;
    rx_ready_mask = 0;
    @atomicStore(u64, &total_interrupt_count, 0, .release);
    @atomicStore(u64, &tx_interrupt_count, 0, .release);
    @atomicStore(u64, &rx_interrupt_count, 0, .release);
    @atomicStore(u32, &last_tx_cause, 0, .release);
    @atomicStore(u32, &last_rx_cause, 0, .release);
    interrupts_enabled = true;

    write32(controller.bar0, ivar_offset, (ivar_valid << ivar_rxq0_shift) |
        (ivar_valid << ivar_txq0_shift));
    write32(controller.bar0, eitr0_offset, 0);
    write32(controller.bar0, eiac_offset, 0);
    _ = read32(controller.bar0, icr_offset);
    write32(controller.bar0, ims_offset, interrupt_mask);
    _ = read32(controller.bar0, status_offset);

    write32(controller.bar0, rxdctl_offset, read32(controller.bar0, rxdctl_offset) | queue_enable);
    write32(controller.bar0, txdctl_offset, read32(controller.bar0, txdctl_offset) | queue_enable);
    write32(controller.bar0, tarc0_offset, read32(controller.bar0, tarc0_offset) | tarc_enable);
    write32(controller.bar0, tipg_offset, 0x0060_2008);
    write32(controller.bar0, tctl_offset, tctl_enable | tctl_pad_short_packets | tctl_collision_threshold | tctl_collision_distance);
    write32(controller.bar0, rctl_offset, rctl_enable | rctl_broadcast_accept | rctl_strip_crc);
    _ = read32(controller.bar0, status_offset);

    const tx_buffer = @as([*]u8, @ptrFromInt(tx_buffer_address))[0..memory.page_size];
    var rx_recycled_descriptors: u16 = 0;
    var rx_descriptor_wrap_count: u16 = 0;
    var previous_recycled_rx_descriptor: ?usize = null;

    @memset(tx_buffer, 0);
    const discover_length = dhcp.buildDiscover(tx_buffer, controller.mac_address) orelse return null;
    tx_descriptors[0] = makeTxDescriptor(tx_buffer_address, discover_length);
    if (!armTxDescriptor(0)) return null;
    zigos_memory_fence();
    const discover_tx_baseline = txInterruptCount();
    const offer_rx_baseline = rxInterruptCount();
    write32(controller.bar0, tdt_offset, 1);
    _ = read32(controller.bar0, status_offset);
    if (!waitForTx(tx_descriptors, 0, discover_tx_baseline, target_apic_id)) return null;
    if (!waitForRx(rx_descriptors, 0, offer_rx_baseline, target_apic_id)) return null;
    zigos_memory_fence();
    const offer_length = validateRxDescriptor(rx_descriptors, 0) orelse return null;
    const offer_frame = @as([*]const u8, @ptrFromInt(rx_buffer_addresses[0]))[0..offer_length];
    const offer = dhcp.parseOffer(offer_frame, controller.mac_address) orelse return null;
    const discover_tx_interrupt_count = txInterruptCount() - discover_tx_baseline;
    const offer_rx_interrupt_count = rxInterruptCount() - offer_rx_baseline;
    const discover_tx_interrupt_cause = @atomicLoad(u32, &last_tx_cause, .acquire);
    const offer_rx_interrupt_cause = @atomicLoad(u32, &last_rx_cause, .acquire);
    if (!recycleRxDescriptor(
        controller.bar0,
        rx_descriptors,
        0,
        &rx_recycled_descriptors,
        &rx_descriptor_wrap_count,
        &previous_recycled_rx_descriptor,
    )) return null;

    @memset(tx_buffer, 0);
    const request_length = dhcp.buildRequest(tx_buffer, controller.mac_address, offer.lease) orelse return null;
    tx_descriptors[1] = makeTxDescriptor(tx_buffer_address, request_length);
    if (!armTxDescriptor(1)) return null;
    zigos_memory_fence();
    const request_tx_baseline = txInterruptCount();
    const ack_rx_baseline = rxInterruptCount();
    write32(controller.bar0, tdt_offset, 2);
    _ = read32(controller.bar0, status_offset);
    if (!waitForTx(tx_descriptors, 1, request_tx_baseline, target_apic_id)) return null;
    if (!waitForRx(rx_descriptors, 1, ack_rx_baseline, target_apic_id)) return null;
    zigos_memory_fence();
    const ack_length = validateRxDescriptor(rx_descriptors, 1) orelse return null;
    const ack_frame = @as([*]const u8, @ptrFromInt(rx_buffer_addresses[1]))[0..ack_length];
    const ack = dhcp.parseAck(ack_frame, controller.mac_address, offer.lease) orelse return null;
    const request_tx_interrupt_count = txInterruptCount() - request_tx_baseline;
    const ack_rx_interrupt_count = rxInterruptCount() - ack_rx_baseline;
    const request_tx_interrupt_cause = @atomicLoad(u32, &last_tx_cause, .acquire);
    const ack_rx_interrupt_cause = @atomicLoad(u32, &last_rx_cause, .acquire);
    if (!recycleRxDescriptor(
        controller.bar0,
        rx_descriptors,
        1,
        &rx_recycled_descriptors,
        &rx_descriptor_wrap_count,
        &previous_recycled_rx_descriptor,
    )) return null;

    @memset(tx_buffer, 0);
    buildArpRequest(
        tx_buffer[0..ethernet_minimum_frame_bytes],
        controller.mac_address,
        ack.lease.address,
        ack.lease.router,
    );
    tx_descriptors[2] = makeTxDescriptor(tx_buffer_address, ethernet_minimum_frame_bytes);
    if (!armTxDescriptor(2)) return null;
    zigos_memory_fence();
    const arp_tx_baseline = txInterruptCount();
    const arp_rx_baseline = rxInterruptCount();
    write32(controller.bar0, tdt_offset, 3);
    _ = read32(controller.bar0, status_offset);
    if (!waitForTx(tx_descriptors, 2, arp_tx_baseline, target_apic_id)) return null;
    if (!waitForRx(rx_descriptors, 2, arp_rx_baseline, target_apic_id)) return null;
    zigos_memory_fence();
    const received_length = validateRxDescriptor(rx_descriptors, 2) orelse return null;
    if (received_length < arp_payload_bytes) return null;
    const received = @as([*]const u8, @ptrFromInt(rx_buffer_addresses[2]))[0..received_length];
    const parsed = parseArpReply(
        received,
        controller.mac_address,
        ack.lease.address,
        ack.lease.router,
    ) orelse return null;
    const arp_tx_interrupt_count = txInterruptCount() - arp_tx_baseline;
    const arp_rx_interrupt_count = rxInterruptCount() - arp_rx_baseline;
    const arp_tx_interrupt_cause = @atomicLoad(u32, &last_tx_cause, .acquire);
    const arp_rx_interrupt_cause = @atomicLoad(u32, &last_rx_cause, .acquire);
    if (!recycleRxDescriptor(
        controller.bar0,
        rx_descriptors,
        2,
        &rx_recycled_descriptors,
        &rx_descriptor_wrap_count,
        &previous_recycled_rx_descriptor,
    )) return null;

    @memset(tx_buffer, 0);
    buildIcmpEchoRequest(
        tx_buffer[0..ethernet_minimum_frame_bytes],
        controller.mac_address,
        parsed.gateway_mac_address,
        ack.lease.address,
        ack.lease.router,
        icmp_identifier,
        icmp_sequence,
    );
    tx_descriptors[3] = makeTxDescriptor(tx_buffer_address, ethernet_minimum_frame_bytes);
    if (!armTxDescriptor(3)) return null;
    zigos_memory_fence();
    const icmp_tx_baseline = txInterruptCount();
    const icmp_rx_baseline = rxInterruptCount();
    write32(controller.bar0, tdt_offset, 4);
    _ = read32(controller.bar0, status_offset);
    if (!waitForTx(tx_descriptors, 3, icmp_tx_baseline, target_apic_id)) return null;
    if (!waitForRx(rx_descriptors, 3, icmp_rx_baseline, target_apic_id)) return null;
    zigos_memory_fence();
    const icmp_received_length = validateRxDescriptor(rx_descriptors, 3) orelse return null;
    if (icmp_received_length < 14 + ipv4_header_bytes + icmp_header_bytes) return null;
    const icmp_received = @as([*]const u8, @ptrFromInt(rx_buffer_addresses[3]))[0..icmp_received_length];
    const icmp = parseIcmpEchoReply(
        icmp_received,
        controller.mac_address,
        parsed.gateway_mac_address,
        ack.lease.address,
        ack.lease.router,
        icmp_identifier,
        icmp_sequence,
    ) orelse return null;
    const icmp_tx_interrupt_count = txInterruptCount() - icmp_tx_baseline;
    const icmp_rx_interrupt_count = rxInterruptCount() - icmp_rx_baseline;
    const icmp_tx_interrupt_cause = @atomicLoad(u32, &last_tx_cause, .acquire);
    const icmp_rx_interrupt_cause = @atomicLoad(u32, &last_rx_cause, .acquire);
    if (!recycleRxDescriptor(
        controller.bar0,
        rx_descriptors,
        3,
        &rx_recycled_descriptors,
        &rx_descriptor_wrap_count,
        &previous_recycled_rx_descriptor,
    )) return null;

    var tftp_payload_buffer: [128]u8 = undefined;
    const read_request = tftp.buildReadRequest(&tftp_payload_buffer) orelse return null;
    const rrq_length = udp.buildFrame(tx_buffer, .{
        .source_mac = controller.mac_address,
        .destination_mac = parsed.gateway_mac_address,
        .source_ipv4 = ack.lease.address,
        .destination_ipv4 = ack.lease.router,
        .source_port = tftp.client_port,
        .destination_port = tftp.server_port,
        .identification = 0x5A50,
        .payload = read_request,
    }) orelse return null;
    tx_descriptors[4] = makeTxDescriptor(tx_buffer_address, rrq_length);
    if (!armTxDescriptor(4)) return null;
    zigos_memory_fence();
    const tftp_rrq_tx_baseline = txInterruptCount();
    var next_data_rx_baseline = rxInterruptCount();
    write32(controller.bar0, tdt_offset, 5);
    _ = read32(controller.bar0, status_offset);
    if (!waitForTx(tx_descriptors, 4, tftp_rrq_tx_baseline, target_apic_id)) return null;
    const tftp_rrq_tx_interrupt_count = txInterruptCount() - tftp_rrq_tx_baseline;
    const tftp_rrq_tx_interrupt_cause = @atomicLoad(u32, &last_tx_cause, .acquire);

    var tftp_data_frame_lengths = std.mem.zeroes([tftp.expected_block_count]u16);
    var tftp_ack_lengths = std.mem.zeroes([tftp.expected_block_count]u16);
    var tftp_server_port: u16 = 0;
    var tftp_reply_ttl: u8 = 0;
    var tftp_udp_checksum_present = true;
    var tftp_final_block = false;
    var tftp_block_count: u16 = 0;
    var tftp_payload_length: usize = 0;
    var tftp_payload_fnv1a64 = tftp.initial_fnv1a64;
    var tftp_data_rx_interrupt_count: u64 = 0;
    var tftp_ack_tx_interrupt_count: u64 = 0;
    var tftp_data_rx_interrupt_cause: u32 = 0;
    var tftp_ack_tx_interrupt_cause: u32 = 0;
    var tftp_tx_wrap_count: u16 = 0;

    while (tftp_block_count < tftp.expected_block_count) {
        const sequence_index: usize = tftp_block_count;
        const rx_descriptor_index = (4 + sequence_index) % ring_descriptor_count;
        if (!waitForRx(
            rx_descriptors,
            rx_descriptor_index,
            next_data_rx_baseline,
            target_apic_id,
        )) return null;
        zigos_memory_fence();
        const data_frame_length = validateRxDescriptor(
            rx_descriptors,
            rx_descriptor_index,
        ) orelse return null;
        const data_frame = @as(
            [*]const u8,
            @ptrFromInt(rx_buffer_addresses[rx_descriptor_index]),
        )[0..data_frame_length];
        const datagram = udp.parseFrame(data_frame, .{
            .destination_mac = controller.mac_address,
            .source_mac = parsed.gateway_mac_address,
            .destination_ipv4 = ack.lease.address,
            .source_ipv4 = ack.lease.router,
            .destination_port = tftp.client_port,
            .source_port = if (tftp_server_port == 0) null else tftp_server_port,
        }) orelse return null;
        if (tftp_server_port == 0) {
            tftp_server_port = datagram.source_port;
            tftp_reply_ttl = datagram.ttl;
        } else if (datagram.source_port != tftp_server_port or datagram.ttl != tftp_reply_ttl) {
            return null;
        }
        tftp_udp_checksum_present = tftp_udp_checksum_present and datagram.udp_checksum_present;

        const expected_block: u16 = tftp_block_count + 1;
        const data = tftp.parseData(
            datagram.payload,
            expected_block,
            tftp_payload_length,
        ) orelse return null;
        tftp_data_frame_lengths[sequence_index] = datagram.frame_length;
        tftp_payload_fnv1a64 = tftp.updatePayloadHash(tftp_payload_fnv1a64, data.payload);
        tftp_payload_length += data.payload.len;
        tftp_final_block = data.final_block;
        tftp_block_count += 1;
        const data_interrupt_observed = rxInterruptCount();
        if (data_interrupt_observed == next_data_rx_baseline) return null;
        tftp_data_rx_interrupt_count += data_interrupt_observed - next_data_rx_baseline;
        tftp_data_rx_interrupt_cause = @atomicLoad(u32, &last_rx_cause, .acquire);
        if (!recycleRxDescriptor(
            controller.bar0,
            rx_descriptors,
            rx_descriptor_index,
            &rx_recycled_descriptors,
            &rx_descriptor_wrap_count,
            &previous_recycled_rx_descriptor,
        )) return null;

        if (tftp_final_block != (tftp_block_count == tftp.expected_block_count)) return null;
        const next_block_rx_baseline = if (!tftp_final_block) rxInterruptCount() else 0;
        const acknowledgement = tftp.buildAcknowledgement(
            &tftp_payload_buffer,
            data.block,
        ) orelse return null;
        const acknowledgement_length = udp.buildFrame(tx_buffer, .{
            .source_mac = controller.mac_address,
            .destination_mac = parsed.gateway_mac_address,
            .source_ipv4 = ack.lease.address,
            .destination_ipv4 = ack.lease.router,
            .source_port = tftp.client_port,
            .destination_port = tftp_server_port,
            .identification = 0x5A51 + tftp_block_count - 1,
            .payload = acknowledgement,
        }) orelse return null;
        tftp_ack_lengths[sequence_index] = acknowledgement_length;
        const tx_descriptor_index = (5 + sequence_index) % ring_descriptor_count;
        tx_descriptors[tx_descriptor_index] = makeTxDescriptor(
            tx_buffer_address,
            acknowledgement_length,
        );
        if (!armTxDescriptor(tx_descriptor_index)) return null;
        zigos_memory_fence();
        const acknowledgement_tx_baseline = txInterruptCount();
        const next_tx_tail: u16 = @intCast((tx_descriptor_index + 1) % ring_descriptor_count);
        if (next_tx_tail == 0) tftp_tx_wrap_count +|= 1;
        write32(controller.bar0, tdt_offset, next_tx_tail);
        _ = read32(controller.bar0, status_offset);
        if (!waitForTx(
            tx_descriptors,
            tx_descriptor_index,
            acknowledgement_tx_baseline,
            target_apic_id,
        )) return null;
        const acknowledgement_interrupt_observed = txInterruptCount();
        if (acknowledgement_interrupt_observed == acknowledgement_tx_baseline) return null;
        tftp_ack_tx_interrupt_count += acknowledgement_interrupt_observed - acknowledgement_tx_baseline;
        tftp_ack_tx_interrupt_cause = @atomicLoad(u32, &last_tx_cause, .acquire);
        if (!tftp_final_block) next_data_rx_baseline = next_block_rx_baseline;
    }

    const tftp_tx_tail_after_ack: u16 = @truncate(read32(controller.bar0, tdt_offset));
    const rx_head_after_stream: u16 = @truncate(read32(controller.bar0, rdh_offset));
    const rx_tail_after_stream: u16 = @truncate(read32(controller.bar0, rdt_offset));
    const tx_completion_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_completion_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_completion_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const rx_completion_dequeues = completionQueueDequeued(&rx_completion_queue);
    const tx_completion_high_water = completionQueueHighWater(&tx_completion_queue);
    const rx_completion_high_water = completionQueueHighWater(&rx_completion_queue);
    const completion_queue_overflows = completionQueueOverflow(&tx_completion_queue) +
        completionQueueOverflow(&rx_completion_queue);
    const tx_pending_mask_after_stream = @atomicLoad(u32, &tx_pending_mask, .acquire);
    const rx_pending_mask_after_stream = @atomicLoad(u32, &rx_pending_mask, .acquire);
    const expected_tx_completions: u64 = 5 + tftp.expected_block_count;
    const expected_rx_completions: u64 = 4 + tftp.expected_block_count;
    if (!tftp_final_block or
        tftp_block_count != tftp.expected_block_count or
        tftp_payload_length != tftp.expected_file_bytes or
        tftp_payload_fnv1a64 != tftp.expected_payload_fnv1a64 or
        tftp_server_port == 0 or
        tftp_tx_tail_after_ack != 2 or
        tftp_tx_wrap_count != 1 or
        rx_recycled_descriptors != 4 + tftp.expected_block_count or
        rx_descriptor_wrap_count != 1 or
        rx_head_after_stream != 1 or
        rx_tail_after_stream != 0 or
        tx_completion_enqueues != expected_tx_completions or
        tx_completion_dequeues != expected_tx_completions or
        rx_completion_enqueues != expected_rx_completions or
        rx_completion_dequeues != expected_rx_completions or
        tx_completion_high_water == 0 or
        rx_completion_high_water == 0 or
        completion_queue_overflows != 0 or
        tx_pending_mask_after_stream != 0 or
        rx_pending_mask_after_stream != all_rx_descriptors_pending or
        tx_ready_mask != 0 or
        rx_ready_mask != 0)
    {
        return null;
    }

    active_device_storage = .{
        .bar0 = controller.bar0,
        .rx_ring_address = rx_ring_address,
        .tx_ring_address = tx_ring_address,
        .tx_buffer_address = tx_buffer_address,
        .rx_buffer_addresses = rx_buffer_addresses,
        .tx_producer = tftp_tx_tail_after_ack,
        .rx_consumer = rx_head_after_stream,
        .interrupt_target_apic_id = target_apic_id,
        .local_mac = controller.mac_address,
        .local_ipv4 = ack.lease.address,
        .gateway_mac = parsed.gateway_mac_address,
        .gateway_ipv4 = ack.lease.router,
        .tx_submissions = 0,
        .rx_deliveries = 0,
        .last_tx_interrupt_count = txInterruptCount(),
        .last_rx_interrupt_count = rxInterruptCount(),
        .tx_cursor_wraps = 0,
        .rx_cursor_wraps = 0,
        .rx_recycled_descriptors = 0,
        .rx_descriptor_wraps = 0,
        .previous_recycled_rx_descriptor = 0,
        .software_rx_queue = std.mem.zeroes(SoftwarePacketQueue),
        .arp_rx_queue = std.mem.zeroes(SoftwarePacketQueue),
        .icmp_rx_queue = std.mem.zeroes(SoftwarePacketQueue),
        .udp_rx_queue = std.mem.zeroes(SoftwarePacketQueue),
        .packets_dispatched = 0,
        .arp_packets_dispatched = 0,
        .icmp_packets_dispatched = 0,
        .udp_packets_dispatched = 0,
        .unknown_packets_dropped = 0,
    };
    const device = activeDevice() orelse return null;
    const persistent = verifyPersistentQueueOwner(device) orelse {
        active_device_storage = null;
        return null;
    };
    const software_packet_queue = verifySoftwarePacketQueue(device) orelse {
        active_device_storage = null;
        return null;
    };
    const protocol_dispatch = verifyProtocolDispatch(device) orelse {
        active_device_storage = null;
        return null;
    };

    return .{
        .rx_ring_address = rx_ring_address,
        .tx_ring_address = tx_ring_address,
        .tx_buffer_address = tx_buffer_address,
        .rx_buffer_address = rx_buffer_addresses[0],
        .descriptor_count = ring_descriptor_count,
        .msix_capability_offset = msix.capability_offset,
        .msix_control = msix.control,
        .msix_table_address = msix.table_address,
        .msix_vector_count = msix.vector_count,
        .msix_mapping_table_pages = msix.mapping_table_pages,
        .interrupt_target_apic_id = target_apic_id,
        .dhcp_transaction_id = dhcp.transaction_id,
        .dhcp_discover_length = discover_length,
        .dhcp_offer_length = offer.frame_length,
        .dhcp_request_length = request_length,
        .dhcp_ack_length = ack.frame_length,
        .dhcp_discover_tx_interrupt_count = discover_tx_interrupt_count,
        .dhcp_offer_rx_interrupt_count = offer_rx_interrupt_count,
        .dhcp_request_tx_interrupt_count = request_tx_interrupt_count,
        .dhcp_ack_rx_interrupt_count = ack_rx_interrupt_count,
        .dhcp_discover_tx_interrupt_cause = discover_tx_interrupt_cause,
        .dhcp_offer_rx_interrupt_cause = offer_rx_interrupt_cause,
        .dhcp_request_tx_interrupt_cause = request_tx_interrupt_cause,
        .dhcp_ack_rx_interrupt_cause = ack_rx_interrupt_cause,
        .dhcp_offer_address = offer.lease.address,
        .dhcp_offer_server_identifier = offer.lease.server_identifier,
        .dhcp_offer_lease_seconds = offer.lease.lease_seconds,
        .dhcp_address = ack.lease.address,
        .dhcp_subnet_mask = ack.lease.subnet_mask,
        .dhcp_router = ack.lease.router,
        .dhcp_dns_server = ack.lease.dns_server,
        .dhcp_router_advertised = ack.lease.router_advertised,
        .dhcp_dns_server_advertised = ack.lease.dns_server_advertised,
        .dhcp_server_identifier = ack.lease.server_identifier,
        .dhcp_server_mac = ack.lease.server_mac,
        .dhcp_lease_seconds = ack.lease.lease_seconds,
        .dhcp_reply_ttl = ack.lease.reply_ttl,
        .dhcp_udp_checksum_present = ack.lease.udp_checksum_present,
        .tx_interrupt_count = arp_tx_interrupt_count,
        .rx_interrupt_count = arp_rx_interrupt_count,
        .tx_interrupt_cause = arp_tx_interrupt_cause,
        .rx_interrupt_cause = arp_rx_interrupt_cause,
        .transmitted_length = ethernet_minimum_frame_bytes,
        .received_length = received_length,
        .gateway_mac_address = parsed.gateway_mac_address,
        .arp_opcode = parsed.opcode,
        .sender_ipv4 = parsed.sender_ipv4,
        .target_ipv4 = parsed.target_ipv4,
        .icmp_transmitted_length = ethernet_minimum_frame_bytes,
        .icmp_received_length = icmp_received_length,
        .icmp_tx_interrupt_count = icmp_tx_interrupt_count,
        .icmp_rx_interrupt_count = icmp_rx_interrupt_count,
        .icmp_tx_interrupt_cause = icmp_tx_interrupt_cause,
        .icmp_rx_interrupt_cause = icmp_rx_interrupt_cause,
        .icmp_identifier = icmp.identifier,
        .icmp_sequence = icmp.sequence,
        .icmp_reply_ttl = icmp.ttl,
        .icmp_payload_length = icmp.payload_length,
        .tftp_rrq_length = rrq_length,
        .tftp_data_frame_lengths = tftp_data_frame_lengths,
        .tftp_ack_lengths = tftp_ack_lengths,
        .tftp_server_port = tftp_server_port,
        .tftp_block_count = tftp_block_count,
        .tftp_payload_length = @intCast(tftp_payload_length),
        .tftp_payload_fnv1a64 = tftp_payload_fnv1a64,
        .tftp_reply_ttl = tftp_reply_ttl,
        .tftp_udp_checksum_present = tftp_udp_checksum_present,
        .tftp_final_block = tftp_final_block,
        .tftp_tx_tail_after_ack = tftp_tx_tail_after_ack,
        .tftp_tx_wrap_count = tftp_tx_wrap_count,
        .rx_recycled_descriptors = rx_recycled_descriptors,
        .rx_descriptor_wrap_count = rx_descriptor_wrap_count,
        .rx_head_after_stream = rx_head_after_stream,
        .rx_tail_after_stream = rx_tail_after_stream,
        .tftp_rrq_tx_interrupt_count = tftp_rrq_tx_interrupt_count,
        .tftp_data_rx_interrupt_count = tftp_data_rx_interrupt_count,
        .tftp_ack_tx_interrupt_count = tftp_ack_tx_interrupt_count,
        .tftp_rrq_tx_interrupt_cause = tftp_rrq_tx_interrupt_cause,
        .tftp_data_rx_interrupt_cause = tftp_data_rx_interrupt_cause,
        .tftp_ack_tx_interrupt_cause = tftp_ack_tx_interrupt_cause,
        .tx_completion_enqueues = tx_completion_enqueues,
        .tx_completion_dequeues = tx_completion_dequeues,
        .rx_completion_enqueues = rx_completion_enqueues,
        .rx_completion_dequeues = rx_completion_dequeues,
        .tx_completion_high_water = tx_completion_high_water,
        .rx_completion_high_water = rx_completion_high_water,
        .completion_queue_overflows = completion_queue_overflows,
        .tx_pending_mask_after_stream = tx_pending_mask_after_stream,
        .rx_pending_mask_after_stream = rx_pending_mask_after_stream,
        .persistent = persistent,
        .software_packet_queue = software_packet_queue,
        .protocol_dispatch = protocol_dispatch,
    };
}

pub fn activeDevice() ?*Device {
    if (active_device_storage) |*device| return device;
    return null;
}

pub fn submitFrame(device: *Device, frame: []const u8) ?TxCompletion {
    if (device.bar0 == 0 or frame.len == 0 or frame.len > memory.page_size or
        device.tx_producer >= ring_descriptor_count)
    {
        return null;
    }
    const descriptor_index: usize = device.tx_producer;
    const tx_buffer = @as([*]u8, @ptrFromInt(device.tx_buffer_address))[0..memory.page_size];
    @memset(tx_buffer, 0);
    @memcpy(tx_buffer[0..frame.len], frame);
    const descriptors: [*]volatile TxDescriptor = @ptrFromInt(device.tx_ring_address);
    descriptors[descriptor_index] = makeTxDescriptor(device.tx_buffer_address, @intCast(frame.len));
    if (!armTxDescriptor(descriptor_index)) return null;
    zigos_memory_fence();

    const baseline = device.last_tx_interrupt_count;
    const next_cursor: u16 = @intCast((descriptor_index + 1) % ring_descriptor_count);
    if (next_cursor == 0) device.tx_cursor_wraps +|= 1;
    write32(device.bar0, tdt_offset, next_cursor);
    _ = read32(device.bar0, status_offset);
    if (!waitForTx(descriptors, descriptor_index, baseline, device.interrupt_target_apic_id)) return null;
    const observed = txInterruptCount();
    if (observed == baseline) return null;

    device.tx_producer = next_cursor;
    device.tx_submissions +|= 1;
    device.last_tx_interrupt_count = observed;
    return .{
        .descriptor_index = @intCast(descriptor_index),
        .next_cursor = next_cursor,
        .frame_length = @intCast(frame.len),
        .interrupt_count = observed - baseline,
        .interrupt_cause = @atomicLoad(u32, &last_tx_cause, .acquire),
    };
}

pub fn receiveFrame(device: *Device) ?ReceivedFrame {
    if (device.bar0 == 0 or device.rx_consumer >= ring_descriptor_count) return null;
    const descriptor_index: usize = device.rx_consumer;
    const descriptors: [*]volatile RxDescriptor = @ptrFromInt(device.rx_ring_address);
    const baseline = device.last_rx_interrupt_count;
    if (!waitForRx(descriptors, descriptor_index, baseline, device.interrupt_target_apic_id)) return null;
    zigos_memory_fence();
    const frame_length = validateRxDescriptor(descriptors, descriptor_index) orelse return null;
    const next_cursor: u16 = @intCast((descriptor_index + 1) % ring_descriptor_count);
    if (next_cursor == 0) device.rx_cursor_wraps +|= 1;
    device.rx_consumer = next_cursor;
    device.rx_deliveries +|= 1;
    const observed = rxInterruptCount();
    if (observed == baseline) return null;
    device.last_rx_interrupt_count = observed;
    return .{
        .descriptor_index = @intCast(descriptor_index),
        .next_cursor = next_cursor,
        .frame_length = frame_length,
        .bytes = @as(
            [*]const u8,
            @ptrFromInt(device.rx_buffer_addresses[descriptor_index]),
        )[0..frame_length],
        .interrupt_count = observed - baseline,
        .interrupt_cause = @atomicLoad(u32, &last_rx_cause, .acquire),
    };
}

pub fn releaseFrame(device: *Device, frame: ReceivedFrame) bool {
    return recycleRxDescriptor(
        device.bar0,
        @ptrFromInt(device.rx_ring_address),
        frame.descriptor_index,
        &device.rx_recycled_descriptors,
        &device.rx_descriptor_wraps,
        &device.previous_recycled_rx_descriptor,
    );
}

pub fn pumpReceive(device: *Device) bool {
    const frame = receiveFrame(device) orelse return false;
    const enqueued = enqueueSoftwarePacket(&device.software_rx_queue, frame);
    const released = releaseFrame(device, frame);
    return enqueued and released;
}

pub fn dequeuePacket(device: *Device) ?Packet {
    return dequeueQueuedPacket(&device.software_rx_queue);
}

pub fn dispatchNextPacket(device: *Device) bool {
    const packet = dequeuePacket(device) orelse return false;
    const kind = classifyPacket(packet.bytes[0..packet.length]);
    const queue = switch (kind) {
        .arp => &device.arp_rx_queue,
        .icmp => &device.icmp_rx_queue,
        .udp => &device.udp_rx_queue,
        .unknown => {
            device.unknown_packets_dropped +|= 1;
            return false;
        },
    };
    if (!enqueueQueuedPacket(queue, packet)) return false;
    device.packets_dispatched +|= 1;
    switch (kind) {
        .arp => device.arp_packets_dispatched +|= 1,
        .icmp => device.icmp_packets_dispatched +|= 1,
        .udp => device.udp_packets_dispatched +|= 1,
        .unknown => unreachable,
    }
    return true;
}

pub fn dequeueArpPacket(device: *Device) ?Packet {
    return dequeueQueuedPacket(&device.arp_rx_queue);
}

pub fn dequeueIcmpPacket(device: *Device) ?Packet {
    return dequeueQueuedPacket(&device.icmp_rx_queue);
}

pub fn dequeueUdpPacket(device: *Device) ?Packet {
    return dequeueQueuedPacket(&device.udp_rx_queue);
}

fn dequeueQueuedPacket(queue: *SoftwarePacketQueue) ?Packet {
    if (queue.tail == queue.head) return null;
    const packet = queue.entries[queue.tail];
    queue.tail = @intCast((queue.tail + 1) % software_packet_queue_capacity);
    queue.dequeued +|= 1;
    return packet;
}

fn enqueueSoftwarePacket(queue: *SoftwarePacketQueue, frame: ReceivedFrame) bool {
    if (frame.frame_length == 0 or frame.frame_length > maximum_software_packet_bytes) {
        queue.dropped +|= 1;
        return false;
    }
    const next: u16 = @intCast((queue.head + 1) % software_packet_queue_capacity);
    if (next == queue.tail) {
        queue.dropped +|= 1;
        return false;
    }
    var packet = &queue.entries[queue.head];
    @memset(packet.bytes[0..], 0);
    @memcpy(packet.bytes[0..frame.frame_length], frame.bytes);
    packet.length = frame.frame_length;
    packet.source_descriptor = frame.descriptor_index;
    packet.interrupt_count = frame.interrupt_count;
    packet.interrupt_cause = frame.interrupt_cause;
    queue.head = next;
    queue.enqueued +|= 1;
    const depth: u16 = @intCast((queue.head + software_packet_queue_capacity - queue.tail) % software_packet_queue_capacity);
    if (depth > queue.high_water) queue.high_water = depth;
    return true;
}

fn enqueueQueuedPacket(queue: *SoftwarePacketQueue, packet: Packet) bool {
    const next: u16 = @intCast((queue.head + 1) % software_packet_queue_capacity);
    if (next == queue.tail) {
        queue.dropped +|= 1;
        return false;
    }
    queue.entries[queue.head] = packet;
    queue.head = next;
    queue.enqueued +|= 1;
    const depth: u16 = @intCast((queue.head + software_packet_queue_capacity - queue.tail) % software_packet_queue_capacity);
    if (depth > queue.high_water) queue.high_water = depth;
    return true;
}

fn classifyPacket(frame: []const u8) PacketKind {
    if (frame.len < 14) return .unknown;
    const ether_type = readNetwork16(frame, 12);
    if (ether_type == ether_type_arp) return .arp;
    if (ether_type != ether_type_ipv4 or frame.len < 14 + ipv4_header_bytes) return .unknown;

    const ip_offset: usize = 14;
    if ((frame[ip_offset] >> 4) != 4) return .unknown;
    const ihl_bytes: usize = @as(usize, frame[ip_offset] & 0x0F) * 4;
    if (ihl_bytes < ipv4_header_bytes or ip_offset + ihl_bytes > frame.len) return .unknown;
    const total_length: usize = readNetwork16(frame, ip_offset + 2);
    if (total_length < ihl_bytes or ip_offset + total_length > frame.len) return .unknown;
    if ((readNetwork16(frame, ip_offset + 6) & 0x3FFF) != 0) return .unknown;

    return switch (frame[ip_offset + 9]) {
        ipv4_protocol_icmp => .icmp,
        ipv4_protocol_udp => .udp,
        else => .unknown,
    };
}

fn verifyPersistentQueueOwner(device: *Device) ?PersistentQueueReport {
    var request = std.mem.zeroes([ethernet_minimum_frame_bytes]u8);
    buildIcmpEchoRequest(
        &request,
        device.local_mac,
        device.gateway_mac,
        device.local_ipv4,
        device.gateway_ipv4,
        persistent_icmp_identifier,
        persistent_icmp_sequence,
    );
    const tx = submitFrame(device, &request) orelse return null;
    const rx = receiveFrame(device) orelse return null;
    const parsed = parseIcmpEchoReply(
        rx.bytes,
        device.local_mac,
        device.gateway_mac,
        device.local_ipv4,
        device.gateway_ipv4,
        persistent_icmp_identifier,
        persistent_icmp_sequence,
    ) orelse return null;
    if (!releaseFrame(device, rx)) return null;

    const tx_queue_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_queue_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_queue_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const rx_queue_dequeues = completionQueueDequeued(&rx_completion_queue);
    const queue_overflows = completionQueueOverflow(&tx_completion_queue) +
        completionQueueOverflow(&rx_completion_queue);
    const final_tx_pending = @atomicLoad(u32, &tx_pending_mask, .acquire);
    const final_rx_pending = @atomicLoad(u32, &rx_pending_mask, .acquire);
    if (tx.descriptor_index != 2 or tx.next_cursor != 3 or
        rx.descriptor_index != 1 or rx.next_cursor != 2 or
        device.tx_submissions != 1 or device.rx_deliveries != 1 or
        device.tx_cursor_wraps != 0 or device.rx_cursor_wraps != 0 or
        device.rx_recycled_descriptors != 1 or device.rx_descriptor_wraps != 0 or
        tx_queue_enqueues != 11 or tx_queue_dequeues != 11 or
        rx_queue_enqueues != 10 or rx_queue_dequeues != 10 or
        queue_overflows != 0 or final_tx_pending != 0 or
        final_rx_pending != all_rx_descriptors_pending or
        tx_ready_mask != 0 or rx_ready_mask != 0)
    {
        return null;
    }

    return .{
        .tx = tx,
        .rx_descriptor_index = rx.descriptor_index,
        .rx_next_cursor = rx.next_cursor,
        .rx_frame_length = rx.frame_length,
        .rx_interrupt_count = rx.interrupt_count,
        .rx_interrupt_cause = rx.interrupt_cause,
        .identifier = parsed.identifier,
        .sequence = parsed.sequence,
        .ttl = parsed.ttl,
        .payload_length = parsed.payload_length,
        .tx_submissions = device.tx_submissions,
        .rx_deliveries = device.rx_deliveries,
        .tx_cursor_wraps = device.tx_cursor_wraps,
        .rx_cursor_wraps = device.rx_cursor_wraps,
        .tx_queue_enqueues = tx_queue_enqueues,
        .tx_queue_dequeues = tx_queue_dequeues,
        .rx_queue_enqueues = rx_queue_enqueues,
        .rx_queue_dequeues = rx_queue_dequeues,
        .queue_overflows = queue_overflows,
        .tx_pending_mask = final_tx_pending,
        .rx_pending_mask = final_rx_pending,
    };
}

fn verifySoftwarePacketQueue(device: *Device) ?SoftwarePacketQueueReport {
    var request = std.mem.zeroes([ethernet_minimum_frame_bytes]u8);
    buildIcmpEchoRequest(
        &request,
        device.local_mac,
        device.gateway_mac,
        device.local_ipv4,
        device.gateway_ipv4,
        queued_icmp_identifier,
        queued_icmp_sequence,
    );
    const tx = submitFrame(device, &request) orelse return null;
    if (!pumpReceive(device)) return null;
    const packet = dequeuePacket(device) orelse return null;
    const parsed = parseIcmpEchoReply(
        packet.bytes[0..packet.length],
        device.local_mac,
        device.gateway_mac,
        device.local_ipv4,
        device.gateway_ipv4,
        queued_icmp_identifier,
        queued_icmp_sequence,
    ) orelse return null;

    const tx_queue_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_queue_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_queue_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const rx_queue_dequeues = completionQueueDequeued(&rx_completion_queue);
    const completion_queue_overflows = completionQueueOverflow(&tx_completion_queue) +
        completionQueueOverflow(&rx_completion_queue);
    const final_tx_pending = @atomicLoad(u32, &tx_pending_mask, .acquire);
    const final_rx_pending = @atomicLoad(u32, &rx_pending_mask, .acquire);
    if (tx.descriptor_index != 3 or tx.next_cursor != 4 or
        packet.source_descriptor != 2 or device.rx_consumer != 3 or
        device.software_rx_queue.enqueued != 1 or
        device.software_rx_queue.dequeued != 1 or
        device.software_rx_queue.high_water != 1 or
        device.software_rx_queue.dropped != 0 or
        device.software_rx_queue.head != device.software_rx_queue.tail or
        device.rx_recycled_descriptors != 2 or
        tx_queue_enqueues != 12 or tx_queue_dequeues != 12 or
        rx_queue_enqueues != 11 or rx_queue_dequeues != 11 or
        completion_queue_overflows != 0 or final_tx_pending != 0 or
        final_rx_pending != all_rx_descriptors_pending or
        tx_ready_mask != 0 or rx_ready_mask != 0)
    {
        return null;
    }

    return .{
        .tx = tx,
        .dma_rx_descriptor = packet.source_descriptor,
        .rx_next_cursor = device.rx_consumer,
        .packet_length = packet.length,
        .identifier = parsed.identifier,
        .sequence = parsed.sequence,
        .ttl = parsed.ttl,
        .payload_length = parsed.payload_length,
        .queue_enqueued = device.software_rx_queue.enqueued,
        .queue_dequeued = device.software_rx_queue.dequeued,
        .queue_high_water = device.software_rx_queue.high_water,
        .queue_dropped = device.software_rx_queue.dropped,
        .device_tx_cursor = device.tx_producer,
        .device_rx_cursor = device.rx_consumer,
        .tx_queue_enqueues = tx_queue_enqueues,
        .tx_queue_dequeues = tx_queue_dequeues,
        .rx_queue_enqueues = rx_queue_enqueues,
        .rx_queue_dequeues = rx_queue_dequeues,
        .completion_queue_overflows = completion_queue_overflows,
        .tx_pending_mask = final_tx_pending,
        .rx_pending_mask = final_rx_pending,
    };
}

fn verifyProtocolDispatch(device: *Device) ?ProtocolDispatchReport {
    var request = std.mem.zeroes([ethernet_minimum_frame_bytes]u8);
    buildIcmpEchoRequest(
        &request,
        device.local_mac,
        device.gateway_mac,
        device.local_ipv4,
        device.gateway_ipv4,
        dispatched_icmp_identifier,
        dispatched_icmp_sequence,
    );
    const tx = submitFrame(device, &request) orelse return null;
    if (!pumpReceive(device)) return null;
    if (!dispatchNextPacket(device)) return null;
    const packet = dequeueIcmpPacket(device) orelse return null;
    const parsed = parseIcmpEchoReply(
        packet.bytes[0..packet.length],
        device.local_mac,
        device.gateway_mac,
        device.local_ipv4,
        device.gateway_ipv4,
        dispatched_icmp_identifier,
        dispatched_icmp_sequence,
    ) orelse return null;

    const tx_queue_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_queue_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_queue_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const rx_queue_dequeues = completionQueueDequeued(&rx_completion_queue);
    const completion_queue_overflows = completionQueueOverflow(&tx_completion_queue) +
        completionQueueOverflow(&rx_completion_queue);
    const final_tx_pending = @atomicLoad(u32, &tx_pending_mask, .acquire);
    const final_rx_pending = @atomicLoad(u32, &rx_pending_mask, .acquire);
    if (tx.descriptor_index != 4 or tx.next_cursor != 5 or
        packet.source_descriptor != 3 or device.rx_consumer != 4 or
        device.software_rx_queue.enqueued != 2 or
        device.software_rx_queue.dequeued != 2 or
        device.software_rx_queue.dropped != 0 or
        device.software_rx_queue.head != device.software_rx_queue.tail or
        device.packets_dispatched != 1 or
        device.arp_packets_dispatched != 0 or
        device.icmp_packets_dispatched != 1 or
        device.udp_packets_dispatched != 0 or
        device.unknown_packets_dropped != 0 or
        device.arp_rx_queue.enqueued != 0 or device.arp_rx_queue.dequeued != 0 or
        device.udp_rx_queue.enqueued != 0 or device.udp_rx_queue.dequeued != 0 or
        device.icmp_rx_queue.enqueued != 1 or
        device.icmp_rx_queue.dequeued != 1 or
        device.icmp_rx_queue.high_water != 1 or
        device.icmp_rx_queue.dropped != 0 or
        device.icmp_rx_queue.head != device.icmp_rx_queue.tail or
        device.rx_recycled_descriptors != 3 or
        tx_queue_enqueues != 13 or tx_queue_dequeues != 13 or
        rx_queue_enqueues != 12 or rx_queue_dequeues != 12 or
        completion_queue_overflows != 0 or final_tx_pending != 0 or
        final_rx_pending != all_rx_descriptors_pending or
        tx_ready_mask != 0 or rx_ready_mask != 0)
    {
        return null;
    }

    return .{
        .tx = tx,
        .dma_rx_descriptor = packet.source_descriptor,
        .device_tx_cursor = device.tx_producer,
        .device_rx_cursor = device.rx_consumer,
        .packet_length = packet.length,
        .identifier = parsed.identifier,
        .sequence = parsed.sequence,
        .ttl = parsed.ttl,
        .payload_length = parsed.payload_length,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .ingress_dropped = device.software_rx_queue.dropped,
        .packets_dispatched = device.packets_dispatched,
        .arp_dispatched = device.arp_packets_dispatched,
        .icmp_dispatched = device.icmp_packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
        .unknown_dropped = device.unknown_packets_dropped,
        .icmp_queue_enqueued = device.icmp_rx_queue.enqueued,
        .icmp_queue_dequeued = device.icmp_rx_queue.dequeued,
        .icmp_queue_high_water = device.icmp_rx_queue.high_water,
        .icmp_queue_dropped = device.icmp_rx_queue.dropped,
        .tx_queue_enqueues = tx_queue_enqueues,
        .tx_queue_dequeues = tx_queue_dequeues,
        .rx_queue_enqueues = rx_queue_enqueues,
        .rx_queue_dequeues = rx_queue_dequeues,
        .completion_queue_overflows = completion_queue_overflows,
        .tx_pending_mask = final_tx_pending,
        .rx_pending_mask = final_rx_pending,
    };
}

fn makeTxDescriptor(buffer_address: usize, length: u16) TxDescriptor {
    return .{
        .buffer_address = buffer_address,
        .length = length,
        .checksum_offset = 0,
        .command = 0x0B,
        .status = 0,
        .checksum_start = 0,
        .special = 0,
    };
}

fn validateRxDescriptor(descriptors: [*]volatile RxDescriptor, descriptor_index: usize) ?u16 {
    const descriptor = descriptors[descriptor_index];
    if ((descriptor.status & 0x03) != 0x03 or descriptor.errors != 0 or
        descriptor.length == 0 or descriptor.length > memory.page_size)
    {
        return null;
    }
    return descriptor.length;
}

fn recycleRxDescriptor(
    bar0: usize,
    descriptors: [*]volatile RxDescriptor,
    descriptor_index: usize,
    recycle_count: *u16,
    wrap_count: *u16,
    previous_descriptor_index: *?usize,
) bool {
    if (descriptor_index >= ring_descriptor_count) return false;
    const buffer_address = descriptors[descriptor_index].buffer_address;
    if (buffer_address == 0) return false;
    descriptors[descriptor_index] = .{
        .buffer_address = buffer_address,
        .length = 0,
        .checksum = 0,
        .status = 0,
        .errors = 0,
        .special = 0,
    };
    if (!armRxDescriptor(descriptor_index)) return false;
    zigos_memory_fence();
    write32(bar0, rdt_offset, descriptor_index);
    _ = read32(bar0, status_offset);
    if (read32(bar0, rdt_offset) != descriptor_index) return false;
    if (previous_descriptor_index.*) |previous| {
        if (descriptor_index < previous) wrap_count.* +|= 1;
    }
    previous_descriptor_index.* = descriptor_index;
    recycle_count.* +|= 1;
    return true;
}

const MsixSetup = struct {
    capability_offset: u8,
    control: u16,
    table_address: usize,
    vector_count: u16,
    mapping_table_pages: u64,
};

fn configureMsix(
    controller: *Controller,
    allocator: *memory.FrameAllocator,
    target_apic_id: u8,
) ?MsixSetup {
    const descriptor = pci.inspectMsix(controller.pci_function) orelse return null;
    if (descriptor.table_size <= msix_table_index) return null;
    const table_bar = pci.decodeMemoryBar(controller.pci_function, descriptor.table_bar_index) orelse return null;
    const entry_offset = @as(u64, descriptor.table_offset) +
        @as(u64, msix_table_index) * @sizeOf(MsixTableEntry);
    if (table_bar > std.math.maxInt(u64) - entry_offset) return null;
    const table_address_u64 = table_bar + entry_offset;
    if (table_address_u64 > std.math.maxInt(usize)) return null;

    var mapping_table_pages: u64 = 0;
    if (!paging.isIdentityRangeMapped(table_address_u64, @sizeOf(MsixTableEntry))) {
        const mapping = paging.mapIdentityMmio(
            allocator,
            table_address_u64,
            @sizeOf(MsixTableEntry),
        ) orelse return null;
        mapping_table_pages = mapping.table_pages;
    }

    const control_offset = @as(usize, descriptor.capability_offset) + 2;
    const masked_control = (descriptor.control | msix_function_mask) & ~msix_enable;
    pci.writeConfiguration16(controller.pci_function, control_offset, masked_control);
    const masked_readback = pci.readConfiguration16(controller.pci_function, control_offset);
    if ((masked_readback & (msix_enable | msix_function_mask)) != msix_function_mask) return null;

    const table_address: usize = @intCast(table_address_u64);
    const entry: *volatile MsixTableEntry = @ptrFromInt(table_address);
    entry.vector_control = msix_vector_mask;
    zigos_memory_fence();
    entry.message_address_low = msi_message_address_base | (@as(u32, target_apic_id) << 12);
    entry.message_address_high = 0;
    entry.message_data = interrupt_vector;
    zigos_memory_fence();
    entry.vector_control = 0;
    zigos_memory_fence();

    const enabled_control = (descriptor.control | msix_enable) & ~msix_function_mask;
    pci.writeConfiguration16(controller.pci_function, control_offset, enabled_control);
    const enabled_readback = pci.readConfiguration16(controller.pci_function, control_offset);
    if ((enabled_readback & (msix_enable | msix_function_mask)) != msix_enable) return null;
    if (entry.message_address_low != (msi_message_address_base | (@as(u32, target_apic_id) << 12)) or
        entry.message_address_high != 0 or entry.message_data != interrupt_vector or
        (entry.vector_control & msix_vector_mask) != 0)
    {
        return null;
    }

    var command = pci.readConfiguration16(controller.pci_function, 0x04);
    command |= pci_command_memory_space | pci_command_bus_master | pci_command_interrupt_disable;
    pci.writeConfiguration16(controller.pci_function, 0x04, command);
    command = pci.readConfiguration16(controller.pci_function, 0x04);
    if ((command & pci_command_interrupt_disable) == 0) return null;
    controller.pci_command = command;

    return .{
        .capability_offset = descriptor.capability_offset,
        .control = enabled_readback,
        .table_address = table_address,
        .vector_count = descriptor.table_size,
        .mapping_table_pages = mapping_table_pages,
    };
}

fn programReceiveRing(bar0: usize, ring_address: usize) void {
    write32(bar0, rdbal_offset, @as(u32, @truncate(ring_address)));
    write32(bar0, rdbah_offset, @as(u32, @truncate(@as(u64, ring_address) >> 32)));
    write32(bar0, rdlen_offset, ring_bytes);
    write32(bar0, rdh_offset, 0);
    write32(bar0, rdt_offset, ring_descriptor_count - 1);
    _ = read32(bar0, status_offset);
}

fn programTransmitRing(bar0: usize, ring_address: usize) void {
    write32(bar0, tdbal_offset, @as(u32, @truncate(ring_address)));
    write32(bar0, tdbah_offset, @as(u32, @truncate(@as(u64, ring_address) >> 32)));
    write32(bar0, tdlen_offset, ring_bytes);
    write32(bar0, tdh_offset, 0);
    write32(bar0, tdt_offset, 0);
    _ = read32(bar0, status_offset);
}

fn waitForTx(descriptors: [*]volatile TxDescriptor, descriptor_index: usize, _: u64, target_apic_id: u8) bool {
    const local_target = apic.currentId() == target_apic_id;
    if (local_target) zigos_enable_interrupts();
    var completed = false;
    var iteration: usize = 0;
    while (iteration < maximum_poll_iterations) : (iteration += 1) {
        if (consumeCompletion(&tx_completion_queue, &tx_ready_mask, descriptor_index) and
            (descriptors[descriptor_index].status & 1) != 0)
        {
            completed = true;
            break;
        }
        zigos_cpu_relax();
    }
    if (local_target) zigos_disable_interrupts();
    return completed;
}

fn waitForRx(descriptors: [*]volatile RxDescriptor, descriptor_index: usize, _: u64, target_apic_id: u8) bool {
    const local_target = apic.currentId() == target_apic_id;
    if (local_target) zigos_enable_interrupts();
    var completed = false;
    var iteration: usize = 0;
    while (iteration < maximum_poll_iterations) : (iteration += 1) {
        if (consumeCompletion(&rx_completion_queue, &rx_ready_mask, descriptor_index) and
            (descriptors[descriptor_index].status & 1) != 0)
        {
            completed = true;
            break;
        }
        zigos_cpu_relax();
    }
    if (local_target) zigos_disable_interrupts();
    return completed;
}

const ParsedArp = struct {
    gateway_mac_address: [6]u8,
    opcode: u16,
    sender_ipv4: [4]u8,
    target_ipv4: [4]u8,
};

fn parseArpReply(
    frame: []const u8,
    local_mac: [6]u8,
    local_ipv4: [4]u8,
    gateway_ipv4: [4]u8,
) ?ParsedArp {
    if (frame.len < arp_payload_bytes) return null;
    if (!std.mem.eql(u8, frame[0..6], &local_mac)) return null;
    if (readNetwork16(frame, 12) != ether_type_arp) return null;
    if (readNetwork16(frame, 14) != arp_hardware_ethernet or
        readNetwork16(frame, 16) != arp_protocol_ipv4 or frame[18] != 6 or frame[19] != 4)
    {
        return null;
    }
    const opcode = readNetwork16(frame, 20);
    if (opcode != arp_reply) return null;
    if (!std.mem.eql(u8, frame[28..32], &gateway_ipv4) or
        !std.mem.eql(u8, frame[32..38], &local_mac) or
        !std.mem.eql(u8, frame[38..42], &local_ipv4))
    {
        return null;
    }
    if (!std.mem.eql(u8, frame[6..12], frame[22..28])) return null;
    var gateway_mac_address: [6]u8 = undefined;
    @memcpy(&gateway_mac_address, frame[6..12]);
    var sender_ipv4: [4]u8 = undefined;
    @memcpy(&sender_ipv4, frame[28..32]);
    var target_ipv4: [4]u8 = undefined;
    @memcpy(&target_ipv4, frame[38..42]);
    return .{
        .gateway_mac_address = gateway_mac_address,
        .opcode = opcode,
        .sender_ipv4 = sender_ipv4,
        .target_ipv4 = target_ipv4,
    };
}

fn buildArpRequest(
    frame: []u8,
    local_mac: [6]u8,
    local_ipv4: [4]u8,
    gateway_ipv4: [4]u8,
) void {
    @memset(frame, 0);
    @memset(frame[0..6], 0xFF);
    @memcpy(frame[6..12], &local_mac);
    writeNetwork16(frame, 12, ether_type_arp);
    writeNetwork16(frame, 14, arp_hardware_ethernet);
    writeNetwork16(frame, 16, arp_protocol_ipv4);
    frame[18] = 6;
    frame[19] = 4;
    writeNetwork16(frame, 20, arp_request);
    @memcpy(frame[22..28], &local_mac);
    @memcpy(frame[28..32], &local_ipv4);
    @memset(frame[32..38], 0);
    @memcpy(frame[38..42], &gateway_ipv4);
}

const ParsedIcmp = struct {
    identifier: u16,
    sequence: u16,
    ttl: u8,
    payload_length: u16,
};

fn buildIcmpEchoRequest(
    frame: []u8,
    local_mac: [6]u8,
    gateway_mac: [6]u8,
    local_ipv4: [4]u8,
    gateway_ipv4: [4]u8,
    identifier: u16,
    sequence: u16,
) void {
    @memset(frame, 0);
    @memcpy(frame[0..6], &gateway_mac);
    @memcpy(frame[6..12], &local_mac);
    writeNetwork16(frame, 12, ether_type_ipv4);

    const ip_offset: usize = 14;
    frame[ip_offset] = 0x45;
    frame[ip_offset + 1] = 0;
    writeNetwork16(frame, ip_offset + 2, icmp_ipv4_total_bytes);
    writeNetwork16(frame, ip_offset + 4, identifier);
    writeNetwork16(frame, ip_offset + 6, ipv4_dont_fragment);
    frame[ip_offset + 8] = 64;
    frame[ip_offset + 9] = ipv4_protocol_icmp;
    writeNetwork16(frame, ip_offset + 10, 0);
    @memcpy(frame[ip_offset + 12 .. ip_offset + 16], &local_ipv4);
    @memcpy(frame[ip_offset + 16 .. ip_offset + 20], &gateway_ipv4);
    const ip_checksum = internetChecksum(frame[ip_offset .. ip_offset + ipv4_header_bytes]);
    writeNetwork16(frame, ip_offset + 10, ip_checksum);

    const icmp_offset = ip_offset + ipv4_header_bytes;
    frame[icmp_offset] = icmp_echo_request;
    frame[icmp_offset + 1] = 0;
    writeNetwork16(frame, icmp_offset + 2, 0);
    writeNetwork16(frame, icmp_offset + 4, identifier);
    writeNetwork16(frame, icmp_offset + 6, sequence);
    @memcpy(frame[icmp_offset + icmp_header_bytes .. icmp_offset + icmp_header_bytes + icmp_payload.len], icmp_payload);
    const icmp_checksum = internetChecksum(frame[icmp_offset .. icmp_offset + icmp_header_bytes + icmp_payload.len]);
    writeNetwork16(frame, icmp_offset + 2, icmp_checksum);
}

fn parseIcmpEchoReply(
    frame: []const u8,
    local_mac: [6]u8,
    gateway_mac: [6]u8,
    local_ipv4: [4]u8,
    gateway_ipv4: [4]u8,
    expected_identifier: u16,
    expected_sequence: u16,
) ?ParsedIcmp {
    if (frame.len < 14 + ipv4_header_bytes + icmp_header_bytes) return null;
    if (!std.mem.eql(u8, frame[0..6], &local_mac) or
        !std.mem.eql(u8, frame[6..12], &gateway_mac) or
        readNetwork16(frame, 12) != ether_type_ipv4)
    {
        return null;
    }

    const ip_offset: usize = 14;
    if ((frame[ip_offset] >> 4) != 4) return null;
    const ihl_bytes: usize = @as(usize, frame[ip_offset] & 0x0F) * 4;
    if (ihl_bytes < ipv4_header_bytes or ip_offset + ihl_bytes > frame.len) return null;
    const total_length: usize = readNetwork16(frame, ip_offset + 2);
    if (total_length < ihl_bytes + icmp_header_bytes or ip_offset + total_length > frame.len) return null;
    if (frame[ip_offset + 9] != ipv4_protocol_icmp or frame[ip_offset + 8] == 0) return null;
    if ((readNetwork16(frame, ip_offset + 6) & 0x1FFF) != 0) return null;
    if (!std.mem.eql(u8, frame[ip_offset + 12 .. ip_offset + 16], &gateway_ipv4) or
        !std.mem.eql(u8, frame[ip_offset + 16 .. ip_offset + 20], &local_ipv4))
    {
        return null;
    }
    if (internetChecksum(frame[ip_offset .. ip_offset + ihl_bytes]) != 0) return null;

    const icmp_offset = ip_offset + ihl_bytes;
    const icmp_length = total_length - ihl_bytes;
    if (frame[icmp_offset] != icmp_echo_reply or frame[icmp_offset + 1] != 0) return null;
    if (internetChecksum(frame[icmp_offset .. icmp_offset + icmp_length]) != 0) return null;
    const identifier = readNetwork16(frame, icmp_offset + 4);
    const sequence = readNetwork16(frame, icmp_offset + 6);
    if (identifier != expected_identifier or sequence != expected_sequence) return null;
    const payload = frame[icmp_offset + icmp_header_bytes .. icmp_offset + icmp_length];
    if (!std.mem.eql(u8, payload, icmp_payload)) return null;

    return .{
        .identifier = identifier,
        .sequence = sequence,
        .ttl = frame[ip_offset + 8],
        .payload_length = @intCast(payload.len),
    };
}

fn internetChecksum(bytes: []const u8) u16 {
    var sum: u32 = 0;
    var index: usize = 0;
    while (index + 1 < bytes.len) : (index += 2) {
        sum += (@as(u32, bytes[index]) << 8) | bytes[index + 1];
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    if (index < bytes.len) {
        sum += @as(u32, bytes[index]) << 8;
    }
    while ((sum >> 16) != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return @truncate(~sum);
}

fn readMacAddress(bar0: usize) ?[6]u8 {
    const ral0 = read32(bar0, ral0_offset);
    const rah0 = read32(bar0, rah0_offset);
    if ((rah0 & rah_address_valid) == 0) return null;
    const mac = [6]u8{
        @truncate(ral0),
        @truncate(ral0 >> 8),
        @truncate(ral0 >> 16),
        @truncate(ral0 >> 24),
        @truncate(rah0),
        @truncate(rah0 >> 8),
    };
    var all_zero = true;
    var all_ff = true;
    for (mac) |octet| {
        all_zero = all_zero and octet == 0;
        all_ff = all_ff and octet == 0xFF;
    }
    if (all_zero or all_ff) return null;
    return mac;
}

fn writeMacAddress(bar0: usize, mac: [6]u8) void {
    const low = @as(u32, mac[0]) |
        (@as(u32, mac[1]) << 8) |
        (@as(u32, mac[2]) << 16) |
        (@as(u32, mac[3]) << 24);
    const high = @as(u32, mac[4]) | (@as(u32, mac[5]) << 8) | rah_address_valid;
    write32(bar0, ral0_offset, low);
    write32(bar0, rah0_offset, high);
}

fn decodeSpeed(status: u32) u16 {
    return switch (status & status_speed_mask) {
        0 => 10,
        1 << 6 => 100,
        2 << 6, 3 << 6 => 1000,
        else => 0,
    };
}

fn disableInterrupts(bar0: usize) void {
    write32(bar0, imc_offset, 0xFFFF_FFFF);
    _ = read32(bar0, icr_offset);
}

pub fn interruptCount() u64 {
    return @atomicLoad(u64, &total_interrupt_count, .acquire);
}

pub fn txInterruptCount() u64 {
    return @atomicLoad(u64, &tx_interrupt_count, .acquire);
}

pub fn rxInterruptCount() u64 {
    return @atomicLoad(u64, &rx_interrupt_count, .acquire);
}

export fn zigos_e1000e_interrupt_handler() callconv(cc) void {
    const bar0 = active_bar0;
    if (!interrupts_enabled or bar0 == 0) {
        apic.acknowledgeInterrupt();
        return;
    }
    const cause = read32(bar0, icr_offset);
    if ((cause & interrupt_txq0) != 0) {
        @atomicStore(u32, &last_tx_cause, cause, .release);
        _ = @atomicRmw(u64, &tx_interrupt_count, .Add, 1, .acq_rel);
        scanTxCompletions();
    }
    if ((cause & interrupt_rxq0) != 0) {
        @atomicStore(u32, &last_rx_cause, cause, .release);
        _ = @atomicRmw(u64, &rx_interrupt_count, .Add, 1, .acq_rel);
        scanRxCompletions();
    }
    if (cause != 0) _ = @atomicRmw(u64, &total_interrupt_count, .Add, 1, .acq_rel);
    apic.acknowledgeInterrupt();
}

fn resetCompletionQueue(queue: *CompletionQueue) void {
    @memset(queue.entries[0..], 0);
    @atomicStore(u32, &queue.head, 0, .release);
    @atomicStore(u32, &queue.tail, 0, .release);
    @atomicStore(u64, &queue.enqueued, 0, .release);
    @atomicStore(u64, &queue.dequeued, 0, .release);
    @atomicStore(u32, &queue.high_water, 0, .release);
    @atomicStore(u64, &queue.overflow, 0, .release);
}

fn enqueueCompletion(queue: *CompletionQueue, descriptor_index: usize) void {
    if (descriptor_index >= ring_descriptor_count) {
        _ = @atomicRmw(u64, &queue.overflow, .Add, 1, .acq_rel);
        return;
    }
    const head = @atomicLoad(u32, &queue.head, .acquire);
    const tail = @atomicLoad(u32, &queue.tail, .acquire);
    const next: u32 = @intCast((head + 1) % completion_queue_capacity);
    if (next == tail) {
        _ = @atomicRmw(u64, &queue.overflow, .Add, 1, .acq_rel);
        return;
    }
    queue.entries[head] = @intCast(descriptor_index);
    @atomicStore(u32, &queue.head, next, .release);
    _ = @atomicRmw(u64, &queue.enqueued, .Add, 1, .acq_rel);
    const depth: u32 = @intCast((next + completion_queue_capacity - tail) % completion_queue_capacity);
    const high_water = @atomicLoad(u32, &queue.high_water, .acquire);
    if (depth > high_water) @atomicStore(u32, &queue.high_water, depth, .release);
}

fn popCompletion(queue: *CompletionQueue) ?u8 {
    const tail = @atomicLoad(u32, &queue.tail, .acquire);
    const head = @atomicLoad(u32, &queue.head, .acquire);
    if (tail == head) return null;
    const descriptor_index = queue.entries[tail];
    const next: u32 = @intCast((tail + 1) % completion_queue_capacity);
    @atomicStore(u32, &queue.tail, next, .release);
    _ = @atomicRmw(u64, &queue.dequeued, .Add, 1, .acq_rel);
    return descriptor_index;
}

fn consumeCompletion(queue: *CompletionQueue, ready_mask: *u32, descriptor_index: usize) bool {
    if (descriptor_index >= ring_descriptor_count) return false;
    const bit = descriptorBit(descriptor_index);
    if ((ready_mask.* & bit) != 0) {
        ready_mask.* &= ~bit;
        return true;
    }
    while (popCompletion(queue)) |completed_index| {
        const completed_bit = descriptorBit(completed_index);
        if (completed_bit == bit) return true;
        ready_mask.* |= completed_bit;
    }
    return false;
}

fn armTxDescriptor(descriptor_index: usize) bool {
    return armDescriptor(&tx_pending_mask, descriptor_index);
}

fn armRxDescriptor(descriptor_index: usize) bool {
    return armDescriptor(&rx_pending_mask, descriptor_index);
}

fn armDescriptor(pending_mask: *u32, descriptor_index: usize) bool {
    if (descriptor_index >= ring_descriptor_count) return false;
    const bit = descriptorBit(descriptor_index);
    const previous = @atomicRmw(u32, pending_mask, .Or, bit, .acq_rel);
    return (previous & bit) == 0;
}

fn scanTxCompletions() void {
    const address = active_tx_descriptors;
    if (address == 0) return;
    const descriptors: [*]volatile TxDescriptor = @ptrFromInt(address);
    for (0..ring_descriptor_count) |descriptor_index| {
        if ((descriptors[descriptor_index].status & 1) == 0) continue;
        completePendingDescriptor(&tx_pending_mask, &tx_completion_queue, descriptor_index);
    }
}

fn scanRxCompletions() void {
    const address = active_rx_descriptors;
    if (address == 0) return;
    const descriptors: [*]volatile RxDescriptor = @ptrFromInt(address);
    for (0..ring_descriptor_count) |descriptor_index| {
        if ((descriptors[descriptor_index].status & 1) == 0) continue;
        completePendingDescriptor(&rx_pending_mask, &rx_completion_queue, descriptor_index);
    }
}

fn completePendingDescriptor(
    pending_mask: *u32,
    queue: *CompletionQueue,
    descriptor_index: usize,
) void {
    const bit = descriptorBit(descriptor_index);
    const previous = @atomicRmw(u32, pending_mask, .And, ~bit, .acq_rel);
    if ((previous & bit) != 0) enqueueCompletion(queue, descriptor_index);
}

fn descriptorBit(descriptor_index: usize) u32 {
    return @as(u32, 1) << @intCast(descriptor_index);
}

fn completionQueueEnqueued(queue: *CompletionQueue) u64 {
    return @atomicLoad(u64, &queue.enqueued, .acquire);
}

fn completionQueueDequeued(queue: *CompletionQueue) u64 {
    return @atomicLoad(u64, &queue.dequeued, .acquire);
}

fn completionQueueHighWater(queue: *CompletionQueue) u32 {
    return @atomicLoad(u32, &queue.high_water, .acquire);
}

fn completionQueueOverflow(queue: *CompletionQueue) u64 {
    return @atomicLoad(u64, &queue.overflow, .acquire);
}

fn waitRegisterBits(base: usize, offset: usize, mask: u32, set: bool) bool {
    var iteration: usize = 0;
    while (iteration < maximum_poll_iterations) : (iteration += 1) {
        if (((read32(base, offset) & mask) != 0) == set) return true;
        zigos_cpu_relax();
    }
    return false;
}

fn writeNetwork16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value >> 8);
    bytes[offset + 1] = @truncate(value);
}

fn readNetwork16(bytes: []const u8, offset: usize) u16 {
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

fn clearPage(address: usize) void {
    const bytes = @as([*]u8, @ptrFromInt(address))[0..memory.page_size];
    @memset(bytes, 0);
}

fn read32(base: usize, offset: usize) u32 {
    const register: *volatile u32 = @ptrFromInt(base + offset);
    return register.*;
}

fn write32(base: usize, offset: usize, value: anytype) void {
    const register: *volatile u32 = @ptrFromInt(base + offset);
    register.* = @intCast(value);
}

comptime {
    if (@sizeOf(RxDescriptor) != 16) @compileError("e1000e RX descriptors must be 16 bytes");
    if (@sizeOf(TxDescriptor) != 16) @compileError("e1000e TX descriptors must be 16 bytes");
    if (@sizeOf(MsixTableEntry) != 16) @compileError("MSI-X table entries must be 16 bytes");
    if (ring_bytes != 128) @compileError("e1000e test rings must be exactly 128 bytes");
    if (completion_queue_capacity < ring_descriptor_count * 2) @compileError("e1000e completion queues are too small");
    if (completion_queue_capacity > std.math.maxInt(u8)) @compileError("e1000e completion queue indices must fit in u8");
    if (software_packet_queue_capacity < 2) @compileError("e1000e software packet queue is too small");
    if (maximum_software_packet_bytes < 1518) @compileError("e1000e software packet entries must hold a full Ethernet frame");
    if (icmp_payload.len != 16) @compileError("ICMP payload must remain deterministic");
    if (icmp_ipv4_total_bytes != 44) @compileError("ICMP IPv4 packet must remain 44 bytes");
    if (icmp_ethernet_frame_bytes != 58) @compileError("ICMP Ethernet payload must fit one padded frame");
}
