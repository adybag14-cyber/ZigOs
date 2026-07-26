const std = @import("std");
const memory = @import("memory.zig");

pub const page_bytes: usize = 4096;
pub const maximum_pages: usize = 4096;
pub const poison_byte: u8 = 0xA5;

pub const Error = error{
    InvalidConfiguration,
    InvalidAddress,
    DoubleFree,
    OwnerMismatch,
    ReferenceOverflow,
    BackingAllocatorFailure,
};

pub const State = enum(u8) {
    free,
    exclusive,
    shared,
};

pub const ReleaseResult = enum(u8) {
    retained,
    freed,
};

pub const Entry = struct {
    state: State = .free,
    address: usize = 0,
    owner: u64 = 0,
    references: u32 = 0,
    generation: u32 = 0,
};

pub const Report = struct {
    capacity: usize,
    active: usize,
    shared: usize,
    peak: usize,
    allocations: u64,
    releases: u64,
    frees: u64,
    retains: u64,
    out_of_memory: u64,
    invalid_addresses: u64,
    double_frees: u64,
    owner_mismatches: u64,
    reference_overflows: u64,
    backing_failures: u64,
    clean: bool,
};

pub const Pool = struct {
    base: usize = 0,
    page_count: usize = 0,
    manager: ?*memory.PhysicalMemoryManager = null,
    limit_exclusive: u64 = std.math.maxInt(u64),
    poison_on_free: bool = false,
    entries: [maximum_pages]Entry = @splat(.{}),
    active: usize = 0,
    shared: usize = 0,
    peak: usize = 0,
    allocations: u64 = 0,
    releases: u64 = 0,
    frees: u64 = 0,
    retains: u64 = 0,
    out_of_memory: u64 = 0,
    invalid_addresses: u64 = 0,
    double_frees: u64 = 0,
    owner_mismatches: u64 = 0,
    reference_overflows: u64 = 0,
    backing_failures: u64 = 0,

    pub fn init(base: usize, page_count: usize) Error!Pool {
        var self = Pool{};
        try self.initialize(base, page_count);
        return self;
    }

    pub fn initialize(self: *Pool, base: usize, page_count: usize) Error!void {
        if (base == 0 or (base & (page_bytes - 1)) != 0 or page_count == 0 or page_count > maximum_pages) {
            return Error.InvalidConfiguration;
        }
        if (page_count > (std.math.maxInt(usize) - base) / page_bytes) return Error.InvalidConfiguration;
        self.* = .{};
        self.base = base;
        self.page_count = page_count;
    }

    pub fn initializeManager(
        self: *Pool,
        manager: *memory.PhysicalMemoryManager,
        page_count: usize,
        limit_exclusive: u64,
        poison_on_free: bool,
    ) Error!void {
        if (page_count == 0 or page_count > maximum_pages or limit_exclusive < page_bytes) {
            return Error.InvalidConfiguration;
        }
        self.* = .{};
        self.manager = manager;
        self.page_count = page_count;
        self.limit_exclusive = limit_exclusive;
        self.poison_on_free = poison_on_free;
    }

    pub fn initialized(self: *const Pool) bool {
        return self.page_count != 0 and (self.base != 0 or self.manager != null);
    }

    pub fn allocate(self: *Pool, owner: u64) ?usize {
        if (owner == 0) {
            self.owner_mismatches +|= 1;
            return null;
        }
        var first_free: ?usize = null;
        for (self.entries[0..self.page_count], 0..) |entry, index| {
            if (entry.state == .free and first_free == null) first_free = index;
        }
        const available_index = first_free orelse {
            self.out_of_memory +|= 1;
            return null;
        };

        var index = available_index;
        const address = if (self.manager) |manager| blk: {
            const physical = manager.allocateBelow(self.limit_exclusive) orelse {
                self.out_of_memory +|= 1;
                return null;
            };
            // Never zero a page that the ownership table still considers live.
            // If the backing allocator exposes such an address, consuming its
            // allocation repairs the backing free set while preserving the
            // original live owner; the new allocation fails transactionally.
            for (self.entries[0..self.page_count]) |entry| {
                if (entry.state != .free and entry.address == physical) {
                    self.backing_failures +|= 1;
                    return null;
                }
            }
            // A released manager page may be returned in a different order from
            // metadata slots. Prefer the entry that already remembers this exact
            // address, then erase any stale duplicate memories.
            for (self.entries[0..self.page_count], 0..) |entry, candidate| {
                if (entry.state == .free and entry.address == physical) {
                    index = candidate;
                    break;
                }
            }
            for (self.entries[0..self.page_count], 0..) |*entry, candidate| {
                if (candidate != index and entry.state == .free and entry.address == physical) entry.address = 0;
            }
            break :blk physical;
        } else self.base + index * page_bytes;

        const entry = &self.entries[index];
        entry.state = .exclusive;
        entry.address = address;
        entry.owner = owner;
        entry.references = 1;
        entry.generation = nextGeneration(entry.generation);
        self.active += 1;
        self.peak = @max(self.peak, self.active);
        self.allocations +|= 1;
        return address;
    }

    pub fn retainShared(self: *Pool, address: usize, owner: u64) Error!void {
        const entry = try self.resolve(address);
        if (entry.state == .free) return self.rejectDoubleFree();
        if (entry.state == .exclusive and entry.owner != owner) return self.rejectOwner();
        if (entry.references == std.math.maxInt(u32)) {
            self.reference_overflows +|= 1;
            return Error.ReferenceOverflow;
        }
        if (entry.state == .exclusive) {
            entry.state = .shared;
            entry.owner = 0;
            self.shared += 1;
        }
        entry.references += 1;
        self.retains +|= 1;
    }

    pub fn release(self: *Pool, address: usize, owner: u64) Error!ReleaseResult {
        const entry = try self.resolve(address);
        if (entry.state == .free) return self.rejectDoubleFree();
        if (entry.state == .exclusive and entry.owner != owner) return self.rejectOwner();
        if (entry.references > 1) {
            entry.references -= 1;
            self.releases +|= 1;
            return .retained;
        }
        if (self.poison_on_free) {
            @memset(@as([*]u8, @ptrFromInt(address))[0..page_bytes], poison_byte);
        }
        if (self.manager) |manager| {
            manager.free(address) catch {
                self.backing_failures +|= 1;
                return Error.BackingAllocatorFailure;
            };
        }
        if (entry.state == .shared) self.shared -= 1;
        entry.state = .free;
        entry.owner = 0;
        entry.references = 0;
        if (self.manager != null) {
            // Keep exactly one tombstone for generation-preserving reuse.
            for (self.entries[0..self.page_count]) |*other| {
                if (other != entry and other.state == .free and other.address == address) other.address = 0;
            }
        }
        self.active -= 1;
        self.releases +|= 1;
        self.frees +|= 1;
        return .freed;
    }

    pub fn inspect(self: *Pool, address: usize) Error!*const Entry {
        return try self.resolve(address);
    }

    pub fn report(self: *const Pool) Report {
        return .{
            .capacity = self.page_count,
            .active = self.active,
            .shared = self.shared,
            .peak = self.peak,
            .allocations = self.allocations,
            .releases = self.releases,
            .frees = self.frees,
            .retains = self.retains,
            .out_of_memory = self.out_of_memory,
            .invalid_addresses = self.invalid_addresses,
            .double_frees = self.double_frees,
            .owner_mismatches = self.owner_mismatches,
            .reference_overflows = self.reference_overflows,
            .backing_failures = self.backing_failures,
            .clean = self.active == 0 and self.shared == 0 and self.backing_failures == 0,
        };
    }

    fn resolve(self: *Pool, address: usize) Error!*Entry {
        if (self.manager != null) {
            var released_match: ?*Entry = null;
            for (self.entries[0..self.page_count]) |*entry| {
                if (entry.address != address) continue;
                if (entry.state != .free) return entry;
                if (released_match == null) released_match = entry;
            }
            return released_match orelse self.rejectAddress();
        }
        if (address < self.base) return self.rejectAddress();
        const offset = address - self.base;
        if ((offset & (page_bytes - 1)) != 0) return self.rejectAddress();
        const index = offset / page_bytes;
        if (index >= self.page_count) return self.rejectAddress();
        return &self.entries[index];
    }

    fn rejectAddress(self: *Pool) Error {
        self.invalid_addresses +|= 1;
        return Error.InvalidAddress;
    }

    fn rejectDoubleFree(self: *Pool) Error {
        self.double_frees +|= 1;
        return Error.DoubleFree;
    }

    fn rejectOwner(self: *Pool) Error {
        self.owner_mismatches +|= 1;
        return Error.OwnerMismatch;
    }
};

fn nextGeneration(current: u32) u32 {
    const next = current +% 1;
    return if (next == 0) 1 else next;
}

test "owned pages support arbitrary release and immediate reuse" {
    var pool = try Pool.init(0x20_0000, 4);
    const first = pool.allocate(11).?;
    const second = pool.allocate(22).?;
    try std.testing.expectEqual(@as(usize, 0x20_0000), first);
    try std.testing.expectEqual(@as(usize, 0x20_1000), second);
    try std.testing.expectEqual(ReleaseResult.freed, try pool.release(first, 11));
    try std.testing.expectEqual(first, pool.allocate(33).?);
    const entry = try pool.inspect(first);
    try std.testing.expectEqual(State.exclusive, entry.state);
    try std.testing.expectEqual(@as(u64, 33), entry.owner);
    try std.testing.expectEqual(@as(u32, 2), entry.generation);
}

test "shared references retain a page until the final release" {
    var pool = try Pool.init(0x30_0000, 2);
    const page = pool.allocate(7).?;
    try pool.retainShared(page, 7);
    try pool.retainShared(page, 99);
    try std.testing.expectEqual(ReleaseResult.retained, try pool.release(page, 7));
    try std.testing.expectEqual(ReleaseResult.retained, try pool.release(page, 88));
    try std.testing.expectEqual(ReleaseResult.freed, try pool.release(page, 77));
    const report = pool.report();
    try std.testing.expectEqual(@as(u64, 3), report.releases);
    try std.testing.expectEqual(@as(u64, 1), report.frees);
    try std.testing.expect(report.clean);
}

test "double free wrong owner and malformed addresses are rejected" {
    var pool = try Pool.init(0x40_0000, 2);
    const page = pool.allocate(5).?;
    try std.testing.expectError(Error.OwnerMismatch, pool.release(page, 6));
    try std.testing.expectEqual(ReleaseResult.freed, try pool.release(page, 5));
    try std.testing.expectError(Error.DoubleFree, pool.release(page, 5));
    try std.testing.expectError(Error.InvalidAddress, pool.release(page + 1, 5));
    const report = pool.report();
    try std.testing.expectEqual(@as(u64, 1), report.owner_mismatches);
    try std.testing.expectEqual(@as(u64, 1), report.double_frees);
    try std.testing.expectEqual(@as(u64, 1), report.invalid_addresses);
}

test "out of memory is explicit and accounting remains consistent" {
    var pool = try Pool.init(0x50_0000, 2);
    _ = pool.allocate(1).?;
    _ = pool.allocate(2).?;
    try std.testing.expect(pool.allocate(3) == null);
    const report = pool.report();
    try std.testing.expectEqual(@as(usize, 2), report.active);
    try std.testing.expectEqual(@as(usize, 2), report.peak);
    try std.testing.expectEqual(@as(u64, 1), report.out_of_memory);
    try std.testing.expect(!report.clean);
}

test "manager-backed pages return to post-bootstrap physical memory" {
    const extents = [_]memory.PhysicalExtent{.{ .base = 0x60_0000, .end = 0x60_4000 }};
    var manager = memory.PhysicalMemoryManager.initForTesting(&extents).?;
    var pool = Pool{};
    try pool.initializeManager(&manager, 2, memory.four_gib, false);
    const first = pool.allocate(10).?;
    const second = pool.allocate(20).?;
    try std.testing.expectEqual(@as(usize, 0x60_0000), first);
    try std.testing.expectEqual(@as(usize, 0x60_1000), second);
    try std.testing.expectEqual(ReleaseResult.freed, try pool.release(first, 10));
    try std.testing.expectEqual(first, pool.allocate(30).?);
    try std.testing.expectEqual(ReleaseResult.freed, try pool.release(second, 20));
    try std.testing.expectEqual(ReleaseResult.freed, try pool.release(first, 30));
    try std.testing.expect(pool.report().clean);
    const manager_report = manager.report();
    try std.testing.expectEqual(@as(u64, 3), manager_report.allocations);
    try std.testing.expectEqual(@as(u64, 3), manager_report.frees);
    try std.testing.expect(manager_report.clean);
}

test "manager-backed metadata follows recycled physical addresses" {
    const extents = [_]memory.PhysicalExtent{.{ .base = 0x70_0000, .end = 0x70_5000 }};
    var manager = memory.PhysicalMemoryManager.initForTesting(&extents).?;
    var pool = Pool{};
    try pool.initializeManager(&manager, 4, memory.four_gib, false);

    const a = pool.allocate(1).?;
    const b = pool.allocate(2).?;
    const c = pool.allocate(3).?;
    try std.testing.expectEqual(ReleaseResult.freed, try pool.release(c, 3));
    try std.testing.expectEqual(ReleaseResult.freed, try pool.release(a, 1));

    // The physical manager returns the lower free address first even though a
    // different metadata slot was released first.
    const recycled_a = pool.allocate(4).?;
    const recycled_c = pool.allocate(5).?;
    try std.testing.expectEqual(a, recycled_a);
    try std.testing.expectEqual(c, recycled_c);

    var remembered_a: usize = 0;
    var remembered_c: usize = 0;
    for (pool.entries[0..pool.page_count]) |entry| {
        remembered_a += @intFromBool(entry.address == a);
        remembered_c += @intFromBool(entry.address == c);
    }
    try std.testing.expectEqual(@as(usize, 1), remembered_a);
    try std.testing.expectEqual(@as(usize, 1), remembered_c);

    try std.testing.expectEqual(ReleaseResult.freed, try pool.release(b, 2));
    try std.testing.expectEqual(ReleaseResult.freed, try pool.release(recycled_a, 4));
    try std.testing.expectEqual(ReleaseResult.freed, try pool.release(recycled_c, 5));
    try std.testing.expect(pool.report().clean);
    try std.testing.expect(manager.report().clean);
}

test "manager-backed pool rejects a backing duplicate before zeroing" {
    const extents = [_]memory.PhysicalExtent{.{ .base = 0x80_0000, .end = 0x80_3000 }};
    var manager = memory.PhysicalMemoryManager.initForTesting(&extents).?;
    var pool = Pool{};
    try pool.initializeManager(&manager, 3, memory.four_gib, false);

    const live = pool.allocate(11).?;
    // Simulate a corrupted backing free set while ownership metadata remains live.
    try manager.free(live);
    try std.testing.expect(pool.allocate(22) == null);
    const entry = try pool.inspect(live);
    try std.testing.expectEqual(State.exclusive, entry.state);
    try std.testing.expectEqual(@as(u64, 11), entry.owner);
    try std.testing.expectEqual(@as(u64, 1), pool.report().backing_failures);
    try std.testing.expectEqual(ReleaseResult.freed, try pool.release(live, 11));
}
