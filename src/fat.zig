const std = @import("std");

pub const Kind = enum {
    fat12,
    fat16,
    fat32,
};

pub const Volume = struct {
    kind: Kind,
    partition_lba: u64,
    bytes_per_sector: u16,
    sectors_per_cluster: u8,
    reserved_sector_count: u16,
    fat_count: u8,
    sectors_per_fat: u32,
    root_entry_count: u16,
    root_directory_sectors: u32,
    root_cluster: u32,
    total_sectors: u32,
    data_sectors: u32,
    cluster_count: u32,
    first_fat_lba: u64,
    first_data_lba: u64,
    root_directory_lba: u64,
    media_descriptor: u8,
    volume_id: u32,
    volume_label: [12]u8,
    filesystem_label: [9]u8,
};

pub fn parseBootSector(sector: []const u8, partition_lba: u64) ?Volume {
    if (sector.len < 512) return null;
    if (read16(sector, 510) != 0xAA55) return null;

    const bytes_per_sector = read16(sector, 11);
    const sectors_per_cluster = sector[13];
    const reserved_sector_count = read16(sector, 14);
    const fat_count = sector[16];
    const root_entry_count = read16(sector, 17);
    const total_sectors_16 = read16(sector, 19);
    const media_descriptor = sector[21];
    const sectors_per_fat_16 = read16(sector, 22);
    const total_sectors_32 = read32(sector, 32);

    if (!validBytesPerSector(bytes_per_sector)) return null;
    if (sectors_per_cluster == 0 or !std.math.isPowerOfTwo(sectors_per_cluster)) return null;
    if (reserved_sector_count == 0 or fat_count == 0) return null;

    const total_sectors: u32 = if (total_sectors_16 != 0) total_sectors_16 else total_sectors_32;
    const sectors_per_fat: u32 = if (sectors_per_fat_16 != 0) sectors_per_fat_16 else read32(sector, 36);
    if (total_sectors == 0 or sectors_per_fat == 0) return null;

    const root_directory_bytes = @as(u32, root_entry_count) * 32;
    const root_directory_sectors = (root_directory_bytes + bytes_per_sector - 1) / bytes_per_sector;
    const metadata_sectors = @as(u32, reserved_sector_count) +
        @as(u32, fat_count) * sectors_per_fat + root_directory_sectors;
    if (metadata_sectors >= total_sectors) return null;

    const data_sectors = total_sectors - metadata_sectors;
    const cluster_count = data_sectors / sectors_per_cluster;
    const kind: Kind = if (cluster_count < 4085)
        .fat12
    else if (cluster_count < 65525)
        .fat16
    else
        .fat32;

    if (kind == .fat32 and root_entry_count != 0) return null;
    const root_cluster: u32 = if (kind == .fat32) read32(sector, 44) else 0;
    if (kind == .fat32 and root_cluster < 2) return null;

    const first_fat_lba = partition_lba + reserved_sector_count;
    const first_data_lba = partition_lba + metadata_sectors;
    const root_directory_lba = if (kind == .fat32)
        first_data_lba + (@as(u64, root_cluster) - 2) * sectors_per_cluster
    else
        partition_lba + reserved_sector_count + @as(u64, fat_count) * sectors_per_fat;

    var volume_label: [12]u8 = @splat(0);
    var filesystem_label: [9]u8 = @splat(0);
    const volume_id: u32 = switch (kind) {
        .fat12, .fat16 => blk: {
            copyTrimmedAscii(&volume_label, sector[43..54]);
            copyTrimmedAscii(&filesystem_label, sector[54..62]);
            break :blk read32(sector, 39);
        },
        .fat32 => blk: {
            copyTrimmedAscii(&volume_label, sector[71..82]);
            copyTrimmedAscii(&filesystem_label, sector[82..90]);
            break :blk read32(sector, 67);
        },
    };

    return .{
        .kind = kind,
        .partition_lba = partition_lba,
        .bytes_per_sector = bytes_per_sector,
        .sectors_per_cluster = sectors_per_cluster,
        .reserved_sector_count = reserved_sector_count,
        .fat_count = fat_count,
        .sectors_per_fat = sectors_per_fat,
        .root_entry_count = root_entry_count,
        .root_directory_sectors = root_directory_sectors,
        .root_cluster = root_cluster,
        .total_sectors = total_sectors,
        .data_sectors = data_sectors,
        .cluster_count = cluster_count,
        .first_fat_lba = first_fat_lba,
        .first_data_lba = first_data_lba,
        .root_directory_lba = root_directory_lba,
        .media_descriptor = media_descriptor,
        .volume_id = volume_id,
        .volume_label = volume_label,
        .filesystem_label = filesystem_label,
    };
}

pub fn terminatedSlice(buffer: []const u8) []const u8 {
    for (buffer, 0..) |character, index| {
        if (character == 0) return buffer[0..index];
    }
    return buffer;
}

fn validBytesPerSector(value: u16) bool {
    return value == 512 or value == 1024 or value == 2048 or value == 4096;
}

fn copyTrimmedAscii(output: []u8, input: []const u8) void {
    @memset(output, 0);
    var end = input.len;
    while (end > 0 and (input[end - 1] == ' ' or input[end - 1] == 0)) end -= 1;
    const count = @min(end, output.len - 1);
    @memcpy(output[0..count], input[0..count]);
}

fn read16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn read32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, read16(bytes, offset)) | (@as(u32, read16(bytes, offset + 2)) << 16);
}
