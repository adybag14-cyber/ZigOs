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
const udp_endpoint_capacity: usize = 4;
const maximum_software_packet_bytes: usize = 2048;
const maximum_ethernet_frame_bytes: usize = 1518;
pub const maximum_udp_payload_bytes: usize = maximum_ethernet_frame_bytes - 14 - ipv4_header_bytes - 8;
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
const dispatched_tftp_client_port: u16 = 40_001;
const dispatched_tftp_identification: u16 = 0x5A60;
const endpoint_tftp_client_port: u16 = 40_002;
const endpoint_tftp_identification: u16 = 0x5A70;
const unmatched_udp_port: u16 = 49_999;
const lifecycle_udp_port: u16 = 41_000;
const lifecycle_second_udp_port: u16 = 41_001;
const lifecycle_overflow_udp_port: u16 = 41_002;
const lifecycle_reuse_udp_port: u16 = 41_003;
const lifecycle_source_port: u16 = 12_345;
const peer_filter_udp_port: u16 = 42_000;
const peer_filter_source_port: u16 = 23_456;
const peer_filter_alternate_port: u16 = 23_457;
const ephemeral_udp_port_first: u16 = 49_152;
const ephemeral_udp_port_last: u16 = 65_535;
const ephemeral_udp_port_count: u32 = @as(u32, ephemeral_udp_port_last) - ephemeral_udp_port_first + 1;
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

pub const PacketDispatchResult = enum(u8) {
    empty,
    routed,
    dropped,
};

pub const PacketDispatchBatch = struct {
    examined: u16,
    routed: u16,
    dropped: u16,
    remaining: u16,
};

pub const UdpPeer = struct {
    mac: [6]u8,
    ipv4: [4]u8,
    port: u16,
};

pub const UdpEndpoint = struct {
    active: bool,
    port: u16,
    generation: u32,
    peer_bound: bool,
    peer: UdpPeer,
    queue: SoftwarePacketQueue,
};

pub const UdpSocket = struct {
    endpoint_index: u16,
    generation: u32,
    local_port: u16,
};

pub const UdpSendOptions = struct {
    destination_mac: [6]u8,
    destination_ipv4: [4]u8,
    destination_port: u16,
    identification: u16,
    ttl: u8 = 64,
    payload: []const u8,
};

pub const ConnectedUdpSendOptions = struct {
    identification: u16,
    ttl: u8 = 64,
    payload: []const u8,
};

pub const UdpTransmitResult = struct {
    completion: TxCompletion,
    identification: u16,
};

pub const UdpReadySockets = struct {
    sockets: [udp_endpoint_capacity]UdpSocket,
    count: u8,
    total_pending: u16,
};

pub const UdpServiceCycle = struct {
    dispatch: PacketDispatchBatch,
    ready: UdpReadySockets,
};

pub const UdpEndpointPoll = struct {
    active_mask: u8,
    readable_mask: u8,
    connected_mask: u8,
    active_count: u8,
    readable_count: u8,
    connected_count: u8,
    total_pending: u16,
    max_pending: u16,
};

pub const UdpSocketStatus = struct {
    local_port: u16,
    generation: u32,
    connected: bool,
    peer_port: u16,
    pending_packets: u16,
    usable_capacity: u16,
    enqueued: u64,
    dequeued: u64,
    dropped: u64,
    high_water: u16,
};

pub const ReceivedUdpDatagram = struct {
    packet: Packet,
    source_mac: [6]u8,
    destination_mac: [6]u8,
    source_ipv4: [4]u8,
    destination_ipv4: [4]u8,
    source_port: u16,
    destination_port: u16,
    ttl: u8,
    identification: u16,
    udp_checksum_present: bool,
    payload_offset: u16,
    payload_length: u16,

    pub fn payload(self: *const ReceivedUdpDatagram) []const u8 {
        const start: usize = self.payload_offset;
        return self.packet.bytes[start .. start + self.payload_length];
    }
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
    udp_endpoints: [udp_endpoint_capacity]UdpEndpoint,
    udp_endpoint_count: u16,
    next_udp_generation: u32,
    next_ephemeral_udp_port: u16,
    next_udp_ready_index: u8,
    next_udp_identification: u16,
    unmatched_udp_packets_dropped: u64,
    invalid_udp_packets_dropped: u64,
    peer_mismatch_udp_packets_dropped: u64,
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

pub const UdpTftpDispatchReport = struct {
    rrq: TxCompletion,
    data_descriptors: [tftp.expected_block_count]u16,
    acknowledgement_descriptors: [tftp.expected_block_count]u16,
    data_frame_lengths: [tftp.expected_block_count]u16,
    acknowledgement_frame_lengths: [tftp.expected_block_count]u16,
    block_count: u16,
    payload_length: u32,
    payload_fnv1a64: u64,
    server_port: u16,
    reply_ttl: u8,
    udp_checksum_present: bool,
    device_tx_cursor: u16,
    device_rx_cursor: u16,
    tx_cursor_wraps: u16,
    rx_cursor_wraps: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    ingress_dropped: u64,
    packets_dispatched: u64,
    arp_dispatched: u64,
    icmp_dispatched: u64,
    udp_dispatched: u64,
    unknown_dropped: u64,
    udp_queue_enqueued: u64,
    udp_queue_dequeued: u64,
    udp_queue_high_water: u16,
    udp_queue_dropped: u64,
    tx_queue_enqueues: u64,
    tx_queue_dequeues: u64,
    rx_queue_enqueues: u64,
    rx_queue_dequeues: u64,
    completion_queue_overflows: u64,
    tx_pending_mask: u32,
    rx_pending_mask: u32,
};

pub const UdpEndpointDemuxReport = struct {
    endpoint_index: u16,
    endpoint_port: u16,
    socket_generation: u32,
    registered_endpoints: u16,
    structured_receives: u16,
    connected_sends: u16,
    connected_peer_port: u16,
    connected_peer_bound: bool,
    unmatched_port: u16,
    unmatched_dropped: u64,
    rrq: TxCompletion,
    data_descriptors: [tftp.expected_block_count]u16,
    acknowledgement_descriptors: [tftp.expected_block_count]u16,
    data_frame_lengths: [tftp.expected_block_count]u16,
    acknowledgement_frame_lengths: [tftp.expected_block_count]u16,
    block_count: u16,
    payload_length: u32,
    payload_fnv1a64: u64,
    server_port: u16,
    reply_ttl: u8,
    udp_checksum_present: bool,
    device_tx_cursor: u16,
    device_rx_cursor: u16,
    tx_cursor_wraps: u16,
    rx_cursor_wraps: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    ingress_dropped: u64,
    packets_dispatched: u64,
    arp_dispatched: u64,
    icmp_dispatched: u64,
    udp_dispatched: u64,
    unknown_dropped: u64,
    endpoint_queue_enqueued: u64,
    endpoint_queue_dequeued: u64,
    endpoint_queue_high_water: u16,
    endpoint_queue_dropped: u64,
    tx_queue_enqueues: u64,
    tx_queue_dequeues: u64,
    rx_queue_enqueues: u64,
    rx_queue_dequeues: u64,
    completion_queue_overflows: u64,
    tx_pending_mask: u32,
    rx_pending_mask: u32,
};

pub const UdpTransmitWrapReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    identifications: [2]u16,
    descriptors: [2]u16,
    next_cursors: [2]u16,
    frame_lengths: [2]u16,
    wraps_before: u16,
    wraps_after: u16,
    wrap_delta: u16,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    completion_overflow: u64,
    tx_pending_mask: u32,
    rx_pending_mask: u32,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
};

pub const UdpPayloadBoundaryReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    maximum_payload_bytes: u16,
    oversized_payload_bytes: u16,
    oversized_rejected: bool,
    cursor_preserved_on_rejection: bool,
    maximum_identification: u16,
    maximum_descriptor: u16,
    maximum_next_cursor: u16,
    maximum_frame_length: u16,
    empty_identification: u16,
    empty_descriptor: u16,
    empty_next_cursor: u16,
    empty_frame_length: u16,
    final_identification_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    completion_overflow: u64,
    final_tx_cursor: u16,
    tx_wraps_unchanged: bool,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
};

pub const UdpAutomaticIdentificationReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    peer_port: u16,
    unconnected_rejected: bool,
    zero_ttl_rejected: bool,
    cursor_preserved_on_failure: bool,
    identifications: [4]u16,
    descriptors: [4]u16,
    next_cursors: [4]u16,
    frame_lengths: [4]u16,
    final_identification_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    completion_overflow: u64,
    tx_pending_mask: u32,
    rx_pending_mask: u32,
    final_tx_cursor: u16,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
};

pub const UdpFairServiceReport = struct {
    first_slot: u16,
    first_generation: u32,
    first_port: u16,
    second_slot: u16,
    second_generation: u32,
    second_port: u16,
    initial_dispatch_examined: u16,
    initial_dispatch_routed: u16,
    initial_ready_count: u8,
    initial_total_pending: u16,
    selection_slots: [4]u16,
    selection_generations: [4]u32,
    selection_payload_indexes: [4]u8,
    ready_cursors_after: [4]u8,
    empty_ready_count: u8,
    final_ready_cursor: u8,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const UdpServiceCycleReport = struct {
    first_slot: u16,
    first_generation: u32,
    first_port: u16,
    second_slot: u16,
    second_generation: u32,
    second_port: u16,
    first_examined: u16,
    first_routed: u16,
    first_dropped: u16,
    first_remaining: u16,
    first_ready_count: u8,
    first_total_pending: u16,
    second_examined: u16,
    second_routed: u16,
    second_dropped: u16,
    second_remaining: u16,
    second_ready_count: u8,
    second_total_pending: u16,
    drained_examined: u16,
    drained_ready_count: u8,
    delivered_datagrams: u16,
    stale_first_rejected: bool,
    stale_second_rejected: bool,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
    unmatched_dropped: u64,
    invalid_udp_dropped: u64,
};

pub const UdpEndpointPollReport = struct {
    first_slot: u16,
    first_generation: u32,
    first_port: u16,
    second_slot: u16,
    second_generation: u32,
    second_port: u16,
    initial_active_mask: u8,
    initial_readable_mask: u8,
    initial_connected_mask: u8,
    initial_total_pending: u16,
    initial_max_pending: u16,
    partial_readable_mask: u8,
    partial_total_pending: u16,
    drained_readable_mask: u8,
    drained_total_pending: u16,
    final_active_mask: u8,
    final_readable_mask: u8,
    final_connected_mask: u8,
    final_total_pending: u16,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const UdpDispatchBatchReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    initial_ingress_depth: u16,
    first_examined: u16,
    first_routed: u16,
    first_dropped: u16,
    first_remaining: u16,
    second_examined: u16,
    second_routed: u16,
    second_dropped: u16,
    second_remaining: u16,
    final_examined: u16,
    final_routed: u16,
    final_dropped: u16,
    final_remaining: u16,
    empty_examined: u16,
    empty_remaining: u16,
    delivered_datagrams: u16,
    endpoint_high_water: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
    unmatched_dropped: u64,
    invalid_udp_dropped: u64,
    final_registered_endpoints: u16,
};

pub const UdpSocketQueueReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    connected: bool,
    peer_port: u16,
    pending_before_discard: u16,
    readable_before_discard: bool,
    disconnect_while_pending_rejected: bool,
    discarded_packets: u16,
    pending_after_discard: u16,
    readable_after_discard: bool,
    queue_enqueued: u64,
    queue_dequeued: u64,
    queue_high_water: u16,
    queue_dropped: u64,
    stale_status_rejected: bool,
    stale_discard_rejected: bool,
    final_registered_endpoints: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const UdpEphemeralPortReport = struct {
    range_first: u16,
    range_last: u16,
    first_slot: u16,
    first_generation: u32,
    first_port: u16,
    second_slot: u16,
    second_generation: u32,
    second_port: u16,
    full_table_rejected: bool,
    collision_skipped: bool,
    collision_slot: u16,
    collision_generation: u32,
    collision_port: u16,
    wrap_slot: u16,
    wrap_generation: u32,
    wrap_port: u16,
    post_wrap_slot: u16,
    post_wrap_generation: u32,
    post_wrap_port: u16,
    final_cursor: u16,
    final_registered_endpoints: u16,
};

pub const UdpPeerFilterReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    peer_port: u16,
    peer_bound: bool,
    correct_peer_accepted: bool,
    wrong_mac_rejected: bool,
    wrong_ipv4_rejected: bool,
    wrong_port_rejected: bool,
    invalid_checksum_rejected: bool,
    wildcard_after_disconnect: bool,
    endpoint_enqueued: u64,
    endpoint_dequeued: u64,
    endpoint_high_water: u16,
    endpoint_dropped: u64,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
    unmatched_dropped: u64,
    invalid_udp_dropped: u64,
    peer_mismatch_dropped: u64,
    final_registered_endpoints: u16,
};

pub const UdpEndpointLifecycleReport = struct {
    table_capacity: u16,
    usable_queue_capacity: u16,
    duplicate_slot: u16,
    duplicate_handle_match: bool,
    full_table_rejected: bool,
    queue_slot: u16,
    queue_generation: u32,
    queue_enqueued: u64,
    queue_dequeued: u64,
    queue_high_water: u16,
    queue_dropped: u64,
    busy_unregister_rejected: bool,
    reuse_slot: u16,
    reuse_generation: u32,
    stale_active_rejected: bool,
    stale_receive_rejected: bool,
    stale_send_rejected: bool,
    stale_close_rejected: bool,
    final_registered_endpoints: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    ingress_dropped: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
    unmatched_dropped: u64,
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
    udp_tftp_dispatch: UdpTftpDispatchReport,
    udp_endpoint_demux: UdpEndpointDemuxReport,
    udp_endpoint_lifecycle: UdpEndpointLifecycleReport,
    udp_peer_filter: UdpPeerFilterReport,
    udp_ephemeral_ports: UdpEphemeralPortReport,
    udp_socket_queue: UdpSocketQueueReport,
    udp_dispatch_batch: UdpDispatchBatchReport,
    udp_endpoint_poll: UdpEndpointPollReport,
    udp_service_cycle: UdpServiceCycleReport,
    udp_fair_service: UdpFairServiceReport,
    udp_automatic_identification: UdpAutomaticIdentificationReport,
    udp_payload_boundary: UdpPayloadBoundaryReport,
    udp_transmit_wrap: UdpTransmitWrapReport,
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
        .udp_endpoints = std.mem.zeroes([udp_endpoint_capacity]UdpEndpoint),
        .udp_endpoint_count = 0,
        .next_udp_generation = 1,
        .next_ephemeral_udp_port = ephemeral_udp_port_first,
        .next_udp_ready_index = 0,
        .next_udp_identification = 0x7000,
        .unmatched_udp_packets_dropped = 0,
        .invalid_udp_packets_dropped = 0,
        .peer_mismatch_udp_packets_dropped = 0,
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
    const udp_tftp_dispatch = verifyUdpTftpDispatch(device) orelse {
        active_device_storage = null;
        return null;
    };
    const udp_endpoint_demux = verifyUdpEndpointDemux(device) orelse {
        active_device_storage = null;
        return null;
    };
    const udp_endpoint_lifecycle = verifyUdpEndpointLifecycle(device) orelse {
        active_device_storage = null;
        return null;
    };
    const udp_peer_filter = verifyUdpPeerFiltering(device) orelse {
        active_device_storage = null;
        return null;
    };
    const udp_ephemeral_ports = verifyUdpEphemeralPorts(device) orelse {
        active_device_storage = null;
        return null;
    };
    const udp_socket_queue = verifyUdpSocketQueueControl(device) orelse {
        active_device_storage = null;
        return null;
    };
    const udp_dispatch_batch = verifyUdpDispatchBatch(device) orelse {
        active_device_storage = null;
        return null;
    };
    const udp_endpoint_poll = verifyUdpEndpointPoll(device) orelse {
        active_device_storage = null;
        return null;
    };
    const udp_service_cycle = verifyUdpServiceCycle(device) orelse {
        active_device_storage = null;
        return null;
    };
    const udp_fair_service = verifyUdpFairService(device) orelse {
        active_device_storage = null;
        return null;
    };
    const udp_automatic_identification = verifyUdpAutomaticIdentification(device) orelse {
        active_device_storage = null;
        return null;
    };
    const udp_payload_boundary = verifyUdpPayloadBoundary(device) orelse {
        active_device_storage = null;
        return null;
    };
    const udp_transmit_wrap = verifyUdpTransmitWrap(device) orelse {
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
        .udp_tftp_dispatch = udp_tftp_dispatch,
        .udp_endpoint_demux = udp_endpoint_demux,
        .udp_endpoint_lifecycle = udp_endpoint_lifecycle,
        .udp_peer_filter = udp_peer_filter,
        .udp_ephemeral_ports = udp_ephemeral_ports,
        .udp_socket_queue = udp_socket_queue,
        .udp_dispatch_batch = udp_dispatch_batch,
        .udp_endpoint_poll = udp_endpoint_poll,
        .udp_service_cycle = udp_service_cycle,
        .udp_fair_service = udp_fair_service,
        .udp_automatic_identification = udp_automatic_identification,
        .udp_payload_boundary = udp_payload_boundary,
        .udp_transmit_wrap = udp_transmit_wrap,
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
    return dispatchNextPacketResult(device) == .routed;
}

pub fn dispatchNextPacketResult(device: *Device) PacketDispatchResult {
    const packet = dequeuePacket(device) orelse return .empty;
    const kind = classifyPacket(packet.bytes[0..packet.length]);
    const queue = switch (kind) {
        .arp => &device.arp_rx_queue,
        .icmp => &device.icmp_rx_queue,
        .udp => blk: {
            const datagram = udp.parseFrame(packet.bytes[0..packet.length], .{
                .destination_mac = device.local_mac,
                .destination_ipv4 = device.local_ipv4,
            }) orelse {
                device.invalid_udp_packets_dropped +|= 1;
                return .dropped;
            };
            const endpoint_index = findUdpEndpoint(device, datagram.destination_port) orelse {
                device.unmatched_udp_packets_dropped +|= 1;
                return .dropped;
            };
            const endpoint = &device.udp_endpoints[endpoint_index];
            if (endpoint.peer_bound and
                (!std.mem.eql(u8, &datagram.source_mac, &endpoint.peer.mac) or
                    !std.mem.eql(u8, &datagram.source_ipv4, &endpoint.peer.ipv4) or
                    datagram.source_port != endpoint.peer.port))
            {
                device.peer_mismatch_udp_packets_dropped +|= 1;
                return .dropped;
            }
            break :blk &endpoint.queue;
        },
        .unknown => {
            device.unknown_packets_dropped +|= 1;
            return .dropped;
        },
    };
    if (!enqueueQueuedPacket(queue, packet)) return .dropped;
    device.packets_dispatched +|= 1;
    switch (kind) {
        .arp => device.arp_packets_dispatched +|= 1,
        .icmp => device.icmp_packets_dispatched +|= 1,
        .udp => device.udp_packets_dispatched +|= 1,
        .unknown => unreachable,
    }
    return .routed;
}

pub fn dispatchPacketBatch(device: *Device, budget: u16) PacketDispatchBatch {
    var batch = PacketDispatchBatch{
        .examined = 0,
        .routed = 0,
        .dropped = 0,
        .remaining = queueDepth(&device.software_rx_queue),
    };
    while (batch.examined < budget) {
        switch (dispatchNextPacketResult(device)) {
            .empty => break,
            .routed => {
                batch.examined +|= 1;
                batch.routed +|= 1;
            },
            .dropped => {
                batch.examined +|= 1;
                batch.dropped +|= 1;
            },
        }
    }
    batch.remaining = queueDepth(&device.software_rx_queue);
    return batch;
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

pub fn registerUdpEndpoint(device: *Device, port: u16) ?u16 {
    if (port == 0) return null;
    if (findUdpEndpoint(device, port)) |index| return @intCast(index);
    for (&device.udp_endpoints, 0..) |*endpoint, index| {
        if (endpoint.active) continue;
        endpoint.* = .{
            .active = true,
            .port = port,
            .generation = allocateUdpGeneration(device),
            .peer_bound = false,
            .peer = std.mem.zeroes(UdpPeer),
            .queue = std.mem.zeroes(SoftwarePacketQueue),
        };
        device.udp_endpoint_count +|= 1;
        return @intCast(index);
    }
    return null;
}

pub fn unregisterUdpEndpoint(device: *Device, endpoint_index: u16) bool {
    if (endpoint_index >= udp_endpoint_capacity) return false;
    const endpoint = &device.udp_endpoints[endpoint_index];
    if (!endpoint.active or endpoint.queue.head != endpoint.queue.tail) return false;
    endpoint.* = std.mem.zeroes(UdpEndpoint);
    device.udp_endpoint_count -|= 1;
    return true;
}

pub fn dequeueUdpEndpointPacket(device: *Device, endpoint_index: u16) ?Packet {
    if (endpoint_index >= udp_endpoint_capacity) return null;
    const endpoint = &device.udp_endpoints[endpoint_index];
    if (!endpoint.active) return null;
    return dequeueQueuedPacket(&endpoint.queue);
}

pub fn openUdpSocket(device: *Device, port: u16) ?UdpSocket {
    const endpoint_index = registerUdpEndpoint(device, port) orelse return null;
    const endpoint = &device.udp_endpoints[endpoint_index];
    if (!endpoint.active or endpoint.port != port or endpoint.generation == 0) return null;
    return .{
        .endpoint_index = endpoint_index,
        .generation = endpoint.generation,
        .local_port = port,
    };
}

pub fn openEphemeralUdpSocket(device: *Device) ?UdpSocket {
    if (device.udp_endpoint_count >= udp_endpoint_capacity) return null;
    var candidate = device.next_ephemeral_udp_port;
    if (candidate < ephemeral_udp_port_first) candidate = ephemeral_udp_port_first;
    var attempts: u32 = 0;
    while (attempts < ephemeral_udp_port_count) : (attempts += 1) {
        if (findUdpEndpoint(device, candidate) == null) {
            const socket = openUdpSocket(device, candidate) orelse return null;
            device.next_ephemeral_udp_port = nextEphemeralUdpPort(candidate);
            return socket;
        }
        candidate = nextEphemeralUdpPort(candidate);
    }
    return null;
}

pub fn udpSocketActive(device: *Device, socket: UdpSocket) bool {
    return udpSocketEndpoint(device, socket) != null;
}

pub fn collectReadableUdpSockets(device: *const Device) UdpReadySockets {
    var ready = std.mem.zeroes(UdpReadySockets);
    for (&device.udp_endpoints, 0..) |*endpoint, index| {
        if (!endpoint.active) continue;
        const pending = queueDepth(&endpoint.queue);
        if (pending == 0) continue;
        const ready_index: usize = ready.count;
        ready.sockets[ready_index] = .{
            .endpoint_index = @intCast(index),
            .generation = endpoint.generation,
            .local_port = endpoint.port,
        };
        ready.count +|= 1;
        ready.total_pending +|= pending;
    }
    return ready;
}

pub fn serviceUdpSockets(device: *Device, dispatch_budget: u16) UdpServiceCycle {
    return .{
        .dispatch = dispatchPacketBatch(device, dispatch_budget),
        .ready = collectReadableUdpSockets(device),
    };
}

pub fn collectReadableUdpSocketsFair(device: *Device, max_sockets: u8) UdpReadySockets {
    var ready = std.mem.zeroes(UdpReadySockets);
    if (max_sockets == 0) return ready;
    var scanned: u8 = 0;
    var index: u8 = if (device.next_udp_ready_index < udp_endpoint_capacity)
        device.next_udp_ready_index
    else
        0;
    while (scanned < udp_endpoint_capacity and ready.count < max_sockets) : (scanned += 1) {
        const endpoint = &device.udp_endpoints[index];
        if (endpoint.active) {
            const pending = queueDepth(&endpoint.queue);
            if (pending != 0) {
                const ready_index: usize = ready.count;
                ready.sockets[ready_index] = .{
                    .endpoint_index = index,
                    .generation = endpoint.generation,
                    .local_port = endpoint.port,
                };
                ready.count +|= 1;
                ready.total_pending +|= pending;
                device.next_udp_ready_index = @intCast((@as(u16, index) + 1) % udp_endpoint_capacity);
            }
        }
        index = @intCast((@as(u16, index) + 1) % udp_endpoint_capacity);
    }
    return ready;
}

pub fn serviceUdpSocketsFair(
    device: *Device,
    dispatch_budget: u16,
    ready_budget: u8,
) UdpServiceCycle {
    return .{
        .dispatch = dispatchPacketBatch(device, dispatch_budget),
        .ready = collectReadableUdpSocketsFair(device, ready_budget),
    };
}

pub fn pollUdpEndpoints(device: *const Device) UdpEndpointPoll {
    var result = std.mem.zeroes(UdpEndpointPoll);
    for (&device.udp_endpoints, 0..) |*endpoint, index| {
        if (!endpoint.active) continue;
        const bit: u8 = @as(u8, 1) << @intCast(index);
        result.active_mask |= bit;
        result.active_count +|= 1;
        const pending = queueDepth(&endpoint.queue);
        result.total_pending +|= pending;
        if (pending > result.max_pending) result.max_pending = pending;
        if (pending != 0) {
            result.readable_mask |= bit;
            result.readable_count +|= 1;
        }
        if (endpoint.peer_bound) {
            result.connected_mask |= bit;
            result.connected_count +|= 1;
        }
    }
    return result;
}

pub fn inspectUdpSocket(device: *Device, socket: UdpSocket) ?UdpSocketStatus {
    const endpoint = udpSocketEndpoint(device, socket) orelse return null;
    return .{
        .local_port = endpoint.port,
        .generation = endpoint.generation,
        .connected = endpoint.peer_bound,
        .peer_port = if (endpoint.peer_bound) endpoint.peer.port else 0,
        .pending_packets = queueDepth(&endpoint.queue),
        .usable_capacity = software_packet_queue_capacity - 1,
        .enqueued = endpoint.queue.enqueued,
        .dequeued = endpoint.queue.dequeued,
        .dropped = endpoint.queue.dropped,
        .high_water = endpoint.queue.high_water,
    };
}

pub fn udpSocketReadable(device: *Device, socket: UdpSocket) bool {
    const status = inspectUdpSocket(device, socket) orelse return false;
    return status.pending_packets != 0;
}

pub fn discardUdpSocketPackets(device: *Device, socket: UdpSocket) ?u16 {
    const endpoint = udpSocketEndpoint(device, socket) orelse return null;
    var discarded: u16 = 0;
    while (dequeueQueuedPacket(&endpoint.queue) != null) discarded +|= 1;
    return discarded;
}

pub fn receiveUdpSocket(device: *Device, socket: UdpSocket) ?Packet {
    const endpoint = udpSocketEndpoint(device, socket) orelse return null;
    return dequeueQueuedPacket(&endpoint.queue);
}

pub fn receiveUdpDatagram(device: *Device, socket: UdpSocket) ?ReceivedUdpDatagram {
    const endpoint = udpSocketEndpoint(device, socket) orelse return null;
    const packet = dequeueQueuedPacket(&endpoint.queue) orelse return null;
    const datagram = udp.parseFrame(packet.bytes[0..packet.length], .{
        .destination_mac = device.local_mac,
        .source_mac = if (endpoint.peer_bound) endpoint.peer.mac else null,
        .destination_ipv4 = device.local_ipv4,
        .source_ipv4 = if (endpoint.peer_bound) endpoint.peer.ipv4 else null,
        .destination_port = endpoint.port,
        .source_port = if (endpoint.peer_bound) endpoint.peer.port else null,
    }) orelse return null;
    const payload_offset = @intFromPtr(datagram.payload.ptr) - @intFromPtr(packet.bytes[0..].ptr);
    if (payload_offset > packet.length or datagram.payload.len > packet.length - payload_offset) return null;
    return .{
        .packet = packet,
        .source_mac = datagram.source_mac,
        .destination_mac = datagram.destination_mac,
        .source_ipv4 = datagram.source_ipv4,
        .destination_ipv4 = datagram.destination_ipv4,
        .source_port = datagram.source_port,
        .destination_port = datagram.destination_port,
        .ttl = datagram.ttl,
        .identification = datagram.identification,
        .udp_checksum_present = datagram.udp_checksum_present,
        .payload_offset = @intCast(payload_offset),
        .payload_length = @intCast(datagram.payload.len),
    };
}

pub fn connectUdpSocket(device: *Device, socket: UdpSocket, peer: UdpPeer) bool {
    const endpoint = udpSocketEndpoint(device, socket) orelse return false;
    if (!validUdpPeer(peer) or endpoint.queue.head != endpoint.queue.tail) return false;
    if (endpoint.peer_bound) return std.meta.eql(endpoint.peer, peer);
    endpoint.peer = peer;
    endpoint.peer_bound = true;
    return true;
}

pub fn disconnectUdpSocket(device: *Device, socket: UdpSocket) bool {
    const endpoint = udpSocketEndpoint(device, socket) orelse return false;
    if (!endpoint.peer_bound or endpoint.queue.head != endpoint.queue.tail) return false;
    endpoint.peer = std.mem.zeroes(UdpPeer);
    endpoint.peer_bound = false;
    return true;
}

pub fn udpSocketPeer(device: *Device, socket: UdpSocket) ?UdpPeer {
    const endpoint = udpSocketEndpoint(device, socket) orelse return null;
    if (!endpoint.peer_bound) return null;
    return endpoint.peer;
}

pub fn sendUdpSocket(device: *Device, socket: UdpSocket, options: UdpSendOptions) ?TxCompletion {
    const endpoint = udpSocketEndpoint(device, socket) orelse return null;
    if (options.destination_port == 0 or options.ttl == 0 or
        options.payload.len > maximum_udp_payload_bytes)
    {
        return null;
    }
    var frame = std.mem.zeroes([maximum_software_packet_bytes]u8);
    const frame_length = udp.buildFrame(&frame, .{
        .source_mac = device.local_mac,
        .destination_mac = options.destination_mac,
        .source_ipv4 = device.local_ipv4,
        .destination_ipv4 = options.destination_ipv4,
        .source_port = endpoint.port,
        .destination_port = options.destination_port,
        .identification = options.identification,
        .ttl = options.ttl,
        .payload = options.payload,
    }) orelse return null;
    return submitFrame(device, frame[0..frame_length]);
}

pub fn sendConnectedUdpSocket(
    device: *Device,
    socket: UdpSocket,
    options: ConnectedUdpSendOptions,
) ?TxCompletion {
    const endpoint = udpSocketEndpoint(device, socket) orelse return null;
    if (!endpoint.peer_bound) return null;
    return sendUdpSocket(device, socket, .{
        .destination_mac = endpoint.peer.mac,
        .destination_ipv4 = endpoint.peer.ipv4,
        .destination_port = endpoint.peer.port,
        .identification = options.identification,
        .ttl = options.ttl,
        .payload = options.payload,
    });
}

pub fn sendConnectedUdpDatagram(
    device: *Device,
    socket: UdpSocket,
    ttl: u8,
    payload: []const u8,
) ?UdpTransmitResult {
    var identification = device.next_udp_identification;
    if (identification == 0) identification = 1;
    const completion = sendConnectedUdpSocket(device, socket, .{
        .identification = identification,
        .ttl = ttl,
        .payload = payload,
    }) orelse return null;
    device.next_udp_identification = nextUdpIdentification(identification);
    return .{
        .completion = completion,
        .identification = identification,
    };
}

pub fn closeUdpSocket(device: *Device, socket: UdpSocket) bool {
    _ = udpSocketEndpoint(device, socket) orelse return false;
    return unregisterUdpEndpoint(device, socket.endpoint_index);
}

fn udpSocketEndpoint(device: *Device, socket: UdpSocket) ?*UdpEndpoint {
    if (socket.endpoint_index >= udp_endpoint_capacity or socket.generation == 0 or socket.local_port == 0) {
        return null;
    }
    const endpoint = &device.udp_endpoints[socket.endpoint_index];
    if (!endpoint.active or endpoint.port != socket.local_port or endpoint.generation != socket.generation) {
        return null;
    }
    return endpoint;
}

fn findUdpEndpoint(device: *Device, port: u16) ?usize {
    for (&device.udp_endpoints, 0..) |*endpoint, index| {
        if (endpoint.active and endpoint.port == port) return index;
    }
    return null;
}

fn validUdpPeer(peer: UdpPeer) bool {
    if (peer.port == 0) return false;
    var mac_nonzero = false;
    for (peer.mac) |octet| mac_nonzero = mac_nonzero or octet != 0;
    var ipv4_nonzero = false;
    for (peer.ipv4) |octet| ipv4_nonzero = ipv4_nonzero or octet != 0;
    return mac_nonzero and ipv4_nonzero;
}

fn nextEphemeralUdpPort(port: u16) u16 {
    return if (port >= ephemeral_udp_port_last) ephemeral_udp_port_first else port + 1;
}

fn nextUdpIdentification(identification: u16) u16 {
    const next = identification +% 1;
    return if (next == 0) 1 else next;
}

fn allocateUdpGeneration(device: *Device) u32 {
    var generation = device.next_udp_generation;
    if (generation == 0) generation = 1;
    device.next_udp_generation = generation +% 1;
    if (device.next_udp_generation == 0) device.next_udp_generation = 1;
    return generation;
}

fn queueDepth(queue: *const SoftwarePacketQueue) u16 {
    return @intCast((queue.head + software_packet_queue_capacity - queue.tail) % software_packet_queue_capacity);
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

fn verifyUdpTftpDispatch(device: *Device) ?UdpTftpDispatchReport {
    const endpoint_index = registerUdpEndpoint(device, dispatched_tftp_client_port) orelse return null;
    if (endpoint_index != 0) return null;
    const endpoint = &device.udp_endpoints[endpoint_index];
    var tftp_payload_buffer: [128]u8 = undefined;
    const read_request = tftp.buildReadRequest(&tftp_payload_buffer) orelse return null;
    var frame = std.mem.zeroes([ethernet_minimum_frame_bytes]u8);
    const rrq_length = udp.buildFrame(&frame, .{
        .source_mac = device.local_mac,
        .destination_mac = device.gateway_mac,
        .source_ipv4 = device.local_ipv4,
        .destination_ipv4 = device.gateway_ipv4,
        .source_port = dispatched_tftp_client_port,
        .destination_port = tftp.server_port,
        .identification = dispatched_tftp_identification,
        .payload = read_request,
    }) orelse return null;
    const rrq = submitFrame(device, frame[0..rrq_length]) orelse return null;

    var data_descriptors = std.mem.zeroes([tftp.expected_block_count]u16);
    var acknowledgement_descriptors = std.mem.zeroes([tftp.expected_block_count]u16);
    var data_frame_lengths = std.mem.zeroes([tftp.expected_block_count]u16);
    var acknowledgement_frame_lengths = std.mem.zeroes([tftp.expected_block_count]u16);
    var server_port: u16 = 0;
    var reply_ttl: u8 = 0;
    var udp_checksum_present = true;
    var block_count: u16 = 0;
    var payload_length: usize = 0;
    var payload_fnv1a64 = tftp.initial_fnv1a64;
    var final_block = false;

    while (block_count < tftp.expected_block_count) {
        if (!pumpReceive(device)) return null;
        if (!dispatchNextPacket(device)) return null;
        const packet = dequeueUdpEndpointPacket(device, endpoint_index) orelse return null;
        const datagram = udp.parseFrame(packet.bytes[0..packet.length], .{
            .destination_mac = device.local_mac,
            .source_mac = device.gateway_mac,
            .destination_ipv4 = device.local_ipv4,
            .source_ipv4 = device.gateway_ipv4,
            .destination_port = dispatched_tftp_client_port,
            .source_port = if (server_port == 0) null else server_port,
        }) orelse return null;
        if (server_port == 0) {
            server_port = datagram.source_port;
            reply_ttl = datagram.ttl;
        } else if (datagram.source_port != server_port or datagram.ttl != reply_ttl) {
            return null;
        }
        udp_checksum_present = udp_checksum_present and datagram.udp_checksum_present;

        const expected_block: u16 = block_count + 1;
        const data = tftp.parseData(datagram.payload, expected_block, payload_length) orelse return null;
        const index: usize = block_count;
        data_descriptors[index] = packet.source_descriptor;
        data_frame_lengths[index] = packet.length;
        payload_fnv1a64 = tftp.updatePayloadHash(payload_fnv1a64, data.payload);
        payload_length += data.payload.len;
        block_count += 1;
        final_block = data.final_block;
        if (final_block != (block_count == tftp.expected_block_count)) return null;

        const acknowledgement = tftp.buildAcknowledgement(&tftp_payload_buffer, data.block) orelse return null;
        const acknowledgement_length = udp.buildFrame(&frame, .{
            .source_mac = device.local_mac,
            .destination_mac = device.gateway_mac,
            .source_ipv4 = device.local_ipv4,
            .destination_ipv4 = device.gateway_ipv4,
            .source_port = dispatched_tftp_client_port,
            .destination_port = server_port,
            .identification = dispatched_tftp_identification + block_count,
            .payload = acknowledgement,
        }) orelse return null;
        const acknowledgement_tx = submitFrame(device, frame[0..acknowledgement_length]) orelse return null;
        acknowledgement_descriptors[index] = acknowledgement_tx.descriptor_index;
        acknowledgement_frame_lengths[index] = acknowledgement_tx.frame_length;
    }

    const tx_queue_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_queue_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_queue_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const rx_queue_dequeues = completionQueueDequeued(&rx_completion_queue);
    const completion_queue_overflows = completionQueueOverflow(&tx_completion_queue) +
        completionQueueOverflow(&rx_completion_queue);
    const final_tx_pending = @atomicLoad(u32, &tx_pending_mask, .acquire);
    const final_rx_pending = @atomicLoad(u32, &rx_pending_mask, .acquire);
    const expected_data_descriptors = [tftp.expected_block_count]u16{ 4, 5, 6, 7, 0 };
    const expected_acknowledgement_descriptors = [tftp.expected_block_count]u16{ 6, 7, 0, 1, 2 };
    const expected_data_frame_lengths = [tftp.expected_block_count]u16{ 558, 558, 558, 558, 302 };
    const expected_acknowledgement_frame_lengths = [tftp.expected_block_count]u16{ 60, 60, 60, 60, 60 };
    if (rrq.descriptor_index != 5 or rrq.next_cursor != 6 or rrq.frame_length != 60 or
        !std.mem.eql(u16, &data_descriptors, &expected_data_descriptors) or
        !std.mem.eql(u16, &acknowledgement_descriptors, &expected_acknowledgement_descriptors) or
        !std.mem.eql(u16, &data_frame_lengths, &expected_data_frame_lengths) or
        !std.mem.eql(u16, &acknowledgement_frame_lengths, &expected_acknowledgement_frame_lengths) or
        !final_block or block_count != tftp.expected_block_count or
        payload_length != tftp.expected_file_bytes or
        payload_fnv1a64 != tftp.expected_payload_fnv1a64 or
        server_port != tftp.server_port or reply_ttl == 0 or !udp_checksum_present or
        device.tx_producer != 3 or device.rx_consumer != 1 or
        device.tx_submissions != 9 or device.rx_deliveries != 8 or
        device.tx_cursor_wraps != 1 or device.rx_cursor_wraps != 1 or
        device.rx_recycled_descriptors != 8 or device.rx_descriptor_wraps != 1 or
        device.software_rx_queue.enqueued != 7 or
        device.software_rx_queue.dequeued != 7 or
        device.software_rx_queue.dropped != 0 or
        device.software_rx_queue.head != device.software_rx_queue.tail or
        device.packets_dispatched != 6 or
        device.arp_packets_dispatched != 0 or
        device.icmp_packets_dispatched != 1 or
        device.udp_packets_dispatched != tftp.expected_block_count or
        device.unknown_packets_dropped != 0 or
        device.unmatched_udp_packets_dropped != 0 or
        device.udp_endpoint_count != 1 or endpoint.port != dispatched_tftp_client_port or
        endpoint.queue.enqueued != tftp.expected_block_count or
        endpoint.queue.dequeued != tftp.expected_block_count or
        endpoint.queue.high_water != 1 or
        endpoint.queue.dropped != 0 or
        endpoint.queue.head != endpoint.queue.tail or
        device.udp_rx_queue.enqueued != 0 or device.udp_rx_queue.dequeued != 0 or
        tx_queue_enqueues != 19 or tx_queue_dequeues != 19 or
        rx_queue_enqueues != 17 or rx_queue_dequeues != 17 or
        completion_queue_overflows != 0 or final_tx_pending != 0 or
        final_rx_pending != all_rx_descriptors_pending or
        tx_ready_mask != 0 or rx_ready_mask != 0)
    {
        return null;
    }

    return .{
        .rrq = rrq,
        .data_descriptors = data_descriptors,
        .acknowledgement_descriptors = acknowledgement_descriptors,
        .data_frame_lengths = data_frame_lengths,
        .acknowledgement_frame_lengths = acknowledgement_frame_lengths,
        .block_count = block_count,
        .payload_length = @intCast(payload_length),
        .payload_fnv1a64 = payload_fnv1a64,
        .server_port = server_port,
        .reply_ttl = reply_ttl,
        .udp_checksum_present = udp_checksum_present,
        .device_tx_cursor = device.tx_producer,
        .device_rx_cursor = device.rx_consumer,
        .tx_cursor_wraps = device.tx_cursor_wraps,
        .rx_cursor_wraps = device.rx_cursor_wraps,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .ingress_dropped = device.software_rx_queue.dropped,
        .packets_dispatched = device.packets_dispatched,
        .arp_dispatched = device.arp_packets_dispatched,
        .icmp_dispatched = device.icmp_packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
        .unknown_dropped = device.unknown_packets_dropped,
        .udp_queue_enqueued = endpoint.queue.enqueued,
        .udp_queue_dequeued = endpoint.queue.dequeued,
        .udp_queue_high_water = endpoint.queue.high_water,
        .udp_queue_dropped = endpoint.queue.dropped,
        .tx_queue_enqueues = tx_queue_enqueues,
        .tx_queue_dequeues = tx_queue_dequeues,
        .rx_queue_enqueues = rx_queue_enqueues,
        .rx_queue_dequeues = rx_queue_dequeues,
        .completion_queue_overflows = completion_queue_overflows,
        .tx_pending_mask = final_tx_pending,
        .rx_pending_mask = final_rx_pending,
    };
}

fn verifyUdpEndpointDemux(device: *Device) ?UdpEndpointDemuxReport {
    if (registerUdpEndpoint(device, dispatched_tftp_client_port) != 0) return null;
    const socket = openUdpSocket(device, endpoint_tftp_client_port) orelse return null;
    const endpoint_index = socket.endpoint_index;
    if (endpoint_index != 1 or socket.generation != 2 or device.udp_endpoint_count != 2) return null;
    const endpoint = &device.udp_endpoints[endpoint_index];

    var unmatched_frame = std.mem.zeroes([ethernet_minimum_frame_bytes]u8);
    const unmatched_payload = [_]u8{ 0x5A, 0x49, 0x47, 0x4F, 0x53 };
    const unmatched_length = udp.buildFrame(&unmatched_frame, .{
        .source_mac = device.gateway_mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = device.gateway_ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = tftp.server_port,
        .destination_port = unmatched_udp_port,
        .identification = endpoint_tftp_identification - 1,
        .payload = &unmatched_payload,
    }) orelse return null;
    var unmatched_packet = std.mem.zeroes(Packet);
    unmatched_packet.length = unmatched_length;
    unmatched_packet.source_descriptor = std.math.maxInt(u16);
    @memcpy(unmatched_packet.bytes[0..unmatched_length], unmatched_frame[0..unmatched_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, unmatched_packet)) return null;
    if (dispatchNextPacket(device)) return null;
    if (device.unmatched_udp_packets_dropped != 1) return null;

    var tftp_payload_buffer: [128]u8 = undefined;
    const read_request = tftp.buildReadRequest(&tftp_payload_buffer) orelse return null;
    const rrq = sendUdpSocket(device, socket, .{
        .destination_mac = device.gateway_mac,
        .destination_ipv4 = device.gateway_ipv4,
        .destination_port = tftp.server_port,
        .identification = endpoint_tftp_identification,
        .payload = read_request,
    }) orelse return null;

    var data_descriptors = std.mem.zeroes([tftp.expected_block_count]u16);
    var acknowledgement_descriptors = std.mem.zeroes([tftp.expected_block_count]u16);
    var data_frame_lengths = std.mem.zeroes([tftp.expected_block_count]u16);
    var acknowledgement_frame_lengths = std.mem.zeroes([tftp.expected_block_count]u16);
    var server_port: u16 = 0;
    var reply_ttl: u8 = 0;
    var udp_checksum_present = true;
    var block_count: u16 = 0;
    var payload_length: usize = 0;
    var payload_fnv1a64 = tftp.initial_fnv1a64;
    var final_block = false;
    var structured_receives: u16 = 0;
    var connected_sends: u16 = 0;

    while (block_count < tftp.expected_block_count) {
        if (!pumpReceive(device)) return null;
        if (!dispatchNextPacket(device)) return null;
        const datagram = receiveUdpDatagram(device, socket) orelse return null;
        structured_receives +|= 1;
        if (server_port == 0) {
            server_port = datagram.source_port;
            reply_ttl = datagram.ttl;
            if (!connectUdpSocket(device, socket, .{
                .mac = datagram.source_mac,
                .ipv4 = datagram.source_ipv4,
                .port = datagram.source_port,
            })) return null;
        } else if (datagram.source_port != server_port or datagram.ttl != reply_ttl) {
            return null;
        }
        udp_checksum_present = udp_checksum_present and datagram.udp_checksum_present;

        const expected_block: u16 = block_count + 1;
        const data = tftp.parseData(datagram.payload(), expected_block, payload_length) orelse return null;
        const index: usize = block_count;
        data_descriptors[index] = datagram.packet.source_descriptor;
        data_frame_lengths[index] = datagram.packet.length;
        payload_fnv1a64 = tftp.updatePayloadHash(payload_fnv1a64, data.payload);
        payload_length += data.payload.len;
        block_count += 1;
        final_block = data.final_block;
        if (final_block != (block_count == tftp.expected_block_count)) return null;

        const acknowledgement = tftp.buildAcknowledgement(&tftp_payload_buffer, data.block) orelse return null;
        const acknowledgement_tx = sendConnectedUdpSocket(device, socket, .{
            .identification = endpoint_tftp_identification + block_count,
            .payload = acknowledgement,
        }) orelse return null;
        connected_sends +|= 1;
        acknowledgement_descriptors[index] = acknowledgement_tx.descriptor_index;
        acknowledgement_frame_lengths[index] = acknowledgement_tx.frame_length;
    }

    const tx_queue_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_queue_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_queue_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const rx_queue_dequeues = completionQueueDequeued(&rx_completion_queue);
    const completion_queue_overflows = completionQueueOverflow(&tx_completion_queue) +
        completionQueueOverflow(&rx_completion_queue);
    const final_tx_pending = @atomicLoad(u32, &tx_pending_mask, .acquire);
    const final_rx_pending = @atomicLoad(u32, &rx_pending_mask, .acquire);
    const expected_data_descriptors = [tftp.expected_block_count]u16{ 1, 2, 3, 4, 5 };
    const expected_acknowledgement_descriptors = [tftp.expected_block_count]u16{ 4, 5, 6, 7, 0 };
    const expected_data_frame_lengths = [tftp.expected_block_count]u16{ 558, 558, 558, 558, 302 };
    const expected_acknowledgement_frame_lengths = [tftp.expected_block_count]u16{ 60, 60, 60, 60, 60 };
    if (rrq.descriptor_index != 3 or rrq.next_cursor != 4 or rrq.frame_length != 60 or
        !std.mem.eql(u16, &data_descriptors, &expected_data_descriptors) or
        !std.mem.eql(u16, &acknowledgement_descriptors, &expected_acknowledgement_descriptors) or
        !std.mem.eql(u16, &data_frame_lengths, &expected_data_frame_lengths) or
        !std.mem.eql(u16, &acknowledgement_frame_lengths, &expected_acknowledgement_frame_lengths) or
        !final_block or block_count != tftp.expected_block_count or
        payload_length != tftp.expected_file_bytes or
        payload_fnv1a64 != tftp.expected_payload_fnv1a64 or
        server_port != tftp.server_port or reply_ttl == 0 or !udp_checksum_present or
        structured_receives != tftp.expected_block_count or connected_sends != tftp.expected_block_count or
        !endpoint.peer_bound or endpoint.peer.port != server_port or
        device.tx_producer != 1 or device.rx_consumer != 6 or
        device.tx_submissions != 15 or device.rx_deliveries != 13 or
        device.tx_cursor_wraps != 2 or device.rx_cursor_wraps != 1 or
        device.rx_recycled_descriptors != 13 or device.rx_descriptor_wraps != 1 or
        device.software_rx_queue.enqueued != 13 or
        device.software_rx_queue.dequeued != 13 or
        device.software_rx_queue.dropped != 0 or
        device.software_rx_queue.head != device.software_rx_queue.tail or
        device.packets_dispatched != 11 or
        device.arp_packets_dispatched != 0 or
        device.icmp_packets_dispatched != 1 or
        device.udp_packets_dispatched != 10 or
        device.unknown_packets_dropped != 0 or
        device.unmatched_udp_packets_dropped != 1 or
        device.udp_endpoint_count != 2 or endpoint.port != endpoint_tftp_client_port or
        endpoint.generation != socket.generation or !udpSocketActive(device, socket) or
        endpoint.queue.enqueued != tftp.expected_block_count or
        endpoint.queue.dequeued != tftp.expected_block_count or
        endpoint.queue.high_water != 1 or
        endpoint.queue.dropped != 0 or
        endpoint.queue.head != endpoint.queue.tail or
        tx_queue_enqueues != 25 or tx_queue_dequeues != 25 or
        rx_queue_enqueues != 22 or rx_queue_dequeues != 22 or
        completion_queue_overflows != 0 or final_tx_pending != 0 or
        final_rx_pending != all_rx_descriptors_pending or
        tx_ready_mask != 0 or rx_ready_mask != 0)
    {
        return null;
    }

    return .{
        .endpoint_index = endpoint_index,
        .endpoint_port = endpoint.port,
        .socket_generation = socket.generation,
        .registered_endpoints = device.udp_endpoint_count,
        .structured_receives = structured_receives,
        .connected_sends = connected_sends,
        .connected_peer_port = endpoint.peer.port,
        .connected_peer_bound = endpoint.peer_bound,
        .unmatched_port = unmatched_udp_port,
        .unmatched_dropped = device.unmatched_udp_packets_dropped,
        .rrq = rrq,
        .data_descriptors = data_descriptors,
        .acknowledgement_descriptors = acknowledgement_descriptors,
        .data_frame_lengths = data_frame_lengths,
        .acknowledgement_frame_lengths = acknowledgement_frame_lengths,
        .block_count = block_count,
        .payload_length = @intCast(payload_length),
        .payload_fnv1a64 = payload_fnv1a64,
        .server_port = server_port,
        .reply_ttl = reply_ttl,
        .udp_checksum_present = udp_checksum_present,
        .device_tx_cursor = device.tx_producer,
        .device_rx_cursor = device.rx_consumer,
        .tx_cursor_wraps = device.tx_cursor_wraps,
        .rx_cursor_wraps = device.rx_cursor_wraps,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .ingress_dropped = device.software_rx_queue.dropped,
        .packets_dispatched = device.packets_dispatched,
        .arp_dispatched = device.arp_packets_dispatched,
        .icmp_dispatched = device.icmp_packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
        .unknown_dropped = device.unknown_packets_dropped,
        .endpoint_queue_enqueued = endpoint.queue.enqueued,
        .endpoint_queue_dequeued = endpoint.queue.dequeued,
        .endpoint_queue_high_water = endpoint.queue.high_water,
        .endpoint_queue_dropped = endpoint.queue.dropped,
        .tx_queue_enqueues = tx_queue_enqueues,
        .tx_queue_dequeues = tx_queue_dequeues,
        .rx_queue_enqueues = rx_queue_enqueues,
        .rx_queue_dequeues = rx_queue_dequeues,
        .completion_queue_overflows = completion_queue_overflows,
        .tx_pending_mask = final_tx_pending,
        .rx_pending_mask = final_rx_pending,
    };
}

fn verifyUdpEndpointLifecycle(device: *Device) ?UdpEndpointLifecycleReport {
    if (openUdpSocket(device, 0) != null) return null;
    if (unregisterUdpEndpoint(device, udp_endpoint_capacity)) return null;

    const queue_socket = openUdpSocket(device, lifecycle_udp_port) orelse return null;
    const queue_slot = queue_socket.endpoint_index;
    if (queue_slot != 2 or queue_socket.generation != 3 or device.udp_endpoint_count != 3) return null;
    const duplicate_socket = openUdpSocket(device, lifecycle_udp_port) orelse return null;
    const duplicate_handle_match = duplicate_socket.endpoint_index == queue_socket.endpoint_index and
        duplicate_socket.generation == queue_socket.generation and
        duplicate_socket.local_port == queue_socket.local_port;
    if (!duplicate_handle_match or device.udp_endpoint_count != 3) return null;
    const second_socket = openUdpSocket(device, lifecycle_second_udp_port) orelse return null;
    if (second_socket.endpoint_index != 3 or second_socket.generation != 4 or
        device.udp_endpoint_count != udp_endpoint_capacity)
    {
        return null;
    }
    const full_table_rejected = openUdpSocket(device, lifecycle_overflow_udp_port) == null;
    if (!full_table_rejected) return null;

    const usable_queue_capacity: usize = software_packet_queue_capacity - 1;
    var packet_index: usize = 0;
    while (packet_index < software_packet_queue_capacity) : (packet_index += 1) {
        var frame = std.mem.zeroes([ethernet_minimum_frame_bytes]u8);
        const payload = [_]u8{ 0xA5, @intCast(packet_index) };
        const frame_length = udp.buildFrame(&frame, .{
            .source_mac = device.gateway_mac,
            .destination_mac = device.local_mac,
            .source_ipv4 = device.gateway_ipv4,
            .destination_ipv4 = device.local_ipv4,
            .source_port = lifecycle_source_port,
            .destination_port = lifecycle_udp_port,
            .identification = @intCast(0x5B00 + packet_index),
            .payload = &payload,
        }) orelse return null;
        var packet = std.mem.zeroes(Packet);
        packet.length = frame_length;
        packet.source_descriptor = @intCast(0xFF00 + packet_index);
        @memcpy(packet.bytes[0..frame_length], frame[0..frame_length]);
        if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return null;
        const dispatched = dispatchNextPacket(device);
        if (dispatched != (packet_index < usable_queue_capacity)) return null;
    }

    const endpoint = &device.udp_endpoints[queue_slot];
    const queue_enqueued = endpoint.queue.enqueued;
    const queue_high_water = endpoint.queue.high_water;
    const queue_dropped = endpoint.queue.dropped;
    if (queue_enqueued != usable_queue_capacity or
        queue_high_water != usable_queue_capacity or queue_dropped != 1)
    {
        return null;
    }

    const busy_unregister_rejected = !closeUdpSocket(device, queue_socket);
    if (!busy_unregister_rejected) return null;

    packet_index = 0;
    while (packet_index < usable_queue_capacity) : (packet_index += 1) {
        const packet = receiveUdpSocket(device, queue_socket) orelse return null;
        const datagram = udp.parseFrame(packet.bytes[0..packet.length], .{
            .destination_mac = device.local_mac,
            .source_mac = device.gateway_mac,
            .destination_ipv4 = device.local_ipv4,
            .source_ipv4 = device.gateway_ipv4,
            .destination_port = lifecycle_udp_port,
            .source_port = lifecycle_source_port,
        }) orelse return null;
        if (datagram.payload.len != 2 or datagram.payload[0] != 0xA5 or
            datagram.payload[1] != packet_index)
        {
            return null;
        }
    }
    const queue_dequeued = endpoint.queue.dequeued;
    if (queue_dequeued != usable_queue_capacity or endpoint.queue.head != endpoint.queue.tail) return null;
    if (!closeUdpSocket(device, queue_socket)) return null;

    const reuse_socket = openUdpSocket(device, lifecycle_reuse_udp_port) orelse return null;
    const reuse_slot = reuse_socket.endpoint_index;
    if (reuse_slot != queue_slot or reuse_socket.generation != 5 or
        reuse_socket.generation == queue_socket.generation or
        device.udp_endpoint_count != udp_endpoint_capacity)
    {
        return null;
    }

    const stale_active_rejected = !udpSocketActive(device, queue_socket);
    const stale_receive_rejected = receiveUdpSocket(device, queue_socket) == null;
    const stale_payload = [_]u8{ 0xDE, 0xAD };
    const submissions_before_stale_send = device.tx_submissions;
    const stale_send_rejected = sendUdpSocket(device, queue_socket, .{
        .destination_mac = device.gateway_mac,
        .destination_ipv4 = device.gateway_ipv4,
        .destination_port = 9,
        .identification = 0x5B10,
        .payload = &stale_payload,
    }) == null and device.tx_submissions == submissions_before_stale_send;
    const stale_close_rejected = !closeUdpSocket(device, queue_socket);
    if (!stale_active_rejected or !stale_receive_rejected or
        !stale_send_rejected or !stale_close_rejected)
    {
        return null;
    }

    if (!closeUdpSocket(device, reuse_socket)) return null;
    if (!closeUdpSocket(device, second_socket)) return null;

    const tx_queue_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_queue_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_queue_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const rx_queue_dequeues = completionQueueDequeued(&rx_completion_queue);
    const completion_queue_overflows = completionQueueOverflow(&tx_completion_queue) +
        completionQueueOverflow(&rx_completion_queue);
    const final_tx_pending = @atomicLoad(u32, &tx_pending_mask, .acquire);
    const final_rx_pending = @atomicLoad(u32, &rx_pending_mask, .acquire);
    if (device.udp_endpoint_count != 2 or
        !device.udp_endpoints[0].active or !device.udp_endpoints[1].active or
        device.udp_endpoints[2].active or device.udp_endpoints[3].active or
        device.software_rx_queue.enqueued != 21 or
        device.software_rx_queue.dequeued != 21 or
        device.software_rx_queue.dropped != 0 or
        device.software_rx_queue.head != device.software_rx_queue.tail or
        device.packets_dispatched != 18 or
        device.udp_packets_dispatched != 17 or
        device.unmatched_udp_packets_dropped != 1 or
        device.unknown_packets_dropped != 0 or
        device.tx_producer != 1 or device.rx_consumer != 6 or
        tx_queue_enqueues != 25 or tx_queue_dequeues != 25 or
        rx_queue_enqueues != 22 or rx_queue_dequeues != 22 or
        completion_queue_overflows != 0 or final_tx_pending != 0 or
        final_rx_pending != all_rx_descriptors_pending or
        tx_ready_mask != 0 or rx_ready_mask != 0)
    {
        return null;
    }

    return .{
        .table_capacity = udp_endpoint_capacity,
        .usable_queue_capacity = usable_queue_capacity,
        .duplicate_slot = duplicate_socket.endpoint_index,
        .duplicate_handle_match = duplicate_handle_match,
        .full_table_rejected = full_table_rejected,
        .queue_slot = queue_slot,
        .queue_generation = queue_socket.generation,
        .queue_enqueued = queue_enqueued,
        .queue_dequeued = queue_dequeued,
        .queue_high_water = queue_high_water,
        .queue_dropped = queue_dropped,
        .busy_unregister_rejected = busy_unregister_rejected,
        .reuse_slot = reuse_slot,
        .reuse_generation = reuse_socket.generation,
        .stale_active_rejected = stale_active_rejected,
        .stale_receive_rejected = stale_receive_rejected,
        .stale_send_rejected = stale_send_rejected,
        .stale_close_rejected = stale_close_rejected,
        .final_registered_endpoints = device.udp_endpoint_count,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .ingress_dropped = device.software_rx_queue.dropped,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
        .unmatched_dropped = device.unmatched_udp_packets_dropped,
        .tx_queue_enqueues = tx_queue_enqueues,
        .tx_queue_dequeues = tx_queue_dequeues,
        .rx_queue_enqueues = rx_queue_enqueues,
        .rx_queue_dequeues = rx_queue_dequeues,
        .completion_queue_overflows = completion_queue_overflows,
        .tx_pending_mask = final_tx_pending,
        .rx_pending_mask = final_rx_pending,
    };
}

fn verifyUdpTransmitWrap(device: *Device) ?UdpTransmitWrapReport {
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (socket.endpoint_index != 2 or socket.generation != 22 or socket.local_port != 49_163 or
        device.next_ephemeral_udp_port != 49_164 or device.next_udp_generation != 23 or
        device.next_udp_identification != 4 or device.udp_endpoint_count != 3 or
        device.tx_producer != 7)
    {
        return null;
    }
    const peer = UdpPeer{
        .mac = device.gateway_mac,
        .ipv4 = device.gateway_ipv4,
        .port = 9,
    };
    if (!connectUdpSocket(device, socket, peer)) return null;

    const payload = [_]u8{ 0x57, 0x52, 0x41, 0x50 };
    const submissions_before = device.tx_submissions;
    const wraps_before = device.tx_cursor_wraps;
    const first = sendConnectedUdpDatagram(device, socket, 64, &payload) orelse return null;
    const second = sendConnectedUdpDatagram(device, socket, 64, &payload) orelse return null;
    const identifications = [_]u16{ first.identification, second.identification };
    const descriptors = [_]u16{ first.completion.descriptor_index, second.completion.descriptor_index };
    const next_cursors = [_]u16{ first.completion.next_cursor, second.completion.next_cursor };
    const frame_lengths = [_]u16{ first.completion.frame_length, second.completion.frame_length };
    if (!std.mem.eql(u16, &identifications, &[_]u16{ 4, 5 }) or
        !std.mem.eql(u16, &descriptors, &[_]u16{ 7, 0 }) or
        !std.mem.eql(u16, &next_cursors, &[_]u16{ 0, 1 }) or
        !std.mem.eql(u16, &frame_lengths, &[_]u16{ 60, 60 }) or
        device.next_udp_identification != 6 or device.tx_producer != 1 or
        device.tx_cursor_wraps != wraps_before + 1 or device.tx_submissions != submissions_before + 2)
    {
        return null;
    }

    const tx_completion_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_completion_dequeues = completionQueueDequeued(&tx_completion_queue);
    const completion_overflow = completionQueueOverflow(&tx_completion_queue) +
        completionQueueOverflow(&rx_completion_queue);
    const final_tx_pending = @atomicLoad(u32, &tx_pending_mask, .acquire);
    const final_rx_pending = @atomicLoad(u32, &rx_pending_mask, .acquire);
    if (tx_completion_enqueues != 33 or tx_completion_dequeues != 33 or completion_overflow != 0 or
        final_tx_pending != 0 or final_rx_pending != all_rx_descriptors_pending or
        tx_ready_mask != 0 or rx_ready_mask != 0)
    {
        return null;
    }
    if (!closeUdpSocket(device, socket)) return null;
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_164 or
        device.software_rx_queue.enqueued != 46 or device.software_rx_queue.dequeued != 46 or
        device.packets_dispatched != 35 or device.udp_packets_dispatched != 34 or
        device.unmatched_udp_packets_dropped != 3 or device.invalid_udp_packets_dropped != 3 or
        device.peer_mismatch_udp_packets_dropped != 3 or device.unknown_packets_dropped != 0)
    {
        return null;
    }

    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .identifications = identifications,
        .descriptors = descriptors,
        .next_cursors = next_cursors,
        .frame_lengths = frame_lengths,
        .wraps_before = wraps_before,
        .wraps_after = device.tx_cursor_wraps,
        .wrap_delta = device.tx_cursor_wraps - wraps_before,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = tx_completion_enqueues,
        .tx_completion_dequeues = tx_completion_dequeues,
        .completion_overflow = completion_overflow,
        .tx_pending_mask = final_tx_pending,
        .rx_pending_mask = final_rx_pending,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
    };
}

fn verifyUdpPayloadBoundary(device: *Device) ?UdpPayloadBoundaryReport {
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (socket.endpoint_index != 2 or socket.generation != 21 or socket.local_port != 49_162 or
        device.next_ephemeral_udp_port != 49_163 or device.next_udp_generation != 22 or
        device.next_udp_identification != 2 or device.udp_endpoint_count != 3 or
        device.tx_producer != 5)
    {
        return null;
    }
    const peer = UdpPeer{
        .mac = device.gateway_mac,
        .ipv4 = device.gateway_ipv4,
        .port = 9,
    };
    if (!connectUdpSocket(device, socket, peer)) return null;

    var oversized_payload = std.mem.zeroes([maximum_udp_payload_bytes + 1]u8);
    @memset(&oversized_payload, 0xEE);
    const submissions_before = device.tx_submissions;
    const wraps_before = device.tx_cursor_wraps;
    const completion_before = completionQueueEnqueued(&tx_completion_queue);
    const oversized_rejected = sendConnectedUdpDatagram(device, socket, 64, &oversized_payload) == null;
    const cursor_preserved_on_rejection = oversized_rejected and
        device.next_udp_identification == 2 and device.tx_producer == 5 and
        device.tx_submissions == submissions_before and
        completionQueueEnqueued(&tx_completion_queue) == completion_before;
    if (!cursor_preserved_on_rejection) return null;

    var maximum_payload = std.mem.zeroes([maximum_udp_payload_bytes]u8);
    for (&maximum_payload, 0..) |*byte, index| byte.* = @truncate(index);
    const maximum = sendConnectedUdpDatagram(device, socket, 64, &maximum_payload) orelse return null;
    const empty_payload = [_]u8{};
    const empty = sendConnectedUdpDatagram(device, socket, 64, &empty_payload) orelse return null;
    if (maximum.identification != 2 or maximum.completion.descriptor_index != 5 or
        maximum.completion.next_cursor != 6 or maximum.completion.frame_length != maximum_ethernet_frame_bytes or
        empty.identification != 3 or empty.completion.descriptor_index != 6 or
        empty.completion.next_cursor != 7 or empty.completion.frame_length != ethernet_minimum_frame_bytes or
        device.next_udp_identification != 4 or device.tx_producer != 7 or
        device.tx_submissions != submissions_before + 2 or device.tx_cursor_wraps != wraps_before)
    {
        return null;
    }

    const tx_completion_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_completion_dequeues = completionQueueDequeued(&tx_completion_queue);
    const completion_overflow = completionQueueOverflow(&tx_completion_queue) +
        completionQueueOverflow(&rx_completion_queue);
    if (tx_completion_enqueues != 31 or tx_completion_dequeues != 31 or completion_overflow != 0 or
        @atomicLoad(u32, &tx_pending_mask, .acquire) != 0 or
        @atomicLoad(u32, &rx_pending_mask, .acquire) != all_rx_descriptors_pending or
        tx_ready_mask != 0 or rx_ready_mask != 0)
    {
        return null;
    }
    if (!closeUdpSocket(device, socket)) return null;
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_163 or
        device.software_rx_queue.enqueued != 46 or device.software_rx_queue.dequeued != 46 or
        device.packets_dispatched != 35 or device.udp_packets_dispatched != 34 or
        device.unmatched_udp_packets_dropped != 3 or device.invalid_udp_packets_dropped != 3 or
        device.peer_mismatch_udp_packets_dropped != 3 or device.unknown_packets_dropped != 0)
    {
        return null;
    }

    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .maximum_payload_bytes = maximum_udp_payload_bytes,
        .oversized_payload_bytes = maximum_udp_payload_bytes + 1,
        .oversized_rejected = oversized_rejected,
        .cursor_preserved_on_rejection = cursor_preserved_on_rejection,
        .maximum_identification = maximum.identification,
        .maximum_descriptor = maximum.completion.descriptor_index,
        .maximum_next_cursor = maximum.completion.next_cursor,
        .maximum_frame_length = maximum.completion.frame_length,
        .empty_identification = empty.identification,
        .empty_descriptor = empty.completion.descriptor_index,
        .empty_next_cursor = empty.completion.next_cursor,
        .empty_frame_length = empty.completion.frame_length,
        .final_identification_cursor = device.next_udp_identification,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = tx_completion_enqueues,
        .tx_completion_dequeues = tx_completion_dequeues,
        .completion_overflow = completion_overflow,
        .final_tx_cursor = device.tx_producer,
        .tx_wraps_unchanged = device.tx_cursor_wraps == wraps_before,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
    };
}

fn verifyUdpAutomaticIdentification(device: *Device) ?UdpAutomaticIdentificationReport {
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (socket.endpoint_index != 2 or socket.generation != 20 or socket.local_port != 49_161 or
        device.next_ephemeral_udp_port != 49_162 or device.next_udp_generation != 21 or
        device.next_udp_identification != 0x7000 or device.udp_endpoint_count != 3 or
        device.tx_producer != 1)
    {
        return null;
    }

    const payload = [_]u8{ 0x49, 0x44, 0x21 };
    const initial_identification = device.next_udp_identification;
    const submissions_before = device.tx_submissions;
    const unconnected_rejected = sendConnectedUdpDatagram(device, socket, 64, &payload) == null;
    const cursor_after_unconnected = device.next_udp_identification;
    const peer = UdpPeer{
        .mac = device.gateway_mac,
        .ipv4 = device.gateway_ipv4,
        .port = 9,
    };
    if (!connectUdpSocket(device, socket, peer)) return null;
    const zero_ttl_rejected = sendConnectedUdpDatagram(device, socket, 0, &payload) == null;
    const cursor_preserved_on_failure = unconnected_rejected and zero_ttl_rejected and
        cursor_after_unconnected == initial_identification and
        device.next_udp_identification == initial_identification and
        device.tx_submissions == submissions_before and device.tx_producer == 1;
    if (!cursor_preserved_on_failure) return null;

    var identifications = std.mem.zeroes([4]u16);
    var descriptors = std.mem.zeroes([4]u16);
    var next_cursors = std.mem.zeroes([4]u16);
    var frame_lengths = std.mem.zeroes([4]u16);

    const first = sendConnectedUdpDatagram(device, socket, 64, &payload) orelse return null;
    const second = sendConnectedUdpDatagram(device, socket, 64, &payload) orelse return null;
    device.next_udp_identification = 0xFFFF;
    const wrap = sendConnectedUdpDatagram(device, socket, 64, &payload) orelse return null;
    const post_wrap = sendConnectedUdpDatagram(device, socket, 64, &payload) orelse return null;
    const sends = [_]UdpTransmitResult{ first, second, wrap, post_wrap };
    for (sends, 0..) |send, index| {
        identifications[index] = send.identification;
        descriptors[index] = send.completion.descriptor_index;
        next_cursors[index] = send.completion.next_cursor;
        frame_lengths[index] = send.completion.frame_length;
    }
    if (!std.mem.eql(u16, &identifications, &[_]u16{ 0x7000, 0x7001, 0xFFFF, 1 }) or
        !std.mem.eql(u16, &descriptors, &[_]u16{ 1, 2, 3, 4 }) or
        !std.mem.eql(u16, &next_cursors, &[_]u16{ 2, 3, 4, 5 }) or
        !std.mem.eql(u16, &frame_lengths, &[_]u16{ 60, 60, 60, 60 }) or
        device.next_udp_identification != 2 or device.tx_producer != 5 or
        device.tx_submissions != submissions_before + 4)
    {
        return null;
    }

    const tx_completion_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_completion_dequeues = completionQueueDequeued(&tx_completion_queue);
    const completion_overflow = completionQueueOverflow(&tx_completion_queue) +
        completionQueueOverflow(&rx_completion_queue);
    const final_tx_pending = @atomicLoad(u32, &tx_pending_mask, .acquire);
    const final_rx_pending = @atomicLoad(u32, &rx_pending_mask, .acquire);
    if (tx_completion_enqueues != 29 or tx_completion_dequeues != 29 or
        completion_overflow != 0 or final_tx_pending != 0 or
        final_rx_pending != all_rx_descriptors_pending or tx_ready_mask != 0 or rx_ready_mask != 0)
    {
        return null;
    }
    if (!closeUdpSocket(device, socket)) return null;
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_162 or
        device.software_rx_queue.enqueued != 46 or device.software_rx_queue.dequeued != 46 or
        device.packets_dispatched != 35 or device.udp_packets_dispatched != 34 or
        device.unmatched_udp_packets_dropped != 3 or device.invalid_udp_packets_dropped != 3 or
        device.peer_mismatch_udp_packets_dropped != 3 or device.unknown_packets_dropped != 0)
    {
        return null;
    }

    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .peer_port = peer.port,
        .unconnected_rejected = unconnected_rejected,
        .zero_ttl_rejected = zero_ttl_rejected,
        .cursor_preserved_on_failure = cursor_preserved_on_failure,
        .identifications = identifications,
        .descriptors = descriptors,
        .next_cursors = next_cursors,
        .frame_lengths = frame_lengths,
        .final_identification_cursor = device.next_udp_identification,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = tx_completion_enqueues,
        .tx_completion_dequeues = tx_completion_dequeues,
        .completion_overflow = completion_overflow,
        .tx_pending_mask = final_tx_pending,
        .rx_pending_mask = final_rx_pending,
        .final_tx_cursor = device.tx_producer,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
    };
}

fn verifyUdpFairService(device: *Device) ?UdpFairServiceReport {
    const first = openEphemeralUdpSocket(device) orelse return null;
    const second = openEphemeralUdpSocket(device) orelse return null;
    if (first.endpoint_index != 2 or first.generation != 18 or first.local_port != 49_159 or
        second.endpoint_index != 3 or second.generation != 19 or second.local_port != 49_160 or
        device.next_ephemeral_udp_port != 49_161 or device.next_udp_generation != 20 or
        device.next_udp_ready_index != 0 or device.udp_endpoint_count != 4)
    {
        return null;
    }

    var packet_index: u16 = 0;
    while (packet_index < 4) : (packet_index += 1) {
        const target = if (packet_index < 2) first else second;
        var frame = std.mem.zeroes([ethernet_minimum_frame_bytes]u8);
        const payload = [_]u8{ 0x46, @intCast(packet_index) };
        const frame_length = udp.buildFrame(&frame, .{
            .source_mac = device.gateway_mac,
            .destination_mac = device.local_mac,
            .source_ipv4 = device.gateway_ipv4,
            .destination_ipv4 = device.local_ipv4,
            .source_port = peer_filter_source_port,
            .destination_port = target.local_port,
            .identification = 0x6100 + packet_index,
            .payload = &payload,
        }) orelse return null;
        var packet = std.mem.zeroes(Packet);
        packet.length = frame_length;
        packet.source_descriptor = 0xF800 + packet_index;
        @memcpy(packet.bytes[0..frame_length], frame[0..frame_length]);
        if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return null;
    }

    const initial = serviceUdpSocketsFair(device, 4, 0);
    if (initial.dispatch.examined != 4 or initial.dispatch.routed != 4 or
        initial.dispatch.dropped != 0 or initial.dispatch.remaining != 0 or
        initial.ready.count != 0 or initial.ready.total_pending != 0 or
        device.next_udp_ready_index != 0)
    {
        return null;
    }

    var selection_slots = std.mem.zeroes([4]u16);
    var selection_generations = std.mem.zeroes([4]u32);
    var selection_payload_indexes = std.mem.zeroes([4]u8);
    var ready_cursors_after = std.mem.zeroes([4]u8);
    var selection_index: usize = 0;
    while (selection_index < 4) : (selection_index += 1) {
        const cycle = serviceUdpSocketsFair(device, 0, 1);
        if (cycle.dispatch.examined != 0 or cycle.ready.count != 1) return null;
        const socket = cycle.ready.sockets[0];
        const datagram = receiveUdpDatagram(device, socket) orelse return null;
        const payload = datagram.payload();
        if (payload.len != 2 or payload[0] != 0x46) return null;
        selection_slots[selection_index] = socket.endpoint_index;
        selection_generations[selection_index] = socket.generation;
        selection_payload_indexes[selection_index] = payload[1];
        ready_cursors_after[selection_index] = device.next_udp_ready_index;
    }
    if (!std.mem.eql(u16, &selection_slots, &[_]u16{ 2, 3, 2, 3 }) or
        !std.mem.eql(u32, &selection_generations, &[_]u32{ 18, 19, 18, 19 }) or
        !std.mem.eql(u8, &selection_payload_indexes, &[_]u8{ 0, 2, 1, 3 }) or
        !std.mem.eql(u8, &ready_cursors_after, &[_]u8{ 3, 0, 3, 0 }))
    {
        return null;
    }

    const empty = serviceUdpSocketsFair(device, 0, 1);
    if (empty.dispatch.examined != 0 or empty.ready.count != 0 or empty.ready.total_pending != 0 or
        device.next_udp_ready_index != 0)
    {
        return null;
    }
    if (!closeUdpSocket(device, second) or !closeUdpSocket(device, first)) return null;
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_161 or
        device.next_udp_ready_index != 0 or
        device.software_rx_queue.enqueued != 46 or device.software_rx_queue.dequeued != 46 or
        device.software_rx_queue.dropped != 0 or device.software_rx_queue.head != device.software_rx_queue.tail or
        device.packets_dispatched != 35 or device.udp_packets_dispatched != 34 or
        device.unmatched_udp_packets_dropped != 3 or device.invalid_udp_packets_dropped != 3 or
        device.peer_mismatch_udp_packets_dropped != 3 or device.unknown_packets_dropped != 0)
    {
        return null;
    }

    return .{
        .first_slot = first.endpoint_index,
        .first_generation = first.generation,
        .first_port = first.local_port,
        .second_slot = second.endpoint_index,
        .second_generation = second.generation,
        .second_port = second.local_port,
        .initial_dispatch_examined = initial.dispatch.examined,
        .initial_dispatch_routed = initial.dispatch.routed,
        .initial_ready_count = initial.ready.count,
        .initial_total_pending = 4,
        .selection_slots = selection_slots,
        .selection_generations = selection_generations,
        .selection_payload_indexes = selection_payload_indexes,
        .ready_cursors_after = ready_cursors_after,
        .empty_ready_count = empty.ready.count,
        .final_ready_cursor = device.next_udp_ready_index,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyUdpServiceCycle(device: *Device) ?UdpServiceCycleReport {
    const first = openEphemeralUdpSocket(device) orelse return null;
    const second = openEphemeralUdpSocket(device) orelse return null;
    if (first.endpoint_index != 2 or first.generation != 16 or first.local_port != 49_157 or
        second.endpoint_index != 3 or second.generation != 17 or second.local_port != 49_158 or
        device.next_ephemeral_udp_port != 49_159 or device.udp_endpoint_count != 4)
    {
        return null;
    }

    var packet_index: u16 = 0;
    while (packet_index < 4) : (packet_index += 1) {
        const destination_port: u16 = switch (packet_index) {
            0, 1 => first.local_port,
            2 => second.local_port,
            else => unmatched_udp_port - 2,
        };
        var frame = std.mem.zeroes([ethernet_minimum_frame_bytes]u8);
        const payload = [_]u8{ 0x53, @intCast(packet_index) };
        const frame_length = udp.buildFrame(&frame, .{
            .source_mac = device.gateway_mac,
            .destination_mac = device.local_mac,
            .source_ipv4 = device.gateway_ipv4,
            .destination_ipv4 = device.local_ipv4,
            .source_port = peer_filter_source_port,
            .destination_port = destination_port,
            .identification = 0x6000 + packet_index,
            .payload = &payload,
        }) orelse return null;
        if (packet_index == 1) frame[14 + ipv4_header_bytes + 8] ^= 0x01;
        var packet = std.mem.zeroes(Packet);
        packet.length = frame_length;
        packet.source_descriptor = 0xF900 + packet_index;
        @memcpy(packet.bytes[0..frame_length], frame[0..frame_length]);
        if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return null;
    }

    const first_cycle = serviceUdpSockets(device, 3);
    if (first_cycle.dispatch.examined != 3 or first_cycle.dispatch.routed != 2 or
        first_cycle.dispatch.dropped != 1 or first_cycle.dispatch.remaining != 1 or
        first_cycle.ready.count != 2 or first_cycle.ready.total_pending != 2)
    {
        return null;
    }
    const ready_first = first_cycle.ready.sockets[0];
    const ready_second = first_cycle.ready.sockets[1];
    if (!std.meta.eql(ready_first, first) or !std.meta.eql(ready_second, second)) return null;

    const second_cycle = serviceUdpSockets(device, 4);
    if (second_cycle.dispatch.examined != 1 or second_cycle.dispatch.routed != 0 or
        second_cycle.dispatch.dropped != 1 or second_cycle.dispatch.remaining != 0 or
        second_cycle.ready.count != 2 or second_cycle.ready.total_pending != 2 or
        !std.meta.eql(second_cycle.ready.sockets[0], first) or
        !std.meta.eql(second_cycle.ready.sockets[1], second))
    {
        return null;
    }

    const first_datagram = receiveUdpDatagram(device, ready_first) orelse return null;
    const second_datagram = receiveUdpDatagram(device, ready_second) orelse return null;
    const first_payload = first_datagram.payload();
    const second_payload = second_datagram.payload();
    if (first_payload.len != 2 or first_payload[0] != 0x53 or first_payload[1] != 0 or
        second_payload.len != 2 or second_payload[0] != 0x53 or second_payload[1] != 2)
    {
        return null;
    }

    const drained_cycle = serviceUdpSockets(device, 4);
    if (drained_cycle.dispatch.examined != 0 or drained_cycle.dispatch.routed != 0 or
        drained_cycle.dispatch.dropped != 0 or drained_cycle.dispatch.remaining != 0 or
        drained_cycle.ready.count != 0 or drained_cycle.ready.total_pending != 0)
    {
        return null;
    }
    if (!closeUdpSocket(device, second) or !closeUdpSocket(device, first)) return null;
    const stale_first_rejected = !udpSocketActive(device, ready_first) and
        receiveUdpDatagram(device, ready_first) == null;
    const stale_second_rejected = !udpSocketActive(device, ready_second) and
        receiveUdpDatagram(device, ready_second) == null;
    if (!stale_first_rejected or !stale_second_rejected) return null;
    const final_cycle = serviceUdpSockets(device, 4);
    if (final_cycle.dispatch.examined != 0 or final_cycle.ready.count != 0 or
        device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_159 or
        device.next_udp_generation != 18 or
        device.software_rx_queue.enqueued != 42 or device.software_rx_queue.dequeued != 42 or
        device.software_rx_queue.dropped != 0 or device.software_rx_queue.head != device.software_rx_queue.tail or
        device.packets_dispatched != 31 or device.udp_packets_dispatched != 30 or
        device.unmatched_udp_packets_dropped != 3 or device.invalid_udp_packets_dropped != 3 or
        device.peer_mismatch_udp_packets_dropped != 3 or device.unknown_packets_dropped != 0)
    {
        return null;
    }

    return .{
        .first_slot = first.endpoint_index,
        .first_generation = first.generation,
        .first_port = first.local_port,
        .second_slot = second.endpoint_index,
        .second_generation = second.generation,
        .second_port = second.local_port,
        .first_examined = first_cycle.dispatch.examined,
        .first_routed = first_cycle.dispatch.routed,
        .first_dropped = first_cycle.dispatch.dropped,
        .first_remaining = first_cycle.dispatch.remaining,
        .first_ready_count = first_cycle.ready.count,
        .first_total_pending = first_cycle.ready.total_pending,
        .second_examined = second_cycle.dispatch.examined,
        .second_routed = second_cycle.dispatch.routed,
        .second_dropped = second_cycle.dispatch.dropped,
        .second_remaining = second_cycle.dispatch.remaining,
        .second_ready_count = second_cycle.ready.count,
        .second_total_pending = second_cycle.ready.total_pending,
        .drained_examined = drained_cycle.dispatch.examined,
        .drained_ready_count = drained_cycle.ready.count,
        .delivered_datagrams = 2,
        .stale_first_rejected = stale_first_rejected,
        .stale_second_rejected = stale_second_rejected,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
        .unmatched_dropped = device.unmatched_udp_packets_dropped,
        .invalid_udp_dropped = device.invalid_udp_packets_dropped,
    };
}

fn verifyUdpEndpointPoll(device: *Device) ?UdpEndpointPollReport {
    const first = openEphemeralUdpSocket(device) orelse return null;
    const second = openEphemeralUdpSocket(device) orelse return null;
    if (first.endpoint_index != 2 or first.generation != 14 or first.local_port != 49_155 or
        second.endpoint_index != 3 or second.generation != 15 or second.local_port != 49_156 or
        device.next_ephemeral_udp_port != 49_157 or device.udp_endpoint_count != 4)
    {
        return null;
    }
    const peer = UdpPeer{
        .mac = device.gateway_mac,
        .ipv4 = device.gateway_ipv4,
        .port = peer_filter_source_port,
    };
    if (!connectUdpSocket(device, second, peer)) return null;

    var packet_index: u16 = 0;
    while (packet_index < 3) : (packet_index += 1) {
        const target = if (packet_index < 2) first else second;
        var frame = std.mem.zeroes([ethernet_minimum_frame_bytes]u8);
        const payload = [_]u8{ 0x50, @intCast(packet_index) };
        const frame_length = udp.buildFrame(&frame, .{
            .source_mac = peer.mac,
            .destination_mac = device.local_mac,
            .source_ipv4 = peer.ipv4,
            .destination_ipv4 = device.local_ipv4,
            .source_port = peer.port,
            .destination_port = target.local_port,
            .identification = 0x5F00 + packet_index,
            .payload = &payload,
        }) orelse return null;
        var packet = std.mem.zeroes(Packet);
        packet.length = frame_length;
        packet.source_descriptor = 0xFA00 + packet_index;
        @memcpy(packet.bytes[0..frame_length], frame[0..frame_length]);
        if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return null;
    }
    const dispatch = dispatchPacketBatch(device, 3);
    if (dispatch.examined != 3 or dispatch.routed != 3 or dispatch.dropped != 0 or dispatch.remaining != 0) return null;

    const initial = pollUdpEndpoints(device);
    if (initial.active_mask != 0x0F or initial.readable_mask != 0x0C or
        initial.connected_mask != 0x0A or initial.active_count != 4 or
        initial.readable_count != 2 or initial.connected_count != 2 or
        initial.total_pending != 3 or initial.max_pending != 2)
    {
        return null;
    }

    const first_datagram = receiveUdpDatagram(device, first) orelse return null;
    const first_payload = first_datagram.payload();
    if (first_payload.len != 2 or first_payload[0] != 0x50 or first_payload[1] != 0) return null;
    const partial = pollUdpEndpoints(device);
    if (partial.active_mask != 0x0F or partial.readable_mask != 0x0C or
        partial.connected_mask != 0x0A or partial.total_pending != 2 or partial.max_pending != 1)
    {
        return null;
    }

    const remaining_first = receiveUdpDatagram(device, first) orelse return null;
    const remaining_second = receiveUdpDatagram(device, second) orelse return null;
    const first_remaining_payload = remaining_first.payload();
    const second_payload = remaining_second.payload();
    if (first_remaining_payload.len != 2 or first_remaining_payload[1] != 1 or
        second_payload.len != 2 or second_payload[1] != 2)
    {
        return null;
    }
    const drained = pollUdpEndpoints(device);
    if (drained.active_mask != 0x0F or drained.readable_mask != 0 or
        drained.connected_mask != 0x0A or drained.total_pending != 0 or drained.max_pending != 0)
    {
        return null;
    }

    if (!closeUdpSocket(device, second) or !closeUdpSocket(device, first)) return null;
    const final = pollUdpEndpoints(device);
    if (final.active_mask != 0x03 or final.readable_mask != 0 or final.connected_mask != 0x02 or
        final.active_count != 2 or final.readable_count != 0 or final.connected_count != 1 or
        final.total_pending != 0 or final.max_pending != 0 or device.udp_endpoint_count != 2 or
        device.next_ephemeral_udp_port != 49_157 or device.next_udp_generation != 16 or
        device.software_rx_queue.enqueued != 38 or device.software_rx_queue.dequeued != 38 or
        device.software_rx_queue.dropped != 0 or device.software_rx_queue.head != device.software_rx_queue.tail or
        device.packets_dispatched != 29 or device.udp_packets_dispatched != 28 or
        device.unmatched_udp_packets_dropped != 2 or device.invalid_udp_packets_dropped != 2 or
        device.peer_mismatch_udp_packets_dropped != 3 or device.unknown_packets_dropped != 0)
    {
        return null;
    }

    return .{
        .first_slot = first.endpoint_index,
        .first_generation = first.generation,
        .first_port = first.local_port,
        .second_slot = second.endpoint_index,
        .second_generation = second.generation,
        .second_port = second.local_port,
        .initial_active_mask = initial.active_mask,
        .initial_readable_mask = initial.readable_mask,
        .initial_connected_mask = initial.connected_mask,
        .initial_total_pending = initial.total_pending,
        .initial_max_pending = initial.max_pending,
        .partial_readable_mask = partial.readable_mask,
        .partial_total_pending = partial.total_pending,
        .drained_readable_mask = drained.readable_mask,
        .drained_total_pending = drained.total_pending,
        .final_active_mask = final.active_mask,
        .final_readable_mask = final.readable_mask,
        .final_connected_mask = final.connected_mask,
        .final_total_pending = final.total_pending,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyUdpDispatchBatch(device: *Device) ?UdpDispatchBatchReport {
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (socket.endpoint_index != 2 or socket.generation != 13 or socket.local_port != 49_154 or
        device.next_ephemeral_udp_port != 49_155 or device.udp_endpoint_count != 3)
    {
        return null;
    }

    var packet_index: u16 = 0;
    while (packet_index < 5) : (packet_index += 1) {
        var frame = std.mem.zeroes([ethernet_minimum_frame_bytes]u8);
        const payload = [_]u8{ 0x42, @intCast(packet_index) };
        const destination_port: u16 = if (packet_index == 1) unmatched_udp_port - 1 else socket.local_port;
        const frame_length = udp.buildFrame(&frame, .{
            .source_mac = device.gateway_mac,
            .destination_mac = device.local_mac,
            .source_ipv4 = device.gateway_ipv4,
            .destination_ipv4 = device.local_ipv4,
            .source_port = peer_filter_source_port,
            .destination_port = destination_port,
            .identification = 0x5E00 + packet_index,
            .payload = &payload,
        }) orelse return null;
        if (packet_index == 2) frame[14 + ipv4_header_bytes + 8] ^= 0x01;
        var packet = std.mem.zeroes(Packet);
        packet.length = frame_length;
        packet.source_descriptor = 0xFE00 + packet_index;
        @memcpy(packet.bytes[0..frame_length], frame[0..frame_length]);
        if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return null;
    }

    const initial_ingress_depth = queueDepth(&device.software_rx_queue);
    const zero = dispatchPacketBatch(device, 0);
    if (zero.examined != 0 or zero.routed != 0 or zero.dropped != 0 or zero.remaining != 5) return null;
    const first = dispatchPacketBatch(device, 2);
    if (first.examined != 2 or first.routed != 1 or first.dropped != 1 or first.remaining != 3) return null;
    const second = dispatchPacketBatch(device, 2);
    if (second.examined != 2 or second.routed != 1 or second.dropped != 1 or second.remaining != 1) return null;
    const final = dispatchPacketBatch(device, 10);
    if (final.examined != 1 or final.routed != 1 or final.dropped != 0 or final.remaining != 0) return null;
    const empty = dispatchPacketBatch(device, 10);
    if (empty.examined != 0 or empty.routed != 0 or empty.dropped != 0 or empty.remaining != 0) return null;

    const status = inspectUdpSocket(device, socket) orelse return null;
    if (status.pending_packets != 3 or status.high_water != 3 or status.enqueued != 3 or status.dequeued != 0) return null;
    const expected_payload_indexes = [_]u8{ 0, 3, 4 };
    var delivered: u16 = 0;
    for (expected_payload_indexes) |expected_index| {
        const datagram = receiveUdpDatagram(device, socket) orelse return null;
        const payload = datagram.payload();
        if (payload.len != 2 or payload[0] != 0x42 or payload[1] != expected_index) return null;
        delivered +|= 1;
    }
    if (receiveUdpDatagram(device, socket) != null or udpSocketReadable(device, socket)) return null;
    if (!closeUdpSocket(device, socket)) return null;
    if (device.udp_endpoint_count != 2 or
        device.software_rx_queue.enqueued != 35 or device.software_rx_queue.dequeued != 35 or
        device.software_rx_queue.dropped != 0 or device.software_rx_queue.head != device.software_rx_queue.tail or
        device.packets_dispatched != 26 or device.udp_packets_dispatched != 25 or
        device.unmatched_udp_packets_dropped != 2 or device.invalid_udp_packets_dropped != 2 or
        device.peer_mismatch_udp_packets_dropped != 3 or device.unknown_packets_dropped != 0)
    {
        return null;
    }

    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .initial_ingress_depth = initial_ingress_depth,
        .first_examined = first.examined,
        .first_routed = first.routed,
        .first_dropped = first.dropped,
        .first_remaining = first.remaining,
        .second_examined = second.examined,
        .second_routed = second.routed,
        .second_dropped = second.dropped,
        .second_remaining = second.remaining,
        .final_examined = final.examined,
        .final_routed = final.routed,
        .final_dropped = final.dropped,
        .final_remaining = final.remaining,
        .empty_examined = empty.examined,
        .empty_remaining = empty.remaining,
        .delivered_datagrams = delivered,
        .endpoint_high_water = status.high_water,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
        .unmatched_dropped = device.unmatched_udp_packets_dropped,
        .invalid_udp_dropped = device.invalid_udp_packets_dropped,
        .final_registered_endpoints = device.udp_endpoint_count,
    };
}

fn verifyUdpSocketQueueControl(device: *Device) ?UdpSocketQueueReport {
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (socket.endpoint_index != 2 or socket.generation != 12 or socket.local_port != 49_153 or
        device.next_ephemeral_udp_port != 49_154 or device.udp_endpoint_count != 3)
    {
        return null;
    }
    const peer = UdpPeer{
        .mac = device.gateway_mac,
        .ipv4 = device.gateway_ipv4,
        .port = peer_filter_source_port,
    };
    if (!connectUdpSocket(device, socket, peer)) return null;

    var packet_index: u16 = 0;
    while (packet_index < 3) : (packet_index += 1) {
        var frame = std.mem.zeroes([ethernet_minimum_frame_bytes]u8);
        const payload = [_]u8{ 0x51, @intCast(packet_index) };
        const frame_length = udp.buildFrame(&frame, .{
            .source_mac = peer.mac,
            .destination_mac = device.local_mac,
            .source_ipv4 = peer.ipv4,
            .destination_ipv4 = device.local_ipv4,
            .source_port = peer.port,
            .destination_port = socket.local_port,
            .identification = 0x5D00 + packet_index,
            .payload = &payload,
        }) orelse return null;
        var packet = std.mem.zeroes(Packet);
        packet.length = frame_length;
        packet.source_descriptor = 0xFD00 + packet_index;
        @memcpy(packet.bytes[0..frame_length], frame[0..frame_length]);
        if (!enqueueQueuedPacket(&device.software_rx_queue, packet) or !dispatchNextPacket(device)) return null;
    }

    const before = inspectUdpSocket(device, socket) orelse return null;
    const readable_before_discard = udpSocketReadable(device, socket);
    const disconnect_while_pending_rejected = !disconnectUdpSocket(device, socket);
    if (before.local_port != socket.local_port or before.generation != socket.generation or
        !before.connected or before.peer_port != peer.port or before.pending_packets != 3 or
        before.usable_capacity != software_packet_queue_capacity - 1 or
        before.enqueued != 3 or before.dequeued != 0 or before.dropped != 0 or before.high_water != 3 or
        !readable_before_discard or !disconnect_while_pending_rejected)
    {
        return null;
    }

    const discarded = discardUdpSocketPackets(device, socket) orelse return null;
    const after = inspectUdpSocket(device, socket) orelse return null;
    const readable_after_discard = udpSocketReadable(device, socket);
    if (discarded != 3 or after.pending_packets != 0 or after.enqueued != 3 or after.dequeued != 3 or
        after.high_water != 3 or after.dropped != 0 or readable_after_discard)
    {
        return null;
    }
    if (!disconnectUdpSocket(device, socket) or !closeUdpSocket(device, socket)) return null;
    const stale_status_rejected = inspectUdpSocket(device, socket) == null;
    const stale_discard_rejected = discardUdpSocketPackets(device, socket) == null;
    if (!stale_status_rejected or !stale_discard_rejected or udpSocketReadable(device, socket)) return null;
    if (device.udp_endpoint_count != 2 or
        device.software_rx_queue.enqueued != 30 or device.software_rx_queue.dequeued != 30 or
        device.software_rx_queue.dropped != 0 or device.software_rx_queue.head != device.software_rx_queue.tail or
        device.packets_dispatched != 23 or device.udp_packets_dispatched != 22 or
        device.unmatched_udp_packets_dropped != 1 or device.invalid_udp_packets_dropped != 1 or
        device.peer_mismatch_udp_packets_dropped != 3 or device.unknown_packets_dropped != 0)
    {
        return null;
    }

    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .connected = before.connected,
        .peer_port = before.peer_port,
        .pending_before_discard = before.pending_packets,
        .readable_before_discard = readable_before_discard,
        .disconnect_while_pending_rejected = disconnect_while_pending_rejected,
        .discarded_packets = discarded,
        .pending_after_discard = after.pending_packets,
        .readable_after_discard = readable_after_discard,
        .queue_enqueued = after.enqueued,
        .queue_dequeued = after.dequeued,
        .queue_high_water = after.high_water,
        .queue_dropped = after.dropped,
        .stale_status_rejected = stale_status_rejected,
        .stale_discard_rejected = stale_discard_rejected,
        .final_registered_endpoints = device.udp_endpoint_count,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyUdpEphemeralPorts(device: *Device) ?UdpEphemeralPortReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != ephemeral_udp_port_first) return null;

    const first = openEphemeralUdpSocket(device) orelse return null;
    if (first.endpoint_index != 2 or first.generation != 7 or first.local_port != ephemeral_udp_port_first or
        device.next_ephemeral_udp_port != ephemeral_udp_port_first + 1)
    {
        return null;
    }
    const second = openEphemeralUdpSocket(device) orelse return null;
    if (second.endpoint_index != 3 or second.generation != 8 or second.local_port != ephemeral_udp_port_first + 1 or
        device.next_ephemeral_udp_port != ephemeral_udp_port_first + 2)
    {
        return null;
    }
    const cursor_before_full = device.next_ephemeral_udp_port;
    const full_table_rejected = openEphemeralUdpSocket(device) == null and
        device.next_ephemeral_udp_port == cursor_before_full;
    if (!full_table_rejected) return null;

    if (!closeUdpSocket(device, first)) return null;
    device.next_ephemeral_udp_port = second.local_port;
    const collision = openEphemeralUdpSocket(device) orelse return null;
    const collision_skipped = collision.endpoint_index == first.endpoint_index and
        collision.generation == 9 and collision.local_port == ephemeral_udp_port_first + 2 and
        device.next_ephemeral_udp_port == ephemeral_udp_port_first + 3;
    if (!collision_skipped) return null;
    if (!closeUdpSocket(device, collision) or !closeUdpSocket(device, second)) return null;

    device.next_ephemeral_udp_port = ephemeral_udp_port_last;
    const wrap = openEphemeralUdpSocket(device) orelse return null;
    if (wrap.endpoint_index != 2 or wrap.generation != 10 or wrap.local_port != ephemeral_udp_port_last or
        device.next_ephemeral_udp_port != ephemeral_udp_port_first)
    {
        return null;
    }
    const post_wrap = openEphemeralUdpSocket(device) orelse return null;
    if (post_wrap.endpoint_index != 3 or post_wrap.generation != 11 or
        post_wrap.local_port != ephemeral_udp_port_first or
        device.next_ephemeral_udp_port != ephemeral_udp_port_first + 1)
    {
        return null;
    }
    if (!udpSocketActive(device, wrap) or !udpSocketActive(device, post_wrap)) return null;
    if (!closeUdpSocket(device, post_wrap) or !closeUdpSocket(device, wrap)) return null;
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != ephemeral_udp_port_first + 1 or
        device.next_udp_generation != 12 or
        device.software_rx_queue.enqueued != 27 or device.software_rx_queue.dequeued != 27 or
        device.packets_dispatched != 20 or device.udp_packets_dispatched != 19 or
        device.invalid_udp_packets_dropped != 1 or device.peer_mismatch_udp_packets_dropped != 3)
    {
        return null;
    }

    return .{
        .range_first = ephemeral_udp_port_first,
        .range_last = ephemeral_udp_port_last,
        .first_slot = first.endpoint_index,
        .first_generation = first.generation,
        .first_port = first.local_port,
        .second_slot = second.endpoint_index,
        .second_generation = second.generation,
        .second_port = second.local_port,
        .full_table_rejected = full_table_rejected,
        .collision_skipped = collision_skipped,
        .collision_slot = collision.endpoint_index,
        .collision_generation = collision.generation,
        .collision_port = collision.local_port,
        .wrap_slot = wrap.endpoint_index,
        .wrap_generation = wrap.generation,
        .wrap_port = wrap.local_port,
        .post_wrap_slot = post_wrap.endpoint_index,
        .post_wrap_generation = post_wrap.generation,
        .post_wrap_port = post_wrap.local_port,
        .final_cursor = device.next_ephemeral_udp_port,
        .final_registered_endpoints = device.udp_endpoint_count,
    };
}

fn verifyUdpPeerFiltering(device: *Device) ?UdpPeerFilterReport {
    const socket = openUdpSocket(device, peer_filter_udp_port) orelse return null;
    if (socket.endpoint_index != 2 or socket.generation != 6 or device.udp_endpoint_count != 3) return null;
    const endpoint = &device.udp_endpoints[socket.endpoint_index];
    const peer = UdpPeer{
        .mac = device.gateway_mac,
        .ipv4 = device.gateway_ipv4,
        .port = peer_filter_source_port,
    };
    if (!connectUdpSocket(device, socket, peer)) return null;
    if (!connectUdpSocket(device, socket, peer)) return null;
    const observed_peer = udpSocketPeer(device, socket) orelse return null;
    if (!std.meta.eql(observed_peer, peer)) return null;
    const conflicting_peer = UdpPeer{
        .mac = device.gateway_mac,
        .ipv4 = device.gateway_ipv4,
        .port = peer_filter_alternate_port,
    };
    if (connectUdpSocket(device, socket, conflicting_peer)) return null;

    const payload = [_]u8{ 0x50, 0x45, 0x45, 0x52 };
    var correct_frame = std.mem.zeroes([ethernet_minimum_frame_bytes]u8);
    const correct_length = udp.buildFrame(&correct_frame, .{
        .source_mac = peer.mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = peer.ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = peer.port,
        .destination_port = peer_filter_udp_port,
        .identification = 0x5C00,
        .payload = &payload,
    }) orelse return null;
    var correct_packet = std.mem.zeroes(Packet);
    correct_packet.length = correct_length;
    correct_packet.source_descriptor = 0xFC00;
    @memcpy(correct_packet.bytes[0..correct_length], correct_frame[0..correct_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, correct_packet)) return null;
    const correct_peer_accepted = dispatchNextPacket(device);
    if (!correct_peer_accepted) return null;

    var wrong_mac = peer.mac;
    wrong_mac[5] +%= 1;
    var wrong_mac_frame = std.mem.zeroes([ethernet_minimum_frame_bytes]u8);
    const wrong_mac_length = udp.buildFrame(&wrong_mac_frame, .{
        .source_mac = wrong_mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = peer.ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = peer.port,
        .destination_port = peer_filter_udp_port,
        .identification = 0x5C01,
        .payload = &payload,
    }) orelse return null;
    var wrong_mac_packet = std.mem.zeroes(Packet);
    wrong_mac_packet.length = wrong_mac_length;
    wrong_mac_packet.source_descriptor = 0xFC01;
    @memcpy(wrong_mac_packet.bytes[0..wrong_mac_length], wrong_mac_frame[0..wrong_mac_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, wrong_mac_packet)) return null;
    const wrong_mac_rejected = !dispatchNextPacket(device);
    if (!wrong_mac_rejected) return null;

    var wrong_ipv4 = peer.ipv4;
    wrong_ipv4[3] +%= 1;
    var wrong_ipv4_frame = std.mem.zeroes([ethernet_minimum_frame_bytes]u8);
    const wrong_ipv4_length = udp.buildFrame(&wrong_ipv4_frame, .{
        .source_mac = peer.mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = wrong_ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = peer.port,
        .destination_port = peer_filter_udp_port,
        .identification = 0x5C02,
        .payload = &payload,
    }) orelse return null;
    var wrong_ipv4_packet = std.mem.zeroes(Packet);
    wrong_ipv4_packet.length = wrong_ipv4_length;
    wrong_ipv4_packet.source_descriptor = 0xFC02;
    @memcpy(wrong_ipv4_packet.bytes[0..wrong_ipv4_length], wrong_ipv4_frame[0..wrong_ipv4_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, wrong_ipv4_packet)) return null;
    const wrong_ipv4_rejected = !dispatchNextPacket(device);
    if (!wrong_ipv4_rejected) return null;

    var wrong_port_frame = std.mem.zeroes([ethernet_minimum_frame_bytes]u8);
    const wrong_port_length = udp.buildFrame(&wrong_port_frame, .{
        .source_mac = peer.mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = peer.ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = peer_filter_alternate_port,
        .destination_port = peer_filter_udp_port,
        .identification = 0x5C03,
        .payload = &payload,
    }) orelse return null;
    var wrong_port_packet = std.mem.zeroes(Packet);
    wrong_port_packet.length = wrong_port_length;
    wrong_port_packet.source_descriptor = 0xFC03;
    @memcpy(wrong_port_packet.bytes[0..wrong_port_length], wrong_port_frame[0..wrong_port_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, wrong_port_packet)) return null;
    const wrong_port_rejected = !dispatchNextPacket(device);
    if (!wrong_port_rejected) return null;

    var invalid_frame = correct_frame;
    invalid_frame[14 + ipv4_header_bytes + 8] ^= 0x01;
    var invalid_packet = std.mem.zeroes(Packet);
    invalid_packet.length = correct_length;
    invalid_packet.source_descriptor = 0xFC04;
    @memcpy(invalid_packet.bytes[0..correct_length], invalid_frame[0..correct_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, invalid_packet)) return null;
    const invalid_checksum_rejected = !dispatchNextPacket(device);
    if (!invalid_checksum_rejected) return null;

    const received_correct = receiveUdpSocket(device, socket) orelse return null;
    const correct_datagram = udp.parseFrame(received_correct.bytes[0..received_correct.length], .{
        .destination_mac = device.local_mac,
        .source_mac = peer.mac,
        .destination_ipv4 = device.local_ipv4,
        .source_ipv4 = peer.ipv4,
        .destination_port = peer_filter_udp_port,
        .source_port = peer.port,
    }) orelse return null;
    if (!std.mem.eql(u8, correct_datagram.payload, &payload)) return null;
    if (!disconnectUdpSocket(device, socket) or udpSocketPeer(device, socket) != null) return null;

    const alternate_peer = UdpPeer{
        .mac = wrong_mac,
        .ipv4 = wrong_ipv4,
        .port = peer_filter_alternate_port,
    };
    var alternate_frame = std.mem.zeroes([ethernet_minimum_frame_bytes]u8);
    const alternate_length = udp.buildFrame(&alternate_frame, .{
        .source_mac = alternate_peer.mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = alternate_peer.ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = alternate_peer.port,
        .destination_port = peer_filter_udp_port,
        .identification = 0x5C04,
        .payload = &payload,
    }) orelse return null;
    var alternate_packet = std.mem.zeroes(Packet);
    alternate_packet.length = alternate_length;
    alternate_packet.source_descriptor = 0xFC05;
    @memcpy(alternate_packet.bytes[0..alternate_length], alternate_frame[0..alternate_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, alternate_packet)) return null;
    const wildcard_after_disconnect = dispatchNextPacket(device);
    if (!wildcard_after_disconnect) return null;
    const received_alternate = receiveUdpSocket(device, socket) orelse return null;
    const alternate_datagram = udp.parseFrame(received_alternate.bytes[0..received_alternate.length], .{
        .destination_mac = device.local_mac,
        .source_mac = alternate_peer.mac,
        .destination_ipv4 = device.local_ipv4,
        .source_ipv4 = alternate_peer.ipv4,
        .destination_port = peer_filter_udp_port,
        .source_port = alternate_peer.port,
    }) orelse return null;
    if (!std.mem.eql(u8, alternate_datagram.payload, &payload)) return null;

    const endpoint_enqueued = endpoint.queue.enqueued;
    const endpoint_dequeued = endpoint.queue.dequeued;
    const endpoint_high_water = endpoint.queue.high_water;
    const endpoint_dropped = endpoint.queue.dropped;
    if (!closeUdpSocket(device, socket)) return null;
    if (device.udp_endpoint_count != 2 or
        device.software_rx_queue.enqueued != 27 or device.software_rx_queue.dequeued != 27 or
        device.software_rx_queue.dropped != 0 or device.software_rx_queue.head != device.software_rx_queue.tail or
        device.packets_dispatched != 20 or device.udp_packets_dispatched != 19 or
        device.unmatched_udp_packets_dropped != 1 or device.invalid_udp_packets_dropped != 1 or
        device.peer_mismatch_udp_packets_dropped != 3 or device.unknown_packets_dropped != 0 or
        endpoint_enqueued != 2 or endpoint_dequeued != 2 or endpoint_high_water != 1 or endpoint_dropped != 0)
    {
        return null;
    }

    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .peer_port = peer.port,
        .peer_bound = true,
        .correct_peer_accepted = correct_peer_accepted,
        .wrong_mac_rejected = wrong_mac_rejected,
        .wrong_ipv4_rejected = wrong_ipv4_rejected,
        .wrong_port_rejected = wrong_port_rejected,
        .invalid_checksum_rejected = invalid_checksum_rejected,
        .wildcard_after_disconnect = wildcard_after_disconnect,
        .endpoint_enqueued = endpoint_enqueued,
        .endpoint_dequeued = endpoint_dequeued,
        .endpoint_high_water = endpoint_high_water,
        .endpoint_dropped = endpoint_dropped,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
        .unmatched_dropped = device.unmatched_udp_packets_dropped,
        .invalid_udp_dropped = device.invalid_udp_packets_dropped,
        .peer_mismatch_dropped = device.peer_mismatch_udp_packets_dropped,
        .final_registered_endpoints = device.udp_endpoint_count,
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
    if (maximum_udp_payload_bytes != 1476) @compileError("e1000e UDP payload boundary must remain a full Ethernet frame");
    if (icmp_payload.len != 16) @compileError("ICMP payload must remain deterministic");
    if (icmp_ipv4_total_bytes != 44) @compileError("ICMP IPv4 packet must remain 44 bytes");
    if (icmp_ethernet_frame_bytes != 58) @compileError("ICMP Ethernet payload must fit one padded frame");
}
