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
    columns: usize,
    rows: usize,
    cursor_column: usize,
    cursor_row: usize,
    lines: usize,
    glyphs: usize,
    writes: usize,
    newlines: usize,
    backspaces: usize,
    scrolls: usize,
    resets: usize,
    lit_pixels: usize,
    checksum: u64,
};

pub const Console = struct {
    framebuffer: boot.FramebufferInfo,
    pixels: [*]volatile u32,
    width: usize,
    height: usize,
    stride: usize,
    pixel_count: usize,
    columns: usize,
    rows: usize,
    background: u32,
    foreground: u32,
    accent: u32,
    cursor_column: usize,
    cursor_row: usize,
    lines: usize,
    glyphs: usize,
    writes: usize,
    newlines: usize,
    backspaces: usize,
    scrolls: usize,
    resets: usize,

    pub fn init(framebuffer: boot.FramebufferInfo) ?Console {
        if (framebuffer.base == 0 or framebuffer.pixel_format == 3) return null;

        const width: usize = @intCast(framebuffer.width);
        const height: usize = @intCast(framebuffer.height);
        const stride: usize = @intCast(framebuffer.pixels_per_scan_line);
        if (width == 0 or height == 0 or stride < width) return null;
        if (height > std.math.maxInt(usize) / stride) return null;
        const pixel_count = stride * height;
        if (pixel_count > std.math.maxInt(usize) / @sizeOf(u32)) return null;
        if (framebuffer.size < pixel_count * @sizeOf(u32)) return null;
        if (width <= margin_x * 2 or height <= margin_y * 2) return null;

        const cell_width = (glyph_width + glyph_spacing) * scale;
        const cell_height = (glyph_height + line_spacing) * scale;
        const columns = (width - margin_x * 2) / cell_width;
        const rows = (height - margin_y * 2) / cell_height;
        if (columns == 0 or rows == 0) return null;

        var console = Console{
            .framebuffer = framebuffer,
            .pixels = @ptrFromInt(framebuffer.base),
            .width = width,
            .height = height,
            .stride = stride,
            .pixel_count = pixel_count,
            .columns = columns,
            .rows = rows,
            .background = encodePixel(framebuffer, 16, 24, 40),
            .foreground = encodePixel(framebuffer, 232, 238, 247),
            .accent = encodePixel(framebuffer, 120, 212, 255),
            .cursor_column = 0,
            .cursor_row = 0,
            .lines = 1,
            .glyphs = 0,
            .writes = 0,
            .newlines = 0,
            .backspaces = 0,
            .scrolls = 0,
            .resets = 0,
        };
        console.clearPixels();
        console.writeAccent("ZigOs");
        console.put('\n');
        console.write("Experimental x86-64");
        console.put('\n');
        console.put('\n');
        console.write("zigos> ");
        return console;
    }

    pub fn reset(self: *Console) void {
        self.clearPixels();
        self.cursor_column = 0;
        self.cursor_row = 0;
        self.lines = 1;
        self.glyphs = 0;
        self.writes = 0;
        self.newlines = 0;
        self.backspaces = 0;
        self.scrolls = 0;
        self.resets += 1;
    }

    pub fn write(self: *Console, text: []const u8) void {
        self.writeColor(text, self.foreground);
    }

    pub fn writeAccent(self: *Console, text: []const u8) void {
        self.writeColor(text, self.accent);
    }

    pub fn put(self: *Console, character: u8) void {
        switch (character) {
            '\r' => return,
            '\n' => {
                self.newlines += 1;
                self.advanceLine();
                return;
            },
            0x08, 0x7F => {
                self.erasePreviousCell();
                return;
            },
            else => {},
        }
        if (character < 0x20 or character > 0x7E) return;
        self.putColor(character, self.foreground);
    }

    pub fn report(self: *const Console) Report {
        var checksum = fnv_offset;
        var lit_pixels: usize = 0;
        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var x: usize = 0;
            while (x < self.width) : (x += 1) {
                const value = self.pixels[y * self.stride + x];
                if (value != self.background) lit_pixels += 1;
                checksum ^= value;
                checksum *%= fnv_prime;
            }
        }
        return .{
            .width = self.width,
            .height = self.height,
            .stride = self.stride,
            .columns = self.columns,
            .rows = self.rows,
            .cursor_column = self.cursor_column,
            .cursor_row = self.cursor_row,
            .lines = self.lines,
            .glyphs = self.glyphs,
            .writes = self.writes,
            .newlines = self.newlines,
            .backspaces = self.backspaces,
            .scrolls = self.scrolls,
            .resets = self.resets,
            .lit_pixels = lit_pixels,
            .checksum = checksum,
        };
    }

    fn clearPixels(self: *Console) void {
        var index: usize = 0;
        while (index < self.pixel_count) : (index += 1) {
            self.pixels[index] = self.background;
        }
    }

    fn writeColor(self: *Console, text: []const u8, color: u32) void {
        for (text) |character| {
            if (character == '\n') {
                self.newlines += 1;
                self.advanceLine();
            } else if (character >= 0x20 and character <= 0x7E) {
                self.putColor(character, color);
            }
        }
    }

    fn putColor(self: *Console, character: u8, color: u32) void {
        if (self.cursor_column >= self.columns) {
            self.newlines += 1;
            self.advanceLine();
        }
        const origin_x = margin_x + self.cursor_column * (glyph_width + glyph_spacing) * scale;
        const origin_y = margin_y + self.cursor_row * (glyph_height + line_spacing) * scale;
        _ = drawGlyph(
            self.pixels,
            self.width,
            self.height,
            self.stride,
            origin_x,
            origin_y,
            character,
            color,
        );
        self.cursor_column += 1;
        self.glyphs += 1;
        self.writes += 1;
    }

    fn advanceLine(self: *Console) void {
        self.cursor_column = 0;
        self.cursor_row += 1;
        self.lines += 1;
        if (self.cursor_row >= self.rows) self.scroll();
    }

    fn erasePreviousCell(self: *Console) void {
        if (self.cursor_column == 0) return;
        self.cursor_column -= 1;
        const cell_width = (glyph_width + glyph_spacing) * scale;
        const cell_height = (glyph_height + line_spacing) * scale;
        const origin_x = margin_x + self.cursor_column * cell_width;
        const origin_y = margin_y + self.cursor_row * cell_height;
        self.fillRectangle(origin_x, origin_y, cell_width, cell_height, self.background);
        self.backspaces += 1;
    }

    fn scroll(self: *Console) void {
        const cell_height = (glyph_height + line_spacing) * scale;
        const top = margin_y;
        const bottom = margin_y + self.rows * cell_height;
        var y = top;
        while (y + cell_height < bottom) : (y += 1) {
            var x = margin_x;
            while (x < self.width - margin_x) : (x += 1) {
                self.pixels[y * self.stride + x] = self.pixels[(y + cell_height) * self.stride + x];
            }
        }
        self.fillRectangle(
            margin_x,
            bottom - cell_height,
            self.width - margin_x * 2,
            cell_height,
            self.background,
        );
        self.cursor_row = self.rows - 1;
        self.scrolls += 1;
    }

    fn fillRectangle(self: *Console, origin_x: usize, origin_y: usize, width: usize, height: usize, color: u32) void {
        var y: usize = 0;
        while (y < height and origin_y + y < self.height) : (y += 1) {
            var x: usize = 0;
            while (x < width and origin_x + x < self.width) : (x += 1) {
                self.pixels[(origin_y + y) * self.stride + origin_x + x] = color;
            }
        }
    }
};

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
