BITS 64
ORG 0

%define SYS_EXIT  64
%define SYS_SLEEP 68

entry:
    mov eax, SYS_SLEEP
    mov edi, 1
    int 0x80
    test eax, eax
    jne failure

    mov eax, SYS_EXIT
    mov edi, 0x2A
    int 0x80
    ud2

failure:
    mov eax, SYS_EXIT
    mov edi, 0xEE
    int 0x80
    ud2
