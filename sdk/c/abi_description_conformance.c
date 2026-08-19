#include "zigos_abi.h"

_Static_assert(ZIGOS_ABI_MAGIC == UINT32_C(0x4942415A), "ABI magic");
_Static_assert(ZIGOS_ABI_MAJOR == UINT16_C(1), "ABI major");
_Static_assert(ZIGOS_ABI_MINOR == UINT16_C(26), "ABI minor");
_Static_assert(ZIGOS_PAGE_SIZE == UINT32_C(4096), "ABI page size");
_Static_assert(ZIGOS_SYSCALL_BASE == UINT16_C(64), "ABI syscall base");
_Static_assert(ZIGOS_SYSCALL_COUNT == UINT16_C(66), "ABI syscall count");
_Static_assert(ZIGOS_SYS_FSCHECK == UINT64_C(129), "ABI last syscall");
_Static_assert(sizeof(zigos_auxv_entry) == 16, "startup auxv layout");
_Static_assert(sizeof(zigos_abi_info) == 64, "ABI discovery layout");
_Static_assert(sizeof(zigos_stat) == 32, "stat layout");
_Static_assert(sizeof(zigos_directory_event) == 64, "directory event layout");

static uint64_t auxiliary_value(const zigos_auxv_entry *auxv, uint64_t kind) {
    for (size_t index = 0; index < 16; ++index) {
        if (auxv[index].kind == ZIGOS_AUX_NULL) return 0;
        if (auxv[index].kind == kind) return auxv[index].value;
    }
    return 0;
}

uint32_t zigos_main(size_t argc, const uintptr_t *argv, const uintptr_t *envp, const zigos_auxv_entry *auxv) {
    if (argc == 0 || argv == 0 || envp == 0 || auxv == 0) return 2;
    if (auxiliary_value(auxv, ZIGOS_AUX_PAGESZ) != ZIGOS_PAGE_SIZE) return 1;
    if (auxiliary_value(auxv, ZIGOS_AUX_ZIGOS_ABI) != ((uint64_t)ZIGOS_ABI_MAJOR << 32 | ZIGOS_ABI_MINOR)) return 1;
    const uint64_t capabilities = auxiliary_value(auxv, ZIGOS_AUX_ZIGOS_CAPABILITIES);
    if ((capabilities & ZIGOS_CAP_PROCESS) == 0 ||
        (capabilities & ZIGOS_CAP_VFS) == 0 ||
        (capabilities & ZIGOS_CAP_TERMINAL) == 0)
    {
        return 1;
    }
    return 0;
}
