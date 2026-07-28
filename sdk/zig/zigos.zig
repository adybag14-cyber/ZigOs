const abi = @import("abi.zig");

pub const constants = abi;
pub const AbiInfo = abi.AbiInfo;
pub const WaitStatus = abi.WaitStatus;
pub const Stat = abi.Stat;
pub const DirectoryEntry = abi.DirectoryEntry;
pub const PollDescriptor = abi.PollDescriptor;
pub const Ipv4SocketAddress = abi.Ipv4SocketAddress;
pub const UserString = abi.UserString;
pub const SpawnRequest = abi.SpawnRequest;
pub const AuxvEntry = abi.AuxvEntry;

extern fn zigos_syscall6(number: u64, a0: u64, a1: u64, a2: u64, a3: u64, a4: u64, a5: u64) callconv(.c) u64;

pub const Error = error{
    PermissionDenied,
    NotFound,
    NoProcess,
    Interrupted,
    InputOutput,
    TooBig,
    BadDescriptor,
    NoChild,
    WouldBlock,
    OutOfMemory,
    AccessDenied,
    Fault,
    Busy,
    AlreadyExists,
    CrossDevice,
    NotDirectory,
    IsDirectory,
    InvalidArgument,
    SystemFileLimit,
    ProcessFileLimit,
    FileTooLarge,
    NoSpace,
    NotSeekable,
    ReadOnly,
    BrokenPipe,
    NameTooLong,
    Unsupported,
    NotEmpty,
    Loop,
    NotSocket,
    AddressInUse,
    NotConnected,
    ConnectionRefused,
    Unknown,
};

pub const OpenFlags = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    create: bool = false,
    truncate: bool = false,
    append: bool = false,
    close_on_exec: bool = false,
    reserved: u2 = 0,

    pub fn bits(self: OpenFlags) u64 {
        return @as(u8, @bitCast(self));
    }
};

pub const Protection = packed struct(u8) {
    read: bool = true,
    write: bool = false,
    execute: bool = false,
    reserved: u5 = 0,

    pub fn bits(self: Protection) u64 {
        return @as(u8, @bitCast(self));
    }
};

pub const MapFlags = packed struct(u8) {
    private: bool = true,
    anonymous: bool = true,
    fixed: bool = false,
    fixed_no_replace: bool = false,
    reserved: u4 = 0,

    pub fn bits(self: MapFlags) u64 {
        return @as(u8, @bitCast(self));
    }
};

pub const MessageFlags = packed struct(u8) {
    dontwait: bool = false,
    reserved: u7 = 0,

    pub fn bits(self: MessageFlags) u64 {
        return @as(u8, @bitCast(self));
    }
};

pub const FallocateFlags = packed struct(u8) {
    keep_size: bool = false,
    punch_hole: bool = false,
    reserved: u6 = 0,

    pub fn bits(self: FallocateFlags) u64 {
        return @as(u8, @bitCast(self));
    }
};

fn ptrValue(pointer: anytype) u64 {
    return @intFromPtr(pointer);
}

fn signed(value: u64) i64 {
    return @bitCast(value);
}

fn result(value: u64) Error!u64 {
    const code = signed(value);
    if (code >= 0) return value;
    return switch (code) {
        abi.errno_permission => Error.PermissionDenied,
        abi.errno_not_found => Error.NotFound,
        abi.errno_no_process => Error.NoProcess,
        abi.errno_interrupted => Error.Interrupted,
        abi.errno_io => Error.InputOutput,
        abi.errno_too_big => Error.TooBig,
        abi.errno_bad_fd => Error.BadDescriptor,
        abi.errno_no_child => Error.NoChild,
        abi.errno_would_block => Error.WouldBlock,
        abi.errno_no_memory => Error.OutOfMemory,
        abi.errno_access => Error.AccessDenied,
        abi.errno_fault => Error.Fault,
        abi.errno_busy => Error.Busy,
        abi.errno_exists => Error.AlreadyExists,
        abi.errno_cross_device => Error.CrossDevice,
        abi.errno_not_directory => Error.NotDirectory,
        abi.errno_is_directory => Error.IsDirectory,
        abi.errno_invalid => Error.InvalidArgument,
        abi.errno_system_file_limit => Error.SystemFileLimit,
        abi.errno_process_file_limit => Error.ProcessFileLimit,
        abi.errno_file_too_large => Error.FileTooLarge,
        abi.errno_no_space => Error.NoSpace,
        abi.errno_not_seekable => Error.NotSeekable,
        abi.errno_read_only => Error.ReadOnly,
        abi.errno_broken_pipe => Error.BrokenPipe,
        abi.errno_name_too_long => Error.NameTooLong,
        abi.errno_no_syscall => Error.Unsupported,
        abi.errno_not_empty => Error.NotEmpty,
        abi.errno_loop => Error.Loop,
        abi.errno_not_socket => Error.NotSocket,
        abi.errno_address_in_use => Error.AddressInUse,
        abi.errno_not_connected => Error.NotConnected,
        abi.errno_connection_refused => Error.ConnectionRefused,
        else => Error.Unknown,
    };
}

pub fn exit(status: u32) noreturn {
    _ = zigos_syscall6(abi.syscall_exit, status, 0, 0, 0, 0, 0);
    while (true) asm volatile ("pause");
}

pub fn write(fd: u16, bytes: []const u8) Error!usize {
    return @intCast(try result(zigos_syscall6(abi.syscall_write, fd, ptrValue(bytes.ptr), bytes.len, 0, 0, 0)));
}

pub fn read(fd: u16, bytes: []u8) Error!usize {
    return @intCast(try result(zigos_syscall6(abi.syscall_read, fd, ptrValue(bytes.ptr), bytes.len, 0, 0, 0)));
}

pub fn getpid() Error!u32 {
    return @intCast(try result(zigos_syscall6(abi.syscall_getpid, 0, 0, 0, 0, 0, 0)));
}

pub fn sleep(duration_ticks: u64) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_sleep, duration_ticks, 0, 0, 0, 0, 0));
}

pub fn yield() Error!void {
    _ = try result(zigos_syscall6(abi.syscall_yield, 0, 0, 0, 0, 0, 0));
}

pub fn pipe(fds: *[2]u32) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_pipe, ptrValue(fds), 0, 0, 0, 0, 0));
}

pub fn close(fd: u16) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_close, fd, 0, 0, 0, 0, 0));
}

pub fn dup(fd: u16) Error!u16 {
    return @intCast(try result(zigos_syscall6(abi.syscall_dup, fd, 0, 0, 0, 0, 0)));
}

pub fn dup2(source: u16, destination: u16) Error!u16 {
    return @intCast(try result(zigos_syscall6(abi.syscall_dup2, source, destination, 0, 0, 0, 0)));
}

pub fn open(path: [*:0]const u8, flags: OpenFlags, mode: u16) Error!u16 {
    return @intCast(try result(zigos_syscall6(abi.syscall_open, ptrValue(path), flags.bits(), mode, 0, 0, 0)));
}

pub fn ticks() Error!u64 {
    return result(zigos_syscall6(abi.syscall_ticks, 0, 0, 0, 0, 0, 0));
}

pub fn spawn(path: []const u8) Error!u32 {
    return @intCast(try result(zigos_syscall6(abi.syscall_spawn, ptrValue(path.ptr), path.len, 0, 0, 0, 0)));
}

pub fn spawnv(path: []const u8, arguments: []const []const u8, environment: []const []const u8) Error!u32 {
    if (path.len == 0 or path.len > 255 or arguments.len == 0 or arguments.len > abi.maximum_arguments or
        environment.len > abi.maximum_environment) return Error.TooBig;
    var argument_descriptors: [abi.maximum_arguments]UserString = @splat(.{ .pointer = 0, .length = 0 });
    var environment_descriptors: [abi.maximum_environment]UserString = @splat(.{ .pointer = 0, .length = 0 });
    for (arguments, 0..) |argument, index| {
        if (argument.len == 0 or argument.len > abi.maximum_argument_bytes) return Error.NameTooLong;
        argument_descriptors[index] = .{ .pointer = ptrValue(argument.ptr), .length = @intCast(argument.len) };
    }
    for (environment, 0..) |entry, index| {
        if (entry.len == 0 or entry.len > abi.maximum_environment_bytes or !validEnvironmentEntry(entry))
            return Error.InvalidArgument;
        environment_descriptors[index] = .{ .pointer = ptrValue(entry.ptr), .length = @intCast(entry.len) };
    }
    const request = SpawnRequest{
        .path_pointer = ptrValue(path.ptr),
        .arguments_pointer = ptrValue(&argument_descriptors),
        .environment_pointer = if (environment.len == 0) 0 else ptrValue(&environment_descriptors),
        .path_length = @intCast(path.len),
        .argument_count = @intCast(arguments.len),
        .environment_count = @intCast(environment.len),
    };
    return @intCast(try result(zigos_syscall6(abi.syscall_spawnv, ptrValue(&request), 0, 0, 0, 0, 0)));
}

pub fn wait(pid: u32, nohang: bool, status: *WaitStatus) Error!u32 {
    return @intCast(try result(zigos_syscall6(abi.syscall_wait, pid, @intFromBool(nohang), ptrValue(status), 0, 0, 0)));
}

pub fn queryAbi(info: *AbiInfo) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_abi_query, ptrValue(info), @sizeOf(AbiInfo), 0, 0, 0, 0));
}

pub fn mmap(address: ?*anyopaque, length: usize, protection: Protection, flags: MapFlags) Error![]u8 {
    const raw = try result(zigos_syscall6(
        abi.syscall_mmap,
        if (address) |pointer| ptrValue(pointer) else 0,
        length,
        protection.bits(),
        flags.bits(),
        0xffff_ffff_ffff_ffff,
        0,
    ));
    return @as([*]u8, @ptrFromInt(raw))[0..length];
}

pub fn munmap(bytes: []u8) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_munmap, ptrValue(bytes.ptr), bytes.len, 0, 0, 0, 0));
}

pub fn mprotect(bytes: []u8, protection: Protection) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_mprotect, ptrValue(bytes.ptr), bytes.len, protection.bits(), 0, 0, 0));
}

pub fn brk(address: usize) Error!usize {
    return @intCast(try result(zigos_syscall6(abi.syscall_brk, address, 0, 0, 0, 0, 0)));
}

pub fn fstat(fd: u16, info: *Stat) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_fstat, fd, ptrValue(info), 0, 0, 0, 0));
}

pub fn stat(path: [*:0]const u8, info: *Stat) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_stat, ptrValue(path), ptrValue(info), 0, 0, 0, 0));
}

pub fn ioctl(fd: u16, request: u64, argument: u64) Error!u64 {
    return result(zigos_syscall6(abi.syscall_ioctl, fd, request, argument, 0, 0, 0));
}

pub fn openat(directory_fd: i64, path: [*:0]const u8, flags: OpenFlags, mode: u16) Error!u16 {
    return @intCast(try result(zigos_syscall6(
        abi.syscall_openat,
        @bitCast(directory_fd),
        ptrValue(path),
        flags.bits(),
        mode,
        0,
        0,
    )));
}

pub fn fsync(fd: u16) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_fsync, fd, 0, 0, 0, 0, 0));
}

pub fn fallocate(fd: u16, flags: FallocateFlags, offset: usize, length: usize) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_fallocate, fd, flags.bits(), offset, length, 0, 0));
}

pub fn getdents(fd: u16, entries: []DirectoryEntry) Error!usize {
    const bytes = entries.len * @sizeOf(DirectoryEntry);
    const returned = try result(zigos_syscall6(abi.syscall_getdents, fd, ptrValue(entries.ptr), bytes, 0, 0, 0));
    return @intCast(returned / @sizeOf(DirectoryEntry));
}

pub fn poll(descriptors: []PollDescriptor) Error!usize {
    return @intCast(try result(zigos_syscall6(abi.syscall_poll, ptrValue(descriptors.ptr), descriptors.len, 0, 0, 0, 0)));
}

pub fn socket() Error!u16 {
    return @intCast(try result(zigos_syscall6(abi.syscall_socket, abi.address_family_ipv4, abi.socket_datagram, abi.protocol_udp, 0, 0, 0)));
}

pub fn bind(fd: u16, address: *const Ipv4SocketAddress) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_bind, fd, ptrValue(address), @sizeOf(Ipv4SocketAddress), 0, 0, 0));
}

pub fn connect(fd: u16, address: *const Ipv4SocketAddress) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_connect, fd, ptrValue(address), @sizeOf(Ipv4SocketAddress), 0, 0, 0));
}

pub fn send(fd: u16, bytes: []const u8) Error!usize {
    return @intCast(try result(zigos_syscall6(abi.syscall_send, fd, ptrValue(bytes.ptr), bytes.len, 0, 0, 0)));
}

pub fn recv(fd: u16, bytes: []u8) Error!usize {
    return @intCast(try result(zigos_syscall6(abi.syscall_recv, fd, ptrValue(bytes.ptr), bytes.len, 0, 0, 0)));
}

pub fn getsockname(fd: u16, address: *Ipv4SocketAddress) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_getsockname, fd, ptrValue(address), @sizeOf(Ipv4SocketAddress), 0, 0, 0));
}

pub fn sendto(fd: u16, bytes: []const u8, address: *const Ipv4SocketAddress) Error!usize {
    return @intCast(try result(zigos_syscall6(
        abi.syscall_sendto,
        fd,
        ptrValue(bytes.ptr),
        bytes.len,
        0,
        ptrValue(address),
        @sizeOf(Ipv4SocketAddress),
    )));
}

pub fn recvfrom(fd: u16, bytes: []u8, address: *Ipv4SocketAddress, flags: MessageFlags) Error!usize {
    return @intCast(try result(zigos_syscall6(
        abi.syscall_recvfrom,
        fd,
        ptrValue(bytes.ptr),
        bytes.len,
        flags.bits(),
        ptrValue(address),
        @sizeOf(Ipv4SocketAddress),
    )));
}

pub fn getpeername(fd: u16, address: *Ipv4SocketAddress) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_getpeername, fd, ptrValue(address), @sizeOf(Ipv4SocketAddress), 0, 0, 0));
}

pub fn setNonblocking(fd: u16, enabled: bool) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_setnonblock, fd, @intFromBool(enabled), 0, 0, 0, 0));
}

pub const SeekWhence = enum(u64) {
    start = abi.seek_start,
    current = abi.seek_current,
    end = abi.seek_end,
};

pub fn lseek(fd: u16, offset: i64, whence: SeekWhence) Error!usize {
    return @intCast(try result(zigos_syscall6(
        abi.syscall_lseek,
        fd,
        @bitCast(offset),
        @intFromEnum(whence),
        0,
        0,
        0,
    )));
}

pub fn mkdir(path: [*:0]const u8, mode: u16) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_mkdir, ptrValue(path), mode, 0, 0, 0, 0));
}

pub fn unlink(path: [*:0]const u8) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_unlink, ptrValue(path), 0, 0, 0, 0, 0));
}

pub fn rmdir(path: [*:0]const u8) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_rmdir, ptrValue(path), 0, 0, 0, 0, 0));
}

pub fn rename(old_path: [*:0]const u8, new_path: [*:0]const u8) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_rename, ptrValue(old_path), ptrValue(new_path), 0, 0, 0, 0));
}

pub fn chmod(path: [*:0]const u8, mode: u16) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_chmod, ptrValue(path), mode, 0, 0, 0, 0));
}

pub fn symlink(target: [*:0]const u8, path: [*:0]const u8) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_symlink, ptrValue(target), ptrValue(path), 0, 0, 0, 0));
}

pub fn readlink(path: [*:0]const u8, output: []u8) Error!usize {
    return @intCast(try result(zigos_syscall6(abi.syscall_readlink, ptrValue(path), ptrValue(output.ptr), output.len, 0, 0, 0)));
}

pub fn link(old_path: [*:0]const u8, new_path: [*:0]const u8) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_link, ptrValue(old_path), ptrValue(new_path), 0, 0, 0, 0));
}

pub fn sync() Error!void {
    _ = try result(zigos_syscall6(abi.syscall_sync, 0, 0, 0, 0, 0, 0));
}

pub fn shutdown() Error!void {
    _ = try result(zigos_syscall6(abi.syscall_shutdown, 0, 0, 0, 0, 0, 0));
}

pub fn getcwd(buffer: []u8) Error![]const u8 {
    const length = try result(zigos_syscall6(abi.syscall_getcwd, ptrValue(buffer.ptr), buffer.len, 0, 0, 0, 0));
    return buffer[0..@intCast(length)];
}

pub fn chdir(path: [*:0]const u8) Error!void {
    _ = try result(zigos_syscall6(abi.syscall_chdir, ptrValue(path), 0, 0, 0, 0, 0));
}

pub fn environmentValue(envp: [*]const usize, key: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (index < abi.maximum_environment and envp[index] != 0) : (index += 1) {
        const pointer: [*:0]const u8 = @ptrFromInt(envp[index]);
        const length = stringLength(pointer);
        const entry = pointer[0..length];
        if (entry.len > key.len and entry[key.len] == '=' and bytesEqual(entry[0..key.len], key))
            return entry[key.len + 1 ..];
    }
    return null;
}

pub fn collectEnvironment(envp: [*]const usize, output: [][]const u8) ?[]const []const u8 {
    var count: usize = 0;
    while (count < output.len and count < abi.maximum_environment and envp[count] != 0) : (count += 1) {
        const pointer: [*:0]const u8 = @ptrFromInt(envp[count]);
        const length = stringLength(pointer);
        const entry = pointer[0..length];
        if (!validEnvironmentEntry(entry)) return null;
        output[count] = entry;
    }
    if (count == output.len and count < abi.maximum_environment and envp[count] != 0) return null;
    return output[0..count];
}

pub fn auxiliaryValue(auxv: [*]const AuxvEntry, kind: u64) ?u64 {
    var index: usize = 0;
    while (index < 32) : (index += 1) {
        const entry = auxv[index];
        if (entry.kind == abi.aux_null) return null;
        if (entry.kind == kind) return entry.value;
    }
    return null;
}

fn validEnvironmentEntry(entry: []const u8) bool {
    var separator: ?usize = null;
    for (entry, 0..) |byte, index| {
        if (byte == 0) return false;
        if (byte == '=' and separator == null) separator = index;
    }
    return if (separator) |index| index != 0 else false;
}

fn bytesEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |a, b| if (a != b) return false;
    return true;
}

pub fn writeAll(fd: u16, bytes: []const u8) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = try write(fd, bytes[offset..]);
        if (count == 0) return Error.InputOutput;
        offset += count;
    }
}

pub fn stringLength(value: [*:0]const u8) usize {
    var length: usize = 0;
    while (value[length] != 0) : (length += 1) {}
    return length;
}

pub fn stringEqual(value: [*:0]const u8, expected: []const u8) bool {
    const length = stringLength(value);
    if (length != expected.len) return false;
    for (expected, 0..) |byte, index| if (value[index] != byte) return false;
    return true;
}
