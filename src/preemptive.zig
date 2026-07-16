const std = @import("std");
const apic = @import("apic.zig");
const interrupt_context = @import("interrupt_context.zig");
const memory = @import("memory.zig");

const cc = std.os.uefi.cc;
const task_count: usize = 2;
const task_stack_pages: usize = 4;
const kernel_code_selector: u64 = 0x08;
const kernel_data_selector: u64 = 0x10;
const initial_rflags: u64 = 0x202;
const stack_canary: u64 = 0x5052_4545_4D50_5354;

pub const Entry = *const fn () callconv(cc) void;

const State = enum {
    unused,
    runnable,
    running,
    finished,
};

const Task = struct {
    context: interrupt_context.Frame,
    fx_state: interrupt_context.FxState align(16),
    stack_base: usize,
    stack_size: usize,
    entry: Entry,
    state: State,
    preemptions: u64,
};

pub const TaskReport = struct {
    stack_base: usize,
    stack_size: usize,
    preemptions: u64,
    finished: bool,
    canary_intact: bool,
};

pub const Report = struct {
    timer_ticks: u64,
    timer_preemptions: u64,
    context_switches: u64,
    software_interrupts: u64,
    periodic_initial_count: u32,
    first: TaskReport,
    second: TaskReport,
};

extern fn zigos_trigger_scheduler_interrupt() callconv(cc) void;
extern fn zigos_fxsave(state: *align(16) interrupt_context.FxState) callconv(cc) void;
extern fn zigos_cpu_relax() callconv(cc) void;
extern fn zigos_halt_forever() callconv(cc) noreturn;

var tasks: [task_count]Task = undefined;
var kernel_context: interrupt_context.Frame = undefined;
var kernel_fx_state: interrupt_context.FxState align(16) = undefined;
var current_task: usize = 0;
var timer_ticks: u64 = 0;
var timer_preemptions: u64 = 0;
var context_switches: u64 = 0;
var software_interrupts: u64 = 0;
var launch_pending: bool = false;
var running: bool = false;

pub fn runTwo(
    allocator: *memory.FrameAllocator,
    first: Entry,
    second: Entry,
    ticks_per_second: u64,
    frequency_hz: u32,
) ?Report {
    if (running) return null;
    resetCounters();
    if (!createTask(allocator, 0, first)) return null;
    if (!createTask(allocator, 1, second)) return null;

    current_task = 0;
    tasks[0].state = .running;
    tasks[1].state = .runnable;
    running = true;
    launch_pending = true;
    context_switches = 1;
    software_interrupts = 1;

    apic.setTimerHook(&timerHook);
    const initial_count = apic.startPeriodicTimer(ticks_per_second, frequency_hz) orelse {
        apic.setTimerHook(null);
        running = false;
        launch_pending = false;
        return null;
    };

    zigos_trigger_scheduler_interrupt();

    apic.stopTimer();
    apic.setTimerHook(null);
    if (running or launch_pending) return null;
    if (tasks[0].state != .finished or tasks[1].state != .finished) return null;

    return .{
        .timer_ticks = timer_ticks,
        .timer_preemptions = timer_preemptions,
        .context_switches = context_switches,
        .software_interrupts = software_interrupts,
        .periodic_initial_count = initial_count,
        .first = reportTask(tasks[0]),
        .second = reportTask(tasks[1]),
    };
}

pub fn tickCount() u64 {
    const pointer: *const volatile u64 = @ptrCast(&timer_ticks);
    return pointer.*;
}

pub fn relax() void {
    zigos_cpu_relax();
}

fn resetCounters() void {
    current_task = 0;
    timer_ticks = 0;
    timer_preemptions = 0;
    context_switches = 0;
    software_interrupts = 0;
    launch_pending = false;
    running = false;
}

fn createTask(allocator: *memory.FrameAllocator, index: usize, entry: Entry) bool {
    const stack_base = allocator.allocateContiguousBelow(task_stack_pages, memory.four_gib) orelse return false;
    const stack_size = task_stack_pages * @as(usize, @intCast(memory.page_size));
    const stack = @as([*]u8, @ptrFromInt(stack_base))[0..stack_size];
    @memset(stack, 0);
    @as(*u64, @ptrFromInt(stack_base)).* = stack_canary;

    const stack_top = stack_base + stack_size;
    tasks[index] = .{
        .context = std.mem.zeroes(interrupt_context.Frame),
        .fx_state = undefined,
        .stack_base = stack_base,
        .stack_size = stack_size,
        .entry = entry,
        .state = .runnable,
        .preemptions = 0,
    };
    tasks[index].context.rip = @intFromPtr(&taskBootstrap);
    tasks[index].context.cs = kernel_code_selector;
    tasks[index].context.rflags = initial_rflags;
    tasks[index].context.rsp = stack_top - 8;
    tasks[index].context.ss = kernel_data_selector;
    zigos_fxsave(&tasks[index].fx_state);
    return true;
}

fn taskBootstrap() callconv(cc) noreturn {
    const index = current_task;
    tasks[index].entry();
    finishCurrentTask();
}

fn finishCurrentTask() noreturn {
    tasks[current_task].state = .finished;
    software_interrupts +%= 1;
    zigos_trigger_scheduler_interrupt();
    zigos_halt_forever();
}

fn timerHook(
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) callconv(cc) void {
    if (!running or launch_pending) return;
    timer_ticks +%= 1;
    if (tasks[current_task].state != .running) return;

    const old_index = current_task;
    const next_index = findNextRunnable(old_index) orelse return;
    saveTask(old_index, frame, fx_state);
    tasks[old_index].state = .runnable;
    tasks[old_index].preemptions +%= 1;
    tasks[next_index].state = .running;
    current_task = next_index;
    timer_preemptions +%= 1;
    context_switches +%= 1;
    loadTask(next_index, frame, fx_state);
}

export fn zigos_scheduler_interrupt_handler(
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) callconv(cc) void {
    if (launch_pending) {
        kernel_context = frame.*;
        copyFx(&kernel_fx_state, fx_state);
        launch_pending = false;
        loadTask(current_task, frame, fx_state);
        return;
    }
    if (!running) return;

    const old_index = current_task;
    if (tasks[old_index].state == .running) saveTask(old_index, frame, fx_state);

    if (findNextRunnable(old_index)) |next_index| {
        if (tasks[old_index].state == .running) tasks[old_index].state = .runnable;
        tasks[next_index].state = .running;
        current_task = next_index;
        context_switches +%= 1;
        loadTask(next_index, frame, fx_state);
        return;
    }

    running = false;
    context_switches +%= 1;
    frame.* = kernel_context;
    copyFx(fx_state, &kernel_fx_state);
}

fn saveTask(
    index: usize,
    frame: *const interrupt_context.Frame,
    fx_state: *align(16) const interrupt_context.FxState,
) void {
    tasks[index].context = frame.*;
    copyFx(&tasks[index].fx_state, fx_state);
}

fn loadTask(
    index: usize,
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) void {
    frame.* = tasks[index].context;
    copyFx(fx_state, &tasks[index].fx_state);
}

fn findNextRunnable(old_index: usize) ?usize {
    var offset: usize = 1;
    while (offset <= task_count) : (offset += 1) {
        const candidate = (old_index + offset) % task_count;
        if (tasks[candidate].state == .runnable) return candidate;
    }
    return null;
}

fn copyFx(
    destination: *align(16) interrupt_context.FxState,
    source: *align(16) const interrupt_context.FxState,
) void {
    @memcpy(destination.bytes[0..], source.bytes[0..]);
}

fn reportTask(task: Task) TaskReport {
    return .{
        .stack_base = task.stack_base,
        .stack_size = task.stack_size,
        .preemptions = task.preemptions,
        .finished = task.state == .finished,
        .canary_intact = @as(*const u64, @ptrFromInt(task.stack_base)).* == stack_canary,
    };
}
