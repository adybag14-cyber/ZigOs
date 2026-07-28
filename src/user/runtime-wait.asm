BITS 64
ORG 0x0000008000000000

%define DATA_BASE       0x0000008000002000
%define START_MESSAGE   (DATA_BASE + 0)
%define PASS_MESSAGE    (DATA_BASE + 32)
%define SLEEP_PATH      (DATA_BASE + 128)
%define SHORT_PATH      (DATA_BASE + 160)
%define WAIT_STATUS     (DATA_BASE + 256)

%define START_LENGTH    17
%define PASS_LENGTH     47
%define SLEEP_PATH_LEN  14
%define SHORT_PATH_LEN  19

%define SYS_EXIT        64
%define SYS_WRITE       65
%define SYS_SPAWN       76
%define SYS_WAIT        77
%define WNOHANG         1

_start:
    mov rbx, WAIT_STATUS
    mov eax, SYS_WRITE
    mov edi, 1
    mov rsi, START_MESSAGE
    mov edx, START_LENGTH
    int 0x80
    test rax, rax
    js .fail_write_start

    ; Long child A sleeps for three ticks.
    mov eax, SYS_SPAWN
    mov rdi, SLEEP_PATH
    mov esi, SLEEP_PATH_LEN
    int 0x80
    test rax, rax
    js .fail_spawn_long
    mov r12d, eax

    ; Short child B sleeps for one tick. Both children are live when wait-any blocks.
    mov eax, SYS_SPAWN
    mov rdi, SHORT_PATH
    mov esi, SHORT_PATH_LEN
    int 0x80
    test rax, rax
    js .fail_spawn_short
    mov r13d, eax

    ; PID zero must remain an any-child wait and wake when short child B exits first.
    mov eax, SYS_WAIT
    xor edi, edi
    xor esi, esi
    mov rdx, rbx
    int 0x80
    cmp eax, r13d
    jne .fail_waitany_return
    cmp dword [rbx], r13d
    jne .fail_waitany_status
    cmp dword [rbx + 4], 0x2A
    jne .fail_waitany_status

    ; Long child A must still be live: exact WNOHANG returns zero without reaping it.
    mov eax, SYS_WAIT
    mov edi, r12d
    mov esi, WNOHANG
    mov rdx, rbx
    int 0x80
    test rax, rax
    jnz .fail_long_not_running

    ; Exact waitpid then blocks until long child A exits with status 7.
    mov eax, SYS_WAIT
    mov edi, r12d
    xor esi, esi
    mov rdx, rbx
    int 0x80
    cmp eax, r12d
    jne .fail_waitpid_return
    cmp dword [rbx], r12d
    jne .fail_waitpid_status
    cmp dword [rbx + 4], 7
    jne .fail_waitpid_status

    mov eax, SYS_WRITE
    mov edi, 1
    mov rsi, PASS_MESSAGE
    mov edx, PASS_LENGTH
    int 0x80
    test rax, rax
    js .fail_write_pass

    mov eax, SYS_EXIT
    mov edi, 0x31
    int 0x80

.fail_write_start:
    mov edi, 0xE0
    jmp .exit_failure
.fail_spawn_long:
    mov edi, 0xE1
    jmp .exit_failure
.fail_spawn_short:
    mov edi, 0xE2
    jmp .exit_failure
.fail_waitany_return:
    mov edi, 0xE3
    jmp .exit_failure
.fail_waitany_status:
    mov edi, 0xE4
    jmp .exit_failure
.fail_long_not_running:
    mov edi, 0xE5
    jmp .exit_failure
.fail_waitpid_return:
    mov edi, 0xE6
    jmp .exit_failure
.fail_waitpid_status:
    mov edi, 0xE7
    jmp .exit_failure
.fail_write_pass:
    mov edi, 0xE8
.exit_failure:
    mov eax, SYS_EXIT
    int 0x80
    ud2
