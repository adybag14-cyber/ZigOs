; ZigOs legacy i686 kernel entry and exact hardware helpers.

bits 32

section .text

global _start
global zigos_i686_read_cr0
global zigos_i686_read_cr3
global zigos_i686_enable_paging
global zigos_i686_invalidate_page
global zigos_i686_cpuid_vendor
global zigos_i686_out8
global zigos_i686_in8
global zigos_i686_in16
global zigos_i686_load_idt
global zigos_i686_load_gdt
global zigos_i686_load_tr
global zigos_i686_read_tr
global zigos_i686_enter_user
global zigos_i686_user_return_stub
global zigos_i686_enable_interrupts
global zigos_i686_disable_interrupts
global zigos_i686_halt
global zigos_i686_irq0_stub
global zigos_i686_irq1_stub
global zigos_i686_exception_stub_table
global zigos_i686_trigger_breakpoint
extern zigos_legacy_kernel_main
extern zigos_i686_timer_interrupt
extern zigos_i686_keyboard_interrupt
extern zigos_i686_exception_dispatch
extern zigos_i686_user_return_dispatch
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

zigos_i686_read_cr3:
    mov eax, cr3
    ret

; cdecl: void zigos_i686_enable_paging(u32 page_directory)
zigos_i686_enable_paging:
    mov eax, [esp + 4]
    mov cr3, eax
    mov eax, cr0
    or eax, 0x80000000
    mov cr0, eax
    jmp short .paging_serialized
.paging_serialized:
    ret

; cdecl: void zigos_i686_invalidate_page(u32 address)
zigos_i686_invalidate_page:
    mov eax, [esp + 4]
    invlpg [eax]
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

; cdecl: u8 zigos_i686_in8(u16 port)
zigos_i686_in8:
    mov edx, [esp + 4]
    xor eax, eax
    in al, dx
    ret

; cdecl: u16 zigos_i686_in16(u16 port)
zigos_i686_in16:
    mov edx, [esp + 4]
    xor eax, eax
    in ax, dx
    ret

; cdecl: void zigos_i686_load_idt(const void *descriptor)
zigos_i686_load_idt:
    mov eax, [esp + 4]
    lidt [eax]
    ret

; cdecl: void zigos_i686_load_gdt(const void *descriptor)
zigos_i686_load_gdt:
    mov eax, [esp + 4]
    lgdt [eax]
    jmp 0x08:.reload_segments
.reload_segments:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    ret

zigos_i686_load_tr:
    mov eax, [esp + 4]
    ltr ax
    ret

zigos_i686_read_tr:
    xor eax, eax
    str ax
    ret

zigos_i686_enter_user:
    mov [zigos_i686_kernel_return_esp], esp
    mov eax, [esp + 4]
    mov edx, [esp + 8]
    mov cx, 0x23
    mov ds, cx
    mov es, cx
    mov fs, cx
    mov gs, cx
    push dword 0x23
    push edx
    push dword 0x00000002
    push dword 0x1B
    push eax
    iretd

zigos_i686_user_return_stub:
    pushad
    mov eax, esp
    mov ebp, esp
    and esp, -16
    sub esp, 12
    push eax
    cld
    call zigos_i686_user_return_dispatch
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    mov esp, [zigos_i686_kernel_return_esp]
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

zigos_i686_trigger_breakpoint:
    int3
    ret

zigos_i686_irq0_stub:
    pushad
    mov ebp, esp
    and esp, -16
    sub esp, 12
    push ebp
    cld
    call zigos_i686_timer_interrupt
    test eax, eax
    jnz .selected_context
    mov eax, ebp
.selected_context:
    mov esp, eax
    mov al, 0x20
    out 0x20, al
    popad
    iretd

zigos_i686_irq1_stub:
    pushad
    mov ebp, esp
    and esp, -16
    cld
    call zigos_i686_keyboard_interrupt
    mov esp, ebp
    mov al, 0x20
    out 0x20, al
    popad
    iretd

; Every exception reaches Zig with the same stack shape:
; pushad registers, vector, error code, EIP, CS, EFLAGS.
%macro EXCEPTION_NO_ERROR 1
zigos_i686_exception_%1:
    push dword 0
    push dword %1
    jmp zigos_i686_exception_common
%endmacro

%macro EXCEPTION_WITH_ERROR 1
zigos_i686_exception_%1:
    push dword %1
    jmp zigos_i686_exception_common
%endmacro

EXCEPTION_NO_ERROR 0
EXCEPTION_NO_ERROR 1
EXCEPTION_NO_ERROR 2
EXCEPTION_NO_ERROR 3
EXCEPTION_NO_ERROR 4
EXCEPTION_NO_ERROR 5
EXCEPTION_NO_ERROR 6
EXCEPTION_NO_ERROR 7
EXCEPTION_WITH_ERROR 8
EXCEPTION_NO_ERROR 9
EXCEPTION_WITH_ERROR 10
EXCEPTION_WITH_ERROR 11
EXCEPTION_WITH_ERROR 12
EXCEPTION_WITH_ERROR 13
EXCEPTION_WITH_ERROR 14
EXCEPTION_NO_ERROR 15
EXCEPTION_NO_ERROR 16
EXCEPTION_WITH_ERROR 17
EXCEPTION_NO_ERROR 18
EXCEPTION_NO_ERROR 19
EXCEPTION_NO_ERROR 20
EXCEPTION_WITH_ERROR 21
EXCEPTION_NO_ERROR 22
EXCEPTION_NO_ERROR 23
EXCEPTION_NO_ERROR 24
EXCEPTION_NO_ERROR 25
EXCEPTION_NO_ERROR 26
EXCEPTION_NO_ERROR 27
EXCEPTION_NO_ERROR 28
EXCEPTION_WITH_ERROR 29
EXCEPTION_WITH_ERROR 30
EXCEPTION_NO_ERROR 31

zigos_i686_exception_common:
    pushad
    mov eax, esp
    mov ebp, esp
    and esp, -16
    sub esp, 12
    push eax
    cld
    call zigos_i686_exception_dispatch
    mov esp, ebp
    popad
    add esp, 8
    iretd

section .rodata
align 4
zigos_i686_exception_stub_table:
%assign exception_index 0
%rep 32
    dd zigos_i686_exception_%+exception_index
%assign exception_index exception_index + 1
%endrep

section .data
align 4
global zigos_i686_entry_stack
global zigos_i686_boot_info_pointer
zigos_i686_entry_stack: dd 0
zigos_i686_boot_info_pointer: dd 0
global zigos_i686_kernel_return_esp
zigos_i686_kernel_return_esp: dd 0
