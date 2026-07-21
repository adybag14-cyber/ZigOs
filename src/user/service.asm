; ZigOs Capstone 15 deterministic x86-64 ELF64 userspace service workload.
; This flat payload is wrapped into a two-PT_LOAD ELF64 image by the host generator.

bits 64
org 0x0000008000100000

%define CODE_BASE       0x0000008000100000
%define DATA_BASE       0x0000008000102000
%define BSS_BASE        0x0000008000103000
%define STACK_BASE      0x0000008000104000
%define HEAP_BASE       0x0000008000105000
%define ANON_BASE       0x0000008000107000
%define GUARD_BASE      0x0000008000108000

%define RESULTS         (DATA_BASE + 0x000)
%define PROC_INFO       (DATA_BASE + 0x200)
%define MEM_INFO        (DATA_BASE + 0x280)
%define FDS             (DATA_BASE + 0x300)
%define DESC_INFO       (DATA_BASE + 0x320)
%define READBACK        (DATA_BASE + 0x380)
%define MESSAGE         (DATA_BASE + 0x400)
%define MESSAGE_LEN     34
%define PIPE_PAYLOAD    (DATA_BASE + 0x440)
%define PIPE_LEN        24

%define SYS_GETPID          0
%define SYS_GETPPID         1
%define SYS_PROCESS_INFO    2
%define SYS_CLOCK           3
%define SYS_WRITE_OUTPUT    4
%define SYS_HASH            5
%define SYS_BRK             6
%define SYS_MEMORY_INFO     7
%define SYS_MMAP            8
%define SYS_MUNMAP          9
%define SYS_PIPE            10
%define SYS_READ            11
%define SYS_WRITE           12
%define SYS_CLOSE           13
%define SYS_DUP             14
%define SYS_DUP2            15
%define SYS_DESCRIPTOR_INFO 16
%define SYS_SIGNAL_SEND     17
%define SYS_SIGNAL_TAKE     18
%define SYS_YIELD           19
%define SYS_SLEEP           20
%define SYS_SET_FAULT       21
%define SYS_EXIT            22

%define PID_VALUE       64
%define PPID_VALUE      1
%define ERR_FAULT       -14
%define ERR_BAD_FD      -9
%define ERR_BUSY        -16
%define ERR_INVALID     -22
%define ERR_NO_PROCESS  -3
%define ERR_NO_SYSCALL  -38

%macro STORE_RESULT 1
    mov r10, RESULTS + (%1 * 8)
    mov [r10], rax
%endmacro

%macro EXPECT_IMM 1
    mov rbx, %1
    cmp rax, rbx
    jne user_failure
%endmacro

%macro SET_STEP 1
    mov r15, %1
%endmacro

service_entry:
    mov r12, 0x1122334455667788
    mov r13, 0x8877665544332211
    mov r14, 0xA55AA55A5AA55AA5
    movq xmm6, r14

    SET_STEP 0
    mov eax, SYS_GETPID
    int 0x80
    STORE_RESULT 0
    EXPECT_IMM PID_VALUE
    mov rbx, 0x1122334455667788
    cmp r12, rbx
    jne user_failure
    mov rbx, 0x8877665544332211
    cmp r13, rbx
    jne user_failure
    movq rbx, xmm6
    cmp rbx, r14
    jne user_failure

    SET_STEP 1
    mov eax, SYS_GETPPID
    int 0x80
    STORE_RESULT 1
    EXPECT_IMM PPID_VALUE

    SET_STEP 2
    mov rdi, PROC_INFO
    mov eax, SYS_PROCESS_INFO
    int 0x80
    STORE_RESULT 2
    EXPECT_IMM 0

    SET_STEP 3
    mov rdi, 0xFFFF800000000000
    mov eax, SYS_PROCESS_INFO
    int 0x80
    STORE_RESULT 3
    EXPECT_IMM ERR_FAULT

    SET_STEP 4
    mov eax, SYS_CLOCK
    int 0x80
    STORE_RESULT 4
    EXPECT_IMM 0x1000

    SET_STEP 5
    mov rdi, MESSAGE
    mov rsi, MESSAGE_LEN
    mov eax, SYS_WRITE_OUTPUT
    int 0x80
    STORE_RESULT 5
    EXPECT_IMM MESSAGE_LEN

    SET_STEP 6
    mov rdi, GUARD_BASE - 4
    mov rsi, 8
    mov eax, SYS_WRITE_OUTPUT
    int 0x80
    STORE_RESULT 6
    EXPECT_IMM ERR_FAULT

    SET_STEP 7
    mov rdi, -4
    mov rsi, 16
    mov eax, SYS_WRITE_OUTPUT
    int 0x80
    STORE_RESULT 7
    EXPECT_IMM ERR_FAULT

    SET_STEP 8
    mov rdi, -1
    xor esi, esi
    mov eax, SYS_WRITE_OUTPUT
    int 0x80
    STORE_RESULT 8
    EXPECT_IMM 0

    SET_STEP 9
    mov rdi, CODE_BASE
    mov rsi, 64
    mov eax, SYS_HASH
    int 0x80
    STORE_RESULT 9
    test rax, rax
    jz user_failure

    SET_STEP 10
    xor edi, edi
    mov eax, SYS_BRK
    int 0x80
    STORE_RESULT 10
    EXPECT_IMM HEAP_BASE

    SET_STEP 11
    mov rdi, HEAP_BASE + 0x2000
    mov eax, SYS_BRK
    int 0x80
    STORE_RESULT 11
    EXPECT_IMM HEAP_BASE + 0x2000
    mov r10, HEAP_BASE
    mov rax, 0x1111222233334444
    mov [r10], rax
    mov r10, HEAP_BASE + 0x1000
    mov rax, 0x5555666677778888
    mov [r10], rax

    SET_STEP 12
    mov rdi, CODE_BASE
    mov eax, SYS_MEMORY_INFO
    int 0x80
    STORE_RESULT 12
    EXPECT_IMM ERR_FAULT

    SET_STEP 13
    mov rdi, MEM_INFO
    mov eax, SYS_MEMORY_INFO
    int 0x80
    STORE_RESULT 13
    EXPECT_IMM 0

    SET_STEP 14
    mov eax, SYS_MMAP
    int 0x80
    STORE_RESULT 14
    EXPECT_IMM ANON_BASE
    mov r10, ANON_BASE
    mov rax, 0xCAFEBABEDEADBEEF
    mov [r10], rax

    SET_STEP 15
    mov eax, SYS_MMAP
    int 0x80
    STORE_RESULT 15
    EXPECT_IMM ERR_BUSY

    SET_STEP 16
    mov rdi, MEM_INFO
    mov eax, SYS_MEMORY_INFO
    int 0x80
    STORE_RESULT 16
    EXPECT_IMM 0

    SET_STEP 17
    mov rdi, FDS
    mov eax, SYS_PIPE
    int 0x80
    STORE_RESULT 17
    EXPECT_IMM 0

    SET_STEP 18
    xor edi, edi
    mov rsi, DESC_INFO
    mov eax, SYS_DESCRIPTOR_INFO
    int 0x80
    STORE_RESULT 18
    EXPECT_IMM 0

    SET_STEP 19
    mov edi, 1
    mov rsi, PIPE_PAYLOAD
    mov rdx, PIPE_LEN
    mov eax, SYS_WRITE
    int 0x80
    STORE_RESULT 19
    EXPECT_IMM PIPE_LEN

    SET_STEP 20
    xor edi, edi
    mov eax, SYS_DUP
    int 0x80
    STORE_RESULT 20
    EXPECT_IMM 2

    SET_STEP 21
    mov edi, 1
    mov esi, 7
    mov eax, SYS_DUP2
    int 0x80
    STORE_RESULT 21
    EXPECT_IMM 7

    SET_STEP 22
    mov edi, 1
    mov eax, SYS_CLOSE
    int 0x80
    STORE_RESULT 22
    EXPECT_IMM 0

    SET_STEP 23
    mov edi, 2
    mov rsi, READBACK
    mov rdx, PIPE_LEN
    mov eax, SYS_READ
    int 0x80
    STORE_RESULT 23
    EXPECT_IMM PIPE_LEN

    SET_STEP 24
    mov edi, 7
    mov eax, SYS_CLOSE
    int 0x80
    STORE_RESULT 24
    EXPECT_IMM 0

    SET_STEP 25
    mov edi, 2
    mov rsi, READBACK + PIPE_LEN
    mov rdx, 8
    mov eax, SYS_READ
    int 0x80
    STORE_RESULT 25
    EXPECT_IMM 0

    SET_STEP 26
    xor edi, edi
    mov eax, SYS_CLOSE
    int 0x80
    STORE_RESULT 26
    EXPECT_IMM 0

    SET_STEP 27
    mov edi, 2
    mov eax, SYS_CLOSE
    int 0x80
    STORE_RESULT 27
    EXPECT_IMM 0

    SET_STEP 28
    mov edi, 7
    mov eax, SYS_CLOSE
    int 0x80
    STORE_RESULT 28
    EXPECT_IMM ERR_BAD_FD

    SET_STEP 29
    mov edi, 999
    mov esi, 9
    mov eax, SYS_SIGNAL_SEND
    int 0x80
    STORE_RESULT 29
    EXPECT_IMM ERR_NO_PROCESS

    SET_STEP 30
    mov edi, PID_VALUE
    mov esi, 9
    mov eax, SYS_SIGNAL_SEND
    int 0x80
    STORE_RESULT 30
    EXPECT_IMM 0

    SET_STEP 31
    mov eax, SYS_SIGNAL_TAKE
    int 0x80
    STORE_RESULT 31
    EXPECT_IMM 9

    SET_STEP 32
    mov eax, SYS_SIGNAL_TAKE
    int 0x80
    STORE_RESULT 32
    EXPECT_IMM 0

    SET_STEP 33
    mov eax, SYS_YIELD
    int 0x80
    STORE_RESULT 33
    EXPECT_IMM 0

    SET_STEP 34
    xor edi, edi
    mov eax, SYS_SLEEP
    int 0x80
    STORE_RESULT 34
    EXPECT_IMM ERR_INVALID

    SET_STEP 35
    mov edi, 3
    mov eax, SYS_SLEEP
    int 0x80
    STORE_RESULT 35
    EXPECT_IMM 3

    SET_STEP 36
    mov eax, SYS_CLOCK
    int 0x80
    STORE_RESULT 36
    EXPECT_IMM 0x1004

    SET_STEP 37
    mov rdi, READBACK
    mov rsi, PIPE_LEN
    mov eax, SYS_HASH
    int 0x80
    STORE_RESULT 37
    test rax, rax
    jz user_failure

    SET_STEP 38
    mov rdi, ANON_BASE
    mov eax, SYS_MUNMAP
    int 0x80
    STORE_RESULT 38
    EXPECT_IMM 0

    SET_STEP 39
    mov rdi, ANON_BASE
    mov eax, SYS_MUNMAP
    int 0x80
    STORE_RESULT 39
    EXPECT_IMM ERR_INVALID

    SET_STEP 40
    mov rdi, HEAP_BASE
    mov eax, SYS_BRK
    int 0x80
    STORE_RESULT 40
    EXPECT_IMM HEAP_BASE

    SET_STEP 41
    mov rdi, STACK_BASE
    mov eax, SYS_BRK
    int 0x80
    STORE_RESULT 41
    EXPECT_IMM ERR_INVALID

    SET_STEP 42
    xor edi, edi
    mov rsi, DESC_INFO
    mov eax, SYS_DESCRIPTOR_INFO
    int 0x80
    STORE_RESULT 42
    EXPECT_IMM ERR_BAD_FD

    SET_STEP 43
    mov rdi, fault_handler_one
    mov eax, SYS_SET_FAULT
    int 0x80
    STORE_RESULT 43
    EXPECT_IMM 0

    SET_STEP 44
    mov rdi, DATA_BASE
    mov eax, SYS_SET_FAULT
    int 0x80
    STORE_RESULT 44
    EXPECT_IMM ERR_FAULT

    SET_STEP 45
    mov eax, 0xFFFF
    int 0x80
    STORE_RESULT 45
    EXPECT_IMM ERR_NO_SYSCALL

    SET_STEP 46
    mov rdi, PROC_INFO
    mov eax, SYS_PROCESS_INFO
    int 0x80
    STORE_RESULT 46
    EXPECT_IMM 0

    ; A real instruction-fetch page fault is expected because DATA_BASE is NX.
    mov r10, DATA_BASE
    call r10
    ud2

fault_handler_one:
    add rsp, 8
    SET_STEP 47
    mov rdi, fault_handler_two
    mov eax, SYS_SET_FAULT
    int 0x80
    STORE_RESULT 47
    EXPECT_IMM 0

    ; A second real page fault is expected because GUARD_BASE is unmapped.
    mov r10, GUARD_BASE
    mov rax, [r10]
    ud2

fault_handler_two:
    SET_STEP 48
    mov rdi, PROC_INFO
    mov eax, SYS_PROCESS_INFO
    int 0x80
    STORE_RESULT 48
    EXPECT_IMM 0

    mov r10, BSS_BASE
    mov rax, 0xB16B00B5C0DEC0DE
    mov [r10], rax

    SET_STEP 49
    mov edi, 0x64
    mov eax, SYS_EXIT
    int 0x80
    ud2

user_failure:
    mov rdi, r15
    or rdi, 0xE000
    mov eax, SYS_EXIT
    int 0x80
    ud2

service_end:
