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

int64_t zigos_ioctl(uint16_t fd, uint64_t request, uint64_t argument) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_IOCTL, fd, request, argument, 0, 0, 0);
}

int64_t zigos_fsync(uint16_t fd) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_FSYNC, fd, 0, 0, 0, 0, 0);
}

int64_t zigos_fdatasync(uint16_t fd) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_FDATASYNC, fd, 0, 0, 0, 0, 0);
}

int64_t zigos_fallocate(uint16_t fd, uint64_t mode, uint64_t offset, uint64_t length) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_FALLOCATE, fd, mode, offset, length, 0, 0);
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
