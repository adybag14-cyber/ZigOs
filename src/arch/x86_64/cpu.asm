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

global zigos_halt_forever

; noreturn zigos_halt_forever(void)
; Once boot services are gone, ZigOs disables interrupts until it installs its
; own IDT and interrupt controllers in a later milestone.
zigos_halt_forever:
    cli
.hang:
    hlt
    jmp .hang

global zigos_enter_kernel

; noreturn zigos_enter_kernel(void *stack_top, BootInfo *info, KernelEntry entry)
; RCX = one-past-end stack address, RDX = BootInfo, R8 = kernel entry.
zigos_enter_kernel:
    mov rsp, rcx
    and rsp, -16
    xor rbp, rbp
    mov rcx, rdx
    sub rsp, 32                 ; Microsoft x64 shadow space
    call r8
    ud2                         ; the kernel entry is contractually noreturn


global zigos_load_cr3

; void zigos_load_cr3(usize physical_address)
; Loading CR3 installs ZigOs-owned page tables and flushes non-global TLB state.
zigos_load_cr3:
    mov cr3, rcx
    ret


extern zigos_breakpoint_handler

global zigos_load_gdt
global zigos_load_idt
global zigos_read_cs
global zigos_read_tr
global zigos_isr_breakpoint
global zigos_trigger_breakpoint

; void zigos_load_gdt(GDTR *pointer, u16 code, u16 data, u16 tss)
; RCX = GDTR, DX = code selector, R8W = data selector, R9W = TSS selector.
zigos_load_gdt:
    lgdt [rcx]

    mov ax, r8w
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax

    movzx eax, dx
    push rax
    lea rax, [rel .reload_cs]
    push rax
    retfq
.reload_cs:
    mov ax, r9w
    ltr ax
    ret

; void zigos_load_idt(IDTR *pointer)
zigos_load_idt:
    lidt [rcx]
    ret

; u64 zigos_read_cs(void)
zigos_read_cs:
    xor eax, eax
    mov ax, cs
    ret

; u64 zigos_read_tr(void)
zigos_read_tr:
    xor eax, eax
    str ax
    ret

; Normal callable helper used to trigger vector 3 after the IDT is installed.
zigos_trigger_breakpoint:
    int3
    ret

; Vector 3 interrupt entry. The IDT assigns IST1, so the CPU switches to the
; ZigOs interrupt stack before entering this stub. Preserve all general-purpose
; registers, establish the Microsoft x64 call frame, then return with IRETQ.
zigos_isr_breakpoint:
    cld
    push rax
    push rcx
    push rdx
    push rbx
    push rbp
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    mov r12, rsp
    and rsp, -16
    sub rsp, 32
    mov ecx, 3
    mov rdx, r12
    call zigos_breakpoint_handler
    mov rsp, r12

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    pop rdx
    pop rcx
    pop rax
    iretq
