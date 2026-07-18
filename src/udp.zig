const std = @import("std");

const ethernet_header_bytes: usize = 14;
const ipv4_minimum_header_bytes: usize = 20;
const udp_header_bytes: usize = 8;
const ethernet_minimum_frame_bytes: usize = 60;
const ether_type_ipv4: u16 = 0x0800;
const ipv4_protocol_udp: u8 = 17;
const ipv4_dont_fragment: u16 = 1 << 14;

pub const BuildOptions = struct {
    source_mac: [6]u8,
    destination_mac: [6]u8,
    source_ipv4: [4]u8,
    destination_ipv4: [4]u8,
    source_port: u16,
    destination_port: u16,
    identification: u16,
    ttl: u8 = 64,
    payload: []const u8,
};

pub const ParseOptions = struct {
    destination_mac: [6]u8,
    source_mac: ?[6]u8 = null,
    destination_ipv4: [4]u8,
    source_ipv4: ?[4]u8 = null,
    destination_port: ?u16 = null,
    source_port: ?u16 = null,
};

pub const Datagram = struct {
    source_mac: [6]u8,
    destination_mac: [6]u8,
    source_ipv4: [4]u8,
    destination_ipv4: [4]u8,
    source_port: u16,
    destination_port: u16,
    ttl: u8,
    identification: u16,
    udp_checksum_present: bool,
    frame_length: u16,
    payload: []const u8,
};

pub fn buildFrame(frame: []u8, options: BuildOptions) ?u16 {
    if (options.source_port == 0 or options.destination_port == 0 or options.ttl == 0) return null;
    const udp_length = std.math.add(usize, udp_header_bytes, options.payload.len) catch return null;
    if (udp_length > std.math.maxInt(u16)) return null;
    const ipv4_total_length = std.math.add(usize, ipv4_minimum_header_bytes, udp_length) catch return null;
    if (ipv4_total_length > std.math.maxInt(u16)) return null;
    const unpadded_frame_length = std.math.add(usize, ethernet_header_bytes, ipv4_total_length) catch return null;
    const frame_length = @max(unpadded_frame_length, ethernet_minimum_frame_bytes);
    if (frame_length > frame.len or frame_length > std.math.maxInt(u16)) return null;

    @memset(frame[0..frame_length], 0);
    @memcpy(frame[0..6], &options.destination_mac);
    @memcpy(frame[6..12], &options.source_mac);
    writeNetwork16(frame, 12, ether_type_ipv4);

    const ip_offset = ethernet_header_bytes;
    frame[ip_offset] = 0x45;
    frame[ip_offset + 1] = 0;
    writeNetwork16(frame, ip_offset + 2, @intCast(ipv4_total_length));
    writeNetwork16(frame, ip_offset + 4, options.identification);
    writeNetwork16(frame, ip_offset + 6, ipv4_dont_fragment);
    frame[ip_offset + 8] = options.ttl;
    frame[ip_offset + 9] = ipv4_protocol_udp;
    writeNetwork16(frame, ip_offset + 10, 0);
    @memcpy(frame[ip_offset + 12 .. ip_offset + 16], &options.source_ipv4);
    @memcpy(frame[ip_offset + 16 .. ip_offset + 20], &options.destination_ipv4);
    writeNetwork16(
        frame,
        ip_offset + 10,
        internetChecksum(frame[ip_offset .. ip_offset + ipv4_minimum_header_bytes]),
    );

    const udp_offset = ip_offset + ipv4_minimum_header_bytes;
    writeNetwork16(frame, udp_offset, options.source_port);
    writeNetwork16(frame, udp_offset + 2, options.destination_port);
    writeNetwork16(frame, udp_offset + 4, @intCast(udp_length));
    writeNetwork16(frame, udp_offset + 6, 0);
    @memcpy(frame[udp_offset + udp_header_bytes .. udp_offset + udp_length], options.payload);
    var checksum = udpChecksum(
        options.source_ipv4,
        options.destination_ipv4,
        frame[udp_offset .. udp_offset + udp_length],
    );
    if (checksum == 0) checksum = 0xFFFF;
    writeNetwork16(frame, udp_offset + 6, checksum);
    return @intCast(frame_length);
}

pub fn parseFrame(frame: []const u8, options: ParseOptions) ?Datagram {
    if (frame.len < ethernet_header_bytes + ipv4_minimum_header_bytes + udp_header_bytes) return null;
    if (!std.mem.eql(u8, frame[0..6], &options.destination_mac)) return null;
    if (options.source_mac) |expected| {
        if (!std.mem.eql(u8, frame[6..12], &expected)) return null;
    }
    if (readNetwork16(frame, 12) != ether_type_ipv4) return null;

    var source_mac: [6]u8 = undefined;
    @memcpy(&source_mac, frame[6..12]);
    var destination_mac: [6]u8 = undefined;
    @memcpy(&destination_mac, frame[0..6]);

    const ip_offset = ethernet_header_bytes;
    if ((frame[ip_offset] >> 4) != 4) return null;
    const ihl_bytes: usize = @as(usize, frame[ip_offset] & 0x0F) * 4;
    if (ihl_bytes < ipv4_minimum_header_bytes or ip_offset + ihl_bytes > frame.len) return null;
    const ipv4_total_length: usize = readNetwork16(frame, ip_offset + 2);
    if (ipv4_total_length < ihl_bytes + udp_header_bytes or
        ip_offset + ipv4_total_length > frame.len)
    {
        return null;
    }
    if (frame[ip_offset + 9] != ipv4_protocol_udp or frame[ip_offset + 8] == 0) return null;
    if ((readNetwork16(frame, ip_offset + 6) & 0x3FFF) != 0) return null;
    if (internetChecksum(frame[ip_offset .. ip_offset + ihl_bytes]) != 0) return null;

    var source_ipv4: [4]u8 = undefined;
    @memcpy(&source_ipv4, frame[ip_offset + 12 .. ip_offset + 16]);
    var destination_ipv4: [4]u8 = undefined;
    @memcpy(&destination_ipv4, frame[ip_offset + 16 .. ip_offset + 20]);
    if (options.source_ipv4) |expected| {
        if (!std.mem.eql(u8, &source_ipv4, &expected)) return null;
    }
    if (!std.mem.eql(u8, &destination_ipv4, &options.destination_ipv4)) return null;

    const udp_offset = ip_offset + ihl_bytes;
    const source_port = readNetwork16(frame, udp_offset);
    const destination_port = readNetwork16(frame, udp_offset + 2);
    if (source_port == 0 or destination_port == 0) return null;
    if (options.destination_port) |expected| {
        if (destination_port != expected) return null;
    }
    if (options.source_port) |expected| {
        if (source_port != expected) return null;
    }
    const udp_length: usize = readNetwork16(frame, udp_offset + 4);
    if (udp_length < udp_header_bytes or udp_offset + udp_length != ip_offset + ipv4_total_length) return null;
    const udp_packet = frame[udp_offset .. udp_offset + udp_length];
    const checksum = readNetwork16(frame, udp_offset + 6);
    if (checksum != 0 and udpChecksum(source_ipv4, destination_ipv4, udp_packet) != 0) return null;

    return .{
        .source_mac = source_mac,
        .destination_mac = destination_mac,
        .source_ipv4 = source_ipv4,
        .destination_ipv4 = destination_ipv4,
        .source_port = source_port,
        .destination_port = destination_port,
        .ttl = frame[ip_offset + 8],
        .identification = readNetwork16(frame, ip_offset + 4),
        .udp_checksum_present = checksum != 0,
        .frame_length = @intCast(frame.len),
        .payload = frame[udp_offset + udp_header_bytes .. udp_offset + udp_length],
    };
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

fn writeNetwork16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value >> 8);
    bytes[offset + 1] = @truncate(value);
}

fn readNetwork16(bytes: []const u8, offset: usize) u16 {
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

comptime {
    if (ethernet_header_bytes != 14) @compileError("Ethernet II header size changed unexpectedly");
    if (ipv4_minimum_header_bytes != 20) @compileError("IPv4 minimum header size changed unexpectedly");
    if (udp_header_bytes != 8) @compileError("UDP header size changed unexpectedly");
}
