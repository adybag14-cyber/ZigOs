; ZigOs x86-64 hardware primitives.
; The UEFI x86-64 ABI is the Microsoft x64 calling convention:
; first scalar/pointer argument in RCX, scalar return value in RAX.

bits 64
default rel

section .text

global zigos_cpuid_vendor
global zigos_read_cr0
global zigos_read_cr3
global zigos_read_cr4
global zigos_debug_putc

; void zigos_cpuid_vendor(u8 *out)
zigos_cpuid_vendor:
    push rbx                    ; RBX is non-volatile in the Microsoft x64 ABI
    mov r8, rcx
    xor eax, eax
    cpuid
    mov [r8 + 0], ebx
    mov [r8 + 4], edx
    mov [r8 + 8], ecx
    mov byte [r8 + 12], 0
    pop rbx
    ret

; u64 zigos_read_cr0(void)
zigos_read_cr0:
    mov rax, cr0
    ret

; u64 zigos_read_cr3(void)
zigos_read_cr3:
    mov rax, cr3
    ret

; u64 zigos_read_cr4(void)
zigos_read_cr4:
    mov rax, cr4
    ret

; void zigos_debug_putc(u8 character)
; Port 0xE9 is captured by QEMU's isa-debugcon device. On normal hardware this
; is only used during this early experimental boot milestone.
zigos_debug_putc:
    mov dx, 0x00E9
    mov al, cl
    out dx, al
    ret
