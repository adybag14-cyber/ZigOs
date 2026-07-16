const std = @import("std");
const acpi = @import("acpi.zig");
const apic = @import("apic.zig");
const boot = @import("boot_info.zig");
const hpet = @import("hpet.zig");
const memory = @import("memory.zig");
const paging = @import("paging.zig");

const cc = std.os.uefi.cc;
const trampoline_image = @embedFile("generated/ap_trampoline.bin");

const boot_data_offset: usize = 0x10;
const gdt_descriptor_base_offset: usize = 0x42;
const protected_mode_pointer_offset: usize = 0x46;
const long_mode_pointer_offset: usize = 0x4C;
const gdt_offset: usize = 0x300;
const code32_descriptor_offset: usize = gdt_offset + 8;
const stack_pages: usize = 4;
const boot_signature: u64 = 0x5A49_474F_5341_5031;
const initial_actual_apic_id: u32 = 0xFFFF_FFFF;
const startup_timeout_iterations: usize = 2000;
const startup_poll_nanoseconds: u64 = 100_000;

const ApBootData = extern struct {
    signature: u64,
    cr3: u64,
    stack_top: u64,
    entry_point: u64,
    expected_apic_id: u32,
    actual_apic_id: u32,
    online: u32,
    state: u32,
};

pub const ApReport = struct {
    expected_apic_id: u32,
    actual_apic_id: u32,
    stack_base: usize,
    stack_size: usize,
    online: bool,
    state: u32,
};

pub const Report = struct {
    bsp_apic_id: u32,
    madt_processor_count: u32,
    target_count: usize,
    online_count: usize,
    startup_vector: u8,
    trampoline_base: usize,
    trampoline_size: usize,
    processors: [acpi.maximum_processors]ApReport,
};

extern fn zigos_memory_fence() callconv(cc) void;
extern fn zigos_halt_forever() callconv(cc) noreturn;

pub fn start(
    boot_info: *const boot.BootInfo,
    allocator: *memory.FrameAllocator,
    madt: acpi.MadtInfo,
    local_apic: apic.Information,
    reference: hpet.Device,
) ?Report {
    if (trampoline_image.len != memory.page_size) return null;
    if (boot_info.ap_trampoline.size != trampoline_image.len) return null;
    if (boot_info.ap_trampoline.base >= 0x0010_0000) return null;
    if ((boot_info.ap_trampoline.base & 0xFFF) != 0) return null;

    const pml4_address = paging.activePml4Address() orelse return null;
    if (pml4_address >= memory.four_gib) return null;

    const startup_vector_usize = boot_info.ap_trampoline.base >> 12;
    if (startup_vector_usize == 0 or startup_vector_usize > 0xFF) return null;
    const startup_vector: u8 = @intCast(startup_vector_usize);

    installTrampoline(boot_info.ap_trampoline.base) orelse return null;

    var report = Report{
        .bsp_apic_id = local_apic.apic_id,
        .madt_processor_count = madt.processor_count,
        .target_count = 0,
        .online_count = 0,
        .startup_vector = startup_vector,
        .trampoline_base = boot_info.ap_trampoline.base,
        .trampoline_size = boot_info.ap_trampoline.size,
        .processors = undefined,
    };

    for (madt.processors[0..madt.stored_processor_count]) |processor| {
        if (processor.apic_id == local_apic.apic_id) continue;
        if (report.target_count >= report.processors.len) return null;

        const stack_base = allocator.allocateContiguousBelow(stack_pages, memory.four_gib) orelse return null;
        const stack_size = stack_pages * @as(usize, @intCast(memory.page_size));
        const stack_top = stack_base + stack_size;
        const stack = @as([*]u8, @ptrFromInt(stack_base))[0..stack_size];
        @memset(stack, 0);

        const data = bootDataAt(boot_info.ap_trampoline.base);
        data.* = .{
            .signature = boot_signature,
            .cr3 = pml4_address,
            .stack_top = stack_top,
            .entry_point = @intFromPtr(&zigos_ap_entry),
            .expected_apic_id = processor.apic_id,
            .actual_apic_id = initial_actual_apic_id,
            .online = 0,
            .state = 1,
        };
        zigos_memory_fence();

        if (!apic.sendInitSipi(processor.apic_id, startup_vector, reference)) return null;

        var online = false;
        var iteration: usize = 0;
        while (iteration < startup_timeout_iterations) : (iteration += 1) {
            zigos_memory_fence();
            if (readVolatileU32(&data.online) != 0) {
                online = true;
                break;
            }
            if (!reference.waitNanoseconds(startup_poll_nanoseconds)) return null;
        }

        zigos_memory_fence();
        const actual_apic_id = readVolatileU32(&data.actual_apic_id);
        const state = readVolatileU32(&data.state);
        if (!online or actual_apic_id != processor.apic_id or state != 2) {
            debugWrite("SMP AP acknowledgement failure: online ");
            debugWriteU32(readVolatileU32(&data.online));
            debugWrite(", expected ");
            debugWriteU32(processor.apic_id);
            debugWrite(", actual 0x");
            debugWriteHex32(actual_apic_id);
            debugWrite(", state 0x");
            debugWriteHex32(state);
            debugWrite("\r\n");
            return null;
        }

        report.processors[report.target_count] = .{
            .expected_apic_id = processor.apic_id,
            .actual_apic_id = actual_apic_id,
            .stack_base = stack_base,
            .stack_size = stack_size,
            .online = online,
            .state = state,
        };
        report.target_count += 1;
        report.online_count += 1;
    }

    if (report.target_count + 1 != madt.processor_count) return null;
    return report;
}

export fn zigos_ap_entry(data: *volatile ApBootData) callconv(cc) noreturn {
    const actual_apic_id = apic.currentId();
    data.actual_apic_id = actual_apic_id;
    data.state = if (data.signature == boot_signature and actual_apic_id == data.expected_apic_id) 2 else 0xDEAD;
    zigos_memory_fence();
    data.online = 1;
    zigos_memory_fence();
    zigos_halt_forever();
}

fn debugWrite(text: []const u8) void {
    for (text) |character| zigos_debug_putc(character);
}

fn debugWriteU32(initial_value: u32) void {
    if (initial_value == 0) {
        zigos_debug_putc('0');
        return;
    }
    var value = initial_value;
    var buffer: [10]u8 = undefined;
    var index = buffer.len;
    while (value != 0) {
        index -= 1;
        buffer[index] = @intCast('0' + value % 10);
        value /= 10;
    }
    debugWrite(buffer[index..]);
}

fn debugWriteHex8(value: u8) void {
    const digits = "0123456789ABCDEF";
    zigos_debug_putc(digits[@as(u4, @truncate(value >> 4))]);
    zigos_debug_putc(digits[@as(u4, @truncate(value))]);
}

fn debugWriteHex32(value: u32) void {
    const digits = "0123456789ABCDEF";
    var shift: u5 = 28;
    while (true) {
        zigos_debug_putc(digits[@as(u4, @truncate(value >> shift))]);
        if (shift == 0) break;
        shift -= 4;
    }
}

fn debugWriteHex64(value: usize) void {
    const digits = "0123456789ABCDEF";
    var shift: u6 = 60;
    const integer: u64 = @intCast(value);
    while (true) {
        zigos_debug_putc(digits[@as(u4, @truncate(integer >> shift))]);
        if (shift == 0) break;
        shift -= 4;
    }
}
fn installTrampoline(base: usize) ?void {
    const destination = @as([*]u8, @ptrFromInt(base))[0..trampoline_image.len];
    @memcpy(destination, trampoline_image);

    const gdt_relative = readU32(destination, gdt_descriptor_base_offset);
    const protected_relative = readU32(destination, protected_mode_pointer_offset);
    const long_relative = readU32(destination, long_mode_pointer_offset);
    if (gdt_relative != gdt_offset) return null;
    if (protected_relative >= trampoline_image.len or long_relative >= trampoline_image.len) return null;

    writeU32(destination, gdt_descriptor_base_offset, @intCast(base + gdt_relative));
    writeU32(destination, long_mode_pointer_offset, @intCast(base + long_relative));
    patchDescriptorBase(destination, code32_descriptor_offset, base);

    if (readU64(destination, boot_data_offset) != boot_signature) return null;
    zigos_memory_fence();
    return {};
}

fn patchDescriptorBase(bytes: []u8, descriptor_offset: usize, base: usize) void {
    const base32: u32 = @truncate(base);
    bytes[descriptor_offset + 2] = @truncate(base32);
    bytes[descriptor_offset + 3] = @truncate(base32 >> 8);
    bytes[descriptor_offset + 4] = @truncate(base32 >> 16);
    bytes[descriptor_offset + 7] = @truncate(base32 >> 24);
}

fn bootDataAt(base: usize) *volatile ApBootData {
    return @ptrFromInt(base + boot_data_offset);
}

fn readVolatileU32(value: *volatile u32) u32 {
    return value.*;
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn readU64(bytes: []const u8, offset: usize) u64 {
    return @as(u64, readU32(bytes, offset)) | (@as(u64, readU32(bytes, offset + 4)) << 32);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
    bytes[offset + 2] = @truncate(value >> 16);
    bytes[offset + 3] = @truncate(value >> 24);
}

comptime {
    if (@sizeOf(ApBootData) != 48) @compileError("AP boot-data header must remain 48 bytes");
    if (trampoline_image.len != 4096) @compileError("embedded AP trampoline must be one page");
}
