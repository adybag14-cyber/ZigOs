const std = @import("std");
const runtime_vfs = @import("runtime_vfs.zig");

pub const maximum_registrations: usize = 16;

const Registration = struct {
    used: bool = false,
    name: [runtime_vfs.maximum_name_length + 1]u8 = @splat(0),
    name_length: u8 = 0,
    mode: u16 = 0,
    operations: ?*const runtime_vfs.PseudoOperations = null,
    context: ?*anyopaque = null,
    node: u16 = runtime_vfs.invalid_node,

    fn nameSlice(self: *const Registration) []const u8 {
        return self.name[0..self.name_length];
    }
};

pub const Report = struct {
    kind: runtime_vfs.MountKind,
    mounted: bool,
    mount_id: u8,
    registrations: usize,
    publications: u64,
    withdrawals: u64,
    failures: u64,
};

pub const Registry = struct {
    kind: runtime_vfs.MountKind,
    entries: [maximum_registrations]Registration = @splat(.{}),
    mounted: bool = false,
    mount_id: u8 = 0,
    root_node: u16 = runtime_vfs.invalid_node,
    publications: u64 = 0,
    withdrawals: u64 = 0,
    failures: u64 = 0,

    pub fn init(kind: runtime_vfs.MountKind) Registry {
        return .{ .kind = kind };
    }

    pub fn register(
        self: *Registry,
        vfs: *runtime_vfs.Vfs,
        name: []const u8,
        mode: u16,
        operations: *const runtime_vfs.PseudoOperations,
        context: ?*anyopaque,
        tick: u64,
    ) runtime_vfs.Error!u16 {
        try validateKind(self.kind);
        try validateName(name);
        if (self.find(name) != null) return runtime_vfs.Error.AlreadyExists;
        const slot = self.freeSlot() orelse return runtime_vfs.Error.NoSpace;
        var node = runtime_vfs.invalid_node;
        if (self.mounted) {
            node = vfs.publishPseudoRegistration(self.root_node, name, mode, tick, operations, context) catch |err| {
                self.failures +%= 1;
                return err;
            };
        }
        var entry = Registration{
            .used = true,
            .name_length = @intCast(name.len),
            .mode = mode & 0o777,
            .operations = operations,
            .context = context,
            .node = node,
        };
        @memcpy(entry.name[0..name.len], name);
        self.entries[slot] = entry;
        if (self.mounted) self.publications +%= 1;
        return node;
    }

    pub fn unregister(self: *Registry, vfs: *runtime_vfs.Vfs, name: []const u8) runtime_vfs.Error!void {
        try validateKind(self.kind);
        try validateName(name);
        const slot = self.find(name) orelse return runtime_vfs.Error.NotFound;
        if (self.mounted) {
            vfs.withdrawPseudoRegistration(self.root_node, name) catch |err| {
                self.failures +%= 1;
                return err;
            };
            self.withdrawals +%= 1;
        }
        self.entries[slot] = .{};
    }

    pub fn mount(self: *Registry, vfs: *runtime_vfs.Vfs, path: []const u8, source: []const u8, tick: u64) runtime_vfs.Error!u8 {
        try validateKind(self.kind);
        if (self.mounted) return runtime_vfs.Error.Busy;
        const mount_id = vfs.mountEmpty(0, path, self.kind, true, source) catch |err| {
            self.failures +%= 1;
            return err;
        };
        const root_node = vfs.resolve(0, path) catch |err| {
            vfs.unmount(mount_id) catch {};
            self.failures +%= 1;
            return err;
        };
        errdefer {
            for (&self.entries) |*entry| {
                if (!entry.used or entry.node == runtime_vfs.invalid_node) continue;
                vfs.withdrawPseudoRegistration(root_node, entry.nameSlice()) catch {};
                entry.node = runtime_vfs.invalid_node;
            }
            vfs.unmount(mount_id) catch {};
            self.failures +%= 1;
        }
        for (&self.entries) |*entry| {
            if (!entry.used) continue;
            entry.node = try vfs.publishPseudoRegistration(
                root_node,
                entry.nameSlice(),
                entry.mode,
                tick,
                entry.operations.?,
                entry.context,
            );
            self.publications +%= 1;
        }
        self.mounted = true;
        self.mount_id = mount_id;
        self.root_node = root_node;
        return mount_id;
    }

    pub fn validate(self: *const Registry, vfs: *runtime_vfs.Vfs) bool {
        validateKind(self.kind) catch return false;
        if (!self.mounted) {
            if (self.mount_id != 0 or self.root_node != runtime_vfs.invalid_node) return false;
            for (self.entries) |entry| if (entry.used and entry.node != runtime_vfs.invalid_node) return false;
            return true;
        }
        if (self.mount_id == 0 or self.root_node == runtime_vfs.invalid_node) return false;
        var count: usize = 0;
        for (self.entries) |entry| {
            if (!entry.used) continue;
            count += 1;
            const operations = entry.operations orelse return false;
            if (entry.node == runtime_vfs.invalid_node or
                !vfs.pseudoRegistrationMatches(self.root_node, entry.nameSlice(), entry.node, operations, entry.context))
                return false;
        }
        return self.publications >= count and self.failures == 0;
    }

    pub fn report(self: *const Registry) Report {
        var count: usize = 0;
        for (self.entries) |entry| {
            if (entry.used) count += 1;
        }
        return .{
            .kind = self.kind,
            .mounted = self.mounted,
            .mount_id = self.mount_id,
            .registrations = count,
            .publications = self.publications,
            .withdrawals = self.withdrawals,
            .failures = self.failures,
        };
    }

    fn find(self: *const Registry, name: []const u8) ?usize {
        for (self.entries, 0..) |entry, index| {
            if (entry.used and std.mem.eql(u8, entry.nameSlice(), name)) return index;
        }
        return null;
    }

    fn freeSlot(self: *const Registry) ?usize {
        for (self.entries, 0..) |entry, index| {
            if (!entry.used) return index;
        }
        return null;
    }
};

fn validateKind(kind: runtime_vfs.MountKind) runtime_vfs.Error!void {
    switch (kind) {
        .procfs, .devfs, .netfs => {},
        else => return runtime_vfs.Error.UnsupportedOperation,
    }
}

fn validateName(name: []const u8) runtime_vfs.Error!void {
    if (name.len == 0 or name.len > runtime_vfs.maximum_name_length) return runtime_vfs.Error.NameTooLong;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        std.mem.indexOfScalar(u8, name, '/') != null or std.mem.indexOfScalar(u8, name, 0) != null)
        return runtime_vfs.Error.InvalidPath;
}

const TestContext = struct {
    byte: u8,
};

fn readTest(context: ?*anyopaque, _: u16, offset: usize, output: []u8) runtime_vfs.Error!usize {
    const value: *TestContext = @ptrCast(@alignCast(context.?));
    if (offset != 0 or output.len == 0) return 0;
    output[0] = value.byte;
    return 1;
}

fn writeTest(_: ?*anyopaque, _: u16, _: usize, input: []const u8) runtime_vfs.Error!usize {
    return input.len;
}

const read_operations = runtime_vfs.PseudoOperations{ .read = readTest };
const read_write_operations = runtime_vfs.PseudoOperations{ .read = readTest, .write = writeTest };

test "live pseudo registry publishes after mount and withdraws only when idle" {
    var fs = runtime_vfs.Vfs.init();
    _ = try fs.mkdir(0, "/dev", 0o755, 1);
    var registry = Registry.init(.devfs);
    var first = TestContext{ .byte = 'A' };
    var second = TestContext{ .byte = 'B' };

    _ = try registry.register(&fs, "first", 0o444, &read_operations, &first, 2);
    const mount_id = try registry.mount(&fs, "/dev", "live-devices", 3);
    try std.testing.expect(mount_id > 1);
    try std.testing.expectError(runtime_vfs.Error.ReadOnly, fs.create(0, "/dev/ordinary", 0o644, 4));

    const first_fd = try fs.open(9, 0, "/dev/first", .{ .read = true }, 0, 5);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try fs.readOpen(9, first_fd, &byte));
    try std.testing.expectEqual(@as(u8, 'A'), byte[0]);
    try fs.close(9, first_fd);

    const second_node = try registry.register(&fs, "second", 0o666, &read_write_operations, &second, 6);
    try std.testing.expect(second_node != runtime_vfs.invalid_node);
    const second_fd = try fs.open(9, 0, "/dev/second", .{ .read = true, .write = true }, 0, 7);
    try std.testing.expectError(runtime_vfs.Error.Busy, registry.unregister(&fs, "second"));
    try fs.close(9, second_fd);
    try registry.unregister(&fs, "second");
    try std.testing.expectError(runtime_vfs.Error.NotFound, fs.resolve(0, "/dev/second"));

    const report = registry.report();
    try std.testing.expect(report.mounted);
    try std.testing.expectEqual(@as(usize, 1), report.registrations);
    try std.testing.expectEqual(@as(u64, 2), report.publications);
    try std.testing.expectEqual(@as(u64, 1), report.withdrawals);
    try std.testing.expectEqual(@as(u64, 1), report.failures);
    try std.testing.expect(!registry.validate(&fs));
    registry.failures = 0;
    try std.testing.expect(registry.validate(&fs));
    try std.testing.expect(fs.validate());
}
