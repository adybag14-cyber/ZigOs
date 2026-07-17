const acpi = @import("acpi.zig");
const memory = @import("memory.zig");

const register_select_offset: usize = 0x00;
const register_window_offset: usize = 0x10;
const id_register: u32 = 0x00;
const version_register: u32 = 0x01;
const arbitration_register: u32 = 0x02;
const redirection_table_base: u32 = 0x10;
const redirection_polarity_low: u32 = 1 << 13;
const redirection_trigger_level: u32 = 1 << 15;
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

pub const Route = struct {
    global_system_interrupt: u32,
    redirection_index: u16,
    vector: u8,
    destination_apic_id: u8,
    active_low: bool,
    level_triggered: bool,
    low_value: u32,
    high_value: u32,
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

pub fn route(
    information: Information,
    global_system_interrupt: u32,
    vector: u8,
    destination_apic_id: u32,
    madt_flags: u16,
) ?Route {
    if (vector < 0x20 or vector >= 0xF0 or destination_apic_id > 0xFF) return null;
    const redirection_index = redirectionIndex(information, global_system_interrupt) orelse return null;
    const polarity = madt_flags & 0x3;
    const trigger = (madt_flags >> 2) & 0x3;
    const active_low = switch (polarity) {
        0, 1 => false,
        3 => true,
        else => return null,
    };
    const level_triggered = switch (trigger) {
        0, 1 => false,
        3 => true,
        else => return null,
    };

    const low_register = redirection_table_base + @as(u32, redirection_index) * 2;
    const high_register = low_register + 1;
    const high_value = destination_apic_id << 24;
    var low_value: u32 = vector;
    if (active_low) low_value |= redirection_polarity_low;
    if (level_triggered) low_value |= redirection_trigger_level;

    writeRegister(information.base_address, low_register, low_value | redirection_mask);
    writeRegister(information.base_address, high_register, high_value);
    writeRegister(information.base_address, low_register, low_value);
    const verified_low = readRegister(information.base_address, low_register);
    const verified_high = readRegister(information.base_address, high_register);
    if (verified_low != low_value or verified_high != high_value) return null;

    return .{
        .global_system_interrupt = global_system_interrupt,
        .redirection_index = redirection_index,
        .vector = vector,
        .destination_apic_id = @intCast(destination_apic_id),
        .active_low = active_low,
        .level_triggered = level_triggered,
        .low_value = verified_low,
        .high_value = verified_high,
    };
}

pub fn mask(information: Information, global_system_interrupt: u32) bool {
    const redirection_index = redirectionIndex(information, global_system_interrupt) orelse return false;
    const low_register = redirection_table_base + @as(u32, redirection_index) * 2;
    const low_value = readRegister(information.base_address, low_register) | redirection_mask;
    writeRegister(information.base_address, low_register, low_value);
    return readRegister(information.base_address, low_register) == low_value;
}

fn redirectionIndex(information: Information, global_system_interrupt: u32) ?u16 {
    if (global_system_interrupt < information.global_system_interrupt_base) return null;
    const index = global_system_interrupt - information.global_system_interrupt_base;
    if (index >= information.redirection_entries) return null;
    return @intCast(index);
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
