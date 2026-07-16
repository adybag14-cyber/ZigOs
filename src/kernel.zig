const std = @import("std");
const boot = @import("boot_info.zig");

const cc = std.os.uefi.cc;

extern fn zigos_debug_putc(character: u8) callconv(cc) void;
extern fn zigos_halt_forever() callconv(cc) noreturn;

pub fn enter(info: *const boot.BootInfo) callconv(cc) noreturn {
    debugWrite("\r\nExitBootServices succeeded.\r\n");
    debugWrite("ZigOs now owns execution without UEFI boot services.\r\n");
    debugWrite("Kernel stack: 0x");
    debugWriteHex64(@intCast(info.kernel_stack.base));
    debugWrite(" + ");
    debugWriteUsizeDecimal(info.kernel_stack.size);
    debugWrite(" bytes\r\n");

    debugWrite("Final memory descriptors: ");
    debugWriteUsizeDecimal(info.memory_map.descriptor_count);
    debugWrite("\r\nConventional memory: ");
    debugWriteU64Decimal(info.memory_map.conventional_pages * 4096);
    debugWrite(" bytes\r\nHighest physical address: 0x");
    debugWriteHex64(info.memory_map.highest_physical_address);
    debugWrite("\r\n");

    if (info.acpi_rsdp) |address| {
        debugWrite("ACPI RSDP retained at 0x");
        debugWriteHex64(@intCast(address));
        debugWrite("\r\n");
    } else {
        debugWrite("ACPI RSDP was not found.\r\n");
    }

    if (info.framebuffer) |framebuffer| {
        paintFramebuffer(framebuffer);
        debugWrite("Framebuffer retained and written directly at 0x");
        debugWriteHex64(@intCast(framebuffer.base));
        debugWrite("\r\n");
    } else {
        debugWrite("No writable framebuffer was retained.\r\n");
    }

    debugWrite("Milestone 0.2 reached: firmware handoff complete; kernel remains alive.\r\n");
    zigos_halt_forever();
}

fn paintFramebuffer(framebuffer: boot.FramebufferInfo) void {
    if (framebuffer.base == 0 or framebuffer.size < 4) return;
    if (framebuffer.pixel_format == 3) return;

    const rows: u32 = @min(framebuffer.height, 48);
    const columns: u32 = @min(framebuffer.width, framebuffer.pixels_per_scan_line);
    const maximum_pixels = framebuffer.size / @sizeOf(u32);
    const pixels: [*]volatile u32 = @ptrFromInt(framebuffer.base);

    var y: u32 = 0;
    while (y < rows) : (y += 1) {
        var x: u32 = 0;
        while (x < columns) : (x += 1) {
            const index = @as(usize, y) * @as(usize, framebuffer.pixels_per_scan_line) + @as(usize, x);
            if (index >= maximum_pixels) return;

            const red: u8 = @intCast(32 + ((x * 191) / @max(columns, 1)));
            const green: u8 = @intCast(24 + ((y * 160) / @max(rows, 1)));
            const blue: u8 = 112;
            pixels[index] = encodePixel(framebuffer, red, green, blue);
        }
    }
}

fn encodePixel(framebuffer: boot.FramebufferInfo, red: u8, green: u8, blue: u8) u32 {
    return switch (framebuffer.pixel_format) {
        0 => @as(u32, red) | (@as(u32, green) << 8) | (@as(u32, blue) << 16),
        1 => @as(u32, blue) | (@as(u32, green) << 8) | (@as(u32, red) << 16),
        2 => channelToMask(red, framebuffer.red_mask) |
            channelToMask(green, framebuffer.green_mask) |
            channelToMask(blue, framebuffer.blue_mask),
        else => 0,
    };
}

fn channelToMask(value: u8, mask: u32) u32 {
    if (mask == 0) return 0;

    const shift: u5 = @intCast(@ctz(mask));
    const normalized_mask = mask >> shift;
    const width: u6 = @intCast(32 - @clz(normalized_mask));
    const maximum: u64 = (@as(u64, 1) << width) - 1;
    const scaled: u32 = @intCast((@as(u64, value) * maximum) / 255);
    return (scaled << shift) & mask;
}

fn debugWrite(text: []const u8) void {
    for (text) |character| zigos_debug_putc(character);
}

fn debugWriteHex64(value: u64) void {
    const digits = "0123456789ABCDEF";
    var text: [16]u8 = undefined;
    var shift: u6 = 60;

    for (&text) |*character| {
        const nibble: u4 = @truncate(value >> shift);
        character.* = digits[nibble];
        if (shift == 0) break;
        shift -= 4;
    }
    debugWrite(&text);
}

fn debugWriteUsizeDecimal(value: usize) void {
    debugWriteU64Decimal(@intCast(value));
}

fn debugWriteU64Decimal(initial_value: u64) void {
    if (initial_value == 0) {
        zigos_debug_putc('0');
        return;
    }

    var value = initial_value;
    var text: [20]u8 = undefined;
    var index = text.len;
    while (value != 0) {
        index -= 1;
        text[index] = @intCast('0' + (value % 10));
        value /= 10;
    }
    debugWrite(text[index..]);
}
