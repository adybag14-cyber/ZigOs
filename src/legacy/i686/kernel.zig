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
const vfs_open_cloexec: u8 = 0x20;
const user_heap_base: u32 = 0x0040_3000;
const user_heap_limit: u32 = 0x0040_5000;
const user_mmap_address: u32 = 0x0040_5000;
const user_service_limit: u32 = 0x0040_6000;
const service_payload = "SERVICE-PIPE-OK!\r\n";
const orch_request = "PARENT-TO-CHILD\r\n";
const child_reply = "CHILD-TO-PARENT\r\n";
const path_max_bytes: u32 = 48;
const path_max_components: usize = 4;
const path_write_create: u32 = 0x01;
const path_write_truncate: u32 = 0x02;
const path_write_append: u32 = 0x04;
const expected_path_payload_bytes: u32 = 600;
const expected_path_payload_hash: u32 = 0x36F7_3195;
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

const PathTokenKind = enum(u8) {
    name,
    parent,
};

const PathToken = struct {
    name: [11]u8 = @splat(' '),
    kind: PathTokenKind = .name,
};

const ParsedPath = struct {
    tokens: [path_max_components]PathToken = @splat(.{}),
    count: u8 = 0,
    absolute: bool = false,
};

const PathEntry = struct {
    name: [11]u8 = @splat(' '),
    cluster: u16 = 0,
    parent_cluster: u16 = 0,
    entry_lba: u32 = 0,
    size: u32 = 0,
    entry_offset: u16 = 0,
    attributes: u8 = 0,
};

const PathParent = struct {
    directory_cluster: u16 = 0,
    leaf: [11]u8 = @splat(' '),
};

const DirectorySlot = struct {
    lba: u32,
    offset: u16,
};

const DescriptorKind = enum(u8) {
    free,
    file,
    pipe_read,
    pipe_write,
};

const VfsDescriptor = struct {
    node_index: u8 = 0,
    pipe_index: u8 = 0,
    flags: u8 = 0,
    kind: DescriptorKind = .free,
    offset: u32 = 0,
    owner_pid: u32 = 0,
    open: bool = false,
};

const PipeObject = struct {
    buffer: [256]u8 = @splat(0),
    head: u16 = 0,
    tail: u16 = 0,
    count: u16 = 0,
    readers: u8 = 0,
    writers: u8 = 0,
    active: bool = false,
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
    process_group: u32 = 0,
    name: [11]u8 = @splat(' '),
    exit_code: u32 = 0,
    fault_vector: u32 = 0,
    fault_address: u32 = 0,
    waited: bool = false,
    pending_signal: u8 = 0,
    cwd_cluster: u16 = 0,
    state: ProcessState = .free,
};

const ForkChildContext = struct {
    frames: [7]u32 = @splat(0),
    inherited_fds: [8]u8 = @splat(0xFF),
    child_results: [6]u32 = @splat(0),
    child_pid: u32 = 0,
    parent_pid: u32 = 0,
    process_group: u32 = 0,
    process_index: u8 = 0,
    inherited_count: u8 = 0,
    read_fd: u8 = 0xFF,
    write_fd: u8 = 0xFF,
    cloexec_closed: u8 = 0,
    child_exit_cleanup: u8 = 0,
    child_exit_code: u32 = 0,
    child_syscalls: u32 = 0,
    frames_before: u32 = 0,
    frames_after: u32 = 0,
    request_match: bool = false,
    active: bool = false,
    exec_ready: bool = false,
    executed: bool = false,
    resources_released: bool = false,
    parent_cr3_restored: bool = false,
    parent_tss_restored: bool = false,
    parent_pid_restored: bool = false,
};

const KernelThreadState = enum(u8) {
    free,
    ready,
    running,
    sleeping,
    blocked,
    exited,
};

const KernelThread = struct {
    stack_pointer: u32 = 0,
    wake_tick: u32 = 0,
    quanta: u32 = 0,
    state: KernelThreadState = .free,
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
extern var zigos_i686_kernel_return_esp: u32;
extern fn zigos_i686_read_cr0() callconv(.c) u32;
extern fn zigos_i686_read_cr3() callconv(.c) u32;
extern fn zigos_i686_read_cr2() callconv(.c) u32;
extern fn zigos_i686_write_cr3(page_directory: u32) callconv(.c) void;
extern fn zigos_i686_enable_paging(page_directory: u32) callconv(.c) void;
extern fn zigos_i686_invalidate_page(address: u32) callconv(.c) void;
extern fn zigos_i686_cpuid_vendor(destination: [*]u8) callconv(.c) u32;
extern fn zigos_i686_out8(port: u16, value: u8) callconv(.c) void;
extern fn zigos_i686_out16(port: u16, value: u16) callconv(.c) void;
extern fn zigos_i686_out32(port: u16, value: u32) callconv(.c) void;
extern fn zigos_i686_in8(port: u16) callconv(.c) u8;
extern fn zigos_i686_in16(port: u16) callconv(.c) u16;
extern fn zigos_i686_in32(port: u16) callconv(.c) u32;
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
var keyboard_ring: [16]u8 = @splat(0);
var keyboard_ring_head: u8 = 0;
var keyboard_ring_tail: u8 = 0;
var keyboard_ring_count: u8 = 0;
var keyboard_ring_dropped: u32 = 0;
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
var service_elf_size: u32 = 0;
var orch_elf_size: u32 = 0;
var child_elf_size: u32 = 0;
var paths_elf_size: u32 = 0;
var fault_elf_size: u32 = 0;
var big_file_size: u32 = 0;
var vfs_nodes: [16]VfsNode = @splat(.{});
var vfs_node_count: u32 = 0;
var vfs_descriptors: [8]VfsDescriptor = @splat(.{});
var pipe_objects: [4]PipeObject = @splat(.{});
const fat_cache_sector_count: usize = 9;
var fat_cache: [fat_cache_sector_count * 512]u8 align(16) = @splat(0);
var fat_cache_loaded = false;
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
var ata_retry_count: u32 = 0;
var ata_reset_count: u32 = 0;
var ata_last_status: u8 = 0;
var vfs_rename_count: u32 = 0;
var vfs_unlink_count: u32 = 0;
var namespace_verified = false;
var namespace_reused_cluster: u16 = 0;
var namespace_hash: u32 = 0;
var fat_sectors_per_fat: u16 = 0;
var fat_root_sectors: u16 = 0;
var fat_cluster_count: u16 = 0;
var notes_present_at_boot = false;
var notes_cluster: u16 = 0;
var notes_hash: u32 = 0;
var runtime_first_cluster: u16 = 0;
var hierarchy_present_at_boot = false;
var hierarchy_verified = false;
var hierarchy_home_cluster: u16 = 0;
var hierarchy_docs_cluster: u16 = 0;
var hierarchy_archive_cluster: u16 = 0;
var hierarchy_log_first_cluster: u16 = 0;
var hierarchy_log_second_cluster: u16 = 0;
var hierarchy_reused_cluster: u16 = 0;
var hierarchy_hash: u32 = 0;
var hierarchy_syscalls: u32 = 0;
var hierarchy_rejections: u32 = 0;
var hierarchy_mkdir_count: u32 = 0;
var hierarchy_rmdir_count: u32 = 0;
var hierarchy_rename_count: u32 = 0;
var hierarchy_unlink_count: u32 = 0;
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
var process_fault_error: u32 = 0;
var user_service_frames: [3]u32 = @splat(0);
var user_break_current: u32 = user_heap_base;
var user_mmap_active = false;
var service_verified = false;
var service_syscalls: u32 = 0;
var service_pipe_bytes: u32 = 0;
var service_sleep_ticks: u32 = 0;
var service_signal: u32 = 0;
var fork_child: ForkChildContext = .{};
var fork_child_kernel_stack: [4096]u8 align(16) = @splat(0);
var fork_tree_verified = false;
var fork_tree_child_pid: u32 = 0;
var fork_tree_child_syscalls: u32 = 0;
var fork_tree_inherited: u32 = 0;
var fork_tree_cloexec: u32 = 0;
var fork_tree_signal: u32 = 0;
var fork_tree_pipe_bytes: u32 = 0;
var pci_device_count: u32 = 0;
var pci_host_id: u32 = 0;
var pci_class_code: u8 = 0;
var demand_page_active = false;
var demand_page_virtual: u32 = 0;
var demand_page_frame: u32 = 0;
var demand_page_faults: u32 = 0;
var demand_page_error: u32 = 0;
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
var advanced_threads: [5]KernelThread = @splat(.{});
var advanced_thread_stacks: [4][4096]u8 align(16) = @splat(@splat(0));
var advanced_thread_iterations: [4]u32 = @splat(0);
var advanced_scheduler_current: u32 = 0;
var advanced_scheduler_switches: u32 = 0;
var advanced_scheduler_dispatches: u32 = 0;
var advanced_scheduler_sleep_count: u32 = 0;
var advanced_scheduler_block_count: u32 = 0;
var advanced_scheduler_signal_count: u32 = 0;
var advanced_scheduler_wake_count: u32 = 0;
var advanced_scheduler_exit_count: u32 = 0;
var advanced_scheduler_active = false;
var advanced_scheduler_done = false;
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
var kernel_alias_table: u32 = 0;
var vm_map_count: u32 = 0;
var vm_remap_count: u32 = 0;
var vm_unmap_count: u32 = 0;
var vm_fault_recovery_count: u32 = 0;
var vm_fault_containment_count: u32 = 0;
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
var syscall_brk_count: u32 = 0;
var syscall_mmap_count: u32 = 0;
var syscall_munmap_count: u32 = 0;
var syscall_getppid_count: u32 = 0;
var syscall_uptime_count: u32 = 0;
var syscall_sleep_count: u32 = 0;
var syscall_stat_count: u32 = 0;
var syscall_rename_count: u32 = 0;
var syscall_unlink_count: u32 = 0;
var syscall_pipe_count: u32 = 0;
var syscall_pipe_read_count: u32 = 0;
var syscall_pipe_write_count: u32 = 0;
var syscall_dup_count: u32 = 0;
var syscall_dup2_count: u32 = 0;
var syscall_signal_send_count: u32 = 0;
var syscall_signal_pending_count: u32 = 0;
var syscall_clone_count: u32 = 0;
var syscall_child_peek_count: u32 = 0;
var syscall_child_poke_count: u32 = 0;
var syscall_child_exec_count: u32 = 0;
var syscall_waitpid_count: u32 = 0;
var syscall_setpgid_count: u32 = 0;
var syscall_getpgid_count: u32 = 0;
var syscall_killpg_count: u32 = 0;
var syscall_procinfo_count: u32 = 0;
var syscall_getcwd_count: u32 = 0;
var syscall_chdir_count: u32 = 0;
var syscall_mkdir_count: u32 = 0;
var syscall_rmdir_count: u32 = 0;
var syscall_path_stat_count: u32 = 0;
var syscall_path_write_count: u32 = 0;
var syscall_path_read_count: u32 = 0;
var syscall_path_rename_count: u32 = 0;
var syscall_path_unlink_count: u32 = 0;
var syscall_listdir_count: u32 = 0;
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
    if (frame.vector == 14 and (frame.cs & 3) == 3 and demand_page_active) {
        const fault_address = zigos_i686_read_cr2();
        if (fault_address == demand_page_virtual and (frame.error_code & 0x01) == 0) {
            if (!mapPageExisting(kernel_page_directory, demand_page_virtual, demand_page_frame, 0x006)) {
                pagingFailure("demand-zero map");
            }
            demand_page_active = false;
            demand_page_faults +|= 1;
            demand_page_error = frame.error_code;
            vm_fault_recovery_count +|= 1;
            return 0;
        }
    }
    if ((frame.cs & 3) == 3 and current_pid != 0) {
        process_faulted = true;
        process_fault_vector = frame.vector;
        process_fault_address = if (frame.vector == 14) zigos_i686_read_cr2() else frame.eip;
        process_fault_error = frame.error_code;
        vm_fault_containment_count +|= 1;
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
    if (advanced_scheduler_active) return scheduleAdvancedThreads(current_esp);
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
    if (keyboard_ring_count < keyboard_ring.len) {
        keyboard_ring[keyboard_ring_tail] = scancode;
        keyboard_ring_tail = @intCast((@as(usize, keyboard_ring_tail) + 1) % keyboard_ring.len);
        keyboard_ring_count += 1;
    } else {
        keyboard_ring_dropped +|= 1;
    }
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
            const amount = descriptorReadOwned(@truncate(frame.ebx), current_pid, destination) orelse {
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
            const amount = descriptorWriteOwned(@truncate(frame.ebx), current_pid, source) orelse {
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
        9 => {
            const result = setUserBreak(frame.ebx) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFEA;
                return 0;
            };
            syscall_brk_count +|= 1;
            frame.eax = result;
            return 0;
        },
        10 => {
            const result = mapUserAnonymous(frame.ebx, frame.ecx, frame.edx) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFEA;
                return 0;
            };
            syscall_mmap_count +|= 1;
            frame.eax = result;
            return 0;
        },
        11 => {
            if (!unmapUserAnonymous(frame.ebx, frame.ecx)) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFEA;
                return 0;
            }
            syscall_munmap_count +|= 1;
            frame.eax = 0;
            return 0;
        },
        12 => {
            syscall_getppid_count +|= 1;
            frame.eax = currentParentPid();
            return 0;
        },
        13 => {
            syscall_uptime_count +|= 1;
            frame.eax = timer_ticks;
            return 0;
        },
        14 => {
            const elapsed = sleepUserTicks(frame.ebx) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFEA;
                return 0;
            };
            syscall_sleep_count +|= 1;
            frame.eax = elapsed;
            return 0;
        },
        15 => {
            const name = userReadableSlice(frame.ebx, frame.ecx, 11) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            const destination = userWritableSlice(frame.edx, 16, 16) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            if (name.len != 11 or current_pid == 0 or !vfsStatToBuffer(name, destination)) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFFE;
                return 0;
            }
            syscall_stat_count +|= 1;
            frame.eax = 0;
            return 0;
        },
        16 => {
            const old_name = userReadableSlice(frame.ebx, frame.ecx, 11) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            const new_name = userReadableSlice(frame.edx, frame.esi, 11) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            if (old_name.len != 11 or new_name.len != 11 or current_pid == 0 or !vfsRenameNode(old_name, new_name)) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFFE;
                return 0;
            }
            syscall_rename_count +|= 1;
            frame.eax = 0;
            return 0;
        },
        17 => {
            const name = userReadableSlice(frame.ebx, frame.ecx, 11) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            if (name.len != 11 or current_pid == 0 or !vfsUnlinkNode(name)) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFFE;
                return 0;
            }
            syscall_unlink_count +|= 1;
            frame.eax = 0;
            return 0;
        },
        18 => {
            const output = userWritableSlice(frame.ebx, 8, 8) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            if (current_pid == 0 or !pipeCreateOwned(current_pid, output)) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFE8;
                return 0;
            }
            syscall_pipe_count +|= 1;
            frame.eax = 0;
            return 0;
        },
        19 => {
            if (frame.ebx > 0xFF or current_pid == 0) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF7;
                return 0;
            }
            const duplicated = duplicateDescriptorOwned(@truncate(frame.ebx), current_pid, null) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFE8;
                return 0;
            };
            syscall_dup_count +|= 1;
            frame.eax = duplicated;
            return 0;
        },
        20 => {
            if (frame.ebx > 0xFF or frame.ecx > 0xFF or current_pid == 0) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF7;
                return 0;
            }
            const duplicated = duplicateDescriptorOwned(@truncate(frame.ebx), current_pid, @truncate(frame.ecx)) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFE8;
                return 0;
            };
            syscall_dup2_count +|= 1;
            frame.eax = duplicated;
            return 0;
        },
        21 => {
            if (current_pid == 0 or frame.ecx == 0 or frame.ecx > 31 or !sendProcessSignal(frame.ebx, @truncate(frame.ecx))) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFFD;
                return 0;
            }
            syscall_signal_send_count +|= 1;
            frame.eax = 0;
            return 0;
        },
        22 => {
            if (current_pid == 0) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFFD;
                return 0;
            }
            syscall_signal_pending_count +|= 1;
            frame.eax = takePendingSignal(current_pid);
            return 0;
        },
        23 => {
            const pid = forkCloneCurrentProcess() orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF5;
                return 0;
            };
            syscall_clone_count +|= 1;
            frame.eax = pid;
            return 0;
        },
        24 => {
            const value = forkChildReadWord(frame.ebx, frame.ecx) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            syscall_child_peek_count +|= 1;
            frame.eax = value;
            return 0;
        },
        25 => {
            if (!forkChildWriteWord(frame.ebx, frame.ecx, frame.edx)) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            }
            syscall_child_poke_count +|= 1;
            frame.eax = 0;
            return 0;
        },
        26 => {
            const name = userReadableSlice(frame.ecx, frame.edx, 11) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            if (name.len != 11 or !forkExecChild(frame.ebx, name)) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFFE;
                return 0;
            }
            syscall_child_exec_count +|= 1;
            frame.eax = 0;
            return 0;
        },
        27 => {
            const status = userWritableSlice(frame.ecx, 16, 16) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            const pid = forkWaitChild(frame.ebx, status) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF6;
                return 0;
            };
            syscall_waitpid_count +|= 1;
            frame.eax = pid;
            return 0;
        },
        28 => {
            if (!setProcessGroup(frame.ebx, frame.ecx)) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFFD;
                return 0;
            }
            syscall_setpgid_count +|= 1;
            frame.eax = 0;
            return 0;
        },
        29 => {
            const group = getProcessGroup(frame.ebx) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFFD;
                return 0;
            };
            syscall_getpgid_count +|= 1;
            frame.eax = group;
            return 0;
        },
        30 => {
            const delivered = signalProcessGroup(frame.ebx, frame.ecx) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFFD;
                return 0;
            };
            syscall_killpg_count +|= 1;
            frame.eax = delivered;
            return 0;
        },
        31 => {
            const destination = userWritableSlice(frame.ecx, 32, 32) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            if (!writeProcessInfo(frame.ebx, destination)) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFFD;
                return 0;
            }
            syscall_procinfo_count +|= 1;
            frame.eax = 0;
            return 0;
        },
        32 => {
            const destination = userWritableSlice(frame.ebx, frame.ecx, path_max_bytes) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            const amount = pathGetCwd(current_pid, destination) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFEA;
                return 0;
            };
            syscall_getcwd_count +|= 1;
            frame.eax = @intCast(amount);
            return 0;
        },
        33 => {
            const path = userReadableSlice(frame.ebx, frame.ecx, path_max_bytes) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            if (current_pid == 0 or !pathChangeDirectory(current_pid, path)) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFFE;
                return 0;
            }
            syscall_chdir_count +|= 1;
            frame.eax = 0;
            return 0;
        },
        34 => {
            const path = userReadableSlice(frame.ebx, frame.ecx, path_max_bytes) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            const cluster = pathMakeDirectory(current_pid, path) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFFE;
                return 0;
            };
            syscall_mkdir_count +|= 1;
            frame.eax = cluster;
            return 0;
        },
        35 => {
            const path = userReadableSlice(frame.ebx, frame.ecx, path_max_bytes) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            if (current_pid == 0 or !pathRemoveDirectory(current_pid, path)) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFD9;
                return 0;
            }
            syscall_rmdir_count +|= 1;
            frame.eax = 0;
            return 0;
        },
        36 => {
            const path = userReadableSlice(frame.ebx, frame.ecx, path_max_bytes) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            const destination = userWritableSlice(frame.edx, 16, 16) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            if (!pathStatFile(current_pid, path, destination)) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFFE;
                return 0;
            }
            syscall_path_stat_count +|= 1;
            frame.eax = 0;
            return 0;
        },
        37 => {
            const path = userReadableSlice(frame.ebx, frame.ecx, path_max_bytes) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            const source = userReadableSlice(frame.edx, frame.esi, 2048) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            const amount = pathWriteFile(current_pid, path, source, frame.edi) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFFE;
                return 0;
            };
            syscall_path_write_count +|= 1;
            frame.eax = @intCast(amount);
            return 0;
        },
        38 => {
            const path = userReadableSlice(frame.ebx, frame.ecx, path_max_bytes) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            const destination = userWritableSlice(frame.edx, frame.esi, 2048) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            const amount = pathReadFile(current_pid, path, destination) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFFE;
                return 0;
            };
            syscall_path_read_count +|= 1;
            frame.eax = @intCast(amount);
            return 0;
        },
        39 => {
            const old_path = userReadableSlice(frame.ebx, frame.ecx, path_max_bytes) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            const new_path = userReadableSlice(frame.edx, frame.esi, path_max_bytes) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            if (!pathRename(current_pid, old_path, new_path)) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFFE;
                return 0;
            }
            syscall_path_rename_count +|= 1;
            frame.eax = 0;
            return 0;
        },
        40 => {
            const path = userReadableSlice(frame.ebx, frame.ecx, path_max_bytes) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            if (!pathUnlink(current_pid, path)) {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFFE;
                return 0;
            }
            syscall_path_unlink_count +|= 1;
            frame.eax = 0;
            return 0;
        },
        41 => {
            const path = userReadableSlice(frame.ebx, frame.ecx, path_max_bytes) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            const destination = userWritableSlice(frame.edx, frame.esi, 512) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFF2;
                return 0;
            };
            const amount = pathListDirectory(current_pid, path, destination) orelse {
                syscall_rejected +|= 1;
                frame.eax = 0xFFFF_FFFE;
                return 0;
            };
            syscall_listdir_count +|= 1;
            frame.eax = @intCast(amount);
            return 0;
        },
        else => {
            syscall_rejected +|= 1;
            frame.eax = 0xFFFF_FFDA;
            return 0;
        },
    }
}

fn userRangeMapped(start: u32, length: u32, writable: bool) bool {
    const end = start +% length;
    if (end < start or start < 0x0040_0000 or end > user_service_limit) return false;
    if (length == 0) return true;
    var page = start & 0xFFFF_F000;
    const final_page = (end - 1) & 0xFFFF_F000;
    while (true) {
        const entry = queryPageEntry(kernel_page_directory, page) orelse return false;
        if ((entry & 0x005) != 0x005 or (writable and (entry & 0x002) == 0)) return false;
        if (page == final_page) break;
        page +%= frame_size;
    }
    return true;
}

fn userReadableSlice(start: u32, length: u32, maximum: u32) ?[]const u8 {
    if (length > maximum or !userRangeMapped(start, length, false)) return null;
    const bytes: [*]const u8 = @ptrFromInt(start);
    return bytes[0..@intCast(length)];
}

fn userWritableSlice(start: u32, length: u32, maximum: u32) ?[]u8 {
    if (length > maximum or !userRangeMapped(start, length, true)) return null;
    const bytes: [*]u8 = @ptrFromInt(start);
    return bytes[0..@intCast(length)];
}

fn setUserBreak(requested: u32) ?u32 {
    if (requested == 0) return user_break_current;
    if (requested < user_heap_base or requested > user_heap_limit) return null;
    const required_pages: usize = @intCast((requested - user_heap_base + frame_size - 1) / frame_size);
    for (0..user_service_frames[0..2].len) |index| {
        const virtual = user_heap_base + @as(u32, @intCast(index)) * frame_size;
        const mapped = queryPageEntry(kernel_page_directory, virtual) != null;
        if (index < required_pages and !mapped) {
            zeroPhysicalFrame(user_service_frames[index]);
            if (!mapPageExisting(kernel_page_directory, virtual, user_service_frames[index], 0x006)) return null;
        } else if (index >= required_pages and mapped) {
            _ = unmapPageExisting(kernel_page_directory, virtual) orelse return null;
        }
    }
    user_break_current = requested;
    return requested;
}

fn mapUserAnonymous(address: u32, length: u32, protection: u32) ?u32 {
    if (address != user_mmap_address or length != frame_size or (protection & 0x03) != 0x03 or user_mmap_active) return null;
    zeroPhysicalFrame(user_service_frames[2]);
    if (!mapPageExisting(kernel_page_directory, address, user_service_frames[2], 0x006)) return null;
    user_mmap_active = true;
    return address;
}

fn unmapUserAnonymous(address: u32, length: u32) bool {
    if (address != user_mmap_address or length != frame_size or !user_mmap_active) return false;
    _ = unmapPageExisting(kernel_page_directory, address) orelse return false;
    user_mmap_active = false;
    return true;
}

fn resetUserServiceMappings() void {
    for (0..2) |index| {
        const virtual = user_heap_base + @as(u32, @intCast(index)) * frame_size;
        _ = unmapPageExisting(kernel_page_directory, virtual);
        if (user_service_frames[index] != 0) zeroPhysicalFrame(user_service_frames[index]);
    }
    _ = unmapPageExisting(kernel_page_directory, user_mmap_address);
    if (user_service_frames[2] != 0) zeroPhysicalFrame(user_service_frames[2]);
    user_break_current = user_heap_base;
    user_mmap_active = false;
}

fn currentParentPid() u32 {
    for (process_table) |record| if (record.state != .free and record.pid == current_pid) return record.parent_pid;
    return 0;
}

fn sendProcessSignal(pid: u32, signal: u8) bool {
    for (&process_table) |*record| {
        if (record.state == .free or record.pid != pid) continue;
        record.pending_signal = signal;
        return true;
    }
    return false;
}

fn takePendingSignal(pid: u32) u32 {
    for (&process_table) |*record| {
        if (record.state == .free or record.pid != pid) continue;
        const signal = record.pending_signal;
        record.pending_signal = 0;
        return signal;
    }
    return 0;
}

fn sleepUserTicks(requested: u32) ?u32 {
    if (requested > 10) return null;
    if (requested == 0) return 0;
    const start = timer_ticks;
    configurePic();
    configurePit100Hz();
    zigos_i686_out8(0x0021, 0xFE);
    zigos_i686_enable_interrupts();
    while (timer_ticks -% start < requested) zigos_i686_halt();
    zigos_i686_disable_interrupts();
    zigos_i686_out8(0x0021, 0xFF);
    zigos_i686_out8(0x00A1, 0xFF);
    return timer_ticks -% start;
}

fn processRecordIndex(pid: u32) ?usize {
    for (process_table, 0..) |record, index| {
        if (record.state != .free and record.pid == pid) return index;
    }
    return null;
}

fn copyPhysicalFrame(source: u32, destination: u32) void {
    const source_bytes: [*]const volatile u8 = @ptrFromInt(source);
    const destination_bytes: [*]volatile u8 = @ptrFromInt(destination);
    for (0..frame_size) |index| destination_bytes[index] = source_bytes[index];
}

fn releaseForkFrames(frames: *[7]u32) void {
    for (frames) |*frame| {
        if (frame.* != 0) {
            _ = freeFrame(frame.*);
            frame.* = 0;
        }
    }
}

fn forkCloneCurrentProcess() ?u32 {
    if (current_pid == 0 or fork_child.active) return null;
    const parent_index = processRecordIndex(current_pid) orelse return null;
    var process_slot: ?usize = null;
    for (process_table, 0..) |record, index| {
        if (record.state == .free) {
            process_slot = index;
            break;
        }
    }
    const resolved_slot = process_slot orelse return null;
    var parent_descriptors: usize = 0;
    var free_descriptors: usize = 0;
    for (vfs_descriptors) |descriptor| {
        if (!descriptor.open) free_descriptors += 1 else if (descriptor.owner_pid == current_pid) parent_descriptors += 1;
    }
    if (parent_descriptors == 0 or free_descriptors < parent_descriptors) return null;

    var frames: [7]u32 = @splat(0);
    var allocated: usize = 0;
    while (allocated < frames.len) : (allocated += 1) {
        frames[allocated] = allocateFrame() orelse {
            releaseForkFrames(&frames);
            return null;
        };
    }
    const frames_before = free_frame_count + @as(u32, @intCast(frames.len));
    copyPhysicalFrame(user_code_frame, frames[2]);
    copyPhysicalFrame(user_stack_frame, frames[3]);
    for (0..3) |index| copyPhysicalFrame(user_service_frames[index], frames[4 + index]);
    zeroPhysicalFrame(frames[0]);
    zeroPhysicalFrame(frames[1]);
    const source_directory: [*]const volatile u32 = @ptrFromInt(kernel_page_directory);
    const child_directory: [*]volatile u32 = @ptrFromInt(frames[0]);
    for (0..1024) |index| child_directory[index] = source_directory[index];
    child_directory[1] = frames[1] | 0x007;
    const child_table: [*]volatile u32 = @ptrFromInt(frames[1]);
    child_table[0] = frames[2] | 0x007;
    child_table[2] = frames[3] | 0x007;
    for (0..3) |index| {
        const virtual = user_heap_base + @as(u32, @intCast(index)) * frame_size;
        if (queryPageEntry(kernel_page_directory, virtual) != null) child_table[3 + index] = frames[4 + index] | 0x007;
    }

    const child_pid = next_pid;
    next_pid +|= 1;
    const parent_group = if (process_table[parent_index].process_group != 0) process_table[parent_index].process_group else current_pid;
    fork_child = .{
        .frames = frames,
        .child_pid = child_pid,
        .parent_pid = current_pid,
        .process_group = parent_group,
        .process_index = @intCast(resolved_slot),
        .frames_before = frames_before,
        .active = true,
    };
    for (vfs_descriptors) |descriptor| {
        if (!descriptor.open or descriptor.owner_pid != current_pid) continue;
        var target: ?usize = null;
        for (vfs_descriptors, 0..) |candidate, index| {
            if (!candidate.open) {
                target = index;
                break;
            }
        }
        const target_index = target orelse {
            releaseForkFrames(&fork_child.frames);
            fork_child = .{};
            return null;
        };
        vfs_descriptors[target_index] = descriptor;
        vfs_descriptors[target_index].owner_pid = child_pid;
        if (descriptor.kind == .pipe_read or descriptor.kind == .pipe_write) {
            const pipe_index: usize = descriptor.pipe_index;
            if (pipe_index >= pipe_objects.len or !pipe_objects[pipe_index].active) return null;
            if (descriptor.kind == .pipe_read) pipe_objects[pipe_index].readers +|= 1 else pipe_objects[pipe_index].writers +|= 1;
            if (descriptor.kind == .pipe_read) fork_child.read_fd = @intCast(target_index) else fork_child.write_fd = @intCast(target_index);
        }
        fork_child.inherited_fds[fork_child.inherited_count] = @intCast(target_index);
        fork_child.inherited_count += 1;
    }
    process_table[resolved_slot] = .{
        .pid = child_pid,
        .parent_pid = current_pid,
        .process_group = parent_group,
        .cwd_cluster = process_table[parent_index].cwd_cluster,
        .name = fatName("CLONE   PRC"),
        .state = .running,
    };
    process_count +|= 1;
    return child_pid;
}

fn forkChildPhysical(pid: u32, virtual: u32) ?u32 {
    if (!fork_child.active or fork_child.child_pid != pid or virtual < 0x0040_0000 or virtual >= user_service_limit) return null;
    const table: [*]const volatile u32 = @ptrFromInt(fork_child.frames[1]);
    const entry = table[(virtual >> 12) & 0x3FF];
    if ((entry & 1) == 0 or (entry & 4) == 0) return null;
    return (entry & 0xFFFF_F000) + (virtual & 0xFFF);
}

fn forkChildReadWord(pid: u32, virtual: u32) ?u32 {
    if ((virtual & 3) != 0) return null;
    const physical = forkChildPhysical(pid, virtual) orelse return null;
    const pointer: *const volatile u32 = @ptrFromInt(physical);
    return pointer.*;
}

fn forkChildWriteWord(pid: u32, virtual: u32, value: u32) bool {
    if ((virtual & 3) != 0) return false;
    const physical = forkChildPhysical(pid, virtual) orelse return false;
    const pointer: *volatile u32 = @ptrFromInt(physical);
    pointer.* = value;
    return true;
}

fn forkExecChild(pid: u32, name: []const u8) bool {
    if (!fork_child.active or fork_child.child_pid != pid or fork_child.exec_ready or name.len != 11) return false;
    _ = loadElfSegmentIntoFrame(name, fork_child.frames[2]) orelse return false;
    zeroPhysicalFrame(fork_child.frames[3]);
    const table: [*]volatile u32 = @ptrFromInt(fork_child.frames[1]);
    for (3..6) |index| {
        table[index] = 0;
        zeroPhysicalFrame(fork_child.frames[1 + index]);
    }
    var closed: u8 = 0;
    for (0..vfs_descriptors.len) |index| {
        const descriptor = vfs_descriptors[index];
        if (descriptor.open and descriptor.owner_pid == pid and (descriptor.flags & vfs_open_cloexec) != 0) {
            if (!vfsCloseOwned(@intCast(index), pid)) return false;
            closed += 1;
        }
    }
    fork_child.cloexec_closed = closed;
    fork_child.read_fd = 0xFF;
    fork_child.write_fd = 0xFF;
    for (vfs_descriptors, 0..) |descriptor, index| {
        if (!descriptor.open or descriptor.owner_pid != pid) continue;
        if (descriptor.kind == .pipe_read) fork_child.read_fd = @intCast(index);
        if (descriptor.kind == .pipe_write) fork_child.write_fd = @intCast(index);
    }
    if (fork_child.read_fd == 0xFF or fork_child.write_fd == 0xFF) return false;
    const code: [*]u8 = @ptrFromInt(fork_child.frames[2]);
    writeLe32(code[0..4096], 0x200, fork_child.read_fd);
    writeLe32(code[0..4096], 0x204, fork_child.write_fd);
    writeLe32(code[0..4096], 0x208, pid);
    writeLe32(code[0..4096], 0x20C, fork_child.parent_pid);
    writeLe32(code[0..4096], 0x210, fork_child.process_group);
    const process_index: usize = fork_child.process_index;
    for (0..11) |index| process_table[process_index].name[index] = name[index];
    fork_child.exec_ready = true;
    return true;
}

fn setProcessGroup(pid_value: u32, group_value: u32) bool {
    const pid = if (pid_value == 0) current_pid else pid_value;
    const group = if (group_value == 0) pid else group_value;
    const index = processRecordIndex(pid) orelse return false;
    const record = &process_table[index];
    if (current_pid == 0 or (pid != current_pid and record.parent_pid != current_pid) or record.state != .running) return false;
    record.process_group = group;
    if (fork_child.active and fork_child.child_pid == pid) fork_child.process_group = group;
    return true;
}

fn getProcessGroup(pid_value: u32) ?u32 {
    const pid = if (pid_value == 0) current_pid else pid_value;
    const index = processRecordIndex(pid) orelse return null;
    const group = process_table[index].process_group;
    return if (group == 0) pid else group;
}

fn signalProcessGroup(group: u32, signal_value: u32) ?u32 {
    if (current_pid == 0 or group == 0 or signal_value == 0 or signal_value > 31) return null;
    var delivered: u32 = 0;
    for (&process_table) |*record| {
        if (record.state != .running or record.process_group != group) continue;
        record.pending_signal = @truncate(signal_value);
        delivered +|= 1;
    }
    return if (delivered == 0) null else delivered;
}

fn writeProcessInfo(pid: u32, destination: []u8) bool {
    if (destination.len < 32) return false;
    const index = processRecordIndex(pid) orelse return false;
    const record = &process_table[index];
    writeLe32(destination, 0, record.pid);
    writeLe32(destination, 4, record.parent_pid);
    writeLe32(destination, 8, if (record.process_group == 0) record.pid else record.process_group);
    writeLe32(destination, 12, @intFromEnum(record.state));
    writeLe32(destination, 16, if (fork_child.child_pid == pid) fork_child.inherited_count else 0);
    writeLe32(destination, 20, if (fork_child.child_pid == pid) fork_child.cloexec_closed else 0);
    writeLe32(destination, 24, if (fork_child.child_pid == pid) fork_child.frames[0] else 0);
    writeLe32(destination, 28, if (fork_child.child_pid == pid) fork_child.frames.len else 0);
    return true;
}

fn executeForkChild() bool {
    if (!fork_child.active or !fork_child.exec_ready or fork_child.executed) return false;
    const saved_cr3 = zigos_i686_read_cr3();
    const saved_tss = kernel_tss.esp0;
    const saved_pid = current_pid;
    const saved_return_esp = zigos_i686_kernel_return_esp;
    const before_syscalls = syscall_count;
    syscall_exit_code = 0;
    syscall_exited = false;
    syscall_exit_cleanup_closes = 0;
    process_faulted = false;
    current_pid = fork_child.child_pid;
    kernel_tss.esp0 = @intCast(@intFromPtr(&fork_child_kernel_stack) + fork_child_kernel_stack.len);
    zigos_i686_write_cr3(fork_child.frames[0]);
    zigos_i686_enter_user(0x0040_0000, 0x0040_3000);
    fork_child.child_syscalls = syscall_count -% before_syscalls;
    fork_child.child_exit_code = syscall_exit_code;
    fork_child.child_exit_cleanup = @truncate(syscall_exit_cleanup_closes);
    const child_code: [*]const volatile u8 = @ptrFromInt(fork_child.frames[2]);
    for (0..fork_child.child_results.len) |index| fork_child.child_results[index] = readLe32(child_code, 0x220 + index * 4);
    fork_child.request_match = true;
    for (orch_request, 0..) |byte, index| {
        if (child_code[0x260 + index] != byte) fork_child.request_match = false;
    }
    const process_index: usize = fork_child.process_index;
    if (process_faulted or !syscall_exited) {
        process_table[process_index].state = .faulted;
        process_table[process_index].fault_vector = process_fault_vector;
        process_table[process_index].fault_address = process_fault_address;
        process_table[process_index].exit_code = if (process_faulted) 0x80 + process_fault_vector else 0xFF;
    } else {
        process_table[process_index].state = .exited;
        process_table[process_index].exit_code = syscall_exit_code;
    }
    zigos_i686_write_cr3(saved_cr3);
    kernel_tss.esp0 = saved_tss;
    current_pid = saved_pid;
    zigos_i686_kernel_return_esp = saved_return_esp;
    fork_child.parent_cr3_restored = zigos_i686_read_cr3() == saved_cr3;
    fork_child.parent_tss_restored = kernel_tss.esp0 == saved_tss;
    fork_child.parent_pid_restored = current_pid == saved_pid;
    syscall_exit_code = 0;
    syscall_exited = false;
    syscall_exit_cleanup_closes = 0;
    process_faulted = false;
    fork_child.executed = true;
    return true;
}

fn releaseForkChildResources() bool {
    if (!fork_child.active or !fork_child.executed) return false;
    if (vfsOpenCountOwned(fork_child.child_pid) != 0) return false;
    releaseForkFrames(&fork_child.frames);
    fork_child.frames_after = free_frame_count;
    fork_child.resources_released = fork_child.frames_after == fork_child.frames_before;
    fork_child.active = false;
    return fork_child.resources_released;
}

fn forkWaitChild(pid: u32, status: []u8) ?u32 {
    if (!fork_child.active or fork_child.child_pid != pid or !fork_child.exec_ready or status.len < 16) return null;
    if (!fork_child.executed and !executeForkChild()) return null;
    const process_index: usize = fork_child.process_index;
    const record = &process_table[process_index];
    if (record.waited or record.state == .running) return null;
    writeLe32(status, 0, record.pid);
    writeLe32(status, 4, record.exit_code);
    writeLe32(status, 8, @intFromEnum(record.state));
    writeLe32(status, 12, fork_child.child_syscalls);
    record.waited = true;
    process_wait_count +|= 1;
    last_waited_pid = pid;
    if (!releaseForkChildResources()) return null;
    return pid;
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
    verifyKeyboardRing();
    return ticks.*;
}

fn keyboardRingPop() ?u8 {
    if (keyboard_ring_count == 0) return null;
    const value = keyboard_ring[keyboard_ring_head];
    keyboard_ring_head = @intCast((@as(usize, keyboard_ring_head) + 1) % keyboard_ring.len);
    keyboard_ring_count -= 1;
    return value;
}

fn verifyKeyboardRing() void {
    keyboard_ring = @splat(0);
    keyboard_ring_head = 0;
    keyboard_ring_tail = 0;
    keyboard_ring_count = 0;
    keyboard_ring_dropped = 0;
    const start_irqs = keyboard_irq_count;
    const sequence = [_]u8{ 0x1E, 0x9E, 0x30, 0xB0 };
    zigos_i686_out8(0x0021, 0xFD);
    for (sequence, 0..) |scancode, index| {
        injectPs2Scancode(scancode);
        const target = start_irqs + @as(u32, @intCast(index)) + 1;
        const interrupts: *volatile u32 = &keyboard_irq_count;
        zigos_i686_enable_interrupts();
        while (interrupts.* < target) zigos_i686_halt();
        zigos_i686_disable_interrupts();
    }
    zigos_i686_out8(0x0021, 0xFF);
    for (sequence) |expected| {
        if (keyboardRingPop() != expected) keyboardFailure("ring ordering");
    }
    if (keyboard_ring_count != 0 or keyboard_ring_dropped != 0) keyboardFailure("ring accounting");
    writeAll("ZigOs i686 keyboard ring verified: capacity 0x00000010 events 0x00000004 order 0x1E/0x9E/0x30/0xB0 dropped 0x00000000\r\n");
}

fn keyboardFailure(reason: []const u8) noreturn {
    zigos_i686_disable_interrupts();
    writeAll("ZigOs i686 keyboard ring failed: ");
    writeAll(reason);
    writeAll("\r\n");
    haltForever();
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
    kernel_alias_table = alias_table;
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
    verifyPci();
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
    if (!loadFatCache()) fatFailure("FAT cache or mirror mismatch");
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

    const next_cluster = fatReadEntry(fat_file_cluster) orelse fatFailure("read cached FAT");
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
    writeAll(" FAT-cache mirrored heap-restored yes\r\n");
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
    verifyAdvancedVirtualMemory();
}

fn pageEntryPointer(directory_address: u32, virtual_address: u32) ?*volatile u32 {
    const directory: [*]volatile u32 = @ptrFromInt(directory_address);
    const directory_index: usize = @intCast(virtual_address >> 22);
    const directory_entry = directory[directory_index];
    if ((directory_entry & 0x001) == 0) return null;
    const table: [*]volatile u32 = @ptrFromInt(directory_entry & 0xFFFF_F000);
    const table_index: usize = @intCast((virtual_address >> 12) & 0x03FF);
    return &table[table_index];
}

fn queryPageEntry(directory_address: u32, virtual_address: u32) ?u32 {
    const entry = pageEntryPointer(directory_address, virtual_address) orelse return null;
    if ((entry.* & 0x001) == 0) return null;
    return entry.*;
}

fn mapPageExisting(directory_address: u32, virtual_address: u32, physical_address: u32, flags: u32) bool {
    if ((virtual_address & 0x0FFF) != 0 or (physical_address & 0x0FFF) != 0) return false;
    const entry = pageEntryPointer(directory_address, virtual_address) orelse return false;
    if ((entry.* & 0x001) == 0) {
        vm_map_count +|= 1;
    } else {
        vm_remap_count +|= 1;
    }
    entry.* = physical_address | (flags & 0x0FFE) | 0x001;
    zigos_i686_invalidate_page(virtual_address);
    return true;
}

fn unmapPageExisting(directory_address: u32, virtual_address: u32) ?u32 {
    const entry = pageEntryPointer(directory_address, virtual_address) orelse return null;
    if ((entry.* & 0x001) == 0) return null;
    const previous = entry.*;
    entry.* = 0;
    zigos_i686_invalidate_page(virtual_address);
    vm_unmap_count +|= 1;
    return previous;
}

fn resetUserFaultProbe() void {
    process_faulted = false;
    process_fault_vector = 0;
    process_fault_address = 0;
    process_fault_error = 0;
    user_return_eax = 0;
    user_return_cs = 0;
    user_return_ss = 0;
    user_return_esp = 0;
}

fn installUserProbe(program: []const u8) void {
    const code: [*]volatile u8 = @ptrFromInt(user_code_frame);
    for (0..512) |index| code[index] = 0;
    for (program, 0..) |byte, index| code[index] = byte;
    zigos_i686_invalidate_page(0x0040_0000);
}

fn runUserFaultProbe(pid: u32) void {
    current_pid = pid;
    zigos_i686_enter_user(0x0040_0000, 0x0040_2000);
    current_pid = 0;
}

fn verifyAdvancedVirtualMemory() void {
    const saved_pid = current_pid;
    const free_before = free_frame_count;
    vm_map_count = 0;
    vm_remap_count = 0;
    vm_unmap_count = 0;
    vm_fault_recovery_count = 0;
    vm_fault_containment_count = 0;
    const first_frame = allocateFrame() orelse pagingFailure("advanced first frame");
    const second_frame = allocateFrame() orelse pagingFailure("advanced second frame");
    const zero_frame = allocateFrame() orelse pagingFailure("demand-zero frame");
    zeroPhysicalFrame(first_frame);
    zeroPhysicalFrame(second_frame);
    zeroPhysicalFrame(zero_frame);

    const alias_virtual: u32 = 0xC000_1000;
    const first_value: *volatile u32 = @ptrFromInt(first_frame);
    const second_value: *volatile u32 = @ptrFromInt(second_frame);
    first_value.* = 0x1111_AAAA;
    second_value.* = 0x2222_BBBB;
    if (!mapPageExisting(kernel_page_directory, alias_virtual, first_frame, 0x002)) pagingFailure("advanced map");
    const alias: *volatile u32 = @ptrFromInt(alias_virtual);
    if (alias.* != first_value.*) pagingFailure("advanced mapped read");
    const first_entry = queryPageEntry(kernel_page_directory, alias_virtual) orelse pagingFailure("advanced query");
    if ((first_entry & 0xFFFF_F000) != first_frame or (first_entry & 0x007) != 0x003) pagingFailure("advanced flags");
    if (!mapPageExisting(kernel_page_directory, alias_virtual, second_frame, 0x002)) pagingFailure("advanced remap");
    if (alias.* != second_value.* or first_value.* != 0x1111_AAAA) pagingFailure("advanced TLB coherence");
    const removed = unmapPageExisting(kernel_page_directory, alias_virtual) orelse pagingFailure("advanced unmap");
    if ((removed & 0xFFFF_F000) != second_frame or queryPageEntry(kernel_page_directory, alias_virtual) != null) {
        pagingFailure("advanced unmap query");
    }

    const user_table: [*]volatile u32 = @ptrFromInt(kernel_identity_tables[1]);
    _ = unmapPageExisting(kernel_page_directory, 0x0040_3000);
    demand_page_active = true;
    demand_page_virtual = 0x0040_3000;
    demand_page_frame = zero_frame;
    demand_page_faults = 0;
    demand_page_error = 0;
    resetUserFaultProbe();
    const demand_program = [_]u8{
        0xC7, 0x05, 0x00, 0x30, 0x40, 0x00, 0xED, 0xFE, 0x0D, 0xD0,
        0xA1, 0x00, 0x30, 0x40, 0x00, 0xCD, 0x30, 0xF4,
    };
    installUserProbe(&demand_program);
    runUserFaultProbe(0xF0);
    const demand_value: *const volatile u32 = @ptrFromInt(zero_frame);
    if (process_faulted or demand_page_active or demand_page_faults != 1 or demand_page_error != 0x06 or
        demand_value.* != 0xD00D_FEED or user_return_eax != 0xD00D_FEED)
    {
        pagingFailure("demand-zero recovery");
    }
    _ = unmapPageExisting(kernel_page_directory, 0x0040_3000) orelse pagingFailure("demand unmap");

    const read_only_program = [_]u8{
        0xC7, 0x05, 0x00, 0x02, 0x40, 0x00, 0x44, 0x33, 0x22, 0x11,
        0xCD, 0x30, 0xF4,
    };
    installUserProbe(&read_only_program);
    user_table[0] = user_code_frame | 0x005;
    zigos_i686_invalidate_page(0x0040_0000);
    resetUserFaultProbe();
    runUserFaultProbe(0xF1);
    if (!process_faulted or process_fault_vector != 14 or process_fault_address != 0x0040_0200 or process_fault_error != 0x07) {
        pagingFailure("read-only containment");
    }
    user_table[0] = user_code_frame | 0x007;
    zigos_i686_invalidate_page(0x0040_0000);

    const supervisor_program = [_]u8{ 0xA1, 0x00, 0x00, 0x01, 0x00, 0xCD, 0x30, 0xF4 };
    installUserProbe(&supervisor_program);
    resetUserFaultProbe();
    runUserFaultProbe(0xF2);
    if (!process_faulted or process_fault_vector != 14 or process_fault_address != 0x0001_0000 or process_fault_error != 0x05) {
        pagingFailure("supervisor isolation");
    }

    user_table[4] = 0;
    zigos_i686_invalidate_page(0x0040_4000);
    const guard_program = [_]u8{
        0xC7, 0x05, 0x00, 0x40, 0x40, 0x00, 0x78, 0x56, 0x34, 0x12,
        0xCD, 0x30, 0xF4,
    };
    installUserProbe(&guard_program);
    resetUserFaultProbe();
    runUserFaultProbe(0xF3);
    if (!process_faulted or process_fault_vector != 14 or process_fault_address != 0x0040_4000 or process_fault_error != 0x06) {
        pagingFailure("guard-page containment");
    }
    resetUserFaultProbe();
    current_pid = saved_pid;

    if (!freeFrame(zero_frame) or !freeFrame(second_frame) or !freeFrame(first_frame) or free_frame_count != free_before) {
        pagingFailure("advanced frame restoration");
    }
    writeAll("ZigOs i686 advanced VM verified: map 0x00000001 remap 0x00000001 unmap 0x00000002 flags-RW yes TLB-coherent yes demand-zero 0x00000001 error 0x00000006 readonly-error 0x00000007 supervisor-error 0x00000005 guard-error 0x00000006 frames-restored yes\r\n");
    verifyAdvancedThreading();
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

fn advancedThreadLoop(comptime index: usize) noreturn {
    const iterations: *volatile u32 = &advanced_thread_iterations[index];
    while (true) {
        iterations.* +|= 1;
        zigos_i686_halt();
    }
}

fn advancedThreadA() callconv(.c) noreturn {
    advancedThreadLoop(0);
}

fn advancedThreadB() callconv(.c) noreturn {
    advancedThreadLoop(1);
}

fn advancedThreadC() callconv(.c) noreturn {
    advancedThreadLoop(2);
}

fn advancedThreadD() callconv(.c) noreturn {
    advancedThreadLoop(3);
}

fn allAdvancedThreadsExited() bool {
    for (advanced_threads[1..]) |thread| if (thread.state != .exited) return false;
    return true;
}

fn scheduleAdvancedThreads(current_esp: u32) u32 {
    const current: usize = @intCast(advanced_scheduler_current);
    advanced_threads[current].stack_pointer = current_esp;
    if (current != 0) {
        var thread = &advanced_threads[current];
        thread.quanta +|= 1;
        if (current == 1 and thread.quanta == 1) {
            thread.state = .sleeping;
            thread.wake_tick = timer_ticks +% 4;
            advanced_scheduler_sleep_count +|= 1;
        } else if (current == 2 and thread.quanta == 1) {
            thread.state = .blocked;
            advanced_scheduler_block_count +|= 1;
        } else if (thread.quanta >= 3) {
            thread.state = .exited;
            advanced_scheduler_exit_count +|= 1;
        } else {
            thread.state = .ready;
        }
        if (current == 3 and thread.quanta == 2 and advanced_threads[2].state == .blocked) {
            advanced_threads[2].state = .ready;
            advanced_scheduler_signal_count +|= 1;
            advanced_scheduler_wake_count +|= 1;
        }
    }

    for (advanced_threads[1..]) |*thread| {
        if (thread.state == .sleeping and timer_ticks >= thread.wake_tick) {
            thread.state = .ready;
            advanced_scheduler_wake_count +|= 1;
        }
    }
    if (allAdvancedThreadsExited()) {
        advanced_scheduler_active = false;
        advanced_scheduler_done = true;
        advanced_scheduler_current = 0;
        advanced_scheduler_switches +|= 1;
        return advanced_threads[0].stack_pointer;
    }

    var distance: u32 = 1;
    while (distance <= 4) : (distance += 1) {
        const candidate: usize = @intCast(((advanced_scheduler_current + distance - 1) % 4) + 1);
        if (advanced_threads[candidate].state != .ready) continue;
        advanced_threads[candidate].state = .running;
        advanced_scheduler_current = @intCast(candidate);
        advanced_scheduler_switches +|= 1;
        advanced_scheduler_dispatches +|= 1;
        return advanced_threads[candidate].stack_pointer;
    }
    advancedSchedulerFailure("no runnable thread");
}

fn prepareAdvancedThread(index: usize, entry: u32) void {
    const stack_index = index - 1;
    const canary: u8 = 0xA0 + @as(u8, @intCast(index));
    @memset(advanced_thread_stacks[stack_index][0..32], canary);
    advanced_threads[index] = .{
        .stack_pointer = initializeKernelTask(&advanced_thread_stacks[stack_index], entry),
        .state = .ready,
    };
}

fn verifyAdvancedThreading() void {
    advanced_threads = @splat(.{});
    advanced_thread_iterations = @splat(0);
    advanced_scheduler_current = 0;
    advanced_scheduler_switches = 0;
    advanced_scheduler_dispatches = 0;
    advanced_scheduler_sleep_count = 0;
    advanced_scheduler_block_count = 0;
    advanced_scheduler_signal_count = 0;
    advanced_scheduler_wake_count = 0;
    advanced_scheduler_exit_count = 0;
    advanced_scheduler_done = false;
    advanced_threads[0].state = .running;
    prepareAdvancedThread(1, @intCast(@intFromPtr(&advancedThreadA)));
    prepareAdvancedThread(2, @intCast(@intFromPtr(&advancedThreadB)));
    prepareAdvancedThread(3, @intCast(@intFromPtr(&advancedThreadC)));
    prepareAdvancedThread(4, @intCast(@intFromPtr(&advancedThreadD)));
    const start_ticks = timer_ticks;

    configurePic();
    configurePit100Hz();
    zigos_i686_out8(0x0021, 0xFE);
    advanced_scheduler_active = true;
    const done: *volatile bool = &advanced_scheduler_done;
    zigos_i686_enable_interrupts();
    while (!done.*) zigos_i686_halt();
    zigos_i686_disable_interrupts();
    zigos_i686_out8(0x0021, 0xFF);
    zigos_i686_out8(0x00A1, 0xFF);

    const elapsed = timer_ticks -% start_ticks;
    var failure_mask: u32 = 0;
    if (advanced_scheduler_active or !advanced_scheduler_done or advanced_scheduler_current != 0) failure_mask |= 1 << 0;
    if (elapsed != 13 or advanced_scheduler_switches != 13 or advanced_scheduler_dispatches != 12) failure_mask |= 1 << 1;
    if (advanced_scheduler_sleep_count != 1 or advanced_scheduler_block_count != 1 or
        advanced_scheduler_signal_count != 1 or advanced_scheduler_wake_count != 2)
    {
        failure_mask |= 1 << 2;
    }
    if (advanced_scheduler_exit_count != 4) failure_mask |= 1 << 3;
    for (advanced_threads[1..], 1..) |thread, index| {
        if (thread.state != .exited or thread.quanta != 3) failure_mask |= 1 << 4;
        if (advanced_thread_iterations[index - 1] == 0) failure_mask |= 1 << 5;
        const expected: u8 = 0xA0 + @as(u8, @intCast(index));
        for (advanced_thread_stacks[index - 1][0..32]) |byte| {
            if (byte != expected) failure_mask |= 1 << 6;
        }
    }
    if (failure_mask != 0) {
        writeAll("ZigOs i686 advanced scheduler failed: predicate-mask 0x");
        writeHex32(failure_mask);
        writeAll("\r\n");
        haltForever();
    }
    writeAll("ZigOs i686 advanced scheduler verified: threads 0x00000004 quanta 0x00000003/0x00000003/0x00000003/0x00000003 switches 0x0000000D dispatches 0x0000000C sleep 0x00000001 block 0x00000001 signal 0x00000001 wakes 0x00000002 exits 0x00000004 stack-canaries yes bootstrap-restored yes\r\n");
    verifyElfLoader();
}

fn advancedSchedulerFailure(reason: []const u8) noreturn {
    advanced_scheduler_active = false;
    zigos_i686_disable_interrupts();
    writeAll("ZigOs i686 advanced scheduler failed: ");
    writeAll(reason);
    writeAll("\r\n");
    haltForever();
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
    pipe_objects = @splat(.{});
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
    const service_index = vfsFindNode("SERVICE ELF") orelse vfsFailure("SERVICE.ELF node");
    const orch_index = vfsFindNode("ORCH    ELF") orelse vfsFailure("ORCH.ELF node");
    const child_index = vfsFindNode("CHILD   ELF") orelse vfsFailure("CHILD.ELF node");
    const paths_index = vfsFindNode("PATHS   ELF") orelse vfsFailure("PATHS.ELF node");
    notes_present_at_boot = vfsFindNode("NOTES   TXT") != null;
    cat_elf_size = vfs_nodes[cat_index].size;
    big_file_size = vfs_nodes[big_index].size;
    fault_elf_size = vfs_nodes[fault_index].size;
    writer_elf_size = vfs_nodes[writer_index].size;
    service_elf_size = vfs_nodes[service_index].size;
    orch_elf_size = vfs_nodes[orch_index].size;
    child_elf_size = vfs_nodes[child_index].size;
    paths_elf_size = vfs_nodes[paths_index].size;
    runtime_first_cluster = vfs_nodes[paths_index].cluster + @as(u16, @intCast((paths_elf_size + 511) / 512));
    hierarchy_present_at_boot = pathFindEntry(0, "HOME       ") != null;
    const expected_nodes: u32 = if (notes_present_at_boot) 13 else 12;
    if (vfs_node_count != expected_nodes or vfs_nodes[hello_index].size != expected_fat_file.len or
        vfs_nodes[init_index].size != init_elf_size or cat_elf_size != 510 or
        big_file_size != expected_big_bytes or fault_elf_size != 262 or writer_elf_size != 1488 or
        service_elf_size != 1362 or orch_elf_size != 1937 or child_elf_size != 913 or
        paths_elf_size != 4024 or runtime_first_cluster != 31 or hierarchy_present_at_boot != notes_present_at_boot)
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

    verifyNamespaceLifecycle();
    if (hierarchy_present_at_boot) verifyPersistentHierarchy();
    if (notes_present_at_boot) verifyNotesFile();

    process_table = @splat(.{});
    process_table[0] = .{
        .pid = 1,
        .parent_pid = 0,
        .process_group = 1,
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
    initializeProcessServices();

    writeAll("ZigOs i686 writable VFS ready: root-files 0x");
    writeHex32(vfs_node_count);
    writeAll(" descriptors 0x00000008 pipes 0x00000004 BIG.TXT bytes 0x");
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
    writeAll("ZigOs i686 hierarchical FAT12 ready: static-base 0x");
    writeHex32(runtime_first_cluster);
    writeAll(" PATHS.ELF bytes 0x");
    writeHex32(paths_elf_size);
    writeAll(" present ");
    writeAll(if (hierarchy_present_at_boot) "yes" else "no");
    if (hierarchy_present_at_boot) {
        writeAll(" HOME 0x");
        writeHex32(hierarchy_home_cluster);
        writeAll(" DOCS 0x");
        writeHex32(hierarchy_docs_cluster);
        writeAll(" LOG 0x");
        writeHex32(hierarchy_log_first_cluster);
        writeAll("->0x");
        writeHex32(hierarchy_log_second_cluster);
        writeAll(" ARCHIVE 0x");
        writeHex32(hierarchy_archive_cluster);
        writeAll(" hash 0x");
        writeHex32(hierarchy_hash);
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

fn loadFatCache() bool {
    if (fat_sectors_per_fat != fat_cache_sector_count or fat_bytes_per_sector != 512) return false;
    fat_cache_loaded = false;
    for (0..fat_cache_sector_count) |sector_index| {
        const cache_address: u32 = @intCast(@intFromPtr(&fat_cache) + sector_index * 512);
        if (!ataReadSector(fat_start_lba + @as(u32, @intCast(sector_index)), cache_address)) return false;
        const mirror_lba = fat_start_lba + fat_sectors_per_fat + @as(u32, @intCast(sector_index));
        if (!ataReadSector(mirror_lba, @intCast(@intFromPtr(&vfs_aux_buffer)))) return false;
        const cache_offset = sector_index * 512;
        if (!equalBytes(fat_cache[cache_offset .. cache_offset + 512], vfs_aux_buffer[0..])) return false;
    }
    fat_cache_loaded = true;
    return true;
}

fn fatReadEntry(cluster: u16) ?u16 {
    if (!validDataCluster(cluster) or !fat_cache_loaded) return null;
    const fat_offset: usize = @as(usize, cluster) + @as(usize, cluster) / 2;
    if (fat_offset + 1 >= fat_cache.len) return null;
    const pair = @as(u16, fat_cache[fat_offset]) | (@as(u16, fat_cache[fat_offset + 1]) << 8);
    return if ((cluster & 1) == 0) pair & 0x0FFF else pair >> 4;
}

fn fatWriteEntry(cluster: u16, value: u16) bool {
    if (!validDataCluster(cluster) or value > 0x0FFF or !fat_cache_loaded) return false;
    const fat_offset: usize = @as(usize, cluster) + @as(usize, cluster) / 2;
    if (fat_offset + 1 >= fat_cache.len) return false;
    const pair = @as(u16, fat_cache[fat_offset]) | (@as(u16, fat_cache[fat_offset + 1]) << 8);
    const updated = if ((cluster & 1) == 0)
        (pair & 0xF000) | value
    else
        (pair & 0x000F) | (value << 4);
    fat_cache[fat_offset] = @truncate(updated);
    fat_cache[fat_offset + 1] = @truncate(updated >> 8);

    const first_sector = fat_offset / 512;
    const last_sector = (fat_offset + 1) / 512;
    for (0..2) |copy_index| {
        var sector_index = first_sector;
        while (sector_index <= last_sector) : (sector_index += 1) {
            const lba = fat_start_lba +
                @as(u32, @intCast(copy_index)) * fat_sectors_per_fat +
                @as(u32, @intCast(sector_index));
            const cache_address: u32 = @intCast(@intFromPtr(&fat_cache) + sector_index * 512);
            if (!ataWriteSector(lba, cache_address)) return false;
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

fn vfsRenameNode(old_name: []const u8, new_name: []const u8) bool {
    if (old_name.len != 11 or new_name.len != 11 or vfsFindNode(new_name) != null) return false;
    const node_index = vfsFindNode(old_name) orelse return false;
    var node = &vfs_nodes[node_index];
    if (!ataReadSector(node.root_lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return false;
    const offset: usize = node.root_offset;
    for (0..11) |index| vfs_sector_buffer[offset + index] = new_name[index];
    if (!ataWriteSector(node.root_lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return false;
    for (0..11) |index| node.name[index] = new_name[index];
    vfs_rename_count +|= 1;
    return true;
}

fn vfsUnlinkNode(name: []const u8) bool {
    const node_index = vfsFindNode(name) orelse return false;
    for (vfs_descriptors) |descriptor| {
        if (descriptor.open and descriptor.node_index == node_index) return false;
    }
    const node = vfs_nodes[node_index];
    if (!ataReadSector(node.root_lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return false;
    const offset: usize = node.root_offset;
    vfs_sector_buffer[offset] = 0xE5;
    writeLe16(&vfs_sector_buffer, offset + 26, 0);
    writeLe32(&vfs_sector_buffer, offset + 28, 0);
    if (!ataWriteSector(node.root_lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return false;
    if (!fatFreeChain(node.cluster)) return false;
    vfs_unlink_count +|= 1;
    reloadVfsRoot();
    return true;
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
    if ((flags & ~(vfs_open_read | vfs_open_write | vfs_open_create | vfs_open_truncate | vfs_open_append | vfs_open_cloexec)) != 0 or
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
            .kind = .file,
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
    if (!descriptor.open or descriptor.owner_pid != owner_pid or descriptor.kind != .file or
        (descriptor.flags & vfs_open_read) == 0) return null;
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
    if (!descriptor.open or descriptor.owner_pid != owner_pid or descriptor.kind != .file or
        (descriptor.flags & vfs_open_write) == 0) return null;
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
    if (!descriptor.open or descriptor.owner_pid != owner_pid or descriptor.kind != .file) return null;
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
    const descriptor = vfs_descriptors[index];
    if (descriptor.kind == .pipe_read or descriptor.kind == .pipe_write) {
        const pipe_index: usize = descriptor.pipe_index;
        if (pipe_index >= pipe_objects.len or !pipe_objects[pipe_index].active) return false;
        var pipe = &pipe_objects[pipe_index];
        if (descriptor.kind == .pipe_read) {
            if (pipe.readers == 0) return false;
            pipe.readers -= 1;
        } else {
            if (pipe.writers == 0) return false;
            pipe.writers -= 1;
        }
        if (pipe.readers == 0 and pipe.writers == 0) pipe.* = .{};
    }
    vfs_descriptors[index] = .{};
    vfs_close_count +|= 1;
    return true;
}

fn vfsCloseAllOwned(owner_pid: u32) u32 {
    var closed: u32 = 0;
    for (0..vfs_descriptors.len) |index| {
        if (!vfs_descriptors[index].open or vfs_descriptors[index].owner_pid != owner_pid) continue;
        if (!vfsCloseOwned(@intCast(index), owner_pid)) return closed;
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

fn vfsStatToBuffer(name: []const u8, destination: []u8) bool {
    if (name.len != 11 or destination.len < 16) return false;
    const node_index = vfsFindNode(name) orelse return false;
    const node = &vfs_nodes[node_index];
    writeLe32(destination, 0, node.size);
    writeLe32(destination, 4, node.cluster);
    writeLe32(destination, 8, node.attributes);
    writeLe32(destination, 12, 1);
    return true;
}

fn pipeCreateOwned(owner_pid: u32, output: []u8) bool {
    if (owner_pid == 0 or output.len < 8) return false;
    var pipe_slot: ?usize = null;
    for (&pipe_objects, 0..) |*pipe, index| {
        if (!pipe.active) {
            pipe_slot = index;
            break;
        }
    }
    const resolved_pipe = pipe_slot orelse return false;
    var descriptor_slots: [2]usize = undefined;
    var found: usize = 0;
    for (vfs_descriptors, 0..) |descriptor, index| {
        if (!descriptor.open) {
            descriptor_slots[found] = index;
            found += 1;
            if (found == descriptor_slots.len) break;
        }
    }
    if (found != descriptor_slots.len) return false;
    pipe_objects[resolved_pipe] = .{ .readers = 1, .writers = 1, .active = true };
    vfs_descriptors[descriptor_slots[0]] = .{
        .pipe_index = @intCast(resolved_pipe),
        .kind = .pipe_read,
        .owner_pid = owner_pid,
        .open = true,
    };
    vfs_descriptors[descriptor_slots[1]] = .{
        .pipe_index = @intCast(resolved_pipe),
        .kind = .pipe_write,
        .owner_pid = owner_pid,
        .open = true,
    };
    writeLe32(output, 0, @intCast(descriptor_slots[0]));
    writeLe32(output, 4, @intCast(descriptor_slots[1]));
    return true;
}

fn descriptorReadOwned(fd: u8, owner_pid: u32, destination: []u8) ?usize {
    const index: usize = fd;
    if (index >= vfs_descriptors.len or !vfs_descriptors[index].open or
        vfs_descriptors[index].owner_pid != owner_pid) return null;
    if (vfs_descriptors[index].kind == .file) return vfsReadOwned(fd, owner_pid, destination);
    if (vfs_descriptors[index].kind != .pipe_read) return null;
    const pipe_index: usize = vfs_descriptors[index].pipe_index;
    if (pipe_index >= pipe_objects.len or !pipe_objects[pipe_index].active) return null;
    var pipe = &pipe_objects[pipe_index];
    const amount = @min(destination.len, @as(usize, pipe.count));
    for (0..amount) |offset| {
        destination[offset] = pipe.buffer[pipe.head];
        pipe.head = @intCast((@as(usize, pipe.head) + 1) % pipe.buffer.len);
        pipe.count -= 1;
    }
    syscall_pipe_read_count +|= 1;
    return amount;
}

fn descriptorWriteOwned(fd: u8, owner_pid: u32, source: []const u8) ?usize {
    const index: usize = fd;
    if (index >= vfs_descriptors.len or !vfs_descriptors[index].open or
        vfs_descriptors[index].owner_pid != owner_pid) return null;
    if (vfs_descriptors[index].kind == .file) return vfsWriteOwned(fd, owner_pid, source);
    if (vfs_descriptors[index].kind != .pipe_write) return null;
    const pipe_index: usize = vfs_descriptors[index].pipe_index;
    if (pipe_index >= pipe_objects.len or !pipe_objects[pipe_index].active) return null;
    var pipe = &pipe_objects[pipe_index];
    if (pipe.readers == 0 or source.len > pipe.buffer.len - pipe.count) return null;
    for (source) |byte| {
        pipe.buffer[pipe.tail] = byte;
        pipe.tail = @intCast((@as(usize, pipe.tail) + 1) % pipe.buffer.len);
        pipe.count += 1;
    }
    syscall_pipe_write_count +|= 1;
    return source.len;
}

fn duplicateDescriptorOwned(source_fd: u8, owner_pid: u32, requested_target: ?u8) ?u8 {
    const source_index: usize = source_fd;
    if (source_index >= vfs_descriptors.len or !vfs_descriptors[source_index].open or
        vfs_descriptors[source_index].owner_pid != owner_pid) return null;
    if (requested_target != null and requested_target.? == source_fd) return source_fd;
    var target_index: usize = undefined;
    if (requested_target) |target_fd| {
        target_index = target_fd;
        if (target_index >= vfs_descriptors.len) return null;
        if (vfs_descriptors[target_index].open) {
            if (vfs_descriptors[target_index].owner_pid != owner_pid or
                !vfsCloseOwned(target_fd, owner_pid)) return null;
        }
    } else {
        var target: ?usize = null;
        for (vfs_descriptors, 0..) |descriptor, index| {
            if (!descriptor.open) {
                target = index;
                break;
            }
        }
        target_index = target orelse return null;
    }
    const source = vfs_descriptors[source_index];
    vfs_descriptors[target_index] = source;
    if (source.kind == .pipe_read or source.kind == .pipe_write) {
        const pipe_index: usize = source.pipe_index;
        if (pipe_index >= pipe_objects.len or !pipe_objects[pipe_index].active) {
            vfs_descriptors[target_index] = .{};
            return null;
        }
        if (source.kind == .pipe_read) pipe_objects[pipe_index].readers +|= 1 else pipe_objects[pipe_index].writers +|= 1;
    }
    return @intCast(target_index);
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

fn parsePath(path: []const u8) ?ParsedPath {
    if (path.len == 0 or path.len > path_max_bytes) return null;
    var result: ParsedPath = .{ .absolute = path[0] == '/' };
    var cursor: usize = 0;
    while (cursor < path.len) {
        while (cursor < path.len and path[cursor] == '/') cursor += 1;
        if (cursor == path.len) break;
        const start = cursor;
        while (cursor < path.len and path[cursor] != '/') cursor += 1;
        const component = path[start..cursor];
        if (equalBytes(component, ".")) continue;
        if (result.count >= result.tokens.len) return null;
        const token_index: usize = result.count;
        if (equalBytes(component, "..")) {
            result.tokens[token_index] = .{ .kind = .parent };
        } else {
            const name = parseFatDisplayName(component) orelse return null;
            result.tokens[token_index] = .{ .name = name, .kind = .name };
        }
        result.count += 1;
    }
    return result;
}

fn pathDirectoryLba(cluster: u16, sector_index: u16) ?u32 {
    if (cluster == 0) {
        if (sector_index >= fat_root_sectors) return null;
        return fat_root_lba + sector_index;
    }
    if (!validDataCluster(cluster) or sector_index != 0 or fat_sectors_per_cluster != 1) return null;
    return fat_data_lba + (@as(u32, cluster) - 2);
}

fn pathFindEntry(directory_cluster: u16, name: []const u8) ?PathEntry {
    if (name.len != 11) return null;
    const sector_count: u16 = if (directory_cluster == 0) fat_root_sectors else 1;
    var sector_index: u16 = 0;
    while (sector_index < sector_count) : (sector_index += 1) {
        const lba = pathDirectoryLba(directory_cluster, sector_index) orelse return null;
        if (!ataReadSector(lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return null;
        for (0..16) |entry_index| {
            const offset = entry_index * 32;
            const first = vfs_sector_buffer[offset];
            if (first == 0) return null;
            if (first == 0xE5) continue;
            const attributes = vfs_sector_buffer[offset + 11];
            if (attributes == 0x0F or (attributes & 0x08) != 0) continue;
            if (!equalBytes(vfs_sector_buffer[offset .. offset + 11], name)) continue;
            var entry: PathEntry = .{
                .cluster = readLe16(&vfs_sector_buffer, offset + 26),
                .parent_cluster = directory_cluster,
                .entry_lba = lba,
                .size = readLe32(&vfs_sector_buffer, offset + 28),
                .entry_offset = @intCast(offset),
                .attributes = attributes,
            };
            for (0..11) |index| entry.name[index] = vfs_sector_buffer[offset + index];
            return entry;
        }
    }
    return null;
}

fn pathFindFreeSlot(directory_cluster: u16) ?DirectorySlot {
    const sector_count: u16 = if (directory_cluster == 0) fat_root_sectors else 1;
    var sector_index: u16 = 0;
    while (sector_index < sector_count) : (sector_index += 1) {
        const lba = pathDirectoryLba(directory_cluster, sector_index) orelse return null;
        if (!ataReadSector(lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return null;
        for (0..16) |entry_index| {
            const offset = entry_index * 32;
            if (vfs_sector_buffer[offset] == 0 or vfs_sector_buffer[offset] == 0xE5) {
                return .{ .lba = lba, .offset = @intCast(offset) };
            }
        }
    }
    return null;
}

fn pathWriteSlot(slot: DirectorySlot, name: []const u8, attributes: u8, cluster: u16, size: u32) bool {
    if (name.len != 11 or !ataReadSector(slot.lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return false;
    const offset: usize = slot.offset;
    const first = vfs_sector_buffer[offset];
    if (first != 0 and first != 0xE5) return false;
    @memset(vfs_sector_buffer[offset .. offset + 32], 0);
    for (0..11) |index| vfs_sector_buffer[offset + index] = name[index];
    vfs_sector_buffer[offset + 11] = attributes;
    writeLe16(&vfs_sector_buffer, offset + 26, cluster);
    writeLe32(&vfs_sector_buffer, offset + 28, size);
    return ataWriteSector(slot.lba, @intCast(@intFromPtr(&vfs_sector_buffer)));
}

fn pathUpdateEntry(entry: PathEntry, cluster: u16, size: u32) bool {
    if (!ataReadSector(entry.entry_lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return false;
    const offset: usize = entry.entry_offset;
    if (vfs_sector_buffer[offset] == 0 or vfs_sector_buffer[offset] == 0xE5) return false;
    writeLe16(&vfs_sector_buffer, offset + 26, cluster);
    writeLe32(&vfs_sector_buffer, offset + 28, size);
    return ataWriteSector(entry.entry_lba, @intCast(@intFromPtr(&vfs_sector_buffer)));
}

fn pathDeleteEntry(entry: PathEntry) bool {
    if (!ataReadSector(entry.entry_lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return false;
    const offset: usize = entry.entry_offset;
    if (vfs_sector_buffer[offset] == 0 or vfs_sector_buffer[offset] == 0xE5) return false;
    vfs_sector_buffer[offset] = 0xE5;
    writeLe16(&vfs_sector_buffer, offset + 26, 0);
    writeLe32(&vfs_sector_buffer, offset + 28, 0);
    return ataWriteSector(entry.entry_lba, @intCast(@intFromPtr(&vfs_sector_buffer)));
}

fn pathDirectoryParent(cluster: u16) ?u16 {
    if (cluster == 0) return 0;
    const parent = pathFindEntry(cluster, "..         ") orelse return null;
    if ((parent.attributes & 0x10) == 0) return null;
    return parent.cluster;
}

fn processCwdCluster(pid: u32) ?u16 {
    if (pid == 0) return 0;
    const index = processRecordIndex(pid) orelse return null;
    return process_table[index].cwd_cluster;
}

fn pathSyntheticDirectory(cluster: u16) PathEntry {
    return .{ .cluster = cluster, .parent_cluster = pathDirectoryParent(cluster) orelse 0, .attributes = 0x10 };
}

fn pathResolve(pid: u32, path: []const u8) ?PathEntry {
    const parsed = parsePath(path) orelse return null;
    var directory = if (parsed.absolute) @as(u16, 0) else processCwdCluster(pid) orelse return null;
    if (parsed.count == 0) return pathSyntheticDirectory(directory);
    for (parsed.tokens[0..parsed.count], 0..) |token, index| {
        if (token.kind == .parent) {
            directory = pathDirectoryParent(directory) orelse return null;
            if (index + 1 == parsed.count) return pathSyntheticDirectory(directory);
            continue;
        }
        const entry = pathFindEntry(directory, token.name[0..]) orelse return null;
        if (index + 1 == parsed.count) return entry;
        if ((entry.attributes & 0x10) == 0 or entry.cluster < 2) return null;
        directory = entry.cluster;
    }
    return null;
}

fn pathResolveParent(pid: u32, path: []const u8) ?PathParent {
    const parsed = parsePath(path) orelse return null;
    if (parsed.count == 0) return null;
    const last_index: usize = parsed.count - 1;
    if (parsed.tokens[last_index].kind != .name) return null;
    var directory = if (parsed.absolute) @as(u16, 0) else processCwdCluster(pid) orelse return null;
    for (parsed.tokens[0..last_index]) |token| {
        if (token.kind == .parent) {
            directory = pathDirectoryParent(directory) orelse return null;
            continue;
        }
        const entry = pathFindEntry(directory, token.name[0..]) orelse return null;
        if ((entry.attributes & 0x10) == 0 or entry.cluster < 2) return null;
        directory = entry.cluster;
    }
    return .{ .directory_cluster = directory, .leaf = parsed.tokens[last_index].name };
}

fn pathChildName(parent_cluster: u16, child_cluster: u16) ?[11]u8 {
    const sector_count: u16 = if (parent_cluster == 0) fat_root_sectors else 1;
    var sector_index: u16 = 0;
    while (sector_index < sector_count) : (sector_index += 1) {
        const lba = pathDirectoryLba(parent_cluster, sector_index) orelse return null;
        if (!ataReadSector(lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return null;
        for (0..16) |entry_index| {
            const offset = entry_index * 32;
            const first = vfs_sector_buffer[offset];
            if (first == 0) return null;
            if (first == 0xE5) continue;
            const attributes = vfs_sector_buffer[offset + 11];
            if ((attributes & 0x10) == 0 or attributes == 0x0F) continue;
            if (readLe16(&vfs_sector_buffer, offset + 26) != child_cluster) continue;
            if (vfs_sector_buffer[offset] == '.') continue;
            var name: [11]u8 = undefined;
            for (0..11) |index| name[index] = vfs_sector_buffer[offset + index];
            return name;
        }
    }
    return null;
}

fn appendFatName(destination: []u8, cursor: *usize, name: *const [11]u8, directory: bool) bool {
    var base_length: usize = 8;
    while (base_length > 0 and name[base_length - 1] == ' ') base_length -= 1;
    var extension_length: usize = 3;
    while (extension_length > 0 and name[8 + extension_length - 1] == ' ') extension_length -= 1;
    const needed = base_length + (if (extension_length == 0) @as(usize, 0) else 1 + extension_length) + (if (directory) @as(usize, 1) else 0);
    if (cursor.* + needed > destination.len) return false;
    for (name[0..base_length]) |byte| {
        destination[cursor.*] = byte;
        cursor.* += 1;
    }
    if (extension_length != 0) {
        destination[cursor.*] = '.';
        cursor.* += 1;
        for (name[8 .. 8 + extension_length]) |byte| {
            destination[cursor.*] = byte;
            cursor.* += 1;
        }
    }
    if (directory) {
        destination[cursor.*] = '/';
        cursor.* += 1;
    }
    return true;
}

fn pathGetCwd(pid: u32, destination: []u8) ?usize {
    var cluster = processCwdCluster(pid) orelse return null;
    if (cluster == 0) {
        if (destination.len < 1) return null;
        destination[0] = '/';
        return 1;
    }
    var names: [path_max_components][11]u8 = undefined;
    var count: usize = 0;
    while (cluster != 0) {
        if (count >= names.len) return null;
        const parent = pathDirectoryParent(cluster) orelse return null;
        names[count] = pathChildName(parent, cluster) orelse return null;
        count += 1;
        cluster = parent;
    }
    var cursor: usize = 0;
    var index = count;
    while (index != 0) {
        index -= 1;
        if (cursor >= destination.len) return null;
        destination[cursor] = '/';
        cursor += 1;
        if (!appendFatName(destination, &cursor, &names[index], false)) return null;
    }
    return cursor;
}

fn pathChangeDirectory(pid: u32, path: []const u8) bool {
    if (pid == 0) return false;
    const entry = pathResolve(pid, path) orelse return false;
    if ((entry.attributes & 0x10) == 0) return false;
    const index = processRecordIndex(pid) orelse return false;
    process_table[index].cwd_cluster = entry.cluster;
    return true;
}

fn pathInitializeDirectory(cluster: u16, parent_cluster: u16) bool {
    const lba = pathDirectoryLba(cluster, 0) orelse return false;
    @memset(vfs_sector_buffer[0..], 0);
    const dot = fatName(".          ");
    const dotdot = fatName("..         ");
    for (0..11) |index| vfs_sector_buffer[index] = dot[index];
    vfs_sector_buffer[11] = 0x10;
    writeLe16(&vfs_sector_buffer, 26, cluster);
    for (0..11) |index| vfs_sector_buffer[32 + index] = dotdot[index];
    vfs_sector_buffer[43] = 0x10;
    writeLe16(&vfs_sector_buffer, 58, parent_cluster);
    return ataWriteSector(lba, @intCast(@intFromPtr(&vfs_sector_buffer)));
}

fn pathMakeDirectory(pid: u32, path: []const u8) ?u16 {
    const parent = pathResolveParent(pid, path) orelse return null;
    if (pathFindEntry(parent.directory_cluster, parent.leaf[0..]) != null) return null;
    const slot = pathFindFreeSlot(parent.directory_cluster) orelse return null;
    const cluster = fatAllocateCluster() orelse return null;
    if (!pathInitializeDirectory(cluster, parent.directory_cluster)) {
        _ = fatFreeChain(cluster);
        return null;
    }
    if (!pathWriteSlot(slot, parent.leaf[0..], 0x10, cluster, 0)) {
        _ = fatFreeChain(cluster);
        return null;
    }
    hierarchy_mkdir_count +|= 1;
    return cluster;
}

fn pathDirectoryEmpty(cluster: u16) bool {
    const lba = pathDirectoryLba(cluster, 0) orelse return false;
    if (!ataReadSector(lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return false;
    for (0..16) |entry_index| {
        const offset = entry_index * 32;
        const first = vfs_sector_buffer[offset];
        if (first == 0) return true;
        if (first == 0xE5 or first == '.') continue;
        const attributes = vfs_sector_buffer[offset + 11];
        if (attributes == 0x0F or (attributes & 0x08) != 0) continue;
        return false;
    }
    return true;
}

fn pathRemoveDirectory(pid: u32, path: []const u8) bool {
    const entry = pathResolve(pid, path) orelse return false;
    if ((entry.attributes & 0x10) == 0 or entry.cluster < 2 or !pathDirectoryEmpty(entry.cluster)) return false;
    for (process_table) |record| {
        if (record.state != .free and record.cwd_cluster == entry.cluster) return false;
    }
    if (!pathDeleteEntry(entry) or !fatFreeChain(entry.cluster)) return false;
    hierarchy_rmdir_count +|= 1;
    return true;
}

fn pathEntryClusterAt(entry: PathEntry, ordinal: u32) ?u16 {
    if (entry.cluster == 0) return null;
    var cluster = entry.cluster;
    var index: u32 = 0;
    while (index < ordinal) : (index += 1) {
        const next = fatReadEntry(cluster) orelse return null;
        if (next >= 0x0FF8 or !validDataCluster(next)) return null;
        cluster = next;
    }
    return cluster;
}

fn pathReadEntryData(entry: PathEntry, destination: []u8) ?usize {
    if ((entry.attributes & 0x10) != 0 or entry.size > destination.len or entry.size > 4096) return null;
    var copied: usize = 0;
    while (copied < entry.size) {
        const ordinal: u32 = @intCast(copied / 512);
        const cluster = pathEntryClusterAt(entry, ordinal) orelse return null;
        const lba = pathDirectoryLba(cluster, 0) orelse return null;
        if (!ataReadSector(lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return null;
        const chunk = @min(@as(usize, @intCast(entry.size)) - copied, 512);
        for (0..chunk) |index| destination[copied + index] = vfs_sector_buffer[index];
        copied += chunk;
    }
    return copied;
}

fn pathAllocateData(data: []const u8) ?u16 {
    if (data.len == 0) return 0;
    var first: u16 = 0;
    var previous: u16 = 0;
    var copied: usize = 0;
    while (copied < data.len) {
        const cluster = fatAllocateCluster() orelse {
            if (first != 0) _ = fatFreeChain(first);
            return null;
        };
        if (first == 0) first = cluster;
        if (previous != 0 and !fatWriteEntry(previous, cluster)) {
            _ = fatFreeChain(first);
            return null;
        }
        @memset(vfs_sector_buffer[0..], 0);
        const chunk = @min(data.len - copied, 512);
        for (0..chunk) |index| vfs_sector_buffer[index] = data[copied + index];
        const lba = pathDirectoryLba(cluster, 0) orelse {
            _ = fatFreeChain(first);
            return null;
        };
        if (!ataWriteSector(lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) {
            _ = fatFreeChain(first);
            return null;
        }
        copied += chunk;
        previous = cluster;
    }
    return first;
}

fn pathWriteFile(pid: u32, path: []const u8, source: []const u8, flags: u32) ?usize {
    if ((flags & ~(path_write_create | path_write_truncate | path_write_append)) != 0 or source.len > 2048) return null;
    const parent = pathResolveParent(pid, path) orelse return null;
    const existing = pathFindEntry(parent.directory_cluster, parent.leaf[0..]);
    if (existing == null and (flags & path_write_create) == 0) return null;
    if (existing) |entry| if ((entry.attributes & 0x10) != 0) return null;

    var final_data: []const u8 = source;
    if (existing != null and (flags & path_write_append) != 0) {
        const entry = existing.?;
        if (entry.size + source.len > vfs_large_buffer.len) return null;
        const old_amount = pathReadEntryData(entry, vfs_large_buffer[0..]) orelse return null;
        for (source, 0..) |byte, index| vfs_large_buffer[old_amount + index] = byte;
        final_data = vfs_large_buffer[0 .. old_amount + source.len];
    } else if (existing != null and (flags & path_write_truncate) == 0) {
        return null;
    }

    const new_cluster = pathAllocateData(final_data) orelse return null;
    if (existing) |entry| {
        if (!pathUpdateEntry(entry, new_cluster, @intCast(final_data.len))) {
            _ = fatFreeChain(new_cluster);
            return null;
        }
        if (entry.cluster != 0 and !fatFreeChain(entry.cluster)) return null;
    } else {
        const slot = pathFindFreeSlot(parent.directory_cluster) orelse {
            _ = fatFreeChain(new_cluster);
            return null;
        };
        if (!pathWriteSlot(slot, parent.leaf[0..], 0x20, new_cluster, @intCast(final_data.len))) {
            _ = fatFreeChain(new_cluster);
            return null;
        }
    }
    return source.len;
}

fn pathReadFile(pid: u32, path: []const u8, destination: []u8) ?usize {
    const entry = pathResolve(pid, path) orelse return null;
    return pathReadEntryData(entry, destination);
}

fn pathStatFile(pid: u32, path: []const u8, destination: []u8) bool {
    if (destination.len < 16) return false;
    const entry = pathResolve(pid, path) orelse return false;
    var clusters: u32 = 0;
    if (entry.cluster != 0) {
        var cluster = entry.cluster;
        while (clusters <= fat_cluster_count) {
            clusters += 1;
            const next = fatReadEntry(cluster) orelse return false;
            if (next >= 0x0FF8) break;
            if (!validDataCluster(next)) return false;
            cluster = next;
        }
    }
    writeLe32(destination, 0, entry.size);
    writeLe32(destination, 4, entry.cluster);
    writeLe32(destination, 8, entry.attributes);
    writeLe32(destination, 12, clusters);
    return true;
}

fn pathRename(pid: u32, old_path: []const u8, new_path: []const u8) bool {
    const old_entry = pathResolve(pid, old_path) orelse return false;
    const target = pathResolveParent(pid, new_path) orelse return false;
    if (pathFindEntry(target.directory_cluster, target.leaf[0..]) != null) return false;
    if (old_entry.parent_cluster == target.directory_cluster) {
        if (!ataReadSector(old_entry.entry_lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return false;
        const offset: usize = old_entry.entry_offset;
        for (0..11) |index| vfs_sector_buffer[offset + index] = target.leaf[index];
        if (!ataWriteSector(old_entry.entry_lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return false;
    } else {
        if ((old_entry.attributes & 0x10) != 0) return false;
        const slot = pathFindFreeSlot(target.directory_cluster) orelse return false;
        if (!pathWriteSlot(slot, target.leaf[0..], old_entry.attributes, old_entry.cluster, old_entry.size)) return false;
        if (!pathDeleteEntry(old_entry)) {
            const rollback = pathFindEntry(target.directory_cluster, target.leaf[0..]) orelse return false;
            _ = pathDeleteEntry(rollback);
            return false;
        }
    }
    hierarchy_rename_count +|= 1;
    return true;
}

fn pathUnlink(pid: u32, path: []const u8) bool {
    const entry = pathResolve(pid, path) orelse return false;
    if ((entry.attributes & 0x10) != 0) return false;
    if (!pathDeleteEntry(entry)) return false;
    if (entry.cluster != 0 and !fatFreeChain(entry.cluster)) return false;
    hierarchy_unlink_count +|= 1;
    return true;
}

fn pathListDirectory(pid: u32, path: []const u8, destination: []u8) ?usize {
    const directory = pathResolve(pid, path) orelse return null;
    if ((directory.attributes & 0x10) == 0) return null;
    const sector_count: u16 = if (directory.cluster == 0) fat_root_sectors else 1;
    var cursor: usize = 0;
    var sector_index: u16 = 0;
    while (sector_index < sector_count) : (sector_index += 1) {
        const lba = pathDirectoryLba(directory.cluster, sector_index) orelse return null;
        if (!ataReadSector(lba, @intCast(@intFromPtr(&vfs_sector_buffer)))) return null;
        for (0..16) |entry_index| {
            const offset = entry_index * 32;
            const first = vfs_sector_buffer[offset];
            if (first == 0) return cursor;
            if (first == 0xE5 or first == '.') continue;
            const attributes = vfs_sector_buffer[offset + 11];
            if (attributes == 0x0F or (attributes & 0x08) != 0) continue;
            var name: [11]u8 = undefined;
            for (0..11) |index| name[index] = vfs_sector_buffer[offset + index];
            if (!appendFatName(destination, &cursor, &name, (attributes & 0x10) != 0)) return null;
            if (cursor >= destination.len) return null;
            destination[cursor] = '\n';
            cursor += 1;
        }
    }
    return cursor;
}

fn resetNamespaceAccounting() void {
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
    vfs_rename_count = 0;
    vfs_unlink_count = 0;
    pipe_objects = @splat(.{});
}

fn verifyNamespaceLifecycle() void {
    namespace_verified = false;
    namespace_reused_cluster = 0;
    namespace_hash = 0;
    vfs_rename_count = 0;
    vfs_unlink_count = 0;
    const temporary = "TEMP    BIN";
    const moved = "MOVED   BIN";
    const reused = "REUSE   BIN";
    if (vfsFindNode(temporary) != null or vfsFindNode(moved) != null or vfsFindNode(reused) != null) {
        vfsFailure("namespace residue");
    }
    if (notes_present_at_boot) {
        namespace_verified = true;
        writeAll("ZigOs i686 FAT12 namespace verified: mode readonly rename 0x00000000 unlink 0x00000000 residue none disk-writes 0x00000000 preserved yes\r\n");
        writeAll("ZigOs i686 Capstone 9 verified: new-goals 0x00000010 VM 0x00000008 threads 0x00000006 IRQ-queues 0x00000001 namespace 0x00000001 mode persistence\r\n");
        return;
    }

    var payload: [600]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @intCast((index * 37 + 11) & 0xFF);
    const expected_hash = fnv1a32(payload[0..]);
    const fd = vfsOpenOwned(temporary, 0, vfs_open_read | vfs_open_write | vfs_open_create) orelse
        vfsFailure("namespace create");
    if (vfsWriteOwned(fd, 0, payload[0..]) != payload.len or !vfsClose(fd)) vfsFailure("namespace write");
    const temporary_index = vfsFindNode(temporary) orelse vfsFailure("namespace temporary node");
    const first_cluster = vfs_nodes[temporary_index].cluster;
    const second_cluster = fatReadEntry(first_cluster) orelse vfsFailure("namespace second cluster");
    const chain_end = fatReadEntry(second_cluster) orelse vfsFailure("namespace chain end");
    if (first_cluster != runtime_first_cluster or second_cluster != runtime_first_cluster + 1 or chain_end < 0x0FF8) vfsFailure("namespace deterministic chain");

    if (!vfsRenameNode(temporary, moved) or vfsFindNode(temporary) != null) vfsFailure("namespace rename");
    const moved_index = vfsFindNode(moved) orelse vfsFailure("namespace moved node");
    if (vfs_nodes[moved_index].cluster != first_cluster or vfs_nodes[moved_index].size != payload.len) {
        vfsFailure("namespace rename metadata");
    }
    const moved_amount = vfsReadWhole(moved, vfs_large_buffer[0..]) orelse vfsFailure("namespace moved read");
    namespace_hash = fnv1a32(vfs_large_buffer[0..moved_amount]);
    if (moved_amount != payload.len or namespace_hash != expected_hash) vfsFailure("namespace content");

    if (!vfsUnlinkNode(moved) or vfsFindNode(moved) != null) vfsFailure("namespace unlink");
    if (fatReadEntry(first_cluster) != 0 or fatReadEntry(second_cluster) != 0) vfsFailure("namespace reclaim");

    const reuse_fd = vfsOpenOwned(reused, 0, vfs_open_read | vfs_open_write | vfs_open_create) orelse
        vfsFailure("namespace reuse create");
    const reuse_byte = [_]u8{0x5A};
    if (vfsWriteOwned(reuse_fd, 0, &reuse_byte) != 1 or !vfsClose(reuse_fd)) vfsFailure("namespace reuse write");
    const reuse_index = vfsFindNode(reused) orelse vfsFailure("namespace reuse node");
    namespace_reused_cluster = vfs_nodes[reuse_index].cluster;
    if (namespace_reused_cluster != first_cluster) vfsFailure("namespace first-fit reuse");
    if (!vfsUnlinkNode(reused) or fatReadEntry(namespace_reused_cluster) != 0) vfsFailure("namespace reuse unlink");
    reloadVfsRoot();
    if (vfs_node_count != 12 or vfsFindNode(temporary) != null or vfsFindNode(moved) != null or vfsFindNode(reused) != null) {
        vfsFailure("namespace root restoration");
    }
    if (vfs_rename_count != 1 or vfs_unlink_count != 2 or fat_allocation_count != 3 or fat_free_count != 3) {
        vfsFailure("namespace accounting");
    }
    namespace_verified = true;
    writeAll("ZigOs i686 FAT12 namespace verified: mode cleanup rename 0x00000001 unlink 0x00000002 bytes 0x00000258 hash 0x");
    writeHex32(namespace_hash);
    writeAll(" chain 0x");
    writeHex32(first_cluster);
    writeAll("->0x");
    writeHex32(second_cluster);
    writeAll(" reclaimed yes reused 0x");
    writeHex32(namespace_reused_cluster);
    writeAll(" residue none root-restored yes\r\n");
    writeAll("ZigOs i686 Capstone 9 verified: new-goals 0x00000010 VM 0x00000008 threads 0x00000006 IRQ-queues 0x00000001 namespace 0x00000001 mode first\r\n");
    resetNamespaceAccounting();
}

fn verifyPersistentHierarchy() void {
    const writes_before = ata_write_count;
    const allocations_before = fat_allocation_count;
    const frees_before = fat_free_count;
    const home = pathFindEntry(0, "HOME       ") orelse vfsFailure("hierarchy HOME");
    const docs = pathFindEntry(home.cluster, "DOCS       ") orelse vfsFailure("hierarchy DOCS");
    const archive = pathFindEntry(home.cluster, "ARCHIVE    ") orelse vfsFailure("hierarchy ARCHIVE");
    const log = pathFindEntry(archive.cluster, "LOG     TXT") orelse vfsFailure("hierarchy LOG");
    const home_dot = pathFindEntry(home.cluster, ".          ") orelse vfsFailure("hierarchy HOME dot");
    const home_parent = pathFindEntry(home.cluster, "..         ") orelse vfsFailure("hierarchy HOME parent");
    const docs_parent = pathFindEntry(docs.cluster, "..         ") orelse vfsFailure("hierarchy DOCS parent");
    const archive_parent = pathFindEntry(archive.cluster, "..         ") orelse vfsFailure("hierarchy ARCHIVE parent");
    const second = fatReadEntry(log.cluster) orelse vfsFailure("hierarchy LOG second");
    const end = fatReadEntry(second) orelse vfsFailure("hierarchy LOG end");
    const amount = pathReadFile(0, "/HOME/ARCHIVE/LOG.TXT", vfs_large_buffer[0..]) orelse
        vfsFailure("hierarchy LOG read");
    var home_list: [128]u8 = @splat(0);
    var archive_list: [128]u8 = @splat(0);
    const home_list_bytes = pathListDirectory(0, "/HOME", home_list[0..]) orelse
        vfsFailure("hierarchy HOME list");
    const archive_list_bytes = pathListDirectory(0, "/HOME/ARCHIVE", archive_list[0..]) orelse
        vfsFailure("hierarchy ARCHIVE list");
    hierarchy_hash = fnv1a32(vfs_large_buffer[0..amount]);
    hierarchy_home_cluster = home.cluster;
    hierarchy_docs_cluster = docs.cluster;
    hierarchy_archive_cluster = archive.cluster;
    hierarchy_log_first_cluster = log.cluster;
    hierarchy_log_second_cluster = second;
    hierarchy_reused_cluster = runtime_first_cluster + 5;
    const reuse_fat = fatReadEntry(hierarchy_reused_cluster) orelse vfsFailure("hierarchy reuse FAT");
    const expected_reuse = if (notes_present_at_boot) runtime_first_cluster + 6 else 0;
    if ((home.attributes & 0x10) == 0 or (docs.attributes & 0x10) == 0 or (archive.attributes & 0x10) == 0 or
        home.cluster != runtime_first_cluster or docs.cluster != runtime_first_cluster + 1 or
        log.cluster != runtime_first_cluster + 2 or second != runtime_first_cluster + 3 or
        archive.cluster != runtime_first_cluster + 4 or end < 0x0FF8 or log.size != expected_path_payload_bytes or
        hierarchy_hash != expected_path_payload_hash or home_dot.cluster != home.cluster or home_parent.cluster != 0 or
        docs_parent.cluster != home.cluster or archive_parent.cluster != home.cluster or !pathDirectoryEmpty(docs.cluster) or
        pathFindEntry(docs.cluster, "SCRATCH BIN") != null or pathFindEntry(docs.cluster, "REUSE   BIN") != null or
        !equalBytes(home_list[0..home_list_bytes], "DOCS/\nARCHIVE/\n") or
        !equalBytes(archive_list[0..archive_list_bytes], "LOG.TXT\n") or reuse_fat != expected_reuse or
        ata_write_count != writes_before or fat_allocation_count != allocations_before or fat_free_count != frees_before)
    {
        vfsFailure("hierarchy persistent contract");
    }
    hierarchy_present_at_boot = true;
    hierarchy_verified = true;
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
    if (notes_hash != expected_notes_hash or notes_cluster != runtime_first_cluster + 5 or second != runtime_first_cluster + 6 or end < 0x0FF8) {
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

fn initializeProcessServices() void {
    for (&user_service_frames) |*frame| {
        if (frame.* == 0) frame.* = allocateFrame() orelse processFailure("service frame allocation");
        zeroPhysicalFrame(frame.*);
    }
    resetUserServiceMappings();
    pipe_objects = @splat(.{});
    service_verified = false;
    service_syscalls = 0;
    service_pipe_bytes = 0;
    service_sleep_ticks = 0;
    service_signal = 0;
    fork_child = .{};
    fork_child_kernel_stack = @splat(0);
    fork_tree_verified = false;
    fork_tree_child_pid = 0;
    fork_tree_child_syscalls = 0;
    fork_tree_inherited = 0;
    fork_tree_cloexec = 0;
    fork_tree_signal = 0;
    fork_tree_pipe_bytes = 0;
    writeAll("ZigOs i686 process services ready: brk 0x00403000-0x00405000 mmap 0x00405000 pipes 0x00000004 fork-frames 0x00000007 signals pending PCI-devices 0x");
    writeHex32(pci_device_count);
    writeAll("\r\n");
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
    syscall_brk_count = 0;
    syscall_mmap_count = 0;
    syscall_munmap_count = 0;
    syscall_getppid_count = 0;
    syscall_uptime_count = 0;
    syscall_sleep_count = 0;
    syscall_stat_count = 0;
    syscall_rename_count = 0;
    syscall_unlink_count = 0;
    syscall_pipe_count = 0;
    syscall_pipe_read_count = 0;
    syscall_pipe_write_count = 0;
    syscall_dup_count = 0;
    syscall_dup2_count = 0;
    syscall_signal_send_count = 0;
    syscall_signal_pending_count = 0;
    syscall_clone_count = 0;
    syscall_child_peek_count = 0;
    syscall_child_poke_count = 0;
    syscall_child_exec_count = 0;
    syscall_waitpid_count = 0;
    syscall_setpgid_count = 0;
    syscall_getpgid_count = 0;
    syscall_killpg_count = 0;
    syscall_procinfo_count = 0;
    syscall_getcwd_count = 0;
    syscall_chdir_count = 0;
    syscall_mkdir_count = 0;
    syscall_rmdir_count = 0;
    syscall_path_stat_count = 0;
    syscall_path_write_count = 0;
    syscall_path_read_count = 0;
    syscall_path_rename_count = 0;
    syscall_path_unlink_count = 0;
    syscall_listdir_count = 0;
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
    const inherited_cwd = if (parent_pid == 0) @as(u16, 0) else processCwdCluster(parent_pid) orelse 0;
    process_table[process_index] = .{
        .pid = pid,
        .parent_pid = parent_pid,
        .process_group = pid,
        .cwd_cluster = inherited_cwd,
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
    resetUserServiceMappings();
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
    } else if (equalBytes(name[0..], "SERVICE ELF")) {
        const results: [*]const volatile u32 = @ptrFromInt(user_code_frame + 0x3D0);
        const stat: [*]const volatile u8 = @ptrFromInt(user_code_frame + 0x3B0);
        const readback: [*]const volatile u8 = @ptrFromInt(user_code_frame + 0x440);
        const heap_sentinel: *const volatile u32 = @ptrFromInt(user_service_frames[0]);
        const mmap_sentinel: *const volatile u32 = @ptrFromInt(user_service_frames[2]);
        var payload_match = true;
        for (service_payload, 0..) |byte, index| {
            if (readback[index] != byte) payload_match = false;
        }
        var pipes_closed = true;
        for (pipe_objects) |pipe| {
            if (pipe.active) pipes_closed = false;
        }
        if (syscall_exit_code != 0x66 or syscall_count != 30 or syscall_rejected != 0 or
            syscall_brk_count != 3 or syscall_mmap_count != 1 or syscall_munmap_count != 1 or
            syscall_getppid_count != 1 or syscall_uptime_count != 2 or syscall_sleep_count != 1 or
            syscall_stat_count != 2 or syscall_rename_count != 1 or syscall_unlink_count != 1 or
            syscall_pipe_count != 1 or syscall_pipe_write_count != 1 or syscall_pipe_read_count != 2 or
            syscall_dup_count != 1 or syscall_dup2_count != 1 or syscall_signal_send_count != 1 or
            syscall_signal_pending_count != 1 or syscall_file_opens != 1 or syscall_file_writes != 2 or
            syscall_file_write_bytes != service_payload.len * 2 or syscall_file_reads != 2 or
            syscall_file_read_bytes != service_payload.len or syscall_file_closes != 5 or
            syscall_exit_cleanup_closes != 0 or results[0] != user_heap_base or results[1] != user_heap_limit or
            results[2] != user_mmap_address or results[3] != 0 or results[4] != parent_pid or
            results[6] < 2 or results[7] -% results[5] < 2 or results[8] != service_payload.len or
            results[9] != 0 or results[10] != 0 or results[11] != 0 or results[12] != 0 or results[13] != 0 or
            results[14] != service_payload.len or results[15] >= vfs_descriptors.len or results[16] != 7 or
            results[17] != service_payload.len or results[18] != 0 or results[19] != pid or results[20] != 0 or
            results[21] != 9 or results[22] != user_heap_base or readLe32(stat, 0) != service_payload.len or
            readLe32(stat, 4) != runtime_first_cluster or readLe32(stat, 8) != 0x20 or readLe32(stat, 12) != 1 or
            heap_sentinel.* != 0xDEAD_BEEF or mmap_sentinel.* != 0xCAFE_BABE or !payload_match or !pipes_closed or
            queryPageEntry(kernel_page_directory, user_heap_base) != null or
            queryPageEntry(kernel_page_directory, user_heap_base + frame_size) != null or
            queryPageEntry(kernel_page_directory, user_mmap_address) != null or vfsOpenCountOwned(pid) != 0 or
            vfsFindNode("TEMP2   BIN") != null or vfsFindNode("RENAMED BIN") != null or
            fatReadEntry(runtime_first_cluster) != 0 or vfs_create_count != 1 or vfs_rename_count != 1 or vfs_unlink_count != 1 or
            fat_allocation_count != 1 or fat_free_count != 1 or process_table[process_index].pending_signal != 0)
        {
            processFailure("SERVICE contract");
        }
        service_verified = true;
        service_syscalls = syscall_count;
        service_pipe_bytes = syscall_file_read_bytes;
        service_sleep_ticks = results[6];
        service_signal = results[21];
        resetNamespaceAccounting();
    } else if (equalBytes(name[0..], "ORCH    ELF")) {
        const results: [*]const volatile u32 = @ptrFromInt(user_code_frame + 0x580);
        const status: [*]const volatile u8 = @ptrFromInt(user_code_frame + 0x620);
        const info: [*]const volatile u8 = @ptrFromInt(user_code_frame + 0x640);
        const reply: [*]const volatile u8 = @ptrFromInt(user_code_frame + 0x680);
        const child_pid = results[6];
        const child_index = processRecordIndex(child_pid) orelse processFailure("ORCH child record");
        var reply_match = true;
        for (child_reply, 0..) |byte, index| {
            if (reply[index] != byte) reply_match = false;
        }
        var pipes_closed = true;
        for (pipe_objects) |pipe| {
            if (pipe.active) pipes_closed = false;
        }
        if (syscall_exit_code != 0x70 or syscall_count != 30 or syscall_rejected != 0 or
            syscall_brk_count != 3 or syscall_mmap_count != 1 or syscall_munmap_count != 1 or
            syscall_file_opens != 1 or syscall_pipe_count != 1 or syscall_file_writes != 2 or
            syscall_file_write_bytes != orch_request.len + child_reply.len or syscall_file_reads != 2 or
            syscall_file_read_bytes != orch_request.len + child_reply.len or syscall_file_closes != 3 or
            syscall_clone_count != 1 or syscall_child_peek_count != 2 or syscall_child_poke_count != 1 or
            syscall_child_exec_count != 1 or syscall_waitpid_count != 1 or syscall_setpgid_count != 1 or
            syscall_getpgid_count != 2 or syscall_killpg_count != 1 or syscall_procinfo_count != 1 or
            syscall_signal_pending_count != 1 or results[0] != user_heap_base or results[1] != user_heap_limit or
            results[2] != user_mmap_address or results[4] != 0 or results[5] != orch_request.len or
            results[7] != 0xDEAD_BEEF or results[8] != 0 or results[9] != 0xAABB_CCDD or
            results[10] != 0xDEAD_BEEF or results[11] != 0 or results[12] != child_pid or results[13] != 1 or
            results[14] != 0 or results[15] != 0 or results[16] != child_pid or results[17] != child_reply.len or
            results[18] != 0 or results[19] != 0 or results[20] != 0 or results[21] != 0 or
            results[22] != user_heap_base or readLe32(status, 0) != child_pid or readLe32(status, 4) != 0x77 or
            readLe32(status, 8) != @intFromEnum(ProcessState.exited) or readLe32(status, 12) != 7 or
            readLe32(info, 0) != child_pid or readLe32(info, 4) != pid or readLe32(info, 8) != child_pid or
            readLe32(info, 12) != @intFromEnum(ProcessState.running) or readLe32(info, 16) != 3 or
            readLe32(info, 20) != 1 or readLe32(info, 24) == 0 or readLe32(info, 24) == kernel_page_directory or
            readLe32(info, 28) != 7 or !reply_match or !fork_child.request_match or
            fork_child.child_results[0] != child_pid or fork_child.child_results[1] != pid or
            fork_child.child_results[2] != child_pid or fork_child.child_results[3] != 12 or
            fork_child.child_results[4] != orch_request.len or fork_child.child_results[5] != child_reply.len or
            fork_child.child_exit_code != 0x77 or fork_child.child_syscalls != 7 or fork_child.child_exit_cleanup != 2 or
            fork_child.inherited_count != 3 or fork_child.cloexec_closed != 1 or !fork_child.resources_released or
            !fork_child.parent_cr3_restored or !fork_child.parent_tss_restored or !fork_child.parent_pid_restored or
            fork_child.frames_after != fork_child.frames_before or vfsOpenCountOwned(pid) != 0 or
            process_table[child_index].state != .exited or !process_table[child_index].waited or
            process_table[child_index].parent_pid != pid or process_table[child_index].process_group != child_pid or
            process_table[child_index].pending_signal != 0 or waitProcess(pid, child_pid) != null or !pipes_closed or
            queryPageEntry(kernel_page_directory, user_heap_base) != null or
            queryPageEntry(kernel_page_directory, user_heap_base + frame_size) != null or
            queryPageEntry(kernel_page_directory, user_mmap_address) != null)
        {
            processFailure("ORCH process-tree contract");
        }
        fork_tree_verified = true;
        fork_tree_child_pid = child_pid;
        fork_tree_child_syscalls = fork_child.child_syscalls;
        fork_tree_inherited = fork_child.inherited_count;
        fork_tree_cloexec = fork_child.cloexec_closed;
        fork_tree_signal = fork_child.child_results[3];
        fork_tree_pipe_bytes = results[17];
    } else if (equalBytes(name[0..], "PATHS   ELF")) {
        const results: [*]const volatile u32 = @ptrFromInt(user_code_frame + 0x740);
        const cwd_root: [*]const volatile u8 = @ptrFromInt(user_code_frame + 0x7C0);
        const cwd_home: [*]const volatile u8 = @ptrFromInt(user_code_frame + 0x7F0);
        const cwd_docs: [*]const volatile u8 = @ptrFromInt(user_code_frame + 0x820);
        const stat: [*]const volatile u8 = @ptrFromInt(user_code_frame + 0x850);
        const home_list: [*]const volatile u8 = @ptrFromInt(user_code_frame + 0x880);
        const archive_list: [*]const volatile u8 = @ptrFromInt(user_code_frame + 0x900);
        const readback: [*]const volatile u8 = @ptrFromInt(user_code_frame + 0xC60);
        const expected_results = [_]u32{
            1,
            runtime_first_cluster,
            0,
            5,
            runtime_first_cluster + 1,
            0,
            10,
            runtime_first_cluster + 2,
            0,
            expected_path_payload_bytes,
            0,
            expected_path_payload_bytes,
            0,
            0,
            0xFFFF_FFFE,
            0,
            0,
            runtime_first_cluster + 4,
            0,
            0xFFFF_FFD9,
            15,
            8,
            0,
            expected_path_payload_bytes,
            1,
            0,
            1,
            0,
            0,
            1,
        };
        var results_match = true;
        for (expected_results, 0..) |expected, index| {
            if (results[index] != expected) results_match = false;
        }
        var payload_match = true;
        for (0..expected_path_payload_bytes) |index| {
            const expected: u8 = @intCast((index * 29 + 7) & 0xFF);
            if (readback[index] != expected) payload_match = false;
        }
        var cwd_match = cwd_root[0] == '/';
        for ("/HOME", 0..) |byte, index| {
            if (cwd_home[index] != byte) cwd_match = false;
        }
        for ("/HOME/DOCS", 0..) |byte, index| {
            if (cwd_docs[index] != byte) cwd_match = false;
        }
        var home_list_match = true;
        for ("DOCS/\nARCHIVE/\n", 0..) |byte, index| {
            if (home_list[index] != byte) home_list_match = false;
        }
        var archive_list_match = true;
        for ("LOG.TXT\n", 0..) |byte, index| {
            if (archive_list[index] != byte) archive_list_match = false;
        }
        if (syscall_exit_code != 0x72 or syscall_count != 31 or syscall_rejected != 2 or
            syscall_getcwd_count != 4 or syscall_chdir_count != 5 or syscall_mkdir_count != 4 or
            syscall_rmdir_count != 1 or syscall_path_stat_count != 2 or syscall_path_write_count != 3 or
            syscall_path_read_count != 2 or syscall_path_rename_count != 3 or syscall_path_unlink_count != 2 or
            syscall_listdir_count != 2 or syscall_exit_cleanup_closes != 0 or !results_match or !payload_match or
            !cwd_match or !home_list_match or !archive_list_match or readLe32(stat, 0) != expected_path_payload_bytes or
            readLe32(stat, 4) != runtime_first_cluster + 2 or readLe32(stat, 8) != 0x20 or readLe32(stat, 12) != 2 or
            process_table[process_index].cwd_cluster != 0 or vfsOpenCountOwned(pid) != 0 or
            hierarchy_mkdir_count != 4 or hierarchy_rmdir_count != 1 or hierarchy_rename_count != 3 or
            hierarchy_unlink_count != 2 or fat_allocation_count != 8 or fat_free_count != 3 or
            fatReadEntry(runtime_first_cluster + 5) != 0)
        {
            processFailure("PATHS hierarchy contract");
        }
        hierarchy_syscalls = syscall_count;
        hierarchy_rejections = syscall_rejected;
        hierarchy_reused_cluster = runtime_first_cluster + 5;
        verifyPersistentHierarchy();
        resetNamespaceAccounting();
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
    const expected_nodes: u32 = if (notes_present_at_boot) 13 else 12;
    if (!ata_ready or !fat_ready or !heap_ready or !frame_allocator_ready or vfs_node_count != expected_nodes) {
        shellFailure("subsystems unavailable");
    }
    writeAll("ZigOs i686 Capstone 12 shell ready: commands help ls mem ticks disk hash FILE stat FILE run FILE wait PID ps exit mode ");
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
            writeAll(" SERVICE.ELF-bytes 0x");
            writeHex32(service_elf_size);
            writeAll(" ORCH.ELF-bytes 0x");
            writeHex32(orch_elf_size);
            writeAll(" CHILD.ELF-bytes 0x");
            writeHex32(child_elf_size);
            writeAll(" PATHS.ELF-bytes 0x");
            writeHex32(paths_elf_size);
            writeAll(" WRITER.ELF-bytes 0x");
            writeHex32(writer_elf_size);
            writeAll(" persistent-notes ");
            writeAll(if (vfsFindNode("NOTES   TXT") != null) "yes" else "no");
            writeAll(" persistent-hierarchy ");
            writeAll(if (hierarchy_present_at_boot) "yes" else "no");
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
            if (equalBytes(name[0..], "SERVICE ELF")) {
                writeAll(" services 0x00000012 pipe-bytes 0x");
                writeHex32(service_pipe_bytes);
                writeAll(" sleep-ticks 0x");
                writeHex32(service_sleep_ticks);
                writeAll(" signal 0x");
                writeHex32(service_signal);
                writeAll(" cleanup yes");
            }
            if (equalBytes(name[0..], "ORCH    ELF")) {
                writeAll(" child 0x");
                writeHex32(fork_tree_child_pid);
                writeAll(" child-syscalls 0x");
                writeHex32(fork_tree_child_syscalls);
                writeAll(" inherited 0x");
                writeHex32(fork_tree_inherited);
                writeAll(" cloexec 0x");
                writeHex32(fork_tree_cloexec);
                writeAll(" signal 0x");
                writeHex32(fork_tree_signal);
                writeAll(" pipe-bytes 0x");
                writeHex32(fork_tree_pipe_bytes);
                writeAll(" cleanup yes");
            }
            if (equalBytes(name[0..], "PATHS   ELF")) {
                writeAll(" hierarchy-goals 0x00000017 home 0x");
                writeHex32(hierarchy_home_cluster);
                writeAll(" docs 0x");
                writeHex32(hierarchy_docs_cluster);
                writeAll(" log 0x");
                writeHex32(hierarchy_log_first_cluster);
                writeAll("->0x");
                writeHex32(hierarchy_log_second_cluster);
                writeAll(" archive 0x");
                writeHex32(hierarchy_archive_cluster);
                writeAll(" reuse 0x");
                writeHex32(hierarchy_reused_cluster);
                writeAll(" hash 0x");
                writeHex32(hierarchy_hash);
                writeAll(" cleanup yes");
            }
            if (equalBytes(name[0..], "WRITER  ELF")) {
                writeAll(" wrote 0x");
                writeHex32(syscall_file_write_bytes);
                writeAll(" readback 0x");
                writeHex32(syscall_file_read_bytes);
                writeAll(" notes-hash 0x");
                writeHex32(notes_hash);
                writeAll(" chain 0x");
                writeHex32(notes_cluster);
                writeAll("->0x");
                writeHex32(runtime_first_cluster + 6);
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
                    if (record.pid == 11 and record.state == .faulted and record.fault_vector == 14 and
                        record.fault_address == 0x0080_0000) fault_ok = true;
                }
                if (vfs_node_count != 13 or process_count != 11 or last_spawned_pid != 11 or
                    process_wait_count != 2 or last_waited_pid != 10 or !fault_ok or shell_command_count != 16 or
                    vfs_create_count != 1 or vfs_truncate_count != 1 or vfs_write_count != 2 or
                    vfs_seek_count != 1 or fat_allocation_count != 2 or notes_hash != expected_notes_hash or
                    !namespace_verified or !service_verified or !fork_tree_verified or !hierarchy_verified or
                    hierarchy_syscalls != 31 or hierarchy_rejections != 2 or hierarchy_home_cluster != runtime_first_cluster or
                    hierarchy_docs_cluster != runtime_first_cluster + 1 or hierarchy_log_first_cluster != runtime_first_cluster + 2 or
                    hierarchy_log_second_cluster != runtime_first_cluster + 3 or hierarchy_archive_cluster != runtime_first_cluster + 4 or
                    hierarchy_reused_cluster != runtime_first_cluster + 5 or hierarchy_hash != expected_path_payload_hash or
                    service_syscalls != 30 or service_pipe_bytes != service_payload.len or
                    vm_fault_recovery_count != 1 or vm_fault_containment_count != 4 or
                    advanced_scheduler_exit_count != 4 or keyboard_ring_dropped != 0 or !fat_cache_loaded)
                {
                    shellFailure("first-session accounting");
                }
                writeAll("ZigOs i686 Capstone 12 first session verified: goals 0x00000056 new-goals 0x00000017 root-files 0x");
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
                writeAll(" chain 0x");
                writeHex32(notes_cluster);
                writeAll("->0x");
                writeHex32(runtime_first_cluster + 6);
                writeAll(" hierarchy 0x");
                writeHex32(hierarchy_log_first_cluster);
                writeAll("->0x");
                writeHex32(hierarchy_log_second_cluster);
                writeAll(" hierarchy-hash 0x");
                writeHex32(hierarchy_hash);
                writeAll(" fault-contained yes descriptors-closed yes commands 0x");
                writeHex32(shell_command_count);
                writeAll("\r\n");
            } else {
                verifyNotesFile();
                if (vfs_node_count != 13 or process_count != 3 or shell_command_count != 3 or
                    vfs_create_count != 0 or vfs_truncate_count != 0 or vfs_write_count != 0 or
                    fat_allocation_count != 0 or notes_hash != expected_notes_hash or
                    !namespace_verified or !hierarchy_verified or hierarchy_hash != expected_path_payload_hash or
                    hierarchy_home_cluster != runtime_first_cluster or hierarchy_docs_cluster != runtime_first_cluster + 1 or
                    hierarchy_log_first_cluster != runtime_first_cluster + 2 or hierarchy_log_second_cluster != runtime_first_cluster + 3 or
                    hierarchy_archive_cluster != runtime_first_cluster + 4 or vm_fault_recovery_count != 1 or vm_fault_containment_count != 3 or
                    advanced_scheduler_exit_count != 4 or keyboard_ring_dropped != 0 or !fat_cache_loaded)
                {
                    shellFailure("persistence-session accounting");
                }
                writeAll("ZigOs i686 Capstone 12 persistence session verified: goals 0x00000056 inherited-goals 0x00000043 root-files 0x0000000D notes 0x000002D0 hash 0x");
                writeHex32(notes_hash);
                writeAll(" chain 0x");
                writeHex32(notes_cluster);
                writeAll("->0x");
                writeHex32(runtime_first_cluster + 6);
                writeAll(" hierarchy 0x");
                writeHex32(hierarchy_log_first_cluster);
                writeAll("->0x");
                writeHex32(hierarchy_log_second_cluster);
                writeAll(" hierarchy-hash 0x");
                writeHex32(hierarchy_hash);
                writeAll(" writes 0x00000000 allocations 0x00000000 descriptors-closed yes commands 0x");
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

fn pciConfigRead32(bus: u8, device: u8, function: u8, offset: u8) u32 {
    const address = 0x8000_0000 | (@as(u32, bus) << 16) | (@as(u32, device) << 11) |
        (@as(u32, function) << 8) | (@as(u32, offset) & 0xFC);
    zigos_i686_out32(0x0CF8, address);
    return zigos_i686_in32(0x0CFC);
}

fn verifyPci() void {
    pci_host_id = pciConfigRead32(0, 0, 0, 0);
    if ((pci_host_id & 0xFFFF) != 0x8086 or (pci_host_id >> 16) != 0x1237) {
        writeAll("ZigOs i686 PCI failed: host-id 0x");
        writeHex32(pci_host_id);
        writeAll("\r\n");
        haltForever();
    }
    pci_device_count = 0;
    for (0..32) |device| {
        const identity = pciConfigRead32(0, @intCast(device), 0, 0);
        if ((identity & 0xFFFF) != 0xFFFF) pci_device_count +|= 1;
    }
    const class_register = pciConfigRead32(0, 0, 0, 8);
    pci_class_code = @truncate(class_register >> 24);
    if (pci_device_count < 3 or pci_class_code != 0x06) {
        writeAll("ZigOs i686 PCI failed: devices 0x");
        writeHex32(pci_device_count);
        writeAll(" class 0x");
        writeHex8(pci_class_code);
        writeAll("\r\n");
        haltForever();
    }
    writeAll("ZigOs i686 PCI verified: mechanism-1 yes bus 0x00000000 devices 0x");
    writeHex32(pci_device_count);
    writeAll(" host 8086:1237 class 0x");
    writeHex8(pci_class_code);
    writeAll(" config-ports 0x0CF8/0x0CFC\r\n");
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
    writeAll(" heap-restored yes retries 0x");
    writeHex32(ata_retry_count);
    writeAll(" resets 0x");
    writeHex32(ata_reset_count);
    writeAll("\r\n");
    verifyFat12();
}

fn ataIdentify(destination: *[256]u16) bool {
    if (!ataWaitIdle()) return false;
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
    var attempt: u32 = 0;
    while (attempt < 2) : (attempt += 1) {
        if (ataTryReadSector(lba, destination_address)) return true;
        if (attempt != 0 or !ataRecover()) return false;
        ata_retry_count +|= 1;
    }
    return false;
}

fn ataTryReadSector(lba: u32, destination_address: u32) bool {
    if (!ataWaitIdle()) return false;
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
    // A following command serializes completion. If that boundary does not
    // settle within the bounded poll, ataRecover resets and retries it.
    return true;
}

fn ataWriteSector(lba: u32, source_address: u32) bool {
    if (ata_sector_count != 0 and lba >= ata_sector_count) return false;
    if (lba >= 0x1000_0000) return false;
    var attempt: u32 = 0;
    while (attempt < 2) : (attempt += 1) {
        if (ataTryWriteSector(lba, source_address)) {
            ata_write_count +|= 1;
            return true;
        }
        if (attempt != 0 or !ataRecover()) return false;
        ata_retry_count +|= 1;
    }
    return false;
}

fn ataTryWriteSector(lba: u32, source_address: u32) bool {
    if (!ataWaitIdle()) return false;
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
    if (!ataWaitIdle()) return false;
    zigos_i686_out8(ata_status_command_port, 0xE7);
    if (!ataWaitIdle()) return false;
    if (!ataTryReadSector(lba, @intCast(@intFromPtr(&ata_verify_buffer)))) return false;
    for (0..512) |index| {
        if (ata_verify_buffer[index] != source[index]) return false;
    }
    return true;
}

const ata_poll_limit: u32 = 1024;

fn ataRecover() bool {
    // SRST aborts any incomplete PIO phase and returns the selected device to
    // a command boundary. IRQ14 remains masked, so nIEN is not required here.
    zigos_i686_out8(ata_alternate_status_port, 0x04);
    for (0..32) |_| _ = zigos_i686_in8(ata_alternate_status_port);
    zigos_i686_out8(ata_alternate_status_port, 0x00);
    ataDelay();
    if (!ataWaitReady()) return false;
    zigos_i686_out8(ata_drive_port, 0xE0);
    ataDelay();
    if (!ataWaitIdle()) return false;
    ata_reset_count +|= 1;
    return true;
}

fn ataWaitReady() bool {
    var remaining: u32 = ata_poll_limit;
    while (remaining != 0) : (remaining -= 1) {
        const status = zigos_i686_in8(ata_alternate_status_port);
        ata_last_status = status;
        if ((status & 0x21) != 0) return false;
        if ((status & 0x80) == 0) return true;
    }
    return false;
}

fn ataWaitIdle() bool {
    var remaining: u32 = ata_poll_limit;
    while (remaining != 0) : (remaining -= 1) {
        const status = zigos_i686_in8(ata_alternate_status_port);
        ata_last_status = status;
        if ((status & 0x21) != 0) return false;
        if ((status & 0x88) == 0) return true;
    }
    return false;
}

fn ataWaitData() bool {
    var remaining: u32 = ata_poll_limit;
    while (remaining != 0) : (remaining -= 1) {
        const status = zigos_i686_in8(ata_alternate_status_port);
        ata_last_status = status;
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
