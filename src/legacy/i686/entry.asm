; ZigOs legacy i686 kernel entry and minimal hardware helpers.

bits 32

section .text

global _start
global zigos_i686_read_cr0
global zigos_i686_cpuid_vendor
global zigos_i686_out8
global zigos_i686_load_idt
global zigos_i686_enable_interrupts
global zigos_i686_disable_interrupts
global zigos_i686_halt
global zigos_i686_irq0_stub
extern zigos_legacy_kernel_main
extern zigos_i686_timer_interrupt
extern __bss_start
extern __bss_end

_start:
    cli
    cld
    mov esp, 0x0009F000
    and esp, -16
    xor ebp, ebp
    mov [zigos_i686_entry_stack], esp
    mov [zigos_i686_boot_info_pointer], esi

    ; Flat binaries do not carry an initialized BSS payload. Zero it before Zig.
    mov edi, __bss_start
    mov ecx, __bss_end
    sub ecx, edi
    xor eax, eax
    rep stosb

    call zigos_legacy_kernel_main

.hang:
    hlt
    jmp .hang

zigos_i686_read_cr0:
    mov eax, cr0
    ret

; cdecl: u32 zigos_i686_cpuid_vendor(u8 *destination)
zigos_i686_cpuid_vendor:
    push ebx
    push edi
    mov eax, 0
    cpuid
    mov edi, [esp + 12]
    mov [edi], ebx
    mov [edi + 4], edx
    mov [edi + 8], ecx
    pop edi
    pop ebx
    ret

; cdecl: void zigos_i686_out8(u16 port, u8 value)
zigos_i686_out8:
    mov edx, [esp + 4]
    mov eax, [esp + 8]
    out dx, al
    ret

; cdecl: void zigos_i686_load_idt(const void *descriptor)
zigos_i686_load_idt:
    mov eax, [esp + 4]
    lidt [eax]
    ret

zigos_i686_enable_interrupts:
    sti
    ret

zigos_i686_disable_interrupts:
    cli
    ret

zigos_i686_halt:
    hlt
    ret

zigos_i686_irq0_stub:
    pushad
    mov ebp, esp
    and esp, -16
    cld
    call zigos_i686_timer_interrupt
    mov esp, ebp
    mov al, 0x20
    out 0x20, al
    popad
    iretd

section .data
align 4
global zigos_i686_entry_stack
global zigos_i686_boot_info_pointer
zigos_i686_entry_stack: dd 0
zigos_i686_boot_info_pointer: dd 0
