const std = @import("std");

pub const page_size: u64 = 4096;
pub const maximum_load_segments: usize = 4;
pub const pt_load: u32 = 1;
pub const pf_execute: u32 = 1;
pub const pf_write: u32 = 2;
pub const pf_read: u32 = 4;

pub const Segment = struct {
    file_offset: u64,
    virtual_address: u64,
    file_size: u64,
    memory_size: u64,
    alignment: u64,
    flags: u32,

    pub fn readable(self: Segment) bool {
        return (self.flags & pf_read) != 0;
    }

    pub fn writable(self: Segment) bool {
        return (self.flags & pf_write) != 0;
    }

    pub fn executable(self: Segment) bool {
        return (self.flags & pf_execute) != 0;
    }
};

pub const Image = struct {
    entry: u64,
    program_header_offset: u64,
    program_header_count: u16,
    load_count: u8,
    load_segments: [maximum_load_segments]Segment,
    file_hash: u64,

    pub fn segmentBytes(self: *const Image, file: []const u8, index: usize) ?[]const u8 {
        if (index >= self.load_count) return null;
        const segment = self.load_segments[index];
        const start: usize = @intCast(segment.file_offset);
        const size: usize = @intCast(segment.file_size);
        if (start > file.len or size > file.len - start) return null;
        return file[start .. start + size];
    }
};

pub fn parse(file: []const u8) ?Image {
    if (file.len < 64) return null;
    if (!std.mem.eql(u8, file[0..4], "\x7FELF")) return null;
    if (file[4] != 2 or file[5] != 1 or file[6] != 1 or file[7] != 0) return null;
    for (file[8..16]) |byte| if (byte != 0) return null;
    if (read16(file, 16) != 2 or read16(file, 18) != 0x3E or read32(file, 20) != 1) return null;

    const entry = read64(file, 24);
    const program_header_offset = read64(file, 32);
    if (read64(file, 40) != 0 or read32(file, 48) != 0) return null;
    if (read16(file, 52) != 64 or read16(file, 54) != 56) return null;
    const program_header_count = read16(file, 56);
    if (program_header_count == 0 or program_header_count > 16) return null;
    if (read16(file, 58) != 0 or read16(file, 60) != 0 or read16(file, 62) != 0) return null;

    const phoff: usize = std.math.cast(usize, program_header_offset) orelse return null;
    const ph_bytes = std.math.mul(usize, program_header_count, 56) catch return null;
    if (phoff > file.len or ph_bytes > file.len - phoff) return null;
    if (!isCanonicalUser(entry)) return null;

    var result = Image{
        .entry = entry,
        .program_header_offset = program_header_offset,
        .program_header_count = program_header_count,
        .load_count = 0,
        .load_segments = @splat(.{
            .file_offset = 0,
            .virtual_address = 0,
            .file_size = 0,
            .memory_size = 0,
            .alignment = 0,
            .flags = 0,
        }),
        .file_hash = fnv1a64(file),
    };

    var entry_in_executable = false;
    var previous_end: u64 = 0;
    for (0..program_header_count) |index| {
        const offset = phoff + index * 56;
        const kind = read32(file, offset);
        const flags = read32(file, offset + 4);
        const file_offset = read64(file, offset + 8);
        const virtual_address = read64(file, offset + 16);
        const physical_address = read64(file, offset + 24);
        const file_size = read64(file, offset + 32);
        const memory_size = read64(file, offset + 40);
        const alignment = read64(file, offset + 48);
        if (kind != pt_load) return null;
        if (physical_address != 0 or flags == 0 or (flags & ~(pf_read | pf_write | pf_execute)) != 0) return null;
        if ((flags & pf_read) == 0 or (flags & pf_write) != 0 and (flags & pf_execute) != 0) return null;
        if (file_size == 0 or memory_size < file_size or memory_size == 0) return null;
        if (alignment != page_size or file_offset % page_size != virtual_address % page_size) return null;
        if (!isCanonicalUser(virtual_address)) return null;
        const memory_end = std.math.add(u64, virtual_address, memory_size) catch return null;
        if (memory_end <= virtual_address or !isCanonicalUser(memory_end - 1)) return null;
        const file_end = std.math.add(u64, file_offset, file_size) catch return null;
        if (file_end > file.len) return null;
        if (result.load_count != 0 and virtual_address < previous_end) return null;
        previous_end = alignForward(memory_end, page_size) orelse return null;
        if (result.load_count >= result.load_segments.len) return null;
        result.load_segments[result.load_count] = .{
            .file_offset = file_offset,
            .virtual_address = virtual_address,
            .file_size = file_size,
            .memory_size = memory_size,
            .alignment = alignment,
            .flags = flags,
        };
        if ((flags & pf_execute) != 0 and entry >= virtual_address and entry < memory_end) {
            entry_in_executable = true;
        }
        result.load_count += 1;
    }
    if (result.load_count != program_header_count or !entry_in_executable) return null;
    return result;
}

pub fn fnv1a64(bytes: []const u8) u64 {
    var value: u64 = 0xCBF2_9CE4_8422_2325;
    for (bytes) |byte| {
        value ^= byte;
        value *%= 0x0000_0100_0000_01B3;
    }
    return value;
}

fn isCanonicalUser(address: u64) bool {
    return address <= 0x0000_7FFF_FFFF_FFFF;
}

fn alignForward(value: u64, alignment: u64) ?u64 {
    if (alignment == 0 or (alignment & (alignment - 1)) != 0) return null;
    const adjusted = std.math.add(u64, value, alignment - 1) catch return null;
    return adjusted & ~(alignment - 1);
}

fn read16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn read32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, read16(bytes, offset)) | (@as(u32, read16(bytes, offset + 2)) << 16);
}

fn read64(bytes: []const u8, offset: usize) u64 {
    return @as(u64, read32(bytes, offset)) | (@as(u64, read32(bytes, offset + 4)) << 32);
}
