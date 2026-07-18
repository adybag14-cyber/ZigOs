const std = @import("std");

const header_bytes: usize = 12;
const question_tail_bytes: usize = 4;
const resource_record_fixed_bytes: usize = 10;
pub const maximum_name_bytes: usize = 253;
const maximum_compression_jumps: usize = 16;
const maximum_alias_hops: usize = 8;
const flag_response: u16 = 1 << 15;
const flag_authoritative: u16 = 1 << 10;
const flag_truncated: u16 = 1 << 9;
const flag_recursion_desired: u16 = 1 << 8;
const flag_recursion_available: u16 = 1 << 7;
const opcode_mask: u16 = 0x7800;
const response_code_mask: u16 = 0x000F;
const class_internet: u16 = 1;
const type_a: u16 = 1;
const type_cname: u16 = 5;

pub const server_port: u16 = 53;
pub const default_ttl: u32 = 300;
pub const fixture_transaction_id: u16 = 0x4453;
pub const fixture_name = "zigos.test";
pub const fixture_alias_name = "alias.zigos.test";
pub const fixture_address = [4]u8{ 192, 0, 2, 42 };

pub const AResponse = struct {
    address: [4]u8,
    ttl: u32,
    authoritative: bool,
    recursion_available: bool,
    alias_hops: u8,
};

const DecodedName = struct {
    next_offset: usize,
    length: usize,
};

pub fn buildAQuery(buffer: []u8, transaction_id: u16, name: []const u8) ?[]const u8 {
    const encoded_name_bytes = encodedNameLength(name) orelse return null;
    const length = header_bytes + encoded_name_bytes + question_tail_bytes;
    if (buffer.len < length) return null;
    @memset(buffer[0..length], 0);
    writeNetwork16(buffer, 0, transaction_id);
    writeNetwork16(buffer, 2, flag_recursion_desired);
    writeNetwork16(buffer, 4, 1);
    var offset: usize = header_bytes;
    offset = encodeName(buffer, offset, name) orelse return null;
    writeNetwork16(buffer, offset, type_a);
    writeNetwork16(buffer, offset + 2, class_internet);
    return buffer[0..length];
}

pub fn buildAResponse(
    buffer: []u8,
    transaction_id: u16,
    name: []const u8,
    address: [4]u8,
    ttl: u32,
) ?[]const u8 {
    const query = buildAQuery(buffer, transaction_id, name) orelse return null;
    const length = query.len + 2 + resource_record_fixed_bytes + address.len;
    if (buffer.len < length) return null;
    writeNetwork16(buffer, 2, flag_response | flag_authoritative | flag_recursion_desired | flag_recursion_available);
    writeNetwork16(buffer, 6, 1);
    var offset = query.len;
    writeNetwork16(buffer, offset, 0xC000 | @as(u16, header_bytes));
    offset += 2;
    writeNetwork16(buffer, offset, type_a);
    writeNetwork16(buffer, offset + 2, class_internet);
    writeNetwork32(buffer, offset + 4, ttl);
    writeNetwork16(buffer, offset + 8, address.len);
    @memcpy(buffer[offset + resource_record_fixed_bytes .. length], &address);
    return buffer[0..length];
}

pub fn buildCnameAResponse(
    buffer: []u8,
    transaction_id: u16,
    alias_name: []const u8,
    canonical_name: []const u8,
    address: [4]u8,
    ttl: u32,
) ?[]const u8 {
    const canonical_encoded_bytes = encodedNameLength(canonical_name) orelse return null;
    const query = buildAQuery(buffer, transaction_id, alias_name) orelse return null;
    const length = query.len + 26 + canonical_encoded_bytes * 2;
    if (buffer.len < length) return null;
    writeNetwork16(buffer, 2, flag_response | flag_authoritative | flag_recursion_desired | flag_recursion_available);
    writeNetwork16(buffer, 6, 2);

    var offset = query.len;
    writeNetwork16(buffer, offset, 0xC000 | @as(u16, header_bytes));
    offset += 2;
    writeNetwork16(buffer, offset, type_cname);
    writeNetwork16(buffer, offset + 2, class_internet);
    writeNetwork32(buffer, offset + 4, ttl);
    writeNetwork16(buffer, offset + 8, @intCast(canonical_encoded_bytes));
    offset += resource_record_fixed_bytes;
    offset = encodeName(buffer, offset, canonical_name) orelse return null;

    offset = encodeName(buffer, offset, canonical_name) orelse return null;
    writeNetwork16(buffer, offset, type_a);
    writeNetwork16(buffer, offset + 2, class_internet);
    writeNetwork32(buffer, offset + 4, ttl);
    writeNetwork16(buffer, offset + 8, address.len);
    offset += resource_record_fixed_bytes;
    @memcpy(buffer[offset .. offset + address.len], &address);
    offset += address.len;
    if (offset != length) return null;
    return buffer[0..length];
}

pub fn parseAResponse(
    message: []const u8,
    expected_transaction_id: u16,
    expected_name: []const u8,
) ?AResponse {
    _ = encodedNameLength(expected_name) orelse return null;
    if (message.len < header_bytes) return null;
    if (readNetwork16(message, 0) != expected_transaction_id) return null;
    const flags = readNetwork16(message, 2);
    if ((flags & flag_response) == 0 or (flags & opcode_mask) != 0 or
        (flags & flag_truncated) != 0 or (flags & response_code_mask) != 0)
    {
        return null;
    }
    const question_count = readNetwork16(message, 4);
    const answer_count = readNetwork16(message, 6);
    if (question_count != 1 or answer_count == 0) return null;

    var question_name_buffer: [maximum_name_bytes]u8 = undefined;
    const question_name = decodeName(message, header_bytes, &question_name_buffer) orelse return null;
    if (!equalName(question_name_buffer[0..question_name.length], expected_name)) return null;
    var offset = question_name.next_offset;
    if (offset + question_tail_bytes > message.len) return null;
    if (readNetwork16(message, offset) != type_a or
        readNetwork16(message, offset + 2) != class_internet)
    {
        return null;
    }
    offset += question_tail_bytes;
    const answers_offset = offset;

    var current_name = std.mem.zeroes([maximum_name_bytes]u8);
    @memcpy(current_name[0..expected_name.len], expected_name);
    var current_length = expected_name.len;
    var visited_names = std.mem.zeroes([maximum_alias_hops + 1][maximum_name_bytes]u8);
    var visited_lengths = std.mem.zeroes([maximum_alias_hops + 1]usize);
    @memcpy(visited_names[0][0..expected_name.len], expected_name);
    visited_lengths[0] = expected_name.len;
    var alias_hops: u8 = 0;

    while (true) {
        offset = answers_offset;
        var cname_found = false;
        var cname_target = std.mem.zeroes([maximum_name_bytes]u8);
        var cname_target_length: usize = 0;
        var answer_index: u16 = 0;
        while (answer_index < answer_count) : (answer_index += 1) {
            var owner_buffer: [maximum_name_bytes]u8 = undefined;
            const owner = decodeName(message, offset, &owner_buffer) orelse return null;
            offset = owner.next_offset;
            if (offset + resource_record_fixed_bytes > message.len) return null;
            const record_type = readNetwork16(message, offset);
            const record_class = readNetwork16(message, offset + 2);
            const ttl = readNetwork32(message, offset + 4);
            const data_length: usize = readNetwork16(message, offset + 8);
            offset += resource_record_fixed_bytes;
            const data_offset = offset;
            const data_end = data_offset + data_length;
            if (data_end > message.len) return null;

            if (record_class == class_internet and
                equalName(owner_buffer[0..owner.length], current_name[0..current_length]))
            {
                if (record_type == type_a and data_length == 4) {
                    var address: [4]u8 = undefined;
                    @memcpy(&address, message[data_offset..data_end]);
                    return .{
                        .address = address,
                        .ttl = ttl,
                        .authoritative = (flags & flag_authoritative) != 0,
                        .recursion_available = (flags & flag_recursion_available) != 0,
                        .alias_hops = alias_hops,
                    };
                }
                if (record_type == type_cname and !cname_found) {
                    const decoded = decodeName(message, data_offset, &cname_target) orelse return null;
                    if (decoded.next_offset != data_end) return null;
                    _ = encodedNameLength(cname_target[0..decoded.length]) orelse return null;
                    cname_target_length = decoded.length;
                    cname_found = true;
                }
            }
            offset = data_end;
        }

        if (!cname_found or alias_hops >= maximum_alias_hops) return null;
        var visited_index: usize = 0;
        while (visited_index <= alias_hops) : (visited_index += 1) {
            if (equalName(
                cname_target[0..cname_target_length],
                visited_names[visited_index][0..visited_lengths[visited_index]],
            )) return null;
        }
        alias_hops += 1;
        current_name = std.mem.zeroes([maximum_name_bytes]u8);
        @memcpy(current_name[0..cname_target_length], cname_target[0..cname_target_length]);
        current_length = cname_target_length;
        @memcpy(visited_names[alias_hops][0..cname_target_length], cname_target[0..cname_target_length]);
        visited_lengths[alias_hops] = cname_target_length;
    }
}

fn encodedNameLength(name: []const u8) ?usize {
    if (name.len == 0 or name.len > maximum_name_bytes or
        name[0] == '.' or name[name.len - 1] == '.')
    {
        return null;
    }
    var encoded_length: usize = 1;
    var label_start: usize = 0;
    var index: usize = 0;
    while (index <= name.len) : (index += 1) {
        if (index != name.len and name[index] != '.') continue;
        const label = name[label_start..index];
        if (!validLabel(label)) return null;
        encoded_length += 1 + label.len;
        label_start = index + 1;
    }
    return encoded_length;
}

fn validLabel(label: []const u8) bool {
    if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') return false;
    for (label) |byte| {
        if (!((byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or
            (byte >= '0' and byte <= '9') or byte == '-'))
        {
            return false;
        }
    }
    return true;
}

fn encodeName(buffer: []u8, start: usize, name: []const u8) ?usize {
    _ = encodedNameLength(name) orelse return null;
    var offset = start;
    var label_start: usize = 0;
    var index: usize = 0;
    while (index <= name.len) : (index += 1) {
        if (index != name.len and name[index] != '.') continue;
        const label = name[label_start..index];
        if (offset + 1 + label.len > buffer.len) return null;
        buffer[offset] = @intCast(label.len);
        offset += 1;
        @memcpy(buffer[offset .. offset + label.len], label);
        offset += label.len;
        label_start = index + 1;
    }
    if (offset >= buffer.len) return null;
    buffer[offset] = 0;
    return offset + 1;
}

fn decodeName(message: []const u8, start: usize, output: []u8) ?DecodedName {
    if (start >= message.len) return null;
    var cursor = start;
    var next_offset: usize = start;
    var output_length: usize = 0;
    var jumped = false;
    var jump_count: usize = 0;
    var label_count: usize = 0;
    while (true) {
        if (cursor >= message.len) return null;
        const length = message[cursor];
        if ((length & 0xC0) == 0xC0) {
            if (cursor + 1 >= message.len or jump_count >= maximum_compression_jumps) return null;
            const pointer = (@as(usize, length & 0x3F) << 8) | message[cursor + 1];
            if (pointer >= message.len) return null;
            if (!jumped) next_offset = cursor + 2;
            cursor = pointer;
            jumped = true;
            jump_count += 1;
            continue;
        }
        if ((length & 0xC0) != 0) return null;
        cursor += 1;
        if (length == 0) {
            if (!jumped) next_offset = cursor;
            if (label_count == 0) return null;
            return .{ .next_offset = next_offset, .length = output_length };
        }
        if (length > 63 or cursor + length > message.len) return null;
        if (label_count != 0) {
            if (output_length >= output.len) return null;
            output[output_length] = '.';
            output_length += 1;
        }
        if (output_length + length > output.len) return null;
        @memcpy(output[output_length .. output_length + length], message[cursor .. cursor + length]);
        output_length += length;
        cursor += length;
        label_count += 1;
    }
}

fn equalName(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_byte, right_byte| {
        if (asciiLower(left_byte) != asciiLower(right_byte)) return false;
    }
    return true;
}

fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
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
    if (fixture_name.len != 10) @compileError("DNS fixture name changed unexpectedly");
    if (fixture_alias_name.len != 16) @compileError("DNS alias fixture name changed unexpectedly");
    if (maximum_name_bytes != 253) @compileError("DNS maximum domain length changed unexpectedly");
}
