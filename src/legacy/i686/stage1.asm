; ZigOs legacy BIOS stage-1 loader.
; Stage-0 loads this exact 8-sector image at physical address 0x00008000.

bits 16
org 0x8000

%ifndef KERNEL_SECTORS
%error KERNEL_SECTORS must be defined by the build
%endif

kernel_lba equ 9
kernel_segment equ 0x1000
kernel_address equ 0x00010000

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7A00
    sti
    cld
    mov [boot_drive], dl

    mov si, stage1_banner
    call debug_write16

    ; Fast A20 gate. Preserve all unrelated System Control Port A bits.
    in al, 0x92
    or al, 0x02
    and al, 0xFE
    out 0x92, al

    mov word [kernel_dap + 2], KERNEL_SECTORS
    mov si, kernel_dap
    mov dl, [boot_drive]
    mov ah, 0x42
    int 0x13
    jc kernel_read_failed

    mov si, kernel_loaded
    call debug_write16

    cli
    lgdt [gdt_descriptor]
    mov eax, cr0
    or eax, 1
    mov cr0, eax
    jmp dword 0x08:protected_mode

kernel_read_failed:
    mov si, kernel_failed
    call debug_write16
    cli
.hang16:
    hlt
    jmp .hang16

debug_write16:
.next:
    lodsb
    test al, al
    jz .done
    mov dx, 0x00E9
    out dx, al
    jmp .next
.done:
    ret

align 4, db 0
kernel_dap:
    db 0x10, 0
    dw 0
    dw 0x0000
    dw kernel_segment
    dq kernel_lba

align 8, db 0
gdt:
    dq 0x0000000000000000
    dq 0x00CF9A000000FFFF
    dq 0x00CF92000000FFFF
gdt_end:

gdt_descriptor:
    dw gdt_end - gdt - 1
    dd gdt

stage1_banner: db 'ZigOs BIOS stage1 online: real mode address 0x00008000', 13, 10, 0
kernel_loaded: db 'ZigOs BIOS stage1 loaded kernel: LBA 9 address 0x00010000', 13, 10, 0
kernel_failed: db 'ZigOs BIOS stage1 failed: kernel read', 13, 10, 0
boot_drive: db 0

bits 32
protected_mode:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, 0x0009F000
    and esp, -16
    xor ebp, ebp
    cld

    mov esi, protected_marker
    call debug_write32

    mov eax, kernel_address
    jmp eax

debug_write32:
.next:
    lodsb
    test al, al
    jz .done
    mov dx, 0x00E9
    out dx, al
    jmp .next
.done:
    ret

protected_marker: db 'ZigOs BIOS stage1 protected mode verified: CS 0x0008 CR0.PE yes kernel 0x00010000', 13, 10, 0

times 4096 - ($ - $$) db 0
