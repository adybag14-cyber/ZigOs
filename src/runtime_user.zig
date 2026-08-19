const std = @import("std");
const descriptor_tables = @import("descriptor_tables.zig");
const elf64 = @import("elf64.zig");
const e1000e = @import("e1000e.zig");
const interrupt_context = @import("interrupt_context.zig");
const memory = @import("memory.zig");
const paging = @import("paging.zig");
const runtime_abi = @import("runtime_abi.zig");
const runtime_fd = @import("runtime_fd.zig");
const runtime_process = @import("runtime_process.zig");
const runtime_page_pool = @import("runtime_page_pool.zig");
const runtime_vfs = @import("runtime_vfs.zig");
const serial = @import("serial.zig");
const tcp = @import("tcp.zig");
const tcp_connection = @import("tcp_connection.zig");

const cc = std.os.uefi.cc;
const page_bytes: usize = @intCast(memory.page_size);
const page_limit: usize = runtime_page_pool.maximum_pages;
const maximum_contexts: usize = runtime_process.maximum_processes;
const maximum_mappings: usize = 1024;
const maximum_page_tables: usize = 64;
const maximum_output_bytes: usize = 4096;
const maximum_io_bytes: usize = 1024;
const maximum_directory_batch: usize = maximum_io_bytes / @sizeOf(runtime_abi.DirectoryEntry);
const maximum_poll_descriptors: usize = maximum_io_bytes / @sizeOf(runtime_abi.PollDescriptor);
const maximum_socket_slots: usize = 8;
const maximum_tcp_backlog: usize = 4;
const tcp_ephemeral_port_first: u16 = 49_152;
const tcp_ephemeral_port_last: u16 = 65_535;
const tcp_ephemeral_port_count: u32 = @as(u32, tcp_ephemeral_port_last) - tcp_ephemeral_port_first + 1;
const tcp_receive_window: u16 = 32_768;
const tcp_retransmission_policy = tcp_connection.RetransmissionPolicy{
    .initial_timeout_ticks = 10,
    .maximum_timeout_ticks = 40,
    .maximum_retries = 3,
};
const stack_pages: usize = 8;
const user_base: usize = 0x0000_0080_0000_0000;
const user_window_bytes: usize = 1024 * 1024 * 1024;
const user_end: usize = user_base + user_window_bytes;
const trampoline_virtual: usize = user_end - page_bytes;
const stack_top: usize = trampoline_virtual;
const stack_virtual: usize = stack_top - stack_pages * page_bytes;
const guard_virtual: usize = stack_virtual - page_bytes;
const mmap_floor: usize = user_base + 64 * 1024 * 1024;
const mmap_ceiling: usize = guard_virtual;
const page_table_span: usize = 2 * 1024 * 1024;
const maximum_auxiliary_entries: usize = 9;
pub const default_environment = [_][]const u8{
    "PATH=/bin:/persist",
    "HOME=/home/root",
    "TERM=zigos",
    "SHELL=/bin/sh.elf",
};

const syscall = runtime_abi.constants;
const errno_bad_fd = runtime_abi.errno_bad_fd;
const errno_would_block = runtime_abi.errno_would_block;
const errno_fault = runtime_abi.errno_fault;
const errno_invalid = runtime_abi.errno_invalid;
const errno_no_memory = runtime_abi.errno_no_memory;
const errno_no_syscall = runtime_abi.errno_no_syscall;
const wait_nohang: u64 = runtime_abi.wait_nohang;
const wait_process_group: u64 = runtime_abi.wait_process_group;
const wait_allowed: u64 = runtime_abi.wait_allowed;

const fault_trampoline = [_]u8{
    0xB8, @truncate(syscall.syscall_fault_return), 0x00, 0x00, 0x00, // mov eax, SYS_FAULT_RETURN
    0xCD, 0x80, // int 0x80
    0x0F, 0x0B, // ud2 if the kernel incorrectly resumes it
};

pub const SpawnRegisters = struct {
    override: bool = false,
    rdi: u64 = 0,
    rsi: u64 = 0,
    rdx: u64 = 0,
};

const SpawnDescriptorMap = struct {
    enabled: bool = false,
    stdin_source: ?u16 = null,
    stdout_source: ?u16 = null,
};

pub const Report = struct {
    page_limit: usize,
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
    shared_pages: usize,
    file_mapping_pages: usize,
    allocator_allocations: u64,
    allocator_releases: u64,
    allocator_retains: u64,
    allocator_out_of_memory: u64,
    allocator_rejections: u64,
    allocator_clean: bool,
};

const MappingKind = enum(u8) {
    image,
    trampoline,
    stack,
    heap,
    anonymous,
    file_shared,
};

const Mapping = struct {
    used: bool = false,
    virtual_address: usize = 0,
    physical_address: usize = 0,
    writable: bool = false,
    executable: bool = false,
    kind: MappingKind = .anonymous,
    file_node: u16 = runtime_vfs.invalid_node,
    file_generation: u16 = 0,
    file_slot: u8 = 0,
};

const PageTable = struct {
    used: bool = false,
    virtual_base: usize = 0,
    physical_address: usize = 0,
};

const SocketProtocol = enum(u8) {
    udp,
    tcp,
};

const TcpConnectStatus = enum(u8) {
    connecting,
    established,
    refused,
    timed_out,
    io_failed,
};

const TcpSocketState = struct {
    local_port: u16,
    peer_ipv4: [4]u8,
    peer_mac: [6]u8,
    peer_port: u16,
    control: tcp_connection.ControlBlock,
    status: TcpConnectStatus = .connecting,
};

const TcpPendingConnection = struct {
    used: bool = false,
    peer_ipv4: [4]u8 = @splat(0),
    peer_mac: [6]u8 = @splat(0),
    peer_port: u16 = 0,
    control: ?tcp_connection.ControlBlock = null,
};

const TcpListenerState = struct {
    local_port: u16,
    backlog: u8,
    pending: [maximum_tcp_backlog]TcpPendingConnection = @splat(.{}),
};

const SocketSlot = struct {
    used: bool = false,
    generation: u32 = 0,
    protocol: SocketProtocol = .udp,
    udp: ?e1000e.UdpSocket = null,
    tcp: ?TcpSocketState = null,
    tcp_bound_port: u16 = 0,
    listener: ?TcpListenerState = null,
    nonblocking: bool = false,
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
    page_tables: [maximum_page_tables]PageTable = @splat(.{}),
    page_table_count: usize = 0,
    mappings: [maximum_mappings]Mapping = @splat(.{}),
    mapping_count: usize = 0,
    image_end: usize = user_base,
    brk_base: usize = user_base,
    brk_current: usize = user_base,
    brk_limit: usize = mmap_floor - page_bytes,
    mmap_hint: usize = mmap_floor,
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
var page_pool: runtime_page_pool.Pool = .{};
var contexts: [maximum_contexts]Context = @splat(.{});
var socket_slots: [maximum_socket_slots]SocketSlot = @splat(.{});
var next_tcp_ephemeral_port: u16 = tcp_ephemeral_port_first;
var baseline_fx: interrupt_context.FxState align(16) = std.mem.zeroes(interrupt_context.FxState);
var current_context: ?usize = null;
var user_active = false;
var current_tick: u64 = 0;
var launches: u64 = 0;
var exits: u64 = 0;
var faults: u64 = 0;
var preemptions: u64 = 0;
var blocking_returns: u64 = 0;
var syscall_count: u64 = 0;

pub const ShutdownFn = *const fn (context: ?*anyopaque, process_handle: u64) bool;
pub const SyncFn = *const fn (context: ?*anyopaque) i64;
pub const SyncFileFn = *const fn (context: ?*anyopaque, node: u16, include_metadata: bool) i64;
pub const FscheckFn = *const fn (context: ?*anyopaque) i64;
pub const ChildSpawnFn = *const fn (parent_handle: u64, child_handle: u64) bool;
var system_context: ?*anyopaque = null;
var shutdown_fn: ?ShutdownFn = null;
var sync_fn: ?SyncFn = null;
var sync_file_fn: ?SyncFileFn = null;
var fscheck_fn: ?FscheckFn = null;
var child_spawn_fn: ?ChildSpawnFn = null;
var normal_boot_capability: bool = false;
var persistent_storage_capability: bool = false;

pub fn setSystemBackend(
    context: ?*anyopaque,
    shutdown_callback: ?ShutdownFn,
    sync_callback: ?SyncFn,
    sync_file_callback: ?SyncFileFn,
    fscheck_callback: ?FscheckFn,
    normal_boot: bool,
    persistent_storage: bool,
) void {
    system_context = context;
    shutdown_fn = shutdown_callback;
    sync_fn = sync_callback;
    sync_file_fn = sync_file_callback;
    fscheck_fn = fscheck_callback;
    normal_boot_capability = normal_boot;
    persistent_storage_capability = persistent_storage;
}

pub fn setChildSpawnCallback(callback: ?ChildSpawnFn) void {
    child_spawn_fn = callback;
}

pub fn initialize(
    physical_memory: *memory.PhysicalMemoryManager,
    vfs: *runtime_vfs.Vfs,
    processes: *runtime_process.Table,
    descriptors: *runtime_fd.System,
) !void {
    if (initialized) return error.AlreadyInitialized;
    if (!paging.noExecuteEnabled() and !paging.enableNoExecute()) return error.NoExecuteUnavailable;
    vfs_pointer = vfs;
    process_pointer = processes;
    descriptor_pointer = descriptors;
    @memset(std.mem.asBytes(&contexts), 0);
    for (0..contexts.len) |index| initializeContextDefaults(&contexts[index]);
    socket_slots = @splat(.{});
    next_tcp_ephemeral_port = tcp_ephemeral_port_first;
    descriptors.setExternalBackend(null, closeExternalSocket, pollExternalSocket);
    zigos_fxsave(&baseline_fx);
    current_context = null;
    user_active = false;
    current_tick = 0;
    launches = 0;
    exits = 0;
    faults = 0;
    preemptions = 0;
    blocking_returns = 0;
    syscall_count = 0;
    system_context = null;
    shutdown_fn = null;
    sync_fn = null;
    sync_file_fn = null;
    fscheck_fn = null;
    child_spawn_fn = null;
    normal_boot_capability = false;
    persistent_storage_capability = false;
    try page_pool.initializeManager(physical_memory, page_limit, memory.four_gib, true);
    if (page_pool.report().capacity != page_limit) return error.RuntimePagePoolUnavailable;
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
    return spawnWithEnvironment(
        parent_handle,
        name,
        arguments,
        &default_environment,
        cwd_node,
        image_bytes,
        tick,
        registers,
    );
}

pub fn spawnWithEnvironment(
    parent_handle: u64,
    name: []const u8,
    arguments: []const []const u8,
    environment: []const []const u8,
    cwd_node: u16,
    image_bytes: []const u8,
    tick: u64,
    registers: SpawnRegisters,
) !u64 {
    return spawnWithEnvironmentGroup(parent_handle, name, arguments, environment, cwd_node, image_bytes, tick, registers, .inherit, .{});
}

fn spawnWithEnvironmentGroup(
    parent_handle: u64,
    name: []const u8,
    arguments: []const []const u8,
    environment: []const []const u8,
    cwd_node: u16,
    image_bytes: []const u8,
    tick: u64,
    registers: SpawnRegisters,
    group: runtime_process.SpawnGroup,
    descriptor_map: SpawnDescriptorMap,
) !u64 {
    if (!initialized) return error.NotInitialized;
    if (arguments.len == 0 or arguments.len > syscall.maximum_arguments) return error.TooManyArguments;
    if (environment.len > syscall.maximum_environment) return error.TooManyArguments;
    const image = elf64.parse(image_bytes) orelse return error.InvalidElf;
    try validateImage(image);
    const context_index = findFreeContext() orelse return error.ContextLimit;
    const processes = activeProcesses();
    const parent = try processes.get(parent_handle);
    // G242 stores setuid/setgid as inode metadata only. Process creation never
    // consumes executable mode/owner metadata; children inherit caller credentials.
    const limits = runtime_process.Limits{
        .maximum_pages = maximum_mappings + maximum_page_tables + 3,
        .maximum_descriptors = runtime_fd.maximum_descriptors_per_process,
        .maximum_sockets = maximum_socket_slots,
        .maximum_children = maximum_contexts - 1,
        .maximum_cpu_ticks = 100_000,
    };
    const handle = switch (group) {
        .inherit => try processes.spawn(parent_handle, .userspace, name, arguments, cwd_node, parent.uid, parent.gid, tick, limits),
        .new_pipeline, .join_pipeline => try processes.spawnPipeline(parent_handle, .userspace, name, arguments, cwd_node, parent.uid, parent.gid, tick, limits, group),
    };
    errdefer rollbackProcess(parent_handle, handle);
    _ = try activeDescriptors().cloneProcess(processes, parent_handle, handle);
    if (descriptor_map.enabled) {
        _ = try activeDescriptors().configurePipelineChild(
            activeVfs(),
            processes,
            handle,
            descriptor_map.stdin_source,
            descriptor_map.stdout_source,
        );
    }

    try installContext(
        context_index,
        handle,
        arguments,
        environment,
        image,
        image_bytes,
        registers,
    );
    launches +%= 1;
    return handle;
}

pub fn attachExisting(
    handle: u64,
    arguments: []const []const u8,
    environment: []const []const u8,
    image_bytes: []const u8,
    registers: SpawnRegisters,
) !void {
    if (!initialized) return error.NotInitialized;
    if (arguments.len == 0 or arguments.len > syscall.maximum_arguments) return error.TooManyArguments;
    if (environment.len > syscall.maximum_environment) return error.TooManyArguments;
    if (findContext(handle) != null) return error.ContextAlreadyExists;
    const process = try activeProcesses().get(handle);
    if (process.kind != .userspace or process.terminal()) return error.InvalidProcessState;
    const image = elf64.parse(image_bytes) orelse return error.InvalidElf;
    try validateImage(image);
    const context_index = findFreeContext() orelse return error.ContextLimit;
    try installContext(
        context_index,
        handle,
        arguments,
        environment,
        image,
        image_bytes,
        registers,
    );
    launches +%= 1;
}

fn installContext(
    context_index: usize,
    handle: u64,
    arguments: []const []const u8,
    environment: []const []const u8,
    image: elf64.Image,
    image_bytes: []const u8,
    registers: SpawnRegisters,
) !void {
    const processes = activeProcesses();
    const context = resetContext(context_index);
    context.used = true;
    context.handle = handle;
    errdefer releaseContext(context_index);
    for (&context.table_frames) |*frame| {
        frame.* = allocatePage(context.handle) orelse return error.NoRuntimeFrames;
    }
    context.space = paging.createUserAddressSpaceFromFrames(context.table_frames) orelse return error.AddressSpaceFailure;
    context.page_tables[0] = .{
        .used = true,
        .virtual_base = user_base,
        .physical_address = context.table_frames[3],
    };
    context.page_table_count = 1;
    try loadImage(context, image, image_bytes);
    context.brk_base = alignForward(context.image_end + page_bytes, page_bytes);
    context.brk_current = context.brk_base;
    if (context.brk_base >= context.brk_limit) return error.AddressSpaceFailure;

    const trampoline_frame = allocatePage(context.handle) orelse return error.NoRuntimeFrames;
    @memcpy(@as([*]u8, @ptrFromInt(trampoline_frame))[0..fault_trampoline.len], &fault_trampoline);
    try mapOwned(context, trampoline_virtual, trampoline_frame, false, true, .trampoline);

    var top_stack_frame: usize = 0;
    for (0..stack_pages) |stack_index| {
        const stack_frame = allocatePage(context.handle) orelse return error.NoRuntimeFrames;
        const virtual = stack_virtual + stack_index * page_bytes;
        try mapOwned(context, virtual, stack_frame, true, false, .stack);
        if (stack_index + 1 == stack_pages) top_stack_frame = stack_frame;
    }
    if (paging.inspectUserPageInSpace(context.space, guard_virtual) != null) return error.GuardMapped;

    const child_process = try processes.get(handle);
    const stack = try buildInitialStack(
        top_stack_frame,
        stack_top - page_bytes,
        arguments,
        environment,
        child_process.uid,
        child_process.gid,
        availableCapabilities(),
    );
    context.frame = std.mem.zeroes(interrupt_context.Frame);
    context.frame.rip = image.entry;
    context.frame.cs = descriptor_tables.user_code_selector;
    context.frame.rflags = 0x202;
    context.frame.rsp = stack.rsp;
    context.frame.ss = descriptor_tables.user_data_selector;
    context.frame.rdi = stack.argc;
    context.frame.rsi = stack.argv;
    context.frame.rdx = stack.envp;
    context.frame.rcx = stack.auxv;
    if (registers.override) {
        context.frame.rdi = registers.rdi;
        context.frame.rsi = registers.rsi;
        context.frame.rdx = registers.rdx;
    }
    copyFx(&context.fx_state, &baseline_fx);
    context.image_hash = image.file_hash;
    context.image_bytes = image_bytes.len;
    try syncMemoryUsage(context);
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
    if (!paging.kernelAddressSpaceHealthy() or !paging.currentAddressSpaceSharesKernel())
        return error.KernelAddressSpaceCorrupt;
    user_active = false;
    current_context = null;
    if (!paging.activateKernelAddressSpace()) return error.KernelAddressSpaceRestore;

    process = try activeProcesses().get(handle);
    if (process.state == .running) try activeProcesses().setRunnable(handle);
    if (process.terminal()) try finalize(handle);
}

pub fn serviceOne(tick: u64) !?u64 {
    if (!initialized or user_active) return error.InvalidDispatchState;
    var scanned: usize = 0;
    while (scanned < runtime_process.maximum_processes) : (scanned += 1) {
        const handle = activeProcesses().scheduleNextKind(.userspace, null) orelse return null;
        const context_index = findContext(handle) orelse {
            activeProcesses().setRunnable(handle) catch {};
            continue;
        };
        const process = activeProcesses().get(handle) catch continue;
        if (process.terminal()) {
            try finalize(handle);
            continue;
        }
        if (!contexts[context_index].used) continue;
        try dispatch(handle, tick);
        return handle;
    }
    return null;
}

pub fn handleSyscall(
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) u64 {
    if (!isActive()) return 1;
    const index = current_context orelse return 1;
    const context = &contexts[index];
    if (!validFrame(context, frame)) return forceFault(frame, fx_state, 13, frame.rip);
    activeProcesses().accountSyscall(context.handle) catch return forceFault(frame, fx_state, 13, frame.rip);
    syscall_count +%= 1;

    switch (frame.rax) {
        syscall.syscall_exit => {
            activeProcesses().exit(context.handle, @truncate(frame.rdi)) catch {};
            exits +%= 1;
            saveContext(context, frame, fx_state);
            return 1;
        },
        syscall.syscall_write => return syscallWrite(context, frame, fx_state),
        syscall.syscall_read => return syscallRead(context, frame, fx_state),
        syscall.syscall_writev => return syscallWritev(context, frame, fx_state),
        syscall.syscall_readv => return syscallReadv(context, frame, fx_state),
        syscall.syscall_getpid => {
            const process = activeProcesses().get(context.handle) catch return forceFault(frame, fx_state, 13, frame.rip);
            frame.rax = process.pid;
            return 0;
        },
        syscall.syscall_sleep => {
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
        syscall.syscall_yield => {
            frame.rax = 0;
            saveContext(context, frame, fx_state);
            activeProcesses().setRunnable(context.handle) catch {};
            blocking_returns +%= 1;
            return 1;
        },
        syscall.syscall_pipe => {
            if (!validateRange(context, frame.rdi, 8, true)) {
                frame.rax = reject(errno_fault);
                return 0;
            }
            const fds = activeDescriptors().createPipe(activeProcesses(), context.handle) catch |err| {
                frame.rax = reject(runtime_abi.fromError(err));
                return 0;
            };
            const values = [2]u32{ fds[0], fds[1] };
            if (!copyToUser(context, frame.rdi, std.mem.asBytes(&values))) {
                activeDescriptors().close(activeVfs(), activeProcesses(), context.handle, fds[0]) catch {};
                activeDescriptors().close(activeVfs(), activeProcesses(), context.handle, fds[1]) catch {};
                frame.rax = reject(errno_fault);
                return 0;
            }
            frame.rax = 0;
            return 0;
        },
        syscall.syscall_close => {
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
        syscall.syscall_dup => {
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
        syscall.syscall_dup2 => {
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
        syscall.syscall_open => return syscallOpen(context, frame),
        syscall.syscall_ticks => {
            frame.rax = current_tick;
            return 0;
        },
        syscall.syscall_spawn => return syscallSpawn(context, frame),
        syscall.syscall_wait => return syscallWait(context, frame, fx_state),
        syscall.syscall_abi_query => return syscallAbiQuery(context, frame),
        syscall.syscall_mmap => return syscallMmap(context, frame),
        syscall.syscall_munmap => return syscallMunmap(context, frame),
        syscall.syscall_mprotect => return syscallMprotect(context, frame),
        syscall.syscall_brk => return syscallBrk(context, frame),
        syscall.syscall_fstat => return syscallFstat(context, frame),
        syscall.syscall_getdents => return syscallGetdents(context, frame),
        syscall.syscall_poll => return syscallPoll(context, frame),
        syscall.syscall_socket => return syscallSocket(context, frame),
        syscall.syscall_bind => return syscallBind(context, frame),
        syscall.syscall_connect => return syscallConnect(context, frame, fx_state),
        syscall.syscall_listen => return syscallListen(context, frame),
        syscall.syscall_send => return syscallSend(context, frame),
        syscall.syscall_recv => return syscallRecv(context, frame, fx_state),
        syscall.syscall_getsockname => return syscallGetSockName(context, frame),
        syscall.syscall_sendto => return syscallSendTo(context, frame),
        syscall.syscall_recvfrom => return syscallRecvFrom(context, frame, fx_state),
        syscall.syscall_getpeername => return syscallGetPeerName(context, frame),
        syscall.syscall_setnonblock => return syscallSetNonblocking(context, frame),
        syscall.syscall_ioctl => return syscallIoctl(context, frame),
        syscall.syscall_stat => return syscallStat(context, frame),
        syscall.syscall_statfs => return syscallStatfs(context, frame),
        syscall.syscall_stattimes => return syscallStatTimes(context, frame),
        syscall.syscall_statowner => return syscallStatOwner(context, frame),
        syscall.syscall_openat => return syscallOpenAt(context, frame),
        syscall.syscall_fsync => return syscallFsync(context, frame, fx_state),
        syscall.syscall_fdatasync => return syscallFdatasync(context, frame, fx_state),
        syscall.syscall_mount => return syscallMount(context, frame),
        syscall.syscall_umount => return syscallUmount(context, frame),
        syscall.syscall_symlink => return syscallSymlink(context, frame),
        syscall.syscall_readlink => return syscallReadlink(context, frame),
        syscall.syscall_link => return syscallLink(context, frame),
        syscall.syscall_fallocate => return syscallFallocate(context, frame),
        syscall.syscall_shutdown => return syscallShutdown(context, frame, fx_state),
        syscall.syscall_getcwd => return syscallGetcwd(context, frame),
        syscall.syscall_chdir => return syscallChdir(context, frame),
        syscall.syscall_spawnv => return syscallSpawnv(context, frame),
        syscall.syscall_sync => return syscallSync(context, frame, fx_state),
        syscall.syscall_lseek => return syscallLseek(context, frame),
        syscall.syscall_mkdir => return syscallMkdir(context, frame),
        syscall.syscall_unlink => return syscallUnlink(context, frame),
        syscall.syscall_rmdir => return syscallRmdir(context, frame),
        syscall.syscall_rename => return syscallRename(context, frame),
        syscall.syscall_chmod => return syscallChmod(context, frame),
        syscall.syscall_umask => return syscallUmask(context, frame),
        syscall.syscall_flock => return syscallFlock(context, frame, fx_state),
        syscall.syscall_lockrange => return syscallLockRange(context, frame, fx_state),
        syscall.syscall_watchdir => return syscallWatchDir(context, frame),
        syscall.syscall_kill => return syscallKill(context, frame, fx_state),
        syscall.syscall_fscheck => return syscallFscheck(context, frame, fx_state),
        syscall.syscall_fault_return => {
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

pub fn validateSyscallReturn(
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
    disposition: u64,
    syscall_number: u64,
) u64 {
    if (!paging.kernelAddressSpaceHealthy() or !paging.currentAddressSpaceSharesKernel()) return 1;
    if (disposition != 0 or !isActive()) return disposition;
    const index = current_context orelse return 1;
    const context = &contexts[index];
    const failure: u8, const observed: u64 = if (frame.cs != descriptor_tables.user_code_selector)
        .{ 1, frame.cs }
    else if (frame.ss != descriptor_tables.user_data_selector)
        .{ 2, frame.ss }
    else if (frame.rsp < stack_virtual or frame.rsp >= stack_top)
        .{ 3, frame.rsp }
    else if (paging.translateUserAddressInSpace(context.space, @intCast(frame.rip), false, true) == null)
        .{ 4, frame.rip }
    else if ((frame.rflags & 0x2) == 0 or (frame.rflags & ((@as(u64, 3) << 12) | (@as(u64, 1) << 14) | (@as(u64, 1) << 17))) != 0)
        .{ 5, frame.rflags }
    else
        return 0;

    const diagnostic = (@as(u64, failure) << 56) |
        ((syscall_number & 0xFF) << 48) |
        (observed & 0x0000_FFFF_FFFF_FFFF);
    saveContext(context, frame, fx_state);
    activeProcesses().fault(context.handle, 13, diagnostic) catch {};
    faults +%= 1;
    return 1;
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
    if (user_active) {
        const running_index = current_context orelse return error.InvalidDispatchState;
        if (running_index == index) return error.ContextActive;
        const running_root = contexts[running_index].space.pml4_address;
        if (paging.currentCr3Address() != running_root or paging.activePml4Address() != running_root)
            return error.ActiveAddressSpaceMismatch;
    } else {
        if (!paging.kernelAddressSpaceHealthy()) return error.KernelAddressSpaceCorrupt;
        if (!paging.activateKernelAddressSpace()) return error.KernelAddressSpaceRestore;
    }
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
    _ = resetContext(index);
}

pub fn finalizeTerminalContexts() !usize {
    var finalized: usize = 0;
    for (0..contexts.len) |index| {
        if (!contexts[index].used or contexts[index].resources_released) continue;
        const process = activeProcesses().get(contexts[index].handle) catch continue;
        if (!process.terminal()) continue;
        try finalize(contexts[index].handle);
        finalized += 1;
    }
    return finalized;
}

pub fn sweepReleasedContexts() usize {
    var swept: usize = 0;
    for (0..contexts.len) |index| {
        if (!contexts[index].used or !contexts[index].resources_released) continue;
        _ = activeProcesses().get(contexts[index].handle) catch {
            _ = resetContext(index);
            swept += 1;
            continue;
        };
    }
    return swept;
}

pub fn takeOutput(handle: u64, destination: []u8) usize {
    const index = findContext(handle) orelse return 0;
    const context = &contexts[index];
    const count = @min(destination.len, context.output_length);
    if (count == 0) return 0;
    @memcpy(destination[0..count], context.output[0..count]);
    const remaining = context.output_length - count;
    if (remaining != 0) std.mem.copyForwards(u8, context.output[0..remaining], context.output[count..context.output_length]);
    @memset(context.output[remaining..context.output_length], 0);
    context.output_length = remaining;
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
    const allocator_report = page_pool.report();
    var live_contexts: usize = 0;
    var file_mapping_pages: usize = 0;
    for (0..contexts.len) |context_index| if (contexts[context_index].used) {
        live_contexts += 1;
        for (contexts[context_index].mappings) |mapping|
            file_mapping_pages += @intFromBool(mapping.used and mapping.kind == .file_shared);
    };
    return .{
        .page_limit = allocator_report.capacity,
        .used_pages = allocator_report.active,
        .peak_pages = allocator_report.peak,
        .live_contexts = live_contexts,
        .launches = launches,
        .exits = exits,
        .faults = faults,
        .preemptions = preemptions,
        .blocking_returns = blocking_returns,
        .syscalls = syscall_count,
        .reclaimed_pages = allocator_report.frees,
        .shared_pages = allocator_report.shared,
        .file_mapping_pages = file_mapping_pages,
        .allocator_allocations = allocator_report.allocations,
        .allocator_releases = allocator_report.releases,
        .allocator_retains = allocator_report.retains,
        .allocator_out_of_memory = allocator_report.out_of_memory,
        .allocator_rejections = allocator_report.invalid_addresses + allocator_report.double_frees + allocator_report.owner_mismatches + allocator_report.reference_overflows + allocator_report.backing_failures,
        .allocator_clean = allocator_report.clean,
    };
}

fn syscallLseek(context: *Context, frame: *interrupt_context.Frame) u64 {
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    const whence: runtime_fd.SeekWhence = switch (frame.rdx) {
        syscall.seek_start => .start,
        syscall.seek_current => .current,
        syscall.seek_end => .end,
        else => {
            frame.rax = reject(errno_invalid);
            return 0;
        },
    };
    const position = activeDescriptors().seek(
        activeVfs(),
        activeProcesses(),
        context.handle,
        fd,
        @bitCast(frame.rsi),
        whence,
    ) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    frame.rax = position;
    return 0;
}

fn syscallMkdir(context: *Context, frame: *interrupt_context.Frame) u64 {
    var path_buffer: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0);
    const path_length = copyUserPath(context, frame, frame.rdi, &path_buffer) orelse return 0;
    const mode = runtime_abi.mode(frame.rsi) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const process = activeProcesses().get(context.handle) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    if (!runtime_vfs.validStoredMode(mode)) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    const creation_mode = runtime_vfs.applyCreationUmask(mode, process.umask);
    _ = activeVfs().mkdirOwned(process.cwd_node, path_buffer[0..path_length], creation_mode, .{ .uid = process.uid, .gid = process.gid }, current_tick) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    frame.rax = 0;
    return 0;
}

fn syscallUnlink(context: *Context, frame: *interrupt_context.Frame) u64 {
    return syscallSinglePathMutation(context, frame, .unlink);
}

fn syscallRmdir(context: *Context, frame: *interrupt_context.Frame) u64 {
    return syscallSinglePathMutation(context, frame, .rmdir);
}

const PathMutation = enum { unlink, rmdir };

fn syscallSinglePathMutation(context: *Context, frame: *interrupt_context.Frame, operation: PathMutation) u64 {
    var path_buffer: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0);
    const path_length = copyUserPath(context, frame, frame.rdi, &path_buffer) orelse return 0;
    const process = activeProcesses().get(context.handle) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const path = path_buffer[0..path_length];
    (switch (operation) {
        .unlink => activeVfs().unlinkAs(process.cwd_node, path, .{ .uid = process.uid, .gid = process.gid }, current_tick),
        .rmdir => activeVfs().rmdirAs(process.cwd_node, path, .{ .uid = process.uid, .gid = process.gid }, current_tick),
    }) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    frame.rax = 0;
    return 0;
}

fn syscallRename(context: *Context, frame: *interrupt_context.Frame) u64 {
    var old_buffer: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0);
    var new_buffer: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0);
    const old_length = copyUserPath(context, frame, frame.rdi, &old_buffer) orelse return 0;
    const new_length = copyUserPath(context, frame, frame.rsi, &new_buffer) orelse return 0;
    const process = activeProcesses().get(context.handle) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    activeVfs().renameAs(
        process.cwd_node,
        old_buffer[0..old_length],
        new_buffer[0..new_length],
        .{ .uid = process.uid, .gid = process.gid },
        current_tick,
    ) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    frame.rax = 0;
    return 0;
}

fn syscallChmod(context: *Context, frame: *interrupt_context.Frame) u64 {
    var path_buffer: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0);
    const path_length = copyUserPath(context, frame, frame.rdi, &path_buffer) orelse return 0;
    const mode = runtime_abi.mode(frame.rsi) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if (!runtime_vfs.validStoredMode(mode)) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    const process = activeProcesses().get(context.handle) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    activeVfs().chmodAs(process.cwd_node, path_buffer[0..path_length], mode, .{ .uid = process.uid, .gid = process.gid }, current_tick) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    frame.rax = 0;
    return 0;
}

fn syscallUmask(context: *Context, frame: *interrupt_context.Frame) u64 {
    const mask = runtime_abi.mode(frame.rdi) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if ((mask & ~@as(u16, 0o777)) != 0) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    const previous = activeProcesses().setUmask(context.handle, mask) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    frame.rax = previous;
    return 0;
}

fn syscallFlock(
    context: *Context,
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) u64 {
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    const request = decodeAdvisoryLockRequest(frame.rsi) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const requested = request.lock;
    const nonblocking = request.nonblocking;
    const lock_result = activeDescriptors().flock(
        activeVfs(),
        activeProcesses(),
        context.handle,
        fd,
        requested,
        nonblocking,
    ) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    switch (lock_result) {
        .acquired => {
            frame.rax = 0;
            return 0;
        },
        .blocked => {
            if (nonblocking) {
                frame.rax = reject(errno_would_block);
                return 0;
            }
            return blockAndRetry(context, frame, fx_state);
        },
    }
}

const AdvisoryLockRequest = struct {
    lock: runtime_fd.AdvisoryLock,
    nonblocking: bool,
};

fn decodeAdvisoryLockRequest(operation: u64) ?AdvisoryLockRequest {
    const lock_mask = syscall.flock_shared | syscall.flock_exclusive | syscall.flock_unlock;
    const allowed = lock_mask | syscall.flock_nonblock;
    if ((operation & ~allowed) != 0) return null;
    const mode = operation & lock_mask;
    const nonblocking = (operation & syscall.flock_nonblock) != 0;
    const lock: runtime_fd.AdvisoryLock = if (mode == syscall.flock_shared)
        .shared
    else if (mode == syscall.flock_exclusive)
        .exclusive
    else if (mode == syscall.flock_unlock and !nonblocking)
        .none
    else
        return null;
    return .{ .lock = lock, .nonblocking = nonblocking };
}

fn syscallLockRange(
    context: *Context,
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) u64 {
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    const request = decodeAdvisoryLockRequest(frame.r10) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const lock_result = activeDescriptors().lockRange(
        activeVfs(),
        activeProcesses(),
        context.handle,
        fd,
        frame.rsi,
        frame.rdx,
        request.lock,
        request.nonblocking,
    ) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    switch (lock_result) {
        .acquired => {
            frame.rax = 0;
            return 0;
        },
        .blocked => {
            if (request.nonblocking) {
                frame.rax = reject(errno_would_block);
                return 0;
            }
            return blockAndRetry(context, frame, fx_state);
        },
    }
}

fn syscallWatchDir(context: *Context, frame: *interrupt_context.Frame) u64 {
    const directory_fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    if (frame.rsi != 0 or frame.rdx != 0 or frame.r10 != 0 or frame.r8 != 0 or frame.r9 != 0) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    const fd = activeDescriptors().createDirectoryWatch(
        activeVfs(),
        activeProcesses(),
        context.handle,
        directory_fd,
    ) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    frame.rax = fd;
    return 0;
}

fn syscallSync(
    context: *Context,
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) u64 {
    const callback = sync_fn orelse {
        frame.rax = reject(runtime_abi.errno_no_syscall);
        return 0;
    };
    const user_root = context.space.pml4_address;
    if (paging.currentCr3Address() != user_root or !paging.activateKernelAddressSpace()) {
        frame.rax = reject(runtime_abi.errno_io);
        return 0;
    }
    const result = callback(system_context);
    if (!paging.activateAddressSpace(user_root)) {
        saveContext(context, frame, fx_state);
        activeProcesses().fault(context.handle, 13, user_root) catch {};
        faults +%= 1;
        return 1;
    }
    frame.rax = if (result < 0) reject(result) else @intCast(result);
    return 0;
}

fn syscallFscheck(
    context: *Context,
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) u64 {
    if (frame.rdi != 0 or frame.rsi != 0 or frame.rdx != 0 or frame.r10 != 0 or frame.r8 != 0 or frame.r9 != 0) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    const callback = fscheck_fn orelse {
        frame.rax = reject(runtime_abi.errno_no_syscall);
        return 0;
    };
    const user_root = context.space.pml4_address;
    if (paging.currentCr3Address() != user_root or !paging.activateKernelAddressSpace()) {
        frame.rax = reject(runtime_abi.errno_io);
        return 0;
    }
    const result = callback(system_context);
    if (!paging.activateAddressSpace(user_root)) {
        saveContext(context, frame, fx_state);
        activeProcesses().fault(context.handle, 13, user_root) catch {};
        faults +%= 1;
        return 1;
    }
    frame.rax = if (result < 0) reject(result) else @intCast(result);
    return 0;
}

fn syscallShutdown(
    context: *Context,
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) u64 {
    const process = activeProcesses().get(context.handle) catch {
        frame.rax = reject(runtime_abi.errno_no_process);
        return 0;
    };
    const callback = shutdown_fn orelse {
        frame.rax = reject(runtime_abi.errno_permission);
        return 0;
    };
    if ((process.pid != 1 and process.pid != 2) or !normal_boot_capability or !callback(system_context, context.handle)) {
        frame.rax = reject(runtime_abi.errno_permission);
        return 0;
    }
    frame.rax = 0;
    activeProcesses().exit(context.handle, 0) catch {
        frame.rax = reject(runtime_abi.errno_io);
        return 0;
    };
    exits +%= 1;
    saveContext(context, frame, fx_state);
    return 1;
}

fn syscallKill(context: *Context, frame: *interrupt_context.Frame, fx_state: *align(16) interrupt_context.FxState) u64 {
    const pid = std.math.cast(u32, frame.rdi) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const signal = std.math.cast(u8, frame.rsi) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if (pid == 0 or signal == 0 or signal >= 64) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    const target_handle = activeProcesses().handleForPid(pid) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    activeProcesses().sendSignal(context.handle, target_handle, signal) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const target = activeProcesses().get(target_handle) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    frame.rax = 0;
    if (!target.terminal()) return 0;
    if (target_handle == context.handle) {
        saveContext(context, frame, fx_state);
        return 1;
    }
    finalize(target_handle) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    return 0;
}

fn syscallGetcwd(context: *Context, frame: *interrupt_context.Frame) u64 {
    const capacity: usize = std.math.cast(usize, frame.rsi) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if (capacity == 0 or capacity > runtime_vfs.maximum_path_length + 1 or
        !validateRange(context, frame.rdi, capacity, true))
    {
        frame.rax = reject(errno_fault);
        return 0;
    }
    const process = activeProcesses().get(context.handle) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    var path_buffer: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0);
    const path = activeVfs().canonicalPath(process.cwd_node, &path_buffer) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    if (path.len + 1 > capacity) {
        frame.rax = reject(runtime_abi.errno_name_too_long);
        return 0;
    }
    path_buffer[path.len] = 0;
    if (!copyToUser(context, frame.rdi, path_buffer[0 .. path.len + 1])) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    frame.rax = path.len;
    return 0;
}

fn syscallChdir(context: *Context, frame: *interrupt_context.Frame) u64 {
    var path_buffer: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0);
    const path_length = copyUserPath(context, frame, frame.rdi, &path_buffer) orelse return 0;
    const process = activeProcesses().get(context.handle) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const path = path_buffer[0..path_length];
    const node = activeVfs().resolveDirectoryAs(
        process.cwd_node,
        path,
        .{ .uid = process.uid, .gid = process.gid },
    ) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    activeProcesses().setWorkingDirectory(context.handle, node) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    frame.rax = 0;
    return 0;
}

fn syscallSocket(context: *Context, frame: *interrupt_context.Frame) u64 {
    if (frame.rdi != runtime_abi.address_family_ipv4 or e1000e.activeDevice() == null) {
        frame.rax = reject(runtime_abi.errno_connection_refused);
        return 0;
    }
    const protocol: SocketProtocol = if (frame.rsi == runtime_abi.socket_datagram and
        (frame.rdx == 0 or frame.rdx == runtime_abi.protocol_udp))
        .udp
    else if (frame.rsi == runtime_abi.socket_stream and
        (frame.rdx == 0 or frame.rdx == runtime_abi.protocol_tcp))
        .tcp
    else {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const slot_index = findFreeSocketSlot() orelse {
        frame.rax = reject(runtime_abi.errno_system_file_limit);
        return 0;
    };
    const generation = nextSocketGeneration(socket_slots[slot_index].generation);
    socket_slots[slot_index] = .{ .used = true, .generation = generation, .protocol = protocol };
    const description_kind: runtime_fd.DescriptionKind = if (protocol == .udp) .udp_socket else .tcp_socket;
    const fd = activeDescriptors().createExternalDescriptor(
        activeProcesses(),
        context.handle,
        description_kind,
        .{ .index = @intCast(slot_index), .generation = generation },
        true,
        true,
        true,
    ) catch |err| {
        socket_slots[slot_index] = .{ .generation = generation };
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    frame.rax = fd;
    return 0;
}

fn syscallBind(context: *Context, frame: *interrupt_context.Frame) u64 {
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    const address = readSocketAddress(context, frame.rsi, frame.rdx) orelse {
        frame.rax = reject(errno_fault);
        return 0;
    };
    const slot = socketSlotForDescriptor(context.handle, fd) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const device = e1000e.activeDevice() orelse {
        frame.rax = reject(runtime_abi.errno_connection_refused);
        return 0;
    };
    const address_bytes = socketAddressBytes(&address);
    if (!allZero(address_bytes) and !std.mem.eql(u8, address_bytes, &device.local_ipv4)) {
        frame.rax = reject(runtime_abi.errno_access);
        return 0;
    }
    const requested_port = @byteSwap(address.port_be);
    if (slot.protocol == .udp) {
        if (slot.udp != null) {
            frame.rax = reject(runtime_abi.errno_busy);
            return 0;
        }
        slot.udp = if (requested_port == 0) e1000e.openEphemeralUdpSocket(device) else e1000e.openUdpSocket(device, requested_port);
        if (slot.udp == null) {
            frame.rax = reject(runtime_abi.errno_address_in_use);
            return 0;
        }
        frame.rax = 0;
        return 0;
    }

    if (slot.tcp != null or slot.listener != null or slot.tcp_bound_port != 0) {
        frame.rax = reject(runtime_abi.errno_busy);
        return 0;
    }
    const local_port = if (requested_port == 0)
        allocateTcpEphemeralPort() orelse {
            frame.rax = reject(runtime_abi.errno_address_in_use);
            return 0;
        }
    else blk: {
        if (tcpPortInUse(requested_port)) {
            frame.rax = reject(runtime_abi.errno_address_in_use);
            return 0;
        }
        break :blk requested_port;
    };
    slot.tcp_bound_port = local_port;
    frame.rax = 0;
    return 0;
}

fn syscallListen(context: *Context, frame: *interrupt_context.Frame) u64 {
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    const backlog: usize = std.math.cast(usize, frame.rsi) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if (backlog == 0 or backlog > maximum_tcp_backlog) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    const slot = socketSlotForDescriptor(context.handle, fd) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    if (slot.protocol != .tcp) {
        frame.rax = reject(errno_no_syscall);
        return 0;
    }
    if (slot.tcp != null or slot.listener != null) {
        frame.rax = reject(runtime_abi.errno_busy);
        return 0;
    }
    if (slot.tcp_bound_port == 0) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    slot.listener = .{ .local_port = slot.tcp_bound_port, .backlog = @intCast(backlog) };
    frame.rax = 0;
    return 0;
}

fn syscallConnect(
    context: *Context,
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) u64 {
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    const address = readSocketAddress(context, frame.rsi, frame.rdx) orelse {
        frame.rax = reject(errno_fault);
        return 0;
    };
    const slot = socketSlotForDescriptor(context.handle, fd) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const device = e1000e.activeDevice() orelse {
        frame.rax = reject(runtime_abi.errno_connection_refused);
        return 0;
    };
    if (slot.protocol == .udp) {
        const peer = udpPeerForAddress(device, address) orelse {
            frame.rax = reject(errno_invalid);
            return 0;
        };
        if (slot.udp == null) slot.udp = e1000e.openEphemeralUdpSocket(device);
        const socket = slot.udp orelse {
            frame.rax = reject(runtime_abi.errno_no_space);
            return 0;
        };
        if (!e1000e.connectUdpSocket(device, socket, peer)) {
            frame.rax = reject(runtime_abi.errno_connection_refused);
            return 0;
        }
        frame.rax = 0;
        return 0;
    }

    const peer = tcpPeerForAddress(device, address) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if (slot.listener != null) {
        frame.rax = reject(runtime_abi.errno_busy);
        return 0;
    }
    if (slot.tcp == null) {
        if (!runtimeNetworkReady(device)) {
            frame.rax = reject(runtime_abi.errno_io);
            return 0;
        }
        const local_port = if (slot.tcp_bound_port != 0)
            slot.tcp_bound_port
        else
            allocateTcpEphemeralPort() orelse {
                frame.rax = reject(runtime_abi.errno_address_in_use);
                return 0;
            };
        slot.tcp_bound_port = local_port;
        var control = tcp_connection.init(tcp_receive_window) orelse {
            frame.rax = reject(errno_invalid);
            return 0;
        };
        const slot_index: usize = @intFromPtr(slot) - @intFromPtr(&socket_slots[0]);
        const index = slot_index / @sizeOf(SocketSlot);
        const initial_sequence = tcpInitialSequence(@intCast(index), slot.generation);
        const transition = tcp_connection.beginActiveOpenAt(&control, initial_sequence, current_tick, tcp_retransmission_policy);
        const outbound = transition.outbound orelse {
            frame.rax = reject(runtime_abi.errno_io);
            return 0;
        };
        var connection = TcpSocketState{
            .local_port = local_port,
            .peer_ipv4 = peer.ipv4,
            .peer_mac = peer.mac,
            .peer_port = peer.port,
            .control = control,
        };
        if (!sendTcpControl(device, &connection, outbound)) {
            connection.status = .io_failed;
            slot.tcp = connection;
            frame.rax = reject(runtime_abi.errno_io);
            return 0;
        }
        slot.tcp = connection;
    }

    const connection = &slot.tcp.?;
    if (!tcpPeerMatches(connection, peer)) {
        frame.rax = reject(runtime_abi.errno_busy);
        return 0;
    }
    switch (connection.status) {
        .established => {
            frame.rax = 0;
            return 0;
        },
        .refused => {
            frame.rax = reject(runtime_abi.errno_connection_refused);
            return 0;
        },
        .timed_out, .io_failed => {
            frame.rax = reject(runtime_abi.errno_io);
            return 0;
        },
        .connecting => {},
    }
    if (slot.nonblocking) {
        frame.rax = reject(errno_would_block);
        return 0;
    }
    const resource = socketResourceForSlot(slot) orelse {
        frame.rax = reject(runtime_abi.errno_not_socket);
        return 0;
    };
    activeProcesses().block(context.handle, .socket_write, socketWaitKey(resource.index, resource.generation)) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    return blockAndRetry(context, frame, fx_state);
}

fn syscallSend(context: *Context, frame: *interrupt_context.Frame) u64 {
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    const length: usize = std.math.cast(usize, frame.rdx) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if (runtime_abi.messageFlagBits(frame.r10) == null) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    if (length > maximum_io_bytes or !validateRange(context, frame.rsi, length, false)) {
        frame.rax = reject(if (length > maximum_io_bytes) errno_invalid else errno_fault);
        return 0;
    }
    var bytes: [maximum_io_bytes]u8 = undefined;
    if (length != 0 and !copyFromUser(context, frame.rsi, bytes[0..length])) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    const slot = socketSlotForDescriptor(context.handle, fd) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    if (slot.protocol != .udp) {
        frame.rax = reject(errno_no_syscall);
        return 0;
    }
    const socket = slot.udp orelse {
        frame.rax = reject(runtime_abi.errno_not_connected);
        return 0;
    };
    const device = e1000e.activeDevice() orelse {
        frame.rax = reject(runtime_abi.errno_connection_refused);
        return 0;
    };
    if (!runtimeNetworkReady(device)) {
        frame.rax = reject(runtime_abi.errno_io);
        return 0;
    }
    if (e1000e.sendConnectedUdpDatagram(device, socket, 64, bytes[0..length]) == null) {
        frame.rax = reject(runtime_abi.errno_io);
        return 0;
    }
    frame.rax = length;
    return 0;
}

fn syscallSendTo(context: *Context, frame: *interrupt_context.Frame) u64 {
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    const length: usize = std.math.cast(usize, frame.rdx) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if (runtime_abi.messageFlagBits(frame.r10) == null) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    if (length > maximum_io_bytes or !validateRange(context, frame.rsi, length, false)) {
        frame.rax = reject(if (length > maximum_io_bytes) errno_invalid else errno_fault);
        return 0;
    }
    const address = readSocketAddress(context, frame.r8, frame.r9) orelse {
        frame.rax = reject(errno_fault);
        return 0;
    };
    var bytes: [maximum_io_bytes]u8 = undefined;
    if (length != 0 and !copyFromUser(context, frame.rsi, bytes[0..length])) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    const slot = socketSlotForDescriptor(context.handle, fd) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    if (slot.protocol != .udp) {
        frame.rax = reject(errno_no_syscall);
        return 0;
    }
    const device = e1000e.activeDevice() orelse {
        frame.rax = reject(runtime_abi.errno_connection_refused);
        return 0;
    };
    const peer = udpPeerForAddress(device, address) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if (slot.udp == null) slot.udp = e1000e.openEphemeralUdpSocket(device);
    const socket = slot.udp orelse {
        frame.rax = reject(runtime_abi.errno_no_space);
        return 0;
    };
    if (!runtimeNetworkReady(device)) {
        frame.rax = reject(runtime_abi.errno_io);
        return 0;
    }
    if (e1000e.sendUdpDatagramTo(device, socket, peer, 64, bytes[0..length]) == null) {
        frame.rax = reject(runtime_abi.errno_io);
        return 0;
    }
    frame.rax = length;
    return 0;
}

fn syscallRecv(
    context: *Context,
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) u64 {
    return syscallReceiveDatagram(context, frame, fx_state, false);
}

fn syscallRecvFrom(
    context: *Context,
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) u64 {
    return syscallReceiveDatagram(context, frame, fx_state, true);
}

fn syscallReceiveDatagram(
    context: *Context,
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
    copy_source: bool,
) u64 {
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    const length: usize = std.math.cast(usize, frame.rdx) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const flags = runtime_abi.messageFlagBits(frame.r10) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if (length > maximum_io_bytes or !validateRange(context, frame.rsi, length, true) or
        (copy_source and (frame.r9 < @sizeOf(runtime_abi.Ipv4SocketAddress) or
            !validateRange(context, frame.r8, @sizeOf(runtime_abi.Ipv4SocketAddress), true))))
    {
        frame.rax = reject(if (length > maximum_io_bytes) errno_invalid else errno_fault);
        return 0;
    }
    const resource = activeDescriptors().externalResource(activeProcesses(), context.handle, fd, .udp_socket) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const slot = resolveSocketSlot(resource.index, resource.generation) orelse {
        frame.rax = reject(runtime_abi.errno_not_socket);
        return 0;
    };
    const socket = slot.udp orelse {
        frame.rax = reject(runtime_abi.errno_not_connected);
        return 0;
    };
    const device = e1000e.activeDevice() orelse {
        frame.rax = reject(runtime_abi.errno_connection_refused);
        return 0;
    };
    var bytes: [maximum_io_bytes]u8 = undefined;
    const received = e1000e.receiveUdpInto(device, socket, bytes[0..length]) orelse {
        if (slot.nonblocking or (flags & runtime_abi.message_dontwait) != 0) {
            frame.rax = reject(errno_would_block);
            return 0;
        }
        activeProcesses().block(context.handle, .socket_read, socketWaitKey(resource.index, resource.generation)) catch |err| {
            frame.rax = reject(runtime_abi.fromError(err));
            return 0;
        };
        return blockAndRetry(context, frame, fx_state);
    };
    if (received.copied_length != 0 and !copyToUser(context, frame.rsi, bytes[0..received.copied_length])) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    if (copy_source and !writeSocketAddress(context, frame.r8, frame.r9, received.source_ipv4, received.source_port)) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    frame.rax = received.copied_length;
    return 0;
}

fn syscallGetSockName(context: *Context, frame: *interrupt_context.Frame) u64 {
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    const slot = socketSlotForDescriptor(context.handle, fd) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const device = e1000e.activeDevice() orelse {
        frame.rax = reject(runtime_abi.errno_connection_refused);
        return 0;
    };
    const port = if (slot.protocol == .udp) blk: {
        const socket = slot.udp orelse {
            frame.rax = reject(runtime_abi.errno_not_connected);
            return 0;
        };
        break :blk socket.local_port;
    } else blk: {
        if (slot.tcp) |connection| break :blk connection.local_port;
        if (slot.tcp_bound_port != 0) break :blk slot.tcp_bound_port;
        frame.rax = reject(runtime_abi.errno_not_connected);
        return 0;
    };
    if (!writeSocketAddress(context, frame.rsi, frame.rdx, device.local_ipv4, port)) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    frame.rax = @sizeOf(runtime_abi.Ipv4SocketAddress);
    return 0;
}

fn syscallGetPeerName(context: *Context, frame: *interrupt_context.Frame) u64 {
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    const slot = socketSlotForDescriptor(context.handle, fd) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    var ipv4: [4]u8 = undefined;
    var port: u16 = 0;
    if (slot.protocol == .udp) {
        const socket = slot.udp orelse {
            frame.rax = reject(runtime_abi.errno_not_connected);
            return 0;
        };
        const device = e1000e.activeDevice() orelse {
            frame.rax = reject(runtime_abi.errno_connection_refused);
            return 0;
        };
        const peer = e1000e.udpSocketPeer(device, socket) orelse {
            frame.rax = reject(runtime_abi.errno_not_connected);
            return 0;
        };
        ipv4 = peer.ipv4;
        port = peer.port;
    } else {
        const connection = slot.tcp orelse {
            frame.rax = reject(runtime_abi.errno_not_connected);
            return 0;
        };
        if (connection.status != .established) {
            frame.rax = reject(runtime_abi.errno_not_connected);
            return 0;
        }
        ipv4 = connection.peer_ipv4;
        port = connection.peer_port;
    }
    if (!writeSocketAddress(context, frame.rsi, frame.rdx, ipv4, port)) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    frame.rax = @sizeOf(runtime_abi.Ipv4SocketAddress);
    return 0;
}

fn syscallSetNonblocking(context: *Context, frame: *interrupt_context.Frame) u64 {
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    if (frame.rsi > 1) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    const slot = socketSlotForDescriptor(context.handle, fd) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    slot.nonblocking = frame.rsi != 0;
    frame.rax = 0;
    return 0;
}

fn runtimeNetworkReady(device: *e1000e.Device) bool {
    return e1000e.runtimePollingMode() and e1000e.runtimeMmioAccessible(device);
}

pub fn serviceNetwork() usize {
    const device = e1000e.activeDevice() orelse return 0;
    _ = e1000e.serviceUdpSockets(device, 8);
    var wakeups = serviceTcpConnects(device, current_tick);
    for (socket_slots, 0..) |slot, index| {
        if (!slot.used or slot.protocol != .udp) continue;
        const socket = slot.udp orelse continue;
        if (e1000e.udpSocketReadable(device, socket)) {
            wakeups += activeProcesses().wakeMatching(.socket_read, socketWaitKey(@intCast(index), slot.generation), true);
        }
    }
    return wakeups;
}

fn readSocketAddress(context: *const Context, pointer: u64, size: u64) ?runtime_abi.Ipv4SocketAddress {
    if (size < @sizeOf(runtime_abi.Ipv4SocketAddress) or
        !validateRange(context, pointer, @sizeOf(runtime_abi.Ipv4SocketAddress), false)) return null;
    var address = std.mem.zeroes(runtime_abi.Ipv4SocketAddress);
    if (!copyFromUser(context, pointer, std.mem.asBytes(&address))) return null;
    if (address.family != runtime_abi.address_family_ipv4) return null;
    return address;
}

fn socketAddressBytes(address: *const runtime_abi.Ipv4SocketAddress) *const [4]u8 {
    return @ptrCast(&address.address_be);
}

fn writeSocketAddress(
    context: *const Context,
    pointer: u64,
    size: u64,
    ipv4: [4]u8,
    port: u16,
) bool {
    if (size < @sizeOf(runtime_abi.Ipv4SocketAddress) or
        !validateRange(context, pointer, @sizeOf(runtime_abi.Ipv4SocketAddress), true)) return false;
    var address = runtime_abi.Ipv4SocketAddress{
        .family = runtime_abi.address_family_ipv4,
        .port_be = @byteSwap(port),
        .address_be = 0,
    };
    @memcpy(std.mem.asBytes(&address.address_be), &ipv4);
    return copyToUser(context, pointer, std.mem.asBytes(&address));
}

fn udpPeerForAddress(device: *const e1000e.Device, address: runtime_abi.Ipv4SocketAddress) ?e1000e.UdpPeer {
    const port = @byteSwap(address.port_be);
    const ipv4 = socketAddressBytes(&address).*;
    if (port == 0 or allZero(&ipv4)) return null;
    return .{
        .mac = if (std.mem.eql(u8, &ipv4, &device.local_ipv4)) device.local_mac else device.gateway_mac,
        .ipv4 = ipv4,
        .port = port,
    };
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn findFreeSocketSlot() ?usize {
    for (socket_slots, 0..) |slot, index| if (!slot.used) return index;
    return null;
}

fn nextSocketGeneration(current: u32) u32 {
    var generation = current +% 1;
    if (generation == 0) generation = 1;
    return generation;
}

fn resolveSocketSlot(index: u16, generation: u32) ?*SocketSlot {
    if (index >= socket_slots.len) return null;
    const slot = &socket_slots[index];
    if (!slot.used or slot.generation != generation) return null;
    return slot;
}

fn socketSlotForDescriptor(handle: u64, fd: u16) !*SocketSlot {
    const kind = try activeDescriptors().descriptorKind(activeProcesses(), handle, fd);
    if (kind != .udp_socket and kind != .tcp_socket) return error.NotSocket;
    const resource = try activeDescriptors().externalResource(activeProcesses(), handle, fd, kind);
    const slot = resolveSocketSlot(resource.index, resource.generation) orelse return error.NotSocket;
    if ((kind == .udp_socket) != (slot.protocol == .udp)) return error.NotSocket;
    return slot;
}

fn socketResourceForSlot(slot: *const SocketSlot) ?runtime_fd.ExternalResource {
    for (&socket_slots, 0..) |*candidate, index| {
        if (candidate == slot) return .{ .index = @intCast(index), .generation = slot.generation };
    }
    return null;
}

fn closeExternalSocket(_: ?*anyopaque, index: u16, generation: u32) bool {
    const slot = resolveSocketSlot(index, generation) orelse return false;
    if (slot.protocol == .udp) {
        if (slot.udp) |socket| {
            const device = e1000e.activeDevice() orelse return false;
            _ = e1000e.closeUdpSocketDiscarding(device, socket) orelse return false;
        }
    }
    slot.* = .{ .generation = generation };
    return true;
}

fn pollExternalSocket(_: ?*anyopaque, index: u16, generation: u32, requested: u16) u16 {
    const slot = resolveSocketSlot(index, generation) orelse return runtime_abi.poll_error | runtime_abi.poll_hangup;
    const device = e1000e.activeDevice() orelse return runtime_abi.poll_error | runtime_abi.poll_hangup;
    var ready: u16 = 0;
    if (slot.protocol == .udp) {
        ready |= runtime_abi.poll_writable;
        if (slot.udp) |socket| {
            if (e1000e.udpSocketReadable(device, socket)) ready |= runtime_abi.poll_readable;
        }
    } else if (slot.listener) |*listener| {
        if (tcpListenerReady(listener)) ready |= runtime_abi.poll_readable;
    } else if (slot.tcp) |connection| {
        ready |= switch (connection.status) {
            .connecting => 0,
            .established => runtime_abi.poll_writable,
            .refused, .timed_out, .io_failed => runtime_abi.poll_error | runtime_abi.poll_hangup,
        };
    } else {
        ready |= runtime_abi.poll_writable;
    }
    return ready & requested;
}

const TcpPeer = struct {
    mac: [6]u8,
    ipv4: [4]u8,
    port: u16,
};

fn tcpPeerForAddress(device: *const e1000e.Device, address: runtime_abi.Ipv4SocketAddress) ?TcpPeer {
    const port = @byteSwap(address.port_be);
    const ipv4 = socketAddressBytes(&address).*;
    if (port == 0 or allZero(&ipv4)) return null;
    return .{
        .mac = if (std.mem.eql(u8, &ipv4, &device.local_ipv4)) device.local_mac else device.gateway_mac,
        .ipv4 = ipv4,
        .port = port,
    };
}

fn tcpPeerMatches(connection: *const TcpSocketState, peer: TcpPeer) bool {
    return connection.peer_port == peer.port and std.mem.eql(u8, &connection.peer_ipv4, &peer.ipv4);
}

fn tcpPortInUse(port: u16) bool {
    for (socket_slots) |slot| {
        if (!slot.used or slot.protocol != .tcp) continue;
        if (slot.tcp_bound_port == port) return true;
        if (slot.tcp) |connection| if (connection.local_port == port) return true;
    }
    return false;
}

fn tcpListenerReady(listener: *const TcpListenerState) bool {
    for (listener.pending[0..listener.backlog]) |pending| {
        const control = pending.control orelse continue;
        if (pending.used and control.state == .established) return true;
    }
    return false;
}

fn nextTcpEphemeralPort(port: u16) u16 {
    return if (port >= tcp_ephemeral_port_last) tcp_ephemeral_port_first else port + 1;
}

fn allocateTcpEphemeralPort() ?u16 {
    var candidate = next_tcp_ephemeral_port;
    if (candidate < tcp_ephemeral_port_first) candidate = tcp_ephemeral_port_first;
    var attempts: u32 = 0;
    while (attempts < tcp_ephemeral_port_count) : (attempts += 1) {
        if (!tcpPortInUse(candidate)) {
            next_tcp_ephemeral_port = nextTcpEphemeralPort(candidate);
            return candidate;
        }
        candidate = nextTcpEphemeralPort(candidate);
    }
    return null;
}

fn tcpInitialSequence(index: u16, generation: u32) u32 {
    var value = @as(u32, @truncate(current_tick)) ^ (generation *% 0x9E37_79B9) ^ (@as(u32, index + 1) << 16) ^ 0x5A49_0001;
    if (value == 0) value = 1;
    return value;
}

fn sendTcpControlToPeer(
    device: *e1000e.Device,
    local_port: u16,
    peer_mac: [6]u8,
    peer_ipv4: [4]u8,
    peer_port: u16,
    outbound: tcp_connection.OutboundSegment,
) bool {
    return e1000e.sendTcpSegment(device, .{
        .destination_mac = peer_mac,
        .destination_ipv4 = peer_ipv4,
        .source_port = local_port,
        .destination_port = peer_port,
        .sequence_number = outbound.sequence_number,
        .acknowledgement_number = outbound.acknowledgement_number,
        .flags = outbound.flags,
        .window_size = outbound.window_size,
    }) != null;
}

fn sendTcpControl(device: *e1000e.Device, connection: *const TcpSocketState, outbound: tcp_connection.OutboundSegment) bool {
    return sendTcpControlToPeer(
        device,
        connection.local_port,
        connection.peer_mac,
        connection.peer_ipv4,
        connection.peer_port,
        outbound,
    );
}

fn sendTcpPendingControl(
    device: *e1000e.Device,
    listener: *const TcpListenerState,
    pending: *const TcpPendingConnection,
    outbound: tcp_connection.OutboundSegment,
) bool {
    return sendTcpControlToPeer(
        device,
        listener.local_port,
        pending.peer_mac,
        pending.peer_ipv4,
        pending.peer_port,
        outbound,
    );
}

fn serviceTcpConnects(device: *e1000e.Device, tick: u64) usize {
    var wakeups: usize = 0;
    var examined: u8 = 0;
    while (examined < 8) : (examined += 1) {
        const packet = e1000e.dequeueTcpPacket(device) orelse break;
        const length: usize = packet.length;
        const segment = tcp.parseFrame(packet.bytes[0..length], .{
            .destination_mac = device.local_mac,
            .destination_ipv4 = device.local_ipv4,
        }) orelse continue;

        var handled = false;
        for (&socket_slots, 0..) |*slot, index| {
            if (!slot.used or slot.protocol != .tcp) continue;
            const connection = if (slot.tcp) |*value| value else continue;
            if (connection.status != .connecting or connection.local_port != segment.destination_port or
                connection.peer_port != segment.source_port or !std.mem.eql(u8, &connection.peer_ipv4, &segment.source_ipv4) or
                !std.mem.eql(u8, &connection.peer_mac, &segment.source_mac)) continue;
            const transition = tcp_connection.handleSegment(&connection.control, .{
                .sequence_number = segment.sequence_number,
                .acknowledgement_number = segment.acknowledgement_number,
                .flags = segment.flags,
                .window_size = segment.window_size,
                .payload_length = @intCast(segment.payload.len),
            });
            if (transition.accepted) {
                if (transition.outbound) |outbound| {
                    if (!sendTcpControl(device, connection, outbound)) connection.status = .io_failed;
                }
                if (connection.status != .io_failed) {
                    connection.status = switch (transition.state) {
                        .established => .established,
                        .reset => .refused,
                        .timed_out => .timed_out,
                        else => .connecting,
                    };
                }
                if (connection.status != .connecting) {
                    wakeups += activeProcesses().wakeMatching(.socket_write, socketWaitKey(@intCast(index), slot.generation), true);
                }
            }
            handled = true;
            break;
        }
        if (handled) continue;

        for (&socket_slots, 0..) |*slot, index| {
            if (!slot.used or slot.protocol != .tcp) continue;
            const listener = if (slot.listener) |*value| value else continue;
            if (segment.destination_port != listener.local_port) continue;
            if (serviceTcpListenerSegment(device, listener, @intCast(index), slot.generation, segment, tick)) {
                if (tcpListenerReady(listener)) {
                    wakeups += activeProcesses().wakeMatching(.socket_read, socketWaitKey(@intCast(index), slot.generation), true);
                }
                break;
            }
        }
    }

    for (&socket_slots, 0..) |*slot, index| {
        if (!slot.used or slot.protocol != .tcp) continue;
        const connection = if (slot.tcp) |*value| value else continue;
        if (connection.status != .connecting) continue;
        const timer = tcp_connection.onTimer(&connection.control, tick);
        switch (timer.action) {
            .none => {},
            .retransmit_syn => if (timer.outbound) |outbound| {
                if (!sendTcpControl(device, connection, outbound)) connection.status = .io_failed;
            },
            .retransmit_syn_ack => {},
            .timed_out => connection.status = .timed_out,
        }
        if (connection.status != .connecting) {
            wakeups += activeProcesses().wakeMatching(.socket_write, socketWaitKey(@intCast(index), slot.generation), true);
        }
    }

    for (&socket_slots) |*slot| {
        if (!slot.used or slot.protocol != .tcp) continue;
        const listener = if (slot.listener) |*value| value else continue;
        const limit: usize = listener.backlog;
        for (listener.pending[0..limit]) |*pending| {
            if (!pending.used) continue;
            const control = if (pending.control) |*value| value else {
                pending.* = .{};
                continue;
            };
            if (control.state != .syn_received) continue;
            const timer = tcp_connection.onTimer(control, tick);
            switch (timer.action) {
                .none => {},
                .retransmit_syn => {},
                .retransmit_syn_ack => if (timer.outbound) |outbound| {
                    if (!sendTcpPendingControl(device, listener, pending, outbound)) pending.* = .{};
                },
                .timed_out => {
                    pending.* = .{};
                },
            }
        }
    }
    return wakeups;
}

fn serviceTcpListenerSegment(
    device: *e1000e.Device,
    listener: *TcpListenerState,
    socket_index: u16,
    generation: u32,
    segment: tcp.Segment,
    tick: u64,
) bool {
    const limit: usize = listener.backlog;
    for (listener.pending[0..limit]) |*pending| {
        if (!pending.used or pending.peer_port != segment.source_port or
            !std.mem.eql(u8, &pending.peer_ipv4, &segment.source_ipv4) or
            !std.mem.eql(u8, &pending.peer_mac, &segment.source_mac)) continue;
        const control = if (pending.control) |*value| value else {
            pending.* = .{};
            return true;
        };
        const transition = tcp_connection.handleSegment(control, .{
            .sequence_number = segment.sequence_number,
            .acknowledgement_number = segment.acknowledgement_number,
            .flags = segment.flags,
            .window_size = segment.window_size,
            .payload_length = @intCast(segment.payload.len),
        });
        if (!transition.accepted) return true;
        if (transition.outbound) |outbound| {
            if (!sendTcpPendingControl(device, listener, pending, outbound)) {
                pending.* = .{};
                return true;
            }
        }
        switch (transition.state) {
            .closed, .reset, .timed_out => pending.* = .{},
            else => {},
        }
        return true;
    }

    if (segment.flags != tcp.flag_syn or segment.payload.len != 0) return true;
    var pending_index: usize = 0;
    while (pending_index < limit and listener.pending[pending_index].used) : (pending_index += 1) {}
    if (pending_index == limit) return true;

    var control = tcp_connection.init(tcp_receive_window) orelse return true;
    const initial_sequence = tcpPassiveInitialSequence(socket_index, @intCast(pending_index), generation, segment.sequence_number, tick);
    const transition = tcp_connection.beginPassiveOpenAt(&control, initial_sequence, .{
        .sequence_number = segment.sequence_number,
        .acknowledgement_number = segment.acknowledgement_number,
        .flags = segment.flags,
        .window_size = segment.window_size,
        .payload_length = @intCast(segment.payload.len),
    }, tick, tcp_retransmission_policy);
    if (!transition.accepted) return true;
    const pending = &listener.pending[pending_index];
    pending.* = .{
        .used = true,
        .peer_ipv4 = segment.source_ipv4,
        .peer_mac = segment.source_mac,
        .peer_port = segment.source_port,
        .control = control,
    };
    if (transition.outbound) |outbound| {
        if (!sendTcpPendingControl(device, listener, pending, outbound)) pending.* = .{};
    }
    return true;
}

fn tcpPassiveInitialSequence(socket_index: u16, pending_index: u8, generation: u32, peer_sequence: u32, tick: u64) u32 {
    var value = @as(u32, @truncate(tick)) ^ peer_sequence ^ (generation *% 0x9E37_79B9) ^
        (@as(u32, socket_index + 1) << 16) ^ (@as(u32, pending_index + 1) *% 0x45D9_F3B) ^ 0x4C49_5301;
    if (value == 0) value = 1;
    return value;
}

fn socketWaitKey(index: u16, generation: u32) u64 {
    return (@as(u64, generation) << 16) | index;
}

fn syscallFstat(context: *Context, frame: *interrupt_context.Frame) u64 {
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    if (!validateRange(context, frame.rsi, @sizeOf(runtime_abi.Stat), true)) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    const info = activeDescriptors().stat(
        activeVfs(),
        activeProcesses(),
        context.handle,
        fd,
    ) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    if (!copyToUser(context, frame.rsi, std.mem.asBytes(&info))) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    frame.rax = 0;
    return 0;
}

fn syscallGetdents(context: *Context, frame: *interrupt_context.Frame) u64 {
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    const byte_capacity: usize = std.math.cast(usize, frame.rdx) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if (byte_capacity < @sizeOf(runtime_abi.DirectoryEntry) or byte_capacity > maximum_io_bytes or
        !validateRange(context, frame.rsi, byte_capacity, true))
    {
        frame.rax = reject(if (byte_capacity > maximum_io_bytes) errno_invalid else errno_fault);
        return 0;
    }
    const capacity = @min(byte_capacity / @sizeOf(runtime_abi.DirectoryEntry), maximum_directory_batch);
    var records: [maximum_directory_batch]runtime_vfs.DirectoryRecord = @splat(.{});
    const count = activeDescriptors().getDirectoryEntries(
        activeVfs(),
        activeProcesses(),
        context.handle,
        fd,
        records[0..capacity],
        current_tick,
    ) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    var entries: [maximum_directory_batch]runtime_abi.DirectoryEntry = @splat(std.mem.zeroes(runtime_abi.DirectoryEntry));
    for (records[0..count], 0..) |record, index| {
        entries[index].node = record.node;
        entries[index].kind = @intFromEnum(record.kind);
        entries[index].readonly = @intFromBool(record.readonly);
        entries[index].name_length = record.name_length;
        entries[index].size = record.size;
        @memcpy(entries[index].name[0..record.name_length], record.nameSlice());
    }
    const bytes = std.mem.asBytes(&entries)[0 .. count * @sizeOf(runtime_abi.DirectoryEntry)];
    if (bytes.len != 0 and !copyToUser(context, frame.rsi, bytes)) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    frame.rax = bytes.len;
    return 0;
}

fn syscallPoll(context: *Context, frame: *interrupt_context.Frame) u64 {
    const count: usize = std.math.cast(usize, frame.rsi) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if (frame.rdx != 0 or count > maximum_poll_descriptors) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    const byte_count = std.math.mul(usize, count, @sizeOf(runtime_abi.PollDescriptor)) catch {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if (!validateRange(context, frame.rdi, byte_count, true)) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    var descriptors: [maximum_poll_descriptors]runtime_abi.PollDescriptor = @splat(std.mem.zeroes(runtime_abi.PollDescriptor));
    if (byte_count != 0 and !copyFromUser(context, frame.rdi, std.mem.asBytes(&descriptors)[0..byte_count])) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    var ready_count: usize = 0;
    for (descriptors[0..count]) |*descriptor| {
        descriptor.returned = activeDescriptors().poll(
            activeVfs(),
            activeProcesses(),
            context.handle,
            descriptor.fd,
            descriptor.requested,
        ) catch |err| {
            frame.rax = reject(runtime_abi.fromError(err));
            return 0;
        };
        if (descriptor.returned != 0) ready_count += 1;
    }
    if (byte_count != 0 and !copyToUser(context, frame.rdi, std.mem.asBytes(&descriptors)[0..byte_count])) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    frame.rax = ready_count;
    return 0;
}

fn availableCapabilities() u64 {
    var capabilities = syscall.capability_process |
        syscall.capability_descriptors |
        syscall.capability_pipes |
        syscall.capability_vfs |
        syscall.capability_wait |
        syscall.capability_virtual_memory |
        syscall.capability_terminal |
        syscall.capability_pseudo_files;
    if (e1000e.activeDevice() != null) capabilities |= syscall.capability_udp_sockets | syscall.capability_tcp_sockets;
    if (persistent_storage_capability) capabilities |= syscall.capability_persistent_storage;
    if (normal_boot_capability) capabilities |= syscall.capability_normal_boot;
    return capabilities;
}

fn syscallAbiQuery(context: *Context, frame: *interrupt_context.Frame) u64 {
    if (frame.rdi == 0) {
        frame.rax = @sizeOf(runtime_abi.AbiInfo);
        return 0;
    }
    const destination_size: usize = std.math.cast(usize, frame.rsi) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if (destination_size < @sizeOf(runtime_abi.AbiInfo) or
        !validateRange(context, frame.rdi, @sizeOf(runtime_abi.AbiInfo), true))
    {
        frame.rax = reject(if (destination_size < @sizeOf(runtime_abi.AbiInfo)) errno_invalid else errno_fault);
        return 0;
    }
    const info = runtime_abi.makeInfo(.{
        .capabilities = availableCapabilities(),
        .user_base = user_base,
        .user_end = user_end,
        .maximum_io_bytes = maximum_io_bytes,
        .maximum_path_bytes = runtime_vfs.maximum_path_length,
        .maximum_processes = runtime_process.maximum_processes,
        .maximum_descriptors = runtime_fd.maximum_descriptors_per_process,
        .maximum_sockets = if (e1000e.activeDevice() != null) @min(maximum_socket_slots, e1000e.udpEndpointCapacity()) else 0,
    });
    if (!copyToUser(context, frame.rdi, std.mem.asBytes(&info))) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    frame.rax = @sizeOf(runtime_abi.AbiInfo);
    return 0;
}

fn syscallMmap(context: *Context, frame: *interrupt_context.Frame) u64 {
    const requested_length: usize = std.math.cast(usize, frame.rsi) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const length = alignForwardChecked(requested_length, page_bytes) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if (length == 0 or length / page_bytes > maximum_mappings) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    const protection = runtime_abi.protectionBits(frame.rdx) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const flags = runtime_abi.mapFlagBits(frame.r10) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const file_shared = (flags & runtime_abi.map_shared) != 0;
    if ((protection & runtime_abi.protection_read) == 0 or
        (protection & runtime_abi.protection_write) != 0 and (protection & runtime_abi.protection_execute) != 0 or
        file_shared and (protection & (runtime_abi.protection_write | runtime_abi.protection_execute)) != 0)
    {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    var file_info: ?runtime_fd.FileMappingInfo = null;
    var file_offset: usize = 0;
    if (file_shared) {
        const fd = runtime_abi.descriptor(frame.r8) orelse {
            frame.rax = reject(errno_bad_fd);
            return 0;
        };
        file_offset = std.math.cast(usize, frame.r9) orelse {
            frame.rax = reject(errno_invalid);
            return 0;
        };
        if ((file_offset & (page_bytes - 1)) != 0) {
            frame.rax = reject(errno_invalid);
            return 0;
        }
        const info = activeDescriptors().fileMappingInfo(
            activeVfs(),
            activeProcesses(),
            context.handle,
            fd,
        ) catch |err| {
            frame.rax = reject(runtime_abi.fromError(err));
            return 0;
        };
        const requested_end = std.math.add(usize, file_offset, requested_length) catch {
            frame.rax = reject(errno_invalid);
            return 0;
        };
        if (!info.readable or requested_end > info.size or file_offset / page_bytes + length / page_bytes > runtime_vfs.file_blocks_per_node) {
            frame.rax = reject(errno_invalid);
            return 0;
        }
        file_info = info;
    } else if (frame.r9 != 0 or (frame.r8 != std.math.maxInt(u64) and frame.r8 != std.math.maxInt(u32))) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    const requested_address: usize = std.math.cast(usize, frame.rdi) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const fixed = (flags & (runtime_abi.map_fixed | runtime_abi.map_fixed_no_replace)) != 0;
    const start = if (fixed)
        requested_address
    else
        findMmapRange(context, length) orelse {
            frame.rax = reject(errno_no_memory);
            return 0;
        };
    const end = std.math.add(usize, start, length) catch {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if ((start & (page_bytes - 1)) != 0 or start < mmap_floor or end > mmap_ceiling or
        !mappingRangeAvailable(context, start, end))
    {
        frame.rax = reject(if (fixed) runtime_abi.errno_exists else errno_no_memory);
        return 0;
    }
    const writable = (protection & runtime_abi.protection_write) != 0;
    const executable = (protection & runtime_abi.protection_execute) != 0;
    const mapping_kind: MappingKind = if (file_shared) .file_shared else .anonymous;
    var virtual = start;
    while (virtual < end) : (virtual += page_bytes) {
        if (file_info) |info| {
            const slot = file_offset / page_bytes + (virtual - start) / page_bytes;
            const mapped_page = activeVfs().pinFilePage(info.node, info.generation, slot) catch |err| {
                rollbackDynamicRange(context, start, virtual, mapping_kind);
                frame.rax = reject(runtime_abi.fromError(err));
                return 0;
            };
            mapBorrowedFilePage(context, virtual, mapped_page) catch |err| {
                rollbackDynamicRange(context, start, virtual, mapping_kind);
                frame.rax = reject(runtime_abi.fromError(err));
                return 0;
            };
        } else {
            const physical = allocatePage(context.handle) orelse {
                rollbackDynamicRange(context, start, virtual, mapping_kind);
                frame.rax = reject(errno_no_memory);
                return 0;
            };
            mapOwned(context, virtual, physical, writable, executable, mapping_kind) catch |err| {
                rollbackDynamicRange(context, start, virtual, mapping_kind);
                frame.rax = reject(runtime_abi.fromError(err));
                return 0;
            };
        }
    }
    syncMemoryUsage(context) catch |err| {
        rollbackDynamicRange(context, start, end, mapping_kind);
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    context.mmap_hint = if (end < mmap_ceiling) end else mmap_floor;
    frame.rax = start;
    return 0;
}

fn syscallMunmap(context: *Context, frame: *interrupt_context.Frame) u64 {
    const start: usize = std.math.cast(usize, frame.rdi) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const requested_length: usize = std.math.cast(usize, frame.rsi) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const length = alignForwardChecked(requested_length, page_bytes) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const end = std.math.add(usize, start, length) catch {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if (length == 0 or (start & (page_bytes - 1)) != 0 or start < mmap_floor or end > mmap_ceiling or
        !rangeHasDynamicMappings(context, start, end))
    {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    var virtual = start;
    while (virtual < end) : (virtual += page_bytes) {
        const index = findMapping(context, virtual) orelse unreachable;
        unmapOwned(context, index) catch |err| {
            frame.rax = reject(runtime_abi.fromError(err));
            return 0;
        };
    }
    reclaimEmptyPageTables(context, start, end);
    syncMemoryUsage(context) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    context.mmap_hint = @min(context.mmap_hint, start);
    frame.rax = 0;
    return 0;
}

fn syscallMprotect(context: *Context, frame: *interrupt_context.Frame) u64 {
    const start: usize = std.math.cast(usize, frame.rdi) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const requested_length: usize = std.math.cast(usize, frame.rsi) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const length = alignForwardChecked(requested_length, page_bytes) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const protection = runtime_abi.protectionBits(frame.rdx) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const end = std.math.add(usize, start, length) catch {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if (length == 0 or (start & (page_bytes - 1)) != 0 or start < user_base or end > user_end or
        (protection & runtime_abi.protection_read) == 0 or
        (protection & runtime_abi.protection_write) != 0 and (protection & runtime_abi.protection_execute) != 0)
    {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    var virtual = start;
    while (virtual < end) : (virtual += page_bytes) {
        const index = findMapping(context, virtual) orelse {
            frame.rax = reject(errno_invalid);
            return 0;
        };
        if (context.mappings[index].kind == .trampoline or
            context.mappings[index].kind == .file_shared and
                ((protection & runtime_abi.protection_write) != 0 or (protection & runtime_abi.protection_execute) != 0))
        {
            frame.rax = reject(runtime_abi.errno_access);
            return 0;
        }
    }
    const writable = (protection & runtime_abi.protection_write) != 0;
    const executable = (protection & runtime_abi.protection_execute) != 0;
    virtual = start;
    while (virtual < end) : (virtual += page_bytes) {
        const index = findMapping(context, virtual) orelse unreachable;
        const mapping = &context.mappings[index];
        if (!paging.protectUserPageInSpace(
            context.space,
            virtual,
            mapping.physical_address,
            writable,
            executable,
        )) {
            rollbackProtection(context, start, virtual);
            frame.rax = reject(runtime_abi.errno_io);
            return 0;
        }
    }
    virtual = start;
    while (virtual < end) : (virtual += page_bytes) {
        const index = findMapping(context, virtual) orelse unreachable;
        context.mappings[index].writable = writable;
        context.mappings[index].executable = executable;
    }
    frame.rax = 0;
    return 0;
}

fn syscallBrk(context: *Context, frame: *interrupt_context.Frame) u64 {
    if (frame.rdi == 0) {
        frame.rax = context.brk_current;
        return 0;
    }
    const requested: usize = std.math.cast(usize, frame.rdi) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if (requested < context.brk_base or requested > context.brk_limit) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    if (requested > context.brk_current) {
        const first = alignForward(context.brk_current, page_bytes);
        const end = alignForwardChecked(requested, page_bytes) orelse {
            frame.rax = reject(errno_invalid);
            return 0;
        };
        var virtual = first;
        while (virtual < end) : (virtual += page_bytes) {
            if (findMapping(context, virtual) != null) {
                rollbackDynamicRange(context, first, virtual, .heap);
                frame.rax = reject(errno_no_memory);
                return 0;
            }
            const physical = allocatePage(context.handle) orelse {
                rollbackDynamicRange(context, first, virtual, .heap);
                frame.rax = reject(errno_no_memory);
                return 0;
            };
            mapOwned(context, virtual, physical, true, false, .heap) catch |err| {
                rollbackDynamicRange(context, first, virtual, .heap);
                frame.rax = reject(runtime_abi.fromError(err));
                return 0;
            };
        }
    } else if (requested < context.brk_current) {
        const first = alignForward(requested, page_bytes);
        const end = alignForward(context.brk_current, page_bytes);
        if (!rangeHasKindOrEmpty(context, first, end, .heap)) {
            frame.rax = reject(runtime_abi.errno_io);
            return 0;
        }
        var virtual = first;
        while (virtual < end) : (virtual += page_bytes) {
            const index = findMapping(context, virtual) orelse continue;
            unmapOwned(context, index) catch |err| {
                frame.rax = reject(runtime_abi.fromError(err));
                return 0;
            };
        }
        reclaimEmptyPageTables(context, first, end);
    }
    context.brk_current = requested;
    syncMemoryUsage(context) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    frame.rax = context.brk_current;
    return 0;
}

fn findMmapRange(context: *const Context, length: usize) ?usize {
    if (length == 0 or length > mmap_ceiling - mmap_floor) return null;
    const hint = alignForward(@max(@min(context.mmap_hint, mmap_ceiling), mmap_floor), page_bytes);
    if (scanMmapRange(context, hint, mmap_ceiling, length)) |address| return address;
    if (hint > mmap_floor) return scanMmapRange(context, mmap_floor, hint, length);
    return null;
}

fn scanMmapRange(context: *const Context, first: usize, limit: usize, length: usize) ?usize {
    if (first >= limit or length > limit - first) return null;
    const final_start = limit - length;
    var candidate = first;
    while (candidate <= final_start) : (candidate += page_bytes) {
        const end = candidate + length;
        if (mappingRangeAvailable(context, candidate, end)) return candidate;
        if (candidate > final_start -| page_bytes) break;
    }
    return null;
}

fn mappingRangeAvailable(context: *const Context, start: usize, end: usize) bool {
    var virtual = start;
    while (virtual < end) : (virtual += page_bytes) if (findMapping(context, virtual) != null) return false;
    return true;
}

fn rangeHasKind(context: *const Context, start: usize, end: usize, kind: MappingKind) bool {
    var virtual = start;
    while (virtual < end) : (virtual += page_bytes) {
        const index = findMapping(context, virtual) orelse return false;
        if (context.mappings[index].kind != kind) return false;
    }
    return true;
}

fn rangeHasDynamicMappings(context: *const Context, start: usize, end: usize) bool {
    var virtual = start;
    while (virtual < end) : (virtual += page_bytes) {
        const index = findMapping(context, virtual) orelse return false;
        const kind = context.mappings[index].kind;
        if (kind != .anonymous and kind != .file_shared) return false;
    }
    return true;
}

fn rangeHasKindOrEmpty(context: *const Context, start: usize, end: usize, kind: MappingKind) bool {
    var virtual = start;
    while (virtual < end) : (virtual += page_bytes) {
        const index = findMapping(context, virtual) orelse continue;
        if (context.mappings[index].kind != kind) return false;
    }
    return true;
}

fn rollbackDynamicRange(context: *Context, start: usize, end: usize, kind: MappingKind) void {
    var virtual = start;
    while (virtual < end) : (virtual += page_bytes) {
        const index = findMapping(context, virtual) orelse continue;
        if (context.mappings[index].kind != kind) continue;
        unmapOwned(context, index) catch {};
    }
    reclaimEmptyPageTables(context, start, end);
    syncMemoryUsage(context) catch {};
}

fn rollbackProtection(context: *Context, start: usize, end: usize) void {
    var virtual = start;
    while (virtual < end) : (virtual += page_bytes) {
        const index = findMapping(context, virtual) orelse continue;
        const mapping = &context.mappings[index];
        _ = paging.protectUserPageInSpace(
            context.space,
            virtual,
            mapping.physical_address,
            mapping.writable,
            mapping.executable,
        );
    }
}

fn reclaimEmptyPageTables(context: *Context, start: usize, end: usize) void {
    var table_base = start & ~(page_table_span - 1);
    const final_base = (end - 1) & ~(page_table_span - 1);
    while (table_base <= final_base) : (table_base += page_table_span) {
        if (tableHasMappings(context, table_base)) continue;
        for (&context.page_tables) |*table| {
            if (!table.used or table.virtual_base != table_base) continue;
            if (!paging.removeUserPageTableInSpace(context.space, table.virtual_base, table.physical_address)) break;
            releasePage(table.physical_address, context.handle);
            if (context.table_frames[3] == table.physical_address) context.table_frames[3] = 0;
            table.* = .{};
            context.page_table_count -= 1;
            break;
        }
    }
}

fn tableHasMappings(context: *const Context, table_base: usize) bool {
    const table_end = table_base + page_table_span;
    for (context.mappings) |mapping| {
        if (mapping.used and mapping.virtual_address >= table_base and mapping.virtual_address < table_end) return true;
    }
    return false;
}

fn syscallSpawn(context: *Context, frame: *interrupt_context.Frame) u64 {
    const path_length: usize = std.math.cast(usize, frame.rsi) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if (path_length == 0) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    if (path_length > runtime_vfs.maximum_path_length) {
        frame.rax = reject(runtime_abi.errno_name_too_long);
        return 0;
    }
    if (!validateRange(context, frame.rdi, path_length, false)) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    var path_buffer: [runtime_vfs.maximum_path_length]u8 = undefined;
    if (!copyFromUser(context, frame.rdi, path_buffer[0..path_length])) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    const path = path_buffer[0..path_length];
    if (std.mem.indexOfScalar(u8, path, 0) != null) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    runtime_vfs.validatePathBounds(path) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const parent = activeProcesses().get(context.handle) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const image_bytes = activeVfs().executableViewAs(parent.cwd_node, path, .{ .uid = parent.uid, .gid = parent.gid }) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const raw_name = if (slash) |index| path[index + 1 ..] else path;
    const name = raw_name[0..@min(raw_name.len, runtime_process.maximum_name_length)];
    if (name.len == 0) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    const handle = spawn(
        context.handle,
        name,
        &.{name},
        parent.cwd_node,
        image_bytes,
        current_tick,
        .{},
    ) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    if (!notifyChildSpawn(context.handle, handle)) {
        discardSpawnedChild(context.handle, handle);
        frame.rax = reject(runtime_abi.errno_io);
        return 0;
    }
    const child = activeProcesses().get(handle) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    frame.rax = child.pid;
    return 0;
}

fn syscallSpawnv(context: *Context, frame: *interrupt_context.Frame) u64 {
    if (!validateRange(context, frame.rdi, @sizeOf(runtime_abi.SpawnRequest), false)) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    var request: runtime_abi.SpawnRequest = undefined;
    if (!copyFromUser(context, frame.rdi, std.mem.asBytes(&request))) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    if ((request.flags & ~runtime_abi.spawn_allowed) != 0) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    const group_flags = request.flags & runtime_abi.spawn_group_allowed;
    const spawn_group: runtime_process.SpawnGroup = switch (group_flags) {
        0 => blk: {
            if (frame.rsi != 0) {
                frame.rax = reject(errno_invalid);
                return 0;
            }
            break :blk .inherit;
        },
        runtime_abi.spawn_new_process_group => blk: {
            if (frame.rsi != 0) {
                frame.rax = reject(errno_invalid);
                return 0;
            }
            break :blk .new_pipeline;
        },
        runtime_abi.spawn_join_process_group => blk: {
            const requested_group = std.math.cast(u32, frame.rsi) orelse {
                frame.rax = reject(errno_invalid);
                return 0;
            };
            if (requested_group == 0) {
                frame.rax = reject(errno_invalid);
                return 0;
            }
            break :blk .{ .join_pipeline = requested_group };
        },
        else => {
            frame.rax = reject(errno_invalid);
            return 0;
        },
    };

    const foreground_group = (request.flags & runtime_abi.spawn_foreground_process_group) != 0;
    if (foreground_group and group_flags != runtime_abi.spawn_new_process_group) {
        frame.rax = reject(errno_invalid);
        return 0;
    }

    var descriptor_map = SpawnDescriptorMap{};
    if ((request.flags & runtime_abi.spawn_pipeline_io) != 0) {
        if (group_flags == 0 or (frame.rdx >> 32) != 0) {
            frame.rax = reject(errno_invalid);
            return 0;
        }
        const raw_stdin: u16 = @truncate(frame.rdx);
        const raw_stdout: u16 = @truncate(frame.rdx >> 16);
        const stdin_source: ?u16 = if (raw_stdin == runtime_abi.spawn_io_inherit_descriptor)
            null
        else if (raw_stdin < runtime_fd.maximum_descriptors_per_process)
            raw_stdin
        else {
            frame.rax = reject(errno_bad_fd);
            return 0;
        };
        const stdout_source: ?u16 = if (raw_stdout == runtime_abi.spawn_io_inherit_descriptor)
            null
        else if (raw_stdout < runtime_fd.maximum_descriptors_per_process)
            raw_stdout
        else {
            frame.rax = reject(errno_bad_fd);
            return 0;
        };
        if (stdin_source == null and stdout_source == null) {
            frame.rax = reject(errno_invalid);
            return 0;
        }
        descriptor_map = .{ .enabled = true, .stdin_source = stdin_source, .stdout_source = stdout_source };
    } else if (frame.rdx != 0) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    if (request.path_length == 0) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    if (request.path_length > runtime_vfs.maximum_path_length) {
        frame.rax = reject(runtime_abi.errno_name_too_long);
        return 0;
    }
    if (request.argument_count == 0 or request.argument_count > syscall.maximum_arguments or
        request.environment_count > syscall.maximum_environment)
    {
        frame.rax = reject(if (request.argument_count > syscall.maximum_arguments or
            request.environment_count > syscall.maximum_environment) runtime_abi.errno_too_big else errno_invalid);
        return 0;
    }
    if (!validateRange(context, request.path_pointer, request.path_length, false)) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    var path_storage: [runtime_vfs.maximum_path_length]u8 = undefined;
    if (!copyFromUser(context, request.path_pointer, path_storage[0..request.path_length])) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    const path = path_storage[0..request.path_length];
    if (std.mem.indexOfScalar(u8, path, 0) != null) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    runtime_vfs.validatePathBounds(path) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };

    const argument_bytes = @as(usize, request.argument_count) * @sizeOf(runtime_abi.UserString);
    const environment_bytes = @as(usize, request.environment_count) * @sizeOf(runtime_abi.UserString);
    if (!validateRange(context, request.arguments_pointer, argument_bytes, false) or
        (environment_bytes != 0 and !validateRange(context, request.environment_pointer, environment_bytes, false)))
    {
        frame.rax = reject(errno_fault);
        return 0;
    }
    var argument_descriptors: [syscall.maximum_arguments]runtime_abi.UserString = @splat(.{
        .pointer = 0,
        .length = 0,
    });
    var environment_descriptors: [syscall.maximum_environment]runtime_abi.UserString = @splat(.{
        .pointer = 0,
        .length = 0,
    });
    if (!copyFromUser(
        context,
        request.arguments_pointer,
        std.mem.asBytes(&argument_descriptors)[0..argument_bytes],
    ) or (environment_bytes != 0 and !copyFromUser(
        context,
        request.environment_pointer,
        std.mem.asBytes(&environment_descriptors)[0..environment_bytes],
    ))) {
        frame.rax = reject(errno_fault);
        return 0;
    }

    var argument_storage: [syscall.maximum_arguments][syscall.maximum_argument_bytes + 1]u8 = @splat(@splat(0));
    var environment_storage: [syscall.maximum_environment][syscall.maximum_environment_bytes + 1]u8 = @splat(@splat(0));
    var arguments: [syscall.maximum_arguments][]const u8 = undefined;
    var environment: [syscall.maximum_environment][]const u8 = undefined;
    for (argument_descriptors[0..request.argument_count], 0..) |descriptor, index| {
        if (descriptor.reserved0 != 0 or descriptor.reserved1 != 0 or descriptor.length == 0 or
            descriptor.length > syscall.maximum_argument_bytes or
            !validateRange(context, descriptor.pointer, descriptor.length, false))
        {
            frame.rax = reject(if (descriptor.length > syscall.maximum_argument_bytes) runtime_abi.errno_name_too_long else errno_invalid);
            return 0;
        }
        const target = argument_storage[index][0..descriptor.length];
        if (!copyFromUser(context, descriptor.pointer, target) or std.mem.indexOfScalar(u8, target, 0) != null) {
            frame.rax = reject(errno_fault);
            return 0;
        }
        arguments[index] = target;
    }
    for (environment_descriptors[0..request.environment_count], 0..) |descriptor, index| {
        if (descriptor.reserved0 != 0 or descriptor.reserved1 != 0 or descriptor.length == 0 or
            descriptor.length > syscall.maximum_environment_bytes or
            !validateRange(context, descriptor.pointer, descriptor.length, false))
        {
            frame.rax = reject(if (descriptor.length > syscall.maximum_environment_bytes) runtime_abi.errno_name_too_long else errno_invalid);
            return 0;
        }
        const target = environment_storage[index][0..descriptor.length];
        if (!copyFromUser(context, descriptor.pointer, target) or !validEnvironmentString(target)) {
            frame.rax = reject(errno_invalid);
            return 0;
        }
        environment[index] = target;
    }

    const parent = activeProcesses().get(context.handle) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const image_bytes = activeVfs().executableViewAs(parent.cwd_node, path, .{ .uid = parent.uid, .gid = parent.gid }) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const raw_name = if (slash) |index| path[index + 1 ..] else path;
    const name = raw_name[0..@min(raw_name.len, runtime_process.maximum_name_length)];
    if (name.len == 0) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    const handle = spawnWithEnvironmentGroup(
        context.handle,
        name,
        arguments[0..request.argument_count],
        environment[0..request.environment_count],
        parent.cwd_node,
        image_bytes,
        current_tick,
        .{},
        spawn_group,
        descriptor_map,
    ) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const child = activeProcesses().get(handle) catch |err| {
        discardSpawnedChild(context.handle, handle);
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    if (!notifyChildSpawn(context.handle, handle)) {
        discardSpawnedChild(context.handle, handle);
        frame.rax = reject(runtime_abi.errno_io);
        return 0;
    }
    if (foreground_group) {
        _ = activeDescriptors().ioctl(
            activeVfs(),
            activeProcesses(),
            context.handle,
            0,
            runtime_abi.constants.ioctl_tty_set_foreground_group,
            child.pid,
        ) catch |err| {
            discardSpawnedChild(context.handle, handle);
            frame.rax = reject(runtime_abi.fromError(err));
            return 0;
        };
    }
    frame.rax = child.pid;
    return 0;
}

fn notifyChildSpawn(parent_handle: u64, child_handle: u64) bool {
    const callback = child_spawn_fn orelse return true;
    return callback(parent_handle, child_handle);
}

fn discardSpawnedChild(parent_handle: u64, child_handle: u64) void {
    activeProcesses().exit(child_handle, 0x7F00_0003) catch {};
    finalize(child_handle) catch {};
    _ = activeProcesses().wait(parent_handle, child_handle, true) catch null;
    forget(child_handle);
}

fn validEnvironmentString(value: []const u8) bool {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return false;
    const separator = std.mem.indexOfScalar(u8, value, '=') orelse return false;
    return separator != 0;
}

fn syscallWait(
    context: *Context,
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) u64 {
    const flags = frame.rsi;
    if ((flags & ~wait_allowed) != 0) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    if (!validateRange(context, frame.rdx, @sizeOf(runtime_abi.WaitStatus), true)) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    const target: u32 = std.math.cast(u32, frame.rdi) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const group_wait = (flags & wait_process_group) != 0;
    if (group_wait and target == 0) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    const target_handle = (if (group_wait)
        activeProcesses().childForWaitGroup(context.handle, target)
    else
        activeProcesses().childForWait(context.handle, target)) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    if (target_handle) |handle| {
        const child = activeProcesses().get(handle) catch |err| {
            frame.rax = reject(runtime_abi.fromError(err));
            return 0;
        };
        if (child.terminal()) {
            const user_status = runtime_abi.WaitStatus{
                .pid = child.pid,
                .exit_status = child.exit_status,
                .state = @intFromEnum(child.state),
                .fault_vector = child.fault_vector,
                .fault_address = child.fault_address,
            };
            // Copy first: an invalid destination must not consume the one-shot child status.
            if (!copyToUser(context, frame.rdx, std.mem.asBytes(&user_status))) {
                frame.rax = reject(errno_fault);
                return 0;
            }
            finalize(handle) catch |err| {
                frame.rax = reject(runtime_abi.fromError(err));
                return 0;
            };
            const status = activeProcesses().wait(context.handle, handle, true) catch |err| {
                frame.rax = reject(runtime_abi.fromError(err));
                return 0;
            } orelse {
                frame.rax = reject(errno_would_block);
                return 0;
            };
            forget(handle);
            frame.rax = status.pid;
            return 0;
        }
    }
    if ((flags & wait_nohang) != 0) {
        frame.rax = 0;
        return 0;
    }
    if (group_wait) {
        _ = activeProcesses().waitGroup(context.handle, target, false) catch |err| {
            frame.rax = reject(runtime_abi.fromError(err));
            return 0;
        };
    } else {
        const blocking_target: ?u64 = if (target == 0) null else target_handle;
        _ = activeProcesses().wait(context.handle, blocking_target, false) catch |err| {
            frame.rax = reject(runtime_abi.fromError(err));
            return 0;
        };
    }
    return blockAndRetry(context, frame, fx_state);
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
    if (length > maximum_io_bytes or !validateRange(context, frame.rsi, length, false)) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    var bytes: [maximum_io_bytes]u8 = undefined;
    if (!copyFromUser(context, frame.rsi, bytes[0..length])) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    const kind = activeDescriptors().descriptorKind(activeProcesses(), context.handle, fd) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
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
    if (kind == .terminal and result.count != 0) appendOutput(context, bytes[0..result.count]);
    frame.rax = result.count;
    return 0;
}

const KernelDescriptorRead = union(enum) {
    complete: runtime_fd.IoResult,
    descriptor_error: runtime_fd.Error,
    activation_failure,
    restore_failure,
};

fn readDescriptorInKernelAddressSpace(context: *Context, fd: u16, output: []u8) KernelDescriptorRead {
    const user_root = context.space.pml4_address;
    if (paging.currentCr3Address() != user_root or !paging.activateKernelAddressSpace()) return .activation_failure;

    var descriptor_error: ?runtime_fd.Error = null;
    const result = activeDescriptors().readAtTick(
        activeVfs(),
        activeProcesses(),
        context.handle,
        fd,
        output,
        current_tick,
    ) catch |err| blk: {
        descriptor_error = err;
        break :blk runtime_fd.IoResult{ .status = .complete };
    };

    if (!paging.activateAddressSpace(user_root)) return .restore_failure;
    if (descriptor_error) |err| return .{ .descriptor_error = err };
    return .{ .complete = result };
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
    if (length > maximum_io_bytes or !validateRange(context, frame.rsi, length, true)) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    var bytes: [maximum_io_bytes]u8 = undefined;
    const result = switch (readDescriptorInKernelAddressSpace(context, fd, bytes[0..length])) {
        .complete => |value| value,
        .descriptor_error => |err| {
            frame.rax = reject(runtime_abi.fromError(err));
            return 0;
        },
        .activation_failure => {
            frame.rax = reject(runtime_abi.errno_io);
            return 0;
        },
        .restore_failure => {
            saveContext(context, frame, fx_state);
            activeProcesses().fault(context.handle, 13, context.space.pml4_address) catch {};
            faults +%= 1;
            return 1;
        },
    };
    if (result.status == .blocked) return blockAndRetry(context, frame, fx_state);
    if (result.count != 0 and !copyToUser(context, frame.rsi, bytes[0..result.count])) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    frame.rax = result.count;
    return 0;
}

const IoVectorPlanError = error{ Invalid, TooBig, Fault };

const IoVectorPlan = struct {
    vectors: [runtime_abi.constants.maximum_iovecs]runtime_abi.IoVector = @splat(.{ .pointer = 0, .length = 0 }),
    count: usize = 0,
    total: usize = 0,
};

fn loadIoVectorPlan(context: *const Context, pointer: u64, count_value: u64, write_to_user: bool) IoVectorPlanError!IoVectorPlan {
    const count = std.math.cast(usize, count_value) orelse return error.Invalid;
    if (count > runtime_abi.constants.maximum_iovecs) return error.Invalid;
    var plan = IoVectorPlan{ .count = count };
    const descriptor_bytes = count * @sizeOf(runtime_abi.IoVector);
    if (descriptor_bytes != 0) {
        if (!validateRange(context, pointer, descriptor_bytes, false) or
            !copyFromUser(context, pointer, std.mem.asBytes(&plan.vectors)[0..descriptor_bytes])) return error.Fault;
    }
    for (plan.vectors[0..count]) |vector| {
        const length = std.math.cast(usize, vector.length) orelse return error.Invalid;
        plan.total = std.math.add(usize, plan.total, length) catch return error.TooBig;
        if (plan.total > maximum_io_bytes) return error.TooBig;
        if (length != 0 and !validateRange(context, vector.pointer, length, write_to_user)) return error.Fault;
    }
    return plan;
}

fn rejectIoVectorPlan(frame: *interrupt_context.Frame, err: IoVectorPlanError) u64 {
    frame.rax = reject(switch (err) {
        error.Invalid => errno_invalid,
        error.TooBig => runtime_abi.errno_too_big,
        error.Fault => errno_fault,
    });
    return 0;
}

fn syscallWritev(
    context: *Context,
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) u64 {
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    const plan = loadIoVectorPlan(context, frame.rsi, frame.rdx, false) catch |err| return rejectIoVectorPlan(frame, err);
    const kind = activeDescriptors().descriptorKind(activeProcesses(), context.handle, fd) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    var bytes: [maximum_io_bytes]u8 = undefined;
    var gathered: usize = 0;
    for (plan.vectors[0..plan.count]) |vector| {
        const length: usize = @intCast(vector.length);
        if (length == 0) continue;
        if (!copyFromUser(context, vector.pointer, bytes[gathered .. gathered + length])) {
            frame.rax = reject(errno_fault);
            return 0;
        }
        gathered += length;
    }
    const io = activeDescriptors().write(
        activeVfs(),
        activeProcesses(),
        context.handle,
        fd,
        bytes[0..plan.total],
        current_tick,
    ) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    if (io.status == .blocked) return blockAndRetry(context, frame, fx_state);
    if (kind == .terminal and io.count != 0) appendOutput(context, bytes[0..io.count]);
    frame.rax = io.count;
    return 0;
}

fn syscallReadv(
    context: *Context,
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) u64 {
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    const plan = loadIoVectorPlan(context, frame.rsi, frame.rdx, true) catch |err| return rejectIoVectorPlan(frame, err);
    var bytes: [maximum_io_bytes]u8 = undefined;
    const io = switch (readDescriptorInKernelAddressSpace(context, fd, bytes[0..plan.total])) {
        .complete => |value| value,
        .descriptor_error => |err| {
            frame.rax = reject(runtime_abi.fromError(err));
            return 0;
        },
        .activation_failure => {
            frame.rax = reject(runtime_abi.errno_io);
            return 0;
        },
        .restore_failure => {
            saveContext(context, frame, fx_state);
            activeProcesses().fault(context.handle, 13, context.space.pml4_address) catch {};
            faults +%= 1;
            return 1;
        },
    };
    if (io.status == .blocked) return blockAndRetry(context, frame, fx_state);
    var scattered: usize = 0;
    for (plan.vectors[0..plan.count]) |vector| {
        if (scattered == io.count) break;
        const vector_length: usize = @intCast(vector.length);
        const count = @min(vector_length, io.count - scattered);
        if (count != 0 and !copyToUser(context, vector.pointer, bytes[scattered .. scattered + count])) {
            frame.rax = reject(errno_fault);
            return 0;
        }
        scattered += count;
    }
    frame.rax = io.count;
    return 0;
}

fn syscallOpen(context: *Context, frame: *interrupt_context.Frame) u64 {
    var path_buffer: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0);
    const path_length = copyUserPath(context, frame, frame.rdi, &path_buffer) orelse return 0;
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

fn syscallIoctl(context: *Context, frame: *interrupt_context.Frame) u64 {
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    frame.rax = activeDescriptors().ioctl(
        activeVfs(),
        activeProcesses(),
        context.handle,
        fd,
        frame.rsi,
        frame.rdx,
    ) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    return 0;
}

fn syscallStat(context: *Context, frame: *interrupt_context.Frame) u64 {
    var path_buffer: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0);
    const path_length = copyUserPath(context, frame, frame.rdi, &path_buffer) orelse return 0;
    if (!validateRange(context, frame.rsi, @sizeOf(runtime_abi.Stat), true)) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    const process = activeProcesses().get(context.handle) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const info = activeVfs().statAs(process.cwd_node, path_buffer[0..path_length], .{ .uid = process.uid, .gid = process.gid }) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const result = runtime_fd.statFromVfs(info);
    if (!copyToUser(context, frame.rsi, std.mem.asBytes(&result))) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    frame.rax = 0;
    return 0;
}

fn filesystemStatFromVfs(info: runtime_vfs.FilesystemStats) runtime_abi.FilesystemStat {
    var flags: u16 = 0;
    if (info.readonly) flags |= syscall.filesystem_stat_read_only;
    if (info.shared_blocks) flags |= syscall.filesystem_stat_shared_blocks;
    if (info.shared_nodes) flags |= syscall.filesystem_stat_shared_nodes;
    if (info.synthetic) flags |= syscall.filesystem_stat_synthetic;
    const filesystem_kind: u16 = switch (info.kind) {
        .ramfs => syscall.filesystem_type_ramfs,
        .tmpfs => syscall.filesystem_type_tmpfs,
        .boot_fat => syscall.filesystem_type_boot_fat,
        .procfs => syscall.filesystem_type_procfs,
        .devfs => syscall.filesystem_type_devfs,
        .netfs => syscall.filesystem_type_netfs,
        .zigos_persist => syscall.filesystem_type_zigos_persist,
    };
    return .{
        .block_size = info.block_size,
        .total_blocks = info.total_blocks,
        .free_blocks = info.free_blocks,
        .available_blocks = info.free_blocks,
        .total_nodes = info.total_nodes,
        .free_nodes = info.free_nodes,
        .mount_id = info.mount_id,
        .filesystem_kind = filesystem_kind,
        .flags = flags,
    };
}

fn syscallStatTimes(context: *Context, frame: *interrupt_context.Frame) u64 {
    var path_buffer: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0);
    const path_length = copyUserPath(context, frame, frame.rdi, &path_buffer) orelse return 0;
    if (!validateRange(context, frame.rsi, @sizeOf(runtime_abi.FileTimes), true)) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    const process = activeProcesses().get(context.handle) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const times = activeVfs().timestampsAs(process.cwd_node, path_buffer[0..path_length], .{ .uid = process.uid, .gid = process.gid }) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const result = runtime_abi.FileTimes{
        .created_tick = times.created_tick,
        .modified_tick = times.modified_tick,
        .changed_tick = times.changed_tick,
        .accessed_tick = times.accessed_tick,
    };
    if (!copyToUser(context, frame.rsi, std.mem.asBytes(&result))) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    frame.rax = 0;
    return 0;
}

fn syscallStatOwner(context: *Context, frame: *interrupt_context.Frame) u64 {
    var path_buffer: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0);
    const path_length = copyUserPath(context, frame, frame.rdi, &path_buffer) orelse return 0;
    if (!validateRange(context, frame.rsi, @sizeOf(runtime_abi.FileOwner), true)) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    const process = activeProcesses().get(context.handle) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const ownership = activeVfs().ownershipAs(process.cwd_node, path_buffer[0..path_length], .{ .uid = process.uid, .gid = process.gid }) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const result = runtime_abi.FileOwner{ .uid = ownership.uid, .gid = ownership.gid };
    if (!copyToUser(context, frame.rsi, std.mem.asBytes(&result))) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    frame.rax = 0;
    return 0;
}

fn syscallStatfs(context: *Context, frame: *interrupt_context.Frame) u64 {
    var path_buffer: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0);
    const path_length = copyUserPath(context, frame, frame.rdi, &path_buffer) orelse return 0;
    if (!validateRange(context, frame.rsi, @sizeOf(runtime_abi.FilesystemStat), true)) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    const process = activeProcesses().get(context.handle) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const info = activeVfs().statFilesystemAs(process.cwd_node, path_buffer[0..path_length], .{ .uid = process.uid, .gid = process.gid }) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const result = filesystemStatFromVfs(info);
    if (!copyToUser(context, frame.rsi, std.mem.asBytes(&result))) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    frame.rax = 0;
    return 0;
}

fn syscallOpenAt(context: *Context, frame: *interrupt_context.Frame) u64 {
    var path_buffer: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0);
    const path_length = copyUserPath(context, frame, frame.rsi, &path_buffer) orelse return 0;
    const bits = runtime_abi.openFlagBits(frame.rdx) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const mode = runtime_abi.mode(frame.r10) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const process = activeProcesses().get(context.handle) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const path = path_buffer[0..path_length];
    const directory_node = if (path.len != 0 and path[0] == '/')
        process.cwd_node
    else if (@as(i64, @bitCast(frame.rdi)) == syscall.directory_fd_cwd)
        process.cwd_node
    else blk: {
        const directory_fd = runtime_abi.descriptor(frame.rdi) orelse {
            frame.rax = reject(errno_bad_fd);
            return 0;
        };
        break :blk activeDescriptors().directoryNode(
            activeVfs(),
            activeProcesses(),
            context.handle,
            directory_fd,
        ) catch |err| {
            frame.rax = reject(runtime_abi.fromError(err));
            return 0;
        };
    };
    const flags = runtime_vfs.OpenFlags{
        .read = (bits & runtime_abi.open_read) != 0,
        .write = (bits & runtime_abi.open_write) != 0,
        .create = (bits & runtime_abi.open_create) != 0,
        .truncate = (bits & runtime_abi.open_truncate) != 0,
        .append = (bits & runtime_abi.open_append) != 0,
    };
    const fd = activeDescriptors().openFileAt(
        activeVfs(),
        activeProcesses(),
        context.handle,
        directory_node,
        path,
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

fn syscallMount(context: *Context, frame: *interrupt_context.Frame) u64 {
    if ((frame.r10 & ~syscall.mount_read_only) != 0 or frame.r8 != 0) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    const process = activeProcesses().get(context.handle) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    if (process.uid != 0) {
        frame.rax = reject(runtime_abi.errno_permission);
        return 0;
    }

    var target_buffer: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0);
    const target_length = copyUserPath(context, frame, frame.rsi, &target_buffer) orelse return 0;
    var filesystem_buffer: [17]u8 = @splat(0);
    const filesystem_length = copyUserString(context, frame.rdx, &filesystem_buffer) orelse {
        frame.rax = reject(errno_fault);
        return 0;
    };
    if (!std.mem.eql(u8, filesystem_buffer[0..filesystem_length], "tmpfs")) {
        frame.rax = reject(runtime_abi.errno_no_syscall);
        return 0;
    }

    var source_buffer: [33]u8 = @splat(0);
    var source: []const u8 = "none";
    if (frame.rdi != 0) {
        const source_length = copyUserString(context, frame.rdi, &source_buffer) orelse {
            frame.rax = reject(errno_fault);
            return 0;
        };
        if (source_length != 0) source = source_buffer[0..source_length];
    }
    _ = activeVfs().mountEmpty(
        process.cwd_node,
        target_buffer[0..target_length],
        .tmpfs,
        (frame.r10 & syscall.mount_read_only) != 0,
        source,
    ) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    frame.rax = 0;
    return 0;
}

fn syscallUmount(context: *Context, frame: *interrupt_context.Frame) u64 {
    if (frame.rsi != 0) {
        frame.rax = reject(errno_invalid);
        return 0;
    }
    const process = activeProcesses().get(context.handle) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    if (process.uid != 0) {
        frame.rax = reject(runtime_abi.errno_permission);
        return 0;
    }
    var target_buffer: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0);
    const target_length = copyUserPath(context, frame, frame.rdi, &target_buffer) orelse return 0;
    const mount_id = activeVfs().mountIdAtPath(process.cwd_node, target_buffer[0..target_length]) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    if ((activeVfs().mountKind(mount_id) catch null) != .tmpfs) {
        frame.rax = reject(runtime_abi.errno_no_syscall);
        return 0;
    }
    for (0..runtime_process.maximum_processes) |slot| {
        const candidate = activeProcesses().processAt(slot) orelse continue;
        if (activeVfs().nodeOnMount(mount_id, candidate.cwd_node)) {
            frame.rax = reject(runtime_abi.errno_busy);
            return 0;
        }
    }
    activeVfs().unmount(mount_id) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    frame.rax = 0;
    return 0;
}

fn syscallSymlink(context: *Context, frame: *interrupt_context.Frame) u64 {
    var target_buffer: [runtime_vfs.maximum_symlink_target_length + 1]u8 = @splat(0);
    var path_buffer: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0);
    const target_length = copyUserPath(context, frame, frame.rdi, &target_buffer) orelse return 0;
    const path_length = copyUserPath(context, frame, frame.rsi, &path_buffer) orelse return 0;
    const process = activeProcesses().get(context.handle) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    _ = activeVfs().symlinkOwned(
        process.cwd_node,
        target_buffer[0..target_length],
        path_buffer[0..path_length],
        .{ .uid = process.uid, .gid = process.gid },
        current_tick,
    ) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    frame.rax = 0;
    return 0;
}

fn syscallLink(context: *Context, frame: *interrupt_context.Frame) u64 {
    var old_buffer: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0);
    var new_buffer: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0);
    const old_length = copyUserPath(context, frame, frame.rdi, &old_buffer) orelse return 0;
    const new_length = copyUserPath(context, frame, frame.rsi, &new_buffer) orelse return 0;
    const process = activeProcesses().get(context.handle) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    _ = activeVfs().linkAs(
        process.cwd_node,
        old_buffer[0..old_length],
        new_buffer[0..new_length],
        .{ .uid = process.uid, .gid = process.gid },
        current_tick,
    ) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    frame.rax = 0;
    return 0;
}

fn syscallReadlink(context: *Context, frame: *interrupt_context.Frame) u64 {
    var path_buffer: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0);
    const path_length = copyUserPath(context, frame, frame.rdi, &path_buffer) orelse return 0;
    const length: usize = std.math.cast(usize, frame.rdx) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    if (length > maximum_io_bytes or !validateRange(context, frame.rsi, length, true)) {
        frame.rax = reject(if (length > maximum_io_bytes) errno_invalid else errno_fault);
        return 0;
    }
    const process = activeProcesses().get(context.handle) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    var output: [maximum_io_bytes]u8 = undefined;
    const count = activeVfs().readlinkAs(process.cwd_node, path_buffer[0..path_length], output[0..length], .{ .uid = process.uid, .gid = process.gid }, current_tick) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    if (!copyToUser(context, frame.rsi, output[0..count])) {
        frame.rax = reject(errno_fault);
        return 0;
    }
    frame.rax = count;
    return 0;
}

fn syscallFallocate(context: *Context, frame: *interrupt_context.Frame) u64 {
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    const bits = runtime_abi.fallocateFlagBits(frame.rsi) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const offset: usize = std.math.cast(usize, frame.rdx) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    const length: usize = std.math.cast(usize, frame.r10) orelse {
        frame.rax = reject(errno_invalid);
        return 0;
    };
    activeDescriptors().fallocate(
        activeVfs(),
        activeProcesses(),
        context.handle,
        fd,
        offset,
        length,
        .{
            .keep_size = (bits & runtime_abi.fallocate_keep_size) != 0,
            .punch_hole = (bits & runtime_abi.fallocate_punch_hole) != 0,
        },
        current_tick,
    ) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    frame.rax = 0;
    return 0;
}

fn syscallFsync(
    context: *Context,
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) u64 {
    return syscallFileSync(context, frame, fx_state, true);
}

fn syscallFdatasync(
    context: *Context,
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) u64 {
    return syscallFileSync(context, frame, fx_state, false);
}

fn syscallFileSync(
    context: *Context,
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
    include_metadata: bool,
) u64 {
    const fd = runtime_abi.descriptor(frame.rdi) orelse {
        frame.rax = reject(errno_bad_fd);
        return 0;
    };
    const node = activeDescriptors().syncNode(
        activeVfs(),
        activeProcesses(),
        context.handle,
        fd,
    ) catch |err| {
        frame.rax = reject(runtime_abi.fromError(err));
        return 0;
    };
    const callback = sync_file_fn orelse {
        frame.rax = reject(runtime_abi.errno_no_syscall);
        return 0;
    };
    const user_root = context.space.pml4_address;
    if (paging.currentCr3Address() != user_root or !paging.activateKernelAddressSpace()) {
        frame.rax = reject(runtime_abi.errno_io);
        return 0;
    }
    const result = callback(system_context, node, include_metadata);
    if (!paging.activateAddressSpace(user_root)) {
        saveContext(context, frame, fx_state);
        activeProcesses().fault(context.handle, 13, user_root) catch {};
        faults +%= 1;
        return 1;
    }
    frame.rax = if (result < 0) reject(result) else @intCast(result);
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
        if (start < user_base or end > user_end) return error.UnsupportedAddress;
        if (end >= mmap_floor) return error.ReservedAddress;
        if (rangesOverlap(start, end, trampoline_virtual, trampoline_virtual + page_bytes) or
            rangesOverlap(start, end, stack_virtual, stack_top) or
            rangesOverlap(start, end, guard_virtual, guard_virtual + page_bytes)) return error.ReservedAddress;
    }
}

fn loadImage(context: *Context, image: elf64.Image, file: []const u8) !void {
    var image_end = user_base;
    for (image.load_segments[0..image.load_count]) |segment| {
        const segment_start: usize = @intCast(segment.virtual_address);
        const segment_memory_end: usize = @intCast(segment.virtual_address + segment.memory_size);
        const segment_file_end: usize = @intCast(segment.virtual_address + segment.file_size);
        image_end = @max(image_end, segment_memory_end);
        var page = segment_start & ~(page_bytes - 1);
        while (page < alignForward(segment_memory_end, page_bytes)) : (page += page_bytes) {
            const physical = allocatePage(context.handle) orelse return error.NoRuntimeFrames;
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
            try mapOwned(context, page, physical, segment.writable(), segment.executable(), .image);
        }
    }
    context.image_end = image_end;
}

fn mapOwned(
    context: *Context,
    virtual: usize,
    physical: usize,
    writable: bool,
    executable: bool,
    kind: MappingKind,
) !void {
    const mapping_index = findFreeMapping(context) orelse {
        releasePage(physical, context.handle);
        return error.MappingLimit;
    };
    ensurePageTable(context, virtual) catch |err| {
        releasePage(physical, context.handle);
        return err;
    };
    if (!paging.mapUserPageInSpace(context.space, virtual, physical, writable, executable)) {
        releasePage(physical, context.handle);
        return error.MappingFailure;
    }
    context.mappings[mapping_index] = .{
        .used = true,
        .virtual_address = virtual,
        .physical_address = physical,
        .writable = writable,
        .executable = executable,
        .kind = kind,
    };
    context.mapping_count += 1;
}

fn mapBorrowedFilePage(context: *Context, virtual: usize, page: runtime_vfs.MappedFilePage) !void {
    const mapping_index = findFreeMapping(context) orelse {
        activeVfs().unpinFilePage(page.node, page.generation, page.slot) catch {};
        return error.MappingLimit;
    };
    ensurePageTable(context, virtual) catch |err| {
        activeVfs().unpinFilePage(page.node, page.generation, page.slot) catch {};
        return err;
    };
    if (!paging.mapUserPageInSpace(context.space, virtual, page.address, false, false)) {
        activeVfs().unpinFilePage(page.node, page.generation, page.slot) catch {};
        return error.MappingFailure;
    }
    context.mappings[mapping_index] = .{
        .used = true,
        .virtual_address = virtual,
        .physical_address = page.address,
        .writable = false,
        .executable = false,
        .kind = .file_shared,
        .file_node = page.node,
        .file_generation = page.generation,
        .file_slot = page.slot,
    };
    context.mapping_count += 1;
}

fn ensurePageTable(context: *Context, virtual: usize) !void {
    if (paging.userPageTableAddressInSpace(context.space, virtual) != null) return;
    if (context.page_table_count >= context.page_tables.len) return error.MappingLimit;
    const table_slot = findFreePageTable(context) orelse return error.MappingLimit;
    const physical = allocatePage(context.handle) orelse return error.NoRuntimeFrames;
    const virtual_base = virtual & ~(page_table_span - 1);
    if (!paging.installUserPageTableInSpace(context.space, virtual_base, physical)) {
        releasePage(physical, context.handle);
        return error.MappingFailure;
    }
    context.page_tables[table_slot] = .{
        .used = true,
        .virtual_base = virtual_base,
        .physical_address = physical,
    };
    context.page_table_count += 1;
}

fn findFreeMapping(context: *const Context) ?usize {
    for (context.mappings, 0..) |mapping, index| if (!mapping.used) return index;
    return null;
}

fn findMapping(context: *const Context, virtual: usize) ?usize {
    for (context.mappings, 0..) |mapping, index| {
        if (mapping.used and mapping.virtual_address == virtual) return index;
    }
    return null;
}

fn findFreePageTable(context: *const Context) ?usize {
    for (context.page_tables, 0..) |table, index| if (!table.used) return index;
    return null;
}

fn unmapOwned(context: *Context, mapping_index: usize) !void {
    if (mapping_index >= context.mappings.len or !context.mappings[mapping_index].used) return error.InvalidMapping;
    const mapping = context.mappings[mapping_index];
    if (!paging.unmapUserPageInSpace(context.space, mapping.virtual_address, mapping.physical_address)) {
        return error.MappingFailure;
    }
    if (mapping.kind == .file_shared)
        try activeVfs().unpinFilePage(mapping.file_node, mapping.file_generation, mapping.file_slot)
    else
        releasePage(mapping.physical_address, context.handle);
    context.mappings[mapping_index] = .{};
    context.mapping_count -= 1;
}

const InitialStack = struct {
    rsp: u64,
    argc: u64,
    argv: u64,
    envp: u64,
    auxv: u64,
};

fn buildInitialStack(
    stack_frame: usize,
    stack_page_virtual: usize,
    arguments: []const []const u8,
    environment: []const []const u8,
    uid: u32,
    gid: u32,
    capabilities: u64,
) !InitialStack {
    if (arguments.len == 0 or arguments.len > syscall.maximum_arguments or
        environment.len > syscall.maximum_environment) return error.TooManyArguments;
    var cursor = page_bytes;
    var argument_addresses: [syscall.maximum_arguments]u64 = @splat(0);
    var environment_addresses: [syscall.maximum_environment]u64 = @splat(0);

    var index = environment.len;
    while (index != 0) {
        index -= 1;
        const value = environment[index];
        if (value.len == 0 or value.len > syscall.maximum_environment_bytes or
            !validEnvironmentString(value) or cursor < value.len + 1) return error.ArgumentTooLong;
        cursor -= value.len + 1;
        const target = @as([*]u8, @ptrFromInt(stack_frame + cursor))[0 .. value.len + 1];
        @memcpy(target[0..value.len], value);
        target[value.len] = 0;
        environment_addresses[index] = stack_page_virtual + cursor;
    }
    index = arguments.len;
    while (index != 0) {
        index -= 1;
        const argument = arguments[index];
        if (argument.len == 0 or argument.len > syscall.maximum_argument_bytes or
            std.mem.indexOfScalar(u8, argument, 0) != null or cursor < argument.len + 1) return error.ArgumentTooLong;
        cursor -= argument.len + 1;
        const target = @as([*]u8, @ptrFromInt(stack_frame + cursor))[0 .. argument.len + 1];
        @memcpy(target[0..argument.len], argument);
        target[argument.len] = 0;
        argument_addresses[index] = stack_page_virtual + cursor;
    }

    const abi_version = (@as(u64, syscall.abi_major) << 32) | syscall.abi_minor;
    const auxiliary = [_]runtime_abi.AuxvEntry{
        .{ .kind = syscall.aux_pagesz, .value = page_bytes },
        .{ .kind = syscall.aux_uid, .value = uid },
        .{ .kind = syscall.aux_euid, .value = uid },
        .{ .kind = syscall.aux_gid, .value = gid },
        .{ .kind = syscall.aux_egid, .value = gid },
        .{ .kind = syscall.aux_secure, .value = 0 },
        .{ .kind = syscall.aux_zigos_abi, .value = abi_version },
        .{ .kind = syscall.aux_zigos_capabilities, .value = capabilities },
        .{ .kind = syscall.aux_null, .value = 0 },
    };
    comptime if (auxiliary.len != maximum_auxiliary_entries) @compileError("auxiliary vector count changed");

    const word_count = 1 + arguments.len + 1 + environment.len + 1 + auxiliary.len * 2;
    const vector_bytes = word_count * @sizeOf(u64);
    if (cursor < vector_bytes + 15) return error.StackOverflow;
    cursor = (cursor - vector_bytes) & ~@as(usize, 0xF);
    const words = @as([*]u64, @ptrFromInt(stack_frame + cursor))[0..word_count];
    var word_index: usize = 0;
    words[word_index] = arguments.len;
    word_index += 1;
    for (argument_addresses[0..arguments.len]) |address| {
        words[word_index] = address;
        word_index += 1;
    }
    words[word_index] = 0;
    word_index += 1;
    const envp_index = word_index;
    for (environment_addresses[0..environment.len]) |address| {
        words[word_index] = address;
        word_index += 1;
    }
    words[word_index] = 0;
    word_index += 1;
    const auxv_index = word_index;
    for (auxiliary) |entry| {
        words[word_index] = entry.kind;
        words[word_index + 1] = entry.value;
        word_index += 2;
    }
    if (word_index != word_count) return error.StackOverflow;

    return .{
        .rsp = stack_page_virtual + cursor,
        .argc = arguments.len,
        .argv = stack_page_virtual + cursor + @sizeOf(u64),
        .envp = stack_page_virtual + cursor + envp_index * @sizeOf(u64),
        .auxv = stack_page_virtual + cursor + auxv_index * @sizeOf(u64),
    };
}

fn releaseMappings(index: usize) bool {
    const context = &contexts[index];
    for (context.mappings) |mapping| {
        if (!mapping.used) continue;
        const info = paging.inspectUserPageInSpace(context.space, mapping.virtual_address) orelse return false;
        if (info.physical_address != mapping.physical_address) return false;
    }
    for (&context.mappings) |*mapping| {
        if (!mapping.used) continue;
        if (!paging.unmapUserPageInSpace(context.space, mapping.virtual_address, mapping.physical_address)) return false;
        if (mapping.kind == .file_shared) {
            activeVfs().unpinFilePage(mapping.file_node, mapping.file_generation, mapping.file_slot) catch return false;
        } else {
            releasePage(mapping.physical_address, context.handle);
        }
        mapping.* = .{};
    }
    context.mapping_count = 0;
    if (!paging.userAddressSpaceEmpty(context.space)) return false;
    for (&context.page_tables) |*table| {
        if (!table.used) continue;
        if (!paging.removeUserPageTableInSpace(context.space, table.virtual_base, table.physical_address)) return false;
        releasePage(table.physical_address, context.handle);
        if (context.table_frames[3] == table.physical_address) context.table_frames[3] = 0;
        table.* = .{};
    }
    context.page_table_count = 0;
    if (!paging.userAddressSpaceEmpty(context.space)) return false;
    for (&context.table_frames) |*frame| {
        if (frame.* != 0) releasePage(frame.*, context.handle);
        frame.* = 0;
    }
    context.space = .{ .pml4_address = 0, .pdpt_address = 0, .directory_address = 0, .table_address = 0, .table_pages = 0 };
    return true;
}

fn initializeContextDefaults(context: *Context) void {
    context.image_end = user_base;
    context.brk_base = user_base;
    context.brk_current = user_base;
    context.brk_limit = mmap_floor - page_bytes;
    context.mmap_hint = mmap_floor;
}

fn resetContext(index: usize) *Context {
    const context = &contexts[index];
    @memset(std.mem.asBytes(context), 0);
    initializeContextDefaults(context);
    return context;
}

fn releaseContext(index: usize) void {
    if (!contexts[index].used) return;
    if (contexts[index].space.pml4_address != 0) {
        if (!releaseMappings(index)) return;
    } else {
        for (&contexts[index].table_frames) |*frame| {
            if (frame.* != 0) releasePage(frame.*, contexts[index].handle);
            frame.* = 0;
        }
    }
    _ = resetContext(index);
}

fn rollbackProcess(parent_handle: u64, handle: u64) void {
    _ = activeDescriptors().releaseProcess(activeVfs(), activeProcesses(), handle) catch 0;
    activeProcesses().exit(handle, 0x7F00_0002) catch {};
    _ = activeProcesses().wait(parent_handle, handle, true) catch null;
}

fn syncMemoryUsage(context: *const Context) !void {
    const process = try activeProcesses().get(context.handle);
    try activeProcesses().setResourceUsage(
        context.handle,
        @intCast(context.mapping_count + context.page_table_count + 3),
        process.descriptor_count,
        process.socket_count,
    );
}

fn allocatePage(owner: u64) ?usize {
    const physical = page_pool.allocate(owner) orelse return null;
    @memset(@as([*]u8, @ptrFromInt(physical))[0..page_bytes], 0);
    return physical;
}

fn releasePage(physical: usize, owner: u64) void {
    _ = page_pool.release(physical, owner) catch return;
}

fn findFreeContext() ?usize {
    for (0..contexts.len) |index| if (!contexts[index].used) return index;
    return null;
}

fn findContext(handle: u64) ?usize {
    for (0..contexts.len) |index| if (contexts[index].used and contexts[index].handle == handle) return index;
    return null;
}

fn validFrame(context: *const Context, frame: *const interrupt_context.Frame) bool {
    if (frame.cs != descriptor_tables.user_code_selector or frame.ss != descriptor_tables.user_data_selector) return false;
    if (frame.rsp < stack_virtual or frame.rsp >= stack_top) return false;
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

fn validateRange(context: *const Context, address: u64, length: usize, write: bool) bool {
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

fn copyFromUser(context: *const Context, address: u64, destination: []u8) bool {
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

fn copyToUser(context: *const Context, address: u64, source: []const u8) bool {
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

fn copyUserPath(context: *const Context, frame: *interrupt_context.Frame, address: u64, destination: []u8) ?usize {
    if (destination.len != runtime_vfs.maximum_path_length + 1) {
        frame.rax = reject(errno_invalid);
        return null;
    }
    for (0..destination.len) |index| {
        var byte: [1]u8 = undefined;
        const virtual = std.math.add(u64, address, index) catch {
            frame.rax = reject(errno_fault);
            return null;
        };
        if (!copyFromUser(context, virtual, &byte)) {
            frame.rax = reject(errno_fault);
            return null;
        }
        if (byte[0] == 0) {
            runtime_vfs.validatePathBounds(destination[0..index]) catch |err| {
                frame.rax = reject(runtime_abi.fromError(err));
                return null;
            };
            return index;
        }
        if (index == destination.len - 1) {
            frame.rax = reject(runtime_abi.errno_name_too_long);
            return null;
        }
        destination[index] = byte[0];
    }
    unreachable;
}

fn copyUserString(context: *const Context, address: u64, destination: []u8) ?usize {
    if (destination.len == 0) return null;
    for (0..destination.len) |index| {
        var byte: [1]u8 = undefined;
        const virtual = std.math.add(u64, address, index) catch return null;
        if (!copyFromUser(context, virtual, &byte)) return null;
        if (byte[0] == 0) return index;
        if (index == destination.len - 1) return null;
        destination[index] = byte[0];
    }
    unreachable;
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

fn alignForwardChecked(value: usize, alignment: usize) ?usize {
    const adjusted = std.math.add(usize, value, alignment - 1) catch return null;
    return adjusted & ~(alignment - 1);
}

fn rangesOverlap(left_start: usize, left_end: usize, right_start: usize, right_end: usize) bool {
    return left_start < right_end and right_start < left_end;
}

fn reject(code: i64) u64 {
    return @bitCast(code);
}
