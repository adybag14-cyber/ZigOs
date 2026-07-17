const std = @import("std");
const serial = @import("serial.zig");
const stack_trace = @import("stack_trace.zig");

const cc = std.os.uefi.cc;

extern fn zigos_debug_putc(character: u8) callconv(cc) void;
extern fn zigos_halt_forever() callconv(cc) noreturn;
extern fn zigos_read_cr2() callconv(cc) u64;
extern fn zigos_trigger_ud2() callconv(cc) void;

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

pub const RecoveryResult = struct {
    vector: u64,
    error_code: u64,
    fault_rip: u64,
    resumed_rip: u64,
    trace: stack_trace.Report,
};

var recovery_armed: bool = false;
var recovery_succeeded: bool = false;
var last_vector: u64 = 0;
var last_error_code: u64 = 0;
var last_fault_rip: u64 = 0;
var last_resumed_rip: u64 = 0;
var last_trace: stack_trace.Report = stack_trace.Report.empty();
var trace_guard: u64 = 0;

pub fn testInvalidOpcodeRecovery() ?RecoveryResult {
    recovery_succeeded = false;
    last_vector = 0;
    last_error_code = 0;
    last_fault_rip = 0;
    last_resumed_rip = 0;
    last_trace = stack_trace.Report.empty();
    if (!registerRecoverySymbols()) return null;

    recovery_armed = true;
    traceProbeLevel1();
    recovery_armed = false;

    if (!recovery_succeeded or last_vector != 6) return null;
    return .{
        .vector = last_vector,
        .error_code = last_error_code,
        .fault_rip = last_fault_rip,
        .resumed_rip = last_resumed_rip,
        .trace = last_trace,
    };
}

export fn zigos_exception_handler(frame: *ExceptionFrame) callconv(cc) void {
    last_vector = frame.vector;
    last_error_code = frame.error_code;
    last_fault_rip = frame.rip;

    if (recovery_armed and frame.vector == 6) {
        last_trace = stack_trace.capture(@intCast(frame.rip), @intCast(frame.rbp));
        frame.rip += 2;
        last_resumed_rip = frame.rip;
        recovery_succeeded = true;
        return;
    }

    debugWrite("\r\nZigOs fatal CPU exception: vector ");
    debugWriteU64Decimal(frame.vector);
    debugWrite(" (");
    debugWrite(exceptionName(frame.vector));
    debugWrite(")\r\nError code: 0x");
    debugWriteHex64(frame.error_code);
    debugWrite("\r\nRIP: 0x");
    debugWriteHex64(frame.rip);
    debugWrite("  CS: 0x");
    debugWriteHex64(frame.cs);
    debugWrite("  RFLAGS: 0x");
    debugWriteHex64(frame.rflags);
    debugWrite("\r\nInterrupted RSP: 0x");
    debugWriteHex64(frame.interrupted_rsp);
    debugWrite("  SS: 0x");
    debugWriteHex64(frame.interrupted_ss);
    debugWrite("\r\nCR2: 0x");
    debugWriteHex64(zigos_read_cr2());
    debugWrite("\r\n");
    printStackTrace(stack_trace.capture(@intCast(frame.rip), @intCast(frame.rbp)));
    debugWrite("Kernel halted.\r\n");
    zigos_halt_forever();
}

fn registerRecoverySymbols() bool {
    return stack_trace.registerSymbol("zigos_trigger_ud2", @intFromPtr(&zigos_trigger_ud2)) and
        stack_trace.registerSymbol("exceptions.traceProbeLevel3", @intFromPtr(&traceProbeLevel3)) and
        stack_trace.registerSymbol("exceptions.traceProbeLevel2", @intFromPtr(&traceProbeLevel2)) and
        stack_trace.registerSymbol("exceptions.traceProbeLevel1", @intFromPtr(&traceProbeLevel1)) and
        stack_trace.registerSymbol(
            "exceptions.testInvalidOpcodeRecovery",
            @intFromPtr(&testInvalidOpcodeRecovery),
        );
}

noinline fn traceProbeLevel1() void {
    traceProbeLevel2();
    touchTraceGuard(1);
}

noinline fn traceProbeLevel2() void {
    traceProbeLevel3();
    touchTraceGuard(2);
}

noinline fn traceProbeLevel3() void {
    zigos_trigger_ud2();
    touchTraceGuard(3);
}

fn touchTraceGuard(value: u64) void {
    const pointer: *volatile u64 = &trace_guard;
    pointer.* +%= value;
}

fn printStackTrace(report: stack_trace.Report) void {
    debugWrite("Stack trace: ");
    if (report.frame_count == 0) {
        debugWrite("<unavailable>\r\n");
        return;
    }
    for (report.frames[0..report.frame_count], 0..) |frame, index| {
        if (index != 0) debugWrite(" <- ");
        debugWrite("#");
        debugWriteU64Decimal(index);
        debugWrite(" ");
        if (frame.symbol_name) |name| {
            debugWrite(name);
            debugWrite("+0x");
            debugWriteHex64(frame.symbol_offset);
        } else {
            debugWrite("0x");
            debugWriteHex64(frame.address);
        }
    }
    debugWrite("\r\n");
}

fn exceptionName(vector: u64) []const u8 {
    return switch (vector) {
        0 => "divide error",
        1 => "debug",
        2 => "non-maskable interrupt",
        3 => "breakpoint",
        4 => "overflow",
        5 => "bound range exceeded",
        6 => "invalid opcode",
        7 => "device not available",
        8 => "double fault",
        9 => "coprocessor segment overrun",
        10 => "invalid TSS",
        11 => "segment not present",
        12 => "stack-segment fault",
        13 => "general protection fault",
        14 => "page fault",
        15 => "reserved",
        16 => "x87 floating-point exception",
        17 => "alignment check",
        18 => "machine check",
        19 => "SIMD floating-point exception",
        20 => "virtualization exception",
        21 => "control-protection exception",
        22...27 => "reserved",
        28 => "hypervisor injection exception",
        29 => "VMM communication exception",
        30 => "security exception",
        31 => "reserved",
        else => "unknown",
    };
}

fn debugWrite(text: []const u8) void {
    for (text) |character| {
        zigos_debug_putc(character);
        _ = serial.putByte(character);
    }
}

fn debugWriteHex64(value: u64) void {
    const digits = "0123456789ABCDEF";
    var text: [16]u8 = undefined;
    var shift: u6 = 60;

    for (&text) |*character| {
        const nibble: u4 = @truncate(value >> shift);
        character.* = digits[nibble];
        if (shift == 0) break;
        shift -= 4;
    }
    debugWrite(&text);
}

fn debugWriteU64Decimal(initial_value: u64) void {
    if (initial_value == 0) {
        zigos_debug_putc('0');
        return;
    }

    var value = initial_value;
    var text: [20]u8 = undefined;
    var index = text.len;
    while (value != 0) {
        index -= 1;
        text[index] = @intCast('0' + (value % 10));
        value /= 10;
    }
    debugWrite(text[index..]);
}

comptime {
    if (@sizeOf(ExceptionFrame) != 176) @compileError("exception-frame layout must match the assembly stub");
}
