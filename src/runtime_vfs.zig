const std = @import("std");
const synchronization = @import("synchronization.zig");

pub const maximum_nodes: usize = 96;
pub const maximum_dentries: usize = maximum_nodes * 2;
pub const maximum_dentry_cache_entries: usize = 16;
pub const maximum_file_page_cache_entries: usize = 16;
pub const maximum_name_length: usize = 31;
pub const maximum_path_length: usize = 255;
pub const maximum_symlink_depth: usize = 8;
pub const maximum_symlink_target_length: usize = maximum_path_length;
pub const maximum_file_size: usize = 32 * 1024;
pub const file_block_size: usize = 4096;
pub const file_blocks_per_node: usize = maximum_file_size / file_block_size;
pub const maximum_data_blocks: usize = 256;
pub const invalid_data_block: u16 = 0xFFFF;
pub const maximum_mounts: usize = 8;
pub const maximum_open_files: usize = 64;
pub const maximum_directory_entries: usize = 64;
pub const invalid_node: u16 = 0xFFFF;
pub const invalid_dentry: u16 = 0xFFFF;
pub const invalid_cache_entry: u16 = 0xFFFF;

pub const PseudoReadFn = *const fn (context: ?*anyopaque, node: u16, offset: usize, output: []u8) Error!usize;
pub const PseudoWriteFn = *const fn (context: ?*anyopaque, node: u16, offset: usize, input: []const u8) Error!usize;
pub const PseudoPollFn = *const fn (context: ?*anyopaque, node: u16, requested: u16) Error!u16;
pub const PseudoIoctlFn = *const fn (context: ?*anyopaque, node: u16, request: u64, argument: u64) Error!u64;
pub const PseudoCloseFn = *const fn (context: ?*anyopaque, node: u16, owner_pid: u32) void;

pub const PseudoStream = enum(u8) {
    console,
};

pub const PseudoOperations = struct {
    read: ?PseudoReadFn = null,
    write: ?PseudoWriteFn = null,
    poll: ?PseudoPollFn = null,
    ioctl: ?PseudoIoctlFn = null,
    close: ?PseudoCloseFn = null,
    stream: ?PseudoStream = null,
};

const unsupported_pseudo_operations = PseudoOperations{};

pub const Kind = enum(u8) {
    file,
    directory,
    pseudo,
    symlink,
};

pub const MountKind = enum(u8) {
    ramfs,
    boot_fat,
    procfs,
    devfs,
    netfs,
    zigos_persist,
};

pub const Error = error{
    InvalidPath,
    NameTooLong,
    PathTooLong,
    NotFound,
    AlreadyExists,
    NotDirectory,
    IsDirectory,
    DirectoryNotEmpty,
    ReadOnly,
    NoSpace,
    FileTooLarge,
    InvalidOffset,
    PermissionDenied,
    Busy,
    InvalidHandle,
    TooManyOpenFiles,
    CrossMount,
    Cycle,
    UnsupportedOperation,
    NotSeekable,
    NotSymlink,
};

pub const Stat = struct {
    node: u16,
    generation: u16,
    kind: Kind,
    size: usize,
    mode: u16,
    readonly: bool,
    mount_id: u8,
    link_count: u16,
    modified_tick: u64,
};

pub const DirectoryRecord = struct {
    node: u16 = invalid_node,
    entry: u16 = invalid_dentry,
    name: [maximum_name_length + 1]u8 = @splat(0),
    name_length: u8 = 0,
    kind: Kind = .file,
    size: usize = 0,
    readonly: bool = false,

    pub fn nameSlice(self: *const DirectoryRecord) []const u8 {
        return self.name[0..self.name_length];
    }
};

pub const DirectoryList = struct {
    records: [maximum_directory_entries]DirectoryRecord = @splat(.{}),
    count: usize = 0,
};

const Node = struct {
    used: bool = false,
    generation: u16 = 0,
    kind: Kind = .file,
    link_count: u16 = 0,
    size: usize = 0,
    file_blocks: [file_blocks_per_node]u16 = @splat(invalid_data_block),
    symlink_data: [maximum_symlink_target_length]u8 = @splat(0),
    mode: u16 = 0o644,
    readonly: bool = false,
    mount_id: u8 = 0,
    modified_tick: u64 = 0,
    data_lock: synchronization.TicketLock = synchronization.TicketLock.init(),
    pseudo_operations: ?*const PseudoOperations = null,
    pseudo_context: ?*anyopaque = null,
};

const DataBlock = struct {
    used: bool = false,
    owner_node: u16 = invalid_node,
    owner_slot: u8 = 0,
    data: [file_block_size]u8 = @splat(0),
};

const FilePageCacheEntry = struct {
    used: bool = false,
    node: u16 = invalid_node,
    node_generation: u16 = 0,
    slot: u8 = 0,
    last_used: u64 = 0,
    data: [file_block_size]u8 = @splat(0),
};

const Dentry = struct {
    used: bool = false,
    generation: u16 = 0,
    parent: u16 = invalid_node,
    node: u16 = invalid_node,
    name: [maximum_name_length + 1]u8 = @splat(0),
    name_length: u8 = 0,

    fn nameSlice(self: *const Dentry) []const u8 {
        return self.name[0..self.name_length];
    }
};

const DentryCacheEntry = struct {
    used: bool = false,
    stale: bool = false,
    generation: u16 = 0,
    parent: u16 = invalid_node,
    dentry: u16 = invalid_dentry,
    dentry_generation: u16 = 0,
    references: u16 = 0,
    last_used: u64 = 0,
    name: [maximum_name_length + 1]u8 = @splat(0),
    name_length: u8 = 0,

    fn nameSlice(self: *const DentryCacheEntry) []const u8 {
        return self.name[0..self.name_length];
    }
};

const DentryReference = struct {
    cache_entry: u16 = invalid_cache_entry,
    cache_generation: u16 = 0,
    dentry: u16,
};

pub const Mount = struct {
    used: bool = false,
    id: u8 = 0,
    parent_id: u8 = 0,
    mountpoint_node: u16 = invalid_node,
    root_node: u16 = invalid_node,
    kind: MountKind = .ramfs,
    readonly: bool = false,
    source: [32]u8 = @splat(0),
    source_length: u8 = 0,

    pub fn sourceSlice(self: *const Mount) []const u8 {
        return self.source[0..self.source_length];
    }
};

pub const OpenFlags = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    create: bool = false,
    truncate: bool = false,
    append: bool = false,
    _padding: u3 = 0,
};

pub const AllocationFlags = packed struct(u8) {
    keep_size: bool = false,
    punch_hole: bool = false,
    _padding: u6 = 0,
};

pub const SparseFileInfo = struct {
    size: usize,
    allocation_bitmap: u8,
    allocated_blocks: u8,
};

const OpenFile = struct {
    used: bool = false,
    generation: u16 = 0,
    node: u16 = invalid_node,
    node_generation: u16 = 0,
    owner_pid: u32 = 0,
    offset: usize = 0,
    readable: bool = false,
    writable: bool = false,
    append: bool = false,
};

pub const OpenInfo = struct {
    node: u16,
    node_generation: u16,
    offset: usize,
    readable: bool,
    writable: bool,
    append: bool,
};

pub const Report = struct {
    nodes_used: usize,
    dentries_used: usize,
    files: usize,
    directories: usize,
    pseudo_files: usize,
    mounts: usize,
    open_files: usize,
    bytes_used: usize,
    mutations: u64,
    rejected_operations: u64,
    dentry_cache_entries: usize,
    dentry_cache_references: usize,
    dentry_cache_hits: u64,
    dentry_cache_misses: u64,
    dentry_cache_insertions: u64,
    dentry_cache_evictions: u64,
    dentry_cache_invalidations: u64,
    dentry_cache_rejections: u64,
    dentry_cache_acquires: u64,
    dentry_cache_releases: u64,
    file_page_cache_entries: usize,
    file_page_cache_hits: u64,
    file_page_cache_misses: u64,
    file_page_cache_insertions: u64,
    file_page_cache_evictions: u64,
    file_page_cache_invalidations: u64,
    file_page_cache_lock_tickets: u64,
    file_page_cache_lock_outstanding: u64,
    data_lock_tickets: u64,
    data_lock_outstanding: u64,
    data_pool_lock_tickets: u64,
    data_pool_lock_outstanding: u64,
    allocated_blocks: usize,
    allocated_bytes: usize,
    sparse_hole_bytes: usize,
};

pub const Vfs = struct {
    nodes: [maximum_nodes]Node = @splat(.{}),
    data_blocks: [maximum_data_blocks]DataBlock = @splat(.{}),
    data_pool_lock: synchronization.TicketLock = synchronization.TicketLock.init(),
    file_page_cache: [maximum_file_page_cache_entries]FilePageCacheEntry = @splat(.{}),
    file_page_cache_lock: synchronization.TicketLock = synchronization.TicketLock.init(),
    file_page_cache_clock: u64 = 0,
    file_page_cache_hits: u64 = 0,
    file_page_cache_misses: u64 = 0,
    file_page_cache_insertions: u64 = 0,
    file_page_cache_evictions: u64 = 0,
    file_page_cache_invalidations: u64 = 0,
    view_scratch: [maximum_file_size]u8 = @splat(0),
    dentries: [maximum_dentries]Dentry = @splat(.{}),
    dentry_cache: [maximum_dentry_cache_entries]DentryCacheEntry = @splat(.{}),
    mounts: [maximum_mounts]Mount = @splat(.{}),
    open_files: [maximum_open_files]OpenFile = @splat(.{}),
    mutations: u64 = 0,
    rejected_operations: u64 = 0,
    dentry_cache_clock: u64 = 0,
    dentry_cache_hits: u64 = 0,
    dentry_cache_misses: u64 = 0,
    dentry_cache_insertions: u64 = 0,
    dentry_cache_evictions: u64 = 0,
    dentry_cache_invalidations: u64 = 0,
    dentry_cache_rejections: u64 = 0,
    dentry_cache_acquires: u64 = 0,
    dentry_cache_releases: u64 = 0,

    pub fn init() Vfs {
        var self: Vfs = undefined;
        self.initialize();
        return self;
    }

    pub fn initialize(self: *Vfs) void {
        self.* = .{};
        self.nodes[0] = .{
            .used = true,
            .generation = 1,
            .kind = .directory,
            .link_count = 1,
            .mode = 0o755,
            .mount_id = 1,
        };
        self.mounts[0] = .{
            .used = true,
            .id = 1,
            .parent_id = 0,
            .mountpoint_node = 0,
            .root_node = 0,
            .kind = .ramfs,
            .readonly = false,
            .source = sourceArray("ramfs"),
            .source_length = 5,
        };
    }

    pub fn root(self: *const Vfs) u16 {
        _ = self;
        return 0;
    }

    pub fn resolve(self: *Vfs, cwd: u16, path: []const u8) Error!u16 {
        return self.resolveInternal(cwd, path, true, 0);
    }

    pub fn resolveNoFollow(self: *Vfs, cwd: u16, path: []const u8) Error!u16 {
        return self.resolveInternal(cwd, path, false, 0);
    }

    pub fn stat(self: *Vfs, cwd: u16, path: []const u8) Error!Stat {
        return self.statNode(try self.resolve(cwd, path));
    }

    pub fn statNode(self: *const Vfs, node_index: u16) Error!Stat {
        if (node_index >= self.nodes.len or !self.nodes[node_index].used) return Error.NotFound;
        const node = &self.nodes[node_index];
        return .{
            .node = node_index,
            .generation = node.generation,
            .kind = node.kind,
            .size = node.size,
            .mode = node.mode,
            .readonly = self.nodeReadonly(node_index),
            .mount_id = node.mount_id,
            .link_count = node.link_count,
            .modified_tick = node.modified_tick,
        };
    }

    pub fn canonicalEntryNode(self: *const Vfs, node_index: u16) Error!u16 {
        if (node_index >= self.nodes.len or !self.nodes[node_index].used or self.nodes[node_index].link_count == 0) return Error.NotFound;
        return self.canonicalDentry(node_index) orelse Error.NotFound;
    }

    pub fn list(self: *Vfs, cwd: u16, path: []const u8) Error!DirectoryList {
        const directory = try self.resolve(cwd, path);
        if (self.nodes[directory].kind != .directory) return Error.NotDirectory;
        var result = DirectoryList{};
        for (self.dentries, 0..) |entry, entry_index| {
            if (!entry.used or entry.parent != directory) continue;
            if (result.count >= result.records.len) return Error.NoSpace;
            const visible_node = self.followMount(entry.node);
            const node = &self.nodes[visible_node];
            var record = DirectoryRecord{
                .node = visible_node,
                .entry = @intCast(entry_index),
                .kind = node.kind,
                .size = node.size,
                .readonly = self.nodeReadonly(visible_node),
            };
            record.name_length = entry.name_length;
            @memcpy(record.name[0..entry.name_length], entry.nameSlice());
            result.records[result.count] = record;
            result.count += 1;
        }
        sortDirectoryRecords(result.records[0..result.count]);
        return result;
    }

    pub fn mkdir(self: *Vfs, cwd: u16, path: []const u8, mode: u16, tick: u64) Error!u16 {
        const parent_name = try self.parentAndName(cwd, path);
        return self.createNode(parent_name.parent, parent_name.name, .directory, mode, false, tick);
    }

    pub fn create(self: *Vfs, cwd: u16, path: []const u8, mode: u16, tick: u64) Error!u16 {
        const parent_name = try self.parentAndName(cwd, path);
        return self.createNode(parent_name.parent, parent_name.name, .file, mode, false, tick);
    }

    pub fn link(self: *Vfs, cwd: u16, old_path: []const u8, new_path: []const u8, tick: u64) Error!u16 {
        const node_index = try self.resolveNoFollow(cwd, old_path);
        const node = &self.nodes[node_index];
        if (node.kind == .directory) return Error.IsDirectory;
        if (node.kind != .file) return Error.UnsupportedOperation;
        const destination = try self.parentAndName(cwd, new_path);
        if (node.mount_id != self.nodes[destination.parent].mount_id) return Error.CrossMount;
        if (node.readonly or self.mountReadonly(node.mount_id) or self.nodes[destination.parent].readonly) return Error.ReadOnly;
        if (self.findDentry(destination.parent, destination.name) != null) return Error.AlreadyExists;
        if (node.link_count == std.math.maxInt(u16)) return Error.NoSpace;
        const entry_index = self.freeDentry() orelse return Error.NoSpace;
        self.initializeDentry(entry_index, destination.parent, node_index, destination.name);
        self.nodes[node_index].link_count += 1;
        self.nodes[node_index].modified_tick = tick;
        self.mutations +%= 1;
        return node_index;
    }

    pub fn symlink(self: *Vfs, cwd: u16, target: []const u8, path: []const u8, tick: u64) Error!u16 {
        if (target.len == 0 or std.mem.indexOfScalar(u8, target, 0) != null) return Error.InvalidPath;
        if (target.len > maximum_symlink_target_length) return Error.PathTooLong;
        const parent_name = try self.parentAndName(cwd, path);
        const node_index = try self.createNode(parent_name.parent, parent_name.name, .symlink, 0o777, false, tick);
        @memcpy(self.nodes[node_index].symlink_data[0..target.len], target);
        self.nodes[node_index].size = target.len;
        return node_index;
    }

    pub fn readlink(self: *Vfs, cwd: u16, path: []const u8, output: []u8) Error!usize {
        const node_index = try self.resolveNoFollow(cwd, path);
        const target = try self.symlinkTargetNode(node_index);
        const count = @min(output.len, target.len);
        @memcpy(output[0..count], target[0..count]);
        return count;
    }

    pub fn symlinkTargetNode(self: *const Vfs, node_index: u16) Error![]const u8 {
        if (node_index >= self.nodes.len or !self.nodes[node_index].used or self.nodes[node_index].link_count == 0) return Error.NotFound;
        const node = &self.nodes[node_index];
        if (node.kind != .symlink) return Error.NotSymlink;
        return node.symlink_data[0..node.size];
    }

    pub fn createPseudo(self: *Vfs, cwd: u16, path: []const u8, mode: u16, tick: u64) Error!u16 {
        return self.createPseudoWithOperations(cwd, path, mode, tick, &unsupported_pseudo_operations, null);
    }

    pub fn createPseudoWithOperations(
        self: *Vfs,
        cwd: u16,
        path: []const u8,
        mode: u16,
        tick: u64,
        operations: ?*const PseudoOperations,
        context: ?*anyopaque,
    ) Error!u16 {
        const parent_name = try self.parentAndName(cwd, path);
        const node_index = try self.createNode(parent_name.parent, parent_name.name, .pseudo, mode, false, tick);
        self.nodes[node_index].pseudo_operations = operations;
        self.nodes[node_index].pseudo_context = context;
        return node_index;
    }

    pub fn ensureDirectory(self: *Vfs, cwd: u16, path: []const u8, mode: u16, tick: u64) Error!u16 {
        return self.resolve(cwd, path) catch |err| switch (err) {
            Error.NotFound => self.mkdir(cwd, path, mode, tick),
            else => err,
        };
    }

    pub fn putFile(self: *Vfs, cwd: u16, path: []const u8, bytes: []const u8, mode: u16, readonly: bool, tick: u64) Error!u16 {
        if (bytes.len > maximum_file_size) return Error.FileTooLarge;
        const node_index = self.resolve(cwd, path) catch |err| switch (err) {
            Error.NotFound => try self.create(cwd, path, mode, tick),
            else => return err,
        };
        var node = &self.nodes[node_index];
        if (node.kind == .directory) return Error.IsDirectory;
        if (node.kind != .file) return Error.UnsupportedOperation;
        if (node.readonly or self.mountReadonly(node.mount_id)) return Error.ReadOnly;
        _ = node.data_lock.acquire();
        defer node.data_lock.release();
        _ = try self.writeNodeLocked(node_index, 0, bytes, true, tick);
        node.mode = mode;
        node.readonly = readonly;
        node.modified_tick = tick;
        self.mutations +%= 1;
        return node_index;
    }

    pub fn read(self: *Vfs, cwd: u16, path: []const u8, offset: usize, output: []u8) Error!usize {
        const node_index = try self.resolve(cwd, path);
        var node = &self.nodes[node_index];
        if (node.kind == .directory) return Error.IsDirectory;
        if ((node.mode & 0o444) == 0) return Error.PermissionDenied;
        if (node.kind == .pseudo) return self.readPseudo(node_index, offset, output);
        _ = node.data_lock.acquire();
        defer node.data_lock.release();
        if (offset > node.size) return Error.InvalidOffset;
        const count = @min(output.len, node.size - offset);
        self.readFileDataLocked(node_index, offset, output[0..count]);
        return count;
    }

    pub fn readOnlyView(self: *Vfs, cwd: u16, path: []const u8) Error![]const u8 {
        const node_index = try self.resolve(cwd, path);
        var node = &self.nodes[node_index];
        if (node.kind == .directory) return Error.IsDirectory;
        if ((node.mode & 0o444) == 0) return Error.PermissionDenied;
        if (node.kind != .file) return Error.UnsupportedOperation;
        _ = node.data_lock.acquire();
        defer node.data_lock.release();
        @memset(&self.view_scratch, 0);
        self.readFileDataLocked(node_index, 0, self.view_scratch[0..node.size]);
        return self.view_scratch[0..node.size];
    }

    pub fn write(self: *Vfs, cwd: u16, path: []const u8, offset: usize, bytes: []const u8, truncate_first: bool, tick: u64) Error!usize {
        const node_index = try self.resolve(cwd, path);
        if (self.nodes[node_index].kind == .pseudo) {
            if (truncate_first) return Error.UnsupportedOperation;
            return self.writePseudo(node_index, offset, bytes);
        }
        return self.writeNode(node_index, offset, bytes, truncate_first, tick);
    }

    pub fn append(self: *Vfs, cwd: u16, path: []const u8, bytes: []const u8, tick: u64) Error!usize {
        const node_index = try self.resolve(cwd, path);
        if (self.nodes[node_index].kind == .pseudo) return self.writePseudo(node_index, 0, bytes);
        return (try self.appendNode(node_index, bytes, tick)).written;
    }

    pub fn truncate(self: *Vfs, cwd: u16, path: []const u8, size: usize, tick: u64) Error!void {
        if (size > maximum_file_size) return Error.FileTooLarge;
        const node_index = try self.resolve(cwd, path);
        try self.requireWritableFile(node_index);
        var node = &self.nodes[node_index];
        _ = node.data_lock.acquire();
        defer node.data_lock.release();
        self.truncateNodeLocked(node_index, size, tick);
    }

    pub fn allocate(self: *Vfs, cwd: u16, path: []const u8, offset: usize, length: usize, flags: AllocationFlags, tick: u64) Error!void {
        const node_index = try self.resolve(cwd, path);
        try self.allocateNode(node_index, offset, length, flags, tick);
    }

    pub fn unlink(self: *Vfs, cwd: u16, path: []const u8) Error!void {
        const entry_index = try self.entryForPath(cwd, path);
        const node_index = self.dentries[entry_index].node;
        if (self.nodes[node_index].kind == .directory) return Error.IsDirectory;
        try self.unlinkEntry(entry_index);
    }

    pub fn rmdir(self: *Vfs, cwd: u16, path: []const u8) Error!void {
        const entry_index = try self.entryForPath(cwd, path);
        const node_index = self.dentries[entry_index].node;
        if (node_index == 0 or self.nodes[node_index].kind != .directory) return Error.NotDirectory;
        if (self.hasChildren(node_index)) return Error.DirectoryNotEmpty;
        try self.removeEntry(entry_index);
    }

    pub fn rename(self: *Vfs, cwd: u16, old_path: []const u8, new_path: []const u8, tick: u64) Error!void {
        const source_entry = try self.entryForPath(cwd, old_path);
        const source = self.dentries[source_entry].node;
        if (self.mountAtNode(source) != null) return Error.Busy;
        const destination = try self.parentAndName(cwd, new_path);
        if (self.nodes[source].mount_id != self.nodes[destination.parent].mount_id) return Error.CrossMount;
        if (self.nodes[source].readonly or self.mountReadonly(self.nodes[source].mount_id) or self.nodes[destination.parent].readonly)
            return Error.ReadOnly;
        if (self.nodes[source].kind == .directory and self.isDescendant(destination.parent, source)) return Error.Cycle;

        if (self.findDentry(destination.parent, destination.name)) |target_entry| {
            if (target_entry == source_entry or self.dentries[target_entry].node == source) return;
            try self.validateRenameReplacement(source, self.dentries[target_entry].node);
            self.detachOrReclaimEntry(target_entry);
        }

        self.renameEntry(source_entry, destination.parent, destination.name, tick);
        self.mutations +%= 1;
    }

    pub fn chmod(self: *Vfs, cwd: u16, path: []const u8, mode: u16, tick: u64) Error!void {
        const node_index = try self.resolve(cwd, path);
        if (self.nodes[node_index].readonly or self.mountReadonly(self.nodes[node_index].mount_id)) return Error.ReadOnly;
        self.nodes[node_index].mode = mode & 0o777;
        self.nodes[node_index].modified_tick = tick;
        self.mutations +%= 1;
    }

    pub fn canonicalPath(self: *const Vfs, node_index: u16, output: []u8) Error![]const u8 {
        if (output.len < 2) return Error.PathTooLong;
        if (node_index >= self.nodes.len or !self.nodes[node_index].used or self.nodes[node_index].link_count == 0) return Error.NotFound;
        if (node_index == 0) {
            output[0] = '/';
            return output[0..1];
        }
        var chain: [maximum_nodes + maximum_mounts]u16 = undefined;
        var count: usize = 0;
        var current = node_index;
        while (current != 0) {
            if (count >= chain.len) return Error.Cycle;
            const namespace_node = if (self.mountForRoot(current)) |mount_entry| mount_entry.mountpoint_node else current;
            const entry_index = self.canonicalDentry(namespace_node) orelse return Error.NotFound;
            chain[count] = entry_index;
            count += 1;
            current = self.dentries[entry_index].parent;
        }
        var used: usize = 0;
        var index = count;
        while (index != 0) {
            index -= 1;
            const name = self.dentries[chain[index]].nameSlice();
            if (used + 1 + name.len > output.len) return Error.PathTooLong;
            output[used] = '/';
            used += 1;
            @memcpy(output[used .. used + name.len], name);
            used += name.len;
        }
        return output[0..used];
    }

    pub fn mount(self: *Vfs, cwd: u16, path: []const u8, kind: MountKind, readonly: bool, source: []const u8) Error!u8 {
        if (source.len > 32) return Error.NameTooLong;
        const mountpoint_entry = try self.entryForPath(cwd, path);
        const mountpoint_node = self.dentries[mountpoint_entry].node;
        if (self.nodes[mountpoint_node].kind != .directory) return Error.NotDirectory;
        if (self.mountAtNode(mountpoint_node) != null) return Error.Busy;
        for (self.mounts) |mount_entry| {
            if (!mount_entry.used or mount_entry.id == 1) continue;
            if (self.isDescendant(mount_entry.mountpoint_node, mountpoint_node)) return Error.Busy;
        }
        var mount_index: usize = 1;
        while (mount_index < self.mounts.len and self.mounts[mount_index].used) : (mount_index += 1) {}
        if (mount_index >= self.mounts.len) return Error.NoSpace;
        const root_node = try self.allocateMountRoot(mountpoint_node, @intCast(mount_index + 1));
        errdefer self.reclaimNode(root_node);
        const mount_id: u8 = @intCast(mount_index + 1);
        var mount_entry = Mount{
            .used = true,
            .id = mount_id,
            .parent_id = self.nodes[mountpoint_node].mount_id,
            .mountpoint_node = mountpoint_node,
            .root_node = root_node,
            .kind = kind,
            .readonly = readonly,
            .source_length = @intCast(source.len),
        };
        @memcpy(mount_entry.source[0..source.len], source);
        self.mounts[mount_index] = mount_entry;
        self.migrateMountChildren(mountpoint_node, root_node, mount_id);
        self.mutations +%= 1;
        return mount_id;
    }

    pub fn unmount(self: *Vfs, mount_id: u8) Error!void {
        if (mount_id <= 1) return Error.Busy;
        const mount_index: usize = mount_id - 1;
        if (mount_index >= self.mounts.len or !self.mounts[mount_index].used) return Error.NotFound;
        for (self.mounts) |mount_entry| {
            if (mount_entry.used and mount_entry.parent_id == mount_id) return Error.Busy;
        }
        for (self.open_files) |open_file| {
            if (open_file.used and self.nodes[open_file.node].mount_id == mount_id) return Error.Busy;
        }
        for (self.dentry_cache) |cache_entry| {
            if (!cache_entry.used or cache_entry.references == 0 or cache_entry.dentry >= self.dentries.len) continue;
            const dentry = &self.dentries[cache_entry.dentry];
            if (dentry.used and self.nodes[dentry.node].mount_id == mount_id) return Error.Busy;
        }
        self.destroyMountNamespace(mount_id);
        self.mounts[mount_index] = .{};
        self.mutations +%= 1;
    }

    pub fn mountList(self: *const Vfs) [maximum_mounts]Mount {
        return self.mounts;
    }

    pub fn open(self: *Vfs, owner_pid: u32, cwd: u16, path: []const u8, flags: OpenFlags, mode: u16, tick: u64) Error!u32 {
        if (!flags.read and !flags.write) return Error.PermissionDenied;
        var node_index = self.resolve(cwd, path) catch |err| switch (err) {
            Error.NotFound => if (flags.create) try self.create(cwd, path, mode, tick) else return err,
            else => return err,
        };
        if (self.nodes[node_index].kind == .directory) {
            if (flags.write or flags.create or flags.truncate or flags.append) return Error.IsDirectory;
        } else if (self.nodes[node_index].kind == .pseudo) {
            const operations = self.nodes[node_index].pseudo_operations orelse return Error.UnsupportedOperation;
            if (flags.create or flags.truncate or flags.append) return Error.UnsupportedOperation;
            if (flags.read and ((self.nodes[node_index].mode & 0o444) == 0 or
                (operations.read == null and operations.stream == null))) return Error.PermissionDenied;
            if (flags.write and ((self.nodes[node_index].mode & 0o222) == 0 or
                (operations.write == null and operations.stream == null))) return Error.PermissionDenied;
        } else {
            if (flags.read and (self.nodes[node_index].mode & 0o444) == 0) return Error.PermissionDenied;
            if (flags.write) try self.requireWritableFile(node_index);
            if (flags.truncate and flags.write) try self.truncate(cwd, path, 0, tick);
        }
        node_index = try self.resolve(cwd, path);
        var owner_count: usize = 0;
        for (self.open_files) |open_file| {
            if (open_file.used and open_file.owner_pid == owner_pid) owner_count += 1;
        }
        if (owner_count >= 16) return Error.TooManyOpenFiles;
        var index: usize = 0;
        while (index < self.open_files.len and self.open_files[index].used) : (index += 1) {}
        if (index >= self.open_files.len) return Error.TooManyOpenFiles;
        const generation = nextGeneration(self.open_files[index].generation);
        self.open_files[index] = .{
            .used = true,
            .generation = generation,
            .node = node_index,
            .node_generation = self.nodes[node_index].generation,
            .owner_pid = owner_pid,
            .offset = if (flags.append) self.nodes[node_index].size else 0,
            .readable = flags.read,
            .writable = flags.write,
            .append = flags.append,
        };
        return makeHandle(index, generation);
    }

    pub fn close(self: *Vfs, owner_pid: u32, handle: u32) Error!void {
        const index = try self.resolveOpen(owner_pid, handle);
        const open_file = self.open_files[index];
        const node_index = open_file.node;
        if (self.nodes[node_index].kind == .pseudo) {
            if (self.nodes[open_file.node].pseudo_operations) |operations| {
                if (operations.close) |close_fn| close_fn(self.nodes[open_file.node].pseudo_context, open_file.node, owner_pid);
            }
        }
        const generation = open_file.generation;
        self.open_files[index] = .{ .generation = generation };
        self.maybeReclaimUnlinked(node_index);
    }

    pub fn closeAll(self: *Vfs, owner_pid: u32) usize {
        var count: usize = 0;
        for (&self.open_files) |*open_file| {
            if (!open_file.used or open_file.owner_pid != owner_pid) continue;
            const node_index = open_file.node;
            if (self.nodes[node_index].kind == .pseudo) {
                if (self.nodes[open_file.node].pseudo_operations) |operations| {
                    if (operations.close) |close_fn| close_fn(self.nodes[open_file.node].pseudo_context, open_file.node, owner_pid);
                }
            }
            const generation = open_file.generation;
            open_file.* = .{ .generation = generation };
            self.maybeReclaimUnlinked(node_index);
            count += 1;
        }
        return count;
    }

    pub fn readOpen(self: *Vfs, owner_pid: u32, handle: u32, output: []u8) Error!usize {
        const index = try self.resolveOpen(owner_pid, handle);
        var open_file = &self.open_files[index];
        if (!open_file.readable) return Error.PermissionDenied;
        var node = &self.nodes[open_file.node];
        if (node.kind == .directory) return Error.IsDirectory;
        if (node.kind == .pseudo) {
            const count = try self.readPseudo(open_file.node, open_file.offset, output);
            open_file.offset += count;
            return count;
        }
        _ = node.data_lock.acquire();
        defer node.data_lock.release();
        if (open_file.offset > node.size) return Error.InvalidOffset;
        const count = @min(output.len, node.size - open_file.offset);
        self.readFileDataLocked(open_file.node, open_file.offset, output[0..count]);
        open_file.offset += count;
        return count;
    }

    pub fn statOpen(self: *const Vfs, owner_pid: u32, handle: u32) Error!Stat {
        const index = try self.resolveOpen(owner_pid, handle);
        return self.statNode(self.open_files[index].node);
    }

    pub fn readDirectoryOpen(
        self: *Vfs,
        owner_pid: u32,
        handle: u32,
        output: []DirectoryRecord,
    ) Error!usize {
        const open_index = try self.resolveOpen(owner_pid, handle);
        var open_file = &self.open_files[open_index];
        if (!open_file.readable) return Error.PermissionDenied;
        const directory = open_file.node;
        if (self.nodes[directory].kind != .directory) return Error.NotDirectory;
        var count: usize = 0;
        var entry_index = open_file.offset;
        while (entry_index < self.dentries.len and count < output.len) : (entry_index += 1) {
            const entry = &self.dentries[entry_index];
            if (!entry.used or entry.parent != directory) continue;
            const visible_node = self.followMount(entry.node);
            const node = &self.nodes[visible_node];
            var record = DirectoryRecord{
                .node = visible_node,
                .entry = @intCast(entry_index),
                .kind = node.kind,
                .size = node.size,
                .readonly = self.nodeReadonly(visible_node),
            };
            record.name_length = entry.name_length;
            @memcpy(record.name[0..entry.name_length], entry.nameSlice());
            output[count] = record;
            count += 1;
        }
        open_file.offset = entry_index;
        return count;
    }

    pub fn writeOpen(self: *Vfs, owner_pid: u32, handle: u32, bytes: []const u8, tick: u64) Error!usize {
        const index = try self.resolveOpen(owner_pid, handle);
        var open_file = &self.open_files[index];
        if (!open_file.writable) return Error.PermissionDenied;
        if (self.nodes[open_file.node].kind == .pseudo) {
            const written = try self.writePseudo(open_file.node, open_file.offset, bytes);
            open_file.offset += written;
            return written;
        }
        if (open_file.append) {
            try self.requireWritableFile(open_file.node);
            var node = &self.nodes[open_file.node];
            _ = node.data_lock.acquire();
            defer node.data_lock.release();
            const offset = node.size;
            const written = try self.writeNodeLocked(open_file.node, offset, bytes, false, tick);
            open_file.offset = offset + written;
            return written;
        }
        const written = try self.writeNode(open_file.node, open_file.offset, bytes, false, tick);
        open_file.offset += written;
        return written;
    }

    pub fn seek(self: *Vfs, owner_pid: u32, handle: u32, offset: i64, whence: enum { start, current, end }) Error!usize {
        const index = try self.resolveOpen(owner_pid, handle);
        var open_file = &self.open_files[index];
        if (self.nodes[open_file.node].kind == .pseudo) return Error.NotSeekable;
        const base: i64 = switch (whence) {
            .start => 0,
            .current => @intCast(open_file.offset),
            .end => @intCast(self.nodes[open_file.node].size),
        };
        const target = std.math.add(i64, base, offset) catch return Error.InvalidOffset;
        if (target < 0 or target > maximum_file_size) return Error.InvalidOffset;
        open_file.offset = @intCast(target);
        return open_file.offset;
    }

    pub fn openInfo(self: *const Vfs, owner_pid: u32, handle: u32) Error!OpenInfo {
        const index = try self.resolveOpen(owner_pid, handle);
        const open_file = self.open_files[index];
        return .{
            .node = open_file.node,
            .node_generation = open_file.node_generation,
            .offset = open_file.offset,
            .readable = open_file.readable,
            .writable = open_file.writable,
            .append = open_file.append,
        };
    }

    pub fn pseudoStreamOpen(self: *const Vfs, owner_pid: u32, handle: u32) Error!?PseudoStream {
        const index = try self.resolveOpen(owner_pid, handle);
        const node = &self.nodes[self.open_files[index].node];
        if (node.kind != .pseudo) return null;
        const operations = node.pseudo_operations orelse return Error.UnsupportedOperation;
        return operations.stream;
    }

    pub fn pollOpen(self: *const Vfs, owner_pid: u32, handle: u32, requested: u16) Error!u16 {
        const index = try self.resolveOpen(owner_pid, handle);
        const open_file = self.open_files[index];
        const node = &self.nodes[open_file.node];
        if (node.kind != .pseudo) {
            var ready: u16 = 0;
            if (open_file.readable) ready |= 1 << 0;
            if (open_file.writable) ready |= 1 << 1;
            return ready & requested;
        }
        const operations = node.pseudo_operations orelse return Error.UnsupportedOperation;
        const poll_fn = operations.poll orelse {
            var ready: u16 = 0;
            if (open_file.readable and operations.read != null) ready |= 1 << 0;
            if (open_file.writable and operations.write != null) ready |= 1 << 1;
            return ready & requested;
        };
        return try poll_fn(node.pseudo_context, open_file.node, requested);
    }

    pub fn ioctlOpen(self: *Vfs, owner_pid: u32, handle: u32, request: u64, argument: u64) Error!u64 {
        const index = try self.resolveOpen(owner_pid, handle);
        const node = &self.nodes[self.open_files[index].node];
        if (node.kind != .pseudo) return Error.UnsupportedOperation;
        const operations = node.pseudo_operations orelse return Error.UnsupportedOperation;
        const ioctl_fn = operations.ioctl orelse return Error.UnsupportedOperation;
        return ioctl_fn(node.pseudo_context, self.open_files[index].node, request, argument);
    }

    pub fn directoryNodeOpen(self: *const Vfs, owner_pid: u32, handle: u32) Error!u16 {
        const index = try self.resolveOpen(owner_pid, handle);
        const node_index = self.open_files[index].node;
        if (self.nodes[node_index].kind != .directory) return Error.NotDirectory;
        return node_index;
    }

    pub fn persistentNode(self: *const Vfs, node_index: u16) Error!bool {
        if (node_index >= self.nodes.len or !self.nodes[node_index].used) return Error.NotFound;
        const mount_id = self.nodes[node_index].mount_id;
        if (mount_id == 0) return false;
        const mount_index: usize = mount_id - 1;
        return mount_index < self.mounts.len and self.mounts[mount_index].used and self.mounts[mount_index].kind == .zigos_persist;
    }

    pub fn persistentOpenNode(self: *const Vfs, owner_pid: u32, handle: u32) Error!?u16 {
        const index = try self.resolveOpen(owner_pid, handle);
        const node_index = self.open_files[index].node;
        return if (try self.persistentNode(node_index)) node_index else null;
    }

    pub fn persistentOpen(self: *const Vfs, owner_pid: u32, handle: u32) Error!bool {
        return (try self.persistentOpenNode(owner_pid, handle)) != null;
    }

    pub fn truncateOpen(self: *Vfs, owner_pid: u32, handle: u32, size: usize, tick: u64) Error!void {
        if (size > maximum_file_size) return Error.FileTooLarge;
        const index = try self.resolveOpen(owner_pid, handle);
        const node_index = self.open_files[index].node;
        if (!self.open_files[index].writable) return Error.PermissionDenied;
        try self.requireWritableFile(node_index);
        var node = &self.nodes[node_index];
        _ = node.data_lock.acquire();
        defer node.data_lock.release();
        self.truncateNodeLocked(node_index, size, tick);
    }

    pub fn allocateOpen(self: *Vfs, owner_pid: u32, handle: u32, offset: usize, length: usize, flags: AllocationFlags, tick: u64) Error!void {
        const index = try self.resolveOpen(owner_pid, handle);
        if (!self.open_files[index].writable) return Error.PermissionDenied;
        try self.allocateNode(self.open_files[index].node, offset, length, flags, tick);
    }

    pub fn sparseFileInfoNode(self: *const Vfs, node_index: u16) Error!SparseFileInfo {
        if (node_index >= self.nodes.len or !self.nodes[node_index].used or self.nodes[node_index].kind != .file) return Error.NotFound;
        const node = &self.nodes[node_index];
        var bitmap: u8 = 0;
        var count: u8 = 0;
        for (node.file_blocks, 0..) |block_index, slot| {
            if (block_index == invalid_data_block) continue;
            bitmap |= @as(u8, 1) << @intCast(slot);
            count += 1;
        }
        return .{ .size = self.nodes[node_index].size, .allocation_bitmap = bitmap, .allocated_blocks = count };
    }

    pub fn readAllocatedBlockNode(self: *Vfs, node_index: u16, slot: usize, output: *[file_block_size]u8) Error!bool {
        if (node_index >= self.nodes.len or !self.nodes[node_index].used or self.nodes[node_index].kind != .file or slot >= file_blocks_per_node) return Error.NotFound;
        var node = &self.nodes[node_index];
        _ = node.data_lock.acquire();
        defer node.data_lock.release();
        const block_index = node.file_blocks[slot];
        if (block_index == invalid_data_block) {
            @memset(output, 0);
            return false;
        }
        @memcpy(output, &self.data_blocks[block_index].data);
        return true;
    }

    pub fn restoreSparseFile(self: *Vfs, cwd: u16, path: []const u8, mode: u16, size: usize, allocation_bitmap: u8, allocated_data: []const u8, tick: u64) Error!u16 {
        if (size > maximum_file_size) return Error.FileTooLarge;
        const allocated_count: usize = @popCount(allocation_bitmap);
        if (allocated_data.len != allocated_count * file_block_size) return Error.InvalidPath;
        const node_index = self.resolve(cwd, path) catch |err| switch (err) {
            Error.NotFound => try self.create(cwd, path, mode, tick),
            else => return err,
        };
        var node = &self.nodes[node_index];
        if (node.kind == .directory) return Error.IsDirectory;
        if (node.kind != .file) return Error.UnsupportedOperation;
        if (node.readonly or self.mountReadonly(node.mount_id)) return Error.ReadOnly;
        _ = node.data_lock.acquire();
        defer node.data_lock.release();
        _ = self.data_pool_lock.acquire();
        defer self.data_pool_lock.release();
        const reusable = self.nodeAllocatedBlockCount(node_index);
        if (allocated_count > self.freeDataBlockCount() + reusable) return Error.NoSpace;
        self.releaseAllFileBlocksLocked(node_index);
        var data_offset: usize = 0;
        var slot: usize = 0;
        while (slot < file_blocks_per_node) : (slot += 1) {
            if ((allocation_bitmap & (@as(u8, 1) << @intCast(slot))) == 0) continue;
            self.allocateFileBlockLocked(node_index, slot);
            const block_index = node.file_blocks[slot];
            @memcpy(&self.data_blocks[block_index].data, allocated_data[data_offset .. data_offset + file_block_size]);
            data_offset += file_block_size;
        }
        node.size = size;
        node.mode = mode & 0o777;
        node.modified_tick = tick;
        self.invalidateFilePageCacheNode(node_index);
        self.mutations +%= 1;
        return node_index;
    }

    pub fn validate(self: *const Vfs) bool {
        if (self.data_pool_lock.next() != self.data_pool_lock.serving()) return false;
        if (self.file_page_cache_lock.next() != self.file_page_cache_lock.serving()) return false;
        if (!self.nodes[0].used or self.nodes[0].generation == 0 or self.nodes[0].kind != .directory or self.nodes[0].link_count != 1) return false;
        var counted_links: [maximum_nodes]u16 = @splat(0);
        counted_links[0] = 1;
        for (self.mounts) |mount_entry| {
            if (!mount_entry.used or mount_entry.id == 1) continue;
            if (mount_entry.root_node >= self.nodes.len) return false;
            counted_links[mount_entry.root_node] = std.math.add(u16, counted_links[mount_entry.root_node], 1) catch return false;
        }
        for (self.dentries, 0..) |entry, entry_index| {
            if (!entry.used) continue;
            if (entry.generation == 0 or entry.name_length == 0 or entry.name_length > maximum_name_length) return false;
            if (entry.parent >= self.nodes.len or !self.nodes[entry.parent].used or self.nodes[entry.parent].kind != .directory or self.nodes[entry.parent].link_count == 0) return false;
            if (entry.node == 0 or entry.node >= self.nodes.len or !self.nodes[entry.node].used) return false;
            counted_links[entry.node] = std.math.add(u16, counted_links[entry.node], 1) catch return false;
            for (entry_index + 1..self.dentries.len) |other_index| {
                const other = &self.dentries[other_index];
                if (!other.used or other.parent != entry.parent or other.name_length != entry.name_length) continue;
                if (std.ascii.eqlIgnoreCase(other.nameSlice(), entry.nameSlice())) return false;
            }
        }
        for (0..self.nodes.len) |index| {
            const node = &self.nodes[index];
            if (node.data_lock.next() != node.data_lock.serving()) return false;
            if (node.kind != .file) for (node.file_blocks) |block_index| if (block_index != invalid_data_block) return false;
            if (!node.used) {
                if (counted_links[index] != 0) return false;
                continue;
            }
            if (node.generation == 0 or node.size > maximum_file_size or node.link_count != counted_links[index]) return false;
            if (node.kind == .pseudo and node.pseudo_operations == null) return false;
            if (node.kind == .symlink and (node.size == 0 or node.size > maximum_symlink_target_length)) return false;
            if (index != 0 and node.link_count == 0) {
                if (node.kind == .directory or !self.hasOpenReferences(@intCast(index))) return false;
                for (self.mounts) |mount_entry| if (mount_entry.used and mount_entry.root_node == index) return false;
                continue;
            }
            if (node.kind == .directory and index != 0) {
                if (node.link_count != 1) return false;
                var current: u16 = @intCast(index);
                var depth: usize = 0;
                while (current != 0 and depth < self.nodes.len) : (depth += 1) {
                    current = self.directoryParent(current) catch return false;
                }
                if (current != 0) return false;
            }
        }
        var referenced_blocks: [maximum_data_blocks]bool = @splat(false);
        for (0..self.nodes.len) |node_index| {
            const node = &self.nodes[node_index];
            if (!node.used or node.kind != .file) continue;
            for (node.file_blocks, 0..) |block_index, slot| {
                if (block_index == invalid_data_block) continue;
                if (block_index >= self.data_blocks.len or referenced_blocks[block_index]) return false;
                const block = &self.data_blocks[block_index];
                if (!block.used or block.owner_node != node_index or block.owner_slot != slot) return false;
                referenced_blocks[block_index] = true;
            }
        }
        for (0..self.data_blocks.len) |block_index| {
            const block = &self.data_blocks[block_index];
            if (block.used != referenced_blocks[block_index]) return false;
            if (!block.used and (block.owner_node != invalid_node or block.owner_slot != 0)) return false;
        }
        for (0..self.file_page_cache.len) |cache_index| {
            const entry = &self.file_page_cache[cache_index];
            if (!entry.used) continue;
            if (entry.node >= self.nodes.len or entry.slot >= file_blocks_per_node or entry.node_generation == 0 or entry.last_used == 0) return false;
            const node = &self.nodes[entry.node];
            if (!node.used or node.kind != .file or node.generation != entry.node_generation) return false;
            const block_index = node.file_blocks[entry.slot];
            if (block_index == invalid_data_block) {
                for (entry.data) |byte| if (byte != 0) return false;
            } else {
                if (block_index >= self.data_blocks.len or !std.mem.eql(u8, &entry.data, &self.data_blocks[block_index].data)) return false;
            }
            for (cache_index + 1..self.file_page_cache.len) |other_index| {
                const other = &self.file_page_cache[other_index];
                if (other.used and other.node == entry.node and other.node_generation == entry.node_generation and other.slot == entry.slot) return false;
            }
        }
        for (self.dentry_cache) |cache_entry| {
            if (!cache_entry.used) continue;
            if (cache_entry.generation == 0 or cache_entry.name_length == 0 or cache_entry.name_length > maximum_name_length or cache_entry.references == 0 and cache_entry.stale) return false;
            if (cache_entry.stale) continue;
            if (!self.cacheEntryValid(&cache_entry)) return false;
        }
        for (self.mounts, 0..) |mount_entry, index| {
            if (!mount_entry.used) continue;
            if (mount_entry.id != index + 1 or mount_entry.root_node >= self.nodes.len or mount_entry.mountpoint_node >= self.nodes.len) return false;
            if (!self.nodes[mount_entry.root_node].used or self.nodes[mount_entry.root_node].kind != .directory or self.nodes[mount_entry.root_node].link_count == 0) return false;
            if (!self.nodes[mount_entry.mountpoint_node].used or self.nodes[mount_entry.mountpoint_node].kind != .directory or self.nodes[mount_entry.mountpoint_node].link_count == 0) return false;
            if (index == 0) {
                if (mount_entry.id != 1 or mount_entry.parent_id != 0 or mount_entry.root_node != 0 or mount_entry.mountpoint_node != 0) return false;
            } else {
                if (mount_entry.parent_id == 0 or mount_entry.parent_id == mount_entry.id) return false;
                const parent_index: usize = mount_entry.parent_id - 1;
                if (parent_index >= self.mounts.len or !self.mounts[parent_index].used) return false;
                if (self.nodes[mount_entry.mountpoint_node].mount_id != mount_entry.parent_id or self.nodes[mount_entry.root_node].mount_id != mount_entry.id) return false;
                if (self.canonicalDentry(mount_entry.root_node) != null) return false;
                if (self.mountAtNode(mount_entry.mountpoint_node) == null or self.mountAtNode(mount_entry.mountpoint_node).?.id != mount_entry.id) return false;
                var current_id = mount_entry.parent_id;
                var depth: usize = 0;
                while (current_id != 1 and depth < self.mounts.len) : (depth += 1) {
                    const current_index: usize = current_id - 1;
                    if (current_index >= self.mounts.len or !self.mounts[current_index].used) return false;
                    current_id = self.mounts[current_index].parent_id;
                }
                if (current_id != 1) return false;
            }
            for (index + 1..self.mounts.len) |other_index| {
                const other = self.mounts[other_index];
                if (!other.used) continue;
                if (other.mountpoint_node == mount_entry.mountpoint_node or other.root_node == mount_entry.root_node) return false;
            }
        }
        for (self.open_files) |open_file| {
            if (!open_file.used) continue;
            if (open_file.generation == 0 or open_file.node >= self.nodes.len or !self.nodes[open_file.node].used) return false;
            if (self.nodes[open_file.node].generation != open_file.node_generation) return false;
        }
        return true;
    }

    pub fn report(self: *const Vfs) Report {
        var result = Report{
            .nodes_used = 0,
            .dentries_used = 0,
            .files = 0,
            .directories = 0,
            .pseudo_files = 0,
            .mounts = 0,
            .open_files = 0,
            .bytes_used = 0,
            .mutations = self.mutations,
            .rejected_operations = self.rejected_operations,
            .dentry_cache_entries = 0,
            .dentry_cache_references = 0,
            .dentry_cache_hits = self.dentry_cache_hits,
            .dentry_cache_misses = self.dentry_cache_misses,
            .dentry_cache_insertions = self.dentry_cache_insertions,
            .dentry_cache_evictions = self.dentry_cache_evictions,
            .dentry_cache_invalidations = self.dentry_cache_invalidations,
            .dentry_cache_rejections = self.dentry_cache_rejections,
            .dentry_cache_acquires = self.dentry_cache_acquires,
            .dentry_cache_releases = self.dentry_cache_releases,
            .file_page_cache_entries = 0,
            .file_page_cache_hits = self.file_page_cache_hits,
            .file_page_cache_misses = self.file_page_cache_misses,
            .file_page_cache_insertions = self.file_page_cache_insertions,
            .file_page_cache_evictions = self.file_page_cache_evictions,
            .file_page_cache_invalidations = self.file_page_cache_invalidations,
            .file_page_cache_lock_tickets = self.file_page_cache_lock.next(),
            .file_page_cache_lock_outstanding = self.file_page_cache_lock.next() -% self.file_page_cache_lock.serving(),
            .data_lock_tickets = 0,
            .data_lock_outstanding = 0,
            .data_pool_lock_tickets = self.data_pool_lock.next(),
            .data_pool_lock_outstanding = self.data_pool_lock.next() -% self.data_pool_lock.serving(),
            .allocated_blocks = 0,
            .allocated_bytes = 0,
            .sparse_hole_bytes = 0,
        };
        for (0..self.nodes.len) |node_index| {
            const node = &self.nodes[node_index];
            const next_ticket = node.data_lock.next();
            const serving_ticket = node.data_lock.serving();
            result.data_lock_tickets += next_ticket;
            result.data_lock_outstanding += next_ticket -% serving_ticket;
            if (!node.used) continue;
            result.nodes_used += 1;
            result.bytes_used += node.size;
            if (node.kind == .file) {
                const logical_blocks = (node.size + file_block_size - 1) / file_block_size;
                var slot: usize = 0;
                while (slot < logical_blocks) : (slot += 1) {
                    if (node.file_blocks[slot] != invalid_data_block) continue;
                    result.sparse_hole_bytes += @min(file_block_size, node.size - slot * file_block_size);
                }
            }
            switch (node.kind) {
                .file, .symlink => result.files += 1,
                .directory => result.directories += 1,
                .pseudo => result.pseudo_files += 1,
            }
        }
        for (0..self.data_blocks.len) |block_index| {
            result.allocated_blocks += @intFromBool(self.data_blocks[block_index].used);
        }
        result.allocated_bytes = result.allocated_blocks * file_block_size;
        for (self.dentries) |entry| result.dentries_used += @intFromBool(entry.used);
        for (0..self.file_page_cache.len) |cache_index| result.file_page_cache_entries += @intFromBool(self.file_page_cache[cache_index].used);
        for (self.dentry_cache) |cache_entry| {
            result.dentry_cache_entries += @intFromBool(cache_entry.used);
            result.dentry_cache_references += cache_entry.references;
        }
        for (self.mounts) |mount_entry| result.mounts += @intFromBool(mount_entry.used);
        for (self.open_files) |open_file| result.open_files += @intFromBool(open_file.used);
        return result;
    }

    fn resolveInternal(self: *Vfs, cwd: u16, path: []const u8, follow_final: bool, depth: usize) Error!u16 {
        if (path.len == 0) return self.validateDirectory(cwd);
        if (path.len > maximum_path_length) return Error.PathTooLong;
        var current: u16 = if (path[0] == '/') 0 else try self.validateDirectory(cwd);
        var position: usize = 0;
        while (position < path.len) {
            while (position < path.len and path[position] == '/') position += 1;
            if (position >= path.len) break;
            const start = position;
            while (position < path.len and path[position] != '/') position += 1;
            const component = path[start..position];
            if (std.mem.eql(u8, component, ".")) continue;
            if (component.len > maximum_name_length) return Error.NameTooLong;
            if (std.mem.eql(u8, component, "..")) {
                current = try self.directoryParent(current);
                continue;
            }
            if (self.nodes[current].kind != .directory) return Error.NotDirectory;
            const reference = self.acquireDentry(current, component) orelse return Error.NotFound;
            defer self.releaseDentryReference(reference);
            const entry = &self.dentries[reference.dentry];
            const child = entry.node;
            const has_suffix = position < path.len;
            if (self.nodes[child].kind == .symlink and (follow_final or has_suffix)) {
                if (depth >= maximum_symlink_depth) return Error.Cycle;
                const target = self.nodes[child].symlink_data[0..self.nodes[child].size];
                current = try self.resolveInternal(entry.parent, target, true, depth + 1);
            } else {
                current = self.followMount(child);
            }
        }
        return current;
    }

    fn validateDirectory(self: *const Vfs, node_index: u16) Error!u16 {
        if (node_index >= self.nodes.len or !self.nodes[node_index].used or self.nodes[node_index].link_count == 0) return Error.NotFound;
        const visible_node = self.followMount(node_index);
        if (self.nodes[visible_node].kind != .directory) return Error.NotDirectory;
        return visible_node;
    }

    fn findDentry(self: *Vfs, parent: u16, name: []const u8) ?u16 {
        const reference = self.acquireDentry(parent, name) orelse return null;
        defer self.releaseDentryReference(reference);
        return reference.dentry;
    }

    fn acquireDentry(self: *Vfs, parent: u16, name: []const u8) ?DentryReference {
        self.dentry_cache_clock +%= 1;
        if (self.dentry_cache_clock == 0) self.dentry_cache_clock = 1;
        for (&self.dentry_cache, 0..) |*cache_entry, cache_index| {
            if (!cache_entry.used or cache_entry.stale or cache_entry.parent != parent or cache_entry.name_length != name.len) continue;
            if (!std.ascii.eqlIgnoreCase(cache_entry.nameSlice(), name)) continue;
            if (!self.cacheEntryValid(cache_entry)) {
                self.invalidateCacheSlot(cache_index);
                continue;
            }
            if (cache_entry.references == std.math.maxInt(u16)) {
                self.dentry_cache_rejections +%= 1;
                return .{ .dentry = cache_entry.dentry };
            }
            cache_entry.references += 1;
            cache_entry.last_used = self.dentry_cache_clock;
            self.dentry_cache_hits +%= 1;
            self.dentry_cache_acquires +%= 1;
            return .{
                .cache_entry = @intCast(cache_index),
                .cache_generation = cache_entry.generation,
                .dentry = cache_entry.dentry,
            };
        }

        self.dentry_cache_misses +%= 1;
        const dentry_index = self.findDentryUncached(parent, name) orelse return null;
        const cache_index = self.cacheInsertionSlot() orelse {
            self.dentry_cache_rejections +%= 1;
            return .{ .dentry = dentry_index };
        };
        const prior_generation = self.dentry_cache[cache_index].generation;
        if (self.dentry_cache[cache_index].used) self.dentry_cache_evictions +%= 1;
        const generation = nextGeneration(prior_generation);
        const dentry = &self.dentries[dentry_index];
        self.dentry_cache[cache_index] = .{
            .used = true,
            .generation = generation,
            .parent = parent,
            .dentry = dentry_index,
            .dentry_generation = dentry.generation,
            .references = 1,
            .last_used = self.dentry_cache_clock,
            .name_length = @intCast(name.len),
        };
        @memcpy(self.dentry_cache[cache_index].name[0..name.len], name);
        self.dentry_cache_insertions +%= 1;
        self.dentry_cache_acquires +%= 1;
        return .{
            .cache_entry = @intCast(cache_index),
            .cache_generation = generation,
            .dentry = dentry_index,
        };
    }

    fn releaseDentryReference(self: *Vfs, reference: DentryReference) void {
        if (reference.cache_entry == invalid_cache_entry) return;
        const cache_index: usize = reference.cache_entry;
        if (cache_index >= self.dentry_cache.len) return;
        var cache_entry = &self.dentry_cache[cache_index];
        if (!cache_entry.used or cache_entry.generation != reference.cache_generation or cache_entry.references == 0) return;
        cache_entry.references -= 1;
        self.dentry_cache_releases +%= 1;
        if (cache_entry.stale and cache_entry.references == 0) self.clearCacheSlot(cache_index);
    }

    fn findDentryUncached(self: *const Vfs, parent: u16, name: []const u8) ?u16 {
        for (self.dentries, 0..) |entry, index| {
            if (!entry.used or entry.parent != parent or entry.name_length != name.len) continue;
            if (std.ascii.eqlIgnoreCase(entry.nameSlice(), name)) return @intCast(index);
        }
        return null;
    }

    fn cacheEntryValid(self: *const Vfs, cache_entry: *const DentryCacheEntry) bool {
        if (cache_entry.dentry >= self.dentries.len) return false;
        const dentry = &self.dentries[cache_entry.dentry];
        return dentry.used and dentry.generation == cache_entry.dentry_generation and dentry.parent == cache_entry.parent and
            dentry.name_length == cache_entry.name_length and std.ascii.eqlIgnoreCase(dentry.nameSlice(), cache_entry.nameSlice());
    }

    fn cacheInsertionSlot(self: *const Vfs) ?usize {
        var oldest_index: ?usize = null;
        var oldest_tick: u64 = std.math.maxInt(u64);
        for (self.dentry_cache, 0..) |cache_entry, index| {
            if (!cache_entry.used) return index;
            if (cache_entry.references != 0) continue;
            if (cache_entry.last_used < oldest_tick) {
                oldest_tick = cache_entry.last_used;
                oldest_index = index;
            }
        }
        return oldest_index;
    }

    fn invalidateCachedDentry(self: *Vfs, dentry_index: u16) void {
        for (&self.dentry_cache, 0..) |*cache_entry, cache_index| {
            if (!cache_entry.used or cache_entry.dentry != dentry_index) continue;
            self.dentry_cache_invalidations +%= 1;
            if (cache_entry.references == 0) {
                self.clearCacheSlot(cache_index);
            } else {
                cache_entry.stale = true;
            }
        }
    }

    fn invalidateCacheSlot(self: *Vfs, cache_index: usize) void {
        if (!self.dentry_cache[cache_index].used) return;
        self.dentry_cache_invalidations +%= 1;
        if (self.dentry_cache[cache_index].references == 0) {
            self.clearCacheSlot(cache_index);
        } else {
            self.dentry_cache[cache_index].stale = true;
        }
    }

    fn clearCacheSlot(self: *Vfs, cache_index: usize) void {
        const generation = self.dentry_cache[cache_index].generation;
        self.dentry_cache[cache_index] = .{ .generation = generation };
    }

    fn findChild(self: *Vfs, parent: u16, name: []const u8) ?u16 {
        const entry_index = self.findDentry(parent, name) orelse return null;
        return self.dentries[entry_index].node;
    }

    fn entryForPath(self: *Vfs, cwd: u16, path: []const u8) Error!u16 {
        const parent_name = try self.parentAndName(cwd, path);
        return self.findDentry(parent_name.parent, parent_name.name) orelse Error.NotFound;
    }

    fn canonicalDentry(self: *const Vfs, node_index: u16) ?u16 {
        for (self.dentries, 0..) |entry, index| {
            if (entry.used and entry.node == node_index) return @intCast(index);
        }
        return null;
    }

    fn directoryParent(self: *const Vfs, node_index: u16) Error!u16 {
        if (node_index == 0) return 0;
        if (node_index >= self.nodes.len or !self.nodes[node_index].used or self.nodes[node_index].kind != .directory or self.nodes[node_index].link_count == 0) return Error.NotDirectory;
        if (self.mountForRoot(node_index)) |mount_entry| {
            const entry_index = self.canonicalDentry(mount_entry.mountpoint_node) orelse return Error.NotFound;
            return self.dentries[entry_index].parent;
        }
        const entry_index = self.canonicalDentry(node_index) orelse return Error.NotFound;
        return self.dentries[entry_index].parent;
    }

    fn hasChildren(self: *const Vfs, node_index: u16) bool {
        for (self.dentries) |entry| if (entry.used and entry.parent == node_index) return true;
        return false;
    }

    const ParentName = struct {
        parent: u16,
        name: []const u8,
    };

    fn parentAndName(self: *Vfs, cwd: u16, path: []const u8) Error!ParentName {
        if (path.len == 0 or path.len > maximum_path_length) return if (path.len == 0) Error.InvalidPath else Error.PathTooLong;
        var end = path.len;
        while (end > 1 and path[end - 1] == '/') end -= 1;
        const trimmed = path[0..end];
        const separator = std.mem.lastIndexOfScalar(u8, trimmed, '/');
        const name = if (separator) |position| trimmed[position + 1 ..] else trimmed;
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return Error.InvalidPath;
        if (name.len > maximum_name_length) return Error.NameTooLong;
        const parent_path = if (separator) |position| blk: {
            if (position == 0) break :blk "/";
            break :blk trimmed[0..position];
        } else ".";
        return .{ .parent = try self.resolve(cwd, parent_path), .name = name };
    }

    fn createNode(self: *Vfs, parent: u16, name: []const u8, kind: Kind, mode: u16, readonly: bool, tick: u64) Error!u16 {
        _ = try self.validateDirectory(parent);
        if (self.findDentry(parent, name) != null) return Error.AlreadyExists;
        if (self.nodes[parent].readonly or self.mountReadonly(self.nodes[parent].mount_id)) return Error.ReadOnly;
        var node_index: usize = 1;
        while (node_index < self.nodes.len and self.nodes[node_index].used) : (node_index += 1) {}
        if (node_index >= self.nodes.len) return Error.NoSpace;
        const entry_index = self.freeDentry() orelse return Error.NoSpace;
        const node_generation = nextGeneration(self.nodes[node_index].generation);
        self.nodes[node_index] = .{
            .used = true,
            .generation = node_generation,
            .kind = kind,
            .link_count = 1,
            .mode = mode & 0o777,
            .readonly = readonly,
            .mount_id = self.nodes[parent].mount_id,
            .modified_tick = tick,
        };
        self.initializeDentry(entry_index, parent, @intCast(node_index), name);
        self.mutations +%= 1;
        return @intCast(node_index);
    }

    fn freeDentry(self: *const Vfs) ?usize {
        for (self.dentries, 0..) |entry, index| if (!entry.used) return index;
        return null;
    }

    fn initializeDentry(self: *Vfs, entry_index: usize, parent: u16, node_index: u16, name: []const u8) void {
        const generation = nextGeneration(self.dentries[entry_index].generation);
        self.dentries[entry_index] = .{
            .used = true,
            .generation = generation,
            .parent = parent,
            .node = node_index,
            .name_length = @intCast(name.len),
        };
        @memcpy(self.dentries[entry_index].name[0..name.len], name);
    }

    fn readPseudo(self: *const Vfs, node_index: u16, offset: usize, output: []u8) Error!usize {
        const node = &self.nodes[node_index];
        const operations = node.pseudo_operations orelse return Error.UnsupportedOperation;
        const read_fn = operations.read orelse return Error.PermissionDenied;
        return read_fn(node.pseudo_context, node_index, offset, output);
    }

    fn writePseudo(self: *Vfs, node_index: u16, offset: usize, bytes: []const u8) Error!usize {
        const node = &self.nodes[node_index];
        const operations = node.pseudo_operations orelse return Error.UnsupportedOperation;
        const write_fn = operations.write orelse return Error.PermissionDenied;
        return write_fn(node.pseudo_context, node_index, offset, bytes);
    }

    const AppendResult = struct {
        written: usize,
        end_offset: usize,
    };

    fn writeNode(self: *Vfs, node_index: u16, offset: usize, bytes: []const u8, truncate_first: bool, tick: u64) Error!usize {
        try self.requireWritableFile(node_index);
        var node = &self.nodes[node_index];
        _ = node.data_lock.acquire();
        defer node.data_lock.release();
        return self.writeNodeLocked(node_index, offset, bytes, truncate_first, tick);
    }

    fn appendNode(self: *Vfs, node_index: u16, bytes: []const u8, tick: u64) Error!AppendResult {
        try self.requireWritableFile(node_index);
        var node = &self.nodes[node_index];
        _ = node.data_lock.acquire();
        defer node.data_lock.release();
        const offset = node.size;
        const written = try self.writeNodeLocked(node_index, offset, bytes, false, tick);
        return .{ .written = written, .end_offset = offset + written };
    }

    fn writeNodeLocked(self: *Vfs, node_index: u16, offset: usize, bytes: []const u8, truncate_first: bool, tick: u64) Error!usize {
        if (offset > maximum_file_size or bytes.len > maximum_file_size - offset) return Error.FileTooLarge;
        try self.prepareWriteBlocks(node_index, offset, bytes.len, truncate_first);
        var node = &self.nodes[node_index];
        if (truncate_first) node.size = 0;
        self.copyIntoFileBlocks(node_index, offset, bytes);
        node.size = @max(node.size, offset + bytes.len);
        node.modified_tick = tick;
        self.invalidateFilePageCacheNode(node_index);
        self.mutations +%= 1;
        return bytes.len;
    }

    fn truncateNodeLocked(self: *Vfs, node_index: u16, size: usize, tick: u64) void {
        var node = &self.nodes[node_index];
        if (size < node.size) {
            _ = self.data_pool_lock.acquire();
            defer self.data_pool_lock.release();
            const first_released_slot = (size + file_block_size - 1) / file_block_size;
            if (size != 0 and size % file_block_size != 0) {
                const slot = size / file_block_size;
                const block_index = node.file_blocks[slot];
                if (block_index != invalid_data_block) @memset(self.data_blocks[block_index].data[size % file_block_size ..], 0);
            }
            var slot = first_released_slot;
            while (slot < file_blocks_per_node) : (slot += 1) self.releaseFileBlockLocked(node_index, slot);
        }
        node.size = size;
        node.modified_tick = tick;
        self.invalidateFilePageCacheNode(node_index);
        self.mutations +%= 1;
    }

    fn allocateNode(self: *Vfs, node_index: u16, offset: usize, length: usize, flags: AllocationFlags, tick: u64) Error!void {
        if (length == 0) return Error.InvalidOffset;
        if (offset > maximum_file_size or length > maximum_file_size - offset) return Error.FileTooLarge;
        if (flags.punch_hole and !flags.keep_size) return Error.InvalidOffset;
        try self.requireWritableFile(node_index);
        var node = &self.nodes[node_index];
        _ = node.data_lock.acquire();
        defer node.data_lock.release();
        if (flags.punch_hole) {
            self.punchHoleLocked(node_index, offset, length);
        } else {
            try self.prepareWriteBlocks(node_index, offset, length, false);
            if (!flags.keep_size) node.size = @max(node.size, offset + length);
        }
        node.modified_tick = tick;
        self.invalidateFilePageCacheNode(node_index);
        self.mutations +%= 1;
    }

    fn punchHoleLocked(self: *Vfs, node_index: u16, offset: usize, length: usize) void {
        _ = self.data_pool_lock.acquire();
        defer self.data_pool_lock.release();
        const end = offset + length;
        const first_slot = offset / file_block_size;
        const last_slot = (end - 1) / file_block_size;
        var slot = first_slot;
        while (slot <= last_slot) : (slot += 1) {
            const block_index = self.nodes[node_index].file_blocks[slot];
            if (block_index == invalid_data_block) continue;
            const block_start = slot * file_block_size;
            const overlap_start = @max(offset, block_start) - block_start;
            const overlap_end = @min(end, block_start + file_block_size) - block_start;
            if (overlap_start == 0 and overlap_end == file_block_size) {
                self.releaseFileBlockLocked(node_index, slot);
            } else {
                @memset(self.data_blocks[block_index].data[overlap_start..overlap_end], 0);
            }
        }
    }

    fn readFileDataLocked(self: *Vfs, node_index: u16, offset: usize, output: []u8) void {
        _ = self.file_page_cache_lock.acquire();
        defer self.file_page_cache_lock.release();
        var copied: usize = 0;
        while (copied < output.len) {
            const logical_offset = offset + copied;
            const slot = logical_offset / file_block_size;
            const block_offset = logical_offset % file_block_size;
            const count = @min(output.len - copied, file_block_size - block_offset);
            const page = self.cachedFilePageLocked(node_index, slot);
            @memcpy(output[copied .. copied + count], page.data[block_offset .. block_offset + count]);
            copied += count;
        }
    }

    fn cachedFilePageLocked(self: *Vfs, node_index: u16, slot: usize) *const FilePageCacheEntry {
        self.file_page_cache_clock +%= 1;
        if (self.file_page_cache_clock == 0) self.file_page_cache_clock = 1;
        const node_generation = self.nodes[node_index].generation;
        for (&self.file_page_cache) |*entry| {
            if (!entry.used or entry.node != node_index or entry.node_generation != node_generation or entry.slot != slot) continue;
            entry.last_used = self.file_page_cache_clock;
            self.file_page_cache_hits +%= 1;
            return entry;
        }
        self.file_page_cache_misses +%= 1;
        var candidate: usize = 0;
        var oldest: u64 = std.math.maxInt(u64);
        for (0..self.file_page_cache.len) |index| {
            const entry = &self.file_page_cache[index];
            if (!entry.used) {
                candidate = index;
                oldest = 0;
                break;
            }
            if (entry.last_used < oldest) {
                oldest = entry.last_used;
                candidate = index;
            }
        }
        if (self.file_page_cache[candidate].used) self.file_page_cache_evictions +%= 1;
        var entry = &self.file_page_cache[candidate];
        entry.* = .{
            .used = true,
            .node = node_index,
            .node_generation = node_generation,
            .slot = @intCast(slot),
            .last_used = self.file_page_cache_clock,
        };
        const block_index = self.nodes[node_index].file_blocks[slot];
        if (block_index == invalid_data_block) {
            @memset(&entry.data, 0);
        } else {
            @memcpy(&entry.data, &self.data_blocks[block_index].data);
        }
        self.file_page_cache_insertions +%= 1;
        return entry;
    }

    fn invalidateFilePageCacheNode(self: *Vfs, node_index: u16) void {
        _ = self.file_page_cache_lock.acquire();
        defer self.file_page_cache_lock.release();
        for (&self.file_page_cache) |*entry| {
            if (!entry.used or entry.node != node_index) continue;
            entry.* = .{};
            self.file_page_cache_invalidations +%= 1;
        }
    }

    fn copyIntoFileBlocks(self: *Vfs, node_index: u16, offset: usize, bytes: []const u8) void {
        var copied: usize = 0;
        while (copied < bytes.len) {
            const logical_offset = offset + copied;
            const slot = logical_offset / file_block_size;
            const block_offset = logical_offset % file_block_size;
            const count = @min(bytes.len - copied, file_block_size - block_offset);
            const block_index = self.nodes[node_index].file_blocks[slot];
            std.debug.assert(block_index != invalid_data_block);
            @memcpy(self.data_blocks[block_index].data[block_offset .. block_offset + count], bytes[copied .. copied + count]);
            copied += count;
        }
    }

    fn prepareWriteBlocks(self: *Vfs, node_index: u16, offset: usize, length: usize, truncate_first: bool) Error!void {
        _ = self.data_pool_lock.acquire();
        defer self.data_pool_lock.release();
        const first_slot = offset / file_block_size;
        const last_slot = if (length == 0) first_slot else (offset + length - 1) / file_block_size;
        var required: usize = 0;
        if (length != 0) {
            var slot = first_slot;
            while (slot <= last_slot) : (slot += 1) {
                if (truncate_first or self.nodes[node_index].file_blocks[slot] == invalid_data_block) required += 1;
            }
        }
        const reusable = if (truncate_first) self.nodeAllocatedBlockCount(node_index) else 0;
        if (required > self.freeDataBlockCount() + reusable) return Error.NoSpace;
        if (truncate_first) self.releaseAllFileBlocksLocked(node_index);
        if (length == 0) return;
        var slot = first_slot;
        while (slot <= last_slot) : (slot += 1) {
            if (self.nodes[node_index].file_blocks[slot] == invalid_data_block) self.allocateFileBlockLocked(node_index, slot);
        }
    }

    fn allocateFileBlockLocked(self: *Vfs, node_index: u16, slot: usize) void {
        for (&self.data_blocks, 0..) |*block, block_index| {
            if (block.used) continue;
            block.* = .{ .used = true, .owner_node = node_index, .owner_slot = @intCast(slot) };
            self.nodes[node_index].file_blocks[slot] = @intCast(block_index);
            return;
        }
        unreachable;
    }

    fn releaseFileBlockLocked(self: *Vfs, node_index: u16, slot: usize) void {
        const block_index = self.nodes[node_index].file_blocks[slot];
        if (block_index == invalid_data_block) return;
        std.debug.assert(block_index < self.data_blocks.len);
        std.debug.assert(self.data_blocks[block_index].used);
        std.debug.assert(self.data_blocks[block_index].owner_node == node_index);
        std.debug.assert(self.data_blocks[block_index].owner_slot == slot);
        self.data_blocks[block_index] = .{};
        self.nodes[node_index].file_blocks[slot] = invalid_data_block;
    }

    fn releaseAllFileBlocks(self: *Vfs, node_index: u16) void {
        _ = self.data_pool_lock.acquire();
        defer self.data_pool_lock.release();
        self.releaseAllFileBlocksLocked(node_index);
    }

    fn releaseAllFileBlocksLocked(self: *Vfs, node_index: u16) void {
        var slot: usize = 0;
        while (slot < file_blocks_per_node) : (slot += 1) self.releaseFileBlockLocked(node_index, slot);
    }

    fn nodeAllocatedBlockCount(self: *const Vfs, node_index: u16) usize {
        const node = &self.nodes[node_index];
        var count: usize = 0;
        for (node.file_blocks) |block_index| count += @intFromBool(block_index != invalid_data_block);
        return count;
    }

    fn freeDataBlockCount(self: *const Vfs) usize {
        var count: usize = 0;
        for (0..self.data_blocks.len) |block_index| count += @intFromBool(!self.data_blocks[block_index].used);
        return count;
    }

    fn requireWritableFile(self: *const Vfs, node_index: u16) Error!void {
        if (node_index >= self.nodes.len or !self.nodes[node_index].used) return Error.NotFound;
        const node = &self.nodes[node_index];
        if (node.kind == .directory) return Error.IsDirectory;
        if (node.kind == .pseudo or node.kind == .symlink or node.readonly or self.mountReadonly(node.mount_id)) return Error.ReadOnly;
        if ((node.mode & 0o222) == 0) return Error.PermissionDenied;
    }

    fn unlinkEntry(self: *Vfs, entry_index: u16) Error!void {
        if (entry_index >= self.dentries.len or !self.dentries[entry_index].used) return Error.NotFound;
        const node_index = self.dentries[entry_index].node;
        if (self.nodes[node_index].readonly or self.mountReadonly(self.nodes[node_index].mount_id)) return Error.ReadOnly;
        if (self.mountAtNode(node_index) != null) return Error.Busy;
        self.detachOrReclaimEntry(entry_index);
        self.mutations +%= 1;
    }

    fn validateRenameReplacement(self: *const Vfs, source: u16, target: u16) Error!void {
        const source_node = &self.nodes[source];
        const target_node = &self.nodes[target];
        if (target_node.readonly or self.mountReadonly(target_node.mount_id)) return Error.ReadOnly;
        if (self.mountAtNode(target) != null) return Error.Busy;
        if (source_node.kind == .pseudo or target_node.kind == .pseudo) return Error.UnsupportedOperation;
        if (source_node.kind == .directory and target_node.kind != .directory) return Error.NotDirectory;
        if (source_node.kind != .directory and target_node.kind == .directory) return Error.IsDirectory;
        if (target_node.kind == .directory) {
            if (self.hasChildren(target)) return Error.DirectoryNotEmpty;
            if (self.hasOpenReferences(target)) return Error.Busy;
        }
    }

    fn detachOrReclaimEntry(self: *Vfs, entry_index: u16) void {
        const node_index = self.dentries[entry_index].node;
        self.releaseDentry(entry_index);
        std.debug.assert(self.nodes[node_index].link_count != 0);
        self.nodes[node_index].link_count -= 1;
        if (self.nodes[node_index].link_count == 0 and !self.hasOpenReferences(node_index)) self.reclaimNode(node_index);
    }

    fn renameEntry(self: *Vfs, entry_index: u16, parent: u16, name: []const u8, tick: u64) void {
        self.invalidateCachedDentry(entry_index);
        var entry = &self.dentries[entry_index];
        entry.parent = parent;
        entry.name = @splat(0);
        entry.name_length = @intCast(name.len);
        @memcpy(entry.name[0..name.len], name);
        self.nodes[entry.node].modified_tick = tick;
    }

    fn removeEntry(self: *Vfs, entry_index: u16) Error!void {
        if (entry_index >= self.dentries.len or !self.dentries[entry_index].used) return Error.NotFound;
        const node_index = self.dentries[entry_index].node;
        if (self.nodes[node_index].readonly or self.mountReadonly(self.nodes[node_index].mount_id)) return Error.ReadOnly;
        if (self.mountAtNode(node_index) != null) return Error.Busy;
        if (self.hasOpenReferences(node_index)) return Error.Busy;
        self.detachOrReclaimEntry(entry_index);
        self.mutations +%= 1;
    }

    fn releaseDentry(self: *Vfs, entry_index: u16) void {
        self.invalidateCachedDentry(entry_index);
        const generation = self.dentries[entry_index].generation;
        self.dentries[entry_index] = .{ .generation = generation };
    }

    fn hasOpenReferences(self: *const Vfs, node_index: u16) bool {
        for (self.open_files) |open_file| {
            if (open_file.used and open_file.node == node_index and open_file.node_generation == self.nodes[node_index].generation) return true;
        }
        return false;
    }

    fn maybeReclaimUnlinked(self: *Vfs, node_index: u16) void {
        if (node_index >= self.nodes.len or !self.nodes[node_index].used or self.nodes[node_index].link_count != 0) return;
        if (!self.hasOpenReferences(node_index)) self.reclaimNode(node_index);
    }

    fn reclaimNode(self: *Vfs, node_index: u16) void {
        self.invalidateFilePageCacheNode(node_index);
        self.releaseAllFileBlocks(node_index);
        const generation = self.nodes[node_index].generation;
        self.nodes[node_index] = .{ .generation = generation };
    }

    fn nodeReadonly(self: *const Vfs, node_index: u16) bool {
        const node = &self.nodes[node_index];
        if (node.kind == .pseudo) {
            const operations = node.pseudo_operations orelse return true;
            return operations.write == null and operations.stream == null;
        }
        return node.readonly or self.mountReadonly(node.mount_id);
    }

    fn mountReadonly(self: *const Vfs, mount_id: u8) bool {
        if (mount_id == 0) return false;
        const index: usize = mount_id - 1;
        return index < self.mounts.len and self.mounts[index].used and self.mounts[index].readonly;
    }

    fn mountAtNode(self: *const Vfs, node_index: u16) ?*const Mount {
        for (&self.mounts) |*mount_entry| {
            if (mount_entry.used and mount_entry.id != 1 and mount_entry.mountpoint_node == node_index) return mount_entry;
        }
        return null;
    }

    fn mountForRoot(self: *const Vfs, node_index: u16) ?*const Mount {
        for (&self.mounts) |*mount_entry| {
            if (mount_entry.used and mount_entry.id != 1 and mount_entry.root_node == node_index) return mount_entry;
        }
        return null;
    }

    fn followMount(self: *const Vfs, node_index: u16) u16 {
        return if (self.mountAtNode(node_index)) |mount_entry| mount_entry.root_node else node_index;
    }

    fn allocateMountRoot(self: *Vfs, mountpoint_node: u16, mount_id: u8) Error!u16 {
        var node_index: usize = 1;
        while (node_index < self.nodes.len and self.nodes[node_index].used) : (node_index += 1) {}
        if (node_index >= self.nodes.len) return Error.NoSpace;
        const generation = nextGeneration(self.nodes[node_index].generation);
        self.nodes[node_index] = .{
            .used = true,
            .generation = generation,
            .kind = .directory,
            .link_count = 1,
            .mode = self.nodes[mountpoint_node].mode,
            .mount_id = mount_id,
            .modified_tick = self.nodes[mountpoint_node].modified_tick,
        };
        return @intCast(node_index);
    }

    fn migrateMountChildren(self: *Vfs, mountpoint_node: u16, root_node: u16, mount_id: u8) void {
        for (&self.dentries, 0..) |*entry, entry_index| {
            if (!entry.used or entry.parent != mountpoint_node) continue;
            self.invalidateCachedDentry(@intCast(entry_index));
            entry.parent = root_node;
            self.assignNodeMountRecursive(entry.node, mount_id);
        }
    }

    fn assignNodeMountRecursive(self: *Vfs, node_index: u16, mount_id: u8) void {
        self.nodes[node_index].mount_id = mount_id;
        for (self.dentries) |entry| {
            if (entry.used and entry.parent == node_index) self.assignNodeMountRecursive(entry.node, mount_id);
        }
    }

    fn destroyMountNamespace(self: *Vfs, mount_id: u8) void {
        for (0..self.dentries.len) |entry_index| {
            const entry = &self.dentries[entry_index];
            if (!entry.used or self.nodes[entry.node].mount_id != mount_id) continue;
            self.releaseDentry(@intCast(entry_index));
        }
        for (1..self.nodes.len) |node_index| {
            if (self.nodes[node_index].used and self.nodes[node_index].mount_id == mount_id) self.reclaimNode(@intCast(node_index));
        }
    }

    fn isDescendant(self: *const Vfs, candidate: u16, ancestor: u16) bool {
        var current = candidate;
        var traversed: usize = 0;
        while (traversed < self.nodes.len) : (traversed += 1) {
            if (current == ancestor) return true;
            if (current == 0) return false;
            current = self.directoryParent(current) catch return true;
        }
        return true;
    }

    fn resolveOpen(self: *const Vfs, owner_pid: u32, handle: u32) Error!usize {
        const index: usize = @intCast(handle & 0xFFFF);
        const generation: u16 = @intCast(handle >> 16);
        if (index >= self.open_files.len) return Error.InvalidHandle;
        const open_file = self.open_files[index];
        if (!open_file.used or open_file.generation != generation or open_file.owner_pid != owner_pid) return Error.InvalidHandle;
        if (open_file.node >= self.nodes.len or !self.nodes[open_file.node].used or self.nodes[open_file.node].generation != open_file.node_generation) return Error.InvalidHandle;
        return index;
    }
};

fn sourceArray(comptime value: []const u8) [32]u8 {
    var output: [32]u8 = @splat(0);
    @memcpy(output[0..value.len], value);
    return output;
}

fn nextGeneration(current: u16) u16 {
    const next = current +% 1;
    return if (next == 0) 1 else next;
}

fn makeHandle(index: usize, generation: u16) u32 {
    return (@as(u32, generation) << 16) | @as(u32, @intCast(index));
}

fn sortDirectoryRecords(records: []DirectoryRecord) void {
    var index: usize = 1;
    while (index < records.len) : (index += 1) {
        const value = records[index];
        var position = index;
        while (position > 0 and std.ascii.lessThanIgnoreCase(value.nameSlice(), records[position - 1].nameSlice())) : (position -= 1) {
            records[position] = records[position - 1];
        }
        records[position] = value;
    }
}

const TestPseudoContext = struct {
    written: usize = 0,
    closes: usize = 0,
};

fn testPseudoRead(_: ?*anyopaque, _: u16, offset: usize, output: []u8) Error!usize {
    const payload = "device";
    if (offset >= payload.len) return 0;
    const count = @min(output.len, payload.len - offset);
    @memcpy(output[0..count], payload[offset .. offset + count]);
    return count;
}

fn testPseudoWrite(context: ?*anyopaque, _: u16, _: usize, input: []const u8) Error!usize {
    const state: *TestPseudoContext = @ptrCast(@alignCast(context.?));
    state.written += input.len;
    return input.len;
}

fn testPseudoPoll(_: ?*anyopaque, _: u16, requested: u16) Error!u16 {
    return requested & 0x3;
}

fn testPseudoIoctl(_: ?*anyopaque, _: u16, request: u64, argument: u64) Error!u64 {
    return request + argument;
}

fn testPseudoClose(context: ?*anyopaque, _: u16, _: u32) void {
    const state: *TestPseudoContext = @ptrCast(@alignCast(context.?));
    state.closes += 1;
}

const test_pseudo_operations = PseudoOperations{
    .read = testPseudoRead,
    .write = testPseudoWrite,
    .poll = testPseudoPoll,
    .ioctl = testPseudoIoctl,
    .close = testPseudoClose,
};

const test_console_operations = PseudoOperations{ .stream = .console };

test "VFS pseudo nodes dispatch independent operations inside read only devfs" {
    var fs = Vfs.init();
    const dev = try fs.mkdir(0, "/dev", 0o755, 1);
    var context = TestPseudoContext{};
    _ = try fs.createPseudoWithOperations(dev, "device", 0o666, 2, &test_pseudo_operations, &context);
    _ = try fs.createPseudoWithOperations(dev, "console", 0o666, 2, &test_console_operations, null);
    _ = try fs.mount(0, "/dev", .devfs, true, "kernel-devices");

    const info = try fs.stat(0, "/dev/device");
    try std.testing.expect(!info.readonly);
    try std.testing.expectEqual(@as(u16, 0o666), info.mode);

    const handle = try fs.open(7, 0, "/dev/device", .{ .read = true, .write = true }, 0, 3);
    var output: [8]u8 = undefined;
    const count = try fs.readOpen(7, handle, &output);
    try std.testing.expectEqualStrings("device", output[0..count]);
    try std.testing.expectEqual(@as(usize, 3), try fs.writeOpen(7, handle, "abc", 4));
    try std.testing.expectEqual(@as(u16, 3), try fs.pollOpen(7, handle, 3));
    try std.testing.expectEqual(@as(u64, 12), try fs.ioctlOpen(7, handle, 5, 7));
    try std.testing.expectEqual(@as(?PseudoStream, null), try fs.pseudoStreamOpen(7, handle));
    try std.testing.expectError(Error.UnsupportedOperation, fs.putFile(0, "/dev/device", "dense", 0o644, false, 4));
    try fs.close(7, handle);
    try std.testing.expectEqual(@as(usize, 3), context.written);
    try std.testing.expectEqual(@as(usize, 1), context.closes);

    const console = try fs.open(8, 0, "/dev/console", .{ .write = true }, 0, 5);
    try std.testing.expectEqual(PseudoStream.console, (try fs.pseudoStreamOpen(8, console)).?);
    try fs.close(8, console);
    try std.testing.expect(fs.validate());
}

test "VFS resolves absolute relative dot and parent paths" {
    var fs = Vfs.init();
    const home = try fs.mkdir(0, "/home", 0o755, 1);
    const user = try fs.mkdir(home, "user", 0o755, 2);
    try std.testing.expectEqual(user, try fs.resolve(0, "/home//user/./"));
    try std.testing.expectEqual(home, try fs.resolve(user, ".."));
    try std.testing.expectEqual(user, try fs.resolve(home, "user"));
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/home/user", try fs.canonicalPath(user, &buffer));
}

const ConcurrentAppendWorker = struct {
    fs: *Vfs,
    owner_pid: u32,
    handle: u32,
    worker_id: u8,

    fn run(worker: ConcurrentAppendWorker) void {
        var iteration: u8 = 0;
        while (iteration < 32) : (iteration += 1) {
            const record = [4]u8{ worker.worker_id, iteration, 0xA5, 0x5A };
            const written = worker.fs.writeOpen(worker.owner_pid, worker.handle, &record, iteration) catch
                @panic("concurrent append write failed");
            if (written != record.len) @panic("concurrent append write was partial");
        }
    }
};

test "VFS append writes are atomic across independent concurrent writers" {
    var fs = Vfs.init();
    _ = try fs.mkdir(0, "/tmp", 0o777, 1);
    const workers: usize = 4;
    var handles: [workers]u32 = undefined;
    var threads: [workers]std.Thread = undefined;

    for (0..workers) |worker_index| {
        const owner_pid: u32 = @intCast(worker_index + 1);
        handles[worker_index] = try fs.open(
            owner_pid,
            0,
            "/tmp/atomic-append",
            .{ .write = true, .create = worker_index == 0, .truncate = worker_index == 0, .append = true },
            0o644,
            2,
        );
    }
    const before = fs.report().data_lock_tickets;
    for (0..workers) |worker_index| {
        threads[worker_index] = try std.Thread.spawn(.{}, ConcurrentAppendWorker.run, .{ConcurrentAppendWorker{
            .fs = &fs,
            .owner_pid = @intCast(worker_index + 1),
            .handle = handles[worker_index],
            .worker_id = @intCast(worker_index),
        }});
    }
    for (&threads) |*thread| thread.join();
    const after_appends = fs.report();

    const expected_records = workers * 32;
    const expected_bytes = expected_records * 4;
    const info = try fs.stat(0, "/tmp/atomic-append");
    try std.testing.expectEqual(expected_bytes, info.size);
    var contents: [expected_bytes]u8 = undefined;
    try std.testing.expectEqual(expected_bytes, try fs.read(0, "/tmp/atomic-append", 0, &contents));
    var seen: [workers][32]bool = @splat(@splat(false));
    var offset: usize = 0;
    while (offset < contents.len) : (offset += 4) {
        const worker_id = contents[offset];
        const iteration = contents[offset + 1];
        try std.testing.expect(worker_id < workers and iteration < 32);
        try std.testing.expectEqual(@as(u8, 0xA5), contents[offset + 2]);
        try std.testing.expectEqual(@as(u8, 0x5A), contents[offset + 3]);
        try std.testing.expect(!seen[worker_id][iteration]);
        seen[worker_id][iteration] = true;
    }
    for (seen) |worker_records| for (worker_records) |present| try std.testing.expect(present);
    const after = fs.report();
    try std.testing.expectEqual(@as(u64, expected_records), after_appends.data_lock_tickets - before);
    try std.testing.expectEqual(@as(u64, 0), after.data_lock_outstanding);
    for (0..workers) |worker_index| try fs.close(@intCast(worker_index + 1), handles[worker_index]);
    try std.testing.expect(fs.validate());
}

test "VFS sparse holes allocate punch persist size and reuse bounded blocks" {
    var fs = Vfs.init();
    _ = try fs.mkdir(0, "/tmp", 0o777, 1);
    const handle = try fs.open(1, 0, "/tmp/sparse", .{ .read = true, .write = true, .create = true }, 0o644, 2);
    _ = try fs.seek(1, handle, 2 * file_block_size, .start);
    try std.testing.expectEqual(@as(usize, 4), try fs.writeOpen(1, handle, "DATA", 3));
    var info = try fs.sparseFileInfoNode((try fs.stat(0, "/tmp/sparse")).node);
    try std.testing.expectEqual(@as(usize, 2 * file_block_size + 4), info.size);
    try std.testing.expectEqual(@as(u8, 1 << 2), info.allocation_bitmap);
    try std.testing.expectEqual(@as(u8, 1), info.allocated_blocks);
    var bytes: [2 * file_block_size + 4]u8 = undefined;
    try std.testing.expectEqual(bytes.len, try fs.read(0, "/tmp/sparse", 0, &bytes));
    for (bytes[0 .. 2 * file_block_size]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    try std.testing.expectEqualStrings("DATA", bytes[2 * file_block_size ..]);

    try fs.allocateOpen(1, handle, 0, file_block_size, .{ .keep_size = true }, 4);
    info = try fs.sparseFileInfoNode((try fs.stat(0, "/tmp/sparse")).node);
    try std.testing.expectEqual(@as(u8, (1 << 0) | (1 << 2)), info.allocation_bitmap);
    try std.testing.expectEqual(@as(usize, 2 * file_block_size + 4), info.size);
    try fs.allocateOpen(1, handle, 2 * file_block_size, file_block_size, .{ .keep_size = true, .punch_hole = true }, 5);
    info = try fs.sparseFileInfoNode((try fs.stat(0, "/tmp/sparse")).node);
    try std.testing.expectEqual(@as(u8, 1 << 0), info.allocation_bitmap);
    try std.testing.expectEqual(@as(usize, 2 * file_block_size + 4), info.size);
    var punched: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try fs.read(0, "/tmp/sparse", 2 * file_block_size, &punched));
    try std.testing.expectEqualSlices(u8, &@as([4]u8, @splat(0)), &punched);
    try std.testing.expectError(Error.InvalidOffset, fs.allocateOpen(1, handle, 0, file_block_size, .{ .punch_hole = true }, 6));

    const full: [maximum_file_size]u8 = @splat(0x6D);
    var file_index: usize = 0;
    while (file_index < maximum_data_blocks / file_blocks_per_node - 1) : (file_index += 1) {
        var path_buffer: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "/tmp/full-{d}", .{file_index});
        _ = try fs.putFile(0, path, &full, 0o600, false, 7);
    }
    _ = try fs.putFile(0, "/tmp/tail", full[0 .. 7 * file_block_size], 0o600, false, 8);
    try std.testing.expectEqual(maximum_data_blocks, fs.report().allocated_blocks);
    const victim = try fs.open(2, 0, "/tmp/victim", .{ .read = true, .write = true, .create = true }, 0o600, 8);
    const before_failure = fs.report();
    try std.testing.expectError(Error.NoSpace, fs.allocateOpen(2, victim, 0, file_block_size, .{}, 9));
    const after_failure = fs.report();
    try std.testing.expectEqual(before_failure.allocated_blocks, after_failure.allocated_blocks);
    try std.testing.expectEqual(@as(usize, 0), (try fs.statOpen(2, victim)).size);
    try fs.unlink(0, "/tmp/full-0");
    try fs.allocateOpen(2, victim, 0, file_block_size, .{}, 10);
    try std.testing.expectEqual(@as(usize, file_block_size), (try fs.statOpen(2, victim)).size);
    try std.testing.expectEqual(maximum_data_blocks - file_blocks_per_node + 1, fs.report().allocated_blocks);
    try fs.close(1, handle);
    try fs.close(2, victim);
    try std.testing.expect(fs.validate());
}

test "VFS bounded clean page cache hits evicts and invalidates mutations" {
    var fs = Vfs.init();
    _ = try fs.mkdir(0, "/page-cache", 0o755, 1);
    var payload: [file_block_size]u8 = undefined;
    var paths: [maximum_file_page_cache_entries + 1][32]u8 = @splat(@splat(0));
    var lengths: [maximum_file_page_cache_entries + 1]u8 = @splat(0);
    for (0..paths.len) |index| {
        @memset(&payload, @intCast(index + 1));
        const path = try std.fmt.bufPrint(&paths[index], "/page-cache/f-{d}", .{index});
        lengths[index] = @intCast(path.len);
        _ = try fs.putFile(0, path, &payload, 0o600, false, @intCast(index + 2));
        var byte: [1]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 1), try fs.read(0, path, 0, &byte));
        try std.testing.expectEqual(@as(u8, @intCast(index + 1)), byte[0]);
    }
    var report = fs.report();
    try std.testing.expectEqual(maximum_file_page_cache_entries, report.file_page_cache_entries);
    try std.testing.expectEqual(@as(u64, paths.len), report.file_page_cache_misses);
    try std.testing.expectEqual(@as(u64, paths.len), report.file_page_cache_insertions);
    try std.testing.expect(report.file_page_cache_evictions > 0);

    const hot_path = paths[paths.len - 1][0..lengths[lengths.len - 1]];
    var hot: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try fs.read(0, hot_path, 0, &hot));
    report = fs.report();
    try std.testing.expect(report.file_page_cache_hits > 0);
    const invalidations_before = report.file_page_cache_invalidations;
    try std.testing.expectEqual(@as(usize, 1), try fs.write(0, hot_path, 0, "Z", false, 100));
    report = fs.report();
    try std.testing.expect(report.file_page_cache_invalidations > invalidations_before);
    try std.testing.expectEqual(@as(usize, 1), try fs.read(0, hot_path, 0, &hot));
    try std.testing.expectEqual(@as(u8, 'Z'), hot[0]);

    const sparse = try fs.open(7, 0, "/page-cache/sparse", .{ .read = true, .write = true, .create = true }, 0o600, 101);
    _ = try fs.seek(7, sparse, file_block_size, .start);
    try std.testing.expectEqual(@as(usize, 1), try fs.writeOpen(7, sparse, "Q", 102));
    _ = try fs.seek(7, sparse, 0, .start);
    var zero: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try fs.readOpen(7, sparse, &zero));
    try std.testing.expectEqual(@as(u8, 0), zero[0]);
    _ = try fs.seek(7, sparse, 0, .start);
    try std.testing.expectEqual(@as(usize, 1), try fs.writeOpen(7, sparse, "R", 103));
    _ = try fs.seek(7, sparse, 0, .start);
    try std.testing.expectEqual(@as(usize, 1), try fs.readOpen(7, sparse, &zero));
    try std.testing.expectEqual(@as(u8, 'R'), zero[0]);
    try fs.close(7, sparse);
    try std.testing.expect(fs.validate());
    try std.testing.expectEqual(@as(u64, 0), fs.report().file_page_cache_lock_outstanding);
}

test "VFS sparse restoration applies final nonwritable mode after privileged reconstruction" {
    var fs = Vfs.init();
    _ = try fs.mkdir(0, "/persist", 0o755, 1);
    const block: [file_block_size]u8 = @splat(0x4B);
    const node = try fs.restoreSparseFile(0, "/persist/tool.elf", 0o555, 17, 0x01, &block, 2);
    const info = try fs.stat(0, "/persist/tool.elf");
    try std.testing.expectEqual(node, info.node);
    try std.testing.expectEqual(@as(u16, 0o555), info.mode);
    try std.testing.expectEqual(@as(usize, 17), info.size);
    var bytes: [17]u8 = undefined;
    try std.testing.expectEqual(bytes.len, try fs.read(0, "/persist/tool.elf", 0, &bytes));
    for (bytes) |byte| try std.testing.expectEqual(@as(u8, 0x4B), byte);
    try std.testing.expectError(Error.PermissionDenied, fs.write(0, "/persist/tool.elf", 0, "x", false, 3));
    try std.testing.expect(fs.validate());
}

test "VFS file create write append truncate and read" {
    var fs = Vfs.init();
    _ = try fs.mkdir(0, "/tmp", 0o777, 1);
    _ = try fs.create(0, "/tmp/note.txt", 0o644, 2);
    try std.testing.expectEqual(@as(usize, 5), try fs.write(0, "/tmp/note.txt", 0, "hello", true, 3));
    try std.testing.expectEqual(@as(usize, 6), try fs.append(0, "/tmp/note.txt", " world", 4));
    var output: [32]u8 = undefined;
    const count = try fs.read(0, "/tmp/note.txt", 0, &output);
    try std.testing.expectEqualStrings("hello world", output[0..count]);
    try fs.truncate(0, "/tmp/note.txt", 5, 5);
    try std.testing.expectEqual(@as(usize, 5), (try fs.stat(0, "/tmp/note.txt")).size);
}

test "VFS accepts the full 32 KiB file boundary" {
    var fs = Vfs.init();
    const payload: [maximum_file_size]u8 = @splat(0x5A);
    const oversized: [maximum_file_size + 1]u8 = @splat(0xA5);
    _ = try fs.putFile(0, "/large.bin", &payload, 0o444, false, 1);
    try std.testing.expectEqual(maximum_file_size, (try fs.stat(0, "/large.bin")).size);
    try std.testing.expectError(Error.FileTooLarge, fs.putFile(0, "/too-large.bin", &oversized, 0o444, false, 2));
}
test "VFS directory mutation rejects cycles and nonempty removal" {
    var fs = Vfs.init();
    const a = try fs.mkdir(0, "/a", 0o755, 1);
    _ = try fs.mkdir(a, "b", 0o755, 2);
    try std.testing.expectError(Error.DirectoryNotEmpty, fs.rmdir(0, "/a"));
    try std.testing.expectError(Error.Cycle, fs.rename(0, "/a", "/a/b/a", 3));
    try fs.rename(0, "/a/b", "/b", 4);
    try fs.rmdir(0, "/a");
    try std.testing.expectEqual(@as(u16, 1), (try fs.stat(0, "/b")).generation);
}

test "VFS dentry cache references protect pinned entries and invalidate mutations" {
    var fs = Vfs.init();
    const cache_dir = try fs.mkdir(0, "/cache", 0o755, 1);
    var names: [maximum_dentry_cache_entries + 6][4]u8 = undefined;
    for (&names, 0..) |*name, index| {
        name.* = .{ 'f', @intCast('0' + (index / 10)), @intCast('0' + (index % 10)), 0 };
        _ = try fs.putFile(cache_dir, name[0..3], "x", 0o644, false, @intCast(index + 2));
    }

    _ = try fs.resolve(cache_dir, names[0][0..3]);
    const pinned = fs.acquireDentry(cache_dir, names[0][0..3]).?;
    try std.testing.expect(pinned.cache_entry != invalid_cache_entry);
    try std.testing.expectEqual(@as(usize, 1), fs.report().dentry_cache_references);
    const pinned_slot: usize = pinned.cache_entry;
    const pinned_generation = pinned.cache_generation;

    for (names[1..]) |name| _ = try fs.resolve(cache_dir, name[0..3]);
    try std.testing.expect(fs.dentry_cache[pinned_slot].used);
    try std.testing.expectEqual(pinned_generation, fs.dentry_cache[pinned_slot].generation);
    try std.testing.expectEqual(@as(u16, 1), fs.dentry_cache[pinned_slot].references);
    try std.testing.expect(fs.report().dentry_cache_evictions > 0);

    try fs.rename(cache_dir, names[0][0..3], "renamed", 100);
    try std.testing.expect(fs.dentry_cache[pinned_slot].stale);
    try std.testing.expectError(Error.NotFound, fs.resolve(cache_dir, names[0][0..3]));
    _ = try fs.resolve(cache_dir, "renamed");
    _ = try fs.resolve(cache_dir, "renamed");
    const before_release = fs.report();
    try std.testing.expectEqual(@as(usize, 1), before_release.dentry_cache_references);
    try std.testing.expect(before_release.dentry_cache_hits > 0);
    try std.testing.expect(before_release.dentry_cache_misses > 0);
    try std.testing.expect(before_release.dentry_cache_invalidations > 0);

    fs.releaseDentryReference(pinned);
    const after_release = fs.report();
    try std.testing.expectEqual(@as(usize, 0), after_release.dentry_cache_references);
    try std.testing.expect(!fs.dentry_cache[pinned_slot].used);
    try std.testing.expectEqual(fs.dentry_cache_acquires, fs.dentry_cache_releases);
    try std.testing.expect(fs.validate());
}

test "VFS hard links share node identity data and deferred lifetime" {
    var fs = Vfs.init();
    const first_dir = try fs.mkdir(0, "/first", 0o755, 1);
    const second_dir = try fs.mkdir(0, "/second", 0o755, 2);
    const baseline_nodes = fs.report().nodes_used;
    const node = try fs.putFile(first_dir, "original", "alpha", 0o644, false, 3);
    try std.testing.expectEqual(node, try fs.link(0, "/first/original", "/first/alias", 4));
    try std.testing.expectEqual(node, try fs.link(0, "/first/alias", "/second/shared", 5));

    const original = try fs.stat(0, "/first/original");
    const alias = try fs.stat(0, "/first/alias");
    const shared = try fs.stat(0, "/second/shared");
    try std.testing.expectEqual(original.node, alias.node);
    try std.testing.expectEqual(original.node, shared.node);
    try std.testing.expectEqual(original.generation, alias.generation);
    try std.testing.expectEqual(@as(u16, 3), original.link_count);
    try std.testing.expectEqual(baseline_nodes + 1, fs.report().nodes_used);

    try std.testing.expectEqual(@as(usize, 5), try fs.append(0, "/first/alias", "-beta", 6));
    try std.testing.expectEqualStrings("alpha-beta", try fs.readOnlyView(0, "/second/shared"));
    const first_listing = try fs.list(0, "/first");
    try std.testing.expectEqual(@as(usize, 2), first_listing.count);
    try std.testing.expectEqual(first_listing.records[0].node, first_listing.records[1].node);

    const retained = try fs.open(7, 0, "/second/shared", .{ .read = true }, 0, 7);
    try fs.unlink(0, "/first/original");
    try std.testing.expectEqual(@as(u16, 2), (try fs.stat(0, "/first/alias")).link_count);
    try fs.unlink(0, "/first/alias");
    try std.testing.expectEqual(@as(u16, 1), (try fs.stat(0, "/second/shared")).link_count);
    try fs.unlink(0, "/second/shared");
    try std.testing.expectError(Error.NotFound, fs.stat(0, "/second/shared"));
    try std.testing.expectEqual(baseline_nodes + 1, fs.report().nodes_used);
    var bytes: [16]u8 = undefined;
    const count = try fs.readOpen(7, retained, &bytes);
    try std.testing.expectEqualStrings("alpha-beta", bytes[0..count]);
    try std.testing.expectEqual(@as(u16, 0), (try fs.statOpen(7, retained)).link_count);
    try fs.close(7, retained);
    try std.testing.expectEqual(baseline_nodes, fs.report().nodes_used);

    _ = try fs.mkdir(0, "/mount", 0o755, 8);
    _ = try fs.mount(0, "/mount", .boot_fat, false, "other");
    _ = try fs.putFile(0, "/first/new", "x", 0o644, false, 9);
    try std.testing.expectError(Error.CrossMount, fs.link(0, "/first/new", "/mount/new", 10));
    try std.testing.expectError(Error.IsDirectory, fs.link(0, "/first", "/first/directory-link", 11));
    _ = try fs.symlink(0, "/first/new", "/first/symbolic", 12);
    try std.testing.expectError(Error.UnsupportedOperation, fs.link(0, "/first/symbolic", "/first/symbolic-hard", 13));
    try std.testing.expect(fs.validate());
    _ = second_dir;
}

test "VFS symbolic links follow relative and absolute targets with bounded loops" {
    var fs = Vfs.init();
    const root_dir = try fs.mkdir(0, "/links", 0o755, 1);
    const nested = try fs.mkdir(root_dir, "nested", 0o755, 2);
    _ = try fs.putFile(nested, "target", "payload", 0o644, false, 3);
    const relative_link = try fs.symlink(root_dir, "nested/target", "relative", 4);
    _ = try fs.symlink(root_dir, "/links/nested/target", "absolute", 5);
    _ = try fs.symlink(root_dir, "../links/nested", "directory", 6);

    var target_buffer: [maximum_path_length]u8 = undefined;
    const target_length = try fs.readlink(root_dir, "relative", &target_buffer);
    try std.testing.expectEqualStrings("nested/target", target_buffer[0..target_length]);
    try std.testing.expectEqual(relative_link, try fs.resolveNoFollow(root_dir, "relative"));
    try std.testing.expectEqualStrings("payload", try fs.readOnlyView(root_dir, "relative"));
    try std.testing.expectEqualStrings("payload", try fs.readOnlyView(root_dir, "absolute"));
    try std.testing.expectEqualStrings("payload", try fs.readOnlyView(root_dir, "directory/target"));
    try std.testing.expectError(Error.NotSymlink, fs.readlink(root_dir, "nested/target", &target_buffer));

    _ = try fs.symlink(root_dir, "loop-b", "loop-a", 7);
    _ = try fs.symlink(root_dir, "loop-a", "loop-b", 8);
    try std.testing.expectError(Error.Cycle, fs.resolve(root_dir, "loop-a"));
    try std.testing.expectError(Error.Cycle, fs.resolve(root_dir, "loop-a/child"));

    try fs.unlink(root_dir, "relative");
    try std.testing.expectError(Error.NotFound, fs.resolveNoFollow(root_dir, "relative"));
    try std.testing.expectEqualStrings("payload", try fs.readOnlyView(root_dir, "nested/target"));
    try fs.rename(root_dir, "absolute", "renamed", 9);
    try std.testing.expectEqualStrings("payload", try fs.readOnlyView(root_dir, "renamed"));
    try std.testing.expect(fs.validate());
}

test "VFS replacement rename preserves open destination handles" {
    var fs = Vfs.init();
    _ = try fs.mkdir(0, "/tmp", 0o777, 1);
    const baseline_nodes = fs.report().nodes_used;
    const source = try fs.putFile(0, "/tmp/source", "replacement", 0o644, false, 2);
    const target = try fs.putFile(0, "/tmp/target", "retained", 0o600, false, 3);
    const retained = try fs.open(7, 0, "/tmp/target", .{ .read = true }, 0, 4);

    try fs.rename(0, "/tmp/source", "/tmp/target", 5);
    try std.testing.expectError(Error.NotFound, fs.stat(0, "/tmp/source"));
    const visible = try fs.stat(0, "/tmp/target");
    try std.testing.expectEqual(source, visible.node);
    try std.testing.expectEqual(@as(u16, 0o644), visible.mode);
    try std.testing.expectEqual(baseline_nodes + 2, fs.report().nodes_used);

    var current_bytes: [16]u8 = undefined;
    const current_count = try fs.read(0, "/tmp/target", 0, &current_bytes);
    try std.testing.expectEqualStrings("replacement", current_bytes[0..current_count]);
    var retained_bytes: [16]u8 = undefined;
    const retained_count = try fs.readOpen(7, retained, &retained_bytes);
    try std.testing.expectEqualStrings("retained", retained_bytes[0..retained_count]);
    try std.testing.expectEqual(target, (try fs.statOpen(7, retained)).node);
    try std.testing.expect(fs.validate());

    try fs.close(7, retained);
    try std.testing.expectEqual(baseline_nodes + 1, fs.report().nodes_used);
    try std.testing.expectError(Error.InvalidHandle, fs.statOpen(7, retained));

    _ = try fs.mkdir(0, "/tmp/directory", 0o755, 6);
    _ = try fs.putFile(0, "/tmp/file", "file", 0o644, false, 7);
    try std.testing.expectError(Error.IsDirectory, fs.rename(0, "/tmp/file", "/tmp/directory", 8));
    try std.testing.expectError(Error.NotDirectory, fs.rename(0, "/tmp/directory", "/tmp/target", 9));
    try std.testing.expect(fs.validate());
}

test "VFS generation handles reject stale and foreign owners" {
    var fs = Vfs.init();
    _ = try fs.mkdir(0, "/tmp", 0o777, 1);
    _ = try fs.putFile(0, "/tmp/a", "abcdef", 0o644, false, 2);
    const handle = try fs.open(7, 0, "/tmp/a", .{ .read = true }, 0, 3);
    var output: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try fs.readOpen(7, handle, &output));
    try std.testing.expectEqualStrings("abc", &output);
    try std.testing.expectError(Error.InvalidHandle, fs.readOpen(8, handle, &output));
    try fs.close(7, handle);
    try std.testing.expectError(Error.InvalidHandle, fs.readOpen(7, handle, &output));
}

test "VFS unlink detaches names and reclaims after the final open handle" {
    var fs = Vfs.init();
    _ = try fs.mkdir(0, "/tmp", 0o777, 1);
    const baseline_nodes = fs.report().nodes_used;
    _ = try fs.putFile(0, "/tmp/live", "alpha", 0o644, false, 2);
    const first = try fs.open(7, 0, "/tmp/live", .{ .read = true, .write = true }, 0, 3);
    const second = try fs.open(8, 0, "/tmp/live", .{ .read = true }, 0, 4);
    const original = try fs.statOpen(7, first);

    try fs.unlink(0, "/tmp/live");
    try std.testing.expectError(Error.NotFound, fs.stat(0, "/tmp/live"));
    try std.testing.expectEqual(baseline_nodes + 1, fs.report().nodes_used);
    try std.testing.expectEqual(@as(usize, 5), try fs.seek(7, first, 0, .end));
    try std.testing.expectEqual(@as(usize, 5), try fs.writeOpen(7, first, "-beta", 5));
    var bytes: [16]u8 = undefined;
    const count = try fs.readOpen(8, second, &bytes);
    try std.testing.expectEqualStrings("alpha-beta", bytes[0..count]);
    try std.testing.expectEqual(@as(usize, 10), (try fs.statOpen(7, first)).size);
    try std.testing.expect(fs.validate());

    try fs.close(7, first);
    try std.testing.expectEqual(baseline_nodes + 1, fs.report().nodes_used);
    try fs.close(8, second);
    try std.testing.expectEqual(baseline_nodes, fs.report().nodes_used);
    try std.testing.expectError(Error.InvalidHandle, fs.statOpen(8, second));

    _ = try fs.putFile(0, "/tmp/live", "new", 0o644, false, 6);
    const replacement = try fs.stat(0, "/tmp/live");
    try std.testing.expect(replacement.generation != original.generation);
    try std.testing.expect(fs.validate());
}

test "VFS nested mount roots cross boundaries and unmount child first" {
    var fs = Vfs.init();
    const outer_point = try fs.mkdir(0, "/outer", 0o755, 1);
    _ = try fs.putFile(outer_point, "seed", "outer-data", 0o644, false, 2);
    const outer_id = try fs.mount(0, "/outer", .ramfs, false, "outer-fs");
    const outer_root = try fs.resolve(0, "/outer");
    try std.testing.expect(outer_root != outer_point);
    try std.testing.expectEqualStrings("outer-data", try fs.readOnlyView(0, "/outer/seed"));
    try std.testing.expectEqual(@as(u16, 0), try fs.resolve(outer_root, ".."));

    const inner_point = try fs.mkdir(outer_root, "inner", 0o755, 3);
    _ = try fs.putFile(inner_point, "seed", "inner-data", 0o644, false, 4);
    const inner_id = try fs.mount(outer_root, "inner", .netfs, true, "inner-fs");
    const inner_root = try fs.resolve(0, "/outer/inner");
    try std.testing.expect(inner_root != inner_point);
    try std.testing.expectEqualStrings("inner-data", try fs.readOnlyView(0, "/outer/inner/seed"));
    try std.testing.expectError(Error.ReadOnly, fs.write(0, "/outer/inner/seed", 0, "x", false, 5));
    try std.testing.expectEqual(outer_root, try fs.resolve(inner_root, ".."));

    var path_buffer: [maximum_path_length + 1]u8 = undefined;
    try std.testing.expectEqualStrings("/outer", try fs.canonicalPath(outer_root, &path_buffer));
    try std.testing.expectEqualStrings("/outer/inner", try fs.canonicalPath(inner_root, &path_buffer));
    try std.testing.expectEqualStrings("/outer/inner/seed", try fs.canonicalPath(try fs.resolve(0, "/outer/inner/seed"), &path_buffer));

    const mounts = fs.mountList();
    try std.testing.expectEqual(@as(u8, 1), mounts[outer_id - 1].parent_id);
    try std.testing.expectEqual(outer_point, mounts[outer_id - 1].mountpoint_node);
    try std.testing.expectEqual(outer_root, mounts[outer_id - 1].root_node);
    try std.testing.expectEqual(outer_id, mounts[inner_id - 1].parent_id);
    try std.testing.expectEqual(inner_point, mounts[inner_id - 1].mountpoint_node);
    try std.testing.expectEqual(inner_root, mounts[inner_id - 1].root_node);

    try std.testing.expectError(Error.Busy, fs.rmdir(0, "/outer/inner"));
    try std.testing.expectError(Error.Busy, fs.rename(0, "/outer/inner", "/outer/renamed", 6));
    try std.testing.expectError(Error.Busy, fs.unmount(outer_id));
    const handle = try fs.open(7, 0, "/outer/inner/seed", .{ .read = true }, 0, 7);
    try std.testing.expectError(Error.Busy, fs.unmount(inner_id));
    try fs.close(7, handle);
    try fs.unmount(inner_id);
    try std.testing.expectEqual(inner_point, try fs.resolve(0, "/outer/inner"));
    try std.testing.expectError(Error.NotFound, fs.resolve(0, "/outer/inner/seed"));
    try fs.unmount(outer_id);
    try std.testing.expectEqual(outer_point, try fs.resolve(0, "/outer"));
    try std.testing.expectError(Error.NotFound, fs.resolve(0, "/outer/seed"));
    try std.testing.expectEqual(@as(usize, 1), fs.report().mounts);
    try std.testing.expect(fs.validate());
}
test "VFS mount policy protects read only trees" {
    var fs = Vfs.init();
    const boot = try fs.mkdir(0, "/boot", 0o755, 1);
    _ = try fs.putFile(boot, "kernel.efi", "image", 0o444, false, 2);
    const mount_id = try fs.mount(0, "/boot", .boot_fat, true, "nvme0p1");
    try std.testing.expectEqual(@as(u8, 2), mount_id);
    try std.testing.expectError(Error.ReadOnly, fs.write(0, "/boot/kernel.efi", 0, "x", false, 3));
    try std.testing.expectError(Error.ReadOnly, fs.create(boot, "new", 0o644, 3));
}
