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
        allocated_pages: u64,
    };

    layout: *const Layout,
    region_index: usize = 0,
    current_frame: u64 = 0,
    current_region_end: u64 = 0,
    allocated_pages: u64 = 0,

    pub fn checkpoint(self: *const FrameAllocator) Checkpoint {
        return .{
            .region_index = self.region_index,
            .current_frame = self.current_frame,
            .current_region_end = self.current_region_end,
            .allocated_pages = self.allocated_pages,
        };
    }

    pub fn restore(self: *FrameAllocator, saved: Checkpoint) bool {
        if (self.allocated_pages < saved.allocated_pages) return false;
        if (saved.region_index > self.layout.region_count or self.region_index < saved.region_index) return false;
        if ((saved.current_frame & (page_size - 1)) != 0 or (saved.current_region_end & (page_size - 1)) != 0) return false;
        if ((saved.current_frame == 0) != (saved.current_region_end == 0)) return false;
        if (saved.current_frame > saved.current_region_end) return false;
        if (self.region_index == saved.region_index and
            (self.current_region_end != saved.current_region_end or self.current_frame < saved.current_frame)) return false;
        self.region_index = saved.region_index;
        self.current_frame = saved.current_frame;
        self.current_region_end = saved.current_region_end;
        self.allocated_pages = saved.allocated_pages;
        return true;
    }

    pub fn init(layout: *const Layout) FrameAllocator {
        return .{ .layout = layout };
    }

    pub fn allocate(self: *FrameAllocator) ?usize {
        return self.allocateBelow(@as(u64, @intCast(~@as(usize, 0))));
    }

    pub fn allocateBelow(self: *FrameAllocator, limit_exclusive: u64) ?usize {
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
        if (page_count == 0) return null;
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
        while (self.region_index < self.layout.region_count) {
            const region = self.layout.regions[self.region_index];
            self.region_index += 1;
            if (region.kind != .usable) continue;

            var start = alignForward(region.base, page_size);
            if (start < minimum_allocatable_address) start = minimum_allocatable_address;
            const end = @min(region.end, limit_exclusive);
            if (start >= end or end - start < page_size) continue;

            self.current_frame = start;
            self.current_region_end = alignBackward(end, page_size);
            if (self.current_frame < self.current_region_end) return true;
        }
        return false;
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

comptime {
    if (@sizeOf(RawMemoryDescriptor) != 40) {
        @compileError("UEFI x86-64 memory descriptor layout changed unexpectedly");
    }
}
