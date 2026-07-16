const std = @import("std");
const memory = @import("memory.zig");

const cc = std.os.uefi.cc;

pub const higher_half_base: u64 = 0xFFFF_8000_0000_0000;
const higher_half_pml4_index: usize = 256;

extern fn zigos_load_cr3(address: usize) callconv(cc) void;
extern fn zigos_read_cr3() callconv(cc) u64;

const entries_per_table: usize = 512;
const large_page_size: u64 = 2 * 1024 * 1024;
const present_writable: u64 = 0x003;
const present_writable_large: u64 = 0x083;

pub const Installation = struct {
    previous_cr3: u64,
    pml4_address: usize,
    table_pages: u64,
    mapped_bytes: u64,
    higher_half_base: u64,
};

pub fn installFourGiBIdentityMap(allocator: *memory.FrameAllocator) ?Installation {
    const previous_cr3 = zigos_read_cr3();
    const pml4_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    const pdpt_address = allocator.allocateBelow(memory.four_gib) orelse return null;

    clearTable(pml4_address);
    clearTable(pdpt_address);

    const pml4 = tableAt(pml4_address);
    const pdpt = tableAt(pdpt_address);
    const pdpt_entry = @as(u64, @intCast(pdpt_address)) | present_writable;
    pml4[0] = pdpt_entry;
    pml4[higher_half_pml4_index] = pdpt_entry;

    var directory_index: usize = 0;
    while (directory_index < 4) : (directory_index += 1) {
        const directory_address = allocator.allocateBelow(memory.four_gib) orelse return null;
        clearTable(directory_address);
        pdpt[directory_index] = @as(u64, @intCast(directory_address)) | present_writable;

        const directory = tableAt(directory_address);
        var entry_index: usize = 0;
        while (entry_index < entries_per_table) : (entry_index += 1) {
            const large_page_index = directory_index * entries_per_table + entry_index;
            const physical_address = @as(u64, @intCast(large_page_index)) * large_page_size;
            directory[entry_index] = physical_address | present_writable_large;
        }
    }

    zigos_load_cr3(pml4_address);

    return .{
        .previous_cr3 = previous_cr3,
        .pml4_address = pml4_address,
        .table_pages = 6,
        .mapped_bytes = memory.four_gib,
        .higher_half_base = higher_half_base,
    };
}

pub fn higherHalfAlias(physical_address: usize) ?usize {
    if (physical_address >= memory.four_gib) return null;
    return @intCast(higher_half_base + @as(u64, @intCast(physical_address)));
}

pub fn isHigherHalfAddress(address: usize) bool {
    return @as(u64, @intCast(address)) >= higher_half_base;
}

pub fn currentCr3() u64 {
    return zigos_read_cr3();
}

fn clearTable(address: usize) void {
    const table = tableAt(address);
    for (0..entries_per_table) |index| table[index] = 0;
}

fn tableAt(address: usize) [*]volatile u64 {
    return @ptrFromInt(address);
}
