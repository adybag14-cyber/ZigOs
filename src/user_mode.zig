const std = @import("std");
const descriptor_tables = @import("descriptor_tables.zig");
const interrupt_context = @import("interrupt_context.zig");
const memory = @import("memory.zig");
const paging = @import("paging.zig");
const user_process = @import("user_process.zig");
const user_service = @import("user_service.zig");

const cc = std.os.uefi.cc;
const report_syscall: u64 = 1;
const exit_syscall: u64 = 2;
const user_argument: u64 = 0xC0DE_FACE;
const syscall_return_value: u64 = 0x051A_11CE;
const expected_exit_code: u64 = 0x42;
const stack_canary: u64 = 0x5553_4552_5354_414B;

extern fn zigos_user_program_source() callconv(cc) usize;
extern fn zigos_user_program_size() callconv(cc) usize;
extern fn zigos_enter_user(
    user_rip: usize,
    user_rsp: usize,
    user_cs: u16,
    user_ss: u16,
) callconv(cc) void;

pub const Report = struct {
    code_physical: usize,
    stack_physical: usize,
    code_virtual: usize,
    stack_virtual: usize,
    program_size: usize,
    page_table_pages: u64,
    syscall_count: u64,
    observed_cs: u64,
    observed_ss: u64,
    observed_rip: u64,
    observed_rsp: u64,
    observed_argument: u64,
    exit_code: u64,
    returned_to_kernel: bool,
    stack_canary_intact: bool,
};

var syscall_count: u64 = 0;
var observed_cs: u64 = 0;
var observed_ss: u64 = 0;
var observed_rip: u64 = 0;
var observed_rsp: u64 = 0;
var observed_argument: u64 = 0;
var exit_code: u64 = 0;
var report_received: bool = false;
var exit_received: bool = false;
var syscall_failure: bool = false;
var active_code_virtual: usize = 0;
var active_stack_virtual: usize = 0;

pub fn run(allocator: *memory.FrameAllocator) ?Report {
    reset();
    if (!paging.enableNoExecute()) return null;

    const code_physical = allocator.allocateBelow(memory.four_gib) orelse return null;
    const stack_physical = allocator.allocateBelow(memory.four_gib) orelse return null;
    const page_bytes: usize = @intCast(memory.page_size);
    const code_page = @as([*]u8, @ptrFromInt(code_physical))[0..page_bytes];
    const stack_page = @as([*]u8, @ptrFromInt(stack_physical))[0..page_bytes];
    @memset(code_page, 0);
    @memset(stack_page, 0);
    @as(*u64, @ptrFromInt(stack_physical)).* = stack_canary;

    const program_source = zigos_user_program_source();
    const program_size = zigos_user_program_size();
    if (program_size == 0 or program_size > code_page.len) return null;
    const source = @as([*]const u8, @ptrFromInt(program_source))[0..program_size];
    @memcpy(code_page[0..program_size], source);

    const mapping = paging.mapUserExperiment(allocator, code_physical, stack_physical) orelse return null;
    active_code_virtual = mapping.code_virtual;
    active_stack_virtual = mapping.stack_virtual;

    zigos_enter_user(
        mapping.code_virtual,
        mapping.stack_top,
        descriptor_tables.user_code_selector,
        descriptor_tables.user_data_selector,
    );

    const canary_intact = @as(*const u64, @ptrFromInt(stack_physical)).* == stack_canary;
    if (syscall_failure or !report_received or !exit_received) return null;
    if (syscall_count != 2 or exit_code != expected_exit_code) return null;
    if (!canary_intact) return null;
    if (!std.mem.eql(u8, code_page[0..program_size], source)) return null;

    return .{
        .code_physical = code_physical,
        .stack_physical = stack_physical,
        .code_virtual = mapping.code_virtual,
        .stack_virtual = mapping.stack_virtual,
        .program_size = program_size,
        .page_table_pages = mapping.table_pages,
        .syscall_count = syscall_count,
        .observed_cs = observed_cs,
        .observed_ss = observed_ss,
        .observed_rip = observed_rip,
        .observed_rsp = observed_rsp,
        .observed_argument = observed_argument,
        .exit_code = exit_code,
        .returned_to_kernel = true,
        .stack_canary_intact = canary_intact,
    };
}

export fn zigos_user_syscall_handler(
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) callconv(cc) u64 {
    if (user_process.isActive()) return user_process.handleSyscall(frame, fx_state);
    if (user_service.isActive()) return user_service.handleSyscall(frame, fx_state);
    syscall_count +%= 1;

    if ((frame.cs & 3) != 3 or frame.cs != descriptor_tables.user_code_selector) {
        syscall_failure = true;
        return 1;
    }
    if ((frame.ss & 3) != 3 or frame.ss != descriptor_tables.user_data_selector) {
        syscall_failure = true;
        return 1;
    }
    if (frame.rip < active_code_virtual or frame.rip >= active_code_virtual + memory.page_size) {
        syscall_failure = true;
        return 1;
    }
    if (frame.rsp < active_stack_virtual or frame.rsp >= active_stack_virtual + memory.page_size) {
        syscall_failure = true;
        return 1;
    }

    switch (frame.rax) {
        report_syscall => {
            if (frame.rdi != user_argument or report_received) {
                syscall_failure = true;
                return 1;
            }
            report_received = true;
            observed_cs = frame.cs;
            observed_ss = frame.ss;
            observed_rip = frame.rip;
            observed_rsp = frame.rsp;
            observed_argument = frame.rdi;
            frame.rax = syscall_return_value;
            return 0;
        },
        exit_syscall => {
            if (!report_received or exit_received) {
                syscall_failure = true;
                return 1;
            }
            exit_received = true;
            exit_code = frame.rdi;
            return 1;
        },
        else => {
            syscall_failure = true;
            return 1;
        },
    }
}

fn reset() void {
    syscall_count = 0;
    observed_cs = 0;
    observed_ss = 0;
    observed_rip = 0;
    observed_rsp = 0;
    observed_argument = 0;
    exit_code = 0;
    report_received = false;
    exit_received = false;
    syscall_failure = false;
    active_code_virtual = 0;
    active_stack_virtual = 0;
}
