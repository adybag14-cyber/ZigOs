const std = @import("std");
const acpi = @import("acpi.zig");
const apic = @import("apic.zig");
const boot = @import("boot_info.zig");
const time_reference = @import("time_reference.zig");
const memory = @import("memory.zig");
const paging = @import("paging.zig");
const percpu = @import("percpu.zig");
const synchronization = @import("synchronization.zig");

const cc = std.os.uefi.cc;
const trampoline_image = @embedFile("generated/ap_trampoline.bin");

const boot_data_offset: usize = 0x10;
const gdt_descriptor_base_offset: usize = 0x4A;
const protected_mode_pointer_offset: usize = 0x4E;
const long_mode_pointer_offset: usize = 0x54;
const gdt_offset: usize = 0x300;
const code32_descriptor_offset: usize = gdt_offset + 8;
const stack_pages: usize = 4;
const local_task_stack_pages: usize = 4;
const boot_signature: u64 = 0x5A49_474F_5341_5031;
const initial_actual_apic_id: u32 = 0xFFFF_FFFF;
const startup_timeout_iterations: usize = 2000;
const startup_poll_nanoseconds: u64 = 100_000;
const maximum_active_application_processors: usize = 3;

const ApBootData = extern struct {
    signature: u64,
    cr3: u64,
    stack_top: u64,
    entry_point: u64,
    expected_apic_id: u32,
    actual_apic_id: u32,
    online: u32,
    state: u32,
    per_cpu_state: u64,
};

pub const ApReport = struct {
    expected_apic_id: u32,
    actual_apic_id: u32,
    stack_base: usize,
    stack_size: usize,
    ist_stack_base: usize,
    ist_stack_size: usize,
    gdt_address: usize,
    tss_address: usize,
    idt_address: usize,
    active_cs: u16,
    active_tr: u16,
    work_checksum: u64,
    mailbox_epoch: u32,
    completion_epoch: u32,
    work_input: u64,
    work_result: u64,
    run_queue_jobs: u32,
    run_queue_completed: u32,
    run_queue_last_sequence: u32,
    run_queue_checksum: u64,
    stolen_jobs_executed: u32,
    ipi_wake_count: u32,
    idle_halt_count: u32,
    ipi_job_checksum: u64,
    timer_initial_count: u32,
    timer_interrupt_count: u32,
    timer_armed_epoch: u32,
    timer_halt_count: u32,
    scheduler_jobs: u32,
    scheduler_ticks: u32,
    scheduler_dispatches: u32,
    scheduler_checksum: u64,
    scheduler_halt_count: u32,
    local_task_first_stack: usize,
    local_task_second_stack: usize,
    local_task_stack_size: usize,
    local_task_first_yields: u32,
    local_task_second_yields: u32,
    local_task_context_switches: u64,
    local_task_trace: [12]u8,
    local_task_trace_length: u32,
    local_task_canaries_intact: bool,
    sync_worker_id: u32,
    sync_iterations: u32,
    sync_acquisitions: u32,
    sync_barrier_generation: u32,
    online: bool,
    state: u32,
    per_cpu_state: u64,
};

pub const Report = struct {
    bsp_apic_id: u32,
    madt_processor_count: u32,
    discovered_application_processors: usize,
    parked_application_processors: usize,
    target_count: usize,
    online_count: usize,
    startup_vector: u8,
    trampoline_base: usize,
    trampoline_size: usize,
    work_stealing_source_apic: u32,
    work_stealing_jobs: u32,
    work_stealing_owner_jobs: u32,
    work_stealing_stolen_jobs: u32,
    work_stealing_checksum: u64,
    ipi_wake_vector: u8,
    ipi_wake_targets: u32,
    ipi_wake_completed: u32,
    ap_timer_vector: u8,
    ap_timer_targets: u32,
    ap_timer_completed: u32,
    ap_timer_initial_count: u32,
    ap_scheduler_targets: u32,
    ap_scheduler_completed: u32,
    ap_scheduler_jobs_per_core: u32,
    ap_scheduler_quantum_count: u32,
    ap_task_targets: u32,
    ap_task_completed: u32,
    ap_task_context_switches: u64,
    sync_participants: u32,
    sync_iterations_per_participant: u32,
    sync_total_increments: u64,
    sync_lock_next: u32,
    sync_lock_serving: u32,
    sync_barrier_generation: u32,
    sync_checksum: u64,
    processors: [acpi.maximum_processors]ApReport,
};

extern fn zigos_memory_fence() callconv(cc) void;
extern fn zigos_debug_putc(character: u8) callconv(cc) void;
extern fn zigos_halt_forever() callconv(cc) noreturn;

pub fn start(
    boot_info: *const boot.BootInfo,
    allocator: *memory.FrameAllocator,
    madt: acpi.MadtInfo,
    local_apic: apic.Information,
    reference: time_reference.Reference,
    timer_ticks_per_second: u64,
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
        .discovered_application_processors = 0,
        .parked_application_processors = 0,
        .target_count = 0,
        .online_count = 0,
        .startup_vector = startup_vector,
        .trampoline_base = boot_info.ap_trampoline.base,
        .trampoline_size = boot_info.ap_trampoline.size,
        .work_stealing_source_apic = 0,
        .work_stealing_jobs = 0,
        .work_stealing_owner_jobs = 0,
        .work_stealing_stolen_jobs = 0,
        .work_stealing_checksum = 0,
        .ipi_wake_vector = percpu.ap_work_vector,
        .ipi_wake_targets = 0,
        .ipi_wake_completed = 0,
        .ap_timer_vector = percpu.ap_timer_vector,
        .ap_timer_targets = 0,
        .ap_timer_completed = 0,
        .ap_timer_initial_count = 0,
        .ap_scheduler_targets = 0,
        .ap_scheduler_completed = 0,
        .ap_scheduler_jobs_per_core = 0,
        .ap_scheduler_quantum_count = 0,
        .ap_task_targets = 0,
        .ap_task_completed = 0,
        .ap_task_context_switches = 0,
        .sync_participants = 0,
        .sync_iterations_per_participant = 0,
        .sync_total_increments = 0,
        .sync_lock_next = 0,
        .sync_lock_serving = 0,
        .sync_barrier_generation = 0,
        .sync_checksum = 0,
        .processors = undefined,
    };

    for (madt.processors[0..madt.stored_processor_count]) |processor| {
        if (processor.apic_id == local_apic.apic_id) continue;
        report.discovered_application_processors += 1;
        if (report.target_count >= maximum_active_application_processors) {
            report.parked_application_processors += 1;
            continue;
        }
        if (report.target_count >= report.processors.len) return null;

        const stack_base = allocator.allocateContiguousBelow(stack_pages, memory.four_gib) orelse return null;
        const stack_size = stack_pages * @as(usize, @intCast(memory.page_size));
        const stack_top = stack_base + stack_size;
        const stack = @as([*]u8, @ptrFromInt(stack_base))[0..stack_size];
        @memset(stack, 0);

        const ist_stack_base = allocator.allocateContiguousBelow(stack_pages, memory.four_gib) orelse return null;
        const ist_stack_size = stack_pages * @as(usize, @intCast(memory.page_size));
        const ist_stack = @as([*]u8, @ptrFromInt(ist_stack_base))[0..ist_stack_size];
        @memset(ist_stack, 0);
        const per_cpu_state = percpu.prepare(
            report.target_count,
            processor.apic_id,
            stack_base,
            stack_size,
            ist_stack_base,
            ist_stack_size,
        ) orelse return null;

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
            .per_cpu_state = @intFromPtr(per_cpu_state),
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
        const per_cpu_report = percpu.report(per_cpu_state);
        if (!per_cpu_report.descriptor_ready or
            per_cpu_report.active_cs != 0x08 or
            per_cpu_report.active_tr != 0x18 or
            per_cpu_report.work_checksum == 0)
        {
            debugWrite("SMP per-CPU descriptor verification failed\r\n");
            return null;
        }

        report.processors[report.target_count] = .{
            .expected_apic_id = processor.apic_id,
            .actual_apic_id = actual_apic_id,
            .stack_base = stack_base,
            .stack_size = stack_size,
            .ist_stack_base = ist_stack_base,
            .ist_stack_size = ist_stack_size,
            .gdt_address = per_cpu_report.gdt_address,
            .tss_address = per_cpu_report.tss_address,
            .idt_address = per_cpu_report.idt_address,
            .active_cs = per_cpu_report.active_cs,
            .active_tr = per_cpu_report.active_tr,
            .work_checksum = per_cpu_report.work_checksum,
            .mailbox_epoch = 0,
            .completion_epoch = 0,
            .work_input = 0,
            .work_result = 0,
            .run_queue_jobs = 0,
            .run_queue_completed = 0,
            .run_queue_last_sequence = 0,
            .run_queue_checksum = 0,
            .stolen_jobs_executed = 0,
            .ipi_wake_count = 0,
            .idle_halt_count = 0,
            .ipi_job_checksum = 0,
            .timer_initial_count = 0,
            .timer_interrupt_count = 0,
            .timer_armed_epoch = 0,
            .timer_halt_count = 0,
            .scheduler_jobs = 0,
            .scheduler_ticks = 0,
            .scheduler_dispatches = 0,
            .scheduler_checksum = 0,
            .scheduler_halt_count = 0,
            .local_task_first_stack = 0,
            .local_task_second_stack = 0,
            .local_task_stack_size = 0,
            .local_task_first_yields = 0,
            .local_task_second_yields = 0,
            .local_task_context_switches = 0,
            .local_task_trace = std.mem.zeroes([12]u8),
            .local_task_trace_length = 0,
            .local_task_canaries_intact = false,
            .sync_worker_id = 0,
            .sync_iterations = 0,
            .sync_acquisitions = 0,
            .sync_barrier_generation = 0,
            .online = online,
            .state = state,
            .per_cpu_state = @intFromPtr(per_cpu_state),
        };
        report.target_count += 1;
        report.online_count += 1;
    }

    if (report.target_count != @min(report.discovered_application_processors, maximum_active_application_processors) or
        report.parked_application_processors + report.target_count != report.discovered_application_processors)
    {
        return null;
    }
    if (report.target_count == 0) return report;
    if (!runMailboxRound(&report, reference)) {
        debugWrite("SMP stage failure: mailbox\r\n");
        return null;
    }
    if (!runQueueRound(&report, reference)) {
        debugWrite("SMP stage failure: FIFO\r\n");
        return null;
    }
    if (report.target_count == 3 and !runWorkStealingRound(&report, reference)) {
        debugWrite("SMP stage failure: stealing\r\n");
        return null;
    }
    if (!runTargetedIpiRound(&report, reference)) {
        debugWrite("SMP stage failure: targeted IPI\r\n");
        return null;
    }
    if (!runPerApTimerRound(&report, reference, timer_ticks_per_second)) {
        debugWrite("SMP stage failure: per-AP timer\r\n");
        return null;
    }
    if (!runTickSchedulerRound(&report, reference, timer_ticks_per_second)) {
        debugWrite("SMP stage failure: tick scheduler\r\n");
        return null;
    }
    if (!runLocalTaskRound(&report, allocator, reference)) {
        debugWrite("SMP stage failure: local task contexts\r\n");
        return null;
    }
    if (!runSynchronizationRound(&report, reference)) {
        debugWrite("SMP stage failure: synchronization\r\n");
        return null;
    }
    return report;
}

export fn zigos_ap_entry(data: *volatile ApBootData, per_cpu_state: *percpu.State) callconv(cc) noreturn {
    const actual_apic_id = apic.currentId();
    data.actual_apic_id = actual_apic_id;
    const valid_boot = data.signature == boot_signature and
        data.per_cpu_state == @intFromPtr(per_cpu_state) and
        actual_apic_id == data.expected_apic_id;
    const descriptors_ready = valid_boot and percpu.initialize(per_cpu_state, actual_apic_id);
    data.state = if (descriptors_ready) 2 else 0xDEAD;
    zigos_memory_fence();
    data.online = 1;
    zigos_memory_fence();
    percpu.runMailbox(per_cpu_state);
}

fn runMailboxRound(report: *Report, reference: time_reference.Reference) bool {
    const epoch: u32 = 1;
    const base_input: u64 = 0xC001_D00D_5A49_474F;

    for (report.processors[0..report.target_count], 0..) |*processor, index| {
        const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
        const input = base_input ^
            (@as(u64, processor.actual_apic_id) << 32) ^
            @as(u64, @intCast(index));
        if (!percpu.dispatchWork(state, epoch, input)) return false;
        processor.mailbox_epoch = epoch;
        processor.work_input = input;
    }

    var iteration: usize = 0;
    while (iteration < startup_timeout_iterations) : (iteration += 1) {
        var completed: usize = 0;
        for (report.processors[0..report.target_count]) |processor| {
            const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
            if (percpu.workCompleted(state, epoch)) completed += 1;
        }
        if (completed == report.target_count) break;
        if (!reference.waitNanoseconds(startup_poll_nanoseconds)) return false;
    }

    var distinct_result: u64 = 0;
    for (report.processors[0..report.target_count], 0..) |*processor, index| {
        const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
        const state_report = percpu.report(state);
        const expected = percpu.expectedWorkResult(processor.actual_apic_id, processor.work_input);
        if (state_report.mailbox_epoch != epoch or
            state_report.completion_epoch != epoch or
            state_report.work_input != processor.work_input or
            state_report.work_result != expected)
        {
            return false;
        }
        if (index != 0 and state_report.work_result == distinct_result) return false;
        distinct_result = state_report.work_result;
        processor.completion_epoch = state_report.completion_epoch;
        processor.work_result = state_report.work_result;
    }
    return true;
}

fn runQueueRound(report: *Report, reference: time_reference.Reference) bool {
    const jobs_per_ap: u32 = 4;
    const base_input: u64 = 0x5155_4555_455F_4A4F;

    for (report.processors[0..report.target_count]) |*processor| {
        const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
        var sequence: u32 = 1;
        while (sequence <= jobs_per_ap) : (sequence += 1) {
            const input = base_input ^
                (@as(u64, processor.actual_apic_id) << 40) ^
                (@as(u64, sequence) *% 0x0101_0101_0101_0101);
            if (!percpu.enqueueRunQueue(state, sequence, input)) return false;
        }
        processor.run_queue_jobs = jobs_per_ap;
    }

    var iteration: usize = 0;
    while (iteration < startup_timeout_iterations) : (iteration += 1) {
        var completed: usize = 0;
        for (report.processors[0..report.target_count]) |processor| {
            const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
            if (percpu.runQueueCompleted(state, jobs_per_ap)) completed += 1;
        }
        if (completed == report.target_count) break;
        if (!reference.waitNanoseconds(startup_poll_nanoseconds)) return false;
    }

    var prior_checksum: u64 = 0;
    for (report.processors[0..report.target_count], 0..) |*processor, index| {
        const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
        const checksum = percpu.verifyRunQueue(
            state,
            processor.actual_apic_id,
            jobs_per_ap,
        ) orelse return false;
        if (index != 0 and checksum == prior_checksum) return false;
        prior_checksum = checksum;
        const state_report = percpu.report(state);
        processor.run_queue_completed = state_report.run_queue_completed;
        processor.run_queue_last_sequence = state_report.run_queue_last_sequence;
        processor.run_queue_checksum = checksum;
    }
    return true;
}

fn runWorkStealingRound(report: *Report, reference: time_reference.Reference) bool {
    const source_index: usize = 0;
    const jobs: u32 = 8;
    const thief_quota: u32 = 2;
    const expected_stolen: u32 = 4;
    const expected_owner: u32 = jobs - expected_stolen;
    const base_input: u64 = 0x5354_4541_4C5F_4A4F;
    if (report.target_count != 3) return false;

    percpu.pauseRunQueues();
    for (report.processors[0..report.target_count]) |processor| {
        const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
        if (!percpu.resetRunQueue(state)) return false;
    }

    const source_processor = &report.processors[source_index];
    const source_state: *percpu.State = @ptrFromInt(source_processor.per_cpu_state);
    var sequence: u32 = 1;
    while (sequence <= jobs) : (sequence += 1) {
        const input = base_input ^ (@as(u64, sequence) *% 0x0101_0101_0101_0101);
        if (!percpu.enqueueRunQueue(source_state, sequence, input)) return false;
    }
    if (!percpu.configureWorkStealing(
        report.target_count,
        source_index,
        thief_quota,
        expected_stolen,
    )) return false;
    percpu.resumeRunQueues();

    var iteration: usize = 0;
    while (iteration < startup_timeout_iterations) : (iteration += 1) {
        if (percpu.runQueueCompleted(source_state, jobs) and percpu.workStealingComplete()) break;
        if (!reference.waitNanoseconds(startup_poll_nanoseconds)) return false;
    }

    percpu.pauseRunQueues();
    const verification = percpu.verifyWorkStealing(
        source_state,
        jobs,
        expected_owner,
        expected_stolen,
    ) orelse return false;
    if (percpu.stolenJobCount() != expected_stolen) return false;

    var expected_mask: u64 = 0;
    for (report.processors[0..report.target_count], 0..) |*processor, index| {
        const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
        const state_report = percpu.report(state);
        const expected = if (index == source_index) 0 else thief_quota;
        if (state_report.steal_completed != expected) return false;
        processor.stolen_jobs_executed = state_report.steal_completed;
        if (processor.actual_apic_id >= 64) return false;
        expected_mask |= @as(u64, 1) << @intCast(processor.actual_apic_id);
    }
    if (verification.executor_mask != expected_mask) return false;

    report.work_stealing_source_apic = source_processor.actual_apic_id;
    report.work_stealing_jobs = jobs;
    report.work_stealing_owner_jobs = verification.owner_jobs;
    report.work_stealing_stolen_jobs = verification.stolen_jobs;
    report.work_stealing_checksum = verification.checksum;
    percpu.disableWorkStealing();
    percpu.resumeRunQueues();
    return true;
}

fn runTargetedIpiRound(report: *Report, reference: time_reference.Reference) bool {
    const sequence: u32 = 1;
    const base_input: u64 = 0x4950_495F_484C_545F;
    percpu.pauseRunQueues();
    for (report.processors[0..report.target_count]) |processor| {
        const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
        if (!percpu.resetRunQueue(state)) return false;
    }
    if (!percpu.enableInterruptIdle(report.target_count)) return false;
    percpu.resumeRunQueues();

    var iteration: usize = 0;
    while (iteration < startup_timeout_iterations) : (iteration += 1) {
        var halted: usize = 0;
        for (report.processors[0..report.target_count]) |processor| {
            const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
            if (percpu.interruptIdleReady(state, 1)) halted += 1;
        }
        if (halted == report.target_count) break;
        if (!reference.waitNanoseconds(startup_poll_nanoseconds)) return false;
    }

    for (report.processors[0..report.target_count]) |processor| {
        const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
        const input = base_input ^ (@as(u64, processor.actual_apic_id) << 32);
        if (!percpu.enqueueRunQueue(state, sequence, input)) return false;
        if (!apic.sendFixedIpi(processor.actual_apic_id, percpu.ap_work_vector)) return false;
    }

    iteration = 0;
    while (iteration < startup_timeout_iterations) : (iteration += 1) {
        var completed: usize = 0;
        for (report.processors[0..report.target_count]) |processor| {
            const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
            if (percpu.runQueueCompleted(state, 1) and
                percpu.interruptWakeObserved(state, 1) and
                percpu.interruptIdleReady(state, 2))
            {
                completed += 1;
            }
        }
        if (completed == report.target_count) break;
        if (!reference.waitNanoseconds(startup_poll_nanoseconds)) return false;
    }

    percpu.pauseRunQueues();
    var wake_completed: u32 = 0;
    for (report.processors[0..report.target_count]) |*processor| {
        const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
        const checksum = percpu.verifyRunQueue(state, processor.actual_apic_id, 1) orelse return false;
        const state_report = percpu.report(state);
        if (state_report.ipi_wake_count != 1 or state_report.idle_halt_count < 2) return false;
        processor.ipi_wake_count = state_report.ipi_wake_count;
        processor.idle_halt_count = state_report.idle_halt_count;
        processor.ipi_job_checksum = checksum;
        wake_completed += 1;
    }
    report.ipi_wake_targets = @intCast(report.target_count);
    report.ipi_wake_completed = wake_completed;
    percpu.resumeRunQueues();
    return wake_completed == report.target_count;
}

fn runPerApTimerRound(report: *Report, reference: time_reference.Reference, ticks_per_second: u64) bool {
    const epoch: u32 = 1;
    if (ticks_per_second < 1_000 or ticks_per_second / 20 > std.math.maxInt(u32)) return false;
    const initial_count: u32 = @intCast(@max(@as(u64, 1), ticks_per_second / 20));

    var baseline_halts = std.mem.zeroes([acpi.maximum_processors]u32);
    for (report.processors[0..report.target_count], 0..) |processor, index| {
        const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
        baseline_halts[index] = percpu.report(state).idle_halt_count;
        if (!percpu.requestOneShotTimer(state, epoch, initial_count)) return false;
        if (!apic.sendFixedIpi(processor.actual_apic_id, percpu.ap_work_vector)) return false;
    }

    var iteration: usize = 0;
    while (iteration < startup_timeout_iterations) : (iteration += 1) {
        var armed: usize = 0;
        for (report.processors[0..report.target_count]) |processor| {
            const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
            if (percpu.timerArmed(state, epoch)) armed += 1;
        }
        if (armed == report.target_count) break;
        if (!reference.waitNanoseconds(startup_poll_nanoseconds)) return false;
    }

    iteration = 0;
    while (iteration < startup_timeout_iterations) : (iteration += 1) {
        var fired: usize = 0;
        for (report.processors[0..report.target_count]) |processor| {
            const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
            if (percpu.timerFired(state, epoch)) fired += 1;
        }
        if (fired == report.target_count) break;
        if (!reference.waitNanoseconds(startup_poll_nanoseconds)) return false;
    }

    var completed: u32 = 0;
    for (report.processors[0..report.target_count], 0..) |*processor, index| {
        const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
        const state_report = percpu.report(state);
        if (state_report.timer_request_epoch != epoch or
            state_report.timer_armed_epoch != epoch or
            state_report.timer_interrupt_count != 1 or
            state_report.timer_error != 0 or
            state_report.timer_initial_count != initial_count or
            state_report.idle_halt_count <= baseline_halts[index])
        {
            return false;
        }
        processor.timer_initial_count = state_report.timer_initial_count;
        processor.timer_interrupt_count = state_report.timer_interrupt_count;
        processor.timer_armed_epoch = state_report.timer_armed_epoch;
        processor.timer_halt_count = state_report.idle_halt_count;
        completed += 1;
    }
    report.ap_timer_targets = @intCast(report.target_count);
    report.ap_timer_completed = completed;
    report.ap_timer_initial_count = initial_count;
    return completed == report.target_count;
}

fn runTickSchedulerRound(report: *Report, reference: time_reference.Reference, ticks_per_second: u64) bool {
    const epoch: u32 = 2;
    const jobs: u32 = 3;
    const base_input: u64 = 0x5449_434B_5F51_5541;
    if (ticks_per_second < 1_000 or ticks_per_second / 50 > std.math.maxInt(u32)) return false;
    const quantum_count: u32 = @intCast(@max(@as(u64, 1), ticks_per_second / 50));

    percpu.pauseRunQueues();
    var baseline_halts = std.mem.zeroes([acpi.maximum_processors]u32);
    for (report.processors[0..report.target_count], 0..) |processor, index| {
        const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
        if (!percpu.resetRunQueue(state)) return false;
        baseline_halts[index] = percpu.report(state).idle_halt_count;
        var sequence: u32 = 1;
        while (sequence <= jobs) : (sequence += 1) {
            const input = base_input ^
                (@as(u64, processor.actual_apic_id) << 40) ^
                (@as(u64, sequence) *% 0x0101_0101_0101_0101);
            if (!percpu.enqueueRunQueue(state, sequence, input)) return false;
        }
        if (!percpu.requestTickScheduler(state, epoch, quantum_count, jobs)) return false;
    }
    percpu.resumeRunQueues();
    for (report.processors[0..report.target_count]) |processor| {
        if (!apic.sendFixedIpi(processor.actual_apic_id, percpu.ap_work_vector)) return false;
    }

    var iteration: usize = 0;
    while (iteration < startup_timeout_iterations) : (iteration += 1) {
        var completed: usize = 0;
        for (report.processors[0..report.target_count]) |processor| {
            const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
            if (percpu.tickSchedulerComplete(state, epoch)) completed += 1;
        }
        if (completed == report.target_count) break;
        if (!reference.waitNanoseconds(startup_poll_nanoseconds)) return false;
    }

    percpu.pauseRunQueues();
    var completed: u32 = 0;
    for (report.processors[0..report.target_count], 0..) |*processor, index| {
        const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
        const checksum = percpu.verifyRunQueue(state, processor.actual_apic_id, jobs) orelse return false;
        const state_report = percpu.report(state);
        if (state_report.timer_request_epoch != epoch or
            state_report.timer_armed_epoch != epoch or
            state_report.timer_periodic != 1 or
            state_report.timer_target_interrupts != jobs or
            state_report.scheduler_enabled != 1 or
            state_report.scheduler_target_jobs != jobs or
            state_report.scheduler_tick_count != jobs or
            state_report.scheduler_dispatch_count != jobs or
            state_report.timer_interrupt_count != jobs or
            state_report.idle_halt_count < baseline_halts[index] + jobs)
        {
            return false;
        }
        processor.scheduler_jobs = jobs;
        processor.scheduler_ticks = state_report.scheduler_tick_count;
        processor.scheduler_dispatches = state_report.scheduler_dispatch_count;
        processor.scheduler_checksum = checksum;
        processor.scheduler_halt_count = state_report.idle_halt_count;
        percpu.finishTickScheduler(state);
        completed += 1;
    }
    report.ap_scheduler_targets = @intCast(report.target_count);
    report.ap_scheduler_completed = completed;
    report.ap_scheduler_jobs_per_core = jobs;
    report.ap_scheduler_quantum_count = quantum_count;
    percpu.resumeRunQueues();
    return completed == report.target_count;
}

fn runLocalTaskRound(
    report: *Report,
    allocator: *memory.FrameAllocator,
    reference: time_reference.Reference,
) bool {
    const epoch: u32 = 1;
    const stack_size = local_task_stack_pages * @as(usize, @intCast(memory.page_size));
    for (report.processors[0..report.target_count]) |processor| {
        const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
        const first_stack = allocator.allocateContiguousBelow(local_task_stack_pages, memory.four_gib) orelse return false;
        const second_stack = allocator.allocateContiguousBelow(local_task_stack_pages, memory.four_gib) orelse return false;
        if (!percpu.prepareLocalTaskExperiment(
            state,
            epoch,
            first_stack,
            stack_size,
            second_stack,
            stack_size,
        )) return false;
    }
    for (report.processors[0..report.target_count]) |processor| {
        if (!apic.sendFixedIpi(processor.actual_apic_id, percpu.ap_work_vector)) return false;
    }

    var iteration: usize = 0;
    while (iteration < startup_timeout_iterations) : (iteration += 1) {
        var completed: usize = 0;
        for (report.processors[0..report.target_count]) |processor| {
            const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
            if (percpu.localTaskExperimentComplete(state, epoch)) completed += 1;
        }
        if (completed == report.target_count) break;
        if (!reference.waitNanoseconds(startup_poll_nanoseconds)) return false;
    }

    const expected_trace = "ABABABABABBB";
    var completed: u32 = 0;
    var total_switches: u64 = 0;
    for (report.processors[0..report.target_count]) |*processor| {
        const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
        const state_report = percpu.report(state);
        if (state_report.task_request_epoch != epoch or
            state_report.task_completion_epoch != epoch or
            state_report.task_error != 0 or
            state_report.task_context_switches != 13 or
            !state_report.task_first_finished or
            !state_report.task_second_finished or
            !state_report.task_first_canary_intact or
            !state_report.task_second_canary_intact or
            state_report.task_first_yields != 5 or
            state_report.task_second_yields != 7 or
            state_report.task_first_iterations != 5 or
            state_report.task_second_iterations != 7 or
            state_report.task_trace_length != expected_trace.len or
            !std.mem.eql(u8, state_report.task_trace[0..expected_trace.len], expected_trace))
        {
            return false;
        }
        processor.local_task_first_stack = state_report.task_first_stack_base;
        processor.local_task_second_stack = state_report.task_second_stack_base;
        processor.local_task_stack_size = state_report.task_first_stack_size;
        processor.local_task_first_yields = state_report.task_first_yields;
        processor.local_task_second_yields = state_report.task_second_yields;
        processor.local_task_context_switches = state_report.task_context_switches;
        processor.local_task_trace = state_report.task_trace;
        processor.local_task_trace_length = state_report.task_trace_length;
        processor.local_task_canaries_intact = true;
        total_switches += state_report.task_context_switches;
        completed += 1;
    }
    report.ap_task_targets = @intCast(report.target_count);
    report.ap_task_completed = completed;
    report.ap_task_context_switches = total_switches;
    return completed == report.target_count;
}

fn runSynchronizationRound(report: *Report, reference: time_reference.Reference) bool {
    const epoch: u32 = 1;
    const participants: u32 = @intCast(report.target_count + 1);
    const iterations: u32 = 4096;
    var experiment = synchronization.Experiment.init(participants) orelse return false;

    for (report.processors[0..report.target_count], 0..) |processor, index| {
        const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
        if (!percpu.configureSynchronizationWorker(
            state,
            epoch,
            &experiment,
            @intCast(index + 1),
            iterations,
        )) return false;
    }
    for (report.processors[0..report.target_count]) |processor| {
        if (!apic.sendFixedIpi(processor.actual_apic_id, percpu.ap_work_vector)) return false;
    }

    const bsp_result = synchronization.runWorker(&experiment, 0, iterations) orelse return false;
    if (bsp_result.acquisitions != iterations or bsp_result.final_barrier_generation != 1) return false;

    var iteration: usize = 0;
    while (iteration < startup_timeout_iterations) : (iteration += 1) {
        var completed: usize = 0;
        for (report.processors[0..report.target_count]) |processor| {
            const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
            if (percpu.synchronizationWorkerComplete(state, epoch)) completed += 1;
        }
        if (completed == report.target_count) break;
        if (!reference.waitNanoseconds(startup_poll_nanoseconds)) return false;
    }

    const total: u64 = @as(u64, participants) * iterations;
    const expected_checksum = synchronization.expectedChecksum(participants, iterations);
    if (experiment.counter != total or
        experiment.checksum != expected_checksum or
        experiment.lock.next() != total or
        experiment.lock.serving() != total or
        experiment.barrier.currentGeneration() != 1)
    {
        return false;
    }

    for (report.processors[0..report.target_count]) |*processor| {
        const state: *percpu.State = @ptrFromInt(processor.per_cpu_state);
        const state_report = percpu.report(state);
        if (state_report.sync_request_epoch != epoch or
            state_report.sync_completion_epoch != epoch or
            state_report.sync_error != 0 or
            state_report.sync_iterations != iterations or
            state_report.sync_acquisitions != iterations or
            state_report.sync_barrier_generation != 1)
        {
            return false;
        }
        processor.sync_worker_id = state_report.sync_worker_id;
        processor.sync_iterations = state_report.sync_iterations;
        processor.sync_acquisitions = state_report.sync_acquisitions;
        processor.sync_barrier_generation = state_report.sync_barrier_generation;
    }

    report.sync_participants = participants;
    report.sync_iterations_per_participant = iterations;
    report.sync_total_increments = total;
    report.sync_lock_next = experiment.lock.next();
    report.sync_lock_serving = experiment.lock.serving();
    report.sync_barrier_generation = experiment.barrier.currentGeneration();
    report.sync_checksum = experiment.checksum;
    return true;
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
    if (@sizeOf(ApBootData) != 56) @compileError("AP boot-data header must remain 56 bytes");
    if (trampoline_image.len != 4096) @compileError("embedded AP trampoline must be one page");
}
