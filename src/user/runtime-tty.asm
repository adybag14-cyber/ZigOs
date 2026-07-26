BITS 64
ORG 0

%include "src/user/zigos_abi.inc"

%define DATA_BASE      0x0000008000002000
%define START_MESSAGE  (DATA_BASE + 0)
%define PASS_MESSAGE   (DATA_BASE + 64)
%define READ_BUFFER    (DATA_BASE + 192)
%define POLL_BUFFER    (DATA_BASE + 256)

%define START_LENGTH   16
%define PASS_LENGTH    52

_start:
    mov eax, SYS_WRITE
    mov edi, 1
    mov rsi, START_MESSAGE
    mov edx, START_LENGTH
    int 0x80
    cmp eax, START_LENGTH
    jne .fail_start

    ; Before a canonical line arrives, stdin must not report readable.
    mov rbx, POLL_BUFFER
    mov word [rbx + 0], 0
    mov word [rbx + 2], 1          ; POLL_READABLE
    mov word [rbx + 4], 0
    mov word [rbx + 6], 0
    mov eax, SYS_POLL
    mov rdi, POLL_BUFFER
    mov esi, 1
    xor edx, edx
    int 0x80
    test eax, eax
    jnz .fail_initial_poll

    ; This syscall must block and be retried by the kernel after COM1 commits
    ; one canonical line for this foreground process group.
    mov eax, SYS_READ
    xor edi, edi
    mov rsi, READ_BUFFER
    mov edx, 32
    int 0x80
    cmp eax, 7
    jne .fail_read
    mov rbx, READ_BUFFER
    cmp dword [rbx], 0x7467697A   ; "zigt"
    jne .fail_data
    cmp word [rbx + 4], 0x7974    ; "ty"
    jne .fail_data
    cmp byte [rbx + 6], 10
    jne .fail_data

    ; The line was consumed completely, so readiness returns to zero.
    mov rbx, POLL_BUFFER
    mov word [rbx + 4], 0
    mov eax, SYS_POLL
    mov rdi, POLL_BUFFER
    mov esi, 1
    xor edx, edx
    int 0x80
    test eax, eax
    jnz .fail_final_poll

    mov eax, SYS_WRITE
    mov edi, 1
    mov rsi, PASS_MESSAGE
    mov edx, PASS_LENGTH
    int 0x80
    cmp eax, PASS_LENGTH
    jne .fail_pass

    mov eax, SYS_EXIT
    mov edi, 0x55
    int 0x80
    ud2

.fail_start:
    mov edi, 0xD0
    jmp .exit_failure
.fail_initial_poll:
    mov edi, 0xD1
    jmp .exit_failure
.fail_read:
    mov edi, 0xD2
    jmp .exit_failure
.fail_data:
    mov edi, 0xD3
    jmp .exit_failure
.fail_final_poll:
    mov edi, 0xD4
    jmp .exit_failure
.fail_pass:
    mov edi, 0xD5
.exit_failure:
    mov eax, SYS_EXIT
    int 0x80
    ud2
