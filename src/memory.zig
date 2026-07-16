const boot = @import("boot_info.zig");

pub const page_size: u64 = 4096;
pub const four_gib: u64 = 4 * 1024 * 1024 * 1024;

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

pub const FrameAllocator = struct {
    memory_map: boot.MemoryMapInfo,
    descriptor_index: usize = 0,
    current_frame: u64 = 0,
    current_region_end: u64 = 0,
    allocated_pages: u64 = 0,

    pub fn init(memory_map: boot.MemoryMapInfo) FrameAllocator {
        return .{ .memory_map = memory_map };
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

    fn loadNextRegion(self: *FrameAllocator, limit_exclusive: u64) bool {
        while (self.descriptor_index < self.memory_map.descriptor_count) {
            const entry = self.readDescriptor(self.descriptor_index);
            self.descriptor_index += 1;

            if (entry.memory_type != conventional_memory_type) continue;
            if (entry.number_of_pages == 0) continue;

            const descriptor_bytes = entry.number_of_pages *| page_size;
            const descriptor_end = entry.physical_start +| descriptor_bytes;
            var start = alignForward(entry.physical_start, page_size);
            if (start < minimum_allocatable_address) start = minimum_allocatable_address;
            const end = @min(descriptor_end, limit_exclusive);

            if (start >= end or end - start < page_size) continue;

            self.current_frame = start;
            self.current_region_end = alignBackward(end, page_size);
            if (self.current_frame < self.current_region_end) return true;
        }
        return false;
    }

    fn readDescriptor(self: *const FrameAllocator, index: usize) *const RawMemoryDescriptor {
        const address = self.memory_map.address + index * self.memory_map.descriptor_size;
        return @ptrFromInt(address);
    }
};

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
