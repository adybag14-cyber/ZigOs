const std = @import("std");
const boot = @import("boot_info.zig");

pub const page_size: u64 = 4096;
pub const four_gib: u64 = 4 * 1024 * 1024 * 1024;
pub const maximum_regions: usize = 512;

const conventional_memory_type: u32 = 7;
const minimum_allocatable_address: u64 = 0x0010_0000;

const RawMemoryDescriptor = extern struct {
    memory_type: u32,
    _padding: u32,
    physical_start: u64,
    virtual_start: u64,
    number_of_pages: u64,
    attributes: u64,
};

pub const RegionKind = enum {
    usable,
    loader,
    boot_services,
    runtime_services,
    acpi_reclaimable,
    acpi_nvs,
    mmio,
    persistent,
    unaccepted,
    reserved,
};

pub const Region = struct {
    base: u64,
    end: u64,
    kind: RegionKind,
    memory_type: u32,
    attributes: u64,

    pub fn size(self: Region) u64 {
        return self.end - self.base;
    }
};

pub const Layout = struct {
    regions: [maximum_regions]Region,
    region_count: usize,
    descriptor_count: usize,
    usable_region_count: usize,
    usable_bytes: u64,
    reclaimable_bytes: u64,
    runtime_bytes: u64,
    acpi_nvs_bytes: u64,
    mmio_bytes: u64,
    persistent_bytes: u64,
    unaccepted_bytes: u64,
    reserved_bytes: u64,
    highest_address: u64,

    pub fn overlapsUsable(self: *const Layout, base: usize, size: usize) bool {
        if (size == 0) return false;
        const start: u64 = @intCast(base);
        const length: u64 = @intCast(size);
        if (start > std.math.maxInt(u64) - length) return true;
        const end = start + length;
        for (self.regions[0..self.region_count]) |region| {
            if (region.kind != .usable) continue;
            if (start < region.end and end > region.base) return true;
        }
        return false;
    }

    pub fn countKind(self: *const Layout, kind: RegionKind) usize {
        var count: usize = 0;
        for (self.regions[0..self.region_count]) |region| {
            if (region.kind == kind) count += 1;
        }
        return count;
    }
};

pub fn parseLayout(memory_map: boot.MemoryMapInfo) ?Layout {
    if (memory_map.descriptor_count == 0 or
        memory_map.descriptor_count > maximum_regions or
        memory_map.descriptor_size < @sizeOf(RawMemoryDescriptor))
    {
        return null;
    }

    var collected: [maximum_regions]Region = undefined;
    var collected_count: usize = 0;
    var index: usize = 0;
    while (index < memory_map.descriptor_count) : (index += 1) {
        const descriptor = readDescriptor(memory_map, index);
        if (descriptor.number_of_pages == 0) continue;
        if ((descriptor.physical_start & (page_size - 1)) != 0) return null;
        if (descriptor.number_of_pages > std.math.maxInt(u64) / page_size) return null;
        const bytes = descriptor.number_of_pages * page_size;
        if (descriptor.physical_start > std.math.maxInt(u64) - bytes) return null;
        if (collected_count >= collected.len) return null;
        collected[collected_count] = .{
            .base = descriptor.physical_start,
            .end = descriptor.physical_start + bytes,
            .kind = classify(descriptor.memory_type),
            .memory_type = descriptor.memory_type,
            .attributes = descriptor.attributes,
        };
        collected_count += 1;
    }
    if (collected_count == 0) return null;

    insertionSort(collected[0..collected_count]);

    var layout = Layout{
        .regions = undefined,
        .region_count = 0,
        .descriptor_count = memory_map.descriptor_count,
        .usable_region_count = 0,
        .usable_bytes = 0,
        .reclaimable_bytes = 0,
        .runtime_bytes = 0,
        .acpi_nvs_bytes = 0,
        .mmio_bytes = 0,
        .persistent_bytes = 0,
        .unaccepted_bytes = 0,
        .reserved_bytes = 0,
        .highest_address = 0,
    };

    var previous_end: u64 = 0;
    for (collected[0..collected_count]) |region| {
        if (layout.region_count != 0 and region.base < previous_end) return null;
        previous_end = region.end;
        if (!accumulateTotals(&layout, region)) return null;
        if (region.end > layout.highest_address) layout.highest_address = region.end;

        if (layout.region_count != 0) {
            const previous = &layout.regions[layout.region_count - 1];
            if (previous.end == region.base and
                previous.kind == region.kind and
                previous.memory_type == region.memory_type and
                previous.attributes == region.attributes)
            {
                previous.end = region.end;
                continue;
            }
        }
        if (layout.region_count >= layout.regions.len) return null;
        layout.regions[layout.region_count] = region;
        layout.region_count += 1;
    }
    return layout;
}

pub const FrameAllocator = struct {
    pub const Checkpoint = struct {
        region_index: usize,
        current_frame: u64,
        current_region_end: u64,
        current_region_full_end: u64,
        allocated_pages: u64,
    };

    layout: *const Layout,
    region_index: usize = 0,
    current_frame: u64 = 0,
    current_region_end: u64 = 0,
    current_region_full_end: u64 = 0,
    allocated_pages: u64 = 0,
    sealed: bool = false,

    pub fn checkpoint(self: *const FrameAllocator) Checkpoint {
        return .{
            .region_index = self.region_index,
            .current_frame = self.current_frame,
            .current_region_end = self.current_region_end,
            .current_region_full_end = self.current_region_full_end,
            .allocated_pages = self.allocated_pages,
        };
    }

    pub fn restore(self: *FrameAllocator, saved: Checkpoint) bool {
        if (self.sealed or self.allocated_pages < saved.allocated_pages) return false;
        if (saved.region_index > self.layout.region_count or self.region_index < saved.region_index) return false;
        if ((saved.current_frame & (page_size - 1)) != 0 or
            (saved.current_region_end & (page_size - 1)) != 0 or
            (saved.current_region_full_end & (page_size - 1)) != 0) return false;
        if ((saved.current_frame == 0) != (saved.current_region_full_end == 0)) return false;
        if (saved.current_frame > saved.current_region_end or saved.current_region_end > saved.current_region_full_end) return false;
        if (self.region_index == saved.region_index and
            (self.current_region_full_end != saved.current_region_full_end or
                self.current_region_end < saved.current_region_end or
                self.current_frame < saved.current_frame)) return false;
        self.region_index = saved.region_index;
        self.current_frame = saved.current_frame;
        self.current_region_end = saved.current_region_end;
        self.current_region_full_end = saved.current_region_full_end;
        self.allocated_pages = saved.allocated_pages;
        return true;
    }

    pub fn init(layout: *const Layout) FrameAllocator {
        return .{ .layout = layout };
    }

    pub fn allocate(self: *FrameAllocator) ?usize {
        if (self.sealed) return null;
        return self.allocateBelow(@as(u64, @intCast(~@as(usize, 0))));
    }

    pub fn allocateBelow(self: *FrameAllocator, limit_exclusive: u64) ?usize {
        if (self.sealed or limit_exclusive < page_size) return null;
        while (true) {
            if (self.current_frame < self.current_region_end and
                self.current_frame <= limit_exclusive -| page_size)
            {
                const frame = self.current_frame;
                self.current_frame += page_size;
                self.allocated_pages += 1;
                return @intCast(frame);
            }

            if (!self.loadNextRegion(limit_exclusive)) return null;
        }
    }

    pub fn allocateContiguousBelow(self: *FrameAllocator, page_count: usize, limit_exclusive: u64) ?usize {
        if (self.sealed or page_count == 0) return null;
        const byte_count = @as(u64, @intCast(page_count)) *| page_size;
        if (byte_count == 0 or byte_count > limit_exclusive) return null;

        while (true) {
            if (self.current_frame < self.current_region_end and
                byte_count <= self.current_region_end - self.current_frame and
                self.current_frame <= limit_exclusive - byte_count)
            {
                const base = self.current_frame;
                self.current_frame += byte_count;
                self.allocated_pages += @intCast(page_count);
                return @intCast(base);
            }

            if (!self.loadNextRegion(limit_exclusive)) return null;
        }
    }

    fn loadNextRegion(self: *FrameAllocator, limit_exclusive: u64) bool {
        if (self.current_frame < self.current_region_full_end) {
            const extended_end = alignBackward(@min(self.current_region_full_end, limit_exclusive), page_size);
            if (self.current_frame < extended_end) {
                self.current_region_end = extended_end;
                return true;
            }
            return false;
        }

        while (self.region_index < self.layout.region_count) {
            const region = self.layout.regions[self.region_index];
            self.region_index += 1;
            if (region.kind != .usable) continue;

            var start = alignForward(region.base, page_size);
            if (start < minimum_allocatable_address) start = minimum_allocatable_address;
            const full_end = alignBackward(region.end, page_size);
            if (start >= full_end) continue;

            self.current_frame = start;
            self.current_region_full_end = full_end;
            self.current_region_end = alignBackward(@min(full_end, limit_exclusive), page_size);
            if (self.current_frame < self.current_region_end) return true;

            // The sorted layout has reached a usable extent above this address limit.
            // Keep it as the current deferred extent so a later wider allocation or
            // the post-bootstrap handoff can recover every untouched page.
            return false;
        }
        return false;
    }
};

pub const maximum_physical_extents: usize = 1024;

pub const PhysicalExtent = struct {
    base: u64,
    end: u64,

    pub fn pageCount(self: PhysicalExtent) u64 {
        return (self.end - self.base) / page_size;
    }
};

pub const PhysicalMemoryError = error{
    InvalidAddress,
    DoubleFree,
    MetadataExhausted,
};

pub const PhysicalMemoryReport = struct {
    total_pages: u64,
    free_pages: u64,
    allocated_pages: u64,
    low_pages: u64,
    high_pages: u64,
    managed_extents: usize,
    free_extents: usize,
    peak_allocated_pages: u64,
    allocations: u64,
    frees: u64,
    failed_allocations: u64,
    invalid_frees: u64,
    double_frees: u64,
    metadata_failures: u64,
    clean: bool,
};

pub const PhysicalMemoryManager = struct {
    managed: [maximum_regions]PhysicalExtent = undefined,
    managed_count: usize = 0,
    free_extents: [maximum_physical_extents]PhysicalExtent = undefined,
    free_count: usize = 0,
    total_pages: u64 = 0,
    free_pages: u64 = 0,
    low_pages: u64 = 0,
    high_pages: u64 = 0,
    peak_allocated_pages: u64 = 0,
    allocations: u64 = 0,
    frees: u64 = 0,
    failed_allocations: u64 = 0,
    invalid_frees: u64 = 0,
    double_frees: u64 = 0,
    metadata_failures: u64 = 0,

    pub fn initializeFromBootstrap(self: *PhysicalMemoryManager, bootstrap: *FrameAllocator) bool {
        if (bootstrap.sealed) return false;
        self.* = .{};
        const current_region_index: ?usize = if (bootstrap.current_region_full_end != 0 and bootstrap.region_index != 0)
            bootstrap.region_index - 1
        else
            null;

        for (bootstrap.layout.regions[0..bootstrap.layout.region_count], 0..) |region, index| {
            if (region.kind != .usable) continue;
            var start = alignForward(region.base, page_size);
            if (start < minimum_allocatable_address) start = minimum_allocatable_address;

            if (current_region_index) |current_index| {
                if (index < current_index) continue;
                if (index == current_index) {
                    start = @max(start, bootstrap.current_frame);
                } else if (index < bootstrap.region_index) {
                    continue;
                }
            } else if (index < bootstrap.region_index) {
                continue;
            }

            const end = alignBackward(region.end, page_size);
            if (start >= end) continue;
            if (!self.appendInitialExtent(.{ .base = start, .end = end })) return false;
        }
        if (self.total_pages == 0) return false;
        bootstrap.sealed = true;
        return true;
    }

    pub fn initForTesting(extents: []const PhysicalExtent) ?PhysicalMemoryManager {
        var self = PhysicalMemoryManager{};
        for (extents) |extent| {
            if (!self.appendInitialExtent(extent)) return null;
        }
        return if (self.total_pages == 0) null else self;
    }

    pub fn allocate(self: *PhysicalMemoryManager) ?usize {
        return self.allocateBelow(std.math.maxInt(u64));
    }

    pub fn allocateBelow(self: *PhysicalMemoryManager, limit_exclusive: u64) ?usize {
        return self.allocateContiguousBelow(1, limit_exclusive);
    }

    pub fn allocateContiguousBelow(
        self: *PhysicalMemoryManager,
        page_count: usize,
        limit_exclusive: u64,
    ) ?usize {
        if (page_count == 0 or limit_exclusive < page_size) return self.rejectAllocation();
        const byte_count = std.math.mul(u64, @intCast(page_count), page_size) catch return self.rejectAllocation();
        if (byte_count > limit_exclusive) return self.rejectAllocation();

        var index: usize = 0;
        while (index < self.free_count) : (index += 1) {
            const extent = self.free_extents[index];
            const available_end = @min(extent.end, limit_exclusive);
            if (extent.base >= available_end or byte_count > available_end - extent.base) continue;

            const base = extent.base;
            self.free_extents[index].base += byte_count;
            if (self.free_extents[index].base == self.free_extents[index].end) self.removeFreeExtent(index);
            const pages: u64 = @intCast(page_count);
            self.free_pages -= pages;
            self.allocations +|= pages;
            self.peak_allocated_pages = @max(self.peak_allocated_pages, self.total_pages - self.free_pages);
            return @intCast(base);
        }
        return self.rejectAllocation();
    }

    pub fn free(self: *PhysicalMemoryManager, address: usize) PhysicalMemoryError!void {
        const base: u64 = @intCast(address);
        if (base == 0 or (base & (page_size - 1)) != 0 or base > std.math.maxInt(u64) - page_size) {
            return self.rejectInvalidFree();
        }
        const end = base + page_size;
        if (!self.containsManaged(base, end)) return self.rejectInvalidFree();
        if (self.containsFree(base, end)) return self.rejectDoubleFree();

        var position: usize = 0;
        while (position < self.free_count and self.free_extents[position].base < base) : (position += 1) {}
        const merge_previous = position != 0 and self.free_extents[position - 1].end == base;
        const merge_next = position < self.free_count and self.free_extents[position].base == end;

        if (merge_previous and merge_next) {
            self.free_extents[position - 1].end = self.free_extents[position].end;
            self.removeFreeExtent(position);
        } else if (merge_previous) {
            self.free_extents[position - 1].end = end;
        } else if (merge_next) {
            self.free_extents[position].base = base;
        } else {
            if (self.free_count >= self.free_extents.len) {
                self.metadata_failures +|= 1;
                return PhysicalMemoryError.MetadataExhausted;
            }
            var cursor = self.free_count;
            while (cursor > position) : (cursor -= 1) self.free_extents[cursor] = self.free_extents[cursor - 1];
            self.free_extents[position] = .{ .base = base, .end = end };
            self.free_count += 1;
        }
        self.free_pages += 1;
        self.frees +|= 1;
    }

    pub fn report(self: *const PhysicalMemoryManager) PhysicalMemoryReport {
        const allocated = self.total_pages - self.free_pages;
        return .{
            .total_pages = self.total_pages,
            .free_pages = self.free_pages,
            .allocated_pages = allocated,
            .low_pages = self.low_pages,
            .high_pages = self.high_pages,
            .managed_extents = self.managed_count,
            .free_extents = self.free_count,
            .peak_allocated_pages = self.peak_allocated_pages,
            .allocations = self.allocations,
            .frees = self.frees,
            .failed_allocations = self.failed_allocations,
            .invalid_frees = self.invalid_frees,
            .double_frees = self.double_frees,
            .metadata_failures = self.metadata_failures,
            .clean = allocated == 0 and self.allocations == self.frees,
        };
    }

    fn appendInitialExtent(self: *PhysicalMemoryManager, raw: PhysicalExtent) bool {
        const base = alignForward(raw.base, page_size);
        const end = alignBackward(raw.end, page_size);
        if (base < minimum_allocatable_address or base >= end) return false;
        if (self.managed_count >= self.managed.len or self.free_count >= self.free_extents.len) return false;
        if (self.managed_count != 0 and self.managed[self.managed_count - 1].end > base) return false;

        if (self.managed_count != 0 and self.managed[self.managed_count - 1].end == base) {
            self.managed[self.managed_count - 1].end = end;
            self.free_extents[self.free_count - 1].end = end;
        } else {
            self.managed[self.managed_count] = .{ .base = base, .end = end };
            self.managed_count += 1;
            self.free_extents[self.free_count] = .{ .base = base, .end = end };
            self.free_count += 1;
        }

        const pages = (end - base) / page_size;
        self.total_pages += pages;
        self.free_pages += pages;
        const low_end = @min(end, four_gib);
        if (base < low_end) self.low_pages += (low_end - base) / page_size;
        const high_start = @max(base, four_gib);
        if (high_start < end) self.high_pages += (end - high_start) / page_size;
        return true;
    }

    fn containsManaged(self: *const PhysicalMemoryManager, base: u64, end: u64) bool {
        for (self.managed[0..self.managed_count]) |extent| {
            if (base >= extent.base and end <= extent.end) return true;
        }
        return false;
    }

    fn containsFree(self: *const PhysicalMemoryManager, base: u64, end: u64) bool {
        for (self.free_extents[0..self.free_count]) |extent| {
            if (base >= extent.base and end <= extent.end) return true;
            if (extent.base > base) break;
        }
        return false;
    }

    fn removeFreeExtent(self: *PhysicalMemoryManager, index: usize) void {
        var cursor = index;
        while (cursor + 1 < self.free_count) : (cursor += 1) self.free_extents[cursor] = self.free_extents[cursor + 1];
        self.free_count -= 1;
    }

    fn rejectAllocation(self: *PhysicalMemoryManager) ?usize {
        self.failed_allocations +|= 1;
        return null;
    }

    fn rejectInvalidFree(self: *PhysicalMemoryManager) PhysicalMemoryError {
        self.invalid_frees +|= 1;
        return PhysicalMemoryError.InvalidAddress;
    }

    fn rejectDoubleFree(self: *PhysicalMemoryManager) PhysicalMemoryError {
        self.double_frees +|= 1;
        return PhysicalMemoryError.DoubleFree;
    }
};

fn readDescriptor(memory_map: boot.MemoryMapInfo, index: usize) *const RawMemoryDescriptor {
    const address = memory_map.address + index * memory_map.descriptor_size;
    return @ptrFromInt(address);
}

fn classify(memory_type: u32) RegionKind {
    return switch (memory_type) {
        conventional_memory_type => .usable,
        1, 2 => .loader,
        3, 4 => .boot_services,
        5, 6 => .runtime_services,
        9 => .acpi_reclaimable,
        10 => .acpi_nvs,
        11, 12 => .mmio,
        14 => .persistent,
        15 => .unaccepted,
        else => .reserved,
    };
}

fn insertionSort(regions: []Region) void {
    var index: usize = 1;
    while (index < regions.len) : (index += 1) {
        const value = regions[index];
        var cursor = index;
        while (cursor > 0 and regions[cursor - 1].base > value.base) : (cursor -= 1) {
            regions[cursor] = regions[cursor - 1];
        }
        regions[cursor] = value;
    }
}

fn accumulateTotals(layout: *Layout, region: Region) bool {
    const bytes = region.size();
    switch (region.kind) {
        .usable => {
            if (!addChecked(&layout.usable_bytes, bytes)) return false;
            layout.usable_region_count += 1;
        },
        .loader, .boot_services, .acpi_reclaimable => {
            if (!addChecked(&layout.reclaimable_bytes, bytes)) return false;
        },
        .runtime_services => if (!addChecked(&layout.runtime_bytes, bytes)) return false,
        .acpi_nvs => if (!addChecked(&layout.acpi_nvs_bytes, bytes)) return false,
        .mmio => if (!addChecked(&layout.mmio_bytes, bytes)) return false,
        .persistent => if (!addChecked(&layout.persistent_bytes, bytes)) return false,
        .unaccepted => if (!addChecked(&layout.unaccepted_bytes, bytes)) return false,
        .reserved => if (!addChecked(&layout.reserved_bytes, bytes)) return false,
    }
    return true;
}

fn addChecked(total: *u64, amount: u64) bool {
    if (total.* > std.math.maxInt(u64) - amount) return false;
    total.* += amount;
    return true;
}

fn alignForward(value: u64, alignment: u64) u64 {
    return (value +| (alignment - 1)) & ~(alignment - 1);
}

fn alignBackward(value: u64, alignment: u64) u64 {
    return value & ~(alignment - 1);
}

test "physical manager handoff preserves low and high remaining regions" {
    var layout = Layout{
        .regions = undefined,
        .region_count = 2,
        .descriptor_count = 2,
        .usable_region_count = 2,
        .usable_bytes = 7 * page_size,
        .reclaimable_bytes = 0,
        .runtime_bytes = 0,
        .acpi_nvs_bytes = 0,
        .mmio_bytes = 0,
        .persistent_bytes = 0,
        .unaccepted_bytes = 0,
        .reserved_bytes = 0,
        .highest_address = four_gib + 3 * page_size,
    };
    layout.regions[0] = .{ .base = four_gib - 4 * page_size, .end = four_gib + 2 * page_size, .kind = .usable, .memory_type = conventional_memory_type, .attributes = 0 };
    layout.regions[1] = .{ .base = four_gib + 4 * page_size, .end = four_gib + 5 * page_size, .kind = .usable, .memory_type = conventional_memory_type, .attributes = 0 };
    var bootstrap = FrameAllocator.init(&layout);
    inline for (0..4) |index| {
        try std.testing.expectEqual(@as(usize, @intCast(four_gib - (4 - index) * page_size)), bootstrap.allocateBelow(four_gib).?);
    }
    try std.testing.expect(bootstrap.allocateBelow(four_gib) == null);
    var manager: PhysicalMemoryManager = undefined;
    try std.testing.expect(manager.initializeFromBootstrap(&bootstrap));
    const report = manager.report();
    try std.testing.expectEqual(@as(u64, 3), report.total_pages);
    try std.testing.expectEqual(@as(u64, 0), report.low_pages);
    try std.testing.expectEqual(@as(u64, 3), report.high_pages);
    try std.testing.expect(bootstrap.allocateBelow(four_gib) == null);
}

test "physical manager supports arbitrary free and immediate reuse" {
    const extents = [_]PhysicalExtent{.{ .base = 0x0020_0000, .end = 0x0020_4000 }};
    var manager = PhysicalMemoryManager.initForTesting(&extents).?;
    const first = manager.allocateBelow(four_gib).?;
    const second = manager.allocateBelow(four_gib).?;
    try std.testing.expectEqual(@as(usize, 0x0020_0000), first);
    try std.testing.expectEqual(@as(usize, 0x0020_1000), second);
    try manager.free(first);
    try std.testing.expectEqual(first, manager.allocateBelow(four_gib).?);
    try manager.free(second);
    try manager.free(first);
    const report = manager.report();
    try std.testing.expectEqual(@as(u64, 3), report.allocations);
    try std.testing.expectEqual(@as(u64, 3), report.frees);
    try std.testing.expect(report.clean);
}

test "physical manager merges fragmented releases" {
    const extents = [_]PhysicalExtent{.{ .base = 0x0030_0000, .end = 0x0030_4000 }};
    var manager = PhysicalMemoryManager.initForTesting(&extents).?;
    var pages: [4]usize = undefined;
    for (&pages) |*page| page.* = manager.allocate().?;
    try manager.free(pages[1]);
    try manager.free(pages[3]);
    try manager.free(pages[0]);
    try manager.free(pages[2]);
    const report = manager.report();
    try std.testing.expectEqual(@as(usize, 1), report.free_extents);
    try std.testing.expectEqual(@as(u64, 4), report.free_pages);
    try std.testing.expect(report.clean);
}

test "physical manager enforces limits and rejects invalid releases" {
    const extents = [_]PhysicalExtent{
        .{ .base = 0x0040_0000, .end = 0x0040_2000 },
        .{ .base = four_gib, .end = four_gib + 2 * page_size },
    };
    var manager = PhysicalMemoryManager.initForTesting(&extents).?;
    const low = manager.allocateBelow(four_gib).?;
    _ = manager.allocateBelow(four_gib).?;
    try std.testing.expect(manager.allocateBelow(four_gib) == null);
    const high = manager.allocate().?;
    try std.testing.expect(@as(u64, @intCast(high)) >= four_gib);
    try std.testing.expectError(PhysicalMemoryError.InvalidAddress, manager.free(low + 1));
    try manager.free(low);
    try std.testing.expectError(PhysicalMemoryError.DoubleFree, manager.free(low));
    try manager.free(high);
    const report = manager.report();
    try std.testing.expectEqual(@as(u64, 1), report.failed_allocations);
    try std.testing.expectEqual(@as(u64, 1), report.invalid_frees);
    try std.testing.expectEqual(@as(u64, 1), report.double_frees);
}

comptime {
    if (@sizeOf(RawMemoryDescriptor) != 40) {
        @compileError("UEFI x86-64 memory descriptor layout changed unexpectedly");
    }
}
