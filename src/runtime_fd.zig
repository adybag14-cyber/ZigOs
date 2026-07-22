const std = @import("std");
const runtime_process = @import("runtime_process.zig");
const runtime_vfs = @import("runtime_vfs.zig");

pub const maximum_descriptors_per_process: usize = 32;
pub const maximum_open_descriptions: usize = 96;
pub const maximum_pipes: usize = 32;
pub const pipe_capacity: usize = 1024;
pub const invalid_open_description: u16 = 0xFFFF;
pub const invalid_resource: u16 = 0xFFFF;

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
    ReferenceOverflow,
    CorruptState,
};

pub const DescriptionKind = enum(u8) {
    terminal,
    vfs,
    pipe_read,
    pipe_write,
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
    resource_generation: u16 = 0,
    vfs_owner: u32 = 0,
    vfs_handle: u32 = 0,
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

    pub fn init() System {
        var self: System = undefined;
        self.initialize();
        return self;
    }

    pub fn initialize(self: *System) void {
        self.* = .{};
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
        if (count > target_process.limits.maximum_descriptors) return Error.DescriptorLimit;
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
            target_process.socket_count,
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
        const namespace_slot = try self.resolveNamespace(process_handle);
        try self.requireDescriptorCapacity(&self.namespaces[namespace_slot], process, 1);
        const fd = self.findFreeDescriptors(&self.namespaces[namespace_slot], 1) orelse return Error.DescriptorLimit;
        const open_slot = self.findFreeOpenDescriptions(1) orelse return Error.OpenDescriptionLimit;
        const generation = nextGeneration(self.open_descriptions[open_slot[0]].generation);
        const owner = makeOpenId(open_slot[0], generation);
        const vfs_handle = try vfs.open(owner, process.cwd_node, path, flags, mode, tick);
        self.initializeDescription(open_slot[0], .vfs, flags.read, flags.write, flags.append, invalid_resource, 0, owner, vfs_handle);
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
        _ = try processes.get(process_handle);
        const namespace_slot = try self.resolveNamespace(process_handle);
        const open_index = try self.resolveDescriptor(namespace_slot, fd);
        const description = self.open_descriptions[open_index];
        if (!description.readable) return Error.NotReadable;
        if (output.len == 0) return .{ .status = .complete };
        switch (description.kind) {
            .terminal => return Error.InvalidOperation,
            .vfs => {
                const count = try vfs.readOpen(description.vfs_owner, description.vfs_handle, output);
                self.bytes_read +%= count;
                if (count == 0) {
                    self.eof_reads +%= 1;
                    return .{ .status = .eof };
                }
                return .{ .status = .complete, .count = count };
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
                .terminal => {},
                .vfs => {
                    const info = try vfs.openInfo(description.vfs_owner, description.vfs_handle);
                    resource_id = (@as(u64, info.node_generation) << 32) | info.node;
                    offset_or_buffered = info.offset;
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
                .terminal => if (description.resource_index != invalid_resource) return false,
                .vfs => {
                    _ = vfs.openInfo(description.vfs_owner, description.vfs_handle) catch return false;
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
        if (!pipe.used or pipe.generation != description.resource_generation) return Error.CorruptState;
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
            process.socket_count,
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
        if (description.references == 1 and description.kind == .vfs) try vfs.close(description.vfs_owner, description.vfs_handle);
        self.namespaces[namespace_slot].descriptors[fd] = .{};
        self.open_descriptions[open_index].references -= 1;
        self.descriptor_closes +%= 1;
        if (self.open_descriptions[open_index].references != 0) return;

        switch (description.kind) {
            .terminal, .vfs => {},
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
        resource_generation: u16,
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

test "numeric descriptor namespace uses lowest free descriptor" {
    var fs = runtime_vfs.Vfs.init();
    try initializeTestFilesystem(&fs);
    var processes = runtime_process.Table.init(0);
    var system = System.init();
    const handle = processes.initHandle();
    try system.bindProcess(&processes, handle, true);
    const first = try system.openFile(&fs, &processes, handle, "/tmp/a", .{ .read = true, .write = true, .create = true }, 0o644, 1);
    try std.testing.expectEqual(@as(u16, 3), first);
    try system.close(&fs, &processes, handle, first);
    const second = try system.openFile(&fs, &processes, handle, "/tmp/b", .{ .read = true, .write = true, .create = true }, 0o644, 2);
    try std.testing.expectEqual(first, second);
    try std.testing.expect(system.validate(&fs, &processes));
}

test "dup and dup2 share a VFS open description and offset" {
    var fs = runtime_vfs.Vfs.init();
    try initializeTestFilesystem(&fs);
    var processes = runtime_process.Table.init(0);
    var system = System.init();
    const handle = processes.initHandle();
    try system.bindProcess(&processes, handle, true);
    const fd = try system.openFile(&fs, &processes, handle, "/tmp/shared", .{ .read = true, .write = true, .create = true, .truncate = true }, 0o644, 1);
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
    const fd = try system.openFile(&fs, &processes, parent, "/tmp/fork", .{ .read = true, .write = true, .create = true, .truncate = true }, 0o644, 1);
    _ = try system.write(&fs, &processes, parent, fd, "parent", 2);
    const child = try initializeTestProcess(&processes, "child", 16);
    try std.testing.expectEqual(@as(usize, 4), try system.cloneProcess(&processes, parent, child));
    _ = try system.write(&fs, &processes, child, fd, "-child", 3);
    try system.setCloseOnExec(&processes, child, fd, true);
    try std.testing.expectEqual(@as(usize, 1), try system.closeOnExec(&fs, &processes, child));
    try std.testing.expectError(Error.BadDescriptor, system.write(&fs, &processes, child, fd, "x", 4));
    _ = try system.seek(&fs, &processes, parent, fd, 0, .start);
    var bytes: [32]u8 = undefined;
    const result = try system.read(&fs, &processes, parent, fd, &bytes);
    try std.testing.expectEqualStrings("parent-child", bytes[0..result.count]);
    _ = try system.releaseProcess(&fs, &processes, child);
    try processes.exit(child, 0);
    _ = (try processes.wait(parent, child, false)).?;
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
