; ZigOs application-processor startup trampoline.
; NASM flat binary copied into one UEFI-reserved page below 1 MiB.

bits 16
org 0

jmp short real_mode_start
nop

times 0x10 - ($ - $$) db 0

boot_signature:        dq 0x5A49474F53415031
boot_cr3:              dq 0
boot_stack_top:        dq 0
boot_entry_point:      dq 0
boot_expected_apic_id: dd 0
boot_actual_apic_id:   dd 0xFFFFFFFF
boot_online:           dd 0
boot_state:            dd 0

gdt_descriptor:
    dw gdt_end - gdt - 1
    dd gdt
protected_mode_pointer:
    dd protected_mode_start
    dw 0x08
long_mode_pointer:
    dd long_mode_start
    dw 0x18

times 0x60 - ($ - $$) db 0

real_mode_start:
    cli
    mov al, 'R'
    out 0xE9, al
    cld
    mov ax, cs
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x0FF0
    lgdt [gdt_descriptor]
    mov al, 'G'
    out 0xE9, al
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    jmp dword far [protected_mode_pointer]

bits 32
protected_mode_start:
    mov al, 'P'
    out 0xE9, al
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov eax, [cs:boot_stack_top]
    mov esp, eax
    mov eax, cr0
    and eax, 0xFFFFFFF3
    or eax, 0x00000002
    mov cr0, eax
    mov eax, cr4
    or eax, (1 << 5) | (1 << 9) | (1 << 10)
    mov cr4, eax
    mov eax, [cs:boot_cr3]
    mov cr3, eax
    mov ecx, 0xC0000080
    rdmsr
    or eax, (1 << 8)
    wrmsr
    mov eax, cr0
    or eax, 0x80000000
    mov cr0, eax
    jmp far [cs:long_mode_pointer]

bits 64
long_mode_start:
    mov al, 'L'
    out 0xE9, al
    mov ax, 0x20
    mov ds, ax
    mov es, ax
    mov ss, ax
    xor eax, eax
    mov fs, ax
    mov gs, ax
    mov rsp, [rel boot_stack_top]
    and rsp, -16
    sub rsp, 32
    lea rcx, [rel boot_signature]
    mov rax, [rel boot_entry_point]
    call rax
.ap_halt:
    cli
    hlt
    jmp .ap_halt

times 0x300 - ($ - $$) db 0

gdt:
    dq 0x0000000000000000
    dq 0x00CF9A000000FFFF
    dq 0x00CF92000000FFFF
    dq 0x00AF9A000000FFFF
    dq 0x00CF92000000FFFF
gdt_end:

times 4096 - ($ - $$) db 0