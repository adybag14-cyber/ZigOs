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
    if (!emit("c-sdk: ABI 1.6 discovery passed\r\n")) {
        return 0xC4;
    }

    zigos_stat info = {0};
    if (zigos_stat_path("/dev/null", &info) != 0 || info.kind != 2 ||
        info.readonly != 0 || info.mode != 0666) {
        return fail(0xC5, "path stat /dev/null");
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

    int64_t host_fd = zigos_openat(ZIGOS_AT_CWD, "/etc/hostname", ZIGOS_OPEN_READ, 0);
    if (host_fd < 0 || zigos_fsync((uint16_t)host_fd) != 0 || zigos_close((uint16_t)host_fd) != 0) {
        return fail(0xCE, "descriptor fsync");
    }

    if (!emit("c-sdk: generated header/library/device/ioctl/stat/directory-openat/fsync passed\r\n")) {
        return 0xCF;
    }
    return 0x57;
}
