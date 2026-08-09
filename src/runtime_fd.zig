const std = @import("std");
const runtime_process = @import("runtime_process.zig");
const runtime_tty = @import("runtime_tty.zig");
const runtime_vfs = @import("runtime_vfs.zig");
const runtime_abi = @import("runtime_abi.zig");

pub const maximum_descriptors_per_process: usize = 32;
pub const maximum_open_descriptions: usize = 96;
pub const maximum_pipes: usize = 32;
pub const maximum_byte_range_locks_per_description: usize = 8;
pub const maximum_directory_event_batch: usize = 16;
pub const pipe_capacity: usize = 1024;
pub const invalid_open_description: u16 = 0xFFFF;
pub const invalid_resource: u16 = 0xFFFF;

pub fn statFromVfs(info: runtime_vfs.Stat) runtime_abi.Stat {
    return .{
        .node = info.node,
        .generation = info.generation,
        .kind = @intFromEnum(info.kind),
        .readonly = @intFromBool(info.readonly),
        .mode = info.mode,
        .mount_id = info.mount_id,
        .link_count = @intCast(@min(info.link_count, std.math.maxInt(u8))),
        .size = info.size,
        .modified_tick = info.modified_tick,
    };
}

pub const Error = runtime_process.Error || runtime_vfs.Error || error{
    NamespaceExists,
    NamespaceMissing,
    DescriptorLimit,
    OpenDescriptionLimit,
    PipeLimit,
    BadDescriptor,
    NotReadable,
    NotWritable,
    NotSeekable,
    BrokenPipe,
    InvalidOperation,
    RangeLockLimit,
    WouldBlock,
    ReferenceOverflow,
    CorruptState,
};

pub const DescriptionKind = enum(u8) {
    terminal,
    vfs,
    pipe_read,
    pipe_write,
    udp_socket,
    directory_watch,
};

pub const ExternalCloseFn = *const fn (context: ?*anyopaque, resource_index: u16, generation: u32) bool;
pub const ExternalPollFn = *const fn (context: ?*anyopaque, resource_index: u16, generation: u32, requested: u16) u16;

pub const ExternalResource = struct {
    index: u16,
    generation: u32,
};

pub const IoStatus = enum(u8) {
    complete,
    eof,
    blocked,
};

pub const IoResult = struct {
    status: IoStatus,
    count: usize = 0,
    wakeups: usize = 0,
};

pub const SeekWhence = enum(u8) {
    start,
    current,
    end,
};

pub const AdvisoryLock = enum(u8) {
    none,
    shared,
    exclusive,
};

pub const LockResult = enum(u8) {
    acquired,
    blocked,
};

pub const ByteRangeLock = struct {
    used: bool = false,
    start: u32 = 0,
    end: u32 = 0,
    kind: AdvisoryLock = .none,
};

const Descriptor = struct {
    used: bool = false,
    open_index: u16 = invalid_open_description,
    close_on_exec: bool = false,
};

const Namespace = struct {
    used: bool = false,
    owner_handle: u64 = 0,
    descriptors: [maximum_descriptors_per_process]Descriptor = @splat(.{}),
};

const OpenDescription = struct {
    used: bool = false,
    generation: u16 = 0,
    kind: DescriptionKind = .terminal,
    references: u16 = 0,
    readable: bool = false,
    writable: bool = false,
    append: bool = false,
    resource_index: u16 = invalid_resource,
    resource_generation: u32 = 0,
    vfs_owner: u32 = 0,
    vfs_handle: u32 = 0,
    advisory_lock: AdvisoryLock = .none,
    byte_range_locks: [maximum_byte_range_locks_per_description]ByteRangeLock = @splat(.{}),
    watch_node: u16 = runtime_vfs.invalid_node,
    watch_generation: u16 = 0,
    watch_cursor: u64 = 0,
};

const Pipe = struct {
    used: bool = false,
    generation: u16 = 0,
    bytes: [pipe_capacity]u8 = @splat(0),
    read_cursor: usize = 0,
    write_cursor: usize = 0,
    count: usize = 0,
    readers: u16 = 0,
    writers: u16 = 0,
};

pub const FileMappingInfo = struct {
    node: u16,
    generation: u16,
    size: usize,
    readable: bool,
    writable: bool,
};

pub const DescriptorInfo = struct {
    fd: u16,
    kind: DescriptionKind,
    readable: bool,
    writable: bool,
    close_on_exec: bool,
    open_id: u32,
    references: u16,
    resource_id: u64,
    offset_or_buffered: usize,
};

pub const Snapshot = struct {
    entries: [maximum_descriptors_per_process]DescriptorInfo = undefined,
    count: usize = 0,
};

pub const Report = struct {
    namespaces: usize,
    descriptors: usize,
    open_descriptions: usize,
    vfs_descriptions: usize,
    terminal_descriptions: usize,
    pipe_read_descriptions: usize,
    pipe_write_descriptions: usize,
    udp_socket_descriptions: usize,
    directory_watch_descriptions: usize,
    pipes: usize,
    duplicated_descriptors: u64,
    inherited_descriptors: u64,
    close_on_exec_closes: u64,
    descriptor_closes: u64,
    blocked_reads: u64,
    blocked_writes: u64,
    reader_wakeups: u64,
    writer_wakeups: u64,
    bytes_read: u64,
    bytes_written: u64,
    eof_reads: u64,
    broken_pipe_writes: u64,
    stale_namespace_sweeps: u64,
};

pub const System = struct {
    namespaces: [runtime_process.maximum_processes]Namespace = @splat(.{}),
    open_descriptions: [maximum_open_descriptions]OpenDescription = @splat(.{}),
    pipes: [maximum_pipes]Pipe = @splat(.{}),
    duplicated_descriptors: u64 = 0,
    inherited_descriptors: u64 = 0,
    close_on_exec_closes: u64 = 0,
    descriptor_closes: u64 = 0,
    blocked_reads: u64 = 0,
    blocked_writes: u64 = 0,
    reader_wakeups: u64 = 0,
    writer_wakeups: u64 = 0,
    bytes_read: u64 = 0,
    bytes_written: u64 = 0,
    eof_reads: u64 = 0,
    broken_pipe_writes: u64 = 0,
    stale_namespace_sweeps: u64 = 0,
    terminal_backend: ?*runtime_tty.Tty = null,
    external_context: ?*anyopaque = null,
    external_close: ?ExternalCloseFn = null,
    external_poll: ?ExternalPollFn = null,

    pub fn init() System {
        var self: System = undefined;
        self.initialize();
        return self;
    }

    pub fn initialize(self: *System) void {
        self.* = .{};
    }

    pub fn setTerminalBackend(self: *System, terminal: ?*runtime_tty.Tty) void {
        self.terminal_backend = terminal;
    }

    pub fn accountTerminalWakeups(self: *System, wakeups: usize) void {
        self.reader_wakeups +%= wakeups;
    }

    pub fn setExternalBackend(
        self: *System,
        context: ?*anyopaque,
        close_fn: ?ExternalCloseFn,
        poll_fn: ?ExternalPollFn,
    ) void {
        self.external_context = context;
        self.external_close = close_fn;
        self.external_poll = poll_fn;
    }

    pub fn bindProcess(
        self: *System,
        processes: *runtime_process.Table,
        process_handle: u64,
        install_standard_streams: bool,
    ) Error!void {
        const process = try processes.get(process_handle);
        const slot = try processSlot(process_handle);
        if (self.namespaces[slot].used) return Error.NamespaceExists;
        const required: usize = if (install_standard_streams) 3 else 0;
        if (required > process.limits.maximum_descriptors) return Error.DescriptorLimit;
        const open_slots = if (install_standard_streams)
            self.findFreeOpenDescriptions(3) orelse return Error.OpenDescriptionLimit
        else
            [3]usize{ 0, 0, 0 };

        try processes.setResourceUsage(
            process_handle,
            process.memory_pages,
            @intCast(required),
            process.socket_count,
        );
        self.namespaces[slot] = .{ .used = true, .owner_handle = process_handle };
        if (!install_standard_streams) return;

        const access = [_]struct { readable: bool, writable: bool }{
            .{ .readable = true, .writable = false },
            .{ .readable = false, .writable = true },
            .{ .readable = false, .writable = true },
        };
        for (open_slots, 0..) |open_index, fd| {
            self.initializeDescription(open_index, .terminal, access[fd].readable, access[fd].writable, false, invalid_resource, 0, 0, 0);
            self.namespaces[slot].descriptors[fd] = .{
                .used = true,
                .open_index = @intCast(open_index),
            };
        }
    }

    pub fn cloneProcess(
        self: *System,
        processes: *runtime_process.Table,
        source_handle: u64,
        target_handle: u64,
    ) Error!usize {
        _ = try processes.get(source_handle);
        const target_process = try processes.get(target_handle);
        const source_slot = try self.resolveNamespace(source_handle);
        const target_slot = try processSlot(target_handle);
        if (self.namespaces[target_slot].used) return Error.NamespaceExists;
        const count = descriptorCount(&self.namespaces[source_slot]);
        const socket_count = socketDescriptionCount(self, &self.namespaces[source_slot]);
        if (count > target_process.limits.maximum_descriptors) return Error.DescriptorLimit;
        if (socket_count > target_process.limits.maximum_sockets) return Error.QuotaExceeded;
        for (self.namespaces[source_slot].descriptors) |descriptor| {
            if (!descriptor.used) continue;
            const open_index: usize = descriptor.open_index;
            if (open_index >= self.open_descriptions.len or !self.open_descriptions[open_index].used) return Error.CorruptState;
            if (self.open_descriptions[open_index].references == std.math.maxInt(u16)) return Error.ReferenceOverflow;
        }

        try processes.setResourceUsage(
            target_handle,
            target_process.memory_pages,
            @intCast(count),
            @intCast(socket_count),
        );
        self.namespaces[target_slot] = .{
            .used = true,
            .owner_handle = target_handle,
            .descriptors = self.namespaces[source_slot].descriptors,
        };
        for (self.namespaces[target_slot].descriptors) |descriptor| {
            if (!descriptor.used) continue;
            self.open_descriptions[descriptor.open_index].references += 1;
        }
        self.inherited_descriptors +%= count;
        return count;
    }

    pub fn releaseProcess(
        self: *System,
        vfs: *runtime_vfs.Vfs,
        processes: *runtime_process.Table,
        process_handle: u64,
    ) Error!usize {
        _ = try processes.get(process_handle);
        const slot = try self.resolveNamespace(process_handle);
        var closed: usize = 0;
        for (0..maximum_descriptors_per_process) |fd| {
            if (!self.namespaces[slot].descriptors[fd].used) continue;
            try self.closeDescriptorAt(vfs, processes, slot, fd);
            closed += 1;
        }
        self.namespaces[slot] = .{};
        const process = try processes.get(process_handle);
        try processes.setResourceUsage(process_handle, process.memory_pages, 0, process.socket_count);
        return closed;
    }

    pub fn sweepStaleNamespaces(
        self: *System,
        vfs: *runtime_vfs.Vfs,
        processes: *runtime_process.Table,
    ) Error!usize {
        var swept: usize = 0;
        for (&self.namespaces, 0..) |*namespace, slot| {
            if (!namespace.used) continue;
            _ = processes.get(namespace.owner_handle) catch {
                for (0..maximum_descriptors_per_process) |fd| {
                    if (!self.namespaces[slot].descriptors[fd].used) continue;
                    try self.closeDescriptorAt(vfs, processes, slot, fd);
                }
                namespace.* = .{};
                swept += 1;
                continue;
            };
        }
        self.stale_namespace_sweeps +%= swept;
        return swept;
    }

    pub fn openFile(
        self: *System,
        vfs: *runtime_vfs.Vfs,
        processes: *runtime_process.Table,
        process_handle: u64,
        path: []const u8,
        flags: runtime_vfs.OpenFlags,
        mode: u16,
        tick: u64,
    ) Error!u16 {
        const process = try processes.get(process_handle);
        return self.openFileAt(vfs, processes, process_handle, process.cwd_node, path, flags, mode, tick);
    }

    pub fn openFileAt(
        self: *System,
        vfs: *runtime_vfs.Vfs,
        processes: *runtime_process.Table,
        process_handle: u64,
        directory_node: u16,
        path: []const u8,
        flags: runtime_vfs.OpenFlags,
        mode: u16,
        tick: u64,
    ) Error!u16 {
        const process = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        try self.requireDescriptorCapacity(&self.namespaces[namespace_slot], process, 1);
        const fd = self.findFreeDescriptors(&self.namespaces[namespace_slot], 1) orelse return Error.DescriptorLimit;
        const open_slot = self.findFreeOpenDescriptions(1) orelse return Error.OpenDescriptionLimit;
        const generation = nextGeneration(self.open_descriptions[open_slot[0]].generation);
        const owner = makeOpenId(open_slot[0], generation);
        if (flags.create and !runtime_vfs.validStoredMode(mode)) return runtime_vfs.Error.InvalidPath;
        const creation_mode = runtime_vfs.applyCreationUmask(mode, process.umask);
        const vfs_handle = try vfs.openOwned(owner, directory_node, path, flags, creation_mode, .{ .uid = process.uid, .gid = process.gid }, tick);
        const stream = try vfs.pseudoStreamOpen(owner, vfs_handle);
        const kind: DescriptionKind = if (stream == .console) .terminal else .vfs;
        if (kind == .terminal and self.terminal_backend == null) {
            try vfs.close(owner, vfs_handle);
            return Error.InvalidOperation;
        }
        self.initializeDescription(open_slot[0], kind, flags.read, flags.write, flags.append, invalid_resource, 0, owner, vfs_handle);
        self.namespaces[namespace_slot].descriptors[fd[0]] = .{
            .used = true,
            .open_index = @intCast(open_slot[0]),
        };
        self.syncDescriptorCount(processes, process_handle) catch |err| {
            self.namespaces[namespace_slot].descriptors[fd[0]] = .{};
            _ = vfs.close(owner, vfs_handle) catch {};
            self.clearDescription(open_slot[0]);
            return err;
        };
        return @intCast(fd[0]);
    }

    pub fn createDirectoryWatch(
        self: *System,
        vfs: *const runtime_vfs.Vfs,
        processes: *runtime_process.Table,
        process_handle: u64,
        directory_fd: u16,
    ) Error!u16 {
        const process = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        const source_index = try self.resolveDescriptor(namespace_slot, directory_fd);
        const source = self.open_descriptions[source_index];
        if (source.kind != .vfs) return Error.NotDirectory;
        const info = try vfs.openInfo(source.vfs_owner, source.vfs_handle);
        const node_stat = try vfs.statNode(info.node);
        if (node_stat.kind != .directory or node_stat.generation != info.node_generation) return Error.NotDirectory;
        try self.requireDescriptorCapacity(&self.namespaces[namespace_slot], process, 1);
        const descriptor_slots = self.findFreeDescriptors(&self.namespaces[namespace_slot], 1) orelse return Error.DescriptorLimit;
        const open_slots = self.findFreeOpenDescriptions(1) orelse return Error.OpenDescriptionLimit;
        const cursor = try vfs.directoryEventCursor(info.node, info.node_generation);
        self.initializeDescription(open_slots[0], .directory_watch, true, false, false, invalid_resource, 0, 0, 0);
        self.open_descriptions[open_slots[0]].watch_node = info.node;
        self.open_descriptions[open_slots[0]].watch_generation = info.node_generation;
        self.open_descriptions[open_slots[0]].watch_cursor = cursor;
        self.namespaces[namespace_slot].descriptors[descriptor_slots[0]] = .{
            .used = true,
            .open_index = @intCast(open_slots[0]),
        };
        self.syncDescriptorCount(processes, process_handle) catch |err| {
            self.namespaces[namespace_slot].descriptors[descriptor_slots[0]] = .{};
            self.clearDescription(open_slots[0]);
            return err;
        };
        return @intCast(descriptor_slots[0]);
    }

    pub fn createExternalDescriptor(
        self: *System,
        processes: *runtime_process.Table,
        process_handle: u64,
        kind: DescriptionKind,
        resource: ExternalResource,
        readable: bool,
        writable: bool,
        close_on_exec: bool,
    ) Error!u16 {
        if (kind != .udp_socket or resource.index == invalid_resource or resource.generation == 0) return Error.InvalidOperation;
        const process = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        try self.requireDescriptorCapacity(&self.namespaces[namespace_slot], process, 1);
        if (socketDescriptionCount(self, &self.namespaces[namespace_slot]) >= process.limits.maximum_sockets) return Error.QuotaExceeded;
        const descriptor_slots = self.findFreeDescriptors(&self.namespaces[namespace_slot], 1) orelse return Error.DescriptorLimit;
        const open_slots = self.findFreeOpenDescriptions(1) orelse return Error.OpenDescriptionLimit;
        self.initializeDescription(open_slots[0], kind, readable, writable, false, resource.index, resource.generation, 0, 0);
        self.namespaces[namespace_slot].descriptors[descriptor_slots[0]] = .{
            .used = true,
            .open_index = @intCast(open_slots[0]),
            .close_on_exec = close_on_exec,
        };
        self.syncDescriptorCount(processes, process_handle) catch |err| {
            self.namespaces[namespace_slot].descriptors[descriptor_slots[0]] = .{};
            self.clearDescription(open_slots[0]);
            return err;
        };
        return @intCast(descriptor_slots[0]);
    }

    pub fn externalResource(
        self: *const System,
        processes: *const runtime_process.Table,
        process_handle: u64,
        fd: u16,
        expected_kind: DescriptionKind,
    ) Error!ExternalResource {
        _ = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        const open_index = try self.resolveDescriptor(namespace_slot, fd);
        const description = self.open_descriptions[open_index];
        if (description.kind != expected_kind or description.resource_index == invalid_resource or description.resource_generation == 0) return Error.InvalidOperation;
        return .{ .index = description.resource_index, .generation = description.resource_generation };
    }

    pub fn createPipe(
        self: *System,
        processes: *runtime_process.Table,
        process_handle: u64,
    ) Error![2]u16 {
        const process = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        try self.requireDescriptorCapacity(&self.namespaces[namespace_slot], process, 2);
        const descriptors = self.findFreeDescriptors(&self.namespaces[namespace_slot], 2) orelse return Error.DescriptorLimit;
        const opens = self.findFreeOpenDescriptions(2) orelse return Error.OpenDescriptionLimit;
        const pipe_index = self.findFreePipe() orelse return Error.PipeLimit;
        const pipe_generation = nextGeneration(self.pipes[pipe_index].generation);
        self.pipes[pipe_index] = .{
            .used = true,
            .generation = pipe_generation,
            .readers = 1,
            .writers = 1,
        };
        self.initializeDescription(opens[0], .pipe_read, true, false, false, @intCast(pipe_index), pipe_generation, 0, 0);
        self.initializeDescription(opens[1], .pipe_write, false, true, false, @intCast(pipe_index), pipe_generation, 0, 0);
        self.namespaces[namespace_slot].descriptors[descriptors[0]] = .{
            .used = true,
            .open_index = @intCast(opens[0]),
        };
        self.namespaces[namespace_slot].descriptors[descriptors[1]] = .{
            .used = true,
            .open_index = @intCast(opens[1]),
        };
        try self.syncDescriptorCount(processes, process_handle);
        return .{ @intCast(descriptors[0]), @intCast(descriptors[1]) };
    }

    pub fn duplicate(
        self: *System,
        processes: *runtime_process.Table,
        process_handle: u64,
        source_fd: u16,
    ) Error!u16 {
        const process = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        try self.requireDescriptorCapacity(&self.namespaces[namespace_slot], process, 1);
        const source = try self.resolveDescriptor(namespace_slot, source_fd);
        if (self.open_descriptions[source].references == std.math.maxInt(u16)) return Error.ReferenceOverflow;
        const target = self.findFreeDescriptors(&self.namespaces[namespace_slot], 1) orelse return Error.DescriptorLimit;
        self.open_descriptions[source].references += 1;
        self.namespaces[namespace_slot].descriptors[target[0]] = .{
            .used = true,
            .open_index = @intCast(source),
            .close_on_exec = false,
        };
        self.duplicated_descriptors +%= 1;
        try self.syncDescriptorCount(processes, process_handle);
        return @intCast(target[0]);
    }

    pub fn duplicateTo(
        self: *System,
        vfs: *runtime_vfs.Vfs,
        processes: *runtime_process.Table,
        process_handle: u64,
        source_fd: u16,
        target_fd: u16,
    ) Error!u16 {
        if (target_fd >= maximum_descriptors_per_process) return Error.BadDescriptor;
        const process = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        const source = try self.resolveDescriptor(namespace_slot, source_fd);
        if (source_fd == target_fd) return target_fd;
        const target_was_used = self.namespaces[namespace_slot].descriptors[target_fd].used;
        if (!target_was_used) try self.requireDescriptorCapacity(&self.namespaces[namespace_slot], process, 1);
        if (self.open_descriptions[source].references == std.math.maxInt(u16)) return Error.ReferenceOverflow;
        if (target_was_used) try self.closeDescriptorAt(vfs, processes, namespace_slot, target_fd);
        self.open_descriptions[source].references += 1;
        self.namespaces[namespace_slot].descriptors[target_fd] = .{
            .used = true,
            .open_index = @intCast(source),
            .close_on_exec = false,
        };
        self.duplicated_descriptors +%= 1;
        try self.syncDescriptorCount(processes, process_handle);
        return target_fd;
    }

    pub fn configurePipelineChild(
        self: *System,
        vfs: *runtime_vfs.Vfs,
        processes: *runtime_process.Table,
        process_handle: u64,
        stdin_source: ?u16,
        stdout_source: ?u16,
    ) Error!usize {
        _ = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        if (stdin_source == null and stdout_source == null) return Error.InvalidOperation;

        if (stdin_source) |fd| {
            if (fd < 3) return Error.InvalidOperation;
            const open_index = try self.resolveDescriptor(namespace_slot, fd);
            const description = self.open_descriptions[open_index];
            if (description.kind != .pipe_read or !description.readable) return Error.NotReadable;
            if (description.references == std.math.maxInt(u16)) return Error.ReferenceOverflow;
        }
        if (stdout_source) |fd| {
            if (fd < 3) return Error.InvalidOperation;
            const open_index = try self.resolveDescriptor(namespace_slot, fd);
            const description = self.open_descriptions[open_index];
            if (description.kind != .pipe_write or !description.writable) return Error.NotWritable;
            if (description.references == std.math.maxInt(u16)) return Error.ReferenceOverflow;
        }

        if (stdin_source) |fd| _ = try self.duplicateTo(vfs, processes, process_handle, fd, 0);
        if (stdout_source) |fd| _ = try self.duplicateTo(vfs, processes, process_handle, fd, 1);

        var closed: usize = 0;
        for (3..maximum_descriptors_per_process) |fd| {
            if (!self.namespaces[namespace_slot].descriptors[fd].used) continue;
            try self.closeDescriptorAt(vfs, processes, namespace_slot, fd);
            closed += 1;
        }
        try self.syncDescriptorCount(processes, process_handle);
        return closed;
    }

    pub fn setCloseOnExec(
        self: *System,
        processes: *runtime_process.Table,
        process_handle: u64,
        fd: u16,
        enabled: bool,
    ) Error!void {
        _ = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        _ = try self.resolveDescriptor(namespace_slot, fd);
        self.namespaces[namespace_slot].descriptors[fd].close_on_exec = enabled;
    }

    pub fn closeOnExec(
        self: *System,
        vfs: *runtime_vfs.Vfs,
        processes: *runtime_process.Table,
        process_handle: u64,
    ) Error!usize {
        _ = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        var closed: usize = 0;
        for (0..maximum_descriptors_per_process) |fd| {
            const descriptor = self.namespaces[namespace_slot].descriptors[fd];
            if (!descriptor.used or !descriptor.close_on_exec) continue;
            try self.closeDescriptorAt(vfs, processes, namespace_slot, fd);
            closed += 1;
        }
        self.close_on_exec_closes +%= closed;
        try self.syncDescriptorCount(processes, process_handle);
        return closed;
    }

    pub fn close(
        self: *System,
        vfs: *runtime_vfs.Vfs,
        processes: *runtime_process.Table,
        process_handle: u64,
        fd: u16,
    ) Error!void {
        _ = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        _ = try self.resolveDescriptor(namespace_slot, fd);
        try self.closeDescriptorAt(vfs, processes, namespace_slot, fd);
        try self.syncDescriptorCount(processes, process_handle);
    }

    pub fn closeAll(
        self: *System,
        vfs: *runtime_vfs.Vfs,
        processes: *runtime_process.Table,
        process_handle: u64,
    ) Error!usize {
        _ = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        var closed: usize = 0;
        for (0..maximum_descriptors_per_process) |fd| {
            if (!self.namespaces[namespace_slot].descriptors[fd].used) continue;
            try self.closeDescriptorAt(vfs, processes, namespace_slot, fd);
            closed += 1;
        }
        try self.syncDescriptorCount(processes, process_handle);
        return closed;
    }

    pub fn read(
        self: *System,
        vfs: *runtime_vfs.Vfs,
        processes: *runtime_process.Table,
        process_handle: u64,
        fd: u16,
        output: []u8,
    ) Error!IoResult {
        return self.readInternal(vfs, processes, process_handle, fd, output, null);
    }

    pub fn readAtTick(
        self: *System,
        vfs: *runtime_vfs.Vfs,
        processes: *runtime_process.Table,
        process_handle: u64,
        fd: u16,
        output: []u8,
        tick: u64,
    ) Error!IoResult {
        return self.readInternal(vfs, processes, process_handle, fd, output, tick);
    }

    fn readInternal(
        self: *System,
        vfs: *runtime_vfs.Vfs,
        processes: *runtime_process.Table,
        process_handle: u64,
        fd: u16,
        output: []u8,
        access_tick: ?u64,
    ) Error!IoResult {
        _ = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        const open_index = try self.resolveDescriptor(namespace_slot, fd);
        const description = self.open_descriptions[open_index];
        if (!description.readable) return Error.NotReadable;
        if (output.len == 0) return .{ .status = .complete };
        switch (description.kind) {
            .terminal => {
                const terminal = self.terminal_backend orelse {
                    self.eof_reads +%= 1;
                    return .{ .status = .eof };
                };
                const result = try terminal.read(processes, process_handle, output);
                return switch (result.status) {
                    .complete => blk: {
                        self.bytes_read +%= result.count;
                        break :blk .{ .status = .complete, .count = result.count };
                    },
                    .eof => blk: {
                        self.eof_reads +%= 1;
                        break :blk .{ .status = .eof };
                    },
                    .blocked => blk: {
                        self.blocked_reads +%= 1;
                        break :blk .{ .status = .blocked };
                    },
                };
            },
            .udp_socket => return Error.InvalidOperation,
            .vfs => {
                const count = if (access_tick) |tick|
                    try vfs.readOpenAtTick(description.vfs_owner, description.vfs_handle, output, tick)
                else
                    try vfs.readOpen(description.vfs_owner, description.vfs_handle, output);
                self.bytes_read +%= count;
                if (count == 0) {
                    self.eof_reads +%= 1;
                    return .{ .status = .eof };
                }
                return .{ .status = .complete, .count = count };
            },
            .directory_watch => {
                if (output.len < @sizeOf(runtime_abi.DirectoryEvent) or output.len % @sizeOf(runtime_abi.DirectoryEvent) != 0)
                    return Error.InvalidOperation;
                const capacity = @min(output.len / @sizeOf(runtime_abi.DirectoryEvent), maximum_directory_event_batch);
                var changes: [maximum_directory_event_batch]runtime_vfs.DirectoryChange = @splat(.{});
                var watch = &self.open_descriptions[open_index];
                const count = try vfs.readDirectoryEvents(
                    watch.watch_node,
                    watch.watch_generation,
                    &watch.watch_cursor,
                    changes[0..capacity],
                );
                if (count == 0) return Error.WouldBlock;
                var events: [maximum_directory_event_batch]runtime_abi.DirectoryEvent = @splat(std.mem.zeroes(runtime_abi.DirectoryEvent));
                for (changes[0..count], 0..) |change, index| {
                    events[index].sequence = change.sequence;
                    events[index].node = change.node;
                    events[index].generation = change.generation;
                    events[index].kind = @intFromEnum(change.kind);
                    events[index].flags = change.flags;
                    events[index].name_length = change.name_length;
                    @memcpy(events[index].name[0..change.name_length], change.nameSlice());
                }
                const byte_count = count * @sizeOf(runtime_abi.DirectoryEvent);
                @memcpy(output[0..byte_count], std.mem.asBytes(&events)[0..byte_count]);
                self.bytes_read +%= byte_count;
                return .{ .status = .complete, .count = byte_count };
            },
            .pipe_read => {
                const pipe_index = try self.resolvePipe(description);
                if (self.pipes[pipe_index].count != 0) {
                    const count = self.readPipe(pipe_index, output);
                    const wakeups = processes.wakeMatching(.pipe_write, pipeWaitKey(pipe_index, self.pipes[pipe_index].generation), true);
                    self.writer_wakeups +%= wakeups;
                    self.bytes_read +%= count;
                    return .{ .status = .complete, .count = count, .wakeups = wakeups };
                }
                if (self.pipes[pipe_index].writers == 0) {
                    self.eof_reads +%= 1;
                    return .{ .status = .eof };
                }
                try processes.block(process_handle, .pipe_read, pipeWaitKey(pipe_index, self.pipes[pipe_index].generation));
                self.blocked_reads +%= 1;
                return .{ .status = .blocked };
            },
            .pipe_write => return Error.NotReadable,
        }
    }

    pub fn write(
        self: *System,
        vfs: *runtime_vfs.Vfs,
        processes: *runtime_process.Table,
        process_handle: u64,
        fd: u16,
        bytes: []const u8,
        tick: u64,
    ) Error!IoResult {
        _ = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        const open_index = try self.resolveDescriptor(namespace_slot, fd);
        const description = self.open_descriptions[open_index];
        if (!description.writable) return Error.NotWritable;
        if (bytes.len == 0) return .{ .status = .complete };
        switch (description.kind) {
            .terminal => {
                self.bytes_written +%= bytes.len;
                return .{ .status = .complete, .count = bytes.len };
            },
            .udp_socket, .directory_watch => return Error.InvalidOperation,
            .vfs => {
                const count = try vfs.writeOpen(description.vfs_owner, description.vfs_handle, bytes, tick);
                self.bytes_written +%= count;
                return .{ .status = .complete, .count = count };
            },
            .pipe_write => {
                const pipe_index = try self.resolvePipe(description);
                if (self.pipes[pipe_index].readers == 0) {
                    self.broken_pipe_writes +%= 1;
                    return Error.BrokenPipe;
                }
                if (self.pipes[pipe_index].count == pipe_capacity) {
                    try processes.block(process_handle, .pipe_write, pipeWaitKey(pipe_index, self.pipes[pipe_index].generation));
                    self.blocked_writes +%= 1;
                    return .{ .status = .blocked };
                }
                const count = self.writePipe(pipe_index, bytes);
                const wakeups = processes.wakeMatching(.pipe_read, pipeWaitKey(pipe_index, self.pipes[pipe_index].generation), true);
                self.reader_wakeups +%= wakeups;
                self.bytes_written +%= count;
                return .{ .status = .complete, .count = count, .wakeups = wakeups };
            },
            .pipe_read => return Error.NotWritable,
        }
    }

    pub fn seek(
        self: *System,
        vfs: *runtime_vfs.Vfs,
        processes: *runtime_process.Table,
        process_handle: u64,
        fd: u16,
        offset: i64,
        whence: SeekWhence,
    ) Error!usize {
        _ = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        const open_index = try self.resolveDescriptor(namespace_slot, fd);
        const description = self.open_descriptions[open_index];
        if (description.kind != .vfs) return Error.NotSeekable;
        return vfs.seek(description.vfs_owner, description.vfs_handle, offset, switch (whence) {
            .start => .start,
            .current => .current,
            .end => .end,
        });
    }

    pub fn truncate(
        self: *System,
        vfs: *runtime_vfs.Vfs,
        processes: *runtime_process.Table,
        process_handle: u64,
        fd: u16,
        size: usize,
        tick: u64,
    ) Error!void {
        _ = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        const open_index = try self.resolveDescriptor(namespace_slot, fd);
        const description = self.open_descriptions[open_index];
        if (description.kind != .vfs) return Error.NotSeekable;
        if (!description.writable) return Error.NotWritable;
        try vfs.truncateOpen(description.vfs_owner, description.vfs_handle, size, tick);
    }

    pub fn fallocate(
        self: *System,
        vfs: *runtime_vfs.Vfs,
        processes: *runtime_process.Table,
        process_handle: u64,
        fd: u16,
        offset: usize,
        length: usize,
        flags: runtime_vfs.AllocationFlags,
        tick: u64,
    ) Error!void {
        _ = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        const open_index = try self.resolveDescriptor(namespace_slot, fd);
        const description = self.open_descriptions[open_index];
        if (description.kind != .vfs) return Error.NotSeekable;
        if (!description.writable) return Error.NotWritable;
        try vfs.allocateOpen(description.vfs_owner, description.vfs_handle, offset, length, flags, tick);
    }

    pub fn flock(
        self: *System,
        vfs: *const runtime_vfs.Vfs,
        processes: *runtime_process.Table,
        process_handle: u64,
        fd: u16,
        requested: AdvisoryLock,
        nonblocking: bool,
    ) Error!LockResult {
        _ = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        const open_index = try self.resolveDescriptor(namespace_slot, fd);
        var description = &self.open_descriptions[open_index];
        if (description.kind != .vfs) return Error.InvalidOperation;
        const info = try vfs.openInfo(description.vfs_owner, description.vfs_handle);
        const node_stat = try vfs.statNode(info.node);
        if (node_stat.kind != .file or node_stat.generation != info.node_generation) return Error.InvalidOperation;
        const wait_key = fileLockWaitKey(info.node, info.node_generation);

        if (requested == .none) {
            if (description.advisory_lock != .none) {
                description.advisory_lock = .none;
                _ = processes.wakeMatching(.file_lock, wait_key, true);
            }
            return .acquired;
        }
        if (description.advisory_lock == requested) return .acquired;
        if (description.advisory_lock == .exclusive and requested == .shared) {
            description.advisory_lock = .shared;
            _ = processes.wakeMatching(.file_lock, wait_key, true);
            return .acquired;
        }

        const previous = description.advisory_lock;
        if (previous == .shared and requested == .exclusive) description.advisory_lock = .none;
        if (!(try self.advisoryLockConflicts(vfs, open_index, info.node, info.node_generation, requested))) {
            description.advisory_lock = requested;
            return .acquired;
        }
        if (nonblocking) {
            description.advisory_lock = previous;
            return .blocked;
        }
        if (previous == .shared) _ = processes.wakeMatching(.file_lock, wait_key, true);
        processes.block(process_handle, .file_lock, wait_key) catch |err| {
            description.advisory_lock = previous;
            return err;
        };
        return .blocked;
    }

    pub fn lockRange(
        self: *System,
        vfs: *const runtime_vfs.Vfs,
        processes: *runtime_process.Table,
        process_handle: u64,
        fd: u16,
        start_value: u64,
        length_value: u64,
        requested: AdvisoryLock,
        nonblocking: bool,
    ) Error!LockResult {
        _ = try processes.get(process_handle);
        if (length_value == 0 or start_value >= runtime_vfs.maximum_file_size or
            length_value > runtime_vfs.maximum_file_size - start_value)
        {
            return Error.InvalidOperation;
        }
        const start: u32 = @intCast(start_value);
        const end: u32 = @intCast(start_value + length_value);
        const namespace_slot = try self.resolveNamespace(process_handle);
        const open_index = try self.resolveDescriptor(namespace_slot, fd);
        var description = &self.open_descriptions[open_index];
        if (description.kind != .vfs) return Error.InvalidOperation;
        const info = try vfs.openInfo(description.vfs_owner, description.vfs_handle);
        const node_stat = try vfs.statNode(info.node);
        if (node_stat.kind != .file or node_stat.generation != info.node_generation) return Error.InvalidOperation;
        const wait_key = fileLockWaitKey(info.node, info.node_generation);

        if (requested == .none) {
            description.byte_range_locks = try replaceByteRangeLocks(description.byte_range_locks, start, end, .none);
            _ = processes.wakeMatching(.file_lock, wait_key, true);
            return .acquired;
        }
        if (!(try self.byteRangeLockConflicts(vfs, open_index, info.node, info.node_generation, start, end, requested))) {
            description.byte_range_locks = try replaceByteRangeLocks(description.byte_range_locks, start, end, requested);
            return .acquired;
        }
        if (nonblocking) return .blocked;

        const previous = description.byte_range_locks;
        const had_overlap = byteRangeLocksOverlap(previous, start, end);
        description.byte_range_locks = try replaceByteRangeLocks(previous, start, end, .none);
        if (had_overlap) _ = processes.wakeMatching(.file_lock, wait_key, true);
        processes.block(process_handle, .file_lock, wait_key) catch |err| {
            description.byte_range_locks = previous;
            return err;
        };
        return .blocked;
    }

    pub fn descriptorKind(
        self: *const System,
        processes: *const runtime_process.Table,
        process_handle: u64,
        fd: u16,
    ) Error!DescriptionKind {
        _ = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        const open_index = try self.resolveDescriptor(namespace_slot, fd);
        return self.open_descriptions[open_index].kind;
    }

    pub fn stat(
        self: *const System,
        vfs: *const runtime_vfs.Vfs,
        processes: *const runtime_process.Table,
        process_handle: u64,
        fd: u16,
    ) Error!runtime_abi.Stat {
        _ = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        const open_index = try self.resolveDescriptor(namespace_slot, fd);
        const description = self.open_descriptions[open_index];
        return switch (description.kind) {
            .terminal => blk: {
                if (description.vfs_handle != 0) {
                    break :blk statFromVfs(try vfs.statOpen(description.vfs_owner, description.vfs_handle));
                }
                break :blk .{
                    .node = std.math.maxInt(u32),
                    .generation = description.generation,
                    .kind = @intFromEnum(runtime_vfs.Kind.pseudo),
                    .readonly = 0,
                    .mode = 0o666,
                    .mount_id = 0,
                    .link_count = 1,
                    .size = 0,
                    .modified_tick = 0,
                };
            },
            .vfs => statFromVfs(try vfs.statOpen(description.vfs_owner, description.vfs_handle)),
            .udp_socket => .{
                .node = std.math.maxInt(u32) - @as(u32, description.resource_index),
                .generation = @truncate(description.resource_generation),
                .kind = @intFromEnum(runtime_vfs.Kind.pseudo),
                .readonly = 0,
                .mode = 0o666,
                .mount_id = 0,
                .link_count = 1,
                .size = 0,
                .modified_tick = 0,
            },
            .directory_watch => .{
                .node = description.watch_node,
                .generation = description.watch_generation,
                .kind = @intFromEnum(runtime_vfs.Kind.pseudo),
                .readonly = 1,
                .mode = 0o400,
                .mount_id = 0,
                .link_count = 1,
                .size = 0,
                .modified_tick = 0,
            },
            .pipe_read, .pipe_write => blk: {
                const pipe_index = try self.resolvePipe(description);
                break :blk .{
                    .node = std.math.maxInt(u32) - @as(u32, @intCast(pipe_index)),
                    .generation = @truncate(description.resource_generation),
                    .kind = @intFromEnum(runtime_vfs.Kind.pseudo),
                    .readonly = 0,
                    .mode = if (description.kind == .pipe_read) 0o400 else 0o200,
                    .mount_id = 0,
                    .link_count = 1,
                    .size = self.pipes[pipe_index].count,
                    .modified_tick = 0,
                };
            },
        };
    }

    pub fn getDirectoryEntries(
        self: *System,
        vfs: *runtime_vfs.Vfs,
        processes: *runtime_process.Table,
        process_handle: u64,
        fd: u16,
        output: []runtime_vfs.DirectoryRecord,
        tick: u64,
    ) Error!usize {
        _ = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        const open_index = try self.resolveDescriptor(namespace_slot, fd);
        const description = self.open_descriptions[open_index];
        if (description.kind != .vfs) return Error.NotDirectory;
        return vfs.readDirectoryOpen(description.vfs_owner, description.vfs_handle, output, tick);
    }

    pub fn poll(
        self: *const System,
        vfs: *const runtime_vfs.Vfs,
        processes: *const runtime_process.Table,
        process_handle: u64,
        fd: u16,
        requested: u16,
    ) Error!u16 {
        const allowed = runtime_abi.poll_readable | runtime_abi.poll_writable |
            runtime_abi.poll_error | runtime_abi.poll_hangup;
        if ((requested & ~allowed) != 0) return Error.InvalidOperation;
        _ = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        const open_index = try self.resolveDescriptor(namespace_slot, fd);
        const description = self.open_descriptions[open_index];
        var ready: u16 = 0;
        switch (description.kind) {
            .terminal => {
                if (description.readable) {
                    const terminal = self.terminal_backend orelse return Error.InvalidOperation;
                    ready |= try terminal.poll(processes, process_handle, requested);
                }
                if (description.writable) ready |= runtime_abi.poll_writable;
            },
            .vfs => ready |= try vfs.pollOpen(description.vfs_owner, description.vfs_handle, requested),
            .directory_watch => {
                const event_ready = vfs.directoryEventsReady(description.watch_node, description.watch_generation, description.watch_cursor) catch {
                    ready |= runtime_abi.poll_error | runtime_abi.poll_hangup;
                    return ready & requested;
                };
                if (event_ready) ready |= runtime_abi.poll_readable;
            },
            .udp_socket => {
                const poll_fn = self.external_poll orelse return Error.InvalidOperation;
                ready |= poll_fn(self.external_context, description.resource_index, description.resource_generation, requested);
            },
            .pipe_read => {
                const pipe_index = try self.resolvePipe(description);
                const pipe = self.pipes[pipe_index];
                if (pipe.count != 0 or pipe.writers == 0) ready |= runtime_abi.poll_readable;
                if (pipe.writers == 0) ready |= runtime_abi.poll_hangup;
            },
            .pipe_write => {
                const pipe_index = try self.resolvePipe(description);
                const pipe = self.pipes[pipe_index];
                if (pipe.readers == 0) {
                    ready |= runtime_abi.poll_error | runtime_abi.poll_hangup;
                } else if (pipe.count < pipe_capacity) {
                    ready |= runtime_abi.poll_writable;
                }
            },
        }
        return ready & requested;
    }

    pub fn directoryNode(
        self: *const System,
        vfs: *const runtime_vfs.Vfs,
        processes: *const runtime_process.Table,
        process_handle: u64,
        fd: u16,
    ) Error!u16 {
        _ = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        const open_index = try self.resolveDescriptor(namespace_slot, fd);
        const description = self.open_descriptions[open_index];
        if (description.kind != .vfs) return Error.NotDirectory;
        return vfs.directoryNodeOpen(description.vfs_owner, description.vfs_handle);
    }

    pub fn fileMappingInfo(
        self: *const System,
        vfs: *const runtime_vfs.Vfs,
        processes: *const runtime_process.Table,
        process_handle: u64,
        fd: u16,
    ) Error!FileMappingInfo {
        _ = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        const open_index = try self.resolveDescriptor(namespace_slot, fd);
        const description = self.open_descriptions[open_index];
        if (description.kind != .vfs) return Error.InvalidOperation;
        const open_info = try vfs.openInfo(description.vfs_owner, description.vfs_handle);
        const node_stat = try vfs.statNode(open_info.node);
        if (node_stat.kind != .file or node_stat.generation != open_info.node_generation) return Error.InvalidOperation;
        return .{
            .node = node_stat.node,
            .generation = node_stat.generation,
            .size = node_stat.size,
            .readable = description.readable and open_info.readable,
            .writable = description.writable and open_info.writable,
        };
    }

    pub fn syncNode(
        self: *const System,
        vfs: *const runtime_vfs.Vfs,
        processes: *const runtime_process.Table,
        process_handle: u64,
        fd: u16,
    ) Error!u16 {
        _ = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        const open_index = try self.resolveDescriptor(namespace_slot, fd);
        const description = self.open_descriptions[open_index];
        if (description.kind != .vfs and !(description.kind == .terminal and description.vfs_handle != 0))
            return Error.InvalidOperation;
        return vfs.syncOpenNode(description.vfs_owner, description.vfs_handle);
    }

    pub fn persistentSyncNode(
        self: *const System,
        vfs: *const runtime_vfs.Vfs,
        processes: *const runtime_process.Table,
        process_handle: u64,
        fd: u16,
    ) Error!?u16 {
        const node = try self.syncNode(vfs, processes, process_handle, fd);
        return if (try vfs.persistentNode(node)) node else null;
    }

    pub fn persistentSyncRequired(
        self: *const System,
        vfs: *const runtime_vfs.Vfs,
        processes: *const runtime_process.Table,
        process_handle: u64,
        fd: u16,
    ) Error!bool {
        return (try self.persistentSyncNode(vfs, processes, process_handle, fd)) != null;
    }

    pub fn ioctl(
        self: *System,
        vfs: *runtime_vfs.Vfs,
        processes: *runtime_process.Table,
        process_handle: u64,
        fd: u16,
        request: u64,
        argument: u64,
    ) Error!u64 {
        _ = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        const open_index = try self.resolveDescriptor(namespace_slot, fd);
        const description = self.open_descriptions[open_index];
        return switch (description.kind) {
            .terminal => blk: {
                const terminal = self.terminal_backend orelse return Error.InvalidOperation;
                if (request == runtime_abi.constants.ioctl_tty_get_flags) break :blk terminal.modeFlags();
                if (request == runtime_abi.constants.ioctl_tty_set_flags) {
                    if (!terminal.setModeFlags(argument)) return Error.InvalidOperation;
                    break :blk 0;
                }
                return Error.UnsupportedOperation;
            },
            .vfs => vfs.ioctlOpen(description.vfs_owner, description.vfs_handle, request, argument),
            else => Error.UnsupportedOperation,
        };
    }

    pub fn snapshot(
        self: *const System,
        vfs: *const runtime_vfs.Vfs,
        processes: *const runtime_process.Table,
        process_handle: u64,
    ) Error!Snapshot {
        _ = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        var result = Snapshot{};
        for (self.namespaces[namespace_slot].descriptors, 0..) |descriptor, fd| {
            if (!descriptor.used) continue;
            const description = self.open_descriptions[descriptor.open_index];
            var resource_id: u64 = 0;
            var offset_or_buffered: usize = 0;
            switch (description.kind) {
                .terminal => {
                    if (description.vfs_handle != 0) {
                        const info = try vfs.openInfo(description.vfs_owner, description.vfs_handle);
                        resource_id = (@as(u64, info.node_generation) << 32) | info.node;
                        offset_or_buffered = info.offset;
                    }
                },
                .vfs => {
                    const info = try vfs.openInfo(description.vfs_owner, description.vfs_handle);
                    resource_id = (@as(u64, info.node_generation) << 32) | info.node;
                    offset_or_buffered = info.offset;
                },
                .directory_watch => {
                    resource_id = (@as(u64, description.watch_generation) << 32) | description.watch_node;
                    offset_or_buffered = @intCast(description.watch_cursor);
                },
                .udp_socket => {
                    resource_id = (@as(u64, description.resource_generation) << 16) | description.resource_index;
                },
                .pipe_read, .pipe_write => {
                    const pipe_index = try self.resolvePipe(description);
                    resource_id = pipeWaitKey(pipe_index, self.pipes[pipe_index].generation);
                    offset_or_buffered = self.pipes[pipe_index].count;
                },
            }
            result.entries[result.count] = .{
                .fd = @intCast(fd),
                .kind = description.kind,
                .readable = description.readable,
                .writable = description.writable,
                .close_on_exec = descriptor.close_on_exec,
                .open_id = makeOpenId(descriptor.open_index, description.generation),
                .references = description.references,
                .resource_id = resource_id,
                .offset_or_buffered = offset_or_buffered,
            };
            result.count += 1;
        }
        return result;
    }

    pub fn report(self: *const System) Report {
        var result = Report{
            .namespaces = 0,
            .descriptors = 0,
            .open_descriptions = 0,
            .vfs_descriptions = 0,
            .terminal_descriptions = 0,
            .pipe_read_descriptions = 0,
            .pipe_write_descriptions = 0,
            .udp_socket_descriptions = 0,
            .directory_watch_descriptions = 0,
            .pipes = 0,
            .duplicated_descriptors = self.duplicated_descriptors,
            .inherited_descriptors = self.inherited_descriptors,
            .close_on_exec_closes = self.close_on_exec_closes,
            .descriptor_closes = self.descriptor_closes,
            .blocked_reads = self.blocked_reads,
            .blocked_writes = self.blocked_writes,
            .reader_wakeups = self.reader_wakeups,
            .writer_wakeups = self.writer_wakeups,
            .bytes_read = self.bytes_read,
            .bytes_written = self.bytes_written,
            .eof_reads = self.eof_reads,
            .broken_pipe_writes = self.broken_pipe_writes,
            .stale_namespace_sweeps = self.stale_namespace_sweeps,
        };
        for (self.namespaces) |namespace| {
            if (!namespace.used) continue;
            result.namespaces += 1;
            result.descriptors += descriptorCount(&namespace);
        }
        for (self.open_descriptions) |description| {
            if (!description.used) continue;
            result.open_descriptions += 1;
            switch (description.kind) {
                .terminal => result.terminal_descriptions += 1,
                .vfs => result.vfs_descriptions += 1,
                .pipe_read => result.pipe_read_descriptions += 1,
                .pipe_write => result.pipe_write_descriptions += 1,
                .udp_socket => result.udp_socket_descriptions += 1,
                .directory_watch => result.directory_watch_descriptions += 1,
            }
        }
        for (self.pipes) |pipe| result.pipes += @intFromBool(pipe.used);
        return result;
    }

    pub fn validate(
        self: *const System,
        vfs: *const runtime_vfs.Vfs,
        processes: *const runtime_process.Table,
    ) bool {
        if (!vfs.validate()) return false;
        var expected_references: [maximum_open_descriptions]u16 = @splat(0);
        for (self.namespaces, 0..) |namespace, slot| {
            if (!namespace.used) continue;
            const owner_slot = processSlot(namespace.owner_handle) catch return false;
            if (owner_slot != slot) return false;
            const process = processes.get(namespace.owner_handle) catch return false;
            var count: usize = 0;
            for (namespace.descriptors) |descriptor| {
                if (!descriptor.used) continue;
                count += 1;
                if (descriptor.open_index >= self.open_descriptions.len) return false;
                if (!self.open_descriptions[descriptor.open_index].used) return false;
                expected_references[descriptor.open_index] +|= 1;
            }
            if (count != process.descriptor_count or count > process.limits.maximum_descriptors) return false;
        }

        var expected_readers: [maximum_pipes]u16 = @splat(0);
        var expected_writers: [maximum_pipes]u16 = @splat(0);
        for (self.open_descriptions, 0..) |description, index| {
            if (!description.used) {
                if (expected_references[index] != 0) return false;
                continue;
            }
            if (description.generation == 0 or description.references == 0 or description.references != expected_references[index]) return false;
            switch (description.kind) {
                .terminal => {
                    if (description.resource_index != invalid_resource) return false;
                    if (description.vfs_handle != 0) _ = vfs.openInfo(description.vfs_owner, description.vfs_handle) catch return false;
                },
                .vfs => {
                    const info = vfs.openInfo(description.vfs_owner, description.vfs_handle) catch return false;
                    if (description.advisory_lock != .none) {
                        const node_stat = vfs.statNode(info.node) catch return false;
                        if (node_stat.kind != .file or node_stat.generation != info.node_generation) return false;
                        for (self.open_descriptions[0..index]) |other| {
                            if (!other.used or other.kind != .vfs or other.advisory_lock == .none) continue;
                            const other_info = vfs.openInfo(other.vfs_owner, other.vfs_handle) catch return false;
                            if (other_info.node != info.node or other_info.node_generation != info.node_generation) continue;
                            if (description.advisory_lock == .exclusive or other.advisory_lock == .exclusive) return false;
                        }
                    }
                    if (!validateByteRangeLocks(description.byte_range_locks)) return false;
                    if (hasByteRangeLocks(description.byte_range_locks)) {
                        const node_stat = vfs.statNode(info.node) catch return false;
                        if (node_stat.kind != .file or node_stat.generation != info.node_generation) return false;
                        for (self.open_descriptions[0..index]) |other| {
                            if (!other.used or other.kind != .vfs or !hasByteRangeLocks(other.byte_range_locks)) continue;
                            const other_info = vfs.openInfo(other.vfs_owner, other.vfs_handle) catch return false;
                            if (other_info.node != info.node or other_info.node_generation != info.node_generation) continue;
                            for (description.byte_range_locks) |current_lock| {
                                if (!current_lock.used) continue;
                                for (other.byte_range_locks) |other_lock| {
                                    if (!other_lock.used or !rangesOverlap(current_lock.start, current_lock.end, other_lock.start, other_lock.end)) continue;
                                    if (current_lock.kind == .exclusive or other_lock.kind == .exclusive) return false;
                                }
                            }
                        }
                    }
                },
                .directory_watch => {
                    if (description.resource_index != invalid_resource or description.vfs_handle != 0 or description.watch_generation == 0) return false;
                    const node_stat = vfs.statNode(description.watch_node) catch return false;
                    if (node_stat.kind != .directory or node_stat.generation != description.watch_generation) return false;
                    const current = vfs.directoryEventCursor(description.watch_node, description.watch_generation) catch return false;
                    if (description.watch_cursor > current) return false;
                },
                .udp_socket => {
                    if (description.resource_index == invalid_resource or description.resource_generation == 0) return false;
                },
                .pipe_read, .pipe_write => {
                    const pipe_index = self.resolvePipe(description) catch return false;
                    if (description.kind == .pipe_read) expected_readers[pipe_index] +|= 1 else expected_writers[pipe_index] +|= 1;
                },
            }
        }
        for (self.pipes, 0..) |pipe, index| {
            if (!pipe.used) {
                if (expected_readers[index] != 0 or expected_writers[index] != 0) return false;
                continue;
            }
            if (pipe.generation == 0 or pipe.count > pipe_capacity or pipe.read_cursor >= pipe_capacity or pipe.write_cursor >= pipe_capacity) return false;
            if (pipe.readers != expected_readers[index] or pipe.writers != expected_writers[index]) return false;
            if (pipe.readers == 0 and pipe.writers == 0) return false;
        }
        return true;
    }

    fn advisoryLockConflicts(
        self: *const System,
        vfs: *const runtime_vfs.Vfs,
        owner_index: usize,
        node: u16,
        node_generation: u16,
        requested: AdvisoryLock,
    ) Error!bool {
        for (self.open_descriptions, 0..) |other, index| {
            if (index == owner_index or !other.used or other.kind != .vfs or other.advisory_lock == .none) continue;
            const info = try vfs.openInfo(other.vfs_owner, other.vfs_handle);
            if (info.node != node or info.node_generation != node_generation) continue;
            if (requested == .exclusive or other.advisory_lock == .exclusive) return true;
        }
        return false;
    }

    fn byteRangeLockConflicts(
        self: *const System,
        vfs: *const runtime_vfs.Vfs,
        owner_index: usize,
        node: u16,
        node_generation: u16,
        start: u32,
        end: u32,
        requested: AdvisoryLock,
    ) Error!bool {
        for (self.open_descriptions, 0..) |other, index| {
            if (index == owner_index or !other.used or other.kind != .vfs or !hasByteRangeLocks(other.byte_range_locks)) continue;
            const info = try vfs.openInfo(other.vfs_owner, other.vfs_handle);
            if (info.node != node or info.node_generation != node_generation) continue;
            for (other.byte_range_locks) |other_lock| {
                if (!other_lock.used or !rangesOverlap(start, end, other_lock.start, other_lock.end)) continue;
                if (requested == .exclusive or other_lock.kind == .exclusive) return true;
            }
        }
        return false;
    }

    fn resolveNamespace(self: *const System, process_handle: u64) Error!usize {
        const slot = try processSlot(process_handle);
        const namespace = self.namespaces[slot];
        if (!namespace.used or namespace.owner_handle != process_handle) return Error.NamespaceMissing;
        return slot;
    }

    fn resolveDescriptor(self: *const System, namespace_slot: usize, fd: u16) Error!usize {
        if (fd >= maximum_descriptors_per_process) return Error.BadDescriptor;
        const descriptor = self.namespaces[namespace_slot].descriptors[fd];
        if (!descriptor.used or descriptor.open_index >= self.open_descriptions.len) return Error.BadDescriptor;
        const description = self.open_descriptions[descriptor.open_index];
        if (!description.used or description.references == 0) return Error.BadDescriptor;
        return descriptor.open_index;
    }

    fn resolvePipe(self: *const System, description: OpenDescription) Error!usize {
        if (description.resource_index >= self.pipes.len) return Error.CorruptState;
        const pipe = self.pipes[description.resource_index];
        if (!pipe.used or @as(u32, pipe.generation) != description.resource_generation) return Error.CorruptState;
        return description.resource_index;
    }

    fn requireDescriptorCapacity(self: *const System, namespace: *const Namespace, process: runtime_process.Process, additional: usize) Error!void {
        _ = self;
        if (descriptorCount(namespace) + additional > process.limits.maximum_descriptors) return Error.DescriptorLimit;
    }

    fn syncDescriptorCount(self: *const System, processes: *runtime_process.Table, process_handle: u64) Error!void {
        const slot = try self.resolveNamespace(process_handle);
        const process = try processes.get(process_handle);
        try processes.setResourceUsage(
            process_handle,
            process.memory_pages,
            @intCast(descriptorCount(&self.namespaces[slot])),
            @intCast(socketDescriptionCount(self, &self.namespaces[slot])),
        );
    }

    fn closeDescriptorAt(
        self: *System,
        vfs: *runtime_vfs.Vfs,
        processes: *runtime_process.Table,
        namespace_slot: usize,
        fd: usize,
    ) Error!void {
        const descriptor = self.namespaces[namespace_slot].descriptors[fd];
        if (!descriptor.used or descriptor.open_index >= self.open_descriptions.len) return Error.BadDescriptor;
        const open_index: usize = descriptor.open_index;
        const description = self.open_descriptions[open_index];
        if (!description.used or description.references == 0) return Error.CorruptState;
        var advisory_wait_key: ?u64 = null;
        if (description.references == 1 and description.kind == .vfs and
            (description.advisory_lock != .none or hasByteRangeLocks(description.byte_range_locks)))
        {
            const info = try vfs.openInfo(description.vfs_owner, description.vfs_handle);
            advisory_wait_key = fileLockWaitKey(info.node, info.node_generation);
        }
        if (description.references == 1) switch (description.kind) {
            .terminal => if (description.vfs_handle != 0) try vfs.close(description.vfs_owner, description.vfs_handle),
            .vfs => try vfs.close(description.vfs_owner, description.vfs_handle),
            .udp_socket => {
                const close_fn = self.external_close orelse return Error.InvalidOperation;
                if (!close_fn(self.external_context, description.resource_index, description.resource_generation)) return Error.CorruptState;
            },
            else => {},
        };
        self.namespaces[namespace_slot].descriptors[fd] = .{};
        self.open_descriptions[open_index].references -= 1;
        self.descriptor_closes +%= 1;
        if (self.open_descriptions[open_index].references != 0) return;

        switch (description.kind) {
            .terminal, .vfs, .udp_socket, .directory_watch => {},
            .pipe_read => {
                const pipe_index = try self.resolvePipe(description);
                if (self.pipes[pipe_index].readers == 0) return Error.CorruptState;
                self.pipes[pipe_index].readers -= 1;
                const wakeups = processes.wakeMatching(.pipe_write, pipeWaitKey(pipe_index, self.pipes[pipe_index].generation), true);
                self.writer_wakeups +%= wakeups;
                self.releasePipeIfUnused(pipe_index);
            },
            .pipe_write => {
                const pipe_index = try self.resolvePipe(description);
                if (self.pipes[pipe_index].writers == 0) return Error.CorruptState;
                self.pipes[pipe_index].writers -= 1;
                const wakeups = processes.wakeMatching(.pipe_read, pipeWaitKey(pipe_index, self.pipes[pipe_index].generation), true);
                self.reader_wakeups +%= wakeups;
                self.releasePipeIfUnused(pipe_index);
            },
        }
        self.clearDescription(open_index);
        if (advisory_wait_key) |wait_key| _ = processes.wakeMatching(.file_lock, wait_key, true);
    }

    fn releasePipeIfUnused(self: *System, pipe_index: usize) void {
        if (self.pipes[pipe_index].readers != 0 or self.pipes[pipe_index].writers != 0) return;
        const generation = self.pipes[pipe_index].generation;
        self.pipes[pipe_index] = .{ .generation = generation };
    }

    fn initializeDescription(
        self: *System,
        index: usize,
        kind: DescriptionKind,
        readable: bool,
        writable: bool,
        append: bool,
        resource_index: u16,
        resource_generation: u32,
        vfs_owner: u32,
        vfs_handle: u32,
    ) void {
        const generation = nextGeneration(self.open_descriptions[index].generation);
        self.open_descriptions[index] = .{
            .used = true,
            .generation = generation,
            .kind = kind,
            .references = 1,
            .readable = readable,
            .writable = writable,
            .append = append,
            .resource_index = resource_index,
            .resource_generation = resource_generation,
            .vfs_owner = vfs_owner,
            .vfs_handle = vfs_handle,
        };
    }

    fn clearDescription(self: *System, index: usize) void {
        const generation = self.open_descriptions[index].generation;
        self.open_descriptions[index] = .{ .generation = generation };
    }

    fn findFreeOpenDescriptions(self: *const System, comptime count: usize) ?[count]usize {
        var result: [count]usize = undefined;
        var found: usize = 0;
        for (self.open_descriptions, 0..) |description, index| {
            if (description.used) continue;
            result[found] = index;
            found += 1;
            if (found == count) return result;
        }
        return null;
    }

    fn findFreeDescriptors(self: *const System, namespace: *const Namespace, comptime count: usize) ?[count]usize {
        _ = self;
        var result: [count]usize = undefined;
        var found: usize = 0;
        for (namespace.descriptors, 0..) |descriptor, index| {
            if (descriptor.used) continue;
            result[found] = index;
            found += 1;
            if (found == count) return result;
        }
        return null;
    }

    fn findFreePipe(self: *const System) ?usize {
        for (self.pipes, 0..) |pipe, index| if (!pipe.used) return index;
        return null;
    }

    fn readPipe(self: *System, pipe_index: usize, output: []u8) usize {
        var pipe = &self.pipes[pipe_index];
        const count = @min(output.len, pipe.count);
        const first = @min(count, pipe_capacity - pipe.read_cursor);
        @memcpy(output[0..first], pipe.bytes[pipe.read_cursor .. pipe.read_cursor + first]);
        const second = count - first;
        if (second != 0) @memcpy(output[first .. first + second], pipe.bytes[0..second]);
        pipe.read_cursor = (pipe.read_cursor + count) % pipe_capacity;
        pipe.count -= count;
        return count;
    }

    fn writePipe(self: *System, pipe_index: usize, bytes: []const u8) usize {
        var pipe = &self.pipes[pipe_index];
        const count = @min(bytes.len, pipe_capacity - pipe.count);
        const first = @min(count, pipe_capacity - pipe.write_cursor);
        @memcpy(pipe.bytes[pipe.write_cursor .. pipe.write_cursor + first], bytes[0..first]);
        const second = count - first;
        if (second != 0) @memcpy(pipe.bytes[0..second], bytes[first .. first + second]);
        pipe.write_cursor = (pipe.write_cursor + count) % pipe_capacity;
        pipe.count += count;
        return count;
    }
};

fn processSlot(handle: u64) Error!usize {
    const slot: usize = @intCast(handle & 0xFFFF_FFFF);
    if (slot >= runtime_process.maximum_processes) return Error.InvalidHandle;
    return slot;
}

fn socketDescriptionCount(self: *const System, namespace: *const Namespace) usize {
    var seen: [maximum_open_descriptions]bool = @splat(false);
    var count: usize = 0;
    for (namespace.descriptors) |descriptor| {
        if (!descriptor.used or descriptor.open_index >= self.open_descriptions.len or seen[descriptor.open_index]) continue;
        seen[descriptor.open_index] = true;
        if (self.open_descriptions[descriptor.open_index].used and self.open_descriptions[descriptor.open_index].kind == .udp_socket) count += 1;
    }
    return count;
}

fn descriptorCount(namespace: *const Namespace) usize {
    var count: usize = 0;
    for (namespace.descriptors) |descriptor| count += @intFromBool(descriptor.used);
    return count;
}

fn nextGeneration(current: u16) u16 {
    const next = current +% 1;
    return if (next == 0) 1 else next;
}

fn makeOpenId(index: usize, generation: u16) u32 {
    return (@as(u32, generation) << 16) | @as(u32, @intCast(index + 1));
}

fn rangesOverlap(start_a: u32, end_a: u32, start_b: u32, end_b: u32) bool {
    return start_a < end_b and start_b < end_a;
}

fn hasByteRangeLocks(locks: [maximum_byte_range_locks_per_description]ByteRangeLock) bool {
    for (locks) |lock| if (lock.used) return true;
    return false;
}

fn byteRangeLocksOverlap(locks: [maximum_byte_range_locks_per_description]ByteRangeLock, start: u32, end: u32) bool {
    for (locks) |lock| {
        if (lock.used and rangesOverlap(start, end, lock.start, lock.end)) return true;
    }
    return false;
}

fn validateByteRangeLocks(locks: [maximum_byte_range_locks_per_description]ByteRangeLock) bool {
    var seen_unused = false;
    var previous_end: u32 = 0;
    for (locks) |lock| {
        if (!lock.used) {
            seen_unused = true;
            continue;
        }
        if (seen_unused or lock.kind == .none or lock.start >= lock.end or lock.end > runtime_vfs.maximum_file_size) return false;
        if (lock.start < previous_end) return false;
        previous_end = lock.end;
    }
    return true;
}

fn replaceByteRangeLocks(
    current: [maximum_byte_range_locks_per_description]ByteRangeLock,
    start: u32,
    end: u32,
    replacement: AdvisoryLock,
) Error![maximum_byte_range_locks_per_description]ByteRangeLock {
    var scratch: [maximum_byte_range_locks_per_description + 2]ByteRangeLock = @splat(.{});
    var count: usize = 0;
    for (current) |lock| {
        if (!lock.used) continue;
        if (!rangesOverlap(lock.start, lock.end, start, end)) {
            scratch[count] = lock;
            count += 1;
            continue;
        }
        if (lock.start < start) {
            scratch[count] = .{ .used = true, .start = lock.start, .end = start, .kind = lock.kind };
            count += 1;
        }
        if (lock.end > end) {
            scratch[count] = .{ .used = true, .start = end, .end = lock.end, .kind = lock.kind };
            count += 1;
        }
    }
    if (replacement != .none) {
        scratch[count] = .{ .used = true, .start = start, .end = end, .kind = replacement };
        count += 1;
    }

    var i: usize = 1;
    while (i < count) : (i += 1) {
        const value = scratch[i];
        var j = i;
        while (j > 0 and scratch[j - 1].start > value.start) : (j -= 1) scratch[j] = scratch[j - 1];
        scratch[j] = value;
    }

    var result: [maximum_byte_range_locks_per_description]ByteRangeLock = @splat(.{});
    var result_count: usize = 0;
    for (scratch[0..count]) |lock| {
        if (result_count != 0) {
            var previous = &result[result_count - 1];
            if (previous.kind == lock.kind and previous.end == lock.start) {
                previous.end = lock.end;
                continue;
            }
        }
        if (result_count == result.len) return Error.RangeLockLimit;
        result[result_count] = lock;
        result_count += 1;
    }
    return result;
}

pub fn fileLockWaitKey(node: u16, generation: u16) u64 {
    return (@as(u64, generation) << 32) | node;
}

pub fn pipeWaitKey(index: usize, generation: u16) u64 {
    return (@as(u64, generation) << 32) | @as(u64, @intCast(index + 1));
}

fn initializeTestFilesystem(fs: *runtime_vfs.Vfs) !void {
    _ = try fs.mkdir(0, "/tmp", 0o777, 0);
}

fn initializeTestProcess(table: *runtime_process.Table, name: []const u8, limit: u16) !u64 {
    return table.spawn(table.initHandle(), .userspace, name, &.{name}, 0, 1000, 1000, 0, .{
        .maximum_descriptors = limit,
    });
}

test "VFS console opens as a terminal and supports ioctl state" {
    var fs = runtime_vfs.Vfs.init();
    const dev = try fs.mkdir(0, "/dev", 0o755, 0);
    const console_operations = runtime_vfs.PseudoOperations{ .stream = .console };
    _ = try fs.createPseudoWithOperations(dev, "console", 0o666, 0, &console_operations, null);
    _ = try fs.mount(0, "/dev", .devfs, true, "kernel-devices");

    var processes = runtime_process.Table.init(0);
    const process = processes.initHandle();
    var tty = runtime_tty.Tty.init(process);
    var system = System.init();
    system.setTerminalBackend(&tty);
    try system.bindProcess(&processes, process, true);

    const fd = try system.openFile(&fs, &processes, process, "/dev/console", .{ .write = true }, 0, 0);
    try std.testing.expectEqual(DescriptionKind.terminal, try system.descriptorKind(&processes, process, fd));
    const info = try system.stat(&fs, &processes, process, fd);
    try std.testing.expectEqual(@as(u16, 0o666), info.mode);
    try std.testing.expectEqual(@as(u8, 0), info.readonly);
    try std.testing.expectEqual(
        runtime_abi.constants.tty_echo | runtime_abi.constants.tty_canonical | runtime_abi.constants.tty_signals,
        try system.ioctl(&fs, &processes, process, fd, runtime_abi.constants.ioctl_tty_get_flags, 0),
    );
    try std.testing.expectEqual(@as(u64, 0), try system.ioctl(
        &fs,
        &processes,
        process,
        fd,
        runtime_abi.constants.ioctl_tty_set_flags,
        runtime_abi.constants.tty_echo,
    ));
    try std.testing.expectEqual(runtime_abi.constants.tty_echo, tty.modeFlags());
    try std.testing.expectEqual(@as(usize, 7), (try system.write(&fs, &processes, process, fd, "console", 0)).count);
    try system.close(&fs, &processes, process, fd);
    try std.testing.expect(system.validate(&fs, &processes));
}

test "regular descriptors expose generation safe file mapping metadata" {
    var fs = runtime_vfs.Vfs.init();
    try initializeTestFilesystem(&fs);
    _ = try fs.putFile(0, "/tmp/mapped", "mapped-data", 0o640, false, 1);
    var processes = runtime_process.Table.init(0);
    var system = System.init();
    const handle = processes.initHandle();
    try system.bindProcess(&processes, handle, true);
    const fd = try system.openFile(&fs, &processes, handle, "/tmp/mapped", .{ .read = true, .write = true }, 0, 2);
    try fs.chmod(0, "/tmp/mapped", 0, 3);
    const info = try system.fileMappingInfo(&fs, &processes, handle, fd);
    const node_stat = try fs.stat(0, "/tmp/mapped");
    try std.testing.expectEqual(node_stat.node, info.node);
    try std.testing.expectEqual(node_stat.generation, info.generation);
    try std.testing.expectEqual(node_stat.size, info.size);
    try std.testing.expect(info.readable);
    try std.testing.expect(info.writable);
    try std.testing.expectEqual(@as(usize, 1), (try system.write(&fs, &processes, handle, fd, "!", 4)).count);
    try system.close(&fs, &processes, handle, fd);
    try std.testing.expect(system.validate(&fs, &processes));
}

test "numeric descriptor namespace uses lowest free descriptor" {
    var fs = runtime_vfs.Vfs.init();
    try initializeTestFilesystem(&fs);
    var processes = runtime_process.Table.init(0);
    var system = System.init();
    const handle = try initializeTestProcess(&processes, "owner", 32);
    try system.bindProcess(&processes, handle, true);
    const owner_credentials = runtime_vfs.Ownership{ .uid = 1000, .gid = 1000 };
    const group_credentials = runtime_vfs.Ownership{ .uid = 2000, .gid = 1000 };
    const other_credentials = runtime_vfs.Ownership{ .uid = 2000, .gid = 2000 };
    const stranger_credentials = runtime_vfs.Ownership{ .uid = 3000, .gid = 3000 };
    const first = try system.openFile(&fs, &processes, handle, "/tmp/a", .{ .read = true, .write = true, .create = true }, 0o644, 1);
    try std.testing.expectEqual(@as(u16, 3), first);
    try std.testing.expectEqual(owner_credentials, try fs.ownership(0, "/tmp/a"));

    const group_name = "group";
    const group_handle = try processes.spawn(processes.initHandle(), .userspace, group_name, &.{group_name}, 0, 2000, 1000, 0, .{ .maximum_descriptors = 32 });
    try system.bindProcess(&processes, group_handle, true);
    const other_name = "other";
    const other_handle = try processes.spawn(processes.initHandle(), .userspace, other_name, &.{other_name}, 0, 2000, 2000, 0, .{ .maximum_descriptors = 32 });
    try system.bindProcess(&processes, other_handle, true);

    // Exactly one class is selected: owner first, then matching primary group,
    // otherwise other. A permissive lower-priority class never leaks through.
    try fs.chmod(0, "/tmp/a", 0o640, 2);
    const group_read = try system.openFile(&fs, &processes, group_handle, "/tmp/a", .{ .read = true }, 0, 3);
    try system.close(&fs, &processes, group_handle, group_read);
    try std.testing.expectError(runtime_vfs.Error.PermissionDenied, system.openFile(&fs, &processes, group_handle, "/tmp/a", .{ .write = true }, 0, 4));
    try std.testing.expectError(runtime_vfs.Error.PermissionDenied, system.openFile(&fs, &processes, other_handle, "/tmp/a", .{ .read = true }, 0, 5));
    try fs.chmod(0, "/tmp/a", 0o604, 6);
    try std.testing.expectError(runtime_vfs.Error.PermissionDenied, system.openFile(&fs, &processes, group_handle, "/tmp/a", .{ .read = true }, 0, 7));
    const other_read = try system.openFile(&fs, &processes, other_handle, "/tmp/a", .{ .read = true }, 0, 8);
    try system.close(&fs, &processes, other_handle, other_read);

    // chmod is owner-or-root only. Mode changes affect later opens, while the
    // already-open owner description retains the access granted at open time.
    try std.testing.expectError(runtime_vfs.Error.PermissionDenied, fs.chmodAs(0, "/tmp/a", 0o777, group_credentials, 9));
    try fs.chmodAs(0, "/tmp/a", 0o600, owner_credentials, 10);
    try fs.chmod(0, "/tmp/a", 0, 11);
    try std.testing.expectEqual(@as(usize, 1), (try system.write(&fs, &processes, handle, first, "x", 12)).count);
    try std.testing.expectError(runtime_vfs.Error.PermissionDenied, system.openFile(&fs, &processes, handle, "/tmp/a", .{ .write = true }, 0, 13));
    const a_node = (try fs.stat(0, "/tmp/a")).node;
    try std.testing.expect(try fs.accessAllowedNode(a_node, .{}, .{ .read = true, .write = true, .execute = true }));

    // Directory search is execute; namespace mutation is write+execute on the
    // containing directory. The created inode inherits the mutating process.
    _ = try fs.mkdirOwned(0, "/tmp/team", 0o730, owner_credentials, 14);
    _ = try fs.resolveDirectoryAs(0, "/tmp/team", group_credentials);
    try std.testing.expectError(runtime_vfs.Error.PermissionDenied, fs.resolveDirectoryAs(0, "/tmp/team", other_credentials));
    _ = try fs.createOwned(0, "/tmp/team/member", 0o640, group_credentials, 15);
    try std.testing.expectEqual(group_credentials, try fs.ownership(0, "/tmp/team/member"));
    try std.testing.expectError(runtime_vfs.Error.PermissionDenied, fs.createOwned(0, "/tmp/team/denied", 0o600, other_credentials, 16));
    try std.testing.expectError(runtime_vfs.Error.PermissionDenied, fs.unlinkAs(0, "/tmp/team/member", other_credentials, 17));
    try fs.unlinkAs(0, "/tmp/team/member", group_credentials, 18);

    // Executability is independent from readability: group execute alone can
    // launch the file, while the matching owner class cannot borrow group X.
    _ = try fs.createOwned(0, "/tmp/run", 0o010, owner_credentials, 19);
    try std.testing.expectEqual(@as(usize, 0), (try fs.executableViewAs(0, "/tmp/run", group_credentials)).len);
    try std.testing.expectError(runtime_vfs.Error.PermissionDenied, fs.executableViewAs(0, "/tmp/run", owner_credentials));
    try std.testing.expectEqual(@as(usize, 0), (try fs.executableViewAs(0, "/tmp/run", .{})).len);

    try system.close(&fs, &processes, handle, first);
    try std.testing.expectEqual(@as(u16, 0), try processes.setUmask(handle, 0o027));
    const second = try system.openFile(&fs, &processes, handle, "/tmp/b", .{ .read = true, .write = true, .create = true }, 0o666, 20);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(u16, 0o640), (try fs.stat(0, "/tmp/b")).mode);
    const setid_fd = try system.openFile(&fs, &processes, handle, "/tmp/setid", .{ .read = true, .write = true, .create = true }, 0o6755, 21);
    try std.testing.expectEqual(@as(u16, 0o6750), (try fs.stat(0, "/tmp/setid")).mode);
    try fs.chmodAs(0, "/tmp/setid", 0o6650, owner_credentials, 22);
    try std.testing.expectEqual(@as(u16, 0o6650), (try fs.stat(0, "/tmp/setid")).mode);
    try fs.chmodAs(0, "/tmp/setid", 0o7650, owner_credentials, 23);
    try std.testing.expectEqual(@as(u16, 0o7650), (try fs.stat(0, "/tmp/setid")).mode);
    try system.close(&fs, &processes, handle, setid_fd);

    // Sticky directories add a victim-ownership rule on top of ordinary W+X.
    // Root, the directory owner, or the victim owner may remove/rename; an
    // unrelated UID may not. Replacement rename checks both removed entries.
    _ = try fs.mkdirOwned(0, "/tmp/sticky", 0o1777, owner_credentials, 24);
    try std.testing.expectEqual(@as(u16, 0o1777), (try fs.stat(0, "/tmp/sticky")).mode);
    _ = try fs.createOwned(0, "/tmp/sticky/victim", 0o644, group_credentials, 25);
    try std.testing.expectError(runtime_vfs.Error.PermissionDenied, fs.unlinkAs(0, "/tmp/sticky/victim", stranger_credentials, 26));
    try fs.unlinkAs(0, "/tmp/sticky/victim", group_credentials, 27);
    _ = try fs.createOwned(0, "/tmp/sticky/by-dir-owner", 0o644, group_credentials, 28);
    try fs.unlinkAs(0, "/tmp/sticky/by-dir-owner", owner_credentials, 29);
    _ = try fs.createOwned(0, "/tmp/sticky/by-root", 0o644, group_credentials, 30);
    try fs.unlinkAs(0, "/tmp/sticky/by-root", .{}, 31);

    _ = try fs.mkdirOwned(0, "/tmp/sticky/child", 0o755, group_credentials, 32);
    try std.testing.expectError(runtime_vfs.Error.PermissionDenied, fs.rmdirAs(0, "/tmp/sticky/child", stranger_credentials, 33));
    try fs.rmdirAs(0, "/tmp/sticky/child", group_credentials, 34);

    _ = try fs.createOwned(0, "/tmp/sticky/move", 0o644, group_credentials, 35);
    try fs.renameAs(0, "/tmp/sticky/move", "/tmp/sticky/move", stranger_credentials, 36);
    try std.testing.expectError(runtime_vfs.Error.PermissionDenied, fs.renameAs(0, "/tmp/sticky/move", "/tmp/sticky/moved", stranger_credentials, 37));
    try fs.renameAs(0, "/tmp/sticky/move", "/tmp/sticky/moved", group_credentials, 38);

    _ = try fs.createOwned(0, "/tmp/sticky/source", 0o644, stranger_credentials, 39);
    _ = try fs.createOwned(0, "/tmp/sticky/target", 0o644, group_credentials, 40);
    try std.testing.expectError(runtime_vfs.Error.PermissionDenied, fs.renameAs(0, "/tmp/sticky/source", "/tmp/sticky/target", stranger_credentials, 41));
    try fs.renameAs(0, "/tmp/sticky/source", "/tmp/sticky/target", owner_credentials, 42);

    try std.testing.expectEqual(@as(u16, 0o027), try processes.setUmask(handle, 0));
    try std.testing.expect(system.validate(&fs, &processes));
}

test "dup and dup2 share a VFS open description and offset" {
    var fs = runtime_vfs.Vfs.init();
    try initializeTestFilesystem(&fs);
    var processes = runtime_process.Table.init(0);
    var system = System.init();
    const handle = processes.initHandle();
    try system.bindProcess(&processes, handle, true);
    const fd = try system.openFile(&fs, &processes, handle, "/tmp/shared", .{ .read = true, .write = true, .create = true, .truncate = true }, 0o666, 1);
    try std.testing.expectEqual(@as(usize, 5), (try system.write(&fs, &processes, handle, fd, "alpha", 2)).count);
    const duplicate = try system.duplicate(&processes, handle, fd);
    try std.testing.expectEqual(@as(usize, 5), (try system.write(&fs, &processes, handle, duplicate, "-beta", 3)).count);
    _ = try system.duplicateTo(&fs, &processes, handle, fd, 9);
    try std.testing.expectEqual(@as(usize, 0), try system.seek(&fs, &processes, handle, 9, 0, .start));
    var bytes: [32]u8 = undefined;
    const result = try system.read(&fs, &processes, handle, duplicate, &bytes);
    try std.testing.expectEqualStrings("alpha-beta", bytes[0..result.count]);
    const snapshot = try system.snapshot(&fs, &processes, handle);
    try std.testing.expectEqual(@as(u16, 3), snapshot.entries[3].references);

    // Whole-file locks are owned by the shared open description, while
    // independently opened hard-link aliases contend by inode generation.
    _ = try fs.link(0, "/tmp/shared", "/tmp/shared-alias", 4);
    const contender = try initializeTestProcess(&processes, "lock-contender", 8);
    try system.bindProcess(&processes, contender, false);
    const contender_fd = try system.openFile(&fs, &processes, contender, "/tmp/shared-alias", .{ .read = true, .write = true }, 0, 5);
    try std.testing.expectEqual(LockResult.acquired, try system.flock(&fs, &processes, handle, fd, .exclusive, true));
    try std.testing.expectEqual(LockResult.acquired, try system.flock(&fs, &processes, handle, duplicate, .exclusive, true));
    try std.testing.expectEqual(LockResult.blocked, try system.flock(&fs, &processes, contender, contender_fd, .shared, true));

    // Advisory means advisory: conflicting data I/O is still permitted.
    try std.testing.expectEqual(@as(usize, 1), (try system.write(&fs, &processes, contender, contender_fd, "!", 6)).count);
    try std.testing.expectEqual(LockResult.blocked, try system.flock(&fs, &processes, contender, contender_fd, .exclusive, false));
    const blocked = try processes.get(contender);
    const shared_stat = try fs.stat(0, "/tmp/shared");
    try std.testing.expectEqual(runtime_process.State.blocked, blocked.state);
    try std.testing.expectEqual(runtime_process.WaitReason.file_lock, blocked.wait_reason);
    try std.testing.expectEqual(fileLockWaitKey(shared_stat.node, shared_stat.generation), blocked.wait_target);

    try std.testing.expectEqual(LockResult.acquired, try system.flock(&fs, &processes, handle, duplicate, .none, false));
    try std.testing.expectEqual(runtime_process.State.runnable, (try processes.get(contender)).state);
    try std.testing.expectEqual(LockResult.acquired, try system.flock(&fs, &processes, contender, contender_fd, .exclusive, false));
    try std.testing.expectEqual(LockResult.acquired, try system.flock(&fs, &processes, contender, contender_fd, .shared, false));
    try std.testing.expectEqual(LockResult.acquired, try system.flock(&fs, &processes, handle, 9, .shared, false));
    try std.testing.expectEqual(LockResult.blocked, try system.flock(&fs, &processes, handle, fd, .exclusive, true));
    try std.testing.expectEqual(LockResult.acquired, try system.flock(&fs, &processes, contender, contender_fd, .none, false));
    try std.testing.expectEqual(LockResult.acquired, try system.flock(&fs, &processes, handle, fd, .exclusive, true));
    try std.testing.expectEqual(LockResult.acquired, try system.flock(&fs, &processes, handle, duplicate, .none, false));
    try std.testing.expectError(Error.InvalidOperation, system.flock(&fs, &processes, handle, 1, .exclusive, true));

    // Byte-range locks are independently normalized on each open description.
    // Non-overlapping regions coexist, overlap uses half-open interval math, and
    // ordinary writes remain advisory even when they land inside a foreign lock.
    try std.testing.expectError(Error.InvalidOperation, system.lockRange(&fs, &processes, handle, fd, 0, 0, .exclusive, true));
    try std.testing.expectError(Error.InvalidOperation, system.lockRange(&fs, &processes, handle, fd, runtime_vfs.maximum_file_size, 1, .exclusive, true));
    try std.testing.expectEqual(LockResult.acquired, try system.lockRange(&fs, &processes, handle, fd, 0, 8, .exclusive, true));
    try std.testing.expectEqual(LockResult.acquired, try system.lockRange(&fs, &processes, contender, contender_fd, 8, 8, .shared, true));
    try std.testing.expectEqual(LockResult.blocked, try system.lockRange(&fs, &processes, contender, contender_fd, 4, 4, .shared, true));
    try std.testing.expectEqual(@as(usize, 1), (try system.write(&fs, &processes, contender, contender_fd, "?", 7)).count);
    try std.testing.expectEqual(LockResult.acquired, try system.lockRange(&fs, &processes, contender, contender_fd, 8, 8, .none, false));

    // Blocking overlap uses the same inode-generation wait key as whole-file
    // advisory locks; unlock wakes the sleeper and the retried request acquires.
    try std.testing.expectEqual(LockResult.blocked, try system.lockRange(&fs, &processes, contender, contender_fd, 4, 4, .shared, false));
    try std.testing.expectEqual(runtime_process.State.blocked, (try processes.get(contender)).state);
    try std.testing.expectEqual(runtime_process.WaitReason.file_lock, (try processes.get(contender)).wait_reason);
    try std.testing.expectEqual(fileLockWaitKey(shared_stat.node, shared_stat.generation), (try processes.get(contender)).wait_target);
    try std.testing.expectEqual(LockResult.acquired, try system.lockRange(&fs, &processes, handle, duplicate, 0, 8, .none, false));
    try std.testing.expectEqual(runtime_process.State.runnable, (try processes.get(contender)).state);
    try std.testing.expectEqual(LockResult.acquired, try system.lockRange(&fs, &processes, contender, contender_fd, 4, 4, .shared, false));
    try std.testing.expectEqual(LockResult.acquired, try system.lockRange(&fs, &processes, handle, 9, 4, 4, .shared, true));

    // A failed nonblocking shared-to-exclusive conversion is failure-atomic.
    // The retained shared interval continues to block the other owner's upgrade.
    try std.testing.expectEqual(LockResult.blocked, try system.lockRange(&fs, &processes, handle, fd, 4, 4, .exclusive, true));
    try std.testing.expectEqual(LockResult.blocked, try system.lockRange(&fs, &processes, contender, contender_fd, 4, 4, .exclusive, true));
    try std.testing.expectEqual(LockResult.acquired, try system.lockRange(&fs, &processes, contender, contender_fd, 4, 4, .none, false));
    try std.testing.expectEqual(LockResult.acquired, try system.lockRange(&fs, &processes, handle, fd, 4, 4, .exclusive, true));

    // Replacement plus partial unlock splits one held interval into two preserved
    // fragments. Only the newly unlocked middle can be acquired by another owner.
    try std.testing.expectEqual(LockResult.acquired, try system.lockRange(&fs, &processes, handle, duplicate, 0, 12, .exclusive, true));
    try std.testing.expectEqual(LockResult.acquired, try system.lockRange(&fs, &processes, handle, fd, 3, 6, .none, false));
    try std.testing.expectEqual(LockResult.acquired, try system.lockRange(&fs, &processes, contender, contender_fd, 3, 6, .exclusive, true));
    try std.testing.expectEqual(LockResult.blocked, try system.lockRange(&fs, &processes, contender, contender_fd, 2, 2, .exclusive, true));
    try std.testing.expectEqual(LockResult.acquired, try system.lockRange(&fs, &processes, contender, contender_fd, 3, 6, .none, false));
    try std.testing.expectEqual(LockResult.acquired, try system.lockRange(&fs, &processes, handle, fd, 0, 12, .none, false));

    // G244 flock and G245 byte-range locks are deliberately separate advisory
    // namespaces, mirroring the common whole-file/record-lock distinction.
    try std.testing.expectEqual(LockResult.acquired, try system.flock(&fs, &processes, handle, fd, .exclusive, true));
    try std.testing.expectEqual(LockResult.acquired, try system.lockRange(&fs, &processes, contender, contender_fd, 0, 4, .shared, true));
    try std.testing.expectEqual(LockResult.acquired, try system.lockRange(&fs, &processes, contender, contender_fd, 0, 4, .none, false));
    try std.testing.expectEqual(LockResult.acquired, try system.flock(&fs, &processes, handle, duplicate, .none, false));
    try std.testing.expectError(Error.InvalidOperation, system.lockRange(&fs, &processes, handle, 1, 0, 1, .exclusive, true));
    try system.close(&fs, &processes, contender, contender_fd);
    try std.testing.expect(system.validate(&fs, &processes));
}

test "directory openat deferred unlink and notification watches survive descriptor aliases" {
    var fs = runtime_vfs.Vfs.init();
    try initializeTestFilesystem(&fs);
    const directory = try fs.mkdir(0, "/tmp/base", 0o755, 1);
    var processes = runtime_process.Table.init(0);
    var system = System.init();
    const process = processes.initHandle();
    try system.bindProcess(&processes, process, false);

    const directory_fd = try system.openFile(&fs, &processes, process, "/tmp/base", .{ .read = true }, 0, 2);
    try std.testing.expectEqual(directory, try system.directoryNode(&fs, &processes, process, directory_fd));
    const watch = try system.createDirectoryWatch(&fs, &processes, process, directory_fd);
    const poll_bits = runtime_abi.poll_readable | runtime_abi.poll_error | runtime_abi.poll_hangup;
    try std.testing.expectEqual(@as(u16, 0), try system.poll(&fs, &processes, process, watch, poll_bits));
    var events: [4]runtime_abi.DirectoryEvent = @splat(std.mem.zeroes(runtime_abi.DirectoryEvent));
    try std.testing.expectError(Error.WouldBlock, system.read(&fs, &processes, process, watch, std.mem.asBytes(&events)));

    const file_fd = try system.openFileAt(
        &fs,
        &processes,
        process,
        directory,
        "note",
        .{ .read = true, .write = true, .create = true, .truncate = true },
        0o644,
        3,
    );
    try std.testing.expectError(Error.NotDirectory, system.directoryNode(&fs, &processes, process, file_fd));
    try std.testing.expectError(Error.NotDirectory, system.createDirectoryWatch(&fs, &processes, process, file_fd));
    const watch_alias = try system.duplicate(&processes, process, watch);
    try std.testing.expectEqual(runtime_abi.poll_readable, try system.poll(&fs, &processes, process, watch, runtime_abi.poll_readable));
    const created = try system.read(&fs, &processes, process, watch, std.mem.asBytes(&events));
    try std.testing.expectEqual(@as(usize, @sizeOf(runtime_abi.DirectoryEvent)), created.count);
    try std.testing.expectEqual(runtime_abi.constants.directory_event_created, events[0].flags);
    try std.testing.expectEqualStrings("note", events[0].name[0..events[0].name_length]);
    try std.testing.expectError(Error.WouldBlock, system.read(&fs, &processes, process, watch_alias, std.mem.asBytes(&events)));

    // A separately created watch starts at the current sequence and therefore
    // does not replay the already-consumed create event.
    const independent_watch = try system.createDirectoryWatch(&fs, &processes, process, directory_fd);
    try fs.rename(directory, "note", "moved", 4);
    const renamed_shared = try system.read(&fs, &processes, process, watch_alias, std.mem.asBytes(&events));
    try std.testing.expectEqual(@as(usize, 2 * @sizeOf(runtime_abi.DirectoryEvent)), renamed_shared.count);
    try std.testing.expectEqual(runtime_abi.constants.directory_event_rename_from, events[0].flags);
    try std.testing.expectEqualStrings("note", events[0].name[0..events[0].name_length]);
    try std.testing.expectEqual(runtime_abi.constants.directory_event_rename_to, events[1].flags);
    try std.testing.expectEqualStrings("moved", events[1].name[0..events[1].name_length]);
    const renamed_independent = try system.read(&fs, &processes, process, independent_watch, std.mem.asBytes(&events));
    try std.testing.expectEqual(renamed_shared.count, renamed_independent.count);
    try fs.rename(directory, "moved", "note", 5);
    _ = try system.read(&fs, &processes, process, watch, std.mem.asBytes(&events));
    _ = try system.read(&fs, &processes, process, independent_watch, std.mem.asBytes(&events));

    _ = try system.write(&fs, &processes, process, file_fd, "open-data", 6);
    const alias = try system.duplicate(&processes, process, file_fd);

    try fs.unlink(directory, "note", 7);
    const removed = try system.read(&fs, &processes, process, watch_alias, std.mem.asBytes(&events));
    try std.testing.expectEqual(@as(usize, @sizeOf(runtime_abi.DirectoryEvent)), removed.count);
    try std.testing.expectEqual(runtime_abi.constants.directory_event_removed, events[0].flags);
    try std.testing.expectEqualStrings("note", events[0].name[0..events[0].name_length]);
    _ = try system.read(&fs, &processes, process, independent_watch, std.mem.asBytes(&events));
    try std.testing.expectError(runtime_vfs.Error.NotFound, fs.stat(directory, "note"));
    _ = try system.seek(&fs, &processes, process, alias, 0, .start);
    var bytes: [16]u8 = undefined;
    const first_read = try system.read(&fs, &processes, process, alias, &bytes);
    try std.testing.expectEqualStrings("open-data", bytes[0..first_read.count]);

    try system.close(&fs, &processes, process, file_fd);
    _ = try system.seek(&fs, &processes, process, alias, 0, .start);
    const second_read = try system.read(&fs, &processes, process, alias, &bytes);
    try std.testing.expectEqualStrings("open-data", bytes[0..second_read.count]);
    try system.close(&fs, &processes, process, alias);

    const replacement = try system.openFileAt(
        &fs,
        &processes,
        process,
        directory,
        "note",
        .{ .read = true, .write = true, .create = true },
        0o644,
        8,
    );
    try system.close(&fs, &processes, process, replacement);
    _ = try system.read(&fs, &processes, process, watch, std.mem.asBytes(&events));
    _ = try system.read(&fs, &processes, process, independent_watch, std.mem.asBytes(&events));

    // The journal is globally bounded to 64 records. A lagging watcher gets an
    // explicit overflow marker before resuming from the oldest retained record.
    const overflow_watch = try system.createDirectoryWatch(&fs, &processes, process, directory_fd);
    for (0..33) |index| {
        _ = try fs.create(directory, "burst", 0o644, @intCast(20 + index * 2));
        try fs.unlink(directory, "burst", @intCast(21 + index * 2));
    }
    const overflow = try system.read(&fs, &processes, process, overflow_watch, std.mem.asBytes(&events));
    try std.testing.expectEqual(@as(usize, @sizeOf(runtime_abi.DirectoryEvent)), overflow.count);
    try std.testing.expectEqual(runtime_abi.constants.directory_event_overflow, events[0].flags);
    try std.testing.expectEqual(@as(u16, 0), events[0].name_length);
    try std.testing.expectEqual(runtime_abi.poll_readable, try system.poll(&fs, &processes, process, overflow_watch, runtime_abi.poll_readable));

    try system.close(&fs, &processes, process, overflow_watch);
    try system.close(&fs, &processes, process, independent_watch);
    try system.close(&fs, &processes, process, watch_alias);
    try system.close(&fs, &processes, process, watch);
    try system.close(&fs, &processes, process, directory_fd);
    try std.testing.expectEqual(@as(usize, 0), system.report().directory_watch_descriptions);
    try std.testing.expect(system.validate(&fs, &processes));
}

test "independent append descriptions write at the current file end" {
    var fs = runtime_vfs.Vfs.init();
    try initializeTestFilesystem(&fs);
    var processes = runtime_process.Table.init(0);
    var system = System.init();
    const handle = processes.initHandle();
    try system.bindProcess(&processes, handle, false);
    const initial = try system.openFile(&fs, &processes, handle, "/tmp/append", .{ .write = true, .create = true, .truncate = true }, 0o644, 1);
    _ = try system.write(&fs, &processes, handle, initial, "A", 2);
    const first_append = try system.openFile(&fs, &processes, handle, "/tmp/append", .{ .write = true, .append = true }, 0o644, 3);
    const second_append = try system.openFile(&fs, &processes, handle, "/tmp/append", .{ .read = true, .write = true, .append = true }, 0o644, 4);
    _ = try system.write(&fs, &processes, handle, first_append, "B", 5);
    _ = try system.write(&fs, &processes, handle, second_append, "C", 6);
    _ = try system.seek(&fs, &processes, handle, second_append, 0, .start);
    var bytes: [8]u8 = undefined;
    const result = try system.read(&fs, &processes, handle, second_append, &bytes);
    try std.testing.expectEqualStrings("ABC", bytes[0..result.count]);
    try std.testing.expect(system.validate(&fs, &processes));
}

test "cloned process namespaces inherit shared descriptions and close-on-exec" {
    var fs = runtime_vfs.Vfs.init();
    try initializeTestFilesystem(&fs);
    var processes = runtime_process.Table.init(0);
    var system = System.init();
    const parent = processes.initHandle();
    try system.bindProcess(&processes, parent, true);
    const fd = try system.openFile(&fs, &processes, parent, "/tmp/fork", .{ .read = true, .write = true, .create = true, .truncate = true }, 0o666, 1);
    _ = try system.write(&fs, &processes, parent, fd, "parent", 2);
    const child = try initializeTestProcess(&processes, "child", 16);
    try std.testing.expectEqual(@as(usize, 4), try system.cloneProcess(&processes, parent, child));
    _ = try system.write(&fs, &processes, child, fd, "-child", 3);
    _ = try system.seek(&fs, &processes, parent, fd, 0, .start);
    var bytes: [32]u8 = undefined;
    const result = try system.read(&fs, &processes, parent, fd, &bytes);
    try std.testing.expectEqualStrings("parent-child", bytes[0..result.count]);

    // Forked descriptor namespaces share the same open-description lock. The
    // lock therefore survives a parent close until the child's last inherited
    // reference is closed, at which point an independent opener can acquire it.
    try std.testing.expectEqual(LockResult.acquired, try system.flock(&fs, &processes, parent, fd, .exclusive, true));
    const contender = try initializeTestProcess(&processes, "fork-lock-contender", 8);
    try system.bindProcess(&processes, contender, false);
    const contender_fd = try system.openFile(&fs, &processes, contender, "/tmp/fork", .{ .read = true, .write = true }, 0, 4);
    try std.testing.expectEqual(LockResult.blocked, try system.flock(&fs, &processes, contender, contender_fd, .shared, true));
    try system.close(&fs, &processes, parent, fd);
    try std.testing.expectEqual(LockResult.blocked, try system.flock(&fs, &processes, contender, contender_fd, .shared, true));
    try std.testing.expectEqual(LockResult.acquired, try system.lockRange(&fs, &processes, child, fd, 0, 4, .exclusive, true));
    try std.testing.expectEqual(LockResult.blocked, try system.lockRange(&fs, &processes, contender, contender_fd, 0, 4, .shared, true));
    try system.setCloseOnExec(&processes, child, fd, true);
    try std.testing.expectEqual(@as(usize, 1), try system.closeOnExec(&fs, &processes, child));
    try std.testing.expectError(Error.BadDescriptor, system.write(&fs, &processes, child, fd, "x", 5));
    try std.testing.expectEqual(LockResult.acquired, try system.flock(&fs, &processes, contender, contender_fd, .exclusive, true));
    try std.testing.expectEqual(LockResult.acquired, try system.flock(&fs, &processes, contender, contender_fd, .none, false));
    try std.testing.expectEqual(LockResult.acquired, try system.lockRange(&fs, &processes, contender, contender_fd, 0, 4, .exclusive, true));
    try std.testing.expectEqual(LockResult.acquired, try system.lockRange(&fs, &processes, contender, contender_fd, 0, 4, .none, false));
    try system.close(&fs, &processes, contender, contender_fd);

    _ = try system.releaseProcess(&fs, &processes, child);
    try processes.exit(child, 0);
    _ = (try processes.wait(parent, child, false)).?;

    // G262 keeps spawn-time pipeline I/O deliberately narrower than generic
    // descriptor actions: only inherited pipe ends may replace stdin/stdout,
    // then every non-standard child descriptor is closed before dispatch.
    const pipe_pair = try system.createPipe(&processes, parent);
    try std.testing.expectEqual(@as(u16, 3), pipe_pair[0]);
    try std.testing.expectEqual(@as(u16, 4), pipe_pair[1]);
    const pipeline_child = try initializeTestProcess(&processes, "pipeline-child", 16);
    try std.testing.expectEqual(@as(usize, 5), try system.cloneProcess(&processes, parent, pipeline_child));
    try std.testing.expectError(Error.NotReadable, system.configurePipelineChild(&fs, &processes, pipeline_child, pipe_pair[1], null));
    try std.testing.expectError(Error.NotWritable, system.configurePipelineChild(&fs, &processes, pipeline_child, null, pipe_pair[0]));
    try std.testing.expectEqual(@as(usize, 5), (try system.snapshot(&fs, &processes, pipeline_child)).count);
    try std.testing.expectEqual(@as(usize, 2), try system.configurePipelineChild(&fs, &processes, pipeline_child, pipe_pair[0], pipe_pair[1]));
    const pipeline_snapshot = try system.snapshot(&fs, &processes, pipeline_child);
    try std.testing.expectEqual(@as(usize, 3), pipeline_snapshot.count);
    try std.testing.expectEqual(@as(u16, 0), pipeline_snapshot.entries[0].fd);
    try std.testing.expectEqual(DescriptionKind.pipe_read, pipeline_snapshot.entries[0].kind);
    try std.testing.expectEqual(@as(u16, 1), pipeline_snapshot.entries[1].fd);
    try std.testing.expectEqual(DescriptionKind.pipe_write, pipeline_snapshot.entries[1].kind);
    try std.testing.expectEqual(@as(u16, 2), pipeline_snapshot.entries[2].fd);
    try std.testing.expectEqual(DescriptionKind.terminal, pipeline_snapshot.entries[2].kind);
    try std.testing.expectEqual(@as(usize, 5), (try system.snapshot(&fs, &processes, parent)).count);
    try system.close(&fs, &processes, parent, pipe_pair[0]);
    try system.close(&fs, &processes, parent, pipe_pair[1]);
    _ = try system.releaseProcess(&fs, &processes, pipeline_child);
    try processes.exit(pipeline_child, 0);
    _ = (try processes.wait(parent, pipeline_child, false)).?;
    try std.testing.expectEqual(@as(usize, 0), system.report().pipes);
    try std.testing.expect(system.validate(&fs, &processes));
}

test "empty pipe blocks reader and writer wakeup delivers data then EOF" {
    var fs = runtime_vfs.Vfs.init();
    var processes = runtime_process.Table.init(0);
    var system = System.init();
    const reader = try initializeTestProcess(&processes, "reader", 8);
    const writer = try initializeTestProcess(&processes, "writer", 8);
    try system.bindProcess(&processes, reader, false);
    const pair = try system.createPipe(&processes, reader);
    _ = try system.cloneProcess(&processes, reader, writer);
    try system.close(&fs, &processes, reader, pair[1]);
    try system.close(&fs, &processes, writer, pair[0]);
    var bytes: [32]u8 = undefined;
    try std.testing.expectEqual(IoStatus.blocked, (try system.read(&fs, &processes, reader, pair[0], &bytes)).status);
    try std.testing.expectEqual(runtime_process.State.blocked, (try processes.get(reader)).state);
    const write_result = try system.write(&fs, &processes, writer, pair[1], "pipe-data", 1);
    try std.testing.expectEqual(@as(usize, 1), write_result.wakeups);
    try std.testing.expectEqual(runtime_process.State.runnable, (try processes.get(reader)).state);
    const read_result = try system.read(&fs, &processes, reader, pair[0], &bytes);
    try std.testing.expectEqualStrings("pipe-data", bytes[0..read_result.count]);
    try system.close(&fs, &processes, writer, pair[1]);
    try std.testing.expectEqual(IoStatus.eof, (try system.read(&fs, &processes, reader, pair[0], &bytes)).status);
    try std.testing.expect(system.validate(&fs, &processes));
}

test "full pipe blocks writer and draining reader wakes it across ring wrap" {
    var fs = runtime_vfs.Vfs.init();
    var processes = runtime_process.Table.init(0);
    var system = System.init();
    const reader = try initializeTestProcess(&processes, "reader", 8);
    const writer = try initializeTestProcess(&processes, "writer", 8);
    try system.bindProcess(&processes, reader, false);
    const pair = try system.createPipe(&processes, reader);
    _ = try system.cloneProcess(&processes, reader, writer);
    try system.close(&fs, &processes, reader, pair[1]);
    try system.close(&fs, &processes, writer, pair[0]);
    var payload: [pipe_capacity]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @intCast(index & 0xFF);
    try std.testing.expectEqual(pipe_capacity, (try system.write(&fs, &processes, writer, pair[1], &payload, 1)).count);
    try std.testing.expectEqual(IoStatus.blocked, (try system.write(&fs, &processes, writer, pair[1], "x", 2)).status);
    var drained: [700]u8 = undefined;
    const first_read = try system.read(&fs, &processes, reader, pair[0], &drained);
    try std.testing.expectEqual(@as(usize, 1), first_read.wakeups);
    try std.testing.expectEqual(@as(usize, 700), first_read.count);
    try std.testing.expectEqual(@as(usize, 700), (try system.write(&fs, &processes, writer, pair[1], payload[0..700], 3)).count);
    var remainder: [pipe_capacity]u8 = undefined;
    const second_read = try system.read(&fs, &processes, reader, pair[0], &remainder);
    try std.testing.expectEqual(pipe_capacity, second_read.count);
    try std.testing.expect(system.validate(&fs, &processes));
}

test "closing last reader produces broken pipe" {
    var fs = runtime_vfs.Vfs.init();
    var processes = runtime_process.Table.init(0);
    var system = System.init();
    const process = processes.initHandle();
    try system.bindProcess(&processes, process, false);
    const pair = try system.createPipe(&processes, process);
    try system.close(&fs, &processes, process, pair[0]);
    try std.testing.expectError(Error.BrokenPipe, system.write(&fs, &processes, process, pair[1], "x", 0));
    try system.close(&fs, &processes, process, pair[1]);
    try std.testing.expectEqual(@as(usize, 0), system.report().pipes);
    try std.testing.expect(system.validate(&fs, &processes));
}

test "descriptor truncate is independent of shared offset" {
    var fs = runtime_vfs.Vfs.init();
    try initializeTestFilesystem(&fs);
    var processes = runtime_process.Table.init(0);
    var system = System.init();
    const process = processes.initHandle();
    try system.bindProcess(&processes, process, false);
    const fd = try system.openFile(&fs, &processes, process, "/tmp/truncate", .{ .read = true, .write = true, .create = true }, 0o644, 1);
    _ = try system.write(&fs, &processes, process, fd, "0123456789", 2);
    try system.truncate(&fs, &processes, process, fd, 4, 3);
    const snapshot = try system.snapshot(&fs, &processes, process);
    try std.testing.expectEqual(@as(usize, 10), snapshot.entries[0].offset_or_buffered);
    _ = try system.seek(&fs, &processes, process, fd, 0, .start);
    var bytes: [16]u8 = undefined;
    const result = try system.read(&fs, &processes, process, fd, &bytes);
    try std.testing.expectEqualStrings("0123", bytes[0..result.count]);
}

test "descriptor fallocate preserves size punches holes and enforces writability" {
    var fs = runtime_vfs.Vfs.init();
    try initializeTestFilesystem(&fs);
    var processes = runtime_process.Table.init(0);
    var system = System.init();
    const process = processes.initHandle();
    try system.bindProcess(&processes, process, false);
    const fd = try system.openFile(&fs, &processes, process, "/tmp/sparse-fd", .{ .read = true, .write = true, .create = true, .truncate = true }, 0o644, 1);
    try system.fallocate(&fs, &processes, process, fd, 2 * runtime_vfs.file_block_size, runtime_vfs.file_block_size, .{ .keep_size = true }, 2);
    try std.testing.expectEqual(@as(u64, 0), (try system.stat(&fs, &processes, process, fd)).size);
    try system.fallocate(&fs, &processes, process, fd, 2 * runtime_vfs.file_block_size, 4, .{}, 3);
    try std.testing.expectEqual(@as(u64, 2 * runtime_vfs.file_block_size + 4), (try system.stat(&fs, &processes, process, fd)).size);
    _ = try system.seek(&fs, &processes, process, fd, 2 * runtime_vfs.file_block_size, .start);
    try std.testing.expectEqual(@as(usize, 4), (try system.write(&fs, &processes, process, fd, "DATA", 4)).count);
    try system.fallocate(&fs, &processes, process, fd, 2 * runtime_vfs.file_block_size, runtime_vfs.file_block_size, .{ .keep_size = true, .punch_hole = true }, 5);
    _ = try system.seek(&fs, &processes, process, fd, 2 * runtime_vfs.file_block_size, .start);
    var zeros: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), (try system.read(&fs, &processes, process, fd, &zeros)).count);
    try std.testing.expectEqualSlices(u8, &@as([4]u8, @splat(0)), &zeros);
    const read_only = try system.openFile(&fs, &processes, process, "/tmp/sparse-fd", .{ .read = true }, 0, 6);
    try std.testing.expectError(Error.NotWritable, system.fallocate(&fs, &processes, process, read_only, 0, runtime_vfs.file_block_size, .{}, 7));
    try system.close(&fs, &processes, process, read_only);
    try system.close(&fs, &processes, process, fd);
    try std.testing.expect(system.validate(&fs, &processes));
}

test "descriptor file sync routing distinguishes immediate and persistent mounts" {
    var fs = runtime_vfs.Vfs.init();
    try initializeTestFilesystem(&fs);
    _ = try fs.mkdir(0, "/persist", 0o755, 1);
    _ = try fs.mount(0, "/persist", .zigos_persist, false, "test-persist");
    var processes = runtime_process.Table.init(0);
    var system = System.init();
    const process = processes.initHandle();
    try system.bindProcess(&processes, process, true);

    const ram_fd = try system.openFile(&fs, &processes, process, "/tmp/ram", .{ .read = true, .write = true, .create = true }, 0o600, 2);
    _ = try system.write(&fs, &processes, process, ram_fd, "ram", 3);
    const ram_node = try system.syncNode(&fs, &processes, process, ram_fd);
    try std.testing.expect(!(try fs.persistentNode(ram_node)));
    try std.testing.expectEqual(@as(?u16, null), try system.persistentSyncNode(&fs, &processes, process, ram_fd));
    try std.testing.expect((try fs.dirtyFilePageBitmap(ram_node)) != 0);
    _ = fs.clearDirtyNodePages(ram_node);
    try std.testing.expectEqual(@as(u8, 0), try fs.dirtyFilePageBitmap(ram_node));

    const persistent_fd = try system.openFile(&fs, &processes, process, "/persist/value", .{ .read = true, .write = true, .create = true }, 0o600, 4);
    _ = try system.write(&fs, &processes, process, persistent_fd, "persist", 5);
    const persistent_node = try system.syncNode(&fs, &processes, process, persistent_fd);
    try std.testing.expect(try fs.persistentNode(persistent_node));
    try std.testing.expectEqual(@as(?u16, persistent_node), try system.persistentSyncNode(&fs, &processes, process, persistent_fd));

    const directory_fd = try system.openFile(&fs, &processes, process, "/tmp", .{ .read = true }, 0, 6);
    try std.testing.expectError(runtime_vfs.Error.UnsupportedOperation, system.syncNode(&fs, &processes, process, directory_fd));
    try std.testing.expect(system.validate(&fs, &processes));
}

test "descriptor quota failures leave all tables unchanged" {
    var fs = runtime_vfs.Vfs.init();
    try initializeTestFilesystem(&fs);
    var processes = runtime_process.Table.init(0);
    var system = System.init();
    const process = try initializeTestProcess(&processes, "limited", 1);
    try system.bindProcess(&processes, process, false);
    const fd = try system.openFile(&fs, &processes, process, "/tmp/one", .{ .read = true, .write = true, .create = true }, 0o644, 1);
    try std.testing.expectEqual(@as(u16, 0), fd);
    const before = system.report();
    try std.testing.expectError(Error.DescriptorLimit, system.duplicate(&processes, process, fd));
    try std.testing.expectError(Error.DescriptorLimit, system.createPipe(&processes, process));
    const after = system.report();
    try std.testing.expectEqual(before.descriptors, after.descriptors);
    try std.testing.expectEqual(before.open_descriptions, after.open_descriptions);
    try std.testing.expectEqual(before.pipes, after.pipes);
    try std.testing.expect(system.validate(&fs, &processes));
}

test "stale namespace sweep releases descriptions after process reap" {
    var fs = runtime_vfs.Vfs.init();
    try initializeTestFilesystem(&fs);
    var processes = runtime_process.Table.init(0);
    var system = System.init();
    const parent = processes.initHandle();
    const child = try initializeTestProcess(&processes, "stale", 4);
    try system.bindProcess(&processes, child, false);
    _ = try system.openFile(&fs, &processes, child, "/tmp/stale", .{ .read = true, .write = true, .create = true }, 0o644, 1);
    try processes.exit(child, 0);
    _ = (try processes.wait(parent, child, false)).?;
    try std.testing.expectEqual(@as(usize, 1), try system.sweepStaleNamespaces(&fs, &processes));
    try std.testing.expectEqual(@as(usize, 0), system.report().descriptors);
    try std.testing.expect(system.validate(&fs, &processes));
}
