BITS 64
DEFAULT REL

%include "src/user/zigos_abi.inc"

SECTION .text
GLOBAL _start
GLOBAL zigos_syscall6
EXTERN zigos_main

; Kernel entry contract:
;   rdi = argc, rsi = argv, rsp = initial ZigOs argument vector.
; Establish the SysV AMD64 call-site stack alignment before entering Zig code.
_start:
    mov r12, rsp
    mov rdi, [r12]
    lea rsi, [r12 + 8]
    lea rdx, [rsi + rdi * 8 + 8]
    mov rcx, rdx
.scan_environment:
    cmp qword [rcx], 0
    je .environment_end
    add rcx, 8
    jmp .scan_environment
.environment_end:
    add rcx, 8
    and rsp, -16
    call zigos_main
    mov edi, eax
    mov eax, SYS_EXIT
    int 0x80
    ud2

; System V AMD64 C ABI used by x86_64-freestanding-none:
;   rdi = number, rsi = a0, rdx = a1, rcx = a2,
;   r8 = a3, r9 = a4, [rsp+8] = a5.
; ZigOs int 0x80 ABI:
;   rax = number, rdi/rsi/rdx/r10/r8/r9 = a0..a5.
zigos_syscall6:
    mov rax, rdi
    mov rdi, rsi
    mov rsi, rdx
    mov rdx, rcx
    mov r10, r8
    mov r8, r9
    mov r9, [rsp + 8]
    int 0x80
    ret
