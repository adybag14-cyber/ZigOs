; ZigOs legacy i686 kernel entry.
; The BIOS loader will eventually enter this image in 32-bit protected mode.

bits 32

section .text

global _start
extern zigos_legacy_kernel_main

_start:
    cli
    cld
    mov esp, 0x0009F000
    and esp, -16
    xor ebp, ebp
    call zigos_legacy_kernel_main

.hang:
    hlt
    jmp .hang
