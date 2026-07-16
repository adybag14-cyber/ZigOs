const acpi = @import("acpi.zig");
const memory = @import("memory.zig");

const register_select_offset: usize = 0x00;
const register_window_offset: usize = 0x10;
const id_register: u32 = 0x00;
const version_register: u32 = 0x01;
const arbitration_register: u32 = 0x02;
const redirection_table_base: u32 = 0x10;
const redirection_mask: u32 = 1 << 16;

pub const Information = struct {
    base_address: usize,
    io_apic_id: u8,
    arbitration_id: u8,
    version: u8,
    redirection_entries: u16,
    global_system_interrupt_base: u32,
    first_redirection_low: u32,
    last_redirection_low: u32,
};

pub fn initialize(madt: acpi.MadtInfo, destination_apic_id: u32) ?Information {
    const address = madt.first_io_apic_address orelse return null;
    const gsi_base = madt.first_io_apic_gsi_base orelse return null;
    if (destination_apic_id > 0xFF) return null;
    if (address >= memory.four_gib or (address & 0xFFF) != 0) return null;

    const base: usize = address;
    const raw_id = readRegister(base, id_register);
    const raw_version = readRegister(base, version_register);
    const raw_arbitration = readRegister(base, arbitration_register);
    const maximum_redirection_entry: u8 = @truncate(raw_version >> 16);
    const entry_count: u16 = @as(u16, maximum_redirection_entry) + 1;
    if (entry_count == 0 or entry_count > 256) return null;

    var index: u16 = 0;
    while (index < entry_count) : (index += 1) {
        const low_register = redirection_table_base + @as(u32, index) * 2;
        const high_register = low_register + 1;
        const vector: u32 = 0x20 + (@as(u32, index) % 0xD0);
        writeRegister(base, high_register, destination_apic_id << 24);
        writeRegister(base, low_register, vector | redirection_mask);
    }

    const first_low = readRegister(base, redirection_table_base);
    const last_low = readRegister(base, redirection_table_base + (@as(u32, entry_count) - 1) * 2);
    if ((first_low & redirection_mask) == 0 or (last_low & redirection_mask) == 0) return null;

    return .{
        .base_address = base,
        .io_apic_id = @truncate(raw_id >> 24),
        .arbitration_id = @truncate(raw_arbitration >> 24),
        .version = @truncate(raw_version),
        .redirection_entries = entry_count,
        .global_system_interrupt_base = gsi_base,
        .first_redirection_low = first_low,
        .last_redirection_low = last_low,
    };
}

fn readRegister(base: usize, register_index: u32) u32 {
    const selector: *volatile u32 = @ptrFromInt(base + register_select_offset);
    const window: *volatile u32 = @ptrFromInt(base + register_window_offset);
    selector.* = register_index;
    return window.*;
}

fn writeRegister(base: usize, register_index: u32, value: u32) void {
    const selector: *volatile u32 = @ptrFromInt(base + register_select_offset);
    const window: *volatile u32 = @ptrFromInt(base + register_window_offset);
    selector.* = register_index;
    window.* = value;
    _ = window.*;
}
