const std = @import("std");
const apic = @import("apic.zig");
const descriptor_tables = @import("descriptor_tables.zig");
const elf64 = @import("elf64.zig");
const interrupt_context = @import("interrupt_context.zig");
const memory = @import("memory.zig");
const paging = @import("paging.zig");

const cc = std.os.uefi.cc;
const main_elf = @embedFile("generated/process_user.elf");
const exec_elf = @embedFile("generated/process_exec.elf");

pub const code_base: usize = 0x0000_0080_0000_0000;
pub const data_base: usize = code_base + 0x2000;
pub const bss_base: usize = code_base + 0x3000;
pub const stack_base: usize = code_base + 0x4000;
pub const heap_base: usize = code_base + 0x5000;
pub const demand_base: usize = code_base + 0x6000;
pub const anon_base: usize = code_base + 0x7000;
pub const guard_base: usize = code_base + 0x8000;
const page_bytes: usize = @intCast(memory.page_size);
const maximum_processes: usize = 4;
const maximum_descriptors: usize = 8;
const maximum_open_files: usize = 8;
const maximum_pipes: usize = 2;
const maximum_spaces: usize = 8;
const maximum_tombstones: usize = 8;
const invalid_index: u8 = 0xFF;
const stack_canary: u64 = 0x5052_4F43_3634_5354;
const initial_pid: u64 = 80;
const expected_main_hash: u64 = 0xF4E0_D9F2_5BF7_4D76;
const expected_exec_hash: u64 = 0x13F8_A5B0_90C2_F18A;

const errno_no_process: i64 = -3;
const errno_no_exec: i64 = -8;
const errno_bad_fd: i64 = -9;
const errno_child: i64 = -10;
const errno_would_block: i64 = -11;
const errno_fault: i64 = -14;
const errno_busy: i64 = -16;
const errno_invalid: i64 = -22;
const errno_no_syscall: i64 = -38;

const getpid_syscall: u64 = 32;
const getppid_syscall: u64 = 33;
const getrole_syscall: u64 = 34;
const getticks_syscall: u64 = 35;
const spawn_syscall: u64 = 36;
const fork_syscall: u64 = 37;
const exec_syscall: u64 = 38;
const exit_syscall: u64 = 39;
const yield_syscall: u64 = 40;
const sleep_syscall: u64 = 41;
const wait_syscall: u64 = 42;
const pipe_syscall: u64 = 43;
const read_syscall: u64 = 44;
const write_syscall: u64 = 45;
const close_syscall: u64 = 46;
const dup_syscall: u64 = 47;
const signal_syscall: u64 = 48;
const take_signal_syscall: u64 = 49;
const process_info_syscall: u64 = 50;
const vm_info_syscall: u64 = 51;
const mmap_syscall: u64 = 52;
const munmap_syscall: u64 = 53;
const brk_syscall: u64 = 54;
const gethandle_syscall: u64 = 55;

const Role = enum(u64) {
    initial = 1,
    worker_one = 2,
    worker_two = 3,
    fault_worker = 4,
    reuse_worker = 5,
    exec_image = 6,
};

const ProcessState = enum(u64) {
    free = 0,
    runnable = 1,
    running = 2,
    sleeping = 3,
    waiting = 4,
    zombie = 5,
    faulted = 6,
};

const PageSlot = enum(usize) {
    code = 0,
    data = 1,
    bss = 2,
    stack = 3,
    heap = 4,
    demand = 5,
    anonymous = 6,
};

const OpenKind = enum(u8) {
    free = 0,
    pipe_read = 1,
    pipe_write = 2,
};

const OpenFile = struct {
    active: bool = false,
    kind: OpenKind = .free,
    pipe_index: u8 = invalid_index,
    references: u16 = 0,
};

const Pipe = struct {
    active: bool = false,
    bytes: [128]u8 = @splat(0),
    read_offset: u16 = 0,
    write_offset: u16 = 0,
    readers: u8 = 0,
    writers: u8 = 0,
};

const Tombstone = struct {
    valid: bool = false,
    handle: u64 = 0,
    status: u64 = 0,
    faulted: bool = false,
};

const Process = struct {
    generation: u32 = 0,
    handle: u64 = 0,
    pid: u64 = 0,
    ppid: u64 = 0,
    parent_slot: u8 = invalid_index,
    role: Role = .initial,
    state: ProcessState = .free,
    context: interrupt_context.Frame = std.mem.zeroes(interrupt_context.Frame),
    fx_state: interrupt_context.FxState align(16) = undefined,
    space: paging.UserAddressSpace = .{
        .pml4_address = 0,
        .pdpt_address = 0,
        .directory_address = 0,
        .table_address = 0,
        .table_pages = 0,
    },
    space_valid: bool = false,
    pages: [7]usize = @splat(0),
    mapped: [7]bool = @splat(false),
    cow_data: bool = false,
    cow_bss: bool = false,
    descriptors: [maximum_descriptors]u8 = @splat(invalid_index),
    wake_tick: u64 = 0,
    wait_handle: u64 = 0,
    wait_status_address: u64 = 0,
    exit_status: u64 = 0,
    pending_signals: u64 = 0,
    syscalls: u64 = 0,
    preemptions: u64 = 0,
    yields: u64 = 0,
    sleeps: u64 = 0,
    cow_faults: u64 = 0,
    demand_faults: u64 = 0,
    execs: u64 = 0,
    stack_canary_value: u64 = 0,
};

pub const Report = struct {
    main_elf_bytes: usize,
    exec_elf_bytes: usize,
    main_hash: u64,
    exec_hash: u64,
    process_creations: u64,
    syscall_count: u64,
    spawns: u64,
    forks: u64,
    execs: u64,
    failed_execs: u64,
    waits: u64,
    slot_reuses: u64,
    stale_rejections: u64,
    timer_ticks: u64,
    timer_preemptions: u64,
    context_switches: u64,
    yields: u64,
    sleeps: u64,
    wakeups: u64,
    idle_ticks: u64,
    cow_faults: u64,
    demand_faults: u64,
    terminal_faults: u64,
    signals_sent: u64,
    signals_taken: u64,
    pipe_bytes: u64,
    descriptor_peak: u64,
    descriptor_closes: u64,
    open_file_peak: u64,
    allocated_frames: u64,
    page_table_frames: u64,
    spaces_created: u64,
    tombstones: u64,
    main_exit: u64,
    worker_one_exit: u64,
    worker_two_exit: u64,
    exec_exit: u64,
    fault_exit: u64,
    reuse_exit: u64,
    shared_text_verified: bool,
    cow_isolation_verified: bool,
    exec_replacement_verified: bool,
    pipe_records_verified: bool,
    generations_verified: bool,
    all_descriptors_closed: bool,
    all_pipes_released: bool,
    all_spaces_empty: bool,
    allocator_restored: bool,
    cr3_restored: bool,
    returned_to_kernel: bool,
};

extern fn zigos_enter_user(user_rip: usize, user_rsp: usize, user_cs: u16, user_ss: u16) callconv(cc) void;
extern fn zigos_fxsave(state: *align(16) interrupt_context.FxState) callconv(cc) void;

var active = false;
var running = false;
var fatal_failure = false;
var fatal_reason: u64 = 0;
var allocator_pointer: ?*memory.FrameAllocator = null;
var allocator_checkpoint: memory.FrameAllocator.Checkpoint = undefined;
var original_cr3: u64 = 0;
var processes: [maximum_processes]Process = undefined;
var open_files: [maximum_open_files]OpenFile = undefined;
var pipes: [maximum_pipes]Pipe = undefined;
var tombstones: [maximum_tombstones]Tombstone = undefined;
var spaces: [maximum_spaces]paging.UserAddressSpace = undefined;
var space_count: usize = 0;
var current_slot: usize = 0;
var baseline_fx: interrupt_context.FxState align(16) = undefined;
var parsed_main: elf64.Image = undefined;
var parsed_exec: elf64.Image = undefined;
var main_text_frame: usize = 0;
var process_creations: u64 = 0;
var spawns: u64 = 0;
var forks: u64 = 0;
var execs: u64 = 0;
var failed_execs: u64 = 0;
var waits: u64 = 0;
var slot_reuses: u64 = 0;
var stale_rejections: u64 = 0;
var timer_ticks: u64 = 0;
var timer_preemptions: u64 = 0;
var context_switches: u64 = 0;
var total_yields: u64 = 0;
var total_sleeps: u64 = 0;
var wakeups: u64 = 0;
var idle_ticks: u64 = 0;
var cow_faults: u64 = 0;
var demand_faults: u64 = 0;
var terminal_faults: u64 = 0;
var signals_sent: u64 = 0;
var signals_taken: u64 = 0;
var pipe_bytes_written: u64 = 0;
var descriptor_peak: u64 = 0;
var descriptor_closes: u64 = 0;
var open_file_peak: u64 = 0;
var tombstone_count: u64 = 0;
var shared_text_proof = true;
var child_cow_proof = false;
var parent_cow_proof = false;
var exec_mapping_proof = false;
var pte_permission_proof = true;
var stack_canary_proof = true;
var final_pipe_records: [32]u8 = @splat(0);
var pipe_records_captured = false;
var final_verify_reason: u64 = 0;
var failure_stage: u64 = 0;
var failure_syscalls: u64 = 0;
var failure_ticks: u64 = 0;

pub fn isActive() bool {
    return active;
}

pub fn lastFailureStage() u64 {
    return failure_stage;
}

pub fn lastFailureSyscalls() u64 {
    return failure_syscalls;
}

pub fn lastFailureTicks() u64 {
    return failure_ticks;
}

pub fn lastFailureReason() u64 {
    return fatal_reason;
}

pub fn lastFailureSlot() u64 {
    return current_slot;
}

pub fn lastFailureStates() u64 {
    var state_bits: u64 = 0;
    for (processes, 0..) |process, index| state_bits |= @as(u64, @intFromEnum(process.state)) << @intCast(index * 8);
    return state_bits;
}

pub fn lastFinalVerifyReason() u64 {
    return final_verify_reason;
}

pub fn lastFailureAccounting() u64 {
    return descriptor_peak | (descriptor_closes << 8) | (open_file_peak << 16) |
        (total_yields << 24) | (total_sleeps << 32) | (idle_ticks << 40) | (tombstone_count << 48);
}

pub fn lastFailureProofs() u64 {
    return @as(u64, @intFromBool(shared_text_proof)) |
        (@as(u64, @intFromBool(child_cow_proof)) << 1) |
        (@as(u64, @intFromBool(parent_cow_proof)) << 2) |
        (@as(u64, @intFromBool(exec_mapping_proof)) << 3) |
        (@as(u64, @intFromBool(pte_permission_proof)) << 4) |
        (@as(u64, @intFromBool(stack_canary_proof)) << 5);
}

fn fail(stage: u64) ?Report {
    failure_stage = stage;
    failure_syscalls = totalSyscalls();
    failure_ticks = timer_ticks;
    active = false;
    running = false;
    apic.stopTimer();
    apic.setTimerHook(null);
    _ = paging.activateKernelAddressSpace();
    return null;
}

pub fn run(allocator: *memory.FrameAllocator, ticks_per_second: u64) ?Report {
    if (active or running or ticks_per_second == 0) return fail(1);
    reset();
    allocator_pointer = allocator;
    allocator_checkpoint = allocator.checkpoint();
    original_cr3 = paging.currentCr3();
    parsed_main = elf64.parse(main_elf) orelse return fail(2);
    parsed_exec = elf64.parse(exec_elf) orelse return fail(3);
    if (!verifyImages()) return fail(4);
    if (!paging.enableNoExecute()) return fail(5);
    zigos_fxsave(&baseline_fx);

    const initial = createFreshProcess(.initial, invalid_index, null) orelse return fail(6);
    if (initial != 0 or processes[initial].pid != initial_pid) return fail(7);
    current_slot = initial;
    processes[initial].state = .running;
    running = true;
    active = true;
    context_switches = 1;

    apic.setTimerHook(&timerHook);
    _ = apic.startPeriodicTimer(ticks_per_second, 250) orelse return fail(8);
    if (!paging.activateAddressSpace(processes[initial].space.pml4_address)) return fail(9);
    zigos_enter_user(
        @intCast(parsed_main.entry),
        stack_base + page_bytes - 16,
        descriptor_tables.user_code_selector,
        descriptor_tables.user_data_selector,
    );

    active = false;
    apic.stopTimer();
    apic.setTimerHook(null);
    if (running or fatal_failure) return fail(10);
    if (!paging.activateKernelAddressSpace() or paging.currentCr3() != original_cr3) return fail(11);

    const initial_status = tombstoneStatusForPid(80) orelse 0x80;
    const worker_one_status = tombstoneStatus(81, 0x81);
    const worker_two_status = tombstoneStatus(82, 0x82);
    const exec_status = tombstoneStatus(83, 0x83);
    const fault_status = tombstoneStatusAny(0xE00E);
    const reuse_status = tombstoneStatusAny(0x95);
    if (initial_status != 0x80 or worker_one_status != 0x81 or worker_two_status != 0x82 or exec_status != 0x83 or fault_status != 0xE00E or reuse_status != 0x95) return fail(12);
    if (!verifyPipeRecords()) return fail(13);
    if (!verifyFinalState()) return fail(14);

    const frames_delta = allocator.allocated_pages - allocator_checkpoint.allocated_pages;
    if (frames_delta != 52 or space_count != 6) return fail(15);
    const all_spaces_empty = verifySpacesEmpty();
    if (!all_spaces_empty) return fail(16);
    if (!allocator.restore(allocator_checkpoint)) return fail(17);
    const allocator_restored = sameCheckpoint(allocator.checkpoint(), allocator_checkpoint);
    if (!allocator_restored) return fail(18);
    allocator_pointer = null;

    return .{
        .main_elf_bytes = main_elf.len,
        .exec_elf_bytes = exec_elf.len,
        .main_hash = parsed_main.file_hash,
        .exec_hash = parsed_exec.file_hash,
        .process_creations = process_creations,
        .syscall_count = totalSyscalls(),
        .spawns = spawns,
        .forks = forks,
        .execs = execs,
        .failed_execs = failed_execs,
        .waits = waits,
        .slot_reuses = slot_reuses,
        .stale_rejections = stale_rejections,
        .timer_ticks = timer_ticks,
        .timer_preemptions = timer_preemptions,
        .context_switches = context_switches,
        .yields = total_yields,
        .sleeps = total_sleeps,
        .wakeups = wakeups,
        .idle_ticks = idle_ticks,
        .cow_faults = cow_faults,
        .demand_faults = demand_faults,
        .terminal_faults = terminal_faults,
        .signals_sent = signals_sent,
        .signals_taken = signals_taken,
        .pipe_bytes = pipe_bytes_written,
        .descriptor_peak = descriptor_peak,
        .descriptor_closes = descriptor_closes,
        .open_file_peak = open_file_peak,
        .allocated_frames = frames_delta,
        .page_table_frames = space_count * 4,
        .spaces_created = space_count,
        .tombstones = tombstone_count,
        .main_exit = initial_status,
        .worker_one_exit = worker_one_status,
        .worker_two_exit = worker_two_status,
        .exec_exit = exec_status,
        .fault_exit = fault_status,
        .reuse_exit = reuse_status,
        .shared_text_verified = shared_text_proof,
        .cow_isolation_verified = child_cow_proof and parent_cow_proof,
        .exec_replacement_verified = exec_mapping_proof,
        .pipe_records_verified = true,
        .generations_verified = slot_reuses >= 2 and stale_rejections >= 2,
        .all_descriptors_closed = openDescriptorReferences() == 0,
        .all_pipes_released = activePipeCount() == 0,
        .all_spaces_empty = true,
        .allocator_restored = true,
        .cr3_restored = true,
        .returned_to_kernel = true,
    };
}

pub fn handleSyscall(
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) u64 {
    if (!active or !running or current_slot >= processes.len) return 1;
    var process = &processes[current_slot];
    if (process.state != .running or !validFrame(process.*, frame)) {
        fatal_reason = 1;
        fatal_failure = true;
        return finishToKernel();
    }
    process.syscalls +%= 1;

    switch (frame.rax) {
        getpid_syscall => frame.rax = process.pid,
        getppid_syscall => frame.rax = process.ppid,
        getrole_syscall => frame.rax = @intFromEnum(process.role),
        getticks_syscall => frame.rax = timer_ticks,
        gethandle_syscall => frame.rax = process.handle,
        spawn_syscall => frame.rax = spawnProcess(frame.rdi, frame.rsi),
        fork_syscall => frame.rax = forkProcess(frame, fx_state),
        exec_syscall => {
            const result = execProcess(frame.rdi, frame, fx_state);
            if (result != 0) frame.rax = result;
        },
        exit_syscall => return exitCurrent(frame.rdi, frame, fx_state),
        yield_syscall => return yieldCurrent(frame, fx_state),
        sleep_syscall => return sleepCurrent(frame.rdi, frame, fx_state),
        wait_syscall => return waitForChild(frame.rdi, frame.rsi, frame, fx_state),
        pipe_syscall => frame.rax = createPipe(frame.rdi),
        read_syscall => frame.rax = readDescriptor(frame.rdi, frame.rsi, frame.rdx),
        write_syscall => frame.rax = writeDescriptor(frame.rdi, frame.rsi, frame.rdx),
        close_syscall => frame.rax = closeDescriptor(frame.rdi),
        dup_syscall => frame.rax = duplicateDescriptor(frame.rdi),
        signal_syscall => frame.rax = sendSignal(frame.rdi, frame.rsi),
        take_signal_syscall => frame.rax = takeSignal(),
        process_info_syscall => frame.rax = processInfo(frame.rdi),
        vm_info_syscall => frame.rax = vmInfo(frame.rdi),
        mmap_syscall => frame.rax = mapAnonymous(),
        munmap_syscall => frame.rax = unmapAnonymous(frame.rdi),
        brk_syscall => frame.rax = updateBrk(frame.rdi),
        else => frame.rax = reject(errno_no_syscall),
    }
    return 0;
}

pub fn handleException(
    frame: *interrupt_context.ExceptionFrame,
    fx_state: *align(16) interrupt_context.FxState,
    fault_address: u64,
) bool {
    if (!active or !running or frame.vector != 14 or (frame.cs & 3) != 3) return false;
    var process = &processes[current_slot];
    if (process.state != .running or frame.cs != descriptor_tables.user_code_selector or frame.interrupted_ss != descriptor_tables.user_data_selector) return false;
    const page = @as(usize, @intCast(fault_address)) & ~@as(usize, 0xFFF);
    if (page == data_base and process.cow_data and frame.error_code == 0x7) {
        if (!resolveCow(process, .data)) return false;
        return true;
    }
    if (page == bss_base and process.cow_bss and frame.error_code == 0x7) {
        if (!resolveCow(process, .bss)) return false;
        return true;
    }
    if (page == demand_base and (frame.error_code == 0x4 or frame.error_code == 0x6) and
        !process.mapped[@intFromEnum(PageSlot.demand)])
    {
        const physical = allocateFrame() orelse return false;
        if (!paging.mapUserPageInSpace(process.space, demand_base, physical, true, false)) return false;
        process.pages[@intFromEnum(PageSlot.demand)] = physical;
        process.mapped[@intFromEnum(PageSlot.demand)] = true;
        process.demand_faults +%= 1;
        demand_faults +%= 1;
        return true;
    }
    if (page == guard_base and frame.error_code == 0x4) {
        terminal_faults +%= 1;
        process.exit_status = 0xE00E;
        process.state = .faulted;
        closeAllDescriptors(current_slot);
        wakeWaitingParent(current_slot);
        const next = findNextRunnable(current_slot) orelse return false;
        current_slot = next;
        processes[next].state = .running;
        loadExceptionContext(next, frame, fx_state);
        if (!paging.activateAddressSpace(processes[next].space.pml4_address)) return false;
        context_switches +%= 1;
        return true;
    }
    return false;
}

fn verifyImages() bool {
    if (main_elf.len != 10240 or exec_elf.len != 10240) return false;
    if (parsed_main.file_hash != expected_main_hash or parsed_exec.file_hash != expected_exec_hash) return false;
    if (parsed_main.entry != code_base or parsed_exec.entry != code_base) return false;
    if (parsed_main.load_count != 2 or parsed_exec.load_count != 2) return false;
    const main_text = parsed_main.load_segments[0];
    const exec_text = parsed_exec.load_segments[0];
    const main_data = parsed_main.load_segments[1];
    const exec_data = parsed_exec.load_segments[1];
    return main_text.file_size == 1657 and exec_text.file_size == 175 and
        main_text.flags == elf64.pf_read | elf64.pf_execute and exec_text.flags == main_text.flags and
        main_data.virtual_address == data_base and exec_data.virtual_address == data_base and
        main_data.file_size == 0x800 and exec_data.file_size == 0x800 and
        main_data.memory_size == 0x2000 and exec_data.memory_size == 0x2000;
}

fn createFreshProcess(role: Role, parent_slot: u8, inherit_from: ?usize) ?usize {
    const slot = findFreeSlot() orelse return null;
    const old_generation = processes[slot].generation;
    if (old_generation != 0) slot_reuses +%= 1;
    const generation = old_generation +% 1;
    const space = paging.createUserAddressSpace(activeAllocator()) orelse return null;
    recordSpace(space) orelse return null;

    if (main_text_frame == 0) {
        main_text_frame = allocateFrame() orelse return null;
        const text = parsed_main.segmentBytes(main_elf, 0) orelse return null;
        @memcpy(@as([*]u8, @ptrFromInt(main_text_frame))[0..text.len], text);
    }
    const data_frame = allocateFrame() orelse return null;
    const bss_frame = allocateFrame() orelse return null;
    const stack_frame = allocateFrame() orelse return null;
    const data = parsed_main.segmentBytes(main_elf, 1) orelse return null;
    @memcpy(@as([*]u8, @ptrFromInt(data_frame))[0..data.len], data);
    const canary_value = stack_canary ^ @as(u64, @intCast(slot));
    @as(*u64, @ptrFromInt(stack_frame)).* = canary_value;

    if (!paging.mapUserPageInSpace(space, code_base, main_text_frame, false, true) or
        !paging.mapUserPageInSpace(space, data_base, data_frame, true, false) or
        !paging.mapUserPageInSpace(space, bss_base, bss_frame, true, false) or
        !paging.mapUserPageInSpace(space, stack_base, stack_frame, true, false)) return null;

    processes[slot] = emptyProcess(generation);
    var process = &processes[slot];
    process.handle = makeHandle(slot, generation);
    process.pid = initial_pid + slot;
    process.parent_slot = parent_slot;
    process.ppid = if (parent_slot == invalid_index) 1 else processes[parent_slot].pid;
    process.role = role;
    process.state = .runnable;
    process.space = space;
    process.space_valid = true;
    process.pages[@intFromEnum(PageSlot.code)] = main_text_frame;
    process.pages[@intFromEnum(PageSlot.data)] = data_frame;
    process.pages[@intFromEnum(PageSlot.bss)] = bss_frame;
    process.pages[@intFromEnum(PageSlot.stack)] = stack_frame;
    process.mapped[@intFromEnum(PageSlot.code)] = true;
    process.mapped[@intFromEnum(PageSlot.data)] = true;
    process.mapped[@intFromEnum(PageSlot.bss)] = true;
    process.mapped[@intFromEnum(PageSlot.stack)] = true;
    process.stack_canary_value = canary_value;
    shared_text_proof = shared_text_proof and code_frameProof(process.space, main_text_frame);
    pte_permission_proof = pte_permission_proof and verifyProcessPtes(process.*);
    initializeContext(process, parsed_main.entry);
    copyFx(&process.fx_state, &baseline_fx);
    if (inherit_from) |source| inheritDescriptors(source, slot);
    process_creations +%= 1;
    return slot;
}

fn forkProcess(frame: *interrupt_context.Frame, fx_state: *align(16) interrupt_context.FxState) u64 {
    const parent_slot = current_slot;
    const child_slot = findFreeSlot() orelse return reject(errno_busy);
    const old_generation = processes[child_slot].generation;
    if (old_generation != 0) slot_reuses +%= 1;
    const generation = old_generation +% 1;
    const space = paging.createUserAddressSpace(activeAllocator()) orelse return reject(errno_busy);
    recordSpace(space) orelse return reject(errno_busy);
    const child_stack = allocateFrame() orelse return reject(errno_busy);
    @memcpy(
        @as([*]u8, @ptrFromInt(child_stack))[0..page_bytes],
        @as([*]const u8, @ptrFromInt(processes[parent_slot].pages[@intFromEnum(PageSlot.stack)]))[0..page_bytes],
    );
    var parent = &processes[parent_slot];
    const code_frame = parent.pages[@intFromEnum(PageSlot.code)];
    const data_frame = parent.pages[@intFromEnum(PageSlot.data)];
    const bss_frame = parent.pages[@intFromEnum(PageSlot.bss)];
    if (!paging.protectUserPageInSpace(parent.space, data_base, data_frame, false, false) or
        !paging.protectUserPageInSpace(parent.space, bss_base, bss_frame, false, false)) return reject(errno_busy);
    if (!paging.mapUserPageInSpace(space, code_base, code_frame, false, true) or
        !paging.mapUserPageInSpace(space, data_base, data_frame, false, false) or
        !paging.mapUserPageInSpace(space, bss_base, bss_frame, false, false) or
        !paging.mapUserPageInSpace(space, stack_base, child_stack, true, false)) return reject(errno_busy);

    processes[child_slot] = emptyProcess(generation);
    var child = &processes[child_slot];
    child.handle = makeHandle(child_slot, generation);
    child.pid = initial_pid + child_slot;
    child.ppid = parent.pid;
    child.parent_slot = @intCast(parent_slot);
    child.role = parent.role;
    child.state = .runnable;
    child.space = space;
    child.space_valid = true;
    child.pages[@intFromEnum(PageSlot.code)] = code_frame;
    child.pages[@intFromEnum(PageSlot.data)] = data_frame;
    child.pages[@intFromEnum(PageSlot.bss)] = bss_frame;
    child.pages[@intFromEnum(PageSlot.stack)] = child_stack;
    child.mapped[@intFromEnum(PageSlot.code)] = true;
    child.mapped[@intFromEnum(PageSlot.data)] = true;
    child.mapped[@intFromEnum(PageSlot.bss)] = true;
    child.mapped[@intFromEnum(PageSlot.stack)] = true;
    child.stack_canary_value = parent.stack_canary_value;
    child.cow_data = true;
    child.cow_bss = true;
    child.context = frame.*;
    child.context.rax = 0;
    copyFx(&child.fx_state, fx_state);
    parent.cow_data = true;
    parent.cow_bss = true;
    shared_text_proof = shared_text_proof and code_frameProof(child.space, code_frame);
    pte_permission_proof = pte_permission_proof and verifyProcessPtes(parent.*) and verifyProcessPtes(child.*);
    inheritDescriptors(parent_slot, child_slot);
    forks +%= 1;
    process_creations +%= 1;
    return child.handle;
}

fn spawnProcess(role_value: u64, flags: u64) u64 {
    const role = switch (role_value) {
        2 => Role.worker_one,
        3 => Role.worker_two,
        4 => Role.fault_worker,
        5 => Role.reuse_worker,
        else => return reject(errno_invalid),
    };
    if (flags & ~@as(u64, 1) != 0) return reject(errno_invalid);
    const slot = createFreshProcess(role, @intCast(current_slot), if ((flags & 1) != 0) current_slot else null) orelse return reject(errno_busy);
    spawns +%= 1;
    return processes[slot].handle;
}

fn execProcess(image_id: u64, frame: *interrupt_context.Frame, fx_state: *align(16) interrupt_context.FxState) u64 {
    if (image_id != 1) {
        failed_execs +%= 1;
        return reject(errno_no_exec);
    }
    var process = &processes[current_slot];
    child_cow_proof = verifyForkChildState(process.*);
    const code_frame = allocateFrame() orelse return reject(errno_busy);
    const data_frame = allocateFrame() orelse return reject(errno_busy);
    const bss_frame = allocateFrame() orelse return reject(errno_busy);
    const stack_frame = allocateFrame() orelse return reject(errno_busy);
    const text = parsed_exec.segmentBytes(exec_elf, 0) orelse return reject(errno_no_exec);
    const data = parsed_exec.segmentBytes(exec_elf, 1) orelse return reject(errno_no_exec);
    @memcpy(@as([*]u8, @ptrFromInt(code_frame))[0..text.len], text);
    @memcpy(@as([*]u8, @ptrFromInt(data_frame))[0..data.len], data);
    const exec_canary = stack_canary ^ process.pid ^ 0xE000;
    @as(*u64, @ptrFromInt(stack_frame)).* = exec_canary;

    if (!replaceMappedPage(process, .code, code_base, code_frame, false, true) or
        !replaceMappedPage(process, .data, data_base, data_frame, true, false) or
        !replaceMappedPage(process, .bss, bss_base, bss_frame, true, false) or
        !replaceMappedPage(process, .stack, stack_base, stack_frame, true, false)) return reject(errno_no_exec);
    unmapOptional(process, .heap, heap_base);
    unmapOptional(process, .demand, demand_base);
    unmapOptional(process, .anonymous, anon_base);
    process.cow_data = false;
    process.cow_bss = false;
    process.stack_canary_value = exec_canary;
    process.role = .exec_image;
    process.execs +%= 1;
    execs +%= 1;
    frame.* = std.mem.zeroes(interrupt_context.Frame);
    frame.rip = parsed_exec.entry;
    frame.cs = descriptor_tables.user_code_selector;
    frame.rflags = 0x202;
    frame.rsp = stack_base + page_bytes - 16;
    frame.ss = descriptor_tables.user_data_selector;
    copyFx(fx_state, &baseline_fx);
    exec_mapping_proof = verifyExecMapping(process.*);
    pte_permission_proof = pte_permission_proof and verifyProcessPtes(process.*);
    return 0;
}

fn replaceMappedPage(process: *Process, slot: PageSlot, virtual: usize, new_physical: usize, writable: bool, executable: bool) bool {
    const index = @intFromEnum(slot);
    const old = process.pages[index];
    if (!process.mapped[index] or !paging.replaceUserPageInSpace(process.space, virtual, old, new_physical, writable, executable)) return false;
    process.pages[index] = new_physical;
    return true;
}

fn unmapOptional(process: *Process, slot: PageSlot, virtual: usize) void {
    const index = @intFromEnum(slot);
    if (!process.mapped[index]) return;
    if (paging.unmapUserPageInSpace(process.space, virtual, process.pages[index])) {
        process.mapped[index] = false;
        process.pages[index] = 0;
    }
}

fn exitCurrent(status: u64, frame: *interrupt_context.Frame, fx_state: *align(16) interrupt_context.FxState) u64 {
    const slot = current_slot;
    if (slot == 0) {
        if (!copyFromProcess(slot, data_base + 0x380, &final_pipe_records)) {
            fatal_reason = 9;
            fatal_failure = true;
            return finishToKernel();
        }
        pipe_records_captured = true;
        parent_cow_proof = verifyParentIsolation(processes[slot]);
    }
    processes[slot].exit_status = status;
    processes[slot].state = .zombie;
    closeAllDescriptors(slot);
    wakeWaitingParent(slot);
    if (slot == 0 and noLiveChildren()) {
        recordTombstone(processes[slot].handle, status, false);
        cleanupMappings(slot);
        processes[slot].state = .free;
        running = false;
        return finishToKernel();
    }
    return scheduleAway(frame, fx_state);
}

fn yieldCurrent(frame: *interrupt_context.Frame, fx_state: *align(16) interrupt_context.FxState) u64 {
    processes[current_slot].yields +%= 1;
    total_yields +%= 1;
    frame.rax = 0;
    saveCurrent(frame, fx_state);
    processes[current_slot].state = .runnable;
    return switchToNext(frame, fx_state, true);
}

fn sleepCurrent(ticks: u64, frame: *interrupt_context.Frame, fx_state: *align(16) interrupt_context.FxState) u64 {
    if (ticks == 0 or ticks > 32) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    frame.rax = 0;
    saveCurrent(frame, fx_state);
    processes[current_slot].wake_tick = timer_ticks + ticks;
    processes[current_slot].state = .sleeping;
    processes[current_slot].sleeps +%= 1;
    total_sleeps +%= 1;
    return switchToNext(frame, fx_state, false);
}

fn waitForChild(handle: u64, status_address: u64, frame: *interrupt_context.Frame, fx_state: *align(16) interrupt_context.FxState) u64 {
    const child_slot = resolveHandle(handle) orelse {
        if (hasTombstone(handle)) stale_rejections +%= 1;
        frame.rax = reject(errno_child);
        return 0;
    };
    if (processes[child_slot].parent_slot != current_slot) {
        frame.rax = reject(errno_child);
        return 0;
    }
    if (!validateRange(processes[current_slot], status_address, 8, true)) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    waits +%= 1;
    if (processes[child_slot].state == .zombie or processes[child_slot].state == .faulted) {
        const status = processes[child_slot].exit_status;
        if (!copyToProcess(current_slot, status_address, std.mem.asBytes(&status))) {
            frame.rax = reject(errno_fault);
            return 0;
        }
        reapProcess(child_slot);
        frame.rax = handle;
        return 0;
    }
    frame.rax = 0;
    saveCurrent(frame, fx_state);
    processes[current_slot].wait_handle = handle;
    processes[current_slot].wait_status_address = status_address;
    processes[current_slot].state = .waiting;
    return switchToNext(frame, fx_state, false);
}

fn wakeWaitingParent(child_slot: usize) void {
    const parent_slot = processes[child_slot].parent_slot;
    if (parent_slot == invalid_index) return;
    var parent = &processes[parent_slot];
    if (parent.state != .waiting or parent.wait_handle != processes[child_slot].handle) return;
    const status = processes[child_slot].exit_status;
    if (!copyToProcess(parent_slot, parent.wait_status_address, std.mem.asBytes(&status))) {
        fatal_reason = 2;
        fatal_failure = true;
        return;
    }
    parent.context.rax = processes[child_slot].handle;
    parent.wait_handle = 0;
    parent.wait_status_address = 0;
    parent.state = .runnable;
    wakeups +%= 1;
    reapProcess(child_slot);
}

fn scheduleAway(frame: *interrupt_context.Frame, fx_state: *align(16) interrupt_context.FxState) u64 {
    const next = findNextRunnableOrAdvance(current_slot) orelse {
        fatal_reason = 3;
        fatal_failure = true;
        return finishToKernel();
    };
    current_slot = next;
    processes[next].state = .running;
    loadContext(next, frame, fx_state);
    if (!paging.activateAddressSpace(processes[next].space.pml4_address)) {
        fatal_reason = 4;
        fatal_failure = true;
        return finishToKernel();
    }
    context_switches +%= 1;
    return 0;
}

fn switchToNext(frame: *interrupt_context.Frame, fx_state: *align(16) interrupt_context.FxState, allow_current: bool) u64 {
    wakeSleeping();
    const old = current_slot;
    const next = findNextRunnableOrAdvance(old) orelse {
        if (allow_current) {
            processes[old].state = .running;
            loadContext(old, frame, fx_state);
            return 0;
        }
        fatal_reason = 5;
        fatal_failure = true;
        return finishToKernel();
    };
    current_slot = next;
    processes[next].state = .running;
    loadContext(next, frame, fx_state);
    if (!paging.activateAddressSpace(processes[next].space.pml4_address)) {
        fatal_reason = 4;
        fatal_failure = true;
        return finishToKernel();
    }
    context_switches +%= 1;
    return 0;
}

fn timerHook(frame: *interrupt_context.Frame, fx_state: *align(16) interrupt_context.FxState) callconv(cc) void {
    if (!active or !running or (frame.cs & 3) != 3 or current_slot >= processes.len) return;
    timer_ticks +%= 1;
    wakeSleeping();
    if (processes[current_slot].state != .running) return;
    const old = current_slot;
    const next = findNextRunnable(old) orelse return;
    saveCurrent(frame, fx_state);
    processes[old].state = .runnable;
    processes[old].preemptions +%= 1;
    processes[next].state = .running;
    current_slot = next;
    timer_preemptions +%= 1;
    context_switches +%= 1;
    loadContext(next, frame, fx_state);
    if (!paging.activateAddressSpace(processes[next].space.pml4_address)) {
        fatal_reason = 6;
        fatal_failure = true;
    }
}

fn wakeSleeping() void {
    for (&processes) |*process| {
        if (process.state == .sleeping and timer_ticks >= process.wake_tick) {
            process.state = .runnable;
            process.wake_tick = 0;
            wakeups +%= 1;
        }
    }
}

fn createPipe(address: u64) u64 {
    if (!validateRange(processes[current_slot], address, 8, true)) return reject(errno_fault);
    const pipe_index = findFreePipe() orelse return reject(errno_busy);
    const read_open = findFreeOpenFile() orelse return reject(errno_busy);
    open_files[read_open].active = true;
    const write_open = findFreeOpenFile() orelse {
        open_files[read_open] = .{};
        return reject(errno_busy);
    };
    const read_fd = findFreeDescriptor(current_slot) orelse {
        open_files[read_open] = .{};
        return reject(errno_busy);
    };
    processes[current_slot].descriptors[read_fd] = @intCast(read_open);
    const write_fd = findFreeDescriptor(current_slot) orelse {
        processes[current_slot].descriptors[read_fd] = invalid_index;
        open_files[read_open] = .{};
        return reject(errno_busy);
    };
    pipes[pipe_index] = .{ .active = true, .readers = 1, .writers = 1 };
    open_files[read_open] = .{ .active = true, .kind = .pipe_read, .pipe_index = @intCast(pipe_index), .references = 1 };
    open_files[write_open] = .{ .active = true, .kind = .pipe_write, .pipe_index = @intCast(pipe_index), .references = 1 };
    processes[current_slot].descriptors[write_fd] = @intCast(write_open);
    const fds = [2]u32{ @intCast(read_fd), @intCast(write_fd) };
    if (!copyToProcess(current_slot, address, std.mem.asBytes(&fds))) return reject(errno_fault);
    updatePeaks();
    return 0;
}

fn readDescriptor(fd_value: u64, address: u64, length: u64) u64 {
    const fd = descriptorIndex(fd_value) orelse return reject(errno_bad_fd);
    const open_index = processes[current_slot].descriptors[fd];
    if (open_index == invalid_index) return reject(errno_bad_fd);
    const file = &open_files[open_index];
    if (!file.active or file.kind != .pipe_read) return reject(errno_bad_fd);
    if (length == 0) return 0;
    if (length > 128) return reject(errno_invalid);
    const pipe = &pipes[file.pipe_index];
    const available = pipe.write_offset - pipe.read_offset;
    if (available == 0) return if (pipe.writers == 0) 0 else reject(errno_would_block);
    const count: usize = @intCast(@min(length, available));
    if (!copyToProcess(current_slot, address, pipe.bytes[pipe.read_offset .. pipe.read_offset + count])) return reject(errno_fault);
    pipe.read_offset += @intCast(count);
    return count;
}

fn writeDescriptor(fd_value: u64, address: u64, length: u64) u64 {
    const fd = descriptorIndex(fd_value) orelse return reject(errno_bad_fd);
    const open_index = processes[current_slot].descriptors[fd];
    if (open_index == invalid_index) return reject(errno_bad_fd);
    const file = &open_files[open_index];
    if (!file.active or file.kind != .pipe_write) return reject(errno_bad_fd);
    if (length == 0) return 0;
    if (length > 64) return reject(errno_invalid);
    const pipe = &pipes[file.pipe_index];
    if (pipe.readers == 0 or length > pipe.bytes.len - pipe.write_offset) return reject(errno_busy);
    const count: usize = @intCast(length);
    if (!copyFromProcess(current_slot, address, pipe.bytes[pipe.write_offset .. pipe.write_offset + count])) return reject(errno_fault);
    pipe.write_offset += @intCast(count);
    pipe_bytes_written +%= count;
    return count;
}

fn closeDescriptor(fd_value: u64) u64 {
    const fd = descriptorIndex(fd_value) orelse return reject(errno_bad_fd);
    if (!closeDescriptorIndex(current_slot, fd)) return reject(errno_bad_fd);
    return 0;
}

fn duplicateDescriptor(fd_value: u64) u64 {
    const fd = descriptorIndex(fd_value) orelse return reject(errno_bad_fd);
    const open_index = processes[current_slot].descriptors[fd];
    if (open_index == invalid_index or !open_files[open_index].active) return reject(errno_bad_fd);
    const target = findFreeDescriptor(current_slot) orelse return reject(errno_busy);
    processes[current_slot].descriptors[target] = open_index;
    open_files[open_index].references +%= 1;
    updatePeaks();
    return target;
}

fn closeDescriptorIndex(slot: usize, fd: usize) bool {
    const open_index = processes[slot].descriptors[fd];
    if (open_index == invalid_index or !open_files[open_index].active or open_files[open_index].references == 0) return false;
    processes[slot].descriptors[fd] = invalid_index;
    open_files[open_index].references -= 1;
    descriptor_closes +%= 1;
    if (open_files[open_index].references == 0) {
        const pipe_index = open_files[open_index].pipe_index;
        switch (open_files[open_index].kind) {
            .pipe_read => if (pipes[pipe_index].readers != 0) {
                pipes[pipe_index].readers -= 1;
            },
            .pipe_write => if (pipes[pipe_index].writers != 0) {
                pipes[pipe_index].writers -= 1;
            },
            .free => {},
        }
        open_files[open_index] = .{};
        if (pipes[pipe_index].readers == 0 and pipes[pipe_index].writers == 0) pipes[pipe_index].active = false;
    }
    return true;
}

fn closeAllDescriptors(slot: usize) void {
    for (0..maximum_descriptors) |fd| _ = closeDescriptorIndex(slot, fd);
}

fn inheritDescriptors(source: usize, target: usize) void {
    for (processes[source].descriptors, 0..) |open_index, fd| {
        if (open_index == invalid_index) continue;
        processes[target].descriptors[fd] = open_index;
        open_files[open_index].references +%= 1;
    }
    updatePeaks();
}

fn sendSignal(target_handle: u64, signal: u64) u64 {
    if (signal == 0 or signal >= 64) return reject(errno_invalid);
    const target_slot = if (target_handle == 0)
        if (processes[current_slot].parent_slot == invalid_index) return reject(errno_no_process) else processes[current_slot].parent_slot
    else
        resolveHandle(target_handle) orelse {
            stale_rejections +%= @intFromBool(hasTombstone(target_handle));
            return reject(errno_no_process);
        };
    const state = processes[target_slot].state;
    if (state == .free or state == .zombie or state == .faulted) return reject(errno_no_process);
    processes[target_slot].pending_signals |= @as(u64, 1) << @intCast(signal);
    signals_sent +%= 1;
    return 0;
}

fn takeSignal() u64 {
    var process = &processes[current_slot];
    if (process.pending_signals == 0) return 0;
    const signal: u6 = @intCast(@ctz(process.pending_signals));
    process.pending_signals &= ~(@as(u64, 1) << signal);
    signals_taken +%= 1;
    return signal;
}

fn processInfo(address: u64) u64 {
    const process = processes[current_slot];
    var bytes: [128]u8 = @splat(0);
    write64(&bytes, 0, process.pid);
    write64(&bytes, 8, process.ppid);
    write64(&bytes, 16, process.handle);
    write64(&bytes, 24, @intFromEnum(process.role));
    write64(&bytes, 32, @intFromEnum(process.state));
    write64(&bytes, 40, process.syscalls);
    write64(&bytes, 48, process.preemptions);
    write64(&bytes, 56, process.yields);
    write64(&bytes, 64, process.sleeps);
    write64(&bytes, 72, process.pending_signals);
    write64(&bytes, 80, openDescriptorCount(current_slot));
    write64(&bytes, 88, process.space.pml4_address);
    write64(&bytes, 96, process.context.rip);
    write64(&bytes, 104, process.context.rsp);
    write64(&bytes, 112, process.cow_faults);
    write64(&bytes, 120, process.demand_faults);
    if (!copyToProcess(current_slot, address, &bytes)) return reject(errno_fault);
    return 0;
}

fn vmInfo(address: u64) u64 {
    const process = processes[current_slot];
    var bytes: [96]u8 = @splat(0);
    write64(&bytes, 0, code_base);
    write64(&bytes, 8, data_base);
    write64(&bytes, 16, bss_base);
    write64(&bytes, 24, stack_base);
    write64(&bytes, 32, heap_base);
    write64(&bytes, 40, demand_base);
    write64(&bytes, 48, anon_base);
    write64(&bytes, 56, guard_base);
    write64(&bytes, 64, mappedPageCount(process));
    write64(&bytes, 72, @intFromBool(process.cow_data));
    write64(&bytes, 80, @intFromBool(process.cow_bss));
    write64(&bytes, 88, process.space.table_pages);
    if (!copyToProcess(current_slot, address, &bytes)) return reject(errno_fault);
    return 0;
}

fn mapAnonymous() u64 {
    var process = &processes[current_slot];
    const index = @intFromEnum(PageSlot.anonymous);
    if (process.mapped[index]) return reject(errno_busy);
    const physical = allocateFrame() orelse return reject(errno_busy);
    if (!paging.mapUserPageInSpace(process.space, anon_base, physical, true, false)) return reject(errno_busy);
    process.pages[index] = physical;
    process.mapped[index] = true;
    return anon_base;
}

fn unmapAnonymous(address: u64) u64 {
    if (address != anon_base) return reject(errno_invalid);
    var process = &processes[current_slot];
    const index = @intFromEnum(PageSlot.anonymous);
    if (!process.mapped[index]) return reject(errno_invalid);
    if (!paging.unmapUserPageInSpace(process.space, anon_base, process.pages[index])) return reject(errno_busy);
    process.mapped[index] = false;
    process.pages[index] = 0;
    return 0;
}

fn updateBrk(requested: u64) u64 {
    var process = &processes[current_slot];
    const index = @intFromEnum(PageSlot.heap);
    if (requested == heap_base) {
        if (process.mapped[index]) {
            if (!paging.unmapUserPageInSpace(process.space, heap_base, process.pages[index])) return reject(errno_busy);
            process.mapped[index] = false;
            process.pages[index] = 0;
        }
        return heap_base;
    }
    if (requested == heap_base + page_bytes) {
        if (!process.mapped[index]) {
            const physical = allocateFrame() orelse return reject(errno_busy);
            if (!paging.mapUserPageInSpace(process.space, heap_base, physical, true, false)) return reject(errno_busy);
            process.pages[index] = physical;
            process.mapped[index] = true;
        }
        return requested;
    }
    return reject(errno_invalid);
}

fn resolveCow(process: *Process, slot: PageSlot) bool {
    const index = @intFromEnum(slot);
    const old = process.pages[index];
    const physical = allocateFrame() orelse return false;
    @memcpy(
        @as([*]u8, @ptrFromInt(physical))[0..page_bytes],
        @as([*]const u8, @ptrFromInt(old))[0..page_bytes],
    );
    const virtual = if (slot == .data) data_base else bss_base;
    if (!paging.replaceUserPageInSpace(process.space, virtual, old, physical, true, false)) return false;
    process.pages[index] = physical;
    if (slot == .data) process.cow_data = false else process.cow_bss = false;
    process.cow_faults +%= 1;
    cow_faults +%= 1;
    return true;
}

fn reapProcess(slot: usize) void {
    recordTombstone(processes[slot].handle, processes[slot].exit_status, processes[slot].state == .faulted);
    cleanupMappings(slot);
    const generation = processes[slot].generation;
    processes[slot] = emptyProcess(generation);
}

fn cleanupMappings(slot: usize) void {
    var process = &processes[slot];
    if (!process.space_valid) return;
    if (process.stack_canary_value == 0 or process.pages[@intFromEnum(PageSlot.stack)] == 0 or
        @as(*const u64, @ptrFromInt(process.pages[@intFromEnum(PageSlot.stack)])).* != process.stack_canary_value)
    {
        stack_canary_proof = false;
    }
    pte_permission_proof = pte_permission_proof and verifyProcessPtes(process.*);
    const addresses = [_]usize{ code_base, data_base, bss_base, stack_base, heap_base, demand_base, anon_base };
    for (addresses, 0..) |address, index| {
        if (process.mapped[index]) {
            if (!paging.unmapUserPageInSpace(process.space, address, process.pages[index])) {
                fatal_reason = 7;
                fatal_failure = true;
            }
            process.mapped[index] = false;
            process.pages[index] = 0;
        }
    }
}

fn recordTombstone(handle: u64, status: u64, faulted: bool) void {
    for (&tombstones) |*entry| {
        if (!entry.valid) {
            entry.* = .{ .valid = true, .handle = handle, .status = status, .faulted = faulted };
            tombstone_count +%= 1;
            return;
        }
    }
    fatal_reason = 8;
    fatal_failure = true;
}

fn validFrame(process: Process, frame: *const interrupt_context.Frame) bool {
    if (frame.cs != descriptor_tables.user_code_selector or frame.ss != descriptor_tables.user_data_selector) return false;
    if (frame.rsp < stack_base or frame.rsp >= stack_base + page_bytes) return false;
    return paging.translateUserAddressInSpace(process.space, @intCast(frame.rip), false, true) != null;
}

fn initializeContext(process: *Process, entry: u64) void {
    process.context = std.mem.zeroes(interrupt_context.Frame);
    process.context.rip = entry;
    process.context.cs = descriptor_tables.user_code_selector;
    process.context.rflags = 0x202;
    process.context.rsp = stack_base + page_bytes - 16;
    process.context.ss = descriptor_tables.user_data_selector;
}

fn saveCurrent(frame: *const interrupt_context.Frame, fx_state: *align(16) const interrupt_context.FxState) void {
    processes[current_slot].context = frame.*;
    copyFx(&processes[current_slot].fx_state, fx_state);
}

fn loadContext(slot: usize, frame: *interrupt_context.Frame, fx_state: *align(16) interrupt_context.FxState) void {
    frame.* = processes[slot].context;
    copyFx(fx_state, &processes[slot].fx_state);
}

fn loadExceptionContext(slot: usize, frame: *interrupt_context.ExceptionFrame, fx_state: *align(16) interrupt_context.FxState) void {
    const context = processes[slot].context;
    frame.r15 = context.r15;
    frame.r14 = context.r14;
    frame.r13 = context.r13;
    frame.r12 = context.r12;
    frame.r11 = context.r11;
    frame.r10 = context.r10;
    frame.r9 = context.r9;
    frame.r8 = context.r8;
    frame.rdi = context.rdi;
    frame.rsi = context.rsi;
    frame.rbp = context.rbp;
    frame.rdx = context.rdx;
    frame.rcx = context.rcx;
    frame.rbx = context.rbx;
    frame.rax = context.rax;
    frame.rip = context.rip;
    frame.cs = context.cs;
    frame.rflags = context.rflags;
    frame.interrupted_rsp = context.rsp;
    frame.interrupted_ss = context.ss;
    copyFx(fx_state, &processes[slot].fx_state);
}

fn copyFx(destination: *align(16) interrupt_context.FxState, source: *align(16) const interrupt_context.FxState) void {
    @memcpy(destination.bytes[0..], source.bytes[0..]);
}

fn copyFromProcess(slot: usize, address: u64, destination: []u8) bool {
    var offset: usize = 0;
    while (offset < destination.len) {
        const virtual = std.math.add(u64, address, offset) catch return false;
        const physical = paging.translateUserAddressInSpace(processes[slot].space, @intCast(virtual), false, false) orelse return false;
        const page_remaining = page_bytes - (@as(usize, @intCast(virtual)) & 0xFFF);
        const count = @min(destination.len - offset, page_remaining);
        @memcpy(destination[offset .. offset + count], @as([*]const u8, @ptrFromInt(physical))[0..count]);
        offset += count;
    }
    return true;
}

fn copyToProcess(slot: usize, address: u64, source: []const u8) bool {
    var offset: usize = 0;
    while (offset < source.len) {
        const virtual = std.math.add(u64, address, offset) catch return false;
        const physical = paging.translateUserAddressInSpace(processes[slot].space, @intCast(virtual), true, false) orelse return false;
        const page_remaining = page_bytes - (@as(usize, @intCast(virtual)) & 0xFFF);
        const count = @min(source.len - offset, page_remaining);
        @memcpy(@as([*]u8, @ptrFromInt(physical))[0..count], source[offset .. offset + count]);
        offset += count;
    }
    return true;
}

fn validateRange(process: Process, address: u64, length: usize, write: bool) bool {
    if (length == 0) return true;
    const end = std.math.add(u64, address, length - 1) catch return false;
    var page = @as(usize, @intCast(address)) & ~@as(usize, 0xFFF);
    const final_page = @as(usize, @intCast(end)) & ~@as(usize, 0xFFF);
    while (true) {
        if (paging.translateUserAddressInSpace(process.space, page, write, false) == null) return false;
        if (page == final_page) break;
        page += page_bytes;
    }
    return true;
}

fn allocateFrame() ?usize {
    const frame = activeAllocator().allocateBelow(memory.four_gib) orelse return null;
    @memset(@as([*]u8, @ptrFromInt(frame))[0..page_bytes], 0);
    return frame;
}

fn activeAllocator() *memory.FrameAllocator {
    return allocator_pointer orelse unreachable;
}

fn recordSpace(space: paging.UserAddressSpace) ?void {
    if (space_count >= spaces.len) return null;
    spaces[space_count] = space;
    space_count += 1;
}

fn findFreeSlot() ?usize {
    for (processes, 0..) |process, slot| if (process.state == .free) return slot;
    return null;
}

fn findNextRunnable(old_slot: usize) ?usize {
    var offset: usize = 1;
    while (offset <= processes.len) : (offset += 1) {
        const slot = (old_slot + offset) % processes.len;
        if (processes[slot].state == .runnable) return slot;
    }
    return null;
}

fn findNextRunnableOrAdvance(old_slot: usize) ?usize {
    if (findNextRunnable(old_slot)) |slot| return slot;
    var earliest: u64 = std.math.maxInt(u64);
    for (processes) |process| {
        if (process.state == .sleeping and process.wake_tick < earliest) earliest = process.wake_tick;
    }
    if (earliest == std.math.maxInt(u64)) return null;
    if (earliest > timer_ticks) {
        idle_ticks +%= earliest - timer_ticks;
        timer_ticks = earliest;
    }
    wakeSleeping();
    return findNextRunnable(old_slot);
}

fn findFreeDescriptor(slot: usize) ?usize {
    for (processes[slot].descriptors, 0..) |value, fd| if (value == invalid_index) return fd;
    return null;
}

fn findFreeOpenFile() ?usize {
    for (open_files, 0..) |file, index| if (!file.active) return index;
    return null;
}

fn findFreePipe() ?usize {
    for (pipes, 0..) |pipe, index| if (!pipe.active) return index;
    return null;
}

fn resolveHandle(handle: u64) ?usize {
    const slot: usize = @intCast(handle & 0xFFFF_FFFF);
    if (slot >= processes.len or processes[slot].state == .free or processes[slot].handle != handle) return null;
    return slot;
}

fn hasTombstone(handle: u64) bool {
    for (tombstones) |entry| if (entry.valid and entry.handle == handle) return true;
    return false;
}

fn makeHandle(slot: usize, generation: u32) u64 {
    return (@as(u64, generation) << 32) | slot;
}

fn emptyProcess(generation: u32) Process {
    var process = Process{};
    process.generation = generation;
    process.fx_state = std.mem.zeroes(interrupt_context.FxState);
    return process;
}

fn descriptorIndex(value: u64) ?usize {
    if (value >= maximum_descriptors) return null;
    return @intCast(value);
}

fn updatePeaks() void {
    descriptor_peak = @max(descriptor_peak, openDescriptorReferences());
    var count: u64 = 0;
    for (open_files) |file| if (file.active) {
        count += 1;
    };
    open_file_peak = @max(open_file_peak, count);
}

fn openDescriptorCount(slot: usize) u64 {
    var count: u64 = 0;
    for (processes[slot].descriptors) |value| if (value != invalid_index) {
        count += 1;
    };
    return count;
}

fn openDescriptorReferences() u64 {
    var count: u64 = 0;
    for (open_files) |file| if (file.active) {
        count += file.references;
    };
    return count;
}

fn activePipeCount() u64 {
    var count: u64 = 0;
    for (pipes) |pipe| if (pipe.active) {
        count += 1;
    };
    return count;
}

fn mappedPageCount(process: Process) u64 {
    var count: u64 = 0;
    for (process.mapped) |mapped| if (mapped) {
        count += 1;
    };
    return count;
}

fn noLiveChildren() bool {
    for (processes[1..]) |process| if (process.state != .free) return false;
    return true;
}

fn finishToKernel() u64 {
    running = false;
    _ = paging.activateKernelAddressSpace();
    return 1;
}

fn code_frameProof(space: paging.UserAddressSpace, expected: usize) bool {
    const info = paging.inspectUserPageInSpace(space, code_base) orelse return false;
    return info.physical_address == expected and !info.writable and info.executable;
}

fn verifyProcessPtes(process: Process) bool {
    if (!process.space_valid) return true;
    const code = paging.inspectUserPageInSpace(process.space, code_base) orelse return false;
    const data = paging.inspectUserPageInSpace(process.space, data_base) orelse return false;
    const bss = paging.inspectUserPageInSpace(process.space, bss_base) orelse return false;
    const stack = paging.inspectUserPageInSpace(process.space, stack_base) orelse return false;
    if (code.writable or !code.executable or data.executable or bss.executable or stack.executable or !stack.writable) return false;
    if (data.writable == process.cow_data or bss.writable == process.cow_bss) return false;
    if (paging.inspectUserPageInSpace(process.space, guard_base) != null) return false;
    return true;
}

fn verifyForkChildState(process: Process) bool {
    if (!process.mapped[@intFromEnum(PageSlot.data)] or !process.mapped[@intFromEnum(PageSlot.bss)] or
        !process.mapped[@intFromEnum(PageSlot.demand)]) return false;
    const data_value = @as(*const u64, @ptrFromInt(process.pages[@intFromEnum(PageSlot.data)] + 0x180)).*;
    const bss_value = @as(*const u64, @ptrFromInt(process.pages[@intFromEnum(PageSlot.bss)])).*;
    const demand_value = @as(*const u64, @ptrFromInt(process.pages[@intFromEnum(PageSlot.demand)])).*;
    return data_value == 0xC0C0_C0C0_C0C0_C0C0 and bss_value == 0xB55B_55B5_5B55_B55B and
        demand_value == 0xD00D_D00D_D00D_D00D and !process.cow_data and !process.cow_bss;
}

fn verifyParentIsolation(process: Process) bool {
    if (process.pages[@intFromEnum(PageSlot.data)] == 0 or process.pages[@intFromEnum(PageSlot.bss)] == 0) return false;
    const data_value = @as(*const u64, @ptrFromInt(process.pages[@intFromEnum(PageSlot.data)] + 0x180)).*;
    const bss_value = @as(*const u64, @ptrFromInt(process.pages[@intFromEnum(PageSlot.bss)])).*;
    return data_value == 0 and bss_value == 0 and !process.mapped[@intFromEnum(PageSlot.demand)] and
        !process.cow_data and process.cow_bss;
}

fn verifyExecMapping(process: Process) bool {
    const code = @as([*]const u8, @ptrFromInt(process.pages[@intFromEnum(PageSlot.code)]))[0..175];
    const data = @as([*]const u8, @ptrFromInt(process.pages[@intFromEnum(PageSlot.data)]))[0..0x800];
    const bss = @as([*]const u8, @ptrFromInt(process.pages[@intFromEnum(PageSlot.bss)]))[0..page_bytes];
    const expected_code = parsed_exec.segmentBytes(exec_elf, 0) orelse return false;
    const expected_data = parsed_exec.segmentBytes(exec_elf, 1) orelse return false;
    return std.mem.eql(u8, code, expected_code) and std.mem.eql(u8, data, expected_data) and
        std.mem.allEqual(u8, bss, 0) and process.role == .exec_image;
}

fn verifyUniqueSpaces() bool {
    for (spaces[0..space_count], 0..) |left, left_index| {
        if (left.table_pages != 4 or left.pml4_address == 0 or left.table_address == 0) return false;
        for (spaces[left_index + 1 .. space_count]) |right| {
            if (left.pml4_address == right.pml4_address or left.pdpt_address == right.pdpt_address or
                left.directory_address == right.directory_address or left.table_address == right.table_address) return false;
        }
    }
    return true;
}

fn verifyPipeRecords() bool {
    if (!pipe_records_captured) return false;
    const records = [_][]const u8{ "WORKER1!", "WORKER2!", "EXECCHLD", "REUSE003" };
    var seen: u4 = 0;
    for (0..4) |index| {
        const item = final_pipe_records[index * 8 .. index * 8 + 8];
        for (records, 0..) |record, record_index| {
            if (std.mem.eql(u8, item, record)) seen |= @as(u4, 1) << @intCast(record_index);
        }
    }
    return seen == 0xF;
}

fn verifyFinalState() bool {
    if (process_creations != 6 or totalSyscalls() != 24 or spawns != 4 or forks != 1 or execs != 1 or failed_execs != 2)
        return finalVerificationFailure(1);
    if (waits != 5 or slot_reuses != 2 or stale_rejections != 2 or tombstone_count != 6)
        return finalVerificationFailure(2);
    if (cow_faults < 3 or demand_faults != 2 or terminal_faults != 1)
        return finalVerificationFailure(3);
    if (signals_sent != 2 or signals_taken != 2 or pipe_bytes_written != 32)
        return finalVerificationFailure(4);
    if (descriptor_peak != 8 or descriptor_closes != 13 or open_file_peak != 2)
        return finalVerificationFailure(5);
    if (total_yields != 2 or total_sleeps != 1 or idle_ticks > 2)
        return finalVerificationFailure(6);
    if (timer_ticks == 0 or timer_preemptions < 2 or context_switches < 6)
        return finalVerificationFailure(7);
    if (!shared_text_proof or !child_cow_proof or !parent_cow_proof or !exec_mapping_proof or !pte_permission_proof or !stack_canary_proof)
        return finalVerificationFailure(8);
    if (openDescriptorReferences() != 0 or activePipeCount() != 0)
        return finalVerificationFailure(9);
    return true;
}

fn finalVerificationFailure(reason: u64) bool {
    final_verify_reason = reason;
    return false;
}

fn verifySpacesEmpty() bool {
    if (!verifyUniqueSpaces()) return false;
    for (spaces[0..space_count]) |space| if (!paging.userAddressSpaceEmpty(space)) return false;
    return true;
}

fn tombstoneStatusForPid(pid: u64) ?u64 {
    for (tombstones) |entry| {
        if (!entry.valid) continue;
        const slot = entry.handle & 0xFFFF_FFFF;
        if (initial_pid + slot == pid) return entry.status;
    }
    return null;
}

fn tombstoneStatus(pid: u64, expected: u64) u64 {
    for (tombstones) |entry| {
        if (!entry.valid or entry.status != expected) continue;
        const slot = entry.handle & 0xFFFF_FFFF;
        if (initial_pid + slot == pid) return entry.status;
    }
    return 0;
}

fn tombstoneStatusAny(status: u64) u64 {
    for (tombstones) |entry| if (entry.valid and entry.status == status) return status;
    return 0;
}

fn totalSyscalls() u64 {
    var total: u64 = 0;
    for (processes) |process| total +%= process.syscalls;
    return total;
}

fn write64(destination: []u8, offset: usize, value: u64) void {
    for (0..8) |index| destination[offset + index] = @truncate(value >> @intCast(index * 8));
}

fn reject(code: i64) u64 {
    return @bitCast(code);
}

fn sameCheckpoint(left: memory.FrameAllocator.Checkpoint, right: memory.FrameAllocator.Checkpoint) bool {
    return left.region_index == right.region_index and left.current_frame == right.current_frame and
        left.current_region_end == right.current_region_end and left.allocated_pages == right.allocated_pages;
}

fn reset() void {
    for (&processes) |*process| process.* = emptyProcess(0);
    for (&open_files) |*file| file.* = .{};
    for (&pipes) |*pipe| pipe.* = .{};
    for (&tombstones) |*entry| entry.* = .{};
    for (&spaces) |*space| space.* = .{ .pml4_address = 0, .pdpt_address = 0, .directory_address = 0, .table_address = 0, .table_pages = 0 };
    active = false;
    running = false;
    fatal_failure = false;
    fatal_reason = 0;
    allocator_pointer = null;
    current_slot = 0;
    space_count = 0;
    main_text_frame = 0;
    process_creations = 0;
    spawns = 0;
    forks = 0;
    execs = 0;
    failed_execs = 0;
    waits = 0;
    slot_reuses = 0;
    stale_rejections = 0;
    timer_ticks = 0;
    timer_preemptions = 0;
    context_switches = 0;
    total_yields = 0;
    total_sleeps = 0;
    wakeups = 0;
    idle_ticks = 0;
    cow_faults = 0;
    demand_faults = 0;
    terminal_faults = 0;
    signals_sent = 0;
    signals_taken = 0;
    pipe_bytes_written = 0;
    descriptor_peak = 0;
    descriptor_closes = 0;
    open_file_peak = 0;
    tombstone_count = 0;
    shared_text_proof = true;
    child_cow_proof = false;
    parent_cow_proof = false;
    exec_mapping_proof = false;
    pte_permission_proof = true;
    stack_canary_proof = true;
    final_pipe_records = @splat(0);
    pipe_records_captured = false;
    final_verify_reason = 0;
    failure_stage = 0;
    failure_syscalls = 0;
    failure_ticks = 0;
}
