const std = @import("std");
const acpi = @import("acpi.zig");
const hpet = @import("hpet.zig");
const memory = @import("memory.zig");
const interrupt_context = @import("interrupt_context.zig");

const cc = std.os.uefi.cc;

const ia32_apic_base_msr: u32 = 0x1B;
const apic_global_enable: u64 = 1 << 11;
const x2apic_enable: u64 = 1 << 10;
const apic_base_mask: u64 = 0x000F_FFFF_FFFF_F000;
const spurious_vector: u32 = 0xFF;
const timer_vector: u32 = 0x40;
const software_enable: u32 = 1 << 8;
const timer_masked: u32 = 1 << 16;
const timer_periodic: u32 = 1 << 17;
const divide_by_16_encoding: u32 = 0x3;
const ipi_delivery_status: u32 = 1 << 12;
const init_delivery: u32 = 0b101 << 8;
const startup_delivery: u32 = 0b110 << 8;
const level_assert: u32 = 1 << 14;
const trigger_level: u32 = 1 << 15;

const xapic_id_offset: usize = 0x020;
const xapic_version_offset: usize = 0x030;
const xapic_task_priority_offset: usize = 0x080;
const xapic_eoi_offset: usize = 0x0B0;
const xapic_spurious_offset: usize = 0x0F0;
const xapic_lvt_timer_offset: usize = 0x320;
const xapic_initial_count_offset: usize = 0x380;
const xapic_current_count_offset: usize = 0x390;
const xapic_divide_configuration_offset: usize = 0x3E0;
const xapic_icr_low_offset: usize = 0x300;
const xapic_icr_high_offset: usize = 0x310;

const x2apic_id_msr: u32 = 0x802;
const x2apic_version_msr: u32 = 0x803;
const x2apic_task_priority_msr: u32 = 0x808;
const x2apic_eoi_msr: u32 = 0x80B;
const x2apic_spurious_msr: u32 = 0x80F;
const x2apic_lvt_timer_msr: u32 = 0x832;
const x2apic_initial_count_msr: u32 = 0x838;
const x2apic_current_count_msr: u32 = 0x839;
const x2apic_divide_configuration_msr: u32 = 0x83E;
const x2apic_icr_msr: u32 = 0x830;

extern fn zigos_read_msr(index: u32) callconv(cc) u64;
extern fn zigos_write_msr(index: u32, value: u64) callconv(cc) void;
extern fn zigos_out8(port: u16, value: u8) callconv(cc) void;
extern fn zigos_in8(port: u16) callconv(cc) u8;
extern fn zigos_wait_for_interrupt() callconv(cc) void;

pub const Information = struct {
    base_address: u64,
    apic_id: u32,
    version: u8,
    maximum_lvt_entry: u8,
    spurious_vector_register: u32,
    x2apic: bool,
    legacy_pic_masked: bool,
};

pub const TimerHook = *const fn (
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) callconv(cc) void;

pub const TimerResult = struct {
    ticks_per_second: u64,
    initial_count: u32,
    interrupt_count: u64,
    hpet_period_femtoseconds: u32,
    hpet_counter_64_bit: bool,
};

var active_x2apic: bool = false;
var active_base: usize = 0;
var timer_interrupt_count: u64 = 0;
var timer_hook: ?TimerHook = null;

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

        active_x2apic = true;
        active_base = 0;
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

    active_x2apic = false;
    active_base = base;
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

pub fn initializeCurrentProcessor() bool {
    if (active_x2apic) {
        zigos_write_msr(x2apic_task_priority_msr, 0);
        const old_spurious: u32 = @truncate(zigos_read_msr(x2apic_spurious_msr));
        const new_spurious = (old_spurious & ~@as(u32, 0xFF)) | spurious_vector | software_enable;
        zigos_write_msr(x2apic_spurious_msr, new_spurious);
        const verified: u32 = @truncate(zigos_read_msr(x2apic_spurious_msr));
        return (verified & (software_enable | 0xFF)) == (software_enable | spurious_vector);
    }
    if (active_base == 0) return false;
    writeMmio(active_base, xapic_task_priority_offset, 0);
    const old_spurious = readMmio(active_base, xapic_spurious_offset);
    const new_spurious = (old_spurious & ~@as(u32, 0xFF)) | spurious_vector | software_enable;
    writeMmio(active_base, xapic_spurious_offset, new_spurious);
    const verified = readMmio(active_base, xapic_spurious_offset);
    return (verified & (software_enable | 0xFF)) == (software_enable | spurious_vector);
}

pub fn currentId() u32 {
    return if (active_x2apic)
        @truncate(zigos_read_msr(x2apic_id_msr))
    else
        readMmio(active_base, xapic_id_offset) >> 24;
}

pub fn sendFixedIpi(destination_apic_id: u32, vector: u8) bool {
    if (vector < 0x20 or vector == spurious_vector) return false;
    if (!active_x2apic and destination_apic_id > 0xFF) return false;
    return sendIpi(destination_apic_id, level_assert | vector);
}

pub fn acknowledgeInterrupt() void {
    sendEoi();
}

pub fn sendInitSipi(destination_apic_id: u32, startup_vector: u8, reference: hpet.Device) bool {
    if (startup_vector == 0) return false;
    if (!active_x2apic and destination_apic_id > 0xFF) return false;

    if (!sendIpi(destination_apic_id, init_delivery | level_assert | trigger_level)) return false;
    if (!reference.waitNanoseconds(10_000_000)) return false;

    if (!sendIpi(destination_apic_id, startup_delivery | level_assert | startup_vector)) return false;
    if (!reference.waitNanoseconds(200_000)) return false;
    if (!sendIpi(destination_apic_id, startup_delivery | level_assert | startup_vector)) return false;
    return reference.waitNanoseconds(200_000);
}

pub fn calibrateAndTestTimer(reference: hpet.Device) ?TimerResult {
    const counter_before = reference.readCounter();
    if (!reference.waitNanoseconds(1_000_000)) return null;
    const counter_after = reference.readCounter();
    if (counter_after == counter_before) return null;

    writeTimerDivide(divide_by_16_encoding);
    writeTimerLvt(timer_vector | timer_masked);
    writeTimerInitial(std.math.maxInt(u32));
    if (!reference.waitNanoseconds(10_000_000)) return null;
    const current_count = readTimerCurrent();
    writeTimerInitial(0);

    const elapsed: u32 = std.math.maxInt(u32) - current_count;
    if (elapsed < 100) return null;
    const ticks_per_second = @as(u64, elapsed) * 100;
    const desired_count_u64 = @max(@as(u64, 1), ticks_per_second / 100);
    if (desired_count_u64 > std.math.maxInt(u32)) return null;
    const desired_count: u32 = @intCast(desired_count_u64);

    timer_interrupt_count = 0;
    writeTimerDivide(divide_by_16_encoding);
    writeTimerLvt(timer_vector);
    writeTimerInitial(desired_count);

    var wake_attempts: u8 = 0;
    while (timer_interrupt_count == 0 and wake_attempts < 8) : (wake_attempts += 1) {
        zigos_wait_for_interrupt();
    }

    writeTimerInitial(0);
    writeTimerLvt(timer_vector | timer_masked);
    if (timer_interrupt_count == 0) return null;

    return .{
        .ticks_per_second = ticks_per_second,
        .initial_count = desired_count,
        .interrupt_count = timer_interrupt_count,
        .hpet_period_femtoseconds = reference.period_femtoseconds,
        .hpet_counter_64_bit = reference.counter_64_bit,
    };
}

export fn zigos_apic_timer_handler(
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) callconv(cc) void {
    timer_interrupt_count +%= 1;
    if (timer_hook) |hook| hook(frame, fx_state);
    sendEoi();
}

pub fn setTimerHook(hook: ?TimerHook) void {
    timer_hook = hook;
}

pub fn startPeriodicTimer(ticks_per_second: u64, frequency_hz: u32) ?u32 {
    if (ticks_per_second == 0 or frequency_hz == 0) return null;
    const count_u64 = @max(@as(u64, 1), ticks_per_second / frequency_hz);
    if (count_u64 > std.math.maxInt(u32)) return null;
    const count: u32 = @intCast(count_u64);

    writeTimerDivide(divide_by_16_encoding);
    writeTimerLvt(timer_vector | timer_periodic);
    writeTimerInitial(count);
    return count;
}

pub fn stopTimer() void {
    writeTimerInitial(0);
    writeTimerLvt(timer_vector | timer_masked);
}

fn sendIpi(destination_apic_id: u32, command: u32) bool {
    if (!waitForIpiDelivery()) return false;

    if (active_x2apic) {
        const value = (@as(u64, destination_apic_id) << 32) | command;
        zigos_write_msr(x2apic_icr_msr, value);
    } else {
        writeMmio(active_base, xapic_icr_high_offset, destination_apic_id << 24);
        writeMmio(active_base, xapic_icr_low_offset, command);
    }
    return waitForIpiDelivery();
}

fn waitForIpiDelivery() bool {
    var iteration: usize = 0;
    while (iteration < 10_000_000) : (iteration += 1) {
        const low: u32 = if (active_x2apic)
            @truncate(zigos_read_msr(x2apic_icr_msr))
        else
            readMmio(active_base, xapic_icr_low_offset);
        if ((low & ipi_delivery_status) == 0) return true;
    }
    return false;
}

fn maskLegacyPic() bool {
    zigos_out8(0x21, 0xFF);
    zigos_out8(0xA1, 0xFF);
    return zigos_in8(0x21) == 0xFF and zigos_in8(0xA1) == 0xFF;
}

fn writeTimerDivide(value: u32) void {
    if (active_x2apic) {
        zigos_write_msr(x2apic_divide_configuration_msr, value);
    } else {
        writeMmio(active_base, xapic_divide_configuration_offset, value);
    }
}

fn writeTimerLvt(value: u32) void {
    if (active_x2apic) {
        zigos_write_msr(x2apic_lvt_timer_msr, value);
    } else {
        writeMmio(active_base, xapic_lvt_timer_offset, value);
    }
}

fn writeTimerInitial(value: u32) void {
    if (active_x2apic) {
        zigos_write_msr(x2apic_initial_count_msr, value);
    } else {
        writeMmio(active_base, xapic_initial_count_offset, value);
    }
}

fn readTimerCurrent() u32 {
    return if (active_x2apic)
        @truncate(zigos_read_msr(x2apic_current_count_msr))
    else
        readMmio(active_base, xapic_current_count_offset);
}

fn sendEoi() void {
    if (active_x2apic) {
        zigos_write_msr(x2apic_eoi_msr, 0);
    } else {
        writeMmio(active_base, xapic_eoi_offset, 0);
    }
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
