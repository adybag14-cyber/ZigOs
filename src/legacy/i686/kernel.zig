const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch != .x86) @compileError("legacy kernel requires the x86 target");
    if (builtin.os.tag != .freestanding) @compileError("legacy kernel requires a freestanding target");
    if (@sizeOf(BootInfo) != 32) @compileError("legacy BootInfo layout changed");
    if (@sizeOf(E820Entry) != 24) @compileError("legacy E820 entry layout changed");
    if (@sizeOf(IdtEntry) != 8) @compileError("legacy IDT entry layout changed");
    if (@sizeOf(TrapFrame) != 52) @compileError("legacy trap-frame layout changed");
    if (@sizeOf(InterruptContext) != 44) @compileError("legacy interrupt-context layout changed");
    if (@sizeOf(UserReturnFrame) != 52) @compileError("legacy user-return frame layout changed");
    if (@sizeOf(Tss) != 104) @compileError("legacy TSS layout changed");
    if (@sizeOf(HeapBlock) != 16) @compileError("legacy heap-block layout changed");
}

const boot_info_magic: u32 = 0x4F49_425A;
const boot_info_address: u32 = 0x0000_5000;
const maximum_e820_entries: u16 = 64;
const frame_size: u32 = 4096;
const managed_memory_limit: u32 = 64 * 1024 * 1024;
const managed_frame_count: usize = managed_memory_limit / frame_size;
const expected_fat_file = "ZigOs legacy FAT12 filesystem is online.\r\nLoaded through ATA PIO by the i686 kernel.\r\n";
const frame_bitmap_bytes: usize = managed_frame_count / 8;

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

const InterruptContext = extern struct {
    edi: u32,
    esi: u32,
    ebp: u32,
    interrupted_esp: u32,
    ebx: u32,
    edx: u32,
    ecx: u32,
    eax: u32,
    eip: u32,
    cs: u32,
    eflags: u32,
};

const UserReturnFrame = extern struct {
    edi: u32,
    esi: u32,
    ebp: u32,
    interrupted_esp: u32,
    ebx: u32,
    edx: u32,
    ecx: u32,
    eax: u32,
    eip: u32,
    cs: u32,
    eflags: u32,
    user_esp: u32,
    user_ss: u32,
};

const Tss = extern struct {
    previous: u32 = 0,
    esp0: u32 = 0,
    ss0: u32 = 0,
    esp1: u32 = 0,
    ss1: u32 = 0,
    esp2: u32 = 0,
    ss2: u32 = 0,
    cr3: u32 = 0,
    eip: u32 = 0,
    eflags: u32 = 0,
    eax: u32 = 0,
    ecx: u32 = 0,
    edx: u32 = 0,
    ebx: u32 = 0,
    esp: u32 = 0,
    ebp: u32 = 0,
    esi: u32 = 0,
    edi: u32 = 0,
    es: u32 = 0,
    cs: u32 = 0,
    ss: u32 = 0,
    ds: u32 = 0,
    fs: u32 = 0,
    gs: u32 = 0,
    ldt: u32 = 0,
    trap_iomap: u32 = 0,
};

const HeapBlock = extern struct {
    payload_bytes: u32,
    next_address: u32,
    is_free: u32,
    reserved: u32,
};

const IdtEntry = packed struct {
    offset_low: u16,
    selector: u16,
    zero: u8,
    attributes: u8,
    offset_high: u16,
};

extern var zigos_i686_entry_stack: u32;
extern const __kernel_end: u8;
extern var zigos_i686_boot_info_pointer: u32;
extern fn zigos_i686_read_cr0() callconv(.c) u32;
extern fn zigos_i686_read_cr3() callconv(.c) u32;
extern fn zigos_i686_enable_paging(page_directory: u32) callconv(.c) void;
extern fn zigos_i686_invalidate_page(address: u32) callconv(.c) void;
extern fn zigos_i686_cpuid_vendor(destination: [*]u8) callconv(.c) u32;
extern fn zigos_i686_out8(port: u16, value: u8) callconv(.c) void;
extern fn zigos_i686_in8(port: u16) callconv(.c) u8;
extern fn zigos_i686_in16(port: u16) callconv(.c) u16;
extern fn zigos_i686_load_idt(descriptor: *const [6]u8) callconv(.c) void;
extern fn zigos_i686_load_gdt(descriptor: *const [6]u8) callconv(.c) void;
extern fn zigos_i686_load_tr(selector: u16) callconv(.c) void;
extern fn zigos_i686_read_tr() callconv(.c) u32;
extern fn zigos_i686_enter_user(entry: u32, user_stack: u32) callconv(.c) void;
extern fn zigos_i686_user_return_stub() callconv(.c) void;
extern fn zigos_i686_syscall_stub() callconv(.c) void;
extern fn zigos_i686_enable_interrupts() callconv(.c) void;
extern fn zigos_i686_disable_interrupts() callconv(.c) void;
extern fn zigos_i686_halt() callconv(.c) void;
extern fn zigos_i686_irq0_stub() callconv(.c) void;
extern fn zigos_i686_irq1_stub() callconv(.c) void;
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
var keyboard_irq_count: u32 = 0;
var keyboard_make_count: u32 = 0;
var keyboard_last_make: u8 = 0;
var frame_bitmap: [frame_bitmap_bytes]u8 = @splat(0xFF);
var free_frame_count: u32 = 0;
var frame_allocator_ready = false;
var heap_base: u32 = 0;
var heap_bytes: u32 = 0;
var heap_ready = false;
var ata_model: [40]u8 = @splat(0);
var ata_model_length: usize = 0;
var ata_sector_count: u32 = 0;
var ata_ready = false;
var fat_file_content: [256]u8 = @splat(0);
var fat_file_length: usize = 0;
var fat_file_cluster: u16 = 0;
var fat_file_hash: u32 = 0;
var fat_ready = false;
var fat_volume_lba: u32 = 0;
var fat_start_lba: u32 = 0;
var fat_root_lba: u32 = 0;
var fat_data_lba: u32 = 0;
var fat_bytes_per_sector: u16 = 0;
var fat_sectors_per_cluster: u8 = 0;
var init_elf_size: u32 = 0;
var init_elf_entry: u32 = 0;
var init_elf_filesz: u32 = 0;
var init_elf_memsz: u32 = 0;
var init_elf_hash: u32 = 0;
var init_elf_exit: u32 = 0;
var shell_command_count: u32 = 0;
var shell_unknown_count: u32 = 0;
var scheduler_stacks: [3]u32 = @splat(0);
var scheduler_current: u32 = 0;
var scheduler_switches: u32 = 0;
var scheduler_task_a_quanta: u32 = 0;
var scheduler_task_b_quanta: u32 = 0;
var scheduler_active = false;
var scheduler_done = false;
var scheduler_stack_a: [4096]u8 align(16) = @splat(0);
var scheduler_stack_b: [4096]u8 align(16) = @splat(0);
var kernel_page_directory: u32 = 0;
var kernel_identity_tables: [4]u32 = @splat(0);
var kernel_gdt: [6][8]u8 align(8) = @splat(@splat(0));
var kernel_tss: Tss align(16) = .{};
var user_transition_stack: [4096]u8 align(16) = @splat(0);
var user_return_eax: u32 = 0;
var user_return_cs: u32 = 0;
var user_return_ss: u32 = 0;
var user_return_esp: u32 = 0;
var user_code_frame: u32 = 0;
var user_stack_frame: u32 = 0;
var syscall_count: u32 = 0;
var syscall_write_bytes: u32 = 0;
var syscall_rejected: u32 = 0;
var syscall_exit_code: u32 = 0;
var syscall_exited = false;

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
    verifyFrameAllocator();
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

pub export fn zigos_i686_timer_interrupt(current_esp: u32) callconv(.c) u32 {
    timer_ticks +|= 1;
    if (!scheduler_active) return 0;

    scheduler_stacks[scheduler_current] = current_esp;
    if (scheduler_task_a_quanta >= 3 and scheduler_task_b_quanta >= 3) {
        scheduler_active = false;
        scheduler_done = true;
        scheduler_current = 0;
        scheduler_switches +|= 1;
        return scheduler_stacks[0];
    }

    const next: u32 = if (scheduler_current == 1) 2 else 1;
    scheduler_current = next;
    scheduler_switches +|= 1;
    return scheduler_stacks[next];
}

pub export fn zigos_i686_keyboard_interrupt() callconv(.c) void {
    const scancode = zigos_i686_in8(0x0060);
    keyboard_irq_count +|= 1;
    if ((scancode & 0x80) == 0) {
        keyboard_make_count +|= 1;
        keyboard_last_make = scancode;
    }
}

pub export fn zigos_i686_user_return_dispatch(frame: *const UserReturnFrame) callconv(.c) void {
    user_return_eax = frame.eax;
    user_return_cs = frame.cs;
    user_return_ss = frame.user_ss;
    user_return_esp = frame.user_esp;
}

pub export fn zigos_i686_syscall_dispatch(frame: *UserReturnFrame) callconv(.c) u32 {
    syscall_count +|= 1;
    switch (frame.eax) {
        1 => {
            const length = frame.ecx;
            const start = frame.ebx;
            const end = start +% length;
            if (length > 128 or end < start or start < 0x0040_0000 or end > 0x0040_1000) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            }
            const bytes: [*]const u8 = @ptrFromInt(start);
            writeAll(bytes[0..length]);
            syscall_write_bytes +|= length;
            frame.eax = length;
            return 0;
        },
        2 => {
            frame.eax = 1;
            return 0;
        },
        3 => {
            syscall_exit_code = frame.ebx;
            syscall_exited = true;
            return 1;
        },
        else => {
            syscall_rejected +|= 1;
            frame.eax = 0xFFFF_FFDA;
            return 0;
        },
    }
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
    const timer_handler: u32 = @intCast(@intFromPtr(&zigos_i686_irq0_stub));
    const keyboard_handler: u32 = @intCast(@intFromPtr(&zigos_i686_irq1_stub));
    setIdtGate(0x20, timer_handler);
    setIdtGate(0x21, keyboard_handler);
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
    zigos_i686_out8(0x0021, 0xFD);
    writeAll("ZigOs i686 keyboard waiting: IRQ1 0x21 controller-command 0xD2 expected-make 0x1E\r\n");
    const makes: *volatile u32 = &keyboard_make_count;
    injectPs2Scancode(0x1E);
    zigos_i686_enable_interrupts();
    while (makes.* < 1 or keyboard_last_make != 0x1E) zigos_i686_halt();
    zigos_i686_disable_interrupts();
    zigos_i686_out8(0x0021, 0xFF);
    zigos_i686_out8(0x00A1, 0xFF);
    writeAll("ZigOs i686 keyboard verified: IRQ1 0x21 make-count 0x");
    writeHex32(makes.*);
    writeAll(" last-make 0x");
    writeHex8(keyboard_last_make);
    writeAll(" irq-count-nonzero ");
    writeAll(if (keyboard_irq_count != 0) "yes" else "no");
    writeAll("\r\n");
    return ticks.*;
}

fn verifyFrameAllocator() void {
    initializeFrameAllocator();
    const free_before = free_frame_count;
    const first = allocateFrame() orelse frameAllocatorFailure("first allocation");
    const second = allocateFrame() orelse frameAllocatorFailure("second allocation");
    const third = allocateFrame() orelse frameAllocatorFailure("third allocation");
    if (first != 0x0010_0000 or second != 0x0010_1000 or third != 0x0010_2000) {
        frameAllocatorFailure("unexpected allocation order");
    }
    if (!freeFrame(second)) frameAllocatorFailure("free second");
    const reused = allocateFrame() orelse frameAllocatorFailure("reuse allocation");
    if (reused != second) frameAllocatorFailure("reuse mismatch");
    if (!freeFrame(first) or !freeFrame(reused) or !freeFrame(third)) {
        frameAllocatorFailure("final free");
    }
    const free_after = free_frame_count;
    if (free_after != free_before) frameAllocatorFailure("accounting mismatch");

    writeAll("ZigOs i686 frame allocator verified: managed-limit 0x");
    writeHex32(managed_memory_limit);
    writeAll(" frame-size 0x");
    writeHex32(frame_size);
    writeAll(" free-before 0x");
    writeHex32(free_before);
    writeAll(" first 0x");
    writeHex32(first);
    writeAll(" second 0x");
    writeHex32(second);
    writeAll(" third 0x");
    writeHex32(third);
    writeAll(" reuse 0x");
    writeHex32(reused);
    writeAll(" free-after 0x");
    writeHex32(free_after);
    writeAll(" kernel-end-below-1M ");
    writeAll(if (@intFromPtr(&__kernel_end) < 0x0010_0000) "yes" else "no");
    writeAll("\r\n");
    verifyPaging();
}

fn verifyPaging() void {
    const page_directory = allocateFrame() orelse frameAllocatorFailure("page directory");
    kernel_page_directory = page_directory;
    var identity_tables: [4]u32 = undefined;
    for (&identity_tables) |*table| table.* = allocateFrame() orelse frameAllocatorFailure("identity table");
    kernel_identity_tables = identity_tables;
    const alias_table = allocateFrame() orelse frameAllocatorFailure("alias table");
    const test_frame = allocateFrame() orelse frameAllocatorFailure("paging test frame");

    zeroPhysicalFrame(page_directory);
    for (identity_tables) |table| zeroPhysicalFrame(table);
    zeroPhysicalFrame(alias_table);
    zeroPhysicalFrame(test_frame);

    const directory: [*]volatile u32 = @ptrFromInt(page_directory);
    for (identity_tables, 0..) |table_address, directory_index| {
        directory[directory_index] = table_address | 0x003;
        const table: [*]volatile u32 = @ptrFromInt(table_address);
        const base_page: u32 = @intCast(directory_index * 1024);
        for (0..1024) |entry_index| {
            const page: u32 = base_page + @as(u32, @intCast(entry_index));
            table[entry_index] = page * frame_size | 0x003;
        }
    }

    const alias_virtual: u32 = 0xC000_0000;
    directory[alias_virtual >> 22] = alias_table | 0x003;
    const alias_entries: [*]volatile u32 = @ptrFromInt(alias_table);
    alias_entries[0] = test_frame | 0x003;

    const physical_value: *volatile u32 = @ptrFromInt(test_frame);
    physical_value.* = 0x1122_3344;
    zigos_i686_enable_paging(page_directory);
    const cr0 = zigos_i686_read_cr0();
    const cr3 = zigos_i686_read_cr3();
    const alias_value: *volatile u32 = @ptrFromInt(alias_virtual);
    if (alias_value.* != 0x1122_3344) pagingFailure("initial alias read");
    alias_value.* = 0xA5A5_5A5A;
    zigos_i686_invalidate_page(alias_virtual);
    if (physical_value.* != 0xA5A5_5A5A) pagingFailure("alias writeback");
    if ((cr0 & 0x8000_0000) == 0 or cr3 != page_directory) pagingFailure("control registers");

    writeAll("ZigOs i686 paging verified: CR3 0x");
    writeHex32(cr3);
    writeAll(" CR0 0x");
    writeHex32(cr0);
    writeAll(" identity-MiB 0x00000010 tables 0x00000004 alias 0x");
    writeHex32(alias_virtual);
    writeAll(" physical 0x");
    writeHex32(test_frame);
    writeAll(" value 0x");
    writeHex32(physical_value.*);
    writeAll(" free-frames 0x");
    writeHex32(free_frame_count);
    writeAll("\r\n");
    verifyHeap();
}

fn verifyHeap() void {
    const frame_count: u32 = 8;
    var frames: [8]u32 = undefined;
    for (&frames, 0..) |*frame, index| {
        frame.* = allocateFrame() orelse heapFailure("frame allocation");
        if (index != 0 and frame.* != frames[index - 1] + frame_size) heapFailure("noncontiguous frames");
        zeroPhysicalFrame(frame.*);
    }
    initializeHeap(frames[0], frame_count * frame_size);
    const free_before = heapFreePayloadBytes();

    const first = heapAllocate(64) orelse heapFailure("first allocation");
    const second = heapAllocate(1024) orelse heapFailure("second allocation");
    const third = heapAllocate(4096) orelse heapFailure("third allocation");
    fillBytes(first, 64, 0x11);
    fillBytes(second, 1024, 0x22);
    fillBytes(third, 4096, 0x33);
    if (!heapFree(second)) heapFailure("free second");
    const reused = heapAllocate(512) orelse heapFailure("reuse allocation");
    if (reused != second) heapFailure("first-fit reuse");
    fillBytes(reused, 512, 0x44);
    if (!bytesEqual(first, 64, 0x11) or !bytesEqual(third, 4096, 0x33)) heapFailure("sentinel corruption");
    if (!heapFree(reused) or !heapFree(first) or !heapFree(third)) heapFailure("final frees");
    if (heapFreePayloadBytes() != free_before) heapFailure("coalescing accounting");
    const head: *const HeapBlock = @ptrFromInt(heap_base);
    if (head.next_address != 0 or head.is_free != 1 or head.payload_bytes != free_before) heapFailure("single-block coalesce");

    writeAll("ZigOs i686 heap verified: base 0x");
    writeHex32(heap_base);
    writeAll(" bytes 0x");
    writeHex32(heap_bytes);
    writeAll(" free-before 0x");
    writeHex32(free_before);
    writeAll(" first 0x");
    writeHex32(first);
    writeAll(" second 0x");
    writeHex32(second);
    writeAll(" third 0x");
    writeHex32(third);
    writeAll(" reuse 0x");
    writeHex32(reused);
    writeAll(" coalesced 0x");
    writeHex32(head.payload_bytes);
    writeAll(" frames-left 0x");
    writeHex32(free_frame_count);
    writeAll("\r\n");
    verifyAta();
}

fn verifyFat12() void {
    const free_before = heapFreePayloadBytes();
    const buffer = heapAllocate(512) orelse fatFailure("sector buffer");
    const sector: [*]const volatile u8 = @ptrFromInt(buffer);

    if (!ataReadSector(0, buffer)) fatFailure("read MBR");
    const partition_offset: usize = 446;
    if (sector[partition_offset + 4] != 0x01) fatFailure("partition type");
    const volume_lba = readLe32(sector, partition_offset + 8);
    const partition_sectors = readLe32(sector, partition_offset + 12);
    if (volume_lba != 64 or partition_sectors != 2880) fatFailure("partition geometry");

    if (!ataReadSector(volume_lba, buffer)) fatFailure("read BPB");
    const bytes_per_sector = readLe16(sector, 11);
    const sectors_per_cluster = sector[13];
    const reserved_sectors = readLe16(sector, 14);
    const fat_count = sector[16];
    const root_entries = readLe16(sector, 17);
    const total_sectors = readLe16(sector, 19);
    const sectors_per_fat = readLe16(sector, 22);
    const hidden_sectors = readLe32(sector, 28);
    if (bytes_per_sector != 512 or sectors_per_cluster != 1 or reserved_sectors != 1 or
        fat_count != 2 or root_entries != 224 or total_sectors != 2880 or
        sectors_per_fat != 9 or hidden_sectors != volume_lba or sector[510] != 0x55 or sector[511] != 0xAA)
    {
        fatFailure("BPB contract");
    }

    const root_sectors: u32 = (@as(u32, root_entries) * 32 + bytes_per_sector - 1) / bytes_per_sector;
    const fat_start = volume_lba + reserved_sectors;
    const root_start = fat_start + @as(u32, fat_count) * sectors_per_fat;
    const data_start = root_start + root_sectors;
    fat_volume_lba = volume_lba;
    fat_start_lba = fat_start;
    fat_root_lba = root_start;
    fat_data_lba = data_start;
    fat_bytes_per_sector = bytes_per_sector;
    fat_sectors_per_cluster = sectors_per_cluster;
    var found = false;
    var file_size: u32 = 0;
    search: for (0..root_sectors) |sector_index| {
        if (!ataReadSector(root_start + @as(u32, @intCast(sector_index)), buffer)) fatFailure("read root");
        for (0..16) |entry_index| {
            const offset = entry_index * 32;
            const first = sector[offset];
            if (first == 0) break :search;
            if (first == 0xE5) continue;
            const attributes = sector[offset + 11];
            if (attributes == 0x0F or (attributes & 0x08) != 0) continue;
            if (!fatNameMatches(sector, offset, "HELLO   TXT")) continue;
            fat_file_cluster = readLe16(sector, offset + 26);
            file_size = readLe32(sector, offset + 28);
            found = true;
            break :search;
        }
    }
    if (!found or fat_file_cluster < 2 or file_size != expected_fat_file.len or file_size > fat_file_content.len) {
        fatFailure("HELLO.TXT root entry");
    }

    const fat_offset: u32 = @as(u32, fat_file_cluster) + @as(u32, fat_file_cluster) / 2;
    const fat_sector_lba = fat_start + fat_offset / bytes_per_sector;
    const fat_byte_offset: usize = @intCast(fat_offset % bytes_per_sector);
    if (fat_byte_offset >= 511 or !ataReadSector(fat_sector_lba, buffer)) fatFailure("read FAT");
    const pair = @as(u16, sector[fat_byte_offset]) | (@as(u16, sector[fat_byte_offset + 1]) << 8);
    const next_cluster: u16 = if ((fat_file_cluster & 1) == 0) pair & 0x0FFF else pair >> 4;
    if (next_cluster < 0x0FF8) fatFailure("multi-cluster chain not expected");

    const cluster_lba = data_start + (@as(u32, fat_file_cluster) - 2) * sectors_per_cluster;
    if (!ataReadSector(cluster_lba, buffer)) fatFailure("read file cluster");
    fat_file_length = @intCast(file_size);
    for (0..fat_file_length) |index| fat_file_content[index] = sector[index];
    if (!equalBytes(fat_file_content[0..fat_file_length], expected_fat_file)) fatFailure("file content");
    fat_file_hash = fnv1a32(fat_file_content[0..fat_file_length]);
    if (fat_file_hash != 0xA9F6_60F2) fatFailure("file hash");
    if (!heapFree(buffer) or heapFreePayloadBytes() != free_before) fatFailure("heap restoration");
    fat_ready = true;

    writeAll("ZigOs i686 FAT12 verified: volume-LBA 0x");
    writeHex32(volume_lba);
    writeAll(" sectors 0x");
    writeHex32(partition_sectors);
    writeAll(" bytes-sector 0x");
    writeHex32(bytes_per_sector);
    writeAll(" root-start 0x");
    writeHex32(root_start);
    writeAll(" data-start 0x");
    writeHex32(data_start);
    writeAll(" file HELLO.TXT cluster 0x");
    writeHex32(fat_file_cluster);
    writeAll(" bytes 0x");
    writeHex32(file_size);
    writeAll(" hash 0x");
    writeHex32(fat_file_hash);
    writeAll(" chain-end 0x");
    writeHex32(next_cluster);
    writeAll(" heap-restored yes\r\n");
    verifyPreemptiveScheduler();
}

fn verifyPreemptiveScheduler() void {
    scheduler_stacks = @splat(0);
    scheduler_current = 0;
    scheduler_switches = 0;
    scheduler_task_a_quanta = 0;
    scheduler_task_b_quanta = 0;
    scheduler_done = false;
    scheduler_stacks[1] = initializeKernelTask(&scheduler_stack_a, @intCast(@intFromPtr(&schedulerTaskA)));
    scheduler_stacks[2] = initializeKernelTask(&scheduler_stack_b, @intCast(@intFromPtr(&schedulerTaskB)));
    const start_ticks = timer_ticks;

    configurePic();
    configurePit100Hz();
    zigos_i686_out8(0x0021, 0xFE);
    scheduler_active = true;
    const done: *volatile bool = &scheduler_done;
    zigos_i686_enable_interrupts();
    while (!done.*) zigos_i686_halt();
    zigos_i686_disable_interrupts();
    zigos_i686_out8(0x0021, 0xFF);
    zigos_i686_out8(0x00A1, 0xFF);

    const elapsed = timer_ticks -% start_ticks;
    if (scheduler_active or scheduler_current != 0 or scheduler_task_a_quanta != 3 or
        scheduler_task_b_quanta != 3 or scheduler_switches != 7 or elapsed != 7)
    {
        schedulerFailure("preemption accounting");
    }

    writeAll("ZigOs i686 scheduler verified: policy round-robin tasks 0x00000003 task-a-quanta 0x");
    writeHex32(scheduler_task_a_quanta);
    writeAll(" task-b-quanta 0x");
    writeHex32(scheduler_task_b_quanta);
    writeAll(" switches 0x");
    writeHex32(scheduler_switches);
    writeAll(" tick-delta 0x");
    writeHex32(elapsed);
    writeAll(" bootstrap-restored yes\r\n");
    verifyRing3Isolation();
}

fn verifyRing3Isolation() void {
    installProtectedGdt();
    user_code_frame = allocateFrame() orelse ring3Failure("code frame");
    user_stack_frame = allocateFrame() orelse ring3Failure("stack frame");
    zeroPhysicalFrame(user_code_frame);
    zeroPhysicalFrame(user_stack_frame);

    const user_code_virtual: u32 = 0x0040_0000;
    const user_stack_virtual: u32 = 0x0040_2000;
    const directory: [*]volatile u32 = @ptrFromInt(kernel_page_directory);
    const table: [*]volatile u32 = @ptrFromInt(kernel_identity_tables[1]);
    directory[1] |= 0x004;
    table[0] = user_code_frame | 0x007;
    table[2] = user_stack_frame | 0x007;
    zigos_i686_invalidate_page(user_code_virtual);
    zigos_i686_invalidate_page(user_stack_virtual);

    const machine_code = [_]u8{
        0xC7, 0x05, 0x80, 0x00, 0x40, 0x00, 0xBE, 0xBA, 0xFE, 0xCA,
        0xB8, 0xDF, 0x9B, 0x57, 0x13, 0xCD, 0x30, 0xF4,
    };
    const code: [*]volatile u8 = @ptrFromInt(user_code_frame);
    for (machine_code, 0..) |byte, index| code[index] = byte;
    const sentinel: *volatile u32 = @ptrFromInt(user_code_frame + 0x80);
    sentinel.* = 0;

    const return_handler: u32 = @intCast(@intFromPtr(&zigos_i686_user_return_stub));
    setIdtGateAttributes(0x30, return_handler, 0xEE);
    user_return_eax = 0;
    user_return_cs = 0;
    user_return_ss = 0;
    user_return_esp = 0;
    zigos_i686_enter_user(user_code_virtual, user_stack_virtual);

    const kernel_table: [*]const volatile u32 = @ptrFromInt(kernel_identity_tables[0]);
    const kernel_pte = kernel_table[0x0001_0000 / frame_size];
    const user_code_pte = table[0];
    const user_stack_pte = table[2];
    const observed_tr = zigos_i686_read_tr();
    const observed_sentinel = sentinel.*;
    var failure_mask: u32 = 0;
    if (observed_tr != 0x28) failure_mask |= 1 << 0;
    if (observed_sentinel != 0xCAFE_BABE) failure_mask |= 1 << 1;
    if (user_return_eax != 0x1357_9BDF) failure_mask |= 1 << 2;
    if (user_return_cs != 0x1B) failure_mask |= 1 << 3;
    if (user_return_ss != 0x23) failure_mask |= 1 << 4;
    if (user_return_esp != user_stack_virtual) failure_mask |= 1 << 5;
    if ((kernel_pte & 0x004) != 0) failure_mask |= 1 << 6;
    if ((user_code_pte & 0x007) != 0x007) failure_mask |= 1 << 7;
    if ((user_stack_pte & 0x007) != 0x007) failure_mask |= 1 << 8;
    if (failure_mask != 0) {
        writeAll("ZigOs i686 ring3 failed: predicate-mask 0x");
        writeHex32(failure_mask);
        writeAll("\r\n");
        haltForever();
    }

    writeAll("ZigOs i686 ring3 verified: GDT entries 0x00000006 TSS selector 0x00000028 CS 0x");
    writeHex32(user_return_cs);
    writeAll(" SS 0x");
    writeHex32(user_return_ss);
    writeAll(" user-ESP 0x");
    writeHex32(user_return_esp);
    writeAll(" code 0x00400000 stack 0x00402000 sentinel 0x");
    writeHex32(sentinel.*);
    writeAll(" kernel-user-bit no user-pages yes\r\n");
    verifySyscallAbi();
}

fn verifySyscallAbi() void {
    const code: [*]volatile u8 = @ptrFromInt(user_code_frame);
    var index: usize = 0;
    while (index < 512) : (index += 1) code[index] = 0;
    const program = [_]u8{
        0xB8, 0x01, 0x00, 0x00, 0x00,
        0xBB, 0x00, 0x01, 0x40, 0x00,
        0xB9, 0x25, 0x00, 0x00, 0x00,
        0xCD, 0x80, 0xB8, 0x01, 0x00,
        0x00, 0x00, 0xBB, 0x00, 0x00,
        0x01, 0x00, 0xB9, 0x04, 0x00,
        0x00, 0x00, 0xCD, 0x80, 0xA3,
        0x88, 0x00, 0x40, 0x00, 0xB8,
        0x02, 0x00, 0x00, 0x00, 0xCD,
        0x80, 0xA3, 0x84, 0x00, 0x40,
        0x00, 0xB8, 0x03, 0x00, 0x00,
        0x00, 0xBB, 0x2A, 0x00, 0x00,
        0x00, 0xCD, 0x80, 0xF4,
    };
    for (program, 0..) |byte, offset| code[offset] = byte;
    const message = "ZigOs ring3 syscall write verified.\r\n";
    for (message, 0..) |byte, offset| code[0x100 + offset] = byte;

    syscall_count = 0;
    syscall_write_bytes = 0;
    syscall_rejected = 0;
    syscall_exit_code = 0;
    syscall_exited = false;
    setIdtGateAttributes(0x80, @intCast(@intFromPtr(&zigos_i686_syscall_stub)), 0xEE);
    zigos_i686_invalidate_page(0x0040_0000);
    zigos_i686_enter_user(0x0040_0000, 0x0040_2000);

    const pid_result: *const volatile u32 = @ptrFromInt(user_code_frame + 0x84);
    const rejected_result: *const volatile u32 = @ptrFromInt(user_code_frame + 0x88);
    if (syscall_count != 4 or syscall_write_bytes != message.len or syscall_rejected != 1 or
        syscall_exit_code != 42 or !syscall_exited or pid_result.* != 1 or rejected_result.* != 0xFFFF_FFF2)
    {
        syscallFailure("ABI accounting");
    }

    writeAll("ZigOs i686 syscalls verified: vector 0x00000080 calls 0x");
    writeHex32(syscall_count);
    writeAll(" write-bytes 0x");
    writeHex32(syscall_write_bytes);
    writeAll(" getpid 0x");
    writeHex32(pid_result.*);
    writeAll(" rejected 0x");
    writeHex32(syscall_rejected);
    writeAll(" errno 0x");
    writeHex32(rejected_result.*);
    writeAll(" exit-code 0x");
    writeHex32(syscall_exit_code);
    writeAll(" kernel-pointer-denied yes\r\n");
    verifyElfLoader();
}

fn verifyElfLoader() void {
    const free_before = heapFreePayloadBytes();
    const buffer = heapAllocate(512) orelse elfFailure("sector buffer");
    const sector: [*]const volatile u8 = @ptrFromInt(buffer);
    var cluster: u16 = 0;
    var file_size: u32 = 0;
    var found = false;
    search: for (0..14) |sector_index| {
        if (!ataReadSector(fat_root_lba + @as(u32, @intCast(sector_index)), buffer)) elfFailure("read root");
        for (0..16) |entry_index| {
            const offset = entry_index * 32;
            if (sector[offset] == 0) break :search;
            if (sector[offset] == 0xE5 or sector[offset + 11] == 0x0F) continue;
            if (!fatNameMatches(sector, offset, "INIT    ELF")) continue;
            cluster = readLe16(sector, offset + 26);
            file_size = readLe32(sector, offset + 28);
            found = true;
            break :search;
        }
    }
    if (!found or cluster != 3 or file_size > 512 or file_size < 84) elfFailure("INIT.ELF root entry");
    const cluster_lba = fat_data_lba + (@as(u32, cluster) - 2) * fat_sectors_per_cluster;
    if (!ataReadSector(cluster_lba, buffer)) elfFailure("read INIT.ELF");
    if (sector[0] != 0x7F or sector[1] != 'E' or sector[2] != 'L' or sector[3] != 'F' or
        sector[4] != 1 or sector[5] != 1 or sector[6] != 1 or readLe16(sector, 16) != 2 or
        readLe16(sector, 18) != 3 or readLe32(sector, 20) != 1)
    {
        elfFailure("ELF identity");
    }
    const entry = readLe32(sector, 24);
    const phoff = readLe32(sector, 28);
    const ehsize = readLe16(sector, 40);
    const phentsize = readLe16(sector, 42);
    const phnum = readLe16(sector, 44);
    if (entry != 0x0040_0000 or phoff != 52 or ehsize != 52 or phentsize != 32 or phnum != 1) {
        elfFailure("ELF header geometry");
    }
    const ph: usize = @intCast(phoff);
    const segment_type = readLe32(sector, ph);
    const file_offset = readLe32(sector, ph + 4);
    const virtual_address = readLe32(sector, ph + 8);
    const file_bytes = readLe32(sector, ph + 16);
    const memory_bytes = readLe32(sector, ph + 20);
    const flags = readLe32(sector, ph + 24);
    if (segment_type != 1 or file_offset != 0x100 or virtual_address != 0x0040_0000 or
        file_bytes == 0 or memory_bytes < file_bytes or memory_bytes > 4096 or
        file_offset + file_bytes > file_size or flags != 5)
    {
        elfFailure("PT_LOAD contract");
    }

    zeroPhysicalFrame(user_code_frame);
    const destination: [*]volatile u8 = @ptrFromInt(user_code_frame);
    for (0..file_bytes) |offset| destination[offset] = sector[file_offset + offset];
    const bss_last: *const volatile u8 = @ptrFromInt(user_code_frame + memory_bytes - 1);
    if (bss_last.* != 0) elfFailure("BSS zero fill");
    init_elf_size = file_size;
    init_elf_entry = entry;
    init_elf_filesz = file_bytes;
    init_elf_memsz = memory_bytes;
    const file_slice: [*]const u8 = @ptrFromInt(buffer);
    init_elf_hash = fnv1a32(file_slice[0..file_size]);

    syscall_count = 0;
    syscall_write_bytes = 0;
    syscall_rejected = 0;
    syscall_exit_code = 0;
    syscall_exited = false;
    zigos_i686_invalidate_page(0x0040_0000);
    zigos_i686_enter_user(entry, 0x0040_2000);
    const pid_result: *const volatile u32 = @ptrFromInt(user_code_frame + 0x70);
    init_elf_exit = syscall_exit_code;
    if (syscall_count != 3 or syscall_write_bytes != 39 or syscall_rejected != 0 or
        !syscall_exited or syscall_exit_code != 0x33 or pid_result.* != 1 or bss_last.* != 0)
    {
        elfFailure("INIT execution");
    }
    if (!heapFree(buffer) or heapFreePayloadBytes() != free_before) elfFailure("heap restoration");

    writeAll("ZigOs i686 ELF verified: file INIT.ELF cluster 0x00000003 bytes 0x");
    writeHex32(file_size);
    writeAll(" entry 0x");
    writeHex32(entry);
    writeAll(" PT_LOAD-filesz 0x");
    writeHex32(file_bytes);
    writeAll(" memsz 0x");
    writeHex32(memory_bytes);
    writeAll(" flags 0x");
    writeHex32(flags);
    writeAll(" pid 0x");
    writeHex32(pid_result.*);
    writeAll(" exit 0x");
    writeHex32(syscall_exit_code);
    writeAll(" BSS-zero yes heap-restored yes\r\n");
    runShell();
}

fn elfFailure(reason: []const u8) noreturn {
    writeAll("ZigOs i686 ELF failed: ");
    writeAll(reason);
    writeAll("\r\n");
    haltForever();
}

fn syscallFailure(reason: []const u8) noreturn {
    writeAll("ZigOs i686 syscalls failed: ");
    writeAll(reason);
    writeAll("\r\n");
    haltForever();
}

fn installProtectedGdt() void {
    kernel_gdt = @splat(@splat(0));
    writeGdtDescriptor(&kernel_gdt[1], 0, 0x000F_FFFF, 0x9A, 0xCF);
    writeGdtDescriptor(&kernel_gdt[2], 0, 0x000F_FFFF, 0x92, 0xCF);
    writeGdtDescriptor(&kernel_gdt[3], 0, 0x000F_FFFF, 0xFA, 0xCF);
    writeGdtDescriptor(&kernel_gdt[4], 0, 0x000F_FFFF, 0xF2, 0xCF);
    kernel_tss = .{};
    kernel_tss.esp0 = @intCast(@intFromPtr(&user_transition_stack) + user_transition_stack.len);
    kernel_tss.ss0 = 0x10;
    kernel_tss.trap_iomap = @as(u32, @sizeOf(Tss)) << 16;
    writeGdtDescriptor(&kernel_gdt[5], @intCast(@intFromPtr(&kernel_tss)), @sizeOf(Tss) - 1, 0x89, 0x00);
    const base: u32 = @intCast(@intFromPtr(&kernel_gdt));
    const limit: u16 = @intCast(@sizeOf(@TypeOf(kernel_gdt)) - 1);
    const descriptor = [6]u8{
        @truncate(limit),      @truncate(limit >> 8),
        @truncate(base),       @truncate(base >> 8),
        @truncate(base >> 16), @truncate(base >> 24),
    };
    zigos_i686_load_gdt(&descriptor);
    zigos_i686_load_tr(0x28);
}

fn writeGdtDescriptor(entry: *[8]u8, base: u32, limit: u32, access: u8, flags: u8) void {
    entry[0] = @truncate(limit);
    entry[1] = @truncate(limit >> 8);
    entry[2] = @truncate(base);
    entry[3] = @truncate(base >> 8);
    entry[4] = @truncate(base >> 16);
    entry[5] = access;
    entry[6] = @truncate((limit >> 16) & 0x0F);
    entry[6] |= flags & 0xF0;
    entry[7] = @truncate(base >> 24);
}

fn ring3Failure(reason: []const u8) noreturn {
    writeAll("ZigOs i686 ring3 failed: ");
    writeAll(reason);
    writeAll("\r\n");
    haltForever();
}

fn initializeKernelTask(stack: *[4096]u8, entry: u32) u32 {
    const top = @intFromPtr(stack) + stack.len;
    const context_address: u32 = @intCast(top - @sizeOf(InterruptContext));
    const context: *InterruptContext = @ptrFromInt(context_address);
    context.* = .{
        .edi = 0,
        .esi = 0,
        .ebp = 0,
        .interrupted_esp = 0,
        .ebx = 0,
        .edx = 0,
        .ecx = 0,
        .eax = 0,
        .eip = entry,
        .cs = 0x0008,
        .eflags = 0x0000_0202,
    };
    return context_address;
}

fn schedulerTaskA() callconv(.c) noreturn {
    while (true) {
        scheduler_task_a_quanta +|= 1;
        zigos_i686_halt();
    }
}

fn schedulerTaskB() callconv(.c) noreturn {
    while (true) {
        scheduler_task_b_quanta +|= 1;
        zigos_i686_halt();
    }
}

fn schedulerFailure(reason: []const u8) noreturn {
    scheduler_active = false;
    zigos_i686_disable_interrupts();
    writeAll("ZigOs i686 scheduler failed: ");
    writeAll(reason);
    writeAll("\r\n");
    haltForever();
}

fn runShell() noreturn {
    if (!ata_ready or !fat_ready or !heap_ready or !frame_allocator_ready) shellFailure("subsystems unavailable");
    writeAll("ZigOs i686 shell ready: prompt zigos> commands help mem ticks disk cat HELLO.TXT exit\r\n");
    var line: [64]u8 = undefined;
    while (true) {
        writeAll("zigos> ");
        const length = readShellLine(&line);
        const command = line[0..length];
        if (command.len == 0) continue;
        if (equalBytes(command, "help")) {
            shell_command_count +|= 1;
            writeAll("commands: help mem ticks disk cat HELLO.TXT exit\r\n");
        } else if (equalBytes(command, "mem")) {
            shell_command_count +|= 1;
            writeAll("frames-free 0x");
            writeHex32(free_frame_count);
            writeAll(" heap-free 0x");
            writeHex32(heapFreePayloadBytes());
            writeAll(" heap-base 0x");
            writeHex32(heap_base);
            writeAll("\r\n");
        } else if (equalBytes(command, "ticks")) {
            shell_command_count +|= 1;
            writeAll("ticks 0x");
            writeHex32(timer_ticks);
            writeAll(" PIT-Hz 0x00000064\r\n");
        } else if (equalBytes(command, "disk")) {
            shell_command_count +|= 1;
            writeAll("model ");
            writeAll(ata_model[0..ata_model_length]);
            writeAll(" sectors 0x");
            writeHex32(ata_sector_count);
            writeAll(" FAT12 ");
            writeAll(if (fat_ready) "yes" else "no");
            writeAll(" HELLO.TXT-bytes 0x");
            writeHex32(@as(u32, @intCast(fat_file_length)));
            writeAll("\r\n");
        } else if (equalBytes(command, "cat HELLO.TXT")) {
            shell_command_count +|= 1;
            writeAll(fat_file_content[0..fat_file_length]);
        } else if (equalBytes(command, "exit")) {
            writeAll("ZigOs i686 shell verified: commands 0x");
            writeHex32(shell_command_count);
            writeAll(" unknown 0x");
            writeHex32(shell_unknown_count);
            writeAll(" exit yes\r\n");
            haltForever();
        } else {
            shell_unknown_count +|= 1;
            writeAll("unknown command: ");
            writeAll(command);
            writeAll("\r\n");
        }
    }
}

fn readShellLine(buffer: *[64]u8) usize {
    var length: usize = 0;
    while (true) {
        while ((zigos_i686_in8(0x03FD) & 0x01) == 0) asm volatile ("pause");
        const character = zigos_i686_in8(0x03F8);
        if (character == '\r' or character == '\n') {
            writeAll("\r\n");
            return length;
        }
        if (character == 0x08 or character == 0x7F) {
            if (length != 0) {
                length -= 1;
                writeAll("\x08 \x08");
            }
            continue;
        }
        if (character < 0x20 or character > 0x7E) continue;
        if (length >= buffer.len) {
            writeAll("\r\nline too long\r\n");
            return 0;
        }
        buffer[length] = character;
        length += 1;
        writeAll(&[_]u8{character});
    }
}

fn shellFailure(reason: []const u8) noreturn {
    writeAll("ZigOs i686 shell failed: ");
    writeAll(reason);
    writeAll("\r\n");
    haltForever();
}

fn readLe16(bytes: [*]const volatile u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn readLe32(bytes: [*]const volatile u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn fatNameMatches(bytes: [*]const volatile u8, offset: usize, expected: []const u8) bool {
    if (expected.len != 11) return false;
    for (expected, 0..) |value, index| if (bytes[offset + index] != value) return false;
    return true;
}

fn equalBytes(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}

fn fnv1a32(bytes: []const u8) u32 {
    var hash: u32 = 0x811C_9DC5;
    for (bytes) |byte| hash = (hash ^ byte) *% 0x0100_0193;
    return hash;
}

fn fatFailure(reason: []const u8) noreturn {
    writeAll("ZigOs i686 FAT12 failed: ");
    writeAll(reason);
    writeAll("\r\n");
    haltForever();
}

const ata_data_port: u16 = 0x01F0;
const ata_sector_count_port: u16 = 0x01F2;
const ata_lba_low_port: u16 = 0x01F3;
const ata_lba_mid_port: u16 = 0x01F4;
const ata_lba_high_port: u16 = 0x01F5;
const ata_drive_port: u16 = 0x01F6;
const ata_status_command_port: u16 = 0x01F7;
const ata_alternate_status_port: u16 = 0x03F6;

fn verifyAta() void {
    var identify: [256]u16 = undefined;
    if (!ataIdentify(&identify)) ataFailure("IDENTIFY");
    if ((identify[49] & (1 << 9)) == 0) ataFailure("LBA28 unsupported");
    ata_sector_count = @as(u32, identify[60]) | (@as(u32, identify[61]) << 16);
    if (ata_sector_count < 10) ataFailure("capacity too small");
    parseAtaModel(&identify);

    const free_before = heapFreePayloadBytes();
    const buffer = heapAllocate(512) orelse ataFailure("sector buffer");
    if (!ataReadSector(0, buffer)) ataFailure("read MBR");
    const bytes: [*]const volatile u8 = @ptrFromInt(buffer);
    if (bytes[510] != 0x55 or bytes[511] != 0xAA) ataFailure("MBR signature");
    if (!ataReadSector(9, buffer)) ataFailure("read kernel LBA");
    const kernel: [*]const volatile u8 = @ptrFromInt(0x0001_0000);
    for (0..512) |index| if (bytes[index] != kernel[index]) ataFailure("kernel sector mismatch");
    if (!heapFree(buffer) or heapFreePayloadBytes() != free_before) ataFailure("heap restoration");
    ata_ready = true;

    writeAll("ZigOs i686 ATA verified: primary-master yes model ");
    writeAll(ata_model[0..ata_model_length]);
    writeAll(" LBA28 yes sectors 0x");
    writeHex32(ata_sector_count);
    writeAll(" MBR 0x55AA kernel-LBA 0x00000009 sector-match yes buffer 0x");
    writeHex32(buffer);
    writeAll(" heap-restored yes\r\n");
    verifyFat12();
}

fn ataIdentify(destination: *[256]u16) bool {
    zigos_i686_out8(ata_drive_port, 0xA0);
    ataDelay();
    zigos_i686_out8(ata_sector_count_port, 0);
    zigos_i686_out8(ata_lba_low_port, 0);
    zigos_i686_out8(ata_lba_mid_port, 0);
    zigos_i686_out8(ata_lba_high_port, 0);
    zigos_i686_out8(ata_status_command_port, 0xEC);
    if (zigos_i686_in8(ata_status_command_port) == 0) return false;
    if (!ataWaitReady()) return false;
    if (zigos_i686_in8(ata_lba_mid_port) != 0 or zigos_i686_in8(ata_lba_high_port) != 0) return false;
    if (!ataWaitData()) return false;
    for (destination) |*word| word.* = zigos_i686_in16(ata_data_port);
    return true;
}

fn ataReadSector(lba: u32, destination_address: u32) bool {
    if (ata_sector_count != 0 and lba >= ata_sector_count) return false;
    if (lba >= 0x1000_0000) return false;
    zigos_i686_out8(ata_drive_port, 0xE0 | @as(u8, @truncate(lba >> 24)));
    ataDelay();
    zigos_i686_out8(ata_sector_count_port, 1);
    zigos_i686_out8(ata_lba_low_port, @truncate(lba));
    zigos_i686_out8(ata_lba_mid_port, @truncate(lba >> 8));
    zigos_i686_out8(ata_lba_high_port, @truncate(lba >> 16));
    zigos_i686_out8(ata_status_command_port, 0x20);
    if (!ataWaitData()) return false;
    const destination: [*]volatile u8 = @ptrFromInt(destination_address);
    for (0..256) |index| {
        const word = zigos_i686_in16(ata_data_port);
        destination[index * 2] = @truncate(word);
        destination[index * 2 + 1] = @truncate(word >> 8);
    }
    return true;
}

fn ataWaitReady() bool {
    var remaining: u32 = 1_000_000;
    while (remaining != 0) : (remaining -= 1) {
        const status = zigos_i686_in8(ata_status_command_port);
        if ((status & 0x80) == 0) return (status & 0x21) == 0;
    }
    return false;
}

fn ataWaitData() bool {
    var remaining: u32 = 1_000_000;
    while (remaining != 0) : (remaining -= 1) {
        const status = zigos_i686_in8(ata_status_command_port);
        if ((status & 0x21) != 0) return false;
        if ((status & 0x88) == 0x08) return true;
    }
    return false;
}

fn ataDelay() void {
    _ = zigos_i686_in8(ata_alternate_status_port);
    _ = zigos_i686_in8(ata_alternate_status_port);
    _ = zigos_i686_in8(ata_alternate_status_port);
    _ = zigos_i686_in8(ata_alternate_status_port);
}

fn parseAtaModel(identify: *const [256]u16) void {
    for (0..20) |index| {
        const word = identify[27 + index];
        ata_model[index * 2] = @truncate(word >> 8);
        ata_model[index * 2 + 1] = @truncate(word);
    }
    ata_model_length = ata_model.len;
    while (ata_model_length != 0 and (ata_model[ata_model_length - 1] == ' ' or ata_model[ata_model_length - 1] == 0)) {
        ata_model_length -= 1;
    }
    if (ata_model_length == 0) ataFailure("empty model");
}

fn ataFailure(reason: []const u8) noreturn {
    writeAll("ZigOs i686 ATA failed: ");
    writeAll(reason);
    writeAll("\r\n");
    haltForever();
}

fn initializeHeap(base: u32, bytes: u32) void {
    if ((base & 0xF) != 0 or bytes <= @sizeOf(HeapBlock)) heapFailure("invalid heap range");
    heap_base = base;
    heap_bytes = bytes;
    const head: *HeapBlock = @ptrFromInt(base);
    head.* = .{
        .payload_bytes = bytes - @sizeOf(HeapBlock),
        .next_address = 0,
        .is_free = 1,
        .reserved = 0,
    };
    heap_ready = true;
}

fn heapAllocate(requested_bytes: u32) ?u32 {
    if (!heap_ready or requested_bytes == 0) return null;
    const aligned = alignUp16(requested_bytes);
    var address = heap_base;
    while (address != 0) {
        const block: *HeapBlock = @ptrFromInt(address);
        if (block.is_free == 1 and block.payload_bytes >= aligned) {
            const remaining = block.payload_bytes - aligned;
            if (remaining >= @sizeOf(HeapBlock) + 16) {
                const split_address = address + @sizeOf(HeapBlock) + aligned;
                const split: *HeapBlock = @ptrFromInt(split_address);
                split.* = .{
                    .payload_bytes = remaining - @sizeOf(HeapBlock),
                    .next_address = block.next_address,
                    .is_free = 1,
                    .reserved = 0,
                };
                block.next_address = split_address;
                block.payload_bytes = aligned;
            }
            block.is_free = 0;
            return address + @sizeOf(HeapBlock);
        }
        address = block.next_address;
    }
    return null;
}

fn heapFree(payload_address: u32) bool {
    if (!heap_ready or payload_address < heap_base + @sizeOf(HeapBlock) or payload_address >= heap_base + heap_bytes) return false;
    var previous_address: u32 = 0;
    var address = heap_base;
    while (address != 0) {
        const block: *HeapBlock = @ptrFromInt(address);
        if (address + @sizeOf(HeapBlock) == payload_address) {
            if (block.is_free == 1) return false;
            block.is_free = 1;
            coalesceNext(block);
            if (previous_address != 0) {
                const previous: *HeapBlock = @ptrFromInt(previous_address);
                if (previous.is_free == 1) coalesceNext(previous);
            }
            return true;
        }
        previous_address = address;
        address = block.next_address;
    }
    return false;
}

fn coalesceNext(block: *HeapBlock) void {
    while (block.next_address != 0) {
        const next: *HeapBlock = @ptrFromInt(block.next_address);
        if (next.is_free != 1) return;
        block.payload_bytes +|= @sizeOf(HeapBlock) + next.payload_bytes;
        block.next_address = next.next_address;
    }
}

fn heapFreePayloadBytes() u32 {
    var total: u32 = 0;
    var address = heap_base;
    while (address != 0) {
        const block: *const HeapBlock = @ptrFromInt(address);
        if (block.is_free == 1) total +|= block.payload_bytes;
        address = block.next_address;
    }
    return total;
}

fn alignUp16(value: u32) u32 {
    return (value +| 15) & ~@as(u32, 15);
}

fn fillBytes(address: u32, count: usize, value: u8) void {
    const bytes: [*]volatile u8 = @ptrFromInt(address);
    for (0..count) |index| bytes[index] = value;
}

fn bytesEqual(address: u32, count: usize, value: u8) bool {
    const bytes: [*]const volatile u8 = @ptrFromInt(address);
    for (0..count) |index| if (bytes[index] != value) return false;
    return true;
}

fn heapFailure(reason: []const u8) noreturn {
    writeAll("ZigOs i686 heap failed: ");
    writeAll(reason);
    writeAll("\r\n");
    haltForever();
}

fn zeroPhysicalFrame(address: u32) void {
    const words: [*]volatile u32 = @ptrFromInt(address);
    for (0..1024) |index| words[index] = 0;
}

fn pagingFailure(reason: []const u8) noreturn {
    writeAll("ZigOs i686 paging failed: ");
    writeAll(reason);
    writeAll("\r\n");
    haltForever();
}

fn initializeFrameAllocator() void {
    @memset(frame_bitmap[0..], 0xFF);
    free_frame_count = 0;
    const info: *const BootInfo = @ptrFromInt(boot_info_address);
    const entries: [*]const E820Entry = @ptrFromInt(info.e820_entries_address);
    for (0..info.e820_entry_count) |index| {
        const entry = entries[index];
        if (entry.kind != 1 or entry.length == 0) continue;
        const raw_end = entry.base +| entry.length;
        const bounded_start = if (entry.base < managed_memory_limit) entry.base else managed_memory_limit;
        const bounded_end = if (raw_end < managed_memory_limit) raw_end else managed_memory_limit;
        var start: u32 = @intCast(bounded_start);
        var end: u32 = @intCast(bounded_end);
        start = alignUpFrame(start);
        end &= ~(frame_size - 1);
        while (start < end) : (start += frame_size) markFrameFree(start / frame_size);
    }
    reserveFrameRange(0, 0x0010_0000);
    frame_allocator_ready = true;
}

fn allocateFrame() ?u32 {
    if (!frame_allocator_ready) return null;
    var index: usize = 0x0010_0000 / frame_size;
    while (index < managed_frame_count) : (index += 1) {
        if (frameIsFree(index)) {
            markFrameUsed(index);
            return @intCast(index * frame_size);
        }
    }
    return null;
}

fn freeFrame(address: u32) bool {
    if (!frame_allocator_ready or address < 0x0010_0000 or address >= managed_memory_limit or
        (address & (frame_size - 1)) != 0)
    {
        return false;
    }
    const index: usize = @intCast(address / frame_size);
    if (frameIsFree(index)) return false;
    markFrameFree(index);
    return true;
}

fn reserveFrameRange(start_address: u32, end_address: u32) void {
    var address = start_address & ~(frame_size - 1);
    const end = alignUpFrame(end_address);
    while (address < end and address < managed_memory_limit) : (address += frame_size) {
        markFrameUsed(@intCast(address / frame_size));
    }
}

fn frameIsFree(index: usize) bool {
    return (frame_bitmap[index / 8] & (@as(u8, 1) << @intCast(index & 7))) == 0;
}

fn markFrameFree(index_value: anytype) void {
    const index: usize = @intCast(index_value);
    const mask = @as(u8, 1) << @intCast(index & 7);
    if ((frame_bitmap[index / 8] & mask) != 0) {
        frame_bitmap[index / 8] &= ~mask;
        free_frame_count +|= 1;
    }
}

fn markFrameUsed(index: usize) void {
    const mask = @as(u8, 1) << @intCast(index & 7);
    if ((frame_bitmap[index / 8] & mask) == 0) {
        frame_bitmap[index / 8] |= mask;
        free_frame_count -|= 1;
    }
}

fn alignUpFrame(value: u32) u32 {
    return (value +| (frame_size - 1)) & ~(frame_size - 1);
}

fn frameAllocatorFailure(reason: []const u8) noreturn {
    writeAll("ZigOs i686 frame allocator failed: ");
    writeAll(reason);
    writeAll("\r\n");
    haltForever();
}

fn injectPs2Scancode(scancode: u8) void {
    waitPs2InputReady();
    zigos_i686_out8(0x0064, 0xD2);
    waitPs2InputReady();
    zigos_i686_out8(0x0060, scancode);
}

fn waitPs2InputReady() void {
    var remaining: u32 = 100_000;
    while (remaining != 0) : (remaining -= 1) {
        if ((zigos_i686_in8(0x0064) & 0x02) == 0) return;
    }
    writeAll("ZigOs i686 keyboard failed: controller input busy\r\n");
    haltForever();
}

fn setIdtGate(vector: usize, handler: u32) void {
    setIdtGateAttributes(vector, handler, 0x8E);
}

fn setIdtGateAttributes(vector: usize, handler: u32, attributes: u8) void {
    idt[vector] = .{
        .offset_low = @truncate(handler),
        .selector = 0x0008,
        .zero = 0,
        .attributes = attributes,
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
    zigos_i686_out8(0x0021, 0xFC);
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
