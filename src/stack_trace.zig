const std = @import("std");

pub const maximum_frames: usize = 16;
pub const maximum_symbols: usize = 64;
pub const maximum_stack_ranges: usize = 64;
const maximum_symbol_displacement: usize = 0x4000;

pub const Frame = struct {
    address: usize,
    symbol_name: ?[]const u8,
    symbol_offset: usize,
};

pub const Report = struct {
    frames: [maximum_frames]Frame,
    frame_count: usize,
    symbolized_count: usize,
    stopped_on_invalid_frame: bool,

    pub fn empty() Report {
        return .{
            .frames = undefined,
            .frame_count = 0,
            .symbolized_count = 0,
            .stopped_on_invalid_frame = false,
        };
    }
};

const Symbol = struct {
    name: []const u8,
    address: usize,
};

const StackRange = struct {
    base: usize,
    end: usize,
};

var symbols: [maximum_symbols]Symbol = undefined;
var symbol_count: usize = 0;
var stack_ranges: [maximum_stack_ranges]StackRange = undefined;
var stack_range_count: usize = 0;

pub fn reset() void {
    symbol_count = 0;
    stack_range_count = 0;
}

pub fn registerSymbol(name: []const u8, address: usize) bool {
    if (name.len == 0 or address == 0) return false;
    for (symbols[0..symbol_count]) |symbol| {
        if (symbol.address == address) return std.mem.eql(u8, symbol.name, name);
    }
    if (symbol_count >= symbols.len) return false;
    symbols[symbol_count] = .{
        .name = name,
        .address = address,
    };
    symbol_count += 1;
    return true;
}

pub fn registerStackRange(base: usize, size: usize) bool {
    if (size < 2 * @sizeOf(usize) or base > std.math.maxInt(usize) - size) return false;
    const end = base + size;
    for (stack_ranges[0..stack_range_count]) |range| {
        if (range.base == base and range.end == end) return true;
    }
    if (stack_range_count >= stack_ranges.len) return false;
    stack_ranges[stack_range_count] = .{ .base = base, .end = end };
    stack_range_count += 1;
    return true;
}

pub fn capture(first_instruction: usize, initial_rbp: usize) Report {
    var report = Report.empty();
    appendFrame(&report, first_instruction);

    var frame_pointer = initial_rbp;
    while (report.frame_count < report.frames.len) {
        const range = containingStackRange(frame_pointer) orelse {
            report.stopped_on_invalid_frame = true;
            break;
        };
        if ((frame_pointer & (@alignOf(usize) - 1)) != 0 or
            frame_pointer > range.end - 2 * @sizeOf(usize))
        {
            report.stopped_on_invalid_frame = true;
            break;
        }

        const frame: *const [2]usize = @ptrFromInt(frame_pointer);
        const previous_rbp = frame[0];
        const return_address = frame[1];
        if (return_address == 0) break;
        appendFrame(&report, return_address);
        if (previous_rbp == 0) break;
        if (previous_rbp <= frame_pointer or previous_rbp >= range.end) {
            report.stopped_on_invalid_frame = true;
            break;
        }
        frame_pointer = previous_rbp;
    }
    return report;
}

pub fn frameHasSymbol(frame: Frame, expected: []const u8) bool {
    const name = frame.symbol_name orelse return false;
    return std.mem.eql(u8, name, expected);
}

fn appendFrame(report: *Report, address: usize) void {
    if (address == 0 or report.frame_count >= report.frames.len) return;
    const resolved = resolve(address);
    report.frames[report.frame_count] = .{
        .address = address,
        .symbol_name = if (resolved) |symbol| symbol.name else null,
        .symbol_offset = if (resolved) |symbol| address - symbol.address else 0,
    };
    if (resolved != null) report.symbolized_count += 1;
    report.frame_count += 1;
}

fn resolve(address: usize) ?Symbol {
    var best: ?Symbol = null;
    for (symbols[0..symbol_count]) |symbol| {
        if (address < symbol.address) continue;
        const displacement = address - symbol.address;
        if (displacement > maximum_symbol_displacement) continue;
        if (best == null or symbol.address > best.?.address) best = symbol;
    }
    return best;
}

fn containingStackRange(address: usize) ?StackRange {
    for (stack_ranges[0..stack_range_count]) |range| {
        if (address >= range.base and address < range.end) return range;
    }
    return null;
}
