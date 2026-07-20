; ZigOs legacy BIOS stage-1 loader.
; Stage-0 loads this exact 8-sector image at physical address 0x00008000.

bits 16
org 0x8000

%ifndef KERNEL_SECTORS
%error KERNEL_SECTORS must be defined by the build
%endif
%ifndef KERNEL_BYTES
%error KERNEL_BYTES must be defined by the build
%endif

kernel_lba equ 9
kernel_segment equ 0x1000
kernel_address equ 0x00010000
boot_info_address equ 0x00005000
e820_entries_address equ 0x00005200
maximum_e820_entries equ 64
boot_info_magic equ 0x4F49425A

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

    call initialize_boot_info
    call collect_e820
    jc e820_failed
    mov si, e820_ready
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

initialize_boot_info:
    mov di, boot_info_address
    xor ax, ax
    mov cx, 16
    rep stosw
    mov dword [boot_info_address + 0], boot_info_magic
    mov word [boot_info_address + 4], 1
    mov word [boot_info_address + 6], 32
    mov word [boot_info_address + 8], 24
    mov dword [boot_info_address + 12], e820_entries_address
    mov al, [boot_drive]
    mov byte [boot_info_address + 16], al
    mov dword [boot_info_address + 20], kernel_address
    mov dword [boot_info_address + 24], KERNEL_BYTES
    mov word [boot_info_address + 28], KERNEL_SECTORS
    ret

collect_e820:
    xor ebx, ebx
    mov di, e820_entries_address
    xor bp, bp
.next:
    cmp bp, maximum_e820_entries
    jae .success
    mov dword [es:di + 20], 1
    mov eax, 0x0000E820
    mov edx, 0x534D4150
    mov ecx, 24
    int 0x15
    jc .firmware_end
    cmp eax, 0x534D4150
    jne .failure
    cmp ecx, 20
    jb .failure
    cmp ecx, 24
    jae .record
    mov dword [es:di + 20], 0
.record:
    inc bp
    add di, 24
    test ebx, ebx
    jnz .next
.success:
    test bp, bp
    jz .failure
    mov word [boot_info_address + 10], bp
    or byte [boot_info_address + 17], 1
    clc
    ret
.firmware_end:
    test bp, bp
    jnz .success
.failure:
    stc
    ret

e820_failed:
    mov si, e820_missing
    call debug_write16
    jmp halt16

kernel_read_failed:
    mov si, kernel_failed
    call debug_write16
halt16:
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
e820_ready: db 'ZigOs BIOS stage1 E820 boot contract ready: info 0x00005000 entries 0x00005200', 13, 10, 0
kernel_loaded: db 'ZigOs BIOS stage1 loaded kernel: LBA 9 address 0x00010000', 13, 10, 0
e820_missing: db 'ZigOs BIOS stage1 failed: E820 unavailable', 13, 10, 0
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

    mov esi, boot_info_address
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
