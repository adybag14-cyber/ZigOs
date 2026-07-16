const std = @import("std");
const acpi = @import("acpi.zig");
const memory = @import("memory.zig");

const cc = std.os.uefi.cc;

const ia32_apic_base_msr: u32 = 0x1B;
const apic_global_enable: u64 = 1 << 11;
const x2apic_enable: u64 = 1 << 10;
const apic_base_mask: u64 = 0x000F_FFFF_FFFF_F000;
const spurious_vector: u32 = 0xFF;
const software_enable: u32 = 1 << 8;

const xapic_id_offset: usize = 0x020;
const xapic_version_offset: usize = 0x030;
const xapic_task_priority_offset: usize = 0x080;
const xapic_spurious_offset: usize = 0x0F0;

const x2apic_id_msr: u32 = 0x802;
const x2apic_version_msr: u32 = 0x803;
const x2apic_task_priority_msr: u32 = 0x808;
const x2apic_spurious_msr: u32 = 0x80F;

extern fn zigos_read_msr(index: u32) callconv(cc) u64;
extern fn zigos_write_msr(index: u32, value: u64) callconv(cc) void;
extern fn zigos_out8(port: u16, value: u8) callconv(cc) void;
extern fn zigos_in8(port: u16) callconv(cc) u8;

pub const Information = struct {
    base_address: u64,
    apic_id: u32,
    version: u8,
    maximum_lvt_entry: u8,
    spurious_vector_register: u32,
    x2apic: bool,
    legacy_pic_masked: bool,
};

pub fn initialize(madt: acpi.MadtInfo) ?Information {
    var base_msr = zigos_read_msr(ia32_apic_base_msr);
    if ((base_msr & apic_global_enable) == 0) {
        zigos_write_msr(ia32_apic_base_msr, base_msr | apic_global_enable);
        base_msr = zigos_read_msr(ia32_apic_base_msr);
        if ((base_msr & apic_global_enable) == 0) return null;
    }

    const x2apic = (base_msr & x2apic_enable) != 0;
    const pic_masked = if (madt.legacy_pic_compatible) maskLegacyPic() else false;

    if (x2apic) {
        const raw_version: u32 = @truncate(zigos_read_msr(x2apic_version_msr));
        zigos_write_msr(x2apic_task_priority_msr, 0);
        const old_spurious: u32 = @truncate(zigos_read_msr(x2apic_spurious_msr));
        const new_spurious = (old_spurious & ~@as(u32, 0xFF)) | spurious_vector | software_enable;
        zigos_write_msr(x2apic_spurious_msr, new_spurious);
        const verified_spurious: u32 = @truncate(zigos_read_msr(x2apic_spurious_msr));
        if ((verified_spurious & (software_enable | 0xFF)) != (software_enable | spurious_vector)) return null;

        return .{
            .base_address = base_msr & apic_base_mask,
            .apic_id = @truncate(zigos_read_msr(x2apic_id_msr)),
            .version = @truncate(raw_version),
            .maximum_lvt_entry = @truncate(raw_version >> 16),
            .spurious_vector_register = verified_spurious,
            .x2apic = true,
            .legacy_pic_masked = pic_masked,
        };
    }

    const base_address = if (madt.local_apic_address != 0)
        madt.local_apic_address
    else
        base_msr & apic_base_mask;
    if (base_address >= memory.four_gib or (base_address & 0xFFF) != 0) return null;

    const base: usize = @intCast(base_address);
    const raw_id = readMmio(base, xapic_id_offset);
    const raw_version = readMmio(base, xapic_version_offset);
    writeMmio(base, xapic_task_priority_offset, 0);

    const old_spurious = readMmio(base, xapic_spurious_offset);
    const new_spurious = (old_spurious & ~@as(u32, 0xFF)) | spurious_vector | software_enable;
    writeMmio(base, xapic_spurious_offset, new_spurious);
    const verified_spurious = readMmio(base, xapic_spurious_offset);
    if ((verified_spurious & (software_enable | 0xFF)) != (software_enable | spurious_vector)) return null;

    return .{
        .base_address = base_address,
        .apic_id = raw_id >> 24,
        .version = @truncate(raw_version),
        .maximum_lvt_entry = @truncate(raw_version >> 16),
        .spurious_vector_register = verified_spurious,
        .x2apic = false,
        .legacy_pic_masked = pic_masked,
    };
}

fn maskLegacyPic() bool {
    zigos_out8(0x21, 0xFF);
    zigos_out8(0xA1, 0xFF);
    return zigos_in8(0x21) == 0xFF and zigos_in8(0xA1) == 0xFF;
}

fn readMmio(base: usize, offset: usize) u32 {
    const register: *volatile u32 = @ptrFromInt(base + offset);
    return register.*;
}

fn writeMmio(base: usize, offset: usize, value: u32) void {
    const register: *volatile u32 = @ptrFromInt(base + offset);
    register.* = value;
    _ = register.*;
}
