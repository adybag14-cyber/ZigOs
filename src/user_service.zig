const std = @import("std");
const descriptor_tables = @import("descriptor_tables.zig");
const elf64 = @import("elf64.zig");
const interrupt_context = @import("interrupt_context.zig");
const memory = @import("memory.zig");
const paging = @import("paging.zig");

const cc = std.os.uefi.cc;
const service_elf = @embedFile("generated/service_user.elf");

pub const code_base: usize = 0x0000_0080_0010_0000;
pub const data_base: usize = code_base + 0x2000;
pub const bss_base: usize = code_base + 0x3000;
pub const stack_base: usize = code_base + 0x4000;
pub const heap_base: usize = code_base + 0x5000;
pub const anon_base: usize = code_base + 0x7000;
pub const guard_base: usize = code_base + 0x8000;
const text_gap: usize = code_base + 0x1000;
const page_bytes: usize = @intCast(memory.page_size);
const frame_count: usize = 7;
const result_count: usize = 49;
const process_id: u64 = 64;
const parent_process_id: u64 = 1;
const stack_canary: u64 = 0x5356_4336_3453_544B;
const bss_sentinel: u64 = 0xB16B_00B5_C0DE_C0DE;
const heap_first_sentinel: u64 = 0x1111_2222_3333_4444;
const heap_second_sentinel: u64 = 0x5555_6666_7777_8888;
const anon_sentinel: u64 = 0xCAFE_BABE_DEAD_BEEF;
const output_message = "ZigOs x86-64 ELF64 service active.";
const pipe_payload = "PIPE64-PAYLOAD-VERIFIED!";
const service_clock_initial: u64 = 0x1000;

const errno_no_process: i64 = -3;
const errno_bad_fd: i64 = -9;
const errno_would_block: i64 = -11;
const errno_fault: i64 = -14;
const errno_busy: i64 = -16;
const errno_invalid: i64 = -22;
const errno_no_syscall: i64 = -38;

const getpid_syscall: u64 = 0;
const getppid_syscall: u64 = 1;
const process_info_syscall: u64 = 2;
const clock_syscall: u64 = 3;
const write_output_syscall: u64 = 4;
const hash_syscall: u64 = 5;
const brk_syscall: u64 = 6;
const memory_info_syscall: u64 = 7;
const mmap_syscall: u64 = 8;
const munmap_syscall: u64 = 9;
const pipe_syscall: u64 = 10;
const read_syscall: u64 = 11;
const write_syscall: u64 = 12;
const close_syscall: u64 = 13;
const dup_syscall: u64 = 14;
const dup2_syscall: u64 = 15;
const descriptor_info_syscall: u64 = 16;
const signal_send_syscall: u64 = 17;
const signal_take_syscall: u64 = 18;
const yield_syscall: u64 = 19;
const sleep_syscall: u64 = 20;
const set_fault_syscall: u64 = 21;
const exit_syscall: u64 = 22;

const ProcessState = enum(u64) {
    free = 0,
    running = 1,
    exited = 2,
    faulted = 3,
};

const DescriptorKind = enum(u64) {
    free = 0,
    pipe_read = 1,
    pipe_write = 2,
};

const Descriptor = struct {
    kind: DescriptorKind = .free,
    open: bool = false,
};

const Pipe = struct {
    bytes: [64]u8 = @splat(0),
    read_offset: u8 = 0,
    write_offset: u8 = 0,
    readers: u8 = 0,
    writers: u8 = 0,
    active: bool = false,
};

pub const FaultRecord = struct {
    vector: u64,
    error_code: u64,
    rip: u64,
    rsp: u64,
    address: u64,
    handler: u64,
};

pub const Report = struct {
    elf_bytes: usize,
    elf_hash: u64,
    code_hash: u64,
    data_hash: u64,
    entry: u64,
    rx_file_bytes: u64,
    rw_file_bytes: u64,
    rw_memory_bytes: u64,
    parser_rejections: u64,
    allocated_frames: u64,
    page_table_frames: u64,
    mapped_initial_pages: u64,
    nx_enabled: bool,
    code_read_only: bool,
    data_non_executable: bool,
    guard_unmapped: bool,
    accessed_dirty_verified: bool,
    syscall_count: u64,
    rejected_syscalls: u64,
    pointer_faults: u64,
    output_bytes: u64,
    pipe_bytes: u64,
    descriptor_peak: u64,
    descriptor_closes: u64,
    signal_deliveries: u64,
    yields: u64,
    slept_ticks: u64,
    final_clock: u64,
    exit_code: u64,
    fault_count: u64,
    first_fault: FaultRecord,
    second_fault: FaultRecord,
    code_immutable: bool,
    bss_verified: bool,
    heap_verified: bool,
    anonymous_verified: bool,
    stack_canary_intact: bool,
    descriptors_closed: bool,
    pipe_released: bool,
    mappings_removed: bool,
    allocator_restored: bool,
    cr3_restored: bool,
    returned_to_kernel: bool,
};

extern fn zigos_enter_user(
    user_rip: usize,
    user_rsp: usize,
    user_cs: u16,
    user_ss: u16,
) callconv(cc) void;

var active = false;
var fatal_failure = false;
var state: ProcessState = .free;
var frames: [frame_count]usize = @splat(0);
var current_brk: usize = heap_base;
var heap_pages_mapped: u8 = 0;
var anonymous_mapped = false;
var descriptors: [8]Descriptor = @splat(.{});
var pipe_state: Pipe = .{};
var output_buffer: [128]u8 = @splat(0);
var output_length: u8 = 0;
var pending_signal: u8 = 0;
var fault_handler: usize = 0;
var fault_records: [2]FaultRecord = @splat(.{
    .vector = 0,
    .error_code = 0,
    .rip = 0,
    .rsp = 0,
    .address = 0,
    .handler = 0,
});
var fault_count: u8 = 0;
var exit_code: u64 = 0;
var syscall_count: u64 = 0;
var rejected_syscalls: u64 = 0;
var pointer_faults: u64 = 0;
var output_calls: u64 = 0;
var hash_calls: u64 = 0;
var process_info_calls: u64 = 0;
var memory_info_calls: u64 = 0;
var pipe_create_calls: u64 = 0;
var pipe_read_calls: u64 = 0;
var pipe_write_calls: u64 = 0;
var descriptor_peak: u64 = 0;
var descriptor_closes: u64 = 0;
var signal_deliveries: u64 = 0;
var yields: u64 = 0;
var slept_ticks: u64 = 0;
var service_clock: u64 = service_clock_initial;
var parser_rejections: u64 = 0;
var malformed_image: [service_elf.len]u8 = undefined;
var failure_stage: u64 = 0;
var failure_syscalls: u64 = 0;
var failure_exit_code: u64 = 0;
var failure_faults: u64 = 0;
var failure_rejected: u64 = 0;

pub fn isActive() bool {
    return active;
}

pub fn lastFailureStage() u64 {
    return failure_stage;
}

pub fn lastFailureSyscalls() u64 {
    return failure_syscalls;
}

pub fn lastFailureExitCode() u64 {
    return failure_exit_code;
}

pub fn lastFailureFaults() u64 {
    return failure_faults;
}

pub fn lastFailureRejected() u64 {
    return failure_rejected;
}

fn fail(stage: u64) ?Report {
    failure_stage = stage;
    failure_syscalls = syscall_count;
    failure_exit_code = exit_code;
    failure_faults = fault_count;
    failure_rejected = rejected_syscalls;
    active = false;
    return null;
}

pub fn run(allocator: *memory.FrameAllocator) ?Report {
    if (active) return fail(1);
    reset();
    const allocator_checkpoint = allocator.checkpoint();
    const original_cr3 = paging.currentCr3();
    allocator_pointer = allocator;

    const image = elf64.parse(service_elf) orelse return fail(2);
    if (!verifyImageContract(&image)) return fail(3);
    parser_rejections = verifyParserRejections(service_elf);
    if (parser_rejections != 8 or !sameCheckpoint(allocator.checkpoint(), allocator_checkpoint)) return fail(4);
    if (!paging.enableNoExecute()) return fail(5);

    for (&frames) |*frame| {
        frame.* = allocator.allocateBelow(memory.four_gib) orelse return fail(6);
        @memset(@as([*]u8, @ptrFromInt(frame.*))[0..page_bytes], 0);
    }
    if (allocator.allocated_pages != allocator_checkpoint.allocated_pages + frame_count) return fail(7);
    if (!loadImage(&image)) return fail(8);
    @as(*u64, @ptrFromInt(frames[3])).* = stack_canary;

    const code_hash_before = elf64.fnv1a64(@as([*]const u8, @ptrFromInt(frames[0]))[0..page_bytes]);
    const data_hash_before = elf64.fnv1a64(@as([*]const u8, @ptrFromInt(frames[1]))[0..0x800]);
    if (!mapInitialPages(allocator)) return fail(9);
    if (allocator.allocated_pages != allocator_checkpoint.allocated_pages + frame_count) return fail(10);

    const code_page = paging.inspectUserPage(code_base) orelse return fail(11);
    const data_page = paging.inspectUserPage(data_base) orelse return fail(11);
    const bss_page = paging.inspectUserPage(bss_base) orelse return fail(11);
    const stack_page = paging.inspectUserPage(stack_base) orelse return fail(11);
    if (code_page.writable or !code_page.executable) return fail(12);
    if (!data_page.writable or data_page.executable) return fail(12);
    if (!bss_page.writable or bss_page.executable) return fail(12);
    if (!stack_page.writable or stack_page.executable) return fail(12);
    if (paging.inspectUserPage(text_gap) != null or paging.inspectUserPage(guard_base) != null) return fail(13);

    state = .running;
    active = true;
    zigos_enter_user(
        @intCast(image.entry),
        stack_base + page_bytes - 16,
        descriptor_tables.user_code_selector,
        descriptor_tables.user_data_selector,
    );
    active = false;

    if (fatal_failure or state != .exited or exit_code != 0x64 or syscall_count != 50) return fail(14);
    if (!validateResults(code_hash_before)) return fail(15);
    if (output_length != output_message.len or !std.mem.eql(u8, output_buffer[0..output_length], output_message)) return fail(16);
    if (!std.mem.eql(u8, physicalSlice(frames[1], 0x380, pipe_payload.len), pipe_payload)) return fail(17);
    if (@as(*const u64, @ptrFromInt(frames[2])).* != bss_sentinel) return fail(18);
    if (@as(*const u64, @ptrFromInt(frames[4])).* != heap_first_sentinel) return fail(19);
    if (@as(*const u64, @ptrFromInt(frames[5])).* != heap_second_sentinel) return fail(20);
    if (@as(*const u64, @ptrFromInt(frames[6])).* != anon_sentinel) return fail(21);
    if (@as(*const u64, @ptrFromInt(frames[3])).* != stack_canary) return fail(22);
    if (elf64.fnv1a64(@as([*]const u8, @ptrFromInt(frames[0]))[0..page_bytes]) != code_hash_before) return fail(23);
    const code_after = paging.inspectUserPage(code_base) orelse return fail(31);
    const data_after = paging.inspectUserPage(data_base) orelse return fail(31);
    const bss_after = paging.inspectUserPage(bss_base) orelse return fail(31);
    const stack_after = paging.inspectUserPage(stack_base) orelse return fail(31);
    if (!code_after.accessed or code_after.dirty or !data_after.accessed or !data_after.dirty or
        !bss_after.accessed or !bss_after.dirty or !stack_after.accessed or !stack_after.dirty) return fail(31);
    if (openDescriptorCount() != 0 or pipe_state.active) return fail(24);
    if (heap_pages_mapped != 0 or anonymous_mapped) return fail(25);

    const first_fault = fault_records[0];
    const second_fault = fault_records[1];
    if (fault_count != 2 or first_fault.vector != 14 or first_fault.address != data_base or first_fault.error_code != 0x15) return fail(26);
    if (second_fault.vector != 14 or second_fault.address != guard_base or second_fault.error_code != 0x04) return fail(27);

    const mappings_removed = unmapInitialPages();
    if (!mappings_removed) return fail(28);
    const allocator_restored = allocator.restore(allocator_checkpoint);
    if (!allocator_restored or !sameCheckpoint(allocator.checkpoint(), allocator_checkpoint)) return fail(29);
    const cr3_restored = paging.currentCr3() == original_cr3;
    if (!cr3_restored) return fail(30);
    allocator_pointer = null;

    return .{
        .elf_bytes = service_elf.len,
        .elf_hash = image.file_hash,
        .code_hash = code_hash_before,
        .data_hash = data_hash_before,
        .entry = image.entry,
        .rx_file_bytes = image.load_segments[0].file_size,
        .rw_file_bytes = image.load_segments[1].file_size,
        .rw_memory_bytes = image.load_segments[1].memory_size,
        .parser_rejections = parser_rejections,
        .allocated_frames = frame_count,
        .page_table_frames = 0,
        .mapped_initial_pages = 4,
        .nx_enabled = paging.noExecuteEnabled(),
        .code_read_only = !code_page.writable,
        .data_non_executable = !data_page.executable,
        .guard_unmapped = true,
        .accessed_dirty_verified = true,
        .syscall_count = syscall_count,
        .rejected_syscalls = rejected_syscalls,
        .pointer_faults = pointer_faults,
        .output_bytes = output_length,
        .pipe_bytes = pipe_payload.len,
        .descriptor_peak = descriptor_peak,
        .descriptor_closes = descriptor_closes,
        .signal_deliveries = signal_deliveries,
        .yields = yields,
        .slept_ticks = slept_ticks,
        .final_clock = service_clock,
        .exit_code = exit_code,
        .fault_count = fault_count,
        .first_fault = first_fault,
        .second_fault = second_fault,
        .code_immutable = true,
        .bss_verified = true,
        .heap_verified = true,
        .anonymous_verified = true,
        .stack_canary_intact = true,
        .descriptors_closed = true,
        .pipe_released = true,
        .mappings_removed = true,
        .allocator_restored = true,
        .cr3_restored = true,
        .returned_to_kernel = true,
    };
}

pub fn handleSyscall(
    frame: *interrupt_context.Frame,
    fx_state: *align(16) interrupt_context.FxState,
) u64 {
    _ = fx_state;
    if (!active or state != .running) return 1;
    syscall_count +%= 1;
    if (!validFrame(frame)) {
        fatal_failure = true;
        return 1;
    }

    const result = switch (frame.rax) {
        getpid_syscall => process_id,
        getppid_syscall => parent_process_id,
        process_info_syscall => processInfo(frame.rdi, frame),
        clock_syscall => service_clock,
        write_output_syscall => writeOutput(frame.rdi, frame.rsi),
        hash_syscall => hashUserRange(frame.rdi, frame.rsi),
        brk_syscall => updateBrk(frame.rdi),
        memory_info_syscall => memoryInfo(frame.rdi),
        mmap_syscall => mapAnonymous(),
        munmap_syscall => unmapAnonymous(frame.rdi),
        pipe_syscall => createPipe(frame.rdi),
        read_syscall => readDescriptor(frame.rdi, frame.rsi, frame.rdx),
        write_syscall => writeDescriptor(frame.rdi, frame.rsi, frame.rdx),
        close_syscall => closeDescriptor(frame.rdi),
        dup_syscall => duplicateDescriptor(frame.rdi),
        dup2_syscall => replaceDescriptor(frame.rdi, frame.rsi),
        descriptor_info_syscall => descriptorInfo(frame.rdi, frame.rsi),
        signal_send_syscall => sendSignal(frame.rdi, frame.rsi),
        signal_take_syscall => takeSignal(),
        yield_syscall => yieldProcess(),
        sleep_syscall => sleepProcess(frame.rdi),
        set_fault_syscall => setFaultHandler(frame.rdi),
        exit_syscall => {
            exit_code = frame.rdi;
            state = .exited;
            closeAllDescriptors();
            return 1;
        },
        else => reject(errno_no_syscall),
    };
    frame.rax = result;
    return 0;
}

pub fn handleException(
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rsp: u64,
    address: u64,
    resume_rip: *u64,
) bool {
    if (!active or state != .running or vector != 14 or cs != descriptor_tables.user_code_selector) return false;
    if (fault_handler == 0 or fault_count >= fault_records.len) return false;
    if (rsp < stack_base or rsp >= stack_base + page_bytes) return false;
    const expected = if (fault_count == 0) data_base else guard_base;
    const expected_error: u64 = if (fault_count == 0) 0x15 else 0x04;
    if (address != expected or error_code != expected_error) return false;
    if (fault_count == 0 and rip != data_base) return false;
    if (paging.translateUserAddress(fault_handler, false, true) == null) return false;

    fault_records[fault_count] = .{
        .vector = vector,
        .error_code = error_code,
        .rip = rip,
        .rsp = rsp,
        .address = address,
        .handler = fault_handler,
    };
    resume_rip.* = fault_handler;
    fault_handler = 0;
    fault_count += 1;
    return true;
}

fn verifyImageContract(image: *const elf64.Image) bool {
    if (image.entry != code_base or image.load_count != 2 or image.program_header_count != 2) return false;
    const text = image.load_segments[0];
    const data = image.load_segments[1];
    return text.virtual_address == code_base and text.file_offset == 0x1000 and text.file_size == 2628 and
        text.memory_size == text.file_size and text.flags == elf64.pf_read | elf64.pf_execute and
        data.virtual_address == data_base and data.file_offset == 0x2000 and data.file_size == 0x800 and
        data.memory_size == 0x2000 and data.flags == elf64.pf_read | elf64.pf_write;
}

fn verifyParserRejections(file: []const u8) u64 {
    var count: u64 = 0;
    const mutations = [_]struct { offset: usize, value: u8 }{
        .{ .offset = 0, .value = 0 },
        .{ .offset = 4, .value = 1 },
        .{ .offset = 18, .value = 3 },
        .{ .offset = 56, .value = 0 },
        .{ .offset = 68, .value = 7 },
        .{ .offset = 64 + 40, .value = 0 },
        .{ .offset = 64 + 48, .value = 1 },
        .{ .offset = 31, .value = 0xFF },
    };
    for (mutations) |mutation| {
        @memcpy(malformed_image[0..], file);
        malformed_image[mutation.offset] = mutation.value;
        if (elf64.parse(&malformed_image) == null) count += 1;
    }
    return count;
}

fn loadImage(image: *const elf64.Image) bool {
    const text = image.segmentBytes(service_elf, 0) orelse return false;
    const data = image.segmentBytes(service_elf, 1) orelse return false;
    if (text.len > page_bytes or data.len > page_bytes) return false;
    @memcpy(@as([*]u8, @ptrFromInt(frames[0]))[0..text.len], text);
    @memcpy(@as([*]u8, @ptrFromInt(frames[1]))[0..data.len], data);
    if (!allZero(@as([*]const u8, @ptrFromInt(frames[2]))[0..page_bytes])) return false;
    const embedded_code_hash = @as(*align(1) const u64, @ptrFromInt(frames[1] + 0x7C8)).*;
    const embedded_data_hash = @as(*align(1) const u64, @ptrFromInt(frames[1] + 0x7D0)).*;
    if (embedded_code_hash != elf64.fnv1a64(text)) return false;
    if (embedded_data_hash != elf64.fnv1a64(@as([*]const u8, @ptrFromInt(frames[1]))[0..0x7D0])) return false;
    return @as(*align(1) const u64, @ptrFromInt(frames[1] + 0x7C0)).* == 0x4543_4956_5245_5336;
}

fn mapInitialPages(allocator: *memory.FrameAllocator) bool {
    if (!paging.mapUserPage(allocator, code_base, frames[0], false, true)) return false;
    if (!paging.mapUserPage(allocator, data_base, frames[1], true, false)) return false;
    if (!paging.mapUserPage(allocator, bss_base, frames[2], true, false)) return false;
    if (!paging.mapUserPage(allocator, stack_base, frames[3], true, false)) return false;
    return true;
}

fn unmapInitialPages() bool {
    var ok = true;
    ok = paging.unmapUserPage(stack_base, frames[3]) and ok;
    ok = paging.unmapUserPage(bss_base, frames[2]) and ok;
    ok = paging.unmapUserPage(data_base, frames[1]) and ok;
    ok = paging.unmapUserPage(code_base, frames[0]) and ok;
    return ok and paging.inspectUserPage(text_gap) == null and paging.inspectUserPage(guard_base) == null;
}

fn validFrame(frame: *const interrupt_context.Frame) bool {
    if (frame.cs != descriptor_tables.user_code_selector or frame.ss != descriptor_tables.user_data_selector) return false;
    if (frame.rip < code_base or frame.rip >= code_base + page_bytes) return false;
    if (frame.rsp < stack_base or frame.rsp >= stack_base + page_bytes) return false;
    return paging.translateUserAddress(@intCast(frame.rip), false, true) != null;
}

fn processInfo(address: u64, frame: *const interrupt_context.Frame) u64 {
    process_info_calls +%= 1;
    var bytes: [96]u8 = @splat(0);
    write64(&bytes, 0, process_id);
    write64(&bytes, 8, parent_process_id);
    write64(&bytes, 16, @intFromEnum(state));
    write64(&bytes, 24, syscall_count);
    write64(&bytes, 32, current_brk);
    write64(&bytes, 40, @intFromBool(anonymous_mapped));
    write64(&bytes, 48, pending_signal);
    write64(&bytes, 56, fault_count);
    write64(&bytes, 64, openDescriptorCount());
    write64(&bytes, 72, output_length);
    write64(&bytes, 80, paging.currentCr3());
    write64(&bytes, 88, (frame.ss << 32) | frame.cs);
    if (!copyToUser(address, &bytes)) return rejectFault();
    return 0;
}

fn memoryInfo(address: u64) u64 {
    memory_info_calls +%= 1;
    var bytes: [64]u8 = @splat(0);
    write64(&bytes, 0, heap_base);
    write64(&bytes, 8, current_brk);
    write64(&bytes, 16, heap_pages_mapped);
    write64(&bytes, 24, @intFromBool(anonymous_mapped));
    write64(&bytes, 32, @intFromBool(paging.noExecuteEnabled()));
    write64(&bytes, 40, @intFromBool(paging.inspectUserPage(guard_base) == null));
    write64(&bytes, 48, frame_count);
    write64(&bytes, 56, 4 + heap_pages_mapped + @intFromBool(anonymous_mapped));
    if (!copyToUser(address, &bytes)) return rejectFault();
    return 0;
}

fn writeOutput(address: u64, length: u64) u64 {
    output_calls +%= 1;
    if (length == 0) return 0;
    if (length > output_buffer.len - output_length) return reject(errno_invalid);
    const size: usize = @intCast(length);
    if (!copyFromUser(address, output_buffer[output_length .. output_length + size])) return rejectFault();
    output_length += @intCast(size);
    return length;
}

fn hashUserRange(address: u64, length: u64) u64 {
    hash_calls +%= 1;
    if (length == 0 or length > 4096) return reject(errno_invalid);
    var value: u64 = 0xCBF2_9CE4_8422_2325;
    var offset: u64 = 0;
    while (offset < length) : (offset += 1) {
        const virtual = std.math.add(u64, address, offset) catch return rejectFault();
        const physical = paging.translateUserAddress(@intCast(virtual), false, false) orelse return rejectFault();
        value ^= @as(*const u8, @ptrFromInt(physical)).*;
        value *%= 0x0000_0100_0000_01B3;
    }
    return value;
}

fn updateBrk(requested: u64) u64 {
    if (requested == 0) return current_brk;
    if (requested != heap_base and requested != heap_base + page_bytes and requested != heap_base + 2 * page_bytes) {
        return reject(errno_invalid);
    }
    const desired_pages: u8 = @intCast((requested - heap_base) / page_bytes);
    if (desired_pages == heap_pages_mapped) return requested;
    if (desired_pages > heap_pages_mapped) {
        var mapped = heap_pages_mapped;
        while (mapped < desired_pages) : (mapped += 1) {
            if (!paging.mapUserPage(activeAllocator(), heap_base + @as(usize, mapped) * page_bytes, frames[4 + mapped], true, false)) {
                while (mapped > heap_pages_mapped) {
                    mapped -= 1;
                    _ = paging.unmapUserPage(heap_base + @as(usize, mapped) * page_bytes, frames[4 + mapped]);
                }
                return reject(errno_invalid);
            }
        }
    } else {
        var mapped = heap_pages_mapped;
        while (mapped > desired_pages) {
            mapped -= 1;
            if (!paging.unmapUserPage(heap_base + @as(usize, mapped) * page_bytes, frames[4 + mapped])) return reject(errno_invalid);
        }
    }
    heap_pages_mapped = desired_pages;
    current_brk = @intCast(requested);
    return requested;
}

var allocator_pointer: ?*memory.FrameAllocator = null;

fn activeAllocator() *memory.FrameAllocator {
    return allocator_pointer orelse unreachable;
}

fn mapAnonymous() u64 {
    if (anonymous_mapped) return reject(errno_busy);
    if (!paging.mapUserPage(activeAllocator(), anon_base, frames[6], true, false)) return reject(errno_invalid);
    anonymous_mapped = true;
    return anon_base;
}

fn unmapAnonymous(address: u64) u64 {
    if (address != anon_base or !anonymous_mapped) return reject(errno_invalid);
    if (!paging.unmapUserPage(anon_base, frames[6])) return reject(errno_invalid);
    anonymous_mapped = false;
    return 0;
}

fn createPipe(address: u64) u64 {
    pipe_create_calls +%= 1;
    if (pipe_state.active or openDescriptorCount() != 0) return reject(errno_busy);
    var pair: [16]u8 = @splat(0);
    write64(&pair, 0, 0);
    write64(&pair, 8, 1);
    if (!validateUserRange(address, pair.len, true)) return rejectFault();
    pipe_state = .{ .active = true, .readers = 1, .writers = 1 };
    descriptors[0] = .{ .kind = .pipe_read, .open = true };
    descriptors[1] = .{ .kind = .pipe_write, .open = true };
    updateDescriptorPeak();
    if (!copyToUser(address, &pair)) {
        closeAllDescriptors();
        return rejectFault();
    }
    return 0;
}

fn readDescriptor(fd_value: u64, address: u64, length: u64) u64 {
    pipe_read_calls +%= 1;
    const fd = descriptorIndex(fd_value) orelse return reject(errno_bad_fd);
    if (!descriptors[fd].open or descriptors[fd].kind != .pipe_read or !pipe_state.active) return reject(errno_bad_fd);
    if (length > 64) return reject(errno_invalid);
    const available: usize = pipe_state.write_offset - pipe_state.read_offset;
    if (available == 0) return if (pipe_state.writers == 0) 0 else reject(errno_would_block);
    const count: usize = @min(@as(usize, @intCast(length)), available);
    if (!validateUserRange(address, count, true)) return rejectFault();
    if (!copyToUser(address, pipe_state.bytes[pipe_state.read_offset .. pipe_state.read_offset + count])) return rejectFault();
    pipe_state.read_offset += @intCast(count);
    return count;
}

fn writeDescriptor(fd_value: u64, address: u64, length: u64) u64 {
    pipe_write_calls +%= 1;
    const fd = descriptorIndex(fd_value) orelse return reject(errno_bad_fd);
    if (!descriptors[fd].open or descriptors[fd].kind != .pipe_write or !pipe_state.active) return reject(errno_bad_fd);
    if (pipe_state.readers == 0) return reject(errno_invalid);
    const free = pipe_state.bytes.len - pipe_state.write_offset;
    if (length > free) return reject(errno_would_block);
    const count: usize = @intCast(length);
    if (!copyFromUser(address, pipe_state.bytes[pipe_state.write_offset .. pipe_state.write_offset + count])) return rejectFault();
    pipe_state.write_offset += @intCast(count);
    return count;
}

fn closeDescriptor(fd_value: u64) u64 {
    const fd = descriptorIndex(fd_value) orelse return reject(errno_bad_fd);
    if (!closeDescriptorIndex(fd)) return reject(errno_bad_fd);
    return 0;
}

fn duplicateDescriptor(fd_value: u64) u64 {
    const source = descriptorIndex(fd_value) orelse return reject(errno_bad_fd);
    if (!descriptors[source].open) return reject(errno_bad_fd);
    for (descriptors, 0..) |descriptor, index| {
        if (descriptor.open) continue;
        descriptors[index] = descriptors[source];
        addPipeReference(descriptors[index].kind);
        updateDescriptorPeak();
        return index;
    }
    return reject(errno_busy);
}

fn replaceDescriptor(source_value: u64, target_value: u64) u64 {
    const source = descriptorIndex(source_value) orelse return reject(errno_bad_fd);
    const target = descriptorIndex(target_value) orelse return reject(errno_bad_fd);
    if (!descriptors[source].open) return reject(errno_bad_fd);
    if (source == target) return target;
    if (descriptors[target].open and !closeDescriptorIndex(target)) return reject(errno_bad_fd);
    descriptors[target] = descriptors[source];
    addPipeReference(descriptors[target].kind);
    updateDescriptorPeak();
    return target;
}

fn descriptorInfo(fd_value: u64, address: u64) u64 {
    const fd = descriptorIndex(fd_value) orelse return reject(errno_bad_fd);
    if (!descriptors[fd].open) return reject(errno_bad_fd);
    var bytes: [32]u8 = @splat(0);
    write64(&bytes, 0, fd);
    write64(&bytes, 8, @intFromEnum(descriptors[fd].kind));
    write64(&bytes, 16, (@as(u64, pipe_state.writers) << 32) | pipe_state.readers);
    write64(&bytes, 24, pipe_state.write_offset - pipe_state.read_offset);
    if (!copyToUser(address, &bytes)) return rejectFault();
    return 0;
}

fn sendSignal(pid: u64, signal: u64) u64 {
    if (pid != process_id) return reject(errno_no_process);
    if (signal == 0 or signal > 31 or pending_signal != 0) return reject(errno_invalid);
    pending_signal = @intCast(signal);
    signal_deliveries +%= 1;
    return 0;
}

fn takeSignal() u64 {
    const signal = pending_signal;
    pending_signal = 0;
    return signal;
}

fn yieldProcess() u64 {
    yields +%= 1;
    service_clock +%= 1;
    return 0;
}

fn sleepProcess(ticks: u64) u64 {
    if (ticks == 0 or ticks > 16) return reject(errno_invalid);
    slept_ticks +%= ticks;
    service_clock +%= ticks;
    return ticks;
}

fn setFaultHandler(address: u64) u64 {
    if (address < code_base or address >= code_base + page_bytes) return rejectFault();
    if (paging.translateUserAddress(@intCast(address), false, true) == null) return rejectFault();
    fault_handler = @intCast(address);
    return 0;
}

fn closeAllDescriptors() void {
    for (0..descriptors.len) |index| {
        if (descriptors[index].open) _ = closeDescriptorIndex(index);
    }
}

fn closeDescriptorIndex(index: usize) bool {
    if (index >= descriptors.len or !descriptors[index].open) return false;
    const kind = descriptors[index].kind;
    descriptors[index] = .{};
    descriptor_closes +%= 1;
    switch (kind) {
        .pipe_read => {
            if (pipe_state.readers != 0) pipe_state.readers -= 1;
        },
        .pipe_write => {
            if (pipe_state.writers != 0) pipe_state.writers -= 1;
        },
        .free => {},
    }
    if (pipe_state.readers == 0 and pipe_state.writers == 0) pipe_state = .{};
    return true;
}

fn addPipeReference(kind: DescriptorKind) void {
    switch (kind) {
        .pipe_read => pipe_state.readers +%= 1,
        .pipe_write => pipe_state.writers +%= 1,
        .free => {},
    }
}

fn updateDescriptorPeak() void {
    descriptor_peak = @max(descriptor_peak, openDescriptorCount());
}

fn openDescriptorCount() u64 {
    var count: u64 = 0;
    for (descriptors) |descriptor| {
        if (descriptor.open) count += 1;
    }
    return count;
}

fn descriptorIndex(value: u64) ?usize {
    if (value >= descriptors.len) return null;
    return @intCast(value);
}

fn validateResults(code_page_hash: u64) bool {
    const results = @as([*]align(1) const u64, @ptrFromInt(frames[1]))[0..result_count];
    const expected = [_]u64{
        process_id,
        parent_process_id,
        0,
        errorValue(errno_fault),
        service_clock_initial,
        output_message.len,
        errorValue(errno_fault),
        errorValue(errno_fault),
        0,
        elf64.fnv1a64(@as([*]const u8, @ptrFromInt(frames[0]))[0..64]),
        heap_base,
        heap_base + 2 * page_bytes,
        errorValue(errno_fault),
        0,
        anon_base,
        errorValue(errno_busy),
        0,
        0,
        0,
        pipe_payload.len,
        2,
        7,
        0,
        pipe_payload.len,
        0,
        0,
        0,
        0,
        errorValue(errno_bad_fd),
        errorValue(errno_no_process),
        0,
        9,
        0,
        0,
        errorValue(errno_invalid),
        3,
        service_clock_initial + 4,
        elf64.fnv1a64(pipe_payload),
        0,
        errorValue(errno_invalid),
        heap_base,
        errorValue(errno_invalid),
        errorValue(errno_bad_fd),
        0,
        errorValue(errno_fault),
        errorValue(errno_no_syscall),
        0,
        0,
        0,
    };
    if (expected.len != results.len) return false;
    for (expected, results) |wanted, actual| {
        if (wanted != actual) return false;
    }
    if (code_page_hash != elf64.fnv1a64(@as([*]const u8, @ptrFromInt(frames[0]))[0..page_bytes])) return false;
    const info = @as([*]align(1) const u64, @ptrFromInt(frames[1] + 0x200))[0..12];
    return info[0] == process_id and info[1] == parent_process_id and info[2] == @intFromEnum(ProcessState.running) and
        info[3] == 49 and info[4] == heap_base and info[5] == 0 and info[6] == 0 and info[7] == 2 and
        info[8] == 0 and info[9] == output_message.len and info[10] == paging.currentCr3() and
        @as(u16, @truncate(info[11])) == descriptor_tables.user_code_selector and
        @as(u16, @truncate(info[11] >> 32)) == descriptor_tables.user_data_selector and
        rejected_syscalls == 13 and pointer_faults == 5 and output_calls == 4 and hash_calls == 2 and
        process_info_calls == 4 and memory_info_calls == 3 and pipe_create_calls == 1 and
        pipe_read_calls == 2 and pipe_write_calls == 1 and descriptor_peak == 4 and descriptor_closes == 4 and
        signal_deliveries == 1 and yields == 1 and slept_ticks == 3 and service_clock == service_clock_initial + 4;
}

fn copyFromUser(address: u64, destination: []u8) bool {
    if (destination.len == 0) return true;
    if (!validateUserRange(address, destination.len, false)) return false;
    var copied: usize = 0;
    while (copied < destination.len) {
        const virtual = @as(usize, @intCast(address)) + copied;
        const physical = paging.translateUserAddress(virtual, false, false) orelse return false;
        const chunk = @min(destination.len - copied, page_bytes - (virtual & 0xFFF));
        @memcpy(destination[copied .. copied + chunk], @as([*]const u8, @ptrFromInt(physical))[0..chunk]);
        copied += chunk;
    }
    return true;
}

fn copyToUser(address: u64, source: []const u8) bool {
    if (source.len == 0) return true;
    if (!validateUserRange(address, source.len, true)) return false;
    var copied: usize = 0;
    while (copied < source.len) {
        const virtual = @as(usize, @intCast(address)) + copied;
        const physical = paging.translateUserAddress(virtual, true, false) orelse return false;
        const chunk = @min(source.len - copied, page_bytes - (virtual & 0xFFF));
        @memcpy(@as([*]u8, @ptrFromInt(physical))[0..chunk], source[copied .. copied + chunk]);
        copied += chunk;
    }
    return true;
}

fn validateUserRange(address: u64, length: usize, write: bool) bool {
    if (length == 0) return true;
    const end = std.math.add(u64, address, length - 1) catch return false;
    if (end > 0x0000_7FFF_FFFF_FFFF) return false;
    var current = address;
    while (current <= end) {
        if (paging.translateUserAddress(@intCast(current), write, false) == null) return false;
        const next = (current & ~@as(u64, 0xFFF)) + page_bytes;
        if (next == 0 or next > end) break;
        current = next;
    }
    return true;
}

fn rejectFault() u64 {
    pointer_faults +%= 1;
    return reject(errno_fault);
}

fn reject(code: i64) u64 {
    rejected_syscalls +%= 1;
    return errorValue(code);
}

fn errorValue(code: i64) u64 {
    return @bitCast(code);
}

fn write64(destination: []u8, offset: usize, value: u64) void {
    for (0..8) |index| destination[offset + index] = @truncate(value >> @intCast(index * 8));
}

fn physicalSlice(frame: usize, offset: usize, length: usize) []const u8 {
    return @as([*]const u8, @ptrFromInt(frame + offset))[0..length];
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn sameCheckpoint(left: memory.FrameAllocator.Checkpoint, right: memory.FrameAllocator.Checkpoint) bool {
    return left.region_index == right.region_index and left.current_frame == right.current_frame and
        left.current_region_end == right.current_region_end and left.allocated_pages == right.allocated_pages;
}

fn reset() void {
    active = false;
    fatal_failure = false;
    state = .free;
    frames = @splat(0);
    current_brk = heap_base;
    heap_pages_mapped = 0;
    anonymous_mapped = false;
    descriptors = @splat(.{});
    pipe_state = .{};
    output_buffer = @splat(0);
    output_length = 0;
    pending_signal = 0;
    fault_handler = 0;
    fault_records = @splat(.{ .vector = 0, .error_code = 0, .rip = 0, .rsp = 0, .address = 0, .handler = 0 });
    fault_count = 0;
    exit_code = 0;
    syscall_count = 0;
    rejected_syscalls = 0;
    pointer_faults = 0;
    output_calls = 0;
    hash_calls = 0;
    process_info_calls = 0;
    memory_info_calls = 0;
    pipe_create_calls = 0;
    pipe_read_calls = 0;
    pipe_write_calls = 0;
    descriptor_peak = 0;
    descriptor_closes = 0;
    signal_deliveries = 0;
    yields = 0;
    slept_ticks = 0;
    service_clock = service_clock_initial;
    parser_rejections = 0;
    allocator_pointer = null;
    failure_stage = 0;
    failure_syscalls = 0;
    failure_exit_code = 0;
    failure_faults = 0;
    failure_rejected = 0;
}
