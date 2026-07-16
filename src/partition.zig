pub const Partition = struct {
    index: u8,
    bootable: bool,
    partition_type: u8,
    first_lba: u32,
    sector_count: u32,
};

pub const Mbr = struct {
    disk_signature: u32,
    partitions: [4]Partition,
    populated_count: u8,
};

pub fn parseMbr(sector: []const u8) ?Mbr {
    if (sector.len < 512) return null;
    if (read16(sector, 510) != 0xAA55) return null;

    var result = Mbr{
        .disk_signature = read32(sector, 440),
        .partitions = undefined,
        .populated_count = 0,
    };

    var index: usize = 0;
    while (index < result.partitions.len) : (index += 1) {
        const offset = 446 + index * 16;
        const partition = Partition{
            .index = @intCast(index),
            .bootable = sector[offset] == 0x80,
            .partition_type = sector[offset + 4],
            .first_lba = read32(sector, offset + 8),
            .sector_count = read32(sector, offset + 12),
        };
        if (partition.partition_type != 0 and partition.sector_count != 0) {
            result.populated_count += 1;
        }
        result.partitions[index] = partition;
    }

    return result;
}

pub fn firstUsablePartition(mbr: Mbr) ?Partition {
    for (mbr.partitions) |partition| {
        if (partition.partition_type != 0 and partition.sector_count != 0) return partition;
    }
    return null;
}

fn read16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn read32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, read16(bytes, offset)) | (@as(u32, read16(bytes, offset + 2)) << 16);
}
