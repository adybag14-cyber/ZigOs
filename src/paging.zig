const std = @import("std");
const memory = @import("memory.zig");

const cc = std.os.uefi.cc;

pub const higher_half_base: u64 = 0xFFFF_8000_0000_0000;
const higher_half_pml4_index: usize = 256;
pub const user_virtual_base: u64 = 0x0000_0080_0000_0000;
const user_pml4_index: usize = 1;

extern fn zigos_load_cr3(address: usize) callconv(cc) void;
extern fn zigos_read_cr3() callconv(cc) u64;

var active_pml4_address: usize = 0;

const entries_per_table: usize = 512;
const large_page_size: u64 = 2 * 1024 * 1024;
const present_writable: u64 = 0x003;
const present_user: u64 = 0x005;
const present_writable_user: u64 = 0x007;
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

    active_pml4_address = pml4_address;
    zigos_load_cr3(pml4_address);

    return .{
        .previous_cr3 = previous_cr3,
        .pml4_address = pml4_address,
        .table_pages = 6,
        .mapped_bytes = memory.four_gib,
        .higher_half_base = higher_half_base,
    };
}

pub const UserMapping = struct {
    code_virtual: usize,
    stack_virtual: usize,
    stack_top: usize,
    code_physical: usize,
    stack_physical: usize,
    table_pages: u64,
};

pub fn mapUserExperiment(
    allocator: *memory.FrameAllocator,
    code_physical: usize,
    stack_physical: usize,
) ?UserMapping {
    if (active_pml4_address == 0) return null;
    if (code_physical >= memory.four_gib or stack_physical >= memory.four_gib) return null;
    if ((code_physical & 0xFFF) != 0 or (stack_physical & 0xFFF) != 0) return null;

    const pml4 = tableAt(active_pml4_address);
    if (pml4[user_pml4_index] != 0) return null;

    const pdpt_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    const directory_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    const table_address = allocator.allocateBelow(memory.four_gib) orelse return null;
    clearTable(pdpt_address);
    clearTable(directory_address);
    clearTable(table_address);

    const pdpt = tableAt(pdpt_address);
    const directory = tableAt(directory_address);
    const table = tableAt(table_address);
    pml4[user_pml4_index] = @as(u64, @intCast(pdpt_address)) | present_writable_user;
    pdpt[0] = @as(u64, @intCast(directory_address)) | present_writable_user;
    directory[0] = @as(u64, @intCast(table_address)) | present_writable_user;
    table[0] = @as(u64, @intCast(code_physical)) | present_user;
    table[1] = @as(u64, @intCast(stack_physical)) | present_writable_user;

    zigos_load_cr3(active_pml4_address);

    const code_virtual: usize = @intCast(user_virtual_base);
    const stack_virtual = code_virtual + @as(usize, @intCast(memory.page_size));
    return .{
        .code_virtual = code_virtual,
        .stack_virtual = stack_virtual,
        .stack_top = stack_virtual + @as(usize, @intCast(memory.page_size)) - 16,
        .code_physical = code_physical,
        .stack_physical = stack_physical,
        .table_pages = 3,
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
