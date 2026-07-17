const std = @import("std");
const apic = @import("apic.zig");

const cc = std.os.uefi.cc;
const data_port: u16 = 0x60;
const status_command_port: u16 = 0x64;
const status_output_full: u8 = 1 << 0;
const status_input_full: u8 = 1 << 1;
const command_read_configuration: u8 = 0x20;
const command_write_configuration: u8 = 0x60;
const command_enable_first_port: u8 = 0xAE;
const command_write_keyboard_output: u8 = 0xD2;
const configuration_irq_first_port: u8 = 1 << 0;
const configuration_disable_first_port: u8 = 1 << 4;
const maximum_poll_count: usize = 1_000_000;

extern fn zigos_out8(port: u16, value: u8) callconv(cc) void;
extern fn zigos_in8(port: u16) callconv(cc) u8;
extern fn zigos_wait_for_interrupt() callconv(cc) void;

var interrupt_count: u32 = 0;
var last_scan_code: u32 = 0;

pub const Configuration = struct {
    original: u8,
    active: u8,
};

pub fn prepareKeyboardIrq() ?Configuration {
    flushOutput();
    writeCommand(command_enable_first_port) orelse return null;
    const original = readConfiguration() orelse return null;
    const active = (original | configuration_irq_first_port) & ~configuration_disable_first_port;
    writeConfiguration(active) orelse return null;
    const verified = readConfiguration() orelse return null;
    if (verified != active) return null;
    resetCapture();
    return .{
        .original = original,
        .active = active,
    };
}

pub fn restoreConfiguration(configuration: Configuration) bool {
    writeConfiguration(configuration.original) orelse return false;
    return (readConfiguration() orelse return false) == configuration.original;
}

pub fn injectKeyboardScanCode(scan_code: u8) bool {
    writeCommand(command_write_keyboard_output) orelse return false;
    waitInputEmpty() orelse return false;
    zigos_out8(data_port, scan_code);
    return true;
}

pub fn waitForInterrupt() void {
    zigos_wait_for_interrupt();
}

pub fn count() u32 {
    return @atomicLoad(u32, &interrupt_count, .acquire);
}

pub fn scanCode() u8 {
    return @truncate(@atomicLoad(u32, &last_scan_code, .acquire));
}

export fn zigos_ps2_keyboard_irq_handler() callconv(cc) void {
    const scan_code = zigos_in8(data_port);
    @atomicStore(u32, &last_scan_code, scan_code, .release);
    _ = @atomicRmw(u32, &interrupt_count, .Add, 1, .acq_rel);
    apic.acknowledgeInterrupt();
}

fn resetCapture() void {
    @atomicStore(u32, &interrupt_count, 0, .release);
    @atomicStore(u32, &last_scan_code, 0, .release);
}

fn readConfiguration() ?u8 {
    writeCommand(command_read_configuration) orelse return null;
    waitOutputFull() orelse return null;
    return zigos_in8(data_port);
}

fn writeConfiguration(value: u8) ?void {
    writeCommand(command_write_configuration) orelse return null;
    waitInputEmpty() orelse return null;
    zigos_out8(data_port, value);
    waitInputEmpty() orelse return null;
}

fn writeCommand(command: u8) ?void {
    waitInputEmpty() orelse return null;
    zigos_out8(status_command_port, command);
    waitInputEmpty() orelse return null;
}

fn waitInputEmpty() ?void {
    var polls: usize = 0;
    while ((zigos_in8(status_command_port) & status_input_full) != 0) : (polls += 1) {
        if (polls >= maximum_poll_count) return null;
    }
}

fn waitOutputFull() ?void {
    var polls: usize = 0;
    while ((zigos_in8(status_command_port) & status_output_full) == 0) : (polls += 1) {
        if (polls >= maximum_poll_count) return null;
    }
}

fn flushOutput() void {
    var polls: usize = 0;
    while ((zigos_in8(status_command_port) & status_output_full) != 0 and polls < 256) : (polls += 1) {
        _ = zigos_in8(data_port);
    }
}
