const std = @import("std");

const block_alignment: usize = 16;
const allocation_magic: u64 = 0x5A49_474F_5348_4541;
const freed_magic: u64 = 0x4652_4545_4448_4541;

const FreeBlock = extern struct {
    size: usize,
    next: usize,
};

const AllocationHeader = extern struct {
    magic: u64,
    block_start: usize,
    block_size: usize,
    payload_size: usize,
};

pub const Statistics = struct {
    region_base: usize,
    region_size: usize,
    free_bytes: usize,
    allocated_bytes: usize,
    active_allocations: usize,
    total_allocations: usize,
    total_frees: usize,
};

pub const Heap = struct {
    region_base: usize,
    region_size: usize,
    free_head: usize,
    free_bytes: usize,
    allocated_bytes: usize = 0,
    active_allocations: usize = 0,
    total_allocations: usize = 0,
    total_frees: usize = 0,

    pub fn init(region_base: usize, region_size: usize) ?Heap {
        if ((region_base & (block_alignment - 1)) != 0) return null;
        const usable_size = alignBackward(region_size, block_alignment);
        if (usable_size < minimumFreeBlockSize()) return null;
        if (region_base > std.math.maxInt(usize) - usable_size) return null;

        const first = freeBlockAt(region_base);
        first.* = .{
            .size = usable_size,
            .next = 0,
        };

        return .{
            .region_base = region_base,
            .region_size = usable_size,
            .free_head = region_base,
            .free_bytes = usable_size,
        };
    }

    pub fn allocate(self: *Heap, requested_size: usize, requested_alignment: usize) ?[]u8 {
        if (requested_size == 0) return null;
        if (requested_alignment == 0 or !std.math.isPowerOfTwo(requested_alignment)) return null;
        const alignment = @max(requested_alignment, @alignOf(AllocationHeader));

        var previous_address: usize = 0;
        var current_address = self.free_head;
        while (current_address != 0) {
            const current = freeBlockAt(current_address);
            const block_end = current_address + current.size;
            const minimum_payload = current_address + @sizeOf(FreeBlock) + @sizeOf(AllocationHeader);
            const payload_address = alignForward(minimum_payload, alignment) orelse return null;
            if (payload_address >= block_end or requested_size > block_end - payload_address) {
                previous_address = current_address;
                current_address = current.next;
                continue;
            }

            const raw_end = payload_address + requested_size;
            const aligned_end = alignForward(raw_end, block_alignment) orelse return null;
            if (aligned_end > block_end) {
                previous_address = current_address;
                current_address = current.next;
                continue;
            }

            var consumed_size = aligned_end - current_address;
            var replacement_address: usize = 0;
            const remaining_size = block_end - aligned_end;
            if (remaining_size >= minimumFreeBlockSize()) {
                replacement_address = aligned_end;
                freeBlockAt(replacement_address).* = .{
                    .size = remaining_size,
                    .next = current.next,
                };
            } else {
                consumed_size = current.size;
                replacement_address = current.next;
            }

            if (previous_address == 0) {
                self.free_head = replacement_address;
            } else {
                freeBlockAt(previous_address).next = replacement_address;
            }

            const header_address = payload_address - @sizeOf(AllocationHeader);
            allocationHeaderAt(header_address).* = .{
                .magic = allocation_magic,
                .block_start = current_address,
                .block_size = consumed_size,
                .payload_size = requested_size,
            };

            self.free_bytes -= consumed_size;
            self.allocated_bytes += consumed_size;
            self.active_allocations += 1;
            self.total_allocations += 1;
            return @as([*]u8, @ptrFromInt(payload_address))[0..requested_size];
        }

        return null;
    }

    pub fn free(self: *Heap, payload: []u8) bool {
        if (payload.len == 0) return false;
        const payload_address = @intFromPtr(payload.ptr);
        if (payload_address < self.region_base + @sizeOf(AllocationHeader)) return false;
        if (payload_address >= self.region_base + self.region_size) return false;

        const header_address = payload_address - @sizeOf(AllocationHeader);
        const header = allocationHeaderAt(header_address);
        if (header.magic != allocation_magic) return false;
        if (header.payload_size != payload.len) return false;
        if (header.block_start < self.region_base) return false;
        if (header.block_size < minimumFreeBlockSize()) return false;
        const region_end = self.region_base + self.region_size;
        if (header.block_start > region_end - header.block_size) return false;

        const block_start = header.block_start;
        const block_size = header.block_size;
        header.magic = freed_magic;
        insertFreeBlock(self, block_start, block_size);

        self.free_bytes += block_size;
        self.allocated_bytes -= block_size;
        self.active_allocations -= 1;
        self.total_frees += 1;
        return true;
    }

    pub fn statistics(self: *const Heap) Statistics {
        return .{
            .region_base = self.region_base,
            .region_size = self.region_size,
            .free_bytes = self.free_bytes,
            .allocated_bytes = self.allocated_bytes,
            .active_allocations = self.active_allocations,
            .total_allocations = self.total_allocations,
            .total_frees = self.total_frees,
        };
    }

    pub fn validate(self: *const Heap) bool {
        var total_free: usize = 0;
        var previous_end = self.region_base;
        var current_address = self.free_head;
        var visited: usize = 0;

        while (current_address != 0) {
            if (visited > self.region_size / minimumFreeBlockSize()) return false;
            visited += 1;
            if (current_address < self.region_base or current_address >= self.region_base + self.region_size) return false;
            if ((current_address & (block_alignment - 1)) != 0) return false;

            const block = freeBlockAt(current_address);
            if (block.size < minimumFreeBlockSize()) return false;
            if ((block.size & (block_alignment - 1)) != 0) return false;
            const region_end = self.region_base + self.region_size;
            if (current_address > region_end - block.size) return false;
            if (current_address < previous_end) return false;

            total_free += block.size;
            previous_end = current_address + block.size;
            current_address = block.next;
        }

        return total_free == self.free_bytes and self.free_bytes + self.allocated_bytes == self.region_size;
    }
};

fn insertFreeBlock(heap: *Heap, block_start: usize, block_size: usize) void {
    var previous_address: usize = 0;
    var current_address = heap.free_head;
    while (current_address != 0 and current_address < block_start) {
        previous_address = current_address;
        current_address = freeBlockAt(current_address).next;
    }

    const inserted = freeBlockAt(block_start);
    inserted.* = .{
        .size = block_size,
        .next = current_address,
    };

    if (previous_address == 0) {
        heap.free_head = block_start;
    } else {
        freeBlockAt(previous_address).next = block_start;
    }

    if (current_address != 0 and block_start + inserted.size == current_address) {
        const next = freeBlockAt(current_address);
        inserted.size += next.size;
        inserted.next = next.next;
    }

    if (previous_address != 0) {
        const previous = freeBlockAt(previous_address);
        if (previous_address + previous.size == block_start) {
            previous.size += inserted.size;
            previous.next = inserted.next;
        }
    }
}

fn freeBlockAt(address: usize) *FreeBlock {
    return @ptrFromInt(address);
}

fn allocationHeaderAt(address: usize) *AllocationHeader {
    return @ptrFromInt(address);
}

fn alignForward(value: usize, alignment: usize) ?usize {
    const mask = alignment - 1;
    if (value > std.math.maxInt(usize) - mask) return null;
    return (value + mask) & ~mask;
}

fn alignBackward(value: usize, alignment: usize) usize {
    return value & ~(alignment - 1);
}

fn minimumFreeBlockSize() usize {
    return alignForward(@sizeOf(FreeBlock) + @sizeOf(AllocationHeader) + 1, block_alignment) orelse unreachable;
}

comptime {
    if (@sizeOf(FreeBlock) != 16) @compileError("free-list block header must remain 16 bytes");
    if (@sizeOf(AllocationHeader) != 32) @compileError("allocation header must remain 32 bytes");
}
