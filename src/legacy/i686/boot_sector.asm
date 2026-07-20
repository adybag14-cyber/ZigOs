; ZigOs legacy BIOS stage-0 boot sector.
; Loaded by PC BIOS at physical address 0x00007C00.

bits 16
org 0x7C00

stage1_sectors equ 8
stage1_offset equ 0x8000

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    cld

    mov [boot_drive], dl
    mov si, banner
    call debug_write

    mov dl, [boot_drive]
    mov ah, 0x41
    mov bx, 0x55AA
    int 0x13
    jc edd_unavailable
    cmp bx, 0xAA55
    jne edd_unavailable
    test cx, 1
    jz edd_unavailable

    mov si, drive_prefix
    call debug_write
    mov al, [boot_drive]
    call debug_hex8
    mov si, edd_ready
    call debug_write

    mov si, stage1_dap
    mov dl, [boot_drive]
    mov ah, 0x42
    int 0x13
    jc stage1_read_failed

    mov si, stage1_loaded
    call debug_write
    mov dl, [boot_drive]
    jmp 0x0000:stage1_offset

edd_unavailable:
    mov si, edd_missing
    call debug_write
    jmp halt

stage1_read_failed:
    mov si, read_failed
    call debug_write

halt:
    cli
.hang:
    hlt
    jmp .hang

debug_write:
.next:
    lodsb
    test al, al
    jz .done
    call debug_putc
    jmp .next
.done:
    ret

debug_hex8:
    push ax
    shr al, 4
    call debug_hex4
    pop ax
    and al, 0x0F
    call debug_hex4
    ret

debug_hex4:
    cmp al, 10
    jb .digit
    add al, 'A' - 10
    jmp debug_putc
.digit:
    add al, '0'

debug_putc:
    mov dx, 0x00E9
    out dx, al
    ret

align 4, db 0
stage1_dap:
    db 0x10, 0
    dw stage1_sectors
    dw stage1_offset
    dw 0x0000
    dq 1

boot_drive: db 0
banner: db 'ZigOs legacy BIOS stage0 online', 13, 10, 0
drive_prefix: db 'ZigOs BIOS stage0 verified: drive 0x', 0
edd_ready: db ' EDD yes signature 0x55AA', 13, 10, 0
stage1_loaded: db 'ZigOs BIOS stage0 loaded stage1: LBA 1 sectors 8 address 0x00008000', 13, 10, 0
edd_missing: db 'ZigOs BIOS stage0 failed: EDD unavailable', 13, 10, 0
read_failed: db 'ZigOs BIOS stage0 failed: stage1 read', 13, 10, 0

times 510 - ($ - $$) db 0
dw 0xAA55
