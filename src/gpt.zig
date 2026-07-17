const std = @import("std");

pub const signature = "EFI PART".*;
pub const minimum_header_size: u32 = 92;
pub const minimum_entry_size: u32 = 128;
pub const maximum_entry_size: u32 = 512;
pub const maximum_partition_entries: u32 = 4096;

pub const efi_system_partition_guid = [16]u8{
    0x28, 0x73, 0x2A, 0xC1,
    0x1F, 0xF8, 0xD2, 0x11,
    0xBA, 0x4B, 0x00, 0xA0,
    0xC9, 0x3E, 0xC9, 0x3B,
};

pub const Header = struct {
    revision: u32,
    header_size: u32,
    header_crc32: u32,
    current_lba: u64,
    backup_lba: u64,
    first_usable_lba: u64,
    last_usable_lba: u64,
    disk_guid: [16]u8,
    partition_entry_lba: u64,
    partition_entry_count: u32,
    partition_entry_size: u32,
    partition_array_crc32: u32,
    partition_array_bytes: u64,
};

pub const PartitionEntry = struct {
    index: u32,
    type_guid: [16]u8,
    unique_guid: [16]u8,
    first_lba: u64,
    last_lba: u64,
    attributes: u64,
    name: [73]u8,

    pub fn isUnused(self: PartitionEntry) bool {
        return allZero(&self.type_guid);
    }

    pub fn isEfiSystemPartition(self: PartitionEntry) bool {
        return std.mem.eql(u8, &self.type_guid, &efi_system_partition_guid);
    }

    pub fn sectorCount(self: PartitionEntry) ?u64 {
        if (self.last_lba < self.first_lba) return null;
        return self.last_lba - self.first_lba + 1;
    }

    pub fn nameSlice(self: *const PartitionEntry) []const u8 {
        for (self.name, 0..) |character, index| {
            if (character == 0) return self.name[0..index];
        }
        return &self.name;
    }
};

pub fn parseHeader(sector: []const u8, namespace_lbas: u64) ?Header {
    if (sector.len < minimum_header_size or namespace_lbas < 3) return null;
    if (!std.mem.eql(u8, sector[0..8], &signature)) return null;

    const revision = read32(sector, 8);
    const header_size = read32(sector, 12);
    const header_crc32 = read32(sector, 16);
    if (revision < 0x0001_0000) return null;
    if (header_size < minimum_header_size or header_size > sector.len) return null;
    if (read32(sector, 20) != 0) return null;
    if (crc32WithZeroRange(sector[0..header_size], 16, 4) != header_crc32) return null;

    const current_lba = read64(sector, 24);
    const backup_lba = read64(sector, 32);
    const first_usable_lba = read64(sector, 40);
    const last_usable_lba = read64(sector, 48);
    const partition_entry_lba = read64(sector, 72);
    const partition_entry_count = read32(sector, 80);
    const partition_entry_size = read32(sector, 84);
    const partition_array_crc32 = read32(sector, 88);

    if (current_lba == 0 or current_lba >= namespace_lbas) return null;
    if (backup_lba == current_lba or backup_lba >= namespace_lbas) return null;
    if (first_usable_lba > last_usable_lba or last_usable_lba >= namespace_lbas) return null;
    if (partition_entry_lba == 0 or partition_entry_lba >= namespace_lbas) return null;
    if (partition_entry_count == 0 or partition_entry_count > maximum_partition_entries) return null;
    if (partition_entry_size < minimum_entry_size or partition_entry_size > maximum_entry_size) return null;
    if (partition_entry_size % 8 != 0) return null;

    const partition_array_bytes = std.math.mul(u64, partition_entry_count, partition_entry_size) catch return null;
    if (partition_array_bytes == 0) return null;

    var disk_guid: [16]u8 = undefined;
    @memcpy(&disk_guid, sector[56..72]);
    if (allZero(&disk_guid)) return null;

    return .{
        .revision = revision,
        .header_size = header_size,
        .header_crc32 = header_crc32,
        .current_lba = current_lba,
        .backup_lba = backup_lba,
        .first_usable_lba = first_usable_lba,
        .last_usable_lba = last_usable_lba,
        .disk_guid = disk_guid,
        .partition_entry_lba = partition_entry_lba,
        .partition_entry_count = partition_entry_count,
        .partition_entry_size = partition_entry_size,
        .partition_array_crc32 = partition_array_crc32,
        .partition_array_bytes = partition_array_bytes,
    };
}

pub fn parsePartitionEntry(bytes: []const u8, entry_size: u32, index: u32) ?PartitionEntry {
    if (entry_size < minimum_entry_size or entry_size > bytes.len) return null;
    var result = PartitionEntry{
        .index = index,
        .type_guid = undefined,
        .unique_guid = undefined,
        .first_lba = read64(bytes, 32),
        .last_lba = read64(bytes, 40),
        .attributes = read64(bytes, 48),
        .name = @splat(0),
    };
    @memcpy(&result.type_guid, bytes[0..16]);
    @memcpy(&result.unique_guid, bytes[16..32]);
    if (result.isUnused()) return result;
    if (allZero(&result.unique_guid)) return null;
    if (result.last_lba < result.first_lba) return null;

    const utf16_bytes = @min(@as(usize, entry_size) - 56, 72);
    var input_offset: usize = 0;
    var output_offset: usize = 0;
    while (input_offset + 1 < utf16_bytes and output_offset + 1 < result.name.len) : (input_offset += 2) {
        const code_unit = read16(bytes, 56 + input_offset);
        if (code_unit == 0) break;
        result.name[output_offset] = if (code_unit >= 0x20 and code_unit <= 0x7E)
            @intCast(code_unit)
        else
            '?';
        output_offset += 1;
    }
    return result;
}

pub fn validatePartitionBounds(header: Header, entry: PartitionEntry) bool {
    if (entry.isUnused()) return false;
    return entry.first_lba >= header.first_usable_lba and
        entry.last_lba <= header.last_usable_lba and
        entry.first_lba <= entry.last_lba;
}

pub fn crc32Begin() u32 {
    return 0xFFFF_FFFF;
}

pub fn crc32Update(state: u32, bytes: []const u8) u32 {
    var crc = state;
    for (bytes) |byte| {
        crc ^= byte;
        var bit: u4 = 0;
        while (bit < 8) : (bit += 1) {
            const mask: u32 = 0 -% (crc & 1);
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask);
        }
    }
    return crc;
}

pub fn crc32Finish(state: u32) u32 {
    return ~state;
}

pub fn crc32(bytes: []const u8) u32 {
    return crc32Finish(crc32Update(crc32Begin(), bytes));
}

fn crc32WithZeroRange(bytes: []const u8, zero_offset: usize, zero_length: usize) u32 {
    if (zero_offset > bytes.len or zero_length > bytes.len - zero_offset) return 0;
    var state = crc32Begin();
    state = crc32Update(state, bytes[0..zero_offset]);
    var index: usize = 0;
    while (index < zero_length) : (index += 1) {
        const zero = [_]u8{0};
        state = crc32Update(state, &zero);
    }
    state = crc32Update(state, bytes[zero_offset + zero_length ..]);
    return crc32Finish(state);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
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
