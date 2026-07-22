BITS 64
ORG 0

%define CODE_BASE       0x0000008000000000
%define DATA_BASE       0x0000008000002000
%define BSS_BASE        0x0000008000003000
%define STACK_BASE      0x0000008000004000
%define HEAP_BASE       0x0000008000005000
%define DEMAND_BASE     0x0000008000006000
%define ANON_BASE       0x0000008000007000
%define GUARD_BASE      0x0000008000008000

%define FDS             (DATA_BASE + 0x200)
%define HANDLES         (DATA_BASE + 0x220)
%define STATUS_WORD     (DATA_BASE + 0x260)
%define PROC_INFO       (DATA_BASE + 0x280)
%define VM_INFO         (DATA_BASE + 0x300)
%define READBACK        (DATA_BASE + 0x380)
%define WORKER1_RECORD  (DATA_BASE + 0x500)
%define WORKER2_RECORD  (DATA_BASE + 0x508)
%define EXEC_RECORD     (DATA_BASE + 0x510)
%define REUSE_RECORD    (DATA_BASE + 0x518)

%define SYS_GETPID      32
%define SYS_GETPPID     33
%define SYS_GETROLE     34
%define SYS_GETTICKS    35
%define SYS_SPAWN       36
%define SYS_FORK        37
%define SYS_EXEC        38
%define SYS_EXIT        39
%define SYS_YIELD       40
%define SYS_SLEEP       41
%define SYS_WAIT        42
%define SYS_PIPE        43
%define SYS_READ        44
%define SYS_WRITE       45
%define SYS_CLOSE       46
%define SYS_DUP         47
%define SYS_SIGNAL      48
%define SYS_TAKE_SIGNAL 49
%define SYS_PROC_INFO   50
%define SYS_VM_INFO     51
%define SYS_MMAP        52
%define SYS_MUNMAP      53
%define SYS_BRK         54
%define SYS_GETHANDLE   55

%define ERR_NO_PROCESS  -3
%define ERR_NO_EXEC     -8
%define ERR_CHILD       -10

process_entry:
    mov eax, SYS_GETROLE
    int 0x80
    cmp eax, 1
    je initial_process
    cmp eax, 2
    je worker_one
    cmp eax, 3
    je worker_two
    cmp eax, 4
    je fault_worker
    cmp eax, 5
    je reuse_worker
    jmp user_failure

initial_process:
    mov eax, SYS_GETPID
    int 0x80
    cmp eax, 80
    jne user_failure

    mov eax, SYS_PIPE
    mov rdi, FDS
    int 0x80
    test rax, rax
    js user_failure

    mov eax, SYS_SPAWN
    mov edi, 2
    mov esi, 1
    int 0x80
    test rax, rax
    js user_failure
    mov r12, HANDLES
    mov [r12 + 0], rax

    mov eax, SYS_SPAWN
    mov edi, 3
    mov esi, 1
    int 0x80
    test rax, rax
    js user_failure
    mov [r12 + 8], rax

    mov r15, 0xF0F1F2F3F4F5F6F7
    mov rax, 0x5152535455565758
    push rax
    mov eax, SYS_FORK
    int 0x80
    mov r10, rax
    mov r11, 0xF0F1F2F3F4F5F6F7
    cmp r15, r11
    jne user_failure
    mov r11, 0x5152535455565758
    cmp [rsp], r11
    jne user_failure
    pop r11
    test r10, r10
    jz fork_child
    mov [r12 + 16], r10

    mov eax, SYS_EXEC
    mov edi, 99
    int 0x80
    cmp rax, ERR_NO_EXEC
    jne user_failure

    mov eax, SYS_WAIT
    mov rdi, [r12 + 16]
    mov rsi, STATUS_WORD
    int 0x80
    cmp rax, [r12 + 16]
    jne user_failure
    mov r13, STATUS_WORD
    cmp qword [r13], 0x83
    jne user_failure

    mov eax, SYS_SIGNAL
    mov rdi, [r12 + 16]
    mov esi, 7
    int 0x80
    cmp rax, ERR_NO_PROCESS
    jne user_failure

    mov eax, SYS_WAIT
    mov rdi, [r12 + 0]
    mov rsi, STATUS_WORD
    int 0x80
    cmp rax, [r12 + 0]
    jne user_failure
    cmp qword [r13], 0x81
    jne user_failure

    mov eax, SYS_WAIT
    mov rdi, [r12 + 8]
    mov rsi, STATUS_WORD
    int 0x80
    cmp rax, [r12 + 8]
    jne user_failure
    cmp qword [r13], 0x82
    jne user_failure

    mov eax, SYS_SPAWN
    mov edi, 4
    mov esi, 1
    int 0x80
    test rax, rax
    js user_failure
    mov [r12 + 24], rax

    mov eax, SYS_WAIT
    mov rdi, [r12 + 24]
    mov rsi, STATUS_WORD
    int 0x80
    cmp rax, [r12 + 24]
    jne user_failure
    cmp qword [r13], 0xE00E
    jne user_failure

    mov eax, SYS_WAIT
    mov rdi, [r12 + 16]
    mov rsi, STATUS_WORD
    int 0x80
    cmp rax, ERR_CHILD
    jne user_failure

    mov eax, SYS_SPAWN
    mov edi, 5
    mov esi, 1
    int 0x80
    test rax, rax
    js user_failure
    cmp rax, [r12 + 24]
    je user_failure
    mov [r12 + 32], rax

    mov eax, SYS_WAIT
    mov rdi, [r12 + 32]
    mov rsi, STATUS_WORD
    int 0x80
    cmp rax, [r12 + 32]
    jne user_failure
    cmp qword [r13], 0x95
    jne user_failure

    mov r14, FDS
    mov eax, SYS_CLOSE
    mov edi, [r14 + 4]
    int 0x80
    test rax, rax
    js user_failure

    mov eax, SYS_READ
    mov edi, [r14 + 0]
    mov rsi, READBACK
    mov edx, 32
    int 0x80
    cmp eax, 32
    jne user_failure

    mov eax, SYS_TAKE_SIGNAL
    int 0x80
    cmp eax, 5
    jne user_failure
    mov eax, SYS_TAKE_SIGNAL
    int 0x80
    cmp eax, 6
    jne user_failure

    mov eax, SYS_PROC_INFO
    mov rdi, PROC_INFO
    int 0x80
    test rax, rax
    js user_failure
    mov eax, SYS_VM_INFO
    mov rdi, VM_INFO
    int 0x80
    test rax, rax
    js user_failure

    mov eax, SYS_CLOSE
    mov edi, [r14 + 0]
    int 0x80
    test rax, rax
    js user_failure

    mov eax, SYS_EXIT
    mov edi, 0x80
    int 0x80
    ud2

fork_child:
    mov r12, DATA_BASE
    mov rax, 0xC0C0C0C0C0C0C0C0
    mov [r12 + 0x180], rax
    mov r12, BSS_BASE
    mov rax, 0xB55B55B55B55B55B
    mov [r12], rax
    mov r12, DEMAND_BASE
    cmp qword [r12], 0
    jne user_failure
    mov rax, 0xD00DD00DD00DD00D
    mov [r12], rax

    mov eax, SYS_SIGNAL
    xor edi, edi
    mov esi, 5
    int 0x80
    test rax, rax
    js user_failure

    mov eax, SYS_EXEC
    mov edi, 99
    int 0x80
    cmp rax, ERR_NO_EXEC
    jne user_failure

    mov eax, SYS_EXEC
    mov edi, 1
    int 0x80
    ud2

worker_one:
    mov r15, 0x1111222233334444
    mov rax, 0xA1A2A3A4A5A6A7A8
    movq xmm0, rax
    mov ecx, 3000000
.worker_one_burn:
    pause
    dec ecx
    jnz .worker_one_burn

    mov eax, SYS_SLEEP
    mov edi, 2
    int 0x80
    test rax, rax
    js user_failure
    mov r11, 0x1111222233334444
    cmp r15, r11
    jne user_failure
    movq rax, xmm0
    mov r11, 0xA1A2A3A4A5A6A7A8
    cmp rax, r11
    jne user_failure

    mov eax, SYS_MMAP
    int 0x80
    mov r11, ANON_BASE
    cmp rax, r11
    jne user_failure
    mov r12, rax
    cmp qword [r12], 0
    jne user_failure
    mov rax, 0xA110CA7EA110CA7E
    mov [r12], rax

    mov eax, SYS_MUNMAP
    mov rdi, ANON_BASE
    int 0x80
    test rax, rax
    js user_failure

    mov r12, FDS
    mov eax, SYS_DUP
    mov edi, [r12 + 4]
    int 0x80
    test rax, rax
    js user_failure
    mov r13d, eax

    mov eax, SYS_WRITE
    mov edi, r13d
    mov rsi, WORKER1_RECORD
    mov edx, 8
    int 0x80
    cmp eax, 8
    jne user_failure

    mov eax, SYS_CLOSE
    mov edi, r13d
    int 0x80
    test rax, rax
    js user_failure

    mov eax, SYS_SIGNAL
    xor edi, edi
    mov esi, 6
    int 0x80
    test rax, rax
    js user_failure

    mov eax, SYS_EXIT
    mov edi, 0x81
    int 0x80
    ud2

worker_two:
    mov r15, 0x5555666677778888
    mov rax, 0xB1B2B3B4B5B6B7B8
    movq xmm0, rax
    mov ecx, 3000000
.worker_two_burn:
    pause
    dec ecx
    jnz .worker_two_burn
    mov r11, 0x5555666677778888
    cmp r15, r11
    jne user_failure
    movq rax, xmm0
    mov r11, 0xB1B2B3B4B5B6B7B8
    cmp rax, r11
    jne user_failure

    mov eax, SYS_BRK
    mov rdi, HEAP_BASE + 0x1000
    int 0x80
    mov r11, HEAP_BASE + 0x1000
    cmp rax, r11
    jne user_failure
    mov r12, HEAP_BASE
    cmp qword [r12], 0
    jne user_failure
    mov rax, 0xB22CB22CB22CB22C
    mov [r12], rax

    mov r12, DEMAND_BASE
    cmp qword [r12], 0
    jne user_failure
    mov rax, 0xD22DD22DD22DD22D
    mov [r12], rax

    mov r12, FDS
    mov eax, SYS_WRITE
    mov edi, [r12 + 4]
    mov rsi, WORKER2_RECORD
    mov edx, 8
    int 0x80
    cmp eax, 8
    jne user_failure

    mov eax, SYS_BRK
    mov rdi, HEAP_BASE
    int 0x80
    mov r11, HEAP_BASE
    cmp rax, r11
    jne user_failure

    mov eax, SYS_YIELD
    int 0x80

    mov eax, SYS_EXIT
    mov edi, 0x82
    int 0x80
    ud2

fault_worker:
    mov r12, GUARD_BASE
    mov rax, [r12]
    ud2

reuse_worker:
    mov r12, FDS
    mov eax, SYS_WRITE
    mov edi, [r12 + 4]
    mov rsi, REUSE_RECORD
    mov edx, 8
    int 0x80
    cmp eax, 8
    jne user_failure
    mov eax, SYS_YIELD
    int 0x80
    mov eax, SYS_EXIT
    mov edi, 0x95
    int 0x80
    ud2

user_failure:
    mov eax, SYS_EXIT
    mov edi, 0xEE
    int 0x80
    ud2

process_end:
