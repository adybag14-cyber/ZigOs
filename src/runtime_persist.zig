const std = @import("std");
const gpt = @import("gpt.zig");
const runtime_vfs = @import("runtime_vfs.zig");

pub const maximum_payload_bytes: usize = 64 * 1024;
const magic = "ZIGPERS1".*;
const version: u32 = 1;
const header_size: u32 = 48;
const commit_marker: u32 = 0x434F_4D54;
const persist_root = "/persist";
const persist_prefix = "/persist/";

pub const Error = error{
    NotConfigured,
    InvalidGeometry,
    Io,
    Corrupt,
    NoSpace,
    InvalidRecord,
};

pub const ReadFn = *const fn (context: ?*anyopaque, lba: u64, output: []u8) bool;
pub const WriteFn = *const fn (context: ?*anyopaque, lba: u64, input: []const u8, force_unit_access: bool) bool;
pub const FlushFn = *const fn (context: ?*anyopaque) bool;

pub const BlockDevice = struct {
    context: ?*anyopaque,
    block_size: u32,
    first_lba: u64,
    sector_count: u64,
    read_fn: ReadFn,
    write_fn: WriteFn,
    flush_fn: FlushFn,

    fn read(self: BlockDevice, relative_lba: u64, output: []u8) bool {
        if (relative_lba >= self.sector_count or output.len != self.block_size) return false;
        return self.read_fn(self.context, self.first_lba + relative_lba, output);
    }

    fn write(self: BlockDevice, relative_lba: u64, input: []const u8, force_unit_access: bool) bool {
        if (relative_lba >= self.sector_count or input.len != self.block_size) return false;
        return self.write_fn(self.context, self.first_lba + relative_lba, input, force_unit_access);
    }

    fn flush(self: BlockDevice) bool {
        return self.flush_fn(self.context);
    }
};

const Candidate = struct {
    slot: u8,
    generation: u64,
    payload_length: u32,
    payload_crc32: u32,
    record_count: u32,
};

const HeaderState = union(enum) {
    absent,
    invalid,
    valid: Candidate,
};

pub const Report = struct {
    mounted: bool,
    generation: u64,
    active_slot: u8,
    record_count: u32,
    payload_bytes: u32,
    mounts: u64,
    syncs: u64,
    checks: u64,
    recoveries: u64,
    payload_writes: u64,
    header_writes: u64,
    flushes: u64,
    io_failures: u64,
    corrupt_headers: u64,
};

pub const Store = struct {
    device: ?BlockDevice = null,
    mounted: bool = false,
    generation: u64 = 0,
    active_slot: u8 = 1,
    record_count: u32 = 0,
    payload_length: u32 = 0,
    payload: [maximum_payload_bytes]u8 = @splat(0),
    sector: [4096]u8 = @splat(0),
    path_queue: [runtime_vfs.maximum_nodes][runtime_vfs.maximum_path_length + 1]u8 = @splat(@splat(0)),
    path_lengths: [runtime_vfs.maximum_nodes]u16 = @splat(0),
    path_scratch: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0),
    mounts: u64 = 0,
    syncs: u64 = 0,
    checks: u64 = 0,
    recoveries: u64 = 0,
    payload_writes: u64 = 0,
    header_writes: u64 = 0,
    flushes: u64 = 0,
    io_failures: u64 = 0,
    corrupt_headers: u64 = 0,

    pub fn initialize(self: *Store) void {
        self.* = .{};
    }

    pub fn mount(self: *Store, vfs: *runtime_vfs.Vfs, device: BlockDevice, tick: u64) Error!void {
        self.initialize();
        try validateGeometry(device);
        self.device = device;
        _ = vfs.ensureDirectory(0, persist_root, 0o755, tick) catch return Error.InvalidRecord;
        _ = vfs.mount(0, persist_root, .zigos_persist, false, "nvme-zigos-data") catch return Error.InvalidRecord;

        const first = try self.readHeader(0);
        const second = try self.readHeader(1);
        const first_valid = try self.validCandidate(first);
        const second_valid = try self.validCandidate(second);
        const selected: ?Candidate = if (first_valid != null and second_valid != null)
            if (second_valid.?.generation > first_valid.?.generation) second_valid else first_valid
        else if (first_valid != null)
            first_valid
        else
            second_valid;

        if (selected) |candidate| {
            try self.loadPayload(candidate);
            try self.restore(vfs, candidate, tick);
            self.generation = candidate.generation;
            self.active_slot = candidate.slot;
            self.record_count = candidate.record_count;
            self.payload_length = candidate.payload_length;
            if ((first == .invalid or second == .invalid) or
                (first_valid != null and second_valid != null and first_valid.?.generation != second_valid.?.generation))
            {
                self.recoveries +%= 1;
            }
        } else if (first != .absent or second != .absent) {
            return Error.Corrupt;
        }
        self.mounted = true;
        self.mounts +%= 1;
    }

    pub fn sync(self: *Store, vfs: *const runtime_vfs.Vfs) Error!void {
        const device = self.device orelse return Error.NotConfigured;
        if (!self.mounted) return Error.NotConfigured;
        const snapshot = try self.serialize(vfs);
        const slot: u8 = if (self.active_slot == 0) 1 else 0;
        const block_size: usize = device.block_size;
        const sectors: u64 = @intCast((snapshot.payload_length + block_size - 1) / block_size);
        var remaining: usize = snapshot.payload_length;
        var offset: usize = 0;
        var sector_index: u64 = 0;
        while (sector_index < sectors) : (sector_index += 1) {
            @memset(self.sector[0..block_size], 0);
            const count = @min(remaining, block_size);
            if (count != 0) @memcpy(self.sector[0..count], self.payload[offset .. offset + count]);
            if (!device.write(slotPayloadStart(device.block_size, slot) + sector_index, self.sector[0..block_size], false)) {
                self.io_failures +%= 1;
                return Error.Io;
            }
            self.payload_writes +%= 1;
            remaining -= count;
            offset += count;
        }
        if (!device.flush()) {
            self.io_failures +%= 1;
            return Error.Io;
        }
        self.flushes +%= 1;

        const generation = self.generation +% 1;
        if (generation == 0) return Error.NoSpace;
        self.encodeHeader(.{
            .slot = slot,
            .generation = generation,
            .payload_length = @intCast(snapshot.payload_length),
            .payload_crc32 = gpt.crc32(self.payload[0..snapshot.payload_length]),
            .record_count = snapshot.record_count,
        });
        if (!device.write(slot, self.sector[0..block_size], true)) {
            self.io_failures +%= 1;
            return Error.Io;
        }
        self.header_writes +%= 1;
        if (!device.flush()) {
            self.io_failures +%= 1;
            return Error.Io;
        }
        self.flushes +%= 1;
        self.generation = generation;
        self.active_slot = slot;
        self.record_count = snapshot.record_count;
        self.payload_length = @intCast(snapshot.payload_length);
        self.syncs +%= 1;
    }

    pub fn check(self: *Store) Error!void {
        if (!self.mounted) return Error.NotConfigured;
        if (self.generation == 0) {
            const first = try self.readHeader(0);
            const second = try self.readHeader(1);
            if (first != .absent or second != .absent) return Error.Corrupt;
            self.checks +%= 1;
            return;
        }
        const state = try self.readHeader(self.active_slot);
        const candidate = switch (state) {
            .valid => |value| value,
            else => return Error.Corrupt,
        };
        if (candidate.generation != self.generation or !(try self.validatePayload(candidate))) return Error.Corrupt;
        self.checks +%= 1;
    }

    pub fn report(self: *const Store) Report {
        return .{
            .mounted = self.mounted,
            .generation = self.generation,
            .active_slot = self.active_slot,
            .record_count = self.record_count,
            .payload_bytes = self.payload_length,
            .mounts = self.mounts,
            .syncs = self.syncs,
            .checks = self.checks,
            .recoveries = self.recoveries,
            .payload_writes = self.payload_writes,
            .header_writes = self.header_writes,
            .flushes = self.flushes,
            .io_failures = self.io_failures,
            .corrupt_headers = self.corrupt_headers,
        };
    }

    const Snapshot = struct {
        payload_length: usize,
        record_count: u32,
    };

    fn serialize(self: *Store, vfs: *const runtime_vfs.Vfs) Error!Snapshot {
        @memset(&self.payload, 0);
        @memset(&self.path_queue, @splat(0));
        @memset(&self.path_lengths, 0);
        write32(&self.payload, 0, 0);
        var used: usize = 4;
        var records: u32 = 0;
        @memcpy(self.path_queue[0][0..persist_root.len], persist_root);
        self.path_lengths[0] = persist_root.len;
        var head: usize = 0;
        var tail: usize = 1;
        while (head < tail) : (head += 1) {
            const parent = self.path_queue[head][0..self.path_lengths[head]];
            const list = vfs.list(0, parent) catch return Error.InvalidRecord;
            // Directories first so restore always sees parents before children.
            for (list.records[0..list.count]) |record| {
                if (record.kind != .directory) continue;
                const child = try self.buildChildPath(parent, record.nameSlice());
                const stat = vfs.stat(0, child) catch return Error.InvalidRecord;
                used = try appendRecord(&self.payload, used, child[persist_prefix.len..], .directory, stat.mode, &.{});
                records +%= 1;
                if (tail >= self.path_queue.len) return Error.NoSpace;
                @memcpy(self.path_queue[tail][0..child.len], child);
                self.path_lengths[tail] = @intCast(child.len);
                tail += 1;
            }
            for (list.records[0..list.count]) |record| {
                if (record.kind == .directory or record.kind == .pseudo) continue;
                const child = try self.buildChildPath(parent, record.nameSlice());
                const stat = vfs.statNode(record.node) catch return Error.InvalidRecord;
                const data = switch (record.kind) {
                    .file => vfs.readOnlyView(0, child) catch return Error.InvalidRecord,
                    .symlink => vfs.symlinkTargetNode(record.node) catch return Error.InvalidRecord,
                    .directory, .pseudo => unreachable,
                };
                used = try appendRecord(&self.payload, used, child[persist_prefix.len..], record.kind, stat.mode, data);
                records +%= 1;
            }
        }
        write32(&self.payload, 0, records);
        return .{ .payload_length = used, .record_count = records };
    }

    fn buildChildPath(self: *Store, parent: []const u8, name: []const u8) Error![]const u8 {
        const output = &self.path_scratch;
        const required = parent.len + 1 + name.len;
        if (required > runtime_vfs.maximum_path_length) return Error.NoSpace;
        @memset(output, 0);
        @memcpy(output[0..parent.len], parent);
        output[parent.len] = '/';
        @memcpy(output[parent.len + 1 .. required], name);
        return output[0..required];
    }

    fn restore(self: *Store, vfs: *runtime_vfs.Vfs, candidate: Candidate, tick: u64) Error!void {
        if (candidate.payload_length < 4) return Error.Corrupt;
        const count = read32(&self.payload, 0);
        if (count != candidate.record_count) return Error.Corrupt;
        var offset: usize = 4;
        var record_index: u32 = 0;
        while (record_index < count) : (record_index += 1) {
            if (offset + 8 > candidate.payload_length) return Error.Corrupt;
            const kind: runtime_vfs.Kind = switch (self.payload[offset]) {
                1 => .directory,
                2 => .file,
                3 => .symlink,
                else => return Error.Corrupt,
            };
            const path_length: usize = self.payload[offset + 1];
            const mode = read16(&self.payload, offset + 2);
            const data_length: usize = read32(&self.payload, offset + 4);
            offset += 8;
            if (path_length == 0 or offset + path_length > candidate.payload_length) return Error.Corrupt;
            const relative = self.payload[offset .. offset + path_length];
            offset += path_length;
            if (!validRelativePath(relative)) return Error.Corrupt;
            if (offset + data_length > candidate.payload_length) return Error.Corrupt;
            const path = try self.absolutePath(relative);
            switch (kind) {
                .directory => {
                    if (data_length != 0) return Error.Corrupt;
                    _ = vfs.ensureDirectory(0, path, mode, tick) catch return Error.InvalidRecord;
                },
                .file => {
                    if (data_length > runtime_vfs.maximum_file_size) return Error.Corrupt;
                    _ = vfs.putFile(0, path, self.payload[offset .. offset + data_length], mode, false, tick) catch return Error.InvalidRecord;
                },
                .symlink => {
                    if (data_length == 0 or data_length > runtime_vfs.maximum_symlink_target_length) return Error.Corrupt;
                    _ = vfs.symlink(0, self.payload[offset .. offset + data_length], path, tick) catch return Error.InvalidRecord;
                },
                .pseudo => return Error.Corrupt,
            }
            offset += data_length;
        }
        if (offset != candidate.payload_length) return Error.Corrupt;
    }

    fn absolutePath(self: *Store, relative: []const u8) Error![]const u8 {
        const output = &self.path_scratch;
        const required = persist_prefix.len + relative.len;
        if (required > runtime_vfs.maximum_path_length) return Error.NoSpace;
        @memset(output, 0);
        @memcpy(output[0..persist_prefix.len], persist_prefix);
        @memcpy(output[persist_prefix.len..required], relative);
        return output[0..required];
    }

    fn readHeader(self: *Store, slot: u8) Error!HeaderState {
        const device = self.device orelse return Error.NotConfigured;
        const block_size: usize = device.block_size;
        @memset(self.sector[0..block_size], 0);
        if (!device.read(slot, self.sector[0..block_size])) {
            self.io_failures +%= 1;
            return Error.Io;
        }
        if (allZero(self.sector[0..block_size])) return .absent;
        if (!std.mem.eql(u8, self.sector[0..magic.len], &magic) or
            read32(&self.sector, 8) != version or read32(&self.sector, 12) != header_size or
            read32(&self.sector, 44) != commit_marker)
        {
            self.corrupt_headers +%= 1;
            return .invalid;
        }
        const stored_crc = read32(&self.sector, 40);
        write32(&self.sector, 40, 0);
        const calculated_crc = gpt.crc32(self.sector[0..header_size]);
        write32(&self.sector, 40, stored_crc);
        const payload_length = read32(&self.sector, 24);
        const encoded_slot = read32(&self.sector, 32);
        if (stored_crc != calculated_crc or encoded_slot != slot or payload_length < 4 or payload_length > self.payload.len) {
            self.corrupt_headers +%= 1;
            return .invalid;
        }
        return .{ .valid = .{
            .slot = slot,
            .generation = read64(&self.sector, 16),
            .payload_length = payload_length,
            .payload_crc32 = read32(&self.sector, 28),
            .record_count = read32(&self.sector, 36),
        } };
    }

    fn validCandidate(self: *Store, state: HeaderState) Error!?Candidate {
        return switch (state) {
            .valid => |candidate| if (try self.validatePayload(candidate)) candidate else null,
            else => null,
        };
    }

    fn validatePayload(self: *Store, candidate: Candidate) Error!bool {
        const device = self.device orelse return Error.NotConfigured;
        const block_size: usize = device.block_size;
        var crc_state = gpt.crc32Begin();
        var remaining: usize = candidate.payload_length;
        var sector_index: u64 = 0;
        while (remaining != 0) : (sector_index += 1) {
            if (sector_index >= payloadSectorCount(device.block_size)) return false;
            if (!device.read(slotPayloadStart(device.block_size, candidate.slot) + sector_index, self.sector[0..block_size])) {
                self.io_failures +%= 1;
                return Error.Io;
            }
            const count = @min(remaining, block_size);
            crc_state = gpt.crc32Update(crc_state, self.sector[0..count]);
            remaining -= count;
        }
        return gpt.crc32Finish(crc_state) == candidate.payload_crc32;
    }

    fn loadPayload(self: *Store, candidate: Candidate) Error!void {
        const device = self.device orelse return Error.NotConfigured;
        const block_size: usize = device.block_size;
        @memset(&self.payload, 0);
        var remaining: usize = candidate.payload_length;
        var offset: usize = 0;
        var sector_index: u64 = 0;
        while (remaining != 0) : (sector_index += 1) {
            if (!device.read(slotPayloadStart(device.block_size, candidate.slot) + sector_index, self.sector[0..block_size])) {
                self.io_failures +%= 1;
                return Error.Io;
            }
            const count = @min(remaining, block_size);
            @memcpy(self.payload[offset .. offset + count], self.sector[0..count]);
            remaining -= count;
            offset += count;
        }
    }

    fn encodeHeader(self: *Store, candidate: Candidate) void {
        const device = self.device.?;
        const block_size: usize = device.block_size;
        @memset(self.sector[0..block_size], 0);
        @memcpy(self.sector[0..magic.len], &magic);
        write32(&self.sector, 8, version);
        write32(&self.sector, 12, header_size);
        write64(&self.sector, 16, candidate.generation);
        write32(&self.sector, 24, candidate.payload_length);
        write32(&self.sector, 28, candidate.payload_crc32);
        write32(&self.sector, 32, candidate.slot);
        write32(&self.sector, 36, candidate.record_count);
        write32(&self.sector, 40, 0);
        write32(&self.sector, 44, commit_marker);
        write32(&self.sector, 40, gpt.crc32(self.sector[0..header_size]));
    }
};

fn validRelativePath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn appendRecord(
    payload: []u8,
    initial_offset: usize,
    relative_path: []const u8,
    kind: runtime_vfs.Kind,
    mode: u16,
    data: []const u8,
) Error!usize {
    if (relative_path.len == 0 or relative_path.len > 255 or data.len > runtime_vfs.maximum_file_size) return Error.InvalidRecord;
    const required = 8 + relative_path.len + data.len;
    if (initial_offset > payload.len or required > payload.len - initial_offset) return Error.NoSpace;
    const kind_byte: u8 = switch (kind) {
        .directory => 1,
        .file => 2,
        .symlink => 3,
        .pseudo => return Error.InvalidRecord,
    };
    payload[initial_offset] = kind_byte;
    payload[initial_offset + 1] = @intCast(relative_path.len);
    write16(payload, initial_offset + 2, mode);
    write32(payload, initial_offset + 4, @intCast(data.len));
    var offset = initial_offset + 8;
    @memcpy(payload[offset .. offset + relative_path.len], relative_path);
    offset += relative_path.len;
    @memcpy(payload[offset .. offset + data.len], data);
    return offset + data.len;
}

fn validateGeometry(device: BlockDevice) Error!void {
    if ((device.block_size != 512 and device.block_size != 4096) or device.first_lba == 0) return Error.InvalidGeometry;
    const required = 2 + 2 * payloadSectorCount(device.block_size);
    if (device.sector_count < required) return Error.InvalidGeometry;
}

fn payloadSectorCount(block_size: u32) u64 {
    return (maximum_payload_bytes + block_size - 1) / block_size;
}

fn slotPayloadStart(block_size: u32, slot: u8) u64 {
    return 2 + @as(u64, slot) * payloadSectorCount(block_size);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn read16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn read32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, read16(bytes, offset)) | (@as(u32, read16(bytes, offset + 2)) << 16);
}

fn read64(bytes: []const u8, offset: usize) u64 {
    return @as(u64, read32(bytes, offset)) | (@as(u64, read32(bytes, offset + 4)) << 32);
}

fn write16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}

fn write32(bytes: []u8, offset: usize, value: u32) void {
    write16(bytes, offset, @truncate(value));
    write16(bytes, offset + 2, @truncate(value >> 16));
}

fn write64(bytes: []u8, offset: usize, value: u64) void {
    write32(bytes, offset, @truncate(value));
    write32(bytes, offset + 4, @truncate(value >> 32));
}

test "relative path validation rejects traversal but permits dotted names" {
    try std.testing.expect(validRelativePath("config/foo..bar"));
    try std.testing.expect(validRelativePath(".config/value"));
    try std.testing.expect(!validRelativePath("../escape"));
    try std.testing.expect(!validRelativePath("config/../escape"));
    try std.testing.expect(!validRelativePath("config//value"));
    try std.testing.expect(!validRelativePath("/absolute"));
}

const TestDisk = struct {
    blocks: [300][512]u8 = @splat(@splat(0)),
    writes: u64 = 0,
    flushes: u64 = 0,

    fn read(context: ?*anyopaque, lba: u64, output: []u8) bool {
        const self: *TestDisk = @ptrCast(@alignCast(context.?));
        if (lba >= self.blocks.len or output.len != 512) return false;
        @memcpy(output, &self.blocks[lba]);
        return true;
    }

    fn write(context: ?*anyopaque, lba: u64, input: []const u8, force_unit_access: bool) bool {
        _ = force_unit_access;
        const self: *TestDisk = @ptrCast(@alignCast(context.?));
        if (lba >= self.blocks.len or input.len != 512) return false;
        @memcpy(&self.blocks[lba], input);
        self.writes += 1;
        return true;
    }

    fn flush(context: ?*anyopaque) bool {
        const self: *TestDisk = @ptrCast(@alignCast(context.?));
        self.flushes += 1;
        return true;
    }

    fn device(self: *TestDisk) BlockDevice {
        return .{
            .context = self,
            .block_size = 512,
            .first_lba = 1,
            .sector_count = self.blocks.len - 1,
            .read_fn = read,
            .write_fn = write,
            .flush_fn = flush,
        };
    }
};

test "alternating snapshots restore a persistent VFS subtree" {
    var disk: TestDisk = .{};
    const first_vfs = try std.testing.allocator.create(runtime_vfs.Vfs);
    defer std.testing.allocator.destroy(first_vfs);
    first_vfs.initialize();
    var first_store: Store = .{};
    try first_store.mount(first_vfs, disk.device(), 1);
    _ = try first_vfs.ensureDirectory(0, "/persist/config", 0o755, 2);
    _ = try first_vfs.putFile(0, "/persist/config/name.txt", "zigos\n", 0o640, false, 3);
    _ = try first_vfs.symlink(0, "config/name.txt", "/persist/name-link", 4);
    try first_store.sync(first_vfs);
    try std.testing.expectEqual(@as(u64, 1), first_store.report().generation);
    try first_store.check();

    const second_vfs = try std.testing.allocator.create(runtime_vfs.Vfs);
    defer std.testing.allocator.destroy(second_vfs);
    second_vfs.initialize();
    var second_store: Store = .{};
    try second_store.mount(second_vfs, disk.device(), 10);
    try std.testing.expectEqualStrings("zigos\n", try second_vfs.readOnlyView(0, "/persist/config/name.txt"));
    try std.testing.expectEqualStrings("zigos\n", try second_vfs.readOnlyView(0, "/persist/name-link"));
    var link_target: [runtime_vfs.maximum_path_length]u8 = undefined;
    const link_length = try second_vfs.readlink(0, "/persist/name-link", &link_target);
    try std.testing.expectEqualStrings("config/name.txt", link_target[0..link_length]);
    try std.testing.expectEqual(@as(u64, 1), second_store.report().generation);

    _ = try second_vfs.putFile(0, "/persist/config/name.txt", "second\n", 0o600, false, 11);
    try second_store.sync(second_vfs);
    try std.testing.expectEqual(@as(u64, 2), second_store.report().generation);
    try std.testing.expectEqual(@as(u8, 1), second_store.report().active_slot);
    try std.testing.expect(disk.flushes >= 4);
}

test "mount falls back to the previous valid generation" {
    var disk: TestDisk = .{};
    const vfs = try std.testing.allocator.create(runtime_vfs.Vfs);
    defer std.testing.allocator.destroy(vfs);
    vfs.initialize();
    var store: Store = .{};
    try store.mount(vfs, disk.device(), 1);
    _ = try vfs.putFile(0, "/persist/value", "one", 0o644, false, 2);
    try store.sync(vfs);
    _ = try vfs.putFile(0, "/persist/value", "two", 0o644, false, 3);
    try store.sync(vfs);

    // Corrupt the newest slot's committed header. Slot 1 contains generation 2.
    disk.blocks[1 + 1][0] ^= 0xFF;
    const recovered_vfs = try std.testing.allocator.create(runtime_vfs.Vfs);
    defer std.testing.allocator.destroy(recovered_vfs);
    recovered_vfs.initialize();
    var recovered: Store = .{};
    try recovered.mount(recovered_vfs, disk.device(), 4);
    try std.testing.expectEqualStrings("one", try recovered_vfs.readOnlyView(0, "/persist/value"));
    try std.testing.expectEqual(@as(u64, 1), recovered.report().generation);
    try std.testing.expectEqual(@as(u64, 1), recovered.report().recoveries);
}
