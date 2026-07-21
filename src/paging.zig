const std = @import("std");
const memory = @import("memory.zig");

const cc = std.os.uefi.cc;

pub const higher_half_base: u64 = 0xFFFF_8000_0000_0000;
const higher_half_pml4_index: usize = 256;
pub const user_virtual_base: u64 = 0x0000_0080_0000_0000;
const user_pml4_index: usize = 1;

extern fn zigos_load_cr3(address: usize) callconv(cc) void;
extern fn zigos_read_cr3() callconv(cc) u64;
extern fn zigos_cpu_has_nx() callconv(cc) u8;
extern fn zigos_read_msr(index: u32) callconv(cc) u64;
extern fn zigos_write_msr(index: u32, value: u64) callconv(cc) void;

var active_pml4_address: usize = 0;
var no_execute_enabled = false;

const entries_per_table: usize = 512;
const large_page_size: u64 = 2 * 1024 * 1024;
const present_writable: u64 = 0x003;
const present_user: u64 = 0x005;
const present_writable_user: u64 = 0x007;
const present_writable_large: u64 = 0x083;
const page_table_address_mask: u64 = 0x000F_FFFF_FFFF_F000;
const large_page_flag: u64 = 1 << 7;
const hardware_accessed_dirty_flags: u64 = (1 << 5) | (1 << 6);
const user_flag: u64 = 1 << 2;
const writable_flag: u64 = 1 << 1;
const present_flag: u64 = 1;
const no_execute_flag: u64 = @as(u64, 1) << 63;
const efer_msr: u32 = 0xC000_0080;
const efer_nxe: u64 = 1 << 11;

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

pub const IdentityMapping = struct {
    requested_base: u64,
    requested_size: u64,
    mapped_base: u64,
    mapped_bytes: u64,
    table_pages: u64,
};

pub fn mapIdentityMmio(
    allocator: *memory.FrameAllocator,
    requested_base: u64,
    requested_size: u64,
) ?IdentityMapping {
    if (active_pml4_address == 0 or requested_size == 0) return null;
    if (requested_base > std.math.maxInt(u64) - requested_size) return null;
    const requested_end = requested_base + requested_size;
    const mapped_base = alignBackward(requested_base, large_page_size);
    const mapped_end = alignForward(requested_end, large_page_size) orelse return null;
    if (mapped_end <= mapped_base) return null;

    const pml4 = tableAt(active_pml4_address);
    var table_pages: u64 = 0;
    var physical = mapped_base;
    while (physical < mapped_end) : (physical += large_page_size) {
        const pml4_index: usize = @intCast((physical >> 39) & 0x1FF);
        const pdpt_index: usize = @intCast((physical >> 30) & 0x1FF);
        const directory_index: usize = @intCast((physical >> 21) & 0x1FF);

        const pdpt_result = ensureTable(
            allocator,
            &pml4[pml4_index],
            present_writable,
        ) orelse return null;
        if (pdpt_result.allocated) table_pages += 1;
        const pdpt = tableAt(pdpt_result.address);

        const directory_result = ensureTable(
            allocator,
            &pdpt[pdpt_index],
            present_writable,
        ) orelse return null;
        if (directory_result.allocated) table_pages += 1;
        const directory = tableAt(directory_result.address);

        const expected = physical | present_writable_large;
        const current = directory[directory_index];
        if (current == 0) {
            directory[directory_index] = expected;
        } else if ((current & ~hardware_accessed_dirty_flags) != expected) {
            return null;
        }
    }

    zigos_load_cr3(active_pml4_address);
    return .{
        .requested_base = requested_base,
        .requested_size = requested_size,
        .mapped_base = mapped_base,
        .mapped_bytes = mapped_end - mapped_base,
        .table_pages = table_pages,
    };
}

pub fn isIdentityRangeMapped(requested_base: u64, requested_size: u64) bool {
    if (active_pml4_address == 0 or requested_size == 0) return false;
    if (requested_base > std.math.maxInt(u64) - requested_size) return false;
    const requested_end = requested_base + requested_size;
    const mapped_base = alignBackward(requested_base, large_page_size);
    const mapped_end = alignForward(requested_end, large_page_size) orelse return false;
    if (mapped_end <= mapped_base) return false;

    const pml4 = tableAt(active_pml4_address);
    var physical = mapped_base;
    while (physical < mapped_end) : (physical += large_page_size) {
        const pml4_index: usize = @intCast((physical >> 39) & 0x1FF);
        const pdpt_index: usize = @intCast((physical >> 30) & 0x1FF);
        const directory_index: usize = @intCast((physical >> 21) & 0x1FF);

        const pml4_entry = pml4[pml4_index];
        if ((pml4_entry & 1) == 0 or (pml4_entry & large_page_flag) != 0) return false;
        const pdpt = tableAt(@intCast(pml4_entry & page_table_address_mask));
        const pdpt_entry = pdpt[pdpt_index];
        if ((pdpt_entry & 1) == 0 or (pdpt_entry & large_page_flag) != 0) return false;
        const directory = tableAt(@intCast(pdpt_entry & page_table_address_mask));
        const expected = physical | present_writable_large;
        if ((directory[directory_index] & ~hardware_accessed_dirty_flags) != expected) return false;
    }
    return true;
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
    if (active_pml4_address == 0 or !no_execute_enabled) return null;
    if (code_physical >= memory.four_gib or stack_physical >= memory.four_gib) return null;
    if ((code_physical & 0xFFF) != 0 or (stack_physical & 0xFFF) != 0) return null;

    const pml4 = tableAt(active_pml4_address);
    var table_pages: u64 = 0;
    const pdpt_result = ensureTable(
        allocator,
        &pml4[user_pml4_index],
        present_writable_user,
    ) orelse return null;
    if (pdpt_result.allocated) table_pages += 1;
    const pdpt = tableAt(pdpt_result.address);

    const directory_result = ensureTable(
        allocator,
        &pdpt[0],
        present_writable_user,
    ) orelse return null;
    if (directory_result.allocated) table_pages += 1;
    const directory = tableAt(directory_result.address);

    const table_result = ensureTable(
        allocator,
        &directory[0],
        present_writable_user,
    ) orelse return null;
    if (table_result.allocated) table_pages += 1;
    const table = tableAt(table_result.address);
    if (table[0] != 0 or table[1] != 0) return null;
    table[0] = @as(u64, @intCast(code_physical)) | present_user;
    table[1] = @as(u64, @intCast(stack_physical)) | present_writable_user | no_execute_flag;

    zigos_load_cr3(active_pml4_address);

    const code_virtual: usize = @intCast(user_virtual_base);
    const stack_virtual = code_virtual + @as(usize, @intCast(memory.page_size));
    return .{
        .code_virtual = code_virtual,
        .stack_virtual = stack_virtual,
        .stack_top = stack_virtual + @as(usize, @intCast(memory.page_size)) - 16,
        .code_physical = code_physical,
        .stack_physical = stack_physical,
        .table_pages = table_pages,
    };
}

pub const UserPageInfo = struct {
    virtual_address: usize,
    physical_address: usize,
    writable: bool,
    executable: bool,
    accessed: bool,
    dirty: bool,
};

pub fn enableNoExecute() bool {
    if (zigos_cpu_has_nx() == 0) return false;
    const before = zigos_read_msr(efer_msr);
    zigos_write_msr(efer_msr, before | efer_nxe);
    no_execute_enabled = (zigos_read_msr(efer_msr) & efer_nxe) != 0;
    return no_execute_enabled;
}

pub fn noExecuteEnabled() bool {
    return no_execute_enabled;
}

pub fn mapUserPage(
    allocator: *memory.FrameAllocator,
    virtual_address: usize,
    physical_address: usize,
    writable: bool,
    executable: bool,
) bool {
    if (active_pml4_address == 0 or (virtual_address & 0xFFF) != 0 or (physical_address & 0xFFF) != 0) return false;
    if (@as(u64, @intCast(virtual_address)) > 0x0000_7FFF_FFFF_F000) return false;
    if (physical_address >= memory.four_gib) return false;
    if (!executable and !no_execute_enabled) return false;

    const pml4 = tableAt(active_pml4_address);
    const pml4_index = pageIndex(virtual_address, 39);
    const pdpt_index = pageIndex(virtual_address, 30);
    const directory_index = pageIndex(virtual_address, 21);
    const table_index = pageIndex(virtual_address, 12);

    const pdpt_result = ensureTable(allocator, &pml4[pml4_index], present_writable_user) orelse return false;
    const pdpt = tableAt(pdpt_result.address);
    const directory_result = ensureTable(allocator, &pdpt[pdpt_index], present_writable_user) orelse return false;
    const directory = tableAt(directory_result.address);
    const table_result = ensureTable(allocator, &directory[directory_index], present_writable_user) orelse return false;
    const table = tableAt(table_result.address);
    if (table[table_index] != 0) return false;

    var flags = present_user;
    if (writable) flags |= writable_flag;
    if (!executable) flags |= no_execute_flag;
    table[table_index] = @as(u64, @intCast(physical_address)) | flags;
    zigos_load_cr3(active_pml4_address);
    const info = inspectUserPage(virtual_address) orelse return false;
    return info.physical_address == physical_address and info.writable == writable and info.executable == executable;
}

pub fn unmapUserPage(virtual_address: usize, expected_physical: usize) bool {
    const entry = userPageEntry(virtual_address) orelse return false;
    const current = entry.*;
    if ((current & present_flag) == 0 or (current & user_flag) == 0) return false;
    if (@as(usize, @intCast(current & page_table_address_mask)) != expected_physical) return false;
    entry.* = 0;
    zigos_load_cr3(active_pml4_address);
    return inspectUserPage(virtual_address) == null;
}

pub fn inspectUserPage(virtual_address: usize) ?UserPageInfo {
    if ((virtual_address & 0xFFF) != 0) return null;
    const entry = userPageEntry(virtual_address) orelse return null;
    const value = entry.*;
    if ((value & present_flag) == 0 or (value & user_flag) == 0) return null;
    const physical: usize = @intCast(value & page_table_address_mask);
    if (physical == 0 or physical >= memory.four_gib) return null;
    return .{
        .virtual_address = virtual_address,
        .physical_address = physical,
        .writable = (value & writable_flag) != 0,
        .executable = !no_execute_enabled or (value & no_execute_flag) == 0,
        .accessed = (value & (1 << 5)) != 0,
        .dirty = (value & (1 << 6)) != 0,
    };
}

pub fn translateUserAddress(address: usize, require_write: bool, require_execute: bool) ?usize {
    const page_base = address & ~@as(usize, 0xFFF);
    const info = inspectUserPage(page_base) orelse return null;
    if (require_write and !info.writable) return null;
    if (require_execute and !info.executable) return null;
    return info.physical_address + (address & 0xFFF);
}

fn userPageEntry(virtual_address: usize) ?*volatile u64 {
    if (active_pml4_address == 0 or (virtual_address & 0xFFF) != 0) return null;
    if (@as(u64, @intCast(virtual_address)) > 0x0000_7FFF_FFFF_F000) return null;
    const pml4 = tableAt(active_pml4_address);
    const pml4_entry = pml4[pageIndex(virtual_address, 39)];
    if ((pml4_entry & present_flag) == 0 or (pml4_entry & user_flag) == 0 or (pml4_entry & large_page_flag) != 0) return null;
    const pdpt = tableAt(@intCast(pml4_entry & page_table_address_mask));
    const pdpt_entry = pdpt[pageIndex(virtual_address, 30)];
    if ((pdpt_entry & present_flag) == 0 or (pdpt_entry & user_flag) == 0 or (pdpt_entry & large_page_flag) != 0) return null;
    const directory = tableAt(@intCast(pdpt_entry & page_table_address_mask));
    const directory_entry = directory[pageIndex(virtual_address, 21)];
    if ((directory_entry & present_flag) == 0 or (directory_entry & user_flag) == 0 or (directory_entry & large_page_flag) != 0) return null;
    const table = tableAt(@intCast(directory_entry & page_table_address_mask));
    return &table[pageIndex(virtual_address, 12)];
}

fn pageIndex(address: usize, shift: u6) usize {
    return (address >> shift) & 0x1FF;
}

pub fn higherHalfAlias(physical_address: usize) ?usize {
    if (physical_address >= memory.four_gib) return null;
    return @intCast(higher_half_base + @as(u64, @intCast(physical_address)));
}

pub fn isHigherHalfAddress(address: usize) bool {
    return @as(u64, @intCast(address)) >= higher_half_base;
}

pub fn activePml4Address() ?usize {
    return if (active_pml4_address == 0) null else active_pml4_address;
}

pub fn currentCr3() u64 {
    return zigos_read_cr3();
}

const EnsuredTable = struct {
    address: usize,
    allocated: bool,
};

fn ensureTable(
    allocator: *memory.FrameAllocator,
    entry: *volatile u64,
    flags: u64,
) ?EnsuredTable {
    const current = entry.*;
    if (current == 0) {
        const address = allocator.allocateBelow(memory.four_gib) orelse return null;
        clearTable(address);
        entry.* = @as(u64, @intCast(address)) | flags;
        return .{ .address = address, .allocated = true };
    }
    if ((current & large_page_flag) != 0 or (current & 1) == 0) return null;
    entry.* = current | flags;
    const address_u64 = current & page_table_address_mask;
    if (address_u64 == 0 or address_u64 >= memory.four_gib) return null;
    return .{ .address = @intCast(address_u64), .allocated = false };
}

fn alignBackward(value: u64, alignment: u64) u64 {
    return value & ~(alignment - 1);
}

fn alignForward(value: u64, alignment: u64) ?u64 {
    if (value > std.math.maxInt(u64) - (alignment - 1)) return null;
    return (value + alignment - 1) & ~(alignment - 1);
}

fn clearTable(address: usize) void {
    const table = tableAt(address);
    for (0..entries_per_table) |index| table[index] = 0;
}

fn tableAt(address: usize) [*]volatile u64 {
    return @ptrFromInt(address);
}
