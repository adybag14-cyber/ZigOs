BITS 64
ORG 0

%define DATA_BASE 0x0000008000002000
%define BUFFER     (DATA_BASE + 0x100)
%define SYS_EXIT  64
%define SYS_WRITE 65
%define SYS_READ  66

entry:
    mov r12d, edi

    mov eax, SYS_READ
    mov edi, r12d
    mov rsi, BUFFER
    mov edx, 8
    int 0x80
    cmp eax, 8
    jne failure

    mov eax, SYS_WRITE
    mov edi, 1
    mov rsi, BUFFER
    mov edx, 8
    int 0x80
    cmp eax, 8
    jne failure

    mov eax, SYS_EXIT
    xor edi, edi
    int 0x80
    ud2

failure:
    mov eax, SYS_EXIT
    mov edi, 0xEE
    int 0x80
    ud2
