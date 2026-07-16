const std = @import("std");
const uefi = std.os.uefi;

extern fn zigos_cpuid_vendor(out: [*]u8) callconv(uefi.cc) void;
extern fn zigos_read_cr0() callconv(uefi.cc) u64;
extern fn zigos_read_cr3() callconv(uefi.cc) u64;
extern fn zigos_read_cr4() callconv(uefi.cc) u64;
extern fn zigos_debug_putc(character: u8) callconv(uefi.cc) void;

pub fn main() uefi.Status {
    const console = uefi.system_table.con_out orelse return .unsupported;

    console.clearScreen() catch {};
    writeAscii(console, "ZigOs\r\n");
    writeAscii(console, "Experimental x86-64 operating system in Zig + Assembly\r\n\r\n");

    var vendor: [13]u8 = @splat(0);
    zigos_cpuid_vendor(&vendor);

    writeAscii(console, "CPU vendor: ");
    writeAscii(console, vendor[0..12]);
    writeAscii(console, "\r\n");

    writeRegister(console, "CR0", zigos_read_cr0());
    writeRegister(console, "CR3", zigos_read_cr3());
    writeRegister(console, "CR4", zigos_read_cr4());

    writeAscii(console, "\r\nMilestone 0.1 reached: UEFI -> Zig -> x86-64 assembly -> hardware.\r\n");
    writeAscii(console, "Returning control to UEFI.\r\n");

    return .success;
}

fn writeRegister(console: *uefi.protocol.SimpleTextOutput, name: []const u8, value: u64) void {
    writeAscii(console, name);
    writeAscii(console, " = 0x");
    writeHex64(console, value);
    writeAscii(console, "\r\n");
}

fn writeHex64(console: *uefi.protocol.SimpleTextOutput, value: u64) void {
    const digits = "0123456789ABCDEF";
    var text: [16]u8 = undefined;
    var shift: u6 = 60;

    for (&text) |*character| {
        const nibble: u4 = @truncate(value >> shift);
        character.* = digits[nibble];
        if (shift == 0) break;
        shift -= 4;
    }

    writeAscii(console, &text);
}

fn writeAscii(console: *uefi.protocol.SimpleTextOutput, text: []const u8) void {
    for (text) |character| {
        zigos_debug_putc(character);
    }

    var utf16: [512]u16 = undefined;
    const count = @min(text.len, utf16.len - 1);

    for (text[0..count], 0..) |character, index| {
        utf16[index] = character;
    }
    utf16[count] = 0;

    const terminated: [*:0]const u16 = @ptrCast(&utf16);
    _ = console.outputString(terminated) catch return;
}
