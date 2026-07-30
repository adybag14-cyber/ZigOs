const std = @import("std");
const fat = @import("fat.zig");
const runtime_vfs = @import("runtime_vfs.zig");
const synchronization = @import("synchronization.zig");

pub const maximum_files: usize = 32;
pub const maximum_directories: usize = 24;
pub const maximum_depth: u8 = 8;
pub const maximum_sector_bytes: usize = 4096;
const visited_bytes: usize = 8192;

pub const ReadBlockFn = *const fn (context: ?*anyopaque, lba: u64, output: []u8) bool;

pub const BlockDevice = struct {
    context: ?*anyopaque,
    block_size: u32,
    first_lba: u64,
    sector_count: u64,
    read_fn: ReadBlockFn,
};

pub const Report = struct {
    mounted: bool,
    files: usize,
    directories: usize,
    bytes: u64,
    metadata_reads: u64,
    file_reads: u64,
    blocks_read: u64,
    failures: u64,
    claimed_clusters: u32,
    chain_loops: u64,
    cross_links: u64,
    out_of_range_links: u64,
    lock_tickets: u32,
    lock_outstanding: u32,
};

pub const Error = runtime_vfs.Error || error{
    AlreadyMounted,
    InvalidDevice,
    InvalidVolume,
    UnsupportedFat,
    CorruptFilesystem,
    IoFailure,
    NamespaceLimit,
    ChainLoop,
    CrossLinkedCluster,
    OutOfRangeCluster,
};

const DirectoryTask = struct {
    parent_node: u16,
    first_cluster: u32,
    depth: u8,
};

const FileContext = struct {
    used: bool = false,
    backend: ?*Backend = null,
    first_cluster: u32 = 0,
    size: u32 = 0,
    cursor_valid: bool = false,
    cursor_cluster: u32 = 0,
    cursor_ordinal: u32 = 0,
};

pub const Backend = struct {
    mounted: bool = false,
    device: BlockDevice = undefined,
    volume: fat.Volume = undefined,
    files: [maximum_files]FileContext = @splat(.{}),
    sector: [maximum_sector_bytes]u8 = @splat(0),
    fat_sector: [maximum_sector_bytes]u8 = @splat(0),
    cached_fat_lba: u64 = 0,
    fat_sector_valid: bool = false,
    directory_visited: [visited_bytes]u8 = @splat(0),
    file_visited: [visited_bytes]u8 = @splat(0),
    claimed_cluster_bitmap: [visited_bytes]u8 = @splat(0),
    io_lock: synchronization.TicketLock = synchronization.TicketLock.init(),
    file_count: usize = 0,
    directory_count: usize = 0,
    byte_count: u64 = 0,
    metadata_reads: u64 = 0,
    file_reads: u64 = 0,
    blocks_read: u64 = 0,
    failures: u64 = 0,
    claimed_clusters: u32 = 0,
    chain_loops: u64 = 0,
    cross_links: u64 = 0,
    out_of_range_links: u64 = 0,

    pub fn init() Backend {
        return .{};
    }

    pub fn mount(
        self: *Backend,
        vfs: *runtime_vfs.Vfs,
        mount_path: []const u8,
        source: []const u8,
        device: BlockDevice,
        tick: u64,
    ) Error!u8 {
        if (self.mounted) return Error.AlreadyMounted;
        if (device.block_size < 512 or device.block_size > maximum_sector_bytes or
            !std.math.isPowerOfTwo(device.block_size) or device.sector_count == 0)
            return Error.InvalidDevice;
        _ = std.math.add(u64, device.first_lba, device.sector_count) catch return Error.InvalidDevice;
        self.* = .{};
        self.device = device;
        _ = self.io_lock.acquire();
        defer self.io_lock.release();

        try self.readMetadataBlockLocked(device.first_lba);
        self.volume = fat.parseBootSector(self.sector[0..device.block_size], device.first_lba) orelse return Error.InvalidVolume;
        if (self.volume.kind != .fat16) return Error.UnsupportedFat;
        if (self.volume.bytes_per_sector != device.block_size or self.volume.total_sectors > device.sector_count or
            self.volume.cluster_count + 2 > visited_bytes * 8)
            return Error.InvalidVolume;

        const mountpoint = try vfs.resolve(0, mount_path);
        if ((try vfs.statNode(mountpoint)).kind != .directory) return Error.NotDirectory;
        var queue: [maximum_directories]DirectoryTask = undefined;
        var queue_count: usize = 1;
        var queue_index: usize = 0;
        queue[0] = .{ .parent_node = mountpoint, .first_cluster = self.volume.root_cluster, .depth = 0 };
        while (queue_index < queue_count) : (queue_index += 1) {
            try self.importDirectoryLocked(vfs, queue[queue_index], &queue, &queue_count, tick);
        }
        const mount_id = try vfs.mount(0, mount_path, .boot_fat, true, source);
        self.mounted = true;
        return mount_id;
    }

    pub fn report(self: *const Backend) Report {
        return .{
            .mounted = self.mounted,
            .files = self.file_count,
            .directories = self.directory_count,
            .bytes = self.byte_count,
            .metadata_reads = self.metadata_reads,
            .file_reads = self.file_reads,
            .blocks_read = self.blocks_read,
            .failures = self.failures,
            .claimed_clusters = self.claimed_clusters,
            .chain_loops = self.chain_loops,
            .cross_links = self.cross_links,
            .out_of_range_links = self.out_of_range_links,
            .lock_tickets = self.io_lock.next(),
            .lock_outstanding = self.io_lock.next() -% self.io_lock.serving(),
        };
    }

    pub fn validate(self: *const Backend) bool {
        if (!self.mounted or self.file_count > self.files.len or self.directory_count > maximum_directories) return false;
        if (self.io_lock.next() != self.io_lock.serving()) return false;
        var files: usize = 0;
        var bytes: u64 = 0;
        for (&self.files) |*file| {
            if (!file.used) continue;
            if (file.backend != self or (file.size != 0 and file.first_cluster < 2)) return false;
            files += 1;
            bytes += file.size;
        }
        return files == self.file_count and bytes == self.byte_count and self.claimed_clusters <= self.volume.cluster_count and
            self.chain_loops == 0 and self.cross_links == 0 and self.out_of_range_links == 0;
    }

    fn importDirectoryLocked(
        self: *Backend,
        vfs: *runtime_vfs.Vfs,
        task: DirectoryTask,
        queue: *[maximum_directories]DirectoryTask,
        queue_count: *usize,
        tick: u64,
    ) Error!void {
        if (task.depth > maximum_depth) return Error.NamespaceLimit;
        if (task.first_cluster == 0) {
            if (self.volume.kind == .fat32) return Error.UnsupportedFat;
            var sector_index: u32 = 0;
            while (sector_index < self.volume.root_directory_sectors) : (sector_index += 1) {
                try self.readMetadataBlockLocked(self.volume.root_directory_lba + sector_index);
                const decoded = fat.parseDirectorySector(self.sector[0..self.device.block_size]) orelse return Error.CorruptFilesystem;
                try self.importDirectorySectorLocked(vfs, task, decoded, queue, queue_count, tick);
                if (decoded.end_of_directory) return;
            }
            return;
        }

        @memset(&self.directory_visited, 0);
        var cluster = task.first_cluster;
        var traversed: u32 = 0;
        var end_of_directory = false;
        while (traversed < self.volume.cluster_count) : (traversed += 1) {
            try self.markChainVisitedLocked(&self.directory_visited, cluster);
            try self.claimClusterLocked(cluster);
            if (!end_of_directory) {
                const first_lba = try self.clusterFirstLbaLocked(cluster);
                var sector_index: u32 = 0;
                while (sector_index < self.volume.sectors_per_cluster) : (sector_index += 1) {
                    try self.readMetadataBlockLocked(first_lba + sector_index);
                    const decoded = fat.parseDirectorySector(self.sector[0..self.device.block_size]) orelse return Error.CorruptFilesystem;
                    try self.importDirectorySectorLocked(vfs, task, decoded, queue, queue_count, tick);
                    if (decoded.end_of_directory) {
                        end_of_directory = true;
                        break;
                    }
                }
            }
            switch (try self.readClusterLinkLocked(cluster)) {
                .next => |next| cluster = next,
                .end => return,
                .free, .bad => return Error.CorruptFilesystem,
            }
        }
        self.chain_loops +%= 1;
        return Error.ChainLoop;
    }

    fn importDirectorySectorLocked(
        self: *Backend,
        vfs: *runtime_vfs.Vfs,
        task: DirectoryTask,
        decoded: fat.DirectorySector,
        queue: *[maximum_directories]DirectoryTask,
        queue_count: *usize,
        tick: u64,
    ) Error!void {
        for (decoded.entries[0..decoded.count]) |entry| {
            const name = entry.nameSlice();
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (entry.isDirectory()) {
                if (entry.first_cluster < 2 or queue_count.* >= queue.len) return Error.NamespaceLimit;
                const node = try vfs.mkdir(task.parent_node, name, 0o555, tick);
                queue[queue_count.*] = .{
                    .parent_node = node,
                    .first_cluster = entry.first_cluster,
                    .depth = task.depth + 1,
                };
                queue_count.* += 1;
                self.directory_count += 1;
                continue;
            }
            if (self.file_count >= self.files.len) return Error.NamespaceLimit;
            try self.validateFileChainLocked(entry.first_cluster, entry.file_size);
            const file = &self.files[self.file_count];
            file.* = .{
                .used = true,
                .backend = self,
                .first_cluster = entry.first_cluster,
                .size = entry.file_size,
            };
            _ = try vfs.createBackedFileWithOperations(
                task.parent_node,
                name,
                entry.file_size,
                0o444,
                tick,
                &file_operations,
                file,
            );
            self.file_count += 1;
            self.byte_count += entry.file_size;
        }
    }

    fn validateFileChainLocked(self: *Backend, first_cluster: u32, size: u32) Error!void {
        if (size == 0 and first_cluster == 0) return;
        if (first_cluster < 2) return self.outOfRangeCluster();
        const cluster_bytes = @as(u64, self.device.block_size) * self.volume.sectors_per_cluster;
        const required: u32 = @intCast((@as(u64, size) + cluster_bytes - 1) / cluster_bytes);
        @memset(&self.file_visited, 0);
        var cluster = first_cluster;
        var count: u32 = 0;
        while (count < self.volume.cluster_count) {
            try self.markChainVisitedLocked(&self.file_visited, cluster);
            try self.claimClusterLocked(cluster);
            count += 1;
            switch (try self.readClusterLinkLocked(cluster)) {
                .next => |next| cluster = next,
                .end => {
                    if (count < required) return Error.CorruptFilesystem;
                    return;
                },
                .free, .bad => return Error.CorruptFilesystem,
            }
        }
        self.chain_loops +%= 1;
        return Error.ChainLoop;
    }

    fn readFile(self: *Backend, file: *FileContext, offset: usize, output: []u8) Error!usize {
        _ = self.io_lock.acquire();
        defer self.io_lock.release();
        self.file_reads +%= 1;
        if (offset >= file.size or output.len == 0) return 0;
        const count = @min(output.len, @as(usize, file.size) - offset);
        if (file.size == 0) return 0;
        const cluster_bytes: usize = self.device.block_size * self.volume.sectors_per_cluster;
        const target_ordinal: u32 = @intCast(offset / cluster_bytes);
        var cluster = file.first_cluster;
        var ordinal: u32 = 0;
        if (file.cursor_valid and target_ordinal >= file.cursor_ordinal) {
            cluster = file.cursor_cluster;
            ordinal = file.cursor_ordinal;
        }
        while (ordinal < target_ordinal) : (ordinal += 1) {
            cluster = switch (try self.readClusterLinkLocked(cluster)) {
                .next => |next| next,
                .end, .free, .bad => return Error.CorruptFilesystem,
            };
        }

        var copied: usize = 0;
        var cluster_offset = offset % cluster_bytes;
        while (copied < count) {
            const first_lba = fat.clusterFirstLba(self.volume, cluster) orelse return Error.CorruptFilesystem;
            var sector_index: usize = cluster_offset / self.device.block_size;
            var sector_offset: usize = cluster_offset % self.device.block_size;
            while (sector_index < self.volume.sectors_per_cluster and copied < count) : (sector_index += 1) {
                try self.readFileBlockLocked(first_lba + sector_index);
                const amount = @min(count - copied, @as(usize, self.device.block_size) - sector_offset);
                @memcpy(output[copied .. copied + amount], self.sector[sector_offset .. sector_offset + amount]);
                copied += amount;
                sector_offset = 0;
            }
            file.cursor_valid = true;
            file.cursor_cluster = cluster;
            file.cursor_ordinal = ordinal;
            cluster_offset = 0;
            if (copied == count) break;
            cluster = switch (try self.readClusterLinkLocked(cluster)) {
                .next => |next| next,
                .end, .free, .bad => return Error.CorruptFilesystem,
            };
            ordinal += 1;
        }
        return copied;
    }

    fn readClusterLinkLocked(self: *Backend, cluster: u32) Error!fat.ClusterLink {
        const location = fat.fatEntryLocation(self.volume, cluster) orelse return self.outOfRangeCluster();
        if (!self.fat_sector_valid or self.cached_fat_lba != location.lba) {
            try self.readFatBlockLocked(location.lba);
            self.cached_fat_lba = location.lba;
            self.fat_sector_valid = true;
        }
        return fat.decodeClusterLink(self.volume, cluster, self.fat_sector[0..self.device.block_size]) orelse self.outOfRangeCluster();
    }

    fn readFatBlockLocked(self: *Backend, lba: u64) Error!void {
        try self.readDeviceBlockLocked(lba, self.fat_sector[0..self.device.block_size]);
        self.metadata_reads +%= 1;
    }

    fn readMetadataBlockLocked(self: *Backend, lba: u64) Error!void {
        try self.readBlockLocked(lba);
        self.metadata_reads +%= 1;
    }

    fn readFileBlockLocked(self: *Backend, lba: u64) Error!void {
        try self.readBlockLocked(lba);
    }

    fn readBlockLocked(self: *Backend, lba: u64) Error!void {
        try self.readDeviceBlockLocked(lba, self.sector[0..self.device.block_size]);
    }

    fn readDeviceBlockLocked(self: *Backend, lba: u64, output: []u8) Error!void {
        const end = self.device.first_lba + self.device.sector_count;
        if (lba < self.device.first_lba or lba >= end) {
            self.failures +%= 1;
            return Error.CorruptFilesystem;
        }
        if (!self.device.read_fn(self.device.context, lba, output)) {
            self.failures +%= 1;
            return Error.IoFailure;
        }
        self.blocks_read +%= 1;
    }

    fn clusterFirstLbaLocked(self: *Backend, cluster: u32) Error!u64 {
        return fat.clusterFirstLba(self.volume, cluster) orelse self.outOfRangeCluster();
    }

    fn markChainVisitedLocked(self: *Backend, bitmap: *[visited_bytes]u8, cluster: u32) Error!void {
        if (cluster < 2 or cluster >= self.volume.cluster_count + 2 or cluster >= visited_bytes * 8)
            return self.outOfRangeCluster();
        const index: usize = cluster / 8;
        const bit: u3 = @intCast(cluster % 8);
        const mask = @as(u8, 1) << bit;
        if ((bitmap[index] & mask) != 0) {
            self.chain_loops +%= 1;
            return Error.ChainLoop;
        }
        bitmap[index] |= mask;
    }

    fn claimClusterLocked(self: *Backend, cluster: u32) Error!void {
        if (cluster < 2 or cluster >= self.volume.cluster_count + 2 or cluster >= visited_bytes * 8)
            return self.outOfRangeCluster();
        const index: usize = cluster / 8;
        const bit: u3 = @intCast(cluster % 8);
        const mask = @as(u8, 1) << bit;
        if ((self.claimed_cluster_bitmap[index] & mask) != 0) {
            self.cross_links +%= 1;
            return Error.CrossLinkedCluster;
        }
        self.claimed_cluster_bitmap[index] |= mask;
        self.claimed_clusters += 1;
    }

    fn outOfRangeCluster(self: *Backend) Error {
        self.out_of_range_links +%= 1;
        return Error.OutOfRangeCluster;
    }
};

fn readBackedFile(context: ?*anyopaque, _: u16, offset: usize, output: []u8) runtime_vfs.Error!usize {
    const file: *FileContext = @ptrCast(@alignCast(context.?));
    const backend = file.backend orelse return runtime_vfs.Error.CorruptState;
    return backend.readFile(file, offset, output) catch |err| switch (err) {
        Error.IoFailure => runtime_vfs.Error.InputOutput,
        else => runtime_vfs.Error.CorruptState,
    };
}

const file_operations = runtime_vfs.PseudoOperations{ .read = readBackedFile };

const TestDevice = struct {
    image: []u8,
    reads: usize = 0,
};

fn testReadBlock(context: ?*anyopaque, lba: u64, output: []u8) bool {
    const device: *TestDevice = @ptrCast(@alignCast(context.?));
    const offset = std.math.mul(usize, std.math.cast(usize, lba) orelse return false, output.len) catch return false;
    if (offset > device.image.len or output.len > device.image.len - offset) return false;
    @memcpy(output, device.image[offset .. offset + output.len]);
    device.reads += 1;
    return true;
}

fn write16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}

fn write32(bytes: []u8, offset: usize, value: u32) void {
    write16(bytes, offset, @truncate(value));
    write16(bytes, offset + 2, @truncate(value >> 16));
}

fn setFat16(fat_bytes: []u8, cluster: u16, value: u16) void {
    write16(fat_bytes, @as(usize, cluster) * 2, value);
}

fn setDirectoryEntry(bytes: []u8, index: usize, name: *const [11]u8, attributes: u8, cluster: u16, size: u32) void {
    const offset = index * 32;
    @memcpy(bytes[offset .. offset + 11], name);
    bytes[offset + 11] = attributes;
    write16(bytes, offset + 26, cluster);
    write32(bytes, offset + 28, size);
}

test "read-only FAT16 backend imports directories and streams large files from blocks" {
    const block_size: usize = 512;
    const total_sectors: usize = 4200;
    const sectors_per_fat: usize = 17;
    const root_sectors: usize = 2;
    const first_fat = 1;
    const root_lba = first_fat + 2 * sectors_per_fat;
    const data_lba = root_lba + root_sectors;
    const image = try std.testing.allocator.alloc(u8, total_sectors * block_size);
    defer std.testing.allocator.free(image);
    @memset(image, 0);

    const boot = image[0..block_size];
    boot[0] = 0xEB;
    boot[1] = 0x3C;
    boot[2] = 0x90;
    @memcpy(boot[3..11], "ZIGOSFAT");
    write16(boot, 11, block_size);
    boot[13] = 1;
    write16(boot, 14, 1);
    boot[16] = 2;
    write16(boot, 17, 32);
    write16(boot, 19, total_sectors);
    boot[21] = 0xF8;
    write16(boot, 22, sectors_per_fat);
    boot[38] = 0x29;
    write32(boot, 39, 0x1234_5678);
    @memcpy(boot[43..54], "ZIGOSBOOT  ");
    @memcpy(boot[54..62], "FAT16   ");
    write16(boot, 510, 0xAA55);

    const fat1 = image[first_fat * block_size .. (first_fat + sectors_per_fat) * block_size];
    setFat16(fat1, 0, 0xFFF8);
    setFat16(fat1, 1, 0xFFFF);
    setFat16(fat1, 2, 0xFFFF);
    setFat16(fat1, 3, 0xFFFF);
    setFat16(fat1, 4, 5);
    setFat16(fat1, 5, 0xFFFF);
    setFat16(fat1, 6, 0xFFFF);
    var cluster: u16 = 7;
    while (cluster < 72) : (cluster += 1) setFat16(fat1, cluster, cluster + 1);
    setFat16(fat1, 72, 0xFFFF);
    @memcpy(image[(first_fat + sectors_per_fat) * block_size .. (first_fat + 2 * sectors_per_fat) * block_size], fat1);

    const root = image[root_lba * block_size .. (root_lba + root_sectors) * block_size];
    setDirectoryEntry(root, 0, &"EFI        ".*, 0x10, 2, 0);
    setDirectoryEntry(root, 1, &"README  TXT".*, 0x20, 4, 700);
    root[64] = 0;
    const efi_dir = image[(data_lba + 0) * block_size .. (data_lba + 1) * block_size];
    setDirectoryEntry(efi_dir, 0, &"BOOT       ".*, 0x10, 3, 0);
    efi_dir[32] = 0;
    const boot_dir = image[(data_lba + 1) * block_size .. (data_lba + 2) * block_size];
    setDirectoryEntry(boot_dir, 0, &"BOOT    CFG".*, 0x20, 6, 20);
    setDirectoryEntry(boot_dir, 1, &"BIG     BIN".*, 0x20, 7, 33_000);
    boot_dir[64] = 0;

    for (0..700) |index| image[(data_lba + 2) * block_size + index] = @truncate(index * 5 + 1);
    @memcpy(image[(data_lba + 4) * block_size .. (data_lba + 4) * block_size + 20], "block-backed-config\n");
    for (0..33_000) |index| image[(data_lba + 5) * block_size + index] = @truncate(index * 11 + 3);

    var device_context = TestDevice{ .image = image };
    var backend = Backend.init();
    var vfs = runtime_vfs.Vfs.init();
    _ = try vfs.mkdir(0, "/boot", 0o755, 0);
    const mount_id = try backend.mount(&vfs, "/boot", "memory-fat16", .{
        .context = &device_context,
        .block_size = block_size,
        .first_lba = 0,
        .sector_count = total_sectors,
        .read_fn = testReadBlock,
    }, 1);
    try std.testing.expectEqual(@as(u8, 2), mount_id);
    try std.testing.expectEqual(runtime_vfs.Kind.directory, (try vfs.stat(0, "/boot/EFI/BOOT")).kind);
    try std.testing.expectEqual(@as(usize, 33_000), (try vfs.stat(0, "/boot/EFI/BOOT/BIG.BIN")).size);

    var config: [32]u8 = undefined;
    const config_count = try vfs.read(0, "/boot/EFI/BOOT/BOOT.CFG", 0, &config);
    try std.testing.expectEqualStrings("block-backed-config\n", config[0..config_count]);
    var cross_boundary: [40]u8 = undefined;
    const boundary_offset: usize = runtime_vfs.maximum_file_size - 9;
    try std.testing.expectEqual(cross_boundary.len, try vfs.read(0, "/boot/EFI/BOOT/BIG.BIN", boundary_offset, &cross_boundary));
    for (cross_boundary, 0..) |byte, index| try std.testing.expectEqual(@as(u8, @truncate((boundary_offset + index) * 11 + 3)), byte);

    const handle = try vfs.open(9, 0, "/boot/EFI/BOOT/BIG.BIN", .{ .read = true }, 0, 2);
    try std.testing.expectEqual(@as(usize, 32_990), try vfs.seek(9, handle, -10, .end));
    var tail: [10]u8 = undefined;
    try std.testing.expectEqual(tail.len, try vfs.readOpen(9, handle, &tail));
    try vfs.close(9, handle);
    try std.testing.expectError(runtime_vfs.Error.ReadOnly, vfs.open(9, 0, "/boot/README.TXT", .{ .write = true }, 0, 3));

    const report = backend.report();
    try std.testing.expect(report.mounted);
    try std.testing.expectEqual(@as(usize, 3), report.files);
    try std.testing.expectEqual(@as(usize, 2), report.directories);
    try std.testing.expectEqual(@as(u64, 33_720), report.bytes);
    try std.testing.expect(report.metadata_reads > 0 and report.metadata_reads < 20);
    try std.testing.expect(report.file_reads >= 3 and report.blocks_read == device_context.reads);
    try std.testing.expectEqual(@as(u64, 0), report.failures);
    try std.testing.expectEqual(@as(u32, 71), report.claimed_clusters);
    try std.testing.expectEqual(@as(u64, 0), report.chain_loops);
    try std.testing.expectEqual(@as(u64, 0), report.cross_links);
    try std.testing.expectEqual(@as(u64, 0), report.out_of_range_links);
    try std.testing.expect(backend.validate());
    try std.testing.expect(vfs.validate());

    setFat16(fat1, 8, 7);
    @memcpy(image[(first_fat + sectors_per_fat) * block_size .. (first_fat + 2 * sectors_per_fat) * block_size], fat1);
    var loop_device = TestDevice{ .image = image };
    var loop_backend = Backend.init();
    var loop_vfs = runtime_vfs.Vfs.init();
    _ = try loop_vfs.mkdir(0, "/boot", 0o755, 0);
    try std.testing.expectError(Error.ChainLoop, loop_backend.mount(&loop_vfs, "/boot", "cyclic-fat16", .{
        .context = &loop_device,
        .block_size = block_size,
        .first_lba = 0,
        .sector_count = total_sectors,
        .read_fn = testReadBlock,
    }, 1));
    try std.testing.expect(loop_device.reads > 0);
    try std.testing.expectEqual(@as(u64, 1), loop_backend.report().chain_loops);

    setFat16(fat1, 8, 9);
    setDirectoryEntry(boot_dir, 0, &"BOOT    CFG".*, 0x20, 7, 20);
    @memcpy(image[(first_fat + sectors_per_fat) * block_size .. (first_fat + 2 * sectors_per_fat) * block_size], fat1);
    var cross_device = TestDevice{ .image = image };
    var cross_backend = Backend.init();
    var cross_vfs = runtime_vfs.Vfs.init();
    _ = try cross_vfs.mkdir(0, "/boot", 0o755, 0);
    try std.testing.expectError(Error.CrossLinkedCluster, cross_backend.mount(&cross_vfs, "/boot", "cross-linked-fat16", .{
        .context = &cross_device,
        .block_size = block_size,
        .first_lba = 0,
        .sector_count = total_sectors,
        .read_fn = testReadBlock,
    }, 1));
    try std.testing.expectEqual(@as(u64, 1), cross_backend.report().cross_links);

    setDirectoryEntry(boot_dir, 0, &"BOOT    CFG".*, 0x20, 6, 20);
    setFat16(fat1, 8, 0x7FFF);
    @memcpy(image[(first_fat + sectors_per_fat) * block_size .. (first_fat + 2 * sectors_per_fat) * block_size], fat1);
    var range_device = TestDevice{ .image = image };
    var range_backend = Backend.init();
    var range_vfs = runtime_vfs.Vfs.init();
    _ = try range_vfs.mkdir(0, "/boot", 0o755, 0);
    try std.testing.expectError(Error.OutOfRangeCluster, range_backend.mount(&range_vfs, "/boot", "out-of-range-fat16", .{
        .context = &range_device,
        .block_size = block_size,
        .first_lba = 0,
        .sector_count = total_sectors,
        .read_fn = testReadBlock,
    }, 1));
    try std.testing.expectEqual(@as(u64, 1), range_backend.report().out_of_range_links);
}
