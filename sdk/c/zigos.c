#include "zigos.h"

static uint64_t pointer_value(const void *pointer) {
    return (uint64_t)(uintptr_t)pointer;
}

int64_t zigos_exit(uint32_t status) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_EXIT, status, 0, 0, 0, 0, 0);
}

int64_t zigos_write(uint16_t fd, const void *bytes, size_t length) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_WRITE, fd, pointer_value(bytes), length, 0, 0, 0);
}

int64_t zigos_read(uint16_t fd, void *bytes, size_t length) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_READ, fd, pointer_value(bytes), length, 0, 0, 0);
}

int64_t zigos_readv(uint16_t fd, const zigos_iovec *vectors, size_t count) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_READV, fd, pointer_value(vectors), count, 0, 0, 0);
}

int64_t zigos_writev(uint16_t fd, const zigos_iovec *vectors, size_t count) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_WRITEV, fd, pointer_value(vectors), count, 0, 0, 0);
}

int64_t zigos_close(uint16_t fd) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_CLOSE, fd, 0, 0, 0, 0, 0);
}

int64_t zigos_socket(uint16_t domain, uint16_t type, uint16_t protocol) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_SOCKET, domain, type, protocol, 0, 0, 0);
}

int64_t zigos_bind(uint16_t fd, const zigos_ipv4_socket_address *address) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_BIND, fd, pointer_value(address), sizeof(*address), 0, 0, 0);
}

int64_t zigos_connect(uint16_t fd, const zigos_ipv4_socket_address *address) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_CONNECT, fd, pointer_value(address), sizeof(*address), 0, 0, 0);
}

int64_t zigos_listen(uint16_t fd, uint16_t backlog) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_LISTEN, fd, backlog, 0, 0, 0, 0);
}

int64_t zigos_accept(uint16_t fd, zigos_ipv4_socket_address *address) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_ACCEPT, fd, address == NULL ? 0 : pointer_value(address), address == NULL ? 0 : sizeof(*address), 0, 0, 0);
}

int64_t zigos_socket_shutdown(uint16_t fd, uint64_t how) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_SOCKET_SHUTDOWN, fd, how, 0, 0, 0, 0);
}

int64_t zigos_getsockopt(uint16_t fd, uint64_t level, uint64_t option) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_GETSOCKOPT, fd, level, option, 0, 0, 0);
}

int64_t zigos_setsockopt(uint16_t fd, uint64_t level, uint64_t option, uint64_t value) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_SETSOCKOPT, fd, level, option, value, 0, 0);
}

int64_t zigos_getsockname(uint16_t fd, zigos_ipv4_socket_address *address) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_GETSOCKNAME, fd, pointer_value(address), sizeof(*address), 0, 0, 0);
}

int64_t zigos_getpeername(uint16_t fd, zigos_ipv4_socket_address *address) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_GETPEERNAME, fd, pointer_value(address), sizeof(*address), 0, 0, 0);
}

int64_t zigos_open(const char *path, uint64_t flags, uint16_t mode) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_OPEN, pointer_value(path), flags, mode, 0, 0, 0);
}

int64_t zigos_openat(int64_t directory_fd, const char *path, uint64_t flags, uint16_t mode) {
    return (int64_t)zigos_syscall6(
        ZIGOS_SYS_OPENAT,
        (uint64_t)directory_fd,
        pointer_value(path),
        flags,
        mode,
        0,
        0
    );
}

int64_t zigos_fstat(uint16_t fd, zigos_stat *info) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_FSTAT, fd, pointer_value(info), 0, 0, 0, 0);
}

int64_t zigos_stat_path(const char *path, zigos_stat *info) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_STAT, pointer_value(path), pointer_value(info), 0, 0, 0, 0);
}

int64_t zigos_stattimes(const char *path, zigos_file_times *times) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_STATTIMES, pointer_value(path), pointer_value(times), 0, 0, 0, 0);
}

int64_t zigos_statowner(const char *path, zigos_file_owner *owner) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_STATOWNER, pointer_value(path), pointer_value(owner), 0, 0, 0, 0);
}

int64_t zigos_statfs(const char *path, zigos_filesystem_stat *info) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_STATFS, pointer_value(path), pointer_value(info), 0, 0, 0, 0);
}

int64_t zigos_umask(uint16_t mask) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_UMASK, mask, 0, 0, 0, 0, 0);
}

int64_t zigos_flock(uint16_t fd, uint64_t operation) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_FLOCK, fd, operation, 0, 0, 0, 0);
}

int64_t zigos_lockrange(uint16_t fd, uint64_t start, uint64_t length, uint64_t operation) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_LOCKRANGE, fd, start, length, operation, 0, 0);
}

int64_t zigos_watchdir(uint16_t directory_fd) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_WATCHDIR, directory_fd, 0, 0, 0, 0, 0);
}

int64_t zigos_kill(uint32_t pid, uint8_t signal) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_KILL, pid, signal, 0, 0, 0, 0);
}

int64_t zigos_fscheck(void) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_FSCHECK, 0, 0, 0, 0, 0, 0);
}

int64_t zigos_ioctl(uint16_t fd, uint64_t request, uint64_t argument) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_IOCTL, fd, request, argument, 0, 0, 0);
}

int64_t zigos_fsync(uint16_t fd) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_FSYNC, fd, 0, 0, 0, 0, 0);
}

int64_t zigos_fdatasync(uint16_t fd) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_FDATASYNC, fd, 0, 0, 0, 0, 0);
}

int64_t zigos_mount(const char *source, const char *target, const char *filesystem, uint64_t flags, const void *data) {
    return (int64_t)zigos_syscall6(
        ZIGOS_SYS_MOUNT,
        pointer_value(source),
        pointer_value(target),
        pointer_value(filesystem),
        flags,
        pointer_value(data),
        0
    );
}

int64_t zigos_umount(const char *target, uint64_t flags) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_UMOUNT, pointer_value(target), flags, 0, 0, 0, 0);
}

int64_t zigos_fallocate(uint16_t fd, uint64_t mode, uint64_t offset, uint64_t length) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_FALLOCATE, fd, mode, offset, length, 0, 0);
}

int64_t zigos_mmap_file(uint64_t address, size_t length, uint64_t protection, uint64_t flags, uint16_t fd, uint64_t offset) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_MMAP, address, length, protection, flags, fd, offset);
}

int64_t zigos_munmap(const void *address, size_t length) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_MUNMAP, pointer_value(address), length, 0, 0, 0, 0);
}

int64_t zigos_symlink(const char *target, const char *path) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_SYMLINK, pointer_value(target), pointer_value(path), 0, 0, 0, 0);
}

int64_t zigos_readlink(const char *path, void *bytes, size_t length) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_READLINK, pointer_value(path), pointer_value(bytes), length, 0, 0, 0);
}

int64_t zigos_link(const char *old_path, const char *new_path) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_LINK, pointer_value(old_path), pointer_value(new_path), 0, 0, 0, 0);
}

int64_t zigos_abi_query(zigos_abi_info *info) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_ABI_QUERY, pointer_value(info), sizeof(*info), 0, 0, 0, 0);
}
