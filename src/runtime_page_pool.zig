const std = @import("std");

pub const page_bytes: usize = 4096;
pub const maximum_pages: usize = 256;
pub const poison_byte: u8 = 0xA5;

pub const Error = error{
    InvalidConfiguration,
    InvalidAddress,
    DoubleFree,
    OwnerMismatch,
    ReferenceOverflow,
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
    clean: bool,
};

pub const Pool = struct {
    base: usize = 0,
    page_count: usize = 0,
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

    pub fn allocate(self: *Pool, owner: u64) ?usize {
        if (owner == 0) {
            self.owner_mismatches +|= 1;
            return null;
        }
        for (self.entries[0..self.page_count], 0..) |*entry, index| {
            if (entry.state != .free) continue;
            entry.state = .exclusive;
            entry.owner = owner;
            entry.references = 1;
            entry.generation = nextGeneration(entry.generation);
            self.active += 1;
            self.peak = @max(self.peak, self.active);
            self.allocations +|= 1;
            return self.base + index * page_bytes;
        }
        self.out_of_memory +|= 1;
        return null;
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
        if (entry.state == .shared) self.shared -= 1;
        entry.state = .free;
        entry.owner = 0;
        entry.references = 0;
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
            .clean = self.active == 0 and self.shared == 0,
        };
    }

    fn resolve(self: *Pool, address: usize) Error!*Entry {
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
