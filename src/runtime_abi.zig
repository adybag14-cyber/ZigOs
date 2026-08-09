const std = @import("std");
pub const constants = @import("generated/runtime_abi_constants.zig");

pub const errno_permission = constants.errno_permission;
pub const errno_not_found = constants.errno_not_found;
pub const errno_no_process = constants.errno_no_process;
pub const errno_interrupted = constants.errno_interrupted;
pub const errno_io = constants.errno_io;
pub const errno_too_big = constants.errno_too_big;
pub const errno_bad_fd = constants.errno_bad_fd;
pub const errno_no_child = constants.errno_no_child;
pub const errno_would_block = constants.errno_would_block;
pub const errno_no_memory = constants.errno_no_memory;
pub const errno_access = constants.errno_access;
pub const errno_fault = constants.errno_fault;
pub const errno_busy = constants.errno_busy;
pub const errno_exists = constants.errno_exists;
pub const errno_cross_device = constants.errno_cross_device;
pub const errno_not_directory = constants.errno_not_directory;
pub const errno_is_directory = constants.errno_is_directory;
pub const errno_invalid = constants.errno_invalid;
pub const errno_system_file_limit = constants.errno_system_file_limit;
pub const errno_process_file_limit = constants.errno_process_file_limit;
pub const errno_file_too_large = constants.errno_file_too_large;
pub const errno_no_space = constants.errno_no_space;
pub const errno_not_seekable = constants.errno_not_seekable;
pub const errno_read_only = constants.errno_read_only;
pub const errno_broken_pipe = constants.errno_broken_pipe;
pub const errno_name_too_long = constants.errno_name_too_long;
pub const errno_no_syscall = constants.errno_no_syscall;
pub const errno_not_empty = constants.errno_not_empty;
pub const errno_loop = constants.errno_loop;
pub const errno_not_socket = constants.errno_not_socket;
pub const errno_address_in_use = constants.errno_address_in_use;
pub const errno_not_connected = constants.errno_not_connected;
pub const errno_connection_refused = constants.errno_connection_refused;

pub const wait_nohang: u64 = constants.wait_nohang;
pub const wait_process_group: u64 = constants.wait_process_group;
pub const wait_allowed: u64 = wait_nohang | wait_process_group;

pub const open_read: u8 = 1 << 0;
pub const open_write: u8 = 1 << 1;
pub const open_create: u8 = 1 << 2;
pub const open_truncate: u8 = 1 << 3;
pub const open_append: u8 = 1 << 4;
pub const open_close_on_exec: u8 = 1 << 5;
pub const open_allowed: u64 = open_read | open_write | open_create | open_truncate | open_append | open_close_on_exec;

pub const protection_read: u64 = 1 << 0;
pub const protection_write: u64 = 1 << 1;
pub const protection_execute: u64 = 1 << 2;
pub const protection_allowed: u64 = protection_read | protection_write | protection_execute;

pub const map_private: u64 = 1 << 0;
pub const map_anonymous: u64 = 1 << 1;
pub const map_fixed: u64 = 1 << 2;
pub const map_fixed_no_replace: u64 = 1 << 3;
pub const map_shared: u64 = 1 << 4;
pub const map_allowed: u64 = map_private | map_anonymous | map_fixed | map_fixed_no_replace | map_shared;

pub const message_dontwait: u64 = constants.message_dontwait;
pub const message_allowed: u64 = message_dontwait;

pub const spawn_new_process_group: u16 = constants.spawn_new_process_group;
pub const spawn_join_process_group: u16 = constants.spawn_join_process_group;
pub const spawn_pipeline_io: u16 = constants.spawn_pipeline_io;
pub const spawn_io_inherit_descriptor: u16 = constants.spawn_io_inherit_descriptor;
pub const spawn_group_allowed: u16 = spawn_new_process_group | spawn_join_process_group;
pub const spawn_allowed: u16 = spawn_group_allowed | spawn_pipeline_io;

pub const fallocate_keep_size: u64 = constants.fallocate_keep_size;
pub const fallocate_punch_hole: u64 = constants.fallocate_punch_hole;
pub const fallocate_allowed: u64 = fallocate_keep_size | fallocate_punch_hole;

pub const poll_readable: u16 = 1 << 0;
pub const poll_writable: u16 = 1 << 1;
pub const poll_error: u16 = 1 << 2;
pub const poll_hangup: u16 = 1 << 3;

pub const address_family_ipv4: u16 = 2;
pub const socket_datagram: u16 = 2;
pub const protocol_udp: u16 = 17;

pub const AbiInfo = extern struct {
    magic: u32,
    size: u16,
    major: u16,
    minor: u16,
    reserved0: u16 = 0,
    page_size: u32,
    syscall_base: u16,
    syscall_count: u16,
    reserved1: u32 = 0,
    capabilities: u64,
    user_base: u64,
    user_end: u64,
    maximum_io_bytes: u32,
    maximum_path_bytes: u32,
    maximum_processes: u16,
    maximum_descriptors: u16,
    maximum_sockets: u16,
    reserved2: u16 = 0,
};

pub const WaitStatus = extern struct {
    pid: u32,
    exit_status: u32,
    state: u32,
    fault_vector: u32,
    fault_address: u64,
};

pub const Stat = extern struct {
    node: u32,
    generation: u16,
    kind: u8,
    readonly: u8,
    mode: u16,
    mount_id: u8,
    link_count: u8,
    size: u64,
    modified_tick: u64,
};

pub const FileTimes = extern struct {
    created_tick: u64,
    modified_tick: u64,
    changed_tick: u64,
    accessed_tick: u64,
};

pub const FileOwner = extern struct {
    uid: u32,
    gid: u32,
};

pub const FilesystemStat = extern struct {
    block_size: u64,
    total_blocks: u64,
    free_blocks: u64,
    available_blocks: u64,
    total_nodes: u64,
    free_nodes: u64,
    mount_id: u32,
    filesystem_kind: u16,
    flags: u16,
    reserved: u64 = 0,
};

pub const DirectoryEntry = extern struct {
    node: u32,
    kind: u8,
    readonly: u8,
    name_length: u16,
    size: u64,
    name: [32]u8,
};

pub const PollDescriptor = extern struct {
    fd: u16,
    requested: u16,
    returned: u16,
    reserved: u16 = 0,
};

pub const DirectoryEvent = extern struct {
    sequence: u64,
    node: u32,
    generation: u16,
    kind: u8,
    flags: u8,
    name_length: u16,
    reserved0: [6]u8 = @splat(0),
    name: [32]u8 = @splat(0),
    reserved1: [8]u8 = @splat(0),
};

pub const IoVector = extern struct {
    pointer: u64,
    length: u64,
};

pub const Ipv4SocketAddress = extern struct {
    family: u16,
    port_be: u16,
    address_be: u32,
};

pub const UserString = extern struct {
    pointer: u64,
    length: u16,
    reserved0: u16 = 0,
    reserved1: u32 = 0,
};

pub const SpawnRequest = extern struct {
    path_pointer: u64,
    arguments_pointer: u64,
    environment_pointer: u64,
    path_length: u16,
    argument_count: u16,
    environment_count: u16,
    flags: u16 = 0,
};

pub const AuxvEntry = extern struct {
    kind: u64,
    value: u64,
};

pub const AbiLimits = struct {
    capabilities: u64,
    user_base: u64,
    user_end: u64,
    maximum_io_bytes: u32,
    maximum_path_bytes: u32,
    maximum_processes: u16,
    maximum_descriptors: u16,
    maximum_sockets: u16,
};

pub fn makeInfo(limits: AbiLimits) AbiInfo {
    return .{
        .magic = constants.abi_magic,
        .size = @sizeOf(AbiInfo),
        .major = constants.abi_major,
        .minor = constants.abi_minor,
        .page_size = constants.abi_page_size,
        .syscall_base = constants.syscall_base,
        .syscall_count = constants.syscall_count,
        .capabilities = limits.capabilities,
        .user_base = limits.user_base,
        .user_end = limits.user_end,
        .maximum_io_bytes = limits.maximum_io_bytes,
        .maximum_path_bytes = limits.maximum_path_bytes,
        .maximum_processes = limits.maximum_processes,
        .maximum_descriptors = limits.maximum_descriptors,
        .maximum_sockets = limits.maximum_sockets,
    };
}

pub fn descriptor(value: u64) ?u16 {
    return std.math.cast(u16, value);
}

pub fn openFlagBits(value: u64) ?u8 {
    if ((value & ~open_allowed) != 0) return null;
    return @intCast(value);
}

pub fn protectionBits(value: u64) ?u8 {
    if ((value & ~protection_allowed) != 0) return null;
    return @intCast(value);
}

pub fn mapFlagBits(value: u64) ?u8 {
    if ((value & ~map_allowed) != 0) return null;
    const bits: u8 = @intCast(value);
    const private = (bits & map_private) != 0;
    const anonymous = (bits & map_anonymous) != 0;
    const shared = (bits & map_shared) != 0;
    if (private == shared or private != anonymous) return null;
    if ((bits & map_fixed) != 0 and (bits & map_fixed_no_replace) != 0) return null;
    return bits;
}

pub fn messageFlagBits(value: u64) ?u8 {
    if ((value & ~message_allowed) != 0) return null;
    return @intCast(value);
}

pub fn fallocateFlagBits(value: u64) ?u8 {
    if ((value & ~fallocate_allowed) != 0) return null;
    const bits: u8 = @intCast(value);
    if ((bits & fallocate_punch_hole) != 0 and (bits & fallocate_keep_size) == 0) return null;
    return bits;
}

pub fn mode(value: u64) ?u16 {
    return std.math.cast(u16, value);
}

pub fn fromError(err: anyerror) i64 {
    return switch (err) {
        error.NotFound => errno_not_found,
        error.NoProcess, error.AlreadyTerminal => errno_no_process,
        error.NotChild => errno_no_child,
        error.StillRunning, error.NoSlots, error.NoContext, error.ContextLimit, error.QuotaExceeded, error.WouldBlock => errno_would_block,
        error.PermissionDenied => errno_access,
        error.InvalidHandle, error.BadDescriptor, error.NotReadable, error.NotWritable => errno_bad_fd,
        error.InvalidPath, error.InvalidOffset, error.InvalidOperation, error.InvalidState, error.InvalidSignal, error.InvalidAddress, error.InvalidProtection, error.InvalidMapping, error.NotSymlink => errno_invalid,
        error.NameTooLong, error.PathTooLong, error.ArgumentTooLong => errno_name_too_long,
        error.TooManyArguments => errno_too_big,
        error.AlreadyExists, error.NamespaceExists, error.AddressInUse => errno_exists,
        error.NotDirectory => errno_not_directory,
        error.IsDirectory => errno_is_directory,
        error.DirectoryNotEmpty => errno_not_empty,
        error.ReadOnly => errno_read_only,
        error.NoRuntimeFrames, error.AddressSpaceFailure, error.MappingLimit, error.MappingFailure, error.OutOfMemory => errno_no_memory,
        error.NoSpace, error.PipeLimit, error.RangeLockLimit => errno_no_space,
        error.FileTooLarge => errno_file_too_large,
        error.Busy => errno_busy,
        error.CrossMount => errno_cross_device,
        error.Cycle => errno_loop,
        error.TooManyOpenFiles, error.OpenDescriptionLimit => errno_system_file_limit,
        error.DescriptorLimit => errno_process_file_limit,
        error.NotSeekable => errno_not_seekable,
        error.UnsupportedOperation => errno_no_syscall,
        error.BrokenPipe => errno_broken_pipe,
        error.NotSocket => errno_not_socket,
        error.NotConnected => errno_not_connected,
        error.ConnectionRefused => errno_connection_refused,
        error.NamespaceMissing, error.ReferenceOverflow, error.CorruptState, error.BackingAllocatorFailure => errno_io,
        else => errno_io,
    };
}

test "ABI information has a stable 64-byte versioned layout" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(AbiInfo));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(DirectoryEvent));
    const info = makeInfo(.{
        .capabilities = constants.capability_process | constants.capability_virtual_memory,
        .user_base = 0x1000,
        .user_end = 0x8000,
        .maximum_io_bytes = 1024,
        .maximum_path_bytes = 255,
        .maximum_processes = 64,
        .maximum_descriptors = 32,
        .maximum_sockets = 16,
    });
    try std.testing.expectEqual(constants.abi_magic, info.magic);
    try std.testing.expectEqual(constants.abi_major, info.major);
    try std.testing.expectEqual(constants.syscall_count, info.syscall_count);
    try std.testing.expect((info.capabilities & constants.capability_virtual_memory) != 0);
}

test "descriptor arguments reject narrowing aliases" {
    try std.testing.expectEqual(@as(?u16, 0), descriptor(0));
    try std.testing.expectEqual(@as(?u16, std.math.maxInt(u16)), descriptor(std.math.maxInt(u16)));
    try std.testing.expect(descriptor(@as(u64, std.math.maxInt(u16)) + 1) == null);
    try std.testing.expect(descriptor(std.math.maxInt(u64)) == null);
}

test "open protection map and message flags reject unknown or contradictory bits" {
    try std.testing.expectEqual(@as(?u8, open_allowed), openFlagBits(open_allowed));
    try std.testing.expect(openFlagBits(open_allowed + 1) == null);
    try std.testing.expectEqual(@as(?u8, protection_read | protection_write), protectionBits(protection_read | protection_write));
    try std.testing.expect(protectionBits(8) == null);
    try std.testing.expectEqual(@as(?u8, map_private | map_anonymous), mapFlagBits(map_private | map_anonymous));
    try std.testing.expectEqual(@as(?u8, map_shared), mapFlagBits(map_shared));
    try std.testing.expect(mapFlagBits(map_private) == null);
    try std.testing.expect(mapFlagBits(map_anonymous) == null);
    try std.testing.expect(mapFlagBits(map_shared | map_anonymous) == null);
    try std.testing.expect(mapFlagBits(map_private | map_shared | map_anonymous) == null);
    try std.testing.expect(mapFlagBits(map_private | map_anonymous | map_fixed | map_fixed_no_replace) == null);
    try std.testing.expectEqual(@as(?u8, @intCast(message_dontwait)), messageFlagBits(message_dontwait));
    try std.testing.expect(messageFlagBits(message_dontwait << 1) == null);
    try std.testing.expect(messageFlagBits(std.math.maxInt(u64)) == null);
    try std.testing.expectEqual(@as(?u8, 0), fallocateFlagBits(0));
    try std.testing.expectEqual(@as(?u8, @intCast(fallocate_keep_size)), fallocateFlagBits(fallocate_keep_size));
    try std.testing.expectEqual(@as(?u8, @intCast(fallocate_keep_size | fallocate_punch_hole)), fallocateFlagBits(fallocate_keep_size | fallocate_punch_hole));
    try std.testing.expect(fallocateFlagBits(fallocate_punch_hole) == null);
    try std.testing.expect(fallocateFlagBits(std.math.maxInt(u64)) == null);
}

test "mode arguments reject values wider than the ABI" {
    try std.testing.expectEqual(@as(?u16, 0o755), mode(0o755));
    try std.testing.expectEqual(@as(?u16, 0o6755), mode(0o6755));
    try std.testing.expect(mode(@as(u64, std.math.maxInt(u16)) + 1) == null);
}

test "kernel errors retain distinct userspace errno values" {
    try std.testing.expectEqual(errno_not_found, fromError(error.NotFound));
    try std.testing.expectEqual(errno_access, fromError(error.PermissionDenied));
    try std.testing.expectEqual(errno_read_only, fromError(error.ReadOnly));
    try std.testing.expectEqual(errno_is_directory, fromError(error.IsDirectory));
    try std.testing.expectEqual(errno_broken_pipe, fromError(error.BrokenPipe));
    try std.testing.expectEqual(errno_process_file_limit, fromError(error.DescriptorLimit));
    try std.testing.expectEqual(errno_would_block, fromError(error.NoContext));
    try std.testing.expectEqual(errno_no_memory, fromError(error.NoRuntimeFrames));
    try std.testing.expectEqual(errno_system_file_limit, fromError(error.OpenDescriptionLimit));
    try std.testing.expectEqual(errno_io, fromError(error.InputOutput));
}

test "spawnv request and startup vector layouts are stable" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(IoVector));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Stat));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(FileTimes));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(FileOwner));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(FilesystemStat));
    try std.testing.expectEqual(@as(usize, 8), constants.maximum_iovecs);
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(UserString));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(SpawnRequest));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(AuxvEntry));
    try std.testing.expectEqual(@as(usize, 8), constants.maximum_arguments);
    try std.testing.expectEqual(@as(usize, 8), constants.maximum_environment);
    try std.testing.expect(constants.aux_zigos_abi > constants.aux_secure);
}
