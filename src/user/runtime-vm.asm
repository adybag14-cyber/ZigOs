BITS 64
ORG 0

%include "src/user/zigos_abi.inc"

%define DATA_BASE      0x0000008000002000
%define START_MESSAGE  (DATA_BASE + 0)
%define PASS_MESSAGE   (DATA_BASE + 64)
%define ABI_INFO       (DATA_BASE + 256)

%define START_LENGTH   15
%define PASS_LENGTH    45

_start:
    mov eax, SYS_WRITE
    mov edi, 1
    mov rsi, START_MESSAGE
    mov edx, START_LENGTH
    int 0x80
    cmp eax, START_LENGTH
    jne .fail_start

    ; The versioned ABI is machine-readable and reports the VM capability.
    mov eax, SYS_ABI_QUERY
    mov rdi, ABI_INFO
    mov esi, 64
    int 0x80
    cmp eax, 64
    jne .fail_abi
    mov rbx, ABI_INFO
    cmp dword [rbx + 0], ZIGOS_ABI_MAGIC
    jne .fail_abi
    cmp word [rbx + 6], ZIGOS_ABI_MAJOR
    jne .fail_abi
    cmp dword [rbx + 12], ZIGOS_PAGE_SIZE
    jne .fail_abi
    test qword [rbx + 24], ZIGOS_CAP_VIRTUAL_MEMORY
    jz .fail_abi

    ; Map two anonymous pages in a region that requires a dynamic page table.
    mov eax, SYS_MMAP
    xor edi, edi
    mov esi, 8192
    mov edx, 3                       ; PROT_READ | PROT_WRITE
    mov r10d, 3                      ; MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    int 0x80
    test rax, rax
    js .fail_mmap
    test rax, ZIGOS_PAGE_SIZE - 1
    jnz .fail_mmap
    mov r12, rax
    mov rax, 0x1122334455667788
    mov qword [r12], rax
    mov rax, 0x8877665544332211
    mov qword [r12 + 4096], rax
    mov rax, 0x1122334455667788
    cmp qword [r12], rax
    jne .fail_memory
    mov rax, 0x8877665544332211
    cmp qword [r12 + 4096], rax
    jne .fail_memory

    ; Downgrade and restore the second page without changing its contents.
    mov eax, SYS_MPROTECT
    lea rdi, [r12 + 4096]
    mov esi, 4096
    mov edx, 1                       ; PROT_READ
    int 0x80
    test rax, rax
    jnz .fail_mprotect
    mov eax, SYS_MPROTECT
    lea rdi, [r12 + 4096]
    mov esi, 4096
    mov edx, 3
    int 0x80
    test rax, rax
    jnz .fail_mprotect
    mov rax, 0x8877665544332211
    cmp qword [r12 + 4096], rax
    jne .fail_memory

    mov eax, SYS_MUNMAP
    mov rdi, r12
    mov esi, 8192
    int 0x80
    test rax, rax
    jnz .fail_munmap

    ; Query, grow, use and fully shrink the process heap break.
    mov eax, SYS_BRK
    xor edi, edi
    int 0x80
    test rax, rax
    js .fail_brk
    mov r13, rax
    lea rdi, [r13 + 8192]
    mov eax, SYS_BRK
    int 0x80
    lea rcx, [r13 + 8192]
    cmp rax, rcx
    jne .fail_brk
    mov rax, 0xCAFEBABEDEADC0DE
    mov qword [r13], rax
    mov rax, 0x0BADF00D12345678
    mov qword [r13 + 4096], rax
    mov eax, SYS_BRK
    mov rdi, r13
    int 0x80
    cmp rax, r13
    jne .fail_brk

    mov eax, SYS_WRITE
    mov edi, 1
    mov rsi, PASS_MESSAGE
    mov edx, PASS_LENGTH
    int 0x80
    cmp eax, PASS_LENGTH
    jne .fail_pass

    mov eax, SYS_EXIT
    mov edi, 0x52
    int 0x80
    ud2

.fail_start:
    mov edi, 0xD0
    jmp .exit_failure
.fail_abi:
    mov edi, 0xD1
    jmp .exit_failure
.fail_mmap:
    mov edi, 0xD2
    jmp .exit_failure
.fail_memory:
    mov edi, 0xD3
    jmp .exit_failure
.fail_mprotect:
    mov edi, 0xD4
    jmp .exit_failure
.fail_munmap:
    mov edi, 0xD5
    jmp .exit_failure
.fail_brk:
    mov edi, 0xD6
    jmp .exit_failure
.fail_pass:
    mov edi, 0xD7
.exit_failure:
    mov eax, SYS_EXIT
    int 0x80
    ud2
