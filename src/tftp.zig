const std = @import("std");

const opcode_read_request: u16 = 1;
const opcode_data: u16 = 3;
const opcode_acknowledgement: u16 = 4;
const opcode_error: u16 = 5;
const first_block: u16 = 1;
const maximum_data_bytes: usize = 512;

pub const server_port: u16 = 69;
pub const client_port: u16 = 40_000;
pub const file_name = "zigos.txt";
pub const mode = "octet";
pub const expected_payload = "ZigOs deterministic TFTP payload v1\n";
pub const expected_payload_fnv1a64: u64 = 0x6FA5_A2AB_46F6_99B6;

pub const Data = struct {
    block: u16,
    payload_length: u16,
    payload_fnv1a64: u64,
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

pub fn parseData(payload: []const u8) ?Data {
    if (payload.len < 4) return null;
    const opcode = readNetwork16(payload, 0);
    if (opcode == opcode_error) return null;
    if (opcode != opcode_data or readNetwork16(payload, 2) != first_block) return null;
    const data = payload[4..];
    if (data.len > maximum_data_bytes or !std.mem.eql(u8, data, expected_payload)) return null;
    const hash = fnv1a64(data);
    if (hash != expected_payload_fnv1a64) return null;
    return .{
        .block = first_block,
        .payload_length = @intCast(data.len),
        .payload_fnv1a64 = hash,
        .final_block = data.len < maximum_data_bytes,
    };
}

pub fn buildAcknowledgement(buffer: []u8, block: u16) ?[]const u8 {
    if (buffer.len < 4 or block == 0) return null;
    writeNetwork16(buffer, 0, opcode_acknowledgement);
    writeNetwork16(buffer, 2, block);
    return buffer[0..4];
}

fn fnv1a64(bytes: []const u8) u64 {
    var hash: u64 = 0xCBF2_9CE4_8422_2325;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 0x0000_0100_0000_01B3;
    }
    return hash;
}

fn writeNetwork16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value >> 8);
    bytes[offset + 1] = @truncate(value);
}

fn readNetwork16(bytes: []const u8, offset: usize) u16 {
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

comptime {
    if (expected_payload.len != 36) @compileError("TFTP fixture payload length changed unexpectedly");
    if (file_name.len != 9) @compileError("TFTP fixture filename changed unexpectedly");
    if (mode.len != 5) @compileError("TFTP transfer mode changed unexpectedly");
}
