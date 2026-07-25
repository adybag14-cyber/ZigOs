BITS 64
ORG 0

entry:
    xor r12, r12
.spin:
    inc r12
    rol r12, 7
    jmp .spin
