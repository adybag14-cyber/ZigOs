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
const maximum_record_data_bytes = runtime_vfs.maximum_file_size + 5;

pub const Error = error{
    NotConfigured,
    InvalidGeometry,
    Io,
    Corrupt,
    NoSpace,
    InvalidRecord,
    UnsupportedOperation,
    ReadOnly,
    Busy,
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

pub const RestorationFailure = struct {
    record_index: u32,
    record_kind: u8,
    vfs_error: runtime_vfs.Error,
};

pub const DamageReason = enum(u8) {
    none,
    payload_write,
    payload_flush,
    header_write,
    header_flush,
};

pub const WritebackOutcome = enum {
    idle,
    clean,
    immediate,
    durable,
    unsupported,
    failed,
    stale,
};

pub const WritebackRequest = struct {
    node: u16,
    generation: u16,
    pages: u8,
    persistent: bool,
};

pub const Report = struct {
    mounted: bool,
    damaged: bool,
    damage_reason: DamageReason,
    read_only_remounts: u64,
    read_only_remount_failures: u64,
    discarded_dirty_pages: u64,
    read_only_rejections: u64,
    generation: u64,
    active_slot: u8,
    record_count: u32,
    payload_bytes: u32,
    mount_id: u8,
    mounts: u64,
    syncs: u64,
    global_syncs: u64,
    writable_mount_syncs: u64,
    immediate_mount_syncs: u64,
    durable_mount_syncs: u64,
    rejected_sync_plans: u64,
    writeback_active: bool,
    writeback_requests: u64,
    writeback_completions: u64,
    writeback_passes: u64,
    writeback_immediate: u64,
    writeback_durable: u64,
    writeback_clean: u64,
    writeback_unsupported: u64,
    writeback_failures: u64,
    writeback_stale: u64,
    writeback_pages_queued: u64,
    writeback_pages_completed: u64,
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
    damaged: bool = false,
    damage_reason: DamageReason = .none,
    read_only_remounts: u64 = 0,
    read_only_remount_failures: u64 = 0,
    discarded_dirty_pages: u64 = 0,
    read_only_rejections: u64 = 0,
    mount_id: u8 = 0,
    generation: u64 = 0,
    active_slot: u8 = 1,
    record_count: u32 = 0,
    payload_length: u32 = 0,
    payload: [maximum_payload_bytes]u8 = @splat(0),
    next_payload: [maximum_payload_bytes]u8 = @splat(0),
    sector: [4096]u8 = @splat(0),
    path_queue: [runtime_vfs.maximum_nodes][runtime_vfs.maximum_path_length + 1]u8 = @splat(@splat(0)),
    path_lengths: [runtime_vfs.maximum_nodes]u16 = @splat(0),
    path_scratch: [runtime_vfs.maximum_path_length + 1]u8 = @splat(0),
    record_scratch: [maximum_record_data_bytes]u8 = @splat(0),
    mounts: u64 = 0,
    syncs: u64 = 0,
    global_syncs: u64 = 0,
    writable_mount_syncs: u64 = 0,
    immediate_mount_syncs: u64 = 0,
    durable_mount_syncs: u64 = 0,
    rejected_sync_plans: u64 = 0,
    writeback_active: bool = false,
    writeback_node: u16 = 0,
    writeback_generation: u16 = 0,
    writeback_pages: u8 = 0,
    writeback_persistent: bool = false,
    writeback_requests: u64 = 0,
    writeback_completions: u64 = 0,
    writeback_passes: u64 = 0,
    writeback_immediate: u64 = 0,
    writeback_durable: u64 = 0,
    writeback_clean: u64 = 0,
    writeback_unsupported: u64 = 0,
    writeback_failures: u64 = 0,
    writeback_stale: u64 = 0,
    writeback_pages_queued: u64 = 0,
    writeback_pages_completed: u64 = 0,
    checks: u64 = 0,
    recoveries: u64 = 0,
    payload_writes: u64 = 0,
    header_writes: u64 = 0,
    flushes: u64 = 0,
    io_failures: u64 = 0,
    corrupt_headers: u64 = 0,
    restoration_failure: ?RestorationFailure = null,

    pub fn initialize(self: *Store) void {
        self.* = .{};
    }

    pub fn mount(self: *Store, vfs: *runtime_vfs.Vfs, device: BlockDevice, tick: u64) Error!void {
        self.initialize();
        try validateGeometry(device);
        self.device = device;
        _ = vfs.ensureDirectory(0, persist_root, 0o755, tick) catch return Error.InvalidRecord;
        self.mount_id = vfs.mount(0, persist_root, .zigos_persist, false, "nvme-zigos-data") catch return Error.InvalidRecord;

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

    pub fn sync(self: *Store, vfs: *runtime_vfs.Vfs) Error!void {
        if (self.damaged) {
            _ = vfs.clearDirtyWritableMountPages();
            self.read_only_rejections +%= 1;
            return Error.ReadOnly;
        }
        const plan = self.planWritableMounts(vfs) catch |err| {
            self.rejected_sync_plans +%= 1;
            return err;
        };
        if (plan.durable_mount_id != 0) {
            const snapshot = try self.serialize(vfs, &self.next_payload);
            self.commitSnapshot(vfs, &self.next_payload, snapshot) catch |err| {
                if (self.damaged) _ = vfs.clearDirtyWritableMountPages();
                return err;
            };
        }
        _ = vfs.clearDirtyWritableMountPages();
        self.global_syncs +%= 1;
        self.writable_mount_syncs +%= plan.writable_mounts;
        self.immediate_mount_syncs +%= plan.immediate_mounts;
        if (plan.durable_mount_id != 0) self.durable_mount_syncs +%= 1;
    }

    pub fn syncFile(self: *Store, vfs: *runtime_vfs.Vfs, node_index: u16) Error!void {
        try self.syncFileRecord(vfs, node_index, true);
    }

    pub fn syncFileData(self: *Store, vfs: *runtime_vfs.Vfs, node_index: u16) Error!void {
        try self.syncFileRecord(vfs, node_index, false);
    }

    pub fn requestWriteback(self: *Store, vfs: *const runtime_vfs.Vfs, node_index: u16) Error!WritebackRequest {
        if (self.writeback_active) return Error.Busy;
        const stat = vfs.statNode(node_index) catch return Error.InvalidRecord;
        const persistent = vfs.persistentNode(node_index) catch return Error.InvalidRecord;
        if (persistent and self.damaged) {
            self.read_only_rejections +%= 1;
            return Error.ReadOnly;
        }
        if (stat.kind != .file or stat.link_count == 0 or stat.readonly) return Error.UnsupportedOperation;
        const pages = vfs.dirtyFilePageBitmap(node_index) catch return Error.InvalidRecord;
        if (pages == 0) return Error.UnsupportedOperation;
        self.writeback_active = true;
        self.writeback_node = node_index;
        self.writeback_generation = stat.generation;
        self.writeback_pages = pages;
        self.writeback_persistent = persistent;
        self.writeback_requests +%= 1;
        self.writeback_pages_queued +%= @popCount(pages);
        return .{
            .node = node_index,
            .generation = stat.generation,
            .pages = pages,
            .persistent = persistent,
        };
    }

    pub fn serviceWriteback(self: *Store, vfs: *runtime_vfs.Vfs) WritebackOutcome {
        if (!self.writeback_active) return .idle;
        self.writeback_active = false;
        self.writeback_passes +%= 1;
        const node_index = self.writeback_node;
        const generation = self.writeback_generation;
        const requested_pages: u64 = @popCount(self.writeback_pages);
        const requested_persistent = self.writeback_persistent;
        const stat = vfs.statNode(node_index) catch {
            self.writeback_stale +%= 1;
            return .stale;
        };
        if (stat.kind != .file or stat.generation != generation or stat.link_count == 0) {
            self.writeback_stale +%= 1;
            return .stale;
        }
        const pages = vfs.dirtyFilePageBitmap(node_index) catch {
            self.writeback_stale +%= 1;
            return .stale;
        };
        if (pages == 0) {
            self.writeback_clean +%= 1;
            self.writeback_completions +%= 1;
            self.writeback_pages_completed +%= requested_pages;
            return .clean;
        }
        const persistent = vfs.persistentNode(node_index) catch {
            self.writeback_stale +%= 1;
            return .stale;
        };
        if (persistent != requested_persistent) {
            self.writeback_stale +%= 1;
            return .stale;
        }
        if (!persistent) {
            _ = vfs.clearDirtyNodePages(node_index);
            self.writeback_immediate +%= 1;
            self.writeback_completions +%= 1;
            self.writeback_pages_completed +%= requested_pages;
            return .immediate;
        }
        self.syncFileData(vfs, node_index) catch |err| switch (err) {
            Error.UnsupportedOperation, Error.NotConfigured => {
                self.writeback_unsupported +%= 1;
                return .unsupported;
            },
            else => {
                self.writeback_failures +%= 1;
                return .failed;
            },
        };
        self.writeback_durable +%= 1;
        self.writeback_completions +%= 1;
        self.writeback_pages_completed +%= requested_pages;
        return .durable;
    }

    fn syncFileRecord(self: *Store, vfs: *runtime_vfs.Vfs, node_index: u16, include_metadata: bool) Error!void {
        if (self.damaged) {
            self.read_only_rejections +%= 1;
            return Error.ReadOnly;
        }
        if (self.device == null or !self.mounted) return Error.NotConfigured;
        if (!(vfs.persistentNode(node_index) catch return Error.InvalidRecord)) return Error.UnsupportedOperation;
        const stat = vfs.statNode(node_index) catch return Error.InvalidRecord;
        if (stat.kind != .file or stat.link_count == 0 or self.generation == 0 or self.payload_length < 4)
            return Error.UnsupportedOperation;

        var path_buffer: [runtime_vfs.maximum_path_length + 1]u8 = undefined;
        const canonical = vfs.canonicalPath(node_index, &path_buffer) catch return Error.UnsupportedOperation;
        if (!std.mem.startsWith(u8, canonical, persist_prefix) or canonical.len == persist_prefix.len)
            return Error.UnsupportedOperation;
        const relative = canonical[persist_prefix.len..];

        @memset(&self.next_payload, 0);
        write32(&self.next_payload, 0, 0);
        const committed_length: usize = self.payload_length;
        const committed_count = read32(&self.payload, 0);
        if (committed_count != self.record_count) return Error.Corrupt;
        var input_offset: usize = 4;
        var output_offset: usize = 4;
        var output_count: u32 = 0;
        var target_found = false;
        var committed_mode: ?u16 = null;
        var record_index: u32 = 0;
        while (record_index < committed_count) : (record_index += 1) {
            const record_start = input_offset;
            if (input_offset + 8 > committed_length) return Error.Corrupt;
            const kind: RecordKind = switch (self.payload[input_offset]) {
                1 => .directory,
                2 => .file,
                3 => .symlink,
                4 => .hard_link,
                5 => .sparse_file,
                else => return Error.Corrupt,
            };
            const path_length: usize = self.payload[input_offset + 1];
            const record_mode = read16(&self.payload, input_offset + 2);
            const data_length: usize = read32(&self.payload, input_offset + 4);
            input_offset += 8;
            if (path_length == 0 or input_offset + path_length > committed_length) return Error.Corrupt;
            const record_path = self.payload[input_offset .. input_offset + path_length];
            input_offset += path_length;
            if (!validRelativePath(record_path) or input_offset + data_length > committed_length) return Error.Corrupt;
            input_offset += data_length;
            if (std.mem.eql(u8, record_path, relative)) {
                if (target_found or (kind != .file and kind != .sparse_file)) return Error.UnsupportedOperation;
                target_found = true;
                committed_mode = record_mode;
                continue;
            }
            const record_length = input_offset - record_start;
            if (output_offset > self.next_payload.len or record_length > self.next_payload.len - output_offset)
                return Error.NoSpace;
            @memcpy(self.next_payload[output_offset .. output_offset + record_length], self.payload[record_start..input_offset]);
            output_offset += record_length;
            output_count +%= 1;
        }
        if (input_offset != committed_length) return Error.Corrupt;
        if (!target_found or committed_mode == null) return Error.UnsupportedOperation;
        const persisted_mode = if (include_metadata) stat.mode else committed_mode.?;

        const sparse = vfs.sparseFileInfoNode(node_index) catch return Error.InvalidRecord;
        self.record_scratch[0] = sparse.allocation_bitmap;
        write32(&self.record_scratch, 1, @intCast(sparse.size));
        var data_offset: usize = 5;
        var slot: usize = 0;
        while (slot < runtime_vfs.file_blocks_per_node) : (slot += 1) {
            if ((sparse.allocation_bitmap & (@as(u8, 1) << @intCast(slot))) == 0) continue;
            var block: [runtime_vfs.file_block_size]u8 = undefined;
            if (!(vfs.readAllocatedBlockNode(node_index, slot, &block) catch return Error.InvalidRecord))
                return Error.InvalidRecord;
            @memcpy(self.record_scratch[data_offset .. data_offset + block.len], &block);
            data_offset += block.len;
        }
        output_offset = try appendRecord(
            &self.next_payload,
            output_offset,
            relative,
            .sparse_file,
            persisted_mode,
            self.record_scratch[0..data_offset],
        );
        output_count +%= 1;
        write32(&self.next_payload, 0, output_count);
        try self.commitSnapshot(vfs, &self.next_payload, .{
            .payload_length = output_offset,
            .record_count = output_count,
        });
        _ = vfs.clearDirtyNodePages(node_index);
    }

    fn commitSnapshot(self: *Store, vfs: *runtime_vfs.Vfs, next_payload: *const [maximum_payload_bytes]u8, snapshot: Snapshot) Error!void {
        const device = self.device orelse return Error.NotConfigured;
        if (!self.mounted) return Error.NotConfigured;
        const slot: u8 = if (self.active_slot == 0) 1 else 0;
        const block_size: usize = device.block_size;
        const sectors: u64 = @intCast((snapshot.payload_length + block_size - 1) / block_size);
        var remaining: usize = snapshot.payload_length;
        var offset: usize = 0;
        var sector_index: u64 = 0;
        while (sector_index < sectors) : (sector_index += 1) {
            @memset(self.sector[0..block_size], 0);
            const count = @min(remaining, block_size);
            if (count != 0) @memcpy(self.sector[0..count], next_payload[offset .. offset + count]);
            if (!device.write(slotPayloadStart(device.block_size, slot) + sector_index, self.sector[0..block_size], false)) {
                self.recordIoDamage(vfs, .payload_write);
                return Error.Io;
            }
            self.payload_writes +%= 1;
            remaining -= count;
            offset += count;
        }
        if (!device.flush()) {
            self.recordIoDamage(vfs, .payload_flush);
            return Error.Io;
        }
        self.flushes +%= 1;

        const generation = self.generation +% 1;
        if (generation == 0) return Error.NoSpace;
        self.encodeHeader(.{
            .slot = slot,
            .generation = generation,
            .payload_length = @intCast(snapshot.payload_length),
            .payload_crc32 = gpt.crc32(next_payload[0..snapshot.payload_length]),
            .record_count = snapshot.record_count,
        });
        if (!device.write(slot, self.sector[0..block_size], true)) {
            self.recordIoDamage(vfs, .header_write);
            return Error.Io;
        }
        self.header_writes +%= 1;
        if (!device.flush()) {
            self.recordIoDamage(vfs, .header_flush);
            return Error.Io;
        }
        self.flushes +%= 1;
        @memset(&self.payload, 0);
        @memcpy(self.payload[0..snapshot.payload_length], next_payload[0..snapshot.payload_length]);
        self.generation = generation;
        self.active_slot = slot;
        self.record_count = snapshot.record_count;
        self.payload_length = @intCast(snapshot.payload_length);
        self.syncs +%= 1;
    }

    fn recordIoDamage(self: *Store, vfs: *runtime_vfs.Vfs, reason: DamageReason) void {
        self.io_failures +%= 1;
        if (self.damaged) return;
        self.damaged = true;
        self.damage_reason = reason;
        const discarded = vfs.remountReadOnly(self.mount_id) catch {
            self.read_only_remount_failures +%= 1;
            return;
        };
        self.read_only_remounts +%= 1;
        self.discarded_dirty_pages +%= discarded;
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

    pub fn restoreFailure(self: *const Store) ?RestorationFailure {
        return self.restoration_failure;
    }

    pub fn report(self: *const Store) Report {
        return .{
            .mounted = self.mounted,
            .damaged = self.damaged,
            .damage_reason = self.damage_reason,
            .read_only_remounts = self.read_only_remounts,
            .read_only_remount_failures = self.read_only_remount_failures,
            .discarded_dirty_pages = self.discarded_dirty_pages,
            .read_only_rejections = self.read_only_rejections,
            .generation = self.generation,
            .active_slot = self.active_slot,
            .record_count = self.record_count,
            .payload_bytes = self.payload_length,
            .mount_id = self.mount_id,
            .mounts = self.mounts,
            .syncs = self.syncs,
            .global_syncs = self.global_syncs,
            .writable_mount_syncs = self.writable_mount_syncs,
            .immediate_mount_syncs = self.immediate_mount_syncs,
            .durable_mount_syncs = self.durable_mount_syncs,
            .rejected_sync_plans = self.rejected_sync_plans,
            .writeback_active = self.writeback_active,
            .writeback_requests = self.writeback_requests,
            .writeback_completions = self.writeback_completions,
            .writeback_passes = self.writeback_passes,
            .writeback_immediate = self.writeback_immediate,
            .writeback_durable = self.writeback_durable,
            .writeback_clean = self.writeback_clean,
            .writeback_unsupported = self.writeback_unsupported,
            .writeback_failures = self.writeback_failures,
            .writeback_stale = self.writeback_stale,
            .writeback_pages_queued = self.writeback_pages_queued,
            .writeback_pages_completed = self.writeback_pages_completed,
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

    const WritableMountPlan = struct {
        writable_mounts: u64 = 0,
        immediate_mounts: u64 = 0,
        durable_mount_id: u8 = 0,
    };

    fn planWritableMounts(self: *const Store, vfs: *const runtime_vfs.Vfs) Error!WritableMountPlan {
        var plan: WritableMountPlan = .{};
        for (vfs.mountList()) |mount_entry| {
            if (!mount_entry.used or mount_entry.readonly) continue;
            plan.writable_mounts +%= 1;
            switch (mount_entry.kind) {
                .ramfs, .tmpfs => plan.immediate_mounts +%= 1,
                .zigos_persist => {
                    if (!self.mounted or self.mount_id == 0 or mount_entry.id != self.mount_id or plan.durable_mount_id != 0)
                        return Error.NotConfigured;
                    plan.durable_mount_id = mount_entry.id;
                },
                .boot_fat, .procfs, .devfs, .netfs => return Error.UnsupportedOperation,
            }
        }
        if (self.mounted and plan.durable_mount_id == 0) return Error.NotConfigured;
        return plan;
    }

    const RecordKind = enum(u8) {
        directory = 1,
        file = 2,
        symlink = 3,
        hard_link = 4,
        sparse_file = 5,
    };

    fn serialize(self: *Store, vfs: *runtime_vfs.Vfs, output: *[maximum_payload_bytes]u8) Error!Snapshot {
        @memset(output, 0);
        @memset(&self.path_queue, @splat(0));
        @memset(&self.path_lengths, 0);
        write32(output, 0, 0);
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
                used = try appendRecord(output, used, child[persist_prefix.len..], .directory, stat.mode, &.{});
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
                if (record.kind == .file and record.entry != (vfs.canonicalEntryNode(record.node) catch return Error.InvalidRecord)) {
                    var canonical_buffer: [runtime_vfs.maximum_path_length + 1]u8 = undefined;
                    const canonical = vfs.canonicalPath(record.node, &canonical_buffer) catch return Error.InvalidRecord;
                    if (!std.mem.startsWith(u8, canonical, persist_prefix)) return Error.InvalidRecord;
                    used = try appendRecord(output, used, child[persist_prefix.len..], .hard_link, stat.mode, canonical[persist_prefix.len..]);
                } else if (record.kind == .file) {
                    const sparse = vfs.sparseFileInfoNode(record.node) catch return Error.InvalidRecord;
                    self.record_scratch[0] = sparse.allocation_bitmap;
                    write32(&self.record_scratch, 1, @intCast(sparse.size));
                    var data_offset: usize = 5;
                    var slot: usize = 0;
                    while (slot < runtime_vfs.file_blocks_per_node) : (slot += 1) {
                        if ((sparse.allocation_bitmap & (@as(u8, 1) << @intCast(slot))) == 0) continue;
                        var block: [runtime_vfs.file_block_size]u8 = undefined;
                        if (!(vfs.readAllocatedBlockNode(record.node, slot, &block) catch return Error.InvalidRecord)) return Error.InvalidRecord;
                        @memcpy(self.record_scratch[data_offset .. data_offset + block.len], &block);
                        data_offset += block.len;
                    }
                    used = try appendRecord(output, used, child[persist_prefix.len..], .sparse_file, stat.mode, self.record_scratch[0..data_offset]);
                } else {
                    const data = vfs.symlinkTargetNode(record.node) catch return Error.InvalidRecord;
                    used = try appendRecord(output, used, child[persist_prefix.len..], .symlink, stat.mode, data);
                }
                records +%= 1;
            }
        }
        write32(output, 0, records);
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
        self.restoration_failure = null;
        if (candidate.payload_length < 4) return Error.Corrupt;
        const count = read32(&self.payload, 0);
        if (count != candidate.record_count) return Error.Corrupt;
        try self.restorePass(vfs, candidate, tick, false);
        try self.restorePass(vfs, candidate, tick, true);
    }

    fn restorePass(self: *Store, vfs: *runtime_vfs.Vfs, candidate: Candidate, tick: u64, hard_links_only: bool) Error!void {
        const count = read32(&self.payload, 0);
        var offset: usize = 4;
        var record_index: u32 = 0;
        while (record_index < count) : (record_index += 1) {
            if (offset + 8 > candidate.payload_length) return Error.Corrupt;
            const kind: RecordKind = switch (self.payload[offset]) {
                1 => .directory,
                2 => .file,
                3 => .symlink,
                4 => .hard_link,
                5 => .sparse_file,
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
            const data = self.payload[offset .. offset + data_length];
            if (kind == .hard_link) {
                if (data_length == 0 or data_length > runtime_vfs.maximum_path_length or !validRelativePath(data)) return Error.Corrupt;
                if (hard_links_only) {
                    var target_buffer: [runtime_vfs.maximum_path_length + 1]u8 = undefined;
                    const target = try absolutePathInto(data, &target_buffer);
                    const path = try self.absolutePath(relative);
                    _ = vfs.link(0, target, path, tick) catch |err| return self.rejectRestoration(record_index, kind, err);
                }
            } else if (!hard_links_only) {
                const path = try self.absolutePath(relative);
                switch (kind) {
                    .directory => {
                        if (data_length != 0) return Error.Corrupt;
                        _ = vfs.ensureDirectory(0, path, mode, tick) catch |err| return self.rejectRestoration(record_index, kind, err);
                    },
                    .file => {
                        if (data_length > runtime_vfs.maximum_file_size) return Error.Corrupt;
                        _ = vfs.putFile(0, path, data, mode, false, tick) catch |err| return self.rejectRestoration(record_index, kind, err);
                    },
                    .sparse_file => {
                        if (data_length < 5 or data_length > maximum_record_data_bytes) return Error.Corrupt;
                        const allocation_bitmap = data[0];
                        const logical_size: usize = read32(data, 1);
                        const allocated_count: usize = @popCount(allocation_bitmap);
                        if (logical_size > runtime_vfs.maximum_file_size or data_length != 5 + allocated_count * runtime_vfs.file_block_size) return Error.Corrupt;
                        _ = vfs.restoreSparseFile(0, path, mode, logical_size, allocation_bitmap, data[5..], tick) catch |err| return self.rejectRestoration(record_index, kind, err);
                    },
                    .symlink => {
                        if (data_length == 0 or data_length > runtime_vfs.maximum_symlink_target_length) return Error.Corrupt;
                        _ = vfs.symlink(0, data, path, tick) catch |err| return self.rejectRestoration(record_index, kind, err);
                    },
                    .hard_link => unreachable,
                }
            }
            offset += data_length;
        }
        if (offset != candidate.payload_length) return Error.Corrupt;
    }

    fn rejectRestoration(self: *Store, record_index: u32, kind: RecordKind, err: runtime_vfs.Error) Error {
        self.restoration_failure = .{
            .record_index = record_index,
            .record_kind = @intFromEnum(kind),
            .vfs_error = err,
        };
        return Error.InvalidRecord;
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

    fn absolutePathInto(relative: []const u8, output: *[runtime_vfs.maximum_path_length + 1]u8) Error![]const u8 {
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
    kind: Store.RecordKind,
    mode: u16,
    data: []const u8,
) Error!usize {
    if (relative_path.len == 0 or relative_path.len > 255 or data.len > maximum_record_data_bytes) return Error.InvalidRecord;
    const required = 8 + relative_path.len + data.len;
    if (initial_offset > payload.len or required > payload.len - initial_offset) return Error.NoSpace;
    payload[initial_offset] = @intFromEnum(kind);
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
    fail_write_at: ?u64 = null,
    fail_flush_at: ?u64 = null,

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
        if (self.fail_write_at != null and self.fail_write_at.? == self.writes) return false;
        @memcpy(&self.blocks[lba], input);
        self.writes += 1;
        return true;
    }

    fn flush(context: ?*anyopaque) bool {
        const self: *TestDisk = @ptrCast(@alignCast(context.?));
        if (self.fail_flush_at != null and self.fail_flush_at.? == self.flushes) return false;
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

test "global sync succeeds for a ramfs only writable mount table" {
    const vfs = try std.testing.allocator.create(runtime_vfs.Vfs);
    defer std.testing.allocator.destroy(vfs);
    vfs.initialize();
    var store: Store = .{};
    const dirty_node = try vfs.putFile(0, "/dirty", "ramfs", 0o600, false, 1);
    try std.testing.expect((try vfs.dirtyFilePageBitmap(dirty_node)) != 0);
    try store.sync(vfs);
    try std.testing.expectEqual(@as(u8, 0), try vfs.dirtyFilePageBitmap(dirty_node));
    const report = store.report();
    try std.testing.expect(!report.mounted);
    try std.testing.expectEqual(@as(u64, 1), report.global_syncs);
    try std.testing.expectEqual(@as(u64, 1), report.writable_mount_syncs);
    try std.testing.expectEqual(@as(u64, 1), report.immediate_mount_syncs);
    try std.testing.expectEqual(@as(u64, 0), report.durable_mount_syncs);
    try std.testing.expectEqual(@as(u64, 0), report.syncs);
    try std.testing.expectEqual(@as(u64, 0), report.rejected_sync_plans);
}

test "global sync covers writable mounts and rejects invalid plans before journal writes" {
    var disk: TestDisk = .{};
    const vfs = try std.testing.allocator.create(runtime_vfs.Vfs);
    defer std.testing.allocator.destroy(vfs);
    vfs.initialize();
    var store: Store = .{};
    try store.mount(vfs, disk.device(), 1);
    _ = try vfs.ensureDirectory(0, "/scratch", 0o755, 2);
    _ = try vfs.ensureDirectory(0, "/readonly", 0o755, 3);
    _ = try vfs.ensureDirectory(0, "/foreign", 0o755, 4);
    _ = try vfs.mount(0, "/scratch", .ramfs, false, "scratch-ramfs");
    _ = try vfs.mount(0, "/readonly", .boot_fat, true, "readonly-fat");
    const value_node = try vfs.putFile(0, "/persist/value", "stable", 0o640, false, 5);
    try std.testing.expect((try vfs.dirtyFilePageBitmap(value_node)) != 0);
    try store.sync(vfs);
    try std.testing.expectEqual(@as(u8, 0), try vfs.dirtyFilePageBitmap(value_node));
    var report = store.report();
    try std.testing.expectEqual(@as(u8, 2), report.mount_id);
    try std.testing.expectEqual(@as(u64, 1), report.global_syncs);
    try std.testing.expectEqual(@as(u64, 3), report.writable_mount_syncs);
    try std.testing.expectEqual(@as(u64, 2), report.immediate_mount_syncs);
    try std.testing.expectEqual(@as(u64, 1), report.durable_mount_syncs);
    try std.testing.expectEqual(@as(u64, 1), report.syncs);
    try std.testing.expectEqual(@as(u64, 0), report.rejected_sync_plans);

    const writes_after_commit = disk.writes;
    const generation_after_commit = report.generation;
    const unsupported_id = try vfs.mount(0, "/foreign", .boot_fat, false, "writable-fat");
    _ = try vfs.putFile(0, "/persist/value", "dirty", 0o600, false, 6);
    const dirty_after_rejected_plan = try vfs.dirtyFilePageBitmap(value_node);
    try std.testing.expect(dirty_after_rejected_plan != 0);
    try std.testing.expectError(Error.UnsupportedOperation, store.sync(vfs));
    try std.testing.expectEqual(dirty_after_rejected_plan, try vfs.dirtyFilePageBitmap(value_node));
    report = store.report();
    try std.testing.expectEqual(generation_after_commit, report.generation);
    try std.testing.expectEqual(writes_after_commit, disk.writes);
    try std.testing.expectEqual(@as(u64, 1), report.global_syncs);
    try std.testing.expectEqual(@as(u64, 1), report.rejected_sync_plans);

    try vfs.unmount(unsupported_id);
    _ = try vfs.mount(0, "/foreign", .zigos_persist, false, "duplicate-persist");
    try std.testing.expectError(Error.NotConfigured, store.sync(vfs));
    report = store.report();
    try std.testing.expectEqual(generation_after_commit, report.generation);
    try std.testing.expectEqual(writes_after_commit, disk.writes);
    try std.testing.expectEqual(@as(u64, 1), report.global_syncs);
    try std.testing.expectEqual(@as(u64, 2), report.rejected_sync_plans);
}

test "bounded asynchronous writeback services immediate durable unsupported failed and stale requests" {
    const ram_vfs = try std.testing.allocator.create(runtime_vfs.Vfs);
    defer std.testing.allocator.destroy(ram_vfs);
    ram_vfs.initialize();
    var ram_store: Store = .{};
    const ram_node = try ram_vfs.putFile(0, "/ram", "ram", 0o600, false, 1);
    const ram_request = try ram_store.requestWriteback(ram_vfs, ram_node);
    try std.testing.expect(!ram_request.persistent);
    try std.testing.expectEqual(@as(u8, 0x01), ram_request.pages);
    try std.testing.expect((try ram_vfs.dirtyFilePageBitmap(ram_node)) != 0);
    try std.testing.expectError(Error.Busy, ram_store.requestWriteback(ram_vfs, ram_node));
    try std.testing.expectEqual(WritebackOutcome.immediate, ram_store.serviceWriteback(ram_vfs));
    try std.testing.expectEqual(@as(u8, 0), try ram_vfs.dirtyFilePageBitmap(ram_node));
    try std.testing.expectEqual(WritebackOutcome.idle, ram_store.serviceWriteback(ram_vfs));

    const stale_node = try ram_vfs.putFile(0, "/stale", "old", 0o600, false, 2);
    _ = try ram_store.requestWriteback(ram_vfs, stale_node);
    try ram_vfs.unlink(0, "/stale");
    try std.testing.expectEqual(WritebackOutcome.stale, ram_store.serviceWriteback(ram_vfs));

    var disk: TestDisk = .{};
    const vfs = try std.testing.allocator.create(runtime_vfs.Vfs);
    defer std.testing.allocator.destroy(vfs);
    vfs.initialize();
    var store: Store = .{};
    try store.mount(vfs, disk.device(), 1);
    const stable_node = try vfs.putFile(0, "/persist/stable", "before", 0o640, false, 2);
    try store.sync(vfs);
    _ = try vfs.putFile(0, "/persist/stable", "after-data", 0o600, false, 3);
    const generation_before = store.report().generation;
    const durable_request = try store.requestWriteback(vfs, stable_node);
    try std.testing.expect(durable_request.persistent);
    try std.testing.expect((try vfs.dirtyFilePageBitmap(stable_node)) != 0);
    try std.testing.expectEqual(generation_before, store.report().generation);
    try std.testing.expectEqual(WritebackOutcome.durable, store.serviceWriteback(vfs));
    try std.testing.expectEqual(generation_before + 1, store.report().generation);
    try std.testing.expectEqual(@as(u8, 0), try vfs.dirtyFilePageBitmap(stable_node));

    const new_node = try vfs.putFile(0, "/persist/new", "new", 0o600, false, 4);
    _ = try store.requestWriteback(vfs, new_node);
    try std.testing.expectEqual(WritebackOutcome.unsupported, store.serviceWriteback(vfs));
    try std.testing.expect((try vfs.dirtyFilePageBitmap(new_node)) != 0);

    _ = try vfs.putFile(0, "/persist/stable", "damage", 0o600, false, 5);
    disk.fail_write_at = disk.writes;
    _ = try store.requestWriteback(vfs, stable_node);
    try std.testing.expectEqual(WritebackOutcome.failed, store.serviceWriteback(vfs));
    try std.testing.expectEqual(@as(u8, 0), try vfs.dirtyFilePageBitmap(stable_node));
    try std.testing.expect(try vfs.mountReadOnly(store.report().mount_id));
    try std.testing.expectError(Error.ReadOnly, store.requestWriteback(vfs, stable_node));

    const report = store.report();
    try std.testing.expect(!report.writeback_active);
    try std.testing.expect(report.damaged);
    try std.testing.expectEqual(DamageReason.payload_write, report.damage_reason);
    try std.testing.expectEqual(@as(u64, 1), report.read_only_remounts);
    try std.testing.expectEqual(@as(u64, 0), report.read_only_remount_failures);
    try std.testing.expectEqual(@as(u64, 2), report.discarded_dirty_pages);
    try std.testing.expectEqual(@as(u64, 1), report.read_only_rejections);
    try std.testing.expectEqual(@as(u64, 3), report.writeback_requests);
    try std.testing.expectEqual(@as(u64, 1), report.writeback_completions);
    try std.testing.expectEqual(@as(u64, 3), report.writeback_passes);
    try std.testing.expectEqual(@as(u64, 0), report.writeback_immediate);
    try std.testing.expectEqual(@as(u64, 1), report.writeback_durable);
    try std.testing.expectEqual(@as(u64, 1), report.writeback_unsupported);
    try std.testing.expectEqual(@as(u64, 1), report.writeback_failures);
    try std.testing.expectEqual(@as(u64, 0), report.writeback_stale);
    try std.testing.expectEqual(report.writeback_pages_queued, report.writeback_pages_completed + 2);
    const ram_report = ram_store.report();
    try std.testing.expectEqual(@as(u64, 2), ram_report.writeback_requests);
    try std.testing.expectEqual(@as(u64, 1), ram_report.writeback_completions);
    try std.testing.expectEqual(@as(u64, 1), ram_report.writeback_immediate);
    try std.testing.expectEqual(@as(u64, 1), ram_report.writeback_stale);
}

test "alternating snapshots restore a persistent VFS subtree" {
    var disk: TestDisk = .{};
    const first_vfs = try std.testing.allocator.create(runtime_vfs.Vfs);
    defer std.testing.allocator.destroy(first_vfs);
    first_vfs.initialize();
    var first_store: Store = .{};
    try first_store.mount(first_vfs, disk.device(), 1);
    _ = try first_vfs.ensureDirectory(0, "/persist/config", 0o755, 2);
    _ = try first_vfs.putFile(0, "/persist/config/name.txt", "zigos\n", 0o640, false, 3);
    _ = try first_vfs.link(0, "/persist/config/name.txt", "/persist/name-hard", 4);
    _ = try first_vfs.symlink(0, "config/name.txt", "/persist/name-link", 5);
    const sparse_handle = try first_vfs.open(1, 0, "/persist/sparse.bin", .{ .read = true, .write = true, .create = true }, 0o600, 6);
    _ = try first_vfs.seek(1, sparse_handle, 2 * runtime_vfs.file_block_size, .start);
    _ = try first_vfs.writeOpen(1, sparse_handle, "tail", 7);
    try first_vfs.allocateOpen(1, sparse_handle, 0, runtime_vfs.file_block_size, .{ .keep_size = true }, 8);
    try first_vfs.close(1, sparse_handle);
    try first_store.sync(first_vfs);
    try std.testing.expectEqual(@as(u64, 1), first_store.report().generation);
    try first_store.check();

    const second_vfs = try std.testing.allocator.create(runtime_vfs.Vfs);
    defer std.testing.allocator.destroy(second_vfs);
    second_vfs.initialize();
    var second_store: Store = .{};
    try second_store.mount(second_vfs, disk.device(), 10);
    try std.testing.expectEqualStrings("zigos\n", try second_vfs.readOnlyView(0, "/persist/config/name.txt"));
    try std.testing.expectEqualStrings("zigos\n", try second_vfs.readOnlyView(0, "/persist/name-hard"));
    try std.testing.expectEqual((try second_vfs.stat(0, "/persist/config/name.txt")).node, (try second_vfs.stat(0, "/persist/name-hard")).node);
    try std.testing.expectEqual(@as(u16, 2), (try second_vfs.stat(0, "/persist/name-hard")).link_count);
    try std.testing.expectEqualStrings("zigos\n", try second_vfs.readOnlyView(0, "/persist/name-link"));
    const restored_sparse_node = (try second_vfs.stat(0, "/persist/sparse.bin")).node;
    const restored_sparse = try second_vfs.sparseFileInfoNode(restored_sparse_node);
    try std.testing.expectEqual(@as(usize, 2 * runtime_vfs.file_block_size + 4), restored_sparse.size);
    try std.testing.expectEqual(@as(u8, (1 << 0) | (1 << 2)), restored_sparse.allocation_bitmap);
    var sparse_prefix: [runtime_vfs.file_block_size]u8 = undefined;
    try std.testing.expectEqual(sparse_prefix.len, try second_vfs.read(0, "/persist/sparse.bin", 0, &sparse_prefix));
    for (sparse_prefix) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    var sparse_tail: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try second_vfs.read(0, "/persist/sparse.bin", 2 * runtime_vfs.file_block_size, &sparse_tail));
    try std.testing.expectEqualStrings("tail", &sparse_tail);
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

test "file sync commits one stable file and excludes unrelated dirty state" {
    var disk: TestDisk = .{};
    const live_vfs = try std.testing.allocator.create(runtime_vfs.Vfs);
    defer std.testing.allocator.destroy(live_vfs);
    live_vfs.initialize();
    var store: Store = .{};
    try store.mount(live_vfs, disk.device(), 1);
    const target_node = try live_vfs.putFile(0, "/persist/target.txt", "target-v1", 0o640, false, 2);
    _ = try live_vfs.putFile(0, "/persist/other.txt", "other-v1", 0o600, false, 3);
    try store.sync(live_vfs);
    try std.testing.expectEqual(@as(u64, 1), store.report().generation);

    _ = try live_vfs.putFile(0, "/persist/target.txt", "target-v2", 0o600, false, 4);
    try live_vfs.chmod(0, "/persist/target.txt", 0o600, 5);
    const other_node = try live_vfs.putFile(0, "/persist/other.txt", "other-v2", 0o700, false, 6);
    try live_vfs.chmod(0, "/persist/other.txt", 0o700, 7);
    try std.testing.expect((try live_vfs.dirtyFilePageBitmap(target_node)) != 0);
    try std.testing.expect((try live_vfs.dirtyFilePageBitmap(other_node)) != 0);
    try store.syncFile(live_vfs, target_node);
    try std.testing.expectEqual(@as(u8, 0), try live_vfs.dirtyFilePageBitmap(target_node));
    try std.testing.expect((try live_vfs.dirtyFilePageBitmap(other_node)) != 0);
    try std.testing.expectEqual(@as(u64, 2), store.report().generation);

    const recovered_vfs = try std.testing.allocator.create(runtime_vfs.Vfs);
    defer std.testing.allocator.destroy(recovered_vfs);
    recovered_vfs.initialize();
    var recovered: Store = .{};
    try recovered.mount(recovered_vfs, disk.device(), 8);
    try std.testing.expectEqualStrings("target-v2", try recovered_vfs.readOnlyView(0, "/persist/target.txt"));
    try std.testing.expectEqual(@as(u16, 0o600), (try recovered_vfs.stat(0, "/persist/target.txt")).mode);
    try std.testing.expectEqualStrings("other-v1", try recovered_vfs.readOnlyView(0, "/persist/other.txt"));
    try std.testing.expectEqual(@as(u16, 0o600), (try recovered_vfs.stat(0, "/persist/other.txt")).mode);

    const new_node = try live_vfs.putFile(0, "/persist/new.txt", "new", 0o644, false, 9);
    try std.testing.expectError(Error.UnsupportedOperation, store.syncFile(live_vfs, new_node));
}

test "file data sync persists bytes and size without dirty mode metadata" {
    var disk: TestDisk = .{};
    const live_vfs = try std.testing.allocator.create(runtime_vfs.Vfs);
    defer std.testing.allocator.destroy(live_vfs);
    live_vfs.initialize();
    var store: Store = .{};
    try store.mount(live_vfs, disk.device(), 1);
    const target_node = try live_vfs.putFile(0, "/persist/target.txt", "before", 0o640, false, 2);
    _ = try live_vfs.putFile(0, "/persist/other.txt", "stable", 0o600, false, 3);
    try store.sync(live_vfs);

    _ = try live_vfs.putFile(0, "/persist/target.txt", "after-data-and-size", 0o600, false, 4);
    try live_vfs.chmod(0, "/persist/target.txt", 0o600, 5);
    const other_node = try live_vfs.putFile(0, "/persist/other.txt", "dirty", 0o700, false, 6);
    try std.testing.expect((try live_vfs.dirtyFilePageBitmap(target_node)) != 0);
    try std.testing.expect((try live_vfs.dirtyFilePageBitmap(other_node)) != 0);
    try store.syncFileData(live_vfs, target_node);
    try std.testing.expectEqual(@as(u8, 0), try live_vfs.dirtyFilePageBitmap(target_node));
    try std.testing.expect((try live_vfs.dirtyFilePageBitmap(other_node)) != 0);

    const recovered_vfs = try std.testing.allocator.create(runtime_vfs.Vfs);
    defer std.testing.allocator.destroy(recovered_vfs);
    recovered_vfs.initialize();
    var recovered: Store = .{};
    try recovered.mount(recovered_vfs, disk.device(), 7);
    try std.testing.expectEqualStrings("after-data-and-size", try recovered_vfs.readOnlyView(0, "/persist/target.txt"));
    try std.testing.expectEqual(@as(u16, 0o640), (try recovered_vfs.stat(0, "/persist/target.txt")).mode);
    try std.testing.expectEqualStrings("stable", try recovered_vfs.readOnlyView(0, "/persist/other.txt"));
    try std.testing.expectEqual(@as(u16, 0o600), (try recovered_vfs.stat(0, "/persist/other.txt")).mode);
    try std.testing.expectEqual(@as(u64, 2), recovered.report().generation);
}

test "failed file sync remounts persist read only and preserves the committed baseline" {
    var disk: TestDisk = .{};
    const live_vfs = try std.testing.allocator.create(runtime_vfs.Vfs);
    defer std.testing.allocator.destroy(live_vfs);
    live_vfs.initialize();
    var store: Store = .{};
    try store.mount(live_vfs, disk.device(), 1);
    const target_node = try live_vfs.putFile(0, "/persist/target.txt", "before", 0o640, false, 2);
    try store.sync(live_vfs);
    const committed_payload = store.payload;
    const committed_report = store.report();

    _ = try live_vfs.putFile(0, "/persist/target.txt", "after", 0o600, false, 3);
    try std.testing.expect((try live_vfs.dirtyFilePageBitmap(target_node)) != 0);
    disk.fail_write_at = disk.writes;
    try std.testing.expectError(Error.Io, store.syncFile(live_vfs, target_node));
    try std.testing.expectEqual(@as(u8, 0), try live_vfs.dirtyFilePageBitmap(target_node));
    try std.testing.expect(try live_vfs.mountReadOnly(committed_report.mount_id));
    try std.testing.expect((try live_vfs.stat(0, "/persist/target.txt")).readonly);
    try std.testing.expectEqualStrings("after", try live_vfs.readOnlyView(0, "/persist/target.txt"));
    try std.testing.expectError(runtime_vfs.Error.ReadOnly, live_vfs.write(0, "/persist/target.txt", 0, "blocked", false, 4));
    try std.testing.expectError(Error.ReadOnly, store.syncFile(live_vfs, target_node));
    const ram_node = try live_vfs.putFile(0, "/ram-after-damage", "dirty", 0o600, false, 4);
    try std.testing.expect((try live_vfs.dirtyFilePageBitmap(ram_node)) != 0);
    try std.testing.expectError(Error.ReadOnly, store.sync(live_vfs));
    try std.testing.expectEqual(@as(u8, 0), try live_vfs.dirtyFilePageBitmap(ram_node));
    const damaged_report = store.report();
    try std.testing.expect(damaged_report.damaged);
    try std.testing.expectEqual(DamageReason.payload_write, damaged_report.damage_reason);
    try std.testing.expectEqual(@as(u64, 1), damaged_report.read_only_remounts);
    try std.testing.expectEqual(@as(u64, 0), damaged_report.read_only_remount_failures);
    try std.testing.expectEqual(@as(u64, 1), damaged_report.discarded_dirty_pages);
    try std.testing.expectEqual(@as(u64, 2), damaged_report.read_only_rejections);
    try std.testing.expectEqual(committed_report.generation, damaged_report.generation);
    try std.testing.expectEqual(committed_report.active_slot, damaged_report.active_slot);
    try std.testing.expectEqual(committed_report.record_count, damaged_report.record_count);
    try std.testing.expectEqualSlices(u8, &committed_payload, &store.payload);

    disk.fail_write_at = null;
    const recovered_vfs = try std.testing.allocator.create(runtime_vfs.Vfs);
    defer std.testing.allocator.destroy(recovered_vfs);
    recovered_vfs.initialize();
    var recovered: Store = .{};
    try recovered.mount(recovered_vfs, disk.device(), 5);
    try std.testing.expectEqualStrings("before", try recovered_vfs.readOnlyView(0, "/persist/target.txt"));
    try std.testing.expectEqual(@as(u64, 1), recovered.report().generation);
}

test "journal write and flush failures classify read only remount stage" {
    {
        var disk: TestDisk = .{};
        const vfs = try std.testing.allocator.create(runtime_vfs.Vfs);
        defer std.testing.allocator.destroy(vfs);
        vfs.initialize();
        var store: Store = .{};
        try store.mount(vfs, disk.device(), 1);
        _ = try vfs.putFile(0, "/persist/value", "dirty", 0o600, false, 2);
        disk.fail_flush_at = disk.flushes;
        try std.testing.expectError(Error.Io, store.sync(vfs));
        const report = store.report();
        try std.testing.expect(report.damaged);
        try std.testing.expectEqual(DamageReason.payload_flush, report.damage_reason);
        try std.testing.expectEqual(@as(u64, 1), report.read_only_remounts);
        try std.testing.expectEqual(@as(u64, 1), report.discarded_dirty_pages);
        try std.testing.expect(try vfs.mountReadOnly(report.mount_id));
        try std.testing.expectError(runtime_vfs.Error.ReadOnly, vfs.putFile(0, "/persist/value", "blocked", 0o600, false, 3));
    }

    {
        var disk: TestDisk = .{};
        const vfs = try std.testing.allocator.create(runtime_vfs.Vfs);
        defer std.testing.allocator.destroy(vfs);
        vfs.initialize();
        var store: Store = .{};
        try store.mount(vfs, disk.device(), 1);
        _ = try vfs.putFile(0, "/persist/value", "clean", 0o600, false, 2);
        try store.sync(vfs);
        const committed = store.report();
        const payload_sectors = std.math.divCeil(usize, @intCast(committed.payload_bytes), disk.device().block_size) catch unreachable;
        const writes_before = disk.writes;
        const flushes_before = disk.flushes;
        _ = try vfs.putFile(0, "/persist/value", "dirty", 0o600, false, 3);
        disk.fail_write_at = disk.writes + payload_sectors;
        try std.testing.expectError(Error.Io, store.sync(vfs));
        const report = store.report();
        try std.testing.expect(report.damaged);
        try std.testing.expectEqual(DamageReason.header_write, report.damage_reason);
        try std.testing.expectEqual(@as(u64, 1), report.read_only_remounts);
        try std.testing.expectEqual(@as(u64, 1), report.discarded_dirty_pages);
        try std.testing.expect(try vfs.mountReadOnly(report.mount_id));
        try std.testing.expectEqual(writes_before + payload_sectors, disk.writes);
        try std.testing.expectEqual(flushes_before + 1, disk.flushes);
        try std.testing.expectEqual(committed.generation, report.generation);
        disk.fail_write_at = null;
        const recovered_vfs = try std.testing.allocator.create(runtime_vfs.Vfs);
        defer std.testing.allocator.destroy(recovered_vfs);
        recovered_vfs.initialize();
        var recovered: Store = .{};
        try recovered.mount(recovered_vfs, disk.device(), 4);
        try std.testing.expectEqual(committed.generation, recovered.report().generation);
        try std.testing.expectEqualStrings("clean", try recovered_vfs.readOnlyView(0, "/persist/value"));
    }

    {
        var disk: TestDisk = .{};
        const vfs = try std.testing.allocator.create(runtime_vfs.Vfs);
        defer std.testing.allocator.destroy(vfs);
        vfs.initialize();
        var store: Store = .{};
        try store.mount(vfs, disk.device(), 1);
        _ = try vfs.putFile(0, "/persist/value", "clean", 0o600, false, 2);
        try store.sync(vfs);
        const committed = store.report();
        const payload_sectors = std.math.divCeil(usize, @intCast(committed.payload_bytes), disk.device().block_size) catch unreachable;
        const writes_before = disk.writes;
        const flushes_before = disk.flushes;
        _ = try vfs.putFile(0, "/persist/value", "dirty", 0o600, false, 3);
        disk.fail_flush_at = disk.flushes + 1;
        try std.testing.expectError(Error.Io, store.sync(vfs));
        const report = store.report();
        try std.testing.expect(report.damaged);
        try std.testing.expectEqual(DamageReason.header_flush, report.damage_reason);
        try std.testing.expectEqual(@as(u64, 1), report.read_only_remounts);
        try std.testing.expectEqual(@as(u64, 1), report.discarded_dirty_pages);
        try std.testing.expect(try vfs.mountReadOnly(report.mount_id));
        try std.testing.expectEqual(writes_before + payload_sectors + 1, disk.writes);
        try std.testing.expectEqual(flushes_before + 1, disk.flushes);
        try std.testing.expectEqual(committed.generation, report.generation);
        disk.fail_flush_at = null;
        const recovered_vfs = try std.testing.allocator.create(runtime_vfs.Vfs);
        defer std.testing.allocator.destroy(recovered_vfs);
        recovered_vfs.initialize();
        var recovered: Store = .{};
        try recovered.mount(recovered_vfs, disk.device(), 4);
        try std.testing.expectEqual(committed.generation + 1, recovered.report().generation);
        try std.testing.expectEqualStrings("dirty", try recovered_vfs.readOnlyView(0, "/persist/value"));
    }
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
