const std = @import("std");
const zigos = @import("zigos.zig");

pub const maximum_packet_bytes: usize = 512;
pub const maximum_name_bytes: usize = 253;
pub const dns_port: u16 = 53;

pub const CodecError = error{
    BufferTooSmall,
    InvalidName,
    MalformedResponse,
    TransactionMismatch,
    NotFound,
    ServerFailure,
    Timeout,
    ShortWrite,
};

pub const Error = zigos.Error || CodecError;

pub const Resolution = struct {
    address: [4]u8,
    ttl_seconds: u32,
};

pub fn ipv4Address(address: [4]u8, port: u16) zigos.Ipv4SocketAddress {
    return .{
        .family = zigos.constants.address_family_ipv4,
        .port_be = @byteSwap(port),
        .address_be = @bitCast(address),
    };
}

pub fn resolveA(server: zigos.Ipv4SocketAddress, name: []const u8, timeout_ticks: u64) Error!Resolution {
    if (timeout_ticks == 0 or server.family != zigos.constants.address_family_ipv4 or
        server.port_be == 0 or server.address_be == 0)
        return error.InvalidArgument;

    var query: [maximum_packet_bytes]u8 = undefined;
    const transaction = try nextTransaction();
    const query_length = try encodeQuery(&query, transaction, name);

    const fd = try zigos.socket();
    defer zigos.close(fd) catch {};
    var local = ipv4Address(.{ 0, 0, 0, 0 }, 0);
    try zigos.bind(fd, &local);
    try zigos.setNonblocking(fd, true);
    if (try zigos.sendto(fd, query[0..query_length], &server) != query_length) return error.ShortWrite;

    const started = try zigos.ticks();
    const deadline = started +| timeout_ticks;
    var packet: [maximum_packet_bytes]u8 = undefined;
    while (true) {
        var source = ipv4Address(.{ 0, 0, 0, 0 }, 0);
        const received = zigos.recvfrom(fd, &packet, &source, .{ .dontwait = true }) catch |err| switch (err) {
            error.WouldBlock => {
                if (try zigos.ticks() >= deadline) return error.Timeout;
                try zigos.sleep(1);
                continue;
            },
            else => return err,
        };
        if (!sameEndpoint(source, server)) {
            if (try zigos.ticks() >= deadline) return error.Timeout;
            continue;
        }
        return parseAResponse(packet[0..received], transaction) catch |err| switch (err) {
            error.TransactionMismatch => {
                if (try zigos.ticks() >= deadline) return error.Timeout;
                continue;
            },
            else => return err,
        };
    }
}

pub fn encodeQuery(destination: []u8, transaction: u16, name: []const u8) CodecError!usize {
    if (destination.len < 17 or name.len == 0 or name.len > maximum_name_bytes) return error.BufferTooSmall;
    write16(destination, 0, transaction);
    write16(destination, 2, 0x0100);
    write16(destination, 4, 1);
    write16(destination, 6, 0);
    write16(destination, 8, 0);
    write16(destination, 10, 0);

    var output: usize = 12;
    var label_start: usize = 0;
    while (label_start < name.len) {
        var label_end = label_start;
        while (label_end < name.len and name[label_end] != '.') : (label_end += 1) {}
        const label_length = label_end - label_start;
        if (label_length == 0 or label_length > 63) return error.InvalidName;
        if (output + 1 + label_length + 5 > destination.len) return error.BufferTooSmall;
        destination[output] = @intCast(label_length);
        output += 1;
        @memcpy(destination[output .. output + label_length], name[label_start..label_end]);
        output += label_length;
        if (label_end == name.len) break;
        label_start = label_end + 1;
        if (label_start == name.len) return error.InvalidName;
    }
    destination[output] = 0;
    output += 1;
    write16(destination, output, 1);
    write16(destination, output + 2, 1);
    return output + 4;
}

pub fn parseAResponse(packet: []const u8, transaction: u16) CodecError!Resolution {
    if (packet.len < 12) return error.MalformedResponse;
    if (read16(packet, 0) != transaction) return error.TransactionMismatch;
    const flags = read16(packet, 2);
    if ((flags & 0x8000) == 0 or (flags & 0x0200) != 0) return error.MalformedResponse;
    switch (flags & 0x000F) {
        0 => {},
        3 => return error.NotFound,
        else => return error.ServerFailure,
    }
    const questions = read16(packet, 4);
    const answers = read16(packet, 6);
    var offset: usize = 12;
    for (0..questions) |_| {
        try skipName(packet, &offset);
        if (offset > packet.len or packet.len - offset < 4) return error.MalformedResponse;
        offset += 4;
    }
    for (0..answers) |_| {
        try skipName(packet, &offset);
        if (offset > packet.len or packet.len - offset < 10) return error.MalformedResponse;
        const record_type = read16(packet, offset);
        const record_class = read16(packet, offset + 2);
        const ttl = read32(packet, offset + 4);
        const data_length = read16(packet, offset + 8);
        offset += 10;
        if (offset > packet.len or data_length > packet.len - offset) return error.MalformedResponse;
        if (record_type == 1 and record_class == 1 and data_length == 4) {
            return .{
                .address = packet[offset..][0..4].*,
                .ttl_seconds = ttl,
            };
        }
        offset += data_length;
    }
    return error.NotFound;
}

fn nextTransaction() zigos.Error!u16 {
    const tick = try zigos.ticks();
    const pid = try zigos.getpid();
    var transaction: u16 = @truncate(tick ^ (@as(u64, pid) << 8));
    if (transaction == 0) transaction = 1;
    return transaction;
}

fn sameEndpoint(left: zigos.Ipv4SocketAddress, right: zigos.Ipv4SocketAddress) bool {
    return left.family == right.family and left.port_be == right.port_be and left.address_be == right.address_be;
}

fn skipName(packet: []const u8, offset: *usize) CodecError!void {
    var cursor = offset.*;
    var labels: usize = 0;
    while (true) {
        if (cursor >= packet.len) return error.MalformedResponse;
        const length = packet[cursor];
        if ((length & 0xC0) == 0xC0) {
            if (cursor + 1 >= packet.len) return error.MalformedResponse;
            const pointer = (@as(usize, length & 0x3F) << 8) | packet[cursor + 1];
            if (pointer >= cursor or pointer >= packet.len) return error.MalformedResponse;
            offset.* = cursor + 2;
            return;
        }
        if ((length & 0xC0) != 0 or length > 63) return error.MalformedResponse;
        cursor += 1;
        if (length == 0) {
            offset.* = cursor;
            return;
        }
        if (cursor > packet.len or length > packet.len - cursor) return error.MalformedResponse;
        cursor += length;
        labels += 1;
        if (labels > 127) return error.MalformedResponse;
    }
}

fn write16(destination: []u8, offset: usize, value: u16) void {
    destination[offset] = @truncate(value >> 8);
    destination[offset + 1] = @truncate(value);
}

fn read16(source: []const u8, offset: usize) u16 {
    return (@as(u16, source[offset]) << 8) | source[offset + 1];
}

fn read32(source: []const u8, offset: usize) u32 {
    return (@as(u32, source[offset]) << 24) |
        (@as(u32, source[offset + 1]) << 16) |
        (@as(u32, source[offset + 2]) << 8) |
        source[offset + 3];
}

test "DNS query codec emits a canonical localhost A request" {
    var packet: [maximum_packet_bytes]u8 = undefined;
    const length = try encodeQuery(&packet, 0x5A5A, "localhost");
    const expected = [_]u8{
        0x5A, 0x5A, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x09, 'l',  'o',  'c',  'a',  'l',  'h',  'o',  's',  't',  0x00, 0x00,
        0x01, 0x00, 0x01,
    };
    try std.testing.expectEqual(expected.len, length);
    try std.testing.expectEqualSlices(u8, &expected, packet[0..length]);
}

test "DNS response codec accepts a compressed IPv4 answer" {
    const packet = [_]u8{
        0x5A, 0x5A, 0x81, 0x80, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00,
        0x09, 'l',  'o',  'c',  'a',  'l',  'h',  'o',  's',  't',  0x00, 0x00,
        0x01, 0x00, 0x01, 0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x2A,
        0x30, 0x00, 0x04, 127,  0,    0,    1,
    };
    const resolution = try parseAResponse(&packet, 0x5A5A);
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, resolution.address);
    try std.testing.expectEqual(@as(u32, 10800), resolution.ttl_seconds);
}

test "DNS codecs reject invalid names transactions and compression pointers" {
    var query: [maximum_packet_bytes]u8 = undefined;
    try std.testing.expectError(error.InvalidName, encodeQuery(&query, 1, "bad..name"));
    const valid = [_]u8{
        0x5A, 0x5A, 0x81, 0x80, 0x00, 0x00, 0x00, 0x01, 0, 0, 0, 0,
        0xC0, 0xFF, 0,    1,    0,    1,    0,    0,    0, 1, 0, 4,
        127,  0,    0,    1,
    };
    try std.testing.expectError(error.TransactionMismatch, parseAResponse(&valid, 0x1234));
    try std.testing.expectError(error.MalformedResponse, parseAResponse(&valid, 0x5A5A));
    const self_pointer = [_]u8{
        0x5A, 0x5A, 0x81, 0x80, 0x00, 0x00, 0x00, 0x01, 0, 0, 0, 0,
        0xC0, 0x0C, 0,    1,    0,    1,    0,    0,    0, 1, 0, 4,
        127,  0,    0,    1,
    };
    try std.testing.expectError(error.MalformedResponse, parseAResponse(&self_pointer, 0x5A5A));
}
