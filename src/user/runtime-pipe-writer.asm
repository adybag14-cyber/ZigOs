BITS 64
ORG 0

%define DATA_BASE 0x0000008000002000
%define SYS_EXIT  64
%define SYS_WRITE 65

entry:
    test rdx, rdx
    jnz .standard_stream
    mov r12d, esi
    jmp .write
.standard_stream:
    mov r12d, 1
.write:

    mov eax, SYS_WRITE
    mov edi, r12d
    mov rsi, DATA_BASE
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
