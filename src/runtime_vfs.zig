const std = @import("std");

pub const maximum_nodes: usize = 96;
pub const maximum_name_length: usize = 31;
pub const maximum_path_length: usize = 255;
pub const maximum_file_size: usize = 16 * 1024;
pub const maximum_mounts: usize = 8;
pub const maximum_open_files: usize = 64;
pub const maximum_directory_entries: usize = 64;
pub const invalid_node: u16 = 0xFFFF;

pub const Kind = enum(u8) {
    file,
    directory,
    pseudo,
};

pub const MountKind = enum(u8) {
    ramfs,
    boot_fat,
    procfs,
    devfs,
    netfs,
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
};

pub const Stat = struct {
    node: u16,
    generation: u16,
    kind: Kind,
    size: usize,
    mode: u16,
    readonly: bool,
    mount_id: u8,
    modified_tick: u64,
};

pub const DirectoryRecord = struct {
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
    parent: u16 = invalid_node,
    name: [maximum_name_length + 1]u8 = @splat(0),
    name_length: u8 = 0,
    size: usize = 0,
    data: [maximum_file_size]u8 = @splat(0),
    mode: u16 = 0o644,
    readonly: bool = false,
    mount_id: u8 = 0,
    modified_tick: u64 = 0,

    fn nameSlice(self: *const Node) []const u8 {
        return self.name[0..self.name_length];
    }
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
    files: usize,
    directories: usize,
    pseudo_files: usize,
    mounts: usize,
    open_files: usize,
    bytes_used: usize,
    mutations: u64,
    rejected_operations: u64,
};

pub const Vfs = struct {
    nodes: [maximum_nodes]Node = @splat(.{}),
    mounts: [maximum_mounts]Mount = @splat(.{}),
    open_files: [maximum_open_files]OpenFile = @splat(.{}),
    mutations: u64 = 0,
    rejected_operations: u64 = 0,

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
            .parent = 0,
            .name = @splat(0),
            .name_length = 0,
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

    pub fn resolve(self: *const Vfs, cwd: u16, path: []const u8) Error!u16 {
        if (path.len == 0) return self.validateDirectory(cwd);
        if (path.len > maximum_path_length) return Error.PathTooLong;
        var current: u16 = if (path[0] == '/') 0 else try self.validateDirectory(cwd);
        var iterator = std.mem.splitScalar(u8, path, '/');
        while (iterator.next()) |component| {
            if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
            if (component.len > maximum_name_length) return Error.NameTooLong;
            if (std.mem.eql(u8, component, "..")) {
                current = self.nodes[current].parent;
                continue;
            }
            if (self.nodes[current].kind != .directory) return Error.NotDirectory;
            current = self.findChild(current, component) orelse return Error.NotFound;
        }
        return current;
    }

    pub fn stat(self: *const Vfs, cwd: u16, path: []const u8) Error!Stat {
        return self.statNode(try self.resolve(cwd, path));
    }

    pub fn statNode(self: *const Vfs, node_index: u16) Error!Stat {
        if (node_index >= self.nodes.len or !self.nodes[node_index].used) return Error.NotFound;
        const node = self.nodes[node_index];
        return .{
            .node = node_index,
            .generation = node.generation,
            .kind = node.kind,
            .size = node.size,
            .mode = node.mode,
            .readonly = node.readonly or self.mountReadonly(node.mount_id),
            .mount_id = node.mount_id,
            .modified_tick = node.modified_tick,
        };
    }

    pub fn list(self: *const Vfs, cwd: u16, path: []const u8) Error!DirectoryList {
        const directory = try self.resolve(cwd, path);
        if (self.nodes[directory].kind != .directory) return Error.NotDirectory;
        var result = DirectoryList{};
        for (self.nodes, 0..) |node, index| {
            if (!node.used or index == directory or node.parent != directory) continue;
            if (result.count >= result.records.len) return Error.NoSpace;
            var record = DirectoryRecord{
                .kind = node.kind,
                .size = node.size,
                .readonly = node.readonly or self.mountReadonly(node.mount_id),
            };
            record.name_length = node.name_length;
            @memcpy(record.name[0..node.name_length], node.nameSlice());
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

    pub fn createPseudo(self: *Vfs, cwd: u16, path: []const u8, mode: u16, tick: u64) Error!u16 {
        const parent_name = try self.parentAndName(cwd, path);
        return self.createNode(parent_name.parent, parent_name.name, .pseudo, mode, true, tick);
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

    pub fn read(self: *const Vfs, cwd: u16, path: []const u8, offset: usize, output: []u8) Error!usize {
        const node_index = try self.resolve(cwd, path);
        const node = self.nodes[node_index];
        if (node.kind == .directory) return Error.IsDirectory;
        if ((node.mode & 0o444) == 0) return Error.PermissionDenied;
        if (offset > node.size) return Error.InvalidOffset;
        const count = @min(output.len, node.size - offset);
        @memcpy(output[0..count], node.data[offset .. offset + count]);
        return count;
    }

    pub fn write(self: *Vfs, cwd: u16, path: []const u8, offset: usize, bytes: []const u8, truncate_first: bool, tick: u64) Error!usize {
        const node_index = try self.resolve(cwd, path);
        return self.writeNode(node_index, offset, bytes, truncate_first, tick);
    }

    pub fn append(self: *Vfs, cwd: u16, path: []const u8, bytes: []const u8, tick: u64) Error!usize {
        const node_index = try self.resolve(cwd, path);
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
        const node_index = try self.resolve(cwd, path);
        if (self.nodes[node_index].kind == .directory) return Error.IsDirectory;
        try self.removeNode(node_index);
    }

    pub fn rmdir(self: *Vfs, cwd: u16, path: []const u8) Error!void {
        const node_index = try self.resolve(cwd, path);
        if (node_index == 0 or self.nodes[node_index].kind != .directory) return Error.NotDirectory;
        for (self.nodes, 0..) |node, index| {
            if (node.used and index != node_index and node.parent == node_index) return Error.DirectoryNotEmpty;
        }
        try self.removeNode(node_index);
    }

    pub fn rename(self: *Vfs, cwd: u16, old_path: []const u8, new_path: []const u8, tick: u64) Error!void {
        const source = try self.resolve(cwd, old_path);
        if (source == 0) return Error.Busy;
        const destination = try self.parentAndName(cwd, new_path);
        if (self.findChild(destination.parent, destination.name) != null) return Error.AlreadyExists;
        if (self.nodes[source].mount_id != self.nodes[destination.parent].mount_id) return Error.CrossMount;
        if (self.nodes[source].readonly or self.mountReadonly(self.nodes[source].mount_id)) return Error.ReadOnly;
        if (self.nodes[source].kind == .directory and self.isDescendant(destination.parent, source)) return Error.Cycle;
        self.nodes[source].parent = destination.parent;
        self.nodes[source].name = @splat(0);
        self.nodes[source].name_length = @intCast(destination.name.len);
        @memcpy(self.nodes[source].name[0..destination.name.len], destination.name);
        self.nodes[source].modified_tick = tick;
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
        if (node_index >= self.nodes.len or !self.nodes[node_index].used) return Error.NotFound;
        if (node_index == 0) {
            output[0] = '/';
            return output[0..1];
        }
        var chain: [maximum_nodes]u16 = undefined;
        var count: usize = 0;
        var current = node_index;
        while (current != 0) {
            if (count >= chain.len) return Error.Cycle;
            chain[count] = current;
            count += 1;
            current = self.nodes[current].parent;
        }
        var used: usize = 0;
        var index = count;
        while (index != 0) {
            index -= 1;
            const name = self.nodes[chain[index]].nameSlice();
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
        const parent_mount = self.nodes[self.nodes[node_index].parent].mount_id;
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
        if (self.nodes[node_index].kind == .directory) return Error.IsDirectory;
        if (flags.read and (self.nodes[node_index].mode & 0o444) == 0) return Error.PermissionDenied;
        if (flags.write) try self.requireWritableFile(node_index);
        if (flags.truncate and flags.write) try self.truncate(cwd, path, 0, tick);
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
        const generation = self.open_files[index].generation;
        self.open_files[index] = .{ .generation = generation };
    }

    pub fn closeAll(self: *Vfs, owner_pid: u32) usize {
        var count: usize = 0;
        for (&self.open_files) |*open_file| {
            if (!open_file.used or open_file.owner_pid != owner_pid) continue;
            const generation = open_file.generation;
            open_file.* = .{ .generation = generation };
            count += 1;
        }
        return count;
    }

    pub fn readOpen(self: *Vfs, owner_pid: u32, handle: u32, output: []u8) Error!usize {
        const index = try self.resolveOpen(owner_pid, handle);
        var open_file = &self.open_files[index];
        if (!open_file.readable) return Error.PermissionDenied;
        const node = self.nodes[open_file.node];
        if (open_file.offset > node.size) return Error.InvalidOffset;
        const count = @min(output.len, node.size - open_file.offset);
        @memcpy(output[0..count], node.data[open_file.offset .. open_file.offset + count]);
        open_file.offset += count;
        return count;
    }

    pub fn writeOpen(self: *Vfs, owner_pid: u32, handle: u32, bytes: []const u8, tick: u64) Error!usize {
        const index = try self.resolveOpen(owner_pid, handle);
        var open_file = &self.open_files[index];
        if (!open_file.writable) return Error.PermissionDenied;
        if (open_file.append) open_file.offset = self.nodes[open_file.node].size;
        const written = try self.writeNode(open_file.node, open_file.offset, bytes, false, tick);
        open_file.offset += written;
        return written;
    }

    pub fn seek(self: *Vfs, owner_pid: u32, handle: u32, offset: i64, whence: enum { start, current, end }) Error!usize {
        const index = try self.resolveOpen(owner_pid, handle);
        var open_file = &self.open_files[index];
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
        if (!self.nodes[0].used or self.nodes[0].kind != .directory or self.nodes[0].parent != 0) return false;
        for (self.nodes, 0..) |node, index| {
            if (!node.used) continue;
            if (node.generation == 0 or node.name_length > maximum_name_length or node.size > maximum_file_size) return false;
            if (index != 0) {
                if (node.parent >= self.nodes.len or !self.nodes[node.parent].used or self.nodes[node.parent].kind != .directory) return false;
                var current: u16 = @intCast(index);
                var depth: usize = 0;
                while (current != 0 and depth < self.nodes.len) : (depth += 1) current = self.nodes[current].parent;
                if (current != 0) return false;
            }
            for (self.nodes[index + 1 ..]) |other| {
                if (!other.used or other.parent != node.parent or other.name_length != node.name_length) continue;
                if (std.ascii.eqlIgnoreCase(other.nameSlice(), node.nameSlice())) return false;
            }
        }
        for (self.mounts, 0..) |mount_entry, index| {
            if (!mount_entry.used) continue;
            if (mount_entry.id != index + 1 or mount_entry.node >= self.nodes.len or !self.nodes[mount_entry.node].used) return false;
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
            .files = 0,
            .directories = 0,
            .pseudo_files = 0,
            .mounts = 0,
            .open_files = 0,
            .bytes_used = 0,
            .mutations = self.mutations,
            .rejected_operations = self.rejected_operations,
        };
        for (self.nodes) |node| {
            if (!node.used) continue;
            result.nodes_used += 1;
            result.bytes_used += node.size;
            switch (node.kind) {
                .file => result.files += 1,
                .directory => result.directories += 1,
                .pseudo => result.pseudo_files += 1,
            }
        }
        for (self.mounts) |mount_entry| result.mounts += @intFromBool(mount_entry.used);
        for (self.open_files) |open_file| result.open_files += @intFromBool(open_file.used);
        return result;
    }

    fn validateDirectory(self: *const Vfs, node_index: u16) Error!u16 {
        if (node_index >= self.nodes.len or !self.nodes[node_index].used) return Error.NotFound;
        if (self.nodes[node_index].kind != .directory) return Error.NotDirectory;
        return node_index;
    }

    fn findChild(self: *const Vfs, parent: u16, name: []const u8) ?u16 {
        for (self.nodes, 0..) |node, index| {
            if (!node.used or node.parent != parent or node.name_length != name.len) continue;
            if (std.ascii.eqlIgnoreCase(node.nameSlice(), name)) return @intCast(index);
        }
        return null;
    }

    const ParentName = struct {
        parent: u16,
        name: []const u8,
    };

    fn parentAndName(self: *const Vfs, cwd: u16, path: []const u8) Error!ParentName {
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
        if (self.findChild(parent, name) != null) return Error.AlreadyExists;
        if (self.nodes[parent].readonly or self.mountReadonly(self.nodes[parent].mount_id)) return Error.ReadOnly;
        var index: usize = 1;
        while (index < self.nodes.len and self.nodes[index].used) : (index += 1) {}
        if (index >= self.nodes.len) return Error.NoSpace;
        const generation = nextGeneration(self.nodes[index].generation);
        self.nodes[index] = .{
            .used = true,
            .generation = generation,
            .kind = kind,
            .parent = parent,
            .name_length = @intCast(name.len),
            .mode = mode & 0o777,
            .readonly = readonly,
            .mount_id = self.nodes[parent].mount_id,
            .modified_tick = tick,
        };
        @memcpy(self.nodes[index].name[0..name.len], name);
        self.mutations +%= 1;
        return @intCast(index);
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
        const node = self.nodes[node_index];
        if (node.kind == .directory) return Error.IsDirectory;
        if (node.kind == .pseudo or node.readonly or self.mountReadonly(node.mount_id)) return Error.ReadOnly;
        if ((node.mode & 0o222) == 0) return Error.PermissionDenied;
    }

    fn removeNode(self: *Vfs, node_index: u16) Error!void {
        if (node_index == 0 or node_index >= self.nodes.len or !self.nodes[node_index].used) return Error.NotFound;
        if (self.nodes[node_index].readonly or self.mountReadonly(self.nodes[node_index].mount_id)) return Error.ReadOnly;
        for (self.open_files) |open_file| if (open_file.used and open_file.node == node_index) return Error.Busy;
        const generation = self.nodes[node_index].generation;
        self.nodes[node_index] = .{ .generation = generation };
        self.mutations +%= 1;
    }

    fn mountReadonly(self: *const Vfs, mount_id: u8) bool {
        if (mount_id == 0) return false;
        const index: usize = mount_id - 1;
        return index < self.mounts.len and self.mounts[index].used and self.mounts[index].readonly;
    }

    fn assignMountRecursive(self: *Vfs, node_index: u16, mount_id: u8, readonly: bool) void {
        self.nodes[node_index].mount_id = mount_id;
        if (readonly) self.nodes[node_index].readonly = true;
        for (self.nodes, 0..) |node, index| {
            if (node.used and index != node_index and node.parent == node_index) self.assignMountRecursive(@intCast(index), mount_id, readonly);
        }
    }

    fn isDescendant(self: *const Vfs, candidate: u16, ancestor: u16) bool {
        var current = candidate;
        var traversed: usize = 0;
        while (traversed < self.nodes.len) : (traversed += 1) {
            if (current == ancestor) return true;
            if (current == 0) return false;
            current = self.nodes[current].parent;
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

test "VFS mount policy protects read only trees" {
    var fs = Vfs.init();
    const boot = try fs.mkdir(0, "/boot", 0o755, 1);
    _ = try fs.putFile(boot, "kernel.efi", "image", 0o444, false, 2);
    const mount_id = try fs.mount(0, "/boot", .boot_fat, true, "nvme0p1");
    try std.testing.expectEqual(@as(u8, 2), mount_id);
    try std.testing.expectError(Error.ReadOnly, fs.write(0, "/boot/kernel.efi", 0, "x", false, 3));
    try std.testing.expectError(Error.ReadOnly, fs.create(boot, "new", 0o644, 3));
}
