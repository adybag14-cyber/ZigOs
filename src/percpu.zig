const std = @import("std");
const apic = @import("apic.zig");
const interrupt_context = @import("interrupt_context.zig");
const synchronization = @import("synchronization.zig");

const cc = std.os.uefi.cc;
const code_selector: u16 = 0x08;
const data_selector: u16 = 0x10;
const tss_selector: u16 = 0x18;
const exception_vector_count: usize = 32;
const spurious_vector: usize = 0xFF;
const state_magic: u64 = 0x5A49_474F_5350_4355;
pub const run_queue_capacity: usize = 8;
pub const ap_work_vector: u8 = 0x42;
pub const ap_timer_vector: u8 = 0x43;
const external_irq0_vector: u8 = 0x44;
const ps2_keyboard_vector: u8 = 0x45;
const nvme_vector: u8 = 0x46;
const ahci_vector: u8 = 0x47;
const xhci_vector: u8 = 0x48;
const e1000e_vector: u8 = 0x49;
const run_queue_command: u32 = 2;
const run_queue_checksum_seed: u64 = 0xCBF2_9CE4_8422_2325;
const work_stealing_checksum_seed: u64 = 0x5753_5445_414C_494E;
const local_task_count: usize = 2;
const local_task_trace_length: usize = 12;
const saved_integer_bytes: usize = 8 * @sizeOf(usize);
const saved_xmm_bytes: usize = 10 * 16;
const task_bootstrap_frame_bytes: usize = saved_integer_bytes + saved_xmm_bytes;
const task_stack_canary: u64 = 0x4150_5441_534B_434E;

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

const RunQueueEntry = struct {
    sequence: u32,
    command: u32,
    input: u64,
    result: u64,
    completed: u32,
    executor_apic_id: u32,
    stolen: u32,
    executor_state_index: u32,
};

const LocalTaskStatus = enum(u32) {
    unused,
    runnable,
    running,
    finished,
};

const LocalTask = struct {
    saved_rsp: usize,
    stack_base: usize,
    stack_size: usize,
    status: LocalTaskStatus,
    yields: u32,
    iterations: u32,
};

pub const State = struct {
    magic: u64,
    index: u32,
    expected_apic_id: u32,
    kernel_stack_base: usize,
    kernel_stack_size: usize,
    ist_stack_base: usize,
    ist_stack_size: usize,
    gdt: [5]u64 align(16),
    tss: TaskStateSegment align(16),
    idt: [256]IdtEntry align(16),
    active_cs: u16,
    active_tr: u16,
    descriptor_ready: u32,
    work_checksum: u64,
    mailbox_command: u32,
    mailbox_epoch: u32,
    completion_epoch: u32,
    mailbox_reserved: u32,
    work_input: u64,
    work_result: u64,
    run_queue: [run_queue_capacity]RunQueueEntry,
    run_queue_head: u32,
    run_queue_tail: u32,
    run_queue_completed: u32,
    run_queue_last_sequence: u32,
    run_queue_checksum: u64,
    run_queue_stolen: u32,
    steal_quota: u32,
    steal_completed: u32,
    steal_reserved: u32,
    steal_checksum: u64,
    ipi_wake_count: u32,
    idle_halt_count: u32,
    timer_request_epoch: u32,
    timer_armed_epoch: u32,
    timer_interrupt_count: u32,
    timer_error: u32,
    timer_initial_count: u32,
    timer_periodic: u32,
    timer_target_interrupts: u32,
    scheduler_enabled: u32,
    scheduler_target_jobs: u32,
    scheduler_tick_count: u32,
    scheduler_dispatch_count: u32,
    scheduler_reserved: u32,
    task_request_epoch: u32,
    task_completion_epoch: u32,
    task_running: u32,
    task_current: u32,
    task_scheduler_rsp: usize,
    task_context_switches: u64,
    local_tasks: [local_task_count]LocalTask,
    task_trace: [local_task_trace_length]u8,
    task_trace_length: u32,
    task_error: u32,
    sync_request_epoch: u32,
    sync_completion_epoch: u32,
    sync_experiment_address: usize,
    sync_worker_id: u32,
    sync_iterations: u32,
    sync_acquisitions: u32,
    sync_barrier_generation: u32,
    sync_error: u32,
};

pub const Report = struct {
    gdt_address: usize,
    tss_address: usize,
    idt_address: usize,
    active_cs: u16,
    active_tr: u16,
    work_checksum: u64,
    descriptor_ready: bool,
    mailbox_epoch: u32,
    completion_epoch: u32,
    work_input: u64,
    work_result: u64,
    run_queue_head: u32,
    run_queue_tail: u32,
    run_queue_completed: u32,
    run_queue_last_sequence: u32,
    run_queue_checksum: u64,
    run_queue_stolen: u32,
    steal_completed: u32,
    steal_checksum: u64,
    ipi_wake_count: u32,
    idle_halt_count: u32,
    timer_request_epoch: u32,
    timer_armed_epoch: u32,
    timer_interrupt_count: u32,
    timer_error: u32,
    timer_initial_count: u32,
    timer_periodic: u32,
    timer_target_interrupts: u32,
    scheduler_enabled: u32,
    scheduler_target_jobs: u32,
    scheduler_tick_count: u32,
    scheduler_dispatch_count: u32,
    task_request_epoch: u32,
    task_completion_epoch: u32,
    task_context_switches: u64,
    task_first_stack_base: usize,
    task_first_stack_size: usize,
    task_first_yields: u32,
    task_first_iterations: u32,
    task_first_finished: bool,
    task_first_canary_intact: bool,
    task_second_stack_base: usize,
    task_second_stack_size: usize,
    task_second_yields: u32,
    task_second_iterations: u32,
    task_second_finished: bool,
    task_second_canary_intact: bool,
    task_trace: [local_task_trace_length]u8,
    task_trace_length: u32,
    task_error: u32,
    sync_request_epoch: u32,
    sync_completion_epoch: u32,
    sync_worker_id: u32,
    sync_iterations: u32,
    sync_acquisitions: u32,
    sync_barrier_generation: u32,
    sync_error: u32,
};

extern fn zigos_load_gdt(
    pointer: *const DescriptorTablePointer,
    new_code_selector: u16,
    new_data_selector: u16,
    new_tss_selector: u16,
) callconv(cc) void;
extern fn zigos_load_idt(pointer: *const DescriptorTablePointer) callconv(cc) void;
extern fn zigos_read_cs() callconv(cc) u64;
extern fn zigos_read_tr() callconv(cc) u64;
extern fn zigos_exception_stub_address(vector: u8) callconv(cc) usize;
extern fn zigos_isr_spurious() callconv(cc) void;
extern fn zigos_isr_ap_work() callconv(cc) void;
extern fn zigos_isr_ap_timer() callconv(cc) void;
extern fn zigos_isr_external_irq0() callconv(cc) void;
extern fn zigos_isr_ps2_keyboard() callconv(cc) void;
extern fn zigos_isr_nvme() callconv(cc) void;
extern fn zigos_isr_ahci() callconv(cc) void;
extern fn zigos_isr_xhci() callconv(cc) void;
extern fn zigos_isr_e1000e() callconv(cc) void;
extern fn zigos_wait_for_interrupt() callconv(cc) void;
extern fn zigos_memory_fence() callconv(cc) void;
extern fn zigos_cpu_relax() callconv(cc) void;
extern fn zigos_context_switch(old_rsp: *usize, new_rsp: usize) callconv(cc) void;
extern fn zigos_halt_forever() callconv(cc) noreturn;

var states: [64]State align(4096) = undefined;
var run_queue_gate: u32 = 1;
var stealing_enabled: u32 = 0;
var active_state_count: u32 = 0;
var steal_source_index: u32 = 0;
var steal_required_total: u32 = 0;
var stolen_total: u32 = 0;
var interrupt_idle_enabled: u32 = 0;
var interrupt_idle_state_count: u32 = 0;

pub fn prepare(
    index: usize,
    expected_apic_id: u32,
    kernel_stack_base: usize,
    kernel_stack_size: usize,
    ist_stack_base: usize,
    ist_stack_size: usize,
) ?*State {
    if (index >= states.len) return null;
    if (kernel_stack_size == 0 or ist_stack_size == 0) return null;
    const state = &states[index];
    state.* = undefined;
    state.magic = state_magic;
    state.index = @intCast(index);
    state.expected_apic_id = expected_apic_id;
    state.kernel_stack_base = kernel_stack_base;
    state.kernel_stack_size = kernel_stack_size;
    state.ist_stack_base = ist_stack_base;
    state.ist_stack_size = ist_stack_size;
    state.active_cs = 0;
    state.active_tr = 0;
    state.descriptor_ready = 0;
    state.work_checksum = 0;
    state.mailbox_command = 0;
    state.mailbox_epoch = 0;
    state.completion_epoch = 0;
    state.mailbox_reserved = 0;
    state.work_input = 0;
    state.work_result = 0;
    for (&state.run_queue) |*entry| entry.* = std.mem.zeroes(RunQueueEntry);
    state.run_queue_head = 0;
    state.run_queue_tail = 0;
    state.run_queue_completed = 0;
    state.run_queue_last_sequence = 0;
    state.run_queue_checksum = run_queue_checksum_seed;
    state.run_queue_stolen = 0;
    state.steal_quota = 0;
    state.steal_completed = 0;
    state.steal_reserved = 0;
    state.steal_checksum = work_stealing_checksum_seed;
    state.ipi_wake_count = 0;
    state.idle_halt_count = 0;
    state.timer_request_epoch = 0;
    state.timer_armed_epoch = 0;
    state.timer_interrupt_count = 0;
    state.timer_error = 0;
    state.timer_initial_count = 0;
    state.timer_periodic = 0;
    state.timer_target_interrupts = 0;
    state.scheduler_enabled = 0;
    state.scheduler_target_jobs = 0;
    state.scheduler_tick_count = 0;
    state.scheduler_dispatch_count = 0;
    state.scheduler_reserved = 0;
    state.task_request_epoch = 0;
    state.task_completion_epoch = 0;
    state.task_running = 0;
    state.task_current = 0;
    state.task_scheduler_rsp = 0;
    state.task_context_switches = 0;
    for (&state.local_tasks) |*task| task.* = .{
        .saved_rsp = 0,
        .stack_base = 0,
        .stack_size = 0,
        .status = .unused,
        .yields = 0,
        .iterations = 0,
    };
    @memset(&state.task_trace, 0);
    state.task_trace_length = 0;
    state.task_error = 0;
    state.sync_request_epoch = 0;
    state.sync_completion_epoch = 0;
    state.sync_experiment_address = 0;
    state.sync_worker_id = 0;
    state.sync_iterations = 0;
    state.sync_acquisitions = 0;
    state.sync_barrier_generation = 0;
    state.sync_error = 0;
    zigos_memory_fence();
    return state;
}

pub fn initialize(state: *State, actual_apic_id: u32) bool {
    if (state.magic != state_magic or state.expected_apic_id != actual_apic_id) return false;
    if (state.kernel_stack_base > std.math.maxInt(usize) - state.kernel_stack_size) return false;
    if (state.ist_stack_base > std.math.maxInt(usize) - state.ist_stack_size) return false;

    const kernel_stack_top = state.kernel_stack_base + state.kernel_stack_size;
    const ist_stack_top = state.ist_stack_base + state.ist_stack_size;

    state.tss = std.mem.zeroes(TaskStateSegment);
    state.tss.rsp0 = @intCast(kernel_stack_top);
    state.tss.ist1 = @intCast(ist_stack_top);
    state.tss.io_map_base = @intCast(@sizeOf(TaskStateSegment));

    state.gdt[0] = 0;
    state.gdt[1] = 0x00AF_9A00_0000_FFFF;
    state.gdt[2] = 0x00CF_9200_0000_FFFF;
    installTssDescriptor(state);

    const gdt_pointer = DescriptorTablePointer{
        .limit = @intCast(@sizeOf(@TypeOf(state.gdt)) - 1),
        .base = @intCast(@intFromPtr(&state.gdt)),
    };
    zigos_load_gdt(&gdt_pointer, code_selector, data_selector, tss_selector);

    for (&state.idt) |*entry| entry.* = std.mem.zeroes(IdtEntry);
    var vector: usize = 0;
    while (vector < exception_vector_count) : (vector += 1) {
        setInterruptGate(
            &state.idt[vector],
            zigos_exception_stub_address(@intCast(vector)),
            code_selector,
            1,
        );
    }
    setInterruptGate(
        &state.idt[ap_timer_vector],
        @intFromPtr(&zigos_isr_ap_timer),
        code_selector,
        1,
    );
    setInterruptGate(
        &state.idt[ap_work_vector],
        @intFromPtr(&zigos_isr_ap_work),
        code_selector,
        1,
    );
    setInterruptGate(
        &state.idt[external_irq0_vector],
        @intFromPtr(&zigos_isr_external_irq0),
        code_selector,
        1,
    );
    setInterruptGate(
        &state.idt[ps2_keyboard_vector],
        @intFromPtr(&zigos_isr_ps2_keyboard),
        code_selector,
        1,
    );
    setInterruptGate(
        &state.idt[nvme_vector],
        @intFromPtr(&zigos_isr_nvme),
        code_selector,
        1,
    );
    setInterruptGate(
        &state.idt[ahci_vector],
        @intFromPtr(&zigos_isr_ahci),
        code_selector,
        1,
    );
    setInterruptGate(
        &state.idt[xhci_vector],
        @intFromPtr(&zigos_isr_xhci),
        code_selector,
        1,
    );
    setInterruptGate(
        &state.idt[e1000e_vector],
        @intFromPtr(&zigos_isr_e1000e),
        code_selector,
        1,
    );
    setInterruptGate(
        &state.idt[spurious_vector],
        @intFromPtr(&zigos_isr_spurious),
        code_selector,
        0,
    );

    const idt_pointer = DescriptorTablePointer{
        .limit = @intCast(@sizeOf(@TypeOf(state.idt)) - 1),
        .base = @intCast(@intFromPtr(&state.idt)),
    };
    zigos_load_idt(&idt_pointer);

    state.active_cs = @truncate(zigos_read_cs());
    state.active_tr = @truncate(zigos_read_tr());
    if (state.active_cs != code_selector or state.active_tr != tss_selector) return false;
    state.work_checksum = calculateWorkChecksum(actual_apic_id, state.index);
    state.descriptor_ready = 1;
    zigos_memory_fence();
    return true;
}

pub fn report(state: *const State) Report {
    zigos_memory_fence();
    return .{
        .gdt_address = @intFromPtr(&state.gdt),
        .tss_address = @intFromPtr(&state.tss),
        .idt_address = @intFromPtr(&state.idt),
        .active_cs = state.active_cs,
        .active_tr = state.active_tr,
        .work_checksum = state.work_checksum,
        .descriptor_ready = state.descriptor_ready == 1,
        .mailbox_epoch = readVolatileU32(&state.mailbox_epoch),
        .completion_epoch = readVolatileU32(&state.completion_epoch),
        .work_input = readVolatileU64(&state.work_input),
        .work_result = readVolatileU64(&state.work_result),
        .run_queue_head = readVolatileU32(&state.run_queue_head),
        .run_queue_tail = readVolatileU32(&state.run_queue_tail),
        .run_queue_completed = readVolatileU32(&state.run_queue_completed),
        .run_queue_last_sequence = readVolatileU32(&state.run_queue_last_sequence),
        .run_queue_checksum = readVolatileU64(&state.run_queue_checksum),
        .run_queue_stolen = atomicLoadU32(&state.run_queue_stolen),
        .steal_completed = atomicLoadU32(&state.steal_completed),
        .steal_checksum = atomicLoadU64(&state.steal_checksum),
        .ipi_wake_count = atomicLoadU32(&state.ipi_wake_count),
        .idle_halt_count = atomicLoadU32(&state.idle_halt_count),
        .timer_request_epoch = atomicLoadU32(&state.timer_request_epoch),
        .timer_armed_epoch = atomicLoadU32(&state.timer_armed_epoch),
        .timer_interrupt_count = atomicLoadU32(&state.timer_interrupt_count),
        .timer_error = atomicLoadU32(&state.timer_error),
        .timer_initial_count = atomicLoadU32(&state.timer_initial_count),
        .timer_periodic = atomicLoadU32(&state.timer_periodic),
        .timer_target_interrupts = atomicLoadU32(&state.timer_target_interrupts),
        .scheduler_enabled = atomicLoadU32(&state.scheduler_enabled),
        .scheduler_target_jobs = atomicLoadU32(&state.scheduler_target_jobs),
        .scheduler_tick_count = atomicLoadU32(&state.scheduler_tick_count),
        .scheduler_dispatch_count = atomicLoadU32(&state.scheduler_dispatch_count),
        .task_request_epoch = atomicLoadU32(&state.task_request_epoch),
        .task_completion_epoch = atomicLoadU32(&state.task_completion_epoch),
        .task_context_switches = state.task_context_switches,
        .task_first_stack_base = state.local_tasks[0].stack_base,
        .task_first_stack_size = state.local_tasks[0].stack_size,
        .task_first_yields = state.local_tasks[0].yields,
        .task_first_iterations = state.local_tasks[0].iterations,
        .task_first_finished = state.local_tasks[0].status == .finished,
        .task_first_canary_intact = taskCanaryIntact(&state.local_tasks[0]),
        .task_second_stack_base = state.local_tasks[1].stack_base,
        .task_second_stack_size = state.local_tasks[1].stack_size,
        .task_second_yields = state.local_tasks[1].yields,
        .task_second_iterations = state.local_tasks[1].iterations,
        .task_second_finished = state.local_tasks[1].status == .finished,
        .task_second_canary_intact = taskCanaryIntact(&state.local_tasks[1]),
        .task_trace = state.task_trace,
        .task_trace_length = state.task_trace_length,
        .task_error = state.task_error,
        .sync_request_epoch = atomicLoadU32(&state.sync_request_epoch),
        .sync_completion_epoch = atomicLoadU32(&state.sync_completion_epoch),
        .sync_worker_id = state.sync_worker_id,
        .sync_iterations = state.sync_iterations,
        .sync_acquisitions = state.sync_acquisitions,
        .sync_barrier_generation = state.sync_barrier_generation,
        .sync_error = state.sync_error,
    };
}

pub fn dispatchWork(state: *State, epoch: u32, input: u64) bool {
    if (epoch == 0 or state.descriptor_ready != 1) return false;
    writeVolatileU64(&state.work_input, input);
    writeVolatileU32(&state.mailbox_command, 1);
    zigos_memory_fence();
    writeVolatileU32(&state.mailbox_epoch, epoch);
    zigos_memory_fence();
    return true;
}

pub fn workCompleted(state: *State, epoch: u32) bool {
    zigos_memory_fence();
    return readVolatileU32(&state.completion_epoch) == epoch;
}

pub fn expectedWorkResult(apic_id: u32, input: u64) u64 {
    return calculateMailboxWork(apic_id, input);
}

pub fn configureSynchronizationWorker(
    state: *State,
    epoch: u32,
    experiment: *synchronization.Experiment,
    worker_id: u32,
    iterations: u32,
) bool {
    if (epoch == 0 or iterations == 0 or state.descriptor_ready != 1) return false;
    state.sync_experiment_address = @intFromPtr(experiment);
    state.sync_worker_id = worker_id;
    state.sync_iterations = iterations;
    state.sync_acquisitions = 0;
    state.sync_barrier_generation = 0;
    state.sync_error = 0;
    atomicStoreU32(&state.sync_completion_epoch, 0);
    atomicStoreU32(&state.sync_request_epoch, epoch);
    return true;
}

pub fn synchronizationWorkerComplete(state: *const State, epoch: u32) bool {
    return epoch != 0 and
        atomicLoadU32(&state.sync_completion_epoch) == epoch and
        state.sync_error == 0;
}

fn serviceSynchronizationRequest(state: *State) bool {
    const epoch = atomicLoadU32(&state.sync_request_epoch);
    if (epoch == 0 or atomicLoadU32(&state.sync_completion_epoch) == epoch) return false;
    if (state.sync_experiment_address == 0 or state.sync_iterations == 0) {
        state.sync_error = 1;
    } else {
        const experiment: *synchronization.Experiment = @ptrFromInt(state.sync_experiment_address);
        if (synchronization.runWorker(
            experiment,
            state.sync_worker_id,
            state.sync_iterations,
        )) |result| {
            state.sync_acquisitions = result.acquisitions;
            state.sync_barrier_generation = result.final_barrier_generation;
        } else {
            state.sync_error = 2;
        }
    }
    zigos_memory_fence();
    atomicStoreU32(&state.sync_completion_epoch, epoch);
    return true;
}

pub fn prepareLocalTaskExperiment(
    state: *State,
    epoch: u32,
    first_stack_base: usize,
    first_stack_size: usize,
    second_stack_base: usize,
    second_stack_size: usize,
) bool {
    if (epoch == 0 or state.descriptor_ready != 1 or
        first_stack_size == 0 or second_stack_size == 0)
    {
        return false;
    }
    if (!prepareLocalTask(&state.local_tasks[0], first_stack_base, first_stack_size)) return false;
    if (!prepareLocalTask(&state.local_tasks[1], second_stack_base, second_stack_size)) return false;
    state.task_current = 0;
    state.task_scheduler_rsp = 0;
    state.task_context_switches = 0;
    state.task_running = 0;
    state.task_error = 0;
    state.task_trace_length = 0;
    @memset(&state.task_trace, 0);
    atomicStoreU32(&state.task_completion_epoch, 0);
    atomicStoreU32(&state.task_request_epoch, epoch);
    return true;
}

pub fn localTaskExperimentComplete(state: *const State, epoch: u32) bool {
    return epoch != 0 and
        atomicLoadU32(&state.task_completion_epoch) == epoch and
        atomicLoadU32(&state.task_running) == 0 and
        state.task_error == 0;
}

fn prepareLocalTask(task: *LocalTask, stack_base: usize, stack_size: usize) bool {
    if (stack_base > std.math.maxInt(usize) - stack_size) return false;
    const stack = @as([*]u8, @ptrFromInt(stack_base))[0..stack_size];
    @memset(stack, 0);
    @as(*u64, @ptrFromInt(stack_base)).* = task_stack_canary;
    const stack_top = stack_base + stack_size;
    const return_slot = (stack_top - 16) & ~@as(usize, 0xF);
    if (return_slot < stack_base + task_bootstrap_frame_bytes + @sizeOf(usize)) return false;
    const saved_rsp = return_slot - task_bootstrap_frame_bytes;
    @as(*usize, @ptrFromInt(return_slot)).* = @intFromPtr(&localTaskBootstrap);
    task.* = .{
        .saved_rsp = saved_rsp,
        .stack_base = stack_base,
        .stack_size = stack_size,
        .status = .runnable,
        .yields = 0,
        .iterations = 0,
    };
    return true;
}

fn serviceLocalTaskRequest(state: *State) bool {
    const epoch = atomicLoadU32(&state.task_request_epoch);
    if (epoch == 0 or atomicLoadU32(&state.task_completion_epoch) == epoch) return false;
    if (state.task_running != 0) return false;
    if (!runLocalTasks(state)) {
        state.task_error = 1;
    }
    zigos_memory_fence();
    atomicStoreU32(&state.task_completion_epoch, epoch);
    return true;
}

fn runLocalTasks(state: *State) bool {
    if (state.local_tasks[0].status != .runnable or state.local_tasks[1].status != .runnable) return false;
    state.task_current = 0;
    state.local_tasks[0].status = .running;
    state.task_running = 1;
    state.task_context_switches = 1;
    zigos_context_switch(&state.task_scheduler_rsp, state.local_tasks[0].saved_rsp);
    state.task_running = 0;
    return state.local_tasks[0].status == .finished and
        state.local_tasks[1].status == .finished and
        state.task_context_switches == 13 and
        state.task_trace_length == local_task_trace_length and
        taskCanaryIntact(&state.local_tasks[0]) and
        taskCanaryIntact(&state.local_tasks[1]);
}

fn localTaskBootstrap() callconv(cc) noreturn {
    const state = currentState() orelse zigos_halt_forever();
    const index: usize = state.task_current;
    if (index >= local_task_count) zigos_halt_forever();
    if (index == 0) {
        runLocalTaskA(state);
    } else {
        runLocalTaskB(state);
    }
    finishLocalTask(state);
}

fn runLocalTaskA(state: *State) void {
    var iteration: u32 = 0;
    while (iteration < 5) : (iteration += 1) {
        appendTaskTrace(state, 'A');
        state.local_tasks[0].iterations +%= 1;
        yieldLocalTask(state);
    }
}

fn runLocalTaskB(state: *State) void {
    var iteration: u32 = 0;
    while (iteration < 7) : (iteration += 1) {
        appendTaskTrace(state, 'B');
        state.local_tasks[1].iterations +%= 1;
        yieldLocalTask(state);
    }
}

fn appendTaskTrace(state: *State, marker: u8) void {
    const index: usize = state.task_trace_length;
    if (index >= state.task_trace.len) {
        state.task_error = 2;
        return;
    }
    state.task_trace[index] = marker;
    state.task_trace_length +%= 1;
}

fn yieldLocalTask(state: *State) void {
    if (state.task_running == 0) return;
    const old_index: usize = state.task_current;
    if (old_index >= local_task_count) return;
    state.local_tasks[old_index].yields +%= 1;
    const next_index = findNextLocalTask(state, old_index) orelse return;
    state.local_tasks[old_index].status = .runnable;
    state.local_tasks[next_index].status = .running;
    state.task_current = @intCast(next_index);
    state.task_context_switches +%= 1;
    zigos_context_switch(
        &state.local_tasks[old_index].saved_rsp,
        state.local_tasks[next_index].saved_rsp,
    );
}

fn finishLocalTask(state: *State) noreturn {
    const old_index: usize = state.task_current;
    if (old_index >= local_task_count) zigos_halt_forever();
    state.local_tasks[old_index].status = .finished;
    if (findNextLocalTask(state, old_index)) |next_index| {
        state.local_tasks[next_index].status = .running;
        state.task_current = @intCast(next_index);
        state.task_context_switches +%= 1;
        zigos_context_switch(
            &state.local_tasks[old_index].saved_rsp,
            state.local_tasks[next_index].saved_rsp,
        );
        zigos_halt_forever();
    }
    state.task_context_switches +%= 1;
    zigos_context_switch(&state.local_tasks[old_index].saved_rsp, state.task_scheduler_rsp);
    zigos_halt_forever();
}

fn findNextLocalTask(state: *State, old_index: usize) ?usize {
    var offset: usize = 1;
    while (offset < local_task_count) : (offset += 1) {
        const candidate = (old_index + offset) % local_task_count;
        if (state.local_tasks[candidate].status == .runnable) return candidate;
    }
    return null;
}

fn currentState() ?*State {
    const current_apic_id = apic.currentId();
    const count = atomicLoadU32(&interrupt_idle_state_count);
    var index: usize = 0;
    while (index < count and index < states.len) : (index += 1) {
        if (states[index].expected_apic_id == current_apic_id) return &states[index];
    }
    return null;
}

fn taskCanaryIntact(task: *const LocalTask) bool {
    return task.stack_base != 0 and
        @as(*const u64, @ptrFromInt(task.stack_base)).* == task_stack_canary;
}

pub fn requestOneShotTimer(state: *State, epoch: u32, initial_count: u32) bool {
    if (epoch == 0 or initial_count == 0 or state.descriptor_ready != 1) return false;
    atomicStoreU32(&state.timer_interrupt_count, 0);
    atomicStoreU32(&state.timer_error, 0);
    atomicStoreU32(&state.timer_initial_count, initial_count);
    atomicStoreU32(&state.timer_periodic, 0);
    atomicStoreU32(&state.timer_target_interrupts, 1);
    atomicStoreU32(&state.scheduler_enabled, 0);
    atomicStoreU32(&state.scheduler_target_jobs, 0);
    atomicStoreU32(&state.scheduler_tick_count, 0);
    atomicStoreU32(&state.scheduler_dispatch_count, 0);
    atomicStoreU32(&state.timer_armed_epoch, 0);
    atomicStoreU32(&state.timer_request_epoch, epoch);
    return true;
}

pub fn requestTickScheduler(
    state: *State,
    epoch: u32,
    initial_count: u32,
    target_jobs: u32,
) bool {
    if (epoch == 0 or initial_count == 0 or target_jobs == 0 or
        target_jobs > run_queue_capacity or state.descriptor_ready != 1)
    {
        return false;
    }
    if (atomicLoadU32(&state.run_queue_head) != target_jobs or
        atomicLoadU32(&state.run_queue_tail) != 0 or
        atomicLoadU32(&state.run_queue_completed) != 0)
    {
        return false;
    }
    atomicStoreU32(&state.timer_interrupt_count, 0);
    atomicStoreU32(&state.timer_error, 0);
    atomicStoreU32(&state.timer_initial_count, initial_count);
    atomicStoreU32(&state.timer_periodic, 1);
    atomicStoreU32(&state.timer_target_interrupts, target_jobs);
    atomicStoreU32(&state.scheduler_target_jobs, target_jobs);
    atomicStoreU32(&state.scheduler_tick_count, 0);
    atomicStoreU32(&state.scheduler_dispatch_count, 0);
    atomicStoreU32(&state.scheduler_enabled, 1);
    atomicStoreU32(&state.timer_armed_epoch, 0);
    atomicStoreU32(&state.timer_request_epoch, epoch);
    return true;
}

pub fn tickSchedulerComplete(state: *const State, epoch: u32) bool {
    const target = atomicLoadU32(&state.scheduler_target_jobs);
    return target != 0 and
        atomicLoadU32(&state.timer_armed_epoch) == epoch and
        atomicLoadU32(&state.timer_interrupt_count) == target and
        atomicLoadU32(&state.scheduler_tick_count) == target and
        atomicLoadU32(&state.scheduler_dispatch_count) == target and
        atomicLoadU32(&state.run_queue_completed) == target and
        atomicLoadU32(&state.timer_error) == 0;
}

pub fn finishTickScheduler(state: *State) void {
    atomicStoreU32(&state.scheduler_enabled, 0);
    atomicStoreU32(&state.timer_periodic, 0);
    atomicStoreU32(&state.timer_target_interrupts, 0);
}

pub fn timerArmed(state: *const State, epoch: u32) bool {
    return epoch != 0 and atomicLoadU32(&state.timer_armed_epoch) == epoch;
}

pub fn timerFired(state: *const State, epoch: u32) bool {
    return timerArmed(state, epoch) and
        atomicLoadU32(&state.timer_interrupt_count) == 1 and
        atomicLoadU32(&state.timer_error) == 0;
}

export fn zigos_ap_timer_interrupt_handler() callconv(cc) void {
    const current_apic_id = apic.currentId();
    const count = atomicLoadU32(&interrupt_idle_state_count);
    var index: usize = 0;
    while (index < count and index < states.len) : (index += 1) {
        const state = &states[index];
        if (state.expected_apic_id == current_apic_id) {
            const interrupt_count = atomicFetchAddU32(&state.timer_interrupt_count, 1) +% 1;
            if (atomicLoadU32(&state.scheduler_enabled) != 0) {
                atomicStoreU32(&state.scheduler_tick_count, interrupt_count);
                if (interrupt_count >= atomicLoadU32(&state.timer_target_interrupts)) {
                    apic.stopCurrentProcessorTimer(ap_timer_vector);
                }
            } else {
                apic.stopCurrentProcessorTimer(ap_timer_vector);
            }
            break;
        }
    }
    apic.acknowledgeInterrupt();
}

fn serviceTimerRequest(state: *State) bool {
    const request_epoch = atomicLoadU32(&state.timer_request_epoch);
    if (request_epoch == 0 or atomicLoadU32(&state.timer_armed_epoch) == request_epoch) return false;
    const initial_count = atomicLoadU32(&state.timer_initial_count);
    const started = if (atomicLoadU32(&state.timer_periodic) != 0)
        apic.startCurrentProcessorPeriodicTimer(ap_timer_vector, initial_count)
    else
        apic.startCurrentProcessorOneShotTimer(ap_timer_vector, initial_count);
    if (!started) {
        atomicStoreU32(&state.timer_error, 1);
        atomicStoreU32(&state.timer_armed_epoch, request_epoch);
        return true;
    }
    atomicStoreU32(&state.timer_armed_epoch, request_epoch);
    return true;
}

pub fn enableInterruptIdle(state_count: usize) bool {
    if (state_count == 0 or state_count > states.len) return false;
    atomicStoreU32(&interrupt_idle_state_count, @intCast(state_count));
    atomicStoreU32(&interrupt_idle_enabled, 1);
    return true;
}

pub fn interruptIdleReady(state: *const State, minimum_halts: u32) bool {
    return minimum_halts != 0 and atomicLoadU32(&state.idle_halt_count) >= minimum_halts;
}

pub fn interruptWakeObserved(state: *const State, minimum_wakes: u32) bool {
    return minimum_wakes != 0 and atomicLoadU32(&state.ipi_wake_count) >= minimum_wakes;
}

export fn zigos_ap_work_interrupt_handler() callconv(cc) void {
    const current_apic_id = apic.currentId();
    const count = atomicLoadU32(&interrupt_idle_state_count);
    var index: usize = 0;
    while (index < count and index < states.len) : (index += 1) {
        const state = &states[index];
        if (state.expected_apic_id == current_apic_id) {
            _ = atomicFetchAddU32(&state.ipi_wake_count, 1);
            break;
        }
    }
    apic.acknowledgeInterrupt();
}

fn idleWait(state: *State) void {
    if (atomicLoadU32(&interrupt_idle_enabled) != 0) {
        _ = atomicFetchAddU32(&state.idle_halt_count, 1);
        zigos_wait_for_interrupt();
    } else {
        zigos_cpu_relax();
    }
}

pub const WorkStealingReport = struct {
    owner_jobs: u32,
    stolen_jobs: u32,
    executor_mask: u64,
    checksum: u64,
};

pub fn pauseRunQueues() void {
    atomicStoreU32(&run_queue_gate, 0);
}

pub fn resumeRunQueues() void {
    atomicStoreU32(&run_queue_gate, 1);
}

pub fn resetRunQueue(state: *State) bool {
    if (atomicLoadU32(&run_queue_gate) != 0) return false;
    if (atomicLoadU32(&state.run_queue_head) != atomicLoadU32(&state.run_queue_tail)) return false;
    if (atomicLoadU32(&state.run_queue_completed) != atomicLoadU32(&state.run_queue_head)) return false;
    for (&state.run_queue) |*entry| entry.* = std.mem.zeroes(RunQueueEntry);
    atomicStoreU32(&state.run_queue_head, 0);
    atomicStoreU32(&state.run_queue_tail, 0);
    atomicStoreU32(&state.run_queue_completed, 0);
    atomicStoreU32(&state.run_queue_last_sequence, 0);
    atomicStoreU64(&state.run_queue_checksum, run_queue_checksum_seed);
    atomicStoreU32(&state.run_queue_stolen, 0);
    atomicStoreU32(&state.steal_completed, 0);
    atomicStoreU64(&state.steal_checksum, work_stealing_checksum_seed);
    return true;
}

pub fn configureWorkStealing(
    state_count: usize,
    source_index: usize,
    thief_quota: u32,
    required_stolen: u32,
) bool {
    if (atomicLoadU32(&run_queue_gate) != 0) return false;
    if (state_count < 3 or state_count > states.len or source_index >= state_count) return false;
    if (thief_quota == 0 or required_stolen == 0) return false;
    if (required_stolen != thief_quota * @as(u32, @intCast(state_count - 1))) return false;

    var index: usize = 0;
    while (index < state_count) : (index += 1) {
        atomicStoreU32(&states[index].steal_completed, 0);
        atomicStoreU32(
            &states[index].steal_quota,
            if (index == source_index) 0 else thief_quota,
        );
    }
    atomicStoreU32(&active_state_count, @intCast(state_count));
    atomicStoreU32(&steal_source_index, @intCast(source_index));
    atomicStoreU32(&steal_required_total, required_stolen);
    atomicStoreU32(&stolen_total, 0);
    atomicStoreU32(&stealing_enabled, 1);
    return true;
}

pub fn disableWorkStealing() void {
    atomicStoreU32(&stealing_enabled, 0);
    atomicStoreU32(&active_state_count, 0);
    atomicStoreU32(&steal_required_total, 0);
}

pub fn workStealingComplete() bool {
    const required = atomicLoadU32(&steal_required_total);
    return required != 0 and atomicLoadU32(&stolen_total) == required;
}

pub fn stolenJobCount() u32 {
    return atomicLoadU32(&stolen_total);
}

pub fn enqueueRunQueue(state: *State, sequence: u32, input: u64) bool {
    if (sequence == 0 or state.descriptor_ready != 1) return false;
    const head = readVolatileU32(&state.run_queue_head);
    const tail = readVolatileU32(&state.run_queue_tail);
    if (head -% tail >= @as(u32, @intCast(run_queue_capacity))) return false;

    const entry = &state.run_queue[queueIndex(head)];
    atomicStoreU32(&entry.completed, 0);
    writeVolatileU64(&entry.result, 0);
    entry.executor_apic_id = 0;
    entry.stolen = 0;
    entry.executor_state_index = 0;
    entry.sequence = sequence;
    entry.command = run_queue_command;
    entry.input = input;
    zigos_memory_fence();
    writeVolatileU32(&state.run_queue_head, head +% 1);
    zigos_memory_fence();
    return true;
}

pub fn runQueueCompleted(state: *State, expected_jobs: u32) bool {
    zigos_memory_fence();
    return readVolatileU32(&state.run_queue_completed) == expected_jobs;
}

pub fn expectedRunQueueResult(apic_id: u32, sequence: u32, input: u64) u64 {
    return calculateRunQueueWork(apic_id, sequence, input);
}

pub fn verifyRunQueue(state: *State, apic_id: u32, expected_jobs: u32) ?u64 {
    if (expected_jobs == 0 or expected_jobs > run_queue_capacity) return null;
    zigos_memory_fence();
    if (readVolatileU32(&state.run_queue_head) != expected_jobs or
        readVolatileU32(&state.run_queue_tail) != expected_jobs or
        readVolatileU32(&state.run_queue_completed) != expected_jobs or
        readVolatileU32(&state.run_queue_last_sequence) != expected_jobs)
    {
        return null;
    }

    var checksum = run_queue_checksum_seed;
    var index: u32 = 0;
    while (index < expected_jobs) : (index += 1) {
        const entry = &state.run_queue[queueIndex(index)];
        const sequence = index + 1;
        if (readVolatileU32(&entry.completed) != 1 or
            entry.sequence != sequence or
            entry.command != run_queue_command)
        {
            return null;
        }
        const expected = calculateRunQueueWork(apic_id, sequence, entry.input);
        const result = readVolatileU64(&entry.result);
        if (result != expected) return null;
        checksum = accumulateRunQueueChecksum(checksum, sequence, result);
    }
    if (readVolatileU64(&state.run_queue_checksum) != checksum) return null;
    return checksum;
}

pub fn runMailbox(state: *State) noreturn {
    var observed_epoch: u32 = 0;
    while (true) {
        if (serviceSynchronizationRequest(state)) continue;
        if (serviceLocalTaskRequest(state)) continue;
        if (serviceTimerRequest(state)) continue;
        if (atomicLoadU32(&run_queue_gate) != 0) {
            if (atomicLoadU32(&state.scheduler_enabled) != 0) {
                if (tickSchedulerStep(state)) continue;
            } else if (atomicLoadU32(&stealing_enabled) != 0) {
                if (workStealingStep(state)) continue;
            } else if (runQueueStep(state, state, false)) {
                continue;
            }
        }
        const epoch = readVolatileU32(&state.mailbox_epoch);
        if (epoch == 0 or epoch == observed_epoch) {
            idleWait(state);
            continue;
        }
        observed_epoch = epoch;
        const command = readVolatileU32(&state.mailbox_command);
        if (command == 1) {
            const input = readVolatileU64(&state.work_input);
            const result = calculateMailboxWork(state.expected_apic_id, input);
            writeVolatileU64(&state.work_result, result);
            zigos_memory_fence();
            writeVolatileU32(&state.completion_epoch, epoch);
            zigos_memory_fence();
        }
    }
}

fn tickSchedulerStep(state: *State) bool {
    const target = atomicLoadU32(&state.scheduler_target_jobs);
    const dispatched = atomicLoadU32(&state.scheduler_dispatch_count);
    const ticks = atomicLoadU32(&state.scheduler_tick_count);
    if (target == 0 or dispatched >= target or dispatched >= ticks) return false;
    if (!runQueueStep(state, state, false)) return false;
    _ = atomicFetchAddU32(&state.scheduler_dispatch_count, 1);
    return true;
}

fn workStealingStep(executor: *State) bool {
    const count = atomicLoadU32(&active_state_count);
    const source_index = atomicLoadU32(&steal_source_index);
    if (count == 0 or source_index >= count) return false;
    const source = &states[source_index];

    if (executor.index == source_index) {
        if (atomicLoadU32(&stolen_total) < atomicLoadU32(&steal_required_total)) return false;
        return runQueueStep(source, executor, false);
    }

    const quota = atomicLoadU32(&executor.steal_quota);
    if (quota == 0 or atomicLoadU32(&executor.steal_completed) >= quota) return false;
    return runQueueStep(source, executor, true);
}

fn runQueueStep(victim: *State, executor: *State, stealing: bool) bool {
    const tail = atomicLoadU32(&victim.run_queue_tail);
    const head = atomicLoadU32(&victim.run_queue_head);
    if (tail == head) return false;
    if (!atomicClaimU32(&victim.run_queue_tail, tail, tail +% 1)) return false;

    const entry = &victim.run_queue[queueIndex(tail)];
    const sequence = entry.sequence;
    if (sequence == 0 or entry.command != run_queue_command) return false;
    const executor_apic_id = executor.expected_apic_id;
    const was_stolen = stealing and executor != victim;
    const result = calculateRunQueueWork(executor_apic_id, sequence, entry.input);
    entry.executor_apic_id = executor_apic_id;
    entry.stolen = @intFromBool(was_stolen);
    entry.executor_state_index = executor.index;
    writeVolatileU64(&entry.result, result);

    if (atomicLoadU32(&stealing_enabled) == 0) {
        const checksum = accumulateRunQueueChecksum(
            readVolatileU64(&victim.run_queue_checksum),
            sequence,
            result,
        );
        writeVolatileU64(&victim.run_queue_checksum, checksum);
        writeVolatileU32(&victim.run_queue_last_sequence, sequence);
    } else {
        _ = atomicFetchXorU64(
            &victim.steal_checksum,
            workStealingToken(sequence, executor_apic_id, result),
        );
        if (was_stolen) {
            _ = atomicFetchAddU32(&victim.run_queue_stolen, 1);
            _ = atomicFetchAddU32(&executor.steal_completed, 1);
            _ = atomicFetchAddU32(&stolen_total, 1);
        }
    }

    atomicStoreU32(&entry.completed, 1);
    _ = atomicFetchAddU32(&victim.run_queue_completed, 1);
    return true;
}

pub fn verifyWorkStealing(
    source: *State,
    expected_jobs: u32,
    expected_owner_jobs: u32,
    expected_stolen_jobs: u32,
) ?WorkStealingReport {
    if (expected_jobs == 0 or expected_jobs > run_queue_capacity) return null;
    if (expected_owner_jobs + expected_stolen_jobs != expected_jobs) return null;
    if (atomicLoadU32(&source.run_queue_head) != expected_jobs or
        atomicLoadU32(&source.run_queue_tail) != expected_jobs or
        atomicLoadU32(&source.run_queue_completed) != expected_jobs or
        atomicLoadU32(&source.run_queue_stolen) != expected_stolen_jobs)
    {
        return null;
    }

    var owner_jobs: u32 = 0;
    var stolen_jobs: u32 = 0;
    var executor_mask: u64 = 0;
    var checksum = work_stealing_checksum_seed;
    var index: u32 = 0;
    while (index < expected_jobs) : (index += 1) {
        const entry = &source.run_queue[queueIndex(index)];
        const sequence = index + 1;
        const executor_index: usize = @intCast(entry.executor_state_index);
        const state_count: usize = @intCast(atomicLoadU32(&active_state_count));
        if (atomicLoadU32(&entry.completed) != 1 or
            entry.sequence != sequence or
            entry.command != run_queue_command or
            executor_index >= state_count or
            states[executor_index].expected_apic_id != entry.executor_apic_id)
        {
            return null;
        }
        const was_stolen = entry.executor_apic_id != source.expected_apic_id;
        if (entry.stolen != @intFromBool(was_stolen)) return null;
        if (was_stolen) {
            stolen_jobs += 1;
        } else {
            owner_jobs += 1;
        }
        const result = readVolatileU64(&entry.result);
        const expected = calculateRunQueueWork(entry.executor_apic_id, sequence, entry.input);
        if (result != expected) return null;
        executor_mask |= @as(u64, 1) << @intCast(executor_index);
        checksum ^= workStealingToken(sequence, entry.executor_apic_id, result);
    }
    if (owner_jobs != expected_owner_jobs or stolen_jobs != expected_stolen_jobs) return null;
    if (atomicLoadU64(&source.steal_checksum) != checksum) return null;
    return .{
        .owner_jobs = owner_jobs,
        .stolen_jobs = stolen_jobs,
        .executor_mask = executor_mask,
        .checksum = checksum,
    };
}

fn workStealingToken(sequence: u32, executor_apic_id: u32, result: u64) u64 {
    var value = result ^
        (@as(u64, sequence) *% 0x9E37_79B9_7F4A_7C15) ^
        (@as(u64, executor_apic_id) *% 0xD6E8_FEB8_6659_FD93);
    value = std.math.rotl(u64, value, 23);
    value *%= 0xA076_1D64_78BD_642F;
    return value;
}

fn calculateRunQueueWork(apic_id: u32, sequence: u32, input: u64) u64 {
    var value = input ^
        (@as(u64, apic_id) *% 0xD6E8_FEB8_6659_FD93) ^
        (@as(u64, sequence) *% 0x9E37_79B9_7F4A_7C15);
    var iteration: u64 = 0;
    while (iteration < 250_000) : (iteration += 1) {
        value +%= iteration ^ 0xA076_1D64_78BD_642F;
        value = std.math.rotl(u64, value, 19);
        value *%= 0xE703_7ED1_A0B4_28DB;
        value ^= value >> 29;
    }
    return value;
}

fn accumulateRunQueueChecksum(current: u64, sequence: u32, result: u64) u64 {
    var value = current ^ result ^ (@as(u64, sequence) *% 0x1000_0000_01B3);
    value = std.math.rotl(u64, value, 11);
    value *%= 0x9E37_79B1_85EB_CA87;
    return value;
}

fn queueIndex(counter: u32) usize {
    return @intCast(counter % @as(u32, @intCast(run_queue_capacity)));
}

fn calculateMailboxWork(apic_id: u32, input: u64) u64 {
    var value = input ^ (@as(u64, apic_id) *% 0x9E37_79B9_7F4A_7C15);
    var iteration: u64 = 0;
    while (iteration < 1_000_000) : (iteration += 1) {
        value = std.math.rotl(u64, value +% iteration +% 0xA076_1D64_78BD_642F, 17);
        value ^= value >> 23;
        value *%= 0xE703_7ED1_A0B4_28DB;
    }
    return value;
}

fn atomicLoadU32(value: *const u32) u32 {
    return @atomicLoad(u32, value, .acquire);
}

fn atomicStoreU32(value: *u32, data: u32) void {
    @atomicStore(u32, value, data, .release);
}

fn atomicLoadU64(value: *const u64) u64 {
    return @atomicLoad(u64, value, .acquire);
}

fn atomicStoreU64(value: *u64, data: u64) void {
    @atomicStore(u64, value, data, .release);
}

fn atomicFetchAddU32(value: *u32, amount: u32) u32 {
    return @atomicRmw(u32, value, .Add, amount, .acq_rel);
}

fn atomicFetchXorU64(value: *u64, operand: u64) u64 {
    return @atomicRmw(u64, value, .Xor, operand, .acq_rel);
}

fn atomicClaimU32(value: *u32, expected: u32, desired: u32) bool {
    return @cmpxchgStrong(u32, value, expected, desired, .acq_rel, .acquire) == null;
}

fn readVolatileU32(value: *const u32) u32 {
    const pointer: *const volatile u32 = @ptrCast(value);
    return pointer.*;
}

fn writeVolatileU32(value: *u32, data: u32) void {
    const pointer: *volatile u32 = @ptrCast(value);
    pointer.* = data;
}

fn readVolatileU64(value: *const u64) u64 {
    const pointer: *const volatile u64 = @ptrCast(value);
    return pointer.*;
}

fn writeVolatileU64(value: *u64, data: u64) void {
    const pointer: *volatile u64 = @ptrCast(value);
    pointer.* = data;
}

fn installTssDescriptor(state: *State) void {
    const base: u64 = @intCast(@intFromPtr(&state.tss));
    const limit: u64 = @sizeOf(TaskStateSegment) - 1;
    state.gdt[3] = (limit & 0xFFFF) |
        ((base & 0xFF_FFFF) << 16) |
        (@as(u64, 0x89) << 40) |
        (((limit >> 16) & 0xF) << 48) |
        (((base >> 24) & 0xFF) << 56);
    state.gdt[4] = base >> 32;
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

fn calculateWorkChecksum(apic_id: u32, index: u32) u64 {
    var value = 0x9E37_79B9_7F4A_7C15 ^ @as(u64, apic_id) ^ (@as(u64, index) << 32);
    var iteration: u64 = 0;
    while (iteration < 100_000) : (iteration += 1) {
        value = std.math.rotl(u64, value ^ iteration, 13);
        value *%= 0xD6E8_FEB8_6659_FD93;
        value +%= 0xA5A5_A5A5_A5A5_A5A5;
    }
    return value;
}

comptime {
    if (@sizeOf(DescriptorTablePointer) != 10) @compileError("descriptor-table pointer must be 10 bytes");
    if (@sizeOf(TaskStateSegment) != 104) @compileError("x86-64 TSS must be 104 bytes");
    if (@sizeOf(IdtEntry) != 16) @compileError("x86-64 IDT entry must be 16 bytes");
    if (task_bootstrap_frame_bytes != 224) {
        @compileError("local task bootstrap frame must match zigos_context_switch");
    }
    _ = interrupt_context;
}
