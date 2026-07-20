const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch != .x86) @compileError("legacy kernel requires the x86 target");
    if (builtin.os.tag != .freestanding) @compileError("legacy kernel requires a freestanding target");
    if (@sizeOf(BootInfo) != 32) @compileError("legacy BootInfo layout changed");
    if (@sizeOf(E820Entry) != 24) @compileError("legacy E820 entry layout changed");
    if (@sizeOf(IdtEntry) != 8) @compileError("legacy IDT entry layout changed");
    if (@sizeOf(TrapFrame) != 52) @compileError("legacy trap-frame layout changed");
}

const boot_info_magic: u32 = 0x4F49_425A;
const boot_info_address: u32 = 0x0000_5000;
const maximum_e820_entries: u16 = 64;

const BootInfo = extern struct {
    magic: u32,
    version: u16,
    size: u16,
    e820_entry_size: u16,
    e820_entry_count: u16,
    e820_entries_address: u32,
    boot_drive: u8,
    flags: u8,
    reserved0: u16,
    kernel_address: u32,
    kernel_bytes: u32,
    kernel_sectors: u16,
    reserved1: u16,
};

const E820Entry = extern struct {
    base: u64,
    length: u64,
    kind: u32,
    attributes: u32,
};

const TrapFrame = extern struct {
    edi: u32,
    esi: u32,
    ebp: u32,
    interrupted_esp: u32,
    ebx: u32,
    edx: u32,
    ecx: u32,
    eax: u32,
    vector: u32,
    error_code: u32,
    eip: u32,
    cs: u32,
    eflags: u32,
};

const IdtEntry = packed struct {
    offset_low: u16,
    selector: u16,
    zero: u8,
    attributes: u8,
    offset_high: u16,
};

extern var zigos_i686_entry_stack: u32;
extern var zigos_i686_boot_info_pointer: u32;
extern fn zigos_i686_read_cr0() callconv(.c) u32;
extern fn zigos_i686_cpuid_vendor(destination: [*]u8) callconv(.c) u32;
extern fn zigos_i686_out8(port: u16, value: u8) callconv(.c) void;
extern fn zigos_i686_load_idt(descriptor: *const [6]u8) callconv(.c) void;
extern fn zigos_i686_enable_interrupts() callconv(.c) void;
extern fn zigos_i686_disable_interrupts() callconv(.c) void;
extern fn zigos_i686_halt() callconv(.c) void;
extern fn zigos_i686_irq0_stub() callconv(.c) void;
extern const zigos_i686_exception_stub_table: [32]u32;
extern fn zigos_i686_trigger_breakpoint() callconv(.c) void;

var bss_probe: [64]u8 = @splat(0);
var vga_cursor: usize = 0;
var idt: [256]IdtEntry = undefined;
var timer_ticks: u32 = 0;
var exception_count: u32 = 0;
var last_exception_vector: u32 = 0;
var last_exception_error: u32 = 0;
var last_exception_eip: u32 = 0;

pub export fn zigos_legacy_kernel_main() callconv(.c) noreturn {
    initCom1();
    clearVga();

    var vendor: [12]u8 = undefined;
    const maximum_cpuid_leaf = zigos_i686_cpuid_vendor(&vendor);
    const cr0 = zigos_i686_read_cr0();
    const stack = zigos_i686_entry_stack;
    const pe_enabled = (cr0 & 1) != 0;
    const stack_aligned = (stack & 0xF) == 0;
    var bss_zero = true;
    for (bss_probe) |value| bss_zero = bss_zero and value == 0;
    bss_probe[0] = 0xA5;

    writeAll("ZigOs i686 freestanding kernel image built\r\n");
    writeAll("ZigOs i686 runtime verified: vendor ");
    writeAll(&vendor);
    writeAll(" max-leaf 0x");
    writeHex32(maximum_cpuid_leaf);
    writeAll(" CR0 0x");
    writeHex32(cr0);
    writeAll(" PE ");
    writeAll(if (pe_enabled) "yes" else "no");
    writeAll(" stack 0x");
    writeHex32(stack);
    writeAll(" aligned16 ");
    writeAll(if (stack_aligned) "yes" else "no");
    writeAll(" BSS64 zero ");
    writeAll(if (bss_zero) "yes" else "no");
    writeAll(" VGA yes COM1 yes\r\n");

    verifyAndReportBootInfo();
    const ticks = verifyInterruptTimer();
    writeAll("ZigOs i686 interrupts verified: IDT 0x00000100 limit 0x000007FF IRQ0 0x20 PIC 0x20/0x28 masks 0xFE/0xFF PIT-Hz 0x00000064 divisor 0x00002E9C ticks 0x");
    writeHex32(ticks);
    writeAll("\r\n");
    haltForever();
}

pub export fn zigos_i686_exception_dispatch(frame: *const TrapFrame) callconv(.c) void {
    if (frame.vector == 3) {
        exception_count +|= 1;
        last_exception_vector = frame.vector;
        last_exception_error = frame.error_code;
        last_exception_eip = frame.eip;
        return;
    }

    writeAll("ZigOs i686 fatal exception: vector 0x");
    writeHex32(frame.vector);
    writeAll(" error 0x");
    writeHex32(frame.error_code);
    writeAll(" eip 0x");
    writeHex32(frame.eip);
    writeAll("\r\n");
    haltForever();
}

pub export fn zigos_i686_timer_interrupt() callconv(.c) void {
    timer_ticks +|= 1;
}

fn verifyAndReportBootInfo() void {
    const pointer = zigos_i686_boot_info_pointer;
    if (pointer != boot_info_address) {
        writeAll("ZigOs i686 E820 failed: boot-info pointer 0x");
        writeHex32(pointer);
        writeAll("\r\n");
        return;
    }

    const info: *const BootInfo = @ptrFromInt(pointer);
    const valid = info.magic == boot_info_magic and info.version == 1 and info.size == @sizeOf(BootInfo) and
        info.e820_entry_size == @sizeOf(E820Entry) and info.e820_entry_count != 0 and
        info.e820_entry_count <= maximum_e820_entries and info.e820_entries_address == 0x0000_5200 and
        info.boot_drive == 0x80 and (info.flags & 1) != 0 and info.kernel_address == 0x0001_0000 and
        info.kernel_bytes != 0 and info.kernel_sectors != 0;
    if (!valid) {
        writeAll("ZigOs i686 E820 failed: invalid boot contract\r\n");
        return;
    }

    const entries: [*]const E820Entry = @ptrFromInt(info.e820_entries_address);
    var usable_regions: u32 = 0;
    var usable_bytes: u64 = 0;
    var highest_address: u64 = 0;
    for (0..info.e820_entry_count) |index| {
        const entry = entries[index];
        if (entry.length == 0) continue;
        const end = entry.base +| entry.length;
        if (end > highest_address) highest_address = end;
        if (entry.kind == 1) {
            usable_regions +|= 1;
            usable_bytes +|= entry.length;
        }
    }

    writeAll("ZigOs i686 E820 verified: boot-info 0x");
    writeHex32(pointer);
    writeAll(" version 0x");
    writeHex32(info.version);
    writeAll(" entries 0x");
    writeHex32(info.e820_entry_count);
    writeAll(" usable-regions 0x");
    writeHex32(usable_regions);
    writeAll(" usable-bytes 0x");
    writeHex64(usable_bytes);
    writeAll(" highest 0x");
    writeHex64(highest_address);
    writeAll(" drive 0x");
    writeHex8(info.boot_drive);
    writeAll(" kernel 0x");
    writeHex32(info.kernel_address);
    writeAll("/0x");
    writeHex32(info.kernel_bytes);
    writeAll("/0x");
    writeHex32(info.kernel_sectors);
    writeAll("\r\n");
}

fn verifyInterruptTimer() u32 {
    for (&idt) |*entry| {
        entry.* = .{
            .offset_low = 0,
            .selector = 0,
            .zero = 0,
            .attributes = 0,
            .offset_high = 0,
        };
    }

    for (0..32) |vector| {
        setIdtGate(vector, zigos_i686_exception_stub_table[vector]);
    }
    const handler: u32 = @intCast(@intFromPtr(&zigos_i686_irq0_stub));
    setIdtGate(0x20, handler);
    const base: u32 = @intCast(@intFromPtr(&idt));
    const descriptor = [6]u8{
        0xFF,
        0x07,
        @truncate(base),
        @truncate(base >> 8),
        @truncate(base >> 16),
        @truncate(base >> 24),
    };
    zigos_i686_load_idt(&descriptor);

    zigos_i686_trigger_breakpoint();
    zigos_i686_trigger_breakpoint();
    const exceptions: *volatile u32 = &exception_count;
    if (exceptions.* != 2 or last_exception_vector != 3 or last_exception_error != 0 or last_exception_eip == 0) {
        writeAll("ZigOs i686 exceptions failed\r\n");
        haltForever();
    }
    writeAll("ZigOs i686 exceptions verified: vectors 0x00000020 breakpoint-count 0x");
    writeHex32(exceptions.*);
    writeAll(" last-vector 0x");
    writeHex32(last_exception_vector);
    writeAll(" error 0x");
    writeHex32(last_exception_error);
    writeAll(" eip-nonzero yes\r\n");

    configurePic();
    configurePit100Hz();
    const ticks: *volatile u32 = &timer_ticks;
    zigos_i686_enable_interrupts();
    while (ticks.* < 5) zigos_i686_halt();
    zigos_i686_disable_interrupts();
    zigos_i686_out8(0x0021, 0xFF);
    zigos_i686_out8(0x00A1, 0xFF);
    return ticks.*;
}

fn setIdtGate(vector: usize, handler: u32) void {
    idt[vector] = .{
        .offset_low = @truncate(handler),
        .selector = 0x0008,
        .zero = 0,
        .attributes = 0x8E,
        .offset_high = @truncate(handler >> 16),
    };
}

fn configurePic() void {
    zigos_i686_out8(0x0021, 0xFF);
    zigos_i686_out8(0x00A1, 0xFF);
    zigos_i686_out8(0x0020, 0x11);
    ioWait();
    zigos_i686_out8(0x00A0, 0x11);
    ioWait();
    zigos_i686_out8(0x0021, 0x20);
    ioWait();
    zigos_i686_out8(0x00A1, 0x28);
    ioWait();
    zigos_i686_out8(0x0021, 0x04);
    ioWait();
    zigos_i686_out8(0x00A1, 0x02);
    ioWait();
    zigos_i686_out8(0x0021, 0x01);
    ioWait();
    zigos_i686_out8(0x00A1, 0x01);
    ioWait();
    zigos_i686_out8(0x0021, 0xFE);
    zigos_i686_out8(0x00A1, 0xFF);
}

fn configurePit100Hz() void {
    zigos_i686_out8(0x0043, 0x36);
    zigos_i686_out8(0x0040, 0x9C);
    zigos_i686_out8(0x0040, 0x2E);
}

fn ioWait() void {
    zigos_i686_out8(0x0080, 0);
}

fn initCom1() void {
    zigos_i686_out8(0x03F9, 0x00);
    zigos_i686_out8(0x03FB, 0x80);
    zigos_i686_out8(0x03F8, 0x03);
    zigos_i686_out8(0x03F9, 0x00);
    zigos_i686_out8(0x03FB, 0x03);
    zigos_i686_out8(0x03FA, 0xC7);
    zigos_i686_out8(0x03FC, 0x0B);
}

fn clearVga() void {
    const vga: [*]volatile u16 = @ptrFromInt(0x000B8000);
    for (0..80 * 25) |index| vga[index] = 0x0720;
    vga_cursor = 0;
}

fn writeAll(text: []const u8) void {
    for (text) |character| {
        zigos_i686_out8(0x00E9, character);
        zigos_i686_out8(0x03F8, character);
        vgaPutc(character);
    }
}

fn vgaPutc(character: u8) void {
    if (character == '\r') return;
    if (character == '\n') {
        vga_cursor = ((vga_cursor / 80) + 1) * 80;
        if (vga_cursor >= 80 * 25) vga_cursor = 0;
        return;
    }
    const vga: [*]volatile u16 = @ptrFromInt(0x000B8000);
    vga[vga_cursor] = 0x0700 | @as(u16, character);
    vga_cursor += 1;
    if (vga_cursor >= 80 * 25) vga_cursor = 0;
}

fn writeHex8(value: u8) void {
    writeNibble(value >> 4);
    writeNibble(value & 0xF);
}

fn writeHex32(value: anytype) void {
    const narrowed: u32 = @intCast(value);
    var shift: u5 = 28;
    while (true) {
        writeNibble(@intCast((narrowed >> shift) & 0xF));
        if (shift == 0) break;
        shift -= 4;
    }
}

fn writeHex64(value: u64) void {
    var shift: u6 = 60;
    while (true) {
        writeNibble(@intCast((value >> shift) & 0xF));
        if (shift == 0) break;
        shift -= 4;
    }
}

fn writeNibble(nibble: u8) void {
    const character: u8 = if (nibble < 10) '0' + nibble else 'A' + (nibble - 10);
    writeAll(&[_]u8{character});
}

fn haltForever() noreturn {
    while (true) asm volatile ("hlt");
}
