BITS 64
ORG 0

%include "src/user/zigos_abi.inc"

%define DATA_BASE       0x0000008000002000
%define START_MESSAGE   (DATA_BASE + 0)
%define PASS_MESSAGE    (DATA_BASE + 64)
%define PAYLOAD         (DATA_BASE + 160)
%define ABI_INFO        (DATA_BASE + 256)
%define LOCAL_ADDRESS   (DATA_BASE + 320)
%define PEER_ADDRESS    (DATA_BASE + 336)
%define POLL_BUFFER     (DATA_BASE + 352)

%define START_LENGTH    19
%define PASS_LENGTH     56
%define PAYLOAD_LENGTH  8

_start:
    mov eax, SYS_WRITE
    mov edi, 1
    mov rsi, START_MESSAGE
    mov edx, START_LENGTH
    int 0x80
    cmp eax, START_LENGTH
    jne .fail_start

    mov eax, SYS_ABI_QUERY
    mov rdi, ABI_INFO
    mov esi, 64
    int 0x80
    cmp eax, 64
    jne .fail_abi
    mov rbx, ABI_INFO
    test qword [rbx + 24], ZIGOS_CAP_UDP_SOCKETS
    jz .fail_abi

    mov eax, SYS_SOCKET
    mov edi, 2                  ; AF_INET
    mov esi, 2                  ; SOCK_DGRAM
    mov edx, 17                 ; UDP
    int 0x80
    test eax, eax
    js .fail_socket
    mov r12d, eax

    ; Bind 0.0.0.0:0 and obtain the allocated local endpoint.
    mov rbx, LOCAL_ADDRESS
    mov word [rbx + 0], 2
    mov word [rbx + 2], 0
    mov dword [rbx + 4], 0
    mov eax, SYS_BIND
    mov edi, r12d
    mov rsi, LOCAL_ADDRESS
    mov edx, 8
    int 0x80
    test eax, eax
    jnz .fail_bind

    mov eax, SYS_GETSOCKNAME
    mov edi, r12d
    mov rsi, LOCAL_ADDRESS
    mov edx, 8
    int 0x80
    cmp eax, 8
    jne .fail_name
    mov rbx, LOCAL_ADDRESS
    cmp word [rbx + 0], 2
    jne .fail_name
    cmp word [rbx + 2], 0
    je .fail_name
    cmp dword [rbx + 4], 0x0F02000A   ; 10.0.2.15 bytes
    jne .fail_name

    ; Connect to QEMU's retained gateway and transmit through e1000e.
    mov rbx, PEER_ADDRESS
    mov word [rbx + 0], 2
    mov word [rbx + 2], 0x0900         ; network-order port 9
    mov dword [rbx + 4], 0x0202000A    ; 10.0.2.2 bytes
    mov eax, SYS_CONNECT
    mov edi, r12d
    mov rsi, PEER_ADDRESS
    mov edx, 8
    int 0x80
    test eax, eax
    jnz .fail_connect

    mov rbx, POLL_BUFFER
    mov word [rbx + 0], r12w
    mov word [rbx + 2], 2              ; writable
    mov word [rbx + 4], 0
    mov word [rbx + 6], 0
    mov eax, SYS_POLL
    mov rdi, POLL_BUFFER
    mov esi, 1
    xor edx, edx
    int 0x80
    cmp eax, 1
    jne .fail_poll
    mov rbx, POLL_BUFFER
    test word [rbx + 4], 2
    jz .fail_poll

    mov eax, SYS_SEND
    mov edi, r12d
    mov rsi, PAYLOAD
    mov edx, PAYLOAD_LENGTH
    xor r10d, r10d
    int 0x80
    cmp eax, PAYLOAD_LENGTH
    jne .fail_send

    mov eax, SYS_CLOSE
    mov edi, r12d
    int 0x80
    test eax, eax
    jnz .fail_close

    mov eax, SYS_WRITE
    mov edi, 1
    mov rsi, PASS_MESSAGE
    mov edx, PASS_LENGTH
    int 0x80
    cmp eax, PASS_LENGTH
    jne .fail_pass

    mov eax, SYS_EXIT
    mov edi, 0x54
    int 0x80
    ud2

.fail_start:
    mov edi, 0xB0
    jmp .exit_failure
.fail_abi:
    mov edi, 0xB1
    jmp .exit_failure
.fail_socket:
    mov edi, 0xB2
    jmp .exit_failure
.fail_bind:
    mov edi, 0xB3
    jmp .exit_failure
.fail_name:
    mov edi, 0xB4
    jmp .exit_failure
.fail_connect:
    mov edi, 0xB5
    jmp .exit_failure
.fail_poll:
    mov edi, 0xB6
    jmp .exit_failure
.fail_send:
    mov edi, 0xB7
    jmp .exit_failure
.fail_close:
    mov edi, 0xB8
    jmp .exit_failure
.fail_pass:
    mov edi, 0xB9
.exit_failure:
    mov eax, SYS_EXIT
    int 0x80
    ud2
