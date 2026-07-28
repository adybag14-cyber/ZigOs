const std = @import("std");

pub const maximum_nodes: usize = 96;
pub const maximum_dentries: usize = maximum_nodes * 2;
pub const maximum_dentry_cache_entries: usize = 16;
pub const maximum_name_length: usize = 31;
pub const maximum_path_length: usize = 255;
pub const maximum_symlink_depth: usize = 8;
pub const maximum_symlink_target_length: usize = maximum_path_length;
pub const maximum_file_size: usize = 32 * 1024;
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
    data: [maximum_file_size]u8 = @splat(0),
    mode: u16 = 0o644,
    readonly: bool = false,
    mount_id: u8 = 0,
    modified_tick: u64 = 0,
    pseudo_operations: ?*const PseudoOperations = null,
    pseudo_context: ?*anyopaque = null,
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
    node: u16 = invalid_node,
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
};

pub const Vfs = struct {
    nodes: [maximum_nodes]Node = @splat(.{}),
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
            .node = 0,
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
            const node = &self.nodes[entry.node];
            var record = DirectoryRecord{
                .node = entry.node,
                .entry = @intCast(entry_index),
                .kind = node.kind,
                .size = node.size,
                .readonly = self.nodeReadonly(entry.node),
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
        @memcpy(self.nodes[node_index].data[0..target.len], target);
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
        return node.data[0..node.size];
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
        if (node.readonly or self.mountReadonly(node.mount_id)) return Error.ReadOnly;
        @memset(&node.data, 0);
        @memcpy(node.data[0..bytes.len], bytes);
        node.size = bytes.len;
        node.mode = mode;
        node.readonly = readonly;
        node.modified_tick = tick;
        self.mutations +%= 1;
        return node_index;
    }

    pub fn read(self: *Vfs, cwd: u16, path: []const u8, offset: usize, output: []u8) Error!usize {
        const node_index = try self.resolve(cwd, path);
        const node = &self.nodes[node_index];
        if (node.kind == .directory) return Error.IsDirectory;
        if ((node.mode & 0o444) == 0) return Error.PermissionDenied;
        if (node.kind == .pseudo) return self.readPseudo(node_index, offset, output);
        if (offset > node.size) return Error.InvalidOffset;
        const count = @min(output.len, node.size - offset);
        @memcpy(output[0..count], node.data[offset .. offset + count]);
        return count;
    }

    pub fn readOnlyView(self: *Vfs, cwd: u16, path: []const u8) Error![]const u8 {
        const node_index = try self.resolve(cwd, path);
        const node = &self.nodes[node_index];
        if (node.kind == .directory) return Error.IsDirectory;
        if ((node.mode & 0o444) == 0) return Error.PermissionDenied;
        return node.data[0..node.size];
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
        return self.writeNode(node_index, self.nodes[node_index].size, bytes, false, tick);
    }

    pub fn truncate(self: *Vfs, cwd: u16, path: []const u8, size: usize, tick: u64) Error!void {
        if (size > maximum_file_size) return Error.FileTooLarge;
        const node_index = try self.resolve(cwd, path);
        var node = &self.nodes[node_index];
        try self.requireWritableFile(node_index);
        if (size < node.size) @memset(node.data[size..node.size], 0);
        if (size > node.size) @memset(node.data[node.size..size], 0);
        node.size = size;
        node.modified_tick = tick;
        self.mutations +%= 1;
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
        var chain: [maximum_nodes]u16 = undefined;
        var count: usize = 0;
        var current = node_index;
        while (current != 0) {
            if (count >= chain.len) return Error.Cycle;
            const entry_index = self.canonicalDentry(current) orelse return Error.NotFound;
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
        const node_index = try self.resolve(cwd, path);
        if (self.nodes[node_index].kind != .directory) return Error.NotDirectory;
        for (self.mounts) |mount_entry| if (mount_entry.used and mount_entry.node == node_index) return Error.Busy;
        var mount_index: usize = 0;
        while (mount_index < self.mounts.len and self.mounts[mount_index].used) : (mount_index += 1) {}
        if (mount_index >= self.mounts.len) return Error.NoSpace;
        const mount_id: u8 = @intCast(mount_index + 1);
        var mount_entry = Mount{
            .used = true,
            .id = mount_id,
            .node = node_index,
            .kind = kind,
            .readonly = readonly,
            .source_length = @intCast(source.len),
        };
        @memcpy(mount_entry.source[0..source.len], source);
        self.mounts[mount_index] = mount_entry;
        self.assignMountRecursive(node_index, mount_id, readonly);
        self.mutations +%= 1;
        return mount_id;
    }

    pub fn unmount(self: *Vfs, mount_id: u8) Error!void {
        if (mount_id <= 1) return Error.Busy;
        const mount_index: usize = mount_id - 1;
        if (mount_index >= self.mounts.len or !self.mounts[mount_index].used) return Error.NotFound;
        const node_index = self.mounts[mount_index].node;
        for (self.open_files) |open_file| {
            if (open_file.used and self.nodes[open_file.node].mount_id == mount_id) return Error.Busy;
        }
        const parent_mount = self.nodes[try self.directoryParent(node_index)].mount_id;
        self.assignMountRecursive(node_index, parent_mount, false);
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
        const node = &self.nodes[open_file.node];
        if (node.kind == .directory) return Error.IsDirectory;
        if (node.kind == .pseudo) {
            const count = try self.readPseudo(open_file.node, open_file.offset, output);
            open_file.offset += count;
            return count;
        }
        if (open_file.offset > node.size) return Error.InvalidOffset;
        const count = @min(output.len, node.size - open_file.offset);
        @memcpy(output[0..count], node.data[open_file.offset .. open_file.offset + count]);
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
            const node = &self.nodes[entry.node];
            var record = DirectoryRecord{
                .node = entry.node,
                .entry = @intCast(entry_index),
                .kind = node.kind,
                .size = node.size,
                .readonly = self.nodeReadonly(entry.node),
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
        if (open_file.append) open_file.offset = self.nodes[open_file.node].size;
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

    pub fn persistentOpen(self: *const Vfs, owner_pid: u32, handle: u32) Error!bool {
        const index = try self.resolveOpen(owner_pid, handle);
        const mount_id = self.nodes[self.open_files[index].node].mount_id;
        if (mount_id == 0) return false;
        const mount_index: usize = mount_id - 1;
        return mount_index < self.mounts.len and self.mounts[mount_index].used and self.mounts[mount_index].kind == .zigos_persist;
    }

    pub fn truncateOpen(self: *Vfs, owner_pid: u32, handle: u32, size: usize, tick: u64) Error!void {
        if (size > maximum_file_size) return Error.FileTooLarge;
        const index = try self.resolveOpen(owner_pid, handle);
        const node_index = self.open_files[index].node;
        if (!self.open_files[index].writable) return Error.PermissionDenied;
        try self.requireWritableFile(node_index);
        var node = &self.nodes[node_index];
        if (size < node.size) @memset(node.data[size..node.size], 0);
        if (size > node.size) @memset(node.data[node.size..size], 0);
        node.size = size;
        node.modified_tick = tick;
        self.mutations +%= 1;
    }

    pub fn validate(self: *const Vfs) bool {
        if (!self.nodes[0].used or self.nodes[0].generation == 0 or self.nodes[0].kind != .directory or self.nodes[0].link_count != 1) return false;
        var counted_links: [maximum_nodes]u16 = @splat(0);
        counted_links[0] = 1;
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
            if (!node.used) {
                if (counted_links[index] != 0) return false;
                continue;
            }
            if (node.generation == 0 or node.size > maximum_file_size or node.link_count != counted_links[index]) return false;
            if (node.kind == .pseudo and node.pseudo_operations == null) return false;
            if (node.kind == .symlink and (node.size == 0 or node.size > maximum_symlink_target_length)) return false;
            if (index != 0 and node.link_count == 0) {
                if (node.kind == .directory or !self.hasOpenReferences(@intCast(index))) return false;
                for (self.mounts) |mount_entry| if (mount_entry.used and mount_entry.node == index) return false;
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
        for (self.dentry_cache) |cache_entry| {
            if (!cache_entry.used) continue;
            if (cache_entry.generation == 0 or cache_entry.name_length == 0 or cache_entry.name_length > maximum_name_length or cache_entry.references == 0 and cache_entry.stale) return false;
            if (cache_entry.stale) continue;
            if (!self.cacheEntryValid(&cache_entry)) return false;
        }
        for (self.mounts, 0..) |mount_entry, index| {
            if (!mount_entry.used) continue;
            if (mount_entry.id != index + 1 or mount_entry.node >= self.nodes.len or !self.nodes[mount_entry.node].used or self.nodes[mount_entry.node].link_count == 0) return false;
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
        };
        for (0..self.nodes.len) |node_index| {
            const node = &self.nodes[node_index];
            if (!node.used) continue;
            result.nodes_used += 1;
            result.bytes_used += node.size;
            switch (node.kind) {
                .file, .symlink => result.files += 1,
                .directory => result.directories += 1,
                .pseudo => result.pseudo_files += 1,
            }
        }
        for (self.dentries) |entry| result.dentries_used += @intFromBool(entry.used);
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
                const target = self.nodes[child].data[0..self.nodes[child].size];
                current = try self.resolveInternal(entry.parent, target, true, depth + 1);
            } else {
                current = child;
            }
        }
        return current;
    }

    fn validateDirectory(self: *const Vfs, node_index: u16) Error!u16 {
        if (node_index >= self.nodes.len or !self.nodes[node_index].used or self.nodes[node_index].link_count == 0) return Error.NotFound;
        if (self.nodes[node_index].kind != .directory) return Error.NotDirectory;
        return node_index;
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

    fn writeNode(self: *Vfs, node_index: u16, offset: usize, bytes: []const u8, truncate_first: bool, tick: u64) Error!usize {
        try self.requireWritableFile(node_index);
        if (offset > maximum_file_size or bytes.len > maximum_file_size - offset) return Error.FileTooLarge;
        var node = &self.nodes[node_index];
        if (truncate_first) {
            @memset(&node.data, 0);
            node.size = 0;
        }
        if (offset > node.size) @memset(node.data[node.size..offset], 0);
        @memcpy(node.data[offset .. offset + bytes.len], bytes);
        node.size = @max(node.size, offset + bytes.len);
        node.modified_tick = tick;
        self.mutations +%= 1;
        return bytes.len;
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
        for (self.mounts) |mount_entry| if (mount_entry.used and mount_entry.node == node_index) return Error.Busy;
        self.detachOrReclaimEntry(entry_index);
        self.mutations +%= 1;
    }

    fn validateRenameReplacement(self: *const Vfs, source: u16, target: u16) Error!void {
        const source_node = &self.nodes[source];
        const target_node = &self.nodes[target];
        if (target_node.readonly or self.mountReadonly(target_node.mount_id)) return Error.ReadOnly;
        for (self.mounts) |mount_entry| if (mount_entry.used and mount_entry.node == target) return Error.Busy;
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
        for (self.mounts) |mount_entry| if (mount_entry.used and mount_entry.node == node_index) return Error.Busy;
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

    fn assignMountRecursive(self: *Vfs, node_index: u16, mount_id: u8, readonly: bool) void {
        self.nodes[node_index].mount_id = mount_id;
        if (readonly and self.nodes[node_index].kind != .pseudo) self.nodes[node_index].readonly = true;
        for (self.dentries) |entry| {
            if (entry.used and entry.parent == node_index) self.assignMountRecursive(entry.node, mount_id, readonly);
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

test "VFS mount policy protects read only trees" {
    var fs = Vfs.init();
    const boot = try fs.mkdir(0, "/boot", 0o755, 1);
    _ = try fs.putFile(boot, "kernel.efi", "image", 0o444, false, 2);
    const mount_id = try fs.mount(0, "/boot", .boot_fat, true, "nvme0p1");
    try std.testing.expectEqual(@as(u8, 2), mount_id);
    try std.testing.expectError(Error.ReadOnly, fs.write(0, "/boot/kernel.efi", 0, "x", false, 3));
    try std.testing.expectError(Error.ReadOnly, fs.create(boot, "new", 0o644, 3));
}
