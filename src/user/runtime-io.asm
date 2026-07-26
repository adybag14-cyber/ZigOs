BITS 64
ORG 0

%include "src/user/zigos_abi.inc"

%define DATA_BASE        0x0000008000002000
%define START_MESSAGE    (DATA_BASE + 0)
%define PASS_MESSAGE     (DATA_BASE + 64)
%define PROC_VERSION     (DATA_BASE + 160)
%define BIN_DIRECTORY    (DATA_BASE + 192)
%define DEV_ZERO         (DATA_BASE + 224)
%define ABI_INFO         (DATA_BASE + 256)
%define STAT_BUFFER      (DATA_BASE + 320)
%define IO_BUFFER        (DATA_BASE + 384)
%define DIRECTORY_BUFFER (DATA_BASE + 512)
%define POLL_BUFFER      (DATA_BASE + 1536)

%define START_LENGTH     15
%define PASS_LENGTH      46

_start:
    mov eax, SYS_WRITE
    mov edi, 1
    mov rsi, START_MESSAGE
    mov edx, START_LENGTH
    int 0x80
    cmp eax, START_LENGTH
    jne .fail_start

    mov eax, SYS_ABI_QUERY
    mov rdi, ABI_INFO
    mov esi, 64
    int 0x80
    cmp eax, 64
    jne .fail_abi
    mov rbx, ABI_INFO
    test qword [rbx + 24], ZIGOS_CAP_TERMINAL
    jz .fail_abi
    test qword [rbx + 24], ZIGOS_CAP_PSEUDO_FILES
    jz .fail_abi

    ; Open and stat a dynamic procfs file through an ordinary descriptor.
    mov eax, SYS_OPEN
    mov rdi, PROC_VERSION
    mov esi, 1
    xor edx, edx
    int 0x80
    test eax, eax
    js .fail_proc_open
    mov r12d, eax

    mov eax, SYS_FSTAT
    mov edi, r12d
    mov rsi, STAT_BUFFER
    int 0x80
    test eax, eax
    jnz .fail_fstat
    mov rbx, STAT_BUFFER
    cmp byte [rbx + 6], 2                 ; runtime_vfs.Kind.pseudo
    jne .fail_fstat
    cmp byte [rbx + 7], 1
    jne .fail_fstat

    mov eax, SYS_READ
    mov edi, r12d
    mov rsi, IO_BUFFER
    mov edx, 32
    int 0x80
    cmp eax, 5
    jl .fail_proc_read
    mov rbx, IO_BUFFER
    cmp dword [rbx], 0x4F67695A           ; "ZigO"
    jne .fail_proc_read
    cmp byte [rbx + 4], 's'
    jne .fail_proc_read

    mov eax, SYS_CLOSE
    mov edi, r12d
    int 0x80
    test eax, eax
    jnz .fail_close

    ; Directories are readable descriptor objects with a retained cursor.
    mov eax, SYS_OPEN
    mov rdi, BIN_DIRECTORY
    mov esi, 1
    xor edx, edx
    int 0x80
    test eax, eax
    js .fail_dir_open
    mov r13d, eax

    mov eax, SYS_FSTAT
    mov edi, r13d
    mov rsi, STAT_BUFFER
    int 0x80
    test eax, eax
    jnz .fail_fstat
    mov rbx, STAT_BUFFER
    cmp byte [rbx + 6], 1                 ; runtime_vfs.Kind.directory
    jne .fail_fstat

    mov eax, SYS_GETDENTS
    mov edi, r13d
    mov rsi, DIRECTORY_BUFFER
    mov edx, 960
    int 0x80
    test eax, eax
    jle .fail_getdents
    xor edx, edx
    mov ecx, 48
    div ecx
    test edx, edx
    jnz .fail_getdents
    mov rbx, DIRECTORY_BUFFER
    cmp word [rbx + 6], 9
    jne .fail_getdents
    cmp dword [rbx + 16], 0x6C6C6568      ; "hell"
    jne .fail_getdents
    cmp dword [rbx + 20], 0x6C652E6F      ; "o.el"
    jne .fail_getdents
    cmp byte [rbx + 24], 'f'
    jne .fail_getdents

    mov eax, SYS_CLOSE
    mov edi, r13d
    int 0x80
    test eax, eax
    jnz .fail_close

    ; /dev/zero is supplied by the same pseudo backend and honours length.
    mov eax, SYS_OPEN
    mov rdi, DEV_ZERO
    mov esi, 1
    xor edx, edx
    int 0x80
    test eax, eax
    js .fail_zero
    mov r14d, eax
    mov rbx, IO_BUFFER
    mov qword [rbx], -1
    mov qword [rbx + 8], -1
    mov eax, SYS_READ
    mov edi, r14d
    mov rsi, IO_BUFFER
    mov edx, 16
    int 0x80
    cmp eax, 16
    jne .fail_zero
    mov rbx, IO_BUFFER
    cmp qword [rbx], 0
    jne .fail_zero
    cmp qword [rbx + 8], 0
    jne .fail_zero
    mov eax, SYS_CLOSE
    mov edi, r14d
    int 0x80
    test eax, eax
    jnz .fail_close

    ; Descriptor readiness is observable without a kernel-shell facade.
    mov rbx, POLL_BUFFER
    mov word [rbx + 0], 1
    mov word [rbx + 2], 2          ; POLL_WRITABLE
    mov word [rbx + 4], 0
    mov word [rbx + 6], 0
    mov eax, SYS_POLL
    mov rdi, POLL_BUFFER
    mov esi, 1
    xor edx, edx
    int 0x80
    cmp eax, 1
    jne .fail_poll
    mov rbx, POLL_BUFFER
    test word [rbx + 4], 2
    jz .fail_poll

    mov eax, SYS_WRITE
    mov edi, 1
    mov rsi, PASS_MESSAGE
    mov edx, PASS_LENGTH
    int 0x80
    cmp eax, PASS_LENGTH
    jne .fail_pass

    mov eax, SYS_EXIT
    mov edi, 0x53
    int 0x80
    ud2

.fail_start:
    mov edi, 0xC0
    jmp .exit_failure
.fail_abi:
    mov edi, 0xC1
    jmp .exit_failure
.fail_proc_open:
    mov edi, 0xC2
    jmp .exit_failure
.fail_fstat:
    mov edi, 0xC3
    jmp .exit_failure
.fail_proc_read:
    mov edi, 0xC4
    jmp .exit_failure
.fail_close:
    mov edi, 0xC5
    jmp .exit_failure
.fail_dir_open:
    mov edi, 0xC6
    jmp .exit_failure
.fail_getdents:
    mov edi, 0xC7
    jmp .exit_failure
.fail_zero:
    mov edi, 0xC8
    jmp .exit_failure
.fail_poll:
    mov edi, 0xC9
    jmp .exit_failure
.fail_pass:
    mov edi, 0xCA
.exit_failure:
    mov eax, SYS_EXIT
    int 0x80
    ud2
