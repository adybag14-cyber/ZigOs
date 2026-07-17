const std = @import("std");

const opcode_read_request: u16 = 1;
const opcode_data: u16 = 3;
const opcode_acknowledgement: u16 = 4;
const opcode_error: u16 = 5;
const first_block: u16 = 1;
const maximum_data_bytes: usize = 512;

pub const server_port: u16 = 69;
pub const client_port: u16 = 40_000;
pub const file_name = "zigos.bin";
pub const mode = "octet";
pub const expected_file_bytes: usize = 2304;
pub const expected_block_count: u16 = 5;
pub const initial_fnv1a64: u64 = 0xCBF2_9CE4_8422_2325;
pub const expected_payload_fnv1a64: u64 = 0x6175_986C_BBAB_5125;

pub const Data = struct {
    block: u16,
    payload: []const u8,
    final_block: bool,
};

pub fn buildReadRequest(buffer: []u8) ?[]const u8 {
    const length = 2 + file_name.len + 1 + mode.len + 1;
    if (buffer.len < length) return null;
    @memset(buffer[0..length], 0);
    writeNetwork16(buffer, 0, opcode_read_request);
    @memcpy(buffer[2 .. 2 + file_name.len], file_name);
    const mode_offset = 2 + file_name.len + 1;
    @memcpy(buffer[mode_offset .. mode_offset + mode.len], mode);
    return buffer[0..length];
}

pub fn parseData(payload: []const u8, expected_block: u16, file_offset: usize) ?Data {
    if (payload.len < 4 or expected_block == 0 or file_offset >= expected_file_bytes) return null;
    const opcode = readNetwork16(payload, 0);
    if (opcode == opcode_error) return null;
    if (opcode != opcode_data or readNetwork16(payload, 2) != expected_block) return null;

    const data = payload[4..];
    const expected_length = @min(maximum_data_bytes, expected_file_bytes - file_offset);
    if (data.len != expected_length) return null;
    for (data, 0..) |byte, index| {
        if (byte != fixtureByte(file_offset + index)) return null;
    }
    const final_block = file_offset + data.len == expected_file_bytes and data.len < maximum_data_bytes;
    return .{
        .block = expected_block,
        .payload = data,
        .final_block = final_block,
    };
}

pub fn buildAcknowledgement(buffer: []u8, block: u16) ?[]const u8 {
    if (buffer.len < 4 or block == 0) return null;
    writeNetwork16(buffer, 0, opcode_acknowledgement);
    writeNetwork16(buffer, 2, block);
    return buffer[0..4];
}

pub fn updatePayloadHash(initial_hash: u64, bytes: []const u8) u64 {
    var hash = initial_hash;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 0x0000_0100_0000_01B3;
    }
    return hash;
}

pub fn fixtureByte(index: usize) u8 {
    return @truncate(index * 37 + 11);
}

fn writeNetwork16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value >> 8);
    bytes[offset + 1] = @truncate(value);
}

fn readNetwork16(bytes: []const u8, offset: usize) u16 {
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

comptime {
    if (expected_file_bytes != 2304) @compileError("TFTP fixture length changed unexpectedly");
    if (expected_block_count != 5) @compileError("TFTP block count changed unexpectedly");
    if (file_name.len != 9) @compileError("TFTP fixture filename changed unexpectedly");
    if (mode.len != 5) @compileError("TFTP transfer mode changed unexpectedly");
}
