; ZigOs x86-64 hardware primitives.
; The UEFI x86-64 ABI is the Microsoft x64 calling convention:
; first scalar/pointer argument in RCX, scalar return value in RAX.

bits 64
default rel

section .text

global zigos_cpuid_vendor
global zigos_cpu_has_x2apic
global zigos_cpu_has_nx
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

; u8 zigos_cpu_has_x2apic(void)
; CPUID.01H:ECX[21] advertises the x2APIC architecture. RBX is preserved
; because it is non-volatile in the Microsoft x64 ABI used by UEFI.
zigos_cpu_has_x2apic:
    push rbx
    mov eax, 1
    cpuid
    bt ecx, 21
    setc al
    movzx eax, al
    pop rbx
    ret

 ; u8 zigos_cpu_has_nx(void)
; CPUID.80000001H:EDX[20] advertises execute-disable page-table support.
zigos_cpu_has_nx:
    push rbx
    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000001
    jb .no_nx
    mov eax, 0x80000001
    cpuid
    bt edx, 20
    setc al
    movzx eax, al
    pop rbx
    ret
.no_nx:
    xor eax, eax
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
    cli
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

global zigos_isr_spurious
global zigos_read_msr
global zigos_write_msr
global zigos_out8
global zigos_in8
global zigos_out32
global zigos_in32

; Local-APIC spurious vector. Intel specifies that a spurious interrupt does
; not require an EOI; return directly to the interrupted context.
zigos_isr_spurious:
    iretq

; u64 zigos_read_msr(u32 index)
zigos_read_msr:
    rdmsr
    shl rdx, 32
    or rax, rdx
    ret

; void zigos_write_msr(u32 index, u64 value)
zigos_write_msr:
    mov r8, rdx
    mov eax, r8d
    shr r8, 32
    mov edx, r8d
    wrmsr
    ret

; void zigos_out8(u16 port, u8 value)
zigos_out8:
    mov al, dl
    mov dx, cx
    out dx, al
    ret

; u8 zigos_in8(u16 port)
zigos_in8:
    mov dx, cx
    in al, dx
    movzx eax, al
    ret

; void zigos_out32(u16 port, u32 value)
zigos_out32:
    mov eax, edx
    mov dx, cx
    out dx, eax
    ret

; u32 zigos_in32(u16 port)
zigos_in32:
    mov dx, cx
    in eax, dx
    ret

global zigos_isr_apic_timer
global zigos_isr_ap_work
global zigos_isr_ap_timer
global zigos_isr_external_irq0
global zigos_isr_ps2_keyboard
global zigos_isr_nvme
global zigos_isr_ahci
global zigos_isr_xhci
global zigos_isr_e1000e
global zigos_wait_for_interrupt
global zigos_enable_interrupts
global zigos_disable_interrupts
extern zigos_apic_timer_handler
extern zigos_ap_work_interrupt_handler
extern zigos_ap_timer_interrupt_handler
extern zigos_pit_irq_handler
extern zigos_ps2_keyboard_irq_handler
extern zigos_nvme_interrupt_handler
extern zigos_ahci_interrupt_handler
extern zigos_xhci_interrupt_handler
extern zigos_e1000e_interrupt_handler

; APIC timer vector 0x40, delivered on IST1. Preserve all general-purpose
; registers and call the Zig handler, which acknowledges the local APIC.
zigos_isr_apic_timer:
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
    sub rsp, 512
    mov r13, rsp
    fxsave64 [r13]
    sub rsp, 32
    mov rcx, r12
    mov rdx, r13
    call zigos_apic_timer_handler
    add rsp, 32
    fxrstor64 [rsp]
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

; Per-AP local timer vector 0x43, delivered on the AP-private IST1 stack.
; The timer is armed by the AP itself and wakes it autonomously from HLT.
zigos_isr_ap_timer:
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
    sub rsp, 512
    mov r13, rsp
    fxsave64 [r13]
    sub rsp, 32
    call zigos_ap_timer_interrupt_handler
    add rsp, 32
    fxrstor64 [rsp]
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

; Targeted AP work vector 0x42, delivered on the AP-private IST1 stack.
; Preserve complete integer and x87/SSE state, acknowledge the local APIC in Zig,
; then return to the instruction following HLT.
zigos_isr_ap_work:
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
    sub rsp, 512
    mov r13, rsp
    fxsave64 [r13]
    sub rsp, 32
    call zigos_ap_work_interrupt_handler
    add rsp, 32
    fxrstor64 [rsp]
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

; External ISA IRQ0 routed through the IOAPIC to vector 0x44 on BSP IST1.
zigos_isr_external_irq0:
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
    sub rsp, 512
    mov r13, rsp
    fxsave64 [r13]
    sub rsp, 32
    call zigos_pit_irq_handler
    add rsp, 32
    fxrstor64 [rsp]
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

; PS/2 keyboard IRQ1 routed through the IOAPIC to vector 0x45 on BSP IST1.
zigos_isr_ps2_keyboard:
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
    sub rsp, 512
    mov r13, rsp
    fxsave64 [r13]
    sub rsp, 32
    call zigos_ps2_keyboard_irq_handler
    add rsp, 32
    fxrstor64 [rsp]
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

; NVMe MSI-X vector 0x46, delivered on IST1 to a routable online CPU.
zigos_isr_nvme:
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
    sub rsp, 512
    mov r13, rsp
    fxsave64 [r13]
    sub rsp, 32
    call zigos_nvme_interrupt_handler
    add rsp, 32
    fxrstor64 [rsp]
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

; AHCI MSI vector 0x47, delivered on IST1 to a routable online CPU.
zigos_isr_ahci:
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
    sub rsp, 512
    mov r13, rsp
    fxsave64 [r13]
    sub rsp, 32
    call zigos_ahci_interrupt_handler
    add rsp, 32
    fxrstor64 [rsp]
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

; xHCI MSI-X vector 0x48, delivered on IST1 to a routable online CPU.
zigos_isr_xhci:
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
    sub rsp, 512
    mov r13, rsp
    fxsave64 [r13]
    sub rsp, 32
    call zigos_xhci_interrupt_handler
    add rsp, 32
    fxrstor64 [rsp]
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

; e1000e MSI-X vector 0x49, delivered on IST1 to a routable online CPU.
zigos_isr_e1000e:
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
    sub rsp, 512
    mov r13, rsp
    fxsave64 [r13]
    sub rsp, 32
    call zigos_e1000e_interrupt_handler
    add rsp, 32
    fxrstor64 [rsp]
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

; Wait for one maskable interrupt, then return with interrupts disabled.
zigos_wait_for_interrupt:
    sti
    hlt
    cli
    ret
zigos_enable_interrupts:
    sti
    ret

zigos_disable_interrupts:
    cli
    ret


extern zigos_exception_handler

global zigos_exception_stub_address
global zigos_read_cr2
global zigos_trigger_ud2

%macro ZIGOS_EXCEPTION_NO_ERROR 1
zigos_exception_%1:
    push qword 0
    push qword %1
    jmp zigos_exception_common
%endmacro

%macro ZIGOS_EXCEPTION_WITH_ERROR 1
zigos_exception_%1:
    push qword %1
    jmp zigos_exception_common
%endmacro

ZIGOS_EXCEPTION_NO_ERROR 0
ZIGOS_EXCEPTION_NO_ERROR 1
ZIGOS_EXCEPTION_NO_ERROR 2
ZIGOS_EXCEPTION_NO_ERROR 3
ZIGOS_EXCEPTION_NO_ERROR 4
ZIGOS_EXCEPTION_NO_ERROR 5
ZIGOS_EXCEPTION_NO_ERROR 6
ZIGOS_EXCEPTION_NO_ERROR 7
ZIGOS_EXCEPTION_WITH_ERROR 8
ZIGOS_EXCEPTION_NO_ERROR 9
ZIGOS_EXCEPTION_WITH_ERROR 10
ZIGOS_EXCEPTION_WITH_ERROR 11
ZIGOS_EXCEPTION_WITH_ERROR 12
ZIGOS_EXCEPTION_WITH_ERROR 13
ZIGOS_EXCEPTION_WITH_ERROR 14
ZIGOS_EXCEPTION_NO_ERROR 15
ZIGOS_EXCEPTION_NO_ERROR 16
ZIGOS_EXCEPTION_WITH_ERROR 17
ZIGOS_EXCEPTION_NO_ERROR 18
ZIGOS_EXCEPTION_NO_ERROR 19
ZIGOS_EXCEPTION_NO_ERROR 20
ZIGOS_EXCEPTION_WITH_ERROR 21
ZIGOS_EXCEPTION_NO_ERROR 22
ZIGOS_EXCEPTION_NO_ERROR 23
ZIGOS_EXCEPTION_NO_ERROR 24
ZIGOS_EXCEPTION_NO_ERROR 25
ZIGOS_EXCEPTION_NO_ERROR 26
ZIGOS_EXCEPTION_NO_ERROR 27
ZIGOS_EXCEPTION_NO_ERROR 28
ZIGOS_EXCEPTION_WITH_ERROR 29
ZIGOS_EXCEPTION_WITH_ERROR 30
ZIGOS_EXCEPTION_NO_ERROR 31

zigos_exception_common:
    cld
    push rax
    push rbx
    push rcx
    push rdx
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
    mov rcx, r12
    call zigos_exception_handler
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
    pop rdx
    pop rcx
    pop rbx
    pop rax
    add rsp, 16
    iretq

; usize zigos_exception_stub_address(u8 vector)
zigos_exception_stub_address:
    movzx ecx, cl
    lea rax, [rel zigos_exception_stub_table]
    mov rax, [rax + rcx * 8]
    ret

; u64 zigos_read_cr2(void)
zigos_read_cr2:
    mov rax, cr2
    ret

; Controlled invalid-opcode test. The Zig handler advances RIP by two bytes.
zigos_trigger_ud2:
    push rbp
    mov rbp, rsp
    ud2
    pop rbp
    ret

section .rdata align=8
zigos_exception_stub_table:
    dq zigos_exception_0, zigos_exception_1, zigos_exception_2, zigos_exception_3
    dq zigos_exception_4, zigos_exception_5, zigos_exception_6, zigos_exception_7
    dq zigos_exception_8, zigos_exception_9, zigos_exception_10, zigos_exception_11
    dq zigos_exception_12, zigos_exception_13, zigos_exception_14, zigos_exception_15
    dq zigos_exception_16, zigos_exception_17, zigos_exception_18, zigos_exception_19
    dq zigos_exception_20, zigos_exception_21, zigos_exception_22, zigos_exception_23
    dq zigos_exception_24, zigos_exception_25, zigos_exception_26, zigos_exception_27
    dq zigos_exception_28, zigos_exception_29, zigos_exception_30, zigos_exception_31

section .text


global zigos_memory_fence

; Serialize normal-memory DMA descriptors before and after MMIO doorbells.
zigos_memory_fence:
    mfence
    ret


global zigos_context_switch

; void zigos_context_switch(usize *old_rsp, usize new_rsp)
; Preserve every Microsoft x64 non-volatile integer register plus XMM6-XMM15.
; RCX = storage for the outgoing RSP, RDX = incoming saved RSP.
zigos_context_switch:
    sub rsp, 160
    movdqu [rsp + 0], xmm6
    movdqu [rsp + 16], xmm7
    movdqu [rsp + 32], xmm8
    movdqu [rsp + 48], xmm9
    movdqu [rsp + 64], xmm10
    movdqu [rsp + 80], xmm11
    movdqu [rsp + 96], xmm12
    movdqu [rsp + 112], xmm13
    movdqu [rsp + 128], xmm14
    movdqu [rsp + 144], xmm15

    push rbx
    push rbp
    push rdi
    push rsi
    push r12
    push r13
    push r14
    push r15

    mov [rcx], rsp
    mov rsp, rdx

    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rdi
    pop rbp
    pop rbx

    movdqu xmm6, [rsp + 0]
    movdqu xmm7, [rsp + 16]
    movdqu xmm8, [rsp + 32]
    movdqu xmm9, [rsp + 48]
    movdqu xmm10, [rsp + 64]
    movdqu xmm11, [rsp + 80]
    movdqu xmm12, [rsp + 96]
    movdqu xmm13, [rsp + 112]
    movdqu xmm14, [rsp + 128]
    movdqu xmm15, [rsp + 144]
    add rsp, 160
    ret


extern zigos_scheduler_interrupt_handler

global zigos_isr_scheduler
global zigos_trigger_scheduler_interrupt
global zigos_fxsave
global zigos_cpu_relax

; Software scheduling vector 0x41. It uses the same complete CPU/FX frame as
; the APIC timer, but requires no local-APIC EOI.
zigos_isr_scheduler:
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
    sub rsp, 512
    mov r13, rsp
    fxsave64 [r13]
    sub rsp, 32
    mov rcx, r12
    mov rdx, r13
    call zigos_scheduler_interrupt_handler
    add rsp, 32
    fxrstor64 [rsp]
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

zigos_trigger_scheduler_interrupt:
    int 0x41
    ret

; Capture a baseline x87/SSE state for a newly constructed task.
zigos_fxsave:
    fxsave64 [rcx]
    ret

zigos_cpu_relax:
    pause
    ret


global zigos_high_half_probe

; Return the address observed through RIP-relative execution. Calling this
; through the high-half alias proves the CPU fetched and executed aliased code.
zigos_high_half_probe:
    lea rax, [rel zigos_high_half_probe]
    ret


extern zigos_user_syscall_handler

global zigos_enter_user
global zigos_isr_syscall
global zigos_user_program_source
global zigos_user_program_size

section .data align=8
zigos_user_kernel_rsp:
    dq 0

section .text

; void zigos_enter_user(usize RIP, usize RSP, u16 CS, u16 SS)
; Preserve the Microsoft x64 nonvolatile kernel state, build an outer-privilege
; IRET frame, and transfer to CPL3. The exit syscall restores this exact state.
zigos_enter_user:
    mov r10, rcx
    mov r11, rdx
    movzx eax, r8w
    movzx edx, r9w

    sub rsp, 160
    movdqu [rsp + 0], xmm6
    movdqu [rsp + 16], xmm7
    movdqu [rsp + 32], xmm8
    movdqu [rsp + 48], xmm9
    movdqu [rsp + 64], xmm10
    movdqu [rsp + 80], xmm11
    movdqu [rsp + 96], xmm12
    movdqu [rsp + 112], xmm13
    movdqu [rsp + 128], xmm14
    movdqu [rsp + 144], xmm15
    push rbx
    push rbp
    push rdi
    push rsi
    push r12
    push r13
    push r14
    push r15
    mov [rel zigos_user_kernel_rsp], rsp

    push rdx
    push r11
    push qword 0x202
    push rax
    push r10
    iretq

; DPL3 interrupt gate vector 0x80, delivered on IST1. The Zig handler returns
; zero to resume userspace or nonzero to restore the saved kernel call frame.
zigos_isr_syscall:
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
    sub rsp, 512
    mov r13, rsp
    fxsave64 [r13]
    sub rsp, 32
    mov rcx, r12
    mov rdx, r13
    call zigos_user_syscall_handler
    test rax, rax
    jnz .return_to_kernel

    add rsp, 32
    fxrstor64 [rsp]
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

.return_to_kernel:
    cli
    mov rsp, [rel zigos_user_kernel_rsp]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rdi
    pop rbp
    pop rbx
    movdqu xmm6, [rsp + 0]
    movdqu xmm7, [rsp + 16]
    movdqu xmm8, [rsp + 32]
    movdqu xmm9, [rsp + 48]
    movdqu xmm10, [rsp + 64]
    movdqu xmm11, [rsp + 80]
    movdqu xmm12, [rsp + 96]
    movdqu xmm13, [rsp + 112]
    movdqu xmm14, [rsp + 128]
    movdqu xmm15, [rsp + 144]
    add rsp, 160
    ret

; Position-independent userspace payload copied into a U/S executable page.
zigos_user_program_start:
    mov eax, 1
    mov edi, 0xC0DEFACE
    int 0x80
    cmp eax, 0x051A11CE
    jne .user_failure
    mov eax, 2
    mov edi, 0x42
    int 0x80
    ud2
.user_failure:
    mov eax, 2
    mov edi, 0xEE
    int 0x80
    ud2
zigos_user_program_end:

zigos_user_program_source:
    lea rax, [rel zigos_user_program_start]
    ret

zigos_user_program_size:
    mov eax, zigos_user_program_end - zigos_user_program_start
    ret
