const std = @import("std");
const memory = @import("memory.zig");

const cc = std.os.uefi.cc;
const code_selector: u16 = 0x08;
const data_selector: u16 = 0x10;
const tss_selector: u16 = 0x18;
const breakpoint_vector: usize = 3;
const timer_vector: usize = 0x40;
const spurious_vector: usize = 0xFF;
const interrupt_stack_pages: usize = 4;

const DescriptorTablePointer = extern struct {
    limit: u16,
    base: u64 align(1),
};

const TaskStateSegment = extern struct {
    reserved0: u32,
    rsp0: u64 align(1),
    rsp1: u64 align(1),
    rsp2: u64 align(1),
    reserved1: u64 align(1),
    ist1: u64 align(1),
    ist2: u64 align(1),
    ist3: u64 align(1),
    ist4: u64 align(1),
    ist5: u64 align(1),
    ist6: u64 align(1),
    ist7: u64 align(1),
    reserved2: u64 align(1),
    reserved3: u16 align(1),
    io_map_base: u16 align(1),
};

const IdtEntry = extern struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attributes: u8,
    offset_middle: u16,
    offset_high: u32,
    reserved: u32,
};

pub const Installation = struct {
    gdt_address: usize,
    idt_address: usize,
    tss_address: usize,
    interrupt_stack_base: usize,
    interrupt_stack_size: usize,
    code_segment: u16,
    task_register: u16,
    breakpoint_count: u64,
    breakpoint_stack_pointer: usize,
};

extern fn zigos_exception_stub_address(vector: u8) callconv(cc) usize;
extern fn zigos_load_gdt(
    pointer: *const DescriptorTablePointer,
    new_code_selector: u16,
    new_data_selector: u16,
    new_tss_selector: u16,
) callconv(cc) void;
extern fn zigos_load_idt(pointer: *const DescriptorTablePointer) callconv(cc) void;
extern fn zigos_read_cs() callconv(cc) u64;
extern fn zigos_read_tr() callconv(cc) u64;
extern fn zigos_isr_breakpoint() callconv(cc) void;
extern fn zigos_isr_apic_timer() callconv(cc) void;
extern fn zigos_isr_spurious() callconv(cc) void;
extern fn zigos_trigger_breakpoint() callconv(cc) void;

var gdt: [5]u64 align(16) = .{ 0, 0, 0, 0, 0 };
var tss: TaskStateSegment align(16) = undefined;
var idt: [256]IdtEntry align(16) = undefined;

var interrupt_stack_base: usize = 0;
var interrupt_stack_size: usize = 0;
var breakpoint_count: u64 = 0;
var breakpoint_stack_pointer: usize = 0;
var breakpoint_used_ist: bool = false;

pub fn install(allocator: *memory.FrameAllocator, kernel_stack_top: usize) ?Installation {
    const stack_base = allocator.allocateContiguousBelow(interrupt_stack_pages, memory.four_gib) orelse return null;
    const stack_size = interrupt_stack_pages * @as(usize, @intCast(memory.page_size));
    const stack_top = stack_base + stack_size;

    interrupt_stack_base = stack_base;
    interrupt_stack_size = stack_size;
    breakpoint_count = 0;
    breakpoint_stack_pointer = 0;
    breakpoint_used_ist = false;

    tss = std.mem.zeroes(TaskStateSegment);
    tss.rsp0 = @intCast(kernel_stack_top);
    tss.ist1 = @intCast(stack_top);
    tss.io_map_base = @intCast(@sizeOf(TaskStateSegment));

    gdt[0] = 0;
    gdt[1] = 0x00AF_9A00_0000_FFFF;
    gdt[2] = 0x00CF_9200_0000_FFFF;
    installTssDescriptor();

    const gdt_pointer = DescriptorTablePointer{
        .limit = @intCast(@sizeOf(@TypeOf(gdt)) - 1),
        .base = @intCast(@intFromPtr(&gdt)),
    };
    zigos_load_gdt(&gdt_pointer, code_selector, data_selector, tss_selector);

    for (&idt) |*entry| entry.* = std.mem.zeroes(IdtEntry);
    var exception_vector: usize = 0;
    while (exception_vector < 32) : (exception_vector += 1) {
        setInterruptGate(
            &idt[exception_vector],
            zigos_exception_stub_address(@intCast(exception_vector)),
            code_selector,
            1,
        );
    }
    setInterruptGate(&idt[breakpoint_vector], @intFromPtr(&zigos_isr_breakpoint), code_selector, 1);
    setInterruptGate(&idt[timer_vector], @intFromPtr(&zigos_isr_apic_timer), code_selector, 1);
    setInterruptGate(&idt[spurious_vector], @intFromPtr(&zigos_isr_spurious), code_selector, 0);

    const idt_pointer = DescriptorTablePointer{
        .limit = @intCast(@sizeOf(@TypeOf(idt)) - 1),
        .base = @intCast(@intFromPtr(&idt)),
    };
    zigos_load_idt(&idt_pointer);
    zigos_trigger_breakpoint();

    const active_code_segment: u16 = @truncate(zigos_read_cs());
    const active_task_register: u16 = @truncate(zigos_read_tr());
    if (active_code_segment != code_selector) return null;
    if (active_task_register != tss_selector) return null;
    if (breakpoint_count != 1 or !breakpoint_used_ist) return null;

    return .{
        .gdt_address = @intFromPtr(&gdt),
        .idt_address = @intFromPtr(&idt),
        .tss_address = @intFromPtr(&tss),
        .interrupt_stack_base = stack_base,
        .interrupt_stack_size = stack_size,
        .code_segment = active_code_segment,
        .task_register = active_task_register,
        .breakpoint_count = breakpoint_count,
        .breakpoint_stack_pointer = breakpoint_stack_pointer,
    };
}

export fn zigos_breakpoint_handler(vector: u64, interrupt_rsp: usize) callconv(cc) void {
    if (vector != breakpoint_vector) return;

    breakpoint_count += 1;
    breakpoint_stack_pointer = interrupt_rsp;
    breakpoint_used_ist = interrupt_rsp >= interrupt_stack_base and
        interrupt_rsp < interrupt_stack_base + interrupt_stack_size;
}

fn installTssDescriptor() void {
    const base: u64 = @intCast(@intFromPtr(&tss));
    const limit: u64 = @sizeOf(TaskStateSegment) - 1;

    gdt[3] = (limit & 0xFFFF) |
        ((base & 0xFF_FFFF) << 16) |
        (@as(u64, 0x89) << 40) |
        (((limit >> 16) & 0xF) << 48) |
        (((base >> 24) & 0xFF) << 56);
    gdt[4] = base >> 32;
}

fn setInterruptGate(entry: *IdtEntry, handler_address: usize, selector: u16, ist_index: u3) void {
    const address: u64 = @intCast(handler_address);
    entry.* = .{
        .offset_low = @truncate(address),
        .selector = selector,
        .ist = ist_index,
        .type_attributes = 0x8E,
        .offset_middle = @truncate(address >> 16),
        .offset_high = @truncate(address >> 32),
        .reserved = 0,
    };
}

comptime {
    if (@sizeOf(DescriptorTablePointer) != 10) @compileError("x86-64 descriptor-table pointer must be 10 bytes");
    if (@sizeOf(TaskStateSegment) != 104) @compileError("x86-64 TSS must be 104 bytes");
    if (@sizeOf(IdtEntry) != 16) @compileError("x86-64 IDT entry must be 16 bytes");
}
