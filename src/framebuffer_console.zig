const std = @import("std");
const boot = @import("boot_info.zig");

const glyph_width: usize = 5;
const glyph_height: usize = 7;
const glyph_spacing: usize = 1;
const line_spacing: usize = 3;
const scale: usize = 2;
const margin_x: usize = 24;
const margin_y: usize = 24;
const fnv_offset: u64 = 0xCBF2_9CE4_8422_2325;
const fnv_prime: u64 = 0x0000_0100_0000_01B3;

pub const Report = struct {
    width: usize,
    height: usize,
    stride: usize,
    lines: usize,
    glyphs: usize,
    lit_pixels: usize,
    checksum: u64,
};

pub fn render(framebuffer: boot.FramebufferInfo) ?Report {
    if (framebuffer.base == 0 or framebuffer.pixel_format == 3) return null;

    const width: usize = @intCast(framebuffer.width);
    const height: usize = @intCast(framebuffer.height);
    const stride: usize = @intCast(framebuffer.pixels_per_scan_line);
    if (width == 0 or height == 0 or stride < width) return null;
    if (height > std.math.maxInt(usize) / stride) return null;
    const pixel_count = stride * height;
    if (pixel_count > std.math.maxInt(usize) / @sizeOf(u32)) return null;
    if (framebuffer.size < pixel_count * @sizeOf(u32)) return null;

    const background = encodePixel(framebuffer, 16, 24, 40);
    const foreground = encodePixel(framebuffer, 232, 238, 247);
    const accent = encodePixel(framebuffer, 120, 212, 255);
    const pixels: [*]volatile u32 = @ptrFromInt(framebuffer.base);

    var clear_index: usize = 0;
    while (clear_index < pixel_count) : (clear_index += 1) {
        pixels[clear_index] = background;
    }

    const lines = [_][]const u8{
        "ZigOs",
        "Experimental x86-64",
        "",
        "zigos> help",
        "commands: help cpu mem",
    };

    var glyph_count: usize = 0;
    var lit_pixels: usize = 0;
    var cursor_y = margin_y;
    for (lines, 0..) |line, line_index| {
        var cursor_x = margin_x;
        for (line) |character| {
            const color = if (line_index == 0) accent else foreground;
            lit_pixels += drawGlyph(
                pixels,
                width,
                height,
                stride,
                cursor_x,
                cursor_y,
                character,
                color,
            );
            glyph_count += 1;
            cursor_x += (glyph_width + glyph_spacing) * scale;
            if (cursor_x + glyph_width * scale >= width) break;
        }
        cursor_y += (glyph_height + line_spacing) * scale;
        if (cursor_y + glyph_height * scale >= height) break;
    }

    var checksum = fnv_offset;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            checksum ^= pixels[y * stride + x];
            checksum *%= fnv_prime;
        }
    }
    if (glyph_count == 0 or lit_pixels == 0 or checksum == 0) return null;

    return .{
        .width = width,
        .height = height,
        .stride = stride,
        .lines = lines.len,
        .glyphs = glyph_count,
        .lit_pixels = lit_pixels,
        .checksum = checksum,
    };
}

fn drawGlyph(
    pixels: [*]volatile u32,
    width: usize,
    height: usize,
    stride: usize,
    origin_x: usize,
    origin_y: usize,
    character: u8,
    color: u32,
) usize {
    const rows = glyph(character);
    var lit: usize = 0;
    for (rows, 0..) |row, row_index| {
        var column: usize = 0;
        while (column < glyph_width) : (column += 1) {
            const shift: u3 = @intCast(glyph_width - 1 - column);
            if (((row >> shift) & 1) == 0) continue;
            var dy: usize = 0;
            while (dy < scale) : (dy += 1) {
                const y = origin_y + row_index * scale + dy;
                if (y >= height) continue;
                var dx: usize = 0;
                while (dx < scale) : (dx += 1) {
                    const x = origin_x + column * scale + dx;
                    if (x >= width) continue;
                    pixels[y * stride + x] = color;
                    lit += 1;
                }
            }
        }
    }
    return lit;
}

fn glyph(character: u8) [glyph_height]u5 {
    const normalized = if (character >= 'a' and character <= 'z') character - 32 else character;
    return switch (normalized) {
        'A' => .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'B' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 },
        'C' => .{ 0b01111, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b01111 },
        'D' => .{ 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110 },
        'E' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 },
        'F' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 },
        'G' => .{ 0b01111, 0b10000, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111 },
        'H' => .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'I' => .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b11111 },
        'J' => .{ 0b00111, 0b00010, 0b00010, 0b00010, 0b10010, 0b10010, 0b01100 },
        'K' => .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 },
        'L' => .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 },
        'M' => .{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 },
        'N' => .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 },
        'O' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'P' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 },
        'Q' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 },
        'R' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 },
        'S' => .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 },
        'T' => .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 },
        'U' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'V' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 },
        'W' => .{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010 },
        'X' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001 },
        'Y' => .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100 },
        'Z' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 },
        '0' => .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 },
        '1' => .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        '2' => .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 },
        '3' => .{ 0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110 },
        '4' => .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 },
        '5' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b00001, 0b00001, 0b11110 },
        '6' => .{ 0b01110, 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 },
        '7' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 },
        '8' => .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 },
        '9' => .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b01110 },
        '>' => .{ 0b10000, 0b01000, 0b00100, 0b00010, 0b00100, 0b01000, 0b10000 },
        ':' => .{ 0b00000, 0b00100, 0b00100, 0b00000, 0b00100, 0b00100, 0b00000 },
        '-' => .{ 0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000 },
        ' ' => .{ 0, 0, 0, 0, 0, 0, 0 },
        else => .{ 0b11111, 0b10001, 0b00010, 0b00100, 0b00100, 0b00000, 0b00100 },
    };
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
