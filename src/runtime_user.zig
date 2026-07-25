const std = @import("std");
const descriptor_tables = @import("descriptor_tables.zig");
const elf64 = @import("elf64.zig");
const interrupt_context = @import("interrupt_context.zig");
const memory = @import("memory.zig");
const paging = @import("paging.zig");
const runtime_abi = @import("runtime_abi.zig");
const runtime_fd = @import("runtime_fd.zig");
const runtime_process = @import("runtime_process.zig");
const runtime_vfs = @import("runtime_vfs.zig");

const cc = std.os.uefi.cc;
const page_bytes: usize = @intCast(memory.page_size);
const arena_pages: usize = 256;
const maximum_contexts: usize = 8;
const maximum_mappings: usize = 32;
const maximum_output_bytes: usize = 4096;
const maximum_io_bytes: usize = 1024;
const user_base: usize = 0x0000_0080_0000_0000;
const user_window_bytes: usize = 2 * 1024 * 1024;
const trampoline_virtual: usize = user_base + user_window_bytes - 3 * page_bytes;
const stack_virtual: usize = user_base + user_window_bytes - 2 * page_bytes;
const guard_virtual: usize = user_base + user_window_bytes - page_bytes;

const syscall_exit: u64 = 64;
const syscall_write: u64 = 65;
const syscall_read: u64 = 66;
const syscall_getpid: u64 = 67;
const syscall_sleep: u64 = 68;
const syscall_yield: u64 = 69;
const syscall_pipe: u64 = 70;
const syscall_close: u64 = 71;
const syscall_dup: u64 = 72;
const syscall_dup2: u64 = 73;
const syscall_open: u64 = 74;
const syscall_ticks: u64 = 75;
const syscall_fault_return: u64 = 78;

const errno_bad_fd = runtime_abi.errno_bad_fd;
const errno_would_block = runtime_abi.errno_would_block;
const errno_fault = runtime_abi.errno_fault;
const errno_invalid = runtime_abi.errno_invalid;
const errno_no_syscall = runtime_abi.errno_no_syscall;

const fault_trampoline = [_]u8{
    0xB8, @truncate(syscall_fault_return), 0x00, 0x00, 0x00, // mov eax, SYS_FAULT_RETURN
    0xCD, 0x80, // int 0x80
    0x0F, 0x0B, // ud2 if the kernel incorrectly resumes it
};

pub const SpawnRegisters = struct {
    override: bool = false,
    rdi: u64 = 0,
    rsi: u64 = 0,
    rdx: u64 = 0,
};

pub const Report = struct {
    arena_pages: usize,
    used_pages: usize,
    peak_pages: usize,
    live_contexts: usize,
    launches: u64,
    exits: u64,
    faults: u64,
    preemptions: u64,
    blocking_returns: u64,
    syscalls: u64,
    reclaimed_pages: u64,
};

const Mapping = struct {
    used: bool = false,
    virtual_address: usize = 0,
    physical_address: usize = 0,
};

const Context = struct {
    used: bool = false,
    handle: u64 = 0,
    space: paging.UserAddressSpace = .{
        .pml4_address = 0,
        .pdpt_address = 0,
        .directory_address = 0,
        .table_address = 0,
        .table_pages = 0,
    },
    table_frames: [4]usize = @splat(0),
    mappings: [maximum_mappings]Mapping = @splat(.{}),
    mapping_count: usize = 0,
    frame: interrupt_context.Frame = std.mem.zeroes(interrupt_context.Frame),
    fx_state: interrupt_context.FxState align(16) = std.mem.zeroes(interrupt_context.FxState),
    output: [maximum_output_bytes]u8 = @splat(0),
    output_length: usize = 0,
    output_truncated: bool = false,
    resources_released: bool = false,
    pending_fault: bool = false,
    fault_vector: u16 = 0,
    fault_error: u64 = 0,
    fault_address: u64 = 0,
    image_hash: u64 = 0,
    image_bytes: usize = 0,
    preemptions: u64 = 0,
};

extern fn zigos_enter_user_context(
    frame: *const interrupt_context.Frame,
    fx_state: *const interrupt_context.FxState,
) callconv(cc) void;
extern fn zigos_fxsave(state: *align(16) interrupt_context.FxState) callconv(cc) void;

var initialized = false;
var vfs_pointer: ?*runtime_vfs.Vfs = null;
var process_pointer: ?*runtime_process.Table = null;
var descriptor_pointer: ?*runtime_fd.System = null;
var arena_base: usize = 0;
var arena_used: [arena_pages]bool = @splat(false);
var contexts: [maximum_contexts]Context = @splat(.{});
var baseline_fx: interrupt_context.FxState align(16) = std.mem.zeroes(interrupt_context.FxState);
var current_context: ?usize = null;
var user_active = false;
var current_tick: u64 = 0;
var peak_pages: usize = 0;
var launches: u64 = 0;
var exits: u64 = 0;
var faults: u64 = 0;
var preemptions: u64 = 0;
var blocking_returns: u64 = 0;
var syscall_count: u64 = 0;
var reclaimed_pages: u64 = 0;

pub fn initialize(
    allocator: *memory.FrameAllocator,
    vfs: *runtime_vfs.Vfs,
    processes: *runtime_process.Table,
    descriptors: *runtime_fd.System,
) !void {
    if (initialized) return error.AlreadyInitialized;
    if (!paging.noExecuteEnabled() and !paging.enableNoExecute()) return error.NoExecuteUnavailable;
    const base = allocator.allocateContiguousBelow(arena_pages, memory.four_gib) orelse return error.NoRuntimeFrames;
    if ((base & (page_bytes - 1)) != 0) return error.UnalignedRuntimeArena;
    vfs_pointer = vfs;
    process_pointer = processes;
    descriptor_pointer = descriptors;
    arena_base = base;
    arena_used = @splat(false);
    contexts = @splat(.{});
    zigos_fxsave(&baseline_fx);
    current_context = null;
    user_active = false;
    current_tick = 0;
    peak_pages = 0;
    launches = 0;
    exits = 0;
    faults = 0;
    preemptions = 0;
    blocking_returns = 0;
    syscall_count = 0;
    reclaimed_pages = 0;
    initialized = true;
}

pub fn isActive() bool {
    return initialized and user_active and current_context != null;
}

pub fn spawn(
    parent_handle: u64,
    name: []const u8,
    arguments: []const []const u8,
    cwd_node: u16,
    image_bytes: []const u8,
    tick: u64,
    registers: SpawnRegisters,
) !u64 {
    if (!initialized) return error.NotInitialized;
    const image = elf64.parse(image_bytes) orelse return error.InvalidElf;
    try validateImage(image);
    const context_index = findFreeContext() orelse return error.ContextLimit;
    const processes = activeProcesses();
    const handle = try processes.spawn(
        parent_handle,
        .userspace,
        name,
        arguments,
        cwd_node,
        0,
        0,
        tick,
        .{
            .maximum_pages = maximum_mappings + 4,
            .maximum_descriptors = runtime_fd.maximum_descriptors_per_process,
            .maximum_sockets = 0,
            .maximum_children = 0,
            .maximum_cpu_ticks = 100_000,
        },
    );
    errdefer rollbackProcess(parent_handle, handle);
    _ = try activeDescriptors().cloneProcess(processes, parent_handle, handle);

    contexts[context_index] = .{ .used = true, .handle = handle };
    errdefer releaseContext(context_index);
    const context = &contexts[context_index];
    for (&context.table_frames) |*frame| frame.* = allocatePage() orelse return error.NoRuntimeFrames;
    context.space = paging.createUserAddressSpaceFromFrames(context.table_frames) orelse return error.AddressSpaceFailure;
    try loadImage(context, image, image_bytes);
    const trampoline_frame = allocatePage() orelse return error.NoRuntimeFrames;
    @memcpy(@as([*]u8, @ptrFromInt(trampoline_frame))[0..fault_trampoline.len], &fault_trampoline);
    try mapOwned(context, trampoline_virtual, trampoline_frame, false, true);
    const stack_frame = allocatePage() orelse return error.NoRuntimeFrames;
    try mapOwned(context, stack_virtual, stack_frame, true, false);
    if (paging.inspectUserPageInSpace(context.space, guard_virtual) != null) return error.GuardMapped;

    const stack = try buildInitialStack(stack_frame, arguments);
    context.frame = std.mem.zeroes(interrupt_context.Frame);
    context.frame.rip = image.entry;
    context.frame.cs = descriptor_tables.user_code_selector;
    context.frame.rflags = 0x202;
    context.frame.rsp = stack.rsp;
    context.frame.ss = descriptor_tables.user_data_selector;
    context.frame.rdi = stack.argc;
    context.frame.rsi = stack.argv;
    if (registers.override) {
        context.frame.rdi = registers.rdi;
        context.frame.rsi = registers.rsi;
        context.frame.rdx = registers.rdx;
    }
    copyFx(&context.fx_state, &baseline_fx);
    context.image_hash = image.file_hash;
    context.image_bytes = image_bytes.len;
    try processes.setResourceUsage(handle, @intCast(context.mapping_count + 4), (try processes.get(handle)).descriptor_count, 0);
    launches +%= 1;
    return handle;
}

pub fn dispatch(handle: u64, tick: u64) !void {
    if (!initialized or user_active) return error.InvalidDispatchState;
    const context_index = findContext(handle) orelse return error.NoContext;
    var process = try activeProcesses().get(handle);
    if (process.terminal()) {
        try finalize(handle);
        return;
    }
    if (process.state != .runnable and process.state != .running) return error.NotRunnable;
    try activeProcesses().setRunning(handle);
    current_tick = tick;
    current_context = context_index;
    user_active = true;
    if (!paging.activateAddressSpace(contexts[context_index].space.pml4_address)) {
        user_active = false;
        current_context = null;
        return error.AddressSpaceActivation;
    }
    zigos_enter_user_context(&contexts[context_index].frame, &contexts[context_index].fx_state);
    user_active = false;
    current_context = null;
    if (!paging.activateKernelAddressSpace()) return error.KernelAddressSpaceRestore;

    process = try activeProcesses().get(handle);
    if (process.state == .running) try activeProcesses().setRunnable(handle);
    if (process.terminal()) try finalize(handle);
}

pub fn handleSyscall(
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) u64 {
    if (!isActive()) return 1;
    const index = current_context orelse return 1;
    const context = &contexts[index];
    if (!validFrame(context.*, frame)) return forceFault(frame, fx_state, 13, frame.rip);
    activeProcesses().accountSyscall(context.handle) catch return forceFault(frame, fx_state, 13, frame.rip);
    syscall_count +%= 1;

    switch (frame.rax) {
        syscall_exit => {
            activeProcesses().exit(context.handle, @truncate(frame.rdi)) catch {};
            exits +%= 1;
            saveContext(context, frame, fx_state);
            return 1;
        },
        syscall_write => return syscallWrite(context, frame, fx_state),
        syscall_read => return syscallRead(context, frame, fx_state),
        syscall_getpid => {
            const process = activeProcesses().get(context.handle) catch return forceFault(frame, fx_state, 13, frame.rip);
            frame.rax = process.pid;
            return 0;
        },
        syscall_sleep => {
            if (frame.rdi == 0 or frame.rdi > 100_000) {
                frame.rax = reject(errno_invalid);
                return 0;
            }
            const wake_tick = std.math.add(u64, current_tick, frame.rdi) catch {
                frame.rax = reject(errno_invalid);
                return 0;
            };
            frame.rax = 0;
            saveContext(context, frame, fx_state);
            activeProcesses().sleep(context.handle, wake_tick) catch return forceFault(frame, fx_state, 13, frame.rip);
            blocking_returns +%= 1;
            return 1;
        },
        syscall_yield => {
            frame.rax = 0;
            saveContext(context, frame, fx_state);
            activeProcesses().setRunnable(context.handle) catch {};
            blocking_returns +%= 1;
            return 1;
        },
        syscall_pipe => {
            if (!validateRange(context.*, frame.rdi, 8, true)) {
                frame.rax = reject(errno_fault);
                return 0;
            }
            const fds = activeDescriptors().createPipe(activeProcesses(), context.handle) catch |err| {
                frame.rax = reject(runtime_abi.fromError(err));
                return 0;
            };
            const values = [2]u32{ fds[0], fds[1] };
            if (!copyToUser(context.*, frame.rdi, std.mem.asBytes(&values))) {
                activeDescriptors().close(activeVfs(), activeProcesses(), context.handle, fds[0]) catch {};
                activeDescriptors().close(activeVfs(), activeProcesses(), context.handle, fds[1]) catch {};
                frame.rax = reject(errno_fault);
                return 0;
            }
            frame.rax = 0;
            return 0;
        },
        syscall_close => {
            const fd = runtime_abi.descriptor(frame.rdi) orelse {
                frame.rax = reject(errno_bad_fd);
                return 0;
            };
            activeDescriptors().close(activeVfs(), activeProcesses(), context.handle, fd) catch |err| {
                frame.rax = reject(runtime_abi.fromError(err));
                return 0;
            };
            frame.rax = 0;
            return 0;
        },
        syscall_dup => {
            const source_fd = runtime_abi.descriptor(frame.rdi) orelse {
                frame.rax = reject(errno_bad_fd);
                return 0;
            };
            const fd = activeDescriptors().duplicate(activeProcesses(), context.handle, source_fd) catch |err| {
                frame.rax = reject(runtime_abi.fromError(err));
                return 0;
            };
            frame.rax = fd;
            return 0;
        },
        syscall_dup2 => {
            const source_fd = runtime_abi.descriptor(frame.rdi) orelse {
                frame.rax = reject(errno_bad_fd);
                return 0;
            };
            const target_fd = runtime_abi.descriptor(frame.rsi) orelse {
                frame.rax = reject(errno_bad_fd);
                return 0;
            };
            const fd = activeDescriptors().duplicateTo(
                activeVfs(),
                activeProcesses(),
                context.handle,
                source_fd,
                target_fd,
            ) catch |err| {
                frame.rax = reject(runtime_abi.fromError(err));
                return 0;
            };
            frame.rax = fd;
            return 0;
        },
        syscall_open => return syscallOpen(context, frame),
        syscall_ticks => {
            frame.rax = current_tick;
            return 0;
        },
        syscall_fault_return => {
            if (!context.pending_fault) return forceFault(frame, fx_state, 13, frame.rip);
            activeProcesses().fault(context.handle, context.fault_vector, context.fault_address) catch {};
            faults +%= 1;
            saveContext(context, frame, fx_state);
            return 1;
        },
        else => {
            frame.rax = reject(errno_no_syscall);
            return 0;
        },
    }
}

pub fn handleTimer(
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
    tick: u64,
) bool {
    if (!isActive() or (frame.cs & 3) != 3) return false;
    const index = current_context orelse return false;
    const context = &contexts[index];
    current_tick = tick;
    saveContext(context, frame, fx_state);
    _ = activeProcesses().accountTick(context.handle) catch false;
    const process = activeProcesses().get(context.handle) catch return true;
    if (!process.terminal()) activeProcesses().setRunnable(context.handle) catch {};
    context.preemptions +%= 1;
    preemptions +%= 1;
    return true;
}

pub fn handleException(
    frame: *interrupt_context.ExceptionFrame,
    fault_address: u64,
) bool {
    if (!isActive() or (frame.cs & 3) != 3) return false;
    const index = current_context orelse return false;
    const context = &contexts[index];
    if (context.pending_fault) return false;
    const trampoline = paging.inspectUserPageInSpace(context.space, trampoline_virtual) orelse return false;
    if (!trampoline.executable or trampoline.writable) return false;
    context.pending_fault = true;
    context.fault_vector = @truncate(frame.vector);
    context.fault_error = frame.error_code;
    context.fault_address = fault_address;
    frame.rip = trampoline_virtual;
    return true;
}

pub fn finalize(handle: u64) !void {
    const index = findContext(handle) orelse return error.NoContext;
    if (contexts[index].resources_released) return;
    if (user_active and current_context == index) return error.ContextActive;
    if (!paging.activateKernelAddressSpace()) return error.KernelAddressSpaceRestore;
    _ = activeDescriptors().releaseProcess(activeVfs(), activeProcesses(), handle) catch |err| switch (err) {
        error.NamespaceMissing => 0,
        else => return err,
    };
    const process = try activeProcesses().get(handle);
    try activeProcesses().setResourceUsage(handle, 0, 0, process.socket_count);
    if (!releaseMappings(index)) return error.MappingCleanupFailure;
    contexts[index].resources_released = true;
}

pub fn forget(handle: u64) void {
    const index = findContext(handle) orelse return;
    if (!contexts[index].resources_released) return;
    contexts[index] = .{};
}

pub fn takeOutput(handle: u64, destination: []u8) usize {
    const index = findContext(handle) orelse return 0;
    const context = &contexts[index];
    const count = @min(destination.len, context.output_length);
    @memcpy(destination[0..count], context.output[0..count]);
    return count;
}

pub fn outputWasTruncated(handle: u64) bool {
    const index = findContext(handle) orelse return false;
    return contexts[index].output_truncated;
}

pub fn imageIdentity(handle: u64) ?struct { bytes: usize, hash: u64 } {
    const index = findContext(handle) orelse return null;
    return .{ .bytes = contexts[index].image_bytes, .hash = contexts[index].image_hash };
}

pub fn createPipeFor(handle: u64) ![2]u16 {
    return activeDescriptors().createPipe(activeProcesses(), handle);
}

pub fn closeDescriptorFor(handle: u64, fd: u16) !void {
    return activeDescriptors().close(activeVfs(), activeProcesses(), handle, fd);
}

pub fn report() Report {
    var used_pages: usize = 0;
    for (arena_used) |used| if (used) {
        used_pages += 1;
    };
    var live_contexts: usize = 0;
    for (contexts) |context| if (context.used) {
        live_contexts += 1;
    };
    return .{
        .arena_pages = arena_pages,
        .used_pages = used_pages,
        .peak_pages = peak_pages,
        .live_contexts = live_contexts,
        .launches = launches,
        .exits = exits,
        .faults = faults,
        .preemptions = preemptions,
        .blocking_returns = blocking_returns,
        .syscalls = syscall_count,
        .reclaimed_pages = reclaimed_pages,
    };
}

fn syscallWrite(
    context: *Context,
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) u64 {
    const length: usize = std.math.cast(usize, frame.rdx) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if (length > maximum_io_bytes or !validateRange(context.*, frame.rsi, length, false)) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    var bytes: [maximum_io_bytes]u8 = undefined;
    if (!copyFromUser(context.*, frame.rsi, bytes[0..length])) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    const kind = descriptorKind(context.handle, fd) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    if (kind == .terminal) {
        appendOutput(context, bytes[0..length]);
        frame.rax = length;
        return 0;
    }
    const result = activeDescriptors().write(
        activeVfs(),
        activeProcesses(),
        context.handle,
        fd,
        bytes[0..length],
        current_tick,
    ) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    if (result.status == .blocked) return blockAndRetry(context, frame, fx_state);
    frame.rax = result.count;
    return 0;
}

fn syscallRead(
    context: *Context,
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) u64 {
    const length: usize = std.math.cast(usize, frame.rdx) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if (length > maximum_io_bytes or !validateRange(context.*, frame.rsi, length, true)) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    const kind = descriptorKind(context.handle, fd) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    if (kind == .terminal) {
        frame.rax = 0;
        return 0;
    }
    var bytes: [maximum_io_bytes]u8 = undefined;
    const result = activeDescriptors().read(
        activeVfs(),
        activeProcesses(),
        context.handle,
        fd,
        bytes[0..length],
    ) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    if (result.status == .blocked) return blockAndRetry(context, frame, fx_state);
    if (result.count != 0 and !copyToUser(context.*, frame.rsi, bytes[0..result.count])) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    frame.rax = result.count;
    return 0;
}

fn syscallOpen(context: *Context, frame: *interrupt_context.Frame) u64 {
    var path_buffer: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0);
    const path_length = copyUserString(context.*, frame.rdi, &path_buffer) orelse {
        frame.rax = reject(errno_fault);
        return 0;
    };
    const bits = runtime_abi.openFlagBits(frame.rsi) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const mode = runtime_abi.mode(frame.rdx) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const flags = runtime_vfs.OpenFlags{
        .read = (bits & 1) != 0,
        .write = (bits & 2) != 0,
        .create = (bits & 4) != 0,
        .truncate = (bits & 8) != 0,
        .append = (bits & 16) != 0,
    };
    const fd = activeDescriptors().openFile(
        activeVfs(),
        activeProcesses(),
        context.handle,
        path_buffer[0..path_length],
        flags,
        mode,
        current_tick,
    ) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    frame.rax = fd;
    return 0;
}

fn blockAndRetry(
    context: *Context,
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) u64 {
    if (frame.rip < 2) {
        frame.rax = reject(errno_would_block);
        return 0;
    }
    frame.rip -= 2;
    saveContext(context, frame, fx_state);
    blocking_returns +%= 1;
    return 1;
}

fn forceFault(
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
    vector: u16,
    address: u64,
) u64 {
    const index = current_context orelse return 1;
    const context = &contexts[index];
    saveContext(context, frame, fx_state);
    activeProcesses().fault(context.handle, vector, address) catch {};
    faults +%= 1;
    return 1;
}

fn validateImage(image: elf64.Image) !void {
    if (image.load_count == 0) return error.InvalidElf;
    for (image.load_segments[0..image.load_count]) |segment| {
        const start: usize = std.math.cast(usize, segment.virtual_address) orelse return error.UnsupportedAddress;
        const size: usize = std.math.cast(usize, segment.memory_size) orelse return error.UnsupportedAddress;
        const end = std.math.add(usize, start, size) catch return error.UnsupportedAddress;
        if (start < user_base or end > user_base + user_window_bytes) return error.UnsupportedAddress;
        if (rangesOverlap(start, end, trampoline_virtual, trampoline_virtual + page_bytes) or
            rangesOverlap(start, end, stack_virtual, stack_virtual + page_bytes) or
            rangesOverlap(start, end, guard_virtual, guard_virtual + page_bytes)) return error.ReservedAddress;
    }
}

fn loadImage(context: *Context, image: elf64.Image, file: []const u8) !void {
    for (image.load_segments[0..image.load_count]) |segment| {
        const segment_start: usize = @intCast(segment.virtual_address);
        const segment_memory_end: usize = @intCast(segment.virtual_address + segment.memory_size);
        const segment_file_end: usize = @intCast(segment.virtual_address + segment.file_size);
        var page = segment_start & ~(page_bytes - 1);
        while (page < alignForward(segment_memory_end, page_bytes)) : (page += page_bytes) {
            const physical = allocatePage() orelse return error.NoRuntimeFrames;
            const copy_start = @max(page, segment_start);
            const copy_end = @min(page + page_bytes, segment_file_end);
            if (copy_end > copy_start) {
                const source_offset: usize = @intCast(segment.file_offset + copy_start - segment_start);
                const destination_offset = copy_start - page;
                @memcpy(
                    @as([*]u8, @ptrFromInt(physical + destination_offset))[0 .. copy_end - copy_start],
                    file[source_offset .. source_offset + copy_end - copy_start],
                );
            }
            try mapOwned(context, page, physical, segment.writable(), segment.executable());
        }
    }
}

fn mapOwned(context: *Context, virtual: usize, physical: usize, writable: bool, executable: bool) !void {
    if (context.mapping_count >= context.mappings.len) {
        releasePage(physical);
        return error.MappingLimit;
    }
    if (!paging.mapUserPageInSpace(context.space, virtual, physical, writable, executable)) {
        releasePage(physical);
        return error.MappingFailure;
    }
    context.mappings[context.mapping_count] = .{
        .used = true,
        .virtual_address = virtual,
        .physical_address = physical,
    };
    context.mapping_count += 1;
}

const InitialStack = struct { rsp: u64, argc: u64, argv: u64 };

fn buildInitialStack(stack_frame: usize, arguments: []const []const u8) !InitialStack {
    var cursor = page_bytes;
    var addresses: [runtime_process.maximum_arguments]u64 = @splat(0);
    var index = arguments.len;
    while (index != 0) {
        index -= 1;
        const argument = arguments[index];
        if (argument.len > runtime_process.maximum_argument_length or cursor < argument.len + 1) return error.ArgumentTooLong;
        cursor -= argument.len + 1;
        const target = @as([*]u8, @ptrFromInt(stack_frame + cursor))[0 .. argument.len + 1];
        @memcpy(target[0..argument.len], argument);
        target[argument.len] = 0;
        addresses[index] = stack_virtual + cursor;
    }
    cursor &= ~@as(usize, 0xF);
    const vector_bytes = (arguments.len + 2) * @sizeOf(u64);
    if (cursor < vector_bytes) return error.StackOverflow;
    cursor -= vector_bytes;
    const words = @as([*]u64, @ptrFromInt(stack_frame + cursor))[0 .. arguments.len + 2];
    words[0] = arguments.len;
    for (addresses[0..arguments.len], 0..) |address, argument_index| words[argument_index + 1] = address;
    words[arguments.len + 1] = 0;
    return .{
        .rsp = stack_virtual + cursor,
        .argc = arguments.len,
        .argv = stack_virtual + cursor + @sizeOf(u64),
    };
}

fn releaseMappings(index: usize) bool {
    const context = &contexts[index];
    for (context.mappings[0..context.mapping_count]) |mapping| {
        if (!mapping.used) continue;
        const info = paging.inspectUserPageInSpace(context.space, mapping.virtual_address) orelse return false;
        if (info.physical_address != mapping.physical_address) return false;
    }
    for (context.mappings[0..context.mapping_count]) |mapping| {
        if (!mapping.used) continue;
        if (!paging.unmapUserPageInSpace(context.space, mapping.virtual_address, mapping.physical_address)) return false;
    }
    if (!paging.userAddressSpaceEmpty(context.space)) return false;
    for (context.mappings[0..context.mapping_count]) |*mapping| {
        if (!mapping.used) continue;
        releasePage(mapping.physical_address);
        mapping.used = false;
    }
    context.mapping_count = 0;
    for (&context.table_frames) |*frame| {
        if (frame.* != 0) releasePage(frame.*);
        frame.* = 0;
    }
    context.space = .{ .pml4_address = 0, .pdpt_address = 0, .directory_address = 0, .table_address = 0, .table_pages = 0 };
    return true;
}

fn releaseContext(index: usize) void {
    if (!contexts[index].used) return;
    if (contexts[index].space.pml4_address != 0) {
        if (!releaseMappings(index)) return;
    } else {
        for (&contexts[index].table_frames) |*frame| {
            if (frame.* != 0) releasePage(frame.*);
            frame.* = 0;
        }
    }
    contexts[index] = .{};
}

fn rollbackProcess(parent_handle: u64, handle: u64) void {
    _ = activeDescriptors().releaseProcess(activeVfs(), activeProcesses(), handle) catch 0;
    activeProcesses().exit(handle, 0x7F00_0002) catch {};
    _ = activeProcesses().wait(parent_handle, handle, true) catch null;
}

fn allocatePage() ?usize {
    for (&arena_used, 0..) |*used, index| {
        if (used.*) continue;
        used.* = true;
        const physical = arena_base + index * page_bytes;
        @memset(@as([*]u8, @ptrFromInt(physical))[0..page_bytes], 0);
        var count: usize = 0;
        for (arena_used) |entry| if (entry) {
            count += 1;
        };
        peak_pages = @max(peak_pages, count);
        return physical;
    }
    return null;
}

fn releasePage(physical: usize) void {
    if (physical < arena_base or physical >= arena_base + arena_pages * page_bytes) return;
    const offset = physical - arena_base;
    if ((offset & (page_bytes - 1)) != 0) return;
    const index = offset / page_bytes;
    if (!arena_used[index]) return;
    @memset(@as([*]u8, @ptrFromInt(physical))[0..page_bytes], 0);
    arena_used[index] = false;
    reclaimed_pages +%= 1;
}

fn findFreeContext() ?usize {
    for (contexts, 0..) |context, index| if (!context.used) return index;
    return null;
}

fn findContext(handle: u64) ?usize {
    for (contexts, 0..) |context, index| if (context.used and context.handle == handle) return index;
    return null;
}

fn descriptorKind(handle: u64, fd: u16) ?runtime_fd.DescriptionKind {
    const snapshot = activeDescriptors().snapshot(activeVfs(), activeProcesses(), handle) catch return null;
    for (snapshot.entries[0..snapshot.count]) |entry| if (entry.fd == fd) return entry.kind;
    return null;
}

fn validFrame(context: Context, frame: *const interrupt_context.Frame) bool {
    if (frame.cs != descriptor_tables.user_code_selector or frame.ss != descriptor_tables.user_data_selector) return false;
    if (frame.rsp < stack_virtual or frame.rsp >= stack_virtual + page_bytes) return false;
    return paging.translateUserAddressInSpace(context.space, @intCast(frame.rip), false, true) != null;
}

fn saveContext(
    context: *Context,
    frame: *const interrupt_context.Frame,
    fx_state: *align(16) const interrupt_context.FxState,
) void {
    context.frame = frame.*;
    copyFx(&context.fx_state, fx_state);
}

fn copyFx(destination: *align(16) interrupt_context.FxState, source: *align(16) const interrupt_context.FxState) void {
    @memcpy(destination.bytes[0..], source.bytes[0..]);
}

fn validateRange(context: Context, address: u64, length: usize, write: bool) bool {
    if (length == 0) return true;
    const end = std.math.add(u64, address, length - 1) catch return false;
    var page: usize = @as(usize, @intCast(address)) & ~(page_bytes - 1);
    const final_page: usize = @as(usize, @intCast(end)) & ~(page_bytes - 1);
    while (true) {
        if (paging.translateUserAddressInSpace(context.space, page, write, false) == null) return false;
        if (page == final_page) break;
        page += page_bytes;
    }
    return true;
}

fn copyFromUser(context: Context, address: u64, destination: []u8) bool {
    var offset: usize = 0;
    while (offset < destination.len) {
        const virtual = std.math.add(u64, address, offset) catch return false;
        const physical = paging.translateUserAddressInSpace(context.space, @intCast(virtual), false, false) orelse return false;
        const count = @min(destination.len - offset, page_bytes - (@as(usize, @intCast(virtual)) & (page_bytes - 1)));
        @memcpy(destination[offset .. offset + count], @as([*]const u8, @ptrFromInt(physical))[0..count]);
        offset += count;
    }
    return true;
}

fn copyToUser(context: Context, address: u64, source: []const u8) bool {
    var offset: usize = 0;
    while (offset < source.len) {
        const virtual = std.math.add(u64, address, offset) catch return false;
        const physical = paging.translateUserAddressInSpace(context.space, @intCast(virtual), true, false) orelse return false;
        const count = @min(source.len - offset, page_bytes - (@as(usize, @intCast(virtual)) & (page_bytes - 1)));
        @memcpy(@as([*]u8, @ptrFromInt(physical))[0..count], source[offset .. offset + count]);
        offset += count;
    }
    return true;
}

fn copyUserString(context: Context, address: u64, destination: []u8) ?usize {
    if (destination.len == 0) return null;
    for (0..destination.len - 1) |index| {
        var byte: [1]u8 = undefined;
        const virtual = std.math.add(u64, address, index) catch return null;
        if (!copyFromUser(context, virtual, &byte)) return null;
        if (byte[0] == 0) return index;
        destination[index] = byte[0];
    }
    return null;
}

fn appendOutput(context: *Context, bytes: []const u8) void {
    const count = @min(bytes.len, context.output.len - context.output_length);
    if (count != 0) @memcpy(context.output[context.output_length .. context.output_length + count], bytes[0..count]);
    context.output_length += count;
    context.output_truncated = context.output_truncated or count != bytes.len;
}

fn activeVfs() *runtime_vfs.Vfs {
    return vfs_pointer orelse unreachable;
}

fn activeProcesses() *runtime_process.Table {
    return process_pointer orelse unreachable;
}

fn activeDescriptors() *runtime_fd.System {
    return descriptor_pointer orelse unreachable;
}

fn alignForward(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

fn rangesOverlap(left_start: usize, left_end: usize, right_start: usize, right_end: usize) bool {
    return left_start < right_end and right_start < left_end;
}

fn reject(code: i64) u64 {
    return @bitCast(code);
}
