const std = @import("std");

pub const errno_permission: i64 = -1;
pub const errno_not_found: i64 = -2;
pub const errno_no_process: i64 = -3;
pub const errno_io: i64 = -5;
pub const errno_too_big: i64 = -7;
pub const errno_bad_fd: i64 = -9;
pub const errno_no_child: i64 = -10;
pub const errno_would_block: i64 = -11;
pub const errno_no_memory: i64 = -12;
pub const errno_access: i64 = -13;
pub const errno_fault: i64 = -14;
pub const errno_busy: i64 = -16;
pub const errno_exists: i64 = -17;
pub const errno_cross_device: i64 = -18;
pub const errno_not_directory: i64 = -20;
pub const errno_is_directory: i64 = -21;
pub const errno_invalid: i64 = -22;
pub const errno_system_file_limit: i64 = -23;
pub const errno_process_file_limit: i64 = -24;
pub const errno_file_too_large: i64 = -27;
pub const errno_no_space: i64 = -28;
pub const errno_not_seekable: i64 = -29;
pub const errno_read_only: i64 = -30;
pub const errno_broken_pipe: i64 = -32;
pub const errno_name_too_long: i64 = -36;
pub const errno_no_syscall: i64 = -38;
pub const errno_not_empty: i64 = -39;
pub const errno_loop: i64 = -40;

pub fn descriptor(value: u64) ?u16 {
    return std.math.cast(u16, value);
}

pub fn openFlagBits(value: u64) ?u8 {
    const allowed: u64 = 0x1F;
    if ((value & ~allowed) != 0) return null;
    return @intCast(value);
}

pub fn mode(value: u64) ?u16 {
    return std.math.cast(u16, value);
}

pub fn fromError(err: anyerror) i64 {
    return switch (err) {
        error.NotFound => errno_not_found,
        error.NoProcess, error.AlreadyTerminal => errno_no_process,
        error.NotChild => errno_no_child,
        error.StillRunning, error.NoSlots, error.NoContext, error.ContextLimit, error.QuotaExceeded => errno_would_block,
        error.PermissionDenied => errno_access,
        error.InvalidHandle, error.BadDescriptor, error.NotReadable, error.NotWritable => errno_bad_fd,
        error.InvalidPath, error.InvalidOffset, error.InvalidOperation, error.InvalidState, error.InvalidSignal => errno_invalid,
        error.NameTooLong, error.PathTooLong, error.ArgumentTooLong => errno_name_too_long,
        error.TooManyArguments => errno_too_big,
        error.AlreadyExists, error.NamespaceExists => errno_exists,
        error.NotDirectory => errno_not_directory,
        error.IsDirectory => errno_is_directory,
        error.DirectoryNotEmpty => errno_not_empty,
        error.ReadOnly => errno_read_only,
        error.NoRuntimeFrames, error.AddressSpaceFailure, error.MappingLimit, error.MappingFailure => errno_no_memory,
        error.NoSpace, error.PipeLimit => errno_no_space,
        error.FileTooLarge => errno_file_too_large,
        error.Busy => errno_busy,
        error.CrossMount => errno_cross_device,
        error.Cycle => errno_loop,
        error.TooManyOpenFiles, error.OpenDescriptionLimit => errno_system_file_limit,
        error.DescriptorLimit => errno_process_file_limit,
        error.NotSeekable => errno_not_seekable,
        error.BrokenPipe => errno_broken_pipe,
        error.NamespaceMissing, error.ReferenceOverflow, error.CorruptState => errno_io,
        else => errno_io,
    };
}

test "descriptor arguments reject narrowing aliases" {
    try std.testing.expectEqual(@as(?u16, 0), descriptor(0));
    try std.testing.expectEqual(@as(?u16, std.math.maxInt(u16)), descriptor(std.math.maxInt(u16)));
    try std.testing.expect(descriptor(@as(u64, std.math.maxInt(u16)) + 1) == null);
    try std.testing.expect(descriptor(std.math.maxInt(u64)) == null);
}

test "open flags reject every high bit before narrowing" {
    try std.testing.expectEqual(@as(?u8, 0x1F), openFlagBits(0x1F));
    try std.testing.expect(openFlagBits(0x20) == null);
    try std.testing.expect(openFlagBits(0x100) == null);
    try std.testing.expect(openFlagBits(@as(u64, 1) << 63) == null);
}

test "mode arguments reject values wider than the ABI" {
    try std.testing.expectEqual(@as(?u16, 0o755), mode(0o755));
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
    try std.testing.expectEqual(errno_would_block, fromError(error.ContextLimit));
    try std.testing.expectEqual(errno_no_memory, fromError(error.NoRuntimeFrames));
    try std.testing.expectEqual(errno_system_file_limit, fromError(error.OpenDescriptionLimit));
}
