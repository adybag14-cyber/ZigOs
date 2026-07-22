pub const Frame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rbx: u64,
    rdx: u64,
    rcx: u64,
    rax: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

pub const ExceptionFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    interrupted_rsp: u64,
    interrupted_ss: u64,
};

pub const FxState = extern struct {
    bytes: [512]u8,
};

comptime {
    if (@sizeOf(Frame) != 160) {
        @compileError("interrupt/preemption frame must match the x86-64 assembly layout");
    }
    if (@sizeOf(ExceptionFrame) != 176) {
        @compileError("exception frame must match the x86-64 assembly layout");
    }
    if (@sizeOf(FxState) != 512) {
        @compileError("FXSAVE state must remain 512 bytes");
    }
}
