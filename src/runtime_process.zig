const std = @import("std");

pub const maximum_processes: usize = 64;
pub const maximum_name_length: usize = 31;
pub const maximum_arguments: usize = 8;
pub const maximum_argument_length: usize = 31;
pub const invalid_slot: u16 = 0xFFFF;

pub const Error = error{
    InvalidHandle,
    NoProcess,
    NoSlots,
    NotChild,
    StillRunning,
    AlreadyTerminal,
    InvalidSignal,
    PermissionDenied,
    QuotaExceeded,
    InvalidState,
    NameTooLong,
    TooManyArguments,
    ArgumentTooLong,
};

pub const State = enum(u8) {
    free,
    new,
    runnable,
    running,
    sleeping,
    blocked,
    stopped,
    zombie,
    faulted,
};

pub const WaitReason = enum(u8) {
    none,
    sleep,
    child,
    pipe_read,
    pipe_write,
    socket_read,
    socket_write,
    device_io,
};

pub const Kind = enum(u8) {
    kernel,
    userspace,
};

pub const Limits = struct {
    maximum_pages: u32 = 256,
    maximum_descriptors: u16 = 32,
    maximum_sockets: u16 = 16,
    maximum_children: u16 = 16,
    maximum_cpu_ticks: u64 = std.math.maxInt(u64),
};

pub const Argument = struct {
    bytes: [maximum_argument_length + 1]u8 = @splat(0),
    length: u8 = 0,

    pub fn slice(self: *const Argument) []const u8 {
        return self.bytes[0..self.length];
    }
};

pub const Process = struct {
    used: bool = false,
    generation: u32 = 0,
    handle: u64 = 0,
    pid: u32 = 0,
    ppid: u32 = 0,
    parent_slot: u16 = invalid_slot,
    process_group: u32 = 0,
    session: u32 = 0,
    uid: u32 = 0,
    gid: u32 = 0,
    kind: Kind = .userspace,
    state: State = .free,
    wait_reason: WaitReason = .none,
    name: [maximum_name_length + 1]u8 = @splat(0),
    name_length: u8 = 0,
    arguments: [maximum_arguments]Argument = @splat(.{}),
    argument_count: u8 = 0,
    cwd_node: u16 = 0,
    exit_status: u32 = 0,
    fault_vector: u16 = 0,
    fault_address: u64 = 0,
    pending_signals: u64 = 0,
    signal_mask: u64 = 0,
    priority: u8 = 16,
    time_slice: u8 = 4,
    remaining_slice: u8 = 4,
    start_tick: u64 = 0,
    wake_tick: u64 = 0,
    cpu_ticks: u64 = 0,
    context_switches: u64 = 0,
    syscall_count: u64 = 0,
    memory_pages: u32 = 0,
    descriptor_count: u16 = 0,
    socket_count: u16 = 0,
    child_count: u16 = 0,
    wait_target: u64 = 0,
    limits: Limits = .{},

    pub fn nameSlice(self: *const Process) []const u8 {
        return self.name[0..self.name_length];
    }

    pub fn terminal(self: Process) bool {
        return self.state == .zombie or self.state == .faulted;
    }
};

pub const Status = struct {
    handle: u64,
    pid: u32,
    ppid: u32,
    state: State,
    exit_status: u32,
    fault_vector: u16,
    fault_address: u64,
    cpu_ticks: u64,
    syscall_count: u64,
};

pub const Snapshot = struct {
    processes: [maximum_processes]Process = @splat(.{}),
    count: usize = 0,
};

pub const Report = struct {
    live: usize,
    runnable: usize,
    running: usize,
    sleeping: usize,
    blocked: usize,
    stopped: usize,
    zombies: usize,
    faulted: usize,
    total_created: u64,
    total_reaped: u64,
    total_context_switches: u64,
    total_signals: u64,
    total_faults: u64,
    slot_reuses: u64,
};

pub const Table = struct {
    processes: [maximum_processes]Process = @splat(.{}),
    next_pid: u32 = 1,
    scheduler_cursor: usize = 0,
    init_handle: u64 = 0,
    total_created: u64 = 0,
    total_reaped: u64 = 0,
    total_context_switches: u64 = 0,
    total_signals: u64 = 0,
    total_faults: u64 = 0,
    slot_reuses: u64 = 0,

    pub fn init(tick: u64) Table {
        var self: Table = undefined;
        self.initialize(tick);
        return self;
    }

    pub fn initialize(self: *Table, tick: u64) void {
        self.* = .{};
        const handle = self.spawnInternal(null, .kernel, "init", &.{"init"}, 0, 0, 0, tick, .{}) catch unreachable;
        self.init_handle = handle;
        const slot = self.resolve(handle) catch unreachable;
        self.processes[slot].state = .running;
        self.processes[slot].context_switches = 1;
        self.total_context_switches = 1;
    }

    pub fn initHandle(self: *const Table) u64 {
        return self.init_handle;
    }

    pub fn spawn(
        self: *Table,
        parent_handle: ?u64,
        kind: Kind,
        name: []const u8,
        arguments: []const []const u8,
        cwd_node: u16,
        uid: u32,
        gid: u32,
        tick: u64,
        limits: Limits,
    ) Error!u64 {
        return self.spawnInternal(parent_handle, kind, name, arguments, cwd_node, uid, gid, tick, limits);
    }

    pub fn get(self: *const Table, handle: u64) Error!Process {
        return self.processes[try self.resolve(handle)];
    }

    pub fn getByPid(self: *const Table, pid: u32) Error!Process {
        const slot = self.findPid(pid) orelse return Error.NoProcess;
        return self.processes[slot];
    }

    pub fn handleForPid(self: *const Table, pid: u32) Error!u64 {
        const slot = self.findPid(pid) orelse return Error.NoProcess;
        return self.processes[slot].handle;
    }

    pub fn setRunning(self: *Table, handle: u64) Error!void {
        const target = try self.resolve(handle);
        if (self.processes[target].terminal()) return Error.AlreadyTerminal;
        for (&self.processes, 0..) |*process, slot| {
            if (slot != target and process.used and process.state == .running) process.state = .runnable;
        }
        self.processes[target].state = .running;
        self.processes[target].wait_reason = .none;
        self.processes[target].wake_tick = 0;
        self.processes[target].wait_target = 0;
        self.processes[target].context_switches +%= 1;
        self.total_context_switches +%= 1;
    }

    pub fn setRunnable(self: *Table, handle: u64) Error!void {
        const slot = try self.resolve(handle);
        var process = &self.processes[slot];
        if (process.terminal()) return Error.AlreadyTerminal;
        process.state = .runnable;
        process.wait_reason = .none;
        process.wake_tick = 0;
        process.wait_target = 0;
    }

    pub fn scheduleNext(self: *Table, current_handle: ?u64) ?u64 {
        if (current_handle) |handle| {
            if (self.resolve(handle)) |slot| {
                if (self.processes[slot].state == .running) self.processes[slot].state = .runnable;
            } else |_| {}
        }
        var scanned: usize = 0;
        while (scanned < self.processes.len) : (scanned += 1) {
            self.scheduler_cursor = (self.scheduler_cursor + 1) % self.processes.len;
            var process = &self.processes[self.scheduler_cursor];
            if (!process.used or process.state != .runnable) continue;
            process.state = .running;
            process.remaining_slice = @max(@as(u8, 1), process.time_slice);
            process.context_switches +%= 1;
            self.total_context_switches +%= 1;
            return process.handle;
        }
        if (current_handle) |handle| {
            if (self.resolve(handle)) |slot| {
                if (self.processes[slot].used and self.processes[slot].state == .runnable) {
                    self.processes[slot].state = .running;
                    return handle;
                }
            } else |_| {}
        }
        return null;
    }

    pub fn accountTick(self: *Table, current_handle: u64) Error!bool {
        const slot = try self.resolve(current_handle);
        var process = &self.processes[slot];
        if (process.state != .running) return Error.InvalidState;
        process.cpu_ticks +%= 1;
        if (process.cpu_ticks >= process.limits.maximum_cpu_ticks) {
            try self.exit(current_handle, 0x7F00_0001);
            return true;
        }
        if (process.remaining_slice > 0) process.remaining_slice -= 1;
        return process.remaining_slice == 0;
    }

    pub fn accountSyscall(self: *Table, handle: u64) Error!void {
        self.processes[try self.resolve(handle)].syscall_count +%= 1;
    }

    pub fn sleep(self: *Table, handle: u64, wake_tick: u64) Error!void {
        const slot = try self.resolve(handle);
        var process = &self.processes[slot];
        if (process.terminal()) return Error.AlreadyTerminal;
        process.state = .sleeping;
        process.wait_reason = .sleep;
        process.wake_tick = wake_tick;
    }

    pub fn block(self: *Table, handle: u64, reason: WaitReason, target: u64) Error!void {
        if (reason == .none or reason == .sleep) return Error.InvalidState;
        const slot = try self.resolve(handle);
        var process = &self.processes[slot];
        if (process.terminal()) return Error.AlreadyTerminal;
        process.state = .blocked;
        process.wait_reason = reason;
        process.wait_target = target;
    }

    pub fn wakeExpired(self: *Table, tick: u64) usize {
        var count: usize = 0;
        for (&self.processes) |*process| {
            if (!process.used or process.state != .sleeping or process.wake_tick > tick) continue;
            process.state = .runnable;
            process.wait_reason = .none;
            process.wake_tick = 0;
            count += 1;
        }
        return count;
    }

    pub fn wakeMatching(self: *Table, reason: WaitReason, target: u64, all: bool) usize {
        var count: usize = 0;
        for (&self.processes) |*process| {
            if (!process.used or process.state != .blocked or process.wait_reason != reason or process.wait_target != target) continue;
            process.state = .runnable;
            process.wait_reason = .none;
            process.wait_target = 0;
            count += 1;
            if (!all) break;
        }
        return count;
    }

    pub fn stop(self: *Table, handle: u64) Error!void {
        const slot = try self.resolve(handle);
        if (self.processes[slot].terminal()) return Error.AlreadyTerminal;
        self.processes[slot].state = .stopped;
        self.processes[slot].wait_reason = .none;
    }

    pub fn continueProcess(self: *Table, handle: u64) Error!void {
        const slot = try self.resolve(handle);
        if (self.processes[slot].state != .stopped) return Error.InvalidState;
        self.processes[slot].state = .runnable;
    }

    pub fn exit(self: *Table, handle: u64, status: u32) Error!void {
        const slot = try self.resolve(handle);
        if (self.processes[slot].terminal()) return Error.AlreadyTerminal;
        self.processes[slot].state = .zombie;
        self.processes[slot].exit_status = status;
        self.processes[slot].wait_reason = .none;
        self.processes[slot].wake_tick = 0;
        self.processes[slot].wait_target = 0;
        self.reparentChildren(slot);
        self.wakeParent(slot);
    }

    pub fn fault(self: *Table, handle: u64, vector: u16, address: u64) Error!void {
        const slot = try self.resolve(handle);
        if (self.processes[slot].terminal()) return Error.AlreadyTerminal;
        self.processes[slot].state = .faulted;
        self.processes[slot].fault_vector = vector;
        self.processes[slot].fault_address = address;
        self.processes[slot].exit_status = 0x8000_0000 | @as(u32, vector);
        self.processes[slot].wait_reason = .none;
        self.total_faults +%= 1;
        self.reparentChildren(slot);
        self.wakeParent(slot);
    }

    pub fn sendSignal(self: *Table, sender_handle: u64, target_handle: u64, signal: u8) Error!void {
        if (signal == 0 or signal >= 64) return Error.InvalidSignal;
        const sender_slot = try self.resolve(sender_handle);
        const target_slot = try self.resolve(target_handle);
        if (self.processes[target_slot].terminal()) return Error.NoProcess;
        if (self.processes[sender_slot].uid != 0 and self.processes[sender_slot].uid != self.processes[target_slot].uid) return Error.PermissionDenied;
        self.processes[target_slot].pending_signals |= @as(u64, 1) << @intCast(signal);
        self.total_signals +%= 1;
        if (signal == 9) {
            try self.exit(target_handle, 128 + signal);
        } else if (signal == 19) {
            try self.stop(target_handle);
        } else if (signal == 18 and self.processes[target_slot].state == .stopped) {
            try self.continueProcess(target_handle);
        } else if (self.processes[target_slot].state == .blocked or self.processes[target_slot].state == .sleeping) {
            self.processes[target_slot].state = .runnable;
            self.processes[target_slot].wait_reason = .none;
            self.processes[target_slot].wake_tick = 0;
        }
    }

    pub fn sendGroupSignal(self: *Table, sender_handle: u64, process_group: u32, signal: u8) Error!usize {
        var targets: [maximum_processes]u64 = @splat(0);
        var count: usize = 0;
        for (self.processes) |process| {
            if (!process.used or process.process_group != process_group or process.terminal()) continue;
            targets[count] = process.handle;
            count += 1;
        }
        for (targets[0..count]) |handle| try self.sendSignal(sender_handle, handle, signal);
        return count;
    }

    pub fn takeSignal(self: *Table, handle: u64) Error!?u8 {
        const slot = try self.resolve(handle);
        var process = &self.processes[slot];
        const available = process.pending_signals & ~process.signal_mask;
        if (available == 0) return null;
        const signal: u6 = @intCast(@ctz(available));
        process.pending_signals &= ~(@as(u64, 1) << signal);
        return signal;
    }

    pub fn setSignalMask(self: *Table, handle: u64, mask: u64) Error!void {
        self.processes[try self.resolve(handle)].signal_mask = mask & ~(@as(u64, 1) << 9);
    }

    pub fn wait(self: *Table, parent_handle: u64, target_handle: ?u64, nonblocking: bool) Error!?Status {
        const parent_slot = try self.resolve(parent_handle);
        var candidate: ?usize = null;
        for (self.processes, 0..) |process, slot| {
            if (!process.used or process.parent_slot != parent_slot) continue;
            if (target_handle) |target| if (process.handle != target) continue;
            if (process.terminal()) {
                candidate = slot;
                break;
            }
        }
        if (candidate) |slot| return @as(?Status, try self.reapSlot(parent_slot, slot));
        var has_child = false;
        for (self.processes) |process| {
            if (!process.used or process.parent_slot != parent_slot) continue;
            if (target_handle) |target| if (process.handle != target) continue;
            has_child = true;
            break;
        }
        if (!has_child) return Error.NotChild;
        if (nonblocking) return null;
        self.processes[parent_slot].state = .blocked;
        self.processes[parent_slot].wait_reason = .child;
        self.processes[parent_slot].wait_target = target_handle orelse 0;
        return null;
    }

    pub fn reapOrphans(self: *Table) usize {
        const init_slot = self.resolve(self.init_handle) catch return 0;
        var reaped: usize = 0;
        var slot: usize = 0;
        while (slot < self.processes.len) : (slot += 1) {
            if (!self.processes[slot].used or self.processes[slot].parent_slot != init_slot or !self.processes[slot].terminal()) continue;
            _ = self.reapSlot(init_slot, slot) catch continue;
            reaped += 1;
        }
        return reaped;
    }

    pub fn setResourceUsage(self: *Table, handle: u64, pages: u32, descriptors: u16, sockets: u16) Error!void {
        const slot = try self.resolve(handle);
        const limits = self.processes[slot].limits;
        if (pages > limits.maximum_pages or descriptors > limits.maximum_descriptors or sockets > limits.maximum_sockets) return Error.QuotaExceeded;
        self.processes[slot].memory_pages = pages;
        self.processes[slot].descriptor_count = descriptors;
        self.processes[slot].socket_count = sockets;
    }

    pub fn setWorkingDirectory(self: *Table, handle: u64, cwd_node: u16) Error!void {
        self.processes[try self.resolve(handle)].cwd_node = cwd_node;
    }

    pub fn setProcessGroup(self: *Table, caller_handle: u64, target_handle: u64, group: u32) Error!void {
        const caller_slot = try self.resolve(caller_handle);
        const target_slot = try self.resolve(target_handle);
        if (caller_slot != target_slot and self.processes[target_slot].parent_slot != caller_slot and self.processes[caller_slot].uid != 0) return Error.PermissionDenied;
        self.processes[target_slot].process_group = if (group == 0) self.processes[target_slot].pid else group;
    }

    pub fn snapshot(self: *const Table) Snapshot {
        var result = Snapshot{};
        for (self.processes) |process| {
            if (!process.used) continue;
            result.processes[result.count] = process;
            result.count += 1;
        }
        sortByPid(result.processes[0..result.count]);
        return result;
    }

    pub fn report(self: *const Table) Report {
        var result = Report{
            .live = 0,
            .runnable = 0,
            .running = 0,
            .sleeping = 0,
            .blocked = 0,
            .stopped = 0,
            .zombies = 0,
            .faulted = 0,
            .total_created = self.total_created,
            .total_reaped = self.total_reaped,
            .total_context_switches = self.total_context_switches,
            .total_signals = self.total_signals,
            .total_faults = self.total_faults,
            .slot_reuses = self.slot_reuses,
        };
        for (self.processes) |process| {
            if (!process.used) continue;
            result.live += 1;
            switch (process.state) {
                .runnable => result.runnable += 1,
                .running => result.running += 1,
                .sleeping => result.sleeping += 1,
                .blocked => result.blocked += 1,
                .stopped => result.stopped += 1,
                .zombie => result.zombies += 1,
                .faulted => result.faulted += 1,
                else => {},
            }
        }
        return result;
    }

    fn spawnInternal(
        self: *Table,
        parent_handle: ?u64,
        kind: Kind,
        name: []const u8,
        arguments: []const []const u8,
        cwd_node: u16,
        uid: u32,
        gid: u32,
        tick: u64,
        limits: Limits,
    ) Error!u64 {
        if (name.len == 0 or name.len > maximum_name_length) return Error.NameTooLong;
        if (arguments.len > maximum_arguments) return Error.TooManyArguments;
        const parent_slot: u16 = if (parent_handle) |handle| @intCast(try self.resolve(handle)) else invalid_slot;
        if (parent_slot != invalid_slot and self.processes[parent_slot].child_count >= self.processes[parent_slot].limits.maximum_children) return Error.QuotaExceeded;
        var slot: usize = 0;
        while (slot < self.processes.len and self.processes[slot].used) : (slot += 1) {}
        if (slot >= self.processes.len) return Error.NoSlots;
        if (self.processes[slot].generation != 0) self.slot_reuses +%= 1;
        const generation = nextGeneration(self.processes[slot].generation);
        const pid = self.next_pid;
        self.next_pid +%= 1;
        if (self.next_pid == 0) self.next_pid = 1;
        var process = Process{
            .used = true,
            .generation = generation,
            .handle = makeHandle(slot, generation),
            .pid = pid,
            .ppid = if (parent_slot == invalid_slot) 0 else self.processes[parent_slot].pid,
            .parent_slot = parent_slot,
            .process_group = if (parent_slot == invalid_slot) pid else self.processes[parent_slot].process_group,
            .session = if (parent_slot == invalid_slot) pid else self.processes[parent_slot].session,
            .uid = uid,
            .gid = gid,
            .kind = kind,
            .state = .runnable,
            .name_length = @intCast(name.len),
            .argument_count = @intCast(arguments.len),
            .cwd_node = cwd_node,
            .start_tick = tick,
            .limits = limits,
        };
        @memcpy(process.name[0..name.len], name);
        for (arguments, 0..) |argument, index| {
            if (argument.len > maximum_argument_length) return Error.ArgumentTooLong;
            process.arguments[index].length = @intCast(argument.len);
            @memcpy(process.arguments[index].bytes[0..argument.len], argument);
        }
        self.processes[slot] = process;
        if (parent_slot != invalid_slot) self.processes[parent_slot].child_count += 1;
        self.total_created +%= 1;
        return process.handle;
    }

    fn resolve(self: *const Table, handle: u64) Error!usize {
        const slot: usize = @intCast(handle & 0xFFFF_FFFF);
        const generation: u32 = @intCast(handle >> 32);
        if (slot >= self.processes.len) return Error.InvalidHandle;
        const process = self.processes[slot];
        if (!process.used or process.generation != generation or process.handle != handle) return Error.InvalidHandle;
        return slot;
    }

    fn findPid(self: *const Table, pid: u32) ?usize {
        for (self.processes, 0..) |process, slot| if (process.used and process.pid == pid) return slot;
        return null;
    }

    fn reparentChildren(self: *Table, dead_slot: usize) void {
        const init_slot = self.resolve(self.init_handle) catch return;
        var adopted: u16 = 0;
        for (&self.processes) |*process| {
            if (!process.used or process.parent_slot != dead_slot) continue;
            process.parent_slot = @intCast(init_slot);
            process.ppid = self.processes[init_slot].pid;
            adopted += 1;
        }
        self.processes[dead_slot].child_count -|= adopted;
        self.processes[init_slot].child_count +|= adopted;
    }

    fn wakeParent(self: *Table, child_slot: usize) void {
        const parent_slot = self.processes[child_slot].parent_slot;
        if (parent_slot == invalid_slot or parent_slot >= self.processes.len or !self.processes[parent_slot].used) return;
        var parent = &self.processes[parent_slot];
        if (parent.state != .blocked or parent.wait_reason != .child) return;
        if (parent.wait_target != 0 and parent.wait_target != self.processes[child_slot].handle) return;
        parent.state = .runnable;
        parent.wait_reason = .none;
        parent.wait_target = 0;
    }

    fn reapSlot(self: *Table, parent_slot: usize, child_slot: usize) Error!Status {
        if (!self.processes[child_slot].used or self.processes[child_slot].parent_slot != parent_slot) return Error.NotChild;
        const child = self.processes[child_slot];
        if (!child.terminal()) return Error.StillRunning;
        const status = Status{
            .handle = child.handle,
            .pid = child.pid,
            .ppid = child.ppid,
            .state = child.state,
            .exit_status = child.exit_status,
            .fault_vector = child.fault_vector,
            .fault_address = child.fault_address,
            .cpu_ticks = child.cpu_ticks,
            .syscall_count = child.syscall_count,
        };
        const generation = child.generation;
        self.processes[child_slot] = .{ .generation = generation };
        self.processes[parent_slot].child_count -|= 1;
        self.total_reaped +%= 1;
        return status;
    }
};

fn nextGeneration(current: u32) u32 {
    const next = current +% 1;
    return if (next == 0) 1 else next;
}

fn makeHandle(slot: usize, generation: u32) u64 {
    return (@as(u64, generation) << 32) | @as(u64, @intCast(slot));
}

fn sortByPid(processes: []Process) void {
    var index: usize = 1;
    while (index < processes.len) : (index += 1) {
        const value = processes[index];
        var position = index;
        while (position > 0 and value.pid < processes[position - 1].pid) : (position -= 1) processes[position] = processes[position - 1];
        processes[position] = value;
    }
}

test "process generations reject stale handles after reap and reuse" {
    var table = Table.init(0);
    const init_handle = table.initHandle();
    const child = try table.spawn(init_handle, .userspace, "child", &.{"child"}, 0, 1000, 1000, 1, .{});
    try table.exit(child, 7);
    const status = (try table.wait(init_handle, child, false)).?;
    try std.testing.expectEqual(@as(u32, 7), status.exit_status);
    try std.testing.expectError(Error.InvalidHandle, table.get(child));
    const replacement = try table.spawn(init_handle, .userspace, "new", &.{"new"}, 0, 1000, 1000, 2, .{});
    try std.testing.expect(replacement != child);
    try std.testing.expectEqual(@as(u64, 1), table.slot_reuses);
}

test "sleep block wake and round robin scheduling" {
    var table = Table.init(0);
    const init_handle = table.initHandle();
    const a = try table.spawn(init_handle, .userspace, "a", &.{"a"}, 0, 1, 1, 1, .{});
    const b = try table.spawn(init_handle, .userspace, "b", &.{"b"}, 0, 1, 1, 1, .{});
    try table.setRunnable(init_handle);
    const first = table.scheduleNext(null).?;
    try std.testing.expect(first == a or first == b or first == init_handle);
    try table.sleep(a, 10);
    try table.block(b, .pipe_read, 99);
    try std.testing.expectEqual(@as(usize, 0), table.wakeExpired(9));
    try std.testing.expectEqual(@as(usize, 1), table.wakeExpired(10));
    try std.testing.expectEqual(@as(usize, 1), table.wakeMatching(.pipe_read, 99, false));
}

test "wait blocks and child exit wakes parent" {
    var table = Table.init(0);
    const parent = table.initHandle();
    const child = try table.spawn(parent, .userspace, "child", &.{}, 0, 0, 0, 1, .{});
    try std.testing.expect((try table.wait(parent, child, false)) == null);
    try std.testing.expectEqual(State.blocked, (try table.get(parent)).state);
    try table.exit(child, 42);
    try std.testing.expectEqual(State.runnable, (try table.get(parent)).state);
    const result = (try table.wait(parent, child, false)).?;
    try std.testing.expectEqual(@as(u32, 42), result.exit_status);
}

test "orphan children are adopted and auto reaped by init" {
    var table = Table.init(0);
    const init_handle = table.initHandle();
    const parent = try table.spawn(init_handle, .userspace, "parent", &.{}, 0, 0, 0, 1, .{});
    const child = try table.spawn(parent, .userspace, "child", &.{}, 0, 0, 0, 2, .{});
    try table.exit(parent, 1);
    try std.testing.expectEqual(@as(u32, 1), (try table.get(child)).ppid);
    try table.exit(child, 2);
    try std.testing.expectEqual(@as(usize, 2), table.reapOrphans());
}

test "signals enforce uid permissions masks and terminal kill" {
    var table = Table.init(0);
    const root = table.initHandle();
    const user_a = try table.spawn(root, .userspace, "a", &.{}, 0, 1000, 1000, 1, .{});
    const user_b = try table.spawn(root, .userspace, "b", &.{}, 0, 2000, 2000, 1, .{});
    try std.testing.expectError(Error.PermissionDenied, table.sendSignal(user_a, user_b, 2));
    try table.sendSignal(root, user_a, 2);
    try table.setSignalMask(user_a, @as(u64, 1) << 2);
    try std.testing.expect((try table.takeSignal(user_a)) == null);
    try table.setSignalMask(user_a, 0);
    try std.testing.expectEqual(@as(?u8, 2), try table.takeSignal(user_a));
    try table.sendSignal(root, user_a, 9);
    try std.testing.expectEqual(State.zombie, (try table.get(user_a)).state);
}

test "resource quotas are transactional" {
    var table = Table.init(0);
    const process = try table.spawn(table.initHandle(), .userspace, "limited", &.{}, 0, 1, 1, 1, .{
        .maximum_pages = 4,
        .maximum_descriptors = 3,
        .maximum_sockets = 2,
    });
    try table.setResourceUsage(process, 4, 3, 2);
    try std.testing.expectError(Error.QuotaExceeded, table.setResourceUsage(process, 5, 3, 2));
    const retained = try table.get(process);
    try std.testing.expectEqual(@as(u32, 4), retained.memory_pages);
    try std.testing.expectEqual(@as(u16, 3), retained.descriptor_count);
}

test "process groups support directed group signals" {
    var table = Table.init(0);
    const root = table.initHandle();
    const a = try table.spawn(root, .userspace, "a", &.{}, 0, 0, 0, 1, .{});
    const b = try table.spawn(root, .userspace, "b", &.{}, 0, 0, 0, 1, .{});
    try table.setProcessGroup(root, a, 77);
    try table.setProcessGroup(root, b, 77);
    try std.testing.expectEqual(@as(usize, 2), try table.sendGroupSignal(root, 77, 15));
    try std.testing.expectEqual(@as(?u8, 15), try table.takeSignal(a));
    try std.testing.expectEqual(@as(?u8, 15), try table.takeSignal(b));
}

test "fault status preserves vector address and counters" {
    var table = Table.init(0);
    const root = table.initHandle();
    const child = try table.spawn(root, .userspace, "fault", &.{}, 0, 0, 0, 1, .{});
    try table.accountSyscall(child);
    try table.fault(child, 14, 0xDEAD_BEEF);
    const status = (try table.wait(root, child, false)).?;
    try std.testing.expectEqual(State.faulted, status.state);
    try std.testing.expectEqual(@as(u16, 14), status.fault_vector);
    try std.testing.expectEqual(@as(u64, 0xDEAD_BEEF), status.fault_address);
    try std.testing.expectEqual(@as(u64, 1), status.syscall_count);
}
