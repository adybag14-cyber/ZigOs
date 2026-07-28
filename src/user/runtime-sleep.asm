BITS 64
ORG 0

%define DATA_BASE 0x0000008000002000
%define SYS_EXIT  64
%define SYS_WRITE 65
%define SYS_SLEEP 68

entry:
    mov eax, SYS_WRITE
    mov edi, 1
    mov rsi, DATA_BASE
    mov edx, 15
    int 0x80
    cmp eax, 15
    jne failure

    mov eax, SYS_SLEEP
    mov edi, 32
    int 0x80
    test eax, eax
    jne failure

    mov eax, SYS_WRITE
    mov edi, 1
    mov rsi, DATA_BASE + 32
    mov edx, 14
    int 0x80
    cmp eax, 14
    jne failure

    mov eax, SYS_EXIT
    mov edi, 7
    int 0x80
    ud2

failure:
    mov eax, SYS_EXIT
    mov edi, 0xEE
    int 0x80
    ud2
