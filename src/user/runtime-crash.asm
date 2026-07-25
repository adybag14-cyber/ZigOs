BITS 64
ORG 0

%define DATA_BASE 0x0000008000002000
%define SYS_EXIT  64
%define SYS_WRITE 65
%define FAULT_ADDRESS 0x0000008000180000

entry:
    mov eax, SYS_WRITE
    mov edi, 1
    mov rsi, DATA_BASE
    mov edx, 32
    int 0x80
    cmp eax, 32
    jne failure

    mov r12, FAULT_ADDRESS
    mov rax, [r12]

    mov eax, SYS_EXIT
    mov edi, 0xED
    int 0x80
    ud2

failure:
    mov eax, SYS_EXIT
    mov edi, 0xEE
    int 0x80
    ud2
