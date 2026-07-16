const std = @import("std");
const memory = @import("memory.zig");

const cc = std.os.uefi.cc;
const maximum_tasks: usize = 4;
const task_stack_pages: usize = 4;
const saved_integer_bytes: usize = 8 * @sizeOf(usize);
const saved_xmm_bytes: usize = 10 * 16;
const bootstrap_frame_bytes: usize = saved_integer_bytes + saved_xmm_bytes;
const stack_canary: u64 = 0x5A49_474F_5354_414B;

pub const Entry = *const fn () callconv(cc) void;

const State = enum {
    unused,
    runnable,
    running,
    finished,
};

const Task = struct {
    saved_rsp: usize = 0,
    stack_base: usize = 0,
    stack_size: usize = 0,
    entry: Entry = undefined,
    state: State = .unused,
    yields: u64 = 0,
};

pub const TaskReport = struct {
    stack_base: usize,
    stack_size: usize,
    yields: u64,
    finished: bool,
    canary_intact: bool,
};

pub const Report = struct {
    task_count: usize,
    context_switches: u64,
    first: TaskReport,
    second: TaskReport,
};

extern fn zigos_context_switch(old_rsp: *usize, new_rsp: usize) callconv(cc) void;
extern fn zigos_halt_forever() callconv(cc) noreturn;

var tasks: [maximum_tasks]Task = undefined;
var task_count: usize = 0;
var current_task: usize = 0;
var scheduler_rsp: usize = 0;
var context_switches: u64 = 0;
var scheduler_running: bool = false;

pub fn runTwo(allocator: *memory.FrameAllocator, first: Entry, second: Entry) ?Report {
    if (scheduler_running) return null;
    reset();

    if (!createTask(allocator, 0, first)) return null;
    if (!createTask(allocator, 1, second)) return null;
    task_count = 2;
    current_task = 0;
    tasks[0].state = .running;
    scheduler_running = true;
    context_switches = 1;

    zigos_context_switch(&scheduler_rsp, tasks[0].saved_rsp);

    scheduler_running = false;
    if (tasks[0].state != .finished or tasks[1].state != .finished) return null;

    return .{
        .task_count = task_count,
        .context_switches = context_switches,
        .first = reportTask(tasks[0]),
        .second = reportTask(tasks[1]),
    };
}

pub fn yield() void {
    if (!scheduler_running or task_count == 0) return;

    const old_index = current_task;
    tasks[old_index].yields +%= 1;
    const next_index = findNextRunnable(old_index) orelse return;

    tasks[old_index].state = .runnable;
    tasks[next_index].state = .running;
    current_task = next_index;
    context_switches +%= 1;
    zigos_context_switch(&tasks[old_index].saved_rsp, tasks[next_index].saved_rsp);
}

fn reset() void {
    for (&tasks) |*task| task.* = .{};
    task_count = 0;
    current_task = 0;
    scheduler_rsp = 0;
    context_switches = 0;
    scheduler_running = false;
}

fn createTask(allocator: *memory.FrameAllocator, index: usize, entry: Entry) bool {
    const stack_base = allocator.allocateContiguousBelow(task_stack_pages, memory.four_gib) orelse return false;
    const stack_size = task_stack_pages * @as(usize, @intCast(memory.page_size));
    const stack = @as([*]u8, @ptrFromInt(stack_base))[0..stack_size];
    @memset(stack, 0);
    @as(*u64, @ptrFromInt(stack_base)).* = stack_canary;

    const stack_top = stack_base + stack_size;
    const return_slot = (stack_top - 16) & ~@as(usize, 0xF);
    if (return_slot < stack_base + bootstrap_frame_bytes + @sizeOf(usize)) return false;
    const saved_rsp = return_slot - bootstrap_frame_bytes;
    @as(*usize, @ptrFromInt(return_slot)).* = @intFromPtr(&taskBootstrap);

    tasks[index] = .{
        .saved_rsp = saved_rsp,
        .stack_base = stack_base,
        .stack_size = stack_size,
        .entry = entry,
        .state = .runnable,
        .yields = 0,
    };
    return true;
}

fn findNextRunnable(old_index: usize) ?usize {
    if (task_count <= 1) return null;

    var offset: usize = 1;
    while (offset < task_count) : (offset += 1) {
        const candidate = (old_index + offset) % task_count;
        if (tasks[candidate].state == .runnable) return candidate;
    }
    return null;
}

fn taskBootstrap() callconv(cc) noreturn {
    const index = current_task;
    tasks[index].entry();
    finishCurrentTask();
}

fn finishCurrentTask() noreturn {
    const old_index = current_task;
    tasks[old_index].state = .finished;

    if (findNextRunnable(old_index)) |next_index| {
        tasks[next_index].state = .running;
        current_task = next_index;
        context_switches +%= 1;
        zigos_context_switch(&tasks[old_index].saved_rsp, tasks[next_index].saved_rsp);
        zigos_halt_forever();
    }

    context_switches +%= 1;
    zigos_context_switch(&tasks[old_index].saved_rsp, scheduler_rsp);
    zigos_halt_forever();
}

fn reportTask(task: Task) TaskReport {
    return .{
        .stack_base = task.stack_base,
        .stack_size = task.stack_size,
        .yields = task.yields,
        .finished = task.state == .finished,
        .canary_intact = @as(*const u64, @ptrFromInt(task.stack_base)).* == stack_canary,
    };
}

comptime {
    if (bootstrap_frame_bytes != 224) {
        @compileError("scheduler bootstrap frame must match the assembly context-switch layout");
    }
}
