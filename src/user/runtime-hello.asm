BITS 64
ORG 0

%define DATA_BASE  0x0000008000002000
%define SYS_EXIT   64
%define SYS_WRITE  65
%define SYS_GETPID 67

entry:
    mov eax, SYS_GETPID
    int 0x80
    test eax, eax
    jz failure
    mov r12, DATA_BASE + 0x100
    mov [r12], eax

    mov eax, SYS_WRITE
    mov edi, 1
    mov rsi, DATA_BASE
    mov edx, 34
    int 0x80
    cmp eax, 34
    jne failure

    mov eax, SYS_EXIT
    mov edi, 42
    int 0x80
    ud2

failure:
    mov eax, SYS_EXIT
    mov edi, 0xEE
    int 0x80
    ud2
