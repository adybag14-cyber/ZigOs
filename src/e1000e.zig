const std = @import("std");
const pci = @import("pci.zig");
const memory = @import("memory.zig");
const paging = @import("paging.zig");
const apic = @import("apic.zig");
const dhcp = @import("dhcp.zig");
const udp = @import("udp.zig");
const tftp = @import("tftp.zig");
const dns = @import("dns.zig");
const ntp = @import("ntp.zig");
const time_reference = @import("time_reference.zig");

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

pub const UdpDiscardCloseResult = struct {
    local_port: u16,
    generation: u32,
    was_connected: bool,
    peer_port: u16,
    discarded_packets: u16,
    queue_enqueued: u64,
    queue_dequeued: u64,
    queue_high_water: u16,
    queue_dropped: u64,
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

pub const UdpDatagramInfo = struct {
    source_mac: [6]u8,
    destination_mac: [6]u8,
    source_ipv4: [4]u8,
    destination_ipv4: [4]u8,
    source_port: u16,
    destination_port: u16,
    ttl: u8,
    identification: u16,
    udp_checksum_present: bool,
    payload_length: u16,
};

pub const UdpReceiveIntoResult = struct {
    source_mac: [6]u8,
    destination_mac: [6]u8,
    source_ipv4: [4]u8,
    destination_ipv4: [4]u8,
    source_port: u16,
    destination_port: u16,
    ttl: u8,
    identification: u16,
    udp_checksum_present: bool,
    payload_length: u16,
    copied_length: u16,
    truncated: bool,
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
    next_dns_transaction_id: u16,
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

pub const DnsAResponse = dns.AResponse;

pub const DnsAQueryState = enum(u8) {
    inactive,
    pending,
    resolved,
    not_found,
};

pub const DnsARequest = struct {
    socket: UdpSocket,
    transaction_id: u16,
    name_length: u8,
    name: [dns.maximum_name_bytes]u8,
    transmit: UdpTransmitResult,
    transmissions: u16,
    cancelled: bool,
};

pub const DnsAQueryPoll = struct {
    state: DnsAQueryState,
    examined: u16,
    rejected: u16,
    response: ?DnsAResponse,
};

pub const DnsResolveStart = union(enum) {
    cached: dns.CachedA,
    pending: DnsARequest,
};

pub const DnsCachedOutcomeStart = union(enum) {
    cached: dns.CachedA,
    not_found: u32,
    pending: DnsARequest,
};

pub const DnsResolver = struct {
    active: bool,
    socket: UdpSocket,
    server_ipv4: [4]u8,
    cache: dns.Cache,
};

pub const NtpResponse = ntp.Response;

pub const NtpRequestState = enum(u8) {
    inactive,
    pending,
    resolved,
};

pub const NtpRequest = struct {
    socket: UdpSocket,
    client_timestamp: u64,
    transmit: UdpTransmitResult,
    transmissions: u16,
    cancelled: bool,
};

pub const NtpRequestPoll = struct {
    state: NtpRequestState,
    examined: u16,
    rejected: u16,
    response: ?NtpResponse,
};

pub const NtpClient = struct {
    active: bool,
    socket: UdpSocket,
    server_ipv4: [4]u8,
};

pub const NtpClockPoll = struct {
    poll: NtpRequestPoll,
    apply_result: ?ntp.ClockApplyResult,
};

pub const NtpReferenceClockPoll = struct {
    poll: NtpRequestPoll,
    sample_tick: ?u64,
    apply_result: ?ntp.ClockApplyResult,
};
pub const NtpServiceState = enum(u8) { inactive, idle, awaiting, timed_out };
pub const NtpServiceStartReason = enum(u8) { none, initial, refresh, recovery };
pub const NtpSynchronizationHealth = enum(u8) {
    inactive,
    unsynchronized,
    synchronized,
    holdover,
    expired,
};

pub const NtpServiceHealth = struct {
    state: NtpSynchronizationHealth,
    current_time: ?ntp.UnixTime,
    sample_age_ticks: u64,
    awaiting_response: bool,
    retry_deadline_tick: u64,
    refresh_deadline_tick: u64,
    requests_started: u64,
    retries: u64,
    responses: u64,
    quality_accepted: u64,
    quality_rejected: u64,
    quality_rejection_policy: ntp.QualityRejectionPolicy,
    request_quality_rejections: u8,
    quality_forced_retries: u64,
    step_rejection_policy: ntp.StepRejectionPolicy,
    request_step_rejections: u8,
    discipline_forced_retries: u64,
    step_accepted: u64,
    step_rejected: u64,
    step_invalid_policy_rejected: u64,
    step_stale_rejected: u64,
    step_excessive_forward_rejected: u64,
    request_retry_attempts: u8,
    retry_exhausted: bool,
    retry_limit_hits: u64,
    last_timeout_tick: u64,
    recovery_deadline_tick: u64,
    automatic_recoveries: u8,
    recovery_exhausted: bool,
    recovery_limit_hits: u64,
    recovery_successes: u64,
    source_pool: ?ntp.SourcePool,
    source_rotation_policy: ?ntp.SourceRotationPolicy,
    current_source_index: u8,
    pending_source_index: ?u8,
    current_server_ipv4: [4]u8,
    consecutive_source_failures: u8,
    source_rotations: u64,
};

pub const NtpService = struct {
    active: bool,
    client: NtpClient,
    clock: ntp.ProjectedClock,
    request: NtpRequest,
    request_active: bool,
    quality_policy: ntp.QualityPolicy,
    quality_rejection_policy: ntp.QualityRejectionPolicy,
    step_policy: ntp.ClockStepPolicy,
    step_rejection_policy: ntp.StepRejectionPolicy,
    retry_policy: ntp.RetryPolicy,
    recovery_policy: ?ntp.RecoveryPolicy,
    retry_interval_ticks: u64,
    refresh_interval_ticks: u64,
    retry_deadline_tick: u64,
    refresh_deadline_tick: u64,
    request_retry_attempts: u8,
    retry_exhausted: bool,
    requests_started: u64,
    retries: u64,
    retry_limit_hits: u64,
    last_timeout_tick: u64,
    recovery_deadline_tick: u64,
    automatic_recoveries: u8,
    recovery_exhausted: bool,
    recovery_limit_hits: u64,
    recovery_successes: u64,
    source_pool: ?ntp.SourcePool,
    source_rotation_policy: ?ntp.SourceRotationPolicy,
    current_source_index: u8,
    pending_source_index: ?u8,
    consecutive_source_failures: u8,
    source_rotations: u64,
    responses: u64,
    quality_accepted: u64,
    quality_rejected: u64,
    quality_invalid_policy_rejected: u64,
    quality_stratum_rejected: u64,
    quality_root_delay_rejected: u64,
    quality_root_dispersion_rejected: u64,
    request_quality_rejections: u8,
    quality_forced_retries: u64,
    request_step_rejections: u8,
    discipline_forced_retries: u64,
    step_accepted: u64,
    step_rejected: u64,
    step_invalid_policy_rejected: u64,
    step_stale_rejected: u64,
    step_excessive_forward_rejected: u64,
};

pub const NtpServiceStep = struct {
    state: NtpServiceState,
    poll: NtpRequestPoll,
    transmit: ?UdpTransmitResult,
    sample_tick: ?u64,
    apply_result: ?ntp.ClockApplyResult,
    quality_result: ?ntp.QualityResult,
    quality_rejection_action: ?ntp.QualityRejectionAction,
    quality_rejection_count: u8,
    quality_rejections_remaining: u8,
    step_result: ?ntp.ClockStepResult,
    step_rejection_action: ?ntp.StepRejectionAction,
    step_rejection_count: u8,
    step_rejections_remaining: u8,
    next_retry_interval_ticks: ?u64,
    recovery_state: ?ntp.RecoveryState,
    start_reason: NtpServiceStartReason,
    retried: bool,
    timeout_reached: bool,
    recovery_started: bool,
};

pub const NtpStaleSourceReplyReport = struct {
    source_kind: time_reference.Kind,
    frequency_hz: u64,
    counter_bits: u8,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    source_count: u8,
    previous_source_index: u8,
    current_source_index: u8,
    previous_server: [4]u8,
    current_server: [4]u8,
    transmit_identifications: [2]u16,
    transmit_descriptors: [2]u16,
    transmit_next_cursors: [2]u16,
    recovery_timestamp: u64,
    recovery_started: bool,
    recovery_switched: bool,
    same_socket_preserved: bool,
    old_source_rejected: bool,
    peer_drop_delta: u64,
    old_source_no_sample: bool,
    old_source_clock_preserved: bool,
    old_source_request_preserved: bool,
    accepted_quality_result: ntp.QualityResult,
    accepted_step_result: ntp.ClockStepResult,
    accepted_sample_tick: u64,
    accepted_seconds: u64,
    accepted_fraction: u32,
    accepted_state_clean: bool,
    health_reports_source: bool,
    health_reports_recovery: bool,
    quality_accepted: u64,
    quality_rejected: u64,
    step_accepted: u64,
    step_rejected: u64,
    requests_started: u64,
    retries: u64,
    responses: u64,
    retry_limit_hits: u64,
    recovery_limit_hits: u64,
    recovery_successes: u64,
    close_succeeded: bool,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    final_generation_cursor: u32,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpOperatorSourceFailoverReport = struct {
    source_kind: time_reference.Kind,
    frequency_hz: u64,
    counter_bits: u8,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    source_count: u8,
    operator_source_index: u8,
    fallback_source_index: u8,
    operator_server: [4]u8,
    fallback_server: [4]u8,
    transmit_identifications: [5]u16,
    transmit_descriptors: [5]u16,
    transmit_next_cursors: [5]u16,
    operator_refresh_timestamp: u64,
    automatic_refresh_timestamp: u64,
    recovery_timestamp: u64,
    timestamps_automatic: bool,
    operator_refresh_accepted: bool,
    manual_rotation_preserved: bool,
    automatic_refresh_started: bool,
    retry_timestamp_preserved: bool,
    timeout_waiting: bool,
    timeout_no_tx: bool,
    timeout_pending_source: u8,
    timeout_failure_count: u8,
    cooldown_no_tx: bool,
    recovery_started: bool,
    recovery_switched: bool,
    same_socket_preserved: bool,
    automatic_rotation_count: u64,
    accepted_quality_result: ntp.QualityResult,
    accepted_step_result: ntp.ClockStepResult,
    accepted_sample_tick: u64,
    accepted_seconds: u64,
    accepted_fraction: u32,
    fallback_state_clean: bool,
    health_reports_source: bool,
    health_reports_recovery: bool,
    health_preserves_cumulative: bool,
    quality_accepted: u64,
    quality_rejected: u64,
    step_accepted: u64,
    step_rejected: u64,
    requests_started: u64,
    retries: u64,
    responses: u64,
    retry_limit_hits: u64,
    recovery_limit_hits: u64,
    recovery_successes: u64,
    close_succeeded: bool,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    final_generation_cursor: u32,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpOperatorSourceRefreshReport = struct {
    source_kind: time_reference.Kind,
    frequency_hz: u64,
    counter_bits: u8,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    original_source_index: u8,
    target_source_index: u8,
    original_server: [4]u8,
    target_server: [4]u8,
    initial_identification: u16,
    initial_descriptor: u16,
    initial_next_cursor: u16,
    terminal_seeded: bool,
    reset_succeeded: bool,
    same_socket_preserved: bool,
    clock_preserved: bool,
    transient_state_cleared: bool,
    cumulative_state_preserved: bool,
    projected_refresh_timestamp: u64,
    refresh_identification: u16,
    refresh_descriptor: u16,
    refresh_next_cursor: u16,
    refresh_started: bool,
    refresh_target_source: bool,
    accepted_quality_result: ntp.QualityResult,
    accepted_step_result: ntp.ClockStepResult,
    accepted_sample_tick: u64,
    accepted_seconds: u64,
    accepted_fraction: u32,
    accepted_state_clean: bool,
    health_reports_source: bool,
    health_reports_synchronized: bool,
    health_preserves_cumulative: bool,
    quality_accepted: u64,
    quality_rejected: u64,
    step_accepted: u64,
    step_rejected: u64,
    requests_started: u64,
    retries: u64,
    responses: u64,
    retry_limit_hits: u64,
    recovery_limit_hits: u64,
    source_rotations: u64,
    close_succeeded: bool,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    final_generation_cursor: u32,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpOperatorSourceResetReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    source_count: u8,
    original_source_index: u8,
    target_source_index: u8,
    original_server: [4]u8,
    target_server: [4]u8,
    terminal_seeded: bool,
    invalid_source_rejected: bool,
    invalid_state_preserved: bool,
    reset_succeeded: bool,
    same_socket_preserved: bool,
    target_source_selected: bool,
    transient_state_cleared: bool,
    cumulative_state_preserved: bool,
    rotations_preserved: bool,
    duplicate_reset_rejected: bool,
    no_packet_traffic: bool,
    close_succeeded: bool,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    final_generation_cursor: u32,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpSourceExhaustionResetReport = struct {
    source_kind: time_reference.Kind,
    frequency_hz: u64,
    counter_bits: u8,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    source_count: u8,
    current_source_index: u8,
    current_server: [4]u8,
    initial_identification: u16,
    initial_descriptor: u16,
    initial_next_cursor: u16,
    terminal_seeded: bool,
    switch_to_current_source_succeeded: bool,
    clear_succeeded: bool,
    duplicate_clear_rejected: bool,
    transient_state_cleared: bool,
    cumulative_state_preserved: bool,
    source_state_preserved: bool,
    socket_preserved: bool,
    clock_preserved: bool,
    projected_refresh_timestamp: u64,
    refresh_identification: u16,
    refresh_descriptor: u16,
    refresh_next_cursor: u16,
    refresh_started: bool,
    refresh_source_preserved: bool,
    accepted_quality_result: ntp.QualityResult,
    accepted_step_result: ntp.ClockStepResult,
    accepted_sample_tick: u64,
    accepted_seconds: u64,
    accepted_fraction: u32,
    accepted_reset_state: bool,
    health_reports_source: bool,
    health_reports_synchronized: bool,
    health_preserves_cumulative: bool,
    quality_accepted: u64,
    quality_rejected: u64,
    step_accepted: u64,
    step_rejected: u64,
    requests_started: u64,
    retries: u64,
    responses: u64,
    retry_limit_hits: u64,
    recovery_limit_hits: u64,
    source_rotations: u64,
    close_succeeded: bool,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    final_generation_cursor: u32,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpSourceExhaustionReport = struct {
    source_kind: time_reference.Kind,
    frequency_hz: u64,
    counter_bits: u8,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    source_count: u8,
    failures_before_rotation: u8,
    maximum_recoveries: u8,
    servers: [3][4]u8,
    transmit_identifications: [7]u16,
    transmit_descriptors: [7]u16,
    transmit_next_cursors: [7]u16,
    refresh_client_timestamp: u64,
    recovery_client_timestamps: [2]u64,
    timestamps_automatic: bool,
    timeout_current_sources: [3]u8,
    timeout_pending_sources: [3]u8,
    timeout_failure_counts: [3]u8,
    first_two_waiting: bool,
    cooldowns_no_tx: [2]bool,
    recovery_source_indices: [2]u8,
    recovery_switches_succeeded: [2]bool,
    same_socket_preserved: bool,
    rotation_count: u64,
    terminal_state: NtpServiceState,
    terminal_recovery_state: ntp.RecoveryState,
    terminal_timeout_reached: bool,
    terminal_no_tx: bool,
    terminal_request_cancelled: bool,
    terminal_retry_exhausted: bool,
    terminal_recovery_exhausted: bool,
    terminal_recovery_limit_hits: u64,
    terminal_recovery_deadline_delta: u64,
    terminal_source_preserved: bool,
    terminal_pending_wrap: u8,
    terminal_failure_count: u8,
    repeated_exhausted_no_tx: bool,
    repeated_latch_preserved: bool,
    holdover_visible: bool,
    holdover_advanced: bool,
    health_reports_source: bool,
    health_reports_exhaustion: bool,
    health_reports_holdover: bool,
    quality_accepted: u64,
    quality_rejected: u64,
    step_accepted: u64,
    step_rejected: u64,
    requests_started: u64,
    retries: u64,
    responses: u64,
    retry_limit_hits: u64,
    recovery_successes: u64,
    close_succeeded: bool,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    final_generation_cursor: u32,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpSourceFailureResetReport = struct {
    source_kind: time_reference.Kind,
    frequency_hz: u64,
    counter_bits: u8,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    source_count: u8,
    failures_before_rotation: u8,
    server: [4]u8,
    transmit_identifications: [7]u16,
    transmit_descriptors: [7]u16,
    transmit_next_cursors: [7]u16,
    refresh_timestamps: [2]u64,
    recovery_timestamps: [2]u64,
    timestamps_automatic: bool,
    first_timeout_pending_absent: bool,
    first_timeout_failure_count: u8,
    first_timeout_source_preserved: bool,
    first_cooldown_no_tx: bool,
    first_recovery_same_source: bool,
    first_recovery_started: bool,
    first_recovery_accepted: bool,
    first_success_reset_failures: bool,
    first_success_no_rotation: bool,
    first_success_health_reset: bool,
    second_timeout_pending_absent: bool,
    second_timeout_failure_count: u8,
    second_timeout_source_preserved: bool,
    second_timeout_not_accumulated: bool,
    second_cooldown_no_tx: bool,
    second_recovery_same_source: bool,
    second_recovery_started: bool,
    second_recovery_accepted: bool,
    final_failure_count_reset: bool,
    final_no_rotation: bool,
    same_socket_preserved: bool,
    accepted_seconds: [2]u64,
    accepted_fractions: [2]u32,
    recovery_successes: u64,
    health_reports_source_zero: bool,
    health_reports_clean_chain: bool,
    health_reports_success: bool,
    quality_accepted: u64,
    quality_rejected: u64,
    step_accepted: u64,
    step_rejected: u64,
    requests_started: u64,
    retries: u64,
    responses: u64,
    retry_limit_hits: u64,
    close_succeeded: bool,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    final_generation_cursor: u32,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpSourceWraparoundReport = struct {
    source_kind: time_reference.Kind,
    frequency_hz: u64,
    counter_bits: u8,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    source_count: u8,
    failures_before_rotation: u8,
    servers: [3][4]u8,
    transmit_identifications: [8]u16,
    transmit_descriptors: [8]u16,
    transmit_next_cursors: [8]u16,
    refresh_client_timestamp: u64,
    recovery_client_timestamps: [3]u64,
    recovery_timestamps_automatic: bool,
    timeout_current_sources: [3]u8,
    timeout_pending_sources: [3]u8,
    timeout_failure_counts: [3]u8,
    timeout_servers_preserved: bool,
    cooldowns_no_tx: [3]bool,
    recovery_source_indices: [3]u8,
    recovery_switches_succeeded: [3]bool,
    same_socket_preserved: bool,
    rotation_count: u64,
    wrap_completed: bool,
    accepted_quality_result: ntp.QualityResult,
    accepted_step_result: ntp.ClockStepResult,
    accepted_sample_tick: u64,
    accepted_seconds: u64,
    accepted_fraction: u32,
    recovery_successes: u64,
    health_reports_source_zero: bool,
    health_reports_rotations: bool,
    health_reports_success: bool,
    quality_accepted: u64,
    quality_rejected: u64,
    step_accepted: u64,
    step_rejected: u64,
    requests_started: u64,
    retries: u64,
    responses: u64,
    retry_limit_hits: u64,
    close_succeeded: bool,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    final_generation_cursor: u32,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpThresholdedSourceFailoverReport = struct {
    source_kind: time_reference.Kind,
    frequency_hz: u64,
    counter_bits: u8,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    source_count: u8,
    failures_before_rotation: u8,
    first_server: [4]u8,
    second_server: [4]u8,
    transmit_identifications: [6]u16,
    transmit_descriptors: [6]u16,
    transmit_next_cursors: [6]u16,
    refresh_client_timestamp: u64,
    first_recovery_client_timestamp: u64,
    second_recovery_client_timestamp: u64,
    recovery_timestamps_automatic: bool,
    first_timeout_state: NtpServiceState,
    first_timeout_pending_absent: bool,
    first_timeout_failure_count: u8,
    first_timeout_server_preserved: bool,
    first_recovery_same_source: bool,
    first_recovery_no_rotation: bool,
    first_recovery_failure_preserved: bool,
    first_recovery_started: bool,
    second_timeout_state: NtpServiceState,
    second_timeout_pending_source: u8,
    second_timeout_failure_count: u8,
    second_timeout_server_preserved: bool,
    first_cooldown_no_tx: bool,
    second_cooldown_no_tx: bool,
    second_recovery_ready: bool,
    second_recovery_started: bool,
    second_recovery_switched: bool,
    same_socket_preserved: bool,
    rotation_count: u64,
    source_state_reset_on_switch: bool,
    accepted_quality_result: ntp.QualityResult,
    accepted_step_result: ntp.ClockStepResult,
    accepted_sample_tick: u64,
    accepted_seconds: u64,
    accepted_fraction: u32,
    recovery_successes: u64,
    health_reports_source: bool,
    health_reports_rotation: bool,
    health_reports_success: bool,
    quality_accepted: u64,
    quality_rejected: u64,
    step_accepted: u64,
    step_rejected: u64,
    requests_started: u64,
    retries: u64,
    responses: u64,
    retry_limit_hits: u64,
    close_succeeded: bool,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    final_generation_cursor: u32,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpLiveSourceFailoverReport = struct {
    source_kind: time_reference.Kind,
    frequency_hz: u64,
    counter_bits: u8,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    source_count: u8,
    failures_before_rotation: u8,
    first_server: [4]u8,
    second_server: [4]u8,
    transmit_identifications: [4]u16,
    transmit_descriptors: [4]u16,
    transmit_next_cursors: [4]u16,
    refresh_client_timestamp: u64,
    recovery_client_timestamp: u64,
    recovery_timestamp_automatic: bool,
    timeout_state: NtpServiceState,
    timeout_reached: bool,
    timeout_transmit_absent: bool,
    request_cancelled: bool,
    timeout_current_source: u8,
    timeout_pending_source: u8,
    timeout_failure_count: u8,
    timeout_server_preserved: bool,
    recovery_deadline_delta: u64,
    cooldown_no_tx: bool,
    recovery_ready: bool,
    recovery_started: bool,
    source_switched: bool,
    same_socket_preserved: bool,
    rotation_count: u64,
    failure_count_reset_on_switch: bool,
    pending_cleared_on_switch: bool,
    accepted_quality_result: ntp.QualityResult,
    accepted_step_result: ntp.ClockStepResult,
    accepted_sample_tick: u64,
    accepted_seconds: u64,
    accepted_fraction: u32,
    recovery_successes: u64,
    health_reports_source: bool,
    health_reports_rotation: bool,
    health_reports_success: bool,
    quality_accepted: u64,
    quality_rejected: u64,
    step_accepted: u64,
    step_rejected: u64,
    requests_started: u64,
    retries: u64,
    responses: u64,
    retry_limit_hits: u64,
    close_succeeded: bool,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    final_generation_cursor: u32,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpServiceSourcePoolReport = struct {
    invalid_pool_rejected: bool,
    invalid_pool_state_preserved: bool,
    mismatched_policy_rejected: bool,
    mismatched_policy_state_preserved: bool,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    pool_count: u8,
    rotation_threshold: u8,
    first_server: [4]u8,
    second_server: [4]u8,
    client_server_matches_first: bool,
    peer_matches_first: bool,
    source_state_initialized: bool,
    health_reports_pool: bool,
    health_reports_policy: bool,
    health_reports_current_source: bool,
    health_reports_failure_count: bool,
    health_reports_rotations: bool,
    close_succeeded: bool,
    no_packet_traffic: bool,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    final_generation_cursor: u32,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpClientServerSwitchReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    original_server: [4]u8,
    alternate_server: [4]u8,
    invalid_rejected: bool,
    invalid_state_preserved: bool,
    idempotent_succeeded: bool,
    idempotent_state_preserved: bool,
    forward_succeeded: bool,
    forward_peer_updated: bool,
    reverse_succeeded: bool,
    reverse_peer_restored: bool,
    socket_preserved: bool,
    gateway_mac_preserved: bool,
    peer_port: u16,
    close_succeeded: bool,
    inactive_rejected: bool,
    inactive_state_preserved: bool,
    stale_rejected: bool,
    stale_state_preserved: bool,
    no_packet_traffic: bool,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    final_generation_cursor: u32,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpQualityRecoveryReport = struct {
    source_kind: time_reference.Kind,
    frequency_hz: u64,
    counter_bits: u8,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    maximum_quality_rejections: u8,
    maximum_retries: u8,
    recovery_cooldown_ticks: u64,
    maximum_recoveries: u8,
    transmit_identifications: [4]u16,
    transmit_descriptors: [4]u16,
    transmit_next_cursors: [4]u16,
    refresh_client_timestamp: u64,
    recovery_client_timestamp: u64,
    recovery_timestamp_automatic: bool,
    first_quality_result: ntp.QualityResult,
    first_quality_action: ntp.QualityRejectionAction,
    first_sample_absent: bool,
    first_apply_absent: bool,
    first_clock_preserved: bool,
    first_retry_timestamp_preserved: bool,
    first_retry_transmissions: u64,
    second_quality_result: ntp.QualityResult,
    second_quality_action: ntp.QualityRejectionAction,
    second_sample_absent: bool,
    second_apply_absent: bool,
    second_clock_preserved: bool,
    timeout_state: NtpServiceState,
    timeout_waiting: bool,
    timeout_transmit_absent: bool,
    request_cancelled: bool,
    retry_exhausted: bool,
    recovery_deadline_delta: u64,
    timeout_health_state: NtpSynchronizationHealth,
    timeout_health_timestamp: u64,
    cooldown_health_state: NtpSynchronizationHealth,
    cooldown_health_timestamp: u64,
    holdover_visible: bool,
    holdover_advanced: bool,
    cooldown_no_tx: bool,
    recovery_ready: bool,
    recovery_started: bool,
    accepted_quality_result: ntp.QualityResult,
    accepted_step_result: ntp.ClockStepResult,
    accepted_sample_tick: u64,
    accepted_seconds: u64,
    accepted_fraction: u32,
    recovery_successes: u64,
    recovery_budget_reset: bool,
    retry_budget_reset: bool,
    quality_budget_reset: bool,
    step_budget_reset: bool,
    clock_advanced: bool,
    health_reports_success: bool,
    quality_accepted: u64,
    quality_rejected: u64,
    quality_stratum_rejected: u64,
    quality_root_dispersion_rejected: u64,
    quality_forced_retries: u64,
    step_accepted: u64,
    step_rejected: u64,
    requests_started: u64,
    retries: u64,
    responses: u64,
    retry_limit_hits: u64,
    close_succeeded: bool,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpQualityRejectionExhaustionReport = struct {
    source_kind: time_reference.Kind,
    frequency_hz: u64,
    counter_bits: u8,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    maximum_rejections: u8,
    maximum_retries: u8,
    initial_identification: u16,
    initial_descriptor: u16,
    initial_next_cursor: u16,
    client_timestamp: u64,
    first_quality_result: ntp.QualityResult,
    first_action: ntp.QualityRejectionAction,
    first_sample_absent: bool,
    first_apply_absent: bool,
    first_clock_preserved: bool,
    forced_retry_identification: u16,
    forced_retry_descriptor: u16,
    forced_retry_next_cursor: u16,
    forced_retry_timestamp_preserved: bool,
    forced_retry_transmissions: u64,
    second_quality_result: ntp.QualityResult,
    second_action: ntp.QualityRejectionAction,
    second_count: u8,
    second_remaining: u8,
    second_sample_absent: bool,
    second_apply_absent: bool,
    second_clock_preserved: bool,
    timeout_state: NtpServiceState,
    timeout_reached: bool,
    timeout_transmit_absent: bool,
    request_cancelled: bool,
    request_inactive: bool,
    retry_exhausted: bool,
    retry_limit_hits: u64,
    quality_forced_retries: u64,
    timeout_latched: bool,
    health_reports_exhaustion: bool,
    clear_succeeded: bool,
    duplicate_clear_rejected: bool,
    rejection_count_cleared: bool,
    restart_identification: u16,
    restart_descriptor: u16,
    restart_next_cursor: u16,
    restart_wait_ticks: u64,
    quality_accepted: u64,
    quality_rejected: u64,
    quality_stratum_rejected: u64,
    quality_root_dispersion_rejected: u64,
    step_accepted: u64,
    step_rejected: u64,
    requests_started: u64,
    retries: u64,
    responses: u64,
    close_succeeded: bool,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpLiveQualityRejectionBudgetReport = struct {
    source_kind: time_reference.Kind,
    frequency_hz: u64,
    counter_bits: u8,
    invalid_policy_rejected: bool,
    invalid_policy_state_preserved: bool,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    maximum_rejections: u8,
    initial_identification: u16,
    initial_descriptor: u16,
    initial_next_cursor: u16,
    client_timestamp: u64,
    first_quality_result: ntp.QualityResult,
    first_action: ntp.QualityRejectionAction,
    first_count: u8,
    first_remaining: u8,
    first_sample_absent: bool,
    first_apply_absent: bool,
    first_clock_preserved: bool,
    first_request_retained: bool,
    boundary_quality_result: ntp.QualityResult,
    boundary_action: ntp.QualityRejectionAction,
    boundary_count: u8,
    boundary_remaining: u8,
    boundary_sample_absent: bool,
    boundary_apply_absent: bool,
    boundary_clock_preserved: bool,
    forced_retry_identification: u16,
    forced_retry_descriptor: u16,
    forced_retry_next_cursor: u16,
    forced_retry_before_deadline: bool,
    forced_retry_timestamp_preserved: bool,
    forced_retry_transmissions: u64,
    quality_count_reset: bool,
    accepted_quality_result: ntp.QualityResult,
    accepted_step_result: ntp.ClockStepResult,
    accepted_sample_tick: u64,
    accepted_seconds: u64,
    accepted_fraction: u32,
    health_reports_policy: bool,
    quality_accepted: u64,
    quality_rejected: u64,
    quality_stratum_rejected: u64,
    quality_root_dispersion_rejected: u64,
    quality_forced_retries: u64,
    step_accepted: u64,
    requests_started: u64,
    retries: u64,
    responses: u64,
    close_succeeded: bool,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpDisciplineRecoveryReport = struct {
    source_kind: time_reference.Kind,
    frequency_hz: u64,
    counter_bits: u8,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    maximum_rejections: u8,
    maximum_retries: u8,
    recovery_cooldown_ticks: u64,
    maximum_recoveries: u8,
    transmit_identifications: [4]u16,
    transmit_descriptors: [4]u16,
    transmit_next_cursors: [4]u16,
    refresh_client_timestamp: u64,
    recovery_client_timestamp: u64,
    recovery_timestamp_automatic: bool,
    timeout_state: NtpServiceState,
    timeout_waiting: bool,
    timeout_transmit_absent: bool,
    request_cancelled: bool,
    retry_exhausted: bool,
    recovery_deadline_delta: u64,
    timeout_health_state: NtpSynchronizationHealth,
    timeout_health_timestamp: u64,
    cooldown_health_state: NtpSynchronizationHealth,
    cooldown_health_timestamp: u64,
    holdover_visible: bool,
    holdover_advanced: bool,
    cooldown_no_tx: bool,
    recovery_ready: bool,
    recovery_started: bool,
    accepted_quality_result: ntp.QualityResult,
    accepted_step_result: ntp.ClockStepResult,
    accepted_sample_tick: u64,
    accepted_seconds: u64,
    accepted_fraction: u32,
    recovery_successes: u64,
    recovery_budget_reset: bool,
    retry_budget_reset: bool,
    rejection_budget_reset: bool,
    clock_advanced: bool,
    health_reports_success: bool,
    quality_accepted: u64,
    quality_rejected: u64,
    step_accepted: u64,
    step_rejected: u64,
    step_stale_rejected: u64,
    step_excessive_forward_rejected: u64,
    discipline_forced_retries: u64,
    requests_started: u64,
    retries: u64,
    responses: u64,
    close_succeeded: bool,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpRejectionExhaustionReport = struct {
    source_kind: time_reference.Kind,
    frequency_hz: u64,
    counter_bits: u8,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    maximum_rejections: u8,
    maximum_retries: u8,
    initial_identification: u16,
    initial_descriptor: u16,
    initial_next_cursor: u16,
    refresh_identification: u16,
    refresh_descriptor: u16,
    refresh_next_cursor: u16,
    refresh_client_timestamp: u64,
    first_quality_result: ntp.QualityResult,
    first_step_result: ntp.ClockStepResult,
    first_rejection_action: ntp.StepRejectionAction,
    first_forced_retry_identification: u16,
    first_forced_retry_descriptor: u16,
    first_forced_retry_next_cursor: u16,
    first_forced_retry_timestamp_preserved: bool,
    first_forced_retry_transmissions: u64,
    second_quality_result: ntp.QualityResult,
    second_step_result: ntp.ClockStepResult,
    second_rejection_action: ntp.StepRejectionAction,
    second_rejection_count: u8,
    second_remaining: u8,
    second_apply_absent: bool,
    second_clock_preserved: bool,
    timeout_state: NtpServiceState,
    timeout_reached: bool,
    timeout_transmit_absent: bool,
    request_cancelled: bool,
    request_inactive: bool,
    retry_exhausted: bool,
    retry_limit_hits: u64,
    discipline_forced_retries: u64,
    timeout_latched: bool,
    health_reports_exhaustion: bool,
    clear_succeeded: bool,
    duplicate_clear_rejected: bool,
    rejection_count_cleared: bool,
    quality_accepted: u64,
    quality_rejected: u64,
    step_accepted: u64,
    step_rejected: u64,
    step_stale_rejected: u64,
    step_excessive_forward_rejected: u64,
    requests_started: u64,
    retries: u64,
    responses: u64,
    close_succeeded: bool,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpLiveRejectionBudgetReport = struct {
    source_kind: time_reference.Kind,
    frequency_hz: u64,
    counter_bits: u8,
    invalid_policy_rejected: bool,
    invalid_policy_state_preserved: bool,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    maximum_rejections: u8,
    initial_identification: u16,
    initial_descriptor: u16,
    initial_next_cursor: u16,
    first_sample_tick: u64,
    refresh_identification: u16,
    refresh_descriptor: u16,
    refresh_next_cursor: u16,
    refresh_client_timestamp: u64,
    first_quality_result: ntp.QualityResult,
    first_step_result: ntp.ClockStepResult,
    first_rejection_action: ntp.StepRejectionAction,
    first_rejection_count: u8,
    first_remaining: u8,
    first_apply_absent: bool,
    first_clock_preserved: bool,
    first_request_retained: bool,
    boundary_quality_result: ntp.QualityResult,
    boundary_step_result: ntp.ClockStepResult,
    boundary_rejection_action: ntp.StepRejectionAction,
    boundary_rejection_count: u8,
    boundary_remaining: u8,
    boundary_apply_absent: bool,
    boundary_clock_preserved: bool,
    forced_retry_identification: u16,
    forced_retry_descriptor: u16,
    forced_retry_next_cursor: u16,
    forced_retry_before_deadline: bool,
    forced_retry_timestamp_preserved: bool,
    forced_retry_transmissions: u64,
    rejection_count_reset: bool,
    accepted_quality_result: ntp.QualityResult,
    accepted_step_result: ntp.ClockStepResult,
    accepted_sample_tick: u64,
    accepted_seconds: u64,
    accepted_fraction: u32,
    final_clock_advanced: bool,
    quality_accepted: u64,
    quality_rejected: u64,
    step_accepted: u64,
    step_rejected: u64,
    step_stale_rejected: u64,
    step_excessive_forward_rejected: u64,
    discipline_forced_retries: u64,
    requests_started: u64,
    retries: u64,
    responses: u64,
    close_succeeded: bool,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpStaleStepRetryReport = struct {
    source_kind: time_reference.Kind,
    frequency_hz: u64,
    counter_bits: u8,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    maximum_forward_seconds: u64,
    initial_identification: u16,
    initial_descriptor: u16,
    initial_next_cursor: u16,
    first_sample_tick: u64,
    first_seconds: u64,
    first_fraction: u32,
    refresh_identification: u16,
    refresh_descriptor: u16,
    refresh_next_cursor: u16,
    refresh_client_timestamp: u64,
    stale_quality_result: ntp.QualityResult,
    stale_step_result: ntp.ClockStepResult,
    stale_sample_tick: u64,
    stale_apply_absent: bool,
    stale_clock_preserved: bool,
    stale_request_retained: bool,
    retry_identification: u16,
    retry_descriptor: u16,
    retry_next_cursor: u16,
    retry_timestamp_preserved: bool,
    retry_transmissions: u64,
    accepted_quality_result: ntp.QualityResult,
    accepted_step_result: ntp.ClockStepResult,
    accepted_sample_tick: u64,
    accepted_seconds: u64,
    accepted_fraction: u32,
    final_clock_advanced: bool,
    quality_accepted: u64,
    quality_rejected: u64,
    step_accepted: u64,
    step_rejected: u64,
    step_invalid_policy_rejected: u64,
    step_stale_rejected: u64,
    step_excessive_forward_rejected: u64,
    requests_started: u64,
    retries: u64,
    responses: u64,
    close_succeeded: bool,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};
pub const NtpLiveStepGateReport = struct {
    source_kind: time_reference.Kind,
    frequency_hz: u64,
    counter_bits: u8,
    invalid_policy_rejected: bool,
    invalid_policy_state_preserved: bool,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    maximum_forward_seconds: u64,
    maximum_forward_fraction: u32,
    initial_identification: u16,
    initial_descriptor: u16,
    initial_next_cursor: u16,
    initial_quality_result: ntp.QualityResult,
    initial_step_result: ntp.ClockStepResult,
    first_sample_tick: u64,
    first_seconds: u64,
    first_fraction: u32,
    refresh_identification: u16,
    refresh_descriptor: u16,
    refresh_next_cursor: u16,
    refresh_client_timestamp: u64,
    excessive_quality_result: ntp.QualityResult,
    excessive_step_result: ntp.ClockStepResult,
    excessive_sample_tick: u64,
    excessive_apply_absent: bool,
    excessive_clock_preserved: bool,
    excessive_request_retained: bool,
    accepted_quality_result: ntp.QualityResult,
    accepted_step_result: ntp.ClockStepResult,
    accepted_sample_tick: u64,
    accepted_seconds: u64,
    accepted_fraction: u32,
    final_clock_advanced: bool,
    quality_accepted: u64,
    quality_rejected: u64,
    step_accepted: u64,
    step_rejected: u64,
    step_invalid_policy_rejected: u64,
    step_stale_rejected: u64,
    step_excessive_forward_rejected: u64,
    responses: u64,
    close_succeeded: bool,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};
pub const NtpSynchronizedRecoveryReport = struct {
    source_kind: time_reference.Kind,
    frequency_hz: u64,
    counter_bits: u8,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    transmit_identifications: [7]u16,
    transmit_descriptors: [7]u16,
    transmit_next_cursors: [7]u16,
    initial_client_timestamp: u64,
    refresh_client_timestamp: u64,
    first_recovery_client_timestamp: u64,
    second_recovery_client_timestamp: u64,
    first_refresh_timestamp_automatic: bool,
    first_recovery_timestamp_automatic: bool,
    second_recovery_timestamp_automatic: bool,
    timeout_health_state: NtpSynchronizationHealth,
    timeout_health_timestamp: u64,
    cooldown_health_state: NtpSynchronizationHealth,
    cooldown_health_timestamp: u64,
    holdover_advanced: bool,
    holdover_visible: bool,
    first_timeout_delta: u64,
    first_recovery_deadline_delta: u64,
    first_recovery_delta: u64,
    first_recovery_started: bool,
    recovery_response_accepted: bool,
    recovery_successes_after_accept: u64,
    recovery_budget_reset: bool,
    recovered_timestamp: u64,
    recovered_time_advanced: bool,
    second_timeout_delta: u64,
    second_recovery_deadline_delta: u64,
    second_recovery_delta: u64,
    second_recovery_started: bool,
    full_budget_restored: bool,
    health_reports_success: bool,
    close_succeeded: bool,
    requests_started: u64,
    retries: u64,
    retry_limit_hits: u64,
    responses: u64,
    quality_accepted: u64,
    recovery_successes: u64,
    automatic_recoveries: u8,
    recovery_limit_hits: u64,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};
pub const NtpAutomaticRecoveryReport = struct {
    source_kind: time_reference.Kind,
    frequency_hz: u64,
    counter_bits: u8,
    invalid_policy_rejected: bool,
    invalid_policy_state_preserved: bool,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    retry_initial_ticks: u64,
    retry_maximum_ticks: u64,
    retry_maximum_retries: u8,
    recovery_cooldown_ticks: u64,
    recovery_maximum_recoveries: u8,
    transmit_identifications: [6]u16,
    transmit_descriptors: [6]u16,
    transmit_next_cursors: [6]u16,
    first_timeout_delta: u64,
    first_recovery_deadline_delta: u64,
    first_wait_no_tx: bool,
    first_recovery_delta: u64,
    first_recovery_started: bool,
    second_timeout_delta: u64,
    second_recovery_deadline_delta: u64,
    second_wait_no_tx: bool,
    second_recovery_delta: u64,
    second_recovery_started: bool,
    terminal_timeout_delta: u64,
    terminal_recovery_deadline_delta: u64,
    terminal_exhausted: bool,
    timeout_latched: bool,
    health_reports_exhaustion: bool,
    bootstrap_timestamp_preserved: bool,
    requests_started: u64,
    retries: u64,
    retry_limit_hits: u64,
    automatic_recoveries: u8,
    recovery_limit_hits: u64,
    close_succeeded: bool,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};
pub const NtpBackoffReport = struct {
    source_kind: time_reference.Kind,
    frequency_hz: u64,
    counter_bits: u8,
    invalid_policy_rejected: bool,
    invalid_policy_state_preserved: bool,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    initial_interval_ticks: u64,
    maximum_interval_ticks: u64,
    maximum_retries: u8,
    initial_identification: u16,
    initial_descriptor: u16,
    initial_next_cursor: u16,
    initial_wait_ticks: u64,
    early_no_tx: bool,
    retry_identifications: [3]u16,
    retry_descriptors: [3]u16,
    retry_next_cursors: [3]u16,
    retry_wait_ticks: [3]u64,
    timeout_tick_delta: u64,
    timeout_state: NtpServiceState,
    timeout_reached: bool,
    request_cancelled: bool,
    retry_exhausted: bool,
    timeout_latched: bool,
    health_reports_exhaustion: bool,
    clear_succeeded: bool,
    duplicate_clear_rejected: bool,
    restart_identification: u16,
    restart_descriptor: u16,
    restart_next_cursor: u16,
    restart_wait_ticks: u64,
    close_succeeded: bool,
    requests_started: u64,
    retries: u64,
    retry_limit_hits: u64,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};
pub const NtpSourcePoolReport = struct {
    invalid_zero_count_rejected: bool,
    invalid_single_count_rejected: bool,
    invalid_too_many_rejected: bool,
    invalid_zero_address_rejected: bool,
    invalid_duplicate_rejected: bool,
    valid_two_sources: bool,
    valid_maximum_sources: bool,
    first_source: [4]u8,
    second_source: [4]u8,
    maximum_last_source: [4]u8,
    out_of_range_rejected: bool,
    invalid_pool_lookup_rejected: bool,
    unused_slots_ignored: bool,
};
pub const NtpSourceRotationPolicyReport = struct {
    invalid_zero_sources_rejected: bool,
    invalid_single_source_rejected: bool,
    invalid_zero_threshold_rejected: bool,
    invalid_source_index_rejected: bool,
    zero_failures_stay: bool,
    zero_remaining: u8,
    first_failure_stay: bool,
    first_remaining: u8,
    boundary_rotates: bool,
    boundary_next_source: u8,
    beyond_rotates: bool,
    beyond_next_source: u8,
    wrap_rotates: bool,
    wrap_next_source: u8,
    maximum_penultimate_stays: bool,
    maximum_boundary_rotates: bool,
    maximum_boundary_next_source: u8,
};
pub const NtpQualityRejectionPolicyReport = struct {
    invalid_zero_rejected: bool,
    zero_count_retained: bool,
    zero_count_remaining: u8,
    first_retained: bool,
    first_remaining: u8,
    penultimate_retained: bool,
    penultimate_remaining: u8,
    boundary_retries: bool,
    boundary_remaining: u8,
    beyond_retries: bool,
    maximum_penultimate_retained: bool,
    maximum_boundary_retries: bool,
};
pub const NtpStepRejectionPolicyReport = struct {
    invalid_zero_rejected: bool,
    zero_count_retained: bool,
    zero_count_remaining: u8,
    first_retained: bool,
    first_remaining: u8,
    penultimate_retained: bool,
    penultimate_remaining: u8,
    boundary_retries: bool,
    boundary_remaining: u8,
    beyond_retries: bool,
    maximum_penultimate_retained: bool,
    maximum_boundary_retries: bool,
};
pub const NtpStepPolicyReport = struct {
    invalid_zero_rejected: bool,
    unsynchronized_initial_accepted: bool,
    stale_equal_rejected: bool,
    stale_behind_rejected: bool,
    exact_borrow_accepted: bool,
    exact_no_borrow_accepted: bool,
    excessive_fraction_rejected: bool,
    excessive_seconds_rejected: bool,
    borrow_delta_seconds: u64,
    borrow_delta_fraction: u32,
    no_borrow_delta_seconds: u64,
    no_borrow_delta_fraction: u32,
};
pub const NtpRecoveryPolicyReport = struct {
    invalid_zero_cooldown_rejected: bool,
    invalid_zero_recoveries_rejected: bool,
    deadline_tick: u64,
    waiting_before_deadline: bool,
    ready_at_deadline: bool,
    second_recovery_ready: bool,
    exhausted_at_limit: bool,
    overflow_deadline_tick: u64,
    overflow_waiting: bool,
    overflow_ready: bool,
};
pub const NtpRetryPolicyReport = struct {
    invalid_zero_initial_rejected: bool,
    invalid_cap_rejected: bool,
    invalid_zero_retries_rejected: bool,
    intervals: [4]u64,
    limit_rejected: bool,
    fixed_intervals: [3]u64,
    overflow_saturated: bool,
    maximum_value: u64,
};
pub const NtpHealthReport = struct {
    invalid_zero_holdover_rejected: bool,
    invalid_equal_threshold_rejected: bool,
    invalid_reversed_threshold_rejected: bool,
    inactive_state: NtpSynchronizationHealth,
    unsynchronized_state: NtpSynchronizationHealth,
    synchronized_state: NtpSynchronizationHealth,
    holdover_state: NtpSynchronizationHealth,
    expired_state: NtpSynchronizationHealth,
    backward_tick_rejected: bool,
    synchronized_age_ticks: u64,
    synchronized_seconds: u64,
    synchronized_fraction: u32,
    holdover_age_ticks: u64,
    holdover_seconds: u64,
    holdover_fraction: u32,
    expired_age_ticks: u64,
    expired_time_absent: bool,
    awaiting_response_preserved: bool,
    counters_preserved: bool,
};

pub const NtpAutomaticTimestampReport = struct {
    zero_bootstrap_rejected: bool,
    bootstrap_timestamp: u64,
    anchor_timestamp: u64,
    quarter_timestamp: u64,
    backward_tick_rejected: bool,
};
pub const NtpQualityReport = struct {
    fixture_accepted: bool,
    boundary_accepted: bool,
    invalid_policy_rejected: bool,
    stratum_rejected: bool,
    positive_delay_rejected: bool,
    negative_delay_rejected: bool,
    dispersion_rejected: bool,
    fixture_delay_magnitude: u32,
    negative_delay_magnitude: u32,
};
pub const NtpTimestampReport = struct {
    base_timestamp: u64,
    anchor_timestamp: u64,
    quarter_timestamp: u64,
    rollover_timestamp: u64,
    maximum_timestamp: u64,
    unsynchronized_rejected: bool,
    backward_tick_rejected: bool,
    overflow_rejected: bool,
};
pub const NtpServiceReport = struct {
    source_kind: time_reference.Kind,
    frequency_hz: u64,
    counter_bits: u8,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    invalid_policy_rejected: bool,
    invalid_policy_state_preserved: bool,
    quality_policy_max_stratum: u8,
    quality_policy_max_root_delay: u32,
    quality_policy_max_root_dispersion: u32,
    quality_rejection_reason: ntp.QualityResult,
    quality_rejected_without_sample: bool,
    quality_request_retained: bool,
    bootstrap_zero_rejected: bool,
    bootstrap_state_preserved: bool,
    pre_anchor_idle_preserved: bool,
    initial_client_timestamp: u64,
    retry_timestamp_preserved: bool,
    refresh_client_timestamp: u64,
    refresh_timestamp_automatic: bool,
    retry_interval_ticks: u64,
    refresh_interval_ticks: u64,
    initial_identification: u16,
    initial_descriptor: u16,
    initial_next_cursor: u16,
    early_no_tx: bool,
    retry_identification: u16,
    retry_descriptor: u16,
    retry_next_cursor: u16,
    retry_transmissions: u16,
    first_sample_tick: u64,
    first_seconds: u64,
    first_fraction: u32,
    first_refresh_deadline: u64,
    before_refresh_no_tx: bool,
    refresh_identification: u16,
    refresh_descriptor: u16,
    refresh_next_cursor: u16,
    second_sample_tick: u64,
    second_seconds: u64,
    second_fraction: u32,
    requests_started: u64,
    retries: u64,
    responses: u64,
    quality_accepted: u64,
    quality_rejected: u64,
    quality_invalid_policy_rejected: u64,
    quality_stratum_rejected: u64,
    quality_root_delay_rejected: u64,
    quality_root_dispersion_rejected: u64,
    close_succeeded: bool,
    inactive_preserved: bool,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpReferenceClockReport = struct {
    source_kind: time_reference.Kind,
    frequency_hz: u64,
    counter_bits: u8,
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    server_ipv4: [4]u8,
    server_port: u16,
    first_identification: u16,
    first_descriptor: u16,
    first_next_cursor: u16,
    first_frame_length: u16,
    zero_state: NtpRequestState,
    zero_examined: u16,
    zero_rejected: u16,
    zero_sample_absent: bool,
    zero_apply_absent: bool,
    zero_queue_remaining: u16,
    accepted_state: NtpRequestState,
    accepted_examined: u16,
    accepted_rejected: u16,
    accepted_sample_tick: u64,
    accepted_apply: ntp.ClockApplyResult,
    accepted_seconds: u64,
    accepted_fraction: u32,
    later_tick: u64,
    later_delta: u64,
    later_seconds: u64,
    later_fraction: u32,
    time_advanced: bool,
    second_identification: u16,
    second_descriptor: u16,
    second_next_cursor: u16,
    second_frame_length: u16,
    duplicate_state: NtpRequestState,
    duplicate_examined: u16,
    duplicate_rejected: u16,
    duplicate_sample_tick: u64,
    duplicate_apply: ntp.ClockApplyResult,
    duplicate_clock_preserved: bool,
    close_succeeded: bool,
    inactive_state: NtpRequestState,
    inactive_sample_absent: bool,
    inactive_apply_absent: bool,
    inactive_clock_preserved: bool,
    final_identification_cursor: u16,
    final_dns_transaction_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    completion_overflow: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpProjectedClockReport = struct {
    invalid_frequency_rejected: bool,
    invalid_frequency_state_preserved: bool,
    initially_unsynchronized: bool,
    first_apply: ntp.ClockApplyResult,
    first_anchor_tick: u64,
    first_frequency: u64,
    quarter_seconds: u64,
    quarter_fraction: u32,
    three_quarter_seconds: u64,
    three_quarter_fraction: u32,
    one_second_seconds: u64,
    one_second_fraction: u32,
    backward_tick_rejected: bool,
    resync_apply: ntp.ClockApplyResult,
    resync_anchor_tick: u64,
    resync_frequency: u64,
    resync_seconds: u64,
    resync_fraction: u32,
    resync_stratum: u8,
    resync_reference_id: [4]u8,
    resync_quarter_seconds: u64,
    resync_quarter_fraction: u32,
    stale_apply: ntp.ClockApplyResult,
    stale_state_preserved: bool,
    accepted_samples: u64,
    stale_samples: u64,
};

pub const NtpClockPollingReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    server_ipv4: [4]u8,
    server_port: u16,
    first_identification: u16,
    first_descriptor: u16,
    first_next_cursor: u16,
    first_frame_length: u16,
    zero_state: NtpRequestState,
    zero_examined: u16,
    zero_rejected: u16,
    zero_apply_absent: bool,
    zero_queue_remaining: u16,
    zero_clock_unsynchronized: bool,
    accepted_state: NtpRequestState,
    accepted_examined: u16,
    accepted_rejected: u16,
    accepted_apply: ntp.ClockApplyResult,
    accepted_seconds: u64,
    accepted_fraction: u32,
    second_identification: u16,
    second_descriptor: u16,
    second_next_cursor: u16,
    second_frame_length: u16,
    duplicate_state: NtpRequestState,
    duplicate_examined: u16,
    duplicate_rejected: u16,
    duplicate_apply: ntp.ClockApplyResult,
    duplicate_clock_preserved: bool,
    accepted_samples: u64,
    stale_samples: u64,
    close_succeeded: bool,
    inactive_state: NtpRequestState,
    inactive_apply_absent: bool,
    inactive_clock_preserved: bool,
    final_identification_cursor: u16,
    final_dns_transaction_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    completion_overflow: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpClockReport = struct {
    initially_unsynchronized: bool,
    first_apply: ntp.ClockApplyResult,
    duplicate_apply: ntp.ClockApplyResult,
    backward_apply: ntp.ClockApplyResult,
    fractional_forward_apply: ntp.ClockApplyResult,
    second_forward_apply: ntp.ClockApplyResult,
    duplicate_preserved: bool,
    backward_preserved: bool,
    final_seconds: u64,
    final_fraction: u32,
    final_stratum: u8,
    final_reference_id: [4]u8,
    accepted_samples: u64,
    stale_samples: u64,
};

pub const NtpClientContextReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    server_ipv4: [4]u8,
    server_port: u16,
    invalid_server_rejected: bool,
    invalid_server_state_preserved: bool,
    client_timestamp: u64,
    transmit_identification: u16,
    transmit_descriptor: u16,
    transmit_next_cursor: u16,
    transmit_frame_length: u16,
    poll_state: NtpRequestState,
    poll_examined: u16,
    poll_rejected: u16,
    unix_seconds: u64,
    unix_fraction: u32,
    close_succeeded: bool,
    client_inactive: bool,
    stale_start_rejected: bool,
    stale_poll_state: NtpRequestState,
    stale_retry_rejected: bool,
    stale_state_preserved: bool,
    final_identification_cursor: u16,
    final_dns_transaction_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    completion_overflow: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpRetryReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    client_timestamp: u64,
    initial_identification: u16,
    initial_descriptor: u16,
    initial_next_cursor: u16,
    initial_frame_length: u16,
    pending_state: NtpRequestState,
    pending_examined: u16,
    pending_rejected: u16,
    retry_identification: u16,
    retry_descriptor: u16,
    retry_next_cursor: u16,
    retry_frame_length: u16,
    transmissions: u16,
    wraps_before: u16,
    wraps_after: u16,
    resolved_state: NtpRequestState,
    resolved_examined: u16,
    resolved_rejected: u16,
    unix_seconds: u64,
    unix_fraction: u32,
    stale_retry_rejected: bool,
    stale_retry_state_preserved: bool,
    final_identification_cursor: u16,
    final_dns_transaction_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    completion_overflow: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpPollingReport = struct {
    polling_slot: u16,
    polling_generation: u32,
    polling_port: u16,
    polling_identification: u16,
    polling_descriptor: u16,
    polling_next_cursor: u16,
    polling_frame_length: u16,
    zero_state: NtpRequestState,
    zero_examined: u16,
    zero_rejected: u16,
    zero_remaining: u16,
    first_state: NtpRequestState,
    first_examined: u16,
    first_rejected: u16,
    first_remaining: u16,
    second_state: NtpRequestState,
    second_examined: u16,
    second_rejected: u16,
    unix_seconds: u64,
    unix_fraction: u32,
    cancellation_slot: u16,
    cancellation_generation: u32,
    cancellation_port: u16,
    cancellation_identification: u16,
    cancellation_descriptor: u16,
    cancellation_next_cursor: u16,
    cancellation_frame_length: u16,
    queued_before_cancel: u16,
    cancelled: bool,
    duplicate_cancel_rejected: bool,
    cancelled_poll_state: NtpRequestState,
    cancelled_poll_examined: u16,
    cancelled_poll_rejected: u16,
    queue_preserved: bool,
    normal_close_rejected: bool,
    discarded_packets: u16,
    final_identification_cursor: u16,
    final_dns_transaction_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    completion_overflow: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpTransactionReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    server_ipv4: [4]u8,
    server_port: u16,
    client_timestamp: u64,
    invalid_timestamp_rejected: bool,
    rejection_state_preserved: bool,
    transmit_identification: u16,
    transmit_descriptor: u16,
    transmit_next_cursor: u16,
    transmit_frame_length: u16,
    wrong_originate_rejected: bool,
    unix_seconds: u64,
    unix_fraction: u32,
    stratum: u8,
    poll: i8,
    precision: i8,
    reference_id: [4]u8,
    endpoint_enqueued: u64,
    endpoint_dequeued: u64,
    endpoint_high_water: u16,
    endpoint_dropped: u64,
    final_identification_cursor: u16,
    final_dns_transaction_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    completion_overflow: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const NtpCodecReport = struct {
    client_timestamp: u64,
    server_timestamp: u64,
    request_length: u16,
    request_hash: u64,
    response_length: u16,
    response_hash: u64,
    leap_indicator: u8,
    version: u8,
    stratum: u8,
    poll: i8,
    precision: i8,
    root_delay: u32,
    root_dispersion: u32,
    reference_id: [4]u8,
    unix_seconds: u64,
    unix_fraction: u32,
    zero_timestamp_rejected: bool,
    small_buffer_rejected: bool,
    wrong_mode_rejected: bool,
    alarm_rejected: bool,
    invalid_stratum_rejected: bool,
    wrong_originate_rejected: bool,
    zero_transmit_rejected: bool,
    pre_epoch_rejected: bool,
    truncated_rejected: bool,
};

pub const DnsResolverContextReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    server_ipv4: [4]u8,
    server_port: u16,
    invalid_server_rejected: bool,
    invalid_server_state_preserved: bool,
    transaction_id: u16,
    transmit_identification: u16,
    transmit_descriptor: u16,
    transmit_next_cursor: u16,
    transmit_frame_length: u16,
    resolved_state: DnsAQueryState,
    resolved_examined: u16,
    resolved_rejected: u16,
    address: [4]u8,
    ttl: u32,
    cached_hit: bool,
    cached_ttl_remaining: u32,
    cached_hit_no_tx: bool,
    close_succeeded: bool,
    resolver_inactive: bool,
    stale_start_rejected: bool,
    stale_state_preserved: bool,
    final_dns_transaction_cursor: u16,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    completion_overflow: u64,
    cache_hits: u64,
    cache_misses: u64,
    cache_stores: u64,
    cache_active_entries: u8,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const DnsCancellationReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    transaction_id: u16,
    transmit_identification: u16,
    transmit_descriptor: u16,
    transmit_next_cursor: u16,
    transmit_frame_length: u16,
    queued_before_cancel: u16,
    cancelled: bool,
    duplicate_cancel_rejected: bool,
    poll_state: DnsAQueryState,
    poll_examined: u16,
    poll_rejected: u16,
    queue_preserved: bool,
    retry_rejected: bool,
    retry_cursors_preserved: bool,
    normal_close_rejected: bool,
    discarded_packets: u16,
    stale_poll_state: DnsAQueryState,
    final_dns_transaction_cursor: u16,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    completion_overflow: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const DnsNegativeCacheReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    server_ipv4: [4]u8,
    server_port: u16,
    transaction_id: u16,
    transmit_identification: u16,
    transmit_descriptor: u16,
    transmit_next_cursor: u16,
    transmit_frame_length: u16,
    poll_state: DnsAQueryState,
    negative_stored: bool,
    cached_not_found: bool,
    cached_ttl_remaining: u32,
    cached_hit_no_tx: bool,
    expiry_transaction_id: u16,
    expiry_identification: u16,
    expiry_descriptor: u16,
    expiry_next_cursor: u16,
    expiry_frame_length: u16,
    stale_state: DnsAQueryState,
    final_dns_transaction_cursor: u16,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    completion_overflow: u64,
    cache_hits: u64,
    cache_misses: u64,
    cache_stores: u64,
    cache_expirations: u64,
    cache_active_entries: u8,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const DnsNegativeReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    server_ipv4: [4]u8,
    server_port: u16,
    transaction_id: u16,
    transmit_identification: u16,
    transmit_descriptor: u16,
    transmit_next_cursor: u16,
    transmit_frame_length: u16,
    poll_state: DnsAQueryState,
    poll_examined: u16,
    poll_rejected: u16,
    response_absent: bool,
    queue_empty: bool,
    stale_state: DnsAQueryState,
    final_dns_transaction_cursor: u16,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    completion_overflow: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const DnsAutomaticCachedResolveReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    server_ipv4: [4]u8,
    server_port: u16,
    preload_stored: bool,
    initial_cached_hit: bool,
    initial_cached_ttl: u32,
    initial_hit_no_tx: bool,
    expired_transaction_id: u16,
    expired_identification: u16,
    expired_descriptor: u16,
    expired_next_cursor: u16,
    expired_frame_length: u16,
    resolved_state: DnsAQueryState,
    resolved_examined: u16,
    resolved_rejected: u16,
    resolved_address: [4]u8,
    resolved_ttl: u32,
    refreshed_cached_hit: bool,
    refreshed_cached_ttl: u32,
    refreshed_hit_no_tx: bool,
    invalid_name_rejected: bool,
    invalid_name_cursors_preserved: bool,
    final_dns_transaction_cursor: u16,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    completion_overflow: u64,
    cache_hits: u64,
    cache_misses: u64,
    cache_stores: u64,
    cache_expirations: u64,
    cache_active_entries: u8,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const DnsAutomaticTransactionReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    invalid_name_rejected: bool,
    invalid_name_cursors_preserved: bool,
    transaction_ids: [3]u16,
    packet_identifications: [3]u16,
    descriptors: [3]u16,
    next_cursors: [3]u16,
    frame_lengths: [3]u16,
    transmission_counts: [3]u16,
    stale_socket_rejected: bool,
    stale_socket_cursors_preserved: bool,
    final_dns_transaction_cursor: u16,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    completion_overflow: u64,
    tx_wraps_unchanged: bool,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const DnsCachedResolveReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    server_ipv4: [4]u8,
    server_port: u16,
    transaction_id: u16,
    miss_identification: u16,
    miss_descriptor: u16,
    miss_next_cursor: u16,
    miss_frame_length: u16,
    resolved_state: DnsAQueryState,
    resolved_examined: u16,
    address: [4]u8,
    ttl: u32,
    cache_store_count: u64,
    cached_hit: bool,
    cached_address: [4]u8,
    cached_ttl_remaining: u32,
    cached_hit_no_tx: bool,
    expiry_requery_identification: u16,
    expiry_requery_descriptor: u16,
    expiry_requery_next_cursor: u16,
    expiry_requery_frame_length: u16,
    stale_pending_state: DnsAQueryState,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    completion_overflow: u64,
    cache_hits: u64,
    cache_misses: u64,
    cache_expirations: u64,
    cache_active_entries: u8,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const DnsCacheReport = struct {
    capacity: u8,
    active_entries: u8,
    invalid_store_rejected: bool,
    zero_ttl_rejected: bool,
    case_insensitive_hit: bool,
    first_ttl_remaining: u32,
    eviction_verified: bool,
    expiration_verified: bool,
    refresh_verified: bool,
    refreshed_address: [4]u8,
    refreshed_ttl_remaining: u32,
    hits: u64,
    misses: u64,
    stores: u64,
    refreshes: u64,
    evictions: u64,
    expirations: u64,
};

pub const DnsRetryReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    server_ipv4: [4]u8,
    server_port: u16,
    transaction_id: u16,
    name_length: u8,
    name_hash: u64,
    initial_identification: u16,
    initial_descriptor: u16,
    initial_next_cursor: u16,
    initial_frame_length: u16,
    pending_state: DnsAQueryState,
    pending_examined: u16,
    pending_rejected: u16,
    retry_identification: u16,
    retry_descriptor: u16,
    retry_next_cursor: u16,
    retry_frame_length: u16,
    transmissions: u16,
    tx_wraps_before: u16,
    tx_wraps_after: u16,
    resolved_state: DnsAQueryState,
    resolved_examined: u16,
    resolved_rejected: u16,
    address: [4]u8,
    ttl: u32,
    stale_retry_rejected: bool,
    cursor_preserved_on_stale_retry: bool,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    completion_overflow: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const DnsAliasTransactionReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    server_ipv4: [4]u8,
    server_port: u16,
    transaction_id: u16,
    name_length: u8,
    name_hash: u64,
    transmit_identification: u16,
    transmit_descriptor: u16,
    transmit_next_cursor: u16,
    transmit_frame_length: u16,
    poll_state: DnsAQueryState,
    poll_examined: u16,
    poll_rejected: u16,
    address: [4]u8,
    ttl: u32,
    alias_hops: u8,
    endpoint_enqueued: u64,
    endpoint_dequeued: u64,
    endpoint_high_water: u16,
    endpoint_dropped: u64,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    completion_overflow: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const DnsAliasReport = struct {
    transaction_id: u16,
    alias_name_length: u16,
    alias_name_hash: u64,
    canonical_name_length: u16,
    canonical_name_hash: u64,
    response_length: u16,
    response_hash: u64,
    address: [4]u8,
    ttl: u32,
    alias_hops: u8,
    self_loop_rejected: bool,
    truncated_rejected: bool,
    case_insensitive_match: bool,
};

pub const DnsPollingReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    server_ipv4: [4]u8,
    server_port: u16,
    transaction_id: u16,
    name_length: u8,
    name_hash: u64,
    invalid_request_rejected: bool,
    cursor_preserved_on_rejection: bool,
    transmit_identification: u16,
    transmit_descriptor: u16,
    transmit_next_cursor: u16,
    transmit_frame_length: u16,
    zero_budget_state: DnsAQueryState,
    zero_budget_examined: u16,
    zero_budget_rejected: u16,
    zero_budget_remaining: u16,
    first_poll_state: DnsAQueryState,
    first_poll_examined: u16,
    first_poll_rejected: u16,
    first_poll_remaining: u16,
    second_poll_state: DnsAQueryState,
    second_poll_examined: u16,
    second_poll_rejected: u16,
    address: [4]u8,
    ttl: u32,
    stale_poll_state: DnsAQueryState,
    endpoint_enqueued: u64,
    endpoint_dequeued: u64,
    endpoint_high_water: u16,
    endpoint_dropped: u64,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    completion_overflow: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const DnsTransactionReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    server_ipv4: [4]u8,
    server_port: u16,
    transaction_id: u16,
    invalid_name_rejected: bool,
    cursor_preserved_on_rejection: bool,
    query_payload_length: u16,
    query_payload_hash: u64,
    transmit_identification: u16,
    transmit_descriptor: u16,
    transmit_next_cursor: u16,
    transmit_frame_length: u16,
    wrong_transaction_rejected: bool,
    address: [4]u8,
    ttl: u32,
    authoritative: bool,
    recursion_available: bool,
    endpoint_enqueued: u64,
    endpoint_dequeued: u64,
    endpoint_high_water: u16,
    endpoint_dropped: u64,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    completion_overflow: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const DnsCodecReport = struct {
    transaction_id: u16,
    query_length: u16,
    query_hash: u64,
    response_length: u16,
    response_hash: u64,
    address: [4]u8,
    ttl: u32,
    authoritative: bool,
    recursion_available: bool,
    invalid_names_rejected: bool,
    small_buffer_rejected: bool,
    wrong_transaction_rejected: bool,
    truncated_rejected: bool,
    compression_loop_rejected: bool,
    error_response_rejected: bool,
    wrong_type_rejected: bool,
    case_insensitive_match: bool,
};

pub const UdpSendToReplyReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    request_source_port: u16,
    request_payload_length: u16,
    request_payload_hash: u64,
    invalid_peer_rejected: bool,
    zero_ttl_rejected: bool,
    cursor_preserved_on_rejection: bool,
    reply_identification: u16,
    reply_descriptor: u16,
    reply_next_cursor: u16,
    reply_frame_length: u16,
    send_to_identification: u16,
    send_to_descriptor: u16,
    send_to_next_cursor: u16,
    send_to_frame_length: u16,
    final_identification_cursor: u16,
    final_tx_cursor: u16,
    tx_submissions_delta: u64,
    tx_completion_enqueues: u64,
    tx_completion_dequeues: u64,
    rx_completion_enqueues: u64,
    completion_overflow: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
};

pub const UdpDiscardCloseReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    peer_port: u16,
    normal_close_rejected: bool,
    discarded_packets: u16,
    was_connected: bool,
    queue_enqueued: u64,
    queue_dequeued: u64,
    queue_high_water: u16,
    queue_dropped: u64,
    stale_close_rejected: bool,
    stale_force_close_rejected: bool,
    stale_receive_rejected: bool,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
    tx_completion_enqueues: u64,
    rx_completion_enqueues: u64,
};

pub const UdpPeekExactReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    first_payload_length: u16,
    first_identification: u16,
    repeated_preview_stable: bool,
    insufficient_rejected: bool,
    queue_preserved_on_rejection: bool,
    first_exact_copied: u16,
    first_exact_hash: u64,
    second_payload_length: u16,
    second_identification: u16,
    second_exact_copied: u16,
    second_exact_hash: u64,
    final_preview_empty: bool,
    endpoint_enqueued: u64,
    endpoint_dequeued: u64,
    endpoint_high_water: u16,
    endpoint_dropped: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
    tx_completion_enqueues: u64,
    rx_completion_enqueues: u64,
};

pub const UdpReceiveIntoReport = struct {
    socket_slot: u16,
    socket_generation: u32,
    local_port: u16,
    first_payload_length: u16,
    first_copied_length: u16,
    first_truncated: bool,
    first_copy_hash: u64,
    second_payload_length: u16,
    second_copied_length: u16,
    second_truncated: bool,
    second_copy_hash: u64,
    empty_payload_length: u16,
    empty_copied_length: u16,
    empty_truncated: bool,
    source_port: u16,
    endpoint_enqueued: u64,
    endpoint_dequeued: u64,
    endpoint_high_water: u16,
    endpoint_dropped: u64,
    final_registered_endpoints: u16,
    final_ephemeral_cursor: u16,
    ingress_enqueued: u64,
    ingress_dequeued: u64,
    packets_dispatched: u64,
    udp_dispatched: u64,
    tx_completion_enqueues: u64,
    rx_completion_enqueues: u64,
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
    udp_receive_into: UdpReceiveIntoReport,
    udp_peek_exact: UdpPeekExactReport,
    udp_discard_close: UdpDiscardCloseReport,
    udp_send_to_reply: UdpSendToReplyReport,
    dns_codec: DnsCodecReport,
    dns_transaction: DnsTransactionReport,
    dns_polling: DnsPollingReport,
    dns_alias: DnsAliasReport,
    dns_alias_transaction: DnsAliasTransactionReport,
    dns_retry: DnsRetryReport,
    dns_cache: DnsCacheReport,
    dns_cached_resolve: DnsCachedResolveReport,
    dns_automatic_transaction: DnsAutomaticTransactionReport,
    dns_automatic_cached_resolve: DnsAutomaticCachedResolveReport,
    dns_negative: DnsNegativeReport,
    dns_negative_cache: DnsNegativeCacheReport,
    dns_cancellation: DnsCancellationReport,
    dns_resolver_context: DnsResolverContextReport,
    ntp_codec: NtpCodecReport,
    ntp_transaction: NtpTransactionReport,
    ntp_polling: NtpPollingReport,
    ntp_retry: NtpRetryReport,
    ntp_client_context: NtpClientContextReport,
    ntp_clock: NtpClockReport,
    ntp_clock_polling: NtpClockPollingReport,
    ntp_projected_clock: NtpProjectedClockReport,
    ntp_reference_clock: NtpReferenceClockReport,
    ntp_service: NtpServiceReport,
    ntp_backoff: NtpBackoffReport,
    ntp_automatic_recovery: NtpAutomaticRecoveryReport,
    ntp_synchronized_recovery: NtpSynchronizedRecoveryReport,
    ntp_live_step_gate: NtpLiveStepGateReport,
    ntp_stale_step_retry: NtpStaleStepRetryReport,
    ntp_live_rejection_budget: NtpLiveRejectionBudgetReport,
    ntp_rejection_exhaustion: NtpRejectionExhaustionReport,
    ntp_discipline_recovery: NtpDisciplineRecoveryReport,
    ntp_live_quality_rejection_budget: NtpLiveQualityRejectionBudgetReport,
    ntp_quality_rejection_exhaustion: NtpQualityRejectionExhaustionReport,
    ntp_quality_recovery: NtpQualityRecoveryReport,
    ntp_client_server_switch: NtpClientServerSwitchReport,
    ntp_service_source_pool: NtpServiceSourcePoolReport,
    ntp_live_source_failover: NtpLiveSourceFailoverReport,
    ntp_thresholded_source_failover: NtpThresholdedSourceFailoverReport,
    ntp_source_wraparound: NtpSourceWraparoundReport,
    ntp_source_failure_reset: NtpSourceFailureResetReport,
    ntp_source_exhaustion: NtpSourceExhaustionReport,
    ntp_source_exhaustion_reset: NtpSourceExhaustionResetReport,
    ntp_operator_source_reset: NtpOperatorSourceResetReport,
    ntp_operator_source_refresh: NtpOperatorSourceRefreshReport,
    ntp_operator_source_failover: NtpOperatorSourceFailoverReport,
    ntp_stale_source_reply: NtpStaleSourceReplyReport,
    ntp_timestamp: NtpTimestampReport,
    ntp_automatic_timestamp: NtpAutomaticTimestampReport,
    ntp_quality: NtpQualityReport,
    ntp_health: NtpHealthReport,
    ntp_retry_policy: NtpRetryPolicyReport,
    ntp_recovery_policy: NtpRecoveryPolicyReport,
    ntp_step_policy: NtpStepPolicyReport,
    ntp_step_rejection_policy: NtpStepRejectionPolicyReport,
    ntp_quality_rejection_policy: NtpQualityRejectionPolicyReport,
    ntp_source_pool: NtpSourcePoolReport,
    ntp_source_rotation_policy: NtpSourceRotationPolicyReport,
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
    continuous_counter: *time_reference.ContinuousCounter,
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
        .next_dns_transaction_id = 0x5000,
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
    const udp_receive_into = verifyUdpReceiveInto(device) orelse {
        active_device_storage = null;
        return null;
    };
    const udp_peek_exact = verifyUdpPeekExact(device) orelse {
        active_device_storage = null;
        return null;
    };
    const udp_discard_close = verifyUdpDiscardClose(device) orelse {
        active_device_storage = null;
        return null;
    };
    const udp_send_to_reply = verifyUdpSendToReply(device) orelse {
        active_device_storage = null;
        return null;
    };
    const dns_codec = verifyDnsCodec() orelse {
        active_device_storage = null;
        return null;
    };
    const dns_transaction = verifyDnsTransaction(device) orelse {
        active_device_storage = null;
        return null;
    };
    const dns_polling = verifyDnsPolling(device) orelse {
        active_device_storage = null;
        return null;
    };
    const dns_alias = verifyDnsAlias() orelse {
        active_device_storage = null;
        return null;
    };
    const dns_alias_transaction = verifyDnsAliasTransaction(device) orelse {
        active_device_storage = null;
        return null;
    };
    const dns_retry = verifyDnsRetry(device) orelse {
        active_device_storage = null;
        return null;
    };
    const dns_cache = verifyDnsCache() orelse {
        active_device_storage = null;
        return null;
    };
    const dns_cached_resolve = verifyDnsCachedResolve(device) orelse {
        active_device_storage = null;
        return null;
    };
    const dns_automatic_transaction = verifyDnsAutomaticTransaction(device) orelse {
        active_device_storage = null;
        return null;
    };
    const dns_automatic_cached_resolve = verifyDnsAutomaticCachedResolve(device) orelse {
        active_device_storage = null;
        return null;
    };
    const dns_negative = verifyDnsNegative(device) orelse {
        active_device_storage = null;
        return null;
    };
    const dns_negative_cache = verifyDnsNegativeCache(device) orelse {
        active_device_storage = null;
        return null;
    };
    const dns_cancellation = verifyDnsCancellation(device) orelse {
        active_device_storage = null;
        return null;
    };
    const dns_resolver_context = verifyDnsResolverContext(device) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_codec = verifyNtpCodec() orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_transaction = verifyNtpTransaction(device) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_polling = verifyNtpPolling(device) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_retry = verifyNtpRetry(device) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_client_context = verifyNtpClientContext(device) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_clock = verifyNtpClock() orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_clock_polling = verifyNtpClockPolling(device) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_projected_clock = verifyNtpProjectedClock() orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_reference_clock = verifyNtpReferenceClock(device, continuous_counter) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_service = verifyNtpService(device, continuous_counter) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_backoff = verifyNtpServiceBackoff(device, continuous_counter) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_automatic_recovery = verifyNtpAutomaticRecovery(device, continuous_counter) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_synchronized_recovery = verifyNtpSynchronizedRecovery(device, continuous_counter) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_live_step_gate = verifyNtpLiveStepGate(device, continuous_counter) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_stale_step_retry = verifyNtpStaleStepRetry(device, continuous_counter) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_live_rejection_budget = verifyNtpLiveRejectionBudget(device, continuous_counter) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_rejection_exhaustion = verifyNtpRejectionExhaustion(device, continuous_counter) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_discipline_recovery = verifyNtpDisciplineRecovery(device, continuous_counter) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_live_quality_rejection_budget = verifyNtpLiveQualityRejectionBudget(device, continuous_counter) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_quality_rejection_exhaustion = verifyNtpQualityRejectionExhaustion(device, continuous_counter) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_quality_recovery = verifyNtpQualityRecovery(device, continuous_counter) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_client_server_switch = verifyNtpClientServerSwitch(device) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_service_source_pool = verifyNtpServiceSourcePool(device) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_live_source_failover = verifyNtpLiveSourceFailover(device, continuous_counter) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_thresholded_source_failover = verifyNtpThresholdedSourceFailover(device, continuous_counter) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_source_wraparound = verifyNtpSourceWraparound(device, continuous_counter) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_source_failure_reset = verifyNtpSourceFailureReset(device, continuous_counter) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_source_exhaustion = verifyNtpSourceExhaustion(device, continuous_counter) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_source_exhaustion_reset = verifyNtpSourceExhaustionReset(device, continuous_counter) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_operator_source_reset = verifyNtpOperatorSourceReset(device) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_operator_source_refresh = verifyNtpOperatorSourceRefresh(device, continuous_counter) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_operator_source_failover = verifyNtpOperatorSourceFailover(device, continuous_counter) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_stale_source_reply = verifyNtpStaleSourceReply(device, continuous_counter) orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_timestamp = verifyNtpTimestamp() orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_automatic_timestamp = verifyNtpAutomaticTimestamp() orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_quality = verifyNtpQuality() orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_health = verifyNtpHealth() orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_retry_policy = verifyNtpRetryPolicy() orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_recovery_policy = verifyNtpRecoveryPolicy() orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_step_policy = verifyNtpStepPolicy() orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_step_rejection_policy = verifyNtpStepRejectionPolicy() orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_quality_rejection_policy = verifyNtpQualityRejectionPolicy() orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_source_pool = verifyNtpSourcePool() orelse {
        active_device_storage = null;
        return null;
    };
    const ntp_source_rotation_policy = verifyNtpSourceRotationPolicy() orelse {
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
        .udp_receive_into = udp_receive_into,
        .udp_peek_exact = udp_peek_exact,
        .udp_discard_close = udp_discard_close,
        .udp_send_to_reply = udp_send_to_reply,
        .dns_codec = dns_codec,
        .dns_transaction = dns_transaction,
        .dns_polling = dns_polling,
        .dns_alias = dns_alias,
        .dns_alias_transaction = dns_alias_transaction,
        .dns_retry = dns_retry,
        .dns_cache = dns_cache,
        .dns_cached_resolve = dns_cached_resolve,
        .dns_automatic_transaction = dns_automatic_transaction,
        .dns_automatic_cached_resolve = dns_automatic_cached_resolve,
        .dns_negative = dns_negative,
        .dns_negative_cache = dns_negative_cache,
        .dns_cancellation = dns_cancellation,
        .dns_resolver_context = dns_resolver_context,
        .ntp_codec = ntp_codec,
        .ntp_transaction = ntp_transaction,
        .ntp_polling = ntp_polling,
        .ntp_retry = ntp_retry,
        .ntp_client_context = ntp_client_context,
        .ntp_clock = ntp_clock,
        .ntp_clock_polling = ntp_clock_polling,
        .ntp_projected_clock = ntp_projected_clock,
        .ntp_reference_clock = ntp_reference_clock,
        .ntp_service = ntp_service,
        .ntp_backoff = ntp_backoff,
        .ntp_automatic_recovery = ntp_automatic_recovery,
        .ntp_synchronized_recovery = ntp_synchronized_recovery,
        .ntp_live_step_gate = ntp_live_step_gate,
        .ntp_stale_step_retry = ntp_stale_step_retry,
        .ntp_live_rejection_budget = ntp_live_rejection_budget,
        .ntp_rejection_exhaustion = ntp_rejection_exhaustion,
        .ntp_discipline_recovery = ntp_discipline_recovery,
        .ntp_live_quality_rejection_budget = ntp_live_quality_rejection_budget,
        .ntp_quality_rejection_exhaustion = ntp_quality_rejection_exhaustion,
        .ntp_quality_recovery = ntp_quality_recovery,
        .ntp_client_server_switch = ntp_client_server_switch,
        .ntp_service_source_pool = ntp_service_source_pool,
        .ntp_live_source_failover = ntp_live_source_failover,
        .ntp_thresholded_source_failover = ntp_thresholded_source_failover,
        .ntp_source_wraparound = ntp_source_wraparound,
        .ntp_source_failure_reset = ntp_source_failure_reset,
        .ntp_source_exhaustion = ntp_source_exhaustion,
        .ntp_source_exhaustion_reset = ntp_source_exhaustion_reset,
        .ntp_operator_source_reset = ntp_operator_source_reset,
        .ntp_operator_source_refresh = ntp_operator_source_refresh,
        .ntp_operator_source_failover = ntp_operator_source_failover,
        .ntp_stale_source_reply = ntp_stale_source_reply,
        .ntp_timestamp = ntp_timestamp,
        .ntp_automatic_timestamp = ntp_automatic_timestamp,
        .ntp_quality = ntp_quality,
        .ntp_health = ntp_health,
        .ntp_retry_policy = ntp_retry_policy,
        .ntp_recovery_policy = ntp_recovery_policy,
        .ntp_step_policy = ntp_step_policy,
        .ntp_step_rejection_policy = ntp_step_rejection_policy,
        .ntp_quality_rejection_policy = ntp_quality_rejection_policy,
        .ntp_source_pool = ntp_source_pool,
        .ntp_source_rotation_policy = ntp_source_rotation_policy,
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

pub fn peekUdpDatagram(device: *Device, socket: UdpSocket) ?UdpDatagramInfo {
    const endpoint = udpSocketEndpoint(device, socket) orelse return null;
    const datagram = queuedUdpDatagram(device, endpoint) orelse return null;
    return .{
        .source_mac = datagram.source_mac,
        .destination_mac = datagram.destination_mac,
        .source_ipv4 = datagram.source_ipv4,
        .destination_ipv4 = datagram.destination_ipv4,
        .source_port = datagram.source_port,
        .destination_port = datagram.destination_port,
        .ttl = datagram.ttl,
        .identification = datagram.identification,
        .udp_checksum_present = datagram.udp_checksum_present,
        .payload_length = @intCast(datagram.payload.len),
    };
}

pub fn receiveUdpExact(
    device: *Device,
    socket: UdpSocket,
    output: []u8,
) ?UdpReceiveIntoResult {
    const info = peekUdpDatagram(device, socket) orelse return null;
    if (info.payload_length > output.len) return null;
    const result = receiveUdpInto(device, socket, output) orelse return null;
    if (result.truncated or result.copied_length != result.payload_length) return null;
    return result;
}

pub fn receiveUdpInto(
    device: *Device,
    socket: UdpSocket,
    output: []u8,
) ?UdpReceiveIntoResult {
    const endpoint = udpSocketEndpoint(device, socket) orelse return null;
    const datagram = queuedUdpDatagram(device, endpoint) orelse return null;
    const copied_length = @min(output.len, datagram.payload.len);
    @memcpy(output[0..copied_length], datagram.payload[0..copied_length]);
    endpoint.queue.tail = @intCast((endpoint.queue.tail + 1) % software_packet_queue_capacity);
    endpoint.queue.dequeued +|= 1;
    return .{
        .source_mac = datagram.source_mac,
        .destination_mac = datagram.destination_mac,
        .source_ipv4 = datagram.source_ipv4,
        .destination_ipv4 = datagram.destination_ipv4,
        .source_port = datagram.source_port,
        .destination_port = datagram.destination_port,
        .ttl = datagram.ttl,
        .identification = datagram.identification,
        .udp_checksum_present = datagram.udp_checksum_present,
        .payload_length = @intCast(datagram.payload.len),
        .copied_length = @intCast(copied_length),
        .truncated = copied_length != datagram.payload.len,
    };
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

pub fn sendUdpDatagramTo(
    device: *Device,
    socket: UdpSocket,
    peer: UdpPeer,
    ttl: u8,
    payload: []const u8,
) ?UdpTransmitResult {
    _ = udpSocketEndpoint(device, socket) orelse return null;
    if (!validUdpPeer(peer)) return null;
    var identification = device.next_udp_identification;
    if (identification == 0) identification = 1;
    const completion = sendUdpSocket(device, socket, .{
        .destination_mac = peer.mac,
        .destination_ipv4 = peer.ipv4,
        .destination_port = peer.port,
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

pub fn sendConnectedUdpDatagram(
    device: *Device,
    socket: UdpSocket,
    ttl: u8,
    payload: []const u8,
) ?UdpTransmitResult {
    const endpoint = udpSocketEndpoint(device, socket) orelse return null;
    if (!endpoint.peer_bound) return null;
    return sendUdpDatagramTo(device, socket, endpoint.peer, ttl, payload);
}

pub fn sendDnsAQuery(
    device: *Device,
    socket: UdpSocket,
    transaction_id: u16,
    name: []const u8,
) ?UdpTransmitResult {
    const endpoint = udpSocketEndpoint(device, socket) orelse return null;
    if (!endpoint.peer_bound or endpoint.peer.port != dns.server_port) return null;
    var query_buffer = std.mem.zeroes([512]u8);
    const query = dns.buildAQuery(&query_buffer, transaction_id, name) orelse return null;
    return sendConnectedUdpDatagram(device, socket, 64, query);
}

pub fn receiveDnsAResponse(
    device: *Device,
    socket: UdpSocket,
    transaction_id: u16,
    name: []const u8,
) ?DnsAResponse {
    const endpoint = udpSocketEndpoint(device, socket) orelse return null;
    if (!endpoint.peer_bound or endpoint.peer.port != dns.server_port) return null;
    const datagram = receiveUdpDatagram(device, socket) orelse return null;
    return dns.parseAResponse(datagram.payload(), transaction_id, name);
}

pub fn startDnsAQuery(
    device: *Device,
    socket: UdpSocket,
    transaction_id: u16,
    name: []const u8,
) ?DnsARequest {
    if (name.len > dns.maximum_name_bytes) return null;
    const transmit = sendDnsAQuery(device, socket, transaction_id, name) orelse return null;
    var request = DnsARequest{
        .socket = socket,
        .transaction_id = transaction_id,
        .name_length = @intCast(name.len),
        .name = std.mem.zeroes([dns.maximum_name_bytes]u8),
        .transmit = transmit,
        .transmissions = 1,
        .cancelled = false,
    };
    @memcpy(request.name[0..name.len], name);
    return request;
}

pub fn startAutomaticDnsAQuery(
    device: *Device,
    socket: UdpSocket,
    name: []const u8,
) ?DnsARequest {
    var transaction_id = device.next_dns_transaction_id;
    if (transaction_id == 0) transaction_id = 1;
    const request = startDnsAQuery(device, socket, transaction_id, name) orelse return null;
    device.next_dns_transaction_id = nextDnsTransactionId(transaction_id);
    return request;
}

pub fn openNtpClient(device: *Device, server_ipv4: [4]u8) ?NtpClient {
    const peer = UdpPeer{
        .mac = device.gateway_mac,
        .ipv4 = server_ipv4,
        .port = ntp.server_port,
    };
    if (!validUdpPeer(peer)) return null;
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (!connectUdpSocket(device, socket, peer)) {
        _ = closeUdpSocket(device, socket);
        return null;
    }
    return .{ .active = true, .socket = socket, .server_ipv4 = server_ipv4 };
}

pub fn switchNtpClientServer(
    device: *Device,
    client: *NtpClient,
    server_ipv4: [4]u8,
) bool {
    if (!client.active or !udpSocketActive(device, client.socket)) return false;
    const old_peer = udpSocketPeer(device, client.socket) orelse return false;
    if (old_peer.port != ntp.server_port or
        !std.meta.eql(old_peer.mac, device.gateway_mac) or
        !std.meta.eql(old_peer.ipv4, client.server_ipv4))
    {
        return false;
    }
    const new_peer = UdpPeer{
        .mac = device.gateway_mac,
        .ipv4 = server_ipv4,
        .port = ntp.server_port,
    };
    if (!validUdpPeer(new_peer)) return false;
    if (std.meta.eql(old_peer, new_peer)) {
        return std.meta.eql(client.server_ipv4, server_ipv4);
    }
    if (!disconnectUdpSocket(device, client.socket)) return false;
    if (!connectUdpSocket(device, client.socket, new_peer)) {
        _ = connectUdpSocket(device, client.socket, old_peer);
        return false;
    }
    client.server_ipv4 = server_ipv4;
    return true;
}

pub fn closeNtpClient(device: *Device, client: *NtpClient) bool {
    if (!client.active or !closeUdpSocket(device, client.socket)) return false;
    client.active = false;
    return true;
}

pub fn closeNtpClientDiscarding(
    device: *Device,
    client: *NtpClient,
) ?UdpDiscardCloseResult {
    if (!client.active) return null;
    const result = closeUdpSocketDiscarding(device, client.socket) orelse return null;
    client.active = false;
    return result;
}

pub fn startNtpClientRequest(
    device: *Device,
    client: *NtpClient,
    client_timestamp: u64,
) ?NtpRequest {
    if (!client.active or !udpSocketActive(device, client.socket)) return null;
    return startNtpRequest(device, client.socket, client_timestamp);
}

pub fn pollNtpClientRequest(
    device: *Device,
    client: *NtpClient,
    request: *const NtpRequest,
    budget: u16,
) NtpRequestPoll {
    if (!client.active or !udpSocketActive(device, client.socket) or
        !std.meta.eql(client.socket, request.socket))
    {
        return .{ .state = .inactive, .examined = 0, .rejected = 0, .response = null };
    }
    return pollNtpRequest(device, request, budget);
}

pub fn pollNtpClientClock(
    device: *Device,
    client: *NtpClient,
    request: *const NtpRequest,
    clock: *ntp.Clock,
    budget: u16,
) NtpClockPoll {
    const poll = pollNtpClientRequest(device, client, request, budget);
    var result = NtpClockPoll{
        .poll = poll,
        .apply_result = null,
    };
    if (poll.response) |response| {
        result.apply_result = ntp.applyResponse(clock, response);
    }
    return result;
}

pub fn pollNtpClientReferenceClock(
    device: *Device,
    client: *NtpClient,
    request: *const NtpRequest,
    clock: *ntp.ProjectedClock,
    counter: *time_reference.ContinuousCounter,
    budget: u16,
) NtpReferenceClockPoll {
    const poll = pollNtpClientRequest(device, client, request, budget);
    var result = NtpReferenceClockPoll{
        .poll = poll,
        .sample_tick = null,
        .apply_result = null,
    };
    if (poll.response) |response| {
        const sample_tick = counter.read();
        result.sample_tick = sample_tick;
        result.apply_result = ntp.applyResponseAt(
            clock,
            response,
            sample_tick,
            counter.frequency_hz,
        );
    }
    return result;
}

pub fn openNtpService(
    device: *Device,
    server_ipv4: [4]u8,
    retry_ticks: u64,
    refresh_ticks: u64,
) ?NtpService {
    return openNtpServiceWithPolicy(
        device,
        server_ipv4,
        retry_ticks,
        refresh_ticks,
        ntp.default_quality_policy,
    );
}

pub fn openNtpServiceWithPolicy(
    device: *Device,
    server_ipv4: [4]u8,
    retry_ticks: u64,
    refresh_ticks: u64,
    quality_policy: ntp.QualityPolicy,
) ?NtpService {
    return openNtpServiceWithPolicies(
        device,
        server_ipv4,
        refresh_ticks,
        quality_policy,
        .{
            .initial_interval_ticks = retry_ticks,
            .maximum_interval_ticks = retry_ticks,
            .maximum_retries = std.math.maxInt(u8),
        },
    );
}

pub fn openNtpServiceWithPolicies(
    device: *Device,
    server_ipv4: [4]u8,
    refresh_ticks: u64,
    quality_policy: ntp.QualityPolicy,
    retry_policy: ntp.RetryPolicy,
) ?NtpService {
    return openNtpServiceWithRecoveryPolicies(
        device,
        server_ipv4,
        refresh_ticks,
        quality_policy,
        retry_policy,
        null,
    );
}

pub fn openNtpServiceWithRecoveryPolicies(
    device: *Device,
    server_ipv4: [4]u8,
    refresh_ticks: u64,
    quality_policy: ntp.QualityPolicy,
    retry_policy: ntp.RetryPolicy,
    recovery_policy: ?ntp.RecoveryPolicy,
) ?NtpService {
    return openNtpServiceWithDisciplinePolicies(
        device,
        server_ipv4,
        refresh_ticks,
        quality_policy,
        ntp.default_clock_step_policy,
        retry_policy,
        recovery_policy,
    );
}

pub fn openNtpServiceWithDisciplinePolicies(
    device: *Device,
    server_ipv4: [4]u8,
    refresh_ticks: u64,
    quality_policy: ntp.QualityPolicy,
    step_policy: ntp.ClockStepPolicy,
    retry_policy: ntp.RetryPolicy,
    recovery_policy: ?ntp.RecoveryPolicy,
) ?NtpService {
    return openNtpServiceWithRejectionPolicies(
        device,
        server_ipv4,
        refresh_ticks,
        quality_policy,
        step_policy,
        ntp.default_step_rejection_policy,
        retry_policy,
        recovery_policy,
    );
}

pub fn openNtpServiceWithRejectionPolicies(
    device: *Device,
    server_ipv4: [4]u8,
    refresh_ticks: u64,
    quality_policy: ntp.QualityPolicy,
    step_policy: ntp.ClockStepPolicy,
    step_rejection_policy: ntp.StepRejectionPolicy,
    retry_policy: ntp.RetryPolicy,
    recovery_policy: ?ntp.RecoveryPolicy,
) ?NtpService {
    return openNtpServiceWithResponseRejectionPolicies(
        device,
        server_ipv4,
        refresh_ticks,
        quality_policy,
        ntp.default_quality_rejection_policy,
        step_policy,
        step_rejection_policy,
        retry_policy,
        recovery_policy,
    );
}

pub fn openNtpServiceWithResponseRejectionPolicies(
    device: *Device,
    server_ipv4: [4]u8,
    refresh_ticks: u64,
    quality_policy: ntp.QualityPolicy,
    quality_rejection_policy: ntp.QualityRejectionPolicy,
    step_policy: ntp.ClockStepPolicy,
    step_rejection_policy: ntp.StepRejectionPolicy,
    retry_policy: ntp.RetryPolicy,
    recovery_policy: ?ntp.RecoveryPolicy,
) ?NtpService {
    if (refresh_ticks == 0 or !ntp.qualityPolicyValid(quality_policy) or
        !ntp.qualityRejectionPolicyValid(quality_rejection_policy) or
        !ntp.clockStepPolicyValid(step_policy) or
        !ntp.stepRejectionPolicyValid(step_rejection_policy) or
        !ntp.retryPolicyValid(retry_policy)) return null;
    if (recovery_policy) |policy| {
        if (!ntp.recoveryPolicyValid(policy)) return null;
    }
    const client = openNtpClient(device, server_ipv4) orelse return null;
    return .{
        .active = true,
        .client = client,
        .clock = std.mem.zeroes(ntp.ProjectedClock),
        .request = std.mem.zeroes(NtpRequest),
        .request_active = false,
        .quality_policy = quality_policy,
        .quality_rejection_policy = quality_rejection_policy,
        .step_policy = step_policy,
        .step_rejection_policy = step_rejection_policy,
        .retry_policy = retry_policy,
        .recovery_policy = recovery_policy,
        .retry_interval_ticks = retry_policy.initial_interval_ticks,
        .refresh_interval_ticks = refresh_ticks,
        .retry_deadline_tick = 0,
        .refresh_deadline_tick = 0,
        .request_retry_attempts = 0,
        .retry_exhausted = false,
        .requests_started = 0,
        .retries = 0,
        .retry_limit_hits = 0,
        .last_timeout_tick = 0,
        .recovery_deadline_tick = 0,
        .automatic_recoveries = 0,
        .recovery_exhausted = false,
        .recovery_limit_hits = 0,
        .recovery_successes = 0,
        .source_pool = null,
        .source_rotation_policy = null,
        .current_source_index = 0,
        .pending_source_index = null,
        .consecutive_source_failures = 0,
        .source_rotations = 0,
        .responses = 0,
        .quality_accepted = 0,
        .quality_rejected = 0,
        .quality_invalid_policy_rejected = 0,
        .quality_stratum_rejected = 0,
        .quality_root_delay_rejected = 0,
        .quality_root_dispersion_rejected = 0,
        .request_quality_rejections = 0,
        .quality_forced_retries = 0,
        .request_step_rejections = 0,
        .discipline_forced_retries = 0,
        .step_accepted = 0,
        .step_rejected = 0,
        .step_invalid_policy_rejected = 0,
        .step_stale_rejected = 0,
        .step_excessive_forward_rejected = 0,
    };
}

pub fn openNtpServiceWithSourcePoolPolicies(
    device: *Device,
    source_pool: ntp.SourcePool,
    source_rotation_policy: ntp.SourceRotationPolicy,
    refresh_ticks: u64,
    quality_policy: ntp.QualityPolicy,
    quality_rejection_policy: ntp.QualityRejectionPolicy,
    step_policy: ntp.ClockStepPolicy,
    step_rejection_policy: ntp.StepRejectionPolicy,
    retry_policy: ntp.RetryPolicy,
    recovery_policy: ?ntp.RecoveryPolicy,
) ?NtpService {
    if (!ntp.sourcePoolValid(source_pool) or
        !ntp.sourceRotationPolicyValid(source_rotation_policy) or
        source_rotation_policy.source_count != source_pool.count)
    {
        return null;
    }
    const initial_server = ntp.sourcePoolServer(source_pool, 0) orelse return null;
    var service = openNtpServiceWithResponseRejectionPolicies(
        device,
        initial_server,
        refresh_ticks,
        quality_policy,
        quality_rejection_policy,
        step_policy,
        step_rejection_policy,
        retry_policy,
        recovery_policy,
    ) orelse return null;
    service.source_pool = source_pool;
    service.source_rotation_policy = source_rotation_policy;
    service.current_source_index = 0;
    service.pending_source_index = null;
    service.consecutive_source_failures = 0;
    service.source_rotations = 0;
    return service;
}

pub fn closeNtpService(device: *Device, service: *NtpService) bool {
    if (!service.active) return false;
    if (service.request_active) {
        _ = cancelNtpRequest(&service.request);
        service.request_active = false;
    }
    _ = closeNtpClientDiscarding(device, &service.client) orelse return false;
    service.active = false;
    return true;
}

pub fn clearNtpServiceTimeout(service: *NtpService) bool {
    if (!service.active or service.request_active or !service.retry_exhausted) return false;
    clearNtpServiceTimeoutState(service);
    return true;
}

fn clearNtpServiceTimeoutState(service: *NtpService) void {
    service.retry_exhausted = false;
    service.request_retry_attempts = 0;
    service.request_quality_rejections = 0;
    service.request_step_rejections = 0;
    service.recovery_deadline_tick = 0;
    service.pending_source_index = null;
    service.consecutive_source_failures = 0;
    service.automatic_recoveries = 0;
    service.recovery_exhausted = false;
}

pub fn resetNtpServiceTimeoutToSource(
    device: *Device,
    service: *NtpService,
    source_index: u8,
) bool {
    if (!service.active or !service.client.active or service.request_active or
        !service.retry_exhausted or !udpSocketActive(device, service.client.socket))
        return false;
    const pool = service.source_pool orelse return false;
    const policy = service.source_rotation_policy orelse return false;
    if (!ntp.sourcePoolValid(pool) or !ntp.sourceRotationPolicyValid(policy) or
        policy.source_count != pool.count or source_index >= pool.count)
        return false;
    const target_server = ntp.sourcePoolServer(pool, source_index) orelse return false;
    if (!switchNtpClientServer(device, &service.client, target_server)) return false;
    service.current_source_index = source_index;
    clearNtpServiceTimeoutState(service);
    return true;
}

pub fn readNtpServiceHealth(
    service: *const NtpService,
    current_tick: u64,
    holdover_after_ticks: u64,
    expire_after_ticks: u64,
) ?NtpServiceHealth {
    if (holdover_after_ticks == 0 or expire_after_ticks <= holdover_after_ticks) return null;
    const base = NtpServiceHealth{
        .state = .inactive,
        .current_time = null,
        .sample_age_ticks = 0,
        .awaiting_response = service.request_active,
        .retry_deadline_tick = service.retry_deadline_tick,
        .refresh_deadline_tick = service.refresh_deadline_tick,
        .requests_started = service.requests_started,
        .retries = service.retries,
        .responses = service.responses,
        .quality_accepted = service.quality_accepted,
        .quality_rejected = service.quality_rejected,
        .quality_rejection_policy = service.quality_rejection_policy,
        .request_quality_rejections = service.request_quality_rejections,
        .quality_forced_retries = service.quality_forced_retries,
        .step_rejection_policy = service.step_rejection_policy,
        .request_step_rejections = service.request_step_rejections,
        .discipline_forced_retries = service.discipline_forced_retries,
        .step_accepted = service.step_accepted,
        .step_rejected = service.step_rejected,
        .step_invalid_policy_rejected = service.step_invalid_policy_rejected,
        .step_stale_rejected = service.step_stale_rejected,
        .step_excessive_forward_rejected = service.step_excessive_forward_rejected,
        .request_retry_attempts = service.request_retry_attempts,
        .retry_exhausted = service.retry_exhausted,
        .retry_limit_hits = service.retry_limit_hits,
        .last_timeout_tick = service.last_timeout_tick,
        .recovery_deadline_tick = service.recovery_deadline_tick,
        .automatic_recoveries = service.automatic_recoveries,
        .recovery_exhausted = service.recovery_exhausted,
        .recovery_limit_hits = service.recovery_limit_hits,
        .recovery_successes = service.recovery_successes,
        .source_pool = service.source_pool,
        .source_rotation_policy = service.source_rotation_policy,
        .current_source_index = service.current_source_index,
        .pending_source_index = service.pending_source_index,
        .current_server_ipv4 = service.client.server_ipv4,
        .consecutive_source_failures = service.consecutive_source_failures,
        .source_rotations = service.source_rotations,
    };
    if (!service.active or !service.client.active) return base;
    if (!service.clock.clock.synchronized) {
        var unsynchronized = base;
        unsynchronized.state = .unsynchronized;
        return unsynchronized;
    }
    if (current_tick < service.clock.anchor_tick) return null;
    const age = current_tick - service.clock.anchor_tick;
    var result = base;
    result.sample_age_ticks = age;
    if (age >= expire_after_ticks) {
        result.state = .expired;
        return result;
    }
    result.current_time = ntp.readProjectedClockAt(&service.clock, current_tick) orelse return null;
    result.state = if (age >= holdover_after_ticks) .holdover else .synchronized;
    return result;
}

pub fn selectNtpServiceTimestamp(
    service: *const NtpService,
    current_tick: u64,
    bootstrap_timestamp: u64,
) ?u64 {
    if (service.clock.clock.synchronized) {
        return ntp.projectedTimestampAt(&service.clock, current_tick);
    }
    if (bootstrap_timestamp == 0) return null;
    return bootstrap_timestamp;
}

pub fn stepNtpServiceAutomatic(
    device: *Device,
    service: *NtpService,
    counter: *time_reference.ContinuousCounter,
    now_tick: u64,
    bootstrap_timestamp: u64,
    budget: u16,
) ?NtpServiceStep {
    if (!service.active or !service.client.active or !udpSocketActive(device, service.client.socket)) {
        return stepNtpService(device, service, counter, now_tick, bootstrap_timestamp, budget);
    }
    if (service.request_active) {
        return stepNtpService(device, service, counter, now_tick, service.request.client_timestamp, budget);
    }
    if (service.retry_exhausted) {
        const recovery_timestamp = if (service.clock.clock.synchronized)
            ntp.projectedTimestampAt(&service.clock, now_tick) orelse return null
        else
            service.request.client_timestamp;
        return stepNtpService(device, service, counter, now_tick, recovery_timestamp, budget);
    }
    const start_due = !service.clock.clock.synchronized or now_tick >= service.refresh_deadline_tick;
    if (!start_due) {
        return stepNtpService(device, service, counter, now_tick, 0, budget);
    }
    const timestamp = selectNtpServiceTimestamp(service, now_tick, bootstrap_timestamp) orelse return null;
    return stepNtpService(device, service, counter, now_tick, timestamp, budget);
}

fn recordNtpServiceQualityRejection(service: *NtpService, result: ntp.QualityResult) void {
    service.quality_rejected +|= 1;
    switch (result) {
        .accepted => {},
        .invalid_policy => service.quality_invalid_policy_rejected +|= 1,
        .stratum => service.quality_stratum_rejected +|= 1,
        .root_delay => service.quality_root_delay_rejected +|= 1,
        .root_dispersion => service.quality_root_dispersion_rejected +|= 1,
    }
}

fn recordNtpServiceStepRejection(service: *NtpService, result: ntp.ClockStepResult) void {
    service.step_rejected +|= 1;
    switch (result) {
        .accepted => {},
        .invalid_policy => service.step_invalid_policy_rejected +|= 1,
        .stale => service.step_stale_rejected +|= 1,
        .excessive_forward_step => service.step_excessive_forward_rejected +|= 1,
    }
}

fn retryWaitAfterTransmission(service: *const NtpService) ?u64 {
    if (service.request_retry_attempts < service.retry_policy.maximum_retries) {
        return ntp.retryIntervalForAttempt(service.retry_policy, service.request_retry_attempts);
    }
    return ntp.retryIntervalForAttempt(
        service.retry_policy,
        service.retry_policy.maximum_retries - 1,
    );
}

fn timedOutServiceStep(recovery_state: ?ntp.RecoveryState) NtpServiceStep {
    return .{
        .state = .timed_out,
        .poll = .{ .state = .pending, .examined = 0, .rejected = 0, .response = null },
        .transmit = null,
        .sample_tick = null,
        .apply_result = null,
        .quality_result = null,
        .quality_rejection_action = null,
        .quality_rejection_count = 0,
        .quality_rejections_remaining = 0,
        .step_result = null,
        .step_rejection_action = null,
        .step_rejection_count = 0,
        .step_rejections_remaining = 0,
        .next_retry_interval_ticks = null,
        .recovery_state = recovery_state,
        .start_reason = .none,
        .retried = false,
        .timeout_reached = false,
        .recovery_started = false,
    };
}

fn recordNtpServiceSourceFailure(service: *NtpService) void {
    const pool = service.source_pool orelse return;
    const policy = service.source_rotation_policy orelse return;
    if (policy.source_count != pool.count or service.current_source_index >= pool.count) return;
    service.consecutive_source_failures +|= 1;
    const decision = ntp.evaluateSourceRotation(
        policy,
        service.current_source_index,
        service.consecutive_source_failures,
    );
    service.pending_source_index = switch (decision.action) {
        .rotate => decision.next_source_index,
        .stay => null,
        .invalid_policy, .invalid_source => null,
    };
}

fn switchPendingNtpServiceSource(device: *Device, service: *NtpService) bool {
    const pending_index = service.pending_source_index orelse return true;
    const pool = service.source_pool orelse return false;
    const target_server = ntp.sourcePoolServer(pool, pending_index) orelse return false;
    if (!switchNtpClientServer(device, &service.client, target_server)) return false;
    service.current_source_index = pending_index;
    service.pending_source_index = null;
    service.consecutive_source_failures = 0;
    service.source_rotations +|= 1;
    return true;
}

pub fn stepNtpService(
    device: *Device,
    service: *NtpService,
    counter: *time_reference.ContinuousCounter,
    now_tick: u64,
    client_timestamp: u64,
    budget: u16,
) ?NtpServiceStep {
    const inactive_poll = NtpRequestPoll{ .state = .inactive, .examined = 0, .rejected = 0, .response = null };
    if (!service.active or !service.client.active or !udpSocketActive(device, service.client.socket)) {
        return .{
            .state = .inactive,
            .poll = inactive_poll,
            .transmit = null,
            .sample_tick = null,
            .apply_result = null,
            .quality_result = null,
            .quality_rejection_action = null,
            .quality_rejection_count = 0,
            .quality_rejections_remaining = 0,
            .step_result = null,
            .step_rejection_action = null,
            .step_rejection_count = 0,
            .step_rejections_remaining = 0,
            .next_retry_interval_ticks = null,
            .recovery_state = null,
            .start_reason = .none,
            .retried = false,
            .timeout_reached = false,
            .recovery_started = false,
        };
    }

    var recovery_started = false;
    if (service.retry_exhausted and !service.request_active) {
        const policy = service.recovery_policy orelse return timedOutServiceStep(null);
        const decision = ntp.evaluateRecovery(
            policy,
            service.last_timeout_tick,
            service.automatic_recoveries,
            now_tick,
        );
        service.recovery_deadline_tick = decision.deadline_tick;
        switch (decision.state) {
            .invalid_policy => return null,
            .waiting => return timedOutServiceStep(.waiting),
            .exhausted => {
                if (!service.recovery_exhausted) {
                    service.recovery_exhausted = true;
                    service.recovery_limit_hits +|= 1;
                }
                return timedOutServiceStep(.exhausted);
            },
            .ready => {
                if (!switchPendingNtpServiceSource(device, service)) return null;
                service.retry_exhausted = false;
                service.request_retry_attempts = 0;
                service.request_quality_rejections = 0;
                service.request_step_rejections = 0;
                service.recovery_exhausted = false;
                service.automatic_recoveries += 1;
                recovery_started = true;
            },
        }
    }

    if (service.request_active) {
        const poll = pollNtpClientRequest(device, &service.client, &service.request, budget);
        var out = NtpServiceStep{
            .state = .awaiting,
            .poll = poll,
            .transmit = null,
            .sample_tick = null,
            .apply_result = null,
            .quality_result = null,
            .quality_rejection_action = null,
            .quality_rejection_count = 0,
            .quality_rejections_remaining = 0,
            .step_result = null,
            .step_rejection_action = null,
            .step_rejection_count = 0,
            .step_rejections_remaining = 0,
            .next_retry_interval_ticks = null,
            .recovery_state = null,
            .start_reason = .none,
            .retried = false,
            .timeout_reached = false,
            .recovery_started = false,
        };
        if (poll.state == .inactive) {
            out.state = .inactive;
            return out;
        }
        if (poll.response) |response| {
            const quality_result = ntp.evaluateQuality(response, service.quality_policy);
            out.quality_result = quality_result;
            if (quality_result == .accepted) {
                service.quality_accepted +|= 1;
                service.request_quality_rejections = 0;
                const sample_tick = counter.read();
                out.sample_tick = sample_tick;
                const step_result = ntp.evaluateResponseStepAt(
                    &service.clock,
                    response,
                    sample_tick,
                    service.step_policy,
                ) orelse return null;
                out.step_result = step_result;
                if (step_result == .accepted) {
                    const apply_result = ntp.applyResponseAt(
                        &service.clock,
                        response,
                        sample_tick,
                        counter.frequency_hz,
                    ) orelse return null;
                    out.apply_result = apply_result;
                    service.step_accepted +|= 1;
                    service.request_active = false;
                    service.request_retry_attempts = 0;
                    service.request_quality_rejections = 0;
                    service.request_step_rejections = 0;
                    service.retry_exhausted = false;
                    service.recovery_deadline_tick = 0;
                    if (service.automatic_recoveries > 0) service.recovery_successes +|= 1;
                    service.automatic_recoveries = 0;
                    service.recovery_exhausted = false;
                    service.pending_source_index = null;
                    service.consecutive_source_failures = 0;
                    service.responses +|= 1;
                    service.refresh_deadline_tick = sample_tick +| service.refresh_interval_ticks;
                    out.state = .idle;
                    return out;
                }
                recordNtpServiceStepRejection(service, step_result);
                service.request_step_rejections +|= 1;
                const rejection_decision = ntp.evaluateStepRejectionBudget(
                    service.step_rejection_policy,
                    service.request_step_rejections,
                );
                out.step_rejection_action = rejection_decision.action;
                out.step_rejection_count = service.request_step_rejections;
                out.step_rejections_remaining = rejection_decision.remaining_before_retry;
                if (rejection_decision.action == .retry_now) {
                    const interval = ntp.retryIntervalForAttempt(
                        service.retry_policy,
                        service.request_retry_attempts,
                    );
                    if (interval == null) {
                        _ = cancelNtpRequest(&service.request);
                        service.request_active = false;
                        service.retry_exhausted = true;
                        service.retry_limit_hits +|= 1;
                        service.last_timeout_tick = now_tick;
                        recordNtpServiceSourceFailure(service);
                        out.state = .timed_out;
                        out.timeout_reached = true;
                        if (service.recovery_policy) |policy| {
                            const recovery_decision = ntp.evaluateRecovery(
                                policy,
                                now_tick,
                                service.automatic_recoveries,
                                now_tick,
                            );
                            service.recovery_deadline_tick = recovery_decision.deadline_tick;
                            out.recovery_state = recovery_decision.state;
                            if (recovery_decision.state == .exhausted and !service.recovery_exhausted) {
                                service.recovery_exhausted = true;
                                service.recovery_limit_hits +|= 1;
                            }
                        }
                        return out;
                    }
                    out.transmit = retryNtpClientRequest(device, &service.client, &service.request) orelse return null;
                    service.request_retry_attempts += 1;
                    service.request_quality_rejections = 0;
                    service.request_step_rejections = 0;
                    service.retries +|= 1;
                    service.discipline_forced_retries +|= 1;
                    const next_wait = retryWaitAfterTransmission(service) orelse return null;
                    service.retry_deadline_tick = now_tick +| next_wait;
                    out.next_retry_interval_ticks = next_wait;
                    out.retried = true;
                    return out;
                }
            } else {
                recordNtpServiceQualityRejection(service, quality_result);
                service.request_quality_rejections +|= 1;
                const rejection_decision = ntp.evaluateQualityRejectionBudget(
                    service.quality_rejection_policy,
                    service.request_quality_rejections,
                );
                out.quality_rejection_action = rejection_decision.action;
                out.quality_rejection_count = service.request_quality_rejections;
                out.quality_rejections_remaining = rejection_decision.remaining_before_retry;
                if (rejection_decision.action == .retry_now) {
                    const interval = ntp.retryIntervalForAttempt(
                        service.retry_policy,
                        service.request_retry_attempts,
                    );
                    if (interval == null) {
                        _ = cancelNtpRequest(&service.request);
                        service.request_active = false;
                        service.retry_exhausted = true;
                        service.retry_limit_hits +|= 1;
                        service.last_timeout_tick = now_tick;
                        recordNtpServiceSourceFailure(service);
                        out.state = .timed_out;
                        out.timeout_reached = true;
                        if (service.recovery_policy) |policy| {
                            const recovery_decision = ntp.evaluateRecovery(
                                policy,
                                now_tick,
                                service.automatic_recoveries,
                                now_tick,
                            );
                            service.recovery_deadline_tick = recovery_decision.deadline_tick;
                            out.recovery_state = recovery_decision.state;
                            if (recovery_decision.state == .exhausted and !service.recovery_exhausted) {
                                service.recovery_exhausted = true;
                                service.recovery_limit_hits +|= 1;
                            }
                        }
                        return out;
                    }
                    out.transmit = retryNtpClientRequest(device, &service.client, &service.request) orelse return null;
                    service.request_retry_attempts += 1;
                    service.request_quality_rejections = 0;
                    service.request_step_rejections = 0;
                    service.retries +|= 1;
                    service.quality_forced_retries +|= 1;
                    const next_wait = retryWaitAfterTransmission(service) orelse return null;
                    service.retry_deadline_tick = now_tick +| next_wait;
                    out.next_retry_interval_ticks = next_wait;
                    out.retried = true;
                    return out;
                }
            }
        }
        if (now_tick >= service.retry_deadline_tick) {
            const interval = ntp.retryIntervalForAttempt(
                service.retry_policy,
                service.request_retry_attempts,
            );
            if (interval == null) {
                _ = cancelNtpRequest(&service.request);
                service.request_active = false;
                service.retry_exhausted = true;
                service.retry_limit_hits +|= 1;
                service.last_timeout_tick = now_tick;
                recordNtpServiceSourceFailure(service);
                out.state = .timed_out;
                out.timeout_reached = true;
                if (service.recovery_policy) |policy| {
                    const decision = ntp.evaluateRecovery(
                        policy,
                        now_tick,
                        service.automatic_recoveries,
                        now_tick,
                    );
                    service.recovery_deadline_tick = decision.deadline_tick;
                    out.recovery_state = decision.state;
                    if (decision.state == .exhausted and !service.recovery_exhausted) {
                        service.recovery_exhausted = true;
                        service.recovery_limit_hits +|= 1;
                    }
                }
                return out;
            }
            out.transmit = retryNtpClientRequest(device, &service.client, &service.request) orelse return null;
            service.request_retry_attempts += 1;
            service.request_quality_rejections = 0;
            service.request_step_rejections = 0;
            service.retries +|= 1;
            const next_wait = retryWaitAfterTransmission(service) orelse return null;
            service.retry_deadline_tick = now_tick +| next_wait;
            out.next_retry_interval_ticks = next_wait;
            out.retried = true;
        }
        return out;
    }

    const why: NtpServiceStartReason = if (recovery_started)
        .recovery
    else if (!service.clock.clock.synchronized)
        .initial
    else if (now_tick >= service.refresh_deadline_tick)
        .refresh
    else
        .none;
    if (why == .none) {
        return .{
            .state = .idle,
            .poll = .{ .state = .pending, .examined = 0, .rejected = 0, .response = null },
            .transmit = null,
            .sample_tick = null,
            .apply_result = null,
            .quality_result = null,
            .quality_rejection_action = null,
            .quality_rejection_count = 0,
            .quality_rejections_remaining = 0,
            .step_result = null,
            .step_rejection_action = null,
            .step_rejection_count = 0,
            .step_rejections_remaining = 0,
            .next_retry_interval_ticks = null,
            .recovery_state = null,
            .start_reason = .none,
            .retried = false,
            .timeout_reached = false,
            .recovery_started = false,
        };
    }
    const initial_wait = ntp.retryIntervalForAttempt(service.retry_policy, 0) orelse return null;
    const req = startNtpClientRequest(device, &service.client, client_timestamp) orelse return null;
    service.request = req;
    service.request_active = true;
    service.request_retry_attempts = 0;
    service.request_quality_rejections = 0;
    service.request_step_rejections = 0;
    service.retry_exhausted = false;
    service.retry_deadline_tick = now_tick +| initial_wait;
    service.requests_started +|= 1;
    return .{
        .state = .awaiting,
        .poll = .{ .state = .pending, .examined = 0, .rejected = 0, .response = null },
        .transmit = req.transmit,
        .sample_tick = null,
        .apply_result = null,
        .quality_result = null,
        .quality_rejection_action = null,
        .quality_rejection_count = 0,
        .quality_rejections_remaining = 0,
        .step_result = null,
        .step_rejection_action = null,
        .step_rejection_count = 0,
        .step_rejections_remaining = 0,
        .next_retry_interval_ticks = initial_wait,
        .recovery_state = if (recovery_started) .ready else null,
        .start_reason = why,
        .retried = false,
        .timeout_reached = false,
        .recovery_started = recovery_started,
    };
}
pub fn retryNtpClientRequest(
    device: *Device,
    client: *NtpClient,
    request: *NtpRequest,
) ?UdpTransmitResult {
    if (!client.active or !std.meta.eql(client.socket, request.socket)) return null;
    return retryNtpRequest(device, request);
}

pub fn startNtpRequest(
    device: *Device,
    socket: UdpSocket,
    client_timestamp: u64,
) ?NtpRequest {
    const transmit = sendNtpRequest(device, socket, client_timestamp) orelse return null;
    return .{
        .socket = socket,
        .client_timestamp = client_timestamp,
        .transmit = transmit,
        .transmissions = 1,
        .cancelled = false,
    };
}

pub fn cancelNtpRequest(request: *NtpRequest) bool {
    if (request.cancelled) return false;
    request.cancelled = true;
    return true;
}

pub fn retryNtpRequest(device: *Device, request: *NtpRequest) ?UdpTransmitResult {
    if (request.cancelled or !udpSocketActive(device, request.socket)) return null;
    const transmit = sendNtpRequest(device, request.socket, request.client_timestamp) orelse return null;
    request.transmit = transmit;
    request.transmissions +|= 1;
    return transmit;
}

pub fn pollNtpRequest(
    device: *Device,
    request: *const NtpRequest,
    budget: u16,
) NtpRequestPoll {
    if (request.cancelled or !udpSocketActive(device, request.socket)) {
        return .{ .state = .inactive, .examined = 0, .rejected = 0, .response = null };
    }
    var result = NtpRequestPoll{
        .state = .pending,
        .examined = 0,
        .rejected = 0,
        .response = null,
    };
    while (result.examined < budget and udpSocketReadable(device, request.socket)) {
        const datagram = receiveUdpDatagram(device, request.socket) orelse {
            result.state = .inactive;
            return result;
        };
        result.examined +|= 1;
        if (ntp.parseServerResponse(datagram.payload(), request.client_timestamp)) |response| {
            result.state = .resolved;
            result.response = response;
            return result;
        }
        result.rejected +|= 1;
    }
    return result;
}

pub fn sendNtpRequest(
    device: *Device,
    socket: UdpSocket,
    client_timestamp: u64,
) ?UdpTransmitResult {
    const endpoint = udpSocketEndpoint(device, socket) orelse return null;
    if (!endpoint.peer_bound or endpoint.peer.port != ntp.server_port) return null;
    var request_buffer = std.mem.zeroes([ntp.packet_bytes]u8);
    const request = ntp.buildClientRequest(&request_buffer, client_timestamp) orelse return null;
    return sendConnectedUdpDatagram(device, socket, 64, request);
}

pub fn receiveNtpResponse(
    device: *Device,
    socket: UdpSocket,
    client_timestamp: u64,
) ?NtpResponse {
    const endpoint = udpSocketEndpoint(device, socket) orelse return null;
    if (!endpoint.peer_bound or endpoint.peer.port != ntp.server_port) return null;
    const datagram = receiveUdpDatagram(device, socket) orelse return null;
    return ntp.parseServerResponse(datagram.payload(), client_timestamp);
}

pub fn openDnsResolver(device: *Device, server_ipv4: [4]u8) ?DnsResolver {
    const peer = UdpPeer{
        .mac = device.gateway_mac,
        .ipv4 = server_ipv4,
        .port = dns.server_port,
    };
    if (!validUdpPeer(peer)) return null;
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (!connectUdpSocket(device, socket, peer)) {
        _ = closeUdpSocket(device, socket);
        return null;
    }
    return .{
        .active = true,
        .socket = socket,
        .server_ipv4 = server_ipv4,
        .cache = std.mem.zeroes(dns.Cache),
    };
}

pub fn closeDnsResolver(device: *Device, resolver: *DnsResolver) bool {
    if (!resolver.active or !closeUdpSocket(device, resolver.socket)) return false;
    resolver.active = false;
    return true;
}

pub fn closeDnsResolverDiscarding(
    device: *Device,
    resolver: *DnsResolver,
) ?UdpDiscardCloseResult {
    if (!resolver.active) return null;
    const result = closeUdpSocketDiscarding(device, resolver.socket) orelse return null;
    resolver.active = false;
    return result;
}

pub fn startDnsResolverA(
    device: *Device,
    resolver: *DnsResolver,
    now: u64,
    name: []const u8,
) ?DnsCachedOutcomeStart {
    if (!resolver.active or !udpSocketActive(device, resolver.socket)) return null;
    return startAutomaticDnsAResolveCachedOutcome(
        device,
        resolver.socket,
        &resolver.cache,
        now,
        name,
    );
}

pub fn pollDnsResolverA(
    device: *Device,
    resolver: *DnsResolver,
    request: *const DnsARequest,
    now: u64,
    budget: u16,
    negative_ttl: u32,
) DnsAQueryPoll {
    if (!resolver.active or !udpSocketActive(device, resolver.socket) or
        !std.meta.eql(resolver.socket, request.socket))
    {
        return .{ .state = .inactive, .examined = 0, .rejected = 0, .response = null };
    }
    return pollDnsAResolveCachedOutcome(
        device,
        request,
        &resolver.cache,
        now,
        budget,
        negative_ttl,
    );
}

pub fn startAutomaticDnsAResolveCachedOutcome(
    device: *Device,
    socket: UdpSocket,
    cache: *dns.Cache,
    now: u64,
    name: []const u8,
) ?DnsCachedOutcomeStart {
    if (dns.lookupCachedOutcome(cache, name, now)) |cached| {
        return switch (cached) {
            .answer => |answer| .{ .cached = answer },
            .name_error => |ttl| .{ .not_found = ttl },
        };
    }
    const request = startAutomaticDnsAQuery(device, socket, name) orelse return null;
    return .{ .pending = request };
}

pub fn pollDnsAResolveCachedOutcome(
    device: *Device,
    request: *const DnsARequest,
    cache: *dns.Cache,
    now: u64,
    budget: u16,
    negative_ttl: u32,
) DnsAQueryPoll {
    const result = pollDnsAQuery(device, request, budget);
    const name = request.name[0..@as(usize, request.name_length)];
    if (result.response) |response| {
        _ = dns.storeCachedA(cache, name, response.address, response.ttl, now);
    } else if (result.state == .not_found) {
        _ = dns.storeCachedNameError(cache, name, negative_ttl, now);
    }
    return result;
}

pub fn startAutomaticDnsAResolve(
    device: *Device,
    socket: UdpSocket,
    cache: *dns.Cache,
    now: u64,
    name: []const u8,
) ?DnsResolveStart {
    if (dns.lookupCachedA(cache, name, now)) |cached| return .{ .cached = cached };
    const request = startAutomaticDnsAQuery(device, socket, name) orelse return null;
    return .{ .pending = request };
}

pub fn startDnsAResolve(
    device: *Device,
    socket: UdpSocket,
    cache: *dns.Cache,
    now: u64,
    transaction_id: u16,
    name: []const u8,
) ?DnsResolveStart {
    if (dns.lookupCachedA(cache, name, now)) |cached| return .{ .cached = cached };
    const request = startDnsAQuery(device, socket, transaction_id, name) orelse return null;
    return .{ .pending = request };
}

pub fn pollDnsAResolve(
    device: *Device,
    request: *const DnsARequest,
    cache: *dns.Cache,
    now: u64,
    budget: u16,
) DnsAQueryPoll {
    const result = pollDnsAQuery(device, request, budget);
    if (result.response) |response| {
        _ = dns.storeCachedA(
            cache,
            request.name[0..@as(usize, request.name_length)],
            response.address,
            response.ttl,
            now,
        );
    }
    return result;
}

pub fn cancelDnsAQuery(request: *DnsARequest) bool {
    if (request.cancelled) return false;
    request.cancelled = true;
    return true;
}

pub fn retryDnsAQuery(device: *Device, request: *DnsARequest) ?UdpTransmitResult {
    if (request.cancelled or !udpSocketActive(device, request.socket)) return null;
    const name = request.name[0..@as(usize, request.name_length)];
    const transmit = sendDnsAQuery(device, request.socket, request.transaction_id, name) orelse return null;
    request.transmit = transmit;
    request.transmissions +|= 1;
    return transmit;
}

pub fn pollDnsAQuery(
    device: *Device,
    request: *const DnsARequest,
    budget: u16,
) DnsAQueryPoll {
    if (request.cancelled or !udpSocketActive(device, request.socket)) {
        return .{ .state = .inactive, .examined = 0, .rejected = 0, .response = null };
    }
    var result = DnsAQueryPoll{
        .state = .pending,
        .examined = 0,
        .rejected = 0,
        .response = null,
    };
    const name = request.name[0..@as(usize, request.name_length)];
    while (result.examined < budget and udpSocketReadable(device, request.socket)) {
        const datagram = receiveUdpDatagram(device, request.socket) orelse {
            result.state = .inactive;
            return result;
        };
        result.examined +|= 1;
        const outcome = dns.parseAOutcome(
            datagram.payload(),
            request.transaction_id,
            name,
        ) orelse {
            result.rejected +|= 1;
            continue;
        };
        switch (outcome) {
            .answer => |response| {
                result.state = .resolved;
                result.response = response;
                return result;
            },
            .name_error => {
                result.state = .not_found;
                return result;
            },
        }
    }
    return result;
}

pub fn sendUdpReply(
    device: *Device,
    socket: UdpSocket,
    request: *const ReceivedUdpDatagram,
    ttl: u8,
    payload: []const u8,
) ?UdpTransmitResult {
    const endpoint = udpSocketEndpoint(device, socket) orelse return null;
    if (request.destination_port != endpoint.port or
        !std.mem.eql(u8, &request.destination_mac, &device.local_mac) or
        !std.mem.eql(u8, &request.destination_ipv4, &device.local_ipv4))
    {
        return null;
    }
    return sendUdpDatagramTo(device, socket, .{
        .mac = request.source_mac,
        .ipv4 = request.source_ipv4,
        .port = request.source_port,
    }, ttl, payload);
}

pub fn closeUdpSocket(device: *Device, socket: UdpSocket) bool {
    _ = udpSocketEndpoint(device, socket) orelse return false;
    return unregisterUdpEndpoint(device, socket.endpoint_index);
}

pub fn closeUdpSocketDiscarding(device: *Device, socket: UdpSocket) ?UdpDiscardCloseResult {
    const endpoint = udpSocketEndpoint(device, socket) orelse return null;
    const local_port = endpoint.port;
    const generation = endpoint.generation;
    const was_connected = endpoint.peer_bound;
    const peer_port = if (endpoint.peer_bound) endpoint.peer.port else 0;
    const queue_enqueued = endpoint.queue.enqueued;
    const queue_high_water = endpoint.queue.high_water;
    const queue_dropped = endpoint.queue.dropped;
    var discarded_packets: u16 = 0;
    while (dequeueQueuedPacket(&endpoint.queue) != null) discarded_packets +|= 1;
    const queue_dequeued = endpoint.queue.dequeued;
    if (!unregisterUdpEndpoint(device, socket.endpoint_index)) return null;
    return .{
        .local_port = local_port,
        .generation = generation,
        .was_connected = was_connected,
        .peer_port = peer_port,
        .discarded_packets = discarded_packets,
        .queue_enqueued = queue_enqueued,
        .queue_dequeued = queue_dequeued,
        .queue_high_water = queue_high_water,
        .queue_dropped = queue_dropped,
    };
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

fn nextDnsTransactionId(transaction_id: u16) u16 {
    const next = transaction_id +% 1;
    return if (next == 0) 1 else next;
}

fn allocateUdpGeneration(device: *Device) u32 {
    var generation = device.next_udp_generation;
    if (generation == 0) generation = 1;
    device.next_udp_generation = generation +% 1;
    if (device.next_udp_generation == 0) device.next_udp_generation = 1;
    return generation;
}

fn queuedUdpDatagram(device: *const Device, endpoint: *const UdpEndpoint) ?udp.Datagram {
    if (endpoint.queue.tail == endpoint.queue.head) return null;
    const packet = &endpoint.queue.entries[endpoint.queue.tail];
    return udp.parseFrame(packet.bytes[0..packet.length], .{
        .destination_mac = device.local_mac,
        .source_mac = if (endpoint.peer_bound) endpoint.peer.mac else null,
        .destination_ipv4 = device.local_ipv4,
        .source_ipv4 = if (endpoint.peer_bound) endpoint.peer.ipv4 else null,
        .destination_port = endpoint.port,
        .source_port = if (endpoint.peer_bound) endpoint.peer.port else null,
    });
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

fn enqueueNtpServiceResponse(
    device: *Device,
    socket: UdpSocket,
    server_ipv4: [4]u8,
    client_timestamp: u64,
    server_timestamp: u64,
    identification: u16,
    source_descriptor: u16,
) bool {
    return enqueueNtpServiceResponseWithQuality(
        device,
        socket,
        server_ipv4,
        client_timestamp,
        server_timestamp,
        2,
        0x00010000,
        0x00008000,
        identification,
        source_descriptor,
    );
}

fn enqueueNtpServiceResponseWithQuality(
    device: *Device,
    socket: UdpSocket,
    server_ipv4: [4]u8,
    client_timestamp: u64,
    server_timestamp: u64,
    stratum: u8,
    root_delay: u32,
    root_dispersion: u32,
    identification: u16,
    source_descriptor: u16,
) bool {
    var payload_buffer = std.mem.zeroes([ntp.packet_bytes]u8);
    const payload = ntp.buildServerResponseWithQuality(
        &payload_buffer,
        client_timestamp,
        server_timestamp - 0x40000000,
        server_timestamp,
        stratum,
        root_delay,
        root_dispersion,
    ) orelse return false;
    var frame = std.mem.zeroes([128]u8);
    const frame_length = udp.buildFrame(&frame, .{
        .source_mac = device.gateway_mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = server_ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = ntp.server_port,
        .destination_port = socket.local_port,
        .identification = identification,
        .payload = payload,
    }) orelse return false;
    var packet = std.mem.zeroes(Packet);
    packet.length = frame_length;
    packet.source_descriptor = source_descriptor;
    @memcpy(packet.bytes[0..frame_length], frame[0..frame_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return false;
    const dispatch = dispatchPacketBatch(device, 1);
    return dispatch.examined == 1 and dispatch.routed == 1 and dispatch.dropped == 0;
}
fn verifyNtpRejectionExhaustion(
    device: *Device,
    counter: *time_reference.ContinuousCounter,
) ?NtpRejectionExhaustionReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_193 or
        device.next_udp_generation != 52 or device.tx_producer != 2 or
        device.next_udp_identification != 63 or device.next_dns_transaction_id != 8 or
        completionQueueEnqueued(&tx_completion_queue) != 90 or
        completionQueueDequeued(&tx_completion_queue) != 90 or
        completionQueueEnqueued(&rx_completion_queue) != 22 or
        device.software_rx_queue.enqueued != 95 or device.software_rx_queue.dequeued != 95 or
        device.packets_dispatched != 84 or device.udp_packets_dispatched != 83 or
        counter.frequency_hz == 0 or counter.counter_bits == 0)
    {
        return null;
    }
    const server = [4]u8{ 10, 0, 2, 4 };
    const rejection_policy = ntp.StepRejectionPolicy{ .maximum_rejections_per_request = 1 };
    const retry_policy = ntp.RetryPolicy{
        .initial_interval_ticks = 1,
        .maximum_interval_ticks = 1,
        .maximum_retries = 1,
    };
    var service = openNtpServiceWithRejectionPolicies(
        device,
        server,
        2,
        ntp.default_quality_policy,
        .{ .maximum_forward_seconds = 4, .maximum_forward_fraction = 0 },
        rejection_policy,
        retry_policy,
        null,
    ) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 52 or socket.local_port != 49_193 or
        device.next_ephemeral_udp_port != 49_194 or device.next_udp_generation != 53 or
        device.udp_endpoint_count != 3) return null;

    const submissions_before = device.tx_submissions;
    const start_tick = counter.read();
    const initial = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const initial_tx = initial.transmit orelse return null;
    if (initial_tx.identification != 63 or initial_tx.completion.descriptor_index != 2 or
        initial_tx.completion.next_cursor != 3) return null;

    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        0x7E00,
        0xEE00,
    )) return null;
    const first = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 1) orelse return null;
    if (first.state != .idle or first.quality_result != .accepted or first.step_result != .accepted or
        first.apply_result != .accepted or service.responses != 1) return null;

    const refresh_tick = service.refresh_deadline_tick;
    const refresh = stepNtpServiceAutomatic(device, &service, counter, refresh_tick, 0, 0) orelse return null;
    const refresh_tx = refresh.transmit orelse return null;
    const refresh_client_timestamp = service.request.client_timestamp;
    if (refresh_tx.identification != 64 or refresh_tx.completion.descriptor_index != 3 or
        refresh_tx.completion.next_cursor != 4) return null;

    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        0x7E01,
        0xEE01,
    )) return null;
    const first_rejection = stepNtpServiceAutomatic(device, &service, counter, refresh_tick, 0, 1) orelse return null;
    const first_quality_result = first_rejection.quality_result orelse return null;
    const first_step_result = first_rejection.step_result orelse return null;
    const first_rejection_action = first_rejection.step_rejection_action orelse return null;
    const first_forced_retry_tx = first_rejection.transmit orelse return null;
    const first_forced_retry_timestamp_preserved = service.request.client_timestamp == refresh_client_timestamp;
    if (first_quality_result != .accepted or first_step_result != .stale or
        first_rejection_action != .retry_now or first_rejection.step_rejection_count != 1 or
        first_rejection.step_rejections_remaining != 0 or !first_rejection.retried or
        first_rejection.timeout_reached or !first_forced_retry_timestamp_preserved or
        first_forced_retry_tx.identification != 65 or
        first_forced_retry_tx.completion.descriptor_index != 4 or
        first_forced_retry_tx.completion.next_cursor != 5 or service.request.transmissions != 2 or
        service.request_retry_attempts != 1 or service.request_step_rejections != 0 or
        service.retries != 1 or service.discipline_forced_retries != 1)
        return null;

    const excessive_server_timestamp = ntp.fixture_server_timestamp + (@as(u64, 100) << 32);
    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        excessive_server_timestamp,
        0x7E02,
        0xEE02,
    )) return null;
    const clock_before_second = service.clock;
    const second_rejection = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        refresh_tick,
        0,
        1,
    ) orelse return null;
    const second_quality_result = second_rejection.quality_result orelse return null;
    const second_step_result = second_rejection.step_result orelse return null;
    const second_rejection_action = second_rejection.step_rejection_action orelse return null;
    const second_apply_absent = second_rejection.apply_result == null;
    const second_clock_preserved = std.meta.eql(service.clock, clock_before_second);
    const timeout_transmit_absent = second_rejection.transmit == null;
    const request_cancelled = service.request.cancelled;
    const request_inactive = !service.request_active;
    if (second_quality_result != .accepted or second_step_result != .excessive_forward_step or
        second_rejection_action != .retry_now or second_rejection.step_rejection_count != 1 or
        second_rejection.step_rejections_remaining != 0 or !second_apply_absent or
        !second_clock_preserved or second_rejection.state != .timed_out or
        !second_rejection.timeout_reached or !timeout_transmit_absent or !request_cancelled or
        !request_inactive or !service.retry_exhausted or service.retry_limit_hits != 1 or
        service.discipline_forced_retries != 1 or service.retries != 1 or
        service.request_step_rejections != 1 or service.step_stale_rejected != 1 or
        service.step_excessive_forward_rejected != 1)
        return null;

    const timeout_snapshot = service;
    const id_at_timeout = device.next_udp_identification;
    const tx_at_timeout = device.tx_producer;
    const submissions_at_timeout = device.tx_submissions;
    const latched = stepNtpServiceAutomatic(device, &service, counter, refresh_tick + 1, 0, 0) orelse return null;
    const timeout_latched = latched.state == .timed_out and !latched.timeout_reached and
        latched.transmit == null and std.meta.eql(service, timeout_snapshot) and
        device.next_udp_identification == id_at_timeout and device.tx_producer == tx_at_timeout and
        device.tx_submissions == submissions_at_timeout;
    if (!timeout_latched) return null;

    const health = readNtpServiceHealth(&service, refresh_tick + 1, 1, 100) orelse return null;
    const health_reports_exhaustion = health.current_time != null and health.retry_exhausted and
        health.retry_limit_hits == 1 and health.request_step_rejections == 1 and
        health.discipline_forced_retries == 1 and !health.awaiting_response;
    if (!health_reports_exhaustion) return null;

    const clear_succeeded = clearNtpServiceTimeout(&service);
    const rejection_count_cleared = service.request_step_rejections == 0 and
        service.request_retry_attempts == 0 and !service.retry_exhausted;
    const duplicate_clear_rejected = !clearNtpServiceTimeout(&service);
    if (!clear_succeeded or !rejection_count_cleared or !duplicate_clear_rejected) return null;

    const close_succeeded = closeNtpService(device, &service);
    if (!close_succeeded or service.active or service.client.active or service.request_active) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_194 or
        device.next_udp_generation != 53 or device.next_udp_identification != 66 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 5 or
        device.tx_submissions != submissions_before + 3 or txe != 93 or txd != 93 or rxe != 22 or
        overflow != 0 or device.software_rx_queue.enqueued != 98 or
        device.software_rx_queue.dequeued != 98 or device.packets_dispatched != 87 or
        device.udp_packets_dispatched != 86 or service.quality_accepted != 3 or
        service.quality_rejected != 0 or service.step_accepted != 1 or service.step_rejected != 2 or
        service.requests_started != 2 or service.retries != 1 or service.responses != 1)
        return null;

    return .{
        .source_kind = counter.reference.kind,
        .frequency_hz = counter.frequency_hz,
        .counter_bits = counter.counter_bits,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .maximum_rejections = rejection_policy.maximum_rejections_per_request,
        .maximum_retries = retry_policy.maximum_retries,
        .initial_identification = initial_tx.identification,
        .initial_descriptor = initial_tx.completion.descriptor_index,
        .initial_next_cursor = initial_tx.completion.next_cursor,
        .refresh_identification = refresh_tx.identification,
        .refresh_descriptor = refresh_tx.completion.descriptor_index,
        .refresh_next_cursor = refresh_tx.completion.next_cursor,
        .refresh_client_timestamp = refresh_client_timestamp,
        .first_quality_result = first_quality_result,
        .first_step_result = first_step_result,
        .first_rejection_action = first_rejection_action,
        .first_forced_retry_identification = first_forced_retry_tx.identification,
        .first_forced_retry_descriptor = first_forced_retry_tx.completion.descriptor_index,
        .first_forced_retry_next_cursor = first_forced_retry_tx.completion.next_cursor,
        .first_forced_retry_timestamp_preserved = first_forced_retry_timestamp_preserved,
        .first_forced_retry_transmissions = service.request.transmissions,
        .second_quality_result = second_quality_result,
        .second_step_result = second_step_result,
        .second_rejection_action = second_rejection_action,
        .second_rejection_count = second_rejection.step_rejection_count,
        .second_remaining = second_rejection.step_rejections_remaining,
        .second_apply_absent = second_apply_absent,
        .second_clock_preserved = second_clock_preserved,
        .timeout_state = second_rejection.state,
        .timeout_reached = second_rejection.timeout_reached,
        .timeout_transmit_absent = timeout_transmit_absent,
        .request_cancelled = request_cancelled,
        .request_inactive = request_inactive,
        .retry_exhausted = timeout_snapshot.retry_exhausted,
        .retry_limit_hits = timeout_snapshot.retry_limit_hits,
        .discipline_forced_retries = timeout_snapshot.discipline_forced_retries,
        .timeout_latched = timeout_latched,
        .health_reports_exhaustion = health_reports_exhaustion,
        .clear_succeeded = clear_succeeded,
        .duplicate_clear_rejected = duplicate_clear_rejected,
        .rejection_count_cleared = rejection_count_cleared,
        .quality_accepted = service.quality_accepted,
        .quality_rejected = service.quality_rejected,
        .step_accepted = service.step_accepted,
        .step_rejected = service.step_rejected,
        .step_stale_rejected = service.step_stale_rejected,
        .step_excessive_forward_rejected = service.step_excessive_forward_rejected,
        .requests_started = service.requests_started,
        .retries = service.retries,
        .responses = service.responses,
        .close_succeeded = close_succeeded,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpStaleSourceReply(
    device: *Device,
    counter: *time_reference.ContinuousCounter,
) ?NtpStaleSourceReplyReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_209 or
        device.next_udp_generation != 68 or device.tx_producer != 3 or
        device.next_udp_identification != 120 or device.next_dns_transaction_id != 8 or
        completionQueueEnqueued(&tx_completion_queue) != 147 or
        completionQueueDequeued(&tx_completion_queue) != 147 or
        completionQueueEnqueued(&rx_completion_queue) != 22 or
        device.software_rx_queue.enqueued != 128 or device.software_rx_queue.dequeued != 128 or
        device.packets_dispatched != 117 or device.udp_packets_dispatched != 116 or
        counter.frequency_hz == 0 or counter.counter_bits == 0)
    {
        return null;
    }

    var source_pool = ntp.SourcePool{
        .count = 3,
        .servers = std.mem.zeroes([ntp.maximum_source_pool_entries][4]u8),
    };
    source_pool.servers[0] = .{ 10, 0, 2, 4 };
    source_pool.servers[1] = .{ 10, 0, 2, 5 };
    source_pool.servers[2] = .{ 10, 0, 2, 6 };
    var service = openNtpServiceWithSourcePoolPolicies(
        device,
        source_pool,
        .{ .source_count = 3, .failures_before_rotation = 1 },
        2,
        ntp.default_quality_policy,
        ntp.default_quality_rejection_policy,
        .{ .maximum_forward_seconds = 4, .maximum_forward_fraction = 0 },
        ntp.default_step_rejection_policy,
        .{ .initial_interval_ticks = 1, .maximum_interval_ticks = 1, .maximum_retries = 1 },
        .{ .cooldown_ticks = 2, .maximum_recoveries = 2 },
    ) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 68 or socket.local_port != 49_209 or
        device.udp_endpoint_count != 3 or device.next_ephemeral_udp_port != 49_210 or
        device.next_udp_generation != 69)
        return null;

    const submissions_before = device.tx_submissions;
    const start_tick = counter.read();
    var transmit_identifications = [2]u16{ 0, 0 };
    var transmit_descriptors = [2]u16{ 0, 0 };
    var transmit_next_cursors = [2]u16{ 0, 0 };

    const initial = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const initial_tx = initial.transmit orelse return null;
    transmit_identifications[0] = initial_tx.identification;
    transmit_descriptors[0] = initial_tx.completion.descriptor_index;
    transmit_next_cursors[0] = initial_tx.completion.next_cursor;
    if (initial.state != .awaiting or initial.start_reason != .initial or
        initial_tx.identification != 120 or initial_tx.completion.descriptor_index != 3 or
        initial_tx.completion.next_cursor != 4)
        return null;

    if (!enqueueNtpServiceResponse(
        device,
        socket,
        source_pool.servers[0],
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        0x8D00,
        0xFD00,
    )) return null;
    const initial_sync = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 1) orelse return null;
    const initial_sample_tick = initial_sync.sample_tick orelse return null;
    if (initial_sync.state != .idle or initial_sync.quality_result != .accepted or
        initial_sync.step_result != .accepted or initial_sync.apply_result != .accepted)
        return null;

    if (!switchNtpClientServer(device, &service.client, source_pool.servers[1])) return null;
    service.current_source_index = 1;
    service.pending_source_index = 2;
    service.consecutive_source_failures = 1;
    service.source_rotations = 2;
    service.request_active = false;
    service.request.cancelled = true;
    service.request_retry_attempts = 1;
    service.request_quality_rejections = 0;
    service.request_step_rejections = 0;
    service.retry_exhausted = true;
    service.requests_started = 6;
    service.retries = 4;
    service.responses = 1;
    service.retry_limit_hits = 4;
    service.last_timeout_tick = initial_sample_tick + 2;
    service.recovery_deadline_tick = initial_sample_tick + 4;
    service.automatic_recoveries = 0;
    service.recovery_exhausted = false;
    service.recovery_limit_hits = 1;
    service.recovery_successes = 0;

    const recovery_tick = service.recovery_deadline_tick;
    const expected_recovery_timestamp = ntp.projectedTimestampAt(&service.clock, recovery_tick) orelse return null;
    const recovery = stepNtpServiceAutomatic(device, &service, counter, recovery_tick, 0, 0) orelse return null;
    const recovery_tx = recovery.transmit orelse return null;
    transmit_identifications[1] = recovery_tx.identification;
    transmit_descriptors[1] = recovery_tx.completion.descriptor_index;
    transmit_next_cursors[1] = recovery_tx.completion.next_cursor;
    const recovery_timestamp = service.request.client_timestamp;
    const recovery_started = recovery.state == .awaiting and recovery.start_reason == .recovery and
        recovery.recovery_state == .ready and recovery.recovery_started and
        recovery_timestamp == expected_recovery_timestamp and service.automatic_recoveries == 1;
    const recovery_switched = service.current_source_index == 2 and service.pending_source_index == null and
        service.consecutive_source_failures == 0 and service.source_rotations == 3 and
        std.meta.eql(service.client.server_ipv4, source_pool.servers[2]);
    const same_socket_preserved = std.meta.eql(service.client.socket, socket);
    if (!recovery_started or !recovery_switched or !same_socket_preserved or
        recovery_tx.identification != 121 or recovery_tx.completion.descriptor_index != 4 or
        recovery_tx.completion.next_cursor != 5)
        return null;

    const peer_drops_before = device.peer_mismatch_udp_packets_dropped;
    const clock_before_old_source = service.clock;
    const request_before_old_source = service.request;
    const old_source_enqueue_result = enqueueNtpServiceResponse(
        device,
        socket,
        source_pool.servers[1],
        service.request.client_timestamp,
        ntp.fixture_server_timestamp + (@as(u64, 2) << 32),
        0x8D01,
        0xFD01,
    );
    const peer_drop_delta = device.peer_mismatch_udp_packets_dropped - peer_drops_before;
    const old_source_rejected = !old_source_enqueue_result and peer_drop_delta == 1 and
        device.packets_dispatched == 118 and device.udp_packets_dispatched == 117;
    if (!old_source_rejected) return null;

    const after_old_source = stepNtpServiceAutomatic(device, &service, counter, recovery_tick, 0, 1) orelse return null;
    const old_source_no_sample = after_old_source.state == .awaiting and
        after_old_source.poll.state == .pending and after_old_source.poll.examined == 0 and
        after_old_source.poll.rejected == 0 and after_old_source.poll.response == null and
        after_old_source.sample_tick == null and after_old_source.quality_result == null and
        after_old_source.step_result == null and after_old_source.apply_result == null and
        after_old_source.transmit == null;
    const old_source_clock_preserved = std.meta.eql(service.clock, clock_before_old_source);
    const old_source_request_preserved = std.meta.eql(service.request, request_before_old_source) and
        service.request_active and service.quality_accepted == 1 and service.quality_rejected == 0 and
        service.step_accepted == 1 and service.step_rejected == 0 and service.responses == 1;
    if (!old_source_no_sample or !old_source_clock_preserved or !old_source_request_preserved) return null;

    const accepted_server_timestamp = ntp.fixture_server_timestamp + (@as(u64, 2) << 32);
    if (!enqueueNtpServiceResponse(
        device,
        socket,
        source_pool.servers[2],
        service.request.client_timestamp,
        accepted_server_timestamp,
        0x8D02,
        0xFD02,
    )) return null;
    const accepted = stepNtpServiceAutomatic(device, &service, counter, recovery_tick, 0, 1) orelse return null;
    const accepted_quality_result = accepted.quality_result orelse return null;
    const accepted_step_result = accepted.step_result orelse return null;
    const accepted_sample_tick = accepted.sample_tick orelse return null;
    const accepted_time = ntp.readProjectedClockAt(&service.clock, accepted_sample_tick) orelse return null;
    const accepted_state_clean = accepted.state == .idle and accepted_quality_result == .accepted and
        accepted_step_result == .accepted and accepted.apply_result == .accepted and
        accepted_time.seconds == ntp.fixture_unix_seconds + 2 and accepted_time.fraction == 0x80000000 and
        service.current_source_index == 2 and std.meta.eql(service.client.server_ipv4, source_pool.servers[2]) and
        service.pending_source_index == null and service.consecutive_source_failures == 0 and
        !service.retry_exhausted and !service.recovery_exhausted and service.automatic_recoveries == 0 and
        service.source_rotations == 3 and service.recovery_successes == 1;
    if (!accepted_state_clean) return null;

    const health = readNtpServiceHealth(&service, accepted_sample_tick, 1, 100) orelse return null;
    const health_reports_source = health.current_source_index == 2 and health.pending_source_index == null and
        health.consecutive_source_failures == 0 and health.source_rotations == 3 and
        std.meta.eql(health.current_server_ipv4, source_pool.servers[2]);
    const health_reports_recovery = health.state == .synchronized and health.current_time != null and
        !health.awaiting_response and !health.retry_exhausted and !health.recovery_exhausted and
        health.recovery_successes == 1;
    if (!health_reports_source or !health_reports_recovery) return null;

    const close_succeeded = closeNtpService(device, &service);
    if (!close_succeeded or service.active or service.client.active or service.request_active) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_210 or
        device.next_udp_generation != 69 or device.next_udp_identification != 122 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 5 or
        device.tx_submissions != submissions_before + 2 or txe != 149 or txd != 149 or rxe != 22 or
        overflow != 0 or device.software_rx_queue.enqueued != 131 or
        device.software_rx_queue.dequeued != 131 or device.packets_dispatched != 119 or
        device.udp_packets_dispatched != 118 or device.peer_mismatch_udp_packets_dropped != peer_drops_before + 1 or
        service.quality_accepted != 2 or service.quality_rejected != 0 or
        service.step_accepted != 2 or service.step_rejected != 0 or service.requests_started != 7 or
        service.retries != 4 or service.responses != 2 or service.retry_limit_hits != 4 or
        service.recovery_limit_hits != 1 or service.recovery_successes != 1 or service.source_rotations != 3)
        return null;

    return .{
        .source_kind = counter.reference.kind,
        .frequency_hz = counter.frequency_hz,
        .counter_bits = counter.counter_bits,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .source_count = source_pool.count,
        .previous_source_index = 1,
        .current_source_index = 2,
        .previous_server = source_pool.servers[1],
        .current_server = source_pool.servers[2],
        .transmit_identifications = transmit_identifications,
        .transmit_descriptors = transmit_descriptors,
        .transmit_next_cursors = transmit_next_cursors,
        .recovery_timestamp = recovery_timestamp,
        .recovery_started = recovery_started,
        .recovery_switched = recovery_switched,
        .same_socket_preserved = same_socket_preserved,
        .old_source_rejected = old_source_rejected,
        .peer_drop_delta = peer_drop_delta,
        .old_source_no_sample = old_source_no_sample,
        .old_source_clock_preserved = old_source_clock_preserved,
        .old_source_request_preserved = old_source_request_preserved,
        .accepted_quality_result = accepted_quality_result,
        .accepted_step_result = accepted_step_result,
        .accepted_sample_tick = accepted_sample_tick,
        .accepted_seconds = accepted_time.seconds,
        .accepted_fraction = accepted_time.fraction,
        .accepted_state_clean = accepted_state_clean,
        .health_reports_source = health_reports_source,
        .health_reports_recovery = health_reports_recovery,
        .quality_accepted = service.quality_accepted,
        .quality_rejected = service.quality_rejected,
        .step_accepted = service.step_accepted,
        .step_rejected = service.step_rejected,
        .requests_started = service.requests_started,
        .retries = service.retries,
        .responses = service.responses,
        .retry_limit_hits = service.retry_limit_hits,
        .recovery_limit_hits = service.recovery_limit_hits,
        .recovery_successes = service.recovery_successes,
        .close_succeeded = close_succeeded,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .final_generation_cursor = device.next_udp_generation,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpOperatorSourceFailover(
    device: *Device,
    counter: *time_reference.ContinuousCounter,
) ?NtpOperatorSourceFailoverReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_208 or
        device.next_udp_generation != 67 or device.tx_producer != 6 or
        device.next_udp_identification != 115 or device.next_dns_transaction_id != 8 or
        completionQueueEnqueued(&tx_completion_queue) != 142 or
        completionQueueDequeued(&tx_completion_queue) != 142 or
        completionQueueEnqueued(&rx_completion_queue) != 22 or
        device.software_rx_queue.enqueued != 125 or device.software_rx_queue.dequeued != 125 or
        device.packets_dispatched != 114 or device.udp_packets_dispatched != 113 or
        counter.frequency_hz == 0 or counter.counter_bits == 0)
    {
        return null;
    }

    var source_pool = ntp.SourcePool{
        .count = 3,
        .servers = std.mem.zeroes([ntp.maximum_source_pool_entries][4]u8),
    };
    source_pool.servers[0] = .{ 10, 0, 2, 4 };
    source_pool.servers[1] = .{ 10, 0, 2, 5 };
    source_pool.servers[2] = .{ 10, 0, 2, 6 };
    const rotation_policy = ntp.SourceRotationPolicy{
        .source_count = 3,
        .failures_before_rotation = 1,
    };
    const retry_policy = ntp.RetryPolicy{
        .initial_interval_ticks = 1,
        .maximum_interval_ticks = 1,
        .maximum_retries = 1,
    };
    const recovery_policy = ntp.RecoveryPolicy{
        .cooldown_ticks = 2,
        .maximum_recoveries = 2,
    };
    var service = openNtpServiceWithSourcePoolPolicies(
        device,
        source_pool,
        rotation_policy,
        2,
        ntp.default_quality_policy,
        ntp.default_quality_rejection_policy,
        .{ .maximum_forward_seconds = 4, .maximum_forward_fraction = 0 },
        ntp.default_step_rejection_policy,
        retry_policy,
        recovery_policy,
    ) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 67 or socket.local_port != 49_208 or
        device.udp_endpoint_count != 3 or device.next_ephemeral_udp_port != 49_209 or
        device.next_udp_generation != 68)
        return null;

    const submissions_before = device.tx_submissions;
    const start_tick = counter.read();
    var transmit_identifications = [5]u16{ 0, 0, 0, 0, 0 };
    var transmit_descriptors = [5]u16{ 0, 0, 0, 0, 0 };
    var transmit_next_cursors = [5]u16{ 0, 0, 0, 0, 0 };

    const initial = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const initial_tx = initial.transmit orelse return null;
    transmit_identifications[0] = initial_tx.identification;
    transmit_descriptors[0] = initial_tx.completion.descriptor_index;
    transmit_next_cursors[0] = initial_tx.completion.next_cursor;
    if (initial.state != .awaiting or initial.start_reason != .initial or
        initial_tx.identification != 115 or initial_tx.completion.descriptor_index != 6 or
        initial_tx.completion.next_cursor != 7)
        return null;

    if (!enqueueNtpServiceResponse(
        device,
        socket,
        source_pool.servers[0],
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        0x8C00,
        0xFC00,
    )) return null;
    const initial_sync = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 1) orelse return null;
    const initial_sample_tick = initial_sync.sample_tick orelse return null;
    if (initial_sync.state != .idle or initial_sync.quality_result != .accepted or
        initial_sync.step_result != .accepted or initial_sync.apply_result != .accepted or
        service.responses != 1 or service.refresh_deadline_tick != initial_sample_tick + 2)
        return null;

    if (!switchNtpClientServer(device, &service.client, source_pool.servers[2])) return null;
    service.current_source_index = 2;
    service.pending_source_index = 0;
    service.consecutive_source_failures = 1;
    service.source_rotations = 2;
    service.request_active = false;
    service.request.cancelled = true;
    service.request_retry_attempts = 1;
    service.request_quality_rejections = 1;
    service.request_step_rejections = 1;
    service.retry_exhausted = true;
    service.requests_started = 4;
    service.retries = 3;
    service.responses = 1;
    service.retry_limit_hits = 3;
    service.last_timeout_tick = initial_sample_tick + 4;
    service.recovery_deadline_tick = initial_sample_tick + 6;
    service.automatic_recoveries = 2;
    service.recovery_exhausted = true;
    service.recovery_limit_hits = 1;
    service.recovery_successes = 0;

    const reset_tick = initial_sample_tick + 10;
    const clock_before_reset = service.clock;
    if (!resetNtpServiceTimeoutToSource(device, &service, 1)) return null;
    if (!std.meta.eql(service.clock, clock_before_reset) or service.current_source_index != 1 or
        !std.meta.eql(service.client.server_ipv4, source_pool.servers[1]) or
        !std.meta.eql(service.client.socket, socket) or service.source_rotations != 2 or
        service.retry_exhausted or service.recovery_exhausted or service.pending_source_index != null or
        service.consecutive_source_failures != 0 or service.automatic_recoveries != 0)
        return null;

    const expected_operator_refresh = ntp.projectedTimestampAt(&service.clock, reset_tick) orelse return null;
    const operator_refresh = stepNtpServiceAutomatic(device, &service, counter, reset_tick, 0, 0) orelse return null;
    const operator_refresh_tx = operator_refresh.transmit orelse return null;
    transmit_identifications[1] = operator_refresh_tx.identification;
    transmit_descriptors[1] = operator_refresh_tx.completion.descriptor_index;
    transmit_next_cursors[1] = operator_refresh_tx.completion.next_cursor;
    const operator_refresh_timestamp = service.request.client_timestamp;
    if (operator_refresh.state != .awaiting or operator_refresh.start_reason != .refresh or
        operator_refresh_timestamp != expected_operator_refresh or
        operator_refresh_tx.identification != 116 or operator_refresh_tx.completion.descriptor_index != 7 or
        operator_refresh_tx.completion.next_cursor != 0 or service.current_source_index != 1 or
        service.source_rotations != 2)
        return null;

    const operator_server_timestamp = ntp.fixture_server_timestamp + (@as(u64, 2) << 32);
    if (!enqueueNtpServiceResponse(
        device,
        socket,
        source_pool.servers[1],
        service.request.client_timestamp,
        operator_server_timestamp,
        0x8C01,
        0xFC01,
    )) return null;
    const operator_accepted = stepNtpServiceAutomatic(device, &service, counter, reset_tick, 0, 1) orelse return null;
    const operator_sample_tick = operator_accepted.sample_tick orelse return null;
    const operator_time = ntp.readProjectedClockAt(&service.clock, operator_sample_tick) orelse return null;
    const operator_refresh_accepted = operator_accepted.state == .idle and
        operator_accepted.quality_result == .accepted and operator_accepted.step_result == .accepted and
        operator_accepted.apply_result == .accepted and operator_time.seconds == ntp.fixture_unix_seconds + 2 and
        operator_time.fraction == 0x80000000 and service.current_source_index == 1 and
        std.meta.eql(service.client.server_ipv4, source_pool.servers[1]);
    const manual_rotation_preserved = service.source_rotations == 2 and
        service.pending_source_index == null and service.consecutive_source_failures == 0;
    if (!operator_refresh_accepted or !manual_rotation_preserved) return null;

    const automatic_refresh_tick = service.refresh_deadline_tick;
    const expected_automatic_refresh = ntp.projectedTimestampAt(&service.clock, automatic_refresh_tick) orelse return null;
    const automatic_refresh = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        automatic_refresh_tick,
        0,
        0,
    ) orelse return null;
    const automatic_refresh_tx = automatic_refresh.transmit orelse return null;
    transmit_identifications[2] = automatic_refresh_tx.identification;
    transmit_descriptors[2] = automatic_refresh_tx.completion.descriptor_index;
    transmit_next_cursors[2] = automatic_refresh_tx.completion.next_cursor;
    const automatic_refresh_timestamp = service.request.client_timestamp;
    const automatic_refresh_started = automatic_refresh.state == .awaiting and
        automatic_refresh.start_reason == .refresh and automatic_refresh_timestamp == expected_automatic_refresh and
        automatic_refresh_tx.identification == 117 and automatic_refresh_tx.completion.descriptor_index == 0 and
        automatic_refresh_tx.completion.next_cursor == 1 and service.current_source_index == 1 and
        service.source_rotations == 2;
    if (!automatic_refresh_started) return null;

    const retry = stepNtpServiceAutomatic(device, &service, counter, automatic_refresh_tick + 1, 0, 0) orelse return null;
    const retry_tx = retry.transmit orelse return null;
    transmit_identifications[3] = retry_tx.identification;
    transmit_descriptors[3] = retry_tx.completion.descriptor_index;
    transmit_next_cursors[3] = retry_tx.completion.next_cursor;
    const retry_timestamp_preserved = retry.retried and
        service.request.client_timestamp == automatic_refresh_timestamp and service.request.transmissions == 2 and
        retry_tx.identification == 118 and retry_tx.completion.descriptor_index == 1 and
        retry_tx.completion.next_cursor == 2;
    if (!retry_timestamp_preserved) return null;

    const timeout_tick = automatic_refresh_tick + 2;
    const timeout = stepNtpServiceAutomatic(device, &service, counter, timeout_tick, 0, 0) orelse return null;
    const timeout_waiting = timeout.state == .timed_out and timeout.timeout_reached and
        timeout.recovery_state == .waiting;
    const timeout_no_tx = timeout.transmit == null and !service.request_active and service.request.cancelled and
        service.retry_exhausted;
    const timeout_pending_source = service.pending_source_index orelse return null;
    const timeout_failure_count = service.consecutive_source_failures;
    if (!timeout_waiting or !timeout_no_tx or timeout_pending_source != 2 or timeout_failure_count != 1 or
        service.current_source_index != 1 or service.source_rotations != 2 or
        !std.meta.eql(service.client.server_ipv4, source_pool.servers[1]))
        return null;

    const cooldown = stepNtpServiceAutomatic(device, &service, counter, timeout_tick + 1, 0, 0) orelse return null;
    const cooldown_no_tx = cooldown.state == .timed_out and cooldown.recovery_state == .waiting and
        cooldown.transmit == null and service.current_source_index == 1 and service.pending_source_index == 2 and
        service.source_rotations == 2;
    if (!cooldown_no_tx) return null;

    const recovery_tick = timeout_tick + recovery_policy.cooldown_ticks;
    const expected_recovery_timestamp = ntp.projectedTimestampAt(&service.clock, recovery_tick) orelse return null;
    const recovery = stepNtpServiceAutomatic(device, &service, counter, recovery_tick, 0, 0) orelse return null;
    const recovery_tx = recovery.transmit orelse return null;
    transmit_identifications[4] = recovery_tx.identification;
    transmit_descriptors[4] = recovery_tx.completion.descriptor_index;
    transmit_next_cursors[4] = recovery_tx.completion.next_cursor;
    const recovery_timestamp = service.request.client_timestamp;
    const recovery_started = recovery.state == .awaiting and recovery.start_reason == .recovery and
        recovery.recovery_state == .ready and recovery.recovery_started and
        recovery_timestamp == expected_recovery_timestamp and service.automatic_recoveries == 1;
    const recovery_switched = service.current_source_index == 2 and service.pending_source_index == null and
        service.consecutive_source_failures == 0 and service.source_rotations == 3 and
        std.meta.eql(service.client.server_ipv4, source_pool.servers[2]);
    const same_socket_preserved = std.meta.eql(service.client.socket, socket);
    if (!recovery_started or !recovery_switched or !same_socket_preserved or
        recovery_tx.identification != 119 or recovery_tx.completion.descriptor_index != 2 or
        recovery_tx.completion.next_cursor != 3)
        return null;

    const fallback_server_timestamp = ntp.fixture_server_timestamp + (@as(u64, 4) << 32);
    if (!enqueueNtpServiceResponse(
        device,
        socket,
        source_pool.servers[2],
        service.request.client_timestamp,
        fallback_server_timestamp,
        0x8C02,
        0xFC02,
    )) return null;
    const accepted = stepNtpServiceAutomatic(device, &service, counter, recovery_tick, 0, 1) orelse return null;
    const accepted_quality_result = accepted.quality_result orelse return null;
    const accepted_step_result = accepted.step_result orelse return null;
    const accepted_sample_tick = accepted.sample_tick orelse return null;
    const accepted_time = ntp.readProjectedClockAt(&service.clock, accepted_sample_tick) orelse return null;
    const fallback_state_clean = accepted.state == .idle and accepted_quality_result == .accepted and
        accepted_step_result == .accepted and accepted.apply_result == .accepted and
        accepted_time.seconds == ntp.fixture_unix_seconds + 4 and accepted_time.fraction == 0x80000000 and
        service.current_source_index == 2 and std.meta.eql(service.client.server_ipv4, source_pool.servers[2]) and
        service.pending_source_index == null and service.consecutive_source_failures == 0 and
        !service.retry_exhausted and !service.recovery_exhausted and service.automatic_recoveries == 0 and
        service.source_rotations == 3 and service.recovery_successes == 1;
    if (!fallback_state_clean) return null;

    const timestamps_automatic = operator_refresh_timestamp < automatic_refresh_timestamp and
        automatic_refresh_timestamp < recovery_timestamp and recovery_timestamp == expected_recovery_timestamp;
    const health = readNtpServiceHealth(&service, accepted_sample_tick, 1, 100) orelse return null;
    const health_reports_source = health.current_source_index == 2 and health.pending_source_index == null and
        health.consecutive_source_failures == 0 and health.source_rotations == 3 and
        std.meta.eql(health.current_server_ipv4, source_pool.servers[2]);
    const health_reports_recovery = health.state == .synchronized and health.current_time != null and
        !health.awaiting_response and !health.retry_exhausted and !health.recovery_exhausted and
        health.recovery_successes == 1;
    const health_preserves_cumulative = health.requests_started == 7 and health.retries == 4 and
        health.responses == 3 and health.retry_limit_hits == 4 and health.recovery_limit_hits == 1;
    if (!timestamps_automatic or !health_reports_source or !health_reports_recovery or
        !health_preserves_cumulative)
        return null;

    const close_succeeded = closeNtpService(device, &service);
    if (!close_succeeded or service.active or service.client.active or service.request_active) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_209 or
        device.next_udp_generation != 68 or device.next_udp_identification != 120 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 3 or
        device.tx_submissions != submissions_before + 5 or txe != 147 or txd != 147 or rxe != 22 or
        overflow != 0 or device.software_rx_queue.enqueued != 128 or
        device.software_rx_queue.dequeued != 128 or device.packets_dispatched != 117 or
        device.udp_packets_dispatched != 116 or service.quality_accepted != 3 or
        service.quality_rejected != 0 or service.step_accepted != 3 or service.step_rejected != 0 or
        service.requests_started != 7 or service.retries != 4 or service.responses != 3 or
        service.retry_limit_hits != 4 or service.recovery_limit_hits != 1 or
        service.recovery_successes != 1 or service.source_rotations != 3)
        return null;

    return .{
        .source_kind = counter.reference.kind,
        .frequency_hz = counter.frequency_hz,
        .counter_bits = counter.counter_bits,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .source_count = source_pool.count,
        .operator_source_index = 1,
        .fallback_source_index = 2,
        .operator_server = source_pool.servers[1],
        .fallback_server = source_pool.servers[2],
        .transmit_identifications = transmit_identifications,
        .transmit_descriptors = transmit_descriptors,
        .transmit_next_cursors = transmit_next_cursors,
        .operator_refresh_timestamp = operator_refresh_timestamp,
        .automatic_refresh_timestamp = automatic_refresh_timestamp,
        .recovery_timestamp = recovery_timestamp,
        .timestamps_automatic = timestamps_automatic,
        .operator_refresh_accepted = operator_refresh_accepted,
        .manual_rotation_preserved = manual_rotation_preserved,
        .automatic_refresh_started = automatic_refresh_started,
        .retry_timestamp_preserved = retry_timestamp_preserved,
        .timeout_waiting = timeout_waiting,
        .timeout_no_tx = timeout_no_tx,
        .timeout_pending_source = timeout_pending_source,
        .timeout_failure_count = timeout_failure_count,
        .cooldown_no_tx = cooldown_no_tx,
        .recovery_started = recovery_started,
        .recovery_switched = recovery_switched,
        .same_socket_preserved = same_socket_preserved,
        .automatic_rotation_count = service.source_rotations,
        .accepted_quality_result = accepted_quality_result,
        .accepted_step_result = accepted_step_result,
        .accepted_sample_tick = accepted_sample_tick,
        .accepted_seconds = accepted_time.seconds,
        .accepted_fraction = accepted_time.fraction,
        .fallback_state_clean = fallback_state_clean,
        .health_reports_source = health_reports_source,
        .health_reports_recovery = health_reports_recovery,
        .health_preserves_cumulative = health_preserves_cumulative,
        .quality_accepted = service.quality_accepted,
        .quality_rejected = service.quality_rejected,
        .step_accepted = service.step_accepted,
        .step_rejected = service.step_rejected,
        .requests_started = service.requests_started,
        .retries = service.retries,
        .responses = service.responses,
        .retry_limit_hits = service.retry_limit_hits,
        .recovery_limit_hits = service.recovery_limit_hits,
        .recovery_successes = service.recovery_successes,
        .close_succeeded = close_succeeded,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .final_generation_cursor = device.next_udp_generation,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpOperatorSourceRefresh(
    device: *Device,
    counter: *time_reference.ContinuousCounter,
) ?NtpOperatorSourceRefreshReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_207 or
        device.next_udp_generation != 66 or device.tx_producer != 4 or
        device.next_udp_identification != 113 or device.next_dns_transaction_id != 8 or
        completionQueueEnqueued(&tx_completion_queue) != 140 or
        completionQueueDequeued(&tx_completion_queue) != 140 or
        completionQueueEnqueued(&rx_completion_queue) != 22 or
        device.software_rx_queue.enqueued != 123 or device.software_rx_queue.dequeued != 123 or
        device.packets_dispatched != 112 or device.udp_packets_dispatched != 111 or
        counter.frequency_hz == 0 or counter.counter_bits == 0)
    {
        return null;
    }

    var source_pool = ntp.SourcePool{
        .count = 3,
        .servers = std.mem.zeroes([ntp.maximum_source_pool_entries][4]u8),
    };
    source_pool.servers[0] = .{ 10, 0, 2, 4 };
    source_pool.servers[1] = .{ 10, 0, 2, 5 };
    source_pool.servers[2] = .{ 10, 0, 2, 6 };
    const rotation_policy = ntp.SourceRotationPolicy{
        .source_count = 3,
        .failures_before_rotation = 1,
    };
    var service = openNtpServiceWithSourcePoolPolicies(
        device,
        source_pool,
        rotation_policy,
        2,
        ntp.default_quality_policy,
        ntp.default_quality_rejection_policy,
        .{ .maximum_forward_seconds = 4, .maximum_forward_fraction = 0 },
        ntp.default_step_rejection_policy,
        .{ .initial_interval_ticks = 1, .maximum_interval_ticks = 1, .maximum_retries = 1 },
        .{ .cooldown_ticks = 2, .maximum_recoveries = 2 },
    ) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 66 or socket.local_port != 49_207 or
        device.udp_endpoint_count != 3 or device.next_ephemeral_udp_port != 49_208 or
        device.next_udp_generation != 67)
        return null;

    const submissions_before = device.tx_submissions;
    const start_tick = counter.read();
    const initial = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const initial_tx = initial.transmit orelse return null;
    if (initial.state != .awaiting or initial.start_reason != .initial or
        initial_tx.identification != 113 or initial_tx.completion.descriptor_index != 4 or
        initial_tx.completion.next_cursor != 5)
        return null;

    if (!enqueueNtpServiceResponse(
        device,
        socket,
        source_pool.servers[0],
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        0x8B00,
        0xFB00,
    )) return null;
    const first_sync = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 1) orelse return null;
    const first_sample_tick = first_sync.sample_tick orelse return null;
    if (first_sync.state != .idle or first_sync.quality_result != .accepted or
        first_sync.step_result != .accepted or first_sync.apply_result != .accepted or
        service.responses != 1 or service.refresh_deadline_tick != first_sample_tick + 2)
        return null;

    if (!switchNtpClientServer(device, &service.client, source_pool.servers[2])) return null;
    service.current_source_index = 2;
    service.pending_source_index = 0;
    service.consecutive_source_failures = 1;
    service.source_rotations = 2;
    service.request_active = false;
    service.request.cancelled = true;
    service.request_retry_attempts = 1;
    service.request_quality_rejections = 1;
    service.request_step_rejections = 1;
    service.retry_exhausted = true;
    service.requests_started = 4;
    service.retries = 3;
    service.responses = 1;
    service.retry_limit_hits = 3;
    service.last_timeout_tick = first_sample_tick + 4;
    service.recovery_deadline_tick = first_sample_tick + 6;
    service.automatic_recoveries = 2;
    service.recovery_exhausted = true;
    service.recovery_limit_hits = 1;
    service.recovery_successes = 0;

    const terminal_seeded = service.current_source_index == 2 and service.pending_source_index == 0 and
        service.consecutive_source_failures == 1 and service.source_rotations == 2 and
        service.retry_exhausted and service.recovery_exhausted and service.automatic_recoveries == 2 and
        std.meta.eql(service.client.server_ipv4, source_pool.servers[2]) and
        std.meta.eql(service.client.socket, socket);
    if (!terminal_seeded) return null;

    const reset_tick = first_sample_tick + 10;
    const clock_before_reset = service.clock;
    const time_before_reset = ntp.readProjectedClockAt(&service.clock, reset_tick) orelse return null;
    const last_timeout_before_reset = service.last_timeout_tick;
    const reset_succeeded = resetNtpServiceTimeoutToSource(device, &service, 1);
    const same_socket_preserved = std.meta.eql(service.client.socket, socket);
    const clock_preserved = std.meta.eql(service.clock, clock_before_reset) and
        std.meta.eql(ntp.readProjectedClockAt(&service.clock, reset_tick) orelse return null, time_before_reset);
    const transient_state_cleared = !service.retry_exhausted and !service.recovery_exhausted and
        service.request_retry_attempts == 0 and service.request_quality_rejections == 0 and
        service.request_step_rejections == 0 and service.recovery_deadline_tick == 0 and
        service.pending_source_index == null and service.consecutive_source_failures == 0 and
        service.automatic_recoveries == 0;
    const cumulative_state_preserved = service.requests_started == 4 and service.retries == 3 and
        service.responses == 1 and service.retry_limit_hits == 3 and service.recovery_limit_hits == 1 and
        service.recovery_successes == 0 and service.last_timeout_tick == last_timeout_before_reset and
        service.source_rotations == 2;
    if (!reset_succeeded or !same_socket_preserved or !clock_preserved or
        !transient_state_cleared or !cumulative_state_preserved or service.current_source_index != 1 or
        !std.meta.eql(service.client.server_ipv4, source_pool.servers[1]))
        return null;

    const projected_refresh_timestamp = ntp.projectedTimestampAt(&service.clock, reset_tick) orelse return null;
    const refresh = stepNtpServiceAutomatic(device, &service, counter, reset_tick, 0, 0) orelse return null;
    const refresh_tx = refresh.transmit orelse return null;
    const refresh_started = refresh.state == .awaiting and refresh.start_reason == .refresh and
        service.request.client_timestamp == projected_refresh_timestamp and service.requests_started == 5 and
        refresh_tx.identification == 114 and refresh_tx.completion.descriptor_index == 5 and
        refresh_tx.completion.next_cursor == 6;
    const refresh_target_source = service.current_source_index == 1 and
        std.meta.eql(service.client.server_ipv4, source_pool.servers[1]) and
        std.meta.eql(service.client.socket, socket) and service.source_rotations == 2;
    if (!refresh_started or !refresh_target_source) return null;

    const accepted_server_timestamp = ntp.fixture_server_timestamp + (@as(u64, 2) << 32);
    if (!enqueueNtpServiceResponse(
        device,
        socket,
        source_pool.servers[1],
        service.request.client_timestamp,
        accepted_server_timestamp,
        0x8B01,
        0xFB01,
    )) return null;
    const accepted = stepNtpServiceAutomatic(device, &service, counter, reset_tick, 0, 1) orelse return null;
    const accepted_quality_result = accepted.quality_result orelse return null;
    const accepted_step_result = accepted.step_result orelse return null;
    const accepted_sample_tick = accepted.sample_tick orelse return null;
    const accepted_time = ntp.readProjectedClockAt(&service.clock, accepted_sample_tick) orelse return null;
    const accepted_state_clean = accepted.state == .idle and accepted_quality_result == .accepted and
        accepted_step_result == .accepted and accepted.apply_result == .accepted and
        accepted_time.seconds == ntp.fixture_unix_seconds + 2 and accepted_time.fraction == 0x80000000 and
        service.current_source_index == 1 and std.meta.eql(service.client.server_ipv4, source_pool.servers[1]) and
        service.pending_source_index == null and service.consecutive_source_failures == 0 and
        !service.retry_exhausted and !service.recovery_exhausted and service.automatic_recoveries == 0 and
        service.source_rotations == 2 and service.recovery_successes == 0;
    if (!accepted_state_clean) return null;

    const health = readNtpServiceHealth(&service, accepted_sample_tick, 1, 100) orelse return null;
    const health_reports_source = health.current_source_index == 1 and health.pending_source_index == null and
        health.consecutive_source_failures == 0 and health.source_rotations == 2 and
        std.meta.eql(health.current_server_ipv4, source_pool.servers[1]);
    const health_reports_synchronized = health.state == .synchronized and health.current_time != null and
        !health.awaiting_response and !health.retry_exhausted and !health.recovery_exhausted;
    const health_preserves_cumulative = health.requests_started == 5 and health.retries == 3 and
        health.responses == 2 and health.retry_limit_hits == 3 and health.recovery_limit_hits == 1 and
        health.last_timeout_tick == last_timeout_before_reset;
    if (!health_reports_source or !health_reports_synchronized or !health_preserves_cumulative) return null;

    const close_succeeded = closeNtpService(device, &service);
    if (!close_succeeded or service.active or service.client.active or service.request_active) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_208 or
        device.next_udp_generation != 67 or device.next_udp_identification != 115 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 6 or
        device.tx_submissions != submissions_before + 2 or txe != 142 or txd != 142 or rxe != 22 or
        overflow != 0 or device.software_rx_queue.enqueued != 125 or
        device.software_rx_queue.dequeued != 125 or device.packets_dispatched != 114 or
        device.udp_packets_dispatched != 113 or service.quality_accepted != 2 or
        service.quality_rejected != 0 or service.step_accepted != 2 or service.step_rejected != 0 or
        service.requests_started != 5 or service.retries != 3 or service.responses != 2 or
        service.retry_limit_hits != 3 or service.recovery_limit_hits != 1 or service.source_rotations != 2)
        return null;

    return .{
        .source_kind = counter.reference.kind,
        .frequency_hz = counter.frequency_hz,
        .counter_bits = counter.counter_bits,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .original_source_index = 2,
        .target_source_index = 1,
        .original_server = source_pool.servers[2],
        .target_server = source_pool.servers[1],
        .initial_identification = initial_tx.identification,
        .initial_descriptor = initial_tx.completion.descriptor_index,
        .initial_next_cursor = initial_tx.completion.next_cursor,
        .terminal_seeded = terminal_seeded,
        .reset_succeeded = reset_succeeded,
        .same_socket_preserved = same_socket_preserved,
        .clock_preserved = clock_preserved,
        .transient_state_cleared = transient_state_cleared,
        .cumulative_state_preserved = cumulative_state_preserved,
        .projected_refresh_timestamp = projected_refresh_timestamp,
        .refresh_identification = refresh_tx.identification,
        .refresh_descriptor = refresh_tx.completion.descriptor_index,
        .refresh_next_cursor = refresh_tx.completion.next_cursor,
        .refresh_started = refresh_started,
        .refresh_target_source = refresh_target_source,
        .accepted_quality_result = accepted_quality_result,
        .accepted_step_result = accepted_step_result,
        .accepted_sample_tick = accepted_sample_tick,
        .accepted_seconds = accepted_time.seconds,
        .accepted_fraction = accepted_time.fraction,
        .accepted_state_clean = accepted_state_clean,
        .health_reports_source = health_reports_source,
        .health_reports_synchronized = health_reports_synchronized,
        .health_preserves_cumulative = health_preserves_cumulative,
        .quality_accepted = service.quality_accepted,
        .quality_rejected = service.quality_rejected,
        .step_accepted = service.step_accepted,
        .step_rejected = service.step_rejected,
        .requests_started = service.requests_started,
        .retries = service.retries,
        .responses = service.responses,
        .retry_limit_hits = service.retry_limit_hits,
        .recovery_limit_hits = service.recovery_limit_hits,
        .source_rotations = service.source_rotations,
        .close_succeeded = close_succeeded,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .final_generation_cursor = device.next_udp_generation,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpOperatorSourceReset(device: *Device) ?NtpOperatorSourceResetReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_206 or
        device.next_udp_generation != 65 or device.tx_producer != 4 or
        device.next_udp_identification != 113 or device.next_dns_transaction_id != 8 or
        completionQueueEnqueued(&tx_completion_queue) != 140 or
        completionQueueDequeued(&tx_completion_queue) != 140 or
        completionQueueEnqueued(&rx_completion_queue) != 22 or
        device.software_rx_queue.enqueued != 123 or device.software_rx_queue.dequeued != 123 or
        device.packets_dispatched != 112 or device.udp_packets_dispatched != 111)
    {
        return null;
    }

    var source_pool = ntp.SourcePool{
        .count = 3,
        .servers = std.mem.zeroes([ntp.maximum_source_pool_entries][4]u8),
    };
    source_pool.servers[0] = .{ 10, 0, 2, 4 };
    source_pool.servers[1] = .{ 10, 0, 2, 5 };
    source_pool.servers[2] = .{ 10, 0, 2, 6 };
    const rotation_policy = ntp.SourceRotationPolicy{
        .source_count = 3,
        .failures_before_rotation = 1,
    };
    var service = openNtpServiceWithSourcePoolPolicies(
        device,
        source_pool,
        rotation_policy,
        2,
        ntp.default_quality_policy,
        ntp.default_quality_rejection_policy,
        .{ .maximum_forward_seconds = 4, .maximum_forward_fraction = 0 },
        ntp.default_step_rejection_policy,
        .{ .initial_interval_ticks = 1, .maximum_interval_ticks = 1, .maximum_retries = 1 },
        .{ .cooldown_ticks = 2, .maximum_recoveries = 2 },
    ) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 65 or socket.local_port != 49_206 or
        device.udp_endpoint_count != 3 or device.next_ephemeral_udp_port != 49_207 or
        device.next_udp_generation != 66)
        return null;

    if (!switchNtpClientServer(device, &service.client, source_pool.servers[2])) return null;
    service.current_source_index = 2;
    service.pending_source_index = 0;
    service.consecutive_source_failures = 1;
    service.source_rotations = 2;
    service.request_active = false;
    service.request_retry_attempts = 1;
    service.request_quality_rejections = 1;
    service.request_step_rejections = 1;
    service.retry_exhausted = true;
    service.requests_started = 4;
    service.retries = 3;
    service.responses = 1;
    service.retry_limit_hits = 3;
    service.last_timeout_tick = 777;
    service.recovery_deadline_tick = 779;
    service.automatic_recoveries = 2;
    service.recovery_exhausted = true;
    service.recovery_limit_hits = 1;
    service.recovery_successes = 0;

    const terminal_seeded = service.current_source_index == 2 and service.pending_source_index == 0 and
        service.consecutive_source_failures == 1 and service.source_rotations == 2 and
        service.retry_exhausted and service.recovery_exhausted and service.automatic_recoveries == 2 and
        service.retry_limit_hits == 3 and service.recovery_limit_hits == 1 and
        std.meta.eql(service.client.server_ipv4, source_pool.servers[2]) and
        std.meta.eql(service.client.socket, socket);
    if (!terminal_seeded) return null;

    const state_before_invalid = service;
    const peer_before_invalid = udpSocketPeer(device, socket) orelse return null;
    const invalid_source_rejected = !resetNtpServiceTimeoutToSource(device, &service, 3);
    const peer_after_invalid = udpSocketPeer(device, socket) orelse return null;
    const invalid_state_preserved = std.meta.eql(service, state_before_invalid) and
        std.meta.eql(peer_after_invalid, peer_before_invalid);
    if (!invalid_source_rejected or !invalid_state_preserved) return null;

    const reset_succeeded = resetNtpServiceTimeoutToSource(device, &service, 1);
    const peer_after_reset = udpSocketPeer(device, socket) orelse return null;
    const same_socket_preserved = std.meta.eql(service.client.socket, socket);
    const target_source_selected = service.current_source_index == 1 and
        std.meta.eql(service.client.server_ipv4, source_pool.servers[1]) and
        std.meta.eql(peer_after_reset.ipv4, source_pool.servers[1]) and
        std.meta.eql(peer_after_reset.mac, device.gateway_mac) and peer_after_reset.port == ntp.server_port;
    const transient_state_cleared = !service.retry_exhausted and !service.recovery_exhausted and
        service.request_retry_attempts == 0 and service.request_quality_rejections == 0 and
        service.request_step_rejections == 0 and service.recovery_deadline_tick == 0 and
        service.pending_source_index == null and service.consecutive_source_failures == 0 and
        service.automatic_recoveries == 0;
    const cumulative_state_preserved = service.requests_started == 4 and service.retries == 3 and
        service.responses == 1 and service.retry_limit_hits == 3 and service.recovery_limit_hits == 1 and
        service.recovery_successes == 0 and service.last_timeout_tick == 777;
    const rotations_preserved = service.source_rotations == 2;
    const duplicate_reset_rejected = !resetNtpServiceTimeoutToSource(device, &service, 0);
    if (!reset_succeeded or !same_socket_preserved or !target_source_selected or
        !transient_state_cleared or !cumulative_state_preserved or !rotations_preserved or
        !duplicate_reset_rejected)
        return null;

    const no_packet_traffic = device.next_udp_identification == 113 and device.tx_producer == 4 and
        completionQueueEnqueued(&tx_completion_queue) == 140 and
        completionQueueDequeued(&tx_completion_queue) == 140 and
        completionQueueEnqueued(&rx_completion_queue) == 22 and
        device.software_rx_queue.enqueued == 123 and device.software_rx_queue.dequeued == 123 and
        device.packets_dispatched == 112 and device.udp_packets_dispatched == 111;
    if (!no_packet_traffic) return null;

    const close_succeeded = closeNtpService(device, &service);
    if (!close_succeeded or service.active or service.client.active or service.request_active) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_207 or
        device.next_udp_generation != 66 or device.next_udp_identification != 113 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 4 or txe != 140 or txd != 140 or rxe != 22 or
        device.software_rx_queue.enqueued != 123 or device.software_rx_queue.dequeued != 123 or
        device.packets_dispatched != 112 or device.udp_packets_dispatched != 111)
        return null;

    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .source_count = source_pool.count,
        .original_source_index = 2,
        .target_source_index = 1,
        .original_server = source_pool.servers[2],
        .target_server = source_pool.servers[1],
        .terminal_seeded = terminal_seeded,
        .invalid_source_rejected = invalid_source_rejected,
        .invalid_state_preserved = invalid_state_preserved,
        .reset_succeeded = reset_succeeded,
        .same_socket_preserved = same_socket_preserved,
        .target_source_selected = target_source_selected,
        .transient_state_cleared = transient_state_cleared,
        .cumulative_state_preserved = cumulative_state_preserved,
        .rotations_preserved = rotations_preserved,
        .duplicate_reset_rejected = duplicate_reset_rejected,
        .no_packet_traffic = no_packet_traffic,
        .close_succeeded = close_succeeded,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .final_generation_cursor = device.next_udp_generation,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpSourceExhaustionReset(
    device: *Device,
    counter: *time_reference.ContinuousCounter,
) ?NtpSourceExhaustionResetReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_205 or
        device.next_udp_generation != 64 or device.tx_producer != 2 or
        device.next_udp_identification != 111 or device.next_dns_transaction_id != 8 or
        completionQueueEnqueued(&tx_completion_queue) != 138 or
        completionQueueDequeued(&tx_completion_queue) != 138 or
        completionQueueEnqueued(&rx_completion_queue) != 22 or
        device.software_rx_queue.enqueued != 121 or device.software_rx_queue.dequeued != 121 or
        device.packets_dispatched != 110 or device.udp_packets_dispatched != 109 or
        counter.frequency_hz == 0 or counter.counter_bits == 0)
    {
        return null;
    }

    var source_pool = ntp.SourcePool{
        .count = 3,
        .servers = std.mem.zeroes([ntp.maximum_source_pool_entries][4]u8),
    };
    source_pool.servers[0] = .{ 10, 0, 2, 4 };
    source_pool.servers[1] = .{ 10, 0, 2, 5 };
    source_pool.servers[2] = .{ 10, 0, 2, 6 };
    const rotation_policy = ntp.SourceRotationPolicy{
        .source_count = 3,
        .failures_before_rotation = 1,
    };
    const retry_policy = ntp.RetryPolicy{
        .initial_interval_ticks = 1,
        .maximum_interval_ticks = 1,
        .maximum_retries = 1,
    };
    const recovery_policy = ntp.RecoveryPolicy{
        .cooldown_ticks = 2,
        .maximum_recoveries = 2,
    };
    var service = openNtpServiceWithSourcePoolPolicies(
        device,
        source_pool,
        rotation_policy,
        2,
        ntp.default_quality_policy,
        ntp.default_quality_rejection_policy,
        .{ .maximum_forward_seconds = 4, .maximum_forward_fraction = 0 },
        ntp.default_step_rejection_policy,
        retry_policy,
        recovery_policy,
    ) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 64 or socket.local_port != 49_205 or
        device.udp_endpoint_count != 3 or device.next_ephemeral_udp_port != 49_206 or
        device.next_udp_generation != 65 or service.current_source_index != 0 or
        !std.meta.eql(service.client.server_ipv4, source_pool.servers[0]))
        return null;

    const submissions_before = device.tx_submissions;
    const start_tick = counter.read();
    const initial = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const initial_tx = initial.transmit orelse return null;
    if (initial.state != .awaiting or initial.start_reason != .initial or
        initial_tx.identification != 111 or initial_tx.completion.descriptor_index != 2 or
        initial_tx.completion.next_cursor != 3)
        return null;

    if (!enqueueNtpServiceResponse(
        device,
        socket,
        source_pool.servers[0],
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        0x8A00,
        0xFA00,
    )) return null;
    const first_sync = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 1) orelse return null;
    const first_sample_tick = first_sync.sample_tick orelse return null;
    if (first_sync.state != .idle or first_sync.quality_result != .accepted or
        first_sync.step_result != .accepted or first_sync.apply_result != .accepted or
        service.responses != 1 or service.refresh_deadline_tick != first_sample_tick + 2)
        return null;

    const switch_to_current_source_succeeded = switchNtpClientServer(device, &service.client, source_pool.servers[2]);
    if (!switch_to_current_source_succeeded or !std.meta.eql(service.client.socket, socket) or
        !std.meta.eql(service.client.server_ipv4, source_pool.servers[2]))
        return null;

    service.current_source_index = 2;
    service.pending_source_index = 0;
    service.consecutive_source_failures = 1;
    service.source_rotations = 2;
    service.request_active = false;
    service.request.cancelled = true;
    service.request.transmissions = 2;
    service.request_retry_attempts = 1;
    service.request_quality_rejections = 1;
    service.request_step_rejections = 1;
    service.retry_exhausted = true;
    service.requests_started = 4;
    service.retries = 3;
    service.retry_limit_hits = 3;
    service.last_timeout_tick = first_sample_tick + 4;
    service.recovery_deadline_tick = first_sample_tick + 6;
    service.automatic_recoveries = 2;
    service.recovery_exhausted = true;
    service.recovery_limit_hits = 1;
    service.recovery_successes = 0;

    const terminal_seeded = service.retry_exhausted and service.recovery_exhausted and
        service.automatic_recoveries == 2 and service.pending_source_index == 0 and
        service.consecutive_source_failures == 1 and service.current_source_index == 2 and
        service.source_rotations == 2 and service.retry_limit_hits == 3 and
        service.recovery_limit_hits == 1 and std.meta.eql(service.client.socket, socket) and
        std.meta.eql(service.client.server_ipv4, source_pool.servers[2]);
    if (!terminal_seeded) return null;

    const clear_tick = first_sample_tick + 10;
    const clock_before_clear = service.clock;
    const time_before_clear = ntp.readProjectedClockAt(&service.clock, clear_tick) orelse return null;
    const last_timeout_before_clear = service.last_timeout_tick;
    const refresh_deadline_before_clear = service.refresh_deadline_tick;
    const clear_succeeded = clearNtpServiceTimeout(&service);
    const duplicate_clear_rejected = !clearNtpServiceTimeout(&service);
    const transient_state_cleared = clear_succeeded and duplicate_clear_rejected and
        !service.retry_exhausted and !service.recovery_exhausted and
        service.request_retry_attempts == 0 and service.request_quality_rejections == 0 and
        service.request_step_rejections == 0 and service.recovery_deadline_tick == 0 and
        service.automatic_recoveries == 0 and service.pending_source_index == null and
        service.consecutive_source_failures == 0;
    const cumulative_state_preserved = service.requests_started == 4 and service.retries == 3 and
        service.responses == 1 and service.retry_limit_hits == 3 and
        service.recovery_limit_hits == 1 and service.recovery_successes == 0 and
        service.last_timeout_tick == last_timeout_before_clear and
        service.refresh_deadline_tick == refresh_deadline_before_clear;
    const source_state_preserved = service.current_source_index == 2 and service.source_rotations == 2 and
        std.meta.eql(service.client.server_ipv4, source_pool.servers[2]);
    const socket_preserved = std.meta.eql(service.client.socket, socket);
    const clock_preserved = std.meta.eql(service.clock, clock_before_clear) and
        std.meta.eql(ntp.readProjectedClockAt(&service.clock, clear_tick) orelse return null, time_before_clear);
    if (!transient_state_cleared or !cumulative_state_preserved or !source_state_preserved or
        !socket_preserved or !clock_preserved)
        return null;

    const projected_refresh_timestamp = ntp.projectedTimestampAt(&service.clock, clear_tick) orelse return null;
    const refresh = stepNtpServiceAutomatic(device, &service, counter, clear_tick, 0, 0) orelse return null;
    const refresh_tx = refresh.transmit orelse return null;
    const refresh_started = refresh.state == .awaiting and refresh.start_reason == .refresh and
        service.request.client_timestamp == projected_refresh_timestamp and service.requests_started == 5 and
        refresh_tx.identification == 112 and refresh_tx.completion.descriptor_index == 3 and
        refresh_tx.completion.next_cursor == 4;
    const refresh_source_preserved = service.current_source_index == 2 and
        service.pending_source_index == null and service.consecutive_source_failures == 0 and
        service.source_rotations == 2 and std.meta.eql(service.client.server_ipv4, source_pool.servers[2]) and
        std.meta.eql(service.client.socket, socket);
    if (!refresh_started or !refresh_source_preserved) return null;

    const recovered_server_timestamp = ntp.fixture_server_timestamp + (@as(u64, 2) << 32);
    if (!enqueueNtpServiceResponse(
        device,
        socket,
        source_pool.servers[2],
        service.request.client_timestamp,
        recovered_server_timestamp,
        0x8A01,
        0xFA01,
    )) return null;
    const accepted = stepNtpServiceAutomatic(device, &service, counter, clear_tick, 0, 1) orelse return null;
    const accepted_quality_result = accepted.quality_result orelse return null;
    const accepted_step_result = accepted.step_result orelse return null;
    const accepted_sample_tick = accepted.sample_tick orelse return null;
    const accepted_time = ntp.readProjectedClockAt(&service.clock, accepted_sample_tick) orelse return null;
    const accepted_reset_state = accepted.state == .idle and accepted_quality_result == .accepted and
        accepted_step_result == .accepted and accepted.apply_result == .accepted and
        accepted_time.seconds == ntp.fixture_unix_seconds + 2 and accepted_time.fraction == 0x80000000 and
        !service.retry_exhausted and !service.recovery_exhausted and service.automatic_recoveries == 0 and
        service.pending_source_index == null and service.consecutive_source_failures == 0 and
        service.current_source_index == 2 and service.source_rotations == 2 and
        service.recovery_successes == 0 and std.meta.eql(service.client.server_ipv4, source_pool.servers[2]);
    if (!accepted_reset_state) return null;

    const health = readNtpServiceHealth(&service, accepted_sample_tick, 1, 100) orelse return null;
    const health_reports_source = health.current_source_index == 2 and health.pending_source_index == null and
        health.consecutive_source_failures == 0 and health.source_rotations == 2 and
        std.meta.eql(health.current_server_ipv4, source_pool.servers[2]);
    const health_reports_synchronized = health.state == .synchronized and health.current_time != null and
        !health.awaiting_response and !health.retry_exhausted and !health.recovery_exhausted;
    const health_preserves_cumulative = health.retry_limit_hits == 3 and health.recovery_limit_hits == 1 and
        health.requests_started == 5 and health.retries == 3 and health.responses == 2 and
        health.last_timeout_tick == last_timeout_before_clear;
    if (!health_reports_source or !health_reports_synchronized or !health_preserves_cumulative) return null;

    const close_succeeded = closeNtpService(device, &service);
    if (!close_succeeded or service.active or service.client.active or service.request_active) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_206 or
        device.next_udp_generation != 65 or device.next_udp_identification != 113 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 4 or
        device.tx_submissions != submissions_before + 2 or txe != 140 or txd != 140 or rxe != 22 or
        overflow != 0 or device.software_rx_queue.enqueued != 123 or
        device.software_rx_queue.dequeued != 123 or device.packets_dispatched != 112 or
        device.udp_packets_dispatched != 111 or service.quality_accepted != 2 or
        service.quality_rejected != 0 or service.step_accepted != 2 or service.step_rejected != 0 or
        service.requests_started != 5 or service.retries != 3 or service.responses != 2 or
        service.retry_limit_hits != 3 or service.recovery_limit_hits != 1 or
        service.source_rotations != 2)
        return null;

    return .{
        .source_kind = counter.reference.kind,
        .frequency_hz = counter.frequency_hz,
        .counter_bits = counter.counter_bits,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .source_count = source_pool.count,
        .current_source_index = 2,
        .current_server = source_pool.servers[2],
        .initial_identification = initial_tx.identification,
        .initial_descriptor = initial_tx.completion.descriptor_index,
        .initial_next_cursor = initial_tx.completion.next_cursor,
        .terminal_seeded = terminal_seeded,
        .switch_to_current_source_succeeded = switch_to_current_source_succeeded,
        .clear_succeeded = clear_succeeded,
        .duplicate_clear_rejected = duplicate_clear_rejected,
        .transient_state_cleared = transient_state_cleared,
        .cumulative_state_preserved = cumulative_state_preserved,
        .source_state_preserved = source_state_preserved,
        .socket_preserved = socket_preserved,
        .clock_preserved = clock_preserved,
        .projected_refresh_timestamp = projected_refresh_timestamp,
        .refresh_identification = refresh_tx.identification,
        .refresh_descriptor = refresh_tx.completion.descriptor_index,
        .refresh_next_cursor = refresh_tx.completion.next_cursor,
        .refresh_started = refresh_started,
        .refresh_source_preserved = refresh_source_preserved,
        .accepted_quality_result = accepted_quality_result,
        .accepted_step_result = accepted_step_result,
        .accepted_sample_tick = accepted_sample_tick,
        .accepted_seconds = accepted_time.seconds,
        .accepted_fraction = accepted_time.fraction,
        .accepted_reset_state = accepted_reset_state,
        .health_reports_source = health_reports_source,
        .health_reports_synchronized = health_reports_synchronized,
        .health_preserves_cumulative = health_preserves_cumulative,
        .quality_accepted = service.quality_accepted,
        .quality_rejected = service.quality_rejected,
        .step_accepted = service.step_accepted,
        .step_rejected = service.step_rejected,
        .requests_started = service.requests_started,
        .retries = service.retries,
        .responses = service.responses,
        .retry_limit_hits = service.retry_limit_hits,
        .recovery_limit_hits = service.recovery_limit_hits,
        .source_rotations = service.source_rotations,
        .close_succeeded = close_succeeded,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .final_generation_cursor = device.next_udp_generation,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpSourceExhaustion(
    device: *Device,
    counter: *time_reference.ContinuousCounter,
) ?NtpSourceExhaustionReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_204 or
        device.next_udp_generation != 63 or device.tx_producer != 3 or
        device.next_udp_identification != 104 or device.next_dns_transaction_id != 8 or
        completionQueueEnqueued(&tx_completion_queue) != 131 or
        completionQueueDequeued(&tx_completion_queue) != 131 or
        completionQueueEnqueued(&rx_completion_queue) != 22 or
        device.software_rx_queue.enqueued != 120 or device.software_rx_queue.dequeued != 120 or
        device.packets_dispatched != 109 or device.udp_packets_dispatched != 108 or
        counter.frequency_hz == 0 or counter.counter_bits == 0)
    {
        return null;
    }

    var source_pool = ntp.SourcePool{
        .count = 3,
        .servers = std.mem.zeroes([ntp.maximum_source_pool_entries][4]u8),
    };
    source_pool.servers[0] = .{ 10, 0, 2, 4 };
    source_pool.servers[1] = .{ 10, 0, 2, 5 };
    source_pool.servers[2] = .{ 10, 0, 2, 6 };
    const rotation_policy = ntp.SourceRotationPolicy{
        .source_count = 3,
        .failures_before_rotation = 1,
    };
    const retry_policy = ntp.RetryPolicy{
        .initial_interval_ticks = 1,
        .maximum_interval_ticks = 1,
        .maximum_retries = 1,
    };
    const recovery_policy = ntp.RecoveryPolicy{
        .cooldown_ticks = 2,
        .maximum_recoveries = 2,
    };
    var service = openNtpServiceWithSourcePoolPolicies(
        device,
        source_pool,
        rotation_policy,
        2,
        ntp.default_quality_policy,
        ntp.default_quality_rejection_policy,
        .{ .maximum_forward_seconds = 4, .maximum_forward_fraction = 0 },
        ntp.default_step_rejection_policy,
        retry_policy,
        recovery_policy,
    ) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 63 or socket.local_port != 49_204 or
        device.udp_endpoint_count != 3 or device.next_ephemeral_udp_port != 49_205 or
        device.next_udp_generation != 64 or service.current_source_index != 0 or
        service.pending_source_index != null or service.consecutive_source_failures != 0 or
        service.source_rotations != 0 or !std.meta.eql(service.client.server_ipv4, source_pool.servers[0]))
        return null;

    const submissions_before = device.tx_submissions;
    const start_tick = counter.read();
    var transmit_identifications = [7]u16{ 0, 0, 0, 0, 0, 0, 0 };
    var transmit_descriptors = [7]u16{ 0, 0, 0, 0, 0, 0, 0 };
    var transmit_next_cursors = [7]u16{ 0, 0, 0, 0, 0, 0, 0 };
    var timeout_current_sources = [3]u8{ 0, 0, 0 };
    var timeout_pending_sources = [3]u8{ 0, 0, 0 };
    var timeout_failure_counts = [3]u8{ 0, 0, 0 };
    var cooldowns_no_tx = [2]bool{ false, false };
    var recovery_source_indices = [2]u8{ 0, 0 };
    var recovery_switches_succeeded = [2]bool{ false, false };
    var recovery_client_timestamps = [2]u64{ 0, 0 };

    const initial = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const initial_tx = initial.transmit orelse return null;
    transmit_identifications[0] = initial_tx.identification;
    transmit_descriptors[0] = initial_tx.completion.descriptor_index;
    transmit_next_cursors[0] = initial_tx.completion.next_cursor;
    if (initial.state != .awaiting or initial.start_reason != .initial) return null;

    if (!enqueueNtpServiceResponse(
        device,
        socket,
        source_pool.servers[0],
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        0x8800,
        0xF800,
    )) return null;
    const first_sync = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 1) orelse return null;
    const first_sample_tick = first_sync.sample_tick orelse return null;
    if (first_sync.state != .idle or first_sync.quality_result != .accepted or
        first_sync.step_result != .accepted or first_sync.apply_result != .accepted or
        service.responses != 1 or service.refresh_deadline_tick != first_sample_tick + 2)
        return null;

    const refresh_tick = service.refresh_deadline_tick;
    const expected_refresh_timestamp = ntp.projectedTimestampAt(&service.clock, refresh_tick) orelse return null;
    const refresh = stepNtpServiceAutomatic(device, &service, counter, refresh_tick, 0, 0) orelse return null;
    const refresh_tx = refresh.transmit orelse return null;
    transmit_identifications[1] = refresh_tx.identification;
    transmit_descriptors[1] = refresh_tx.completion.descriptor_index;
    transmit_next_cursors[1] = refresh_tx.completion.next_cursor;
    const refresh_client_timestamp = service.request.client_timestamp;
    if (refresh.state != .awaiting or refresh.start_reason != .refresh or
        refresh_client_timestamp != expected_refresh_timestamp)
        return null;

    var request_start_tick = refresh_tick;
    var terminal_timeout_tick: u64 = 0;
    var terminal_state: NtpServiceState = .inactive;
    var terminal_recovery_state: ntp.RecoveryState = .invalid_policy;
    var terminal_timeout_reached = false;
    var terminal_no_tx = false;
    var terminal_request_cancelled = false;
    var terminal_retry_exhausted = false;
    var terminal_recovery_exhausted = false;
    var terminal_recovery_limit_hits: u64 = 0;
    var terminal_recovery_deadline_delta: u64 = 0;
    var terminal_source_preserved = false;
    var terminal_pending_wrap: u8 = 0;
    var terminal_failure_count: u8 = 0;

    var cycle: usize = 0;
    while (cycle < 3) : (cycle += 1) {
        const retry = stepNtpServiceAutomatic(device, &service, counter, request_start_tick + 1, 0, 0) orelse return null;
        const retry_tx = retry.transmit orelse return null;
        const retry_index: usize = 2 + cycle * 2;
        transmit_identifications[retry_index] = retry_tx.identification;
        transmit_descriptors[retry_index] = retry_tx.completion.descriptor_index;
        transmit_next_cursors[retry_index] = retry_tx.completion.next_cursor;
        if (!retry.retried or retry.timeout_reached or service.request.transmissions != 2) return null;

        const timeout_tick = request_start_tick + 2;
        const timeout = stepNtpServiceAutomatic(device, &service, counter, timeout_tick, 0, 0) orelse return null;
        const expected_current: u8 = @intCast(cycle);
        const expected_pending: u8 = @intCast((cycle + 1) % 3);
        timeout_current_sources[cycle] = service.current_source_index;
        timeout_pending_sources[cycle] = service.pending_source_index orelse return null;
        timeout_failure_counts[cycle] = service.consecutive_source_failures;
        if (timeout.state != .timed_out or !timeout.timeout_reached or timeout.transmit != null or
            timeout_current_sources[cycle] != expected_current or
            timeout_pending_sources[cycle] != expected_pending or timeout_failure_counts[cycle] != 1 or
            !std.meta.eql(service.client.server_ipv4, source_pool.servers[expected_current]) or
            !service.request.cancelled or service.request_active or !service.retry_exhausted)
            return null;

        if (cycle < 2) {
            if (timeout.recovery_state != .waiting or service.recovery_exhausted or
                service.automatic_recoveries != @as(u8, @intCast(cycle)))
                return null;
            const cooldown = stepNtpServiceAutomatic(device, &service, counter, timeout_tick + 1, 0, 0) orelse return null;
            cooldowns_no_tx[cycle] = cooldown.state == .timed_out and
                cooldown.recovery_state == .waiting and cooldown.transmit == null and
                service.current_source_index == expected_current and
                service.pending_source_index == expected_pending and
                service.source_rotations == @as(u64, @intCast(cycle));
            if (!cooldowns_no_tx[cycle]) return null;

            const recovery_tick = timeout_tick + recovery_policy.cooldown_ticks;
            const expected_recovery_timestamp = ntp.projectedTimestampAt(&service.clock, recovery_tick) orelse return null;
            const recovery = stepNtpServiceAutomatic(device, &service, counter, recovery_tick, 0, 0) orelse return null;
            const recovery_tx = recovery.transmit orelse return null;
            const recovery_index: usize = 3 + cycle * 2;
            transmit_identifications[recovery_index] = recovery_tx.identification;
            transmit_descriptors[recovery_index] = recovery_tx.completion.descriptor_index;
            transmit_next_cursors[recovery_index] = recovery_tx.completion.next_cursor;
            recovery_client_timestamps[cycle] = service.request.client_timestamp;
            recovery_source_indices[cycle] = service.current_source_index;
            recovery_switches_succeeded[cycle] =
                recovery.state == .awaiting and recovery.start_reason == .recovery and
                recovery.recovery_state == .ready and recovery.recovery_started and
                recovery_client_timestamps[cycle] == expected_recovery_timestamp and
                recovery_source_indices[cycle] == expected_pending and
                service.pending_source_index == null and service.consecutive_source_failures == 0 and
                service.source_rotations == @as(u64, @intCast(cycle + 1)) and
                service.automatic_recoveries == @as(u8, @intCast(cycle + 1)) and
                std.meta.eql(service.client.server_ipv4, source_pool.servers[expected_pending]) and
                std.meta.eql(service.client.socket, socket);
            if (!recovery_switches_succeeded[cycle]) return null;
            request_start_tick = recovery_tick;
        } else {
            terminal_timeout_tick = timeout_tick;
            terminal_state = timeout.state;
            terminal_recovery_state = timeout.recovery_state orelse return null;
            terminal_timeout_reached = timeout.timeout_reached;
            terminal_no_tx = timeout.transmit == null;
            terminal_request_cancelled = service.request.cancelled and !service.request_active;
            terminal_retry_exhausted = service.retry_exhausted;
            terminal_recovery_exhausted = service.recovery_exhausted;
            terminal_recovery_limit_hits = service.recovery_limit_hits;
            terminal_recovery_deadline_delta = service.recovery_deadline_tick - timeout_tick;
            terminal_source_preserved = service.current_source_index == 2 and
                std.meta.eql(service.client.server_ipv4, source_pool.servers[2]) and
                std.meta.eql(service.client.socket, socket) and service.source_rotations == 2;
            terminal_pending_wrap = service.pending_source_index orelse return null;
            terminal_failure_count = service.consecutive_source_failures;
            if (terminal_recovery_state != .exhausted or !terminal_recovery_exhausted or
                terminal_recovery_limit_hits != 1 or terminal_recovery_deadline_delta != 2 or
                !terminal_source_preserved or terminal_pending_wrap != 0 or terminal_failure_count != 1 or
                service.automatic_recoveries != 2)
                return null;
        }
    }

    const expected_ids = [7]u16{ 104, 105, 106, 107, 108, 109, 110 };
    const expected_descriptors = [7]u16{ 3, 4, 5, 6, 7, 0, 1 };
    const expected_cursors = [7]u16{ 4, 5, 6, 7, 0, 1, 2 };
    if (!std.meta.eql(transmit_identifications, expected_ids) or
        !std.meta.eql(transmit_descriptors, expected_descriptors) or
        !std.meta.eql(transmit_next_cursors, expected_cursors))
        return null;

    const timestamps_automatic = refresh_client_timestamp < recovery_client_timestamps[0] and
        recovery_client_timestamps[0] < recovery_client_timestamps[1];
    const first_two_waiting = timeout_current_sources[0] == 0 and timeout_pending_sources[0] == 1 and
        timeout_current_sources[1] == 1 and timeout_pending_sources[1] == 2;
    if (!timestamps_automatic or !first_two_waiting or
        !std.meta.eql(recovery_source_indices, [2]u8{ 1, 2 }) or
        !std.meta.eql(recovery_switches_succeeded, [2]bool{ true, true }) or
        !std.meta.eql(cooldowns_no_tx, [2]bool{ true, true }))
        return null;

    const terminal_health = readNtpServiceHealth(&service, terminal_timeout_tick, 1, 100) orelse return null;
    const terminal_time = terminal_health.current_time orelse return null;
    const submissions_before_repeat = device.tx_submissions;
    const identification_before_repeat = device.next_udp_identification;
    const tx_cursor_before_repeat = device.tx_producer;
    const repeated = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        terminal_timeout_tick + 1,
        0,
        0,
    ) orelse return null;
    const later_health = readNtpServiceHealth(&service, terminal_timeout_tick + 1, 1, 100) orelse return null;
    const later_time = later_health.current_time orelse return null;
    const repeated_exhausted_no_tx = repeated.state == .timed_out and
        repeated.recovery_state == .exhausted and repeated.transmit == null and
        device.tx_submissions == submissions_before_repeat and
        device.next_udp_identification == identification_before_repeat and
        device.tx_producer == tx_cursor_before_repeat;
    const repeated_latch_preserved = service.recovery_exhausted and service.recovery_limit_hits == 1 and
        service.retry_exhausted and service.automatic_recoveries == 2 and
        service.current_source_index == 2 and service.pending_source_index == 0 and
        service.consecutive_source_failures == 1 and service.source_rotations == 2 and
        std.meta.eql(service.client.server_ipv4, source_pool.servers[2]);
    const holdover_visible = terminal_health.state == .holdover and terminal_health.current_time != null and
        later_health.state == .holdover and later_health.current_time != null;
    const holdover_advanced = later_time.seconds > terminal_time.seconds or
        (later_time.seconds == terminal_time.seconds and later_time.fraction > terminal_time.fraction);
    const health_reports_source = terminal_health.current_source_index == 2 and
        terminal_health.pending_source_index == 0 and
        std.meta.eql(terminal_health.current_server_ipv4, source_pool.servers[2]) and
        terminal_health.consecutive_source_failures == 1 and terminal_health.source_rotations == 2;
    const health_reports_exhaustion = terminal_health.retry_exhausted and
        terminal_health.recovery_exhausted and terminal_health.recovery_limit_hits == 1 and
        terminal_health.automatic_recoveries == 2;
    const health_reports_holdover = terminal_health.state == .holdover and
        terminal_health.current_time != null and terminal_health.sample_age_ticks > 0;
    if (!repeated_exhausted_no_tx or !repeated_latch_preserved or !holdover_visible or
        !holdover_advanced or !health_reports_source or !health_reports_exhaustion or
        !health_reports_holdover)
        return null;

    const same_socket_preserved = std.meta.eql(service.client.socket, socket);
    const close_succeeded = closeNtpService(device, &service);
    if (!close_succeeded or service.active or service.client.active or service.request_active) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_205 or
        device.next_udp_generation != 64 or device.next_udp_identification != 111 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 2 or
        device.tx_submissions != submissions_before + 7 or txe != 138 or txd != 138 or rxe != 22 or
        overflow != 0 or device.software_rx_queue.enqueued != 121 or
        device.software_rx_queue.dequeued != 121 or device.packets_dispatched != 110 or
        device.udp_packets_dispatched != 109 or service.quality_accepted != 1 or
        service.quality_rejected != 0 or service.step_accepted != 1 or service.step_rejected != 0 or
        service.requests_started != 4 or service.retries != 3 or service.responses != 1 or
        service.retry_limit_hits != 3 or service.recovery_successes != 0 or
        service.source_rotations != 2 or service.recovery_limit_hits != 1)
        return null;

    return .{
        .source_kind = counter.reference.kind,
        .frequency_hz = counter.frequency_hz,
        .counter_bits = counter.counter_bits,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .source_count = source_pool.count,
        .failures_before_rotation = rotation_policy.failures_before_rotation,
        .maximum_recoveries = recovery_policy.maximum_recoveries,
        .servers = .{ source_pool.servers[0], source_pool.servers[1], source_pool.servers[2] },
        .transmit_identifications = transmit_identifications,
        .transmit_descriptors = transmit_descriptors,
        .transmit_next_cursors = transmit_next_cursors,
        .refresh_client_timestamp = refresh_client_timestamp,
        .recovery_client_timestamps = recovery_client_timestamps,
        .timestamps_automatic = timestamps_automatic,
        .timeout_current_sources = timeout_current_sources,
        .timeout_pending_sources = timeout_pending_sources,
        .timeout_failure_counts = timeout_failure_counts,
        .first_two_waiting = first_two_waiting,
        .cooldowns_no_tx = cooldowns_no_tx,
        .recovery_source_indices = recovery_source_indices,
        .recovery_switches_succeeded = recovery_switches_succeeded,
        .same_socket_preserved = same_socket_preserved,
        .rotation_count = service.source_rotations,
        .terminal_state = terminal_state,
        .terminal_recovery_state = terminal_recovery_state,
        .terminal_timeout_reached = terminal_timeout_reached,
        .terminal_no_tx = terminal_no_tx,
        .terminal_request_cancelled = terminal_request_cancelled,
        .terminal_retry_exhausted = terminal_retry_exhausted,
        .terminal_recovery_exhausted = terminal_recovery_exhausted,
        .terminal_recovery_limit_hits = terminal_recovery_limit_hits,
        .terminal_recovery_deadline_delta = terminal_recovery_deadline_delta,
        .terminal_source_preserved = terminal_source_preserved,
        .terminal_pending_wrap = terminal_pending_wrap,
        .terminal_failure_count = terminal_failure_count,
        .repeated_exhausted_no_tx = repeated_exhausted_no_tx,
        .repeated_latch_preserved = repeated_latch_preserved,
        .holdover_visible = holdover_visible,
        .holdover_advanced = holdover_advanced,
        .health_reports_source = health_reports_source,
        .health_reports_exhaustion = health_reports_exhaustion,
        .health_reports_holdover = health_reports_holdover,
        .quality_accepted = service.quality_accepted,
        .quality_rejected = service.quality_rejected,
        .step_accepted = service.step_accepted,
        .step_rejected = service.step_rejected,
        .requests_started = service.requests_started,
        .retries = service.retries,
        .responses = service.responses,
        .retry_limit_hits = service.retry_limit_hits,
        .recovery_successes = service.recovery_successes,
        .close_succeeded = close_succeeded,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .final_generation_cursor = device.next_udp_generation,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpSourceFailureReset(
    device: *Device,
    counter: *time_reference.ContinuousCounter,
) ?NtpSourceFailureResetReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_203 or
        device.next_udp_generation != 62 or device.tx_producer != 4 or
        device.next_udp_identification != 97 or device.next_dns_transaction_id != 8 or
        completionQueueEnqueued(&tx_completion_queue) != 124 or
        completionQueueDequeued(&tx_completion_queue) != 124 or
        completionQueueEnqueued(&rx_completion_queue) != 22 or
        device.software_rx_queue.enqueued != 117 or device.software_rx_queue.dequeued != 117 or
        device.packets_dispatched != 106 or device.udp_packets_dispatched != 105 or
        counter.frequency_hz == 0 or counter.counter_bits == 0)
    {
        return null;
    }

    var source_pool = ntp.SourcePool{
        .count = 2,
        .servers = std.mem.zeroes([ntp.maximum_source_pool_entries][4]u8),
    };
    source_pool.servers[0] = .{ 10, 0, 2, 4 };
    source_pool.servers[1] = .{ 10, 0, 2, 5 };
    const rotation_policy = ntp.SourceRotationPolicy{
        .source_count = 2,
        .failures_before_rotation = 2,
    };
    const retry_policy = ntp.RetryPolicy{
        .initial_interval_ticks = 1,
        .maximum_interval_ticks = 1,
        .maximum_retries = 1,
    };
    const recovery_policy = ntp.RecoveryPolicy{
        .cooldown_ticks = 2,
        .maximum_recoveries = 3,
    };
    var service = openNtpServiceWithSourcePoolPolicies(
        device,
        source_pool,
        rotation_policy,
        2,
        ntp.default_quality_policy,
        ntp.default_quality_rejection_policy,
        .{ .maximum_forward_seconds = 4, .maximum_forward_fraction = 0 },
        ntp.default_step_rejection_policy,
        retry_policy,
        recovery_policy,
    ) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 62 or socket.local_port != 49_203 or
        device.udp_endpoint_count != 3 or device.next_ephemeral_udp_port != 49_204 or
        device.next_udp_generation != 63 or service.current_source_index != 0 or
        service.pending_source_index != null or service.consecutive_source_failures != 0 or
        service.source_rotations != 0 or !std.meta.eql(service.client.server_ipv4, source_pool.servers[0]))
        return null;

    const submissions_before = device.tx_submissions;
    const start_tick = counter.read();
    var transmit_identifications = [7]u16{ 0, 0, 0, 0, 0, 0, 0 };
    var transmit_descriptors = [7]u16{ 0, 0, 0, 0, 0, 0, 0 };
    var transmit_next_cursors = [7]u16{ 0, 0, 0, 0, 0, 0, 0 };
    var refresh_timestamps = [2]u64{ 0, 0 };
    var recovery_timestamps = [2]u64{ 0, 0 };
    var accepted_seconds = [2]u64{ 0, 0 };
    var accepted_fractions = [2]u32{ 0, 0 };

    const initial = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const initial_tx = initial.transmit orelse return null;
    transmit_identifications[0] = initial_tx.identification;
    transmit_descriptors[0] = initial_tx.completion.descriptor_index;
    transmit_next_cursors[0] = initial_tx.completion.next_cursor;
    if (initial.state != .awaiting or initial.start_reason != .initial or
        initial_tx.identification != 97 or initial_tx.completion.descriptor_index != 4 or
        initial_tx.completion.next_cursor != 5)
        return null;

    if (!enqueueNtpServiceResponse(
        device,
        socket,
        source_pool.servers[0],
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        0x8700,
        0xF700,
    )) return null;
    const initial_sync = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 1) orelse return null;
    const initial_sample_tick = initial_sync.sample_tick orelse return null;
    if (initial_sync.state != .idle or initial_sync.quality_result != .accepted or
        initial_sync.step_result != .accepted or initial_sync.apply_result != .accepted or
        service.responses != 1 or service.refresh_deadline_tick != initial_sample_tick + 2 or
        service.consecutive_source_failures != 0)
        return null;

    const first_refresh_tick = service.refresh_deadline_tick;
    const expected_first_refresh = ntp.projectedTimestampAt(&service.clock, first_refresh_tick) orelse return null;
    const first_refresh = stepNtpServiceAutomatic(device, &service, counter, first_refresh_tick, 0, 0) orelse return null;
    const first_refresh_tx = first_refresh.transmit orelse return null;
    transmit_identifications[1] = first_refresh_tx.identification;
    transmit_descriptors[1] = first_refresh_tx.completion.descriptor_index;
    transmit_next_cursors[1] = first_refresh_tx.completion.next_cursor;
    refresh_timestamps[0] = service.request.client_timestamp;
    if (first_refresh.state != .awaiting or first_refresh.start_reason != .refresh or
        refresh_timestamps[0] != expected_first_refresh or first_refresh_tx.identification != 98 or
        first_refresh_tx.completion.descriptor_index != 5 or first_refresh_tx.completion.next_cursor != 6)
        return null;

    const first_retry = stepNtpServiceAutomatic(device, &service, counter, first_refresh_tick + 1, 0, 0) orelse return null;
    const first_retry_tx = first_retry.transmit orelse return null;
    transmit_identifications[2] = first_retry_tx.identification;
    transmit_descriptors[2] = first_retry_tx.completion.descriptor_index;
    transmit_next_cursors[2] = first_retry_tx.completion.next_cursor;
    if (!first_retry.retried or first_retry_tx.identification != 99 or
        first_retry_tx.completion.descriptor_index != 6 or first_retry_tx.completion.next_cursor != 7 or
        service.request.client_timestamp != refresh_timestamps[0])
        return null;

    const first_timeout_tick = first_refresh_tick + 2;
    const first_timeout = stepNtpServiceAutomatic(device, &service, counter, first_timeout_tick, 0, 0) orelse return null;
    const first_timeout_pending_absent = service.pending_source_index == null;
    const first_timeout_source_preserved = service.current_source_index == 0 and
        std.meta.eql(service.client.server_ipv4, source_pool.servers[0]);
    if (first_timeout.state != .timed_out or !first_timeout.timeout_reached or
        first_timeout.recovery_state != .waiting or first_timeout.transmit != null or
        !first_timeout_pending_absent or service.consecutive_source_failures != 1 or
        !first_timeout_source_preserved or service.source_rotations != 0)
        return null;

    const first_cooldown = stepNtpServiceAutomatic(device, &service, counter, first_timeout_tick + 1, 0, 0) orelse return null;
    const first_cooldown_no_tx = first_cooldown.state == .timed_out and
        first_cooldown.recovery_state == .waiting and first_cooldown.transmit == null and
        service.current_source_index == 0 and service.pending_source_index == null and
        service.consecutive_source_failures == 1 and service.source_rotations == 0;
    if (!first_cooldown_no_tx) return null;

    const first_recovery_tick = first_timeout_tick + recovery_policy.cooldown_ticks;
    const expected_first_recovery = ntp.projectedTimestampAt(&service.clock, first_recovery_tick) orelse return null;
    const first_recovery = stepNtpServiceAutomatic(device, &service, counter, first_recovery_tick, 0, 0) orelse return null;
    const first_recovery_tx = first_recovery.transmit orelse return null;
    transmit_identifications[3] = first_recovery_tx.identification;
    transmit_descriptors[3] = first_recovery_tx.completion.descriptor_index;
    transmit_next_cursors[3] = first_recovery_tx.completion.next_cursor;
    recovery_timestamps[0] = service.request.client_timestamp;
    const first_recovery_same_source = service.current_source_index == 0 and
        std.meta.eql(service.client.server_ipv4, source_pool.servers[0]) and
        service.pending_source_index == null and service.consecutive_source_failures == 1 and
        service.source_rotations == 0 and std.meta.eql(service.client.socket, socket);
    const first_recovery_started = first_recovery.state == .awaiting and
        first_recovery.start_reason == .recovery and first_recovery.recovery_state == .ready and
        first_recovery.recovery_started and service.automatic_recoveries == 1;
    if (recovery_timestamps[0] != expected_first_recovery or !first_recovery_same_source or
        !first_recovery_started or first_recovery_tx.identification != 100 or
        first_recovery_tx.completion.descriptor_index != 7 or first_recovery_tx.completion.next_cursor != 0)
        return null;

    const first_recovered_server_timestamp = ntp.fixture_server_timestamp + (@as(u64, 2) << 32);
    if (!enqueueNtpServiceResponse(
        device,
        socket,
        source_pool.servers[0],
        service.request.client_timestamp,
        first_recovered_server_timestamp,
        0x8701,
        0xF701,
    )) return null;
    const first_accepted = stepNtpServiceAutomatic(device, &service, counter, first_recovery_tick, 0, 1) orelse return null;
    const first_accepted_tick = first_accepted.sample_tick orelse return null;
    const first_accepted_time = ntp.readProjectedClockAt(&service.clock, first_accepted_tick) orelse return null;
    accepted_seconds[0] = first_accepted_time.seconds;
    accepted_fractions[0] = first_accepted_time.fraction;
    const first_recovery_accepted = first_accepted.state == .idle and
        first_accepted.quality_result == .accepted and first_accepted.step_result == .accepted and
        first_accepted.apply_result == .accepted and accepted_seconds[0] == ntp.fixture_unix_seconds + 2 and
        accepted_fractions[0] == 0x80000000;
    const first_success_reset_failures = service.consecutive_source_failures == 0 and
        service.pending_source_index == null;
    const first_success_no_rotation = service.current_source_index == 0 and service.source_rotations == 0 and
        std.meta.eql(service.client.server_ipv4, source_pool.servers[0]);
    const first_success_health = readNtpServiceHealth(&service, first_accepted_tick, 1, 100) orelse return null;
    const first_success_health_reset = first_success_health.state == .synchronized and
        first_success_health.consecutive_source_failures == 0 and first_success_health.pending_source_index == null and
        first_success_health.current_source_index == 0 and first_success_health.source_rotations == 0 and
        first_success_health.recovery_successes == 1;
    if (!first_recovery_accepted or !first_success_reset_failures or !first_success_no_rotation or
        !first_success_health_reset)
        return null;

    const second_refresh_tick = service.refresh_deadline_tick;
    const expected_second_refresh = ntp.projectedTimestampAt(&service.clock, second_refresh_tick) orelse return null;
    const second_refresh = stepNtpServiceAutomatic(device, &service, counter, second_refresh_tick, 0, 0) orelse return null;
    const second_refresh_tx = second_refresh.transmit orelse return null;
    transmit_identifications[4] = second_refresh_tx.identification;
    transmit_descriptors[4] = second_refresh_tx.completion.descriptor_index;
    transmit_next_cursors[4] = second_refresh_tx.completion.next_cursor;
    refresh_timestamps[1] = service.request.client_timestamp;
    if (second_refresh.state != .awaiting or second_refresh.start_reason != .refresh or
        refresh_timestamps[1] != expected_second_refresh or refresh_timestamps[1] <= recovery_timestamps[0] or
        second_refresh_tx.identification != 101 or second_refresh_tx.completion.descriptor_index != 0 or
        second_refresh_tx.completion.next_cursor != 1)
        return null;

    const second_retry = stepNtpServiceAutomatic(device, &service, counter, second_refresh_tick + 1, 0, 0) orelse return null;
    const second_retry_tx = second_retry.transmit orelse return null;
    transmit_identifications[5] = second_retry_tx.identification;
    transmit_descriptors[5] = second_retry_tx.completion.descriptor_index;
    transmit_next_cursors[5] = second_retry_tx.completion.next_cursor;
    if (!second_retry.retried or second_retry_tx.identification != 102 or
        second_retry_tx.completion.descriptor_index != 1 or second_retry_tx.completion.next_cursor != 2 or
        service.request.client_timestamp != refresh_timestamps[1])
        return null;

    const second_timeout_tick = second_refresh_tick + 2;
    const second_timeout = stepNtpServiceAutomatic(device, &service, counter, second_timeout_tick, 0, 0) orelse return null;
    const second_timeout_pending_absent = service.pending_source_index == null;
    const second_timeout_source_preserved = service.current_source_index == 0 and
        std.meta.eql(service.client.server_ipv4, source_pool.servers[0]);
    const second_timeout_not_accumulated = service.consecutive_source_failures == 1 and
        service.source_rotations == 0;
    if (second_timeout.state != .timed_out or !second_timeout.timeout_reached or
        second_timeout.recovery_state != .waiting or second_timeout.transmit != null or
        !second_timeout_pending_absent or !second_timeout_source_preserved or !second_timeout_not_accumulated)
        return null;

    const second_cooldown = stepNtpServiceAutomatic(device, &service, counter, second_timeout_tick + 1, 0, 0) orelse return null;
    const second_cooldown_no_tx = second_cooldown.state == .timed_out and
        second_cooldown.recovery_state == .waiting and second_cooldown.transmit == null and
        service.current_source_index == 0 and service.pending_source_index == null and
        service.consecutive_source_failures == 1 and service.source_rotations == 0;
    if (!second_cooldown_no_tx) return null;

    const second_recovery_tick = second_timeout_tick + recovery_policy.cooldown_ticks;
    const expected_second_recovery = ntp.projectedTimestampAt(&service.clock, second_recovery_tick) orelse return null;
    const second_recovery = stepNtpServiceAutomatic(device, &service, counter, second_recovery_tick, 0, 0) orelse return null;
    const second_recovery_tx = second_recovery.transmit orelse return null;
    transmit_identifications[6] = second_recovery_tx.identification;
    transmit_descriptors[6] = second_recovery_tx.completion.descriptor_index;
    transmit_next_cursors[6] = second_recovery_tx.completion.next_cursor;
    recovery_timestamps[1] = service.request.client_timestamp;
    const second_recovery_same_source = service.current_source_index == 0 and
        std.meta.eql(service.client.server_ipv4, source_pool.servers[0]) and
        service.pending_source_index == null and service.consecutive_source_failures == 1 and
        service.source_rotations == 0 and std.meta.eql(service.client.socket, socket);
    const second_recovery_started = second_recovery.state == .awaiting and
        second_recovery.start_reason == .recovery and second_recovery.recovery_state == .ready and
        second_recovery.recovery_started and service.automatic_recoveries == 1;
    const timestamps_automatic = refresh_timestamps[0] < recovery_timestamps[0] and
        recovery_timestamps[0] < refresh_timestamps[1] and refresh_timestamps[1] < recovery_timestamps[1] and
        recovery_timestamps[1] == expected_second_recovery;
    if (!timestamps_automatic or !second_recovery_same_source or !second_recovery_started or
        second_recovery_tx.identification != 103 or second_recovery_tx.completion.descriptor_index != 2 or
        second_recovery_tx.completion.next_cursor != 3)
        return null;

    const second_recovered_server_timestamp = ntp.fixture_server_timestamp + (@as(u64, 4) << 32);
    if (!enqueueNtpServiceResponse(
        device,
        socket,
        source_pool.servers[0],
        service.request.client_timestamp,
        second_recovered_server_timestamp,
        0x8702,
        0xF702,
    )) return null;
    const second_accepted = stepNtpServiceAutomatic(device, &service, counter, second_recovery_tick, 0, 1) orelse return null;
    const second_accepted_tick = second_accepted.sample_tick orelse return null;
    const second_accepted_time = ntp.readProjectedClockAt(&service.clock, second_accepted_tick) orelse return null;
    accepted_seconds[1] = second_accepted_time.seconds;
    accepted_fractions[1] = second_accepted_time.fraction;
    const second_recovery_accepted = second_accepted.state == .idle and
        second_accepted.quality_result == .accepted and second_accepted.step_result == .accepted and
        second_accepted.apply_result == .accepted and accepted_seconds[1] == ntp.fixture_unix_seconds + 4 and
        accepted_fractions[1] == 0x80000000;
    const final_failure_count_reset = service.consecutive_source_failures == 0 and
        service.pending_source_index == null;
    const final_no_rotation = service.current_source_index == 0 and service.source_rotations == 0 and
        std.meta.eql(service.client.server_ipv4, source_pool.servers[0]);
    const same_socket_preserved = std.meta.eql(service.client.socket, socket);
    const final_health = readNtpServiceHealth(&service, second_accepted_tick, 1, 100) orelse return null;
    const health_reports_source_zero = final_health.current_source_index == 0 and
        std.meta.eql(final_health.current_server_ipv4, source_pool.servers[0]) and
        final_health.pending_source_index == null;
    const health_reports_clean_chain = final_health.consecutive_source_failures == 0 and
        final_health.source_rotations == 0;
    const health_reports_success = final_health.state == .synchronized and final_health.current_time != null and
        final_health.recovery_successes == 2 and !final_health.retry_exhausted and !final_health.recovery_exhausted;
    if (!second_recovery_accepted or !final_failure_count_reset or !final_no_rotation or
        !same_socket_preserved or !health_reports_source_zero or !health_reports_clean_chain or
        !health_reports_success)
        return null;

    const close_succeeded = closeNtpService(device, &service);
    if (!close_succeeded or service.active or service.client.active or service.request_active) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_204 or
        device.next_udp_generation != 63 or device.next_udp_identification != 104 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 3 or
        device.tx_submissions != submissions_before + 7 or txe != 131 or txd != 131 or rxe != 22 or
        overflow != 0 or device.software_rx_queue.enqueued != 120 or
        device.software_rx_queue.dequeued != 120 or device.packets_dispatched != 109 or
        device.udp_packets_dispatched != 108 or service.quality_accepted != 3 or
        service.quality_rejected != 0 or service.step_accepted != 3 or service.step_rejected != 0 or
        service.requests_started != 5 or service.retries != 2 or service.responses != 3 or
        service.retry_limit_hits != 2 or service.recovery_successes != 2 or
        service.source_rotations != 0)
        return null;

    return .{
        .source_kind = counter.reference.kind,
        .frequency_hz = counter.frequency_hz,
        .counter_bits = counter.counter_bits,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .source_count = source_pool.count,
        .failures_before_rotation = rotation_policy.failures_before_rotation,
        .server = source_pool.servers[0],
        .transmit_identifications = transmit_identifications,
        .transmit_descriptors = transmit_descriptors,
        .transmit_next_cursors = transmit_next_cursors,
        .refresh_timestamps = refresh_timestamps,
        .recovery_timestamps = recovery_timestamps,
        .timestamps_automatic = timestamps_automatic,
        .first_timeout_pending_absent = first_timeout_pending_absent,
        .first_timeout_failure_count = 1,
        .first_timeout_source_preserved = first_timeout_source_preserved,
        .first_cooldown_no_tx = first_cooldown_no_tx,
        .first_recovery_same_source = first_recovery_same_source,
        .first_recovery_started = first_recovery_started,
        .first_recovery_accepted = first_recovery_accepted,
        .first_success_reset_failures = first_success_reset_failures,
        .first_success_no_rotation = first_success_no_rotation,
        .first_success_health_reset = first_success_health_reset,
        .second_timeout_pending_absent = second_timeout_pending_absent,
        .second_timeout_failure_count = 1,
        .second_timeout_source_preserved = second_timeout_source_preserved,
        .second_timeout_not_accumulated = second_timeout_not_accumulated,
        .second_cooldown_no_tx = second_cooldown_no_tx,
        .second_recovery_same_source = second_recovery_same_source,
        .second_recovery_started = second_recovery_started,
        .second_recovery_accepted = second_recovery_accepted,
        .final_failure_count_reset = final_failure_count_reset,
        .final_no_rotation = final_no_rotation,
        .same_socket_preserved = same_socket_preserved,
        .accepted_seconds = accepted_seconds,
        .accepted_fractions = accepted_fractions,
        .recovery_successes = service.recovery_successes,
        .health_reports_source_zero = health_reports_source_zero,
        .health_reports_clean_chain = health_reports_clean_chain,
        .health_reports_success = health_reports_success,
        .quality_accepted = service.quality_accepted,
        .quality_rejected = service.quality_rejected,
        .step_accepted = service.step_accepted,
        .step_rejected = service.step_rejected,
        .requests_started = service.requests_started,
        .retries = service.retries,
        .responses = service.responses,
        .retry_limit_hits = service.retry_limit_hits,
        .close_succeeded = close_succeeded,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .final_generation_cursor = device.next_udp_generation,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpSourceWraparound(
    device: *Device,
    counter: *time_reference.ContinuousCounter,
) ?NtpSourceWraparoundReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_202 or
        device.next_udp_generation != 61 or device.tx_producer != 4 or
        device.next_udp_identification != 89 or device.next_dns_transaction_id != 8 or
        completionQueueEnqueued(&tx_completion_queue) != 116 or
        completionQueueDequeued(&tx_completion_queue) != 116 or
        completionQueueEnqueued(&rx_completion_queue) != 22 or
        device.software_rx_queue.enqueued != 115 or device.software_rx_queue.dequeued != 115 or
        device.packets_dispatched != 104 or device.udp_packets_dispatched != 103 or
        counter.frequency_hz == 0 or counter.counter_bits == 0)
    {
        return null;
    }

    var source_pool = ntp.SourcePool{
        .count = 3,
        .servers = std.mem.zeroes([ntp.maximum_source_pool_entries][4]u8),
    };
    source_pool.servers[0] = .{ 10, 0, 2, 4 };
    source_pool.servers[1] = .{ 10, 0, 2, 5 };
    source_pool.servers[2] = .{ 10, 0, 2, 6 };
    const rotation_policy = ntp.SourceRotationPolicy{
        .source_count = 3,
        .failures_before_rotation = 1,
    };
    const retry_policy = ntp.RetryPolicy{
        .initial_interval_ticks = 1,
        .maximum_interval_ticks = 1,
        .maximum_retries = 1,
    };
    const recovery_policy = ntp.RecoveryPolicy{
        .cooldown_ticks = 2,
        .maximum_recoveries = 4,
    };
    var service = openNtpServiceWithSourcePoolPolicies(
        device,
        source_pool,
        rotation_policy,
        2,
        ntp.default_quality_policy,
        ntp.default_quality_rejection_policy,
        .{ .maximum_forward_seconds = 4, .maximum_forward_fraction = 0 },
        ntp.default_step_rejection_policy,
        retry_policy,
        recovery_policy,
    ) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 61 or socket.local_port != 49_202 or
        device.udp_endpoint_count != 3 or device.next_ephemeral_udp_port != 49_203 or
        device.next_udp_generation != 62 or service.current_source_index != 0 or
        service.pending_source_index != null or service.source_rotations != 0 or
        !std.meta.eql(service.client.server_ipv4, source_pool.servers[0]))
        return null;

    const submissions_before = device.tx_submissions;
    const start_tick = counter.read();
    var transmit_identifications = [8]u16{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var transmit_descriptors = [8]u16{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var transmit_next_cursors = [8]u16{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var timeout_current_sources = [3]u8{ 0, 0, 0 };
    var timeout_pending_sources = [3]u8{ 0, 0, 0 };
    var timeout_failure_counts = [3]u8{ 0, 0, 0 };
    var cooldowns_no_tx = [3]bool{ false, false, false };
    var recovery_source_indices = [3]u8{ 0, 0, 0 };
    var recovery_switches_succeeded = [3]bool{ false, false, false };
    var recovery_client_timestamps = [3]u64{ 0, 0, 0 };

    const initial = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const initial_tx = initial.transmit orelse return null;
    transmit_identifications[0] = initial_tx.identification;
    transmit_descriptors[0] = initial_tx.completion.descriptor_index;
    transmit_next_cursors[0] = initial_tx.completion.next_cursor;
    if (initial.state != .awaiting or initial.start_reason != .initial or
        initial_tx.identification != 89 or initial_tx.completion.descriptor_index != 4 or
        initial_tx.completion.next_cursor != 5)
        return null;

    if (!enqueueNtpServiceResponse(
        device,
        socket,
        source_pool.servers[0],
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        0x8600,
        0xF600,
    )) return null;
    const first_sync = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 1) orelse return null;
    const first_sample_tick = first_sync.sample_tick orelse return null;
    if (first_sync.state != .idle or first_sync.quality_result != .accepted or
        first_sync.step_result != .accepted or first_sync.apply_result != .accepted or
        service.refresh_deadline_tick != first_sample_tick + 2)
        return null;

    const refresh_tick = service.refresh_deadline_tick;
    const expected_refresh_timestamp = ntp.projectedTimestampAt(&service.clock, refresh_tick) orelse return null;
    const refresh = stepNtpServiceAutomatic(device, &service, counter, refresh_tick, 0, 0) orelse return null;
    const refresh_tx = refresh.transmit orelse return null;
    transmit_identifications[1] = refresh_tx.identification;
    transmit_descriptors[1] = refresh_tx.completion.descriptor_index;
    transmit_next_cursors[1] = refresh_tx.completion.next_cursor;
    const refresh_client_timestamp = service.request.client_timestamp;
    if (refresh.state != .awaiting or refresh.start_reason != .refresh or
        refresh_client_timestamp != expected_refresh_timestamp or refresh_tx.identification != 90 or
        refresh_tx.completion.descriptor_index != 5 or refresh_tx.completion.next_cursor != 6)
        return null;

    const first_retry = stepNtpServiceAutomatic(device, &service, counter, refresh_tick + 1, 0, 0) orelse return null;
    const first_retry_tx = first_retry.transmit orelse return null;
    transmit_identifications[2] = first_retry_tx.identification;
    transmit_descriptors[2] = first_retry_tx.completion.descriptor_index;
    transmit_next_cursors[2] = first_retry_tx.completion.next_cursor;
    if (!first_retry.retried or first_retry_tx.identification != 91 or
        first_retry_tx.completion.descriptor_index != 6 or first_retry_tx.completion.next_cursor != 7)
        return null;

    const first_timeout_tick = refresh_tick + 2;
    const first_timeout = stepNtpServiceAutomatic(device, &service, counter, first_timeout_tick, 0, 0) orelse return null;
    timeout_current_sources[0] = service.current_source_index;
    timeout_pending_sources[0] = service.pending_source_index orelse return null;
    timeout_failure_counts[0] = service.consecutive_source_failures;
    if (first_timeout.state != .timed_out or !first_timeout.timeout_reached or
        first_timeout.recovery_state != .waiting or first_timeout.transmit != null or
        timeout_current_sources[0] != 0 or timeout_pending_sources[0] != 1 or
        timeout_failure_counts[0] != 1 or !std.meta.eql(service.client.server_ipv4, source_pool.servers[0]))
        return null;

    const first_cooldown = stepNtpServiceAutomatic(device, &service, counter, first_timeout_tick + 1, 0, 0) orelse return null;
    cooldowns_no_tx[0] = first_cooldown.state == .timed_out and
        first_cooldown.recovery_state == .waiting and first_cooldown.transmit == null and
        service.current_source_index == 0 and service.pending_source_index == 1;
    if (!cooldowns_no_tx[0]) return null;

    const first_recovery_tick = first_timeout_tick + 2;
    const expected_first_recovery_timestamp = ntp.projectedTimestampAt(&service.clock, first_recovery_tick) orelse return null;
    const first_recovery = stepNtpServiceAutomatic(device, &service, counter, first_recovery_tick, 0, 0) orelse return null;
    const first_recovery_tx = first_recovery.transmit orelse return null;
    transmit_identifications[3] = first_recovery_tx.identification;
    transmit_descriptors[3] = first_recovery_tx.completion.descriptor_index;
    transmit_next_cursors[3] = first_recovery_tx.completion.next_cursor;
    recovery_client_timestamps[0] = service.request.client_timestamp;
    recovery_source_indices[0] = service.current_source_index;
    recovery_switches_succeeded[0] = recovery_source_indices[0] == 1 and
        std.meta.eql(service.client.server_ipv4, source_pool.servers[1]) and
        std.meta.eql(service.client.socket, socket) and service.source_rotations == 1 and
        service.pending_source_index == null and service.consecutive_source_failures == 0;
    if (first_recovery.state != .awaiting or first_recovery.start_reason != .recovery or
        !first_recovery.recovery_started or recovery_client_timestamps[0] != expected_first_recovery_timestamp or
        !recovery_switches_succeeded[0] or first_recovery_tx.identification != 92 or
        first_recovery_tx.completion.descriptor_index != 7 or first_recovery_tx.completion.next_cursor != 0)
        return null;

    const second_retry = stepNtpServiceAutomatic(device, &service, counter, first_recovery_tick + 1, 0, 0) orelse return null;
    const second_retry_tx = second_retry.transmit orelse return null;
    transmit_identifications[4] = second_retry_tx.identification;
    transmit_descriptors[4] = second_retry_tx.completion.descriptor_index;
    transmit_next_cursors[4] = second_retry_tx.completion.next_cursor;
    if (!second_retry.retried or second_retry_tx.identification != 93 or
        second_retry_tx.completion.descriptor_index != 0 or second_retry_tx.completion.next_cursor != 1)
        return null;

    const second_timeout_tick = first_recovery_tick + 2;
    const second_timeout = stepNtpServiceAutomatic(device, &service, counter, second_timeout_tick, 0, 0) orelse return null;
    timeout_current_sources[1] = service.current_source_index;
    timeout_pending_sources[1] = service.pending_source_index orelse return null;
    timeout_failure_counts[1] = service.consecutive_source_failures;
    if (second_timeout.state != .timed_out or !second_timeout.timeout_reached or
        second_timeout.recovery_state != .waiting or second_timeout.transmit != null or
        timeout_current_sources[1] != 1 or timeout_pending_sources[1] != 2 or
        timeout_failure_counts[1] != 1 or !std.meta.eql(service.client.server_ipv4, source_pool.servers[1]))
        return null;

    const second_cooldown = stepNtpServiceAutomatic(device, &service, counter, second_timeout_tick + 1, 0, 0) orelse return null;
    cooldowns_no_tx[1] = second_cooldown.state == .timed_out and
        second_cooldown.recovery_state == .waiting and second_cooldown.transmit == null and
        service.current_source_index == 1 and service.pending_source_index == 2;
    if (!cooldowns_no_tx[1]) return null;

    const second_recovery_tick = second_timeout_tick + 2;
    const expected_second_recovery_timestamp = ntp.projectedTimestampAt(&service.clock, second_recovery_tick) orelse return null;
    const second_recovery = stepNtpServiceAutomatic(device, &service, counter, second_recovery_tick, 0, 0) orelse return null;
    const second_recovery_tx = second_recovery.transmit orelse return null;
    transmit_identifications[5] = second_recovery_tx.identification;
    transmit_descriptors[5] = second_recovery_tx.completion.descriptor_index;
    transmit_next_cursors[5] = second_recovery_tx.completion.next_cursor;
    recovery_client_timestamps[1] = service.request.client_timestamp;
    recovery_source_indices[1] = service.current_source_index;
    recovery_switches_succeeded[1] = recovery_source_indices[1] == 2 and
        std.meta.eql(service.client.server_ipv4, source_pool.servers[2]) and
        std.meta.eql(service.client.socket, socket) and service.source_rotations == 2 and
        service.pending_source_index == null and service.consecutive_source_failures == 0;
    if (second_recovery.state != .awaiting or second_recovery.start_reason != .recovery or
        !second_recovery.recovery_started or recovery_client_timestamps[1] != expected_second_recovery_timestamp or
        !recovery_switches_succeeded[1] or second_recovery_tx.identification != 94 or
        second_recovery_tx.completion.descriptor_index != 1 or second_recovery_tx.completion.next_cursor != 2)
        return null;

    const third_retry = stepNtpServiceAutomatic(device, &service, counter, second_recovery_tick + 1, 0, 0) orelse return null;
    const third_retry_tx = third_retry.transmit orelse return null;
    transmit_identifications[6] = third_retry_tx.identification;
    transmit_descriptors[6] = third_retry_tx.completion.descriptor_index;
    transmit_next_cursors[6] = third_retry_tx.completion.next_cursor;
    if (!third_retry.retried or third_retry_tx.identification != 95 or
        third_retry_tx.completion.descriptor_index != 2 or third_retry_tx.completion.next_cursor != 3)
        return null;

    const third_timeout_tick = second_recovery_tick + 2;
    const third_timeout = stepNtpServiceAutomatic(device, &service, counter, third_timeout_tick, 0, 0) orelse return null;
    timeout_current_sources[2] = service.current_source_index;
    timeout_pending_sources[2] = service.pending_source_index orelse return null;
    timeout_failure_counts[2] = service.consecutive_source_failures;
    if (third_timeout.state != .timed_out or !third_timeout.timeout_reached or
        third_timeout.recovery_state != .waiting or third_timeout.transmit != null or
        timeout_current_sources[2] != 2 or timeout_pending_sources[2] != 0 or
        timeout_failure_counts[2] != 1 or !std.meta.eql(service.client.server_ipv4, source_pool.servers[2]))
        return null;

    const third_cooldown = stepNtpServiceAutomatic(device, &service, counter, third_timeout_tick + 1, 0, 0) orelse return null;
    cooldowns_no_tx[2] = third_cooldown.state == .timed_out and
        third_cooldown.recovery_state == .waiting and third_cooldown.transmit == null and
        service.current_source_index == 2 and service.pending_source_index == 0;
    if (!cooldowns_no_tx[2]) return null;

    const third_recovery_tick = third_timeout_tick + 2;
    const expected_third_recovery_timestamp = ntp.projectedTimestampAt(&service.clock, third_recovery_tick) orelse return null;
    const third_recovery = stepNtpServiceAutomatic(device, &service, counter, third_recovery_tick, 0, 0) orelse return null;
    const third_recovery_tx = third_recovery.transmit orelse return null;
    transmit_identifications[7] = third_recovery_tx.identification;
    transmit_descriptors[7] = third_recovery_tx.completion.descriptor_index;
    transmit_next_cursors[7] = third_recovery_tx.completion.next_cursor;
    recovery_client_timestamps[2] = service.request.client_timestamp;
    recovery_source_indices[2] = service.current_source_index;
    recovery_switches_succeeded[2] = recovery_source_indices[2] == 0 and
        std.meta.eql(service.client.server_ipv4, source_pool.servers[0]) and
        std.meta.eql(service.client.socket, socket) and service.source_rotations == 3 and
        service.pending_source_index == null and service.consecutive_source_failures == 0;
    const recovery_timestamps_automatic = recovery_client_timestamps[0] == expected_first_recovery_timestamp and
        recovery_client_timestamps[1] == expected_second_recovery_timestamp and
        recovery_client_timestamps[2] == expected_third_recovery_timestamp and
        refresh_client_timestamp < recovery_client_timestamps[0] and
        recovery_client_timestamps[0] < recovery_client_timestamps[1] and
        recovery_client_timestamps[1] < recovery_client_timestamps[2];
    const same_socket_preserved = std.meta.eql(service.client.socket, socket);
    const wrap_completed = recovery_switches_succeeded[0] and recovery_switches_succeeded[1] and
        recovery_switches_succeeded[2] and service.current_source_index == 0 and service.source_rotations == 3;
    if (third_recovery.state != .awaiting or third_recovery.start_reason != .recovery or
        !third_recovery.recovery_started or !recovery_timestamps_automatic or !same_socket_preserved or
        !wrap_completed or third_recovery_tx.identification != 96 or
        third_recovery_tx.completion.descriptor_index != 3 or third_recovery_tx.completion.next_cursor != 4)
        return null;

    const peer_after_wrap = udpSocketPeer(device, socket) orelse return null;
    if (!std.meta.eql(peer_after_wrap.ipv4, source_pool.servers[0]) or
        !std.meta.eql(peer_after_wrap.mac, device.gateway_mac) or peer_after_wrap.port != ntp.server_port)
        return null;

    const recovered_server_timestamp = ntp.fixture_server_timestamp + (@as(u64, 2) << 32);
    if (!enqueueNtpServiceResponse(
        device,
        socket,
        source_pool.servers[0],
        service.request.client_timestamp,
        recovered_server_timestamp,
        0x8601,
        0xF601,
    )) return null;
    const accepted = stepNtpServiceAutomatic(device, &service, counter, third_recovery_tick, 0, 1) orelse return null;
    const accepted_quality_result = accepted.quality_result orelse return null;
    const accepted_step_result = accepted.step_result orelse return null;
    const accepted_sample_tick = accepted.sample_tick orelse return null;
    const accepted_time = ntp.readProjectedClockAt(&service.clock, accepted_sample_tick) orelse return null;
    if (accepted.state != .idle or accepted_quality_result != .accepted or
        accepted_step_result != .accepted or accepted.apply_result != .accepted or
        accepted_time.seconds != ntp.fixture_unix_seconds + 2 or accepted_time.fraction != 0x80000000 or
        service.recovery_successes != 1 or service.current_source_index != 0 or
        !std.meta.eql(service.client.server_ipv4, source_pool.servers[0]) or
        service.pending_source_index != null or service.consecutive_source_failures != 0 or
        service.source_rotations != 3 or service.retry_exhausted or service.automatic_recoveries != 0)
        return null;

    const health = readNtpServiceHealth(&service, accepted_sample_tick, 1, 100) orelse return null;
    const health_reports_source_zero = health.current_source_index == 0 and
        std.meta.eql(health.current_server_ipv4, source_pool.servers[0]) and health.pending_source_index == null;
    const health_reports_rotations = health.source_rotations == 3 and health.consecutive_source_failures == 0;
    const health_reports_success = health.state == .synchronized and health.current_time != null and
        health.recovery_successes == 1 and !health.retry_exhausted and !health.recovery_exhausted;
    if (!health_reports_source_zero or !health_reports_rotations or !health_reports_success) return null;

    const close_succeeded = closeNtpService(device, &service);
    if (!close_succeeded or service.active or service.client.active or service.request_active) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_203 or
        device.next_udp_generation != 62 or device.next_udp_identification != 97 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 4 or
        device.tx_submissions != submissions_before + 8 or txe != 124 or txd != 124 or rxe != 22 or
        overflow != 0 or device.software_rx_queue.enqueued != 117 or
        device.software_rx_queue.dequeued != 117 or device.packets_dispatched != 106 or
        device.udp_packets_dispatched != 105 or service.quality_accepted != 2 or
        service.quality_rejected != 0 or service.step_accepted != 2 or service.step_rejected != 0 or
        service.requests_started != 5 or service.retries != 3 or service.responses != 2 or
        service.retry_limit_hits != 3 or service.recovery_successes != 1 or
        service.source_rotations != 3)
        return null;

    return .{
        .source_kind = counter.reference.kind,
        .frequency_hz = counter.frequency_hz,
        .counter_bits = counter.counter_bits,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .source_count = source_pool.count,
        .failures_before_rotation = rotation_policy.failures_before_rotation,
        .servers = .{ source_pool.servers[0], source_pool.servers[1], source_pool.servers[2] },
        .transmit_identifications = transmit_identifications,
        .transmit_descriptors = transmit_descriptors,
        .transmit_next_cursors = transmit_next_cursors,
        .refresh_client_timestamp = refresh_client_timestamp,
        .recovery_client_timestamps = recovery_client_timestamps,
        .recovery_timestamps_automatic = recovery_timestamps_automatic,
        .timeout_current_sources = timeout_current_sources,
        .timeout_pending_sources = timeout_pending_sources,
        .timeout_failure_counts = timeout_failure_counts,
        .timeout_servers_preserved = true,
        .cooldowns_no_tx = cooldowns_no_tx,
        .recovery_source_indices = recovery_source_indices,
        .recovery_switches_succeeded = recovery_switches_succeeded,
        .same_socket_preserved = same_socket_preserved,
        .rotation_count = service.source_rotations,
        .wrap_completed = wrap_completed,
        .accepted_quality_result = accepted_quality_result,
        .accepted_step_result = accepted_step_result,
        .accepted_sample_tick = accepted_sample_tick,
        .accepted_seconds = accepted_time.seconds,
        .accepted_fraction = accepted_time.fraction,
        .recovery_successes = service.recovery_successes,
        .health_reports_source_zero = health_reports_source_zero,
        .health_reports_rotations = health_reports_rotations,
        .health_reports_success = health_reports_success,
        .quality_accepted = service.quality_accepted,
        .quality_rejected = service.quality_rejected,
        .step_accepted = service.step_accepted,
        .step_rejected = service.step_rejected,
        .requests_started = service.requests_started,
        .retries = service.retries,
        .responses = service.responses,
        .retry_limit_hits = service.retry_limit_hits,
        .close_succeeded = close_succeeded,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .final_generation_cursor = device.next_udp_generation,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpThresholdedSourceFailover(
    device: *Device,
    counter: *time_reference.ContinuousCounter,
) ?NtpThresholdedSourceFailoverReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_201 or
        device.next_udp_generation != 60 or device.tx_producer != 6 or
        device.next_udp_identification != 83 or device.next_dns_transaction_id != 8 or
        completionQueueEnqueued(&tx_completion_queue) != 110 or
        completionQueueDequeued(&tx_completion_queue) != 110 or
        completionQueueEnqueued(&rx_completion_queue) != 22 or
        device.software_rx_queue.enqueued != 113 or device.software_rx_queue.dequeued != 113 or
        device.packets_dispatched != 102 or device.udp_packets_dispatched != 101 or
        counter.frequency_hz == 0 or counter.counter_bits == 0)
    {
        return null;
    }

    var source_pool = ntp.SourcePool{
        .count = 2,
        .servers = std.mem.zeroes([ntp.maximum_source_pool_entries][4]u8),
    };
    source_pool.servers[0] = .{ 10, 0, 2, 4 };
    source_pool.servers[1] = .{ 10, 0, 2, 5 };
    const rotation_policy = ntp.SourceRotationPolicy{
        .source_count = 2,
        .failures_before_rotation = 2,
    };
    const retry_policy = ntp.RetryPolicy{
        .initial_interval_ticks = 1,
        .maximum_interval_ticks = 1,
        .maximum_retries = 1,
    };
    const recovery_policy = ntp.RecoveryPolicy{
        .cooldown_ticks = 2,
        .maximum_recoveries = 3,
    };
    var service = openNtpServiceWithSourcePoolPolicies(
        device,
        source_pool,
        rotation_policy,
        2,
        ntp.default_quality_policy,
        ntp.default_quality_rejection_policy,
        .{ .maximum_forward_seconds = 4, .maximum_forward_fraction = 0 },
        ntp.default_step_rejection_policy,
        retry_policy,
        recovery_policy,
    ) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 60 or socket.local_port != 49_201 or
        device.udp_endpoint_count != 3 or device.next_ephemeral_udp_port != 49_202 or
        device.next_udp_generation != 61 or service.current_source_index != 0 or
        service.pending_source_index != null or service.consecutive_source_failures != 0 or
        service.source_rotations != 0 or !std.meta.eql(service.client.server_ipv4, source_pool.servers[0]))
        return null;

    const submissions_before = device.tx_submissions;
    const start_tick = counter.read();
    var transmit_identifications = [6]u16{ 0, 0, 0, 0, 0, 0 };
    var transmit_descriptors = [6]u16{ 0, 0, 0, 0, 0, 0 };
    var transmit_next_cursors = [6]u16{ 0, 0, 0, 0, 0, 0 };

    const initial = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const initial_tx = initial.transmit orelse return null;
    transmit_identifications[0] = initial_tx.identification;
    transmit_descriptors[0] = initial_tx.completion.descriptor_index;
    transmit_next_cursors[0] = initial_tx.completion.next_cursor;
    if (initial.state != .awaiting or initial.start_reason != .initial or
        initial_tx.identification != 83 or initial_tx.completion.descriptor_index != 6 or
        initial_tx.completion.next_cursor != 7)
        return null;

    if (!enqueueNtpServiceResponse(
        device,
        socket,
        source_pool.servers[0],
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        0x8500,
        0xF500,
    )) return null;
    const first_sync = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 1) orelse return null;
    const first_sample_tick = first_sync.sample_tick orelse return null;
    if (first_sync.state != .idle or first_sync.quality_result != .accepted or
        first_sync.step_result != .accepted or first_sync.apply_result != .accepted or
        service.responses != 1 or service.refresh_deadline_tick != first_sample_tick + 2)
        return null;

    const refresh_tick = service.refresh_deadline_tick;
    const expected_refresh_timestamp = ntp.projectedTimestampAt(&service.clock, refresh_tick) orelse return null;
    const refresh = stepNtpServiceAutomatic(device, &service, counter, refresh_tick, 0, 0) orelse return null;
    const refresh_tx = refresh.transmit orelse return null;
    transmit_identifications[1] = refresh_tx.identification;
    transmit_descriptors[1] = refresh_tx.completion.descriptor_index;
    transmit_next_cursors[1] = refresh_tx.completion.next_cursor;
    const refresh_client_timestamp = service.request.client_timestamp;
    if (refresh.state != .awaiting or refresh.start_reason != .refresh or
        refresh_client_timestamp != expected_refresh_timestamp or refresh_tx.identification != 84 or
        refresh_tx.completion.descriptor_index != 7 or refresh_tx.completion.next_cursor != 0)
        return null;

    const refresh_retry = stepNtpServiceAutomatic(device, &service, counter, refresh_tick + 1, 0, 0) orelse return null;
    const refresh_retry_tx = refresh_retry.transmit orelse return null;
    transmit_identifications[2] = refresh_retry_tx.identification;
    transmit_descriptors[2] = refresh_retry_tx.completion.descriptor_index;
    transmit_next_cursors[2] = refresh_retry_tx.completion.next_cursor;
    if (!refresh_retry.retried or refresh_retry.timeout_reached or
        refresh_retry_tx.identification != 85 or refresh_retry_tx.completion.descriptor_index != 0 or
        refresh_retry_tx.completion.next_cursor != 1 or service.request.transmissions != 2 or
        service.request_retry_attempts != 1 or service.request.client_timestamp != refresh_client_timestamp)
        return null;

    const first_timeout_tick = refresh_tick + 2;
    const first_timeout = stepNtpServiceAutomatic(device, &service, counter, first_timeout_tick, 0, 0) orelse return null;
    const first_timeout_pending_absent = service.pending_source_index == null;
    const first_timeout_server_preserved = std.meta.eql(service.client.server_ipv4, source_pool.servers[0]);
    if (first_timeout.state != .timed_out or !first_timeout.timeout_reached or
        first_timeout.recovery_state != .waiting or first_timeout.transmit != null or
        !service.request.cancelled or service.request_active or !service.retry_exhausted or
        service.current_source_index != 0 or !first_timeout_pending_absent or
        service.consecutive_source_failures != 1 or !first_timeout_server_preserved or
        service.source_rotations != 0 or service.recovery_deadline_tick != first_timeout_tick + 2)
        return null;

    const first_cooldown = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        first_timeout_tick + 1,
        0,
        0,
    ) orelse return null;
    const first_cooldown_no_tx = first_cooldown.state == .timed_out and
        first_cooldown.recovery_state == .waiting and first_cooldown.transmit == null and
        service.current_source_index == 0 and service.pending_source_index == null and
        service.consecutive_source_failures == 1 and service.source_rotations == 0;
    if (!first_cooldown_no_tx) return null;

    const first_recovery_tick = first_timeout_tick + recovery_policy.cooldown_ticks;
    const expected_first_recovery_timestamp = ntp.projectedTimestampAt(&service.clock, first_recovery_tick) orelse return null;
    const first_recovery = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        first_recovery_tick,
        0,
        0,
    ) orelse return null;
    const first_recovery_tx = first_recovery.transmit orelse return null;
    transmit_identifications[3] = first_recovery_tx.identification;
    transmit_descriptors[3] = first_recovery_tx.completion.descriptor_index;
    transmit_next_cursors[3] = first_recovery_tx.completion.next_cursor;
    const first_recovery_client_timestamp = service.request.client_timestamp;
    const first_recovery_same_source = service.current_source_index == 0 and
        std.meta.eql(service.client.server_ipv4, source_pool.servers[0]);
    const first_recovery_no_rotation = service.source_rotations == 0 and service.pending_source_index == null;
    const first_recovery_failure_preserved = service.consecutive_source_failures == 1;
    const first_recovery_started = first_recovery.state == .awaiting and
        first_recovery.start_reason == .recovery and first_recovery.recovery_state == .ready and
        first_recovery.recovery_started and service.automatic_recoveries == 1;
    if (first_recovery_client_timestamp != expected_first_recovery_timestamp or
        first_recovery_client_timestamp <= refresh_client_timestamp or !first_recovery_same_source or
        !first_recovery_no_rotation or !first_recovery_failure_preserved or !first_recovery_started or
        first_recovery_tx.identification != 86 or first_recovery_tx.completion.descriptor_index != 1 or
        first_recovery_tx.completion.next_cursor != 2)
        return null;

    const first_recovery_retry = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        first_recovery_tick + 1,
        0,
        0,
    ) orelse return null;
    const first_recovery_retry_tx = first_recovery_retry.transmit orelse return null;
    transmit_identifications[4] = first_recovery_retry_tx.identification;
    transmit_descriptors[4] = first_recovery_retry_tx.completion.descriptor_index;
    transmit_next_cursors[4] = first_recovery_retry_tx.completion.next_cursor;
    if (!first_recovery_retry.retried or first_recovery_retry.timeout_reached or
        first_recovery_retry_tx.identification != 87 or
        first_recovery_retry_tx.completion.descriptor_index != 2 or
        first_recovery_retry_tx.completion.next_cursor != 3 or service.request.transmissions != 2 or
        service.request_retry_attempts != 1 or service.request.client_timestamp != first_recovery_client_timestamp)
        return null;

    const second_timeout_tick = first_recovery_tick + 2;
    const second_timeout = stepNtpServiceAutomatic(device, &service, counter, second_timeout_tick, 0, 0) orelse return null;
    const second_timeout_pending_source = service.pending_source_index orelse return null;
    const second_timeout_server_preserved = std.meta.eql(service.client.server_ipv4, source_pool.servers[0]);
    if (second_timeout.state != .timed_out or !second_timeout.timeout_reached or
        second_timeout.recovery_state != .waiting or second_timeout.transmit != null or
        !service.request.cancelled or service.request_active or !service.retry_exhausted or
        service.current_source_index != 0 or second_timeout_pending_source != 1 or
        service.consecutive_source_failures != 2 or !second_timeout_server_preserved or
        service.source_rotations != 0 or service.automatic_recoveries != 1 or
        service.recovery_deadline_tick != second_timeout_tick + 2)
        return null;

    const second_cooldown = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        second_timeout_tick + 1,
        0,
        0,
    ) orelse return null;
    const second_cooldown_no_tx = second_cooldown.state == .timed_out and
        second_cooldown.recovery_state == .waiting and second_cooldown.transmit == null and
        service.current_source_index == 0 and service.pending_source_index == 1 and
        service.consecutive_source_failures == 2 and service.source_rotations == 0;
    if (!second_cooldown_no_tx) return null;

    const second_recovery_tick = second_timeout_tick + recovery_policy.cooldown_ticks;
    const expected_second_recovery_timestamp = ntp.projectedTimestampAt(&service.clock, second_recovery_tick) orelse return null;
    const second_recovery = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        second_recovery_tick,
        0,
        0,
    ) orelse return null;
    const second_recovery_tx = second_recovery.transmit orelse return null;
    transmit_identifications[5] = second_recovery_tx.identification;
    transmit_descriptors[5] = second_recovery_tx.completion.descriptor_index;
    transmit_next_cursors[5] = second_recovery_tx.completion.next_cursor;
    const second_recovery_client_timestamp = service.request.client_timestamp;
    const second_recovery_ready = second_recovery.recovery_state == .ready;
    const second_recovery_started = second_recovery.state == .awaiting and
        second_recovery.start_reason == .recovery and second_recovery.recovery_started and
        service.automatic_recoveries == 2;
    const second_recovery_switched = service.current_source_index == 1 and
        std.meta.eql(service.client.server_ipv4, source_pool.servers[1]);
    const same_socket_preserved = std.meta.eql(service.client.socket, socket);
    const source_state_reset_on_switch = service.pending_source_index == null and
        service.consecutive_source_failures == 0 and service.source_rotations == 1;
    const recovery_timestamps_automatic = first_recovery_client_timestamp == expected_first_recovery_timestamp and
        second_recovery_client_timestamp == expected_second_recovery_timestamp and
        second_recovery_client_timestamp > first_recovery_client_timestamp;
    if (!recovery_timestamps_automatic or !second_recovery_ready or !second_recovery_started or
        !second_recovery_switched or !same_socket_preserved or !source_state_reset_on_switch or
        second_recovery_tx.identification != 88 or second_recovery_tx.completion.descriptor_index != 3 or
        second_recovery_tx.completion.next_cursor != 4)
        return null;

    const peer_after_switch = udpSocketPeer(device, socket) orelse return null;
    if (!std.meta.eql(peer_after_switch.ipv4, source_pool.servers[1]) or
        !std.meta.eql(peer_after_switch.mac, device.gateway_mac) or peer_after_switch.port != ntp.server_port)
        return null;

    const recovered_server_timestamp = ntp.fixture_server_timestamp + (@as(u64, 2) << 32);
    if (!enqueueNtpServiceResponse(
        device,
        socket,
        source_pool.servers[1],
        service.request.client_timestamp,
        recovered_server_timestamp,
        0x8501,
        0xF501,
    )) return null;
    const accepted = stepNtpServiceAutomatic(device, &service, counter, second_recovery_tick, 0, 1) orelse return null;
    const accepted_quality_result = accepted.quality_result orelse return null;
    const accepted_step_result = accepted.step_result orelse return null;
    const accepted_sample_tick = accepted.sample_tick orelse return null;
    const accepted_time = ntp.readProjectedClockAt(&service.clock, accepted_sample_tick) orelse return null;
    if (accepted.state != .idle or accepted_quality_result != .accepted or
        accepted_step_result != .accepted or accepted.apply_result != .accepted or
        accepted_time.seconds != ntp.fixture_unix_seconds + 2 or accepted_time.fraction != 0x80000000 or
        service.recovery_successes != 1 or service.current_source_index != 1 or
        !std.meta.eql(service.client.server_ipv4, source_pool.servers[1]) or
        service.pending_source_index != null or service.consecutive_source_failures != 0 or
        service.source_rotations != 1 or service.retry_exhausted or service.automatic_recoveries != 0)
        return null;

    const health = readNtpServiceHealth(&service, accepted_sample_tick, 1, 100) orelse return null;
    const health_reports_source = health.current_source_index == 1 and
        std.meta.eql(health.current_server_ipv4, source_pool.servers[1]) and health.pending_source_index == null;
    const health_reports_rotation = health.source_rotations == 1 and health.consecutive_source_failures == 0;
    const health_reports_success = health.state == .synchronized and health.current_time != null and
        health.recovery_successes == 1 and !health.retry_exhausted and !health.recovery_exhausted;
    if (!health_reports_source or !health_reports_rotation or !health_reports_success) return null;

    const close_succeeded = closeNtpService(device, &service);
    if (!close_succeeded or service.active or service.client.active or service.request_active) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_202 or
        device.next_udp_generation != 61 or device.next_udp_identification != 89 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 4 or
        device.tx_submissions != submissions_before + 6 or txe != 116 or txd != 116 or rxe != 22 or
        overflow != 0 or device.software_rx_queue.enqueued != 115 or
        device.software_rx_queue.dequeued != 115 or device.packets_dispatched != 104 or
        device.udp_packets_dispatched != 103 or service.quality_accepted != 2 or
        service.quality_rejected != 0 or service.step_accepted != 2 or service.step_rejected != 0 or
        service.requests_started != 4 or service.retries != 2 or service.responses != 2 or
        service.retry_limit_hits != 2 or service.recovery_successes != 1 or
        service.source_rotations != 1)
        return null;

    return .{
        .source_kind = counter.reference.kind,
        .frequency_hz = counter.frequency_hz,
        .counter_bits = counter.counter_bits,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .source_count = source_pool.count,
        .failures_before_rotation = rotation_policy.failures_before_rotation,
        .first_server = source_pool.servers[0],
        .second_server = source_pool.servers[1],
        .transmit_identifications = transmit_identifications,
        .transmit_descriptors = transmit_descriptors,
        .transmit_next_cursors = transmit_next_cursors,
        .refresh_client_timestamp = refresh_client_timestamp,
        .first_recovery_client_timestamp = first_recovery_client_timestamp,
        .second_recovery_client_timestamp = second_recovery_client_timestamp,
        .recovery_timestamps_automatic = recovery_timestamps_automatic,
        .first_timeout_state = first_timeout.state,
        .first_timeout_pending_absent = first_timeout_pending_absent,
        .first_timeout_failure_count = 1,
        .first_timeout_server_preserved = first_timeout_server_preserved,
        .first_recovery_same_source = first_recovery_same_source,
        .first_recovery_no_rotation = first_recovery_no_rotation,
        .first_recovery_failure_preserved = first_recovery_failure_preserved,
        .first_recovery_started = first_recovery_started,
        .second_timeout_state = second_timeout.state,
        .second_timeout_pending_source = second_timeout_pending_source,
        .second_timeout_failure_count = 2,
        .second_timeout_server_preserved = second_timeout_server_preserved,
        .first_cooldown_no_tx = first_cooldown_no_tx,
        .second_cooldown_no_tx = second_cooldown_no_tx,
        .second_recovery_ready = second_recovery_ready,
        .second_recovery_started = second_recovery_started,
        .second_recovery_switched = second_recovery_switched,
        .same_socket_preserved = same_socket_preserved,
        .rotation_count = service.source_rotations,
        .source_state_reset_on_switch = source_state_reset_on_switch,
        .accepted_quality_result = accepted_quality_result,
        .accepted_step_result = accepted_step_result,
        .accepted_sample_tick = accepted_sample_tick,
        .accepted_seconds = accepted_time.seconds,
        .accepted_fraction = accepted_time.fraction,
        .recovery_successes = service.recovery_successes,
        .health_reports_source = health_reports_source,
        .health_reports_rotation = health_reports_rotation,
        .health_reports_success = health_reports_success,
        .quality_accepted = service.quality_accepted,
        .quality_rejected = service.quality_rejected,
        .step_accepted = service.step_accepted,
        .step_rejected = service.step_rejected,
        .requests_started = service.requests_started,
        .retries = service.retries,
        .responses = service.responses,
        .retry_limit_hits = service.retry_limit_hits,
        .close_succeeded = close_succeeded,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .final_generation_cursor = device.next_udp_generation,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpLiveSourceFailover(
    device: *Device,
    counter: *time_reference.ContinuousCounter,
) ?NtpLiveSourceFailoverReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_200 or
        device.next_udp_generation != 59 or device.tx_producer != 2 or
        device.next_udp_identification != 79 or device.next_dns_transaction_id != 8 or
        completionQueueEnqueued(&tx_completion_queue) != 106 or
        completionQueueDequeued(&tx_completion_queue) != 106 or
        completionQueueEnqueued(&rx_completion_queue) != 22 or
        device.software_rx_queue.enqueued != 111 or device.software_rx_queue.dequeued != 111 or
        device.packets_dispatched != 100 or device.udp_packets_dispatched != 99 or
        counter.frequency_hz == 0 or counter.counter_bits == 0)
    {
        return null;
    }

    var source_pool = ntp.SourcePool{
        .count = 2,
        .servers = std.mem.zeroes([ntp.maximum_source_pool_entries][4]u8),
    };
    source_pool.servers[0] = .{ 10, 0, 2, 4 };
    source_pool.servers[1] = .{ 10, 0, 2, 5 };
    const rotation_policy = ntp.SourceRotationPolicy{
        .source_count = 2,
        .failures_before_rotation = 1,
    };
    const retry_policy = ntp.RetryPolicy{
        .initial_interval_ticks = 1,
        .maximum_interval_ticks = 1,
        .maximum_retries = 1,
    };
    const recovery_policy = ntp.RecoveryPolicy{
        .cooldown_ticks = 2,
        .maximum_recoveries = 2,
    };
    var service = openNtpServiceWithSourcePoolPolicies(
        device,
        source_pool,
        rotation_policy,
        2,
        ntp.default_quality_policy,
        ntp.default_quality_rejection_policy,
        .{ .maximum_forward_seconds = 4, .maximum_forward_fraction = 0 },
        ntp.default_step_rejection_policy,
        retry_policy,
        recovery_policy,
    ) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 59 or socket.local_port != 49_200 or
        device.udp_endpoint_count != 3 or device.next_ephemeral_udp_port != 49_201 or
        device.next_udp_generation != 60 or service.current_source_index != 0 or
        service.pending_source_index != null or service.consecutive_source_failures != 0 or
        service.source_rotations != 0 or !std.meta.eql(service.client.server_ipv4, source_pool.servers[0]))
        return null;

    const submissions_before = device.tx_submissions;
    const start_tick = counter.read();
    var transmit_identifications = [4]u16{ 0, 0, 0, 0 };
    var transmit_descriptors = [4]u16{ 0, 0, 0, 0 };
    var transmit_next_cursors = [4]u16{ 0, 0, 0, 0 };

    const initial = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const initial_tx = initial.transmit orelse return null;
    transmit_identifications[0] = initial_tx.identification;
    transmit_descriptors[0] = initial_tx.completion.descriptor_index;
    transmit_next_cursors[0] = initial_tx.completion.next_cursor;
    if (initial.state != .awaiting or initial.start_reason != .initial or
        initial_tx.identification != 79 or initial_tx.completion.descriptor_index != 2 or
        initial_tx.completion.next_cursor != 3)
        return null;

    if (!enqueueNtpServiceResponse(
        device,
        socket,
        source_pool.servers[0],
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        0x8400,
        0xF400,
    )) return null;
    const first_sync = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 1) orelse return null;
    const first_sample_tick = first_sync.sample_tick orelse return null;
    if (first_sync.state != .idle or first_sync.quality_result != .accepted or
        first_sync.step_result != .accepted or first_sync.apply_result != .accepted or
        service.responses != 1 or service.refresh_deadline_tick != first_sample_tick + 2)
        return null;

    const refresh_tick = service.refresh_deadline_tick;
    const expected_refresh_timestamp = ntp.projectedTimestampAt(&service.clock, refresh_tick) orelse return null;
    const refresh = stepNtpServiceAutomatic(device, &service, counter, refresh_tick, 0, 0) orelse return null;
    const refresh_tx = refresh.transmit orelse return null;
    transmit_identifications[1] = refresh_tx.identification;
    transmit_descriptors[1] = refresh_tx.completion.descriptor_index;
    transmit_next_cursors[1] = refresh_tx.completion.next_cursor;
    const refresh_client_timestamp = service.request.client_timestamp;
    if (refresh.state != .awaiting or refresh.start_reason != .refresh or
        refresh_client_timestamp != expected_refresh_timestamp or refresh_tx.identification != 80 or
        refresh_tx.completion.descriptor_index != 3 or refresh_tx.completion.next_cursor != 4 or
        !std.meta.eql(service.client.server_ipv4, source_pool.servers[0]))
        return null;

    const retry = stepNtpServiceAutomatic(device, &service, counter, refresh_tick + 1, 0, 0) orelse return null;
    const retry_tx = retry.transmit orelse return null;
    transmit_identifications[2] = retry_tx.identification;
    transmit_descriptors[2] = retry_tx.completion.descriptor_index;
    transmit_next_cursors[2] = retry_tx.completion.next_cursor;
    if (!retry.retried or retry.timeout_reached or retry_tx.identification != 81 or
        retry_tx.completion.descriptor_index != 4 or retry_tx.completion.next_cursor != 5 or
        service.request.transmissions != 2 or service.request_retry_attempts != 1 or
        service.request.client_timestamp != refresh_client_timestamp)
        return null;

    const timeout_tick = refresh_tick + 2;
    const timeout = stepNtpServiceAutomatic(device, &service, counter, timeout_tick, 0, 0) orelse return null;
    const timeout_transmit_absent = timeout.transmit == null;
    const request_cancelled = service.request.cancelled;
    const timeout_pending_source = service.pending_source_index orelse return null;
    const timeout_server_preserved = std.meta.eql(service.client.server_ipv4, source_pool.servers[0]);
    const recovery_deadline_delta = service.recovery_deadline_tick - timeout_tick;
    if (timeout.state != .timed_out or !timeout.timeout_reached or timeout.recovery_state != .waiting or
        !timeout_transmit_absent or !request_cancelled or service.request_active or
        !service.retry_exhausted or service.current_source_index != 0 or timeout_pending_source != 1 or
        service.consecutive_source_failures != 1 or !timeout_server_preserved or
        service.source_rotations != 0 or recovery_deadline_delta != 2)
        return null;

    const timeout_health = readNtpServiceHealth(&service, timeout_tick, 1, 100) orelse return null;
    if (timeout_health.current_source_index != 0 or timeout_health.pending_source_index != 1 or
        timeout_health.consecutive_source_failures != 1 or
        !std.meta.eql(timeout_health.current_server_ipv4, source_pool.servers[0]))
        return null;

    const cooldown = stepNtpServiceAutomatic(device, &service, counter, timeout_tick + 1, 0, 0) orelse return null;
    const cooldown_no_tx = cooldown.state == .timed_out and cooldown.recovery_state == .waiting and
        cooldown.transmit == null and !cooldown.recovery_started and service.current_source_index == 0 and
        service.pending_source_index == 1 and service.source_rotations == 0;
    if (!cooldown_no_tx) return null;

    const recovery_tick = timeout_tick + recovery_policy.cooldown_ticks;
    const expected_recovery_timestamp = ntp.projectedTimestampAt(&service.clock, recovery_tick) orelse return null;
    const recovery = stepNtpServiceAutomatic(device, &service, counter, recovery_tick, 0, 0) orelse return null;
    const recovery_tx = recovery.transmit orelse return null;
    transmit_identifications[3] = recovery_tx.identification;
    transmit_descriptors[3] = recovery_tx.completion.descriptor_index;
    transmit_next_cursors[3] = recovery_tx.completion.next_cursor;
    const recovery_client_timestamp = service.request.client_timestamp;
    const recovery_timestamp_automatic = recovery_client_timestamp == expected_recovery_timestamp and
        recovery_client_timestamp > refresh_client_timestamp;
    const recovery_ready = recovery.recovery_state == .ready;
    const recovery_started = recovery.state == .awaiting and recovery.start_reason == .recovery and
        recovery.recovery_started and service.automatic_recoveries == 1;
    const source_switched = service.current_source_index == 1 and
        std.meta.eql(service.client.server_ipv4, source_pool.servers[1]);
    const same_socket_preserved = std.meta.eql(service.client.socket, socket);
    const failure_count_reset_on_switch = service.consecutive_source_failures == 0;
    const pending_cleared_on_switch = service.pending_source_index == null;
    if (!recovery_timestamp_automatic or !recovery_ready or !recovery_started or !source_switched or
        !same_socket_preserved or service.source_rotations != 1 or !failure_count_reset_on_switch or
        !pending_cleared_on_switch or recovery_tx.identification != 82 or
        recovery_tx.completion.descriptor_index != 5 or recovery_tx.completion.next_cursor != 6)
        return null;

    const peer_after_switch = udpSocketPeer(device, socket) orelse return null;
    if (!std.meta.eql(peer_after_switch.ipv4, source_pool.servers[1]) or
        !std.meta.eql(peer_after_switch.mac, device.gateway_mac) or peer_after_switch.port != ntp.server_port)
        return null;

    const recovered_server_timestamp = ntp.fixture_server_timestamp + (@as(u64, 2) << 32);
    if (!enqueueNtpServiceResponse(
        device,
        socket,
        source_pool.servers[1],
        service.request.client_timestamp,
        recovered_server_timestamp,
        0x8401,
        0xF401,
    )) return null;
    const accepted = stepNtpServiceAutomatic(device, &service, counter, recovery_tick, 0, 1) orelse return null;
    const accepted_quality_result = accepted.quality_result orelse return null;
    const accepted_step_result = accepted.step_result orelse return null;
    const accepted_sample_tick = accepted.sample_tick orelse return null;
    const accepted_time = ntp.readProjectedClockAt(&service.clock, accepted_sample_tick) orelse return null;
    if (accepted.state != .idle or accepted_quality_result != .accepted or
        accepted_step_result != .accepted or accepted.apply_result != .accepted or
        accepted_time.seconds != ntp.fixture_unix_seconds + 2 or accepted_time.fraction != 0x80000000 or
        service.recovery_successes != 1 or service.current_source_index != 1 or
        !std.meta.eql(service.client.server_ipv4, source_pool.servers[1]) or
        service.pending_source_index != null or service.consecutive_source_failures != 0 or
        service.source_rotations != 1 or service.retry_exhausted or service.automatic_recoveries != 0)
        return null;

    const health = readNtpServiceHealth(&service, accepted_sample_tick, 1, 100) orelse return null;
    const health_reports_source = health.current_source_index == 1 and
        std.meta.eql(health.current_server_ipv4, source_pool.servers[1]) and health.pending_source_index == null;
    const health_reports_rotation = health.source_rotations == 1 and health.consecutive_source_failures == 0;
    const health_reports_success = health.state == .synchronized and health.current_time != null and
        health.recovery_successes == 1 and !health.retry_exhausted and !health.recovery_exhausted;
    if (!health_reports_source or !health_reports_rotation or !health_reports_success) return null;

    const close_succeeded = closeNtpService(device, &service);
    if (!close_succeeded or service.active or service.client.active or service.request_active) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_201 or
        device.next_udp_generation != 60 or device.next_udp_identification != 83 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 6 or
        device.tx_submissions != submissions_before + 4 or txe != 110 or txd != 110 or rxe != 22 or
        overflow != 0 or device.software_rx_queue.enqueued != 113 or
        device.software_rx_queue.dequeued != 113 or device.packets_dispatched != 102 or
        device.udp_packets_dispatched != 101 or service.quality_accepted != 2 or
        service.quality_rejected != 0 or service.step_accepted != 2 or service.step_rejected != 0 or
        service.requests_started != 3 or service.retries != 1 or service.responses != 2 or
        service.retry_limit_hits != 1 or service.recovery_successes != 1 or
        service.source_rotations != 1)
        return null;

    return .{
        .source_kind = counter.reference.kind,
        .frequency_hz = counter.frequency_hz,
        .counter_bits = counter.counter_bits,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .source_count = source_pool.count,
        .failures_before_rotation = rotation_policy.failures_before_rotation,
        .first_server = source_pool.servers[0],
        .second_server = source_pool.servers[1],
        .transmit_identifications = transmit_identifications,
        .transmit_descriptors = transmit_descriptors,
        .transmit_next_cursors = transmit_next_cursors,
        .refresh_client_timestamp = refresh_client_timestamp,
        .recovery_client_timestamp = recovery_client_timestamp,
        .recovery_timestamp_automatic = recovery_timestamp_automatic,
        .timeout_state = timeout.state,
        .timeout_reached = timeout.timeout_reached,
        .timeout_transmit_absent = timeout_transmit_absent,
        .request_cancelled = request_cancelled,
        .timeout_current_source = 0,
        .timeout_pending_source = timeout_pending_source,
        .timeout_failure_count = 1,
        .timeout_server_preserved = timeout_server_preserved,
        .recovery_deadline_delta = recovery_deadline_delta,
        .cooldown_no_tx = cooldown_no_tx,
        .recovery_ready = recovery_ready,
        .recovery_started = recovery_started,
        .source_switched = source_switched,
        .same_socket_preserved = same_socket_preserved,
        .rotation_count = service.source_rotations,
        .failure_count_reset_on_switch = failure_count_reset_on_switch,
        .pending_cleared_on_switch = pending_cleared_on_switch,
        .accepted_quality_result = accepted_quality_result,
        .accepted_step_result = accepted_step_result,
        .accepted_sample_tick = accepted_sample_tick,
        .accepted_seconds = accepted_time.seconds,
        .accepted_fraction = accepted_time.fraction,
        .recovery_successes = service.recovery_successes,
        .health_reports_source = health_reports_source,
        .health_reports_rotation = health_reports_rotation,
        .health_reports_success = health_reports_success,
        .quality_accepted = service.quality_accepted,
        .quality_rejected = service.quality_rejected,
        .step_accepted = service.step_accepted,
        .step_rejected = service.step_rejected,
        .requests_started = service.requests_started,
        .retries = service.retries,
        .responses = service.responses,
        .retry_limit_hits = service.retry_limit_hits,
        .close_succeeded = close_succeeded,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .final_generation_cursor = device.next_udp_generation,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpServiceSourcePool(device: *Device) ?NtpServiceSourcePoolReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_199 or
        device.next_udp_generation != 58 or device.tx_producer != 2 or
        device.next_udp_identification != 79 or device.next_dns_transaction_id != 8 or
        completionQueueEnqueued(&tx_completion_queue) != 106 or
        completionQueueDequeued(&tx_completion_queue) != 106 or
        completionQueueEnqueued(&rx_completion_queue) != 22 or
        device.software_rx_queue.enqueued != 111 or device.software_rx_queue.dequeued != 111 or
        device.packets_dispatched != 100 or device.udp_packets_dispatched != 99)
    {
        return null;
    }

    var valid_pool = ntp.SourcePool{
        .count = 2,
        .servers = std.mem.zeroes([ntp.maximum_source_pool_entries][4]u8),
    };
    valid_pool.servers[0] = .{ 10, 0, 2, 4 };
    valid_pool.servers[1] = .{ 10, 0, 2, 5 };
    const rotation_policy = ntp.SourceRotationPolicy{
        .source_count = 2,
        .failures_before_rotation = 2,
    };
    const retry_policy = ntp.RetryPolicy{
        .initial_interval_ticks = 4,
        .maximum_interval_ticks = 4,
        .maximum_retries = 2,
    };

    const endpoints_before_invalid = device.udp_endpoint_count;
    const port_before_invalid = device.next_ephemeral_udp_port;
    const generation_before_invalid = device.next_udp_generation;
    const id_before_invalid = device.next_udp_identification;
    const tx_before_invalid = device.tx_producer;
    const submissions_before_invalid = device.tx_submissions;

    var invalid_pool = valid_pool;
    invalid_pool.count = 1;
    const invalid_pool_rejected = openNtpServiceWithSourcePoolPolicies(
        device,
        invalid_pool,
        .{ .source_count = 1, .failures_before_rotation = 2 },
        20,
        ntp.default_quality_policy,
        ntp.default_quality_rejection_policy,
        ntp.default_clock_step_policy,
        ntp.default_step_rejection_policy,
        retry_policy,
        null,
    ) == null;
    const invalid_pool_state_preserved = device.udp_endpoint_count == endpoints_before_invalid and
        device.next_ephemeral_udp_port == port_before_invalid and
        device.next_udp_generation == generation_before_invalid and
        device.next_udp_identification == id_before_invalid and
        device.tx_producer == tx_before_invalid and device.tx_submissions == submissions_before_invalid;
    if (!invalid_pool_rejected or !invalid_pool_state_preserved) return null;

    const mismatched_policy_rejected = openNtpServiceWithSourcePoolPolicies(
        device,
        valid_pool,
        .{ .source_count = 3, .failures_before_rotation = 2 },
        20,
        ntp.default_quality_policy,
        ntp.default_quality_rejection_policy,
        ntp.default_clock_step_policy,
        ntp.default_step_rejection_policy,
        retry_policy,
        null,
    ) == null;
    const mismatched_policy_state_preserved = device.udp_endpoint_count == endpoints_before_invalid and
        device.next_ephemeral_udp_port == port_before_invalid and
        device.next_udp_generation == generation_before_invalid and
        device.next_udp_identification == id_before_invalid and
        device.tx_producer == tx_before_invalid and device.tx_submissions == submissions_before_invalid;
    if (!mismatched_policy_rejected or !mismatched_policy_state_preserved) return null;

    var service = openNtpServiceWithSourcePoolPolicies(
        device,
        valid_pool,
        rotation_policy,
        20,
        ntp.default_quality_policy,
        ntp.default_quality_rejection_policy,
        ntp.default_clock_step_policy,
        ntp.default_step_rejection_policy,
        retry_policy,
        null,
    ) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 58 or socket.local_port != 49_199 or
        device.udp_endpoint_count != 3 or device.next_ephemeral_udp_port != 49_200 or
        device.next_udp_generation != 59)
        return null;

    const peer = udpSocketPeer(device, socket) orelse return null;
    const client_server_matches_first = std.meta.eql(service.client.server_ipv4, valid_pool.servers[0]);
    const peer_matches_first = std.meta.eql(peer.ipv4, valid_pool.servers[0]) and
        std.meta.eql(peer.mac, device.gateway_mac) and peer.port == ntp.server_port;
    const source_state_initialized = service.source_pool != null and
        std.meta.eql(service.source_pool.?, valid_pool) and service.source_rotation_policy != null and
        std.meta.eql(service.source_rotation_policy.?, rotation_policy) and
        service.current_source_index == 0 and service.consecutive_source_failures == 0 and
        service.source_rotations == 0;
    if (!client_server_matches_first or !peer_matches_first or !source_state_initialized) return null;

    service.consecutive_source_failures = 1;
    service.source_rotations = 3;
    const health = readNtpServiceHealth(&service, 0, 1, 2) orelse return null;
    const health_reports_pool = health.source_pool != null and std.meta.eql(health.source_pool.?, valid_pool);
    const health_reports_policy = health.source_rotation_policy != null and
        std.meta.eql(health.source_rotation_policy.?, rotation_policy);
    const health_reports_current_source = health.state == .unsynchronized and
        health.current_source_index == 0 and std.meta.eql(health.current_server_ipv4, valid_pool.servers[0]);
    const health_reports_failure_count = health.consecutive_source_failures == 1;
    const health_reports_rotations = health.source_rotations == 3;
    if (!health_reports_pool or !health_reports_policy or !health_reports_current_source or
        !health_reports_failure_count or !health_reports_rotations)
        return null;

    const close_succeeded = closeNtpService(device, &service);
    if (!close_succeeded or service.active or service.client.active or service.request_active) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const no_packet_traffic = device.next_udp_identification == 79 and device.tx_producer == 2 and
        device.tx_submissions == submissions_before_invalid and txe == 106 and txd == 106 and rxe == 22 and
        device.software_rx_queue.enqueued == 111 and device.software_rx_queue.dequeued == 111 and
        device.packets_dispatched == 100 and device.udp_packets_dispatched == 99;
    if (!no_packet_traffic or device.udp_endpoint_count != 2 or
        device.next_ephemeral_udp_port != 49_200 or device.next_udp_generation != 59)
        return null;

    return .{
        .invalid_pool_rejected = invalid_pool_rejected,
        .invalid_pool_state_preserved = invalid_pool_state_preserved,
        .mismatched_policy_rejected = mismatched_policy_rejected,
        .mismatched_policy_state_preserved = mismatched_policy_state_preserved,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .pool_count = valid_pool.count,
        .rotation_threshold = rotation_policy.failures_before_rotation,
        .first_server = valid_pool.servers[0],
        .second_server = valid_pool.servers[1],
        .client_server_matches_first = client_server_matches_first,
        .peer_matches_first = peer_matches_first,
        .source_state_initialized = source_state_initialized,
        .health_reports_pool = health_reports_pool,
        .health_reports_policy = health_reports_policy,
        .health_reports_current_source = health_reports_current_source,
        .health_reports_failure_count = health_reports_failure_count,
        .health_reports_rotations = health_reports_rotations,
        .close_succeeded = close_succeeded,
        .no_packet_traffic = no_packet_traffic,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .final_generation_cursor = device.next_udp_generation,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpClientServerSwitch(device: *Device) ?NtpClientServerSwitchReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_198 or
        device.next_udp_generation != 57 or device.tx_producer != 2 or
        device.next_udp_identification != 79 or device.next_dns_transaction_id != 8 or
        completionQueueEnqueued(&tx_completion_queue) != 106 or
        completionQueueDequeued(&tx_completion_queue) != 106 or
        completionQueueEnqueued(&rx_completion_queue) != 22 or
        device.software_rx_queue.enqueued != 111 or device.software_rx_queue.dequeued != 111 or
        device.packets_dispatched != 100 or device.udp_packets_dispatched != 99)
    {
        return null;
    }

    const original_server = [4]u8{ 10, 0, 2, 4 };
    const alternate_server = [4]u8{ 10, 0, 2, 5 };
    var client = openNtpClient(device, original_server) orelse return null;
    const socket = client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 57 or socket.local_port != 49_198 or
        device.udp_endpoint_count != 3 or device.next_ephemeral_udp_port != 49_199 or
        device.next_udp_generation != 58)
        return null;

    const initial_peer = udpSocketPeer(device, socket) orelse return null;
    if (!std.meta.eql(initial_peer.ipv4, original_server) or
        !std.meta.eql(initial_peer.mac, device.gateway_mac) or initial_peer.port != ntp.server_port)
        return null;

    const client_before_invalid = client;
    const peer_before_invalid = initial_peer;
    const endpoints_before_invalid = device.udp_endpoint_count;
    const port_before_invalid = device.next_ephemeral_udp_port;
    const generation_before_invalid = device.next_udp_generation;
    const identification_before_invalid = device.next_udp_identification;
    const tx_before_invalid = device.tx_producer;
    const submissions_before_invalid = device.tx_submissions;
    const invalid_rejected = !switchNtpClientServer(device, &client, .{ 0, 0, 0, 0 });
    const peer_after_invalid = udpSocketPeer(device, socket) orelse return null;
    const invalid_state_preserved = std.meta.eql(client, client_before_invalid) and
        std.meta.eql(peer_after_invalid, peer_before_invalid) and
        device.udp_endpoint_count == endpoints_before_invalid and
        device.next_ephemeral_udp_port == port_before_invalid and
        device.next_udp_generation == generation_before_invalid and
        device.next_udp_identification == identification_before_invalid and
        device.tx_producer == tx_before_invalid and device.tx_submissions == submissions_before_invalid;
    if (!invalid_rejected or !invalid_state_preserved) return null;

    const client_before_idempotent = client;
    const peer_before_idempotent = peer_after_invalid;
    const idempotent_succeeded = switchNtpClientServer(device, &client, original_server);
    const peer_after_idempotent = udpSocketPeer(device, socket) orelse return null;
    const idempotent_state_preserved = std.meta.eql(client, client_before_idempotent) and
        std.meta.eql(peer_after_idempotent, peer_before_idempotent);
    if (!idempotent_succeeded or !idempotent_state_preserved) return null;

    const forward_succeeded = switchNtpClientServer(device, &client, alternate_server);
    const forward_peer = udpSocketPeer(device, socket) orelse return null;
    const forward_peer_updated = std.meta.eql(client.server_ipv4, alternate_server) and
        std.meta.eql(forward_peer.ipv4, alternate_server) and
        std.meta.eql(forward_peer.mac, device.gateway_mac) and forward_peer.port == ntp.server_port;
    if (!forward_succeeded or !forward_peer_updated) return null;

    const reverse_succeeded = switchNtpClientServer(device, &client, original_server);
    const reverse_peer = udpSocketPeer(device, socket) orelse return null;
    const reverse_peer_restored = std.meta.eql(client.server_ipv4, original_server) and
        std.meta.eql(reverse_peer, initial_peer);
    const socket_preserved = std.meta.eql(client.socket, socket) and
        socket.endpoint_index == 2 and socket.generation == 57 and socket.local_port == 49_198;
    const gateway_mac_preserved = std.meta.eql(reverse_peer.mac, device.gateway_mac);
    if (!reverse_succeeded or !reverse_peer_restored or !socket_preserved or !gateway_mac_preserved)
        return null;

    var stale_client = client;
    const close_succeeded = closeNtpClient(device, &client);
    if (!close_succeeded or client.active or udpSocketActive(device, socket)) return null;

    const inactive_before = client;
    const state_before_inactive = .{
        device.udp_endpoint_count,
        device.next_ephemeral_udp_port,
        device.next_udp_generation,
        device.next_udp_identification,
        device.tx_producer,
        device.tx_submissions,
    };
    const inactive_rejected = !switchNtpClientServer(device, &client, alternate_server);
    const inactive_state_preserved = std.meta.eql(client, inactive_before) and
        device.udp_endpoint_count == state_before_inactive[0] and
        device.next_ephemeral_udp_port == state_before_inactive[1] and
        device.next_udp_generation == state_before_inactive[2] and
        device.next_udp_identification == state_before_inactive[3] and
        device.tx_producer == state_before_inactive[4] and
        device.tx_submissions == state_before_inactive[5];
    if (!inactive_rejected or !inactive_state_preserved) return null;

    const stale_before = stale_client;
    const stale_rejected = !switchNtpClientServer(device, &stale_client, alternate_server);
    const stale_state_preserved = std.meta.eql(stale_client, stale_before) and
        device.udp_endpoint_count == state_before_inactive[0] and
        device.next_ephemeral_udp_port == state_before_inactive[1] and
        device.next_udp_generation == state_before_inactive[2] and
        device.next_udp_identification == state_before_inactive[3] and
        device.tx_producer == state_before_inactive[4] and
        device.tx_submissions == state_before_inactive[5];
    if (!stale_rejected or !stale_state_preserved) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const no_packet_traffic = device.next_udp_identification == 79 and device.tx_producer == 2 and
        device.tx_submissions == submissions_before_invalid and txe == 106 and txd == 106 and rxe == 22 and
        device.software_rx_queue.enqueued == 111 and device.software_rx_queue.dequeued == 111 and
        device.packets_dispatched == 100 and device.udp_packets_dispatched == 99;
    if (!no_packet_traffic or device.udp_endpoint_count != 2 or
        device.next_ephemeral_udp_port != 49_199 or device.next_udp_generation != 58)
        return null;

    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .original_server = original_server,
        .alternate_server = alternate_server,
        .invalid_rejected = invalid_rejected,
        .invalid_state_preserved = invalid_state_preserved,
        .idempotent_succeeded = idempotent_succeeded,
        .idempotent_state_preserved = idempotent_state_preserved,
        .forward_succeeded = forward_succeeded,
        .forward_peer_updated = forward_peer_updated,
        .reverse_succeeded = reverse_succeeded,
        .reverse_peer_restored = reverse_peer_restored,
        .socket_preserved = socket_preserved,
        .gateway_mac_preserved = gateway_mac_preserved,
        .peer_port = reverse_peer.port,
        .close_succeeded = close_succeeded,
        .inactive_rejected = inactive_rejected,
        .inactive_state_preserved = inactive_state_preserved,
        .stale_rejected = stale_rejected,
        .stale_state_preserved = stale_state_preserved,
        .no_packet_traffic = no_packet_traffic,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .final_generation_cursor = device.next_udp_generation,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpQualityRecovery(
    device: *Device,
    counter: *time_reference.ContinuousCounter,
) ?NtpQualityRecoveryReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_197 or
        device.next_udp_generation != 56 or device.tx_producer != 6 or
        device.next_udp_identification != 75 or device.next_dns_transaction_id != 8 or
        completionQueueEnqueued(&tx_completion_queue) != 102 or
        completionQueueDequeued(&tx_completion_queue) != 102 or
        completionQueueEnqueued(&rx_completion_queue) != 22 or
        device.software_rx_queue.enqueued != 107 or device.software_rx_queue.dequeued != 107 or
        device.packets_dispatched != 96 or device.udp_packets_dispatched != 95 or
        counter.frequency_hz == 0 or counter.counter_bits == 0)
    {
        return null;
    }

    const server = [4]u8{ 10, 0, 2, 4 };
    const quality_rejection_policy = ntp.QualityRejectionPolicy{ .maximum_rejections_per_request = 1 };
    const retry_policy = ntp.RetryPolicy{
        .initial_interval_ticks = 1,
        .maximum_interval_ticks = 1,
        .maximum_retries = 1,
    };
    const recovery_policy = ntp.RecoveryPolicy{
        .cooldown_ticks = 2,
        .maximum_recoveries = 2,
    };
    var service = openNtpServiceWithResponseRejectionPolicies(
        device,
        server,
        2,
        ntp.default_quality_policy,
        quality_rejection_policy,
        .{ .maximum_forward_seconds = 4, .maximum_forward_fraction = 0 },
        ntp.default_step_rejection_policy,
        retry_policy,
        recovery_policy,
    ) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 56 or socket.local_port != 49_197 or
        device.next_ephemeral_udp_port != 49_198 or device.next_udp_generation != 57 or
        device.udp_endpoint_count != 3)
        return null;

    const submissions_before = device.tx_submissions;
    const start_tick = counter.read();
    var transmit_identifications = [4]u16{ 0, 0, 0, 0 };
    var transmit_descriptors = [4]u16{ 0, 0, 0, 0 };
    var transmit_next_cursors = [4]u16{ 0, 0, 0, 0 };

    const initial = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const initial_tx = initial.transmit orelse return null;
    transmit_identifications[0] = initial_tx.identification;
    transmit_descriptors[0] = initial_tx.completion.descriptor_index;
    transmit_next_cursors[0] = initial_tx.completion.next_cursor;
    if (initial.state != .awaiting or initial.start_reason != .initial or
        initial_tx.identification != 75 or initial_tx.completion.descriptor_index != 6 or
        initial_tx.completion.next_cursor != 7)
        return null;

    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        0x8300,
        0xF300,
    )) return null;
    const first_sync = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 1) orelse return null;
    const first_sample_tick = first_sync.sample_tick orelse return null;
    if (first_sync.state != .idle or first_sync.quality_result != .accepted or
        first_sync.step_result != .accepted or first_sync.apply_result != .accepted or
        service.responses != 1 or service.refresh_deadline_tick != first_sample_tick + 2)
        return null;

    const refresh_tick = service.refresh_deadline_tick;
    const expected_refresh_timestamp = ntp.projectedTimestampAt(&service.clock, refresh_tick) orelse return null;
    const refresh = stepNtpServiceAutomatic(device, &service, counter, refresh_tick, 0, 0) orelse return null;
    const refresh_tx = refresh.transmit orelse return null;
    transmit_identifications[1] = refresh_tx.identification;
    transmit_descriptors[1] = refresh_tx.completion.descriptor_index;
    transmit_next_cursors[1] = refresh_tx.completion.next_cursor;
    const refresh_client_timestamp = service.request.client_timestamp;
    if (refresh.state != .awaiting or refresh.start_reason != .refresh or
        refresh_client_timestamp != expected_refresh_timestamp or refresh_tx.identification != 76 or
        refresh_tx.completion.descriptor_index != 7 or refresh_tx.completion.next_cursor != 0)
        return null;

    const clock_before_first_rejection = service.clock;
    if (!enqueueNtpServiceResponseWithQuality(
        device,
        socket,
        server,
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        2,
        ntp.default_quality_policy.max_root_delay,
        ntp.default_quality_policy.max_root_dispersion + 1,
        0x8301,
        0xF301,
    )) return null;
    const first_rejection = stepNtpServiceAutomatic(device, &service, counter, refresh_tick, 0, 1) orelse return null;
    const first_quality_result = first_rejection.quality_result orelse return null;
    const first_quality_action = first_rejection.quality_rejection_action orelse return null;
    const first_sample_absent = first_rejection.sample_tick == null;
    const first_apply_absent = first_rejection.apply_result == null;
    const first_clock_preserved = std.meta.eql(service.clock, clock_before_first_rejection);
    const forced_retry_tx = first_rejection.transmit orelse return null;
    transmit_identifications[2] = forced_retry_tx.identification;
    transmit_descriptors[2] = forced_retry_tx.completion.descriptor_index;
    transmit_next_cursors[2] = forced_retry_tx.completion.next_cursor;
    const first_retry_timestamp_preserved = service.request.client_timestamp == refresh_client_timestamp;
    const first_retry_transmissions = service.request.transmissions;
    if (first_quality_result != .root_dispersion or first_quality_action != .retry_now or
        first_rejection.quality_rejection_count != 1 or first_rejection.quality_rejections_remaining != 0 or
        !first_sample_absent or !first_apply_absent or !first_clock_preserved or
        !first_rejection.retried or first_rejection.timeout_reached or forced_retry_tx.identification != 77 or
        forced_retry_tx.completion.descriptor_index != 0 or forced_retry_tx.completion.next_cursor != 1 or
        !first_retry_timestamp_preserved or first_retry_transmissions != 2 or
        service.request_retry_attempts != 1 or service.request_quality_rejections != 0 or
        service.quality_forced_retries != 1)
        return null;

    const clock_before_timeout = service.clock;
    if (!enqueueNtpServiceResponseWithQuality(
        device,
        socket,
        server,
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        ntp.default_quality_policy.max_stratum + 1,
        ntp.default_quality_policy.max_root_delay,
        ntp.default_quality_policy.max_root_dispersion,
        0x8302,
        0xF302,
    )) return null;
    const timeout_tick = refresh_tick + 1;
    const timeout = stepNtpServiceAutomatic(device, &service, counter, timeout_tick, 0, 1) orelse return null;
    const second_quality_result = timeout.quality_result orelse return null;
    const second_quality_action = timeout.quality_rejection_action orelse return null;
    const second_sample_absent = timeout.sample_tick == null;
    const second_apply_absent = timeout.apply_result == null;
    const second_clock_preserved = std.meta.eql(service.clock, clock_before_timeout);
    const timeout_waiting = timeout.recovery_state == .waiting;
    const timeout_transmit_absent = timeout.transmit == null;
    const request_cancelled = service.request.cancelled;
    const recovery_deadline_delta = service.recovery_deadline_tick - timeout_tick;
    if (second_quality_result != .stratum or second_quality_action != .retry_now or
        timeout.quality_rejection_count != 1 or timeout.quality_rejections_remaining != 0 or
        !second_sample_absent or !second_apply_absent or !second_clock_preserved or
        timeout.state != .timed_out or !timeout.timeout_reached or !timeout_waiting or
        !timeout_transmit_absent or !request_cancelled or service.request_active or
        !service.retry_exhausted or service.retry_limit_hits != 1 or recovery_deadline_delta != 2 or
        service.automatic_recoveries != 0 or service.recovery_exhausted)
        return null;

    const timeout_health = readNtpServiceHealth(&service, timeout_tick, 1, 100) orelse return null;
    const timeout_health_time = timeout_health.current_time orelse return null;
    const timeout_health_timestamp = ntp.unixTimeToTimestamp(timeout_health_time) orelse return null;
    const cooldown_tick = timeout_tick + 1;
    const cooldown = stepNtpServiceAutomatic(device, &service, counter, cooldown_tick, 0, 0) orelse return null;
    const cooldown_no_tx = cooldown.state == .timed_out and cooldown.recovery_state == .waiting and
        cooldown.transmit == null and !cooldown.recovery_started;
    if (!cooldown_no_tx) return null;
    const cooldown_health = readNtpServiceHealth(&service, cooldown_tick, 1, 100) orelse return null;
    const cooldown_health_time = cooldown_health.current_time orelse return null;
    const cooldown_health_timestamp = ntp.unixTimeToTimestamp(cooldown_health_time) orelse return null;
    const holdover_advanced = cooldown_health_timestamp > timeout_health_timestamp;
    const holdover_visible = timeout_health.state == .holdover and cooldown_health.state == .holdover and
        timeout_health_timestamp > refresh_client_timestamp and holdover_advanced;
    if (!holdover_visible) return null;

    const recovery_tick = timeout_tick + recovery_policy.cooldown_ticks;
    const expected_recovery_timestamp = ntp.projectedTimestampAt(&service.clock, recovery_tick) orelse return null;
    const recovery = stepNtpServiceAutomatic(device, &service, counter, recovery_tick, 0, 0) orelse return null;
    const recovery_tx = recovery.transmit orelse return null;
    transmit_identifications[3] = recovery_tx.identification;
    transmit_descriptors[3] = recovery_tx.completion.descriptor_index;
    transmit_next_cursors[3] = recovery_tx.completion.next_cursor;
    const recovery_client_timestamp = service.request.client_timestamp;
    const recovery_timestamp_automatic = recovery_client_timestamp == expected_recovery_timestamp and
        recovery_client_timestamp > cooldown_health_timestamp;
    const recovery_ready = recovery.recovery_state == .ready;
    const recovery_started = recovery.state == .awaiting and recovery.start_reason == .recovery and
        recovery.recovery_started and service.automatic_recoveries == 1;
    if (!recovery_timestamp_automatic or !recovery_ready or !recovery_started or
        recovery_tx.identification != 78 or recovery_tx.completion.descriptor_index != 1 or
        recovery_tx.completion.next_cursor != 2 or service.request_retry_attempts != 0 or
        service.request_quality_rejections != 0 or service.request_step_rejections != 0 or
        service.retry_exhausted)
        return null;

    const recovered_server_timestamp = ntp.fixture_server_timestamp + (@as(u64, 2) << 32);
    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        recovered_server_timestamp,
        0x8303,
        0xF303,
    )) return null;
    const recovered = stepNtpServiceAutomatic(device, &service, counter, recovery_tick, 0, 1) orelse return null;
    const accepted_quality_result = recovered.quality_result orelse return null;
    const accepted_step_result = recovered.step_result orelse return null;
    const accepted_sample_tick = recovered.sample_tick orelse return null;
    const accepted_time = ntp.readProjectedClockAt(&service.clock, accepted_sample_tick) orelse return null;
    const accepted_timestamp = ntp.unixTimeToTimestamp(accepted_time) orelse return null;
    const recovery_budget_reset = service.automatic_recoveries == 0 and !service.recovery_exhausted and
        service.recovery_deadline_tick == 0;
    const retry_budget_reset = service.request_retry_attempts == 0 and !service.retry_exhausted;
    const quality_budget_reset = service.request_quality_rejections == 0;
    const step_budget_reset = service.request_step_rejections == 0;
    const clock_advanced = accepted_timestamp > cooldown_health_timestamp;
    const health_after_success = readNtpServiceHealth(&service, accepted_sample_tick, 1, 100) orelse return null;
    const health_reports_success = health_after_success.state == .synchronized and
        health_after_success.current_time != null and health_after_success.recovery_successes == 1 and
        health_after_success.automatic_recoveries == 0 and !health_after_success.retry_exhausted and
        !health_after_success.recovery_exhausted and health_after_success.request_quality_rejections == 0 and
        health_after_success.request_step_rejections == 0 and health_after_success.quality_forced_retries == 1;
    if (recovered.state != .idle or accepted_quality_result != .accepted or accepted_step_result != .accepted or
        recovered.apply_result != .accepted or accepted_time.seconds != ntp.fixture_unix_seconds + 2 or
        accepted_time.fraction != 0x80000000 or service.recovery_successes != 1 or
        !recovery_budget_reset or !retry_budget_reset or !quality_budget_reset or !step_budget_reset or
        !clock_advanced or !health_reports_success)
        return null;

    const close_succeeded = closeNtpService(device, &service);
    if (!close_succeeded or service.active or service.client.active or service.request_active) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_198 or
        device.next_udp_generation != 57 or device.next_udp_identification != 79 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 2 or
        device.tx_submissions != submissions_before + 4 or txe != 106 or txd != 106 or rxe != 22 or
        overflow != 0 or device.software_rx_queue.enqueued != 111 or
        device.software_rx_queue.dequeued != 111 or device.packets_dispatched != 100 or
        device.udp_packets_dispatched != 99 or service.quality_accepted != 2 or
        service.quality_rejected != 2 or service.quality_stratum_rejected != 1 or
        service.quality_root_dispersion_rejected != 1 or service.quality_forced_retries != 1 or
        service.step_accepted != 2 or service.step_rejected != 0 or service.requests_started != 3 or
        service.retries != 1 or service.responses != 2 or service.retry_limit_hits != 1 or
        service.recovery_successes != 1 or service.automatic_recoveries != 0 or
        service.recovery_limit_hits != 0)
        return null;

    return .{
        .source_kind = counter.reference.kind,
        .frequency_hz = counter.frequency_hz,
        .counter_bits = counter.counter_bits,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .maximum_quality_rejections = quality_rejection_policy.maximum_rejections_per_request,
        .maximum_retries = retry_policy.maximum_retries,
        .recovery_cooldown_ticks = recovery_policy.cooldown_ticks,
        .maximum_recoveries = recovery_policy.maximum_recoveries,
        .transmit_identifications = transmit_identifications,
        .transmit_descriptors = transmit_descriptors,
        .transmit_next_cursors = transmit_next_cursors,
        .refresh_client_timestamp = refresh_client_timestamp,
        .recovery_client_timestamp = recovery_client_timestamp,
        .recovery_timestamp_automatic = recovery_timestamp_automatic,
        .first_quality_result = first_quality_result,
        .first_quality_action = first_quality_action,
        .first_sample_absent = first_sample_absent,
        .first_apply_absent = first_apply_absent,
        .first_clock_preserved = first_clock_preserved,
        .first_retry_timestamp_preserved = first_retry_timestamp_preserved,
        .first_retry_transmissions = first_retry_transmissions,
        .second_quality_result = second_quality_result,
        .second_quality_action = second_quality_action,
        .second_sample_absent = second_sample_absent,
        .second_apply_absent = second_apply_absent,
        .second_clock_preserved = second_clock_preserved,
        .timeout_state = timeout.state,
        .timeout_waiting = timeout_waiting,
        .timeout_transmit_absent = timeout_transmit_absent,
        .request_cancelled = request_cancelled,
        .retry_exhausted = service.retry_limit_hits == 1,
        .recovery_deadline_delta = recovery_deadline_delta,
        .timeout_health_state = timeout_health.state,
        .timeout_health_timestamp = timeout_health_timestamp,
        .cooldown_health_state = cooldown_health.state,
        .cooldown_health_timestamp = cooldown_health_timestamp,
        .holdover_visible = holdover_visible,
        .holdover_advanced = holdover_advanced,
        .cooldown_no_tx = cooldown_no_tx,
        .recovery_ready = recovery_ready,
        .recovery_started = recovery_started,
        .accepted_quality_result = accepted_quality_result,
        .accepted_step_result = accepted_step_result,
        .accepted_sample_tick = accepted_sample_tick,
        .accepted_seconds = accepted_time.seconds,
        .accepted_fraction = accepted_time.fraction,
        .recovery_successes = service.recovery_successes,
        .recovery_budget_reset = recovery_budget_reset,
        .retry_budget_reset = retry_budget_reset,
        .quality_budget_reset = quality_budget_reset,
        .step_budget_reset = step_budget_reset,
        .clock_advanced = clock_advanced,
        .health_reports_success = health_reports_success,
        .quality_accepted = service.quality_accepted,
        .quality_rejected = service.quality_rejected,
        .quality_stratum_rejected = service.quality_stratum_rejected,
        .quality_root_dispersion_rejected = service.quality_root_dispersion_rejected,
        .quality_forced_retries = service.quality_forced_retries,
        .step_accepted = service.step_accepted,
        .step_rejected = service.step_rejected,
        .requests_started = service.requests_started,
        .retries = service.retries,
        .responses = service.responses,
        .retry_limit_hits = service.retry_limit_hits,
        .close_succeeded = close_succeeded,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpQualityRejectionExhaustion(
    device: *Device,
    counter: *time_reference.ContinuousCounter,
) ?NtpQualityRejectionExhaustionReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_196 or
        device.next_udp_generation != 55 or device.tx_producer != 3 or
        device.next_udp_identification != 72 or device.next_dns_transaction_id != 8 or
        completionQueueEnqueued(&tx_completion_queue) != 99 or
        completionQueueDequeued(&tx_completion_queue) != 99 or
        completionQueueEnqueued(&rx_completion_queue) != 22 or
        device.software_rx_queue.enqueued != 105 or device.software_rx_queue.dequeued != 105 or
        device.packets_dispatched != 94 or device.udp_packets_dispatched != 93 or
        counter.frequency_hz == 0 or counter.counter_bits == 0)
    {
        return null;
    }

    const server = [4]u8{ 10, 0, 2, 4 };
    const quality_rejection_policy = ntp.QualityRejectionPolicy{ .maximum_rejections_per_request = 1 };
    const retry_policy = ntp.RetryPolicy{
        .initial_interval_ticks = 1,
        .maximum_interval_ticks = 1,
        .maximum_retries = 1,
    };
    var service = openNtpServiceWithResponseRejectionPolicies(
        device,
        server,
        20,
        ntp.default_quality_policy,
        quality_rejection_policy,
        ntp.default_clock_step_policy,
        ntp.default_step_rejection_policy,
        retry_policy,
        null,
    ) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 55 or socket.local_port != 49_196 or
        device.next_ephemeral_udp_port != 49_197 or device.next_udp_generation != 56 or
        device.udp_endpoint_count != 3)
        return null;

    const submissions_before = device.tx_submissions;
    const start_tick = counter.read();
    const initial = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const initial_tx = initial.transmit orelse return null;
    const client_timestamp = service.request.client_timestamp;
    if (initial.state != .awaiting or initial.start_reason != .initial or
        initial_tx.identification != 72 or initial_tx.completion.descriptor_index != 3 or
        initial_tx.completion.next_cursor != 4 or service.retry_deadline_tick != start_tick + 1)
        return null;

    const initial_clock = service.clock;
    if (!enqueueNtpServiceResponseWithQuality(
        device,
        socket,
        server,
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        2,
        ntp.default_quality_policy.max_root_delay,
        ntp.default_quality_policy.max_root_dispersion + 1,
        0x8200,
        0xF200,
    )) return null;
    const first = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 1) orelse return null;
    const first_quality_result = first.quality_result orelse return null;
    const first_action = first.quality_rejection_action orelse return null;
    const first_sample_absent = first.sample_tick == null;
    const first_apply_absent = first.apply_result == null;
    const first_clock_preserved = std.meta.eql(service.clock, initial_clock);
    const forced_retry = first.transmit orelse return null;
    const forced_retry_timestamp_preserved = service.request.client_timestamp == client_timestamp;
    const forced_retry_transmissions = service.request.transmissions;
    if (first_quality_result != .root_dispersion or first_action != .retry_now or
        first.quality_rejection_count != 1 or first.quality_rejections_remaining != 0 or
        !first_sample_absent or !first_apply_absent or !first_clock_preserved or
        !first.retried or first.timeout_reached or forced_retry.identification != 73 or
        forced_retry.completion.descriptor_index != 4 or forced_retry.completion.next_cursor != 5 or
        !forced_retry_timestamp_preserved or service.request.transmissions != 2 or
        service.request_retry_attempts != 1 or service.request_quality_rejections != 0 or
        service.quality_forced_retries != 1 or service.retries != 1)
        return null;

    if (!enqueueNtpServiceResponseWithQuality(
        device,
        socket,
        server,
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        ntp.default_quality_policy.max_stratum + 1,
        ntp.default_quality_policy.max_root_delay,
        ntp.default_quality_policy.max_root_dispersion,
        0x8201,
        0xF201,
    )) return null;
    const clock_before_second = service.clock;
    const second = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 1) orelse return null;
    const second_quality_result = second.quality_result orelse return null;
    const second_action = second.quality_rejection_action orelse return null;
    const second_sample_absent = second.sample_tick == null;
    const second_apply_absent = second.apply_result == null;
    const second_clock_preserved = std.meta.eql(service.clock, clock_before_second);
    const timeout_transmit_absent = second.transmit == null;
    const request_cancelled = service.request.cancelled;
    const request_inactive = !service.request_active;
    if (second_quality_result != .stratum or second_action != .retry_now or
        second.quality_rejection_count != 1 or second.quality_rejections_remaining != 0 or
        !second_sample_absent or !second_apply_absent or !second_clock_preserved or
        second.state != .timed_out or !second.timeout_reached or !timeout_transmit_absent or
        !request_cancelled or !request_inactive or !service.retry_exhausted or
        service.retry_limit_hits != 1 or service.quality_forced_retries != 1 or
        service.request_quality_rejections != 1 or service.retries != 1)
        return null;

    const timeout_snapshot = service;
    const id_at_timeout = device.next_udp_identification;
    const tx_at_timeout = device.tx_producer;
    const submissions_at_timeout = device.tx_submissions;
    const latched = stepNtpServiceAutomatic(device, &service, counter, start_tick + 1, 0, 0) orelse return null;
    const timeout_latched = latched.state == .timed_out and !latched.timeout_reached and
        latched.transmit == null and std.meta.eql(service, timeout_snapshot) and
        device.next_udp_identification == id_at_timeout and device.tx_producer == tx_at_timeout and
        device.tx_submissions == submissions_at_timeout;
    if (!timeout_latched) return null;

    const health = readNtpServiceHealth(&service, start_tick + 1, 1, 100) orelse return null;
    const health_reports_exhaustion = health.state == .unsynchronized and health.current_time == null and
        !health.awaiting_response and health.retry_exhausted and health.retry_limit_hits == 1 and
        health.quality_rejection_policy.maximum_rejections_per_request == 1 and
        health.request_quality_rejections == 1 and health.quality_forced_retries == 1;
    if (!health_reports_exhaustion) return null;

    const clear_succeeded = clearNtpServiceTimeout(&service);
    const rejection_count_cleared = service.request_quality_rejections == 0 and
        service.request_step_rejections == 0 and service.request_retry_attempts == 0 and
        !service.retry_exhausted;
    const duplicate_clear_rejected = !clearNtpServiceTimeout(&service);
    if (!clear_succeeded or !rejection_count_cleared or !duplicate_clear_rejected) return null;

    const restart = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick + 1,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const restart_tx = restart.transmit orelse return null;
    const restart_wait = restart.next_retry_interval_ticks orelse return null;
    if (restart.state != .awaiting or restart.start_reason != .initial or restart_wait != 1 or
        restart_tx.identification != 74 or restart_tx.completion.descriptor_index != 5 or
        restart_tx.completion.next_cursor != 6 or service.requests_started != 2 or
        service.request_retry_attempts != 0 or service.request_quality_rejections != 0 or
        service.retry_exhausted)
        return null;

    const close_succeeded = closeNtpService(device, &service);
    if (!close_succeeded or service.active or service.client.active or service.request_active or
        !service.request.cancelled)
        return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_197 or
        device.next_udp_generation != 56 or device.next_udp_identification != 75 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 6 or
        device.tx_submissions != submissions_before + 3 or txe != 102 or txd != 102 or rxe != 22 or
        overflow != 0 or device.software_rx_queue.enqueued != 107 or
        device.software_rx_queue.dequeued != 107 or device.packets_dispatched != 96 or
        device.udp_packets_dispatched != 95 or service.quality_accepted != 0 or
        service.quality_rejected != 2 or service.quality_stratum_rejected != 1 or
        service.quality_root_dispersion_rejected != 1 or service.quality_forced_retries != 1 or
        service.step_accepted != 0 or service.step_rejected != 0 or service.requests_started != 2 or
        service.retries != 1 or service.responses != 0 or service.retry_limit_hits != 1)
        return null;

    return .{
        .source_kind = counter.reference.kind,
        .frequency_hz = counter.frequency_hz,
        .counter_bits = counter.counter_bits,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .maximum_rejections = quality_rejection_policy.maximum_rejections_per_request,
        .maximum_retries = retry_policy.maximum_retries,
        .initial_identification = initial_tx.identification,
        .initial_descriptor = initial_tx.completion.descriptor_index,
        .initial_next_cursor = initial_tx.completion.next_cursor,
        .client_timestamp = client_timestamp,
        .first_quality_result = first_quality_result,
        .first_action = first_action,
        .first_sample_absent = first_sample_absent,
        .first_apply_absent = first_apply_absent,
        .first_clock_preserved = first_clock_preserved,
        .forced_retry_identification = forced_retry.identification,
        .forced_retry_descriptor = forced_retry.completion.descriptor_index,
        .forced_retry_next_cursor = forced_retry.completion.next_cursor,
        .forced_retry_timestamp_preserved = forced_retry_timestamp_preserved,
        .forced_retry_transmissions = forced_retry_transmissions,
        .second_quality_result = second_quality_result,
        .second_action = second_action,
        .second_count = second.quality_rejection_count,
        .second_remaining = second.quality_rejections_remaining,
        .second_sample_absent = second_sample_absent,
        .second_apply_absent = second_apply_absent,
        .second_clock_preserved = second_clock_preserved,
        .timeout_state = second.state,
        .timeout_reached = second.timeout_reached,
        .timeout_transmit_absent = timeout_transmit_absent,
        .request_cancelled = request_cancelled,
        .request_inactive = request_inactive,
        .retry_exhausted = timeout_snapshot.retry_exhausted,
        .retry_limit_hits = timeout_snapshot.retry_limit_hits,
        .quality_forced_retries = timeout_snapshot.quality_forced_retries,
        .timeout_latched = timeout_latched,
        .health_reports_exhaustion = health_reports_exhaustion,
        .clear_succeeded = clear_succeeded,
        .duplicate_clear_rejected = duplicate_clear_rejected,
        .rejection_count_cleared = rejection_count_cleared,
        .restart_identification = restart_tx.identification,
        .restart_descriptor = restart_tx.completion.descriptor_index,
        .restart_next_cursor = restart_tx.completion.next_cursor,
        .restart_wait_ticks = restart_wait,
        .quality_accepted = service.quality_accepted,
        .quality_rejected = service.quality_rejected,
        .quality_stratum_rejected = service.quality_stratum_rejected,
        .quality_root_dispersion_rejected = service.quality_root_dispersion_rejected,
        .step_accepted = service.step_accepted,
        .step_rejected = service.step_rejected,
        .requests_started = service.requests_started,
        .retries = service.retries,
        .responses = service.responses,
        .close_succeeded = close_succeeded,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpLiveQualityRejectionBudget(
    device: *Device,
    counter: *time_reference.ContinuousCounter,
) ?NtpLiveQualityRejectionBudgetReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_195 or
        device.next_udp_generation != 54 or device.tx_producer != 1 or
        device.next_udp_identification != 70 or device.next_dns_transaction_id != 8 or
        completionQueueEnqueued(&tx_completion_queue) != 97 or
        completionQueueDequeued(&tx_completion_queue) != 97 or
        completionQueueEnqueued(&rx_completion_queue) != 22 or
        device.software_rx_queue.enqueued != 102 or device.software_rx_queue.dequeued != 102 or
        device.packets_dispatched != 91 or device.udp_packets_dispatched != 90 or
        counter.frequency_hz == 0 or counter.counter_bits == 0)
    {
        return null;
    }

    const server = [4]u8{ 10, 0, 2, 4 };
    const endpoints_before_invalid = device.udp_endpoint_count;
    const port_before_invalid = device.next_ephemeral_udp_port;
    const generation_before_invalid = device.next_udp_generation;
    const id_before_invalid = device.next_udp_identification;
    const tx_before_invalid = device.tx_producer;
    const submissions_before_invalid = device.tx_submissions;
    const invalid_policy_rejected = openNtpServiceWithResponseRejectionPolicies(
        device,
        server,
        20,
        ntp.default_quality_policy,
        .{ .maximum_rejections_per_request = 0 },
        ntp.default_clock_step_policy,
        ntp.default_step_rejection_policy,
        .{ .initial_interval_ticks = 4, .maximum_interval_ticks = 4, .maximum_retries = 2 },
        null,
    ) == null;
    const invalid_policy_state_preserved = device.udp_endpoint_count == endpoints_before_invalid and
        device.next_ephemeral_udp_port == port_before_invalid and
        device.next_udp_generation == generation_before_invalid and
        device.next_udp_identification == id_before_invalid and device.tx_producer == tx_before_invalid and
        device.tx_submissions == submissions_before_invalid;
    if (!invalid_policy_rejected or !invalid_policy_state_preserved) return null;

    const quality_rejection_policy = ntp.QualityRejectionPolicy{ .maximum_rejections_per_request = 2 };
    const retry_policy = ntp.RetryPolicy{
        .initial_interval_ticks = 4,
        .maximum_interval_ticks = 4,
        .maximum_retries = 2,
    };
    var service = openNtpServiceWithResponseRejectionPolicies(
        device,
        server,
        20,
        ntp.default_quality_policy,
        quality_rejection_policy,
        ntp.default_clock_step_policy,
        ntp.default_step_rejection_policy,
        retry_policy,
        null,
    ) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 54 or socket.local_port != 49_195 or
        device.next_ephemeral_udp_port != 49_196 or device.next_udp_generation != 55 or
        device.udp_endpoint_count != 3 or
        !std.meta.eql(service.quality_rejection_policy, quality_rejection_policy))
        return null;

    const submissions_before = device.tx_submissions;
    const start_tick = counter.read();
    const initial = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const initial_tx = initial.transmit orelse return null;
    const client_timestamp = service.request.client_timestamp;
    if (initial.state != .awaiting or initial.start_reason != .initial or
        initial_tx.identification != 70 or initial_tx.completion.descriptor_index != 1 or
        initial_tx.completion.next_cursor != 2 or service.retry_deadline_tick != start_tick + 4)
        return null;

    const initial_clock = service.clock;
    if (!enqueueNtpServiceResponseWithQuality(
        device,
        socket,
        server,
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        2,
        ntp.default_quality_policy.max_root_delay,
        ntp.default_quality_policy.max_root_dispersion + 1,
        0x8100,
        0xF100,
    )) return null;
    const first = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 1) orelse return null;
    const first_quality_result = first.quality_result orelse return null;
    const first_action = first.quality_rejection_action orelse return null;
    const first_sample_absent = first.sample_tick == null;
    const first_apply_absent = first.apply_result == null;
    const first_clock_preserved = std.meta.eql(service.clock, initial_clock);
    const first_request_retained = first.state == .awaiting and first.transmit == null and !first.retried and
        service.request_active and service.request.transmissions == 1;
    if (first_quality_result != .root_dispersion or first_action != .retain_request or
        first.quality_rejection_count != 1 or first.quality_rejections_remaining != 1 or
        !first_sample_absent or !first_apply_absent or !first_clock_preserved or !first_request_retained or
        service.request_quality_rejections != 1 or service.quality_forced_retries != 0)
        return null;

    if (!enqueueNtpServiceResponseWithQuality(
        device,
        socket,
        server,
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        ntp.default_quality_policy.max_stratum + 1,
        ntp.default_quality_policy.max_root_delay,
        ntp.default_quality_policy.max_root_dispersion,
        0x8101,
        0xF101,
    )) return null;
    const before_boundary_clock = service.clock;
    const boundary = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 1) orelse return null;
    const boundary_quality_result = boundary.quality_result orelse return null;
    const boundary_action = boundary.quality_rejection_action orelse return null;
    const forced_retry = boundary.transmit orelse return null;
    const boundary_sample_absent = boundary.sample_tick == null;
    const boundary_apply_absent = boundary.apply_result == null;
    const boundary_clock_preserved = std.meta.eql(service.clock, before_boundary_clock);
    const forced_retry_before_deadline = start_tick < service.retry_deadline_tick;
    const forced_retry_timestamp_preserved = service.request.client_timestamp == client_timestamp;
    const quality_count_reset = service.request_quality_rejections == 0;
    if (boundary_quality_result != .stratum or boundary_action != .retry_now or
        boundary.quality_rejection_count != 2 or boundary.quality_rejections_remaining != 0 or
        !boundary_sample_absent or !boundary_apply_absent or !boundary_clock_preserved or
        !boundary.retried or boundary.timeout_reached or forced_retry.identification != 71 or
        forced_retry.completion.descriptor_index != 2 or forced_retry.completion.next_cursor != 3 or
        !forced_retry_before_deadline or !forced_retry_timestamp_preserved or
        service.request.transmissions != 2 or service.request_retry_attempts != 1 or
        !quality_count_reset or service.quality_forced_retries != 1)
        return null;

    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        0x8102,
        0xF102,
    )) return null;
    const accepted = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 1) orelse return null;
    const accepted_quality_result = accepted.quality_result orelse return null;
    const accepted_step_result = accepted.step_result orelse return null;
    const accepted_sample_tick = accepted.sample_tick orelse return null;
    const accepted_time = ntp.readProjectedClockAt(&service.clock, accepted_sample_tick) orelse return null;
    if (accepted.state != .idle or accepted_quality_result != .accepted or
        accepted.quality_rejection_action != null or accepted_step_result != .accepted or
        accepted.apply_result != .accepted or accepted_time.seconds != ntp.fixture_unix_seconds or
        accepted_time.fraction != 0x80000000 or service.request_active or
        service.request_quality_rejections != 0 or service.request_retry_attempts != 0)
        return null;

    const health = readNtpServiceHealth(&service, accepted_sample_tick, 1, 100) orelse return null;
    const health_reports_policy = health.state == .synchronized and
        health.quality_rejection_policy.maximum_rejections_per_request == 2 and
        health.request_quality_rejections == 0 and health.quality_forced_retries == 1;
    if (!health_reports_policy) return null;

    const close_succeeded = closeNtpService(device, &service);
    if (!close_succeeded or service.active or service.client.active or service.request_active) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_196 or
        device.next_udp_generation != 55 or device.next_udp_identification != 72 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 3 or
        device.tx_submissions != submissions_before + 2 or txe != 99 or txd != 99 or rxe != 22 or
        overflow != 0 or device.software_rx_queue.enqueued != 105 or
        device.software_rx_queue.dequeued != 105 or device.packets_dispatched != 94 or
        device.udp_packets_dispatched != 93 or service.quality_accepted != 1 or
        service.quality_rejected != 2 or service.quality_stratum_rejected != 1 or
        service.quality_root_dispersion_rejected != 1 or service.quality_root_delay_rejected != 0 or
        service.quality_invalid_policy_rejected != 0 or service.quality_forced_retries != 1 or
        service.step_accepted != 1 or service.step_rejected != 0 or service.requests_started != 1 or
        service.retries != 1 or service.responses != 1)
        return null;

    return .{
        .source_kind = counter.reference.kind,
        .frequency_hz = counter.frequency_hz,
        .counter_bits = counter.counter_bits,
        .invalid_policy_rejected = invalid_policy_rejected,
        .invalid_policy_state_preserved = invalid_policy_state_preserved,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .maximum_rejections = quality_rejection_policy.maximum_rejections_per_request,
        .initial_identification = initial_tx.identification,
        .initial_descriptor = initial_tx.completion.descriptor_index,
        .initial_next_cursor = initial_tx.completion.next_cursor,
        .client_timestamp = client_timestamp,
        .first_quality_result = first_quality_result,
        .first_action = first_action,
        .first_count = first.quality_rejection_count,
        .first_remaining = first.quality_rejections_remaining,
        .first_sample_absent = first_sample_absent,
        .first_apply_absent = first_apply_absent,
        .first_clock_preserved = first_clock_preserved,
        .first_request_retained = first_request_retained,
        .boundary_quality_result = boundary_quality_result,
        .boundary_action = boundary_action,
        .boundary_count = boundary.quality_rejection_count,
        .boundary_remaining = boundary.quality_rejections_remaining,
        .boundary_sample_absent = boundary_sample_absent,
        .boundary_apply_absent = boundary_apply_absent,
        .boundary_clock_preserved = boundary_clock_preserved,
        .forced_retry_identification = forced_retry.identification,
        .forced_retry_descriptor = forced_retry.completion.descriptor_index,
        .forced_retry_next_cursor = forced_retry.completion.next_cursor,
        .forced_retry_before_deadline = forced_retry_before_deadline,
        .forced_retry_timestamp_preserved = forced_retry_timestamp_preserved,
        .forced_retry_transmissions = service.request.transmissions,
        .quality_count_reset = quality_count_reset,
        .accepted_quality_result = accepted_quality_result,
        .accepted_step_result = accepted_step_result,
        .accepted_sample_tick = accepted_sample_tick,
        .accepted_seconds = accepted_time.seconds,
        .accepted_fraction = accepted_time.fraction,
        .health_reports_policy = health_reports_policy,
        .quality_accepted = service.quality_accepted,
        .quality_rejected = service.quality_rejected,
        .quality_stratum_rejected = service.quality_stratum_rejected,
        .quality_root_dispersion_rejected = service.quality_root_dispersion_rejected,
        .quality_forced_retries = service.quality_forced_retries,
        .step_accepted = service.step_accepted,
        .requests_started = service.requests_started,
        .retries = service.retries,
        .responses = service.responses,
        .close_succeeded = close_succeeded,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpDisciplineRecovery(
    device: *Device,
    counter: *time_reference.ContinuousCounter,
) ?NtpDisciplineRecoveryReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_194 or
        device.next_udp_generation != 53 or device.tx_producer != 5 or
        device.next_udp_identification != 66 or device.next_dns_transaction_id != 8 or
        completionQueueEnqueued(&tx_completion_queue) != 93 or
        completionQueueDequeued(&tx_completion_queue) != 93 or
        completionQueueEnqueued(&rx_completion_queue) != 22 or
        device.software_rx_queue.enqueued != 98 or device.software_rx_queue.dequeued != 98 or
        device.packets_dispatched != 87 or device.udp_packets_dispatched != 86 or
        counter.frequency_hz == 0 or counter.counter_bits == 0)
    {
        return null;
    }

    const server = [4]u8{ 10, 0, 2, 4 };
    const rejection_policy = ntp.StepRejectionPolicy{ .maximum_rejections_per_request = 1 };
    const retry_policy = ntp.RetryPolicy{
        .initial_interval_ticks = 1,
        .maximum_interval_ticks = 1,
        .maximum_retries = 1,
    };
    const recovery_policy = ntp.RecoveryPolicy{
        .cooldown_ticks = 2,
        .maximum_recoveries = 2,
    };
    var service = openNtpServiceWithRejectionPolicies(
        device,
        server,
        2,
        ntp.default_quality_policy,
        .{ .maximum_forward_seconds = 4, .maximum_forward_fraction = 0 },
        rejection_policy,
        retry_policy,
        recovery_policy,
    ) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 53 or socket.local_port != 49_194 or
        device.next_ephemeral_udp_port != 49_195 or device.next_udp_generation != 54 or
        device.udp_endpoint_count != 3) return null;

    const submissions_before = device.tx_submissions;
    const start_tick = counter.read();
    var transmit_identifications = [4]u16{ 0, 0, 0, 0 };
    var transmit_descriptors = [4]u16{ 0, 0, 0, 0 };
    var transmit_next_cursors = [4]u16{ 0, 0, 0, 0 };

    const initial = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const initial_tx = initial.transmit orelse return null;
    transmit_identifications[0] = initial_tx.identification;
    transmit_descriptors[0] = initial_tx.completion.descriptor_index;
    transmit_next_cursors[0] = initial_tx.completion.next_cursor;
    if (initial.state != .awaiting or initial.start_reason != .initial or
        initial_tx.identification != 66 or initial_tx.completion.descriptor_index != 5 or
        initial_tx.completion.next_cursor != 6) return null;

    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        0x7F00,
        0xEF00,
    )) return null;
    const first = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 1) orelse return null;
    const first_tick = first.sample_tick orelse return null;
    if (first.state != .idle or first.quality_result != .accepted or first.step_result != .accepted or
        first.apply_result != .accepted or service.responses != 1 or service.refresh_deadline_tick != first_tick + 2)
        return null;

    const refresh_tick = service.refresh_deadline_tick;
    const expected_refresh_timestamp = ntp.projectedTimestampAt(&service.clock, refresh_tick) orelse return null;
    const refresh = stepNtpServiceAutomatic(device, &service, counter, refresh_tick, 0, 0) orelse return null;
    const refresh_tx = refresh.transmit orelse return null;
    transmit_identifications[1] = refresh_tx.identification;
    transmit_descriptors[1] = refresh_tx.completion.descriptor_index;
    transmit_next_cursors[1] = refresh_tx.completion.next_cursor;
    const refresh_client_timestamp = service.request.client_timestamp;
    if (refresh.state != .awaiting or refresh.start_reason != .refresh or
        refresh_client_timestamp != expected_refresh_timestamp or refresh_tx.identification != 67 or
        refresh_tx.completion.descriptor_index != 6 or refresh_tx.completion.next_cursor != 7)
        return null;

    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        0x7F01,
        0xEF01,
    )) return null;
    const first_rejection = stepNtpServiceAutomatic(device, &service, counter, refresh_tick, 0, 1) orelse return null;
    const forced_retry_tx = first_rejection.transmit orelse return null;
    transmit_identifications[2] = forced_retry_tx.identification;
    transmit_descriptors[2] = forced_retry_tx.completion.descriptor_index;
    transmit_next_cursors[2] = forced_retry_tx.completion.next_cursor;
    if (first_rejection.quality_result != .accepted or first_rejection.step_result != .stale or
        first_rejection.step_rejection_action != .retry_now or !first_rejection.retried or
        first_rejection.timeout_reached or forced_retry_tx.identification != 68 or
        forced_retry_tx.completion.descriptor_index != 7 or forced_retry_tx.completion.next_cursor != 0 or
        service.request.client_timestamp != refresh_client_timestamp or service.request.transmissions != 2 or
        service.request_retry_attempts != 1 or service.request_step_rejections != 0 or
        service.discipline_forced_retries != 1)
        return null;

    const excessive_server_timestamp = ntp.fixture_server_timestamp + (@as(u64, 100) << 32);
    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        excessive_server_timestamp,
        0x7F02,
        0xEF02,
    )) return null;
    const timeout_tick = refresh_tick + 1;
    const clock_before_timeout = service.clock;
    const timeout = stepNtpServiceAutomatic(device, &service, counter, timeout_tick, 0, 1) orelse return null;
    const timeout_waiting = timeout.recovery_state == .waiting;
    const timeout_transmit_absent = timeout.transmit == null;
    const request_cancelled = service.request.cancelled;
    const recovery_deadline_delta = service.recovery_deadline_tick - timeout_tick;
    if (timeout.quality_result != .accepted or timeout.step_result != .excessive_forward_step or
        timeout.step_rejection_action != .retry_now or timeout.step_rejection_count != 1 or
        timeout.step_rejections_remaining != 0 or timeout.state != .timed_out or
        !timeout.timeout_reached or !timeout_waiting or !timeout_transmit_absent or !request_cancelled or
        service.request_active or !service.retry_exhausted or service.retry_limit_hits != 1 or
        service.request_step_rejections != 1 or service.automatic_recoveries != 0 or
        service.recovery_exhausted or recovery_deadline_delta != 2 or
        !std.meta.eql(service.clock, clock_before_timeout))
        return null;

    const timeout_health = readNtpServiceHealth(&service, timeout_tick, 1, 100) orelse return null;
    const timeout_health_time = timeout_health.current_time orelse return null;
    const timeout_health_timestamp = ntp.unixTimeToTimestamp(timeout_health_time) orelse return null;
    const cooldown_tick = timeout_tick + 1;
    const cooldown = stepNtpServiceAutomatic(device, &service, counter, cooldown_tick, 0, 0) orelse return null;
    const cooldown_no_tx = cooldown.state == .timed_out and cooldown.recovery_state == .waiting and
        cooldown.transmit == null and !cooldown.recovery_started;
    if (!cooldown_no_tx) return null;
    const cooldown_health = readNtpServiceHealth(&service, cooldown_tick, 1, 100) orelse return null;
    const cooldown_health_time = cooldown_health.current_time orelse return null;
    const cooldown_health_timestamp = ntp.unixTimeToTimestamp(cooldown_health_time) orelse return null;
    const holdover_advanced = cooldown_health_timestamp > timeout_health_timestamp;
    const holdover_visible = timeout_health.state == .holdover and cooldown_health.state == .holdover and
        timeout_health_timestamp > refresh_client_timestamp and holdover_advanced;
    if (!holdover_visible) return null;

    const recovery_tick = timeout_tick + recovery_policy.cooldown_ticks;
    const expected_recovery_timestamp = ntp.projectedTimestampAt(&service.clock, recovery_tick) orelse return null;
    const recovery = stepNtpServiceAutomatic(device, &service, counter, recovery_tick, 0, 0) orelse return null;
    const recovery_tx = recovery.transmit orelse return null;
    transmit_identifications[3] = recovery_tx.identification;
    transmit_descriptors[3] = recovery_tx.completion.descriptor_index;
    transmit_next_cursors[3] = recovery_tx.completion.next_cursor;
    const recovery_client_timestamp = service.request.client_timestamp;
    const recovery_timestamp_automatic = recovery_client_timestamp == expected_recovery_timestamp and
        recovery_client_timestamp > cooldown_health_timestamp;
    const recovery_ready = recovery.recovery_state == .ready;
    const recovery_started = recovery.state == .awaiting and recovery.start_reason == .recovery and
        recovery.recovery_started and service.automatic_recoveries == 1;
    if (!recovery_timestamp_automatic or !recovery_ready or !recovery_started or
        recovery_tx.identification != 69 or recovery_tx.completion.descriptor_index != 0 or
        recovery_tx.completion.next_cursor != 1 or service.request_retry_attempts != 0 or
        service.request_step_rejections != 0 or service.retry_exhausted)
        return null;

    const recovered_server_timestamp = ntp.fixture_server_timestamp + (@as(u64, 2) << 32);
    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        recovered_server_timestamp,
        0x7F03,
        0xEF03,
    )) return null;
    const recovered = stepNtpServiceAutomatic(device, &service, counter, recovery_tick, 0, 1) orelse return null;
    const accepted_quality_result = recovered.quality_result orelse return null;
    const accepted_step_result = recovered.step_result orelse return null;
    const accepted_sample_tick = recovered.sample_tick orelse return null;
    const accepted_time = ntp.readProjectedClockAt(&service.clock, accepted_sample_tick) orelse return null;
    const accepted_timestamp = ntp.unixTimeToTimestamp(accepted_time) orelse return null;
    const recovery_budget_reset = service.automatic_recoveries == 0 and !service.recovery_exhausted and
        service.recovery_deadline_tick == 0;
    const retry_budget_reset = service.request_retry_attempts == 0 and !service.retry_exhausted;
    const rejection_budget_reset = service.request_step_rejections == 0;
    const clock_advanced = accepted_timestamp > cooldown_health_timestamp;
    const health_after_success = readNtpServiceHealth(&service, accepted_sample_tick, 1, 100) orelse return null;
    const health_reports_success = health_after_success.state == .synchronized and
        health_after_success.current_time != null and health_after_success.recovery_successes == 1 and
        health_after_success.automatic_recoveries == 0 and !health_after_success.retry_exhausted and
        !health_after_success.recovery_exhausted and health_after_success.request_step_rejections == 0;
    if (recovered.state != .idle or accepted_quality_result != .accepted or accepted_step_result != .accepted or
        recovered.apply_result != .accepted or accepted_time.seconds != ntp.fixture_unix_seconds + 2 or
        accepted_time.fraction != 0x80000000 or service.recovery_successes != 1 or
        !recovery_budget_reset or !retry_budget_reset or !rejection_budget_reset or
        !clock_advanced or !health_reports_success)
        return null;

    const close_succeeded = closeNtpService(device, &service);
    if (!close_succeeded or service.active or service.client.active or service.request_active) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_195 or
        device.next_udp_generation != 54 or device.next_udp_identification != 70 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 1 or
        device.tx_submissions != submissions_before + 4 or txe != 97 or txd != 97 or rxe != 22 or
        overflow != 0 or device.software_rx_queue.enqueued != 102 or
        device.software_rx_queue.dequeued != 102 or device.packets_dispatched != 91 or
        device.udp_packets_dispatched != 90 or service.quality_accepted != 4 or
        service.quality_rejected != 0 or service.step_accepted != 2 or service.step_rejected != 2 or
        service.step_stale_rejected != 1 or service.step_excessive_forward_rejected != 1 or
        service.discipline_forced_retries != 1 or service.requests_started != 3 or
        service.retries != 1 or service.responses != 2 or service.retry_limit_hits != 1 or
        service.recovery_successes != 1 or service.automatic_recoveries != 0 or
        service.recovery_limit_hits != 0)
        return null;

    return .{
        .source_kind = counter.reference.kind,
        .frequency_hz = counter.frequency_hz,
        .counter_bits = counter.counter_bits,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .maximum_rejections = rejection_policy.maximum_rejections_per_request,
        .maximum_retries = retry_policy.maximum_retries,
        .recovery_cooldown_ticks = recovery_policy.cooldown_ticks,
        .maximum_recoveries = recovery_policy.maximum_recoveries,
        .transmit_identifications = transmit_identifications,
        .transmit_descriptors = transmit_descriptors,
        .transmit_next_cursors = transmit_next_cursors,
        .refresh_client_timestamp = refresh_client_timestamp,
        .recovery_client_timestamp = recovery_client_timestamp,
        .recovery_timestamp_automatic = recovery_timestamp_automatic,
        .timeout_state = timeout.state,
        .timeout_waiting = timeout_waiting,
        .timeout_transmit_absent = timeout_transmit_absent,
        .request_cancelled = request_cancelled,
        .retry_exhausted = service.retry_limit_hits == 1,
        .recovery_deadline_delta = recovery_deadline_delta,
        .timeout_health_state = timeout_health.state,
        .timeout_health_timestamp = timeout_health_timestamp,
        .cooldown_health_state = cooldown_health.state,
        .cooldown_health_timestamp = cooldown_health_timestamp,
        .holdover_visible = holdover_visible,
        .holdover_advanced = holdover_advanced,
        .cooldown_no_tx = cooldown_no_tx,
        .recovery_ready = recovery_ready,
        .recovery_started = recovery_started,
        .accepted_quality_result = accepted_quality_result,
        .accepted_step_result = accepted_step_result,
        .accepted_sample_tick = accepted_sample_tick,
        .accepted_seconds = accepted_time.seconds,
        .accepted_fraction = accepted_time.fraction,
        .recovery_successes = service.recovery_successes,
        .recovery_budget_reset = recovery_budget_reset,
        .retry_budget_reset = retry_budget_reset,
        .rejection_budget_reset = rejection_budget_reset,
        .clock_advanced = clock_advanced,
        .health_reports_success = health_reports_success,
        .quality_accepted = service.quality_accepted,
        .quality_rejected = service.quality_rejected,
        .step_accepted = service.step_accepted,
        .step_rejected = service.step_rejected,
        .step_stale_rejected = service.step_stale_rejected,
        .step_excessive_forward_rejected = service.step_excessive_forward_rejected,
        .discipline_forced_retries = service.discipline_forced_retries,
        .requests_started = service.requests_started,
        .retries = service.retries,
        .responses = service.responses,
        .close_succeeded = close_succeeded,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpLiveRejectionBudget(
    device: *Device,
    counter: *time_reference.ContinuousCounter,
) ?NtpLiveRejectionBudgetReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_192 or
        device.next_udp_generation != 51 or device.tx_producer != 7 or
        device.next_udp_identification != 60 or device.next_dns_transaction_id != 8 or
        completionQueueEnqueued(&tx_completion_queue) != 87 or
        completionQueueDequeued(&tx_completion_queue) != 87 or
        completionQueueEnqueued(&rx_completion_queue) != 22 or
        device.software_rx_queue.enqueued != 91 or device.software_rx_queue.dequeued != 91 or
        device.packets_dispatched != 80 or device.udp_packets_dispatched != 79 or
        counter.frequency_hz == 0 or counter.counter_bits == 0)
    {
        return null;
    }
    const server = [4]u8{ 10, 0, 2, 4 };
    const invalid_endpoint_count = device.udp_endpoint_count;
    const invalid_ephemeral_cursor = device.next_ephemeral_udp_port;
    const invalid_generation = device.next_udp_generation;
    const invalid_identification = device.next_udp_identification;
    const invalid_tx_cursor = device.tx_producer;
    const invalid_submissions = device.tx_submissions;
    const invalid_policy_rejected = openNtpServiceWithRejectionPolicies(
        device,
        server,
        2,
        ntp.default_quality_policy,
        .{ .maximum_forward_seconds = 4, .maximum_forward_fraction = 0 },
        .{ .maximum_rejections_per_request = 0 },
        .{ .initial_interval_ticks = 4, .maximum_interval_ticks = 4, .maximum_retries = 2 },
        null,
    ) == null;
    const invalid_policy_state_preserved = device.udp_endpoint_count == invalid_endpoint_count and
        device.next_ephemeral_udp_port == invalid_ephemeral_cursor and
        device.next_udp_generation == invalid_generation and
        device.next_udp_identification == invalid_identification and
        device.tx_producer == invalid_tx_cursor and device.tx_submissions == invalid_submissions;
    if (!invalid_policy_rejected or !invalid_policy_state_preserved) return null;

    const rejection_policy = ntp.StepRejectionPolicy{ .maximum_rejections_per_request = 2 };
    var service = openNtpServiceWithRejectionPolicies(
        device,
        server,
        2,
        ntp.default_quality_policy,
        .{ .maximum_forward_seconds = 4, .maximum_forward_fraction = 0 },
        rejection_policy,
        .{ .initial_interval_ticks = 4, .maximum_interval_ticks = 4, .maximum_retries = 2 },
        null,
    ) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 51 or socket.local_port != 49_192 or
        device.next_ephemeral_udp_port != 49_193 or device.next_udp_generation != 52 or
        device.udp_endpoint_count != 3 or !std.meta.eql(service.step_rejection_policy, rejection_policy))
        return null;

    const submissions_before = device.tx_submissions;
    const start_tick = counter.read();
    const initial = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const initial_tx = initial.transmit orelse return null;
    if (initial_tx.identification != 60 or initial_tx.completion.descriptor_index != 7 or
        initial_tx.completion.next_cursor != 0 or initial.step_rejection_action != null)
        return null;

    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        0x7D00,
        0xED00,
    )) return null;
    const first = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 1) orelse return null;
    const first_sample_tick = first.sample_tick orelse return null;
    const first_time = ntp.readProjectedClockAt(&service.clock, first_sample_tick) orelse return null;
    if (first.state != .idle or first.quality_result != .accepted or first.step_result != .accepted or
        first.apply_result != .accepted or service.request_step_rejections != 0 or
        service.discipline_forced_retries != 0) return null;

    const refresh_tick = service.refresh_deadline_tick;
    const refresh = stepNtpServiceAutomatic(device, &service, counter, refresh_tick, 0, 0) orelse return null;
    const refresh_tx = refresh.transmit orelse return null;
    const refresh_client_timestamp = service.request.client_timestamp;
    if (refresh_tx.identification != 61 or refresh_tx.completion.descriptor_index != 0 or
        refresh_tx.completion.next_cursor != 1 or service.retry_deadline_tick != refresh_tick + 4)
        return null;

    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        0x7D01,
        0xED01,
    )) return null;
    const clock_before_first = service.clock;
    const first_rejection = stepNtpServiceAutomatic(device, &service, counter, refresh_tick, 0, 1) orelse return null;
    const first_quality_result = first_rejection.quality_result orelse return null;
    const first_step_result = first_rejection.step_result orelse return null;
    const first_rejection_action = first_rejection.step_rejection_action orelse return null;
    const first_apply_absent = first_rejection.apply_result == null;
    const first_clock_preserved = std.meta.eql(service.clock, clock_before_first);
    const first_request_retained = first_rejection.state == .awaiting and
        first_rejection.transmit == null and !first_rejection.retried and service.request_active and
        service.request.client_timestamp == refresh_client_timestamp and service.request.transmissions == 1;
    if (first_quality_result != .accepted or first_step_result != .stale or
        first_rejection_action != .retain_request or first_rejection.step_rejection_count != 1 or
        first_rejection.step_rejections_remaining != 1 or !first_apply_absent or
        !first_clock_preserved or !first_request_retained or service.request_step_rejections != 1 or
        service.discipline_forced_retries != 0) return null;

    const excessive_server_timestamp = ntp.fixture_server_timestamp + (@as(u64, 100) << 32);
    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        excessive_server_timestamp,
        0x7D02,
        0xED02,
    )) return null;
    const clock_before_boundary = service.clock;
    const boundary = stepNtpServiceAutomatic(device, &service, counter, refresh_tick, 0, 1) orelse return null;
    const boundary_quality_result = boundary.quality_result orelse return null;
    const boundary_step_result = boundary.step_result orelse return null;
    const boundary_rejection_action = boundary.step_rejection_action orelse return null;
    const forced_retry_tx = boundary.transmit orelse return null;
    const boundary_apply_absent = boundary.apply_result == null;
    const boundary_clock_preserved = std.meta.eql(service.clock, clock_before_boundary);
    const forced_retry_before_deadline = boundary.retried and refresh_tick < service.retry_deadline_tick;
    const forced_retry_timestamp_preserved = service.request.client_timestamp == refresh_client_timestamp;
    const rejection_count_reset = service.request_step_rejections == 0;
    if (boundary_quality_result != .accepted or boundary_step_result != .excessive_forward_step or
        boundary_rejection_action != .retry_now or boundary.step_rejection_count != 2 or
        boundary.step_rejections_remaining != 0 or !boundary_apply_absent or
        !boundary_clock_preserved or !forced_retry_before_deadline or
        !forced_retry_timestamp_preserved or !rejection_count_reset or
        forced_retry_tx.identification != 62 or forced_retry_tx.completion.descriptor_index != 1 or
        forced_retry_tx.completion.next_cursor != 2 or service.request.transmissions != 2 or
        service.request_retry_attempts != 1 or service.retries != 1 or
        service.discipline_forced_retries != 1) return null;

    const accepted_server_timestamp = ntp.fixture_server_timestamp + (@as(u64, 2) << 32);
    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        accepted_server_timestamp,
        0x7D03,
        0xED03,
    )) return null;
    const accepted = stepNtpServiceAutomatic(device, &service, counter, refresh_tick, 0, 1) orelse return null;
    const accepted_quality_result = accepted.quality_result orelse return null;
    const accepted_step_result = accepted.step_result orelse return null;
    const accepted_sample_tick = accepted.sample_tick orelse return null;
    const accepted_time = ntp.readProjectedClockAt(&service.clock, accepted_sample_tick) orelse return null;
    const final_clock_advanced = accepted_time.seconds > first_time.seconds or
        (accepted_time.seconds == first_time.seconds and accepted_time.fraction > first_time.fraction);
    if (accepted.state != .idle or accepted_quality_result != .accepted or
        accepted_step_result != .accepted or accepted.apply_result != .accepted or
        accepted.step_rejection_action != null or accepted_time.seconds != ntp.fixture_unix_seconds + 2 or
        accepted_time.fraction != 0x80000000 or !final_clock_advanced or
        service.request_step_rejections != 0 or service.quality_accepted != 4 or
        service.quality_rejected != 0 or service.step_accepted != 2 or service.step_rejected != 2 or
        service.step_stale_rejected != 1 or service.step_excessive_forward_rejected != 1 or
        service.discipline_forced_retries != 1 or service.requests_started != 2 or
        service.retries != 1 or service.responses != 2) return null;

    const close_succeeded = closeNtpService(device, &service);
    if (!close_succeeded or service.active or service.client.active or service.request_active) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_193 or
        device.next_udp_generation != 52 or device.next_udp_identification != 63 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 2 or
        device.tx_submissions != submissions_before + 3 or txe != 90 or txd != 90 or rxe != 22 or
        overflow != 0 or device.software_rx_queue.enqueued != 95 or
        device.software_rx_queue.dequeued != 95 or device.packets_dispatched != 84 or
        device.udp_packets_dispatched != 83) return null;

    return .{
        .source_kind = counter.reference.kind,
        .frequency_hz = counter.frequency_hz,
        .counter_bits = counter.counter_bits,
        .invalid_policy_rejected = invalid_policy_rejected,
        .invalid_policy_state_preserved = invalid_policy_state_preserved,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .maximum_rejections = rejection_policy.maximum_rejections_per_request,
        .initial_identification = initial_tx.identification,
        .initial_descriptor = initial_tx.completion.descriptor_index,
        .initial_next_cursor = initial_tx.completion.next_cursor,
        .first_sample_tick = first_sample_tick,
        .refresh_identification = refresh_tx.identification,
        .refresh_descriptor = refresh_tx.completion.descriptor_index,
        .refresh_next_cursor = refresh_tx.completion.next_cursor,
        .refresh_client_timestamp = refresh_client_timestamp,
        .first_quality_result = first_quality_result,
        .first_step_result = first_step_result,
        .first_rejection_action = first_rejection_action,
        .first_rejection_count = first_rejection.step_rejection_count,
        .first_remaining = first_rejection.step_rejections_remaining,
        .first_apply_absent = first_apply_absent,
        .first_clock_preserved = first_clock_preserved,
        .first_request_retained = first_request_retained,
        .boundary_quality_result = boundary_quality_result,
        .boundary_step_result = boundary_step_result,
        .boundary_rejection_action = boundary_rejection_action,
        .boundary_rejection_count = boundary.step_rejection_count,
        .boundary_remaining = boundary.step_rejections_remaining,
        .boundary_apply_absent = boundary_apply_absent,
        .boundary_clock_preserved = boundary_clock_preserved,
        .forced_retry_identification = forced_retry_tx.identification,
        .forced_retry_descriptor = forced_retry_tx.completion.descriptor_index,
        .forced_retry_next_cursor = forced_retry_tx.completion.next_cursor,
        .forced_retry_before_deadline = forced_retry_before_deadline,
        .forced_retry_timestamp_preserved = forced_retry_timestamp_preserved,
        .forced_retry_transmissions = service.request.transmissions,
        .rejection_count_reset = rejection_count_reset,
        .accepted_quality_result = accepted_quality_result,
        .accepted_step_result = accepted_step_result,
        .accepted_sample_tick = accepted_sample_tick,
        .accepted_seconds = accepted_time.seconds,
        .accepted_fraction = accepted_time.fraction,
        .final_clock_advanced = final_clock_advanced,
        .quality_accepted = service.quality_accepted,
        .quality_rejected = service.quality_rejected,
        .step_accepted = service.step_accepted,
        .step_rejected = service.step_rejected,
        .step_stale_rejected = service.step_stale_rejected,
        .step_excessive_forward_rejected = service.step_excessive_forward_rejected,
        .discipline_forced_retries = service.discipline_forced_retries,
        .requests_started = service.requests_started,
        .retries = service.retries,
        .responses = service.responses,
        .close_succeeded = close_succeeded,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpStaleStepRetry(
    device: *Device,
    counter: *time_reference.ContinuousCounter,
) ?NtpStaleStepRetryReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_191 or
        device.next_udp_generation != 50 or device.tx_producer != 4 or
        device.next_udp_identification != 57 or device.next_dns_transaction_id != 8 or
        completionQueueEnqueued(&tx_completion_queue) != 84 or
        completionQueueDequeued(&tx_completion_queue) != 84 or
        completionQueueEnqueued(&rx_completion_queue) != 22 or
        device.software_rx_queue.enqueued != 88 or device.software_rx_queue.dequeued != 88 or
        device.packets_dispatched != 77 or device.udp_packets_dispatched != 76 or
        counter.frequency_hz == 0 or counter.counter_bits == 0)
    {
        return null;
    }
    const server = [4]u8{ 10, 0, 2, 4 };
    const step_policy = ntp.ClockStepPolicy{
        .maximum_forward_seconds = 4,
        .maximum_forward_fraction = 0,
    };
    const retry_policy = ntp.RetryPolicy{
        .initial_interval_ticks = 1,
        .maximum_interval_ticks = 1,
        .maximum_retries = 2,
    };
    var service = openNtpServiceWithDisciplinePolicies(
        device,
        server,
        2,
        ntp.default_quality_policy,
        step_policy,
        retry_policy,
        null,
    ) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 50 or socket.local_port != 49_191 or
        device.next_ephemeral_udp_port != 49_192 or device.next_udp_generation != 51 or
        device.udp_endpoint_count != 3) return null;

    const submissions_before = device.tx_submissions;
    const start_tick = counter.read();
    const initial = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const initial_tx = initial.transmit orelse return null;
    if (initial_tx.identification != 57 or initial_tx.completion.descriptor_index != 4 or
        initial_tx.completion.next_cursor != 5) return null;

    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        0x7C00,
        0xEC00,
    )) return null;
    const first = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 1) orelse return null;
    const first_sample_tick = first.sample_tick orelse return null;
    const first_time = ntp.readProjectedClockAt(&service.clock, first_sample_tick) orelse return null;
    if (first.state != .idle or first.quality_result != .accepted or first.step_result != .accepted or
        first.apply_result != .accepted or first_time.seconds != ntp.fixture_unix_seconds or
        first_time.fraction != 0x80000000 or service.responses != 1 or
        service.quality_accepted != 1 or service.step_accepted != 1)
        return null;

    const refresh_tick = service.refresh_deadline_tick;
    const refresh = stepNtpServiceAutomatic(device, &service, counter, refresh_tick, 0, 0) orelse return null;
    const refresh_tx = refresh.transmit orelse return null;
    const refresh_client_timestamp = service.request.client_timestamp;
    if (refresh.state != .awaiting or refresh.start_reason != .refresh or
        refresh_tx.identification != 58 or refresh_tx.completion.descriptor_index != 5 or
        refresh_tx.completion.next_cursor != 6 or service.retry_deadline_tick != refresh_tick + 1)
        return null;

    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        0x7C01,
        0xEC01,
    )) return null;
    const clock_before_stale = service.clock;
    const stale = stepNtpServiceAutomatic(device, &service, counter, refresh_tick, 0, 1) orelse return null;
    const stale_quality_result = stale.quality_result orelse return null;
    const stale_step_result = stale.step_result orelse return null;
    const stale_sample_tick = stale.sample_tick orelse return null;
    const stale_apply_absent = stale.apply_result == null;
    const stale_clock_preserved = std.meta.eql(service.clock, clock_before_stale);
    const stale_request_retained = stale.state == .awaiting and stale.poll.state == .resolved and
        stale.transmit == null and !stale.retried and service.request_active and
        service.request.client_timestamp == refresh_client_timestamp and
        service.request.transmissions == 1;
    if (stale_quality_result != .accepted or stale_step_result != .stale or
        !stale_apply_absent or !stale_clock_preserved or !stale_request_retained or
        service.quality_accepted != 2 or service.quality_rejected != 0 or
        service.step_accepted != 1 or service.step_rejected != 1 or
        service.step_invalid_policy_rejected != 0 or service.step_stale_rejected != 1 or
        service.step_excessive_forward_rejected != 0 or service.responses != 1)
        return null;

    const retry = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        refresh_tick + 1,
        0,
        0,
    ) orelse return null;
    const retry_tx = retry.transmit orelse return null;
    const retry_timestamp_preserved = service.request.client_timestamp == refresh_client_timestamp;
    if (!retry.retried or retry.next_retry_interval_ticks != 1 or !retry_timestamp_preserved or
        retry_tx.identification != 59 or retry_tx.completion.descriptor_index != 6 or
        retry_tx.completion.next_cursor != 7 or service.request.transmissions != 2 or
        service.retries != 1) return null;

    const accepted_server_timestamp = ntp.fixture_server_timestamp + (@as(u64, 2) << 32);
    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        accepted_server_timestamp,
        0x7C02,
        0xEC02,
    )) return null;
    const accepted = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        refresh_tick + 1,
        0,
        1,
    ) orelse return null;
    const accepted_quality_result = accepted.quality_result orelse return null;
    const accepted_step_result = accepted.step_result orelse return null;
    const accepted_sample_tick = accepted.sample_tick orelse return null;
    const accepted_time = ntp.readProjectedClockAt(&service.clock, accepted_sample_tick) orelse return null;
    const final_clock_advanced = accepted_time.seconds > first_time.seconds or
        (accepted_time.seconds == first_time.seconds and accepted_time.fraction > first_time.fraction);
    if (accepted.state != .idle or accepted_quality_result != .accepted or
        accepted_step_result != .accepted or accepted.apply_result != .accepted or
        accepted_time.seconds != ntp.fixture_unix_seconds + 2 or
        accepted_time.fraction != 0x80000000 or !final_clock_advanced or
        service.request_active or service.quality_accepted != 3 or service.quality_rejected != 0 or
        service.step_accepted != 2 or service.step_rejected != 1 or
        service.step_invalid_policy_rejected != 0 or service.step_stale_rejected != 1 or
        service.step_excessive_forward_rejected != 0 or service.requests_started != 2 or
        service.retries != 1 or service.responses != 2)
        return null;

    const close_succeeded = closeNtpService(device, &service);
    if (!close_succeeded or service.active or service.client.active or service.request_active) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_192 or
        device.next_udp_generation != 51 or device.next_udp_identification != 60 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 7 or
        device.tx_submissions != submissions_before + 3 or txe != 87 or txd != 87 or rxe != 22 or
        overflow != 0 or device.software_rx_queue.enqueued != 91 or
        device.software_rx_queue.dequeued != 91 or device.packets_dispatched != 80 or
        device.udp_packets_dispatched != 79) return null;

    return .{
        .source_kind = counter.reference.kind,
        .frequency_hz = counter.frequency_hz,
        .counter_bits = counter.counter_bits,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .maximum_forward_seconds = step_policy.maximum_forward_seconds,
        .initial_identification = initial_tx.identification,
        .initial_descriptor = initial_tx.completion.descriptor_index,
        .initial_next_cursor = initial_tx.completion.next_cursor,
        .first_sample_tick = first_sample_tick,
        .first_seconds = first_time.seconds,
        .first_fraction = first_time.fraction,
        .refresh_identification = refresh_tx.identification,
        .refresh_descriptor = refresh_tx.completion.descriptor_index,
        .refresh_next_cursor = refresh_tx.completion.next_cursor,
        .refresh_client_timestamp = refresh_client_timestamp,
        .stale_quality_result = stale_quality_result,
        .stale_step_result = stale_step_result,
        .stale_sample_tick = stale_sample_tick,
        .stale_apply_absent = stale_apply_absent,
        .stale_clock_preserved = stale_clock_preserved,
        .stale_request_retained = stale_request_retained,
        .retry_identification = retry_tx.identification,
        .retry_descriptor = retry_tx.completion.descriptor_index,
        .retry_next_cursor = retry_tx.completion.next_cursor,
        .retry_timestamp_preserved = retry_timestamp_preserved,
        .retry_transmissions = service.request.transmissions,
        .accepted_quality_result = accepted_quality_result,
        .accepted_step_result = accepted_step_result,
        .accepted_sample_tick = accepted_sample_tick,
        .accepted_seconds = accepted_time.seconds,
        .accepted_fraction = accepted_time.fraction,
        .final_clock_advanced = final_clock_advanced,
        .quality_accepted = service.quality_accepted,
        .quality_rejected = service.quality_rejected,
        .step_accepted = service.step_accepted,
        .step_rejected = service.step_rejected,
        .step_invalid_policy_rejected = service.step_invalid_policy_rejected,
        .step_stale_rejected = service.step_stale_rejected,
        .step_excessive_forward_rejected = service.step_excessive_forward_rejected,
        .requests_started = service.requests_started,
        .retries = service.retries,
        .responses = service.responses,
        .close_succeeded = close_succeeded,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}
fn verifyNtpLiveStepGate(
    device: *Device,
    counter: *time_reference.ContinuousCounter,
) ?NtpLiveStepGateReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_190 or
        device.next_udp_generation != 49 or device.tx_producer != 2 or
        device.next_udp_identification != 55 or device.next_dns_transaction_id != 8 or
        completionQueueEnqueued(&tx_completion_queue) != 82 or
        completionQueueDequeued(&tx_completion_queue) != 82 or
        completionQueueEnqueued(&rx_completion_queue) != 22 or
        device.software_rx_queue.enqueued != 85 or device.software_rx_queue.dequeued != 85 or
        device.packets_dispatched != 74 or device.udp_packets_dispatched != 73 or
        counter.frequency_hz == 0 or counter.counter_bits == 0)
    {
        return null;
    }
    const server = [4]u8{ 10, 0, 2, 4 };
    const invalid_endpoint_count = device.udp_endpoint_count;
    const invalid_ephemeral_cursor = device.next_ephemeral_udp_port;
    const invalid_generation = device.next_udp_generation;
    const invalid_identification = device.next_udp_identification;
    const invalid_tx_cursor = device.tx_producer;
    const invalid_submissions = device.tx_submissions;
    const invalid_policy_rejected = openNtpServiceWithDisciplinePolicies(
        device,
        server,
        2,
        ntp.default_quality_policy,
        .{ .maximum_forward_seconds = 0, .maximum_forward_fraction = 0 },
        .{ .initial_interval_ticks = 4, .maximum_interval_ticks = 4, .maximum_retries = 2 },
        null,
    ) == null;
    const invalid_policy_state_preserved = device.udp_endpoint_count == invalid_endpoint_count and
        device.next_ephemeral_udp_port == invalid_ephemeral_cursor and
        device.next_udp_generation == invalid_generation and
        device.next_udp_identification == invalid_identification and
        device.tx_producer == invalid_tx_cursor and device.tx_submissions == invalid_submissions;
    if (!invalid_policy_rejected or !invalid_policy_state_preserved) return null;

    const step_policy = ntp.ClockStepPolicy{
        .maximum_forward_seconds = 4,
        .maximum_forward_fraction = 0,
    };
    var service = openNtpServiceWithDisciplinePolicies(
        device,
        server,
        2,
        ntp.default_quality_policy,
        step_policy,
        .{ .initial_interval_ticks = 4, .maximum_interval_ticks = 4, .maximum_retries = 2 },
        null,
    ) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 49 or socket.local_port != 49_190 or
        device.next_ephemeral_udp_port != 49_191 or device.next_udp_generation != 50 or
        device.udp_endpoint_count != 3 or !std.meta.eql(service.step_policy, step_policy)) return null;

    const submissions_before = device.tx_submissions;
    const start_tick = counter.read();
    const initial = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const initial_tx = initial.transmit orelse return null;
    if (initial_tx.identification != 55 or initial_tx.completion.descriptor_index != 2 or
        initial_tx.completion.next_cursor != 3 or initial.step_result != null) return null;

    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        0x7B00,
        0xEB00,
    )) return null;
    const first = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 1) orelse return null;
    const first_sample_tick = first.sample_tick orelse return null;
    const first_time = ntp.readProjectedClockAt(&service.clock, first_sample_tick) orelse return null;
    const initial_quality_result = first.quality_result orelse return null;
    const initial_step_result = first.step_result orelse return null;
    if (first.state != .idle or initial_quality_result != .accepted or
        initial_step_result != .accepted or first.apply_result != .accepted or
        first_time.seconds != ntp.fixture_unix_seconds or first_time.fraction != 0x80000000 or
        service.quality_accepted != 1 or service.step_accepted != 1 or service.responses != 1)
        return null;

    const refresh_tick = service.refresh_deadline_tick;
    const refresh = stepNtpServiceAutomatic(device, &service, counter, refresh_tick, 0, 0) orelse return null;
    const refresh_tx = refresh.transmit orelse return null;
    const refresh_client_timestamp = service.request.client_timestamp;
    if (refresh.state != .awaiting or refresh.start_reason != .refresh or
        refresh_tx.identification != 56 or refresh_tx.completion.descriptor_index != 3 or
        refresh_tx.completion.next_cursor != 4 or refresh_client_timestamp == ntp.fixture_client_timestamp)
        return null;

    const excessive_server_timestamp = ntp.fixture_server_timestamp + (@as(u64, 100) << 32);
    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        excessive_server_timestamp,
        0x7B01,
        0xEB01,
    )) return null;
    const clock_before_excessive = service.clock;
    const excessive = stepNtpServiceAutomatic(device, &service, counter, refresh_tick, 0, 1) orelse return null;
    const excessive_quality_result = excessive.quality_result orelse return null;
    const excessive_step_result = excessive.step_result orelse return null;
    const excessive_sample_tick = excessive.sample_tick orelse return null;
    const excessive_apply_absent = excessive.apply_result == null;
    const excessive_clock_preserved = std.meta.eql(service.clock, clock_before_excessive);
    const excessive_request_retained = excessive.state == .awaiting and excessive.poll.state == .resolved and
        excessive.transmit == null and !excessive.retried and service.request_active and
        service.request.client_timestamp == refresh_client_timestamp;
    if (excessive_quality_result != .accepted or excessive_step_result != .excessive_forward_step or
        !excessive_apply_absent or !excessive_clock_preserved or !excessive_request_retained or
        service.quality_accepted != 2 or service.quality_rejected != 0 or service.step_accepted != 1 or
        service.step_rejected != 1 or service.step_invalid_policy_rejected != 0 or
        service.step_stale_rejected != 0 or service.step_excessive_forward_rejected != 1 or
        service.responses != 1) return null;

    const accepted_server_timestamp = ntp.fixture_server_timestamp + (@as(u64, 2) << 32);
    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        accepted_server_timestamp,
        0x7B02,
        0xEB02,
    )) return null;
    const accepted = stepNtpServiceAutomatic(device, &service, counter, refresh_tick, 0, 1) orelse return null;
    const accepted_quality_result = accepted.quality_result orelse return null;
    const accepted_step_result = accepted.step_result orelse return null;
    const accepted_sample_tick = accepted.sample_tick orelse return null;
    const accepted_time = ntp.readProjectedClockAt(&service.clock, accepted_sample_tick) orelse return null;
    const final_clock_advanced = accepted_time.seconds > first_time.seconds or
        (accepted_time.seconds == first_time.seconds and accepted_time.fraction > first_time.fraction);
    if (accepted.state != .idle or accepted_quality_result != .accepted or
        accepted_step_result != .accepted or accepted.apply_result != .accepted or
        accepted_time.seconds != ntp.fixture_unix_seconds + 2 or
        accepted_time.fraction != 0x80000000 or !final_clock_advanced or
        service.request_active or service.quality_accepted != 3 or service.quality_rejected != 0 or
        service.step_accepted != 2 or service.step_rejected != 1 or
        service.step_invalid_policy_rejected != 0 or service.step_stale_rejected != 0 or
        service.step_excessive_forward_rejected != 1 or service.responses != 2 or
        service.clock.clock.accepted_samples != 2 or service.clock.clock.stale_samples != 0)
        return null;

    const close_succeeded = closeNtpService(device, &service);
    if (!close_succeeded or service.active or service.client.active or service.request_active) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_191 or
        device.next_udp_generation != 50 or device.next_udp_identification != 57 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 4 or
        device.tx_submissions != submissions_before + 2 or txe != 84 or txd != 84 or rxe != 22 or
        overflow != 0 or device.software_rx_queue.enqueued != 88 or
        device.software_rx_queue.dequeued != 88 or device.packets_dispatched != 77 or
        device.udp_packets_dispatched != 76) return null;

    return .{
        .source_kind = counter.reference.kind,
        .frequency_hz = counter.frequency_hz,
        .counter_bits = counter.counter_bits,
        .invalid_policy_rejected = invalid_policy_rejected,
        .invalid_policy_state_preserved = invalid_policy_state_preserved,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .maximum_forward_seconds = step_policy.maximum_forward_seconds,
        .maximum_forward_fraction = step_policy.maximum_forward_fraction,
        .initial_identification = initial_tx.identification,
        .initial_descriptor = initial_tx.completion.descriptor_index,
        .initial_next_cursor = initial_tx.completion.next_cursor,
        .initial_quality_result = initial_quality_result,
        .initial_step_result = initial_step_result,
        .first_sample_tick = first_sample_tick,
        .first_seconds = first_time.seconds,
        .first_fraction = first_time.fraction,
        .refresh_identification = refresh_tx.identification,
        .refresh_descriptor = refresh_tx.completion.descriptor_index,
        .refresh_next_cursor = refresh_tx.completion.next_cursor,
        .refresh_client_timestamp = refresh_client_timestamp,
        .excessive_quality_result = excessive_quality_result,
        .excessive_step_result = excessive_step_result,
        .excessive_sample_tick = excessive_sample_tick,
        .excessive_apply_absent = excessive_apply_absent,
        .excessive_clock_preserved = excessive_clock_preserved,
        .excessive_request_retained = excessive_request_retained,
        .accepted_quality_result = accepted_quality_result,
        .accepted_step_result = accepted_step_result,
        .accepted_sample_tick = accepted_sample_tick,
        .accepted_seconds = accepted_time.seconds,
        .accepted_fraction = accepted_time.fraction,
        .final_clock_advanced = final_clock_advanced,
        .quality_accepted = service.quality_accepted,
        .quality_rejected = service.quality_rejected,
        .step_accepted = service.step_accepted,
        .step_rejected = service.step_rejected,
        .step_invalid_policy_rejected = service.step_invalid_policy_rejected,
        .step_stale_rejected = service.step_stale_rejected,
        .step_excessive_forward_rejected = service.step_excessive_forward_rejected,
        .responses = service.responses,
        .close_succeeded = close_succeeded,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}
fn verifyNtpSynchronizedRecovery(
    device: *Device,
    counter: *time_reference.ContinuousCounter,
) ?NtpSynchronizedRecoveryReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_189 or
        device.next_udp_generation != 48 or device.tx_producer != 3 or
        device.next_udp_identification != 48 or device.next_dns_transaction_id != 8 or
        completionQueueEnqueued(&tx_completion_queue) != 75 or
        completionQueueDequeued(&tx_completion_queue) != 75 or
        completionQueueEnqueued(&rx_completion_queue) != 22 or
        device.software_rx_queue.enqueued != 83 or device.software_rx_queue.dequeued != 83 or
        device.packets_dispatched != 72 or device.udp_packets_dispatched != 71 or
        counter.frequency_hz == 0 or counter.counter_bits == 0)
    {
        return null;
    }
    const server = [4]u8{ 10, 0, 2, 4 };
    const retry_policy = ntp.RetryPolicy{
        .initial_interval_ticks = 1,
        .maximum_interval_ticks = 1,
        .maximum_retries = 1,
    };
    const recovery_policy = ntp.RecoveryPolicy{
        .cooldown_ticks = 2,
        .maximum_recoveries = 2,
    };
    var service = openNtpServiceWithRecoveryPolicies(
        device,
        server,
        2,
        ntp.default_quality_policy,
        retry_policy,
        recovery_policy,
    ) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 48 or socket.local_port != 49_189 or
        device.next_ephemeral_udp_port != 49_190 or device.next_udp_generation != 49 or
        device.udp_endpoint_count != 3) return null;

    const submissions_before = device.tx_submissions;
    const start_tick = counter.read();
    var transmit_identifications = [7]u16{ 0, 0, 0, 0, 0, 0, 0 };
    var transmit_descriptors = [7]u16{ 0, 0, 0, 0, 0, 0, 0 };
    var transmit_next_cursors = [7]u16{ 0, 0, 0, 0, 0, 0, 0 };

    const initial = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const initial_tx = initial.transmit orelse return null;
    transmit_identifications[0] = initial_tx.identification;
    transmit_descriptors[0] = initial_tx.completion.descriptor_index;
    transmit_next_cursors[0] = initial_tx.completion.next_cursor;
    const initial_client_timestamp = service.request.client_timestamp;
    if (initial.state != .awaiting or initial.start_reason != .initial or
        initial_client_timestamp != ntp.fixture_client_timestamp or initial_tx.identification != 48 or
        initial_tx.completion.descriptor_index != 3 or initial_tx.completion.next_cursor != 4)
        return null;

    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        0x7A00,
        0xEA00,
    )) return null;
    const first = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 1) orelse return null;
    const first_tick = first.sample_tick orelse return null;
    const first_time = ntp.readProjectedClockAt(&service.clock, first_tick) orelse return null;
    if (first.state != .idle or first.quality_result != .accepted or first.apply_result != .accepted or
        first_time.seconds != ntp.fixture_unix_seconds or first_time.fraction != 0x80000000 or
        service.responses != 1 or service.quality_accepted != 1 or service.recovery_successes != 0 or
        service.automatic_recoveries != 0 or service.refresh_deadline_tick != first_tick + 2)
        return null;

    const refresh_tick = service.refresh_deadline_tick;
    const expected_refresh_timestamp = ntp.projectedTimestampAt(&service.clock, refresh_tick) orelse return null;
    const refresh = stepNtpServiceAutomatic(device, &service, counter, refresh_tick, 0, 0) orelse return null;
    const refresh_tx = refresh.transmit orelse return null;
    transmit_identifications[1] = refresh_tx.identification;
    transmit_descriptors[1] = refresh_tx.completion.descriptor_index;
    transmit_next_cursors[1] = refresh_tx.completion.next_cursor;
    const refresh_client_timestamp = service.request.client_timestamp;
    const first_refresh_timestamp_automatic = refresh_client_timestamp == expected_refresh_timestamp and
        refresh_client_timestamp != initial_client_timestamp;
    if (refresh.state != .awaiting or refresh.start_reason != .refresh or
        !first_refresh_timestamp_automatic or refresh_tx.identification != 49 or
        refresh_tx.completion.descriptor_index != 4 or refresh_tx.completion.next_cursor != 5)
        return null;

    const refresh_retry = stepNtpServiceAutomatic(device, &service, counter, refresh_tick + 1, 0, 0) orelse return null;
    const refresh_retry_tx = refresh_retry.transmit orelse return null;
    transmit_identifications[2] = refresh_retry_tx.identification;
    transmit_descriptors[2] = refresh_retry_tx.completion.descriptor_index;
    transmit_next_cursors[2] = refresh_retry_tx.completion.next_cursor;
    if (!refresh_retry.retried or refresh_retry_tx.identification != 50 or
        refresh_retry_tx.completion.descriptor_index != 5 or
        refresh_retry_tx.completion.next_cursor != 6) return null;

    const first_timeout_tick = refresh_tick + 2;
    const first_timeout = stepNtpServiceAutomatic(device, &service, counter, first_timeout_tick, 0, 0) orelse return null;
    const first_timeout_delta = first_timeout_tick - first_tick;
    const first_recovery_deadline_delta = service.recovery_deadline_tick - first_tick;
    if (first_timeout.state != .timed_out or !first_timeout.timeout_reached or
        first_timeout.recovery_state != .waiting or first_timeout_delta != 4 or
        first_recovery_deadline_delta != 6 or service.automatic_recoveries != 0)
        return null;

    const timeout_health = readNtpServiceHealth(&service, first_timeout_tick, 1, 100) orelse return null;
    const timeout_health_time = timeout_health.current_time orelse return null;
    const timeout_health_timestamp = ntp.unixTimeToTimestamp(timeout_health_time) orelse return null;
    const cooldown_tick = first_timeout_tick + 1;
    const cooldown = stepNtpServiceAutomatic(device, &service, counter, cooldown_tick, 0, 0) orelse return null;
    if (cooldown.state != .timed_out or cooldown.recovery_state != .waiting or
        cooldown.transmit != null or cooldown.recovery_started) return null;
    const cooldown_health = readNtpServiceHealth(&service, cooldown_tick, 1, 100) orelse return null;
    const cooldown_health_time = cooldown_health.current_time orelse return null;
    const cooldown_health_timestamp = ntp.unixTimeToTimestamp(cooldown_health_time) orelse return null;
    const holdover_advanced = cooldown_health_timestamp > timeout_health_timestamp;
    const holdover_visible = timeout_health.state == .holdover and cooldown_health.state == .holdover and
        timeout_health_timestamp > refresh_client_timestamp and holdover_advanced;
    if (!holdover_visible) return null;

    const first_recovery_tick = first_timeout_tick + 2;
    const expected_first_recovery_timestamp = ntp.projectedTimestampAt(
        &service.clock,
        first_recovery_tick,
    ) orelse return null;
    const first_recovery = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        first_recovery_tick,
        0,
        0,
    ) orelse return null;
    const first_recovery_tx = first_recovery.transmit orelse return null;
    transmit_identifications[3] = first_recovery_tx.identification;
    transmit_descriptors[3] = first_recovery_tx.completion.descriptor_index;
    transmit_next_cursors[3] = first_recovery_tx.completion.next_cursor;
    const first_recovery_client_timestamp = service.request.client_timestamp;
    const first_recovery_timestamp_automatic =
        first_recovery_client_timestamp == expected_first_recovery_timestamp and
        first_recovery_client_timestamp > refresh_client_timestamp;
    const first_recovery_started = first_recovery.state == .awaiting and
        first_recovery.start_reason == .recovery and first_recovery.recovery_state == .ready and
        first_recovery.recovery_started and service.automatic_recoveries == 1;
    if (!first_recovery_timestamp_automatic or !first_recovery_started or
        first_recovery_tx.identification != 51 or first_recovery_tx.completion.descriptor_index != 6 or
        first_recovery_tx.completion.next_cursor != 7) return null;

    const recovered_server_timestamp = ntp.fixture_server_timestamp + (@as(u64, 2) << 32);
    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        recovered_server_timestamp,
        0x7A01,
        0xEA01,
    )) return null;
    const recovered = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        first_recovery_tick,
        0,
        1,
    ) orelse return null;
    const recovered_tick = recovered.sample_tick orelse return null;
    const recovered_time = ntp.readProjectedClockAt(&service.clock, recovered_tick) orelse return null;
    const recovered_timestamp = ntp.unixTimeToTimestamp(recovered_time) orelse return null;
    const recovery_response_accepted = recovered.state == .idle and recovered.quality_result == .accepted and
        recovered.apply_result == .accepted and service.responses == 2 and service.quality_accepted == 2;
    const recovery_budget_reset = service.automatic_recoveries == 0 and
        !service.retry_exhausted and !service.recovery_exhausted and
        service.recovery_deadline_tick == 0;
    const recovered_time_advanced = recovered_timestamp > cooldown_health_timestamp;
    if (!recovery_response_accepted or service.recovery_successes != 1 or
        !recovery_budget_reset or !recovered_time_advanced or
        recovered_time.seconds != ntp.fixture_unix_seconds + 2 or
        recovered_time.fraction != 0x80000000) return null;

    const health_after_success = readNtpServiceHealth(&service, recovered_tick, 1, 100) orelse return null;
    const health_reports_success = health_after_success.state == .synchronized and
        health_after_success.current_time != null and health_after_success.automatic_recoveries == 0 and
        !health_after_success.retry_exhausted and !health_after_success.recovery_exhausted and
        health_after_success.recovery_successes == 1;
    if (!health_reports_success) return null;

    const second_refresh_tick = service.refresh_deadline_tick;
    const second_refresh = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        second_refresh_tick,
        0,
        0,
    ) orelse return null;
    const second_refresh_tx = second_refresh.transmit orelse return null;
    transmit_identifications[4] = second_refresh_tx.identification;
    transmit_descriptors[4] = second_refresh_tx.completion.descriptor_index;
    transmit_next_cursors[4] = second_refresh_tx.completion.next_cursor;
    if (second_refresh.state != .awaiting or second_refresh.start_reason != .refresh or
        second_refresh_tx.identification != 52 or second_refresh_tx.completion.descriptor_index != 7 or
        second_refresh_tx.completion.next_cursor != 0) return null;

    const second_retry = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        second_refresh_tick + 1,
        0,
        0,
    ) orelse return null;
    const second_retry_tx = second_retry.transmit orelse return null;
    transmit_identifications[5] = second_retry_tx.identification;
    transmit_descriptors[5] = second_retry_tx.completion.descriptor_index;
    transmit_next_cursors[5] = second_retry_tx.completion.next_cursor;
    if (!second_retry.retried or second_retry_tx.identification != 53 or
        second_retry_tx.completion.descriptor_index != 0 or second_retry_tx.completion.next_cursor != 1)
        return null;

    const second_timeout_tick = second_refresh_tick + 2;
    const second_timeout = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        second_timeout_tick,
        0,
        0,
    ) orelse return null;
    const second_timeout_delta = second_timeout_tick - recovered_tick;
    const second_recovery_deadline_delta = service.recovery_deadline_tick - recovered_tick;
    if (second_timeout.state != .timed_out or !second_timeout.timeout_reached or
        second_timeout.recovery_state != .waiting or second_timeout_delta != 4 or
        second_recovery_deadline_delta != 6 or service.automatic_recoveries != 0)
        return null;

    const second_recovery_tick = second_timeout_tick + 2;
    const expected_second_recovery_timestamp = ntp.projectedTimestampAt(
        &service.clock,
        second_recovery_tick,
    ) orelse return null;
    const second_recovery = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        second_recovery_tick,
        0,
        0,
    ) orelse return null;
    const second_recovery_tx = second_recovery.transmit orelse return null;
    transmit_identifications[6] = second_recovery_tx.identification;
    transmit_descriptors[6] = second_recovery_tx.completion.descriptor_index;
    transmit_next_cursors[6] = second_recovery_tx.completion.next_cursor;
    const second_recovery_client_timestamp = service.request.client_timestamp;
    const second_recovery_timestamp_automatic =
        second_recovery_client_timestamp == expected_second_recovery_timestamp and
        second_recovery_client_timestamp > first_recovery_client_timestamp;
    const second_recovery_started = second_recovery.state == .awaiting and
        second_recovery.start_reason == .recovery and second_recovery.recovery_state == .ready and
        second_recovery.recovery_started and service.automatic_recoveries == 1;
    const full_budget_restored = second_recovery_started and !service.recovery_exhausted and
        service.recovery_limit_hits == 0 and service.recovery_successes == 1;
    if (!second_recovery_timestamp_automatic or !full_budget_restored or
        second_recovery_tx.identification != 54 or second_recovery_tx.completion.descriptor_index != 1 or
        second_recovery_tx.completion.next_cursor != 2) return null;

    const close_succeeded = closeNtpService(device, &service);
    if (!close_succeeded or service.active or service.client.active or service.request_active or
        !service.request.cancelled) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_190 or
        device.next_udp_generation != 49 or device.next_udp_identification != 55 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 2 or
        device.tx_submissions != submissions_before + 7 or txe != 82 or txd != 82 or rxe != 22 or
        overflow != 0 or device.software_rx_queue.enqueued != 85 or
        device.software_rx_queue.dequeued != 85 or device.packets_dispatched != 74 or
        device.udp_packets_dispatched != 73 or service.requests_started != 5 or service.retries != 2 or
        service.retry_limit_hits != 2 or service.responses != 2 or service.quality_accepted != 2 or
        service.recovery_successes != 1 or service.automatic_recoveries != 1 or
        service.recovery_limit_hits != 0) return null;

    return .{
        .source_kind = counter.reference.kind,
        .frequency_hz = counter.frequency_hz,
        .counter_bits = counter.counter_bits,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .transmit_identifications = transmit_identifications,
        .transmit_descriptors = transmit_descriptors,
        .transmit_next_cursors = transmit_next_cursors,
        .initial_client_timestamp = initial_client_timestamp,
        .refresh_client_timestamp = refresh_client_timestamp,
        .first_recovery_client_timestamp = first_recovery_client_timestamp,
        .second_recovery_client_timestamp = second_recovery_client_timestamp,
        .first_refresh_timestamp_automatic = first_refresh_timestamp_automatic,
        .first_recovery_timestamp_automatic = first_recovery_timestamp_automatic,
        .second_recovery_timestamp_automatic = second_recovery_timestamp_automatic,
        .timeout_health_state = timeout_health.state,
        .timeout_health_timestamp = timeout_health_timestamp,
        .cooldown_health_state = cooldown_health.state,
        .cooldown_health_timestamp = cooldown_health_timestamp,
        .holdover_advanced = holdover_advanced,
        .holdover_visible = holdover_visible,
        .first_timeout_delta = first_timeout_delta,
        .first_recovery_deadline_delta = first_recovery_deadline_delta,
        .first_recovery_delta = first_recovery_tick - first_tick,
        .first_recovery_started = first_recovery_started,
        .recovery_response_accepted = recovery_response_accepted,
        .recovery_successes_after_accept = 1,
        .recovery_budget_reset = recovery_budget_reset,
        .recovered_timestamp = recovered_timestamp,
        .recovered_time_advanced = recovered_time_advanced,
        .second_timeout_delta = second_timeout_delta,
        .second_recovery_deadline_delta = second_recovery_deadline_delta,
        .second_recovery_delta = second_recovery_tick - recovered_tick,
        .second_recovery_started = second_recovery_started,
        .full_budget_restored = full_budget_restored,
        .health_reports_success = health_reports_success,
        .close_succeeded = close_succeeded,
        .requests_started = service.requests_started,
        .retries = service.retries,
        .retry_limit_hits = service.retry_limit_hits,
        .responses = service.responses,
        .quality_accepted = service.quality_accepted,
        .recovery_successes = service.recovery_successes,
        .automatic_recoveries = service.automatic_recoveries,
        .recovery_limit_hits = service.recovery_limit_hits,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}
fn verifyNtpAutomaticRecovery(
    device: *Device,
    counter: *time_reference.ContinuousCounter,
) ?NtpAutomaticRecoveryReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_188 or
        device.next_udp_generation != 47 or device.tx_producer != 5 or
        device.next_udp_identification != 42 or device.next_dns_transaction_id != 8 or
        completionQueueEnqueued(&tx_completion_queue) != 69 or
        completionQueueDequeued(&tx_completion_queue) != 69 or
        completionQueueEnqueued(&rx_completion_queue) != 22 or
        device.software_rx_queue.enqueued != 83 or device.software_rx_queue.dequeued != 83 or
        device.packets_dispatched != 72 or device.udp_packets_dispatched != 71 or
        counter.frequency_hz == 0 or counter.counter_bits == 0)
    {
        return null;
    }
    const server = [4]u8{ 10, 0, 2, 4 };
    const invalid_endpoint_count = device.udp_endpoint_count;
    const invalid_ephemeral_cursor = device.next_ephemeral_udp_port;
    const invalid_generation = device.next_udp_generation;
    const invalid_identification = device.next_udp_identification;
    const invalid_tx_cursor = device.tx_producer;
    const invalid_submissions = device.tx_submissions;
    const invalid_policy_rejected = openNtpServiceWithRecoveryPolicies(
        device,
        server,
        20,
        ntp.default_quality_policy,
        .{ .initial_interval_ticks = 1, .maximum_interval_ticks = 1, .maximum_retries = 1 },
        .{ .cooldown_ticks = 0, .maximum_recoveries = 2 },
    ) == null;
    const invalid_policy_state_preserved = device.udp_endpoint_count == invalid_endpoint_count and
        device.next_ephemeral_udp_port == invalid_ephemeral_cursor and
        device.next_udp_generation == invalid_generation and
        device.next_udp_identification == invalid_identification and
        device.tx_producer == invalid_tx_cursor and device.tx_submissions == invalid_submissions;
    if (!invalid_policy_rejected or !invalid_policy_state_preserved) return null;

    const retry_policy = ntp.RetryPolicy{
        .initial_interval_ticks = 1,
        .maximum_interval_ticks = 1,
        .maximum_retries = 1,
    };
    const recovery_policy = ntp.RecoveryPolicy{
        .cooldown_ticks = 2,
        .maximum_recoveries = 2,
    };
    var service = openNtpServiceWithRecoveryPolicies(
        device,
        server,
        20,
        ntp.default_quality_policy,
        retry_policy,
        recovery_policy,
    ) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 47 or socket.local_port != 49_188 or
        device.next_ephemeral_udp_port != 49_189 or device.next_udp_generation != 48 or
        device.udp_endpoint_count != 3 or !std.meta.eql(service.retry_policy, retry_policy) or
        service.recovery_policy == null or
        !std.meta.eql(service.recovery_policy.?, recovery_policy)) return null;

    const submissions_before = device.tx_submissions;
    const start_tick = counter.read();
    var transmit_identifications = [6]u16{ 0, 0, 0, 0, 0, 0 };
    var transmit_descriptors = [6]u16{ 0, 0, 0, 0, 0, 0 };
    var transmit_next_cursors = [6]u16{ 0, 0, 0, 0, 0, 0 };

    const initial = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const initial_tx = initial.transmit orelse return null;
    transmit_identifications[0] = initial_tx.identification;
    transmit_descriptors[0] = initial_tx.completion.descriptor_index;
    transmit_next_cursors[0] = initial_tx.completion.next_cursor;
    if (initial.state != .awaiting or initial.start_reason != .initial or initial.recovery_started or
        initial.recovery_state != null or initial.next_retry_interval_ticks != 1 or
        initial_tx.identification != 42 or initial_tx.completion.descriptor_index != 5 or
        initial_tx.completion.next_cursor != 6) return null;

    const first_retry = stepNtpServiceAutomatic(device, &service, counter, start_tick + 1, 0, 0) orelse return null;
    const first_retry_tx = first_retry.transmit orelse return null;
    transmit_identifications[1] = first_retry_tx.identification;
    transmit_descriptors[1] = first_retry_tx.completion.descriptor_index;
    transmit_next_cursors[1] = first_retry_tx.completion.next_cursor;
    if (!first_retry.retried or first_retry.next_retry_interval_ticks != 1 or
        first_retry_tx.identification != 43 or first_retry_tx.completion.descriptor_index != 6 or
        first_retry_tx.completion.next_cursor != 7) return null;

    const first_timeout = stepNtpServiceAutomatic(device, &service, counter, start_tick + 2, 0, 0) orelse return null;
    const first_timeout_delta = service.last_timeout_tick - start_tick;
    const first_recovery_deadline_delta = service.recovery_deadline_tick - start_tick;
    if (first_timeout.state != .timed_out or !first_timeout.timeout_reached or
        first_timeout.recovery_state != .waiting or first_timeout_delta != 2 or
        first_recovery_deadline_delta != 4 or !service.retry_exhausted or
        service.automatic_recoveries != 0 or service.recovery_exhausted)
    {
        return null;
    }

    const first_wait = stepNtpServiceAutomatic(device, &service, counter, start_tick + 3, 0, 0) orelse return null;
    const first_wait_no_tx = first_wait.state == .timed_out and first_wait.recovery_state == .waiting and
        first_wait.transmit == null and !first_wait.recovery_started and
        device.next_udp_identification == 44 and device.tx_producer == 7;
    if (!first_wait_no_tx) return null;

    const first_recovery = stepNtpServiceAutomatic(device, &service, counter, start_tick + 4, 0, 0) orelse return null;
    const first_recovery_tx = first_recovery.transmit orelse return null;
    transmit_identifications[2] = first_recovery_tx.identification;
    transmit_descriptors[2] = first_recovery_tx.completion.descriptor_index;
    transmit_next_cursors[2] = first_recovery_tx.completion.next_cursor;
    const first_recovery_started = first_recovery.state == .awaiting and
        first_recovery.start_reason == .recovery and first_recovery.recovery_state == .ready and
        first_recovery.recovery_started and first_recovery.next_retry_interval_ticks == 1 and
        first_recovery_tx.identification == 44 and first_recovery_tx.completion.descriptor_index == 7 and
        first_recovery_tx.completion.next_cursor == 0 and service.automatic_recoveries == 1;
    if (!first_recovery_started) return null;

    const second_retry = stepNtpServiceAutomatic(device, &service, counter, start_tick + 5, 0, 0) orelse return null;
    const second_retry_tx = second_retry.transmit orelse return null;
    transmit_identifications[3] = second_retry_tx.identification;
    transmit_descriptors[3] = second_retry_tx.completion.descriptor_index;
    transmit_next_cursors[3] = second_retry_tx.completion.next_cursor;
    if (!second_retry.retried or second_retry.next_retry_interval_ticks != 1 or
        second_retry_tx.identification != 45 or second_retry_tx.completion.descriptor_index != 0 or
        second_retry_tx.completion.next_cursor != 1) return null;

    const second_timeout = stepNtpServiceAutomatic(device, &service, counter, start_tick + 6, 0, 0) orelse return null;
    const second_timeout_delta = service.last_timeout_tick - start_tick;
    const second_recovery_deadline_delta = service.recovery_deadline_tick - start_tick;
    if (second_timeout.state != .timed_out or !second_timeout.timeout_reached or
        second_timeout.recovery_state != .waiting or second_timeout_delta != 6 or
        second_recovery_deadline_delta != 8 or service.automatic_recoveries != 1 or
        service.recovery_exhausted)
    {
        return null;
    }

    const second_wait = stepNtpServiceAutomatic(device, &service, counter, start_tick + 7, 0, 0) orelse return null;
    const second_wait_no_tx = second_wait.state == .timed_out and second_wait.recovery_state == .waiting and
        second_wait.transmit == null and !second_wait.recovery_started and
        device.next_udp_identification == 46 and device.tx_producer == 1;
    if (!second_wait_no_tx) return null;

    const second_recovery = stepNtpServiceAutomatic(device, &service, counter, start_tick + 8, 0, 0) orelse return null;
    const second_recovery_tx = second_recovery.transmit orelse return null;
    transmit_identifications[4] = second_recovery_tx.identification;
    transmit_descriptors[4] = second_recovery_tx.completion.descriptor_index;
    transmit_next_cursors[4] = second_recovery_tx.completion.next_cursor;
    const second_recovery_started = second_recovery.state == .awaiting and
        second_recovery.start_reason == .recovery and second_recovery.recovery_state == .ready and
        second_recovery.recovery_started and second_recovery.next_retry_interval_ticks == 1 and
        second_recovery_tx.identification == 46 and second_recovery_tx.completion.descriptor_index == 1 and
        second_recovery_tx.completion.next_cursor == 2 and service.automatic_recoveries == 2;
    if (!second_recovery_started) return null;

    const third_retry = stepNtpServiceAutomatic(device, &service, counter, start_tick + 9, 0, 0) orelse return null;
    const third_retry_tx = third_retry.transmit orelse return null;
    transmit_identifications[5] = third_retry_tx.identification;
    transmit_descriptors[5] = third_retry_tx.completion.descriptor_index;
    transmit_next_cursors[5] = third_retry_tx.completion.next_cursor;
    if (!third_retry.retried or third_retry.next_retry_interval_ticks != 1 or
        third_retry_tx.identification != 47 or third_retry_tx.completion.descriptor_index != 2 or
        third_retry_tx.completion.next_cursor != 3) return null;

    const terminal_timeout = stepNtpServiceAutomatic(device, &service, counter, start_tick + 10, 0, 0) orelse return null;
    const terminal_timeout_delta = service.last_timeout_tick - start_tick;
    const terminal_recovery_deadline_delta = service.recovery_deadline_tick - start_tick;
    const terminal_exhausted = terminal_timeout.state == .timed_out and terminal_timeout.timeout_reached and
        terminal_timeout.recovery_state == .exhausted and terminal_timeout.transmit == null and
        terminal_timeout_delta == 10 and terminal_recovery_deadline_delta == 12 and
        service.retry_exhausted and service.recovery_exhausted and
        service.automatic_recoveries == 2 and service.recovery_limit_hits == 1;
    if (!terminal_exhausted) return null;

    const terminal_snapshot = service;
    const id_at_terminal = device.next_udp_identification;
    const tx_at_terminal = device.tx_producer;
    const submissions_at_terminal = device.tx_submissions;
    const latched = stepNtpServiceAutomatic(device, &service, counter, start_tick + 11, 0, 0) orelse return null;
    const timeout_latched = latched.state == .timed_out and latched.recovery_state == .exhausted and
        !latched.timeout_reached and !latched.recovery_started and latched.transmit == null and
        std.meta.eql(service, terminal_snapshot) and device.next_udp_identification == id_at_terminal and
        device.tx_producer == tx_at_terminal and device.tx_submissions == submissions_at_terminal;
    if (!timeout_latched) return null;

    const health = readNtpServiceHealth(&service, start_tick + 11, 4, 8) orelse return null;
    const health_reports_exhaustion = health.state == .unsynchronized and health.current_time == null and
        !health.awaiting_response and health.retry_exhausted and health.retry_limit_hits == 3 and
        health.recovery_deadline_tick == start_tick + 12 and health.automatic_recoveries == 2 and
        health.recovery_exhausted and health.recovery_limit_hits == 1 and
        health.last_timeout_tick == start_tick + 10;
    if (!health_reports_exhaustion) return null;

    const bootstrap_timestamp_preserved = service.request.client_timestamp == ntp.fixture_client_timestamp;
    const close_succeeded = closeNtpService(device, &service);
    if (!bootstrap_timestamp_preserved or !close_succeeded or service.active or service.client.active or
        service.request_active or !service.request.cancelled) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_189 or
        device.next_udp_generation != 48 or device.next_udp_identification != 48 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 3 or
        device.tx_submissions != submissions_before + 6 or txe != 75 or txd != 75 or rxe != 22 or
        overflow != 0 or device.software_rx_queue.enqueued != 83 or
        device.software_rx_queue.dequeued != 83 or device.packets_dispatched != 72 or
        device.udp_packets_dispatched != 71) return null;

    return .{
        .source_kind = counter.reference.kind,
        .frequency_hz = counter.frequency_hz,
        .counter_bits = counter.counter_bits,
        .invalid_policy_rejected = invalid_policy_rejected,
        .invalid_policy_state_preserved = invalid_policy_state_preserved,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .retry_initial_ticks = retry_policy.initial_interval_ticks,
        .retry_maximum_ticks = retry_policy.maximum_interval_ticks,
        .retry_maximum_retries = retry_policy.maximum_retries,
        .recovery_cooldown_ticks = recovery_policy.cooldown_ticks,
        .recovery_maximum_recoveries = recovery_policy.maximum_recoveries,
        .transmit_identifications = transmit_identifications,
        .transmit_descriptors = transmit_descriptors,
        .transmit_next_cursors = transmit_next_cursors,
        .first_timeout_delta = first_timeout_delta,
        .first_recovery_deadline_delta = first_recovery_deadline_delta,
        .first_wait_no_tx = first_wait_no_tx,
        .first_recovery_delta = 4,
        .first_recovery_started = first_recovery_started,
        .second_timeout_delta = second_timeout_delta,
        .second_recovery_deadline_delta = second_recovery_deadline_delta,
        .second_wait_no_tx = second_wait_no_tx,
        .second_recovery_delta = 8,
        .second_recovery_started = second_recovery_started,
        .terminal_timeout_delta = terminal_timeout_delta,
        .terminal_recovery_deadline_delta = terminal_recovery_deadline_delta,
        .terminal_exhausted = terminal_exhausted,
        .timeout_latched = timeout_latched,
        .health_reports_exhaustion = health_reports_exhaustion,
        .bootstrap_timestamp_preserved = bootstrap_timestamp_preserved,
        .requests_started = service.requests_started,
        .retries = service.retries,
        .retry_limit_hits = service.retry_limit_hits,
        .automatic_recoveries = service.automatic_recoveries,
        .recovery_limit_hits = service.recovery_limit_hits,
        .close_succeeded = close_succeeded,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}
fn verifyNtpServiceBackoff(
    device: *Device,
    counter: *time_reference.ContinuousCounter,
) ?NtpBackoffReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_187 or
        device.next_udp_generation != 46 or device.tx_producer != 0 or
        device.next_udp_identification != 37 or device.next_dns_transaction_id != 8 or
        counter.frequency_hz == 0 or counter.counter_bits == 0)
        return null;
    const server = [4]u8{ 10, 0, 2, 4 };
    const invalid_endpoint_count = device.udp_endpoint_count;
    const invalid_ephemeral_cursor = device.next_ephemeral_udp_port;
    const invalid_generation = device.next_udp_generation;
    const invalid_identification = device.next_udp_identification;
    const invalid_tx_cursor = device.tx_producer;
    const invalid_submissions = device.tx_submissions;
    const invalid_policy_rejected = openNtpServiceWithPolicies(
        device,
        server,
        20,
        ntp.default_quality_policy,
        .{ .initial_interval_ticks = 4, .maximum_interval_ticks = 2, .maximum_retries = 3 },
    ) == null;
    const invalid_policy_state_preserved = device.udp_endpoint_count == invalid_endpoint_count and
        device.next_ephemeral_udp_port == invalid_ephemeral_cursor and
        device.next_udp_generation == invalid_generation and
        device.next_udp_identification == invalid_identification and
        device.tx_producer == invalid_tx_cursor and device.tx_submissions == invalid_submissions;
    if (!invalid_policy_rejected or !invalid_policy_state_preserved) return null;

    const retry_policy = ntp.RetryPolicy{
        .initial_interval_ticks = 1,
        .maximum_interval_ticks = 4,
        .maximum_retries = 3,
    };
    var service = openNtpServiceWithPolicies(
        device,
        server,
        20,
        ntp.default_quality_policy,
        retry_policy,
    ) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 46 or socket.local_port != 49_187 or
        device.next_ephemeral_udp_port != 49_188 or device.next_udp_generation != 47 or
        device.udp_endpoint_count != 3 or !std.meta.eql(service.retry_policy, retry_policy)) return null;
    const submissions_before = device.tx_submissions;
    const start_tick = counter.read();

    const initial = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const initial_tx = initial.transmit orelse return null;
    const initial_wait = initial.next_retry_interval_ticks orelse return null;
    if (initial.state != .awaiting or initial.start_reason != .initial or initial_wait != 1 or
        initial_tx.identification != 37 or initial_tx.completion.descriptor_index != 0 or
        initial_tx.completion.next_cursor != 1 or service.retry_deadline_tick != start_tick + 1 or
        service.request_retry_attempts != 0 or service.requests_started != 1) return null;

    const early = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 0) orelse return null;
    const early_no_tx = early.state == .awaiting and early.transmit == null and !early.retried and
        !early.timeout_reached and service.request_retry_attempts == 0 and
        service.retry_deadline_tick == start_tick + 1;
    if (!early_no_tx) return null;

    const first_retry = stepNtpServiceAutomatic(device, &service, counter, start_tick + 1, 0, 0) orelse return null;
    const first_retry_tx = first_retry.transmit orelse return null;
    const first_retry_wait = first_retry.next_retry_interval_ticks orelse return null;
    if (!first_retry.retried or first_retry_wait != 2 or first_retry_tx.identification != 38 or
        first_retry_tx.completion.descriptor_index != 1 or first_retry_tx.completion.next_cursor != 2 or
        service.request_retry_attempts != 1 or service.retry_deadline_tick != start_tick + 3)
        return null;

    const between_first_second = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick + 2,
        0,
        0,
    ) orelse return null;
    if (between_first_second.transmit != null or between_first_second.retried or
        between_first_second.timeout_reached or service.request_retry_attempts != 1)
        return null;

    const second_retry = stepNtpServiceAutomatic(device, &service, counter, start_tick + 3, 0, 0) orelse return null;
    const second_retry_tx = second_retry.transmit orelse return null;
    const second_retry_wait = second_retry.next_retry_interval_ticks orelse return null;
    if (!second_retry.retried or second_retry_wait != 4 or second_retry_tx.identification != 39 or
        second_retry_tx.completion.descriptor_index != 2 or second_retry_tx.completion.next_cursor != 3 or
        service.request_retry_attempts != 2 or service.retry_deadline_tick != start_tick + 7)
        return null;

    const third_retry = stepNtpServiceAutomatic(device, &service, counter, start_tick + 7, 0, 0) orelse return null;
    const third_retry_tx = third_retry.transmit orelse return null;
    const third_retry_wait = third_retry.next_retry_interval_ticks orelse return null;
    if (!third_retry.retried or third_retry_wait != 4 or third_retry_tx.identification != 40 or
        third_retry_tx.completion.descriptor_index != 3 or third_retry_tx.completion.next_cursor != 4 or
        service.request_retry_attempts != 3 or service.retry_deadline_tick != start_tick + 11)
        return null;

    const before_timeout = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick + 10,
        0,
        0,
    ) orelse return null;
    if (before_timeout.transmit != null or before_timeout.retried or before_timeout.timeout_reached or
        service.retry_exhausted or !service.request_active) return null;

    const timeout = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick + 11,
        0,
        0,
    ) orelse return null;
    const timeout_tick_delta = service.last_timeout_tick - start_tick;
    const request_cancelled = service.request.cancelled;
    if (timeout.state != .timed_out or !timeout.timeout_reached or timeout.transmit != null or
        timeout.next_retry_interval_ticks != null or service.request_active or !request_cancelled or
        !service.retry_exhausted or service.retry_limit_hits != 1 or timeout_tick_delta != 11 or
        service.retries != 3) return null;

    const timeout_snapshot = service;
    const id_at_timeout = device.next_udp_identification;
    const tx_at_timeout = device.tx_producer;
    const submissions_at_timeout = device.tx_submissions;
    const latched = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick + 12,
        0,
        0,
    ) orelse return null;
    const timeout_latched = latched.state == .timed_out and !latched.timeout_reached and
        latched.transmit == null and std.meta.eql(service, timeout_snapshot) and
        device.next_udp_identification == id_at_timeout and device.tx_producer == tx_at_timeout and
        device.tx_submissions == submissions_at_timeout;
    if (!timeout_latched) return null;

    const health = readNtpServiceHealth(&service, start_tick + 12, 4, 8) orelse return null;
    const health_reports_exhaustion = health.state == .unsynchronized and health.current_time == null and
        !health.awaiting_response and health.request_retry_attempts == 3 and health.retry_exhausted and
        health.retry_limit_hits == 1 and health.last_timeout_tick == start_tick + 11;
    if (!health_reports_exhaustion) return null;

    const clear_succeeded = clearNtpServiceTimeout(&service);
    const duplicate_clear_rejected = !clearNtpServiceTimeout(&service);
    if (!clear_succeeded or !duplicate_clear_rejected or service.retry_exhausted or
        service.request_retry_attempts != 0) return null;

    const restart = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick + 12,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const restart_tx = restart.transmit orelse return null;
    const restart_wait = restart.next_retry_interval_ticks orelse return null;
    if (restart.state != .awaiting or restart.start_reason != .initial or restart_wait != 1 or
        restart_tx.identification != 41 or restart_tx.completion.descriptor_index != 4 or
        restart_tx.completion.next_cursor != 5 or service.requests_started != 2 or
        service.request_retry_attempts != 0 or service.retry_exhausted)
        return null;

    const close_succeeded = closeNtpService(device, &service);
    if (!close_succeeded or service.active or service.client.active or service.request_active or
        !service.request.cancelled) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_188 or
        device.next_udp_generation != 47 or device.next_udp_identification != 42 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 5 or
        device.tx_submissions != submissions_before + 5 or txe != 69 or txd != 69 or rxe != 22 or
        overflow != 0 or device.software_rx_queue.enqueued != 83 or
        device.software_rx_queue.dequeued != 83 or device.packets_dispatched != 72 or
        device.udp_packets_dispatched != 71) return null;

    return .{
        .source_kind = counter.reference.kind,
        .frequency_hz = counter.frequency_hz,
        .counter_bits = counter.counter_bits,
        .invalid_policy_rejected = invalid_policy_rejected,
        .invalid_policy_state_preserved = invalid_policy_state_preserved,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .initial_interval_ticks = retry_policy.initial_interval_ticks,
        .maximum_interval_ticks = retry_policy.maximum_interval_ticks,
        .maximum_retries = retry_policy.maximum_retries,
        .initial_identification = initial_tx.identification,
        .initial_descriptor = initial_tx.completion.descriptor_index,
        .initial_next_cursor = initial_tx.completion.next_cursor,
        .initial_wait_ticks = initial_wait,
        .early_no_tx = early_no_tx,
        .retry_identifications = .{
            first_retry_tx.identification,
            second_retry_tx.identification,
            third_retry_tx.identification,
        },
        .retry_descriptors = .{
            first_retry_tx.completion.descriptor_index,
            second_retry_tx.completion.descriptor_index,
            third_retry_tx.completion.descriptor_index,
        },
        .retry_next_cursors = .{
            first_retry_tx.completion.next_cursor,
            second_retry_tx.completion.next_cursor,
            third_retry_tx.completion.next_cursor,
        },
        .retry_wait_ticks = .{ first_retry_wait, second_retry_wait, third_retry_wait },
        .timeout_tick_delta = timeout_tick_delta,
        .timeout_state = timeout.state,
        .timeout_reached = timeout.timeout_reached,
        .request_cancelled = request_cancelled,
        .retry_exhausted = timeout_snapshot.retry_exhausted,
        .timeout_latched = timeout_latched,
        .health_reports_exhaustion = health_reports_exhaustion,
        .clear_succeeded = clear_succeeded,
        .duplicate_clear_rejected = duplicate_clear_rejected,
        .restart_identification = restart_tx.identification,
        .restart_descriptor = restart_tx.completion.descriptor_index,
        .restart_next_cursor = restart_tx.completion.next_cursor,
        .restart_wait_ticks = restart_wait,
        .close_succeeded = close_succeeded,
        .requests_started = service.requests_started,
        .retries = service.retries,
        .retry_limit_hits = service.retry_limit_hits,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}
fn verifyNtpSourcePool() ?NtpSourcePoolReport {
    const zero_pool = ntp.SourcePool{
        .count = 0,
        .servers = std.mem.zeroes([ntp.maximum_source_pool_entries][4]u8),
    };
    var single_pool = zero_pool;
    single_pool.count = 1;
    single_pool.servers[0] = .{ 10, 0, 2, 4 };
    var too_many_pool = single_pool;
    too_many_pool.count = ntp.maximum_source_pool_entries + 1;

    var zero_address_pool = zero_pool;
    zero_address_pool.count = 2;
    zero_address_pool.servers[0] = .{ 10, 0, 2, 4 };
    zero_address_pool.servers[1] = .{ 0, 0, 0, 0 };

    var duplicate_pool = zero_pool;
    duplicate_pool.count = 2;
    duplicate_pool.servers[0] = .{ 10, 0, 2, 4 };
    duplicate_pool.servers[1] = .{ 10, 0, 2, 4 };

    var two_pool = zero_pool;
    two_pool.count = 2;
    two_pool.servers[0] = .{ 10, 0, 2, 4 };
    two_pool.servers[1] = .{ 10, 0, 2, 5 };
    const first = ntp.sourcePoolServer(two_pool, 0) orelse return null;
    const second = ntp.sourcePoolServer(two_pool, 1) orelse return null;

    var maximum_pool = zero_pool;
    maximum_pool.count = ntp.maximum_source_pool_entries;
    maximum_pool.servers[0] = .{ 10, 0, 2, 4 };
    maximum_pool.servers[1] = .{ 10, 0, 2, 5 };
    maximum_pool.servers[2] = .{ 10, 0, 2, 6 };
    maximum_pool.servers[3] = .{ 10, 0, 2, 7 };
    const maximum_last = ntp.sourcePoolServer(maximum_pool, 3) orelse return null;

    const invalid_zero_count_rejected = !ntp.sourcePoolValid(zero_pool);
    const invalid_single_count_rejected = !ntp.sourcePoolValid(single_pool);
    const invalid_too_many_rejected = !ntp.sourcePoolValid(too_many_pool);
    const invalid_zero_address_rejected = !ntp.sourcePoolValid(zero_address_pool);
    const invalid_duplicate_rejected = !ntp.sourcePoolValid(duplicate_pool);
    const valid_two_sources = ntp.sourcePoolValid(two_pool) and
        std.meta.eql(first, two_pool.servers[0]) and std.meta.eql(second, two_pool.servers[1]);
    const valid_maximum_sources = ntp.sourcePoolValid(maximum_pool) and
        std.meta.eql(maximum_last, maximum_pool.servers[3]);
    const out_of_range_rejected = ntp.sourcePoolServer(two_pool, 2) == null;
    const invalid_pool_lookup_rejected = ntp.sourcePoolServer(duplicate_pool, 0) == null;
    const unused_slots_ignored = std.meta.eql(two_pool.servers[2], [4]u8{ 0, 0, 0, 0 }) and
        std.meta.eql(two_pool.servers[3], [4]u8{ 0, 0, 0, 0 }) and ntp.sourcePoolValid(two_pool);

    if (!invalid_zero_count_rejected or !invalid_single_count_rejected or
        !invalid_too_many_rejected or !invalid_zero_address_rejected or
        !invalid_duplicate_rejected or !valid_two_sources or !valid_maximum_sources or
        !out_of_range_rejected or !invalid_pool_lookup_rejected or !unused_slots_ignored)
    {
        return null;
    }
    return .{
        .invalid_zero_count_rejected = invalid_zero_count_rejected,
        .invalid_single_count_rejected = invalid_single_count_rejected,
        .invalid_too_many_rejected = invalid_too_many_rejected,
        .invalid_zero_address_rejected = invalid_zero_address_rejected,
        .invalid_duplicate_rejected = invalid_duplicate_rejected,
        .valid_two_sources = valid_two_sources,
        .valid_maximum_sources = valid_maximum_sources,
        .first_source = first,
        .second_source = second,
        .maximum_last_source = maximum_last,
        .out_of_range_rejected = out_of_range_rejected,
        .invalid_pool_lookup_rejected = invalid_pool_lookup_rejected,
        .unused_slots_ignored = unused_slots_ignored,
    };
}

fn verifyNtpSourceRotationPolicy() ?NtpSourceRotationPolicyReport {
    const invalid_zero_sources = ntp.evaluateSourceRotation(
        .{ .source_count = 0, .failures_before_rotation = 2 },
        0,
        0,
    );
    const invalid_single_source = ntp.evaluateSourceRotation(
        .{ .source_count = 1, .failures_before_rotation = 2 },
        0,
        0,
    );
    const invalid_zero_threshold = ntp.evaluateSourceRotation(
        .{ .source_count = 3, .failures_before_rotation = 0 },
        0,
        0,
    );
    const policy = ntp.SourceRotationPolicy{
        .source_count = 3,
        .failures_before_rotation = 2,
    };
    const invalid_source = ntp.evaluateSourceRotation(policy, 3, 0);
    const zero = ntp.evaluateSourceRotation(policy, 1, 0);
    const first = ntp.evaluateSourceRotation(policy, 1, 1);
    const boundary = ntp.evaluateSourceRotation(policy, 1, 2);
    const beyond = ntp.evaluateSourceRotation(policy, 1, 3);
    const wrap = ntp.evaluateSourceRotation(policy, 2, 2);
    const maximum = ntp.SourceRotationPolicy{
        .source_count = std.math.maxInt(u8),
        .failures_before_rotation = std.math.maxInt(u8),
    };
    const maximum_penultimate = ntp.evaluateSourceRotation(
        maximum,
        std.math.maxInt(u8) - 1,
        std.math.maxInt(u8) - 1,
    );
    const maximum_boundary = ntp.evaluateSourceRotation(
        maximum,
        std.math.maxInt(u8) - 1,
        std.math.maxInt(u8),
    );

    const invalid_zero_sources_rejected = invalid_zero_sources.action == .invalid_policy;
    const invalid_single_source_rejected = invalid_single_source.action == .invalid_policy;
    const invalid_zero_threshold_rejected = invalid_zero_threshold.action == .invalid_policy;
    const invalid_source_index_rejected = invalid_source.action == .invalid_source and
        invalid_source.next_source_index == 0 and invalid_source.remaining_before_rotation == 0;
    const zero_failures_stay = zero.action == .stay and zero.next_source_index == 1;
    const first_failure_stay = first.action == .stay and first.next_source_index == 1;
    const boundary_rotates = boundary.action == .rotate;
    const beyond_rotates = beyond.action == .rotate;
    const wrap_rotates = wrap.action == .rotate;
    const maximum_penultimate_stays = maximum_penultimate.action == .stay and
        maximum_penultimate.next_source_index == std.math.maxInt(u8) - 1 and
        maximum_penultimate.remaining_before_rotation == 1;
    const maximum_boundary_rotates = maximum_boundary.action == .rotate;

    if (!invalid_zero_sources_rejected or !invalid_single_source_rejected or
        !invalid_zero_threshold_rejected or !invalid_source_index_rejected or
        !zero_failures_stay or zero.remaining_before_rotation != 2 or
        !first_failure_stay or first.remaining_before_rotation != 1 or
        !boundary_rotates or boundary.next_source_index != 2 or boundary.remaining_before_rotation != 0 or
        !beyond_rotates or beyond.next_source_index != 2 or beyond.remaining_before_rotation != 0 or
        !wrap_rotates or wrap.next_source_index != 0 or
        !maximum_penultimate_stays or !maximum_boundary_rotates or
        maximum_boundary.next_source_index != 0 or maximum_boundary.remaining_before_rotation != 0)
    {
        return null;
    }

    return .{
        .invalid_zero_sources_rejected = invalid_zero_sources_rejected,
        .invalid_single_source_rejected = invalid_single_source_rejected,
        .invalid_zero_threshold_rejected = invalid_zero_threshold_rejected,
        .invalid_source_index_rejected = invalid_source_index_rejected,
        .zero_failures_stay = zero_failures_stay,
        .zero_remaining = zero.remaining_before_rotation,
        .first_failure_stay = first_failure_stay,
        .first_remaining = first.remaining_before_rotation,
        .boundary_rotates = boundary_rotates,
        .boundary_next_source = boundary.next_source_index,
        .beyond_rotates = beyond_rotates,
        .beyond_next_source = beyond.next_source_index,
        .wrap_rotates = wrap_rotates,
        .wrap_next_source = wrap.next_source_index,
        .maximum_penultimate_stays = maximum_penultimate_stays,
        .maximum_boundary_rotates = maximum_boundary_rotates,
        .maximum_boundary_next_source = maximum_boundary.next_source_index,
    };
}

fn verifyNtpQualityRejectionPolicy() ?NtpQualityRejectionPolicyReport {
    const invalid = ntp.evaluateQualityRejectionBudget(
        .{ .maximum_rejections_per_request = 0 },
        0,
    );
    const policy = ntp.QualityRejectionPolicy{ .maximum_rejections_per_request = 3 };
    const zero = ntp.evaluateQualityRejectionBudget(policy, 0);
    const first = ntp.evaluateQualityRejectionBudget(policy, 1);
    const penultimate = ntp.evaluateQualityRejectionBudget(policy, 2);
    const boundary = ntp.evaluateQualityRejectionBudget(policy, 3);
    const beyond = ntp.evaluateQualityRejectionBudget(policy, 4);
    const maximum = ntp.QualityRejectionPolicy{ .maximum_rejections_per_request = std.math.maxInt(u8) };
    const maximum_penultimate = ntp.evaluateQualityRejectionBudget(maximum, std.math.maxInt(u8) - 1);
    const maximum_boundary = ntp.evaluateQualityRejectionBudget(maximum, std.math.maxInt(u8));

    const invalid_zero_rejected = invalid.action == .invalid_policy and
        invalid.remaining_before_retry == 0;
    const zero_count_retained = zero.action == .retain_request;
    const first_retained = first.action == .retain_request;
    const penultimate_retained = penultimate.action == .retain_request;
    const boundary_retries = boundary.action == .retry_now;
    const beyond_retries = beyond.action == .retry_now and beyond.remaining_before_retry == 0;
    const maximum_penultimate_retained = maximum_penultimate.action == .retain_request and
        maximum_penultimate.remaining_before_retry == 1;
    const maximum_boundary_retries = maximum_boundary.action == .retry_now and
        maximum_boundary.remaining_before_retry == 0;

    if (!invalid_zero_rejected or !zero_count_retained or zero.remaining_before_retry != 3 or
        !first_retained or first.remaining_before_retry != 2 or !penultimate_retained or
        penultimate.remaining_before_retry != 1 or !boundary_retries or
        boundary.remaining_before_retry != 0 or !beyond_retries or
        !maximum_penultimate_retained or !maximum_boundary_retries)
    {
        return null;
    }
    return .{
        .invalid_zero_rejected = invalid_zero_rejected,
        .zero_count_retained = zero_count_retained,
        .zero_count_remaining = zero.remaining_before_retry,
        .first_retained = first_retained,
        .first_remaining = first.remaining_before_retry,
        .penultimate_retained = penultimate_retained,
        .penultimate_remaining = penultimate.remaining_before_retry,
        .boundary_retries = boundary_retries,
        .boundary_remaining = boundary.remaining_before_retry,
        .beyond_retries = beyond_retries,
        .maximum_penultimate_retained = maximum_penultimate_retained,
        .maximum_boundary_retries = maximum_boundary_retries,
    };
}

fn verifyNtpStepRejectionPolicy() ?NtpStepRejectionPolicyReport {
    const invalid = ntp.evaluateStepRejectionBudget(
        .{ .maximum_rejections_per_request = 0 },
        0,
    );
    const policy = ntp.StepRejectionPolicy{ .maximum_rejections_per_request = 3 };
    const zero = ntp.evaluateStepRejectionBudget(policy, 0);
    const first = ntp.evaluateStepRejectionBudget(policy, 1);
    const penultimate = ntp.evaluateStepRejectionBudget(policy, 2);
    const boundary = ntp.evaluateStepRejectionBudget(policy, 3);
    const beyond = ntp.evaluateStepRejectionBudget(policy, 4);
    const maximum = ntp.StepRejectionPolicy{ .maximum_rejections_per_request = std.math.maxInt(u8) };
    const maximum_penultimate = ntp.evaluateStepRejectionBudget(maximum, std.math.maxInt(u8) - 1);
    const maximum_boundary = ntp.evaluateStepRejectionBudget(maximum, std.math.maxInt(u8));

    const invalid_zero_rejected = invalid.action == .invalid_policy and
        invalid.remaining_before_retry == 0;
    const zero_count_retained = zero.action == .retain_request;
    const first_retained = first.action == .retain_request;
    const penultimate_retained = penultimate.action == .retain_request;
    const boundary_retries = boundary.action == .retry_now;
    const beyond_retries = beyond.action == .retry_now and beyond.remaining_before_retry == 0;
    const maximum_penultimate_retained = maximum_penultimate.action == .retain_request and
        maximum_penultimate.remaining_before_retry == 1;
    const maximum_boundary_retries = maximum_boundary.action == .retry_now and
        maximum_boundary.remaining_before_retry == 0;

    if (!invalid_zero_rejected or !zero_count_retained or zero.remaining_before_retry != 3 or
        !first_retained or first.remaining_before_retry != 2 or !penultimate_retained or
        penultimate.remaining_before_retry != 1 or !boundary_retries or
        boundary.remaining_before_retry != 0 or !beyond_retries or
        !maximum_penultimate_retained or !maximum_boundary_retries)
    {
        return null;
    }
    return .{
        .invalid_zero_rejected = invalid_zero_rejected,
        .zero_count_retained = zero_count_retained,
        .zero_count_remaining = zero.remaining_before_retry,
        .first_retained = first_retained,
        .first_remaining = first.remaining_before_retry,
        .penultimate_retained = penultimate_retained,
        .penultimate_remaining = penultimate.remaining_before_retry,
        .boundary_retries = boundary_retries,
        .boundary_remaining = boundary.remaining_before_retry,
        .beyond_retries = beyond_retries,
        .maximum_penultimate_retained = maximum_penultimate_retained,
        .maximum_boundary_retries = maximum_boundary_retries,
    };
}
fn verifyNtpStepPolicy() ?NtpStepPolicyReport {
    const policy = ntp.ClockStepPolicy{
        .maximum_forward_seconds = 1,
        .maximum_forward_fraction = 0x80000000,
    };
    const invalid_zero_rejected = ntp.evaluateClockStep(
        .{ .seconds = 100, .fraction = 0 },
        .{ .seconds = 101, .fraction = 0 },
        .{ .maximum_forward_seconds = 0, .maximum_forward_fraction = 0 },
    ) == .invalid_policy;

    var unsynchronized = std.mem.zeroes(ntp.ProjectedClock);
    const initial_response = ntp.Response{
        .leap_indicator = 0,
        .version = 4,
        .stratum = 2,
        .poll = 6,
        .precision = -20,
        .root_delay = 0,
        .root_dispersion = 0,
        .reference_id = .{ 'S', 'T', 'E', 'P' },
        .receive_timestamp = ntp.fixture_server_timestamp,
        .transmit_timestamp = ntp.fixture_server_timestamp,
        .unix_seconds = ntp.fixture_unix_seconds,
        .unix_fraction = 0x80000000,
    };
    const unsynchronized_initial_accepted =
        ntp.evaluateResponseStepAt(&unsynchronized, initial_response, 100, policy) == .accepted;

    const current_borrow = ntp.UnixTime{ .seconds = 1_800_000_000, .fraction = 0xC0000000 };
    const exact_borrow = ntp.UnixTime{ .seconds = 1_800_000_002, .fraction = 0x40000000 };
    const excessive_fraction = ntp.UnixTime{ .seconds = 1_800_000_002, .fraction = 0x40000001 };
    const excessive_seconds = ntp.UnixTime{ .seconds = 1_800_000_002, .fraction = 0xC0000000 };
    const borrow_delta = ntp.forwardTimeDelta(current_borrow, exact_borrow) orelse return null;

    const current_no_borrow = ntp.UnixTime{ .seconds = 1_800_000_000, .fraction = 0x20000000 };
    const exact_no_borrow = ntp.UnixTime{ .seconds = 1_800_000_001, .fraction = 0xA0000000 };
    const no_borrow_delta = ntp.forwardTimeDelta(current_no_borrow, exact_no_borrow) orelse return null;

    const stale_equal_rejected = ntp.evaluateClockStep(current_borrow, current_borrow, policy) == .stale;
    const stale_behind_rejected = ntp.evaluateClockStep(
        current_borrow,
        .{ .seconds = current_borrow.seconds, .fraction = current_borrow.fraction - 1 },
        policy,
    ) == .stale;
    const exact_borrow_accepted = ntp.evaluateClockStep(current_borrow, exact_borrow, policy) == .accepted;
    const exact_no_borrow_accepted = ntp.evaluateClockStep(
        current_no_borrow,
        exact_no_borrow,
        policy,
    ) == .accepted;
    const excessive_fraction_rejected = ntp.evaluateClockStep(
        current_borrow,
        excessive_fraction,
        policy,
    ) == .excessive_forward_step;
    const excessive_seconds_rejected = ntp.evaluateClockStep(
        current_borrow,
        excessive_seconds,
        policy,
    ) == .excessive_forward_step;

    if (!invalid_zero_rejected or !unsynchronized_initial_accepted or
        !stale_equal_rejected or !stale_behind_rejected or !exact_borrow_accepted or
        !exact_no_borrow_accepted or !excessive_fraction_rejected or
        !excessive_seconds_rejected or borrow_delta.seconds != 1 or
        borrow_delta.fraction != 0x80000000 or no_borrow_delta.seconds != 1 or
        no_borrow_delta.fraction != 0x80000000)
    {
        return null;
    }
    return .{
        .invalid_zero_rejected = invalid_zero_rejected,
        .unsynchronized_initial_accepted = unsynchronized_initial_accepted,
        .stale_equal_rejected = stale_equal_rejected,
        .stale_behind_rejected = stale_behind_rejected,
        .exact_borrow_accepted = exact_borrow_accepted,
        .exact_no_borrow_accepted = exact_no_borrow_accepted,
        .excessive_fraction_rejected = excessive_fraction_rejected,
        .excessive_seconds_rejected = excessive_seconds_rejected,
        .borrow_delta_seconds = borrow_delta.seconds,
        .borrow_delta_fraction = borrow_delta.fraction,
        .no_borrow_delta_seconds = no_borrow_delta.seconds,
        .no_borrow_delta_fraction = no_borrow_delta.fraction,
    };
}
fn verifyNtpRecoveryPolicy() ?NtpRecoveryPolicyReport {
    const invalid_zero_cooldown = ntp.evaluateRecovery(
        .{ .cooldown_ticks = 0, .maximum_recoveries = 2 },
        100,
        0,
        100,
    );
    const invalid_zero_recoveries = ntp.evaluateRecovery(
        .{ .cooldown_ticks = 10, .maximum_recoveries = 0 },
        100,
        0,
        100,
    );
    const policy = ntp.RecoveryPolicy{
        .cooldown_ticks = 10,
        .maximum_recoveries = 2,
    };
    const waiting = ntp.evaluateRecovery(policy, 100, 0, 109);
    const ready = ntp.evaluateRecovery(policy, 100, 0, 110);
    const second_ready = ntp.evaluateRecovery(policy, 100, 1, 110);
    const exhausted = ntp.evaluateRecovery(policy, 100, 2, 110);
    const maximum = std.math.maxInt(u64);
    const overflow_policy = ntp.RecoveryPolicy{
        .cooldown_ticks = 10,
        .maximum_recoveries = 1,
    };
    const overflow_wait = ntp.evaluateRecovery(overflow_policy, maximum - 4, 0, maximum - 1);
    const overflow_ready_decision = ntp.evaluateRecovery(overflow_policy, maximum - 4, 0, maximum);

    const invalid_zero_cooldown_rejected = invalid_zero_cooldown.state == .invalid_policy and
        invalid_zero_cooldown.deadline_tick == 0;
    const invalid_zero_recoveries_rejected = invalid_zero_recoveries.state == .invalid_policy and
        invalid_zero_recoveries.deadline_tick == 0;
    const waiting_before_deadline = waiting.state == .waiting and waiting.deadline_tick == 110;
    const ready_at_deadline = ready.state == .ready and ready.deadline_tick == 110;
    const second_recovery_ready = second_ready.state == .ready and second_ready.deadline_tick == 110;
    const exhausted_at_limit = exhausted.state == .exhausted and exhausted.deadline_tick == 110;
    const overflow_waiting = overflow_wait.state == .waiting and overflow_wait.deadline_tick == maximum;
    const overflow_ready = overflow_ready_decision.state == .ready and
        overflow_ready_decision.deadline_tick == maximum;

    if (!invalid_zero_cooldown_rejected or !invalid_zero_recoveries_rejected or
        !waiting_before_deadline or !ready_at_deadline or !second_recovery_ready or
        !exhausted_at_limit or !overflow_waiting or !overflow_ready)
    {
        return null;
    }
    return .{
        .invalid_zero_cooldown_rejected = invalid_zero_cooldown_rejected,
        .invalid_zero_recoveries_rejected = invalid_zero_recoveries_rejected,
        .deadline_tick = waiting.deadline_tick,
        .waiting_before_deadline = waiting_before_deadline,
        .ready_at_deadline = ready_at_deadline,
        .second_recovery_ready = second_recovery_ready,
        .exhausted_at_limit = exhausted_at_limit,
        .overflow_deadline_tick = overflow_wait.deadline_tick,
        .overflow_waiting = overflow_waiting,
        .overflow_ready = overflow_ready,
    };
}
fn verifyNtpRetryPolicy() ?NtpRetryPolicyReport {
    const invalid_zero_initial_rejected = !ntp.retryPolicyValid(.{
        .initial_interval_ticks = 0,
        .maximum_interval_ticks = 8,
        .maximum_retries = 4,
    });
    const invalid_cap_rejected = !ntp.retryPolicyValid(.{
        .initial_interval_ticks = 8,
        .maximum_interval_ticks = 4,
        .maximum_retries = 4,
    });
    const invalid_zero_retries_rejected = !ntp.retryPolicyValid(.{
        .initial_interval_ticks = 1,
        .maximum_interval_ticks = 8,
        .maximum_retries = 0,
    });
    const exponential = ntp.RetryPolicy{
        .initial_interval_ticks = 3,
        .maximum_interval_ticks = 10,
        .maximum_retries = 4,
    };
    const intervals = [4]u64{
        ntp.retryIntervalForAttempt(exponential, 0) orelse return null,
        ntp.retryIntervalForAttempt(exponential, 1) orelse return null,
        ntp.retryIntervalForAttempt(exponential, 2) orelse return null,
        ntp.retryIntervalForAttempt(exponential, 3) orelse return null,
    };
    const limit_rejected = ntp.retryIntervalForAttempt(exponential, 4) == null;
    const fixed = ntp.RetryPolicy{
        .initial_interval_ticks = 5,
        .maximum_interval_ticks = 5,
        .maximum_retries = 3,
    };
    const fixed_intervals = [3]u64{
        ntp.retryIntervalForAttempt(fixed, 0) orelse return null,
        ntp.retryIntervalForAttempt(fixed, 1) orelse return null,
        ntp.retryIntervalForAttempt(fixed, 2) orelse return null,
    };
    const maximum_value = std.math.maxInt(u64);
    const overflow_policy = ntp.RetryPolicy{
        .initial_interval_ticks = maximum_value - 1,
        .maximum_interval_ticks = maximum_value,
        .maximum_retries = 2,
    };
    const overflow_saturated = ntp.retryIntervalForAttempt(overflow_policy, 1) == maximum_value;
    if (!invalid_zero_initial_rejected or !invalid_cap_rejected or
        !invalid_zero_retries_rejected or intervals[0] != 3 or intervals[1] != 6 or
        intervals[2] != 10 or intervals[3] != 10 or !limit_rejected or
        fixed_intervals[0] != 5 or fixed_intervals[1] != 5 or fixed_intervals[2] != 5 or
        !overflow_saturated)
    {
        return null;
    }
    return .{
        .invalid_zero_initial_rejected = invalid_zero_initial_rejected,
        .invalid_cap_rejected = invalid_cap_rejected,
        .invalid_zero_retries_rejected = invalid_zero_retries_rejected,
        .intervals = intervals,
        .limit_rejected = limit_rejected,
        .fixed_intervals = fixed_intervals,
        .overflow_saturated = overflow_saturated,
        .maximum_value = maximum_value,
    };
}
fn verifyNtpHealth() ?NtpHealthReport {
    var service = std.mem.zeroes(NtpService);
    service.requests_started = 5;
    service.retries = 2;
    service.responses = 3;
    service.quality_accepted = 3;
    service.quality_rejected = 1;
    service.retry_deadline_tick = 106;
    service.refresh_deadline_tick = 104;
    service.request_active = true;

    const invalid_zero_holdover_rejected = readNtpServiceHealth(&service, 100, 0, 8) == null;
    const invalid_equal_threshold_rejected = readNtpServiceHealth(&service, 100, 4, 4) == null;
    const invalid_reversed_threshold_rejected = readNtpServiceHealth(&service, 100, 8, 4) == null;
    const inactive = readNtpServiceHealth(&service, 100, 4, 8) orelse return null;
    if (inactive.state != .inactive or inactive.current_time != null) return null;

    service.active = true;
    service.client.active = true;
    const unsynchronized = readNtpServiceHealth(&service, 100, 4, 8) orelse return null;
    if (unsynchronized.state != .unsynchronized or unsynchronized.current_time != null) return null;

    service.clock.clock.synchronized = true;
    service.clock.clock.unix_seconds = ntp.fixture_unix_seconds;
    service.clock.clock.unix_fraction = 0x80000000;
    service.clock.anchor_tick = 100;
    service.clock.ticks_per_second = 4;
    const backward_tick_rejected = readNtpServiceHealth(&service, 99, 4, 8) == null;
    const synchronized = readNtpServiceHealth(&service, 103, 4, 8) orelse return null;
    const synchronized_time = synchronized.current_time orelse return null;
    const holdover = readNtpServiceHealth(&service, 104, 4, 8) orelse return null;
    const holdover_time = holdover.current_time orelse return null;
    const expired = readNtpServiceHealth(&service, 108, 4, 8) orelse return null;

    const awaiting_response_preserved = synchronized.awaiting_response and holdover.awaiting_response and
        expired.awaiting_response;
    const counters_preserved = synchronized.requests_started == 5 and synchronized.retries == 2 and
        synchronized.responses == 3 and synchronized.quality_accepted == 3 and
        synchronized.quality_rejected == 1 and synchronized.retry_deadline_tick == 106 and
        synchronized.refresh_deadline_tick == 104 and holdover.requests_started == 5 and
        expired.responses == 3;
    if (!invalid_zero_holdover_rejected or !invalid_equal_threshold_rejected or
        !invalid_reversed_threshold_rejected or !backward_tick_rejected or
        synchronized.state != .synchronized or synchronized.sample_age_ticks != 3 or
        synchronized_time.seconds != ntp.fixture_unix_seconds + 1 or
        synchronized_time.fraction != 0x40000000 or holdover.state != .holdover or
        holdover.sample_age_ticks != 4 or holdover_time.seconds != ntp.fixture_unix_seconds + 1 or
        holdover_time.fraction != 0x80000000 or expired.state != .expired or
        expired.sample_age_ticks != 8 or expired.current_time != null or
        !awaiting_response_preserved or !counters_preserved)
    {
        return null;
    }
    return .{
        .invalid_zero_holdover_rejected = invalid_zero_holdover_rejected,
        .invalid_equal_threshold_rejected = invalid_equal_threshold_rejected,
        .invalid_reversed_threshold_rejected = invalid_reversed_threshold_rejected,
        .inactive_state = inactive.state,
        .unsynchronized_state = unsynchronized.state,
        .synchronized_state = synchronized.state,
        .holdover_state = holdover.state,
        .expired_state = expired.state,
        .backward_tick_rejected = backward_tick_rejected,
        .synchronized_age_ticks = synchronized.sample_age_ticks,
        .synchronized_seconds = synchronized_time.seconds,
        .synchronized_fraction = synchronized_time.fraction,
        .holdover_age_ticks = holdover.sample_age_ticks,
        .holdover_seconds = holdover_time.seconds,
        .holdover_fraction = holdover_time.fraction,
        .expired_age_ticks = expired.sample_age_ticks,
        .expired_time_absent = expired.current_time == null,
        .awaiting_response_preserved = awaiting_response_preserved,
        .counters_preserved = counters_preserved,
    };
}
fn verifyNtpQuality() ?NtpQualityReport {
    var payload_buffer = std.mem.zeroes([ntp.packet_bytes]u8);
    const payload = ntp.buildServerResponse(
        &payload_buffer,
        ntp.fixture_client_timestamp,
        ntp.fixture_server_timestamp - 0x40000000,
        ntp.fixture_server_timestamp,
    ) orelse return null;
    const response = ntp.parseServerResponse(payload, ntp.fixture_client_timestamp) orelse return null;
    const permissive = ntp.QualityPolicy{
        .max_stratum = 4,
        .max_root_delay = 0x00020000,
        .max_root_dispersion = 0x00010000,
    };
    const boundary = ntp.QualityPolicy{
        .max_stratum = response.stratum,
        .max_root_delay = ntp.rootDelayMagnitude(response.root_delay),
        .max_root_dispersion = response.root_dispersion,
    };
    const fixture_accepted = ntp.evaluateQuality(response, permissive) == .accepted;
    const boundary_accepted = ntp.evaluateQuality(response, boundary) == .accepted;
    const invalid_policy_rejected = ntp.evaluateQuality(response, .{
        .max_stratum = 0,
        .max_root_delay = std.math.maxInt(u32),
        .max_root_dispersion = std.math.maxInt(u32),
    }) == .invalid_policy;
    var high_stratum = response;
    high_stratum.stratum = boundary.max_stratum + 1;
    const stratum_rejected = ntp.evaluateQuality(high_stratum, boundary) == .stratum;
    var positive_delay = response;
    positive_delay.root_delay = boundary.max_root_delay + 1;
    const positive_delay_rejected = ntp.evaluateQuality(positive_delay, boundary) == .root_delay;
    var negative_delay = response;
    negative_delay.root_delay = @bitCast(@as(i32, -65_537));
    const negative_delay_magnitude = ntp.rootDelayMagnitude(negative_delay.root_delay);
    const negative_delay_rejected = ntp.evaluateQuality(negative_delay, boundary) == .root_delay;
    var high_dispersion = response;
    high_dispersion.root_dispersion = boundary.max_root_dispersion + 1;
    const dispersion_rejected = ntp.evaluateQuality(high_dispersion, boundary) == .root_dispersion;
    const fixture_delay_magnitude = ntp.rootDelayMagnitude(response.root_delay);
    if (!fixture_accepted or !boundary_accepted or !invalid_policy_rejected or
        !stratum_rejected or !positive_delay_rejected or !negative_delay_rejected or
        !dispersion_rejected or fixture_delay_magnitude != 0x00010000 or
        negative_delay_magnitude != 0x00010001)
    {
        return null;
    }
    return .{
        .fixture_accepted = fixture_accepted,
        .boundary_accepted = boundary_accepted,
        .invalid_policy_rejected = invalid_policy_rejected,
        .stratum_rejected = stratum_rejected,
        .positive_delay_rejected = positive_delay_rejected,
        .negative_delay_rejected = negative_delay_rejected,
        .dispersion_rejected = dispersion_rejected,
        .fixture_delay_magnitude = fixture_delay_magnitude,
        .negative_delay_magnitude = negative_delay_magnitude,
    };
}
fn verifyNtpAutomaticTimestamp() ?NtpAutomaticTimestampReport {
    var service = std.mem.zeroes(NtpService);
    const zero_bootstrap_rejected = selectNtpServiceTimestamp(&service, 1000, 0) == null;
    const bootstrap = selectNtpServiceTimestamp(&service, 1000, ntp.fixture_client_timestamp) orelse return null;
    service.clock.clock.synchronized = true;
    service.clock.clock.unix_seconds = ntp.fixture_unix_seconds;
    service.clock.clock.unix_fraction = 0x80000000;
    service.clock.anchor_tick = 1000;
    service.clock.ticks_per_second = 1000;
    const anchor = selectNtpServiceTimestamp(&service, 1000, 0) orelse return null;
    const quarter = selectNtpServiceTimestamp(&service, 1250, 0) orelse return null;
    const backward_tick_rejected = selectNtpServiceTimestamp(&service, 999, 0) == null;
    const expected_quarter = (@as(u64, ntp.fixture_server_seconds) << 32) | 0xC0000000;
    if (!zero_bootstrap_rejected or bootstrap != ntp.fixture_client_timestamp or
        anchor != ntp.fixture_server_timestamp or quarter != expected_quarter or
        !backward_tick_rejected)
    {
        return null;
    }
    return .{
        .zero_bootstrap_rejected = zero_bootstrap_rejected,
        .bootstrap_timestamp = bootstrap,
        .anchor_timestamp = anchor,
        .quarter_timestamp = quarter,
        .backward_tick_rejected = backward_tick_rejected,
    };
}
fn verifyNtpTimestamp() ?NtpTimestampReport {
    const base = ntp.UnixTime{ .seconds = ntp.fixture_unix_seconds, .fraction = 0x80000000 };
    const base_timestamp = ntp.unixTimeToTimestamp(base) orelse return null;
    if (base_timestamp != ntp.fixture_server_timestamp) return null;
    var projected = std.mem.zeroes(ntp.ProjectedClock);
    const unsynchronized_rejected = ntp.projectedTimestampAt(&projected, 1000) == null;
    projected.clock.synchronized = true;
    projected.clock.unix_seconds = base.seconds;
    projected.clock.unix_fraction = base.fraction;
    projected.anchor_tick = 1000;
    projected.ticks_per_second = 1000;
    const anchor = ntp.projectedTimestampAt(&projected, 1000) orelse return null;
    const quarter = ntp.projectedTimestampAt(&projected, 1250) orelse return null;
    const rollover = ntp.projectedTimestampAt(&projected, 1750) orelse return null;
    const expected_quarter = (@as(u64, ntp.fixture_server_seconds) << 32) | 0xC0000000;
    const expected_rollover = (@as(u64, ntp.fixture_server_seconds + 1) << 32) | 0x40000000;
    const backward_tick_rejected = ntp.projectedTimestampAt(&projected, 999) == null;
    const maximum_unix_seconds = std.math.maxInt(u32) - ntp.unix_epoch_offset_seconds;
    const maximum = ntp.unixTimeToTimestamp(.{
        .seconds = maximum_unix_seconds,
        .fraction = 0xFFFFFFFF,
    }) orelse return null;
    const overflow_rejected = ntp.unixTimeToTimestamp(.{
        .seconds = maximum_unix_seconds + 1,
        .fraction = 0,
    }) == null;
    if (!unsynchronized_rejected or anchor != base_timestamp or quarter != expected_quarter or
        rollover != expected_rollover or !backward_tick_rejected or
        maximum != std.math.maxInt(u64) or !overflow_rejected) return null;
    return .{ .base_timestamp = base_timestamp, .anchor_timestamp = anchor, .quarter_timestamp = quarter, .rollover_timestamp = rollover, .maximum_timestamp = maximum, .unsynchronized_rejected = unsynchronized_rejected, .backward_tick_rejected = backward_tick_rejected, .overflow_rejected = overflow_rejected };
}
fn verifyNtpService(device: *Device, counter: *time_reference.ContinuousCounter) ?NtpServiceReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_186 or
        device.next_udp_generation != 45 or device.tx_producer != 5 or
        device.next_udp_identification != 34 or device.next_dns_transaction_id != 8 or
        counter.frequency_hz == 0 or counter.counter_bits == 0) return null;
    const server = [4]u8{ 10, 0, 2, 4 };

    const invalid_endpoint_count = device.udp_endpoint_count;
    const invalid_ephemeral_cursor = device.next_ephemeral_udp_port;
    const invalid_generation = device.next_udp_generation;
    const invalid_identification = device.next_udp_identification;
    const invalid_tx_cursor = device.tx_producer;
    const invalid_submissions = device.tx_submissions;
    const invalid_policy_rejected = openNtpServiceWithPolicy(
        device,
        server,
        1,
        2,
        .{ .max_stratum = 0, .max_root_delay = 0, .max_root_dispersion = 0 },
    ) == null;
    const invalid_policy_state_preserved = device.udp_endpoint_count == invalid_endpoint_count and
        device.next_ephemeral_udp_port == invalid_ephemeral_cursor and
        device.next_udp_generation == invalid_generation and
        device.next_udp_identification == invalid_identification and
        device.tx_producer == invalid_tx_cursor and device.tx_submissions == invalid_submissions;
    if (!invalid_policy_rejected or !invalid_policy_state_preserved) return null;

    var service = openNtpService(device, server, 1, 2) orelse return null;
    const socket = service.client.socket;
    if (socket.endpoint_index != 2 or socket.generation != 45 or socket.local_port != 49_186 or
        device.next_ephemeral_udp_port != 49_187 or device.next_udp_generation != 46 or
        device.udp_endpoint_count != 3 or
        !std.meta.eql(service.quality_policy, ntp.default_quality_policy)) return null;
    const submissions_before = device.tx_submissions;
    const start_tick = counter.read();

    const bootstrap_snapshot = service;
    const bootstrap_identification = device.next_udp_identification;
    const bootstrap_tx_cursor = device.tx_producer;
    const bootstrap_submissions = device.tx_submissions;
    const bootstrap_zero_rejected = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick,
        0,
        0,
    ) == null;
    const bootstrap_state_preserved = std.meta.eql(service, bootstrap_snapshot) and
        device.next_udp_identification == bootstrap_identification and
        device.tx_producer == bootstrap_tx_cursor and
        device.tx_submissions == bootstrap_submissions;
    if (!bootstrap_zero_rejected or !bootstrap_state_preserved) return null;

    const initial = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        start_tick,
        ntp.fixture_client_timestamp,
        0,
    ) orelse return null;
    const initial_tx = initial.transmit orelse return null;
    const initial_client_timestamp = service.request.client_timestamp;
    if (initial.state != .awaiting or initial.start_reason != .initial or
        initial.quality_result != null or initial_client_timestamp != ntp.fixture_client_timestamp or
        initial_tx.identification != 34 or initial_tx.completion.descriptor_index != 5 or
        initial_tx.completion.next_cursor != 6 or service.requests_started != 1 or
        service.retry_deadline_tick != start_tick + 1) return null;

    const early = stepNtpServiceAutomatic(device, &service, counter, start_tick, 0, 0) orelse return null;
    if (early.state != .awaiting or early.transmit != null or early.retried or
        early.quality_result != null or service.retries != 0 or service.request.transmissions != 1)
        return null;

    const retry = stepNtpServiceAutomatic(device, &service, counter, start_tick + 1, 0, 0) orelse return null;
    const retry_tx = retry.transmit orelse return null;
    const retry_timestamp_preserved = service.request.client_timestamp == initial_client_timestamp;
    if (!retry.retried or retry.quality_result != null or !retry_timestamp_preserved or
        retry_tx.identification != 35 or retry_tx.completion.descriptor_index != 6 or
        retry_tx.completion.next_cursor != 7 or service.retries != 1 or
        service.request.transmissions != 2) return null;
    const retry_transmissions = service.request.transmissions;

    if (!enqueueNtpServiceResponseWithQuality(
        device,
        socket,
        server,
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        2,
        ntp.default_quality_policy.max_root_delay,
        ntp.default_quality_policy.max_root_dispersion + 1,
        0x7700,
        0xE800,
    )) return null;
    const clock_before_rejection = service.clock;
    const rejected = stepNtpServiceAutomatic(device, &service, counter, start_tick + 1, 0, 1) orelse return null;
    const quality_rejection_reason = rejected.quality_result orelse return null;
    const quality_rejected_without_sample = rejected.sample_tick == null and
        rejected.apply_result == null and std.meta.eql(service.clock, clock_before_rejection);
    const quality_request_retained = rejected.state == .awaiting and rejected.poll.state == .resolved and
        rejected.transmit == null and !rejected.retried and service.request_active and
        service.request.transmissions == retry_transmissions;
    if (quality_rejection_reason != .root_dispersion or !quality_rejected_without_sample or
        !quality_request_retained or service.quality_accepted != 0 or service.quality_rejected != 1 or
        service.quality_invalid_policy_rejected != 0 or service.quality_stratum_rejected != 0 or
        service.quality_root_delay_rejected != 0 or service.quality_root_dispersion_rejected != 1 or
        service.clock.clock.synchronized) return null;

    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        ntp.fixture_server_timestamp,
        0x7701,
        0xE801,
    )) return null;
    const first = stepNtpServiceAutomatic(device, &service, counter, start_tick + 1, 0, 1) orelse return null;
    const first_tick = first.sample_tick orelse return null;
    const first_time = ntp.readProjectedClockAt(&service.clock, first_tick) orelse return null;
    if (first.state != .idle or first.poll.state != .resolved or first.quality_result != .accepted or
        first.apply_result != .accepted or first_time.seconds != ntp.fixture_unix_seconds or
        first_time.fraction != 0x80000000 or service.request_active or service.responses != 1 or
        service.quality_accepted != 1 or service.refresh_deadline_tick != first_tick + 2)
        return null;

    const pre_anchor_snapshot = service;
    const pre_anchor_identification = device.next_udp_identification;
    const pre_anchor_tx_cursor = device.tx_producer;
    const pre_anchor_submissions = device.tx_submissions;
    const pre_anchor_tick = if (first_tick == 0) 0 else first_tick - 1;
    const pre_anchor = stepNtpServiceAutomatic(device, &service, counter, pre_anchor_tick, 0, 0) orelse return null;
    const pre_anchor_idle_preserved = pre_anchor.state == .idle and pre_anchor.transmit == null and
        pre_anchor.quality_result == null and std.meta.eql(service, pre_anchor_snapshot) and
        device.next_udp_identification == pre_anchor_identification and
        device.tx_producer == pre_anchor_tx_cursor and
        device.tx_submissions == pre_anchor_submissions;
    if (!pre_anchor_idle_preserved) return null;

    const before = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        service.refresh_deadline_tick - 1,
        0,
        0,
    ) orelse return null;
    if (before.state != .idle or before.transmit != null or before.quality_result != null or
        service.request_active or service.requests_started != 1) return null;

    const refresh_tick = service.refresh_deadline_tick;
    const expected_refresh_timestamp = ntp.projectedTimestampAt(&service.clock, refresh_tick) orelse return null;
    const refresh = stepNtpServiceAutomatic(device, &service, counter, refresh_tick, 0, 0) orelse return null;
    const refresh_tx = refresh.transmit orelse return null;
    const refresh_client_timestamp = service.request.client_timestamp;
    const refresh_timestamp_automatic = refresh_client_timestamp == expected_refresh_timestamp and
        refresh_client_timestamp != ntp.fixture_client_timestamp;
    if (refresh.state != .awaiting or refresh.start_reason != .refresh or
        refresh.quality_result != null or !refresh_timestamp_automatic or
        refresh_tx.identification != 36 or refresh_tx.completion.descriptor_index != 7 or
        refresh_tx.completion.next_cursor != 0 or service.requests_started != 2 or
        service.request.transmissions != 1) return null;

    const refreshed_server = ntp.fixture_server_timestamp + (@as(u64, 2) << 32);
    if (!enqueueNtpServiceResponse(
        device,
        socket,
        server,
        service.request.client_timestamp,
        refreshed_server,
        0x7702,
        0xE802,
    )) return null;
    const second = stepNtpServiceAutomatic(
        device,
        &service,
        counter,
        service.retry_deadline_tick - 1,
        0,
        1,
    ) orelse return null;
    const second_tick = second.sample_tick orelse return null;
    const second_time = ntp.readProjectedClockAt(&service.clock, second_tick) orelse return null;
    if (second.state != .idle or second.poll.state != .resolved or second.quality_result != .accepted or
        second.apply_result != .accepted or second_time.seconds != ntp.fixture_unix_seconds + 2 or
        second_time.fraction != 0x80000000 or service.request_active or
        service.requests_started != 2 or service.retries != 1 or service.responses != 2 or
        service.quality_accepted != 2 or service.quality_rejected != 1 or
        service.clock.clock.accepted_samples != 2 or service.clock.clock.stale_samples != 0)
        return null;

    const snapshot = service;
    const close_ok = closeNtpService(device, &service);
    const id_before = device.next_udp_identification;
    const tx_before = device.tx_producer;
    const submissions_at_close = device.tx_submissions;
    const inactive = stepNtpServiceAutomatic(device, &service, counter, second_tick, 0, 1) orelse return null;
    const inactive_preserved = inactive.state == .inactive and inactive.transmit == null and
        inactive.sample_tick == null and inactive.apply_result == null and inactive.quality_result == null and
        std.meta.eql(service.clock, snapshot.clock) and device.next_udp_identification == id_before and
        device.tx_producer == tx_before and device.tx_submissions == submissions_at_close;
    if (!close_ok or service.active or service.client.active or !inactive_preserved) return null;

    const txe = completionQueueEnqueued(&tx_completion_queue);
    const txd = completionQueueDequeued(&tx_completion_queue);
    const rxe = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_187 or
        device.next_udp_generation != 46 or device.next_udp_identification != 37 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 0 or
        device.tx_submissions != submissions_before + 3 or
        device.software_rx_queue.enqueued != 83 or device.software_rx_queue.dequeued != 83 or
        device.packets_dispatched != 72 or device.udp_packets_dispatched != 71 or
        txe != 64 or txd != 64 or rxe != 22 or overflow != 0) return null;

    return .{
        .source_kind = counter.reference.kind,
        .frequency_hz = counter.frequency_hz,
        .counter_bits = counter.counter_bits,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .invalid_policy_rejected = invalid_policy_rejected,
        .invalid_policy_state_preserved = invalid_policy_state_preserved,
        .quality_policy_max_stratum = service.quality_policy.max_stratum,
        .quality_policy_max_root_delay = service.quality_policy.max_root_delay,
        .quality_policy_max_root_dispersion = service.quality_policy.max_root_dispersion,
        .quality_rejection_reason = quality_rejection_reason,
        .quality_rejected_without_sample = quality_rejected_without_sample,
        .quality_request_retained = quality_request_retained,
        .bootstrap_zero_rejected = bootstrap_zero_rejected,
        .bootstrap_state_preserved = bootstrap_state_preserved,
        .pre_anchor_idle_preserved = pre_anchor_idle_preserved,
        .initial_client_timestamp = initial_client_timestamp,
        .retry_timestamp_preserved = retry_timestamp_preserved,
        .refresh_client_timestamp = refresh_client_timestamp,
        .refresh_timestamp_automatic = refresh_timestamp_automatic,
        .retry_interval_ticks = 1,
        .refresh_interval_ticks = 2,
        .initial_identification = initial_tx.identification,
        .initial_descriptor = initial_tx.completion.descriptor_index,
        .initial_next_cursor = initial_tx.completion.next_cursor,
        .early_no_tx = early.transmit == null,
        .retry_identification = retry_tx.identification,
        .retry_descriptor = retry_tx.completion.descriptor_index,
        .retry_next_cursor = retry_tx.completion.next_cursor,
        .retry_transmissions = retry_transmissions,
        .first_sample_tick = first_tick,
        .first_seconds = first_time.seconds,
        .first_fraction = first_time.fraction,
        .first_refresh_deadline = first_tick + 2,
        .before_refresh_no_tx = before.transmit == null,
        .refresh_identification = refresh_tx.identification,
        .refresh_descriptor = refresh_tx.completion.descriptor_index,
        .refresh_next_cursor = refresh_tx.completion.next_cursor,
        .second_sample_tick = second_tick,
        .second_seconds = second_time.seconds,
        .second_fraction = second_time.fraction,
        .requests_started = snapshot.requests_started,
        .retries = snapshot.retries,
        .responses = snapshot.responses,
        .quality_accepted = snapshot.quality_accepted,
        .quality_rejected = snapshot.quality_rejected,
        .quality_invalid_policy_rejected = snapshot.quality_invalid_policy_rejected,
        .quality_stratum_rejected = snapshot.quality_stratum_rejected,
        .quality_root_delay_rejected = snapshot.quality_root_delay_rejected,
        .quality_root_dispersion_rejected = snapshot.quality_root_dispersion_rejected,
        .close_succeeded = close_ok,
        .inactive_preserved = inactive_preserved,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = txe,
        .tx_completion_dequeues = txd,
        .rx_completion_enqueues = rxe,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}
fn verifyNtpReferenceClock(
    device: *Device,
    counter: *time_reference.ContinuousCounter,
) ?NtpReferenceClockReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_185 or
        device.next_udp_generation != 44 or device.tx_producer != 3 or
        device.next_udp_identification != 32 or device.next_dns_transaction_id != 8 or
        counter.frequency_hz == 0 or counter.counter_bits == 0)
    {
        return null;
    }

    const server_ipv4 = [4]u8{ 10, 0, 2, 4 };
    var client = openNtpClient(device, server_ipv4) orelse return null;
    const socket = client.socket;
    if (!client.active or socket.endpoint_index != 2 or socket.generation != 44 or
        socket.local_port != 49_185 or device.next_ephemeral_udp_port != 49_186 or
        device.next_udp_generation != 45 or device.udp_endpoint_count != 3)
    {
        return null;
    }
    const endpoint = udpSocketEndpoint(device, socket) orelse return null;
    const submissions_before = device.tx_submissions;
    var projected = std.mem.zeroes(ntp.ProjectedClock);

    var first_request = startNtpClientRequest(device, &client, ntp.fixture_client_timestamp) orelse return null;
    const first_transmit = first_request.transmit;
    if (first_transmit.identification != 32 or first_transmit.completion.descriptor_index != 3 or
        first_transmit.completion.next_cursor != 4 or first_transmit.completion.frame_length != 90 or
        device.next_udp_identification != 33 or device.tx_producer != 4 or
        device.tx_submissions != submissions_before + 1)
    {
        return null;
    }

    const receive_timestamp = (@as(u64, ntp.fixture_server_seconds) << 32) | 0x40000000;
    var first_payload_buffer = std.mem.zeroes([ntp.packet_bytes]u8);
    const first_payload = ntp.buildServerResponse(
        &first_payload_buffer,
        first_request.client_timestamp,
        receive_timestamp,
        ntp.fixture_server_timestamp,
    ) orelse return null;
    var first_frame = std.mem.zeroes([128]u8);
    const first_frame_length = udp.buildFrame(&first_frame, .{
        .source_mac = device.gateway_mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = server_ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = ntp.server_port,
        .destination_port = socket.local_port,
        .identification = 0x7600,
        .payload = first_payload,
    }) orelse return null;
    var first_packet = std.mem.zeroes(Packet);
    first_packet.length = first_frame_length;
    first_packet.source_descriptor = 0xE700;
    @memcpy(first_packet.bytes[0..first_frame_length], first_frame[0..first_frame_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, first_packet)) return null;
    const first_dispatch = dispatchPacketBatch(device, 1);
    if (first_dispatch.examined != 1 or first_dispatch.routed != 1 or first_dispatch.dropped != 0) return null;

    const zero = pollNtpClientReferenceClock(device, &client, &first_request, &projected, counter, 0);
    const zero_queue_remaining = queueDepth(&endpoint.queue);
    if (zero.poll.state != .pending or zero.poll.examined != 0 or zero.poll.rejected != 0 or
        zero.poll.response != null or zero.sample_tick != null or zero.apply_result != null or
        zero_queue_remaining != 1 or projected.clock.synchronized)
    {
        return null;
    }

    const accepted = pollNtpClientReferenceClock(device, &client, &first_request, &projected, counter, 1);
    const accepted_tick = accepted.sample_tick orelse return null;
    const accepted_apply = accepted.apply_result orelse return null;
    const accepted_time = ntp.readProjectedClockAt(&projected, accepted_tick) orelse return null;
    if (accepted.poll.state != .resolved or accepted.poll.examined != 1 or accepted.poll.rejected != 0 or
        accepted.poll.response == null or accepted_apply != .accepted or
        accepted_time.seconds != ntp.fixture_unix_seconds or accepted_time.fraction != 0x80000000 or
        queueDepth(&endpoint.queue) != 0)
    {
        return null;
    }

    if (!counter.reference.waitNanoseconds(2_000_000)) return null;
    const later_tick = counter.read();
    const later_time = ntp.readProjectedClockAt(&projected, later_tick) orelse return null;
    const time_advanced = later_tick > accepted_tick and
        (later_time.seconds > accepted_time.seconds or
            (later_time.seconds == accepted_time.seconds and later_time.fraction > accepted_time.fraction));
    if (!time_advanced) return null;

    var second_request = startNtpClientRequest(device, &client, ntp.fixture_client_timestamp) orelse return null;
    const second_transmit = second_request.transmit;
    if (second_transmit.identification != 33 or second_transmit.completion.descriptor_index != 4 or
        second_transmit.completion.next_cursor != 5 or second_transmit.completion.frame_length != 90 or
        device.next_udp_identification != 34 or device.tx_producer != 5 or
        device.tx_submissions != submissions_before + 2)
    {
        return null;
    }

    var second_payload_buffer = std.mem.zeroes([ntp.packet_bytes]u8);
    const second_payload = ntp.buildServerResponse(
        &second_payload_buffer,
        second_request.client_timestamp,
        receive_timestamp,
        ntp.fixture_server_timestamp,
    ) orelse return null;
    var second_frame = std.mem.zeroes([128]u8);
    const second_frame_length = udp.buildFrame(&second_frame, .{
        .source_mac = device.gateway_mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = server_ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = ntp.server_port,
        .destination_port = socket.local_port,
        .identification = 0x7601,
        .payload = second_payload,
    }) orelse return null;
    var second_packet = std.mem.zeroes(Packet);
    second_packet.length = second_frame_length;
    second_packet.source_descriptor = 0xE701;
    @memcpy(second_packet.bytes[0..second_frame_length], second_frame[0..second_frame_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, second_packet)) return null;
    const second_dispatch = dispatchPacketBatch(device, 1);
    if (second_dispatch.examined != 1 or second_dispatch.routed != 1 or second_dispatch.dropped != 0) return null;

    const accepted_snapshot = projected;
    const duplicate = pollNtpClientReferenceClock(device, &client, &second_request, &projected, counter, 1);
    const duplicate_tick = duplicate.sample_tick orelse return null;
    const duplicate_apply = duplicate.apply_result orelse return null;
    const duplicate_clock_preserved = projected.clock.synchronized == accepted_snapshot.clock.synchronized and
        projected.clock.unix_seconds == accepted_snapshot.clock.unix_seconds and
        projected.clock.unix_fraction == accepted_snapshot.clock.unix_fraction and
        projected.clock.stratum == accepted_snapshot.clock.stratum and
        std.mem.eql(u8, &projected.clock.reference_id, &accepted_snapshot.clock.reference_id) and
        projected.clock.accepted_samples == accepted_snapshot.clock.accepted_samples and
        projected.clock.stale_samples == accepted_snapshot.clock.stale_samples + 1 and
        projected.anchor_tick == accepted_snapshot.anchor_tick and
        projected.ticks_per_second == accepted_snapshot.ticks_per_second;
    if (duplicate.poll.state != .resolved or duplicate.poll.examined != 1 or duplicate.poll.rejected != 0 or
        duplicate.poll.response == null or duplicate_apply != .stale or !duplicate_clock_preserved or
        duplicate_tick < later_tick or queueDepth(&endpoint.queue) != 0)
    {
        return null;
    }

    const clock_before_close = projected;
    const close_succeeded = closeNtpClient(device, &client);
    const inactive = pollNtpClientReferenceClock(device, &client, &second_request, &projected, counter, 1);
    const inactive_clock_preserved = std.meta.eql(projected, clock_before_close);
    if (!close_succeeded or client.active or inactive.poll.state != .inactive or
        inactive.poll.examined != 0 or inactive.poll.rejected != 0 or inactive.poll.response != null or
        inactive.sample_tick != null or inactive.apply_result != null or !inactive_clock_preserved)
    {
        return null;
    }

    const tx_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_186 or
        device.next_udp_generation != 45 or device.next_udp_identification != 34 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 5 or
        device.tx_submissions != submissions_before + 2 or
        device.software_rx_queue.enqueued != 80 or device.software_rx_queue.dequeued != 80 or
        device.packets_dispatched != 69 or device.udp_packets_dispatched != 68 or
        tx_enqueues != 61 or tx_dequeues != 61 or rx_enqueues != 22 or overflow != 0)
    {
        return null;
    }

    return .{
        .source_kind = counter.reference.kind,
        .frequency_hz = counter.frequency_hz,
        .counter_bits = counter.counter_bits,
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .server_ipv4 = server_ipv4,
        .server_port = ntp.server_port,
        .first_identification = first_transmit.identification,
        .first_descriptor = first_transmit.completion.descriptor_index,
        .first_next_cursor = first_transmit.completion.next_cursor,
        .first_frame_length = first_transmit.completion.frame_length,
        .zero_state = zero.poll.state,
        .zero_examined = zero.poll.examined,
        .zero_rejected = zero.poll.rejected,
        .zero_sample_absent = zero.sample_tick == null,
        .zero_apply_absent = zero.apply_result == null,
        .zero_queue_remaining = zero_queue_remaining,
        .accepted_state = accepted.poll.state,
        .accepted_examined = accepted.poll.examined,
        .accepted_rejected = accepted.poll.rejected,
        .accepted_sample_tick = accepted_tick,
        .accepted_apply = accepted_apply,
        .accepted_seconds = accepted_time.seconds,
        .accepted_fraction = accepted_time.fraction,
        .later_tick = later_tick,
        .later_delta = later_tick - accepted_tick,
        .later_seconds = later_time.seconds,
        .later_fraction = later_time.fraction,
        .time_advanced = time_advanced,
        .second_identification = second_transmit.identification,
        .second_descriptor = second_transmit.completion.descriptor_index,
        .second_next_cursor = second_transmit.completion.next_cursor,
        .second_frame_length = second_transmit.completion.frame_length,
        .duplicate_state = duplicate.poll.state,
        .duplicate_examined = duplicate.poll.examined,
        .duplicate_rejected = duplicate.poll.rejected,
        .duplicate_sample_tick = duplicate_tick,
        .duplicate_apply = duplicate_apply,
        .duplicate_clock_preserved = duplicate_clock_preserved,
        .close_succeeded = close_succeeded,
        .inactive_state = inactive.poll.state,
        .inactive_sample_absent = inactive.sample_tick == null,
        .inactive_apply_absent = inactive.apply_result == null,
        .inactive_clock_preserved = inactive_clock_preserved,
        .final_identification_cursor = device.next_udp_identification,
        .final_dns_transaction_cursor = device.next_dns_transaction_id,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = tx_enqueues,
        .tx_completion_dequeues = tx_dequeues,
        .rx_completion_enqueues = rx_enqueues,
        .completion_overflow = overflow,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpProjectedClock() ?NtpProjectedClockReport {
    var response_buffer = std.mem.zeroes([ntp.packet_bytes]u8);
    const receive_timestamp = (@as(u64, ntp.fixture_server_seconds) << 32) | 0x40000000;
    const response_bytes = ntp.buildServerResponse(
        &response_buffer,
        ntp.fixture_client_timestamp,
        receive_timestamp,
        ntp.fixture_server_timestamp,
    ) orelse return null;
    const base = ntp.parseServerResponse(response_bytes, ntp.fixture_client_timestamp) orelse return null;

    var projected = std.mem.zeroes(ntp.ProjectedClock);
    const invalid_snapshot = projected;
    const invalid_frequency_rejected = ntp.applyResponseAt(&projected, base, 1_000, 0) == null;
    const invalid_frequency_state_preserved = invalid_frequency_rejected and std.meta.eql(projected, invalid_snapshot);
    const initially_unsynchronized = ntp.readProjectedClockAt(&projected, 1_000) == null;
    if (!invalid_frequency_state_preserved or !initially_unsynchronized) return null;

    const first_apply = ntp.applyResponseAt(&projected, base, 1_000, 1_000) orelse return null;
    const quarter = ntp.readProjectedClockAt(&projected, 1_250) orelse return null;
    const three_quarter = ntp.readProjectedClockAt(&projected, 1_750) orelse return null;
    const one_second = ntp.readProjectedClockAt(&projected, 2_000) orelse return null;
    const backward_tick_rejected = ntp.readProjectedClockAt(&projected, 999) == null;
    if (first_apply != .accepted or quarter.seconds != ntp.fixture_unix_seconds or
        quarter.fraction != 0xC0000000 or
        three_quarter.seconds != ntp.fixture_unix_seconds + 1 or three_quarter.fraction != 0x40000000 or
        one_second.seconds != ntp.fixture_unix_seconds + 1 or one_second.fraction != 0x80000000 or
        !backward_tick_rejected or projected.clock.accepted_samples != 1 or projected.clock.stale_samples != 0)
    {
        return null;
    }

    var resync = base;
    resync.unix_seconds = ntp.fixture_unix_seconds + 2;
    resync.unix_fraction = 0x10000000;
    resync.stratum = 3;
    resync.reference_id = .{ 'S', 'Y', 'N', 'C' };
    const resync_apply = ntp.applyResponseAt(&projected, resync, 2_000, 1_000) orelse return null;
    const resync_quarter = ntp.readProjectedClockAt(&projected, 2_250) orelse return null;
    if (resync_apply != .accepted or projected.anchor_tick != 2_000 or projected.ticks_per_second != 1_000 or
        projected.clock.unix_seconds != ntp.fixture_unix_seconds + 2 or
        projected.clock.unix_fraction != 0x10000000 or projected.clock.stratum != 3 or
        !std.mem.eql(u8, &projected.clock.reference_id, "SYNC") or
        resync_quarter.seconds != ntp.fixture_unix_seconds + 2 or resync_quarter.fraction != 0x50000000)
    {
        return null;
    }

    const stale_snapshot = projected;
    const stale_apply = ntp.applyResponseAt(&projected, base, 2_500, 1_000) orelse return null;
    const stale_state_preserved = projected.clock.synchronized == stale_snapshot.clock.synchronized and
        projected.clock.unix_seconds == stale_snapshot.clock.unix_seconds and
        projected.clock.unix_fraction == stale_snapshot.clock.unix_fraction and
        projected.clock.stratum == stale_snapshot.clock.stratum and
        std.mem.eql(u8, &projected.clock.reference_id, &stale_snapshot.clock.reference_id) and
        projected.clock.accepted_samples == stale_snapshot.clock.accepted_samples and
        projected.clock.stale_samples == stale_snapshot.clock.stale_samples + 1 and
        projected.anchor_tick == stale_snapshot.anchor_tick and
        projected.ticks_per_second == stale_snapshot.ticks_per_second;
    if (stale_apply != .stale or !stale_state_preserved or
        projected.clock.accepted_samples != 2 or projected.clock.stale_samples != 1)
    {
        return null;
    }

    return .{
        .invalid_frequency_rejected = invalid_frequency_rejected,
        .invalid_frequency_state_preserved = invalid_frequency_state_preserved,
        .initially_unsynchronized = initially_unsynchronized,
        .first_apply = first_apply,
        .first_anchor_tick = 1_000,
        .first_frequency = 1_000,
        .quarter_seconds = quarter.seconds,
        .quarter_fraction = quarter.fraction,
        .three_quarter_seconds = three_quarter.seconds,
        .three_quarter_fraction = three_quarter.fraction,
        .one_second_seconds = one_second.seconds,
        .one_second_fraction = one_second.fraction,
        .backward_tick_rejected = backward_tick_rejected,
        .resync_apply = resync_apply,
        .resync_anchor_tick = projected.anchor_tick,
        .resync_frequency = projected.ticks_per_second,
        .resync_seconds = projected.clock.unix_seconds,
        .resync_fraction = projected.clock.unix_fraction,
        .resync_stratum = projected.clock.stratum,
        .resync_reference_id = projected.clock.reference_id,
        .resync_quarter_seconds = resync_quarter.seconds,
        .resync_quarter_fraction = resync_quarter.fraction,
        .stale_apply = stale_apply,
        .stale_state_preserved = stale_state_preserved,
        .accepted_samples = projected.clock.accepted_samples,
        .stale_samples = projected.clock.stale_samples,
    };
}

fn verifyNtpClockPolling(device: *Device) ?NtpClockPollingReport {
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_184 or
        device.next_udp_generation != 43 or device.tx_producer != 1 or
        device.next_udp_identification != 30 or device.next_dns_transaction_id != 8)
    {
        return null;
    }

    const server_ipv4 = [4]u8{ 10, 0, 2, 4 };
    var client = openNtpClient(device, server_ipv4) orelse return null;
    const socket = client.socket;
    if (!client.active or socket.endpoint_index != 2 or socket.generation != 43 or
        socket.local_port != 49_184 or device.next_ephemeral_udp_port != 49_185 or
        device.next_udp_generation != 44 or device.udp_endpoint_count != 3)
    {
        return null;
    }
    const endpoint = udpSocketEndpoint(device, socket) orelse return null;
    const submissions_before = device.tx_submissions;
    var clock = std.mem.zeroes(ntp.Clock);

    var first_request = startNtpClientRequest(device, &client, ntp.fixture_client_timestamp) orelse return null;
    const first_transmit = first_request.transmit;
    if (first_transmit.identification != 30 or first_transmit.completion.descriptor_index != 1 or
        first_transmit.completion.next_cursor != 2 or first_transmit.completion.frame_length != 90 or
        device.next_udp_identification != 31 or device.tx_producer != 2 or
        device.tx_submissions != submissions_before + 1)
    {
        return null;
    }

    const receive_timestamp = (@as(u64, ntp.fixture_server_seconds) << 32) | 0x40000000;
    var first_payload_buffer = std.mem.zeroes([ntp.packet_bytes]u8);
    const first_payload = ntp.buildServerResponse(
        &first_payload_buffer,
        first_request.client_timestamp,
        receive_timestamp,
        ntp.fixture_server_timestamp,
    ) orelse return null;
    var first_frame = std.mem.zeroes([128]u8);
    const first_frame_length = udp.buildFrame(&first_frame, .{
        .source_mac = device.gateway_mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = server_ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = ntp.server_port,
        .destination_port = socket.local_port,
        .identification = 0x7500,
        .payload = first_payload,
    }) orelse return null;
    var first_packet = std.mem.zeroes(Packet);
    first_packet.length = first_frame_length;
    first_packet.source_descriptor = 0xE600;
    @memcpy(first_packet.bytes[0..first_frame_length], first_frame[0..first_frame_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, first_packet)) return null;
    const first_dispatch = dispatchPacketBatch(device, 1);
    if (first_dispatch.examined != 1 or first_dispatch.routed != 1 or first_dispatch.dropped != 0) return null;

    const zero = pollNtpClientClock(device, &client, &first_request, &clock, 0);
    const zero_queue_remaining = queueDepth(&endpoint.queue);
    const zero_clock_unsynchronized = ntp.readClock(&clock) == null and
        clock.accepted_samples == 0 and clock.stale_samples == 0;
    if (zero.poll.state != .pending or zero.poll.examined != 0 or zero.poll.rejected != 0 or
        zero.poll.response != null or zero.apply_result != null or zero_queue_remaining != 1 or
        !zero_clock_unsynchronized)
    {
        return null;
    }

    const accepted = pollNtpClientClock(device, &client, &first_request, &clock, 1);
    const accepted_apply = accepted.apply_result orelse return null;
    const accepted_time = ntp.readClock(&clock) orelse return null;
    if (accepted.poll.state != .resolved or accepted.poll.examined != 1 or accepted.poll.rejected != 0 or
        accepted.poll.response == null or accepted_apply != .accepted or
        accepted_time.seconds != ntp.fixture_unix_seconds or accepted_time.fraction != 0x80000000 or
        clock.accepted_samples != 1 or clock.stale_samples != 0 or queueDepth(&endpoint.queue) != 0)
    {
        return null;
    }

    var second_request = startNtpClientRequest(device, &client, ntp.fixture_client_timestamp) orelse return null;
    const second_transmit = second_request.transmit;
    if (second_transmit.identification != 31 or second_transmit.completion.descriptor_index != 2 or
        second_transmit.completion.next_cursor != 3 or second_transmit.completion.frame_length != 90 or
        device.next_udp_identification != 32 or device.tx_producer != 3 or
        device.tx_submissions != submissions_before + 2)
    {
        return null;
    }

    var second_payload_buffer = std.mem.zeroes([ntp.packet_bytes]u8);
    const second_payload = ntp.buildServerResponse(
        &second_payload_buffer,
        second_request.client_timestamp,
        receive_timestamp,
        ntp.fixture_server_timestamp,
    ) orelse return null;
    var second_frame = std.mem.zeroes([128]u8);
    const second_frame_length = udp.buildFrame(&second_frame, .{
        .source_mac = device.gateway_mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = server_ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = ntp.server_port,
        .destination_port = socket.local_port,
        .identification = 0x7501,
        .payload = second_payload,
    }) orelse return null;
    var second_packet = std.mem.zeroes(Packet);
    second_packet.length = second_frame_length;
    second_packet.source_descriptor = 0xE601;
    @memcpy(second_packet.bytes[0..second_frame_length], second_frame[0..second_frame_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, second_packet)) return null;
    const second_dispatch = dispatchPacketBatch(device, 1);
    if (second_dispatch.examined != 1 or second_dispatch.routed != 1 or second_dispatch.dropped != 0) return null;

    const accepted_snapshot = clock;
    const duplicate = pollNtpClientClock(device, &client, &second_request, &clock, 1);
    const duplicate_apply = duplicate.apply_result orelse return null;
    const duplicate_clock_preserved = clock.synchronized == accepted_snapshot.synchronized and
        clock.unix_seconds == accepted_snapshot.unix_seconds and
        clock.unix_fraction == accepted_snapshot.unix_fraction and
        clock.stratum == accepted_snapshot.stratum and
        std.mem.eql(u8, &clock.reference_id, &accepted_snapshot.reference_id) and
        clock.accepted_samples == accepted_snapshot.accepted_samples and
        clock.stale_samples == accepted_snapshot.stale_samples + 1;
    if (duplicate.poll.state != .resolved or duplicate.poll.examined != 1 or duplicate.poll.rejected != 0 or
        duplicate.poll.response == null or duplicate_apply != .stale or !duplicate_clock_preserved or
        queueDepth(&endpoint.queue) != 0 or clock.accepted_samples != 1 or clock.stale_samples != 1)
    {
        return null;
    }

    const clock_before_close = clock;
    const close_succeeded = closeNtpClient(device, &client);
    const inactive = pollNtpClientClock(device, &client, &second_request, &clock, 1);
    const inactive_clock_preserved = std.meta.eql(clock, clock_before_close);
    if (!close_succeeded or client.active or inactive.poll.state != .inactive or
        inactive.poll.examined != 0 or inactive.poll.rejected != 0 or inactive.poll.response != null or
        inactive.apply_result != null or !inactive_clock_preserved)
    {
        return null;
    }

    const tx_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_185 or
        device.next_udp_generation != 44 or device.next_udp_identification != 32 or
        device.next_dns_transaction_id != 8 or device.tx_producer != 3 or
        device.tx_submissions != submissions_before + 2 or
        device.software_rx_queue.enqueued != 78 or device.software_rx_queue.dequeued != 78 or
        device.packets_dispatched != 67 or device.udp_packets_dispatched != 66 or
        tx_enqueues != 59 or tx_dequeues != 59 or rx_enqueues != 22 or overflow != 0)
    {
        return null;
    }

    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .server_ipv4 = server_ipv4,
        .server_port = ntp.server_port,
        .first_identification = first_transmit.identification,
        .first_descriptor = first_transmit.completion.descriptor_index,
        .first_next_cursor = first_transmit.completion.next_cursor,
        .first_frame_length = first_transmit.completion.frame_length,
        .zero_state = zero.poll.state,
        .zero_examined = zero.poll.examined,
        .zero_rejected = zero.poll.rejected,
        .zero_apply_absent = zero.apply_result == null,
        .zero_queue_remaining = zero_queue_remaining,
        .zero_clock_unsynchronized = zero_clock_unsynchronized,
        .accepted_state = accepted.poll.state,
        .accepted_examined = accepted.poll.examined,
        .accepted_rejected = accepted.poll.rejected,
        .accepted_apply = accepted_apply,
        .accepted_seconds = accepted_time.seconds,
        .accepted_fraction = accepted_time.fraction,
        .second_identification = second_transmit.identification,
        .second_descriptor = second_transmit.completion.descriptor_index,
        .second_next_cursor = second_transmit.completion.next_cursor,
        .second_frame_length = second_transmit.completion.frame_length,
        .duplicate_state = duplicate.poll.state,
        .duplicate_examined = duplicate.poll.examined,
        .duplicate_rejected = duplicate.poll.rejected,
        .duplicate_apply = duplicate_apply,
        .duplicate_clock_preserved = duplicate_clock_preserved,
        .accepted_samples = clock_before_close.accepted_samples,
        .stale_samples = clock_before_close.stale_samples,
        .close_succeeded = close_succeeded,
        .inactive_state = inactive.poll.state,
        .inactive_apply_absent = inactive.apply_result == null,
        .inactive_clock_preserved = inactive_clock_preserved,
        .final_identification_cursor = device.next_udp_identification,
        .final_dns_transaction_cursor = device.next_dns_transaction_id,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = tx_enqueues,
        .tx_completion_dequeues = tx_dequeues,
        .rx_completion_enqueues = rx_enqueues,
        .completion_overflow = overflow,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpClock() ?NtpClockReport {
    var response_buffer = std.mem.zeroes([ntp.packet_bytes]u8);
    const receive_timestamp = (@as(u64, ntp.fixture_server_seconds) << 32) | 0x40000000;
    const response_bytes = ntp.buildServerResponse(
        &response_buffer,
        ntp.fixture_client_timestamp,
        receive_timestamp,
        ntp.fixture_server_timestamp,
    ) orelse return null;
    const base = ntp.parseServerResponse(response_bytes, ntp.fixture_client_timestamp) orelse return null;
    var clock = std.mem.zeroes(ntp.Clock);
    const initially_unsynchronized = ntp.readClock(&clock) == null;
    const first_apply = ntp.applyResponse(&clock, base);
    const first_time = ntp.readClock(&clock) orelse return null;
    if (!initially_unsynchronized or first_apply != .accepted or
        first_time.seconds != ntp.fixture_unix_seconds or first_time.fraction != 0x80000000)
    {
        return null;
    }

    const duplicate_snapshot = clock;
    const duplicate_apply = ntp.applyResponse(&clock, base);
    const duplicate_preserved = std.meta.eql(clock, ntp.Clock{
        .synchronized = duplicate_snapshot.synchronized,
        .unix_seconds = duplicate_snapshot.unix_seconds,
        .unix_fraction = duplicate_snapshot.unix_fraction,
        .stratum = duplicate_snapshot.stratum,
        .reference_id = duplicate_snapshot.reference_id,
        .accepted_samples = duplicate_snapshot.accepted_samples,
        .stale_samples = duplicate_snapshot.stale_samples + 1,
    });

    var backward = base;
    backward.unix_seconds -= 1;
    backward.unix_fraction = 0xFFFFFFFF;
    const backward_snapshot = clock;
    const backward_apply = ntp.applyResponse(&clock, backward);
    const backward_preserved = clock.synchronized == backward_snapshot.synchronized and
        clock.unix_seconds == backward_snapshot.unix_seconds and
        clock.unix_fraction == backward_snapshot.unix_fraction and
        clock.stratum == backward_snapshot.stratum and
        std.mem.eql(u8, &clock.reference_id, &backward_snapshot.reference_id) and
        clock.accepted_samples == backward_snapshot.accepted_samples and
        clock.stale_samples == backward_snapshot.stale_samples + 1;

    var fractional_forward = base;
    fractional_forward.unix_fraction = 0xC0000000;
    fractional_forward.stratum = 3;
    fractional_forward.reference_id = .{ 'F', 'R', 'A', 'C' };
    const fractional_forward_apply = ntp.applyResponse(&clock, fractional_forward);
    var second_forward = fractional_forward;
    second_forward.unix_seconds += 1;
    second_forward.unix_fraction = 0x10000000;
    second_forward.stratum = 4;
    second_forward.reference_id = .{ 'N', 'E', 'X', 'T' };
    const second_forward_apply = ntp.applyResponse(&clock, second_forward);
    const final_time = ntp.readClock(&clock) orelse return null;
    if (duplicate_apply != .stale or !duplicate_preserved or
        backward_apply != .stale or !backward_preserved or
        fractional_forward_apply != .accepted or second_forward_apply != .accepted or
        final_time.seconds != ntp.fixture_unix_seconds + 1 or final_time.fraction != 0x10000000 or
        clock.stratum != 4 or !std.mem.eql(u8, &clock.reference_id, "NEXT") or
        clock.accepted_samples != 3 or clock.stale_samples != 2)
    {
        return null;
    }
    return .{
        .initially_unsynchronized = initially_unsynchronized,
        .first_apply = first_apply,
        .duplicate_apply = duplicate_apply,
        .backward_apply = backward_apply,
        .fractional_forward_apply = fractional_forward_apply,
        .second_forward_apply = second_forward_apply,
        .duplicate_preserved = duplicate_preserved,
        .backward_preserved = backward_preserved,
        .final_seconds = final_time.seconds,
        .final_fraction = final_time.fraction,
        .final_stratum = clock.stratum,
        .final_reference_id = clock.reference_id,
        .accepted_samples = clock.accepted_samples,
        .stale_samples = clock.stale_samples,
    };
}

fn verifyNtpClientContext(device: *Device) ?NtpClientContextReport {
    const endpoints_before_invalid = device.udp_endpoint_count;
    const port_before_invalid = device.next_ephemeral_udp_port;
    const generation_before_invalid = device.next_udp_generation;
    const invalid_server_rejected = openNtpClient(device, .{ 0, 0, 0, 0 }) == null;
    const invalid_server_state_preserved = invalid_server_rejected and
        device.udp_endpoint_count == endpoints_before_invalid and
        device.next_ephemeral_udp_port == port_before_invalid and
        device.next_udp_generation == generation_before_invalid;
    if (!invalid_server_state_preserved) return null;

    const server_ipv4 = [4]u8{ 10, 0, 2, 4 };
    var client = openNtpClient(device, server_ipv4) orelse return null;
    const socket = client.socket;
    if (!client.active or socket.endpoint_index != 2 or socket.generation != 42 or
        socket.local_port != 49_183 or device.next_ephemeral_udp_port != 49_184 or
        device.next_udp_generation != 43 or device.udp_endpoint_count != 3 or
        device.tx_producer != 0 or device.next_udp_identification != 29 or
        device.next_dns_transaction_id != 8)
    {
        return null;
    }
    const submissions_before = device.tx_submissions;
    var request = startNtpClientRequest(device, &client, ntp.fixture_client_timestamp) orelse return null;
    if (request.transmit.identification != 29 or request.transmit.completion.descriptor_index != 0 or
        request.transmit.completion.next_cursor != 1 or request.transmit.completion.frame_length != 90 or
        device.next_udp_identification != 30 or device.tx_producer != 1 or
        device.tx_submissions != submissions_before + 1)
    {
        return null;
    }

    const receive_timestamp = (@as(u64, ntp.fixture_server_seconds) << 32) | 0x40000000;
    var payload_buffer = std.mem.zeroes([ntp.packet_bytes]u8);
    const payload = ntp.buildServerResponse(
        &payload_buffer,
        request.client_timestamp,
        receive_timestamp,
        ntp.fixture_server_timestamp,
    ) orelse return null;
    var frame = std.mem.zeroes([128]u8);
    const frame_length = udp.buildFrame(&frame, .{
        .source_mac = device.gateway_mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = server_ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = ntp.server_port,
        .destination_port = socket.local_port,
        .identification = 0x7400,
        .payload = payload,
    }) orelse return null;
    var packet = std.mem.zeroes(Packet);
    packet.length = frame_length;
    packet.source_descriptor = 0xE500;
    @memcpy(packet.bytes[0..frame_length], frame[0..frame_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return null;
    const dispatch = dispatchPacketBatch(device, 1);
    if (dispatch.examined != 1 or dispatch.routed != 1 or dispatch.dropped != 0) return null;
    const poll = pollNtpClientRequest(device, &client, &request, 1);
    const response = poll.response orelse return null;
    if (poll.state != .resolved or poll.examined != 1 or poll.rejected != 0 or
        response.unix_seconds != ntp.fixture_unix_seconds or response.unix_fraction != 0x80000000)
    {
        return null;
    }

    const close_succeeded = closeNtpClient(device, &client);
    const client_inactive = close_succeeded and !client.active and !udpSocketActive(device, socket);
    const ip_before_stale = device.next_udp_identification;
    const producer_before_stale = device.tx_producer;
    const submissions_before_stale = device.tx_submissions;
    const completions_before_stale = completionQueueEnqueued(&tx_completion_queue);
    const stale_start_rejected = startNtpClientRequest(device, &client, ntp.fixture_client_timestamp) == null;
    const stale_poll = pollNtpClientRequest(device, &client, &request, 1);
    const stale_retry_rejected = retryNtpClientRequest(device, &client, &request) == null;
    const stale_state_preserved = stale_start_rejected and stale_retry_rejected and
        stale_poll.state == .inactive and stale_poll.examined == 0 and stale_poll.rejected == 0 and
        device.next_udp_identification == ip_before_stale and device.tx_producer == producer_before_stale and
        device.tx_submissions == submissions_before_stale and
        completionQueueEnqueued(&tx_completion_queue) == completions_before_stale and request.transmissions == 1;
    if (!client_inactive or !stale_state_preserved) return null;

    const tx_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_184 or
        device.software_rx_queue.enqueued != 76 or device.software_rx_queue.dequeued != 76 or
        device.packets_dispatched != 65 or device.udp_packets_dispatched != 64 or
        tx_enqueues != 57 or tx_dequeues != 57 or rx_enqueues != 22 or overflow != 0 or
        device.next_dns_transaction_id != 8)
    {
        return null;
    }
    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .server_ipv4 = server_ipv4,
        .server_port = ntp.server_port,
        .invalid_server_rejected = invalid_server_rejected,
        .invalid_server_state_preserved = invalid_server_state_preserved,
        .client_timestamp = request.client_timestamp,
        .transmit_identification = request.transmit.identification,
        .transmit_descriptor = request.transmit.completion.descriptor_index,
        .transmit_next_cursor = request.transmit.completion.next_cursor,
        .transmit_frame_length = request.transmit.completion.frame_length,
        .poll_state = poll.state,
        .poll_examined = poll.examined,
        .poll_rejected = poll.rejected,
        .unix_seconds = response.unix_seconds,
        .unix_fraction = response.unix_fraction,
        .close_succeeded = close_succeeded,
        .client_inactive = client_inactive,
        .stale_start_rejected = stale_start_rejected,
        .stale_poll_state = stale_poll.state,
        .stale_retry_rejected = stale_retry_rejected,
        .stale_state_preserved = stale_state_preserved,
        .final_identification_cursor = device.next_udp_identification,
        .final_dns_transaction_cursor = device.next_dns_transaction_id,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = tx_enqueues,
        .tx_completion_dequeues = tx_dequeues,
        .rx_completion_enqueues = rx_enqueues,
        .completion_overflow = overflow,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpRetry(device: *Device) ?NtpRetryReport {
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (socket.endpoint_index != 2 or socket.generation != 41 or socket.local_port != 49_182 or
        device.next_ephemeral_udp_port != 49_183 or device.next_udp_generation != 42 or
        device.udp_endpoint_count != 3 or device.tx_producer != 6 or
        device.next_udp_identification != 27 or device.next_dns_transaction_id != 8)
    {
        return null;
    }
    const server_ipv4 = [4]u8{ 10, 0, 2, 4 };
    const peer = UdpPeer{ .mac = device.gateway_mac, .ipv4 = server_ipv4, .port = ntp.server_port };
    if (!connectUdpSocket(device, socket, peer)) return null;
    const submissions_before = device.tx_submissions;
    const wraps_before = device.tx_cursor_wraps;
    var request = startNtpRequest(device, socket, ntp.fixture_client_timestamp) orelse return null;
    const initial = request.transmit;
    if (initial.identification != 27 or initial.completion.descriptor_index != 6 or
        initial.completion.next_cursor != 7 or initial.completion.frame_length != 90 or
        request.transmissions != 1 or device.next_udp_identification != 28 or
        device.tx_producer != 7 or device.tx_cursor_wraps != wraps_before or
        device.tx_submissions != submissions_before + 1)
    {
        return null;
    }
    const pending = pollNtpRequest(device, &request, 2);
    if (pending.state != .pending or pending.examined != 0 or pending.rejected != 0 or pending.response != null) return null;

    const retry = retryNtpRequest(device, &request) orelse return null;
    if (retry.identification != 28 or retry.completion.descriptor_index != 7 or
        retry.completion.next_cursor != 0 or retry.completion.frame_length != 90 or
        request.transmissions != 2 or !std.meta.eql(request.transmit, retry) or
        device.next_udp_identification != 29 or device.tx_producer != 0 or
        device.tx_cursor_wraps != wraps_before + 1 or device.tx_submissions != submissions_before + 2)
    {
        return null;
    }

    const receive_timestamp = (@as(u64, ntp.fixture_server_seconds) << 32) | 0x40000000;
    var payload_buffer = std.mem.zeroes([ntp.packet_bytes]u8);
    const payload = ntp.buildServerResponse(
        &payload_buffer,
        ntp.fixture_client_timestamp,
        receive_timestamp,
        ntp.fixture_server_timestamp,
    ) orelse return null;
    var frame = std.mem.zeroes([128]u8);
    const frame_length = udp.buildFrame(&frame, .{
        .source_mac = peer.mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = peer.ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = peer.port,
        .destination_port = socket.local_port,
        .identification = 0x7300,
        .payload = payload,
    }) orelse return null;
    var packet = std.mem.zeroes(Packet);
    packet.length = frame_length;
    packet.source_descriptor = 0xE600;
    @memcpy(packet.bytes[0..frame_length], frame[0..frame_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return null;
    const dispatch = dispatchPacketBatch(device, 1);
    if (dispatch.examined != 1 or dispatch.routed != 1 or dispatch.dropped != 0) return null;
    const resolved = pollNtpRequest(device, &request, 1);
    const response = resolved.response orelse return null;
    if (resolved.state != .resolved or resolved.examined != 1 or resolved.rejected != 0 or
        response.unix_seconds != ntp.fixture_unix_seconds or response.unix_fraction != 0x80000000)
    {
        return null;
    }
    if (!closeUdpSocket(device, socket)) return null;

    const ip_before_stale = device.next_udp_identification;
    const producer_before_stale = device.tx_producer;
    const submissions_before_stale = device.tx_submissions;
    const completions_before_stale = completionQueueEnqueued(&tx_completion_queue);
    const transmissions_before_stale = request.transmissions;
    const stale_retry_rejected = retryNtpRequest(device, &request) == null;
    const stale_retry_state_preserved = stale_retry_rejected and
        device.next_udp_identification == ip_before_stale and device.tx_producer == producer_before_stale and
        device.tx_submissions == submissions_before_stale and
        completionQueueEnqueued(&tx_completion_queue) == completions_before_stale and
        request.transmissions == transmissions_before_stale;
    if (!stale_retry_state_preserved) return null;

    const tx_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_183 or
        device.software_rx_queue.enqueued != 75 or device.software_rx_queue.dequeued != 75 or
        device.packets_dispatched != 64 or device.udp_packets_dispatched != 63 or
        tx_enqueues != 56 or tx_dequeues != 56 or rx_enqueues != 22 or overflow != 0 or
        device.next_dns_transaction_id != 8 or @atomicLoad(u32, &tx_pending_mask, .acquire) != 0 or
        @atomicLoad(u32, &rx_pending_mask, .acquire) != all_rx_descriptors_pending)
    {
        return null;
    }
    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .client_timestamp = request.client_timestamp,
        .initial_identification = initial.identification,
        .initial_descriptor = initial.completion.descriptor_index,
        .initial_next_cursor = initial.completion.next_cursor,
        .initial_frame_length = initial.completion.frame_length,
        .pending_state = pending.state,
        .pending_examined = pending.examined,
        .pending_rejected = pending.rejected,
        .retry_identification = retry.identification,
        .retry_descriptor = retry.completion.descriptor_index,
        .retry_next_cursor = retry.completion.next_cursor,
        .retry_frame_length = retry.completion.frame_length,
        .transmissions = request.transmissions,
        .wraps_before = wraps_before,
        .wraps_after = device.tx_cursor_wraps,
        .resolved_state = resolved.state,
        .resolved_examined = resolved.examined,
        .resolved_rejected = resolved.rejected,
        .unix_seconds = response.unix_seconds,
        .unix_fraction = response.unix_fraction,
        .stale_retry_rejected = stale_retry_rejected,
        .stale_retry_state_preserved = stale_retry_state_preserved,
        .final_identification_cursor = device.next_udp_identification,
        .final_dns_transaction_cursor = device.next_dns_transaction_id,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = tx_enqueues,
        .tx_completion_dequeues = tx_dequeues,
        .rx_completion_enqueues = rx_enqueues,
        .completion_overflow = overflow,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpPolling(device: *Device) ?NtpPollingReport {
    const server_ipv4 = [4]u8{ 10, 0, 2, 4 };
    const peer = UdpPeer{ .mac = device.gateway_mac, .ipv4 = server_ipv4, .port = ntp.server_port };
    const receive_timestamp = (@as(u64, ntp.fixture_server_seconds) << 32) | 0x40000000;

    const polling_socket = openEphemeralUdpSocket(device) orelse return null;
    if (polling_socket.endpoint_index != 2 or polling_socket.generation != 39 or
        polling_socket.local_port != 49_180 or device.next_ephemeral_udp_port != 49_181 or
        device.next_udp_generation != 40 or device.udp_endpoint_count != 3 or
        device.tx_producer != 4 or device.next_udp_identification != 25 or
        device.next_dns_transaction_id != 8)
    {
        return null;
    }
    if (!connectUdpSocket(device, polling_socket, peer)) return null;
    const submissions_before = device.tx_submissions;
    var polling_request = startNtpRequest(device, polling_socket, ntp.fixture_client_timestamp) orelse return null;
    if (polling_request.transmissions != 1 or polling_request.cancelled or
        polling_request.transmit.identification != 25 or
        polling_request.transmit.completion.descriptor_index != 4 or
        polling_request.transmit.completion.next_cursor != 5 or
        polling_request.transmit.completion.frame_length != 90 or
        device.next_udp_identification != 26 or device.tx_producer != 5 or
        device.tx_submissions != submissions_before + 1)
    {
        return null;
    }

    var wrong_buffer = std.mem.zeroes([ntp.packet_bytes]u8);
    const wrong = ntp.buildServerResponse(
        &wrong_buffer,
        ntp.fixture_client_timestamp + 1,
        receive_timestamp,
        ntp.fixture_server_timestamp,
    ) orelse return null;
    var mode_buffer = std.mem.zeroes([ntp.packet_bytes]u8);
    const mode_base = ntp.buildServerResponse(
        &mode_buffer,
        ntp.fixture_client_timestamp,
        receive_timestamp,
        ntp.fixture_server_timestamp,
    ) orelse return null;
    mode_buffer[0] = (mode_buffer[0] & 0xF8) | 3;
    const bad_mode = mode_buffer[0..mode_base.len];
    var valid_buffer = std.mem.zeroes([ntp.packet_bytes]u8);
    const valid = ntp.buildServerResponse(
        &valid_buffer,
        ntp.fixture_client_timestamp,
        receive_timestamp,
        ntp.fixture_server_timestamp,
    ) orelse return null;
    const payloads = .{ wrong, bad_mode, valid };
    inline for (payloads, 0..) |payload, packet_index| {
        var frame = std.mem.zeroes([128]u8);
        const frame_length = udp.buildFrame(&frame, .{
            .source_mac = peer.mac,
            .destination_mac = device.local_mac,
            .source_ipv4 = peer.ipv4,
            .destination_ipv4 = device.local_ipv4,
            .source_port = peer.port,
            .destination_port = polling_socket.local_port,
            .identification = 0x7100 + packet_index,
            .payload = payload,
        }) orelse return null;
        var packet = std.mem.zeroes(Packet);
        packet.length = frame_length;
        packet.source_descriptor = 0xE800 + packet_index;
        @memcpy(packet.bytes[0..frame_length], frame[0..frame_length]);
        if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return null;
    }
    const polling_dispatch = dispatchPacketBatch(device, 3);
    if (polling_dispatch.examined != 3 or polling_dispatch.routed != 3 or
        polling_dispatch.dropped != 0 or polling_dispatch.remaining != 0)
    {
        return null;
    }
    const polling_endpoint = &device.udp_endpoints[polling_socket.endpoint_index];
    const zero = pollNtpRequest(device, &polling_request, 0);
    const zero_remaining = queueDepth(&polling_endpoint.queue);
    const first = pollNtpRequest(device, &polling_request, 2);
    const first_remaining = queueDepth(&polling_endpoint.queue);
    const second = pollNtpRequest(device, &polling_request, 2);
    const time = second.response orelse return null;
    if (zero.state != .pending or zero.examined != 0 or zero.rejected != 0 or zero_remaining != 3 or
        first.state != .pending or first.examined != 2 or first.rejected != 2 or first_remaining != 1 or
        second.state != .resolved or second.examined != 1 or second.rejected != 0 or
        time.unix_seconds != ntp.fixture_unix_seconds or time.unix_fraction != 0x80000000 or
        polling_endpoint.queue.dequeued != 3 or polling_endpoint.queue.head != polling_endpoint.queue.tail)
    {
        return null;
    }
    if (!closeUdpSocket(device, polling_socket)) return null;

    const cancellation_socket = openEphemeralUdpSocket(device) orelse return null;
    if (cancellation_socket.endpoint_index != 2 or cancellation_socket.generation != 40 or
        cancellation_socket.local_port != 49_181 or device.next_ephemeral_udp_port != 49_182 or
        device.next_udp_generation != 41 or device.udp_endpoint_count != 3 or
        device.tx_producer != 5 or device.next_udp_identification != 26)
    {
        return null;
    }
    if (!connectUdpSocket(device, cancellation_socket, peer)) return null;
    var cancellation_request = startNtpRequest(device, cancellation_socket, ntp.fixture_client_timestamp) orelse return null;
    if (cancellation_request.transmit.identification != 26 or
        cancellation_request.transmit.completion.descriptor_index != 5 or
        cancellation_request.transmit.completion.next_cursor != 6 or
        cancellation_request.transmit.completion.frame_length != 90 or
        device.next_udp_identification != 27 or device.tx_producer != 6 or
        device.tx_submissions != submissions_before + 2)
    {
        return null;
    }
    var cancellation_frame = std.mem.zeroes([128]u8);
    const cancellation_length = udp.buildFrame(&cancellation_frame, .{
        .source_mac = peer.mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = peer.ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = peer.port,
        .destination_port = cancellation_socket.local_port,
        .identification = 0x7200,
        .payload = valid,
    }) orelse return null;
    var cancellation_packet = std.mem.zeroes(Packet);
    cancellation_packet.length = cancellation_length;
    cancellation_packet.source_descriptor = 0xE700;
    @memcpy(cancellation_packet.bytes[0..cancellation_length], cancellation_frame[0..cancellation_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, cancellation_packet)) return null;
    const cancellation_dispatch = dispatchPacketBatch(device, 1);
    if (cancellation_dispatch.examined != 1 or cancellation_dispatch.routed != 1 or
        cancellation_dispatch.dropped != 0)
    {
        return null;
    }
    const cancellation_endpoint = &device.udp_endpoints[cancellation_socket.endpoint_index];
    const queued_before_cancel = queueDepth(&cancellation_endpoint.queue);
    const cancelled = cancelNtpRequest(&cancellation_request);
    const duplicate_cancel_rejected = !cancelNtpRequest(&cancellation_request);
    const cancelled_poll = pollNtpRequest(device, &cancellation_request, 1);
    const queue_preserved = queueDepth(&cancellation_endpoint.queue) == 1 and
        cancellation_endpoint.queue.dequeued == 0;
    const normal_close_rejected = !closeUdpSocket(device, cancellation_socket);
    const closed = closeUdpSocketDiscarding(device, cancellation_socket) orelse return null;
    if (queued_before_cancel != 1 or !cancelled or !duplicate_cancel_rejected or
        cancelled_poll.state != .inactive or cancelled_poll.examined != 0 or
        cancelled_poll.rejected != 0 or !queue_preserved or !normal_close_rejected or
        closed.discarded_packets != 1 or closed.queue_enqueued != 1 or closed.queue_dequeued != 1)
    {
        return null;
    }

    const tx_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_182 or
        device.software_rx_queue.enqueued != 74 or device.software_rx_queue.dequeued != 74 or
        device.packets_dispatched != 63 or device.udp_packets_dispatched != 62 or
        tx_enqueues != 54 or tx_dequeues != 54 or rx_enqueues != 22 or overflow != 0 or
        device.next_dns_transaction_id != 8 or @atomicLoad(u32, &tx_pending_mask, .acquire) != 0 or
        @atomicLoad(u32, &rx_pending_mask, .acquire) != all_rx_descriptors_pending)
    {
        return null;
    }
    return .{
        .polling_slot = polling_socket.endpoint_index,
        .polling_generation = polling_socket.generation,
        .polling_port = polling_socket.local_port,
        .polling_identification = polling_request.transmit.identification,
        .polling_descriptor = polling_request.transmit.completion.descriptor_index,
        .polling_next_cursor = polling_request.transmit.completion.next_cursor,
        .polling_frame_length = polling_request.transmit.completion.frame_length,
        .zero_state = zero.state,
        .zero_examined = zero.examined,
        .zero_rejected = zero.rejected,
        .zero_remaining = zero_remaining,
        .first_state = first.state,
        .first_examined = first.examined,
        .first_rejected = first.rejected,
        .first_remaining = first_remaining,
        .second_state = second.state,
        .second_examined = second.examined,
        .second_rejected = second.rejected,
        .unix_seconds = time.unix_seconds,
        .unix_fraction = time.unix_fraction,
        .cancellation_slot = cancellation_socket.endpoint_index,
        .cancellation_generation = cancellation_socket.generation,
        .cancellation_port = cancellation_socket.local_port,
        .cancellation_identification = cancellation_request.transmit.identification,
        .cancellation_descriptor = cancellation_request.transmit.completion.descriptor_index,
        .cancellation_next_cursor = cancellation_request.transmit.completion.next_cursor,
        .cancellation_frame_length = cancellation_request.transmit.completion.frame_length,
        .queued_before_cancel = queued_before_cancel,
        .cancelled = cancelled,
        .duplicate_cancel_rejected = duplicate_cancel_rejected,
        .cancelled_poll_state = cancelled_poll.state,
        .cancelled_poll_examined = cancelled_poll.examined,
        .cancelled_poll_rejected = cancelled_poll.rejected,
        .queue_preserved = queue_preserved,
        .normal_close_rejected = normal_close_rejected,
        .discarded_packets = closed.discarded_packets,
        .final_identification_cursor = device.next_udp_identification,
        .final_dns_transaction_cursor = device.next_dns_transaction_id,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = tx_enqueues,
        .tx_completion_dequeues = tx_dequeues,
        .rx_completion_enqueues = rx_enqueues,
        .completion_overflow = overflow,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpTransaction(device: *Device) ?NtpTransactionReport {
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (socket.endpoint_index != 2 or socket.generation != 38 or socket.local_port != 49_179 or
        device.next_ephemeral_udp_port != 49_180 or device.next_udp_generation != 39 or
        device.udp_endpoint_count != 3 or device.tx_producer != 3 or
        device.next_udp_identification != 24 or device.next_dns_transaction_id != 8)
    {
        return null;
    }
    const server_ipv4 = [4]u8{ 10, 0, 2, 4 };
    const peer = UdpPeer{ .mac = device.gateway_mac, .ipv4 = server_ipv4, .port = ntp.server_port };
    if (!connectUdpSocket(device, socket, peer)) return null;
    const submissions_before = device.tx_submissions;
    const ip_before_reject = device.next_udp_identification;
    const producer_before_reject = device.tx_producer;
    const completions_before_reject = completionQueueEnqueued(&tx_completion_queue);
    const invalid_timestamp_rejected = sendNtpRequest(device, socket, 0) == null;
    const rejection_state_preserved = invalid_timestamp_rejected and
        device.next_udp_identification == ip_before_reject and
        device.tx_producer == producer_before_reject and device.tx_submissions == submissions_before and
        completionQueueEnqueued(&tx_completion_queue) == completions_before_reject;
    if (!rejection_state_preserved) return null;

    const transmit = sendNtpRequest(device, socket, ntp.fixture_client_timestamp) orelse return null;
    if (transmit.identification != 24 or transmit.completion.descriptor_index != 3 or
        transmit.completion.next_cursor != 4 or transmit.completion.frame_length != 90 or
        device.next_udp_identification != 25 or device.tx_producer != 4 or
        device.tx_submissions != submissions_before + 1)
    {
        return null;
    }

    const receive_timestamp = (@as(u64, ntp.fixture_server_seconds) << 32) | 0x40000000;
    var wrong_buffer = std.mem.zeroes([ntp.packet_bytes]u8);
    const wrong_payload = ntp.buildServerResponse(
        &wrong_buffer,
        ntp.fixture_client_timestamp + 1,
        receive_timestamp,
        ntp.fixture_server_timestamp,
    ) orelse return null;
    var valid_buffer = std.mem.zeroes([ntp.packet_bytes]u8);
    const valid_payload = ntp.buildServerResponse(
        &valid_buffer,
        ntp.fixture_client_timestamp,
        receive_timestamp,
        ntp.fixture_server_timestamp,
    ) orelse return null;
    const payloads = .{ wrong_payload, valid_payload };
    inline for (payloads, 0..) |payload, packet_index| {
        var frame = std.mem.zeroes([128]u8);
        const frame_length = udp.buildFrame(&frame, .{
            .source_mac = peer.mac,
            .destination_mac = device.local_mac,
            .source_ipv4 = peer.ipv4,
            .destination_ipv4 = device.local_ipv4,
            .source_port = peer.port,
            .destination_port = socket.local_port,
            .identification = 0x7000 + packet_index,
            .payload = payload,
        }) orelse return null;
        var packet = std.mem.zeroes(Packet);
        packet.length = frame_length;
        packet.source_descriptor = 0xE900 + packet_index;
        @memcpy(packet.bytes[0..frame_length], frame[0..frame_length]);
        if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return null;
    }
    const dispatch = dispatchPacketBatch(device, 2);
    if (dispatch.examined != 2 or dispatch.routed != 2 or dispatch.dropped != 0 or dispatch.remaining != 0) return null;
    const endpoint = &device.udp_endpoints[socket.endpoint_index];
    if (endpoint.queue.enqueued != 2 or endpoint.queue.dequeued != 0 or
        endpoint.queue.high_water != 2 or endpoint.queue.dropped != 0)
    {
        return null;
    }
    const wrong_originate_rejected = receiveNtpResponse(device, socket, ntp.fixture_client_timestamp) == null;
    const response = receiveNtpResponse(device, socket, ntp.fixture_client_timestamp) orelse return null;
    if (!wrong_originate_rejected or response.unix_seconds != ntp.fixture_unix_seconds or
        response.unix_fraction != 0x80000000 or response.stratum != 2 or response.poll != 6 or
        response.precision != -20 or !std.mem.eql(u8, &response.reference_id, "LOCL") or
        endpoint.queue.dequeued != 2 or endpoint.queue.head != endpoint.queue.tail)
    {
        return null;
    }

    const endpoint_enqueued = endpoint.queue.enqueued;
    const endpoint_dequeued = endpoint.queue.dequeued;
    const endpoint_high_water = endpoint.queue.high_water;
    const endpoint_dropped = endpoint.queue.dropped;
    if (!closeUdpSocket(device, socket)) return null;
    const tx_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_180 or
        device.software_rx_queue.enqueued != 70 or device.software_rx_queue.dequeued != 70 or
        device.packets_dispatched != 59 or device.udp_packets_dispatched != 58 or
        tx_enqueues != 52 or tx_dequeues != 52 or rx_enqueues != 22 or overflow != 0 or
        device.next_dns_transaction_id != 8)
    {
        return null;
    }
    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .server_ipv4 = server_ipv4,
        .server_port = peer.port,
        .client_timestamp = ntp.fixture_client_timestamp,
        .invalid_timestamp_rejected = invalid_timestamp_rejected,
        .rejection_state_preserved = rejection_state_preserved,
        .transmit_identification = transmit.identification,
        .transmit_descriptor = transmit.completion.descriptor_index,
        .transmit_next_cursor = transmit.completion.next_cursor,
        .transmit_frame_length = transmit.completion.frame_length,
        .wrong_originate_rejected = wrong_originate_rejected,
        .unix_seconds = response.unix_seconds,
        .unix_fraction = response.unix_fraction,
        .stratum = response.stratum,
        .poll = response.poll,
        .precision = response.precision,
        .reference_id = response.reference_id,
        .endpoint_enqueued = endpoint_enqueued,
        .endpoint_dequeued = endpoint_dequeued,
        .endpoint_high_water = endpoint_high_water,
        .endpoint_dropped = endpoint_dropped,
        .final_identification_cursor = device.next_udp_identification,
        .final_dns_transaction_cursor = device.next_dns_transaction_id,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = tx_enqueues,
        .tx_completion_dequeues = tx_dequeues,
        .rx_completion_enqueues = rx_enqueues,
        .completion_overflow = overflow,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyNtpCodec() ?NtpCodecReport {
    var request_buffer = std.mem.zeroes([ntp.packet_bytes]u8);
    const request = ntp.buildClientRequest(&request_buffer, ntp.fixture_client_timestamp) orelse return null;
    if (request.len != ntp.packet_bytes) return null;
    const receive_timestamp = (@as(u64, ntp.fixture_server_seconds) << 32) | 0x40000000;
    var response_buffer = std.mem.zeroes([ntp.packet_bytes]u8);
    const response = ntp.buildServerResponse(
        &response_buffer,
        ntp.fixture_client_timestamp,
        receive_timestamp,
        ntp.fixture_server_timestamp,
    ) orelse return null;
    const parsed = ntp.parseServerResponse(response, ntp.fixture_client_timestamp) orelse return null;
    if (response.len != ntp.packet_bytes or parsed.leap_indicator != 0 or parsed.version != 4 or
        parsed.stratum != 2 or parsed.poll != 6 or parsed.precision != -20 or
        parsed.root_delay != 0x00010000 or parsed.root_dispersion != 0x00008000 or
        !std.mem.eql(u8, &parsed.reference_id, "LOCL") or
        parsed.receive_timestamp != receive_timestamp or
        parsed.transmit_timestamp != ntp.fixture_server_timestamp or
        parsed.unix_seconds != ntp.fixture_unix_seconds or parsed.unix_fraction != 0x80000000)
    {
        return null;
    }

    var small_buffer = std.mem.zeroes([ntp.packet_bytes - 1]u8);
    const zero_timestamp_rejected = ntp.buildClientRequest(&request_buffer, 0) == null;
    const small_buffer_rejected = ntp.buildClientRequest(&small_buffer, ntp.fixture_client_timestamp) == null;
    var wrong_mode = response_buffer;
    wrong_mode[0] = (wrong_mode[0] & 0xF8) | 3;
    const wrong_mode_rejected = ntp.parseServerResponse(&wrong_mode, ntp.fixture_client_timestamp) == null;
    var alarm = response_buffer;
    alarm[0] |= 0xC0;
    const alarm_rejected = ntp.parseServerResponse(&alarm, ntp.fixture_client_timestamp) == null;
    var invalid_stratum = response_buffer;
    invalid_stratum[1] = 0;
    const invalid_stratum_rejected = ntp.parseServerResponse(&invalid_stratum, ntp.fixture_client_timestamp) == null;
    const wrong_originate_rejected = ntp.parseServerResponse(response, ntp.fixture_client_timestamp + 1) == null;
    var zero_transmit = response_buffer;
    @memset(zero_transmit[40..48], 0);
    const zero_transmit_rejected = ntp.parseServerResponse(&zero_transmit, ntp.fixture_client_timestamp) == null;
    var pre_epoch = response_buffer;
    pre_epoch[40] = 0;
    pre_epoch[41] = 0;
    pre_epoch[42] = 0;
    pre_epoch[43] = 1;
    const pre_epoch_rejected = ntp.parseServerResponse(&pre_epoch, ntp.fixture_client_timestamp) == null;
    const truncated_rejected = ntp.parseServerResponse(
        response[0 .. response.len - 1],
        ntp.fixture_client_timestamp,
    ) == null;
    if (!zero_timestamp_rejected or !small_buffer_rejected or !wrong_mode_rejected or
        !alarm_rejected or !invalid_stratum_rejected or !wrong_originate_rejected or
        !zero_transmit_rejected or !pre_epoch_rejected or !truncated_rejected)
    {
        return null;
    }

    return .{
        .client_timestamp = ntp.fixture_client_timestamp,
        .server_timestamp = ntp.fixture_server_timestamp,
        .request_length = @intCast(request.len),
        .request_hash = tftp.updatePayloadHash(tftp.initial_fnv1a64, request),
        .response_length = @intCast(response.len),
        .response_hash = tftp.updatePayloadHash(tftp.initial_fnv1a64, response),
        .leap_indicator = parsed.leap_indicator,
        .version = parsed.version,
        .stratum = parsed.stratum,
        .poll = parsed.poll,
        .precision = parsed.precision,
        .root_delay = parsed.root_delay,
        .root_dispersion = parsed.root_dispersion,
        .reference_id = parsed.reference_id,
        .unix_seconds = parsed.unix_seconds,
        .unix_fraction = parsed.unix_fraction,
        .zero_timestamp_rejected = zero_timestamp_rejected,
        .small_buffer_rejected = small_buffer_rejected,
        .wrong_mode_rejected = wrong_mode_rejected,
        .alarm_rejected = alarm_rejected,
        .invalid_stratum_rejected = invalid_stratum_rejected,
        .wrong_originate_rejected = wrong_originate_rejected,
        .zero_transmit_rejected = zero_transmit_rejected,
        .pre_epoch_rejected = pre_epoch_rejected,
        .truncated_rejected = truncated_rejected,
    };
}

fn verifyDnsResolverContext(device: *Device) ?DnsResolverContextReport {
    const endpoints_before_invalid = device.udp_endpoint_count;
    const port_before_invalid = device.next_ephemeral_udp_port;
    const generation_before_invalid = device.next_udp_generation;
    const invalid_server_rejected = openDnsResolver(device, .{ 0, 0, 0, 0 }) == null;
    const invalid_server_state_preserved = invalid_server_rejected and
        device.udp_endpoint_count == endpoints_before_invalid and
        device.next_ephemeral_udp_port == port_before_invalid and
        device.next_udp_generation == generation_before_invalid;
    if (!invalid_server_state_preserved) return null;

    const server_ipv4 = [4]u8{ 10, 0, 2, 3 };
    var resolver = openDnsResolver(device, server_ipv4) orelse return null;
    const socket = resolver.socket;
    if (!resolver.active or socket.endpoint_index != 2 or socket.generation != 37 or
        socket.local_port != 49_178 or device.next_ephemeral_udp_port != 49_179 or
        device.next_udp_generation != 38 or device.udp_endpoint_count != 3 or
        device.tx_producer != 2 or device.next_udp_identification != 23 or
        device.next_dns_transaction_id != 7 or dns.cacheEntryCount(&resolver.cache) != 0)
    {
        return null;
    }
    const submissions_before = device.tx_submissions;
    const start = startDnsResolverA(device, &resolver, 0, dns.fixture_name) orelse return null;
    var request = switch (start) {
        .pending => |pending| pending,
        else => return null,
    };
    if (request.transaction_id != 7 or request.transmit.identification != 23 or
        request.transmit.completion.descriptor_index != 2 or request.transmit.completion.next_cursor != 3 or
        request.transmit.completion.frame_length != 70 or device.next_dns_transaction_id != 8 or
        device.next_udp_identification != 24 or device.tx_producer != 3 or
        device.tx_submissions != submissions_before + 1 or resolver.cache.misses != 1)
    {
        return null;
    }

    var payload_buffer = std.mem.zeroes([256]u8);
    const payload = dns.buildAResponse(
        &payload_buffer,
        request.transaction_id,
        dns.fixture_name,
        dns.fixture_address,
        dns.default_ttl,
    ) orelse return null;
    var frame = std.mem.zeroes([128]u8);
    const frame_length = udp.buildFrame(&frame, .{
        .source_mac = device.gateway_mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = server_ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = dns.server_port,
        .destination_port = socket.local_port,
        .identification = 0x6F00,
        .payload = payload,
    }) orelse return null;
    var packet = std.mem.zeroes(Packet);
    packet.length = frame_length;
    packet.source_descriptor = 0xEA00;
    @memcpy(packet.bytes[0..frame_length], frame[0..frame_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return null;
    const dispatch = dispatchPacketBatch(device, 1);
    if (dispatch.examined != 1 or dispatch.routed != 1 or dispatch.dropped != 0) return null;
    const resolved = pollDnsResolverA(device, &resolver, &request, 0, 1, 60);
    const answer = resolved.response orelse return null;
    if (resolved.state != .resolved or resolved.examined != 1 or resolved.rejected != 0 or
        !std.mem.eql(u8, &answer.address, &dns.fixture_address) or answer.ttl != dns.default_ttl or
        resolver.cache.stores != 1 or dns.cacheEntryCount(&resolver.cache) != 1)
    {
        return null;
    }

    const submissions_before_hit = device.tx_submissions;
    const dns_before_hit = device.next_dns_transaction_id;
    const ip_before_hit = device.next_udp_identification;
    const producer_before_hit = device.tx_producer;
    const completions_before_hit = completionQueueEnqueued(&tx_completion_queue);
    const hit = startDnsResolverA(device, &resolver, 100, "ZIGOS.TEST") orelse return null;
    const cached = switch (hit) {
        .cached => |value| value,
        else => return null,
    };
    const cached_hit = std.mem.eql(u8, &cached.address, &dns.fixture_address) and cached.ttl_remaining == 200;
    const cached_hit_no_tx = cached_hit and device.tx_submissions == submissions_before_hit and
        device.next_dns_transaction_id == dns_before_hit and device.next_udp_identification == ip_before_hit and
        device.tx_producer == producer_before_hit and completionQueueEnqueued(&tx_completion_queue) == completions_before_hit;
    if (!cached_hit_no_tx) return null;

    const close_succeeded = closeDnsResolver(device, &resolver);
    const resolver_inactive = close_succeeded and !resolver.active and !udpSocketActive(device, socket);
    const dns_before_stale = device.next_dns_transaction_id;
    const ip_before_stale = device.next_udp_identification;
    const producer_before_stale = device.tx_producer;
    const submissions_before_stale = device.tx_submissions;
    const cache_hits_before_stale = resolver.cache.hits;
    const stale_start_rejected = startDnsResolverA(device, &resolver, 100, dns.fixture_name) == null;
    const stale_state_preserved = stale_start_rejected and
        device.next_dns_transaction_id == dns_before_stale and device.next_udp_identification == ip_before_stale and
        device.tx_producer == producer_before_stale and device.tx_submissions == submissions_before_stale and
        resolver.cache.hits == cache_hits_before_stale;
    if (!resolver_inactive or !stale_state_preserved) return null;

    const tx_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_179 or
        device.software_rx_queue.enqueued != 68 or device.software_rx_queue.dequeued != 68 or
        device.packets_dispatched != 57 or device.udp_packets_dispatched != 56 or
        tx_enqueues != 51 or tx_dequeues != 51 or rx_enqueues != 22 or overflow != 0 or
        resolver.cache.hits != 1 or resolver.cache.misses != 1 or resolver.cache.stores != 1 or
        dns.cacheEntryCount(&resolver.cache) != 1)
    {
        return null;
    }
    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .server_ipv4 = server_ipv4,
        .server_port = dns.server_port,
        .invalid_server_rejected = invalid_server_rejected,
        .invalid_server_state_preserved = invalid_server_state_preserved,
        .transaction_id = request.transaction_id,
        .transmit_identification = request.transmit.identification,
        .transmit_descriptor = request.transmit.completion.descriptor_index,
        .transmit_next_cursor = request.transmit.completion.next_cursor,
        .transmit_frame_length = request.transmit.completion.frame_length,
        .resolved_state = resolved.state,
        .resolved_examined = resolved.examined,
        .resolved_rejected = resolved.rejected,
        .address = answer.address,
        .ttl = answer.ttl,
        .cached_hit = cached_hit,
        .cached_ttl_remaining = cached.ttl_remaining,
        .cached_hit_no_tx = cached_hit_no_tx,
        .close_succeeded = close_succeeded,
        .resolver_inactive = resolver_inactive,
        .stale_start_rejected = stale_start_rejected,
        .stale_state_preserved = stale_state_preserved,
        .final_dns_transaction_cursor = device.next_dns_transaction_id,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = tx_enqueues,
        .tx_completion_dequeues = tx_dequeues,
        .rx_completion_enqueues = rx_enqueues,
        .completion_overflow = overflow,
        .cache_hits = resolver.cache.hits,
        .cache_misses = resolver.cache.misses,
        .cache_stores = resolver.cache.stores,
        .cache_active_entries = dns.cacheEntryCount(&resolver.cache),
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyDnsCancellation(device: *Device) ?DnsCancellationReport {
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (socket.endpoint_index != 2 or socket.generation != 36 or socket.local_port != 49_177 or
        device.next_ephemeral_udp_port != 49_178 or device.next_udp_generation != 37 or
        device.udp_endpoint_count != 3 or device.tx_producer != 1 or
        device.next_udp_identification != 22 or device.next_dns_transaction_id != 6)
    {
        return null;
    }
    const peer = UdpPeer{ .mac = device.gateway_mac, .ipv4 = .{ 10, 0, 2, 3 }, .port = dns.server_port };
    if (!connectUdpSocket(device, socket, peer)) return null;
    const submissions_before = device.tx_submissions;
    var request = startAutomaticDnsAQuery(device, socket, dns.fixture_name) orelse return null;
    if (request.transaction_id != 6 or request.transmit.identification != 22 or
        request.transmit.completion.descriptor_index != 1 or request.transmit.completion.next_cursor != 2 or
        request.transmit.completion.frame_length != 70 or request.cancelled or
        device.next_dns_transaction_id != 7 or device.next_udp_identification != 23 or
        device.tx_producer != 2 or device.tx_submissions != submissions_before + 1)
    {
        return null;
    }

    var payload_buffer = std.mem.zeroes([256]u8);
    const payload = dns.buildAResponse(
        &payload_buffer,
        request.transaction_id,
        dns.fixture_name,
        dns.fixture_address,
        dns.default_ttl,
    ) orelse return null;
    var frame = std.mem.zeroes([128]u8);
    const frame_length = udp.buildFrame(&frame, .{
        .source_mac = peer.mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = peer.ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = peer.port,
        .destination_port = socket.local_port,
        .identification = 0x6E00,
        .payload = payload,
    }) orelse return null;
    var packet = std.mem.zeroes(Packet);
    packet.length = frame_length;
    packet.source_descriptor = 0xEB00;
    @memcpy(packet.bytes[0..frame_length], frame[0..frame_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return null;
    const dispatch = dispatchPacketBatch(device, 1);
    if (dispatch.examined != 1 or dispatch.routed != 1 or dispatch.dropped != 0) return null;
    const endpoint = &device.udp_endpoints[socket.endpoint_index];
    const queued_before_cancel = queueDepth(&endpoint.queue);
    if (queued_before_cancel != 1) return null;

    const cancelled = cancelDnsAQuery(&request);
    const duplicate_cancel_rejected = !cancelDnsAQuery(&request);
    const poll = pollDnsAQuery(device, &request, 1);
    const queue_preserved = queueDepth(&endpoint.queue) == 1 and endpoint.queue.dequeued == 0;
    if (!cancelled or !duplicate_cancel_rejected or poll.state != .inactive or
        poll.examined != 0 or poll.rejected != 0 or poll.response != null or !queue_preserved)
    {
        return null;
    }

    const dns_before_retry = device.next_dns_transaction_id;
    const ip_before_retry = device.next_udp_identification;
    const producer_before_retry = device.tx_producer;
    const submissions_before_retry = device.tx_submissions;
    const completions_before_retry = completionQueueEnqueued(&tx_completion_queue);
    const transmissions_before_retry = request.transmissions;
    const retry_rejected = retryDnsAQuery(device, &request) == null;
    const retry_cursors_preserved = retry_rejected and request.transmissions == transmissions_before_retry and
        device.next_dns_transaction_id == dns_before_retry and device.next_udp_identification == ip_before_retry and
        device.tx_producer == producer_before_retry and device.tx_submissions == submissions_before_retry and
        completionQueueEnqueued(&tx_completion_queue) == completions_before_retry;
    if (!retry_cursors_preserved) return null;

    const normal_close_rejected = !closeUdpSocket(device, socket);
    const closed = closeUdpSocketDiscarding(device, socket) orelse return null;
    if (!normal_close_rejected or closed.discarded_packets != 1 or closed.queue_enqueued != 1 or
        closed.queue_dequeued != 1 or closed.queue_high_water != 1 or closed.queue_dropped != 0)
    {
        return null;
    }
    const stale_poll = pollDnsAQuery(device, &request, 1);
    if (stale_poll.state != .inactive or stale_poll.examined != 0 or stale_poll.rejected != 0) return null;

    const tx_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_178 or
        device.software_rx_queue.enqueued != 67 or device.software_rx_queue.dequeued != 67 or
        device.packets_dispatched != 56 or device.udp_packets_dispatched != 55 or
        tx_enqueues != 50 or tx_dequeues != 50 or rx_enqueues != 22 or overflow != 0)
    {
        return null;
    }
    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .transaction_id = request.transaction_id,
        .transmit_identification = request.transmit.identification,
        .transmit_descriptor = request.transmit.completion.descriptor_index,
        .transmit_next_cursor = request.transmit.completion.next_cursor,
        .transmit_frame_length = request.transmit.completion.frame_length,
        .queued_before_cancel = queued_before_cancel,
        .cancelled = cancelled,
        .duplicate_cancel_rejected = duplicate_cancel_rejected,
        .poll_state = poll.state,
        .poll_examined = poll.examined,
        .poll_rejected = poll.rejected,
        .queue_preserved = queue_preserved,
        .retry_rejected = retry_rejected,
        .retry_cursors_preserved = retry_cursors_preserved,
        .normal_close_rejected = normal_close_rejected,
        .discarded_packets = closed.discarded_packets,
        .stale_poll_state = stale_poll.state,
        .final_dns_transaction_cursor = device.next_dns_transaction_id,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = tx_enqueues,
        .tx_completion_dequeues = tx_dequeues,
        .rx_completion_enqueues = rx_enqueues,
        .completion_overflow = overflow,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyDnsNegativeCache(device: *Device) ?DnsNegativeCacheReport {
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (socket.endpoint_index != 2 or socket.generation != 35 or socket.local_port != 49_176 or
        device.next_ephemeral_udp_port != 49_177 or device.next_udp_generation != 36 or
        device.udp_endpoint_count != 3 or device.tx_producer != 7 or
        device.next_udp_identification != 20 or device.next_dns_transaction_id != 4)
    {
        return null;
    }
    const server_ipv4 = [4]u8{ 10, 0, 2, 3 };
    const peer = UdpPeer{ .mac = device.gateway_mac, .ipv4 = server_ipv4, .port = dns.server_port };
    if (!connectUdpSocket(device, socket, peer)) return null;
    var cache = std.mem.zeroes(dns.Cache);
    const name = "missing.zigos.test";
    const submissions_before = device.tx_submissions;
    const first_start = startAutomaticDnsAResolveCachedOutcome(device, socket, &cache, 0, name) orelse return null;
    var request = switch (first_start) {
        .pending => |pending| pending,
        else => return null,
    };
    if (request.transaction_id != 4 or request.transmit.identification != 20 or
        request.transmit.completion.descriptor_index != 7 or request.transmit.completion.next_cursor != 0 or
        request.transmit.completion.frame_length != 78 or device.next_dns_transaction_id != 5 or
        device.next_udp_identification != 21 or device.tx_producer != 0 or
        device.tx_submissions != submissions_before + 1 or cache.misses != 1)
    {
        return null;
    }

    var payload_buffer = std.mem.zeroes([256]u8);
    const payload = dns.buildNameErrorResponse(&payload_buffer, request.transaction_id, name) orelse return null;
    var frame = std.mem.zeroes([128]u8);
    const frame_length = udp.buildFrame(&frame, .{
        .source_mac = peer.mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = peer.ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = peer.port,
        .destination_port = socket.local_port,
        .identification = 0x6D00,
        .payload = payload,
    }) orelse return null;
    var packet = std.mem.zeroes(Packet);
    packet.length = frame_length;
    packet.source_descriptor = 0xEC00;
    @memcpy(packet.bytes[0..frame_length], frame[0..frame_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return null;
    const dispatch = dispatchPacketBatch(device, 1);
    if (dispatch.examined != 1 or dispatch.routed != 1 or dispatch.dropped != 0) return null;
    const poll = pollDnsAResolveCachedOutcome(device, &request, &cache, 0, 1, 60);
    const negative_stored = poll.state == .not_found and cache.stores == 1 and dns.cacheEntryCount(&cache) == 1;
    if (!negative_stored) return null;

    const submissions_before_hit = device.tx_submissions;
    const dns_before_hit = device.next_dns_transaction_id;
    const ip_before_hit = device.next_udp_identification;
    const producer_before_hit = device.tx_producer;
    const completions_before_hit = completionQueueEnqueued(&tx_completion_queue);
    const hit_start = startAutomaticDnsAResolveCachedOutcome(device, socket, &cache, 10, "MISSING.ZIGOS.TEST") orelse return null;
    const cached_ttl = switch (hit_start) {
        .not_found => |ttl| ttl,
        else => return null,
    };
    const cached_not_found = cached_ttl == 50;
    const cached_hit_no_tx = cached_not_found and device.tx_submissions == submissions_before_hit and
        device.next_dns_transaction_id == dns_before_hit and device.next_udp_identification == ip_before_hit and
        device.tx_producer == producer_before_hit and completionQueueEnqueued(&tx_completion_queue) == completions_before_hit;
    if (!cached_hit_no_tx) return null;

    const expiry_start = startAutomaticDnsAResolveCachedOutcome(device, socket, &cache, 60, name) orelse return null;
    var expiry_request = switch (expiry_start) {
        .pending => |pending| pending,
        else => return null,
    };
    if (expiry_request.transaction_id != 5 or expiry_request.transmit.identification != 21 or
        expiry_request.transmit.completion.descriptor_index != 0 or expiry_request.transmit.completion.next_cursor != 1 or
        expiry_request.transmit.completion.frame_length != 78 or device.next_dns_transaction_id != 6 or
        device.next_udp_identification != 22 or device.tx_producer != 1 or
        device.tx_submissions != submissions_before + 2 or cache.hits != 1 or cache.misses != 2 or
        cache.expirations != 1 or dns.cacheEntryCount(&cache) != 0)
    {
        return null;
    }

    if (!closeUdpSocket(device, socket)) return null;
    const stale = pollDnsAResolveCachedOutcome(device, &expiry_request, &cache, 60, 1, 60);
    if (stale.state != .inactive or stale.examined != 0 or stale.rejected != 0 or cache.stores != 1) return null;
    const tx_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_177 or
        device.software_rx_queue.enqueued != 66 or device.software_rx_queue.dequeued != 66 or
        device.packets_dispatched != 55 or device.udp_packets_dispatched != 54 or
        tx_enqueues != 49 or tx_dequeues != 49 or rx_enqueues != 22 or overflow != 0 or
        cache.hits != 1 or cache.misses != 2 or cache.stores != 1 or cache.expirations != 1 or
        dns.cacheEntryCount(&cache) != 0)
    {
        return null;
    }
    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .server_ipv4 = server_ipv4,
        .server_port = peer.port,
        .transaction_id = request.transaction_id,
        .transmit_identification = request.transmit.identification,
        .transmit_descriptor = request.transmit.completion.descriptor_index,
        .transmit_next_cursor = request.transmit.completion.next_cursor,
        .transmit_frame_length = request.transmit.completion.frame_length,
        .poll_state = poll.state,
        .negative_stored = negative_stored,
        .cached_not_found = cached_not_found,
        .cached_ttl_remaining = cached_ttl,
        .cached_hit_no_tx = cached_hit_no_tx,
        .expiry_transaction_id = expiry_request.transaction_id,
        .expiry_identification = expiry_request.transmit.identification,
        .expiry_descriptor = expiry_request.transmit.completion.descriptor_index,
        .expiry_next_cursor = expiry_request.transmit.completion.next_cursor,
        .expiry_frame_length = expiry_request.transmit.completion.frame_length,
        .stale_state = stale.state,
        .final_dns_transaction_cursor = device.next_dns_transaction_id,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = tx_enqueues,
        .tx_completion_dequeues = tx_dequeues,
        .rx_completion_enqueues = rx_enqueues,
        .completion_overflow = overflow,
        .cache_hits = cache.hits,
        .cache_misses = cache.misses,
        .cache_stores = cache.stores,
        .cache_expirations = cache.expirations,
        .cache_active_entries = dns.cacheEntryCount(&cache),
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyDnsNegative(device: *Device) ?DnsNegativeReport {
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (socket.endpoint_index != 2 or socket.generation != 34 or socket.local_port != 49_175 or
        device.next_ephemeral_udp_port != 49_176 or device.next_udp_generation != 35 or
        device.udp_endpoint_count != 3 or device.tx_producer != 6 or
        device.next_udp_identification != 19 or device.next_dns_transaction_id != 3)
    {
        return null;
    }
    const server_ipv4 = [4]u8{ 10, 0, 2, 3 };
    const peer = UdpPeer{
        .mac = device.gateway_mac,
        .ipv4 = server_ipv4,
        .port = dns.server_port,
    };
    if (!connectUdpSocket(device, socket, peer)) return null;
    const submissions_before = device.tx_submissions;
    var request = startAutomaticDnsAQuery(device, socket, "missing.zigos.test") orelse return null;
    if (request.transaction_id != 3 or request.transmit.identification != 19 or
        request.transmit.completion.descriptor_index != 6 or
        request.transmit.completion.next_cursor != 7 or
        request.transmit.completion.frame_length != 78 or
        device.next_dns_transaction_id != 4 or device.next_udp_identification != 20 or
        device.tx_producer != 7 or device.tx_submissions != submissions_before + 1)
    {
        return null;
    }

    var payload_buffer = std.mem.zeroes([256]u8);
    const payload = dns.buildNameErrorResponse(
        &payload_buffer,
        request.transaction_id,
        request.name[0..request.name_length],
    ) orelse return null;
    var frame = std.mem.zeroes([128]u8);
    const frame_length = udp.buildFrame(&frame, .{
        .source_mac = peer.mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = peer.ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = peer.port,
        .destination_port = socket.local_port,
        .identification = 0x6C00,
        .payload = payload,
    }) orelse return null;
    var packet = std.mem.zeroes(Packet);
    packet.length = frame_length;
    packet.source_descriptor = 0xED00;
    @memcpy(packet.bytes[0..frame_length], frame[0..frame_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return null;
    const dispatch = dispatchPacketBatch(device, 1);
    if (dispatch.examined != 1 or dispatch.routed != 1 or dispatch.dropped != 0 or dispatch.remaining != 0) return null;
    const poll = pollDnsAQuery(device, &request, 1);
    const endpoint = &device.udp_endpoints[socket.endpoint_index];
    const response_absent = poll.response == null;
    const queue_empty = endpoint.queue.head == endpoint.queue.tail and endpoint.queue.dequeued == 1;
    if (poll.state != .not_found or poll.examined != 1 or poll.rejected != 0 or
        !response_absent or !queue_empty)
    {
        return null;
    }
    if (!closeUdpSocket(device, socket)) return null;
    const stale = pollDnsAQuery(device, &request, 1);
    if (stale.state != .inactive or stale.examined != 0 or stale.rejected != 0 or stale.response != null) return null;

    const tx_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_176 or
        device.software_rx_queue.enqueued != 65 or device.software_rx_queue.dequeued != 65 or
        device.packets_dispatched != 54 or device.udp_packets_dispatched != 53 or
        tx_enqueues != 47 or tx_dequeues != 47 or rx_enqueues != 22 or overflow != 0 or
        @atomicLoad(u32, &tx_pending_mask, .acquire) != 0 or
        @atomicLoad(u32, &rx_pending_mask, .acquire) != all_rx_descriptors_pending)
    {
        return null;
    }
    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .server_ipv4 = server_ipv4,
        .server_port = peer.port,
        .transaction_id = request.transaction_id,
        .transmit_identification = request.transmit.identification,
        .transmit_descriptor = request.transmit.completion.descriptor_index,
        .transmit_next_cursor = request.transmit.completion.next_cursor,
        .transmit_frame_length = request.transmit.completion.frame_length,
        .poll_state = poll.state,
        .poll_examined = poll.examined,
        .poll_rejected = poll.rejected,
        .response_absent = response_absent,
        .queue_empty = queue_empty,
        .stale_state = stale.state,
        .final_dns_transaction_cursor = device.next_dns_transaction_id,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = tx_enqueues,
        .tx_completion_dequeues = tx_dequeues,
        .rx_completion_enqueues = rx_enqueues,
        .completion_overflow = overflow,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyDnsAutomaticCachedResolve(device: *Device) ?DnsAutomaticCachedResolveReport {
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (socket.endpoint_index != 2 or socket.generation != 33 or socket.local_port != 49_174 or
        device.next_ephemeral_udp_port != 49_175 or device.next_udp_generation != 34 or
        device.udp_endpoint_count != 3 or device.tx_producer != 5 or
        device.next_udp_identification != 18 or device.next_dns_transaction_id != 2)
    {
        return null;
    }
    const dns_server_ipv4 = [4]u8{ 10, 0, 2, 3 };
    const peer = UdpPeer{
        .mac = device.gateway_mac,
        .ipv4 = dns_server_ipv4,
        .port = dns.server_port,
    };
    if (!connectUdpSocket(device, socket, peer)) return null;
    var cache = std.mem.zeroes(dns.Cache);
    const preload_stored = dns.storeCachedA(&cache, dns.fixture_name, dns.fixture_address, 1000, 0);
    if (!preload_stored or cache.stores != 1 or dns.cacheEntryCount(&cache) != 1) return null;

    const submissions_before = device.tx_submissions;
    const dns_before_hit = device.next_dns_transaction_id;
    const ip_before_hit = device.next_udp_identification;
    const producer_before_hit = device.tx_producer;
    const completions_before_hit = completionQueueEnqueued(&tx_completion_queue);
    const initial_start = startAutomaticDnsAResolve(
        device,
        socket,
        &cache,
        100,
        "ZIGOS.TEST",
    ) orelse return null;
    const initial_cached = switch (initial_start) {
        .cached => |cached| cached,
        .pending => return null,
    };
    const initial_cached_hit = std.mem.eql(u8, &initial_cached.address, &dns.fixture_address) and
        initial_cached.ttl_remaining == 900;
    const initial_hit_no_tx = initial_cached_hit and device.next_dns_transaction_id == dns_before_hit and
        device.next_udp_identification == ip_before_hit and device.tx_producer == producer_before_hit and
        device.tx_submissions == submissions_before and
        completionQueueEnqueued(&tx_completion_queue) == completions_before_hit;
    if (!initial_hit_no_tx) return null;

    const expired_start = startAutomaticDnsAResolve(
        device,
        socket,
        &cache,
        1000,
        dns.fixture_name,
    ) orelse return null;
    var request = switch (expired_start) {
        .cached => return null,
        .pending => |pending| pending,
    };
    const expired_transmit = request.transmit;
    if (request.transaction_id != 2 or expired_transmit.identification != 18 or
        expired_transmit.completion.descriptor_index != 5 or expired_transmit.completion.next_cursor != 6 or
        expired_transmit.completion.frame_length != 70 or device.next_dns_transaction_id != 3 or
        device.next_udp_identification != 19 or device.tx_producer != 6 or
        device.tx_submissions != submissions_before + 1 or cache.expirations != 1 or
        cache.misses != 1 or dns.cacheEntryCount(&cache) != 0)
    {
        return null;
    }

    var response_buffer = std.mem.zeroes([256]u8);
    const response_payload = dns.buildAResponse(
        &response_buffer,
        request.transaction_id,
        dns.fixture_name,
        dns.fixture_address,
        dns.default_ttl,
    ) orelse return null;
    var response_frame = std.mem.zeroes([128]u8);
    const response_length = udp.buildFrame(&response_frame, .{
        .source_mac = peer.mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = peer.ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = peer.port,
        .destination_port = socket.local_port,
        .identification = 0x6B00,
        .payload = response_payload,
    }) orelse return null;
    var packet = std.mem.zeroes(Packet);
    packet.length = response_length;
    packet.source_descriptor = 0xEE00;
    @memcpy(packet.bytes[0..response_length], response_frame[0..response_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return null;
    const dispatch = dispatchPacketBatch(device, 1);
    if (dispatch.examined != 1 or dispatch.routed != 1 or dispatch.dropped != 0 or dispatch.remaining != 0) return null;
    const resolved = pollDnsAResolve(device, &request, &cache, 1000, 1);
    const answer = resolved.response orelse return null;
    if (resolved.state != .resolved or resolved.examined != 1 or resolved.rejected != 0 or
        !std.mem.eql(u8, &answer.address, &dns.fixture_address) or answer.ttl != dns.default_ttl or
        cache.stores != 2 or dns.cacheEntryCount(&cache) != 1)
    {
        return null;
    }

    const submissions_before_refresh_hit = device.tx_submissions;
    const dns_before_refresh_hit = device.next_dns_transaction_id;
    const ip_before_refresh_hit = device.next_udp_identification;
    const producer_before_refresh_hit = device.tx_producer;
    const completions_before_refresh_hit = completionQueueEnqueued(&tx_completion_queue);
    const refreshed_start = startAutomaticDnsAResolve(
        device,
        socket,
        &cache,
        1100,
        "ZiGoS.TeSt",
    ) orelse return null;
    const refreshed_cached = switch (refreshed_start) {
        .cached => |cached| cached,
        .pending => return null,
    };
    const refreshed_cached_hit = std.mem.eql(u8, &refreshed_cached.address, &dns.fixture_address) and
        refreshed_cached.ttl_remaining == 200;
    const refreshed_hit_no_tx = refreshed_cached_hit and
        device.next_dns_transaction_id == dns_before_refresh_hit and
        device.next_udp_identification == ip_before_refresh_hit and
        device.tx_producer == producer_before_refresh_hit and
        device.tx_submissions == submissions_before_refresh_hit and
        completionQueueEnqueued(&tx_completion_queue) == completions_before_refresh_hit;
    if (!refreshed_hit_no_tx) return null;

    const dns_before_invalid = device.next_dns_transaction_id;
    const ip_before_invalid = device.next_udp_identification;
    const producer_before_invalid = device.tx_producer;
    const submissions_before_invalid = device.tx_submissions;
    const completions_before_invalid = completionQueueEnqueued(&tx_completion_queue);
    const invalid_name_rejected = startAutomaticDnsAResolve(
        device,
        socket,
        &cache,
        1100,
        "bad..name",
    ) == null;
    const invalid_name_cursors_preserved = invalid_name_rejected and
        device.next_dns_transaction_id == dns_before_invalid and
        device.next_udp_identification == ip_before_invalid and
        device.tx_producer == producer_before_invalid and
        device.tx_submissions == submissions_before_invalid and
        completionQueueEnqueued(&tx_completion_queue) == completions_before_invalid;
    if (!invalid_name_cursors_preserved) return null;

    if (!closeUdpSocket(device, socket)) return null;
    const tx_completion_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_completion_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_completion_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const completion_overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_175 or
        device.software_rx_queue.enqueued != 64 or device.software_rx_queue.dequeued != 64 or
        device.software_rx_queue.dropped != 0 or device.software_rx_queue.head != device.software_rx_queue.tail or
        device.packets_dispatched != 53 or device.udp_packets_dispatched != 52 or
        device.unmatched_udp_packets_dropped != 3 or device.invalid_udp_packets_dropped != 3 or
        device.peer_mismatch_udp_packets_dropped != 3 or device.unknown_packets_dropped != 0 or
        tx_completion_enqueues != 46 or tx_completion_dequeues != 46 or rx_completion_enqueues != 22 or
        completion_overflow != 0 or @atomicLoad(u32, &tx_pending_mask, .acquire) != 0 or
        @atomicLoad(u32, &rx_pending_mask, .acquire) != all_rx_descriptors_pending or
        cache.hits != 2 or cache.misses != 1 or cache.stores != 2 or cache.expirations != 1 or
        dns.cacheEntryCount(&cache) != 1)
    {
        return null;
    }
    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .server_ipv4 = dns_server_ipv4,
        .server_port = peer.port,
        .preload_stored = preload_stored,
        .initial_cached_hit = initial_cached_hit,
        .initial_cached_ttl = initial_cached.ttl_remaining,
        .initial_hit_no_tx = initial_hit_no_tx,
        .expired_transaction_id = request.transaction_id,
        .expired_identification = expired_transmit.identification,
        .expired_descriptor = expired_transmit.completion.descriptor_index,
        .expired_next_cursor = expired_transmit.completion.next_cursor,
        .expired_frame_length = expired_transmit.completion.frame_length,
        .resolved_state = resolved.state,
        .resolved_examined = resolved.examined,
        .resolved_rejected = resolved.rejected,
        .resolved_address = answer.address,
        .resolved_ttl = answer.ttl,
        .refreshed_cached_hit = refreshed_cached_hit,
        .refreshed_cached_ttl = refreshed_cached.ttl_remaining,
        .refreshed_hit_no_tx = refreshed_hit_no_tx,
        .invalid_name_rejected = invalid_name_rejected,
        .invalid_name_cursors_preserved = invalid_name_cursors_preserved,
        .final_dns_transaction_cursor = device.next_dns_transaction_id,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = tx_completion_enqueues,
        .tx_completion_dequeues = tx_completion_dequeues,
        .rx_completion_enqueues = rx_completion_enqueues,
        .completion_overflow = completion_overflow,
        .cache_hits = cache.hits,
        .cache_misses = cache.misses,
        .cache_stores = cache.stores,
        .cache_expirations = cache.expirations,
        .cache_active_entries = dns.cacheEntryCount(&cache),
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyDnsAutomaticTransaction(device: *Device) ?DnsAutomaticTransactionReport {
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (socket.endpoint_index != 2 or socket.generation != 32 or socket.local_port != 49_173 or
        device.next_ephemeral_udp_port != 49_174 or device.next_udp_generation != 33 or
        device.udp_endpoint_count != 3 or device.tx_producer != 2 or
        device.next_udp_identification != 15 or device.next_dns_transaction_id != 0x5000)
    {
        return null;
    }
    const peer = UdpPeer{
        .mac = device.gateway_mac,
        .ipv4 = .{ 10, 0, 2, 3 },
        .port = dns.server_port,
    };
    if (!connectUdpSocket(device, socket, peer)) return null;

    const submissions_before = device.tx_submissions;
    const wraps_before = device.tx_cursor_wraps;
    const invalid_dns_before = device.next_dns_transaction_id;
    const invalid_ip_before = device.next_udp_identification;
    const invalid_producer_before = device.tx_producer;
    const invalid_completions_before = completionQueueEnqueued(&tx_completion_queue);
    const invalid_name_rejected = startAutomaticDnsAQuery(device, socket, "bad..name") == null;
    const invalid_name_cursors_preserved = invalid_name_rejected and
        device.next_dns_transaction_id == invalid_dns_before and
        device.next_udp_identification == invalid_ip_before and
        device.tx_producer == invalid_producer_before and
        device.tx_submissions == submissions_before and
        completionQueueEnqueued(&tx_completion_queue) == invalid_completions_before;
    if (!invalid_name_cursors_preserved) return null;

    const first = startAutomaticDnsAQuery(device, socket, dns.fixture_name) orelse return null;
    device.next_dns_transaction_id = 0xFFFF;
    const second = startAutomaticDnsAQuery(device, socket, dns.fixture_name) orelse return null;
    const third = startAutomaticDnsAQuery(device, socket, dns.fixture_alias_name) orelse return null;
    const transaction_ids = [_]u16{ first.transaction_id, second.transaction_id, third.transaction_id };
    const packet_identifications = [_]u16{
        first.transmit.identification,
        second.transmit.identification,
        third.transmit.identification,
    };
    const descriptors = [_]u16{
        first.transmit.completion.descriptor_index,
        second.transmit.completion.descriptor_index,
        third.transmit.completion.descriptor_index,
    };
    const next_cursors = [_]u16{
        first.transmit.completion.next_cursor,
        second.transmit.completion.next_cursor,
        third.transmit.completion.next_cursor,
    };
    const frame_lengths = [_]u16{
        first.transmit.completion.frame_length,
        second.transmit.completion.frame_length,
        third.transmit.completion.frame_length,
    };
    const transmission_counts = [_]u16{ first.transmissions, second.transmissions, third.transmissions };
    if (!std.mem.eql(u16, &transaction_ids, &[_]u16{ 0x5000, 0xFFFF, 1 }) or
        !std.mem.eql(u16, &packet_identifications, &[_]u16{ 15, 16, 17 }) or
        !std.mem.eql(u16, &descriptors, &[_]u16{ 2, 3, 4 }) or
        !std.mem.eql(u16, &next_cursors, &[_]u16{ 3, 4, 5 }) or
        !std.mem.eql(u16, &frame_lengths, &[_]u16{ 70, 70, 76 }) or
        !std.mem.eql(u16, &transmission_counts, &[_]u16{ 1, 1, 1 }) or
        device.next_dns_transaction_id != 2 or device.next_udp_identification != 18 or
        device.tx_producer != 5 or device.tx_cursor_wraps != wraps_before or
        device.tx_submissions != submissions_before + 3)
    {
        return null;
    }

    if (!closeUdpSocket(device, socket)) return null;
    const stale_dns_before = device.next_dns_transaction_id;
    const stale_ip_before = device.next_udp_identification;
    const stale_producer_before = device.tx_producer;
    const stale_submissions_before = device.tx_submissions;
    const stale_completions_before = completionQueueEnqueued(&tx_completion_queue);
    const stale_socket_rejected = startAutomaticDnsAQuery(device, socket, dns.fixture_name) == null;
    const stale_socket_cursors_preserved = stale_socket_rejected and
        device.next_dns_transaction_id == stale_dns_before and
        device.next_udp_identification == stale_ip_before and
        device.tx_producer == stale_producer_before and
        device.tx_submissions == stale_submissions_before and
        completionQueueEnqueued(&tx_completion_queue) == stale_completions_before;
    if (!stale_socket_cursors_preserved) return null;

    const tx_completion_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_completion_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_completion_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const completion_overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_174 or
        device.software_rx_queue.enqueued != 63 or device.software_rx_queue.dequeued != 63 or
        device.software_rx_queue.dropped != 0 or device.software_rx_queue.head != device.software_rx_queue.tail or
        device.packets_dispatched != 52 or device.udp_packets_dispatched != 51 or
        device.unmatched_udp_packets_dropped != 3 or device.invalid_udp_packets_dropped != 3 or
        device.peer_mismatch_udp_packets_dropped != 3 or device.unknown_packets_dropped != 0 or
        tx_completion_enqueues != 45 or tx_completion_dequeues != 45 or rx_completion_enqueues != 22 or
        completion_overflow != 0 or @atomicLoad(u32, &tx_pending_mask, .acquire) != 0 or
        @atomicLoad(u32, &rx_pending_mask, .acquire) != all_rx_descriptors_pending)
    {
        return null;
    }
    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .invalid_name_rejected = invalid_name_rejected,
        .invalid_name_cursors_preserved = invalid_name_cursors_preserved,
        .transaction_ids = transaction_ids,
        .packet_identifications = packet_identifications,
        .descriptors = descriptors,
        .next_cursors = next_cursors,
        .frame_lengths = frame_lengths,
        .transmission_counts = transmission_counts,
        .stale_socket_rejected = stale_socket_rejected,
        .stale_socket_cursors_preserved = stale_socket_cursors_preserved,
        .final_dns_transaction_cursor = device.next_dns_transaction_id,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = tx_completion_enqueues,
        .tx_completion_dequeues = tx_completion_dequeues,
        .rx_completion_enqueues = rx_completion_enqueues,
        .completion_overflow = completion_overflow,
        .tx_wraps_unchanged = device.tx_cursor_wraps == wraps_before,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyDnsCachedResolve(device: *Device) ?DnsCachedResolveReport {
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (socket.endpoint_index != 2 or socket.generation != 31 or socket.local_port != 49_172 or
        device.next_ephemeral_udp_port != 49_173 or device.next_udp_generation != 32 or
        device.udp_endpoint_count != 3 or device.tx_producer != 0 or device.next_udp_identification != 13)
    {
        return null;
    }
    const dns_server_ipv4 = [4]u8{ 10, 0, 2, 3 };
    const peer = UdpPeer{
        .mac = device.gateway_mac,
        .ipv4 = dns_server_ipv4,
        .port = dns.server_port,
    };
    if (!connectUdpSocket(device, socket, peer)) return null;
    var cache = std.mem.zeroes(dns.Cache);
    const transaction_id: u16 = dns.fixture_transaction_id + 5;
    const submissions_before = device.tx_submissions;

    const miss_start = startDnsAResolve(
        device,
        socket,
        &cache,
        1000,
        transaction_id,
        dns.fixture_name,
    ) orelse return null;
    var request = switch (miss_start) {
        .cached => return null,
        .pending => |pending| pending,
    };
    const miss_transmit = request.transmit;
    if (cache.misses != 1 or cache.hits != 0 or request.transmissions != 1 or
        miss_transmit.identification != 13 or miss_transmit.completion.descriptor_index != 0 or
        miss_transmit.completion.next_cursor != 1 or miss_transmit.completion.frame_length != 70 or
        device.next_udp_identification != 14 or device.tx_producer != 1 or
        device.tx_submissions != submissions_before + 1)
    {
        return null;
    }

    var response_buffer = std.mem.zeroes([256]u8);
    const response_payload = dns.buildAResponse(
        &response_buffer,
        transaction_id,
        dns.fixture_name,
        dns.fixture_address,
        dns.default_ttl,
    ) orelse return null;
    var response_frame = std.mem.zeroes([128]u8);
    const response_length = udp.buildFrame(&response_frame, .{
        .source_mac = peer.mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = peer.ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = peer.port,
        .destination_port = socket.local_port,
        .identification = 0x6A00,
        .payload = response_payload,
    }) orelse return null;
    var packet = std.mem.zeroes(Packet);
    packet.length = response_length;
    packet.source_descriptor = 0xEF00;
    @memcpy(packet.bytes[0..response_length], response_frame[0..response_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return null;
    const dispatch = dispatchPacketBatch(device, 1);
    if (dispatch.examined != 1 or dispatch.routed != 1 or dispatch.dropped != 0 or dispatch.remaining != 0) return null;
    const resolved = pollDnsAResolve(device, &request, &cache, 1000, 1);
    const answer = resolved.response orelse return null;
    if (resolved.state != .resolved or resolved.examined != 1 or resolved.rejected != 0 or
        !std.mem.eql(u8, &answer.address, &dns.fixture_address) or answer.ttl != dns.default_ttl or
        cache.stores != 1 or dns.cacheEntryCount(&cache) != 1)
    {
        return null;
    }

    const submissions_before_hit = device.tx_submissions;
    const producer_before_hit = device.tx_producer;
    const identification_before_hit = device.next_udp_identification;
    const completions_before_hit = completionQueueEnqueued(&tx_completion_queue);
    const hit_start = startDnsAResolve(
        device,
        socket,
        &cache,
        1100,
        transaction_id + 1,
        "ZIGOS.TEST",
    ) orelse return null;
    const cached = switch (hit_start) {
        .cached => |value| value,
        .pending => return null,
    };
    const cached_hit = std.mem.eql(u8, &cached.address, &dns.fixture_address) and cached.ttl_remaining == 200;
    const cached_hit_no_tx = cached_hit and device.tx_submissions == submissions_before_hit and
        device.tx_producer == producer_before_hit and device.next_udp_identification == identification_before_hit and
        completionQueueEnqueued(&tx_completion_queue) == completions_before_hit;
    if (!cached_hit_no_tx) return null;

    const expired_start = startDnsAResolve(
        device,
        socket,
        &cache,
        1300,
        transaction_id + 2,
        dns.fixture_name,
    ) orelse return null;
    var expired_request = switch (expired_start) {
        .cached => return null,
        .pending => |pending| pending,
    };
    const expiry_transmit = expired_request.transmit;
    if (expiry_transmit.identification != 14 or expiry_transmit.completion.descriptor_index != 1 or
        expiry_transmit.completion.next_cursor != 2 or expiry_transmit.completion.frame_length != 70 or
        device.next_udp_identification != 15 or device.tx_producer != 2 or
        device.tx_submissions != submissions_before + 2 or cache.hits != 1 or cache.misses != 2 or
        cache.expirations != 1 or dns.cacheEntryCount(&cache) != 0)
    {
        return null;
    }

    if (!closeUdpSocket(device, socket)) return null;
    const stale_pending = pollDnsAResolve(device, &expired_request, &cache, 1300, 1);
    if (stale_pending.state != .inactive or stale_pending.examined != 0 or stale_pending.rejected != 0 or
        stale_pending.response != null or cache.stores != 1)
    {
        return null;
    }

    const tx_completion_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_completion_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_completion_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const completion_overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_173 or
        device.software_rx_queue.enqueued != 63 or device.software_rx_queue.dequeued != 63 or
        device.software_rx_queue.dropped != 0 or device.software_rx_queue.head != device.software_rx_queue.tail or
        device.packets_dispatched != 52 or device.udp_packets_dispatched != 51 or
        device.unmatched_udp_packets_dropped != 3 or device.invalid_udp_packets_dropped != 3 or
        device.peer_mismatch_udp_packets_dropped != 3 or device.unknown_packets_dropped != 0 or
        tx_completion_enqueues != 42 or tx_completion_dequeues != 42 or rx_completion_enqueues != 22 or
        completion_overflow != 0 or @atomicLoad(u32, &tx_pending_mask, .acquire) != 0 or
        @atomicLoad(u32, &rx_pending_mask, .acquire) != all_rx_descriptors_pending)
    {
        return null;
    }
    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .server_ipv4 = dns_server_ipv4,
        .server_port = peer.port,
        .transaction_id = transaction_id,
        .miss_identification = miss_transmit.identification,
        .miss_descriptor = miss_transmit.completion.descriptor_index,
        .miss_next_cursor = miss_transmit.completion.next_cursor,
        .miss_frame_length = miss_transmit.completion.frame_length,
        .resolved_state = resolved.state,
        .resolved_examined = resolved.examined,
        .address = answer.address,
        .ttl = answer.ttl,
        .cache_store_count = cache.stores,
        .cached_hit = cached_hit,
        .cached_address = cached.address,
        .cached_ttl_remaining = cached.ttl_remaining,
        .cached_hit_no_tx = cached_hit_no_tx,
        .expiry_requery_identification = expiry_transmit.identification,
        .expiry_requery_descriptor = expiry_transmit.completion.descriptor_index,
        .expiry_requery_next_cursor = expiry_transmit.completion.next_cursor,
        .expiry_requery_frame_length = expiry_transmit.completion.frame_length,
        .stale_pending_state = stale_pending.state,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = tx_completion_enqueues,
        .tx_completion_dequeues = tx_completion_dequeues,
        .rx_completion_enqueues = rx_completion_enqueues,
        .completion_overflow = completion_overflow,
        .cache_hits = cache.hits,
        .cache_misses = cache.misses,
        .cache_expirations = cache.expirations,
        .cache_active_entries = dns.cacheEntryCount(&cache),
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyDnsCache() ?DnsCacheReport {
    var cache = std.mem.zeroes(dns.Cache);
    const invalid_store_rejected = !dns.storeCachedA(&cache, "bad..name", .{ 192, 0, 2, 1 }, 100, 0);
    const zero_ttl_rejected = !dns.storeCachedA(&cache, "zero.test", .{ 192, 0, 2, 1 }, 0, 0);
    if (!invalid_store_rejected or !zero_ttl_rejected or dns.cacheEntryCount(&cache) != 0 or
        cache.stores != 0 or cache.clock != 0)
    {
        return null;
    }

    if (!dns.storeCachedA(&cache, "a.test", .{ 192, 0, 2, 1 }, 200, 0) or
        !dns.storeCachedA(&cache, "b.test", .{ 192, 0, 2, 2 }, 200, 0) or
        !dns.storeCachedA(&cache, "c.test", .{ 192, 0, 2, 3 }, 50, 0) or
        !dns.storeCachedA(&cache, "d.test", .{ 192, 0, 2, 4 }, 200, 0))
    {
        return null;
    }
    const case_hit = dns.lookupCachedA(&cache, "B.TEST", 1) orelse return null;
    const case_insensitive_hit = std.mem.eql(u8, &case_hit.address, &[_]u8{ 192, 0, 2, 2 }) and
        case_hit.ttl_remaining == 199;
    if (!case_insensitive_hit) return null;

    if (!dns.storeCachedA(&cache, "e.test", .{ 192, 0, 2, 5 }, 200, 2)) return null;
    const eviction_verified = dns.lookupCachedA(&cache, "a.test", 2) == null;
    if (!eviction_verified) return null;
    _ = dns.lookupCachedA(&cache, "b.test", 2) orelse return null;
    _ = dns.lookupCachedA(&cache, "c.test", 2) orelse return null;
    _ = dns.lookupCachedA(&cache, "d.test", 2) orelse return null;
    _ = dns.lookupCachedA(&cache, "e.test", 2) orelse return null;

    const expiration_verified = dns.lookupCachedA(&cache, "c.test", 101) == null;
    if (!expiration_verified or !dns.storeCachedA(&cache, "f.test", .{ 192, 0, 2, 6 }, 200, 101)) return null;
    _ = dns.lookupCachedA(&cache, "d.test", 101) orelse return null;
    _ = dns.lookupCachedA(&cache, "e.test", 101) orelse return null;
    _ = dns.lookupCachedA(&cache, "f.test", 101) orelse return null;

    if (!dns.storeCachedA(&cache, "B.Test", .{ 192, 0, 2, 99 }, 300, 110)) return null;
    const refreshed = dns.lookupCachedA(&cache, "b.test", 110) orelse return null;
    const refresh_verified = std.mem.eql(u8, &refreshed.address, &[_]u8{ 192, 0, 2, 99 }) and
        refreshed.ttl_remaining == 300 and dns.cacheEntryCount(&cache) == dns.cache_capacity;
    if (!refresh_verified or cache.hits != 9 or cache.misses != 2 or cache.stores != 7 or
        cache.refreshes != 1 or cache.evictions != 1 or cache.expirations != 1)
    {
        return null;
    }

    return .{
        .capacity = dns.cache_capacity,
        .active_entries = dns.cacheEntryCount(&cache),
        .invalid_store_rejected = invalid_store_rejected,
        .zero_ttl_rejected = zero_ttl_rejected,
        .case_insensitive_hit = case_insensitive_hit,
        .first_ttl_remaining = case_hit.ttl_remaining,
        .eviction_verified = eviction_verified,
        .expiration_verified = expiration_verified,
        .refresh_verified = refresh_verified,
        .refreshed_address = refreshed.address,
        .refreshed_ttl_remaining = refreshed.ttl_remaining,
        .hits = cache.hits,
        .misses = cache.misses,
        .stores = cache.stores,
        .refreshes = cache.refreshes,
        .evictions = cache.evictions,
        .expirations = cache.expirations,
    };
}

fn verifyDnsRetry(device: *Device) ?DnsRetryReport {
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (socket.endpoint_index != 2 or socket.generation != 30 or socket.local_port != 49_171 or
        device.next_ephemeral_udp_port != 49_172 or device.next_udp_generation != 31 or
        device.udp_endpoint_count != 3 or device.tx_producer != 6 or device.next_udp_identification != 11)
    {
        return null;
    }
    const dns_server_ipv4 = [4]u8{ 10, 0, 2, 3 };
    const peer = UdpPeer{
        .mac = device.gateway_mac,
        .ipv4 = dns_server_ipv4,
        .port = dns.server_port,
    };
    if (!connectUdpSocket(device, socket, peer)) return null;

    const transaction_id: u16 = dns.fixture_transaction_id + 4;
    const submissions_before = device.tx_submissions;
    const wraps_before = device.tx_cursor_wraps;
    var request = startDnsAQuery(device, socket, transaction_id, dns.fixture_name) orelse return null;
    const initial = request.transmit;
    if (request.transmissions != 1 or initial.identification != 11 or
        initial.completion.descriptor_index != 6 or initial.completion.next_cursor != 7 or
        initial.completion.frame_length != 70 or device.next_udp_identification != 12 or
        device.tx_producer != 7 or device.tx_cursor_wraps != wraps_before or
        device.tx_submissions != submissions_before + 1)
    {
        return null;
    }
    const pending = pollDnsAQuery(device, &request, 2);
    if (pending.state != .pending or pending.examined != 0 or pending.rejected != 0 or pending.response != null) return null;

    const retry = retryDnsAQuery(device, &request) orelse return null;
    if (request.transmissions != 2 or !std.meta.eql(request.transmit, retry) or
        retry.identification != 12 or retry.completion.descriptor_index != 7 or
        retry.completion.next_cursor != 0 or retry.completion.frame_length != 70 or
        device.next_udp_identification != 13 or device.tx_producer != 0 or
        device.tx_cursor_wraps != wraps_before + 1 or device.tx_submissions != submissions_before + 2)
    {
        return null;
    }

    var response_buffer = std.mem.zeroes([256]u8);
    const response_payload = dns.buildAResponse(
        &response_buffer,
        transaction_id,
        dns.fixture_name,
        dns.fixture_address,
        dns.default_ttl,
    ) orelse return null;
    var response_frame = std.mem.zeroes([128]u8);
    const response_length = udp.buildFrame(&response_frame, .{
        .source_mac = peer.mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = peer.ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = peer.port,
        .destination_port = socket.local_port,
        .identification = 0x6900,
        .payload = response_payload,
    }) orelse return null;
    var packet = std.mem.zeroes(Packet);
    packet.length = response_length;
    packet.source_descriptor = 0xF000;
    @memcpy(packet.bytes[0..response_length], response_frame[0..response_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return null;
    const dispatch = dispatchPacketBatch(device, 1);
    if (dispatch.examined != 1 or dispatch.routed != 1 or dispatch.dropped != 0 or dispatch.remaining != 0) return null;
    const resolved = pollDnsAQuery(device, &request, 1);
    const answer = resolved.response orelse return null;
    if (resolved.state != .resolved or resolved.examined != 1 or resolved.rejected != 0 or
        !std.mem.eql(u8, &answer.address, &dns.fixture_address) or answer.ttl != dns.default_ttl or
        answer.alias_hops != 0)
    {
        return null;
    }

    if (!closeUdpSocket(device, socket)) return null;
    const identification_before_stale = device.next_udp_identification;
    const producer_before_stale = device.tx_producer;
    const submissions_before_stale = device.tx_submissions;
    const completions_before_stale = completionQueueEnqueued(&tx_completion_queue);
    const stale_retry_rejected = retryDnsAQuery(device, &request) == null;
    const cursor_preserved_on_stale_retry = stale_retry_rejected and
        device.next_udp_identification == identification_before_stale and
        device.tx_producer == producer_before_stale and device.tx_submissions == submissions_before_stale and
        completionQueueEnqueued(&tx_completion_queue) == completions_before_stale and request.transmissions == 2;
    if (!cursor_preserved_on_stale_retry) return null;

    const tx_completion_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_completion_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_completion_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const completion_overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_172 or
        device.software_rx_queue.enqueued != 62 or device.software_rx_queue.dequeued != 62 or
        device.software_rx_queue.dropped != 0 or device.software_rx_queue.head != device.software_rx_queue.tail or
        device.packets_dispatched != 51 or device.udp_packets_dispatched != 50 or
        device.unmatched_udp_packets_dropped != 3 or device.invalid_udp_packets_dropped != 3 or
        device.peer_mismatch_udp_packets_dropped != 3 or device.unknown_packets_dropped != 0 or
        tx_completion_enqueues != 40 or tx_completion_dequeues != 40 or rx_completion_enqueues != 22 or
        completion_overflow != 0 or @atomicLoad(u32, &tx_pending_mask, .acquire) != 0 or
        @atomicLoad(u32, &rx_pending_mask, .acquire) != all_rx_descriptors_pending)
    {
        return null;
    }
    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .server_ipv4 = dns_server_ipv4,
        .server_port = peer.port,
        .transaction_id = transaction_id,
        .name_length = request.name_length,
        .name_hash = tftp.updatePayloadHash(tftp.initial_fnv1a64, request.name[0..request.name_length]),
        .initial_identification = initial.identification,
        .initial_descriptor = initial.completion.descriptor_index,
        .initial_next_cursor = initial.completion.next_cursor,
        .initial_frame_length = initial.completion.frame_length,
        .pending_state = pending.state,
        .pending_examined = pending.examined,
        .pending_rejected = pending.rejected,
        .retry_identification = retry.identification,
        .retry_descriptor = retry.completion.descriptor_index,
        .retry_next_cursor = retry.completion.next_cursor,
        .retry_frame_length = retry.completion.frame_length,
        .transmissions = request.transmissions,
        .tx_wraps_before = wraps_before,
        .tx_wraps_after = device.tx_cursor_wraps,
        .resolved_state = resolved.state,
        .resolved_examined = resolved.examined,
        .resolved_rejected = resolved.rejected,
        .address = answer.address,
        .ttl = answer.ttl,
        .stale_retry_rejected = stale_retry_rejected,
        .cursor_preserved_on_stale_retry = cursor_preserved_on_stale_retry,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = tx_completion_enqueues,
        .tx_completion_dequeues = tx_completion_dequeues,
        .rx_completion_enqueues = rx_completion_enqueues,
        .completion_overflow = completion_overflow,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyDnsAliasTransaction(device: *Device) ?DnsAliasTransactionReport {
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (socket.endpoint_index != 2 or socket.generation != 29 or socket.local_port != 49_170 or
        device.next_ephemeral_udp_port != 49_171 or device.next_udp_generation != 30 or
        device.udp_endpoint_count != 3 or device.tx_producer != 5 or device.next_udp_identification != 10)
    {
        return null;
    }
    const dns_server_ipv4 = [4]u8{ 10, 0, 2, 3 };
    const peer = UdpPeer{
        .mac = device.gateway_mac,
        .ipv4 = dns_server_ipv4,
        .port = dns.server_port,
    };
    if (!connectUdpSocket(device, socket, peer)) return null;

    const transaction_id: u16 = dns.fixture_transaction_id + 3;
    const submissions_before = device.tx_submissions;
    const request = startDnsAQuery(device, socket, transaction_id, dns.fixture_alias_name) orelse return null;
    if (request.name_length != dns.fixture_alias_name.len or
        request.transmit.identification != 10 or request.transmit.completion.descriptor_index != 5 or
        request.transmit.completion.next_cursor != 6 or request.transmit.completion.frame_length != 76 or
        device.next_udp_identification != 11 or device.tx_producer != 6 or
        device.tx_submissions != submissions_before + 1)
    {
        return null;
    }

    var response_buffer = std.mem.zeroes([256]u8);
    const response_payload = dns.buildCnameAResponse(
        &response_buffer,
        transaction_id,
        dns.fixture_alias_name,
        dns.fixture_name,
        dns.fixture_address,
        dns.default_ttl,
    ) orelse return null;
    var response_frame = std.mem.zeroes([160]u8);
    const response_length = udp.buildFrame(&response_frame, .{
        .source_mac = peer.mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = peer.ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = peer.port,
        .destination_port = socket.local_port,
        .identification = 0x6800,
        .payload = response_payload,
    }) orelse return null;
    var packet = std.mem.zeroes(Packet);
    packet.length = response_length;
    packet.source_descriptor = 0xF100;
    @memcpy(packet.bytes[0..response_length], response_frame[0..response_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return null;
    const dispatch = dispatchPacketBatch(device, 1);
    if (dispatch.examined != 1 or dispatch.routed != 1 or dispatch.dropped != 0 or dispatch.remaining != 0) return null;
    const endpoint = &device.udp_endpoints[socket.endpoint_index];
    if (endpoint.queue.enqueued != 1 or endpoint.queue.dequeued != 0 or
        endpoint.queue.high_water != 1 or endpoint.queue.dropped != 0)
    {
        return null;
    }

    const poll = pollDnsAQuery(device, &request, 1);
    const resolved = poll.response orelse return null;
    if (poll.state != .resolved or poll.examined != 1 or poll.rejected != 0 or
        !std.mem.eql(u8, &resolved.address, &dns.fixture_address) or resolved.ttl != dns.default_ttl or
        resolved.alias_hops != 1 or endpoint.queue.dequeued != 1 or endpoint.queue.head != endpoint.queue.tail)
    {
        return null;
    }

    const endpoint_enqueued = endpoint.queue.enqueued;
    const endpoint_dequeued = endpoint.queue.dequeued;
    const endpoint_high_water = endpoint.queue.high_water;
    const endpoint_dropped = endpoint.queue.dropped;
    if (!closeUdpSocket(device, socket)) return null;
    const tx_completion_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_completion_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_completion_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const completion_overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_171 or
        device.software_rx_queue.enqueued != 61 or device.software_rx_queue.dequeued != 61 or
        device.software_rx_queue.dropped != 0 or device.software_rx_queue.head != device.software_rx_queue.tail or
        device.packets_dispatched != 50 or device.udp_packets_dispatched != 49 or
        device.unmatched_udp_packets_dropped != 3 or device.invalid_udp_packets_dropped != 3 or
        device.peer_mismatch_udp_packets_dropped != 3 or device.unknown_packets_dropped != 0 or
        tx_completion_enqueues != 38 or tx_completion_dequeues != 38 or rx_completion_enqueues != 22 or
        completion_overflow != 0 or @atomicLoad(u32, &tx_pending_mask, .acquire) != 0 or
        @atomicLoad(u32, &rx_pending_mask, .acquire) != all_rx_descriptors_pending)
    {
        return null;
    }
    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .server_ipv4 = dns_server_ipv4,
        .server_port = peer.port,
        .transaction_id = transaction_id,
        .name_length = request.name_length,
        .name_hash = tftp.updatePayloadHash(tftp.initial_fnv1a64, request.name[0..request.name_length]),
        .transmit_identification = request.transmit.identification,
        .transmit_descriptor = request.transmit.completion.descriptor_index,
        .transmit_next_cursor = request.transmit.completion.next_cursor,
        .transmit_frame_length = request.transmit.completion.frame_length,
        .poll_state = poll.state,
        .poll_examined = poll.examined,
        .poll_rejected = poll.rejected,
        .address = resolved.address,
        .ttl = resolved.ttl,
        .alias_hops = resolved.alias_hops,
        .endpoint_enqueued = endpoint_enqueued,
        .endpoint_dequeued = endpoint_dequeued,
        .endpoint_high_water = endpoint_high_water,
        .endpoint_dropped = endpoint_dropped,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = tx_completion_enqueues,
        .tx_completion_dequeues = tx_completion_dequeues,
        .rx_completion_enqueues = rx_completion_enqueues,
        .completion_overflow = completion_overflow,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyDnsAlias() ?DnsAliasReport {
    const transaction_id: u16 = dns.fixture_transaction_id + 2;
    var response_buffer = std.mem.zeroes([256]u8);
    const response = dns.buildCnameAResponse(
        &response_buffer,
        transaction_id,
        dns.fixture_alias_name,
        dns.fixture_name,
        dns.fixture_address,
        dns.default_ttl,
    ) orelse return null;
    if (response.len != 84) return null;
    const parsed = dns.parseAResponse(response, transaction_id, dns.fixture_alias_name) orelse return null;
    if (!std.mem.eql(u8, &parsed.address, &dns.fixture_address) or parsed.ttl != dns.default_ttl or
        parsed.alias_hops != 1 or !parsed.authoritative or !parsed.recursion_available)
    {
        return null;
    }

    var loop_buffer = std.mem.zeroes([256]u8);
    const loop_response = dns.buildCnameAResponse(
        &loop_buffer,
        transaction_id,
        dns.fixture_alias_name,
        dns.fixture_alias_name,
        dns.fixture_address,
        dns.default_ttl,
    ) orelse return null;
    const loop_a_type_offset = loop_response.len - 14;
    loop_buffer[loop_a_type_offset] = 0;
    loop_buffer[loop_a_type_offset + 1] = 28;
    const self_loop_rejected = dns.parseAResponse(
        loop_buffer[0..loop_response.len],
        transaction_id,
        dns.fixture_alias_name,
    ) == null;
    const truncated_rejected = dns.parseAResponse(
        response[0 .. response.len - 1],
        transaction_id,
        dns.fixture_alias_name,
    ) == null;

    var mixed_buffer = std.mem.zeroes([256]u8);
    const mixed_response = dns.buildCnameAResponse(
        &mixed_buffer,
        transaction_id,
        "Alias.ZiGoS.TeSt",
        "ZiGoS.TeSt",
        dns.fixture_address,
        dns.default_ttl,
    ) orelse return null;
    const mixed = dns.parseAResponse(
        mixed_response,
        transaction_id,
        dns.fixture_alias_name,
    ) orelse return null;
    const case_insensitive_match = mixed.alias_hops == 1 and
        std.mem.eql(u8, &mixed.address, &dns.fixture_address);
    if (!self_loop_rejected or !truncated_rejected or !case_insensitive_match) return null;

    return .{
        .transaction_id = transaction_id,
        .alias_name_length = dns.fixture_alias_name.len,
        .alias_name_hash = tftp.updatePayloadHash(tftp.initial_fnv1a64, dns.fixture_alias_name),
        .canonical_name_length = dns.fixture_name.len,
        .canonical_name_hash = tftp.updatePayloadHash(tftp.initial_fnv1a64, dns.fixture_name),
        .response_length = @intCast(response.len),
        .response_hash = tftp.updatePayloadHash(tftp.initial_fnv1a64, response),
        .address = parsed.address,
        .ttl = parsed.ttl,
        .alias_hops = parsed.alias_hops,
        .self_loop_rejected = self_loop_rejected,
        .truncated_rejected = truncated_rejected,
        .case_insensitive_match = case_insensitive_match,
    };
}

fn verifyDnsPolling(device: *Device) ?DnsPollingReport {
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (socket.endpoint_index != 2 or socket.generation != 28 or socket.local_port != 49_169 or
        device.next_ephemeral_udp_port != 49_170 or device.next_udp_generation != 29 or
        device.udp_endpoint_count != 3 or device.tx_producer != 4 or device.next_udp_identification != 9)
    {
        return null;
    }
    const dns_server_ipv4 = [4]u8{ 10, 0, 2, 3 };
    const peer = UdpPeer{
        .mac = device.gateway_mac,
        .ipv4 = dns_server_ipv4,
        .port = dns.server_port,
    };
    if (!connectUdpSocket(device, socket, peer)) return null;

    const transaction_id: u16 = dns.fixture_transaction_id + 1;
    const submissions_before = device.tx_submissions;
    const identification_before = device.next_udp_identification;
    const completion_before = completionQueueEnqueued(&tx_completion_queue);
    const invalid_request_rejected = startDnsAQuery(device, socket, transaction_id, "bad..name") == null;
    const cursor_preserved_on_rejection = invalid_request_rejected and
        device.next_udp_identification == identification_before and
        device.tx_submissions == submissions_before and device.tx_producer == 4 and
        completionQueueEnqueued(&tx_completion_queue) == completion_before;
    if (!cursor_preserved_on_rejection) return null;

    const request = startDnsAQuery(device, socket, transaction_id, dns.fixture_name) orelse return null;
    if (request.transmit.identification != 9 or request.transmit.completion.descriptor_index != 4 or
        request.transmit.completion.next_cursor != 5 or request.transmit.completion.frame_length != 70 or
        device.next_udp_identification != 10 or device.tx_producer != 5 or
        device.tx_submissions != submissions_before + 1)
    {
        return null;
    }

    var wrong_buffer = std.mem.zeroes([256]u8);
    const wrong = dns.buildAResponse(
        &wrong_buffer,
        transaction_id + 1,
        dns.fixture_name,
        dns.fixture_address,
        dns.default_ttl,
    ) orelse return null;
    var error_buffer = std.mem.zeroes([256]u8);
    const error_base = dns.buildAResponse(
        &error_buffer,
        transaction_id,
        dns.fixture_name,
        dns.fixture_address,
        dns.default_ttl,
    ) orelse return null;
    error_buffer[3] = (error_buffer[3] & 0xF0) | 2;
    const error_response = error_buffer[0..error_base.len];
    var valid_buffer = std.mem.zeroes([256]u8);
    const valid = dns.buildAResponse(
        &valid_buffer,
        transaction_id,
        dns.fixture_name,
        dns.fixture_address,
        dns.default_ttl,
    ) orelse return null;
    const payloads = .{ wrong, error_response, valid };
    inline for (payloads, 0..) |payload, packet_index| {
        var frame = std.mem.zeroes([128]u8);
        const frame_length = udp.buildFrame(&frame, .{
            .source_mac = peer.mac,
            .destination_mac = device.local_mac,
            .source_ipv4 = peer.ipv4,
            .destination_ipv4 = device.local_ipv4,
            .source_port = peer.port,
            .destination_port = socket.local_port,
            .identification = 0x6700 + packet_index,
            .payload = payload,
        }) orelse return null;
        var packet = std.mem.zeroes(Packet);
        packet.length = frame_length;
        packet.source_descriptor = 0xF200 + packet_index;
        @memcpy(packet.bytes[0..frame_length], frame[0..frame_length]);
        if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return null;
    }
    const dispatch = dispatchPacketBatch(device, 3);
    if (dispatch.examined != 3 or dispatch.routed != 3 or dispatch.dropped != 0 or dispatch.remaining != 0) return null;
    const endpoint = &device.udp_endpoints[socket.endpoint_index];
    if (endpoint.queue.enqueued != 3 or endpoint.queue.dequeued != 0 or
        endpoint.queue.high_water != 3 or endpoint.queue.dropped != 0)
    {
        return null;
    }

    const zero_budget = pollDnsAQuery(device, &request, 0);
    const zero_budget_remaining = queueDepth(&endpoint.queue);
    if (zero_budget.state != .pending or zero_budget.examined != 0 or zero_budget.rejected != 0 or
        zero_budget.response != null or zero_budget_remaining != 3)
    {
        return null;
    }
    const first_poll = pollDnsAQuery(device, &request, 2);
    const first_poll_remaining = queueDepth(&endpoint.queue);
    if (first_poll.state != .pending or first_poll.examined != 2 or first_poll.rejected != 2 or
        first_poll.response != null or first_poll_remaining != 1)
    {
        return null;
    }
    const second_poll = pollDnsAQuery(device, &request, 2);
    const response = second_poll.response orelse return null;
    if (second_poll.state != .resolved or second_poll.examined != 1 or second_poll.rejected != 0 or
        !std.mem.eql(u8, &response.address, &dns.fixture_address) or response.ttl != dns.default_ttl or
        endpoint.queue.dequeued != 3 or endpoint.queue.head != endpoint.queue.tail)
    {
        return null;
    }

    const endpoint_enqueued = endpoint.queue.enqueued;
    const endpoint_dequeued = endpoint.queue.dequeued;
    const endpoint_high_water = endpoint.queue.high_water;
    const endpoint_dropped = endpoint.queue.dropped;
    if (!closeUdpSocket(device, socket)) return null;
    const stale_poll = pollDnsAQuery(device, &request, 2);
    if (stale_poll.state != .inactive or stale_poll.examined != 0 or stale_poll.rejected != 0 or
        stale_poll.response != null)
    {
        return null;
    }
    const tx_completion_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_completion_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_completion_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const completion_overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_170 or
        device.software_rx_queue.enqueued != 60 or device.software_rx_queue.dequeued != 60 or
        device.software_rx_queue.dropped != 0 or device.software_rx_queue.head != device.software_rx_queue.tail or
        device.packets_dispatched != 49 or device.udp_packets_dispatched != 48 or
        device.unmatched_udp_packets_dropped != 3 or device.invalid_udp_packets_dropped != 3 or
        device.peer_mismatch_udp_packets_dropped != 3 or device.unknown_packets_dropped != 0 or
        tx_completion_enqueues != 37 or tx_completion_dequeues != 37 or rx_completion_enqueues != 22 or
        completion_overflow != 0 or @atomicLoad(u32, &tx_pending_mask, .acquire) != 0 or
        @atomicLoad(u32, &rx_pending_mask, .acquire) != all_rx_descriptors_pending)
    {
        return null;
    }
    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .server_ipv4 = dns_server_ipv4,
        .server_port = peer.port,
        .transaction_id = transaction_id,
        .name_length = request.name_length,
        .name_hash = tftp.updatePayloadHash(tftp.initial_fnv1a64, request.name[0..request.name_length]),
        .invalid_request_rejected = invalid_request_rejected,
        .cursor_preserved_on_rejection = cursor_preserved_on_rejection,
        .transmit_identification = request.transmit.identification,
        .transmit_descriptor = request.transmit.completion.descriptor_index,
        .transmit_next_cursor = request.transmit.completion.next_cursor,
        .transmit_frame_length = request.transmit.completion.frame_length,
        .zero_budget_state = zero_budget.state,
        .zero_budget_examined = zero_budget.examined,
        .zero_budget_rejected = zero_budget.rejected,
        .zero_budget_remaining = zero_budget_remaining,
        .first_poll_state = first_poll.state,
        .first_poll_examined = first_poll.examined,
        .first_poll_rejected = first_poll.rejected,
        .first_poll_remaining = first_poll_remaining,
        .second_poll_state = second_poll.state,
        .second_poll_examined = second_poll.examined,
        .second_poll_rejected = second_poll.rejected,
        .address = response.address,
        .ttl = response.ttl,
        .stale_poll_state = stale_poll.state,
        .endpoint_enqueued = endpoint_enqueued,
        .endpoint_dequeued = endpoint_dequeued,
        .endpoint_high_water = endpoint_high_water,
        .endpoint_dropped = endpoint_dropped,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = tx_completion_enqueues,
        .tx_completion_dequeues = tx_completion_dequeues,
        .rx_completion_enqueues = rx_completion_enqueues,
        .completion_overflow = completion_overflow,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyDnsTransaction(device: *Device) ?DnsTransactionReport {
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (socket.endpoint_index != 2 or socket.generation != 27 or socket.local_port != 49_168 or
        device.next_ephemeral_udp_port != 49_169 or device.next_udp_generation != 28 or
        device.udp_endpoint_count != 3 or device.tx_producer != 3 or device.next_udp_identification != 8)
    {
        return null;
    }
    const dns_server_ipv4 = [4]u8{ 10, 0, 2, 3 };
    const peer = UdpPeer{
        .mac = device.gateway_mac,
        .ipv4 = dns_server_ipv4,
        .port = dns.server_port,
    };
    if (!connectUdpSocket(device, socket, peer)) return null;

    const submissions_before = device.tx_submissions;
    const identification_before = device.next_udp_identification;
    const completion_before = completionQueueEnqueued(&tx_completion_queue);
    const invalid_name_rejected = sendDnsAQuery(device, socket, dns.fixture_transaction_id, "bad..name") == null;
    const cursor_preserved_on_rejection = invalid_name_rejected and
        device.next_udp_identification == identification_before and
        device.tx_submissions == submissions_before and device.tx_producer == 3 and
        completionQueueEnqueued(&tx_completion_queue) == completion_before;
    if (!cursor_preserved_on_rejection) return null;

    var query_buffer = std.mem.zeroes([512]u8);
    const query = dns.buildAQuery(&query_buffer, dns.fixture_transaction_id, dns.fixture_name) orelse return null;
    const transmit = sendDnsAQuery(device, socket, dns.fixture_transaction_id, dns.fixture_name) orelse return null;
    if (transmit.identification != 8 or transmit.completion.descriptor_index != 3 or
        transmit.completion.next_cursor != 4 or transmit.completion.frame_length != 70 or
        device.next_udp_identification != 9 or device.tx_producer != 4 or
        device.tx_submissions != submissions_before + 1)
    {
        return null;
    }

    var wrong_payload_buffer = std.mem.zeroes([256]u8);
    const wrong_payload = dns.buildAResponse(
        &wrong_payload_buffer,
        dns.fixture_transaction_id + 1,
        dns.fixture_name,
        dns.fixture_address,
        dns.default_ttl,
    ) orelse return null;
    var valid_payload_buffer = std.mem.zeroes([256]u8);
    const valid_payload = dns.buildAResponse(
        &valid_payload_buffer,
        dns.fixture_transaction_id,
        dns.fixture_name,
        dns.fixture_address,
        dns.default_ttl,
    ) orelse return null;
    const payloads = .{ wrong_payload, valid_payload };
    inline for (payloads, 0..) |payload, packet_index| {
        var frame = std.mem.zeroes([128]u8);
        const frame_length = udp.buildFrame(&frame, .{
            .source_mac = peer.mac,
            .destination_mac = device.local_mac,
            .source_ipv4 = peer.ipv4,
            .destination_ipv4 = device.local_ipv4,
            .source_port = peer.port,
            .destination_port = socket.local_port,
            .identification = 0x6600 + packet_index,
            .payload = payload,
        }) orelse return null;
        var packet = std.mem.zeroes(Packet);
        packet.length = frame_length;
        packet.source_descriptor = 0xF300 + packet_index;
        @memcpy(packet.bytes[0..frame_length], frame[0..frame_length]);
        if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return null;
    }
    const dispatch = dispatchPacketBatch(device, 2);
    if (dispatch.examined != 2 or dispatch.routed != 2 or dispatch.dropped != 0 or dispatch.remaining != 0) return null;
    const endpoint = &device.udp_endpoints[socket.endpoint_index];
    if (endpoint.queue.enqueued != 2 or endpoint.queue.dequeued != 0 or
        endpoint.queue.high_water != 2 or endpoint.queue.dropped != 0)
    {
        return null;
    }
    const wrong_transaction_rejected = receiveDnsAResponse(
        device,
        socket,
        dns.fixture_transaction_id,
        dns.fixture_name,
    ) == null;
    if (!wrong_transaction_rejected) return null;
    const response = receiveDnsAResponse(
        device,
        socket,
        dns.fixture_transaction_id,
        dns.fixture_name,
    ) orelse return null;
    if (!std.mem.eql(u8, &response.address, &dns.fixture_address) or response.ttl != dns.default_ttl or
        !response.authoritative or !response.recursion_available or
        endpoint.queue.dequeued != 2 or endpoint.queue.head != endpoint.queue.tail)
    {
        return null;
    }

    const endpoint_enqueued = endpoint.queue.enqueued;
    const endpoint_dequeued = endpoint.queue.dequeued;
    const endpoint_high_water = endpoint.queue.high_water;
    const endpoint_dropped = endpoint.queue.dropped;
    const tx_completion_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_completion_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_completion_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const completion_overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (!closeUdpSocket(device, socket)) return null;
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_169 or
        device.software_rx_queue.enqueued != 57 or device.software_rx_queue.dequeued != 57 or
        device.software_rx_queue.dropped != 0 or device.software_rx_queue.head != device.software_rx_queue.tail or
        device.packets_dispatched != 46 or device.udp_packets_dispatched != 45 or
        device.unmatched_udp_packets_dropped != 3 or device.invalid_udp_packets_dropped != 3 or
        device.peer_mismatch_udp_packets_dropped != 3 or device.unknown_packets_dropped != 0 or
        tx_completion_enqueues != 36 or tx_completion_dequeues != 36 or rx_completion_enqueues != 22 or
        completion_overflow != 0 or @atomicLoad(u32, &tx_pending_mask, .acquire) != 0 or
        @atomicLoad(u32, &rx_pending_mask, .acquire) != all_rx_descriptors_pending)
    {
        return null;
    }
    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .server_ipv4 = dns_server_ipv4,
        .server_port = peer.port,
        .transaction_id = dns.fixture_transaction_id,
        .invalid_name_rejected = invalid_name_rejected,
        .cursor_preserved_on_rejection = cursor_preserved_on_rejection,
        .query_payload_length = @intCast(query.len),
        .query_payload_hash = tftp.updatePayloadHash(tftp.initial_fnv1a64, query),
        .transmit_identification = transmit.identification,
        .transmit_descriptor = transmit.completion.descriptor_index,
        .transmit_next_cursor = transmit.completion.next_cursor,
        .transmit_frame_length = transmit.completion.frame_length,
        .wrong_transaction_rejected = wrong_transaction_rejected,
        .address = response.address,
        .ttl = response.ttl,
        .authoritative = response.authoritative,
        .recursion_available = response.recursion_available,
        .endpoint_enqueued = endpoint_enqueued,
        .endpoint_dequeued = endpoint_dequeued,
        .endpoint_high_water = endpoint_high_water,
        .endpoint_dropped = endpoint_dropped,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = tx_completion_enqueues,
        .tx_completion_dequeues = tx_completion_dequeues,
        .rx_completion_enqueues = rx_completion_enqueues,
        .completion_overflow = completion_overflow,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyDnsCodec() ?DnsCodecReport {
    var query_buffer = std.mem.zeroes([256]u8);
    const query = dns.buildAQuery(&query_buffer, dns.fixture_transaction_id, dns.fixture_name) orelse return null;
    if (query.len != 28) return null;
    var response_buffer = std.mem.zeroes([256]u8);
    const response = dns.buildAResponse(
        &response_buffer,
        dns.fixture_transaction_id,
        dns.fixture_name,
        dns.fixture_address,
        dns.default_ttl,
    ) orelse return null;
    if (response.len != 44) return null;
    const parsed = dns.parseAResponse(response, dns.fixture_transaction_id, dns.fixture_name) orelse return null;
    if (!std.mem.eql(u8, &parsed.address, &dns.fixture_address) or parsed.ttl != dns.default_ttl or
        !parsed.authoritative or !parsed.recursion_available or parsed.alias_hops != 0)
    {
        return null;
    }

    var invalid_buffer = std.mem.zeroes([256]u8);
    const long_label = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.test";
    const invalid_names_rejected = dns.buildAQuery(&invalid_buffer, 1, "") == null and
        dns.buildAQuery(&invalid_buffer, 1, ".zigos") == null and
        dns.buildAQuery(&invalid_buffer, 1, "zigos.") == null and
        dns.buildAQuery(&invalid_buffer, 1, "bad..name") == null and
        dns.buildAQuery(&invalid_buffer, 1, "-bad.test") == null and
        dns.buildAQuery(&invalid_buffer, 1, "bad-.test") == null and
        dns.buildAQuery(&invalid_buffer, 1, long_label) == null;
    var small_buffer = std.mem.zeroes([27]u8);
    const small_buffer_rejected = dns.buildAQuery(&small_buffer, dns.fixture_transaction_id, dns.fixture_name) == null;

    var wrong_transaction = response_buffer;
    wrong_transaction[1] ^= 1;
    const wrong_transaction_rejected = dns.parseAResponse(
        wrong_transaction[0..response.len],
        dns.fixture_transaction_id,
        dns.fixture_name,
    ) == null;
    const truncated_rejected = dns.parseAResponse(
        response[0 .. response.len - 1],
        dns.fixture_transaction_id,
        dns.fixture_name,
    ) == null;
    var compression_loop = response_buffer;
    compression_loop[12] = 0xC0;
    compression_loop[13] = 0x0C;
    const compression_loop_rejected = dns.parseAResponse(
        compression_loop[0..response.len],
        dns.fixture_transaction_id,
        dns.fixture_name,
    ) == null;
    var error_response = response_buffer;
    error_response[3] = (error_response[3] & 0xF0) | 3;
    const error_response_rejected = dns.parseAResponse(
        error_response[0..response.len],
        dns.fixture_transaction_id,
        dns.fixture_name,
    ) == null;
    var wrong_type = response_buffer;
    wrong_type[query.len + 2] = 0;
    wrong_type[query.len + 3] = 5;
    const wrong_type_rejected = dns.parseAResponse(
        wrong_type[0..response.len],
        dns.fixture_transaction_id,
        dns.fixture_name,
    ) == null;

    var mixed_case_buffer = std.mem.zeroes([256]u8);
    const mixed_case = dns.buildAResponse(
        &mixed_case_buffer,
        dns.fixture_transaction_id,
        "ZiGoS.TeSt",
        dns.fixture_address,
        dns.default_ttl,
    ) orelse return null;
    const case_insensitive = dns.parseAResponse(
        mixed_case,
        dns.fixture_transaction_id,
        dns.fixture_name,
    ) orelse return null;
    const case_insensitive_match = std.mem.eql(u8, &case_insensitive.address, &dns.fixture_address);
    if (!invalid_names_rejected or !small_buffer_rejected or !wrong_transaction_rejected or
        !truncated_rejected or !compression_loop_rejected or !error_response_rejected or
        !wrong_type_rejected or !case_insensitive_match)
    {
        return null;
    }
    return .{
        .transaction_id = dns.fixture_transaction_id,
        .query_length = @intCast(query.len),
        .query_hash = tftp.updatePayloadHash(tftp.initial_fnv1a64, query),
        .response_length = @intCast(response.len),
        .response_hash = tftp.updatePayloadHash(tftp.initial_fnv1a64, response),
        .address = parsed.address,
        .ttl = parsed.ttl,
        .authoritative = parsed.authoritative,
        .recursion_available = parsed.recursion_available,
        .invalid_names_rejected = invalid_names_rejected,
        .small_buffer_rejected = small_buffer_rejected,
        .wrong_transaction_rejected = wrong_transaction_rejected,
        .truncated_rejected = truncated_rejected,
        .compression_loop_rejected = compression_loop_rejected,
        .error_response_rejected = error_response_rejected,
        .wrong_type_rejected = wrong_type_rejected,
        .case_insensitive_match = case_insensitive_match,
    };
}

fn verifyUdpSendToReply(device: *Device) ?UdpSendToReplyReport {
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (socket.endpoint_index != 2 or socket.generation != 26 or socket.local_port != 49_167 or
        device.next_ephemeral_udp_port != 49_168 or device.next_udp_generation != 27 or
        device.udp_endpoint_count != 3 or device.tx_producer != 1 or device.next_udp_identification != 6)
    {
        return null;
    }

    const request_payload = [_]u8{ 'P', 'I', 'N', 'G' };
    var request_frame = std.mem.zeroes([ethernet_minimum_frame_bytes]u8);
    const request_length = udp.buildFrame(&request_frame, .{
        .source_mac = device.gateway_mac,
        .destination_mac = device.local_mac,
        .source_ipv4 = device.gateway_ipv4,
        .destination_ipv4 = device.local_ipv4,
        .source_port = 34_567,
        .destination_port = socket.local_port,
        .identification = 0x6500,
        .payload = &request_payload,
    }) orelse return null;
    var request_packet = std.mem.zeroes(Packet);
    request_packet.length = request_length;
    request_packet.source_descriptor = 0xF400;
    @memcpy(request_packet.bytes[0..request_length], request_frame[0..request_length]);
    if (!enqueueQueuedPacket(&device.software_rx_queue, request_packet)) return null;
    const dispatch = dispatchPacketBatch(device, 1);
    if (dispatch.examined != 1 or dispatch.routed != 1 or dispatch.dropped != 0 or dispatch.remaining != 0) return null;
    const request = receiveUdpDatagram(device, socket) orelse return null;
    if (request.source_port != 34_567 or request.destination_port != socket.local_port or
        !std.mem.eql(u8, request.payload(), &request_payload))
    {
        return null;
    }

    const submissions_before = device.tx_submissions;
    const completion_before = completionQueueEnqueued(&tx_completion_queue);
    const identification_before = device.next_udp_identification;
    const invalid_peer_rejected = sendUdpDatagramTo(device, socket, .{
        .mac = device.gateway_mac,
        .ipv4 = device.gateway_ipv4,
        .port = 0,
    }, 64, "bad") == null;
    const zero_ttl_rejected = sendUdpDatagramTo(device, socket, .{
        .mac = device.gateway_mac,
        .ipv4 = device.gateway_ipv4,
        .port = 9,
    }, 0, "bad") == null;
    const cursor_preserved_on_rejection = invalid_peer_rejected and zero_ttl_rejected and
        device.next_udp_identification == identification_before and
        device.tx_submissions == submissions_before and device.tx_producer == 1 and
        completionQueueEnqueued(&tx_completion_queue) == completion_before;
    if (!cursor_preserved_on_rejection) return null;

    const reply = sendUdpReply(device, socket, &request, 64, "PONG") orelse return null;
    const send_to = sendUdpDatagramTo(device, socket, .{
        .mac = device.gateway_mac,
        .ipv4 = device.gateway_ipv4,
        .port = 9,
    }, 64, "SEND") orelse return null;
    if (reply.identification != 6 or reply.completion.descriptor_index != 1 or
        reply.completion.next_cursor != 2 or reply.completion.frame_length != 60 or
        send_to.identification != 7 or send_to.completion.descriptor_index != 2 or
        send_to.completion.next_cursor != 3 or send_to.completion.frame_length != 60 or
        device.next_udp_identification != 8 or device.tx_producer != 3 or
        device.tx_submissions != submissions_before + 2)
    {
        return null;
    }

    const tx_completion_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const tx_completion_dequeues = completionQueueDequeued(&tx_completion_queue);
    const rx_completion_enqueues = completionQueueEnqueued(&rx_completion_queue);
    const completion_overflow = completionQueueOverflow(&tx_completion_queue) + completionQueueOverflow(&rx_completion_queue);
    if (tx_completion_enqueues != 35 or tx_completion_dequeues != 35 or rx_completion_enqueues != 22 or
        completion_overflow != 0 or @atomicLoad(u32, &tx_pending_mask, .acquire) != 0 or
        @atomicLoad(u32, &rx_pending_mask, .acquire) != all_rx_descriptors_pending or
        tx_ready_mask != 0 or rx_ready_mask != 0)
    {
        return null;
    }
    if (!closeUdpSocket(device, socket)) return null;
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_168 or
        device.software_rx_queue.enqueued != 55 or device.software_rx_queue.dequeued != 55 or
        device.software_rx_queue.dropped != 0 or device.software_rx_queue.head != device.software_rx_queue.tail or
        device.packets_dispatched != 44 or device.udp_packets_dispatched != 43 or
        device.unmatched_udp_packets_dropped != 3 or device.invalid_udp_packets_dropped != 3 or
        device.peer_mismatch_udp_packets_dropped != 3 or device.unknown_packets_dropped != 0)
    {
        return null;
    }
    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .request_source_port = request.source_port,
        .request_payload_length = @intCast(request.payload().len),
        .request_payload_hash = tftp.updatePayloadHash(tftp.initial_fnv1a64, request.payload()),
        .invalid_peer_rejected = invalid_peer_rejected,
        .zero_ttl_rejected = zero_ttl_rejected,
        .cursor_preserved_on_rejection = cursor_preserved_on_rejection,
        .reply_identification = reply.identification,
        .reply_descriptor = reply.completion.descriptor_index,
        .reply_next_cursor = reply.completion.next_cursor,
        .reply_frame_length = reply.completion.frame_length,
        .send_to_identification = send_to.identification,
        .send_to_descriptor = send_to.completion.descriptor_index,
        .send_to_next_cursor = send_to.completion.next_cursor,
        .send_to_frame_length = send_to.completion.frame_length,
        .final_identification_cursor = device.next_udp_identification,
        .final_tx_cursor = device.tx_producer,
        .tx_submissions_delta = device.tx_submissions - submissions_before,
        .tx_completion_enqueues = tx_completion_enqueues,
        .tx_completion_dequeues = tx_completion_dequeues,
        .rx_completion_enqueues = rx_completion_enqueues,
        .completion_overflow = completion_overflow,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
    };
}

fn verifyUdpDiscardClose(device: *Device) ?UdpDiscardCloseReport {
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (socket.endpoint_index != 2 or socket.generation != 25 or socket.local_port != 49_166 or
        device.next_ephemeral_udp_port != 49_167 or device.next_udp_generation != 26 or
        device.udp_endpoint_count != 3 or device.tx_producer != 1 or device.next_udp_identification != 6)
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
        const payload = [_]u8{ 0x43, @intCast(packet_index) };
        const frame_length = udp.buildFrame(&frame, .{
            .source_mac = peer.mac,
            .destination_mac = device.local_mac,
            .source_ipv4 = peer.ipv4,
            .destination_ipv4 = device.local_ipv4,
            .source_port = peer.port,
            .destination_port = socket.local_port,
            .identification = 0x6400 + packet_index,
            .payload = &payload,
        }) orelse return null;
        var packet = std.mem.zeroes(Packet);
        packet.length = frame_length;
        packet.source_descriptor = 0xF500 + packet_index;
        @memcpy(packet.bytes[0..frame_length], frame[0..frame_length]);
        if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return null;
    }
    const dispatch = dispatchPacketBatch(device, 3);
    if (dispatch.examined != 3 or dispatch.routed != 3 or dispatch.dropped != 0 or dispatch.remaining != 0) return null;
    const status = inspectUdpSocket(device, socket) orelse return null;
    if (status.pending_packets != 3 or status.enqueued != 3 or status.dequeued != 0 or
        status.high_water != 3 or status.dropped != 0 or !status.connected or status.peer_port != peer.port)
    {
        return null;
    }
    const normal_close_rejected = !closeUdpSocket(device, socket);
    if (!normal_close_rejected or !udpSocketActive(device, socket)) return null;
    const closed = closeUdpSocketDiscarding(device, socket) orelse return null;
    if (closed.local_port != socket.local_port or closed.generation != socket.generation or
        !closed.was_connected or closed.peer_port != peer.port or closed.discarded_packets != 3 or
        closed.queue_enqueued != 3 or closed.queue_dequeued != 3 or
        closed.queue_high_water != 3 or closed.queue_dropped != 0)
    {
        return null;
    }
    const stale_close_rejected = !closeUdpSocket(device, socket);
    const stale_force_close_rejected = closeUdpSocketDiscarding(device, socket) == null;
    const stale_receive_rejected = receiveUdpDatagram(device, socket) == null;
    if (!stale_close_rejected or !stale_force_close_rejected or !stale_receive_rejected) return null;
    const tx_completion_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const rx_completion_enqueues = completionQueueEnqueued(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_167 or
        device.software_rx_queue.enqueued != 54 or device.software_rx_queue.dequeued != 54 or
        device.software_rx_queue.dropped != 0 or device.software_rx_queue.head != device.software_rx_queue.tail or
        device.packets_dispatched != 43 or device.udp_packets_dispatched != 42 or
        device.unmatched_udp_packets_dropped != 3 or device.invalid_udp_packets_dropped != 3 or
        device.peer_mismatch_udp_packets_dropped != 3 or device.unknown_packets_dropped != 0 or
        tx_completion_enqueues != 33 or rx_completion_enqueues != 22 or
        @atomicLoad(u32, &tx_pending_mask, .acquire) != 0 or
        @atomicLoad(u32, &rx_pending_mask, .acquire) != all_rx_descriptors_pending)
    {
        return null;
    }
    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .peer_port = peer.port,
        .normal_close_rejected = normal_close_rejected,
        .discarded_packets = closed.discarded_packets,
        .was_connected = closed.was_connected,
        .queue_enqueued = closed.queue_enqueued,
        .queue_dequeued = closed.queue_dequeued,
        .queue_high_water = closed.queue_high_water,
        .queue_dropped = closed.queue_dropped,
        .stale_close_rejected = stale_close_rejected,
        .stale_force_close_rejected = stale_force_close_rejected,
        .stale_receive_rejected = stale_receive_rejected,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
        .tx_completion_enqueues = tx_completion_enqueues,
        .rx_completion_enqueues = rx_completion_enqueues,
    };
}

fn verifyUdpPeekExact(device: *Device) ?UdpPeekExactReport {
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (socket.endpoint_index != 2 or socket.generation != 24 or socket.local_port != 49_165 or
        device.next_ephemeral_udp_port != 49_166 or device.next_udp_generation != 25 or
        device.udp_endpoint_count != 3 or device.tx_producer != 1 or
        device.next_udp_identification != 6)
    {
        return null;
    }

    const first_payload = [_]u8{ 0x10, 0x11, 0x12, 0x13, 0x14, 0x15 };
    const second_payload = [_]u8{ 0x20, 0x21 };
    const payloads = .{ first_payload, second_payload };
    inline for (payloads, 0..) |payload, packet_index| {
        var frame = std.mem.zeroes([ethernet_minimum_frame_bytes]u8);
        const frame_length = udp.buildFrame(&frame, .{
            .source_mac = device.gateway_mac,
            .destination_mac = device.local_mac,
            .source_ipv4 = device.gateway_ipv4,
            .destination_ipv4 = device.local_ipv4,
            .source_port = peer_filter_source_port,
            .destination_port = socket.local_port,
            .identification = 0x6300 + packet_index,
            .payload = &payload,
        }) orelse return null;
        var packet = std.mem.zeroes(Packet);
        packet.length = frame_length;
        packet.source_descriptor = 0xF600 + packet_index;
        @memcpy(packet.bytes[0..frame_length], frame[0..frame_length]);
        if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return null;
    }
    const dispatch = dispatchPacketBatch(device, 2);
    if (dispatch.examined != 2 or dispatch.routed != 2 or dispatch.dropped != 0 or dispatch.remaining != 0) return null;
    const endpoint = &device.udp_endpoints[socket.endpoint_index];
    if (endpoint.queue.enqueued != 2 or endpoint.queue.dequeued != 0 or
        endpoint.queue.high_water != 2 or endpoint.queue.dropped != 0)
    {
        return null;
    }

    const first_preview = peekUdpDatagram(device, socket) orelse return null;
    const repeated_preview = peekUdpDatagram(device, socket) orelse return null;
    const repeated_preview_stable = std.meta.eql(first_preview, repeated_preview) and
        first_preview.payload_length == first_payload.len and first_preview.identification == 0x6300 and
        first_preview.source_port == peer_filter_source_port and first_preview.destination_port == socket.local_port;
    if (!repeated_preview_stable) return null;
    const before_rejection = inspectUdpSocket(device, socket) orelse return null;
    var insufficient_buffer = std.mem.zeroes([4]u8);
    const insufficient_rejected = receiveUdpExact(device, socket, &insufficient_buffer) == null;
    const after_rejection = inspectUdpSocket(device, socket) orelse return null;
    const queue_preserved_on_rejection = insufficient_rejected and
        before_rejection.pending_packets == 2 and after_rejection.pending_packets == 2 and
        before_rejection.dequeued == 0 and after_rejection.dequeued == 0 and
        std.mem.allEqual(u8, &insufficient_buffer, 0);
    if (!queue_preserved_on_rejection) return null;

    var first_buffer = std.mem.zeroes([first_payload.len]u8);
    const first_exact = receiveUdpExact(device, socket, &first_buffer) orelse return null;
    if (first_exact.payload_length != first_payload.len or first_exact.copied_length != first_payload.len or
        first_exact.truncated or !std.mem.eql(u8, &first_buffer, &first_payload))
    {
        return null;
    }
    const second_preview = peekUdpDatagram(device, socket) orelse return null;
    if (second_preview.payload_length != second_payload.len or second_preview.identification != 0x6301) return null;
    var second_buffer = std.mem.zeroes([second_payload.len]u8);
    const second_exact = receiveUdpExact(device, socket, &second_buffer) orelse return null;
    if (second_exact.payload_length != second_payload.len or second_exact.copied_length != second_payload.len or
        second_exact.truncated or !std.mem.eql(u8, &second_buffer, &second_payload))
    {
        return null;
    }
    const final_preview_empty = peekUdpDatagram(device, socket) == null and
        receiveUdpExact(device, socket, &second_buffer) == null and !udpSocketReadable(device, socket);
    if (!final_preview_empty) return null;

    const endpoint_enqueued = endpoint.queue.enqueued;
    const endpoint_dequeued = endpoint.queue.dequeued;
    const endpoint_high_water = endpoint.queue.high_water;
    const endpoint_dropped = endpoint.queue.dropped;
    if (endpoint_dequeued != 2 or endpoint.queue.head != endpoint.queue.tail) return null;
    if (!closeUdpSocket(device, socket)) return null;
    const tx_completion_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const rx_completion_enqueues = completionQueueEnqueued(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_166 or
        device.software_rx_queue.enqueued != 51 or device.software_rx_queue.dequeued != 51 or
        device.software_rx_queue.dropped != 0 or device.software_rx_queue.head != device.software_rx_queue.tail or
        device.packets_dispatched != 40 or device.udp_packets_dispatched != 39 or
        device.unmatched_udp_packets_dropped != 3 or device.invalid_udp_packets_dropped != 3 or
        device.peer_mismatch_udp_packets_dropped != 3 or device.unknown_packets_dropped != 0 or
        tx_completion_enqueues != 33 or rx_completion_enqueues != 22 or
        @atomicLoad(u32, &tx_pending_mask, .acquire) != 0 or
        @atomicLoad(u32, &rx_pending_mask, .acquire) != all_rx_descriptors_pending)
    {
        return null;
    }

    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .first_payload_length = first_preview.payload_length,
        .first_identification = first_preview.identification,
        .repeated_preview_stable = repeated_preview_stable,
        .insufficient_rejected = insufficient_rejected,
        .queue_preserved_on_rejection = queue_preserved_on_rejection,
        .first_exact_copied = first_exact.copied_length,
        .first_exact_hash = tftp.updatePayloadHash(tftp.initial_fnv1a64, &first_buffer),
        .second_payload_length = second_preview.payload_length,
        .second_identification = second_preview.identification,
        .second_exact_copied = second_exact.copied_length,
        .second_exact_hash = tftp.updatePayloadHash(tftp.initial_fnv1a64, &second_buffer),
        .final_preview_empty = final_preview_empty,
        .endpoint_enqueued = endpoint_enqueued,
        .endpoint_dequeued = endpoint_dequeued,
        .endpoint_high_water = endpoint_high_water,
        .endpoint_dropped = endpoint_dropped,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
        .tx_completion_enqueues = tx_completion_enqueues,
        .rx_completion_enqueues = rx_completion_enqueues,
    };
}

fn verifyUdpReceiveInto(device: *Device) ?UdpReceiveIntoReport {
    const socket = openEphemeralUdpSocket(device) orelse return null;
    if (socket.endpoint_index != 2 or socket.generation != 23 or socket.local_port != 49_164 or
        device.next_ephemeral_udp_port != 49_165 or device.next_udp_generation != 24 or
        device.udp_endpoint_count != 3 or device.tx_producer != 1 or
        device.next_udp_identification != 6)
    {
        return null;
    }

    const payloads = .{
        [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 },
        [_]u8{ 0xA0, 0xA1, 0xA2, 0xA3 },
        [_]u8{},
    };
    inline for (payloads, 0..) |payload, packet_index| {
        var frame = std.mem.zeroes([ethernet_minimum_frame_bytes]u8);
        const frame_length = udp.buildFrame(&frame, .{
            .source_mac = device.gateway_mac,
            .destination_mac = device.local_mac,
            .source_ipv4 = device.gateway_ipv4,
            .destination_ipv4 = device.local_ipv4,
            .source_port = peer_filter_source_port,
            .destination_port = socket.local_port,
            .identification = 0x6200 + packet_index,
            .payload = &payload,
        }) orelse return null;
        var packet = std.mem.zeroes(Packet);
        packet.length = frame_length;
        packet.source_descriptor = 0xF700 + packet_index;
        @memcpy(packet.bytes[0..frame_length], frame[0..frame_length]);
        if (!enqueueQueuedPacket(&device.software_rx_queue, packet)) return null;
    }
    const dispatch = dispatchPacketBatch(device, 3);
    if (dispatch.examined != 3 or dispatch.routed != 3 or dispatch.dropped != 0 or dispatch.remaining != 0) return null;
    const endpoint = &device.udp_endpoints[socket.endpoint_index];
    if (endpoint.queue.enqueued != 3 or endpoint.queue.dequeued != 0 or
        endpoint.queue.high_water != 3 or endpoint.queue.dropped != 0)
    {
        return null;
    }

    var first_buffer = std.mem.zeroes([5]u8);
    const first = receiveUdpInto(device, socket, &first_buffer) orelse return null;
    if (first.payload_length != 8 or first.copied_length != 5 or !first.truncated or
        first.source_port != peer_filter_source_port or first.destination_port != socket.local_port or
        !std.mem.eql(u8, &first_buffer, &[_]u8{ 0, 1, 2, 3, 4 }))
    {
        return null;
    }
    var second_buffer = std.mem.zeroes([8]u8);
    const second = receiveUdpInto(device, socket, &second_buffer) orelse return null;
    if (second.payload_length != 4 or second.copied_length != 4 or second.truncated or
        !std.mem.eql(u8, second_buffer[0..4], &[_]u8{ 0xA0, 0xA1, 0xA2, 0xA3 }) or
        !std.mem.allEqual(u8, second_buffer[4..], 0))
    {
        return null;
    }
    const empty_buffer = [_]u8{};
    const empty = receiveUdpInto(device, socket, &empty_buffer) orelse return null;
    if (empty.payload_length != 0 or empty.copied_length != 0 or empty.truncated) return null;
    if (receiveUdpInto(device, socket, &second_buffer) != null or udpSocketReadable(device, socket)) return null;

    const endpoint_enqueued = endpoint.queue.enqueued;
    const endpoint_dequeued = endpoint.queue.dequeued;
    const endpoint_high_water = endpoint.queue.high_water;
    const endpoint_dropped = endpoint.queue.dropped;
    if (endpoint_dequeued != 3 or endpoint.queue.head != endpoint.queue.tail) return null;
    if (!closeUdpSocket(device, socket)) return null;
    const tx_completion_enqueues = completionQueueEnqueued(&tx_completion_queue);
    const rx_completion_enqueues = completionQueueEnqueued(&rx_completion_queue);
    if (device.udp_endpoint_count != 2 or device.next_ephemeral_udp_port != 49_165 or
        device.software_rx_queue.enqueued != 49 or device.software_rx_queue.dequeued != 49 or
        device.software_rx_queue.dropped != 0 or device.software_rx_queue.head != device.software_rx_queue.tail or
        device.packets_dispatched != 38 or device.udp_packets_dispatched != 37 or
        device.unmatched_udp_packets_dropped != 3 or device.invalid_udp_packets_dropped != 3 or
        device.peer_mismatch_udp_packets_dropped != 3 or device.unknown_packets_dropped != 0 or
        tx_completion_enqueues != 33 or rx_completion_enqueues != 22 or
        @atomicLoad(u32, &tx_pending_mask, .acquire) != 0 or
        @atomicLoad(u32, &rx_pending_mask, .acquire) != all_rx_descriptors_pending)
    {
        return null;
    }

    return .{
        .socket_slot = socket.endpoint_index,
        .socket_generation = socket.generation,
        .local_port = socket.local_port,
        .first_payload_length = first.payload_length,
        .first_copied_length = first.copied_length,
        .first_truncated = first.truncated,
        .first_copy_hash = tftp.updatePayloadHash(tftp.initial_fnv1a64, &first_buffer),
        .second_payload_length = second.payload_length,
        .second_copied_length = second.copied_length,
        .second_truncated = second.truncated,
        .second_copy_hash = tftp.updatePayloadHash(tftp.initial_fnv1a64, second_buffer[0..second.copied_length]),
        .empty_payload_length = empty.payload_length,
        .empty_copied_length = empty.copied_length,
        .empty_truncated = empty.truncated,
        .source_port = first.source_port,
        .endpoint_enqueued = endpoint_enqueued,
        .endpoint_dequeued = endpoint_dequeued,
        .endpoint_high_water = endpoint_high_water,
        .endpoint_dropped = endpoint_dropped,
        .final_registered_endpoints = device.udp_endpoint_count,
        .final_ephemeral_cursor = device.next_ephemeral_udp_port,
        .ingress_enqueued = device.software_rx_queue.enqueued,
        .ingress_dequeued = device.software_rx_queue.dequeued,
        .packets_dispatched = device.packets_dispatched,
        .udp_dispatched = device.udp_packets_dispatched,
        .tx_completion_enqueues = tx_completion_enqueues,
        .rx_completion_enqueues = rx_completion_enqueues,
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
