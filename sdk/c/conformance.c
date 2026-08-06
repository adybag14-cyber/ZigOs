#include "zigos.h"

static size_t text_length(const char *text) {
    size_t length = 0;
    while (text[length] != '\0') {
        ++length;
    }
    return length;
}

static int text_equal(const char *left, const char *right) {
    size_t index = 0;
    while (left[index] != '\0' && right[index] != '\0') {
        if (left[index] != right[index]) {
            return 0;
        }
        ++index;
    }
    return left[index] == right[index];
}

static int text_starts_with(const char *text, size_t length, const char *prefix) {
    size_t index = 0;
    while (prefix[index] != '\0') {
        if (index >= length || text[index] != prefix[index]) {
            return 0;
        }
        ++index;
    }
    return 1;
}

static int emit(const char *text) {
    const size_t length = text_length(text);
    return zigos_write(1, text, length) == (int64_t)length;
}

static int64_t remove_path(const char *path) {
    return (int64_t)zigos_syscall6(ZIGOS_SYS_UNLINK, (uint64_t)(uintptr_t)path, 0, 0, 0, 0, 0);
}

static uint32_t fail(uint32_t status, const char *message) {
    (void)emit("c-sdk: failure: ");
    (void)emit(message);
    (void)emit("\r\n");
    return status;
}

uint32_t zigos_main(size_t argc, const uintptr_t *argv, const uintptr_t *envp, const zigos_auxv_entry *auxv) {
    (void)envp;
    (void)auxv;
    if (!emit("c-sdk: start\r\n")) {
        return 0xC0;
    }

    if (argc != 3 || argv == 0 ||
        !text_equal((const char *)(uintptr_t)argv[1], "alpha") ||
        !text_equal((const char *)(uintptr_t)argv[2], "beta")) {
        return fail(0xC1, "argc/argv");
    }
    if (!emit("c-sdk: argc/argv passed\r\n")) {
        return 0xC2;
    }

    zigos_abi_info abi = {0};
    if (zigos_abi_query(&abi) != (int64_t)sizeof(abi) ||
        abi.magic != ZIGOS_ABI_MAGIC || abi.major != ZIGOS_ABI_MAJOR ||
        abi.minor < ZIGOS_ABI_MINOR || abi.syscall_count < ZIGOS_SYSCALL_COUNT ||
        (abi.capabilities & (ZIGOS_CAP_VFS | ZIGOS_CAP_TERMINAL | ZIGOS_CAP_PSEUDO_FILES)) !=
            (ZIGOS_CAP_VFS | ZIGOS_CAP_TERMINAL | ZIGOS_CAP_PSEUDO_FILES) ||
        abi.maximum_sockets > 4) {
        return fail(0xC3, "ABI discovery");
    }
    if (!emit("c-sdk: ABI 1.18 discovery passed\r\n")) {
        return 0xC4;
    }

    zigos_filesystem_stat root_fs = {0};
    zigos_filesystem_stat dev_fs = {0};
    if (zigos_statfs("/", &root_fs) != 0 || root_fs.filesystem_kind != ZIGOS_FS_TYPE_RAMFS ||
        root_fs.block_size != ZIGOS_PAGE_SIZE || root_fs.total_blocks != 256 ||
        root_fs.free_blocks > root_fs.total_blocks || root_fs.available_blocks != root_fs.free_blocks ||
        root_fs.total_nodes != 96 || root_fs.free_nodes > root_fs.total_nodes || root_fs.mount_id != 1 ||
        (root_fs.flags & (ZIGOS_FS_STAT_SHARED_BLOCKS | ZIGOS_FS_STAT_SHARED_NODES)) !=
            (ZIGOS_FS_STAT_SHARED_BLOCKS | ZIGOS_FS_STAT_SHARED_NODES) ||
        zigos_statfs("/dev/null", &dev_fs) != 0 || dev_fs.filesystem_kind != ZIGOS_FS_TYPE_DEVFS ||
        dev_fs.total_blocks != 0 || dev_fs.free_blocks != 0 ||
        (dev_fs.flags & (ZIGOS_FS_STAT_READ_ONLY | ZIGOS_FS_STAT_SHARED_NODES | ZIGOS_FS_STAT_SYNTHETIC)) !=
            (ZIGOS_FS_STAT_READ_ONLY | ZIGOS_FS_STAT_SHARED_NODES | ZIGOS_FS_STAT_SYNTHETIC)) {
        return fail(0xD8, "filesystem statfs");
    }

    zigos_stat info = {0};
    if (zigos_stat_path("/dev/null", &info) != 0 || info.kind != 2 ||
        info.readonly != 0 || info.mode != 0666) {
        return fail(0xC5, "path stat /dev/null");
    }
    zigos_file_times dev_times = {0};
    if (sizeof(dev_times) != 32 || zigos_stattimes("/dev/null", &dev_times) != 0 ||
        dev_times.modified_tick != info.modified_tick) {
        return fail(0xDA, "path timestamps /dev/null");
    }
    zigos_file_owner dev_owner = {0};
    if (sizeof(dev_owner) != 8 || zigos_statowner("/dev/null", &dev_owner) != 0 || dev_owner.uid != 0 || dev_owner.gid != 0) {
        return fail(0xDB, "path owner /dev/null");
    }

    static const char umask_path[] = "/tmp/c-sdk-umask";
    (void)remove_path(umask_path);
    if (zigos_umask(0027) != 0 || zigos_umask(01000) != ZIGOS_ERRNO_INVALID) {
        return fail(0xDC, "umask set/invalid");
    }
    int64_t umask_fd = zigos_open(umask_path, ZIGOS_OPEN_READ | ZIGOS_OPEN_WRITE | ZIGOS_OPEN_CREATE, 0666);
    zigos_stat umask_info = {0};
    if (umask_fd < 0 || zigos_close((uint16_t)umask_fd) != 0 || zigos_stat_path(umask_path, &umask_info) != 0 ||
        umask_info.mode != 0640 || zigos_umask(0) != 0027) {
        return fail(0xDD, "umask creation");
    }
    if (remove_path(umask_path) != 0 || !emit("c-sdk: process umask creation passed\r\n")) {
        return fail(0xDE, "umask cleanup");
    }

    static const char setid_path[] = "/tmp/c-sdk-setid";
    (void)remove_path(setid_path);
    int64_t setid_fd = zigos_open(setid_path, ZIGOS_OPEN_READ | ZIGOS_OPEN_WRITE | ZIGOS_OPEN_CREATE, 06755);
    zigos_stat setid_info = {0};
    if (setid_fd < 0 || zigos_close((uint16_t)setid_fd) != 0 || zigos_stat_path(setid_path, &setid_info) != 0 || setid_info.mode != 06755 ||
        (int64_t)zigos_syscall6(ZIGOS_SYS_CHMOD, (uint64_t)(uintptr_t)setid_path, 06650, 0, 0, 0, 0) != 0 ||
        zigos_stat_path(setid_path, &setid_info) != 0 || setid_info.mode != 06650 ||
        (int64_t)zigos_syscall6(ZIGOS_SYS_CHMOD, (uint64_t)(uintptr_t)setid_path, 07650, 0, 0, 0, 0) != 0 ||
        zigos_stat_path(setid_path, &setid_info) != 0 || setid_info.mode != 07650) {
        return fail(0xDF, "setid/sticky metadata");
    }
    if (remove_path(setid_path) != 0 || !emit("c-sdk: setuid/setgid metadata passed\r\n")) {
        return fail(0xB0, "setid cleanup");
    }

    static const char flock_path[] = "/tmp/c-sdk-flock";
    (void)remove_path(flock_path);
    int64_t flock_fd = zigos_open(flock_path, ZIGOS_OPEN_READ | ZIGOS_OPEN_WRITE | ZIGOS_OPEN_CREATE | ZIGOS_OPEN_TRUNCATE, 0666);
    int64_t flock_alias = flock_fd < 0 ? flock_fd : (int64_t)zigos_syscall6(ZIGOS_SYS_DUP, (uint64_t)flock_fd, 0, 0, 0, 0, 0);
    int64_t flock_other = flock_alias < 0 ? flock_alias : zigos_open(flock_path, ZIGOS_OPEN_READ | ZIGOS_OPEN_WRITE, 0);
    if (flock_fd < 0 || flock_alias < 0 || flock_other < 0 ||
        zigos_flock((uint16_t)flock_fd, ZIGOS_LOCK_EXCLUSIVE | ZIGOS_LOCK_NONBLOCK) != 0 ||
        zigos_flock((uint16_t)flock_alias, ZIGOS_LOCK_EXCLUSIVE | ZIGOS_LOCK_NONBLOCK) != 0 ||
        zigos_flock((uint16_t)flock_other, ZIGOS_LOCK_SHARED | ZIGOS_LOCK_NONBLOCK) != ZIGOS_ERRNO_WOULD_BLOCK ||
        zigos_flock((uint16_t)flock_other, ZIGOS_LOCK_SHARED | ZIGOS_LOCK_EXCLUSIVE) != ZIGOS_ERRNO_INVALID ||
        zigos_flock((uint16_t)flock_other, ZIGOS_LOCK_UNLOCK | ZIGOS_LOCK_NONBLOCK) != ZIGOS_ERRNO_INVALID ||
        zigos_write((uint16_t)flock_other, "!", 1) != 1) {
        return fail(0xB1, "flock conflict/advisory");
    }
    if (zigos_close((uint16_t)flock_fd) != 0 ||
        zigos_flock((uint16_t)flock_other, ZIGOS_LOCK_SHARED | ZIGOS_LOCK_NONBLOCK) != ZIGOS_ERRNO_WOULD_BLOCK ||
        zigos_close((uint16_t)flock_alias) != 0 ||
        zigos_flock((uint16_t)flock_other, ZIGOS_LOCK_EXCLUSIVE | ZIGOS_LOCK_NONBLOCK) != 0 ||
        zigos_flock((uint16_t)flock_other, ZIGOS_LOCK_UNLOCK) != 0 ||
        zigos_close((uint16_t)flock_other) != 0) {
        return fail(0xB2, "flock lifetime");
    }
    if (remove_path(flock_path) != 0 || !emit("c-sdk: advisory whole-file flock passed\r\n")) {
        return fail(0xB3, "flock cleanup");
    }

    int64_t null_fd = zigos_open("/dev/null", ZIGOS_OPEN_READ | ZIGOS_OPEN_WRITE, 0);
    if (null_fd < 0) {
        return fail(0xC6, "open /dev/null");
    }
    static const char discarded[] = "discarded by null";
    if (zigos_write((uint16_t)null_fd, discarded, sizeof(discarded) - 1) != (int64_t)(sizeof(discarded) - 1) ||
        zigos_read((uint16_t)null_fd, &info, sizeof(info)) != 0 ||
        zigos_close((uint16_t)null_fd) != 0) {
        return fail(0xC7, "/dev/null semantics");
    }

    int64_t zero_fd = zigos_open("/dev/zero", ZIGOS_OPEN_READ | ZIGOS_OPEN_WRITE, 0);
    uint8_t zeros[16];
    if (zero_fd < 0 || zigos_read((uint16_t)zero_fd, zeros, sizeof(zeros)) != (int64_t)sizeof(zeros)) {
        return fail(0xC8, "read /dev/zero");
    }
    for (size_t index = 0; index < sizeof(zeros); ++index) {
        if (zeros[index] != 0) {
            return fail(0xC9, "/dev/zero content");
        }
    }
    if (zigos_write((uint16_t)zero_fd, discarded, sizeof(discarded) - 1) != (int64_t)(sizeof(discarded) - 1) ||
        zigos_close((uint16_t)zero_fd) != 0) {
        return fail(0xCA, "/dev/zero write/close");
    }

    int64_t console_fd = zigos_open("/dev/console", ZIGOS_OPEN_WRITE, 0);
    if (console_fd < 0) {
        return fail(0xCB, "open /dev/console");
    }
    const int64_t tty_flags = zigos_ioctl((uint16_t)console_fd, ZIGOS_IOCTL_TTY_GET_FLAGS, 0);
    if (tty_flags < 0 || ((uint64_t)tty_flags & (ZIGOS_TTY_ECHO | ZIGOS_TTY_CANONICAL | ZIGOS_TTY_SIGNALS)) == 0 ||
        zigos_ioctl((uint16_t)console_fd, ZIGOS_IOCTL_TTY_SET_FLAGS, (uint64_t)tty_flags) != 0 ||
        zigos_fstat((uint16_t)console_fd, &info) != 0 || info.mode != 0666 ||
        zigos_close((uint16_t)console_fd) != 0) {
        return fail(0xCC, "/dev/console ioctl/stat");
    }

    int64_t proc_fd = zigos_open("/proc", ZIGOS_OPEN_READ, 0);
    int64_t version_fd = proc_fd < 0 ? proc_fd : zigos_openat(proc_fd, "version", ZIGOS_OPEN_READ, 0);
    char version[64];
    const int64_t version_length = version_fd < 0 ? version_fd : zigos_read((uint16_t)version_fd, version, sizeof(version));
    const int64_t nondirectory = version_fd < 0 ? version_fd : zigos_openat(version_fd, "child", ZIGOS_OPEN_READ, 0);
    const int64_t absolute_fd = zigos_openat(INT64_C(32767), "/etc/hostname", ZIGOS_OPEN_READ, 0);
    if (proc_fd < 0 || version_fd < 0 || version_length <= 0 ||
        !text_starts_with(version, (size_t)version_length, "ZigOs 19.0.0") ||
        nondirectory != ZIGOS_ERRNO_NOT_DIRECTORY || absolute_fd < 0 ||
        zigos_close((uint16_t)absolute_fd) != 0 || zigos_close((uint16_t)version_fd) != 0 ||
        zigos_close((uint16_t)proc_fd) != 0) {
        return fail(0xCD, "directory-relative/absolute openat");
    }

    static const char link_path[] = "/tmp/c-sdk-hostname";
    static const char link_target[] = "/etc/hostname";
    static const char loop_a[] = "/tmp/c-sdk-loop-a";
    static const char loop_b[] = "/tmp/c-sdk-loop-b";
    (void)remove_path(link_path);
    (void)remove_path(loop_a);
    (void)remove_path(loop_b);
    char read_target[32] = {0};
    if (zigos_symlink(link_target, link_path) != 0) {
        return fail(0xCE, "create symlink");
    }
    const int64_t target_length = zigos_readlink(link_path, read_target, sizeof(read_target) - 1);
    int64_t link_fd = zigos_open(link_path, ZIGOS_OPEN_READ, 0);
    char link_contents[32];
    const int64_t link_length = link_fd < 0 ? link_fd : zigos_read((uint16_t)link_fd, link_contents, sizeof(link_contents));
    if (target_length != (int64_t)(sizeof(link_target) - 1) || !text_equal(read_target, link_target) ||
        link_fd < 0 || link_length <= 0 || zigos_close((uint16_t)link_fd) != 0) {
        return fail(0xCF, "symlink/readlink traversal");
    }
    if (zigos_symlink("c-sdk-loop-b", loop_a) != 0 || zigos_symlink("c-sdk-loop-a", loop_b) != 0 ||
        zigos_open(loop_a, ZIGOS_OPEN_READ, 0) != ZIGOS_ERRNO_LOOP ||
        remove_path(loop_a) != 0 || remove_path(loop_b) != 0 || remove_path(link_path) != 0) {
        return fail(0xD0, "symlink loop/cleanup");
    }

    static const char hard_source[] = "/tmp/c-sdk-hard-source";
    static const char hard_alias[] = "/tmp/c-sdk-hard-alias";
    (void)remove_path(hard_source);
    (void)remove_path(hard_alias);
    int64_t hard_fd = zigos_open(hard_source, ZIGOS_OPEN_READ | ZIGOS_OPEN_WRITE | ZIGOS_OPEN_CREATE | ZIGOS_OPEN_TRUNCATE, 0644);
    static const char hard_payload[] = "hard-link-data";
    if (hard_fd < 0 || zigos_write((uint16_t)hard_fd, hard_payload, sizeof(hard_payload) - 1) != (int64_t)(sizeof(hard_payload) - 1) ||
        zigos_close((uint16_t)hard_fd) != 0 || zigos_link(hard_source, hard_alias) != 0) {
        return fail(0xD1, "hard link create");
    }
    zigos_stat hard_source_info = {0};
    zigos_stat hard_alias_info = {0};
    zigos_file_times hard_source_times = {0};
    zigos_file_times hard_alias_times = {0};
    zigos_file_owner hard_source_owner = {0};
    zigos_file_owner hard_alias_owner = {0};
    if (zigos_statowner(hard_source, &hard_source_owner) != 0 || zigos_statowner(hard_alias, &hard_alias_owner) != 0 ||
        hard_source_owner.uid != hard_alias_owner.uid || hard_source_owner.gid != hard_alias_owner.gid ||
        zigos_stattimes(hard_source, &hard_source_times) != 0 || zigos_stattimes(hard_alias, &hard_alias_times) != 0 ||
        hard_source_times.created_tick != hard_alias_times.created_tick ||
        hard_source_times.modified_tick != hard_alias_times.modified_tick ||
        hard_source_times.changed_tick != hard_alias_times.changed_tick ||
        hard_source_times.accessed_tick != hard_alias_times.accessed_tick) {
        return fail(0xD9, "hard link timestamp identity");
    }
    if (zigos_stat_path(hard_source, &hard_source_info) != 0 || zigos_stat_path(hard_alias, &hard_alias_info) != 0 ||
        hard_source_info.node != hard_alias_info.node || hard_source_info.generation != hard_alias_info.generation ||
        hard_source_info.link_count != 2 || hard_alias_info.link_count != 2 || remove_path(hard_source) != 0 ||
        zigos_stat_path(hard_alias, &hard_alias_info) != 0 || hard_alias_info.link_count != 1) {
        return fail(0xD2, "hard link identity/count");
    }
    hard_fd = zigos_open(hard_alias, ZIGOS_OPEN_READ, 0);
    char hard_contents[sizeof(hard_payload)] = {0};
    if (hard_fd < 0 || zigos_read((uint16_t)hard_fd, hard_contents, sizeof(hard_payload) - 1) != (int64_t)(sizeof(hard_payload) - 1) ||
        !text_equal(hard_contents, hard_payload) || zigos_close((uint16_t)hard_fd) != 0 || remove_path(hard_alias) != 0) {
        return fail(0xD3, "hard link shared data/cleanup");
    }

    static const char sparse_path[] = "/tmp/c-sdk-sparse";
    (void)remove_path(sparse_path);
    int64_t sparse_fd = zigos_open(sparse_path, ZIGOS_OPEN_READ | ZIGOS_OPEN_WRITE | ZIGOS_OPEN_CREATE | ZIGOS_OPEN_TRUNCATE, 0600);
    zigos_stat sparse_info = {0};
    uint8_t sparse_zeros[4] = {1, 1, 1, 1};
    if (sparse_fd < 0 ||
        zigos_fallocate((uint16_t)sparse_fd, ZIGOS_FALLOCATE_KEEP_SIZE, 0, ZIGOS_PAGE_SIZE) != 0 ||
        zigos_fstat((uint16_t)sparse_fd, &sparse_info) != 0 || sparse_info.size != 0 ||
        zigos_fallocate((uint16_t)sparse_fd, 0, 2 * ZIGOS_PAGE_SIZE, 4) != 0 ||
        zigos_syscall6(ZIGOS_SYS_LSEEK, (uint16_t)sparse_fd, 2 * ZIGOS_PAGE_SIZE, ZIGOS_SEEK_START, 0, 0, 0) != 2 * ZIGOS_PAGE_SIZE ||
        zigos_write((uint16_t)sparse_fd, "DATA", 4) != 4 ||
        zigos_fallocate((uint16_t)sparse_fd, ZIGOS_FALLOCATE_PUNCH_HOLE, 2 * ZIGOS_PAGE_SIZE, ZIGOS_PAGE_SIZE) != (uint64_t)ZIGOS_ERRNO_INVALID ||
        zigos_fallocate((uint16_t)sparse_fd, ZIGOS_FALLOCATE_KEEP_SIZE | ZIGOS_FALLOCATE_PUNCH_HOLE, 2 * ZIGOS_PAGE_SIZE, ZIGOS_PAGE_SIZE) != 0 ||
        zigos_fstat((uint16_t)sparse_fd, &sparse_info) != 0 || sparse_info.size != 2 * ZIGOS_PAGE_SIZE + 4 ||
        zigos_syscall6(ZIGOS_SYS_LSEEK, (uint16_t)sparse_fd, 2 * ZIGOS_PAGE_SIZE, ZIGOS_SEEK_START, 0, 0, 0) != 2 * ZIGOS_PAGE_SIZE ||
        zigos_read((uint16_t)sparse_fd, sparse_zeros, sizeof(sparse_zeros)) != (int64_t)sizeof(sparse_zeros) ||
        sparse_zeros[0] != 0 || sparse_zeros[1] != 0 || sparse_zeros[2] != 0 || sparse_zeros[3] != 0 ||
        zigos_close((uint16_t)sparse_fd) != 0 || remove_path(sparse_path) != 0) {
        return fail(0xD4, "fallocate sparse keep-size/punch");
    }

    static const char vector_path[] = "/tmp/c-sdk-vectors";
    (void)remove_path(vector_path);
    int64_t vector_fd = zigos_open(vector_path, ZIGOS_OPEN_READ | ZIGOS_OPEN_WRITE | ZIGOS_OPEN_CREATE | ZIGOS_OPEN_TRUNCATE, 0600);
    static const char vector_a[] = "vec";
    static const char vector_b[] = "tor";
    static const char vector_c[] = "-io";
    const zigos_iovec write_vectors[] = {
        {(uint64_t)(uintptr_t)vector_a, sizeof(vector_a) - 1},
        {0, 0},
        {(uint64_t)(uintptr_t)vector_b, sizeof(vector_b) - 1},
        {(uint64_t)(uintptr_t)vector_c, sizeof(vector_c) - 1},
    };
    const zigos_iovec invalid_write_vectors[] = {
        {(uint64_t)(uintptr_t)vector_a, sizeof(vector_a) - 1},
        {0, 1},
    };
    char vector_first[2] = {0};
    char vector_second[3] = {0};
    char vector_third[4] = {0};
    const zigos_iovec read_vectors[] = {
        {(uint64_t)(uintptr_t)vector_first, sizeof(vector_first)},
        {(uint64_t)(uintptr_t)vector_second, sizeof(vector_second)},
        {(uint64_t)(uintptr_t)vector_third, sizeof(vector_third)},
    };
    const zigos_iovec invalid_read_vectors[] = {
        {(uint64_t)(uintptr_t)vector_first, sizeof(vector_first)},
        {0, 1},
    };
    const zigos_iovec oversized_vector = {0, 1025};
    if (vector_fd < 0 ||
        zigos_writev((uint16_t)vector_fd, invalid_write_vectors, sizeof(invalid_write_vectors) / sizeof(invalid_write_vectors[0])) != ZIGOS_ERRNO_FAULT ||
        zigos_fstat((uint16_t)vector_fd, &info) != 0 || info.size != 0 ||
        zigos_writev((uint16_t)vector_fd, 0, 0) != 0 ||
        zigos_writev((uint16_t)vector_fd, write_vectors, sizeof(write_vectors) / sizeof(write_vectors[0])) != 9 ||
        zigos_syscall6(ZIGOS_SYS_LSEEK, (uint16_t)vector_fd, 0, ZIGOS_SEEK_START, 0, 0, 0) != 0 ||
        zigos_readv((uint16_t)vector_fd, invalid_read_vectors, sizeof(invalid_read_vectors) / sizeof(invalid_read_vectors[0])) != ZIGOS_ERRNO_FAULT ||
        zigos_readv((uint16_t)vector_fd, read_vectors, sizeof(read_vectors) / sizeof(read_vectors[0])) != 9 ||
        vector_first[0] != 'v' || vector_first[1] != 'e' ||
        vector_second[0] != 'c' || vector_second[1] != 't' || vector_second[2] != 'o' ||
        vector_third[0] != 'r' || vector_third[1] != '-' || vector_third[2] != 'i' || vector_third[3] != 'o' ||
        zigos_writev((uint16_t)vector_fd, write_vectors, ZIGOS_MAX_IOVECS + 1) != ZIGOS_ERRNO_INVALID ||
        zigos_writev((uint16_t)vector_fd, &oversized_vector, 1) != ZIGOS_ERRNO_TOO_BIG ||
        zigos_close((uint16_t)vector_fd) != 0 || remove_path(vector_path) != 0) {
        return fail(0xD5, "readv/writev gather/scatter/limits");
    }

    int64_t host_fd = zigos_openat(ZIGOS_AT_CWD, "/etc/hostname", ZIGOS_OPEN_READ, 0);
    if (host_fd < 0 || zigos_fsync((uint16_t)host_fd) != 0 || zigos_fdatasync((uint16_t)host_fd) != 0 || zigos_close((uint16_t)host_fd) != 0) {
        return fail(0xD6, "descriptor fsync/fdatasync");
    }

    if (!emit("c-sdk: generated header/library/device/ioctl/stat/statfs/stattimes/statowner/umask/setid-metadata/flock/directory-openat/fsync/fdatasync/symlink/readlink/link/nlink/fallocate/sparse/readv/writev passed\r\n")) {
        return 0xD7;
    }
    return 0x57;
}
