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
const expected_big_bytes: u32 = 1300;
const expected_big_hash: u32 = 0xE5D1_20DF;
const expected_notes_bytes: u32 = 720;
const expected_notes_hash: u32 = 0xC618_1D2F;
const notes_suffix = "APPEND-PERSIST-OK!\r\n";
const vfs_open_read: u8 = 0x01;
const vfs_open_write: u8 = 0x02;
const vfs_open_create: u8 = 0x04;
const vfs_open_truncate: u8 = 0x08;
const vfs_open_append: u8 = 0x10;
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
    kernel_checksum16: u16,
    kernel_address: u32,
    kernel_bytes: u32,
    kernel_sectors: u16,
    fat_partition_lba: u16,
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

const VfsNode = struct {
    name: [11]u8 = @splat(' '),
    cluster: u16 = 0,
    size: u32 = 0,
    root_lba: u32 = 0,
    root_offset: u16 = 0,
    attributes: u8 = 0,
    present: bool = false,
};

const VfsDescriptor = struct {
    node_index: u8 = 0,
    flags: u8 = 0,
    offset: u32 = 0,
    owner_pid: u32 = 0,
    open: bool = false,
};

const ProcessState = enum(u8) {
    free,
    running,
    exited,
    faulted,
};

const ProcessRecord = struct {
    pid: u32 = 0,
    parent_pid: u32 = 0,
    name: [11]u8 = @splat(' '),
    exit_code: u32 = 0,
    fault_vector: u32 = 0,
    fault_address: u32 = 0,
    waited: bool = false,
    state: ProcessState = .free,
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
extern var zigos_i686_entry_checksum_ok: u32;
extern var zigos_i686_entry_checksum_observed: u32;
extern fn zigos_i686_read_cr0() callconv(.c) u32;
extern fn zigos_i686_read_cr3() callconv(.c) u32;
extern fn zigos_i686_read_cr2() callconv(.c) u32;
extern fn zigos_i686_write_cr3(page_directory: u32) callconv(.c) void;
extern fn zigos_i686_enable_paging(page_directory: u32) callconv(.c) void;
extern fn zigos_i686_invalidate_page(address: u32) callconv(.c) void;
extern fn zigos_i686_cpuid_vendor(destination: [*]u8) callconv(.c) u32;
extern fn zigos_i686_out8(port: u16, value: u8) callconv(.c) void;
extern fn zigos_i686_out16(port: u16, value: u16) callconv(.c) void;
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
var cat_elf_size: u32 = 0;
var writer_elf_size: u32 = 0;
var fault_elf_size: u32 = 0;
var big_file_size: u32 = 0;
var vfs_nodes: [16]VfsNode = @splat(.{});
var vfs_node_count: u32 = 0;
var vfs_descriptors: [8]VfsDescriptor = @splat(.{});
var vfs_sector_buffer: [512]u8 align(16) = @splat(0);
var vfs_aux_buffer: [512]u8 align(16) = @splat(0);
var vfs_root_buffer: [512]u8 align(16) = @splat(0);
var vfs_large_buffer: [4096]u8 align(16) = @splat(0);
var ata_verify_buffer: [512]u8 align(16) = @splat(0);
var vfs_open_count: u32 = 0;
var vfs_read_count: u32 = 0;
var vfs_write_count: u32 = 0;
var vfs_seek_count: u32 = 0;
var vfs_close_count: u32 = 0;
var vfs_create_count: u32 = 0;
var vfs_truncate_count: u32 = 0;
var fat_allocation_count: u32 = 0;
var fat_free_count: u32 = 0;
var fat_entry_write_count: u32 = 0;
var ata_write_count: u32 = 0;
var fat_sectors_per_fat: u16 = 0;
var fat_root_sectors: u16 = 0;
var fat_cluster_count: u16 = 0;
var notes_present_at_boot = false;
var notes_cluster: u16 = 0;
var notes_hash: u32 = 0;
var process_table: [16]ProcessRecord = @splat(.{});
var process_count: u32 = 0;
var next_pid: u32 = 2;
var current_pid: u32 = 1;
var last_spawned_pid: u32 = 0;
var process_wait_count: u32 = 0;
var last_waited_pid: u32 = 0;
var process_faulted = false;
var process_fault_vector: u32 = 0;
var process_fault_address: u32 = 0;
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
var user_scheduler_stacks: [3]u32 = @splat(0);
var user_scheduler_cr3: [3]u32 = @splat(0);
var user_scheduler_kernel_tops: [3]u32 = @splat(0);
var user_scheduler_quanta: [3]u32 = @splat(0);
var user_scheduler_current: u32 = 0;
var user_scheduler_switches: u32 = 0;
var user_scheduler_active = false;
var user_scheduler_done = false;
var user_scheduler_kernel_stack_a: [4096]u8 align(16) = @splat(0);
var user_scheduler_kernel_stack_b: [4096]u8 align(16) = @splat(0);
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
var syscall_file_opens: u32 = 0;
var syscall_file_reads: u32 = 0;
var syscall_file_read_bytes: u32 = 0;
var syscall_file_writes: u32 = 0;
var syscall_file_write_bytes: u32 = 0;
var syscall_file_seeks: u32 = 0;
var syscall_file_closes: u32 = 0;
var syscall_exit_cleanup_closes: u32 = 0;
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

pub export fn zigos_i686_exception_dispatch(frame: *const TrapFrame) callconv(.c) u32 {
    if (frame.vector == 3 and (frame.cs & 3) == 0) {
        exception_count +|= 1;
        last_exception_vector = frame.vector;
        last_exception_error = frame.error_code;
        last_exception_eip = frame.eip;
        return 0;
    }
    if ((frame.cs & 3) == 3 and current_pid != 0) {
        process_faulted = true;
        process_fault_vector = frame.vector;
        process_fault_address = if (frame.vector == 14) zigos_i686_read_cr2() else frame.eip;
        syscall_exit_cleanup_closes = vfsCloseAllOwned(current_pid);
        return 1;
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
    if (user_scheduler_active) {
        user_scheduler_stacks[user_scheduler_current] = current_esp;
        if (user_scheduler_current != 0) user_scheduler_quanta[user_scheduler_current] +|= 1;
        if (user_scheduler_quanta[1] >= 3 and user_scheduler_quanta[2] >= 3) {
            user_scheduler_active = false;
            user_scheduler_done = true;
            user_scheduler_current = 0;
            user_scheduler_switches +|= 1;
            current_pid = 0;
            kernel_tss.esp0 = user_scheduler_kernel_tops[0];
            zigos_i686_write_cr3(user_scheduler_cr3[0]);
            return user_scheduler_stacks[0];
        }

        const next: u32 = if (user_scheduler_current == 1) 2 else 1;
        user_scheduler_current = next;
        user_scheduler_switches +|= 1;
        current_pid = next + 1;
        kernel_tss.esp0 = user_scheduler_kernel_tops[next];
        zigos_i686_write_cr3(user_scheduler_cr3[next]);
        return user_scheduler_stacks[next];
    }
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
            const bytes = userReadableSlice(frame.ebx, frame.ecx, 2048) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            writeAll(bytes);
            syscall_write_bytes +|= frame.ecx;
            frame.eax = frame.ecx;
            return 0;
        },
        2 => {
            frame.eax = current_pid;
            return 0;
        },
        3 => {
            syscall_exit_code = frame.ebx;
            syscall_exited = true;
            syscall_exit_cleanup_closes = vfsCloseAllOwned(current_pid);
            return 1;
        },
        4 => {
            const name = userReadableSlice(frame.ebx, frame.ecx, 11) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            if (name.len != 11 or current_pid == 0 or frame.edx > 0xFF) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFEA;
                return 0;
            }
            const fd = vfsOpenOwned(name, current_pid, @truncate(frame.edx)) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFFE;
                return 0;
            };
            syscall_file_opens +|= 1;
            frame.eax = fd;
            return 0;
        },
        5 => {
            if (frame.ebx > 0xFF or frame.edx > 2048 or current_pid == 0) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF7;
                return 0;
            }
            const destination = userWritableSlice(frame.ecx, frame.edx, 2048) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            const amount = vfsReadOwned(@truncate(frame.ebx), current_pid, destination) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF7;
                return 0;
            };
            syscall_file_reads +|= 1;
            syscall_file_read_bytes +|= @intCast(amount);
            frame.eax = @intCast(amount);
            return 0;
        },
        6 => {
            if (frame.ebx > 0xFF or current_pid == 0 or !vfsCloseOwned(@truncate(frame.ebx), current_pid)) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF7;
                return 0;
            }
            syscall_file_closes +|= 1;
            frame.eax = 0;
            return 0;
        },
        7 => {
            if (frame.ebx > 0xFF or frame.edx > 2048 or current_pid == 0) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF7;
                return 0;
            }
            const source = userReadableSlice(frame.ecx, frame.edx, 2048) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            const amount = vfsWriteOwned(@truncate(frame.ebx), current_pid, source) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF7;
                return 0;
            };
            syscall_file_writes +|= 1;
            syscall_file_write_bytes +|= @intCast(amount);
            frame.eax = @intCast(amount);
            return 0;
        },
        8 => {
            if (frame.ebx > 0xFF or current_pid == 0) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF7;
                return 0;
            }
            const position = vfsSeekOwned(@truncate(frame.ebx), current_pid, frame.ecx, frame.edx) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF7;
                return 0;
            };
            syscall_file_seeks +|= 1;
            frame.eax = position;
            return 0;
        },
        else => {
            syscall_rejected +|= 1;
            frame.eax = 0xFFFF_FFDA;
            return 0;
        },
    }
}

fn userReadableSlice(start: u32, length: u32, maximum: u32) ?[]const u8 {
    const end = start +% length;
    if (length > maximum or end < start or start < 0x0040_0000 or end > 0x0040_1000) return null;
    const bytes: [*]const u8 = @ptrFromInt(start);
    return bytes[0..@intCast(length)];
}

fn userWritableSlice(start: u32, length: u32, maximum: u32) ?[]u8 {
    const end = start +% length;
    if (length > maximum or end < start or start < 0x0040_0000 or end > 0x0040_1000) return null;
    const bytes: [*]u8 = @ptrFromInt(start);
    return bytes[0..@intCast(length)];
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
    const valid = info.magic == boot_info_magic and info.version == 2 and info.size == @sizeOf(BootInfo) and
        info.e820_entry_size == @sizeOf(E820Entry) and info.e820_entry_count != 0 and
        info.e820_entry_count <= maximum_e820_entries and info.e820_entries_address == 0x0000_5200 and
        info.boot_drive == 0x80 and (info.flags & 0x07) == 0x07 and info.kernel_address == 0x0001_0000 and
        info.kernel_bytes != 0 and info.kernel_sectors != 0 and info.kernel_sectors <= 247 and
        info.fat_partition_lba == 256 and zigos_i686_entry_checksum_ok == 1 and
        zigos_i686_entry_checksum_observed == info.kernel_checksum16;
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
    writeAll(" loader checksum16 0x");
    writeHex32(info.kernel_checksum16);
    writeAll(" entry-checksum yes FAT-LBA 0x");
    writeHex32(info.fat_partition_lba);
    writeAll(" flags 0x");
    writeHex8(info.flags);
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
    if (volume_lba != 256 or partition_sectors != 2880) fatFailure("partition geometry");

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
    fat_sectors_per_fat = sectors_per_fat;
    fat_root_sectors = @intCast(root_sectors);
    fat_cluster_count = @intCast((@as(u32, total_sectors) - (data_start - volume_lba)) / sectors_per_cluster);
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
    initializeVfsAndProcesses();
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

fn initializeVfsAndProcesses() void {
    vfs_descriptors = @splat(.{});
    vfs_open_count = 0;
    vfs_read_count = 0;
    vfs_write_count = 0;
    vfs_seek_count = 0;
    vfs_close_count = 0;
    vfs_create_count = 0;
    vfs_truncate_count = 0;
    fat_allocation_count = 0;
    fat_free_count = 0;
    fat_entry_write_count = 0;
    ata_write_count = 0;
    reloadVfsRoot();

    const hello_index = vfsFindNode("HELLO   TXT") orelse vfsFailure("HELLO.TXT node");
    const init_index = vfsFindNode("INIT    ELF") orelse vfsFailure("INIT.ELF node");
    const cat_index = vfsFindNode("CAT     ELF") orelse vfsFailure("CAT.ELF node");
    const big_index = vfsFindNode("BIG     TXT") orelse vfsFailure("BIG.TXT node");
    _ = vfsFindNode("SPINA   ELF") orelse vfsFailure("SPINA.ELF node");
    _ = vfsFindNode("SPINB   ELF") orelse vfsFailure("SPINB.ELF node");
    const fault_index = vfsFindNode("FAULT   ELF") orelse vfsFailure("FAULT.ELF node");
    const writer_index = vfsFindNode("WRITER  ELF") orelse vfsFailure("WRITER.ELF node");
    notes_present_at_boot = vfsFindNode("NOTES   TXT") != null;
    cat_elf_size = vfs_nodes[cat_index].size;
    big_file_size = vfs_nodes[big_index].size;
    fault_elf_size = vfs_nodes[fault_index].size;
    writer_elf_size = vfs_nodes[writer_index].size;
    const expected_nodes: u32 = if (notes_present_at_boot) 9 else 8;
    if (vfs_node_count != expected_nodes or vfs_nodes[hello_index].size != expected_fat_file.len or
        vfs_nodes[init_index].size != init_elf_size or cat_elf_size != 510 or
        big_file_size != expected_big_bytes or fault_elf_size != 262 or writer_elf_size != 1488)
    {
        vfsFailure("root inventory");
    }

    const big_amount = vfsReadWhole("BIG     TXT", vfs_large_buffer[0..]) orelse vfsFailure("BIG.TXT read");
    const big_hash = fnv1a32(vfs_large_buffer[0..big_amount]);
    if (big_amount != expected_big_bytes or big_hash != expected_big_hash) vfsFailure("multi-cluster BIG.TXT");

    var probe: [86]u8 = @splat(0);
    const probe_fd = vfsOpen("HELLO   TXT") orelse vfsFailure("probe open");
    const first_read = vfsRead(probe_fd, probe[0..32]);
    const second_read = vfsRead(probe_fd, probe[32..]);
    if (!vfsClose(probe_fd) or first_read != 32 or second_read != 54 or
        !equalBytes(probe[0..], expected_fat_file))
    {
        vfsFailure("split read");
    }

    var denied_probe: [1]u8 = @splat(0);
    const owner_probe_fd = vfsOpenOwned("HELLO   TXT", 0x77, vfs_open_read) orelse vfsFailure("owner probe open");
    const owner_offset_before = vfs_descriptors[owner_probe_fd].offset;
    const denied_read = vfsReadOwned(owner_probe_fd, 0x78, denied_probe[0..]);
    const denied_close = vfsCloseOwned(owner_probe_fd, 0x78);
    if (denied_read != null or denied_close or vfs_descriptors[owner_probe_fd].offset != owner_offset_before or
        !vfsCloseOwned(owner_probe_fd, 0x77))
    {
        vfsFailure("descriptor owner isolation");
    }

    if (notes_present_at_boot) verifyNotesFile();

    process_table = @splat(.{});
    process_table[0] = .{
        .pid = 1,
        .parent_pid = 0,
        .name = fatName("INIT    ELF"),
        .exit_code = init_elf_exit,
        .state = .exited,
    };
    process_count = 1;
    next_pid = 2;
    current_pid = 0;
    last_spawned_pid = 0;
    process_wait_count = 0;
    last_waited_pid = 0;

    writeAll("ZigOs i686 writable VFS ready: root-files 0x");
    writeHex32(vfs_node_count);
    writeAll(" descriptors 0x00000008 BIG.TXT bytes 0x");
    writeHex32(big_file_size);
    writeAll(" hash 0x");
    writeHex32(big_hash);
    writeAll(" split-read 0x");
    writeHex32(first_read);
    writeAll("/0x");
    writeHex32(second_read);
    writeAll(" owner-denied yes persistent-notes ");
    writeAll(if (notes_present_at_boot) "yes" else "no");
    if (notes_present_at_boot) {
        writeAll(" notes-cluster 0x");
        writeHex32(notes_cluster);
        writeAll(" notes-hash 0x");
        writeHex32(notes_hash);
    }
    writeAll("\r\n");
    verifyUserProcessScheduler();
    runShell();
}

fn reloadVfsRoot() void {
    vfs_nodes = @splat(.{});
    vfs_node_count = 0;
    const buffer_address: u32 = @intCast(@intFromPtr(&vfs_root_buffer));
    scan: for (0..fat_root_sectors) |sector_index| {
        const root_lba = fat_root_lba + @as(u32, @intCast(sector_index));
        if (!ataReadSector(root_lba, buffer_address)) vfsFailure("read root");
        for (0..16) |entry_index| {
            const offset = entry_index * 32;
            const first = vfs_root_buffer[offset];
            if (first == 0) break :scan;
            if (first == 0xE5) continue;
            const attributes = vfs_root_buffer[offset + 11];
            if (attributes == 0x0F or (attributes & 0x18) != 0) continue;
            if (vfs_node_count >= vfs_nodes.len) vfsFailure("root capacity");
            const node_index: usize = @intCast(vfs_node_count);
            var node = &vfs_nodes[node_index];
            for (0..11) |index| node.name[index] = vfs_root_buffer[offset + index];
            node.cluster = readLe16(&vfs_root_buffer, offset + 26);
            node.size = readLe32(&vfs_root_buffer, offset + 28);
            node.root_lba = root_lba;
            node.root_offset = @intCast(offset);
            node.attributes = attributes;
            node.present = true;
            if ((node.size == 0 and node.cluster != 0) or (node.size != 0 and node.cluster < 2) or node.size > 4096) {
                vfsFailure("root node bounds");
            }
            if (node.size != 0 and !validateFatChain(node.cluster, node.size)) vfsFailure("root node chain");
            vfs_node_count += 1;
        }
    }
}

fn validateFatChain(first_cluster: u16, size: u32) bool {
    const needed = (size + 511) / 512;
    var cluster = first_cluster;
    var visited: u32 = 0;
    while (visited < needed) : (visited += 1) {
        if (!validDataCluster(cluster)) return false;
        const next = fatReadEntry(cluster) orelse return false;
        if (visited + 1 == needed) return next >= 0x0FF8;
        if (next >= 0x0FF8 or !validDataCluster(next)) return false;
        cluster = next;
    }
    return false;
}

fn verifyUserProcessScheduler() void {
    const free_before = free_frame_count;
    var frames: [8]u32 = @splat(0);
    for (&frames) |*frame| frame.* = allocateFrame() orelse userSchedulerFailure("frame allocation");

    const task_a_directory = frames[0];
    const task_a_table = frames[1];
    const task_a_code = frames[2];
    const task_a_stack = frames[3];
    const task_b_directory = frames[4];
    const task_b_table = frames[5];
    const task_b_code = frames[6];
    const task_b_stack = frames[7];
    buildUserAddressSpace(task_a_directory, task_a_table, task_a_code, task_a_stack);
    buildUserAddressSpace(task_b_directory, task_b_table, task_b_code, task_b_stack);
    _ = loadElfSegmentIntoFrame("SPINA   ELF", task_a_code) orelse userSchedulerFailure("SPINA ELF load");
    _ = loadElfSegmentIntoFrame("SPINB   ELF", task_b_code) orelse userSchedulerFailure("SPINB ELF load");

    const task_a_counter: *volatile u32 = @ptrFromInt(task_a_code + 0x100);
    const task_b_counter: *volatile u32 = @ptrFromInt(task_b_code + 0x100);
    task_a_counter.* = 0x1100_0000;
    task_b_counter.* = 0x2200_0000;

    process_table[1] = .{
        .pid = 2,
        .parent_pid = 0,
        .name = fatName("SPINA   ELF"),
        .state = .running,
    };
    process_table[2] = .{
        .pid = 3,
        .parent_pid = 0,
        .name = fatName("SPINB   ELF"),
        .state = .running,
    };
    process_count = 3;
    next_pid = 4;
    last_spawned_pid = 3;

    user_scheduler_stacks = @splat(0);
    user_scheduler_cr3 = @splat(0);
    user_scheduler_kernel_tops = @splat(0);
    user_scheduler_quanta = @splat(0);
    user_scheduler_current = 0;
    user_scheduler_switches = 0;
    user_scheduler_done = false;
    user_scheduler_cr3[0] = kernel_page_directory;
    user_scheduler_cr3[1] = task_a_directory;
    user_scheduler_cr3[2] = task_b_directory;
    user_scheduler_kernel_tops[0] = @intCast(@intFromPtr(&user_transition_stack) + user_transition_stack.len);
    user_scheduler_kernel_tops[1] = @intCast(@intFromPtr(&user_scheduler_kernel_stack_a) + user_scheduler_kernel_stack_a.len);
    user_scheduler_kernel_tops[2] = @intCast(@intFromPtr(&user_scheduler_kernel_stack_b) + user_scheduler_kernel_stack_b.len);
    user_scheduler_stacks[1] = initializeUserTask(&user_scheduler_kernel_stack_a);
    user_scheduler_stacks[2] = initializeUserTask(&user_scheduler_kernel_stack_b);
    const start_ticks = timer_ticks;

    configurePic();
    configurePit100Hz();
    zigos_i686_out8(0x0021, 0xFE);
    user_scheduler_active = true;
    const done: *volatile bool = &user_scheduler_done;
    zigos_i686_enable_interrupts();
    while (!done.*) zigos_i686_halt();
    zigos_i686_disable_interrupts();
    zigos_i686_out8(0x0021, 0xFF);
    zigos_i686_out8(0x00A1, 0xFF);

    const elapsed = timer_ticks -% start_ticks;
    const observed_a = task_a_counter.*;
    const observed_b = task_b_counter.*;
    const directory_a: [*]const volatile u32 = @ptrFromInt(task_a_directory);
    const directory_b: [*]const volatile u32 = @ptrFromInt(task_b_directory);
    var failure_mask: u32 = 0;
    if (user_scheduler_active or user_scheduler_current != 0 or !user_scheduler_done) failure_mask |= 1 << 0;
    if (user_scheduler_quanta[1] != 3 or user_scheduler_quanta[2] != 3) failure_mask |= 1 << 1;
    if (user_scheduler_switches != 7 or elapsed != 7) failure_mask |= 1 << 2;
    if (zigos_i686_read_cr3() != kernel_page_directory) failure_mask |= 1 << 3;
    if (task_a_directory == task_b_directory or task_a_code == task_b_code or task_a_stack == task_b_stack) failure_mask |= 1 << 4;
    if (user_scheduler_kernel_tops[1] == user_scheduler_kernel_tops[2]) failure_mask |= 1 << 5;
    if ((directory_a[0] & 0x004) != 0 or (directory_b[0] & 0x004) != 0) failure_mask |= 1 << 6;
    if ((directory_a[1] & 0x007) != 0x007 or (directory_b[1] & 0x007) != 0x007) failure_mask |= 1 << 7;
    if (observed_a <= 0x1100_0000 or observed_b <= 0x2200_0000) failure_mask |= 1 << 8;
    if ((observed_a >> 24) != 0x11 or (observed_b >> 24) != 0x22 or observed_a == observed_b) failure_mask |= 1 << 9;
    if (kernel_tss.esp0 != user_scheduler_kernel_tops[0] or current_pid != 0) failure_mask |= 1 << 10;
    if (failure_mask != 0) {
        writeAll("ZigOs i686 user scheduler failed: predicate-mask 0x");
        writeHex32(failure_mask);
        writeAll("\r\n");
        haltForever();
    }

    process_table[1].exit_code = 0x40;
    process_table[1].state = .exited;
    process_table[2].exit_code = 0x41;
    process_table[2].state = .exited;

    var frame_index: usize = frames.len;
    while (frame_index != 0) {
        frame_index -= 1;
        if (!freeFrame(frames[frame_index])) userSchedulerFailure("frame release");
    }
    if (free_frame_count != free_before) userSchedulerFailure("frame restoration");

    writeAll("ZigOs i686 user scheduler verified: disk-ELF tasks SPINA.ELF/SPINB.ELF address-spaces 0x00000002 switches 0x");
    writeHex32(user_scheduler_switches);
    writeAll(" quanta 0x");
    writeHex32(user_scheduler_quanta[1]);
    writeAll("/0x");
    writeHex32(user_scheduler_quanta[2]);
    writeAll(" tick-delta 0x");
    writeHex32(elapsed);
    writeAll(" CR3-distinct yes kernel-stacks distinct shared-VA 0x00400100 tags 0x");
    writeHex8(@truncate(observed_a >> 24));
    writeAll("/0x");
    writeHex8(@truncate(observed_b >> 24));
    writeAll(" frames-restored yes\r\n");
}

fn loadElfSegmentIntoFrame(name: []const u8, destination_frame: u32) ?u32 {
    const amount = vfsReadWhole(name, vfs_large_buffer[0..]) orelse return null;
    if (amount < 84 or readLe32(&vfs_large_buffer, 0) != 0x464C_457F or
        readLe16(&vfs_large_buffer, 16) != 2 or readLe16(&vfs_large_buffer, 18) != 3 or
        readLe32(&vfs_large_buffer, 24) != 0x0040_0000 or readLe32(&vfs_large_buffer, 28) != 52)
    {
        return null;
    }
    const ph: usize = 52;
    const file_offset = readLe32(&vfs_large_buffer, ph + 4);
    const virtual_address = readLe32(&vfs_large_buffer, ph + 8);
    const file_bytes = readLe32(&vfs_large_buffer, ph + 16);
    const memory_bytes = readLe32(&vfs_large_buffer, ph + 20);
    const flags = readLe32(&vfs_large_buffer, ph + 24);
    if (readLe32(&vfs_large_buffer, ph) != 1 or file_offset + file_bytes > amount or
        virtual_address != 0x0040_0000 or memory_bytes < file_bytes or memory_bytes > 4096 or flags != 5)
    {
        return null;
    }
    zeroPhysicalFrame(destination_frame);
    const destination: [*]volatile u8 = @ptrFromInt(destination_frame);
    for (0..file_bytes) |offset| destination[offset] = vfs_large_buffer[file_offset + offset];
    return memory_bytes;
}

fn buildUserAddressSpace(directory_frame: u32, table_frame: u32, code_frame: u32, stack_frame: u32) void {
    zeroPhysicalFrame(directory_frame);
    zeroPhysicalFrame(table_frame);
    zeroPhysicalFrame(code_frame);
    zeroPhysicalFrame(stack_frame);
    const source: [*]const volatile u32 = @ptrFromInt(kernel_page_directory);
    const destination: [*]volatile u32 = @ptrFromInt(directory_frame);
    for (0..1024) |index| destination[index] = source[index];
    destination[1] = table_frame | 0x007;
    const table: [*]volatile u32 = @ptrFromInt(table_frame);
    table[0] = code_frame | 0x007;
    table[2] = stack_frame | 0x007;
}

fn initializeUserTask(stack: *[4096]u8) u32 {
    const top = @intFromPtr(stack) + stack.len;
    const context_address: u32 = @intCast(top - @sizeOf(UserReturnFrame));
    const context: *UserReturnFrame = @ptrFromInt(context_address);
    context.* = .{
        .edi = 0,
        .esi = 0,
        .ebp = 0,
        .interrupted_esp = 0,
        .ebx = 0,
        .edx = 0,
        .ecx = 0,
        .eax = 0,
        .eip = 0x0040_0000,
        .cs = 0x001B,
        .eflags = 0x0000_0202,
        .user_esp = 0x0040_3000,
        .user_ss = 0x0023,
    };
    return context_address;
}

fn userSchedulerFailure(reason: []const u8) noreturn {
    user_scheduler_active = false;
    zigos_i686_disable_interrupts();
    writeAll("ZigOs i686 user scheduler failed: ");
    writeAll(reason);
    writeAll("\r\n");
    haltForever();
}

fn fatName(comptime text: []const u8) [11]u8 {
    if (text.len != 11) @compileError("FAT name must contain exactly 11 bytes");
    var result: [11]u8 = undefined;
    for (text, 0..) |byte, index| result[index] = byte;
    return result;
}

fn parseFatDisplayName(text: []const u8) ?[11]u8 {
    if (text.len == 0 or text.len > 12) return null;
    var result: [11]u8 = @splat(' ');
    var base_index: usize = 0;
    var extension_index: usize = 0;
    var in_extension = false;
    for (text) |raw| {
        if (raw == '.') {
            if (in_extension or base_index == 0) return null;
            in_extension = true;
            continue;
        }
        var byte = raw;
        if (byte >= 'a' and byte <= 'z') byte -= 32;
        const valid = (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '_' or byte == '-';
        if (!valid) return null;
        if (!in_extension) {
            if (base_index >= 8) return null;
            result[base_index] = byte;
            base_index += 1;
        } else {
            if (extension_index >= 3) return null;
            result[8 + extension_index] = byte;
            extension_index += 1;
        }
    }
    if (base_index == 0) return null;
    return result;
}

fn validDataCluster(cluster: u16) bool {
    return cluster >= 2 and cluster <= fat_cluster_count + 1;
}

fn fatReadEntry(cluster: u16) ?u16 {
    if (!validDataCluster(cluster)) return null;
    const fat_offset: u32 = @as(u32, cluster) + @as(u32, cluster) / 2;
    const lba = fat_start_lba + fat_offset / fat_bytes_per_sector;
    const byte_offset: usize = @intCast(fat_offset % fat_bytes_per_sector);
    if (!ataReadSector(lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return null;
    const first = vfs_sector_buffer[byte_offset];
    const second: u8 = if (byte_offset == 511) blk: {
        if (!ataReadSector(lba + 1, @intCast(@intFromPtr(&vfs_aux_buffer)))) return null;
        break :blk vfs_aux_buffer[0];
    } else vfs_sector_buffer[byte_offset + 1];
    const pair = @as(u16, first) | (@as(u16, second) << 8);
    return if ((cluster & 1) == 0) pair & 0x0FFF else pair >> 4;
}

fn fatWriteEntry(cluster: u16, value: u16) bool {
    if (!validDataCluster(cluster) or value > 0x0FFF) return false;
    const fat_offset: u32 = @as(u32, cluster) + @as(u32, cluster) / 2;
    const relative_sector = fat_offset / fat_bytes_per_sector;
    const byte_offset: usize = @intCast(fat_offset % fat_bytes_per_sector);
    for (0..2) |copy_index| {
        const lba = fat_start_lba + @as(u32, @intCast(copy_index)) * fat_sectors_per_fat + relative_sector;
        if (!ataReadSector(lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return false;
        var second: u8 = undefined;
        if (byte_offset == 511) {
            if (!ataReadSector(lba + 1, @intCast(@intFromPtr(&vfs_aux_buffer)))) return false;
            second = vfs_aux_buffer[0];
        } else {
            second = vfs_sector_buffer[byte_offset + 1];
        }
        if ((cluster & 1) == 0) {
            vfs_sector_buffer[byte_offset] = @truncate(value);
            second = (second & 0xF0) | @as(u8, @truncate(value >> 8));
        } else {
            vfs_sector_buffer[byte_offset] = (vfs_sector_buffer[byte_offset] & 0x0F) | @as(u8, @truncate(value << 4));
            second = @truncate(value >> 4);
        }
        if (byte_offset == 511) {
            vfs_aux_buffer[0] = second;
            if (!ataWriteSector(lba, @intCast(@intFromPtr(&vfs_sector_buffer))) or
                !ataWriteSector(lba + 1, @intCast(@intFromPtr(&vfs_aux_buffer)))) return false;
        } else {
            vfs_sector_buffer[byte_offset + 1] = second;
            if (!ataWriteSector(lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return false;
        }
    }
    fat_entry_write_count +|= 1;
    return true;
}

fn fatAllocateCluster() ?u16 {
    var cluster: u16 = 2;
    while (cluster <= fat_cluster_count + 1) : (cluster += 1) {
        const value = fatReadEntry(cluster) orelse return null;
        if (value != 0) continue;
        if (!fatWriteEntry(cluster, 0x0FFF)) return null;
        @memset(vfs_sector_buffer[0..], 0);
        const cluster_lba = fat_data_lba + (@as(u32, cluster) - 2) * fat_sectors_per_cluster;
        if (!ataWriteSector(cluster_lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return null;
        fat_allocation_count +|= 1;
        return cluster;
    }
    return null;
}

fn fatFreeChain(first_cluster: u16) bool {
    if (first_cluster == 0) return true;
    var cluster = first_cluster;
    var remaining: u32 = fat_cluster_count;
    while (remaining != 0) : (remaining -= 1) {
        if (!validDataCluster(cluster)) return false;
        const next = fatReadEntry(cluster) orelse return false;
        if (!fatWriteEntry(cluster, 0)) return false;
        fat_free_count +|= 1;
        if (next >= 0x0FF8) return true;
        cluster = next;
    }
    return false;
}

fn vfsFindNode(name: []const u8) ?usize {
    if (name.len != 11) return null;
    for (vfs_nodes, 0..) |node, index| {
        if (node.present and equalBytes(node.name[0..], name)) return index;
    }
    return null;
}

fn vfsCreateNode(name: []const u8) ?usize {
    if (name.len != 11 or vfs_node_count >= vfs_nodes.len) return null;
    for (0..fat_root_sectors) |sector_index| {
        const lba = fat_root_lba + @as(u32, @intCast(sector_index));
        if (!ataReadSector(lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return null;
        for (0..16) |entry_index| {
            const offset = entry_index * 32;
            const first = vfs_sector_buffer[offset];
            if (first != 0 and first != 0xE5) continue;
            @memset(vfs_sector_buffer[offset .. offset + 32], 0);
            for (0..11) |index| vfs_sector_buffer[offset + index] = name[index];
            vfs_sector_buffer[offset + 11] = 0x20;
            if (!ataWriteSector(lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return null;
            const node_index: usize = @intCast(vfs_node_count);
            vfs_nodes[node_index] = .{
                .name = undefined,
                .root_lba = lba,
                .root_offset = @intCast(offset),
                .attributes = 0x20,
                .present = true,
            };
            for (0..11) |index| vfs_nodes[node_index].name[index] = name[index];
            vfs_node_count += 1;
            vfs_create_count +|= 1;
            return node_index;
        }
    }
    return null;
}

fn vfsUpdateNode(node_index: usize) bool {
    if (node_index >= vfs_nodes.len or !vfs_nodes[node_index].present) return false;
    const node = &vfs_nodes[node_index];
    if (!ataReadSector(node.root_lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return false;
    const offset: usize = node.root_offset;
    writeLe16(&vfs_sector_buffer, offset + 26, node.cluster);
    writeLe32(&vfs_sector_buffer, offset + 28, node.size);
    return ataWriteSector(node.root_lba, @intCast(@intFromPtr(&vfs_sector_buffer)));
}

fn vfsTruncateNode(node_index: usize) bool {
    if (node_index >= vfs_nodes.len or !vfs_nodes[node_index].present) return false;
    var node = &vfs_nodes[node_index];
    if (!fatFreeChain(node.cluster)) return false;
    node.cluster = 0;
    node.size = 0;
    if (!vfsUpdateNode(node_index)) return false;
    vfs_truncate_count +|= 1;
    return true;
}

fn vfsClusterAt(node_index: usize, ordinal: u32, allocate: bool) ?u16 {
    if (node_index >= vfs_nodes.len or !vfs_nodes[node_index].present) return null;
    var node = &vfs_nodes[node_index];
    if (node.cluster == 0) {
        if (!allocate) return null;
        node.cluster = fatAllocateCluster() orelse return null;
        if (!vfsUpdateNode(node_index)) return null;
    }
    var cluster = node.cluster;
    var index: u32 = 0;
    while (index < ordinal) : (index += 1) {
        const next = fatReadEntry(cluster) orelse return null;
        if (next >= 0x0FF8) {
            if (!allocate) return null;
            const allocated = fatAllocateCluster() orelse return null;
            if (!fatWriteEntry(cluster, allocated)) return null;
            cluster = allocated;
        } else {
            if (!validDataCluster(next)) return null;
            cluster = next;
        }
    }
    return cluster;
}

fn vfsOpen(name: []const u8) ?u8 {
    return vfsOpenOwned(name, 0, vfs_open_read);
}

fn vfsOpenOwned(name: []const u8, owner_pid: u32, flags: u8) ?u8 {
    if ((flags & ~(vfs_open_read | vfs_open_write | vfs_open_create | vfs_open_truncate | vfs_open_append)) != 0 or
        (flags & (vfs_open_read | vfs_open_write)) == 0 or
        ((flags & (vfs_open_truncate | vfs_open_append)) != 0 and (flags & vfs_open_write) == 0))
    {
        return null;
    }
    var node_index = vfsFindNode(name);
    if (node_index == null and (flags & vfs_open_create) != 0) node_index = vfsCreateNode(name);
    const resolved = node_index orelse return null;
    if ((flags & vfs_open_truncate) != 0 and !vfsTruncateNode(resolved)) return null;
    for (&vfs_descriptors, 0..) |*descriptor, index| {
        if (descriptor.open) continue;
        descriptor.* = .{
            .node_index = @intCast(resolved),
            .flags = flags,
            .offset = if ((flags & vfs_open_append) != 0) vfs_nodes[resolved].size else 0,
            .owner_pid = owner_pid,
            .open = true,
        };
        vfs_open_count +|= 1;
        return @intCast(index);
    }
    return null;
}

fn vfsRead(fd: u8, destination: []u8) usize {
    return vfsReadOwned(fd, 0, destination) orelse 0;
}

fn vfsReadOwned(fd: u8, owner_pid: u32, destination: []u8) ?usize {
    const index: usize = fd;
    if (index >= vfs_descriptors.len) return null;
    var descriptor = &vfs_descriptors[index];
    if (!descriptor.open or descriptor.owner_pid != owner_pid or (descriptor.flags & vfs_open_read) == 0) return null;
    const node_index: usize = descriptor.node_index;
    if (node_index >= vfs_nodes.len or !vfs_nodes[node_index].present) return null;
    const node = &vfs_nodes[node_index];
    if (descriptor.offset >= node.size or destination.len == 0) {
        vfs_read_count +|= 1;
        return 0;
    }
    const remaining: usize = @intCast(node.size - descriptor.offset);
    const amount = @min(destination.len, remaining);
    var copied: usize = 0;
    while (copied < amount) {
        const absolute = descriptor.offset + @as(u32, @intCast(copied));
        const ordinal = absolute / 512;
        const within: usize = @intCast(absolute % 512);
        const cluster = vfsClusterAt(node_index, ordinal, false) orelse return null;
        const lba = fat_data_lba + (@as(u32, cluster) - 2) * fat_sectors_per_cluster;
        if (!ataReadSector(lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return null;
        const chunk = @min(amount - copied, 512 - within);
        for (0..chunk) |offset| destination[copied + offset] = vfs_sector_buffer[within + offset];
        copied += chunk;
    }
    descriptor.offset += @intCast(amount);
    vfs_read_count +|= 1;
    return amount;
}

fn vfsWriteOwned(fd: u8, owner_pid: u32, source: []const u8) ?usize {
    const index: usize = fd;
    if (index >= vfs_descriptors.len) return null;
    var descriptor = &vfs_descriptors[index];
    if (!descriptor.open or descriptor.owner_pid != owner_pid or (descriptor.flags & vfs_open_write) == 0) return null;
    const node_index: usize = descriptor.node_index;
    if (node_index >= vfs_nodes.len or !vfs_nodes[node_index].present) return null;
    var node = &vfs_nodes[node_index];
    if ((descriptor.flags & vfs_open_append) != 0) descriptor.offset = node.size;
    const end = descriptor.offset +% @as(u32, @intCast(source.len));
    if (end < descriptor.offset or end > 4096) return null;
    var copied: usize = 0;
    while (copied < source.len) {
        const absolute = descriptor.offset + @as(u32, @intCast(copied));
        const ordinal = absolute / 512;
        const within: usize = @intCast(absolute % 512);
        const cluster = vfsClusterAt(node_index, ordinal, true) orelse return null;
        const lba = fat_data_lba + (@as(u32, cluster) - 2) * fat_sectors_per_cluster;
        if (!ataReadSector(lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return null;
        const chunk = @min(source.len - copied, 512 - within);
        for (0..chunk) |offset| vfs_sector_buffer[within + offset] = source[copied + offset];
        if (!ataWriteSector(lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return null;
        copied += chunk;
    }
    descriptor.offset = end;
    if (end > node.size) {
        node.size = end;
        if (!vfsUpdateNode(node_index)) return null;
    }
    vfs_write_count +|= 1;
    return source.len;
}

fn vfsSeekOwned(fd: u8, owner_pid: u32, offset: u32, whence: u32) ?u32 {
    const index: usize = fd;
    if (index >= vfs_descriptors.len) return null;
    var descriptor = &vfs_descriptors[index];
    if (!descriptor.open or descriptor.owner_pid != owner_pid) return null;
    const node_index: usize = descriptor.node_index;
    if (node_index >= vfs_nodes.len or !vfs_nodes[node_index].present) return null;
    const base: u32 = switch (whence) {
        0 => 0,
        1 => descriptor.offset,
        2 => vfs_nodes[node_index].size,
        else => return null,
    };
    const position = base +% offset;
    if (position < base or position > vfs_nodes[node_index].size) return null;
    descriptor.offset = position;
    vfs_seek_count +|= 1;
    return position;
}

fn vfsClose(fd: u8) bool {
    return vfsCloseOwned(fd, 0);
}

fn vfsCloseOwned(fd: u8, owner_pid: u32) bool {
    const index: usize = fd;
    if (index >= vfs_descriptors.len or !vfs_descriptors[index].open or
        vfs_descriptors[index].owner_pid != owner_pid)
    {
        return false;
    }
    vfs_descriptors[index] = .{};
    vfs_close_count +|= 1;
    return true;
}

fn vfsCloseAllOwned(owner_pid: u32) u32 {
    var closed: u32 = 0;
    for (&vfs_descriptors) |*descriptor| {
        if (!descriptor.open or descriptor.owner_pid != owner_pid) continue;
        descriptor.* = .{};
        vfs_close_count +|= 1;
        closed +|= 1;
    }
    return closed;
}

fn vfsOpenCountOwned(owner_pid: u32) u32 {
    var count: u32 = 0;
    for (vfs_descriptors) |descriptor| {
        if (descriptor.open and descriptor.owner_pid == owner_pid) count +|= 1;
    }
    return count;
}

fn vfsReadWhole(name: []const u8, destination: []u8) ?usize {
    const node_index = vfsFindNode(name) orelse return null;
    if (vfs_nodes[node_index].size > destination.len) return null;
    const fd = vfsOpen(name) orelse return null;
    const amount = vfsReadOwned(fd, 0, destination) orelse {
        _ = vfsClose(fd);
        return null;
    };
    if (!vfsClose(fd) or amount != vfs_nodes[node_index].size) return null;
    return amount;
}

fn verifyNotesFile() void {
    const node_index = vfsFindNode("NOTES   TXT") orelse vfsFailure("NOTES.TXT absent");
    const amount = vfsReadWhole("NOTES   TXT", vfs_large_buffer[0..]) orelse vfsFailure("NOTES.TXT read");
    if (amount != expected_notes_bytes) vfsFailure("NOTES.TXT size");
    for (0..700) |index| {
        const expected: u8 = 'a' + @as(u8, @intCast(index % 26));
        if (vfs_large_buffer[index] != expected) vfsFailure("NOTES.TXT base content");
    }
    if (!equalBytes(vfs_large_buffer[700..720], notes_suffix)) vfsFailure("NOTES.TXT suffix");
    notes_hash = fnv1a32(vfs_large_buffer[0..amount]);
    notes_cluster = vfs_nodes[node_index].cluster;
    const second = fatReadEntry(notes_cluster) orelse vfsFailure("NOTES first FAT entry");
    const end = fatReadEntry(second) orelse vfsFailure("NOTES second FAT entry");
    if (notes_hash != expected_notes_hash or notes_cluster != 14 or second != 15 or end < 0x0FF8) {
        vfsFailure("NOTES.TXT deterministic chain");
    }
}

fn writeFatDisplayName(name: *const [11]u8) void {
    var base_length: usize = 8;
    while (base_length > 0 and name[base_length - 1] == ' ') base_length -= 1;
    writeAll(name[0..base_length]);
    var extension_length: usize = 3;
    while (extension_length > 0 and name[8 + extension_length - 1] == ' ') extension_length -= 1;
    if (extension_length != 0) {
        writeAll(".");
        writeAll(name[8 .. 8 + extension_length]);
    }
}

fn listVfsRoot() void {
    for (&vfs_nodes) |*node| {
        if (!node.present) continue;
        writeFatDisplayName(&node.name);
        writeAll(" 0x");
        writeHex32(node.size);
        writeAll(" cluster 0x");
        writeHex32(node.cluster);
        writeAll("\r\n");
    }
}

fn hashVfsFile(name: []const u8) bool {
    const amount = vfsReadWhole(name, vfs_large_buffer[0..]) orelse return false;
    writeAll("hash ");
    const node_index = vfsFindNode(name) orelse return false;
    writeFatDisplayName(&vfs_nodes[node_index].name);
    writeAll(" bytes 0x");
    writeHex32(@as(u32, @intCast(amount)));
    writeAll(" fnv1a32 0x");
    writeHex32(fnv1a32(vfs_large_buffer[0..amount]));
    writeAll("\r\n");
    return true;
}

fn statVfsFile(name: []const u8) bool {
    const node_index = vfsFindNode(name) orelse return false;
    const node = &vfs_nodes[node_index];
    writeAll("stat ");
    writeFatDisplayName(&node.name);
    writeAll(" bytes 0x");
    writeHex32(node.size);
    writeAll(" first-cluster 0x");
    writeHex32(node.cluster);
    var clusters: u32 = 0;
    var cluster = node.cluster;
    if (node.size != 0) {
        while (clusters <= fat_cluster_count) {
            clusters += 1;
            const next = fatReadEntry(cluster) orelse return false;
            if (next >= 0x0FF8) break;
            cluster = next;
        }
    }
    writeAll(" clusters 0x");
    writeHex32(clusters);
    writeAll("\r\n");
    return true;
}

const SpawnResult = struct {
    pid: u32,
    exit_code: u32,
    syscalls: u32,
    state: ProcessState,
};

fn resetSyscallAccounting() void {
    syscall_count = 0;
    syscall_write_bytes = 0;
    syscall_file_opens = 0;
    syscall_file_reads = 0;
    syscall_file_read_bytes = 0;
    syscall_file_writes = 0;
    syscall_file_write_bytes = 0;
    syscall_file_seeks = 0;
    syscall_file_closes = 0;
    syscall_exit_cleanup_closes = 0;
    syscall_rejected = 0;
    syscall_exit_code = 0;
    syscall_exited = false;
    process_faulted = false;
    process_fault_vector = 0;
    process_fault_address = 0;
}

fn spawnElfProcess(name: [11]u8, parent_pid: u32) ?SpawnResult {
    const node_index = vfsFindNode(name[0..]) orelse return null;
    const node = &vfs_nodes[node_index];
    if (node.size < 84 or node.size > 4096) return null;
    var slot: ?usize = null;
    for (&process_table, 0..) |*record, index| {
        if (record.state == .free) {
            slot = index;
            break;
        }
    }
    const process_index = slot orelse return null;
    const pid = next_pid;
    next_pid +|= 1;
    process_table[process_index] = .{
        .pid = pid,
        .parent_pid = parent_pid,
        .name = name,
        .state = .running,
    };
    process_count +|= 1;

    const free_before = heapFreePayloadBytes();
    const image_address = heapAllocate(node.size) orelse processFailure("ELF image allocation");
    const image: [*]u8 = @ptrFromInt(image_address);
    const amount = vfsReadWhole(name[0..], image[0..node.size]) orelse processFailure("ELF VFS read");
    if (amount != node.size or readLe32(image, 0) != 0x464C_457F or readLe16(image, 16) != 2 or
        readLe16(image, 18) != 3 or readLe32(image, 24) != 0x0040_0000 or readLe32(image, 28) != 52)
    {
        processFailure("ELF identity");
    }
    const ph: usize = 52;
    const file_offset = readLe32(image, ph + 4);
    const virtual_address = readLe32(image, ph + 8);
    const file_bytes = readLe32(image, ph + 16);
    const memory_bytes = readLe32(image, ph + 20);
    const flags = readLe32(image, ph + 24);
    if (readLe32(image, ph) != 1 or file_offset + file_bytes > amount or virtual_address != 0x0040_0000 or
        memory_bytes < file_bytes or memory_bytes > 4096 or flags != 5)
    {
        processFailure("ELF PT_LOAD");
    }

    zeroPhysicalFrame(user_code_frame);
    const code: [*]volatile u8 = @ptrFromInt(user_code_frame);
    for (0..file_bytes) |offset| code[offset] = image[file_offset + offset];
    zigos_i686_invalidate_page(0x0040_0000);
    resetSyscallAccounting();
    current_pid = pid;
    zigos_i686_enter_user(0x0040_0000, 0x0040_2000);
    current_pid = 0;

    if (process_faulted) {
        syscall_exit_code = 0x80 + process_fault_vector;
        process_table[process_index].state = .faulted;
        process_table[process_index].fault_vector = process_fault_vector;
        process_table[process_index].fault_address = process_fault_address;
    } else {
        if (!syscall_exited) processFailure("ELF did not exit");
        process_table[process_index].state = .exited;
    }
    process_table[process_index].exit_code = syscall_exit_code;
    last_spawned_pid = pid;

    if (equalBytes(name[0..], "INIT    ELF")) {
        if (syscall_exit_code != 0x33 or syscall_count != 3 or syscall_rejected != 0) processFailure("INIT contract");
    } else if (equalBytes(name[0..], "CAT     ELF")) {
        if (syscall_exit_code != 0x44 or syscall_count != 5 or syscall_file_opens != 1 or
            syscall_file_reads != 1 or syscall_file_read_bytes != expected_fat_file.len or
            syscall_file_closes != 1 or syscall_rejected != 0)
        {
            processFailure("CAT contract");
        }
    } else if (equalBytes(name[0..], "WRITER  ELF")) {
        if (syscall_exit_code != 0x55 or syscall_count != 9 or syscall_file_opens != 2 or
            syscall_file_writes != 2 or syscall_file_write_bytes != expected_notes_bytes or
            syscall_file_seeks != 1 or syscall_file_reads != 1 or syscall_file_read_bytes != 700 or
            syscall_file_closes != 2 or syscall_rejected != 0 or vfsOpenCountOwned(pid) != 0)
        {
            processFailure("WRITER syscall contract");
        }
        verifyNotesFile();
    } else if (equalBytes(name[0..], "FAULT   ELF")) {
        if (!process_faulted or process_fault_vector != 14 or process_fault_address != 0x0080_0000 or
            syscall_count != 0 or syscall_exit_code != 0x8E)
        {
            processFailure("FAULT containment contract");
        }
    }

    if (!heapFree(image_address) or heapFreePayloadBytes() != free_before) processFailure("ELF heap restoration");
    return .{
        .pid = pid,
        .exit_code = syscall_exit_code,
        .syscalls = syscall_count,
        .state = process_table[process_index].state,
    };
}

fn waitProcess(parent_pid: u32, pid: u32) ?u32 {
    for (&process_table) |*record| {
        if (record.state == .free or record.pid != pid or record.parent_pid != parent_pid or record.waited or
            record.state == .running)
        {
            continue;
        }
        record.waited = true;
        process_wait_count +|= 1;
        last_waited_pid = pid;
        return record.exit_code;
    }
    return null;
}

fn listProcesses() void {
    for (&process_table) |*record| {
        if (record.state == .free) continue;
        writeAll("PID 0x");
        writeHex32(record.pid);
        writeAll(" PPID 0x");
        writeHex32(record.parent_pid);
        switch (record.state) {
            .running => writeAll(" RUNNING "),
            .exited => {
                writeAll(" EXITED 0x");
                writeHex32(record.exit_code);
                writeAll(" ");
            },
            .faulted => {
                writeAll(" FAULTED vector 0x");
                writeHex32(record.fault_vector);
                writeAll(" address 0x");
                writeHex32(record.fault_address);
                writeAll(" exit 0x");
                writeHex32(record.exit_code);
                writeAll(" ");
            },
            .free => unreachable,
        }
        writeFatDisplayName(&record.name);
        writeAll(" waited ");
        writeAll(if (record.waited) "yes" else "no");
        writeAll("\r\n");
    }
}

fn vfsFailure(reason: []const u8) noreturn {
    writeAll("ZigOs i686 VFS failed: ");
    writeAll(reason);
    writeAll("\r\n");
    haltForever();
}

fn processFailure(reason: []const u8) noreturn {
    writeAll("ZigOs i686 process failed: ");
    writeAll(reason);
    writeAll("\r\n");
    haltForever();
}

fn runShell() noreturn {
    const expected_nodes: u32 = if (notes_present_at_boot) 9 else 8;
    if (!ata_ready or !fat_ready or !heap_ready or !frame_allocator_ready or vfs_node_count != expected_nodes) {
        shellFailure("subsystems unavailable");
    }
    writeAll("ZigOs i686 Capstone 8 shell ready: commands help ls mem ticks disk hash FILE stat FILE run FILE wait PID ps exit mode ");
    writeAll(if (notes_present_at_boot) "persistence" else "first");
    writeAll("\r\n");
    var line: [64]u8 = undefined;
    while (true) {
        writeAll("zigos> ");
        const length = readShellLine(&line);
        const command = line[0..length];
        if (command.len == 0) continue;
        if (equalBytes(command, "help")) {
            shell_command_count +|= 1;
            writeAll("commands: help ls mem ticks disk hash FILE stat FILE run FILE wait PID ps exit\r\n");
        } else if (equalBytes(command, "ls")) {
            shell_command_count +|= 1;
            listVfsRoot();
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
            writeAll(" FAT12 writable yes root-files 0x");
            writeHex32(vfs_node_count);
            writeAll(" BIG.TXT-bytes 0x");
            writeHex32(big_file_size);
            writeAll(" WRITER.ELF-bytes 0x");
            writeHex32(writer_elf_size);
            writeAll(" persistent-notes ");
            writeAll(if (vfsFindNode("NOTES   TXT") != null) "yes" else "no");
            writeAll("\r\n");
        } else if (command.len > 5 and equalBytes(command[0..5], "hash ")) {
            shell_command_count +|= 1;
            const name = parseFatDisplayName(command[5..]) orelse shellFailure("invalid hash name");
            if (!hashVfsFile(name[0..])) shellFailure("hash file");
        } else if (command.len > 5 and equalBytes(command[0..5], "stat ")) {
            shell_command_count +|= 1;
            const name = parseFatDisplayName(command[5..]) orelse shellFailure("invalid stat name");
            if (!statVfsFile(name[0..])) shellFailure("stat file");
        } else if (command.len > 4 and equalBytes(command[0..4], "run ")) {
            shell_command_count +|= 1;
            const name = parseFatDisplayName(command[4..]) orelse shellFailure("invalid ELF name");
            const result = spawnElfProcess(name, 0) orelse shellFailure("exec failed");
            writeAll("process PID 0x");
            writeHex32(result.pid);
            writeAll(" ");
            writeFatDisplayName(&name);
            if (result.state == .faulted) {
                writeAll(" faulted vector 0x");
                writeHex32(process_fault_vector);
                writeAll(" address 0x");
                writeHex32(process_fault_address);
                writeAll(" contained yes exit 0x");
                writeHex32(result.exit_code);
            } else {
                writeAll(" exited 0x");
                writeHex32(result.exit_code);
                writeAll(" syscalls 0x");
                writeHex32(result.syscalls);
            }
            if (equalBytes(name[0..], "WRITER  ELF")) {
                writeAll(" wrote 0x");
                writeHex32(syscall_file_write_bytes);
                writeAll(" readback 0x");
                writeHex32(syscall_file_read_bytes);
                writeAll(" notes-hash 0x");
                writeHex32(notes_hash);
                writeAll(" chain 0x0000000E->0x0000000F");
            }
            writeAll("\r\n");
        } else if (command.len > 5 and equalBytes(command[0..5], "wait ")) {
            shell_command_count +|= 1;
            const pid = parseDecimal(command[5..]) orelse shellFailure("invalid PID");
            const exit_code = waitProcess(0, pid) orelse shellFailure("wait target");
            writeAll("wait PID 0x");
            writeHex32(pid);
            writeAll(" exit 0x");
            writeHex32(exit_code);
            writeAll(" reaped yes\r\n");
        } else if (equalBytes(command, "ps")) {
            shell_command_count +|= 1;
            listProcesses();
        } else if (equalBytes(command, "exit")) {
            var descriptors_closed = true;
            for (vfs_descriptors) |descriptor| {
                if (descriptor.open) descriptors_closed = false;
            }
            if (!descriptors_closed or shell_unknown_count != 0) shellFailure("descriptor/unknown accounting");
            if (!notes_present_at_boot) {
                verifyNotesFile();
                var fault_ok = false;
                for (process_table) |record| {
                    if (record.pid == 7 and record.state == .faulted and record.fault_vector == 14 and
                        record.fault_address == 0x0080_0000) fault_ok = true;
                }
                if (vfs_node_count != 9 or process_count != 7 or last_spawned_pid != 7 or
                    process_wait_count != 1 or last_waited_pid != 6 or !fault_ok or shell_command_count != 13 or
                    vfs_create_count != 1 or vfs_truncate_count != 1 or vfs_write_count != 2 or
                    vfs_seek_count != 1 or fat_allocation_count != 2 or notes_hash != expected_notes_hash)
                {
                    shellFailure("first-session accounting");
                }
                writeAll("ZigOs i686 Capstone 8 first session verified: goals 0x0000000A root-files 0x");
                writeHex32(vfs_node_count);
                writeAll(" processes 0x");
                writeHex32(process_count);
                writeAll(" waits 0x");
                writeHex32(process_wait_count);
                writeAll(" creates 0x");
                writeHex32(vfs_create_count);
                writeAll(" truncates 0x");
                writeHex32(vfs_truncate_count);
                writeAll(" writes 0x");
                writeHex32(vfs_write_count);
                writeAll(" seeks 0x");
                writeHex32(vfs_seek_count);
                writeAll(" allocations 0x");
                writeHex32(fat_allocation_count);
                writeAll(" notes 0x000002D0 hash 0x");
                writeHex32(notes_hash);
                writeAll(" chain 0x0000000E->0x0000000F fault-contained yes descriptors-closed yes commands 0x");
                writeHex32(shell_command_count);
                writeAll("\r\n");
            } else {
                verifyNotesFile();
                if (vfs_node_count != 9 or process_count != 3 or shell_command_count != 3 or
                    vfs_create_count != 0 or vfs_truncate_count != 0 or vfs_write_count != 0 or
                    fat_allocation_count != 0 or notes_hash != expected_notes_hash)
                {
                    shellFailure("persistence-session accounting");
                }
                writeAll("ZigOs i686 Capstone 8 persistence session verified: root-files 0x00000009 notes 0x000002D0 hash 0x");
                writeHex32(notes_hash);
                writeAll(" chain 0x0000000E->0x0000000F writes 0x00000000 allocations 0x00000000 descriptors-closed yes commands 0x");
                writeHex32(shell_command_count);
                writeAll("\r\n");
            }
            haltForever();
        } else {
            shell_unknown_count +|= 1;
            writeAll("unknown command: ");
            writeAll(command);
            writeAll("\r\n");
        }
    }
}

fn parseDecimal(text: []const u8) ?u32 {
    if (text.len == 0) return null;
    var value: u32 = 0;
    for (text) |byte| {
        if (byte < '0' or byte > '9') return null;
        const digit: u32 = byte - '0';
        if (value > (0xFFFF_FFFF - digit) / 10) return null;
        value = value * 10 + digit;
    }
    return value;
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

fn writeLe16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}

fn writeLe32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
    bytes[offset + 2] = @truncate(value >> 16);
    bytes[offset + 3] = @truncate(value >> 24);
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
    if (lba >= 0x1000_0000 or !ataWaitReady()) return false;
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
    // Complete READ SECTORS before another ATA command can be issued.
    return ataWaitReady();
}

fn ataWriteSector(lba: u32, source_address: u32) bool {
    if (ata_sector_count != 0 and lba >= ata_sector_count) return false;
    if (lba >= 0x1000_0000 or !ataWaitReady()) return false;
    zigos_i686_out8(ata_drive_port, 0xE0 | @as(u8, @truncate(lba >> 24)));
    ataDelay();
    zigos_i686_out8(ata_sector_count_port, 1);
    zigos_i686_out8(ata_lba_low_port, @truncate(lba));
    zigos_i686_out8(ata_lba_mid_port, @truncate(lba >> 8));
    zigos_i686_out8(ata_lba_high_port, @truncate(lba >> 16));
    zigos_i686_out8(ata_status_command_port, 0x30);
    if (!ataWaitData()) return false;
    const source: [*]const volatile u8 = @ptrFromInt(source_address);
    for (0..256) |index| {
        const word = @as(u16, source[index * 2]) | (@as(u16, source[index * 2 + 1]) << 8);
        zigos_i686_out16(ata_data_port, word);
    }
    // The device may assert BSY after the final data word. Complete the
    // WRITE SECTORS command before issuing the independent FLUSH CACHE command.
    if (!ataWaitReady()) return false;
    zigos_i686_out8(ata_status_command_port, 0xE7);
    if (!ataWaitReady()) return false;
    if (!ataReadSector(lba, @intCast(@intFromPtr(&ata_verify_buffer)))) return false;
    for (0..512) |index| {
        if (ata_verify_buffer[index] != source[index]) return false;
    }
    ata_write_count +|= 1;
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
