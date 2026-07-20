const std = @import("std");

pub const protocol_number: u8 = 6;
pub const minimum_header_bytes: usize = 20;
pub const maximum_options_bytes: usize = 40;

const ethernet_header_bytes: usize = 14;
const ipv4_minimum_header_bytes: usize = 20;
const ethernet_minimum_frame_bytes: usize = 60;
const ether_type_ipv4: u16 = 0x0800;
const ipv4_dont_fragment: u16 = 1 << 14;

pub const flag_fin: u9 = 1 << 0;
pub const flag_syn: u9 = 1 << 1;
pub const flag_rst: u9 = 1 << 2;
pub const flag_psh: u9 = 1 << 3;
pub const flag_ack: u9 = 1 << 4;
pub const flag_urg: u9 = 1 << 5;
pub const flag_ece: u9 = 1 << 6;
pub const flag_cwr: u9 = 1 << 7;
pub const flag_ns: u9 = 1 << 8;

pub const BuildOptions = struct {
    source_mac: [6]u8,
    destination_mac: [6]u8,
    source_ipv4: [4]u8,
    destination_ipv4: [4]u8,
    source_port: u16,
    destination_port: u16,
    identification: u16,
    sequence_number: u32,
    acknowledgement_number: u32 = 0,
    flags: u9,
    window_size: u16,
    urgent_pointer: u16 = 0,
    ttl: u8 = 64,
    options: []const u8 = &.{},
    payload: []const u8 = &.{},
};

pub const ParseOptions = struct {
    destination_mac: [6]u8,
    source_mac: ?[6]u8 = null,
    destination_ipv4: [4]u8,
    source_ipv4: ?[4]u8 = null,
    destination_port: ?u16 = null,
    source_port: ?u16 = null,
};

pub const Segment = struct {
    source_mac: [6]u8,
    destination_mac: [6]u8,
    source_ipv4: [4]u8,
    destination_ipv4: [4]u8,
    source_port: u16,
    destination_port: u16,
    ttl: u8,
    identification: u16,
    sequence_number: u32,
    acknowledgement_number: u32,
    flags: u9,
    window_size: u16,
    checksum: u16,
    urgent_pointer: u16,
    header_length: u8,
    frame_length: u16,
    options: []const u8,
    payload: []const u8,

    pub fn hasFlag(self: Segment, flag: u9) bool {
        return (self.flags & flag) != 0;
    }
};

pub fn buildFrame(frame: []u8, options: BuildOptions) ?u16 {
    if (options.source_port == 0 or options.destination_port == 0 or options.ttl == 0) return null;
    if (options.options.len > maximum_options_bytes or (options.options.len & 3) != 0) return null;
    if ((options.flags & flag_urg) == 0 and options.urgent_pointer != 0) return null;

    const tcp_header_length = std.math.add(usize, minimum_header_bytes, options.options.len) catch return null;
    const tcp_length = std.math.add(usize, tcp_header_length, options.payload.len) catch return null;
    if (tcp_length > std.math.maxInt(u16)) return null;
    const ipv4_total_length = std.math.add(usize, ipv4_minimum_header_bytes, tcp_length) catch return null;
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
    frame[ip_offset + 9] = protocol_number;
    writeNetwork16(frame, ip_offset + 10, 0);
    @memcpy(frame[ip_offset + 12 .. ip_offset + 16], &options.source_ipv4);
    @memcpy(frame[ip_offset + 16 .. ip_offset + 20], &options.destination_ipv4);
    writeNetwork16(
        frame,
        ip_offset + 10,
        internetChecksum(frame[ip_offset .. ip_offset + ipv4_minimum_header_bytes]),
    );

    const tcp_offset = ip_offset + ipv4_minimum_header_bytes;
    writeNetwork16(frame, tcp_offset, options.source_port);
    writeNetwork16(frame, tcp_offset + 2, options.destination_port);
    writeNetwork32(frame, tcp_offset + 4, options.sequence_number);
    writeNetwork32(frame, tcp_offset + 8, options.acknowledgement_number);
    const data_offset_words: u8 = @intCast(tcp_header_length / 4);
    frame[tcp_offset + 12] = (data_offset_words << 4) | @as(u8, @truncate(options.flags >> 8));
    frame[tcp_offset + 13] = @truncate(options.flags);
    writeNetwork16(frame, tcp_offset + 14, options.window_size);
    writeNetwork16(frame, tcp_offset + 16, 0);
    writeNetwork16(frame, tcp_offset + 18, options.urgent_pointer);
    @memcpy(frame[tcp_offset + minimum_header_bytes .. tcp_offset + tcp_header_length], options.options);
    @memcpy(frame[tcp_offset + tcp_header_length .. tcp_offset + tcp_length], options.payload);
    var checksum = tcpChecksum(
        options.source_ipv4,
        options.destination_ipv4,
        frame[tcp_offset .. tcp_offset + tcp_length],
    );
    if (checksum == 0) checksum = 0xFFFF;
    writeNetwork16(frame, tcp_offset + 16, checksum);
    return @intCast(frame_length);
}

pub fn parseFrame(frame: []const u8, options: ParseOptions) ?Segment {
    if (frame.len < ethernet_header_bytes + ipv4_minimum_header_bytes + minimum_header_bytes) return null;
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
    if (ipv4_total_length < ihl_bytes + minimum_header_bytes or ip_offset + ipv4_total_length > frame.len) return null;
    if (frame[ip_offset + 9] != protocol_number or frame[ip_offset + 8] == 0) return null;
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

    const tcp_offset = ip_offset + ihl_bytes;
    const tcp_length = ipv4_total_length - ihl_bytes;
    const source_port = readNetwork16(frame, tcp_offset);
    const destination_port = readNetwork16(frame, tcp_offset + 2);
    if (source_port == 0 or destination_port == 0) return null;
    if (options.destination_port) |expected| {
        if (destination_port != expected) return null;
    }
    if (options.source_port) |expected| {
        if (source_port != expected) return null;
    }

    const data_offset_words: usize = frame[tcp_offset + 12] >> 4;
    const tcp_header_length = data_offset_words * 4;
    if (tcp_header_length < minimum_header_bytes or tcp_header_length > tcp_length) return null;
    if ((frame[tcp_offset + 12] & 0x0E) != 0) return null;
    const checksum = readNetwork16(frame, tcp_offset + 16);
    if (checksum == 0 or tcpChecksum(source_ipv4, destination_ipv4, frame[tcp_offset .. tcp_offset + tcp_length]) != 0) {
        return null;
    }

    const flags: u9 = (@as(u9, frame[tcp_offset + 12] & 1) << 8) | frame[tcp_offset + 13];
    const urgent_pointer = readNetwork16(frame, tcp_offset + 18);
    if ((flags & flag_urg) == 0 and urgent_pointer != 0) return null;

    return .{
        .source_mac = source_mac,
        .destination_mac = destination_mac,
        .source_ipv4 = source_ipv4,
        .destination_ipv4 = destination_ipv4,
        .source_port = source_port,
        .destination_port = destination_port,
        .ttl = frame[ip_offset + 8],
        .identification = readNetwork16(frame, ip_offset + 4),
        .sequence_number = readNetwork32(frame, tcp_offset + 4),
        .acknowledgement_number = readNetwork32(frame, tcp_offset + 8),
        .flags = flags,
        .window_size = readNetwork16(frame, tcp_offset + 14),
        .checksum = checksum,
        .urgent_pointer = urgent_pointer,
        .header_length = @intCast(tcp_header_length),
        .frame_length = @intCast(frame.len),
        .options = frame[tcp_offset + minimum_header_bytes .. tcp_offset + tcp_header_length],
        .payload = frame[tcp_offset + tcp_header_length .. tcp_offset + tcp_length],
    };
}

fn tcpChecksum(source: [4]u8, destination: [4]u8, tcp_packet: []const u8) u16 {
    var sum: u32 = 0;
    addChecksumBytes(&sum, &source);
    addChecksumBytes(&sum, &destination);
    sum += protocol_number;
    sum += @intCast(tcp_packet.len);
    addChecksumBytes(&sum, tcp_packet);
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
    if (ethernet_header_bytes != 14) @compileError("Ethernet II header size changed unexpectedly");
    if (ipv4_minimum_header_bytes != 20) @compileError("IPv4 minimum header size changed unexpectedly");
    if (minimum_header_bytes != 20) @compileError("TCP minimum header size changed unexpectedly");
    if (maximum_options_bytes != 40) @compileError("TCP option capacity changed unexpectedly");
}
