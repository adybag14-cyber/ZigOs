BITS 64
ORG 0

%define DATA_BASE       0x0000008000002000
%define FDS             (DATA_BASE + 0x200)
%define PROC_INFO       (DATA_BASE + 0x280)
%define BSS_BASE        0x0000008000003000
%define EXEC_RECORD     (DATA_BASE + 0x510)
%define IMAGE_MAGIC     (DATA_BASE + 0x7C0)

%define SYS_GETPID      32
%define SYS_GETPPID     33
%define SYS_GETROLE     34
%define SYS_EXIT        39
%define SYS_WRITE       45
%define SYS_PROC_INFO   50

exec_entry:
    mov r12, IMAGE_MAGIC
    mov r11, 0x4558454336343031
    cmp [r12], r11
    jne exec_failure
    mov r12, BSS_BASE
    cmp qword [r12], 0
    jne exec_failure

    mov eax, SYS_GETROLE
    int 0x80
    cmp eax, 6
    jne exec_failure

    mov eax, SYS_GETPID
    int 0x80
    cmp eax, 83
    jne exec_failure

    mov eax, SYS_GETPPID
    int 0x80
    cmp eax, 80
    jne exec_failure

    mov r12, FDS
    mov eax, SYS_WRITE
    mov edi, [r12 + 4]
    mov rsi, EXEC_RECORD
    mov edx, 8
    int 0x80
    cmp eax, 8
    jne exec_failure

    mov eax, SYS_PROC_INFO
    mov rdi, PROC_INFO
    int 0x80
    test rax, rax
    js exec_failure

    mov eax, SYS_EXIT
    mov edi, 0x83
    int 0x80
    ud2

exec_failure:
    mov eax, SYS_EXIT
    mov edi, 0xEF
    int 0x80
    ud2

exec_end:
