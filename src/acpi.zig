const std = @import("std");
const memory = @import("memory.zig");

const maximum_table_length: usize = 1024 * 1024;

const RsdpV1 = extern struct {
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_address: u32 align(1),
};

const RsdpV2 = extern struct {
    first: RsdpV1,
    length: u32 align(1),
    xsdt_address: u64 align(1),
    extended_checksum: u8,
    reserved: [3]u8,
};

const SdtHeader = extern struct {
    signature: [4]u8,
    length: u32 align(1),
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32 align(1),
    creator_id: u32 align(1),
    creator_revision: u32 align(1),
};

const MadtHeader = extern struct {
    header: SdtHeader,
    local_apic_address: u32 align(1),
    flags: u32 align(1),
};

pub const RootKind = enum {
    rsdt,
    xsdt,
};

pub const maximum_processors: usize = 64;

pub const ProcessorInfo = struct {
    apic_id: u32,
    acpi_uid: u32,
    x2apic: bool,
};

pub const InterruptOverride = struct {
    bus_source: u8,
    irq_source: u8,
    global_system_interrupt: u32,
    flags: u16,
};
pub const MadtInfo = struct {
    address: usize,
    local_apic_address: u64,
    processor_count: u32,
    stored_processor_count: u8,
    processors: [maximum_processors]ProcessorInfo,
    io_apic_count: u32,
    first_io_apic_address: ?u32,
    first_io_apic_gsi_base: ?u32,
    interrupt_override_count: u32,
    stored_override_count: u8,
    overrides: [16]InterruptOverride,
    legacy_pic_compatible: bool,
};

pub const Discovery = struct {
    rsdp_address: usize,
    revision: u8,
    root_kind: RootKind,
    root_address: usize,
    valid_table_count: usize,
    invalid_table_count: usize,
    madt: ?MadtInfo,
    mcfg_address: ?usize,
    hpet_address: ?usize,
    facp_address: ?usize,
};

pub fn discover(rsdp_address: usize) ?Discovery {
    if (!rangeMapped(rsdp_address, @sizeOf(RsdpV1))) return null;
    const rsdp_v1: *const RsdpV1 = @ptrFromInt(rsdp_address);
    if (!std.mem.eql(u8, &rsdp_v1.signature, "RSD PTR ")) return null;
    if (!checksumValid(rsdp_address, @sizeOf(RsdpV1))) return null;

    var root_kind: RootKind = .rsdt;
    var root_address: usize = rsdp_v1.rsdt_address;

    if (rsdp_v1.revision >= 2) {
        if (!rangeMapped(rsdp_address, @sizeOf(RsdpV2))) return null;
        const rsdp_v2: *const RsdpV2 = @ptrFromInt(rsdp_address);
        const rsdp_length: usize = @intCast(rsdp_v2.length);
        if (rsdp_length < @sizeOf(RsdpV2) or rsdp_length > 4096) return null;
        if (!rangeMapped(rsdp_address, rsdp_length)) return null;
        if (!checksumValid(rsdp_address, rsdp_length)) return null;

        if (rsdp_v2.xsdt_address != 0 and rsdp_v2.xsdt_address < memory.four_gib) {
            root_kind = .xsdt;
            root_address = @intCast(rsdp_v2.xsdt_address);
        }
    }

    const root = validHeader(root_address) orelse return null;
    const expected_root = if (root_kind == .xsdt) "XSDT" else "RSDT";
    if (!std.mem.eql(u8, &root.signature, expected_root)) return null;

    const entry_size: usize = if (root_kind == .xsdt) 8 else 4;
    const root_length: usize = @intCast(root.length);
    const entry_bytes = root_length - @sizeOf(SdtHeader);
    if (entry_bytes % entry_size != 0) return null;
    const entry_count = entry_bytes / entry_size;
    const entries_address = root_address + @sizeOf(SdtHeader);

    var result = Discovery{
        .rsdp_address = rsdp_address,
        .revision = rsdp_v1.revision,
        .root_kind = root_kind,
        .root_address = root_address,
        .valid_table_count = 0,
        .invalid_table_count = 0,
        .madt = null,
        .mcfg_address = null,
        .hpet_address = null,
        .facp_address = null,
    };

    var index: usize = 0;
    while (index < entry_count) : (index += 1) {
        const table_address_u64 = if (root_kind == .xsdt)
            readU64(entries_address + index * entry_size)
        else
            readU32(entries_address + index * entry_size);

        if (table_address_u64 == 0 or table_address_u64 >= memory.four_gib) {
            result.invalid_table_count += 1;
            continue;
        }

        const table_address: usize = @intCast(table_address_u64);
        const table = validHeader(table_address) orelse {
            result.invalid_table_count += 1;
            continue;
        };
        result.valid_table_count += 1;

        if (std.mem.eql(u8, &table.signature, "APIC") and result.madt == null) {
            result.madt = parseMadt(table_address);
        } else if (std.mem.eql(u8, &table.signature, "MCFG") and result.mcfg_address == null) {
            result.mcfg_address = table_address;
        } else if (std.mem.eql(u8, &table.signature, "HPET") and result.hpet_address == null) {
            result.hpet_address = table_address;
        } else if (std.mem.eql(u8, &table.signature, "FACP") and result.facp_address == null) {
            result.facp_address = table_address;
        }
    }

    return result;
}

fn parseMadt(address: usize) ?MadtInfo {
    const header = validHeader(address) orelse return null;
    if (header.length < @sizeOf(MadtHeader)) return null;
    const madt: *const MadtHeader = @ptrFromInt(address);

    var info = MadtInfo{
        .address = address,
        .local_apic_address = madt.local_apic_address,
        .processor_count = 0,
        .stored_processor_count = 0,
        .processors = undefined,
        .io_apic_count = 0,
        .first_io_apic_address = null,
        .first_io_apic_gsi_base = null,
        .interrupt_override_count = 0,
        .stored_override_count = 0,
        .overrides = undefined,
        .legacy_pic_compatible = (madt.flags & 1) != 0,
    };

    var cursor = address + @sizeOf(MadtHeader);
    const end = address + @as(usize, @intCast(header.length));
    while (cursor + 2 <= end) {
        const entry_type = readU8(cursor);
        const entry_length: usize = readU8(cursor + 1);
        if (entry_length < 2 or cursor + entry_length > end) return null;

        switch (entry_type) {
            0 => if (entry_length >= 8) {
                const flags = readU32(cursor + 4);
                if ((flags & 0x3) != 0) {
                    info.processor_count += 1;
                    retainProcessor(&info, .{
                        .apic_id = readU8(cursor + 3),
                        .acpi_uid = readU8(cursor + 2),
                        .x2apic = false,
                    });
                }
            },
            1 => if (entry_length >= 12) {
                info.io_apic_count += 1;
                if (info.first_io_apic_address == null) {
                    info.first_io_apic_address = @truncate(readU32(cursor + 4));
                    info.first_io_apic_gsi_base = @truncate(readU32(cursor + 8));
                }
            },
            2 => if (entry_length >= 10) {
                info.interrupt_override_count += 1;
                if (info.stored_override_count < info.overrides.len) {
                    const override_index: usize = info.stored_override_count;
                    info.overrides[override_index] = .{
                        .bus_source = readU8(cursor + 2),
                        .irq_source = readU8(cursor + 3),
                        .global_system_interrupt = readU32(cursor + 4),
                        .flags = readU16(cursor + 8),
                    };
                    info.stored_override_count += 1;
                }
            },
            5 => if (entry_length >= 12) {
                info.local_apic_address = readU64(cursor + 4);
            },
            9 => if (entry_length >= 16) {
                const flags = readU32(cursor + 8);
                if ((flags & 0x3) != 0) {
                    info.processor_count += 1;
                    retainProcessor(&info, .{
                        .apic_id = readU32(cursor + 4),
                        .acpi_uid = readU32(cursor + 12),
                        .x2apic = true,
                    });
                }
            },
            else => {},
        }

        cursor += entry_length;
    }

    if (cursor != end) return null;
    return info;
}

fn retainProcessor(info: *MadtInfo, processor: ProcessorInfo) void {
    if (info.stored_processor_count >= info.processors.len) return;
    for (info.processors[0..info.stored_processor_count]) |existing| {
        if (existing.apic_id == processor.apic_id) return;
    }
    info.processors[info.stored_processor_count] = processor;
    info.stored_processor_count += 1;
}

fn validHeader(address: usize) ?*const SdtHeader {
    if (!rangeMapped(address, @sizeOf(SdtHeader))) return null;
    const header: *const SdtHeader = @ptrFromInt(address);
    const length: usize = @intCast(header.length);
    if (length < @sizeOf(SdtHeader) or length > maximum_table_length) return null;
    if (!rangeMapped(address, length)) return null;
    if (!checksumValid(address, length)) return null;
    return header;
}

fn rangeMapped(address: usize, length: usize) bool {
    const limit: usize = @intCast(memory.four_gib);
    return address < limit and length <= limit - address;
}

fn checksumValid(address: usize, length: usize) bool {
    const bytes: [*]const u8 = @ptrFromInt(address);
    var sum: u8 = 0;
    for (0..length) |index| sum +%= bytes[index];
    return sum == 0;
}

fn readU8(address: usize) u8 {
    const byte: *const u8 = @ptrFromInt(address);
    return byte.*;
}

fn readU16(address: usize) u16 {
    const bytes: [*]const u8 = @ptrFromInt(address);
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}
fn readU32(address: usize) u32 {
    const bytes: [*]const u8 = @ptrFromInt(address);
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn readU64(address: usize) u64 {
    return @as(u64, readU32(address)) | (@as(u64, readU32(address + 4)) << 32);
}

comptime {
    if (@sizeOf(RsdpV1) != 20) @compileError("ACPI 1.0 RSDP must be 20 bytes");
    if (@sizeOf(RsdpV2) != 36) @compileError("ACPI 2.0 RSDP must be 36 bytes");
    if (@sizeOf(SdtHeader) != 36) @compileError("ACPI SDT header must be 36 bytes");
    if (@sizeOf(MadtHeader) != 44) @compileError("ACPI MADT header must be 44 bytes");
}
