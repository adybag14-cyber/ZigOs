const std = @import("std");

const ethernet_header_bytes: usize = 14;
const ipv4_header_bytes: usize = 20;
const udp_header_bytes: usize = 8;
const dhcp_fixed_bytes: usize = 240;
const dhcp_payload_bytes: usize = 300;
const ethernet_frame_bytes: usize = ethernet_header_bytes + ipv4_header_bytes + udp_header_bytes + dhcp_payload_bytes;

const ether_type_ipv4: u16 = 0x0800;
const ipv4_protocol_udp: u8 = 17;
const ipv4_dont_fragment: u16 = 1 << 14;
const bootp_request: u8 = 1;
const bootp_reply: u8 = 2;
const hardware_ethernet: u8 = 1;
const ethernet_address_bytes: u8 = 6;
const bootp_broadcast: u16 = 1 << 15;
const dhcp_client_port: u16 = 68;
const dhcp_server_port: u16 = 67;
const dhcp_magic_cookie: u32 = 0x6382_5363;

const option_subnet_mask: u8 = 1;
const option_router: u8 = 3;
const option_dns_server: u8 = 6;
const option_requested_ip: u8 = 50;
const option_lease_time: u8 = 51;
const option_message_type: u8 = 53;
const option_server_identifier: u8 = 54;
const option_parameter_request_list: u8 = 55;
const option_maximum_message_size: u8 = 57;
const option_client_identifier: u8 = 61;
const option_end: u8 = 255;
const message_discover: u8 = 1;
const message_offer: u8 = 2;
const message_request: u8 = 3;
const message_ack: u8 = 5;

pub const transaction_id: u32 = 0x5A49_474F;
pub const expected_frame_bytes: usize = ethernet_frame_bytes;

const zero_ipv4 = [4]u8{ 0, 0, 0, 0 };
const broadcast_ipv4 = [4]u8{ 255, 255, 255, 255 };
const broadcast_mac = [6]u8{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
const requested_parameters = [_]u8{
    option_subnet_mask,
    option_router,
    option_dns_server,
    option_lease_time,
    option_server_identifier,
};

pub const Lease = struct {
    address: [4]u8,
    subnet_mask: [4]u8,
    router: [4]u8,
    dns_server: [4]u8,
    router_advertised: bool,
    dns_server_advertised: bool,
    server_identifier: [4]u8,
    server_mac: [6]u8,
    lease_seconds: u32,
    reply_ttl: u8,
    udp_checksum_present: bool,
};

pub const Response = struct {
    lease: Lease,
    frame_length: u16,
};

pub fn buildDiscover(frame: []u8, client_mac: [6]u8) ?u16 {
    return buildClientMessage(frame, client_mac, message_discover, null, null);
}

pub fn buildRequest(frame: []u8, client_mac: [6]u8, offer: Lease) ?u16 {
    return buildClientMessage(
        frame,
        client_mac,
        message_request,
        offer.address,
        offer.server_identifier,
    );
}

pub fn parseOffer(frame: []const u8, client_mac: [6]u8) ?Response {
    return parseResponse(frame, client_mac, message_offer, null, null);
}

pub fn parseAck(frame: []const u8, client_mac: [6]u8, offer: Lease) ?Response {
    return parseResponse(
        frame,
        client_mac,
        message_ack,
        offer.address,
        offer.server_identifier,
    );
}

fn buildClientMessage(
    frame: []u8,
    client_mac: [6]u8,
    message_type: u8,
    requested_ip: ?[4]u8,
    server_identifier: ?[4]u8,
) ?u16 {
    if (frame.len < ethernet_frame_bytes) return null;
    @memset(frame[0..ethernet_frame_bytes], 0);
    @memcpy(frame[0..6], &broadcast_mac);
    @memcpy(frame[6..12], &client_mac);
    writeNetwork16(frame, 12, ether_type_ipv4);

    const ip_offset = ethernet_header_bytes;
    frame[ip_offset] = 0x45;
    writeNetwork16(frame, ip_offset + 2, ipv4_header_bytes + udp_header_bytes + dhcp_payload_bytes);
    writeNetwork16(frame, ip_offset + 4, @as(u16, @truncate(transaction_id)));
    writeNetwork16(frame, ip_offset + 6, ipv4_dont_fragment);
    frame[ip_offset + 8] = 64;
    frame[ip_offset + 9] = ipv4_protocol_udp;
    @memcpy(frame[ip_offset + 12 .. ip_offset + 16], &zero_ipv4);
    @memcpy(frame[ip_offset + 16 .. ip_offset + 20], &broadcast_ipv4);
    writeNetwork16(frame, ip_offset + 10, internetChecksum(frame[ip_offset .. ip_offset + ipv4_header_bytes]));

    const udp_offset = ip_offset + ipv4_header_bytes;
    writeNetwork16(frame, udp_offset, dhcp_client_port);
    writeNetwork16(frame, udp_offset + 2, dhcp_server_port);
    writeNetwork16(frame, udp_offset + 4, udp_header_bytes + dhcp_payload_bytes);
    writeNetwork16(frame, udp_offset + 6, 0);

    const dhcp_offset = udp_offset + udp_header_bytes;
    frame[dhcp_offset] = bootp_request;
    frame[dhcp_offset + 1] = hardware_ethernet;
    frame[dhcp_offset + 2] = ethernet_address_bytes;
    writeNetwork32(frame, dhcp_offset + 4, transaction_id);
    writeNetwork16(frame, dhcp_offset + 10, bootp_broadcast);
    @memcpy(frame[dhcp_offset + 28 .. dhcp_offset + 34], &client_mac);
    writeNetwork32(frame, dhcp_offset + 236, dhcp_magic_cookie);

    var option_index = dhcp_offset + dhcp_fixed_bytes;
    option_index = appendOptionByte(frame, option_index, option_message_type, message_type) orelse return null;
    if (requested_ip) |address| {
        option_index = appendOption(frame, option_index, option_requested_ip, &address) orelse return null;
    }
    if (server_identifier) |address| {
        option_index = appendOption(frame, option_index, option_server_identifier, &address) orelse return null;
    }
    const client_identifier = [_]u8{
        hardware_ethernet,
        client_mac[0],
        client_mac[1],
        client_mac[2],
        client_mac[3],
        client_mac[4],
        client_mac[5],
    };
    option_index = appendOption(frame, option_index, option_client_identifier, &client_identifier) orelse return null;
    option_index = appendOption(frame, option_index, option_parameter_request_list, &requested_parameters) orelse return null;
    const maximum_message_size = [_]u8{ 0x02, 0x40 };
    option_index = appendOption(frame, option_index, option_maximum_message_size, &maximum_message_size) orelse return null;
    if (option_index >= dhcp_offset + dhcp_payload_bytes) return null;
    frame[option_index] = option_end;

    const udp_packet = frame[udp_offset .. udp_offset + udp_header_bytes + dhcp_payload_bytes];
    var checksum = udpChecksum(zero_ipv4, broadcast_ipv4, udp_packet);
    if (checksum == 0) checksum = 0xFFFF;
    writeNetwork16(frame, udp_offset + 6, checksum);
    return ethernet_frame_bytes;
}

fn parseResponse(
    frame: []const u8,
    client_mac: [6]u8,
    expected_message_type: u8,
    expected_address: ?[4]u8,
    expected_server_identifier: ?[4]u8,
) ?Response {
    if (frame.len < ethernet_header_bytes + ipv4_header_bytes + udp_header_bytes + dhcp_fixed_bytes) return null;
    const destination = frame[0..6];
    if (!std.mem.eql(u8, destination, &client_mac) and !std.mem.eql(u8, destination, &broadcast_mac)) return null;
    if (readNetwork16(frame, 12) != ether_type_ipv4) return null;

    var server_mac: [6]u8 = undefined;
    @memcpy(&server_mac, frame[6..12]);
    if (allZero(&server_mac) or allOnes(&server_mac)) return null;

    const ip_offset = ethernet_header_bytes;
    if ((frame[ip_offset] >> 4) != 4) return null;
    const ihl_bytes: usize = @as(usize, frame[ip_offset] & 0x0F) * 4;
    if (ihl_bytes < ipv4_header_bytes or ip_offset + ihl_bytes > frame.len) return null;
    const ip_total_length: usize = readNetwork16(frame, ip_offset + 2);
    if (ip_total_length < ihl_bytes + udp_header_bytes + dhcp_fixed_bytes or ip_offset + ip_total_length > frame.len) return null;
    if (frame[ip_offset + 9] != ipv4_protocol_udp or frame[ip_offset + 8] == 0) return null;
    if ((readNetwork16(frame, ip_offset + 6) & 0x1FFF) != 0) return null;
    if (internetChecksum(frame[ip_offset .. ip_offset + ihl_bytes]) != 0) return null;

    var source_ipv4: [4]u8 = undefined;
    @memcpy(&source_ipv4, frame[ip_offset + 12 .. ip_offset + 16]);
    var destination_ipv4: [4]u8 = undefined;
    @memcpy(&destination_ipv4, frame[ip_offset + 16 .. ip_offset + 20]);

    const udp_offset = ip_offset + ihl_bytes;
    if (readNetwork16(frame, udp_offset) != dhcp_server_port or
        readNetwork16(frame, udp_offset + 2) != dhcp_client_port)
    {
        return null;
    }
    const udp_length: usize = readNetwork16(frame, udp_offset + 4);
    if (udp_length < udp_header_bytes + dhcp_fixed_bytes or udp_offset + udp_length > ip_offset + ip_total_length) return null;
    const udp_packet = frame[udp_offset .. udp_offset + udp_length];
    const udp_checksum_value = readNetwork16(frame, udp_offset + 6);
    if (udp_checksum_value != 0 and udpChecksum(source_ipv4, destination_ipv4, udp_packet) != 0) return null;

    const dhcp_offset = udp_offset + udp_header_bytes;
    if (frame[dhcp_offset] != bootp_reply or
        frame[dhcp_offset + 1] != hardware_ethernet or
        frame[dhcp_offset + 2] != ethernet_address_bytes or
        readNetwork32(frame, dhcp_offset + 4) != transaction_id or
        readNetwork32(frame, dhcp_offset + 236) != dhcp_magic_cookie or
        !std.mem.eql(u8, frame[dhcp_offset + 28 .. dhcp_offset + 34], &client_mac))
    {
        return null;
    }

    var address: [4]u8 = undefined;
    @memcpy(&address, frame[dhcp_offset + 16 .. dhcp_offset + 20]);
    if (allZero(&address) or allOnes(&address)) return null;
    if (expected_address) |wanted| {
        if (!std.mem.eql(u8, &address, &wanted)) return null;
    }
    if (!std.mem.eql(u8, &destination_ipv4, &broadcast_ipv4) and
        !std.mem.eql(u8, &destination_ipv4, &address))
    {
        return null;
    }

    var message_type: ?u8 = null;
    var subnet_mask: ?[4]u8 = null;
    var router: ?[4]u8 = null;
    var dns_server: ?[4]u8 = null;
    var lease_seconds: ?u32 = null;
    var server_identifier: ?[4]u8 = null;
    var option_index = dhcp_offset + dhcp_fixed_bytes;
    const option_limit = udp_offset + udp_length;
    while (option_index < option_limit) {
        const option = frame[option_index];
        option_index += 1;
        if (option == 0) continue;
        if (option == option_end) break;
        if (option_index >= option_limit) return null;
        const length: usize = frame[option_index];
        option_index += 1;
        if (length > option_limit - option_index) return null;
        const value = frame[option_index .. option_index + length];
        switch (option) {
            option_message_type => if (length == 1) {
                message_type = value[0];
            },
            option_subnet_mask => if (length >= 4) {
                var parsed: [4]u8 = undefined;
                @memcpy(&parsed, value[0..4]);
                subnet_mask = parsed;
            },
            option_router => if (length >= 4) {
                var parsed: [4]u8 = undefined;
                @memcpy(&parsed, value[0..4]);
                router = parsed;
            },
            option_dns_server => if (length >= 4) {
                var parsed: [4]u8 = undefined;
                @memcpy(&parsed, value[0..4]);
                dns_server = parsed;
            },
            option_lease_time => if (length == 4) {
                lease_seconds = readNetwork32(value, 0);
            },
            option_server_identifier => if (length == 4) {
                var parsed: [4]u8 = undefined;
                @memcpy(&parsed, value);
                server_identifier = parsed;
            },
            else => {},
        }
        option_index += length;
    }

    const actual_message_type = message_type orelse return null;
    if (actual_message_type != expected_message_type) return null;
    const server = server_identifier orelse return null;
    if (allZero(&server) or !std.mem.eql(u8, &source_ipv4, &server)) return null;
    if (expected_server_identifier) |wanted| {
        if (!std.mem.eql(u8, &server, &wanted)) return null;
    }
    const mask = subnet_mask orelse return null;
    const route = router orelse server;
    const dns = dns_server orelse zero_ipv4;
    const lease = lease_seconds orelse return null;
    if (lease == 0 or allZero(&mask) or allZero(&route)) return null;

    return .{
        .lease = .{
            .address = address,
            .subnet_mask = mask,
            .router = route,
            .dns_server = dns,
            .router_advertised = router != null,
            .dns_server_advertised = dns_server != null,
            .server_identifier = server,
            .server_mac = server_mac,
            .lease_seconds = lease,
            .reply_ttl = frame[ip_offset + 8],
            .udp_checksum_present = udp_checksum_value != 0,
        },
        .frame_length = @intCast(frame.len),
    };
}

fn appendOptionByte(frame: []u8, index: usize, code: u8, value: u8) ?usize {
    const bytes = [_]u8{value};
    return appendOption(frame, index, code, &bytes);
}

fn appendOption(frame: []u8, index: usize, code: u8, value: []const u8) ?usize {
    if (value.len > std.math.maxInt(u8) or index > frame.len or frame.len - index < value.len + 2) return null;
    frame[index] = code;
    frame[index + 1] = @intCast(value.len);
    @memcpy(frame[index + 2 .. index + 2 + value.len], value);
    return index + 2 + value.len;
}

fn udpChecksum(source: [4]u8, destination: [4]u8, udp_packet: []const u8) u16 {
    var sum: u32 = 0;
    addChecksumBytes(&sum, &source);
    addChecksumBytes(&sum, &destination);
    sum += ipv4_protocol_udp;
    sum += @intCast(udp_packet.len);
    addChecksumBytes(&sum, udp_packet);
    return finalizeChecksum(sum);
}

fn internetChecksum(bytes: []const u8) u16 {
    var sum: u32 = 0;
    addChecksumBytes(&sum, bytes);
    return finalizeChecksum(sum);
}

fn addChecksumBytes(sum: *u32, bytes: []const u8) void {
    var index: usize = 0;
    while (index + 1 < bytes.len) : (index += 2) {
        sum.* += (@as(u32, bytes[index]) << 8) | bytes[index + 1];
        sum.* = (sum.* & 0xFFFF) + (sum.* >> 16);
    }
    if (index < bytes.len) sum.* += @as(u32, bytes[index]) << 8;
}

fn finalizeChecksum(initial_sum: u32) u16 {
    var sum = initial_sum;
    while ((sum >> 16) != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return @truncate(~sum);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn allOnes(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0xFF) return false;
    return true;
}

fn writeNetwork16(bytes: []u8, offset: usize, value: anytype) void {
    const converted: u16 = @intCast(value);
    bytes[offset] = @truncate(converted >> 8);
    bytes[offset + 1] = @truncate(converted);
}

fn writeNetwork32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value >> 24);
    bytes[offset + 1] = @truncate(value >> 16);
    bytes[offset + 2] = @truncate(value >> 8);
    bytes[offset + 3] = @truncate(value);
}

fn readNetwork16(bytes: []const u8, offset: usize) u16 {
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

fn readNetwork32(bytes: []const u8, offset: usize) u32 {
    return (@as(u32, bytes[offset]) << 24) |
        (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) |
        bytes[offset + 3];
}

comptime {
    if (dhcp_fixed_bytes != 240) @compileError("DHCP fixed header and cookie must remain 240 bytes");
    if (dhcp_payload_bytes != 300) @compileError("DHCP client payload must remain BOOTP-compatible");
    if (ethernet_frame_bytes != 342) @compileError("DHCP Ethernet frame size changed unexpectedly");
}
