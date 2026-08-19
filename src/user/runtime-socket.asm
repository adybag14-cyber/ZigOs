BITS 64
ORG 0

%include "src/user/zigos_abi.inc"

%define DATA_BASE       0x0000008000002000
%define START_MESSAGE   (DATA_BASE + 0)
%define PASS_MESSAGE    (DATA_BASE + 64)
%define PAYLOAD         (DATA_BASE + 160)
%define DNS_QUERY       (DATA_BASE + 192)
%define ABI_INFO        (DATA_BASE + 256)
%define LOCAL_ADDRESS   (DATA_BASE + 320)
%define PEER_ADDRESS    (DATA_BASE + 336)
%define POLL_BUFFER     (DATA_BASE + 352)
%define DNS_ADDRESS     (DATA_BASE + 368)
%define SOURCE_ADDRESS  (DATA_BASE + 384)
%define RECEIVE_BUFFER  (DATA_BASE + 400)

%define START_LENGTH    19
%define PASS_LENGTH     52
%define PAYLOAD_LENGTH  8
%define DNS_QUERY_LENGTH 27
%define RECEIVE_CAPACITY 512

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
    test qword [rbx + 24], ZIGOS_CAP_TCP_SOCKETS
    jz .fail_abi
    cmp word [rbx + 8], 5
    jb .fail_abi

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

    ; Socket-level nonblocking mode must reject an empty queue immediately.
    mov eax, SYS_SETNONBLOCK
    mov edi, r12d
    mov esi, 1
    int 0x80
    test eax, eax
    jnz .fail_nonblock

    mov eax, SYS_RECVFROM
    mov edi, r12d
    mov rsi, RECEIVE_BUFFER
    mov edx, RECEIVE_CAPACITY
    xor r10d, r10d
    mov r8, SOURCE_ADDRESS
    mov r9d, 8
    int 0x80
    cmp rax, ERRNO_WOULD_BLOCK
    jne .fail_nonblock

    mov eax, SYS_SETNONBLOCK
    mov edi, r12d
    xor esi, esi
    int 0x80
    test eax, eax
    jnz .fail_nonblock

    ; Per-call MSG_DONTWAIT must have the same empty-queue result.
    mov eax, SYS_RECVFROM
    mov edi, r12d
    mov rsi, RECEIVE_BUFFER
    mov edx, RECEIVE_CAPACITY
    mov r10d, ZIGOS_MSG_DONTWAIT
    mov r8, SOURCE_ADDRESS
    mov r9d, 8
    int 0x80
    cmp rax, ERRNO_WOULD_BLOCK
    jne .fail_nonblock

    ; Send an unconnected DNS query to QEMU's retained resolver.
    mov rbx, DNS_ADDRESS
    mov word [rbx + 0], 2
    mov word [rbx + 2], 0x3500         ; network-order port 53
    mov dword [rbx + 4], 0x0302000A    ; 10.0.2.3 bytes
    mov eax, SYS_SENDTO
    mov edi, r12d
    mov rsi, DNS_QUERY
    mov edx, DNS_QUERY_LENGTH
    xor r10d, r10d
    mov r8, DNS_ADDRESS
    mov r9d, 8
    int 0x80
    cmp eax, DNS_QUERY_LENGTH
    jne .fail_sendto

    ; Blocking recvfrom returns through the normal scheduler wakeup path.
    mov eax, SYS_RECVFROM
    mov edi, r12d
    mov rsi, RECEIVE_BUFFER
    mov edx, RECEIVE_CAPACITY
    xor r10d, r10d
    mov r8, SOURCE_ADDRESS
    mov r9d, 8
    int 0x80
    cmp eax, 12
    jb .fail_recvfrom
    mov r13d, eax

    mov rbx, SOURCE_ADDRESS
    cmp word [rbx + 0], 2
    jne .fail_source
    cmp word [rbx + 2], 0x3500
    jne .fail_source
    cmp dword [rbx + 4], 0x0302000A
    jne .fail_source
    mov rbx, RECEIVE_BUFFER
    cmp word [rbx + 0], 0x5A5A
    jne .fail_recvfrom
    test byte [rbx + 2], 0x80          ; DNS response bit
    jz .fail_recvfrom

    ; Connect to QEMU's retained gateway and verify the stored peer.
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

    mov eax, SYS_GETPEERNAME
    mov edi, r12d
    mov rsi, SOURCE_ADDRESS
    mov edx, 8
    int 0x80
    cmp eax, 8
    jne .fail_peer
    mov rbx, SOURCE_ADDRESS
    cmp word [rbx + 0], 2
    jne .fail_peer
    cmp word [rbx + 2], 0x0900
    jne .fail_peer
    cmp dword [rbx + 4], 0x0202000A
    jne .fail_peer

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

    ; G300: active-open a TCP stream to QEMU's host gateway.
    mov eax, SYS_SOCKET
    mov edi, 2                  ; AF_INET
    mov esi, 1                  ; SOCK_STREAM
    mov edx, 6                  ; TCP
    int 0x80
    test eax, eax
    js .fail_tcp_socket
    mov r12d, eax

    mov rbx, PEER_ADDRESS
    mov word [rbx + 0], 2
    mov word [rbx + 2], 0x5998         ; network-order port 39001
    mov dword [rbx + 4], 0x0202000A    ; 10.0.2.2 host gateway
    mov eax, SYS_CONNECT
    mov edi, r12d
    mov rsi, PEER_ADDRESS
    mov edx, 8
    int 0x80
    test eax, eax
    jnz .fail_tcp_connect

    mov eax, SYS_GETSOCKNAME
    mov edi, r12d
    mov rsi, LOCAL_ADDRESS
    mov edx, 8
    int 0x80
    cmp eax, 8
    jne .fail_tcp_name
    mov rbx, LOCAL_ADDRESS
    cmp word [rbx + 0], 2
    jne .fail_tcp_name
    cmp word [rbx + 2], 0
    je .fail_tcp_name
    cmp dword [rbx + 4], 0x0F02000A
    jne .fail_tcp_name

    mov eax, SYS_GETPEERNAME
    mov edi, r12d
    mov rsi, SOURCE_ADDRESS
    mov edx, 8
    int 0x80
    cmp eax, 8
    jne .fail_tcp_peer
    mov rbx, SOURCE_ADDRESS
    cmp word [rbx + 0], 2
    jne .fail_tcp_peer
    cmp word [rbx + 2], 0x5998
    jne .fail_tcp_peer
    cmp dword [rbx + 4], 0x0202000A
    jne .fail_tcp_peer

    mov rbx, POLL_BUFFER
    mov word [rbx + 0], r12w
    mov word [rbx + 2], 2              ; writable once established
    mov word [rbx + 4], 0
    mov word [rbx + 6], 0
    mov eax, SYS_POLL
    mov rdi, POLL_BUFFER
    mov esi, 1
    xor edx, edx
    int 0x80
    cmp eax, 1
    jne .fail_tcp_poll
    mov rbx, POLL_BUFFER
    test word [rbx + 4], 2
    jz .fail_tcp_poll

    ; G313 remains open: connect must not silently expose TCP payload send.
    mov eax, SYS_SEND
    mov edi, r12d
    mov rsi, PAYLOAD
    mov edx, PAYLOAD_LENGTH
    xor r10d, r10d
    int 0x80
    cmp rax, ERRNO_NO_SYSCALL
    jne .fail_tcp_boundary

    mov eax, SYS_CLOSE
    mov edi, r12d
    int 0x80
    test eax, eax
    jnz .fail_tcp_close

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
.fail_nonblock:
    mov edi, 0xB5
    jmp .exit_failure
.fail_sendto:
    mov edi, 0xB6
    jmp .exit_failure
.fail_recvfrom:
    mov edi, 0xB7
    jmp .exit_failure
.fail_source:
    mov edi, 0xB8
    jmp .exit_failure
.fail_connect:
    mov edi, 0xB9
    jmp .exit_failure
.fail_peer:
    mov edi, 0xBA
    jmp .exit_failure
.fail_poll:
    mov edi, 0xBB
    jmp .exit_failure
.fail_send:
    mov edi, 0xBC
    jmp .exit_failure
.fail_close:
    mov edi, 0xBD
    jmp .exit_failure
.fail_tcp_socket:
    mov edi, 0xC0
    jmp .exit_failure
.fail_tcp_connect:
    mov edi, 0xC1
    jmp .exit_failure
.fail_tcp_name:
    mov edi, 0xC2
    jmp .exit_failure
.fail_tcp_peer:
    mov edi, 0xC3
    jmp .exit_failure
.fail_tcp_poll:
    mov edi, 0xC4
    jmp .exit_failure
.fail_tcp_boundary:
    mov edi, 0xC5
    jmp .exit_failure
.fail_tcp_close:
    mov edi, 0xC6
    jmp .exit_failure
.fail_pass:
    mov edi, 0xBE
.exit_failure:
    mov eax, SYS_EXIT
    int 0x80
    ud2
