const std = @import("std");
const apic = @import("apic.zig");
const interrupt_context = @import("interrupt_context.zig");

const cc = std.os.uefi.cc;
const code_selector: u16 = 0x08;
const data_selector: u16 = 0x10;
const tss_selector: u16 = 0x18;
const exception_vector_count: usize = 32;
const spurious_vector: usize = 0xFF;
const state_magic: u64 = 0x5A49_474F_5350_4355;
pub const run_queue_capacity: usize = 8;
pub const ap_work_vector: u8 = 0x42;
const run_queue_command: u32 = 2;
const run_queue_checksum_seed: u64 = 0xCBF2_9CE4_8422_2325;
const work_stealing_checksum_seed: u64 = 0x5753_5445_414C_494E;

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
    reserved: u32,
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
extern fn zigos_wait_for_interrupt() callconv(cc) void;
extern fn zigos_memory_fence() callconv(cc) void;
extern fn zigos_cpu_relax() callconv(cc) void;

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
        &state.idt[ap_work_vector],
        @intFromPtr(&zigos_isr_ap_work),
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
    if (!apic.initializeCurrentProcessor()) return false;

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
    entry.sequence = sequence;
    entry.command = run_queue_command;
    entry.input = input;
    entry.reserved = 0;
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
        if (atomicLoadU32(&run_queue_gate) != 0) {
            if (atomicLoadU32(&stealing_enabled) != 0) {
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
        if (atomicLoadU32(&entry.completed) != 1 or
            entry.sequence != sequence or
            entry.command != run_queue_command or
            entry.executor_apic_id >= 64)
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
        executor_mask |= @as(u64, 1) << @intCast(entry.executor_apic_id);
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
    _ = interrupt_context;
}
